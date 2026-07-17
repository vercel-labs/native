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
    load_more,
    toggle: u32,
    set_filter: Filter,
    draft: canvas.TextInputEvent,
    confidence: f32,
    feed_scrolled: canvas.ScrollState,
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

fn findByText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, text)) |found| return found;
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
                ui.el(.card, .{ .global_key = ui_model.uiKey(@as(u32, 7)), .padding = 4 }, .{
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

test "textarea keyboard: enter edits a newline, submit rides the primary chord" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.column(.{ .gap = 8 }, .{
        ui.el(.textarea, .{ .on_input = InboxUi.inputMsg(.draft), .on_submit = .add }, .{}),
    }));
    const textarea = findByKind(tree.root, .textarea).?;

    // Plain Enter is an EDIT: the model's on_input hears the newline the
    // runtime applied to the retained text — never a submit.
    const enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expectEqualStrings("\n", tree.msgForKeyboard(textarea.id, enter).?.draft.insert_text);

    // Shift+Enter stays a newline too: single-line muscle memory must
    // never destroy multi-line text.
    const shift_enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter", .modifiers = .{ .shift = true } };
    try testing.expectEqualStrings("\n", tree.msgForKeyboard(textarea.id, shift_enter).?.draft.insert_text);

    // The primary chord submits (cmd on macOS, ctrl elsewhere).
    const cmd_enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter", .modifiers = .{ .super = true } };
    try testing.expectEqual(Msg.add, tree.msgForKeyboard(textarea.id, cmd_enter).?);
    const ctrl_enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter", .modifiers = .{ .control = true } };
    try testing.expectEqual(Msg.add, tree.msgForKeyboard(textarea.id, ctrl_enter).?);

    // Shift/alt variants of the chord stay free for app shortcuts.
    const cmd_shift_enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter", .modifiers = .{ .super = true, .shift = true } };
    try testing.expectEqual(@as(?Msg, null), tree.msgForKeyboard(textarea.id, cmd_shift_enter));
    const alt_enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter", .modifiers = .{ .alt = true } };
    try testing.expectEqual(@as(?Msg, null), tree.msgForKeyboard(textarea.id, alt_enter));
}

test "single-line keyboard fallback derivation sanitizes line breaks like the runtime seam" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.column(.{ .gap = 8 }, .{
        ui.el(.text_field, .{ .on_input = InboxUi.inputMsg(.draft) }, .{}),
        ui.el(.textarea, .{ .on_input = InboxUi.inputMsg(.draft) }, .{}),
    }));
    const field = findByKind(tree.root, .text_field).?;
    const textarea = findByKind(tree.root, .textarea).?;

    // An un-stamped text_input event (a direct Tree consumer — nothing
    // crossed the runtime) derives its insert locally, and the local
    // derivation applies the SAME single-line sanitize rule the runtime
    // seam stamps with: line breaks strip, so a model mirror can never
    // hear bytes the retained editor would refuse.
    const multi_line = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = "a\nb\r\nc" };
    try testing.expectEqualStrings("abc", tree.msgForKeyboard(field.id, multi_line).?.draft.insert_text);
    try testing.expectEqualStrings("a\nb\r\nc", tree.msgForKeyboard(textarea.id, multi_line).?.draft.insert_text);

    // An insert that is ONLY breaks suppresses outright.
    const bare_breaks = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = "\r\n" };
    try testing.expectEqual(@as(?Msg, null), tree.msgForKeyboard(field.id, bare_breaks));

    // A STAMPED edit (the runtime already sanitized it) passes through.
    const stamped = canvas.WidgetKeyboardEvent{ .phase = .key_down, .edit = .{ .insert_text = "clean" } };
    try testing.expectEqualStrings("clean", tree.msgForKeyboard(field.id, stamped).?.draft.insert_text);
}

test "typed handlers imply accessibility actions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.column(.{}, .{
        ui.el(.segmented_control, .{ .on_press = .add }, .{}),
        ui.el(.segmented_control, .{}, .{}),
    }));

    // A command-less segmented control with a typed press handler exposes
    // the press action; without one it only exposes select.
    const with_handler = tree.root.children[0];
    const without_handler = tree.root.children[1];
    try testing.expect(canvas.semanticActions(with_handler).press);
    try testing.expect(!canvas.semanticActions(without_handler).press);
    try testing.expect(canvas.semanticActions(without_handler).select);
}

test "avatar and image sugar carry registered image ids" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.column(.{}, .{
        ui.avatar(.{ .image = 77, .semantics = .{ .label = "Native SDK" } }, "NS"),
        ui.avatar(.{}, "NS"),
        ui.image(.{ .image = 42, .semantics = .{ .label = "Chart" } }),
    }));

    // With an image id the avatar clips it to the circle (cover fit);
    // without one the initials text is the rendered fallback.
    const with_image = tree.root.children[0];
    try testing.expectEqual(canvas.WidgetKind.avatar, with_image.kind);
    try testing.expectEqual(@as(canvas.ImageId, 77), with_image.image_id);
    try testing.expectEqual(canvas.ImageFit.cover, with_image.image_fit);
    try testing.expectEqualStrings("NS", with_image.text);

    const fallback = tree.root.children[1];
    try testing.expectEqual(@as(canvas.ImageId, 0), fallback.image_id);
    try testing.expectEqualStrings("NS", fallback.text);

    const image_leaf = tree.root.children[2];
    try testing.expectEqual(canvas.WidgetKind.image, image_leaf.kind);
    try testing.expectEqual(@as(canvas.ImageId, 42), image_leaf.image_id);
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

    // on_scroll builds a message from the post-scroll state; widgets
    // without one dispatch nothing.
    const scroll_tree = blk: {
        var other_ui = InboxUi.init(arena_state.allocator());
        break :blk try other_ui.finalize(other_ui.scroll(
            .{ .on_scroll = InboxUi.scrollMsg(.feed_scrolled) },
            other_ui.text(.{}, "Row"),
        ));
    };
    const feed = findByKind(scroll_tree.root, .scroll_view).?;
    const scrolled = scroll_tree.msgForScroll(feed.id, .{
        .offset = 64,
        .viewport_extent = 72,
        .content_extent = 200,
    }).?.feed_scrolled;
    try testing.expectEqual(@as(f32, 64), scrolled.offset);
    try testing.expectEqual(@as(f32, 128), scrolled.maxOffset());
    try testing.expectEqual(@as(?Msg, null), tree.msgForScroll(slider.id, .{}));

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

test "text wrap opt-in becomes a single-span paragraph at finalize" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const content = "A long error message that should wrap instead of clipping on one line";
    const wrapped = ui.text(.{ .wrap = true }, content);
    const plain = ui.text(.{}, content);
    const tree = try ui.finalize(ui.column(.{}, .{ wrapped, plain }));

    const wrapped_widget = tree.root.children[0];
    try testing.expectEqual(@as(usize, 1), wrapped_widget.spans.len);
    // The span invariant: span text subslices widget.text, so retained
    // copies rebase instead of duplicating bytes.
    try testing.expectEqualStrings(content, wrapped_widget.text);
    try testing.expect(wrapped_widget.spans[0].text.ptr == wrapped_widget.text.ptr);
    try testing.expectEqual(content.len, wrapped_widget.spans[0].text.len);

    // Default stays the classic single-line path, byte-identical.
    const plain_widget = tree.root.children[1];
    try testing.expectEqual(@as(usize, 0), plain_widget.spans.len);
    try testing.expect(!plain_widget.text_no_wrap);
    try testing.expect(!wrapped_widget.text_no_wrap);
}

test "explicit wrap=false stamps the honest single-line text mode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const content = "A list-row title that must stay on one line however narrow the row gets";
    const tree = try ui.finalize(ui.column(.{}, .{
        ui.text(.{ .wrap = false }, content),
        ui.text(.{}, content),
    }));

    // wrap=false keeps the plain text path (no spans) and stamps the
    // no-wrap paint mode; the unset default stays untouched.
    const no_wrap_widget = tree.root.children[0];
    try testing.expectEqual(@as(usize, 0), no_wrap_widget.spans.len);
    try testing.expect(no_wrap_widget.text_no_wrap);
    try testing.expectEqualStrings(content, no_wrap_widget.text);
    const plain_widget = tree.root.children[1];
    try testing.expect(!plain_widget.text_no_wrap);
}

test "no-wrap text paints one clipped line in a width-constrained row" {
    // The list-row overlap repro: a narrow column must never let the
    // title paint a second line over the sibling below. wrap=false must
    // keep single-line measurement AND emit a single `.none` text run;
    // overflow="clip" (the explicit opt-out of the ellipsis default)
    // clips it to the received frame.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const content = "A long issue title that is much wider than the narrow row it sits in";
    const tree = try ui.finalize(ui.column(.{ .width = 160 }, .{
        ui.text(.{ .wrap = false, .overflow = .clip }, content),
        ui.text(.{}, "Below"),
    }));

    var layout_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 160, 400), &layout_nodes);

    const title = tree.root.children[0];
    const below = tree.root.children[1];
    var title_frame: ?geometry.RectF = null;
    var below_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.widget.id == title.id) title_frame = node.frame;
        if (node.widget.id == below.id) below_frame = node.frame;
    }
    // Measurement stays single-line in the constrained path: the title
    // reserves one line and the sibling sits below without overlap.
    try testing.expectEqual(title_frame.?.height, below_frame.?.height);
    try testing.expect(below_frame.?.y >= title_frame.?.y + title_frame.?.height);

    // Paint agrees: one `.none`-wrapped text run for the title, clipped
    // to the frame it received.
    var storage: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&storage);
    try canvas.emitWidgetLayout(&builder, layout, .{});
    const list = builder.displayList();
    var found_title = false;
    var clip_depth: usize = 0;
    var title_clipped = false;
    var clip_rect: ?geometry.RectF = null;
    for (list.commands) |command| {
        switch (command) {
            .push_clip => |clip| {
                clip_depth += 1;
                clip_rect = clip.rect;
            },
            .pop_clip => clip_depth -= 1,
            .draw_text => |text| {
                if (std.mem.eql(u8, text.text, content)) {
                    found_title = true;
                    try testing.expectEqual(canvas.TextWrap.none, text.text_layout.?.wrap);
                    title_clipped = clip_depth > 0;
                }
            },
            else => {},
        }
    }
    try testing.expect(found_title);
    try testing.expect(title_clipped);
    // The clip is the title's own frame — the clean-clip truncation.
    try testing.expectEqual(title_frame.?.width, clip_rect.?.width);
}

test "wrapped text reserves its wrapped height in a definite-width pane" {
    // A chat-pane repro shape end-to-end: a 360px pane with a long wrapped
    // text. The pane stays 360 wide, and the text lays out over multiple
    // lines whose height the column layout reserves.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const content = "This is a long single-line status message that lays out much wider than the pane it sits in and should wrap onto several lines";
    const tree = try ui.finalize(ui.row(.{}, .{
        ui.column(.{ .width = 360 }, .{
            ui.text(.{ .wrap = true }, content),
            ui.text(.{}, "Below"),
        }),
        ui.column(.{ .grow = 1 }, .{}),
    }));

    var layout_nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 800, 400), &layout_nodes);

    const pane = tree.root.children[0];
    const pane_frame = blk: {
        for (layout.nodes) |node| {
            if (node.widget.id == pane.id) break :blk node.frame;
        }
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(f32, 360), pane_frame.width);

    const wrapped = pane.children[0];
    const below = pane.children[1];
    var wrapped_frame: ?geometry.RectF = null;
    var below_frame: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.widget.id == wrapped.id) wrapped_frame = node.frame;
        if (node.widget.id == below.id) below_frame = node.frame;
    }
    // Multiple lines reserved: the wrapped text is taller than the
    // single-line sibling, which sits below it rather than overlapping.
    try testing.expect(wrapped_frame.?.height > below_frame.?.height);
    try testing.expect(below_frame.?.y >= wrapped_frame.?.y + wrapped_frame.?.height);
}

test "explicit sizes are definite except on resizable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.column(.{}, .{
        ui.el(.panel, .{ .width = 240, .height = 40 }, .{}),
        // Resizable keeps width as the initial/min width only: the engine's
        // drag handle writes larger frames past it.
        ui.el(.resizable, .{ .width = 240 }, .{}),
    }));

    const panel = tree.root.children[0];
    try testing.expectEqual(@as(f32, 240), panel.layout.min_size.width);
    try testing.expectEqual(@as(f32, 240), panel.layout.max_size.width);
    try testing.expectEqual(@as(f32, 40), panel.layout.min_size.height);
    try testing.expectEqual(@as(f32, 40), panel.layout.max_size.height);

    const resizable = tree.root.children[1];
    try testing.expectEqual(@as(f32, 240), resizable.layout.min_size.width);
    try testing.expectEqual(@as(f32, 0), resizable.layout.max_size.width);
}

test "opacity and transform flow to the widget with identity defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.column(.{}, .{
        ui.el(.panel, .{ .transform = canvas.Affine.translate(8, 4), .opacity = 0.5 }, .{
            ui.text(.{}, "Slide"),
        }),
        ui.el(.panel, .{}, .{}),
    }));

    const moved = tree.root.children[0];
    try testing.expectEqualDeep(canvas.Affine.translate(8, 4), moved.transform);
    try testing.expectEqual(@as(f32, 0.5), moved.opacity);

    const still = tree.root.children[1];
    try testing.expectEqualDeep(canvas.Affine.identity(), still.transform);
    try testing.expectEqual(@as(f32, 1), still.opacity);
}

test "builder transform and opacity wrap the emitted display list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(
        ui.el(.stack, .{ .transform = canvas.Affine.translate(8, 4), .opacity = 0.5 }, .{
            ui.text(.{ .frame = geometry.RectF.init(0, 0, 80, 20) }, "Slide"),
        }),
    );

    var commands: [8]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, tree.root, .{});
    const display_list = builder.displayList();
    try testing.expectEqual(@as(usize, 5), display_list.commandCount());
    switch (display_list.commands[0]) {
        .push_opacity => |opacity| try testing.expectEqual(@as(f32, 0.5), opacity),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .transform => |transform| try testing.expectEqualDeep(canvas.Affine.translate(8, 4), transform),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try testing.expectEqualStrings("Slide", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .transform => |transform| try testing.expectEqualDeep(canvas.Affine.translate(-8, -4), transform),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(display_list.commands[4] == .pop_opacity);
}

// ------------------------------------------------------------ components

fn countKindIn(widget: canvas.Widget, kind: canvas.WidgetKind) usize {
    var count: usize = if (widget.kind == kind) 1 else 0;
    for (widget.children) |child| count += countKindIn(child, kind);
    return count;
}

fn findSemanticsLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findSemanticsLabel(child, label)) |found| return found;
    }
    return null;
}

test "stepper derives completed/active/pending states from the active index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const steps = [_]InboxUi.StepperStep{
        .{ .label = "Work" },
        .{ .label = "Triage" },
        .{ .label = "Review" },
        .{ .label = "Fix" },
        .{ .label = "Ready" },
    };
    const tree = try ui.finalize(ui.stepper(.{ .active = 2 }, &steps));

    // Root is a list; five listitems joined by four connectors.
    try testing.expectEqual(canvas.WidgetRole.list, tree.root.semantics.role);
    try testing.expectEqual(@as(usize, 4), countKindIn(tree.root, .separator));
    try testing.expectEqual(@as(usize, 9), tree.root.children.len);

    const done = findSemanticsLabel(tree.root, "Work (completed)").?;
    try testing.expectEqual(canvas.WidgetRole.listitem, done.semantics.role);
    try testing.expect(!done.state.selected);
    const done_badge = findByKind(done, .badge).?;
    // Completed steps wear the vector check icon, not the ✓ text glyph
    // (outside the bundled face's coverage — tofu on reference paths).
    try testing.expectEqualStrings("check", done_badge.icon);
    try testing.expectEqualStrings("", done_badge.text);
    try testing.expectEqual(canvas.WidgetVariant.primary, done_badge.variant);

    const active = findSemanticsLabel(tree.root, "Review (active)").?;
    try testing.expect(active.state.selected);
    try testing.expectEqual(@as(u32, 2), active.semantics.list_item_index.?);
    try testing.expectEqual(@as(u32, 5), active.semantics.list_item_count.?);
    const active_badge = findByKind(active, .badge).?;
    try testing.expectEqualStrings("3", active_badge.text);
    try testing.expectEqual(canvas.WidgetVariant.primary, active_badge.variant);
    // Active label is a bold span paragraph.
    const active_label = active.children[1];
    try testing.expectEqual(canvas.TextSpanWeight.bold, active_label.spans[0].weight);

    const pending = findSemanticsLabel(tree.root, "Fix (pending)").?;
    const pending_badge = findByKind(pending, .badge).?;
    try testing.expectEqualStrings("4", pending_badge.text);
    try testing.expectEqual(canvas.WidgetVariant.outline, pending_badge.variant);

    // active past the end marks every step completed.
    var ui2 = InboxUi.init(arena_state.allocator());
    const tree2 = try ui2.finalize(ui2.stepper(.{ .active = steps.len }, &steps));
    try testing.expect(findSemanticsLabel(tree2.root, "Ready (completed)") != null);
}

test "timeline items compose indicator, content, chevron, and a root press" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ui = InboxUi.init(arena_state.allocator());
    const tree = try ui.finalize(ui.timeline(.{ .gap = 4 }, .{
        ui.timelineItem(.{
            .key = ui_model.uiKey(1),
            .variant = .primary,
            .title = "Coder finished",
            .description = "Implemented the fix and updated tests.",
            .meta = "claude · sonnet · 1m 12s",
            .on_press = Msg{ .toggle = 7 },
        }),
        ui.timelineItem(.{
            .key = ui_model.uiKey(2),
            .icon = "x",
            .variant = .destructive,
            .title = "Review failed",
            .connector = false,
        }),
    }));

    try testing.expectEqual(canvas.WidgetRole.list, tree.root.semantics.role);
    const first = tree.root.children[0];
    // Pressable: the press binds to the item's root stack (no overlay, no
    // duplicated handlers) — the bound handler makes the stack a hit
    // target and presses on the content fall through to it.
    try testing.expectEqual(canvas.WidgetKind.stack, first.kind);
    try testing.expectEqual(canvas.WidgetRole.listitem, first.semantics.role);
    try testing.expect(first.semantics.focusable);
    try testing.expect(first.semantics.actions.press);
    try testing.expect(canvas.widgetIsHitTarget(first));
    try testing.expect(canvas.widgetClaimsPress(first));
    try testing.expectEqualStrings("Coder finished", first.semantics.label);
    const msg = tree.msgForPointer(first.id, .up).?;
    try testing.expectEqual(@as(u32, 7), msg.toggle);
    // No empty-text press overlay remains anywhere in the item.
    try testing.expectEqual(@as(usize, 1), first.children.len);

    // Indicator dot badge, connector separator, muted description + meta,
    // trailing chevron.
    const badge = findByKind(first, .badge).?;
    try testing.expectEqual(canvas.WidgetVariant.primary, badge.variant);
    try testing.expectEqual(@as(f32, 10), badge.layout.min_size.width);
    try testing.expectEqual(@as(usize, 1), countKindIn(first, .separator));
    try testing.expect(findSemanticsLabel(first, "Coder finished") != null);
    const chevron = findKindText(first, "›");
    try testing.expect(chevron != null);
    const description = findTextContaining(first, "Implemented the fix");
    try testing.expect(description.?.spans.len == 1); // wrap opt-in span
    const meta = findTextContaining(first, "claude · sonnet");
    try testing.expectEqual(canvas.TextSpanColor.text_muted, meta.?.spans[0].color.?);

    // Non-pressable: not a press claimer, no chevron, no connector.
    const second = tree.root.children[1];
    try testing.expectEqual(@as(usize, 1), second.children.len);
    try testing.expectEqual(canvas.WidgetRole.listitem, second.semantics.role);
    try testing.expect(!second.semantics.focusable);
    try testing.expect(findKindText(second, "›") == null);
    try testing.expectEqual(@as(usize, 0), countKindIn(second, .separator));
    const badge2 = findByKind(second, .badge).?;
    // The failure indicator rides the vector icon channel — the ✗ text
    // glyph is outside the bundled face's coverage.
    try testing.expectEqualStrings("x", badge2.icon);
    try testing.expectEqual(@as(f32, 0), badge2.layout.min_size.width);
}

fn findKindText(widget: canvas.Widget, content: []const u8) ?canvas.Widget {
    if (widget.kind == .text and std.mem.eql(u8, widget.text, content)) return widget;
    for (widget.children) |child| {
        if (findKindText(child, content)) |found| return found;
    }
    return null;
}

fn findTextContaining(widget: canvas.Widget, fragment: []const u8) ?canvas.Widget {
    if (widget.kind == .text and std.mem.indexOf(u8, widget.text, fragment) != null) return widget;
    for (widget.children) |child| {
        if (findTextContaining(child, fragment)) |found| return found;
    }
    return null;
}

test "nav mounts the active page with stable position-derived identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Pane = struct {
        fn view(ui: *InboxUi, active: usize, retain: bool) InboxUi.Node {
            return ui.nav(.{ .active = active, .retain = retain }, .{
                ui.scroll(.{}, .{ui.text(.{}, "ledger")}),
                ui.scroll(.{}, .{ui.text(.{}, "transcript")}),
            });
        }
    };

    // Unmounted mode: only the active page is in the tree.
    var first_ui = InboxUi.init(arena);
    const first = try first_ui.finalize(Pane.view(&first_ui, 0, false));
    try testing.expectEqual(canvas.WidgetRole.group, first.root.semantics.role);
    try testing.expectEqual(@as(usize, 1), first.root.children.len);
    try testing.expect(findTextContaining(first.root, "ledger") != null);
    try testing.expect(findTextContaining(first.root, "transcript") == null);

    var second_ui = InboxUi.init(arena);
    const second = try second_ui.finalize(Pane.view(&second_ui, 1, false));
    try testing.expect(findTextContaining(second.root, "transcript") != null);
    // Pages carry position-derived keys, so page 2's scroll id differs from
    // page 1's even though each is the sole child of the nav stack.
    try testing.expect(first.root.children[0].id != second.root.children[0].id);

    // A page's id is stable whether it is the active page or a retained
    // hidden one — engine scroll/text state reconciles by that id.
    var retained_ui = InboxUi.init(arena);
    const retained = try retained_ui.finalize(Pane.view(&retained_ui, 1, true));
    try testing.expectEqual(@as(usize, 2), retained.root.children.len);
    try testing.expectEqual(first.root.children[0].id, retained.root.children[0].id);
    try testing.expectEqual(second.root.children[0].id, retained.root.children[1].id);
    // Inactive retained pages are hidden (excluded from render, hit
    // testing, focus, and semantics); the active page is not.
    try testing.expect(retained.root.children[0].semantics.hidden);
    try testing.expect(!retained.root.children[1].semantics.hidden);

    // Out-of-range active clamps to the last page.
    var clamped_ui = InboxUi.init(arena);
    const clamped = try clamped_ui.finalize(Pane.view(&clamped_ui, 9, false));
    try testing.expect(findTextContaining(clamped.root, "transcript") != null);
}

test "nav min_width declares the pane root's layout floor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Split panes clamp against the pane ROOT's min_size; a chat/detail
    // pane commonly roots in ui.nav, so the nav must be able to declare
    // its own floor instead of stamping
    // widget.layout.min_size.width post-build.
    var ui = InboxUi.init(arena);
    const tree = try ui.finalize(ui.nav(.{ .active = 0, .min_width = 360, .grow = 1 }, .{
        ui.scroll(.{}, .{ui.text(.{}, "chat")}),
    }));
    try testing.expectEqual(@as(f32, 360), tree.root.layout.min_size.width);

    // The empty-pages shape keeps the floor too.
    var empty_ui = InboxUi.init(arena);
    const empty = try empty_ui.finalize(empty_ui.nav(.{ .min_width = 240 }, .{}));
    try testing.expectEqual(@as(f32, 240), empty.root.layout.min_size.width);
}

test "wrap on a non-text element warns in Debug but never fails the build" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Same contract as the stacking-container gap warning: wrap is
    // text-leaf word wrapping only, rows never flow-wrap — the option on
    // a container is silently inert and shipped apps carry it, so the
    // diagnostic must stay a warning, never a
    // failure. Raise the test log threshold so the intentional warn stays
    // out of the test output.
    const saved_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log_level;

    var ui = InboxUi.init(arena);
    const tree = try ui.finalize(ui.row(.{ .wrap = true, .gap = 8 }, .{
        ui.text(.{}, "a"),
        ui.text(.{}, "b"),
    }));
    try testing.expectEqual(canvas.WidgetKind.row, tree.root.kind);

    // wrap on a plain text leaf keeps working (and stays quiet): it
    // becomes the single-span paragraph documented on ElementOptions.wrap.
    var text_ui = InboxUi.init(arena);
    const wrapped = try text_ui.finalize(text_ui.text(.{ .wrap = true }, "long message"));
    try testing.expectEqual(@as(usize, 1), wrapped.root.spans.len);
}

test "gap on a stacking container warns in Debug but never fails the build" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The warning content cannot be captured here (std.log has no test
    // seam); the predicate it keys on (canvas.widgetKindStacksChildren)
    // is kept honest by the lockstep test in ui_markup_view_tests.zig.
    // This test pins the compat contract: the diagnostic path runs and
    // the build still succeeds — shipped apps carry this mistake, so it
    // must stay a warning, never a failure. Raise the test log threshold
    // so the intentional warn stays out of the test output.
    const saved_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log_level;

    var ui = InboxUi.init(arena);
    const tree = try ui.finalize(ui.panel(.{ .gap = 8 }, .{
        ui.text(.{}, "a"),
        ui.text(.{}, "b"),
    }));
    try testing.expectEqual(canvas.WidgetKind.panel, tree.root.kind);
    try testing.expectEqual(@as(f32, 8), tree.root.layout.gap);
    try testing.expectEqual(@as(usize, 2), tree.root.children.len);
}

// ------------------------------------------------- press fall-through

fn layoutCenterById(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId) geometry.PointF {
    const node = layout.findById(id).?;
    return node.frame.normalized().center();
}

test "presses on plain text fall through to the nearest pressable ancestor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = InboxUi.init(arena_state.allocator());

    // The notes/soundboard row shape: a pressable panel whose visible
    // content is plain text. No empty-text overlay, no duplicated
    // handlers — the press falls through the text to the panel.
    const tree = try ui.finalize(ui.column(.{ .gap = 8 }, .{
        ui.panel(.{ .on_press = Msg{ .toggle = 1 }, .height = 48 }, .{
            ui.row(.{ .gap = 8, .padding = 8 }, .{
                ui.text(.{ .grow = 1 }, "Ship the IR"),
                ui.button(.{ .on_press = Msg{ .toggle = 99 } }, "Go"),
            }),
        }),
        // Nested pressables: the deepest pressable wins.
        ui.panel(.{ .on_press = Msg{ .toggle = 2 }, .height = 48 }, .{
            ui.panel(.{ .on_press = Msg{ .toggle = 3 }, .height = 24 }, .{
                ui.text(.{}, "Inner"),
            }),
        }),
    }));

    var layout_nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 400, 300), &layout_nodes);

    const outer_row_panel = tree.root.children[0];
    const text_id = findByKind(outer_row_panel, .text).?.id;
    const button_id = findByKind(outer_row_panel, .button).?.id;
    const inner_panel = tree.root.children[1].children[0];
    const inner_text_id = findByKind(inner_panel, .text).?.id;

    // 1. A press on the plain text lands on the pressable row panel.
    const text_hit = layout.hitTest(layoutCenterById(layout, text_id)).?;
    try testing.expectEqual(text_id, text_hit.id);
    const row_press = canvas.widgetPressTargetForHit(layout, text_hit).?;
    try testing.expectEqual(outer_row_panel.id, row_press.id);
    try testing.expectEqual(@as(u32, 1), tree.msgForPointer(row_press.id, .up).?.toggle);

    // 2. A button inside the row claims its own press — the button wins.
    const button_hit = layout.hitTest(layoutCenterById(layout, button_id)).?;
    try testing.expectEqual(button_id, button_hit.id);
    const button_press = canvas.widgetPressTargetForHit(layout, button_hit).?;
    try testing.expectEqual(button_id, button_press.id);
    try testing.expectEqual(@as(u32, 99), tree.msgForPointer(button_press.id, .up).?.toggle);

    // 3. Nested pressables: the deepest pressable ancestor wins.
    const inner_hit = layout.hitTest(layoutCenterById(layout, inner_text_id)).?;
    const inner_press = canvas.widgetPressTargetForHit(layout, inner_hit).?;
    try testing.expectEqual(inner_panel.id, inner_press.id);
    try testing.expectEqual(@as(u32, 3), tree.msgForPointer(inner_press.id, .up).?.toggle);
}

test "editable text and overlay surfaces stop the press fall-through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = InboxUi.init(arena_state.allocator());

    const tree = try ui.finalize(ui.column(.{ .gap = 8 }, .{
        // A text field inside a pressable panel: a click places the
        // caret; it must never activate the panel.
        ui.panel(.{ .on_press = Msg{ .toggle = 1 }, .height = 56 }, .{
            ui.textField(.{ .placeholder = "Type here", .grow = 1 }),
        }),
        // A dialog inside a pressable panel: clicks inside the surface
        // must never activate what it covers.
        ui.panel(.{ .on_press = Msg{ .toggle = 2 }, .height = 96 }, .{
            ui.el(.dialog, .{ .height = 64 }, .{
                ui.text(.{}, "Body copy"),
            }),
        }),
    }));

    var layout_nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 400, 300), &layout_nodes);

    const field_id = findByKind(tree.root, .text_field).?.id;
    const field_hit = layout.hitTest(layoutCenterById(layout, field_id)).?;
    const field_press = canvas.widgetPressTargetForHit(layout, field_hit).?;
    try testing.expectEqual(field_id, field_press.id);
    try testing.expectEqual(@as(?Msg, null), tree.msgForPointer(field_press.id, .up));

    const body_id = findByKind(tree.root.children[1], .text).?.id;
    const body_hit = layout.hitTest(layoutCenterById(layout, body_id)).?;
    const body_press = canvas.widgetPressTargetForHit(layout, body_hit).?;
    try testing.expectEqual(canvas.WidgetKind.dialog, body_press.kind);
    try testing.expectEqual(@as(?Msg, null), tree.msgForPointer(body_press.id, .up));
}

test "a bound press handler makes layout containers hit targets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = InboxUi.init(arena_state.allocator());

    // The timeline-item shape: a pressable stack/row without panel
    // chrome. The bound handler makes the container a widget-level hit
    // target, so both bare-container clicks and fall-through clicks on
    // its text land on it.
    const tree = try ui.finalize(ui.column(.{}, .{
        ui.row(.{ .on_press = Msg{ .toggle = 7 }, .height = 40, .gap = 8 }, .{
            ui.text(.{}, "Row label"),
        }),
    }));

    const row = tree.root.children[0];
    try testing.expect(row.semantics.actions.press);
    try testing.expect(canvas.widgetIsHitTarget(row));
    try testing.expect(canvas.widgetClaimsPress(row));

    var layout_nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 400, 300), &layout_nodes);

    // Click on the label: falls through to the row.
    const text_id = findByKind(row, .text).?.id;
    const text_hit = layout.hitTest(layoutCenterById(layout, text_id)).?;
    try testing.expectEqual(row.id, canvas.widgetPressTargetForHit(layout, text_hit).?.id);

    // Click on the bare row area (right of the text): hits the row
    // directly now that the handler made it a hit target.
    const row_frame = layout.findById(row.id).?.frame.normalized();
    const bare_point = geometry.PointF.init(row_frame.maxX() - 4, row_frame.center().y);
    const bare_hit = layout.hitTest(bare_point).?;
    try testing.expectEqual(row.id, bare_hit.id);
    try testing.expectEqual(@as(u32, 7), tree.msgForPointer(row.id, .up).?.toggle);
}

test "chart builder copies, downsamples, and summarizes series" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = InboxUi.init(arena_state.allocator());

    // A 10k-point series (the star-history shape) plus a sparkline.
    const big = try testing.allocator.alloc(f32, 10_000);
    defer testing.allocator.free(big);
    for (big, 0..) |*value, index| value.* = @floatFromInt(index);
    var small = [_]f32{ 0.25, 0.5, 0.75 };

    const node = ui.chart(.{ .width = 240, .height = 64, .y_min = 0 }, &.{
        .{ .kind = .line, .values = big, .fill = true, .color = .accent, .label = "stars" },
        .{ .kind = .bar, .values = &small, .color = .info, .label = "cpu" },
    });
    const tree = try ui.finalize(node);

    // Series copied into the arena and bounded by the downsampling cap;
    // clobbering the caller buffer must not reach the stored points.
    small[0] = 9;
    const stored = tree.root.chart.series;
    try testing.expectEqual(@as(usize, 2), stored.len);
    try testing.expectEqual(canvas.max_chart_points_per_series, stored[0].values.len);
    try testing.expectEqualSlices(f32, &.{ 0.25, 0.5, 0.75 }, stored[1].values);
    // Deterministic decimation keeps the true extremes of a ramp.
    try testing.expectEqual(@as(f32, 0), stored[0].values[0]);
    try testing.expectEqual(@as(f32, 9999), stored[0].values[stored[0].values.len - 1]);
    try testing.expectEqual(@as(?f32, 0), tree.root.chart.y_min);

    // The generated summary describes the SOURCE series so automation
    // asserts on what the app handed over.
    try testing.expectEqualStrings(
        "chart: stars 10000 pts last 9999.00; cpu 3 pts last 0.75",
        tree.root.semantics.label,
    );

    // Display-only: a chart is not a hit target and never claims a press.
    try testing.expect(!canvas.widgetKindHitTarget(.chart));
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 240, 64), &nodes);
    try testing.expect(layout.hitTest(geometry.PointF.init(120, 32)) == null);

    // An explicit semantics label wins over the generated summary.
    var labeled_ui = InboxUi.init(arena_state.allocator());
    const labeled = try labeled_ui.finalize(labeled_ui.chart(.{
        .semantics = .{ .label = "CPU history" },
    }, &.{.{ .kind = .line, .values = &small }}));
    try testing.expectEqualStrings("CPU history", labeled.root.semantics.label);
}

// -------------------------------------------------- windowed virtual lists

const feed_options = InboxUi.VirtualListOptions{
    .id = "feed",
    .item_count = 100_000,
    .item_extent = 25,
    .overscan = 2,
    .grow = 1,
    .on_scroll = InboxUi.scrollMsg(.feed_scrolled),
    .on_reach_end = .load_more,
};

fn feedRow(ui: *InboxUi, index: usize) InboxUi.Node {
    var node = ui.listItem(.{}, ui.fmt("Item {d}", .{index}));
    node.key = .{ .int = @intCast(index) };
    return node;
}

fn buildFeed(ui: *InboxUi, window: canvas.VirtualListRange) !InboxUi.Tree {
    const rows = try ui.arena.alloc(InboxUi.Node, window.itemCount());
    for (rows, 0..) |*row, offset| row.* = feedRow(ui, window.start_index + offset);
    return ui.finalize(ui.virtualList(feed_options, window, .{rows}));
}

/// A window source pinned to one scroll state, the shape `UiApp`
/// installs from the retained layout.
const FixedWindowSource = struct {
    state: canvas.VirtualWindowState,

    fn resolve(context: ?*anyopaque, id: canvas.ObjectId) ?canvas.VirtualWindowState {
        _ = id;
        const self: *FixedWindowSource = @ptrCast(@alignCast(context.?));
        return self.state;
    }
};

test "virtualWindow resolves the runtime state and virtualList builds only the window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = InboxUi.init(arena_state.allocator());

    // Scrolled to item 1000 (offset 25_000) in a 90-point viewport.
    var source = FixedWindowSource{ .state = .{ .offset = 25_000, .viewport_extent = 90 } };
    ui.virtual_window_context = @ptrCast(&source);
    ui.virtual_window_source = FixedWindowSource.resolve;

    const window = ui.virtualWindow(feed_options);
    try testing.expectEqual(@as(usize, 998), window.start_index);
    try testing.expectEqual(@as(usize, 1006), window.end_index);
    try testing.expectEqual(@as(usize, 1000), window.first_visible_index);

    const tree = try buildFeed(&ui, window);

    // The container: a runtime-scrolled virtual list under its declared
    // global identity, with the window's slice stamped on the layout.
    try testing.expect(canvas.widgetVirtualRuntimeScrolled(tree.root));
    try testing.expectEqual(canvas.globalWidgetId(.scroll_view, .{ .str = "feed" }), tree.root.id);
    try testing.expectEqual(@as(usize, 100_000), tree.root.layout.virtual_item_count);
    try testing.expectEqual(@as(usize, 998), tree.root.layout.virtual_first_index);
    try testing.expectEqual(@as(f32, 25), tree.root.layout.virtual_item_extent);
    try testing.expectEqual(@as(usize, 2), tree.root.layout.virtual_overscan);
    try testing.expectEqual(window.layout_offset, tree.root.value);
    try testing.expectEqual(@as(usize, 8), tree.root.children.len);

    // The build records its window for the app loop.
    const records = ui.virtualWindows();
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expectEqual(tree.root.id, records[0].id);
    try testing.expectEqual(@as(usize, 998), records[0].start_index);
    try testing.expectEqual(@as(usize, 1006), records[0].end_index);
    try testing.expectEqual(@as(usize, 100_000), records[0].item_count);

    // Typed dispatch: the scroll observation and the approach-end signal
    // both resolve through the container's handlers.
    const state = canvas.ScrollState{ .offset = 25_000, .viewport_extent = 90, .content_extent = 2_499_975 };
    try testing.expectEqual(@as(f32, 25_000), tree.msgForScroll(tree.root.id, state).?.feed_scrolled.offset);
    try testing.expectEqual(Msg.load_more, tree.msgForReachEnd(tree.root.id).?);
}

test "virtual list row identity is stable across window shifts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Window A: items 998..1006.
    var ui_a = InboxUi.init(arena_state.allocator());
    var source_a = FixedWindowSource{ .state = .{ .offset = 25_000, .viewport_extent = 90 } };
    ui_a.virtual_window_context = @ptrCast(&source_a);
    ui_a.virtual_window_source = FixedWindowSource.resolve;
    const tree_a = try buildFeed(&ui_a, ui_a.virtualWindow(feed_options));

    // Window B: scrolled ~two rows on — items 1000..1008 overlap A.
    var ui_b = InboxUi.init(arena_state.allocator());
    var source_b = FixedWindowSource{ .state = .{ .offset = 25_050, .viewport_extent = 90 } };
    ui_b.virtual_window_context = @ptrCast(&source_b);
    ui_b.virtual_window_source = FixedWindowSource.resolve;
    const tree_b = try buildFeed(&ui_b, ui_b.virtualWindow(feed_options));

    // Item 1002 exists in both windows at DIFFERENT child positions, yet
    // its structural id is identical — engine-owned row state follows
    // the item across window shifts, and returns with it.
    const row_a = findByText(tree_a.root, "Item 1002").?;
    const row_b = findByText(tree_b.root, "Item 1002").?;
    try testing.expectEqual(row_a.id, row_b.id);

    // A row A built and B did not: present exactly once.
    try testing.expect(findByText(tree_a.root, "Item 998") != null);
    try testing.expect(findByText(tree_b.root, "Item 998") == null);
}

test "virtualWindow without a source falls back to the request viewport" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = InboxUi.init(arena_state.allocator());

    // No source installed (bare build): offset 0 at the fallback height.
    var options = feed_options;
    options.viewport_fallback = 100;
    const window = ui.virtualWindow(options);
    try testing.expectEqual(@as(usize, 0), window.start_index);
    try testing.expectEqual(@as(usize, 6), window.end_index);

    // And a zero fallback builds nothing — the honest "viewport unknown".
    options.viewport_fallback = 0;
    try testing.expect(ui.virtualWindow(options).isEmpty());
}


test "widget kind codes are pinned: assigned at birth, declaration-order-independent" {
    // The FULL golden table. `structuralId` hashes `widgetKindCode`, so
    // this table IS the id vocabulary persisted state references:
    // reordering the `WidgetKind` enum is free (the switch maps names,
    // and this test would still pass), but renumbering an existing kind
    // is a schema-version bump, never a silent edit — if a row here
    // changed, every retained id, automation target, and journal anchor
    // for that kind changed with it. New kinds append with the next
    // unused code.
    const expected = [_]struct { kind: canvas.WidgetKind, code: u16 }{
        .{ .kind = .stack, .code = 0 },
        .{ .kind = .row, .code = 1 },
        .{ .kind = .column, .code = 2 },
        .{ .kind = .grid, .code = 3 },
        .{ .kind = .data_grid, .code = 4 },
        .{ .kind = .table, .code = 5 },
        .{ .kind = .scroll_view, .code = 6 },
        .{ .kind = .list, .code = 7 },
        .{ .kind = .breadcrumb, .code = 8 },
        .{ .kind = .button_group, .code = 9 },
        .{ .kind = .pagination, .code = 10 },
        .{ .kind = .radio_group, .code = 11 },
        .{ .kind = .tabs, .code = 12 },
        .{ .kind = .toggle_group, .code = 13 },
        .{ .kind = .accordion, .code = 14 },
        .{ .kind = .bubble, .code = 15 },
        .{ .kind = .resizable, .code = 16 },
        .{ .kind = .alert, .code = 17 },
        .{ .kind = .card, .code = 18 },
        .{ .kind = .dialog, .code = 19 },
        .{ .kind = .drawer, .code = 20 },
        .{ .kind = .sheet, .code = 21 },
        .{ .kind = .panel, .code = 22 },
        .{ .kind = .popover, .code = 23 },
        .{ .kind = .menu_surface, .code = 24 },
        .{ .kind = .dropdown_menu, .code = 25 },
        .{ .kind = .text, .code = 26 },
        .{ .kind = .icon, .code = 27 },
        .{ .kind = .image, .code = 28 },
        .{ .kind = .avatar, .code = 29 },
        .{ .kind = .badge, .code = 30 },
        .{ .kind = .button, .code = 31 },
        .{ .kind = .toggle_button, .code = 32 },
        .{ .kind = .icon_button, .code = 33 },
        .{ .kind = .select, .code = 34 },
        .{ .kind = .input, .code = 35 },
        .{ .kind = .text_field, .code = 36 },
        .{ .kind = .search_field, .code = 37 },
        .{ .kind = .combobox, .code = 38 },
        .{ .kind = .textarea, .code = 39 },
        .{ .kind = .tooltip, .code = 40 },
        .{ .kind = .menu_item, .code = 41 },
        .{ .kind = .list_item, .code = 42 },
        .{ .kind = .data_row, .code = 43 },
        .{ .kind = .data_cell, .code = 44 },
        .{ .kind = .status_bar, .code = 45 },
        .{ .kind = .segmented_control, .code = 46 },
        .{ .kind = .checkbox, .code = 47 },
        .{ .kind = .radio, .code = 48 },
        .{ .kind = .switch_control, .code = 49 },
        .{ .kind = .toggle, .code = 50 },
        .{ .kind = .slider, .code = 51 },
        .{ .kind = .progress, .code = 52 },
        .{ .kind = .separator, .code = 53 },
        .{ .kind = .skeleton, .code = 54 },
        .{ .kind = .spinner, .code = 55 },
        .{ .kind = .chart, .code = 56 },
        .{ .kind = .split, .code = 57 },
        .{ .kind = .split_divider, .code = 58 },
        .{ .kind = .tree, .code = 59 },
        .{ .kind = .input_group, .code = 60 },
        .{ .kind = .media_surface, .code = 61 },
    };
    try testing.expectEqual(std.enums.values(canvas.WidgetKind).len, expected.len);
    for (expected) |entry| {
        try testing.expectEqual(entry.code, canvas.widgetKindCode(entry.kind));
    }
    // Uniqueness: two kinds sharing a code would collide ids structurally.
    for (std.enums.values(canvas.WidgetKind)) |left| {
        for (std.enums.values(canvas.WidgetKind)) |right| {
            if (left == right) continue;
            try testing.expect(canvas.widgetKindCode(left) != canvas.widgetKindCode(right));
        }
    }
}

test "structural id goldens: the id algorithm is pinned end to end" {
    // Exact ids for known (kind, key) pairs under the global seed. These
    // pin the WHOLE id recipe — seed, kind code, key-tag discipline,
    // zero-fallback — so any drift (a reorder that bypassed the code
    // table, a hash-input change) fails here before it silently orphans
    // retained state. The values predate the kind-code switch: codes were
    // frozen from the ordinals at the moment of the switch, so the switch
    // itself changed no ids.
    try testing.expectEqual(@as(canvas.ObjectId, 1758586856932284458), canvas.globalWidgetId(.button, canvas.uiKey(@as(u64, 7))));
    try testing.expectEqual(@as(canvas.ObjectId, 14648775719080514296), canvas.globalWidgetId(.text, canvas.uiKey("greeting")));
    try testing.expectEqual(@as(canvas.ObjectId, 10740830058688169295), canvas.globalWidgetId(.tree, .{ .index = 3 }));
    try testing.expectEqual(@as(canvas.ObjectId, 9835495177657875356), canvas.globalWidgetId(.split_divider, canvas.uiKey("divider")));
}

