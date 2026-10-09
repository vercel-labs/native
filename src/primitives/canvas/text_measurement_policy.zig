//! Copied measured-text decisions. Native owns hashes, opaque provider
//! identities, generation atomics, font calls, buffers and pointer proofs.
const std = @import("std");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const key_bytes = 96;
pub const fact_bytes = 104;
pub const max_facts = 257;
pub const facts_at = 128;
pub const fact_packet_bytes = facts_at + max_facts * fact_bytes;
pub const Decision = struct { kind: u32, slot: ?usize, flags: u32 };

pub fn header(bytes: []u8, mode: u8, flags: u8, count: usize, length: usize, capacity: usize) void {
    @memset(bytes, 0);
    bytes[0..4].* = .{ 58, 1, mode, flags };
    put(bytes, 4, count);
    put(bytes, 8, length);
    put(bytes, 12, capacity);
}
pub fn resultValid(request: []const u8, result: []const u8) bool {
    if (request.len < 32 or result.len != 16 or word(result, 0) > 6 or word(result, 8) > 15 or word(result, 12) != 0) return false;
    const kind = word(result, 0);
    const slot = word(result, 4);
    const flags = word(result, 8);
    const mode = request[2];
    const indexed = kind == 2 or kind == 3 or kind == 4;
    if (indexed) {
        if (slot >= word(request, 4)) return false;
    } else if (slot != 0xffffffff) return false;
    return switch (mode) {
        0 => (kind == 0 or kind == 1 or kind == 6) and flags == 0,
        3 => (kind == 0 or kind == 6) and flags == 0,
        1 => (kind == 2 and flags == 3) or (kind == 3 and flags == 5),
        2 => (kind == 0 and flags == 0) or (kind == 2 and flags == (if (word(request, 8) > 2048) @as(u32, 2) else 3)),
        4 => (kind == 0 and flags == 8) or (kind == 2 and flags == 3),
        5 => (kind == 0 and flags == 0) or (kind == 4 and flags == 1),
        6, 7 => (kind == 0 or kind == 5) and flags == 0,
        else => false,
    };
}
pub fn execute(policy: Policy, request: []const u8) Decision {
    var result: [16]u8 = undefined;
    if (policy(request, &result) != result.len or !resultValid(request, &result)) @panic("invalid measured text decision");
    const kind = word(&result, 0);
    const slot = word(&result, 4);
    return .{ .kind = kind, .slot = if (kind == 2 or kind == 3 or kind == 4) slot else null, .flags = word(&result, 8) };
}
pub fn key(bytes: []u8, value: anytype) void {
    @memset(bytes[0..key_bytes], 0);
    const T = @TypeOf(value);
    if (comptime @hasField(T, "hash")) {
        integer(bytes, 0, value.hash);
        integer(bytes, 8, value.text_len);
        integer(bytes, 16, value.font_id);
        put(bytes, 24, value.size_bits);
        integer(bytes, 32, value.provider_context);
        integer(bytes, 40, value.provider_fn);
        integer(bytes, 48, value.generation);
    } else {
        integer(bytes, 0, value.fingerprint);
        integer(bytes, 8, value.span_count);
        put(bytes, 16, value.size_bits);
        put(bytes, 20, value.line_height_bits);
        put(bytes, 24, value.max_width_bits);
        put(bytes, 28, @intFromEnum(value.wrap));
        put(bytes, 32, @intFromEnum(value.alignment));
        integer(bytes, 40, value.font_id);
        integer(bytes, 48, value.mono_font_id);
        integer(bytes, 56, value.provider_context);
        integer(bytes, 64, value.provider_fn);
        integer(bytes, 72, value.paragraph_policy);
        integer(bytes, 80, value.generation);
    }
    put(bytes, 88, @intFromBool(value.used));
}
pub fn fact(bytes: []u8, value: anytype, tick: u64) void {
    key(bytes, value);
    integer(bytes, 96, tick);
}
pub fn admission(policy: Policy, mode: u8, flags: u8, length: usize, capacity: usize) Decision {
    var bytes: [32]u8 = undefined;
    header(&bytes, mode, flags, 0, length, capacity);
    return execute(policy, &bytes);
}
const BatchScratch = struct { bytes: [32 + 65536 * 4]u8 };
const batch_scratch = @import("lazy_tls.zig").LazyTls(BatchScratch);
pub fn batchValid(policy: Policy, advances: []const f32) bool {
    if (advances.len > 65536) @panic("measured text batch outside owner storage");
    const bytes = batch_scratch.get().bytes[0 .. 32 + advances.len * 4];
    header(bytes, 6, 1, 0, advances.len, 0);
    for (advances, 0..) |value, i| put(bytes, 32 + i * 4, @as(u32, @bitCast(value)));
    return execute(policy, bytes).kind == 5;
}
pub fn put(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("measured text wire overflow"), .little);
}
pub fn integer(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

test "measured text copied transport rejects foreign shapes before native state changes" {
    var request: [32]u8 = undefined;
    header(&request, 1, 0, 256, 1, 0);
    var result: [16]u8 = @splat(0);
    put(&result, 0, 3);
    put(&result, 4, 255);
    put(&result, 8, 5);
    try std.testing.expect(resultValid(&request, &result));
    for (0..16) |length| try std.testing.expect(!resultValid(&request, result[0..length]));
    for ([_]usize{ 0, 4, 8, 12 }) |at| {
        var bad = result;
        put(&bad, at, 0xffffffff);
        try std.testing.expect(!resultValid(&request, &bad));
    }
    put(&result, 4, 256);
    try std.testing.expect(!resultValid(&request, &result));
    put(&result, 4, 0);
    for ([_]u8{ 0, 2, 3, 4, 5, 6, 7, 255 }) |mode| {
        request[2] = mode;
        try std.testing.expect(!resultValid(&request, &result));
    }
}
