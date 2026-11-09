//! Rebuild collection plans over copied facts. Returned ordinals select native
//! records; text, hashes, selections and code-cache identities never transfer
//! ownership. Native reference collectors remain independent when absent.
const std = @import("std");
const canvas = @import("canvas");
const limits = @import("canvas_limits.zig");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Operation = enum(u8) { source_scroll, source_control, control, scroll, source_text, text, autofocus };
pub const Selection = struct { node: usize, source: ?usize, selected: bool, resizable: bool, code_diff: bool };
pub const Plan = struct {
    entries: [limits.max_canvas_widget_nodes_per_view]Selection = undefined,
    count: usize = 0,
    target: ?usize = null,
};

pub fn collect(policy: Policy, operation: Operation, nodes: []const canvas.WidgetLayoutNode, sources: anytype, capacity: usize, states: usize) ?Plan {
    const callback = policy orelse return null;
    if (nodes.len > limits.max_canvas_widget_nodes_per_view or sources.len > limits.max_canvas_widget_nodes_per_view or capacity > limits.max_canvas_widget_nodes_per_view or states > limits.max_canvas_widget_nodes_per_view)
        @panic("widget retention table exceeds view budget");
    var input: [24 + limits.max_canvas_widget_nodes_per_view * 32]u8 = undefined;
    const bytes = input[0 .. 24 + (nodes.len + sources.len) * 16];
    @memset(bytes, 0);
    bytes[0] = 92;
    bytes[1] = @intFromEnum(operation);
    word(bytes[4..8], nodes.len);
    word(bytes[8..12], sources.len);
    word(bytes[12..16], capacity);
    word(bytes[16..20], states);
    for (nodes, 0..) |node, i| {
        const fact = bytes[24 + i * 16 ..][0..16];
        wide(fact[0..8], node.widget.id);
        fact[8] = @intCast(canvas.widgetKindCode(node.widget.kind));
        const selection = node.widget.text_selection;
        fact[9] = @as(u8, @intFromBool(node.widget.autofocus)) |
            (@as(u8, @intFromBool(selection != null)) << 1) |
            (@as(u8, @intFromBool(if (selection) |value| !value.isCollapsed(node.widget.text.len) else false)) << 2) |
            (@as(u8, @intFromBool(node.widget.hasCodeDiff())) << 3) |
            (@as(u8, @intFromBool(node.widget.state.selected)) << 4);
        std.mem.writeInt(u32, fact[12..16], @bitCast(node.widget.value), .little);
    }
    for (sources, 0..) |source, i| {
        const fact = bytes[24 + (nodes.len + i) * 16 ..][0..16];
        wide(fact[0..8], source.id);
        fact[8] = if (comptime @hasField(@TypeOf(source), "kind")) @intCast(canvas.widgetKindCode(source.kind)) else 0;
    }
    var output: [16 + limits.max_canvas_widget_nodes_per_view * 12]u8 = undefined;
    const size = callback(bytes, &output);
    if (size < 16 or size > output.len or output[0] != 92 or output[1] != @intFromEnum(operation) or output[2] != 0 or output[3] != 0 or read(output[12..16]) != 0)
        @panic("invalid compiled widget retention header");
    var plan = Plan{};
    plan.count = read(output[4..8]);
    const target = read(output[8..12]);
    if (plan.count > capacity or size != 16 + plan.count * 12 or (target != std.math.maxInt(u32) and (operation != .autofocus or target >= nodes.len)))
        @panic("invalid compiled widget retention counts");
    plan.target = if (target == std.math.maxInt(u32)) null else target;
    for (plan.entries[0..plan.count], 0..) |*entry, i| {
        const at = 16 + i * 12;
        const index = read(output[at..][0..4]);
        const source = read(output[at + 4 ..][0..4]);
        const flags = read(output[at + 8 ..][0..4]);
        if (index >= nodes.len or (i > 0 and index <= plan.entries[i - 1].node) or (source != std.math.maxInt(u32) and source >= sources.len) or flags > 7)
            @panic("invalid compiled widget retention entry");
        entry.* = .{ .node = index, .source = if (source == std.math.maxInt(u32)) null else source, .selected = flags & 1 != 0, .resizable = flags & 2 != 0, .code_diff = flags & 4 != 0 };
    }
    return plan;
}
fn word(bytes: *[4]u8, value: usize) void {
    std.mem.writeInt(u32, bytes, @intCast(value), .little);
}
fn wide(bytes: *[8]u8, value: u64) void {
    std.mem.writeInt(u64, bytes, value, .little);
}
fn read(bytes: *const [4]u8) usize {
    return std.mem.readInt(u32, bytes, .little);
}
