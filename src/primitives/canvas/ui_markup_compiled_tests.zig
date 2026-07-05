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
            .message => |msg| try expectSameMsg(MsgT, msg, actual_handler.action.message),
            .input => |make| try testing.expectEqual(make, actual_handler.action.input),
            .value => |make| try testing.expectEqual(make, actual_handler.action.value),
            .scroll => |make| try testing.expectEqual(make, actual_handler.action.scroll),
            // Context menus are builder-only (the closed markup grammar has
            // no list-valued attributes), so parity trees never carry them.
            .context_menu => |msgs| {
                const actual_msgs = actual_handler.action.context_menu;
                try testing.expectEqual(msgs.len, actual_msgs.len);
                for (msgs, actual_msgs) |expected_msg, actual_msg| {
                    try testing.expectEqual(expected_msg == null, actual_msg == null);
                    if (expected_msg) |msg| try expectSameMsg(MsgT, msg, actual_msg.?);
                }
            },
        }
    }
}

/// Messages are equal when their tag and payload agree; string payloads
/// compare by bytes (each engine formats arena-computed payloads into its
/// own arena, so pointer identity is not part of the contract).
fn expectSameMsg(comptime MsgT: type, expected: MsgT, actual: MsgT) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        inline else => |payload, tag| {
            const actual_payload = @field(actual, @tagName(tag));
            if (@TypeOf(payload) == []const u8) {
                try testing.expectEqualStrings(payload, actual_payload);
            } else {
                try testing.expect(std.meta.eql(payload, actual_payload));
            }
        },
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
    feed_scrolled: canvas.ScrollState,
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

// ------------------------------------------------ on-scroll parity

const scroll_feed_markup =
    \\<scroll on-scroll="feed_scrolled" on-reach-end="refresh">
    \\  <column gap="4">
    \\    <for each="entries" as="e" key="id">
    \\      <text>{e.label}</text>
    \\    </for>
    \\  </column>
    \\</scroll>
;

const ScrollFeedCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, scroll_feed_markup);

test "compiled on-scroll binds the ScrollState constructor identically to the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{.{ .id = 11, .label = "first" }};
    const model = EntriesModel{ .entries = &entries };

    var view = try markup_view.MarkupView(EntriesModel, EntriesMsg).init(arena, scroll_feed_markup);
    var interpreter_ui = EntriesUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = EntriesUi.init(arena);
    const compiled = try compiled_ui.finalize(ScrollFeedCompiled.build(&compiled_ui, &model));
    try expectSameTree(EntriesMsg, interpreted, compiled);

    // Both engines dispatch the same typed scroll Msg for the container.
    const feed = fixture.findByKind(compiled.root, .scroll_view).?;
    const state = canvas.ScrollState{ .offset = 40, .viewport_extent = 80, .content_extent = 200 };
    try testing.expectEqual(@as(f32, 40), compiled.msgForScroll(feed.id, state).?.feed_scrolled.offset);
    try testing.expectEqual(
        interpreted.msgForScroll(feed.id, state).?.feed_scrolled.offset,
        compiled.msgForScroll(feed.id, state).?.feed_scrolled.offset,
    );

    // And the same approach-end Msg (`on-reach-end`, the infinite-scroll
    // fetch signal) through both handler tables.
    try testing.expectEqual(EntriesMsg.refresh, compiled.msgForReachEnd(feed.id).?);
    try testing.expectEqual(interpreted.msgForReachEnd(feed.id).?, compiled.msgForReachEnd(feed.id).?);
}

// --------------------- multi-child for bodies and the for-empty else

const multi_entries_markup =
    \\<column gap="4">
    \\  <for each="entries" as="e" key="id">
    \\    <if test="{e.status == closed_status}">
    \\      <badge>closed</badge>
    \\    </if>
    \\    <else>
    \\      <badge>open</badge>
    \\    </else>
    \\    <text>{e.label}</text>
    \\    <text>#{e.id}</text>
    \\  </for>
    \\  <else>
    \\    <text>Nothing yet</text>
    \\  </else>
    \\</column>
;

const MultiEntriesCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, multi_entries_markup);

fn interpretMultiEntries(arena: std.mem.Allocator, model: *const EntriesModel) !EntriesUi.Tree {
    var view = try EntriesInterpreter.init(arena, multi_entries_markup);
    var ui = EntriesUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileMultiEntries(arena: std.mem.Allocator, model: *const EntriesModel) !EntriesUi.Tree {
    var ui = EntriesUi.init(arena);
    return ui.finalize(MultiEntriesCompiled.build(&ui, model));
}

test "compiled multi-child for bodies and the for-empty else match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{
        .{ .id = 11, .label = "first" },
        .{ .id = 22, .label = "second", .status = .closed },
    };

    // Non-empty: each item emits an if/else badge arm plus two same-kind
    // texts as siblings (no wrapper node), and the trailing else stays out.
    var model = EntriesModel{ .entries = &entries };
    const interpreted = try interpretMultiEntries(arena, &model);
    const compiled = try compileMultiEntries(arena, &model);
    try expectSameTree(EntriesMsg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try testing.expect(findText(compiled.root, "Nothing yet") == null);
    try testing.expect(findText(compiled.root, "first") != null);
    try testing.expect(findText(compiled.root, "#22") != null);
    try testing.expect(findText(compiled.root, "closed") != null);
    try testing.expect(findText(compiled.root, "open") != null);

    // Same-kind siblings from one keyed item stay distinct: the item key
    // slot-suffix keeps every structural id in the tree unique.
    var ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer ids.deinit(testing.allocator);
    try fixture.collectIds(compiled.root, &ids, testing.allocator);
    for (ids.items, 0..) |id, index| {
        for (ids.items[index + 1 ..]) |other| try testing.expect(id != other);
    }

    // Keyed identity survives reorders for every node an item emits.
    const label_before = findText(compiled.root, "first").?;
    const number_before = findText(compiled.root, "#11").?;
    const reversed = [_]Entry{
        .{ .id = 22, .label = "second", .status = .closed },
        .{ .id = 11, .label = "first" },
    };
    model.entries = &reversed;
    const reordered = try compileMultiEntries(arena, &model);
    try expectSameTree(EntriesMsg, try interpretMultiEntries(arena, &model), reordered);
    try testing.expectEqual(label_before.id, findText(reordered.root, "first").?.id);
    try testing.expectEqual(number_before.id, findText(reordered.root, "#11").?.id);

    // Empty: the trailing else renders the empty state in both engines.
    model.entries = &.{};
    const empty_interpreted = try interpretMultiEntries(arena, &model);
    const empty_compiled = try compileMultiEntries(arena, &model);
    try expectSameTree(EntriesMsg, empty_interpreted, empty_compiled);
    try expectSameTexts(empty_interpreted.root, empty_compiled.root);
    try testing.expect(findText(empty_compiled.root, "Nothing yet") != null);
    try testing.expect(findText(empty_interpreted.root, "Nothing yet") != null);
}

test "the compiled path accepts every element the validator knows" {
    for (canvas.ui_markup.known_element_names) |name| {
        try testing.expect(markup_view.elementKind(name) != null);
    }
}

const icon_markup_source =
    "<row gap=\"8\">\n" ++
    "  <icon name=\"search\" width=\"16\" height=\"16\" foreground=\"accent\" />\n" ++
    "  <text>Search</text>\n" ++
    "</row>";

test "compiled icons match the interpreter and carry the validated name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.Model{};

    var interpreter_view = try InboxInterpreter.init(arena, icon_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));

    const Compiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, icon_markup_source);
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.Msg, interpreted, compiled);
    const icon = compiled.root.children[0];
    try testing.expectEqual(canvas.WidgetKind.icon, icon.kind);
    try testing.expectEqualStrings("search", icon.text);
    try testing.expectEqual(canvas.WidgetKind.icon, interpreted.root.children[0].kind);
    try testing.expectEqualStrings("search", interpreted.root.children[0].text);
}

const button_icon_markup_source =
    "<row gap=\"8\">\n" ++
    "  <button icon=\"save\" on-press=\"add\">Save</button>\n" ++
    "  <button icon=\"refresh-cw\" on-press=\"add\" label=\"Refresh\"></button>\n" ++
    "  <toggle-button icon=\"arrow-up\" on-toggle=\"add\">Newest</toggle-button>\n" ++
    "  <list-item icon=\"folder\" on-press=\"add\">Projects</list-item>\n" ++
    "  <menu-item icon=\"trash\" on-press=\"add\">Delete</menu-item>\n" ++
    "</row>";

test "compiled button icons match the interpreter and carry the validated name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.Model{};

    var interpreter_view = try InboxInterpreter.init(arena, button_icon_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));

    const Compiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, button_icon_markup_source);
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.Msg, interpreted, compiled);
    for ([_]InboxUi.Tree{ interpreted, compiled }) |tree| {
        const labeled = tree.root.children[0];
        try testing.expectEqual(canvas.WidgetKind.button, labeled.kind);
        try testing.expectEqualStrings("save", labeled.icon);
        try testing.expectEqualStrings("Save", labeled.text);
        // Icon + label are ONE hit target: the icon has no child node and
        // the button's own press handler dispatches.
        try testing.expectEqual(@as(usize, 0), labeled.children.len);
        try testing.expect(tree.msgFor(labeled.id, .press) != null);
        const icon_only = tree.root.children[1];
        try testing.expectEqualStrings("refresh-cw", icon_only.icon);
        try testing.expectEqualStrings("", icon_only.text);
        try testing.expectEqualStrings("Refresh", icon_only.semantics.label);
        // The wider labeled interactive set compiles to the same
        // widgets in both engines.
        const chip = tree.root.children[2];
        try testing.expectEqual(canvas.WidgetKind.toggle_button, chip.kind);
        try testing.expectEqualStrings("arrow-up", chip.icon);
        const row_item = tree.root.children[3];
        try testing.expectEqual(canvas.WidgetKind.list_item, row_item.kind);
        try testing.expectEqualStrings("folder", row_item.icon);
        const menu_row = tree.root.children[4];
        try testing.expectEqual(canvas.WidgetKind.menu_item, menu_row.kind);
        try testing.expectEqualStrings("trash", menu_row.icon);
    }
}

// --------------------------------------------- component catalog parity

const CatalogUi = fixture.CatalogUi;
const CatalogInterpreter = markup_view.MarkupView(fixture.CatalogModel, fixture.CatalogMsg);
const CatalogCompiled = canvas.CompiledMarkupView(fixture.CatalogModel, fixture.CatalogMsg, fixture.catalog_markup_source);

fn interpretCatalog(arena: std.mem.Allocator, model: *const fixture.CatalogModel) !CatalogUi.Tree {
    var view = try CatalogInterpreter.init(arena, fixture.catalog_markup_source);
    var ui = CatalogUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileCatalog(arena: std.mem.Allocator, model: *const fixture.CatalogModel) !CatalogUi.Tree {
    var ui = CatalogUi.init(arena);
    return ui.finalize(CatalogCompiled.build(&ui, model));
}

test "compiled catalog elements match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.catalogTestModel();

    const interpreted = try interpretCatalog(arena, &model);
    const compiled = try compileCatalog(arena, &model);
    var hand_ui = CatalogUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handCatalogView(&hand_ui, &model));

    // All three engines agree on every new element: ids, handlers, texts.
    try expectSameTree(fixture.CatalogMsg, hand, interpreted);
    try expectSameTree(fixture.CatalogMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Dispatch parity across the new control kinds.
    const select = fixture.findByKind(compiled.root, .select).?;
    try testing.expectEqual(
        interpreted.msgForPointer(select.id, .up).?,
        compiled.msgForPointer(select.id, .up).?,
    );
    const switch_control = fixture.findByKind(compiled.root, .switch_control).?;
    try testing.expectEqual(fixture.CatalogMsg.toggle_bold, compiled.msgForPointer(switch_control.id, .up).?);
    const pears_cell = fixture.findByText(compiled.root, .data_cell, "Pears").?;
    try testing.expectEqual(
        interpreted.msgForPointer(pears_cell.id, .up).?,
        compiled.msgForPointer(pears_cell.id, .up).?,
    );
    try testing.expectEqual(@as(u32, 2), compiled.msgForPointer(pears_cell.id, .up).?.pick_row);

    // Text entry parity on the input element, including on-input.
    const input = fixture.findByKind(compiled.root, .input).?;
    const typed = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = "q" };
    try testing.expectEqualStrings("q", compiled.msgForKeyboard(input.id, typed).?.query_edit.insert_text);
    const submit = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expectEqual(
        interpreted.msgForKeyboard(input.id, submit).?,
        compiled.msgForKeyboard(input.id, submit).?,
    );
}

test "compiled catalog stays in parity when conditional surfaces flip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = fixture.catalogTestModel();
    model.loading = false;
    model.dialog_open = true;
    model.tab = 1;
    model.bold = true;
    model.page = 3;

    const interpreted = try interpretCatalog(arena, &model);
    const compiled = try compileCatalog(arena, &model);
    try expectSameTree(fixture.CatalogMsg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // The dialog branch renders with its title and dispatching child.
    const dialog = fixture.findByKind(compiled.root, .dialog).?;
    try testing.expectEqualStrings("Confirm", dialog.text);
    try testing.expect(fixture.findByKind(compiled.root, .spinner) == null);
    const yes_button = fixture.findByText(compiled.root, .button, "Yes").?;
    try testing.expectEqual(fixture.CatalogMsg.submit_query, compiled.msgForPointer(yes_button.id, .up).?);
    try testing.expectEqual(@as(u32, 2), compiled.msgForPointer(fixture.findByText(compiled.root, .button, "Prev").?.id, .up).?.set_page);
}

// ---------------------------------------------- arena-scalar binding parity

const ExpensesUi = fixture.ExpensesUi;
const ExpensesInterpreter = markup_view.MarkupView(fixture.ExpensesModel, fixture.ExpensesMsg);
const ExpensesCompiled = canvas.CompiledMarkupView(fixture.ExpensesModel, fixture.ExpensesMsg, fixture.expenses_markup_source);

fn interpretExpenses(arena: std.mem.Allocator, model: *const fixture.ExpensesModel) !ExpensesUi.Tree {
    var view = try ExpensesInterpreter.init(arena, fixture.expenses_markup_source);
    var ui = ExpensesUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileExpenses(arena: std.mem.Allocator, model: *const fixture.ExpensesModel) !ExpensesUi.Tree {
    var ui = ExpensesUi.init(arena);
    return ui.finalize(ExpensesCompiled.build(&ui, model));
}

test "compiled arena-scalar bindings match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.expensesTestModel();

    const interpreted = try interpretExpenses(arena, &model);
    const compiled = try compileExpenses(arena, &model);
    var hand_ui = ExpensesUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handExpensesView(&hand_ui, &model));

    // All three engines agree: the arena scalar flows through text
    // content, interpolation, an attribute value (label), a message
    // payload, an if test, and an item-level arena method.
    try expectSameTree(fixture.ExpensesMsg, hand, interpreted);
    try expectSameTree(fixture.ExpensesMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    try testing.expectEqualStrings("2 expenses · $12.94", fixture.findByKind(compiled.root, .status_bar).?.text);
    const labeled = fixture.findByText(compiled.root, .text, "all: 2 expenses · $12.94").?;
    try testing.expectEqualStrings("2 expenses · $12.94", labeled.semantics.label);
    try testing.expect(fixture.findByText(compiled.root, .badge, "summarized") != null);

    // Payload dispatch parity: the arena string rides the typed message.
    const pick_button = fixture.findByKind(compiled.root, .button).?;
    try testing.expectEqualStrings("$12.34", compiled.msgForPointer(pick_button.id, .up).?.pick);
    try testing.expectEqualStrings(
        interpreted.msgForPointer(pick_button.id, .up).?.pick,
        compiled.msgForPointer(pick_button.id, .up).?.pick,
    );
}

test "compiled string bindings pass to templates as value args" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.expensesTestModel();
    const source =
        "<template name=\"line\" args=\"title\"><text>{title}</text></template>\n" ++
        "<column>\n" ++
        "  <use template=\"line\" title=\"{filter}\" />\n" ++
        "  <use template=\"line\" title=\"{summary}\" />\n" ++
        "</column>";
    const Compiled = canvas.CompiledMarkupView(fixture.ExpensesModel, fixture.ExpensesMsg, source);

    var compiled_ui = ExpensesUi.init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    var view = try ExpensesInterpreter.init(arena, source);
    var interpreted_ui = ExpensesUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    try expectSameTree(fixture.ExpensesMsg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try testing.expect(findText(compiled.root, "all") != null);
    try testing.expect(findText(compiled.root, "2 expenses · $12.94") != null);
}

// -------------------------------------------------- markdown element parity

const DocUi = fixture.DocUi;
const DocInterpreter = markup_view.MarkupView(fixture.DocModel, fixture.DocMsg);
const DocCompiled = canvas.CompiledMarkupView(fixture.DocModel, fixture.DocMsg, fixture.doc_markup_source);

fn interpretDoc(arena: std.mem.Allocator, model: *const fixture.DocModel) !DocUi.Tree {
    var view = try DocInterpreter.init(arena, fixture.doc_markup_source);
    var ui = DocUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileDoc(arena: std.mem.Allocator, model: *const fixture.DocModel) !DocUi.Tree {
    var ui = DocUi.init(arena);
    return ui.finalize(DocCompiled.build(&ui, model));
}

test "compiled markdown element matches the interpreter and the hand-written Md.view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = fixture.DocModel{};

    const interpreted = try interpretDoc(arena, &model);
    const compiled = try compileDoc(arena, &model);
    var hand_ui = DocUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handDocView(&hand_ui, &model));

    try expectSameTree(fixture.DocMsg, hand, interpreted);
    try expectSameTree(fixture.DocMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Link dispatch parity, including the payload URL.
    const link = fixture.findByRole(compiled.root, .link).?;
    try testing.expectEqualStrings("https://example.com/guide", compiled.msgForPointer(link.id, .up).?.open_url);
    try testing.expectEqualStrings(
        interpreted.msgForPointer(link.id, .up).?.open_url,
        compiled.msgForPointer(link.id, .up).?.open_url,
    );

    // Autolink parity: issue refs through the issue-link-base binding and
    // bare URLs resolve to the same targets in both engines.
    try testing.expectEqualStrings("ghissue://12", fixture.findSpanLink(compiled.root, "#12").?);
    try testing.expectEqualStrings(
        fixture.findSpanLink(interpreted.root, "#12").?,
        fixture.findSpanLink(compiled.root, "#12").?,
    );
    try testing.expectEqualStrings(
        fixture.findSpanLink(interpreted.root, "https://status.example.com").?,
        fixture.findSpanLink(compiled.root, "https://status.example.com").?,
    );

    // Details dispatch parity: the summary press carries the block index.
    const summary_item = fixture.findByKind(compiled.root, .list_item).?;
    try testing.expectEqual(@as(usize, 0), compiled.msgForPointer(summary_item.id, .up).?.toggle_details);
    try testing.expect(findText(compiled.root, "Enable for 5% of traffic.") == null);

    // Expanding through the caller-owned flag keeps the engines in step.
    model.details_expanded[0] = true;
    const expanded_interpreted = try interpretDoc(arena, &model);
    const expanded_compiled = try compileDoc(arena, &model);
    try expectSameTree(fixture.DocMsg, expanded_interpreted, expanded_compiled);
    try expectSameTexts(expanded_interpreted.root, expanded_compiled.root);
    try testing.expect(findText(expanded_compiled.root, "Enable for 5% of traffic.") != null);

    // The summary keeps its id across the expand (keyed by details index).
    try testing.expectEqual(summary_item.id, fixture.findByKind(expanded_compiled.root, .list_item).?.id);
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

// ------------------------------------------- avatar image binding parity

const AvatarUi = fixture.AvatarUi;
const AvatarInterpreter = markup_view.MarkupView(fixture.AvatarModel, fixture.AvatarMsg);
const AvatarCompiled = canvas.CompiledMarkupView(fixture.AvatarModel, fixture.AvatarMsg, fixture.avatar_markup_source);

test "compiled avatar image binding matches the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.AvatarModel{ .user_image = 7 };

    var view = try AvatarInterpreter.init(arena, fixture.avatar_markup_source);
    var interpreted_ui = AvatarUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = AvatarUi.init(arena);
    const compiled = try compiled_ui.finalize(AvatarCompiled.build(&compiled_ui, &model));

    var hand_ui = AvatarUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handAvatarView(&hand_ui, &model));

    try expectSameTree(fixture.AvatarMsg, hand, interpreted);
    try expectSameTree(fixture.AvatarMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // The field binding and the fn binding both resolve to the widget's
    // image id at comptime-unrolled access, with the Ui.avatar cover fit.
    const field_avatar = fixture.findByText(compiled.root, .avatar, "CT").?;
    try testing.expectEqual(@as(canvas.ImageId, 7), field_avatar.image_id);
    try testing.expectEqual(canvas.ImageFit.cover, field_avatar.image_fit);
    try testing.expectEqual(@as(canvas.ImageId, 8), fixture.findByText(compiled.root, .avatar, "NS").?.image_id);

    // 0 keeps the initials fallback in both engines.
    const empty_model = fixture.AvatarModel{};
    var empty_ui = AvatarUi.init(arena);
    const empty = try empty_ui.finalize(AvatarCompiled.build(&empty_ui, &empty_model));
    try testing.expectEqual(@as(canvas.ImageId, 0), fixture.findByText(empty.root, .avatar, "CT").?.image_id);
    try testing.expectEqualStrings("CT", fixture.findByText(empty.root, .avatar, "CT").?.text);
}

// ------------------------------------------------------ text wrap parity

const WrapUi = fixture.WrapUi;
const WrapInterpreter = markup_view.MarkupView(fixture.WrapModel, fixture.WrapMsg);
const WrapCompiled = canvas.CompiledMarkupView(fixture.WrapModel, fixture.WrapMsg, fixture.wrap_markup_source);

test "compiled wrap attribute matches the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.WrapModel{};

    var view = try WrapInterpreter.init(arena, fixture.wrap_markup_source);
    var interpreted_ui = WrapUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = WrapUi.init(arena);
    const compiled = try compiled_ui.finalize(WrapCompiled.build(&compiled_ui, &model));

    var hand_ui = WrapUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handWrapView(&hand_ui, &model));

    try expectSameTree(fixture.WrapMsg, hand, interpreted);
    try expectSameTree(fixture.WrapMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Both engines produce the single-span paragraph conversion.
    const compiled_wrapped = compiled.root.children[0];
    try testing.expectEqual(@as(usize, 1), compiled_wrapped.spans.len);
    try testing.expectEqualStrings(model.message, compiled_wrapped.text);
    try testing.expectEqual(@as(usize, 0), compiled.root.children[1].spans.len);
    try testing.expect(!compiled.root.children[1].text_no_wrap);
    // And both stamp wrap="false" as the honest single-line mode.
    const compiled_no_wrap = compiled.root.children[2];
    try testing.expectEqual(@as(usize, 0), compiled_no_wrap.spans.len);
    try testing.expect(compiled_no_wrap.text_no_wrap);
    try testing.expect(interpreted.root.children[2].text_no_wrap);
    // The definite width lands in both bounds.
    try testing.expectEqual(@as(f32, 360), compiled.root.layout.min_size.width);
    try testing.expectEqual(@as(f32, 360), compiled.root.layout.max_size.width);
}

// -------------------------------- text alignment and grid columns parity

const AlignUi = fixture.AlignUi;
const AlignInterpreter = markup_view.MarkupView(fixture.AlignModel, fixture.AlignMsg);
const AlignCompiled = canvas.CompiledMarkupView(fixture.AlignModel, fixture.AlignMsg, fixture.align_markup_source);

test "compiled text-alignment and grid columns match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.AlignModel{};

    var view = try AlignInterpreter.init(arena, fixture.align_markup_source);
    var interpreted_ui = AlignUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = AlignUi.init(arena);
    const compiled = try compiled_ui.finalize(AlignCompiled.build(&compiled_ui, &model));

    var hand_ui = AlignUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handAlignView(&hand_ui, &model));

    try expectSameTree(fixture.AlignMsg, hand, interpreted);
    try expectSameTree(fixture.AlignMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Both engines land the alignment and the column counts.
    try testing.expectEqual(canvas.TextAlign.center, compiled.root.children[0].text_alignment);
    try testing.expectEqualDeep((canvas.DesignTokens{}).colors.info, compiled.root.children[0].style.foreground.?);
    try testing.expectEqual(@as(usize, 4), compiled.root.children[1].layout.columns);
    try testing.expectEqual(@as(usize, 3), compiled.root.children[2].layout.columns);
}

// --------------------------------- pressable rows (press fall-through)

const pressable_rows_markup =
    \\<column gap="4">
    \\  <for each="entries" as="e" key="id">
    \\    <panel on-press="open_entry:{e.id}" padding="8" role="listitem" label="{e.label}">
    \\      <row gap="8" cross="center">
    \\        <text grow="1">{e.label}</text>
    \\        <badge>#{e.id}</badge>
    \\      </row>
    \\    </panel>
    \\  </for>
    \\  <row on-press="refresh" gap="8">
    \\    <text>Refresh feed</text>
    \\  </row>
    \\</column>
;

const PressableRowsCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, pressable_rows_markup);

test "compiled pressable rows (panel and layout containers) match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{
        .{ .id = 7, .label = "Ship the IR" },
        .{ .id = 9, .label = "Write decisions" },
    };
    const model = EntriesModel{ .entries = &entries };

    var view = try EntriesInterpreter.init(arena, pressable_rows_markup);
    var interpreter_ui = EntriesUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = EntriesUi.init(arena);
    const compiled = try compiled_ui.finalize(PressableRowsCompiled.build(&compiled_ui, &model));
    try expectSameTree(EntriesMsg, interpreted, compiled);

    // Both engines make the pressable panel row a press claimer that
    // dispatches the payload-carrying Msg, with its text falling through.
    const first_row = fixture.findByKind(compiled.root, .panel).?;
    try testing.expectEqualStrings("Ship the IR", first_row.semantics.label);
    try testing.expect(canvas.widgetClaimsPress(first_row));
    try testing.expectEqual(@as(u32, 7), compiled.msgForPointer(first_row.id, .up).?.open_entry);
    try testing.expect(!canvas.widgetClaimsPress(first_row.children[0].children[0]));

    // A LAYOUT container with on-press is a widget-level hit target in
    // both engines — the handler stamps the press action.
    var pressable_row: ?canvas.Widget = null;
    for (compiled.root.children) |child| {
        if (child.kind == .row and child.semantics.actions.press) pressable_row = child;
    }
    try testing.expect(pressable_row != null);
    try testing.expect(canvas.widgetIsHitTarget(pressable_row.?));
    try testing.expectEqual(EntriesMsg.refresh, compiled.msgForPointer(pressable_row.?.id, .up).?);
}

// -------------------------------------------------- anchored picker parity

const PickerCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, fixture.picker_markup_source);

test "compiled anchored picker (anchor, on-dismiss, on-hold) matches the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.Model{};

    var view = try InboxInterpreter.init(arena, fixture.picker_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(PickerCompiled.build(&compiled_ui, &model));
    try expectSameTree(fixture.Msg, interpreted, compiled);

    // Both engines resolve the anchor attributes into the same layout
    // channel and bind the dismiss/hold handlers identically.
    const dropdown = fixture.findByKind(compiled.root, .dropdown_menu).?;
    const anchor = dropdown.layout.anchor orelse return error.TestUnexpectedResult;
    try testing.expectEqual(canvas.WidgetAnchorPlacement.below, anchor.placement);
    try testing.expectEqual(canvas.WidgetAnchorAlignment.stretch, anchor.alignment);
    try testing.expectEqual(@as(f32, 6), anchor.offset);
    try testing.expect(compiled.msgFor(dropdown.id, .dismiss) != null);
    const crumb = fixture.findByKind(compiled.root, .button).?;
    try testing.expect(compiled.msgFor(crumb.id, .hold) != null);
    try testing.expect(crumb.semantics.actions.press);
}

// -------------------------------------------------- split panes and trees

const PaneCompiled = canvas.CompiledMarkupView(fixture.PaneModel, fixture.PaneMsg, fixture.pane_markup_source);

test "compiled split and tree match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.PaneModel{};

    var view = try markup_view.MarkupView(fixture.PaneModel, fixture.PaneMsg).init(arena, fixture.pane_markup_source);
    var interpreter_ui = fixture.PaneUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = fixture.PaneUi.init(arena);
    const compiled = try compiled_ui.finalize(PaneCompiled.build(&compiled_ui, &model));
    try expectSameTree(fixture.PaneMsg, interpreted, compiled);

    var hand_ui = fixture.PaneUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handPaneView(&hand_ui, &model));
    try expectSameTree(fixture.PaneMsg, hand, compiled);

    // The synthesized divider and the resize dispatch agree across engines.
    try testing.expectEqual(canvas.WidgetKind.split_divider, compiled.root.children[1].kind);
    try testing.expectEqual(@as(f32, 0.7), compiled.msgForResize(compiled.root.id, 0.7).?.sidebar_resized);
    try testing.expectEqual(
        interpreted.msgForResize(interpreted.root.id, 0.7).?.sidebar_resized,
        compiled.msgForResize(compiled.root.id, 0.7).?.sidebar_resized,
    );

    // Tree rows: role, expanded state, and both dispatch channels.
    const row = fixture.findByKind(compiled.root, .panel).?;
    try testing.expectEqual(canvas.WidgetRole.treeitem, row.semantics.role);
    try testing.expectEqual(@as(?bool, true), row.state.expanded);
    try testing.expectEqual(@as(u32, 1), compiled.msgForPointer(row.id, .up).?.select_folder);
    try testing.expectEqual(@as(u32, 1), compiled.msgFor(row.id, .toggle).?.toggle_folder);
}
