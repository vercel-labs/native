//! menu-bar: the menu-bar app lifecycle in one small player.
//!
//! The Spotify-shaped loop, end to end: the window declares
//! `close_policy = "hide"` in app.zon, so the red close button hides it
//! and the app keeps running behind its status item; the tray's
//! "Open Player" row dispatches a command the model maps to
//! `fx.showWindow`, "Quit" maps to `fx.quitApp` (the real graceful
//! terminate), and the macOS Dock reopen re-shows the hidden window on
//! its own. The status-item title is model-driven, so the menu bar
//! shows the transport state even while the window is hidden.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "player-canvas";
pub const window_label = "main";
const window_width: f32 = 420;
const window_height: f32 = 260;

pub const open_command = "app.open";
pub const quit_command = "app.quit";
pub const toggle_command = "player.toggle";
pub const next_command = "player.next";

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Menu bar player", .accessibility_label = "Menu bar player", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = window_label,
    .title = "Menu Bar Player",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    // Keep the SAME declaration app.zon threads to the host create, so
    // the scene and the startup window never disagree.
    .close_policy = .hide,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const tracks = [_][]const u8{
    "Ambient Coast",
    "Night Drive",
    "Paper Planes",
};

pub const Model = struct {
    playing: bool = false,
    track: usize = 0,

    pub fn trackTitle(model: *const Model) []const u8 {
        return tracks[model.track];
    }
};

pub const Msg = union(enum) {
    toggle_play,
    next_track,
    /// The tray "Open Player" consequence: un-hide + activate the main
    /// window (also what a Dock reopen does host-side, without a Msg).
    open_player,
    /// The tray "Quit" consequence: the REAL graceful terminate — the
    /// same shutdown path closing the last window of a .quit app takes.
    quit,
};

const PlayerApp = native_sdk.UiApp(Model, Msg);
pub const Effects = PlayerApp.Effects;

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .toggle_play => model.playing = !model.playing,
        .next_track => model.track = (model.track + 1) % tracks.len,
        .open_player => fx.showWindow(window_label),
        .quit => fx.quitApp(),
    }
}

// ------------------------------------------------------------------- view

pub const PlayerUi = canvas.Ui(Msg);

pub fn view(ui: *PlayerUi, model: *const Model) PlayerUi.Node {
    return ui.column(.{ .gap = 12, .padding = 16, .style_tokens = .{ .background = .background } }, .{
        ui.text(.{ .size = .lg }, model.trackTitle()),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, if (model.playing) "Playing" else "Paused"),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .variant = .primary, .on_press = .toggle_play }, if (model.playing) "Pause" else "Play"),
            ui.button(.{ .on_press = .next_track }, "Next"),
        }),
        ui.spacer(1),
        ui.statusBar(.{}, "Closing this window hides it - the menu-bar extra keeps playing."),
    });
}

// -------------------------------------------------------------- commands

/// Tray rows, window menus, and shortcuts all dispatch command NAMES;
/// the model maps them to Msgs here — the single command vocabulary.
pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, open_command)) return .open_player;
    if (std.mem.eql(u8, name, quit_command)) return .quit;
    if (std.mem.eql(u8, name, toggle_command)) return .toggle_play;
    if (std.mem.eql(u8, name, next_command)) return .next_track;
    return null;
}

/// The status-item menu: Open re-shows the hidden window, the transport
/// rows drive playback without ever showing it, Quit really quits.
pub const status_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Open Player", .command = open_command },
    .{ .separator = true },
    .{ .id = 2, .label = "Play/Pause", .command = toggle_command },
    .{ .id = 3, .label = "Next Track", .command = next_command },
    .{ .separator = true },
    .{ .id = 4, .label = "Quit", .command = quit_command },
};

/// Model-driven title: the menu bar reflects the transport state while
/// the window is hidden.
pub fn statusItem(model: *const Model, scratch: *PlayerApp.StatusItemScratch) PlayerApp.StatusItemState {
    _ = scratch;
    return .{
        .title = if (model.playing) "MB \u{25B6}" else "MB",
        .items = &status_items,
    };
}

pub fn options() PlayerApp.Options {
    return .{
        .name = "menu-bar",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .view = view,
        .on_command = command,
        .status_item = .{
            .title = "MB",
            .tooltip = "Menu Bar Player",
            .items = &status_items,
        },
        .status_item_fn = statusItem,
    };
}

// -------------------------------------------------------------------- app

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(PlayerApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = PlayerApp.init(std.heap.page_allocator, .{}, options());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "menu-bar",
        .window_title = "Menu Bar Player",
        .bundle_id = "dev.native_sdk.menu_bar",
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
