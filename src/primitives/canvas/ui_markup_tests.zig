const std = @import("std");
const markup = @import("ui_markup.zig");

const testing = std.testing;

const inbox_source =
    \\<!-- The inbox mockup, adjusted to the shipped v1 grammar. -->
    \\<column gap="12" padding="16">
    \\  <row gap="8" cross="center">
    \\    <text-field placeholder="New task…" on-input="draft" on-submit="add" grow="1" />
    \\    <button variant="primary" on-press="add">Add</button>
    \\  </row>
    \\  <row gap="8">
    \\    <for each="filters" as="f">
    \\      <button selected="{f == filter}" on-press="set_filter:{f}">{f}</button>
    \\    </for>
    \\  </row>
    \\  <scroll grow="1">
    \\    <column gap="2">
    \\      <for each="visible" key="id" as="t">
    \\        <row gap="8" padding="6" cross="center" global-key="{t.id}">
    \\          <checkbox checked="{t.done}" on-toggle="toggle:{t.id}" />
    \\          <text grow="1">{t.title}</text>
    \\        </row>
    \\      </for>
    \\    </column>
    \\  </scroll>
    \\  <status-bar>{open_count} open · {done_count} done</status-bar>
    \\</column>
;

fn parseSource(arena: std.mem.Allocator, source: []const u8) !markup.MarkupDocument {
    var parser = markup.Parser.init(arena, source);
    return parser.parse();
}

test "parses the inbox mockup into the expected tree shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const document = try parseSource(arena_state.allocator(), inbox_source);
    const root = document.root;

    try testing.expectEqual(markup.MarkupNodeKind.element, root.kind);
    try testing.expectEqualStrings("column", root.name);
    try testing.expectEqualStrings("12", root.attr("gap").?);
    try testing.expectEqual(@as(usize, 4), root.children.len);

    const toolbar = root.children[0];
    try testing.expectEqualStrings("row", toolbar.name);
    try testing.expectEqualStrings("text-field", toolbar.children[0].name);
    try testing.expectEqualStrings("draft", toolbar.children[0].attr("on-input").?);

    const add_button = toolbar.children[1];
    try testing.expectEqualStrings("button", add_button.name);
    try testing.expectEqual(@as(usize, 1), add_button.children.len);
    try testing.expectEqual(markup.MarkupNodeKind.text, add_button.children[0].kind);
    try testing.expectEqualStrings("Add", add_button.children[0].text);

    const filters_row = root.children[1];
    const filters_for = filters_row.children[0];
    try testing.expectEqual(markup.MarkupNodeKind.for_block, filters_for.kind);
    try testing.expectEqualStrings("filters", filters_for.attr("each").?);
    try testing.expectEqualStrings("f", filters_for.attr("as").?);

    const tasks_for = root.children[2].children[0].children[0];
    try testing.expectEqual(markup.MarkupNodeKind.for_block, tasks_for.kind);
    try testing.expectEqualStrings("id", tasks_for.attr("key").?);
    const task_row = tasks_for.children[0];
    try testing.expectEqualStrings("{t.id}", task_row.attr("global-key").?);

    const status = root.children[3];
    try testing.expectEqualStrings("status-bar", status.name);
    try testing.expectEqualStrings("{open_count} open · {done_count} done", status.children[0].text);
}

test "reports syntax errors with line and column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const cases = [_]struct { source: []const u8, line: usize }{
        .{ .source = "<row>\n  <button>Add</row>\n</row>", .line = 2 },
        .{ .source = "<row gap=12></row>", .line = 1 },
        .{ .source = "<row><button>Add</button>", .line = 1 },
        .{ .source = "<row></row><row></row>", .line = 1 },
        .{ .source = "<row gap=\"8></row>", .line = 1 },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena_state.allocator(), case.source);
        try testing.expectError(error.MarkupSyntax, parser.parse());
        try testing.expect(parser.diagnostic.message.len > 0);
        try testing.expectEqual(case.line, parser.diagnostic.line);
    }
}

test "attribute expressions parse into the sanctioned forms only" {
    const literal = markup.parseAttrExpression("primary").?;
    try testing.expectEqualStrings("primary", literal.literal);

    const binding = markup.parseAttrExpression("{t.done}").?;
    try testing.expectEqualStrings("t.done", binding.binding);

    const equals = markup.parseAttrExpression("{f == filter}").?;
    try testing.expectEqualStrings("f", equals.equals.left);
    try testing.expectEqualStrings("filter", equals.equals.right);

    // Anything beyond bindings and one equality is rejected.
    try testing.expectEqual(@as(?markup.Expression, null), markup.parseAttrExpression("{a + b}"));
    try testing.expectEqual(@as(?markup.Expression, null), markup.parseAttrExpression("{call(a)}"));
    try testing.expectEqual(@as(?markup.Expression, null), markup.parseAttrExpression("{a == b == c}"));
    try testing.expectEqual(@as(?markup.Expression, null), markup.parseAttrExpression("{}"));
    try testing.expectEqual(@as(?markup.Expression, null), markup.parseAttrExpression("{unclosed"));
}

test "message expressions parse tag and optional payload binding" {
    const plain = markup.parseMessageExpression("add").?;
    try testing.expectEqualStrings("add", plain.tag);
    try testing.expectEqualStrings("", plain.payload);

    const with_payload = markup.parseMessageExpression("toggle:{t.id}").?;
    try testing.expectEqualStrings("toggle", with_payload.tag);
    try testing.expectEqualStrings("t.id", with_payload.payload);

    try testing.expectEqual(@as(?markup.MessageExpression, null), markup.parseMessageExpression("toggle:t.id"));
    try testing.expectEqual(@as(?markup.MessageExpression, null), markup.parseMessageExpression("toggle:{}"));
    try testing.expectEqual(@as(?markup.MessageExpression, null), markup.parseMessageExpression("1add"));
}

test "structural validation reports positions for grammar misuse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // The inbox fixture is fully valid.
    var parser = markup.Parser.init(arena_state.allocator(), inbox_source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<column>\n  <weird />\n</column>", .message = "unknown element" },
        .{ .source = "<column bogus=\"1\" />", .message = "unknown attribute" },
        .{ .source = "<row>\n  <button on-press=\"a + b\">X</button>\n</row>", .message = "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")" },
        .{ .source = "<row>\n  <button on-hover=\"x\">X</button>\n</row>", .message = "unknown event attribute" },
        .{ .source = "<row gap=\"{a + b}\" />", .message = "invalid expression: values are a literal, one {binding}, or one {a == b} equality - no other operators or calls (put logic in a model function)" },
        .{ .source = "<column>\n  <for as=\"t\"><text>x</text></for>\n</column>", .message = "for requires an each attribute" },
        .{ .source = "<column>\n  <if><text>x</text></if>\n</column>", .message = "if requires a test attribute" },
        .{ .source = "<column>\n  <else><text>x</text></else>\n</column>", .message = "else must directly follow an if" },
    };
    for (cases) |case| {
        var case_parser = markup.Parser.init(arena_state.allocator(), case.source);
        const info = markup.validate(try case_parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
    }
}
