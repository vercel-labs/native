//! video-player: the media tier's player example, on both levels.
//!
//! The Player screen is the declarative shape — `ui.video` with `src`
//! and `controls` loads the app's single platform-decoded playback and
//! composes the house transport chrome; the model carries no transport
//! state. The Custom screen is the audio pattern — a bare media
//! surface the app claims itself through `fx.loadVideo`, with its own
//! transport bar built from the command vocabulary and every event
//! arriving as an ordinary Msg. No media ships with the example: pass
//! a file path or http(s) URL as the launch argument, or type one into
//! the source field.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "player-canvas";
const window_width: f32 = 760;
const window_height: f32 = 560;

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Video player canvas", .accessibility_label = "Video player", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Video Player",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

/// The custom screen's playback identity: the effect key every event
/// echoes, and the media-surface id the bare surface widget binds (the
/// declarative screen uses the framework-owned playback surface
/// instead, so the two screens never fight over a claim).
pub const custom_key: u64 = 1;
pub const custom_surface: u64 = 0x7601;

pub const max_source_bytes = 1024;
const seek_step_ms: u64 = 10_000;

pub const Screen = enum { player, custom };

pub const Model = struct {
    screen: Screen = .player,
    /// The source field's live edit buffer.
    source_field: canvas.TextBuffer(max_source_bytes) = .{},
    /// The committed source the active screen plays — set by Open (or
    /// the launch argument), never by keystrokes, so half-typed paths
    /// are never loaded.
    opened_storage: [max_source_bytes]u8 = undefined,
    opened_len: usize = 0,
    /// Custom-screen transport mirrors, fed ONLY by video events — the
    /// model believes the player, never its own commands.
    status: ?native_sdk.EffectVideoEventKind = null,
    playing: bool = false,
    buffering: bool = false,
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    width: u64 = 0,
    height: u64 = 0,
    muted: bool = false,
    looping: bool = false,
    volume: f32 = 1.0,

    pub fn opened(model: *const Model) []const u8 {
        return model.opened_storage[0..model.opened_len];
    }

    pub fn setOpened(model: *Model, source: []const u8) void {
        const len = @min(source.len, model.opened_storage.len);
        @memcpy(model.opened_storage[0..len], source[0..len]);
        model.opened_len = len;
    }

    fn record(model: *Model, event: native_sdk.EffectVideo) void {
        model.status = event.kind;
        model.playing = event.playing;
        model.buffering = event.buffering;
        model.position_ms = event.position_ms;
        model.duration_ms = event.duration_ms;
        if (event.width > 0) model.width = event.width;
        if (event.height > 0) model.height = event.height;
    }

    /// The Player screen's status line: static teaching, never
    /// transport state — the declarative screen's whole point is that
    /// the model carries none (the runtime-owned chrome shows the live
    /// transport), so the only honest app-side words are where the
    /// source comes from and who owns the playback.
    pub fn playerHint(model: *const Model) []const u8 {
        if (model.opened_len == 0) return "no source - pass a file path or http(s) url, or type one above";
        return "house chrome drives the playback - transport state lives in the runtime, not the model";
    }

    /// The Custom screen's status line: fed by the app's own video
    /// events, because on this screen the app owns the playback.
    pub fn statusText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.opened_len == 0) return "no source - pass a file path or http(s) url, or type one above";
        const kind = model.status orelse return "loading";
        return switch (kind) {
            .loaded, .position => std.fmt.allocPrint(arena, "{d}x{d}{s}{s}", .{
                model.width,
                model.height,
                if (model.buffering) " · buffering" else if (model.playing) " · playing" else " · paused",
                if (model.looping) " · loop" else "",
            }) catch "playing",
            .completed => "finished",
            .failed => "playback failed - is the source a video AVFoundation can decode?",
            .rejected => "source rejected - use a file path or an http(s) url",
        };
    }
};

pub const Msg = union(enum) {
    show_player,
    show_custom,
    source_edit: canvas.TextInputEvent,
    open,
    toggle_play,
    back,
    forward,
    scrubbed: f32,
    set_volume: f32,
    toggle_mute,
    toggle_loop,
    video_event: native_sdk.EffectVideo,
};

const PlayerApp = native_sdk.UiApp(Model, Msg);
pub const Effects = PlayerApp.Effects;

/// Load the committed source on the custom screen's own surface. The
/// cascade split mirrors the loadVideo contract: http(s) strings are
/// URLs, everything else is a local path.
fn loadCustom(model: *Model, fx: *Effects) void {
    const source = model.opened();
    if (source.len == 0) {
        // Committing an empty source clears the deck: the current
        // playback stops and the transport mirrors reset by hand
        // (stopVideo echoes no event), so the "no source" status line
        // and the actual player agree.
        fx.stopVideo();
        model.status = null;
        model.playing = false;
        model.buffering = false;
        model.position_ms = 0;
        model.duration_ms = 0;
        return;
    }
    const is_url = std.ascii.startsWithIgnoreCase(source, "http://") or
        std.ascii.startsWithIgnoreCase(source, "https://");
    model.status = null;
    model.position_ms = 0;
    model.duration_ms = 0;
    fx.loadVideo(.{
        .key = custom_key,
        .surface = custom_surface,
        .path = if (is_url) "" else source,
        .url = if (is_url) source else "",
        .loop = model.looping,
        .muted = model.muted,
        .on_event = Effects.videoMsg(.video_event),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        // Switching screens re-targets the single player: the leaving
        // screen's playback ends (declaratively for <video>, explicitly
        // here for the custom claim) and the arriving screen loads the
        // same committed source its own way.
        .show_player => {
            if (model.screen == .player) return;
            model.screen = .player;
            fx.stopVideo();
        },
        .show_custom => {
            if (model.screen == .custom) return;
            model.screen = .custom;
            loadCustom(model, fx);
        },
        .source_edit => |edit| model.source_field.apply(edit),
        .open => {
            model.setOpened(model.source_field.text());
            if (model.screen == .custom) loadCustom(model, fx);
        },
        // Toggle against the channel's own mirror, not the event-fed
        // model state: commands echo no events, so mid-gesture truth
        // lives in the snapshot (the next tick reconciles the model).
        // A FINISHED playback has no player left to resume (play would
        // answer with one failed event), so Play means from-the-start:
        // restartVideo reloads the same source.
        .toggle_play => if (fx.videoSnapshot().playing) {
            model.playing = false;
            fx.pauseVideo();
        } else if (fx.videoSnapshot().completed) {
            model.playing = true;
            fx.restartVideo();
        } else {
            model.playing = true;
            fx.playVideo();
        },
        .back => fx.seekVideo(model.position_ms -| seek_step_ms),
        .forward => fx.seekVideo(model.position_ms + seek_step_ms),
        .scrubbed => |fraction| if (model.duration_ms > 0) {
            const target: u64 = @intFromFloat(std.math.clamp(fraction, 0.0, 1.0) * @as(f64, @floatFromInt(model.duration_ms)));
            model.position_ms = target;
            fx.seekVideo(target);
        },
        .set_volume => |volume| {
            model.volume = std.math.clamp(volume, 0.0, 1.0);
            fx.setVideoVolume(model.volume);
        },
        .toggle_mute => {
            model.muted = !model.muted;
            fx.setVideoMuted(model.muted);
        },
        .toggle_loop => {
            model.looping = !model.looping;
            fx.setVideoLoop(model.looping);
        },
        .video_event => |event| model.record(event),
    }
}

// ------------------------------------------------------------------- view

pub const PlayerUi = canvas.Ui(Msg);

pub fn formatClock(arena: std.mem.Allocator, ms: u64) []const u8 {
    const total_seconds = ms / 1000;
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const seconds = total_seconds % 60;
    if (hours > 0) {
        return std.fmt.allocPrint(arena, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "0:00";
    }
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ minutes, seconds }) catch "0:00";
}

pub fn view(ui: *PlayerUi, model: *const Model) PlayerUi.Node {
    // Bottom chrome anchors like a real app's: the page padding wraps
    // only the CONTENT column, and the status bar is the root column's
    // last child — full-bleed to the window's left/right/bottom edges,
    // its own horizontal padding, its hairline top separator from the
    // theme tokens.
    return ui.column(.{ .gap = 0, .style_tokens = .{ .background = .background } }, .{
        ui.column(.{ .gap = 12, .padding = 16, .grow = 1 }, .{
            ui.row(.{ .gap = 8, .cross = .center }, .{
                ui.text(.{ .size = .lg }, "Video Player"),
                ui.spacer(1),
                ui.el(.button_group, .{}, .{
                    ui.el(.toggle_button, .{ .selected = model.screen == .player, .on_toggle = .show_player, .text = "Player" }, .{}),
                    ui.el(.toggle_button, .{ .selected = model.screen == .custom, .on_toggle = .show_custom, .text = "Custom" }, .{}),
                }),
            }),
            ui.row(.{ .gap = 8, .cross = .center }, .{
                ui.el(.search_field, .{
                    .grow = 1,
                    .text = model.source_field.text(),
                    .placeholder = "file path or http(s) url",
                    .on_input = PlayerUi.inputMsg(.source_edit),
                    .on_submit = .open,
                    .semantics = .{ .label = "Source" },
                }, .{}),
                ui.button(.{ .variant = .primary, .on_press = .open, .disabled = model.source_field.text().len == 0 }, "Open"),
            }),
            switch (model.screen) {
                .player => playerScreen(ui, model),
                .custom => customScreen(ui, model),
            },
        }),
        // Each screen's status line matches its ownership model: the
        // declarative screen has no event-fed state to report, the
        // custom screen reports exactly what its events told it.
        ui.statusBar(.{}, switch (model.screen) {
            .player => model.playerHint(),
            .custom => model.statusText(ui.arena),
        }),
    });
}

/// The declarative screen: one element carries the whole player — the
/// committed source loads the single playback and the house chrome
/// drives it. Empty source renders the bare placeholder surface.
fn playerScreen(ui: *PlayerUi, model: *const Model) PlayerUi.Node {
    return ui.video(.{
        .src = model.opened(),
        .controls = true,
        .grow = 1,
        .label = "Feature video",
    });
}

/// The custom screen: the audio pattern — a bare surface the app's own
/// loadVideo claimed, and a transport bar composed from the command
/// vocabulary. The model mirrors only what events told it.
fn customScreen(ui: *PlayerUi, model: *const Model) PlayerUi.Node {
    const active = model.status != null and model.status != .failed and model.status != .rejected;
    // A finished playback's player is retired: seeks refuse and the
    // thumb would spring back, so the seek-family controls go dead —
    // Play stays live and restarts from the start.
    const seekable = active and model.status != .completed;
    const fraction: f32 = if (model.duration_ms > 0)
        @floatCast(@as(f64, @floatFromInt(model.position_ms)) / @as(f64, @floatFromInt(model.duration_ms)))
    else
        0;
    return ui.column(.{ .grow = 1, .gap = 0, .style_tokens = .{ .background = .surface, .radius = .lg } }, .{
        ui.mediaSurface(.{ .image = custom_surface, .grow = 1, .semantics = .{ .label = "Custom player video" } }),
        ui.row(.{ .padding = 10, .gap = 8, .cross = .center }, .{
            ui.button(.{ .variant = .ghost, .size = .sm, .icon = "skip-back", .on_press = .back, .disabled = !seekable, .semantics = .{ .label = "Back 10 seconds" } }, ""),
            ui.button(.{ .variant = .ghost, .size = .sm, .icon = if (model.playing) "pause" else "play", .on_press = .toggle_play, .disabled = !active, .semantics = .{ .label = if (model.playing) "Pause" else "Play" } }, ""),
            ui.button(.{ .variant = .ghost, .size = .sm, .icon = "skip-forward", .on_press = .forward, .disabled = !seekable, .semantics = .{ .label = "Forward 10 seconds" } }, ""),
            ui.text(.{ .size = .sm, .width = 52, .wrap = false, .overflow = .clip, .style_tokens = .{ .foreground = .text_muted } }, formatClock(ui.arena, model.position_ms)),
            ui.el(.slider, .{ .grow = 1, .value = fraction, .disabled = !seekable, .on_value = PlayerUi.valueMsg(.scrubbed), .semantics = .{ .label = "Seek" } }, .{}),
            ui.text(.{ .size = .sm, .width = 52, .wrap = false, .overflow = .clip, .style_tokens = .{ .foreground = .text_muted } }, formatClock(ui.arena, model.duration_ms)),
            ui.el(.toggle_button, .{ .selected = model.looping, .on_toggle = .toggle_loop, .icon = "repeat", .semantics = .{ .label = "Loop" } }, .{}),
            ui.el(.toggle_button, .{ .selected = model.muted, .on_toggle = .toggle_mute, .icon = "volume", .semantics = .{ .label = "Mute" } }, .{}),
            ui.el(.slider, .{ .width = 90, .value = model.volume, .on_value = PlayerUi.valueMsg(.set_volume), .semantics = .{ .label = "Volume" } }, .{}),
        }),
    });
}

// -------------------------------------------------------------------- app

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(PlayerApp);
    defer std.heap.page_allocator.destroy(app_state);

    // The launch argument is the source: a local clip path or an
    // http(s) URL (no media ships with the example).
    var model = Model{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // the executable path
    if (args.next()) |source| {
        model.setOpened(source);
        model.source_field.set(source);
    }

    app_state.* = PlayerApp.init(std.heap.page_allocator, model, .{
        .name = "video-player",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .view = view,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "video-player",
        .window_title = "Video Player",
        .bundle_id = "dev.native_sdk.video_player",
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
