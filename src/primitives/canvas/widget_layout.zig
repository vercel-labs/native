const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_model = @import("text.zig");
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
const estimateTextWidthForFont = text_model.estimateTextWidthForFont;
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
        @max(intrinsic.width, @max(child.layout.min_size.width, nonNegative(child.frame.width))),
        @max(intrinsic.height, @max(child.layout.min_size.height, nonNegative(child.frame.height))),
    );
}

fn intrinsicAxisChildrenSize(widget: Widget, tokens: DesignTokens, axis: LayoutAxis, depth: usize) geometry.SizeF {
    if (depth >= max_widget_depth or widget.children.len == 0) return intrinsicOwnMinSize(widget);
    const gap = nonNegative(widget.layout.gap) * @as(f32, @floatFromInt(widget.children.len - 1));
    var main_sum: f32 = 0;
    var cross_max: f32 = 0;
    for (widget.children) |child| {
        const size = intrinsicChildSize(child, tokens, depth + 1);
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
