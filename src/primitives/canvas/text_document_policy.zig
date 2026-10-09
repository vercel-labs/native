//! Copied document-width transport and explicit font capabilities. Native
//! owns storage, pointer identity and the retained widget fields; the owner
//! chooses admission, cache validity, chunks, fallback and accumulation.
const std = @import("std");
const metrics = @import("text_metrics.zig");
const cache = @import("text_measure_cache.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
fn put(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("document width integer range"), .little);
}
fn setFloat(bytes: []u8, at: usize, value: f32) void {
    put(bytes, at, @as(u32, @bitCast(value)));
}
fn integer(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn initialize(bytes: []u8, mode: u8, flags: u8, length: usize) void {
    @memset(bytes, 0);
    bytes[0..4].* = .{ 59, 1, mode, 0 };
    put(bytes, 4, flags);
    put(bytes, 8, length);
    const slots: usize = if (mode == 2) @min(length, 65536) else 0;
    put(bytes, 12, 128 + slots * 4);
    put(bytes, 16, slots);
}
/// Prove every foreign range before slicing bytes or invoking a provider.
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len < 128 or result.len != 128 or result[3] < 1 or result[3] > 2 or
        !std.mem.eql(u8, request[0..3], result[0..3]) or !std.mem.eql(u8, request[4..80], result[4..80]) or
        word(result, 112) != 0 or word(result, 116) != 0 or word(result, 120) != 0 or word(result, 124) != 0) return false;
    if (request[2] != 2) return result[3] == 2 and word(result, 80) <= 1 and std.mem.allEqual(u8, result[84..120], 0);
    const length = word(request, 8);
    if (@as(u64, word(request, 12)) + length != request.len or word(request, 12) != 128 + @as(u64, word(request, 16)) * 4 or
        word(result, 100) > length or word(result, 92) != 0 or word(result, 108) != 0) return false;
    const action = word(result, 80);
    const first = word(result, 84);
    const last = word(result, 88);
    const phase = word(result, 96);
    if (result[3] == 2) return action == 0 and first == 0 and last == 0 and phase == 0;
    if (first > last or last > length or first != word(result, 100)) return false;
    return switch (action) {
        1 => phase == 1 and word(request, 4) == 3 and last > first and last - first <= word(request, 16),
        2 => phase == 2 or phase == 3,
        else => false,
    };
}
fn run(policy: Policy, request: []const u8, result: *[128]u8) void {
    @memset(result, 0xa5);
    if (policy(request, result) != result.len or !resultValid(request, result)) @panic("invalid document width decision");
}
pub fn cacheDecision(policy: Policy, widget: anytype, font: u64, size: f32, admission: bool) u32 {
    var request: [128]u8 = undefined;
    const flags: u8 = @as(u8, @intFromBool(widget.kind == .textarea)) |
        (@as(u8, @intFromBool(widget.runtime_flags.code_editor)) << 1) |
        (@as(u8, @intFromBool(widget.text_no_wrap)) << 2) |
        (@as(u8, @intFromBool(widget.hasCodeDiff())) << 3);
    initialize(&request, if (admission) 1 else 0, flags, 0);
    integer(&request, 32, cache.textMeasureGeneration());
    integer(&request, 40, font);
    put(&request, 48, @as(u32, @bitCast(size)));
    integer(&request, 56, widget.code_content_width_generation);
    integer(&request, 64, widget.code_content_width_font_id);
    put(&request, 72, widget.code_content_width_size_bits);
    setFloat(&request, 76, widget.code_content_width);
    var result: [128]u8 = undefined;
    run(policy, &request, &result);
    return word(&result, 80);
}
pub fn widest(policy: Policy, provider: ?*const metrics.TextMeasureProvider, font: u64, text: []const u8, size: f32) f32 {
    const allocator = std.heap.page_allocator;
    const slots: usize = @min(text.len, 65536);
    const total = std.math.add(usize, 128 + slots * 4, text.len) catch @panic("document width packet capacity");
    if (total > std.math.maxInt(u32)) @panic("document width packet range");
    var small: [8192]u8 = undefined;
    const packet = if (total <= small.len) small[0..total] else allocator.alloc(u8, total) catch @panic("document width allocation");
    defer if (total > small.len) allocator.free(packet);
    initialize(packet, 2, @as(u8, @intFromBool(provider != null)) | (if (provider) |p| @as(u8, @intFromBool(p.measure_advances_fn != null)) << 1 else 0), text.len);
    @memcpy(packet[128 + slots * 4 ..], text);
    var result: [128]u8 = undefined;
    var calls: usize = 0;
    while (true) {
        calls += 1;
        // A declined batch precedes a complete scalar restart, including
        // its trailing empty line. Both walks are bounded by source bytes.
        if (calls > std.math.add(usize, std.math.mul(usize, text.len, 2) catch @panic("document width quota"), 3) catch @panic("document width quota")) @panic("document width did not finish");
        run(policy, packet, &result);
        if (result[3] == 2) return float(&result, 104);
        @memcpy(packet[0..128], &result);
        const first = word(&result, 84);
        const last = word(&result, 88);
        if (word(&result, 80) == 1) {
            const values = cache.textRunAdvancesWithPolicy(provider.?, policy, font, size, text[first..last]);
            put(packet, 92, @intFromBool(values != null));
            if (values) |advances| for (advances, 0..) |value, i| setFloat(packet, 128 + i * 4, value);
        } else setFloat(packet, 108, metrics.measureTextWidthForFont(provider, font, text[first..last], size));
    }
}

test "document width copied transport rejects foreign capability ranges and writes" {
    var request: [148]u8 = undefined;
    initialize(&request, 2, 3, 4);
    var result: [128]u8 = request[0..128].*;
    result[3] = 1;
    put(&result, 80, 1);
    put(&result, 88, 4);
    put(&result, 96, 1);
    try std.testing.expect(resultValid(&request, &result));
    for (0..128) |length| try std.testing.expect(!resultValid(&request, result[0..length]));
    for ([_]usize{ 0, 4, 8, 12, 16, 80, 84, 88, 92, 96, 100, 108, 112, 116, 120, 124 }) |at| {
        var bad = result;
        put(&bad, at, 0xffffffff);
        try std.testing.expect(!resultValid(&request, &bad));
    }
}
