//! Copied scalar values and original f32 numeric capabilities. The compiled
//! owner implements integer/boolean/comparison semantics and selects failures.
//! No arena allocation or borrowed pointer crosses the policy boundary.
const std = @import("std");
const expr = @import("ui_markup_expr.zig");

fn encode(request: []u8, at: usize, value: expr.Value) void {
    switch (value) {
        .integer => |number| std.mem.writeInt(i64, request[at..][0..8], number, .little),
        .float => |number| std.mem.writeInt(u32, request[at..][0..4], @bitCast(number), .little),
        .string => |bytes| std.mem.writeInt(u64, request[at..][0..8], @intCast(bytes.len), .little),
        .boolean => {},
    }
}

fn numeric(value: expr.Value) f32 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => 0,
    };
}

fn invoke(owner: expr.Policy, request: []const u8) [16]u8 {
    var out: [16]u8 = undefined;
    const size = owner(request, &out);
    if (size != out.len or out[0] != 105 or out[1] != 1 or out[2] > 2 or out[5] > 1 or out[6] != 0 or out[7] != 0)
        @panic("invalid scalar expression reply");
    if (out[2] == 0) {
        if (out[3] < 2 or out[3] > 4 or out[4] != 0 or out[3] != 4 and out[5] != 0 or
            out[3] == 3 and std.mem.readInt(u32, out[12..16], .little) != 0 or
            out[3] == 4 and std.mem.readInt(u64, out[8..16], .little) != 0)
            @panic("invalid scalar expression value");
    } else if (out[3] != 0 or out[5] != 0 or std.mem.readInt(u64, out[8..16], .little) != 0 or
        out[2] == 2 and out[4] != 0)
        @panic("invalid scalar expression control");
    return out;
}

fn equalBlocks(owner: expr.Policy, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) @panic("invalid scalar comparison request");
    var offset: usize = 0;
    while (offset < a.len) {
        const len: usize = @min(@as(usize, 256), a.len - offset);
        var request: [16 + 512]u8 = @splat(0);
        request[0..8].* = .{ 105, 1, 9, 1, 1, 2, 0, 0 };
        std.mem.writeInt(u16, request[8..10], @intCast(len), .little);
        std.mem.writeInt(u16, request[10..12], @intCast(len), .little);
        @memcpy(request[16..][0..len], a[offset..][0..len]);
        @memcpy(request[16 + len ..][0..len], b[offset..][0..len]);
        const out = invoke(owner, request[0 .. 16 + len * 2]);
        if (out[2] != 0 or out[3] != 4) @panic("invalid scalar comparison result");
        if (out[5] == 0) return false;
        offset += len;
    }
    return true;
}

fn failure(code: u8) []const u8 {
    return switch (code) {
        1 => expr.negate_type_message,
        2 => expr.logic_type_message,
        3 => expr.arithmetic_type_message,
        4 => expr.ordering_type_message,
        6 => expr.integer_overflow_message,
        7 => expr.division_by_zero_message,
        8 => expr.non_finite_message,
        9 => expr.abs_overflow_message,
        10 => expr.round_range_message,
        25...30 => expr.function_specs[code - 16].signature,
        else => @panic("invalid scalar expression failure"),
    };
}

pub fn evaluate(owner: expr.Policy, capability: u8, a: expr.Value, b: expr.Value) expr.EvalOutcome {
    var request: [48]u8 = @splat(0);
    request[0..8].* = .{ 105, 1, capability, @as(u8, @intFromEnum(expr.kindOf(a))) + 1, @as(u8, @intFromEnum(expr.kindOf(b))) + 1, 0, if (a == .boolean and a.boolean) 1 else 0, if (b == .boolean and b.boolean) 1 else 0 };
    encode(&request, 8, a);
    encode(&request, 16, b);
    const fa = numeric(a);
    const fb = numeric(b);
    std.mem.writeInt(u32, request[24..28], @bitCast(fa), .little);
    std.mem.writeInt(u32, request[28..32], @bitCast(fb), .little);
    // These are the original f32 primitives, including min/max zero ties
    // and round's ties away from zero. The owner admits their results.
    const primitive: f32 = switch (capability) {
        4 => fa + fb,
        5 => fa - fb,
        6 => fa * fb,
        7 => fa / fb,
        27 => @min(fa, fb),
        28 => @max(fa, fb),
        30 => @round(fa),
        31 => @floor(fa),
        32 => @ceil(fa),
        else => 0,
    };
    std.mem.writeInt(u32, request[32..36], @bitCast(primitive), .little);
    var out = invoke(owner, &request);
    if (out[2] == 2) {
        if ((capability != 9 and capability != 10) or a != .string or b != .string or a.string.len != b.string.len)
            @panic("invalid scalar comparison capability");
        request[5] = 1;
        request[6] = if (equalBlocks(owner, a.string, b.string)) 1 else 0;
        out = invoke(owner, &request);
        if (out[2] == 2) @panic("incomplete scalar comparison");
    }
    if (out[2] == 1) return .{ .fail = failure(out[4]) };
    return .{ .value = switch (out[3]) {
        2 => .{ .integer = std.mem.readInt(i64, out[8..16], .little) },
        3 => .{ .float = @bitCast(std.mem.readInt(u32, out[8..12], .little)) },
        4 => .{ .boolean = out[5] != 0 },
        else => unreachable,
    } };
}
