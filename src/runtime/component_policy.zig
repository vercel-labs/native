//! Portable menu and scroll plans; native owns payloads, pins and latch storage.
const std = @import("std");
const canvas = @import("canvas");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { shown_count, pin_owner, rebuild_arena, release_window, dismiss_token, restore_tree, selection_begin, selection_item, missing_tree, fallback_label, fallback_dismiss, fallback_item, fallback_dispatch, fallback_vanished, rebuild_views, scroll_rebuild };
pub const Plan = [16]u8;
pub fn request(stage: Stage, a: bool, b: bool, c: bool, x: u64, y: u64) [32]u8 {
    var bytes: [32]u8 = @splat(0);
    bytes[0..5].* = .{ 22, @intFromEnum(stage), @intFromBool(a), @intFromBool(b), @intFromBool(c) };
    std.mem.writeInt(u64, bytes[8..16], x, .little);
    std.mem.writeInt(u64, bytes[16..24], y, .little);
    return bytes;
}
pub fn plan(policy: Policy, stage: Stage, a: bool, b: bool, c: bool, x: u64, y: u64) Plan {
    const bytes = request(stage, a, b, c, x, y);
    if (policy) |callback| {
        var result: Plan = undefined;
        if (callback(&bytes, &result) != result.len) @panic("invalid compiled component plan size");
        const ceiling: u8 = switch (stage) {
            .pin_owner, .selection_item, .fallback_dispatch => 2,
            .selection_begin => 3,
            else => 1,
        };
        if (result[0] > ceiling or !std.mem.allEqual(u8, result[1..8], 0)) @panic("invalid compiled component action");
        if (stage != .shown_count and !std.mem.allEqual(u8, result[8..], 0)) @panic("invalid compiled component count");
        if (stage == .shown_count and (result[0] != 0 or std.mem.readInt(u64, result[8..16], .little) > @min(x, y))) @panic("invalid compiled menu count");
        return result;
    }
    return reference(stage, a, b, c, x, y);
}
pub fn reference(stage: Stage, a: bool, b: bool, c: bool, x: u64, y: u64) Plan {
    var result: Plan = @splat(0);
    result[0] = switch (stage) {
        .shown_count => 0,
        .pin_owner => if (a) 1 else if (b) 2 else 0,
        .rebuild_arena => @intFromBool(a and b and c),
        .release_window => @intFromBool(a and b and c),
        .dismiss_token => @intFromBool(a and b),
        .restore_tree => @intFromBool(a and (b or c)),
        .selection_begin => @as(u8, @intFromBool(a)) | (@as(u8, @intFromBool(b and c)) << 1),
        .selection_item => if (a and b) 1 else 2,
        .missing_tree => @intFromBool(a),
        .fallback_label => @intFromBool(a and b),
        .fallback_dismiss => @intFromBool(a and b and c),
        .fallback_item => @intFromBool(a and b and c),
        .fallback_dispatch => if (a) 1 else 2,
        .fallback_vanished => @intFromBool(a and !b),
        .rebuild_views => @intFromBool(a),
        .scroll_rebuild => @intFromBool(!a and b and c and x != 0),
    };
    if (stage == .shown_count) std.mem.writeInt(u64, result[8..16], @min(x, y), .little);
    return result;
}
pub const Reach = struct { horizontal: bool, action: enum(u8) { none, clear, store } };
pub fn reachRequest(start: bool, id_present: bool, scroll: canvas.ScrollState, vertical_fired: bool, horizontal_fired: bool) [32]u8 {
    var bytes: [32]u8 = @splat(0);
    bytes[0..6].* = .{ 23, @intFromBool(start), @intFromBool(id_present), @intFromBool(vertical_fired), @intFromBool(horizontal_fired), 0 };
    const v = scroll.axis(.vertical);
    const h = scroll.axis(.horizontal);
    const values = [_]f32{ v.offset, v.viewport_extent, v.content_extent, h.offset, h.viewport_extent, h.content_extent };
    for (values, 0..) |value, i| std.mem.writeInt(u32, bytes[8 + i * 4 ..][0..4], @bitCast(value), .little);
    return bytes;
}
pub fn reach(policy: Policy, start: bool, id_present: bool, scroll: canvas.ScrollState, vertical_fired: bool, horizontal_fired: bool) Reach {
    if (policy) |callback| {
        const bytes = reachRequest(start, id_present, scroll, vertical_fired, horizontal_fired);
        var result: [8]u8 = undefined;
        if (callback(&bytes, &result) != result.len or result[0] > 1 or result[1] > 2 or !std.mem.allEqual(u8, result[2..], 0)) @panic("invalid compiled reach plan");
        return .{ .horizontal = result[0] != 0, .action = @enumFromInt(result[1]) };
    }
    return reachReference(start, id_present, scroll, vertical_fired, horizontal_fired);
}
pub fn reachReference(start: bool, id_present: bool, scroll: canvas.ScrollState, vertical_fired: bool, horizontal_fired: bool) Reach {
    const vertical = scroll.axis(.vertical);
    const horizontal = scroll.axis(.horizontal);
    const use_horizontal = !(vertical.maxOffset() > 0) and horizontal.maxOffset() > 0;
    const axis = if (use_horizontal) horizontal else vertical;
    var result: Reach = .{ .horizontal = use_horizontal, .action = .none };
    if (!id_present or axis.viewport_extent <= 0) return result;
    const remaining = if (start) axis.offset else axis.content_extent - axis.viewport_extent - axis.offset;
    if (remaining > axis.viewport_extent * @as(f32, 1.5)) result.action = .clear else if (!(remaining > axis.viewport_extent * @as(f32, 1.0)) and !(if (use_horizontal) horizontal_fired else vertical_fired)) result.action = .store;
    return result;
}
