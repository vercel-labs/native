const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const text_spans_model = @import("text_spans.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const equality_model = @import("equality.zig");
const widget_tree = @import("widget_tree.zig");
const widget_layout = @import("widget_layout.zig");
const widget_access = @import("widget_access.zig");
const widget_semantics = @import("widget_semantics.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_text_input = @import("widget_text_input.zig");
const widget_text_select = @import("widget_text_select.zig");
const widget_render_style = @import("widget_render_style.zig");
const widget_render_scroll = @import("widget_render_scroll.zig");
const widget_render_surfaces = @import("widget_render_surfaces.zig");
const widget_render_controls = @import("widget_render_controls.zig");
const icon_model = @import("icons.zig");
const chart_model = @import("chart.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Builder = canvas.Builder;
const Affine = drawing_model.Affine;
const Radius = drawing_model.Radius;
const Fill = drawing_model.Fill;
const Stroke = drawing_model.Stroke;
const Clip = drawing_model.Clip;
const Shadow = drawing_model.Shadow;
const TextWrap = text_model.TextWrap;
const TextAlign = text_model.TextAlign;
const TextLayoutOptions = text_model.TextLayoutOptions;
const DesignTokens = token_model.DesignTokens;
const ControlVisualTokens = token_model.ControlVisualTokens;
const WidgetPaintOrder = widget_tree.WidgetPaintOrder;
const widgetPaintLayer = widget_tree.widgetPaintLayer;
const nextWidgetPaintChild = widget_tree.nextWidgetPaintChild;
const widgetLayoutDirectChildCount = widget_tree.widgetLayoutDirectChildCount;
const nextWidgetLayoutPaintChild = widget_tree.nextWidgetLayoutPaintChild;
const widgetTransform = widget_tree.widgetTransform;
const widgetClipsContent = widget_tree.widgetClipsContent;
const booleanControlSelected = widget_access.booleanControlSelected;
const widgetPlaceholder = widget_text_input.widgetPlaceholder;
const widgetTextInputSize = widget_text_input.widgetTextInputSize;
const widgetTextInputLayoutOptions = widget_text_input.widgetTextInputLayoutOptions;
const widgetTextInputOrigin = widget_text_input.widgetTextInputOrigin;
const widgetTextInputClipRect = widget_text_input.widgetTextInputClipRect;
const widgetTextInputInset = widget_text_input.widgetTextInputInset;
const widgetButtonTextSize = widget_metrics.widgetButtonTextSize;
const widgetBodyTextSize = widget_metrics.widgetBodyTextSize;
const widgetLabelTextSize = widget_metrics.widgetLabelTextSize;
const widgetLineHeight = widget_metrics.widgetLineHeight;
const widgetTypographySize = widget_metrics.widgetTypographySize;
const widgetButtonInset = widget_metrics.widgetButtonInset;
const widgetControlInset = widget_metrics.widgetControlInset;
const widgetSizedDensityValue = widget_metrics.widgetSizedDensityValue;
const widgetSizedTokenValue = widget_metrics.widgetSizedTokenValue;
const widgetControlHeight = widget_metrics.widgetControlHeight;
const densityValue = widget_metrics.densityValue;
const WidgetKind = widget_model.WidgetKind;
const WidgetState = widget_model.WidgetState;
const WidgetRenderState = widget_model.WidgetRenderState;
const WidgetSize = widget_model.WidgetSize;
const Widget = widget_model.Widget;
const estimateTextWidth = text_model.estimateTextWidth;
const layoutTextCaretRect = text_model.layoutTextCaretRect;
const affinesEqual = equality_model.affinesEqual;
pub const textSelectionFillColor = widget_render_style.textSelectionFillColor;
pub const colorWithAlpha = widget_render_style.colorWithAlpha;
const colorFill = widget_render_style.colorFill;
const widgetBackgroundFill = widget_render_style.widgetBackgroundFill;
const widgetAccentFill = widget_render_style.widgetAccentFill;
const widgetBorderFill = widget_render_style.widgetBorderFill;
const widgetBackgroundColor = widget_render_style.widgetBackgroundColor;
const widgetAccentColor = widget_render_style.widgetAccentColor;
const widgetBorderColor = widget_render_style.widgetBorderColor;
const widgetForegroundColor = widget_render_style.widgetForegroundColor;
const widgetAccentForegroundColor = widget_render_style.widgetAccentForegroundColor;
const widgetRadius = widget_render_style.widgetRadius;
pub const controlRadius = widget_render_style.controlRadius;
pub const controlStrokeWidth = widget_render_style.controlStrokeWidth;
pub const selectControlVisualTokens = widget_render_style.selectControlVisualTokens;
pub const textInputControlVisualTokens = widget_render_style.textInputControlVisualTokens;
const alertControlVisualTokens = widget_render_style.alertControlVisualTokens;
const cardControlVisualTokens = widget_render_style.cardControlVisualTokens;
const dialogControlVisualTokens = widget_render_style.dialogControlVisualTokens;
const drawerControlVisualTokens = widget_render_style.drawerControlVisualTokens;
const sheetControlVisualTokens = widget_render_style.sheetControlVisualTokens;
pub const listItemControlVisualTokens = widget_render_style.listItemControlVisualTokens;
pub const selectionControlVisualTokens = widget_render_style.selectionControlVisualTokens;
pub const surfaceControlVisualTokens = widget_render_style.surfaceControlVisualTokens;
pub const componentControlVisualTokens = widget_render_style.componentControlVisualTokens;
const componentPillRadius = widget_render_style.componentPillRadius;
const badgeBackgroundColor = widget_render_style.badgeBackgroundColor;
const badgeBorderColor = widget_render_style.badgeBorderColor;
const badgeTextColor = widget_render_style.badgeTextColor;
const badgeStrokeWidth = widget_render_style.badgeStrokeWidth;
pub const buttonStrokeWidth = widget_render_style.buttonStrokeWidth;
pub const transparentColor = widget_render_style.transparentColor;
pub const checkboxWidgetBoxRect = widget_render_controls.checkboxWidgetBoxRect;
pub const radioWidgetCircleRect = widget_render_controls.radioWidgetCircleRect;
pub const toggleWidgetTrackRect = widget_render_controls.toggleWidgetTrackRect;
pub const sliderWidgetKnobRect = widget_render_controls.sliderWidgetKnobRect;

const max_widget_depth: usize = 32;

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

/// Frame-lifetime scratch for chart path elements: `.chart` widgets build
/// their line/band `PathElement`s here at emit time (unlike icons, whose
/// elements are comptime-static), and emitted commands slice into it. The
/// event loop is single-threaded and the runtime copies the display list
/// into per-view storage within the same emit call stack, so one
/// threadlocal buffer per frame is sound — reset at each emit entry
/// point. Sized to mirror the runtime's per-view path-element budget
/// (`canvas_limits.max_canvas_path_elements_per_view`; a lockstep test
/// keeps them equal), so overflow here fails exactly where the per-view
/// copy would have refused anyway — loudly, by budget name.
threadlocal var chart_frame_path_elements: [chart_model.max_chart_path_elements_per_frame]drawing_model.PathElement = undefined;
threadlocal var chart_frame_path_len: usize = 0;

fn resetChartFramePathScratch() void {
    chart_frame_path_len = 0;
}

fn allocChartPathElements(count: usize) Error![]drawing_model.PathElement {
    if (chart_frame_path_len + count > chart_frame_path_elements.len) return error.ChartPathElementListFull;
    const start = chart_frame_path_len;
    chart_frame_path_len += count;
    return chart_frame_path_elements[start .. start + count];
}

pub fn emitWidgetTree(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    resetChartFramePathScratch();
    try emitWidgetDepth(builder, widget, tokens, 0);
}

pub fn emitWidgetLayout(builder: *Builder, layout: anytype, tokens: DesignTokens) Error!void {
    return emitWidgetLayoutWithState(builder, layout, tokens, .{});
}

pub fn emitWidgetLayoutWithState(builder: *Builder, layout: anytype, tokens: DesignTokens, state: WidgetRenderState) Error!void {
    resetChartFramePathScratch();
    try emitWidgetLayoutChildren(builder, layout, null, tokens, state);
    try emitWidgetLayoutAnchored(builder, layout, tokens, state);
}

/// The late z-pass for anchored floating surfaces: they are skipped by
/// the in-tree walk above and emitted here LAST, at the top level, so no
/// ancestor scroll/clip region crops them (window-clipped, not
/// parent-clipped) and they paint above everything in the tree. Node
/// order is tree order, so a nested anchored surface (submenu) paints
/// above the surface it hangs from. Ancestor hiding still applies.
fn emitWidgetLayoutAnchored(builder: *Builder, layout: anytype, tokens: DesignTokens, state: WidgetRenderState) Error!void {
    for (layout.nodes, 0..) |node, index| {
        if (!widget_tree.widgetIsAnchored(node.widget)) continue;
        if (widget_tree.isWidgetHiddenInAncestors(layout, index)) continue;
        try emitWidgetLayoutNode(builder, layout, index, tokens, state);
    }
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
        .button, .toggle_button => try widget_render_controls.emitButtonWidget(builder, paint_widget, tokens),
        .icon_button => try widget_render_controls.emitIconButtonWidget(builder, paint_widget, tokens),
        .select => try widget_render_controls.emitSelectWidget(builder, paint_widget, tokens),
        .input, .text_field, .textarea => try widget_render_controls.emitTextFieldWidget(builder, paint_widget, tokens),
        .search_field, .combobox => try widget_render_controls.emitSearchFieldWidget(builder, paint_widget, tokens),
        .tooltip => try widget_render_controls.emitTooltipWidget(builder, paint_widget, tokens),
        .menu_item => try widget_render_controls.emitMenuItemWidget(builder, paint_widget, tokens),
        .list_item => try widget_render_controls.emitListItemWidget(builder, paint_widget, tokens),
        .data_cell => try emitDataCellContent(builder, paint_widget, tokens),
        .status_bar => try emitStatusBarWidget(builder, paint_widget, tokens),
        .segmented_control => try widget_render_controls.emitSegmentedControlWidget(builder, paint_widget, tokens),
        .checkbox => try widget_render_controls.emitCheckboxWidget(builder, paint_widget, tokens),
        .radio => try widget_render_controls.emitRadioWidget(builder, paint_widget, tokens),
        .switch_control, .toggle => try widget_render_controls.emitToggleWidget(builder, paint_widget, tokens),
        .slider => try widget_render_controls.emitSliderWidget(builder, paint_widget, tokens),
        .progress => try widget_render_controls.emitProgressWidget(builder, paint_widget, tokens),
        .separator => try emitSeparatorWidget(builder, paint_widget, tokens),
        .skeleton => try emitSkeletonWidget(builder, paint_widget, tokens),
        .spinner => try emitSpinnerWidget(builder, paint_widget, tokens),
        .chart => try emitChartWidget(builder, paint_widget, tokens),
    }
}

/// A table cell draws its chrome (fill, border, focus ring) and then its
/// text: span-carrying cells (markdown tables) draw inline-styled runs
/// through the span paragraph emitter, classic cells keep the single-line
/// path byte-identical.
fn emitDataCellContent(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    if (widget.spans.len == 0) return widget_render_controls.emitDataCellWidget(builder, widget, tokens);
    _ = try widget_render_controls.emitDataCellWidgetChrome(builder, widget, tokens);
    try emitTextSpansWidget(builder, widget, tokens);
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
    layout: anytype,
    parent_index: ?usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
) Error!void {
    const child_count = widgetLayoutDirectChildCount(layout, parent_index);
    var emitted: usize = 0;
    var previous: ?WidgetPaintOrder = null;
    while (emitted < child_count) : (emitted += 1) {
        const child_index = nextWidgetLayoutPaintChild(layout, parent_index, tokens, previous) orelse return;
        // Anchored floating children paint in the late z-pass
        // (`emitWidgetLayoutAnchored`), never in tree position.
        if (!widget_tree.widgetIsAnchored(layout.nodes[child_index].widget)) {
            try emitWidgetLayoutNode(builder, layout, child_index, tokens, state);
        }
        previous = .{ .layer = widgetPaintLayer(layout.nodes[child_index].widget, tokens), .index = child_index };
    }
}

fn emitWidgetLayoutNode(
    builder: *Builder,
    layout: anytype,
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
    layout: anytype,
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
            // Native scroll drivers own the (OS overlay) scrollbar.
            if (!paint_widget.native_scroll) {
                try widget_render_scroll.emitScrollViewScrollbar(builder, paint_widget.frame, widgetScrollSemantics(layout, node_index).metrics, tokens, paint_widget.id);
            }
            return;
        },
        .alert => try widget_render_surfaces.emitAlertWidgetChrome(builder, paint_widget, tokens),
        .card => try widget_render_surfaces.emitCardWidgetChrome(builder, paint_widget, tokens),
        .dialog => try widget_render_surfaces.emitDialogSurfaceWidgetChrome(builder, paint_widget, tokens),
        .drawer => try widget_render_surfaces.emitDrawerSurfaceWidgetChrome(builder, paint_widget, tokens),
        .sheet => try widget_render_surfaces.emitSheetSurfaceWidgetChrome(builder, paint_widget, tokens),
        .accordion, .bubble, .resizable, .panel => try widget_render_surfaces.emitPanelWidgetChrome(builder, paint_widget, tokens),
        .popover => try widget_render_surfaces.emitPopoverWidgetChrome(builder, paint_widget, tokens),
        .menu_surface, .dropdown_menu => try widget_render_surfaces.emitMenuSurfaceWidgetChrome(builder, paint_widget, tokens),
        .text => try emitTextWidget(builder, paint_widget, tokens),
        .icon => try emitIconWidget(builder, paint_widget, tokens),
        .image => try emitImageWidget(builder, paint_widget),
        .avatar => try emitAvatarWidget(builder, paint_widget, tokens),
        .badge => try emitBadgeWidget(builder, paint_widget, tokens),
        .button, .toggle_button => try widget_render_controls.emitButtonWidget(builder, paint_widget, tokens),
        .icon_button => try widget_render_controls.emitIconButtonWidget(builder, paint_widget, tokens),
        .select => try widget_render_controls.emitSelectWidget(builder, paint_widget, tokens),
        .input, .text_field, .textarea => try widget_render_controls.emitTextFieldWidget(builder, paint_widget, tokens),
        .search_field, .combobox => try widget_render_controls.emitSearchFieldWidget(builder, paint_widget, tokens),
        .tooltip => try widget_render_controls.emitTooltipWidget(builder, paint_widget, tokens),
        .menu_item => try widget_render_controls.emitMenuItemWidget(builder, paint_widget, tokens),
        .list_item => try widget_render_controls.emitListItemWidget(builder, paint_widget, tokens),
        .data_cell => try emitDataCellContent(builder, paint_widget, tokens),
        .status_bar => try emitStatusBarWidget(builder, paint_widget, tokens),
        .segmented_control => try widget_render_controls.emitSegmentedControlWidget(builder, paint_widget, tokens),
        .checkbox => try widget_render_controls.emitCheckboxWidget(builder, paint_widget, tokens),
        .radio => try widget_render_controls.emitRadioWidget(builder, paint_widget, tokens),
        .switch_control, .toggle => try widget_render_controls.emitToggleWidget(builder, paint_widget, tokens),
        .slider => try widget_render_controls.emitSliderWidget(builder, paint_widget, tokens),
        .progress => try widget_render_controls.emitProgressWidget(builder, paint_widget, tokens),
        .separator => try emitSeparatorWidget(builder, paint_widget, tokens),
        .skeleton => try emitSkeletonWidget(builder, paint_widget, tokens),
        .spinner => try emitSpinnerWidget(builder, paint_widget, tokens),
        .chart => try emitChartWidget(builder, paint_widget, tokens),
    }

    try emitWidgetLayoutClippedChildren(builder, layout, node_index, tokens, state, paint_widget);
}

fn emitWidgetLayoutScrollableChildren(
    builder: *Builder,
    layout: anytype,
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
    // Native scroll drivers own the (OS overlay) scrollbar.
    if (!widget.native_scroll) {
        try widget_render_scroll.emitScrollViewScrollbar(builder, widget.frame, widgetScrollSemantics(layout, parent_index).metrics, tokens, widget.id);
    }
}

fn widgetOpacity(widget: Widget) f32 {
    return std.math.clamp(widget.opacity, 0, 1);
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

pub fn widgetBackdropBlur(widget: Widget, tokens: DesignTokens) f32 {
    const explicit = nonNegative(widget.backdrop_blur);
    if (explicit > 0) return explicit;
    if (widget.backdrop_blur_token) |token| return nonNegative(tokens.blur.value(token));
    return 0;
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
    try widget_render_surfaces.emitAlertWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitCardWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitCardWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitDialogSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitDialogSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitDrawerSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitDrawerSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitSheetSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitSheetSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitPanelWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitPanelWidgetChrome(builder, widget, tokens);
    if (!accordionChildrenVisible(widget)) return;
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitPopoverWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitPopoverWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitMenuSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitMenuSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitScrollViewWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try builder.pushClip(.{ .id = widgetPartId(widget.id, 1), .rect = widget.frame });
    try emitWidgetChildren(builder, widget.children, tokens, depth);
    try builder.popClip();
    // Native scroll drivers own the (OS overlay) scrollbar.
    if (!widget.native_scroll) {
        try widget_render_scroll.emitScrollViewScrollbar(builder, widget.frame, widget_render_scroll.widgetScrollMetricsForWidget(widget, tokens), tokens, widget.id);
    }
}

fn emitWidgetClippedChildren(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    if (widget.layout.clip_content) try builder.pushClip(widgetContentClip(widget, tokens));
    try emitWidgetChildren(builder, widget.children, tokens, depth);
    if (widget.layout.clip_content) try builder.popClip();
}

fn widgetScrollSemantics(layout: anytype, node_index: usize) widget_semantics.WidgetScrollSemantics {
    return widget_semantics.widgetScrollSemantics(layout, node_index, widget_layout.virtualWidgetScrollContentExtent);
}

fn emitWidgetLayoutClippedChildren(
    builder: *Builder,
    layout: anytype,
    parent_index: usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
    widget: Widget,
) Error!void {
    if (widget.layout.clip_content) try builder.pushClip(widgetContentClip(widget, tokens));
    try emitWidgetLayoutChildren(builder, layout, parent_index, tokens, state);
    if (widget.layout.clip_content) try builder.popClip();
}

fn emitTextWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    if (widget.spans.len > 0) return emitTextSpansWidget(builder, widget, tokens);
    // Empty text leaves are hit/semantics-only: paragraph link hotspots
    // and composite press overlays (timeline items) draw nothing.
    if (widget.text.len == 0) return;
    try emitStaticTextSelection(builder, widget, tokens);
    const text_size = widgetBodyTextSize(widget, tokens);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 1),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, textOrigin(widget.frame, text_size, 0)),
        .color = widgetForegroundColor(widget, tokens, tokens.colors.text),
        .text = widget.text,
        .text_layout = .{
            .max_width = textWrapMaxWidth(tokens, widget.frame.width),
            .line_height = text_size * 1.25,
            .wrap = .word,
            .alignment = widget.text_alignment,
            .measure = tokens.text_measure,
        },
    });
}

/// Wrap budget for text painted inside a pixel-snapped frame. Geometry
/// snapping (`emitWidgetDepthContent`'s `pixelSnapGeometryRect`) can shave
/// up to half a device pixel off the layout frame that intrinsic sizing
/// measured with the exact same metrics — enough to word-wrap an
/// exact-fit line ("Sort" painting as "Sor"/"t"). Hand the shaved
/// quantum back to the wrap so snapping never changes line breaks;
/// glyph origins still snap independently via `pixelSnapTextPoint`.
fn textWrapMaxWidth(tokens: DesignTokens, width: f32) f32 {
    if (!tokens.pixel_snap.geometry) return width;
    const scale = pixelSnapScale(tokens) orelse return width;
    return width + 0.5 / scale;
}

/// Static text selection highlight: fill rects behind the selected lines
/// of a `.text` widget (plain or span paragraph). Command ids are hashed
/// per line ordinal like span runs, so retained diffing stays stable.
fn emitStaticTextSelection(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const range = widget_access.widgetTextSelectionRange(widget) orelse return;
    if (range.isCollapsed(widget.text.len)) return;
    var rect_buffer: [widget_text_select.max_static_text_layout_lines]text_model.TextSelectionRect = undefined;
    const rects = widget_text_select.staticTextSelectionRects(widget, tokens, range, &rect_buffer);
    for (rects, 0..) |selection, ordinal| {
        try builder.fillRoundedRect(.{
            .id = textSelectionCommandId(widget.id, ordinal),
            .rect = pixelSnapGeometryRect(tokens, selection.rect),
            .radius = Radius.all(tokens.radius.sm),
            .fill = .{ .color = textSelectionFillColor(widget, tokens) },
        });
    }
}

/// Draw a span paragraph: one single-line text command per laid-out run
/// plus thin fill rects for underline/strikethrough decorations. Runs and
/// decorations get stable hashed command ids derived from the widget id
/// and their ordinal, so retained diffing works across frames.
fn emitTextSpansWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const content = widget.frame.inset(widget.layout.padding);
    var runs: [text_spans_model.max_text_span_runs_per_paragraph]text_spans_model.TextSpanRun = undefined;
    const layout = text_spans_model.layoutTextSpans(
        widget.spans,
        widget_metrics.widgetTextSpanLayoutOptions(widget, tokens, textWrapMaxWidth(tokens, content.width)),
        &runs,
    );

    // Span background highlights (intra-line diff emphasis): one
    // full-line-height rect per run, the same geometry selection rects
    // use, painted before selection and glyphs. Edge-snapped rects of
    // adjacent runs share their boundary, so equal backgrounds abut
    // without seams.
    for (layout.runs, 0..) |run, ordinal| {
        if (run.text.len == 0) continue;
        const background = widget.spans[run.span_index].background orelse continue;
        const bounds = text_spans_model.textSpanRunBounds(layout, run);
        try builder.fillRect(.{
            .id = textSpanBackgroundCommandId(widget.id, ordinal),
            .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(
                content.x + bounds.x,
                content.y + bounds.y,
                bounds.width,
                bounds.height,
            )),
            .fill = colorFill(text_spans_model.textSpanColorValue(tokens.colors, background)),
        });
    }

    try emitStaticTextSelection(builder, widget, tokens);

    var decoration_ordinal: usize = 0;
    for (layout.runs, 0..) |run, ordinal| {
        if (run.text.len == 0) continue;
        const span = widget.spans[run.span_index];
        const is_link = span.link.len > 0;
        const color = if (span.color) |ref|
            text_spans_model.textSpanColorValue(tokens.colors, ref)
        else if (is_link)
            widgetForegroundColor(widget, tokens, tokens.colors.accent)
        else
            widgetForegroundColor(widget, tokens, tokens.colors.text);
        const origin = pixelSnapTextPoint(tokens, geometry.PointF.init(content.x + run.x, content.y + run.baseline));
        try builder.drawText(.{
            .id = textSpanRunCommandId(widget.id, ordinal),
            .font_id = run.font_id,
            .size = run.size,
            .origin = origin,
            .color = color,
            .text = run.text,
        });

        const thickness = @max(1, tokens.stroke.hairline);
        if (span.underline or is_link) {
            try builder.fillRect(.{
                .id = textSpanDecorationCommandId(widget.id, decoration_ordinal),
                .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(
                    content.x + run.x,
                    content.y + run.baseline + @max(1, run.size * 0.1),
                    run.width,
                    thickness,
                )),
                .fill = colorFill(color),
            });
            decoration_ordinal += 1;
        }
        if (span.strikethrough) {
            try builder.fillRect(.{
                .id = textSpanDecorationCommandId(widget.id, decoration_ordinal),
                .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(
                    content.x + run.x,
                    content.y + run.baseline - run.size * 0.3,
                    run.width,
                    thickness,
                )),
                .fill = colorFill(color),
            });
            decoration_ordinal += 1;
        }
    }
}

pub fn textSpanRunCommandId(widget_id: ObjectId, ordinal: usize) ObjectId {
    return textSpanCommandId(0x5eed_59a2_0000_0001, widget_id, ordinal);
}

pub fn textSpanDecorationCommandId(widget_id: ObjectId, ordinal: usize) ObjectId {
    return textSpanCommandId(0x5eed_59a2_0000_0002, widget_id, ordinal);
}

pub fn textSpanBackgroundCommandId(widget_id: ObjectId, ordinal: usize) ObjectId {
    return textSpanCommandId(0x5eed_59a2_0000_0004, widget_id, ordinal);
}

pub fn textSelectionCommandId(widget_id: ObjectId, ordinal: usize) ObjectId {
    return textSpanCommandId(0x5eed_59a2_0000_0003, widget_id, ordinal);
}

fn textSpanCommandId(seed: u64, widget_id: ObjectId, ordinal: usize) ObjectId {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(std.mem.asBytes(&widget_id));
    hasher.update(std.mem.asBytes(&@as(u64, ordinal)));
    const value = hasher.final();
    return if (value == 0) 1 else value;
}

fn emitIconWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    // A vector icon name — built-in or app-registered
    // (`icons.registerAppIcons`) — draws crisp parsed paths: `widget.icon`
    // first (the explicit channel), then an icon-name `text`; any other
    // text keeps the historical glyph rendering (apps that put literal
    // glyph characters in `icon.text` are untouched).
    if (widget.icon.len > 0) {
        if (icon_model.resolve(widget.icon)) |icon| {
            return emitVectorIconWidget(builder, widget, tokens, icon);
        }
    }
    if (widget.text.len == 0) return;
    if (icon_model.resolve(widget.text)) |icon| {
        return emitVectorIconWidget(builder, widget, tokens, icon);
    }
    const size = iconGlyphSize(widget, tokens);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 1),
        .font_id = tokens.typography.font_id,
        .size = size,
        .origin = pixelSnapTextPoint(tokens, centeredTextOrigin(widget.frame, widget.text, size, tokens)),
        .color = widgetForegroundColor(widget, tokens, tokens.colors.text),
        .text = widget.text,
    });
}

/// Draw a parsed vector icon fitted (contain, centered) into the widget
/// frame via the shared `emitVectorIcon` helper (buttons and icon
/// buttons draw inline icons through the same code path, so geometry and
/// command shapes agree everywhere). `currentColor` resolves to the
/// widget's foreground color token.
fn emitVectorIconWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, icon: *const icon_model.Icon) Error!void {
    const color = widgetForegroundColor(widget, tokens, tokens.colors.text);
    try widget_render_controls.emitVectorIcon(builder, widget.id, 1, widget.frame, color, icon);
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
            // The render plan flattens the clip stack to rects, so the
            // pill clip above only crops the bounds; the draw's own
            // radius mask is what actually rounds the image.
            .radius = radius,
        });
        try builder.popClip();
    } else if (widget.text.len > 0) {
        const text_size = widgetLabelTextSize(widget, tokens);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, centeredTextOrigin(widget.frame, widget.text, text_size, tokens)),
            .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted),
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, 0, .center, .none, tokens),
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
    const content_color = badgeTextColor(widget, tokens, visual);
    // Inline vector icon: icon-only badges center it (the stepper's
    // completed check, status chips); icon + text draws it before the
    // label. One widget, one tint — and no text glyph outside the bundled
    // face's coverage (the stepper-checkmark tofu fix).
    const icon = if (widget.icon.len > 0) icon_model.resolve(widget.icon) else null;
    if (icon) |resolved| {
        const icon_extent = widget_metrics.widgetBadgeIconExtent(widget, tokens);
        const icon_y = widget.frame.y + (widget.frame.height - icon_extent) * 0.5;
        if (widget.text.len == 0) {
            const icon_frame = geometry.RectF.init(
                widget.frame.x + (widget.frame.width - icon_extent) * 0.5,
                icon_y,
                icon_extent,
                icon_extent,
            );
            try widget_render_controls.emitVectorIcon(builder, widget.id, 4, icon_frame, content_color, resolved);
            return;
        }
        const icon_frame = geometry.RectF.init(widget.frame.x + text_inset, icon_y, icon_extent, icon_extent);
        try widget_render_controls.emitVectorIcon(builder, widget.id, 4, icon_frame, content_color, resolved);
        const shift = icon_extent + widget_metrics.widgetBadgeIconGap(widget, tokens);
        const text_frame = geometry.RectF.init(
            widget.frame.x + shift,
            widget.frame.y,
            @max(1, widget.frame.width - shift),
            widget.frame.height,
        );
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(text_frame, text_size, text_inset)),
            .color = content_color,
            .text = widget.text,
            .text_layout = boundedTextLayout(text_frame, text_size, text_inset, .center, .none, tokens),
        });
        return;
    }
    if (widget.text.len > 0) {
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
            .color = content_color,
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .center, .none, tokens),
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
            .measure = tokens.text_measure,
        },
    });
}

pub fn widgetStatusBarPadding(widget: Widget) geometry.InsetsF {
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

// ------------------------------------------------------------------ chart

/// Draw a `.chart` widget: token-hairline gridlines and baseline first,
/// then each series oldest-to-newest through the vector path pipeline —
/// lines as one `strokePath` (plus an optional translucent baseline-fill
/// `fillPath`), bands as one closed envelope `fillPath`, bars as one
/// pixel-snapped `fillRoundedRect` per value. Series colors resolve from
/// design tokens at emit time, so charts retheme with the palette.
/// Deterministic by construction: geometry is a pure function of the
/// series, the domain, and the frame.
fn emitChartWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const data = widget.chart;
    const plot = widget.frame.inset(widget.layout.padding).normalized();
    if (plot.isEmpty() or plot.width <= 0 or plot.height <= 0) return;
    const domain = chart_model.chartDomain(data);

    const hairline = @max(1, tokens.stroke.hairline);
    if (data.grid_lines > 0) {
        const divisions: f32 = @floatFromInt(@as(usize, data.grid_lines) + 1);
        for (0..data.grid_lines) |index| {
            const y = plot.y + plot.height * @as(f32, @floatFromInt(index + 1)) / divisions;
            try builder.fillRect(.{
                .id = chartCommandId(widget.id, chart_grid_seed, 0, index),
                .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(plot.x, y - hairline * 0.5, plot.width, hairline)),
                .fill = colorFill(tokens.colors.border),
            });
        }
    }
    if (data.baseline) {
        const y = chartMapY(chartBaselineValue(domain), domain, plot, 0);
        try builder.fillRect(.{
            .id = chartCommandId(widget.id, chart_baseline_seed, 0, 0),
            .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(plot.x, y - hairline * 0.5, plot.width, hairline)),
            .fill = colorFill(tokens.colors.border),
        });
    }

    for (data.series, 0..) |series, series_index| {
        if (series.values.len == 0) continue;
        const color = text_spans_model.textSpanColorValue(tokens.colors, series.color);
        switch (series.kind) {
            .bar => try emitChartBars(builder, widget, tokens, plot, domain, series, series_index, color),
            .line => try emitChartLine(builder, widget, plot, domain, series, series_index, color),
            .band => try emitChartBand(builder, widget, plot, domain, series, series_index, color),
        }
    }
}

/// Where fills and bars anchor: zero when the domain includes it, else
/// the nearer domain edge (an all-positive auto domain fills to the plot
/// floor, matching what the data shows).
fn chartBaselineValue(domain: chart_model.ChartDomain) f32 {
    return std.math.clamp(0, domain.min, domain.max);
}

/// Map a value into plot-space y, top-down, with an optional symmetric
/// vertical inset (line strokes inset by half their width so peak ink
/// stays inside the widget frame and its dirty bounds).
fn chartMapY(value: f32, domain: chart_model.ChartDomain, plot: geometry.RectF, inset: f32) f32 {
    const fraction = std.math.clamp((value - domain.min) / domain.span(), 0, 1);
    const height = @max(0, plot.height - inset * 2);
    return plot.maxY() - inset - fraction * height;
}

fn chartMapX(index: usize, count: usize, plot: geometry.RectF, inset: f32) f32 {
    const width = @max(0, plot.width - inset * 2);
    if (count <= 1) return plot.x + inset + width * 0.5;
    return plot.x + inset + width * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count - 1));
}

const chart_stroke_default: f32 = 1.5;
const chart_line_fill_alpha: f32 = 0.18;
const chart_band_fill_alpha: f32 = 0.25;

fn chartStrokeWidth(widget: Widget) f32 {
    const explicit = widget.style.stroke_width orelse chart_stroke_default;
    return if (std.math.isFinite(explicit) and explicit > 0) explicit else chart_stroke_default;
}

fn emitChartBars(
    builder: *Builder,
    widget: Widget,
    tokens: DesignTokens,
    plot: geometry.RectF,
    domain: chart_model.ChartDomain,
    series: chart_model.ChartSeries,
    series_index: usize,
    color: drawing_model.Color,
) Error!void {
    const count = series.values.len;
    const slot = plot.width / @as(f32, @floatFromInt(count));
    const gap = if (count > 1) std.math.clamp(slot * 0.25, 0.5, 4) else 0;
    const bar_width = @max(1, slot - gap);
    const base_value = chartBaselineValue(domain);
    const base_y = chartMapY(base_value, domain, plot, 0);
    for (series.values, 0..) |value, index| {
        if (!std.math.isFinite(value)) continue;
        if (value == base_value) continue;
        const x = plot.x + slot * @as(f32, @floatFromInt(index)) + (slot - bar_width) * 0.5;
        const value_y = chartMapY(value, domain, plot, 0);
        const top = @min(base_y, value_y);
        // A visible tick for near-baseline values: zero draws nothing
        // (zero looks like zero), anything else is at least a hairline.
        const height = @max(1, @abs(base_y - value_y));
        try builder.fillRoundedRect(.{
            .id = chartCommandId(widget.id, chart_bar_seed, series_index, index),
            .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(x, if (value >= base_value) top else base_y, bar_width, height)),
            .radius = Radius.all(@min(1, bar_width * 0.5)),
            .fill = colorFill(color),
        });
    }
}

fn emitChartLine(
    builder: *Builder,
    widget: Widget,
    plot: geometry.RectF,
    domain: chart_model.ChartDomain,
    series: chart_model.ChartSeries,
    series_index: usize,
    color: drawing_model.Color,
) Error!void {
    const stroke_width = chartStrokeWidth(widget);
    const inset = stroke_width * 0.5;
    const points = try chartPolylinePoints(series.values, domain, plot, inset);
    if (points.len == 0) return;
    if (points.len == 1) {
        // A single sample has no line: draw a dot at the point.
        const extent = @max(2, stroke_width * 2);
        try builder.fillRoundedRect(.{
            .id = chartCommandId(widget.id, chart_line_seed, series_index, 0),
            .rect = geometry.RectF.init(points[0].x - extent * 0.5, points[0].y - extent * 0.5, extent, extent),
            .radius = Radius.all(extent * 0.5),
            .fill = colorFill(color),
        });
        return;
    }

    if (series.fill) {
        const base_y = chartMapY(chartBaselineValue(domain), domain, plot, 0);
        const elements = try allocChartPathElements(points.len + 3);
        for (points, 0..) |point, index| {
            elements[index] = .{
                .verb = if (index == 0) .move_to else .line_to,
                .points = .{ point, geometry.PointF.zero(), geometry.PointF.zero() },
            };
        }
        elements[points.len] = .{ .verb = .line_to, .points = .{ geometry.PointF.init(points[points.len - 1].x, base_y), geometry.PointF.zero(), geometry.PointF.zero() } };
        elements[points.len + 1] = .{ .verb = .line_to, .points = .{ geometry.PointF.init(points[0].x, base_y), geometry.PointF.zero(), geometry.PointF.zero() } };
        elements[points.len + 2] = .{ .verb = .close };
        try builder.fillPath(.{
            .id = chartCommandId(widget.id, chart_fill_seed, series_index, 0),
            .elements = elements,
            .fill = colorFill(colorWithAlpha(color, chart_line_fill_alpha)),
        });
    }

    const elements = try allocChartPathElements(points.len);
    for (points, 0..) |point, index| {
        elements[index] = .{
            .verb = if (index == 0) .move_to else .line_to,
            .points = .{ point, geometry.PointF.zero(), geometry.PointF.zero() },
        };
    }
    try builder.strokePath(.{
        .id = chartCommandId(widget.id, chart_line_seed, series_index, 0),
        .elements = elements,
        .stroke = .{
            .fill = colorFill(color),
            .width = stroke_width,
        },
    });
}

fn emitChartBand(
    builder: *Builder,
    widget: Widget,
    plot: geometry.RectF,
    domain: chart_model.ChartDomain,
    series: chart_model.ChartSeries,
    series_index: usize,
    color: drawing_model.Color,
) Error!void {
    const upper = try chartPolylinePoints(series.values, domain, plot, 0);
    if (upper.len < 2) return;
    const base_y = chartMapY(chartBaselineValue(domain), domain, plot, 0);
    const pair_count = @min(series.values.len, series.low.len);
    const lower_count = if (pair_count >= 2) pair_count else 2;
    const elements = try allocChartPathElements(upper.len + lower_count + 1);
    for (upper, 0..) |point, index| {
        elements[index] = .{
            .verb = if (index == 0) .move_to else .line_to,
            .points = .{ point, geometry.PointF.zero(), geometry.PointF.zero() },
        };
    }
    var cursor = upper.len;
    if (pair_count >= 2) {
        // Walk the lower edge back (newest to oldest) to close the
        // envelope. Non-finite lower values clamp to the baseline.
        var index = pair_count;
        while (index > 0) {
            index -= 1;
            const raw = series.low[index];
            const value = if (std.math.isFinite(raw)) raw else chartBaselineValue(domain);
            elements[cursor] = .{ .verb = .line_to, .points = .{
                geometry.PointF.init(chartMapX(index, series.values.len, plot, 0), chartMapY(value, domain, plot, 0)),
                geometry.PointF.zero(),
                geometry.PointF.zero(),
            } };
            cursor += 1;
        }
    } else {
        // No lower edge: fill down to the baseline (a stroke-less
        // line-with-fill).
        elements[cursor] = .{ .verb = .line_to, .points = .{ geometry.PointF.init(upper[upper.len - 1].x, base_y), geometry.PointF.zero(), geometry.PointF.zero() } };
        elements[cursor + 1] = .{ .verb = .line_to, .points = .{ geometry.PointF.init(upper[0].x, base_y), geometry.PointF.zero(), geometry.PointF.zero() } };
        cursor += 2;
    }
    elements[cursor] = .{ .verb = .close };
    try builder.fillPath(.{
        .id = chartCommandId(widget.id, chart_band_seed, series_index, 0),
        .elements = elements,
        .fill = colorFill(colorWithAlpha(color, chart_band_fill_alpha)),
    });
}

/// Map a series into plot-space points, skipping non-finite values.
/// Returned points live in a threadlocal scratch valid until the next
/// series maps (each emitter consumes them before returning).
threadlocal var chart_polyline_points: [chart_model.max_chart_points_per_series]geometry.PointF = undefined;

fn chartPolylinePoints(
    values: []const f32,
    domain: chart_model.ChartDomain,
    plot: geometry.RectF,
    inset: f32,
) Error![]const geometry.PointF {
    const count = @min(values.len, chart_polyline_points.len);
    var len: usize = 0;
    for (values[0..count], 0..) |value, index| {
        if (!std.math.isFinite(value)) continue;
        chart_polyline_points[len] = geometry.PointF.init(
            chartMapX(index, count, plot, inset),
            chartMapY(value, domain, plot, inset),
        );
        len += 1;
    }
    return chart_polyline_points[0..len];
}

const chart_grid_seed: u64 = 0x5eed_c4a8_0000_0001;
const chart_baseline_seed: u64 = 0x5eed_c4a8_0000_0002;
const chart_line_seed: u64 = 0x5eed_c4a8_0000_0003;
const chart_fill_seed: u64 = 0x5eed_c4a8_0000_0004;
const chart_band_seed: u64 = 0x5eed_c4a8_0000_0005;
const chart_bar_seed: u64 = 0x5eed_c4a8_0000_0006;

/// Stable hashed command ids per (family, series, ordinal), same scheme
/// as span runs, so retained diffing tracks chart commands across frames.
fn chartCommandId(widget_id: ObjectId, seed: u64, series_index: usize, ordinal: usize) ObjectId {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(std.mem.asBytes(&widget_id));
    hasher.update(std.mem.asBytes(&@as(u64, series_index)));
    hasher.update(std.mem.asBytes(&@as(u64, ordinal)));
    const value = hasher.final();
    return if (value == 0) 1 else value;
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

fn boundedTextLayout(frame: geometry.RectF, size: f32, inset: f32, alignment: TextAlign, wrap: TextWrap, tokens: DesignTokens) TextLayoutOptions {
    return .{
        .max_width = @max(1, frame.width - inset * 2),
        .line_height = size * 1.25,
        .wrap = wrap,
        .alignment = alignment,
        .measure = tokens.text_measure,
    };
}

fn centeredTextOrigin(frame: geometry.RectF, text: []const u8, size: f32, tokens: DesignTokens) geometry.PointF {
    return alignedTextOrigin(frame, text, size, 0, .center, tokens);
}

fn alignedTextOrigin(frame: geometry.RectF, text: []const u8, size: f32, inset: f32, alignment: TextAlign, tokens: DesignTokens) geometry.PointF {
    const width = if (tokens.text_measure) |measure|
        measure.measureWidth(tokens.typography.font_id, size, text)
    else
        estimateTextWidth(text, size);
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

fn accordionChildrenVisible(widget: Widget) bool {
    return widget.kind != .accordion or booleanControlSelected(widget);
}

fn accordionContentFrame(widget: Widget, content: geometry.RectF, tokens: DesignTokens) geometry.RectF {
    const header_height = widgetControlHeight(widget, tokens, tokens.sizes.control_md);
    const gap = nonNegative(widget.layout.gap);
    return geometry.RectF.init(content.x, content.y + header_height + gap, content.width, @max(0, content.height - header_height - gap));
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
