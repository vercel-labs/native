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

fn findKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findKind(child, kind)) |found| return found;
    }
    return null;
}

fn findImageId(widget: canvas.Widget, image_id: canvas.ImageId) ?canvas.Widget {
    if (widget.kind == .image and widget.image_id == image_id) return widget;
    for (widget.children) |child| {
        if (findImageId(child, image_id)) |found| return found;
    }
    return null;
}

fn findCellContainingImage(widget: canvas.Widget, image_id: canvas.ImageId) ?canvas.Widget {
    if (widget.kind == .data_cell and findImageId(widget, image_id) != null) return widget;
    for (widget.children) |child| {
        if (findCellContainingImage(child, image_id)) |found| return found;
    }
    return null;
}

fn appendParagraphText(widget: canvas.Widget, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (widget.kind == .text and widget.spans.len > 0) {
        try out.appendSlice(allocator, widget.text);
        return;
    }
    for (widget.children) |child| try appendParagraphText(child, out, allocator);
}

fn hasSpan(widget: canvas.Widget, text: []const u8, color: ?canvas.TextSpanColor) bool {
    for (widget.spans) |span| {
        if (std.mem.eql(u8, span.text, text) and span.color == color) return true;
    }
    for (widget.children) |child| {
        if (hasSpan(child, text, color)) return true;
    }
    return false;
}

fn findSpan(widget: canvas.Widget, text: []const u8) ?canvas.TextSpan {
    for (widget.spans) |span| {
        if (std.mem.eql(u8, span.text, text)) return span;
    }
    for (widget.children) |child| {
        if (findSpan(child, text)) |span| return span;
    }
    return null;
}

fn allSpansMonospace(widget: canvas.Widget) bool {
    for (widget.spans) |span| {
        if (!span.monospace) return false;
    }
    for (widget.children) |child| {
        if (!allSpansMonospace(child)) return false;
    }
    return true;
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

fn countKindLabel(widget: canvas.Widget, kind: canvas.WidgetKind, label: []const u8) usize {
    var count: usize = if (widget.kind == kind and
        (std.mem.eql(u8, widget.semantics.label, label) or std.mem.eql(u8, widget.text, label))) 1 else 0;
    for (widget.children) |child| count += countKindLabel(child, kind, label);
    return count;
}

fn countRole(widget: canvas.Widget, role: canvas.WidgetRole) usize {
    var count: usize = if (widget.semantics.role == role) 1 else 0;
    for (widget.children) |child| count += countRole(child, role);
    return count;
}

fn findRowWithDirectParagraph(widget: canvas.Widget, fragment: []const u8) ?canvas.Widget {
    if (widget.kind == .row) {
        for (widget.children) |child| {
            if (child.kind == .text and child.spans.len > 0 and std.mem.indexOf(u8, child.text, fragment) != null) return widget;
        }
    }
    for (widget.children) |child| {
        if (findRowWithDirectParagraph(child, fragment)) |found| return found;
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
    try testing.expect(spans[9].underline);

    // The link span grew a hit-area child that dispatches on_link's Msg.
    const link_child = paragraph.children[0];
    try testing.expectEqual(canvas.WidgetRole.link, link_child.semantics.role);
    const msg = tree.msgForPointer(link_child.id, .up).?;
    try testing.expectEqualStrings("https://example.com", msg.open_url);
}

test "safe GitHub-style inline HTML maps onto native spans" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\Plain <strong>bold <em>and italic</em></strong>, <code>code</code>, <del>gone</del>, <ins>new</ins>, <mark>marked</mark>, and <small>small</small>.
        \\<A HREF=https://example.com/a/b>a link</A>.<BR />Next <IMG src="ignored.png" onerror="boom()" alt='diagram'> &amp; &#x2713;.
    , .{ .on_link = Ui.linkMsg(.open_url) });

    const paragraph = findParagraphContaining(tree.root, "Plain").?;
    try testing.expectEqualStrings(
        "Plain bold and italic, code, gone, new, marked, and small. a link.\nNext diagram & ✓.",
        paragraph.text,
    );

    try testing.expectEqual(canvas.TextSpanWeight.bold, findSpan(paragraph, "bold ").?.weight);
    const nested = findSpan(paragraph, "and italic").?;
    try testing.expectEqual(canvas.TextSpanWeight.bold, nested.weight);
    try testing.expect(nested.italic);
    try testing.expect(findSpan(paragraph, "code").?.monospace);
    try testing.expect(findSpan(paragraph, "gone").?.strikethrough);
    try testing.expect(findSpan(paragraph, "new").?.underline);
    try testing.expectEqual(canvas.TextSpanColor.surface_pressed, findSpan(paragraph, "marked").?.background.?);
    try testing.expectEqual(@as(f32, 0.875), findSpan(paragraph, "small").?.scale);

    const link = findSpan(paragraph, "a link").?;
    try testing.expectEqualStrings("https://example.com/a/b", link.link);
    const link_widget = findRoleLabel(tree.root, .link, "a link").?;
    const msg = tree.msgForPointer(link_widget.id, .up).?;
    try testing.expectEqualStrings("https://example.com/a/b", msg.open_url);
}

test "safe HTML decodes entities in link and image attributes" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<a href="https://example.com/search?a=1&amp;b=2">query</a> <img alt="A &amp; B">.
    , .{ .on_link = Ui.linkMsg(.open_url) });

    const paragraph = findParagraphContaining(tree.root, "query").?;
    try testing.expectEqualStrings("query A & B.", paragraph.text);
    const link = findSpan(paragraph, "query").?;
    try testing.expectEqualStrings("https://example.com/search?a=1&b=2", link.link);
    const link_widget = findRoleLabel(tree.root, .link, "query").?;
    const msg = tree.msgForPointer(link_widget.id, .up).?;
    try testing.expectEqualStrings("https://example.com/search?a=1&b=2", msg.open_url);
}

test "empty HTML anchors do not create accessibility links" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\Before<a href="https://empty.example"><sup><img alt="" /></sup></a>After.
        \\<a href="https://diagram.example"><img alt="diagram" /></a>
    , .{ .on_link = Ui.linkMsg(.open_url) });

    try testing.expectEqual(@as(usize, 1), countRole(tree.root, .link));
    try testing.expect(findRoleLabel(tree.root, .link, "") == null);
    const diagram = findRoleLabel(tree.root, .link, "diagram").?;
    try testing.expectEqualStrings("https://diagram.example", tree.msgForPointer(diagram.id, .up).?.open_url);
}

test "link reference definitions stay hidden without resolving references" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\[vc]: #hash:payload
        \\   [docs]: <https://example.com/a b> "A title"
        \\The update leaves [vc] and [docs][] literal.
        \\
        \\Paragraph text
        \\[not-interrupting]: /url
        \\
        \\[broken]:
        \\[junk]: /url trailing words
        \\[joined-title]: <https://example.com>"title"
        \\    [too-indented]: /url
    , .{});

    try testing.expect(findParagraphContaining(tree.root, "#hash:payload") == null);
    try testing.expect(findParagraphContaining(tree.root, "A title") == null);
    try testing.expectEqualStrings(
        "The update leaves [vc] and [docs][] literal.",
        findParagraphContaining(tree.root, "The update").?.text,
    );
    try testing.expectEqualStrings(
        "Paragraph text [not-interrupting]: /url",
        findParagraphContaining(tree.root, "Paragraph text").?.text,
    );
    try testing.expect(findParagraphContaining(tree.root, "[broken]:") != null);
    try testing.expect(findParagraphContaining(tree.root, "[junk]: /url trailing words") != null);
    try testing.expect(findParagraphContaining(tree.root, "[joined-title]") != null);
    try testing.expect(findParagraphContaining(tree.root, "[too-indented]: /url") != null);
}

test "Vercel deployment comments hide metadata and retain table links" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\[vc]: #H4enDGKDtR2Lb2lsv4EbfoqtEIHUz0WJNjyO4zsNHm8=:eyJpc01vbm9yZXBvIjp0cnVlLCJ0eXBlIjoiZ2l0aHViIn0=
        \\The latest updates on your projects. Learn more about [Vercel for GitHub](https://vercel.link/github-learn-more).
        \\
        \\| Project | Deployment | Actions | Updated (UTC) |
        \\| :--- | :----- | :------ | :------ |
        \\| <a href="https://vercel.com/vercel-labs/native-sdk"><sup><img src="avatar" width="16" height="16" alt="" /></sup></a> [native-sdk](https://vercel.com/vercel-labs/native-sdk) | ![Ready](ready.svg) [Ready](https://vercel.com/deployment) | [Preview](https://preview.example) | Aug 4, 2026 8:14pm |
    , .{ .on_link = Ui.linkMsg(.open_url) });

    try testing.expect(findParagraphContaining(tree.root, "[vc]") == null);
    try testing.expectEqualStrings(
        "The latest updates on your projects. Learn more about Vercel for GitHub.",
        findParagraphContaining(tree.root, "The latest updates").?.text,
    );
    try testing.expectEqual(@as(usize, 1), countKind(tree.root, .table));
    try testing.expectEqual(@as(usize, 4), countRole(tree.root, .link));
    try testing.expect(findRoleLabel(tree.root, .link, "") == null);
    try testing.expect(findRoleLabel(tree.root, .link, "Vercel for GitHub") != null);
    try testing.expect(findRoleLabel(tree.root, .link, "native-sdk") != null);
    try testing.expect(findRoleLabel(tree.root, .link, "Ready") != null);
    try testing.expect(findRoleLabel(tree.root, .link, "Preview") != null);
}

test "GitHub-style HTML blocks lower onto native document structure" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<div align="center">
        \\<h2>Centered <em>heading</em></h2>
        \\<p>Copy <strong>here</strong>.</p>
        \\</div>
        \\<h3>
        \\Multiline heading
        \\</h3>
        \\
        \\<blockquote>Quoted <code>value</code>.</blockquote>
        \\<blockquote>
        \\Nested <strong>quote</strong>.
        \\</blockquote>
        \\<hr class="ignored">
        \\<ul>
        \\<li>First</li>
        \\<li>Second <b>bold</b></li>
        \\</ul>
        \\<pre>
        \\<code>
        \\const answer = 42;
        \\</code>
        \\</pre>
    , .{});

    const heading = findParagraphContaining(tree.root, "Centered heading").?;
    try testing.expectEqual(canvas.TextAlign.center, heading.text_alignment);
    try testing.expectEqual(markdown.heading_scales[1], findSpan(heading, "Centered ").?.scale);
    const heading_emphasis = findSpan(heading, "heading").?;
    try testing.expectEqual(canvas.TextSpanWeight.bold, heading_emphasis.weight);
    try testing.expect(heading_emphasis.italic);

    const centered_copy = findParagraphContaining(tree.root, "Copy here.").?;
    try testing.expectEqual(canvas.TextAlign.center, centered_copy.text_alignment);
    try testing.expectEqual(canvas.TextSpanWeight.bold, findSpan(centered_copy, "here").?.weight);

    const multiline_heading = findParagraphContaining(tree.root, "Multiline heading").?;
    try testing.expectEqual(canvas.TextSpanWeight.bold, multiline_heading.spans[0].weight);
    try testing.expectEqual(markdown.heading_scales[2], multiline_heading.spans[0].scale);

    const quote = findParagraphContaining(tree.root, "Quoted value.").?;
    try testing.expectEqual(canvas.TextAlign.start, quote.text_alignment);
    try testing.expect(findSpan(quote, "value").?.monospace);
    try testing.expectEqual(canvas.TextSpanWeight.bold, findSpan(tree.root, "quote").?.weight);
    try testing.expectEqual(@as(usize, 3), countKind(tree.root, .separator));
    try testing.expect(findRowWithDirectParagraph(tree.root, "First") != null);
    try testing.expect(findRowWithDirectParagraph(tree.root, "Second bold") != null);
    const preformatted = findParagraphContaining(tree.root, "const answer = 42;").?;
    try testing.expect(allSpansMonospace(preformatted));
}

test "HTML block closers may follow content without absorbing later blocks" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<div align="center">
        \\Centered</div>
        \\
        \\Outside
        \\<blockquote>
        \\Quoted</blockquote>After quote
        \\<pre>
        \\<code>&lt;tag&gt; &amp; &#x2713;</code></pre>After pre
    , .{});

    try testing.expectEqual(@as(usize, 6), tree.root.children.len);
    try testing.expectEqual(canvas.TextAlign.center, tree.root.children[0].text_alignment);
    try testing.expectEqualStrings("Outside", tree.root.children[1].text);
    try testing.expectEqual(canvas.TextAlign.start, tree.root.children[1].text_alignment);
    try testing.expect(findParagraphContaining(tree.root.children[2], "Quoted") != null);
    try testing.expectEqualStrings("After quote", tree.root.children[3].text);
    try testing.expect(findParagraphContaining(tree.root.children[4], "<tag> & ✓") != null);
    try testing.expectEqualStrings("After pre", tree.root.children[5].text);
}

test "multiline HTML blocks keep semantics when content follows the opener" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<blockquote>First line
        \\Second line</blockquote>After quote
        \\<pre><code>first
        \\second</code></pre>After pre
    , .{});

    try testing.expectEqual(@as(usize, 4), tree.root.children.len);
    try testing.expectEqual(@as(usize, 1), countKind(tree.root.children[0], .separator));
    try testing.expect(findParagraphContaining(tree.root.children[0], "First line Second line") != null);
    try testing.expectEqualStrings("After quote", tree.root.children[1].text);
    const code = findParagraphContaining(tree.root.children[2], "first\nsecond").?;
    try testing.expect(allSpansMonospace(code));
    try testing.expectEqualStrings("After pre", tree.root.children[3].text);
}

test "multiline HTML list items retain their native marker" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<ul>
        \\<li>
        \\First <strong>bold</strong>
        \\</li>
        \\</ul>
    , .{});

    const item = findRowWithDirectParagraph(tree.root, "First bold").?;
    try testing.expect(findKindLabel(item, .text, "•") != null);
    try testing.expectEqual(canvas.TextSpanWeight.bold, findSpan(item, "bold").?.weight);
}

test "multiline HTML headings honor align" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<h2 align="center">
        \\Heading
        \\</h2>
        \\Outside
    , .{});

    const heading = findParagraphContaining(tree.root, "Heading").?;
    const outside = findParagraphContaining(tree.root, "Outside").?;
    try testing.expectEqual(canvas.TextAlign.center, heading.text_alignment);
    try testing.expectEqual(markdown.heading_scales[1], heading.spans[0].scale);
    try testing.expectEqual(canvas.TextAlign.start, outside.text_alignment);
}

test "HTML blockquotes contain malformed child presentation scopes" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<blockquote>
        \\<div align="center">
        \\Inside
        \\</blockquote>
        \\Outside
    , .{});

    const inside = findParagraphContaining(tree.root.children[0], "Inside").?;
    const outside = findParagraphContaining(tree.root.children[1], "Outside").?;
    try testing.expectEqual(canvas.TextAlign.center, inside.text_alignment);
    try testing.expectEqual(canvas.TextAlign.start, outside.text_alignment);
}

test "self-closing HTML wrappers do not leak block presentation" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<div align="center" />
        \\Plain
        \\<h1 />
        \\Still plain
    , .{});

    const plain = findParagraphContaining(tree.root, "Plain").?;
    const still_plain = findParagraphContaining(tree.root, "Still plain").?;
    try testing.expectEqual(canvas.TextAlign.start, plain.text_alignment);
    try testing.expectEqual(canvas.TextAlign.start, still_plain.text_alignment);
    try testing.expectEqual(canvas.TextSpanWeight.regular, plain.spans[0].weight);
    try testing.expectEqual(canvas.TextSpanWeight.regular, still_plain.spans[0].weight);
    try testing.expectEqual(@as(f32, 0), plain.spans[0].scale);
    try testing.expectEqual(@as(f32, 0), still_plain.spans[0].scale);
}

test "HTML comments hide content while unsupported and malformed tags stay literal" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\Visible <!-- hidden **secret** --> text. <script><strong>alert</strong>&amp;</script> <span onclick="boom()">safe</span>.
        \\
        \\Malformed <strong never closes.
    , .{});

    const visible = findParagraphContaining(tree.root, "Visible").?;
    try testing.expect(std.mem.indexOf(u8, visible.text, "hidden") == null);
    try testing.expect(std.mem.indexOf(u8, visible.text, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, visible.text, "<script><strong>alert</strong>&amp;</script>") != null);
    try testing.expect(std.mem.indexOf(u8, visible.text, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, visible.text, "safe") != null);

    const malformed = findParagraphContaining(tree.root, "Malformed").?;
    try testing.expect(std.mem.indexOf(u8, malformed.text, "<strong never closes.") != null);
}

test "multiline unsupported HTML stays opaque across block boundaries" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<div align="center">
        \\<script>
        \\raw script text
        \\
        \\<strong>alert</strong> &amp;
        \\</div>
        \\</script>
        \\Still centered
        \\</div>
        \\Outside
    , .{});

    const script = findParagraphContaining(tree.root, "<script>").?;
    try testing.expect(std.mem.indexOf(u8, script.text, "<strong>alert</strong> &amp;") != null);
    try testing.expect(std.mem.startsWith(u8, script.spans[0].text, "<script>"));
    try testing.expect(std.mem.indexOf(u8, script.spans[0].text, "<strong>alert</strong> &amp;") != null);
    try testing.expectEqual(canvas.TextSpanWeight.regular, script.spans[0].weight);

    const centered = findParagraphContaining(tree.root, "Still centered").?;
    const outside = findParagraphContaining(tree.root, "Outside").?;
    try testing.expectEqual(canvas.TextAlign.center, centered.text_alignment);
    try testing.expectEqual(canvas.TextAlign.start, outside.text_alignment);
}

test "HTML element bodies truncate at the markdown paragraph budget" {
    var source_buffer: [markdown.max_markdown_paragraph_bytes + 256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&source_buffer);
    try stream.writeAll("<p>");
    for (0..markdown.max_markdown_paragraph_bytes + 128) |_| try stream.writeAll("x");
    try stream.writeAll("</p>After");

    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(stream.buffered(), .{});
    try testing.expectEqual(@as(usize, 2), tree.root.children.len);
    try testing.expectEqual(markdown.max_markdown_paragraph_bytes, tree.root.children[0].text.len);
    try testing.expectEqualStrings("After", tree.root.children[1].text);
}

test "multiline HTML comments stay hidden across blank lines" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\Before
        \\<!-- hidden
        \\
        \\still hidden -->
        \\After
    , .{});

    try testing.expectEqual(@as(usize, 2), tree.root.children.len);
    try testing.expectEqualStrings("Before", tree.root.children[0].text);
    try testing.expectEqualStrings("After", tree.root.children[1].text);
}

test "unclosed safe HTML blocks and inline tags remain literal" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<h2>Unclosed heading
        \\
        \\- following item
        \\
        \\Malformed <strong title="**">never closes and stray </em>.
        \\
        \\</h3>
    , .{});

    const heading = findParagraphContaining(tree.root, "Unclosed heading").?;
    try testing.expectEqualStrings("<h2>Unclosed heading", heading.text);
    try testing.expectEqual(canvas.TextSpanWeight.regular, heading.spans[0].weight);
    try testing.expectEqual(@as(f32, 0), heading.spans[0].scale);
    try testing.expect(findRowWithDirectParagraph(tree.root, "following item") != null);

    const malformed = findParagraphContaining(tree.root, "Malformed").?;
    try testing.expectEqualStrings(
        "Malformed <strong title=\"**\">never closes and stray </em>.",
        malformed.text,
    );
    for (malformed.spans) |span| try testing.expectEqual(canvas.TextSpanWeight.regular, span.weight);
    try testing.expectEqualStrings("</h3>", findParagraphContaining(tree.root, "</h3>").?.text);
}

test "HTML wrapper closers inside Markdown code spans stay literal" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<div align="center">
        \\Use `</div>` literally.
        \\
        \\Still centered.
        \\</div>
        \\Outside.
    , .{});

    const code_line = findParagraphContaining(tree.root, "Use </div> literally.").?;
    const centered = findParagraphContaining(tree.root, "Still centered.").?;
    const outside = findParagraphContaining(tree.root, "Outside.").?;
    try testing.expect(findSpan(code_line, "</div>").?.monospace);
    try testing.expectEqual(canvas.TextAlign.center, code_line.text_alignment);
    try testing.expectEqual(canvas.TextAlign.center, centered.text_alignment);
    try testing.expectEqual(canvas.TextAlign.start, outside.text_alignment);
}

test "multiline comments stay opaque while collecting HTML blocks" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<blockquote>
        \\Before.
        \\<!-- hidden
        \\</blockquote>
        \\still hidden -->
        \\After.
        \\</blockquote>
        \\Outside.
    , .{});

    try testing.expectEqual(@as(usize, 2), tree.root.children.len);
    try testing.expect(findParagraphContaining(tree.root.children[0], "Before.") != null);
    try testing.expect(findParagraphContaining(tree.root.children[0], "After.") != null);
    try testing.expect(findParagraphContaining(tree.root.children[0], "hidden") == null);
    try testing.expectEqualStrings("Outside.", tree.root.children[1].text);
}

test "HTML ordered and definition lists retain their native semantics" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\<ol>
        \\<li>First</li>
        \\<li>Second</li>
        \\</ol>
        \\<ol><li>Compact one</li><li>Compact two</li></ol>
        \\<dl>
        \\<dt>Term</dt>
        \\<dd>Definition</dd>
        \\</dl>
    , .{});

    try testing.expectEqual(@as(usize, 2), countKindLabel(tree.root, .text, "1."));
    try testing.expectEqual(@as(usize, 2), countKindLabel(tree.root, .text, "2."));
    try testing.expectEqual(@as(usize, 0), countKindLabel(tree.root, .text, "•"));
    try testing.expectEqual(canvas.TextSpanWeight.bold, findSpan(tree.root, "Term").?.weight);
    try testing.expect(findParagraphContaining(tree.root, "Definition") != null);
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
    // The row keeps stretch alignment for wrapped paragraph height, while
    // a leading column pins the marker itself to the first-line edge.
    const bullet_row = findRowWithDirectParagraph(tree.root, "first").?;
    const ordered_row = findRowWithDirectParagraph(tree.root, "one").?;
    try testing.expectEqual(canvas.WidgetCrossAlignment.stretch, bullet_row.layout.cross_alignment);
    try testing.expectEqual(canvas.WidgetKind.column, bullet_row.children[0].kind);
    try testing.expectEqualStrings("•", bullet_row.children[0].children[0].text);
    try testing.expectEqual(canvas.WidgetCrossAlignment.stretch, ordered_row.layout.cross_alignment);
    try testing.expectEqual(canvas.WidgetKind.column, ordered_row.children[0].kind);
    try testing.expectEqualStrings("1.", ordered_row.children[0].children[0].text);

    // Fences use the same deliberately bare code component.
    try testing.expectEqual(@as(usize, 0), countKind(tree.root, .panel));
    const code = findParagraphContaining(tree.root, "const x = 1;").?;
    try testing.expect(code.spans[0].monospace);
    try testing.expectEqual(@as(?canvas.TextSpanColor, .syntax_keyword), code.spans[0].color);
}

test "language-tagged code fences highlight tokens and preserve indentation" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\```zig
        \\pub fn main() void {
        \\    const message = "hello";
        \\    // keep this indentation
        \\    return 42;
        \\}
        \\```
    , .{});

    const code = findParagraphContaining(tree.root, "pub fn main() void").?;
    var source_text: std.ArrayListUnmanaged(u8) = .empty;
    defer source_text.deinit(testing.allocator);
    try appendParagraphText(code, &source_text, testing.allocator);
    try testing.expectEqualStrings(
        "pub fn main() void {\n    const message = \"hello\";\n    // keep this indentation\n    return 42;\n}",
        source_text.items,
    );
    try testing.expect(allSpansMonospace(code));
    try testing.expect(hasSpan(code, "pub", .syntax_keyword));
    try testing.expect(hasSpan(code, "void", .syntax_literal));
    try testing.expect(hasSpan(code, "\"hello\"", .syntax_literal));
    try testing.expect(hasSpan(code, "// keep this indentation", .syntax_comment));
    try testing.expect(hasSpan(code, "42", .syntax_literal));

    const indented = findParagraphContaining(code, "const message").?;
    var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
    const layout = text_spans.layoutTextSpans(indented.spans, .{ .size = 14, .max_width = 10_000 }, &runs);
    var indented_keyword_x: ?f32 = null;
    for (layout.runs) |run| {
        if (run.line_index == 1 and std.mem.eql(u8, run.text, "const")) indented_keyword_x = run.x;
    }
    // Four source spaces occupy real horizontal advance before `const`.
    try testing.expect(indented_keyword_x != null);
    try testing.expectApproxEqAbs(@as(f32, 4 * 14 * 0.6), indented_keyword_x.?, 0.01);
}

test "unrecognized code-fence languages remain plain monospace" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\```made-up-language
        \\alpha 42
        \\```
    , .{});

    const code = findParagraphContaining(tree.root, "alpha 42").?;
    try testing.expectEqual(@as(usize, 1), code.spans.len);
    try testing.expect(code.spans[0].monospace);
    try testing.expectEqual(@as(?canvas.TextSpanColor, .syntax_plain), code.spans[0].color);
}

test "per-line syntax highlighting does not drop fenced code" {
    const code_source =
        "const a0 = 0;\n" ++
        "const a1 = 1;\n" ++
        "const a2 = 2;\n" ++
        "const a3 = 3;\n" ++
        "const a4 = 4;\n" ++
        "const a5 = 5;\n" ++
        "const a6 = 6;\n" ++
        "const a7 = 7;\n" ++
        "const a8 = 8;\n" ++
        "const a9 = 9;\n" ++
        "const a10 = 10;\n" ++
        "const a11 = 11;";
    const source = "```zig\n" ++ code_source ++ "\n```";

    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(source, .{});
    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    defer rendered.deinit(testing.allocator);
    try appendParagraphText(tree.root, &rendered, testing.allocator);
    try testing.expectEqualStrings(code_source, rendered.items);
    try testing.expect(hasSpan(tree.root, "const", .syntax_keyword));
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

test "details summaries lower safe inline HTML" {
    const source =
        \\<details>
        \\<summary><strong>More</strong> &amp; <a href="https://example.com">docs</a></summary>
        \\Body.
        \\</details>
    ;

    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(source, .{
        .on_link = Ui.linkMsg(.open_url),
        .on_details = Md.detailsMsg(.toggle_details),
    });

    const summary = findParagraphContaining(tree.root, "More & docs").?;
    try testing.expectEqual(canvas.TextSpanWeight.bold, findSpan(summary, "More").?.weight);
    try testing.expectEqualStrings("https://example.com", findSpan(summary, "docs").?.link);

    const header = findKindLabel(tree.root, .list_item, "▸ More & docs").?;
    const toggle = tree.msgForPointer(header.id, .up).?;
    try testing.expectEqual(@as(usize, 0), toggle.toggle_details);
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

test "resolved leading table images render as native image leaves with alt fallback" {
    const avatar_url = "https://vercel.com/api/www/avatar?projectId=project&teamId=team&s=32";
    const ready_url = "https://vercel.com/static/status/ready.svg";
    const images = [_]markdown.ResolvedImage{
        .{ .source = avatar_url, .image = 41, .width = 32, .height = 32 },
        .{ .source = ready_url, .image = 42, .width = 10, .height = 10 },
    };

    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\| Project | Deployment |
        \\| :--- | :--- |
        \\| <a href="https://vercel.com/vercel-labs/native-sdk"><sup><img src="https://vercel.com/api/www/avatar?projectId=project&teamId=team&s=32" width="16" height="16" align="middle" alt="" /></sup></a> [native-sdk](https://vercel.com/vercel-labs/native-sdk) | ![Ready](https://vercel.com/static/status/ready.svg) [Ready](https://vercel.com/deploy) |
    , .{ .on_link = Ui.linkMsg(.open_url), .images = &images });

    try testing.expectEqual(@as(usize, 2), countKind(tree.root, .image));
    const avatar = findImageId(tree.root, 41).?;
    try testing.expectEqual(@as(f32, 16), avatar.layout.min_size.width);
    try testing.expectEqual(@as(f32, 16), avatar.layout.min_size.height);
    try testing.expectEqual(canvas.WidgetRole.link, avatar.semantics.role);
    try testing.expectEqualStrings("https://vercel.com/vercel-labs/native-sdk", tree.msgForPointer(avatar.id, .up).?.open_url);

    const ready = findImageId(tree.root, 42).?;
    try testing.expectEqual(@as(f32, 10), ready.layout.min_size.width);
    try testing.expectEqual(@as(f32, 10), ready.layout.min_size.height);
    try testing.expectEqual(canvas.WidgetRole.image, ready.semantics.role);
    try testing.expectEqualStrings("Ready", ready.semantics.label);
    try testing.expect(findParagraphContaining(tree.root, "native-sdk") != null);
    try testing.expect(findParagraphContaining(tree.root, "Ready") != null);

    var fallback_doc = TestDoc.init();
    defer fallback_doc.deinit();
    const fallback = try fallback_doc.build(
        \\| Deployment |
        \\| --- |
        \\| ![Ready](https://vercel.com/static/status/ready.svg) |
    , .{});
    try testing.expectEqual(@as(usize, 0), countKind(fallback.root, .image));
    try testing.expect(findCellContaining(fallback.root, "Ready") != null);
}

test "entity-normalized discovered image sources match resolved HTML images" {
    const source =
        \\<img src="https://example.com/avatar?a=1&amp;b=2" alt="Avatar" />
    ;
    var collected_storage: [1]markdown.CollectedImageSource = undefined;
    const collected = markdown.collectImageSources(source, &collected_storage);
    try testing.expectEqual(@as(usize, 1), collected.len);
    try testing.expectEqualStrings("https://example.com/avatar?a=1&b=2", collected[0].value());

    const images = [_]markdown.ResolvedImage{.{
        .source = collected[0].value(),
        .image = 75,
        .width = 32,
        .height = 32,
    }};
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(source, .{ .images = &images });
    try testing.expect(findImageId(tree.root, 75) != null);
}

test "table text cells vertically center beside resolved images" {
    const source = "https://example.com/tall.png";
    const images = [_]markdown.ResolvedImage{
        .{ .source = source, .image = 76, .width = 40, .height = 40 },
    };

    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\| Project | Action |
        \\| --- | --- |
        \\| ![Logo](https://example.com/tall.png) Native | [Preview](https://example.com) |
    , .{ .on_link = Ui.linkMsg(.open_url), .images = &images });

    const image = findImageId(tree.root, 76).?;
    const preview = findRoleLabel(tree.root, .link, "Preview").?;
    var nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTreeWithTokens(
        tree.root,
        geometry.RectF.init(0, 0, 360, 160),
        .{},
        &nodes,
    );
    const image_frame = layout.findById(image.id).?.frame;
    const preview_frame = layout.findById(preview.id).?.frame;
    try testing.expectApproxEqAbs(
        image_frame.y + image_frame.height * 0.5,
        preview_frame.y + preview_frame.height * 0.5,
        0.01,
    );
}

test "resolved image composites honor center and end alignment" {
    const source = "https://example.com/centered.png";
    const images = [_]markdown.ResolvedImage{
        .{ .source = source, .image = 78, .width = 40, .height = 20 },
        .{ .source = source, .image = 79, .width = 40, .height = 20 },
        .{ .source = source, .image = 81, .width = 40, .height = 20 },
    };

    var paragraph_doc = TestDoc.init();
    defer paragraph_doc.deinit();
    const paragraph_tree = try paragraph_doc.build(
        \\<p align="center"><img src="https://example.com/centered.png" alt="Centered" /></p>
    , .{ .images = images[0..1] });
    const paragraph_image = findImageId(paragraph_tree.root, 78).?;
    var paragraph_nodes: [32]canvas.WidgetLayoutNode = undefined;
    const paragraph_layout = try canvas.layoutWidgetTreeWithTokens(
        paragraph_tree.root,
        geometry.RectF.init(0, 0, 400, 100),
        .{},
        &paragraph_nodes,
    );
    const paragraph_frame = paragraph_layout.findById(paragraph_image.id).?.frame;
    try testing.expectApproxEqAbs(@as(f32, 200), paragraph_frame.x + paragraph_frame.width * 0.5, 0.01);

    var table_doc = TestDoc.init();
    defer table_doc.deinit();
    const table_tree = try table_doc.build(
        \\| Centered |
        \\| :---: |
        \\| ![Centered](https://example.com/centered.png) |
    , .{ .images = images[1..2] });
    const table_image = findImageId(table_tree.root, 79).?;
    const table_cell = findCellContainingImage(table_tree.root, 79).?;
    var table_nodes: [32]canvas.WidgetLayoutNode = undefined;
    const table_layout = try canvas.layoutWidgetTreeWithTokens(
        table_tree.root,
        geometry.RectF.init(0, 0, 400, 120),
        .{},
        &table_nodes,
    );
    const image_frame = table_layout.findById(table_image.id).?.frame;
    const cell_frame = table_layout.findById(table_cell.id).?.frame;
    try testing.expectApproxEqAbs(
        cell_frame.x + cell_frame.width * 0.5,
        image_frame.x + image_frame.width * 0.5,
        0.01,
    );

    var end_doc = TestDoc.init();
    defer end_doc.deinit();
    const end_tree = try end_doc.build(
        \\<p align="right"><img src="https://example.com/centered.png" alt="End" /></p>
    , .{ .images = images[2..3] });
    const end_image = findImageId(end_tree.root, 81).?;
    var end_nodes: [32]canvas.WidgetLayoutNode = undefined;
    const end_layout = try canvas.layoutWidgetTreeWithTokens(
        end_tree.root,
        geometry.RectF.init(0, 0, 400, 100),
        .{},
        &end_nodes,
    );
    const end_frame = end_layout.findById(end_image.id).?.frame;
    try testing.expectApproxEqAbs(@as(f32, 400), end_frame.x + end_frame.width, 0.01);
}

test "resolved leading paragraph images compose with trailing inline text" {
    const source = "https://example.com/diagram.png";
    const images = [_]markdown.ResolvedImage{
        .{ .source = source, .image = 77, .width = 80, .height = 40 },
    };

    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\![Architecture](https://example.com/diagram.png) **Current** design
        \\Text before ![inline](https://example.com/inline.png) stays an alt fallback.
    , .{ .images = &images });

    const image = findImageId(tree.root, 77).?;
    try testing.expectEqualStrings("Architecture", image.semantics.label);
    try testing.expect(findParagraphContaining(tree.root, "Current design") != null);
    try testing.expect(findParagraphContaining(tree.root, "Text before inline stays an alt fallback.") != null);
}

test "resolved image bounds preserve aspect ratio" {
    const source = "https://example.com/wide.png";
    const images = [_]markdown.ResolvedImage{
        .{ .source = source, .image = 80, .width = 1024, .height = 256 },
    };

    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(
        \\![Wide](https://example.com/wide.png)
    , .{ .images = &images });
    const image = findImageId(tree.root, 80).?;
    try testing.expectEqual(@as(f32, 512), image.layout.min_size.width);
    try testing.expectEqual(@as(f32, 128), image.layout.min_size.height);
}

test "image source collection is bounded, distinct, and keeps code inert" {
    var storage: [4]markdown.CollectedImageSource = undefined;
    const sources = markdown.collectImageSources(
        \\![first](https://example.com/first.png)
        \\Text before ![inline](https://example.com/inline.png)
        \\`![code](https://example.com/code.png)`
        \\| Image | Copy |
        \\| --- | --- |
        \\| <a href="https://example.com"><sup><img src="https://example.com/second.svg?a=1&amp;b=2" alt="second" /></sup></a> label | <!-- <img src="https://example.com/comment.png" /> --> |
        \\![again](https://example.com/first.png)
        \\```
        \\![fenced](https://example.com/fenced.png)
        \\```
    , &storage);

    try testing.expectEqual(@as(usize, 2), sources.len);
    try testing.expectEqualStrings("https://example.com/first.png", sources[0].value());
    try testing.expectEqualStrings("https://example.com/second.svg?a=1&b=2", sources[1].value());
}

test "image source collection mirrors visible block starts and keeps opaque HTML inert" {
    var storage: [10]markdown.CollectedImageSource = undefined;
    const sources = markdown.collectImageSources(
        \\Opening prose
        \\![joined fallback](https://example.com/joined.png)
        \\
        \\# ![heading](https://example.com/heading.png)
        \\- ![list](https://example.com/list.png)
        \\> ![quote](https://example.com/quote.png)
        \\<p><img src="https://example.com/html.png" alt="html" /></p>
        \\<!--
        \\<img src="https://tracker.example/comment.png" />
        \\-->
        \\![after comment](https://example.com/after-comment.png)
        \\
        \\<script>
        \\<img src="https://tracker.example/script.png" />
        \\</script>
        \\
        \\<pre>
        \\<img src="https://tracker.example/pre.png" />
        \\</pre>
        \\![after pre](https://example.com/after-pre.png)
        \\
        \\<code>
        \\<img src="https://tracker.example/code.png" />
        \\</code>
    , &storage);

    try testing.expectEqual(@as(usize, 6), sources.len);
    try testing.expectEqualStrings("https://example.com/heading.png", sources[0].value());
    try testing.expectEqualStrings("https://example.com/list.png", sources[1].value());
    try testing.expectEqualStrings("https://example.com/quote.png", sources[2].value());
    try testing.expectEqualStrings("https://example.com/html.png", sources[3].value());
    try testing.expectEqualStrings("https://example.com/after-comment.png", sources[4].value());
    try testing.expectEqualStrings("https://example.com/after-pre.png", sources[5].value());
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
    try testing.expectEqual(@as(usize, 0), countKind(tree.root, .panel));

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

    // Deliberate golden updates can be reviewed as pixels before pinning
    // the new signature.
    if (markdownGoldenDumpRequested()) {
        try dumpMarkdownGoldenPng("/tmp/markdown-shots/readme.png", width, height, pixels);
    }

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
// separators with vertically centered cell content, bare fenced code
// with preserved source indentation and language-token colors, and
// near-black underlined links.
// Update deliberately when markdown rendering changes, reviewing the
// rendered pixels first (see reference_tests.zig conventions).
const markdown_document_reference_signature: u64 = 17200107192111546862;

fn markdownGoldenDumpRequested() bool {
    if (comptime !@import("builtin").link_libc) return false;
    return std.c.getenv("MARKDOWN_GOLDEN_DUMP") != null;
}

fn dumpMarkdownGoldenPng(path: []const u8, width: usize, height: usize, pixels: []const u8) !void {
    const io = testing.io;
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse ".") catch {};
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try canvas.png.writeRgba8(&writer.interface, width, height, pixels);
    try writer.interface.flush();
}

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
