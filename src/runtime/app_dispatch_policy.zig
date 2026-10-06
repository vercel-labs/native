//! Portable dispatch scheduling with copied plans and native-owned execution.
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { dispatch_begin, update, dispatch_render, drain_installed, drain_pending, drain_rebuild, video_rebuild, secondary, direct_tail, event_tail, error_selection };
pub const Action = enum(u8) { end, bind, sync, apply, audio, update_fx, update, relational_flush, main, pending_query, capture_drain, video_query, secondary, hover, take_error };
pub const Plan = [16]u8;
pub fn plan(policy: Policy, stage: Stage, a: u8, b: u8) Plan {
    const request = [_]u8{ 19, @intFromEnum(stage), a, b, 0, 0 };
    if (policy) |callback| {
        var result: Plan = undefined;
        if (callback(&request, &result) != result.len) @panic("invalid compiled app dispatch plan size");
        const allowed: u16 = switch (stage) {
            .dispatch_begin => (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4),
            .update => (1 << 5) | (1 << 6) | (1 << 7),
            .dispatch_render, .video_rebuild => 1 << 8,
            .drain_installed => 1 << 9,
            .drain_pending => (1 << 1) | (1 << 2) | (1 << 10) | (1 << 4),
            .drain_rebuild => (1 << 8) | (1 << 11),
            .secondary => 1 << 12,
            .direct_tail, .event_tail => 1 << 13,
            .error_selection => 1 << 14,
        };
        var ended = false;
        var seen: u16 = 0;
        for (result) |byte| {
            if (byte == 0) {
                ended = true;
                continue;
            }
            if (ended or byte > @intFromEnum(Action.take_error)) @panic("invalid compiled app dispatch action");
            const bit = @as(u16, 1) << @as(u4, @intCast(byte));
            if (allowed & bit == 0) @panic("unexpected compiled app dispatch stage action");
            if (seen & bit != 0) @panic("duplicate compiled app dispatch action");
            seen |= bit;
        }
        return result;
    }
    return reference(stage, a, b);
}
pub fn reference(stage: Stage, a: u8, b: u8) Plan {
    var result: Plan = @splat(0);
    switch (stage) {
        .dispatch_begin => result[0..4].* = .{ 1, 2, 3, 4 },
        .update => result[0..2].* = .{ if (a != 0) 5 else 6, 7 },
        .dispatch_render, .video_rebuild => {
            if (a != 0) result[0] = 8;
        },
        .drain_installed => {
            if (a != 0) result[0] = 9;
        },
        .drain_pending => {
            if (a != 0) result[0..4].* = .{ 1, 2, 10, 4 };
        },
        .drain_rebuild => result[0] = if (a != 0) 8 else if (b != 0) 11 else 0,
        .secondary => {
            if (a == 0) result[0] = 12;
        },
        .direct_tail => {
            if (a != 0 and b == 0) result[0] = 13;
        },
        .event_tail => {
            if (a == 0 or (a == 2 and b != 0)) result[0] = 13;
        },
        .error_selection => {
            if (a == 0 and b != 0) result[0] = 14;
        },
    }
    return result;
}
