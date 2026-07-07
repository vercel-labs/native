//! NSUI codec conformance: golden bytes, round-trip equality, the
//! document hash's field coverage (the render wire's fingerprint-audit
//! pattern applied to the schema), and the refusal paths (unknown
//! version/codes, truncation, trailing bytes, hostile depth).

const std = @import("std");
const markup = @import("ui_markup.zig");
const nsui = @import("ui_markup_binary.zig");
const schema = @import("ui_schema.zig");
const testing = std.testing;

fn parseSource(arena: std.mem.Allocator, source: []const u8) !markup.MarkupDocument {
    var parser = markup.Parser.init(arena, source);
    const document = try parser.parse();
    return markup.canonicalize(arena, document);
}

fn hashOf(arena: std.mem.Allocator, source: []const u8) !u64 {
    return nsui.documentHash(arena, try parseSource(arena, source));
}

/// Structural equality over decoded documents: names, attrs (name +
/// value), text, children, spans, and source paths — everything the wire
/// carries.
fn expectNodesEqual(expected: markup.MarkupNode, actual: markup.MarkupNode) !void {
    try testing.expectEqual(expected.kind, actual.kind);
    try testing.expectEqualStrings(expected.name, actual.name);
    try testing.expectEqualStrings(expected.text, actual.text);
    try testing.expectEqualStrings(expected.src_path, actual.src_path);
    try testing.expectEqual(expected.span, actual.span);
    try testing.expectEqual(expected.attrs.len, actual.attrs.len);
    for (expected.attrs, actual.attrs) |expected_attr, actual_attr| {
        try testing.expectEqualStrings(expected_attr.name, actual_attr.name);
        try testing.expectEqualStrings(expected_attr.value, actual_attr.value);
        try testing.expectEqual(expected_attr.name_span, actual_attr.name_span);
        try testing.expectEqual(expected_attr.value_span, actual_attr.value_span);
    }
    try testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |expected_child, actual_child| {
        try expectNodesEqual(expected_child, actual_child);
    }
}

const fixture_source =
    \\<template name="chip" args="label tone=neutral">
    \\  <badge variant="{tone}">{label}</badge>
    \\</template>
    \\<column gap="8" background="surface">
    \\  <text wrap="true">{count} open</text>
    \\  <for each="items" key="id" as="item">
    \\    <row gap="4">
    \\      <checkbox checked="{item.done}" on-toggle="toggle:{item.id}" />
    \\      <use template="chip" label="{item.title}" />
    \\    </row>
    \\  </for>
    \\  <else>
    \\    <text>Nothing yet.</text>
    \\  </else>
    \\</column>
;

test "NSUI round-trips a document byte-for-byte and node-for-node" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try parseSource(arena, fixture_source);

    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);
    const decoded = try nsui.decode(arena, bytes, &diagnostic);

    try testing.expectEqual(document.templates.len, decoded.templates.len);
    for (document.templates, decoded.templates) |expected, actual| {
        try expectNodesEqual(expected, actual);
    }
    try expectNodesEqual(document.root.?, decoded.root.?);

    // Decoded documents come back canonicalized (typed values stamped).
    const decoded_checkbox = decoded.root.?.children[1].children[0].children[0];
    try testing.expect(decoded_checkbox.attrEntry("checked").?.typed.?.* == .binding);
    try testing.expect(decoded_checkbox.attrEntry("on-toggle").?.typed.?.* == .message);

    // Determinism: encoding is a pure function of the document.
    const again = try nsui.encode(arena, document, .{}, &diagnostic);
    try testing.expectEqualSlices(u8, bytes, again);

    // Re-encoding the DECODED document without spans/provenance matches
    // the original stripped encoding: the binary is self-sufficient.
    const stripped = try nsui.encode(arena, document, .{ .spans = false, .provenance = false }, &diagnostic);
    const re_stripped = try nsui.encode(arena, decoded, .{ .spans = false, .provenance = false }, &diagnostic);
    try testing.expectEqualSlices(u8, stripped, re_stripped);
}

test "NSUI round-trips app: and bound icon values as plain attribute strings" {
    // Icon values are VALUES: NSUI writes every attribute value as an
    // inline str16 under the attr's existing code (name=36, icon=37), so
    // the app: namespace and {binding} forms ride the wire with no new
    // codes and no schema bump - purely additive vocabulary.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\<row gap="8">
        \\  <icon name="app:wave-pulse" />
        \\  <icon name="{status_icon}" />
        \\  <button icon="app:wave" on-press="play" label="Wave"></button>
        \\  <button icon="{status_icon}" on-press="play" label="Status"></button>
        \\</row>
    ;
    const document = try parseSource(arena, source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));

    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);
    const decoded = try nsui.decode(arena, bytes, &diagnostic);
    try expectNodesEqual(document.root.?, decoded.root.?);

    // Decoded documents come back canonicalized with the same typed
    // classification the engines consume.
    try testing.expect(decoded.root.?.children[0].attrEntry("name").?.typed.?.* == .literal);
    try testing.expect(decoded.root.?.children[1].attrEntry("name").?.typed.?.* == .binding);
}

test "NSUI round-trips the input-group vocabulary under its fresh codes" {
    // The grouped-input composite serializes like any element — fresh
    // registry codes ride the wire automatically, no schema bump — so a
    // full composer document survives encode/decode node-for-node.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\<column gap="8">
        \\  <input-group label="Composer" height="120">
        \\    <textarea text="{draft}" placeholder="Type a message" on-input="edit" label="Message" />
        \\    <input-group-actions>
        \\      <button icon="plus" variant="ghost" size="icon" on-press="attach" label="Attach"></button>
        \\      <spacer grow="1" />
        \\      <button icon="send" size="icon" on-press="send" label="Send"></button>
        \\    </input-group-actions>
        \\  </input-group>
        \\</column>
    ;
    const document = try parseSource(arena, source);

    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);
    const decoded = try nsui.decode(arena, bytes, &diagnostic);
    try expectNodesEqual(document.root.?, decoded.root.?);

    // The wire carries the registry codes, never the names.
    try testing.expectEqual(@as(u16, 62), schema.elementByName("input-group").?.code);
    try testing.expectEqual(@as(u16, 63), schema.elementByName("input-group-actions").?.code);
}

test "NSUI round-trips the split layout-tween pair under its fresh codes" {
    // resize-duration/resize-easing serialize like any attribute — fresh
    // registry codes ride the wire automatically, no schema bump — so a
    // tweened split survives encode/decode node-for-node and the dump
    // shows the pair by name and code.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\<split value="{fraction}" resize-duration="180" resize-easing="emphasized" on-resize="resized">
        \\  <panel><text>sidebar</text></panel>
        \\  <panel><text>content</text></panel>
        \\</split>
    ;
    const document = try parseSource(arena, source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));

    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);
    const decoded = try nsui.decode(arena, bytes, &diagnostic);
    try expectNodesEqual(document.root.?, decoded.root.?);

    // The wire carries the registry codes, never the names.
    try testing.expectEqual(@as(u16, 71), schema.attrByName("resize-duration").?.code);
    try testing.expectEqual(@as(u16, 72), schema.attrByName("resize-easing").?.code);

    // The JSON inspection view (`native markup dump`) shows the pair.
    const hash = try nsui.documentHash(arena, decoded);
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try nsui.writeJson(decoded, hash, &out.writer);
    const json = out.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"resize-duration\",\"code\":71,\"value\":\"180\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"resize-easing\",\"code\":72,\"value\":\"emphasized\"") != null);
}

test "NSUI golden bytes for a minimal document" {
    // Hand-checkable pin of the exact layout. If this changed, the WIRE
    // changed: bump the schema version and write the migration — never
    // silently reshape.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try parseSource(arena, "<row gap=\"4\"><text>hi</text></row>");
    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{ .spans = false, .provenance = false }, &diagnostic);
    const expected = [_]u8{
        'N', 'S', 'U', 'I', // magic
        1, 0, // schema_version = 1
        0, 0, // flags: no spans, no provenance
        0, 0, // template count = 0
        1, // root present
        1, // node kind: element
        1, 0, // element code: row = 1
        0, 0, 0, 0, // text len = 0
        1, 0, // attr count = 1
        12, 0, // attr code: gap = 12
        1, 0, '4', // value "4"
        1, 0, // child count = 1
        1, // element
        27, 0, // element code: text = 27
        0, 0, 0, 0, // text len = 0
        0, 0, // attr count = 0
        1, 0, // child count = 1
        2, // text run
        0, 0, // element code 0
        2, 0, 0, 0, 'h', 'i', // text "hi"
        0, 0, // attr count
        0, 0, // child count
    };
    try testing.expectEqualSlices(u8, &expected, bytes);
}

test "document hash covers every structural field and nothing else" {
    // The wire fingerprint-coverage pattern: one mutation per structural
    // field must change the hash; formatting and provenance must not.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = try hashOf(arena, "<column gap=\"8\"><text>hi</text><badge>b</badge></column>");

    // Whitespace/formatting only: IDENTICAL hash (spans differ, structure
    // does not — the whole point of hashing the span-stripped encoding).
    try testing.expectEqual(base, try hashOf(arena,
        \\<column   gap="8">
        \\  <text>hi</text>
        \\  <badge>b</badge>
        \\</column>
    ));

    // Element changed.
    try testing.expect(base != try hashOf(arena, "<row gap=\"8\"><text>hi</text><badge>b</badge></row>"));
    // Attribute name changed.
    try testing.expect(base != try hashOf(arena, "<column padding=\"8\"><text>hi</text><badge>b</badge></column>"));
    // Attribute value changed.
    try testing.expect(base != try hashOf(arena, "<column gap=\"9\"><text>hi</text><badge>b</badge></column>"));
    // Attribute removed.
    try testing.expect(base != try hashOf(arena, "<column><text>hi</text><badge>b</badge></column>"));
    // Text content changed.
    try testing.expect(base != try hashOf(arena, "<column gap=\"8\"><text>ho</text><badge>b</badge></column>"));
    // Node order changed.
    try testing.expect(base != try hashOf(arena, "<column gap=\"8\"><badge>b</badge><text>hi</text></column>"));
    // Child added.
    try testing.expect(base != try hashOf(arena, "<column gap=\"8\"><text>hi</text><badge>b</badge><spacer/></column>"));
    // Structure tag added.
    try testing.expect(base != try hashOf(arena, "<column gap=\"8\"><if test=\"{x}\"><text>hi</text></if><badge>b</badge></column>"));

    // Templates are structure too.
    const with_template = "<template name=\"chip\"><badge>b</badge></template><column gap=\"8\"><text>hi</text><badge>b</badge></column>";
    try testing.expect(base != try hashOf(arena, with_template));
    // A template's own content is structure.
    const with_other_template = "<template name=\"chip\"><badge>c</badge></template><column gap=\"8\"><text>hi</text><badge>b</badge></column>";
    try testing.expect(try hashOf(arena, with_template) != try hashOf(arena, with_other_template));
}

test "the hash ignores provenance: the same structure from another file layout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Resolve the same one-file structure under two different root names;
    // src_path stamps differ, the hash must not.
    const loader_a = markup.SourceSetLoader{ .set = &.{} };
    var diagnostic: markup.MarkupErrorInfo = .{};
    const doc_a = try markup.resolveImports(arena, "app/main.native", "<row><text>hi</text></row>", loader_a.loader(), &diagnostic);
    const doc_b = try markup.resolveImports(arena, "elsewhere/view.native", "<row><text>hi</text></row>", loader_a.loader(), &diagnostic);
    try testing.expect(doc_a.root.?.src_path.len > 0);
    try testing.expect(!std.mem.eql(u8, doc_a.root.?.src_path, doc_b.root.?.src_path));
    try testing.expectEqual(
        try nsui.documentHash(arena, doc_a),
        try nsui.documentHash(arena, doc_b),
    );
}

test "NSUI refuses what it does not know, loudly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try parseSource(arena, "<row><text>hi</text></row>");
    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);

    // Unknown schema version.
    {
        const mutated = try arena.dupe(u8, bytes);
        mutated[4] = 99;
        try testing.expectError(error.DocumentDecode, nsui.decode(arena, mutated, &diagnostic));
        try testing.expectEqualStrings(nsui.bad_version_message, diagnostic.message);
    }
    // Bad magic.
    {
        const mutated = try arena.dupe(u8, bytes);
        mutated[0] = 'X';
        try testing.expectError(error.DocumentDecode, nsui.decode(arena, mutated, &diagnostic));
        try testing.expectEqualStrings(nsui.bad_magic_message, diagnostic.message);
    }
    // Truncation.
    try testing.expectError(error.DocumentDecode, nsui.decode(arena, bytes[0 .. bytes.len - 1], &diagnostic));
    // Trailing bytes: framing disagreements refuse, never skip.
    {
        const padded = try arena.alloc(u8, bytes.len + 1);
        @memcpy(padded[0..bytes.len], bytes);
        padded[bytes.len] = 0;
        try testing.expectError(error.DocumentDecode, nsui.decode(arena, padded, &diagnostic));
    }
    // Unknown registry code (an element code no registry entry carries).
    {
        const stripped = try nsui.encode(arena, document, .{ .spans = false, .provenance = false }, &diagnostic);
        const mutated = try arena.dupe(u8, stripped);
        // Header (8) + template count (2) + root flag (1) + node kind (1)
        // = offset 12 is the root's element code.
        std.mem.writeInt(u16, mutated[12..14], 999, .little);
        try testing.expectError(error.DocumentDecode, nsui.decode(arena, mutated, &diagnostic));
        try testing.expectEqualStrings(nsui.unknown_code_message, diagnostic.message);
    }
    // Unresolved imports refuse to encode.
    {
        var parser = markup.Parser.init(arena, "<import src=\"parts.native\"/>\n<use template=\"chip\"/>");
        const unresolved = try parser.parse();
        try testing.expectError(error.DocumentEncode, nsui.encode(arena, unresolved, .{}, &diagnostic));
        try testing.expectEqualStrings(nsui.unresolved_imports_message, diagnostic.message);
    }
}

test "NSUI JSON dump derives from the decoded document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try parseSource(arena, "<row gap=\"4\"><text>{count}</text></row>");
    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);
    const decoded = try nsui.decode(arena, bytes, &diagnostic);
    const hash = try nsui.documentHash(arena, decoded);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try nsui.writeJson(decoded, hash, &out.writer);
    const json = out.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"schemaVersion\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"node\":\"row\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"code\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"gap\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"text\":\"{count}\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"documentHash\":") != null);
}

test "NSUI refuses hostile nesting depth" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Synthesize a document nested past the cap (parsing one would be
    // fine; the decoder must bound RECURSION on hostile bytes).
    var node = markup.MarkupNode{ .kind = .element, .name = "row" };
    for (0..nsui.max_decode_depth + 2) |_| {
        const children = try arena.alloc(markup.MarkupNode, 1);
        children[0] = node;
        node = .{ .kind = .element, .name = "row", .children = children };
    }
    const document = markup.MarkupDocument{ .root = node };
    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{ .spans = false, .provenance = false }, &diagnostic);
    try testing.expectError(error.DocumentDecode, nsui.decode(arena, bytes, &diagnostic));
    try testing.expectEqualStrings(nsui.depth_message, diagnostic.message);
}

test "the schema version constant is 1 and the registry backs the wire" {
    try testing.expectEqual(@as(u16, 1), schema.schema_version);
    // Every registry element/attr the encoder can meet has a nonzero code
    // (0 is the wire's "no entry" marker).
    for (schema.elements) |entry| try testing.expect(entry.code != 0);
    for (schema.attrs) |entry| try testing.expect(entry.code != 0);
}

test "NSUI round-trips context-menu composites through registry codes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\<column>
        \\  <list-item on-press="open:{row.id}" label="{row.title}">
        \\    <text>{row.title}</text>
        \\    <context-menu>
        \\      <menu-item on-press="copy:{row.id}">Copy</menu-item>
        \\      <separator />
        \\      <menu-item on-press="trash:{row.id}" disabled="{row.locked}">Delete</menu-item>
        \\    </context-menu>
        \\  </list-item>
        \\</column>
    ;
    const document = try parseSource(arena, source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));

    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);
    const decoded = try nsui.decode(arena, bytes, &diagnostic);
    try expectNodesEqual(document.root.?, decoded.root.?);

    // The context-menu element rides its fresh registry code; decoded
    // names are the registry's spellings.
    const row_node = decoded.root.?.children[0];
    const menu_node = row_node.children[1];
    try testing.expectEqualStrings("context-menu", menu_node.name);
    try testing.expectEqualStrings("menu-item", menu_node.children[0].name);

    // Determinism, and hash coverage: an item edit is structural.
    const again = try nsui.encode(arena, document, .{}, &diagnostic);
    try testing.expectEqualSlices(u8, bytes, again);
    const base_hash = try nsui.documentHash(arena, document);
    const edited_source =
        \\<column>
        \\  <list-item on-press="open:{row.id}" label="{row.title}">
        \\    <text>{row.title}</text>
        \\    <context-menu>
        \\      <menu-item on-press="copy:{row.id}">Duplicate</menu-item>
        \\      <separator />
        \\      <menu-item on-press="trash:{row.id}" disabled="{row.locked}">Delete</menu-item>
        \\    </context-menu>
        \\  </list-item>
        \\</column>
    ;
    const edited = try parseSource(arena, edited_source);
    try testing.expect(base_hash != try nsui.documentHash(arena, edited));
}

test "NSUI round-trips bubble reactions through registry codes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\<column>
        \\  <bubble variant="primary">
        \\    <text wrap="true">{message.body}</text>
        \\    <reactions text-alignment="start">{message.reactions} +1</reactions>
        \\  </bubble>
        \\</column>
    ;
    const document = try parseSource(arena, source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));

    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);
    const decoded = try nsui.decode(arena, bytes, &diagnostic);
    try expectNodesEqual(document.root.?, decoded.root.?);

    // The reactions element rides its fresh registry code (65) and its
    // dock rides the existing text-alignment code; decoded names are
    // the registry's spellings.
    const bubble_node = decoded.root.?.children[0];
    const pill_node = bubble_node.children[1];
    try testing.expectEqualStrings("reactions", pill_node.name);
    try testing.expectEqualStrings("start", pill_node.attr("text-alignment").?);

    // Determinism, and hash coverage: moving the dock is structural.
    const again = try nsui.encode(arena, document, .{}, &diagnostic);
    try testing.expectEqualSlices(u8, bytes, again);
    const base_hash = try nsui.documentHash(arena, document);
    const edited_source =
        \\<column>
        \\  <bubble variant="primary">
        \\    <text wrap="true">{message.body}</text>
        \\    <reactions>{message.reactions} +1</reactions>
        \\  </bubble>
        \\</column>
    ;
    const edited = try parseSource(arena, edited_source);
    try testing.expect(base_hash != try nsui.documentHash(arena, edited));
}

test "NSUI round-trips chart composites through registry codes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\<column>
        \\  <chart y-min="0" y-max="1" grid-lines="4" baseline="true" x-labels="{months}" y-labels="true" hover-details="true" stroke-width="2" label="CPU history">
        \\    <series kind="area" values="{cpu_history}" color="accent" label="cpu" />
        \\    <series kind="bar" values="{latency}" />
        \\  </chart>
        \\</column>
    ;
    const document = try parseSource(arena, source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));

    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);
    const decoded = try nsui.decode(arena, bytes, &diagnostic);
    try expectNodesEqual(document.root.?, decoded.root.?);

    // The chart element and its series attrs ride registry codes, so the
    // decoded names are the registry's spellings, not the source bytes.
    // The axis/hover attrs (fresh codes 73..75) ride along: x-labels
    // keeps its binding form, the flags keep their values.
    const chart_node = decoded.root.?.children[0];
    try testing.expectEqualStrings("chart", chart_node.name);
    try testing.expectEqualStrings("series", chart_node.children[0].name);
    try testing.expect(chart_node.children[0].attrEntry("values").?.typed.?.* == .binding);
    try testing.expect(chart_node.attrEntry("x-labels").?.typed.?.* == .binding);
    try testing.expectEqualStrings("true", chart_node.attr("y-labels").?);
    try testing.expectEqualStrings("true", chart_node.attr("hover-details").?);

    // Determinism, and hash coverage over the chart vocabulary: a series
    // attribute edit is a structural change.
    const again = try nsui.encode(arena, document, .{}, &diagnostic);
    try testing.expectEqualSlices(u8, bytes, again);
    const base_hash = try nsui.documentHash(arena, document);
    const edited_source =
        \\<column>
        \\  <chart y-min="0" y-max="1" grid-lines="4" baseline="true" stroke-width="2" label="CPU history">
        \\    <series kind="bar" values="{cpu_history}" color="accent" label="cpu" />
        \\    <series kind="bar" values="{latency}" />
        \\  </chart>
        \\</column>
    ;
    const edited = try parseSource(arena, edited_source);
    try testing.expect(base_hash != try nsui.documentHash(arena, edited));
}

test "NSUI round-trips span paragraphs under their fresh codes" {
    // Inline spans serialize like any element — fresh registry codes ride
    // the wire automatically, no schema bump — and the parser-spliced
    // single-space separators are ordinary text runs, so a spacing-
    // sensitive paragraph survives encode/decode node-for-node even in
    // the span-stripped hash form.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\<column gap="8">
        \\  <text>Disk <span weight="bold">{used}</span> of <span foreground="text_muted">{total}</span>; run <span mono="true">native doctor</span><span italic="true">!</span> <span scale="1.5">Alerts</span> <span underline="true">now</span></text>
        \\</column>
    ;
    const document = try parseSource(arena, source);
    try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(document));

    var diagnostic = nsui.CodecDiagnostic{};
    const bytes = try nsui.encode(arena, document, .{}, &diagnostic);
    const decoded = try nsui.decode(arena, bytes, &diagnostic);
    try expectNodesEqual(document.root.?, decoded.root.?);

    // The hash form (spans and provenance stripped) keeps the separator
    // runs too: spacing is structure, never a byte-gap artifact.
    const stripped = try nsui.encode(arena, document, .{ .spans = false, .provenance = false }, &diagnostic);
    const stripped_decoded = try nsui.decode(arena, stripped, &diagnostic);
    // [Disk][ ][span][ ][of][ ][span]["; run"][ ][span][span][ ][span]
    // [ ][span] — the abutting "; run" and "!" runs keep their glue, the
    // spaced runs (the scaled and underlined ones included) keep exactly
    // one separator each.
    const text_node = stripped_decoded.root.?.children[0];
    try testing.expectEqual(@as(usize, 15), text_node.children.len);
    try testing.expectEqualStrings(" ", text_node.children[3].text);
    try testing.expectEqualStrings("; run", text_node.children[7].text);
    try testing.expectEqualStrings("!", text_node.children[10].children[0].text);
    try testing.expectEqualStrings("Alerts", text_node.children[12].children[0].text);
    try testing.expectEqualStrings("now", text_node.children[14].children[0].text);

    // The wire carries the registry codes, never the names.
    try testing.expectEqual(@as(u16, 64), schema.elementByName("span").?.code);
    try testing.expectEqual(@as(u16, 68), schema.attrByName("weight").?.code);
    try testing.expectEqual(@as(u16, 69), schema.attrByName("mono").?.code);
    try testing.expectEqual(@as(u16, 70), schema.attrByName("italic").?.code);
    try testing.expectEqual(@as(u16, 76), schema.attrByName("scale").?.code);
    try testing.expectEqual(@as(u16, 77), schema.attrByName("underline").?.code);

    // The JSON inspection view (`native markup dump`) shows the spans:
    // element name, code, styled attributes, and the separator runs.
    const hash = try nsui.documentHash(arena, decoded);
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try nsui.writeJson(decoded, hash, &out.writer);
    const json = out.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"node\":\"span\",\"code\":64") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"weight\",\"code\":68,\"value\":\"bold\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"mono\",\"code\":69,\"value\":\"true\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"scale\",\"code\":76,\"value\":\"1.5\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"underline\",\"code\":77,\"value\":\"true\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"text\":\"{used}\"") != null);
}
