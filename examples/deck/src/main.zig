//! deck: the radically skinned sibling of `examples/soundboard` — the same
//! local music player (albums, tracks, transport, seek, queue, search)
//! wearing rack-unit hardware identity, in the true two-window shape: a
//! SMALL, FIXED player window (the window IS the device — hidden-inset
//! titlebar, the gold cap band as the drag region) and a matching
//! playlist rack unit declared through `windows_fn` while the model says
//! it is open (the PL key and `primary+L` flip the flag). Everything
//! visual comes from the deck theme's design tokens plus Zig-drawn chrome
//! (the `ui.chart` spectrum, mono paragraph readouts, the seven-segment
//! elapsed readout) over two small AI-generated textures registered
//! through the runtime image channel; nothing forks the engine. Playback
//! is soundboard's honest simulation: a repeating timer effect advances
//! the progress clock, no audio is decoded.
//!
//! Authoring split (markup where it fits): the playlist's status strip is
//! a `.zml` view compiled at comptime; the faceplate and the playlist
//! rack are Zig views because they need what the closed markup grammar
//! deliberately excludes — the chart widget, scaled mono spans, per-row
//! native context menus, and the registered-texture image leaf.

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
pub const window_width: f32 = view_mod.window_width;
pub const window_height: f32 = view_mod.window_height;

pub const playlist_window_label = "playlist";
pub const playlist_canvas_label = "playlist-canvas";

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Deck canvas", .accessibility_label = "Deck music player", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Deck",
    .width = window_width,
    .height = window_height,
    // The player is a piece of hardware: fixed size (the chrome pass
    // machines absolute geometry) and no OS titlebar — the gold cap
    // band is the drag region.
    .resizable = false,
    .titlebar = .hidden_inset,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------- textures

/// The two committed texture assets, AI-generated and packed into the
/// strict PNG subset (`tools/pack_textures.zig`; prompts in the README)
/// so they decode both live and under the deterministic test decoder.
pub const plate_texture_bytes = @embedFile("textures/plate.png");
pub const weave_texture_bytes = @embedFile("textures/weave.png");

pub const plate_texture_id: canvas.ImageId = 1;
pub const weave_texture_id: canvas.ImageId = 2;

/// Boot effect: decode and register both textures. Registration is
/// synchronous on the effects channel; ids reach the model only on
/// success, so a failed decode leaves the chrome pure vector (the
/// texture draw moves offscreen) — a bad asset can never break
/// presentation.
pub fn boot(model: *Model, fx: *model_mod.Effects) void {
    if (fx.registerImageBytes(plate_texture_id, plate_texture_bytes)) |_| {
        model.texture_plate = plate_texture_id;
    } else |_| {}
    if (fx.registerImageBytes(weave_texture_id, weave_texture_bytes)) |_| {
        model.texture_weave = weave_texture_id;
    } else |_| {}
}

// --------------------------------------------------------------- commands

// Shortcut command ids: registered in app.zon (`.shortcuts`), delivered as
// command events, mapped to Msgs here. One spelling, two homes: app.zon
// and this table (the README documents the bindings).
pub const cmd_play_pause = "deck.play-pause"; // primary+P
pub const cmd_next = "deck.next"; // primary+arrowright
pub const cmd_prev = "deck.prev"; // primary+arrowleft
pub const cmd_playlist = "deck.playlist"; // primary+L
pub const cmd_dismiss = "deck.dismiss"; // escape

pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, cmd_play_pause)) return .toggle_play;
    if (std.mem.eql(u8, name, cmd_next)) return .next_track;
    if (std.mem.eql(u8, name, cmd_prev)) return .prev_track;
    if (std.mem.eql(u8, name, cmd_playlist)) return .toggle_playlist;
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
        .init_fx = boot,
        .view = rootView,
        .tokens_fn = tokensFromModel,
        // The sculpted hardware layer: brushed plate texture, gold cap
        // band, bevels, wells, screws, scanlines, and the seven-segment
        // readout — a fixed-count display-list pass drawn behind
        // (prefix) and in front of (suffix) the widgets. See chrome.zig.
        .chrome = .{
            .prefix_commands = chrome.prefix_commands,
            .suffix_commands = chrome.suffix_commands,
            .build = chrome.build,
        },
        // The playlist rack: presence in the declared set IS visibility.
        .windows_fn = deckWindows,
        .window_view = deckWindowView,
        .on_appearance = onAppearance,
        .on_chrome = onChrome,
        .on_command = command,
        .sync = sync,
    };
}

/// The declared window set derives from the model: the playlist window
/// exists exactly while `playlist_open` is set. A Msg opens it, a Msg
/// closes it, and the user's titlebar close dispatches
/// `.playlist_closed` so the model agrees.
fn deckWindows(model: *const Model, scratch: *DeckApp.WindowsScratch) []const DeckApp.WindowDescriptor {
    var count: usize = 0;
    if (model.playlist_open) {
        scratch.windows[count] = .{
            .label = playlist_window_label,
            .canvas_label = playlist_canvas_label,
            .title = "Deck Playlist",
            .width = view_mod.playlist_width,
            .height = view_mod.playlist_height,
            // A matching rack unit: fixed size, its own cap strip as
            // the drag region.
            .resizable = false,
            .titlebar = .hidden_inset,
            .on_close = .playlist_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

fn deckWindowView(ui: *DeckApp.Ui, model: *const Model, window_label: []const u8) DeckApp.Ui.Node {
    std.debug.assert(std.mem.eql(u8, window_label, playlist_window_label));
    return view_mod.playlistView(ui, model);
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

/// Chrome overlay insets flow into the model (hidden-inset titlebar):
/// the cap band pads its leading edge so the brand engraving clears the
/// traffic lights; fullscreen zeroes it and the band reclaims the space.
fn onChrome(window_chrome: native_sdk.WindowChrome) ?Msg {
    return Msg{ .set_chrome_leading = window_chrome.insets.left };
}

/// The runtime owns transient slider state (`.change` carries no value);
/// mirror both faders into the model before each update so the `.seeked`
/// and `.volume_changed` arms read the positions the user dragged to.
/// Main canvas only — the playlist window has no sliders by design.
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
