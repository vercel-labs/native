//! Copied session-recording plans over native-owned storage and I/O capabilities.
const std = @import("std");
const journal = @import("session_journal.zig");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { begin, stage, commit, chrome, checkpoint_gate, checkpoint, screenshot, effect, finish, record, write, fail, count };
pub const Action = enum(u8) { skip, proceed, depth_budget, unavailable_chrome, unowned_chrome, chrome_budget, record_budget, journal_budget, suppressed };
pub const Treatment = enum(u8) { inline_bytes, pty, file, image, persist, db, redact, placeholder };
pub const Facts = struct {
    began: bool = false,
    finished: bool = false,
    failed: bool = false,
    depth: usize = 0,
    owner: ?usize = null,
    suppressed: bool = false,
    category: u8 = 0,
    file_chunk: bool = false,
    credential_get: bool = false,
    credential_ok: bool = false,
    chrome_unavailable: bool = false,
    chrome_count: usize = 0,
    a: u64 = 0,
    b: u64 = 0,
    limit_a: u64 = 0,
    limit_b: u64 = 0,
};
pub const Plan = struct { action: Action, depth: usize, owner: ?usize, treatment: Treatment, value: u64, chrome_count: usize };
pub fn plan(policy: Policy, stage: Stage, facts: Facts) ?Plan {
    const callback = policy orelse return null;
    var input: [64]u8 = @splat(0);
    input[0..13].* = .{ 24, @intFromEnum(stage), @intFromBool(facts.began), @intFromBool(facts.finished), @intFromBool(facts.failed), @intCast(facts.depth), if (facts.owner) |owner| @intCast(owner) else 255, @intFromBool(facts.suppressed), facts.category, @intFromBool(facts.file_chunk), @intFromBool(facts.credential_get), @intFromBool(facts.credential_ok), @intFromBool(facts.chrome_unavailable) };
    std.mem.writeInt(u32, input[16..20], @intCast(facts.chrome_count), .little);
    std.mem.writeInt(u32, input[20..24], journal.max_session_event_depth, .little);
    std.mem.writeInt(u32, input[24..28], journal.max_session_window_chrome_queries, .little);
    inline for (.{ facts.a, facts.b, facts.limit_a, facts.limit_b }, 0..) |value, i| std.mem.writeInt(u64, input[32 + i * 8 ..][0..8], value, .little);
    var output: [32]u8 = undefined;
    if (callback(&input, &output) != output.len or output[0] > 8 or output[1] > journal.max_session_event_depth or
        (output[2] != 255 and output[2] >= journal.max_session_event_depth) or output[3] > 7 or
        !std.mem.allEqual(u8, output[4..8], 0) or !std.mem.allEqual(u8, output[20..], 0)) @panic("invalid compiled recording plan");
    const count = std.mem.readInt(u32, output[16..20], .little);
    if (count > journal.max_session_window_chrome_queries) @panic("invalid compiled recording chrome count");
    return .{ .action = @enumFromInt(output[0]), .depth = output[1], .owner = if (output[2] == 255) null else output[2], .treatment = @enumFromInt(output[3]), .value = std.mem.readInt(u64, output[8..16], .little), .chrome_count = count };
}
