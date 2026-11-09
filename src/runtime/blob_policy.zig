//! Copied session blob decisions; native retains I/O, hashing, entropy and storage.
const std = @import("std");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { directory, write, open, probe, equal, find, memory_write, memory_read, read, hash, install, path, name };
pub const Action = enum(u8) { proceed, over_budget, io_failed, missing, corrupt, directory_too_long, matches, mismatch, more, dedup, repair, append, spare, found, absent };
pub const Facts = struct {
    flags: u8 = 0,
    words: [6]u64 = @splat(0),
    a: []const u8 = "",
    b: []const u8 = "",
};
pub const Plan = struct {
    action: Action = .proceed,
    words: [3]u64 = @splat(0),
    text: [1104]u8 = undefined,
    len: usize = 0,
    pub fn bytes(self: *const Plan) []const u8 {
        return self.text[0..self.len];
    }
};
pub fn plan(policy: Policy, mode: Mode, facts: Facts) Plan {
    const callback = policy orelse return @import("blob_reference.zig").plan(mode, facts);
    if (facts.a.len > 4096 or facts.b.len > 4096) @panic("blob copied chunk exceeds capacity");
    var input: [8256]u8 = undefined;
    @memset(input[0..64], 0);
    input[0..4].* = .{ 28, 1, @intFromEnum(mode), facts.flags };
    for (facts.words, 0..) |value, i| std.mem.writeInt(u64, input[8 + i * 8 ..][0..8], value, .little);
    std.mem.writeInt(u32, input[56..60], @intCast(facts.a.len), .little);
    std.mem.writeInt(u32, input[60..64], @intCast(facts.b.len), .little);
    @memcpy(input[64..][0..facts.a.len], facts.a);
    @memcpy(input[64 + facts.a.len ..][0..facts.b.len], facts.b);
    var output: [1136]u8 = undefined;
    const count = callback(input[0 .. 64 + facts.a.len + facts.b.len], &output);
    if (count < 32 or count > output.len or output[0] > 14 or !std.mem.allEqual(u8, output[1..4], 0)) @panic("invalid compiled blob plan");
    const len = std.mem.readInt(u32, output[4..8], .little);
    if (len > 1104 or count != 32 + @as(usize, len) or (mode != .path and mode != .name and len != 0)) @panic("invalid compiled blob text");
    var result: Plan = .{ .action = @enumFromInt(output[0]), .len = len };
    for (&result.words, 0..) |*value, i| value.* = std.mem.readInt(u64, output[8 + i * 8 ..][0..8], .little);
    if (result.words[2] != 0) @panic("invalid compiled blob reserved result");
    if (mode != .memory_write and result.words[1] != 0) @panic("invalid compiled blob reserved counter");
    if (mode != .probe and mode != .equal and mode != .find and mode != .memory_write and result.words[0] != 0) @panic("invalid compiled blob reserved position");
    if (mode == .path and len > facts.words[1]) @panic("invalid compiled blob path capacity");
    @memcpy(result.text[0..len], output[32..][0..len]);
    const valid = switch (mode) {
        .directory => result.action == .proceed or result.action == .directory_too_long,
        .write, .memory_read => result.action == .proceed or result.action == .over_budget or (mode == .memory_read and result.action == .missing),
        .open => result.action == .more or result.action == .absent,
        .probe, .equal => result.action == .matches or result.action == .mismatch or result.action == .more,
        .find => result.action == .found or result.action == .more,
        .memory_write => result.action == .over_budget or result.action == .io_failed or result.action == .dedup or result.action == .repair or result.action == .append,
        .read => result.action == .proceed or result.action == .io_failed or result.action == .over_budget or result.action == .spare,
        .hash => result.action == .proceed or result.action == .corrupt,
        .install, .path => result.action == .proceed or result.action == .io_failed,
        .name => result.action == .proceed,
    };
    if (!valid or (mode == .name and len != 32)) @panic("invalid compiled blob action");
    return result;
}
