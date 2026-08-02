//! Hostile-input corpus for the markdown mapper: real-world-nasty GitHub
//! content — pathological nesting, gigantic tables, kilochar words, mixed
//! RTL/CJK/emoji/ZWJ, unterminated fences, bracket/autolink bombs, HTML
//! soup, NUL bytes and invalid UTF-8, and multi-megabyte documents.
//!
//! The contract under test is the mapper's own: every input degrades
//! loudly-or-gracefully — `view` never panics, never hangs (parse work and
//! arena growth stay linear in the source), and always yields a valid
//! finalized tree (truncation is deterministic, documented, and bounded).
//! Timing is pinned by construction: the bomb documents are sized so a
//! reintroduced quadratic scan or join turns this suite from milliseconds
//! into minutes — loud in any gate.
//!
//! Two layers:
//! - targeted fixtures for each hostile shape (built inline so the
//!   pathology is visible next to its assertions), and
//! - a seed-pinned generator that splices those shapes into random
//!   documents (deterministic across runs; the seed is a constant).

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const markdown = @import("markdown.zig");
const text_spans = @import("text_spans.zig");
const support = @import("test_support.zig");

const testing = std.testing;

const Msg = union(enum) {
    open_url: []const u8,
    toggle_details: usize,
    noop,
};

const Md = markdown.Markdown(Msg);
const Ui = Md.Ui;

/// Arena growth bound for a build: parsing must stay LINEAR in the
/// source. The constant is honest about the mapper's real shape — every
/// container block eagerly allocates a `max_markdown_blocks_per_container`
/// node buffer (64 nodes x a multi-KiB `Ui.Node`), and one table costs a
/// 64-row buffer (~315 KiB measured), so container-dense documents run
/// ~180x their source bytes (measured: 100-deep nesting 15 KiB -> 2.7 MiB).
/// The factor scales with `Ui.Node` itself — every handler field added to
/// `ElementOptions` (the hover pair moved the densest corpus doc from
/// ~1.45 MiB to ~1.54 MiB at 3.9 KiB source) grows those eager buffers
/// linearly, so the factor carries headroom over the measured densest
/// shape. 320x + a one-table floor keeps the assert green for every
/// legitimate shape while a quadratic join (megabytes-per-source-KiB)
/// still blows through it by orders of magnitude.
fn arenaBound(source_len: usize) usize {
    return source_len * 320 + 512 * 1024;
}

const BuildResult = struct {
    widgets: usize,
    text_bytes: usize,
};

/// Build `source` through the mapper with every hostile-relevant option
/// on, finalize, walk the tree, and enforce the linear-arena bound.
fn buildHostile(source: []const u8) !BuildResult {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = Ui.init(arena_state.allocator());
    const expanded = [_]bool{true} ** markdown.max_markdown_details_per_document;
    const node = Md.view(&ui, source, .{
        .on_link = Ui.linkMsg(.open_url),
        .on_details = Md.detailsMsg(.toggle_details),
        .details_expanded = &expanded,
        .issue_link_base = "ghissue://",
    });
    const tree = try ui.finalize(node);
    var result = BuildResult{ .widgets = 0, .text_bytes = 0 };
    walk(tree.root, &result);
    const capacity = arena_state.queryCapacity();
    if (capacity > arenaBound(source.len)) {
        std.debug.print(
            "markdown build arena grew superlinearly: source={d} bytes, arena={d} bytes (bound {d})\n",
            .{ source.len, capacity, arenaBound(source.len) },
        );
        return error.ArenaGrowthSuperlinear;
    }
    return result;
}

fn walk(widget: canvas.Widget, result: *BuildResult) void {
    result.widgets += 1;
    result.text_bytes += widget.text.len;
    for (widget.spans) |span| result.text_bytes += span.text.len;
    for (widget.children) |child| walk(child, result);
}

/// Layout, emit, frame-plan, and reference-render a built tree — the
/// full deterministic pipeline the README golden runs, at a smaller
/// surface. Hostile text must come out the other end as pixels (or as a
/// named budget error from the fixed-capacity harness arrays), never a
/// panic.
fn renderHostile(source: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = Ui.init(arena_state.allocator());
    const node = Md.view(&ui, source, .{ .on_link = Ui.linkMsg(.open_url) });
    const tree = try ui.finalize(node);

    const canvas_width: f32 = 480;
    const canvas_height: f32 = 960;
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
}

test "hostile: 100-deep quotes, lists, and details nesting stay bounded" {
    var buffer: [64 * 1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    // 100-deep blockquote markers on one line, then 100 quote lines.
    for (0..100) |_| try stream.writeAll("> ");
    try stream.writeAll("deep quote\n\n");
    for (0..100) |_| try stream.writeAll("> another quoted line\n");
    try stream.writeAll("\n");
    // 100-deep list indentation (clamps at max_markdown_list_depth).
    for (0..100) |depth| {
        for (0..depth) |_| try stream.writeAll("  ");
        try stream.writeAll("- item\n");
    }
    try stream.writeAll("\n");
    // Details nested past max_markdown_details_per_document, all expanded.
    for (0..40) |_| try stream.writeAll("<details>\n<summary>s</summary>\n\nbody\n\n");
    for (0..40) |_| try stream.writeAll("</details>\n");

    const result = try buildHostile(stream.buffered());
    try testing.expect(result.widgets > 0);
}

test "hostile: gigantic tables truncate deterministically" {
    var buffer: [512 * 1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    // Max-width table with thousands of rows: rows past
    // max_markdown_table_rows drop, columns past the cap degrade the
    // whole block to paragraphs (pinned by markdown_tests) — either way
    // the tree stays valid and bounded.
    try stream.writeAll("| a | b | c | d | e | f | g | h |\n");
    try stream.writeAll("| - | - | - | - | - | - | - | - |\n");
    for (0..4000) |_| try stream.writeAll("| **x** | `y` | [l](https://e.com) | ~~s~~ | v | w | #12 | z |\n");

    const result = try buildHostile(stream.buffered());
    try testing.expect(result.widgets > 0);
}

test "hostile: kilochar single words and megabyte paragraphs join in linear memory" {
    const allocator = testing.allocator;

    // A 10k-char single word inside prose.
    {
        var buffer: [16 * 1024]u8 = undefined;
        var stream = std.Io.Writer.fixed(&buffer);
        try stream.writeAll("before ");
        for (0..10_000) |_| try stream.writeAll("a");
        try stream.writeAll(" after");
        _ = try buildHostile(stream.buffered());
    }

    // One paragraph, no blank lines, ~1 MiB of short lines: the join
    // must be one-pass (a per-line re-join is quadratic in both time and
    // arena) and the paragraph must truncate at its documented budget.
    {
        const source = try allocator.alloc(u8, 1024 * 1024);
        defer allocator.free(source);
        @memset(source, 'w');
        var index: usize = 40;
        while (index < source.len) : (index += 41) source[index] = '\n';
        _ = try buildHostile(source);
    }
}

test "hostile: bracket, autolink, and reference-link bombs parse in linear time" {
    const allocator = testing.allocator;
    const bomb_len = 256 * 1024;
    const source = try allocator.alloc(u8, bomb_len);
    defer allocator.free(source);

    // '[' wall with one ']' at the end: every position used to rescan to
    // the terminator looking for `](`.
    @memset(source, '[');
    source[bomb_len - 1] = ']';
    _ = try buildHostile(source);

    // '<' wall: every position used to rescan for '>' and fail the
    // autolink test.
    @memset(source, '<');
    source[bomb_len - 1] = '>';
    _ = try buildHostile(source);

    // '[a](x' units with the lone ')' at the end: the ']' is always
    // nearby but the ')' scan used to run to the terminator each time.
    {
        var index: usize = 0;
        while (index + 5 <= bomb_len) : (index += 5) {
            @memcpy(source[index..][0..5], "[a](x");
        }
        @memset(source[bomb_len - (bomb_len % 5) ..], 'x');
        source[bomb_len - 1] = ')';
        _ = try buildHostile(source);
    }

    // Interleaved '[<' wall with a link tail: the link title-strip and
    // the autolink target check both probe for ' ' from different
    // offsets — with a shared memo they evict each other back into
    // quadratic rescans.
    {
        // Tail: "]()" makes every '[' parse fail AFTER its title-space
        // probe (empty target), and " ://x>" lets every '<' reach its
        // target-space probe — the two probe streams interleave.
        const tail = "]() ://x> en";
        var index: usize = 0;
        while (index + 2 <= bomb_len - tail.len) : (index += 2) {
            @memcpy(source[index..][0..2], "[<");
        }
        @memcpy(source[bomb_len - tail.len ..][0..tail.len], tail);
        _ = try buildHostile(source);
    }

    // Reference-link bomb: thousands of definitions (unsupported ->
    // literal text) with no blank lines — one giant paragraph.
    {
        var stream = std.Io.Writer.fixed(source);
        while (stream.buffered().len + 32 < bomb_len) {
            try stream.writeAll("[ref]: https://example.com/path\n");
        }
        _ = try buildHostile(stream.buffered());
    }
}

test "hostile: bare-url paren tails trim in linear time" {
    const allocator = testing.allocator;
    const source = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(source);
    @memcpy(source[0..12], "https://e.c/");
    @memset(source[12..], ')');
    _ = try buildHostile(source);

    // Balanced-paren URL of the same size — the keep path.
    @memset(source[12..], '(');
    @memset(source[12 + (source.len - 12) / 2 ..], ')');
    _ = try buildHostile(source);
}

test "hostile: unterminated fences, HTML soup, and stray closers stay valid" {
    _ = try buildHostile(
        \\```zig
        \\fence with no close, ever
        \\| a | b |
        \\<details>
    );
    _ = try buildHostile(
        \\<div class="x"><span>soup</span><table><tr><td>no
        \\</details></summary><details open><DETAILS><summary>
        \\<script>alert(1)</script><!-- comment --><br/><hr>
        \\<summary>orphan</summary>
        \\</details>
    );
    _ = try buildHostile("<details>\n<summary>unclosed forever");
    // Delimiter row with no header above it.
    _ = try buildHostile("| --- | --- |\n| a | b |\n");
}

test "hostile: NUL bytes and invalid UTF-8 degrade to renderable text" {
    // Real invalid sequences: NUL, lone continuation, truncated lead,
    // CESU surrogate half, overlong encoding, and 0xFF. The mapper is
    // byte-oriented (bytes pass through to spans); the text pipeline must
    // measure and render them by UTF-8 scalar with fallback glyphs.
    const nasty = "plain \x00 nul **bo\x80ld** `co\xc3de` [li\xed\xa0\x80nk](https://e.com) \xc0\xaf over \xff end";
    const result = try buildHostile(nasty);
    try testing.expect(result.widgets > 0);
    try renderHostile(nasty);

    // A NUL-ridden fenced block keeps its bytes (zero-copy slice).
    _ = try buildHostile("```\n\x00\x00\x00\x01\x02\xfe\xff\n```\n");
}

test "hostile: mixed RTL, CJK, emoji, and ZWJ sequences render" {
    const mixed =
        \\# שלום עולם — مرحبا بالعالم
        \\
        \\日本語テキストと**한국어 텍스트**が *مختلطة مع العربية* です。
        \\
        \\Family: 👨‍👩‍👧‍👦 flags: 🏳️‍🌈 skin: 👍🏽 combining: éé́́ zalgo: h̸̡̪̯ͨ͊̽̅̾̎e̸̢̪̯ͨ͊̽̅̾̎
        \\
        \\| עמודה | 列 | 🙂 |
        \\| --- | --- | --- |
        \\| ‏RTL‏ | 值 | 👨‍👩‍👧‍👦 |
    ;
    const result = try buildHostile(mixed);
    try testing.expect(result.widgets > 0);
    try renderHostile(mixed);
}

test "hostile: five-megabyte document builds bounded and fast" {
    const allocator = testing.allocator;
    const source = try allocator.alloc(u8, 5 * 1024 * 1024);
    defer allocator.free(source);

    // Worst realistic shape: one paragraph the whole way down (no blank
    // lines, so the 64-block cap cannot save the parse early).
    @memset(source, 'm');
    var index: usize = 60;
    while (index < source.len) : (index += 61) source[index] = '\n';
    _ = try buildHostile(source);

    // And the block-heavy shape: parsing stops at the container cap.
    var stream = std.Io.Writer.fixed(source);
    while (stream.buffered().len + 64 < source.len) {
        try stream.writeAll("# heading\n\nparagraph body with **bold** text\n\n- item one\n- item two\n\n");
    }
    _ = try buildHostile(stream.buffered());
}

// ------------------------------------------------------------- generator

/// Hostile fragment producers for the seed-pinned generator. Each writes
/// one document fragment; the fuzz loop splices a random handful together
/// and builds the result. Deterministic: fixed seed, fixed sizes.
const Fragment = enum {
    deep_quotes,
    deep_list,
    wide_table,
    long_word,
    bracket_run,
    angle_run,
    star_run,
    fence_open,
    html_soup,
    nul_run,
    invalid_utf8,
    unicode_soup,
    url_paren_tail,
    issue_refs,
    details_open,
    details_close,
    blank,

    fn emit(self: Fragment, stream: *std.Io.Writer, random: std.Random) !void {
        switch (self) {
            .deep_quotes => {
                const depth = random.intRangeAtMost(usize, 1, 120);
                for (0..depth) |_| try stream.writeAll(">");
                try stream.writeAll(" quoted\n");
            },
            .deep_list => {
                const depth = random.intRangeAtMost(usize, 0, 40);
                for (0..depth) |_| try stream.writeAll("  ");
                try stream.writeAll("- [x] item **b** `c`\n");
            },
            .wide_table => {
                const columns = random.intRangeAtMost(usize, 1, 12);
                const rows = random.intRangeAtMost(usize, 1, 80);
                for (0..rows + 2) |row| {
                    for (0..columns) |_| {
                        try stream.writeAll(if (row == 1) "| --- " else "| `c` \\| **b** ");
                    }
                    try stream.writeAll("|\n");
                }
            },
            .long_word => {
                const length = random.intRangeAtMost(usize, 100, 4000);
                for (0..length) |_| try stream.writeAll("w");
                try stream.writeAll("\n");
            },
            .bracket_run => {
                const length = random.intRangeAtMost(usize, 10, 2000);
                for (0..length) |_| try stream.writeAll("[");
                if (random.boolean()) try stream.writeAll("]");
                try stream.writeAll("\n");
            },
            .angle_run => {
                const length = random.intRangeAtMost(usize, 10, 2000);
                for (0..length) |_| try stream.writeAll("<");
                if (random.boolean()) try stream.writeAll(">");
                try stream.writeAll("\n");
            },
            .star_run => {
                const length = random.intRangeAtMost(usize, 10, 2000);
                for (0..length) |_| try stream.writeAll(if (random.boolean()) "*" else "_");
                try stream.writeAll("\n");
            },
            .fence_open => try stream.writeAll("```zig\nunterminated\n"),
            .html_soup => try stream.writeAll("<div><span a=\"b\"><script>x</script></summary></details><details>\n"),
            .nul_run => {
                const length = random.intRangeAtMost(usize, 1, 64);
                for (0..length) |_| try stream.writeAll("\x00");
                try stream.writeAll("\n");
            },
            .invalid_utf8 => try stream.writeAll("\x80\xc3\xed\xa0\x80\xc0\xaf\xff\xfe\n"),
            .unicode_soup => try stream.writeAll("שלום 日本語 👨‍👩‍👧‍👦 🏳️‍🌈 é́́ مرحبا\n"),
            .url_paren_tail => {
                try stream.writeAll("https://e.com/x");
                const length = random.intRangeAtMost(usize, 1, 500);
                for (0..length) |_| try stream.writeAll(")");
                try stream.writeAll("\n");
            },
            .issue_refs => {
                const count = random.intRangeAtMost(usize, 1, 200);
                for (0..count) |_| try stream.writeAll("#123 ");
                try stream.writeAll("\n");
            },
            .details_open => try stream.writeAll("<details>\n<summary>s **b**</summary>\n"),
            .details_close => try stream.writeAll("</details>\n"),
            .blank => try stream.writeAll("\n"),
        }
    }
};

test "hostile: seed-pinned fuzz corpus builds bounded trees" {
    const allocator = testing.allocator;
    const buffer = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(buffer);

    // Fixed seed: the corpus is identical on every run and every machine.
    var prng = std.Random.DefaultPrng.init(0x6d61726b646f776e);
    const random = prng.random();
    const fragments = std.enums.values(Fragment);

    for (0..48) |_| {
        var stream = std.Io.Writer.fixed(buffer);
        const count = random.intRangeAtMost(usize, 3, 40);
        for (0..count) |_| {
            const fragment = fragments[random.intRangeAtMost(usize, 0, fragments.len - 1)];
            fragment.emit(&stream, random) catch break; // buffer full: use what fits
        }
        _ = try buildHostile(stream.buffered());
    }
}
