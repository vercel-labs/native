//! Complete runtime provider outputs through the production compiled ABI.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const planner = c.registered_font_policy;
fn exactFloat(a: f32, b: f32) !void {
    if (std.math.isNan(a)) return std.testing.expect(std.math.isNan(b));
    try std.testing.expectEqual(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)));
}
fn exactInk(a: c.TextInkMetrics, b: c.TextInkMetrics) !void {
    try exactFloat(a.min_x, b.min_x);
    try exactFloat(a.max_x, b.max_x);
    try exactFloat(a.min_y, b.min_y);
    try exactFloat(a.max_y, b.max_y);
}
fn harness() !*sdk.TestHarness() {
    const h = try sdk.TestHarness().create(std.testing.allocator, .{ .size = .init(240, 140) });
    errdefer h.destroy(std.testing.allocator);
    try h.start(.{ .context = h, .name = "registered-font", .source = sdk.platform.WebViewSource.html("Fonts") });
    try h.runtime.registerCanvasFont(64, c.font_ttf.geist_mono_bytes);
    try h.runtime.registerCanvasFont(0xf123456789abcdef, c.font_ttf.geist_regular_bytes);
    return h;
}
fn compare(h: *sdk.TestHarness(), font: u64, text: []const u8, size: f32) !void {
    errdefer std.debug.print("font={x} size={x} bytes={x}\n", .{ font, @as(u32, @bitCast(size)), text });
    const provider = h.runtime.textMeasureProvider().?;
    const left = try std.testing.allocator.alloc(f32, text.len + 3);
    defer std.testing.allocator.free(left);
    const right = try std.testing.allocator.alloc(f32, text.len + 3);
    defer std.testing.allocator.free(right);
    @memset(left, 123.25);
    @memset(right, 123.25);
    var expected: c.TextInkMetrics = .{ .min_x = 1, .max_x = 2, .min_y = 3, .max_y = 4 };
    var actual = expected;
    h.runtime.text_cache_policy = null;
    const width = provider.measure_fn(provider.context, font, size, text);
    const admitted = provider.measure_advances_fn.?(provider.context, font, size, text, left);
    const ink = provider.measure_ink_fn.?(provider.context, font, size, text, &expected);
    h.runtime.text_cache_policy = core.nativeWindowPolicy;
    try exactFloat(width, provider.measure_fn(provider.context, font, size, text));
    try std.testing.expectEqual(admitted, provider.measure_advances_fn.?(provider.context, font, size, text, right));
    for (left, right) |a, b| try exactFloat(a, b);
    try std.testing.expectEqual(ink, provider.measure_ink_fn.?(provider.context, font, size, text, &actual));
    try exactInk(expected, actual);
    core.rt.frameReset();
}
test "compiled registered font provider preserves full widths byte advances ink and u64 identities" {
    _ = core.initialModel();
    const h = try harness();
    defer h.destroy(std.testing.allocator);
    for ([_]u64{ 0, 1, 2, 3, 4, 5, 6, 64, 65, 0x100000002, 0xf123456789abcdef }) |font|
        for ([_]f32{ 0, -0.0, 0.125, -13.25, 13.25, 1000, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |size|
            for ([_][]const u8{ "", "Hello world…", "café \u{2611} → 界 🙂", " \t\r\n", "\x00\x1f\x7f\xff", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x80", "\xf0\x80\x80", "\xc2A", "\x80\x81" }) |bytes| try compare(h, font, bytes, size);
}
test "compiled registered font traversal preserves every lead byte and complete fallback range edges" {
    _ = core.initialModel();
    const h = try harness();
    defer h.destroy(std.testing.allocator);
    var bytes: [4]u8 = undefined;
    for (0..256) |lead| {
        bytes = .{ @intCast(lead), 0x80, 0xbf, 0x80 };
        for ([_]u64{ 64, 0xf123456789abcdef }) |font| try compare(h, font, &bytes, 13.25);
    }
    for ([_]u21{ 0x1100, 0x115f, 0x2190, 0x2bff, 0x2e80, 0x303e, 0x3041, 0x33ff, 0x3400, 0x4dbf, 0x4e00, 0x9fff, 0xa000, 0xa4cf, 0xa960, 0xa97f, 0xac00, 0xd7a3, 0xf900, 0xfaff, 0xfe10, 0xfe19, 0xfe30, 0xfe6f, 0xff00, 0xff60, 0xffe0, 0xffe6, 0x1f300, 0x1faff, 0x20000, 0x3fffd }) |edge| {
        for ([_]u21{ edge - 1, edge, edge + 1 }) |cp| {
            const length = try std.unicode.utf8Encode(cp, &bytes);
            for ([_]u64{ 64, 0xf123456789abcdef }) |font| try compare(h, font, bytes[0..length], 13.25);
        }
    }
}
var actions: [128]u32 = undefined;
var action_count: usize = 0;
fn observed(request: []const u8, output: []u8) usize {
    const length = core.nativeWindowPolicy(request, output);
    const action = std.mem.readInt(u32, output[72..76], .little);
    if (action_count < actions.len) actions[action_count] = action;
    action_count += 1;
    return length;
}
test "compiled registered font outline failure stops capability order and preserves caller metrics" {
    _ = core.initialModel();
    const h = try harness();
    defer h.destroy(std.testing.allocator);
    h.runtime.canvas_font_faces[0].num_glyphs = 1;
    try compare(h, 64, " AB", 13.25);
    h.runtime.text_cache_policy = observed;
    action_count = 0;
    var bounds: c.TextInkMetrics = .{ .min_x = 1, .max_x = 2, .min_y = 3, .max_y = 4 };
    const provider = h.runtime.textMeasureProvider().?;
    try std.testing.expect(!provider.measure_ink_fn.?(provider.context, 64, 13.25, " AB", &bounds));
    try exactInk(.{ .min_x = 1, .max_x = 2, .min_y = 3, .max_y = 4 }, bounds);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 1, 2, 3, 4, 0 }, actions[0..action_count]);
}
test "compiled registered font long runs keep f32 addition order and complete byte placements" {
    _ = core.initialModel();
    const h = try harness();
    defer h.destroy(std.testing.allocator);
    const bytes = try std.testing.allocator.alloc(u8, 65537);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'i');
    for ([_]u64{ 2, 3, 64, 0xf123456789abcdef }) |font| try compare(h, font, bytes, 13.25);
}
test "compiled registered font copied transport rejects all unsafe indices and arena outputs stay owned" {
    _ = core.initialModel();
    var request: [128]u8 = @splat(0);
    request[0..5].* = .{ 62, 1, 1, 0, 1 };
    std.mem.writeInt(u32, request[8..12], 4, .little);
    std.mem.writeInt(u32, request[24..28], @bitCast(@as(f32, 1000)), .little);
    var result: [128]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 128), core.nativeWindowPolicy(&request, &result));
    try std.testing.expect(planner.resultValid(&request, &result));
    for ([_]usize{ 0, 1, 2, 3, 4, 8, 12, 20, 24, 28, 32, 36, 40, 44, 52, 72, 84, 104, 112, 116, 124 }) |at| {
        var bad = result;
        bad[at] = 255;
        try std.testing.expect(!planner.resultValid(&request, &bad));
    }
    for (0..128) |length| try std.testing.expect(!planner.resultValid(&request, result[0..length]));
    const saved = result;
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    _ = core.nativeView(view_arena.allocator());
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, &saved, &result);
    for (0..8) |_| _ = planner.measure(core.nativeWindowPolicy, &c.font_ttf.geist_mono, 64, "café →", 13.25, .width, &.{});
    try std.testing.expectEqualSlices(u8, &saved, &result);
}
