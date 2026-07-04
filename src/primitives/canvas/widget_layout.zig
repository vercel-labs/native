const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_model = @import("text.zig");
const text_spans_model = @import("text_spans.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const widget_tree = @import("widget_tree.zig");
const widget_access = @import("widget_access.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_render = @import("widget_render.zig");

const Error = canvas.Error;
const Widget = widget_model.Widget;
const WidgetMainAlignment = widget_model.WidgetMainAlignment;
const WidgetCrossAlignment = widget_model.WidgetCrossAlignment;
const WidgetLayoutStyle = widget_model.WidgetLayoutStyle;
const WidgetLayoutNode = event_model.WidgetLayoutNode;
const DesignTokens = token_model.DesignTokens;
const virtualListRange = token_model.virtualListRange;
const measureTextWidthForFont = text_model.measureTextWidthForFont;

/// Text width for intrinsic sizing: the injected provider on `tokens` when
/// present, the deterministic estimator otherwise.
fn measuredTextWidth(tokens: DesignTokens, text: []const u8, size: f32) f32 {
    return measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, text, size);
}
const gridColumnCount = widget_tree.gridColumnCount;
const gridRowCount = widget_tree.gridRowCount;
const saturatingU32 = widget_tree.saturatingU32;
const booleanControlSelected = widget_access.booleanControlSelected;
const widgetButtonTextSize = widget_metrics.widgetButtonTextSize;
const widgetBodyTextSize = widget_metrics.widgetBodyTextSize;
const widgetLabelTextSize = widget_metrics.widgetLabelTextSize;
const widgetTypographySize = widget_metrics.widgetTypographySize;
const widgetLineHeight = widget_metrics.widgetLineHeight;
const widgetDefaultRowHeight = widget_metrics.widgetDefaultRowHeight;
const widgetButtonInset = widget_metrics.widgetButtonInset;
const widgetControlInset = widget_metrics.widgetControlInset;
const widgetSizedDensityValue = widget_metrics.widgetSizedDensityValue;
const widgetControlHeight = widget_metrics.widgetControlHeight;
const widgetStatusBarPadding = widget_render.widgetStatusBarPadding;
const controlStrokeWidth = widget_render.controlStrokeWidth;
const componentControlVisualTokens = widget_render.componentControlVisualTokens;
const widgetTextSpanLayoutOptions = widget_metrics.widgetTextSpanLayoutOptions;

pub const max_widget_depth: usize = 32;

pub fn layoutWidgetDepth(
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
                    if (child.layout.anchor != null) continue;
                    _ = try layoutWidgetDepth(child, stackChildFrame(child_content, child), index, depth + 1, output, len, tokens);
                }
            }
        },
        .stack, .alert, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover => {
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                _ = try layoutWidgetDepth(child, stackChildFrame(content, child), index, depth + 1, output, len, tokens);
            }
        },
        // Span paragraphs and span-carrying table cells share the link
        // hotspot child convention (no spans or no children is a no-op).
        .text, .data_cell => try layoutTextSpanLinkChildren(widget, content, index, depth, output, len, tokens),
        .icon, .image, .avatar, .badge, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .tooltip, .menu_item, .list_item, .status_bar, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .progress, .separator, .skeleton, .spinner, .chart => {},
    }

    // Anchored floating children are excluded from every flow above (they
    // consume no parent space) and positioned here instead, against this
    // widget's resolved frame and the window (the layout root's frame).
    // Leaf trigger kinds (select, button, ...) never lay out flow
    // children, but their anchored children float all the same.
    try layoutAnchoredChildren(widget.children, frame, index, depth, output, len, tokens);

    return index;
}

fn layoutAnchoredChildren(
    children: []const Widget,
    anchor_rect: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    tokens: DesignTokens,
) Error!void {
    for (children) |child| {
        const anchor = child.layout.anchor orelse continue;
        const child_frame = anchoredWidgetFrame(child, anchor, anchor_rect, output[0].frame, tokens);
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
    }
}

/// Resolved frame of an anchored floating widget: sized from its explicit
/// frame or intrinsic content (`stretch` widens to at least the anchor's
/// width), placed on the preferred side of the anchor rect — flipping to
/// the other side when it does not fit and the other side has more room —
/// with height clamped to the chosen side's space and both axes clamped
/// into the window. Pure geometry, unit-testable on its own.
pub fn anchoredWidgetFrame(
    child: Widget,
    anchor: widget_model.WidgetAnchor,
    anchor_rect: geometry.RectF,
    window_rect: geometry.RectF,
    tokens: DesignTokens,
) geometry.RectF {
    const window = window_rect.normalized();
    const anchor_frame = anchor_rect.normalized();
    const intrinsic = intrinsicWidgetSize(child, tokens);

    var width = if (child.frame.width > 0) child.frame.width else intrinsic.width;
    if (anchor.alignment == .stretch) width = @max(width, anchor_frame.width);
    width = clampIntrinsicAxis(width, child.layout.min_size.width, child.layout.max_size.width);
    width = @min(width, window.width);

    var height = if (child.frame.height > 0) child.frame.height else intrinsic.height;
    height = clampIntrinsicAxis(height, child.layout.min_size.height, child.layout.max_size.height);

    const offset = nonNegative(anchor.offset);
    const space_below = window.maxY() - anchor_frame.maxY() - offset;
    const space_above = anchor_frame.y - window.y - offset;
    const preferred_space = switch (anchor.placement) {
        .below => space_below,
        .above => space_above,
    };
    const other_space = switch (anchor.placement) {
        .below => space_above,
        .above => space_below,
    };
    const flipped = height > preferred_space and other_space > preferred_space;
    const below = (anchor.placement == .below) != flipped;
    const side_space = @max(0, if (below) space_below else space_above);
    height = @min(height, side_space);

    const y = if (below) anchor_frame.maxY() + offset else anchor_frame.y - offset - height;
    var x = switch (anchor.alignment) {
        .start, .stretch => anchor_frame.x,
        .end => anchor_frame.maxX() - width,
    };
    x = std.math.clamp(x, window.x, @max(window.x, window.maxX() - width));
    const clamped_y = std.math.clamp(y, window.y, @max(window.y, window.maxY() - height));
    return geometry.RectF.init(x, clamped_y, width, height);
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
    // Anchored floating children take no flow slot: they are skipped in
    // every pass here (measurement, gap counting, placement) and laid out
    // by `layoutAnchoredChildren` against the parent's frame instead.
    var flow_count: usize = 0;
    for (children) |child| {
        if (child.layout.anchor == null) flow_count += 1;
    }
    if (flow_count == 0) return;

    const available_extent = switch (axis) {
        .horizontal => content.width,
        .vertical => content.height,
    };
    const cross_extent = switch (axis) {
        .horizontal => content.height,
        .vertical => content.width,
    };
    const clamped_gap = nonNegative(style.gap);
    const total_gap = clamped_gap * @as(f32, @floatFromInt(flow_count - 1));
    var fixed_extent: f32 = 0;
    var grow_total: f32 = 0;
    for (children) |child| {
        if (child.layout.anchor != null) continue;
        const grow = nonNegative(child.layout.grow);
        if (grow > 0) {
            grow_total += grow;
        } else {
            fixed_extent += preferredMainExtentInCross(child, axis, cross_extent, style.cross_alignment, tokens);
        }
    }

    const remaining = @max(0, available_extent - fixed_extent - total_gap);
    const assigned_extent = assignedAxisChildrenExtent(children, axis, fixed_extent, grow_total, remaining);
    const used_extent = assigned_extent + total_gap;
    if (axisLayoutOverflow(available_extent, used_extent)) |overflow| {
        logAxisChildrenOverflow(output[parent_index].widget.kind, axis, available_extent, used_extent, overflow);
    }
    const free_extent = @max(0, available_extent - used_extent);
    var child_gap = clamped_gap;
    if (style.main_alignment == .space_between and flow_count > 1) {
        child_gap += free_extent / @as(f32, @floatFromInt(flow_count - 1));
    }
    var cursor: f32 = switch (axis) {
        .horizontal => content.x,
        .vertical => content.y,
    } + mainAxisAlignmentOffset(style.main_alignment, free_extent);

    for (children) |child| {
        if (child.layout.anchor != null) continue;
        const grow = nonNegative(child.layout.grow);
        const main_extent = if (grow > 0 and grow_total > 0)
            clampMainExtent(child, axis, remaining * grow / grow_total)
        else
            preferredMainExtentInCross(child, axis, cross_extent, style.cross_alignment, tokens);
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

/// Tolerance separating real layout overflow from float noise.
pub const axis_layout_overflow_epsilon: f32 = 0.5;

/// Positive overflow of the children's assigned extent past the
/// container's content extent, or null when everything fits. Grow
/// children participate with their min-size floors, fixed children with
/// their preferred (intrinsic or explicit) extents — exactly the floors
/// `layoutAxisChildren` cannot shrink below.
pub fn axisLayoutOverflow(available_extent: f32, used_extent: f32) ?f32 {
    const overflow = used_extent - available_extent;
    if (overflow <= axis_layout_overflow_epsilon) return null;
    return overflow;
}

const layout_log = std.log.scoped(.zero_canvas_layout);

/// Debug-build diagnostic for silent flex overflow: when the children's
/// minimum extents exceed the container, the extra pixels spill past the
/// content box with no visual cue at authoring time. Logged at .debug so
/// debug app runs surface it while release builds and test runs stay
/// quiet.
fn logAxisChildrenOverflow(kind: widget_model.WidgetKind, axis: LayoutAxis, available_extent: f32, used_extent: f32, overflow: f32) void {
    if (builtin.mode != .Debug) return;
    layout_log.debug(
        "{s} children overflow the {s} axis by {d:.1}px (need {d:.1}px, have {d:.1}px): intrinsic/min sizes exceed the container - shrink the content, or give siblings grow factors or definite width/height that fit",
        .{ @tagName(kind), @tagName(axis), overflow, used_extent, available_extent },
    );
}

/// Floor `value` with the widget's `min_size` for the axis and cap it at
/// `max_size` when set (0 = unbounded). Explicit author sizes write both
/// bounds, making the extent definite.
fn clampMainExtent(widget: Widget, axis: LayoutAxis, value: f32) f32 {
    return @max(minMainExtent(widget, axis), boundedByMax(value, maxMainExtent(widget, axis)));
}

fn maxMainExtent(widget: Widget, axis: LayoutAxis) f32 {
    return switch (axis) {
        .horizontal => widget.layout.max_size.width,
        .vertical => widget.layout.max_size.height,
    };
}

fn boundedByMax(value: f32, max: f32) f32 {
    return if (max > 0) @min(value, max) else value;
}

/// Main extent of a non-growing flex child, given the cross-axis space it
/// will be offered. Identical to `preferredMainExtent` unless the child's
/// subtree contains span paragraphs and the axis is vertical: those
/// reserve their wrapped height at the width they will receive, so
/// stacked markdown blocks do not overlap. Trees without spans keep the
/// classic single-pass behavior byte-for-byte.
fn preferredMainExtentInCross(
    child: Widget,
    axis: LayoutAxis,
    cross_extent: f32,
    alignment: WidgetCrossAlignment,
    tokens: DesignTokens,
) f32 {
    if (axis == .vertical and child.frame.height <= 0 and widgetSubtreeHasTextSpans(child, 0)) {
        const width = preferredCrossExtent(child, axis, cross_extent, alignment, tokens);
        return clampMainExtent(child, axis, wrappedVerticalExtentForWidth(child, width, tokens, 0));
    }
    return preferredMainExtent(child, axis, tokens);
}

/// Kinds whose `spans` field drives a span-paragraph text layout: plain
/// paragraphs and table cells (markdown tables put inline-styled runs in
/// `data_cell` widgets).
fn widgetIsSpanParagraph(widget: Widget) bool {
    return (widget.kind == .text or widget.kind == .data_cell) and widget.spans.len > 0;
}

fn widgetSubtreeHasTextSpans(widget: Widget, depth: usize) bool {
    if (depth >= max_widget_depth) return false;
    if (widgetIsSpanParagraph(widget)) return true;
    for (widget.children) |child| {
        if (widgetSubtreeHasTextSpans(child, depth + 1)) return true;
    }
    return false;
}

/// Wrapped vertical extent of a widget when it is laid out at `width`.
/// This is the width-aware twin of `intrinsicWidgetSize` that span
/// paragraphs need; it recurses through the container kinds markdown
/// content composes from and falls back to the classic intrinsic extent
/// everywhere else.
fn wrappedVerticalExtentForWidth(widget: Widget, width: f32, tokens: DesignTokens, depth: usize) f32 {
    if (depth >= max_widget_depth) return preferredMainExtent(widget, .vertical, tokens);
    if (widget.frame.height > 0) return clampMainExtent(widget, .vertical, widget.frame.height);
    const padding = widget.layout.padding;
    const inner_width = @max(0, width - padding.left - padding.right);
    const content_height: f32 = switch (widget.kind) {
        .text, .data_cell => if (widget.spans.len > 0)
            spanParagraphHeight(widget, inner_width, tokens)
        else
            return preferredMainExtent(widget, .vertical, tokens),
        .column, .list, .data_grid, .table, .menu_surface, .dropdown_menu => blk: {
            if (widget.layout.virtualized) return preferredMainExtent(widget, .vertical, tokens);
            var sum: f32 = 0;
            var flow_count: usize = 0;
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                const child_width = if (child.frame.width > 0) child.frame.width else inner_width;
                sum += wrappedVerticalExtentForWidth(child, child_width, tokens, depth + 1);
                flow_count += 1;
            }
            if (flow_count > 1) {
                sum += nonNegative(widget.layout.gap) * @as(f32, @floatFromInt(flow_count - 1));
            }
            break :blk sum;
        },
        .stack, .panel, .card, .alert, .bubble, .resizable, .popover => blk: {
            var max_height: f32 = 0;
            for (widget.children) |child| {
                if (child.layout.anchor != null) continue;
                const child_width = if (child.frame.width > 0) child.frame.width else inner_width;
                max_height = @max(max_height, wrappedVerticalExtentForWidth(child, child_width, tokens, depth + 1));
            }
            break :blk max_height;
        },
        .row, .data_row, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group => blk: {
            var max_height: f32 = 0;
            for (widget.children, 0..) |child, index| {
                if (child.layout.anchor != null) continue;
                max_height = @max(max_height, wrappedVerticalExtentForWidth(
                    child,
                    rowChildWidth(widget, inner_width, index, tokens),
                    tokens,
                    depth + 1,
                ));
            }
            break :blk max_height;
        },
        else => return preferredMainExtent(widget, .vertical, tokens),
    };
    return clampMainExtent(widget, .vertical, content_height + padding.top + padding.bottom);
}

/// The width the `index`-th child of a horizontal container receives —
/// the same fixed-vs-grow split `layoutAxisChildren` performs, replayed
/// so wrapped heights inside rows (blockquotes, list items) are computed
/// against real widths.
fn rowChildWidth(row: Widget, available_width: f32, index: usize, tokens: DesignTokens) f32 {
    const children = row.children;
    if (children.len == 0) return available_width;
    var flow_count: usize = 0;
    var fixed_extent: f32 = 0;
    var grow_total: f32 = 0;
    for (children) |child| {
        if (child.layout.anchor != null) continue;
        flow_count += 1;
        const grow = nonNegative(child.layout.grow);
        if (grow > 0) {
            grow_total += grow;
        } else {
            fixed_extent += preferredMainExtent(child, .horizontal, tokens);
        }
    }
    if (flow_count == 0) return available_width;
    const total_gap = nonNegative(row.layout.gap) * @as(f32, @floatFromInt(flow_count - 1));
    const remaining = @max(0, available_width - fixed_extent - total_gap);
    const child = children[index];
    const grow = nonNegative(child.layout.grow);
    if (grow > 0 and grow_total > 0) return clampMainExtent(child, .horizontal, remaining * grow / grow_total);
    return preferredMainExtent(child, .horizontal, tokens);
}

fn spanParagraphHeight(widget: Widget, width: f32, tokens: DesignTokens) f32 {
    return text_spans_model.textSpansWrappedHeight(
        widget.spans,
        widgetTextSpanLayoutOptions(widget, tokens, width),
    );
}

/// Position a span paragraph's link hit-area children. By convention the
/// children of a `.text` widget with spans are its link hotspots, one per
/// link span in order (`Ui.paragraph` builds them). Each child gets the
/// union frame of its span's laid-out runs; surplus children collapse to
/// an empty frame (never hit-testable).
fn layoutTextSpanLinkChildren(
    widget: Widget,
    content: geometry.RectF,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    tokens: DesignTokens,
) Error!void {
    if (widget.children.len == 0) return;
    if (widget.spans.len == 0) return;

    var runs: [text_spans_model.max_text_span_runs_per_paragraph]text_spans_model.TextSpanRun = undefined;
    const layout = text_spans_model.layoutTextSpans(
        widget.spans,
        widgetTextSpanLayoutOptions(widget, tokens, content.width),
        &runs,
    );

    var child_index: usize = 0;
    for (widget.spans, 0..) |span, span_index| {
        if (span.link.len == 0) continue;
        if (child_index >= widget.children.len) break;
        const child = widget.children[child_index];
        child_index += 1;
        if (child.layout.anchor != null) continue;
        const frame = if (text_spans_model.textSpanBounds(layout, span_index)) |bounds|
            geometry.RectF.init(content.x + bounds.x, content.y + bounds.y, bounds.width, bounds.height)
        else
            geometry.RectF.init(content.x, content.y, 0, 0);
        _ = try layoutWidgetDepth(child, frame, parent_index, depth + 1, output, len, tokens);
    }
    while (child_index < widget.children.len) : (child_index += 1) {
        if (widget.children[child_index].layout.anchor != null) continue;
        _ = try layoutWidgetDepth(widget.children[child_index], geometry.RectF.init(content.x, content.y, 0, 0), parent_index, depth + 1, output, len, tokens);
    }
}

fn assignedAxisChildrenExtent(children: []const Widget, axis: LayoutAxis, fixed_extent: f32, grow_total: f32, remaining: f32) f32 {
    if (grow_total <= 0) return fixed_extent;
    var assigned = fixed_extent;
    for (children) |child| {
        if (child.layout.anchor != null) continue;
        const grow = nonNegative(child.layout.grow);
        if (grow <= 0) continue;
        assigned += clampMainExtent(child, axis, remaining * grow / grow_total);
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
        // Anchored floating children keep their grid slot empty.
        if (child.layout.anchor != null) continue;
        const column = child_index % columns;
        const row = child_index / columns;
        const x = content.x + @as(f32, @floatFromInt(column)) * (cell_width + clamped_gap);
        const y = content.y + @as(f32, @floatFromInt(row)) * (fallback_cell_height + clamped_gap);
        const width = clampIntrinsicAxis(if (child.frame.width > 0) child.frame.width else cell_width, child.layout.min_size.width, child.layout.max_size.width);
        const height = clampIntrinsicAxis(if (child.frame.height > 0) child.frame.height else fallback_cell_height, child.layout.min_size.height, child.layout.max_size.height);
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
            if (children[child_index].layout.anchor != null) continue;

            var child = children[child_index];
            child.semantics.list_item_index = saturatingU32(child_index);
            child.semantics.list_item_count = saturatingU32(children.len);
            const x = content.x + @as(f32, @floatFromInt(column)) * (cell_width + clamped_gap);
            const y = content.y + @as(f32, @floatFromInt(row)) * stride - range.layout_offset + child.frame.y;
            const width = clampIntrinsicAxis(if (child.frame.width > 0) child.frame.width else cell_width, child.layout.min_size.width, child.layout.max_size.width);
            const height = clampIntrinsicAxis(if (child.frame.height > 0) child.frame.height else range.item_extent, child.layout.min_size.height, child.layout.max_size.height);
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
        if (child.layout.anchor != null) continue;
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
        if (children[index].layout.anchor != null) continue;
        var child = children[index];
        child.semantics.list_item_index = saturatingU32(index);
        child.semantics.list_item_count = saturatingU32(children.len);
        const y = content.y + @as(f32, @floatFromInt(index)) * stride - range.layout_offset + child.frame.y;
        const width = clampIntrinsicAxis(if (child.frame.width > 0) child.frame.width else content.width, child.layout.min_size.width, child.layout.max_size.width);
        const height = clampIntrinsicAxis(if (child.frame.height > 0) child.frame.height else range.item_extent, child.layout.min_size.height, child.layout.max_size.height);
        const child_frame = geometry.RectF.init(
            content.x + child.frame.x,
            y,
            width,
            height,
        );
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len, tokens);
    }
}

/// Widget kinds whose layout gives every child the full content box
/// (the `stackChildFrame` arm in `layoutWidgetDepth` — keep the two in
/// lockstep): children layer on top of each other, so `layout.gap` can
/// never space them. This is the source of truth for the builder's Debug
/// gap diagnostic and (via a name list kept in sync by a test in
/// ui_markup_view_tests.zig) the markup validator's stack-container list.
/// `scroll_view` and `accordion` also stack children but consume `gap`
/// (virtualized item spacing; header-to-content spacing), so they are
/// excluded on purpose.
pub fn widgetKindStacksChildren(kind: widget_model.WidgetKind) bool {
    return switch (kind) {
        .stack, .alert, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover => true,
        else => false,
    };
}

fn stackChildFrame(content: geometry.RectF, child: Widget) geometry.RectF {
    const width = if (child.frame.width > 0) child.frame.width else content.width;
    const height = if (child.frame.height > 0) child.frame.height else content.height;
    return geometry.RectF.init(
        content.x + child.frame.x,
        content.y + child.frame.y,
        clampIntrinsicAxis(width, child.layout.min_size.width, child.layout.max_size.width),
        clampIntrinsicAxis(height, child.layout.min_size.height, child.layout.max_size.height),
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
    return intrinsicWidgetSizeDepth(widget, tokens, 0);
}

fn intrinsicWidgetSizeDepth(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
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
        .menu_item, .list_item => intrinsicRowTextWidgetSize(widget, tokens),
        // A span-carrying cell (markdown tables) measures like a padded
        // span paragraph; classic cells keep the single-line row metric.
        .data_cell => if (widget.spans.len > 0)
            paddedIntrinsicSize(widget, intrinsicTextWidgetSize(widget, tokens, widgetBodyTextSize(widget, tokens)))
        else
            intrinsicRowTextWidgetSize(widget, tokens),
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
        // A plot has no natural content size; the default is a small
        // sparkline-friendly box, and definite `width`/`height` (or flex
        // grow) size real charts.
        .chart => geometry.SizeF.init(widgetSizedDensityValue(widget, tokens, 160), widgetSizedDensityValue(widget, tokens, 48)),
        .alert => intrinsicAlertWidgetSize(widget, tokens),
        .card => intrinsicCardWidgetSize(widget, tokens),
        .dialog, .drawer, .sheet => intrinsicModalSurfaceWidgetSize(widget, tokens),
        // Containers measure their children (matching the stacking axis the
        // layout pass uses), bounded by the widget depth cap. Scroll
        // viewports and virtualized containers stay zero: their content is
        // allowed to overflow the space they're given.
        .row, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group => intrinsicAxisChildrenSize(widget, tokens, .horizontal, depth),
        .column, .menu_surface, .dropdown_menu => intrinsicAxisChildrenSize(widget, tokens, .vertical, depth),
        .list, .data_grid, .table => if (widget.layout.virtualized)
            geometry.SizeF.zero()
        else
            intrinsicAxisChildrenSize(widget, tokens, .vertical, depth),
        .grid => if (widget.layout.virtualized)
            geometry.SizeF.zero()
        else
            intrinsicGridChildrenSize(widget, tokens, depth),
        .stack, .bubble, .resizable, .panel, .popover => intrinsicOverlayChildrenSize(widget, tokens, depth),
        .scroll_view, .accordion, .image => geometry.SizeF.zero(),
    };
}

fn intrinsicChildSize(child: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    const intrinsic = intrinsicWidgetSizeDepth(child, tokens, depth);
    return geometry.SizeF.init(
        clampIntrinsicAxis(@max(intrinsic.width, nonNegative(child.frame.width)), child.layout.min_size.width, child.layout.max_size.width),
        clampIntrinsicAxis(@max(intrinsic.height, nonNegative(child.frame.height)), child.layout.min_size.height, child.layout.max_size.height),
    );
}

fn clampIntrinsicAxis(value: f32, min: f32, max: f32) f32 {
    return @max(min, boundedByMax(value, max));
}

/// Child contribution to a flex container's intrinsic size. A bare
/// separator inside a horizontal container is a divider: it contributes
/// its stroke thickness on both axes (thin along the row, cross-sized by
/// the siblings it divides) instead of its default horizontal-rule
/// length. Vertical containers keep the classic contribution.
fn intrinsicChildSizeInAxis(child: Widget, tokens: DesignTokens, depth: usize, axis: LayoutAxis) geometry.SizeF {
    const size = intrinsicChildSize(child, tokens, depth);
    if (child.kind == .separator and axis == .horizontal and child.frame.width <= 0) {
        const thin = @min(size.width, size.height);
        return geometry.SizeF.init(
            @max(nonNegative(child.layout.min_size.width), thin),
            @max(nonNegative(child.layout.min_size.height), thin),
        );
    }
    return size;
}

fn intrinsicAxisChildrenSize(widget: Widget, tokens: DesignTokens, axis: LayoutAxis, depth: usize) geometry.SizeF {
    if (depth >= max_widget_depth or widget.children.len == 0) return intrinsicOwnMinSize(widget);
    var flow_count: usize = 0;
    var main_sum: f32 = 0;
    var cross_max: f32 = 0;
    for (widget.children) |child| {
        // Anchored floating children never grow their parent.
        if (child.layout.anchor != null) continue;
        flow_count += 1;
        const size = intrinsicChildSizeInAxis(child, tokens, depth + 1, axis);
        switch (axis) {
            .horizontal => {
                main_sum += size.width;
                cross_max = @max(cross_max, size.height);
            },
            .vertical => {
                main_sum += size.height;
                cross_max = @max(cross_max, size.width);
            },
        }
    }
    if (flow_count == 0) return intrinsicOwnMinSize(widget);
    const gap = nonNegative(widget.layout.gap) * @as(f32, @floatFromInt(flow_count - 1));
    return paddedIntrinsicSize(widget, switch (axis) {
        .horizontal => geometry.SizeF.init(main_sum + gap, cross_max),
        .vertical => geometry.SizeF.init(cross_max, main_sum + gap),
    });
}

fn intrinsicOverlayChildrenSize(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    if (depth >= max_widget_depth or widget.children.len == 0) return intrinsicOwnMinSize(widget);
    var width_max: f32 = 0;
    var height_max: f32 = 0;
    for (widget.children) |child| {
        if (child.layout.anchor != null) continue;
        const size = intrinsicChildSize(child, tokens, depth + 1);
        width_max = @max(width_max, size.width);
        height_max = @max(height_max, size.height);
    }
    return paddedIntrinsicSize(widget, geometry.SizeF.init(width_max, height_max));
}

fn intrinsicGridChildrenSize(widget: Widget, tokens: DesignTokens, depth: usize) geometry.SizeF {
    if (depth >= max_widget_depth or widget.children.len == 0) return intrinsicOwnMinSize(widget);
    var cell_width: f32 = 0;
    var cell_height: f32 = 0;
    for (widget.children) |child| {
        if (child.layout.anchor != null) continue;
        const size = intrinsicChildSize(child, tokens, depth + 1);
        cell_width = @max(cell_width, size.width);
        cell_height = @max(cell_height, size.height);
    }
    const columns = gridColumnCount(widget.children.len, widget.layout.columns);
    const rows = (widget.children.len + columns - 1) / columns;
    const gap = nonNegative(widget.layout.gap);
    return paddedIntrinsicSize(widget, geometry.SizeF.init(
        cell_width * @as(f32, @floatFromInt(columns)) + gap * @as(f32, @floatFromInt(columns - 1)),
        cell_height * @as(f32, @floatFromInt(rows)) + gap * @as(f32, @floatFromInt(rows - 1)),
    ));
}

fn intrinsicOwnMinSize(widget: Widget) geometry.SizeF {
    return geometry.SizeF.init(nonNegative(widget.layout.min_size.width), nonNegative(widget.layout.min_size.height));
}

fn paddedIntrinsicSize(widget: Widget, content: geometry.SizeF) geometry.SizeF {
    const padding = widget.layout.padding;
    return geometry.SizeF.init(
        @max(content.width + padding.left + padding.right, widget.layout.min_size.width),
        @max(content.height + padding.top + padding.bottom, widget.layout.min_size.height),
    );
}

fn intrinsicTextWidgetSize(widget: Widget, tokens: DesignTokens, text_size: f32) geometry.SizeF {
    if (widgetIsSpanParagraph(widget)) {
        const options = widgetTextSpanLayoutOptions(widget, tokens, 0);
        return geometry.SizeF.init(
            text_spans_model.textSpansIntrinsicWidth(widget.spans, options),
            widgetLineHeight(text_size * text_spans_model.textSpansMaxScale(widget.spans)),
        );
    }
    return geometry.SizeF.init(
        measuredTextWidth(tokens, widget.text, text_size),
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
    // An inline icon (`widget.icon`) widens the button: icon + gap before
    // the label, or a square control when the label is empty. The extent
    // and gap are the shared render metrics, so measured width matches
    // painted pixels.
    if (widget.icon.len > 0 and widget.text.len == 0) return geometry.SizeF.init(height, height);
    const icon_width = if (widget.icon.len > 0)
        widget_metrics.widgetButtonIconExtent(widget, tokens) + widget_metrics.widgetButtonIconGap(widget, tokens)
    else
        0;
    const text_width = measuredTextWidth(tokens, widget.text, widgetButtonTextSize(widget, tokens));
    const width = @max(widgetSizedDensityValue(widget, tokens, 44), icon_width + text_width + widgetButtonInset(widget, tokens) * 2);
    return geometry.SizeF.init(width, height);
}

fn intrinsicAvatarWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const size = widgetSizedDensityValue(widget, tokens, 40);
    return geometry.SizeF.init(size, size);
}

fn intrinsicBadgeWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_width = measuredTextWidth(tokens, widget.text, widgetLabelTextSize(widget, tokens));
    const inset = widgetControlInset(widget, tokens, tokens.spacing.sm);
    // An inline icon widens the badge by the same shared metrics
    // the renderer paints with (gap only when a label follows).
    const icon_width = if (widget.icon.len > 0)
        widget_metrics.widgetBadgeIconExtent(widget, tokens) + (if (widget.text.len > 0) widget_metrics.widgetBadgeIconGap(widget, tokens) else 0)
    else
        0;
    return geometry.SizeF.init(@max(widgetSizedDensityValue(widget, tokens, 24), icon_width + text_width + inset * 2), widgetSizedDensityValue(widget, tokens, 22));
}

fn intrinsicSquareControlSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const height = widgetControlHeight(widget, tokens);
    return geometry.SizeF.init(height, height);
}

fn intrinsicSegmentedControlSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_width = measuredTextWidth(tokens, widget.text, widgetLabelTextSize(widget, tokens));
    const width = @max(widgetSizedDensityValue(widget, tokens, 44), text_width + widgetControlInset(widget, tokens, tokens.spacing.md) * 2);
    return geometry.SizeF.init(width, widgetControlHeight(widget, tokens));
}

fn intrinsicRowTextWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text_width = measuredTextWidth(tokens, widget.text, text_size);
    // A leading icon widens the row by the same shared metrics the
    // renderer paints with, so measured widths and pixels agree.
    const icon_width = if (widget.icon.len > 0)
        widget_metrics.widgetRowIconExtent(widget, tokens) + widget_metrics.widgetRowIconGap(widget, tokens)
    else
        0;
    return geometry.SizeF.init(icon_width + text_width + inset * 2, widgetDefaultRowHeight(widget, tokens));
}

fn intrinsicCheckboxWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const box_size = widgetSizedDensityValue(widget, tokens, 18);
    const label_size = widgetLabelTextSize(widget, tokens);
    const label_width = measuredTextWidth(tokens, widget.text, label_size);
    const gap = if (widget.text.len > 0) widgetControlInset(widget, tokens, tokens.spacing.sm) else 0;
    return geometry.SizeF.init(box_size + gap + label_width, @max(box_size, widgetLineHeight(label_size)));
}

fn intrinsicRadioWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    const circle_size = widgetSizedDensityValue(widget, tokens, 18);
    const label_size = widgetLabelTextSize(widget, tokens);
    const label_width = measuredTextWidth(tokens, widget.text, label_size);
    const gap = if (widget.text.len > 0) widgetControlInset(widget, tokens, tokens.spacing.sm) else 0;
    return geometry.SizeF.init(circle_size + gap + label_width, @max(circle_size, widgetLineHeight(label_size)));
}

fn intrinsicToggleWidgetSize(widget: Widget, tokens: DesignTokens) geometry.SizeF {
    // Matches the rendered 44x24 switch track.
    const track_width = widgetSizedDensityValue(widget, tokens, 44);
    const track_height = widgetSizedDensityValue(widget, tokens, 24);
    const label_size = widgetLabelTextSize(widget, tokens);
    const label_width = measuredTextWidth(tokens, widget.text, label_size);
    const gap = if (widget.text.len > 0) widgetControlInset(widget, tokens, tokens.spacing.sm) else 0;
    return geometry.SizeF.init(track_width + gap + label_width, @max(track_height, widgetLineHeight(label_size)));
}

fn intrinsicIconExtent(widget: Widget, tokens: DesignTokens) f32 {
    return widgetSizedDensityValue(widget, tokens, 18);
}

fn preferredMainExtent(widget: Widget, axis: LayoutAxis, tokens: DesignTokens) f32 {
    const value = switch (axis) {
        .horizontal => widget.frame.width,
        .vertical => widget.frame.height,
    };
    return clampMainExtent(widget, axis, if (value > 0) value else intrinsicMainExtent(widget, axis, tokens));
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
    const max_value = switch (axis) {
        .horizontal => widget.layout.max_size.height,
        .vertical => widget.layout.max_size.width,
    };
    if (value > 0) return @max(min_value, boundedByMax(value, max_value));
    if (alignment == .stretch) return @max(min_value, boundedByMax(available, max_value));
    return @max(min_value, boundedByMax(@min(available, intrinsicCrossExtent(widget, axis, tokens)), max_value));
}

fn minMainExtent(widget: Widget, axis: LayoutAxis) f32 {
    return switch (axis) {
        .horizontal => nonNegative(widget.layout.min_size.width),
        .vertical => nonNegative(widget.layout.min_size.height),
    };
}

fn intrinsicMainExtent(widget: Widget, axis: LayoutAxis, tokens: DesignTokens) f32 {
    const size = orientedIntrinsicWidgetSize(widget, tokens, axis);
    return switch (axis) {
        .horizontal => size.width,
        .vertical => size.height,
    };
}

fn intrinsicCrossExtent(widget: Widget, axis: LayoutAxis, tokens: DesignTokens) f32 {
    const size = orientedIntrinsicWidgetSize(widget, tokens, axis);
    return switch (axis) {
        .horizontal => size.height,
        .vertical => size.width,
    };
}

/// Axis-aware intrinsic size. A separator's intrinsic size is authored as
/// a horizontal rule (default length x stroke width); inside a horizontal
/// container the rule runs vertically, so the components swap — the
/// separator stays hairline-thin along the row's main axis (a pane
/// divider) instead of eating its default length from the row. Explicit
/// `width`/`frame` values still win through the min/frame channels.
fn orientedIntrinsicWidgetSize(widget: Widget, tokens: DesignTokens, axis: LayoutAxis) geometry.SizeF {
    const size = intrinsicWidgetSize(widget, tokens);
    if (widget.kind == .separator and axis == .horizontal) {
        return geometry.SizeF.init(size.height, size.width);
    }
    return size;
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

fn widgetWithFrame(widget: Widget, frame: geometry.RectF) Widget {
    var copy = widget;
    copy.frame = frame;
    return copy;
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
