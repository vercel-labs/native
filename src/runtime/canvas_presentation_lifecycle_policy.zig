//! Copied presentation decisions. Native supplies capabilities and installs
//! accepted state; it never repeats the compiled lifecycle policy.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform/root.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { requested, start, built, uploaded, encoded, pixels, baseline, gathered, fallback, image_action, image, direct, rendering };
pub const Instruction = enum(u32) { skipped, packet, upload, encode, pixels, done, gather, adopt, invalidate, observe_image };
pub const Refusal = enum(u32) { none, missing_service, unsupported_command };
pub const Facts = struct {
    requires_render: bool = false,
    view_exists: bool = false,
    software: bool = false,
    packet_service: bool = false,
    representable: bool = false,
    ok: bool = false,
    retained_pixels: bool = false,
    current: bool = false,
    image_upload: bool = false,
    image_index_present: bool = false,
    command_capacity: usize = 0,
    packet_capacity: usize = 0,
    scratch_capacity: usize = 0,
    pixel_bytes: usize = 0,
    fallback_count: usize = 0,
    logged_count: usize = 0,
    detail_bytes: usize = 0,
    detail_capacity: usize = 0,
    image_index: usize = 0,
    image_count: usize = 0,
    image_width: usize = 0,
    image_height: usize = 0,
    image_bytes: usize = 0,
    previous_reason: platform.GpuPresentFallbackReason = .none,
    reason: platform.GpuPresentFallbackReason = .none,
};
pub const Program = struct {
    instruction: Instruction,
    refusal: Refusal,
    use_scratch: bool,
    should_log: bool,
    overflow: bool,
    fallback_count: usize,
    logged_count: usize,
    detail_bytes: usize,
};
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn wide(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}
pub fn resultValid(bytes: []const u8) bool {
    return bytes.len == 64 and word(bytes, 0) == 1 and word(bytes, 4) <= 9 and
        word(bytes, 8) <= 2 and word(bytes, 12) <= 7 and std.mem.allEqual(u8, bytes[40..], 0) and
        wide(bytes, 16) <= std.math.maxInt(usize) and wide(bytes, 24) <= std.math.maxInt(usize) and wide(bytes, 32) <= std.math.maxInt(usize);
}
pub fn plan(mode: Mode, facts: Facts, owner: Policy) Program {
    var request: [128]u8 = @splat(0);
    request[0..4].* = .{ 77, 1, @intFromEnum(mode), @as(u8, @intFromBool(builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) | (@as(u8, @intFromBool(@bitSizeOf(usize) == 32)) << 1) };
    var flags: u32 = 0;
    inline for (.{ "requires_render", "view_exists", "software", "packet_service", "representable", "ok", "retained_pixels", "current", "image_upload", "image_index_present" }, 0..) |field, i|
        flags |= @as(u32, @intFromBool(@field(facts, field))) << @intCast(i);
    std.mem.writeInt(u32, request[4..8], flags, .little);
    inline for (.{ "command_capacity", "packet_capacity", "scratch_capacity", "pixel_bytes", "fallback_count", "logged_count", "detail_bytes", "detail_capacity", "image_index", "image_count", "image_width", "image_height", "image_bytes" }, 0..) |field, i|
        std.mem.writeInt(u64, request[8 + i * 8 ..][0..8], @field(facts, field), .little);
    std.mem.writeInt(u32, request[112..116], @intFromEnum(facts.previous_reason), .little);
    std.mem.writeInt(u32, request[116..120], @intFromEnum(facts.reason), .little);
    var output: [64]u8 = @splat(0xa5);
    const length = owner(&request, &output);
    if (length > output.len or !resultValid(output[0..length])) @panic("invalid compiled presentation lifecycle result");
    const mutations = word(&output, 12);
    return .{ .instruction = @enumFromInt(word(&output, 4)), .refusal = @enumFromInt(word(&output, 8)), .use_scratch = mutations & 1 != 0, .should_log = mutations & 2 != 0, .overflow = mutations & 4 != 0, .fallback_count = @intCast(wide(&output, 16)), .logged_count = @intCast(wide(&output, 24)), .detail_bytes = @intCast(wide(&output, 32)) };
}

test "presentation lifecycle transport rejects unbounded instructions and incomplete envelopes" {
    var output: [64]u8 = @splat(0);
    std.mem.writeInt(u32, output[0..4], 1, .little);
    try std.testing.expect(resultValid(&output));
    for (0..output.len) |length| try std.testing.expect(!resultValid(output[0..length]));
    for ([_]usize{ 0, 4, 8, 12, 40, 44, 48, 52, 56, 60 }) |at| {
        var bad = output;
        std.mem.writeInt(u32, bad[at..][0..4], 0xffffffff, .little);
        try std.testing.expect(!resultValid(&bad));
    }
}
