//! Compiled scalar decisions against the independent native text seam.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const scalar = c.text_scalar_policy;
fn exactFloat(expected: f32, actual: f32) !void {
    if (std.math.isNan(expected)) return std.testing.expect(std.math.isNan(actual));
    try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual)));
}
fn corpus(bytes: []const u8) !void {
    for ([_]u64{ 0, 1, 2, 3, 4, 5, 6, 64, 0x100000002, 0xf123456789abcdef }) |font| {
        for ([_]f32{ 0, -0.0, 0.125, -13.25, 13.25, 1000, std.math.inf(f32), std.math.nan(f32) }) |size| {
            try exactFloat(c.estimateTextWidthForFont(font, bytes, size), scalar.estimate(core.nativeWindowPolicy, font, bytes, size, false));
            try exactFloat(c.estimateTextAdvanceForBytes(font, bytes, size), scalar.estimate(core.nativeWindowPolicy, font, bytes, size, true));
            core.rt.frameReset();
        }
    }
}
test "compiled scalar text preserves malformed UTF8 font identities and every f32 step" {
    _ = core.initialModel();
    for ([_][]const u8{ "", "Hello world…", "café \u{2611} → 界 🙂", "\x00\x1f\x7f\xff", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x80", "\xf0\x80\x80", "\xc2A", "\x80\x81" }) |bytes| try corpus(bytes);
    var bytes: [4]u8 = undefined;
    for (0..256) |lead| {
        bytes = .{ @intCast(lead), 0x80, 0xbf, 0x80 };
        try corpus(&bytes);
    }
    // All fallback range edges and nearby covered glyphs: glyph coverage
    // must win over both width classes, even within a classified block.
    for ([_]u21{ 0x1100, 0x115f, 0x2190, 0x2bff, 0x2e80, 0x303e, 0x3041, 0x33ff, 0x3400, 0x4dbf, 0x4e00, 0x9fff, 0xa000, 0xa4cf, 0xa960, 0xa97f, 0xac00, 0xd7a3, 0xf900, 0xfaff, 0xfe10, 0xfe19, 0xfe30, 0xfe6f, 0xff00, 0xff60, 0xffe0, 0xffe6, 0x1f300, 0x1faff, 0x20000, 0x3fffd }) |edge| {
        for ([_]u21{ edge - 1, edge, edge + 1 }) |cp| {
            const n = try std.unicode.utf8Encode(cp, &bytes);
            try corpus(bytes[0..n]);
        }
    }
    const long = try std.testing.allocator.alloc(u8, 65537);
    defer std.testing.allocator.free(long);
    @memset(long, 'i');
    for ([_]u64{ 1, 2, 3, 4, 6 }) |font| try exactFloat(c.estimateTextWidthForFont(font, long, 13.25), scalar.estimate(core.nativeWindowPolicy, font, long, 13.25, false));
    core.rt.frameReset();
}
const Trace = struct { calls: usize = 0, answer: f32 = 0, ink_calls: usize = 0, accept: bool = false, bounds: c.TextInkMetrics = .{}, digest: [32]u8 = @splat(0) };
fn record(t: *Trace, kind: u8, font: u64, size: f32, bytes: []const u8) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&t.digest);
    hash.update(&.{kind});
    hash.update(std.mem.asBytes(&font));
    hash.update(std.mem.asBytes(&size));
    hash.update(bytes);
    hash.final(&t.digest);
}
fn measure(ctx: ?*anyopaque, font: u64, size: f32, bytes: []const u8) f32 {
    const t: *Trace = @ptrCast(@alignCast(ctx.?));
    t.calls += 1;
    record(t, 1, font, size, bytes);
    return t.answer;
}
fn ink(ctx: ?*anyopaque, font: u64, size: f32, bytes: []const u8, out: *c.TextInkMetrics) bool {
    const t: *Trace = @ptrCast(@alignCast(ctx.?));
    t.ink_calls += 1;
    record(t, 2, font, size, bytes);
    out.* = t.bounds;
    return t.accept;
}
test "compiled scalar text preserves provider acceptance empty admission and complete capability traces" {
    _ = core.initialModel();
    for ([_][]const u8{ "", "é… \xff", "abc" }) |text| for ([_]f32{ 0, -0.0, 12.25, -1, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |answer| {
        var traces: [2]Trace = @splat(.{ .answer = answer });
        var expected: f32 = undefined;
        for (0..2) |lane| {
            const provider: c.TextMeasureProvider = .{ .context = &traces[lane], .measure_fn = measure };
            const width = if (lane == 0) c.measureTextWidthForFont(&provider, 6, text, 13.25) else scalar.width(core.nativeWindowPolicy, &provider, 6, text, 13.25);
            if (lane == 0) expected = width else {
                try exactFloat(expected, width);
                try std.testing.expectEqual(traces[0].calls, traces[1].calls);
                try std.testing.expectEqual(@as(u32, @bitCast(traces[0].answer)), @as(u32, @bitCast(traces[1].answer)));
                try std.testing.expectEqualSlices(u8, &traces[0].digest, &traces[1].digest);
            }
            core.rt.frameReset();
        }
        try exactFloat(c.measureTextWidthForFont(null, 6, text, 13.25), scalar.width(core.nativeWindowPolicy, null, 6, text, 13.25));
    };
    core.rt.frameReset();
}
test "compiled scalar text owns ink admission and validates every complete returned bound" {
    _ = core.initialModel();
    for (0..12) |configuration| for ([_][]const u8{ "", "…abc\xff" }) |text| for ([_]bool{ false, true }) |accept| {
        var bounds: c.TextInkMetrics = .{ .min_x = -1, .max_x = 12, .min_y = -8, .max_y = 3 };
        if (configuration < 8) {
            const value = if (configuration % 2 == 0) std.math.inf(f32) else std.math.nan(f32);
            switch (configuration / 2) {
                0 => bounds.min_x = value,
                1 => bounds.max_x = value,
                2 => bounds.min_y = value,
                3 => bounds.max_y = value,
                else => unreachable,
            }
        } else if (configuration == 8) bounds.max_x = -2 else if (configuration == 9) bounds.max_y = -9;
        var traces: [2]Trace = @splat(.{ .bounds = bounds, .accept = accept });
        var expected: ?c.TextInkMetrics = undefined;
        for (0..2) |lane| {
            const provider: c.TextMeasureProvider = .{ .context = &traces[lane], .measure_fn = measure, .measure_ink_fn = if (configuration == 11) null else ink };
            const got = if (lane == 0) provider.measureInk(1, 13.25, text) else scalar.ink(core.nativeWindowPolicy, &provider, 1, text, 13.25);
            if (lane == 0) expected = got else {
                try std.testing.expectEqualDeep(expected, got);
                try std.testing.expectEqual(traces[0].ink_calls, traces[1].ink_calls);
                try std.testing.expectEqualSlices(u8, &traces[0].digest, &traces[1].digest);
            }
            core.rt.frameReset();
        }
    };
}
