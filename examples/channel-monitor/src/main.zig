//! channel-monitor: the external-source channel dogfood app.
//!
//! One Start button opens a channel through `fx.openChannel` and hands
//! the returned THREAD-SAFE handle to an app-owned worker thread; the
//! worker samples its own process every half second (uptime, resident
//! set size) and `post`s each reading — waking the UI loop itself, so
//! the app polls NOTHING: no `fx.startTimer`, no shared-queue sweep,
//! just events arriving as typed Msgs when the source produces them.
//! Stop closes the channel through `fx.closeChannel`; the worker
//! notices its next `post` answer `.closed` and winds down on its own
//! (the handle outliving the channel is safe by construction), while a
//! transient `.dropped_full` only skips that one sample — back-pressure
//! never stops the monitor. The view never opens anything — effects
//! are update-side only. The launch is gated on `handle.live()`: under
//! session replay the open parks and the gate answers false, so the
//! sampler never spawns and replay stays fully offline — the journaled
//! events are the whole stream either way.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "monitor-canvas";
const window_width: f32 = 560;
const window_height: f32 = 420;

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Channel monitor canvas", .accessibility_label = "Channel monitor", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Channel Monitor",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const monitor_key: u64 = 1;
pub const sample_interval_ms: i64 = 500;
const max_visible_lines = 16;
pub const max_line_bytes = 96;

pub const Model = struct {
    line_storage: [max_visible_lines][max_line_bytes]u8 = undefined,
    line_lens: [max_visible_lines]usize = [_]usize{0} ** max_visible_lines,
    visible_count: usize = 0,
    total_samples: u64 = 0,
    dropped_total: u32 = 0,
    monitoring: bool = false,
    rejected: bool = false,
    /// The source thread failed to start: the channel was closed again
    /// and the status line says so — a monitor with no producer must
    /// never report "monitoring".
    source_failed: bool = false,

    /// Copy the payload: the event's byte slice is drain scratch and
    /// dies with this update call.
    fn recordSample(model: *Model, event: native_sdk.EffectChannelEvent) void {
        model.total_samples += 1;
        model.dropped_total = event.dropped_total;
        if (model.visible_count == max_visible_lines) {
            std.mem.copyForwards([max_line_bytes]u8, model.line_storage[0 .. max_visible_lines - 1], model.line_storage[1..max_visible_lines]);
            std.mem.copyForwards(usize, model.line_lens[0 .. max_visible_lines - 1], model.line_lens[1..max_visible_lines]);
            model.visible_count -= 1;
        }
        const len = @min(event.bytes.len, max_line_bytes);
        @memcpy(model.line_storage[model.visible_count][0..len], event.bytes[0..len]);
        model.line_lens[model.visible_count] = len;
        model.visible_count += 1;
    }

    pub fn lineAt(model: *const Model, index: usize) []const u8 {
        return model.line_storage[index][0..model.line_lens[index]];
    }

    pub fn visible(model: *const Model, arena: std.mem.Allocator) []const []const u8 {
        const out = arena.alloc([]const u8, model.visible_count) catch return &.{};
        for (out, 0..) |*slot, index| slot.* = model.lineAt(index);
        return out;
    }

    pub fn statusText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.rejected) return "channel rejected";
        if (model.source_failed) return "sampler failed to start";
        if (model.monitoring) {
            // Honesty is this example's teaching job: delivered events
            // carry the channel's drop counters, so a stalled drain
            // shows up here instead of a silent "monitoring".
            if (model.dropped_total > 0) {
                return std.fmt.allocPrint(arena, "monitoring: {d} samples, {d} dropped", .{ model.total_samples, model.dropped_total }) catch "monitoring";
            }
            return std.fmt.allocPrint(arena, "monitoring: {d} samples", .{model.total_samples}) catch "monitoring";
        }
        if (model.total_samples > 0) {
            return std.fmt.allocPrint(arena, "stopped after {d} samples", .{model.total_samples}) catch "stopped";
        }
        return "idle";
    }
};

pub const Msg = union(enum) {
    start,
    stop,
    sample: native_sdk.EffectChannelEvent,
};

const MonitorApp = native_sdk.UiApp(Model, Msg);
pub const Effects = MonitorApp.Effects;

// --------------------------------------------------------------- worker

/// The one seam tests swap: `update` starts the source through this
/// pointer, so the unit tests substitute a no-thread recorder (and a
/// failing starter) while the real app spawns the sampling thread
/// below.
pub var start_source: *const fn (handle: native_sdk.ChannelHandle) std.Thread.SpawnError!void = startSamplerThread;

/// Spawn the sampling thread, DETACHED on purpose: the thread owns its
/// own wind-down — after `fx.closeChannel` (or app teardown) its next
/// `post` answers `.closed` and it returns. The generation-stamped
/// handle makes that safe without a join: a post after the channel (or
/// the whole runtime) is gone touches only the process-lifetime header.
/// A failed spawn reports to the caller — `update` closes the channel
/// and puts the failure in the model, never a "monitoring" claim with
/// no producer behind it.
fn startSamplerThread(handle: native_sdk.ChannelHandle) std.Thread.SpawnError!void {
    const thread = try std.Thread.spawn(.{}, samplerMain, .{handle});
    thread.detach();
}

/// The app-owned source: real process readings on a real thread, paced
/// by its own sleep — the loop never ticks for it.
fn samplerMain(handle: native_sdk.ChannelHandle) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const started_ms = native_sdk.monotonicMs();
    var index: u64 = 0;
    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(sample_interval_ms), .awake) catch return;
        index += 1;
        var buffer: [max_line_bytes]u8 = undefined;
        const line = formatSample(&buffer, index, started_ms);
        // The post's answer is the worker's whole protocol — "retry
        // later" and "stop forever" are different answers on purpose.
        switch (handle.post(line)) {
            // Staged: one `.data` Msg delivers on the next drain.
            .accepted => {},
            // Transient back-pressure: THIS sample is dropped and
            // counted — the next delivered event carries the totals
            // and the status line reports them — but sampling
            // continues. A stalled drain is not a stop.
            .dropped_full => {},
            // A programming error by construction here: samples are
            // bounded at max_line_bytes, far under the channel's
            // post bound — no retry of the same bytes could ever land.
            .dropped_oversized => unreachable,
            // The occupancy is over for good — Stop closed the
            // channel, or the app tore down. Wind down.
            .closed => return,
        }
    }
}

/// One reading of this process: sample ordinal, uptime, and (where the
/// OS reports it) the peak resident set size.
fn formatSample(buffer: []u8, index: u64, started_ms: u64) []const u8 {
    const now_ms = native_sdk.monotonicMs();
    const uptime_ms: u64 = if (now_ms > started_ms) now_ms - started_ms else 0;
    const rss_kb = currentMaxRssKb();
    if (rss_kb > 0) {
        return std.fmt.bufPrint(buffer, "sample {d}: uptime {d}.{d:0>1}s, peak rss {d} KiB", .{
            index, uptime_ms / 1000, (uptime_ms % 1000) / 100, rss_kb,
        }) catch "sample";
    }
    return std.fmt.bufPrint(buffer, "sample {d}: uptime {d}.{d:0>1}s", .{
        index, uptime_ms / 1000, (uptime_ms % 1000) / 100,
    }) catch "sample";
}

/// This process's peak resident set size in KiB, 0 where unavailable.
/// macOS reports `maxrss` in bytes, Linux in KiB — normalized here.
fn currentMaxRssKb() u64 {
    if (builtin.os.tag == .windows or !builtin.link_libc) return 0;
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return 0;
    const raw: u64 = @intCast(@max(usage.maxrss, 0));
    return if (builtin.os.tag.isDarwin()) raw / 1024 else raw;
}

// --------------------------------------------------------------- update

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .start => {
            if (model.monitoring) return;
            model.rejected = false;
            model.source_failed = false;
            model.total_samples = 0;
            model.visible_count = 0;
            // Per-run counter like the two above: without the reset a
            // restart shows the previous run's drop total until the
            // first data event overwrites it.
            model.dropped_total = 0;
            // Open the channel and hand its thread-safe handle to the
            // source. A refused open still answers: exactly one
            // `.rejected` event arrives instead of data.
            const handle = fx.openChannel(.{
                .key = monitor_key,
                .on_event = Effects.channelMsg(.sample),
            });
            // Launch the sampler only when the handle can accept posts
            // (`handle.live()` — the producer-launch check). Under
            // session replay this dispatch re-executes but the open
            // PARKS and `live()` answers false, so no thread spawns
            // and none of its pre-post work runs — replay stays fully
            // offline. The Msg stream is IDENTICAL either way (the
            // journaled events are the whole stream), and the model
            // stays identical too because everything below reacts to
            // the channel's events, never to `live()` itself. A
            // refused open's dead handle also answers false: its one
            // `.rejected` event still reports, with no doomed sampler
            // spawned just to exit on its first post.
            if (handle.live()) {
                // Start the source BEFORE claiming "monitoring": a
                // monitor whose producer never started must never
                // report otherwise. On failure the open occupancy
                // would sit idle forever, so close it again — the
                // `.closed` terminal retires the key for a retry — and
                // put the failure where the UI renders it.
                start_source(handle) catch {
                    model.source_failed = true;
                    fx.closeChannel(monitor_key);
                    return;
                };
            }
            model.monitoring = true;
        },
        .stop => fx.closeChannel(monitor_key),
        .sample => |event| switch (event.kind) {
            .data => model.recordSample(event),
            .closed => {
                model.monitoring = false;
                model.dropped_total = event.dropped_total;
            },
            .rejected => {
                model.monitoring = false;
                model.rejected = true;
            },
        },
    }
}

// ------------------------------------------------------------------- view

pub const MonitorUi = canvas.Ui(Msg);

pub fn view(ui: *MonitorUi, model: *const Model) MonitorUi.Node {
    return ui.column(.{ .gap = 8, .padding = 12, .style_tokens = .{ .background = .background } }, .{
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.button(.{ .variant = .primary, .on_press = .start, .disabled = model.monitoring }, "Start monitor"),
            ui.button(.{ .variant = .destructive, .on_press = .stop, .disabled = !model.monitoring }, "Stop"),
            ui.spacer(1),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, model.statusText(ui.arena)),
        }),
        ui.scroll(.{ .grow = 1, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.column(.{ .gap = 2, .padding = 8 }, ui.each(model.visible(ui.arena), lineKey, lineView)),
        }),
        ui.statusBar(.{}, ui.fmt("{d} samples · {d} dropped", .{ model.total_samples, model.dropped_total })),
    });
}

fn lineKey(line: *const []const u8) canvas.UiKey {
    return canvas.uiKey(line.*);
}

fn lineView(ui: *MonitorUi, line: *const []const u8) MonitorUi.Node {
    return ui.text(.{}, line.*);
}

// -------------------------------------------------------------------- app

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(MonitorApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = MonitorApp.init(std.heap.page_allocator, .{}, .{
        .name = "channel-monitor",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .view = view,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "channel-monitor",
        .window_title = "Native SDK Channel Monitor",
        .bundle_id = "dev.native_sdk.channel_monitor",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
