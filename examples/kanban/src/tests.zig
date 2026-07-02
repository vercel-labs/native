const std = @import("std");
const zero_native = @import("zero-native");
const main = @import("main.zig");

const canvas = zero_native.canvas;
const testing = std.testing;

const KanbanUi = main.KanbanUi;
const Model = main.Model;
const Msg = main.Msg;

const KanbanMarkup = canvas.MarkupView(Model, main.Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !KanbanUi.Tree {
    var view = try KanbanMarkup.init(arena, main.board_markup);
    var ui = KanbanUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn subtreeHasText(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.eql(u8, widget.text, text)) return true;
    for (widget.children) |child| {
        if (subtreeHasText(child, text)) return true;
    }
    return false;
}

/// The keyed card container for a given title: the list-item row whose
/// subtree contains the title text.
fn findCard(widget: canvas.Widget, title: []const u8) ?canvas.Widget {
    if (widget.semantics.role == .listitem and subtreeHasText(widget, title)) return widget;
    for (widget.children) |child| {
        if (findCard(child, title)) |found| return found;
    }
    return null;
}

fn findButtonIn(widget: canvas.Widget) ?canvas.Widget {
    if (widget.kind == .button) return widget;
    for (widget.children) |child| {
        if (findButtonIn(child)) |found| return found;
    }
    return null;
}

fn countCards(widget: canvas.Widget) usize {
    var total: usize = 0;
    if (widget.semantics.role == .listitem) total += 1;
    for (widget.children) |child| total += countCards(child);
    return total;
}

test "add card flows through typed pointer dispatch and updates counts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.addCard("Ship it");
    model.addCard("Fix the bug");
    model.addCard("Old work");
    main.update(&model, .{ .move_right = 3 });
    main.update(&model, .{ .move_right = 3 });

    var tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .status_bar, "2 todo · 0 doing · 1 done") != null);
    try testing.expectEqual(@as(usize, 3), countCards(tree.root));

    // Click "Add card": a new card lands in Todo.
    const add_button = findByText(tree.root, .button, "Add card").?;
    main.update(&model, tree.msgForPointer(add_button.id, .up).?);
    try testing.expectEqual(@as(usize, 3), model.count(.todo));

    tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .status_bar, "3 todo · 0 doing · 1 done") != null);
    try testing.expectEqual(@as(usize, 4), countCards(tree.root));
    try testing.expect(findCard(tree.root, "Card 4") != null);
}

test "a card keeps its widget id as it moves across all three columns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.addCard("Ship it");
    model.addCard("Fix the bug");

    var tree = try buildTree(arena, &model);
    const card_before = findCard(tree.root, "Ship it").?;
    try testing.expectEqual(main.Column.todo, model.cardById(1).?.column);

    // Click the card's move affordance: Todo -> Doing.
    const move_button = findButtonIn(card_before).?;
    main.update(&model, tree.msgForPointer(move_button.id, .up).?);
    try testing.expectEqual(main.Column.doing, model.cardById(1).?.column);

    // Keyed identity: the card widget id survives the column move.
    tree = try buildTree(arena, &model);
    const card_doing = findCard(tree.root, "Ship it").?;
    try testing.expectEqual(card_before.id, card_doing.id);

    // Doing -> Done, same identity again.
    const move_again = findButtonIn(card_doing).?;
    try testing.expectEqual(move_button.id, move_again.id);
    main.update(&model, tree.msgForPointer(move_again.id, .up).?);
    try testing.expectEqual(main.Column.done, model.cardById(1).?.column);

    tree = try buildTree(arena, &model);
    const card_done = findCard(tree.root, "Ship it").?;
    try testing.expectEqual(card_before.id, card_done.id);

    // Done cards have no move affordance and the old button resolves to
    // no message.
    try testing.expect(findButtonIn(card_done) == null);
    try testing.expect(tree.msgForPointer(move_again.id, .up) == null);

    try testing.expect(findByText(tree.root, .status_bar, "1 todo · 0 doing · 1 done") != null);
}

test "the board lays out through the canvas engine with cards in their columns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.addCard("Ship it");
    model.addCard("Fix the bug");
    main.update(&model, .{ .move_right = 2 });

    const tree = try buildTree(arena, &model);
    var nodes: [512]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, zero_native.geometry.RectF.init(0, 0, 840, 560), &nodes);
    try testing.expect(layout.nodes.len > 0);

    const todo_card = findCard(tree.root, "Ship it").?;
    const doing_card = findCard(tree.root, "Fix the bug").?;
    var todo_frame: ?zero_native.geometry.RectF = null;
    var doing_frame: ?zero_native.geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.widget.id == todo_card.id) todo_frame = node.frame;
        if (node.widget.id == doing_card.id) doing_frame = node.frame;
    }
    // Both cards are placed, side by side in their columns at the same rank.
    try testing.expect(todo_frame != null);
    try testing.expect(doing_frame != null);
    try testing.expect(doing_frame.?.x > todo_frame.?.x + 100);
    try testing.expectEqual(todo_frame.?.y, doing_frame.?.y);
}

test "compiled and interpreted kanban views build identical trees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.addCard("First");
    model.addCard("Second");

    const interpreted = try buildTree(arena, &model);
    var compiled_ui = KanbanUi.init(arena);
    const compiled = try compiled_ui.finalize(main.CompiledBoardView.build(&compiled_ui, &model));

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
