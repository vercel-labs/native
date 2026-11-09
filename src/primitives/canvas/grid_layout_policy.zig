const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const surface = @import("surface_layout_policy.zig");

pub const Policy = surface.Policy;
pub const Plan = struct {
    columns: usize,
    rows: usize,
    start: usize,
    end: usize,
    width: f32,
    height: f32,
    gap: f32,
    offset: f32,
    item_extent: f32,
};

/// Native supplies integer conversion facts and measured row height. All
/// placement/window arithmetic belongs to the compiled planner. Results are
/// copied before recursion; the enclosing view/cycle owns arena collection.
pub fn plan(policy: Policy, count: usize, columns: usize, overscan: usize, content: geometry.RectF, gap: f32, item_extent: f32, measured_extent: f32, scroll: f32, virtual: bool) Plan {
    var request: [76]u8 = undefined;
    request[0..4].* = .{ 4, 0, (if (virtual) @as(u8, 1) else 0) | (surface.anchorFlags(0, false) >> 2) | (if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) @as(u8, 4) else 0), 0 };
    for ([_]usize{ count, columns, overscan }, 0..) |value, i| std.mem.writeInt(u64, request[4 + i * 8 ..][0..8], value, .little);
    const values = [_]f32{ content.x, content.y, content.width, content.height, gap, item_extent, measured_extent, scroll, @floatFromInt(count), @floatFromInt(columns), @floatFromInt(count -| 1), @floatFromInt(columns -| 1) };
    for (values, 0..) |value, i| std.mem.writeInt(u32, request[28 + i * 4 ..][0..4], @bitCast(value), .little);
    var output: [52]u8 = undefined;
    if (policy(&request, &output) != output.len) @panic("invalid compiled grid plan length");
    const result = Plan{ .columns = integer(output[0..8]), .rows = integer(output[8..16]), .start = integer(output[16..24]), .end = integer(output[24..32]), .width = float(output[32..36]), .height = float(output[36..40]), .gap = float(output[40..44]), .offset = float(output[44..48]), .item_extent = float(output[48..52]) };
    if (result.rows > count or result.start > result.rows or result.end > (if (virtual) result.rows else count) or (count > 0 and result.columns == 0)) @panic("invalid compiled grid indices");
    return result;
}

pub fn frame(policy: Policy, grid: Plan, index: usize, content: geometry.RectF, authored: geometry.RectF, min: geometry.SizeF, max: geometry.SizeF, virtual: bool, fills_width: bool) geometry.RectF {
    var request: [76]u8 = undefined;
    request[0..4].* = .{ 4, 1, (if (virtual) @as(u8, 1) else 0) | (if (fills_width) @as(u8, 2) else 0), 0 };
    std.mem.writeInt(u64, request[4..12], index, .little);
    std.mem.writeInt(u64, request[12..20], grid.columns, .little);
    const values = [_]f32{ content.x, content.y, grid.width, grid.height, grid.gap, grid.offset, authored.x, authored.y, authored.width, authored.height, min.width, min.height, max.width, max.height };
    for (values, 0..) |value, i| std.mem.writeInt(u32, request[20 + i * 4 ..][0..4], @bitCast(value), .little);
    var output: [17]u8 = undefined;
    if (policy(&request, &output) != output.len or output[0] != 1) @panic("invalid compiled grid frame");
    return .init(float(output[1..5]), float(output[5..9]), float(output[9..13]), float(output[13..17]));
}
fn integer(bytes: *const [8]u8) usize {
    return std.math.cast(usize, std.mem.readInt(u64, bytes, .little)) orelse @panic("compiled grid index exceeds usize");
}
fn float(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}
