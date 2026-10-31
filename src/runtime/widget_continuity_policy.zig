//! Rebuild continuity decisions. Exact identities and complete source/physics
//! records stay native; compiled code sees copied facts and returns action bits.
const std = @import("std");
const canvas = @import("canvas");
const limits = @import("canvas_limits.zig");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Plan = struct { actions: [limits.max_canvas_widget_nodes_per_view]u8 = undefined };

pub fn layout(policy: Policy, nodes: []const canvas.WidgetLayoutNode, previous: anytype, semantics: anytype) ?Plan {
    const callback = policy orelse return null;
    var input: [8 + limits.max_canvas_widget_nodes_per_view * 24]u8 = undefined;
    const bytes = header(&input, nodes.len, 0);
    for (nodes, 0..) |node, i| {
        const w = node.widget;
        const fact = bytes[8 + i * 24 ..][0..24];
        fact[0] = bit(w.id != 0, 0) | bit(w.kind == .scroll_view, 1) |
            bit(canvas.widgetScrollsAxis(w, .vertical), 2) | bit(canvas.widgetScrollsAxis(w, .horizontal), 3);
        float(fact[4..8], w.value);
        float(fact[8..12], w.value_x);
        if (w.kind == .scroll_view and w.id != 0) for (previous) |entry| {
            if (entry.id != w.id) continue;
            fact[0] |= 16;
            float(fact[12..16], entry.state.offset_y);
            float(fact[16..20], entry.state.offset_x);
            break;
        };
        if (semantics.first(w.id)) |source| fact[0] |= 32 | bit(source.list.present, 6) | bit(source.scroll.present, 7);
    }
    return finish(callback, bytes, nodes.len, 0);
}

pub fn semanticsPlan(policy: Policy, nodes: []const canvas.WidgetSemanticsNode, sources: anytype) ?Plan {
    const callback = policy orelse return null;
    var input: [8 + limits.max_canvas_widget_nodes_per_view * 24]u8 = undefined;
    const bytes = header(&input, nodes.len, 1);
    for (nodes, 0..) |node, i| {
        if (sources.first(node.id)) |source| bytes[8 + i * 24] = 32 | bit(source.list.present, 6) | bit(source.scroll.present, 7);
    }
    return finish(callback, bytes, nodes.len, 1);
}

fn header(input: []u8, count: usize, mode: u8) []u8 {
    if (count > limits.max_canvas_widget_nodes_per_view) @panic("widget continuity exceeds view budget");
    const bytes = input[0 .. 8 + count * 24];
    @memset(bytes, 0);
    bytes[0] = 95;
    bytes[1] = mode;
    std.mem.writeInt(u32, bytes[4..8], @intCast(count), .little);
    return bytes;
}
fn finish(callback: *const fn ([]const u8, []u8) usize, bytes: []const u8, count: usize, mode: u8) Plan {
    var output: [8 + limits.max_canvas_widget_nodes_per_view]u8 = undefined;
    const size = callback(bytes, &output);
    if (size != 8 + count or output[0] != 95 or output[1] != mode or output[2] != 0 or output[3] != 0 or
        std.mem.readInt(u32, output[4..8], .little) != count) @panic("invalid compiled widget continuity header");
    var plan = Plan{};
    for (plan.actions[0..count], 0..) |*action, i| {
        const flags = output[8 + i];
        const facts = bytes[8 + i * 24];
        if ((flags & (if (mode == 0) @as(u8, 242) else @as(u8, 253))) != 0 or
            (flags & 1 != 0 and facts & 96 != 96) or (flags & 2 != 0 and facts & 160 != 160) or
            (flags & 4 != 0 and facts & 23 != 23) or (flags & 8 != 0 and facts & 27 != 27))
            @panic("invalid compiled widget continuity action");
        action.* = flags;
    }
    return plan;
}
fn bit(value: bool, shift: u3) u8 {
    return @as(u8, @intFromBool(value)) << shift;
}
fn float(bytes: *[4]u8, value: f32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}
