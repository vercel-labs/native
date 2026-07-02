const std = @import("std");
const canvas = @import("root.zig");
const markup_view = @import("ui_markup_view.zig");

const testing = std.testing;

pub const Filter = enum { all, active, done };

pub const Task = struct {
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

pub const Msg = union(enum) {
    add,
    toggle: u32,
    set_filter: Filter,
    draft: canvas.TextInputEvent,
};

pub const Model = struct {
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

pub const inbox_markup_source =
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
pub fn handView(ui: *InboxUi, model: *const Model) InboxUi.Node {
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

pub fn collectIds(widget: canvas.Widget, ids: *std.ArrayListUnmanaged(canvas.ObjectId), allocator: std.mem.Allocator) !void {
    try ids.append(allocator, widget.id);
    for (widget.children) |child| try collectIds(child, ids, allocator);
}

pub fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

pub fn testModel() Model {
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

// ------------------------------------------------ template/use fixture

pub const Fruit = struct {
    id: u32,
    name: []const u8,

    pub fn key(fruit: *const Fruit) canvas.UiKey {
        return canvas.uiKey(fruit.id);
    }
};

pub const TemplateMsg = union(enum) { pick: u32 };

pub const TemplateModel = struct {
    top: []const Fruit = &.{},
    bottom: []const Fruit = &.{},
};

/// Templates with a value arg (`title`) and a slice arg (`items`), a `for`
/// nested inside the template body iterating the slice arg, a nested
/// `<use>` whose arg binds a loop item field, and style token attributes.
pub const template_markup_source =
    \\<template name="fruit-pill" args="label">
    \\  <badge background="surface" radius="md">{label}</badge>
    \\</template>
    \\<template name="fruit-list" args="title items">
    \\  <column gap="4" label="{title}">
    \\    <text foreground="text_muted">{title}</text>
    \\    <for each="items" key="id" as="f">
    \\      <row gap="2">
    \\        <use template="fruit-pill" label="{f.name}" />
    \\        <button on-press="pick:{f.id}">{f.name}</button>
    \\      </row>
    \\    </for>
    \\  </column>
    \\</template>
    \\<row gap="8">
    \\  <use template="fruit-list" title="Top" items="{top}" />
    \\  <use template="fruit-list" title="Bottom" items="{bottom}" />
    \\</row>
;

pub const TemplateUi = canvas.Ui(TemplateMsg);

/// The hand-written equivalent of the template markup: expansion happens
/// at the use site, so ids and handlers must match this exactly.
pub fn handTemplateView(ui: *TemplateUi, model: *const TemplateModel) TemplateUi.Node {
    return ui.row(.{ .gap = 8 }, .{
        fruitColumn(ui, "Top", model.top),
        fruitColumn(ui, "Bottom", model.bottom),
    });
}

fn fruitColumn(ui: *TemplateUi, title: []const u8, items: []const Fruit) TemplateUi.Node {
    return ui.column(.{ .gap = 4, .semantics = .{ .label = title } }, .{
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, title),
        ui.each(items, Fruit.key, fruitRow),
    });
}

fn fruitRow(ui: *TemplateUi, fruit: *const Fruit) TemplateUi.Node {
    var badge = ui.el(.badge, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{});
    badge.widget.text = fruit.name;
    return ui.row(.{ .gap = 2 }, .{
        badge,
        ui.button(.{ .on_press = TemplateMsg{ .pick = fruit.id } }, fruit.name),
    });
}

pub fn templateTestModel() TemplateModel {
    return .{
        .top = &[_]Fruit{ .{ .id = 1, .name = "apple" }, .{ .id = 2, .name = "pear" } },
        .bottom = &[_]Fruit{.{ .id = 7, .name = "plum" }},
    };
}

pub fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

test "template expansion builds the hand-written tree with ids from the expansion site" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = templateTestModel();
    const TemplateMarkup = markup_view.MarkupView(TemplateModel, TemplateMsg);

    var view = try TemplateMarkup.init(arena, template_markup_source);
    var markup_ui = TemplateUi.init(arena);
    const markup_tree = try markup_ui.finalize(try view.build(&markup_ui, &model));

    var hand_ui = TemplateUi.init(arena);
    const hand_tree = try hand_ui.finalize(handTemplateView(&hand_ui, &model));

    var markup_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer markup_ids.deinit(testing.allocator);
    var hand_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer hand_ids.deinit(testing.allocator);
    try collectIds(markup_tree.root, &markup_ids, testing.allocator);
    try collectIds(hand_tree.root, &hand_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, hand_ids.items, markup_ids.items);
    try testing.expectEqual(hand_tree.handlers.len, markup_tree.handlers.len);

    // Value args flow into interpolation and semantics; message payloads
    // built from loop items inside the template dispatch normally.
    try testing.expect(findByText(markup_tree.root, .text, "Top") != null);
    try testing.expect(findByText(markup_tree.root, .badge, "plum") != null);
    const pear_button = findByText(markup_tree.root, .button, "pear").?;
    try testing.expectEqual(@as(u32, 2), markup_tree.msgForPointer(pear_button.id, .up).?.pick);

    // Two uses of the same template at different sites get different ids;
    // the same site is stable across rebuilds.
    const top_text = findByText(markup_tree.root, .text, "Top").?;
    const bottom_text = findByText(markup_tree.root, .text, "Bottom").?;
    try testing.expect(top_text.id != bottom_text.id);

    var rebuild_ui = TemplateUi.init(arena);
    const rebuilt = try rebuild_ui.finalize(try view.build(&rebuild_ui, &model));
    try testing.expectEqual(top_text.id, findByText(rebuilt.root, .text, "Top").?.id);
    try testing.expectEqual(pear_button.id, findByText(rebuilt.root, .button, "pear").?.id);
}

test "style token references resolve against tokens at finalize time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = templateTestModel();
    const TemplateMarkup = markup_view.MarkupView(TemplateModel, TemplateMsg);
    var view = try TemplateMarkup.init(arena, template_markup_source);

    // Plain finalize resolves against the default (light) tokens.
    var light_ui = TemplateUi.init(arena);
    const light = try light_ui.finalize(try view.build(&light_ui, &model));
    const light_tokens = canvas.DesignTokens{};
    const light_badge = findByText(light.root, .badge, "apple").?;
    try testing.expectEqualDeep(light_tokens.colors.surface, light_badge.style.background.?);
    try testing.expectEqual(light_tokens.radius.md, light_badge.style.radius.?);
    const light_text = findByText(light.root, .text, "Top").?;
    try testing.expectEqualDeep(light_tokens.colors.text_muted, light_text.style.foreground.?);

    // finalizeWithTokens re-resolves the same references against live
    // tokens: a theme change rebuilds into different concrete colors.
    var dark_ui = TemplateUi.init(arena);
    const dark_tokens = canvas.DesignTokens.theme(.{ .color_scheme = .dark });
    const dark = try dark_ui.finalizeWithTokens(try view.build(&dark_ui, &model), dark_tokens);
    const dark_badge = findByText(dark.root, .badge, "apple").?;
    try testing.expectEqualDeep(dark_tokens.colors.surface, dark_badge.style.background.?);
    try testing.expect(!std.meta.eql(light_badge.style.background.?, dark_badge.style.background.?));

    // Ids are independent of token resolution.
    try testing.expectEqual(light_badge.id, dark_badge.id);
}

test "explicit style values win over token references" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const explicit = canvas.Color.rgb8(1, 2, 3);
    var ui = TemplateUi.init(arena);
    const node = ui.el(.badge, .{
        .style = .{ .background = explicit },
        .style_tokens = .{ .background = .surface, .radius = .md },
    }, .{});
    const tree = try ui.finalize(node);
    try testing.expectEqualDeep(explicit, tree.root.style.background.?);
    try testing.expectEqual((canvas.DesignTokens{}).radius.md, tree.root.style.radius.?);
}

test "the style token name lists match the canvas token structs and the interpreter table" {
    // Every ColorTokens field is listed, and every listed name is a field.
    const color_fields = @typeInfo(canvas.ColorTokens).@"struct".fields;
    try testing.expectEqual(color_fields.len, canvas.ui_markup.known_color_token_names.len);
    inline for (color_fields) |field| {
        try testing.expect(nameListed(field.name, &canvas.ui_markup.known_color_token_names));
    }
    const radius_fields = @typeInfo(canvas.RadiusTokens).@"struct".fields;
    try testing.expectEqual(radius_fields.len, canvas.ui_markup.known_radius_token_names.len);
    inline for (radius_fields) |field| {
        try testing.expect(nameListed(field.name, &canvas.ui_markup.known_radius_token_names));
    }
    // The validator's attribute list matches the engines' shared table.
    try testing.expectEqual(markup_view.color_style_attr_fields.len, canvas.ui_markup.known_color_style_attrs.len);
    for (markup_view.color_style_attr_fields) |entry| {
        try testing.expect(nameListed(entry.markup, &canvas.ui_markup.known_color_style_attrs));
    }
    // Every color entry targets a StyleTokenRefs field, and every color
    // field of StyleTokenRefs is reachable from markup.
    inline for (@typeInfo(canvas.StyleTokenRefs).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "radius")) continue;
        var found = false;
        for (markup_view.color_style_attr_fields) |entry| {
            if (std.mem.eql(u8, entry.zig, field.name)) found = true;
        }
        try testing.expect(found);
    }
}

fn nameListed(name: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

test "template and style token build failures carry position and message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model{};

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "<column>\n  <use template=\"nope\" />\n</column>",
            .message = canvas.ui_markup.use_undefined_template_message,
        },
        .{
            // Self-recursion parses; the build's expansion-depth guard
            // reports it instead of recursing forever.
            .source = "<template name=\"loop\"><column><use template=\"loop\" /></column></template>\n<use template=\"loop\" />",
            .message = canvas.ui_markup.use_earlier_template_message,
        },
        .{
            .source = "<template name=\"t\" args=\"v\"><text>{v.x}</text></template>\n<column><use template=\"t\" v=\"1\" /></column>",
            .message = "template arg values have no fields",
        },
        .{
            // A slice arg (filters is a pub const array) is only iterable.
            .source = "<template name=\"t\" args=\"items\"><text>{items}</text></template>\n<column><use template=\"t\" items=\"{filters}\" /></column>",
            .message = "slice-valued template args are only usable with for each",
        },
        .{
            .source = "<template name=\"t\" args=\"extra\"><text>{extra}</text></template>\n<column><use template=\"t\" /></column>",
            .message = canvas.ui_markup.use_missing_arg_message,
        },
        .{
            .source = "<column background=\"{filter}\" />",
            .message = canvas.ui_markup.style_token_literal_message,
        },
        .{
            .source = "<column background=\"pink\" />",
            .message = canvas.ui_markup.unknown_color_token_message,
        },
        .{
            .source = "<column radius=\"huge\" />",
            .message = canvas.ui_markup.unknown_radius_token_message,
        },
    };
    for (cases) |case| {
        var view = try InboxMarkup.init(arena, case.source);
        var ui = InboxUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expectEqualStrings(case.message, view.diagnostic.message);
        try testing.expect(view.diagnostic.line > 0);
    }
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

test "the validator's element list matches the interpreter" {
    for (canvas.ui_markup.known_element_names) |name| {
        try testing.expect(markup_view.elementKind(name) != null);
    }
}
