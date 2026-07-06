//! notes model: folders, notes, search, the folder dialog, and the
//! persistence plumbing the views bind to.
//!
//! Everything the views show that is computable — filtered/sorted note
//! rows, first-line titles, snippet previews, relative timestamps, folder
//! counts — is derived per rebuild into the build arena, never stored.
//! The single stored truth is the folder table and the note table (each
//! note's body is a `canvas.TextBuffer`, so the editor edits notes in
//! place, elm-style, and the caret survives note switches).
//!
//! Persistence is the whole store as one file through the effects channel
//! (`fx.writeFile`/`fx.readFile` against the per-app data dir): edits
//! debounce through a one-shot fx timer; structural changes (create,
//! delete, folder ops) write immediately. Exactly one write is in flight
//! at a time — a save that lands while one is pending re-persists on
//! completion, so the newest state always reaches disk.
//!
//! Fixed capacities, documented where they bind:
//!   - `max_folders` folders x `max_folder_name_bytes` names
//!   - `max_notes` notes x `max_note_bytes` bodies (the note list mounts
//!     every visible row, so the cap also bounds the widget tree)
//!   - `max_search_bytes` search buffer
//!   - `max_store_bytes` serialized store (sized so a full store always
//!     fits; the effect channel itself binds reads/writes at 1 MiB)

const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;

pub const Effects = native_sdk.Effects(Msg);

// -------------------------------------------------------------- capacities

/// Folder capacity. Creating past it is refused loudly (disabled button,
/// status-bar note on the shortcut path).
pub const max_folders = 6;
pub const max_folder_name_bytes = 32;
/// Note capacity across all folders. Every visible row mounts real
/// widgets (~6 each), so this also keeps the tree well under the
/// 1024-node per-view layout budget.
pub const max_notes = 48;
/// Per-note body capacity. Only the active note's full text is retained
/// by the view (the textarea); list rows carry short derived snippets,
/// so the per-view 64 KiB widget-text budget stays far away.
pub const max_note_bytes = 4 * 1024;
pub const max_search_bytes = 48;
/// Derived-title/snippet cuts (bytes, backed off to UTF-8 boundaries):
/// the app-level ellipsis mechanism that keeps each derived string a
/// single line in the fixed-width list rail. Layout now measures with
/// the bundled face's real advances (and the packet host draws the
/// engine's lines verbatim), so these are plain content-length design
/// caps — no slack for divergent host metrics baked in.
pub const max_title_bytes = 28;
pub const max_snippet_bytes = 30;
pub const max_path_bytes = 512;
const max_status_bytes = 128;
/// The header band's natural height, and the floor `header_height`
/// falls back to when no titlebar band overlays the content
/// (fullscreen, standard chrome, tests). Matches the tall hidden-inset
/// band the system reports through `on_chrome` — the band must not be
/// taller than the OS band, or the header's controls center below the
/// traffic lights the system centers within its own band.
pub const header_natural_height: f32 = 52;

/// Serialized-store budget: every record header plus every body at cap.
/// Comfortably under the 1 MiB `max_effect_file_bytes` channel bound.
pub const max_store_bytes = max_notes * (max_note_bytes + 96) + max_folders * (max_folder_name_bytes + 32) + 32;

// Effect keys: caller-chosen identities, one per concurrent operation.
pub const store_read_key: u64 = 1;
pub const store_write_key: u64 = 2;
pub const copy_key: u64 = 3;
// Timer keys are their own namespace (never collide with file keys).
pub const save_timer_key: u64 = 1;
pub const refresh_timer_key: u64 = 2;

/// Edit-to-save debounce: the one-shot save timer restarts on every
/// keystroke, so the store writes a beat after typing pauses.
pub const save_debounce_ms: u32 = 800;
/// Relative timestamps ("2m", "3h") refresh on this repeating tick.
pub const refresh_interval_ms: u32 = 30_000;

/// The synthetic "All Notes" folder id; real folder ids start at 1.
pub const all_folder_id: u32 = 0;
/// The synthetic "Recently Deleted" scope id — a sidebar selection value,
/// never a stored folder id (`addFolder` ids count up from 1 and the
/// folder table caps at `max_folders`, so no real folder can reach it).
pub const deleted_scope_id: u32 = std.math.maxInt(u32);

// ------------------------------------------------------------------- store

/// v2 grew a per-note deleted timestamp (the Recently Deleted state).
/// `restoreStore` still reads v1 stores — their notes load as live.
pub const store_header = "native-sdk-notes v2";
pub const store_header_v1 = "native-sdk-notes v1";

pub const Folder = struct {
    id: u32 = 0,
    name_storage: [max_folder_name_bytes]u8 = undefined,
    name_len: usize = 0,

    pub fn name(folder: *const Folder) []const u8 {
        return folder.name_storage[0..folder.name_len];
    }

    fn setName(folder: *Folder, value: []const u8) void {
        const len = @min(value.len, max_folder_name_bytes);
        @memcpy(folder.name_storage[0..len], value[0..len]);
        folder.name_len = len;
    }
};

pub const Note = struct {
    id: u32 = 0,
    folder: u32 = 0,
    created_ms: i64 = 0,
    updated_ms: i64 = 0,
    /// Recently Deleted state: 0 = live, otherwise the wall time the
    /// note was deleted (drives the "Deleted 2h ago" meta line).
    deleted_ms: i64 = 0,
    body: canvas.TextBuffer(max_note_bytes) = .{},

    pub fn isDeleted(note: *const Note) bool {
        return note.deleted_ms != 0;
    }
};

pub const DialogMode = enum { closed, create_folder, rename_folder };

// -------------------------------------------------------------------- msgs

pub const Msg = union(enum) {
    edit: canvas.TextInputEvent,
    /// Search field edits — typing, and the field's built-in clear
    /// affordance (the trailing x / Escape), which arrives as `.clear`.
    search_edit: canvas.TextInputEvent,
    folder_field_edit: canvas.TextInputEvent,
    select_folder: u32,
    /// Sidebar position (0 = All Notes) — the cmd+digit shortcuts.
    select_folder_at: usize,
    /// Select the Recently Deleted scope (the sidebar row that exists
    /// only while deleted notes do).
    select_trash,
    open_note: u32,
    next_note,
    prev_note,
    new_note,
    /// The keyboard delete (Cmd+Backspace): moves the open note to
    /// Recently Deleted, or deletes it permanently when it is already
    /// there — the same double meaning the row context menu spells out.
    delete_note,
    copy_note,
    // Row context-menu items (each row declares its menu in markup; the
    // platform presents it on right/ctrl-click): items dispatch with the
    // row's id, so acting never requires selecting first, and the model
    // holds no open-menu state — presentation belongs to the platform.
    /// Move a note to Recently Deleted (the note row's Delete item).
    trash_note: u32,
    /// Bring a note back from Recently Deleted into its folder.
    restore_note: u32,
    /// Delete a Recently Deleted note permanently.
    purge_note: u32,
    /// Copy a note's body from its row menu (any row, not just the open
    /// note — `copy_note` stays the active-note keyboard path).
    copy_note_id: u32,
    open_create_folder,
    open_rename_folder,
    /// Rename/delete a specific folder (the folder row's menu items).
    rename_folder: u32,
    delete_folder: u32,
    confirm_dialog,
    close_dialog,
    /// Escape: close the dialog, then clear the search. (An open context
    /// menu consumes Escape before the app sees it — the OS menu closes
    /// itself, and the anchored fallback surface is runtime-dismissed.)
    dismiss,
    /// Splitter drags/keyboard: the runtime already applied the fraction;
    /// storing it and echoing it back through the split's `value` is the
    /// controlled pattern (rebuilds re-lay the panes exactly).
    sidebar_resized: f32,
    list_resized: f32,
    /// Note-list scrolls: the runtime already applied the offset; storing
    /// it and echoing it back through the scroll's `value` is the
    /// controlled pattern (rebuilds keep the list's place).
    note_list_scrolled: canvas.ScrollState,
    system_scheme: canvas.ColorScheme,
    /// Chrome overlay geometry (tall hidden-inset titlebar): the header
    /// pads its leading edge past the traffic lights and matches its
    /// height to the titlebar band. Delivered through `on_chrome`.
    chrome_changed: native_sdk.WindowChrome,
    refresh_tick: native_sdk.EffectTimer,
    save_tick: native_sdk.EffectTimer,
    store_done: native_sdk.EffectFileResult,
    clipboard_done: native_sdk.EffectClipboardResult,

    /// Zig-only dispatch — keyboard shortcuts (`on_command`), the
    /// chrome/appearance/effect channels — never bound in markup, so the
    /// dead-state lint must not ask for an on-* event.
    pub const view_unbound = .{
        "select_folder_at", "next_note",     "prev_note", "delete_note",
        "copy_note",        "open_rename_folder", "dismiss",
        "system_scheme",    "chrome_changed", "refresh_tick",
        "save_tick",        "store_done",    "clipboard_done",
    };
};

// ------------------------------------------------------------------- model

pub const Model = struct {
    folders: [max_folders]Folder = undefined,
    folder_count: usize = 0,
    notes: [max_notes]Note = undefined,
    note_count: usize = 0,
    next_folder_id: u32 = 1,
    next_note_id: u32 = 1,
    /// Sidebar selection: `all_folder_id`, a real folder id, or
    /// `deleted_scope_id` for Recently Deleted.
    selected_folder: u32 = all_folder_id,
    /// The note in the editor; 0 = none.
    active_note: u32 = 0,
    search_buffer: canvas.TextBuffer(max_search_bytes) = .{},
    /// The folder dialog (create/rename) and its name field (elm mirror).
    dialog: DialogMode = .closed,
    folder_field: canvas.TextBuffer(max_folder_name_bytes) = .{},
    /// The folder a rename dialog targets — stored at open so the row
    /// menu can rename a folder without selecting it first.
    dialog_folder: u32 = all_folder_id,
    /// Inline dialog validation hint; static strings, "" = none.
    dialog_hint: []const u8 = "",
    /// Where the store persists (resolved from the per-app data dir in
    /// `main`; empty in tests unless set — persistence then stays off).
    store_path_storage: [max_path_bytes]u8 = undefined,
    store_path_len: usize = 0,
    /// Exactly-one-write-in-flight bookkeeping.
    store_write_inflight: bool = false,
    save_pending: bool = false,
    /// Theme: the app follows the system appearance — the scheme flows
    /// in through `on_appearance` and the tokens re-derive from it.
    system_scheme: canvas.ColorScheme = .light,
    /// Time seam (`native_sdk.Clock`): relative timestamps and note
    /// mutation times read it, so tests substitute a `TestClock`.
    clock: native_sdk.Clock = .system,
    /// The view's time base for relative labels ("2m", "3h"): stamped in
    /// UPDATE — from the journaled clock read (`fx.wallMs`) on every
    /// refresh tick and edit — never read live in the view, so replaying
    /// the same Msg sequence renders the same labels.
    now_ms: i64 = 0,
    /// One-line activity note for the status bar ("Saved", "Copied…").
    status_storage: [max_status_bytes]u8 = undefined,
    status_len: usize = 0,
    /// Splitter fractions (model-owned; the runtime echoes drags back
    /// through `sidebar_resized`/`list_resized`). Defaults approximate
    /// the classic 216 / 304 / rest three-pane proportions.
    sidebar_split: f32 = 0.19,
    list_split: f32 = 0.33,
    /// Note-list scroll offset (model-owned; the runtime echoes scrolls
    /// back through `note_list_scrolled`).
    note_list_scroll: f32 = 0,
    /// Chrome overlay geometry from `on_chrome` (tall hidden-inset
    /// titlebar): the header row leads with a spacer this wide so its
    /// controls clear the traffic lights, and matches its height to the
    /// titlebar band so the lights share the header's centerline. Both
    /// fall back to the natural header when no band overlays the
    /// content (fullscreen, platforms with standard chrome, tests).
    chrome_leading: f32 = 0,
    header_height: f32 = header_natural_height,

    /// Update-only state: the view binds the derived query fns
    /// (`folderRows`, `noteRows`, `search`, `folderName`, ...) — never
    /// these backing stores or bookkeeping fields — so opting them out
    /// keeps `native check`'s dead-state lint quiet without weakening it
    /// for real drift.
    pub const view_unbound = .{
        "folders",        "folder_count",  "notes",           "note_count",
        "next_folder_id", "next_note_id",  "selected_folder",
        "search_buffer",  "dialog",        "folder_field",
        "dialog_folder",  "store_path_storage", "store_path_len",
        "store_write_inflight", "save_pending", "system_scheme",
        "clock",          "now_ms",        "status_storage",  "status_len",
        "liveNoteCount",  "deletedNoteCount", "searching",    "status",
        "storePath",
    };

    /// Keyboard reference rendered in the idle editor pane. Spelled-out
    /// key names on purpose: the bundled glyph set has no ⌘/⌥ coverage,
    /// and tofu is worse than prose.
    pub const shortcut_hints = [_]ShortcutHint{
        .{ .keys = "Cmd+N", .action = "New note in the selected folder" },
        .{ .keys = "Cmd+Shift+N", .action = "New folder" },
        .{ .keys = "Cmd+Shift+R", .action = "Rename the selected folder" },
        .{ .keys = "Cmd+Backspace", .action = "Delete the open note" },
        .{ .keys = "Cmd+Shift+C", .action = "Copy the open note" },
        .{ .keys = "Cmd+Opt+Up / Down", .action = "Previous / next note" },
        .{ .keys = "Cmd+1 … Cmd+7", .action = "Jump to a folder" },
        .{ .keys = "Esc", .action = "Close a menu or dialog, clear search" },
    };

    // ------------------------------------------------------------ lookups

    pub fn folderById(model: *const Model, id: u32) ?*const Folder {
        for (model.folders[0..model.folder_count]) |*folder| {
            if (folder.id == id) return folder;
        }
        return null;
    }

    fn folderByIdMut(model: *Model, id: u32) ?*Folder {
        for (model.folders[0..model.folder_count]) |*folder| {
            if (folder.id == id) return folder;
        }
        return null;
    }

    pub fn noteById(model: *const Model, id: u32) ?*const Note {
        for (model.notes[0..model.note_count]) |*note| {
            if (note.id == id) return note;
        }
        return null;
    }

    fn noteByIdMut(model: *Model, id: u32) ?*Note {
        for (model.notes[0..model.note_count]) |*note| {
            if (note.id == id) return note;
        }
        return null;
    }

    fn noteIndexById(model: *const Model, id: u32) ?usize {
        for (model.notes[0..model.note_count], 0..) |*note, index| {
            if (note.id == id) return index;
        }
        return null;
    }

    /// Live notes filed under a folder (Recently Deleted notes keep
    /// their folder id for restore, but never count toward it).
    fn notesInFolder(model: *const Model, folder_id: u32) usize {
        var count: usize = 0;
        for (model.notes[0..model.note_count]) |*note| {
            if (!note.isDeleted() and note.folder == folder_id) count += 1;
        }
        return count;
    }

    pub fn liveNoteCount(model: *const Model) usize {
        var count: usize = 0;
        for (model.notes[0..model.note_count]) |*note| {
            if (!note.isDeleted()) count += 1;
        }
        return count;
    }

    pub fn deletedNoteCount(model: *const Model) usize {
        return model.note_count - model.liveNoteCount();
    }

    /// Note indexes visible in the list — scope-filtered (a folder, All
    /// Notes, or Recently Deleted; deleted notes appear only in the
    /// latter), search-filtered, newest first (ties broken by id, newest
    /// first, for determinism).
    pub fn visibleNoteIndexes(model: *const Model, out: *[max_notes]usize) usize {
        var count: usize = 0;
        const query = model.search();
        const trash = model.selected_folder == deleted_scope_id;
        for (model.notes[0..model.note_count], 0..) |*note, index| {
            if (note.isDeleted() != trash) continue;
            if (!trash and model.selected_folder != all_folder_id and note.folder != model.selected_folder) continue;
            if (query.len > 0 and !containsIgnoreCase(note.body.text(), query)) continue;
            out[count] = index;
            count += 1;
        }
        std.mem.sort(usize, out[0..count], model, noteNewerFirst);
        return count;
    }

    fn noteNewerFirst(model: *const Model, left: usize, right: usize) bool {
        const a = &model.notes[left];
        const b = &model.notes[right];
        if (a.updated_ms != b.updated_ms) return a.updated_ms > b.updated_ms;
        return a.id > b.id;
    }

    // ------------------------------------------------------ view bindings

    pub fn search(model: *const Model) []const u8 {
        return model.search_buffer.text();
    }

    pub fn searching(model: *const Model) bool {
        return model.search().len > 0;
    }

    pub fn foldersFull(model: *const Model) bool {
        return model.folder_count >= max_folders;
    }

    /// Whether the Recently Deleted row renders at all — the section
    /// exists only while deleted notes do (presence, not a dead row).
    pub fn trashAvailable(model: *const Model) bool {
        return model.deletedNoteCount() > 0;
    }

    pub fn trashSelected(model: *const Model) bool {
        return model.selected_folder == deleted_scope_id;
    }

    pub fn trashCount(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}", .{model.deletedNoteCount()}) catch "";
    }

    pub fn folderRows(model: *const Model, arena: std.mem.Allocator) []const FolderRow {
        const out = arena.alloc(FolderRow, model.folder_count + 1) catch return &.{};
        out[0] = .{
            .id = all_folder_id,
            .name = "All Notes",
            .label = "All Notes folder",
            .count = std.fmt.allocPrint(arena, "{d}", .{model.liveNoteCount()}) catch "",
            .selected = model.selected_folder == all_folder_id,
            // The synthetic row cannot be renamed or deleted: its
            // declared context-menu item set is empty, so no menu
            // presents (and the rename/delete handlers refuse its id).
            .mutable = false,
        };
        for (model.folders[0..model.folder_count], out[1..]) |*folder, *row| {
            row.* = .{
                .id = folder.id,
                .name = folder.name(),
                .label = std.fmt.allocPrint(arena, "{s} folder", .{folder.name()}) catch folder.name(),
                .count = std.fmt.allocPrint(arena, "{d}", .{model.notesInFolder(folder.id)}) catch "",
                .selected = model.selected_folder == folder.id,
                .mutable = true,
            };
        }
        return out;
    }

    pub fn listTitle(model: *const Model) []const u8 {
        if (model.trashSelected()) return "Recently Deleted";
        if (model.folderById(model.selected_folder)) |folder| return folder.name();
        return "All Notes";
    }

    pub fn noteCount(model: *const Model, arena: std.mem.Allocator) []const u8 {
        var indexes: [max_notes]usize = undefined;
        return std.fmt.allocPrint(arena, "{d}", .{model.visibleNoteIndexes(&indexes)}) catch "";
    }

    pub fn noteRows(model: *const Model, arena: std.mem.Allocator) []const NoteRow {
        var indexes: [max_notes]usize = undefined;
        const count = model.visibleNoteIndexes(&indexes);
        const out = arena.alloc(NoteRow, count) catch return &.{};
        const now = model.now_ms;
        for (out, indexes[0..count]) |*row, index| {
            const note = &model.notes[index];
            row.* = .{
                .id = note.id,
                .title = displayTitle(arena, note.body.text()),
                .snippet = displaySnippet(arena, note.body.text()),
                .time = relativeTimeLabel(arena, now, note.updated_ms),
                .active = note.id == model.active_note,
                .deleted = note.isDeleted(),
            };
        }
        return out;
    }

    pub fn emptyTitle(model: *const Model) []const u8 {
        return if (model.searching()) "No matches" else "No notes here yet";
    }

    pub fn emptyHint(model: *const Model) []const u8 {
        return if (model.searching())
            "Search covers every folder's full text."
        else
            "Press Cmd+N or the New note button to start one.";
    }

    pub fn hasActiveNote(model: *const Model) bool {
        return model.activeNote() != null;
    }

    pub fn activeNote(model: *const Model) ?*const Note {
        if (model.active_note == 0) return null;
        return model.noteById(model.active_note);
    }

    /// The editable editor renders for a live note; a Recently Deleted
    /// note renders read-only with the restore affordance instead (the
    /// markup nests this under `hasActiveNote`, so its else IS the
    /// deleted branch).
    pub fn activeNoteLive(model: *const Model) bool {
        const note = model.activeNote() orelse return false;
        return !note.isDeleted();
    }

    pub fn editorText(model: *const Model) []const u8 {
        const note = model.activeNote() orelse return "";
        return note.body.text();
    }

    pub fn editorMeta(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const note = model.activeNote() orelse return "";
        const text = note.body.text();
        if (note.isDeleted()) {
            const age = relativeTimeLabel(arena, model.now_ms, note.deleted_ms);
            const deleted = if (std.mem.eql(u8, age, "now"))
                "Deleted just now"
            else
                std.fmt.allocPrint(arena, "Deleted {s} ago", .{age}) catch "";
            return std.fmt.allocPrint(arena, "{s} · {d} words", .{ deleted, countWords(text) }) catch "";
        }
        const age = relativeTimeLabel(arena, model.now_ms, note.updated_ms);
        const edited = if (std.mem.eql(u8, age, "now"))
            "Edited just now"
        else
            std.fmt.allocPrint(arena, "Edited {s} ago", .{age}) catch "";
        return std.fmt.allocPrint(arena, "{s} · {d} words", .{ edited, countWords(text) }) catch "";
    }

    pub fn dialogOpen(model: *const Model) bool {
        return model.dialog != .closed;
    }

    pub fn dialogTitle(model: *const Model) []const u8 {
        return switch (model.dialog) {
            .rename_folder => "Rename Folder",
            else => "New Folder",
        };
    }

    pub fn dialogConfirmLabel(model: *const Model) []const u8 {
        return switch (model.dialog) {
            .rename_folder => "Rename",
            else => "Create",
        };
    }

    pub fn folderName(model: *const Model) []const u8 {
        return model.folder_field.text();
    }

    pub fn dialogNameEmpty(model: *const Model) bool {
        return model.folder_field.isEmpty();
    }

    pub fn statusLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        var indexes: [max_notes]usize = undefined;
        const shown = model.visibleNoteIndexes(&indexes);
        const live = model.liveNoteCount();
        const activity = model.status();
        if (activity.len == 0) {
            return std.fmt.allocPrint(arena, "{d} notes · {d} shown", .{ live, shown }) catch "";
        }
        return std.fmt.allocPrint(arena, "{d} notes · {d} shown · {s}", .{
            live, shown, activity,
        }) catch "";
    }

    // ----------------------------------------------------------- mutation

    pub fn status(model: *const Model) []const u8 {
        return model.status_storage[0..model.status_len];
    }

    pub fn setStatus(model: *Model, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&model.status_storage, fmt, args) catch {
            model.status_len = 0;
            return;
        };
        model.status_len = written.len;
    }

    pub fn setStorePath(model: *Model, value: []const u8) void {
        const len = @min(value.len, max_path_bytes);
        @memcpy(model.store_path_storage[0..len], value[0..len]);
        model.store_path_len = len;
    }

    pub fn storePath(model: *const Model) []const u8 {
        return model.store_path_storage[0..model.store_path_len];
    }

    pub fn addFolder(model: *Model, folder_name: []const u8) ?u32 {
        if (model.folder_count >= max_folders) return null;
        if (folder_name.len == 0) return null;
        const folder = &model.folders[model.folder_count];
        folder.* = .{ .id = model.next_folder_id };
        folder.setName(folder_name);
        model.folder_count += 1;
        model.next_folder_id += 1;
        return folder.id;
    }

    pub fn addNote(model: *Model, folder_id: u32, updated_ms: i64, body: []const u8) ?u32 {
        if (model.note_count >= max_notes) return null;
        const note = &model.notes[model.note_count];
        note.* = .{
            .id = model.next_note_id,
            .folder = folder_id,
            .created_ms = updated_ms,
            .updated_ms = updated_ms,
        };
        note.body.set(body);
        model.note_count += 1;
        model.next_note_id += 1;
        return note.id;
    }

    fn removeNoteAt(model: *Model, index: usize) void {
        var cursor = index;
        while (cursor + 1 < model.note_count) : (cursor += 1) {
            model.notes[cursor] = model.notes[cursor + 1];
        }
        model.note_count -= 1;
    }

    /// When Recently Deleted empties, the row it was selected through is
    /// gone — the selection falls back to All Notes.
    fn leaveEmptyTrash(model: *Model) void {
        if (model.trashSelected() and !model.trashAvailable()) {
            model.selected_folder = all_folder_id;
        }
    }

    /// Point the editor at the newest visible note (0 when none).
    pub fn selectTopNote(model: *Model) void {
        var indexes: [max_notes]usize = undefined;
        const count = model.visibleNoteIndexes(&indexes);
        model.active_note = if (count == 0) 0 else model.notes[indexes[0]].id;
    }

    fn folderNameTaken(model: *const Model, candidate: []const u8, ignore_id: u32) bool {
        for (model.folders[0..model.folder_count]) |*folder| {
            if (folder.id == ignore_id) continue;
            if (std.ascii.eqlIgnoreCase(folder.name(), candidate)) return true;
        }
        return false;
    }

    // -------------------------------------------------------- persistence

    /// Serialize the whole store (folders then notes, byte-counted
    /// bodies) into `buffer`; bounded by construction (`max_store_bytes`).
    pub fn serializeStore(model: *const Model, buffer: []u8) []const u8 {
        var len: usize = 0;
        appendFmt(buffer, &len, "{s}\n", .{store_header});
        for (model.folders[0..model.folder_count]) |*folder| {
            appendFmt(buffer, &len, "folder {d} {s}\n", .{ folder.id, folder.name() });
        }
        for (model.notes[0..model.note_count]) |*note| {
            const body = note.body.text();
            appendFmt(buffer, &len, "note {d} {d} {d} {d} {d} {d}\n", .{
                note.id, note.folder, note.created_ms, note.updated_ms, note.deleted_ms, body.len,
            });
            if (len + body.len + 1 > buffer.len) break;
            @memcpy(buffer[len .. len + body.len], body);
            len += body.len;
            buffer[len] = '\n';
            len += 1;
        }
        return buffer[0..len];
    }

    /// Parse a persisted store. Defensive by construction: any malformed
    /// record stops the parse and keeps what was read; a store with no
    /// folders reports false so the caller can keep its seeds. Both
    /// header versions load: v1 note records carry no deleted field, so
    /// every v1 note comes back live — the honest migration.
    pub fn restoreStore(model: *Model, bytes: []const u8) bool {
        var parsed = Model{ .clock = model.clock };
        var cursor: usize = 0;
        const header = takeLine(bytes, &cursor) orelse return false;
        const v1 = std.mem.eql(u8, header, store_header_v1);
        if (!v1 and !std.mem.eql(u8, header, store_header)) return false;

        while (takeLine(bytes, &cursor)) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "folder ")) {
                if (parsed.folder_count >= max_folders) break;
                var fields = std.mem.splitScalar(u8, line["folder ".len..], ' ');
                const id = std.fmt.parseInt(u32, fields.next() orelse break, 10) catch break;
                const folder_name = std.mem.trim(u8, fields.rest(), " ");
                if (id == all_folder_id or folder_name.len == 0 or folder_name.len > max_folder_name_bytes) break;
                const folder = &parsed.folders[parsed.folder_count];
                folder.* = .{ .id = id };
                folder.setName(folder_name);
                parsed.folder_count += 1;
                parsed.next_folder_id = @max(parsed.next_folder_id, id + 1);
                continue;
            }
            if (std.mem.startsWith(u8, line, "note ")) {
                if (parsed.note_count >= max_notes) break;
                var fields = std.mem.splitScalar(u8, line["note ".len..], ' ');
                const id = std.fmt.parseInt(u32, fields.next() orelse break, 10) catch break;
                const folder_id = std.fmt.parseInt(u32, fields.next() orelse break, 10) catch break;
                const created = std.fmt.parseInt(i64, fields.next() orelse break, 10) catch break;
                const updated = std.fmt.parseInt(i64, fields.next() orelse break, 10) catch break;
                // v1 records: id folder created updated len. v2 adds the
                // deleted timestamp before len.
                const deleted = if (v1) 0 else std.fmt.parseInt(i64, fields.next() orelse break, 10) catch break;
                const body_len = std.fmt.parseInt(usize, fields.next() orelse break, 10) catch break;
                if (id == 0 or body_len > max_note_bytes or cursor + body_len > bytes.len) break;
                const note = &parsed.notes[parsed.note_count];
                note.* = .{ .id = id, .folder = folder_id, .created_ms = created, .updated_ms = updated, .deleted_ms = deleted };
                note.body.set(bytes[cursor .. cursor + body_len]);
                cursor += body_len;
                if (cursor < bytes.len and bytes[cursor] == '\n') cursor += 1;
                parsed.note_count += 1;
                parsed.next_note_id = @max(parsed.next_note_id, id + 1);
                continue;
            }
            break;
        }

        if (parsed.folder_count == 0) return false;
        // Orphaned notes (their folder line was lost) file under the
        // first folder rather than vanishing.
        for (parsed.notes[0..parsed.note_count]) |*note| {
            if (parsed.folderById(note.folder) == null) note.folder = parsed.folders[0].id;
        }

        model.folders = parsed.folders;
        model.folder_count = parsed.folder_count;
        model.notes = parsed.notes;
        model.note_count = parsed.note_count;
        model.next_folder_id = parsed.next_folder_id;
        model.next_note_id = parsed.next_note_id;
        if (model.selected_folder != all_folder_id and model.folderById(model.selected_folder) == null) {
            model.selected_folder = all_folder_id;
        }
        if (model.active_note != 0 and model.noteById(model.active_note) == null) model.active_note = 0;
        if (model.active_note == 0) model.selectTopNote();
        return true;
    }
};

pub const ShortcutHint = struct {
    keys: []const u8,
    action: []const u8,
};

pub const FolderRow = struct {
    id: u32,
    name: []const u8,
    /// Accessible name ("Inbox folder") — disambiguates folder rows from
    /// note rows in the widget tree and automation snapshots.
    label: []const u8,
    count: []const u8,
    selected: bool,
    /// Whether the row's context menu offers Rename/Delete: false only
    /// for the synthetic All Notes row, whose item set is empty — an
    /// empty declared menu presents nothing.
    mutable: bool,
};

pub const NoteRow = struct {
    id: u32,
    title: []const u8,
    snippet: []const u8,
    time: []const u8,
    active: bool,
    /// Recently Deleted rows' context menu offers Restore / Delete
    /// Permanently instead of Copy / Delete.
    deleted: bool,
};

// ------------------------------------------------------------ derivations

/// The note's first non-empty line, trimmed and cut to `max_title_bytes`
/// (UTF-8 safe, with an ellipsis when cut); "Untitled" for empty bodies.
pub fn displayTitle(arena: std.mem.Allocator, body: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        return cutWithEllipsis(arena, trimmed, max_title_bytes);
    }
    return "Untitled";
}

/// Everything after the title line, whitespace runs collapsed to single
/// spaces, cut to `max_snippet_bytes`; an em dash when there is nothing.
pub fn displaySnippet(arena: std.mem.Allocator, body: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    var title_seen = false;
    var rest_start: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!title_seen) {
            if (trimmed.len == 0) continue;
            title_seen = true;
            rest_start = @min(body.len, (lines.index orelse body.len));
            break;
        }
    }
    if (!title_seen) return "—";

    const rest = body[rest_start..];
    const collapsed = arena.alloc(u8, @min(rest.len, max_snippet_bytes + 1)) catch return "—";
    var len: usize = 0;
    var in_space = true; // swallow leading whitespace
    for (rest) |byte| {
        const is_space = byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
        if (is_space) {
            if (!in_space and len < collapsed.len) {
                collapsed[len] = ' ';
                len += 1;
            }
            in_space = true;
            continue;
        }
        if (len >= collapsed.len) break;
        collapsed[len] = byte;
        len += 1;
        in_space = false;
    }
    const trimmed = std.mem.trimEnd(u8, collapsed[0..len], " ");
    if (trimmed.len == 0) return "—";
    return cutWithEllipsis(arena, trimmed, max_snippet_bytes);
}

/// Compact relative age: "now", then minutes/hours/days/weeks/years.
pub fn relativeTimeLabel(arena: std.mem.Allocator, now_ms: i64, then_ms: i64) []const u8 {
    const delta = now_ms - then_ms;
    if (delta < 60 * 1000) return "now";
    const minutes = @divTrunc(delta, 60 * 1000);
    if (minutes < 60) return std.fmt.allocPrint(arena, "{d}m", .{minutes}) catch "";
    const hours = @divTrunc(minutes, 60);
    if (hours < 24) return std.fmt.allocPrint(arena, "{d}h", .{hours}) catch "";
    const days = @divTrunc(hours, 24);
    if (days < 7) return std.fmt.allocPrint(arena, "{d}d", .{days}) catch "";
    const weeks = @divTrunc(days, 7);
    if (weeks < 52) return std.fmt.allocPrint(arena, "{d}w", .{weeks}) catch "";
    return std.fmt.allocPrint(arena, "{d}y", .{@divTrunc(days, 365)}) catch "";
}

/// Cut `text` to at most `limit` bytes at a UTF-8 boundary, appending an
/// ellipsis when anything was dropped.
pub fn cutWithEllipsis(arena: std.mem.Allocator, text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}…", .{std.mem.trimEnd(u8, text[0..end], " ")}) catch text[0..end];
}

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

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn appendFmt(buffer: []u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(buffer[len.*..], fmt, args) catch return;
    len.* += written.len;
}

fn takeLine(bytes: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= bytes.len) return null;
    const start = cursor.*;
    const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
    cursor.* = @min(bytes.len, end + 1);
    return bytes[start..end];
}

// ------------------------------------------------------------------ update

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .edit => |edit| {
            const note = model.noteByIdMut(model.active_note) orelse return;
            // Recently Deleted notes are read-only: the view renders
            // plain text there, and the model refuses stray edits too.
            if (note.isDeleted()) return;
            note.body.apply(edit);
            note.updated_ms = fx.wallMs();
            model.now_ms = note.updated_ms;
            model.status_len = 0;
            if (note.body.truncated) model.setStatus("Note is full ({d} KiB cap)", .{max_note_bytes / 1024});
            scheduleSave(fx);
        },
        .search_edit => |edit| model.search_buffer.apply(edit),
        .folder_field_edit => |edit| {
            model.folder_field.apply(edit);
            model.dialog_hint = "";
        },
        .select_folder => |id| selectFolder(model, id),
        // Echo the applied splitter fractions back through the model:
        // the next rebuild lays panes at exactly these values, so drags
        // never fight the reconcile.
        .sidebar_resized => |fraction| model.sidebar_split = fraction,
        .list_resized => |fraction| model.list_split = fraction,
        // Same controlled pattern for the note-list scroll: store the
        // applied offset, echo it back through the scroll's value.
        .note_list_scrolled => |state| model.note_list_scroll = state.offset,
        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
            // Match the header to the titlebar band so its centered
            // controls share the traffic lights' centerline; the natural
            // height is the floor when no band overlays the content.
            model.header_height = @max(header_natural_height, chrome.insets.top);
        },
        .select_folder_at => |position| {
            if (position == 0) return selectFolder(model, all_folder_id);
            if (position <= model.folder_count) selectFolder(model, model.folders[position - 1].id);
        },
        .select_trash => {
            model.selected_folder = deleted_scope_id;
            model.note_list_scroll = 0;
            model.selectTopNote();
        },
        .open_note => |id| {
            if (model.noteById(id) != null) model.active_note = id;
        },
        .next_note => moveSelection(model, 1),
        .prev_note => moveSelection(model, -1),
        .new_note => {
            // From All Notes or Recently Deleted the note files under the
            // first folder; from Recently Deleted the selection moves
            // there too, so the new note appears where the cursor lands.
            const folder_id = if (model.selected_folder == all_folder_id or model.trashSelected())
                (if (model.folder_count > 0) model.folders[0].id else return)
            else
                model.selected_folder;
            model.now_ms = fx.wallMs();
            const id = model.addNote(folder_id, model.now_ms, "") orelse {
                model.setStatus("Note limit reached ({d})", .{max_notes});
                return;
            };
            if (model.trashSelected()) model.selected_folder = folder_id;
            // An empty note can never match a query; clear the filter so
            // the new note is visible where the cursor expects it.
            model.search_buffer.apply(.clear);
            model.active_note = id;
            model.setStatus("New note in {s}", .{model.folderById(folder_id).?.name()});
            persistStore(model, fx);
        },
        .delete_note => {
            // The one keyboard delete, scope-aware like the row menus: a
            // live note moves to Recently Deleted; a note already there
            // is deleted permanently.
            const note = model.noteById(model.active_note) orelse return;
            if (note.isDeleted()) purgeNote(model, fx, note.id) else trashNote(model, fx, note.id);
        },
        .trash_note => |id| trashNote(model, fx, id),
        .restore_note => |id| restoreNote(model, fx, id),
        .purge_note => |id| purgeNote(model, fx, id),
        .copy_note => {
            const note = model.activeNote() orelse return;
            copyNoteBody(model, fx, note);
        },
        .copy_note_id => |id| {
            const note = model.noteById(id) orelse return;
            copyNoteBody(model, fx, note);
        },
        .open_create_folder => {
            if (model.foldersFull()) {
                model.setStatus("Folder limit reached ({d})", .{max_folders});
                return;
            }
            model.dialog = .create_folder;
            model.folder_field.clear();
            model.dialog_hint = "";
        },
        .open_rename_folder => openRenameDialog(model, model.selected_folder, "Select a folder to rename"),
        .rename_folder => |id| openRenameDialog(model, id, "That folder is gone"),
        .delete_folder => |id| deleteFolder(model, fx, id),
        .confirm_dialog => confirmDialog(model, fx),
        .close_dialog => model.dialog = .closed,
        .dismiss => {
            if (model.dialog != .closed) {
                model.dialog = .closed;
            } else if (model.searching()) {
                model.search_buffer.apply(.clear);
            }
        },
        .system_scheme => |scheme| model.system_scheme = scheme,
        // Advance the view's time base through the JOURNALED clock read
        // and let the rebuild that follows every dispatch re-derive the
        // relative labels — a live clock read in the view would render
        // differently on replay of the same Msg sequence.
        .refresh_tick => model.now_ms = fx.wallMs(),
        .save_tick => persistStore(model, fx),
        .store_done => |result| switch (result.op) {
            .read => switch (result.outcome) {
                .ok => {
                    if (model.restoreStore(result.bytes)) {
                        model.setStatus("Loaded {d} notes", .{model.note_count});
                    } else {
                        model.setStatus("Store unreadable — using the built-in samples", .{});
                    }
                },
                // First run: no store yet, the seeds stand. Quiet.
                .not_found => {},
                else => model.setStatus("Load failed: {s}", .{@tagName(result.outcome)}),
            },
            .write => {
                model.store_write_inflight = false;
                switch (result.outcome) {
                    .ok => {
                        if (model.save_pending) {
                            model.save_pending = false;
                            persistStore(model, fx);
                        } else {
                            model.setStatus("Saved", .{});
                        }
                    },
                    else => model.setStatus("Save failed: {s}", .{@tagName(result.outcome)}),
                }
            },
        },
        .clipboard_done => |result| {
            if (result.op != .write) return;
            switch (result.outcome) {
                .ok => model.setStatus("Copied to clipboard", .{}),
                else => model.setStatus("Copy failed: {s}", .{@tagName(result.outcome)}),
            }
        },
    }
}

fn selectFolder(model: *Model, id: u32) void {
    if (id != all_folder_id and model.folderById(id) == null) return;
    model.selected_folder = id;
    // Jumping to a folder shows its top — the controlled scroll would
    // otherwise echo the previous folder's offset into the new list.
    model.note_list_scroll = 0;
    model.selectTopNote();
}

/// Move a live note to Recently Deleted: it leaves every folder scope,
/// keeps its folder id for restore, and the trash row appears in the
/// sidebar the moment the first note lands there.
fn trashNote(model: *Model, fx: *Effects, id: u32) void {
    const note = model.noteByIdMut(id) orelse return;
    if (note.isDeleted()) return;
    model.now_ms = fx.wallMs();
    note.deleted_ms = model.now_ms;
    var title_buffer: [max_title_bytes + 8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&title_buffer);
    model.setStatus("Moved \"{s}\" to Recently Deleted", .{displayTitle(fixed.allocator(), note.body.text())});
    if (model.active_note == id) model.selectTopNote();
    persistStore(model, fx);
}

/// Bring a note back from Recently Deleted. Its folder may have been
/// deleted since; then it files under the first folder, like the store
/// restore's orphan rule.
fn restoreNote(model: *Model, fx: *Effects, id: u32) void {
    const note = model.noteByIdMut(id) orelse return;
    if (!note.isDeleted()) return;
    note.deleted_ms = 0;
    if (model.folderById(note.folder) == null and model.folder_count > 0) {
        note.folder = model.folders[0].id;
    }
    model.now_ms = fx.wallMs();
    var title_buffer: [max_title_bytes + 8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&title_buffer);
    model.setStatus("Restored \"{s}\"", .{displayTitle(fixed.allocator(), note.body.text())});
    model.leaveEmptyTrash();
    // Restoring the open note keeps it open when the scope now shows it
    // (the empty-trash fallback to All Notes does); a restore from a
    // still-populated trash list re-targets the editor at the list.
    if (model.active_note == id and model.trashSelected()) model.selectTopNote();
    persistStore(model, fx);
}

/// Delete a Recently Deleted note permanently — the only path that
/// actually removes a note record.
fn purgeNote(model: *Model, fx: *Effects, id: u32) void {
    const index = model.noteIndexById(id) orelse return;
    if (!model.notes[index].isDeleted()) return;
    var title_buffer: [max_title_bytes + 8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&title_buffer);
    model.setStatus("Deleted \"{s}\" permanently", .{displayTitle(fixed.allocator(), model.notes[index].body.text())});
    model.removeNoteAt(index);
    model.leaveEmptyTrash();
    if (model.active_note == id) model.selectTopNote();
    persistStore(model, fx);
}

fn copyNoteBody(model: *Model, fx: *Effects, note: *const Note) void {
    fx.writeClipboard(.{
        .key = copy_key,
        .text = note.body.text(),
        .on_result = Effects.clipboardMsg(.clipboard_done),
    });
    model.setStatus("Copying…", .{});
}

/// Open the rename dialog for a folder (the keyboard path targets the
/// selection, the row menu targets its own folder).
fn openRenameDialog(model: *Model, id: u32, missing_status: []const u8) void {
    const folder = model.folderById(id) orelse {
        model.setStatus("{s}", .{missing_status});
        return;
    };
    model.dialog = .rename_folder;
    model.dialog_folder = id;
    model.folder_field.set(folder.name());
    model.dialog_hint = "";
}

/// Delete a folder: its live notes move to Recently Deleted (so nothing
/// is lost silently) and the folder record goes. The last folder stays —
/// a new note always needs a home.
fn deleteFolder(model: *Model, fx: *Effects, id: u32) void {
    const folder = model.folderById(id) orelse return;
    if (model.folder_count <= 1) {
        model.setStatus("Keep at least one folder", .{});
        return;
    }
    var name_buffer: [max_folder_name_bytes]u8 = undefined;
    const name_len = folder.name_len;
    @memcpy(name_buffer[0..name_len], folder.name());
    const folder_name = name_buffer[0..name_len];

    model.now_ms = fx.wallMs();
    var moved: usize = 0;
    for (model.notes[0..model.note_count]) |*note| {
        if (note.folder != id or note.isDeleted()) continue;
        note.deleted_ms = model.now_ms;
        moved += 1;
    }
    var index: usize = 0;
    while (index < model.folder_count) : (index += 1) {
        if (model.folders[index].id != id) continue;
        var cursor = index;
        while (cursor + 1 < model.folder_count) : (cursor += 1) {
            model.folders[cursor] = model.folders[cursor + 1];
        }
        model.folder_count -= 1;
        break;
    }
    if (moved == 0) {
        model.setStatus("Deleted folder \"{s}\"", .{folder_name});
    } else {
        model.setStatus("Deleted folder \"{s}\" · {d} note{s} to Recently Deleted", .{
            folder_name, moved, if (moved == 1) "" else "s",
        });
    }
    if (model.selected_folder == id) model.selected_folder = all_folder_id;
    // The active note may have just been trashed with its folder.
    if (model.activeNote()) |active| {
        if (active.isDeleted() and !model.trashSelected()) model.selectTopNote();
    } else {
        model.selectTopNote();
    }
    persistStore(model, fx);
}

/// Move the editor selection through the visible ordering; from nothing,
/// both directions land on the newest visible note.
fn moveSelection(model: *Model, offset: i32) void {
    var indexes: [max_notes]usize = undefined;
    const count = model.visibleNoteIndexes(&indexes);
    if (count == 0) return;
    var position: i64 = 0;
    for (indexes[0..count], 0..) |index, row| {
        if (model.notes[index].id == model.active_note) {
            position = @as(i64, @intCast(row)) + offset;
            break;
        }
    }
    const clamped: usize = @intCast(std.math.clamp(position, 0, @as(i64, @intCast(count - 1))));
    model.active_note = model.notes[indexes[clamped]].id;
}

fn confirmDialog(model: *Model, fx: *Effects) void {
    if (model.dialog == .closed) return;
    // Single-line fields cannot type newlines, but paste can carry them;
    // collapse to spaces before validating.
    var sanitized: [max_folder_name_bytes]u8 = undefined;
    const raw = model.folder_field.text();
    for (raw, 0..) |byte, index| {
        sanitized[index] = if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte;
    }
    const candidate = std.mem.trim(u8, sanitized[0..raw.len], " ");
    if (candidate.len == 0) {
        model.dialog_hint = "A folder needs a name.";
        return;
    }
    switch (model.dialog) {
        .create_folder => {
            if (model.folderNameTaken(candidate, all_folder_id)) {
                model.dialog_hint = "That name is already taken.";
                return;
            }
            const id = model.addFolder(candidate) orelse {
                model.setStatus("Folder limit reached ({d})", .{max_folders});
                model.dialog = .closed;
                return;
            };
            model.selected_folder = id;
            model.selectTopNote();
            model.setStatus("Created folder {s}", .{model.folderById(id).?.name()});
        },
        .rename_folder => {
            const folder = model.folderByIdMut(model.dialog_folder) orelse {
                model.dialog = .closed;
                return;
            };
            if (model.folderNameTaken(candidate, folder.id)) {
                model.dialog_hint = "That name is already taken.";
                return;
            }
            folder.setName(candidate);
            model.setStatus("Renamed folder to {s}", .{folder.name()});
        },
        .closed => unreachable,
    }
    model.dialog = .closed;
    persistStore(model, fx);
}

// -------------------------------------------------------------- effects

/// Debounced autosave: every edit re-arms the one-shot timer (starting an
/// active key replaces it in place), so the write happens a beat after
/// typing pauses. A rejected timer (host without a timer service) falls
/// through to an immediate write in `update` — autosave degrades to
/// save-on-every-edit, never to silence.
fn scheduleSave(fx: *Effects) void {
    fx.startTimer(.{
        .key = save_timer_key,
        .interval_ms = save_debounce_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.save_tick),
    });
}

/// Write the whole store now. Exactly one write is in flight at a time:
/// a save requested while one runs sets `save_pending`, and the write
/// acknowledgement re-persists — the newest state always reaches disk.
pub fn persistStore(model: *Model, fx: *Effects) void {
    if (model.store_path_len == 0) return;
    if (model.store_write_inflight) {
        model.save_pending = true;
        return;
    }
    var buffer: [max_store_bytes]u8 = undefined;
    fx.writeFile(.{
        .key = store_write_key,
        .path = model.storePath(),
        .bytes = model.serializeStore(&buffer),
        .on_result = Effects.fileMsg(.store_done),
    });
    model.store_write_inflight = true;
}

// -------------------------------------------------------------- seeding

/// The first-run content: three folders and a handful of notes with
/// staggered ages, so the list, snippets, and relative times all have
/// something honest to show. Ages are relative to the model's clock —
/// deterministic under a `TestClock`. Prose bodies are natural
/// one-line paragraphs: the editor soft-wraps them with the same
/// metrics the renderer inks, so the hard-wrapped-seed workaround
/// (needed when the estimator diverged from real glyph metrics) is
/// gone.
pub fn seed(model: *Model) void {
    seedAt(model, model.clock.wallMs());
}

/// `seed` against an explicit "now": the deterministic-init seam. `boot`
/// re-stamps the seeds from the journaled clock read (`fx.wallMs`)
/// before the first view build, so a recorded session's very first
/// frame replays reproducibly even though `main` seeded with the live
/// clock before the runtime existed.
pub fn seedAt(model: *Model, now: i64) void {
    model.folder_count = 0;
    model.note_count = 0;
    model.next_folder_id = 1;
    model.next_note_id = 1;
    model.now_ms = now;

    const inbox = model.addFolder("Inbox").?;
    const ideas = model.addFolder("Ideas").?;
    const reading = model.addFolder("Reading").?;

    _ = model.addNote(reading, now - 8 * std.time.ms_per_day,
        \\Piranesi
        \\
        \\The halls, the tides, the statues. Reread the flooding scene — the calm inventory voice is what makes it land.
    );
    _ = model.addNote(reading, now - 4 * std.time.ms_per_day,
        \\The Making of Prince of Persia
        \\
        \\Jordan Mechner's journals. The rotoscoping chapter pairs well with the animation notes in Ideas.
    );
    _ = model.addNote(ideas, now - 2 * std.time.ms_per_day,
        \\Reading queue mechanics
        \\
        \\The queue should surface the oldest unread item, not the newest. Novelty is the enemy of finishing.
    );
    _ = model.addNote(ideas, now - 26 * std.time.ms_per_hour,
        \\Field recorder for the balcony
        \\
        \\A tiny app that samples one minute of audio at sunrise and files it by date. Could pair with the weather log.
    );
    _ = model.addNote(inbox, now - 5 * std.time.ms_per_hour,
        \\Platform sync — Thursday
        \\
        \\Decisions:
        \\- Folders stay at a fixed capacity, loudly
        \\- Keyboard shortcuts land with the first release
        \\
        \\Follow-ups:
        \\- Snippet truncation at word boundaries
    );
    _ = model.addNote(inbox, now - 3 * std.time.ms_per_hour,
        \\Groceries
        \\
        \\- Coffee beans
        \\- Oat milk
        \\- Rye bread
        \\- Lemons
        \\- Parmesan
    );
    _ = model.addNote(inbox, now - 2 * std.time.ms_per_min,
        \\Welcome to Notes
        \\
        \\Everything here is a real note — edit this text and watch the list re-sort by edit time.
        \\
        \\The first line of a note becomes its title, the next lines become the preview, and search covers every folder's full text. Notes autosave a moment after you stop typing.
        \\
        \\The whole keyboard map is on the right when no note is open; start with Cmd+N.
    );

    model.selected_folder = all_folder_id;
    model.selectTopNote();
}

pub fn initialModel(clock: native_sdk.Clock) Model {
    var model = Model{ .clock = clock };
    seed(&model);
    return model;
}
