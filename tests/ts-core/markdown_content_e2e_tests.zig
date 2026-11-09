//! Complete native-reference comparison through the shipped scriptc owner.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const md = canvas.markdown;
const Msg = union(enum) { open_url: []const u8, toggle_details: usize, noop };
const Md = md.Markdown(Msg);
const Ui = canvas.Ui(Msg);
const exact = @import("component_construction_e2e_tests.zig").exact;

fn routes(widget: canvas.Widget, expected: Ui.Tree, actual: Ui.Tree) !void {
    try exact(expected.msgForPointer(widget.id, .up), actual.msgForPointer(widget.id, .up));
    for (widget.children) |child| try routes(child, expected, actual);
}
fn compare(source: []const u8, options: Md.Options) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var input_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_arena.deinit();
    const copied = try input_arena.allocator().dupe(u8, source);
    var reference = Ui.init(arena.allocator());
    var compiled = Ui.init(arena.allocator());
    compiled.markdown_content_policy = core.nativeMarkdownPolicy;
    compiled.code_content_policy = core.nativeWindowPolicy;
    const expected = try reference.finalize(Md.view(&reference, source, options));
    const actual = try compiled.finalize(Md.view(&compiled, copied, options));
    core.rt.frameReset();
    @memset(copied, 0xa5);
    _ = input_arena.reset(.free_all);
    try exact(expected, actual);
    try routes(expected.root, expected, actual);
    for ([_]f32{ 180, 320, 700 }) |width| {
        const before = try arena.allocator().alloc(canvas.WidgetLayoutNode, 16_384);
        const after = try arena.allocator().alloc(canvas.WidgetLayoutNode, 16_384);
        const reference_layout = canvas.layoutWidgetTree(expected.root, .init(0, 0, width, 480), before);
        const compiled_layout = canvas.layoutWidgetTree(actual.root, .init(0, 0, width, 480), after);
        if (reference_layout) |layout| {
            try exact(layout, try compiled_layout);
        } else |err| {
            // The complete trees above must still match when native layout
            // rejects deeply nested content at its own widget-depth budget.
            try std.testing.expectError(err, compiled_layout);
        }
    }
}
const corpus = [_][]const u8{
    "",                                                                                                                    "\n",                                                                                                                           "# Heading\ntext **bold** *italic* ~~strike~~ `mono` [link](target) <https://example.test> #123\n",
    "- first\n  - nested\n    2. deep\n- [x] done\n- [ ] next\n\n> quote\n> continued\n\n---\n",                           "| **Name** | Link |\n| :--- | --: |\n| a\\|b | [x](target) |\n| short |\n| one | two | three |\n",                             "<details>\n<summary><b>Summary</b> [go](u)</summary>\n# Body\n<details>\n<summary>Nested</summary>\ncontent\n</details>\n</details>\ntail",
    "<DIV align='center'>\n# Center\n<p align=right>A &amp; B</p>\n<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n</DIV>\ntail", "<blockquote><div align=center>\n# quoted\n</blockquote>\n# plain\n<dl><dt>Term</dt><dd>Definition</dd></dl>",                  "<pre><code>&lt;literal&gt;\n  x &amp; y\n</code></pre>\n```{.ts}\n  const raw = true;\n```\n",
    "<b>x <em>y</em></b><mark>marked</mark><small>small</small><q>quote</q><br><wbr><img alt='fallback'>",                 "<script>**literal** <b>inert</b>&amp;\n\n# still inert\n</script>\n<!-- hidden\n\n![x](inert)\n-->tail",                       "<div>text `</div>` stays\nend</div>\n<p>unclosed\n<b>stray</em><unknown/>\n[ref]: <dest> 'title'\n[ref] literal",
    "![alt](asset) **suffix**\n\n<a href='go&amp;next'><sup><img src='asset' alt='label&#33;' width='64'></sup></a> tail", "\x00\xff\xc0\xaf **raw\xff** <a href='u\x00\xff'>link\x00</a> &#128512; &#x1f600; &#0; &#xD800; &#_65; &#65_; &#6__5; &#+65;", "https://example.test/a(b))). xhttps://inert /https://inert &https://inert\n#1 #23x &#24 #0005",
};
const mappings = [_]md.ResolvedImage{
    .{ .source = "asset", .image = 0, .width = 32, .height = 32 },
    .{ .source = "asset", .image = 0xfedc_ba98_7654_3210, .width = 240, .height = 120 },
    .{ .source = "asset", .image = 4, .width = 12, .height = 32 },
};

test "compiled Markdown preserves complete trees spans routes layouts and byte ownership" {
    _ = core.initialModel();
    for (corpus, 0..) |source, index| for (0..8) |facts| {
        const expanded = [_]bool{ facts & 1 != 0, facts & 2 != 0, true, false };
        errdefer std.debug.print("Markdown case {d} facts {d}\n", .{ index, facts });
        try compare(source, .{ .on_link = if (facts & 4 != 0) Ui.linkMsg(.open_url) else null, .on_details = if (facts & 4 != 0) Md.detailsMsg(.toggle_details) else null, .details_expanded = &expanded, .issue_link_base = if (facts & 2 != 0) "issue://\x00\xff/" else null, .images = if (facts & 1 != 0) &mappings else &.{} });
    };
}

test "compiled Markdown image discovery preserves every canonical source and output bound" {
    _ = core.initialModel();
    const source = "![a](asset)\n\n| ![b](second) | ![c](third) |\n|---|---|\n| <img src='a&amp;b'> | tail ![inert](no) |\n\n```\n![inert](no)\n```\n<code>\n<img src='no'>\n</code>\n<script>\n<img src='no'>\n</script>\n\n# ![d](heading)\n- ![e](list)\n> ![f](quote)\n\n<summary><img src='summary'></summary>\n";
    for (corpus ++ .{source}) |text| for (0..18) |capacity| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var before: [18]md.CollectedImageSource = undefined;
        var after: [18]md.CollectedImageSource = undefined;
        const expected = md.collectImageSources(text, before[0..capacity]);
        const actual = try md.collectImageSourcesOwned(core.nativeMarkdownPolicy, arena.allocator(), text, after[0..capacity]);
        core.rt.frameReset();
        _ = arena.reset(.free_all);
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |*a, *b| try std.testing.expectEqualSlices(u8, a.value(), b.value());
    };
}

test "compiled Markdown hostile capacity fallback preserves the complete native tree" {
    _ = core.initialModel();
    const patterns = [_][]const u8{ "- item\n", "# heading\n\n", "a ", "[", "<", "![", "<!--", "https://example.test/" ++ ")" ** 40 ++ " ", "<b>x</b>", "<details>\n<summary>s</summary>\n", "<div align=center>\n", "| a | b |\n" };
    const expanded = [_]bool{true} ** 16;
    for (patterns) |pattern| {
        const count: usize = if (std.mem.eql(u8, pattern, "a ")) 6000 else 100;
        const text = try std.testing.allocator.alloc(u8, pattern.len * count + "\n\n# retained tail\n\x00\xff literal tail".len);
        defer std.testing.allocator.free(text);
        for (0..count) |i| @memcpy(text[i * pattern.len ..][0..pattern.len], pattern);
        @memcpy(text[pattern.len * count ..], "\n\n# retained tail\n\x00\xff literal tail");
        try compare(text, .{ .on_link = Ui.linkMsg(.open_url), .on_details = Md.detailsMsg(.toggle_details), .details_expanded = &expanded, .issue_link_base = "issue://" });
    }
}

test "compiled Markdown dimensions preserve direct f32 rounding and exact geometry" {
    _ = core.initialModel();
    const dimensions = [_][]const u8{ "64", "1_024", "0x1.8p+8", "0X1_0.0p-1", "1.000000059604644775390625", "1.000000059604644775390626", "1.000000059604644775390624", "0x1.000001p0", "0x1.00000100000001p0", "7.00649232162408535461864791644958065640130970938257885878534141944895541342930300743319094181060791015625e-46", "1e-5000", "1e5000", "3.40282356779733661637539395458142568448e38", "nan", "inf", "-1", "", "_1", "1_", "1__2", "1_.2", "1e_2", "0b100", "64px", " 64 ", "64\r", "+64" };
    for (dimensions) |width| for ([_][]const u8{ "", " height='12'", " height='0x1.2p3'", " height='1e5000'" }) |height| {
        var storage: [1400]u8 = undefined;
        const source = try std.fmt.bufPrint(&storage, "<img src=asset width='{s}'{s}> tail", .{ width, height });
        try compare(source, .{ .images = &mappings, .on_link = Ui.linkMsg(.open_url) });
    };
}

test "compiled Markdown complete document and deterministic mixed grammar match native" {
    _ = core.initialModel();
    const document = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/primitives/canvas/testdata/markdown_document.md", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(document);
    const expanded = [_]bool{true} ** 16;
    const options: Md.Options = .{ .images = &mappings, .on_link = Ui.linkMsg(.open_url), .on_details = Md.detailsMsg(.toggle_details), .details_expanded = &expanded, .issue_link_base = "issue://\x00\xff/" };
    try compare(document, options);
    const fragments = [_][]const u8{ "\n", "\x00\xff\xc0", "**bold** ", "*", "`code` ", "<!-- hidden -->", "[go](u)", "![alt](asset)", "<a href='raw&amp;u'>", "</a>", "<b>", "</b>", "&#x1f600;", "<script>", "</script>", "<code>", "</code>", "\n# Title\n", "\n- item\n", "\n> quote\n", "\n<div align=center>\n", "\n</div>\n", "\n| a | b |\n|:---|---:|\n", "\n<details>\n<summary>More</summary>\n", "\n</details>\n", "\n```ts\n", "\n```\n", "https://example.test/path)). ", "#0005 ", "[ref]: target\n" };
    var random = std.Random.DefaultPrng.init(0x4d61726b646f776e);
    for (0..80) |iteration| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(std.testing.allocator);
        for (0..80) |_| try bytes.appendSlice(std.testing.allocator, fragments[random.random().uintLessThan(usize, fragments.len)]);
        errdefer std.debug.print("Markdown mixed grammar case {d}\n", .{iteration});
        try compare(bytes.items, options);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var before: [16]md.CollectedImageSource = undefined;
        var after: [16]md.CollectedImageSource = undefined;
        const expected = md.collectImageSources(bytes.items, &before);
        const actual = try md.collectImageSourcesOwned(core.nativeMarkdownPolicy, arena.allocator(), bytes.items, &after);
        core.rt.frameReset();
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |*a, *b| try std.testing.expectEqualSlices(u8, a.value(), b.value());
    }
}

test "compiled Markdown recipe validation and retained ownership have no native fallback" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "[go](raw\x00\xff)\n\n- item\n\n```ts\nconst x = 1;\n```";
    var request = [_]u8{0} ** (24 + source.len);
    request[0..4].* = .{ 22, 0, 1, 0 };
    std.mem.writeInt(u32, request[4..8], source.len, .little);
    @memcpy(request[24..], source);
    const bytes = try arena.allocator().dupe(u8, core.nativeMarkdownPolicy(&request, arena.allocator()));
    core.rt.frameReset();
    for (0..bytes.len) |len| {
        var ui = Ui.init(arena.allocator());
        try std.testing.expectError(error.InvalidMarkdownRecipe, canvas.MarkdownContentPolicy.execute(Msg, &ui, bytes[0..len], .{}));
    }
    for ([_]usize{ 0, 4, 8, 12, 16, 17, 18, 19, 40, 48, 52, 56, 60, 64, 68, 72, 76 }) |at| {
        const malformed = try arena.allocator().dupe(u8, bytes);
        malformed[at] ^= 255;
        var ui = Ui.init(arena.allocator());
        if (canvas.MarkdownContentPolicy.execute(Msg, &ui, malformed, .{})) |_| return error.TestExpectedError else |_| {}
    }
    var reference = Ui.init(arena.allocator());
    var compiled = Ui.init(arena.allocator());
    compiled.code_content_policy = core.nativeWindowPolicy;
    const expected = try reference.finalize(Md.view(&reference, source, .{ .on_link = Ui.linkMsg(.open_url) }));
    const actual = try compiled.finalize(try canvas.MarkdownContentPolicy.execute(Msg, &compiled, bytes, .{ .on_link = Ui.linkMsg(.open_url) }));
    @memset(bytes, 0xa5);
    @memset(&request, 0);
    core.rt.frameReset();
    try exact(expected, actual);
    try routes(expected.root, expected, actual);
    const Broken = struct {
        fn policy(_: []const u8, _: std.mem.Allocator) []const u8 {
            return &.{0};
        }
    };
    var failed = Ui.init(arena.allocator());
    failed.markdown_content_policy = Broken.policy;
    const root = Md.view(&failed, "# retained source", .{});
    try std.testing.expectError(error.OutOfMemory, failed.finalize(root));
}
