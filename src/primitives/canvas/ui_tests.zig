const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const ui_model = @import("ui.zig");

const testing = std.testing;

const Filter = enum { all, active, done };

const Task = struct {
    id: u32,
    title: []const u8,
    done: bool = false,

    fn key(task: *const Task) ui_model.UiKey {
        return ui_model.uiKey(task.id);
    }
};

const Msg = union(enum) {
    add,
    toggle: u32,
    set_filter: Filter,
    draft: canvas.TextInputEvent,
    confidence: f32,
};

const InboxUi = ui_model.Ui(Msg);

const Model = struct {
    tasks: []const Task,
    filter: Filter = .all,
    open_count: usize = 0,
};

fn taskRow(ui: *InboxUi, task: *const Task) InboxUi.Node {
    return ui.row(.{ .gap = 8, .padding = 4, .cross = .center }, .{
        ui.checkbox(.{ .checked = task.done, .on_toggle = Msg{ .toggle = task.id } }),
        ui.text(.{ .grow = 1 }, task.title),
    });
}

fn inboxView(ui: *InboxUi, model: *const Model) InboxUi.Node {
    return ui.column(.{ .gap = 8 }, .{
        ui.row(.{ .gap = 8, .padding = 8 }, .{
            ui.textField(.{ .placeholder = "New task…", .grow = 1, .on_submit = .add }),
            ui.button(.{ .variant = .primary, .on_press = .add }, "Add"),
        }),
        ui.scroll(.{ .grow = 1 }, ui.each(model.tasks, Task.key, taskRow)),
        ui.statusBar(.{}, ui.fmt("{d} open", .{model.open_count})),
    });
}

fn collectIds(widget: canvas.Widget, ids: *std.ArrayListUnmanaged(canvas.ObjectId), allocator: std.mem.Allocator) !void {
    try ids.append(allocator, widget.id);
    for (widget.children) |child| try collectIds(child, ids, allocator);
}

fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

fn findRowByCheckboxToggle(tree: InboxUi.Tree, widget: canvas.Widget, task_id: u32) ?canvas.Widget {
    if (widget.kind == .checkbox) {
        if (tree.msgFor(widget.id, .toggle)) |msg| {
            if (msg == .toggle and msg.toggle == task_id) return widget;
        }
    }
    for (widget.children) |child| {
        if (findRowByCheckboxToggle(tree, child, task_id)) |found| return found;
    }
    return null;
}

test "ui builder emits an engine-compatible widget tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const tasks = [_]Task{
        .{ .id = 1, .title = "Ship IR" },
        .{ .id = 2, .title = "Write RFC", .done = true },
    };
    const model = Model{ .tasks = &tasks, .open_count = 1 };

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(inboxView(&ui, &model));

    try testing.expectEqual(canvas.WidgetKind.column, tree.root.kind);
    try testing.expectEqual(@as(usize, 3), tree.root.children.len);
    try testing.expect(findByKind(tree.root, .text_field) != null);
    try testing.expectEqual(@as(usize, 2), findByKind(tree.root, .scroll_view).?.children.len);
    try testing.expectEqualStrings("1 open", findByKind(tree.root, .status_bar).?.text);

    var ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer ids.deinit(testing.allocator);
    try collectIds(tree.root, &ids, testing.allocator);
    for (ids.items, 0..) |id, index| {
        try testing.expect(id != 0);
        for (ids.items[index + 1 ..]) |other| try testing.expect(id != other);
    }

    var layout_nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 720, 480), &layout_nodes);
    const button_id = findByKind(tree.root, .button).?.id;
    var saw_button = false;
    for (layout.nodes) |node| {
        if (node.widget.id == button_id) saw_button = true;
    }
    try testing.expect(saw_button);
}

test "structural ids are stable across rebuilds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const tasks = [_]Task{
        .{ .id = 1, .title = "Ship IR" },
        .{ .id = 2, .title = "Write RFC" },
    };
    const model = Model{ .tasks = &tasks, .open_count = 2 };

    var first_ui = InboxUi.init(arena_state.allocator());
    const first = try first_ui.finalize(inboxView(&first_ui, &model));
    var second_ui = InboxUi.init(arena_state.allocator());
    const second = try second_ui.finalize(inboxView(&second_ui, &model));

    var first_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer first_ids.deinit(testing.allocator);
    var second_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer second_ids.deinit(testing.allocator);
    try collectIds(first.root, &first_ids, testing.allocator);
    try collectIds(second.root, &second_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, first_ids.items, second_ids.items);
}

test "keyed items keep their ids across reorders and insertions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const before_tasks = [_]Task{
        .{ .id = 1, .title = "Ship IR" },
        .{ .id = 2, .title = "Write RFC" },
    };
    const after_tasks = [_]Task{
        .{ .id = 3, .title = "New first task" },
        .{ .id = 2, .title = "Write RFC" },
        .{ .id = 1, .title = "Ship IR" },
    };

    var before_ui = InboxUi.init(arena_state.allocator());
    const before = try before_ui.finalize(inboxView(&before_ui, &Model{ .tasks = &before_tasks }));
    var after_ui = InboxUi.init(arena_state.allocator());
    const after = try after_ui.finalize(inboxView(&after_ui, &Model{ .tasks = &after_tasks }));

    const before_task_one = findRowByCheckboxToggle(before, before.root, 1).?;
    const after_task_one = findRowByCheckboxToggle(after, after.root, 1).?;
    try testing.expectEqual(before_task_one.id, after_task_one.id);

    const before_task_two = findRowByCheckboxToggle(before, before.root, 2).?;
    const after_task_two = findRowByCheckboxToggle(after, after.root, 2).?;
    try testing.expectEqual(before_task_two.id, after_task_two.id);
}

test "global keys keep ids across reparenting, sibling keys do not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Board = struct {
        fn view(ui: *InboxUi, in_first_column: bool) InboxUi.Node {
            const movable = [_]InboxUi.Node{
                ui.el(.card, .{ .global_key = ui_model.uiKey(@as(u32, 7)), .gap = 4 }, .{
                    ui.checkbox(.{ .on_toggle = Msg{ .toggle = 7 } }),
                }),
                ui.text(.{ .key = ui_model.uiKey(@as(u32, 8)) }, "Sibling-keyed"),
            };
            const empty = [_]InboxUi.Node{};
            return ui.row(.{}, .{
                ui.column(.{}, @as([]const InboxUi.Node, if (in_first_column) &movable else &empty)),
                ui.column(.{}, @as([]const InboxUi.Node, if (in_first_column) &empty else &movable)),
            });
        }
    };

    var first_ui = InboxUi.init(arena);
    const first = try first_ui.finalize(Board.view(&first_ui, true));
    var second_ui = InboxUi.init(arena);
    const second = try second_ui.finalize(Board.view(&second_ui, false));

    // The globally keyed card keeps its id in a different parent, and its
    // descendants (hashed from the card's id) follow it.
    const first_card = findByKind(first.root, .card).?;
    const second_card = findByKind(second.root, .card).?;
    try testing.expectEqual(first_card.id, second_card.id);
    try testing.expectEqual(first_card.children[0].id, second_card.children[0].id);
    try testing.expectEqual(
        first.msgFor(first_card.children[0].id, .toggle).?,
        second.msgFor(second_card.children[0].id, .toggle).?,
    );

    // A sibling-scoped key does not survive the move.
    const first_keyed = findByKind(first.root.children[0], .text).?;
    const second_keyed = findByKind(second.root.children[1], .text).?;
    try testing.expect(first_keyed.id != second_keyed.id);
}

test "typed handlers dispatch through the elm-style loop" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var tasks = [_]Task{
        .{ .id = 1, .title = "Ship IR" },
        .{ .id = 2, .title = "Write RFC" },
    };
    var model = Model{ .tasks = &tasks, .open_count = 2 };

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(inboxView(&ui, &model));

    const add_button = findByKind(tree.root, .button).?;
    try testing.expectEqual(Msg.add, tree.msgFor(add_button.id, .press).?);
    try testing.expectEqual(@as(?Msg, null), tree.msgFor(add_button.id, .toggle));

    const checkbox = findRowByCheckboxToggle(tree, tree.root, 2).?;
    try testing.expect(!checkbox.state.selected);

    // Dispatch the checkbox toggle message and rebuild, elm-style.
    switch (tree.msgFor(checkbox.id, .toggle).?) {
        .toggle => |task_id| {
            for (&tasks) |*task| {
                if (task.id == task_id) task.done = !task.done;
            }
        },
        else => return error.TestUnexpectedResult,
    }
    model.open_count = 1;

    var next_ui = InboxUi.init(arena_state.allocator());
    const next = try next_ui.finalize(inboxView(&next_ui, &model));
    const next_checkbox = findRowByCheckboxToggle(next, next.root, 2).?;
    try testing.expectEqual(checkbox.id, next_checkbox.id);
    try testing.expect(next_checkbox.state.selected);
    try testing.expectEqualStrings("1 open", findByKind(next.root, .status_bar).?.text);
}

test "pointer events resolve to typed messages through semantic intents" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const tasks = [_]Task{
        .{ .id = 1, .title = "Ship IR" },
        .{ .id = 2, .title = "Write RFC" },
    };
    const model = Model{ .tasks = &tasks, .open_count = 2 };

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(inboxView(&ui, &model));

    // Released press on the add button dispatches its press message.
    const add_button = findByKind(tree.root, .button).?;
    try testing.expectEqual(Msg.add, tree.msgForPointer(add_button.id, .up).?);

    // Released press on a checkbox resolves to its toggle message.
    const checkbox = findRowByCheckboxToggle(tree, tree.root, 1).?;
    const toggle_msg = tree.msgForPointer(checkbox.id, .up).?;
    try testing.expectEqual(@as(u32, 1), toggle_msg.toggle);

    // Non-activating phases and handler-less widgets dispatch nothing.
    try testing.expectEqual(@as(?Msg, null), tree.msgForPointer(add_button.id, .down));
    try testing.expectEqual(@as(?Msg, null), tree.msgForPointer(add_button.id, .hover));
    const status_bar = findByKind(tree.root, .status_bar).?;
    try testing.expectEqual(@as(?Msg, null), tree.msgForPointer(status_bar.id, .up));
    try testing.expectEqual(@as(?Msg, null), tree.msgForPointer(0xdead_beef, .up));
}

test "keyboard events resolve activation and submit messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const tasks = [_]Task{.{ .id = 1, .title = "Ship IR" }};
    const model = Model{ .tasks = &tasks, .open_count = 1 };

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(inboxView(&ui, &model));

    // Space activates a focused checkbox as a toggle.
    const checkbox = findRowByCheckboxToggle(tree, tree.root, 1).?;
    const space_down = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "space" };
    const toggle_msg = tree.msgForKeyboard(checkbox.id, space_down).?;
    try testing.expectEqual(@as(u32, 1), toggle_msg.toggle);

    // Enter submits from the text field.
    const text_field = findByKind(tree.root, .text_field).?;
    const enter_down = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expectEqual(Msg.add, tree.msgForKeyboard(text_field.id, enter_down).?);

    // Key-up, modified, and unrelated keys dispatch nothing.
    const enter_up = canvas.WidgetKeyboardEvent{ .phase = .key_up, .key = "enter" };
    try testing.expectEqual(@as(?Msg, null), tree.msgForKeyboard(text_field.id, enter_up));
    const control_enter = canvas.WidgetKeyboardEvent{
        .phase = .key_down,
        .key = "enter",
        .modifiers = .{ .control = true },
    };
    try testing.expectEqual(@as(?Msg, null), tree.msgForKeyboard(text_field.id, control_enter));
    const letter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "a" };
    try testing.expectEqual(@as(?Msg, null), tree.msgForKeyboard(checkbox.id, letter));
}

test "payload-carrying handlers build messages from edits and values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.column(.{ .gap = 8 }, .{
        ui.textField(.{ .placeholder = "New task…", .on_input = InboxUi.inputMsg(.draft), .on_submit = .add }),
        ui.el(.slider, .{ .value = 0.5, .on_value = InboxUi.valueMsg(.confidence) }, .{}),
    }));

    const text_field = findByKind(tree.root, .text_field).?;
    const slider = findByKind(tree.root, .slider).?;

    // Typed text becomes a draft message carrying the edit.
    const typed = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = "a" };
    const draft_msg = tree.msgForKeyboard(text_field.id, typed).?;
    try testing.expectEqualStrings("a", draft_msg.draft.insert_text);

    // Editing keys carry structured edits.
    const backspace = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "backspace" };
    try testing.expectEqual(canvas.TextInputEvent.delete_backward, tree.msgForKeyboard(text_field.id, backspace).?.draft);

    // Enter still submits rather than editing.
    const enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expectEqual(Msg.add, tree.msgForKeyboard(text_field.id, enter).?);

    // Slider keyboard steps carry the new value.
    const step_up = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowright" };
    const confidence_msg = tree.msgForKeyboard(slider.id, step_up).?;
    try testing.expect(confidence_msg.confidence > 0.5);

    // Direct value dispatch (accessibility set-value) works too.
    try testing.expectEqual(@as(f32, 0.25), tree.msgForValue(slider.id, 0.25).?.confidence);

    // Widgets without payload handlers dispatch nothing for edits.
    const checkbox_tree = blk: {
        var other_ui = InboxUi.init(arena_state.allocator());
        break :blk try other_ui.finalize(other_ui.checkbox(.{ .on_toggle = Msg{ .toggle = 1 } }));
    };
    try testing.expectEqual(@as(?Msg, null), checkbox_tree.msgForTextEdit(checkbox_tree.root.id, .delete_backward));
}

test "toggling one of a thousand keyed rows invalidates O(changed), not O(n)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const task_count = 1000;
    const tasks = try arena.alloc(Task, task_count);
    for (tasks, 0..) |*task, index| {
        task.* = .{ .id = @intCast(index + 1), .title = "Benchmark row" };
    }

    const bounds = geometry.RectF.init(0, 0, 800, 24 * task_count);
    const before_nodes = try testing.allocator.alloc(canvas.WidgetLayoutNode, 4096);
    defer testing.allocator.free(before_nodes);
    const after_nodes = try testing.allocator.alloc(canvas.WidgetLayoutNode, 4096);
    defer testing.allocator.free(after_nodes);

    var before_ui = InboxUi.init(arena);
    const before_tree = try before_ui.finalize(benchmarkView(&before_ui, tasks));
    const before_layout = try canvas.layoutWidgetTree(before_tree.root, bounds, before_nodes);

    tasks[499].done = true;
    var after_ui = InboxUi.init(arena);
    const after_tree = try after_ui.finalize(benchmarkView(&after_ui, tasks));
    const after_layout = try canvas.layoutWidgetTree(after_tree.root, bounds, after_nodes);

    // Structural identity: every widget id is unchanged by the rebuild.
    try testing.expectEqual(before_layout.nodes.len, after_layout.nodes.len);
    for (before_layout.nodes, after_layout.nodes) |before_node, after_node| {
        try testing.expectEqual(before_node.widget.id, after_node.widget.id);
    }

    // The layout diff must scale with what changed, not with row count.
    var invalidations: [32]canvas.WidgetInvalidation = undefined;
    const changed = try canvas.WidgetLayoutTree.diffWithTokens(before_layout, after_layout, .{}, &invalidations);
    try testing.expect(changed.len >= 1);
    try testing.expect(changed.len <= 4);
}

fn benchmarkView(ui: *InboxUi, tasks: []const Task) InboxUi.Node {
    return ui.column(.{}, ui.each(tasks, Task.key, taskRow));
}

test "allocation failure latches and surfaces from finalize" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var ui = InboxUi.init(failing.allocator());
    const node = ui.column(.{}, .{
        ui.text(.{}, ui.fmt("{d}", .{@as(usize, 1)})),
    });
    try testing.expectError(error.OutOfMemory, ui.finalize(node));
}
