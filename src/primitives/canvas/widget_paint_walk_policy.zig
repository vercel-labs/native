//! Copied paint traversal boundary. Native owns command identities, packets,
//! result storage and drawing execution; portable code owns scheduling.
const std = @import("std");
const geometry = @import("geometry");
const drawing = @import("drawing.zig");
const widgets = @import("widgets.zig");
const tokens_model = @import("tokens.zig");
const tree = @import("widget_tree.zig");
pub const Policy = @import("surface_layout_policy.zig").Policy;
const none = std.math.maxInt(u32);
pub fn owner(layout: anytype) ?Policy {
    const T = switch (@typeInfo(@TypeOf(layout))) {
        .pointer => |p| p.child,
        else => @TypeOf(layout),
    };
    if (comptime @hasField(T, "paint_walk_policy")) return layout.paint_walk_policy;
    return null;
}
fn put(b: []u8, at: usize, v: usize) void {
    std.mem.writeInt(u32, b[at..][0..4], std.math.cast(u32, v) orelse @panic("paint walk wire capacity"), .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn float(b: []u8, at: usize, v: f32) void {
    put(b, at, @as(u32, @bitCast(v)));
}
fn readFloat(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn wide(b: []u8, at: usize, v: u64) void {
    put(b, at, @as(u32, @truncate(v)));
    put(b, at + 4, v >> 32);
}
fn slot(b: []const u8, at: usize) ?usize {
    const v = read(b, at);
    return if (v == none) null else v;
}
fn validateSlot(b: []const u8, at: usize, count: usize) void {
    if (slot(b, at)) |v| {
        if (v >= count) @panic("invalid compiled paint walk slot");
    }
}
pub const Lane = struct {
    focused: bool,
    hovered: bool,
    pressed: bool,
    logical_focus: bool,
    group_focus: bool,
    skip: bool,
    wrap_opacity: bool,
    wrap_motion: bool,
    wrap_transform: bool,
    suppress_flow: bool,
    disclosure: enum(u2) { closed, revealing, open },
    opacity: f32,
    motion: geometry.OffsetF,
    inverse: ?drawing.Affine,
};
pub const Facts = struct {
    layer: i32,
    surface_layer: i32,
    next_sibling: ?usize,
    first_child: ?usize,
    next_surface: ?usize,
    next_escaping: ?usize,
    child_count: usize,
    segment: widgets.WidgetGroupSegment,
    ordinary: Lane,
    preview: Lane,
};
fn lane(b: []const u8, at: usize) Lane {
    const f = read(b, at);
    return .{ .focused = f & 1 != 0, .hovered = f & 2 != 0, .pressed = f & 4 != 0, .logical_focus = f & 8 != 0, .group_focus = f & 16 != 0, .skip = f & 32 != 0, .wrap_opacity = f & 64 != 0, .wrap_motion = f & 128 != 0, .wrap_transform = f & 256 != 0, .suppress_flow = f & 512 != 0, .disclosure = @enumFromInt((f >> 10) & 3), .opacity = readFloat(b, at + 4), .motion = .{ .dx = readFloat(b, at + 8), .dy = readFloat(b, at + 12) }, .inverse = if (read(b, at + 16) == 0) null else .{ .a = readFloat(b, at + 20), .b = readFloat(b, at + 24), .c = readFloat(b, at + 28), .d = readFloat(b, at + 32), .tx = readFloat(b, at + 36), .ty = readFloat(b, at + 40) } };
}
pub const Plan = struct {
    allocator: std.mem.Allocator,
    request: []u8,
    result: []u8,
    nodes: []const @import("events.zig").WidgetLayoutNode,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, layout: anytype, tokens: tokens_model.DesignTokens, state: widgets.WidgetRenderState) std.mem.Allocator.Error!Plan {
        const node_bytes = std.math.mul(usize, layout.nodes.len, 96) catch @panic("paint walk node capacity");
        const motion_bytes = std.math.mul(usize, state.layout_motions.len, 24) catch @panic("paint walk motion capacity");
        const reveal_bytes = std.math.mul(usize, state.revealing_disclosure_ids.len, 8) catch @panic("paint walk reveal capacity");
        var size: usize = 80;
        for ([_]usize{ node_bytes, motion_bytes, reveal_bytes }) |v| size = std.math.add(usize, size, v) catch @panic("paint walk byte capacity");
        const request = try allocator.alloc(u8, size);
        errdefer allocator.free(request);
        @memset(request, 0);
        request[0..4].* = .{ 28, 1, @import("render_plan_policy.zig").numericFlags(), 0 };
        put(request, 4, layout.nodes.len);
        put(request, 8, state.layout_motions.len);
        put(request, 12, state.revealing_disclosure_ids.len);
        var flags: u32 = @intFromBool(state.keyboard_active);
        inline for (.{ "focused_id", "focus_visible_id", "hovered_id", "pressed_id", "drag_preview_id" }, 0..) |name, i| {
            if (@field(state, name)) |id| {
                flags |= @as(u32, 1) << (i + 1);
                wide(request, 36 + i * 8, id);
            }
        }
        flags |= @as(u32, @intFromBool(state.rendering_drag_preview)) << 6;
        flags |= @as(u32, @intFromBool(tokens.controls.button_group_style == .detached)) << 7;
        put(request, 16, flags);
        inline for (.{ "base", "overlay", "floating", "modal" }, 0..) |name, i| put(request, 20 + i * 4, @as(u32, @bitCast(@field(tokens.layer, name))));
        for (layout.nodes, 0..) |n, i| {
            const at = 80 + i * 96;
            put(request, at, widgets.widgetKindCode(n.widget.kind));
            put(request, at + 4, @as(u32, @intFromBool(n.parent_index != null)) | (@as(u32, @intFromBool(n.widget.layout.anchor != null)) << 1) | (@as(u32, @intFromBool(n.widget.semantics.hidden)) << 2) | (@as(u32, @intFromBool(n.widget.layer != null)) << 3) | (@as(u32, @intFromBool(n.widget.state.focused)) << 4) | (@as(u32, @intFromBool(n.widget.state.hovered)) << 5) | (@as(u32, @intFromBool(n.widget.state.pressed)) << 6) | (@as(u32, @intFromBool(n.widget.state.selected)) << 7));
            if (n.parent_index) |p| wide(request, at + 8, p);
            wide(request, at + 16, n.widget.id);
            wide(request, at + 24, if (n.widget.id == 0) 0 else @import("widget_render.zig").dragPreviewWidgetId(n.widget.id));
            wide(request, at + 32, n.depth);
            put(request, at + 40, @as(u32, @bitCast(n.widget.layer orelse 0)));
            inline for (.{ "x", "y", "width", "height" }, 0..) |name, j| float(request, at + 44 + j * 4, @field(n.frame, name));
            inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |name, j| float(request, at + 60 + j * 4, @field(n.widget.transform, name));
            float(request, at + 84, n.widget.opacity);
            float(request, at + 88, n.widget.value);
            float(request, at + 92, n.widget.layout.gap);
        }
        for (state.layout_motions, 0..) |m, i| {
            const at = 80 + node_bytes + i * 24;
            wide(request, at, m.id);
            float(request, at + 8, m.offset.dx);
            float(request, at + 12, m.offset.dy);
            put(request, at + 16, @intFromBool(m.escape_ancestor_clips));
        }
        for (state.revealing_disclosure_ids, 0..) |id, i| wide(request, 80 + node_bytes + motion_bytes + i * 8, id);
        const result_size = std.math.add(usize, 24, std.math.mul(usize, layout.nodes.len, 120) catch @panic("paint walk result capacity")) catch @panic("paint walk result capacity");
        const result = try allocator.alloc(u8, result_size);
        errdefer allocator.free(result);
        @memset(result, 0xa5);
        if (policy(request, result) != result.len or !std.mem.eql(u8, result[0..4], &.{ 1, 0, 0, 0 }) or read(result, 4) != layout.nodes.len) @panic("invalid compiled paint walk result");
        for (0..4) |j| validateSlot(result, 8 + j * 4, layout.nodes.len);
        for (layout.nodes, 0..) |_, i| {
            const at = 24 + i * 120;
            for (0..4) |j| validateSlot(result, at + 8 + j * 4, layout.nodes.len);
            if (read(result, at + 24) > layout.nodes.len or read(result, at + 28) > 3) @panic("invalid compiled paint walk count");
            for ([_]usize{ at + 32, at + 76 }) |a| {
                const f = read(result, a);
                if (f > 3071 or ((f >> 10) & 3) > 2 or read(result, a + 16) > 1 or (read(result, a + 16) == 0 and !std.mem.allEqual(u8, result[a + 20 ..][0..24], 0))) @panic("invalid compiled paint walk lane");
            }
        }
        return .{ .allocator = allocator, .request = request, .result = result, .nodes = layout.nodes };
    }
    pub fn matches(self: Plan, layout: anytype) bool {
        return self.nodes.ptr == layout.nodes.ptr and self.nodes.len == layout.nodes.len;
    }
    pub fn firstRoot(self: Plan) ?usize {
        return slot(self.result, 8);
    }
    pub fn firstSurface(self: Plan) ?usize {
        return slot(self.result, 12);
    }
    pub fn firstEscaping(self: Plan) ?usize {
        return slot(self.result, 16);
    }
    pub fn previewIndex(self: Plan) ?usize {
        return slot(self.result, 20);
    }
    pub fn facts(self: Plan, index: usize) Facts {
        const at = 24 + index * 120;
        return .{ .layer = @bitCast(read(self.result, at)), .surface_layer = @bitCast(read(self.result, at + 4)), .next_sibling = slot(self.result, at + 8), .first_child = slot(self.result, at + 12), .next_surface = slot(self.result, at + 16), .next_escaping = slot(self.result, at + 20), .child_count = read(self.result, at + 24), .segment = @enumFromInt(read(self.result, at + 28)), .ordinary = lane(self.result, at + 32), .preview = lane(self.result, at + 76) };
    }
    pub fn activeLane(self: Plan, index: usize, preview: bool) Lane {
        const f = self.facts(index);
        return if (preview) f.preview else f.ordinary;
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.request);
        self.allocator.free(self.result);
    }
};

fn eligibleSurface(layout: anytype, index: usize) bool {
    return tree.widgetEscapesAncestorClips(layout.nodes[index].widget) and !tree.isWidgetHiddenInAncestors(layout, index) and !tree.isWidgetConcealedByDisclosure(layout, index);
}
fn eligibleEscaping(layout: anytype, index: usize, state: widgets.WidgetRenderState) bool {
    return !tree.widgetEscapesAncestorClips(layout.nodes[index].widget) and state.layoutMotionEscapesAncestorClips(layout.nodes[index].widget.id) and !tree.isWidgetHiddenInAncestors(layout, index) and !tree.isWidgetConcealedByDisclosure(layout, index);
}
pub fn referenceSurface(layout: anytype, tokens: tokens_model.DesignTokens, previous: ?tree.WidgetPaintOrder) ?usize {
    var order = previous;
    while (tree.nextWidgetLayoutWindowSurface(layout, tokens, order)) |index| {
        if (eligibleSurface(layout, index)) return index;
        order = tree.widgetLayoutWindowSurfaceOrder(layout, index, tokens);
    }
    return null;
}
pub fn referenceEscaping(layout: anytype, start: usize, state: widgets.WidgetRenderState) ?usize {
    for (start..layout.nodes.len) |i| if (eligibleEscaping(layout, i, state)) return i;
    return null;
}
pub fn referencePreview(layout: anytype, state: widgets.WidgetRenderState) ?usize {
    const i = tree.widgetIndexById(layout, state.drag_preview_id orelse return null) orelse return null;
    const n = layout.nodes[i];
    return if (n.widget.kind == .resizable or n.widget.kind == .split_divider or tree.isWidgetHiddenInAncestors(layout, i) or tree.isWidgetConcealedByDisclosure(layout, i)) null else i;
}
pub fn referenceFacts(layout: anytype, index: usize, tokens: tokens_model.DesignTokens, state: widgets.WidgetRenderState) Facts {
    const render = @import("widget_render.zig");
    const node = layout.nodes[index];
    const layer = tree.widgetPaintLayer(node.widget, tokens);
    const preview: widgets.WidgetRenderState = .{ .rendering_drag_preview = true, .drag_preview_id = state.drag_preview_id, .drag_preview_origin = state.drag_preview_origin, .drag_preview_offset = state.drag_preview_offset, .revealing_disclosure_ids = state.revealing_disclosure_ids };
    return .{
        .layer = layer,
        .surface_layer = tree.widgetLayoutWindowSurfaceLayer(layout, index, tokens),
        .next_sibling = tree.nextWidgetLayoutPaintChild(layout, node.parent_index, tokens, .{ .layer = layer, .index = index }),
        .first_child = tree.nextWidgetLayoutPaintChild(layout, index, tokens, null),
        .next_surface = if (eligibleSurface(layout, index)) referenceSurface(layout, tokens, tree.widgetLayoutWindowSurfaceOrder(layout, index, tokens)) else null,
        .next_escaping = if (eligibleEscaping(layout, index, state)) referenceEscaping(layout, index + 1, state) else null,
        .child_count = tree.widgetLayoutDirectChildCount(layout, index),
        .segment = render.referencePaintWalkSegment(layout, index, tokens),
        .ordinary = render.referencePaintWalkLane(layout, index, state),
        .preview = render.referencePaintWalkLane(layout, index, preview),
    };
}

pub fn referenceRoot(layout: anytype, tokens: tokens_model.DesignTokens) ?usize {
    return tree.nextWidgetLayoutPaintChild(layout, null, tokens, null);
}
pub fn previewCommandId(id: u64) u64 {
    return if (id == 0) 0 else @import("widget_render.zig").dragPreviewWidgetId(id);
}
