const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const KanbanUi = main.KanbanUi;
const Model = main.Model;
const Msg = main.Msg;

const KanbanMarkup = canvas.MarkupView(Model, main.Msg);

/// The interpreter over the same resolved document the compiled view
/// embeds: the board imports components/board-column.native, so the test
/// resolves the embedded source set exactly like the app runtime does.
fn boardView(arena: std.mem.Allocator) !KanbanMarkup {
    var set_loader = canvas.ui_markup.SourceSetLoader{ .set = &main.board_markup_files };
    var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
    const document = try canvas.ui_markup.resolveImports(arena, "board.native", main.board_markup, set_loader.loader(), &diagnostic);
    return KanbanMarkup.fromDocument(document);
}

fn buildTree(arena: std.mem.Allocator, model: *const Model) !KanbanUi.Tree {
    var view = try boardView(arena);
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
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 840, 560), &nodes);
    try testing.expect(layout.nodes.len > 0);

    const todo_card = findCard(tree.root, "Ship it").?;
    const doing_card = findCard(tree.root, "Fix the bug").?;
    var todo_frame: ?native_sdk.geometry.RectF = null;
    var doing_frame: ?native_sdk.geometry.RectF = null;
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

/// The board markup before the board-column template existed: three
/// copy-pasted column blocks. Template expansion happens at the use site,
/// so the templated board must produce byte-identical widget ids.
const legacy_board_markup =
    \\<column background="background">
    \\  <row height="{header_height}" padding="12" gap="10" cross="center" background="surface" window-drag="true" label="Kanban header">
    \\    <spacer width="{chrome_leading}" />
    \\    <spacer grow="1" />
    \\    <button variant="primary" on-press="add">Add card</button>
    \\  </row>
    \\  <separator />
    \\  <row grow="1" gap="12" padding="16">
    \\    <column grow="1" gap="8" padding="10" label="Todo">
    \\      <text>Todo</text>
    \\      <column gap="8">
    \\        <for each="todoCards" key="id" as="c">
    \\          <row global-key="{c.id}" gap="8" padding="8" cross="center" role="listitem" label="{c.title}">
    \\            <text grow="1">{c.title}</text>
    \\            <if test="{c.movable}">
    \\              <button size="sm" on-press="move_right:{c.id}">></button>
    \\            </if>
    \\          </row>
    \\        </for>
    \\      </column>
    \\    </column>
    \\    <column grow="1" gap="8" padding="10" label="Doing">
    \\      <text>Doing</text>
    \\      <column gap="8">
    \\        <for each="doingCards" key="id" as="c">
    \\          <row global-key="{c.id}" gap="8" padding="8" cross="center" role="listitem" label="{c.title}">
    \\            <text grow="1">{c.title}</text>
    \\            <if test="{c.movable}">
    \\              <button size="sm" on-press="move_right:{c.id}">></button>
    \\            </if>
    \\          </row>
    \\        </for>
    \\      </column>
    \\    </column>
    \\    <column grow="1" gap="8" padding="10" label="Done">
    \\      <text>Done</text>
    \\      <column gap="8">
    \\        <for each="doneCards" key="id" as="c">
    \\          <row global-key="{c.id}" gap="8" padding="8" cross="center" role="listitem" label="{c.title}">
    \\            <text grow="1">{c.title}</text>
    \\            <if test="{c.movable}">
    \\              <button size="sm" on-press="move_right:{c.id}">></button>
    \\            </if>
    \\          </row>
    \\        </for>
    \\      </column>
    \\    </column>
    \\  </row>
    \\  <status-bar>{todoCount} todo · {doingCount} doing · {doneCount} done</status-bar>
    \\</column>
;

test "layout audit sweep: nothing clips, overlaps, or escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    const tree = try buildTree(arena_state.allocator(), &model);
    const floor = native_sdk.geometry.SizeF.init(main.window_min_width, main.window_min_height);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, .{
        .min_size = floor,
        .default_size = floor,
    });
}

test "a11y audit sweep: every interactive widget is named, reachable, and unambiguous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    const tree = try buildTree(arena_state.allocator(), &model);
    const floor = native_sdk.geometry.SizeF.init(main.window_min_width, main.window_min_height);
    try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, .{
        .min_size = floor,
        .default_size = floor,
    });
}

test "the templated board keeps the pre-template widget ids exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.addCard("Ship it");
    model.addCard("Fix the bug");
    model.addCard("Old work");
    main.update(&model, .{ .move_right = 2 });
    main.update(&model, .{ .move_right = 3 });
    main.update(&model, .{ .move_right = 3 });

    const templated = try buildTree(arena, &model);
    var legacy_view = try KanbanMarkup.init(arena, legacy_board_markup);
    var legacy_ui = KanbanUi.init(arena);
    const legacy = try legacy_ui.finalize(try legacy_view.build(&legacy_ui, &model));
    try expectSameIds(legacy.root, templated.root);
}

test "the board's style tokens resolve to concrete card and header styles" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.addCard("Ship it");

    const tree = try buildTree(arena, &model);
    const tokens = canvas.DesignTokens{};
    const card = findCard(tree.root, "Ship it").?;
    try testing.expectEqualDeep(tokens.colors.surface, card.style.background.?);
    try testing.expectEqual(tokens.radius.md, card.style.radius.?);
    const header = findByText(tree.root, .text, "Todo").?;
    try testing.expectEqualDeep(tokens.colors.text_muted, header.style.foreground.?);
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

test "the board markup satisfies the model contract in both directions" {
    // The same check `native check` runs against the emitted artifact,
    // in-process: every binding, iterable, message tag, and expression in
    // the resolved board document against the app's real Model/Msg
    // (view -> model), and no model state or Msg tag left unbound past
    // the declared view_unbound set (model -> view).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const board_contract = comptime canvas.describeModelContract(Model, Msg);
    var set_loader = canvas.ui_markup.SourceSetLoader{ .set = &main.board_markup_files };
    var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
    const document = try canvas.ui_markup.resolveImports(arena, "board.native", main.board_markup, set_loader.loader(), &diagnostic);
    try testing.expectEqual(null, canvas.ui_markup.validate(document));

    var usage = try canvas.ui_markup.contract.Usage.init(arena, &board_contract);
    if (try canvas.ui_markup.contract.checkDocument(arena, document, &board_contract, &usage)) |info| {
        std.debug.print("contract check failed: {s}:{d}:{d}: {s}\n", .{ info.path, info.line, info.column, info.message });
        return error.TestUnexpectedError;
    }
    const warnings = try canvas.ui_markup.contract.deadState(arena, &board_contract, &usage);
    for (warnings) |warning| {
        std.debug.print("dead-state warning: {s}\n", .{warning.message});
    }
    try testing.expectEqual(@as(usize, 0), warnings.len);
}

test "chrome geometry pads the header and matches its height to the tall band" {
    var model = main.Model{};
    try testing.expectEqual(main.header_natural_height, model.header_height);

    // The tall hidden-inset band arrives through on_chrome: the header
    // pads past the traffic lights and matches the band's height so its
    // centered controls share the lights' centerline.
    const chrome: native_sdk.WindowChrome = .{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 19, 52, 14),
    };
    const msg = main.onChrome(chrome) orelse return error.TestUnexpectedResult;
    main.update(&model, msg);
    try testing.expectEqual(@as(f32, 78), model.chrome_leading);
    try testing.expectEqual(@max(main.header_natural_height, 52), model.header_height);

    // A band taller than the natural header grows the header with it.
    const tall = main.onChrome(.{ .insets = .{ .top = 72, .left = 78 } }) orelse return error.TestUnexpectedResult;
    main.update(&model, tall);
    try testing.expectEqual(@as(f32, 72), model.header_height);

    // Fullscreen zeroes the chrome: the pad collapses and the height
    // falls back to the header's natural floor.
    const cleared = main.onChrome(.{}) orelse return error.TestUnexpectedResult;
    main.update(&model, cleared);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    try testing.expectEqual(main.header_natural_height, model.header_height);

    // The scene declares the matching titlebar so the platform actually
    // hides the OS bar this header replaces.
    try testing.expectEqual(.hidden_inset_tall, main.shell_scene.windows[0].titlebar);
}
