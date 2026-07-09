const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const widget_access = @import("widget_access.zig");
const widget_routing = @import("widget_routing.zig");
const widget_semantics = @import("widget_semantics.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_text_input = @import("widget_text_input.zig");
const widget_layout = @import("widget_layout.zig");
const widget_render = @import("widget_render.zig");
const widget_invalidation = @import("widget_invalidation.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Builder = canvas.Builder;
const Color = drawing_model.Color;
const DesignTokens = token_model.DesignTokens;
const VirtualListRange = token_model.VirtualListRange;
const WidgetKind = widget_model.WidgetKind;
const WidgetCursor = widget_model.WidgetCursor;
const WidgetState = widget_model.WidgetState;
const WidgetRenderState = widget_model.WidgetRenderState;
const Widget = widget_model.Widget;
const WidgetLayoutNode = event_model.WidgetLayoutNode;
const WidgetHit = event_model.WidgetHit;
const WidgetPointerEvent = event_model.WidgetPointerEvent;
const WidgetKeyboardEvent = event_model.WidgetKeyboardEvent;
const WidgetFileDropEvent = event_model.WidgetFileDropEvent;
const WidgetDragEvent = event_model.WidgetDragEvent;
const WidgetEventRouteEntry = event_model.WidgetEventRouteEntry;
const WidgetEventRoute = event_model.WidgetEventRoute;
const WidgetKeyboardRoute = event_model.WidgetKeyboardRoute;
const WidgetFocusDirection = event_model.WidgetFocusDirection;
const WidgetFocusTarget = event_model.WidgetFocusTarget;
const WidgetSemanticsNode = event_model.WidgetSemanticsNode;
const WidgetInvalidation = event_model.WidgetInvalidation;

pub const max_widget_depth = widget_layout.max_widget_depth;
pub const max_widget_text_range_rects: usize = 4;
pub const widgetControlHeight = widget_metrics.widgetControlHeight;
pub const WidgetTextGeometry = widget_text_input.WidgetTextGeometry;
pub const textSelectionForWidgetPoint = widget_text_input.textSelectionForWidgetPoint;
pub const textOffsetForWidgetPoint = widget_text_input.textOffsetForWidgetPoint;
pub const textInputViewportForWidget = widget_text_input.textInputViewportForWidget;
pub const textInputClearButtonRect = widget_text_input.textInputClearButtonRect;
pub const textInputClearButtonHitRect = widget_text_input.textInputClearButtonHitRect;
pub const textInputContentExtentForWidget = widget_text_input.textInputContentExtentForWidget;
pub const textInputMaxScrollOffsetForWidget = widget_text_input.textInputMaxScrollOffsetForWidget;
pub const clampedTextInputScrollOffsetForWidget = widget_text_input.clampedTextInputScrollOffsetForWidget;
pub const textInputScrollOffsetToRevealCaret = widget_text_input.textInputScrollOffsetToRevealCaret;
pub const textGeometryForWidget = widget_text_input.textGeometryForWidget;

pub const WidgetLayoutTree = struct {
    nodes: []const WidgetLayoutNode = &.{},

    pub fn nodeCount(self: WidgetLayoutTree) usize {
        return self.nodes.len;
    }

    pub fn findById(self: WidgetLayoutTree, id: ObjectId) ?WidgetLayoutNode {
        if (id == 0) return null;
        for (self.nodes) |node| {
            if (node.widget.id == id) return node;
        }
        return null;
    }

    pub fn virtualRangeById(self: WidgetLayoutTree, id: ObjectId) ?VirtualListRange {
        if (id == 0) return null;
        for (self.nodes) |node| {
            if (node.widget.id == id) return widget_semantics.widgetVirtualRangeForLayoutNode(node);
        }
        return null;
    }

    pub fn virtualRangeAt(self: WidgetLayoutTree, index: usize) ?VirtualListRange {
        if (index >= self.nodes.len) return null;
        return widget_semantics.widgetVirtualRangeForLayoutNode(self.nodes[index]);
    }

    pub fn hitTest(self: WidgetLayoutTree, point: geometry.PointF) ?WidgetHit {
        return widget_routing.hitTestWidgetLayout(self, point, .{});
    }

    pub fn hitTestWithTokens(self: WidgetLayoutTree, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
        return widget_routing.hitTestWidgetLayout(self, point, tokens);
    }

    pub fn cursorForHit(self: WidgetLayoutTree, hit: ?WidgetHit) WidgetCursor {
        _ = self;
        return widget_access.cursorForWidgetHit(hit);
    }

    /// Resolve a raw hit to the widget hover visually belongs to: the
    /// press fall-through walk, so the hover wash and pointer cursor
    /// land where a click would (a composite row is one surface).
    pub fn hoverTargetForHit(self: WidgetLayoutTree, hit: ?WidgetHit) ?WidgetHit {
        const raw = hit orelse return null;
        return widget_routing.widgetHoverTargetForHit(self, raw);
    }

    pub fn routePointerEvent(self: WidgetLayoutTree, event: WidgetPointerEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return widget_routing.routeWidgetPointerEvent(self, event, .{}, output);
    }

    pub fn routePointerEventWithTokens(self: WidgetLayoutTree, event: WidgetPointerEvent, tokens: DesignTokens, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return widget_routing.routeWidgetPointerEvent(self, event, tokens, output);
    }

    pub fn routeKeyboardEvent(self: WidgetLayoutTree, event: WidgetKeyboardEvent, output: []WidgetEventRouteEntry) Error!WidgetKeyboardRoute {
        return widget_routing.routeWidgetKeyboardEvent(self, event, output, widgetScrollSemantics);
    }

    pub fn routeFileDropEvent(self: WidgetLayoutTree, event: WidgetFileDropEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return widget_routing.routeWidgetFileDropEvent(self, event, output);
    }

    pub fn routeDragEvent(self: WidgetLayoutTree, event: WidgetDragEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return widget_routing.routeWidgetDragEvent(self, event, output);
    }

    pub fn focusTarget(self: WidgetLayoutTree, current_id: ?ObjectId, direction: WidgetFocusDirection) ?WidgetFocusTarget {
        return widget_routing.focusWidgetTarget(self, current_id, direction, widgetScrollSemantics);
    }

    pub fn focusTargetById(self: WidgetLayoutTree, id: ObjectId) ?WidgetFocusTarget {
        return widget_routing.focusWidgetTargetById(self, id, widgetScrollSemantics);
    }

    pub fn collectSemantics(self: WidgetLayoutTree, output: []WidgetSemanticsNode) Error![]const WidgetSemanticsNode {
        return collectWidgetSemantics(self, output);
    }

    pub fn textGeometry(self: WidgetLayoutTree, id: ObjectId, tokens: DesignTokens) ?WidgetTextGeometry {
        const node = self.findById(id) orelse return null;
        return textGeometryForWidget(node.widget, tokens);
    }

    pub fn emitDisplayList(self: WidgetLayoutTree, builder: *Builder, tokens: DesignTokens) Error!void {
        return emitWidgetLayout(builder, self, tokens);
    }

    pub fn emitDisplayListWithState(self: WidgetLayoutTree, builder: *Builder, tokens: DesignTokens, state: WidgetRenderState) Error!void {
        return emitWidgetLayoutWithState(builder, self, tokens, state);
    }

    pub fn renderStateDirtyBounds(self: WidgetLayoutTree, previous: WidgetRenderState, next: WidgetRenderState) ?geometry.RectF {
        return self.renderStateDirtyBoundsWithTokens(previous, next, .{});
    }

    pub fn renderStateDirtyBoundsWithTokens(self: WidgetLayoutTree, previous: WidgetRenderState, next: WidgetRenderState, tokens: DesignTokens) ?geometry.RectF {
        return widget_invalidation.widgetRenderStateDirtyBounds(self, previous, next, tokens);
    }

    pub fn diff(previous: WidgetLayoutTree, next: WidgetLayoutTree, output: []WidgetInvalidation) Error![]const WidgetInvalidation {
        return diffWithTokens(previous, next, .{}, output);
    }

    pub fn diffWithTokens(previous: WidgetLayoutTree, next: WidgetLayoutTree, tokens: DesignTokens, output: []WidgetInvalidation) Error![]const WidgetInvalidation {
        return widget_invalidation.diffWidgetLayoutTrees(previous, next, tokens, output);
    }
};

pub fn emitWidgetTree(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    return widget_render.emitWidgetTree(builder, widget, tokens);
}

pub fn layoutWidgetTree(widget: Widget, bounds: geometry.RectF, output: []WidgetLayoutNode) Error!WidgetLayoutTree {
    return layoutWidgetTreeWithTokens(widget, bounds, .{}, output);
}

pub fn layoutWidgetTreeWithTokens(widget: Widget, bounds: geometry.RectF, tokens: DesignTokens, output: []WidgetLayoutNode) Error!WidgetLayoutTree {
    var len: usize = 0;
    _ = try widget_layout.layoutWidgetDepth(widget, bounds.normalized(), null, 0, output, &len, tokens);
    return .{ .nodes = output[0..len] };
}

pub fn intrinsicWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    return widget_layout.intrinsicWidgetSize(widget, tokens);
}

pub fn virtualWidgetScrollContentExtent(widget: Widget, viewport_extent: f32) f32 {
    return widget_layout.virtualWidgetScrollContentExtent(widget, viewport_extent);
}

pub fn virtualWidgetScrollContentExtentWithTokens(widget: Widget, viewport_extent: f32, tokens: DesignTokens) f32 {
    return widget_layout.virtualWidgetScrollContentExtentWithTokens(widget, viewport_extent, tokens);
}

pub fn emitWidgetLayout(builder: *Builder, layout: WidgetLayoutTree, tokens: DesignTokens) Error!void {
    return widget_render.emitWidgetLayout(builder, layout, tokens);
}

fn emitWidgetLayoutWithState(builder: *Builder, layout: WidgetLayoutTree, tokens: DesignTokens, state: WidgetRenderState) Error!void {
    return widget_render.emitWidgetLayoutWithState(builder, layout, tokens, state);
}

pub fn toggleWidgetKnobCommandId(id: ObjectId) ObjectId {
    return widget_render.toggleWidgetKnobCommandId(id);
}

pub fn textCaretCommandId(kind: WidgetKind, id: ObjectId) ObjectId {
    return widget_render.textCaretCommandId(kind, id);
}

pub fn spinnerWidgetArcCommandId(id: ObjectId) ObjectId {
    return widget_render.spinnerWidgetArcCommandId(id);
}

pub fn skeletonWidgetFillCommandId(id: ObjectId) ObjectId {
    return widget_render.skeletonWidgetFillCommandId(id);
}

pub fn spinnerWidgetRotationCenter(widget: Widget, tokens: DesignTokens) geometry.PointF {
    return widget_render.spinnerWidgetRotationCenter(widget, tokens);
}

pub fn spinnerWidgetSegmentCommandId(id: ObjectId, index: usize) ObjectId {
    return widget_render.spinnerWidgetSegmentCommandId(id, index);
}

pub fn spinnerWidgetSegmentCount(tokens: DesignTokens) usize {
    return widget_render.spinnerWidgetSegmentCount(tokens);
}

/// The rect a chart's data plots into (padded frame minus opted-in axis
/// label gutters) — the runtime's hover logic and the renderer share it.
pub fn chartWidgetPlotRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    return widget_render.chartWidgetPlotRect(widget, tokens);
}

/// The sample index a pointer over a hover-details chart snaps to (null
/// for anything else) — the runtime's repaint gate for chart hover.
pub fn chartWidgetHoverIndex(widget: Widget, tokens: DesignTokens, point: geometry.PointF) ?usize {
    return widget_render.chartWidgetHoverIndex(widget, tokens, point);
}

pub fn toggleWidgetKnobTravel(widget: Widget, tokens: DesignTokens) f32 {
    return widget_render.toggleWidgetKnobTravel(widget, tokens);
}

/// The point synthesized pointer input (automation `widget-click`) should
/// aim at. Selection controls draw their glyph as a small sub-rect of the
/// widget frame — a switch stretched to fill a column still renders a
/// ~36px track at its left edge — so aiming at the geometric center of a
/// stretched frame can land far from the visible control (or under an
/// overlapping later-painted sibling) and miss. Aim at the rendered
/// control glyph for those kinds; everything else keeps the frame center.
pub fn widgetControlAimPoint(widget: Widget, tokens: DesignTokens) geometry.PointF {
    return switch (widget.kind) {
        .switch_control => widget_render.toggleWidgetTrackRect(widget, tokens).center(),
        .checkbox => widget_render.checkboxWidgetBoxRect(widget, tokens).center(),
        .radio => widget_render.radioWidgetCircleRect(widget, tokens).center(),
        else => widget.frame.normalized().center(),
    };
}

pub fn widgetPartId(id: ObjectId, slot: ObjectId) ObjectId {
    return widget_render.widgetPartId(id, slot);
}

pub fn textSelectionFillColor(widget: Widget, tokens: DesignTokens) Color {
    return widget_render.textSelectionFillColor(widget, tokens);
}

pub fn textSelectionTextColor(widget: Widget, tokens: DesignTokens) Color {
    return widget_render.textSelectionTextColor(widget, tokens);
}

pub fn textEditingInkColor(widget: Widget, tokens: DesignTokens) Color {
    return widget_render.textEditingInkColor(widget, tokens);
}

pub fn staticTextSelectionFillColor(widget: Widget, tokens: DesignTokens) Color {
    return widget_render.staticTextSelectionFillColor(widget, tokens);
}

/// Stable command id of the `ordinal`-th static text selection highlight
/// rect on a `.text` widget (tests and retained diffing).
pub fn textSelectionCommandId(widget_id: ObjectId, ordinal: usize) ObjectId {
    return widget_render.textSelectionCommandId(widget_id, ordinal);
}

pub fn colorWithAlpha(color: Color, alpha: f32) Color {
    return widget_render.colorWithAlpha(color, alpha);
}

pub fn transparentColor() Color {
    return widget_render.transparentColor();
}
pub fn cursorForWidgetHit(hit: ?WidgetHit) WidgetCursor {
    return widget_access.cursorForWidgetHit(hit);
}

pub fn cursorForWidgetTarget(kind: WidgetKind, state: WidgetState) WidgetCursor {
    return widget_access.cursorForWidgetTarget(kind, state);
}

fn collectWidgetSemantics(layout: WidgetLayoutTree, output: []WidgetSemanticsNode) Error![]const WidgetSemanticsNode {
    return widget_semantics.collectWidgetSemantics(layout, output, widgetScrollSemantics);
}

fn widgetScrollSemantics(layout: WidgetLayoutTree, node_index: usize) widget_semantics.WidgetScrollSemantics {
    return widget_semantics.widgetScrollSemantics(layout, node_index, widget_layout.virtualWidgetScrollContentExtent);
}
