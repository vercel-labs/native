//! Complete portable paragraphs, including measurement order and copied runs.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const exact = @import("component_construction_e2e_tests.zig").exact;
fn compare(spans: []const c.TextSpan, options: c.TextSpanLayoutOptions, first: usize, capacity: usize) !void {
    var ar: [192]c.TextSpanRun = undefined;
    var br: [192]c.TextSpanRun = undefined;
    var compiled = options;
    compiled.paragraph_policy = core.nativeWindowPolicy;
    const a = c.text_spans.layoutTextSpansFromLine(spans, options, first, ar[0..capacity]);
    const b = c.text_spans.layoutTextSpansFromLine(spans, compiled, first, br[0..capacity]);
    try exact(a, b);
    try exact(c.text_spans.textSpansIntrinsicWidth(spans, options), c.text_spans.textSpansIntrinsicWidth(spans, compiled));
    core.rt.frameReset();
    try exact(a, b);
}
test "compiled widget metric paragraphs preserve complete wrapping alignment paging and capacities" {
    _ = core.initialModel();
    const texts = [_][]const u8{ "", "hello world", "  lead\tspace  tail  ", "word\n\nline\n", "ab\r\ncd\ref", "é 🙂界\xff\x80\xc0!", "averylongunbrokenword" };
    for (texts) |text| {
        const spans = [_]c.TextSpan{ .{ .text = text, .weight = .bold }, .{ .text = " suffix ", .italic = true, .scale = 1.25 }, .{ .text = "\tcode\n  kept", .monospace = true } };
        for (std.enums.values(c.TextWrap)) |wrap| for (std.enums.values(c.TextAlign)) |alignment| for ([_]f32{ 0, 1, 12.25, 38, 96, std.math.inf(f32), std.math.nan(f32) }) |width| {
            for ([_]usize{ 0, 1, 4, 160, 192 }) |capacity| for ([_]usize{ 0, 1, 3 }) |first|
                try compare(&spans, .{ .size = 11, .wrap = wrap, .alignment = alignment, .max_width = width }, first, capacity);
        };
    }
}
const Measure = struct {
    const Call = struct { font: u64, size: f32, len: usize, hash: u64 };
    calls: [4096]Call = undefined,
    len: usize = 0,
    fn measure(context: ?*anyopaque, font: u64, size: f32, text: []const u8) f32 {
        const self: *Measure = @ptrCast(@alignCast(context.?));
        self.calls[self.len] = .{ .font = font, .size = size, .len = text.len, .hash = std.hash.Wyhash.hash(0, text) };
        self.len += 1;
        var width: f32 = 0;
        for (text) |byte| width += @as(f32, @floatFromInt(byte % 7 + 1)) * size / 12;
        return width;
    }
};
test "compiled widget metric paragraphs preserve exact provider calls and source ownership" {
    _ = core.initialModel();
    const spans = [_]c.TextSpan{ .{ .text = "tight kerning \r\nlongword界🙂" }, .{ .text = "next span", .weight = .bold, .scale = 2 }, .{ .text = " monospace\t", .monospace = true } };
    for ([_]usize{ 0, 2, 130 }) |first| {
        var a: Measure = .{};
        var b: Measure = .{};
        var ap: c.TextMeasureProvider = .{ .context = &a, .measure_fn = Measure.measure };
        var bp: c.TextMeasureProvider = .{ .context = &b, .measure_fn = Measure.measure };
        var ar: [160]c.TextSpanRun = undefined;
        var br: [160]c.TextSpanRun = undefined;
        const ao: c.TextSpanLayoutOptions = .{ .size = 13.25, .max_width = 37.25, .alignment = .center, .measure = &ap };
        var bo = ao;
        bo.measure = &bp;
        bo.paragraph_policy = core.nativeWindowPolicy;
        const al = c.text_spans.layoutTextSpansFromLine(&spans, ao, first, &ar);
        const bl = c.text_spans.layoutTextSpansFromLine(&spans, bo, first, &br);
        try exact(al, bl);
        try exact(a.calls[0..a.len], b.calls[0..b.len]);
        a.len = 0;
        b.len = 0;
        try exact(c.text_spans.textSpansIntrinsicWidth(&spans, ao), c.text_spans.textSpansIntrinsicWidth(&spans, bo));
        try exact(a.calls[0..a.len], b.calls[0..b.len]);
        core.rt.frameReset();
        try exact(al, bl);
    }
}
test "compiled widget metric paragraphs preserve all-span scale and bounded line pages" {
    _ = core.initialModel();
    var spans: [34]c.TextSpan = @splat(.{ .text = "x\n" });
    spans[33].scale = 4;
    try compare(&spans, .{ .size = 10 }, 0, 160);
    const long = [_]c.TextSpan{.{ .text = "row\n" ** 260 }};
    for ([_]usize{ 0, 120, 128, 255, 260 }) |first| try compare(&long, .{ .size = 12, .max_width = 80 }, first, 192);
}
test "compiled widget metric paragraphs preserve exceptional size scale and line-height words" {
    _ = core.initialModel();
    const words = [_]u32{ 0, 0x80000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00037, 1 };
    for (words) |size| for (words) |height| for (words) |scale| {
        const spans = [_]c.TextSpan{.{ .text = "ab cd\n", .scale = @bitCast(scale) }};
        try compare(&spans, .{ .size = @bitCast(size), .line_height = @bitCast(height), .max_width = 12.25 }, 0, 160);
    };
}
var paragraph_calls: usize = 0;
var cache_calls: [8]usize = @splat(0);
fn trackedPolicy(request: []const u8, output: []u8) usize {
    if (request[0] == 53) paragraph_calls += 1;
    if (request[0] == 58) cache_calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
test "compiled widget metric paragraphs keep retained cache owners distinct and rebase copied source" {
    _ = core.initialModel();
    c.bumpTextMeasureGeneration();
    var trace: Measure = .{};
    const provider: c.TextMeasureProvider = .{ .context = &trace, .measure_fn = Measure.measure };
    const spans = [_]c.TextSpan{.{ .text = "unique cache owner words" }};
    var a: [160]c.TextSpanRun = undefined;
    var b: [160]c.TextSpanRun = undefined;
    const reference_options: c.TextSpanLayoutOptions = .{ .size = 12, .measure = &provider, .max_width = 60 };
    var compiled = reference_options;
    compiled.paragraph_policy = trackedPolicy;
    const expected = c.text_spans.layoutTextSpans(&spans, reference_options, &a);
    paragraph_calls = 0;
    cache_calls = @splat(0);
    const actual = c.text_spans.layoutTextSpans(&spans, compiled, &b);
    try std.testing.expect(paragraph_calls > 0);
    for ([_]usize{ 3, 4, 5 }) |mode| try std.testing.expect(cache_calls[mode] > 0);
    try exact(expected, actual);
    core.rt.frameReset();
    var copied: ["unique cache owner words".len]u8 = undefined;
    @memcpy(&copied, spans[0].text);
    const fresh = [_]c.TextSpan{.{ .text = &copied }};
    trace.len = 0;
    paragraph_calls = 0;
    cache_calls = @splat(0);
    const hit = c.text_spans.layoutTextSpans(&fresh, compiled, &b);
    try exact(expected, hit);
    try std.testing.expectEqual(@as(usize, 0), trace.len);
    // A retained hit asks the owner to admit, look up and rebase the entry;
    // it never reruns the paragraph planner or measures the source.
    try std.testing.expectEqual(@as(usize, 0), paragraph_calls);
    try std.testing.expectEqual([8]usize{ 0, 0, 0, 1, 1, 0, 0, 1 }, cache_calls);
    for (hit.runs) |run| try std.testing.expect(@intFromPtr(run.text.ptr) >= @intFromPtr(&copied) and @intFromPtr(run.text.ptr) + run.text.len <= @intFromPtr(&copied) + copied.len);
}
