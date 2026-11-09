//! Copied snapshot projection and frame-profile decisions. Native code owns
//! borrowed storage, allocation and clock/process/GPU observations.
const std = @import("std");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { bounded, view, widget, virtual_range, uptime, presence, record, stats, reset, has_samples, elapsed };
pub const Facts = struct {
    flags: u32 = 0,
    words: [8]u64 = @splat(0),
    floats: [7]f32 = @splat(0),
    samples: []const u32 = &.{},
};
pub const Plan = struct {
    flags: u8 = 0,
    words: [8]u64 = @splat(0),
    floats: [7]f32 = @splat(0),
};
pub fn plan(policy: Policy, mode: Mode, facts: Facts) Plan {
    const callback = policy orelse return @import("snapshot_reference.zig").plan(mode, facts);
    if (facts.samples.len > 128) @panic("snapshot sample budget exceeded");
    var input: [616]u8 = undefined;
    const input_len = 104 + facts.samples.len * 4;
    @memset(input[0..input_len], 0);
    input[0..4].* = .{ 27, 1, @intFromEnum(mode), 0 };
    std.mem.writeInt(u32, input[4..8], facts.flags, .little);
    for (facts.words, 0..) |word, i| std.mem.writeInt(u64, input[8 + i * 8 ..][0..8], word, .little);
    for (facts.floats, 0..) |value, i| std.mem.writeInt(u32, input[72 + i * 4 ..][0..4], @bitCast(value), .little);
    for (facts.samples, 0..) |value, i| std.mem.writeInt(u32, input[104 + i * 4 ..][0..4], value, .little);
    var output: [104]u8 = undefined;
    if (callback(input[0..input_len], &output) != output.len or !std.mem.allEqual(u8, output[1..8], 0) or !std.mem.allEqual(u8, output[100..104], 0))
        @panic("invalid compiled snapshot response");
    const mask: u8 = switch (mode) {
        .widget => 63,
        .presence => 7,
        else => 1,
    };
    if (output[0] & ~mask != 0) @panic("invalid compiled snapshot flags");
    var result: Plan = .{ .flags = output[0] };
    for (&result.words, 0..) |*word, i| word.* = std.mem.readInt(u64, output[8 + i * 8 ..][0..8], .little);
    for (&result.floats, 0..) |*value, i| value.* = @bitCast(std.mem.readInt(u32, output[72 + i * 4 ..][0..4], .little));
    const used: usize = switch (mode) {
        .bounded, .uptime, .elapsed, .widget => 1,
        .record => 4,
        .stats, .virtual_range => 5,
        else => 0,
    };
    for (result.words[used..]) |word| if (word != 0) @panic("invalid compiled snapshot reserved word");
    if (mode == .widget and !std.mem.allEqual(u8, output[88..100], 0)) @panic("invalid compiled snapshot reserved geometry");
    if (mode != .widget and !std.mem.allEqual(u8, output[72..100], 0)) @panic("invalid compiled snapshot reserved geometry");
    switch (mode) {
        .widget => if (result.flags & 32 != 0 and (result.words[0] >= facts.words[5] or facts.flags & 1024 == 0)) @panic("invalid compiled snapshot parent"),
        .bounded => if (result.words[0] > facts.words[0] or result.words[0] > facts.words[1]) @panic("invalid compiled snapshot capacity"),
        .record => if (result.words[0] > 128 or result.words[1] >= 128 or result.words[3] > std.math.maxInt(u32)) @panic("invalid compiled profile ring"),
        .stats => if (result.words[0] > 128 or result.words[2] > result.words[3] or result.words[3] > result.words[4] or result.words[4] > std.math.maxInt(u32)) @panic("invalid compiled profile statistics"),
        .virtual_range => for (result.words[0..5]) |word| {
            if (word > std.math.maxInt(u32)) @panic("invalid compiled snapshot range");
        },
        else => {},
    }
    return result;
}
