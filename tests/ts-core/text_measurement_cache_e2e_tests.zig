//! Independent native and compiled retention sequences, complete owned output
//! and provider call traces. Neither lane consumes the other's decisions.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const cache = c.text_measure_cache;
const exact = @import("component_construction_e2e_tests.zig").exact;
const policy = c.text_measurement_policy;
const Trace = struct { batch: u64 = 0, width: u64 = 0, decline: bool = false, invalid: bool = false, calls: [32]u8 = @splat(0) };
fn record(trace: *Trace, kind: u8, font: c.FontId, size: f32, text: []const u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&trace.calls);
    h.update(&.{kind});
    h.update(std.mem.asBytes(&font));
    h.update(std.mem.asBytes(&size));
    h.update(text);
    h.final(&trace.calls);
}
fn width(context: ?*anyopaque, font: c.FontId, size: f32, text: []const u8) f32 {
    const t: *Trace = @ptrCast(@alignCast(context.?));
    t.width += 1;
    record(t, 0, font, size, text);
    return @as(f32, @floatFromInt(text.len)) * size;
}
fn advances(context: ?*anyopaque, font: c.FontId, size: f32, text: []const u8, output: []f32) bool {
    const t: *Trace = @ptrCast(@alignCast(context.?));
    t.batch += 1;
    record(t, 1, font, size, text);
    if (t.decline) return false;
    for (text, 0..) |byte, i| output[i] = if (byte & 192 == 128) 0 else @as(f32, @floatFromInt((byte +% @as(u8, @truncate(font))) % 9 + 1)) * size;
    if (t.invalid and output.len > 0) output[output.len - 1] = std.math.nan(f32);
    return true;
}
const Observation = struct { present: bool, sum: f32, batch: u64, hits: u64, fetches: u64, advances_hash: [32]u8, calls_hash: [32]u8 };
fn fetch(provider: *const c.TextMeasureProvider, owner: ?policy.Policy, text: []const u8, font: c.FontId, size: f32, peek: bool, start_hits: u64, start_fetches: u64) Observation {
    const values = if (peek) cache.cachedTextRunAdvancesWithPolicy(provider, owner, font, size, text) else cache.textRunAdvancesWithPolicy(provider, owner, font, size, text);
    const t: *Trace = @ptrCast(@alignCast(provider.context.?));
    var digest: [32]u8 = @splat(0);
    if (values) |v| std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(v), &digest, .{});
    return .{ .advances_hash = digest, .calls_hash = t.calls, .present = values != null, .sum = if (values) |v| cache.advanceSliceWidth(v, 0, v.len) else -123, .batch = t.batch, .hits = c.textAdvanceHitCount() - start_hits, .fetches = c.textAdvanceFetchCount() - start_fetches };
}
fn sequence(owner: ?policy.Policy, out: []Observation) void {
    c.bumpTextMeasureGeneration();
    var t: Trace = .{};
    var p: c.TextMeasureProvider = .{ .context = &t, .measure_fn = width, .measure_advances_fn = advances };
    const hits = c.textAdvanceHitCount();
    const fetches = c.textAdvanceFetchCount();
    var bytes: [65537]u8 = @splat('x');
    const lengths = [_]usize{ 0, 1, 2048, 2049, 65536, 65537 };
    var n: usize = 0;
    for (lengths) |length| for ([_]bool{ true, false, true, false }) |peek| {
        out[n] = fetch(&p, owner, bytes[0..length], 0xf123456789abcdef, 13.25, peek, hits, fetches);
        n += 1;
    };
    // Overflow the hot set, revisit oldest/newest, then rewrite same address.
    for (0..270) |i| {
        std.mem.writeInt(u32, bytes[0..4], @intCast(i), .little);
        out[n] = fetch(&p, owner, bytes[0..4], 2, 0.125, false, hits, fetches);
        n += 1;
    }
    for ([_]u32{ 0, 1, 269, 14, 15, 269 }) |id| for ([_]bool{ true, false }) |peek| {
        std.mem.writeInt(u32, bytes[0..4], id, .little);
        out[n] = fetch(&p, owner, bytes[0..4], 2, 0.125, peek, hits, fetches);
        n += 1;
    };
    for ([_]f32{ 0, -0.0, 13.5 }) |size| {
        out[n] = fetch(&p, owner, bytes[0..3], 9, size, false, hits, fetches);
        n += 1;
    }
    t.invalid = true;
    for ([_]usize{ 10, 2049 }) |length| for ([_]bool{ false, true, false }) |peek| {
        out[n] = fetch(&p, owner, bytes[0..length], 77, 2.25, peek, hits, fetches);
        n += 1;
    };
    t.invalid = false;
    t.decline = true;
    for ([_]bool{ false, true, false }) |peek| {
        out[n] = fetch(&p, owner, bytes[0..8], 78, 12, peek, hits, fetches);
        n += 1;
    }
    t.decline = false;
    p.measure_advances_fn = null;
    out[n] = fetch(&p, owner, "", 1, 1, false, hits, fetches);
    n += 1;
    p.measure_advances_fn = advances;
    c.bumpTextMeasureGeneration();
    out[n] = fetch(&p, owner, bytes[0..2049], 0xf123456789abcdef, 13.25, true, hits, fetches);
    n += 1;
    std.debug.assert(n == out.len);
}
test "compiled widget metric measured cache preserves full fetch peek LRU oversize and failed-provider traces" {
    _ = core.initialModel();
    var expected: [320]Observation = undefined;
    var actual: [320]Observation = undefined;
    sequence(null, &expected);
    sequence(core.nativeWindowPolicy, &actual);
    try exact(expected, actual);
    core.rt.frameReset();
    sequence(core.nativeWindowPolicy, &actual);
    try exact(expected, actual);
}

test "compiled widget metric measured cache retains paragraphs and rebases complete runs onto current bytes" {
    _ = core.initialModel();
    var trace: Trace = .{};
    const provider: c.TextMeasureProvider = .{ .context = &trace, .measure_fn = width, .measure_advances_fn = advances };
    var text: [256]u8 = @splat('a');
    const spans = [_]c.TextSpan{ .{ .text = text[0..16] }, .{ .text = "second line\n\xff\x00世界", .monospace = true, .scale = 1.125 } };
    var a: [160]c.TextSpanRun = undefined;
    var b: [160]c.TextSpanRun = undefined;
    for ([_]usize{ 0, 1, 159, 160 }) |capacity| {
        for ([_]f32{ 0, 11.25, 180 }) |max_width| {
            for (std.enums.values(c.TextWrap)) |wrap| for (std.enums.values(c.TextAlign)) |alignment| {
                const options: c.TextSpanLayoutOptions = .{ .measure = &provider, .size = 13.5, .max_width = max_width, .wrap = wrap, .alignment = alignment };
                c.bumpTextMeasureGeneration();
                trace = .{};
                const hits_a = c.textSpanWrapCacheHitCount();
                const misses_a = c.textSpanWrapCacheMissCount();
                const expected = c.layoutTextSpans(&spans, options, a[0..capacity]);
                const first_trace = trace;
                _ = c.layoutTextSpans(&spans, options, a[0..capacity]);
                const native_trace = trace;
                const hits = c.textSpanWrapCacheHitCount() - hits_a;
                const misses = c.textSpanWrapCacheMissCount() - misses_a;
                c.bumpTextMeasureGeneration();
                core.rt.frameReset();
                trace = .{};
                var owned_options = options;
                owned_options.paragraph_policy = core.nativeWindowPolicy;
                const hits_b = c.textSpanWrapCacheHitCount();
                const misses_b = c.textSpanWrapCacheMissCount();
                const result = c.layoutTextSpans(&spans, owned_options, b[0..capacity]);
                try exact(expected, result);
                try exact(first_trace, trace);
                try exact(expected, c.layoutTextSpans(&spans, owned_options, b[0..capacity]));
                try exact(native_trace, trace);
                try std.testing.expectEqual(hits, c.textSpanWrapCacheHitCount() - hits_b);
                try std.testing.expectEqual(misses, c.textSpanWrapCacheMissCount() - misses_b);
                // Identical content at a new address must borrow from that address.
                var replacement = text;
                var relocated = spans;
                relocated[0].text = replacement[0..16];
                const rebased = c.layoutTextSpans(&relocated, owned_options, b[0..capacity]);
                for (rebased.runs) |run| if (run.span_index == 0) {
                    const base = @intFromPtr(replacement[0..16].ptr);
                    try std.testing.expect(@intFromPtr(run.text.ptr) >= base and @intFromPtr(run.text.ptr) + run.text.len <= base + 16);
                };
            };
        }
    }
}

test "compiled widget metric measured cache rebases full span budgets without narrow wire arithmetic" {
    _ = core.initialModel();
    var trace: Trace = .{};
    const provider: c.TextMeasureProvider = .{ .context = &trace, .measure_fn = width, .measure_advances_fn = advances };
    var spans: [33]c.TextSpan = undefined;
    for (&spans, 0..) |*span, i| span.* = .{ .text = if (i % 2 == 0) "first " else "second ", .monospace = i % 3 == 0 };
    var a: [160]c.TextSpanRun = undefined;
    var b: [160]c.TextSpanRun = undefined;
    for ([_]usize{ 15, 16, 31, 32, 33 }) |count| {
        const options: c.TextSpanLayoutOptions = .{ .measure = &provider, .size = 12.25, .max_width = 125 };
        c.bumpTextMeasureGeneration();
        const expected = c.layoutTextSpans(spans[0..count], options, &a);
        c.bumpTextMeasureGeneration();
        var compiled_options = options;
        compiled_options.paragraph_policy = core.nativeWindowPolicy;
        try exact(expected, c.layoutTextSpans(spans[0..count], compiled_options, &b));
        // The second layout takes the copied rebase protocol at the full budget.
        try exact(expected, c.layoutTextSpans(spans[0..count], compiled_options, &b));
        core.rt.frameReset();
    }
}
