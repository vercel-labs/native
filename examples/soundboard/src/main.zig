//! soundboard: a music-library browser showcasing native-rendered
//! Native SDK UI — the committed music catalog with real cover art
//! through the runtime image pipeline, track lists with native context
//! menus, a now-playing bar with REAL audio playback through the runtime
//! audio effect family, search, and a custom light/dark theme.
//!
//! Authoring split (markup-first, two shells): the header and
//! now-playing bars are `.native` views compiled at comptime; the album
//! grid, album detail, and track rows are Zig views because they need
//! what the closed markup grammar deliberately excludes — square cover
//! images, grid column counts, scaled paragraph headings, and per-row
//! native context menus. `src/view.zig` composes both kinds under one
//! root — the DESKTOP shell — and recomposes the same shared content
//! pieces into a COMPACT shell for phone-class surfaces (the root view
//! switches on the model's form factor: host-reported size class when
//! present, width-derived as the fallback). Widget identity,
//! dispatch, and theming behave exactly as in a single-source view in
//! both shells.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const update = model_mod.update;
pub const rootView = view_mod.rootView;

pub const canvas_label = "soundboard-canvas";
pub const window_width: f32 = 1080;
pub const window_height: f32 = 720;
/// Content min-size floor the window enforces: the smallest size where
/// the header, album grid, and now-playing rail lay out without clipping
/// or overlap — proven by the layout audit sweep in tests.zig, which
/// sweeps from exactly this floor. The model owns the value because it
/// doubles as the pre-first-frame `canvas_width` default the adaptive
/// album grid derives from.
pub const window_min_width: f32 = model_mod.min_canvas_width;
pub const window_min_height: f32 = 600;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Music library canvas", .accessibility_label = "Soundboard music library", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Soundboard",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    // Tall hidden-inset titlebar (declared in app.zon too, which threads
    // it through the STARTUP window create): the header bar IS the
    // titlebar — it pads its leading edge past the traffic lights via
    // `on_chrome` and is the window's drag surface (`window-drag` in
    // header.native).
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// -------------------------------------------------------------- app icons

/// The app's own vector icon, parsed at comptime from the common
/// stroke-icon dialect (24x24, stroke-width 2, currentColor). Lives
/// under src/ so `@embedFile` reaches it from the module root (and the
/// contract's source hash covers icon changes-adjacent code).
const waveform_icon = canvas.svg_icon.parseComptime(@embedFile("icons/waveform.svg"));

/// The album-grid glyph for the declared mobile tab bar (a 2x2 tile
/// grid): tab icons come from the registered app-icon vocabulary, so
/// the projected native bar tints the app's own artwork.
const albums_icon = canvas.svg_icon.parseComptime(@embedFile("icons/albums.svg"));

/// The registered icon table: ONE declaration feeds boot-time
/// registration (`registerIcons`, called from main and the test
/// harness) AND the model contract's `app_icons` list (the emit step
/// reflects this decl), so markup `app:<name>` references are verified
/// by `native check` against exactly what the app registers.
pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "waveform", .icon = &waveform_icon },
    .{ .name = "albums", .icon = &albums_icon },
};

/// Install the app icon table; once, before views build (main does it
/// first thing, and the tests' harness setup mirrors it).
pub fn registerIcons() void {
    canvas.icons.registerAppIcons(&app_icons);
}

// ------------------------------------------------------------------ covers

/// The committed album art, embedded at comptime from the paths the
/// music manifest names (relative to src/, like the manifest says).
/// Index = album id - 1; the registered `ImageId` equals the album id.
/// Albums whose manifest slot is null carry no bytes and simply keep
/// their initials fallback.
pub const cover_bytes: [model_mod.albums.len]?[]const u8 = blk: {
    var out: [model_mod.albums.len]?[]const u8 = undefined;
    for (model_mod.albums, 0..) |album, index| {
        out[index] = if (album.art) |art_path| @embedFile(art_path) else null;
    }
    break :blk out;
};

/// Boot effect: decode and register every committed cover. Registration
/// is synchronous on the effects channel; ids reach the model only on
/// success, so a failed decode leaves that album on its initials
/// fallback — a bad asset can never break presentation. The art is JPEG:
/// live macOS decodes it through the platform codec, while the null
/// platform's strict test decoder (a PNG subset) cannot — under tests
/// every album degrades to initials honestly, which the suite pins.
pub fn boot(model: *Model, fx: *model_mod.Effects) void {
    for (cover_bytes, 1..) |maybe_bytes, album_id| {
        const bytes = maybe_bytes orelse continue;
        _ = fx.registerImageBytes(@intCast(album_id), bytes) catch continue;
        model.covers[album_id - 1] = @intCast(album_id);
    }
}

// -------------------------------------------------------------------- app

pub const SoundboardApp = native_sdk.UiApp(Model, Msg);

pub fn soundboardOptions() SoundboardApp.Options {
    return .{
        .name = "soundboard",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .view = rootView,
        .init_fx = boot,
        .tokens_fn = tokensFromModel,
        .on_appearance = onAppearance,
        .on_chrome = onChrome,
        .on_key = onKey,
        .on_frame = onFrame,
        .animations = animations,
        .sync = sync,
    };
}

/// The media-app keyboard conventions, all through the app-level key
/// FALLBACK (`on_key`), so the framework's precedence rule applies
/// before any of them fire: a RING-focused widget consumes its own keys
/// (a tabbed-to row selects on Space and plays on Enter, a slider takes
/// the arrows), and a focused editable field keeps typing — the
/// text-entry exception is structural (checked by widget kind in the
/// runtime), so the header's search field blocks all of these without
/// this function knowing it exists. A QUIETLY focused track row (the
/// state a click leaves behind) is transparent to keys by the
/// framework's quiet-list-row rule, so after clicking around the
/// library these still work app-wide:
///   - SPACE toggles the transport;
///   - Up/Down ARROWS move the SELECTION (the accent row), never
///     playback and never the focus ring — outlines belong to Tab;
///   - ENTER plays the selected track (pause toggle when it is the
///     loaded one).
pub fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.modifiers.hasNavigationModifier() or keyboard.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "space")) return .toggle_play;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return .select_next;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return .select_previous;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "enter")) return .play_selected;
    return null;
}

/// Chrome overlay geometry flows into the model (tall hidden-inset
/// titlebar): delivered before the first view build and again when it
/// changes — entering fullscreen hides the traffic lights and this goes
/// to zero.
pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

/// Design tokens derive from the model's theme preference plus the
/// OS-reported appearance (scheme, contrast, reduced motion).
pub fn tokensFromModel(model: *const Model) canvas.DesignTokens {
    return theme.tokens(model.colorScheme(), model.appearance.high_contrast, model.appearance.reduce_motion);
}

/// System appearance changes land in the model so `tokens_fn` re-derives;
/// the `auto` theme preference follows them live.
fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return Msg{ .set_appearance = appearance };
}

/// The per-frame hook carries two channels, both gated so the idle law
/// holds (an idle app presents zero frames):
///
/// 1. The album grid's width channel: a WIDTH CHANGE (a live window
///    resize, fullscreen) dispatches into the model so the grid
///    re-derives its column count on the very next rebuild. The
///    one-frame lag is inherent and invisible: the resize-triggered
///    rebuild still lays out with the previous width, then the frame it
///    presents delivers the new one and the corrected grid is on screen
///    a frame later.
///
/// 2. The smooth-scrubber frame clock, WHILE PLAYING ONLY: each
///    presented frame's timestamp advances the rendered playback clock
///    (`advanceRenderedClock`), whose changed scrubber presents the
///    next frame — the dispatch loop sustains itself exactly as long as
///    audio moves. Pause, stop, buffering, or idle return null, the
///    display list stops changing, and the frame channel starves on its
///    own: zero frames while nothing moves, with no arming flag to
///    forget to clear.
pub fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (frame.size.width != model.canvas_width) {
        return Msg{ .canvas_resized = frame.size.width };
    }
    if (model.playing and model.now != null and !model.buffering) {
        return Msg{ .frame_clock = .{ .timestamp_ns = frame.timestamp_ns, .interval_ns = frame.frame_interval_ns } };
    }
    return null;
}

/// The runtime owns transient slider state (`.change` carries no value);
/// mirror the seek slider's reconciled value into the model before each
/// update so the `.seeked` arm reads the position the user dragged to.
fn sync(model: *Model, layout: canvas.WidgetLayoutTree) void {
    for (layout.nodes) |node| {
        if (node.widget.kind == .slider) model.seek_fraction = node.widget.value;
    }
}

// ------------------------------------------------------------- animations

/// Subtle track-change motion: the now-playing title and cover fade/slide
/// in for a ~240 ms window after a track starts. The window is gated on
/// the PLAYBACK clock (`elapsed_ms`, which restarts on every track
/// change and advances with the player's position events), so later
/// rebuilds do not restart it and the same Msg sequence replays the same
/// animation set — no live clock read anywhere; reduce-motion zeroes the
/// durations through the theme.
const motion_window_ms: u32 = 240;

pub fn animations(model: *const Model, tree: *const SoundboardApp.Ui.Tree, start_ns: u64, out: []canvas.CanvasRenderAnimation) usize {
    if (model.now == null) return 0;
    if (model.elapsed_ms > motion_window_ms) return 0;
    const motion = tokensFromModel(model).motion;

    var count: usize = 0;
    if (findByLabel(tree.root, "Now playing title")) |title| {
        count += slideIn(motion, title.id, text_slot, start_ns, out[count..]);
    }
    if (findByLabel(tree.root, "Now playing cover")) |cover| {
        count += slideIn(motion, cover.id, fill_slot, start_ns, out[count..]);
        count += slideIn(motion, cover.id, image_slot, start_ns, out[count..]);
    }
    return count;
}

// Widget display-list part slots (`canvas.widgetCommandPartId`).
const fill_slot: canvas.ObjectId = 1;
const image_slot: canvas.ObjectId = 3;
const text_slot: canvas.ObjectId = 4;

fn slideIn(motion: anytype, widget_id: canvas.ObjectId, slot: canvas.ObjectId, start_ns: u64, out: []canvas.CanvasRenderAnimation) usize {
    if (out.len == 0) return 0;
    out[0] = motion.animation(.{
        .id = canvas.widgetCommandPartId(.{ .widget_id = widget_id, .slot = slot }),
        .start_ns = start_ns,
        .duration = .fast,
        .from_opacity = 0.3,
        .to_opacity = 1,
        .from_transform = canvas.Affine.translate(0, 5),
        .to_transform = canvas.Affine.identity(),
    });
    return 1;
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
    }
    return null;
}

// ----------------------------------------------------------------- mobile

/// Mobile embed seam: the same Model/Msg/update/view compiled into the
/// embed static library (`zig build lib`, which `native dev --target
/// ios` drives) with the canonical single-surface mobile scene. The
/// desktop window constants above — size, min size, the tall titlebar —
/// belong to the DESKTOP scene only: the mobile scene is the full-screen
/// surface the host owns, so nothing here constrains the phone. The
/// model seeds its pre-first-frame canvas width at a phone-portrait
/// value so the installing frame already composes the compact shell; the
/// first presented frame corrects it, exactly like the desktop seed.
pub fn initModel() Model {
    // The mobile host has no main(): the icon table installs here, once,
    // before any view builds (registration is idempotent — one static
    // table — so the test harness's own install never conflicts).
    registerIcons();
    var model: Model = .{ .canvas_width = model_mod.compact_seed_canvas_width };
    // Streaming configuration, resolved once at boot exactly like the
    // desktop main() below — replay's deterministic-init contract holds
    // on phones too: no env read ever happens inside update. Without
    // this, every `fx.playAudio` would carry an empty cache_path and a
    // streamed track would re-download on every single play; with it,
    // the platform cache-fill installs the verified bytes under the
    // resolved directory's audio/ child and the next play is local.
    if (embedEnvValue("NATIVE_SDK_MUSIC_URL_BASE")) |base| model.setUrlBase(base);
    var cache_dir_buffer: [model_mod.max_cache_dir]u8 = undefined;
    const cache_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = "soundboard" },
        native_sdk.app_dirs.currentPlatform(),
        embedEnv(),
        .cache,
        &cache_dir_buffer,
    ) catch "";
    model.setCacheDir(cache_dir);
    return model;
}

/// The embed entry's environment for directory resolution: there is no
/// `std.process.Init` on this path (the host library calls `initModel()`
/// directly), so instead of `native_sdk.debug.envFromMap` over an owned
/// env map the values come from the process environment through libc.
/// Both phone platforms publish the app's directory namespace there
/// before any app code runs — iOS processes get HOME (the sandbox
/// container root) and TMPDIR from the OS itself, and the toolkit's
/// Android host exports HOME (the app data directory) and TMPDIR (its
/// cache/ child) in its activity's onCreate — and HOME/TMPDIR are the
/// only keys the phone resolvers read, so the desktop-only keys stay
/// null. A build that cannot reach `getenv` (see `embed_env_readable`)
/// has no environment to read: resolution fails honestly and the cache
/// stays disabled ("" — streaming still plays, each play just
/// re-downloads).
fn embedEnv() native_sdk.app_dirs.Env {
    return .{
        .home = embedEnvValue("HOME"),
        .tmpdir = embedEnvValue("TMPDIR"),
    };
}

/// Whether this compilation can emit a `getenv` call at all. The embed
/// static library declares no libc of its own (the Android slice
/// cross-compiles pure-Zig, without an NDK sysroot, so `std.c` symbols
/// are refused at compile time and `link_libc` is false) — but on the
/// phone targets the enclosing host process always links the system C
/// runtime (iOS apps link it unconditionally; the Android static lib
/// lands inside the host .so, which links bionic), so a plain extern
/// reference below resolves at the host link and the read is safe.
/// Everywhere else the call is emitted only when libc is actually
/// linked, so a libc-less desktop test build still links.
const embed_env_readable = builtin.link_libc or
    builtin.os.tag == .ios or
    (@hasField(@TypeOf(builtin.abi), "android") and builtin.abi == .android);

/// libc's environment lookup, declared as a bare external symbol (not
/// through `std.c`, whose declarations demand a declared libc
/// dependency): the symbol stays unreferenced unless
/// `embed_env_readable` holds, and where it holds the final link always
/// carries the C runtime that defines it.
extern fn getenv(name: [*:0]const u8) ?[*:0]u8;

/// One env read on the embed path (gated, see `embed_env_readable`). A
/// set but empty value comes back as "" — exactly what an env map's
/// `get` reports — so set-empty semantics (an empty URL base disables
/// streaming) match the desktop launch path.
fn embedEnvValue(name: [*:0]const u8) ?[]const u8 {
    if (comptime !embed_env_readable) return null;
    const value = getenv(name) orelse return null;
    return std.mem.span(value);
}

/// Declared platform chrome for the mobile scene: the Albums/Songs
/// navigation as a REAL system tab bar (the canonical music-app shape).
/// The ids are command ids — a projected tap dispatches them through
/// `onCommand` into the same `show_albums`/`show_songs` Msgs the
/// in-canvas switcher sends, and `selectedTab` mirrors `model.tab` back
/// so the bar always projects the model. No primary floating action on
/// purpose: the transport lives in the mini player bar, and a floating
/// play control would project playback twice.
const mobile_tab_albums_command = "tabs.albums";
const mobile_tab_songs_command = "tabs.songs";

/// The platform back command: a completed edge-swipe-back on the album
/// detail dispatches this id, which maps onto the exact `close_album`
/// Msg the in-canvas back button sends — the gesture and the button are
/// indistinguishable in the journal. A cancelled swipe dispatches
/// nothing.
const mobile_nav_back_command = "nav.back";

const mobile_chrome_tabs = [_]native_sdk.ShellTab{
    .{ .id = mobile_tab_albums_command, .label = "Albums", .icon = "app:albums" },
    .{ .id = mobile_tab_songs_command, .label = "Songs", .icon = "music" },
};

/// The canonical single-surface mobile scene plus the declared chrome.
const mobile_scene: native_sdk.ShellConfig = .{
    .windows = native_sdk.embed.mobile_shell_scene.windows,
    .chrome = .{ .tabs = &mobile_chrome_tabs },
};

/// Projected chrome taps arrive as command events with the declared
/// tab ids; they map onto the exact Msgs the canvas switcher dispatches,
/// so the two entry points are indistinguishable in the journal.
pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, mobile_tab_albums_command)) return .show_albums;
    if (std.mem.eql(u8, name, mobile_tab_songs_command)) return .show_songs;
    if (std.mem.eql(u8, name, mobile_nav_back_command)) return .close_album;
    return null;
}

/// The model's selected tab as its declared command id — the projection
/// the native bar mirrors (an open album detail is still the Albums
/// tab, exactly like the in-canvas switcher's selected state).
pub fn selectedTab(model: *const Model) []const u8 {
    return switch (model.tab) {
        .albums => mobile_tab_albums_command,
        .songs => mobile_tab_songs_command,
    };
}

/// The model's navigation depth — the projection a host presents REAL
/// push/pop transitions from (album grid -> album detail pushes; back
/// pops). Depth follows the VISIBLE page stack, so an open album counts
/// only while the Albums tab shows it: switching to Songs with a detail
/// open is a lateral tab change (the host reconciles with no
/// transition), exactly like switching back. Presentation only — the
/// state is `model.open_album`, owned by update.
pub fn navigationDepth(model: *const Model) usize {
    return if (model.tab == .albums and model.open_album != null) 1 else 0;
}

pub fn mobileOptions() SoundboardApp.Options {
    return .{
        .name = "soundboard",
        .scene = mobile_scene,
        .canvas_label = native_sdk.embed.mobile_gpu_surface_label,
        .update_fx = update,
        .view = rootView,
        .init_fx = boot,
        .tokens_fn = tokensFromModel,
        .on_appearance = onAppearance,
        .on_chrome = onChrome,
        .on_command = onCommand,
        .selected_tab_fn = selectedTab,
        .navigation_depth_fn = navigationDepth,
        .navigation_back_command = mobile_nav_back_command,
        .on_key = onKey,
        .on_frame = onFrame,
        .animations = animations,
        .sync = sync,
    };
}

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    registerIcons();
    // Streaming configuration, resolved once at launch: the env URL
    // base overrides the manifest's committed one (so a locally served
    // pack needs no re-prepare), and the platform caches directory
    // (~/Library/Caches/soundboard on macOS, XDG cache on Linux) hosts
    // the track cache in its audio/ child — delete that directory to
    // clear the cache. Both land in the INITIAL model, so replay's
    // deterministic-init contract holds: no env read ever happens
    // inside update.
    var model: Model = .{};
    if (init.environ_map.get("NATIVE_SDK_MUSIC_URL_BASE")) |base| model.setUrlBase(base);
    var cache_dir_buffer: [model_mod.max_cache_dir]u8 = undefined;
    const cache_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = "soundboard" },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .cache,
        &cache_dir_buffer,
    ) catch "";
    model.setCacheDir(cache_dir);
    const app_state = try std.heap.page_allocator.create(SoundboardApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = SoundboardApp.init(std.heap.page_allocator, model, soundboardOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "soundboard",
        .window_title = "Native SDK Soundboard",
        .bundle_id = "dev.native_sdk.soundboard",
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
