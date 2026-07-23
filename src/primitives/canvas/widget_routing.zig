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
const WidgetKind = widget_model.WidgetKind;
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
    // Anchored floating surfaces paint in the late z-pass — topmost — so
    // they hit-test FIRST, in reverse tree order (a nested anchored
    // submenu has a higher node index than the surface it hangs from).
    var index = layout.nodes.len;
    while (index > 0) {
        index -= 1;
        if (!widget_tree.widgetIsAnchored(layout.nodes[index].widget)) continue;
        if (isWidgetHiddenInAncestors(layout, index)) continue;
        if (widget_tree.isWidgetConcealedByDisclosure(layout, index)) continue;
        if (hitTestWidgetLayoutNode(layout, index, point, tokens)) |hit| return hit;
    }
    return hitTestWidgetLayoutChildren(layout, null, point, tokens);
}

fn hitTestWidgetLayoutChildren(layout: anytype, parent_index: ?usize, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    const child_count = widget_tree.widgetLayoutDirectChildCount(layout, parent_index);
    var tested: usize = 0;
    var previous: ?widget_tree.WidgetPaintOrder = null;
    while (tested < child_count) : (tested += 1) {
        const child_index = widget_tree.previousWidgetLayoutPaintChild(layout, parent_index, tokens, previous) orelse return null;
        // Anchored floating children live in the hoisted pre-pass above,
        // never at their tree position.
        if (!widget_tree.widgetIsAnchored(layout.nodes[child_index].widget)) {
            if (hitTestWidgetLayoutNode(layout, child_index, point, tokens)) |hit| return hit;
        }
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
    // Concealed disclosure content is inert: a closed — or still
    // revealing — accordion hit-tests as ONE leaf (its trigger band),
    // so a press inside a partially revealed region cannot reach
    // content the reveal has not finished delivering, and the full-size
    // content a closed item keeps laid out below its header never
    // shadows the widgets that actually occupy that space.
    const content_interactive = !widget_tree.widgetKindDisclosureAnimated(node.widget.kind) or widget_tree.disclosureSettledOpen(layout, node_index);
    if (content_interactive) {
        if (hitTestWidgetLayoutChildren(layout, node_index, local_point, tokens)) |hit| return hit;
    }

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
        .role = node.widget.semantics.role,
    };
}

/// The widget a press that hit `hit` actually lands on: the deepest
/// widget on the hit path (the target itself, then its ancestors) that
/// claims presses (`widgetClaimsPress`). Plain text, icons, decorations,
/// and layout containers let the press fall through; interactive kinds,
/// editable text, scroll containers, overlay surfaces, and any widget
/// with a bound press/toggle handler stop the walk. Returns null when
/// nothing on the path claims — the press dispatches to no one, exactly
/// like a click on dead space.
pub fn widgetPressTargetIndexFromNode(layout: anytype, node_index: usize) ?usize {
    var current: ?usize = node_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return null;
        if (widget_access.widgetClaimsPress(layout.nodes[index].widget)) return index;
        current = layout.nodes[index].parent_index;
    }
    return null;
}

pub fn widgetPressTargetForHit(layout: anytype, hit: WidgetHit) ?WidgetHit {
    const index = widgetPressTargetIndexFromNode(layout, hit.index) orelse return null;
    return widgetHitFromNode(layout.nodes[index], index);
}

/// The widget a HOVER that hit `hit` visually belongs to: the same
/// target-then-ancestors walk as the press fall-through, so the hover
/// wash and the pointer cursor track exactly where a click would land.
/// A composite row is ONE interactive surface — a hit on plain text, an
/// icon, or a badge inside a list row attributes hover to the row, so
/// the wash never drops out over the row's own content. Links keep their
/// own hover (the pointer cursor is the link's affordance even inside a
/// pressable ancestor), and a hit with no claiming ancestor keeps itself
/// (static text keeps its selection affordance).
pub fn widgetHoverTargetForHit(layout: anytype, hit: WidgetHit) WidgetHit {
    if (hit.role == .link and !hit.state.disabled) return hit;
    const target = widgetPressTargetForHit(layout, hit) orelse hit;
    // A table row hovers as ONE unit: a hit that resolves to a cell (a
    // plain cell claims nothing, so the fall-through keeps the raw hit)
    // attributes hover to its `data_row`, the full-width row wash. A
    // cell with its own press handler still routes the CLICK to itself;
    // only the wash lifts to the row.
    if (target.kind == .data_cell) {
        if (widgetAncestorHitOfKind(layout, target.index, .data_row)) |row_hit| return row_hit;
    }
    return target;
}

/// The hover-Msg containment chain for a raw hit: every widget on the
/// hit path (the target itself, then its ancestors) whose bound
/// hover-enter/hover-leave handlers are live
/// (`widget_access.widgetListensForHoverMsgs`), written into `output`
/// OUTERMOST FIRST — the DOM's mouseenter order, so a diff against the
/// previously delivered chain fires enters outermost-first and leaves
/// innermost-first by construction. Nested listeners each track their
/// own containment: moving from a listening card onto a listening row
/// inside it keeps the card's entry (the pointer never left the card),
/// exactly like the browser pair this models. The chain is empty for
/// apps that bind no hover handlers, so unbound trees pay nothing.
pub fn widgetHoverMsgChainFromNode(layout: anytype, node_index: usize, output: []ObjectId) []const ObjectId {
    var chain: [max_widget_depth]ObjectId = undefined;
    var chain_len: usize = 0;
    var current: ?usize = node_index;
    while (current) |index| {
        if (index >= layout.nodes.len) break;
        if (widget_access.widgetListensForHoverMsgs(layout.nodes[index].widget) and chain_len < chain.len) {
            chain[chain_len] = layout.nodes[index].widget.id;
            chain_len += 1;
        }
        current = layout.nodes[index].parent_index;
    }
    const len = @min(chain_len, output.len);
    // The walk collected innermost-first; deliver outermost-first.
    for (0..len) |index| {
        output[index] = chain[chain_len - 1 - index];
    }
    return output[0..len];
}

/// The nearest ancestor of `node_index` with the given kind, as a hit.
fn widgetAncestorHitOfKind(layout: anytype, node_index: usize, kind: WidgetKind) ?WidgetHit {
    var current: ?usize = if (node_index < layout.nodes.len) layout.nodes[node_index].parent_index else null;
    while (current) |index| {
        if (index >= layout.nodes.len) return null;
        if (layout.nodes[index].widget.kind == kind) return widgetHitFromNode(layout.nodes[index], index);
        current = layout.nodes[index].parent_index;
    }
    return null;
}

/// The window-drag region a press that hit `node_index` lands on, if
/// any: the same target-then-ancestors walk as the press fall-through,
/// but a press-CLAIMING widget encountered first wins the gesture for
/// itself (a button inside a drag header stays a button) and stops the
/// walk. A widget that both claims presses and marks `window_drag`
/// keeps its press — authored handlers outrank the drag surface.
pub fn widgetWindowDragTargetIndexFromNode(layout: anytype, node_index: usize) ?usize {
    var current: ?usize = node_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return null;
        if (widget_access.widgetClaimsPress(layout.nodes[index].widget)) return null;
        if (widget_access.isWindowDragRegion(layout.nodes[index].widget)) return index;
        current = layout.nodes[index].parent_index;
    }
    return null;
}

fn isPointVisibleInWidgetAncestors(layout: anytype, node_index: usize, point: geometry.PointF) bool {
    var current: usize = node_index;
    while (true) {
        // An anchored floating widget escapes its ancestors' clip regions
        // (window-clipped, not parent-clipped), so the walk stops here.
        if (widget_tree.widgetIsAnchored(layout.nodes[current].widget)) return true;
        const parent_index = layout.nodes[current].parent_index orelse return true;
        if (parent_index >= layout.nodes.len) return true;
        const parent = layout.nodes[parent_index];
        if (widget_tree.widgetClipsContent(parent.widget) and !parent.frame.normalized().containsPoint(point)) return false;
        current = parent_index;
    }
}

fn isWidgetFrameVisibleInWidgetAncestors(layout: anytype, node_index: usize) bool {
    if (node_index >= layout.nodes.len) return false;
    const frame = layout.nodes[node_index].frame.normalized();
    if (frame.isEmpty()) return false;
    var current: usize = node_index;
    while (true) {
        // Anchored floating widgets escape ancestor clips — focus targets
        // inside an open overlay stay live outside the scroll ancestor's
        // bounds.
        if (widget_tree.widgetIsAnchored(layout.nodes[current].widget)) return true;
        const parent_index = layout.nodes[current].parent_index orelse return true;
        if (parent_index >= layout.nodes.len) return true;
        const parent = layout.nodes[parent_index];
        if (widget_tree.widgetClipsContent(parent.widget) and geometry.RectF.intersection(frame, parent.frame.normalized()).isEmpty()) return false;
        current = parent_index;
    }
}

pub fn routeWidgetPointerEvent(layout: anytype, event: WidgetPointerEvent, tokens: DesignTokens, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    const target = if (eventUsesPointerCapture(event)) blk: {
        break :blk capturedWidgetPointerTarget(layout, event) orelse return .{ .entries = output[0..0] };
    } else hitTestWidgetLayout(layout, event.point, tokens) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target.index, output);
    return .{
        .target = target,
        .press_target = widgetPressTargetForHit(layout, target),
        .entries = entries,
    };
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
    if (widget_tree.isWidgetConcealedByDisclosure(layout, index)) return null;
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
        if (widget_tree.isWidgetConcealedByDisclosure(layout, index)) continue;
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
    if (widget_tree.isWidgetConcealedByDisclosure(layout, index)) return null;
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
    // Concealed disclosure content never joins the focus order: a
    // closed section's controls are unreachable by tab or arrows, and
    // mid-reveal content stays unreachable until the reveal settles.
    if (widget_tree.isWidgetConcealedByDisclosure(layout, index)) return null;
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
