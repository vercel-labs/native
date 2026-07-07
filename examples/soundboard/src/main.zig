//! soundboard: a music-library browser showcasing native-rendered
//! Native SDK UI — the committed music catalog with real cover art
//! through the runtime image pipeline, track lists with native context
//! menus, a now-playing bar with REAL audio playback through the runtime
//! audio effect family, search, and a custom light/dark theme.
//!
//! Authoring split (markup-first): the header and now-playing bars are
//! `.native` views compiled at comptime; the album grid, album detail, and
//! track rows are Zig views because they need what the closed markup
//! grammar deliberately excludes — square cover images, grid column
//! counts, scaled paragraph headings, and per-row native context menus.
//! `src/view.zig` composes both kinds under one root, so widget identity,
//! dispatch, and theming behave exactly as in a single-source view.

const std = @import("std");
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
/// sweeps from exactly this floor.
pub const window_min_width: f32 = 1056;
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

/// The registered icon table: ONE declaration feeds boot-time
/// registration (`registerIcons`, called from main and the test
/// harness) AND the model contract's `app_icons` list (the emit step
/// reflects this decl), so markup `app:<name>` references are verified
/// by `native check` against exactly what the app registers.
pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "waveform", .icon = &waveform_icon },
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
        .animations = animations,
        .sync = sync,
    };
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

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    registerIcons();
    const app_state = try std.heap.page_allocator.create(SoundboardApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = SoundboardApp.init(std.heap.page_allocator, .{}, soundboardOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "soundboard",
        .window_title = "Native SDK Soundboard",
        .bundle_id = "dev.native_sdk.soundboard",
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
