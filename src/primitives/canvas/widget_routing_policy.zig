//! Copied routing boundary. Native owns request/result/caller storage and
//! reconstructs typed records; the portable owner selects every target/path.
const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const events = @import("events.zig");
const tokens_model = @import("tokens.zig");
pub const Policy = @import("surface_layout_policy.zig").Policy;
const missing = std.math.maxInt(u32);
const roles = [_]widgets.WidgetRole{ .none, .group, .text, .link, .image, .button, .textbox, .tooltip, .dialog, .menu, .menuitem, .list, .listitem, .row, .grid, .gridcell, .tab, .checkbox, .radio, .radiogroup, .switch_control, .slider, .progressbar, .chart, .tree, .treeitem, .separator };
comptime {
    if (roles.len != @typeInfo(widgets.WidgetRole).@"enum".fields.len) @compileError("update routing role codes");
}
pub fn owner(layout: anytype) ?Policy {
    const T = switch (@typeInfo(@TypeOf(layout))) {
        .pointer => |p| p.child,
        else => @TypeOf(layout),
    };
    if (comptime @hasField(T, "routing_policy")) return layout.routing_policy;
    return null;
}
fn roleCode(role: widgets.WidgetRole) u32 {
    for (roles, 0..) |value, i| if (value == role) return @intCast(i);
    unreachable;
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn float(bytes: []u8, at: usize, value: f32) void {
    put(bytes, at, @bitCast(value));
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub const Result = struct {
    status: u8,
    keep_hit: bool,
    target: ?usize,
    press: ?usize,
    len: usize,
    indices: [63]usize = undefined,
    phases: [63]events.WidgetEventPhase = undefined,

    pub fn copy(self: Result, layout: anytype, output: []events.WidgetEventRouteEntry) @import("root.zig").Error![]const events.WidgetEventRouteEntry {
        for (0..self.len) |i| {
            const index = self.indices[i];
            const node = layout.nodes[index];
            output[i] = .{ .phase = self.phases[i], .node_index = index, .id = node.widget.id, .kind = node.widget.kind, .bounds = node.frame };
        }
        // The reference preserves the already-written prefix on overflow.
        if (self.status == 1) return error.WidgetDepthExceeded;
        if (self.status == 2) return error.WidgetEventRouteListFull;
        return output[0..self.len];
    }
};
fn readIndex(value: u32, count: usize) ?usize {
    if (value == missing) return null;
    if (value >= count) @panic("invalid compiled routing index");
    return value;
}
/// op is a protocol query, param is its phase/direction. The portable owner
/// requests scroll observations only when ordinary focus gates need them.
pub fn query(layout: anytype, policy: Policy, comptime op: u8, param: u8, subject: ?usize, id: ?u64, point: geometry.PointF, tokens: tokens_model.DesignTokens, capacity: usize, scroll_semantics_fn: anytype) Result {
    const allocator = std.heap.page_allocator;
    const count = std.math.cast(u32, layout.nodes.len) orelse @panic("routing node capacity");
    const length = std.math.add(usize, 64, std.math.mul(usize, count, 96) catch @panic("routing byte capacity")) catch @panic("routing byte capacity");
    const request = allocator.alloc(u8, length) catch @panic("routing request allocation");
    defer allocator.free(request);
    @memset(request, 0);
    request[0..4].* = .{ 24, 1, op, param };
    put(request, 4, count);
    put(request, 8, if (subject) |i| (if (i < count) @as(u32, @intCast(i)) else missing) else missing);
    put(request, 12, @intCast(@min(capacity, std.math.maxInt(u32))));
    std.mem.writeInt(u64, request[16..24], id orelse 0, .little);
    float(request, 24, point.x);
    float(request, 28, point.y);
    // Some(0) is a capture request that cannot resolve; it is not null.
    put(request, 48, @intFromBool(id != null));
    for ([_]i32{ tokens.layer.base, tokens.layer.overlay, tokens.layer.modal, tokens.layer.floating }, 0..) |layer, i| put(request, 32 + i * 4, @bitCast(layer));
    for (layout.nodes, 0..) |node, i| {
        const n = node.widget;
        const bytes = request[64 + i * 96 ..][0..96];
        put(bytes, 0, widgets.widgetKindCode(n.kind));
        put(bytes, 4, roleCode(n.semantics.role));
        put(bytes, 8, if (node.parent_index) |p| (std.math.cast(u32, p) orelse missing) else missing);
        put(bytes, 12, std.math.cast(u32, node.depth) orelse @panic("routing depth capacity"));
        std.mem.writeInt(u64, bytes[16..24], n.id, .little);
        // Authored flags only: no native target/visibility/focus verdicts.
        const flags: u32 = @intFromBool(n.semantics.hidden) | (@as(u32, @intFromBool(n.state.disabled)) << 1) |
            (@as(u32, @intFromBool(n.state.selected)) << 2) | (@as(u32, @intFromBool(n.layout.anchor != null)) << 3) |
            (@as(u32, @intFromBool(n.layout.clip_content)) << 4) | (@as(u32, @intFromBool(n.hover_msgs)) << 5) |
            (@as(u32, @intFromBool(n.window_drag)) << 6) | (@as(u32, @intFromBool(n.semantics.focusable)) << 7) |
            (@as(u32, @intFromBool(n.layer != null)) << 9) | (@as(u32, @intFromBool(n.chart.hover_details)) << 10);
        put(bytes, 24, flags);
        put(bytes, 28, events.semanticActionBits(n.semantics.actions));
        float(bytes, 32, n.value);
        put(bytes, 36, @bitCast(n.layer orelse 0));
        const values = [_]f32{ node.frame.x, node.frame.y, node.frame.width, node.frame.height, n.transform.a, n.transform.b, n.transform.c, n.transform.d, n.transform.tx, n.transform.ty };
        for (values, 0..) |value, v| float(bytes, 40 + v * 4, value);
    }
    // Path depth is 32, so the complete capture/target/bubble path is 63.
    var output: [24 + 63 * 8]u8 = undefined;
    var written: usize = undefined;
    var observations: usize = 0;
    while (true) {
        written = policy(request, &output);
        if (written < 24 or output[2] != 3) break;
        if (comptime op == 7 or op >= 10) {
            const index = word(&output, 4);
            if (written != 24 or output[0] != 1 or output[1] != op or output[3] != 0 or index >= count or word(&output, 8) != missing or word(&output, 12) != 0 or word(&output, 16) != 0 or word(&output, 20) != 0 or observations >= count)
                @panic("invalid compiled routing observation");
            const at = 64 + @as(usize, index) * 96 + 24;
            var flags = word(request, at);
            if (flags & 2048 != 0) @panic("repeated compiled routing observation");
            flags |= 2048;
            if (scroll_semantics_fn(layout, index).scrollable) flags |= 256;
            put(request, at, flags);
            observations += 1;
        } else @panic("unexpected compiled routing observation");
    }
    if (written < 24 or written > output.len or output[0] != 1 or output[1] != op or output[2] > 2 or (if (op == 3) output[3] > 1 else output[3] != 0) or word(&output, 16) != 0 or word(&output, 20) != 0) @panic("invalid compiled routing result");
    const len = word(&output, 12);
    if (len > 63 or len > capacity or written != 24 + @as(usize, len) * 8 or (op != 4 and (op < 6 or op > 9) and len != 0) or ((op < 6 or op > 9) and output[2] != 0)) @panic("invalid compiled routing path");
    var result = Result{ .status = output[2], .keep_hit = output[3] == 1, .target = readIndex(word(&output, 4), count), .press = readIndex(word(&output, 8), count), .len = len };
    for (0..len) |i| {
        result.indices[i] = readIndex(word(&output, 24 + i * 8), count) orelse @panic("missing compiled route entry");
        result.phases[i] = switch (word(&output, 28 + i * 8)) {
            0 => .capture,
            1 => .target,
            2 => .bubble,
            else => @panic("invalid compiled route phase"),
        };
    }
    return result;
}
