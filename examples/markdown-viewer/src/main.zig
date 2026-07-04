//! markdown-viewer: a split-pane markdown editor/preview authored in
//! markup + Zig.
//!
//! The left pane is a `textarea` whose every edit mirrors into the model
//! (`canvas.TextBuffer`, the elm-style pattern); the right pane is one
//! `<markdown>` element bound to the same bytes, so the preview is always
//! exactly the document — no debounce, no cache, no drift. Links open in
//! the system browser through `fx.spawn` (`open`/`xdg-open`), and Open /
//! Save / Save As are real file I/O through `fx.readFile`/`fx.writeFile`
//! against an honest, editable path field — native-sdk has no native
//! file dialogs, so the path field IS the file picker, and the sidebar's
//! recent-files list (itself persisted through the same file effects)
//! makes it livable.
//!
//! Fixed capacities, documented where they bind: documents cap at
//! `max_document_bytes` (16 KiB — the view retains editor + preview text
//! against the 64 KiB per-view widget-text budget), paths at
//! `max_path_bytes`, the recent list at `max_recent` entries, and
//! `<details>` blocks at `max_details` model-owned expansion flags.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const app_dirs = native_sdk.app_dirs;

const canvas_label = "viewer-canvas";
const window_width: f32 = 1200;
const window_height: f32 = 760;

/// Document capacity. The rendered preview retains the document's plain
/// text alongside the editor's copy, and the per-view retained-text
/// budget is 64 KiB (`canvas_limits.max_canvas_widget_text_bytes_per_view`),
/// so 16 KiB leaves 2x headroom for chrome text and span payloads.
pub const max_document_bytes = 16 * 1024;
/// Path capacity; the effect channel itself binds at 1 KiB
/// (`max_effect_file_path_bytes`).
pub const max_path_bytes = 512;
/// Sidebar recent-files entries (newest first).
pub const max_recent = 6;
/// Model-owned `<details>` expansion flags, indexed by document order.
/// The renderer caps details blocks at 16 per document, matching this.
pub const max_details = 16;
const max_note_bytes = 192;

// Effect keys: caller-chosen identities, one per concurrent operation.
pub const open_key: u64 = 1;
pub const save_key: u64 = 2;
pub const recent_read_key: u64 = 3;
pub const recent_write_key: u64 = 4;
pub const link_key: u64 = 5;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Markdown viewer canvas", .accessibility_label = "Markdown viewer", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Markdown",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ---------------------------------------------------------------- samples

pub const Sample = struct {
    id: u32,
    title: []const u8,
    body: []const u8,
};

pub const welcome_sample_id: u32 = 1;

pub const Model = struct {
    /// The document, elm-style: the model applies every textarea edit and
    /// is the single source both panes render from.
    editor: canvas.TextBuffer(max_document_bytes) = .{},
    /// The toolbar path field (also an elm mirror).
    path_field: canvas.TextBuffer(max_path_bytes) = .{},
    /// The path of the opened/saved document; empty means unsaved.
    current_path_storage: [max_path_bytes]u8 = undefined,
    current_path_len: usize = 0,
    /// The path an in-flight Open/Save As will adopt on success.
    pending_path_storage: [max_path_bytes]u8 = undefined,
    pending_path_len: usize = 0,
    /// Recent files, newest first, persisted via file effects.
    recent_storage: [max_recent][max_path_bytes]u8 = undefined,
    recent_lens: [max_recent]usize = [_]usize{0} ** max_recent,
    recent_count: usize = 0,
    /// Where the recent list persists (resolved from the per-app data dir
    /// in `main`; empty in tests unless set — persistence then stays off).
    recent_path_storage: [max_path_bytes]u8 = undefined,
    recent_path_len: usize = 0,
    /// `<details>` expansion flags, document order. The markup binds this
    /// field directly; `update` toggles it.
    details_expanded: [max_details]bool = [_]bool{false} ** max_details,
    /// The sidebar sample currently loaded (0 = none: edited or opened).
    active_sample_id: u32 = 0,
    /// Toolbar sample-picker open state — model-owned (TEA): the anchored
    /// dropdown exists only while this is true; `close_sample_picker`
    /// (the surface's on-dismiss) and picking both clear it.
    sample_picker_open: bool = false,
    /// Theme: the system scheme flows in through `on_appearance`; the
    /// toolbar toggle overrides it until the app restarts.
    system_scheme: canvas.ColorScheme = .light,
    override_scheme: ?canvas.ColorScheme = null,
    /// One-line activity note for the status bar ("Saved", "Open failed…").
    note_storage: [max_note_bytes]u8 = undefined,
    note_len: usize = 0,

    pub const samples = [_]Sample{
        .{ .id = welcome_sample_id, .title = "Welcome", .body = @embedFile("samples/welcome.md") },
        .{ .id = 2, .title = "Renderer tour", .body = @embedFile("samples/tour.md") },
        .{ .id = 3, .title = "RFC: Session sync", .body = @embedFile("samples/spec.md") },
        .{ .id = 4, .title = "Reading notes", .body = @embedFile("samples/notes.md") },
    };

    pub fn sampleById(id: u32) ?*const Sample {
        for (&samples) |*sample| {
            if (sample.id == id) return sample;
        }
        return null;
    }

    // ------------------------------------------------------- view bindings

    pub fn document(model: *const Model) []const u8 {
        return model.editor.text();
    }

    pub fn path(model: *const Model) []const u8 {
        return model.path_field.text();
    }

    pub fn pathEmpty(model: *const Model) bool {
        return model.path_field.isEmpty();
    }

    pub fn cannotSave(model: *const Model) bool {
        return model.current_path_len == 0;
    }

    pub fn currentPath(model: *const Model) []const u8 {
        return model.current_path_storage[0..model.current_path_len];
    }

    pub fn docTitle(model: *const Model) []const u8 {
        if (sampleById(model.active_sample_id)) |sample| return sample.title;
        if (model.current_path_len > 0) return pathBasename(model.currentPath());
        return "Untitled";
    }

    /// The accessible name for the icon-only theme toggle (the sun/moon
    /// vector icons carry the visual; dingbats rendered as tofu and are
    /// long gone).
    pub fn themeLabel(model: *const Model) []const u8 {
        return switch (model.effectiveScheme()) {
            .light => "Dark mode",
            .dark => "Light mode",
        };
    }

    /// `<if test="{isDark}">` predicate for the theme toggle's icon arms.
    pub fn isDark(model: *const Model) bool {
        return model.effectiveScheme() == .dark;
    }

    pub const RecentDoc = struct {
        index: usize,
        name: []const u8,
        path: []const u8,
    };

    pub fn recentDocs(model: *const Model, arena: std.mem.Allocator) []const RecentDoc {
        const out = arena.alloc(RecentDoc, model.recent_count) catch return &.{};
        for (out, 0..) |*slot, index| {
            const entry = model.recentAt(index);
            slot.* = .{ .index = index, .name = pathBasename(entry), .path = entry };
        }
        return out;
    }

    pub fn statusLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const text = model.editor.text();
        const activity = model.note();
        if (activity.len == 0) {
            return std.fmt.allocPrint(arena, "{d} words · {d} lines · {d} bytes", .{
                countWords(text), countLines(text), text.len,
            }) catch "";
        }
        return std.fmt.allocPrint(arena, "{d} words · {d} lines · {d} bytes · {s}", .{
            countWords(text), countLines(text), text.len, activity,
        }) catch "";
    }

    // ----------------------------------------------------------- mutation

    pub fn note(model: *const Model) []const u8 {
        return model.note_storage[0..model.note_len];
    }

    pub fn setNote(model: *Model, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&model.note_storage, fmt, args) catch {
            model.note_len = 0;
            return;
        };
        model.note_len = written.len;
    }

    pub fn loadSample(model: *Model, id: u32) void {
        const sample = sampleById(id) orelse return;
        model.editor.set(sample.body);
        model.active_sample_id = id;
        model.current_path_len = 0;
        model.details_expanded = [_]bool{false} ** max_details;
        model.note_len = 0;
    }

    pub fn setPendingPath(model: *Model, value: []const u8) void {
        const len = @min(value.len, max_path_bytes);
        @memcpy(model.pending_path_storage[0..len], value[0..len]);
        model.pending_path_len = len;
    }

    pub fn pendingPath(model: *const Model) []const u8 {
        return model.pending_path_storage[0..model.pending_path_len];
    }

    pub fn adoptPendingPath(model: *Model) void {
        @memcpy(model.current_path_storage[0..model.pending_path_len], model.pendingPath());
        model.current_path_len = model.pending_path_len;
        model.path_field.set(model.currentPath());
    }

    pub fn recentAt(model: *const Model, index: usize) []const u8 {
        return model.recent_storage[index][0..model.recent_lens[index]];
    }

    /// Move `value` to the front of the recent list, deduplicated.
    pub fn pushRecent(model: *Model, value: []const u8) void {
        if (value.len == 0 or value.len > max_path_bytes) return;
        var keep_count: usize = 0;
        var kept: [max_recent][max_path_bytes]u8 = undefined;
        var kept_lens: [max_recent]usize = undefined;
        for (0..model.recent_count) |index| {
            const entry = model.recentAt(index);
            if (std.mem.eql(u8, entry, value)) continue;
            if (keep_count + 1 >= max_recent) break;
            @memcpy(kept[keep_count][0..entry.len], entry);
            kept_lens[keep_count] = entry.len;
            keep_count += 1;
        }
        @memcpy(model.recent_storage[0][0..value.len], value);
        model.recent_lens[0] = value.len;
        for (0..keep_count) |index| {
            @memcpy(model.recent_storage[index + 1][0..kept_lens[index]], kept[index][0..kept_lens[index]]);
            model.recent_lens[index + 1] = kept_lens[index];
        }
        model.recent_count = keep_count + 1;
    }

    pub fn setRecentStorePath(model: *Model, value: []const u8) void {
        const len = @min(value.len, max_path_bytes);
        @memcpy(model.recent_path_storage[0..len], value[0..len]);
        model.recent_path_len = len;
    }

    pub fn recentStorePath(model: *const Model) []const u8 {
        return model.recent_path_storage[0..model.recent_path_len];
    }

    /// Parse the persisted recent list (one path per line, newest first).
    pub fn restoreRecent(model: *Model, bytes: []const u8) void {
        model.recent_count = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed.len > max_path_bytes) continue;
            if (model.recent_count >= max_recent) break;
            @memcpy(model.recent_storage[model.recent_count][0..trimmed.len], trimmed);
            model.recent_lens[model.recent_count] = trimmed.len;
            model.recent_count += 1;
        }
    }

    /// Serialize the recent list for persistence (into a caller buffer;
    /// bounded by construction: max_recent * (max_path_bytes + 1)).
    pub fn serializeRecent(model: *const Model, buffer: []u8) []const u8 {
        var len: usize = 0;
        for (0..model.recent_count) |index| {
            const entry = model.recentAt(index);
            if (len + entry.len + 1 > buffer.len) break;
            @memcpy(buffer[len .. len + entry.len], entry);
            len += entry.len;
            buffer[len] = '\n';
            len += 1;
        }
        return buffer[0..len];
    }

    pub fn effectiveScheme(model: *const Model) canvas.ColorScheme {
        return model.override_scheme orelse model.system_scheme;
    }
};

pub fn countWords(text: []const u8) usize {
    var count: usize = 0;
    var in_word = false;
    for (text) |byte| {
        const is_space = byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
        if (is_space) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            count += 1;
        }
    }
    return count;
}

pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn pathBasename(value: []const u8) []const u8 {
    const separator: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    if (std.mem.lastIndexOfScalar(u8, value, separator)) |index| {
        if (index + 1 < value.len) return value[index + 1 ..];
    }
    return value;
}

// ------------------------------------------------------------------ update

pub const Msg = union(enum) {
    edit: canvas.TextInputEvent,
    edit_path: canvas.TextInputEvent,
    load_sample: u32,
    toggle_sample_picker,
    close_sample_picker,
    open_recent: usize,
    open_doc,
    save_doc,
    save_as,
    toggle_theme,
    system_scheme: canvas.ColorScheme,
    toggle_details: usize,
    open_url: []const u8,
    file_done: native_sdk.EffectFileResult,
    recent_done: native_sdk.EffectFileResult,
    link_done: native_sdk.EffectExit,
};

const ViewerApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev_markup_reload });
pub const Effects = ViewerApp.Effects;

/// TEA init: restore the persisted recent list before the first paint.
pub fn boot(model: *Model, fx: *Effects) void {
    if (model.recent_path_len == 0) return;
    fx.readFile(.{
        .key = recent_read_key,
        .path = model.recentStorePath(),
        .on_result = Effects.fileMsg(.recent_done),
    });
}

fn persistRecent(model: *Model, fx: *Effects) void {
    if (model.recent_path_len == 0) return;
    var buffer: [max_recent * (max_path_bytes + 1)]u8 = undefined;
    fx.writeFile(.{
        .key = recent_write_key,
        .path = model.recentStorePath(),
        .bytes = model.serializeRecent(&buffer),
        .on_result = Effects.fileMsg(.recent_done),
    });
}

fn openPath(model: *Model, fx: *Effects, value: []const u8) void {
    if (value.len == 0) return;
    model.setPendingPath(value);
    model.setNote("Opening {s}…", .{pathBasename(value)});
    fx.readFile(.{
        .key = open_key,
        .path = model.pendingPath(),
        .on_result = Effects.fileMsg(.file_done),
    });
}

fn savePath(model: *Model, fx: *Effects, value: []const u8) void {
    if (value.len == 0) return;
    model.setPendingPath(value);
    model.setNote("Saving {s}…", .{pathBasename(value)});
    fx.writeFile(.{
        .key = save_key,
        .path = model.pendingPath(),
        .bytes = model.editor.text(),
        .on_result = Effects.fileMsg(.file_done),
    });
}

/// The platform's open-in-browser command; `fx.spawn` copies argv at call
/// time, so building it from the drain-scratch URL is safe.
fn openInBrowser(fx: *Effects, url: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "cmd", "/c", "start", "", url },
        .macos => &.{ "open", url },
        else => &.{ "xdg-open", url },
    };
    fx.spawn(.{
        .key = link_key,
        .argv = argv,
        .output = .collect,
        .on_exit = Effects.exitMsg(.link_done),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .edit => |edit| {
            model.editor.apply(edit);
            model.active_sample_id = 0;
            if (model.editor.truncated) model.setNote("Document is full ({d} KiB cap)", .{max_document_bytes / 1024});
        },
        .edit_path => |edit| model.path_field.apply(edit),
        .load_sample => |id| {
            model.loadSample(id);
            model.sample_picker_open = false;
        },
        .toggle_sample_picker => model.sample_picker_open = !model.sample_picker_open,
        // The anchored dropdown's on-dismiss: Escape or a click outside
        // the menu closes it here, model-side.
        .close_sample_picker => model.sample_picker_open = false,
        .open_recent => |index| {
            if (index >= model.recent_count) return;
            model.path_field.set(model.recentAt(index));
            openPath(model, fx, model.recentAt(index));
        },
        .open_doc => openPath(model, fx, std.mem.trim(u8, model.path_field.text(), " ")),
        .save_doc => savePath(model, fx, model.currentPath()),
        .save_as => savePath(model, fx, std.mem.trim(u8, model.path_field.text(), " ")),
        .toggle_theme => model.override_scheme = switch (model.effectiveScheme()) {
            .light => .dark,
            .dark => .light,
        },
        .system_scheme => |scheme| model.system_scheme = scheme,
        .toggle_details => |index| {
            if (index < max_details) model.details_expanded[index] = !model.details_expanded[index];
        },
        .open_url => |url| {
            model.setNote("Opening link…", .{});
            openInBrowser(fx, url);
        },
        .file_done => |result| switch (result.op) {
            .read => switch (result.outcome) {
                .ok => {
                    // COPY the payload: result.bytes is drain scratch.
                    model.editor.set(result.bytes);
                    model.active_sample_id = 0;
                    model.details_expanded = [_]bool{false} ** max_details;
                    model.adoptPendingPath();
                    model.pushRecent(model.currentPath());
                    model.setNote("Opened {s}", .{model.docTitle()});
                    persistRecent(model, fx);
                },
                .truncated => {
                    model.editor.set(result.bytes);
                    model.active_sample_id = 0;
                    model.setNote("Opened a cut copy: file exceeds the {d} KiB document cap", .{max_document_bytes / 1024});
                },
                else => model.setNote("Open failed: {s}", .{@tagName(result.outcome)}),
            },
            .write => switch (result.outcome) {
                .ok => {
                    model.adoptPendingPath();
                    // The document now lives at the saved path; title from
                    // the file, not the sample it started from.
                    model.active_sample_id = 0;
                    model.pushRecent(model.currentPath());
                    model.setNote("Saved {s}", .{model.docTitle()});
                    persistRecent(model, fx);
                },
                else => model.setNote("Save failed: {s}", .{@tagName(result.outcome)}),
            },
        },
        .recent_done => |result| {
            if (result.op == .read and result.outcome == .ok) model.restoreRecent(result.bytes);
            // Write acknowledgements and missing-file reads are quiet:
            // the recent list is a convenience, never an error surface.
        },
        .link_done => |exit| {
            if (exit.reason == .exited and exit.code == 0) {
                model.setNote("Opened in browser", .{});
            } else {
                model.setNote("Browser open failed ({s})", .{@tagName(exit.reason)});
            }
        },
    }
}

// ------------------------------------------------------------------- theme

/// A refined two-mode palette (stone neutrals + indigo accent) derived
/// per rebuild from the model's scheme; the runtime stamps the surface
/// scale afterwards.
pub fn viewerTokens(model: *const Model) canvas.DesignTokens {
    const scheme = model.effectiveScheme();
    var tokens = canvas.DesignTokens.theme(.{ .color_scheme = scheme });
    tokens.colors = switch (scheme) {
        .light => .{
            .background = canvas.Color.rgb8(250, 250, 249),
            .surface = canvas.Color.rgb8(255, 255, 255),
            .surface_subtle = canvas.Color.rgb8(245, 245, 244),
            .surface_pressed = canvas.Color.rgb8(231, 229, 228),
            .text = canvas.Color.rgb8(28, 25, 23),
            .text_muted = canvas.Color.rgb8(121, 113, 107),
            .border = canvas.Color.rgb8(231, 229, 228),
            .accent = canvas.Color.rgb8(79, 70, 229),
            .accent_text = canvas.Color.rgb8(255, 255, 255),
            .destructive = canvas.Color.rgb8(220, 38, 38),
            .destructive_text = canvas.Color.rgb8(250, 250, 250),
            .success = canvas.Color.rgb8(22, 163, 74),
            .success_text = canvas.Color.rgb8(250, 250, 250),
            .warning = canvas.Color.rgb8(217, 119, 6),
            .warning_text = canvas.Color.rgb8(250, 250, 250),
            .focus_ring = canvas.Color.rgb8(99, 102, 241),
            .shadow = canvas.Color.rgba8(28, 25, 23, 24),
            .disabled = canvas.Color.rgb8(245, 245, 244),
        },
        .dark => .{
            .background = canvas.Color.rgb8(18, 18, 21),
            .surface = canvas.Color.rgb8(28, 28, 33),
            .surface_subtle = canvas.Color.rgb8(38, 38, 44),
            .surface_pressed = canvas.Color.rgb8(51, 51, 58),
            .text = canvas.Color.rgb8(244, 244, 245),
            .text_muted = canvas.Color.rgb8(161, 161, 170),
            .border = canvas.Color.rgb8(42, 42, 49),
            .accent = canvas.Color.rgb8(129, 140, 248),
            .accent_text = canvas.Color.rgb8(30, 27, 75),
            .destructive = canvas.Color.rgb8(239, 68, 68),
            .destructive_text = canvas.Color.rgb8(250, 250, 250),
            .success = canvas.Color.rgb8(34, 197, 94),
            .success_text = canvas.Color.rgb8(9, 9, 11),
            .warning = canvas.Color.rgb8(245, 158, 11),
            .warning_text = canvas.Color.rgb8(9, 9, 11),
            .focus_ring = canvas.Color.rgb8(129, 140, 248),
            .shadow = canvas.Color.rgba8(0, 0, 0, 150),
            .disabled = canvas.Color.rgb8(38, 38, 44),
        },
    };
    return tokens;
}

/// System appearance flows into the model; an explicit toolbar override
/// keeps winning because `effectiveScheme` consults it first.
pub fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return .{ .system_scheme = switch (appearance.color_scheme) {
        .light => .light,
        .dark => .dark,
    } };
}

// ------------------------------------------------------------------- view

pub const ViewerUi = canvas.Ui(Msg);
pub const viewer_markup = @embedFile("viewer.zml");

/// The comptime-compiled engine: same tree, ids, and handlers as the
/// interpreter, no parser in the binary.
pub const CompiledViewerView = canvas.CompiledMarkupView(Model, Msg, viewer_markup);

// -------------------------------------------------------------------- app

/// Debug builds keep the runtime markup engine for hot reload; release
/// builds compile it out entirely.
const dev_markup_reload = builtin.mode == .Debug;

pub fn initialModel() Model {
    var model = Model{};
    model.loadSample(welcome_sample_id);
    return model;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(ViewerApp);
    defer std.heap.page_allocator.destroy(app_state);

    var model = initialModel();
    // Resolve where the recent list persists: the per-app data directory
    // (~/Library/Application Support/markdown-viewer on macOS). Failure
    // just disables persistence — never a startup error.
    var dir_buffer: [max_path_bytes]u8 = undefined;
    var file_buffer: [max_path_bytes]u8 = undefined;
    const env = native_sdk.debug.envFromMap(init.environ_map);
    const platform_value = app_dirs.currentPlatform();
    if (app_dirs.resolveOne(.{ .name = "markdown-viewer" }, platform_value, env, .data, &dir_buffer)) |data_dir| {
        if (app_dirs.join(platform_value, &file_buffer, &.{ data_dir, "recent.txt" })) |recent_path| {
            model.setRecentStorePath(recent_path);
        } else |_| {}
    } else |_| {}

    app_state.* = ViewerApp.init(std.heap.page_allocator, model, .{
        .name = "markdown-viewer",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .tokens_fn = viewerTokens,
        .on_appearance = onAppearance,
        .view = CompiledViewerView.build,
        .markup = if (dev_markup_reload)
            .{ .source = viewer_markup, .watch_path = "src/viewer.zml", .io = init.io }
        else
            null,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "markdown-viewer",
        .window_title = "Native SDK Markdown",
        .bundle_id = "dev.native_sdk.markdown_viewer",
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
