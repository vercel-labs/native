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
    \\          <checkbox checked="{t.done}" on-toggle="toggle:{t.id}" label="Done" />
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

    // The other two icon grammar forms are structurally valid: an
    // app:<name> reference (its registration is `native check`'s job,
    // through the model contract) and one {binding} producing the name.
    const open_icon_source = "<row gap=\"8\">\n  <icon name=\"app:wave-pulse\" />\n  <icon name=\"{status_icon}\" />\n  <button icon=\"app:wave\" on-press=\"play\">Wave</button>\n  <button icon=\"{status_icon}\" on-press=\"play\">Status</button>\n</row>";
    var open_icon_parser = markup.Parser.init(arena_state.allocator(), open_icon_source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try open_icon_parser.parse()));

    // The labeled interactive elements take an inline icon (with or
    // without a label): one hit target, one tint. Toggle-buttons cover
    // chips and tab strips; list/menu items get a leading slot.
    const button_icon_source = "<row gap=\"8\">\n  <button icon=\"save\" on-press=\"save\">Save</button>\n  <button icon=\"refresh-cw\" on-press=\"refresh\" label=\"Refresh\"></button>\n  <toggle-button icon=\"arrow-up\" on-toggle=\"sort\">Newest</toggle-button>\n  <list-item icon=\"folder\" on-press=\"open\">Projects</list-item>\n  <menu-item icon=\"trash\" on-press=\"remove\">Delete</menu-item>\n  <badge icon=\"check\">3</badge>\n</row>";
    var button_icon_parser = markup.Parser.init(arena_state.allocator(), button_icon_source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try button_icon_parser.parse()));

    // Autofocus on focusable controls: literal or bound.
    const autofocus_source = "<column gap=\"8\">\n  <text-field autofocus=\"true\" label=\"Title\" on-input=\"edit\" />\n  <textarea autofocus=\"{editing}\" label=\"Body\" on-input=\"edit\" />\n</column>";
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
        // Icon: bare names are the closed built-in vocabulary; app: is
        // the one namespace (well-shaped names only); bindings pass
        // structurally. Leaf, icon-scoped attr.
        .{ .source = "<row>\n  <icon />\n</row>", .message = markup.icon_missing_name_message },
        .{ .source = "<row>\n  <icon name=\"sparkle-pony\" />\n</row>", .message = markup.icon_name_message },
        .{ .source = "<row>\n  <icon name=\"lib:search\" />\n</row>", .message = markup.icon_namespace_message },
        .{ .source = "<row>\n  <icon name=\"app:\" />\n</row>", .message = markup.app_icon_shape_message },
        .{ .source = "<row>\n  <icon name=\"app:Wave Pulse\" />\n</row>", .message = markup.app_icon_shape_message },
        .{ .source = "<row>\n  <icon name=\"app:wave--pulse\" />\n</row>", .message = markup.app_icon_shape_message },
        .{ .source = "<row>\n  <badge name=\"search\">3</badge>\n</row>", .message = markup.icon_name_element_message },
        .{ .source = "<row>\n  <icon name=\"search\"><text>x</text></icon>\n</row>", .message = markup.icon_children_message },
        .{ .source = "<row>\n  <icon name=\"search\" on-change=\"go\" />\n</row>", .message = markup.non_hit_target_handler_message },
        // Button icon attr: the same grammar, button-scoped.
        .{ .source = "<row>\n  <button icon=\"sparkle-pony\">Save</button>\n</row>", .message = markup.button_icon_message },
        .{ .source = "<row>\n  <button icon=\"lib:save\">Save</button>\n</row>", .message = markup.icon_namespace_message },
        .{ .source = "<row>\n  <button icon=\"app:-wave\">Save</button>\n</row>", .message = markup.app_icon_shape_message },
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

test "the a11y lint: unnamed controls, icon-only controls, and unnamed text entry are errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // A control with no name anywhere is announced as an unnamed
        // control - unusable blind.
        .{ .source = "<row>\n  <checkbox on-toggle=\"select\" />\n</row>", .message = markup.a11y_unlabeled_control_message },
        .{ .source = "<row>\n  <slider value=\"0.5\" on-change=\"scale\" />\n</row>", .message = markup.a11y_unlabeled_control_message },
        // The icon name is a drawing instruction, not a label.
        .{ .source = "<row>\n  <button icon=\"trash\" on-press=\"remove\"></button>\n</row>", .message = markup.a11y_icon_only_message },
        // Text entry needs a label or a placeholder; a bound VALUE is
        // not a name (hearing the content does not say what to type).
        .{ .source = "<row>\n  <text-field on-input=\"draft\" />\n</row>", .message = markup.a11y_unlabeled_editable_message },
        .{ .source = "<row>\n  <input text=\"{query}\" on-input=\"draft\" />\n</row>", .message = markup.a11y_unlabeled_editable_message },
        // A blank label is not a name on a control (unlike an image,
        // where the empty label is the decorative opt-out).
        .{ .source = "<row>\n  <checkbox label=\" \" on-toggle=\"select\" />\n</row>", .message = markup.a11y_unlabeled_control_message },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
    }

    // Every sanctioned name source validates clean: text content, the
    // text attribute, a label (literal or binding), a placeholder, and
    // select's face content.
    const clean = [_][]const u8{
        "<row>\n  <checkbox on-toggle=\"select\">Done</checkbox>\n</row>",
        "<row>\n  <checkbox text=\"Done\" on-toggle=\"select\" />\n</row>",
        "<row>\n  <checkbox label=\"Done\" on-toggle=\"select\" />\n</row>",
        "<row>\n  <button icon=\"trash\" label=\"Delete\" on-press=\"remove\"></button>\n</row>",
        "<row>\n  <button icon=\"save\" on-press=\"save\">Save</button>\n</row>",
        "<row>\n  <checkbox label=\"{item.title}\" on-toggle=\"select\" />\n</row>",
        "<row>\n  <text-field placeholder=\"New task\" on-input=\"draft\" />\n</row>",
        "<row>\n  <textarea label=\"Body\" on-input=\"draft\" />\n</row>",
        "<row>\n  <select on-press=\"open\">Newest first</select>\n</row>",
        "<row>\n  <select text=\"{choice}\" on-press=\"open\"/>\n</row>",
    };
    for (clean) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }
}

test "the a11y lint: unknown literal roles and container roles on childless elements are errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const unknown = "<row>\n  <button role=\"pushbutton\" on-press=\"add\">Add</button>\n</row>";
    var unknown_parser = markup.Parser.init(arena, unknown);
    const unknown_info = markup.validate(try unknown_parser.parse()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(markup.a11y_unknown_role_message, unknown_info.message);
    // The diagnostic points at the role attribute.
    try testing.expectEqual(@as(usize, 2), unknown_info.line);

    // role="tree" promises rows a text leaf can never hold.
    const misuse = "<row>\n  <button role=\"tree\" on-press=\"add\">Add</button>\n</row>";
    var misuse_parser = markup.Parser.init(arena, misuse);
    const misuse_info = markup.validate(try misuse_parser.parse()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(markup.a11y_container_role_message, misuse_info.message);

    // The same container roles are fine on containers, treeitem is fine
    // on a pressable row, and a dynamic role resolves at runtime.
    const clean = [_][]const u8{
        "<column role=\"tree\">\n  <row role=\"treeitem\" on-press=\"pick\"><text>Docs</text></row>\n</column>",
        "<row>\n  <button role=\"{item.role}\" on-press=\"add\">Add</button>\n</row>",
    };
    for (clean) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }
}

test "the a11y lint: unnamed images and redundant labels are warnings, not errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var storage: [markup.max_a11y_warnings]markup.MarkupErrorInfo = undefined;

    // An unnamed avatar validates (degraded, not blocked) and warns.
    const unnamed = "<row>\n  <avatar image=\"{photo}\"></avatar>\n</row>";
    var unnamed_parser = markup.Parser.init(arena, unnamed);
    const unnamed_doc = try unnamed_parser.parse();
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(unnamed_doc));
    const unnamed_warnings = markup.collectA11yWarnings(unnamed_doc, &storage);
    try testing.expectEqual(@as(usize, 1), unnamed_warnings.len);
    try testing.expectEqualStrings(markup.a11y_unlabeled_image_message, unnamed_warnings[0].message);
    try testing.expectEqual(@as(usize, 2), unnamed_warnings[0].line);

    // label="" is the explicit decorative opt-out; initials or a real
    // label also clear it.
    const clean = [_][]const u8{
        "<row>\n  <avatar image=\"{photo}\" label=\"\"></avatar>\n</row>",
        "<row>\n  <avatar image=\"{photo}\" label=\"Octocat\"></avatar>\n</row>",
        "<row>\n  <avatar>CT</avatar>\n</row>",
    };
    for (clean) |source| {
        var parser = markup.Parser.init(arena, source);
        const document = try parser.parse();
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));
        try testing.expectEqual(@as(usize, 0), markup.collectA11yWarnings(document, &storage).len);
    }

    // A label duplicating the text it shadows warns at the label.
    const redundant = "<row>\n  <button label=\"Save\" on-press=\"save\">Save</button>\n</row>";
    var redundant_parser = markup.Parser.init(arena, redundant);
    const redundant_doc = try redundant_parser.parse();
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(redundant_doc));
    const redundant_warnings = markup.collectA11yWarnings(redundant_doc, &storage);
    try testing.expectEqual(@as(usize, 1), redundant_warnings.len);
    try testing.expectEqualStrings(markup.a11y_redundant_label_message, redundant_warnings[0].message);

    // A label that ADDS information (differs from the text) is the
    // sanctioned shape and stays quiet.
    const adds = "<row>\n  <button label=\"Save the draft\" on-press=\"save\">Save</button>\n</row>";
    var adds_parser = markup.Parser.init(arena, adds);
    const adds_doc = try adds_parser.parse();
    try testing.expectEqual(@as(usize, 0), markup.collectA11yWarnings(adds_doc, &storage).len);
}

test "collectA11yErrors reports every a11y error in one pass with validate's positions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var storage: [markup.max_a11y_warnings]markup.MarkupErrorInfo = undefined;

    // validate stops at the first offender; the collector reports both.
    const two_unlabeled = "<column>\n  <button on-press=\"add\"></button>\n  <button on-press=\"remove\"></button>\n</column>";
    var parser = markup.Parser.init(arena, two_unlabeled);
    const document = try parser.parse();
    const first = markup.validate(document) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(markup.a11y_unlabeled_control_message, first.message);
    const findings = markup.collectA11yErrors(document, &storage);
    try testing.expectEqual(@as(usize, 2), findings.len);
    try testing.expectEqualStrings(markup.a11y_unlabeled_control_message, findings[0].message);
    try testing.expectEqual(first.line, findings[0].line);
    try testing.expectEqual(first.column, findings[0].column);
    try testing.expectEqualStrings(markup.a11y_unlabeled_control_message, findings[1].message);
    try testing.expect(findings[1].line > findings[0].line);

    // Mixed classes collect together: an unnamed control and a role
    // misuse (positioned at the role attribute, like validate).
    const mixed = "<column>\n  <slider value=\"0.5\" on-change=\"scale\" />\n  <button role=\"tree\" on-press=\"add\">Add</button>\n</column>";
    var mixed_parser = markup.Parser.init(arena, mixed);
    const mixed_findings = markup.collectA11yErrors(try mixed_parser.parse(), &storage);
    try testing.expectEqual(@as(usize, 2), mixed_findings.len);
    try testing.expectEqualStrings(markup.a11y_unlabeled_control_message, mixed_findings[0].message);
    try testing.expectEqualStrings(markup.a11y_container_role_message, mixed_findings[1].message);

    // A clean document collects nothing.
    var clean_parser = markup.Parser.init(arena, "<column>\n  <button on-press=\"add\">Add</button>\n</column>");
    try testing.expectEqual(@as(usize, 0), markup.collectA11yErrors(try clean_parser.parse(), &storage).len);
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

test "the image attribute validates as one binding on avatar and image" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One {binding} on avatar or the image leaf is the whole grammar.
    const valid = [_][]const u8{
        "<row>\n  <avatar image=\"{user_image}\">CT</avatar>\n</row>",
        "<row>\n  <image image=\"{cover}\" width=\"120\" height=\"80\" label=\"Cover art\" />\n</row>",
    };
    for (valid) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // Runtime image ids are model data, never markup literals.
        .{ .source = "<row>\n  <avatar image=\"7\">CT</avatar>\n</row>", .message = markup.image_binding_message },
        .{ .source = "<row>\n  <avatar image=\"{a == b}\">CT</avatar>\n</row>", .message = markup.image_binding_message },
        .{ .source = "<row>\n  <image image=\"7\" label=\"Art\" />\n</row>", .message = markup.image_binding_message },
        // Scoped to the two ImageId-drawing widgets: anywhere else the
        // attribute would be silently inert.
        .{ .source = "<row>\n  <badge image=\"{user_image}\">3</badge>\n</row>", .message = markup.image_binding_element_message },
        .{ .source = "<column>\n  <panel image=\"{user_image}\" />\n</column>", .message = markup.image_binding_element_message },
        // ...and required on the leaf: an unbound image is statically
        // dead markup (avatar keeps its initials fallback instead).
        .{ .source = "<row>\n  <image label=\"Art\" />\n</row>", .message = markup.image_missing_image_message },
        // The leaf takes no children (icon's policy): widget layout
        // gives an image no child slots, so a nested caption would
        // silently vanish instead of rendering.
        .{ .source = "<row>\n  <image image=\"{cover}\" label=\"Art\"><text>Caption</text></image>\n</row>", .message = markup.image_children_message },
    };
    for (cases) |case| {
        var case_parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try case_parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expectEqual(@as(usize, 2), info.line);
    }
}

test "the media-surface surface attribute validates as one binding, required, media-surface-only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One {binding} on media-surface is the whole grammar.
    var parser = markup.Parser.init(arena, "<row>\n  <media-surface surface=\"{preview}\" label=\"Preview\" />\n</row>");
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // Surface ids are model data, never markup literals.
        .{ .source = "<row>\n  <media-surface surface=\"7\" label=\"Preview\" />\n</row>", .message = markup.media_surface_surface_message },
        .{ .source = "<row>\n  <media-surface surface=\"{a == b}\" label=\"Preview\" />\n</row>", .message = markup.media_surface_surface_message },
        // Scoped to media-surface: anywhere else it would be inert.
        .{ .source = "<row>\n  <panel surface=\"{preview}\" />\n</row>", .message = markup.media_surface_surface_element_message },
        // ...and required: an unbound surface is statically dead markup.
        .{ .source = "<row>\n  <media-surface label=\"Preview\" />\n</row>", .message = markup.media_surface_missing_surface_message },
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

test "overscroll validates as scroll-scoped with a closed value vocabulary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Valid: every vocabulary value on scroll, and a binding (resolved
    // by the engines at build).
    const valid_sources = [_][]const u8{
        "<column>\n  <scroll overscroll=\"none\">\n    <column><text>a</text></column>\n  </scroll>\n</column>",
        "<column>\n  <scroll overscroll=\"rubber_band\">\n    <column><text>a</text></column>\n  </scroll>\n</column>",
        "<column>\n  <scroll overscroll=\"default\">\n    <column><text>a</text></column>\n  </scroll>\n</column>",
        "<column>\n  <scroll overscroll=\"{edge_mode}\">\n    <column><text>a</text></column>\n  </scroll>\n</column>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // Edge behavior exists only where the runtime scrolls; anywhere
        // else the option is silently inert (same policy as columns off
        // grid).
        .{
            .source = "<column>\n  <row overscroll=\"rubber_band\">\n    <text>a</text>\n  </row>\n</column>",
            .message = markup.overscroll_element_message,
        },
        .{
            .source = "<column>\n  <list overscroll=\"none\">\n    <list-item>a</list-item>\n  </list>\n</column>",
            .message = markup.overscroll_element_message,
        },
        // Literal values outside the closed vocabulary teach the set.
        .{
            .source = "<column>\n  <scroll overscroll=\"bouncy\">\n    <column><text>a</text></column>\n  </scroll>\n</column>",
            .message = markup.overscroll_value_message,
        },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
    }
}

test "tooltip-delay validates as tooltip-scoped beside anchor, and anchor accepts tooltip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Valid: an anchored tooltip with a literal delay, a zero delay
    // (instant show), a binding (resolved by the engines at build), and
    // an anchored tooltip with no delay at all (the token default).
    const valid_sources = [_][]const u8{
        "<stack>\n  <button on-press=\"pressed\">Bold</button>\n  <tooltip anchor=\"above\" tooltip-delay=\"500\">Bold the selection</tooltip>\n</stack>",
        "<stack>\n  <button on-press=\"pressed\">Bold</button>\n  <tooltip anchor=\"above\" tooltip-delay=\"0\">Bold the selection</tooltip>\n</stack>",
        "<stack>\n  <button on-press=\"pressed\">Bold</button>\n  <tooltip anchor=\"below\" tooltip-delay=\"{delay}\">Bold the selection</tooltip>\n</stack>",
        "<stack>\n  <button on-press=\"pressed\">Bold</button>\n  <tooltip anchor=\"above\">Bold the selection</tooltip>\n</stack>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // Hover intent exists only where the runtime owns visibility;
        // anywhere else the delay is silently inert.
        .{
            .source = "<column>\n  <button on-press=\"pressed\" tooltip-delay=\"500\">Bold</button>\n</column>",
            .message = markup.tooltip_delay_element_message,
        },
        // A delay beside no anchor shapes a hover-show that never
        // happens: a static tooltip paints whenever the view renders it.
        .{
            .source = "<column>\n  <tooltip tooltip-delay=\"500\">Bold the selection</tooltip>\n</column>",
            .message = markup.tooltip_delay_dependent_attr_message,
        },
        // Anchor stays scoped to its registry set; tooltip joining it
        // must not open other elements.
        .{
            .source = "<column>\n  <badge anchor=\"above\">3</badge>\n</column>",
            .message = markup.anchor_element_message,
        },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
    }
}

test "overflow validates as text-scoped with a closed value vocabulary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Valid: every vocabulary value on text, and a binding (resolved by
    // the engines at build).
    const valid_sources = [_][]const u8{
        "<column>\n  <text overflow=\"ellipsis\">a long row title</text>\n</column>",
        "<column>\n  <text overflow=\"clip\">1:22</text>\n</column>",
        "<column>\n  <text wrap=\"false\" overflow=\"clip\">1:22</text>\n</column>",
        "<column>\n  <text overflow=\"{policy}\">a</text>\n</column>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // Overflow policy exists only where a single line can overflow:
        // a plain text leaf (same policy as wrap).
        .{
            .source = "<column>\n  <row overflow=\"clip\">\n    <text>a</text>\n  </row>\n</column>",
            .message = markup.overflow_element_message,
        },
        .{
            .source = "<column>\n  <button overflow=\"ellipsis\">Save</button>\n</column>",
            .message = markup.overflow_element_message,
        },
        // Literal values outside the closed vocabulary teach the set —
        // including the deliberate absence of overflow-visible.
        .{
            .source = "<column>\n  <text overflow=\"visible\">a</text>\n</column>",
            .message = markup.overflow_value_message,
        },
        .{
            .source = "<column>\n  <text overflow=\"middle\">a</text>\n</column>",
            .message = markup.overflow_value_message,
        },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
    }
}

test "resize-duration and resize-easing validate as split-scoped with a closed easing vocabulary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Valid: a duration alone (with and without easing), every easing
    // vocabulary value beside a nonzero duration, bindings for both
    // (resolved by the engines at build), and an explicit 0 duration
    // WITHOUT easing (a declared snap is legal; easing beside it is not).
    const valid_sources = [_][]const u8{
        "<column>\n  <split value=\"{fraction}\" resize-duration=\"180\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
        "<column>\n  <split value=\"{fraction}\" resize-duration=\"180\" resize-easing=\"linear\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
        "<column>\n  <split value=\"{fraction}\" resize-duration=\"180\" resize-easing=\"standard\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
        "<column>\n  <split value=\"{fraction}\" resize-duration=\"180\" resize-easing=\"emphasized\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
        "<column>\n  <split value=\"{fraction}\" resize-duration=\"180\" resize-easing=\"spring\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
        "<column>\n  <split value=\"{fraction}\" resize-duration=\"{speed}\" resize-easing=\"{curve}\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
        "<column>\n  <split value=\"{fraction}\" resize-duration=\"0\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // The layout tween exists only where a fraction can move: a
        // split. Anywhere else the pair is silently inert (same policy
        // as overscroll off scroll).
        .{
            .source = "<column>\n  <row resize-duration=\"180\">\n    <text>a</text>\n  </row>\n</column>",
            .message = markup.resize_duration_element_message,
        },
        .{
            .source = "<column>\n  <scroll resize-easing=\"standard\">\n    <column><text>a</text></column>\n  </scroll>\n</column>",
            .message = markup.resize_easing_element_message,
        },
        // Easing shapes a ramp only a nonzero duration declares: alone,
        // or beside a literal 0, it is silently inert data (same policy
        // as anchor-alignment without anchor).
        .{
            .source = "<column>\n  <split value=\"{fraction}\" resize-easing=\"standard\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
            .message = markup.resize_easing_dependent_attr_message,
        },
        .{
            .source = "<column>\n  <split value=\"{fraction}\" resize-duration=\"0\" resize-easing=\"standard\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
            .message = markup.resize_easing_dependent_attr_message,
        },
        // Literal easing values outside the closed vocabulary teach the
        // set (the names mirror canvas.Easing member for member).
        .{
            .source = "<column>\n  <split value=\"{fraction}\" resize-duration=\"180\" resize-easing=\"bouncy\">\n    <panel><text>a</text></panel>\n    <panel><text>b</text></panel>\n  </split>\n</column>",
            .message = markup.resize_easing_value_message,
        },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
    }
}

test "size validates as the two-axis closed vocabulary with teaching errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Valid: the control scale on controls, the typography rungs on
    // text, and bindings (resolved by the engines at build).
    const valid_sources = [_][]const u8{
        "<column>\n  <button size=\"sm\" on-press=\"go\">Go</button>\n</column>",
        "<column>\n  <text size=\"heading\">Section</text>\n</column>",
        "<column>\n  <text size=\"display\">42.7</text>\n</column>",
        "<column>\n  <text size=\"display\" wrap=\"true\">A hero line that may wrap</text>\n</column>",
        "<column>\n  <text size=\"{stat_size}\">42</text>\n</column>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // The typography rungs are text-only: on a control the size
        // register is the control scale, a different axis.
        .{
            .source = "<column>\n  <button size=\"display\" on-press=\"go\">Go</button>\n</column>",
            .message = markup.text_size_element_message,
        },
        .{
            .source = "<column>\n  <badge size=\"heading\">3</badge>\n</column>",
            .message = markup.text_size_element_message,
        },
        // Unknown values teach the whole vocabulary; numeric sizes are
        // refused by design (type sizes are themable token steps).
        .{
            .source = "<column>\n  <text size=\"title\">Section</text>\n</column>",
            .message = markup.size_value_message,
        },
        .{
            .source = "<column>\n  <text size=\"48\">42.7</text>\n</column>",
            .message = markup.size_value_message,
        },
        .{
            .source = "<column>\n  <button size=\"tiny\" on-press=\"go\">Go</button>\n</column>",
            .message = markup.size_value_message,
        },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expectEqual(@as(usize, 2), info.line);
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

test "chart and series validate structure with teaching messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const valid_sources = [_][]const u8{
        "<column>\n  <chart y-min=\"0\" y-max=\"1\" grid-lines=\"4\" baseline=\"true\" width=\"239\" height=\"32\" label=\"CPU history\">\n    <series kind=\"bar\" values=\"{cpu_history}\" color=\"accent\" label=\"cpu\" />\n    <series kind=\"area\" values=\"{latency}\" />\n  </chart>\n</column>",
        "<column>\n  <chart grow=\"1\" stroke-width=\"2\">\n    <series values=\"{levels}\" />\n  </chart>\n</column>",
        // Axis labels and hover details: x-labels bind a string
        // iterable, the flags are ordinary truthy attributes.
        "<column>\n  <chart x-labels=\"{months}\" y-labels=\"true\" hover-details=\"true\">\n    <series values=\"{levels}\" />\n  </chart>\n</column>",
    };
    for (valid_sources) |source| {
        var parser = markup.Parser.init(arena, source);
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<column>\n  <chart gap=\"4\">\n    <series values=\"{levels}\" />\n  </chart>\n</column>", .message = markup.chart_attr_message },
        // The label data channel is a binding, never a literal.
        .{ .source = "<column>\n  <chart x-labels=\"jan\">\n    <series values=\"{levels}\" />\n  </chart>\n</column>", .message = markup.chart_x_labels_message },
        .{ .source = "<column>\n  <chart on-press=\"pick\">\n    <series values=\"{levels}\" />\n  </chart>\n</column>", .message = markup.chart_display_only_message },
        .{ .source = "<column>\n  <chart />\n</column>", .message = markup.chart_series_required_message },
        .{ .source = "<column>\n  <chart>\n    <text>x</text>\n  </chart>\n</column>", .message = markup.chart_children_message },
        // The series set is static: dynamic composition stays with the
        // Zig builder, so structure tags inside a chart teach that.
        .{ .source = "<column>\n  <chart>\n    <for each=\"rows\" as=\"row\">\n      <series values=\"{row.levels}\" />\n    </for>\n  </chart>\n</column>", .message = markup.chart_children_message },
        .{ .source = "<column>\n  <series values=\"{levels}\" />\n</column>", .message = markup.series_parent_message },
        .{ .source = "<column>\n  <chart>\n    <series />\n  </chart>\n</column>", .message = markup.series_values_message },
        .{ .source = "<column>\n  <chart>\n    <series values=\"7\" />\n  </chart>\n</column>", .message = markup.series_values_message },
        // Band envelopes need a paired lower edge; the teaching error
        // names the Zig builder as the home.
        .{ .source = "<column>\n  <chart>\n    <series kind=\"band\" values=\"{levels}\" />\n  </chart>\n</column>", .message = markup.series_kind_message },
        .{ .source = "<column>\n  <chart>\n    <series kind=\"{kind}\" values=\"{levels}\" />\n  </chart>\n</column>", .message = markup.series_kind_message },
        .{ .source = "<column>\n  <chart>\n    <series values=\"{levels}\" color=\"magenta\" />\n  </chart>\n</column>", .message = markup.series_color_message },
        .{ .source = "<column>\n  <chart>\n    <series values=\"{levels}\" fill=\"true\" />\n  </chart>\n</column>", .message = markup.series_attr_message },
        .{ .source = "<column>\n  <chart>\n    <series values=\"{levels}\">\n      <text>x</text>\n    </series>\n  </chart>\n</column>", .message = markup.series_children_message },
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

    // view.native imports components/pills.native, which imports base.native from
    // its own directory (transitive, subdirectory, relative-to-importer).
    const set = [_]markup.SourceFile{
        .{ .path = "view.native", .source = "<import src=\"components/pills.native\"/>\n<template name=\"local\"><text>l</text></template>\n<row>\n  <use template=\"pill-stack\" title=\"T\" />\n</row>" },
        .{ .path = "components/pills.native", .source = "<import src=\"base.native\"/>\n<template name=\"pill-stack\" args=\"title\"><column><use template=\"pill\" label=\"{title}\" /></column></template>" },
        .{ .path = "components/base.native", .source = "<template name=\"pill\" args=\"label\"><badge>{label}</badge></template>" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    const document = try resolveSet(arena, &set, "view.native", &diagnostic);

    // Depth-first splice order: transitive imports first, then the
    // importer's templates, then the root's own.
    try testing.expectEqual(@as(usize, 3), document.templates.len);
    try testing.expectEqualStrings("pill", document.templates[0].attr("name").?);
    try testing.expectEqualStrings("pill-stack", document.templates[1].attr("name").?);
    try testing.expectEqualStrings("local", document.templates[2].attr("name").?);
    try testing.expectEqual(@as(usize, 0), document.imports.len);

    // Every node is stamped with its source file for diagnostics.
    try testing.expectEqualStrings("components/base.native", document.templates[0].src_path);
    try testing.expectEqualStrings("components/pills.native", document.templates[1].src_path);
    try testing.expectEqualStrings("view.native", document.templates[2].src_path);
    try testing.expectEqualStrings("view.native", document.root.?.src_path);
    try testing.expectEqualStrings("components/base.native", document.templates[0].children[0].src_path);

    // The merged document passes the strict (resolved) validation pass.
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));
}

test "import cycles are reported with the cycle path spelled out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const set = [_]markup.SourceFile{
        .{ .path = "a.native", .source = "<import src=\"b.native\"/>\n<row />" },
        .{ .path = "b.native", .source = "<import src=\"a.native\"/>\n<template name=\"t\"><text>x</text></template>" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "a.native", &diagnostic));
    try testing.expectEqualStrings("import cycle: a.native -> b.native -> a.native", diagnostic.message);
    try testing.expectEqualStrings("b.native", diagnostic.path);

    // Self-import is the shortest cycle.
    const self_set = [_]markup.SourceFile{
        .{ .path = "a.native", .source = "<import src=\"a.native\"/>\n<row />" },
    };
    try testing.expectError(error.MarkupImport, resolveSet(arena, &self_set, "a.native", &diagnostic));
    try testing.expectEqualStrings("import cycle: a.native -> a.native", diagnostic.message);
}

test "duplicate template names across files name both definition sites" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const set = [_]markup.SourceFile{
        .{ .path = "view.native", .source = "<import src=\"one.native\"/>\n<import src=\"two.native\"/>\n<row />" },
        .{ .path = "one.native", .source = "<template name=\"card\"><text>1</text></template>" },
        .{ .path = "two.native", .source = "<template name=\"card\"><text>2</text></template>" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "view.native", &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "duplicate template name \"card\"") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "one.native:1:1") != null);
    try testing.expectEqualStrings("two.native", diagnostic.path);

    // Import vs local: the local definition collides with the imported one.
    const local_set = [_]markup.SourceFile{
        .{ .path = "view.native", .source = "<import src=\"one.native\"/>\n<template name=\"card\"><text>l</text></template>\n<row />" },
        .{ .path = "one.native", .source = "<template name=\"card\"><text>1</text></template>" },
    };
    try testing.expectError(error.MarkupImport, resolveSet(arena, &local_set, "view.native", &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "duplicate template name \"card\"") != null);
    try testing.expectEqualStrings("view.native", diagnostic.path);
}

test "import path escapes, absolute paths, and bad extensions are teaching errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { src: []const u8, message: []const u8 }{
        .{ .src = "../secrets.native", .message = markup.import_src_escape_message },
        .{ .src = "/etc/passwd.native", .message = markup.import_src_absolute_message },
        .{ .src = "c:\\parts.native", .message = markup.import_src_absolute_message },
        .{ .src = "parts.txt", .message = markup.import_src_extension_message },
        .{ .src = "", .message = markup.import_src_message },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(arena, "<import src=\"{s}\"/>\n<row />", .{case.src});
        const set = [_]markup.SourceFile{.{ .path = "src/view.native", .source = source }};
        var diagnostic: markup.MarkupErrorInfo = .{};
        try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "src/view.native", &diagnostic));
        try testing.expectEqualStrings(case.message, diagnostic.message);
        try testing.expectEqual(@as(usize, 1), diagnostic.line);
    }

    // Within-root ".." stays legal: components can reach a sibling folder
    // under the markup root.
    var buffer: [markup.max_import_path_len]u8 = undefined;
    const resolved = markup.resolveImportPath("src", "src/components/pills.native", "../shared/base.native", &buffer);
    try testing.expectEqualStrings("src/shared/base.native", resolved.path);
    const escaped = markup.resolveImportPath("src", "src/view.native", "../../other.native", &buffer);
    try testing.expectEqualStrings(markup.import_src_escape_message, escaped.message);
}

test "an absolute root path resolves imports the same as a relative one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Checking a view by absolute path (as `native markup check /abs/view.native`
    // does) must behave exactly like the relative form: joined import paths
    // keep the leading "/", so they stay under the absolute markup root and
    // load from the right place. Regression: the join used to drop the "/",
    // making every import of an absolutely-addressed view "escape" the root.
    var buffer: [markup.max_import_path_len]u8 = undefined;
    const resolved = markup.resolveImportPath("/app/src", "/app/src/view.native", "components/card.native", &buffer);
    try testing.expectEqualStrings("/app/src/components/card.native", resolved.path);

    // The full resolver, rooted at an absolute path, resolves the closure.
    const set = [_]markup.SourceFile{
        .{ .path = "/app/src/view.native", .source = "<import src=\"components/card.native\"/>\n<column><card/></column>" },
        .{ .path = "/app/src/components/card.native", .source = "<template name=\"card\"><text>hi</text></template>" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    const document = try resolveSet(arena, &set, "/app/src/view.native", &diagnostic);
    try testing.expectEqual(@as(usize, 1), document.templates.len);

    // An import that genuinely climbs out of the absolute root still fails.
    const escaped = markup.resolveImportPath("/app/src", "/app/src/view.native", "../other.native", &buffer);
    try testing.expectEqualStrings(markup.import_src_escape_message, escaped.message);
}

test ".native is the one markup extension" {
    try testing.expect(markup.hasMarkupExtension("view.native"));
    try testing.expect(!markup.hasMarkupExtension("view.html"));
    try testing.expect(!markup.hasMarkupExtension("view.xml"));
    try testing.expect(!markup.hasMarkupExtension("view.native.txt"));
}

test "an imported file with a view root is rejected with the teaching error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const set = [_]markup.SourceFile{
        .{ .path = "view.native", .source = "<import src=\"other.native\"/>\n<row />" },
        .{ .path = "other.native", .source = "<template name=\"t\"><text>x</text></template>\n<column />" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "view.native", &diagnostic));
    try testing.expectEqualStrings(markup.import_view_root_message, diagnostic.message);
    try testing.expectEqualStrings("other.native", diagnostic.path);
}

test "a missing imported file reports at the importing file's position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const set = [_]markup.SourceFile{
        .{ .path = "view.native", .source = "<row />\n" },
        .{ .path = "importer.native", .source = "<import src=\"nope.native\"/>\n<row />" },
    };
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, &set, "importer.native", &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "unable to read imported file \"nope.native\"") != null);
    try testing.expectEqualStrings("importer.native", diagnostic.path);
    try testing.expectEqual(@as(usize, 1), diagnostic.line);
}

test "hostile import chains and template counts get bounded errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A chain one past max_import_depth errors instead of recursing on.
    var files: std.ArrayListUnmanaged(markup.SourceFile) = .empty;
    for (0..markup.max_import_depth + 1) |index| {
        const path = try std.fmt.allocPrint(arena, "c{d}.native", .{index});
        const source = if (index == markup.max_import_depth)
            try std.fmt.allocPrint(arena, "<template name=\"leaf\"><text>x</text></template>", .{})
        else
            try std.fmt.allocPrint(arena, "<import src=\"c{d}.native\"/>\n<template name=\"t{d}\"><text>x</text></template>", .{ index + 1, index });
        try files.append(arena, .{ .path = path, .source = source });
    }
    var diagnostic: markup.MarkupErrorInfo = .{};
    try testing.expectError(error.MarkupImport, resolveSet(arena, files.items, "c0.native", &diagnostic));
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
    var parser = markup.Parser.init(arena, "<template name=\"t\"><text>x</text></template>\n<import src=\"a.native\"/>\n<row />");
    try testing.expectError(error.MarkupSyntax, parser.parse());
    try testing.expectEqualStrings(markup.import_top_level_message, parser.diagnostic.message);

    const shape_cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<import/>\n<row />", .message = markup.import_src_message },
        .{ .source = "<import src=\"a.native\" extra=\"1\"/>\n<row />", .message = markup.import_attrs_message },
        .{ .source = "<import src=\"a.native\"><text>x</text></import>\n<row />", .message = markup.import_children_message },
        .{ .source = "<column>\n  <import src=\"a.native\"/>\n</column>", .message = markup.import_top_level_message },
    };
    for (shape_cases) |case| {
        var case_parser = markup.Parser.init(arena, case.source);
        const info = markup.validate(try case_parser.parse()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.message, info.message);
    }

    // A view with unresolved imports skips use-reference checks (the
    // template may come from the import); everything else still validates.
    var lenient_parser = markup.Parser.init(arena, "<import src=\"a.native\"/>\n<row>\n  <use template=\"from-import\" whatever=\"1\" />\n</row>");
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
        // Quote characters in a default are literal text, not string
        // delimiters - rejected with the bare-form teaching instead of
        // silently rendering the quotes.
        .{ .source = "<template name=\"t\" args=\"trend='flat'\"><text>{trend}</text></template>\n<row />", .message = markup.template_default_quoted_message },
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
            if (std.mem.eql(u8, node.text, " ") and !std.mem.eql(u8, source[node.span.start..node.span.end], " ")) {
                // The parser-spliced inline separator (span paragraphs):
                // its text is the canonical single space while its span
                // covers the whitespace gap it collapsed, so write-back
                // still owns the exact source bytes.
                try testing.expect(node.span.end > node.span.start);
            } else {
                // A text run's span is exactly its trimmed visible bytes.
                try testing.expectEqualStrings(node.text, source[node.span.start..node.span.end]);
            }
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

// ------------------------------------------------- inline span separators

test "whitespace between a span paragraph's runs collapses to one spliced space" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Whitespace between inline children is STRUCTURE inside a span
    // paragraph: the parser materializes it as a single-space text node,
    // so spacing serializes, hashes, and round-trips as ordinary content.
    const source = "<column><text>value <span weight=\"bold\">42</span>\n    of <span mono=\"true\">60</span>.</text></column>";
    var parser = markup.Parser.init(arena, source);
    const document = try parser.parse();
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));
    const text_node = document.root.?.children[0];

    // [value][ ][span 42][ ][of][ ][span 60][.] — the multi-byte
    // "\n    " gap collapses to one space, and the "." run abuts its
    // span (no gap, no separator).
    try testing.expectEqual(@as(usize, 8), text_node.children.len);
    try testing.expectEqualStrings("value", text_node.children[0].text);
    try testing.expectEqualStrings(" ", text_node.children[1].text);
    try testing.expect(markup.nodeIsSpan(text_node.children[2]));
    try testing.expectEqualStrings(" ", text_node.children[3].text);
    try testing.expectEqualStrings("of", text_node.children[4].text);
    try testing.expectEqualStrings(" ", text_node.children[5].text);
    try testing.expect(markup.nodeIsSpan(text_node.children[6]));
    try testing.expectEqualStrings(".", text_node.children[7].text);

    // Separator spans cover the exact whitespace gap (write-back bytes),
    // and their positions derive from the gap start like every node.
    const separator = text_node.children[3];
    try testing.expectEqualStrings("\n    ", source[separator.span.start..separator.span.end]);
    try expectSpansCover(source, document.root.?);

    // The comptime parser splices identical separators.
    const comptime_document = comptime markup.parseComptime("<column><text>value <span weight=\"bold\">42</span>\n    of <span mono=\"true\">60</span>.</text></column>");
    const comptime_text = comptime_document.root.?.children[0];
    try testing.expectEqual(@as(usize, 8), comptime_text.children.len);
    try testing.expectEqualStrings(" ", comptime_text.children[1].text);
    try testing.expectEqualStrings(".", comptime_text.children[7].text);

    // Span-less text keeps the classic trim: no separators appear.
    var plain_parser = markup.Parser.init(arena, "<column><text>  hi there  </text></column>");
    const plain = try plain_parser.parse();
    try testing.expectEqual(@as(usize, 1), plain.root.?.children[0].children.len);
    try testing.expectEqualStrings("hi there", plain.root.?.children[0].children[0].text);

    // Comments between runs are transparent: their bytes never count as
    // author whitespace, so commented-but-abutting runs stay abutting.
    var comment_parser = markup.Parser.init(arena, "<column><text><span>a</span><!-- glue --><span>b</span></text></column>");
    const commented = try comment_parser.parse();
    try testing.expectEqual(@as(usize, 2), commented.root.?.children[0].children.len);
}
