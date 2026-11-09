//! Copied retained-tree plans. Native owns the geometry buffers and virtual
//! measurement; the planner chooses traversal, moving nodes and tab reveals.
const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
const limits = @import("canvas_limits.zig");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Request = struct {
    operation: u8,
    target: usize,
    viewport: geometry.RectF = .{},
    previous: canvas.WidgetLayoutTree = .{ .nodes = &.{} },
    anchored_depth: ?usize = null,
    strata: ?canvas.layout_coordination_policy.RetainedPlan = null,
};
pub const Plan = struct {
    target: ?usize,
    x: f32,
    y: f32,
    cursor: usize,
    moving: [limits.max_canvas_widget_nodes_per_view]bool = undefined,

    pub fn translate(self: *const Plan, nodes: []canvas.WidgetLayoutNode, offset: geometry.OffsetF) void {
        for (nodes, 0..) |*node, i| if (self.moving[i]) {
            node.frame = node.frame.translate(offset);
            node.widget.frame = node.frame;
        };
    }
};
pub fn build(policy: Policy, nodes: []const canvas.WidgetLayoutNode, request: Request) ?Plan {
    const callback = policy orelse return null;
    if (nodes.len > limits.max_canvas_widget_nodes_per_view or request.target > nodes.len or (request.operation != 2 and request.target == nodes.len)) @panic("scroll tree exceeds view budget");
    var input: [48 + limits.max_canvas_widget_nodes_per_view * 56]u8 = undefined;
    const bytes = input[0 .. 48 + nodes.len * 56];
    @memset(bytes, 0);
    bytes[0] = 94;
    bytes[1] = request.operation;
    word(bytes[4..8], nodes.len);
    word(bytes[8..12], request.target);
    word(bytes[12..16], request.anchored_depth orelse std.math.maxInt(u32));
    rect(bytes[16..32], request.viewport);
    if (request.operation == 0 and nodes[request.target].widget.layout.virtualized) float(bytes[32..36], canvas.virtualWidgetScrollContentExtent(nodes[request.target].widget, request.viewport.height));
    const tree = canvas.WidgetLayoutTree{ .nodes = nodes };
    for (nodes, 0..) |node, i| {
        const w = node.widget;
        const fact = bytes[48 + i * 56 ..][0..56];
        word(fact[0..4], node.depth);
        word(fact[4..8], node.parent_index orelse std.math.maxInt(u32));
        var bits: u32 = 0;
        if (canvas.widgetIsRootRelativeModal(w)) bits |= 1;
        if (w.layout.anchor != null) bits |= 2;
        if (canvas.widgetEscapesAncestorClips(w)) bits |= 4;
        if (w.kind == .scroll_view or w.layout.clip_content) bits |= 8;
        if (w.layout.virtualized) bits |= 16;
        if (request.operation == 0 and canvas.widgetKindDisclosureAnimated(w.kind) and !canvas.disclosureSettledOpen(tree, i)) bits |= 32;
        if (w.kind == .scroll_view and canvas.widgetScrollsAxis(w, .horizontal)) bits |= 64;
        if (w.semantics.role == .tab and w.state.selected) {
            bits |= 128;
            if (request.operation == 2 and w.id != 0) for (request.previous.nodes) |previous| {
                if (previous.widget.id != w.id) continue;
                if (previous.widget.semantics.role == .tab and previous.widget.state.selected) bits |= 256;
                break;
            };
        }
        word(fact[8..12], bits);
        float(fact[12..16], w.value);
        float(fact[16..20], w.value_x);
        rect(fact[20..36], node.frame);
        if (request.operation == 2) {
            // Only eligible scroll ancestors consume a viewport. Other nodes
            // may have negative extents that the tab planner normalizes itself.
            if (bits & (64 | 16) == 64) rect(fact[36..52], node.frame.inset(w.layout.padding).normalized());
            word(fact[52..56], if (request.strata) |plan| plan.nesting(i) else canvas.anchoredNestingDepth(nodes, i));
        }
    }
    var output: [24 + limits.max_canvas_widget_nodes_per_view]u8 = undefined;
    const size = callback(bytes, &output);
    if (size != 24 + nodes.len or output[0] != 94 or output[1] != request.operation or output[2] != 0 or output[3] != 0 or std.mem.readInt(u32, output[4..8], .little) != nodes.len) @panic("invalid compiled scroll tree header");
    const target = std.mem.readInt(u32, output[8..12], .little);
    const cursor = std.mem.readInt(u32, output[20..24], .little);
    if ((target != std.math.maxInt(u32) and (request.operation != 2 or target >= nodes.len or nodes[target].widget.kind != .scroll_view)) or
        (request.operation == 2 and (cursor <= request.target and request.target < nodes.len or cursor > nodes.len)) or
        (request.operation != 2 and cursor != 0)) @panic("invalid compiled scroll tree target");
    var plan = Plan{ .target = if (target == std.math.maxInt(u32)) null else target, .cursor = cursor, .x = @bitCast(std.mem.readInt(u32, output[12..16], .little)), .y = @bitCast(std.mem.readInt(u32, output[16..20], .little)) };
    for (plan.moving[0..nodes.len], 0..) |*moving, i| {
        if (output[24 + i] > 1 or (request.operation == 0 and output[24 + i] != 0)) @panic("invalid compiled scroll tree translation");
        moving.* = output[24 + i] != 0;
    }
    return plan;
}
fn word(bytes: *[4]u8, value: usize) void {
    std.mem.writeInt(u32, bytes, @intCast(value), .little);
}
fn float(bytes: *[4]u8, value: f32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}
fn rect(bytes: *[16]u8, value: geometry.RectF) void {
    inline for (.{ value.x, value.y, value.width, value.height }, 0..) |v, i| float(bytes[i * 4 ..][0..4], v);
}
