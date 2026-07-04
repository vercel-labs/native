const std = @import("std");
const zero_native = @import("zero-native");
const main = @import("main.zig");

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const ViewerUi = main.ViewerUi;
const ViewerApp = zero_native.UiApp(Model, Msg);
const ViewerMarkup = canvas.MarkupView(Model, Msg);

const shell_views = [_]zero_native.ShellView{
    .{ .label = "viewer-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const shell_windows = [_]zero_native.ShellWindow{.{
    .label = "main",
    .title = "Markdown Viewer",
    .width = 1200,
    .height = 760,
    .views = &shell_views,
}};
const shell_scene: zero_native.ShellConfig = .{ .windows = &shell_windows };

fn viewerOptions() ViewerApp.Options {
    return .{
        .name = "markdown-viewer",
        .scene = shell_scene,
        .canvas_label = "viewer-canvas",
        .update_fx = main.update,
        .init_fx = main.boot,
        .tokens_fn = main.viewerTokens,
        .view = main.CompiledViewerView.build,
    };
}

// ------------------------------------------------------------ tree helpers

fn buildTree(arena: std.mem.Allocator, model: *const Model) !ViewerUi.Tree {
    var ui = ViewerUi.init(arena);
    return ui.finalize(main.CompiledViewerView.build(&ui, model));
}

fn interpretTree(arena: std.mem.Allocator, model: *const Model) !ViewerUi.Tree {
    var view = try ViewerMarkup.init(arena, main.viewer_markup);
    var ui = ViewerUi.init(arena);
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

fn snapshotWidgetNamed(snapshot: zero_native.automation.snapshot.Input, role: []const u8, name: []const u8) ?zero_native.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (std.mem.eql(u8, widget.role, role) and std.mem.eql(u8, widget.name, name)) return widget;
    }
    return null;
}

const Harness = struct {
    harness: *zero_native.TestHarness(),
    app_state: *ViewerApp,
    app: zero_native.App,

    fn create() !Harness {
        const harness = try zero_native.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(1200, 760) });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        const app_state = try testing.allocator.create(ViewerApp);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = ViewerApp.init(std.heap.page_allocator, main.initialModel(), viewerOptions());
        app_state.effects.executor = .fake;
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = "viewer-canvas",
            .size = geometry.SizeF.init(1200, 760),
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

    fn snapshot(self: *Harness) zero_native.automation.snapshot.Input {
        return self.harness.runtime.automationSnapshot("Markdown Viewer");
    }

    fn clickWidget(self: *Harness, id: u64) !void {
        var command_buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&command_buffer, "widget-click viewer-canvas {d}", .{id});
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }
};

// ------------------------------------------------------------------- tests

test "the initial tree renders the welcome sample in editor and preview" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    const tree = try buildTree(arena, &model);

    // The toolbar is present and Save is disabled (nothing opened yet).
    try testing.expect(findByText(tree.root, .button, "Open") != null);
    const save = findByText(tree.root, .button, "Save").?;
    try testing.expect(save.state.disabled);
    try testing.expect(findByText(tree.root, .button, "Save As") != null);

    // The editor mirrors the sample source; the preview rendered it as
    // widgets (the H1 becomes a span paragraph, the table becomes cells).
    const editor = findByKind(tree.root, .textarea).?;
    try testing.expect(std.mem.startsWith(u8, editor.text, "# Markdown Viewer"));
    try testing.expect(findByText(tree.root, .data_cell, "Open") != null);
    try testing.expect(subtreeHasText(tree.root, "Markdown Viewer"));

    // The sidebar lists all samples; the welcome one is selected.
    const welcome_item = findByText(tree.root, .list_item, "Welcome").?;
    try testing.expect(welcome_item.state.selected);
    try testing.expect(!findByText(tree.root, .list_item, "Renderer tour").?.state.selected);

    // Word count derives from the live document.
    const status = findByKind(tree.root, .status_bar).?;
    const expected_words = main.countWords(model.document());
    var prefix_buffer: [32]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buffer, "{d} words", .{expected_words});
    try testing.expect(std.mem.startsWith(u8, status.text, prefix));
}

test "the compiled view and the hot-reload interpreter build the same tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.loadSample(2);

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
}

test "editing the textarea updates the preview and derived counts through dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.editor.set("# One\n");
    model.active_sample_id = 0;

    var tree = try buildTree(arena, &model);
    const editor = findByKind(tree.root, .textarea).?;

    // Type through the real dispatch path: the edit lands in the mirror,
    // the rebuilt preview renders the new heading.
    const edit = tree.msgForTextEdit(editor.id, .{ .insert_text = "curious words" }).?;
    var fx = ViewerApp.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, edit, &fx);
    try testing.expectEqualStrings("# One\ncurious words", model.document());
    try testing.expectEqual(@as(u32, 0), model.active_sample_id);
    try testing.expectEqual(@as(usize, 4), main.countWords(model.document()));
    try testing.expectEqual(@as(usize, 2), main.countLines(model.document()));

    tree = try buildTree(arena, &model);
    try testing.expect(subtreeHasText(tree.root, "curious words"));
}

test "open and save round-trip through the fake executor" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    const model = &h.app_state.model;

    // Recent-list persistence is wired to a store path in this test.
    model.setRecentStorePath("/tmp/zn-markdown-viewer-test/recent.txt");

    // Type a path and open it: the read request is recorded verbatim.
    try h.dispatch(.{ .edit_path = .clear });
    try h.dispatch(.{ .edit_path = .{ .insert_text = "/tmp/zn-md-note.md" } });
    try h.dispatch(.open_doc);
    try testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    const read_request = fx.pendingFileAt(0).?;
    try testing.expectEqual(main.open_key, read_request.key);
    try testing.expectEqual(zero_native.EffectFileOp.read, read_request.op);
    try testing.expectEqualStrings("/tmp/zn-md-note.md", read_request.path);

    // The read lands: the editor adopts the bytes, the path becomes
    // current, the file joins the recent list, and the list persists.
    try fx.feedFileResult(main.open_key, .ok, "# Loaded\n\nfrom disk\n");
    try h.wake();
    try testing.expectEqualStrings("# Loaded\n\nfrom disk\n", model.document());
    try testing.expectEqualStrings("/tmp/zn-md-note.md", model.currentPath());
    try testing.expectEqual(@as(usize, 1), model.recent_count);
    try testing.expectEqualStrings("/tmp/zn-md-note.md", model.recentAt(0));
    const recent_write = fx.pendingFileAt(0).?;
    try testing.expectEqual(main.recent_write_key, recent_write.key);
    try testing.expectEqual(zero_native.EffectFileOp.write, recent_write.op);
    try testing.expectEqualStrings("/tmp/zn-markdown-viewer-test/recent.txt", recent_write.path);
    try testing.expectEqualStrings("/tmp/zn-md-note.md\n", recent_write.bytes);
    try fx.feedFileResult(main.recent_write_key, .ok, "");
    try h.wake();

    // Save is now enabled and writes the edited document back whole.
    try h.dispatch(.{ .edit = .{ .move_caret = .{ .direction = .end } } });
    try h.dispatch(.{ .edit = .{ .insert_text = "appended\n" } });
    try h.dispatch(.save_doc);
    const write_request = fx.pendingFileAt(0).?;
    try testing.expectEqual(main.save_key, write_request.key);
    try testing.expectEqual(zero_native.EffectFileOp.write, write_request.op);
    try testing.expectEqualStrings("/tmp/zn-md-note.md", write_request.path);
    try testing.expectEqualStrings("# Loaded\n\nfrom disk\nappended\n", write_request.bytes);
    try fx.feedFileResult(main.save_key, .ok, "");
    try h.wake();
    try testing.expect(std.mem.indexOf(u8, model.note(), "Saved") != null);

    // A failed open reports its outcome without touching the document.
    try h.dispatch(.{ .edit_path = .clear });
    try h.dispatch(.{ .edit_path = .{ .insert_text = "/tmp/zn-md-missing.md" } });
    try h.dispatch(.open_doc);
    try fx.feedFileResult(main.open_key, .not_found, "");
    try h.wake();
    try testing.expect(std.mem.indexOf(u8, model.note(), "not_found") != null);
    try testing.expectEqualStrings("# Loaded\n\nfrom disk\nappended\n", model.document());
    try testing.expectEqualStrings("/tmp/zn-md-note.md", model.currentPath());
}

test "save as adopts the path field and boot restores the recent list" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    const model = &h.app_state.model;

    // Save As writes the welcome sample to the typed path.
    try h.dispatch(.{ .edit_path = .{ .insert_text = "/tmp/zn-md-copy.md" } });
    try h.dispatch(.save_as);
    const write_request = fx.pendingFileAt(0).?;
    try testing.expectEqual(main.save_key, write_request.key);
    try testing.expectEqualStrings("/tmp/zn-md-copy.md", write_request.path);
    try testing.expectEqualStrings(model.document(), write_request.bytes);
    try fx.feedFileResult(main.save_key, .ok, "");
    try h.wake();
    try testing.expectEqualStrings("/tmp/zn-md-copy.md", model.currentPath());
    try testing.expect(!model.cannotSave());

    // Boot with a store path issues the recent read; restoring parses one
    // path per line, newest first, and renders into the sidebar.
    model.setRecentStorePath("/tmp/zn-markdown-viewer-test/recent.txt");
    main.boot(model, fx);
    const read_request = fx.pendingFileAt(0).?;
    try testing.expectEqual(main.recent_read_key, read_request.key);
    try fx.feedFileResult(main.recent_read_key, .ok, "/tmp/a-doc.md\n/tmp/b-doc.md\n");
    try h.wake();
    try testing.expectEqual(@as(usize, 2), model.recent_count);
    try testing.expectEqualStrings("/tmp/a-doc.md", model.recentAt(0));

    // The sidebar items are named by their full path (the accessible
    // label) while displaying the basename.
    const snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "/tmp/a-doc.md") != null);
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "/tmp/b-doc.md") != null);
}

test "preview links open through fx.spawn and details expand through the model" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    const model = &h.app_state.model;

    // The welcome sample's preview exposes a real link; clicking it spawns
    // the platform browser command with the link's URL.
    var snapshot = h.snapshot();
    const link = snapshotWidgetNamed(snapshot, "link", "real links").?;
    try testing.expect(link.actions.press);
    try h.clickWidget(link.id);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    const spawn_request = fx.pendingSpawnAt(0).?;
    try testing.expectEqual(main.link_key, spawn_request.key);
    try testing.expectEqualStrings("https://ziglang.org", spawn_request.argv[spawn_request.argv.len - 1]);
    try fx.feedExit(main.link_key, 0);
    try h.wake();
    try testing.expect(std.mem.indexOf(u8, model.note(), "browser") != null);

    // Load the spec sample: its details blocks render collapsed (the
    // snapshot enumerates below-the-fold widgets too) and its task list
    // renders display-only checkboxes.
    const spec_item = snapshotWidgetNamed(snapshot, "listitem", "RFC: Session sync").?;
    try h.clickWidget(spec_item.id);
    try testing.expectEqual(@as(u32, 3), model.active_sample_id);
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "▸ Failure modes considered") != null);
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "▸ Rejected alternatives") != null);
    try testing.expect(!subtreeHasTextInSnapshot(snapshot, "Server unreachable"));
    const done_task = snapshotWidgetNamed(snapshot, "checkbox", "Deterministic merge for concurrent edits on two devices").?;
    try testing.expect(!done_task.enabled);
    try testing.expect(done_task.selected);

    // Widget clicks require a visible frame, so drive the details toggle
    // on a short document typed through the real edit dispatch path.
    try h.dispatch(.{ .edit = .clear });
    try h.dispatch(.{ .edit = .{ .insert_text = "# T\n\n<details>\n<summary>Alpha</summary>\n\nAlpha body.\n\n</details>\n\n<details>\n<summary>Beta</summary>\n\nBeta body.\n\n</details>\n" } });
    snapshot = h.snapshot();
    try testing.expect(!subtreeHasTextInSnapshot(snapshot, "Alpha body."));
    const summary = snapshotWidgetNamed(snapshot, "listitem", "▸ Alpha").?;
    try h.clickWidget(summary.id);
    try testing.expect(model.details_expanded[0]);
    try testing.expect(!model.details_expanded[1]);
    snapshot = h.snapshot();
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "▾ Alpha") != null);
    try testing.expect(snapshotWidgetNamed(snapshot, "listitem", "▸ Beta") != null);
    try testing.expect(subtreeHasTextInSnapshot(snapshot, "Alpha body."));
    try testing.expect(!subtreeHasTextInSnapshot(snapshot, "Beta body."));

    // Loading a sample resets the expansion flags.
    const tour_item = snapshotWidgetNamed(snapshot, "listitem", "Renderer tour").?;
    try h.clickWidget(tour_item.id);
    try testing.expect(!model.details_expanded[0]);
}

/// True when any non-editor widget carries `needle` — the textarea always
/// holds the whole source, so it is excluded to observe the preview only.
fn subtreeHasTextInSnapshot(snapshot: zero_native.automation.snapshot.Input, needle: []const u8) bool {
    for (snapshot.widgets) |widget| {
        if (std.mem.eql(u8, widget.role, "textbox")) continue;
        if (std.mem.indexOf(u8, widget.name, needle) != null) return true;
        if (std.mem.indexOf(u8, widget.text_value, needle) != null) return true;
    }
    return false;
}

test "the theme toggle flips the derived tokens" {
    var fx = ViewerApp.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = main.initialModel();
    const light_tokens = main.viewerTokens(&model);
    main.update(&model, .toggle_theme, &fx);
    const dark_tokens = main.viewerTokens(&model);
    try testing.expect(!std.meta.eql(light_tokens.colors.background, dark_tokens.colors.background));
    try testing.expectEqual(canvas.ColorScheme.dark, model.effectiveScheme());

    // The system scheme flows in but the explicit override keeps winning.
    main.update(&model, .{ .system_scheme = .light }, &fx);
    try testing.expectEqual(canvas.ColorScheme.dark, model.effectiveScheme());
    main.update(&model, .toggle_theme, &fx);
    try testing.expectEqual(canvas.ColorScheme.light, model.effectiveScheme());
}

test "the viewer lays out through the canvas engine at window size" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    const tree = try buildTree(arena_state.allocator(), &model);

    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 1200, 760), &nodes);
    try testing.expect(layout.nodes.len > 0);

    const editor = findByKind(tree.root, .textarea).?;
    var editor_frame: ?geometry.RectF = null;
    var scroll_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.widget.id == editor.id) editor_frame = node.frame;
        if (node.widget.kind == .scroll_view and scroll_frame == null) scroll_frame = node.frame;
    }
    // Editor and preview split the space beside the sidebar.
    try testing.expect(editor_frame.?.width > 350);
    try testing.expect(scroll_frame.?.width > 350);
    try testing.expect(editor_frame.?.height > 500);
}
