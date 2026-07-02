const std = @import("std");
const canvas = @import("root.zig");
const markup_view = @import("ui_markup_view.zig");

const testing = std.testing;

const Filter = enum { all, active, done };

const Task = struct {
    id: u32,
    title_storage: [24]u8 = [_]u8{0} ** 24,
    title_len: usize = 0,
    done: bool = false,

    pub fn title(task: *const Task) []const u8 {
        return task.title_storage[0..task.title_len];
    }

    fn key(task: *const Task) canvas.UiKey {
        return canvas.uiKey(task.id);
    }
};

const Msg = union(enum) {
    add,
    toggle: u32,
    set_filter: Filter,
    draft: canvas.TextInputEvent,
};

const Model = struct {
    tasks: [8]Task = undefined,
    task_count: usize = 0,
    filter: Filter = .all,

    pub const filters = [_]Filter{ .all, .active, .done };

    fn addTask(model: *Model, text: []const u8, done: bool) void {
        var task = Task{ .id = @intCast(model.task_count + 1), .done = done };
        const len = @min(text.len, task.title_storage.len);
        @memcpy(task.title_storage[0..len], text[0..len]);
        task.title_len = len;
        model.tasks[model.task_count] = task;
        model.task_count += 1;
    }

    pub fn visible(model: *const Model, arena: std.mem.Allocator) []const Task {
        const out = arena.alloc(Task, model.task_count) catch return &.{};
        var len: usize = 0;
        for (model.tasks[0..model.task_count]) |task| {
            const keep = switch (model.filter) {
                .all => true,
                .active => !task.done,
                .done => task.done,
            };
            if (keep) {
                out[len] = task;
                len += 1;
            }
        }
        return out[0..len];
    }

    pub fn open_count(model: *const Model) usize {
        var open: usize = 0;
        for (model.tasks[0..model.task_count]) |task| open += @intFromBool(!task.done);
        return open;
    }
};

const InboxUi = canvas.Ui(Msg);
const InboxMarkup = markup_view.MarkupView(Model, Msg);

const inbox_markup_source =
    \\<column gap="12" padding="16">
    \\  <row gap="8" cross="center">
    \\    <text-field placeholder="New task…" on-input="draft" on-submit="add" grow="1" />
    \\    <button variant="primary" on-press="add">Add</button>
    \\  </row>
    \\  <row gap="8">
    \\    <for each="filters" as="f">
    \\      <button selected="{f == filter}" size="sm" on-press="set_filter:{f}">{f}</button>
    \\    </for>
    \\  </row>
    \\  <scroll grow="1">
    \\    <column gap="2">
    \\      <for each="visible" key="id" as="t">
    \\        <row gap="8" padding="6" cross="center">
    \\          <checkbox checked="{t.done}" on-toggle="toggle:{t.id}" />
    \\          <text grow="1">{t.title}</text>
    \\        </row>
    \\      </for>
    \\    </column>
    \\  </scroll>
    \\  <status-bar>{open_count} open</status-bar>
    \\</column>
;

/// The hand-written equivalent of the markup above; parity means the
/// interpreter builds exactly this tree.
fn handView(ui: *InboxUi, model: *const Model) InboxUi.Node {
    return ui.column(.{ .gap = 12, .padding = 16 }, .{
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.textField(.{ .placeholder = "New task…", .on_input = InboxUi.inputMsg(.draft), .on_submit = .add, .grow = 1 }),
            ui.button(.{ .variant = .primary, .on_press = .add }, "Add"),
        }),
        ui.row(.{ .gap = 8 }, filterNodes(ui, model)),
        ui.scroll(.{ .grow = 1 }, ui.column(.{ .gap = 2 }, ui.each(model.visible(ui.arena), Task.key, taskRow))),
        ui.statusBar(.{}, ui.fmt("{d} open", .{model.open_count()})),
    });
}

/// Filter buttons without explicit keys, matching the markup `for`
/// (sibling-index identity).
fn filterNodes(ui: *InboxUi, model: *const Model) []const InboxUi.Node {
    const nodes = ui.arena.alloc(InboxUi.Node, Model.filters.len) catch {
        ui.failed = true;
        return &.{};
    };
    for (Model.filters, 0..) |filter, index| {
        nodes[index] = ui.button(.{
            .size = .sm,
            .selected = filter == model.filter,
            .on_press = Msg{ .set_filter = filter },
        }, @tagName(filter));
    }
    return nodes;
}

fn taskRow(ui: *InboxUi, task: *const Task) InboxUi.Node {
    return ui.row(.{ .gap = 8, .padding = 6, .cross = .center }, .{
        ui.checkbox(.{ .checked = task.done, .on_toggle = Msg{ .toggle = task.id } }),
        ui.text(.{ .grow = 1 }, task.title()),
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

fn testModel() Model {
    var model = Model{};
    model.addTask("Ship IR", false);
    model.addTask("Write decisions", true);
    model.addTask("Hot reload", false);
    return model;
}

test "markup view builds the same tree as the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = testModel();

    var view = try InboxMarkup.init(arena, inbox_markup_source);
    var markup_ui = InboxUi.init(arena);
    const markup_tree = try markup_ui.finalize(try view.build(&markup_ui, &model));

    var hand_ui = InboxUi.init(arena);
    const hand_tree = try hand_ui.finalize(handView(&hand_ui, &model));

    // Identical structural ids, node for node.
    var markup_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer markup_ids.deinit(testing.allocator);
    var hand_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer hand_ids.deinit(testing.allocator);
    try collectIds(markup_tree.root, &markup_ids, testing.allocator);
    try collectIds(hand_tree.root, &hand_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, hand_ids.items, markup_ids.items);

    // Identical handler tables: same count, same dispatch results.
    try testing.expectEqual(hand_tree.handlers.len, markup_tree.handlers.len);
    const add_button = findByKind(markup_tree.root, .button).?;
    try testing.expectEqual(Msg.add, markup_tree.msgForPointer(add_button.id, .up).?);

    const hand_checkbox = findByKind(hand_tree.root, .checkbox).?;
    const markup_checkbox = findByKind(markup_tree.root, .checkbox).?;
    try testing.expectEqual(hand_checkbox.id, markup_checkbox.id);
    try testing.expectEqual(
        hand_tree.msgForPointer(hand_checkbox.id, .up).?,
        markup_tree.msgForPointer(markup_checkbox.id, .up).?,
    );

    // Text edits dispatch through the markup-declared on-input constructor.
    const text_field = findByKind(markup_tree.root, .text_field).?;
    const typed = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = "x" };
    try testing.expectEqualStrings("x", markup_tree.msgForKeyboard(text_field.id, typed).?.draft.insert_text);

    // Interpolation and state rendering match.
    try testing.expectEqualStrings("2 open", findByKind(markup_tree.root, .status_bar).?.text);
    try testing.expectEqualStrings(
        findByKind(hand_tree.root, .status_bar).?.text,
        findByKind(markup_tree.root, .status_bar).?.text,
    );
}

test "markup keyed rows keep ids across model changes and filters dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = testModel();
    var view = try InboxMarkup.init(arena, inbox_markup_source);

    var first_ui = InboxUi.init(arena);
    const first = try first_ui.finalize(try view.build(&first_ui, &model));
    const first_checkbox = findByKind(first.root, .checkbox).?;

    // Dispatch the done filter through a markup-built button.
    var done_msg: ?Msg = null;
    for (first.handlers) |handler| {
        if (handler.action == .message and handler.action.message == .set_filter) {
            if (handler.action.message.set_filter == .done) done_msg = handler.action.message;
        }
    }
    try testing.expectEqual(Filter.done, done_msg.?.set_filter);
    model.filter = done_msg.?.set_filter;

    var second_ui = InboxUi.init(arena);
    const second = try second_ui.finalize(try view.build(&second_ui, &model));

    // Only the done task remains, and it is a different task than the first
    // visible row was — keyed identity distinguishes them.
    const second_checkbox = findByKind(second.root, .checkbox).?;
    try testing.expect(first_checkbox.id != second_checkbox.id);
    try testing.expectEqual(@as(u32, 2), second.msgForPointer(second_checkbox.id, .up).?.toggle);

    // Back to all: the original first row returns with its original id.
    model.filter = .all;
    var third_ui = InboxUi.init(arena);
    const third = try third_ui.finalize(try view.build(&third_ui, &model));
    try testing.expectEqual(first_checkbox.id, findByKind(third.root, .checkbox).?.id);
}

test "markup build failures carry position and message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model{};

    const cases = [_][]const u8{
        "<column>\n  <bogus-element />\n</column>",
        "<column gap=\"{missing_binding}\" />",
        "<column>\n  <button on-press=\"unknown_msg\">X</button>\n</column>",
        "<column>\n  <button on-press=\"toggle\">X</button>\n</column>",
        "<column>\n  <for each=\"nope\" as=\"t\"><text>{t}</text></for>\n</column>",
        "<column bogus-attr=\"1\" />",
    };
    for (cases) |source| {
        var view = try InboxMarkup.init(arena, source);
        var ui = InboxUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expect(view.diagnostic.message.len > 0);
        try testing.expect(view.diagnostic.line > 0);
    }
}
