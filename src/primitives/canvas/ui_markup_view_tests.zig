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

pub fn findByRoleLabel(widget: canvas.Widget, role: canvas.WidgetRole, label: []const u8) ?canvas.Widget {
    if (widget.semantics.role == role and std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByRoleLabel(child, role, label)) |found| return found;
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
        "<column on-input=\"draft\">\n  <text>dead handler</text>\n</column>",
    };
    for (cases) |source| {
        var view = try InboxMarkup.init(arena, source);
        var ui = InboxUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expect(view.diagnostic.message.len > 0);
        try testing.expect(view.diagnostic.line > 0);
    }
}

test "dead value handlers on non-hit-target elements fail the build with the teaching message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model{};

    // Value/text handlers on layout containers are dead — the element has
    // no control or text behavior to bind.
    const sources = [_][]const u8{
        "<column>\n  <row on-change=\"add\">\n    <text>press me</text>\n  </row>\n</column>",
        "<column>\n  <toggle-group on-submit=\"add\">\n    <toggle-button>A</toggle-button>\n  </toggle-group>\n</column>",
    };
    for (sources) |source| {
        var view = try InboxMarkup.init(arena, source);
        var ui = InboxUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expectEqualStrings(canvas.ui_markup.non_hit_target_handler_message, view.diagnostic.message);
        try testing.expectEqual(@as(usize, 2), view.diagnostic.line);
    }

    // The same handler on a hit-target leaf builds fine.
    var view = try InboxMarkup.init(arena, "<column>\n  <list-item on-press=\"add\">press me</list-item>\n</column>");
    var ui = InboxUi.init(arena);
    _ = try view.build(&ui, &model);
}

test "press handlers on layout elements build and stamp the press action" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model{};

    // A pressable row with plain text children: the bound handler makes
    // the row a widget-level hit target (semantics.actions.press) and the
    // press fall-through routes clicks on the text to it.
    var view = try InboxMarkup.init(arena, "<column>\n  <row on-press=\"add\" gap=\"8\">\n    <text>press me</text>\n  </row>\n</column>");
    var ui = InboxUi.init(arena);
    const tree = try ui.finalize(try view.build(&ui, &model));
    const row = tree.root.children[0];
    try testing.expectEqual(canvas.WidgetKind.row, row.kind);
    try testing.expect(row.semantics.actions.press);
    try testing.expect(canvas.widgetIsHitTarget(row));
    try testing.expect(canvas.widgetClaimsPress(row));
    try testing.expectEqual(Msg.add, tree.msgForPointer(row.id, .up).?);
    // The plain text child stays fall-through: no press claim of its own.
    try testing.expect(!canvas.widgetClaimsPress(row.children[0]));
}

test "gap on stacking containers fails the build with the teaching message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model{};

    // A plain overlay container and a modal surface kind: both layer
    // their children, so the gap could never space them.
    const sources = [_][]const u8{
        "<column>\n  <panel gap=\"8\">\n    <text>a</text>\n    <text>b</text>\n  </panel>\n</column>",
        "<column>\n  <sheet text=\"Share\" gap=\"8\">\n    <text>a</text>\n  </sheet>\n</column>",
    };
    for (sources) |source| {
        var view = try InboxMarkup.init(arena, source);
        var ui = InboxUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expectEqualStrings(canvas.ui_markup.stack_container_gap_message, view.diagnostic.message);
        try testing.expectEqual(@as(usize, 2), view.diagnostic.line);
    }

    // gap on flow containers stays fine, including inside a panel.
    var view = try InboxMarkup.init(arena, "<panel>\n  <column gap=\"8\">\n    <text>a</text>\n    <text>b</text>\n  </column>\n</panel>");
    var ui = InboxUi.init(arena);
    _ = try view.build(&ui, &model);
}

test "markup icons build icon widgets with validated names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model{};

    var view = try InboxMarkup.init(arena, "<row gap=\"8\">\n  <icon name=\"search\" width=\"16\" height=\"16\" />\n  <text>Search</text>\n</row>");
    var ui = InboxUi.init(arena);
    const tree = try ui.finalize(try view.build(&ui, &model));
    const icon = tree.root.children[0];
    try testing.expectEqual(canvas.WidgetKind.icon, icon.kind);
    try testing.expectEqualStrings("search", icon.text);

    // Unknown names, bindings, misplaced name attrs, and children fail
    // the build with the validator's messages.
    const failing = [_][]const u8{
        "<row>\n  <icon />\n</row>",
        "<row>\n  <icon name=\"sparkle-pony\" />\n</row>",
        "<row>\n  <icon name=\"{filter}\" />\n</row>",
        "<row>\n  <badge name=\"search\">3</badge>\n</row>",
        "<row>\n  <icon name=\"search\"><text>x</text></icon>\n</row>",
    };
    for (failing) |source| {
        var failing_view = try InboxMarkup.init(arena, source);
        var failing_ui = InboxUi.init(arena);
        try testing.expectError(error.MarkupBuild, failing_view.build(&failing_ui, &model));
        try testing.expect(failing_view.diagnostic.message.len > 0);
    }
}

test "markup buttons take an inline icon with validated names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model{};

    var view = try InboxMarkup.init(arena, "<row gap=\"8\">\n  <button icon=\"save\" on-press=\"add\">Save</button>\n  <button icon=\"refresh-cw\" on-press=\"add\"></button>\n  <toggle-button icon=\"arrow-up\" on-toggle=\"add\">Newest</toggle-button>\n  <list-item icon=\"folder\" on-press=\"add\">Projects</list-item>\n  <menu-item icon=\"trash\" on-press=\"add\">Delete</menu-item>\n</row>");
    var ui = InboxUi.init(arena);
    const tree = try ui.finalize(try view.build(&ui, &model));
    const labeled = tree.root.children[0];
    try testing.expectEqual(canvas.WidgetKind.button, labeled.kind);
    try testing.expectEqualStrings("save", labeled.icon);
    try testing.expectEqualStrings("Save", labeled.text);
    const icon_only = tree.root.children[1];
    try testing.expectEqualStrings("refresh-cw", icon_only.icon);
    try testing.expectEqualStrings("", icon_only.text);
    // One hit target: the button dispatches its own press; there is no
    // icon child to duplicate the handler onto.
    try testing.expectEqual(@as(usize, 0), labeled.children.len);
    try testing.expect(tree.msgFor(labeled.id, .press) != null);
    // The rest of the labeled interactive set (#96): toggle-buttons
    // (chips, tab strips), list items, and menu items carry the icon in
    // the same field with the same closed vocabulary.
    const chip = tree.root.children[2];
    try testing.expectEqual(canvas.WidgetKind.toggle_button, chip.kind);
    try testing.expectEqualStrings("arrow-up", chip.icon);
    try testing.expectEqualStrings("Newest", chip.text);
    try testing.expect(tree.msgFor(chip.id, .toggle) != null);
    const row_item = tree.root.children[3];
    try testing.expectEqual(canvas.WidgetKind.list_item, row_item.kind);
    try testing.expectEqualStrings("folder", row_item.icon);
    const menu_row = tree.root.children[4];
    try testing.expectEqual(canvas.WidgetKind.menu_item, menu_row.kind);
    try testing.expectEqualStrings("trash", menu_row.icon);

    // Unknown names, bindings, and out-of-scope elements fail the build
    // with the validator's messages.
    const failing = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<row>\n  <button icon=\"sparkle-pony\">Save</button>\n</row>", .message = canvas.ui_markup.button_icon_message },
        .{ .source = "<row>\n  <toggle-button icon=\"sparkle-pony\">Bold</toggle-button>\n</row>", .message = canvas.ui_markup.button_icon_message },
        .{ .source = "<row>\n  <button icon=\"{filter}\">Save</button>\n</row>", .message = canvas.ui_markup.button_icon_message },
        .{ .source = "<row>\n  <badge icon=\"sparkle-pony\">3</badge>\n</row>", .message = canvas.ui_markup.button_icon_message },
        .{ .source = "<column>\n  <checkbox icon=\"check\">Done</checkbox>\n</column>", .message = canvas.ui_markup.button_icon_element_message },
    };
    for (failing) |case| {
        var failing_view = try InboxMarkup.init(arena, case.source);
        var failing_ui = InboxUi.init(arena);
        try testing.expectError(error.MarkupBuild, failing_view.build(&failing_ui, &model));
        try testing.expectEqualStrings(case.message, failing_view.diagnostic.message);
    }
}

test "markup autofocus binds to focusable controls in both shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model{};

    var view = try InboxMarkup.init(arena, "<column gap=\"8\">\n  <text-field autofocus=\"true\" on-input=\"draft\" />\n  <text-field on-input=\"draft\" />\n</column>");
    var ui = InboxUi.init(arena);
    const tree = try ui.finalize(try view.build(&ui, &model));
    try testing.expect(tree.root.children[0].autofocus);
    try testing.expect(!tree.root.children[1].autofocus);

    // Non-focusable elements reject the request with the teaching error.
    var failing_view = try InboxMarkup.init(arena, "<column>\n  <row autofocus=\"true\">\n    <text>x</text>\n  </row>\n</column>");
    var failing_ui = InboxUi.init(arena);
    try testing.expectError(error.MarkupBuild, failing_view.build(&failing_ui, &model));
    try testing.expectEqualStrings(canvas.ui_markup.autofocus_element_message, failing_view.diagnostic.message);
}

/// Shared source for the anchored-picker parity tests (interpreter here,
/// compiled engine in ui_markup_compiled_tests.zig): the sanctioned select
/// composition with a floating dropdown, dismissal Msg, and a
/// press-and-hold crumb.
pub const picker_markup_source =
    \\<column gap="8">
    \\  <stack height="28">
    \\    <select text="Repo" on-press="add"/>
    \\    <dropdown-menu anchor="below" anchor-alignment="stretch" anchor-offset="6" width="160" height="90" on-dismiss="add">
    \\      <menu-item on-press="toggle:{open_count}">Alpha</menu-item>
    \\    </dropdown-menu>
    \\  </stack>
    \\  <button on-press="add" on-hold="add">Crumb</button>
    \\</column>
;

test "markup anchors dropdown-menus and binds dismiss and hold handlers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = Model{};

    var view = try InboxMarkup.init(arena, picker_markup_source);
    var ui = InboxUi.init(arena);
    const tree = try ui.finalize(try view.build(&ui, &model));

    const picker_stack = tree.root.children[0];
    const dropdown = picker_stack.children[1];
    try testing.expectEqual(canvas.WidgetKind.dropdown_menu, dropdown.kind);
    const anchor = dropdown.layout.anchor orelse return error.TestUnexpectedResult;
    try testing.expectEqual(canvas.WidgetAnchorPlacement.below, anchor.placement);
    try testing.expectEqual(canvas.WidgetAnchorAlignment.stretch, anchor.alignment);
    try testing.expectEqual(@as(f32, 6), anchor.offset);
    try testing.expect(tree.msgFor(dropdown.id, .dismiss) != null);

    const crumb = tree.root.children[1];
    try testing.expect(tree.msgFor(crumb.id, .hold) != null);
    // A hold handler makes the element pressable, like on-press.
    try testing.expect(crumb.semantics.actions.press);

    // Misplaced and malformed anchor/dismiss attributes fail the build
    // with the validator's teaching messages.
    const failing = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<row>\n  <button anchor=\"below\">Save</button>\n</row>", .message = canvas.ui_markup.anchor_element_message },
        .{ .source = "<row>\n  <dropdown-menu anchor=\"sideways\"><menu-item on-press=\"add\">A</menu-item></dropdown-menu>\n</row>", .message = canvas.ui_markup.anchor_value_message },
        .{ .source = "<row>\n  <dropdown-menu anchor-alignment=\"end\"><menu-item on-press=\"add\">A</menu-item></dropdown-menu>\n</row>", .message = canvas.ui_markup.anchor_dependent_attr_message },
        .{ .source = "<row>\n  <dropdown-menu anchor=\"below\" anchor-offset=\"lots\"><menu-item on-press=\"add\">A</menu-item></dropdown-menu>\n</row>", .message = canvas.ui_markup.anchor_offset_value_message },
        .{ .source = "<row>\n  <button on-dismiss=\"add\">Save</button>\n</row>", .message = canvas.ui_markup.on_dismiss_element_message },
    };
    for (failing) |case| {
        var failing_view = try InboxMarkup.init(arena, case.source);
        var failing_ui = InboxUi.init(arena);
        try testing.expectError(error.MarkupBuild, failing_view.build(&failing_ui, &model));
        try testing.expectEqualStrings(case.message, failing_view.diagnostic.message);
    }

    // The validator teaches the same rules through `markup check`.
    for (failing) |case| {
        var parser = canvas.ui_markup.Parser.init(arena, case.source);
        const document = try parser.parse();
        const diagnostic = canvas.ui_markup.validate(document) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, diagnostic.message);
    }
    var good_parser = canvas.ui_markup.Parser.init(arena, picker_markup_source);
    const good_document = try good_parser.parse();
    try testing.expectEqual(@as(?canvas.ui_markup.MarkupErrorInfo, null), canvas.ui_markup.validate(good_document));
}

test "the validator's icon name list matches the comptime registry" {
    // ui_markup.zig is std-only (it doubles as the LSP's module root), so
    // its icon vocabulary is a hardcoded mirror of the comptime-parsed
    // registry; this keeps the two in lockstep.
    try testing.expectEqual(canvas.icons.known_icon_names.len, canvas.ui_markup.known_icon_names.len);
    for (canvas.ui_markup.known_icon_names) |name| {
        try testing.expect(canvas.icons.find(name) != null);
    }
    for (canvas.icons.known_icon_names) |name| {
        try testing.expect(nameListed(name, &canvas.ui_markup.known_icon_names));
    }
}

test "the validator's element list matches the interpreter" {
    for (canvas.ui_markup.known_element_names) |name| {
        try testing.expect(markup_view.elementKind(name) != null);
    }
}

test "the validator's non-hit-target element list matches the engine's hit-target predicate" {
    // The engine predicate (canvas.widgetKindHitTarget, which the runtime's
    // pointer dispatch and both markup engines use) is the source of truth;
    // the validator's std-only name list must mirror it exactly so an
    // element can never accept a handler the runtime would never fire.
    for (canvas.ui_markup.known_element_names) |name| {
        const kind = markup_view.elementKind(name).?;
        try testing.expectEqual(
            !canvas.widgetKindHitTarget(kind),
            nameListed(name, &canvas.ui_markup.known_non_hit_target_element_names),
        );
    }
    // Every listed non-hit-target name is a known element.
    for (canvas.ui_markup.known_non_hit_target_element_names) |name| {
        try testing.expect(nameListed(name, &canvas.ui_markup.known_element_names));
    }
}

test "the validator's stack-container element list matches the engine's stacking predicate" {
    // The engine predicate (canvas.widgetKindStacksChildren, which the
    // layout pass, the builder's Debug gap diagnostic, and both markup
    // engines use) is the source of truth; the validator's std-only name
    // list must mirror it exactly so an element can never accept a gap
    // the layout would never apply.
    for (canvas.ui_markup.known_element_names) |name| {
        const kind = markup_view.elementKind(name).?;
        try testing.expectEqual(
            canvas.widgetKindStacksChildren(kind),
            nameListed(name, &canvas.ui_markup.known_stack_container_element_names),
        );
    }
    // Every listed stack-container name is a known element.
    for (canvas.ui_markup.known_stack_container_element_names) |name| {
        try testing.expect(nameListed(name, &canvas.ui_markup.known_element_names));
    }
}

test "the validator's text-leaf element list matches the interpreter's takes-text set" {
    for (canvas.ui_markup.known_element_names) |name| {
        const kind = markup_view.elementKind(name).?;
        try testing.expectEqual(
            markup_view.elementTakesText(kind),
            nameListed(name, &canvas.ui_markup.known_text_leaf_element_names),
        );
    }
    // Every listed text leaf is a known element.
    for (canvas.ui_markup.known_text_leaf_element_names) |name| {
        try testing.expect(nameListed(name, &canvas.ui_markup.known_element_names));
    }
}

/// Widget kinds deliberately NOT expressible in markup v1 — each needs
/// something the closed grammar cannot carry, so these are written as Zig
/// view functions instead of forcing a bad markup shape:
/// - image, icon_button: reference image assets by runtime ImageId,
///   which markup's literal/binding attribute values cannot express.
///   (icon IS expressible: the built-in vector set is a closed literal
///   vocabulary, comptime-validated.)
/// - data_grid: a virtualized data grid needs per-column cell templates
///   (arbitrary render callbacks).
/// - popover, menu_surface: floating surfaces anchored to runtime geometry
///   the static tree cannot express (dropdown-menu covers the declarative
///   menu case).
/// - segmented_control: engine kind for shell chrome segments; tabs and
///   toggle-group cover the component catalog's use cases.
/// - chart: series data is model-derived float arrays, and markup's
///   scalar bindings cannot carry arrays (the documented select-options
///   constraint, one level deeper). Charts are Zig views via `Ui.chart`;
///   a markup chart element waits for an array-binding channel.
const markup_excluded_widget_kinds = [_]canvas.WidgetKind{
    .image, .icon_button, .data_grid, .popover, .menu_surface, .segmented_control, .chart,
};

fn kindExpressible(kind: canvas.WidgetKind) bool {
    for (canvas.ui_markup.known_element_names) |name| {
        if (markup_view.elementKind(name) == kind) return true;
    }
    return false;
}

test "known_element_names covers every markup-expressible widget kind" {
    // Exactly the excluded kinds are inexpressible: a new widget kind must
    // either get a markup element or a documented exclusion above.
    for (std.enums.values(canvas.WidgetKind)) |kind| {
        const excluded = std.mem.indexOfScalar(canvas.WidgetKind, &markup_excluded_widget_kinds, kind) != null;
        try testing.expectEqual(!excluded, kindExpressible(kind));
    }
}

test "every built-in component is expressible in markup" {
    for (canvas.builtin_component_kinds) |component| {
        const descriptor = canvas.builtinComponentDescriptor(component);
        try testing.expect(kindExpressible(descriptor.root_widget_kind));
    }
}

// ---------------------------------------------- arena-scalar binding fixture

pub const Expense = struct {
    id: u32,
    cents: u32,

    /// Arena-taking item method: formats into the build arena, so the
    /// string lives exactly as long as the built tree.
    pub fn amount(expense: *const Expense, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "${d}.{d:0>2}", .{ expense.cents / 100, expense.cents % 100 }) catch "";
    }
};

pub const ExpensesMsg = union(enum) {
    pick: []const u8,
    refresh,
};

pub const ExpensesModel = struct {
    expenses: []const Expense = &.{},
    filter: []const u8 = "all",

    /// Arena-taking scalar binding: `{summary}` binds this directly — no
    /// one-element `<for>` needed.
    pub fn summary(model: *const ExpensesModel, arena: std.mem.Allocator) []const u8 {
        var total: u32 = 0;
        for (model.expenses) |expense| total += expense.cents;
        return std.fmt.allocPrint(arena, "{d} expenses · ${d}.{d:0>2}", .{ model.expenses.len, total / 100, total % 100 }) catch "";
    }
};

/// Arena scalars everywhere a scalar binding works: text interpolation
/// (mixed with other bindings), attribute values (label), message
/// payloads, if-test truthiness, and item-level arena methods.
pub const expenses_markup_source =
    \\<column gap="8">
    \\  <for each="expenses" key="id" as="e">
    \\    <row gap="4">
    \\      <text grow="1">{e.amount}</text>
    \\      <button size="sm" on-press="pick:{e.amount}">Pick</button>
    \\    </row>
    \\  </for>
    \\  <if test="{summary}">
    \\    <badge>summarized</badge>
    \\  </if>
    \\  <text label="{summary}">{filter}: {summary}</text>
    \\  <status-bar>{summary}</status-bar>
    \\</column>
;

pub const ExpensesUi = canvas.Ui(ExpensesMsg);

fn expenseRow(ui: *ExpensesUi, expense: *const Expense) ExpensesUi.Node {
    return ui.row(.{ .gap = 4 }, .{
        ui.text(.{ .grow = 1 }, expense.amount(ui.arena)),
        ui.button(.{ .size = .sm, .on_press = ExpensesMsg{ .pick = expense.amount(ui.arena) } }, "Pick"),
    });
}

fn expenseKey(expense: *const Expense) canvas.UiKey {
    return canvas.uiKey(expense.id);
}

fn expensesBadge(ui: *ExpensesUi) ExpensesUi.Node {
    var node = ui.el(.badge, .{}, .{});
    node.widget.text = "summarized";
    return node;
}

/// The hand-written equivalent of the arena-scalar markup: parity means
/// both engines build exactly this.
pub fn handExpensesView(ui: *ExpensesUi, model: *const ExpensesModel) ExpensesUi.Node {
    return ui.column(.{ .gap = 8 }, .{
        ui.each(model.expenses, expenseKey, expenseRow),
        expensesBadge(ui),
        ui.text(
            .{ .semantics = .{ .label = model.summary(ui.arena) } },
            ui.fmt("{s}: {s}", .{ model.filter, model.summary(ui.arena) }),
        ),
        ui.statusBar(.{}, model.summary(ui.arena)),
    });
}

pub fn expensesTestModel() ExpensesModel {
    return .{
        .expenses = &[_]Expense{
            .{ .id = 1, .cents = 1234 },
            .{ .id = 2, .cents = 60 },
        },
    };
}

test "arena-taking scalar bindings work in interpolation, attributes, payloads, and if tests" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = expensesTestModel();
    const ExpensesMarkup = markup_view.MarkupView(ExpensesModel, ExpensesMsg);

    var view = try ExpensesMarkup.init(arena, expenses_markup_source);
    var markup_ui = ExpensesUi.init(arena);
    const markup_tree = try markup_ui.finalize(try view.build(&markup_ui, &model));

    var hand_ui = ExpensesUi.init(arena);
    const hand_tree = try hand_ui.finalize(handExpensesView(&hand_ui, &model));

    var markup_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer markup_ids.deinit(testing.allocator);
    var hand_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer hand_ids.deinit(testing.allocator);
    try collectIds(markup_tree.root, &markup_ids, testing.allocator);
    try collectIds(hand_tree.root, &hand_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, hand_ids.items, markup_ids.items);
    try testing.expectEqual(hand_tree.handlers.len, markup_tree.handlers.len);

    // The scalar binds directly — text content and interpolation.
    try testing.expectEqualStrings("2 expenses · $12.94", findByKind(markup_tree.root, .status_bar).?.text);
    const labeled = findByText(markup_tree.root, .text, "all: 2 expenses · $12.94").?;
    // Attribute values (accessible label).
    try testing.expectEqualStrings("2 expenses · $12.94", labeled.semantics.label);
    // Item-level arena methods.
    try testing.expect(findByText(markup_tree.root, .text, "$12.34") != null);
    try testing.expect(findByText(markup_tree.root, .text, "$0.60") != null);
    // If-test truthiness on an arena scalar (non-empty string).
    try testing.expect(findByText(markup_tree.root, .badge, "summarized") != null);

    // Message payloads carry the arena string; it lives while the tree
    // does (the build arena outlives dispatch between rebuilds).
    const pick_button = findByKind(markup_tree.root, .button).?;
    try testing.expectEqualStrings("$12.34", markup_tree.msgForPointer(pick_button.id, .up).?.pick);
}

test "arena scalars are rejected inside equality with a teaching error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = expensesTestModel();
    const ExpensesMarkup = markup_view.MarkupView(ExpensesModel, ExpensesMsg);

    const cases = [_][]const u8{
        "<column>\n  <badge selected=\"{summary == filter}\">x</badge>\n</column>",
        "<column>\n  <badge selected=\"{filter == summary}\">x</badge>\n</column>",
        "<column>\n  <if test=\"{summary == filter}\"><text>x</text></if>\n</column>",
    };
    for (cases) |source| {
        var view = try ExpensesMarkup.init(arena, source);
        var ui = ExpensesUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expectEqualStrings(canvas.ui_markup.arena_scalar_equality_message, view.diagnostic.message);
        try testing.expect(view.diagnostic.line > 0);
    }
}

test "string-producing bindings pass to templates as value args" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = expensesTestModel();
    const ExpensesMarkup = markup_view.MarkupView(ExpensesModel, ExpensesMsg);

    // Both a string field (filter) and an arena scalar (summary) bind as
    // scalar value args — never as iterables of bytes.
    const source =
        "<template name=\"line\" args=\"title\"><text>{title}</text></template>\n" ++
        "<column>\n" ++
        "  <use template=\"line\" title=\"{filter}\" />\n" ++
        "  <use template=\"line\" title=\"{summary}\" />\n" ++
        "</column>";
    var view = try ExpensesMarkup.init(arena, source);
    var ui = ExpensesUi.init(arena);
    const tree = try ui.finalize(try view.build(&ui, &model));
    try testing.expect(findByText(tree.root, .text, "all") != null);
    try testing.expect(findByText(tree.root, .text, "2 expenses · $12.94") != null);
}

// --------------------------------------------------- markdown element fixture

pub const DocMsg = union(enum) {
    open_url: []const u8,
    toggle_details: usize,
    refresh,
};

pub const doc_body_source =
    \\## Release
    \\
    \\Read [the guide](https://example.com/guide) before shipping.
    \\
    \\Tracked in #12, see https://status.example.com.
    \\
    \\<details>
    \\<summary>Rollout</summary>
    \\
    \\Enable for 5% of traffic.
    \\
    \\</details>
;

pub const DocModel = struct {
    body: []const u8 = doc_body_source,
    details_expanded: [2]bool = .{ false, false },
    opened_count: usize = 0,
    issue_base: []const u8 = "ghissue://",

    /// Arena scalar as a markdown source: composed at view time.
    pub fn banner(model: *const DocModel, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "**{d}** links opened", .{model.opened_count}) catch "";
    }
};

pub const doc_markup_source =
    \\<column gap="8">
    \\  <markdown source="{body}" on-link="open_url" on-details="toggle_details" details-expanded="{details_expanded}" issue-link-base="{issue_base}" />
    \\  <markdown source="{banner}" />
    \\</column>
;

pub const DocUi = canvas.Ui(DocMsg);
const DocMd = canvas.markdown.Markdown(DocMsg);

/// The hand-written equivalent of the markdown markup: both engines must
/// build exactly what direct `Md.view` calls produce.
pub fn handDocView(ui: *DocUi, model: *const DocModel) DocUi.Node {
    return ui.column(.{ .gap = 8 }, .{
        DocMd.view(ui, model.body, .{
            .on_link = DocUi.linkMsg(.open_url),
            .on_details = DocMd.detailsMsg(.toggle_details),
            .details_expanded = &model.details_expanded,
            .issue_link_base = model.issue_base,
        }),
        DocMd.view(ui, model.banner(ui.arena), .{}),
    });
}

/// The link payload of the span whose text is exactly `span_text`, found
/// anywhere in the subtree; null when no such linked span exists.
pub fn findSpanLink(widget: canvas.Widget, span_text: []const u8) ?[]const u8 {
    for (widget.spans) |span| {
        if (span.link.len > 0 and std.mem.eql(u8, span.text, span_text)) return span.link;
    }
    for (widget.children) |child| {
        if (findSpanLink(child, span_text)) |link| return link;
    }
    return null;
}

pub fn findByRole(widget: canvas.Widget, role: canvas.WidgetRole) ?canvas.Widget {
    if (widget.semantics.role == role) return widget;
    for (widget.children) |child| {
        if (findByRole(child, role)) |found| return found;
    }
    return null;
}

test "the markdown element builds the hand-written Md.view tree and dispatches links and details" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = DocModel{};
    const DocMarkup = markup_view.MarkupView(DocModel, DocMsg);

    var view = try DocMarkup.init(arena, doc_markup_source);
    var markup_ui = DocUi.init(arena);
    const markup_tree = try markup_ui.finalize(try view.build(&markup_ui, &model));

    var hand_ui = DocUi.init(arena);
    const hand_tree = try hand_ui.finalize(handDocView(&hand_ui, &model));

    var markup_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer markup_ids.deinit(testing.allocator);
    var hand_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer hand_ids.deinit(testing.allocator);
    try collectIds(markup_tree.root, &markup_ids, testing.allocator);
    try collectIds(hand_tree.root, &hand_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, hand_ids.items, markup_ids.items);
    try testing.expectEqual(hand_tree.handlers.len, markup_tree.handlers.len);

    // Link spans dispatch the typed on-link message carrying the URL.
    const link = findByRole(markup_tree.root, .link).?;
    try testing.expectEqualStrings("https://example.com/guide", markup_tree.msgForPointer(link.id, .up).?.open_url);

    // Issue refs linkify through the issue-link-base binding, and bare
    // URLs autolink (trailing punctuation trimmed).
    try testing.expectEqualStrings("ghissue://12", findSpanLink(markup_tree.root, "#12").?);
    try testing.expectEqualStrings("https://status.example.com", findSpanLink(markup_tree.root, "https://status.example.com").?);

    // Details summary dispatches on-details with the block index; the body
    // is hidden while the caller-owned flag is false.
    try testing.expect(findByText(markup_tree.root, .text, "Enable for 5% of traffic.") == null);
    const summary_item = findByKind(markup_tree.root, .list_item).?;
    try testing.expectEqual(@as(usize, 0), markup_tree.msgForPointer(summary_item.id, .up).?.toggle_details);

    model.details_expanded[0] = true;
    var expanded_ui = DocUi.init(arena);
    const expanded_tree = try expanded_ui.finalize(try view.build(&expanded_ui, &model));
    try testing.expect(findByText(expanded_tree.root, .text, "Enable for 5% of traffic.") != null);
}

test "markdown misuse fails the build with teaching messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = DocModel{};
    const DocMarkup = markup_view.MarkupView(DocModel, DocMsg);

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            // Missing source entirely.
            .source = "<column>\n  <markdown on-link=\"open_url\" />\n</column>",
            .message = canvas.ui_markup.markdown_source_message,
        },
        .{
            // A literal is not a source binding.
            .source = "<column>\n  <markdown source=\"# hi\" />\n</column>",
            .message = canvas.ui_markup.markdown_source_message,
        },
        .{
            // Source binding must produce text (opened_count is a usize).
            .source = "<column>\n  <markdown source=\"{opened_count}\" />\n</column>",
            .message = canvas.ui_markup.markdown_source_message,
        },
        .{
            // on-link tag must carry a []const u8 payload (refresh is void).
            .source = "<column>\n  <markdown source=\"{body}\" on-link=\"refresh\" />\n</column>",
            .message = canvas.ui_markup.markdown_on_link_message,
        },
        .{
            // on-link takes a bare tag, never a payload binding.
            .source = "<column>\n  <markdown source=\"{body}\" on-link=\"open_url:{body}\" />\n</column>",
            .message = canvas.ui_markup.markdown_on_link_message,
        },
        .{
            // on-details tag must carry a usize payload.
            .source = "<column>\n  <markdown source=\"{body}\" on-details=\"refresh\" />\n</column>",
            .message = canvas.ui_markup.markdown_on_details_message,
        },
        .{
            // details-expanded must name a bool iterable (body is text).
            .source = "<column>\n  <markdown source=\"{body}\" details-expanded=\"{body}\" />\n</column>",
            .message = canvas.ui_markup.markdown_details_expanded_message,
        },
        .{
            // Closed attribute set.
            .source = "<column>\n  <markdown source=\"{body}\" gap=\"8\" />\n</column>",
            .message = canvas.ui_markup.markdown_attr_message,
        },
        .{
            // No children: the source binding provides the content.
            .source = "<column>\n  <markdown source=\"{body}\">text</markdown>\n</column>",
            .message = canvas.ui_markup.markdown_children_message,
        },
    };
    for (cases) |case| {
        var view = try DocMarkup.init(arena, case.source);
        var ui = DocUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expectEqualStrings(case.message, view.diagnostic.message);
        try testing.expect(view.diagnostic.line > 0);
    }
}

test "markdown misuse is caught by the model-agnostic validator with positions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "<column>\n  <markdown on-link=\"open_url\" />\n</column>",
            .message = canvas.ui_markup.markdown_source_message,
        },
        .{
            .source = "<column>\n  <markdown source=\"# literal\" />\n</column>",
            .message = canvas.ui_markup.markdown_source_message,
        },
        .{
            .source = "<column>\n  <markdown source=\"{body}\" on-link=\"open_url:{body}\" />\n</column>",
            .message = canvas.ui_markup.markdown_on_link_message,
        },
        .{
            .source = "<column>\n  <markdown source=\"{body}\" on-details=\"toggle:{body}\" />\n</column>",
            .message = canvas.ui_markup.markdown_on_details_message,
        },
        .{
            .source = "<column>\n  <markdown source=\"{body}\" details-expanded=\"literal\" />\n</column>",
            .message = canvas.ui_markup.markdown_details_expanded_message,
        },
        .{
            .source = "<column>\n  <markdown source=\"{body}\" padding=\"8\" />\n</column>",
            .message = canvas.ui_markup.markdown_attr_message,
        },
        .{
            .source = "<column>\n  <markdown source=\"{body}\"><text>x</text></markdown>\n</column>",
            .message = canvas.ui_markup.markdown_children_message,
        },
    };
    for (cases) |case| {
        var parser = canvas.ui_markup.Parser.init(arena, case.source);
        const info = canvas.ui_markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
        try testing.expect(info.column > 0);
    }

    // A correct markdown element validates cleanly.
    var parser = canvas.ui_markup.Parser.init(arena, "<column><markdown source=\"{body}\" on-link=\"open_url\" on-details=\"toggle_details\" details-expanded=\"{flags}\" /></column>");
    try testing.expectEqual(@as(?canvas.ui_markup.MarkupErrorInfo, null), canvas.ui_markup.validate(try parser.parse()));
}

// -------------------------------------------------- component catalog fixture

pub const CatalogRow = struct {
    id: u32,
    name: []const u8,
    qty: u32,

    pub fn key(row: *const CatalogRow) canvas.UiKey {
        return canvas.uiKey(row.id);
    }
};

pub const CatalogMsg = union(enum) {
    open_picker,
    set_tab: u32,
    toggle_bold,
    toggle_details,
    set_page: u32,
    pick_row: u32,
    query_edit: canvas.TextInputEvent,
    submit_query,
};

pub const CatalogModel = struct {
    tab: u32 = 0,
    overview_tab: u32 = 0,
    data_tab: u32 = 1,
    bold: bool = false,
    details_open: bool = true,
    dialog_open: bool = false,
    loading: bool = true,
    page: u32 = 1,
    stage: usize = 1,
    choice: []const u8 = "Bananas",
    query: []const u8 = "",
    rows: []const CatalogRow = &.{},

    pub fn prevPage(model: *const CatalogModel) u32 {
        return model.page -| 1;
    }

    pub fn nextPage(model: *const CatalogModel) u32 {
        return model.page + 1;
    }
};

/// One instance of every element added for built-in component coverage:
/// row containers (breadcrumb, tabs, toggle-group, button-group,
/// radio-group, pagination), vertical containers (table + table-row +
/// table-cell, dropdown-menu), surfaces (accordion, alert, bubble,
/// resizable, dialog, drawer, sheet), text leaves (avatar, select, switch,
/// toggle-button, tooltip), text entry (input, combobox), and plain leaves
/// (skeleton, spinner).
pub const catalog_markup_source =
    \\<column gap="8">
    \\  <breadcrumb gap="4">
    \\    <text>Home</text>
    \\    <text>Products</text>
    \\  </breadcrumb>
    \\  <tabs gap="4">
    \\    <button selected="{tab == overview_tab}" on-press="set_tab:{overview_tab}">Overview</button>
    \\    <button selected="{tab == data_tab}" on-press="set_tab:{data_tab}">Data</button>
    \\  </tabs>
    \\  <row gap="8" cross="center">
    \\    <avatar>CT</avatar>
    \\    <select placeholder="Pick a fruit" on-press="open_picker">{choice}</select>
    \\    <switch checked="{bold}" on-toggle="toggle_bold">Bold</switch>
    \\    <toggle-group gap="4">
    \\      <toggle-button selected="{bold}" on-toggle="toggle_bold">B</toggle-button>
    \\    </toggle-group>
    \\    <button-group gap="4">
    \\      <button size="sm" on-press="open_picker">Open</button>
    \\    </button-group>
    \\  </row>
    \\  <row gap="8">
    \\    <input text="{query}" placeholder="Name" autofocus="true" on-input="query_edit" on-submit="submit_query" grow="1" />
    \\    <combobox text="{query}" placeholder="Search fruit" on-input="query_edit" />
    \\  </row>
    \\  <radio-group gap="4">
    \\    <radio checked="{bold}" on-toggle="toggle_bold" />
    \\  </radio-group>
    \\  <accordion text="Details" selected="{details_open}" on-toggle="toggle_details" padding="8">
    \\    <text>More info</text>
    \\  </accordion>
    \\  <alert text="Heads up" />
    \\  <bubble padding="8">
    \\    <text>Hi!</text>
    \\  </bubble>
    \\  <table gap="2">
    \\    <table-row gap="4">
    \\      <table-cell>Name</table-cell>
    \\      <table-cell>Qty</table-cell>
    \\    </table-row>
    \\    <for each="rows" key="id" as="r">
    \\      <table-row gap="4">
    \\        <table-cell on-press="pick_row:{r.id}">{r.name}</table-cell>
    \\        <table-cell>{r.qty}</table-cell>
    \\      </table-row>
    \\    </for>
    \\  </table>
    \\  <stepper active="{stage}" key="pipeline">
    \\    <step>Work</step>
    \\    <step>Review · {page}</step>
    \\    <step>Ready</step>
    \\  </stepper>
    \\  <timeline gap="4" label="run ledger">
    \\    <for each="rows" key="id" as="entry">
    \\      <timeline-item title="{entry.name}" description="Step summary" meta="claude · sonnet" variant="primary" on-press="pick_row:{entry.id}" />
    \\    </for>
    \\    <timeline-item title="Ready for review" icon="check" variant="secondary" connector="false" selected="true" />
    \\  </timeline>
    \\  <pagination gap="4">
    \\    <button size="sm" on-press="set_page:{prevPage}">Prev</button>
    \\    <badge>{page}</badge>
    \\    <button size="sm" on-press="set_page:{nextPage}">Next</button>
    \\  </pagination>
    \\  <dropdown-menu gap="2">
    \\    <menu-item on-press="open_picker">Rename</menu-item>
    \\  </dropdown-menu>
    \\  <resizable width="240">
    \\    <column padding="8">
    \\      <text>Sidebar</text>
    \\    </column>
    \\  </resizable>
    \\  <if test="{loading}">
    \\    <row gap="4" cross="center">
    \\      <spinner />
    \\      <skeleton width="120" height="16" />
    \\    </row>
    \\  </if>
    \\  <tooltip>Copied!</tooltip>
    \\  <if test="{dialog_open}">
    \\    <dialog text="Confirm">
    \\      <column gap="8" padding="12">
    \\        <text>Are you sure?</text>
    \\        <button variant="primary" on-press="submit_query">Yes</button>
    \\      </column>
    \\    </dialog>
    \\  </if>
    \\  <drawer text="Filters">
    \\    <column padding="8">
    \\      <text>Drawer body</text>
    \\    </column>
    \\  </drawer>
    \\  <sheet text="Share">
    \\    <column padding="8">
    \\      <text>Sheet body</text>
    \\    </column>
    \\  </sheet>
    \\</column>
;

pub const CatalogUi = canvas.Ui(CatalogMsg);

fn textLeaf(ui: *CatalogUi, kind: canvas.WidgetKind, options: CatalogUi.ElementOptions, content: []const u8) CatalogUi.Node {
    var node = ui.el(kind, options, .{});
    node.widget.text = content;
    return node;
}

fn catalogTableRow(ui: *CatalogUi, row: *const CatalogRow) CatalogUi.Node {
    return ui.el(.data_row, .{ .gap = 4 }, .{
        textLeaf(ui, .data_cell, .{ .on_press = CatalogMsg{ .pick_row = row.id } }, row.name),
        textLeaf(ui, .data_cell, .{}, ui.fmt("{d}", .{row.qty})),
    });
}

fn catalogTimelineEntry(ui: *CatalogUi, row: *const CatalogRow) CatalogUi.Node {
    return ui.timelineItem(.{
        .title = row.name,
        .description = "Step summary",
        .meta = "claude · sonnet",
        .variant = .primary,
        .on_press = CatalogMsg{ .pick_row = row.id },
    });
}

/// The hand-written equivalent of the catalog markup for a model with
/// `loading` true and `dialog_open` false (the fixture model): parity
/// means the interpreter and the compiled view both build exactly this.
pub fn handCatalogView(ui: *CatalogUi, model: *const CatalogModel) CatalogUi.Node {
    return ui.column(.{ .gap = 8 }, .{
        ui.el(.breadcrumb, .{ .gap = 4 }, .{
            ui.text(.{}, "Home"),
            ui.text(.{}, "Products"),
        }),
        ui.el(.tabs, .{ .gap = 4 }, .{
            ui.button(.{ .selected = model.tab == model.overview_tab, .on_press = CatalogMsg{ .set_tab = model.overview_tab } }, "Overview"),
            ui.button(.{ .selected = model.tab == model.data_tab, .on_press = CatalogMsg{ .set_tab = model.data_tab } }, "Data"),
        }),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            textLeaf(ui, .avatar, .{}, "CT"),
            textLeaf(ui, .select, .{ .placeholder = "Pick a fruit", .on_press = .open_picker }, model.choice),
            textLeaf(ui, .switch_control, .{ .checked = model.bold, .on_toggle = .toggle_bold }, "Bold"),
            ui.el(.toggle_group, .{ .gap = 4 }, .{
                textLeaf(ui, .toggle_button, .{ .selected = model.bold, .on_toggle = .toggle_bold }, "B"),
            }),
            ui.el(.button_group, .{ .gap = 4 }, .{
                ui.button(.{ .size = .sm, .on_press = .open_picker }, "Open"),
            }),
        }),
        ui.row(.{ .gap = 8 }, .{
            ui.el(.input, .{ .text = model.query, .placeholder = "Name", .autofocus = true, .on_input = CatalogUi.inputMsg(.query_edit), .on_submit = .submit_query, .grow = 1 }, .{}),
            ui.el(.combobox, .{ .text = model.query, .placeholder = "Search fruit", .on_input = CatalogUi.inputMsg(.query_edit) }, .{}),
        }),
        ui.el(.radio_group, .{ .gap = 4 }, .{
            ui.el(.radio, .{ .checked = model.bold, .on_toggle = .toggle_bold }, .{}),
        }),
        ui.el(.accordion, .{ .text = "Details", .selected = model.details_open, .on_toggle = .toggle_details, .padding = 8 }, .{
            ui.text(.{}, "More info"),
        }),
        ui.el(.alert, .{ .text = "Heads up" }, .{}),
        ui.el(.bubble, .{ .padding = 8 }, .{
            ui.text(.{}, "Hi!"),
        }),
        ui.el(.table, .{ .gap = 2 }, .{
            ui.el(.data_row, .{ .gap = 4 }, .{
                textLeaf(ui, .data_cell, .{}, "Name"),
                textLeaf(ui, .data_cell, .{}, "Qty"),
            }),
            ui.each(model.rows, CatalogRow.key, catalogTableRow),
        }),
        ui.stepper(.{ .active = model.stage, .key = canvas.uiKey("pipeline") }, &.{
            .{ .label = "Work" },
            .{ .label = ui.fmt("Review · {d}", .{model.page}) },
            .{ .label = "Ready" },
        }),
        ui.timeline(.{ .gap = 4, .semantics = .{ .label = "run ledger" } }, .{
            ui.each(model.rows, CatalogRow.key, catalogTimelineEntry),
            ui.timelineItem(.{
                .title = "Ready for review",
                .icon = "check",
                .variant = .secondary,
                .connector = false,
                .selected = true,
            }),
        }),
        ui.el(.pagination, .{ .gap = 4 }, .{
            ui.button(.{ .size = .sm, .on_press = CatalogMsg{ .set_page = model.prevPage() } }, "Prev"),
            textLeaf(ui, .badge, .{}, ui.fmt("{d}", .{model.page})),
            ui.button(.{ .size = .sm, .on_press = CatalogMsg{ .set_page = model.nextPage() } }, "Next"),
        }),
        ui.el(.dropdown_menu, .{ .gap = 2 }, .{
            textLeaf(ui, .menu_item, .{ .on_press = .open_picker }, "Rename"),
        }),
        ui.el(.resizable, .{ .width = 240 }, .{
            ui.column(.{ .padding = 8 }, ui.text(.{}, "Sidebar")),
        }),
        // The fixture model has loading=true and dialog_open=false; the
        // interpreter/compiled if blocks flatten to exactly these siblings.
        ui.row(.{ .gap = 4, .cross = .center }, .{
            ui.el(.spinner, .{}, .{}),
            ui.el(.skeleton, .{ .width = 120, .height = 16 }, .{}),
        }),
        textLeaf(ui, .tooltip, .{}, "Copied!"),
        ui.el(.drawer, .{ .text = "Filters" }, .{
            ui.column(.{ .padding = 8 }, ui.text(.{}, "Drawer body")),
        }),
        ui.el(.sheet, .{ .text = "Share" }, .{
            ui.column(.{ .padding = 8 }, ui.text(.{}, "Sheet body")),
        }),
    });
}

pub fn catalogTestModel() CatalogModel {
    return .{
        .rows = &[_]CatalogRow{
            .{ .id = 1, .name = "Apples", .qty = 4 },
            .{ .id = 2, .name = "Pears", .qty = 7 },
        },
    };
}

test "the catalog fixture passes structural validation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parser = canvas.ui_markup.Parser.init(arena_state.allocator(), catalog_markup_source);
    try testing.expectEqual(@as(?canvas.ui_markup.MarkupErrorInfo, null), canvas.ui_markup.validate(try parser.parse()));
}

test "catalog elements build the hand-written tree and dispatch typed messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = catalogTestModel();
    const CatalogMarkup = markup_view.MarkupView(CatalogModel, CatalogMsg);

    var view = try CatalogMarkup.init(arena, catalog_markup_source);
    var markup_ui = CatalogUi.init(arena);
    const markup_tree = try markup_ui.finalize(try view.build(&markup_ui, &model));

    var hand_ui = CatalogUi.init(arena);
    const hand_tree = try hand_ui.finalize(handCatalogView(&hand_ui, &model));

    var markup_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer markup_ids.deinit(testing.allocator);
    var hand_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer hand_ids.deinit(testing.allocator);
    try collectIds(markup_tree.root, &markup_ids, testing.allocator);
    try collectIds(hand_tree.root, &hand_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, hand_ids.items, markup_ids.items);
    try testing.expectEqual(hand_tree.handlers.len, markup_tree.handlers.len);

    // Text-bearing leaves carry their content.
    try testing.expect(findByText(markup_tree.root, .avatar, "CT") != null);
    try testing.expect(findByText(markup_tree.root, .select, "Bananas") != null);
    try testing.expect(findByText(markup_tree.root, .tooltip, "Copied!") != null);
    try testing.expect(findByText(markup_tree.root, .data_cell, "Pears") != null);
    try testing.expect(findByText(markup_tree.root, .badge, "1") != null);

    // Surface titles flow through the text attribute.
    try testing.expectEqualStrings("Heads up", findByKind(markup_tree.root, .alert).?.text);
    try testing.expectEqualStrings("Details", findByKind(markup_tree.root, .accordion).?.text);

    // Typed dispatch through the engine's semantic intents: select presses,
    // switch/toggle-button/accordion toggle, table cells select-press.
    const select = findByKind(markup_tree.root, .select).?;
    try testing.expectEqual(CatalogMsg.open_picker, markup_tree.msgForPointer(select.id, .up).?);
    const switch_control = findByKind(markup_tree.root, .switch_control).?;
    try testing.expectEqual(CatalogMsg.toggle_bold, markup_tree.msgForPointer(switch_control.id, .up).?);
    const toggle_button = findByKind(markup_tree.root, .toggle_button).?;
    try testing.expectEqual(CatalogMsg.toggle_bold, markup_tree.msgForPointer(toggle_button.id, .up).?);
    const accordion = findByKind(markup_tree.root, .accordion).?;
    try testing.expectEqual(CatalogMsg.toggle_details, markup_tree.msgForPointer(accordion.id, .up).?);
    const pears_cell = findByText(markup_tree.root, .data_cell, "Pears").?;
    try testing.expectEqual(@as(u32, 2), markup_tree.msgForPointer(pears_cell.id, .up).?.pick_row);

    // Composite stepper: the active step (index 1) is selected and carries
    // its interpolated label + state in semantics.
    const active_step = findByRoleLabel(markup_tree.root, .listitem, "Review · 1 (active)").?;
    try testing.expect(active_step.state.selected);
    try testing.expect(findByRoleLabel(markup_tree.root, .listitem, "Work (completed)") != null);
    // Composite timeline: an item press dispatches from the item's root
    // (the bound handler makes it a hit target; presses on the content
    // fall through to it).
    const ledger_item = findByRoleLabel(markup_tree.root, .listitem, "Pears").?;
    try testing.expect(canvas.widgetClaimsPress(ledger_item));
    try testing.expectEqual(@as(u32, 2), markup_tree.msgForPointer(ledger_item.id, .up).?.pick_row);
    const prev_button = findByText(markup_tree.root, .button, "Prev").?;
    try testing.expectEqual(@as(u32, 0), markup_tree.msgForPointer(prev_button.id, .up).?.set_page);

    // Text entry: edits and enter-to-submit dispatch on input.
    const input = findByKind(markup_tree.root, .input).?;
    const typed = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = "q" };
    try testing.expectEqualStrings("q", markup_tree.msgForKeyboard(input.id, typed).?.query_edit.insert_text);
    const submit = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expectEqual(CatalogMsg.submit_query, markup_tree.msgForKeyboard(input.id, submit).?);

    // The whole catalog lays out through the canvas engine.
    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(markup_tree.root, @import("geometry").RectF.init(0, 0, 900, 1400), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

test "new element misuse is validated with positions and teaching messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "<column>\n  <table-row><table-cell>x</table-cell></table-row>\n</column>",
            .message = canvas.ui_markup.table_row_parent_message,
        },
        .{
            .source = "<table>\n  <table-cell>x</table-cell>\n</table>",
            .message = canvas.ui_markup.table_cell_parent_message,
        },
        .{
            .source = "<row>\n  <select><button on-press=\"x\">pick</button></select>\n</row>",
            .message = canvas.ui_markup.text_leaf_children_message,
        },
        .{
            .source = "<row>\n  <avatar><text>CT</text></avatar>\n</row>",
            .message = canvas.ui_markup.text_leaf_children_message,
        },
    };
    for (cases) |case| {
        var parser = canvas.ui_markup.Parser.init(arena, case.source);
        const info = canvas.ui_markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
        try testing.expect(info.column > 0);
    }

    // Structure tags between a table and its rows are fine.
    var parser = canvas.ui_markup.Parser.init(arena, "<table><for each=\"rows\" as=\"r\"><table-row><table-cell>{r.name}</table-cell></table-row></for></table>");
    try testing.expectEqual(@as(?canvas.ui_markup.MarkupErrorInfo, null), canvas.ui_markup.validate(try parser.parse()));
}

// --------------------------------------------------------- text wrapping

pub const WrapMsg = union(enum) { refresh };

pub const WrapModel = struct {
    message: []const u8 = "A long error message that should wrap onto several lines instead of clipping on one",
};

pub const wrap_markup_source =
    \\<column gap="8" width="360">
    \\  <text wrap="true">{message}</text>
    \\  <text>{message}</text>
    \\</column>
;

pub const WrapUi = canvas.Ui(WrapMsg);

pub fn handWrapView(ui: *WrapUi, model: *const WrapModel) WrapUi.Node {
    return ui.column(.{ .gap = 8, .width = 360 }, .{
        ui.text(.{ .wrap = true }, model.message),
        ui.text(.{}, model.message),
    });
}

test "the wrap attribute builds the hand-written wrapped text leaf" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = WrapModel{};
    const WrapMarkup = markup_view.MarkupView(WrapModel, WrapMsg);

    var view = try WrapMarkup.init(arena, wrap_markup_source);
    var markup_ui = WrapUi.init(arena);
    const markup_tree = try markup_ui.finalize(try view.build(&markup_ui, &model));

    var hand_ui = WrapUi.init(arena);
    const hand_tree = try hand_ui.finalize(handWrapView(&hand_ui, &model));

    var markup_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer markup_ids.deinit(testing.allocator);
    var hand_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer hand_ids.deinit(testing.allocator);
    try collectIds(markup_tree.root, &markup_ids, testing.allocator);
    try collectIds(hand_tree.root, &hand_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, hand_ids.items, markup_ids.items);

    // wrap="true" becomes a single-span paragraph over the interpolated
    // text; the default stays the single-line path.
    const wrapped = markup_tree.root.children[0];
    try testing.expectEqual(@as(usize, 1), wrapped.spans.len);
    try testing.expectEqualStrings(model.message, wrapped.text);
    try testing.expect(wrapped.spans[0].text.ptr == wrapped.text.ptr);
    const plain = markup_tree.root.children[1];
    try testing.expectEqual(@as(usize, 0), plain.spans.len);

    // The definite column width is both floor and cap.
    try testing.expectEqual(@as(f32, 360), markup_tree.root.layout.min_size.width);
    try testing.expectEqual(@as(f32, 360), markup_tree.root.layout.max_size.width);
}

// -------------------------------------------- avatar image binding fixture

pub const AvatarMsg = union(enum) { refresh };

pub const AvatarModel = struct {
    /// Runtime-registered ImageId kept in the model (0 = no image, the
    /// initials fallback) — the id only lands here on successful
    /// `fx.registerImageBytes`.
    user_image: canvas.ImageId = 0,
    user_name: []const u8 = "Chris Tate",

    /// A pub fn producing an ImageId binds like a field.
    pub fn teammateImage(model: *const AvatarModel) canvas.ImageId {
        return model.user_image + 1;
    }
};

pub const avatar_markup_source =
    \\<row gap="8" cross="center">
    \\  <avatar image="{user_image}" label="{user_name}">CT</avatar>
    \\  <avatar image="{teammateImage}">NS</avatar>
    \\</row>
;

pub const AvatarUi = canvas.Ui(AvatarMsg);

/// The hand-written equivalent of the avatar markup: `ui.avatar` with
/// `ElementOptions.image`, so parity covers the cover-fit clip too.
pub fn handAvatarView(ui: *AvatarUi, model: *const AvatarModel) AvatarUi.Node {
    return ui.row(.{ .gap = 8, .cross = .center }, .{
        ui.avatar(.{ .image = model.user_image, .semantics = .{ .label = model.user_name } }, "CT"),
        ui.avatar(.{ .image = model.teammateImage() }, "NS"),
    });
}

test "the avatar image binding resolves model fields and fns to the widget image id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const AvatarMarkup = markup_view.MarkupView(AvatarModel, AvatarMsg);
    const model = AvatarModel{ .user_image = 7 };

    var view = try AvatarMarkup.init(arena, avatar_markup_source);
    var markup_ui = AvatarUi.init(arena);
    const markup_tree = try markup_ui.finalize(try view.build(&markup_ui, &model));

    var hand_ui = AvatarUi.init(arena);
    const hand_tree = try hand_ui.finalize(handAvatarView(&hand_ui, &model));

    var markup_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer markup_ids.deinit(testing.allocator);
    var hand_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer hand_ids.deinit(testing.allocator);
    try collectIds(markup_tree.root, &markup_ids, testing.allocator);
    try collectIds(hand_tree.root, &hand_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, hand_ids.items, markup_ids.items);

    // The field binding and the fn binding both land in image_id; the
    // initials stay the text content and the image clips like Ui.avatar.
    const field_avatar = findByText(markup_tree.root, .avatar, "CT").?;
    try testing.expectEqual(@as(canvas.ImageId, 7), field_avatar.image_id);
    try testing.expectEqual(canvas.ImageFit.cover, field_avatar.image_fit);
    try testing.expectEqualStrings("Chris Tate", field_avatar.semantics.label);
    const fn_avatar = findByText(markup_tree.root, .avatar, "NS").?;
    try testing.expectEqual(@as(canvas.ImageId, 8), fn_avatar.image_id);

    // 0 is the "no image" sentinel: the widget stays on the initials
    // fallback path.
    const empty_model = AvatarModel{};
    var empty_ui = AvatarUi.init(arena);
    const empty_tree = try empty_ui.finalize(try view.build(&empty_ui, &empty_model));
    try testing.expectEqual(@as(canvas.ImageId, 0), findByText(empty_tree.root, .avatar, "CT").?.image_id);
    try testing.expectEqualStrings("CT", findByText(empty_tree.root, .avatar, "CT").?.text);
}

test "avatar image misuse fails the build with the teaching messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = AvatarModel{};
    const AvatarMarkup = markup_view.MarkupView(AvatarModel, AvatarMsg);

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            // A literal id is not model data.
            .source = "<row>\n  <avatar image=\"7\">CT</avatar>\n</row>",
            .message = canvas.ui_markup.avatar_image_message,
        },
        .{
            // The binding must produce an integer ImageId (user_name is text).
            .source = "<row>\n  <avatar image=\"{user_name}\">CT</avatar>\n</row>",
            .message = canvas.ui_markup.avatar_image_message,
        },
        .{
            // Scoped to avatar: the other image elements stay Zig views.
            .source = "<row>\n  <badge image=\"{user_image}\">3</badge>\n</row>",
            .message = canvas.ui_markup.avatar_image_element_message,
        },
    };
    for (cases) |case| {
        var view = try AvatarMarkup.init(arena, case.source);
        var ui = AvatarUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expectEqualStrings(case.message, view.diagnostic.message);
        try testing.expect(view.diagnostic.line > 0);
    }
}

// -------------------------------- text alignment and grid columns (#84)

pub const AlignMsg = union(enum) { refresh };

pub const AlignModel = struct {
    duration: []const u8 = "4:33",
    column_count: usize = 3,
};

pub const align_markup_source =
    \\<column gap="8" width="360">
    \\  <text text-alignment="center" foreground="info">{duration}</text>
    \\  <grid columns="4" gap="6">
    \\    <text>a</text>
    \\    <text>b</text>
    \\  </grid>
    \\  <grid columns="{column_count}">
    \\    <text>c</text>
    \\  </grid>
    \\</column>
;

pub const AlignUi = canvas.Ui(AlignMsg);

pub fn handAlignView(ui: *AlignUi, model: *const AlignModel) AlignUi.Node {
    return ui.column(.{ .gap = 8, .width = 360 }, .{
        ui.text(.{ .text_alignment = .center, .style_tokens = .{ .foreground = .info } }, model.duration),
        ui.el(.grid, .{ .columns = 4, .gap = 6 }, .{
            ui.text(.{}, "a"),
            ui.text(.{}, "b"),
        }),
        ui.el(.grid, .{ .columns = model.column_count }, .{
            ui.text(.{}, "c"),
        }),
    });
}

test "text-alignment and grid columns build the hand-written tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = AlignModel{};
    const AlignMarkup = markup_view.MarkupView(AlignModel, AlignMsg);

    var view = try AlignMarkup.init(arena, align_markup_source);
    var markup_ui = AlignUi.init(arena);
    const markup_tree = try markup_ui.finalize(try view.build(&markup_ui, &model));

    var hand_ui = AlignUi.init(arena);
    const hand_tree = try hand_ui.finalize(handAlignView(&hand_ui, &model));

    var markup_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer markup_ids.deinit(testing.allocator);
    var hand_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer hand_ids.deinit(testing.allocator);
    try collectIds(markup_tree.root, &markup_ids, testing.allocator);
    try collectIds(hand_tree.root, &hand_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, hand_ids.items, markup_ids.items);

    // text-alignment lands on the widget; the default stays .start.
    const aligned = markup_tree.root.children[0];
    try testing.expectEqual(canvas.TextAlign.center, aligned.text_alignment);
    // The info token resolves like any other ColorTokens field (#85).
    try testing.expectEqualDeep((canvas.DesignTokens{}).colors.info, aligned.style.foreground.?);

    // columns lands in the grid layout, from a literal and from a binding.
    try testing.expectEqual(@as(usize, 4), markup_tree.root.children[1].layout.columns);
    try testing.expectEqual(@as(usize, 3), markup_tree.root.children[2].layout.columns);
    // The inner texts keep the .start default.
    try testing.expectEqual(canvas.TextAlign.start, markup_tree.root.children[1].children[0].text_alignment);

    // The source validates cleanly.
    var parser = canvas.ui_markup.Parser.init(arena, align_markup_source);
    try testing.expectEqual(@as(?canvas.ui_markup.MarkupErrorInfo, null), canvas.ui_markup.validate(try parser.parse()));
}

test "columns off grid and misshapen alignment values fail with teaching messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The validator scopes columns to grid (the only layout that reads it).
    var parser = canvas.ui_markup.Parser.init(arena, "<column columns=\"3\">\n  <text>x</text>\n</column>");
    const info = canvas.ui_markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(canvas.ui_markup.grid_columns_element_message, info.message);
    try testing.expect(info.line > 0);

    // The interpreter rejects bad values with its generic option messages.
    const model = AlignModel{};
    const AlignMarkup = markup_view.MarkupView(AlignModel, AlignMsg);
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "<column>\n  <text text-alignment=\"middle\">x</text>\n</column>",
            .message = "unknown option value",
        },
        .{
            .source = "<column>\n  <grid columns=\"{duration}\"><text>x</text></grid>\n</column>",
            .message = "expected a whole number",
        },
    };
    for (cases) |case| {
        var view = try AlignMarkup.init(arena, case.source);
        var ui = AlignUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expectEqualStrings(case.message, view.diagnostic.message);
        try testing.expect(view.diagnostic.line > 0);
    }
}
