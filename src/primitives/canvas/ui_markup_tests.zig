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

test "templates parse before the root and expose name and args" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const source =
        \\<template name="pill" args="label">
        \\  <badge>{label}</badge>
        \\</template>
        \\<template name="pill-row" args="a b">
        \\  <row gap="4">
        \\    <use template="pill" label="{a}" />
        \\    <use template="pill" label="{b}" />
        \\  </row>
        \\</template>
        \\<row>
        \\  <use template="pill-row" a="one" b="two" />
        \\</row>
    ;
    const document = try parseSource(arena_state.allocator(), source);
    try testing.expectEqual(@as(usize, 2), document.templates.len);
    try testing.expectEqualStrings("pill", document.templates[0].attr("name").?);
    try testing.expectEqual(@as(?usize, 1), document.templateIndex("pill-row"));
    try testing.expectEqual(@as(?usize, null), document.templateIndex("missing"));

    var args = markup.templateArgs(document.templates[1]);
    try testing.expectEqualStrings("a", args.next().?);
    try testing.expectEqualStrings("b", args.next().?);
    try testing.expectEqual(@as(?[]const u8, null), args.next());
    try testing.expect(markup.templateDeclaresArg(document.templates[0], "label"));
    try testing.expect(!markup.templateDeclaresArg(document.templates[0], "cards"));

    try testing.expectEqualStrings("row", document.root.name);
    try testing.expectEqual(markup.MarkupNodeKind.use_block, document.root.children[0].kind);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));
}

test "a template file without a view root is a parse error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var parser = markup.Parser.init(arena_state.allocator(), "<template name=\"only\"><text>x</text></template>");
    try testing.expectError(error.MarkupSyntax, parser.parse());
    try testing.expectEqualStrings("expected a view root element after the template definitions", parser.diagnostic.message);
}

test "template and use misuse is validated with positions and teaching messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // Templates must be top-level, named, unique, and single-bodied.
        .{ .source = "<column>\n  <template name=\"t\"><text>x</text></template>\n</column>", .message = markup.template_top_level_message },
        .{ .source = "<template args=\"a\"><text>x</text></template>\n<row />", .message = markup.template_name_message },
        .{ .source = "<template name=\"t\"><text>x</text></template>\n<template name=\"t\"><text>y</text></template>\n<row />", .message = markup.template_unique_name_message },
        .{ .source = "<template name=\"t\" args=\"a.b\"><text>x</text></template>\n<row />", .message = markup.template_args_message },
        .{ .source = "<template name=\"t\" bogus=\"1\"><text>x</text></template>\n<row />", .message = markup.template_attrs_message },
        .{ .source = "<template name=\"t\"><text>x</text><text>y</text></template>\n<row />", .message = markup.template_one_child_message },
        // Use sites must name a defined, earlier template and match its args.
        .{ .source = "<row>\n  <use />\n</row>", .message = markup.use_template_attr_message },
        .{ .source = "<row>\n  <use template=\"missing\" />\n</row>", .message = markup.use_undefined_template_message },
        .{ .source = "<template name=\"a\"><column><use template=\"b\" /></column></template>\n<template name=\"b\"><text>x</text></template>\n<row />", .message = markup.use_earlier_template_message },
        .{ .source = "<template name=\"t\" args=\"title\"><text>{title}</text></template>\n<row>\n  <use template=\"t\" />\n</row>", .message = markup.use_missing_arg_message },
        .{ .source = "<template name=\"t\"><text>x</text></template>\n<row>\n  <use template=\"t\" extra=\"1\" />\n</row>", .message = markup.use_extra_arg_message },
        .{ .source = "<template name=\"t\"><text>x</text></template>\n<row>\n  <use template=\"t\"><text>y</text></use>\n</row>", .message = markup.use_no_children_message },
        .{ .source = "<template name=\"t\" args=\"title\"><text>{title}</text></template>\n<row>\n  <use template=\"t\" title=\"{a + b}\" />\n</row>", .message = markup.invalid_expression_message },
        // A template using itself is a later-reference error (recursion).
        .{ .source = "<template name=\"loop\"><column><use template=\"loop\" /></column></template>\n<row />", .message = markup.use_earlier_template_message },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena_state.allocator(), case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
        try testing.expect(info.column > 0);
    }
}

test "style token attributes validate against the token name lists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Every color style attribute accepts every known color token name,
    // and radius accepts every radius token name.
    for (markup.known_color_style_attrs) |attr| {
        for (markup.known_color_token_names) |token| {
            const source = try std.fmt.allocPrint(arena_state.allocator(), "<row {s}=\"{s}\" />", .{ attr, token });
            var parser = markup.Parser.init(arena_state.allocator(), source);
            try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
        }
    }
    for (markup.known_radius_token_names) |token| {
        const source = try std.fmt.allocPrint(arena_state.allocator(), "<row radius=\"{s}\" />", .{token});
        var parser = markup.Parser.init(arena_state.allocator(), source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<row background=\"chartreuse\" />", .message = markup.unknown_color_token_message },
        .{ .source = "<row foreground=\"#ff0000\" />", .message = markup.unknown_color_token_message },
        .{ .source = "<row radius=\"tiny\" />", .message = markup.unknown_radius_token_message },
        .{ .source = "<row background=\"{accentColor}\" />", .message = markup.style_token_literal_message },
        .{ .source = "<row radius=\"{r}\" />", .message = markup.style_token_literal_message },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena_state.allocator(), case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
    }
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
