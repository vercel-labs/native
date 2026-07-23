//! Value conversion between structurally-equivalent mirror types —
//! shared by the sidecar suites: the conformance suite converts
//! transpiled-module values into sidecar-classed shim layouts for the
//! facade parity axis, and the compiled-core behavior-parity suite
//! converts scripted messages and reference models the same way.

const std = @import("std");

/// Convert a value between two structurally-equivalent mirror types by
/// field/arm/member NAME, normalizing numeric classes and reference
/// storage (pointers deref on read, re-materialize on write).
pub fn convertValue(comptime Target: type, value: anytype, allocator: std.mem.Allocator) !Target {
    const Source = @TypeOf(value);
    if (@typeInfo(Source) == .pointer and @typeInfo(Source).pointer.size == .one) {
        return convertValue(Target, value.*, allocator);
    }
    switch (@typeInfo(Target)) {
        .bool => return value,
        .int => return switch (@typeInfo(Source)) {
            .int => @intCast(value),
            .float => @intFromFloat(value),
            else => @compileError("cannot convert " ++ @typeName(Source) ++ " to " ++ @typeName(Target)),
        },
        .float => return switch (@typeInfo(Source)) {
            .float => @floatCast(value),
            .int => @floatFromInt(value),
            else => @compileError("cannot convert " ++ @typeName(Source) ++ " to " ++ @typeName(Target)),
        },
        .@"enum" => {
            switch (value) {
                inline else => |tag| return @field(Target, @tagName(tag)),
            }
        },
        .optional => |info| {
            if (value) |inner| return try convertValue(info.child, inner, allocator);
            return null;
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) return allocator.dupe(u8, value);
                const out = try allocator.alloc(info.child, value.len);
                for (out, value) |*slot, element| {
                    slot.* = try convertValue(info.child, element, allocator);
                }
                return out;
            },
            .one => {
                const out = try allocator.create(info.child);
                out.* = try convertValue(info.child, value, allocator);
                return out;
            },
            else => @compileError("no conversion for " ++ @typeName(Target)),
        },
        .@"struct" => |info| {
            var out: Target = undefined;
            inline for (info.fields) |field| {
                @field(out, field.name) = try convertValue(field.type, @field(value, field.name), allocator);
            }
            return out;
        },
        .@"union" => |info| {
            switch (value) {
                inline else => |payload, tag| {
                    inline for (info.fields) |field| {
                        if (comptime std.mem.eql(u8, field.name, @tagName(tag))) {
                            if (field.type == void) return @unionInit(Target, field.name, {});
                            return @unionInit(Target, field.name, try convertValue(field.type, payload, allocator));
                        }
                    }
                    unreachable;
                },
            }
        },
        else => @compileError("no conversion for " ++ @typeName(Target)),
    }
}
