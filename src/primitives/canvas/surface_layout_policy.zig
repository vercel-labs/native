const std = @import("std");
const geometry = @import("geometry");

/// Copied frame boundary. The view/cycle consumer owns collection; invoking
/// geometry while authored model/helper slices are borrowed must not reset it.
pub const Policy = *const fn ([]const u8, []u8) usize;

pub fn frame(policy: Policy, operation: u8, a: u8, b: u8, values: []const f32) ?geometry.RectF {
    if (values.len > 19) @panic("surface request capacity");
    var request: [80]u8 = undefined;
    request[0..4].* = .{ 3, operation, a, b };
    for (values, 0..) |value, i| std.mem.writeInt(u32, request[4 + i * 4 ..][0..4], @bitCast(value), .little);
    var output: [17]u8 = undefined;
    if (policy(request[0 .. 4 + values.len * 4], &output) != output.len or output[0] > 1) @panic("invalid compiled surface frame");
    if (output[0] == 0) return null;
    return .{
        .x = read(output[1..5]),
        .y = read(output[5..9]),
        .width = read(output[9..13]),
        .height = read(output[13..17]),
    };
}
fn read(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}
