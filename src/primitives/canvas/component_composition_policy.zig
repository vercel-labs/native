//! Copied composition plans. Native owns arenas, byte storage and typed Msg
//! routes; the compiled recipe owns structure, defaults and branch decisions.
const std = @import("std");
const widgets = @import("widgets.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { input_group, input_entry, input_actions, stepper, step, timeline_item, nav, timeline };
pub const Plan = struct {
    bytes: [128]u8,
    pub fn role(self: Plan) widgets.WidgetRole {
        return @enumFromInt(self.bytes[0]);
    }
    pub fn flag(self: Plan, mask: u8) bool {
        return self.bytes[1] & mask != 0;
    }
    pub fn float(self: Plan, slot: usize) f32 {
        return @bitCast(std.mem.readInt(u32, self.bytes[32 + slot * 4 ..][0..4], .little));
    }
    pub fn count(self: Plan) usize {
        return @intCast(std.mem.readInt(u64, self.bytes[16..24], .little));
    }
    pub fn active(self: Plan) usize {
        return @intCast(std.mem.readInt(u64, self.bytes[8..16], .little));
    }
    pub fn stateName(self: *const Plan) []const u8 {
        return self.bytes[104..][0..self.bytes[100]];
    }
};

pub fn plan(policy: Policy, stage: Stage, facts: u8, role: widgets.WidgetRole, active: usize, index: usize, count: usize, grow: f32, gap: f32) Plan {
    var input: [64]u8 = @splat(0);
    input[0..4].* = .{ 19, @intFromEnum(stage), facts, @intCast(@intFromEnum(role)) };
    std.mem.writeInt(u64, input[8..16], active, .little);
    std.mem.writeInt(u64, input[16..24], index, .little);
    std.mem.writeInt(u64, input[24..32], count, .little);
    std.mem.writeInt(u32, input[32..36], @bitCast(grow), .little);
    std.mem.writeInt(u32, input[36..40], @bitCast(gap), .little);
    var result: Plan = undefined;
    if (policy(&input, &result.bytes) != result.bytes.len or result.bytes[0] > 26 or result.bytes[1] > 15 or result.bytes[2] > 2 or result.bytes[3] > 3 or result.bytes[4] > 5 or result.bytes[100] > 9) @panic("invalid compiled composition plan");
    for (result.bytes[5..8]) |byte| if (byte != 0) @panic("invalid compiled composition reserved bytes");
    for (result.bytes[24..32]) |byte| if (byte != 0) @panic("invalid compiled composition reserved bytes");
    for (result.bytes[101..104]) |byte| if (byte != 0) @panic("invalid compiled composition reserved bytes");
    for (result.bytes[104 + @as(usize, result.bytes[100]) ..]) |byte| if (byte != 0) @panic("invalid compiled composition string capacity");
    return result;
}
