//! Copied journal framing and sequencing decisions. Payload codecs, borrowed
//! byte storage, and sink I/O remain native capabilities.
const std = @import("std");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { init, frame, next, seal, preamble };
pub const Action = enum(u8) { proceed, bad_magic, format_mismatch, truncated, corrupt, over_budget, missing_header, count_mismatch, done };
pub const Facts = struct {
    header: bool = false,
    ended: bool = false,
    kind: u8 = 0,
    a: u64 = 0,
    b: u64 = 0,
    fingerprint: u64 = 0,
    counts: [5]u64 = @splat(0),
    sealed: [5]u64 = @splat(0),
    sample: []const u8 = "",
    limit: u64 = 0,
};
pub const Plan = struct {
    action: Action = .proceed,
    kind: u8 = 0,
    length: u32 = 0,
    pos: u64 = 0,
    counts: [5]u64 = @splat(0),
    frame: [5]u8 = @splat(0),
    preamble: [16]u8 = @splat(0),
};
pub fn plan(policy: Policy, stage: Stage, facts: Facts) Plan {
    const callback = policy orelse return @import("journal_reference.zig").plan(stage, facts);
    std.debug.assert(facts.sample.len <= 16);
    var input: [160]u8 = @splat(0);
    input[0..4].* = .{ 26, @intFromEnum(stage), @as(u8, @intFromBool(facts.header)) | (@as(u8, @intFromBool(facts.ended)) << 1), facts.kind };
    inline for (.{ facts.a, facts.b, facts.fingerprint }, 0..) |value, i| std.mem.writeInt(u64, input[8 + i * 8 ..][0..8], value, .little);
    for (facts.counts, 0..) |value, i| std.mem.writeInt(u64, input[32 + i * 8 ..][0..8], value, .little);
    for (facts.sealed, 0..) |value, i| std.mem.writeInt(u64, input[72 + i * 8 ..][0..8], value, .little);
    @memcpy(input[112..][0..facts.sample.len], facts.sample);
    std.mem.writeInt(u64, input[128..136], facts.limit, .little);
    var output: [80]u8 = undefined;
    if (callback(&input, &output) != output.len or output[0] > 8 or output[1] > 7 or
        !std.mem.allEqual(u8, output[2..4], 0) or !std.mem.allEqual(u8, output[61..64], 0)) @panic("invalid compiled journal plan");
    var result: Plan = .{
        .action = @enumFromInt(output[0]),
        .kind = output[1],
        .length = std.mem.readInt(u32, output[4..8], .little),
        .pos = std.mem.readInt(u64, output[8..16], .little),
        .frame = output[56..61].*,
        .preamble = output[64..80].*,
    };
    for (&result.counts, 0..) |*value, i| value.* = std.mem.readInt(u64, output[16 + i * 8 ..][0..8], .little);
    const valid_action = switch (stage) {
        .init => result.action == .proceed or result.action == .bad_magic or result.action == .format_mismatch,
        .frame => result.action == .proceed or result.action == .over_budget,
        .next => result.action == .proceed or result.action == .truncated or result.action == .corrupt or result.action == .over_budget or result.action == .missing_header or result.action == .done,
        .seal => result.action == .proceed or result.action == .count_mismatch,
        .preamble => result.action == .proceed,
    };
    if (!valid_action or (stage != .next and (result.kind != 0 or result.length != 0)) or
        (stage != .frame and !std.mem.allEqual(u8, &result.frame, 0)) or
        (stage != .preamble and !std.mem.allEqual(u8, &result.preamble, 0))) @panic("invalid compiled journal stage result");
    if (stage == .next and (result.pos < facts.b or result.pos > facts.a or
        (result.kind == 0 and result.action == .proceed) or
        (result.kind != 0 and (result.length > facts.limit or result.pos - facts.b != 5 + @as(u64, result.length)))))
        @panic("invalid compiled journal frame bounds");
    if (stage == .init and result.action == .proceed and result.pos != 16) @panic("invalid compiled journal preamble bounds");
    return result;
}
