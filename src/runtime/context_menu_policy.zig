//! Owned context-menu plans. All identities/tokens remain complete integer
//! words. Native owns labels, widgets, callbacks, buffers and OS services.
const std = @import("std");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const limits = @import("canvas_limits.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Kind = enum(u32) { app = 1, edit_text, terminal, static_copy };
pub const Action = enum(u32) { none, app, cut, copy, paste, select_all, terminal_copy, terminal_paste, static_copy };
fn header(comptime n: usize, mode: u8) [n]u8 {
    var bytes: [n]u8 = @splat(0);
    bytes[0..2].* = .{ 98, mode };
    return bytes;
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn wide(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn scalar(policy: Policy, request: []const u8, maximum: u32) u32 {
    var out: [4]u8 = undefined;
    if (policy(request, &out) != out.len) @panic("invalid context menu scalar length");
    const value = std.mem.readInt(u32, &out, .little);
    if (value > maximum) @panic("invalid context menu scalar");
    return value;
}
pub fn route(policy: Policy, nodes: []const canvas.WidgetLayoutNode, entries: []const canvas.WidgetEventRouteEntry) ?usize {
    if (nodes.len > limits.max_canvas_widget_nodes_per_view or entries.len > limits.max_canvas_widget_nodes_per_view) @panic("context menu route capacity");
    var request = header(16 + limits.max_canvas_widget_nodes_per_view * 24, 0);
    put(&request, 4, @intCast(nodes.len));
    put(&request, 8, @intCast(entries.len));
    for (nodes, 0..) |node, i| {
        const at = 16 + i * 16;
        wide(&request, at, node.depth);
        put(&request, at + 8, @intCast(node.widget.context_menu.len));
        put(&request, at + 12, @intFromBool(node.widget.state.disabled));
    }
    for (entries, 0..) |entry, i| wide(&request, 16 + nodes.len * 16 + i * 8, entry.node_index);
    const slot = scalar(policy, request[0 .. 16 + nodes.len * 16 + entries.len * 8], std.math.maxInt(u32));
    if (slot == std.math.maxInt(u32)) return null;
    if (slot >= nodes.len or nodes[slot].widget.context_menu.len == 0 or nodes[slot].widget.state.disabled) @panic("invalid context menu route capability");
    return slot;
}
pub const Presentation = struct {
    kind: enum(u8) { none, hold, edit_text, terminal, static_copy },
    count: usize,
    items: [5]platform.ContextMenuItem = undefined,
};
pub const Facts = struct {
    flags: u32,
    target: u64 = 0,
    selected: u64 = 0,
    selected_group: u64 = 0,
    target_group: u64 = 0,
};
pub fn presentation(policy: Policy, facts: Facts) Presentation {
    var request = header(56, 1);
    put(&request, 4, facts.flags);
    for ([_]u64{ facts.target, facts.selected, facts.selected_group, facts.target_group }, 0..) |v, i| wide(&request, 16 + i * 8, v);
    var out: [28]u8 = undefined;
    const length = policy(&request, &out);
    if (length < 8 or length > out.len or out[0] > 4 or out[1] > 5 or length != 8 + @as(usize, out[1]) * 4 or
        !std.mem.allEqual(u8, out[2..8], 0)) @panic("invalid context menu presentation");
    const labels = [_][]const u8{ "", "Cut", "Copy", "Paste", "Select All" };
    var result = Presentation{ .kind = @enumFromInt(out[0]), .count = out[1] };
    for (0..result.count) |i| {
        const at = 8 + i * 4;
        if (out[at] > 4 or out[at + 1] > 4 or out[at + 2] > 1 or out[at + 3] > 1) @panic("invalid context menu item capability");
        result.items[i] = .{ .id = out[at], .label = labels[out[at + 1]], .enabled = out[at + 2] != 0, .separator = out[at + 3] != 0 };
    }
    return result;
}
pub fn nextToken(policy: Policy, token: u64) u64 {
    var request = header(16, 2);
    wide(&request, 8, token);
    var out: [8]u8 = undefined;
    if (policy(&request, &out) != out.len) @panic("invalid context menu token length");
    const value = std.mem.readInt(u64, &out, .little);
    if (value == 0) @panic("invalid context menu token");
    return value;
}
pub fn notice(policy: Policy, kind: ?Kind) bool {
    var request = header(16, 3);
    put(&request, 4, if (kind) |k| @intFromEnum(k) else 0);
    return scalar(policy, &request, 1) != 0;
}
pub const Continuation = enum(u32) { superseded, view_closed, shown };
pub fn continuation(policy: Policy, token: u64, current: ?u64, view_open: bool) Continuation {
    var request = header(32, 4);
    put(&request, 4, @as(u32, @intFromBool(current != null)) | (@as(u32, @intFromBool(view_open)) << 1));
    wide(&request, 8, token);
    wide(&request, 16, current orelse 0);
    return @enumFromInt(scalar(policy, &request, 2));
}
pub const Admission = enum(u32) { ignore, dismiss, clear, lookup };
pub fn admission(policy: Policy, kind: ?Kind, window: u64, token: u64, event: platform.ContextMenuActionEvent) Admission {
    var request = header(48, 5);
    put(&request, 4, if (kind) |k| @intFromEnum(k) else 0);
    wide(&request, 8, window);
    wide(&request, 16, event.window_id);
    wide(&request, 24, token);
    wide(&request, 32, event.token);
    put(&request, 40, event.item_id);
    return @enumFromInt(scalar(policy, &request, 3));
}
pub fn action(policy: Policy, kind: Kind, item: u32) Action {
    var request = header(16, 6);
    put(&request, 4, @intFromEnum(kind));
    put(&request, 8, item);
    return @enumFromInt(scalar(policy, &request, 8));
}
