const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const equality_model = @import("equality.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const FontId = canvas.FontId;
const Builder = canvas.Builder;
const CanvasCommand = canvas.CanvasCommand;
const Color = drawing_model.Color;
const Affine = drawing_model.Affine;
const Radius = drawing_model.Radius;
const Fill = drawing_model.Fill;
const Stroke = drawing_model.Stroke;
const Clip = drawing_model.Clip;
const Shadow = drawing_model.Shadow;
const DrawText = text_model.DrawText;
const TextWrap = text_model.TextWrap;
const TextAlign = text_model.TextAlign;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextLayout = text_model.TextLayout;
const TextLine = text_model.TextLine;
const TextRange = text_model.TextRange;
const TextSelection = text_model.TextSelection;
const TextSelectionRect = text_model.TextSelectionRect;
const Density = token_model.Density;
const DesignTokens = token_model.DesignTokens;
const ControlVisualTokens = token_model.ControlVisualTokens;
const VirtualListRange = token_model.VirtualListRange;
const virtualListRange = token_model.virtualListRange;
const WidgetKind = widget_model.WidgetKind;
const WidgetCursor = widget_model.WidgetCursor;
const WidgetState = widget_model.WidgetState;
const WidgetRenderState = widget_model.WidgetRenderState;
const WidgetMainAlignment = widget_model.WidgetMainAlignment;
const WidgetCrossAlignment = widget_model.WidgetCrossAlignment;
const WidgetLayoutStyle = widget_model.WidgetLayoutStyle;
const WidgetStyle = widget_model.WidgetStyle;
const WidgetVariant = widget_model.WidgetVariant;
const WidgetSize = widget_model.WidgetSize;
const WidgetRole = widget_model.WidgetRole;
const WidgetActions = widget_model.WidgetActions;
const WidgetSemantics = widget_model.WidgetSemantics;
const Widget = widget_model.Widget;
const WidgetLayoutNode = event_model.WidgetLayoutNode;
const WidgetHit = event_model.WidgetHit;
const WidgetPointerPhase = event_model.WidgetPointerPhase;
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
const WidgetScrollMetrics = event_model.WidgetScrollMetrics;
const WidgetListMetrics = event_model.WidgetListMetrics;
const WidgetSemanticsNode = event_model.WidgetSemanticsNode;
const WidgetInvalidationKind = event_model.WidgetInvalidationKind;
const WidgetInvalidation = event_model.WidgetInvalidation;
const semanticActions = event_model.semanticActions;
const defaultSemanticActions = event_model.defaultSemanticActions;
const defaultFocusable = event_model.defaultFocusable;
const textLineBounds = text_model.textLineBounds;
const estimateTextWidth = text_model.estimateTextWidth;
const estimateTextWidthForFont = text_model.estimateTextWidthForFont;
const estimateTextAdvanceForBytes = text_model.estimateTextAdvanceForBytes;
const estimatedGlyphAdvance = text_model.estimatedGlyphAdvance;
const snapTextSelection = text_model.snapTextSelection;
const snapTextRange = text_model.snapTextRange;
const nextTextOffset = text_model.nextTextOffset;
const nextTextLineEnd = text_model.nextTextLineEnd;
const isTextBreakByte = text_model.isTextBreakByte;
const textLineRange = text_model.textLineRange;
const textLineCaretX = text_model.textLineCaretX;
const layoutTextRun = text_model.layoutTextRun;
const layoutTextCaretRect = text_model.layoutTextCaretRect;
const textCaretRectForLayout = text_model.textCaretRectForLayout;
const layoutTextSelectionRects = text_model.layoutTextSelectionRects;
const layoutTextOffsetForPoint = text_model.layoutTextOffsetForPoint;
const strokeBounds = drawing_model.strokeBounds;
const shadowBounds = drawing_model.shadowBounds;
const rectsEqual = equality_model.rectsEqual;
const optionalRectsEqual = equality_model.optionalRectsEqual;
const sizesEqual = equality_model.sizesEqual;
const insetsEqual = equality_model.insetsEqual;
const optionalColorsEqual = equality_model.optionalColorsEqual;
const radiiEqual = equality_model.radiiEqual;
const affinesEqual = equality_model.affinesEqual;
const optionalF32Equal = equality_model.optionalF32Equal;
const optionalTextSelectionsEqual = equality_model.optionalTextSelectionsEqual;
const optionalTextRangesEqual = equality_model.optionalTextRangesEqual;

pub const max_widget_depth: usize = 32;
pub const max_widget_text_range_rects: usize = 4;
const max_widget_text_layout_lines: usize = 16;
const default_widget_row_extent: f32 = 28;
const SpinnerSegment = struct { x: f32, y: f32 };
const spinner_segments = [_]SpinnerSegment{
    .{ .x = 0, .y = -1 },
    .{ .x = 0.707, .y = -0.707 },
    .{ .x = 1, .y = 0 },
    .{ .x = 0.707, .y = 0.707 },
    .{ .x = 0, .y = 1 },
    .{ .x = -0.707, .y = 0.707 },
    .{ .x = -1, .y = 0 },
    .{ .x = -0.707, .y = -0.707 },
};

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
            if (node.widget.id == id) return widgetVirtualRangeForLayoutNode(node);
        }
        return null;
    }

    pub fn virtualRangeAt(self: WidgetLayoutTree, index: usize) ?VirtualListRange {
        if (index >= self.nodes.len) return null;
        return widgetVirtualRangeForLayoutNode(self.nodes[index]);
    }

    pub fn hitTest(self: WidgetLayoutTree, point: geometry.PointF) ?WidgetHit {
        return hitTestWidgetLayout(self, point, .{});
    }

    pub fn hitTestWithTokens(self: WidgetLayoutTree, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
        return hitTestWidgetLayout(self, point, tokens);
    }

    pub fn cursorForHit(self: WidgetLayoutTree, hit: ?WidgetHit) WidgetCursor {
        _ = self;
        return cursorForWidgetHit(hit);
    }

    pub fn routePointerEvent(self: WidgetLayoutTree, event: WidgetPointerEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return routeWidgetPointerEvent(self, event, .{}, output);
    }

    pub fn routePointerEventWithTokens(self: WidgetLayoutTree, event: WidgetPointerEvent, tokens: DesignTokens, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return routeWidgetPointerEvent(self, event, tokens, output);
    }

    pub fn routeKeyboardEvent(self: WidgetLayoutTree, event: WidgetKeyboardEvent, output: []WidgetEventRouteEntry) Error!WidgetKeyboardRoute {
        return routeWidgetKeyboardEvent(self, event, output);
    }

    pub fn routeFileDropEvent(self: WidgetLayoutTree, event: WidgetFileDropEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return routeWidgetFileDropEvent(self, event, output);
    }

    pub fn routeDragEvent(self: WidgetLayoutTree, event: WidgetDragEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
        return routeWidgetDragEvent(self, event, output);
    }

    pub fn focusTarget(self: WidgetLayoutTree, current_id: ?ObjectId, direction: WidgetFocusDirection) ?WidgetFocusTarget {
        return focusWidgetTarget(self, current_id, direction);
    }

    pub fn focusTargetById(self: WidgetLayoutTree, id: ObjectId) ?WidgetFocusTarget {
        return focusWidgetTargetById(self, id);
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
        return widgetRenderStateDirtyBounds(self, previous, next, tokens);
    }

    pub fn diff(previous: WidgetLayoutTree, next: WidgetLayoutTree, output: []WidgetInvalidation) Error![]const WidgetInvalidation {
        return diffWithTokens(previous, next, .{}, output);
    }

    pub fn diffWithTokens(previous: WidgetLayoutTree, next: WidgetLayoutTree, tokens: DesignTokens, output: []WidgetInvalidation) Error![]const WidgetInvalidation {
        return diffWidgetLayoutTrees(previous, next, tokens, output);
    }
};

pub fn emitWidgetTree(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitWidgetDepth(builder, widget, tokens, 0);
}

pub fn layoutWidgetTree(widget: Widget, bounds: geometry.RectF, output: []WidgetLayoutNode) Error!WidgetLayoutTree {
    return layoutWidgetTreeWithTokens(widget, bounds, .{}, output);
}

pub fn layoutWidgetTreeWithTokens(widget: Widget, bounds: geometry.RectF, tokens: DesignTokens, output: []WidgetLayoutNode) Error!WidgetLayoutTree {
    var len: usize = 0;
    _ = try layoutWidgetDepth(widget, bounds.normalized(), null, 0, output, &len, tokens);
    return .{ .nodes = output[0..len] };
}

pub fn emitWidgetLayout(builder: *Builder, layout: WidgetLayoutTree, tokens: DesignTokens) Error!void {
    return emitWidgetLayoutWithState(builder, layout, tokens, .{});
}

fn emitWidgetLayoutWithState(builder: *Builder, layout: WidgetLayoutTree, tokens: DesignTokens, state: WidgetRenderState) Error!void {
    try emitWidgetLayoutChildren(builder, layout, null, tokens, state);
}

const WidgetPaintOrder = struct {
    layer: i32,
    index: usize,
};

fn widgetPaintLayer(widget: Widget, tokens: DesignTokens) i32 {
    if (widget.layer) |layer| return layer;
    return switch (widget.kind) {
        .popover, .menu_surface, .dropdown_menu => tokens.layer.overlay,
        .tooltip => tokens.layer.floating,
        else => tokens.layer.base,
    };
}

fn nextWidgetPaintChild(children: []const Widget, tokens: DesignTokens, previous: ?WidgetPaintOrder) ?usize {
    var best: ?WidgetPaintOrder = null;
    for (children, 0..) |child, index| {
        const order = WidgetPaintOrder{ .layer = widgetPaintLayer(child, tokens), .index = index };
        if (!widgetPaintOrderAfter(order, previous)) continue;
        if (best == null or widgetPaintOrderLess(order, best.?)) best = order;
    }
    return if (best) |order| order.index else null;
}

fn widgetLayoutDirectChildCount(layout: WidgetLayoutTree, parent_index: ?usize) usize {
    var count: usize = 0;
    for (layout.nodes) |node| {
        if (optionalUsizeEqual(node.parent_index, parent_index)) count += 1;
    }
    return count;
}

fn nextWidgetLayoutPaintChild(layout: WidgetLayoutTree, parent_index: ?usize, tokens: DesignTokens, previous: ?WidgetPaintOrder) ?usize {
    var best: ?WidgetPaintOrder = null;
    for (layout.nodes, 0..) |node, index| {
        if (!optionalUsizeEqual(node.parent_index, parent_index)) continue;
        const order = WidgetPaintOrder{ .layer = widgetPaintLayer(node.widget, tokens), .index = index };
        if (!widgetPaintOrderAfter(order, previous)) continue;
        if (best == null or widgetPaintOrderLess(order, best.?)) best = order;
    }
    return if (best) |order| order.index else null;
}

fn previousWidgetLayoutPaintChild(layout: WidgetLayoutTree, parent_index: ?usize, tokens: DesignTokens, previous: ?WidgetPaintOrder) ?usize {
    var best: ?WidgetPaintOrder = null;
    for (layout.nodes, 0..) |node, index| {
        if (!optionalUsizeEqual(node.parent_index, parent_index)) continue;
        const order = WidgetPaintOrder{ .layer = widgetPaintLayer(node.widget, tokens), .index = index };
        if (!widgetPaintOrderBefore(order, previous)) continue;
        if (best == null or widgetPaintOrderLess(best.?, order)) best = order;
    }
    return if (best) |order| order.index else null;
}

fn widgetPaintOrderAfter(order: WidgetPaintOrder, previous: ?WidgetPaintOrder) bool {
    const value = previous orelse return true;
    return order.layer > value.layer or (order.layer == value.layer and order.index > value.index);
}

fn widgetPaintOrderBefore(order: WidgetPaintOrder, previous: ?WidgetPaintOrder) bool {
    const value = previous orelse return true;
    return order.layer < value.layer or (order.layer == value.layer and order.index < value.index);
}

fn widgetPaintOrderLess(a: WidgetPaintOrder, b: WidgetPaintOrder) bool {
    return a.layer < b.layer or (a.layer == b.layer and a.index < b.index);
}

fn optionalUsizeEqual(a: ?usize, b: ?usize) bool {
    if (a) |a_value| {
        return if (b) |b_value| a_value == b_value else false;
    }
    return b == null;
}

fn emitWidgetDepth(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    if (depth >= max_widget_depth) return error.WidgetDepthExceeded;
    if (widget.semantics.hidden) return;

    const opacity = widgetOpacity(widget);
    if (opacity <= 0) return;
    const wrap_opacity = opacity < 1;
    const transform = widgetTransform(widget);
    const wrap_transform = !affinesEqual(transform, Affine.identity());
    const inverse_transform = if (wrap_transform) transform.inverse() orelse return error.InvalidTransform else Affine.identity();
    if (wrap_opacity) try builder.pushOpacity(opacity);
    if (wrap_transform) try builder.transform(transform);
    try emitWidgetDepthContent(builder, widget, tokens, depth);
    if (wrap_transform) try builder.transform(inverse_transform);
    if (wrap_opacity) try builder.popOpacity();
}

fn emitWidgetDepthContent(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    const paint_widget = widgetWithFrame(widget, pixelSnapGeometryRect(tokens, widget.frame));
    try emitWidgetBackdropBlur(builder, paint_widget, tokens);
    switch (paint_widget.kind) {
        .stack, .row, .column, .grid, .data_grid, .table, .list, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .data_row => try emitWidgetClippedChildren(builder, paint_widget, tokens, depth),
        .scroll_view => try emitScrollViewWidget(builder, paint_widget, tokens, depth),
        .alert => try emitAlertWidget(builder, paint_widget, tokens, depth),
        .card => try emitCardWidget(builder, paint_widget, tokens, depth),
        .dialog => try emitDialogSurfaceWidget(builder, paint_widget, tokens, depth),
        .drawer => try emitDrawerSurfaceWidget(builder, paint_widget, tokens, depth),
        .sheet => try emitSheetSurfaceWidget(builder, paint_widget, tokens, depth),
        .accordion, .bubble, .resizable, .panel => try emitPanelWidget(builder, paint_widget, tokens, depth),
        .popover => try emitPopoverWidget(builder, paint_widget, tokens, depth),
        .menu_surface, .dropdown_menu => try emitMenuSurfaceWidget(builder, paint_widget, tokens, depth),
        .text => try emitTextWidget(builder, paint_widget, tokens),
        .icon => try emitIconWidget(builder, paint_widget, tokens),
        .image => try emitImageWidget(builder, paint_widget),
        .avatar => try emitAvatarWidget(builder, paint_widget, tokens),
        .badge => try emitBadgeWidget(builder, paint_widget, tokens),
        .button, .toggle_button => try emitButtonWidget(builder, paint_widget, tokens),
        .icon_button => try emitIconButtonWidget(builder, paint_widget, tokens),
        .select => try emitSelectWidget(builder, paint_widget, tokens),
        .input, .text_field, .textarea => try emitTextFieldWidget(builder, paint_widget, tokens),
        .search_field, .combobox => try emitSearchFieldWidget(builder, paint_widget, tokens),
        .tooltip => try emitTooltipWidget(builder, paint_widget, tokens),
        .menu_item => try emitMenuItemWidget(builder, paint_widget, tokens),
        .list_item => try emitListItemWidget(builder, paint_widget, tokens),
        .data_cell => try emitDataCellWidget(builder, paint_widget, tokens),
        .status_bar => try emitStatusBarWidget(builder, paint_widget, tokens),
        .segmented_control => try emitSegmentedControlWidget(builder, paint_widget, tokens),
        .checkbox => try emitCheckboxWidget(builder, paint_widget, tokens),
        .radio => try emitRadioWidget(builder, paint_widget, tokens),
        .switch_control, .toggle => try emitToggleWidget(builder, paint_widget, tokens),
        .slider => try emitSliderWidget(builder, paint_widget, tokens),
        .progress => try emitProgressWidget(builder, paint_widget, tokens),
        .separator => try emitSeparatorWidget(builder, paint_widget, tokens),
        .skeleton => try emitSkeletonWidget(builder, paint_widget, tokens),
        .spinner => try emitSpinnerWidget(builder, paint_widget, tokens),
    }
}

fn emitWidgetChildren(builder: *Builder, children: []const Widget, tokens: DesignTokens, depth: usize) Error!void {
    var emitted: usize = 0;
    var previous: ?WidgetPaintOrder = null;
    while (emitted < children.len) : (emitted += 1) {
        const child_index = nextWidgetPaintChild(children, tokens, previous) orelse return;
        const child = children[child_index];
        try emitWidgetDepth(builder, child, tokens, depth + 1);
        previous = .{ .layer = widgetPaintLayer(child, tokens), .index = child_index };
    }
}

fn emitWidgetLayoutChildren(
    builder: *Builder,
    layout: WidgetLayoutTree,
    parent_index: ?usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
) Error!void {
    const child_count = widgetLayoutDirectChildCount(layout, parent_index);
    var emitted: usize = 0;
    var previous: ?WidgetPaintOrder = null;
    while (emitted < child_count) : (emitted += 1) {
        const child_index = nextWidgetLayoutPaintChild(layout, parent_index, tokens, previous) orelse return;
        try emitWidgetLayoutNode(builder, layout, child_index, tokens, state);
        previous = .{ .layer = widgetPaintLayer(layout.nodes[child_index].widget, tokens), .index = child_index };
    }
}

fn emitWidgetLayoutNode(
    builder: *Builder,
    layout: WidgetLayoutTree,
    node_index: usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
) Error!void {
    const node = layout.nodes[node_index];
    if (node.widget.semantics.hidden) return;

    const widget = widgetWithRenderState(widgetWithFrame(node.widget, node.frame), state);
    const opacity = widgetOpacity(widget);
    if (opacity <= 0) return;
    const wrap_opacity = opacity < 1;
    const transform = widgetTransform(widget);
    const wrap_transform = !affinesEqual(transform, Affine.identity());
    const inverse_transform = if (wrap_transform) transform.inverse() orelse return error.InvalidTransform else Affine.identity();
    if (wrap_opacity) try builder.pushOpacity(opacity);
    if (wrap_transform) try builder.transform(transform);
    try emitWidgetLayoutNodeContent(builder, layout, node_index, tokens, state, widget);
    if (wrap_transform) try builder.transform(inverse_transform);
    if (wrap_opacity) try builder.popOpacity();
}

fn emitWidgetLayoutNodeContent(
    builder: *Builder,
    layout: WidgetLayoutTree,
    node_index: usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
    widget: Widget,
) Error!void {
    const paint_widget = widgetWithFrame(widget, pixelSnapGeometryRect(tokens, widget.frame));
    try emitWidgetBackdropBlur(builder, paint_widget, tokens);
    switch (paint_widget.kind) {
        .stack, .row, .column, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .data_row => {},
        .grid, .data_grid, .table, .list => if (paint_widget.layout.virtualized) {
            try emitWidgetLayoutScrollableChildren(builder, layout, node_index, tokens, state, paint_widget);
            return;
        },
        .scroll_view => {
            try builder.pushClip(.{ .id = widgetPartId(paint_widget.id, 1), .rect = paint_widget.frame });
            try emitWidgetLayoutChildren(builder, layout, node_index, tokens, state);
            try builder.popClip();
            try emitScrollViewScrollbar(builder, paint_widget.frame, widgetScrollSemantics(layout, node_index).metrics, tokens, paint_widget.id);
            return;
        },
        .alert => try emitAlertWidgetChrome(builder, paint_widget, tokens),
        .card => try emitCardWidgetChrome(builder, paint_widget, tokens),
        .dialog => try emitDialogSurfaceWidgetChrome(builder, paint_widget, tokens),
        .drawer => try emitDrawerSurfaceWidgetChrome(builder, paint_widget, tokens),
        .sheet => try emitSheetSurfaceWidgetChrome(builder, paint_widget, tokens),
        .accordion, .bubble, .resizable, .panel => try emitPanelWidgetChrome(builder, paint_widget, tokens),
        .popover => try emitPopoverWidgetChrome(builder, paint_widget, tokens),
        .menu_surface, .dropdown_menu => try emitMenuSurfaceWidgetChrome(builder, paint_widget, tokens),
        .text => try emitTextWidget(builder, paint_widget, tokens),
        .icon => try emitIconWidget(builder, paint_widget, tokens),
        .image => try emitImageWidget(builder, paint_widget),
        .avatar => try emitAvatarWidget(builder, paint_widget, tokens),
        .badge => try emitBadgeWidget(builder, paint_widget, tokens),
        .button, .toggle_button => try emitButtonWidget(builder, paint_widget, tokens),
        .icon_button => try emitIconButtonWidget(builder, paint_widget, tokens),
        .select => try emitSelectWidget(builder, paint_widget, tokens),
        .input, .text_field, .textarea => try emitTextFieldWidget(builder, paint_widget, tokens),
        .search_field, .combobox => try emitSearchFieldWidget(builder, paint_widget, tokens),
        .tooltip => try emitTooltipWidget(builder, paint_widget, tokens),
        .menu_item => try emitMenuItemWidget(builder, paint_widget, tokens),
        .list_item => try emitListItemWidget(builder, paint_widget, tokens),
        .data_cell => try emitDataCellWidget(builder, paint_widget, tokens),
        .status_bar => try emitStatusBarWidget(builder, paint_widget, tokens),
        .segmented_control => try emitSegmentedControlWidget(builder, paint_widget, tokens),
        .checkbox => try emitCheckboxWidget(builder, paint_widget, tokens),
        .radio => try emitRadioWidget(builder, paint_widget, tokens),
        .switch_control, .toggle => try emitToggleWidget(builder, paint_widget, tokens),
        .slider => try emitSliderWidget(builder, paint_widget, tokens),
        .progress => try emitProgressWidget(builder, paint_widget, tokens),
        .separator => try emitSeparatorWidget(builder, paint_widget, tokens),
        .skeleton => try emitSkeletonWidget(builder, paint_widget, tokens),
        .spinner => try emitSpinnerWidget(builder, paint_widget, tokens),
    }

    try emitWidgetLayoutClippedChildren(builder, layout, node_index, tokens, state, paint_widget);
}

fn emitWidgetLayoutScrollableChildren(
    builder: *Builder,
    layout: WidgetLayoutTree,
    parent_index: usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
    widget: Widget,
) Error!void {
    const clip = if (widget.layout.clip_content) widgetContentClip(widget, tokens) else Clip{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
    };
    try builder.pushClip(clip);
    try emitWidgetLayoutChildren(builder, layout, parent_index, tokens, state);
    try builder.popClip();
    try emitScrollViewScrollbar(builder, widget.frame, widgetScrollSemantics(layout, parent_index).metrics, tokens, widget.id);
}

fn widgetOpacity(widget: Widget) f32 {
    return std.math.clamp(widget.opacity, 0, 1);
}

fn widgetTransform(widget: Widget) Affine {
    return widget.transform;
}

fn pixelSnapScale(tokens: DesignTokens) ?f32 {
    const scale = tokens.pixel_snap.scale;
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    return scale;
}

fn pixelSnapValueWithScale(value: f32, scale: f32) f32 {
    return @round(value * scale) / scale;
}

fn pixelSnapGeometryRect(tokens: DesignTokens, rect: geometry.RectF) geometry.RectF {
    if (!tokens.pixel_snap.geometry) return rect;
    const scale = pixelSnapScale(tokens) orelse return rect;
    const normalized = rect.normalized();
    const x0 = pixelSnapValueWithScale(normalized.x, scale);
    const y0 = pixelSnapValueWithScale(normalized.y, scale);
    const x1 = pixelSnapValueWithScale(normalized.maxX(), scale);
    const y1 = pixelSnapValueWithScale(normalized.maxY(), scale);
    return geometry.RectF.init(x0, y0, @max(0, x1 - x0), @max(0, y1 - y0));
}

fn pixelSnapGeometryPoint(tokens: DesignTokens, point: geometry.PointF) geometry.PointF {
    if (!tokens.pixel_snap.geometry) return point;
    const scale = pixelSnapScale(tokens) orelse return point;
    return geometry.PointF.init(
        pixelSnapValueWithScale(point.x, scale),
        pixelSnapValueWithScale(point.y, scale),
    );
}

fn pixelSnapTextPoint(tokens: DesignTokens, point: geometry.PointF) geometry.PointF {
    if (!tokens.pixel_snap.text) return point;
    const scale = pixelSnapScale(tokens) orelse return point;
    return geometry.PointF.init(
        pixelSnapValueWithScale(point.x, scale),
        pixelSnapValueWithScale(point.y, scale),
    );
}

fn emitWidgetBackdropBlur(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = widgetBackdropBlur(widget, tokens);
    if (radius <= 0 or widget.frame.normalized().isEmpty()) return;
    try builder.blur(.{
        .id = widgetPartId(widget.id, 12),
        .rect = widget.frame,
        .radius = radius,
    });
}

fn widgetBackdropBlur(widget: Widget, tokens: DesignTokens) f32 {
    const explicit = nonNegative(widget.backdrop_blur);
    if (explicit > 0) return explicit;
    if (widget.backdrop_blur_token) |token| return nonNegative(tokens.blur.value(token));
    return 0;
}

fn widgetClipsContent(widget: Widget) bool {
    return widget.kind == .scroll_view or widget.layout.clip_content;
}

fn widgetContentClip(widget: Widget, tokens: DesignTokens) Clip {
    return .{
        .id = widgetPartId(widget.id, 9),
        .rect = widget.frame,
        .radius = widgetContentClipRadius(widget, tokens),
    };
}

fn widgetContentClipRadius(widget: Widget, tokens: DesignTokens) Radius {
    if (!widget.layout.clip_content) return .{};
    return switch (widget.kind) {
        .accordion, .alert, .bubble, .card, .resizable, .panel, .menu_surface, .dropdown_menu => Radius.all(tokens.radius.lg),
        .dialog, .popover => Radius.all(tokens.radius.xl),
        .drawer, .sheet => Radius.all(tokens.radius.lg),
        .tooltip => Radius.all(tokens.radius.md),
        else => .{},
    };
}

fn emitAlertWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitAlertWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitAlertWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = alertControlVisualTokens(tokens);
    const radius = controlRadius(widget, visual, tokens.radius.lg);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.text.len == 0) return;

    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    const icon_size = @max(widgetSizedDensityValue(widget, tokens, 12), text_size - 1);
    const icon_frame = geometry.RectF.init(widget.frame.x + inset, widget.frame.y + inset, icon_size, icon_size);
    const text_gap = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text_frame = geometry.RectF.init(
        icon_frame.x + icon_size + text_gap,
        widget.frame.y,
        @max(1, widget.frame.width - inset * 2 - icon_size - text_gap),
        widget.frame.height,
    );
    const foreground = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    try emitAlertMark(builder, widget, tokens, icon_frame, foreground);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 6),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(text_frame.x, widget.frame.y + inset + text_size)),
        .color = foreground,
        .text = widget.text,
        .text_layout = .{
            .max_width = text_frame.width,
            .line_height = widgetLineHeight(text_size),
            .wrap = .word,
            .alignment = widget.text_alignment,
        },
    });
}

fn emitAlertMark(builder: *Builder, widget: Widget, tokens: DesignTokens, frame: geometry.RectF, color_value: Color) Error!void {
    const normalized = pixelSnapGeometryRect(tokens, frame.normalized());
    if (normalized.isEmpty()) return;
    const stroke = Stroke{ .fill = colorFill(color_value), .width = tokens.stroke.regular };
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = normalized,
        .radius = Radius.all(normalized.height * 0.5),
        .stroke = stroke,
    });
    const center_x = normalized.x + normalized.width * 0.5;
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 4),
        .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center_x, normalized.y + normalized.height * 0.28)),
        .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center_x, normalized.y + normalized.height * 0.58)),
        .stroke = stroke,
    });
    const dot_size = @max(1, normalized.height * 0.14);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 5),
        .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(center_x - dot_size * 0.5, normalized.y + normalized.height * 0.70, dot_size, dot_size)),
        .radius = Radius.all(dot_size * 0.5),
        .fill = colorFill(color_value),
    });
}

fn emitCardWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitCardWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitCardWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = cardControlVisualTokens(tokens);
    const radius = controlRadius(widget, visual, tokens.radius.lg);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.text.len == 0) return;

    const title_size = widgetTypographySize(widget, tokens.typography.body_size + 1);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = title_size,
        .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(widget.frame.x + inset, widget.frame.y + inset + title_size)),
        .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .text = widget.text,
        .text_layout = .{
            .max_width = @max(1, widget.frame.width - inset * 2),
            .line_height = widgetLineHeight(title_size),
            .wrap = .word,
            .alignment = widget.text_alignment,
        },
    });
}

fn emitDialogSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitDialogSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitDrawerSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitDrawerSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitSheetSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitSheetSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitDialogSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitModalSurfaceWidgetChrome(builder, widget, tokens, dialogControlVisualTokens(tokens), tokens.radius.xl);
}

fn emitDrawerSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitModalSurfaceWidgetChrome(builder, widget, tokens, drawerControlVisualTokens(tokens), tokens.radius.xl);
}

fn emitSheetSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitModalSurfaceWidgetChrome(builder, widget, tokens, sheetControlVisualTokens(tokens), tokens.radius.lg);
}

fn emitModalSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens, fallback_radius: f32) Error!void {
    const radius = controlRadius(widget, visual, fallback_radius);
    const shadow_token = tokens.shadow.md;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = widgetBackgroundFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.text.len == 0) return;

    const title_size = widgetTypographySize(widget, tokens.typography.title_size);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.xl);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 4),
        .font_id = tokens.typography.font_id,
        .size = title_size,
        .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(widget.frame.x + inset, widget.frame.y + inset + title_size)),
        .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .text = widget.text,
        .text_layout = .{
            .max_width = @max(1, widget.frame.width - inset * 2),
            .line_height = widgetLineHeight(title_size),
            .wrap = .word,
            .alignment = widget.text_alignment,
        },
    });
}

fn emitPanelWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitPanelWidgetChrome(builder, widget, tokens);
    if (!accordionChildrenVisible(widget)) return;
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitPopoverWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitPopoverWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitMenuSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitMenuSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitScrollViewWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try builder.pushClip(.{ .id = widgetPartId(widget.id, 1), .rect = widget.frame });
    try emitWidgetChildren(builder, widget.children, tokens, depth);
    try builder.popClip();
    try emitScrollViewScrollbar(builder, widget.frame, widgetScrollMetricsForWidget(widget), tokens, widget.id);
}

fn emitWidgetClippedChildren(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    if (widget.layout.clip_content) try builder.pushClip(widgetContentClip(widget, tokens));
    try emitWidgetChildren(builder, widget.children, tokens, depth);
    if (widget.layout.clip_content) try builder.popClip();
}

const ScrollbarGeometry = struct {
    track: geometry.RectF,
    thumb: geometry.RectF,
};

fn emitScrollViewScrollbar(builder: *Builder, frame: geometry.RectF, metrics: WidgetScrollMetrics, tokens: DesignTokens, id: ObjectId) Error!void {
    const scrollbar = scrollViewScrollbarGeometry(frame, metrics, tokens) orelse return;
    const track = pixelSnapGeometryRect(tokens, scrollbar.track);
    const thumb = pixelSnapGeometryRect(tokens, scrollbar.thumb);
    const visual = tokens.controls.scrollbar;
    const radius = Radius.all(if (visual.radius) |value| nonNegative(value) else track.width * 0.5);
    const track_fill = visual.background orelse colorWithAlpha(tokens.colors.border, @min(tokens.colors.border.a, 0.22));
    const thumb_fill = visual.foreground orelse visual.active_background orelse colorWithAlpha(tokens.colors.text_muted, 0.55);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(id, 2),
        .rect = track,
        .radius = radius,
        .fill = colorFill(track_fill),
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(id, 3),
        .rect = thumb,
        .radius = radius,
        .fill = colorFill(thumb_fill),
    });
}

fn scrollViewScrollbarGeometry(frame: geometry.RectF, metrics: WidgetScrollMetrics, tokens: DesignTokens) ?ScrollbarGeometry {
    if (!metrics.present) return null;
    const viewport = nonNegative(metrics.viewport_extent);
    const content = nonNegative(metrics.content_extent);
    const max_offset = @max(0, content - viewport);
    if (frame.isEmpty() or viewport <= 0 or content <= viewport or max_offset <= 0) return null;

    const inset = densityValue(tokens, 3);
    const thickness = @min(@max(densityValue(tokens, 3), frame.width * 0.0125), densityValue(tokens, 6));
    const track_height = @max(0, frame.height - inset * 2);
    if (track_height <= 0 or thickness <= 0) return null;

    const track = geometry.RectF.init(
        frame.x + frame.width - inset - thickness,
        frame.y + inset,
        thickness,
        track_height,
    );
    const thumb_ratio = std.math.clamp(viewport / content, 0, 1);
    const min_thumb = @min(track_height, densityValue(tokens, 18));
    const thumb_height = @min(track_height, @max(min_thumb, track_height * thumb_ratio));
    const travel = @max(0, track_height - thumb_height);
    const offset_ratio = std.math.clamp(nonNegative(metrics.offset) / max_offset, 0, 1);
    return .{
        .track = track,
        .thumb = geometry.RectF.init(track.x, track.y + travel * offset_ratio, track.width, thumb_height),
    };
}

fn widgetScrollMetricsForWidget(widget: Widget) WidgetScrollMetrics {
    if (widget.kind != .scroll_view) return .{};

    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    if (viewport.isEmpty()) return .{};

    const content_extent = widgetScrollContentExtentForWidget(widget, viewport);
    const max_offset = @max(0, content_extent - viewport.height);
    return .{
        .present = true,
        .offset = std.math.clamp(nonNegative(widget.value), 0, max_offset),
        .viewport_extent = viewport.height,
        .content_extent = content_extent,
    };
}

fn widgetScrollContentExtentForWidget(widget: Widget, viewport: geometry.RectF) f32 {
    if (widget.layout.virtualized) {
        return @max(viewport.height, virtualWidgetScrollContentExtent(widget, viewport.height));
    }

    const offset = widget.value;
    var bottom = viewport.maxY();
    for (widget.children) |child| {
        bottom = @max(bottom, child.frame.maxY() + offset);
    }
    return @max(0, bottom - viewport.y);
}

fn emitWidgetLayoutClippedChildren(
    builder: *Builder,
    layout: WidgetLayoutTree,
    parent_index: usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
    widget: Widget,
) Error!void {
    if (widget.layout.clip_content) try builder.pushClip(widgetContentClip(widget, tokens));
    try emitWidgetLayoutChildren(builder, layout, parent_index, tokens, state);
    if (widget.layout.clip_content) try builder.popClip();
}

fn emitPanelWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = surfaceControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.lg);
    const shadow_token = tokens.shadow.sm;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = widgetBackgroundFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.kind == .accordion) {
        try emitAccordionWidgetHeader(builder, widget, tokens, visual);
        if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 7);
    }
    if (widget.kind == .resizable) try emitResizableWidgetHandle(builder, widget, tokens, visual);
}

fn emitAccordionWidgetHeader(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Error!void {
    const frame = widget.frame.normalized();
    if (frame.isEmpty()) return;

    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text_size = widgetBodyTextSize(widget, tokens);
    const chevron_size = @max(widgetSizedDensityValue(widget, tokens, 10), text_size - 2);
    const chevron_center = geometry.PointF.init(frame.maxX() - inset - chevron_size * 0.5, frame.y + @min(frame.height * 0.5, inset + text_size * 0.45));
    const color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    if (widget.text.len > 0) {
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 6),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(frame.x + inset, frame.y + inset + text_size)),
            .color = color,
            .text = widget.text,
            .text_layout = .{
                .max_width = @max(1, frame.width - inset * 3 - chevron_size),
                .line_height = widgetLineHeight(text_size),
                .wrap = .none,
                .alignment = widget.text_alignment,
            },
        });
    }
    try emitAccordionChevron(builder, widget, tokens, chevron_center, chevron_size, color);
}

fn emitAccordionChevron(builder: *Builder, widget: Widget, tokens: DesignTokens, center: geometry.PointF, size: f32, color: Color) Error!void {
    const half = size * 0.28;
    const rise = size * 0.24;
    const stroke = Stroke{ .fill = colorFill(color), .width = tokens.stroke.regular };
    const selected = booleanControlSelected(widget);
    const first_from = if (selected)
        geometry.PointF.init(center.x - half, center.y - rise)
    else
        geometry.PointF.init(center.x - rise, center.y - half);
    const first_to = if (selected)
        geometry.PointF.init(center.x, center.y + rise)
    else
        geometry.PointF.init(center.x + rise, center.y);
    const second_to = if (selected)
        geometry.PointF.init(center.x + half, center.y - rise)
    else
        geometry.PointF.init(center.x - rise, center.y + half);
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 4),
        .from = pixelSnapGeometryPoint(tokens, first_from),
        .to = pixelSnapGeometryPoint(tokens, first_to),
        .stroke = stroke,
    });
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 5),
        .from = pixelSnapGeometryPoint(tokens, first_to),
        .to = pixelSnapGeometryPoint(tokens, second_to),
        .stroke = stroke,
    });
}

fn emitResizableWidgetHandle(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Error!void {
    const frame = widget.frame.normalized();
    if (frame.isEmpty()) return;

    const inset = widgetSizedDensityValue(widget, tokens, 6);
    const gap = widgetSizedDensityValue(widget, tokens, 4);
    const handle_height = @min(@max(widgetSizedDensityValue(widget, tokens, 10), frame.height * 0.48), @max(0, frame.height - inset * 2));
    if (handle_height <= 0) return;

    const right_x = @max(frame.x + inset, frame.maxX() - inset);
    const left_x = @max(frame.x + inset, right_x - gap);
    const y0 = frame.y + (frame.height - handle_height) * 0.5;
    const y1 = y0 + handle_height;
    const stroke = Stroke{
        .fill = colorFill(widgetForegroundColor(widget, tokens, visual.foreground orelse visual.border orelse tokens.colors.text_muted)),
        .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
    };

    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 4),
        .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left_x, y0)),
        .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left_x, y1)),
        .stroke = stroke,
    });
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 5),
        .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(right_x, y0)),
        .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(right_x, y1)),
        .stroke = stroke,
    });
}

fn emitPopoverWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = surfaceControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.xl);
    const shadow_token = tokens.shadow.md;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = widgetBackgroundFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
}

fn emitMenuSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = surfaceControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.lg);
    const shadow_token = tokens.shadow.md;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = widgetBackgroundFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
}

fn emitTextWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const text_size = widgetBodyTextSize(widget, tokens);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 1),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, textOrigin(widget.frame, text_size, 0)),
        .color = widgetForegroundColor(widget, tokens, tokens.colors.text),
        .text = widget.text,
        .text_layout = .{
            .max_width = widget.frame.width,
            .line_height = text_size * 1.25,
            .wrap = .word,
            .alignment = widget.text_alignment,
        },
    });
}

fn emitIconWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    if (widget.text.len == 0) return;
    const size = iconGlyphSize(widget, tokens);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 1),
        .font_id = tokens.typography.font_id,
        .size = size,
        .origin = pixelSnapTextPoint(tokens, centeredTextOrigin(widget.frame, widget.text, size)),
        .color = widgetForegroundColor(widget, tokens, tokens.colors.text),
        .text = widget.text,
    });
}

fn emitImageWidget(builder: *Builder, widget: Widget) Error!void {
    if (widget.image_id == 0 or widget.frame.normalized().isEmpty()) return;
    const clips_image = widget.image_fit == .cover;
    if (clips_image) try builder.pushClip(.{ .id = widgetPartId(widget.id, 2), .rect = widget.frame });
    try builder.drawImage(.{
        .id = widgetPartId(widget.id, 1),
        .image_id = widget.image_id,
        .src = widget.image_src,
        .dst = widget.frame,
        .opacity = widget.image_opacity,
        .fit = widget.image_fit,
        .sampling = widget.image_sampling,
    });
    if (clips_image) try builder.popClip();
}

fn emitAvatarWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = componentControlVisualTokens(widget, tokens);
    const radius = componentPillRadius(widget, visual, widget.frame.height * 0.5);
    const background = widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_subtle);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = colorFill(background),
    });

    if (widget.image_id != 0) {
        try builder.pushClip(.{
            .id = widgetPartId(widget.id, 2),
            .rect = widget.frame,
            .radius = radius,
        });
        try builder.drawImage(.{
            .id = widgetPartId(widget.id, 3),
            .image_id = widget.image_id,
            .src = widget.image_src,
            .dst = widget.frame,
            .opacity = widget.image_opacity,
            .fit = widget.image_fit,
            .sampling = widget.image_sampling,
        });
        try builder.popClip();
    } else if (widget.text.len > 0) {
        const text_size = widgetLabelTextSize(widget, tokens);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, centeredTextOrigin(widget.frame, widget.text, text_size)),
            .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted),
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, 0, .center, .none),
        });
    }

    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 4),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
}

fn emitBadgeWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = componentControlVisualTokens(widget, tokens);
    const radius = componentPillRadius(widget, visual, widget.frame.height * 0.5);
    const text_size = widgetLabelTextSize(widget, tokens);
    const text_inset = widgetControlInset(widget, tokens, tokens.spacing.sm);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = colorFill(badgeBackgroundColor(widget, tokens, visual)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, badgeBorderColor(widget, tokens, visual)),
            .width = badgeStrokeWidth(widget, tokens, visual),
        },
    });
    if (widget.text.len > 0) {
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
            .color = badgeTextColor(widget, tokens, visual),
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .center, .none),
        });
    }
}

fn emitSeparatorWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = componentControlVisualTokens(widget, tokens);
    const normalized = widget.frame.normalized();
    if (normalized.isEmpty()) return;
    const thickness = controlStrokeWidth(widget, visual, tokens.stroke.hairline);
    const line_rect = if (normalized.width >= normalized.height)
        geometry.RectF.init(normalized.x, normalized.y + (normalized.height - thickness) * 0.5, normalized.width, thickness)
    else
        geometry.RectF.init(normalized.x + (normalized.width - thickness) * 0.5, normalized.y, thickness, normalized.height);
    try builder.fillRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = pixelSnapGeometryRect(tokens, line_rect),
        .fill = colorFill(widgetBackgroundColor(widget, visual.background orelse visual.border orelse tokens.colors.border)),
    });
}

fn emitStatusBarWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const frame = widget.frame.normalized();
    if (frame.isEmpty()) return;

    try builder.fillRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = pixelSnapGeometryRect(tokens, frame),
        .fill = colorFill(widgetBackgroundColor(widget, tokens.colors.surface)),
    });

    const separator_height = @max(tokens.stroke.hairline, widget.style.stroke_width orelse tokens.stroke.hairline);
    try builder.fillRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(frame.x, frame.y, frame.width, separator_height)),
        .fill = widgetBorderFill(widget, tokens.colors.border),
    });

    if (widget.text.len == 0) return;

    const text_size = widgetBodyTextSize(widget, tokens);
    const padding = widgetStatusBarPadding(widget);
    const content = frame.inset(padding).normalized();
    if (content.isEmpty()) return;
    const line_height = text_size * 1.25;
    const text_frame = geometry.RectF.init(
        content.x,
        frame.y + @max(0, (frame.height - line_height) * 0.5),
        content.width,
        @min(content.height, line_height),
    );
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, textOrigin(text_frame, text_size, 0)),
        .color = widgetForegroundColor(widget, tokens, tokens.colors.text),
        .text = widget.text,
        .text_layout = .{
            .max_width = text_frame.width,
            .line_height = line_height,
            .wrap = .none,
            .alignment = widget.text_alignment,
        },
    });
}

fn widgetStatusBarPadding(widget: Widget) geometry.InsetsF {
    const padding = widget.layout.padding;
    if (padding.top == 0 and padding.right == 0 and padding.bottom == 0 and padding.left == 0) {
        return geometry.InsetsF.symmetric(7, 14);
    }
    return padding;
}

fn emitSkeletonWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = componentControlVisualTokens(widget, tokens);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = controlRadius(widget, visual, tokens.radius.md),
        .fill = colorFill(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_subtle)),
    });
}

fn emitSpinnerWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = componentControlVisualTokens(widget, tokens);
    const normalized = widget.frame.normalized();
    if (normalized.isEmpty()) return;
    const size = @min(normalized.width, normalized.height);
    if (size <= 0) return;

    const center = geometry.PointF.init(normalized.x + normalized.width * 0.5, normalized.y + normalized.height * 0.5);
    const radius = size * 0.42;
    const inner = radius * 0.58;
    const stroke_width = controlStrokeWidth(widget, visual, @max(1, size * 0.09));
    const color = widgetForegroundColor(widget, tokens, visual.foreground orelse visual.active_background orelse tokens.colors.accent);
    const phase = @as(usize, @intFromFloat(@floor(std.math.clamp(widget.value, 0, 1) * 8))) % spinner_segments.len;

    for (spinner_segments, 0..) |segment, index| {
        const segment_index = (index + phase) % spinner_segments.len;
        const alpha = 0.28 + @as(f32, @floatFromInt(segment_index)) * 0.09;
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, @as(ObjectId, @intCast(index + 1))),
            .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x + segment.x * inner, center.y + segment.y * inner)),
            .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x + segment.x * radius, center.y + segment.y * radius)),
            .stroke = .{
                .fill = colorFill(colorWithAlpha(color, alpha)),
                .width = stroke_width,
            },
        });
    }
}

fn emitButtonWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = buttonControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetButtonTextSize(widget, tokens);
    const text_inset = widgetButtonInset(widget, tokens);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = buttonFill(widget, tokens),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = buttonBorderFill(widget, tokens),
            .width = buttonStrokeWidth(widget, tokens),
        },
    });
    if (widget.state.focused) {
        try builder.strokeRect(.{
            .id = widgetPartId(widget.id, 3),
            .rect = widget.frame,
            .radius = radius,
            .stroke = .{
                .fill = widgetFocusRingFill(widget, tokens),
                .width = tokens.stroke.focus,
            },
        });
    }
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 4),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
        .color = buttonTextColorForWidget(widget, tokens),
        .text = widget.text,
        .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .center, .none),
    });
}

fn emitIconButtonWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = buttonControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = buttonFill(widget, tokens),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else buttonBorderFill(widget, tokens),
            .width = if (widget.state.focused) tokens.stroke.focus else buttonStrokeWidth(widget, tokens),
        },
    });
    if (widget.text.len > 0) {
        const size = iconGlyphSize(widget, tokens);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = size,
            .origin = pixelSnapTextPoint(tokens, centeredTextOrigin(widget.frame, widget.text, size)),
            .color = buttonTextColorForWidget(widget, tokens),
            .text = widget.text,
        });
    }
}

fn emitSelectWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = selectControlVisualTokens(tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const chevron_size = @max(widgetSizedDensityValue(widget, tokens, 8), text_size - 4);
    const chevron_extent = chevron_size + inset;
    const text_frame = geometry.RectF.init(
        widget.frame.x + inset,
        widget.frame.y,
        @max(1, widget.frame.width - inset * 2 - chevron_extent),
        widget.frame.height,
    );
    const placeholder = widgetPlaceholder(widget);
    const visible_text = if (widget.text.len > 0) widget.text else placeholder;
    const is_placeholder = widget.text.len == 0 and placeholder.len > 0;

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    if (visible_text.len > 0) {
        const text_color = if (is_placeholder)
            widgetForegroundColor(widget, tokens, tokens.colors.text_muted)
        else
            widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(text_frame, text_size, 0)),
            .color = text_color,
            .text = visible_text,
            .text_layout = boundedTextLayout(text_frame, text_size, 0, .start, .none),
        });
    }
    try emitSelectChevron(builder, widget, tokens, visual, inset, chevron_size);
}

fn emitSelectChevron(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens, inset: f32, chevron_size: f32) Error!void {
    const center = geometry.PointF.init(widget.frame.x + widget.frame.width - inset - chevron_size * 0.5, widget.frame.y + widget.frame.height * 0.5);
    const half = chevron_size * 0.36;
    const drop = chevron_size * 0.28;
    const left = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x - half, center.y - drop * 0.5));
    const mid = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x, center.y + drop * 0.5));
    const right = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x + half, center.y - drop * 0.5));
    const stroke = Stroke{
        .fill = colorFill(widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted)),
        .width = tokens.stroke.regular,
    };
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 4), .from = left, .to = mid, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 5), .from = mid, .to = right, .stroke = stroke });
}

fn emitTextFieldWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = textInputControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const clip_rect = widgetTextInputClipRect(widget, tokens, text_size, text_inset, layout_options);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const text_color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, text_color, layout_options);
    const selection_range = widgetTextSelectionRange(widget);
    const composition_range = widgetTextCompositionRange(widget);
    const has_text_affordances = selection_range != null or composition_range != null;
    const clips_text = widget.kind == .textarea;

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = textInputFill(widget, tokens, visual),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else textInputBorderFill(widget, visual, tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    if (clips_text) try builder.pushClip(.{ .id = widgetPartId(widget.id, 16), .rect = clip_rect, .radius = radius });
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectionRects(builder, widget, draw_text, layout_options, range, 3, 13, max_widget_text_range_rects, tokens);
        }
    }
    const placeholder = widgetPlaceholder(widget);
    const visible_text = if (widget.text.len > 0) widget.text else placeholder;
    if (visible_text.len > 0) {
        var command = draw_text;
        command.id = widgetPartId(widget.id, if (has_text_affordances) 4 else 3);
        command.text = visible_text;
        if (widget.text.len == 0) {
            command.color = widgetForegroundColor(widget, tokens, tokens.colors.text_muted);
        }
        try builder.drawText(command);
    }
    if (composition_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextCompositionLines(builder, widget, draw_text, layout_options, range, 5, 10, max_widget_text_range_rects, tokens);
        }
    }
    if (widget.state.focused) {
        if (selection_range) |range| {
            if (range.isCollapsed(widget.text.len)) {
                try emitWidgetTextCaret(builder, widget, draw_text, layout_options, range.start, 6, tokens);
            }
        }
    }
    if (clips_text) try builder.popClip();
}

fn emitSearchFieldWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = textInputControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetTextInputSize(widget, tokens);
    const icon_size = @max(8, text_size - 2);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const selection_range = widgetTextSelectionRange(widget);
    const composition_range = widgetTextCompositionRange(widget);
    const text_color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, text_color, layout_options);

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = textInputFill(widget, tokens, visual),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else textInputBorderFill(widget, visual, tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    try emitSearchFieldIcon(builder, widget, tokens, icon_size);
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectionRects(builder, widget, draw_text, layout_options, range, 8, 0, 1, tokens);
        }
    }
    const placeholder = widgetPlaceholder(widget);
    const visible_text = if (widget.text.len > 0) widget.text else placeholder;
    if (visible_text.len > 0) {
        var command = draw_text;
        command.id = widgetPartId(widget.id, 9);
        command.text = visible_text;
        command.color = if (widget.text.len > 0) text_color else widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted);
        try builder.drawText(command);
    }
    if (composition_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextCompositionLines(builder, widget, draw_text, layout_options, range, 10, 0, 1, tokens);
        }
    }
    if (widget.state.focused) {
        if (selection_range) |range| {
            if (range.isCollapsed(widget.text.len)) {
                try emitWidgetTextCaret(builder, widget, draw_text, layout_options, range.start, 11, tokens);
            }
        }
    }
    if (widget.kind == .combobox) {
        try emitComboboxChevron(builder, widget, tokens, visual, text_size);
    }
}

fn emitComboboxChevron(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens, text_size: f32) Error!void {
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const chevron_size = @max(widgetSizedDensityValue(widget, tokens, 8), text_size - 4);
    const center = geometry.PointF.init(widget.frame.x + widget.frame.width - inset - chevron_size * 0.5, widget.frame.y + widget.frame.height * 0.5);
    const half = chevron_size * 0.36;
    const drop = chevron_size * 0.28;
    const left = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x - half, center.y - drop * 0.5));
    const mid = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x, center.y + drop * 0.5));
    const right = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x + half, center.y - drop * 0.5));
    const stroke = Stroke{
        .fill = colorFill(widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted)),
        .width = tokens.stroke.regular,
    };
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 12), .from = left, .to = mid, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 13), .from = mid, .to = right, .stroke = stroke });
}

fn emitSearchFieldIcon(builder: *Builder, widget: Widget, tokens: DesignTokens, icon_size: f32) Error!void {
    const left = widget.frame.x + widgetControlInset(widget, tokens, tokens.spacing.md);
    const top = widget.frame.y + @max(0, (widget.frame.height - icon_size) * 0.5);
    const box = icon_size * 0.58;
    const p0 = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left, top));
    const p1 = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left + box, top));
    const p2 = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left + box, top + box));
    const p3 = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left, top + box));
    const tail = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left + icon_size, top + icon_size));
    const visual = textInputControlVisualTokens(widget, tokens);
    const stroke = Stroke{ .fill = colorFill(widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted)), .width = tokens.stroke.regular };

    try builder.drawLine(.{ .id = widgetPartId(widget.id, 3), .from = p0, .to = p1, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 4), .from = p1, .to = p2, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 5), .from = p2, .to = p3, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 6), .from = p3, .to = p0, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 7), .from = p2, .to = tail, .stroke = stroke });
}

fn emitTooltipWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = surfaceControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const shadow_token = tokens.shadow.sm;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = widgetAccentFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.accent)),
    });
    if (widget.text.len > 0) {
        const text_size = widgetLabelTextSize(widget, tokens);
        const text_inset = widgetControlInset(widget, tokens, tokens.spacing.sm);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
            .color = widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text),
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .start, .none),
        });
    }
}

fn emitMenuItemWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitListItemWidget(builder, widget, tokens);
}

fn emitListItemWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = listItemControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const fill = listItemFillColor(widget, tokens, widget.state);
    if (fill.a > 0) {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .fill = widgetBackgroundFill(widget, fill),
        });
    }
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 2);
    const text_size = widgetBodyTextSize(widget, tokens);
    const text_inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
        .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .text = widget.text,
        .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .start, .none),
    });
}

fn emitDataCellWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = listItemControlVisualTokens(widget, tokens);
    const state_fill = listItemFillColor(widget, tokens, widget.state);
    if (state_fill.a > 0) {
        try builder.fillRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .fill = widgetBackgroundFill(widget, state_fill),
        });
    }
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 3);
    if (widget.text.len > 0) {
        const text_size = widgetBodyTextSize(widget, tokens);
        const text_inset = widgetControlInset(widget, tokens, tokens.spacing.md);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 4),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
            .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .start, .none),
        });
    }
}

fn emitSegmentedControlWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const selected = widget.state.selected or widget.value >= 0.5;
    const visual = selectionControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetLabelTextSize(widget, tokens);
    const text_inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = if (selected)
            colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent))
        else
            colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
        .color = if (selected) widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text) else widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .text = widget.text,
        .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .center, .none),
    });
}

fn emitCheckboxWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = selectionControlVisualTokens(widget, tokens);
    const box = checkboxWidgetBoxRect(widget, tokens);
    const selected = booleanControlSelected(widget);
    const radius = controlRadius(widget, visual, tokens.radius.sm);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = box,
        .radius = radius,
        .fill = if (selected)
            colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent))
        else
            colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = box,
        .radius = radius,
        .stroke = .{
            .fill = if (selected) widgetAccentFill(widget, visual.border orelse visual.active_background orelse tokens.colors.accent) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 3, box, radius);
    if (selected) {
        const left = pixelSnapGeometryPoint(tokens, geometry.PointF.init(box.x + box.width * 0.26, box.y + box.height * 0.54));
        const mid = pixelSnapGeometryPoint(tokens, geometry.PointF.init(box.x + box.width * 0.43, box.y + box.height * 0.70));
        const right = pixelSnapGeometryPoint(tokens, geometry.PointF.init(box.x + box.width * 0.76, box.y + box.height * 0.32));
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, 4),
            .from = left,
            .to = mid,
            .stroke = .{ .fill = colorFill(widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text)), .width = 2 },
        });
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, 5),
            .from = mid,
            .to = right,
            .stroke = .{ .fill = colorFill(widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text)), .width = 2 },
        });
    }
    try emitControlLabelWithColor(builder, widget, tokens, box.x + box.width + widgetControlInset(widget, tokens, tokens.spacing.sm), 6, visual.foreground orelse tokens.colors.text);
}

fn emitRadioWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = selectionControlVisualTokens(widget, tokens);
    const circle = radioWidgetCircleRect(widget, tokens);
    const selected = booleanControlSelected(widget);
    const radius = controlRadius(widget, visual, circle.height * 0.5);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = circle,
        .radius = radius,
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = circle,
        .radius = radius,
        .stroke = .{
            .fill = if (selected) widgetAccentFill(widget, visual.border orelse visual.active_background orelse tokens.colors.accent) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 3, circle, radius);
    if (selected) {
        const dot_size = @max(0, circle.height * 0.48);
        const dot = pixelSnapGeometryRect(tokens, geometry.RectF.init(
            circle.x + (circle.width - dot_size) * 0.5,
            circle.y + (circle.height - dot_size) * 0.5,
            dot_size,
            dot_size,
        ));
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 4),
            .rect = dot,
            .radius = Radius.all(dot.height * 0.5),
            .fill = colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent)),
        });
    }
    try emitControlLabelWithColor(builder, widget, tokens, circle.x + circle.width + widgetControlInset(widget, tokens, tokens.spacing.sm), 5, visual.foreground orelse tokens.colors.text);
}

fn emitToggleWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const selected = booleanControlSelected(widget);
    const visual = selectionControlVisualTokens(widget, tokens);
    const knob_inset = widgetSizedDensityValue(widget, tokens, 2);
    const track = toggleWidgetTrackRect(widget, tokens);
    const track_radius = controlRadius(widget, visual, track.height * 0.5);
    const knob_size = @max(0, track.height - knob_inset * 2);
    const knob_x = if (selected)
        track.x + track.width - knob_size - knob_inset
    else
        track.x + knob_inset;
    const knob = pixelSnapGeometryRect(tokens, geometry.RectF.init(knob_x, track.y + knob_inset, knob_size, knob_size));

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = track,
        .radius = track_radius,
        .fill = if (selected)
            colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent))
        else
            colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface_pressed))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = track,
        .radius = track_radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = knob,
        .radius = controlRadius(widget, visual, knob.height * 0.5),
        .fill = colorFill(if (selected) widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text) else widgetBackgroundColor(widget, visual.foreground orelse tokens.colors.surface)),
    });
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 4, track, track_radius);
    try emitControlLabelWithColor(builder, widget, tokens, track.x + track.width + widgetControlInset(widget, tokens, tokens.spacing.sm), 5, visual.foreground orelse tokens.colors.text);
}

fn emitSliderWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const value = std.math.clamp(widget.value, 0, 1);
    const visual = selectionControlVisualTokens(widget, tokens);
    const track = sliderWidgetTrackRect(widget, tokens);
    const active = pixelSnapGeometryRect(tokens, geometry.RectF.init(track.x, track.y, track.width * value, track.height));
    const knob = sliderWidgetKnobRect(widget, tokens);
    const track_radius = controlRadius(widget, visual, track.height * 0.5);
    const knob_radius = controlRadius(widget, visual, knob.height * 0.5);

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = track,
        .radius = track_radius,
        .fill = colorFill(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_pressed)),
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = active,
        .radius = track_radius,
        .fill = colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent)),
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = knob,
        .radius = knob_radius,
        .fill = colorFill(if (widget.state.disabled) tokens.colors.disabled else widgetBackgroundColor(widget, visual.foreground orelse tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 4),
        .rect = knob,
        .radius = knob_radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
}

fn checkboxWidgetBoxRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const box_size = @min(@max(widgetSizedDensityValue(widget, tokens, 14), widget.frame.height * 0.55), widgetSizedDensityValue(widget, tokens, 20));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - box_size) * 0.5,
        box_size,
        box_size,
    ));
}

fn radioWidgetCircleRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const circle_size = @min(@max(widgetSizedDensityValue(widget, tokens, 14), widget.frame.height * 0.55), widgetSizedDensityValue(widget, tokens, 20));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - circle_size) * 0.5,
        circle_size,
        circle_size,
    ));
}

fn toggleWidgetTrackRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const track_width = @min(widget.frame.width, @max(widgetSizedDensityValue(widget, tokens, 36), widget.frame.height * 1.75));
    const track_height = @min(widget.frame.height, widgetSizedDensityValue(widget, tokens, 24));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        track_width,
        track_height,
    ));
}

fn sliderWidgetTrackRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const track_height: f32 = widgetSizedDensityValue(widget, tokens, 4);
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        widget.frame.width,
        track_height,
    ));
}

fn sliderWidgetKnobRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const value = std.math.clamp(widget.value, 0, 1);
    const knob_size = @min(@max(widgetSizedDensityValue(widget, tokens, 14), widget.frame.height * 0.55), widgetSizedDensityValue(widget, tokens, 20));
    const knob_x = std.math.clamp(
        widget.frame.x + widget.frame.width * value - knob_size * 0.5,
        widget.frame.x,
        widget.frame.x + @max(0, widget.frame.width - knob_size),
    );
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        knob_x,
        widget.frame.y + (widget.frame.height - knob_size) * 0.5,
        knob_size,
        knob_size,
    ));
}

fn emitProgressWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const progress = std.math.clamp(widget.value, 0, 1);
    const visual = selectionControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, @min(tokens.radius.md, widget.frame.height * 0.5));
    if (progress < 1) {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .fill = colorFill(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_pressed)),
        });
    }
    if (progress > 0) {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 2),
            .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(widget.frame.x, widget.frame.y, widget.frame.width * progress, widget.frame.height)),
            .radius = radius,
            .fill = colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent)),
        });
    }
}

fn emitWidgetFocusRing(builder: *Builder, widget: Widget, tokens: DesignTokens, slot: ObjectId) Error!void {
    return emitWidgetFocusRingForRect(builder, widget, tokens, slot, widget.frame, widgetRadius(widget, tokens.radius.md));
}

fn emitWidgetFocusRingForRect(builder: *Builder, widget: Widget, tokens: DesignTokens, slot: ObjectId, rect: geometry.RectF, radius: Radius) Error!void {
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, slot),
        .rect = rect,
        .radius = radius,
        .stroke = .{
            .fill = widgetFocusRingFill(widget, tokens),
            .width = tokens.stroke.focus,
        },
    });
}

fn emitControlLabel(builder: *Builder, widget: Widget, tokens: DesignTokens, x: f32, slot: ObjectId) Error!void {
    return emitControlLabelWithColor(builder, widget, tokens, x, slot, tokens.colors.text);
}

fn emitControlLabelWithColor(builder: *Builder, widget: Widget, tokens: DesignTokens, x: f32, slot: ObjectId, color: Color) Error!void {
    if (widget.text.len == 0) return;
    const text_size = widgetLabelTextSize(widget, tokens);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, slot),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(labelFrameForControl(widget.frame, x), text_size, 0)),
        .color = widgetForegroundColor(widget, tokens, color),
        .text = widget.text,
        .text_layout = boundedTextLayout(labelFrameForControl(widget.frame, x), text_size, 0, .start, .none),
    });
}

fn booleanControlSelected(widget: Widget) bool {
    return widget.state.selected or widget.value >= 0.5;
}

pub fn toggleWidgetKnobCommandId(id: ObjectId) ObjectId {
    return widgetPartId(id, 3);
}

pub fn toggleWidgetKnobTravel(widget: Widget, tokens: DesignTokens) f32 {
    if (!widgetSwitchControlKind(widget.kind)) return 0;
    const knob_inset = densityValue(tokens, 2);
    const track_width = @min(widget.frame.width, @max(densityValue(tokens, 36), widget.frame.height * 1.75));
    const track_height = @min(widget.frame.height, densityValue(tokens, 24));
    const track = pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        track_width,
        track_height,
    ));
    const knob_size = @max(0, track.height - knob_inset * 2);
    const off_knob = pixelSnapGeometryRect(tokens, geometry.RectF.init(track.x + knob_inset, track.y + knob_inset, knob_size, knob_size));
    const on_knob = pixelSnapGeometryRect(tokens, geometry.RectF.init(
        track.x + track.width - knob_size - knob_inset,
        track.y + knob_inset,
        knob_size,
        knob_size,
    ));
    return on_knob.x - off_knob.x;
}

fn widgetSwitchControlKind(kind: WidgetKind) bool {
    return kind == .switch_control or kind == .toggle;
}

pub fn widgetPartId(id: ObjectId, slot: ObjectId) ObjectId {
    if (id == 0) return 0;
    const base = id *% 16;
    const part = base +% slot;
    return if (part == 0) id else part;
}

fn textOrigin(frame: geometry.RectF, size: f32, inset: f32) geometry.PointF {
    const line_height = size * 1.25;
    return geometry.PointF.init(
        frame.x + inset,
        frame.y + @max(size, (frame.height - line_height) * 0.5 + size),
    );
}

fn boundedTextOrigin(frame: geometry.RectF, size: f32, inset: f32) geometry.PointF {
    return geometry.PointF.init(frame.x + inset, textOrigin(frame, size, 0).y);
}

fn boundedTextLayout(frame: geometry.RectF, size: f32, inset: f32, alignment: TextAlign, wrap: TextWrap) TextLayoutOptions {
    return .{
        .max_width = @max(1, frame.width - inset * 2),
        .line_height = size * 1.25,
        .wrap = wrap,
        .alignment = alignment,
    };
}

fn labelFrameForControl(frame: geometry.RectF, x: f32) geometry.RectF {
    return geometry.RectF.init(x, frame.y, @max(1, frame.x + frame.width - x), frame.height);
}

fn centeredTextOrigin(frame: geometry.RectF, text: []const u8, size: f32) geometry.PointF {
    return alignedTextOrigin(frame, text, size, 0, .center);
}

fn alignedTextOrigin(frame: geometry.RectF, text: []const u8, size: f32, inset: f32, alignment: TextAlign) geometry.PointF {
    const width = estimateTextWidth(text, size);
    const available_width = @max(0, frame.width - inset * 2);
    const offset = switch (alignment) {
        .start => 0,
        .center => @max(0, (available_width - width) * 0.5),
        .end => @max(0, available_width - width),
    };
    const line_height = size * 1.25;
    return geometry.PointF.init(
        frame.x + inset + offset,
        frame.y + @max(size, (frame.height - line_height) * 0.5 + size),
    );
}

fn iconGlyphSize(widget: Widget, tokens: DesignTokens) f32 {
    const min_size = widgetSizedDensityValue(widget, tokens, 12);
    if (widget.frame.height > 0) return @min(@max(min_size, widget.frame.height * widgetIconGlyphScale(widget)), @max(min_size, widgetTypographySize(widget, tokens.typography.title_size)));
    return widgetButtonTextSize(widget, tokens);
}

fn widgetIconGlyphScale(widget: Widget) f32 {
    return switch (widget.size) {
        .sm => 0.44,
        .default, .icon => 0.48,
        .lg => 0.52,
    };
}

fn widgetTextSelectionRange(widget: Widget) ?TextRange {
    if (!widgetTextInputKind(widget.kind)) return null;
    if (widget.text_selection) |selection| return snapTextRange(widget.text, selection.range(widget.text.len));
    return null;
}

fn widgetTextCompositionRange(widget: Widget) ?TextRange {
    if (!widgetTextInputKind(widget.kind)) return null;
    if (widget.text_composition) |range| return snapTextRange(widget.text, range);
    return null;
}

fn widgetTextInputKind(kind: WidgetKind) bool {
    return switch (kind) {
        .input, .text_field, .search_field, .combobox, .textarea => true,
        else => false,
    };
}

fn widgetPlaceholder(widget: Widget) []const u8 {
    if (widget.placeholder.len > 0) return widget.placeholder;
    return switch (widget.kind) {
        .select, .search_field, .combobox => widget.semantics.label,
        else => "",
    };
}

pub fn textSelectionForWidgetPoint(widget: Widget, point: geometry.PointF, anchor: ?usize, tokens: DesignTokens) ?TextSelection {
    const offset = textOffsetForWidgetPoint(widget, point, tokens) orelse return null;
    const selection = if (anchor) |anchor_offset|
        TextSelection{ .anchor = anchor_offset, .focus = offset }
    else
        TextSelection.collapsed(offset);
    return snapTextSelection(widget.text, selection);
}

pub fn textOffsetForWidgetPoint(widget: Widget, point: geometry.PointF, tokens: DesignTokens) ?usize {
    if (!widgetTextInputKind(widget.kind)) return null;
    if (widget.state.disabled) return null;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, tokens.colors.text, layout_options);
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    return layoutTextOffsetForPoint(draw_text, layout_options, point, &lines) catch null;
}

fn widgetButtonTextSize(widget: Widget, tokens: DesignTokens) f32 {
    return widgetTypographySize(widget, tokens.typography.button_size);
}

fn widgetBodyTextSize(widget: Widget, tokens: DesignTokens) f32 {
    return widgetTypographySize(widget, tokens.typography.body_size);
}

fn widgetLabelTextSize(widget: Widget, tokens: DesignTokens) f32 {
    return widgetTypographySize(widget, tokens.typography.label_size);
}

fn widgetTextInputSize(widget: Widget, tokens: DesignTokens) f32 {
    return widgetBodyTextSize(widget, tokens);
}

fn widgetTypographySize(widget: Widget, base: f32) f32 {
    return switch (widget.size) {
        .sm => @max(8, base - 1),
        .default, .icon => base,
        .lg => base + 1,
    };
}

fn widgetTextInputLayoutOptions(widget: Widget, text_size: f32, inset: f32) TextLayoutOptions {
    const line_height = widgetTextInputLineHeight(text_size);
    const trailing_inset = widgetTextInputTrailingInset(widget, text_size, inset);
    return .{
        .max_width = @max(1, widget.frame.width - inset - trailing_inset),
        .line_height = line_height,
        .wrap = widgetTextInputWrap(widget, line_height),
    };
}

fn widgetTextInputLineHeight(text_size: f32) f32 {
    return widgetLineHeight(text_size);
}

fn widgetTextInputWrap(widget: Widget, line_height: f32) TextWrap {
    if (widget.kind == .textarea) return .word;
    if (widget.kind == .text_field and widget.frame.height >= line_height * 2.25) return .word;
    return .none;
}

fn widgetTextInputVerticalInset(widget: Widget, tokens: DesignTokens, text_size: f32, options: TextLayoutOptions) f32 {
    if (options.wrap != .none) return widgetControlInset(widget, tokens, tokens.spacing.sm);
    return @max(0, (widget.frame.height - widgetTextInputLineHeight(text_size)) * 0.5);
}

fn widgetTextInputScrollOffset(widget: Widget, tokens: DesignTokens, text_size: f32, text_inset: f32, options: TextLayoutOptions) f32 {
    if (widget.kind != .textarea) return 0;
    return std.math.clamp(widget.value, 0, widgetTextInputMaxScrollOffset(widget, tokens, text_size, text_inset, options));
}

fn widgetTextInputOrigin(widget: Widget, tokens: DesignTokens, text_size: f32, inset: f32, options: TextLayoutOptions) geometry.PointF {
    if (options.wrap != .none) {
        const scroll_offset = widgetTextInputScrollOffset(widget, tokens, text_size, inset, options);
        return geometry.PointF.init(
            widget.frame.x + inset,
            widget.frame.y + widgetTextInputVerticalInset(widget, tokens, text_size, options) + text_size - scroll_offset,
        );
    }
    return textOrigin(widget.frame, text_size, inset);
}

fn widgetTextInputClipRect(widget: Widget, tokens: DesignTokens, text_size: f32, inset: f32, options: TextLayoutOptions) geometry.RectF {
    const vertical_inset = widgetTextInputVerticalInset(widget, tokens, text_size, options);
    const trailing_inset = widgetTextInputTrailingInset(widget, text_size, inset);
    return widget.frame.normalized().deflate(.{
        .top = vertical_inset,
        .right = trailing_inset,
        .bottom = vertical_inset,
        .left = inset,
    });
}

pub fn textInputViewportForWidget(widget: Widget, tokens: DesignTokens) ?geometry.RectF {
    if (!widgetTextInputKind(widget.kind)) return null;
    if (widget.state.disabled) return null;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    return widgetTextInputClipRect(widget, tokens, text_size, text_inset, options);
}

pub fn textInputContentExtentForWidget(widget: Widget, tokens: DesignTokens) f32 {
    if (!widgetTextInputKind(widget.kind)) return 0;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const line_height = widgetTextInputLineHeight(text_size);
    return @as(f32, @floatFromInt(widgetTextInputLineCount(widget, tokens.typography.font_id, text_size, options))) * line_height;
}

pub fn textInputMaxScrollOffsetForWidget(widget: Widget, tokens: DesignTokens) f32 {
    if (!widgetTextInputKind(widget.kind)) return 0;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    return widgetTextInputMaxScrollOffset(widget, tokens, text_size, text_inset, options);
}

pub fn clampedTextInputScrollOffsetForWidget(widget: Widget, tokens: DesignTokens, offset: f32) f32 {
    if (!widgetTextInputKind(widget.kind)) return 0;
    return std.math.clamp(offset, 0, textInputMaxScrollOffsetForWidget(widget, tokens));
}

fn widgetTextInputMaxScrollOffset(widget: Widget, tokens: DesignTokens, text_size: f32, text_inset: f32, options: TextLayoutOptions) f32 {
    const viewport = widgetTextInputClipRect(widget, tokens, text_size, text_inset, options);
    return @max(0, textInputContentExtentForWidgetWithOptions(widget, tokens.typography.font_id, text_size, options) - viewport.height);
}

fn textInputContentExtentForWidgetWithOptions(widget: Widget, font_id: FontId, text_size: f32, options: TextLayoutOptions) f32 {
    return @as(f32, @floatFromInt(widgetTextInputLineCount(widget, font_id, text_size, options))) * widgetTextInputLineHeight(text_size);
}

fn widgetTextInputLineCount(widget: Widget, font_id: FontId, text_size: f32, options: TextLayoutOptions) usize {
    if (widget.text.len == 0) return 1;
    var count: usize = 0;
    var start: usize = 0;
    while (start <= widget.text.len) {
        const end = nextTextLineEnd(widget.text, start, font_id, text_size, options);
        count += 1;
        if (end >= widget.text.len) break;
        start = end;
        if (start < widget.text.len and widget.text[start] == '\n') start += 1;
        while (options.wrap == .word and start < widget.text.len and isTextBreakByte(widget.text[start])) start += 1;
    }
    return @max(1, count);
}

fn widgetTextInputDrawText(
    widget: Widget,
    tokens: DesignTokens,
    text_size: f32,
    origin: geometry.PointF,
    color: Color,
    options: TextLayoutOptions,
) DrawText {
    return .{
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, origin),
        .color = color,
        .text = widget.text,
        .text_layout = options,
    };
}

fn widgetTextInputInset(widget: Widget, tokens: DesignTokens) f32 {
    const text_size = widgetTextInputSize(widget, tokens);
    return switch (widget.kind) {
        .search_field, .combobox => widgetControlInset(widget, tokens, tokens.spacing.md) + @max(widgetSizedDensityValue(widget, tokens, 8), text_size - 2) + widgetControlInset(widget, tokens, tokens.spacing.sm),
        else => widgetControlInset(widget, tokens, tokens.spacing.md),
    };
}

fn widgetTextInputTrailingInset(widget: Widget, text_size: f32, inset: f32) f32 {
    if (widget.kind == .combobox) return inset + @max(8, text_size - 4);
    return inset;
}

fn widgetButtonInset(widget: Widget, tokens: DesignTokens) f32 {
    return switch (widget.size) {
        .icon => 0,
        else => widgetControlInset(widget, tokens, tokens.spacing.md),
    };
}

fn widgetControlInset(widget: Widget, tokens: DesignTokens, base: f32) f32 {
    return densityValue(tokens, widgetSizedTokenValue(widget, base));
}

fn widgetSizedDensityValue(widget: Widget, tokens: DesignTokens, value: f32) f32 {
    return densityValue(tokens, value) * widgetSizeScale(widget);
}

fn widgetSizedTokenValue(widget: Widget, value: f32) f32 {
    return switch (widget.size) {
        .sm => @max(0, value - 2),
        .default, .icon => value,
        .lg => value + 2,
    };
}

fn widgetSizeScale(widget: Widget) f32 {
    return switch (widget.size) {
        .sm => 0.875,
        .default, .icon => 1,
        .lg => 1.125,
    };
}

fn densityValue(tokens: DesignTokens, value: f32) f32 {
    return value * densityScale(tokens.density);
}

fn densityScale(density: Density) f32 {
    return switch (density) {
        .compact => 0.875,
        .regular => 1,
        .spacious => 1.125,
    };
}

fn textInputAffordanceColor(widget: Widget, tokens: DesignTokens) Color {
    const visual = textInputControlVisualTokens(widget, tokens);
    return widget.style.focus_ring orelse widget.style.accent orelse visual.active_background orelse tokens.colors.focus_ring;
}

pub fn textSelectionFillColor(widget: Widget, tokens: DesignTokens) Color {
    return colorWithAlpha(textInputAffordanceColor(widget, tokens), 0.18);
}

pub fn colorWithAlpha(color: Color, alpha: f32) Color {
    return Color.rgba(color.r, color.g, color.b, std.math.clamp(alpha, 0, 1));
}

fn colorFill(color: Color) Fill {
    return .{ .color = color };
}

fn widgetBackgroundFill(widget: Widget, fallback: Color) Fill {
    return colorFill(widget.style.background orelse fallback);
}

fn widgetAccentFill(widget: Widget, fallback: Color) Fill {
    return colorFill(widget.style.accent orelse fallback);
}

fn widgetBorderFill(widget: Widget, fallback: Color) Fill {
    return colorFill(widget.style.border orelse fallback);
}

fn widgetFocusRingFill(widget: Widget, tokens: DesignTokens) Fill {
    return colorFill(widget.style.focus_ring orelse tokens.colors.focus_ring);
}

fn widgetBackgroundColor(widget: Widget, fallback: Color) Color {
    return widget.style.background orelse fallback;
}

fn widgetAccentColor(widget: Widget, fallback: Color) Color {
    return widget.style.accent orelse fallback;
}

fn widgetBorderColor(widget: Widget, fallback: Color) Color {
    return widget.style.border orelse fallback;
}

fn widgetForegroundColor(widget: Widget, tokens: DesignTokens, fallback: Color) Color {
    if (widget.state.disabled) return tokens.colors.text_muted;
    return widget.style.foreground orelse fallback;
}

fn widgetAccentForegroundColor(widget: Widget, tokens: DesignTokens, fallback: Color) Color {
    if (widget.state.disabled) return tokens.colors.text_muted;
    return widget.style.accent_foreground orelse fallback;
}

fn widgetRadius(widget: Widget, fallback: f32) Radius {
    if (widget.style.radius) |radius| return Radius.all(nonNegative(radius));
    return Radius.all(nonNegative(widgetSizedRadiusValue(widget, fallback)));
}

fn controlRadius(widget: Widget, visual: ControlVisualTokens, fallback: f32) Radius {
    if (widget.style.radius) |radius| return Radius.all(nonNegative(radius));
    return Radius.all(nonNegative(widgetSizedRadiusValue(widget, visual.radius orelse fallback)));
}

fn widgetSizedRadiusValue(widget: Widget, fallback: f32) f32 {
    return switch (widget.size) {
        .sm => @max(0, fallback - 2),
        .default, .icon => fallback,
        .lg => fallback + 2,
    };
}

fn widgetStrokeWidth(widget: Widget, fallback: f32) f32 {
    return nonNegative(widget.style.stroke_width orelse fallback);
}

fn controlStrokeWidth(widget: Widget, visual: ControlVisualTokens, fallback: f32) f32 {
    return nonNegative(widget.style.stroke_width orelse visual.stroke_width orelse fallback);
}

fn emitWidgetTextSelectionRects(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    first_part: ObjectId,
    overflow_first_part: ObjectId,
    max_parts: usize,
    tokens: DesignTokens,
) Error!void {
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    var rect_buffer: [max_widget_text_range_rects]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, range, &lines, rect_buffer[0..@min(max_parts, rect_buffer.len)]);
    for (rects, 0..) |selection, index| {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, widgetTextRangePart(first_part, overflow_first_part, index)),
            .rect = pixelSnapGeometryRect(tokens, selection.rect),
            .radius = Radius.all(tokens.radius.sm),
            .fill = .{ .color = textSelectionFillColor(widget, tokens) },
        });
    }
}

fn emitWidgetTextCompositionLines(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    first_part: ObjectId,
    overflow_first_part: ObjectId,
    max_parts: usize,
    tokens: DesignTokens,
) Error!void {
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    var rect_buffer: [max_widget_text_range_rects]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, range, &lines, rect_buffer[0..@min(max_parts, rect_buffer.len)]);
    for (rects, 0..) |selection, index| {
        const y = pixelSnapGeometryRect(tokens, selection.rect).maxY() - tokens.stroke.regular;
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, widgetTextRangePart(first_part, overflow_first_part, index)),
            .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(selection.rect.x, y)),
            .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(selection.rect.x + selection.rect.width, y)),
            .stroke = .{ .fill = .{ .color = textInputAffordanceColor(widget, tokens) }, .width = 1 },
        });
    }
}

fn widgetTextRangePart(first_part: ObjectId, overflow_first_part: ObjectId, index: usize) ObjectId {
    if (index == 0 or overflow_first_part == 0) return first_part + @as(ObjectId, @intCast(index));
    return overflow_first_part + @as(ObjectId, @intCast(index - 1));
}

fn emitWidgetTextCaret(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    offset: usize,
    part: ObjectId,
    tokens: DesignTokens,
) Error!void {
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    const rect = (try layoutTextCaretRect(text, options, offset, &lines)) orelse return;
    const snapped = pixelSnapGeometryRect(tokens, rect);
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, part),
        .from = geometry.PointF.init(snapped.x, snapped.y),
        .to = geometry.PointF.init(snapped.x, snapped.y + snapped.height),
        .stroke = .{ .fill = .{ .color = textInputAffordanceColor(widget, tokens) }, .width = tokens.stroke.regular },
    });
}

fn buttonFill(widget: Widget, tokens: DesignTokens) Fill {
    if (widget.state.disabled) return colorFill(tokens.colors.disabled);
    const active = widget.state.pressed or widget.state.selected;
    const visual = buttonControlVisualTokens(widget, tokens);
    return switch (widget.variant) {
        .default => if (active)
            colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent))
        else if (widget.state.hovered)
            colorFill(widgetBackgroundColor(widget, visual.hover_background orelse tokens.colors.surface_subtle))
        else
            colorFill(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface)),
        .primary => colorFill(widgetAccentColor(widget, buttonStateBackground(visual, active, widget.state.hovered, tokens.colors.accent))),
        .secondary => colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, active, widget.state.hovered, if (active or widget.state.hovered) tokens.colors.surface_pressed else tokens.colors.surface_subtle))),
        .outline => colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, active, widget.state.hovered, if (active or widget.state.hovered) tokens.colors.surface_subtle else transparentColor()))),
        .ghost => colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, active, widget.state.hovered, if (active or widget.state.hovered) tokens.colors.surface_subtle else transparentColor()))),
        .destructive => colorFill(widgetAccentColor(widget, buttonStateBackground(visual, active, widget.state.hovered, tokens.colors.destructive))),
    };
}

fn buttonTextColorForWidget(widget: Widget, tokens: DesignTokens) Color {
    if (widget.state.disabled) return tokens.colors.text_muted;
    const active = widget.state.pressed or widget.state.selected;
    const visual = buttonControlVisualTokens(widget, tokens);
    return switch (widget.variant) {
        .default => if (active)
            widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text)
        else
            widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .primary => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text),
        .secondary, .outline, .ghost => widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .destructive => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.destructive_text),
    };
}

fn buttonBorderFill(widget: Widget, tokens: DesignTokens) Fill {
    if (widget.style.border) |border| return colorFill(border);
    const visual = buttonControlVisualTokens(widget, tokens);
    return switch (widget.variant) {
        .primary => colorFill(widgetAccentColor(widget, visual.border orelse tokens.colors.accent)),
        .destructive => colorFill(widgetAccentColor(widget, visual.border orelse tokens.colors.destructive)),
        .ghost => colorFill(widgetBorderColor(widget, visual.border orelse transparentColor())),
        else => colorFill(widgetBorderColor(widget, visual.border orelse tokens.colors.border)),
    };
}

fn buttonControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    const variant = switch (widget.variant) {
        .default => tokens.controls.button_default,
        .primary => tokens.controls.button_primary,
        .secondary => tokens.controls.button_secondary,
        .outline => tokens.controls.button_outline,
        .ghost => tokens.controls.button_ghost,
        .destructive => tokens.controls.button_destructive,
    };
    if (widget.kind == .toggle_button) return controlVisualTokensWithFallback(tokens.controls.toggle_button, variant);
    return variant;
}

fn selectControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.select, tokens.controls.button_outline);
}

fn controlVisualTokensWithFallback(primary: ControlVisualTokens, fallback: ControlVisualTokens) ControlVisualTokens {
    return .{
        .background = primary.background orelse fallback.background,
        .hover_background = primary.hover_background orelse fallback.hover_background,
        .active_background = primary.active_background orelse fallback.active_background,
        .foreground = primary.foreground orelse fallback.foreground,
        .border = primary.border orelse fallback.border,
        .radius = primary.radius orelse fallback.radius,
        .stroke_width = primary.stroke_width orelse fallback.stroke_width,
    };
}

fn buttonStateBackground(visual: ControlVisualTokens, active: bool, hovered: bool, fallback: Color) Color {
    if (active) return visual.active_background orelse visual.hover_background orelse visual.background orelse fallback;
    if (hovered) return visual.hover_background orelse visual.background orelse fallback;
    return visual.background orelse fallback;
}

fn textInputControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .input => controlVisualTokensWithFallback(tokens.controls.input, tokens.controls.text_field),
        .search_field => tokens.controls.search_field,
        .combobox => controlVisualTokensWithFallback(tokens.controls.combobox, tokens.controls.search_field),
        .textarea => tokens.controls.textarea,
        else => tokens.controls.text_field,
    };
}

fn textInputFill(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Fill {
    if (widget.state.disabled) return colorFill(tokens.colors.disabled);
    return colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface)));
}

fn textInputBorderFill(widget: Widget, visual: ControlVisualTokens, fallback: Color) Fill {
    return colorFill(widgetBorderColor(widget, visual.border orelse fallback));
}

fn accordionControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.accordion, tokens.controls.panel);
}

fn alertControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.alert, tokens.controls.panel);
}

fn bubbleControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.bubble, tokens.controls.panel);
}

fn cardControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.card, tokens.controls.panel);
}

fn dialogControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.dialog, tokens.controls.popover);
}

fn drawerControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.drawer, tokens.controls.popover);
}

fn sheetControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.sheet, tokens.controls.popover);
}

fn listItemControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .data_cell => controlVisualTokensWithFallback(tokens.controls.data_cell, tokens.controls.list_item),
        .menu_item => controlVisualTokensWithFallback(tokens.controls.menu_item, tokens.controls.list_item),
        .list_item => tokens.controls.list_item,
        else => .{},
    };
}

fn selectionControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .segmented_control => tokens.controls.segmented_control,
        .checkbox => tokens.controls.checkbox,
        .radio => tokens.controls.radio,
        .switch_control, .toggle => tokens.controls.toggle,
        .slider => tokens.controls.slider,
        .progress => tokens.controls.progress,
        else => .{},
    };
}

fn surfaceControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .accordion => accordionControlVisualTokens(tokens),
        .alert => alertControlVisualTokens(tokens),
        .bubble => bubbleControlVisualTokens(tokens),
        .card => cardControlVisualTokens(tokens),
        .dialog => dialogControlVisualTokens(tokens),
        .drawer => drawerControlVisualTokens(tokens),
        .sheet => sheetControlVisualTokens(tokens),
        .panel => tokens.controls.panel,
        .resizable => resizableControlVisualTokens(tokens),
        .popover => tokens.controls.popover,
        .menu_surface => tokens.controls.menu_surface,
        .dropdown_menu => controlVisualTokensWithFallback(tokens.controls.dropdown_menu, tokens.controls.menu_surface),
        .tooltip => tokens.controls.tooltip,
        else => .{},
    };
}

fn resizableControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.resizable, tokens.controls.panel);
}

fn componentControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .avatar => tokens.controls.avatar,
        .badge => tokens.controls.badge,
        .separator => tokens.controls.separator,
        .skeleton => tokens.controls.skeleton,
        .spinner => tokens.controls.spinner,
        else => .{},
    };
}

fn componentPillRadius(widget: Widget, visual: ControlVisualTokens, fallback: f32) Radius {
    if (widget.style.radius) |radius| return Radius.all(nonNegative(radius));
    if (visual.radius) |radius| return Radius.all(nonNegative(radius));
    return Radius.all(nonNegative(fallback));
}

fn badgeBackgroundColor(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Color {
    if (widget.state.disabled) return tokens.colors.disabled;
    return switch (widget.variant) {
        .default, .primary => widgetAccentColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.accent)),
        .secondary => widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface_subtle)),
        .outline, .ghost => widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, if (widget.state.hovered or widget.state.pressed) tokens.colors.surface_subtle else transparentColor())),
        .destructive => widgetAccentColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.destructive)),
    };
}

fn badgeBorderColor(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Color {
    return switch (widget.variant) {
        .default, .primary => widgetAccentColor(widget, visual.border orelse tokens.colors.accent),
        .destructive => widgetAccentColor(widget, visual.border orelse tokens.colors.destructive),
        else => widgetBorderColor(widget, visual.border orelse tokens.colors.border),
    };
}

fn badgeTextColor(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Color {
    if (widget.state.disabled) return tokens.colors.text_muted;
    return switch (widget.variant) {
        .default, .primary => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text),
        .destructive => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.destructive_text),
        else => widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
    };
}

fn badgeStrokeWidth(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) f32 {
    if (widget.style.stroke_width) |width| return nonNegative(width);
    if (visual.stroke_width) |width| return nonNegative(width);
    return switch (widget.variant) {
        .ghost => 0,
        else => tokens.stroke.hairline,
    };
}

fn buttonStrokeWidth(widget: Widget, tokens: DesignTokens) f32 {
    if (widget.style.stroke_width) |width| return nonNegative(width);
    const visual = buttonControlVisualTokens(widget, tokens);
    if (visual.stroke_width) |width| return nonNegative(width);
    return switch (widget.variant) {
        .ghost => 0,
        else => tokens.stroke.regular,
    };
}

fn listItemFillColor(widget: Widget, tokens: DesignTokens, state: WidgetState) Color {
    const visual = listItemControlVisualTokens(widget, tokens);
    const fallback = if (state.selected or state.pressed)
        tokens.colors.surface_pressed
    else if (state.hovered)
        tokens.colors.surface_subtle
    else
        transparentColor();
    return buttonStateBackground(visual, state.selected or state.pressed, state.hovered, fallback);
}

pub fn transparentColor() Color {
    return Color.rgba(0, 0, 0, 0);
}

fn layoutWidgetDepth(
    widget: Widget,
    frame: geometry.RectF,
    parent_index: ?usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    tokens: DesignTokens,
) Error!usize {
    if (depth >= max_widget_depth) return error.WidgetDepthExceeded;
    if (len.* >= output.len) return error.WidgetLayoutListFull;

    const index = len.*;
    output[index] = .{
        .widget = widgetWithFrame(widget, frame),
        .frame = frame,
        .depth = depth,
        .parent_index = parent_index,
    };
    len.* += 1;

    const content = frame.inset(widget.layout.padding);
    switch (widget.kind) {
        .row, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, widget.layout, tokens),
        .column => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        .grid => if (widget.layout.virtualized)
            try layoutVirtualGridChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout, tokens)
        else
            try layoutGridChildren(widget.children, content, index, depth, output, len, widget.layout.gap, widget.layout.columns, tokens),
        .data_grid, .table => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout, tokens)
        else
            try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        .data_row => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, widget.layout, tokens),
        .scroll_view => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout, tokens)
        else
            try layoutScrollChildren(widget.children, content, index, depth, output, len, widget.value, tokens),
        .list => if (widget.layout.virtualized)
            try layoutVirtualVerticalChildren(widget.children, content, index, depth, output, len, widget.value, widget.layout, tokens)
        else
            try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        .menu_surface, .dropdown_menu => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout, tokens),
        .accordion => {
            if (accordionChildrenVisible(widget)) {
                const child_content = accordionContentFrame(widget, content, tokens);
                for (widget.children) |child| {
                    _ = try layoutWidgetDepth(child, stackChildFrame(child_content, child), index, depth + 1, output, len, tokens);
                }
            }
        },
        .stack, .alert, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover => {
            for (widget.children) |child| {
                _ = try layoutWidgetDepth(child, stackChildFrame(content, child), index, depth + 1, output, len, tokens);
            }
        },
        .text, .icon, .image, .avatar, .badge, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .tooltip, .menu_item, .list_item, .data_cell, .status_bar, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .progress, .separator, .skeleton, .spinner => {},
    }

    return index;
}

const LayoutAxis = enum {
    horizontal,
    vertical,
};

fn layoutAxisChildren(
    children: []const Widget,
    content: geometry.RectF,
    axis: LayoutAxis,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    style: WidgetLayoutStyle,
    tokens: DesignTokens,
) Error!void {
    if (children.len == 0) return;

    const available_extent = switch (axis) {
        .horizontal => content.width,
        .vertical => content.height,
    };
    const cross_extent = switch (axis) {
        .horizontal => content.height,
        .vertical => content.width,
    };
    const clamped_gap = nonNegative(style.gap);
    const total_gap = clamped_gap * @as(f32, @floatFromInt(children.len - 1));
    var fixed_extent: f32 = 0;
    var grow_total: f32 = 0;
    for (children) |child| {
        const grow = nonNegative(child.layout.grow);
        if (grow > 0) {
            grow_total += grow;
        } else {
            fixed_extent += preferredMainExtent(child, axis, tokens);
        }
    }

    const remaining = @max(0, available_extent - fixed_extent - total_gap);
    const assigned_extent = assignedAxisChildrenExtent(children, axis, fixed_extent, grow_total, remaining);
    const used_extent = assigned_extent + total_gap;
    const free_extent = @max(0, available_extent - used_extent);
    var child_gap = clamped_gap;
    if (style.main_alignment == .space_between and children.len > 1) {
        child_gap += free_extent / @as(f32, @floatFromInt(children.len - 1));
    }
    var cursor: f32 = switch (axis) {
        .horizontal => content.x,
        .vertical => content.y,
    } + mainAxisAlignmentOffset(style.main_alignment, free_extent);

    for (children) |child| {
        const grow = nonNegative(child.layout.grow);
        const main_extent = if (grow > 0 and grow_total > 0)
            @max(minMainExtent(child, axis), remaining * grow / grow_total)
        else
            preferredMainExtent(child, axis, tokens);
        const cross = preferredCrossExtent(child, axis, cross_extent, style.cross_alignment, tokens);
        const cross_origin = alignedCrossAxisOrigin(content, axis, cross_extent, cross, child, style.cross_alignment);
        const child_frame = switch (axis) {
            .horizontal => geometry.RectF.init(cursor, cross_origin, main_extent, cross),
            .vertical => geometry.RectF.init(cross_origin, cursor, cross, main_extent),
        };
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
        cursor += main_extent + child_gap;
    }
}

fn assignedAxisChildrenExtent(children: []const Widget, axis: LayoutAxis, fixed_extent: f32, grow_total: f32, remaining: f32) f32 {
    if (grow_total <= 0) return fixed_extent;
    var assigned = fixed_extent;
    for (children) |child| {
        const grow = nonNegative(child.layout.grow);
        if (grow <= 0) continue;
        assigned += @max(minMainExtent(child, axis), remaining * grow / grow_total);
    }
    return assigned;
}

fn mainAxisAlignmentOffset(alignment: WidgetMainAlignment, free_extent: f32) f32 {
    return switch (alignment) {
        .start, .space_between => 0,
        .center => free_extent * 0.5,
        .end => free_extent,
    };
}

fn alignedCrossAxisOrigin(
    content: geometry.RectF,
    axis: LayoutAxis,
    available_extent: f32,
    child_extent: f32,
    child: Widget,
    alignment: WidgetCrossAlignment,
) f32 {
    const start = switch (axis) {
        .horizontal => content.y,
        .vertical => content.x,
    };
    const offset = switch (axis) {
        .horizontal => child.frame.y,
        .vertical => child.frame.x,
    };
    const free_extent = @max(0, available_extent - child_extent);
    return start + offset + switch (alignment) {
        .stretch, .start => 0,
        .center => free_extent * 0.5,
        .end => free_extent,
    };
}

fn layoutGridChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    gap: f32,
    requested_columns: usize,
    tokens: DesignTokens,
) Error!void {
    if (children.len == 0) return;

    const columns = gridColumnCount(children.len, requested_columns);
    const rows = gridRowCount(children.len, columns);
    const clamped_gap = nonNegative(gap);
    const total_column_gap = clamped_gap * @as(f32, @floatFromInt(columns - 1));
    const total_row_gap = clamped_gap * @as(f32, @floatFromInt(rows - 1));
    const cell_width = if (columns > 0) @max(0, content.width - total_column_gap) / @as(f32, @floatFromInt(columns)) else 0;
    const fallback_cell_height = if (rows > 0) @max(0, content.height - total_row_gap) / @as(f32, @floatFromInt(rows)) else 0;

    for (children, 0..) |child, child_index| {
        const column = child_index % columns;
        const row = child_index / columns;
        const x = content.x + @as(f32, @floatFromInt(column)) * (cell_width + clamped_gap);
        const y = content.y + @as(f32, @floatFromInt(row)) * (fallback_cell_height + clamped_gap);
        const width = @max(child.layout.min_size.width, if (child.frame.width > 0) child.frame.width else cell_width);
        const height = @max(child.layout.min_size.height, if (child.frame.height > 0) child.frame.height else fallback_cell_height);
        const child_frame = geometry.RectF.init(
            x + child.frame.x,
            y + child.frame.y,
            width,
            height,
        );
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
    }
}

fn layoutVirtualGridChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    scroll_y: f32,
    style: WidgetLayoutStyle,
    tokens: DesignTokens,
) Error!void {
    if (children.len == 0) return;

    const columns = gridColumnCount(children.len, style.columns);
    const rows = gridRowCount(children.len, columns);
    if (columns == 0 or rows == 0) return;

    const clamped_gap = nonNegative(style.gap);
    const total_column_gap = clamped_gap * @as(f32, @floatFromInt(columns - 1));
    const cell_width = @max(0, content.width - total_column_gap) / @as(f32, @floatFromInt(columns));
    const item_extent = if (style.virtual_item_extent > 0)
        style.virtual_item_extent
    else
        preferredGridRowExtent(children, columns, tokens);
    const range = virtualListRange(.{
        .item_count = rows,
        .item_extent = item_extent,
        .item_gap = clamped_gap,
        .viewport_extent = content.height,
        .scroll_offset = scroll_y,
        .overscan = style.virtual_overscan,
    });
    output[parent_index].widget.layout.virtual_item_extent = range.item_extent;
    output[parent_index].widget.semantics.list_item_count = saturatingU32(rows);
    if (range.isEmpty()) return;

    const stride = range.item_extent + range.item_gap;
    var row = range.start_index;
    while (row < range.end_index) : (row += 1) {
        var column: usize = 0;
        while (column < columns) : (column += 1) {
            const child_index = row * columns + column;
            if (child_index >= children.len) break;

            var child = children[child_index];
            child.semantics.list_item_index = saturatingU32(child_index);
            child.semantics.list_item_count = saturatingU32(children.len);
            const x = content.x + @as(f32, @floatFromInt(column)) * (cell_width + clamped_gap);
            const y = content.y + @as(f32, @floatFromInt(row)) * stride - range.layout_offset + child.frame.y;
            const width = @max(child.layout.min_size.width, if (child.frame.width > 0) child.frame.width else cell_width);
            const height = @max(child.layout.min_size.height, if (child.frame.height > 0) child.frame.height else range.item_extent);
            const child_frame = geometry.RectF.init(
                x + child.frame.x,
                y,
                width,
                height,
            );
            _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
        }
    }
}

fn gridColumnCount(child_count: usize, requested_columns: usize) usize {
    if (child_count == 0) return 0;
    return if (requested_columns > 0) @min(requested_columns, child_count) else child_count;
}

fn gridRowCount(child_count: usize, columns: usize) usize {
    if (child_count == 0 or columns == 0) return 0;
    return (child_count + columns - 1) / columns;
}

fn preferredGridRowExtent(children: []const Widget, columns: usize, tokens: DesignTokens) f32 {
    if (children.len == 0 or columns == 0) return 0;
    var max_height: f32 = 0;
    var index: usize = 0;
    while (index < children.len and index < columns) : (index += 1) {
        max_height = @max(max_height, preferredMainExtent(children[index], .vertical, tokens));
    }
    return max_height;
}

fn layoutScrollChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    scroll_y: f32,
    tokens: DesignTokens,
) Error!void {
    const scrolled_content = content.translate(geometry.OffsetF.init(0, -scroll_y));
    for (children) |child| {
        _ = try layoutWidgetDepth(child, stackChildFrame(scrolled_content, child), parent_index, depth + 1, output, len, tokens);
    }
}

fn layoutVirtualVerticalChildren(
    children: []const Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    scroll_y: f32,
    style: WidgetLayoutStyle,
    tokens: DesignTokens,
) Error!void {
    if (children.len == 0) return;

    const item_extent = if (style.virtual_item_extent > 0)
        style.virtual_item_extent
    else
        preferredMainExtent(children[0], .vertical, tokens);
    const range = virtualListRange(.{
        .item_count = children.len,
        .item_extent = item_extent,
        .item_gap = style.gap,
        .viewport_extent = content.height,
        .scroll_offset = scroll_y,
        .overscan = style.virtual_overscan,
    });
    output[parent_index].widget.layout.virtual_item_extent = range.item_extent;
    output[parent_index].widget.semantics.list_item_count = saturatingU32(children.len);
    if (range.isEmpty()) return;

    const stride = range.item_extent + range.item_gap;
    var index = range.start_index;
    while (index < range.end_index) : (index += 1) {
        var child = children[index];
        child.semantics.list_item_index = saturatingU32(index);
        child.semantics.list_item_count = saturatingU32(children.len);
        const y = content.y + @as(f32, @floatFromInt(index)) * stride - range.layout_offset + child.frame.y;
        const width = @max(child.layout.min_size.width, if (child.frame.width > 0) child.frame.width else content.width);
        const height = @max(child.layout.min_size.height, if (child.frame.height > 0) child.frame.height else range.item_extent);
        const child_frame = geometry.RectF.init(
            content.x + child.frame.x,
            y,
            width,
            height,
        );
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
    }
}

fn stackChildFrame(content: geometry.RectF, child: Widget) geometry.RectF {
    const width = if (child.frame.width > 0) child.frame.width else content.width;
    const height = if (child.frame.height > 0) child.frame.height else content.height;
    return geometry.RectF.init(
        content.x + child.frame.x,
        content.y + child.frame.y,
        @max(child.layout.min_size.width, width),
        @max(child.layout.min_size.height, height),
    );
}

fn accordionChildrenVisible(widget: Widget) bool {
    return widget.kind != .accordion or booleanControlSelected(widget);
}

fn accordionContentFrame(widget: Widget, content: geometry.RectF, tokens: DesignTokens) geometry.RectF {
    if (widget.kind != .accordion) return content;
    const header_height = accordionHeaderHeight(widget, tokens);
    const gap = nonNegative(widget.layout.gap);
    const y = @min(content.maxY(), content.y + header_height + gap);
    return geometry.RectF.init(content.x, y, content.width, @max(0, content.maxY() - y));
}

fn accordionHeaderHeight(widget: Widget, tokens: DesignTokens) f32 {
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    return @max(widgetControlHeight(widget, tokens), text_size + inset * 2);
}

pub fn intrinsicWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    return switch (widget.kind) {
        .text => intrinsicTextWidgetSize(widget, tokens, widgetBodyTextSize(widget, tokens)),
        .icon => geometry.SizeF.init(intrinsicIconExtent(widget, tokens), intrinsicIconExtent(widget, tokens)),
        .avatar => intrinsicAvatarWidgetSize(widget, tokens),
        .badge => intrinsicBadgeWidgetSize(widget, tokens),
        .button, .toggle_button => intrinsicButtonWidgetSize(widget, tokens),
        .icon_button => intrinsicSquareControlSize(widget, tokens),
        .select => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 200), widgetControlHeight(widget, tokens)),
        .input, .text_field => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), widgetControlHeight(widget, tokens)),
        .search_field, .combobox => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 200), widgetControlHeight(widget, tokens)),
        .textarea => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 200), widgetSizedDensityValue(widget, tokens, 80)),
        .tooltip => intrinsicPaddedTextWidgetSize(widget, tokens, widgetLabelTextSize(widget, tokens), widgetControlInset(widget, tokens, tokens.spacing.sm)),
        .menu_item, .list_item, .data_cell => intrinsicRowTextWidgetSize(widget, tokens),
        .data_row => geometry.SizeF.init(0, widgetDefaultRowHeight(widget, tokens)),
        .status_bar => intrinsicStatusBarWidgetSize(widget, tokens),
        .segmented_control => intrinsicSegmentedControlSize(widget, tokens),
        .checkbox => intrinsicCheckboxWidgetSize(widget, tokens),
        .radio => intrinsicRadioWidgetSize(widget, tokens),
        .switch_control, .toggle => intrinsicToggleWidgetSize(widget, tokens),
        .slider => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), @max(widgetSizedDensityValue(widget, tokens, 28), widgetSizedDensityValue(widget, tokens, 20))),
        .progress => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), widgetSizedDensityValue(widget, tokens, 8)),
        .separator => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), controlStrokeWidth(widget, componentControlVisualTokens(widget, tokens), tokens.stroke.hairline)),
        .skeleton => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 120), widgetSizedDensityValue(widget, tokens, 20)),
        .spinner => intrinsicSquareControlSize(widget, tokens),
        .alert => intrinsicAlertWidgetSize(widget, tokens),
        .card => intrinsicCardWidgetSize(widget, tokens),
        .dialog, .drawer, .sheet => intrinsicModalSurfaceWidgetSize(widget, tokens),
        .stack, .row, .column, .grid, .data_grid, .table, .scroll_view, .list, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .accordion, .bubble, .resizable, .panel, .popover, .menu_surface, .dropdown_menu, .image => geometry.SizeF.zero(),
    };
}

fn intrinsicTextWidgetSize(widget: Widget, tokens: DesignTokens, text_size: f32) geometry.SizeF {
    return geometry.SizeF.init(
        estimateTextWidthForFont(tokens.typography.font_id, widget.text, text_size),
        widgetLineHeight(text_size),
    );
}

fn intrinsicPaddedTextWidgetSize(widget: Widget, tokens: DesignTokens, text_size: f32, inset: f32) geometry.SizeF {
    const text = intrinsicTextWidgetSize(widget, tokens, text_size);
    return geometry.SizeF.init(text.width + inset * 2, @max(widgetControlHeight(widget, tokens), text.height + widgetSizedDensityValue(widget, tokens, 8)));
}

fn intrinsicStatusBarWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_size = widgetBodyTextSize(widget, tokens);
    const text = intrinsicTextWidgetSize(widget, tokens, text_size);
    const padding = widgetStatusBarPadding(widget);
    return geometry.SizeF.init(text.width + padding.horizontal(), @max(widgetSizedDensityValue(widget, tokens, 32), text.height + padding.vertical()));
}

fn intrinsicAlertWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    const icon_size = @max(widgetSizedDensityValue(widget, tokens, 12), text_size - 1);
    const text_gap = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text = intrinsicTextWidgetSize(widget, tokens, text_size);
    return geometry.SizeF.init(
        @max(widgetSizedDensityValue(widget, tokens, 240), text.width + inset * 2 + icon_size + text_gap),
        @max(widgetSizedDensityValue(widget, tokens, 52), widgetLineHeight(text_size) + inset * 2),
    );
}

fn intrinsicCardWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const title_size = widgetTypographySize(widget, tokens.typography.body_size + 1);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    const text = intrinsicTextWidgetSize(widget, tokens, title_size);
    return geometry.SizeF.init(
        @max(widgetSizedDensityValue(widget, tokens, 240), text.width + inset * 2),
        @max(widgetSizedDensityValue(widget, tokens, 120), if (widget.text.len > 0) widgetLineHeight(title_size) + inset * 2 else 0),
    );
}

fn intrinsicModalSurfaceWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const title_size = widgetTypographySize(widget, tokens.typography.title_size);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.xl);
    const text = intrinsicTextWidgetSize(widget, tokens, title_size);
    const default_size = switch (widget.kind) {
        .drawer => geometry.SizeF.init(360, 280),
        .sheet => geometry.SizeF.init(320, 420),
        else => geometry.SizeF.init(420, 220),
    };
    return geometry.SizeF.init(
        @max(widgetSizedDensityValue(widget, tokens, default_size.width), text.width + inset * 2),
        @max(widgetSizedDensityValue(widget, tokens, default_size.height), if (widget.text.len > 0) widgetLineHeight(title_size) + inset * 2 else 0),
    );
}

fn intrinsicButtonWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const height = widgetControlHeight(widget, tokens);
    if (widget.size == .icon) return geometry.SizeF.init(height, height);
    const text_width = estimateTextWidthForFont(tokens.typography.font_id, widget.text, widgetButtonTextSize(widget, tokens));
    const width = @max(widgetSizedDensityValue(widget, tokens, 44), text_width + widgetButtonInset(widget, tokens) * 2);
    return geometry.SizeF.init(width, height);
}

fn intrinsicAvatarWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const size = widgetSizedDensityValue(widget, tokens, 40);
    return geometry.SizeF.init(size, size);
}

fn intrinsicBadgeWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_width = estimateTextWidthForFont(tokens.typography.font_id, widget.text, widgetLabelTextSize(widget, tokens));
    const inset = widgetControlInset(widget, tokens, tokens.spacing.sm);
    return geometry.SizeF.init(@max(widgetSizedDensityValue(widget, tokens, 24), text_width + inset * 2), widgetSizedDensityValue(widget, tokens, 22));
}

fn intrinsicSquareControlSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const height = widgetControlHeight(widget, tokens);
    return geometry.SizeF.init(height, height);
}

fn intrinsicSegmentedControlSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_width = estimateTextWidthForFont(tokens.typography.font_id, widget.text, widgetLabelTextSize(widget, tokens));
    const width = @max(widgetSizedDensityValue(widget, tokens, 44), text_width + widgetControlInset(widget, tokens, tokens.spacing.md) * 2);
    return geometry.SizeF.init(width, widgetControlHeight(widget, tokens));
}

fn intrinsicRowTextWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text_width = estimateTextWidthForFont(tokens.typography.font_id, widget.text, text_size);
    return geometry.SizeF.init(text_width + inset * 2, widgetDefaultRowHeight(widget, tokens));
}

fn intrinsicCheckboxWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const box_size = widgetSizedDensityValue(widget, tokens, 18);
    const label_size = widgetLabelTextSize(widget, tokens);
    const label_width = estimateTextWidthForFont(tokens.typography.font_id, widget.text, label_size);
    const gap = if (widget.text.len > 0) widgetControlInset(widget, tokens, tokens.spacing.sm) else 0;
    return geometry.SizeF.init(box_size + gap + label_width, @max(box_size, widgetLineHeight(label_size)));
}

fn intrinsicRadioWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const circle_size = widgetSizedDensityValue(widget, tokens, 18);
    const label_size = widgetLabelTextSize(widget, tokens);
    const label_width = estimateTextWidthForFont(tokens.typography.font_id, widget.text, label_size);
    const gap = if (widget.text.len > 0) widgetControlInset(widget, tokens, tokens.spacing.sm) else 0;
    return geometry.SizeF.init(circle_size + gap + label_width, @max(circle_size, widgetLineHeight(label_size)));
}

fn intrinsicToggleWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const track_width = widgetSizedDensityValue(widget, tokens, 42);
    const track_height = widgetSizedDensityValue(widget, tokens, 24);
    const label_size = widgetLabelTextSize(widget, tokens);
    const label_width = estimateTextWidthForFont(tokens.typography.font_id, widget.text, label_size);
    const gap = if (widget.text.len > 0) widgetControlInset(widget, tokens, tokens.spacing.sm) else 0;
    return geometry.SizeF.init(track_width + gap + label_width, @max(track_height, widgetLineHeight(label_size)));
}

fn intrinsicIconExtent(widget: Widget, tokens: DesignTokens) f32 {
    return widgetSizedDensityValue(widget, tokens, 18);
}

pub fn widgetControlHeight(widget: Widget, tokens: DesignTokens) f32 {
    return widgetSizedDensityValue(widget, tokens, 34);
}

fn widgetDefaultRowHeight(widget: Widget, tokens: DesignTokens) f32 {
    return widgetSizedDensityValue(widget, tokens, default_widget_row_extent);
}

fn widgetLineHeight(text_size: f32) f32 {
    return text_size * 1.25;
}

fn preferredMainExtent(widget: Widget, axis: LayoutAxis, tokens: DesignTokens) f32 {
    const value = switch (axis) {
        .horizontal => widget.frame.width,
        .vertical => widget.frame.height,
    };
    return @max(minMainExtent(widget, axis), if (value > 0) value else intrinsicMainExtent(widget, axis, tokens));
}

fn preferredCrossExtent(widget: Widget, axis: LayoutAxis, available: f32, alignment: WidgetCrossAlignment, tokens: DesignTokens) f32 {
    const value = switch (axis) {
        .horizontal => widget.frame.height,
        .vertical => widget.frame.width,
    };
    const min_value = switch (axis) {
        .horizontal => widget.layout.min_size.height,
        .vertical => widget.layout.min_size.width,
    };
    if (value > 0) return @max(min_value, value);
    if (alignment == .stretch) return @max(min_value, available);
    return @max(min_value, @min(available, intrinsicCrossExtent(widget, axis, tokens)));
}

fn minMainExtent(widget: Widget, axis: LayoutAxis) f32 {
    return switch (axis) {
        .horizontal => nonNegative(widget.layout.min_size.width),
        .vertical => nonNegative(widget.layout.min_size.height),
    };
}

fn intrinsicMainExtent(widget: Widget, axis: LayoutAxis, tokens: DesignTokens) f32 {
    const size = intrinsicWidgetSize(widget, tokens);
    return switch (axis) {
        .horizontal => size.width,
        .vertical => size.height,
    };
}

fn intrinsicCrossExtent(widget: Widget, axis: LayoutAxis, tokens: DesignTokens) f32 {
    const size = intrinsicWidgetSize(widget, tokens);
    return switch (axis) {
        .horizontal => size.height,
        .vertical => size.width,
    };
}

fn hitTestWidgetLayout(layout: WidgetLayoutTree, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    return hitTestWidgetLayoutChildren(layout, null, point, tokens);
}

fn hitTestWidgetLayoutChildren(layout: WidgetLayoutTree, parent_index: ?usize, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    const child_count = widgetLayoutDirectChildCount(layout, parent_index);
    var tested: usize = 0;
    var previous: ?WidgetPaintOrder = null;
    while (tested < child_count) : (tested += 1) {
        const child_index = previousWidgetLayoutPaintChild(layout, parent_index, tokens, previous) orelse return null;
        if (hitTestWidgetLayoutNode(layout, child_index, point, tokens)) |hit| return hit;
        previous = .{ .layer = widgetPaintLayer(layout.nodes[child_index].widget, tokens), .index = child_index };
    }
    return null;
}

fn hitTestWidgetLayoutNode(layout: WidgetLayoutTree, node_index: usize, point: geometry.PointF, tokens: DesignTokens) ?WidgetHit {
    if (node_index >= layout.nodes.len) return null;
    const node = layout.nodes[node_index];
    if (node.widget.semantics.hidden) return null;

    const local_point = widgetLocalHitPoint(node.widget, point) orelse return null;
    if (widgetClipsContent(node.widget) and !node.frame.normalized().containsPoint(local_point)) return null;
    if (hitTestWidgetLayoutChildren(layout, node_index, local_point, tokens)) |hit| return hit;

    if (!isHitTarget(node.widget)) return null;
    if (!node.frame.normalized().containsPoint(local_point)) return null;
    return widgetHitFromNode(node, node_index);
}

fn widgetLocalHitPoint(widget: Widget, point: geometry.PointF) ?geometry.PointF {
    const transform = widgetTransform(widget);
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

pub fn cursorForWidgetHit(hit: ?WidgetHit) WidgetCursor {
    const target = hit orelse return .arrow;
    return cursorForWidgetTarget(target.kind, target.state);
}

pub fn cursorForWidgetTarget(kind: WidgetKind, state: WidgetState) WidgetCursor {
    if (state.disabled) return .arrow;
    return switch (kind) {
        .input, .text_field, .search_field, .combobox, .textarea => .text,
        .button,
        .toggle_button,
        .accordion,
        .icon_button,
        .select,
        .menu_item,
        .list_item,
        .data_cell,
        .segmented_control,
        .checkbox,
        .radio,
        .switch_control,
        .toggle,
        => .pointing_hand,
        .slider, .resizable => .resize_horizontal,
        else => .arrow,
    };
}

fn isPointVisibleInWidgetAncestors(layout: WidgetLayoutTree, node_index: usize, point: geometry.PointF) bool {
    var current = layout.nodes[node_index].parent_index;
    while (current) |parent_index| {
        const parent = layout.nodes[parent_index];
        if (widgetClipsContent(parent.widget) and !parent.frame.normalized().containsPoint(point)) return false;
        current = parent.parent_index;
    }
    return true;
}

fn isWidgetFrameVisibleInWidgetAncestors(layout: WidgetLayoutTree, node_index: usize) bool {
    if (node_index >= layout.nodes.len) return false;
    const frame = layout.nodes[node_index].frame.normalized();
    if (frame.isEmpty()) return false;
    var current = layout.nodes[node_index].parent_index;
    while (current) |parent_index| {
        const parent = layout.nodes[parent_index];
        if (widgetClipsContent(parent.widget) and geometry.RectF.intersection(frame, parent.frame.normalized()).isEmpty()) return false;
        current = parent.parent_index;
    }
    return true;
}

fn routeWidgetPointerEvent(layout: WidgetLayoutTree, event: WidgetPointerEvent, tokens: DesignTokens, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
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

fn capturedWidgetPointerTarget(layout: WidgetLayoutTree, event: WidgetPointerEvent) ?WidgetHit {
    const id = event.captured_id orelse return null;
    return switch (event.phase) {
        .move, .up, .cancel => widgetPointerTargetById(layout, id),
        .hover, .down, .wheel => null,
    };
}

fn widgetPointerTargetById(layout: WidgetLayoutTree, id: ObjectId) ?WidgetHit {
    const index = widgetIndexById(layout, id) orelse return null;
    const node = layout.nodes[index];
    if (!isHitTarget(node.widget)) return null;
    if (isWidgetHiddenInAncestors(layout, index)) return null;
    if (!isWidgetFrameVisibleInWidgetAncestors(layout, index)) return null;
    return widgetHitFromNode(node, index);
}

fn routeWidgetKeyboardEvent(layout: WidgetLayoutTree, event: WidgetKeyboardEvent, output: []WidgetEventRouteEntry) Error!WidgetKeyboardRoute {
    const focused_id = event.focused_id orelse return .{ .entries = output[0..0] };
    const target_index = widgetIndexById(layout, focused_id) orelse return .{ .entries = output[0..0] };
    const target = focusTargetFromLayoutNode(layout, target_index) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target.index, output);
    return .{ .target = target, .entries = entries };
}

fn routeWidgetFileDropEvent(layout: WidgetLayoutTree, event: WidgetFileDropEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    if (event.paths.len == 0) return .{ .entries = output[0..0] };
    const target_index = widgetDropTargetIndexAtPoint(layout, event.point) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target_index, output);
    return .{ .target = widgetHitFromNode(layout.nodes[target_index], target_index), .entries = entries };
}

fn routeWidgetDragEvent(layout: WidgetLayoutTree, event: WidgetDragEvent, output: []WidgetEventRouteEntry) Error!WidgetEventRoute {
    const target_index = widgetDragSourceIndex(layout, event.source_id) orelse return .{ .entries = output[0..0] };
    const entries = try routeWidgetEventPath(layout, target_index, output);
    return .{ .target = widgetHitFromNode(layout.nodes[target_index], target_index), .entries = entries };
}

fn widgetDropTargetIndexAtPoint(layout: WidgetLayoutTree, point: geometry.PointF) ?usize {
    var index = layout.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = layout.nodes[index];
        if (!isDropTarget(node.widget)) continue;
        if (isWidgetHiddenInAncestors(layout, index)) continue;
        if (!node.frame.normalized().containsPoint(point)) continue;
        if (!isPointVisibleInWidgetAncestors(layout, index, point)) continue;
        return index;
    }
    return null;
}

fn widgetDragSourceIndex(layout: WidgetLayoutTree, id: ObjectId) ?usize {
    if (id == 0) return null;
    const index = widgetIndexById(layout, id) orelse return null;
    const node = layout.nodes[index];
    if (!isDragSource(node.widget)) return null;
    if (isWidgetHiddenInAncestors(layout, index)) return null;
    if (!isWidgetFrameVisibleInWidgetAncestors(layout, index)) return null;
    return index;
}

fn routeWidgetEventPath(layout: WidgetLayoutTree, target_index: usize, output: []WidgetEventRouteEntry) Error![]const WidgetEventRouteEntry {
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

fn focusWidgetTarget(layout: WidgetLayoutTree, current_id: ?ObjectId, direction: WidgetFocusDirection) ?WidgetFocusTarget {
    if (layout.nodes.len == 0) return null;
    const current_index = if (current_id) |id| widgetIndexById(layout, id) else null;
    return switch (direction) {
        .forward => focusForward(layout, current_index),
        .backward => focusBackward(layout, current_index),
        .left, .right, .up, .down => if (current_index) |index| focusSpatial(layout, index, direction) else null,
    };
}

fn focusWidgetTargetById(layout: WidgetLayoutTree, id: ObjectId) ?WidgetFocusTarget {
    const index = widgetIndexById(layout, id) orelse return null;
    return focusTargetFromLayoutNode(layout, index);
}

fn focusForward(layout: WidgetLayoutTree, current_index: ?usize) ?WidgetFocusTarget {
    var index: usize = if (current_index) |value| value + 1 else 0;
    while (index < layout.nodes.len) : (index += 1) {
        if (focusTargetFromLayoutNode(layout, index)) |target| return target;
    }
    index = 0;
    const stop = current_index orelse layout.nodes.len;
    while (index < stop and index < layout.nodes.len) : (index += 1) {
        if (focusTargetFromLayoutNode(layout, index)) |target| return target;
    }
    return null;
}

fn focusBackward(layout: WidgetLayoutTree, current_index: ?usize) ?WidgetFocusTarget {
    var index = current_index orelse layout.nodes.len;
    while (index > 0) {
        index -= 1;
        if (focusTargetFromLayoutNode(layout, index)) |target| return target;
    }
    index = layout.nodes.len;
    const stop = if (current_index) |value| value + 1 else 0;
    while (index > stop) {
        index -= 1;
        if (focusTargetFromLayoutNode(layout, index)) |target| return target;
    }
    return null;
}

fn focusSpatial(layout: WidgetLayoutTree, current_index: usize, direction: WidgetFocusDirection) ?WidgetFocusTarget {
    const current = focusTargetFromLayoutNode(layout, current_index) orelse return null;
    const current_bounds = current.bounds.normalized();
    const current_center = current_bounds.center();
    var best: ?WidgetFocusTarget = null;
    var best_score = std.math.inf(f32);

    for (layout.nodes, 0..) |_, index| {
        if (index == current_index) continue;
        const target = focusTargetFromLayoutNode(layout, index) orelse continue;
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

fn focusTargetFromLayoutNode(layout: WidgetLayoutTree, index: usize) ?WidgetFocusTarget {
    if (index >= layout.nodes.len) return null;
    if (isWidgetHiddenInAncestors(layout, index)) return null;
    if (!isWidgetFrameVisibleInWidgetAncestors(layout, index)) return null;
    const node = layout.nodes[index];
    if (node.widget.id == 0) return null;
    if (!isFocusable(node.widget) and (node.widget.state.disabled or !widgetScrollSemantics(layout, index).scrollable)) return null;
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

fn widgetIndexById(layout: WidgetLayoutTree, id: ObjectId) ?usize {
    if (id == 0) return null;
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id == id) return index;
    }
    return null;
}

fn isWidgetHiddenInAncestors(layout: WidgetLayoutTree, node_index: usize) bool {
    var current: ?usize = node_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return false;
        const node = layout.nodes[index];
        if (node.widget.semantics.hidden) return true;
        current = node.parent_index;
    }
    return false;
}

fn collectWidgetSemantics(layout: WidgetLayoutTree, output: []WidgetSemanticsNode) Error![]const WidgetSemanticsNode {
    var len: usize = 0;
    var semantic_stack: [max_widget_depth]?usize = [_]?usize{null} ** max_widget_depth;
    var hidden_depth: ?usize = null;

    for (layout.nodes, 0..) |node, node_index| {
        if (node.depth >= max_widget_depth) return error.WidgetDepthExceeded;
        if (hidden_depth) |depth| {
            if (node.depth > depth) continue;
            hidden_depth = null;
        }
        var cursor = node.depth + 1;
        while (cursor < semantic_stack.len) : (cursor += 1) {
            semantic_stack[cursor] = null;
        }

        const role = semanticRole(node.widget);
        if (node.widget.semantics.hidden) {
            hidden_depth = node.depth;
            continue;
        }
        if (role == .none or node.widget.id == 0) continue;
        if (len >= output.len) return error.WidgetSemanticsListFull;

        const parent_index = nearestSemanticParent(semantic_stack[0..node.depth]);
        const grid = widgetGridSemantics(layout, node_index);
        const list = widgetListSemantics(layout, node_index);
        const scroll = widgetScrollSemantics(layout, node_index);
        var actions = semanticActions(node.widget);
        if (scroll.scrollable and !node.widget.state.disabled) {
            actions.focus = true;
            actions.increment = true;
            actions.decrement = true;
        }
        output[len] = .{
            .id = node.widget.id,
            .role = role,
            .label = semanticLabel(node.widget),
            .value = scroll.value orelse semanticValue(node.widget),
            .text_value = semanticTextValue(node.widget),
            .placeholder = semanticPlaceholder(node.widget),
            .grid_row_index = grid.row_index,
            .grid_column_index = grid.column_index,
            .grid_row_count = grid.row_count,
            .grid_column_count = grid.column_count,
            .list = list.metrics,
            .scroll = scroll.metrics,
            .bounds = node.frame,
            .state = semanticState(node.widget),
            .focusable = semanticFocusable(node.widget, actions),
            .actions = actions,
            .text_selection = widgetTextSelectionRange(node.widget),
            .text_composition = widgetTextCompositionRange(node.widget),
            .parent_index = parent_index,
        };
        semantic_stack[node.depth] = len;
        len += 1;
    }

    return output[0..len];
}

pub const WidgetTextGeometry = struct {
    caret_bounds: ?geometry.RectF = null,
    selection_bounds: ?geometry.RectF = null,
    selection_rect_count: usize = 0,
    composition_bounds: ?geometry.RectF = null,
    composition_rect_count: usize = 0,
};

pub fn textGeometryForWidget(widget: Widget, tokens: DesignTokens) WidgetTextGeometry {
    var value: WidgetTextGeometry = .{};
    if (!widgetTextInputKind(widget.kind)) return value;
    if (widget.state.disabled) return value;

    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, tokens.colors.text, layout_options);

    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    const layout = layoutTextRun(draw_text, layout_options, &lines) catch return value;

    if (widgetTextSelectionRange(widget)) |range| {
        if (range.isCollapsed(widget.text.len)) {
            value.caret_bounds = textCaretRectForLayout(draw_text, layout, range.start);
        } else {
            const bounds = textRangeBoundsForLayout(draw_text, layout, range);
            value.selection_bounds = bounds.bounds;
            value.selection_rect_count = bounds.rect_count;
        }
    }
    if (widgetTextCompositionRange(widget)) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            const bounds = textRangeBoundsForLayout(draw_text, layout, range);
            value.composition_bounds = bounds.bounds;
            value.composition_rect_count = bounds.rect_count;
        }
    }
    return value;
}

const TextRangeBounds = struct {
    bounds: ?geometry.RectF = null,
    rect_count: usize = 0,
};

fn textRangeBoundsForLayout(text: DrawText, layout: TextLayout, range: TextRange) TextRangeBounds {
    const normalized = snapTextRange(text.text, range);
    if (normalized.isCollapsed(text.text.len)) return .{};

    var value: TextRangeBounds = .{};
    for (layout.lines) |line| {
        const line_range = textLineRange(text, line);
        const start = @max(normalized.start, line_range.start);
        const end = @min(normalized.end, line_range.end);
        if (start >= end) continue;

        const x0 = textLineCaretX(text, line, start);
        const x1 = textLineCaretX(text, line, end);
        const left = @min(x0, x1);
        const right = @max(x0, x1);
        value.bounds = unionOptionalBounds(
            value.bounds,
            geometry.RectF.init(left, line.bounds.y, @max(1, right - left), @max(1, line.bounds.height)),
        );
        value.rect_count += 1;
    }
    return value;
}

fn nearestSemanticParent(stack: []const ?usize) ?usize {
    var index = stack.len;
    while (index > 0) {
        index -= 1;
        if (stack[index]) |semantic_index| return semantic_index;
    }
    return null;
}

fn semanticRole(widget: Widget) WidgetRole {
    if (widget.semantics.role != .none) return widget.semantics.role;
    return switch (widget.kind) {
        .stack, .row, .column, .grid, .scroll_view, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .accordion, .bubble, .resizable, .alert, .card, .panel => .group,
        .data_grid, .table => .grid,
        .data_row => .row,
        .dialog, .drawer, .sheet, .popover => .dialog,
        .menu_surface, .dropdown_menu => .menu,
        .list => .list,
        .text, .status_bar => .text,
        .icon, .image, .avatar => .image,
        .badge => .text,
        .button, .toggle_button => .button,
        .icon_button, .select => .button,
        .input, .text_field, .search_field, .combobox, .textarea => .textbox,
        .tooltip => .tooltip,
        .menu_item => .menuitem,
        .list_item => .listitem,
        .data_cell => .gridcell,
        .segmented_control => .tab,
        .checkbox => .checkbox,
        .radio => .radio,
        .switch_control, .toggle => .switch_control,
        .slider => .slider,
        .progress => .progressbar,
        .separator, .skeleton => .none,
        .spinner => .progressbar,
    };
}

fn semanticLabel(widget: Widget) []const u8 {
    if (widget.semantics.label.len > 0) return widget.semantics.label;
    return widget.text;
}

fn semanticValue(widget: Widget) ?f32 {
    if (widget.semantics.value) |value| return value;
    return switch (widget.kind) {
        .radio, .list_item, .menu_item, .data_cell, .segmented_control => if (widget.state.selected or widget.value >= 0.5) 1 else 0,
        .accordion, .checkbox, .switch_control, .toggle, .toggle_button => if (booleanControlSelected(widget)) 1 else 0,
        .slider, .progress => std.math.clamp(widget.value, 0, 1),
        .spinner => null,
        else => null,
    };
}

fn semanticState(widget: Widget) WidgetState {
    var state = widget.state;
    if (state.expanded == null) state.expanded = defaultExpandedState(widget);
    return state;
}

fn defaultExpandedState(widget: Widget) ?bool {
    return switch (widget.kind) {
        .accordion => booleanControlSelected(widget),
        .select, .combobox => false,
        .popover, .menu_surface, .dropdown_menu => true,
        else => null,
    };
}

fn semanticTextValue(widget: Widget) []const u8 {
    return switch (widget.kind) {
        .input, .text_field, .search_field, .combobox, .textarea => widget.text,
        else => "",
    };
}

fn semanticPlaceholder(widget: Widget) []const u8 {
    return switch (widget.kind) {
        .select, .input, .text_field, .search_field, .combobox, .textarea => widget.placeholder,
        else => "",
    };
}

const WidgetGridSemantics = struct {
    row_index: ?usize = null,
    column_index: ?usize = null,
    row_count: ?usize = null,
    column_count: ?usize = null,
};

fn widgetGridSemantics(layout: WidgetLayoutTree, node_index: usize) WidgetGridSemantics {
    if (node_index >= layout.nodes.len) return .{};
    const node = layout.nodes[node_index];
    return switch (node.widget.kind) {
        .grid => widgetLayoutGridSemantics(layout, node_index),
        .data_grid, .table => .{
            .row_count = dataGridRowCount(layout, node_index),
            .column_count = maxDataGridColumnCount(layout, node_index),
        },
        .data_row => widgetDataRowGridSemantics(layout, node_index),
        .data_cell => widgetDataCellGridSemantics(layout, node_index),
        else => widgetGridChildSemantics(layout, node_index),
    };
}

fn widgetLayoutGridSemantics(layout: WidgetLayoutTree, grid_index: usize) WidgetGridSemantics {
    const grid = layout.nodes[grid_index].widget;
    if (grid.semantics.role != .grid) return .{};
    const columns = gridSemanticColumnCount(grid);
    return .{
        .row_count = gridSemanticRowCount(grid, columns),
        .column_count = columns,
    };
}

fn widgetGridChildSemantics(layout: WidgetLayoutTree, child_index: usize) WidgetGridSemantics {
    const grid_index = layout.nodes[child_index].parent_index orelse return .{};
    if (grid_index >= layout.nodes.len) return .{};
    const grid = layout.nodes[grid_index].widget;
    if (grid.kind != .grid or grid.semantics.role != .grid) return .{};

    const columns = gridSemanticColumnCount(grid);
    if (columns == 0) return .{};
    const source_index = if (layout.nodes[child_index].widget.semantics.list_item_index) |index|
        @as(usize, @intCast(index))
    else
        directChildOrdinal(layout, grid_index, child_index) orelse return .{};

    return .{
        .row_index = source_index / columns,
        .column_index = source_index % columns,
        .row_count = gridSemanticRowCount(grid, columns),
        .column_count = columns,
    };
}

fn gridSemanticColumnCount(grid: Widget) usize {
    return gridColumnCount(grid.children.len, grid.layout.columns);
}

fn gridSemanticRowCount(grid: Widget, columns: usize) usize {
    if (grid.semantics.list_item_count) |count| return @intCast(count);
    return gridRowCount(grid.children.len, columns);
}

fn widgetDataRowGridSemantics(layout: WidgetLayoutTree, row_index: usize) WidgetGridSemantics {
    const grid_index = layout.nodes[row_index].parent_index orelse return .{};
    if (grid_index >= layout.nodes.len) return .{};
    if (layout.nodes[grid_index].widget.kind == .grid) return widgetGridChildSemantics(layout, row_index);
    if (!widgetTableContainerKind(layout.nodes[grid_index].widget.kind)) return .{};
    const row = layout.nodes[row_index].widget;
    return .{
        .row_index = if (row.semantics.list_item_index) |source_index|
            @as(usize, @intCast(source_index))
        else
            directChildOrdinalByKind(layout, grid_index, row_index, .data_row),
        .row_count = dataGridRowCount(layout, grid_index),
        .column_count = dataRowColumnCount(layout, row_index),
    };
}

fn widgetDataCellGridSemantics(layout: WidgetLayoutTree, cell_index: usize) WidgetGridSemantics {
    const row_index = layout.nodes[cell_index].parent_index orelse return .{};
    if (row_index >= layout.nodes.len) return .{};
    if (layout.nodes[row_index].widget.kind == .grid) return widgetGridChildSemantics(layout, cell_index);
    if (layout.nodes[row_index].widget.kind != .data_row) return .{};
    const grid_index = layout.nodes[row_index].parent_index orelse return .{};
    if (grid_index >= layout.nodes.len or !widgetTableContainerKind(layout.nodes[grid_index].widget.kind)) return .{};
    const row = layout.nodes[row_index].widget;
    return .{
        .row_index = if (row.semantics.list_item_index) |source_index|
            @as(usize, @intCast(source_index))
        else
            directChildOrdinalByKind(layout, grid_index, row_index, .data_row),
        .column_index = directChildOrdinalByKind(layout, row_index, cell_index, .data_cell),
        .row_count = dataGridRowCount(layout, grid_index),
        .column_count = dataRowColumnCount(layout, row_index),
    };
}

fn widgetTableContainerKind(kind: WidgetKind) bool {
    return kind == .data_grid or kind == .table;
}

fn dataGridRowCount(layout: WidgetLayoutTree, grid_index: usize) usize {
    if (layout.nodes[grid_index].widget.semantics.list_item_count) |virtual_count| return @intCast(virtual_count);
    return directChildCountByKind(layout, grid_index, .data_row);
}

fn dataRowColumnCount(layout: WidgetLayoutTree, row_index: usize) usize {
    return directChildCountByKind(layout, row_index, .data_cell);
}

fn directChildCountByKind(layout: WidgetLayoutTree, parent_index: usize, kind: WidgetKind) usize {
    var count: usize = 0;
    for (layout.nodes) |node| {
        if (node.parent_index == parent_index and node.widget.kind == kind) count += 1;
    }
    return count;
}

fn directChildOrdinalByKind(layout: WidgetLayoutTree, parent_index: usize, child_index: usize, kind: WidgetKind) ?usize {
    var ordinal: usize = 0;
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != parent_index or node.widget.kind != kind) continue;
        if (index == child_index) return ordinal;
        ordinal += 1;
    }
    return null;
}

fn directChildOrdinal(layout: WidgetLayoutTree, parent_index: usize, child_index: usize) ?usize {
    var ordinal: usize = 0;
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != parent_index) continue;
        if (index == child_index) return ordinal;
        ordinal += 1;
    }
    return null;
}

fn maxDataGridColumnCount(layout: WidgetLayoutTree, grid_index: usize) usize {
    var max_columns: usize = 0;
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != grid_index or node.widget.kind != .data_row) continue;
        max_columns = @max(max_columns, dataRowColumnCount(layout, index));
    }
    return max_columns;
}

const WidgetListSemantics = struct {
    metrics: WidgetListMetrics = .{},
};

fn widgetListSemantics(layout: WidgetLayoutTree, node_index: usize) WidgetListSemantics {
    if (node_index >= layout.nodes.len) return .{};
    const node = layout.nodes[node_index];

    const list_index = node.parent_index orelse return .{};
    if (list_index >= layout.nodes.len or layout.nodes[list_index].widget.kind != .list) return .{};

    if (node.widget.semantics.list_item_index) |item_index| {
        if (node.widget.semantics.list_item_count) |item_count| {
            return .{ .metrics = .{
                .present = true,
                .item_index = item_index,
                .item_count = item_count,
            } };
        }
    }

    if (node.widget.kind != .list_item) return .{};

    const item_count = directChildCountByKind(layout, list_index, .list_item);
    if (item_count == 0) return .{};

    const item_index = directChildOrdinalByKind(layout, list_index, node_index, .list_item) orelse return .{};
    return .{ .metrics = .{
        .present = true,
        .item_index = saturatingU32(item_index),
        .item_count = saturatingU32(item_count),
    } };
}

fn saturatingU32(value: usize) u32 {
    return if (value > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(value);
}

fn widgetVirtualRangeForLayoutNode(node: WidgetLayoutNode) ?VirtualListRange {
    if (!node.widget.layout.virtualized) return null;
    const item_count = if (node.widget.semantics.list_item_count) |count|
        @as(usize, @intCast(count))
    else
        return null;
    if (item_count == 0 or node.widget.layout.virtual_item_extent <= 0) return null;
    const viewport = node.frame.inset(node.widget.layout.padding).normalized();
    if (viewport.isEmpty()) return null;
    return virtualListRange(.{
        .item_count = item_count,
        .item_extent = node.widget.layout.virtual_item_extent,
        .item_gap = node.widget.layout.gap,
        .viewport_extent = viewport.height,
        .scroll_offset = node.widget.value,
        .overscan = node.widget.layout.virtual_overscan,
    });
}

const WidgetScrollSemantics = struct {
    metrics: WidgetScrollMetrics = .{},
    value: ?f32 = null,
    scrollable: bool = false,
};

fn widgetScrollSemantics(layout: WidgetLayoutTree, node_index: usize) WidgetScrollSemantics {
    if (node_index >= layout.nodes.len) return .{};
    const node = layout.nodes[node_index];
    if (!widgetExposesScrollSemantics(node.widget)) return .{};

    const viewport = node.frame.inset(node.widget.layout.padding).normalized();
    if (viewport.isEmpty()) return .{};

    const content_extent = widgetScrollContentExtent(layout, node_index, viewport);
    const max_offset = @max(0, content_extent - viewport.height);
    const offset = std.math.clamp(nonNegative(node.widget.value), 0, max_offset);
    return .{
        .metrics = .{
            .present = true,
            .offset = offset,
            .viewport_extent = viewport.height,
            .content_extent = content_extent,
        },
        .value = if (max_offset > 0) offset / max_offset else 0,
        .scrollable = max_offset > 0,
    };
}

fn widgetExposesScrollSemantics(widget: Widget) bool {
    return switch (widget.kind) {
        .scroll_view => true,
        .grid, .list, .data_grid, .table => widget.layout.virtualized,
        else => false,
    };
}

fn widgetScrollContentExtent(layout: WidgetLayoutTree, scroll_index: usize, viewport: geometry.RectF) f32 {
    const scroll_node = layout.nodes[scroll_index];
    if (scroll_node.widget.layout.virtualized) {
        return @max(viewport.height, virtualWidgetScrollContentExtent(scroll_node.widget, viewport.height));
    }

    const scroll_depth = scroll_node.depth;
    const offset = scroll_node.widget.value;
    var bottom = viewport.maxY();
    var index = scroll_index + 1;
    while (index < layout.nodes.len and layout.nodes[index].depth > scroll_depth) : (index += 1) {
        bottom = @max(bottom, layout.nodes[index].frame.maxY() + offset);
    }
    return @max(0, bottom - viewport.y);
}

pub fn virtualWidgetScrollContentExtent(widget: Widget, viewport_extent: f32) f32 {
    return virtualWidgetScrollContentExtentWithTokens(widget, viewport_extent, .{});
}

pub fn virtualWidgetScrollContentExtentWithTokens(widget: Widget, viewport_extent: f32, tokens: DesignTokens) f32 {
    const item_count = virtualWidgetScrollItemCount(widget);
    if (item_count == 0) return 0;
    const item_extent = if (widget.layout.virtual_item_extent > 0)
        widget.layout.virtual_item_extent
    else if (widget.kind == .grid and widget.children.len > 0)
        preferredGridRowExtent(widget.children, gridColumnCount(widget.children.len, widget.layout.columns), tokens)
    else if (widget.children.len > 0)
        preferredMainExtent(widget.children[0], .vertical, tokens)
    else
        return 0;
    return virtualListRange(.{
        .item_count = item_count,
        .item_extent = item_extent,
        .item_gap = widget.layout.gap,
        .viewport_extent = viewport_extent,
        .scroll_offset = widget.value,
    }).content_extent;
}

fn virtualWidgetScrollItemCount(widget: Widget) usize {
    if (widget.kind == .grid and widget.children.len > 0) {
        const columns = gridColumnCount(widget.children.len, widget.layout.columns);
        return gridRowCount(widget.children.len, columns);
    }
    if (widget.children.len > 0) return widget.children.len;
    if (widget.semantics.list_item_count) |count| return @intCast(count);
    return 0;
}

fn semanticFocusable(widget: Widget, actions: WidgetActions) bool {
    if (widget.id == 0 or widget.state.disabled or widget.semantics.hidden) return false;
    return widget.semantics.focusable or widget.semantics.actions.focus or actions.focus or defaultFocusable(widget);
}

fn isFocusable(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled or widget.semantics.hidden) return false;
    return widget.semantics.focusable or widget.semantics.actions.focus or defaultFocusable(widget);
}

fn isDropTarget(widget: Widget) bool {
    return widget.id != 0 and
        !widget.state.disabled and
        !widget.semantics.hidden and
        widget.semantics.actions.drop_files;
}

fn isDragSource(widget: Widget) bool {
    return widget.id != 0 and
        !widget.state.disabled and
        !widget.semantics.hidden and
        (widget.semantics.actions.drag or defaultSemanticActions(widget).drag);
}

fn isHitTarget(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled) return false;
    return switch (widget.kind) {
        .row, .column, .grid, .data_grid, .table, .data_row, .list, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .stack, .tooltip, .icon, .image, .avatar, .badge, .separator, .skeleton, .spinner => false,
        .scroll_view, .accordion, .alert, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover, .menu_surface, .dropdown_menu, .text, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .menu_item, .list_item, .data_cell, .status_bar, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .progress => true,
    };
}

fn widgetWithFrame(widget: Widget, frame: geometry.RectF) Widget {
    var copy = widget;
    copy.frame = frame;
    return copy;
}

fn widgetWithRenderState(widget: Widget, state: WidgetRenderState) Widget {
    var copy = widget;
    if (state.focused_id != null or state.focus_visible_id != null) {
        copy.state.focused = if (state.focus_visible_id) |focus_visible_id|
            copy.id != 0 and copy.id == focus_visible_id
        else
            false;
    }
    if (state.hovered_id) |hovered_id| {
        copy.state.hovered = copy.id != 0 and copy.id == hovered_id;
    }
    if (state.pressed_id) |pressed_id| {
        copy.state.pressed = copy.id != 0 and copy.id == pressed_id;
    }
    return copy;
}

fn diffWidgetLayoutTrees(previous: WidgetLayoutTree, next: WidgetLayoutTree, tokens: DesignTokens, output: []WidgetInvalidation) Error![]const WidgetInvalidation {
    try validateUniqueWidgetIds(previous);
    try validateUniqueWidgetIds(next);

    var len: usize = 0;
    for (previous.nodes, 0..) |previous_node, previous_index| {
        const id = previous_node.widget.id;
        if (id == 0) continue;
        const next_ref = findWidgetNodeById(next, id) orelse {
            try appendWidgetInvalidation(output, &len, .{
                .kind = .removed,
                .id = id,
                .previous_index = previous_index,
                .dirty_bounds = widgetClippedDirtyBounds(previous, previous_index, widgetFullPaintBounds(previous_node, tokens)),
                .layout_dirty = true,
                .paint_dirty = true,
                .semantics_dirty = true,
            });
            continue;
        };

        var change = widgetChange(previous_node, next_ref.node, previous_index, next_ref.index, tokens);
        if (previous_node.widget.semantics.hidden != next_ref.node.widget.semantics.hidden) {
            change.dirty_bounds = unionOptionalBounds(
                widgetVisibleSubtreeFullPaintBounds(previous, previous_index, tokens),
                widgetVisibleSubtreeFullPaintBounds(next, next_ref.index, tokens),
            );
        } else if (previous_node.widget.opacity != next_ref.node.widget.opacity or !affinesEqual(previous_node.widget.transform, next_ref.node.widget.transform)) {
            change.dirty_bounds = unionOptionalBounds(
                widgetVisibleSubtreeFullPaintBounds(previous, previous_index, tokens),
                widgetVisibleSubtreeFullPaintBounds(next, next_ref.index, tokens),
            );
        } else {
            change.dirty_bounds = widgetChangedClippedDirtyBounds(previous, previous_index, next, next_ref.index, change.dirty_bounds);
        }
        if (change.layout_dirty or change.paint_dirty or change.semantics_dirty) {
            try appendWidgetInvalidation(output, &len, change);
        }
    }

    for (next.nodes, 0..) |next_node, next_index| {
        const id = next_node.widget.id;
        if (id == 0) continue;
        if (findWidgetNodeById(previous, id) == null) {
            try appendWidgetInvalidation(output, &len, .{
                .kind = .added,
                .id = id,
                .next_index = next_index,
                .dirty_bounds = widgetClippedDirtyBounds(next, next_index, widgetFullPaintBounds(next_node, tokens)),
                .layout_dirty = true,
                .paint_dirty = true,
                .semantics_dirty = true,
            });
        }
    }

    return output[0..len];
}

fn appendWidgetInvalidation(output: []WidgetInvalidation, len: *usize, invalidation: WidgetInvalidation) Error!void {
    if (len.* >= output.len) return error.WidgetInvalidationListFull;
    output[len.*] = invalidation;
    len.* += 1;
}

const WidgetNodeRef = struct {
    index: usize,
    node: WidgetLayoutNode,
};

fn findWidgetNodeById(layout: WidgetLayoutTree, id: ObjectId) ?WidgetNodeRef {
    if (id == 0) return null;
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id == id) return .{ .index = index, .node = node };
    }
    return null;
}

fn validateUniqueWidgetIds(layout: WidgetLayoutTree) Error!void {
    for (layout.nodes, 0..) |node, index| {
        const id = node.widget.id;
        if (id == 0) continue;
        var cursor = index + 1;
        while (cursor < layout.nodes.len) : (cursor += 1) {
            if (layout.nodes[cursor].widget.id == id) return error.DuplicateWidgetId;
        }
    }
}

fn widgetChange(previous: WidgetLayoutNode, next: WidgetLayoutNode, previous_index: usize, next_index: usize, tokens: DesignTokens) WidgetInvalidation {
    const layout_dirty =
        previous.widget.kind != next.widget.kind or
        previous.depth != next.depth or
        previous.parent_index != next.parent_index or
        !rectsEqual(previous.frame, next.frame) or
        !widgetLayoutStylesEqual(previous.widget.layout, next.widget.layout);
    const content_dirty = !std.mem.eql(u8, previous.widget.text, next.widget.text) or
        !std.mem.eql(u8, previous.widget.placeholder, next.widget.placeholder) or
        previous.widget.value != next.widget.value or
        previous.widget.image_id != next.widget.image_id or
        !optionalRectsEqual(previous.widget.image_src, next.widget.image_src) or
        previous.widget.image_fit != next.widget.image_fit or
        previous.widget.image_sampling != next.widget.image_sampling or
        previous.widget.image_opacity != next.widget.image_opacity or
        !optionalTextSelectionsEqual(previous.widget.text_selection, next.widget.text_selection) or
        !optionalTextRangesEqual(previous.widget.text_composition, next.widget.text_composition);
    const behavior_dirty = !std.mem.eql(u8, previous.widget.command, next.widget.command);
    const visual_dirty = previous.widget.opacity != next.widget.opacity or
        !affinesEqual(previous.widget.transform, next.widget.transform) or
        previous.widget.backdrop_blur != next.widget.backdrop_blur or
        previous.widget.backdrop_blur_token != next.widget.backdrop_blur_token or
        previous.widget.text_alignment != next.widget.text_alignment or
        previous.widget.variant != next.widget.variant or
        previous.widget.size != next.widget.size or
        !widgetStylesEqual(previous.widget.style, next.widget.style);
    const state_dirty = !widgetStatesEqual(previous.widget.state, next.widget.state);
    const visibility_dirty = previous.widget.semantics.hidden != next.widget.semantics.hidden;
    const layer_dirty = previous.widget.layer != next.widget.layer;
    const semantics_dirty =
        layout_dirty or
        content_dirty or
        behavior_dirty or
        state_dirty or
        !widgetSemanticsEqual(previous.widget.semantics, next.widget.semantics);
    const paint_dirty = layout_dirty or content_dirty or visual_dirty or state_dirty or visibility_dirty or layer_dirty;

    const dirty_bounds = if (layout_dirty or visibility_dirty or layer_dirty)
        unionOptionalBounds(widgetFullPaintBounds(previous, tokens), widgetFullPaintBounds(next, tokens))
    else if (paint_dirty)
        widgetPaintChangeBounds(previous.widget, next.widget, tokens)
    else
        null;

    return .{
        .kind = .changed,
        .id = previous.widget.id,
        .previous_index = previous_index,
        .next_index = next_index,
        .dirty_bounds = dirty_bounds,
        .layout_dirty = layout_dirty,
        .paint_dirty = paint_dirty,
        .semantics_dirty = semantics_dirty,
    };
}

fn widgetRenderStateDirtyBounds(layout: WidgetLayoutTree, previous: WidgetRenderState, next: WidgetRenderState, tokens: DesignTokens) ?geometry.RectF {
    var ids: [8]?ObjectId = [_]?ObjectId{null} ** 8;
    var id_len: usize = 0;
    if (previous.focused_id != next.focused_id) {
        appendOptionalObjectId(&ids, &id_len, previous.focused_id);
        appendOptionalObjectId(&ids, &id_len, next.focused_id);
    }
    if (previous.focus_visible_id != next.focus_visible_id) {
        appendOptionalObjectId(&ids, &id_len, previous.focus_visible_id);
        appendOptionalObjectId(&ids, &id_len, next.focus_visible_id);
    }
    if (previous.hovered_id != next.hovered_id) {
        appendOptionalObjectId(&ids, &id_len, previous.hovered_id);
        appendOptionalObjectId(&ids, &id_len, next.hovered_id);
    }
    if (previous.pressed_id != next.pressed_id) {
        appendOptionalObjectId(&ids, &id_len, previous.pressed_id);
        appendOptionalObjectId(&ids, &id_len, next.pressed_id);
    }

    var bounds: ?geometry.RectF = null;
    for (ids[0..id_len]) |maybe_id| {
        const id = maybe_id orelse continue;
        const index = widgetIndexById(layout, id) orelse continue;
        const node = layout.nodes[index];
        const base = widgetWithFrame(node.widget, node.frame);
        const previous_widget = widgetWithRenderState(base, previous);
        const next_widget = widgetWithRenderState(base, next);
        if (widgetStatesEqual(previous_widget.state, next_widget.state)) continue;
        bounds = unionOptionalBounds(bounds, widgetClippedDirtyBounds(layout, index, widgetRenderStatePaintChangeBounds(previous_widget, next_widget, tokens)));
    }
    return bounds;
}

fn appendOptionalObjectId(output: []?ObjectId, len: *usize, maybe_id: ?ObjectId) void {
    const id = maybe_id orelse return;
    if (id == 0) return;
    for (output[0..len.*]) |existing| {
        if (existing != null and existing.? == id) return;
    }
    if (len.* >= output.len) return;
    output[len.*] = id;
    len.* += 1;
}

fn widgetFullPaintBounds(node: WidgetLayoutNode, tokens: DesignTokens) geometry.RectF {
    return widgetFullPaintBoundsWithTransform(node, widgetTransform(node.widget), tokens);
}

fn widgetFullPaintBoundsWithTransform(node: WidgetLayoutNode, transform: Affine, tokens: DesignTokens) geometry.RectF {
    var bounds = node.frame.normalized();
    if (widgetFrameStrokeBounds(node.widget, tokens)) |stroke_bounds| {
        bounds = geometry.RectF.unionWith(bounds, stroke_bounds.normalized());
    }
    if (widgetShadowPaintBounds(node.widget, tokens)) |shadow_bounds| {
        bounds = geometry.RectF.unionWith(bounds, shadow_bounds.normalized());
    }
    if (widgetBackdropBlurPaintBounds(node.widget, tokens)) |blur_bounds| {
        bounds = geometry.RectF.unionWith(bounds, blur_bounds.normalized());
    }
    return transform.transformRect(bounds).normalized();
}

fn widgetVisibleSubtreeFullPaintBounds(layout: WidgetLayoutTree, root_index: usize, tokens: DesignTokens) ?geometry.RectF {
    if (root_index >= layout.nodes.len) return null;

    const root_depth = layout.nodes[root_index].depth;
    var bounds: ?geometry.RectF = null;
    var hidden_depth: ?usize = null;
    var index = root_index;
    while (index < layout.nodes.len) : (index += 1) {
        const node = layout.nodes[index];
        if (index != root_index and node.depth <= root_depth) break;
        if (hidden_depth) |depth| {
            if (node.depth > depth) continue;
            hidden_depth = null;
        }
        if (node.widget.semantics.hidden) {
            hidden_depth = node.depth;
            continue;
        }
        bounds = unionOptionalBounds(bounds, widgetClippedDirtyBounds(layout, index, widgetFullPaintBoundsWithTransform(node, widgetAccumulatedTransform(layout, index), tokens)));
    }
    return bounds;
}

fn widgetAccumulatedTransform(layout: WidgetLayoutTree, node_index: usize) Affine {
    var indices: [max_widget_depth]usize = undefined;
    var len: usize = 0;
    var current: ?usize = node_index;
    while (current) |index| {
        if (index >= layout.nodes.len or len >= indices.len) break;
        indices[len] = index;
        len += 1;
        current = layout.nodes[index].parent_index;
    }

    var transform = Affine.identity();
    while (len > 0) {
        len -= 1;
        transform = transform.multiply(widgetTransform(layout.nodes[indices[len]].widget));
    }
    return transform;
}

fn widgetChangedClippedDirtyBounds(
    previous: WidgetLayoutTree,
    previous_index: usize,
    next: WidgetLayoutTree,
    next_index: usize,
    bounds: ?geometry.RectF,
) ?geometry.RectF {
    return unionOptionalBounds(
        widgetClippedDirtyBounds(previous, previous_index, bounds),
        widgetClippedDirtyBounds(next, next_index, bounds),
    );
}

fn widgetClippedDirtyBounds(layout: WidgetLayoutTree, node_index: usize, bounds: ?geometry.RectF) ?geometry.RectF {
    if (node_index >= layout.nodes.len) return null;
    if (isWidgetHiddenInAncestors(layout, node_index)) return null;

    var clipped = (bounds orelse return null).normalized();
    var current = layout.nodes[node_index].parent_index;
    while (current) |parent_index| {
        if (parent_index >= layout.nodes.len) return null;
        const parent = layout.nodes[parent_index];
        if (widgetClipsContent(parent.widget)) {
            clipped = geometry.RectF.intersection(clipped, parent.frame.normalized());
            if (clipped.isEmpty()) return null;
        }
        current = parent.parent_index;
    }
    return clipped;
}

fn widgetPaintChangeBounds(previous: Widget, next: Widget, tokens: DesignTokens) ?geometry.RectF {
    var bounds = unionOptionalBounds(previous.frame, next.frame);
    if (widgetFrameStrokePaintChanged(previous, next, tokens)) {
        bounds = unionOptionalBounds(bounds, widgetFrameStrokeBounds(previous, tokens));
        bounds = unionOptionalBounds(bounds, widgetFrameStrokeBounds(next, tokens));
    }
    bounds = unionOptionalBounds(bounds, widgetFocusPaintBounds(previous, tokens));
    bounds = unionOptionalBounds(bounds, widgetFocusPaintBounds(next, tokens));
    bounds = unionOptionalBounds(bounds, widgetBackdropBlurPaintBounds(previous, tokens));
    bounds = unionOptionalBounds(bounds, widgetBackdropBlurPaintBounds(next, tokens));
    return bounds;
}

fn widgetRenderStatePaintChangeBounds(previous: Widget, next: Widget, tokens: DesignTokens) ?geometry.RectF {
    var bounds: ?geometry.RectF = null;
    if (widgetFrameStrokePaintChanged(previous, next, tokens)) {
        bounds = unionOptionalBounds(bounds, widgetFrameStrokeBounds(previous, tokens));
        bounds = unionOptionalBounds(bounds, widgetFrameStrokeBounds(next, tokens));
    }
    if (previous.state.focused != next.state.focused) {
        bounds = unionOptionalBounds(bounds, widgetFocusPaintBounds(previous, tokens));
        bounds = unionOptionalBounds(bounds, widgetFocusPaintBounds(next, tokens));
    }
    if (previous.state.hovered != next.state.hovered or previous.state.pressed != next.state.pressed) {
        bounds = unionOptionalBounds(bounds, widgetInteractiveStatePaintBounds(previous, tokens));
        bounds = unionOptionalBounds(bounds, widgetInteractiveStatePaintBounds(next, tokens));
    }
    return bounds;
}

fn widgetFrameStrokePaintChanged(previous: Widget, next: Widget, tokens: DesignTokens) bool {
    return widgetFrameStrokeWidth(previous, tokens) != widgetFrameStrokeWidth(next, tokens) or
        !optionalColorsEqual(previous.style.border, next.style.border);
}

fn widgetFrameStrokeBounds(widget: Widget, tokens: DesignTokens) ?geometry.RectF {
    const width = widgetFrameStrokeWidth(widget, tokens);
    if (width <= 0) return null;
    return strokeBounds(widgetChromeStrokeRect(widget, tokens), width);
}

fn widgetFocusPaintBounds(widget: Widget, tokens: DesignTokens) ?geometry.RectF {
    if (!widget.state.focused or widgetFocusStrokeWidth(widget, tokens) <= 0) return null;
    return strokeBounds(widgetFocusPaintRect(widget, tokens), tokens.stroke.focus);
}

fn widgetInteractiveStatePaintBounds(widget: Widget, tokens: DesignTokens) geometry.RectF {
    return switch (widget.kind) {
        .checkbox => checkboxWidgetBoxRect(widget, tokens),
        .radio => radioWidgetCircleRect(widget, tokens),
        .switch_control, .toggle => toggleWidgetTrackRect(widget, tokens),
        .slider => sliderWidgetKnobRect(widget, tokens),
        else => widget.frame,
    };
}

fn widgetChromeStrokeRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    return switch (widget.kind) {
        .checkbox => checkboxWidgetBoxRect(widget, tokens),
        .radio => radioWidgetCircleRect(widget, tokens),
        .switch_control, .toggle => toggleWidgetTrackRect(widget, tokens),
        .slider => sliderWidgetKnobRect(widget, tokens),
        else => widget.frame,
    };
}

fn widgetFocusPaintRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    return switch (widget.kind) {
        .checkbox => checkboxWidgetBoxRect(widget, tokens),
        .radio => radioWidgetCircleRect(widget, tokens),
        .switch_control, .toggle => toggleWidgetTrackRect(widget, tokens),
        .slider => sliderWidgetKnobRect(widget, tokens),
        else => widget.frame,
    };
}

fn widgetFrameStrokeWidth(widget: Widget, tokens: DesignTokens) f32 {
    return switch (widget.kind) {
        .accordion, .alert, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover, .menu_surface, .dropdown_menu => controlStrokeWidth(widget, surfaceControlVisualTokens(widget, tokens), tokens.stroke.hairline),
        .button, .toggle_button, .icon_button => if (widget.state.focused) tokens.stroke.focus else buttonStrokeWidth(widget, tokens),
        .select => if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, selectControlVisualTokens(tokens), tokens.stroke.regular),
        .input, .text_field, .search_field, .combobox, .textarea => if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, textInputControlVisualTokens(widget, tokens), tokens.stroke.regular),
        .segmented_control => if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, selectionControlVisualTokens(widget, tokens), tokens.stroke.regular),
        .data_cell => if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, listItemControlVisualTokens(widget, tokens), tokens.stroke.hairline),
        .checkbox, .radio, .switch_control, .toggle, .slider => if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, selectionControlVisualTokens(widget, tokens), tokens.stroke.regular),
        .avatar, .badge => controlStrokeWidth(widget, componentControlVisualTokens(widget, tokens), tokens.stroke.hairline),
        .list_item, .menu_item => if (widget.state.focused) tokens.stroke.focus else 0,
        else => 0,
    };
}

fn widgetFocusStrokeWidth(widget: Widget, tokens: DesignTokens) f32 {
    return switch (widget.kind) {
        .button,
        .toggle_button,
        .icon_button,
        .select,
        .input,
        .text_field,
        .search_field,
        .combobox,
        .textarea,
        .menu_item,
        .list_item,
        .data_cell,
        .segmented_control,
        .checkbox,
        .radio,
        .switch_control,
        .toggle,
        .slider,
        => tokens.stroke.focus,
        else => 0,
    };
}

fn widgetShadowPaintBounds(widget: Widget, tokens: DesignTokens) ?geometry.RectF {
    const token = switch (widget.kind) {
        .accordion, .bubble, .resizable, .panel, .tooltip => tokens.shadow.sm,
        .dialog, .drawer, .sheet, .popover, .menu_surface, .dropdown_menu => tokens.shadow.md,
        else => return null,
    };
    if (token.y == 0 and token.blur == 0 and token.spread == 0) return null;
    return shadowBounds(.{
        .rect = widget.frame,
        .radius = widgetShadowRadius(widget, tokens),
        .offset = .{ .dx = 0, .dy = token.y },
        .blur = token.blur,
        .spread = token.spread,
        .color = tokens.colors.shadow,
    });
}

fn widgetBackdropBlurPaintBounds(widget: Widget, tokens: DesignTokens) ?geometry.RectF {
    const radius = widgetBackdropBlur(widget, tokens);
    if (radius <= 0) return null;
    return widget.frame.normalized().inflate(geometry.InsetsF.all(radius));
}

fn widgetShadowRadius(widget: Widget, tokens: DesignTokens) Radius {
    return switch (widget.kind) {
        .dialog, .drawer, .popover => controlRadius(widget, surfaceControlVisualTokens(widget, tokens), tokens.radius.xl),
        .sheet => controlRadius(widget, surfaceControlVisualTokens(widget, tokens), tokens.radius.lg),
        .accordion, .alert, .bubble, .card, .resizable, .panel, .menu_surface, .dropdown_menu => controlRadius(widget, surfaceControlVisualTokens(widget, tokens), tokens.radius.lg),
        .tooltip => controlRadius(widget, surfaceControlVisualTokens(widget, tokens), tokens.radius.md),
        else => Radius.all(0),
    };
}

fn widgetStatesEqual(a: WidgetState, b: WidgetState) bool {
    return a.hovered == b.hovered and
        a.pressed == b.pressed and
        a.focused == b.focused and
        a.disabled == b.disabled and
        a.selected == b.selected and
        a.expanded == b.expanded and
        a.required == b.required and
        a.read_only == b.read_only and
        a.invalid == b.invalid;
}

fn widgetLayoutStylesEqual(a: WidgetLayoutStyle, b: WidgetLayoutStyle) bool {
    return insetsEqual(a.padding, b.padding) and
        a.gap == b.gap and
        a.grow == b.grow and
        a.main_alignment == b.main_alignment and
        a.cross_alignment == b.cross_alignment and
        a.clip_content == b.clip_content and
        a.columns == b.columns and
        a.virtualized == b.virtualized and
        a.virtual_item_extent == b.virtual_item_extent and
        a.virtual_overscan == b.virtual_overscan and
        sizesEqual(a.min_size, b.min_size);
}

fn widgetStylesEqual(a: WidgetStyle, b: WidgetStyle) bool {
    return optionalColorsEqual(a.background, b.background) and
        optionalColorsEqual(a.foreground, b.foreground) and
        optionalColorsEqual(a.accent, b.accent) and
        optionalColorsEqual(a.accent_foreground, b.accent_foreground) and
        optionalColorsEqual(a.border, b.border) and
        optionalColorsEqual(a.focus_ring, b.focus_ring) and
        optionalF32Equal(a.radius, b.radius) and
        optionalF32Equal(a.stroke_width, b.stroke_width);
}

fn widgetSemanticsEqual(a: WidgetSemantics, b: WidgetSemantics) bool {
    return a.role == b.role and
        std.mem.eql(u8, a.label, b.label) and
        optionalF32Equal(a.value, b.value) and
        a.list_item_index == b.list_item_index and
        a.list_item_count == b.list_item_count and
        widgetActionsEqual(a.actions, b.actions) and
        a.hidden == b.hidden and
        a.focusable == b.focusable;
}

fn widgetActionsEqual(a: WidgetActions, b: WidgetActions) bool {
    return a.focus == b.focus and
        a.press == b.press and
        a.toggle == b.toggle and
        a.increment == b.increment and
        a.decrement == b.decrement and
        a.set_text == b.set_text and
        a.set_selection == b.set_selection and
        a.select == b.select and
        a.drag == b.drag and
        a.drop_files == b.drop_files and
        a.dismiss == b.dismiss;
}
fn unionOptionalBounds(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    if (a) |rect_a| {
        if (b) |rect_b| return geometry.RectF.unionWith(rect_a.normalized(), rect_b.normalized());
        return rect_a.normalized();
    }
    if (b) |rect_b| return rect_b.normalized();
    return null;
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}

fn floorVirtualIndex(value: f32) usize {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@floor(value));
}

fn ceilVirtualIndex(value: f32) usize {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@ceil(value));
}

fn nonZeroObjectId(id: ObjectId) ?ObjectId {
    return if (id == 0) null else id;
}
