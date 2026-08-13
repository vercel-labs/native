//! code-editor: a native folder picker feeding a two-pane source editor.
//!
//! The small `CodeEditorApp` wrapper is the host boundary: after the
//! elm-style app requests a folder, it presents `Runtime.showOpenDialog`
//! with `allow_directories`, copies the chosen path, and loads the bounded
//! explorer tree one expanded directory at a time with `std.Io`.
//! The complete view lives in `code-editor.native`; this file owns the
//! Model/Msg/update loop and the narrow platform/filesystem seams. Debug
//! builds hot-reload the markup without losing the selected folder.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "code-editor-canvas";
pub const window_width: f32 = 1120;
pub const window_height: f32 = 720;
pub const window_min_width: f32 = 760;
pub const window_min_height: f32 = 480;
pub const titlebar_natural_height: f32 = 52;
pub const tree_row_inset: f32 = 4;
pub const tree_depth_indent: f32 = 16;

/// The explored tree is deliberately bounded: a source browser should not
/// exhaust its view/model budgets because somebody selected a monorepo or `/`.
pub const max_entries: usize = 128;
pub const max_scan_depth: usize = 12;
pub const max_root_path_bytes: usize = 512;
pub const max_relative_path_bytes: usize = 512;
pub const max_name_bytes: usize = 255;
/// Pinned tabs are bounded like the folder scan and source preview.
pub const max_open_tabs: usize = 16;
/// Stable tab geometry lets the model move the horizontal strip to the
/// selected tab without depending on host-only text measurements.
pub const editor_tab_width: f32 = 180;
/// One extra slot holds the replaceable single-click preview beside the
/// persistent tab limit.
pub const max_documents: usize = max_open_tabs + 1;
/// Leave 128 KiB of the 512 KiB per-view retained-text budget for the
/// bounded file tree, tabs, semantics labels, and other chrome. The tree
/// retains each visible name as both text and an accessibility label, so
/// its worst case needs substantially more than a token reserve.
pub const max_preview_bytes: usize = 384 * 1024;
const max_status_bytes: usize = 192;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_dialog,
    native_sdk.security.permission_filesystem,
    native_sdk.security.permission_view,
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Code editor canvas", .accessibility_label = "Code editor", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Code Editor",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };
pub const app_shortcuts = [_]native_sdk.Shortcut{
    .{ .id = "save-file", .key = "s", .modifiers = .{ .primary = true } },
    .{ .id = "close-tab", .key = "w", .modifiers = .{ .primary = true } },
    .{ .id = "open-folder", .key = "o", .modifiers = .{ .primary = true } },
    .{ .id = "new-window", .key = "n", .modifiers = .{ .primary = true } },
    .{ .id = "previous-tab", .key = "[", .modifiers = .{ .primary = true, .shift = true } },
    .{ .id = "next-tab", .key = "]", .modifiers = .{ .primary = true, .shift = true } },
};

/// `UiApp` supports four model-declared secondary windows in addition to
/// the scene's main window. Each slot below owns a complete, independent
/// browser session; closed slots can be reused without moving a Model that
/// may own heap-backed editor buffers.
pub const max_browser_windows: usize = 5;
const secondary_window_labels = [_][]const u8{
    "code-editor-2",
    "code-editor-3",
    "code-editor-4",
    "code-editor-5",
};
const secondary_canvas_labels = [_][]const u8{
    "code-editor-canvas-2",
    "code-editor-canvas-3",
    "code-editor-canvas-4",
    "code-editor-canvas-5",
};

pub const EntryKind = enum { directory, file };

pub const Entry = struct {
    name_storage: [max_name_bytes]u8 = [_]u8{0} ** max_name_bytes,
    name_len: usize = 0,
    relative_storage: [max_relative_path_bytes]u8 = [_]u8{0} ** max_relative_path_bytes,
    relative_len: usize = 0,
    kind: EntryKind = .file,
    depth: u8 = 1,
    parent: ?u16 = null,
    expanded: bool = false,
    children_loaded: bool = false,
    /// Scratch identity stamped immediately before an in-place re-sort so
    /// every tab/document index can follow the same entry afterward.
    sort_identity: u16 = 0,

    pub fn name(entry: *const Entry) []const u8 {
        return entry.name_storage[0..entry.name_len];
    }

    pub fn relativePath(entry: *const Entry) []const u8 {
        return entry.relative_storage[0..entry.relative_len];
    }

    fn setRoot(entry: *Entry, dir_entry: std.Io.Dir.Entry) !void {
        if (dir_entry.name.len > entry.name_storage.len or dir_entry.name.len > entry.relative_storage.len) {
            return error.PathTooLong;
        }
        @memcpy(entry.name_storage[0..dir_entry.name.len], dir_entry.name);
        entry.name_len = dir_entry.name.len;
        @memcpy(entry.relative_storage[0..dir_entry.name.len], dir_entry.name);
        entry.relative_len = dir_entry.name.len;
        entry.kind = if (dir_entry.kind == .directory) .directory else .file;
        entry.depth = 1;
        entry.children_loaded = entry.kind != .directory or skipDirectory(dir_entry.name);
    }

    fn setChild(entry: *Entry, parent_entry: *const Entry, dir_entry: std.Io.Dir.Entry) !void {
        const parent_path = parent_entry.relativePath();
        const relative_len = parent_path.len + 1 + dir_entry.name.len;
        if (dir_entry.name.len > entry.name_storage.len or relative_len > entry.relative_storage.len) {
            return error.PathTooLong;
        }
        @memcpy(entry.name_storage[0..dir_entry.name.len], dir_entry.name);
        entry.name_len = dir_entry.name.len;
        @memcpy(entry.relative_storage[0..parent_path.len], parent_path);
        entry.relative_storage[parent_path.len] = std.fs.path.sep;
        @memcpy(entry.relative_storage[parent_path.len + 1 .. relative_len], dir_entry.name);
        entry.relative_len = relative_len;
        entry.kind = if (dir_entry.kind == .directory) .directory else .file;
        entry.depth = parent_entry.depth +| 1;
        entry.children_loaded = entry.kind != .directory or
            entry.depth >= max_scan_depth or
            skipDirectory(dir_entry.name);
    }
};

pub const PreviewState = enum {
    idle,
    loading,
    text,
    binary,
    failed,
};

const SourceTextBuffer = canvas.TextBuffer(max_preview_bytes);
const RenameTextBuffer = canvas.TextBuffer(max_name_bytes);

/// Own the large fixed-capacity source buffer out of line. The model keeps
/// up to 17 document slots, but only opened documents pay the 384 KiB
/// allocation; stack-allocated models and ordinary small test fixtures stay
/// compact.
pub const EditorBuffer = struct {
    value: ?*SourceTextBuffer = null,
    allocator: ?std.mem.Allocator = null,

    pub fn init(allocator: std.mem.Allocator, initial: []const u8) !EditorBuffer {
        const value = try allocator.create(SourceTextBuffer);
        value.* = SourceTextBuffer.init(initial);
        return .{ .value = value, .allocator = allocator };
    }

    pub fn deinit(editor: *EditorBuffer) void {
        const value = editor.value orelse return;
        editor.allocator.?.destroy(value);
        editor.* = .{};
    }

    pub fn text(editor: *const EditorBuffer) []const u8 {
        const value = editor.value orelse return "";
        return value.text();
    }

    pub fn apply(editor: *EditorBuffer, event: canvas.TextInputEvent) void {
        const value = editor.value orelse return;
        value.apply(event);
    }

    pub fn set(editor: *EditorBuffer, new_text: []const u8) void {
        const value = editor.value orelse return;
        value.set(new_text);
    }

    pub fn clear(editor: *EditorBuffer) void {
        const value = editor.value orelse return;
        value.clear();
    }

    pub fn truncated(editor: *const EditorBuffer) bool {
        const value = editor.value orelse return false;
        return value.truncated;
    }
};

pub const Document = struct {
    entry_index: ?u16 = null,
    editor: EditorBuffer = .{},
    state: PreviewState = .idle,
    source_truncated: bool = false,
    read_key: u64 = 0,
    save_key: u64 = 0,
    save_queued: bool = false,
    saved_len: usize = 0,
    saved_hash: u64 = 0,
    pending_save_len: usize = 0,
    pending_save_hash: u64 = 0,

    pub fn dirty(document: *const Document) bool {
        if (document.state != .text) return false;
        const text = document.editor.text();
        return text.len != document.saved_len or
            std.hash.Wyhash.hash(0, text) != document.saved_hash;
    }

    fn reset(
        document: *Document,
        allocator: std.mem.Allocator,
        entry_index: u16,
        state: PreviewState,
    ) !void {
        document.deinit();
        document.* = .{
            .entry_index = entry_index,
            .editor = try EditorBuffer.init(allocator, ""),
            .state = state,
        };
    }

    fn deinit(document: *Document) void {
        document.editor.deinit();
    }

    fn adopt(document: *Document, bytes: []const u8, effect_truncated: bool) void {
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
            document.editor.clear();
            document.state = .binary;
            document.source_truncated = false;
            document.saved_len = 0;
            document.saved_hash = 0;
            return;
        }

        const validated_len = if (std.unicode.utf8ValidateSlice(bytes))
            bytes.len
        else if (effect_truncated)
            utf8PrefixBeforeIncompleteTail(bytes) orelse {
                document.editor.clear();
                document.state = .binary;
                document.source_truncated = false;
                document.saved_len = 0;
                document.saved_hash = 0;
                return;
            }
        else {
            document.editor.clear();
            document.state = .binary;
            document.source_truncated = false;
            document.saved_len = 0;
            document.saved_hash = 0;
            return;
        };

        var len = @min(validated_len, max_preview_bytes);
        while (len > 0 and len < validated_len and (bytes[len] & 0xc0) == 0x80) len -= 1;
        document.editor.set(bytes[0..len]);
        document.state = .text;
        document.source_truncated = effect_truncated or len < validated_len;
        document.saved_len = document.editor.text().len;
        document.saved_hash = std.hash.Wyhash.hash(0, document.editor.text());
    }
};

/// A bounded read can stop midway through its final UTF-8 scalar. Repair
/// only that provably incomplete tail; arbitrary malformed bytes (including
/// an invalid final lead byte) must still select the binary-file state.
fn utf8PrefixBeforeIncompleteTail(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    var scalar_start = bytes.len - 1;
    while (scalar_start > 0 and (bytes[scalar_start] & 0xc0) == 0x80) scalar_start -= 1;
    const tail = bytes[scalar_start..];
    const scalar_len: usize = switch (tail[0]) {
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => return null,
    };
    if (scalar_len <= tail.len) return null;
    for (tail[1..]) |byte| {
        if ((byte & 0xc0) != 0x80) return null;
    }
    if (tail.len > 1) switch (tail[0]) {
        0xe0 => if (tail[1] < 0xa0) return null,
        0xed => if (tail[1] > 0x9f) return null,
        0xf0 => if (tail[1] < 0x90) return null,
        0xf4 => if (tail[1] > 0x8f) return null,
        else => {},
    };
    if (!std.unicode.utf8ValidateSlice(bytes[0..scalar_start])) return null;
    return scalar_start;
}

pub const Model = struct {
    root_storage: [max_root_path_bytes]u8 = [_]u8{0} ** max_root_path_bytes,
    root_len: usize = 0,
    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,
    tree_selected_entry: ?u16 = null,
    selected_entry: ?u16 = null,
    pinned_entries: [max_open_tabs]u16 = [_]u16{0} ** max_open_tabs,
    pinned_count: usize = 0,
    preview_entry: ?u16 = null,
    hovered_tab: ?u16 = null,
    renaming_entry: ?u16 = null,
    pending_rename_entry: ?u16 = null,
    rename_buffer: RenameTextBuffer = .{},
    rename_serial: u64 = 0,
    pending_expand_entry: ?u16 = null,
    expand_serial: u64 = 0,
    scan_truncated: bool = false,
    scan_had_errors: bool = false,
    sidebar_fraction: f32 = 0.30,
    chrome_leading: f32 = 0,
    titlebar_height: f32 = titlebar_natural_height,

    picker_serial: u64 = 0,
    next_file_key: u64 = 100,
    documents: [max_documents]Document = @splat(.{}),
    document_count: usize = 0,

    status_storage: [max_status_bytes]u8 = [_]u8{0} ** max_status_bytes,
    status_len: usize = 0,

    /// Backing storage and effect-only state are intentionally hidden
    /// behind view query functions or used only by Zig update/host code.
    pub const view_unbound = .{
        "root_storage",
        "root_len",
        "entries",
        "tree_selected_entry",
        "selected_entry",
        "pinned_entries",
        "pinned_count",
        "preview_entry",
        "hovered_tab",
        "renaming_entry",
        "pending_rename_entry",
        "rename_buffer",
        "rename_serial",
        "pending_expand_entry",
        "expand_serial",
        "scan_truncated",
        "scan_had_errors",
        "picker_serial",
        "next_file_key",
        "documents",
        "document_count",
        "status_storage",
        "status_len",
    };

    pub fn rootPath(model: *const Model) []const u8 {
        return model.root_storage[0..model.root_len];
    }

    pub fn rootName(model: *const Model) []const u8 {
        const path = model.rootPath();
        if (path.len == 0) return "Code Explorer";
        const trimmed = std.mem.trimEnd(u8, path, "/\\");
        if (trimmed.len == 0) return path;
        return std.fs.path.basename(trimmed);
    }

    pub fn folderOpen(model: *const Model) bool {
        return model.root_len > 0;
    }

    pub fn status(model: *const Model) []const u8 {
        return model.status_storage[0..model.status_len];
    }

    pub fn renameText(model: *const Model) []const u8 {
        return model.rename_buffer.text();
    }

    pub fn preview(model: *const Model) []const u8 {
        const document = model.activeDocument() orelse return "";
        return document.editor.text();
    }

    pub fn previewState(model: *const Model) PreviewState {
        const document = model.activeDocument() orelse return .idle;
        return document.state;
    }

    pub fn previewTruncated(model: *const Model) bool {
        const document = model.activeDocument() orelse return false;
        return document.source_truncated;
    }

    pub fn codeEditable(model: *const Model) bool {
        const document = model.activeDocument() orelse return false;
        return document.state == .text and !document.source_truncated;
    }

    pub fn selectedDirty(model: *const Model) bool {
        const document = model.activeDocument() orelse return false;
        return document.state == .text and document.dirty();
    }

    pub fn saveDisabled(model: *const Model) bool {
        const document = model.activeDocument() orelse return true;
        return document.state != .text or !document.dirty() or document.source_truncated;
    }

    pub fn hasOpenTabs(model: *const Model) bool {
        return model.pinned_count > 0 or model.preview_entry != null;
    }

    pub fn hasDirtyDocuments(model: *const Model) bool {
        for (model.documents[0..model.document_count]) |*document| {
            if (document.dirty()) return true;
        }
        return false;
    }

    pub fn hasPendingWrites(model: *const Model) bool {
        for (model.documents[0..model.document_count]) |*document| {
            if (document.save_key != 0) return true;
        }
        return false;
    }

    pub fn openTabs(model: *const Model, arena: std.mem.Allocator) []const OpenTab {
        const out = arena.alloc(OpenTab, model.pinned_count + @intFromBool(model.preview_entry != null)) catch return &.{};
        var count: usize = 0;
        for (model.pinned_entries[0..model.pinned_count]) |index| {
            if (index >= model.entry_count) continue;
            const entry = &model.entries[index];
            if (entry.kind != .file) continue;
            out[count] = model.openTab(index, false);
            count += 1;
        }
        if (model.preview_entry) |index| {
            if (index < model.entry_count and model.entries[index].kind == .file and !model.isPinned(index)) {
                out[count] = model.openTab(index, true);
                count += 1;
            }
        }
        for (out[0..count]) |*tab| tab.only_tab = count == 1;
        return out[0..count];
    }

    fn openTab(model: *const Model, index: u16, preview_tab: bool) OpenTab {
        const entry = &model.entries[index];
        const active = model.selected_entry != null and model.selected_entry.? == index;
        return .{
            .index = index,
            .relative_path = entry.relativePath(),
            .name = entry.name(),
            .preview = preview_tab,
            .selected = active,
            .dirty = if (model.documentForEntry(index)) |document| document.dirty() else false,
            .show_close = active or model.hovered_tab == index,
        };
    }

    pub fn isPinned(model: *const Model, index: u16) bool {
        for (model.pinned_entries[0..model.pinned_count]) |pinned| {
            if (pinned == index) return true;
        }
        return false;
    }

    pub fn selectedIsFile(model: *const Model) bool {
        const entry = model.selected() orelse return false;
        return entry.kind == .file;
    }

    pub fn selectedPath(model: *const Model) []const u8 {
        const entry = model.selected() orelse return "";
        return entry.relativePath();
    }

    pub fn emptyEditorTitle(model: *const Model) []const u8 {
        const entry = model.selected() orelse return "Select a file";
        if (entry.kind == .directory) return entry.name();
        return "Select a file";
    }

    pub fn emptyEditorDetail(model: *const Model) []const u8 {
        const entry = model.selected() orelse return "Choose a file from the tree to preview its source.";
        if (entry.kind == .directory) return "This is a folder. Expand it or select a file.";
        return "Choose a file from the tree to preview its source.";
    }

    pub fn previewLanguage(model: *const Model) native_sdk.code.Language {
        return languageForPath(model.selectedPath());
    }

    pub fn selected(model: *const Model) ?*const Entry {
        const index = model.selected_entry orelse return null;
        if (index >= model.entry_count) return null;
        return &model.entries[index];
    }

    fn activeDocument(model: *const Model) ?*const Document {
        const index = model.selected_entry orelse return null;
        return model.documentForEntry(index);
    }

    fn activeDocumentMut(model: *Model) ?*Document {
        const index = model.selected_entry orelse return null;
        return model.documentForEntryMut(index);
    }

    fn documentForEntry(model: *const Model, entry_index: u16) ?*const Document {
        for (model.documents[0..model.document_count]) |*document| {
            if (document.entry_index != null and document.entry_index.? == entry_index) return document;
        }
        return null;
    }

    fn documentForEntryMut(model: *Model, entry_index: u16) ?*Document {
        for (model.documents[0..model.document_count]) |*document| {
            if (document.entry_index != null and document.entry_index.? == entry_index) return document;
        }
        return null;
    }

    fn ensureDocument(
        model: *Model,
        allocator: std.mem.Allocator,
        entry_index: u16,
    ) ?*Document {
        if (model.documentForEntryMut(entry_index)) |document| return document;
        if (model.document_count >= model.documents.len) return null;
        const document = &model.documents[model.document_count];
        document.reset(allocator, entry_index, .idle) catch return null;
        model.document_count += 1;
        return document;
    }

    fn removeDocument(model: *Model, entry_index: u16) void {
        for (model.documents[0..model.document_count], 0..) |document, index| {
            if (document.entry_index == null or document.entry_index.? != entry_index) continue;
            model.documents[index].deinit();
            if (index + 1 < model.document_count) {
                std.mem.copyForwards(
                    Document,
                    model.documents[index .. model.document_count - 1],
                    model.documents[index + 1 .. model.document_count],
                );
            }
            model.document_count -= 1;
            model.documents[model.document_count] = .{};
            return;
        }
    }

    pub fn deinit(model: *Model) void {
        for (model.documents[0..model.document_count]) |*document| document.deinit();
        model.document_count = 0;
    }

    pub fn findEntry(model: *const Model, relative_path: []const u8) ?u16 {
        for (model.entries[0..model.entry_count], 0..) |*entry, index| {
            if (std.mem.eql(u8, entry.relativePath(), relative_path)) return @intCast(index);
        }
        return null;
    }

    pub fn setStatus(model: *Model, comptime format: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&model.status_storage, format, args) catch {
            model.status_len = 0;
            return;
        };
        model.status_len = written.len;
    }

    pub fn fullPath(model: *const Model, entry: *const Entry, buffer: []u8) ?[]const u8 {
        if (model.root_len == 0) return null;
        const root = std.mem.trimEnd(u8, model.rootPath(), "/\\");
        return std.fmt.bufPrint(buffer, "{s}{c}{s}", .{ root, std.fs.path.sep, entry.relativePath() }) catch null;
    }

    pub fn visible(model: *const Model, arena: std.mem.Allocator) []const VisibleEntry {
        const out = arena.alloc(VisibleEntry, model.entry_count) catch return &.{};
        var count: usize = 0;
        for (model.entries[0..model.entry_count], 0..) |*entry, index| {
            if (!model.entryVisible(entry)) continue;
            const depth = if (entry.depth > 0) entry.depth - 1 else 0;
            const renaming = model.renaming_entry != null and model.renaming_entry.? == index;
            const tree_selected = model.tree_selected_entry != null and model.tree_selected_entry.? == index;
            out[count] = .{
                .index = @intCast(index),
                .relative_path = entry.relativePath(),
                .name = entry.name(),
                .tree_level = entry.depth,
                .indent = tree_row_inset + @as(f32, @floatFromInt(depth)) * tree_depth_indent,
                .icon = if (entry.kind == .directory)
                    if (entry.expanded) "folder-open" else "folder"
                else
                    "file-text",
                .directory = entry.kind == .directory,
                .expanded = entry.expanded,
                .selected = tree_selected,
                .renaming = renaming,
            };
            count += 1;
        }
        return out[0..count];
    }

    fn entryVisible(model: *const Model, entry: *const Entry) bool {
        var parent = entry.parent;
        while (parent) |index| {
            const ancestor = &model.entries[index];
            if (!ancestor.expanded) return false;
            parent = ancestor.parent;
        }
        return true;
    }
};

pub const VisibleEntry = struct {
    index: u16,
    relative_path: []const u8,
    name: []const u8,
    tree_level: u16,
    indent: f32,
    icon: []const u8,
    directory: bool,
    expanded: bool,
    selected: bool,
    renaming: bool,
};

pub const OpenTab = struct {
    index: u16,
    relative_path: []const u8,
    name: []const u8,
    preview: bool,
    selected: bool,
    dirty: bool,
    show_close: bool,
    only_tab: bool = false,
};

pub const Msg = union(enum) {
    open_folder,
    new_window,
    close_window: u8,
    folder_loaded,
    folder_dialog_cancelled,
    folder_dialog_failed,
    directory_loaded,
    select_entry: u16,
    preview_entry: u16,
    pin_entry: u16,
    pin_tree_entry,
    begin_rename: u16,
    edit_rename: canvas.TextInputEvent,
    commit_rename,
    rename_finished,
    activate_tab: u16,
    hover_tab: u16,
    unhover_tab: u16,
    close_tab: u16,
    close_other_tabs: u16,
    close_active_tab,
    previous_tab,
    next_tab,
    toggle_entry: u16,
    edit_code: canvas.TextInputEvent,
    save_file,
    file_done: native_sdk.EffectFileResult,
    sidebar_resized: f32,
    chrome_changed: native_sdk.WindowChrome,

    /// The host wrapper and effect executor dispatch these messages;
    /// they are not user events bound by the markup.
    pub const view_unbound = .{
        "new_window",
        "close_window",
        "folder_loaded",
        "folder_dialog_cancelled",
        "folder_dialog_failed",
        "directory_loaded",
        "rename_finished",
        "file_done",
        "chrome_changed",
    };
};

const dev_markup_reload = builtin.mode == .Debug;
pub const BrowserSession = struct {
    open: bool = false,
    handled_picker_serial: u64 = 0,
    handled_rename_serial: u64 = 0,
    handled_expand_serial: u64 = 0,
    browser: Model = .{},

    fn reset(session: *BrowserSession, index: usize) void {
        const next_file_key = @max(session.browser.next_file_key, fileKeyBase(index));
        session.browser.deinit();
        session.* = .{
            .open = true,
            .browser = .{ .next_file_key = next_file_key },
        };
    }

    fn close(session: *BrowserSession) void {
        const next_file_key = session.browser.next_file_key;
        session.browser.deinit();
        session.* = .{ .browser = .{ .next_file_key = next_file_key } };
    }
};

pub const AppModel = struct {
    sessions: [max_browser_windows]BrowserSession = @splat(.{}),
    active_session: u8 = 0,
    pending_focus_session: ?u8 = null,
    pending_close_main: bool = false,

    pub fn init(model: *AppModel) void {
        model.sessions[0].reset(0);
    }

    pub fn deinit(model: *AppModel) void {
        for (&model.sessions) |*session| session.close();
    }

    pub fn browser(model: *const AppModel, index: usize) ?*const Model {
        if (index >= model.sessions.len or !model.sessions[index].open) return null;
        return &model.sessions[index].browser;
    }

    pub fn browserMut(model: *AppModel, index: usize) ?*Model {
        if (index >= model.sessions.len or !model.sessions[index].open) return null;
        return &model.sessions[index].browser;
    }

    fn activeBrowserMut(model: *AppModel) *Model {
        return model.browserMut(model.active_session) orelse &model.sessions[0].browser;
    }

    fn closeSecondarySession(model: *AppModel, index: u8) void {
        if (index == 0 or index >= model.sessions.len) return;
        if (model.sessions[index].browser.hasPendingWrites()) {
            model.sessions[index].browser.setStatus("Wait for file saves before closing this window.", .{});
            return;
        }
        if (model.sessions[index].browser.hasDirtyDocuments()) {
            model.sessions[index].browser.setStatus("Save all files before closing this window.", .{});
            return;
        }
        model.sessions[index].close();
        if (model.active_session == index) model.active_session = 0;
        if (model.pending_focus_session == index) model.pending_focus_session = null;
    }
};

pub const BrowserUiApp = native_sdk.UiAppWithFeatures(AppModel, Msg, .{ .runtime_markup = dev_markup_reload });
pub const Effects = BrowserUiApp.Effects;
pub const BrowserUi = canvas.Ui(Msg);

fn fileKeyBase(index: usize) u64 {
    return 100 + @as(u64, @intCast(index)) * 1_000_000;
}

pub fn appUpdate(model: *AppModel, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .new_window => {
            for (model.sessions[1..], 1..) |*session, index| {
                if (session.open) continue;
                session.reset(index);
                model.active_session = @intCast(index);
                model.pending_focus_session = @intCast(index);
                return;
            }
            model.activeBrowserMut().setStatus("Window limit reached ({d}).", .{max_browser_windows});
        },
        .close_window => |index| {
            model.closeSecondarySession(index);
        },
        .close_active_tab => {
            const index = model.active_session;
            const browser = model.browserMut(index) orelse return;
            if (browser.hasOpenTabs()) {
                update(browser, msg, fx);
            } else if (index == 0) {
                // The scene owns the main window, so the host wrapper
                // performs its runtime close after this dispatch returns.
                model.pending_close_main = true;
            } else {
                // Declared secondary windows close by disappearing from
                // `browserWindows`; reconciliation removes the platform
                // window without disturbing any other session.
                model.closeSecondarySession(index);
            }
        },
        .file_done => |result| {
            // Effect keys are partitioned per session. Search all open
            // sessions so a file completion is delivered to its owner even
            // when the user focused another window while the I/O was live.
            for (&model.sessions) |*session| {
                if (session.open) applyFileResult(&session.browser, result, fx);
            }
        },
        // `UiApp.on_chrome` describes the scene's main canvas. Declared
        // windows get their titlebar geometry from their descriptor and
        // must not steal a later fullscreen/inset update just because they
        // were the last browser session to receive input.
        .chrome_changed => update(&model.sessions[0].browser, msg, fx),
        else => update(model.activeBrowserMut(), msg, fx),
    }
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .new_window, .close_window => unreachable,
        .open_folder => {
            if (model.hasPendingWrites()) {
                model.setStatus("Wait for file saves before opening another folder.", .{});
                return;
            }
            if (model.hasDirtyDocuments()) {
                model.setStatus("Save all files before opening another folder.", .{});
                return;
            }
            model.picker_serial +%= 1;
        },
        .folder_loaded => {},
        .folder_dialog_cancelled => model.setStatus("Folder selection cancelled.", .{}),
        .folder_dialog_failed => model.setStatus("The folder dialog could not be opened.", .{}),
        .directory_loaded => {},
        .select_entry => |index| selectEntry(model, index),
        .preview_entry => |index| previewEntry(model, fx, index),
        .pin_entry => |index| pinEntry(model, fx, index),
        .pin_tree_entry => if (model.tree_selected_entry) |index| pinEntry(model, fx, index),
        .begin_rename => |index| beginRename(model, index),
        .edit_rename => |edit| editRename(model, edit),
        .commit_rename => commitRename(model),
        .rename_finished => {},
        .activate_tab => |index| activateTab(model, fx, index),
        .hover_tab => |index| if (tabIsOpen(model, index)) {
            model.hovered_tab = index;
        },
        .unhover_tab => |index| if (model.hovered_tab == index) {
            model.hovered_tab = null;
        },
        .close_tab => |index| closeTab(model, fx, index),
        .close_other_tabs => |index| closeOtherTabs(model, fx, index),
        .close_active_tab => if (model.selected_entry) |index| closeTab(model, fx, index),
        .previous_tab => cycleOpenTab(model, fx, false),
        .next_tab => cycleOpenTab(model, fx, true),
        .toggle_entry => |index| toggleEntry(model, index),
        .edit_code => |edit| editCode(model, edit),
        .save_file => saveActiveFile(model, fx),
        .file_done => |result| applyFileResult(model, result, fx),
        .sidebar_resized => |fraction| model.sidebar_fraction = fraction,
        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
            model.titlebar_height = @max(titlebar_natural_height, chrome.insets.top);
        },
    }
}

fn selectEntry(model: *Model, index: u16) void {
    if (index >= model.entry_count) return;
    const entry = &model.entries[index];
    model.tree_selected_entry = index;
    model.setStatus("{s}", .{entry.relativePath()});
}

fn beginRename(model: *Model, index: u16) void {
    if (index >= model.entry_count) return;
    const entry = &model.entries[index];
    model.tree_selected_entry = index;
    model.renaming_entry = index;
    model.pending_rename_entry = null;
    model.rename_buffer.set(entry.name());
    model.setStatus("Rename {s}", .{entry.relativePath()});
}

fn editRename(model: *Model, edit: canvas.TextInputEvent) void {
    if (model.renaming_entry == null or model.pending_rename_entry != null) return;
    model.rename_buffer.apply(edit);
    if (model.rename_buffer.truncated) {
        model.setStatus("Names are limited to {d} bytes.", .{max_name_bytes});
    }
}

fn commitRename(model: *Model) void {
    const index = model.renaming_entry orelse return;
    if (index >= model.entry_count or model.pending_rename_entry != null) return;
    const name = model.rename_buffer.text();
    if (!validEntryName(name)) {
        model.setStatus("Enter a name without path separators.", .{});
        return;
    }
    const entry = &model.entries[index];
    if (std.mem.eql(u8, name, entry.name())) {
        model.renaming_entry = null;
        model.setStatus("{s}", .{entry.relativePath()});
        return;
    }
    if (!renamedPathsFit(model, index, name)) {
        model.setStatus("That renamed path is too long.", .{});
        return;
    }
    if (renameTouchesPendingIo(model, index)) {
        model.setStatus("Wait for file activity to finish before renaming.", .{});
        return;
    }
    model.pending_rename_entry = index;
    model.rename_serial +%= 1;
    if (model.rename_serial == 0) model.rename_serial = 1;
    model.setStatus("Renaming {s}…", .{entry.name()});
}

fn validEntryName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\") == null;
}

fn previewEntry(model: *Model, fx: *Effects, index: u16) void {
    if (index >= model.entry_count or model.entries[index].kind != .file) return;
    model.tree_selected_entry = index;
    if (!model.isPinned(index)) {
        if (model.preview_entry) |previous| {
            if (previous != index and !model.isPinned(previous)) {
                if (model.documentForEntry(previous)) |document| {
                    if (document.save_key != 0) {
                        model.setStatus("Wait for {s} to finish saving before replacing its preview tab.", .{model.entries[previous].name()});
                        return;
                    }
                    if (document.dirty()) {
                        model.setStatus("Save {s} before replacing its preview tab.", .{model.entries[previous].name()});
                        return;
                    }
                    if (document.read_key != 0) {
                        fx.cancel(document.read_key);
                    }
                }
                model.removeDocument(previous);
            }
        }
        model.preview_entry = index;
    }
    activateFile(model, fx, index);
}

fn pinEntry(model: *Model, fx: *Effects, index: u16) void {
    if (index >= model.entry_count or model.entries[index].kind != .file) return;
    if (!model.isPinned(index)) {
        if (model.pinned_count == model.pinned_entries.len) {
            model.setStatus("Open tab limit reached ({d}).", .{max_open_tabs});
            return;
        }
        model.pinned_entries[model.pinned_count] = index;
        model.pinned_count += 1;
    }
    if (model.preview_entry != null and model.preview_entry.? == index) {
        model.preview_entry = null;
    }
    if (model.selected_entry == null or model.selected_entry.? != index) {
        activateFile(model, fx, index);
    }
}

fn activateTab(model: *Model, fx: *Effects, index: u16) void {
    if (!model.isPinned(index) and model.preview_entry != index) return;
    activateFile(model, fx, index);
}

fn closeTab(model: *Model, fx: *Effects, index: u16) void {
    if (!tabIsOpen(model, index)) return;
    if (model.documentForEntry(index)) |document| {
        if (document.save_key != 0) {
            model.setStatus("Wait for {s} to finish saving before closing it.", .{model.entries[index].name()});
            return;
        }
        if (document.dirty()) {
            model.setStatus("Save {s} before closing it.", .{model.entries[index].name()});
            return;
        }
    }

    const was_selected = model.selected_entry == index;
    const replacement = if (was_selected) replacementAfterClosing(model, index) else null;
    closeTabUnchecked(model, fx, index);
    if (was_selected) {
        model.selected_entry = null;
        if (replacement) |next| activateFile(model, fx, next);
    }
    model.setStatus("Closed {s}.", .{model.entries[index].name()});
}

fn closeOtherTabs(model: *Model, fx: *Effects, index: u16) void {
    if (!tabIsOpen(model, index)) return;

    var open_storage: [max_documents]u16 = undefined;
    const open = collectOpenTabIndices(model, &open_storage);
    for (open) |other| {
        if (other == index) continue;
        if (model.documentForEntry(other)) |document| {
            if (document.save_key != 0) {
                model.setStatus("Wait for {s} to finish saving before closing other tabs.", .{model.entries[other].name()});
                return;
            }
            if (document.dirty()) {
                model.setStatus("Save {s} before closing other tabs.", .{model.entries[other].name()});
                return;
            }
        }
    }
    for (open) |other| {
        if (other != index) closeTabUnchecked(model, fx, other);
    }
    if (model.selected_entry != index) {
        model.selected_entry = null;
        activateFile(model, fx, index);
    }
    model.setStatus("Closed other tabs.", .{});
}

fn tabIsOpen(model: *const Model, index: u16) bool {
    return model.isPinned(index) or model.preview_entry == index;
}

fn collectOpenTabIndices(model: *const Model, out: *[max_documents]u16) []const u16 {
    var count: usize = 0;
    for (model.pinned_entries[0..model.pinned_count]) |pinned| {
        if (pinned >= model.entry_count or model.entries[pinned].kind != .file) continue;
        out[count] = pinned;
        count += 1;
    }
    if (model.preview_entry) |preview| {
        if (preview < model.entry_count and
            model.entries[preview].kind == .file and
            !model.isPinned(preview))
        {
            out[count] = preview;
            count += 1;
        }
    }
    return out[0..count];
}

fn cycleOpenTab(model: *Model, fx: *Effects, forward: bool) void {
    var open_storage: [max_documents]u16 = undefined;
    const open = collectOpenTabIndices(model, &open_storage);
    if (open.len == 0) return;

    var current_position: ?usize = null;
    if (model.selected_entry) |selected| {
        for (open, 0..) |candidate, position| {
            if (candidate == selected) {
                current_position = position;
                break;
            }
        }
    }
    const target_position = if (current_position) |position|
        if (forward)
            (position + 1) % open.len
        else if (position == 0)
            open.len - 1
        else
            position - 1
    else if (forward)
        0
    else
        open.len - 1;
    const target = open[target_position];
    if (model.selected_entry != null and model.selected_entry.? == target) return;
    activateFile(model, fx, target);
}

fn replacementAfterClosing(model: *const Model, index: u16) ?u16 {
    var open_storage: [max_documents]u16 = undefined;
    const open = collectOpenTabIndices(model, &open_storage);
    for (open, 0..) |candidate, position| {
        if (candidate != index) continue;
        if (position + 1 < open.len) return open[position + 1];
        if (position > 0) return open[position - 1];
        return null;
    }
    return null;
}

fn closeTabUnchecked(model: *Model, fx: *Effects, index: u16) void {
    if (model.hovered_tab == index) model.hovered_tab = null;
    if (model.preview_entry == index) model.preview_entry = null;
    for (model.pinned_entries[0..model.pinned_count], 0..) |pinned, position| {
        if (pinned != index) continue;
        if (position + 1 < model.pinned_count) {
            std.mem.copyForwards(
                u16,
                model.pinned_entries[position .. model.pinned_count - 1],
                model.pinned_entries[position + 1 .. model.pinned_count],
            );
        }
        model.pinned_count -= 1;
        model.pinned_entries[model.pinned_count] = 0;
        break;
    }
    if (model.documentForEntry(index)) |document| {
        if (document.read_key != 0) {
            fx.cancel(document.read_key);
        }
    }
    model.removeDocument(index);
}

fn activateFile(model: *Model, fx: *Effects, index: u16) void {
    if (index >= model.entry_count or model.entries[index].kind != .file) return;
    model.tree_selected_entry = index;
    model.selected_entry = index;
    const document = model.ensureDocument(fx.allocator, index) orelse {
        model.setStatus("Open document limit reached ({d}).", .{max_documents});
        return;
    };
    if (document.state == .text or document.state == .binary or document.state == .loading) return;
    const entry = &model.entries[index];
    document.state = .loading;
    document.editor.clear();
    document.source_truncated = false;
    model.next_file_key +%= 1;
    if (model.next_file_key == 0) model.next_file_key = 100;
    document.read_key = model.next_file_key;

    var path_buffer: [native_sdk.max_effect_file_path_bytes]u8 = undefined;
    const path = model.fullPath(entry, &path_buffer) orelse {
        document.read_key = 0;
        document.state = .failed;
        model.setStatus("That file path is too long to read.", .{});
        return;
    };
    model.setStatus("Opening {s}…", .{entry.name()});
    fx.readFile(.{
        .key = document.read_key,
        .path = path,
        .on_result = Effects.fileMsg(.file_done),
    });
}

fn toggleEntry(model: *Model, index: u16) void {
    if (index >= model.entry_count) return;
    const entry = &model.entries[index];
    if (entry.kind != .directory) return;
    if (entry.expanded) {
        entry.expanded = false;
        return;
    }
    if (entry.children_loaded) {
        entry.expanded = true;
        return;
    }
    model.pending_expand_entry = index;
    model.expand_serial +%= 1;
    if (model.expand_serial == 0) model.expand_serial = 1;
    model.setStatus("Loading {s}…", .{entry.relativePath()});
}

fn editCode(model: *Model, edit: canvas.TextInputEvent) void {
    const selected_index = model.selected_entry orelse return;
    const document = model.activeDocumentMut() orelse return;
    if (document.state != .text or document.source_truncated) {
        if (document.source_truncated) {
            model.setStatus("This cut preview is read-only to avoid overwriting the full file.", .{});
        }
        return;
    }
    if (!model.isPinned(selected_index)) {
        if (model.pinned_count < model.pinned_entries.len) {
            model.pinned_entries[model.pinned_count] = selected_index;
            model.pinned_count += 1;
            if (model.preview_entry == selected_index) model.preview_entry = null;
        }
        // At the tab limit the edited preview remains in its dedicated
        // slot and cannot be replaced until saved; no edit is discarded.
    }
    document.editor.apply(edit);
    if (document.editor.truncated()) {
        model.setStatus("File buffer is full ({d} KiB cap).", .{max_preview_bytes / 1024});
    } else {
        model.setStatus("{s}{s}", .{
            model.entries[selected_index].relativePath(),
            if (document.dirty()) " · unsaved" else "",
        });
    }
}

fn saveActiveFile(model: *Model, fx: *Effects) void {
    const selected_index = model.selected_entry orelse return;
    const document = model.activeDocumentMut() orelse return;
    if (document.state != .text or !document.dirty()) return;
    if (document.source_truncated) {
        model.setStatus("Cannot save a cut preview; the full file was not loaded.", .{});
        return;
    }
    if (document.save_key != 0) {
        document.save_queued = true;
        model.setStatus("Saving {s}… latest edits queued", .{model.entries[selected_index].name()});
        return;
    }
    startDocumentSave(model, fx, selected_index);
}

fn startDocumentSave(model: *Model, fx: *Effects, entry_index: u16) void {
    if (entry_index >= model.entry_count) return;
    const entry = &model.entries[entry_index];
    const document = model.documentForEntryMut(entry_index) orelse return;
    if (document.state != .text or !document.dirty() or document.source_truncated or document.save_key != 0) return;
    var path_buffer: [native_sdk.max_effect_file_path_bytes]u8 = undefined;
    const path = model.fullPath(entry, &path_buffer) orelse {
        model.setStatus("That file path is too long to save.", .{});
        return;
    };
    model.next_file_key +%= 1;
    if (model.next_file_key == 0) model.next_file_key = 100;
    document.save_key = model.next_file_key;
    document.pending_save_len = document.editor.text().len;
    document.pending_save_hash = std.hash.Wyhash.hash(0, document.editor.text());
    model.setStatus("Saving {s}…", .{entry.name()});
    fx.writeFile(.{
        .key = document.save_key,
        .path = path,
        .bytes = document.editor.text(),
        .on_result = Effects.fileMsg(.file_done),
    });
}

fn applyFileResult(model: *Model, result: native_sdk.EffectFileResult, fx: *Effects) void {
    for (model.documents[0..model.document_count]) |*document| {
        const index = document.entry_index orelse continue;
        const entry = &model.entries[index];
        if (result.op == .read and result.key == document.read_key) {
            document.read_key = 0;
            switch (result.outcome) {
                .ok, .truncated => {
                    document.adopt(result.bytes, result.outcome == .truncated);
                    switch (document.state) {
                        .text => if (document.source_truncated)
                            model.setStatus("{s} · preview limited to {d} KiB", .{ entry.relativePath(), max_preview_bytes / 1024 })
                        else
                            model.setStatus("{s} · {d} bytes", .{ entry.relativePath(), document.editor.text().len }),
                        .binary => model.setStatus("{s} · binary file", .{entry.relativePath()}),
                        else => {},
                    }
                },
                else => {
                    document.state = .failed;
                    model.setStatus("Could not open {s}: {s}", .{ entry.name(), @tagName(result.outcome) });
                },
            }
            return;
        }
        if (result.op == .write and result.key == document.save_key) {
            document.save_key = 0;
            const save_queued = document.save_queued;
            document.save_queued = false;
            switch (result.outcome) {
                .ok => {
                    // The acknowledgement describes the copied bytes from
                    // the request. If the user typed during the write,
                    // `dirty()` remains true against this saved snapshot.
                    document.saved_len = document.pending_save_len;
                    document.saved_hash = document.pending_save_hash;
                    model.setStatus("Saved {s}{s}", .{
                        entry.relativePath(),
                        if (document.dirty()) " · newer edits remain unsaved" else "",
                    });
                },
                else => model.setStatus("Could not save {s}: {s}", .{ entry.name(), @tagName(result.outcome) }),
            }
            if (save_queued and document.dirty()) startDocumentSave(model, fx, index);
            return;
        }
    }
}

fn renameTouchesPendingIo(model: *const Model, entry_index: u16) bool {
    const renamed = &model.entries[entry_index];
    for (model.documents[0..model.document_count]) |*document| {
        const document_index = document.entry_index orelse continue;
        const document_entry = &model.entries[document_index];
        if (document_index != entry_index and
            (renamed.kind != .directory or descendantSuffix(document_entry.relativePath(), renamed.relativePath()) == null))
        {
            continue;
        }
        if (document.read_key != 0 or document.save_key != 0) return true;
    }
    return false;
}

fn renamedRelativePath(entry: *const Entry, new_name: []const u8, buffer: []u8) ?[]const u8 {
    const parent_path = std.fs.path.dirname(entry.relativePath()) orelse return std.fmt.bufPrint(buffer, "{s}", .{new_name}) catch null;
    return std.fmt.bufPrint(buffer, "{s}{c}{s}", .{ parent_path, std.fs.path.sep, new_name }) catch null;
}

fn renamedPathsFit(model: *const Model, entry_index: u16, new_name: []const u8) bool {
    const renamed = &model.entries[entry_index];
    var path_storage: [max_relative_path_bytes]u8 = undefined;
    const new_path = renamedRelativePath(renamed, new_name, &path_storage) orelse return false;
    if (renamed.kind != .directory) return true;
    for (model.entries[0..model.entry_count]) |*entry| {
        const suffix = descendantSuffix(entry.relativePath(), renamed.relativePath()) orelse continue;
        if (new_path.len + suffix.len > max_relative_path_bytes) return false;
    }
    return true;
}

fn descendantSuffix(path: []const u8, ancestor: []const u8) ?[]const u8 {
    if (path.len <= ancestor.len or !std.mem.eql(u8, path[0..ancestor.len], ancestor)) return null;
    if (path[ancestor.len] != std.fs.path.sep) return null;
    return path[ancestor.len..];
}

fn fullPathForRelative(model: *const Model, relative_path: []const u8, buffer: []u8) ?[]const u8 {
    if (model.root_len == 0) return null;
    const root = std.mem.trimEnd(u8, model.rootPath(), "/\\");
    return std.fmt.bufPrint(buffer, "{s}{c}{s}", .{ root, std.fs.path.sep, relative_path }) catch null;
}

/// Execute the model's validated rename request at the host/filesystem
/// seam. Like folder scanning, this runs outside `update`; the host follows
/// it with `.rename_finished` so the mutated model is rebuilt and presented.
pub fn performPendingRenameOnDisk(model: *Model, io: std.Io) void {
    const entry_index = model.pending_rename_entry orelse return;
    defer model.pending_rename_entry = null;
    if (entry_index >= model.entry_count) return;

    const new_name = model.rename_buffer.text();
    const entry = &model.entries[entry_index];
    var old_name_storage: [max_name_bytes]u8 = undefined;
    @memcpy(old_name_storage[0..entry.name().len], entry.name());
    const old_name = old_name_storage[0..entry.name().len];

    var relative_storage: [max_relative_path_bytes]u8 = undefined;
    const new_relative = renamedRelativePath(entry, new_name, &relative_storage) orelse {
        model.setStatus("That renamed path is too long.", .{});
        return;
    };
    for (model.entries[0..model.entry_count], 0..) |*candidate, index| {
        if (index != entry_index and std.mem.eql(u8, candidate.relativePath(), new_relative)) {
            model.setStatus("An item named {s} already exists.", .{new_name});
            return;
        }
    }

    var old_full_storage: [native_sdk.max_effect_file_path_bytes]u8 = undefined;
    var new_full_storage: [native_sdk.max_effect_file_path_bytes]u8 = undefined;
    const old_full = model.fullPath(entry, &old_full_storage) orelse {
        model.setStatus("That file path is too long to rename.", .{});
        return;
    };
    const new_full = fullPathForRelative(model, new_relative, &new_full_storage) orelse {
        model.setStatus("That file path is too long to rename.", .{});
        return;
    };

    const cwd = std.Io.Dir.cwd();
    const case_only_source_alias = caseOnlyRenameResolvesToSource(io, old_full, new_full, old_name, new_name);
    const rename_result = if (case_only_source_alias)
        // On a case-insensitive volume the destination is the source itself;
        // the replacing primitive is the only spelling-only rename path.
        cwd.rename(old_full, cwd, new_full, io)
    else
        renameWithoutReplace(cwd, old_full, cwd, new_full, io);
    rename_result catch |err| {
        if (err == error.PathAlreadyExists) {
            model.setStatus("An item named {s} already exists.", .{new_name});
        } else {
            model.setStatus("Could not rename {s}: {s}", .{ old_name, @errorName(err) });
        }
        return;
    };

    applyRenamedEntry(model, entry_index, new_name) catch |err| {
        // Validation preflights every bounded path before the filesystem
        // move, so reaching this is an internal consistency failure rather
        // than a recoverable user error.
        model.setStatus("Renamed on disk, but the tree could not update: {s}", .{@errorName(err)});
        return;
    };
    model.renaming_entry = null;
    model.setStatus("Renamed {s} to {s}.", .{ old_name, new_name });
}

/// Atomically move a path without replacing an existing destination.
/// Zig's non-Linux POSIX fallback uses hard-link-and-unlink, which cannot move
/// directories. macOS provides the same no-replace guarantee for every path
/// kind through `renameatx_np(RENAME_EXCL)`.
fn renameWithoutReplace(
    old_dir: std.Io.Dir,
    old_path: []const u8,
    new_dir: std.Io.Dir,
    new_path: []const u8,
    io: std.Io,
) std.Io.Dir.RenamePreserveError!void {
    if (builtin.os.tag != .macos) return old_dir.renamePreserve(old_path, new_dir, new_path, io);

    const Darwin = struct {
        extern "c" fn renameatx_np(
            from_fd: std.posix.fd_t,
            from: [*:0]const u8,
            to_fd: std.posix.fd_t,
            to: [*:0]const u8,
            flags: c_uint,
        ) c_int;
    };
    const rename_exclusive: c_uint = 0x00000004;
    const old_path_z = try std.posix.toPosixPath(old_path);
    const new_path_z = try std.posix.toPosixPath(new_path);

    try io.checkCancel();
    while (true) switch (std.c.errno(Darwin.renameatx_np(
        old_dir.handle,
        &old_path_z,
        new_dir.handle,
        &new_path_z,
        rename_exclusive,
    ))) {
        .SUCCESS => return,
        .INTR => {
            try io.checkCancel();
            continue;
        },
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .BUSY, .TXTBSY => return error.FileBusy,
        .DQUOT => return error.DiskQuota,
        .IO => return error.HardwareFailure,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .MLINK => return error.LinkQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .EXIST, .NOTEMPTY => return error.PathAlreadyExists,
        .OPNOTSUPP => return error.OperationUnsupported,
        .ROFS => return error.ReadOnlyFileSystem,
        .XDEV => return error.CrossDevice,
        .NODEV => return error.NoDevice,
        .CANCELED => return error.Canceled,
        .ILSEQ => return error.BadPathName,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

/// Case-insensitive volumes report the source itself when probing a new
/// capitalization. Canonical paths distinguish that alias from a hard link
/// with a different directory entry, so only the former may bypass the
/// destination-exists guard.
fn caseOnlyRenameResolvesToSource(
    io: std.Io,
    old_path: []const u8,
    new_path: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) bool {
    if (std.mem.eql(u8, old_name, new_name) or !std.ascii.eqlIgnoreCase(old_name, new_name)) return false;
    var old_real_storage: [std.fs.max_path_bytes]u8 = undefined;
    var new_real_storage: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const old_real_len = cwd.realPathFile(io, old_path, &old_real_storage) catch return false;
    const new_real_len = cwd.realPathFile(io, new_path, &new_real_storage) catch return false;
    return std.mem.eql(u8, old_real_storage[0..old_real_len], new_real_storage[0..new_real_len]);
}

fn applyRenamedEntry(model: *Model, entry_index: u16, new_name: []const u8) !void {
    if (entry_index >= model.entry_count or !renamedPathsFit(model, entry_index, new_name)) return error.PathTooLong;
    var old_path_storage: [max_relative_path_bytes]u8 = undefined;
    const old_path_len = model.entries[entry_index].relativePath().len;
    @memcpy(old_path_storage[0..old_path_len], model.entries[entry_index].relativePath());
    const old_path = old_path_storage[0..old_path_len];
    const renamed_kind = model.entries[entry_index].kind;

    var new_path_storage: [max_relative_path_bytes]u8 = undefined;
    const new_path = renamedRelativePath(&model.entries[entry_index], new_name, &new_path_storage) orelse return error.PathTooLong;
    for (model.entries[0..model.entry_count], 0..) |*entry, index| {
        if (index == entry_index) {
            @memcpy(entry.name_storage[0..new_name.len], new_name);
            entry.name_len = new_name.len;
            @memcpy(entry.relative_storage[0..new_path.len], new_path);
            entry.relative_len = new_path.len;
            continue;
        }
        if (renamed_kind != .directory) continue;
        const suffix = descendantSuffix(entry.relativePath(), old_path) orelse continue;
        var suffix_storage: [max_relative_path_bytes]u8 = undefined;
        @memcpy(suffix_storage[0..suffix.len], suffix);
        @memcpy(entry.relative_storage[0..new_path.len], new_path);
        @memcpy(entry.relative_storage[new_path.len .. new_path.len + suffix.len], suffix_storage[0..suffix.len]);
        entry.relative_len = new_path.len + suffix.len;
    }

    sortEntriesAndRemap(model);
}

fn sortEntriesAndRemap(model: *Model) void {
    for (model.entries[0..model.entry_count], 0..) |*entry, index| {
        entry.sort_identity = @intCast(index);
    }
    std.mem.sort(Entry, model.entries[0..model.entry_count], {}, entryLessThan);
    var old_to_new: [max_entries]u16 = undefined;
    for (model.entries[0..model.entry_count], 0..) |*entry, index| {
        old_to_new[entry.sort_identity] = @intCast(index);
        entry.sort_identity = 0;
    }
    remapModelEntryIndices(model, &old_to_new);
    assignParents(model);
}

fn remapModelEntryIndices(model: *Model, old_to_new: *const [max_entries]u16) void {
    if (model.tree_selected_entry) |index| model.tree_selected_entry = old_to_new[index];
    if (model.selected_entry) |index| model.selected_entry = old_to_new[index];
    if (model.preview_entry) |index| model.preview_entry = old_to_new[index];
    if (model.hovered_tab) |index| model.hovered_tab = old_to_new[index];
    if (model.pending_expand_entry) |index| model.pending_expand_entry = old_to_new[index];
    for (model.pinned_entries[0..model.pinned_count]) |*index| index.* = old_to_new[index.*];
    for (model.documents[0..model.document_count]) |*document| {
        if (document.entry_index) |index| document.entry_index = old_to_new[index];
    }
}

/// Scan an already-open directory. This seam keeps the filesystem behavior
/// hermetic in tests while `scanFolder` supplies the production path open.
pub fn scanOpenDirectory(model: *Model, io: std.Io, allocator: std.mem.Allocator, root_path: []const u8, root_dir: std.Io.Dir) !void {
    _ = allocator;
    if (root_path.len == 0 or root_path.len > model.root_storage.len) return error.PathTooLong;
    if (model.hasPendingWrites()) return error.FileActivityPending;
    if (model.hasDirtyDocuments()) return error.UnsavedChanges;

    // A scan replaces folder-scoped data, but the picker request serial must
    // remain monotonic. Resetting it makes the host mistake the completed
    // request for another pending dialog. Preserve the other window/effect
    // state that also lives outside the selected folder.
    var next = Model{
        .sidebar_fraction = model.sidebar_fraction,
        .chrome_leading = model.chrome_leading,
        .titlebar_height = model.titlebar_height,
        .picker_serial = model.picker_serial,
        .rename_serial = model.rename_serial,
        .expand_serial = model.expand_serial,
        .next_file_key = model.next_file_key,
    };
    @memcpy(next.root_storage[0..root_path.len], root_path);
    next.root_len = root_path.len;

    // Load only the root. Descendants are read when their directory expands,
    // so one large subtree cannot spend the whole bounded model before the
    // user can even see its root-level siblings.
    var root_iterator = root_dir.iterate();
    while (true) {
        const maybe_entry = root_iterator.next(io) catch {
            next.scan_had_errors = true;
            break;
        };
        const dir_entry = maybe_entry orelse break;
        if (next.entry_count == next.entries.len) {
            next.scan_truncated = true;
            break;
        }

        var entry = Entry{};
        entry.setRoot(dir_entry) catch {
            next.scan_had_errors = true;
            continue;
        };
        next.entries[next.entry_count] = entry;
        next.entry_count += 1;
    }

    std.mem.sort(Entry, next.entries[0..next.entry_count], {}, entryLessThan);
    assignParents(&next);
    next.setStatus("{d} root items{s}{s}", .{
        next.entry_count,
        if (next.scan_truncated) " · tree capped" else "",
        if (next.scan_had_errors) " · some folders unavailable" else "",
    });
    model.deinit();
    model.* = next;
}

/// Populate one directory's immediate children when its tree row expands.
/// Entries keep fixed-capacity storage, but the budget now follows explored
/// folders rather than disappearing into an eager depth-first walk.
pub fn loadDirectoryChildren(model: *Model, io: std.Io, entry_index: u16) !void {
    if (entry_index >= model.entry_count) return error.InvalidEntry;
    const parent_entry = &model.entries[entry_index];
    if (parent_entry.kind != .directory) return error.NotDir;
    if (parent_entry.children_loaded) {
        model.entries[entry_index].expanded = true;
        return;
    }

    var full_path_storage: [native_sdk.max_effect_file_path_bytes]u8 = undefined;
    const full_path = model.fullPath(parent_entry, &full_path_storage) orelse return error.PathTooLong;
    var dir = try std.Io.Dir.cwd().openDir(io, full_path, .{ .iterate = true });
    defer dir.close(io);

    try loadOpenDirectoryChildren(model, io, entry_index, dir);
}

/// Open-directory seam for hermetic expansion tests.
pub fn loadOpenDirectoryChildren(model: *Model, io: std.Io, entry_index: u16, dir: std.Io.Dir) !void {
    if (entry_index >= model.entry_count) return error.InvalidEntry;
    const parent_entry = &model.entries[entry_index];
    if (parent_entry.kind != .directory) return error.NotDir;
    if (parent_entry.children_loaded) {
        model.entries[entry_index].expanded = true;
        return;
    }

    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next(io) catch {
            model.scan_had_errors = true;
            break;
        };
        const dir_entry = maybe_entry orelse break;
        if (model.entry_count == model.entries.len) {
            model.scan_truncated = true;
            break;
        }

        var child = Entry{};
        child.setChild(parent_entry, dir_entry) catch {
            model.scan_had_errors = true;
            continue;
        };
        model.entries[model.entry_count] = child;
        model.entry_count += 1;
    }
    model.entries[entry_index].children_loaded = true;
    model.entries[entry_index].expanded = true;
    sortEntriesAndRemap(model);
    model.setStatus("{d} indexed items{s}{s}", .{
        model.entry_count,
        if (model.scan_truncated) " · tree capped" else "",
        if (model.scan_had_errors) " · some folders unavailable" else "",
    });
}

pub fn scanFolder(model: *Model, io: std.Io, allocator: std.mem.Allocator, root_path: []const u8) !void {
    var root_dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root_dir.close(io);
    try scanOpenDirectory(model, io, allocator, root_path, root_dir);
}

fn skipDirectory(name: []const u8) bool {
    const skipped = [_][]const u8{
        ".git",
        ".next",
        ".pnpm-store",
        ".zig-cache",
        "node_modules",
        "zig-cache",
        "zig-out",
    };
    for (skipped) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn entryLessThan(_: void, lhs: Entry, rhs: Entry) bool {
    var lhs_parts = std.mem.splitScalar(u8, lhs.relativePath(), std.fs.path.sep);
    var rhs_parts = std.mem.splitScalar(u8, rhs.relativePath(), std.fs.path.sep);
    while (true) {
        const lhs_part = lhs_parts.next();
        const rhs_part = rhs_parts.next();
        if (lhs_part == null) return rhs_part != null;
        if (rhs_part == null) return false;
        if (std.mem.eql(u8, lhs_part.?, rhs_part.?)) continue;

        // A non-final path component is necessarily a directory. At the
        // first component where two paths differ, putting that component's
        // directory subtree first gives every level the familiar
        // folders-then-files ordering while keeping each subtree contiguous.
        const lhs_directory = lhs_parts.rest().len > 0 or lhs.kind == .directory;
        const rhs_directory = rhs_parts.rest().len > 0 or rhs.kind == .directory;
        if (lhs_directory != rhs_directory) return lhs_directory;

        const insensitive = std.ascii.orderIgnoreCase(lhs_part.?, rhs_part.?);
        if (insensitive != .eq) return insensitive == .lt;
        return std.mem.order(u8, lhs_part.?, rhs_part.?) == .lt;
    }
}

fn assignParents(model: *Model) void {
    for (model.entries[0..model.entry_count]) |*entry| {
        entry.parent = null;
        const dirname = std.fs.path.dirname(entry.relativePath()) orelse continue;
        for (model.entries[0..model.entry_count], 0..) |*candidate, index| {
            if (candidate.kind == .directory and std.mem.eql(u8, candidate.relativePath(), dirname)) {
                entry.parent = @intCast(index);
                break;
            }
        }
    }
}

fn languageForPath(path: []const u8) native_sdk.code.Language {
    const extension = std.fs.path.extension(path);
    if (extension.len <= 1) return .plain;
    const name = extension[1..];
    if (std.ascii.eqlIgnoreCase(name, "zon")) return .zig;
    if (std.ascii.eqlIgnoreCase(name, "native")) return .html;
    return native_sdk.code.languageFromName(name);
}

pub const code_editor_markup = @embedFile("code-editor.native");
pub const CompiledCodeEditorView = canvas.CompiledMarkupView(Model, Msg, code_editor_markup);

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "save-file")) return .save_file;
    if (std.mem.eql(u8, name, "close-tab")) return .close_active_tab;
    if (std.mem.eql(u8, name, "open-folder")) return .open_folder;
    if (std.mem.eql(u8, name, "new-window")) return .new_window;
    if (std.mem.eql(u8, name, "previous-tab")) return .previous_tab;
    if (std.mem.eql(u8, name, "next-tab")) return .next_tab;
    return null;
}

/// Command+Down is deliberately left to this app fallback, which pins the
/// model's tree selection without interfering with the tree's plain-Enter
/// inline rename or the code editor (text entries outrank `on_key`).
pub fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (!keyboard.modifiers.hasCommandModifier() or keyboard.modifiers.alt or keyboard.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) {
        return .pin_tree_entry;
    }
    return null;
}

const code_editor_fragments = [_]canvas.MarkupFragment{
    CompiledCodeEditorView.fragment("src/code-editor.native"),
};

fn mainView(ui: *BrowserUiApp.Ui, model: *const AppModel) BrowserUiApp.Ui.Node {
    return CompiledCodeEditorView.build(ui, &model.sessions[0].browser);
}

pub fn editorWindows(
    model: *const AppModel,
    scratch: *BrowserUiApp.WindowsScratch,
) []const BrowserUiApp.WindowDescriptor {
    var count: usize = 0;
    for (model.sessions[1..], 1..) |*session, index| {
        if (!session.open) continue;
        scratch.windows[count] = .{
            .label = secondary_window_labels[index - 1],
            .canvas_label = secondary_canvas_labels[index - 1],
            .title = "Native SDK Code Editor",
            .width = window_width,
            .height = window_height,
            .min_width = window_min_width,
            .min_height = window_min_height,
            .titlebar = .hidden_inset_tall,
            .on_close = .{ .close_window = @intCast(index) },
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

fn browserWindowView(
    ui: *BrowserUiApp.Ui,
    model: *const AppModel,
    window_label: []const u8,
) BrowserUiApp.Ui.Node {
    for (secondary_window_labels, 1..) |label, index| {
        if (std.mem.eql(u8, label, window_label)) {
            return CompiledCodeEditorView.build(ui, &model.sessions[index].browser);
        }
    }
    std.debug.assert(false);
    return ui.column(.{}, .{});
}

fn browserOptions(io: std.Io) BrowserUiApp.Options {
    return .{
        .name = "code-editor",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = appUpdate,
        .on_chrome = onChrome,
        .on_command = onCommand,
        .on_key = onKey,
        .view = mainView,
        .windows_fn = editorWindows,
        .window_view = browserWindowView,
        .fragment_watch = .{ .fragments = &code_editor_fragments, .io = io },
    };
}

/// `UiApp` deliberately keeps raw `std.Io` and modal runtime services out
/// of `update`. This wrapper is the narrow host seam that presents the
/// directory picker and turns its selection into model data.
pub const CodeEditorApp = struct {
    ui_app: *BrowserUiApp,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !CodeEditorApp {
        const ui_app = try BrowserUiApp.create(allocator, browserOptions(io));
        ui_app.model.init();
        return .{
            .ui_app = ui_app,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *CodeEditorApp) void {
        self.ui_app.model.deinit();
        self.ui_app.destroy();
    }

    pub fn app(self: *CodeEditorApp) native_sdk.App {
        return .{
            .context = self,
            .name = "code-editor",
            .scene_fn = scene,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn scene(_: *anyopaque) anyerror!native_sdk.ShellConfig {
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *CodeEditorApp = @ptrCast(@alignCast(context));
        self.routeEventToSession(runtime, event_value);
        try self.ui_app.app().event(runtime, event_value);
        try self.performPendingRename(runtime);
        try self.performPendingDirectoryScan(runtime);
        self.closePendingMainWindow(runtime);
        self.focusPendingWindow(runtime);
        try self.presentPendingFolderDialog(runtime);
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *CodeEditorApp = @ptrCast(@alignCast(context));
        try self.ui_app.app().stop(runtime);
    }

    fn presentPendingFolderDialog(self: *CodeEditorApp, runtime: *native_sdk.Runtime) !void {
        for (&self.ui_app.model.sessions, 0..) |*session, index| {
            if (!session.open) continue;
            const serial = session.browser.picker_serial;
            if (serial == session.handled_picker_serial) continue;
            session.handled_picker_serial = serial;
            self.ui_app.model.active_session = @intCast(index);
            const window_id = self.windowIdForSession(runtime, index) orelse 1;

            var path_buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
            const result = runtime.showOpenDialog(.{
                .title = "Open Folder",
                .default_path = session.browser.rootPath(),
                .allow_directories = true,
                .allow_multiple = false,
            }, &path_buffer) catch {
                try self.ui_app.dispatch(runtime, window_id, .folder_dialog_failed);
                return;
            };
            if (result.count == 0) {
                try self.ui_app.dispatch(runtime, window_id, .folder_dialog_cancelled);
                return;
            }

            // Multiple selection is disabled, so the payload is one complete
            // path rather than a newline-delimited list. Preserve it byte for
            // byte: newlines are valid path bytes on macOS and Linux.
            const selected_path = result.paths;
            scanFolder(&session.browser, self.io, self.allocator, selected_path) catch |err| {
                session.browser.setStatus("Could not open that folder: {s}", .{@errorName(err)});
                try self.ui_app.dispatch(runtime, window_id, .folder_loaded);
                return;
            };
            try self.ui_app.dispatch(runtime, window_id, .folder_loaded);
            return;
        }
    }

    fn performPendingRename(self: *CodeEditorApp, runtime: *native_sdk.Runtime) !void {
        for (&self.ui_app.model.sessions, 0..) |*session, index| {
            if (!session.open or session.browser.pending_rename_entry == null) continue;
            const serial = session.browser.rename_serial;
            if (serial == session.handled_rename_serial) continue;
            session.handled_rename_serial = serial;
            self.ui_app.model.active_session = @intCast(index);
            performPendingRenameOnDisk(&session.browser, self.io);
            const window_id = self.windowIdForSession(runtime, index) orelse return;
            try self.ui_app.dispatch(runtime, window_id, .rename_finished);
            return;
        }
    }

    fn performPendingDirectoryScan(self: *CodeEditorApp, runtime: *native_sdk.Runtime) !void {
        for (&self.ui_app.model.sessions, 0..) |*session, index| {
            if (!session.open or session.browser.pending_expand_entry == null) continue;
            const serial = session.browser.expand_serial;
            if (serial == session.handled_expand_serial) continue;
            session.handled_expand_serial = serial;
            self.ui_app.model.active_session = @intCast(index);
            const pending_index = session.browser.pending_expand_entry.?;
            loadDirectoryChildren(&session.browser, self.io, pending_index) catch |err| {
                session.browser.setStatus("Could not open that folder: {s}", .{@errorName(err)});
            };
            session.browser.pending_expand_entry = null;
            const window_id = self.windowIdForSession(runtime, index) orelse return;
            try self.ui_app.dispatch(runtime, window_id, .directory_loaded);
            return;
        }
    }

    fn routeEventToSession(
        self: *CodeEditorApp,
        runtime: *native_sdk.Runtime,
        event_value: native_sdk.Event,
    ) void {
        const window_id = eventWindowId(event_value) orelse return;
        self.ui_app.model.active_session = @intCast(self.sessionIndexForWindow(runtime, window_id) orelse return);
    }

    fn sessionIndexForWindow(
        self: *const CodeEditorApp,
        runtime: *const native_sdk.Runtime,
        window_id: native_sdk.platform.WindowId,
    ) ?usize {
        _ = self;
        var storage: [native_sdk.platform.max_windows]native_sdk.platform.WindowInfo = undefined;
        for (runtime.listWindows(&storage)) |info| {
            if (info.id != window_id) continue;
            if (std.mem.eql(u8, info.label, "main")) return 0;
            for (secondary_window_labels, 1..) |label, index| {
                if (std.mem.eql(u8, info.label, label)) return index;
            }
            return null;
        }
        return null;
    }

    fn focusPendingWindow(self: *CodeEditorApp, runtime: *native_sdk.Runtime) void {
        const index = self.ui_app.model.pending_focus_session orelse return;
        const window_id = self.windowIdForSession(runtime, index) orelse return;
        runtime.focusWindow(window_id) catch return;
        self.ui_app.model.pending_focus_session = null;
    }

    fn closePendingMainWindow(self: *CodeEditorApp, runtime: *native_sdk.Runtime) void {
        if (!self.ui_app.model.pending_close_main) return;
        const window_id = self.windowIdForSession(runtime, 0) orelse return;
        runtime.closeWindow(window_id) catch return;
        self.ui_app.model.pending_close_main = false;
    }

    fn windowIdForSession(
        self: *const CodeEditorApp,
        runtime: *const native_sdk.Runtime,
        index: usize,
    ) ?native_sdk.platform.WindowId {
        _ = self;
        const label = if (index == 0) "main" else secondary_window_labels[index - 1];
        var storage: [native_sdk.platform.max_windows]native_sdk.platform.WindowInfo = undefined;
        for (runtime.listWindows(&storage)) |info| {
            if (std.mem.eql(u8, info.label, label)) return info.id;
        }
        return null;
    }
};

fn eventWindowId(event_value: native_sdk.Event) ?native_sdk.platform.WindowId {
    return switch (event_value) {
        .command => |event| event.window_id,
        .shortcut => |event| event.window_id,
        .canvas_widget_pointer => |event| event.window_id,
        .canvas_widget_keyboard => |event| event.window_id,
        .canvas_widget_scroll => |event| event.window_id,
        .canvas_widget_file_drop => |event| event.window_id,
        .canvas_widget_drag => |event| event.window_id,
        .canvas_widget_context_menu => |event| event.window_id,
        .canvas_widget_context_menu_shown => |event| event.window_id,
        .canvas_widget_context_menu_dismissed => |event| event.window_id,
        .canvas_widget_context_menu_request => |event| event.window_id,
        .canvas_widget_dismiss => |event| event.window_id,
        .canvas_widget_context_press => |event| event.window_id,
        .canvas_widget_resize => |event| event.window_id,
        .canvas_widget_change => |event| event.window_id,
        .window_closed => |event| event.window_id,
        .automation_provenance => |event| event.window_id,
        else => null,
    };
}

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(CodeEditorApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = try CodeEditorApp.init(std.heap.page_allocator, init.io);
    defer app_state.deinit();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "code-editor",
        .window_title = "Native SDK Code Editor",
        .bundle_id = "dev.native_sdk.code_editor",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .shortcuts = &app_shortcuts,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
