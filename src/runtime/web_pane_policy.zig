//! Copied pane plans. Native retains complete text, layout and slot storage;
//! only equality observations, numeric capabilities and bounded ordinals cross.
const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
const limits = @import("canvas_limits.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
// Probe the same constant-zero f32 operation as the native pane owner.
// Two variable zero operands can select a different sign on the same target.
fn originNumericFlags() u8 {
    var value: f32 = -0.0;
    std.mem.doNotOptimizeAway(&value);
    return if (@as(u32, @bitCast(@max(value, 0))) == 0x80000000) 4 else 0;
}
fn header(comptime length: usize, mode: u8) [length]u8 {
    var bytes: [length]u8 = @splat(0);
    bytes[0..2].* = .{ 99, mode };
    return bytes;
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn wide(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn get(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn rect(bytes: []u8, at: usize, value: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |field, i| put(bytes, at + i * 4, @bitCast(@field(value, field)));
}
fn run(policy: Policy, request: []const u8, result: []u8) void {
    if (policy(request, result) != result.len) @panic("invalid web pane plan length");
}
pub const Frame = struct { kind: enum(u32) { missing_anchor, collapsed, apply }, value: geometry.RectF };
pub fn frame(policy: Policy, nodes: []const canvas.WidgetLayoutNode, explicit: geometry.RectF, anchor: ?[]const u8) Frame {
    const count = if (anchor != null) nodes.len else 0;
    if (count > limits.max_canvas_widget_nodes_per_view) @panic("web pane layout capacity");
    var request = header(32 + limits.max_canvas_widget_nodes_per_view * 20, 0);
    request[2] = originNumericFlags();
    put(&request, 4, @intCast(count));
    put(&request, 8, @intFromBool(anchor != null));
    rect(&request, 16, explicit);
    for (nodes[0..count], 0..) |node, i| {
        const at = 32 + i * 20;
        put(&request, at, @intFromBool(std.mem.eql(u8, node.widget.semantics.label, anchor.?)));
        rect(&request, at + 4, node.frame);
    }
    var out: [24]u8 = undefined;
    run(policy, request[0 .. 32 + count * 20], &out);
    const kind = get(&out, 0);
    const selected = get(&out, 4);
    if (kind > 2 or (kind == 0 and anchor == null) or (selected != std.math.maxInt(u32) and (selected >= count or anchor == null or
        !std.mem.eql(u8, nodes[selected].widget.semantics.label, anchor.?))) or
        (kind == 2 and anchor != null and selected == std.math.maxInt(u32))) @panic("invalid web pane frame capability");
    return .{ .kind = @enumFromInt(kind), .value = .{
        .x = @bitCast(get(&out, 8)),
        .y = @bitCast(get(&out, 12)),
        .width = @bitCast(get(&out, 16)),
        .height = @bitCast(get(&out, 20)),
    } };
}
pub const Slot = struct { index: usize, create: bool, label_bytes: usize };
pub fn slot(policy: Policy, states: anytype, label: []const u8, capacity: usize) ?Slot {
    if (states.len > 4 or capacity > 64) @panic("web pane slot capacity");
    var request = header(32, 1);
    put(&request, 4, @intCast(states.len));
    wide(&request, 8, label.len);
    put(&request, 16, @intCast(capacity));
    for (states, 0..) |state, i| request[20 + i] = @intFromBool(std.mem.eql(u8, state.label_storage[0..state.label_len], label));
    var out: [12]u8 = undefined;
    run(policy, &request, &out);
    const kind = get(&out, 0);
    const index = get(&out, 4);
    const bytes = get(&out, 8);
    if (kind > 2 or bytes > capacity or bytes > label.len or (kind == 1 and (index >= states.len or bytes != 0 or
        !std.mem.eql(u8, states[index].label_storage[0..states[index].label_len], label))) or
        (kind == 2 and (index != states.len or index >= 4))) @panic("invalid web pane slot capability");
    if (kind == 0) {
        if (index != std.math.maxInt(u32) or bytes != 0) @panic("invalid web pane exhausted slot");
        return null;
    }
    return .{ .index = index, .create = kind == 2, .label_bytes = bytes };
}
pub const Patch = packed struct(u8) { frame: bool, url: bool, reserved: u6 = 0 };
pub fn patch(policy: Policy, actual: geometry.RectF, desired: geometry.RectF, previous_url: []const u8, url: []const u8, previous_token: u64, token: u64) Patch {
    var request = header(64, 2);
    put(&request, 4, @as(u32, @intFromBool(previous_url.len == 0)) | (@as(u32, @intFromBool(std.mem.eql(u8, previous_url, url))) << 1) |
        (@as(u32, @intFromBool(url.len > 0)) << 2));
    rect(&request, 8, desired);
    rect(&request, 24, actual);
    wide(&request, 40, previous_token);
    wide(&request, 48, token);
    var out: [4]u8 = undefined;
    run(policy, &request, &out);
    if (get(&out, 0) > 3) @panic("invalid web pane patch capability");
    return @bitCast(out[0]);
}
pub fn commit(policy: Policy, success: bool, length: usize, capacity: usize) ?usize {
    if (capacity > 4096) @panic("web pane URL capacity");
    var request = header(32, 3);
    put(&request, 4, @intFromBool(success));
    wide(&request, 8, length);
    put(&request, 16, @intCast(capacity));
    var out: [8]u8 = undefined;
    run(policy, &request, &out);
    const admitted = get(&out, 0);
    const bytes = get(&out, 4);
    if (admitted > 1 or bytes > length or bytes > capacity or (admitted == 0 and bytes != 0) or (admitted == 1 and !success)) @panic("invalid web pane commit capability");
    return if (admitted == 1) bytes else null;
}
