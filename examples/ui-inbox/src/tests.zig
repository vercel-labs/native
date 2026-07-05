const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const InboxUi = main.InboxUi;
const Model = main.Model;
const Msg = main.Msg;

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn countKind(widget: canvas.Widget, kind: canvas.WidgetKind) usize {
    var total: usize = 0;
    if (widget.kind == kind) total += 1;
    for (widget.children) |child| total += countKind(child, kind);
    return total;
}

const InboxMarkup = canvas.MarkupView(Model, main.Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !InboxUi.Tree {
    var view = try InboxMarkup.init(arena, main.inbox_markup);
    var ui = InboxUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

test "a full user session drives the model through typed dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.addTask("First");
    model.addTask("Second");

    // Click "Add task".
    var tree = try buildTree(arena, &model);
    const add_button = findByText(tree.root, .button, "Add task").?;
    main.update(&model, tree.msgForPointer(add_button.id, .up).?);
    try testing.expectEqual(@as(usize, 3), model.task_count);

    // Toggle the first task's checkbox; its id must survive the rebuild.
    tree = try buildTree(arena, &model);
    const first_checkbox = firstCheckbox(tree.root).?;
    main.update(&model, tree.msgForPointer(first_checkbox.id, .up).?);
    try testing.expectEqual(@as(usize, 2), model.openCount());

    const rebuilt = try buildTree(arena, &model);
    const rebuilt_checkbox = firstCheckbox(rebuilt.root).?;
    try testing.expectEqual(first_checkbox.id, rebuilt_checkbox.id);
    try testing.expect(rebuilt_checkbox.state.selected);

    // Switch to the done filter; only completed rows remain visible.
    // Tab triggers are `<button>`s in markup, lowered to segmented
    // controls by the engine (the house tab treatment).
    const done_button = findByText(rebuilt.root, .segmented_control, "done").?;
    main.update(&model, rebuilt.msgForPointer(done_button.id, .up).?);
    const filtered = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 1), countKind(filtered.root, .checkbox));

    // Clear done removes the completed task.
    const clear_button = findByText(filtered.root, .button, "Clear done").?;
    main.update(&model, filtered.msgForPointer(clear_button.id, .up).?);
    try testing.expectEqual(@as(usize, 2), model.task_count);
    try testing.expectEqual(@as(usize, 2), model.openCount());
}

test "the inbox view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    model.addTask("First");
    model.addTask("Second");
    const tree = try buildTree(arena_state.allocator(), &model);

    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 720, 520), &nodes);
    try testing.expect(layout.nodes.len > 0);

    const add_button = findByText(tree.root, .button, "Add task").?;
    var saw_button = false;
    for (layout.nodes) |node| {
        if (node.widget.id == add_button.id) saw_button = true;
    }
    try testing.expect(saw_button);
}

test "layout audit sweep: nothing clips, overlaps, or escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    model.addTask("Write the launch announcement draft");
    model.addTask("Second");
    const tree = try buildTree(arena_state.allocator(), &model);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, .{
        .min_size = native_sdk.geometry.SizeF.init(main.window_min_width, main.window_min_height),
        .default_size = native_sdk.geometry.SizeF.init(720, 520),
    });
}

fn firstCheckbox(widget: canvas.Widget) ?canvas.Widget {
    if (widget.kind == .checkbox) return widget;
    for (widget.children) |child| {
        if (firstCheckbox(child)) |found| return found;
    }
    return null;
}

test "the draft field is an elm-style mirror: edits, submit, clear" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};

    // Type "Milk" through the typed dispatch path.
    var tree = try buildTree(arena, &model);
    const field = findByKind(tree.root, .text_field).?;
    for ([_][]const u8{ "M", "i", "l", "k" }) |letter| {
        const typed = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = letter };
        main.update(&model, tree.msgForKeyboard(field.id, typed).?);
        tree = try buildTree(arena, &model);
    }
    try testing.expectEqualStrings("Milk", model.draft());
    try testing.expectEqualStrings("Milk", findByKind(tree.root, .text_field).?.text);

    // Backspace edits through the same path.
    const backspace = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "backspace" };
    main.update(&model, tree.msgForKeyboard(field.id, backspace).?);
    try testing.expectEqualStrings("Mil", model.draft());

    // Enter submits: the task is created from the draft and the field
    // clears (the source-side change that wins over runtime text).
    tree = try buildTree(arena, &model);
    const enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    main.update(&model, tree.msgForKeyboard(field.id, enter).?);
    try testing.expectEqual(@as(usize, 1), model.task_count);
    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .text, "Mil") != null);
    try testing.expectEqualStrings("", findByKind(tree.root, .text_field).?.text);
}

fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

test "compiled and interpreted inbox views build identical trees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.addTask("First");
    model.addTask("Second");

    const interpreted = try buildTree(arena, &model);
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(main.CompiledInboxView.build(&compiled_ui, &model));

    try expectSameIds(interpreted.root, compiled.root);
    try testing.expectEqual(interpreted.handlers.len, compiled.handlers.len);
}

fn expectSameIds(expected: canvas.Widget, actual: canvas.Widget) !void {
    try testing.expectEqual(expected.id, actual.id);
    try testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |expected_child, actual_child| {
        try expectSameIds(expected_child, actual_child);
    }
}
