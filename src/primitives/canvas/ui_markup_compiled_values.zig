//! Runtime value capabilities for statically lowered markup. The same compiled
//! programs used by the interpreter admit values and select borrowed keys/enum
//! fields. Native retains exact integer bounds, numeric casts and typed storage.
const std = @import("std");
const markup = @import("ui_markup.zig");
const values = @import("ui_markup_values.zig");
const elements = @import("ui_markup_elements.zig");
const canvas = @import("root.zig");

pub fn enumValue(comptime T: type, owner: markup.expr.Policy, text: []const u8) ?T {
    var request = values.Request.init(15);
    defer request.deinit();
    request.blob(text);
    const fields = @typeInfo(T).@"enum".fields;
    request.word(fields.len);
    inline for (fields) |field| request.blob(field.name);
    const row = request.decision(owner);
    if (row.action == 0) return null;
    if (row.action != 74 or row.fields[0] >= fields.len) @panic("invalid compiled markup enum capability");
    inline for (fields, 0..) |field, index| if (row.fields[0] == index) return @field(T, field.name);
    unreachable;
}

pub fn convert(comptime T: type, owner: markup.expr.Policy, value: markup.expr.Value, comptime payload: bool) ?T {
    const class = comptime values.typeClass(T);
    const within = if (comptime class == 4)
        value == .integer and value.integer >= (if (payload) std.math.minInt(T) else 0) and value.integer <= std.math.maxInt(T)
    else
        false;
    const row = values.decide(owner, if (payload) 5 else 4, &.{ class, values.kind(value), @intFromBool(within) });
    if (row.action == 255) return null;
    if (row.action != class) @panic("invalid compiled markup conversion capability");
    return switch (comptime class) {
        1 => switch (value) {
            .float => |number| @floatCast(number),
            .integer => |number| @floatFromInt(number),
            else => unreachable,
        },
        2 => markup.expr.truthyWithPolicy(owner, value),
        3 => enumValue(T, owner, value.string),
        4 => @intCast(value.integer),
        5 => value.string,
        else => unreachable,
    };
}

pub fn key(owner: markup.expr.Policy, value: markup.expr.Value, omitted_default: bool) error{InvalidValue}!?canvas.UiKey {
    const row = elements.decide(owner, 4, &.{ 1, @intFromBool(omitted_default), 1, switch (value) {
        .integer => 0,
        .float => 1,
        .string => 2,
        .boolean => 3,
    }, @intFromBool(value == .string and value.string.len == 0) });
    return switch (row.action) {
        0 => null,
        1 => canvas.uiKey(@as(u64, @bitCast(value.integer))),
        2 => canvas.uiKey(value.string),
        255 => error.InvalidValue,
        else => @panic("invalid compiled markup key capability"),
    };
}

pub fn resource(owner: markup.expr.Policy, value: markup.expr.Value, channel: u8) elements.Record {
    return values.decide(owner, 1, &.{ channel, values.kind(value), @intFromBool(value == .integer and value.integer >= 0) });
}

/// Policy sees exact i64 words and selects admission/clamping; native casts the original value.
pub fn collectionIndex(owner: markup.expr.Policy, value: markup.expr.Value, comptime clamp_negative: bool) ?usize {
    const row = values.integerOption(owner, if (clamp_negative) 1 else 0, value, 0);
    return switch (row.action) {
        1 => @intCast(value.integer),
        2 => if (clamp_negative) 0 else @panic("invalid static index clamp capability"),
        255 => null,
        else => @panic("invalid static index capability"),
    };
}
