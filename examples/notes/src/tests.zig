const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const model_mod = @import("model.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const NotesUi = main.NotesUi;
const NotesApp = native_sdk.UiApp(Model, Msg);
const NotesMarkup = canvas.MarkupView(Model, Msg);

/// A fixed, plausible wall clock for deterministic relative labels.
const test_wall_ms: i64 = 1_700_000_000_000;

fn testClock(clock: *native_sdk.TestClock) native_sdk.Clock {
    clock.setWallMs(test_wall_ms);
    return clock.clock();
}

const shell_views = [_]native_sdk.ShellView{
    .{ .label = "notes-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Notes",
    .width = 1180,
    .height = 760,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

fn notesOptions() NotesApp.Options {
    return .{
        .name = "notes",
        .scene = shell_scene,
        .canvas_label = "notes-canvas",
        .update_fx = main.update,
        .init_fx = main.boot,
        .tokens_fn = main.notesTokens,
        .on_appearance = main.onAppearance,
        .on_command = main.command,
        .view = main.CompiledNotesView.build,
    };
}

// ------------------------------------------------------------ tree helpers

fn buildTree(arena: std.mem.Allocator, model: *const Model) !NotesUi.Tree {
    var ui = NotesUi.init(arena);
    return ui.finalize(main.CompiledNotesView.build(&ui, model));
}

fn interpretTree(arena: std.mem.Allocator, model: *const Model) !NotesUi.Tree {
    var view = try NotesMarkup.init(arena, main.notes_markup);
    var ui = NotesUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
    }
    return null;
}

fn subtreeHasText(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, text) != null) return true;
    for (widget.children) |child| {
        if (subtreeHasText(child, text)) return true;
    }
    return false;
}

fn collectIds(widget: canvas.Widget, ids: *std.ArrayListUnmanaged(canvas.ObjectId), allocator: std.mem.Allocator) !void {
    try ids.append(allocator, widget.id);
    for (widget.children) |child| try collectIds(child, ids, allocator);
}

// --------------------------------------------------------- harness helpers

fn snapshotWidgetNamed(snapshot: native_sdk.automation.snapshot.Input, role: []const u8, name: []const u8) ?native_sdk.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (std.mem.eql(u8, widget.role, role) and std.mem.eql(u8, widget.name, name)) return widget;
    }
    return null;
}

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *NotesApp,
    app: native_sdk.App,

    fn create(model: Model) !Harness {
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(1180, 760) });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        const app_state = try testing.allocator.create(NotesApp);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = NotesApp.init(std.heap.page_allocator, model, notesOptions());
        app_state.effects.executor = .fake;
        // The journaled clock reads (`fx.wallMs`) follow the model's
        // test clock, so boot's reseed and edit timestamps stay
        // deterministic under the harness.
        app_state.effects.clock = app_state.model.clock;
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = "notes-canvas",
            .size = geometry.SizeF.init(1180, 760),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        testing.allocator.destroy(self.app_state);
        self.harness.destroy(testing.allocator);
    }

    fn dispatch(self: *Harness, msg: Msg) !void {
        try self.app_state.dispatch(&self.harness.runtime, 1, msg);
    }

    fn wake(self: *Harness) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }

    fn shortcut(self: *Harness, id: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .shortcut = .{ .id = id, .key = "", .window_id = 1 } });
    }

    fn snapshot(self: *Harness) native_sdk.automation.snapshot.Input {
        return self.harness.runtime.automationSnapshot("Notes");
    }

    fn clickWidget(self: *Harness, id: u64) !void {
        var command_buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&command_buffer, "widget-click notes-canvas {d}", .{id});
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    /// The automation right-click: a full secondary-button pointer
    /// stream at the widget. The rows declare context menus, so the
    /// press asks the platform to present — the null platform records
    /// the request (`contextMenuItems`) the way macOS would show an OS
    /// menu; a presenter-less platform mounts the anchored fallback.
    fn contextPress(self: *Harness, id: u64) !void {
        var command_buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&command_buffer, "widget-context-press notes-canvas {d}", .{id});
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    /// Invoke one of a widget's declared context-menu items by index —
    /// the selection dispatches as the same `context_menu_action`
    /// platform event a real pick produces (presentation is skipped;
    /// the OS menu's tracking loop cannot be driven programmatically).
    fn contextMenuItem(self: *Harness, id: u64, index: usize) !void {
        var command_buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&command_buffer, "widget-context-menu notes-canvas {d} {d}", .{ id, index });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    /// The id of the widget keyboard focus is on (0 = none).
    fn focusedWidgetId(self: *Harness) canvas.ObjectId {
        for (self.harness.runtime.views[0..self.harness.runtime.view_count]) |view| {
            if (std.mem.eql(u8, view.label, "notes-canvas")) return view.canvas_widget_focused_id;
        }
        return 0;
    }

    /// A raw pointer click at a canvas point — for targets whose center
    /// is covered by something else (the dialog backdrop scrim).
    fn clickPoint(self: *Harness, x: f32, y: f32) !void {
        for ([_]native_sdk.platform.GpuSurfaceInputKind{ .pointer_down, .pointer_up }) |kind| {
            try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
                .window_id = 1,
                .label = "notes-canvas",
                .kind = kind,
                .timestamp_ns = 2_000_000,
                .x = x,
                .y = y,
                .button = 0,
            } });
        }
    }
};

// -------------------------------------------------------------- pure model

test "titles, snippets, and relative times derive from note bodies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Title: first non-empty line, trimmed; empty bodies are Untitled.
    try testing.expectEqualStrings("Groceries", model_mod.displayTitle(arena, "Groceries\n\n- Coffee\n"));
    try testing.expectEqualStrings("Second line first", model_mod.displayTitle(arena, "\n  \nSecond line first\nrest"));
    try testing.expectEqualStrings("Untitled", model_mod.displayTitle(arena, ""));
    try testing.expectEqualStrings("Untitled", model_mod.displayTitle(arena, "  \n \n"));

    // Long titles cut at a UTF-8 boundary with an ellipsis.
    const long_title = model_mod.displayTitle(arena, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa é tail");
    try testing.expect(std.mem.endsWith(u8, long_title, "…"));
    try testing.expect(std.unicode.utf8ValidateSlice(long_title));

    // Snippet: everything after the title, whitespace collapsed.
    try testing.expectEqualStrings("- Coffee - Milk", model_mod.displaySnippet(arena, "Groceries\n\n- Coffee\n- Milk\n"));
    try testing.expectEqualStrings("—", model_mod.displaySnippet(arena, "Just a title"));
    try testing.expectEqualStrings("—", model_mod.displaySnippet(arena, ""));

    // Relative labels bucket by age.
    const now = test_wall_ms;
    try testing.expectEqualStrings("now", model_mod.relativeTimeLabel(arena, now, now - 30 * std.time.ms_per_s));
    try testing.expectEqualStrings("5m", model_mod.relativeTimeLabel(arena, now, now - 5 * std.time.ms_per_min));
    try testing.expectEqualStrings("3h", model_mod.relativeTimeLabel(arena, now, now - 3 * std.time.ms_per_hour));
    try testing.expectEqualStrings("6d", model_mod.relativeTimeLabel(arena, now, now - 6 * std.time.ms_per_day));
    try testing.expectEqualStrings("2w", model_mod.relativeTimeLabel(arena, now, now - 15 * std.time.ms_per_day));
    try testing.expectEqualStrings("1y", model_mod.relativeTimeLabel(arena, now, now - 400 * std.time.ms_per_day));
}

test "the store serializes and restores losslessly, and rejects garbage" {
    var clock = native_sdk.TestClock{};
    var model = model_mod.initialModel(testClock(&clock));

    var buffer: [model_mod.max_store_bytes]u8 = undefined;
    const bytes = model.serializeStore(&buffer);
    try testing.expect(std.mem.startsWith(u8, bytes, model_mod.store_header));

    var restored = Model{ .clock = clock.clock() };
    try testing.expect(restored.restoreStore(bytes));
    try testing.expectEqual(model.folder_count, restored.folder_count);
    try testing.expectEqual(model.note_count, restored.note_count);
    try testing.expectEqual(model.next_folder_id, restored.next_folder_id);
    try testing.expectEqual(model.next_note_id, restored.next_note_id);
    for (model.folders[0..model.folder_count], restored.folders[0..restored.folder_count]) |*expected, *actual| {
        try testing.expectEqual(expected.id, actual.id);
        try testing.expectEqualStrings(expected.name(), actual.name());
    }
    for (model.notes[0..model.note_count], restored.notes[0..restored.note_count]) |*expected, *actual| {
        try testing.expectEqual(expected.id, actual.id);
        try testing.expectEqual(expected.folder, actual.folder);
        try testing.expectEqual(expected.created_ms, actual.created_ms);
        try testing.expectEqual(expected.updated_ms, actual.updated_ms);
        try testing.expectEqualStrings(expected.body.text(), actual.body.text());
    }
    // The restore pointed the editor at the newest note.
    try testing.expect(restored.active_note != 0);

    // Garbage, an empty store, and a header-only store all keep the
    // current content (restore reports false).
    var untouched = model_mod.initialModel(clock.clock());
    try testing.expect(!untouched.restoreStore("not a store"));
    try testing.expect(!untouched.restoreStore(""));
    try testing.expect(!untouched.restoreStore(model_mod.store_header ++ "\n"));
    try testing.expectEqual(model.note_count, untouched.note_count);

    // A note whose folder record was lost files under the first folder.
    const orphan = model_mod.store_header ++ "\nfolder 1 Inbox\nnote 9 42 5 5 0 2\nhi\n";
    var adopted = Model{ .clock = clock.clock() };
    try testing.expect(adopted.restoreStore(orphan));
    try testing.expectEqual(@as(u32, 1), adopted.notes[0].folder);
}

test "the store round-trips the Recently Deleted state" {
    var clock = native_sdk.TestClock{};
    var model = model_mod.initialModel(testClock(&clock));
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.clock = model.clock;

    // Trash one note; its record must carry the deleted timestamp.
    const doomed = model.notes[0].id;
    model_mod.update(&model, .{ .trash_note = doomed }, &fx);
    try testing.expect(model.noteById(doomed).?.isDeleted());

    var buffer: [model_mod.max_store_bytes]u8 = undefined;
    const bytes = model.serializeStore(&buffer);
    var restored = Model{ .clock = clock.clock() };
    try testing.expect(restored.restoreStore(bytes));
    try testing.expectEqual(model.note_count, restored.note_count);
    try testing.expectEqual(model.noteById(doomed).?.deleted_ms, restored.noteById(doomed).?.deleted_ms);
    try testing.expect(restored.trashAvailable());
    try testing.expectEqual(@as(usize, 1), restored.deletedNoteCount());
}

test "a v1 store migrates cleanly: every note loads live, the next save writes v2" {
    var clock = native_sdk.TestClock{};

    // A store exactly as the previous release wrote it: v1 header, note
    // records without the deleted field.
    const v1_store = model_mod.store_header_v1 ++ "\n" ++
        "folder 1 Inbox\n" ++
        "folder 2 Ideas\n" ++
        "note 1 1 5000 6000 11\n" ++ "Old note\nhi\n" ++
        "note 2 2 7000 8000 5\n" ++ "Later\n";

    var model = Model{ .clock = clock.clock() };
    try testing.expect(model.restoreStore(v1_store));
    try testing.expectEqual(@as(usize, 2), model.folder_count);
    try testing.expectEqual(@as(usize, 2), model.note_count);
    try testing.expectEqualStrings("Old note\nhi", model.notes[0].body.text());
    try testing.expectEqual(@as(i64, 8000), model.notes[1].updated_ms);
    // The migration: v1 records carry no deleted state, so everything
    // loads live — no Recently Deleted row appears out of nowhere.
    for (model.notes[0..model.note_count]) |*note| {
        try testing.expect(!note.isDeleted());
    }
    try testing.expect(!model.trashAvailable());

    // The next serialization writes the current version.
    var buffer: [model_mod.max_store_bytes]u8 = undefined;
    const bytes = model.serializeStore(&buffer);
    try testing.expect(std.mem.startsWith(u8, bytes, model_mod.store_header ++ "\n"));
    try testing.expect(std.mem.indexOf(u8, bytes, "note 1 1 5000 6000 0 11\n") != null);
    var reread = Model{ .clock = clock.clock() };
    try testing.expect(reread.restoreStore(bytes));
    try testing.expectEqual(@as(usize, 2), reread.note_count);
}

test "visible notes are folder-scoped, search-filtered, and newest first" {
    var clock = native_sdk.TestClock{};
    var model = model_mod.initialModel(testClock(&clock));

    var indexes: [model_mod.max_notes]usize = undefined;
    var count = model.visibleNoteIndexes(&indexes);
    try testing.expectEqual(@as(usize, 7), count);
    // Newest first: the welcome note (2m) leads, Piranesi (8d) trails.
    try testing.expect(std.mem.startsWith(u8, model.notes[indexes[0]].body.text(), "Welcome to Notes"));
    try testing.expect(std.mem.startsWith(u8, model.notes[indexes[count - 1]].body.text(), "Piranesi"));

    // Folder scope: Ideas holds two notes.
    model.selected_folder = 2;
    count = model.visibleNoteIndexes(&indexes);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(std.mem.startsWith(u8, model.notes[indexes[0]].body.text(), "Field recorder"));

    // Search is case-insensitive over the full body, across all folders.
    model.selected_folder = model_mod.all_folder_id;
    model.search_buffer.set("ROTOSCOPING");
    count = model.visibleNoteIndexes(&indexes);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(std.mem.startsWith(u8, model.notes[indexes[0]].body.text(), "The Making of Prince of Persia"));

    model.search_buffer.set("no such phrase anywhere");
    try testing.expectEqual(@as(usize, 0), model.visibleNoteIndexes(&indexes));
}

// ------------------------------------------------------------------- views

test "the initial tree renders folders, the note list, and the editor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var clock = native_sdk.TestClock{};
    var model = model_mod.initialModel(testClock(&clock));
    const tree = try buildTree(arena, &model);

    // Sidebar: All Notes + the three seeded folders, counts as badges,
    // the selection on All Notes.
    try testing.expect(findByText(tree.root, .text, "All Notes") != null);
    try testing.expect(findByText(tree.root, .text, "Inbox") != null);
    try testing.expect(findByText(tree.root, .text, "Ideas") != null);
    try testing.expect(findByText(tree.root, .text, "Reading") != null);
    const all_row = findByLabel(tree.root, "All Notes folder").?;
    try testing.expect(all_row.state.selected);
    try testing.expect(!findByLabel(tree.root, "Inbox folder").?.state.selected);
    try testing.expect(findByText(tree.root, .badge, "7") != null); // All Notes count
    try testing.expect(findByText(tree.root, .badge, "3") != null); // Inbox count

    // Note list: titles, snippets, and relative times derive per row;
    // the newest note is selected for the editor.
    try testing.expect(findByText(tree.root, .text, "Welcome to Notes") != null);
    try testing.expect(findByText(tree.root, .text, "Groceries") != null);
    try testing.expect(subtreeHasText(tree.root, "2m"));
    try testing.expect(subtreeHasText(tree.root, "3h"));
    try testing.expect(subtreeHasText(tree.root, "1w"));
    const active_row = findByLabel(tree.root, "Welcome to Notes").?;
    try testing.expect(active_row.state.selected);

    // Editor: the textarea mirrors the active note; the meta line and
    // status bar derive from the same truth.
    const editor = findByKind(tree.root, .textarea).?;
    try testing.expect(std.mem.startsWith(u8, editor.text, "Welcome to Notes"));
    try testing.expect(subtreeHasText(tree.root, "Edited 2m ago"));
    const status = findByKind(tree.root, .status_bar).?;
    try testing.expect(std.mem.startsWith(u8, status.text, "7 notes · 7 shown"));

    // The editor is the pane: no button row above the text — copy and
    // delete live in the note's context menu and the keyboard map.
    try testing.expect(findByText(tree.root, .button, "Copy") == null);
    try testing.expect(findByText(tree.root, .button, "Delete") == null);
    // Folder rename likewise lives in the folder's context menu.
    try testing.expect(findByText(tree.root, .button, "Rename") == null);

    // Row actions are DECLARED menu items on the rows themselves (the
    // platform presents them; nothing canvas-drawn mounts at rest): a
    // live note row offers Copy/Delete, a real folder Rename/Delete,
    // and the synthetic All Notes row declares nothing.
    const note_row = findByLabel(tree.root, "Welcome to Notes").?;
    try testing.expectEqual(@as(usize, 2), note_row.context_menu.len);
    try testing.expectEqualStrings("Copy", note_row.context_menu[0].label);
    try testing.expectEqualStrings("Delete", note_row.context_menu[1].label);
    const folder_row = findByLabel(tree.root, "Ideas folder").?;
    try testing.expectEqual(@as(usize, 2), folder_row.context_menu.len);
    try testing.expectEqualStrings("Rename", folder_row.context_menu[0].label);
    try testing.expectEqual(@as(usize, 0), all_row.context_menu.len);

    // No dialog, no mounted menu surface, and no Recently Deleted row
    // until they have a reason to exist.
    try testing.expect(findByKind(tree.root, .dialog) == null);
    try testing.expect(findByKind(tree.root, .dropdown_menu) == null);
    try testing.expect(findByText(tree.root, .text, "Recently Deleted") == null);
}

/// The audit-swept model states: the plain app and the Recently Deleted
/// scope with a trashed note open read-only. (Context menus hold no
/// model state — the anchored fallback surface is swept separately by
/// `buildTreeWithFallbackMenu`.)
fn sweepStates(clock: *native_sdk.TestClock) [2]Model {
    var states: [2]Model = undefined;
    states[0] = model_mod.initialModel(testClock(clock));
    states[1] = states[0];
    states[1].notes[0].deleted_ms = test_wall_ms - std.time.ms_per_hour;
    states[1].selected_folder = model_mod.deleted_scope_id;
    states[1].active_note = states[1].notes[0].id;
    return states;
}

/// Build the tree with the context-menu fallback surface mounted on a
/// note row — the presentation a presenter-less host shows — so the
/// layout and a11y sweeps cover the synthesized surface too.
fn buildTreeWithFallbackMenu(arena: std.mem.Allocator, model: *const Model) !NotesUi.Tree {
    const plain = try buildTree(arena, model);
    const row = findByLabel(plain.root, "Welcome to Notes") orelse return error.TestUnexpectedResult;
    var ui = NotesUi.init(arena);
    ui.context_menu_fallback_target = row.id;
    const tree = try ui.finalize(main.CompiledNotesView.build(&ui, model));
    if (tree.context_menu_fallback == null) return error.TestUnexpectedResult;
    return tree;
}

test "layout audit sweep: nothing clips, overlaps, or escapes" {
    var clock = native_sdk.TestClock{};
    for (sweepStates(&clock)) |model| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const tree = try buildTree(arena_state.allocator(), &model);
        try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, .{
            .tokens = main.notesTokens(&model),
            .min_size = geometry.SizeF.init(main.window_min_width, main.window_min_height),
            .default_size = geometry.SizeF.init(main.window_width, main.window_height),
        });
    }
    // The anchored fallback surface (presenter-less hosts) sweeps clean
    // too — it floats against its row, clipped by the window.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = model_mod.initialModel(testClock(&clock));
    const fallback_tree = try buildTreeWithFallbackMenu(arena_state.allocator(), &model);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, fallback_tree.root, .{
        .tokens = main.notesTokens(&model),
        .min_size = geometry.SizeF.init(main.window_min_width, main.window_min_height),
        .default_size = geometry.SizeF.init(main.window_width, main.window_height),
    });
}

test "a11y audit sweep: every interactive widget is named, reachable, and unambiguous" {
    var clock = native_sdk.TestClock{};
    for (sweepStates(&clock)) |model| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const tree = try buildTree(arena_state.allocator(), &model);
        try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, .{
            .tokens = main.notesTokens(&model),
            .min_size = geometry.SizeF.init(main.window_min_width, main.window_min_height),
            .default_size = geometry.SizeF.init(main.window_width, main.window_height),
        });
    }
    // Every synthesized fallback menu item is named by its label text.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = model_mod.initialModel(testClock(&clock));
    const fallback_tree = try buildTreeWithFallbackMenu(arena_state.allocator(), &model);
    try canvas.expectA11yAuditSweepClean(testing.allocator, fallback_tree.root, .{
        .tokens = main.notesTokens(&model),
        .min_size = geometry.SizeF.init(main.window_min_width, main.window_min_height),
        .default_size = geometry.SizeF.init(main.window_width, main.window_height),
    });
}

test "the idle editor pane shows the keyboard reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var clock = native_sdk.TestClock{};
    var model = model_mod.initialModel(testClock(&clock));
    model.active_note = 0;
    const tree = try buildTree(arena, &model);

    try testing.expect(findByKind(tree.root, .textarea) == null);
    try testing.expect(findByText(tree.root, .text, "No note selected") != null);
    try testing.expect(subtreeHasText(tree.root, "Cmd+Shift+N"));
    try testing.expect(subtreeHasText(tree.root, "Cmd+1 … Cmd+7"));
}

test "the compiled view and the hot-reload interpreter build the same tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var clock = native_sdk.TestClock{};

    // Parity across every conditional surface: the dialog and the
    // Recently Deleted scope (context menus hold no model state; their
    // declared items are compared below).
    var states = sweepStates(&clock);
    states[0].dialog = .create_folder;
    for (states) |model| {
        const compiled = try buildTree(arena, &model);
        const interpreted = try interpretTree(arena, &model);

        var compiled_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
        defer compiled_ids.deinit(testing.allocator);
        var interpreted_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
        defer interpreted_ids.deinit(testing.allocator);
        try collectIds(compiled.root, &compiled_ids, testing.allocator);
        try collectIds(interpreted.root, &interpreted_ids, testing.allocator);
        try testing.expectEqualSlices(canvas.ObjectId, interpreted_ids.items, compiled_ids.items);
        try testing.expectEqual(interpreted.handlers.len, compiled.handlers.len);

        // Declared context-menu items agree row for row, item for item
        // — both scopes (live rows' Copy/Delete, trashed rows' Restore/
        // Delete Permanently, folders' Rename/Delete, All Notes' none).
        for (interpreted_ids.items) |id| {
            const interpreted_row = findWidgetById(interpreted.root, id).?;
            const compiled_row = findWidgetById(compiled.root, id).?;
            try testing.expectEqual(interpreted_row.context_menu.len, compiled_row.context_menu.len);
            for (interpreted_row.context_menu, compiled_row.context_menu) |expected_item, actual_item| {
                try testing.expectEqualStrings(expected_item.label, actual_item.label);
                try testing.expectEqual(expected_item.enabled, actual_item.enabled);
                try testing.expectEqual(expected_item.separator, actual_item.separator);
            }
        }
    }
}

fn findWidgetById(widget: canvas.Widget, id: canvas.ObjectId) ?canvas.Widget {
    if (widget.id == id) return widget;
    for (widget.children) |child| {
        if (findWidgetById(child, id)) |found| return found;
    }
    return null;
}

test "the notes app lays out three panes through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var clock = native_sdk.TestClock{};
    var model = model_mod.initialModel(testClock(&clock));
    const tree = try buildTree(arena_state.allocator(), &model);

    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 1180, 760), &nodes);
    try testing.expect(layout.nodes.len > 0);

    const editor = findByKind(tree.root, .textarea).?;
    var editor_frame: ?geometry.RectF = null;
    var scroll_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.widget.id == editor.id) editor_frame = node.frame;
        if (node.widget.kind == .scroll_view and scroll_frame == null) scroll_frame = node.frame;
    }
    // The editor gets the space beside the two fixed rails.
    try testing.expect(editor_frame.?.width > 500);
    try testing.expect(editor_frame.?.height > 500);
    // The note list scrolls inside its fixed-width rail.
    try testing.expect(scroll_frame.?.width > 250);
    try testing.expect(scroll_frame.?.width < 320);
}

// ---------------------------------------------------------------- dispatch

test "editing the active note re-titles, re-sorts, and arms the autosave" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const fx = &h.app_state.effects;
    const model = &h.app_state.model;
    model.setStorePath("/tmp/zn-notes-test/store.txt");

    // Open an older note and edit it: the body mutates in place, the
    // edit time bumps, and the note jumps to the top of the list.
    const groceries_id = blk: {
        var indexes: [model_mod.max_notes]usize = undefined;
        const count = model.visibleNoteIndexes(&indexes);
        try testing.expectEqual(@as(usize, 7), count);
        break :blk model.notes[indexes[1]].id; // Groceries (3h)
    };
    try h.dispatch(.{ .open_note = groceries_id });
    clock.advanceMs(std.time.ms_per_min);
    try h.dispatch(.{ .edit = .{ .move_caret = .{ .direction = .end } } });
    try h.dispatch(.{ .edit = .{ .insert_text = "\n- Basil" } });

    const note = model.noteById(groceries_id).?;
    try testing.expect(std.mem.endsWith(u8, note.body.text(), "- Basil"));
    try testing.expectEqual(test_wall_ms + std.time.ms_per_min, note.updated_ms);
    var indexes: [model_mod.max_notes]usize = undefined;
    _ = model.visibleNoteIndexes(&indexes);
    try testing.expectEqual(groceries_id, model.notes[indexes[0]].id);

    // The edit armed the one-shot save debounce; firing it writes the
    // whole serialized store to the store path.
    var timer_found = false;
    var timer_index: usize = 0;
    while (fx.pendingTimerAt(timer_index)) |request| : (timer_index += 1) {
        if (request.key == model_mod.save_timer_key) {
            try testing.expectEqual(model_mod.save_debounce_ms, request.interval_ms);
            timer_found = true;
        }
    }
    try testing.expect(timer_found);
    try fx.fireTimer(model_mod.save_timer_key);
    try h.wake();
    const write_request = fx.pendingFileAt(0).?;
    try testing.expectEqual(model_mod.store_write_key, write_request.key);
    try testing.expectEqual(native_sdk.EffectFileOp.write, write_request.op);
    try testing.expectEqualStrings("/tmp/zn-notes-test/store.txt", write_request.path);
    try testing.expect(std.mem.startsWith(u8, write_request.bytes, model_mod.store_header));
    try testing.expect(std.mem.indexOf(u8, write_request.bytes, "- Basil") != null);

    // A save requested while the write is in flight re-persists on the
    // acknowledgement — the newest state always reaches disk.
    try h.dispatch(.{ .edit = .{ .insert_text = "\n- Thyme" } });
    try fx.fireTimer(model_mod.save_timer_key);
    try h.wake();
    try testing.expect(model.save_pending);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
    const rewrite = fx.pendingFileAt(0).?;
    try testing.expectEqual(model_mod.store_write_key, rewrite.key);
    try testing.expect(std.mem.indexOf(u8, rewrite.bytes, "- Thyme") != null);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
    try testing.expectEqualStrings("Saved", model.status());
}

test "boot restores the persisted store before the first paint" {
    var clock = native_sdk.TestClock{};
    var donor = model_mod.initialModel(testClock(&clock));
    donor.folder_count = 0;
    donor.note_count = 0;
    donor.next_folder_id = 1;
    donor.next_note_id = 1;
    const projects = donor.addFolder("Projects").?;
    _ = donor.addNote(projects, test_wall_ms - std.time.ms_per_hour, "Restored plan\n\nShip the notes example.");
    var store_buffer: [model_mod.max_store_bytes]u8 = undefined;
    const store_bytes = donor.serializeStore(&store_buffer);

    var boot_clock = native_sdk.TestClock{};
    var model = model_mod.initialModel(testClock(&boot_clock));
    model.setStorePath("/tmp/zn-notes-test/store.txt");
    var h = try Harness.create(model);
    defer h.destroy();
    const fx = &h.app_state.effects;

    // init_fx issued the read on the installing frame.
    const read_request = fx.pendingFileAt(0).?;
    try testing.expectEqual(model_mod.store_read_key, read_request.key);
    try testing.expectEqual(native_sdk.EffectFileOp.read, read_request.op);
    try testing.expectEqualStrings("/tmp/zn-notes-test/store.txt", read_request.path);

    try fx.feedFileResult(model_mod.store_read_key, .ok, store_bytes);
    try h.wake();
    try testing.expectEqual(@as(usize, 1), h.app_state.model.note_count);
    try testing.expectEqualStrings("Projects", h.app_state.model.folders[0].name());
    try testing.expect(std.mem.indexOf(u8, h.app_state.model.status(), "Loaded 1 notes") != null);

    // The restored note reached the widgets.
    const snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "Restored plan") != null);
    try testing.expect(snapshotWidgetNamed(snapshot, "treeitem", "Projects folder") != null);

    // A missing store (first run) keeps the seeds, quietly.
    var fresh_clock = native_sdk.TestClock{};
    var fresh_model = model_mod.initialModel(testClock(&fresh_clock));
    fresh_model.setStorePath("/tmp/zn-notes-test/none.txt");
    var fresh = try Harness.create(fresh_model);
    defer fresh.destroy();
    try fresh.app_state.effects.feedFileResult(model_mod.store_read_key, .not_found, "");
    try fresh.wake();
    try testing.expectEqual(@as(usize, 7), fresh.app_state.model.note_count);
    try testing.expectEqual(@as(usize, 0), fresh.app_state.model.status().len);
}

test "the folder dialog creates and renames through real widget clicks" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const fx = &h.app_state.effects;
    const model = &h.app_state.model;
    model.setStorePath("/tmp/zn-notes-test/store.txt");

    // The sidebar button opens the create dialog.
    var snapshot = h.snapshot();
    const new_folder_button = snapshotWidgetNamed(snapshot, "button", "New folder").?;
    try h.clickWidget(new_folder_button.id);
    try testing.expectEqual(model_mod.DialogMode.create_folder, model.dialog);
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "dialog", "New Folder") != null);

    // Confirm is disabled while the name is empty; typing enables it.
    const disabled_confirm = snapshotWidgetNamed(snapshot, "button", "Confirm dialog").?;
    try testing.expect(!disabled_confirm.enabled);
    try h.dispatch(.{ .folder_field_edit = .{ .insert_text = "Projects" } });
    snapshot = h.snapshot();
    const confirm = snapshotWidgetNamed(snapshot, "button", "Confirm dialog").?;
    try testing.expect(confirm.enabled);
    try h.clickWidget(confirm.id);

    // The folder exists, is selected, and the store persisted.
    try testing.expectEqual(model_mod.DialogMode.closed, model.dialog);
    try testing.expectEqual(@as(usize, 4), model.folder_count);
    try testing.expectEqualStrings("Projects", model.listTitle());
    try testing.expect(std.mem.indexOf(u8, model.status(), "Created folder Projects") != null);
    const write_request = fx.pendingFileAt(0).?;
    try testing.expect(std.mem.indexOf(u8, write_request.bytes, "folder 4 Projects") != null);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();

    // Duplicate names are refused with an inline hint, dialog stays up.
    try h.dispatch(.open_create_folder);
    try h.dispatch(.{ .folder_field_edit = .{ .insert_text = "inbox" } });
    try h.dispatch(.confirm_dialog);
    try testing.expectEqual(model_mod.DialogMode.create_folder, model.dialog);
    try testing.expect(model.dialog_hint.len > 0);
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "text", "That name is already taken.") != null);
    try h.dispatch(.close_dialog);

    // Rename prefills the selected folder's name and applies in place.
    try h.dispatch(.{ .select_folder = 2 });
    try h.dispatch(.open_rename_folder);
    try testing.expectEqualStrings("Ideas", model.folderName());
    try h.dispatch(.{ .folder_field_edit = .clear });
    try h.dispatch(.{ .folder_field_edit = .{ .insert_text = "Sketches" } });
    try h.dispatch(.confirm_dialog);
    try testing.expectEqual(model_mod.DialogMode.closed, model.dialog);
    try testing.expectEqualStrings("Sketches", model.folderById(2).?.name());
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();

    // Clicking the scrim (any point outside the centered dialog — here
    // over the sidebar it covers) closes without applying.
    try h.dispatch(.open_create_folder);
    try h.clickPoint(60, 400);
    try testing.expectEqual(model_mod.DialogMode.closed, model.dialog);

    // Capacity binds loudly: at six folders the button disables and the
    // shortcut path reports instead of opening.
    try testing.expectEqual(@as(u32, 5), model.addFolder("Archive").?);
    try testing.expectEqual(@as(u32, 6), model.addFolder("Someday").?);
    try testing.expect(model.foldersFull());
    try h.dispatch(.open_create_folder);
    try testing.expectEqual(model_mod.DialogMode.closed, model.dialog);
    try testing.expect(std.mem.indexOf(u8, model.status(), "Folder limit reached") != null);
    snapshot = h.snapshot();
    try testing.expect(!snapshotWidgetNamed(snapshot, "button", "New folder").?.enabled);
}

test "the keyboard map drives the whole app through shortcut commands" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const fx = &h.app_state.effects;
    const model = &h.app_state.model;
    model.setStorePath("/tmp/zn-notes-test/store.txt");

    // Cmd+2 jumps to the first real folder (position 1 = Inbox).
    try h.shortcut(main.folder_command_prefix ++ "2");
    try testing.expectEqual(@as(u32, 1), model.selected_folder);
    try testing.expectEqualStrings("Inbox", model.listTitle());

    // Cmd+Opt+Down/Up walk the visible ordering.
    const first = model.active_note;
    try h.shortcut(main.cmd_next_note);
    try testing.expect(model.active_note != first);
    try h.shortcut(main.cmd_prev_note);
    try testing.expectEqual(first, model.active_note);
    try h.shortcut(main.cmd_prev_note); // clamps at the top
    try testing.expectEqual(first, model.active_note);

    // Cmd+N creates an empty note in the selected folder and opens it.
    try h.shortcut(main.cmd_new_note);
    try testing.expectEqual(@as(usize, 8), model.note_count);
    const created = model.activeNote().?;
    try testing.expectEqual(@as(u32, 1), created.folder);
    try testing.expectEqual(@as(usize, 0), created.body.text().len);
    try testing.expect(std.mem.indexOf(u8, model.status(), "New note in Inbox") != null);
    const write_request = fx.pendingFileAt(0).?;
    try testing.expectEqual(model_mod.store_write_key, write_request.key);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();

    // Cmd+Backspace moves it to Recently Deleted (the record stays for
    // restore) and the selection falls to the next note.
    const doomed = model.active_note;
    try h.shortcut(main.cmd_delete_note);
    try testing.expectEqual(@as(usize, 8), model.note_count);
    try testing.expectEqual(@as(usize, 1), model.deletedNoteCount());
    try testing.expect(std.mem.indexOf(u8, model.status(), "Moved \"Untitled\" to Recently Deleted") != null);
    try testing.expectEqual(first, model.active_note);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();

    // In the Recently Deleted scope the same key deletes permanently.
    try h.dispatch(.select_trash);
    try testing.expectEqual(doomed, model.active_note);
    try h.shortcut(main.cmd_delete_note);
    try testing.expectEqual(@as(usize, 7), model.note_count);
    try testing.expect(std.mem.indexOf(u8, model.status(), "Deleted \"Untitled\" permanently") != null);
    // The trash emptied, so its row is gone and the selection fell back.
    try testing.expectEqual(model_mod.all_folder_id, model.selected_folder);
    try testing.expectEqual(first, model.active_note);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
    // Back where the walk started: Cmd+2's folder scope was left behind
    // by the trash round-trip, so re-enter it for the copy leg below.
    try h.shortcut(main.folder_command_prefix ++ "2");

    // Cmd+Shift+N opens the dialog; Escape dismisses it.
    try h.shortcut(main.cmd_new_folder);
    try testing.expectEqual(model_mod.DialogMode.create_folder, model.dialog);
    try h.shortcut(main.cmd_dismiss);
    try testing.expectEqual(model_mod.DialogMode.closed, model.dialog);

    // Escape with no dialog clears the search instead.
    try h.dispatch(.{ .search_edit = .{ .insert_text = "piranesi" } });
    try testing.expect(model.searching());
    try h.shortcut(main.cmd_dismiss);
    try testing.expect(!model.searching());

    // Cmd+Shift+C copies the active note through the clipboard effect.
    try h.shortcut(main.cmd_copy_note);
    try testing.expectEqual(@as(usize, 1), fx.pendingClipboardCount());
    const copy_request = fx.pendingClipboardAt(0).?;
    try testing.expectEqual(model_mod.copy_key, copy_request.key);
    try testing.expectEqualStrings(model.activeNote().?.body.text(), copy_request.text);
    try fx.feedClipboardResult(model_mod.copy_key, .ok, "");
    try h.wake();
    try testing.expectEqualStrings("Copied to clipboard", model.status());
}

test "search filters live and the built-in clear affordance resets it" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const model = &h.app_state.model;

    try h.dispatch(.{ .search_edit = .{ .insert_text = "coffee" } });
    var snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "Groceries") != null);
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "Piranesi") == null);

    try h.dispatch(.{ .search_edit = .{ .insert_text = " nowhere" } });
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "text", "No matches") != null);

    // Clearing is the search field's own affordance now: a field holding
    // text renders a trailing x, and pressing it clears through the
    // standard edit path (the on-input handler receives `.clear`). Hit
    // the real rect through raw pointer events.
    const layout = try h.harness.runtime.canvasWidgetLayout(1, "notes-canvas");
    const tokens = try h.harness.runtime.canvasWidgetDesignTokens(1, "notes-canvas");
    var clear_rect: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.widget.kind != .search_field) continue;
        var field = node.widget;
        field.frame = node.frame;
        clear_rect = canvas.textInputClearButtonRect(field, tokens);
        break;
    }
    const rect = clear_rect orelse return error.TestUnexpectedResult;
    try h.clickPoint(rect.x + rect.width * 0.5, rect.y + rect.height * 0.5);
    try testing.expect(!model.searching());
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "Piranesi") != null);

    // The same clear arrives as a plain `.clear` edit through on-input —
    // the model path the affordance rides.
    try h.dispatch(.{ .search_edit = .{ .insert_text = "walk" } });
    try testing.expect(model.searching());
    try h.dispatch(.{ .search_edit = .clear });
    try testing.expect(!model.searching());
}

test "folder and note rows dispatch selection through real clicks" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const model = &h.app_state.model;

    // Clicking a folder row scopes the list and re-targets the editor at
    // that folder's newest note.
    var snapshot = h.snapshot();
    const ideas_row = snapshotWidgetNamed(snapshot, "treeitem", "Ideas folder").?;
    try h.clickWidget(ideas_row.id);
    try testing.expectEqual(@as(u32, 2), model.selected_folder);
    try testing.expect(std.mem.startsWith(u8, model.activeNote().?.body.text(), "Field recorder"));

    // Clicking a note row opens it in the editor.
    snapshot = h.snapshot();
    const queue_row = snapshotWidgetNamed(snapshot, "listitem", "Reading queue mechanics").?;
    try h.clickWidget(queue_row.id);
    try testing.expect(std.mem.startsWith(u8, model.activeNote().?.body.text(), "Reading queue mechanics"));
}

test "a note row's context menu copies, deletes, restores, and purges through real dispatch" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const fx = &h.app_state.effects;
    const model = &h.app_state.model;
    model.setStorePath("/tmp/zn-notes-test/store.txt");

    // The note row DECLARES its menu; the snapshot lists the items in
    // invocation order. Right-clicking presents it through the platform
    // (the null platform records the request the way macOS shows an
    // NSMenu) — no model state changes, no selection change.
    var snapshot = h.snapshot();
    const active_before = model.active_note;
    const groceries_row = snapshotWidgetNamed(snapshot, "listitem", "Groceries").?;
    try testing.expectEqual(@as(usize, 2), groceries_row.context_menu.len);
    try testing.expectEqualStrings("Copy", groceries_row.context_menu[0].label);
    try testing.expectEqualStrings("Delete", groceries_row.context_menu[1].label);
    try h.contextPress(groceries_row.id);
    try testing.expectEqual(@as(usize, 1), h.harness.null_platform.context_menu_request_count);
    try testing.expectEqual(groceries_row.id, h.harness.null_platform.context_menu_token);
    const presented = h.harness.null_platform.contextMenuItems();
    try testing.expectEqual(@as(usize, 2), presented.len);
    try testing.expectEqualStrings("Copy", presented[0].label);
    try testing.expectEqualStrings("Delete", presented[1].label);
    try testing.expectEqual(active_before, model.active_note);
    const groceries_id = blk: {
        for (model.notes[0..model.note_count]) |*note| {
            if (std.mem.startsWith(u8, note.body.text(), "Groceries")) break :blk note.id;
        }
        return error.TestUnexpectedResult;
    };

    // Selecting Copy — driven by index through the same
    // context_menu_action dispatch a real pick takes — pipes the ROW's
    // body (not the open note's) through the clipboard effect.
    try h.contextMenuItem(groceries_row.id, 0);
    const copy_request = fx.pendingClipboardAt(0).?;
    try testing.expect(std.mem.startsWith(u8, copy_request.text, "Groceries"));
    try fx.feedClipboardResult(model_mod.copy_key, .ok, "");
    try h.wake();

    // Delete from the menu moves the note to Recently Deleted and the
    // sidebar row appears — it exists only while trash is non-empty.
    try h.contextMenuItem(groceries_row.id, 1);
    try testing.expect(model.noteById(groceries_id).?.isDeleted());
    try testing.expect(std.mem.indexOf(u8, model.status(), "Moved \"Groceries\" to Recently Deleted") != null);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "Groceries") == null);
    const trash_row = snapshotWidgetNamed(snapshot, "treeitem", "Recently Deleted folder").?;

    // Inside Recently Deleted the same row declares Restore / Delete
    // Permanently instead — no Copy in the trash scope.
    try h.clickWidget(trash_row.id);
    try testing.expectEqual(model_mod.deleted_scope_id, model.selected_folder);
    try testing.expectEqualStrings("Recently Deleted", model.listTitle());
    snapshot = h.snapshot();
    const trashed_row = snapshotWidgetNamed(snapshot, "listitem", "Groceries").?;
    try testing.expectEqual(@as(usize, 2), trashed_row.context_menu.len);
    try testing.expectEqualStrings("Restore", trashed_row.context_menu[0].label);
    try testing.expectEqualStrings("Delete Permanently", trashed_row.context_menu[1].label);
    for (trashed_row.context_menu) |item| {
        try testing.expect(!std.mem.eql(u8, item.label, "Copy"));
    }

    // Restore puts the note back in its folder; the emptied trash row
    // disappears and the selection falls back to All Notes.
    try h.contextMenuItem(trashed_row.id, 0);
    try testing.expect(!model.noteById(groceries_id).?.isDeleted());
    try testing.expectEqual(model_mod.all_folder_id, model.selected_folder);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "Groceries") != null);
    try testing.expect(snapshotWidgetNamed(snapshot, "treeitem", "Recently Deleted folder") == null);

    // Delete Permanently is the one path that removes the record.
    const before_purge = model.note_count;
    try h.dispatch(.{ .trash_note = groceries_id });
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
    try h.dispatch(.{ .purge_note = groceries_id });
    try testing.expectEqual(before_purge - 1, model.note_count);
    try testing.expect(model.noteById(groceries_id) == null);
    try testing.expect(std.mem.indexOf(u8, model.status(), "Deleted \"Groceries\" permanently") != null);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
}

test "a folder row's context menu renames and deletes through real dispatch" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const fx = &h.app_state.effects;
    const model = &h.app_state.model;
    model.setStorePath("/tmp/zn-notes-test/store.txt");

    // The Ideas row declares Rename / Delete; right-clicking presents
    // them natively (recorded) without touching the selection — menus
    // act on their own row, so no select-first dance.
    var snapshot = h.snapshot();
    const ideas_row = snapshotWidgetNamed(snapshot, "treeitem", "Ideas folder").?;
    try testing.expectEqual(@as(usize, 2), ideas_row.context_menu.len);
    try testing.expectEqualStrings("Rename", ideas_row.context_menu[0].label);
    try testing.expectEqualStrings("Delete", ideas_row.context_menu[1].label);
    try h.contextPress(ideas_row.id);
    try testing.expectEqual(@as(usize, 1), h.harness.null_platform.context_menu_request_count);
    try testing.expectEqual(ideas_row.id, h.harness.null_platform.context_menu_token);
    try testing.expectEqual(model_mod.all_folder_id, model.selected_folder);

    // Rename opens the same dialog flow the keyboard uses, prefilled,
    // targeting the row's folder rather than the selection.
    try h.contextMenuItem(ideas_row.id, 0);
    try testing.expectEqual(model_mod.DialogMode.rename_folder, model.dialog);
    try testing.expectEqual(@as(u32, 2), model.dialog_folder);
    try testing.expectEqualStrings("Ideas", model.folderName());
    try h.dispatch(.{ .folder_field_edit = .clear });
    try h.dispatch(.{ .folder_field_edit = .{ .insert_text = "Sketches" } });
    try h.dispatch(.confirm_dialog);
    try testing.expectEqualStrings("Sketches", model.folderById(2).?.name());
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();

    // The synthetic All Notes row declares NO items, so a right-click
    // presents nothing (and never falls through to a press).
    snapshot = h.snapshot();
    const all_row = snapshotWidgetNamed(snapshot, "treeitem", "All Notes folder").?;
    try testing.expectEqual(@as(usize, 0), all_row.context_menu.len);
    const requests_before = h.harness.null_platform.context_menu_request_count;
    try h.contextPress(all_row.id);
    try testing.expectEqual(requests_before, h.harness.null_platform.context_menu_request_count);

    // Delete moves the folder's live notes to Recently Deleted and drops
    // the folder.
    const notes_before = model.note_count;
    snapshot = h.snapshot();
    const sketches_row = snapshotWidgetNamed(snapshot, "treeitem", "Sketches folder").?;
    try h.contextMenuItem(sketches_row.id, 1);
    try testing.expect(model.folderById(2) == null);
    try testing.expectEqual(notes_before, model.note_count);
    try testing.expectEqual(@as(usize, 2), model.deletedNoteCount());
    try testing.expect(std.mem.indexOf(u8, model.status(), "Deleted folder \"Sketches\" · 2 notes to Recently Deleted") != null);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "treeitem", "Sketches folder") == null);
    try testing.expect(snapshotWidgetNamed(snapshot, "treeitem", "Recently Deleted folder") != null);

    // Restored notes from a deleted folder file under the first folder.
    var indexes: [model_mod.max_notes]usize = undefined;
    model.selected_folder = model_mod.deleted_scope_id;
    const trash_count = model.visibleNoteIndexes(&indexes);
    try testing.expectEqual(@as(usize, 2), trash_count);
    const orphan_id = model.notes[indexes[0]].id;
    try h.dispatch(.{ .restore_note = orphan_id });
    try testing.expectEqual(model.folders[0].id, model.noteById(orphan_id).?.folder);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();

    // The last folder refuses deletion — a new note always needs a home.
    main.update(model, .{ .delete_folder = model.folders[1].id }, fx);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
    try testing.expectEqual(@as(usize, 1), model.folder_count);
    try h.dispatch(.{ .delete_folder = model.folders[0].id });
    try testing.expectEqual(@as(usize, 1), model.folder_count);
    try testing.expect(std.mem.indexOf(u8, model.status(), "Keep at least one folder") != null);
}

test "the folder dialog autofocuses its name field the moment it opens" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const model = &h.app_state.model;

    // Nothing is focused until the user acts.
    try testing.expectEqual(@as(canvas.ObjectId, 0), h.focusedWidgetId());

    // Clicking New Folder mounts the dialog; the autofocus edge lands
    // the keyboard in the name field with no second click.
    var snapshot = h.snapshot();
    const new_folder_button = snapshotWidgetNamed(snapshot, "button", "New folder").?;
    try h.clickWidget(new_folder_button.id);
    try testing.expectEqual(model_mod.DialogMode.create_folder, model.dialog);
    snapshot = h.snapshot();
    const name_field = snapshotWidgetNamed(snapshot, "textbox", "Folder name").?;
    try testing.expectEqual(@as(canvas.ObjectId, @intCast(name_field.id)), h.focusedWidgetId());

    // Typing lands in the field through the ordinary key path — no
    // click in between.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "notes-canvas",
        .kind = .key_down,
        .key = "P",
        .text = "P",
    } });
    try testing.expectEqualStrings("P", model.folderName());

    // Reopening after a close re-focuses (edge-triggered on mount).
    try h.dispatch(.close_dialog);
    try h.dispatch(.open_create_folder);
    snapshot = h.snapshot();
    const refocused = snapshotWidgetNamed(snapshot, "textbox", "Folder name").?;
    try testing.expectEqual(@as(canvas.ObjectId, @intCast(refocused.id)), h.focusedWidgetId());
}

test "a Recently Deleted note opens read-only with the restore affordance" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const fx = &h.app_state.effects;
    const model = &h.app_state.model;
    model.setStorePath("/tmp/zn-notes-test/store.txt");

    const doomed = model.active_note;
    try h.dispatch(.{ .trash_note = doomed });
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
    try h.dispatch(.select_trash);
    try testing.expectEqual(doomed, model.active_note);

    // The pane renders the body as plain text with one action — no
    // textarea, no edits.
    var snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "button", "Restore note") != null);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), model);
    try testing.expect(findByKind(tree.root, .textarea) == null);
    try testing.expect(subtreeHasText(tree.root, "Deleted just now"));
    const body_before = model.noteById(doomed).?.body.text().len;
    try h.dispatch(.{ .edit = .{ .insert_text = "sneaky edit" } });
    try testing.expectEqual(body_before, model.noteById(doomed).?.body.text().len);

    // Restore through the pane's button: the note is live again and
    // stays open (the emptied trash fell back to All Notes, where the
    // note is visible).
    snapshot = h.snapshot();
    const restore_button = snapshotWidgetNamed(snapshot, "button", "Restore note").?;
    try h.clickWidget(restore_button.id);
    try testing.expect(!model.noteById(doomed).?.isDeleted());
    try testing.expectEqual(model_mod.all_folder_id, model.selected_folder);
    try testing.expectEqual(doomed, model.active_note);
    try fx.feedFileResult(model_mod.store_write_key, .ok, "");
    try h.wake();
}

test "splitter drags resize the panes through the model-owned fraction" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const model = &h.app_state.model;
    try testing.expectApproxEqAbs(@as(f32, 0.19), model.sidebar_split, 0.0001);

    // The outer split's divider is the first split_divider in tree order
    // (the sidebar seam). Drag it right through real pointer events: the
    // runtime applies the fraction, dispatches on-resize, and the model
    // echoes it — the rebuild lays panes at the model's value.
    const layout = try h.harness.runtime.canvasWidgetLayout(1, "notes-canvas");
    var divider_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.widget.kind == .split_divider) {
            divider_frame = node.frame;
            break;
        }
    }
    const seam = divider_frame orelse return error.TestUnexpectedResult;
    const grab_x = seam.x + seam.width * 0.5;
    const grab_y = seam.y + 40;
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "notes-canvas", .kind = .pointer_down, .x = grab_x, .y = grab_y, .button = 0 } });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "notes-canvas", .kind = .pointer_drag, .x = grab_x + 90, .y = grab_y } });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "notes-canvas", .kind = .pointer_up, .x = grab_x + 90, .y = grab_y, .button = 0 } });

    try testing.expect(model.sidebar_split > 0.24);
    // The rebuilt layout lays the seam at the model's fraction.
    const resized = try h.harness.runtime.canvasWidgetLayout(1, "notes-canvas");
    var resized_seam: ?geometry.RectF = null;
    for (resized.nodes) |node| {
        if (node.widget.kind == .split_divider) {
            resized_seam = node.frame;
            break;
        }
    }
    try testing.expect(resized_seam.?.x > seam.x + 80);

    // The inner seam guards the editor's min width: dragging far right
    // clamps instead of collapsing the editor pane.
    main.update(model, .{ .list_resized = 0.99 }, &h.app_state.effects);
    try testing.expect(model.list_split > 0.9);
}

test "folder tree keys move the selection through real key dispatch" {
    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    const model = &h.app_state.model;

    // Click the first folder row (All Notes) to land keyboard focus in
    // the tree, then walk with the ARIA tree keymap: Down moves the
    // selection through visible rows (selection follows focus through
    // each row's on-press), End jumps to the last folder, Home back to
    // the first.
    var snapshot = h.snapshot();
    const all_row = snapshotWidgetNamed(snapshot, "treeitem", "All Notes folder").?;
    try h.clickWidget(all_row.id);
    try testing.expectEqual(model_mod.all_folder_id, model.selected_folder);

    const key = struct {
        fn down(harness: *Harness, name: []const u8) !void {
            try harness.harness.runtime.dispatchPlatformEvent(harness.app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "notes-canvas", .kind = .key_down, .key = name } });
        }
    };

    try key.down(&h, "arrowdown");
    try testing.expectEqual(@as(u32, 1), model.selected_folder);
    try key.down(&h, "arrowdown");
    try testing.expectEqual(@as(u32, 2), model.selected_folder);
    try key.down(&h, "end");
    try testing.expectEqual(model.folders[model.folder_count - 1].id, model.selected_folder);
    try key.down(&h, "home");
    try testing.expectEqual(model_mod.all_folder_id, model.selected_folder);
    // Up at the first row stays put (no wrap).
    try key.down(&h, "arrowup");
    try testing.expectEqual(model_mod.all_folder_id, model.selected_folder);

    // The snapshot mirrors the selection on the treeitem rows.
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "treeitem", "All Notes folder").?.selected);
}

test "the system appearance re-derives the tokens live, both directions" {
    var fx = NotesApp.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Model level: the scheme Msg flips the derived palette both ways —
    // there is no in-window theme control by design.
    var clock = native_sdk.TestClock{};
    var model = model_mod.initialModel(testClock(&clock));
    const light_tokens = main.notesTokens(&model);
    main.update(&model, .{ .system_scheme = .dark }, &fx);
    const dark_tokens = main.notesTokens(&model);
    try testing.expect(!std.meta.eql(light_tokens.colors.background, dark_tokens.colors.background));
    main.update(&model, .{ .system_scheme = .light }, &fx);
    try testing.expect(std.meta.eql(light_tokens.colors.background, main.notesTokens(&model).colors.background));

    // End to end: the OS appearance event reaches the canvas tokens
    // through `on_appearance`, live, in both directions.
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    const dark_live = try h.harness.runtime.canvasWidgetDesignTokens(1, "notes-canvas");
    try testing.expect(std.meta.eql(dark_tokens.colors.background, dark_live.colors.background));
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .appearance_changed = .{ .color_scheme = .light } });
    const light_live = try h.harness.runtime.canvasWidgetDesignTokens(1, "notes-canvas");
    try testing.expect(std.meta.eql(light_tokens.colors.background, light_live.colors.background));
}

test "the note list scroll offset round-trips through the model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = NotesApp.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var clock = native_sdk.TestClock{};
    var model = model_mod.initialModel(testClock(&clock));

    // The runtime delivers the applied offset; the model stores it…
    main.update(&model, .{ .note_list_scrolled = .{ .offset = 42, .viewport_extent = 500, .content_extent = 900 } }, &fx);
    try testing.expectEqual(@as(f32, 42), model.note_list_scroll);

    // …and the rebuilt tree echoes it back through the scroll's value,
    // so rebuilds re-lay the list at exactly the scrolled place.
    const tree = try buildTree(arena, &model);
    const list = findByLabel(tree.root, "Note list") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(canvas.WidgetKind.scroll_view, list.kind);
    try testing.expectEqual(@as(f32, 42), list.value);

    // Jumping to a folder resets the offset: the new list starts at its
    // top instead of inheriting the previous folder's scroll.
    main.update(&model, .{ .select_folder = 2 }, &fx);
    try testing.expectEqual(@as(f32, 0), model.note_list_scroll);
}

// Env-gated screenshot renderer (skipped by default, never in CI): renders
// the app OFFSCREEN through the deterministic reference renderer via the
// automation screenshot artifact — no live window. PNGs land in
// /tmp/icon-batch-shots/notes-*-artifacts/. To use:
//
//   ICON_BATCH_SHOTS=1 zig build test
test "render icon-batch screenshots (env-gated)" {
    if (!envGateSet("ICON_BATCH_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();

    // Light mode: folder icons on the sidebar rows, plus the New note
    // button in the header.
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/icon-batch-shots/notes-light-artifacts", "Notes");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot notes-canvas 2");

    // Dark mode while searching: the search field's built-in trailing
    // clear x.
    try h.dispatch(.{ .system_scheme = .dark });
    try h.dispatch(.{ .search_edit = .{ .insert_text = "walk" } });
    try presentShotFrame(&h, 2);
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/icon-batch-shots/notes-dark-artifacts", "Notes");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot notes-canvas 2");
}

fn presentShotFrame(h: *Harness, frame_index: u64) !void {
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = "notes-canvas",
        .size = geometry.SizeF.init(1180, 760),
        .scale_factor = 2,
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .nonblank = true,
    } });
}

// Env-gated homepage screenshot renderer (skipped by default, never in
// CI): the docs-homepage showcase state — the seeded notes list with the
// first note open — once per color scheme, same state in both. PNGs land
// in /tmp/homepage-shots/notes-{light,dark}-artifacts/. To use:
//
//   HOMEPAGE_SHOTS=1 zig build test
test "render homepage screenshots (env-gated)" {
    if (!envGateSet("HOMEPAGE_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();

    // The docs site overlays CSS stoplights on the capture, inside the
    // header's own chrome gap. Reserve that gap for real: the standard
    // macOS tall hidden-inset geometry (the same numbers the
    // chrome-geometry test pins) arrives through the app's chrome
    // channel, so the header pads exactly where the site's dots land.
    try h.dispatch(main.onChrome(.{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 19, 52, 14),
    }).?);
    try presentShotFrame(&h, 2);

    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/notes-light-artifacts", "Notes");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot notes-canvas 2");

    // Same state, dark scheme via the OS appearance channel (the app
    // follows the system appearance): the dispatch re-emits the display
    // list with the re-derived tokens, so no present is needed in between.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/notes-dark-artifacts", "Notes");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot notes-canvas 2");
}

// Env-gated state-shot renderer (skipped by default, never in CI): the
// conditional surfaces a static screenshot cannot show — a note row's
// context menu, a folder row's menu, and the Recently Deleted scope with
// a trashed note open read-only. On macOS a right-click presents a real
// OS menu, which lives outside the canvas — so the shots model a
// presenter-less host and capture the anchored FALLBACK surface (the
// presentation Linux/Windows users see). Driven through the same
// automation right-click path a live session uses. PNGs land in
// /tmp/notes-state-shots/<state>-artifacts/. To use:
//
//   NOTES_STATE_SHOTS=1 zig build test
test "render state screenshots (env-gated)" {
    if (!envGateSet("NOTES_STATE_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    var clock = native_sdk.TestClock{};
    var h = try Harness.create(model_mod.initialModel(testClock(&clock)));
    defer h.destroy();
    // Presenter-less host: right-clicks mount the anchored fallback
    // surface on the canvas, where the screenshot can see it.
    h.harness.null_platform.context_menus = false;
    h.harness.runtime.options.platform = h.harness.null_platform.platform();

    const dismissFallback = struct {
        fn run(harness: *Harness) !void {
            const fallback = harness.app_state.tree.?.context_menu_fallback orelse return;
            var command_buffer: [96]u8 = undefined;
            const command = try std.fmt.bufPrint(&command_buffer, "widget-action notes-canvas {d} dismiss", .{fallback.surface_id});
            try harness.harness.runtime.dispatchAutomationCommand(harness.app, command);
        }
    }.run;

    // A note row's menu, opened by the automation right-click.
    var snapshot = h.snapshot();
    const groceries_row = snapshotWidgetNamed(snapshot, "listitem", "Groceries").?;
    try h.contextPress(groceries_row.id);
    try presentShotFrame(&h, 2);
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/notes-state-shots/note-menu-artifacts", "Notes");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot notes-canvas 2");

    // A folder row's menu.
    try dismissFallback(&h);
    snapshot = h.snapshot();
    const ideas_row = snapshotWidgetNamed(snapshot, "treeitem", "Ideas folder").?;
    try h.contextPress(ideas_row.id);
    try presentShotFrame(&h, 3);
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/notes-state-shots/folder-menu-artifacts", "Notes");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot notes-canvas 2");

    // Recently Deleted selected, its rows' menu open over the read-only
    // note pane (Restore in both places).
    try dismissFallback(&h);
    try h.dispatch(.{ .trash_note = h.app_state.model.active_note });
    try h.dispatch(.select_trash);
    try presentShotFrame(&h, 4);
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/notes-state-shots/recently-deleted-artifacts", "Notes");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot notes-canvas 2");

    snapshot = h.snapshot();
    const trashed_row = snapshotWidgetNamed(snapshot, "listitem", "Welcome to Notes").?;
    try h.contextPress(trashed_row.id);
    try presentShotFrame(&h, 5);
    h.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/notes-state-shots/trash-menu-artifacts", "Notes");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot notes-canvas 2");
}

/// Env-gated dump switch. `std.c.getenv` needs libc, which this test
/// build only links on targets whose platform layer pulls it in; when
/// libc is absent the gate reads as unset and the gated test skips.
fn envGateSet(name: [*:0]const u8) bool {
    if (comptime !@import("builtin").link_libc) return false;
    return std.c.getenv(name) != null;
}

test "chrome geometry pads the header and matches its height to the tall band" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = model_mod.initialModel(.system);
    try testing.expectEqual(model_mod.header_natural_height, model.header_height);

    // The tall hidden-inset band arrives through on_chrome: the header
    // pads past the traffic lights and matches the band's height so its
    // centered controls share the lights' centerline.
    const chrome: native_sdk.WindowChrome = .{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 19, 52, 14),
    };
    const msg = main.onChrome(chrome) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, msg, &fx);
    try testing.expectEqual(@as(f32, 78), model.chrome_leading);
    try testing.expectEqual(@max(model_mod.header_natural_height, 52), model.header_height);

    // A band taller than the natural header grows the header with it.
    const tall = main.onChrome(.{ .insets = .{ .top = 72, .left = 78 } }) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, tall, &fx);
    try testing.expectEqual(@as(f32, 72), model.header_height);

    // Fullscreen zeroes the chrome: the pad collapses and the height
    // falls back to the header's natural floor.
    const cleared = main.onChrome(.{}) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, cleared, &fx);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    try testing.expectEqual(model_mod.header_natural_height, model.header_height);

    // The scene declares the matching titlebar so the platform actually
    // hides the OS bar this header replaces.
    try testing.expectEqual(.hidden_inset_tall, main.shell_scene.windows[0].titlebar);
}
