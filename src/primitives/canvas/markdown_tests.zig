const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const markdown = @import("markdown.zig");
const text_spans = @import("text_spans.zig");
const support = @import("test_support.zig");

const testing = std.testing;

const markdown_document_fixture = @embedFile("testdata/markdown_document.md");

const Msg = union(enum) {
    open_url: []const u8,
    toggle_details: usize,
    noop,
};

const Md = markdown.Markdown(Msg);
const Ui = Md.Ui;

const TestDoc = struct {
    arena_state: std.heap.ArenaAllocator,
    ui: Ui,
    tree: Ui.Tree = undefined,

    fn init() TestDoc {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .ui = undefined,
        };
    }

    fn build(self: *TestDoc, source: []const u8, options: Md.Options) !Ui.Tree {
        self.ui = Ui.init(self.arena_state.allocator());
        const node = Md.view(&self.ui, source, options);
        self.tree = try self.ui.finalize(node);
        return self.tree;
    }

    fn deinit(self: *TestDoc) void {
        self.arena_state.deinit();
    }
};

fn countKind(widget: canvas.Widget, kind: canvas.WidgetKind) usize {
    var count: usize = if (widget.kind == kind) 1 else 0;
    for (widget.children) |child| count += countKind(child, kind);
    return count;
}

fn findParagraphContaining(widget: canvas.Widget, fragment: []const u8) ?canvas.Widget {
    if (widget.kind == .text and widget.spans.len > 0 and std.mem.indexOf(u8, widget.text, fragment) != null) return widget;
    for (widget.children) |child| {
        if (findParagraphContaining(child, fragment)) |found| return found;
    }
    return null;
}

fn findRoleLabel(widget: canvas.Widget, role: canvas.WidgetRole, label: []const u8) ?canvas.Widget {
    if (widget.semantics.role == role and std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findRoleLabel(child, role, label)) |found| return found;
    }
    return null;
}

fn findKindLabel(widget: canvas.Widget, kind: canvas.WidgetKind, label: []const u8) ?canvas.Widget {
    if (widget.kind == kind and (std.mem.eql(u8, widget.semantics.label, label) or std.mem.eql(u8, widget.text, label))) return widget;
    for (widget.children) |child| {
        if (findKindLabel(child, kind, label)) |found| return found;
    }
    return null;
}

test "markdown maps headings, paragraphs, and inline styles onto spans" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\# Title
        \\
        \\Plain **bold** and *italic* with `code`, ~~gone~~, and [a link](https://example.com).
    , .{ .on_link = Ui.linkMsg(.open_url) });

    const heading = findParagraphContaining(tree.root, "Title").?;
    try testing.expectEqual(@as(usize, 1), heading.spans.len);
    try testing.expectEqual(canvas.TextSpanWeight.bold, heading.spans[0].weight);
    try testing.expectEqual(markdown.heading_scales[0], heading.spans[0].scale);

    const paragraph = findParagraphContaining(tree.root, "Plain").?;
    try testing.expectEqualStrings("Plain bold and italic with code, gone, and a link.", paragraph.text);

    const spans = paragraph.spans;
    try testing.expectEqual(canvas.TextSpanWeight.bold, spans[1].weight);
    try testing.expectEqualStrings("bold", spans[1].text);
    try testing.expect(spans[3].italic);
    try testing.expectEqualStrings("italic", spans[3].text);
    try testing.expect(spans[5].monospace);
    try testing.expectEqualStrings("code", spans[5].text);
    try testing.expect(spans[7].strikethrough);
    try testing.expectEqualStrings("gone", spans[7].text);
    try testing.expectEqualStrings("a link", spans[9].text);
    try testing.expectEqualStrings("https://example.com", spans[9].link);

    // The link span grew a hit-area child that dispatches on_link's Msg.
    const link_child = paragraph.children[0];
    try testing.expectEqual(canvas.WidgetRole.link, link_child.semantics.role);
    const msg = tree.msgForPointer(link_child.id, .up).?;
    try testing.expectEqualStrings("https://example.com", msg.open_url);
}

test "markdown maps lists, task lists, code fences, quotes, and rules" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\- first
        \\- second
        \\  - nested
        \\
        \\1. one
        \\2. two
        \\
        \\- [ ] todo item
        \\- [x] done item
        \\
        \\> quoted wisdom
        \\
        \\---
        \\
        \\```zig
        \\const x = 1;
        \\```
    , .{});

    // Two task checkboxes, disabled (display-only), checked state mapped.
    try testing.expectEqual(@as(usize, 2), countKind(tree.root, .checkbox));
    const todo = findKindLabel(tree.root, .checkbox, "todo item").?;
    try testing.expect(todo.state.disabled);
    try testing.expect(!todo.state.selected);
    const done = findKindLabel(tree.root, .checkbox, "done item").?;
    try testing.expect(done.state.selected);

    // Bullets, ordered markers, nested item, quote bar + rule separators.
    try testing.expect(findParagraphContaining(tree.root, "nested") != null);
    try testing.expect(findParagraphContaining(tree.root, "one") != null);
    try testing.expect(findParagraphContaining(tree.root, "quoted wisdom") != null);
    try testing.expectEqual(@as(usize, 2), countKind(tree.root, .separator));

    // The fenced block is a panel wrapping a mono paragraph.
    try testing.expectEqual(@as(usize, 1), countKind(tree.root, .panel));
    const code = findParagraphContaining(tree.root, "const x = 1;").?;
    try testing.expect(code.spans[0].monospace);
}

test "details blocks are caller-controlled collapsibles" {
    const source =
        \\<details>
        \\<summary>More info</summary>
        \\
        \\Hidden paragraph.
        \\
        \\</details>
        \\
        \\After.
    ;

    var collapsed = TestDoc.init();
    defer collapsed.deinit();
    const collapsed_tree = try collapsed.build(source, .{ .on_details = Md.detailsMsg(.toggle_details) });
    try testing.expect(findParagraphContaining(collapsed_tree.root, "Hidden paragraph") == null);
    try testing.expect(findParagraphContaining(collapsed_tree.root, "After") != null);
    const header = findKindLabel(collapsed_tree.root, .list_item, "▸ More info").?;
    try testing.expectEqual(@as(?bool, false), header.state.expanded);
    const msg = collapsed_tree.msgForPointer(header.id, .up).?;
    try testing.expectEqual(@as(usize, 0), msg.toggle_details);

    var expanded = TestDoc.init();
    defer expanded.deinit();
    const expanded_tree = try expanded.build(source, .{
        .on_details = Md.detailsMsg(.toggle_details),
        .details_expanded = &.{true},
    });
    try testing.expect(findParagraphContaining(expanded_tree.root, "Hidden paragraph") != null);
    const open_header = findKindLabel(expanded_tree.root, .list_item, "▾ More info").?;
    try testing.expectEqual(@as(?bool, true), open_header.state.expanded);
}

test "malformed markdown degrades to literal text and never fails" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\**unclosed bold and `unclosed code and [broken](link
        \\
        \\```
        \\fence with no close
    , .{});

    const literal = findParagraphContaining(tree.root, "unclosed bold").?;
    // Everything stayed literal: no bold weight, delimiters preserved.
    try testing.expect(std.mem.indexOf(u8, literal.text, "**unclosed bold") != null);
    try testing.expect(std.mem.indexOf(u8, literal.text, "[broken](link") != null);
    for (literal.spans) |span| try testing.expectEqual(canvas.TextSpanWeight.regular, span.weight);

    const code = findParagraphContaining(tree.root, "fence with no close").?;
    try testing.expect(code.spans[0].monospace);
}

test "empty and pathological inputs build empty-but-valid trees" {
    var doc = TestDoc.init();
    defer doc.deinit();
    _ = try doc.build("", .{});

    var doc2 = TestDoc.init();
    defer doc2.deinit();
    _ = try doc2.build("\n\n\n</details>\n<summary>stray</summary>\n", .{});
}

fn findCellContaining(widget: canvas.Widget, fragment: []const u8) ?canvas.Widget {
    if (widget.kind == .data_cell and std.mem.indexOf(u8, widget.text, fragment) != null) return widget;
    for (widget.children) |child| {
        if (findCellContaining(child, fragment)) |found| return found;
    }
    return null;
}

test "pipe tables map onto table/data_row/data_cell with alignment and header styling" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\| Variable | Default | Notes |
        \\| :--- | :---: | ---: |
        \\| `PORT` | 3000 | **required** in prod |
        \\| `LOG_LEVEL` | info | see [docs](https://example.com/logs) |
    , .{ .on_link = Ui.linkMsg(.open_url) });

    try testing.expectEqual(@as(usize, 1), countKind(tree.root, .table));
    try testing.expectEqual(@as(usize, 3), countKind(tree.root, .data_row));
    try testing.expectEqual(@as(usize, 9), countKind(tree.root, .data_cell));

    // Header cells are bold with delimiter-driven alignment.
    const header_cell = findCellContaining(tree.root, "Variable").?;
    try testing.expectEqual(canvas.TextSpanWeight.bold, header_cell.spans[0].weight);
    try testing.expectEqual(canvas.TextAlign.start, header_cell.text_alignment);
    const centered = findCellContaining(tree.root, "Default").?;
    try testing.expectEqual(canvas.TextAlign.center, centered.text_alignment);
    const trailing = findCellContaining(tree.root, "Notes").?;
    try testing.expectEqual(canvas.TextAlign.end, trailing.text_alignment);

    // Body cells run the inline grammar: code, bold, and live links.
    const port = findCellContaining(tree.root, "PORT").?;
    try testing.expect(port.spans[0].monospace);
    try testing.expectEqual(canvas.TextSpanWeight.regular, port.spans[0].weight);
    const required = findCellContaining(tree.root, "required").?;
    try testing.expectEqual(canvas.TextSpanWeight.bold, required.spans[0].weight);
    const link_cell = findCellContaining(tree.root, "docs").?;
    const hotspot = link_cell.children[0];
    try testing.expectEqual(canvas.WidgetRole.link, hotspot.semantics.role);
    const msg = tree.msgForPointer(hotspot.id, .up).?;
    try testing.expectEqualStrings("https://example.com/logs", msg.open_url);
}

test "table rows pad short rows, drop extra cells, and stop at blank or pipeless lines" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\| A | B |
        \\| --- | --- |
        \\| one |
        \\| one | two | three |
        \\
        \\After the table.
    , .{});

    try testing.expectEqual(@as(usize, 1), countKind(tree.root, .table));
    try testing.expectEqual(@as(usize, 3), countKind(tree.root, .data_row));
    // Every row has exactly the header's column count.
    try testing.expectEqual(@as(usize, 6), countKind(tree.root, .data_cell));
    try testing.expect(findCellContaining(tree.root, "three") == null);
    const after = findParagraphContaining(tree.root, "After the table.").?;
    try testing.expectEqual(canvas.WidgetKind.text, after.kind);
}

test "tables interrupt paragraphs and escape pipes inside cells" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\Leading prose
        \\| Cmd | Effect |
        \\| --- | --- |
        \\| `a \| b` | pipe stays |
    , .{});

    try testing.expect(findParagraphContaining(tree.root, "Leading prose") != null);
    try testing.expect(findParagraphContaining(tree.root, "Cmd") == null);
    try testing.expectEqual(@as(usize, 1), countKind(tree.root, .table));
    const escaped = findCellContaining(tree.root, "a | b").?;
    try testing.expect(escaped.spans[0].monospace);
}

test "malformed pipe blocks degrade to plain paragraphs" {
    var doc = TestDoc.init();
    defer doc.deinit();

    // No delimiter row.
    const tree = try doc.build(
        \\| a | b |
        \\| c | d |
    , .{});
    try testing.expectEqual(@as(usize, 0), countKind(tree.root, .table));
    try testing.expect(findParagraphContaining(tree.root, "| a | b |") != null);

    // Column-count mismatch between header and delimiter row.
    var doc2 = TestDoc.init();
    defer doc2.deinit();
    const tree2 = try doc2.build(
        \\| a | b | c |
        \\| --- | --- |
    , .{});
    try testing.expectEqual(@as(usize, 0), countKind(tree2.root, .table));

    // Wider than max_markdown_table_columns degrades rather than dropping columns.
    var doc3 = TestDoc.init();
    defer doc3.deinit();
    const tree3 = try doc3.build(
        \\| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
        \\| - | - | - | - | - | - | - | - | - |
    , .{});
    try testing.expectEqual(@as(usize, 0), countKind(tree3.root, .table));
}

test "the README-shaped fixture renders through the mapper and the reference renderer" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(markdown_document_fixture, .{ .on_link = Ui.linkMsg(.open_url) });

    // Structure spot checks against the fixture document.
    const title = findParagraphContaining(tree.root, "Fieldnote").?;
    try testing.expectEqual(markdown.heading_scales[0], title.spans[0].scale);
    try testing.expect(findParagraphContaining(tree.root, "Left pane") != null);
    const cli_link = findRoleLabel(tree.root, .link, "`flg`").?;
    const open_msg = tree.msgForPointer(cli_link.id, .up).?;
    try testing.expectEqualStrings("https://example.com/flg", open_msg.open_url);
    try testing.expect(countKind(tree.root, .panel) >= 2); // fenced code blocks

    // Layout + emit + reference-render the document; the pixel signature is
    // the golden. Estimator-driven and provider-free: deterministic.
    const canvas_width: f32 = 760;
    const canvas_height: f32 = 2400;
    var nodes: [512]canvas.WidgetLayoutNode = undefined;
    const tokens = canvas.DesignTokens{};
    const tree_layout = try canvas.layoutWidgetTreeWithTokens(
        tree.root,
        geometry.RectF.init(20, 20, canvas_width - 40, canvas_height - 40),
        tokens,
        &nodes,
    );

    var commands: [1024]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetLayout(&builder, tree_layout, tokens);
    const list = builder.displayList();
    try testing.expect(list.commands.len > 100);

    var render_commands: [1024]canvas.RenderCommand = undefined;
    var render_batches: [1024]canvas.RenderBatch = undefined;
    var resources: [1024]canvas.RenderResource = undefined;
    var resource_cache_entries: [1024]canvas.RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2048]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [4096]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [4096]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [8192]canvas.GlyphAtlasCacheAction = undefined;
    var changes: [2049]canvas.DiffChange = undefined;
    const frame = try (canvas.DisplayList{ .commands = list.commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(canvas_width, canvas_height),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .changes = &changes,
    });

    const width: usize = @intFromFloat(canvas_width);
    const height: usize = @intFromFloat(canvas_height);
    const pixels = try testing.allocator.alloc(u8, width * height * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0);
    const surface = try canvas.ReferenceRenderSurface.init(width, height, pixels);
    try surface.renderPass(frame.renderPass(), canvas.Color.rgb8(255, 255, 255));

    // Golden: byte-identical reference rendering of the README fixture.
    try testing.expectEqual(markdown_document_reference_signature, support.referenceSurfaceSignature(pixels));
    try support.expectVisiblePixel(surface.pixelRgba8(24, 32));
}

// Reference-renderer pixel signature of the README-shaped fixture at
// 760x2400 with default tokens and the deterministic bundled-face
// metrics. It pins the whole document register in one number: heading
// scales, wrapped bullets and em-dash spacing at the face's real
// advances, real sans and mono outlines (fixed-pitch runs sit in their
// 0.6 em cells), GFM tables as borderless cells on hairline row
// separators, fenced-code panels, and near-black underlined links.
// Update deliberately when markdown rendering changes, reviewing the
// rendered pixels first (see reference_tests.zig conventions).
const markdown_document_reference_signature: u64 = 6015448079037287912;


test "bare URLs autolink at word boundaries with trailing punctuation trimmed" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\See https://example.com/path(1). Also (https://foo.dev/a?b=1), or http://bar.io!
        \\
        \\But nothttps://nope.com stays literal, as does a bare https:// scheme.
    , .{ .on_link = Ui.linkMsg(.open_url) });

    const paragraph = findParagraphContaining(tree.root, "See").?;
    var links: usize = 0;
    for (paragraph.spans) |span| {
        if (span.link.len == 0) continue;
        links += 1;
        switch (links) {
            // The trailing period is trimmed; the balanced paren is kept.
            1 => try testing.expectEqualStrings("https://example.com/path(1)", span.link),
            // The unbalanced close paren and comma are trimmed.
            2 => try testing.expectEqualStrings("https://foo.dev/a?b=1", span.link),
            3 => try testing.expectEqualStrings("http://bar.io", span.link),
            else => {},
        }
        try testing.expectEqualStrings(span.link, span.text);
    }
    try testing.expectEqual(@as(usize, 3), links);

    // No word-boundary, or no target after the scheme: literal text.
    const literal = findParagraphContaining(tree.root, "nope").?;
    for (literal.spans) |span| {
        try testing.expectEqual(@as(usize, 0), span.link.len);
    }

    // Autolinked URLs are pressable through the ordinary link machinery.
    const link_child = paragraph.children[0];
    const msg = tree.msgForPointer(link_child.id, .up).?;
    try testing.expectEqualStrings("https://example.com/path(1)", msg.open_url);
}

test "issue refs linkify only with an issue link base, at word boundaries" {
    var doc = TestDoc.init();
    defer doc.deinit();

    // Without the option, refs stay plain text (no repo context).
    {
        const tree = try doc.build("Fixes #123 for real", .{});
        const paragraph = findParagraphContaining(tree.root, "Fixes").?;
        for (paragraph.spans) |span| {
            try testing.expectEqual(@as(usize, 0), span.link.len);
        }
    }
    doc.deinit();
    doc = TestDoc.init();

    const tree = try doc.build(
        \\Fixes #123 and (#45), but not path/#6, not &#39;, not #12abc, and not word#7.
    , .{
        .on_link = Ui.linkMsg(.open_url),
        .issue_link_base = "ghissue://",
    });
    const paragraph = findParagraphContaining(tree.root, "Fixes").?;
    var links: usize = 0;
    for (paragraph.spans) |span| {
        if (span.link.len == 0) continue;
        links += 1;
        switch (links) {
            1 => {
                try testing.expectEqualStrings("#123", span.text);
                try testing.expectEqualStrings("ghissue://123", span.link);
            },
            2 => {
                try testing.expectEqualStrings("#45", span.text);
                try testing.expectEqualStrings("ghissue://45", span.link);
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2), links);

    // The ref press dispatches the composed target through on_link.
    const link_child = paragraph.children[0];
    const msg = tree.msgForPointer(link_child.id, .up).?;
    try testing.expectEqualStrings("ghissue://123", msg.open_url);
}

test "real GitHub symbol codepoints keep their bytes and charge the cascade-class advance" {
    var doc = TestDoc.init();
    defer doc.deinit();

    // Real GitHub-flavored content: ballot-box
    // symbols in a table's status column next to mono cells and an
    // em-dash. The markdown engine deliberately does NOT rewrite the
    // characters (bytes stay byte-identical for selection/copy fidelity;
    // live macOS rendering covers them through CoreText's cascade, pinned
    // in text_metrics_tests) — the engine's job is an honest measured
    // cell for them.
    const tree = try doc.build(
        \\| Status | API group | Effort |
        \\| --- | --- | --- |
        \\| ☐ | `experimental_createProviderRegistry` | — |
        \\| ☑ | `experimental_wrapLanguageModel` | — |
        \\
    , .{});

    const open_cell = findCellContaining(tree.root, "☐").?;
    try testing.expectEqualStrings("☐", std.mem.trim(u8, open_cell.text, " "));

    // The estimator charges the ballot box the 0.8 em symbol class (the
    // AppleSymbols cascade advance live text falls back to), not the
    // 0.6 em .notdef advance, so headless layout reserves the same cell
    // class the live host inks.
    const spans = open_cell.spans;
    try testing.expect(spans.len >= 1);
    const width = canvas.text_spans.textSpansIntrinsicWidth(spans, .{ .size = 10 });
    try testing.expectApproxEqAbs(@as(f32, 8), width, 0.01);

    // Mono cells stay intact single spans (the packet host draws the run
    // as one string with the real mono face; the reference renderer
    // centers each glyph in its fixed 0.6 em cell).
    const mono_cell = findCellContaining(tree.root, "experimental_createProviderRegistry").?;
    var mono_spans: usize = 0;
    for (mono_cell.spans) |span| {
        if (span.monospace) {
            mono_spans += 1;
            try testing.expectEqualStrings("experimental_createProviderRegistry", span.text);
        }
    }
    try testing.expectEqual(@as(usize, 1), mono_spans);
}
