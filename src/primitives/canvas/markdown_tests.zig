const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const markdown = @import("markdown.zig");
const text_spans = @import("text_spans.zig");
const support = @import("test_support.zig");

const testing = std.testing;

const dev2_readme = @embedFile("testdata/dev2_readme.md");

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

test "dev-2 README renders through the mapper and the reference renderer" {
    var doc = TestDoc.init();
    defer doc.deinit();
    const tree = try doc.build(dev2_readme, .{ .on_link = Ui.linkMsg(.open_url) });

    // Structure spot checks against the real document.
    const title = findParagraphContaining(tree.root, "GHProjects").?;
    try testing.expectEqual(markdown.heading_scales[0], title.spans[0].scale);
    try testing.expect(findParagraphContaining(tree.root, "Left pane") != null);
    const gh_link = findRoleLabel(tree.root, .link, "`gh`").?;
    const open_msg = tree.msgForPointer(gh_link.id, .up).?;
    try testing.expectEqualStrings("https://cli.github.com", open_msg.open_url);
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
    try testing.expectEqual(dev2_readme_reference_signature, support.referenceSurfaceSignature(pixels));
    try support.expectVisiblePixel(surface.pixelRgba8(24, 32));
}

// Reference-renderer pixel signature of the fixture at 760x2400 with
// default tokens and the deterministic estimator.
const dev2_readme_reference_signature: u64 = 15066189027424610165;

