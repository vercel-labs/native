const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_spans = @import("text_spans.zig");
const text_metrics = @import("text_metrics.zig");
const ui_model = @import("ui.zig");

const testing = std.testing;
const TextSpan = text_spans.TextSpan;
const TextSpanRun = text_spans.TextSpanRun;

fn layout(spans: []const TextSpan, options: text_spans.TextSpanLayoutOptions, storage: []TextSpanRun) text_spans.TextSpanLayout {
    return text_spans.layoutTextSpans(spans, options, storage);
}

test "single span word-wraps deterministically with the estimator" {
    const spans = [_]TextSpan{.{ .text = "Hello world" }};
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 50 }, &runs);

    try testing.expectEqual(@as(usize, 2), result.line_count);
    try testing.expectEqual(@as(usize, 2), result.runs.len);
    try testing.expectEqualStrings("Hello", result.runs[0].text);
    try testing.expectEqualStrings("world", result.runs[1].text);
    try testing.expectEqual(@as(usize, 0), result.runs[0].line_index);
    try testing.expectEqual(@as(usize, 1), result.runs[1].line_index);
    try testing.expectEqual(@as(f32, 0), result.runs[1].x);
    try testing.expect(!result.truncated);
    try testing.expectEqual(@as(f32, 2 * 14 * 1.25), result.size.height);
}

test "wide layout keeps a single merged run per span" {
    const spans = [_]TextSpan{.{ .text = "Hello world" }};
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 10_000 }, &runs);

    try testing.expectEqual(@as(usize, 1), result.line_count);
    try testing.expectEqual(@as(usize, 1), result.runs.len);
    try testing.expectEqualStrings("Hello world", result.runs[0].text);
}

test "a word crossing a style boundary wraps as one unit" {
    // "brave" + "new" abut with no whitespace: "bravenew" must never split
    // at the span boundary, so both pieces move to line 2 together.
    const spans = [_]TextSpan{
        .{ .text = "Hello " },
        .{ .text = "brave", .weight = .bold },
        .{ .text = "new", .italic = true },
    };
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 70 }, &runs);

    try testing.expectEqual(@as(usize, 2), result.line_count);
    try testing.expectEqual(@as(usize, 3), result.runs.len);
    try testing.expectEqualStrings("Hello", result.runs[0].text);
    try testing.expectEqualStrings("brave", result.runs[1].text);
    try testing.expectEqualStrings("new", result.runs[2].text);
    try testing.expectEqual(@as(usize, 1), result.runs[1].line_index);
    try testing.expectEqual(@as(usize, 1), result.runs[2].line_index);
    // The italic piece starts exactly where the bold piece ends.
    try testing.expectEqual(result.runs[1].x + result.runs[1].width, result.runs[2].x);
    // Styles map to the reserved sans variant ids.
    try testing.expectEqual(canvas.default_sans_bold_font_id, result.runs[1].font_id);
    try testing.expectEqual(canvas.default_sans_italic_font_id, result.runs[2].font_id);
}

test "mono spans measure and draw with the mono font id" {
    const spans = [_]TextSpan{
        .{ .text = "run " },
        .{ .text = "zig build", .monospace = true },
    };
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 10_000 }, &runs);
    try testing.expectEqual(@as(usize, 2), result.runs.len);
    try testing.expectEqual(canvas.default_mono_font_id, result.runs[1].font_id);
    // Mono estimator advance: 0.6em per scalar.
    try testing.expectApproxEqAbs(@as(f32, 9 * 14 * 0.6), result.runs[1].width, 0.01);
}

const FakeMeasure = struct {
    calls: usize = 0,
    mono_calls: usize = 0,

    fn measure(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
        _ = size;
        const self: *FakeMeasure = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (font_id == canvas.default_mono_font_id) self.mono_calls += 1;
        // Ten pixels per byte regardless of font: predictable break math.
        return @floatFromInt(text.len * 10);
    }
};

test "layout measures per-run through an injected provider" {
    var fake = FakeMeasure{};
    const provider = text_metrics.TextMeasureProvider{ .context = &fake, .measure_fn = FakeMeasure.measure };

    const spans = [_]TextSpan{
        .{ .text = "alpha " },
        .{ .text = "beta", .monospace = true },
    };
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    // 10px per byte: "alpha" is 50px, the mono "beta" is 40px. At 60px the
    // provider-driven break puts "beta" on line 2.
    const result = layout(&spans, .{ .size = 14, .max_width = 60, .measure = &provider }, &runs);

    try testing.expect(fake.calls > 0);
    try testing.expect(fake.mono_calls > 0);
    try testing.expectEqual(@as(usize, 2), result.line_count);
    try testing.expectEqualStrings("alpha", result.runs[0].text);
    try testing.expectEqual(@as(f32, 50), result.runs[0].width);
    try testing.expectEqualStrings("beta", result.runs[1].text);
    try testing.expectEqual(@as(f32, 40), result.runs[1].width);
    try testing.expectEqual(@as(usize, 1), result.runs[1].line_index);
}

fn expectSameSpanLayout(a: text_spans.TextSpanLayout, b: text_spans.TextSpanLayout) !void {
    try testing.expectEqual(a.line_count, b.line_count);
    try testing.expectEqual(a.line_height, b.line_height);
    try testing.expectEqual(a.size.width, b.size.width);
    try testing.expectEqual(a.size.height, b.size.height);
    try testing.expectEqual(a.truncated, b.truncated);
    try testing.expectEqual(a.runs.len, b.runs.len);
    for (a.runs, b.runs) |left, right| {
        try testing.expectEqual(left.span_index, right.span_index);
        try testing.expectEqualStrings(left.text, right.text);
        try testing.expectEqual(left.line_index, right.line_index);
        try testing.expectEqual(left.x, right.x);
        try testing.expectEqual(left.width, right.width);
        try testing.expectEqual(left.baseline, right.baseline);
        try testing.expectEqual(left.size, right.size);
        try testing.expectEqual(left.font_id, right.font_id);
    }
}

test "background is measurement-neutral in both measure paths" {
    const plain = [_]TextSpan{
        .{ .text = "alpha " },
        .{ .text = "beta gamma", .monospace = true },
    };
    var tinted = plain;
    tinted[0].background = .success;
    tinted[1].background = .warning;

    // Estimator path (no injected provider).
    var estimator_plain: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    var estimator_tinted: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const estimator_options = text_spans.TextSpanLayoutOptions{ .size = 14, .max_width = 60 };
    try expectSameSpanLayout(
        layout(&plain, estimator_options, &estimator_plain),
        layout(&tinted, estimator_options, &estimator_tinted),
    );
    try testing.expectEqual(
        text_spans.textSpansIntrinsicWidth(&plain, estimator_options),
        text_spans.textSpansIntrinsicWidth(&tinted, estimator_options),
    );

    // Injected provider path.
    var fake = FakeMeasure{};
    const provider = text_metrics.TextMeasureProvider{ .context = &fake, .measure_fn = FakeMeasure.measure };
    var provider_plain: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    var provider_tinted: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const provider_options = text_spans.TextSpanLayoutOptions{ .size = 14, .max_width = 60, .measure = &provider };
    try expectSameSpanLayout(
        layout(&plain, provider_options, &provider_plain),
        layout(&tinted, provider_options, &provider_tinted),
    );
    try testing.expectEqual(
        text_spans.textSpansIntrinsicWidth(&plain, provider_options),
        text_spans.textSpansIntrinsicWidth(&tinted, provider_options),
    );
}

test "explicit newlines break lines and empty spans are skipped" {
    const spans = [_]TextSpan{
        .{ .text = "one\ntwo" },
        .{ .text = "" },
        .{ .text = " three" },
    };
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 10_000 }, &runs);

    try testing.expectEqual(@as(usize, 2), result.line_count);
    try testing.expectEqualStrings("one", result.runs[0].text);
    try testing.expectEqual(@as(usize, 1), result.runs[1].line_index);
}

test "an oversized word cluster-wraps instead of overflowing" {
    const spans = [_]TextSpan{.{ .text = "aaaaaaaaaaaaaaaaaaaa" }};
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 40 }, &runs);
    try testing.expect(result.line_count > 1);
    var total: usize = 0;
    for (result.runs) |run| {
        try testing.expect(run.width <= 40 + 14); // one cluster of slack
        total += run.text.len;
    }
    try testing.expectEqual(@as(usize, 20), total);
}

test "center alignment shifts whole lines" {
    const spans = [_]TextSpan{.{ .text = "hi" }};
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 100, .alignment = .center }, &runs);
    try testing.expectEqual(@as(usize, 1), result.runs.len);
    const expected = (100 - result.runs[0].width) * 0.5;
    try testing.expectApproxEqAbs(expected, result.runs[0].x, 0.001);
}

test "span capacity truncates deterministically" {
    var spans: [text_spans.max_text_spans_per_paragraph + 4]TextSpan = undefined;
    for (&spans) |*span| span.* = .{ .text = "x " };
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 10_000 }, &runs);
    try testing.expect(result.truncated);
    try testing.expect(result.runs.len <= text_spans.max_text_span_runs_per_paragraph);
}

test "heading scale raises line height and baseline" {
    const spans = [_]TextSpan{.{ .text = "Title", .weight = .bold, .scale = 2 }};
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 10_000 }, &runs);
    try testing.expectEqual(@as(f32, 14 * 2 * 1.25), result.line_height);
    try testing.expectEqual(@as(f32, 28), result.runs[0].size);
    try testing.expectEqual(@as(f32, 28), result.runs[0].baseline);
}

test "link bounds union the link span's runs" {
    const spans = [_]TextSpan{
        .{ .text = "see " },
        .{ .text = "the docs", .link = "https://example.com" },
    };
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 10_000 }, &runs);
    const bounds = text_spans.textSpanBounds(result, 1).?;
    try testing.expectEqual(@as(f32, 0), bounds.y);
    try testing.expectEqual(result.line_height, bounds.height);
    try testing.expectApproxEqAbs(result.runs[0].width, bounds.x, 0.001);
    try testing.expect(text_spans.textSpanBounds(result, 0) != null);
    try testing.expect(text_spans.textSpanBounds(result, 5) == null);
}

test "textSpansEqual compares style, text, and link bytes" {
    const a = [_]TextSpan{.{ .text = "x", .link = "https://a" }};
    var b = a;
    try testing.expect(text_spans.textSpansEqual(&a, &b));
    b[0].link = "https://b";
    try testing.expect(!text_spans.textSpansEqual(&a, &b));
    b[0] = .{ .text = "x", .weight = .bold };
    try testing.expect(!text_spans.textSpansEqual(&a, &b));
    b = a;
    b[0].background = .success;
    try testing.expect(!text_spans.textSpansEqual(&a, &b));
}

// ------------------------------------------------------------- widget path

const Msg = union(enum) {
    open: []const u8,
    noop,
};

const SpanUi = ui_model.Ui(Msg);

fn paragraphView(ui: *SpanUi) SpanUi.Node {
    const spans = [_]TextSpan{
        .{ .text = "Read " },
        .{ .text = "the guide", .link = "https://example.com/guide" },
        .{ .text = " and " },
        .{ .text = "the spec", .link = "https://example.com/spec" },
    };
    return ui.column(.{ .gap = 8 }, .{
        ui.paragraph(.{ .on_link = SpanUi.linkMsg(.open) }, &spans),
        ui.text(.{}, "plain trailer"),
    });
}

test "paragraph builds concatenated text, rebased spans, and link children" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = SpanUi.init(arena_state.allocator());
    const tree = try ui.finalize(paragraphView(&ui));

    const paragraph = tree.root.children[0];
    try testing.expectEqual(canvas.WidgetKind.text, paragraph.kind);
    try testing.expectEqualStrings("Read the guide and the spec", paragraph.text);
    try testing.expectEqual(@as(usize, 4), paragraph.spans.len);
    // Spans are subslices of the concatenated paragraph text.
    for (paragraph.spans) |span| {
        const base = @intFromPtr(paragraph.text.ptr);
        const ptr = @intFromPtr(span.text.ptr);
        try testing.expect(ptr >= base and ptr + span.text.len <= base + paragraph.text.len);
    }
    // One hit-area child per link span, with link semantics + press action.
    try testing.expectEqual(@as(usize, 2), paragraph.children.len);
    for (paragraph.children) |child| {
        try testing.expectEqual(canvas.WidgetRole.link, child.semantics.role);
        try testing.expect(child.semantics.actions.press);
        try testing.expect(child.semantics.focusable);
    }
    try testing.expectEqualStrings("the guide", paragraph.children[0].semantics.label);

    // Pressing a link child dispatches the on_link-built message.
    const msg = tree.msgForPointer(paragraph.children[1].id, .up).?;
    try testing.expectEqualStrings("https://example.com/spec", msg.open);
}

test "link children get span-derived frames and are hit-testable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = SpanUi.init(arena_state.allocator());
    const tree = try ui.finalize(paragraphView(&ui));

    var nodes: [32]canvas.WidgetLayoutNode = undefined;
    const bounds = geometry.RectF.init(0, 0, 400, 200);
    const tokens = canvas.DesignTokens{};
    const tree_layout = try canvas.layoutWidgetTreeWithTokens(tree.root, bounds, tokens, &nodes);

    const paragraph = tree.root.children[0];
    const first_link = paragraph.children[0];
    const link_node = tree_layout.findById(first_link.id).?;
    try testing.expect(link_node.frame.width > 0);
    try testing.expect(link_node.frame.height > 0);

    // A point inside the link frame hits the link, not the paragraph.
    const hit = tree_layout.hitTestWithTokens(link_node.frame.center(), tokens).?;
    try testing.expectEqual(first_link.id, hit.id);
    try testing.expectEqual(canvas.WidgetRole.link, hit.role);
    try testing.expectEqual(canvas.WidgetCursor.pointing_hand, canvas.cursorForWidgetHit(hit));

    // A point in the paragraph before the link hits the paragraph itself.
    const before = geometry.PointF.init(link_node.frame.x - 4, link_node.frame.center().y);
    const paragraph_hit = tree_layout.hitTestWithTokens(before, tokens).?;
    try testing.expectEqual(paragraph.id, paragraph_hit.id);
}

test "span paragraphs emit one text command per run plus link underlines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = SpanUi.init(arena_state.allocator());
    const tree = try ui.finalize(paragraphView(&ui));

    var nodes: [32]canvas.WidgetLayoutNode = undefined;
    const tokens = canvas.DesignTokens{};
    const tree_layout = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, 400, 200), tokens, &nodes);

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetLayout(&builder, tree_layout, tokens);
    const list = builder.displayList();

    var text_commands: usize = 0;
    var underlines: usize = 0;
    var accent_texts: usize = 0;
    for (list.commands) |command| {
        switch (command) {
            .draw_text => |value| {
                text_commands += 1;
                if (std.meta.eql(value.color, tokens.colors.accent)) accent_texts += 1;
            },
            .fill_rect => underlines += 1,
            else => {},
        }
    }
    // 4 spans on one wide line + the plain trailer text widget.
    try testing.expectEqual(@as(usize, 5), text_commands);
    try testing.expectEqual(@as(usize, 2), underlines);
    try testing.expectEqual(@as(usize, 2), accent_texts);
}

test "span backgrounds fill seamless full-line rects behind the glyphs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = SpanUi.init(arena_state.allocator());

    // A diff-style line: "middle" is one word whose two pieces carry the
    // same background but different styles, so it lays out as two abutting
    // runs (the intra-line diff-emphasis shape).
    const spans = [_]TextSpan{
        .{ .text = "left " },
        .{ .text = "mid", .background = .success },
        .{ .text = "dle", .background = .success, .weight = .bold },
        .{ .text = " right" },
    };
    const tree = try ui.finalize(ui.column(.{}, .{ui.paragraph(.{}, &spans)}));

    var nodes: [32]canvas.WidgetLayoutNode = undefined;
    const tokens = canvas.DesignTokens{};
    const tree_layout = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, 400, 200), tokens, &nodes);

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetLayout(&builder, tree_layout, tokens);
    const list = builder.displayList();

    var rects: [4]geometry.RectF = undefined;
    var rect_len: usize = 0;
    var last_rect_index: usize = 0;
    var first_text_index: ?usize = null;
    var tinted_text: ?canvas.DrawText = null;
    for (list.commands, 0..) |command, index| {
        switch (command) {
            .fill_rect => |value| {
                try testing.expectEqual(tokens.colors.success, value.fill.color);
                rects[rect_len] = value.rect;
                rect_len += 1;
                last_rect_index = index;
            },
            .draw_text => |value| {
                if (first_text_index == null) first_text_index = index;
                if (std.mem.eql(u8, value.text, "mid")) tinted_text = value;
            },
            else => {},
        }
    }

    // One background rect per tinted run, all before any glyphs.
    try testing.expectEqual(@as(usize, 2), rect_len);
    try testing.expect(last_rect_index < first_text_index.?);

    // Same-background neighbors share their snapped edge and line box:
    // no horizontal seam, identical top and height.
    try testing.expectEqual(rects[0].maxX(), rects[1].x);
    try testing.expectEqual(rects[0].y, rects[1].y);
    try testing.expectEqual(rects[0].height, rects[1].height);

    // The rect is the run's full line box: it starts at the tinted run's
    // origin and spans the whole line height around the baseline.
    const text = tinted_text.?;
    try testing.expectApproxEqAbs(text.origin.x, rects[0].x, 1);
    try testing.expect(rects[0].y <= text.origin.y - text.size * 0.5);
    try testing.expect(rects[0].maxY() >= text.origin.y);
    try testing.expect(rects[0].height >= text.size);
}

test "single-style text widgets keep their classic single-command path" {
    const widget = canvas.Widget{
        .id = 7,
        .kind = .text,
        .frame = geometry.RectF.init(0, 0, 200, 20),
        .text = "unchanged",
    };
    var commands: [8]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, widget, .{});
    const list = builder.displayList();
    try testing.expectEqual(@as(usize, 1), list.commands.len);
    const value = list.commands[0].draw_text;
    try testing.expectEqualStrings("unchanged", value.text);
    try testing.expect(value.text_layout != null);
}

test "paragraph intrinsic and wrapped extents drive stacked layout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = SpanUi.init(arena_state.allocator());

    const long_spans = [_]TextSpan{.{ .text = "one two three four five six seven eight nine ten eleven twelve" }};
    const tree = try ui.finalize(ui.column(.{}, .{
        ui.paragraph(.{}, &long_spans),
        ui.text(.{}, "below"),
    }));

    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    const tokens = canvas.DesignTokens{};
    const narrow = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, 120, 400), tokens, &nodes);

    const paragraph_node = narrow.findById(tree.root.children[0].id).?;
    const below_node = narrow.findById(tree.root.children[1].id).?;
    // The wrapped paragraph reserves more than one line and the trailer
    // starts below it (no overlap).
    try testing.expect(paragraph_node.frame.height > 14 * 1.25 * 2);
    try testing.expect(below_node.frame.y >= paragraph_node.frame.y + paragraph_node.frame.height - 0.001);
}

test "span selection maps points to paragraph offsets and back to rects" {
    const paragraph = "Hello world again";
    const spans = [_]TextSpan{
        .{ .text = paragraph[0..5], .weight = .bold },
        .{ .text = paragraph[5..] },
    };
    const options = text_spans.TextSpanLayoutOptions{ .size = 14, .max_width = 60 };
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, options, &runs);
    try testing.expect(result.line_count >= 2);

    // Left of the first run on line 0 clamps to offset 0.
    try testing.expectEqual(@as(usize, 0), text_spans.textSpanOffsetForPoint(paragraph, &spans, options, geometry.PointF.init(-5, 2)).?);
    // Far right of the last line clamps to the paragraph end.
    const bottom = @as(f32, @floatFromInt(result.line_count)) * result.line_height - 1;
    try testing.expectEqual(paragraph.len, text_spans.textSpanOffsetForPoint(paragraph, &spans, options, geometry.PointF.init(500, bottom)).?);
    // Below the paragraph clamps to the last line.
    try testing.expectEqual(paragraph.len, text_spans.textSpanOffsetForPoint(paragraph, &spans, options, geometry.PointF.init(500, bottom + 300)).?);

    // Whole-paragraph selection produces one rect per selected line.
    var rects: [8]canvas.TextSelectionRect = undefined;
    const selection = text_spans.textSpanSelectionRects(paragraph, &spans, options, .{ .start = 0, .end = paragraph.len }, &rects);
    try testing.expectEqual(result.line_count, selection.len);
    try testing.expectEqual(@as(usize, 0), selection[0].range.start);
    try testing.expectEqual(paragraph.len, selection[selection.len - 1].range.end);
    for (selection, 0..) |rect, index| {
        try testing.expectEqual(@as(f32, @floatFromInt(index)) * result.line_height, rect.rect.y);
        try testing.expect(rect.rect.width >= 1);
    }

    // A collapsed range selects nothing.
    try testing.expectEqual(@as(usize, 0), text_spans.textSpanSelectionRects(paragraph, &spans, options, .{ .start = 3, .end = 3 }, &rects).len);
}

test "span selection degrades to unsupported when spans alias other storage" {
    const paragraph = "Hello world";
    // Spans that do NOT slice into `paragraph` (a stack copy: the bytes
    // match but the storage differs — identical literals intern).
    var other: [11]u8 = "Hello world".*;
    const spans = [_]TextSpan{.{ .text = &other }};
    const options = text_spans.TextSpanLayoutOptions{ .size = 14 };
    try testing.expect(text_spans.textSpanOffsetForPoint(paragraph, &spans, options, geometry.PointF.init(5, 5)) == null);
    var rects: [4]canvas.TextSelectionRect = undefined;
    try testing.expectEqual(@as(usize, 0), text_spans.textSpanSelectionRects(paragraph, &spans, options, .{ .start = 0, .end = paragraph.len }, &rects).len);
}

// ------------------------------------------- measurement seam on run draws

/// A CoreText-shaped stand-in: mono at the exact 0.6 em design pitch,
/// sans at the estimator's advances minus a kerning residue — the
/// relationship the live macOS provider exhibits (its sans lines measure
/// 1.5–2.1% narrower than the kerning-free estimator).
const KernedMeasure = struct {
    fn measure(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
        _ = context;
        const estimated = text_metrics.estimateTextWidthForFont(font_id, text, size);
        if (font_id == canvas.default_mono_font_id) return estimated;
        return estimated * 0.98;
    }
};

test "span run draws carry the measurement seam their layout positioned with" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = SpanUi.init(arena_state.allocator());

    // The markdown shape that exposed the drift: prose + inline
    // code (mono) + prose on one line, plus a mono table-cell paragraph.
    const spans = [_]TextSpan{
        .{ .text = "keep the " },
        .{ .text = "experimental_", .monospace = true },
        .{ .text = " name" },
    };
    const tree = try ui.finalize(ui.column(.{}, .{ui.paragraph(.{}, &spans)}));

    const provider = text_metrics.TextMeasureProvider{ .measure_fn = KernedMeasure.measure };
    var tokens = canvas.DesignTokens{};
    tokens.text_measure = &provider;

    var nodes: [32]canvas.WidgetLayoutNode = undefined;
    const tree_layout = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, 600, 200), tokens, &nodes);

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetLayout(&builder, tree_layout, tokens);

    // Every run command carries layout options with the SAME provider the
    // run positions were measured with, and no wrap work (wrapping already
    // happened at the span level). The reference renderer walks these
    // advances, so a kerned prose run can no longer overpaint the mono
    // span that follows it (the swallowed inter-span space class).
    var text_commands: usize = 0;
    var mono_commands: usize = 0;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |value| {
                text_commands += 1;
                const options = value.text_layout orelse return error.TestUnexpectedResult;
                try testing.expectEqual(canvas.TextWrap.none, options.wrap);
                try testing.expectEqual(@as(?*const text_metrics.TextMeasureProvider, &provider), options.measure);
                if (value.font_id == canvas.default_mono_font_id) {
                    mono_commands += 1;
                    try testing.expectEqualStrings("experimental_", value.text);
                }
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), text_commands);
    try testing.expectEqual(@as(usize, 1), mono_commands);
}

test "provider-kerned prose runs never overlap the mono span that follows" {
    const provider = text_metrics.TextMeasureProvider{ .measure_fn = KernedMeasure.measure };
    const spans = [_]TextSpan{
        .{ .text = "all remaining " },
        .{ .text = "experimental_", .monospace = true },
        .{ .text = " APIs" },
    };
    var runs: [text_spans.max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const result = layout(&spans, .{ .size = 14, .max_width = 10_000, .measure = &provider }, &runs);

    try testing.expectEqual(@as(usize, 3), result.runs.len);
    for (result.runs[0 .. result.runs.len - 1], result.runs[1..]) |left, right| {
        // Runs abut exactly at their provider-measured widths...
        try testing.expectApproxEqAbs(left.x + left.width, right.x, 0.01);
        // ...and the drawn width equals the measured width when the draw
        // walks the same provider (the seam the emitted commands carry),
        // so painted ink ends where the next run begins.
        const drawn = text_metrics.measureTextWidthForFont(&provider, left.font_id, left.text, left.size);
        try testing.expectApproxEqAbs(left.width, drawn, 0.01);
    }
}
