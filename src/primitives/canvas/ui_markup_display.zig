//! Numeric rendering and arena capabilities for copied display programs.
//! Plans contain no pointers and are fully admitted before any allocation.
const std = @import("std");
const expr = @import("ui_markup_expr.zig");

fn execute(owner: expr.Policy, mode: u8, value: expr.Value, digits: usize, out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) error{OutOfMemory}!bool {
    const kind: u8 = @as(u8, @intFromEnum(expr.kindOf(value))) + 1;
    const request = [8]u8{ 104, 1, mode, kind, @intCast(digits), if (value == .boolean and value.boolean) 1 else 0, 0, 0 };
    var output: [40]u8 = undefined;
    const size = owner(&request, &output);
    if (size < 8 or size > output.len or output[0] != 104 or output[1] != 1 or output[2] != mode or
        output[3] == 0 or output[3] > 6 or output[4] > 5 or output[5] != 0 or output[6] != 0 or output[7] != 0 or
        size != 8 + @as(usize, output[3]) * 4 + output[4]) @panic("invalid markup display header");
    const literal = output[8 + @as(usize, output[3]) * 4 .. size];
    var prepared = false;
    var rendered = false;
    for (0..output[3]) |i| {
        const at = 8 + i * 4;
        const a = output[at + 1];
        const b = output[at + 2];
        if (output[at + 3] != 0) @panic("invalid markup display instruction");
        switch (output[at]) {
            0, 1 => {
                if (kind != (if (output[at] == 0) @as(u8, 2) else 3) or b != 0 or a != (if (mode == 0) @as(usize, 0) else digits))
                    @panic("invalid markup numeric capability");
                rendered = true;
            },
            2 => {
                if (mode != 2 or (value != .integer and value != .float) or a != 0 or b != 0) @panic("invalid markup scaling capability");
                prepared = true;
            },
            3 => {
                if (mode == 0 or (mode == 2 and !prepared) or (mode == 1 and value != .float) or a != digits or b != 0)
                    @panic("invalid markup decimal capability");
                rendered = true;
            },
            4 => if (value != .string or a != 0 or b != 0) @panic("invalid markup source capability"),
            5 => if (!rendered or a != 0 or b != 0) @panic("invalid markup body capability"),
            6 => if (@as(usize, a) + b > literal.len) @panic("invalid markup literal capability"),
            7 => if (b > 6) @panic("invalid markup repeat capability"),
            else => @panic("unknown markup display capability"),
        }
    }
    var buffer: [80]u8 = undefined;
    var body: []const u8 = undefined;
    var number: f32 = undefined;
    for (0..output[3]) |i| {
        const at = 8 + i * 4;
        const a = output[at + 1];
        const b = output[at + 2];
        switch (output[at]) {
            0 => body = std.fmt.bufPrint(buffer[0..64], "{d}", .{value.integer}) catch return error.OutOfMemory,
            1 => body = std.fmt.bufPrint(buffer[0..64], "{d}", .{value.float}) catch return error.OutOfMemory,
            2 => {
                const fraction: f32 = if (value == .integer) @floatFromInt(value.integer) else value.float;
                number = fraction * 100;
                if (!std.math.isFinite(number)) return false;
            },
            3 => {
                const float = if (mode == 2) number else value.float;
                if (!std.math.isFinite(float)) return false;
                body = std.fmt.float.render(&buffer, float, .{ .mode = .decimal, .precision = a }) catch return false;
            },
            4 => try out.appendSlice(arena, value.string),
            5 => try out.appendSlice(arena, body),
            6 => try out.appendSlice(arena, literal[a..][0..b]),
            7 => try out.appendNTimes(arena, a, b),
            else => unreachable,
        }
    }
    return true;
}

pub fn append(owner: expr.Policy, out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, value: expr.Value) error{OutOfMemory}!void {
    if (!try execute(owner, 0, value, 0, out, arena)) unreachable;
}

pub fn fixed(owner: expr.Policy, value: expr.Value, digits: usize, percent: bool, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (!try execute(owner, if (percent) 2 else 1, value, digits, &out, arena)) return null;
    return out.items;
}
