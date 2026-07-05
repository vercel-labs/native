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
    const root = document.root.?;

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

test "attribute expressions classify into the sanctioned forms" {
    const literal = markup.parseAttrExpression("primary").?;
    try testing.expectEqualStrings("primary", literal.literal);

    const binding = markup.parseAttrExpression("{t.done}").?;
    try testing.expectEqualStrings("t.done", binding.binding);

    const equals = markup.parseAttrExpression("{f == filter}").?;
    try testing.expectEqualStrings("f", equals.equals.left);
    try testing.expectEqualStrings("filter", equals.equals.right);

    // Everything else brace-wrapped classifies as a full expression: the
    // grammar (and its teaching errors) live in the expression core, which
    // `attrExpressionError` and the engines run.
    const arithmetic = markup.parseAttrExpression("{a + b}").?;
    try testing.expectEqualStrings("a + b", arithmetic.expression);
    try testing.expect(markup.attrExpressionError("{a + b}", "fallback") == null);
    try testing.expect(markup.attrExpressionError("{count > 0 and not busy}", "fallback") == null);
    try testing.expect(markup.attrExpressionError("{plural(n, 'item', 'items')}", "fallback") == null);

    // Invalid expressions surface the core's specific messages.
    try testing.expectEqualStrings(
        markup.expr.unknown_function_message,
        markup.attrExpressionError("{call(a)}", "fallback").?,
    );
    try testing.expectEqualStrings(
        markup.expr.comparison_chain_message,
        markup.attrExpressionError("{a == b == c}", "fallback").?,
    );
    try testing.expectEqualStrings(
        markup.expr.clock_function_message,
        markup.attrExpressionError("{now()}", "fallback").?,
    );
    try testing.expectEqualStrings(
        markup.expr.arithmetic_type_message,
        markup.attrExpressionError("{'a' - 1}", "fallback").?,
    );

    // Values that do not even classify keep the caller's message.
    try testing.expectEqual(@as(?markup.Expression, null), markup.parseAttrExpression("{}"));
    try testing.expectEqual(@as(?markup.Expression, null), markup.parseAttrExpression("{unclosed"));
    try testing.expectEqualStrings("fallback", markup.attrExpressionError("{}", "fallback").?);
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

    try testing.expectEqualStrings("row", document.root.?.name);
    try testing.expectEqual(markup.MarkupNodeKind.use_block, document.root.?.children[0].kind);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));
}

test "a template file without a view root parses as a component file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Valid as an import target: all templates, no view root. The engines
    // reject building it as a view with their own teaching error.
    var parser = markup.Parser.init(arena_state.allocator(), "<template name=\"only\"><text>x</text></template>");
    const document = try parser.parse();
    try testing.expectEqual(@as(?markup.MarkupNode, null), document.root);
    try testing.expectEqual(@as(usize, 1), document.templates.len);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));

    // A file with nothing at all stays an error.
    var empty_parser = markup.Parser.init(arena_state.allocator(), "  <!-- just a comment -->\n");
    try testing.expectError(error.MarkupSyntax, empty_parser.parse());
    try testing.expectEqualStrings(markup.empty_document_message, empty_parser.diagnostic.message);
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
        .{ .source = "<template name=\"t\"><text>x</text></template>\n<row>\n  <use template=\"t\"><text>y</text></use>\n</row>", .message = markup.use_children_without_slot_message },
        .{ .source = "<template name=\"t\" args=\"title\"><text>{title}</text></template>\n<row>\n  <use template=\"t\" title=\"{a ++}\" />\n</row>", .message = markup.expr.expected_operand_message },
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

    // on-scroll validates on the scroll element itself.
    const scrollable = "<scroll on-scroll=\"scrolled\">\n  <column><text>x</text></column>\n</scroll>";
    var scrollable_parser = markup.Parser.init(arena_state.allocator(), scrollable);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try scrollable_parser.parse()));

    // on-reach-end (the infinite-scroll fetch signal) validates on the
    // scroll element too, with or without a payload.
    const reachable = "<scroll on-reach-end=\"load_more\" on-scroll=\"scrolled\">\n  <column><text>x</text></column>\n</scroll>";
    var reachable_parser = markup.Parser.init(arena_state.allocator(), reachable);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try reachable_parser.parse()));

    // A built-in vector icon with a literal name and token tint is valid.
    const icon_source = "<row gap=\"8\">\n  <icon name=\"search\" width=\"16\" height=\"16\" foreground=\"accent\" />\n  <text>Search</text>\n</row>";
    var icon_parser = markup.Parser.init(arena_state.allocator(), icon_source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try icon_parser.parse()));

    // The labeled interactive elements take an inline icon (with or
    // without a label): one hit target, one tint. Toggle-buttons cover
    // chips and tab strips; list/menu items get a leading slot.
    const button_icon_source = "<row gap=\"8\">\n  <button icon=\"save\" on-press=\"save\">Save</button>\n  <button icon=\"refresh-cw\" on-press=\"refresh\" label=\"Refresh\"></button>\n  <toggle-button icon=\"arrow-up\" on-toggle=\"sort\">Newest</toggle-button>\n  <list-item icon=\"folder\" on-press=\"open\">Projects</list-item>\n  <menu-item icon=\"trash\" on-press=\"remove\">Delete</menu-item>\n  <badge icon=\"check\">3</badge>\n</row>";
    var button_icon_parser = markup.Parser.init(arena_state.allocator(), button_icon_source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try button_icon_parser.parse()));

    // Autofocus on focusable controls: literal or bound.
    const autofocus_source = "<column gap=\"8\">\n  <text-field autofocus=\"true\" on-input=\"edit\" />\n  <textarea autofocus=\"{editing}\" on-input=\"edit\" />\n</column>";
    var autofocus_parser = markup.Parser.init(arena_state.allocator(), autofocus_source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try autofocus_parser.parse()));

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<column>\n  <weird />\n</column>", .message = "unknown element" },
        .{ .source = "<column bogus=\"1\" />", .message = "unknown attribute" },
        .{ .source = "<row>\n  <button on-press=\"a + b\">X</button>\n</row>", .message = "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")" },
        .{ .source = "<row>\n  <button on-hover=\"x\">X</button>\n</row>", .message = "unknown event attribute" },
        .{ .source = "<column>\n  <row on-change=\"select\">\n    <text>press me</text>\n  </row>\n</column>", .message = markup.non_hit_target_handler_message },
        .{ .source = "<column on-input=\"draft\">\n  <text>x</text>\n</column>", .message = markup.non_hit_target_handler_message },
        .{ .source = "<table>\n  <table-row on-submit=\"pick\">\n    <table-cell>x</table-cell>\n  </table-row>\n</table>", .message = markup.non_hit_target_handler_message },
        .{ .source = "<row>\n  <badge on-change=\"x\">3</badge>\n</row>", .message = markup.non_hit_target_handler_message },
        // Full expressions are valid attribute values now; broken ones
        // surface the expression core's specific teaching message.
        .{ .source = "<row gap=\"{a +}\" />", .message = markup.expr.expected_operand_message },
        .{ .source = "<row gap=\"{count(a)}\" />", .message = markup.expr.unknown_function_message },
        .{ .source = "<row gap=\"{now()}\" />", .message = markup.expr.clock_function_message },
        .{ .source = "<row gap=\"{'a' - 1}\" />", .message = markup.expr.arithmetic_type_message },
        .{ .source = "<column>\n  <for as=\"t\"><text>x</text></for>\n</column>", .message = "for requires an each attribute" },
        .{ .source = "<column>\n  <if><text>x</text></if>\n</column>", .message = "if requires a test attribute" },
        .{ .source = "<column>\n  <else><text>x</text></else>\n</column>", .message = markup.else_placement_message },
        .{ .source = "<row>\n  <button on-scroll=\"scrolled\">X</button>\n</row>", .message = markup.on_scroll_element_message },
        .{ .source = "<column>\n  <list on-scroll=\"scrolled\"><list-item>x</list-item></list>\n</column>", .message = markup.on_scroll_element_message },
        .{ .source = "<row>\n  <button on-reach-end=\"load_more\">X</button>\n</row>", .message = markup.on_reach_end_element_message },
        .{ .source = "<column>\n  <list on-reach-end=\"load_more\"><list-item>x</list-item></list>\n</column>", .message = markup.on_reach_end_element_message },
        .{ .source = "<column>\n  <text>x</text>\n  <else><text>y</text></else>\n</column>", .message = markup.else_placement_message },
        .{ .source = "<column>\n  <for each=\"items\" as=\"t\"></for>\n</column>", .message = markup.for_children_message },
        .{ .source = "<column>\n  <for each=\"items\" as=\"t\">stray text</for>\n</column>", .message = markup.for_children_message },
        // Icon: closed literal name vocabulary, leaf, icon-scoped attr.
        .{ .source = "<row>\n  <icon />\n</row>", .message = markup.icon_missing_name_message },
        .{ .source = "<row>\n  <icon name=\"sparkle-pony\" />\n</row>", .message = markup.icon_name_message },
        .{ .source = "<row>\n  <icon name=\"{binding}\" />\n</row>", .message = markup.icon_name_message },
        .{ .source = "<row>\n  <badge name=\"search\">3</badge>\n</row>", .message = markup.icon_name_element_message },
        .{ .source = "<row>\n  <icon name=\"search\"><text>x</text></icon>\n</row>", .message = markup.icon_children_message },
        .{ .source = "<row>\n  <icon name=\"search\" on-change=\"go\" />\n</row>", .message = markup.non_hit_target_handler_message },
        // Button icon attr: closed literal vocabulary, button-scoped.
        .{ .source = "<row>\n  <button icon=\"sparkle-pony\">Save</button>\n</row>", .message = markup.button_icon_message },
        .{ .source = "<row>\n  <button icon=\"{binding}\">Save</button>\n</row>", .message = markup.button_icon_message },
        .{ .source = "<row>\n  <badge icon=\"sparkle-pony\">3</badge>\n</row>", .message = markup.button_icon_message },
        .{ .source = "<row>\n  <toggle-button icon=\"sparkle-pony\">Bold</toggle-button>\n</row>", .message = markup.button_icon_message },
        .{ .source = "<column>\n  <checkbox icon=\"check\">Done</checkbox>\n</column>", .message = markup.button_icon_element_message },
        // Autofocus needs a focusable control; layout and decoration
        // elements can never take the keyboard.
        .{ .source = "<column>\n  <row autofocus=\"true\">\n    <text>x</text>\n  </row>\n</column>", .message = markup.autofocus_element_message },
        .{ .source = "<column>\n  <badge autofocus=\"true\">3</badge>\n</column>", .message = markup.autofocus_element_message },
    };
    for (cases) |case| {
        var case_parser = markup.Parser.init(arena_state.allocator(), case.source);
        const info = markup.validate(try case_parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
    }
}


test "the tofu guard flags markup literals outside the bundled font's coverage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Everything the showcase apps ship passes: typographic punctuation,
    // accents, arrows are in the bundled face.
    const covered_source = "<column gap=\"8\">\n  <text>Cafe\xc3\xa9 \xe2\x80\xa6 \xc2\xb7 \xe2\x86\x92</text>\n  <text-field placeholder=\"Search albums\xe2\x80\xa6\" on-input=\"edit\" />\n</column>";
    var covered_parser = markup.Parser.init(arena_state.allocator(), covered_source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try covered_parser.parse()));

    // Binding spans are skipped: dynamic values are the runtime Debug
    // warning's job, not the static guard's.
    const binding_source = "<column>\n  <text>{shortcutHint} to send</text>\n</column>";
    var binding_parser = markup.Parser.init(arena_state.allocator(), binding_source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try binding_parser.parse()));

    // A ⌘ in text content errors AT the character's position.
    const text_source = "<column>\n  <text>Press \xe2\x8c\x98K to search</text>\n</column>";
    var text_parser = markup.Parser.init(arena_state.allocator(), text_source);
    const text_info = markup.validate(try text_parser.parse()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(markup.font_coverage_message, text_info.message);
    try testing.expectEqual(@as(usize, 2), text_info.line);
    try testing.expectEqual(@as(usize, 15), text_info.column);

    // Text-bearing attribute literals ride the same guard.
    const attr_cases = [_][]const u8{
        "<row>\n  <button label=\"\xe2\x8c\x98K\" on-press=\"go\">Go</button>\n</row>",
        "<column>\n  <text-field placeholder=\"\xe2\x8c\x98 to focus\" on-input=\"edit\" />\n</column>",
        "<timeline>\n  <timeline-item title=\"Done\" indicator=\"\xe2\x9c\x93\" />\n</timeline>",
        "<column>\n  <stepper active=\"{page}\">\n    <step>Work \xe2\x8c\x98</step>\n  </stepper>\n</column>",
    };
    for (attr_cases) |source| {
        var case_parser = markup.Parser.init(arena_state.allocator(), source);
        const info = markup.validate(try case_parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(markup.font_coverage_message, info.message);
        try testing.expect(info.line > 0);
    }
}

test "the coverage scanner finds the first uncovered codepoint and skips bindings" {
    try testing.expectEqual(@as(?markup.UncoveredCodepoint, null), markup.firstUncoveredCodepoint("plain words"));
    try testing.expectEqual(@as(?markup.UncoveredCodepoint, null), markup.firstUncoveredCodepoint("caf\xc3\xa9 \xe2\x80\xa6 \xc2\xb7"));
    try testing.expectEqual(@as(?markup.UncoveredCodepoint, null), markup.firstUncoveredCodepoint("{anything \xe2\x8c\x98 inside} stays dynamic"));

    const found = markup.firstUncoveredCodepoint("Press \xe2\x8c\x98K").?;
    try testing.expectEqual(@as(usize, 6), found.offset);
    try testing.expectEqual(@as(u21, 0x2318), found.codepoint);
    try testing.expectEqualStrings("\xe2\x8c\x98", found.bytes);

    // Invalid UTF-8 reports as U+FFFD at the offending byte.
    const invalid = markup.firstUncoveredCodepoint("ok \xff bytes").?;
    try testing.expectEqual(@as(u21, 0xFFFD), invalid.codepoint);
    try testing.expectEqual(@as(usize, 3), invalid.offset);
}
test "for accepts multiple element children and a trailing else for the empty case" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Multi-child for bodies: elements, if/else arms, and nested fors are
    // all valid without a wrapper node.
    const valid_sources = [_][]const u8{
        "<column>\n  <for each=\"items\" as=\"t\">\n    <text>{t.title}</text>\n    <separator />\n  </for>\n</column>",
        "<column>\n  <for each=\"items\" as=\"t\">\n    <if test=\"{t.done}\"><text>done</text></if>\n    <else><text>{t.title}</text></else>\n  </for>\n</column>",
        "<column>\n  <for each=\"items\" as=\"t\">\n    <for each=\"t.tags\" as=\"tag\"><badge>{tag.name}</badge></for>\n  </for>\n</column>",
        "<column>\n  <for each=\"items\" as=\"t\">\n    <text>{t.title}</text>\n  </for>\n  <else>\n    <text>Nothing yet</text>\n  </else>\n</column>",
        "<column>\n  <for each=\"items\" as=\"t\">\n    <text>{t.title}</text>\n  </for>\n  <else>\n    <text>empty</text>\n  </else>\n  <text>after</text>\n</column>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    // An else after the for's else (or anywhere else) still teaches.
    const stray = "<column>\n  <for each=\"items\" as=\"t\"><text>{t.title}</text></for>\n  <else><text>empty</text></else>\n  <else><text>again</text></else>\n</column>";
    var stray_parser = markup.Parser.init(arena, stray);
    const info = markup.validate(try stray_parser.parse()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(markup.else_placement_message, info.message);
}

test "a dead handler on a non-hit-target element reports the attribute position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const source = "<column>\n  <row gap=\"8\" on-change=\"select\">\n    <text>press me</text>\n  </row>\n</column>";
    var parser = markup.Parser.init(arena_state.allocator(), source);
    const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(markup.non_hit_target_handler_message, info.message);
    try testing.expectEqual(@as(usize, 2), info.line);
    // The diagnostic points at the on-change attribute, not the element.
    try testing.expectEqual(@as(usize, 16), info.column);

    // The same handler on a control inside the row validates clean.
    const fixed = "<column>\n  <row gap=\"8\">\n    <checkbox on-change=\"select\">press me</checkbox>\n  </row>\n</column>";
    var fixed_parser = markup.Parser.init(arena_state.allocator(), fixed);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try fixed_parser.parse()));
}

test "press and toggle handlers are legal on layout elements (press fall-through makes them pressable)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // A pressable row with plain text children is THE shape the press
    // fall-through exists for: the handler makes the row a hit target and
    // clicks on the text land on it — no empty-text overlay, no
    // duplicated handlers.
    const sources = [_][]const u8{
        "<column>\n  <row on-press=\"select\" gap=\"8\">\n    <text>press me</text>\n  </row>\n</column>",
        "<column on-press=\"add\">\n  <text>x</text>\n</column>",
        "<column>\n  <stack on-toggle=\"flip\">\n    <text>x</text>\n  </stack>\n</column>",
        "<row>\n  <icon name=\"search\" on-press=\"go\" />\n</row>",
        "<row>\n  <badge on-press=\"open\">3</badge>\n</row>",
    };
    for (sources) |source| {
        var parser = markup.Parser.init(arena_state.allocator(), source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }
}

test "gap on stacking containers is rejected with the teaching error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every stack-container element rejects gap at the attribute position.
    for (markup.known_stack_container_element_names) |name| {
        const source = try std.fmt.allocPrint(arena, "<column>\n  <{s} gap=\"8\" />\n</column>", .{name});
        var parser = markup.Parser.init(arena, source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(markup.stack_container_gap_message, info.message);
        try testing.expectEqual(@as(usize, 2), info.line);
    }

    // Flow containers keep gap; a column inside a panel is the fix.
    const valid_sources = [_][]const u8{
        "<row gap=\"8\">\n  <text>x</text>\n</row>",
        "<panel>\n  <column gap=\"8\">\n    <text>a</text>\n    <text>b</text>\n  </column>\n</panel>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }
}

test "the avatar image attribute validates as one binding, avatar-only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One {binding} on avatar is the whole grammar.
    var parser = markup.Parser.init(arena, "<row>\n  <avatar image=\"{user_image}\">CT</avatar>\n</row>");
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // Runtime image ids are model data, never markup literals.
        .{ .source = "<row>\n  <avatar image=\"7\">CT</avatar>\n</row>", .message = markup.avatar_image_message },
        .{ .source = "<row>\n  <avatar image=\"{a == b}\">CT</avatar>\n</row>", .message = markup.avatar_image_message },
        // Scoped to avatar: the other image elements stay Zig views.
        .{ .source = "<row>\n  <badge image=\"{user_image}\">3</badge>\n</row>", .message = markup.avatar_image_element_message },
        .{ .source = "<column>\n  <panel image=\"{user_image}\" />\n</column>", .message = markup.avatar_image_element_message },
    };
    for (cases) |case| {
        var case_parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try case_parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expectEqual(@as(usize, 2), info.line);
    }
}

test "wrap and issue-link-base validate as vocabulary with teaching errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Valid: wrap on a text leaf, issue-link-base as a literal prefix or
    // one binding.
    const valid_sources = [_][]const u8{
        "<column>\n  <text wrap=\"true\">long message</text>\n</column>",
        "<column>\n  <text wrap=\"false\">one-line row title</text>\n</column>",
        "<column>\n  <markdown source=\"{body}\" issue-link-base=\"ghissue://\" />\n</column>",
        "<column>\n  <markdown source=\"{body}\" issue-link-base=\"{issue_base}\" />\n</column>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    // issue-link-base rejects equality expressions with the teaching
    // message; the closed markdown attr set names it.
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "<column>\n  <markdown source=\"{body}\" issue-link-base=\"{a == b}\" />\n</column>",
            .message = markup.markdown_issue_link_base_message,
        },
        .{
            .source = "<column>\n  <markdown source=\"{body}\" wrap=\"true\" />\n</column>",
            .message = markup.markdown_attr_message,
        },
        // wrap on anything but a text leaf is silently inert (rows never
        // flow-wrap their children) — rejected with the teaching message,
        // same policy as gap on stacking containers.
        .{
            .source = "<column>\n  <row wrap=\"true\">\n    <text>a</text>\n  </row>\n</column>",
            .message = markup.wrap_element_message,
        },
        .{
            .source = "<column>\n  <badge wrap=\"true\">new</badge>\n</column>",
            .message = markup.wrap_element_message,
        },
        .{
            .source = "<column>\n  <row wrap=\"false\">\n    <text>a</text>\n  </row>\n</column>",
            .message = markup.wrap_element_message,
        },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
    }
}

test "stepper and timeline validate structure with teaching messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const valid_sources = [_][]const u8{
        "<column>\n  <stepper active=\"{stage}\">\n    <step>Work</step>\n    <step>Ready</step>\n  </stepper>\n</column>",
        "<column>\n  <timeline gap=\"4\">\n    <timeline-item title=\"Done\" description=\"ok\" meta=\"1m\" variant=\"primary\" on-press=\"pick:{id}\" />\n    <if test=\"{ready}\">\n      <timeline-item title=\"Ready\" connector=\"false\" />\n    </if>\n  </timeline>\n</column>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<column>\n  <stepper>\n    <step>Work</step>\n  </stepper>\n</column>", .message = markup.stepper_active_message },
        .{ .source = "<column>\n  <stepper active=\"1\" gap=\"4\" />\n</column>", .message = markup.stepper_attr_message },
        .{ .source = "<column>\n  <stepper active=\"1\">\n    <text>Work</text>\n  </stepper>\n</column>", .message = markup.stepper_children_message },
        .{ .source = "<column>\n  <stepper active=\"1\">\n    <step variant=\"primary\">Work</step>\n  </stepper>\n</column>", .message = markup.step_attr_message },
        .{ .source = "<column>\n  <step>Work</step>\n</column>", .message = markup.step_parent_message },
        .{ .source = "<column>\n  <timeline padding=\"8\" />\n</column>", .message = markup.timeline_attr_message },
        .{ .source = "<column>\n  <timeline-item title=\"Done\" />\n</column>", .message = markup.timeline_item_parent_message },
        .{ .source = "<column>\n  <timeline>\n    <timeline-item description=\"x\" />\n  </timeline>\n</column>", .message = markup.timeline_item_title_message },
        .{ .source = "<column>\n  <timeline>\n    <timeline-item title=\"Done\" width=\"20\" />\n  </timeline>\n</column>", .message = markup.timeline_item_attr_message },
        .{ .source = "<column>\n  <timeline>\n    <timeline-item title=\"Done\" on-toggle=\"pick\" />\n  </timeline>\n</column>", .message = markup.timeline_item_press_only_message },
        .{ .source = "<column>\n  <timeline>\n    <timeline-item title=\"Done\">\n      <text>x</text>\n    </timeline-item>\n  </timeline>\n</column>", .message = markup.timeline_item_children_message },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
    }
}

// ----------------------------------------------------------- imports

fn resolveSet(arena: std.mem.Allocator, set: []const markup.SourceFile, root_name: []const u8, diagnostic: *markup.MarkupErrorInfo) markup.ResolveError!markup.MarkupDocument {
    var loader = markup.SourceSetLoader{ .set = set };
    const root_source = for (set) |file| {
        if (std.mem.eql(u8, file.path, root_name)) break file.source;
    } else return error.MarkupImport;
    return markup.resolveImports(arena, root_name, root_source, loader.loader(), diagnostic);
}

test "import resolution merges imported templates before the importer's own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // view.zml imports components/pills.zml, which imports base.zml from
    // its own directory (transitive, subdirectory, relative-to-importer).
    const set = [_]markup.SourceFile{
        .{ .path = "view.zml", .source = "<import src=\"components/pills.zml\"/>\n<template name=\"local\"><text>l</text></template>\n<row>\n  <use template=\"pill-stack\" title=\"T\" />\n</row>" },
        .{ .path = "components/pills.zml", .source = "<import src=\"base.zml\"/>\n<template name=\"pill-stack\" args=\"title\"><column><use template=\"pill\" label=\"{title}\" /></column></template>" },
        .{ .path = "components/base.zml", .source = "<template name=\"pill\" args=\"label\"><badge>{label}</badge></template>" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    const document = try resolveSet(arena, &set, "view.zml", &diagnostic);

    // Depth-first splice order: transitive imports first, then the
    // importer's templates, then the root's own.
    try testing.expectEqual(@as(usize, 3), document.templates.len);
    try testing.expectEqualStrings("pill", document.templates[0].attr("name").?);
    try testing.expectEqualStrings("pill-stack", document.templates[1].attr("name").?);
    try testing.expectEqualStrings("local", document.templates[2].attr("name").?);
    try testing.expectEqual(@as(usize, 0), document.imports.len);

    // Every node is stamped with its source file for diagnostics.
    try testing.expectEqualStrings("components/base.zml", document.templates[0].src_path);
    try testing.expectEqualStrings("components/pills.zml", document.templates[1].src_path);
    try testing.expectEqualStrings("view.zml", document.templates[2].src_path);
    try testing.expectEqualStrings("view.zml", document.root.?.src_path);
    try testing.expectEqualStrings("components/base.zml", document.templates[0].children[0].src_path);

    // The merged document passes the strict (resolved) validation pass.
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));
}

test "import cycles are reported with the cycle path spelled out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const set = [_]markup.SourceFile{
        .{ .path = "a.zml", .source = "<import src=\"b.zml\"/>\n<row />" },
        .{ .path = "b.zml", .source = "<import src=\"a.zml\"/>\n<template name=\"t\"><text>x</text></template>" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "a.zml", &diagnostic));
    try testing.expectEqualStrings("import cycle: a.zml -> b.zml -> a.zml", diagnostic.message);
    try testing.expectEqualStrings("b.zml", diagnostic.path);

    // Self-import is the shortest cycle.
    const self_set = [_]markup.SourceFile{
        .{ .path = "a.zml", .source = "<import src=\"a.zml\"/>\n<row />" },
    };
    try testing.expectError(error.MarkupImport, resolveSet(arena, &self_set, "a.zml", &diagnostic));
    try testing.expectEqualStrings("import cycle: a.zml -> a.zml", diagnostic.message);
}

test "duplicate template names across files name both definition sites" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const set = [_]markup.SourceFile{
        .{ .path = "view.zml", .source = "<import src=\"one.zml\"/>\n<import src=\"two.zml\"/>\n<row />" },
        .{ .path = "one.zml", .source = "<template name=\"card\"><text>1</text></template>" },
        .{ .path = "two.zml", .source = "<template name=\"card\"><text>2</text></template>" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "view.zml", &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "duplicate template name \"card\"") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "one.zml:1:1") != null);
    try testing.expectEqualStrings("two.zml", diagnostic.path);

    // Import vs local: the local definition collides with the imported one.
    const local_set = [_]markup.SourceFile{
        .{ .path = "view.zml", .source = "<import src=\"one.zml\"/>\n<template name=\"card\"><text>l</text></template>\n<row />" },
        .{ .path = "one.zml", .source = "<template name=\"card\"><text>1</text></template>" },
    };
    try testing.expectError(error.MarkupImport, resolveSet(arena, &local_set, "view.zml", &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "duplicate template name \"card\"") != null);
    try testing.expectEqualStrings("view.zml", diagnostic.path);
}

test "import path escapes, absolute paths, and bad extensions are teaching errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { src: []const u8, message: []const u8 }{
        .{ .src = "../secrets.zml", .message = markup.import_src_escape_message },
        .{ .src = "/etc/passwd.zml", .message = markup.import_src_absolute_message },
        .{ .src = "c:\\parts.zml", .message = markup.import_src_absolute_message },
        .{ .src = "parts.txt", .message = markup.import_src_extension_message },
        .{ .src = "", .message = markup.import_src_message },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(arena, "<import src=\"{s}\"/>\n<row />", .{case.src});
        const set = [_]markup.SourceFile{.{ .path = "src/view.zml", .source = source }};
        var diagnostic: markup.MarkupErrorInfo = .{};
        try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "src/view.zml", &diagnostic));
        try testing.expectEqualStrings(case.message, diagnostic.message);
        try testing.expectEqual(@as(usize, 1), diagnostic.line);
    }

    // Within-root ".." stays legal: components can reach a sibling folder
    // under the markup root.
    var buffer: [markup.max_import_path_len]u8 = undefined;
    const resolved = markup.resolveImportPath("src", "src/components/pills.zml", "../shared/base.zml", &buffer);
    try testing.expectEqualStrings("src/shared/base.zml", resolved.path);
    const escaped = markup.resolveImportPath("src", "src/view.zml", "../../other.zml", &buffer);
    try testing.expectEqualStrings(markup.import_src_escape_message, escaped.message);
}

test "an imported file with a view root is rejected with the teaching error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const set = [_]markup.SourceFile{
        .{ .path = "view.zml", .source = "<import src=\"other.zml\"/>\n<row />" },
        .{ .path = "other.zml", .source = "<template name=\"t\"><text>x</text></template>\n<column />" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "view.zml", &diagnostic));
    try testing.expectEqualStrings(markup.import_view_root_message, diagnostic.message);
    try testing.expectEqualStrings("other.zml", diagnostic.path);
}

test "a missing imported file reports at the importing file's position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const set = [_]markup.SourceFile{
        .{ .path = "view.zml", .source = "<row />\n" },
        .{ .path = "importer.zml", .source = "<import src=\"nope.zml\"/>\n<row />" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "importer.zml", &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "unable to read imported file \"nope.zml\"") != null);
    try testing.expectEqualStrings("importer.zml", diagnostic.path);
    try testing.expectEqual(@as(usize, 1), diagnostic.line);
}

test "hostile import chains and template counts get bounded errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A chain one past max_import_depth errors instead of recursing on.
    var files: std.ArrayListUnmanaged(markup.SourceFile) = .empty;
    for (0..markup.max_import_depth + 1) |index| {
        const path = try std.fmt.allocPrint(arena, "c{d}.zml", .{index});
        const source = if (index == markup.max_import_depth)
            try std.fmt.allocPrint(arena, "<template name=\"leaf\"><text>x</text></template>", .{})
        else
            try std.fmt.allocPrint(arena, "<import src=\"c{d}.zml\"/>\n<template name=\"t{d}\"><text>x</text></template>", .{ index + 1, index });
        try files.append(arena, .{ .path = path, .source = source });
    }
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, files.items, "c0.zml", &diagnostic));
    try testing.expectEqualStrings(markup.import_depth_message, diagnostic.message);

    // A single file with too many templates fails the parse cap.
    var huge: std.ArrayListUnmanaged(u8) = .empty;
    for (0..markup.max_document_templates + 1) |index| {
        try huge.appendSlice(arena, try std.fmt.allocPrint(arena, "<template name=\"t{d}\"><text>x</text></template>\n", .{index}));
    }
    try huge.appendSlice(arena, "<row />");
    var parser = markup.Parser.init(arena, huge.items);
    try testing.expectError(error.MarkupSyntax, parser.parse());
    try testing.expectEqualStrings(markup.max_templates_message, parser.diagnostic.message);
}

test "imports parse at the top only and validate their shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An import after a template is a parse error (position is structure).
    var parser = markup.Parser.init(arena, "<template name=\"t\"><text>x</text></template>\n<import src=\"a.zml\"/>\n<row />");
    try testing.expectError(error.MarkupSyntax, parser.parse());
    try testing.expectEqualStrings(markup.import_top_level_message, parser.diagnostic.message);

    const shape_cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<import/>\n<row />", .message = markup.import_src_message },
        .{ .source = "<import src=\"a.zml\" extra=\"1\"/>\n<row />", .message = markup.import_attrs_message },
        .{ .source = "<import src=\"a.zml\"><text>x</text></import>\n<row />", .message = markup.import_children_message },
        .{ .source = "<column>\n  <import src=\"a.zml\"/>\n</column>", .message = markup.import_top_level_message },
    };
    for (shape_cases) |case| {
        var case_parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try case_parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
    }

    // A view with unresolved imports skips use-reference checks (the
    // template may come from the import); everything else still validates.
    var lenient_parser = markup.Parser.init(arena, "<import src=\"a.zml\"/>\n<row>\n  <use template=\"from-import\" whatever=\"1\" />\n</row>");
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try lenient_parser.parse()));
}

// -------------------------------------------------- defaults and slots

test "template arg defaults parse and validate as literals only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const arg = markup.parseTemplateArg("trend=flat");
    try testing.expectEqualStrings("trend", arg.name);
    try testing.expectEqualStrings("flat", arg.default.?);
    try testing.expectEqual(@as(?[]const u8, null), markup.parseTemplateArg("trend").default);
    try testing.expectEqualStrings("", markup.parseTemplateArg("trend=").default.?);

    // Omitting a defaulted arg is fine; omitting a required one is not.
    var ok_parser = markup.Parser.init(arena, "<template name=\"t\" args=\"title trend=flat\"><text>{title} {trend}</text></template>\n<row>\n  <use template=\"t\" title=\"T\" />\n</row>");
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try ok_parser.parse()));

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<template name=\"t\" args=\"title trend=flat\"><text>{title}</text></template>\n<row>\n  <use template=\"t\" trend=\"up\" />\n</row>", .message = markup.use_missing_arg_message },
        .{ .source = "<template name=\"t\" args=\"trend={title}\"><text>{trend}</text></template>\n<row />", .message = markup.template_default_literal_message },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
    }
}

test "slot placement rules validate with teaching messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A template with one slot accepts use-site children (built in the
    // consumer's scope); a slotless template rejects them.
    var ok_parser = markup.Parser.init(arena, "<template name=\"t\" args=\"title\"><column><text>{title}</text><slot/></column></template>\n<row>\n  <use template=\"t\" title=\"T\"><text>body</text></use>\n</row>");
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try ok_parser.parse()));

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<template name=\"t\"><column><slot/><slot/></column></template>\n<row />", .message = markup.template_one_slot_message },
        .{ .source = "<row>\n  <slot/>\n</row>", .message = markup.slot_outside_template_message },
        .{ .source = "<template name=\"t\"><column><slot gap=\"2\"/></column></template>\n<row />", .message = markup.slot_attrs_message },
        .{ .source = "<template name=\"t\"><column><slot><text>x</text></slot></column></template>\n<row />", .message = markup.slot_children_message },
        .{ .source = "<template name=\"a\"><column><slot/></column></template>\n<template name=\"b\"><column><use template=\"a\"><slot/></use></column></template>\n<row />", .message = markup.slot_in_use_children_message },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
    }
}

// ------------------------------------------------------------------ spans

fn expectSpansCover(source: []const u8, node: markup.MarkupNode) !void {
    switch (node.kind) {
        .text => {
            // A text run's span is exactly its trimmed visible bytes.
            try testing.expectEqualStrings(node.text, source[node.span.start..node.span.end]);
        },
        else => {
            // An element/structure node spans `<` through its closing `>`.
            try testing.expectEqual(@as(u8, '<'), source[node.span.start]);
            try testing.expectEqual(@as(u8, '>'), source[node.span.end - 1]);
        },
    }
    // The classic line/column IS the span start, in display form.
    const node_position = markup.positionAt(source, node.span.start);
    try testing.expectEqual(node.line, node_position.line);
    try testing.expectEqual(node.column, node_position.column);
    for (node.attrs) |attribute| {
        try testing.expectEqualStrings(attribute.name, source[attribute.name_span.start..attribute.name_span.end]);
        if (attribute.value.len > 0) {
            try testing.expectEqualStrings(attribute.value, source[attribute.value_span.start..attribute.value_span.end]);
        } else {
            try testing.expectEqual(attribute.value_span.start, attribute.value_span.end);
        }
        const attr_position = markup.positionAt(source, attribute.name_span.start);
        try testing.expectEqual(attribute.line, attr_position.line);
        try testing.expectEqual(attribute.column, attr_position.column);
    }
    for (node.children) |child| {
        try expectSpansCover(source, child);
    }
}

test "nodes and attributes carry byte-range spans; line/column derive from them" {
    // Spans are the write-back prerequisite: every node, attribute name,
    // attribute value, and text run must map to the exact source bytes,
    // and the parser's line/column must be re-derivable from the span
    // start (diagnostics keep their line:column shape; spans carry the
    // authority).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parser = markup.Parser.init(arena_state.allocator(), inbox_source);
    const document = try parser.parse();
    try expectSpansCover(inbox_source, document.root.?);

    // The comptime parser stamps identical spans (both engines see one
    // document geometry).
    const comptime_document = comptime markup.parseComptime(inbox_source);
    try expectSpansCover(inbox_source, comptime_document.root.?);
    try testing.expectEqual(document.root.?.span, comptime_document.root.?.span);

    // Spot-pin the root: the document's exact extent.
    try testing.expectEqual(std.mem.indexOf(u8, inbox_source, "<column").?, document.root.?.span.start);
    try testing.expectEqual(inbox_source.len, document.root.?.span.end);
}

test "self-closing elements and value-less attributes span correctly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = "<column><separator/><text wrap=\"true\">hi</text></column>";
    var parser = markup.Parser.init(arena_state.allocator(), source);
    const document = try parser.parse();
    const root = document.root.?;
    const separator = root.children[0];
    try testing.expectEqualStrings("<separator/>", source[separator.span.start..separator.span.end]);
    const text = root.children[1];
    try testing.expectEqualStrings("<text wrap=\"true\">hi</text>", source[text.span.start..text.span.end]);
    const wrap = text.attrs[0];
    try testing.expectEqualStrings("wrap", source[wrap.name_span.start..wrap.name_span.end]);
    try testing.expectEqualStrings("true", source[wrap.value_span.start..wrap.value_span.end]);
    const run = text.children[0];
    try testing.expectEqualStrings("hi", source[run.span.start..run.span.end]);
}

// ---------------------------------------------------------- typed pass

fn expectTypedMatchesClassification(node: markup.MarkupNode) !void {
    for (node.attrs) |attribute| {
        // Canonicalization stamped every attribute...
        const typed = attribute.typed orelse return error.TestUnexpectedResult;
        // ...with exactly the classification the engines' fallback
        // computes — the pass changes cost, never meaning.
        const fallback = markup.classifyAttrValue(attribute.name, attribute.value);
        try testing.expectEqual(std.meta.activeTag(fallback), std.meta.activeTag(typed.*));
        if (typed.* == .expression) {
            // The tree parsed once, at document level.
            try testing.expect(typed.expression.tree != null);
            try testing.expectEqualStrings(fallback.expression.inner, typed.expression.inner);
        }
    }
    if (node.kind == .text and std.mem.indexOfScalar(u8, node.text, '{') != null) {
        try testing.expect(node.typed_text != null);
    }
    for (node.children) |child| {
        try expectTypedMatchesClassification(child);
    }
}

test "canonicalization stamps typed values that match on-the-fly classification" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\<column gap="8" background="surface">
        \\  <text label="{count} items">{count} of {total(count, 2)}</text>
        \\  <button selected="{mode == active_mode}" on-press="set:{mode}">Go</button>
        \\  <if test="{count > 0 and not busy}">
        \\    <badge>{count}</badge>
        \\  </if>
        \\</column>
    ;
    var parser = markup.Parser.init(arena, source);
    const document = try parser.parse();
    const canonical = try markup.canonicalize(arena, document);
    try expectTypedMatchesClassification(canonical.root.?);

    // The if test is a full expression whose tree parsed once.
    const if_block = canonical.root.?.children[2];
    const test_attr = if_block.attrEntry("test").?;
    try testing.expect(test_attr.typed.?.* == .expression);
    try testing.expect(test_attr.typed.?.expression.tree != null);

    // on-* attributes classify as messages, payload path included.
    const button = canonical.root.?.children[1];
    const press = button.attrEntry("on-press").?;
    try testing.expectEqualStrings("set", press.typed.?.message.tag);
    try testing.expectEqualStrings("mode", press.typed.?.message.payload);

    // The comptime pass stamps the same shapes for the compiled engine.
    const comptime_canonical = comptime markup.canonicalizeComptime(markup.parseComptime(
        \\<row><text>{a} + {b}</text></row>
    ));
    const run = comptime_canonical.root.?.children[0].children[0];
    try testing.expect(run.typed_text != null);
    try testing.expectEqual(@as(usize, 3), run.typed_text.?.len);
    try testing.expectEqualStrings("a", run.typed_text.?[0].binding);
    try testing.expectEqualStrings(" + ", run.typed_text.?[1].literal);
    try testing.expectEqualStrings("b", run.typed_text.?[2].binding);
}
