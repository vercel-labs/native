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
    const face = &font_ttf.geist_regular;
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
pub fn estimate(policy: Policy, font: u64, text: []const u8, size: f32, cluster: bool) f32 {
    const total = std.math.add(usize, 64, std.math.mul(usize, text.len, 9) catch @panic("scalar text capacity")) catch @panic("scalar text capacity");
    if (total > std.math.maxInt(u32)) @panic("scalar text packet range");
    var small: [8192]u8 = undefined;
    const allocator = std.heap.page_allocator;
    const storage = if (total <= small.len / 2) small[0 .. total * 2] else allocator.alloc(u8, std.math.mul(usize, total, 2) catch @panic("scalar text capacity")) catch @panic("scalar text allocation");
    defer if (total > small.len / 2) allocator.free(storage);
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
        if (metrics.bundledGlyphAdvanceEm(@intCast(cp))) |advance| setFloat(packet, 64 + i * 8 + 4, advance);
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
