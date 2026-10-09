const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;
const CodeEditorMarkup = canvas.MarkupView(main.Model, main.Msg);

fn buildTree(arena: std.mem.Allocator, model: *const main.Model) !main.BrowserUi.Tree {
    var ui = main.BrowserUi.init(arena);
    return ui.finalize(main.CompiledCodeEditorView.build(&ui, model));
}

fn interpretTree(arena: std.mem.Allocator, model: *const main.Model) !main.BrowserUi.Tree {
    var view = try CodeEditorMarkup.init(arena, main.code_editor_markup);
    var ui = main.BrowserUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
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

fn findByRole(widget: canvas.Widget, role: canvas.WidgetRole) ?canvas.Widget {
    if (widget.semantics.role == role) return widget;
    for (widget.children) |child| {
        if (findByRole(child, role)) |found| return found;
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

fn findByRoleAndLabel(widget: canvas.Widget, role: canvas.WidgetRole, label: []const u8) ?canvas.Widget {
    if (widget.semantics.role == role and std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByRoleAndLabel(child, role, label)) |found| return found;
    }
    return null;
}

fn countRole(widget: canvas.Widget, role: canvas.WidgetRole) usize {
    var count: usize = if (widget.semantics.role == role) 1 else 0;
    for (widget.children) |child| count += countRole(child, role);
    return count;
}

fn retainedWidgetTextBytes(widget: canvas.Widget) usize {
    var count = widget.text.len + widget.icon.len + widget.command.len + widget.semantics.label.len;
    for (widget.context_menu) |item| count += item.label.len;
    for (widget.spans) |span| count += span.link.len;
    for (widget.chart.x_labels) |label| count += label.len;
    for (widget.chart.series) |series| count += series.label.len;
    for (widget.children) |child| count += retainedWidgetTextBytes(child);
    return count;
}

fn collectIds(widget: canvas.Widget, ids: *std.ArrayListUnmanaged(canvas.ObjectId), allocator: std.mem.Allocator) !void {
    try ids.append(allocator, widget.id);
    for (widget.children) |child| try collectIds(child, ids, allocator);
}

fn seedActiveDocument(model: *main.Model, entry_index: u16, source: []const u8) void {
    model.tree_selected_entry = entry_index;
    model.selected_entry = entry_index;
    model.document_count = 1;
    model.documents[0] = .{
        .entry_index = entry_index,
        .editor = main.EditorBuffer.init(std.heap.page_allocator, source) catch unreachable,
        .state = .text,
        .saved_len = source.len,
        .saved_hash = std.hash.Wyhash.hash(0, source),
    };
}

fn appendDocument(model: *main.Model, entry_index: u16, source: []const u8) void {
    const document = &model.documents[model.document_count];
    document.* = .{
        .entry_index = entry_index,
        .editor = main.EditorBuffer.init(std.heap.page_allocator, source) catch unreachable,
        .state = .text,
        .saved_len = source.len,
        .saved_hash = std.hash.Wyhash.hash(0, source),
    };
    model.document_count += 1;
}

fn fixtureModel() !main.Model {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src/lib");
    try tmp.dir.createDirPath(testing.io, ".git");
    try tmp.dir.createDirPath(testing.io, "node_modules/pkg");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "README.md", .data = "# Fixture\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/lib/util.zig", .data = "pub const answer = 42;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".git/config", .data = "hidden\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "node_modules/pkg/index.js", .data = "hidden\n" });

    var model = main.Model{};
    try main.scanOpenDirectory(&model, testing.io, testing.allocator, "/fixture", tmp.dir);
    var src_dir = try tmp.dir.openDir(testing.io, "src", .{ .iterate = true });
    defer src_dir.close(testing.io);
    try main.loadOpenDirectoryChildren(&model, testing.io, model.findEntry("src").?, src_dir);
    var lib_dir = try tmp.dir.openDir(testing.io, "src/lib", .{ .iterate = true });
    defer lib_dir.close(testing.io);
    try main.loadOpenDirectoryChildren(&model, testing.io, model.findEntry("src/lib").?, lib_dir);
    model.entries[model.findEntry("src").?].expanded = false;
    model.entries[model.findEntry("src/lib").?].expanded = false;
    return model;
}

test "titlebar derives the folder name and preserves a filesystem root" {
    var model = main.Model{};
    try testing.expectEqualStrings("Code Explorer", model.rootName());

    const path = "/Users/ctate/Developer/3d-maze/";
    @memcpy(model.root_storage[0..path.len], path);
    model.root_len = path.len;
    try testing.expectEqualStrings("3d-maze", model.rootName());

    model.root_storage[0] = '/';
    model.root_len = 1;
    try testing.expectEqualStrings("/", model.rootName());
}

test "mjs files use JavaScript syntax highlighting" {
    var model = try fixtureModel();
    defer model.deinit();
    const selected_index = model.findEntry("src/main.zig").?;
    const selected = &model.entries[selected_index];
    const mjs_path = "src/main.mjs";
    @memcpy(selected.relative_storage[0..mjs_path.len], mjs_path);
    selected.relative_len = mjs_path.len;
    model.selected_entry = selected_index;

    try testing.expectEqual(native_sdk.code.Language.javascript, model.previewLanguage());
}

test "yaml and yml files use YAML syntax highlighting" {
    var model = try fixtureModel();
    defer model.deinit();
    const selected_index = model.findEntry("src/main.zig").?;
    const selected = &model.entries[selected_index];
    seedActiveDocument(&model, selected_index, "name: value\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    inline for (.{ "workflow.yaml", "workflow.yml" }) |yaml_path| {
        @memcpy(selected.relative_storage[0..yaml_path.len], yaml_path);
        selected.relative_len = yaml_path.len;
        try testing.expectEqual(native_sdk.code.Language.yaml, model.previewLanguage());

        _ = arena_state.reset(.retain_capacity);
        const compiled = try buildTree(arena_state.allocator(), &model);
        try testing.expectEqual(native_sdk.code.Language.yaml, findByKind(compiled.root, .textarea).?.code_language);

        _ = arena_state.reset(.retain_capacity);
        const interpreted = try interpretTree(arena_state.allocator(), &model);
        try testing.expectEqual(native_sdk.code.Language.yaml, findByKind(interpreted.root, .textarea).?.code_language);
    }
}

test "Markdown files use Markdown syntax highlighting" {
    var model = try fixtureModel();
    defer model.deinit();
    const selected_index = model.findEntry("README.md").?;
    seedActiveDocument(&model, selected_index, "# Fixture\n\n- highlighted\n");
    try testing.expectEqual(native_sdk.code.Language.markdown, model.previewLanguage());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const compiled = try buildTree(arena_state.allocator(), &model);
    try testing.expectEqual(native_sdk.code.Language.markdown, findByKind(compiled.root, .textarea).?.code_language);

    _ = arena_state.reset(.retain_capacity);
    const interpreted = try interpretTree(arena_state.allocator(), &model);
    try testing.expectEqual(native_sdk.code.Language.markdown, findByKind(interpreted.root, .textarea).?.code_language);
}

test "folder scanning builds a sorted, bounded tree without descending generated directories" {
    var model = try fixtureModel();
    defer model.deinit();

    try testing.expectEqualStrings("/fixture", model.rootPath());
    try testing.expectEqualStrings("fixture", model.rootName());
    const expected_names = [_][]const u8{
        ".git",
        "node_modules",
        "src",
        "lib",
        "util.zig",
        "main.zig",
        "README.md",
    };
    try testing.expectEqual(expected_names.len, model.entry_count);
    for (expected_names, model.entries[0..model.entry_count]) |expected, entry| {
        try testing.expectEqualStrings(expected, entry.name());
    }
    try testing.expect(model.findEntry("README.md") != null);
    try testing.expect(model.findEntry("src") != null);
    try testing.expect(model.findEntry("src/main.zig") != null);
    try testing.expect(model.findEntry("src/lib/util.zig") != null);
    try testing.expect(model.findEntry(".git") != null);
    try testing.expect(model.findEntry("node_modules") != null);
    try testing.expect(model.findEntry(".git/config") == null);
    const package_path = try std.fs.path.join(testing.allocator, &.{ "node_modules", "pkg" });
    defer testing.allocator.free(package_path);
    try testing.expect(model.findEntry(package_path) == null);
    try testing.expect(!model.scan_truncated);

    // Only root children render until their ancestors expand.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const root_entries = model.visible(arena_state.allocator());
    try testing.expectEqual(@as(usize, 4), root_entries.len);
    try testing.expectEqualStrings(".git", root_entries[0].name);
    try testing.expectEqualStrings("node_modules", root_entries[1].name);
    try testing.expectEqualStrings("src", root_entries[2].name);
    try testing.expectEqualStrings("README.md", root_entries[3].name);
    try testing.expect(root_entries[0].directory);
    try testing.expect(root_entries[1].directory);
    try testing.expect(root_entries[2].directory);
    try testing.expect(!root_entries[3].directory);

    const src_index = model.findEntry("src").?;
    model.entries[src_index].expanded = true;
    _ = arena_state.reset(.retain_capacity);
    try testing.expectEqual(@as(usize, 6), model.visible(arena_state.allocator()).len);

    const lib_path = try std.fs.path.join(testing.allocator, &.{ "src", "lib" });
    defer testing.allocator.free(lib_path);
    const lib_index = model.findEntry(lib_path).?;
    model.entries[lib_index].expanded = true;
    _ = arena_state.reset(.retain_capacity);
    try testing.expectEqual(@as(usize, 7), model.visible(arena_state.allocator()).len);
}

test "folder scanning does not report an exact-cap directory as truncated" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (0..main.max_entries) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "file-{d:0>3}.txt", .{index});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
    }

    var model = main.Model{};
    defer model.deinit();
    try main.scanOpenDirectory(&model, testing.io, testing.allocator, "/exact-cap", tmp.dir);

    try testing.expectEqual(main.max_entries, model.entry_count);
    try testing.expect(!model.scan_truncated);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one-more.txt", .data = "" });
    try main.scanOpenDirectory(&model, testing.io, testing.allocator, "/over-cap", tmp.dir);
    try testing.expectEqual(main.max_entries, model.entry_count);
    try testing.expect(model.scan_truncated);
}

test "folder expansion preserves root siblings when a deep subtree fills the cap" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a-large");
    for (0..main.max_entries) |index| {
        var name_buffer: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "a-large/file-{d:0>3}.txt", .{index});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "z-root-file.txt", .data = "" });

    var model = main.Model{};
    defer model.deinit();
    try main.scanOpenDirectory(&model, testing.io, testing.allocator, "/root-first", tmp.dir);

    try testing.expectEqual(@as(usize, 2), model.entry_count);
    try testing.expect(!model.scan_truncated);
    const large_index = model.findEntry("a-large").?;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .{ .toggle_entry = large_index }, &fx);
    try testing.expectEqual(large_index, model.pending_expand_entry.?);
    try testing.expect(!model.entries[large_index].expanded);
    var large_dir = try tmp.dir.openDir(testing.io, "a-large", .{ .iterate = true });
    defer large_dir.close(testing.io);
    try main.loadOpenDirectoryChildren(&model, testing.io, large_index, large_dir);
    model.pending_expand_entry = null;

    try testing.expectEqual(main.max_entries, model.entry_count);
    try testing.expect(model.scan_truncated);
    try testing.expect(model.findEntry("a-large") != null);
    try testing.expect(model.findEntry("z-root-file.txt") != null);
}

test "tree depth moves each row's icon and label together" {
    var model = try fixtureModel();
    defer model.deinit();
    const src_index = model.findEntry("src").?;
    model.entries[src_index].expanded = true;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    const root_row = findByRoleAndLabel(tree.root, .treeitem, "src").?;
    const nested_row = findByRoleAndLabel(tree.root, .treeitem, "main.zig").?;
    try testing.expectEqual(@as(usize, 3), root_row.children.len);
    try testing.expectEqual(@as(usize, 3), nested_row.children.len);
    try testing.expectEqual(canvas.WidgetKind.stack, root_row.children[0].kind);
    try testing.expectEqual(canvas.WidgetKind.icon, root_row.children[1].kind);
    try testing.expectEqual(canvas.WidgetKind.text, root_row.children[2].kind);

    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        tree.root,
        native_sdk.geometry.RectF.init(0, 0, main.window_width, main.window_height),
        &nodes,
    );
    const root_icon = layout.findById(root_row.children[1].id).?.frame;
    const nested_icon = layout.findById(nested_row.children[1].id).?.frame;
    const root_label = layout.findById(root_row.children[2].id).?.frame;
    const nested_label = layout.findById(nested_row.children[2].id).?.frame;
    const sidebar_frame = layout.findById(findByLabel(tree.root, "Code editor sidebar").?.id).?.frame;
    const tree_frame = layout.findById(findByLabel(tree.root, "Files and folders").?.id).?.frame;
    const root_row_frame = layout.findById(root_row.id).?.frame;
    try testing.expectApproxEqAbs(@as(f32, 6), root_row_frame.x - sidebar_frame.x, 0.01);
    try testing.expectApproxEqAbs(tree_frame.x, root_row_frame.x, 0.01);
    try testing.expectApproxEqAbs(sidebar_frame.maxX(), root_row_frame.maxX(), 0.01);
    try testing.expectApproxEqAbs(main.tree_depth_indent, nested_icon.x - root_icon.x, 0.01);
    try testing.expectApproxEqAbs(main.tree_depth_indent, nested_label.x - root_label.x, 0.01);
}

test "tree arrows select vertically and disclose horizontally" {
    var model = try fixtureModel();
    defer model.deinit();
    const src_index = model.findEntry("src").?;
    try testing.expect(!model.entries[src_index].expanded);

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tree = try buildTree(arena_state.allocator(), &model);
    var src_row = findByRoleAndLabel(tree.root, .treeitem, "src").?;

    const arrow_up = canvas.WidgetKeyboardEvent{
        .phase = .key_down,
        .key = "arrowup",
        .focus_moved = true,
    };
    main.update(&model, tree.msgForKeyboard(src_row.id, arrow_up).?, &fx);
    try testing.expectEqual(src_index, model.tree_selected_entry.?);
    try testing.expect(model.selected_entry == null);
    try testing.expect(!model.entries[src_index].expanded);

    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena_state.allocator(), &model);
    src_row = findByRoleAndLabel(tree.root, .treeitem, "src").?;
    const arrow_right = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowright" };
    main.update(&model, tree.msgForKeyboard(src_row.id, arrow_right).?, &fx);
    try testing.expect(model.entries[src_index].expanded);

    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena_state.allocator(), &model);
    src_row = findByRoleAndLabel(tree.root, .treeitem, "src").?;
    const arrow_down = canvas.WidgetKeyboardEvent{
        .phase = .key_down,
        .key = "arrowdown",
        .focus_moved = true,
    };
    main.update(&model, tree.msgForKeyboard(src_row.id, arrow_down).?, &fx);
    try testing.expect(model.entries[src_index].expanded);

    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena_state.allocator(), &model);
    src_row = findByRoleAndLabel(tree.root, .treeitem, "src").?;
    const arrow_left = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowleft" };
    main.update(&model, tree.msgForKeyboard(src_row.id, arrow_left).?, &fx);
    try testing.expect(!model.entries[src_index].expanded);
}

test "tree keyboard selection preserves the preview and Left selects a file's folder" {
    var model = try fixtureModel();
    defer model.deinit();
    const src_index = model.findEntry("src").?;
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const main_index = model.findEntry(main_path).?;
    const readme_index = model.findEntry("README.md").?;
    model.entries[src_index].expanded = true;
    model.preview_entry = readme_index;
    seedActiveDocument(&model, readme_index, "# Fixture\n");

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tree = try buildTree(arena_state.allocator(), &model);
    const main_row = findByRoleAndLabel(tree.root, .treeitem, "main.zig").?;
    try testing.expectEqual(@as(u16, 2), main_row.tree_level);

    // Up/Down focus movement dispatches the row's on-change selection,
    // not its pointer-only preview action.
    const moved = tree.msgForKeyboard(main_row.id, .{
        .phase = .key_down,
        .key = "arrowdown",
        .focus_moved = true,
    }).?;
    try testing.expectEqual(main.Msg{ .select_entry = main_index }, moved);
    main.update(&model, moved, &fx);
    try testing.expectEqual(main_index, model.tree_selected_entry.?);
    try testing.expectEqual(readme_index, model.selected_entry.?);
    try testing.expectEqual(readme_index, model.preview_entry.?);
    try testing.expectEqualStrings("# Fixture\n", model.preview());

    // The runtime's logical tree-level move routes Left to the parent row;
    // its focus-moved event selects that folder without changing the editor.
    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena_state.allocator(), &model);
    const src_row = findByRoleAndLabel(tree.root, .treeitem, "src").?;
    const parent_selected = tree.msgForKeyboard(src_row.id, .{
        .phase = .key_down,
        .key = "arrowleft",
        .focus_moved = true,
    }).?;
    try testing.expectEqual(main.Msg{ .select_entry = src_index }, parent_selected);
    main.update(&model, parent_selected, &fx);
    try testing.expectEqual(src_index, model.tree_selected_entry.?);
    try testing.expectEqual(readme_index, model.selected_entry.?);
}

test "Enter starts inline rename while Cmd+Down pins the tree file" {
    var model = try fixtureModel();
    defer model.deinit();
    const src_index = model.findEntry("src").?;
    model.entries[src_index].expanded = true;
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const main_index = model.findEntry(main_path).?;
    model.tree_selected_entry = main_index;

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tree = try buildTree(arena_state.allocator(), &model);
    const main_row = findByRoleAndLabel(tree.root, .treeitem, "main.zig").?;
    const enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    const begin = tree.msgForKeyboard(main_row.id, enter).?;
    try testing.expectEqual(main.Msg{ .begin_rename = main_index }, begin);
    main.update(&model, begin, &fx);
    try testing.expectEqualStrings("main.zig", model.renameText());

    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena_state.allocator(), &model);
    const rename_field = findByLabel(tree.root, "Rename item").?;
    try testing.expect(rename_field.autofocus);
    main.update(&model, tree.msgForTextEdit(rename_field.id, .clear).?, &fx);
    main.update(&model, tree.msgForTextEdit(rename_field.id, .{ .insert_text = "app.zig" }).?, &fx);
    try testing.expectEqualStrings("app.zig", model.renameText());
    main.update(&model, tree.msgForKeyboard(rename_field.id, enter).?, &fx);
    try testing.expectEqual(main_index, model.pending_rename_entry.?);

    // A fresh model keeps the primary chord out of inline rename and opens
    // the selected file as a persistent tab.
    var pin_model = try fixtureModel();
    defer pin_model.deinit();
    const pin_src = pin_model.findEntry("src").?;
    pin_model.entries[pin_src].expanded = true;
    const pin_index = pin_model.findEntry(main_path).?;
    pin_model.tree_selected_entry = pin_index;
    const command_down = canvas.WidgetKeyboardEvent{
        .phase = .key_down,
        .key = "arrowdown",
        .modifiers = .{ .super = true },
    };
    const command_enter = canvas.WidgetKeyboardEvent{
        .phase = .key_down,
        .key = "enter",
        .modifiers = .{ .super = true },
    };
    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena_state.allocator(), &pin_model);
    const pin_row = findByRoleAndLabel(tree.root, .treeitem, "main.zig").?;
    try testing.expect(tree.msgForKeyboard(pin_row.id, command_down) == null);
    try testing.expect(main.onKey(command_enter) == null);
    try testing.expectEqual(main.Msg.pin_tree_entry, main.onKey(command_down).?);
    main.update(&pin_model, main.onKey(command_down).?, &fx);
    try testing.expect(pin_model.isPinned(pin_index));
    try testing.expectEqual(pin_index, pin_model.selected_entry.?);
    try testing.expect(pin_model.preview_entry == null);
}

test "filesystem rename keeps directory descendants and open documents attached" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "README.md", .data = "# Fixture\n" });

    var root_storage: [256]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&root_storage, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var model = main.Model{};
    defer model.deinit();
    try main.scanFolder(&model, testing.io, testing.allocator, root_path);
    try main.loadDirectoryChildren(&model, testing.io, model.findEntry("src").?);
    const src_index = model.findEntry("src").?;
    const old_main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(old_main_path);
    const main_index = model.findEntry(old_main_path).?;
    model.entries[src_index].expanded = true;
    model.preview_entry = main_index;
    seedActiveDocument(&model, main_index, "pub fn main() void {}\n");

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .{ .begin_rename = src_index }, &fx);
    model.rename_buffer.set("lib");
    main.update(&model, .commit_rename, &fx);
    try testing.expectEqual(src_index, model.pending_rename_entry.?);
    main.performPendingRenameOnDisk(&model, testing.io);

    try tmp.dir.access(testing.io, "lib/main.zig", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "src/main.zig", .{}));
    const new_main_path = try std.fs.path.join(testing.allocator, &.{ "lib", "main.zig" });
    defer testing.allocator.free(new_main_path);
    const new_main_index = model.findEntry(new_main_path).?;
    try testing.expect(model.findEntry("src") == null);
    try testing.expect(model.findEntry("lib") != null);
    try testing.expectEqual(new_main_index, model.selected_entry.?);
    try testing.expectEqual(new_main_index, model.preview_entry.?);
    try testing.expectEqualStrings(new_main_path, model.selectedPath());
    try testing.expectEqualStrings("pub fn main() void {}\n", model.preview());
}

test "filesystem rename preserves a destination created after the folder scan" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "draft.zig", .data = "const draft = true;\n" });

    var root_storage: [256]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&root_storage, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var model = main.Model{};
    defer model.deinit();
    try main.scanFolder(&model, testing.io, testing.allocator, root_path);
    const entry_index = model.findEntry("draft.zig").?;

    // This file is absent from the scanned model, matching a destination
    // created by another process after the editor last observed the folder.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "final.zig", .data = "const final = true;\n" });

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .{ .begin_rename = entry_index }, &fx);
    model.rename_buffer.set("final.zig");
    main.update(&model, .commit_rename, &fx);
    main.performPendingRenameOnDisk(&model, testing.io);

    var destination: [64]u8 = undefined;
    const destination_contents = try tmp.dir.readFile(testing.io, "final.zig", &destination);
    try testing.expectEqualStrings("const final = true;\n", destination_contents);
    try tmp.dir.access(testing.io, "draft.zig", .{});
    try testing.expectEqualStrings("An item named final.zig already exists.", model.status());
}

test "filesystem rename permits a case-only spelling change" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Widget.zig", .data = "pub const widget = true;\n" });

    var root_storage: [256]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&root_storage, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var model = main.Model{};
    defer model.deinit();
    try main.scanFolder(&model, testing.io, testing.allocator, root_path);
    const entry_index = model.findEntry("Widget.zig").?;

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .{ .begin_rename = entry_index }, &fx);
    model.rename_buffer.set("widget.zig");
    main.update(&model, .commit_rename, &fx);
    main.performPendingRenameOnDisk(&model, testing.io);

    try tmp.dir.access(testing.io, "widget.zig", .{});
    try testing.expect(model.findEntry("Widget.zig") == null);
    try testing.expect(model.findEntry("widget.zig") != null);
}

test "selecting a folder preserves the active editor file" {
    var model = try fixtureModel();
    defer model.deinit();
    const src_index = model.findEntry("src").?;
    const file_index = model.findEntry("README.md").?;
    const source = "# Fixture\n";
    model.preview_entry = file_index;
    seedActiveDocument(&model, file_index, source);

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .{ .select_entry = src_index }, &fx);
    try testing.expectEqual(src_index, model.tree_selected_entry.?);
    try testing.expectEqual(file_index, model.selected_entry.?);
    try testing.expectEqualStrings(source, model.preview());
    try testing.expectEqualStrings("README.md", model.selectedPath());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    const folder = findByRoleAndLabel(tree.root, .treeitem, "src").?;
    const file = findByRoleAndLabel(tree.root, .treeitem, "README.md").?;
    const tab = findByRoleAndLabel(tree.root, .tab, "README.md").?;
    try testing.expect(folder.state.selected);
    try testing.expect(!file.state.selected);
    try testing.expect(tab.state.selected);
    try testing.expect(findByText(tree.root, .textarea, source) != null);
    try testing.expect(findByText(tree.root, .text, "This is a folder. Expand it or select a file.") == null);
}

test "folder scanning preserves the completed picker request and window state" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.zig", .data = "pub fn main() void {}\n" });

    var model = main.Model{
        .sidebar_fraction = 0.42,
        .chrome_leading = 71,
        .titlebar_height = 49,
        .picker_serial = 1,
        .next_file_key = 108,
    };
    try main.scanOpenDirectory(&model, testing.io, testing.allocator, "/chosen", tmp.dir);

    try testing.expectEqual(@as(u64, 1), model.picker_serial);
    try testing.expectEqual(@as(u64, 108), model.next_file_key);
    try testing.expectEqual(@as(f32, 0.42), model.sidebar_fraction);
    try testing.expectEqual(@as(f32, 71), model.chrome_leading);
    try testing.expectEqual(@as(f32, 49), model.titlebar_height);
    try testing.expectEqualStrings("/chosen", model.rootPath());
    try testing.expect(model.findEntry("main.zig") != null);
}

test "file selection issues a bounded read and adopts text, truncation, and binary outcomes" {
    var model = main.Model{};
    defer model.deinit();
    const root = "/fixture";
    @memcpy(model.root_storage[0..root.len], root);
    model.root_len = root.len;
    model.entry_count = 1;
    model.entries[0] = .{};
    const name = "main.zig";
    @memcpy(model.entries[0].name_storage[0..name.len], name);
    model.entries[0].name_len = name.len;
    @memcpy(model.entries[0].relative_storage[0..name.len], name);
    model.entries[0].relative_len = name.len;

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .{ .preview_entry = 0 }, &fx);
    try testing.expectEqual(main.PreviewState.loading, model.previewState());
    const request = fx.pendingFileAt(0).?;
    try testing.expectEqual(native_sdk.EffectFileOp.read, request.op);
    var expected_path_buffer: [64]u8 = undefined;
    const expected_path = try std.fmt.bufPrint(&expected_path_buffer, "{s}{c}{s}", .{ root, std.fs.path.sep, name });
    try testing.expectEqualStrings(expected_path, request.path);

    main.update(&model, .{ .file_done = .{
        .key = request.key,
        .op = .read,
        .outcome = .ok,
        .bytes = "const answer: u32 = 42;\n",
    } }, &fx);
    try testing.expectEqual(main.PreviewState.text, model.previewState());
    try testing.expectEqualStrings("const answer: u32 = 42;\n", model.preview());
    try testing.expect(!model.previewTruncated());

    model.documents[0].read_key = request.key + 1;
    main.update(&model, .{ .file_done = .{
        .key = request.key + 1,
        .op = .read,
        .outcome = .truncated,
        .bytes = "const clipped = true;\n",
    } }, &fx);
    try testing.expect(model.previewTruncated());

    model.documents[0].read_key = request.key + 2;
    main.update(&model, .{ .file_done = .{
        .key = request.key + 2,
        .op = .read,
        .outcome = .ok,
        .bytes = "png\x00bytes",
    } }, &fx);
    try testing.expectEqual(main.PreviewState.binary, model.previewState());
}

test "a truncated read ending inside UTF-8 remains a text preview" {
    var model = main.Model{};
    defer model.deinit();
    model.entry_count = 1;
    model.entries[0] = .{};
    const name = "unicode.txt";
    @memcpy(model.entries[0].name_storage[0..name.len], name);
    model.entries[0].name_len = name.len;
    @memcpy(model.entries[0].relative_storage[0..name.len], name);
    model.entries[0].relative_len = name.len;
    seedActiveDocument(&model, 0, "old");
    model.documents[0].read_key = 700;

    const bytes = try testing.allocator.alloc(u8, native_sdk.max_effect_file_bytes);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'a');
    bytes[bytes.len - 1] = 0xe2;

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .{ .file_done = .{
        .key = 700,
        .op = .read,
        .outcome = .truncated,
        .bytes = bytes,
    } }, &fx);

    try testing.expectEqual(main.PreviewState.text, model.previewState());
    try testing.expect(model.previewTruncated());
    try testing.expectEqual(main.max_preview_bytes, model.preview().len);
    try testing.expect(std.unicode.utf8ValidateSlice(model.preview()));

    bytes[bytes.len - 1] = 0xf5;
    model.documents[0].read_key = 701;
    main.update(&model, .{ .file_done = .{
        .key = 701,
        .op = .read,
        .outcome = .truncated,
        .bytes = bytes,
    } }, &fx);
    try testing.expectEqual(main.PreviewState.binary, model.previewState());
}

test "the largest source preview and bounded chrome fit retained text storage" {
    var model = main.Model{};
    defer model.deinit();
    const root = "/max";
    @memcpy(model.root_storage[0..root.len], root);
    model.root_len = root.len;
    model.entry_count = main.max_entries;
    for (model.entries[0..model.entry_count], 0..) |*entry, index| {
        entry.* = .{};
        @memset(&entry.name_storage, 'x');
        const prefix = try std.fmt.bufPrint(entry.name_storage[0..16], "file-{d:0>3}-", .{index});
        entry.name_len = main.max_name_bytes;
        @memcpy(entry.relative_storage[0..prefix.len], prefix);
        @memset(entry.relative_storage[prefix.len..main.max_name_bytes], 'x');
        entry.relative_len = main.max_name_bytes;
        entry.depth = 1;
    }
    for (0..main.max_open_tabs) |index| model.pinned_entries[index] = @intCast(index);
    model.pinned_count = main.max_open_tabs;
    model.preview_entry = main.max_open_tabs;

    const source = try testing.allocator.alloc(u8, main.max_preview_bytes);
    defer testing.allocator.free(source);
    @memset(source, 'x');
    seedActiveDocument(&model, 0, source);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(retainedWidgetTextBytes(tree.root) <= canvas.max_widget_text_bytes_per_view);
}

test "single-click previews replace each other while double-click pins persistent tabs" {
    var model = try fixtureModel();
    defer model.deinit();
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const util_path = try std.fs.path.join(testing.allocator, &.{ "src", "lib", "util.zig" });
    defer testing.allocator.free(util_path);
    const main_index = model.findEntry(main_path).?;
    const util_index = model.findEntry(util_path).?;
    const readme_index = model.findEntry("README.md").?;

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.update(&model, .{ .preview_entry = main_index }, &fx);
    var tabs = model.openTabs(arena);
    try testing.expectEqual(@as(usize, 1), tabs.len);
    try testing.expectEqualStrings("main.zig", tabs[0].name);
    try testing.expect(tabs[0].preview);
    try testing.expect(tabs[0].selected);
    try testing.expect(tabs[0].show_close);

    // Another single click replaces the one transient preview tab.
    main.update(&model, .{ .preview_entry = util_index }, &fx);
    _ = arena_state.reset(.retain_capacity);
    tabs = model.openTabs(arena);
    try testing.expectEqual(@as(usize, 1), tabs.len);
    try testing.expectEqualStrings("util.zig", tabs[0].name);
    try testing.expect(tabs[0].preview);

    // The second release of a double click on the preview tab pins that
    // preview in place, just like double-clicking its tree row.
    _ = arena_state.reset(.retain_capacity);
    var tree = try buildTree(arena, &model);
    const util_preview = findByRoleAndLabel(tree.root, .tab, "util.zig").?;
    const pin_message = tree.msgForPointerClick(util_preview.id, .up, 2).?;
    try testing.expectEqual(main.Msg{ .pin_entry = util_index }, pin_message);
    main.update(&model, pin_message, &fx);
    _ = arena_state.reset(.retain_capacity);
    tabs = model.openTabs(arena);
    try testing.expectEqual(@as(usize, 1), tabs.len);
    try testing.expectEqualStrings("util.zig", tabs[0].name);
    try testing.expect(!tabs[0].preview);
    try testing.expect(model.isPinned(util_index));

    // A later single click adds a new transient preview without replacing
    // the pinned tab, and clicking the pinned tab activates it again.
    main.update(&model, .{ .preview_entry = readme_index }, &fx);
    _ = arena_state.reset(.retain_capacity);
    tabs = model.openTabs(arena);
    try testing.expectEqual(@as(usize, 2), tabs.len);
    try testing.expectEqualStrings("util.zig", tabs[0].name);
    try testing.expect(!tabs[0].preview);
    try testing.expectEqualStrings("README.md", tabs[1].name);
    try testing.expect(tabs[1].preview);
    try testing.expect(tabs[1].selected);
    try testing.expect(!tabs[0].show_close);
    try testing.expect(tabs[1].show_close);

    // The active tab always owns a close button. An inactive tab adds its
    // close button only for the duration of its hover containment.
    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena, &model);
    const active_preview = findByRoleAndLabel(tree.root, .tab, "README.md").?;
    try testing.expect(findByLabel(active_preview, "Close tab") != null);
    const inactive_util = findByRoleAndLabel(tree.root, .tab, "util.zig").?;
    try testing.expect(findByLabel(inactive_util, "Close tab") == null);
    try testing.expectEqual(active_preview.style.background.?, inactive_util.style.background.?);
    try testing.expectEqual(canvas.WidgetKind.stack, active_preview.kind);
    try testing.expectEqual(canvas.WidgetKind.stack, inactive_util.kind);
    try testing.expectEqual(@as(usize, 2), inactive_util.children.len);
    const inactive_baseline_layer = inactive_util.children[1];
    try testing.expectEqual(canvas.WidgetKind.column, inactive_baseline_layer.kind);
    try testing.expectEqual(canvas.WidgetKind.separator, inactive_baseline_layer.children[1].kind);

    var tab_nodes: [256]canvas.WidgetLayoutNode = undefined;
    const tab_layout = try canvas.layoutWidgetTree(
        tree.root,
        native_sdk.geometry.RectF.init(0, 0, main.window_width, main.window_height),
        &tab_nodes,
    );
    const active_frame = tab_layout.findById(active_preview.id).?.frame;
    const inactive_frame = tab_layout.findById(inactive_util.id).?.frame;
    try testing.expectEqual(active_frame.height, inactive_frame.height);
    try testing.expectEqual(main.editor_tab_width, active_frame.width);
    try testing.expectEqual(main.editor_tab_width, inactive_frame.width);
    const inactive_baseline_frame = tab_layout.findById(inactive_baseline_layer.children[1].id).?.frame;
    try testing.expectEqual(inactive_frame.width, inactive_baseline_frame.width);
    try testing.expectEqual(inactive_frame.maxY(), inactive_baseline_frame.maxY());
    const active_label = findByText(active_preview, .text, "README.md").?;
    const inactive_label = findByText(inactive_util, .text, "util.zig").?;
    try testing.expectEqual(
        tab_layout.findById(active_label.id).?.frame.y,
        tab_layout.findById(inactive_label.id).?.frame.y,
    );

    const hover_message = tree.msgFor(inactive_util.id, .hover_enter).?;
    try testing.expectEqual(main.Msg{ .hover_tab = util_index }, hover_message);
    main.update(&model, hover_message, &fx);

    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena, &model);
    const hovered_util = findByRoleAndLabel(tree.root, .tab, "util.zig").?;
    const hovered_close = findByLabel(hovered_util, "Close tab").?;
    try testing.expectEqual(
        main.Msg{ .close_tab = util_index },
        tree.msgForPointer(hovered_close.id, .up).?,
    );
    const unhover_message = tree.msgFor(hovered_util.id, .hover_leave).?;
    try testing.expectEqual(main.Msg{ .unhover_tab = util_index }, unhover_message);
    main.update(&model, unhover_message, &fx);
    try testing.expect(model.hovered_tab == null);

    main.update(&model, .{ .activate_tab = util_index }, &fx);
    _ = arena_state.reset(.retain_capacity);
    tabs = model.openTabs(arena);
    try testing.expect(tabs[0].selected);
    try testing.expect(!tabs[1].selected);
}

test "switching tabs keeps pinned file reads alive" {
    var model = try fixtureModel();
    defer model.deinit();
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const main_index = model.findEntry(main_path).?;
    const readme_index = model.findEntry("README.md").?;

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .{ .preview_entry = main_index }, &fx);
    const main_read_key = model.documents[0].read_key;
    main.update(&model, .{ .pin_entry = main_index }, &fx);
    main.update(&model, .{ .preview_entry = readme_index }, &fx);

    try testing.expectEqual(@as(usize, 2), fx.pendingFileCount());
    try testing.expectEqual(main_index, model.documents[0].entry_index.?);
    try testing.expectEqual(main_read_key, model.documents[0].read_key);
    try testing.expectEqual(main.PreviewState.loading, model.documents[0].state);

    main.update(&model, .{ .file_done = .{
        .key = main_read_key,
        .op = .read,
        .outcome = .ok,
        .bytes = "pub fn main() void {}\n",
    } }, &fx);
    try testing.expectEqual(main.PreviewState.text, model.documents[0].state);
    try testing.expectEqualStrings("pub fn main() void {}\n", model.documents[0].editor.text());
}

test "tab strip keeps a stable runtime-owned horizontal offset" {
    var model = try fixtureModel();
    defer model.deinit();
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const util_path = try std.fs.path.join(testing.allocator, &.{ "src", "lib", "util.zig" });
    defer testing.allocator.free(util_path);
    const main_index = model.findEntry(main_path).?;
    const util_index = model.findEntry(util_path).?;
    const readme_index = model.findEntry("README.md").?;

    model.pinned_entries[0] = main_index;
    model.pinned_entries[1] = util_index;
    model.pinned_count = 2;
    model.preview_entry = readme_index;
    seedActiveDocument(&model, readme_index, "# Fixture\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    const strip = findByLabel(tree.root, "Open file tabs").?;
    try testing.expectEqual(@as(f32, 0), strip.value_x);

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .{ .activate_tab = util_index }, &fx);
    _ = arena_state.reset(.retain_capacity);
    const switched = try buildTree(arena_state.allocator(), &model);
    const switched_strip = findByLabel(switched.root, "Open file tabs").?;
    try testing.expectEqual(strip.id, switched_strip.id);
    try testing.expectEqual(@as(f32, 0), switched_strip.value_x);
}

test "previous and next tab commands cycle the open tab order with wrapping" {
    var model = try fixtureModel();
    defer model.deinit();
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const util_path = try std.fs.path.join(testing.allocator, &.{ "src", "lib", "util.zig" });
    defer testing.allocator.free(util_path);
    const main_index = model.findEntry(main_path).?;
    const util_index = model.findEntry(util_path).?;
    const readme_index = model.findEntry("README.md").?;

    model.pinned_entries[0] = main_index;
    model.pinned_entries[1] = util_index;
    model.pinned_count = 2;
    model.preview_entry = readme_index;
    model.selected_entry = util_index;
    appendDocument(&model, main_index, "pub fn main() void {}\n");
    appendDocument(&model, util_index, "pub const answer = 42;\n");
    appendDocument(&model, readme_index, "# Fixture\n");

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .next_tab, &fx);
    try testing.expectEqual(readme_index, model.selected_entry.?);
    main.update(&model, .next_tab, &fx);
    try testing.expectEqual(main_index, model.selected_entry.?);
    main.update(&model, .previous_tab, &fx);
    try testing.expectEqual(readme_index, model.selected_entry.?);

    model.selected_entry = null;
    main.update(&model, .next_tab, &fx);
    try testing.expectEqual(main_index, model.selected_entry.?);
    model.selected_entry = null;
    main.update(&model, .previous_tab, &fx);
    try testing.expectEqual(readme_index, model.selected_entry.?);
}

test "editing pins the preview and repeated saves serialize the latest snapshot" {
    var model = try fixtureModel();
    defer model.deinit();
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const main_index = model.findEntry(main_path).?;
    const source = "pub fn main() void {}\n";
    model.preview_entry = main_index;
    seedActiveDocument(&model, main_index, source);

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .{ .edit_code = .{ .insert_text = "// edit\n" } }, &fx);
    try testing.expect(model.selectedDirty());
    try testing.expect(model.isPinned(main_index));
    try testing.expect(model.preview_entry == null);
    try testing.expectEqualStrings("pub fn main() void {}\n// edit\n", model.preview());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tabs = model.openTabs(arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), tabs.len);
    try testing.expect(tabs[0].dirty);
    try testing.expect(!tabs[0].preview);
    const dirty_tree = try buildTree(arena_state.allocator(), &model);
    const dirty_titlebar = findByLabel(dirty_tree.root, "Code editor titlebar").?;
    const active_save = findByLabel(dirty_titlebar, "Save").?;
    try testing.expectEqual(canvas.WidgetKind.button, active_save.kind);
    try testing.expect(!active_save.state.disabled);
    try testing.expectEqual(main.Msg.save_file, dirty_tree.msgForPointer(active_save.id, .up).?);

    main.update(&model, .save_file, &fx);
    const first_save_key = model.documents[0].save_key;
    const request = fx.pendingFileAt(0).?;
    try testing.expectEqual(native_sdk.EffectFileOp.write, request.op);
    try testing.expectEqual(first_save_key, request.key);
    try testing.expectEqualStrings(model.preview(), request.bytes);

    // A second save while the first write is live queues the latest
    // snapshot without trying to cancel a disk operation already in flight.
    main.update(&model, .{ .edit_code = .{ .insert_text = "// newer\n" } }, &fx);
    main.update(&model, .save_file, &fx);
    try testing.expectEqual(first_save_key, model.documents[0].save_key);
    try testing.expect(model.documents[0].save_queued);
    try testing.expectEqual(@as(usize, 1), fx.pendingFileCount());

    main.update(&model, .{ .file_done = .{
        .key = first_save_key,
        .op = .write,
        .outcome = .ok,
        .bytes = "",
    } }, &fx);
    try testing.expect(model.selectedDirty());
    const second_save_key = model.documents[0].save_key;
    try testing.expect(second_save_key != 0 and second_save_key != first_save_key);
    try testing.expect(!model.documents[0].save_queued);
    try testing.expectEqualStrings(model.preview(), fx.pendingFileAt(1).?.bytes);
    main.update(&model, .{ .file_done = .{
        .key = second_save_key,
        .op = .write,
        .outcome = .ok,
        .bytes = "",
    } }, &fx);
    try testing.expect(!model.selectedDirty());
    _ = arena_state.reset(.retain_capacity);
    tabs = model.openTabs(arena_state.allocator());
    try testing.expect(!tabs[0].dirty);
}

test "an in-flight save keeps its document and folder session alive" {
    var model = try fixtureModel();
    defer model.deinit();
    const entry_index = model.findEntry("README.md").?;
    const source = "# Fixture\n";
    model.pinned_entries[0] = entry_index;
    model.pinned_count = 1;
    seedActiveDocument(&model, entry_index, source);

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .{ .edit_code = .{ .insert_text = "draft\n" } }, &fx);
    main.update(&model, .save_file, &fx);
    try testing.expect(model.documents[0].save_key != 0);

    // Returning the editor to its previous snapshot makes dirty() false,
    // but the non-interruptible write still owns this document until its
    // acknowledgement arrives.
    model.documents[0].editor.set(source);
    try testing.expect(!model.documents[0].dirty());
    main.update(&model, .{ .close_tab = entry_index }, &fx);
    try testing.expect(model.isPinned(entry_index));
    try testing.expectEqual(@as(usize, 1), model.document_count);
    try testing.expect(std.mem.startsWith(u8, model.status(), "Wait for README.md"));

    main.update(&model, .open_folder, &fx);
    try testing.expectEqual(@as(u64, 0), model.picker_serial);
    try testing.expectEqualStrings("Wait for file saves before opening another folder.", model.status());

    var replacement = testing.tmpDir(.{ .iterate = true });
    defer replacement.cleanup();
    try testing.expectError(
        error.FileActivityPending,
        main.scanOpenDirectory(&model, testing.io, testing.allocator, "/replacement", replacement.dir),
    );
}

test "tab close actions select a neighbor, close others, and preserve dirty documents" {
    var model = try fixtureModel();
    defer model.deinit();
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const util_path = try std.fs.path.join(testing.allocator, &.{ "src", "lib", "util.zig" });
    defer testing.allocator.free(util_path);
    const main_index = model.findEntry(main_path).?;
    const util_index = model.findEntry(util_path).?;
    const readme_index = model.findEntry("README.md").?;

    model.pinned_entries[0] = main_index;
    model.pinned_entries[1] = util_index;
    model.pinned_count = 2;
    model.preview_entry = readme_index;
    model.selected_entry = util_index;
    appendDocument(&model, main_index, "pub fn main() void {}\n");
    appendDocument(&model, util_index, "pub const answer = 42;\n");
    appendDocument(&model, readme_index, "# Fixture\n");

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Cmd+W closes the selected middle tab and activates its right-hand neighbor.
    main.update(&model, .close_active_tab, &fx);
    try testing.expect(!model.isPinned(util_index));
    try testing.expectEqual(readme_index, model.selected_entry.?);
    try testing.expectEqual(@as(usize, 2), model.document_count);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tabs = model.openTabs(arena_state.allocator());
    try testing.expectEqual(@as(usize, 2), tabs.len);
    try testing.expectEqualStrings("main.zig", tabs[0].name);
    try testing.expectEqualStrings("README.md", tabs[1].name);
    try testing.expect(!tabs[0].only_tab);

    // Close Others keeps the invoked tab even when it was not selected.
    main.update(&model, .{ .close_other_tabs = main_index }, &fx);
    try testing.expectEqual(@as(usize, 1), model.pinned_count);
    try testing.expectEqual(main_index, model.pinned_entries[0]);
    try testing.expect(model.preview_entry == null);
    try testing.expectEqual(main_index, model.selected_entry.?);
    try testing.expectEqual(@as(usize, 1), model.document_count);
    _ = arena_state.reset(.retain_capacity);
    tabs = model.openTabs(arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), tabs.len);
    try testing.expect(tabs[0].only_tab);

    // Neither action silently discards a dirty document.
    model.pinned_entries[1] = util_index;
    model.pinned_count = 2;
    appendDocument(&model, util_index, "pub const answer = 42;\n");
    model.documents[1].editor.apply(.{ .insert_text = "// unsaved\n" });
    main.update(&model, .{ .close_tab = util_index }, &fx);
    try testing.expect(model.isPinned(util_index));
    try testing.expectEqual(@as(usize, 2), model.document_count);
    main.update(&model, .{ .close_other_tabs = main_index }, &fx);
    try testing.expectEqual(@as(usize, 2), model.pinned_count);
    try testing.expect(std.mem.indexOf(u8, model.status(), "Save util.zig") != null);
}

test "editor and window commands have standard primary shortcuts" {
    for (main.app_shortcuts) |shortcut| {
        try native_sdk.platform.validateShortcut(shortcut);
    }

    try testing.expectEqual(@as(usize, 6), main.app_shortcuts.len);
    try testing.expectEqualStrings("close-tab", main.app_shortcuts[1].id);
    try testing.expectEqualStrings("w", main.app_shortcuts[1].key);
    try testing.expect(main.app_shortcuts[1].modifiers.primary);
    try testing.expectEqualStrings("open-folder", main.app_shortcuts[2].id);
    try testing.expectEqualStrings("o", main.app_shortcuts[2].key);
    try testing.expect(main.app_shortcuts[2].modifiers.primary);
    try testing.expectEqualStrings("new-window", main.app_shortcuts[3].id);
    try testing.expectEqualStrings("n", main.app_shortcuts[3].key);
    try testing.expect(main.app_shortcuts[3].modifiers.primary);
    try testing.expectEqualStrings("previous-tab", main.app_shortcuts[4].id);
    try testing.expectEqualStrings("[", main.app_shortcuts[4].key);
    try testing.expect(main.app_shortcuts[4].modifiers.primary);
    try testing.expect(main.app_shortcuts[4].modifiers.shift);
    try testing.expectEqualStrings("next-tab", main.app_shortcuts[5].id);
    try testing.expectEqualStrings("]", main.app_shortcuts[5].key);
    try testing.expect(main.app_shortcuts[5].modifiers.primary);
    try testing.expect(main.app_shortcuts[5].modifiers.shift);
    try testing.expectEqual(main.Msg.close_active_tab, main.onCommand("close-tab").?);
    try testing.expectEqual(main.Msg.save_file, main.onCommand("save-file").?);
    try testing.expectEqual(main.Msg.open_folder, main.onCommand("open-folder").?);
    try testing.expectEqual(main.Msg.new_window, main.onCommand("new-window").?);
    try testing.expectEqual(main.Msg.previous_tab, main.onCommand("previous-tab").?);
    try testing.expectEqual(main.Msg.next_tab, main.onCommand("next-tab").?);
    try testing.expect(main.onCommand("unknown") == null);
}

test "Cmd+W closes a tab first and closes the focused window when no tabs remain" {
    var app_model = main.AppModel{};
    app_model.init();
    defer app_model.deinit();

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // The scene-owned main window asks the host wrapper to close it when
    // its browser has no tabs.
    main.appUpdate(&app_model, .close_active_tab, &fx);
    try testing.expect(app_model.pending_close_main);
    try testing.expect(app_model.sessions[0].open);

    // With a tab present, the same command closes only that tab.
    app_model.pending_close_main = false;
    var browser = &app_model.sessions[0].browser;
    browser.entry_count = 1;
    browser.entries[0] = .{};
    browser.pinned_entries[0] = 0;
    browser.pinned_count = 1;
    browser.selected_entry = 0;
    main.appUpdate(&app_model, .close_active_tab, &fx);
    try testing.expect(!app_model.pending_close_main);
    try testing.expect(!browser.hasOpenTabs());
    try testing.expect(app_model.sessions[0].open);

    // An empty model-declared window disappears from the declaration set,
    // leaving the main browser alive.
    main.appUpdate(&app_model, .new_window, &fx);
    try testing.expect(app_model.sessions[1].open);
    try testing.expectEqual(@as(u8, 1), app_model.active_session);
    main.appUpdate(&app_model, .close_active_tab, &fx);
    try testing.expect(!app_model.sessions[1].open);
    try testing.expectEqual(@as(u8, 0), app_model.active_session);
    try testing.expect(app_model.pending_focus_session == null);

    var scratch = main.BrowserUiApp.WindowsScratch{};
    try testing.expectEqual(@as(usize, 0), main.editorWindows(&app_model, &scratch).len);
}

test "new windows own independent folders and opening again replaces only the active one" {
    var app_model = main.AppModel{};
    app_model.init();
    defer app_model.deinit();

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const first_root = "/first";
    @memcpy(app_model.sessions[0].browser.root_storage[0..first_root.len], first_root);
    app_model.sessions[0].browser.root_len = first_root.len;

    main.appUpdate(&app_model, .new_window, &fx);
    try testing.expectEqual(@as(u8, 1), app_model.active_session);
    try testing.expectEqual(@as(?u8, 1), app_model.pending_focus_session);
    try testing.expect(app_model.sessions[1].open);
    try testing.expect(
        app_model.sessions[0].browser.next_file_key !=
            app_model.sessions[1].browser.next_file_key,
    );

    var scratch = main.BrowserUiApp.WindowsScratch{};
    const windows = main.editorWindows(&app_model, &scratch);
    try testing.expectEqual(@as(usize, 1), windows.len);
    try testing.expectEqualStrings("code-editor-2", windows[0].label);
    try testing.expectEqual(main.Msg{ .close_window = 1 }, windows[0].on_close.?);

    // Cmd+O targets the active session. A second scan replaces that
    // session's folder-scoped model while the main window remains intact.
    main.appUpdate(&app_model, .open_folder, &fx);
    try testing.expectEqual(@as(u64, 1), app_model.sessions[1].browser.picker_serial);
    try testing.expectEqual(@as(u64, 0), app_model.sessions[0].browser.picker_serial);

    var first = testing.tmpDir(.{ .iterate = true });
    defer first.cleanup();
    try first.dir.writeFile(testing.io, .{ .sub_path = "one.zig", .data = "const one = 1;\n" });
    try main.scanOpenDirectory(
        &app_model.sessions[1].browser,
        testing.io,
        testing.allocator,
        "/second",
        first.dir,
    );
    try testing.expectEqualStrings("/second", app_model.sessions[1].browser.rootPath());

    var replacement = testing.tmpDir(.{ .iterate = true });
    defer replacement.cleanup();
    try replacement.dir.writeFile(testing.io, .{ .sub_path = "two.zig", .data = "const two = 2;\n" });
    try main.scanOpenDirectory(
        &app_model.sessions[1].browser,
        testing.io,
        testing.allocator,
        "/replacement",
        replacement.dir,
    );
    try testing.expectEqualStrings("/replacement", app_model.sessions[1].browser.rootPath());
    try testing.expect(app_model.sessions[1].browser.findEntry("one.zig") == null);
    try testing.expect(app_model.sessions[1].browser.findEntry("two.zig") != null);
    try testing.expectEqualStrings("/first", app_model.sessions[0].browser.rootPath());

    main.appUpdate(&app_model, .{ .close_window = 1 }, &fx);
    try testing.expect(!app_model.sessions[1].open);
    try testing.expectEqual(@as(usize, 0), main.editorWindows(&app_model, &scratch).len);
}

test "dirty documents block folder replacement and secondary window teardown" {
    var app_model = main.AppModel{};
    app_model.init();
    defer app_model.deinit();

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.appUpdate(&app_model, .new_window, &fx);
    var browser = &app_model.sessions[1].browser;
    browser.entry_count = 1;
    browser.entries[0] = .{};
    seedActiveDocument(browser, 0, "saved\n");
    browser.documents[0].editor.apply(.{ .insert_text = "dirty\n" });
    try testing.expect(browser.hasDirtyDocuments());

    main.appUpdate(&app_model, .open_folder, &fx);
    try testing.expectEqual(@as(u64, 0), browser.picker_serial);
    try testing.expectEqualStrings("Save all files before opening another folder.", browser.status());

    var replacement = testing.tmpDir(.{ .iterate = true });
    defer replacement.cleanup();
    try replacement.dir.writeFile(testing.io, .{ .sub_path = "replacement.zig", .data = "const replacement = true;\n" });
    try testing.expectError(
        error.UnsavedChanges,
        main.scanOpenDirectory(browser, testing.io, testing.allocator, "/replacement", replacement.dir),
    );
    try testing.expectEqualStrings("saved\ndirty\n", browser.preview());

    main.appUpdate(&app_model, .{ .close_window = 1 }, &fx);
    try testing.expect(app_model.sessions[1].open);
    try testing.expectEqualStrings("Save all files before closing this window.", browser.status());
}

test "reopened window sessions never reuse in-flight file effect keys" {
    var app_model = main.AppModel{};
    app_model.init();
    defer app_model.deinit();

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.appUpdate(&app_model, .new_window, &fx);
    var browser = &app_model.sessions[1].browser;
    const old_root = "/old";
    @memcpy(browser.root_storage[0..old_root.len], old_root);
    browser.root_len = old_root.len;
    browser.entry_count = 1;
    browser.entries[0] = .{};
    const old_name = "old.zig";
    @memcpy(browser.entries[0].name_storage[0..old_name.len], old_name);
    browser.entries[0].name_len = old_name.len;
    @memcpy(browser.entries[0].relative_storage[0..old_name.len], old_name);
    browser.entries[0].relative_len = old_name.len;
    main.appUpdate(&app_model, .{ .preview_entry = 0 }, &fx);
    const old_key = browser.documents[0].read_key;

    main.appUpdate(&app_model, .{ .close_window = 1 }, &fx);
    main.appUpdate(&app_model, .new_window, &fx);
    browser = &app_model.sessions[1].browser;
    const new_root = "/new";
    @memcpy(browser.root_storage[0..new_root.len], new_root);
    browser.root_len = new_root.len;
    browser.entry_count = 1;
    browser.entries[0] = .{};
    const new_name = "new.zig";
    @memcpy(browser.entries[0].name_storage[0..new_name.len], new_name);
    browser.entries[0].name_len = new_name.len;
    @memcpy(browser.entries[0].relative_storage[0..new_name.len], new_name);
    browser.entries[0].relative_len = new_name.len;
    main.appUpdate(&app_model, .{ .preview_entry = 0 }, &fx);
    const new_key = browser.documents[0].read_key;

    try testing.expect(new_key > old_key);
    try testing.expectEqual(@as(usize, 2), fx.pendingFileCount());
    main.appUpdate(&app_model, .{ .file_done = .{
        .key = old_key,
        .op = .read,
        .outcome = .ok,
        .bytes = "stale bytes from the closed window\n",
    } }, &fx);
    try testing.expectEqual(main.PreviewState.loading, browser.documents[0].state);
    try testing.expectEqualStrings("", browser.documents[0].editor.text());
}

test "the empty and loaded views expose the picker, tree, and highlighted code surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.Model{};
    defer model.deinit();
    var tree = try buildTree(arena_state.allocator(), &model);
    const empty_titlebar = findByLabel(tree.root, "Code editor titlebar").?;
    _ = findByText(empty_titlebar, .text, "Code Explorer").?;
    const open_button = findByText(tree.root, .button, "Open Folder…").?;
    try testing.expectEqual(main.Msg.open_folder, tree.msgForPointer(open_button.id, .up).?);
    try testing.expectEqual(@as(usize, 0), countRole(tree.root, .treeitem));

    model = try fixtureModel();
    const src_index = model.findEntry("src").?;
    model.entries[src_index].expanded = true;
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const selected_index = model.findEntry(main_path).?;
    model.preview_entry = selected_index;
    const selected = &model.entries[selected_index];
    const tsx_name = "main.tsx";
    @memcpy(selected.name_storage[0..tsx_name.len], tsx_name);
    selected.name_len = tsx_name.len;
    const tsx_path = "src/main.tsx";
    @memcpy(selected.relative_storage[0..tsx_path.len], tsx_path);
    selected.relative_len = tsx_path.len;
    const source = "export default function RootLayout() { return <main />; }\n";
    seedActiveDocument(&model, selected_index, source);
    try testing.expectEqual(native_sdk.code.Language.tsx, model.previewLanguage());

    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena_state.allocator(), &model);
    try testing.expectEqual(@as(usize, 6), countRole(tree.root, .treeitem));
    const directory_row = findByRoleAndLabel(tree.root, .treeitem, "src").?;
    const file_row = findByRoleAndLabel(tree.root, .treeitem, tsx_name).?;
    try testing.expectEqual(tree.root.style.background.?, directory_row.style.focus_ring.?);
    try testing.expectEqual(tree.root.style.background.?, file_row.style.focus_ring.?);
    try testing.expect(findByText(tree.root, .text, "FILES · 7") == null);
    try testing.expect(findByText(tree.root, .button, "Change Folder") == null);
    const titlebar = findByLabel(tree.root, "Code editor titlebar").?;
    const sidebar = findByLabel(tree.root, "Code editor sidebar").?;
    const tab_strip = findByLabel(tree.root, "Editor tab strip").?;
    try testing.expect(titlebar.window_drag);
    try testing.expectEqual(tree.root.style.background.?, titlebar.style.background.?);
    try testing.expectEqual(tree.root.style.background.?, sidebar.style.background.?);
    try testing.expectEqual(tree.root.style.background.?, tab_strip.style.background.?);
    const centered_folder = findByText(titlebar, .text, "fixture").?;
    const save_button = findByLabel(titlebar, "Save").?;
    try testing.expect(findByText(titlebar, .text, "/fixture") == null);
    try testing.expectEqual(canvas.TextAlign.center, centered_folder.text_alignment);
    try testing.expectEqualStrings("", save_button.text);
    try testing.expectEqual(canvas.WidgetVariant.ghost, save_button.variant);
    try testing.expect(save_button.state.disabled);
    try testing.expect(tree.msgForPointer(save_button.id, .up) == null);
    try testing.expect(findByLabel(tree.root, "Save").?.id == save_button.id);

    var titlebar_nodes: [256]canvas.WidgetLayoutNode = undefined;
    const titlebar_layout = try canvas.layoutWidgetTree(
        tree.root,
        native_sdk.geometry.RectF.init(0, 0, main.window_width, main.window_height),
        &titlebar_nodes,
    );
    const folder_frame = titlebar_layout.findById(centered_folder.id).?.frame;
    const save_frame = titlebar_layout.findById(save_button.id).?.frame;
    try testing.expectApproxEqAbs(
        main.window_width * 0.5,
        folder_frame.x + folder_frame.width * 0.5,
        0.01,
    );
    try testing.expect(
        save_frame.x + save_frame.width * 0.5 >
            folder_frame.x + folder_frame.width * 0.5,
    );

    const editor = findByText(tree.root, .textarea, source).?;
    try testing.expect(editor.runtime_flags.code_editor);
    try testing.expectEqual(@as(usize, 1), editor.spans.len);
    try testing.expectEqual(native_sdk.code.Language.tsx, editor.code_language);
    try testing.expectEqual(native_sdk.geometry.InsetsF{}, editor.layout.padding);
    try testing.expect(editor.style.background == null);
    try testing.expect(editor.style.border == null);
    try testing.expect(editor.style.radius == null);
    try testing.expect(tree.msgForTextEdit(editor.id, .{ .insert_text = "x" }) != null);

    const preview_tab = findByRoleAndLabel(tree.root, .tab, tsx_name).?;
    try testing.expect(preview_tab.state.selected);
    try testing.expectEqual(main.Msg{ .activate_tab = model.selected_entry.? }, tree.msgForPointer(preview_tab.id, .up).?);
    try testing.expectEqual(canvas.WidgetKind.stack, preview_tab.kind);
    try testing.expect(preview_tab.style.background != null);
    try testing.expect(preview_tab.style.radius == null);
    try testing.expectEqual(canvas.WidgetKind.stack, tab_strip.kind);
    try testing.expectEqual(@as(usize, 2), tab_strip.children.len);
    const baseline_layer = tab_strip.children[0];
    try testing.expectEqual(canvas.WidgetKind.column, baseline_layer.kind);
    try testing.expectEqual(@as(usize, 2), baseline_layer.children.len);
    const tab_baseline = baseline_layer.children[1];
    try testing.expectEqual(canvas.WidgetKind.separator, tab_baseline.kind);
    const tab_strip_frame = titlebar_layout.findById(tab_strip.id).?.frame;
    const preview_tab_frame = titlebar_layout.findById(preview_tab.id).?.frame;
    const tab_baseline_frame = titlebar_layout.findById(tab_baseline.id).?.frame;
    try testing.expectEqual(@as(f32, 37), tab_strip_frame.height);
    try testing.expectEqual(tab_strip_frame.maxY(), preview_tab_frame.maxY());
    try testing.expectEqual(tab_strip_frame.maxY(), tab_baseline_frame.maxY());
    const preview_label = findByText(preview_tab, .text, tsx_name).?;
    try testing.expectEqual(@as(usize, 1), preview_label.spans.len);
    try testing.expect(preview_label.spans[0].italic);
    const tab_icon = findByKind(preview_tab, .icon).?;
    try testing.expectEqualStrings("file-text", tab_icon.text);
    try testing.expectEqual(@as(usize, 2), preview_tab.context_menu.len);
    try testing.expectEqualStrings("Close", preview_tab.context_menu[0].label);
    try testing.expectEqualStrings("Close Others", preview_tab.context_menu[1].label);
    try testing.expect(!preview_tab.context_menu[1].enabled);
    try testing.expectEqual(
        main.Msg{ .close_tab = model.selected_entry.? },
        tree.msgForContextMenu(preview_tab.id, 0).?,
    );
    try testing.expectEqual(
        main.Msg{ .close_other_tabs = model.selected_entry.? },
        tree.msgForContextMenu(preview_tab.id, 1).?,
    );

    // Pinning converts the same tab to the persistent, non-italic style.
    model.pinned_entries[0] = model.selected_entry.?;
    model.pinned_count = 1;
    model.preview_entry = null;
    _ = arena_state.reset(.retain_capacity);
    tree = try buildTree(arena_state.allocator(), &model);
    const pinned_tab = findByRoleAndLabel(tree.root, .tab, tsx_name).?;
    const pinned_label = findByText(pinned_tab, .text, tsx_name).?;
    try testing.expectEqual(@as(usize, 0), pinned_label.spans.len);
}

test "the editor accepts a ten-thousand-line source without truncation" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..10_000) |_| {
        try source.appendSlice(testing.allocator, "const x = 1;\n");
    }
    try testing.expect(source.items.len < main.max_preview_bytes);

    var model = main.Model{};
    defer model.deinit();
    const root = "/fixture";
    @memcpy(model.root_storage[0..root.len], root);
    model.root_len = root.len;
    model.entry_count = 1;
    model.entries[0] = .{};
    const name = "large.zig";
    @memcpy(model.entries[0].name_storage[0..name.len], name);
    model.entries[0].name_len = name.len;
    @memcpy(model.entries[0].relative_storage[0..name.len], name);
    model.entries[0].relative_len = name.len;
    model.preview_entry = 0;
    seedActiveDocument(&model, 0, source.items);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    const editor = findByText(tree.root, .textarea, source.items).?;
    try testing.expectEqual(source.items.len, model.preview().len);
    try testing.expect(!model.previewTruncated());
    try testing.expectEqual(@as(u8, 5), editor.code_line_number_digits);
    try testing.expectEqual(@as(usize, 1), editor.spans.len);
}

test "selected editable code keeps unique display-list ids across app deactivation" {
    var model = try fixtureModel();
    defer model.deinit();
    const src_index = model.findEntry("src").?;
    model.entries[src_index].expanded = true;
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const selected_index = model.findEntry(main_path).?;
    model.preview_entry = selected_index;
    const source = "pub fn main() void {\n    const answer: u32 = 42;\n}\n";
    seedActiveDocument(&model, selected_index, source);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    const editor = findByText(tree.root, .textarea, source).?;

    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    var layout = try canvas.layoutWidgetTree(
        tree.root,
        native_sdk.geometry.RectF.init(0, 0, main.window_width, main.window_height),
        &nodes,
    );
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id != editor.id) continue;
        // Mirror the edit/rebuild seam: runtime text and source-highlight
        // spans have equal bytes but temporarily live in distinct storage.
        nodes[index].widget.text = try arena_state.allocator().dupe(u8, source);
        nodes[index].widget.text_selection = .{ .anchor = 4, .focus = 30 };
        break;
    }

    var active_commands: [2048]canvas.CanvasCommand = undefined;
    var active_builder = canvas.Builder.init(&active_commands);
    try layout.emitDisplayListWithState(&active_builder, .{}, .{
        .keyboard_active = true,
        .focused_id = editor.id,
    });
    var inactive_commands: [2048]canvas.CanvasCommand = undefined;
    var inactive_builder = canvas.Builder.init(&inactive_commands);
    try layout.emitDisplayListWithState(&inactive_builder, .{}, .{
        .keyboard_active = false,
        .focused_id = editor.id,
    });
    var changes: [2048]canvas.DiffChange = undefined;
    _ = try canvas.DisplayList.diff(
        active_builder.displayList(),
        inactive_builder.displayList(),
        &changes,
    );
}

test "the compiled view and hot-reload interpreter build the same tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = try fixtureModel();
    defer model.deinit();
    const src_index = model.findEntry("src").?;
    model.entries[src_index].expanded = true;
    const main_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(main_path);
    const selected_index = model.findEntry(main_path).?;
    model.preview_entry = selected_index;
    const source = "pub fn main() void {}\n";
    seedActiveDocument(&model, selected_index, source);

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

    const compiled_row = findByRole(compiled.root, .treeitem).?;
    const interpreted_row = findByRole(interpreted.root, .treeitem).?;
    try testing.expectEqual(interpreted_row.id, compiled_row.id);
    try testing.expectEqual(
        interpreted.msgForPointer(interpreted_row.id, .up).?,
        compiled.msgForPointer(compiled_row.id, .up).?,
    );

    const compiled_file = findByRoleAndLabel(compiled.root, .treeitem, "main.zig").?;
    const interpreted_file = findByRoleAndLabel(interpreted.root, .treeitem, "main.zig").?;
    try testing.expectEqual(
        interpreted.msgForPointerClick(interpreted_file.id, .up, 2).?,
        compiled.msgForPointerClick(compiled_file.id, .up, 2).?,
    );
    try testing.expectEqual(
        main.Msg{ .pin_entry = model.selected_entry.? },
        compiled.msgForPointerClick(compiled_file.id, .up, 2).?,
    );
}

test "chrome geometry centers the custom titlebar around the traffic lights" {
    var model = main.Model{};
    try testing.expectEqual(main.titlebar_natural_height, model.titlebar_height);

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const chrome: native_sdk.WindowChrome = .{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 19, 52, 14),
    };
    main.update(&model, main.onChrome(chrome).?, &fx);
    try testing.expectEqual(@as(f32, 78), model.chrome_leading);
    try testing.expectEqual(@max(main.titlebar_natural_height, 52), model.titlebar_height);

    main.update(&model, main.onChrome(.{ .insets = .{ .top = 72, .left = 78 } }).?, &fx);
    try testing.expectEqual(@as(f32, 72), model.titlebar_height);

    main.update(&model, main.onChrome(.{}).?, &fx);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    try testing.expectEqual(main.titlebar_natural_height, model.titlebar_height);
    try testing.expectEqual(.hidden_inset_tall, main.shell_scene.windows[0].titlebar);
}

test "layout and accessibility stay clean from the window floor upward" {
    var empty = main.Model{};
    var loaded = try fixtureModel();
    defer loaded.deinit();
    const src_index = loaded.findEntry("src").?;
    loaded.entries[src_index].expanded = true;
    const selected_path = try std.fs.path.join(testing.allocator, &.{ "src", "main.zig" });
    defer testing.allocator.free(selected_path);
    const selected_index = loaded.findEntry(selected_path).?;
    loaded.preview_entry = selected_index;
    const source = "pub fn main() void {}\n";
    seedActiveDocument(&loaded, selected_index, source);

    const states = [_]*const main.Model{ &empty, &loaded };
    for (states) |model| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const tree = try buildTree(arena_state.allocator(), model);
        try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, .{
            .min_size = native_sdk.geometry.SizeF.init(main.window_min_width, main.window_min_height),
            .default_size = native_sdk.geometry.SizeF.init(main.window_width, main.window_height),
            .large_size = native_sdk.geometry.SizeF.init(1440, 900),
        });
        try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, .{
            .min_size = native_sdk.geometry.SizeF.init(main.window_min_width, main.window_min_height),
            .default_size = native_sdk.geometry.SizeF.init(main.window_width, main.window_height),
            .large_size = native_sdk.geometry.SizeF.init(1440, 900),
        });
    }
}
