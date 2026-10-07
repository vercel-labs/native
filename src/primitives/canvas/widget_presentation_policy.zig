//! Copied retained presentation boundary. Native owns packets and results;
//! portable code derives viewport, ancestry, motion and span visibility.
const std = @import("std");
const geometry = @import("geometry");
const drawing = @import("drawing.zig");
const widgets = @import("widgets.zig");
const tokens_model = @import("tokens.zig");
pub const Policy = @import("surface_layout_policy.zig").Policy;
const node_size = 64;
const result_node_size = 152;
pub fn owner(layout: anytype) ?Policy {
    const T = switch (@typeInfo(@TypeOf(layout))) {
        .pointer => |p| p.child,
        else => @TypeOf(layout),
    };
    if (comptime @hasField(T, "presentation_policy")) return layout.presentation_policy;
    return null;
}
fn put(b: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, b[at..][0..4], std.math.cast(u32, value) orelse @panic("presentation wire capacity"), .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn float(b: []u8, at: usize, value: f32) void {
    put(b, at, @as(u32, @bitCast(value)));
}
fn readFloat(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn wide(b: []u8, at: usize, value: u64) void {
    put(b, at, @as(u32, @truncate(value)));
    put(b, at + 4, value >> 32);
}
fn rect(b: []u8, at: usize, value: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| float(b, at + i * 4, @field(value, name));
}
fn optionalRect(b: []const u8, at: usize) ?geometry.RectF {
    if (read(b, at) == 0) return null;
    return .init(readFloat(b, at + 4), readFloat(b, at + 8), readFloat(b, at + 12), readFloat(b, at + 16));
}
fn optionalAffine(b: []const u8, at: usize) ?drawing.Affine {
    if (read(b, at) == 0) return null;
    return .{ .a = readFloat(b, at + 4), .b = readFloat(b, at + 8), .c = readFloat(b, at + 12), .d = readFloat(b, at + 16), .tx = readFloat(b, at + 20), .ty = readFloat(b, at + 24) };
}
fn validateOptional(b: []const u8, at: usize, size: usize) void {
    if (read(b, at) > 1 or (read(b, at) == 0 and !std.mem.allEqual(u8, b[at + 4 ..][0..size], 0))) @panic("invalid compiled presentation optional");
}
pub const Facts = struct {
    emission: ?drawing.Affine,
    ancestor: ?drawing.Affine,
    presentation: ?drawing.Affine,
    preview_presentation: ?drawing.Affine,
    visible: ?geometry.RectF,
    preview_visible: ?geometry.RectF,
};
pub const Plan = struct {
    allocator: std.mem.Allocator,
    request: []u8,
    result: []u8,
    nodes: []const @import("events.zig").WidgetLayoutNode,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, layout: anytype, tokens: tokens_model.DesignTokens, state: widgets.WidgetRenderState) std.mem.Allocator.Error!Plan {
        return build(allocator, policy, layout, tokens, state, 1);
    }
    fn build(allocator: std.mem.Allocator, policy: Policy, layout: anytype, tokens: tokens_model.DesignTokens, state: widgets.WidgetRenderState, mode: u8) std.mem.Allocator.Error!Plan {
        const node_bytes = std.math.mul(usize, layout.nodes.len, node_size) catch @panic("presentation node capacity");
        const motion_bytes = std.math.mul(usize, state.layout_motions.len, 24) catch @panic("presentation motion capacity");
        const size = std.math.add(usize, 64, std.math.add(usize, node_bytes, motion_bytes) catch @panic("presentation byte capacity")) catch @panic("presentation byte capacity");
        const request = try allocator.alloc(u8, size);
        errdefer allocator.free(request);
        @memset(request, 0);
        request[0..4].* = .{ 27, mode, 1, @import("render_plan_policy.zig").numericFlags() };
        put(request, 4, layout.nodes.len);
        put(request, 8, state.layout_motions.len);
        const T = switch (@typeInfo(@TypeOf(layout))) {
            .pointer => |p| p.child,
            else => @TypeOf(layout),
        };
        const root_bounds: ?geometry.RectF = if (comptime @hasField(T, "root_bounds")) layout.root_bounds else null;
        put(request, 12, @as(u32, @intFromBool(root_bounds != null)) | (@as(u32, @intFromBool(state.drag_preview_id != null)) << 1) | (@as(u32, @intFromBool(state.drag_preview_origin != null)) << 2) | (@as(u32, @intFromBool(tokens.pixel_snap.geometry)) << 3) | (@as(u32, @intFromBool(state.rendering_drag_preview)) << 4));
        if (root_bounds) |r| rect(request, 16, r);
        if (state.drag_preview_id) |id| wide(request, 32, id);
        if (state.drag_preview_origin) |p| {
            float(request, 40, p.x);
            float(request, 44, p.y);
        }
        float(request, 48, state.drag_preview_offset.dx);
        float(request, 52, state.drag_preview_offset.dy);
        float(request, 56, tokens.pixel_snap.scale);
        for (layout.nodes, 0..) |n, i| {
            const at = 64 + i * node_size;
            put(request, at, widgets.widgetKindCode(n.widget.kind));
            put(request, at + 4, @as(u32, @intFromBool(n.parent_index != null)) | (@as(u32, @intFromBool(n.widget.layout.anchor != null)) << 1) | (@as(u32, @intFromBool(n.widget.layout.clip_content)) << 2) | (@as(u32, @intFromBool(n.widget.kind == .text and n.widget.spans.len > 0)) << 3));
            if (n.parent_index) |p| wide(request, at + 8, p);
            wide(request, at + 16, n.widget.id);
            rect(request, at + 24, n.frame);
            inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |name, j| float(request, at + 40 + j * 4, @field(n.widget.transform, name));
        }
        for (state.layout_motions, 0..) |m, i| {
            const at = 64 + node_bytes + i * 24;
            wide(request, at, m.id);
            float(request, at + 8, m.offset.dx);
            float(request, at + 12, m.offset.dy);
            put(request, at + 16, @intFromBool(m.escape_ancestor_clips));
        }
        const count = if (mode == 0) 0 else layout.nodes.len;
        const result = try allocator.alloc(u8, std.math.add(usize, 56, std.math.mul(usize, count, result_node_size) catch @panic("presentation result capacity")) catch @panic("presentation result capacity"));
        errdefer allocator.free(result);
        @memset(result, 0xa5);
        const written = policy(request, result);
        if (written != result.len or !std.mem.eql(u8, result[0..4], &.{ 1, mode, 0, 0 }) or read(result, 4) != count) @panic("invalid compiled presentation result");
        validateOptional(result, 8, 16);
        validateOptional(result, 28, 24);
        for (0..count) |i| {
            const at = 56 + i * result_node_size;
            for (0..4) |j| validateOptional(result, at + j * 28, 24);
            validateOptional(result, at + 112, 16);
            validateOptional(result, at + 132, 16);
        }
        return .{ .allocator = allocator, .request = request, .result = result, .nodes = layout.nodes };
    }
    pub fn matches(self: Plan, layout: anytype) bool {
        return self.nodes.ptr == layout.nodes.ptr and self.nodes.len == layout.nodes.len;
    }
    pub fn root(self: Plan) ?geometry.RectF {
        return optionalRect(self.result, 8);
    }
    pub fn drag(self: Plan) ?drawing.Affine {
        return optionalAffine(self.result, 28);
    }
    pub fn facts(self: Plan, index: usize) Facts {
        const at = 56 + index * result_node_size;
        return .{ .emission = optionalAffine(self.result, at), .ancestor = optionalAffine(self.result, at + 28), .presentation = optionalAffine(self.result, at + 56), .preview_presentation = optionalAffine(self.result, at + 84), .visible = optionalRect(self.result, at + 112), .preview_visible = optionalRect(self.result, at + 132) };
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.request);
        self.allocator.free(self.result);
    }
};
pub fn rootBounds(policy: Policy, layout: anytype) ?geometry.RectF {
    const plan = Plan.build(std.heap.page_allocator, policy, layout, .{}, .{}, 0) catch @panic("presentation root allocation failed");
    defer plan.deinit();
    return plan.root();
}
/// Independent native calculations for parity qualification of every copied
/// result, including records that ordinary rendering never reaches.
pub fn referenceFacts(layout: anytype, index: usize, tokens: tokens_model.DesignTokens, state: widgets.WidgetRenderState) Facts {
    const render = @import("widget_render.zig");
    var preview_state = state;
    preview_state.rendering_drag_preview = true;
    preview_state.layout_motions = &.{};
    const drag: ?drawing.Affine = if (state.drag_preview_id) |id| blk: {
        const slot = @import("widget_tree.zig").widgetIndexById(layout, id) orelse break :blk null;
        const ancestor = render.widgetLayoutNodeAncestorEmissionTransform(layout, slot) orelse break :blk null;
        break :blk render.widgetLayoutDragPreviewTranslation(layout, slot, state, ancestor);
    } else null;
    const outer = if (state.rendering_drag_preview) drag else drawing.Affine.identity();
    const bounds = render.pixelSnapGeometryRect(tokens, layout.nodes[index].frame);
    const text = layout.nodes[index].widget.kind == .text and layout.nodes[index].widget.spans.len > 0;
    return .{
        .emission = render.widgetLayoutNodeEmissionTransform(layout, index),
        .ancestor = render.widgetLayoutNodeAncestorEmissionTransform(layout, index),
        .presentation = if (outer) |t| render.widgetLayoutNodePresentationTransform(layout, index, state, t) else null,
        .preview_presentation = if (drag) |t| render.widgetLayoutNodePresentationTransform(layout, index, preview_state, t) else null,
        .visible = if (text) render.widgetLayoutNodeVisibleBounds(layout, index, bounds, state) else null,
        .preview_visible = if (text) render.widgetLayoutNodeVisibleBounds(layout, index, bounds, preview_state) else null,
    };
}
