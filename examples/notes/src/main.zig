//! notes: the daily-driver shape — folders sidebar, note list, editor —
//! authored in markup + Zig.
//!
//! The whole view lives in `src/notes.native` (compiled at comptime, hot
//! reloaded in dev); `src/model.zig` is the logic: folders and notes as
//! model-owned tables, titles/snippets/relative-times derived per rebuild,
//! and persistence as one store file through the effects channel with a
//! debounced autosave. This file is the app wiring — shell scene, the
//! paper/evergreen theme, the store path, and the keyboard map.
//!
//! Keyboard-first: every mutation the buttons reach is also a registered
//! app shortcut (declared in app.zon, delivered as command events through
//! `on_command`) — new note/folder, rename, delete, copy, next/prev note,
//! cmd+digit folder jumps, and Escape to dismiss.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const app_dirs = native_sdk.app_dirs;

const model_mod = @import("model.zig");

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const update = model_mod.update;

pub const canvas_label = "notes-canvas";
pub const window_width: f32 = 1180;
pub const window_height: f32 = 760;
/// Content min-size floor the window enforces: the smallest size where
/// the three panes, the note-list rows, and the editor toolbar all lay
/// out without clipping or wrapping over each other — proven by the
/// layout audit sweep in tests.zig, which sweeps from exactly this floor.
pub const window_min_width: f32 = 760;
pub const window_min_height: f32 = 520;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Notes canvas", .accessibility_label = "Notes", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Notes",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    // Tall hidden-inset titlebar (declared in app.zon too, which threads
    // it through the STARTUP window create): the header row IS the
    // titlebar — it pads its leading edge past the traffic lights via
    // `on_chrome` and is the window's drag surface (`window-drag` in
    // notes.native).
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// --------------------------------------------------------------- commands

// Shortcut command ids: registered in app.zon (`.shortcuts`), delivered
// as command events, mapped to Msgs here. One spelling, three homes:
// app.zon, this table, and the on-screen keyboard reference.
pub const cmd_new_note = "notes.new-note"; // primary+N
pub const cmd_new_folder = "notes.new-folder"; // primary+shift+N
pub const cmd_rename_folder = "notes.rename-folder"; // primary+shift+R
pub const cmd_delete_note = "notes.delete-note"; // primary+backspace
pub const cmd_copy_note = "notes.copy-note"; // primary+shift+C
pub const cmd_prev_note = "notes.prev-note"; // primary+option+arrowup
pub const cmd_next_note = "notes.next-note"; // primary+option+arrowdown
pub const cmd_dismiss = "notes.dismiss"; // escape
/// `notes.folder-1` … `notes.folder-7`: primary+digit jumps to the
/// sidebar position (1 = All Notes, 2… = folders in creation order).
pub const folder_command_prefix = "notes.folder-";

pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, cmd_new_note)) return .new_note;
    if (std.mem.eql(u8, name, cmd_new_folder)) return .open_create_folder;
    if (std.mem.eql(u8, name, cmd_rename_folder)) return .open_rename_folder;
    if (std.mem.eql(u8, name, cmd_delete_note)) return .delete_note;
    if (std.mem.eql(u8, name, cmd_copy_note)) return .copy_note;
    if (std.mem.eql(u8, name, cmd_prev_note)) return .prev_note;
    if (std.mem.eql(u8, name, cmd_next_note)) return .next_note;
    if (std.mem.eql(u8, name, cmd_dismiss)) return .dismiss;
    if (std.mem.startsWith(u8, name, folder_command_prefix)) {
        const digit = std.fmt.parseInt(usize, name[folder_command_prefix.len..], 10) catch return null;
        if (digit == 0) return null;
        return .{ .select_folder_at = digit - 1 };
    }
    return null;
}

// -------------------------------------------------------------------- app

/// Debug builds keep the runtime markup engine for hot reload; release
/// builds compile it out entirely.
const dev_markup_reload = builtin.mode == .Debug;

const NotesApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev_markup_reload });
pub const Effects = NotesApp.Effects;

/// TEA init: restore the persisted store before the first paint, and
/// start the repeating tick that keeps relative timestamps honest.
pub fn boot(model: *Model, fx: *Effects) void {
    // Deterministic init under session replay: re-stamp the sample
    // notes from the JOURNALED clock read. `main` seeded with the live
    // clock before the runtime existed; this reseed lands before the
    // first view build, so the ages the first frame renders come from a
    // value the journal replays verbatim.
    model_mod.seedAt(model, fx.wallMs());
    if (model.store_path_len > 0) {
        fx.readFile(.{
            .key = model_mod.store_read_key,
            .path = model.storePath(),
            .on_result = Effects.fileMsg(.store_done),
        });
    }
    fx.startTimer(.{
        .key = model_mod.refresh_timer_key,
        .interval_ms = model_mod.refresh_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.refresh_tick),
    });
}

// ------------------------------------------------------------------- theme

/// A paper-and-evergreen palette derived per rebuild from the model's
/// scheme; the runtime stamps the surface scale afterwards. The
/// neutrals are the register's warm (stone) scale — anchors converted
/// from their published oklch values — so notes keeps its paper warmth
/// without tinted grays; the evergreen personality lives in the teal
/// accent alone (light oklch(0.511 0.096 186.391) = #00786f). The
/// dialog scrim is token-driven through the modal chrome (dim + blur),
/// so the shadow token is just a shadow again.
pub fn notesTokens(model: *const Model) canvas.DesignTokens {
    const scheme = model.system_scheme;
    var tokens = canvas.DesignTokens.theme(.{ .color_scheme = scheme });
    tokens.colors = switch (scheme) {
        .light => .{
            .background = canvas.Color.rgb8(250, 250, 249),
            .surface = canvas.Color.rgb8(255, 255, 255),
            .surface_subtle = canvas.Color.rgb8(245, 245, 244),
            .surface_pressed = canvas.Color.rgb8(231, 229, 228),
            .text = canvas.Color.rgb8(12, 10, 9),
            .text_muted = canvas.Color.rgb8(121, 113, 107),
            .border = canvas.Color.rgb8(231, 229, 228),
            .accent = canvas.Color.rgb8(0, 120, 111),
            .accent_text = canvas.Color.rgb8(240, 253, 250),
            .destructive = canvas.Color.rgb8(231, 0, 11),
            .destructive_text = canvas.Color.rgb8(250, 250, 250),
            .success = canvas.Color.rgb8(22, 163, 74),
            .success_text = canvas.Color.rgb8(250, 250, 250),
            .warning = canvas.Color.rgb8(217, 119, 6),
            .warning_text = canvas.Color.rgb8(250, 250, 250),
            .focus_ring = canvas.Color.rgb8(166, 160, 155),
            .shadow = canvas.Color.rgba8(0, 0, 0, 26),
            .disabled = canvas.Color.rgb8(245, 245, 244),
        },
        .dark => .{
            .background = canvas.Color.rgb8(12, 10, 9),
            .surface = canvas.Color.rgb8(28, 25, 23),
            .surface_subtle = canvas.Color.rgb8(41, 37, 36),
            .surface_pressed = canvas.Color.rgba8(255, 255, 255, 38),
            .text = canvas.Color.rgb8(250, 250, 249),
            .text_muted = canvas.Color.rgb8(166, 160, 155),
            .border = canvas.Color.rgba8(255, 255, 255, 26),
            .accent = canvas.Color.rgb8(0, 187, 167),
            .accent_text = canvas.Color.rgb8(12, 10, 9),
            .destructive = canvas.Color.rgb8(255, 100, 103),
            .destructive_text = canvas.Color.rgb8(250, 250, 250),
            .success = canvas.Color.rgb8(34, 197, 94),
            .success_text = canvas.Color.rgb8(9, 9, 11),
            .warning = canvas.Color.rgb8(245, 158, 11),
            .warning_text = canvas.Color.rgb8(9, 9, 11),
            .info = canvas.Color.rgb8(167, 139, 250),
            .info_text = canvas.Color.rgb8(9, 9, 11),
            .focus_ring = canvas.Color.rgb8(121, 113, 107),
            .shadow = canvas.Color.rgba8(0, 0, 0, 150),
            .disabled = canvas.Color.rgb8(41, 37, 36),
        },
    };
    tokens.radius = .{ .sm = 6, .md = 8, .lg = 11, .xl = 14 };
    return tokens;
}

/// System appearance flows into the model and the tokens re-derive from
/// it — the app follows the OS scheme live, with no in-window theme UI.
/// Chrome overlay geometry flows into the model (tall hidden-inset
/// titlebar): delivered before the first view build and again when it
/// changes — entering fullscreen hides the traffic lights and this goes
/// to zero.
pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return .{ .system_scheme = switch (appearance.color_scheme) {
        .light => .light,
        .dark => .dark,
    } };
}

// -------------------------------------------------------------------- view

pub const NotesUi = canvas.Ui(Msg);
pub const notes_markup = @embedFile("notes.native");

/// The comptime-compiled engine: same tree, ids, and handlers as the
/// interpreter, no parser in the binary.
pub const CompiledNotesView = canvas.CompiledMarkupView(Model, Msg, notes_markup);

// -------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(NotesApp);
    defer std.heap.page_allocator.destroy(app_state);

    var model = model_mod.initialModel(.system);
    // Resolve where the store persists: the per-app data directory
    // (~/Library/Application Support/notes on macOS). Failure just
    // disables persistence — never a startup error.
    var dir_buffer: [model_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [model_mod.max_path_bytes]u8 = undefined;
    const env = native_sdk.debug.envFromMap(init.environ_map);
    const platform_value = app_dirs.currentPlatform();
    if (app_dirs.resolveOne(.{ .name = "notes" }, platform_value, env, .data, &dir_buffer)) |data_dir| {
        if (app_dirs.join(platform_value, &file_buffer, &.{ data_dir, "store.txt" })) |store_path| {
            model.setStorePath(store_path);
        } else |_| {}
    } else |_| {}

    app_state.* = NotesApp.init(std.heap.page_allocator, model, .{
        .name = "notes",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .tokens_fn = notesTokens,
        .on_appearance = onAppearance,
        .on_chrome = onChrome,
        .on_command = command,
        .view = CompiledNotesView.build,
        .markup = if (dev_markup_reload)
            .{ .source = notes_markup, .watch_path = "src/notes.native", .io = init.io }
        else
            null,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "notes",
        .window_title = "Native SDK Notes",
        .bundle_id = "dev.native_sdk.notes",
        .icon_path = "assets/icon.png",
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
