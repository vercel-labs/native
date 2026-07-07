//! effects-probe: the minimal effects dogfood app.
//!
//! One Start button spawns a long-running shell stream through
//! `fx.spawn`; each stdout line arrives as a typed Msg and lands in the
//! list; Cancel kills the process mid-stream through `fx.cancel`; Copy
//! status puts the counters on the system clipboard through
//! `fx.writeClipboard` (no pbcopy spawn). The view never spawns
//! anything — effects are update-side only.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "probe-canvas";
const window_width: f32 = 560;
const window_height: f32 = 480;

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Effects probe canvas", .accessibility_label = "Effects probe", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Effects Probe",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const stream_key: u64 = 1;
pub const clipboard_key: u64 = 2;
const max_visible_lines = 24;
const max_line_bytes = 64;

/// A slow, minutes-long stream: Cancel is the only way it ends early.
/// POSIX emits one line every 200ms through /bin/sh; Windows has no sh,
/// so cmd's `for /L` paces with the classic `ping -n 2 127.0.0.1` ~1s
/// delay (`timeout /t` refuses to wait without a console, and Wine's
/// stub returns immediately, so ping is also what keeps the stream slow
/// under the Wine effects verification). Cmd parser quirks shape the
/// exact spelling: real cmd echoes each loop-body command with a prompt
/// line unless echo is off — `/q` turns it off portably, while an `@(...)`
/// group is silently dropped by the Wine parser (exit 0, no output) —
/// and a redirect filename directly before `)` swallows the paren,
/// creating a literal `nul)` file — so ping runs first and echo closes
/// the group.
pub const stream_argv = if (builtin.os.tag == .windows) [_][]const u8{
    "cmd", "/q", "/c", "for /L %i in (1,1,500) do (ping -n 2 127.0.0.1 > nul & echo stream line %i)",
} else [_][]const u8{
    "/bin/sh", "-c", "i=0; while [ $i -lt 500 ]; do i=$((i+1)); echo \"stream line $i\"; sleep 0.2; done",
};

pub const Model = struct {
    line_storage: [max_visible_lines][max_line_bytes]u8 = undefined,
    line_lens: [max_visible_lines]usize = [_]usize{0} ** max_visible_lines,
    visible_count: usize = 0,
    total_lines: u64 = 0,
    dropped_lines: u32 = 0,
    streaming: bool = false,
    last_exit: ?native_sdk.EffectExit = null,
    /// Terminal outcome of the last clipboard copy (`fx.writeClipboard`).
    copied: ?native_sdk.EffectClipboardOutcome = null,

    /// Copy the payload: the line slice is drain scratch and dies with
    /// this update call.
    fn recordLine(model: *Model, line: native_sdk.EffectLine) void {
        model.total_lines += 1;
        model.dropped_lines += line.dropped_before;
        if (model.visible_count == max_visible_lines) {
            std.mem.copyForwards([max_line_bytes]u8, model.line_storage[0 .. max_visible_lines - 1], model.line_storage[1..max_visible_lines]);
            std.mem.copyForwards(usize, model.line_lens[0 .. max_visible_lines - 1], model.line_lens[1..max_visible_lines]);
            model.visible_count -= 1;
        }
        const len = @min(line.line.len, max_line_bytes);
        @memcpy(model.line_storage[model.visible_count][0..len], line.line[0..len]);
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
        if (model.streaming) {
            return std.fmt.allocPrint(arena, "streaming: {d} lines", .{model.total_lines}) catch "streaming";
        }
        if (model.last_exit) |exit| {
            return std.fmt.allocPrint(arena, "{s}: code {d} after {d} lines", .{ @tagName(exit.reason), exit.code, model.total_lines }) catch "done";
        }
        return "idle";
    }
};

pub const Msg = union(enum) {
    start,
    cancel,
    copy_status,
    line: native_sdk.EffectLine,
    exited: native_sdk.EffectExit,
    copied: native_sdk.EffectClipboardResult,
};

const ProbeApp = native_sdk.UiApp(Model, Msg);
pub const Effects = ProbeApp.Effects;

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .start => {
            if (model.streaming) return;
            model.streaming = true;
            model.last_exit = null;
            model.total_lines = 0;
            model.visible_count = 0;
            fx.spawn(.{
                .key = stream_key,
                .argv = &stream_argv,
                .on_line = Effects.lineMsg(.line),
                .on_exit = Effects.exitMsg(.exited),
            });
        },
        .cancel => fx.cancel(stream_key),
        // Copy the status line to the system clipboard through the
        // effects channel — no pbcopy spawn: the
        // pasteboard is a platform service, and the terminal outcome
        // arrives as one `.copied` Msg.
        .copy_status => {
            var buffer: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "effects-probe: {d} lines total, {d} dropped", .{ model.total_lines, model.dropped_lines }) catch "effects-probe";
            fx.writeClipboard(.{
                .key = clipboard_key,
                .text = text,
                .on_result = Effects.clipboardMsg(.copied),
            });
        },
        .line => |line| model.recordLine(line),
        .exited => |exit| {
            model.streaming = false;
            model.last_exit = exit;
        },
        .copied => |result| model.copied = result.outcome,
    }
}

// ------------------------------------------------------------------- view

pub const ProbeUi = canvas.Ui(Msg);

pub fn view(ui: *ProbeUi, model: *const Model) ProbeUi.Node {
    return ui.column(.{ .gap = 8, .padding = 12, .style_tokens = .{ .background = .background } }, .{
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.button(.{ .variant = .primary, .on_press = .start, .disabled = model.streaming }, "Start stream"),
            ui.button(.{ .variant = .destructive, .on_press = .cancel, .disabled = !model.streaming }, "Cancel"),
            ui.button(.{ .on_press = .copy_status }, if (model.copied) |outcome| switch (outcome) {
                .ok => "Copied",
                else => "Copy failed",
            } else "Copy status"),
            ui.spacer(1),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, model.statusText(ui.arena)),
        }),
        ui.scroll(.{ .grow = 1, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.column(.{ .gap = 2, .padding = 8 }, ui.each(model.visible(ui.arena), lineKey, lineView)),
        }),
        ui.statusBar(.{}, ui.fmt("{d} lines total · {d} dropped", .{ model.total_lines, model.dropped_lines })),
    });
}

fn lineKey(line: *const []const u8) canvas.UiKey {
    return canvas.uiKey(line.*);
}

fn lineView(ui: *ProbeUi, line: *const []const u8) ProbeUi.Node {
    return ui.text(.{}, line.*);
}

// -------------------------------------------------------------------- app

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(ProbeApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = ProbeApp.init(std.heap.page_allocator, .{}, .{
        .name = "effects-probe",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .view = view,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "effects-probe",
        .window_title = "Native SDK Effects Probe",
        .bundle_id = "dev.native_sdk.effects_probe",
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
