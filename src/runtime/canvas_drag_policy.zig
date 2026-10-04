//! Portable drag coordination over the existing copied-byte surface policy.
//! Native retains exact identities, geometry, route storage and fallible effects.
const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { admission, route, escape, source, slop, delivery, resolve, message, capture_match };
pub const Request = struct {
    stage: Stage,
    phase: u8 = 4,
    facts: u8 = 0,
    modifiers: u8 = 0,
    delta: geometry.OffsetF = .{},
};
pub fn decide(policy: Policy, request: Request) u8 {
    if (policy) |callback| {
        var bytes = [_]u8{0} ** 16;
        bytes[0..5].* = .{ 35, @intFromEnum(request.stage), request.phase, request.facts, request.modifiers };
        std.mem.writeInt(u32, bytes[8..12], @bitCast(request.delta.dx), .little);
        std.mem.writeInt(u32, bytes[12..16], @bitCast(request.delta.dy), .little);
        var result: [1]u8 = undefined;
        if (callback(&bytes, &result) != 1) @panic("invalid compiled drag result size");
        const valid = switch (request.stage) {
            .admission => result[0] == 0 or result[0] == 1 or result[0] == 2 or result[0] == 3 or result[0] == 19,
            .route => result[0] == 4 or result[0] == 36 or result[0] == 37 or result[0] == 6 or result[0] == 7 or result[0] == 71 or result[0] == 8,
            .source => result[0] == 0 or result[0] == 3,
            .delivery => result[0] <= 2,
            .resolve => result[0] == 0 or result[0] == 32 or result[0] == 5 or result[0] == 6 or result[0] == 9 or result[0] == 10,
            .message => result[0] == 0 or result[0] == 1 or result[0] == 3 or result[0] == 4 or result[0] == 5,
            else => result[0] <= 1,
        };
        if (!valid) @panic("invalid compiled drag decision");
        return result[0];
    }
    return reference(request);
}
pub fn inputPhase(kind: platform.GpuSurfaceInputKind) u8 {
    return switch (kind) {
        .pointer_down => 0,
        .pointer_drag => 1,
        .pointer_up => 2,
        .pointer_cancel => 3,
        else => 4,
    };
}
pub fn dragPhase(value: canvas.WidgetDragPhase) u8 {
    return switch (value) {
        .change => 1,
        .end => 2,
        .cancel => 3,
    };
}
pub fn modifiers(value: platform.ShortcutModifiers) u8 {
    return @as(u8, if (value.shift) 1 else 0) | @as(u8, if (value.control) 2 else 0) | @as(u8, if (value.option) 4 else 0) | @as(u8, if (value.command) 8 else 0) | @as(u8, if (value.primary) 16 else 0);
}
pub fn crossedSlop(delta: geometry.OffsetF) bool {
    return @abs(delta.dx) >= 6.0 or @abs(delta.dy) >= 6.0;
}
pub fn reference(r: Request) u8 {
    switch (r.stage) {
        .admission => {
            if (r.phase == 0) return if (r.facts & 1 == 0) 1 else 0;
            if (r.phase == 4 or r.facts & 2 == 0) return 0;
            if (r.facts & 1 == 0 and r.phase != 1) return 2;
            if (r.facts & 5 == 0) return 0;
            return 3 | @as(u8, if (r.facts & 1 != 0) 16 else 0);
        },
        .route => {
            if (r.facts & 2 == 0) return @as(u8, if (r.facts & 5 == 5) 5 else 4) | @as(u8, if (r.facts & 1 != 0) 32 else 0);
            if (r.facts & 1 == 0 and !crossedSlop(r.delta)) return 6;
            return if (r.phase == 1) 7 | @as(u8, if (r.facts & 1 == 0) 64 else 0) else 8;
        },
        .escape => return @intFromBool(r.phase == 0 and r.facts == 1 and r.modifiers == 0),
        .source => return if (r.facts == 1) 3 else 0,
        .slop => return @intFromBool(crossedSlop(r.delta)),
        .delivery => {
            if (r.facts == 0 or (r.phase == 1 and !crossedSlop(r.delta))) return 0;
            return if (r.phase == 1) 1 else 2;
        },
        .resolve => {
            if (r.phase == 1) return if (r.facts & 3 == 3) 5 else 0;
            const template: u8 = if (r.facts & 1 != 0) 1 else if (r.facts & 12 == 12) 2 else 0;
            if (template == 0) return if (r.facts & 4 != 0) 32 else 0;
            const size: u8 = if (r.facts & 2 != 0) 4 else if (r.facts & 4 != 0) 8 else 0;
            return if (size != 0) template | size else 0;
        },
        .message => {
            if (r.phase == 1) return if (r.facts & 1 != 0) 3 else 0;
            return (r.facts & 1) | @as(u8, if (r.facts & 2 != 0) 4 else 0);
        },
        .capture_match => return @intFromBool(r.facts == 15),
    }
}
