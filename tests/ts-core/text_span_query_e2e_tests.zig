//! Complete rich paragraph queries against independent native references.
const std = @import("std");
const geometry = @import("native_sdk").geometry;
const c = @import("native_sdk").canvas;
const core = @import("ts_persist_core");
const exact = @import("component_construction_e2e_tests.zig").exact;
const s = c.text_spans;
fn owned(options: c.TextSpanLayoutOptions) c.TextSpanLayoutOptions {
    var result = options;
    result.paragraph_policy = core.nativeWindowPolicy;
    return result;
}
const Trace = struct {
    const Call = struct { kind: u8, font: u64, size: f32, len: usize, hash: u64 };
    calls: [32768]Call = undefined,
    len: usize = 0,
    batched: bool = false,
    decline: bool = false,
    fn record(self: *Trace, kind: u8, font: u64, size: f32, text: []const u8) void {
        std.debug.assert(self.len < self.calls.len);
        self.calls[self.len] = .{ .kind = kind, .font = font, .size = size, .len = text.len, .hash = std.hash.Wyhash.hash(0, text) };
        self.len += 1;
    }
    fn advance(byte: u8) f32 {
        return if (byte == '~' or byte & 0xc0 == 0x80) 0 else if (byte == '\t') 2.125 else 5.25;
    }
    fn measure(context: ?*anyopaque, font: u64, size: f32, text: []const u8) f32 {
        const self: *Trace = @ptrCast(@alignCast(context.?));
        self.record(0, font, size, text);
        var width: f32 = 0;
        for (text) |byte| width += advance(byte);
        return width;
    }
    fn advances(context: ?*anyopaque, font: u64, size: f32, text: []const u8, output: []f32) bool {
        const self: *Trace = @ptrCast(@alignCast(context.?));
        self.record(1, font, size, text);
        if (self.decline) return false;
        if (output.len < text.len) return false;
        for (text, 0..) |byte, i| output[i] = advance(byte);
        return true;
    }
    fn provider(self: *Trace) c.TextMeasureProvider {
        return .{ .context = self, .measure_fn = measure, .measure_advances_fn = if (self.batched) advances else null };
    }
};
fn selection(paragraph: []const u8, spans: []const c.TextSpan, options: c.TextSpanLayoutOptions, range: c.TextRange, capacity: usize, trace: ?*Trace) !void {
    var a: [12]c.TextSelectionRect = @splat(.{ .range = .{ .start = 909, .end = 808 }, .rect = .init(77, 88, 99, 111) });
    var b = a;
    c.bumpTextMeasureGeneration();
    if (trace) |t| t.len = 0;
    const ar = s.textSpanSelectionRects(paragraph, spans, options, range, a[0..capacity]);
    const count = if (trace) |t| t.len else 0;
    var saved: [32768]Trace.Call = undefined;
    if (trace) |t| @memcpy(saved[0..count], t.calls[0..count]);
    c.bumpTextMeasureGeneration();
    if (trace) |t| t.len = 0;
    const br = s.textSpanSelectionRects(paragraph, spans, owned(options), range, b[0..capacity]);
    try std.testing.expectEqual(ar.len, br.len);
    try exact(a, b);
    if (trace) |t| {
        try std.testing.expectEqual(count, t.len);
        try exact(saved[0..count], t.calls[0..t.len]);
    }
    core.rt.frameReset();
    try exact(a, b);
}
fn point(paragraph: []const u8, spans: []const c.TextSpan, options: c.TextSpanLayoutOptions, value: geometry.PointF, trace: ?*Trace) !void {
    c.bumpTextMeasureGeneration();
    if (trace) |t| t.len = 0;
    const a = s.textSpanOffsetForPoint(paragraph, spans, options, value);
    const count = if (trace) |t| t.len else 0;
    var saved: [32768]Trace.Call = undefined;
    if (trace) |t| @memcpy(saved[0..count], t.calls[0..count]);
    c.bumpTextMeasureGeneration();
    if (trace) |t| t.len = 0;
    const b = s.textSpanOffsetForPoint(paragraph, spans, owned(options), value);
    try std.testing.expectEqual(a, b);
    if (trace) |t| {
        try std.testing.expectEqual(count, t.len);
        try exact(saved[0..count], t.calls[0..t.len]);
    }
    core.rt.frameReset();
}
test "compiled span query preserves clipping clusters malformed bytes and complete font order" {
    _ = core.initialModel();
    for ([_][]const u8{ "", "abc~~~~def", "é 🙂界\xff\x80\xc0!", "~~", "a\rb\tcdef" }) |text| {
        const span: c.TextSpan = .{ .text = text, .scale = 1.125, .weight = .bold };
        for ([_]u8{ 0, 1, 2, 3 }) |provider_kind| {
            var trace: Trace = .{ .batched = provider_kind > 1, .decline = provider_kind == 3 };
            const provider = trace.provider();
            const options: c.TextSpanLayoutOptions = .{ .size = 13, .measure = if (provider_kind == 0) null else &provider };
            const run: c.TextSpanRun = .{ .text = text, .width = 40.25, .size = 14.625, .font_id = c.default_sans_bold_font_id };
            for ([_]f32{ -10, 0, 1, 14.125, 45, std.math.nan(f32) }) |left| for ([_]f32{ -1, 8.5, 23.75, 60, std.math.inf(f32) }) |right| {
                c.bumpTextMeasureGeneration();
                trace.len = 0;
                const a = s.textSpanRunVisibleSlice(span, run, options, left, right);
                const count = trace.len;
                const saved = trace.calls;
                c.bumpTextMeasureGeneration();
                trace.len = 0;
                const b = s.textSpanRunVisibleSlice(span, run, owned(options), left, right);
                try exact(a, b);
                try std.testing.expectEqual(count, trace.len);
                try exact(saved[0..count], trace.calls[0..trace.len]);
                if (b) |slice| try std.testing.expect(@intFromPtr(slice.text.ptr) >= @intFromPtr(run.text.ptr) and @intFromPtr(slice.text.ptr) + slice.text.len <= @intFromPtr(run.text.ptr) + run.text.len);
                core.rt.frameReset();
                try exact(a, b);
            };
        }
    }
}
test "compiled span query preserves complete point selection source ranges and untouched suffixes" {
    _ = core.initialModel();
    for ([_][]const u8{ "", "hello world café 🙂界\xff\x80", "  a\tb  \n\nlast  \r\n", " \t\r\n  \n\t", "one\n\n\n" }) |paragraph| {
        const cut = @min(paragraph.len, 4);
        const spans = [_]c.TextSpan{ .{ .text = paragraph[0..cut], .weight = .bold }, .{ .text = paragraph[cut..], .monospace = true, .scale = 1.25 } };
        for ([_]bool{ false, true }) |batched| {
            var trace: Trace = .{ .batched = batched };
            const provider = trace.provider();
            for (std.enums.values(c.TextWrap)) |wrap| for (std.enums.values(c.TextAlign)) |alignment| {
                const options: c.TextSpanLayoutOptions = .{ .size = 11, .max_width = 29.5, .wrap = wrap, .alignment = alignment, .measure = &provider };
                for ([_]usize{ 0, 1, 2, 12 }) |capacity| for ([_]c.TextRange{ .{ .start = 0, .end = 9999 }, .{ .start = 19, .end = 3 }, .{ .start = 2, .end = 2 } }) |range|
                    try selection(paragraph, &spans, options, range, capacity, &trace);
                for ([_]f32{ -20, 0, 7.75, 28, 100 }) |x| for ([_]f32{ -30, 0, 17, 500 }) |y| try point(paragraph, &spans, options, .{ .x = x, .y = y }, &trace);
            };
        }
    }
}
test "compiled span query preserves detached and long unbatched run clipping" {
    _ = core.initialModel();
    var long: [8193]u8 = undefined;
    for (&long, 0..) |*byte, i| byte.* = if (i % 7 == 0) '~' else 'a';
    for ([_][]const u8{ "detached café 🙂 ~~~~run", &long }) |text| {
        for ([_]bool{ false, true }) |aliases| {
            const span: c.TextSpan = .{ .text = if (aliases) text else "different source" };
            var trace: Trace = .{ .batched = true };
            const provider = trace.provider();
            const options: c.TextSpanLayoutOptions = .{ .size = 12, .measure = &provider };
            const run: c.TextSpanRun = .{ .text = text, .width = @as(f32, @floatFromInt(text.len)) * 5.25, .size = 12 };
            c.bumpTextMeasureGeneration();
            const a = s.textSpanRunVisibleSlice(span, run, options, 28.25, 54.75);
            const count = trace.len;
            const saved = trace.calls;
            c.bumpTextMeasureGeneration();
            trace.len = 0;
            const b = s.textSpanRunVisibleSlice(span, run, owned(options), 28.25, 54.75);
            try exact(a, b);
            try std.testing.expectEqual(count, trace.len);
            try exact(saved[0..count], trace.calls[0..trace.len]);
            core.rt.frameReset();
            try exact(a, b);
        }
    }
}
test "compiled span query preserves logarithmic pages blank gaps and selection overflow" {
    _ = core.initialModel();
    var text: [2400]u8 = undefined;
    for (0..600) |line| @memcpy(text[line * 4 ..][0..4], if (line >= 128 and line < 384) "\n\n\n\n" else "abc\n");
    const spans = [_]c.TextSpan{.{ .text = &text }};
    const options: c.TextSpanLayoutOptions = .{ .size = 11, .line_height = 13.5, .max_width = 50 };
    for ([_]usize{ 0, 1, 2, 12 }) |capacity| for ([_]c.TextRange{ .{ .start = 0, .end = text.len }, .{ .start = 515, .end = 1700 }, .{ .start = 1900, .end = 2100 } }) |range|
        try selection(&text, &spans, options, range, capacity, null);
    for ([_]f32{ -10, 0, 1, 30, 300 }) |x| for ([_]f32{ 0, 128 * 13.5, 9000, 18000 }) |y| try point(&text, &spans, options, .{ .x = x, .y = y }, null);
}
test "compiled span query preserves unsupported paragraph aliases and runless whitespace" {
    _ = core.initialModel();
    const paragraph = "one\n  \t\nlast";
    const other = [_]c.TextSpan{.{ .text = "separate bytes" }};
    try selection(paragraph, &other, .{ .size = 11 }, .{ .end = 999 }, 2, null);
    try point(paragraph, &other, .{ .size = 11 }, .{ .x = 2 }, null);
    const whitespace = " \t\n \r\n\t";
    const spans = [_]c.TextSpan{.{ .text = whitespace }};
    for ([_]f32{ -1, 1, 50, 500 }) |x| for ([_]f32{ -1, 0, 1000 }) |y| try point(whitespace, &spans, .{ .size = 11, .max_width = 50 }, .{ .x = x, .y = y }, null);
}

test "compiled span query preserves aggregate bounds exact u64 rounding and numeric words" {
    _ = core.initialModel();
    const ids = [_]usize{ 0, 1, std.math.maxInt(usize) };
    const lines = [_]usize{ 0, 1, 16777217, 4294967295, (@as(usize, 1) << 63) + (@as(usize, 1) << 39) + 1, std.math.maxInt(usize) };
    for ([_]f32{ 0, 0.125, 13.5, std.math.inf(f32), std.math.nan(f32) }) |height| for (lines) |line| {
        const runs = [_]c.TextSpanRun{
            .{ .span_index = 1, .line_index = line, .x = -0.0, .width = 17.25 },
            .{ .span_index = 0, .line_index = 1, .x = -20, .width = 11 },
            .{ .span_index = 1, .line_index = 3, .x = -12.75, .width = 50.125 },
            .{ .span_index = std.math.maxInt(usize), .line_index = line, .x = std.math.nan(f32), .width = -3.5 },
        };
        const layout: c.TextSpanLayout = .{ .runs = &runs, .line_height = height };
        for (ids) |id| {
            const expected = s.textSpanBounds(layout, id);
            const actual = s.textSpanBoundsWithPolicy(layout, id, core.nativeWindowPolicy);
            try exact(expected, actual);
            core.rt.frameReset();
            try exact(expected, actual);
        }
    };
    try std.testing.expect(s.textSpanBoundsWithPolicy(.{}, 0, core.nativeWindowPolicy) == null);
}
test "span query copied transport rejects writes outside capacity and missing source ranges" {
    var request: [5648]u8 = @splat(0);
    request[0..4].* = .{ 56, 1, 0, 0 };
    std.mem.writeInt(u32, request[12..16], request.len, .little);
    std.mem.writeInt(u32, request[28..32], 1, .little);
    std.mem.writeInt(u32, request[32..36], 528, .little);
    var result: [512]u8 = undefined;
    @memcpy(&result, request[0..512]);
    result[3] = 1;
    std.mem.writeInt(u32, result[80..84], 2, .little);
    std.mem.writeInt(u32, result[108..112], 1, .little);
    try std.testing.expect(c.text_span_query_policy.resultValid(&request, &result));
    for (344..512) |at| {
        var damaged = result;
        damaged[at] = 1;
        try std.testing.expect(!c.text_span_query_policy.resultValid(&request, &damaged));
    }
    std.mem.writeInt(u32, result[108..112], 25, .little);
    try std.testing.expect(!c.text_span_query_policy.resultValid(&request, &result));
    std.mem.writeInt(u32, result[108..112], 1, .little);
    std.mem.writeInt(u32, result[84..88], 1, .little);
    try std.testing.expect(!c.text_span_query_policy.resultValid(&request, &result));
    std.mem.writeInt(u32, result[84..88], 0, .little);
    std.mem.writeInt(u32, result[80..84], 3, .little);
    std.mem.writeInt(u32, result[92..96], 1, .little);
    try std.testing.expect(!c.text_span_query_policy.resultValid(&request, &result));
    result[344] = 1;
    try std.testing.expect(!c.text_span_query_policy.resultValid(&request, &result));
    result[344] = 0;
    result[3] = 2;
    std.mem.writeInt(u32, result[80..84], 0, .little);
    std.mem.writeInt(u32, result[112..116], 1, .little);
    std.mem.writeInt(u32, result[120..124], 1, .little);
    try std.testing.expect(!c.text_span_query_policy.resultValid(&request, &result));
}
