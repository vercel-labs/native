//! Portable hover message coordination through the copied-byte surface policy.
//! Native owns exact identity bytes, layout facts, deep captures and fallible effects.
const std = @import("std");
const canvas = @import("canvas");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { view, diff, refresh, refresh_entry, capture, leave, enter, unwind, drain, continuation };
pub const Request = struct { stage: Stage, a: u8 = 0, b: u8 = 0, facts: u8 = 0 };
pub fn decide(policy: Policy, r: Request) u8 {
    if (policy) |callback| {
        const bytes = [_]u8{ 36, @intFromEnum(r.stage), r.a, r.b, r.facts, 0 };
        var result: [1]u8 = undefined;
        if (callback(&bytes, &result) != 1) @panic("invalid compiled hover decision size");
        const max: u8 = switch (r.stage) {
            .view => 2,
            .capture => 4,
            .leave, .enter => 3,
            else => 1,
        };
        if (result[0] > max) @panic("invalid compiled hover decision");
        return result[0];
    }
    return reference(r);
}
pub fn reference(r: Request) u8 {
    return switch (r.stage) {
        .view => if (r.facts & 3 != 3) 0 else if (r.facts & 4 != 0) 2 else if (r.facts & 8 == 0) 1 else 0,
        .refresh => @intFromBool(r.facts & 1 != 0 and r.facts & 2 == 0 and r.facts & 12 == 12),
        .refresh_entry => @intFromBool(r.facts & 1 == 0 and r.facts & 2 != 0),
        .capture => if (r.b == 0) 1 else if (r.b == 2) 4 else if (r.a == 1) 2 else if (r.facts == 0) 3 else 0,
        .leave => if (r.facts & 1 != 0) 0 else if (r.facts & 2 != 0) 1 else if (r.facts & 12 == 12) 2 else 3,
        .enter => if (r.facts & 1 == 0) 0 else if (r.facts & 2 == 0) 1 else if (r.facts & 12 != 12) 2 else 3,
        .drain => @intFromBool(r.facts == 1),
        .continuation => @intFromBool(r.a < 64 and r.facts == 1),
        .diff, .unwind => unreachable,
    };
}
pub const Plan = struct {
    identical: bool = false,
    entering: bool = false,
    retained: [canvas.max_widget_depth]u8 = @splat(255),
    leaving: [canvas.max_widget_depth]u8 = @splat(255),
    leave_count: usize = 0,
};
pub fn plan(policy: Policy, same_view: bool, mirror: []const canvas.ObjectId, standing: []const canvas.ObjectId) Plan {
    if (policy) |callback| {
        var bytes: [6 + canvas.max_widget_depth * 16]u8 = undefined;
        bytes[0..6].* = .{ 36, 1, @intFromBool(same_view), @intCast(mirror.len), @intCast(standing.len), 0 };
        var offset: usize = 6;
        for (mirror) |id| {
            std.mem.writeInt(u64, bytes[offset..][0..8], id, .little);
            offset += 8;
        }
        for (standing) |id| {
            std.mem.writeInt(u64, bytes[offset..][0..8], id, .little);
            offset += 8;
        }
        var output: [3 + canvas.max_widget_depth * 2]u8 = undefined;
        const size = 3 + standing.len + mirror.len;
        if (callback(bytes[0..offset], output[0..size]) != size or output[0] > 1 or output[1] > 1 or output[2] > mirror.len) @panic("invalid compiled hover plan");
        var out: Plan = .{ .identical = output[0] == 1, .entering = output[1] == 1, .leave_count = output[2] };
        for (output[3..][0..standing.len], 0..) |index, position| {
            if (index != 255 and index >= mirror.len) @panic("invalid compiled hover retained index");
            out.retained[position] = index;
        }
        for (output[3 + standing.len ..][0..mirror.len], 0..) |index, position| {
            if (position < out.leave_count) {
                if (index >= mirror.len or (position > 0 and index >= out.leaving[position - 1])) @panic("invalid compiled hover leave order");
            } else if (index != 255) @panic("invalid compiled hover reserved index");
            out.leaving[position] = index;
        }
        return out;
    }
    return referencePlan(same_view, mirror, standing);
}
pub fn referencePlan(same_view: bool, mirror: []const canvas.ObjectId, standing: []const canvas.ObjectId) Plan {
    var out: Plan = .{ .identical = same_view and mirror.len == standing.len };
    for (standing, 0..) |id, position| {
        if (same_view) for (mirror, 0..) |candidate, index| {
            if (candidate != id) continue;
            out.retained[position] = @intCast(index);
            if (position != index) out.identical = false;
            break;
        };
        if (out.retained[position] == 255) {
            out.entering = true;
            out.identical = false;
        }
    }
    var index = mirror.len;
    while (index > 0) {
        index -= 1;
        var retained = false;
        if (same_view) for (standing) |id| {
            if (id == mirror[index]) {
                retained = true;
                break;
            }
        };
        if (!retained) {
            out.leaving[out.leave_count] = @intCast(index);
            out.leave_count += 1;
        }
    }
    return out;
}
pub const Compaction = struct { kept: [canvas.max_widget_depth]u8 = @splat(255), len: usize = 0 };
pub fn unwind(policy: Policy, entering: []const bool, from: usize) Compaction {
    var out: Compaction = .{};
    if (policy) |callback| {
        var bytes: [6 + canvas.max_widget_depth]u8 = undefined;
        bytes[0..6].* = .{ 36, 7, @intCast(from), @intCast(entering.len), 0, 0 };
        for (entering, 0..) |flag, index| bytes[6 + index] = @intFromBool(flag);
        var result: [1 + canvas.max_widget_depth]u8 = undefined;
        const size = 1 + entering.len;
        if (callback(bytes[0 .. 6 + entering.len], result[0..size]) != size or result[0] > entering.len) @panic("invalid compiled hover compaction");
        out.len = result[0];
        for (result[1..size], 0..) |index, position| {
            if (position < out.len) {
                if (index >= entering.len or (position > 0 and index <= out.kept[position - 1])) @panic("invalid compiled hover kept index");
            } else if (index != 255) @panic("invalid compiled hover reserved index");
            out.kept[position] = index;
        }
        return out;
    }
    for (entering, 0..) |flag, index| {
        if (index >= from and flag) continue;
        out.kept[out.len] = @intCast(index);
        out.len += 1;
    }
    return out;
}
