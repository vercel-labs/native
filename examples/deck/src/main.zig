//! deck: the radically skinned sibling of `examples/soundboard` — the same
//! local music player (albums, tracks, transport, seek, queue, search)
//! wearing a rack-unit hardware identity. Everything visual comes from the
//! deck theme's design tokens plus Zig-drawn chrome (the `ui.chart`
//! spectrum, mono paragraph readouts); nothing forks the engine. Playback
//! is soundboard's honest simulation: a repeating timer effect advances
//! the progress clock, no audio is decoded.
//!
//! Authoring split (markup where it fits): the status strip is a `.zml`
//! view compiled at comptime; the faceplate, rail, and ledger are Zig
//! views because they need what the closed markup grammar deliberately
//! excludes — the chart widget, scaled mono spans, per-row native context
//! menus, and model-conditional plate styling.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const chrome = @import("chrome.zig");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const update = model_mod.update;
pub const rootView = view_mod.rootView;

pub const canvas_label = "deck-canvas";
pub const window_width: f32 = 960;
pub const window_height: f32 = 640;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Deck canvas", .accessibility_label = "Deck music player", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Deck",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// --------------------------------------------------------------- commands

// Shortcut command ids: registered in app.zon (`.shortcuts`), delivered as
// command events, mapped to Msgs here. One spelling, two homes: app.zon
// and this table (the README documents the bindings).
pub const cmd_play_pause = "deck.play-pause"; // primary+P
pub const cmd_next = "deck.next"; // primary+arrowright
pub const cmd_prev = "deck.prev"; // primary+arrowleft
pub const cmd_toggle_face = "deck.toggle-face"; // primary+K
pub const cmd_dismiss = "deck.dismiss"; // escape

pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, cmd_play_pause)) return .toggle_play;
    if (std.mem.eql(u8, name, cmd_next)) return .next_track;
    if (std.mem.eql(u8, name, cmd_prev)) return .prev_track;
    if (std.mem.eql(u8, name, cmd_toggle_face)) return .toggle_face;
    if (std.mem.eql(u8, name, cmd_dismiss)) return .clear_search;
    return null;
}

// -------------------------------------------------------------------- app

pub const DeckApp = native_sdk.UiApp(Model, Msg);

pub fn deckOptions() DeckApp.Options {
    return .{
        .name = "deck",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .view = rootView,
        .tokens_fn = tokensFromModel,
        // The sculpted hardware layer: brushed chassis, gold plates,
        // bevels, wells, screws, scanlines, and the seven-segment
        // readout — a fixed-count display-list pass drawn behind
        // (prefix) and in front of (suffix) the widgets. See chrome.zig.
        .chrome = .{
            .prefix_commands = chrome.prefix_commands,
            .suffix_commands = chrome.suffix_commands,
            .build = chrome.build,
        },
        .on_appearance = onAppearance,
        .on_command = command,
        .sync = sync,
    };
}

/// Dark-only by the brief: the OS color scheme never reaches the theme.
/// The appearance still matters for high contrast (which abandons the
/// skin for the framework palette) and reduce motion.
pub fn tokensFromModel(model: *const Model) canvas.DesignTokens {
    return theme.tokens(model.appearance.high_contrast, model.appearance.reduce_motion);
}

/// Appearance changes land in the model so `tokens_fn` re-derives; only
/// contrast and motion are consumed (see `tokensFromModel`).
fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return Msg{ .set_appearance = appearance };
}

/// The runtime owns transient slider state (`.change` carries no value);
/// mirror both faders into the model before each update so the `.seeked`
/// and `.volume_changed` arms read the positions the user dragged to.
fn sync(model: *Model, layout: canvas.WidgetLayoutTree) void {
    for (layout.nodes) |node| {
        if (node.widget.kind != .slider) continue;
        if (std.mem.eql(u8, node.widget.semantics.label, "Seek")) {
            model.seek_fraction = node.widget.value;
        } else if (std.mem.eql(u8, node.widget.semantics.label, "Volume")) {
            model.volume_fraction = node.widget.value;
        }
    }
}

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(DeckApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = DeckApp.init(std.heap.page_allocator, .{}, deckOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "deck",
        .window_title = "Native SDK Deck",
        .bundle_id = "dev.native_sdk.deck",
        .icon_path = "assets/icon.icns",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
