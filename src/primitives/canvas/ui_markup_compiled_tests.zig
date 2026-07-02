//! Parity tests for the comptime-compiled markup path: for the same model,
//! `CompiledMarkupView(...).build` must produce exactly what the runtime
//! interpreter produces — identical structural ids node for node, identical
//! handler tables, identical dispatch results, identical interpolated text.
//!
//! Compile-error coverage: Zig cannot unit-test `@compileError`, so the
//! rejecting side is guaranteed structurally — every invalid construct the
//! interpreter reports at runtime (see "markup build failures carry position
//! and message" in ui_markup_view_tests.zig) is resolved during the comptime
//! walk and fails compilation with the same message plus line/column. These
//! tests pin down the accepting side: everything valid builds identically.

const std = @import("std");
const canvas = @import("root.zig");
const markup_view = @import("ui_markup_view.zig");
const fixture = @import("ui_markup_view_tests.zig");

const testing = std.testing;

// ------------------------------------------------------ shared assertions

/// Identical trees: same structural ids node for node and the same handler
/// table entry for entry (messages by value, input/value constructors by
/// function identity — both engines instantiate `Ui.inputMsg` on the same
/// comptime tag, so parity implies pointer equality).
fn expectSameTree(comptime MsgT: type, expected: canvas.Ui(MsgT).Tree, actual: canvas.Ui(MsgT).Tree) !void {
    var expected_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer expected_ids.deinit(testing.allocator);
    var actual_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer actual_ids.deinit(testing.allocator);
    try fixture.collectIds(expected.root, &expected_ids, testing.allocator);
    try fixture.collectIds(actual.root, &actual_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, expected_ids.items, actual_ids.items);

    try testing.expectEqual(expected.handlers.len, actual.handlers.len);
    for (expected.handlers, actual.handlers) |expected_handler, actual_handler| {
        try testing.expectEqual(expected_handler.id, actual_handler.id);
        try testing.expectEqual(expected_handler.event, actual_handler.event);
        try testing.expectEqual(std.meta.activeTag(expected_handler.action), std.meta.activeTag(actual_handler.action));
        switch (expected_handler.action) {
            .message => |msg| try testing.expect(std.meta.eql(msg, actual_handler.action.message)),
            .input => |make| try testing.expectEqual(make, actual_handler.action.input),
            .value => |make| try testing.expectEqual(make, actual_handler.action.value),
        }
    }
}

fn expectSameTexts(expected: canvas.Widget, actual: canvas.Widget) !void {
    try testing.expectEqual(expected.kind, actual.kind);
    try testing.expectEqualStrings(expected.text, actual.text);
    try testing.expectEqual(expected.state.selected, actual.state.selected);
    try testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |expected_child, actual_child| {
        try expectSameTexts(expected_child, actual_child);
    }
}

// --------------------------------------------------- inbox fixture parity

const InboxUi = canvas.Ui(fixture.Msg);
const InboxInterpreter = markup_view.MarkupView(fixture.Model, fixture.Msg);
const InboxCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, fixture.inbox_markup_source);

fn interpretInbox(arena: std.mem.Allocator, model: *const fixture.Model) !InboxUi.Tree {
    var view = try InboxInterpreter.init(arena, fixture.inbox_markup_source);
    var ui = InboxUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileInbox(arena: std.mem.Allocator, model: *const fixture.Model) !InboxUi.Tree {
    var ui = InboxUi.init(arena);
    return ui.finalize(InboxCompiled.build(&ui, model));
}

test "compiled inbox view builds the interpreter's and the hand-written tree exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.testModel();

    const interpreted = try interpretInbox(arena, &model);
    const compiled = try compileInbox(arena, &model);
    var hand_ui = InboxUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handView(&hand_ui, &model));

    // The three engines agree node for node and handler for handler: the
    // compiled path covers `for` over a pub const array (filters) and an
    // arena fn (visible), `{a == b}` equality, on-input/on-submit/on-press/
    // on-toggle messages, and interpolation.
    try expectSameTree(fixture.Msg, hand, interpreted);
    try expectSameTree(fixture.Msg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Pointer dispatch parity.
    const add_button = fixture.findByKind(compiled.root, .button).?;
    try testing.expectEqual(fixture.Msg.add, compiled.msgForPointer(add_button.id, .up).?);
    const interpreted_checkbox = fixture.findByKind(interpreted.root, .checkbox).?;
    const compiled_checkbox = fixture.findByKind(compiled.root, .checkbox).?;
    try testing.expectEqual(interpreted_checkbox.id, compiled_checkbox.id);
    try testing.expectEqual(
        interpreted.msgForPointer(interpreted_checkbox.id, .up).?,
        compiled.msgForPointer(compiled_checkbox.id, .up).?,
    );

    // Keyboard dispatch parity, including the on-input constructor.
    const text_field = fixture.findByKind(compiled.root, .text_field).?;
    const typed = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = "x" };
    try testing.expectEqualStrings("x", compiled.msgForKeyboard(text_field.id, typed).?.draft.insert_text);
    const submit = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expectEqual(
        interpreted.msgForKeyboard(text_field.id, submit).?,
        compiled.msgForKeyboard(text_field.id, submit).?,
    );

    // Interpolated text parity down to the byte.
    try testing.expectEqualStrings("2 open", fixture.findByKind(compiled.root, .status_bar).?.text);
}

test "compiled keyed rows keep ids across model changes and filters dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = fixture.testModel();

    const first = try compileInbox(arena, &model);
    const first_checkbox = fixture.findByKind(first.root, .checkbox).?;

    // Dispatch the done filter through a compiled-view button.
    var done_msg: ?fixture.Msg = null;
    for (first.handlers) |handler| {
        if (handler.action == .message and handler.action.message == .set_filter) {
            if (handler.action.message.set_filter == .done) done_msg = handler.action.message;
        }
    }
    try testing.expectEqual(fixture.Filter.done, done_msg.?.set_filter);
    model.filter = done_msg.?.set_filter;

    const second = try compileInbox(arena, &model);
    const second_checkbox = fixture.findByKind(second.root, .checkbox).?;
    try testing.expect(first_checkbox.id != second_checkbox.id);
    try testing.expectEqual(@as(u32, 2), second.msgForPointer(second_checkbox.id, .up).?.toggle);

    // Back to all: the original first row returns with its original id, and
    // the interpreter agrees at every step.
    model.filter = .all;
    const third = try compileInbox(arena, &model);
    try testing.expectEqual(first_checkbox.id, fixture.findByKind(third.root, .checkbox).?.id);
    try expectSameTree(fixture.Msg, try interpretInbox(arena, &model), third);
}

// ------------------------- field-slice for, if/else, global-key fixture

const EntryStatus = enum { open, closed };

const Entry = struct {
    id: u32,
    label: []const u8,
    status: EntryStatus = .open,
};

const EntriesMsg = union(enum) {
    open_entry: u32,
    refresh,
};

const EntriesModel = struct {
    /// A plain slice field: the third `for` source kind (the inbox fixture
    /// covers pub const arrays and arena fns).
    entries: []const Entry = &.{},
    /// Optional binding: truthiness is only runtime-known.
    banner: ?[]const u8 = null,
    closed_status: EntryStatus = .closed,
};

const entries_markup =
    \\<column gap="4">
    \\  <if test="{banner}">
    \\    <text>bannered</text>
    \\  </if>
    \\  <else>
    \\    <text>plain</text>
    \\  </else>
    \\  <for each="entries" as="e" key="id">
    \\    <row global-key="{e.id}" gap="2" cross="center">
    \\      <if test="{e.status == closed_status}">
    \\        <badge>closed</badge>
    \\      </if>
    \\      <else>
    \\        <badge>open</badge>
    \\      </else>
    \\      <text grow="1">{e.label} #{e.id}</text>
    \\      <button size="sm" on-press="open_entry:{e.id}">Open</button>
    \\    </row>
    \\  </for>
    \\  <if test="{banner}">
    \\    <status-bar>{banner}</status-bar>
    \\  </if>
    \\</column>
;

const EntriesUi = canvas.Ui(EntriesMsg);
const EntriesInterpreter = markup_view.MarkupView(EntriesModel, EntriesMsg);
const EntriesCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, entries_markup);

fn interpretEntries(arena: std.mem.Allocator, model: *const EntriesModel) !EntriesUi.Tree {
    var view = try EntriesInterpreter.init(arena, entries_markup);
    var ui = EntriesUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileEntries(arena: std.mem.Allocator, model: *const EntriesModel) !EntriesUi.Tree {
    var ui = EntriesUi.init(arena);
    return ui.finalize(EntriesCompiled.build(&ui, model));
}

fn findText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findText(child, text)) |found| return found;
    }
    return null;
}

test "compiled field-slice for, if/else, and optional bindings match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{
        .{ .id = 11, .label = "first" },
        .{ .id = 22, .label = "second", .status = .closed },
        .{ .id = 33, .label = "third" },
    };

    // Optional none: the else branch renders, the trailing if disappears.
    var model = EntriesModel{ .entries = &entries };
    const plain_interpreted = try interpretEntries(arena, &model);
    const plain_compiled = try compileEntries(arena, &model);
    try expectSameTree(EntriesMsg, plain_interpreted, plain_compiled);
    try expectSameTexts(plain_interpreted.root, plain_compiled.root);
    try testing.expect(findText(plain_compiled.root, "plain") != null);
    try testing.expect(findText(plain_compiled.root, "bannered") == null);
    try testing.expect(findText(plain_compiled.root, "second #22") != null);
    try testing.expect(findText(plain_compiled.root, "closed") != null);
    try testing.expect(findText(plain_compiled.root, "open") != null);

    // Optional some: both ifs flip, and the status bar interpolates the
    // optional's payload.
    model.banner = "hello";
    const bannered_interpreted = try interpretEntries(arena, &model);
    const bannered_compiled = try compileEntries(arena, &model);
    try expectSameTree(EntriesMsg, bannered_interpreted, bannered_compiled);
    try expectSameTexts(bannered_interpreted.root, bannered_compiled.root);
    try testing.expect(findText(bannered_compiled.root, "bannered") != null);
    try testing.expect(findText(bannered_compiled.root, "plain") == null);
    try testing.expectEqualStrings("hello", fixture.findByKind(bannered_compiled.root, .status_bar).?.text);

    // Message payloads built from loop items dispatch identically.
    const open_button = fixture.findByKind(plain_compiled.root, .button).?;
    try testing.expectEqual(
        plain_interpreted.msgForPointer(open_button.id, .up).?,
        plain_compiled.msgForPointer(open_button.id, .up).?,
    );
    try testing.expectEqual(@as(u32, 11), plain_compiled.msgForPointer(open_button.id, .up).?.open_entry);
}

test "compiled global-key rows keep their ids across reorders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const forward = [_]Entry{
        .{ .id = 11, .label = "first" },
        .{ .id = 22, .label = "second" },
    };
    const reversed = [_]Entry{
        .{ .id = 22, .label = "second" },
        .{ .id = 11, .label = "first" },
    };

    var model = EntriesModel{ .entries = &forward };
    const before = try compileEntries(arena, &model);
    const first_before = findText(before.root, "first #11").?;

    model.entries = &reversed;
    const after = try compileEntries(arena, &model);
    const first_after = findText(after.root, "first #11").?;

    // global-key (declared in markup, resolved at comptime) pins identity
    // independent of position — and the interpreter agrees.
    try testing.expectEqual(first_before.id, first_after.id);
    try expectSameTree(EntriesMsg, try interpretEntries(arena, &model), after);
}

test "the compiled path accepts every element the validator knows" {
    for (canvas.ui_markup.known_element_names) |name| {
        try testing.expect(markup_view.elementKind(name) != null);
    }
}

// ------------------------------------------- template/use + style parity

fn expectSameStyles(expected: canvas.Widget, actual: canvas.Widget) !void {
    try testing.expect(std.meta.eql(expected.style, actual.style));
    try testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |expected_child, actual_child| {
        try expectSameStyles(expected_child, actual_child);
    }
}

const TemplateUi = fixture.TemplateUi;
const TemplateInterpreter = markup_view.MarkupView(fixture.TemplateModel, fixture.TemplateMsg);
const TemplateCompiled = canvas.CompiledMarkupView(fixture.TemplateModel, fixture.TemplateMsg, fixture.template_markup_source);

fn interpretTemplates(arena: std.mem.Allocator, model: *const fixture.TemplateModel, tokens: canvas.DesignTokens) !TemplateUi.Tree {
    var view = try TemplateInterpreter.init(arena, fixture.template_markup_source);
    var ui = TemplateUi.init(arena);
    return ui.finalizeWithTokens(try view.build(&ui, model), tokens);
}

fn compileTemplates(arena: std.mem.Allocator, model: *const fixture.TemplateModel, tokens: canvas.DesignTokens) !TemplateUi.Tree {
    var ui = TemplateUi.init(arena);
    return ui.finalizeWithTokens(TemplateCompiled.build(&ui, model), tokens);
}

test "compiled templates with slice and value args match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.templateTestModel();
    const tokens = canvas.DesignTokens{};

    const interpreted = try interpretTemplates(arena, &model, tokens);
    const compiled = try compileTemplates(arena, &model, tokens);
    var hand_ui = TemplateUi.init(arena);
    const hand = try hand_ui.finalizeWithTokens(fixture.handTemplateView(&hand_ui, &model), tokens);

    // All three engines agree: ids, handlers, texts, and resolved styles.
    // The fixture covers a value arg (title), a slice arg iterated by a
    // for inside the template, a nested use whose arg binds a loop item
    // field, and style token attributes.
    try expectSameTree(fixture.TemplateMsg, hand, interpreted);
    try expectSameTree(fixture.TemplateMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try expectSameStyles(hand.root, interpreted.root);
    try expectSameStyles(hand.root, compiled.root);

    // Dispatch parity for a handler declared inside a template body.
    const pear_button = fixture.findByText(compiled.root, .button, "pear").?;
    try testing.expectEqual(
        interpreted.msgForPointer(pear_button.id, .up).?,
        compiled.msgForPointer(pear_button.id, .up).?,
    );
    try testing.expectEqual(@as(u32, 2), compiled.msgForPointer(pear_button.id, .up).?.pick);

    // Style token references resolved to the same concrete values.
    const badge = fixture.findByText(compiled.root, .badge, "apple").?;
    try testing.expectEqualDeep(tokens.colors.surface, badge.style.background.?);
    try testing.expectEqual(tokens.radius.md, badge.style.radius.?);
}

test "compiled template expansion keeps ids per use site and re-resolves tokens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.templateTestModel();

    const light = try compileTemplates(arena, &model, canvas.DesignTokens{});
    const top_text = fixture.findByText(light.root, .text, "Top").?;
    const bottom_text = fixture.findByText(light.root, .text, "Bottom").?;
    try testing.expect(top_text.id != bottom_text.id);

    // Retheme rebuild: same ids, new resolved colors — and the
    // interpreter agrees on both.
    const dark_tokens = canvas.DesignTokens.theme(.{ .color_scheme = .dark });
    const dark = try compileTemplates(arena, &model, dark_tokens);
    const dark_top_text = fixture.findByText(dark.root, .text, "Top").?;
    try testing.expectEqual(top_text.id, dark_top_text.id);
    try testing.expectEqualDeep(dark_tokens.colors.text_muted, dark_top_text.style.foreground.?);
    try testing.expect(!std.meta.eql(top_text.style.foreground.?, dark_top_text.style.foreground.?));

    const dark_interpreted = try interpretTemplates(arena, &model, dark_tokens);
    try expectSameTree(fixture.TemplateMsg, dark_interpreted, dark);
    try expectSameStyles(dark_interpreted.root, dark.root);
}
