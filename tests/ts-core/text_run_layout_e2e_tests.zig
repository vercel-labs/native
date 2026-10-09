//! Complete ordinary line, elision, caret and hit geometry comparisons.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const exact = @import("component_construction_e2e_tests.zig").exact;
const policy = c.text_run_policy;
fn compare(text: c.DrawText, options: c.TextLayoutOptions, capacity: usize) !void {
    errdefer std.debug.print("text run case bytes={any} glyphs={d} size={d} width={d} wrap={s} align={s} overflow={s} capacity={d}\n", .{ text.text, text.glyphs.len, text.size, options.max_width, @tagName(options.wrap), @tagName(options.alignment), @tagName(options.overflow), capacity });
    const sentinel: c.TextLine = .{ .text_start = 0x123456, .bounds = .{ .x = -777, .height = 333 }, .elided_text_len = 17 };
    var expected_lines: [400]c.TextLine = @splat(sentinel);
    var actual_lines: [400]c.TextLine = @splat(sentinel);
    var compiled_text = text;
    compiled_text.text_run_policy = core.nativeWindowPolicy;
    var compiled_options = options;
    compiled_options.text_run_policy = core.nativeWindowPolicy;
    if (compiled_text.text_layout) |*value| value.text_run_policy = core.nativeWindowPolicy;
    const expected = c.layoutTextRun(text, options, expected_lines[0..capacity]);
    const actual = c.layoutTextRun(compiled_text, compiled_options, actual_lines[0..capacity]);
    if (expected) |layout| {
        try exact(layout, try actual);
        core.rt.frameReset();
        try exact(layout, try actual);
    } else |err| try std.testing.expectError(err, actual);
    // Capacity failures preserve the exact prefix and untouched suffix.
    try exact(expected_lines, actual_lines);
    var a = c.TextLineIterator.init(text, options);
    var b = c.TextLineIterator.init(compiled_text, compiled_options);
    while (true) {
        const line = a.next();
        try exact(line, b.next());
        try std.testing.expectEqual(a.cursor, b.cursor);
        try std.testing.expectEqual(a.index, b.index);
        try std.testing.expectEqual(a.finished, b.finished);
        if (line == null) break;
    }
    // Streaming queries retain their original lack of a line-count cap.
    for ([_]usize{ 0, 1, text.text.len / 2, text.text.len, text.text.len + 3 }) |offset| {
        for (std.enums.values(c.TextCaretAffinity)) |affinity| try exact(c.layoutTextCaretRectWithAffinity(text, options, offset, affinity), c.layoutTextCaretRectWithAffinity(compiled_text, compiled_options, offset, affinity));
        if (expected) |layout| {
            for (std.enums.values(c.TextCaretAffinity)) |affinity| try exact(c.textCaretRectForLayoutWithAffinity(text, layout, offset, affinity), c.textCaretRectForLayoutWithAffinity(compiled_text, try actual, offset, affinity));
        } else |_| {}
    }
    for ([_]sdk.geometry.PointF{ .{}, .{ .x = 5, .y = 20 }, .{ .x = 60, .y = 31 }, .{ .x = 1000, .y = 10000 } }) |point| {
        try exact(c.layoutTextCaretPositionForPoint(text, options, point), c.layoutTextCaretPositionForPoint(compiled_text, compiled_options, point));
        if (expected) |layout| {
            try exact(c.textCaretPositionForLayoutPoint(text, layout, point), c.textCaretPositionForLayoutPoint(compiled_text, try actual, point));
        } else |_| {}
    }
    for ([_]usize{ 0, 1, 4, 400 }) |budget| {
        var ar: [400]c.TextSelectionRect = undefined;
        var br: [400]c.TextSelectionRect = undefined;
        try exact(c.layoutTextSelectionRects(text, options, .{ .start = 1, .end = text.text.len }, ar[0..budget]), c.layoutTextSelectionRects(compiled_text, compiled_options, .{ .start = 1, .end = text.text.len }, br[0..budget]));
        if (expected) |layout| {
            try exact(c.textSelectionRectsForLayout(text, layout, .{ .start = text.text.len, .end = 1 }, ar[0..budget]), c.textSelectionRectsForLayout(compiled_text, try actual, .{ .start = text.text.len, .end = 1 }, br[0..budget]));
        } else |_| {}
    }
}
fn run(bytes: []const u8) c.DrawText {
    return .{ .text = bytes, .size = 11.25, .font_id = c.default_sans_font_id, .origin = .{ .x = 3.25, .y = 14.5 }, .color = c.Color.rgba(1, 1, 1, 1) };
}
test "compiled text runs preserve complete plain lines overflow alignment and streaming geometry" {
    _ = core.initialModel();
    const inputs = [_][]const u8{ "", "a", "hello world", "  lead\tspace  tail  ", "word\n\n  line\n", "ab\r\ncd\ref", "é 🙂界\xff\x80\xc0!", "verylongunbrokenword" };
    for (inputs) |bytes| for (std.enums.values(c.TextWrap)) |wrap| for (std.enums.values(c.TextAlign)) |alignment| for (std.enums.values(c.TextOverflow)) |overflow| {
        for ([_]f32{ 0, 1, 12.25, 38, 96, std.math.inf(f32), std.math.nan(f32) }) |width| {
            try compare(run(bytes), .{ .max_width = width, .wrap = wrap, .alignment = alignment, .overflow = overflow }, 400);
        }
    };
    for ([_]usize{ 0, 1, 4 }) |capacity| try compare(run("line\n" ** 260), .{ .max_width = 60 }, capacity);
}
const Trace = struct {
    const Call = struct { kind: u8, start_hash: u64, len: usize, font: u64, size: f32 };
    calls: [16000]Call = undefined,
    len: usize = 0,
    batched: bool = false,
    ink_mode: u8 = 0,
    fn record(self: *Trace, kind: u8, font: u64, size: f32, text: []const u8) void {
        self.calls[self.len] = .{ .kind = kind, .font = font, .size = size, .len = text.len, .start_hash = std.hash.Wyhash.hash(0, text) };
        self.len += 1;
    }
    fn width(context: ?*anyopaque, font: u64, size: f32, bytes: []const u8) f32 {
        const self: *Trace = @ptrCast(@alignCast(context.?));
        self.record(1, font, size, bytes);
        var value: f32 = 0;
        for (bytes) |byte| value += @as(f32, @floatFromInt(byte % 5 + 1)) * size / 8;
        return value;
    }
    fn advances(context: ?*anyopaque, font: u64, size: f32, bytes: []const u8, out: []f32) bool {
        const self: *Trace = @ptrCast(@alignCast(context.?));
        self.record(2, font, size, bytes);
        if (!self.batched) return false;
        for (bytes, out) |byte, *value| value.* = @as(f32, @floatFromInt(byte % 5 + 1)) * size / 8;
        return true;
    }
    fn ink(context: ?*anyopaque, font: u64, size: f32, bytes: []const u8, out: *c.TextInkMetrics) bool {
        const self: *Trace = @ptrCast(@alignCast(context.?));
        self.record(3, font, size, bytes);
        out.* = .{ .min_x = -size * 0.5, .max_x = @as(f32, @floatFromInt(bytes.len)) * size, .min_y = -size * 0.75, .max_y = size * 1.5 };
        if (self.ink_mode == 2) out.max_x = std.math.nan(f32);
        if (self.ink_mode == 3) out.max_x = out.min_x;
        return self.ink_mode != 0;
    }
};
fn compareBounds(text: c.DrawText, batched: bool, ink_mode: u8, provider: bool) !void {
    errdefer std.debug.print("ink case bytes={d} glyphs={d} size={d} layout={any} batched={} ink={d} provider={}\n", .{ text.text.len, text.glyphs.len, text.size, text.text_layout, batched, ink_mode, provider });
    var a: Trace = .{ .batched = batched, .ink_mode = ink_mode };
    var b: Trace = .{ .batched = batched, .ink_mode = ink_mode };
    const ap: c.TextMeasureProvider = .{ .context = &a, .measure_fn = Trace.width, .measure_advances_fn = Trace.advances, .measure_ink_fn = Trace.ink };
    const bp: c.TextMeasureProvider = .{ .context = &b, .measure_fn = Trace.width, .measure_advances_fn = Trace.advances, .measure_ink_fn = Trace.ink };
    var ta = text;
    ta.measure = if (provider) &ap else null;
    var tb = ta;
    tb.measure = if (provider) &bp else null;
    tb.text_run_policy = core.nativeWindowPolicy;
    if (tb.text_layout) |*o| o.text_run_policy = core.nativeWindowPolicy;
    c.bumpTextMeasureGeneration();
    const expected = (c.CanvasCommand{ .draw_text = ta }).bounds();
    c.bumpTextMeasureGeneration();
    const actual = (c.CanvasCommand{ .draw_text = tb }).bounds();
    try exact(expected, actual);
    try exact(a.calls[0..a.len], b.calls[0..b.len]);
    core.rt.frameReset();
    try exact(expected, actual);
}
test "compiled text bounds preserve complete metrics ink unions and callback order" {
    _ = core.initialModel();
    for ([_][]const u8{ "", "a", "italic overhang  ", "é🙂\nlast", "line\n" ** 70 }) |bytes| {
        for ([_]bool{ false, true }) |provider| for ([_]bool{ false, true }) |batched| for (0..4) |ink_mode| {
            var text = run(bytes);
            try compareBounds(text, batched, @intCast(ink_mode), provider);
            for (std.enums.values(c.TextWrap)) |wrap| for ([_]f32{ 1, 20, 90 }) |width| {
                text.text_layout = .{ .max_width = width, .wrap = wrap, .alignment = .center };
                try compareBounds(text, batched, @intCast(ink_mode), provider);
            };
        };
    }
    var shaped = run("é🙂");
    shaped.glyphs = &.{ .{ .id = 1, .x = -3, .y = -2, .advance = 8 }, .{ .id = 2, .x = 12, .y = 4, .advance = 7 } };
    try compareBounds(shaped, false, 1, true);
    shaped.text_layout = .{ .max_width = 10, .wrap = .none };
    try compareBounds(shaped, false, 1, true);
}
test "compiled text runs preserve complete width and advance capability call order" {
    _ = core.initialModel();
    for ([_]bool{ false, true }) |batched| for (std.enums.values(c.TextWrap)) |wrap| for (std.enums.values(c.TextOverflow)) |overflow| {
        var a: Trace = .{ .batched = batched };
        var b: Trace = .{ .batched = batched };
        const ap: c.TextMeasureProvider = .{ .context = &a, .measure_fn = Trace.width, .measure_advances_fn = Trace.advances };
        const bp: c.TextMeasureProvider = .{ .context = &b, .measure_fn = Trace.width, .measure_advances_fn = Trace.advances };
        var ta = run("lead words  tail\n next\xff");
        ta.measure = &ap;
        var tb = ta;
        tb.measure = &bp;
        tb.text_run_policy = core.nativeWindowPolicy;
        const oa: c.TextLayoutOptions = .{ .max_width = 37.25, .measure = &ap, .wrap = wrap, .overflow = overflow };
        var ob = oa;
        ob.measure = &bp;
        ob.text_run_policy = core.nativeWindowPolicy;
        var al: [100]c.TextLine = undefined;
        var bl: [100]c.TextLine = undefined;
        c.bumpTextMeasureGeneration();
        const expected = try c.layoutTextRun(ta, oa, &al);
        c.bumpTextMeasureGeneration();
        const actual = try c.layoutTextRun(tb, ob, &bl);
        try exact(expected, actual);
        try exact(a.calls[0..a.len], b.calls[0..b.len]);
        // Query the same already-materialized line so font prefix calls
        // and cache reads compare independently from iterator traversal.
        for (expected.lines, actual.lines) |el, rl| {
            a.len = 0;
            b.len = 0;
            try exact(c.textLineCaretX(ta, el, 3), c.textLineCaretX(tb, rl, 3));
            try exact(a.calls[0..a.len], b.calls[0..b.len]);
        }
        core.rt.frameReset();
        try exact(expected, actual);
    };
}
test "compiled text runs preserve shaped explicit and proportional glyph layouts" {
    _ = core.initialModel();
    const glyphs = [_]c.Glyph{
        .{ .id = 1, .x = -1.25, .y = 0.25, .advance = 8, .text_start = 0, .text_len = 2 },
        .{ .id = 2, .x = 7, .y = -2, .advance = 3, .text_start = 2, .text_len = 1 },
        .{ .id = 3, .x = 10, .y = 1, .advance = 14, .text_start = 3, .text_len = 4 },
        .{ .id = 4, .x = 24, .y = 0, .advance = 5, .text_start = 7, .text_len = 1 },
        .{ .id = 5, .x = 29, .y = 0, .advance = 20, .text_start = 8, .text_len = 3 },
    };
    var text = run("é 🙂 界");
    for ([_]bool{ false, true }) |explicit| {
        var source = glyphs;
        if (!explicit) for (&source) |*glyph| {
            glyph.text_start = 0;
            glyph.text_len = 0;
        };
        text.glyphs = &source;
        for (std.enums.values(c.TextWrap)) |wrap| for (std.enums.values(c.TextAlign)) |alignment| for (std.enums.values(c.TextOverflow)) |overflow| for ([_]f32{ 0, 1, 12, 30, 90 }) |width| {
            try compare(text, .{ .wrap = wrap, .alignment = alignment, .overflow = overflow, .max_width = width }, 400);
        };
    }
}
test "compiled text runs preserve exceptional numeric words and complete line failures" {
    _ = core.initialModel();
    for ([_]u32{ 0, 0x80000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00037, 1 }) |word| {
        var text = run("abc def");
        text.size = @bitCast(word);
        for (std.enums.values(c.TextWrap)) |wrap| try compare(text, .{ .max_width = 12.25, .wrap = wrap, .line_height = @bitCast(word) }, 400);
    }
}
test "text run copied transport rejects corrupt storage and capability ranges" {
    var bytes: [527]u8 = @splat(0);
    bytes[0..8].* = .{ 54, 1, 0, 0, 1, 0, 0, 0 };
    std.mem.writeInt(u32, bytes[8..12], 524, .little);
    std.mem.writeInt(u32, bytes[12..16], bytes.len, .little);
    std.mem.writeInt(u32, bytes[16..20], @bitCast(@as(f32, 12)), .little);
    std.mem.writeInt(u32, bytes[28..32], @bitCast(@as(f32, 5)), .little);
    std.mem.writeInt(u32, bytes[36..40], 3, .little);
    @memcpy(bytes[524..], "abc");
    var reply: [512]u8 = undefined;
    _ = core.initialModel();
    try std.testing.expectEqual(reply.len, core.nativeWindowPolicy(&bytes, &reply));
    try std.testing.expect(policy.resultValid(&bytes, &reply));
    for ([_]usize{ 0, 8, 12, 36, 104, 108, 376 }) |at| {
        var damaged = reply;
        damaged[at] ^= 0xff;
        try std.testing.expect(!policy.resultValid(&bytes, &damaged));
    }
    for (376..512) |at| {
        var damaged = reply;
        damaged[at] = 1;
        try std.testing.expect(!policy.resultValid(&bytes, &damaged));
    }
    // A valid ink capability is invalid in line-planning mode.
    var wrong_mode = reply;
    std.mem.writeInt(u32, wrong_mode[96..100], 60, .little);
    std.mem.writeInt(u32, wrong_mode[100..104], 6, .little);
    try std.testing.expect(!policy.resultValid(&bytes, &wrong_mode));
    try std.testing.expect(!policy.resultValid(&bytes, reply[0..511]));
}
test "portable text planner context survives command copies without changing content identity" {
    _ = core.initialModel();
    var commands: [2]c.CanvasCommand = undefined;
    var builder = c.Builder.init(&commands);
    builder.text_run_policy = core.nativeWindowPolicy;
    const text = run("owned text");
    try builder.drawText(text);
    const copy = commands[0].draw_text;
    try std.testing.expect(copy.text_run_policy.? == core.nativeWindowPolicy);
    var lines_a: [10]c.TextLine = undefined;
    var lines_b: [10]c.TextLine = undefined;
    const expected = try c.layoutTextRun(text, .{}, &lines_a);
    const actual = try c.layoutTextRun(copy, .{}, &lines_b);
    try exact(expected, actual);
    const old_list: c.DisplayList = .{ .commands = &.{.{ .draw_text = text }} };
    const new_list = builder.displayList();
    var changes: [2]c.DiffChange = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try c.DisplayList.diff(old_list, new_list, &changes)).len);
    var old_plans: [1]c.TextLayoutPlan = undefined;
    var new_plans: [1]c.TextLayoutPlan = undefined;
    try exact(try old_list.textLayoutPlan(.{}, &old_plans, &lines_a), try new_list.textLayoutPlan(.{}, &new_plans, &lines_b));
    core.rt.frameReset();
    try exact(expected, actual);
}

test "compiled text query preserves prepared gaps empty layouts and complete output suffixes" {
    _ = core.initialModel();
    const text = run("é🙂 gap\nlast");
    var compiled = text;
    compiled.text_run_policy = core.nativeWindowPolicy;
    const lines = [_]c.TextLine{
        .{ .text_start = 0, .text_len = 2, .bounds = .{ .x = 3, .y = 0, .width = 11, .height = 14 }, .baseline = 10 },
        .{ .text_start = 2, .text_len = 4, .bounds = .{ .x = -5, .y = 14, .width = 17, .height = 12 }, .baseline = 24 },
        .{ .text_start = 10, .text_len = 4, .bounds = .{ .x = 9, .y = 35, .width = 20, .height = 0 }, .baseline = 45 },
    };
    for ([_][]const c.TextLine{ &.{}, lines[0..1], &lines }) |prepared| {
        const layout: c.TextLayout = .{ .lines = prepared };
        for (0..text.text.len + 3) |offset| for (std.enums.values(c.TextCaretAffinity)) |affinity| {
            try exact(c.textCaretRectForLayoutWithAffinity(text, layout, offset, affinity), c.textCaretRectForLayoutWithAffinity(compiled, layout, offset, affinity));
        };
        for ([_]sdk.geometry.PointF{ .{ .x = -20, .y = -20 }, .{ .x = 3, .y = 15 }, .{ .x = 999, .y = 999 } }) |point| {
            try exact(c.textCaretPositionForLayoutPoint(text, layout, point), c.textCaretPositionForLayoutPoint(compiled, layout, point));
        }
        for (0..4) |capacity| {
            const sentinel: c.TextSelectionRect = .{ .range = .{ .start = 1234, .end = 5678 }, .rect = .{ .x = 777, .height = -5 } };
            var a: [4]c.TextSelectionRect = @splat(sentinel);
            var b = a;
            try exact(c.textSelectionRectsForLayout(text, layout, .{ .start = text.text.len + 100, .end = 1 }, a[0..capacity]), c.textSelectionRectsForLayout(compiled, layout, .{ .start = text.text.len + 100, .end = 1 }, b[0..capacity]));
            try exact(a, b);
            core.rt.frameReset();
            try exact(a, b);
        }
    }
}

test "compiled text query preserves complete streaming and prepared font capability order" {
    _ = core.initialModel();
    for ([_]bool{ false, true }) |batched| for (std.enums.values(c.TextWrap)) |wrap| {
        var a: Trace = .{ .batched = batched };
        var b: Trace = .{ .batched = batched };
        const ap: c.TextMeasureProvider = .{ .context = &a, .measure_fn = Trace.width, .measure_advances_fn = Trace.advances };
        const bp: c.TextMeasureProvider = .{ .context = &b, .measure_fn = Trace.width, .measure_advances_fn = Trace.advances };
        var ta = run("lead words  tail\n next\xff");
        ta.measure = &ap;
        var tb = ta;
        tb.measure = &bp;
        tb.text_run_policy = core.nativeWindowPolicy;
        const oa: c.TextLayoutOptions = .{ .max_width = 17, .measure = &ap, .wrap = wrap };
        var ob = oa;
        ob.measure = &bp;
        ob.text_run_policy = core.nativeWindowPolicy;
        var storage: [100]c.TextLine = undefined;
        const prepared = try c.layoutTextRun(ta, oa, &storage);
        for (0..6) |query| {
            a.len = 0;
            b.len = 0;
            var ar: [2]c.TextSelectionRect = undefined;
            var br: [2]c.TextSelectionRect = undefined;
            c.bumpTextMeasureGeneration();
            switch (query) {
                0, 1 => {
                    const expected = if (query == 0) c.layoutTextCaretRectWithAffinity(ta, oa, 10, .downstream) else c.textCaretRectForLayoutWithAffinity(ta, prepared, 10, .downstream);
                    c.bumpTextMeasureGeneration();
                    const actual = if (query == 0) c.layoutTextCaretRectWithAffinity(tb, ob, 10, .downstream) else c.textCaretRectForLayoutWithAffinity(tb, prepared, 10, .downstream);
                    try exact(expected, actual);
                },
                2, 3 => {
                    const expected = if (query == 2) c.layoutTextSelectionRects(ta, oa, .{ .end = ta.text.len }, &ar) else c.textSelectionRectsForLayout(ta, prepared, .{ .end = ta.text.len }, &ar);
                    c.bumpTextMeasureGeneration();
                    const actual = if (query == 2) c.layoutTextSelectionRects(tb, ob, .{ .end = tb.text.len }, &br) else c.textSelectionRectsForLayout(tb, prepared, .{ .end = tb.text.len }, &br);
                    try exact(expected, actual);
                },
                4, 5 => {
                    const point: sdk.geometry.PointF = .{ .x = 9, .y = 10000 };
                    const expected = if (query == 4) c.layoutTextCaretPositionForPoint(ta, oa, point) else c.textCaretPositionForLayoutPoint(ta, prepared, point);
                    c.bumpTextMeasureGeneration();
                    const actual = if (query == 4) c.layoutTextCaretPositionForPoint(tb, ob, point) else c.textCaretPositionForLayoutPoint(tb, prepared, point);
                    try exact(expected, actual);
                },
                else => unreachable,
            }
            try exact(a.calls[0..a.len], b.calls[0..b.len]);
        }
    };
}

test "text query copied transport rejects unsafe output indices and malformed capabilities" {
    _ = core.initialModel();
    var packet: [1039]u8 = @splat(0);
    policy.initialize(packet[512..], 512, 0, run("abc"), .{ .max_width = 20 }, 0, 0, false, .{}, 0, 0);
    packet[0..6].* = .{ 55, 1, 0, 0, 0, 0 };
    std.mem.writeInt(u32, packet[8..12], 2, .little);
    std.mem.writeInt(u32, packet[12..16], packet.len, .little);
    std.mem.writeInt(u32, packet[40..44], packet.len, .little);
    std.mem.writeInt(u32, packet[520..524], packet.len - 3, .little);
    std.mem.writeInt(u32, packet[524..528], packet.len, .little);
    var result: [1024]u8 = undefined;
    try std.testing.expectEqual(result.len, core.nativeWindowPolicy(&packet, &result));
    const query = c.text_query_policy;
    try std.testing.expect(query.resultValid(&packet, &result));
    for ([_]usize{ 0, 8, 12, 40, 44, 80, 92, 96, 100, 124, 316, 440, 512, 515, 520, 524, 548, 556, 564, 612, 616, 620, 888 }) |at| {
        var corrupt = result;
        corrupt[at] ^= 0xff;
        try std.testing.expect(!query.resultValid(&packet, &corrupt));
    }
    for (440..512) |at| {
        var damaged = result;
        damaged[at] = 1;
        try std.testing.expect(!query.resultValid(&packet, &damaged));
    }
    // Even a structurally plausible store cannot escape the caller's
    // line capacity or be substituted for a font capability reply.
    var corrupt = result;
    std.mem.writeInt(u32, corrupt[80..84], 2, .little);
    std.mem.writeInt(u32, corrupt[84..88], 2, .little);
    std.mem.writeInt(u32, corrupt[100..104], 0, .little);
    std.mem.writeInt(u32, corrupt[124..128], 3, .little);
    try std.testing.expect(!query.resultValid(&packet, &corrupt));
    try std.testing.expect(!query.resultValid(&packet, result[0..1023]));
}
