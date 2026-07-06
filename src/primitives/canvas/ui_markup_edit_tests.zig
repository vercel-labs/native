//! Span-edit matrix for the write-back op layer: every operation shape
//! against byte-exact expected output (the minimal-diff invariant is the
//! whole point, so the expectations are full source strings), plus the
//! reparse-invariance pin and the hostile cases (span drift, truncated
//! files, unrepresentable values, structure-changing text).

const std = @import("std");
const markup = @import("ui_markup.zig");
const edit = @import("ui_markup_edit.zig");

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,

    fn init() Harness {
        return .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
    }

    fn arena(self: *Harness) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// Span start of the first node named `name` in a parse of `source`.
    fn spanOf(self: *Harness, source: []const u8, name: []const u8) !usize {
        var parser = markup.Parser.init(self.arena(), source);
        const document = try parser.parse();
        var found: ?usize = null;
        if (document.root) |root| findNamed(root, name, &found);
        for (document.templates) |template_node| findNamed(template_node, name, &found);
        try std.testing.expect(found != null);
        return found.?;
    }

    fn findNamed(node: markup.MarkupNode, name: []const u8, found: *?usize) void {
        if (found.* != null) return;
        if (std.mem.eql(u8, node.name, name)) {
            found.* = node.span.start;
            return;
        }
        for (node.children) |child| findNamed(child, name, found);
    }

    fn expectEdit(self: *Harness, source: []const u8, target: []const u8, op: edit.EditOp, expected: []const u8) !void {
        const span_start = try self.spanOf(source, target);
        var diagnostic: markup.MarkupErrorInfo = .{};
        const edited = try edit.applyChecked(self.arena(), source, span_start, op, &diagnostic);
        try std.testing.expectEqualStrings(expected, edited);
    }

    fn expectRefusal(self: *Harness, source: []const u8, span_start: usize, op: edit.EditOp, expected_error: anyerror, expected_message: []const u8) !void {
        var diagnostic: markup.MarkupErrorInfo = .{};
        try std.testing.expectError(expected_error, edit.applyChecked(self.arena(), source, span_start, op, &diagnostic));
        try std.testing.expectEqualStrings(expected_message, diagnostic.message);
    }
};

test "set-attr replaces exactly the value bytes of an existing attribute" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column gap=\"8\"  padding=\"16\">\n  <text>hi</text>\n</column>",
        "column",
        .{ .set_attr = .{ .name = "gap", .value = "24" } },
        "<column gap=\"24\"  padding=\"16\">\n  <text>hi</text>\n</column>",
    );
}

test "set-attr keeps whitespace around a spaced equals sign" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<row gap = \"8\"><text>x</text></row>",
        "row",
        .{ .set_attr = .{ .name = "gap", .value = "12" } },
        "<row gap = \"12\"><text>x</text></row>",
    );
}

test "set-attr adds a value to a value-less attribute at the name's end" {
    var h = Harness.init();
    defer h.deinit();
    // `wrap` with no value parses as the empty string; giving it a value
    // inserts `="..."` at the documented insertion point.
    try h.expectEdit(
        "<column><text wrap>hello</text></column>",
        "text",
        .{ .set_attr = .{ .name = "wrap", .value = "false" } },
        "<column><text wrap=\"false\">hello</text></column>",
    );
}

test "set-attr appends a missing attribute after the last attribute" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column gap=\"8\">\n  <text>hi</text>\n</column>",
        "column",
        .{ .set_attr = .{ .name = "padding", .value = "16" } },
        "<column gap=\"8\" padding=\"16\">\n  <text>hi</text>\n</column>",
    );
}

test "set-attr appends after the element name when there are no attributes" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column>\n  <text>hi</text>\n</column>",
        "column",
        .{ .set_attr = .{ .name = "gap", .value = "8" } },
        "<column gap=\"8\">\n  <text>hi</text>\n</column>",
    );
}

test "set-attr appends inside a self-closing tag keeping the tail spacing" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column><icon name=\"search\" /></column>",
        "icon",
        .{ .set_attr = .{ .name = "width", .value = "20" } },
        "<column><icon name=\"search\" width=\"20\" /></column>",
    );
}

test "remove-attr deletes the attribute and its preceding whitespace only" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column gap=\"8\" padding=\"16\">\n  <text>hi</text>\n</column>",
        "column",
        .{ .remove_attr = .{ .name = "padding" } },
        "<column gap=\"8\">\n  <text>hi</text>\n</column>",
    );
    try h.expectEdit(
        "<column gap=\"8\" padding=\"16\">\n  <text>hi</text>\n</column>",
        "column",
        .{ .remove_attr = .{ .name = "gap" } },
        "<column padding=\"16\">\n  <text>hi</text>\n</column>",
    );
}

test "remove-attr on a value-less attribute" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column><text wrap>hello</text></column>",
        "text",
        .{ .remove_attr = .{ .name = "wrap" } },
        "<column><text>hello</text></column>",
    );
}

test "set-text replaces exactly the text run, preserving indentation" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column>\n  <text>\n    old words\n  </text>\n</column>",
        "text",
        .{ .set_text = .{ .text = "new words" } },
        "<column>\n  <text>\n    new words\n  </text>\n</column>",
    );
}

test "set-text fills an empty paired element" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column><button label=\"Go\" on-press=\"go\"></button></column>",
        "button",
        .{ .set_text = .{ .text = "Run" } },
        "<column><button label=\"Go\" on-press=\"go\">Run</button></column>",
    );
}

test "set-text rewrites a self-closing element to the paired form inside its span" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column>\n  <text/>\n</column>",
        "text",
        .{ .set_text = .{ .text = "hello" } },
        "<column>\n  <text>hello</text>\n</column>",
    );
}

test "unicode survives byte-exact in values and text" {
    var h = Harness.init();
    defer h.deinit();
    try h.expectEdit(
        "<column label=\"Ergebnis\"><text>alt</text></column>",
        "text",
        .{ .set_text = .{ .text = "Grüße — 12€" } },
        "<column label=\"Ergebnis\"><text>Grüße — 12€</text></column>",
    );
    try h.expectEdit(
        "<column><button label=\"Fermer\" on-press=\"close\">Fermer</button></column>",
        "button",
        .{ .set_attr = .{ .name = "label", .value = "Ergebnis übernehmen" } },
        "<column><button label=\"Ergebnis übernehmen\" on-press=\"close\">Fermer</button></column>",
    );
}

test "edits inside a component file (all templates, no root) work by span" {
    var h = Harness.init();
    defer h.deinit();
    const component =
        "<template name=\"pill\" args=\"label\">\n" ++
        "  <badge icon=\"check\" label=\"chip\">{label}</badge>\n" ++
        "</template>\n";
    try h.expectEdit(
        component,
        "badge",
        .{ .set_attr = .{ .name = "icon", .value = "x" } },
        "<template name=\"pill\" args=\"label\">\n" ++
            "  <badge icon=\"x\" label=\"chip\">{label}</badge>\n" ++
            "</template>\n",
    );
}

test "comments and sibling formatting outside the span survive byte for byte" {
    var h = Harness.init();
    defer h.deinit();
    const source =
        "<column gap=\"8\">\n" ++
        "  <!-- header keeps its comment -->\n" ++
        "  <text>title</text>\n" ++
        "  <row   gap=\"4\"><text>a</text><text>b</text></row>\n" ++
        "</column>";
    const span_start = try h.spanOf(source, "row");
    var diagnostic: markup.MarkupErrorInfo = .{};
    const edited = try edit.applyChecked(h.arena(), source, span_start, .{ .set_attr = .{ .name = "gap", .value = "6" } }, &diagnostic);
    // Everything before and after the two changed bytes is identical.
    const changed = std.mem.indexOfDiff(u8, source, edited).?;
    try std.testing.expectEqualStrings("4", source[changed .. changed + 1]);
    try std.testing.expectEqualStrings("6", edited[changed .. changed + 1]);
    try std.testing.expectEqualStrings(source[changed + 1 ..], edited[changed + 1 ..]);
}

test "reparse invariance: the checked pipeline proves every other node is untouched" {
    var h = Harness.init();
    defer h.deinit();
    // A document exercising attributes, structure tags, templates, text
    // interpolation, and nesting; the checked apply diffs the parse trees,
    // so success IS the invariance proof. Then a paranoid double-check:
    // reparsing the edited source and re-editing back yields the original.
    const source =
        "<template name=\"card\" args=\"title\">\n" ++
        "  <panel padding=\"8\"><text>{title}</text></panel>\n" ++
        "</template>\n" ++
        "<column gap=\"8\">\n" ++
        "  <for each=\"cards\" as=\"card\" key=\"id\">\n" ++
        "    <use template=\"card\" title=\"{card.title}\"/>\n" ++
        "  </for>\n" ++
        "  <button on-press=\"add\">Add task</button>\n" ++
        "</column>";
    const span_start = try h.spanOf(source, "button");
    var diagnostic: markup.MarkupErrorInfo = .{};
    const edited = try edit.applyChecked(h.arena(), source, span_start, .{ .set_text = .{ .text = "Add card" } }, &diagnostic);
    const back_start = try h.spanOf(edited, "button");
    const restored = try edit.applyChecked(h.arena(), edited, back_start, .{ .set_text = .{ .text = "Add task" } }, &diagnostic);
    try std.testing.expectEqualStrings(source, restored);
}

test "hostile: stale span offset is refused with the drift message" {
    var h = Harness.init();
    defer h.deinit();
    const source = "<column gap=\"8\"><text>hi</text></column>";
    try h.expectRefusal(source, 3, .{ .set_attr = .{ .name = "gap", .value = "9" } }, error.MarkupSyntax, edit.edit_span_stale_message);
    try h.expectRefusal(source, source.len + 10, .{ .set_attr = .{ .name = "gap", .value = "9" } }, error.MarkupSyntax, edit.edit_span_stale_message);
}

test "hostile: truncated file fails the parse before any edit" {
    var h = Harness.init();
    defer h.deinit();
    var diagnostic: markup.MarkupErrorInfo = .{};
    try std.testing.expectError(
        error.MarkupSyntax,
        edit.applyChecked(h.arena(), "<column gap=\"8\"><text>hi</te", 0, .{ .set_attr = .{ .name = "gap", .value = "9" } }, &diagnostic),
    );
    try std.testing.expect(diagnostic.message.len > 0);
}

test "hostile: unrepresentable attribute values are refused up front" {
    var h = Harness.init();
    defer h.deinit();
    const source = "<column gap=\"8\"><text>hi</text></column>";
    try h.expectRefusal(source, 0, .{ .set_attr = .{ .name = "label", .value = "say \"hi\"" } }, error.MarkupEdit, edit.edit_value_quote_message);
    try h.expectRefusal(source, 0, .{ .set_attr = .{ .name = "label", .value = "two\nlines" } }, error.MarkupEdit, edit.edit_value_newline_message);
    try h.expectRefusal(source, 0, .{ .set_attr = .{ .name = "Bad Name", .value = "x" } }, error.MarkupEdit, edit.edit_attr_name_message);
}

test "hostile: structure-changing text is refused" {
    var h = Harness.init();
    defer h.deinit();
    const source = "<column><text>hi</text></column>";
    const text_start = try h.spanOf(source, "text");
    try h.expectRefusal(source, text_start, .{ .set_text = .{ .text = "<icon/>" } }, error.MarkupEdit, edit.edit_text_lt_message);
    try h.expectRefusal(source, text_start, .{ .set_text = .{ .text = " padded " } }, error.MarkupEdit, edit.edit_text_trim_message);
    try h.expectRefusal(source, text_start, .{ .set_text = .{ .text = "" } }, error.MarkupEdit, edit.edit_text_empty_message);
    try h.expectRefusal(source, 0, .{ .set_text = .{ .text = "flat" } }, error.MarkupEdit, edit.edit_text_children_message);
}

test "hostile: removing an absent attribute is refused" {
    var h = Harness.init();
    defer h.deinit();
    const source = "<column gap=\"8\"><text>hi</text></column>";
    try h.expectRefusal(source, 0, .{ .remove_attr = .{ .name = "padding" } }, error.MarkupEdit, edit.edit_attr_missing_message);
}

test "hostile: an edit that fails validation leaves the caller with the teaching error" {
    var h = Harness.init();
    defer h.deinit();
    const source = "<column gap=\"8\"><text>hi</text></column>";
    // `bogus` is not a known attribute anywhere; the reparse validator
    // refuses it, so a tool never writes an invalid file.
    var diagnostic: markup.MarkupErrorInfo = .{};
    try std.testing.expectError(
        error.MarkupValidation,
        edit.applyChecked(h.arena(), source, 0, .{ .set_attr = .{ .name = "bogus", .value = "1" } }, &diagnostic),
    );
    try std.testing.expect(diagnostic.message.len > 0);
}

test "hostile: interpolation braces still validate after a text edit" {
    var h = Harness.init();
    defer h.deinit();
    const source = "<column><text>hi</text></column>";
    const text_start = try h.spanOf(source, "text");
    var diagnostic: markup.MarkupErrorInfo = .{};
    // An unterminated interpolation reparses but fails the validator.
    try std.testing.expectError(
        error.MarkupValidation,
        edit.applyChecked(h.arena(), source, text_start, .{ .set_text = .{ .text = "count: {open" } }, &diagnostic),
    );
    // A well-formed binding passes.
    const edited = try edit.applyChecked(h.arena(), source, text_start, .{ .set_text = .{ .text = "count: {label}" } }, &diagnostic);
    try std.testing.expectEqualStrings("<column><text>count: {label}</text></column>", edited);
}
