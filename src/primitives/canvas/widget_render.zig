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
const Color = drawing_model.Color;
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
const measureTextWidthForFont = text_model.measureTextWidthForFont;
const affinesEqual = equality_model.affinesEqual;
pub const textSelectionFillColor = widget_render_style.textSelectionFillColor;
pub const textSelectionTextColor = widget_render_style.textSelectionTextColor;
pub const textEditingInkColor = widget_render_style.textEditingInkColor;
pub const staticTextSelectionFillColor = widget_render_style.staticTextSelectionFillColor;
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
const snapHairlineStrokeRect = widget_render_style.snapHairlineStrokeRect;
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

/// Frame-lifetime scratch for widget-built path elements: `.chart`
/// widgets build their line/band `PathElement`s here at emit time, and
/// `.spinner` widgets their arc segment (unlike icons, whose elements
/// are comptime-static); emitted commands slice into it. The event loop
/// is single-threaded and the runtime copies the display list into
/// per-view storage within the same emit call stack, so one threadlocal
/// buffer per frame is sound — reset at each emit entry point. Sized to
/// mirror the runtime's per-view path-element budget
/// (`canvas_limits.max_canvas_path_elements_per_view`; a lockstep test
/// keeps them equal), so overflow here fails exactly where the per-view
/// copy would have refused anyway — loudly, by budget name.
threadlocal var frame_path_elements: [chart_model.max_chart_path_elements_per_frame]drawing_model.PathElement = undefined;
threadlocal var frame_path_len: usize = 0;

/// Frame-lifetime scratch for formatted chart label text (y tick values
/// and hover-detail rows): `drawText` commands slice into it under the
/// same single-threaded copy-before-return contract as the path
/// elements above. Overflow fails loudly by budget name.
threadlocal var frame_label_bytes: [chart_model.max_chart_label_bytes_per_frame]u8 = undefined;
threadlocal var frame_label_len: usize = 0;

fn resetFramePathScratch() void {
    frame_path_len = 0;
    frame_label_len = 0;
}

/// Persist a formatted label into the frame scratch so the emitted
/// command outlives the local formatting buffer.
fn allocFrameLabelBytes(text: []const u8) Error![]const u8 {
    if (frame_label_len + text.len > frame_label_bytes.len) return error.ChartLabelBytesFull;
    const start = frame_label_len;
    frame_label_len += text.len;
    @memcpy(frame_label_bytes[start..frame_label_len], text);
    return frame_label_bytes[start..frame_label_len];
}

/// Frame-lifetime scratch (same single-threaded emit contract as the
/// path-element scratch above) holding the root bounds of the tree being
/// emitted: the rect a modal surface's scrim covers. Chrome emission
/// happens deep in the recursion where no ancestor frame is in scope, so
/// the entry points record it here.
threadlocal var scrim_viewport: ?geometry.RectF = null;

fn allocFramePathElements(count: usize) Error![]drawing_model.PathElement {
    if (frame_path_len + count > frame_path_elements.len) return error.ChartPathElementListFull;
    const start = frame_path_len;
    frame_path_len += count;
    return frame_path_elements[start .. start + count];
}

pub fn emitWidgetTree(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    resetFramePathScratch();
    scrim_viewport = widget.frame.normalized();
    try emitWidgetDepth(builder, widget, tokens, 0);
}

pub fn emitWidgetLayout(builder: *Builder, layout: anytype, tokens: DesignTokens) Error!void {
    return emitWidgetLayoutWithState(builder, layout, tokens, .{});
}

pub fn emitWidgetLayoutWithState(builder: *Builder, layout: anytype, tokens: DesignTokens, state: WidgetRenderState) Error!void {
    resetFramePathScratch();
    scrim_viewport = widgetLayoutRootBounds(layout);
    try emitWidgetLayoutChildren(builder, layout, null, tokens, state);
    try emitWidgetLayoutAnchored(builder, layout, tokens, state);
    try emitWidgetLayoutChartHoverDetails(builder, layout, tokens, state);
}

/// The union of the layout's root-node frames: the whole laid-out
/// surface, which is what a modal scrim covers.
pub fn widgetLayoutRootBounds(layout: anytype) ?geometry.RectF {
    var bounds: ?geometry.RectF = null;
    for (layout.nodes) |node| {
        if (node.parent_index != null) continue;
        const frame = node.frame.normalized();
        bounds = if (bounds) |current| geometry.RectF.unionWith(current, frame) else frame;
    }
    return bounds;
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
        // A floating surface anchored inside a concealed disclosure
        // subtree stays down with its anchor — concealed content is
        // laid out but must not paint window-level chrome.
        if (widget_tree.isWidgetConcealedByDisclosure(layout, index)) continue;
        try emitWidgetLayoutNode(builder, layout, index, tokens, state, .none);
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
        .stack, .row, .column, .grid, .list, .breadcrumb, .pagination, .radio_group, .toggle_group, .split, .tree => try emitWidgetClippedChildren(builder, paint_widget, tokens, depth),
        .button_group => try emitButtonGroupWidget(builder, paint_widget, tokens, depth),
        .table, .data_grid => {
            try emitWidgetClippedChildren(builder, paint_widget, tokens, depth);
            try emitTableRowSeparators(builder, paint_widget.children, tokens);
        },
        .data_row => {
            try emitDataRowWidgetWash(builder, paint_widget, tokens);
            try emitWidgetClippedChildren(builder, paint_widget, tokens, depth);
        },
        .tabs => try emitTabsWidget(builder, paint_widget, tokens, depth),
        .scroll_view => try emitScrollViewWidget(builder, paint_widget, tokens, depth),
        .alert => try emitAlertWidget(builder, paint_widget, tokens, depth),
        .card => try emitCardWidget(builder, paint_widget, tokens, depth),
        .dialog => try emitDialogSurfaceWidget(builder, paint_widget, tokens, depth),
        .drawer => try emitDrawerSurfaceWidget(builder, paint_widget, tokens, depth),
        .sheet => try emitSheetSurfaceWidget(builder, paint_widget, tokens, depth),
        .accordion => try emitAccordionWidget(builder, paint_widget, tokens, depth),
        .bubble => try emitBubbleWidget(builder, paint_widget, tokens, depth),
        .resizable, .panel => try emitPanelWidget(builder, paint_widget, tokens, depth),
        .popover => try emitPopoverWidget(builder, paint_widget, tokens, depth),
        .menu_surface, .dropdown_menu => try emitMenuSurfaceWidget(builder, paint_widget, tokens, depth),
        .text => try emitTextWidget(builder, paint_widget, tokens),
        .icon => try emitIconWidget(builder, paint_widget, tokens),
        .image => try emitImageWidget(builder, paint_widget),
        .avatar => try emitAvatarWidget(builder, paint_widget, tokens),
        .badge => try emitBadgeWidget(builder, paint_widget, tokens),
        .button, .toggle_button, .toggle => try widget_render_controls.emitButtonWidget(builder, paint_widget, tokens),
        .icon_button => try widget_render_controls.emitIconButtonWidget(builder, paint_widget, tokens),
        .select => try widget_render_controls.emitSelectWidget(builder, paint_widget, tokens),
        .input, .text_field, .textarea => try widget_render_controls.emitTextFieldWidget(builder, paint_widget, tokens),
        .search_field, .combobox => try widget_render_controls.emitSearchFieldWidget(builder, paint_widget, tokens),
        .tooltip => try widget_render_controls.emitTooltipWidget(builder, paint_widget, tokens),
        .menu_item => try widget_render_controls.emitMenuItemWidget(builder, paint_widget, tokens),
        .list_item => {
            try widget_render_controls.emitListItemWidget(builder, paint_widget, tokens);
            // Custom row content (the list-row composite): children flow
            // inside the flat wash chrome.
            try emitWidgetClippedChildren(builder, paint_widget, tokens, depth);
        },
        .data_cell => try emitDataCellContent(builder, paint_widget, tokens),
        .status_bar => try emitStatusBarWidget(builder, paint_widget, tokens),
        .segmented_control => try widget_render_controls.emitSegmentedControlWidget(builder, paint_widget, tokens),
        .checkbox => try widget_render_controls.emitCheckboxWidget(builder, paint_widget, tokens),
        .radio => try widget_render_controls.emitRadioWidget(builder, paint_widget, tokens),
        .switch_control => try widget_render_controls.emitToggleWidget(builder, paint_widget, tokens),
        .slider => try widget_render_controls.emitSliderWidget(builder, paint_widget, tokens),
        .progress => try widget_render_controls.emitProgressWidget(builder, paint_widget, tokens),
        .separator => try emitSeparatorWidget(builder, paint_widget, tokens),
        .split_divider => try emitSplitDividerWidget(builder, paint_widget, tokens),
        .skeleton => try emitSkeletonWidget(builder, paint_widget, tokens),
        .spinner => try emitSpinnerWidget(builder, paint_widget, tokens),
        .chart => try emitChartWidget(builder, paint_widget, tokens),
        .input_group => {
            // Focus-within: the GROUP wears the focus ring for its
            // focused descendant (the entry's own ring is dissolved), so
            // the whole group reads as one field.
            var group = paint_widget;
            if (!group.state.focused) group.state.focused = widgetSubtreeHasFocusedState(paint_widget);
            try widget_render_controls.emitInputGroupWidget(builder, group, tokens);
            try emitWidgetClippedChildren(builder, paint_widget, tokens, depth);
        },
    }
}

/// Whether any descendant carries the focused state (the tree path's
/// focus-within source: state is baked into the widgets themselves).
fn widgetSubtreeHasFocusedState(widget: Widget) bool {
    for (widget.children) |child| {
        if (child.state.focused) return true;
        if (widgetSubtreeHasFocusedState(child)) return true;
    }
    return false;
}

/// Whether any descendant NODE carries baked focused state (the layout
/// path's focus-within source for static trees — docs scenes, tests —
/// resolved through the layout's parent links, which survive layout
/// retention where `widget.children` slices may not).
fn layoutSubtreeHasBakedFocus(layout: anytype, node_index: usize) bool {
    for (layout.nodes, 0..) |node, index| {
        if (index == node_index or !node.widget.state.focused) continue;
        var current = node.parent_index;
        while (current) |current_index| {
            if (current_index == node_index) return true;
            current = layout.nodes[current_index].parent_index;
        }
    }
    return false;
}

/// Whether the focus-visible widget sits inside `node_index`'s subtree
/// (the layout path's focus-within source: runtime focus is an id in
/// `WidgetRenderState`, resolved against the layout's parent links).
fn layoutSubtreeHasFocusVisible(layout: anytype, node_index: usize, state: WidgetRenderState) bool {
    const focus_id = state.focus_visible_id orelse return false;
    if (focus_id == 0) return false;
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id != focus_id) continue;
        var current: ?usize = index;
        while (current) |current_index| {
            if (current_index == node_index) return true;
            current = layout.nodes[current_index].parent_index;
        }
        return false;
    }
    return false;
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

/// Whether a button group stamps member positions into the render walk.
/// Under the house `.segmented` register only a gap-0 (the default)
/// group stamps — attached segments collapse corners and seams, while
/// an author who spaces the group out has asked for separate buttons,
/// and rounding off their inner corners then would be dishonest chrome.
/// Under the `.detached` register every member stamps regardless of
/// gap: the stamp switches the member to the group's chip treatment
/// (full corners, group control table), so spacing carries no opt-out
/// meaning there. The button emitters key the corner/seam collapse on
/// the register, never on the stamp alone.
fn buttonGroupStampsSegments(widget: Widget, tokens: DesignTokens) bool {
    return switch (tokens.controls.button_group_style) {
        .segmented => widget.layout.gap <= 0,
        .detached => true,
    };
}

/// A group child's position among the group's VISIBLE children, in
/// layout (slice) order — paint order may reorder emission by layer,
/// but which corner a segment keeps is a where-does-it-sit question,
/// never a when-does-it-paint question. Hidden children vacate their
/// position so the bar re-caps itself around them.
fn buttonGroupChildSegment(children: []const Widget, child_index: usize) widget_model.WidgetGroupSegment {
    var visible_total: usize = 0;
    var ordinal: usize = 0;
    for (children, 0..) |child, index| {
        if (child.semantics.hidden) continue;
        if (index == child_index) ordinal = visible_total;
        visible_total += 1;
    }
    return buttonGroupSegmentAt(ordinal, visible_total);
}

fn buttonGroupSegmentAt(ordinal: usize, visible_total: usize) widget_model.WidgetGroupSegment {
    // A lone segment is just a button: full corners, full border.
    if (visible_total <= 1) return .none;
    if (ordinal == 0) return .first;
    if (ordinal == visible_total - 1) return .last;
    return .middle;
}

/// The tree walk's button-group emission: `emitWidgetClippedChildren`
/// with the group segment stamp applied to each child copy on the way
/// down, so the button emitters can shape corners and collapse the
/// shared seams (segmented register) or swap to the group chip
/// treatment (detached register). The layout walk applies the same
/// stamp in `emitWidgetLayoutChildren` — the two walks must agree or a
/// docs scene and a live app would render different bars.
fn emitButtonGroupWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    if (!buttonGroupStampsSegments(widget, tokens)) return emitWidgetClippedChildren(builder, widget, tokens, depth);
    if (widget.layout.clip_content) try builder.pushClip(widgetContentClip(widget, tokens));
    var emitted: usize = 0;
    var previous: ?WidgetPaintOrder = null;
    while (emitted < widget.children.len) : (emitted += 1) {
        const child_index = nextWidgetPaintChild(widget.children, tokens, previous) orelse break;
        var child = widget.children[child_index];
        child.group_segment = buttonGroupChildSegment(widget.children, child_index);
        try emitWidgetDepth(builder, child, tokens, depth + 1);
        previous = .{ .layer = widgetPaintLayer(child, tokens), .index = child_index };
    }
    if (widget.layout.clip_content) try builder.popClip();
}

fn emitWidgetLayoutChildren(
    builder: *Builder,
    layout: anytype,
    parent_index: ?usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
) Error!void {
    const child_count = widgetLayoutDirectChildCount(layout, parent_index);
    // The layout walk's flush button-group stamp (the tree walk's twin
    // lives in `emitButtonGroupWidget`): children of a gap-0 group get
    // their segment position on the way down.
    const group_index: ?usize = if (parent_index) |index| blk: {
        const parent = layout.nodes[index].widget;
        break :blk if (parent.kind == .button_group and buttonGroupStampsSegments(parent, tokens)) index else null;
    } else null;
    var emitted: usize = 0;
    var previous: ?WidgetPaintOrder = null;
    while (emitted < child_count) : (emitted += 1) {
        const child_index = nextWidgetLayoutPaintChild(layout, parent_index, tokens, previous) orelse return;
        // Anchored floating children paint in the late z-pass
        // (`emitWidgetLayoutAnchored`), never in tree position.
        if (!widget_tree.widgetIsAnchored(layout.nodes[child_index].widget)) {
            const segment = if (group_index) |index|
                layoutButtonGroupSegment(layout, index, child_index)
            else
                widget_model.WidgetGroupSegment.none;
            try emitWidgetLayoutNode(builder, layout, child_index, tokens, state, segment);
        }
        previous = .{ .layer = widgetPaintLayer(layout.nodes[child_index].widget, tokens), .index = child_index };
    }
}

/// A layout node's position among its button group's visible direct
/// children, in node (layout) order — the layout-walk twin of
/// `buttonGroupChildSegment`.
fn layoutButtonGroupSegment(layout: anytype, group_index: usize, child_index: usize) widget_model.WidgetGroupSegment {
    var visible_total: usize = 0;
    var ordinal: usize = 0;
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != group_index) continue;
        if (node.widget.semantics.hidden) continue;
        if (index == child_index) ordinal = visible_total;
        visible_total += 1;
    }
    return buttonGroupSegmentAt(ordinal, visible_total);
}

fn emitWidgetLayoutNode(
    builder: *Builder,
    layout: anytype,
    node_index: usize,
    tokens: DesignTokens,
    state: WidgetRenderState,
    segment: widget_model.WidgetGroupSegment,
) Error!void {
    const node = layout.nodes[node_index];
    if (node.widget.semantics.hidden) return;

    var widget = widgetWithRenderState(widgetWithFrame(node.widget, node.frame), state);
    widget.group_segment = segment;
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
        .stack, .row, .column, .breadcrumb, .button_group, .pagination, .radio_group, .toggle_group, .split, .tree => {},
        .data_row => try emitDataRowWidgetWash(builder, paint_widget, tokens),
        .tabs => try widget_render_surfaces.emitTabsListWidgetChrome(builder, paint_widget, tokens),
        .table, .data_grid => {
            if (paint_widget.layout.virtualized) {
                try emitWidgetLayoutScrollableChildren(builder, layout, node_index, tokens, state, paint_widget);
                try emitTableRowSeparatorsLayout(builder, layout, node_index, tokens, paint_widget, true);
                return;
            }
            try emitWidgetLayoutClippedChildren(builder, layout, node_index, tokens, state, paint_widget);
            try emitTableRowSeparatorsLayout(builder, layout, node_index, tokens, paint_widget, false);
            return;
        },
        .grid, .list => if (paint_widget.layout.virtualized) {
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
        .dialog => {
            try emitModalSurfaceScrim(builder, paint_widget, tokens);
            try widget_render_surfaces.emitDialogSurfaceWidgetChrome(builder, paint_widget, tokens);
        },
        .drawer => {
            try emitModalSurfaceScrim(builder, paint_widget, tokens);
            try widget_render_surfaces.emitDrawerSurfaceWidgetChrome(builder, paint_widget, tokens);
        },
        .sheet => {
            try emitModalSurfaceScrim(builder, paint_widget, tokens);
            try widget_render_surfaces.emitSheetSurfaceWidgetChrome(builder, paint_widget, tokens);
        },
        .accordion => {
            try widget_render_surfaces.emitAccordionWidgetChrome(builder, paint_widget, tokens);
            // Disclosure emission is tri-state. Settled closed: the
            // content (laid out at full size below the header) emits
            // NOTHING — byte-identical to the pre-disclosure display
            // list. Mid-reveal (or mid-conceal): the content paints at
            // its full-size geometry, clipped to the item's animated
            // frame, so text reveals without ever re-wrapping. Settled
            // open: the shared unclipped children pass below, exactly
            // as before.
            switch (accordionLayoutDisclosure(layout, node_index, paint_widget, state)) {
                .closed => return,
                .revealing => {
                    try builder.pushClip(.{ .id = widgetPartId(paint_widget.id, 9), .rect = paint_widget.frame });
                    try emitWidgetLayoutChildren(builder, layout, node_index, tokens, state);
                    try builder.popClip();
                    return;
                },
                .open => {},
            }
        },
        .bubble => {
            try widget_render_surfaces.emitBubbleWidgetChrome(builder, paint_widget, tokens);
            // The bubble's variant re-inks its content: children render
            // against the cascaded token palette (knockout body ink on a
            // filled bubble) instead of the page's, so this subtree
            // recurses with its own tokens and returns before the shared
            // children pass below.
            try emitWidgetLayoutClippedChildren(builder, layout, node_index, widget_render_surfaces.bubbleContentTokens(paint_widget, tokens), state, paint_widget);
            // The reaction pill paints LAST, above the capsule and its
            // content, from the PAGE tokens (never the cascaded
            // palette) — mirrors `emitBubbleWidget` on the widget walk.
            try widget_render_surfaces.emitBubbleWidgetReactions(builder, paint_widget, tokens);
            return;
        },
        .resizable, .panel => try widget_render_surfaces.emitPanelWidgetChrome(builder, paint_widget, tokens),
        .popover => try widget_render_surfaces.emitPopoverWidgetChrome(builder, paint_widget, tokens),
        .menu_surface, .dropdown_menu => try widget_render_surfaces.emitMenuSurfaceWidgetChrome(builder, paint_widget, tokens),
        .text => try emitTextWidget(builder, paint_widget, tokens),
        .icon => try emitIconWidget(builder, paint_widget, tokens),
        .image => try emitImageWidget(builder, paint_widget),
        .avatar => try emitAvatarWidget(builder, paint_widget, tokens),
        .badge => try emitBadgeWidget(builder, paint_widget, tokens),
        .button, .toggle_button, .toggle => try widget_render_controls.emitButtonWidget(builder, paint_widget, tokens),
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
        .switch_control => try widget_render_controls.emitToggleWidget(builder, paint_widget, tokens),
        .slider => try widget_render_controls.emitSliderWidget(builder, paint_widget, tokens),
        .progress => try widget_render_controls.emitProgressWidget(builder, paint_widget, tokens),
        .separator => try emitSeparatorWidget(builder, paint_widget, tokens),
        .split_divider => try emitSplitDividerWidget(builder, paint_widget, tokens),
        .skeleton => try emitSkeletonWidget(builder, paint_widget, tokens),
        .spinner => try emitSpinnerWidget(builder, paint_widget, tokens),
        .chart => try emitChartWidget(builder, paint_widget, tokens),
        .input_group => {
            // Focus-within: the GROUP wears the focus ring for its
            // focused descendant (the entry's own ring is dissolved), so
            // the whole group reads as one field. With runtime render
            // state the focused descendant is an id; without it (static
            // trees, docs scenes) the baked child state is truth — the
            // same override-vs-baked split `widgetWithRenderState` makes.
            var group = paint_widget;
            if (!group.state.focused) {
                group.state.focused = if (state.focused_id != null or state.focus_visible_id != null)
                    layoutSubtreeHasFocusVisible(layout, node_index, state)
                else
                    layoutSubtreeHasBakedFocus(layout, node_index);
            }
            try widget_render_controls.emitInputGroupWidget(builder, group, tokens);
        },
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

/// True when this widget's chrome carries the modal scrim: dialogs,
/// drawers, and sheets are modal — the user must deal with them before
/// the content behind — so the surface behind gets the token-driven
/// blur + dim treatment. Anchored surfaces (popover, menus, tooltips)
/// are NOT modal and never scrim.
pub fn widgetEmitsModalScrim(widget: Widget, tokens: DesignTokens) bool {
    if (!widget.scrim) return false;
    return switch (widget.kind) {
        .dialog, .drawer, .sheet => tokens.colors.scrim.a > 0 or nonNegative(tokens.blur.scrim) > 0,
        else => false,
    };
}

/// The scrim behind a modal surface: a backdrop blur of everything
/// already painted across the whole root bounds (real content blur —
/// the reference rasterizer samples the framebuffer, the GPU packet
/// carries the same region-blur command), then the translucent wash on
/// top. Emitted immediately before the surface's own chrome, so
/// everything below the modal in paint order is behind the glass and
/// the modal itself stays crisp. Slots 13/14 (blur/wash) sit clear of
/// the chrome slots (fill 1, border 2, clip 9, text 10, widget backdrop
/// blur 12). Static by design: it tracks the surface's opacity/transform
/// wrappers, and honoring reduced motion costs nothing because nothing
/// here moves.
fn emitModalSurfaceScrim(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    if (!widgetEmitsModalScrim(widget, tokens)) return;
    const viewport = (scrim_viewport orelse widget.frame.normalized());
    if (viewport.isEmpty()) return;
    const blur_radius = nonNegative(tokens.blur.scrim);
    if (blur_radius > 0) {
        try builder.blur(.{
            .id = widgetPartId(widget.id, 13),
            .rect = viewport,
            .radius = blur_radius,
        });
    }
    if (tokens.colors.scrim.a > 0) {
        try builder.fillRect(.{
            .id = widgetPartId(widget.id, 14),
            .rect = viewport,
            .fill = colorFill(tokens.colors.scrim),
        });
    }
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
        // The bubble clips at its own capsule arc so wide content (an
        // image child, a full-bleed row) shears along the chrome's
        // corners instead of the generic surface radius.
        .bubble => widget_render_surfaces.bubbleWidgetRadius(widget, tokens),
        .alert, .card, .resizable, .panel, .menu_surface, .dropdown_menu => Radius.all(tokens.radius.lg),
        .accordion => .{},
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
    try emitModalSurfaceScrim(builder, widget, tokens);
    try widget_render_surfaces.emitDialogSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitDrawerSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitModalSurfaceScrim(builder, widget, tokens);
    try widget_render_surfaces.emitDrawerSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitSheetSurfaceWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitModalSurfaceScrim(builder, widget, tokens);
    try widget_render_surfaces.emitSheetSurfaceWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitPanelWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitPanelWidgetChrome(builder, widget, tokens);
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

fn emitBubbleWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitBubbleWidgetChrome(builder, widget, tokens);
    // Children render against the bubble's cascaded token palette
    // (knockout body ink on a filled bubble) — the whole subtree, not
    // just direct children, because the recursion below threads these
    // tokens all the way down.
    try emitWidgetClippedChildren(builder, widget, widget_render_surfaces.bubbleContentTokens(widget, tokens), depth);
    // The reaction pill paints LAST — it straddles the bubble's bottom
    // edge above the capsule and its content, the reference's overlap
    // treatment — and from the PAGE tokens, never the bubble's cascaded
    // palette: the pill sits on the conversation plane, so a primary
    // bubble's knockout ink does not apply to it.
    try widget_render_surfaces.emitBubbleWidgetReactions(builder, widget, tokens);
}

// The HIERARCHICAL walk's disclosure is discrete: this path emits
// source trees directly (static scenes, docs specimens) where no
// runtime tween exists, so a closed item simply skips its content.
// Animated disclosure lives on the LAYOUT walk above — the runtime's
// disclosure tween eases the retained frames and the layout emission
// clips the full-size content to the animated frame mid-reveal.
fn emitAccordionWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitAccordionWidgetChrome(builder, widget, tokens);
    if (!accordionChildrenVisible(widget)) return;
    try emitWidgetClippedChildren(builder, widget, tokens, depth);
}

/// One accordion's disclosure pose on the layout walk, judged from
/// retained state plus geometry:
///   - `open`: state open AND the frame holds everything the content
///     reaches — the settled pose; content emits unclipped, exactly
///     the pre-disclosure display list.
///   - `revealing`: the frame trails the content — a reveal in flight
///     (state open, frame still growing) or a conceal in flight (state
///     closed, but the runtime's tween says this id is still moving).
///   - `closed`: state closed with no tween in flight — content emits
///     nothing.
const AccordionLayoutDisclosure = enum { closed, revealing, open };

fn accordionLayoutDisclosure(layout: anytype, node_index: usize, widget: Widget, state: WidgetRenderState) AccordionLayoutDisclosure {
    if (accordionChildrenVisible(widget)) {
        return if (widget_tree.disclosureSettledOpen(layout, node_index)) .open else .revealing;
    }
    return if (state.disclosureRevealing(widget.id)) .revealing else .closed;
}

fn emitTabsWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try widget_render_surfaces.emitTabsListWidgetChrome(builder, widget, tokens);
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
    // Plain leaves paint the single line layout measured (wrapping is
    // the span-paragraph path, `wrap="true"`), so a width-constrained
    // title never paints a second line over the row below. Content past
    // the frame follows the widget's overflow policy: trailing ellipsis
    // by default — layout elides the drawn line while `widget.text`
    // stays the selection/copy source of truth — or the explicit clip
    // opt-in (`overflow="clip"`), which keeps the historical hard-cut
    // behind a frame clip for fixed-format content.
    const clip_overflow = widget.text_overflow == .clip;
    if (clip_overflow) {
        try builder.pushClip(.{ .id = widgetPartId(widget.id, 9), .rect = widget.frame });
    }
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
            .wrap = .none,
            .alignment = widget.text_alignment,
            .overflow = widget.text_overflow,
            .measure = tokens.text_measure,
        },
    });
    if (clip_overflow) try builder.popClip();
}

/// Wrap budget for text painted inside a pixel-snapped frame — the
/// shared quantum hand-back (`widget_metrics.textWrapMaxWidth`), aliased
/// for the emit sites here.
const textWrapMaxWidth = widget_metrics.textWrapMaxWidth;

/// Static text selection highlight: fill rects behind the selected lines
/// of a `.text` widget (plain or span paragraph). Command ids are hashed
/// per line ordinal like span runs, so retained diffing stays stable.
fn emitStaticTextSelection(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const range = widget_access.widgetTextSelectionRange(widget) orelse return;
    if (range.isCollapsed(widget.text.len)) return;
    var rect_buffer: [widget_text_select.max_static_text_selection_rects]text_model.TextSelectionRect = undefined;
    const rects = widget_text_select.staticTextSelectionRects(widget, tokens, range, &rect_buffer);
    for (rects, 0..) |selection, ordinal| {
        try builder.fillRoundedRect(.{
            .id = textSelectionCommandId(widget.id, ordinal),
            .rect = pixelSnapGeometryRect(tokens, selection.rect),
            .radius = Radius.all(tokens.radius.sm),
            .fill = .{ .color = staticTextSelectionFillColor(widget, tokens) },
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
            // Wrapping already happened at the span level (each run is one
            // line segment), so the options carry no wrap work — they carry
            // the measurement seam. Renderers that walk per-cluster
            // advances (the reference renderer behind every automation
            // screenshot) then advance with the same provider layout
            // positioned the runs with; without it a provider-kerned prose
            // run repainted at estimator advances overran the next span's
            // x and visually swallowed the inter-span space
            // ("remaining`experimental_`" -> "remainingexperimental_").
            .text_layout = .{
                .max_width = 0,
                .line_height = layout.line_height,
                .wrap = .none,
                .alignment = .start,
                .measure = tokens.text_measure,
            },
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
    // glyph characters in `icon.text` are untouched). The explicit
    // channel never falls through: a name that resolves nowhere draws the
    // missing-icon fallback (the build-time Debug warning names the
    // value), so a broken reference is visible, never silent.
    if (icon_model.resolveOrMissing(widget.icon)) |icon| {
        return emitVectorIconWidget(builder, widget, tokens, icon);
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
            // Layout alignment centers the line inside `max_width`, so
            // the origin must be the frame START like every other
            // center-aligned text_layout draw — a pre-centered origin
            // here applied the centering offset twice and pushed the
            // initials right of the circle center.
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, 0)),
            .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted),
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, 0, .center, .none, tokens),
        });
    }

    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 4),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    }));
}

fn emitBadgeWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = componentControlVisualTokens(widget, tokens);
    const radius = componentPillRadius(widget, visual, widget.frame.height * 0.5);
    const text_size = widget_metrics.widgetBadgeTextSize(widget, tokens);
    const text_inset = widgetControlInset(widget, tokens, tokens.spacing.sm);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = colorFill(badgeBackgroundColor(widget, tokens, visual)),
    });
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, badgeBorderColor(widget, tokens, visual)),
            .width = badgeStrokeWidth(widget, tokens, visual),
        },
    }));
    const content_color = badgeTextColor(widget, tokens, visual);
    // Inline vector icon: icon-only badges center it (the stepper's
    // completed check, status chips); icon + text draws it before the
    // label. One widget, one tint — and no text glyph outside the bundled
    // face's coverage (the stepper-checkmark tofu fix).
    const icon = icon_model.resolveOrMissing(widget.icon);
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

/// The split's drag handle: a centered vertical hairline in the divider
/// band. Hover/press tint the line with the accent color (the band is
/// the hit target, so the affordance appears as the pointer reaches
/// it); keyboard focus draws the standard focus ring around the band.
fn emitSplitDividerWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = componentControlVisualTokens(widget, tokens);
    const normalized = widget.frame.normalized();
    if (normalized.isEmpty()) return;
    const active = widget.state.hovered or widget.state.pressed;
    const thickness = if (active)
        @max(2, controlStrokeWidth(widget, visual, tokens.stroke.hairline))
    else
        controlStrokeWidth(widget, visual, tokens.stroke.hairline);
    const line_rect = geometry.RectF.init(
        normalized.x + (normalized.width - thickness) * 0.5,
        normalized.y,
        thickness,
        normalized.height,
    );
    const line_color = if (active)
        widgetAccentColor(widget, tokens.colors.accent)
    else
        widgetBorderColor(widget, visual.border orelse tokens.colors.border);
    try builder.fillRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = pixelSnapGeometryRect(tokens, line_rect),
        .fill = colorFill(line_color),
    });
    if (widget.state.focused) {
        try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
            .id = widgetPartId(widget.id, 2),
            .rect = pixelSnapGeometryRect(tokens, normalized),
            .radius = Radius.all(tokens.radius.sm),
            .stroke = .{
                .fill = widget_render_style.widgetFocusRingFill(widget, tokens),
                .width = tokens.stroke.focus,
            },
        }));
    }
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
            .overflow = widget.text_overflow,
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

/// The command id of a skeleton's placeholder fill — the target of the
/// runtime's looping pulse animation, published so the animation and
/// the emitter can never drift apart.
pub fn skeletonWidgetFillCommandId(id: ObjectId) ObjectId {
    return widgetPartId(id, 1);
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

/// A row's own state wash: hover and selection paint the FULL row band
/// edge to edge (the table register's row hover), square-cornered so
/// adjacent rows tile. Rows at rest draw nothing.
fn emitDataRowWidgetWash(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const fill = widget_render_style.listItemFillColor(widget, tokens, widget.state);
    if (fill.a <= 0) return;
    try builder.fillRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .fill = colorFill(fill),
    });
}

/// The table's chrome: a hairline separator under every row but the
/// last — never an outer box, never per-cell gridlines. The separator
/// is a part of the ROW above it (stable command id per row), drawn by
/// the table so the last row can stay open-edged.
fn emitTableRowSeparators(builder: *Builder, children: []const Widget, tokens: DesignTokens) Error!void {
    var last_row_index: ?usize = null;
    for (children, 0..) |child, index| {
        if (child.kind == .data_row and !child.semantics.hidden) last_row_index = index;
    }
    for (children, 0..) |child, index| {
        if (child.kind != .data_row or child.semantics.hidden) continue;
        if (last_row_index != null and index == last_row_index.?) continue;
        try emitTableRowSeparatorLine(builder, child.id, child.frame, tokens);
    }
}

fn emitTableRowSeparatorsLayout(builder: *Builder, layout: anytype, table_index: usize, tokens: DesignTokens, table: Widget, clip_to_table: bool) Error!void {
    if (clip_to_table) try builder.pushClip(.{ .id = widgetPartId(table.id, 9), .rect = table.frame });
    var last_row_index: ?usize = null;
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != table_index) continue;
        if (node.widget.kind == .data_row and !node.widget.semantics.hidden) last_row_index = index;
    }
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != table_index) continue;
        if (node.widget.kind != .data_row or node.widget.semantics.hidden) continue;
        if (last_row_index != null and index == last_row_index.?) continue;
        try emitTableRowSeparatorLine(builder, node.widget.id, node.frame, tokens);
    }
    if (clip_to_table) try builder.popClip();
}

fn emitTableRowSeparatorLine(builder: *Builder, row_id: ObjectId, row_frame: geometry.RectF, tokens: DesignTokens) Error!void {
    const frame = row_frame.normalized();
    if (frame.isEmpty()) return;
    const y = frame.maxY();
    try builder.drawLine(.{
        .id = widgetPartId(row_id, 2),
        .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(frame.x, y)),
        .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(frame.maxX(), y)),
        .stroke = .{
            .fill = colorFill(tokens.colors.border),
            .width = tokens.stroke.hairline,
        },
    });
}

/// Sweep of the arc register's stroked segment, in degrees: the box
/// leaves a 72-degree mouth open, so the shape reads as a broken ring
/// even when a static render freezes it.
const spinner_arc_sweep_degrees: f32 = 288;
/// Arc centerline radius as a fraction of the box extent — the icon
/// register's inset circle (a radius-9 circle in a 24 box), so the
/// glyph breathes inside its frame instead of bleeding to the edge.
const spinner_arc_radius_ratio: f32 = 9.0 / 24.0;
/// Arc stroke as a fraction of the box extent (a 2-unit stroke in the
/// 24 box): the stroke scales with the size rung, before per-widget and
/// theme overrides.
const spinner_arc_stroke_ratio: f32 = 2.0 / 24.0;

/// Draw a `.spinner` widget. Emission is deterministic: the pose is a
/// pure function of `widget.value` (fractions of a cycle from twelve
/// o'clock), so static renders — docs previews, screenshots — pose it
/// reproducibly. The LIVE motion is not emitted here; the runtime arms
/// looping render animations on the emitted command ids instead of
/// re-emitting the display list. Two structural registers, chosen by
/// `metrics.spinner_style` (structure is a pack signature — see the
/// token's comment — so the emitter never asks which pack is active):
///
/// - `.arc`: one stroked 288-degree arc in the widget's ink, no track;
///   the runtime spins it about `spinnerWidgetRotationCenter` via a
///   `.wrap` rotation on `spinnerWidgetArcCommandId`.
/// - `.segmented`: a dial of radial pill segments at fixed angles, one
///   `fillPath` per segment (`spinnerWidgetSegmentCommandId`) so the
///   runtime can stagger a `.wrap` opacity loop per segment — the
///   bright head steps around the dial while each pill fades in place.
///   Animated frames emit every pill at full ink (the OVERRIDE channel
///   multiplies emitted alpha, so a baked fade would double-darken);
///   under reduced motion no loop ever arms, so the fade IS baked and
///   the static pose shows the head-to-tail trail.
fn emitSpinnerWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = componentControlVisualTokens(widget, tokens);
    const normalized = widget.frame.normalized();
    if (normalized.isEmpty()) return;
    const size = @min(normalized.width, normalized.height);
    if (size <= 0) return;
    const center = geometry.PointF.init(normalized.x + normalized.width * 0.5, normalized.y + normalized.height * 0.5);
    const ink = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);

    switch (tokens.metrics.spinner_style) {
        .arc => try emitSpinnerArc(builder, widget, visual, center, size, ink),
        .segmented => try emitSpinnerSegments(builder, widget, tokens, center, size, ink),
    }
}

/// The arc register: a single stroked arc whose start angle carries the
/// deterministic pose. Split into <=90-degree cubic segments (the
/// circle-from-cubics constant generalized per segment angle), accurate
/// to sub-pixel error at control sizes.
fn emitSpinnerArc(builder: *Builder, widget: Widget, visual: ControlVisualTokens, center: geometry.PointF, size: f32, ink: Color) Error!void {
    const stroke_width = controlStrokeWidth(widget, visual, size * spinner_arc_stroke_ratio);
    const radius = size * spinner_arc_radius_ratio;
    if (radius <= 0) return;

    const start_degrees = -90 + std.math.clamp(widget.value, 0, 1) * 360;
    const segment_total: usize = @intFromFloat(@ceil(spinner_arc_sweep_degrees / 90.0));
    const delta_degrees = spinner_arc_sweep_degrees / @as(f32, @floatFromInt(segment_total));
    const kappa = (4.0 / 3.0) * @tan(std.math.degreesToRadians(delta_degrees) * 0.25) * radius;

    const elements = try allocFramePathElements(1 + segment_total);
    const start_radians = std.math.degreesToRadians(start_degrees);
    elements[0] = .{ .verb = .move_to, .points = .{
        geometry.PointF.init(center.x + radius * @cos(start_radians), center.y + radius * @sin(start_radians)),
        geometry.PointF.zero(),
        geometry.PointF.zero(),
    } };
    for (0..segment_total) |segment| {
        const a0 = std.math.degreesToRadians(start_degrees + delta_degrees * @as(f32, @floatFromInt(segment)));
        const a1 = std.math.degreesToRadians(start_degrees + delta_degrees * @as(f32, @floatFromInt(segment + 1)));
        const from = geometry.PointF.init(center.x + radius * @cos(a0), center.y + radius * @sin(a0));
        const to = geometry.PointF.init(center.x + radius * @cos(a1), center.y + radius * @sin(a1));
        elements[1 + segment] = .{ .verb = .cubic_to, .points = .{
            geometry.PointF.init(from.x - kappa * @sin(a0), from.y + kappa * @cos(a0)),
            geometry.PointF.init(to.x + kappa * @sin(a1), to.y - kappa * @cos(a1)),
            to,
        } };
    }
    try builder.strokePath(.{
        .id = spinnerWidgetArcCommandId(widget.id),
        .elements = elements,
        .stroke = .{
            .fill = colorFill(ink),
            .width = stroke_width,
        },
        // The measured reference arc ends in semicircles, not squared-off
        // butt ends: the register reads as a drawn stroke chasing its
        // tail, so the caps are part of the shape, not a rasterizer
        // default.
        .cap = .round,
    });
}

/// The segmented register: `n` pill segments pointing outward at fixed
/// angles, segment 0 at twelve o'clock and the rest stepping clockwise.
/// Each pill is a filled stadium path (two straight edges, two
/// two-cubic semicircle caps) so it stays a pill at any angle —
/// rounded-rect commands are axis-aligned and cannot rotate.
fn emitSpinnerSegments(builder: *Builder, widget: Widget, tokens: DesignTokens, center: geometry.PointF, size: f32, ink: Color) Error!void {
    const count = spinnerWidgetSegmentCount(tokens);
    const length = size * @max(0, tokens.metrics.spinner_segment_length_ratio);
    const thickness = size * @max(0, tokens.metrics.spinner_segment_thickness_ratio);
    const orbit = size * @max(0, tokens.metrics.spinner_segment_radius_ratio);
    if (length <= 0 or thickness <= 0) return;
    const tail = std.math.clamp(tokens.metrics.spinner_tail_opacity, 0, 1);
    // Reduced motion is the one world where the runtime never arms the
    // per-segment opacity loops, so the trail must be baked into the
    // emitted inks for the register to read as an indicator at all.
    // Animated worlds bake nothing: overrides MULTIPLY emitted alpha,
    // and a baked trail under an animated trail would double-darken.
    const reduce_motion = tokens.motion.durationMs(.slow) == 0;
    const value = std.math.clamp(widget.value, 0, 1);

    const cap = thickness * 0.5;
    const half = @max(length * 0.5 - cap, 0);
    const cap_kappa: f32 = 0.5522847498 * cap;
    for (0..count) |segment| {
        const angle = std.math.degreesToRadians(-90 + 360 * @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(count)));
        // Radial and tangential unit vectors: pills point outward along
        // `u`, caps bulge along `u`, straight edges run offset by `v`.
        const u = geometry.PointF.init(@cos(angle), @sin(angle));
        const v = geometry.PointF.init(-@sin(angle), @cos(angle));
        const pill_center = geometry.PointF.init(center.x + orbit * u.x, center.y + orbit * u.y);
        const inner = geometry.PointF.init(pill_center.x - half * u.x, pill_center.y - half * u.y);
        const outer = geometry.PointF.init(pill_center.x + half * u.x, pill_center.y + half * u.y);

        var opacity: f32 = 1;
        if (reduce_motion) {
            // The frozen pose: the head sits `value` turns past twelve
            // o'clock, and each step CLOCKWISE ahead of it is one cycle
            // fraction older — the same linear head-to-tail ramp the
            // staggered loops trace live.
            var distance = @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(count)) - value;
            distance -= @floor(distance);
            var age = 1 - distance;
            if (age >= 1) age = 0;
            opacity = 1 - (1 - tail) * age;
        }

        const a = geometry.PointF.init(inner.x + cap * v.x, inner.y + cap * v.y);
        const b = geometry.PointF.init(outer.x + cap * v.x, outer.y + cap * v.y);
        const outer_mid = geometry.PointF.init(outer.x + cap * u.x, outer.y + cap * u.y);
        const e = geometry.PointF.init(outer.x - cap * v.x, outer.y - cap * v.y);
        const f = geometry.PointF.init(inner.x - cap * v.x, inner.y - cap * v.y);
        const inner_mid = geometry.PointF.init(inner.x - cap * u.x, inner.y - cap * u.y);

        const elements = try allocFramePathElements(8);
        elements[0] = .{ .verb = .move_to, .points = .{ a, geometry.PointF.zero(), geometry.PointF.zero() } };
        elements[1] = .{ .verb = .line_to, .points = .{ b, geometry.PointF.zero(), geometry.PointF.zero() } };
        elements[2] = .{ .verb = .cubic_to, .points = .{
            geometry.PointF.init(b.x + cap_kappa * u.x, b.y + cap_kappa * u.y),
            geometry.PointF.init(outer_mid.x + cap_kappa * v.x, outer_mid.y + cap_kappa * v.y),
            outer_mid,
        } };
        elements[3] = .{ .verb = .cubic_to, .points = .{
            geometry.PointF.init(outer_mid.x - cap_kappa * v.x, outer_mid.y - cap_kappa * v.y),
            geometry.PointF.init(e.x + cap_kappa * u.x, e.y + cap_kappa * u.y),
            e,
        } };
        elements[4] = .{ .verb = .line_to, .points = .{ f, geometry.PointF.zero(), geometry.PointF.zero() } };
        elements[5] = .{ .verb = .cubic_to, .points = .{
            geometry.PointF.init(f.x - cap_kappa * u.x, f.y - cap_kappa * u.y),
            geometry.PointF.init(inner_mid.x - cap_kappa * v.x, inner_mid.y - cap_kappa * v.y),
            inner_mid,
        } };
        elements[6] = .{ .verb = .cubic_to, .points = .{
            geometry.PointF.init(inner_mid.x + cap_kappa * v.x, inner_mid.y + cap_kappa * v.y),
            geometry.PointF.init(a.x - cap_kappa * u.x, a.y - cap_kappa * u.y),
            a,
        } };
        elements[7] = .{ .verb = .close };
        try builder.fillPath(.{
            .id = spinnerWidgetSegmentCommandId(widget.id, segment),
            .elements = elements,
            .fill = colorFill(colorWithAlpha(ink, ink.a * opacity)),
        });
    }
}

/// The command id of a spinner's accent arc segment — the part slot
/// `emitSpinnerWidget` draws it under — so the runtime can target the
/// arc with a looping rotation render animation.
pub fn spinnerWidgetArcCommandId(id: ObjectId) ObjectId {
    return widgetPartId(id, 2);
}

/// The point the spinner's rotation animation must spin about: the
/// center of the PAINTED frame (pixel-snapped exactly like emission),
/// so the sampled rotation never wobbles against the emitted geometry.
pub fn spinnerWidgetRotationCenter(widget: Widget, tokens: DesignTokens) geometry.PointF {
    const normalized = pixelSnapGeometryRect(tokens, widget.frame).normalized();
    return geometry.PointF.init(normalized.x + normalized.width * 0.5, normalized.y + normalized.height * 0.5);
}

/// The command id of segment `index` of a segmented-register spinner —
/// the part slot `emitSpinnerSegments` fills it under — so the runtime
/// can stagger a looping opacity animation per segment.
pub fn spinnerWidgetSegmentCommandId(id: ObjectId, index: usize) ObjectId {
    return widgetPartId(id, @intCast(1 + index));
}

/// How many segments a segmented-register spinner draws: the token
/// count clamped to the widget part-id space (16 slots per widget, one
/// reserved so slot arithmetic never rolls into the next widget's id
/// range). Emitter and runtime both resolve the count through here, so
/// the armed opacity loops always match the emitted commands one-to-one.
pub fn spinnerWidgetSegmentCount(tokens: DesignTokens) usize {
    return @intCast(std.math.clamp(tokens.metrics.spinner_segment_count, 3, 15));
}

// ------------------------------------------------------------------ chart

/// Draw a `.chart` widget: token-hairline gridlines and baseline first,
/// then opt-in axis tick labels in the muted text register, then each
/// series oldest-to-newest through the vector path pipeline — lines as
/// one `strokePath` (plus an optional translucent baseline-fill
/// `fillPath`), bands as one closed envelope `fillPath`, bars as one
/// pixel-snapped `fillRoundedRect` per value. Series colors resolve from
/// design tokens at emit time, so charts retheme with the palette.
/// Deterministic by construction: geometry is a pure function of the
/// series, the domain, and the frame; axis labels reserve gutters
/// (`chartWidgetPlotRect`) only when opted in, so unlabeled charts
/// render byte-identically to before.
fn emitChartWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const data = widget.chart;
    const plot = chartWidgetPlotRect(widget, tokens);
    if (plot.isEmpty() or plot.width <= 0 or plot.height <= 0) return;
    const domain = chart_model.chartDomain(data);

    const hairline = @max(1, tokens.stroke.hairline);
    if (data.grid_lines > 0 and data.y_labels) {
        // A LABELED chart's gridlines ride the nice tick lattice (the
        // labels are exact at those values, so grid and text can never
        // disagree); `grid_lines` becomes the density hint. Interior
        // ticks only — the plot edges and the baseline carry the ends.
        const lattice = chart_model.chartTickLattice(domain, @as(usize, data.grid_lines) + 1);
        for (0..lattice.count) |index| {
            const value = lattice.value(index);
            if (value <= domain.min or value >= domain.max) continue;
            const y = chartMapY(value, domain, plot, 0);
            try builder.fillRect(.{
                .id = chartCommandId(widget.id, chart_grid_seed, 0, index),
                .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(plot.x, y - hairline * 0.5, plot.width, hairline)),
                .fill = colorFill(tokens.colors.border),
            });
        }
    } else if (data.grid_lines > 0) {
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
    try emitChartAxisLabels(builder, widget, tokens, plot, domain);

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

// ------------------------------------------------------ chart axis labels

/// Tick-label type size: two rungs under the label register (13 -> 11
/// with house tokens), floored at 9 so dense themes stay legible. Axis
/// text is secondary chrome — it must never outweigh the data ink.
fn chartTickTextSize(tokens: DesignTokens) f32 {
    return @max(9, tokens.typography.label_size - 2);
}

/// Gap between the plot edge and its tick labels (the reference-grade
/// breathing room that keeps labels from touching the data ink).
const chart_axis_label_gap: f32 = 6;
/// Minimum clear space between adjacent x labels before thinning kicks
/// in (every Nth label draws).
const chart_x_label_min_gap: f32 = 12;

/// The rect the data plots into: the padded frame minus the gutters the
/// opted-in axis labels reserve (a line below for x labels, a measured
/// column at the left for y labels). Pure over the widget and tokens —
/// the runtime's hover hit logic and the renderer share it, so the
/// cursor snaps exactly where the ink is. Without labels this is the
/// padded frame, byte-identical to the pre-label contract.
pub fn chartWidgetPlotRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const data = widget.chart;
    var plot = widget.frame.inset(widget.layout.padding).normalized();
    if (data.x_labels.len > 0) {
        const gutter = chartTickTextSize(tokens) * 1.25 + chart_axis_label_gap;
        plot.height = @max(0, plot.height - gutter);
    }
    if (data.y_labels) {
        const gutter = chartYLabelGutterWidth(data, tokens);
        plot.x += gutter;
        plot.width = @max(0, plot.width - gutter);
    }
    return plot;
}

/// The y tick lattice a labeled chart rides: the nice-step lattice
/// (values exact at their precision), density-hinted by `grid_lines`
/// so labels and gridlines share positions.
fn chartYTickLattice(data: chart_model.ChartData, domain: chart_model.ChartDomain) chart_model.ChartTickLattice {
    return chart_model.chartTickLattice(domain, @as(usize, data.grid_lines) + 1);
}

/// Width of the y-label gutter: the widest formatted tick plus the
/// axis gap, measured through the same seam drawn text uses so the
/// reserved column always fits the ink.
fn chartYLabelGutterWidth(data: chart_model.ChartData, tokens: DesignTokens) f32 {
    const domain = chart_model.chartDomain(data);
    const lattice = chartYTickLattice(data, domain);
    const size = chartTickTextSize(tokens);
    var widest: f32 = 0;
    var buffer: [chart_model.max_chart_value_label_bytes]u8 = undefined;
    for (0..lattice.count) |ordinal| {
        const text = chart_model.formatChartValue(&buffer, lattice.value(ordinal), lattice.decimals);
        widest = @max(widest, measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, text, size));
    }
    return @ceil(widest) + chart_axis_label_gap;
}

/// Emit the opted-in tick labels: y values right-aligned into the left
/// gutter (each vertically centered on its lattice line, clamped inside
/// the padded frame so edge labels never ink outside the widget), and x
/// category labels centered under their sample columns, deterministically
/// thinned to every Nth so they never collide. Muted register — labels
/// are chrome, not data.
fn emitChartAxisLabels(builder: *Builder, widget: Widget, tokens: DesignTokens, plot: geometry.RectF, domain: chart_model.ChartDomain) Error!void {
    const data = widget.chart;
    const size = chartTickTextSize(tokens);
    const line_height = size * 1.25;
    const content = widget.frame.inset(widget.layout.padding).normalized();

    if (data.y_labels) {
        const lattice = chartYTickLattice(data, domain);
        var buffer: [chart_model.max_chart_value_label_bytes]u8 = undefined;
        for (0..lattice.count) |ordinal| {
            const value = lattice.value(ordinal);
            const formatted = chart_model.formatChartValue(&buffer, value, lattice.decimals);
            const text = try allocFrameLabelBytes(formatted);
            const width = measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, text, size);
            const line_y = chartMapY(value, domain, plot, 0);
            const top = std.math.clamp(line_y - line_height * 0.5, content.y, @max(content.y, content.maxY() - line_height));
            try builder.drawText(.{
                .id = chartCommandId(widget.id, chart_tick_seed, 0, ordinal),
                .font_id = tokens.typography.font_id,
                .size = size,
                .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(plot.x - chart_axis_label_gap - width, top + size)),
                .color = tokens.colors.text_muted,
                .text = text,
            });
        }
    }

    if (data.x_labels.len > 0) {
        const count = @max(chart_model.chartPointCount(data), data.x_labels.len);
        // Thinning: the widest label plus the minimum gap defines the
        // space one label needs; every Nth label draws so neighbors
        // never touch. Pure over the labels and the plot width.
        var widest: f32 = 0;
        for (data.x_labels) |label| {
            widest = @max(widest, measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, label, size));
        }
        const spacing = @max(1, widest + chart_x_label_min_gap);
        const fit: usize = @max(1, @as(usize, @intFromFloat(plot.width / spacing)));
        const stride = (data.x_labels.len + fit - 1) / fit;
        const baseline = @min(plot.maxY() + chart_axis_label_gap + size, content.maxY());
        var ordinal: usize = 0;
        while (ordinal < data.x_labels.len) : (ordinal += @max(1, stride)) {
            const label = data.x_labels[ordinal];
            if (label.len == 0) continue;
            const width = measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, label, size);
            const center_x = chartSampleX(data, count, ordinal, plot);
            const x = std.math.clamp(center_x - width * 0.5, content.x, @max(content.x, content.maxX() - width));
            try builder.drawText(.{
                .id = chartCommandId(widget.id, chart_tick_seed, 1, ordinal),
                .font_id = tokens.typography.font_id,
                .size = size,
                .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(x, baseline)),
                .color = tokens.colors.text_muted,
                .text = label,
            });
        }
    }
}

/// The x a sample index renders at: bars-only charts center samples in
/// equal-width slots, everything else sits on the point lattice — the
/// same split `chartHoverIndex` inverts, so labels, cursor, and dots
/// all agree on where a sample lives.
fn chartSampleX(data: chart_model.ChartData, count: usize, index: usize, plot: geometry.RectF) f32 {
    var bars_only = true;
    for (data.series) |series| {
        if (series.values.len > 0 and series.kind != .bar) bars_only = false;
    }
    if (bars_only and count > 0) {
        const slot = plot.width / @as(f32, @floatFromInt(count));
        return plot.x + slot * (@as(f32, @floatFromInt(index)) + 0.5);
    }
    return chartMapX(index, count, plot, 0);
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
        const elements = try allocFramePathElements(points.len + 3);
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

    const elements = try allocFramePathElements(points.len);
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
    const elements = try allocFramePathElements(upper.len + lower_count + 1);
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
const chart_tick_seed: u64 = 0x5eed_c4a8_0000_0007;
const chart_hover_seed: u64 = 0x5eed_c4a8_0000_0008;
const chart_hover_dot_seed: u64 = 0x5eed_c4a8_0000_0009;
const chart_hover_row_seed: u64 = 0x5eed_c4a8_0000_000a;

// ---------------------------------------------------- chart hover details

/// Detail-card type size: one rung under the label register (13 -> 12
/// with house tokens) — denser than control labels, a step above the
/// tick chrome, floored for dense themes.
fn chartDetailTextSize(tokens: DesignTokens) f32 {
    return @max(10, tokens.typography.label_size - 1);
}

const chart_detail_pad_h: f32 = 10;
const chart_detail_pad_v: f32 = 8;
const chart_detail_row_gap: f32 = 2;
const chart_detail_swatch: f32 = 8;
const chart_detail_swatch_gap: f32 = 6;
const chart_detail_column_gap: f32 = 16;
const chart_detail_anchor_gap: f32 = 12;
const chart_detail_edge_margin: f32 = 4;

/// Resolved hover-detail geometry: which sample the pointer snapped to
/// and where the floating card lands. Pure over the widget, tokens,
/// pointer point, and the window bounds the card clamps into — the
/// emitter and the invalidation path share it, so the repainted region
/// always covers the painted chrome.
pub const ChartHoverDetail = struct {
    index: usize,
    plot: geometry.RectF,
    /// The x the hovered sample renders at (cursor line and dots).
    sample_x: f32,
    card: geometry.RectF,
};

/// Value formatting for detail rows: two orders of magnitude below the
/// domain span, so a 0..1 chart reads "0.42" and a 0..500 chart reads
/// "237" — resolution that matches what the plot can show.
fn chartDetailDecimals(domain: chart_model.ChartDomain) u8 {
    return chart_model.chartTickDecimals(domain.span() / 100);
}

fn chartDetailRowName(series: chart_model.ChartSeries) []const u8 {
    return if (series.label.len > 0) series.label else @tagName(series.kind);
}

/// Compute the hover-detail geometry for a pointer over a chart, or
/// null when there is no sample to snap to. The card prefers the right
/// side of the hovered sample and flips left when the window edge is
/// closer than the card is wide; vertically it centers on the plot —
/// position depends only on the snapped index, never the raw pointer,
/// so a pointer gliding within one sample repaints nothing.
pub fn chartWidgetHoverDetail(widget: Widget, tokens: DesignTokens, point: geometry.PointF, bounds: geometry.RectF) ?ChartHoverDetail {
    if (widget.kind != .chart or !widget.chart.hover_details) return null;
    const data = widget.chart;
    const plot = chartWidgetPlotRect(widget, tokens);
    if (plot.isEmpty() or plot.width <= 0 or plot.height <= 0) return null;
    const count = chart_model.chartPointCount(data);
    const index = chart_model.chartHoverIndex(data, (point.x - plot.x) / plot.width) orelse return null;
    const domain = chart_model.chartDomain(data);
    const decimals = chartDetailDecimals(domain);
    const size = chartDetailTextSize(tokens);
    const line_height = size * 1.25;

    // Measure the card: title line (the sample's category label, or its
    // index) over one row per series that has this sample.
    var buffer: [chart_model.max_chart_value_label_bytes]u8 = undefined;
    const title = chartHoverDetailTitle(data, index, &buffer);
    var content_width = measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, title, size);
    var rows: usize = 0;
    for (data.series) |series| {
        if (index >= series.values.len) continue;
        rows += 1;
        var value_buffer: [chart_model.max_chart_value_label_bytes]u8 = undefined;
        const name_width = measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, chartDetailRowName(series), size);
        const value_text = chart_model.formatChartValue(&value_buffer, series.values[index], decimals);
        const value_width = measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, value_text, size);
        content_width = @max(content_width, chart_detail_swatch + chart_detail_swatch_gap + name_width + chart_detail_column_gap + value_width);
    }
    if (rows == 0) return null;

    const card_width = @ceil(content_width) + chart_detail_pad_h * 2;
    const card_height = chart_detail_pad_v * 2 + line_height * @as(f32, @floatFromInt(rows + 1)) + chart_detail_row_gap * @as(f32, @floatFromInt(rows));
    const sample_x = chartSampleX(data, count, index, plot);
    var card_x = sample_x + chart_detail_anchor_gap;
    if (card_x + card_width > bounds.maxX() - chart_detail_edge_margin) {
        card_x = sample_x - chart_detail_anchor_gap - card_width;
    }
    card_x = std.math.clamp(card_x, bounds.x + chart_detail_edge_margin, @max(bounds.x + chart_detail_edge_margin, bounds.maxX() - card_width - chart_detail_edge_margin));
    const card_y = std.math.clamp(plot.y + (plot.height - card_height) * 0.5, bounds.y + chart_detail_edge_margin, @max(bounds.y + chart_detail_edge_margin, bounds.maxY() - card_height - chart_detail_edge_margin));

    return .{
        .index = index,
        .plot = plot,
        .sample_x = sample_x,
        .card = geometry.RectF.init(card_x, card_y, card_width, card_height),
    };
}

/// The sample index a pointer over a hover-details chart snaps to, or
/// null when the widget is not a hover-details chart (or has no data).
/// The runtime's interaction path uses this to gate repaints: a pointer
/// gliding within one sample changes nothing, so nothing repaints.
pub fn chartWidgetHoverIndex(widget: Widget, tokens: DesignTokens, point: geometry.PointF) ?usize {
    if (widget.kind != .chart or !widget.chart.hover_details) return null;
    const plot = chartWidgetPlotRect(widget, tokens);
    if (plot.isEmpty() or plot.width <= 0 or plot.height <= 0) return null;
    return chart_model.chartHoverIndex(widget.chart, (point.x - plot.x) / plot.width);
}

/// The card's title: the hovered sample's category label when the chart
/// carries x labels, else the sample index — never invented text.
fn chartHoverDetailTitle(data: chart_model.ChartData, index: usize, buffer: *[chart_model.max_chart_value_label_bytes]u8) []const u8 {
    if (index < data.x_labels.len and data.x_labels[index].len > 0) return data.x_labels[index];
    return chart_model.formatChartValue(buffer, @floatFromInt(index), 0);
}

/// The region hover-detail chrome inks for a render state, for dirty
/// invalidation: the chart's frame (cursor line and dots live inside
/// it) unioned with the floating card. Null when the state paints no
/// hover chrome.
pub fn chartHoverDetailDirtyBounds(layout: anytype, state: WidgetRenderState, tokens: DesignTokens) ?geometry.RectF {
    const node_index = chartHoverDetailNodeIndex(layout, state) orelse return null;
    const point = state.hover_point orelse return null;
    const node = layout.nodes[node_index];
    const widget = widgetWithFrame(node.widget, node.frame);
    const bounds = widgetLayoutRootBounds(layout) orelse widget.frame.normalized();
    const detail = chartWidgetHoverDetail(widget, tokens, point, bounds) orelse return null;
    return geometry.RectF.unionWith(widget.frame.normalized(), detail.card);
}

/// The layout node the state's hover chrome belongs to: the hovered
/// widget when it is a hover-details chart that is actually visible.
fn chartHoverDetailNodeIndex(layout: anytype, state: WidgetRenderState) ?usize {
    const hovered_id = state.hovered_id orelse return null;
    if (hovered_id == 0 or state.hover_point == null) return null;
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id != hovered_id) continue;
        if (node.widget.kind != .chart or !node.widget.chart.hover_details) return null;
        if (widget_tree.isWidgetHiddenInAncestors(layout, index)) return null;
        return index;
    }
    return null;
}

/// The hover-detail z-pass: runs after the anchored-surface pass, so
/// the cursor, point dots, and floating card paint above everything —
/// the same clip-escaping contract tooltips have. Interaction-only by
/// construction: static trees never carry a `hover_point`, so goldens
/// and docs tiles stay byte-identical.
fn emitWidgetLayoutChartHoverDetails(builder: *Builder, layout: anytype, tokens: DesignTokens, state: WidgetRenderState) Error!void {
    const node_index = chartHoverDetailNodeIndex(layout, state) orelse return;
    const point = state.hover_point orelse return;
    const node = layout.nodes[node_index];
    const widget = widgetWithFrame(node.widget, pixelSnapGeometryRect(tokens, node.frame));
    const bounds = widgetLayoutRootBounds(layout) orelse widget.frame.normalized();
    const detail = chartWidgetHoverDetail(widget, tokens, point, bounds) orelse return;
    try emitChartHoverDetail(builder, widget, tokens, detail);
}

/// Draw the hover chrome: a hairline cursor at the hovered sample, a
/// dot on every line series' hovered point, then the floating card —
/// popover-grade chrome (surface fill, hairline border, small shadow)
/// holding the sample's title over swatch/name/value rows. Values
/// format deterministically into the frame label scratch.
fn emitChartHoverDetail(builder: *Builder, widget: Widget, tokens: DesignTokens, detail: ChartHoverDetail) Error!void {
    const data = widget.chart;
    const domain = chart_model.chartDomain(data);
    const decimals = chartDetailDecimals(domain);
    const hairline = @max(1, tokens.stroke.hairline);

    // Cursor: the vertical reading line the eye follows to the axis.
    try builder.fillRect(.{
        .id = chartCommandId(widget.id, chart_hover_seed, 0, 0),
        .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(detail.sample_x - hairline * 0.5, detail.plot.y, hairline, detail.plot.height)),
        .fill = colorFill(tokens.colors.border),
    });

    // Point dots on line series (bars read fine under the cursor line;
    // bands are ranges, not points).
    const stroke_inset = chartStrokeWidth(widget) * 0.5;
    for (data.series, 0..) |series, series_index| {
        if (series.kind != .line or detail.index >= series.values.len) continue;
        const value = series.values[detail.index];
        if (!std.math.isFinite(value)) continue;
        const dot_extent: f32 = 6;
        const dot_x = chartMapX(detail.index, series.values.len, detail.plot, stroke_inset);
        const dot_y = chartMapY(value, domain, detail.plot, stroke_inset);
        try builder.fillRoundedRect(.{
            .id = chartCommandId(widget.id, chart_hover_dot_seed, series_index, 0),
            .rect = geometry.RectF.init(dot_x - dot_extent * 0.5, dot_y - dot_extent * 0.5, dot_extent, dot_extent),
            .radius = Radius.all(dot_extent * 0.5),
            .fill = colorFill(text_spans_model.textSpanColorValue(tokens.colors, series.color)),
        });
    }

    // Card chrome: the popover register (surface, hairline border, the
    // small shadow step) — floating detail, not a modal surface.
    const card = pixelSnapGeometryRect(tokens, detail.card);
    const radius = Radius.all(tokens.radius.md);
    const shadow_token = tokens.shadow.sm;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = chartCommandId(widget.id, chart_hover_seed, 0, 1),
            .rect = card,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }
    try builder.fillRoundedRect(.{
        .id = chartCommandId(widget.id, chart_hover_seed, 0, 2),
        .rect = card,
        .radius = radius,
        .fill = colorFill(tokens.colors.surface),
    });
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = chartCommandId(widget.id, chart_hover_seed, 0, 3),
        .rect = card,
        .radius = radius,
        .stroke = .{ .fill = colorFill(tokens.colors.border), .width = hairline },
    }));

    // Title line, then one swatch/name/value row per series holding
    // this sample. Values right-align on the card's inner edge so a
    // column of numbers reads as one.
    const size = chartDetailTextSize(tokens);
    const line_height = size * 1.25;
    var title_buffer: [chart_model.max_chart_value_label_bytes]u8 = undefined;
    const title = chartHoverDetailTitle(data, detail.index, &title_buffer);
    const title_text = try allocFrameLabelBytes(title);
    var row_y = card.y + chart_detail_pad_v;
    try builder.drawText(.{
        .id = chartCommandId(widget.id, chart_hover_seed, 0, 4),
        .font_id = tokens.typography.font_id,
        .size = size,
        .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(card.x + chart_detail_pad_h, row_y + size)),
        .color = tokens.colors.text,
        .text = title_text,
    });
    row_y += line_height;
    for (data.series, 0..) |series, series_index| {
        if (detail.index >= series.values.len) continue;
        row_y += chart_detail_row_gap;
        const swatch_y = row_y + (line_height - chart_detail_swatch) * 0.5;
        try builder.fillRoundedRect(.{
            .id = chartCommandId(widget.id, chart_hover_row_seed, series_index, 0),
            .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(card.x + chart_detail_pad_h, swatch_y, chart_detail_swatch, chart_detail_swatch)),
            .radius = Radius.all(2),
            .fill = colorFill(text_spans_model.textSpanColorValue(tokens.colors, series.color)),
        });
        try builder.drawText(.{
            .id = chartCommandId(widget.id, chart_hover_row_seed, series_index, 1),
            .font_id = tokens.typography.font_id,
            .size = size,
            .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(card.x + chart_detail_pad_h + chart_detail_swatch + chart_detail_swatch_gap, row_y + size)),
            .color = tokens.colors.text_muted,
            .text = chartDetailRowName(series),
        });
        var value_buffer: [chart_model.max_chart_value_label_bytes]u8 = undefined;
        const value_text = try allocFrameLabelBytes(chart_model.formatChartValue(&value_buffer, series.values[detail.index], decimals));
        const value_width = measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, value_text, size);
        try builder.drawText(.{
            .id = chartCommandId(widget.id, chart_hover_row_seed, series_index, 2),
            .font_id = tokens.typography.font_id,
            .size = size,
            .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(card.maxX() - chart_detail_pad_h - value_width, row_y + size)),
            .color = tokens.colors.text,
            .text = value_text,
        });
        row_y += line_height;
    }
}

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

/// The command id of an editable text widget's caret line — the part
/// slot `emitTextFieldWidget` / `emitSearchFieldWidget` draw it under —
/// so the runtime can target the caret with a blink render animation.
/// 0 for kinds that never draw a caret.
pub fn textCaretCommandId(kind: WidgetKind, id: ObjectId) ObjectId {
    return switch (kind) {
        .input, .text_field, .textarea => widgetPartId(id, 6),
        .search_field, .combobox => widgetPartId(id, 11),
        else => 0,
    };
}

pub fn toggleWidgetKnobTravel(widget: Widget, tokens: DesignTokens) f32 {
    if (!widgetSwitchControlKind(widget.kind)) return 0;
    // Shares the renderer's track/inset metrics (44x24 track, 2px thumb
    // inset, both size- and density-scaled) so animated travel lands on
    // exactly the painted on/off thumb positions.
    const knob_inset = widget_metrics.widgetSizedDensityValue(widget, tokens, 2);
    const track = widget_render_controls.toggleWidgetTrackRect(widget, tokens);
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
    return kind == .switch_control;
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
        // heading/display are text-leaf typography rungs; icon glyphs
        // keep the default control proportion.
        .default, .icon, .heading, .display => 0.48,
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
