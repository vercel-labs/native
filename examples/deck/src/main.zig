//! deck: the radically skinned sibling of `examples/soundboard` — the same
//! local music player (albums, tracks, transport, seek, queue, search)
//! wearing vintage rack-unit hardware identity, in the true two-window
//! shape: a SMALL, FIXED player window (the window IS the device —
//! CHROMELESS, so the enamel cap band is the drag region and carries
//! the skin's own working close/minimize keys) and a matching playlist
//! unit declared through `windows_fn` while the model says it is open
//! (the PL key and `primary+L` flip the flag).
//! Everything visual comes from the deck theme's design tokens plus
//! Zig-drawn chrome (the `ui.chart` spectrum, pixel-face readouts, the
//! seven-segment elapsed readout, the volume knob face) — pure fills,
//! lines, gradients, and paths; this skin ships no bitmap texture
//! assets, and nothing forks the engine. Playback is REAL: the audio
//! effect channel drives the platform player over the shared committed
//! catalog (the mp3s live once, in the soundboard's gitignored assets),
//! and a failed load lands the honest NO MEDIA remedy on the display
//! instead of a crash or silence.
//!
//! Authoring split (markup where it fits): the playlist's status strip is
//! a `.native` view compiled at comptime; the faceplate and the playlist
//! rack are Zig views because they need what the closed markup grammar
//! deliberately excludes — the chart widget, scaled mono spans, per-row
//! native context menus, and the registered-image cover leaf.

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

pub const playlist_window_label = model_mod.playlist_window_label;
pub const playlist_canvas_label = "playlist-canvas";

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Deck canvas", .accessibility_label = "Deck music player", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = model_mod.main_window_label,
    .title = "Native SDK Deck",
    .width = window_width,
    .height = window_height,
    // The player is a piece of hardware: fixed size (the chrome pass
    // machines absolute geometry) and NO OS chrome at all — the
    // explicit `chromeless` opt-in, honest here because the enamel cap
    // band is the drag region AND carries the skin's own working
    // close/minimize keys (wired to the real window-action effects).
    // Apps that do not draw their own controls should use the hidden
    // styles instead, which keep the real OS buttons.
    .resizable = false,
    .titlebar = .chromeless,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// -------------------------------------------------------------- app icons

/// The deck's own vector glyphs, parsed at comptime from the common
/// stroke-icon dialect (24x24, stroke-width 2, currentColor): the
/// transport STOP square (the built-in set carries every other
/// transport verb but no square, and this skin refuses a text-labeled
/// stop key) and the cap band's MINIMIZE bar (the chromeless windows
/// draw their own window controls; the built-in set has no minus).
const stop_icon = canvas.svg_icon.parseComptime(@embedFile("icons/stop.svg"));
const minimize_icon = canvas.svg_icon.parseComptime(@embedFile("icons/minimize.svg"));

/// The registered icon table: ONE declaration feeds boot-time
/// registration (`registerIcons`, called from main and the test
/// harness) AND the model contract's `app_icons` list, so `app:<name>`
/// references are verified by `native check` against exactly what the
/// app registers.
pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "stop", .icon = &stop_icon },
    .{ .name = "minimize", .icon = &minimize_icon },
};

/// Install the app icon table; once, before views build (main does it
/// first thing, and the tests' harness setup mirrors it).
pub fn registerIcons() void {
    canvas.icons.registerAppIcons(&app_icons);
}

// ---------------------------------------------------------------- covers

/// Album cover image ids ARE the album ids (1-based): the covers are
/// the only registered images this app carries — 8 of the runtime's 16
/// slots. (An earlier round also registered two bitmap chassis
/// textures; the vintage-enamel skin draws its texture with fills,
/// lines, and gradients instead, so the image channel is covers-only.)
pub fn coverImageId(album_id: u8) canvas.ImageId {
    return album_id;
}

/// Boot effect: decode and register every album's committed cover from
/// the manifest's art slots. Registration is synchronous on the effects
/// channel; ids reach the model only on success, so a failed decode
/// leaves that surface on its vector fallback (the art bay and sleeve
/// pane stay engraved plates) — a bad asset can never break
/// presentation. The covers are JPEG: live macOS decodes them through
/// the platform codec, while the null platform's strict test decoder
/// refuses them and the suite pins the degrade instead.
pub fn boot(model: *Model, fx: *model_mod.Effects) void {
    inline for (model_mod.albums, 0..) |album, index| {
        if (album.art) |art_path| {
            const image_id = coverImageId(album.id);
            if (fx.registerImageBytes(image_id, @embedFile(art_path))) |_| {
                model.covers[index] = image_id;
            } else |_| {}
        }
    }
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

/// The media-app space convention: SPACE toggles the transport from
/// anywhere — both windows, focused or not. Bare space cannot be a
/// chrome shortcut (unmodified character keys and space are rejected by
/// `validateShortcut` so registration can never steal typing), so it
/// rides the app-level key FALLBACK instead: the framework's precedence
/// rule runs first, meaning a focused ledger row consumes space to play
/// THAT row, a focused transport button activates itself, and a focused
/// editable field keeps typing spaces — the text-entry exception is
/// structural (by widget kind), so the playlist's search field blocks
/// the toggle without this function naming it. `primary+P` (the chrome
/// shortcut above) stays the works-even-while-typing chord.
pub fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.modifiers.hasNavigationModifier() or keyboard.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "space")) return .toggle_play;
    return null;
}

// -------------------------------------------------------------------- app

pub const DeckApp = native_sdk.UiApp(Model, Msg);

// ------------------------------------------------------------------ fonts

/// The deck's primary text face: Geist Pixel (Square), committed at
/// src/fonts/ with its OFL license and registered at boot through the
/// app-fonts seam — the theme's typography tokens point BOTH face slots
/// at this id (see theme.zig), so every span on the fascia prints in
/// the pixel face. The face is TrueType-glyf and well inside the
/// registry's per-font byte budget.
pub const app_fonts = [_]DeckApp.FontRegistration{.{
    .id = theme.primary_font_id,
    .name = "GeistPixel-Square.ttf",
    .ttf = @embedFile("fonts/GeistPixel-Square.ttf"),
}};

pub fn deckOptions() DeckApp.Options {
    return .{
        .name = "deck",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .view = rootView,
        .fonts = &app_fonts,
        .tokens_fn = tokensFromModel,
        // The sculpted hardware layer: enamel chassis and cap band,
        // bevels, wells, screws, scanlines, the seven-segment readout,
        // the band ladders, and the volume knob face — a fixed-count
        // display-list pass drawn behind (prefix) and in front of
        // (suffix) the widgets. See chrome.zig.
        .chrome = .{
            .prefix_commands = chrome.prefix_commands,
            .suffix_commands = chrome.suffix_commands,
            .build = chrome.build,
        },
        // The playlist rack: presence in the declared set IS visibility.
        .windows_fn = deckWindows,
        .window_view = deckWindowView,
        .on_appearance = onAppearance,
        .on_command = command,
        .on_key = onKey,
        .on_frame = onFrame,
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
            // A matching rack unit: fixed size and chromeless like the
            // player — its cap strip is the drag region and carries the
            // skin's own working close/minimize keys.
            .resizable = false,
            .titlebar = .chromeless,
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

/// One finish, by the brief: hardware has exactly one enamel, so the OS
/// color scheme never reaches the theme. The appearance still matters
/// for high contrast (which abandons the skin for the framework
/// palette) and reduce motion.
pub fn tokensFromModel(model: *const Model) canvas.DesignTokens {
    return theme.tokens(model.appearance.high_contrast, model.appearance.reduce_motion);
}

/// Appearance changes land in the model so `tokens_fn` re-derives; only
/// contrast and motion are consumed (see `tokensFromModel`).
fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return Msg{ .set_appearance = appearance };
}

/// The frame clock, WHILE PLAYING ONLY (the soundboard idiom): each
/// presented frame's timestamp advances the rendered playback clock
/// (`advanceRenderedClock`), whose changed spectrum/marquee/timecode
/// present the next frame — the dispatch loop sustains itself exactly
/// as long as audio moves. Pause, stop, buffering, or idle return null,
/// the display list stops changing, and the frame channel starves on
/// its own: zero frames while nothing moves (the idle law), with no
/// arming flag to forget to clear. Journaled like every Msg, so replay
/// is deterministic.
pub fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (model.playing and model.now != null and !model.buffering) {
        return Msg{ .frame_clock = .{ .timestamp_ns = frame.timestamp_ns, .interval_ns = frame.frame_interval_ns } };
    }
    return null;
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
    // The app icon table installs before any view builds.
    registerIcons();
    // Streaming configuration, resolved once at launch (same story as
    // the soundboard): NATIVE_SDK_MUSIC_URL_BASE overrides the
    // manifest's committed base, and the platform caches directory
    // hosts the track cache in its audio/ child — delete it to clear.
    // Launch-time only, so replay's deterministic-init contract holds:
    // no env read ever happens inside update.
    var model: Model = .{};
    if (init.environ_map.get("NATIVE_SDK_MUSIC_URL_BASE")) |base| model.setUrlBase(base);
    var cache_dir_buffer: [model_mod.max_cache_dir]u8 = undefined;
    const cache_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = "deck" },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .cache,
        &cache_dir_buffer,
    ) catch "";
    model.setCacheDir(cache_dir);
    const app_state = try std.heap.page_allocator.create(DeckApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = DeckApp.init(std.heap.page_allocator, model, deckOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "deck",
        .window_title = "Native SDK Deck",
        .bundle_id = "dev.native_sdk.deck",
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
