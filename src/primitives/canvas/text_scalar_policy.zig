//! Copied scalar text transport. Native supplies font-table primitives and
//! OS callbacks; TypeScript owns admission, fallback and accumulation.
const std = @import("std");
const metrics = @import("text_metrics.zig");
const font_ttf = @import("font_ttf.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
fn put(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("scalar text integer range"), .little);
}
fn setFloat(bytes: []u8, at: usize, value: f32) void {
    put(bytes, at, @as(u32, @bitCast(value)));
}
fn initialize(bytes: []u8, mode: u8, available: bool, font: u64, size: f32, length: usize) void {
    @memset(bytes, 0);
    bytes[0..4].* = .{ 60, 1, mode, 0 };
    put(bytes, 4, @intFromBool(available));
    put(bytes, 8, length);
    put(bytes, 12, if (mode == 1 or mode == 2) length else 0);
    std.mem.writeInt(u64, bytes[16..24], font, .little);
    setFloat(bytes, 24, size);
    const face = font_ttf.bundledFaceForFontId(font);
    setFloat(bytes, 28, face.advance(0) / face.units_per_em);
}
/// Validate every range and codepoint before invoking a font capability.
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len < 64 or result.len != request.len or result[3] < 1 or result[3] > 2 or
        !std.mem.eql(u8, request[0..3], result[0..3]) or !std.mem.eql(u8, request[4..32], result[4..32]) or word(result, 60) != 0) return false;
    const mode = request[2];
    const length = word(request, 8);
    const slots: usize = word(request, 12);
    const action = word(result, 56);
    const count = word(result, 36);
    if (mode == 0 or mode == 3) {
        if (request.len != 64 or count != 0 or action > 2 or (result[3] == 1 and (action != 2 or word(request, 4) != 1 or length == 0))) return false;
        if (mode == 0 and !std.mem.allEqual(u8, result[40..56], 0)) return false;
        return result[3] != 2 or action <= 1;
    }
    if (mode > 2 or slots != length or slots > (std.math.maxInt(usize) - 64) / 9 or request.len != 64 + slots * 9 or count > slots or
        (mode == 2 and count != @intFromBool(length != 0) and !(result[3] == 2 and count == 0)) or !std.mem.eql(u8, request[64 + slots * 8 ..], result[64 + slots * 8 ..]) or !std.mem.allEqual(u8, result[40..56], 0)) return false;
    if (result[3] == 1 and (action != 3 or count == 0 or request[3] != 0)) return false;
    if (result[3] == 2 and action != 0) return false;
    for (0..count) |i| {
        const cp = word(result, 64 + i * 8);
        if (cp != 0xffffffff and (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff))) return false;
    }
    if (!std.mem.allEqual(u8, result[64 + @as(usize, count) * 8 .. 64 + slots * 8], 0)) return false;
    if (request[3] == 1 and (!std.mem.eql(u8, request[64..], result[64..]) or word(request, 36) != count)) return false;
    return true;
}
fn run(policy: Policy, request: []const u8, result: []u8) void {
    @memset(result, 0xa5);
    if (policy(request, result) != result.len or !resultValid(request, result)) @panic("invalid scalar text decision");
}
/// Text layout asks for the same glyph and cluster advances on every frame.
/// An estimate depends only on the policy, the font, the size, the cluster
/// flag and the bytes (bundled font tables are static), so short probes keep
/// their exact result per thread instead of re-entering a policy registered as
/// pure (`decision_reuse.registerPurePolicy`). A slot
/// is reused only when every input matches; a collision just replaces it.
const EstimateEntry = struct {
    policy: ?Policy = null,
    font: u64 = 0,
    size: u32 = 0,
    cluster: bool = false,
    len: u8 = 0,
    bytes: [estimate_key_bytes]u8 = undefined,
    advance: f32 = 0,
};
const estimate_key_bytes = 32;
const estimate_slots = 1024;
threadlocal var estimates: [estimate_slots]EstimateEntry = @splat(.{});

fn estimateSlot(policy: Policy, font: u64, text: []const u8, size: u32, cluster: bool) *EstimateEntry {
    var hash: u64 = 0xcbf29ce484222325 ^ font ^ (@as(u64, size) << 1) ^ @intFromBool(cluster) ^ @intFromPtr(policy);
    for (text) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    hash ^= hash >> 29;
    return &estimates[@intCast(hash % estimate_slots)];
}

pub fn estimate(policy: Policy, font: u64, text: []const u8, size: f32, cluster: bool) f32 {
    if (text.len > estimate_key_bytes or !@import("decision_reuse.zig").isPure(policy)) return estimateUncached(policy, font, text, size, cluster);
    const size_bits: u32 = @bitCast(size);
    const slot = estimateSlot(policy, font, text, size_bits, cluster);
    if (slot.policy == policy and slot.font == font and slot.size == size_bits and slot.cluster == cluster and
        slot.len == text.len and std.mem.eql(u8, slot.bytes[0..text.len], text)) return slot.advance;
    const advance = estimateUncached(policy, font, text, size, cluster);
    slot.* = .{ .policy = policy, .font = font, .size = size_bits, .cluster = cluster, .len = @intCast(text.len), .advance = advance };
    @memcpy(slot.bytes[0..text.len], text);
    return advance;
}

fn estimateUncached(policy: Policy, font: u64, text: []const u8, size: f32, cluster: bool) f32 {
    const total = std.math.add(usize, 64, std.math.mul(usize, text.len, 9) catch @panic("scalar text capacity")) catch @panic("scalar text capacity");
    if (total > std.math.maxInt(u32)) @panic("scalar text packet range");
    // Glyph and cluster probes should not initialize a whole run's scratch
    // buffer in Debug. Every path retains the same complete wire packet.
    var small: [256]u8 = undefined;
    if (total <= small.len / 2) return estimateInStorage(policy, font, text, size, cluster, small[0 .. total * 2]);
    return estimateLarge(policy, font, text, size, cluster, total);
}
fn estimateLarge(policy: Policy, font: u64, text: []const u8, size: f32, cluster: bool, total: usize) f32 {
    if (total <= 4096) {
        var small: [8192]u8 = undefined;
        return estimateInStorage(policy, font, text, size, cluster, small[0 .. total * 2]);
    }
    const allocator = std.heap.page_allocator;
    const storage = allocator.alloc(u8, std.math.mul(usize, total, 2) catch @panic("scalar text capacity")) catch @panic("scalar text allocation");
    defer allocator.free(storage);
    return estimateInStorage(policy, font, text, size, cluster, storage);
}
fn estimateInStorage(policy: Policy, font: u64, text: []const u8, size: f32, cluster: bool, storage: []u8) f32 {
    const total = storage.len / 2;
    const packet = storage[0..total];
    const result = storage[total..];
    initialize(packet, if (cluster) 2 else 1, false, font, size, text.len);
    @memcpy(packet[64 + text.len * 8 ..], text);
    run(policy, packet, result);
    if (result[3] == 2) return float(result, 32);
    @memcpy(packet, result);
    for (0..word(packet, 36)) |i| {
        const cp = word(packet, 64 + i * 8);
        if (cp == 0xffffffff) continue;
        if (metrics.bundledGlyphAdvanceEmForFont(font, @intCast(cp))) |advance| setFloat(packet, 64 + i * 8 + 4, advance);
    }
    run(policy, packet, result);
    if (result[3] != 2) @panic("scalar text did not finish");
    return float(result, 32);
}
pub fn width(policy: Policy, provider: ?*const metrics.TextMeasureProvider, font: u64, text: []const u8, size: f32) f32 {
    var request: [64]u8 = undefined;
    var result: [64]u8 = undefined;
    initialize(&request, 0, provider != null, font, size, text.len);
    run(policy, &request, &result);
    if (result[3] == 1) {
        request = result;
        setFloat(&request, 32, provider.?.measure_fn(provider.?.context, font, size, text));
        run(policy, &request, &result);
    }
    if (result[3] != 2) @panic("scalar width did not finish");
    return if (word(&result, 56) == 1) estimate(policy, font, text, size, false) else float(&result, 32);
}
pub fn ink(policy: Policy, provider: *const metrics.TextMeasureProvider, font: u64, text: []const u8, size: f32) ?metrics.TextInkMetrics {
    var request: [64]u8 = undefined;
    var result: [64]u8 = undefined;
    initialize(&request, 3, provider.measure_ink_fn != null, font, size, text.len);
    run(policy, &request, &result);
    if (result[3] == 2) return null;
    request = result;
    var value: metrics.TextInkMetrics = .{};
    put(&request, 32, @intFromBool(provider.measure_ink_fn.?(provider.context, font, size, text, &value)));
    setFloat(&request, 40, value.min_x);
    setFloat(&request, 44, value.max_x);
    setFloat(&request, 48, value.min_y);
    setFloat(&request, 52, value.max_y);
    run(policy, &request, &result);
    if (result[3] != 2) @panic("scalar ink did not finish");
    return if (word(&result, 56) == 1) value else null;
}

test "scalar text copied transport rejects oversized font facts and changed immutable bytes" {
    var request: [82]u8 = undefined;
    initialize(&request, 1, false, 1, 12, 2);
    request[80..82].* = .{ 'a', 'b' };
    var result = request;
    result[3] = 1;
    put(&result, 36, 2);
    put(&result, 56, 3);
    put(&result, 64, 'a');
    put(&result, 72, 'b');
    try std.testing.expect(resultValid(&request, &result));
    for (0..result.len) |length| try std.testing.expect(!resultValid(&request, result[0..length]));
    for ([_]usize{ 0, 4, 8, 12, 16, 20, 24, 28, 36, 40, 56, 60, 80 }) |at| {
        var bad = result;
        bad[at] = 255;
        try std.testing.expect(!resultValid(&request, &bad));
    }
    for ([_]u32{ 0xd800, 0xdfff, 0x110000, 0xfffffffe }) |cp| {
        var bad = result;
        put(&bad, 64, cp);
        try std.testing.expect(!resultValid(&request, &bad));
    }
    request = result;
    result[3] = 2;
    put(&result, 56, 0);
    try std.testing.expect(resultValid(&request, &result));
    result[68] ^= 1;
    try std.testing.expect(!resultValid(&request, &result));
}

var estimate_test_calls: usize = 0;
fn estimateTestPolicy(request: []const u8, result: []u8) usize {
    estimate_test_calls += 1;
    @memcpy(result[0..request.len], request);
    const slots: usize = word(request, 12);
    @memset(result[32..60], 0);
    @memset(result[64 .. 64 + slots * 8], 0);
    result[3] = 2;
    // A deterministic stand-in decision over every input the cache keys on.
    var advance = float(request, 24) * @as(f32, @floatFromInt(request[2]));
    for (request[64 + slots * 8 ..]) |byte| advance += @floatFromInt(byte);
    advance += @floatFromInt(std.mem.readInt(u64, request[16..24], .little));
    setFloat(result, 32, advance);
    return request.len;
}

test "scalar estimates reuse exact results only for identical inputs" {
    estimate_test_calls = 0;
    _ = estimate(estimateTestPolicy, 7, "ab", 12, true);
    _ = estimate(estimateTestPolicy, 7, "ab", 12, true);
    try std.testing.expectEqual(@as(usize, 2), estimate_test_calls);
    @import("decision_reuse.zig").registerPurePolicy(estimateTestPolicy);
    estimate_test_calls = 0;
    const first = estimate(estimateTestPolicy, 7, "ab", 12, true);
    try std.testing.expectEqual(first, estimate(estimateTestPolicy, 7, "ab", 12, true));
    try std.testing.expectEqual(@as(usize, 1), estimate_test_calls);
    // Every keyed input selects a different decision.
    try std.testing.expect(estimate(estimateTestPolicy, 8, "ab", 12, true) != first);
    try std.testing.expect(estimate(estimateTestPolicy, 7, "ac", 12, true) != first);
    try std.testing.expect(estimate(estimateTestPolicy, 7, "ab", 13, true) != first);
    try std.testing.expect(estimate(estimateTestPolicy, 7, "ab", 12, false) != first);
    try std.testing.expect(estimate(estimateTestPolicy, 7, "a", 12, true) != first);
    try std.testing.expectEqual(@as(usize, 6), estimate_test_calls);
    // Probes longer than the key always run the policy.
    const long = "a long run that does not fit the cached probe key";
    _ = estimate(estimateTestPolicy, 7, long, 12, false);
    _ = estimate(estimateTestPolicy, 7, long, 12, false);
    try std.testing.expectEqual(@as(usize, 8), estimate_test_calls);
}
