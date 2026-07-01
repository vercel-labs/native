const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const equality_model = @import("equality.zig");
const widget_tree = @import("widget_tree.zig");
const widget_access = @import("widget_access.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Affine = drawing_model.Affine;
const DesignTokens = token_model.DesignTokens;
const Widget = widget_model.Widget;
const WidgetLayoutNode = event_model.WidgetLayoutNode;
const WidgetHit = event_model.WidgetHit;
const WidgetPointerEvent = event_model.WidgetPointerEvent;
const WidgetKeyboardEvent = event_model.WidgetKeyboardEvent;
const WidgetFileDropEvent = event_model.WidgetFileDropEvent;
const WidgetDragEvent = event_model.WidgetDragEvent;
const WidgetEventPhase = event_model.WidgetEventPhase;
const WidgetEventRouteEntry = event_model.WidgetEventRouteEntry;
const WidgetEventRoute = event_model.WidgetEventRoute;
const WidgetKeyboardRoute = event_model.WidgetKeyboardRoute;
const WidgetFocusDirection = event_model.WidgetFocusDirection;
const WidgetFocusTarget = event_model.WidgetFocusTarget;
const affinesEqual = equality_model.affinesEqual;
const widgetIndexById = widget_tree.widgetIndexById;
const isWidgetHiddenInAncestors = widget_tree.isWidgetHiddenInAncestors;

const max_widget_depth: usize = 32;

pub fn hitTestWidgetLayout(layout: anytype, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    return hitTestWidgetLayoutChildren(layout, null, point, tokens);
}

fn hitTestWidgetLayoutChildren(layout: anytype, parent_index: ?usize, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    const child_count = widget_tree.widgetLayoutDirectChildCount(layout, parent_index);
    var tested: usize = 0;
    var previous: ?widget_tree.WidgetPaintOrder = null;
    while (tested < child_count) : (tested += 1) {
        const child_index = widget_tree.previousWidgetLayoutPaintChild(layout, parent_index, tokens, previous) orelse return null;
        if (hitTestWidgetLayoutNode(layout, child_index, point, tokens)) |hit| return hit;
        previous = .{ .layer = widget_tree.widgetPaintLayer(layout.nodes[child_index].widget, tokens), .index = child_index };
    }
    return null;
}

fn hitTestWidgetLayoutNode(layout: anytype, node_index: usize, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    if (node_index >= layout.nodes.len) return null;
    const node = layout.nodes[node_index];
    if (node.widget.semantics.hidden) return null;

    const local_point = widgetLocalHitPoint(node.widget, point) orelse return null;
    if (widget_tree.widgetClipsContent(node.widget) and !node.frame.normalized().containsPoint(local_point)) return null;
    if (hitTestWidgetLayoutChildren(layout, node_index, local_point, tokens)) |hit| return hit;

    if (!widget_access.isHitTarget(node.widget)) return null;
    if (!node.frame.normalized().containsPoint(local_point)) return null;
    return widgetHitFromNode(node, node_index);
}

fn widgetLocalHitPoint(widget: Widget, point: geometry.PointF) ?geometry.PointF {
    const transform = widget_tree.widgetTransform(widget);
    if (affinesEqual(transform, Affine.identity())) return point;
    return if (transform.inverse()) |inverse| inverse.transformPoint(point) else null;
}

fn widgetHitFromNode(node: WidgetLayoutNode, index: usize) WidgetHit {
    return .{
        .id = node.widget.id,
        .kind = node.widget.kind,
        .bounds = node.frame,
        .depth = node.depth,
        .index = index,
        .state = node.widget.state,
    };
}

fn isPointVisibleInWidgetAncestors(layout: anytype, node_index: usize, point: geometry.PointF) bool {
    var current = layout.nodes[node_index].parent_index;
    while (current) |parent_index| {
        const parent = layout.nodes[parent_index];
        if (widget_tree.widgetClipsContent(parent.widget) and !parent.frame.normalized().containsPoint(point)) return false;
        current = parent.parent_index;
    }
    return true;
}

fn isWidgetFrameVisibleInWidgetAncestors(layout: anytype, node_index: usize) bool {
    if (node_index >= layout.nodes.len) return false;
    const frame = layout.nodes[node_index].frame.normalized();
    if (frame.isEmpty()) return false;
    var current = layout.nodes[node_index].parent_index;
    while (current) |parent_index| {
        const parent = layout.nodes[parent_index];
        if (widget_tree.widgetClipsContent(parent.widget) and geometry.RectF.intersection(frame, parent.frame.normalized()).isEmpty()) return false;
        current = parent.parent_index;
    }
    return true;
}

pub fn routeWidgetPointerEvent(layout: anytype, event: WidgetPointerEvent, tokens: DesignTokens, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    const target = if (eventUsesPointerCapture(event)) blk: {
        break :blk capturedWidgetPointerTarget(layout, event) orelse return .{ .entries = output[0..0] };
    } else hitTestWidgetLayout(layout, event.point, tokens) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target.index, output);
    return .{ .target = target, .entries = entries };
}

fn eventUsesPointerCapture(event: WidgetPointerEvent) bool {
    if (event.captured_id == null) return false;
    return switch (event.phase) {
        .move, .up, .cancel => true,
        .hover, .down, .wheel => false,
    };
}

fn capturedWidgetPointerTarget(layout: anytype, event: WidgetPointerEvent) ?WidgetHit {
    const id = event.captured_id orelse return null;
    return switch (event.phase) {
        .move, .up, .cancel => widgetPointerTargetById(layout, id),
        .hover, .down, .wheel => null,
    };
}

fn widgetPointerTargetById(layout: anytype, id: ObjectId) ?WidgetHit {
    const index = widgetIndexById(layout, id) orelse return null;
    const node = layout.nodes[index];
    if (!widget_access.isHitTarget(node.widget)) return null;
    if (isWidgetHiddenInAncestors(layout, index)) return null;
    if (!isWidgetFrameVisibleInWidgetAncestors(layout, index)) return null;
    return widgetHitFromNode(node, index);
}

pub fn routeWidgetKeyboardEvent(layout: anytype, event: WidgetKeyboardEvent, output: []WidgetEventRouteEntry, scroll_semantics_fn: anytype) Error!WidgetKeyboardRoute {
    const focused_id = event.focused_id orelse return .{ .entries = output[0..0] };
    const target_index = widgetIndexById(layout, focused_id) orelse return .{ .entries = output[0..0] };
    const target = focusTargetFromLayoutNode(layout, target_index, scroll_semantics_fn) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target.index, output);
    return .{ .target = target, .entries = entries };
}

pub fn routeWidgetFileDropEvent(layout: anytype, event: WidgetFileDropEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    if (event.paths.len == 0) return .{ .entries = output[0..0] };
    const target_index = widgetDropTargetIndexAtPoint(layout, event.point) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target_index, output);
    return .{ .target = widgetHitFromNode(layout.nodes[target_index], target_index), .entries = entries };
}

pub fn routeWidgetDragEvent(layout: anytype, event: WidgetDragEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    const target_index = widgetDragSourceIndex(layout, event.source_id) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target_index, output);
    return .{ .target = widgetHitFromNode(layout.nodes[target_index], target_index), .entries = entries };
}

fn widgetDropTargetIndexAtPoint(layout: anytype, point: geometry.PointF) ?usize {
    var index = layout.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = layout.nodes[index];
        if (!widget_access.isDropTarget(node.widget)) continue;
        if (isWidgetHiddenInAncestors(layout, index)) continue;
        if (!node.frame.normalized().containsPoint(point)) continue;
        if (!isPointVisibleInWidgetAncestors(layout, index, point)) continue;
        return index;
    }
    return null;
}

fn widgetDragSourceIndex(layout: anytype, id: ObjectId) ?usize {
    if (id == 0) return null;
    const index = widgetIndexById(layout, id) orelse return null;
    const node = layout.nodes[index];
    if (!widget_access.isDragSource(node.widget)) return null;
    if (isWidgetHiddenInAncestors(layout, index)) return null;
    if (!isWidgetFrameVisibleInWidgetAncestors(layout, index)) return null;
    return index;
}

fn routeWidgetEventPath(layout: anytype, target_index: usize, output: []WidgetEventRouteEntry) Error![]const WidgetEventRouteEntry {
    var path: [max_widget_depth]usize = undefined;
    var path_len: usize = 0;
    var current: ?usize = target_index;
    while (current) |node_index| {
        if (path_len >= path.len) return error.WidgetDepthExceeded;
        path[path_len] = node_index;
        path_len += 1;
        current = layout.nodes[node_index].parent_index;
    }

    var len: usize = 0;
    var capture_index = path_len;
    while (capture_index > 1) {
        capture_index -= 1;
        try appendWidgetEventRouteEntry(output, &len, .capture, layout.nodes[path[capture_index]], path[capture_index]);
    }
    try appendWidgetEventRouteEntry(output, &len, .target, layout.nodes[target_index], target_index);

    var bubble_index: usize = 1;
    while (bubble_index < path_len) : (bubble_index += 1) {
        try appendWidgetEventRouteEntry(output, &len, .bubble, layout.nodes[path[bubble_index]], path[bubble_index]);
    }

    return output[0..len];
}

fn appendWidgetEventRouteEntry(
    output: []WidgetEventRouteEntry,
    len: *usize,
    phase: WidgetEventPhase,
    node: WidgetLayoutNode,
    node_index: usize,
) Error!void {
    if (len.* >= output.len) return error.WidgetEventRouteListFull;
    output[len.*] = .{
        .phase = phase,
        .node_index = node_index,
        .id = node.widget.id,
        .kind = node.widget.kind,
        .bounds = node.frame,
    };
    len.* += 1;
}

pub fn focusWidgetTarget(layout: anytype, current_id: ?ObjectId, direction: WidgetFocusDirection, scroll_semantics_fn: anytype) ?WidgetFocusTarget {
    if (layout.nodes.len == 0) return null;
    const current_index = if (current_id) |id| widgetIndexById(layout, id) else null;
    return switch (direction) {
        .forward => focusForward(layout, current_index, scroll_semantics_fn),
        .backward => focusBackward(layout, current_index, scroll_semantics_fn),
        .left, .right, .up, .down => if (current_index) |index| focusSpatial(layout, index, direction, scroll_semantics_fn) else null,
    };
}

pub fn focusWidgetTargetById(layout: anytype, id: ObjectId, scroll_semantics_fn: anytype) ?WidgetFocusTarget {
    const index = widgetIndexById(layout, id) orelse return null;
    return focusTargetFromLayoutNode(layout, index, scroll_semantics_fn);
}

fn focusForward(layout: anytype, current_index: ?usize, scroll_semantics_fn: anytype) ?WidgetFocusTarget {
    var index: usize = if (current_index) |value| value + 1 else 0;
    while (index < layout.nodes.len) : (index += 1) {
        if (focusTargetFromLayoutNode(layout, index, scroll_semantics_fn)) |target| return target;
    }
    index = 0;
    const stop = current_index orelse layout.nodes.len;
    while (index < stop and index < layout.nodes.len) : (index += 1) {
        if (focusTargetFromLayoutNode(layout, index, scroll_semantics_fn)) |target| return target;
    }
    return null;
}

fn focusBackward(layout: anytype, current_index: ?usize, scroll_semantics_fn: anytype) ?WidgetFocusTarget {
    var index = current_index orelse layout.nodes.len;
    while (index > 0) {
        index -= 1;
        if (focusTargetFromLayoutNode(layout, index, scroll_semantics_fn)) |target| return target;
    }
    index = layout.nodes.len;
    const stop = if (current_index) |value| value + 1 else 0;
    while (index > stop) {
        index -= 1;
        if (focusTargetFromLayoutNode(layout, index, scroll_semantics_fn)) |target| return target;
    }
    return null;
}

fn focusSpatial(layout: anytype, current_index: usize, direction: WidgetFocusDirection, scroll_semantics_fn: anytype) ?WidgetFocusTarget {
    const current = focusTargetFromLayoutNode(layout, current_index, scroll_semantics_fn) orelse return null;
    const current_bounds = current.bounds.normalized();
    const current_center = current_bounds.center();
    var best: ?WidgetFocusTarget = null;
    var best_score = std.math.inf(f32);

    for (layout.nodes, 0..) |_, index| {
        if (index == current_index) continue;
        const target = focusTargetFromLayoutNode(layout, index, scroll_semantics_fn) orelse continue;
        const target_bounds = target.bounds.normalized();
        const target_center = target_bounds.center();
        if (!spatialFocusCandidate(current_center, target_bounds, direction)) continue;

        const score = spatialFocusScore(current_bounds, target_bounds, current_center, target_center, direction);
        if (score < best_score or (score == best_score and (best == null or target.index < best.?.index))) {
            best = target;
            best_score = score;
        }
    }

    return best;
}

fn focusTargetFromLayoutNode(layout: anytype, index: usize, scroll_semantics_fn: anytype) ?WidgetFocusTarget {
    if (index >= layout.nodes.len) return null;
    if (isWidgetHiddenInAncestors(layout, index)) return null;
    if (!isWidgetFrameVisibleInWidgetAncestors(layout, index)) return null;
    const node = layout.nodes[index];
    if (node.widget.id == 0) return null;
    if (!widget_access.isFocusable(node.widget) and (node.widget.state.disabled or !scroll_semantics_fn(layout, index).scrollable)) return null;
    return .{
        .id = node.widget.id,
        .kind = node.widget.kind,
        .bounds = node.frame,
        .index = index,
        .state = node.widget.state,
    };
}

fn spatialFocusCandidate(
    current_center: geometry.PointF,
    target_bounds: geometry.RectF,
    direction: WidgetFocusDirection,
) bool {
    return switch (direction) {
        .left => target_bounds.maxX() <= current_center.x,
        .right => target_bounds.x >= current_center.x,
        .up => target_bounds.maxY() <= current_center.y,
        .down => target_bounds.y >= current_center.y,
        .forward, .backward => false,
    };
}

fn spatialFocusScore(current_bounds: geometry.RectF, target_bounds: geometry.RectF, current_center: geometry.PointF, target_center: geometry.PointF, direction: WidgetFocusDirection) f32 {
    const dx = @abs(target_center.x - current_center.x);
    const dy = @abs(target_center.y - current_center.y);
    const gap_x = rectGapX(current_bounds, target_bounds);
    const gap_y = rectGapY(current_bounds, target_bounds);
    return switch (direction) {
        .left, .right => dx * 4096 + gap_y * 4096 + dy,
        .up, .down => dy * 4096 + gap_x * 4096 + dx,
        .forward, .backward => std.math.inf(f32),
    };
}

fn rectGapX(a: geometry.RectF, b: geometry.RectF) f32 {
    if (rectsOverlapX(a, b)) return 0;
    if (b.x >= a.maxX()) return b.x - a.maxX();
    return a.x - b.maxX();
}

fn rectGapY(a: geometry.RectF, b: geometry.RectF) f32 {
    if (rectsOverlapY(a, b)) return 0;
    if (b.y >= a.maxY()) return b.y - a.maxY();
    return a.y - b.maxY();
}

fn rectsOverlapX(a: geometry.RectF, b: geometry.RectF) bool {
    return @min(a.maxX(), b.maxX()) > @max(a.x, b.x);
}

fn rectsOverlapY(a: geometry.RectF, b: geometry.RectF) bool {
    return @min(a.maxY(), b.maxY()) > @max(a.y, b.y);
}
