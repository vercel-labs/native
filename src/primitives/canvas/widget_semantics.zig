const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const widget_access = @import("widget_access.zig");
const widget_tree = @import("widget_tree.zig");

const Error = canvas.Error;
const Widget = widget_model.Widget;
const WidgetKind = widget_model.WidgetKind;
const WidgetRole = widget_model.WidgetRole;
const WidgetState = widget_model.WidgetState;
const WidgetLayoutNode = event_model.WidgetLayoutNode;
const WidgetSemanticsNode = event_model.WidgetSemanticsNode;
const WidgetListMetrics = event_model.WidgetListMetrics;
const WidgetScrollMetrics = event_model.WidgetScrollMetrics;
const VirtualListRange = token_model.VirtualListRange;
const virtualListRange = token_model.virtualListRange;
const semanticActions = event_model.semanticActions;

const max_widget_depth: usize = 32;

pub fn collectWidgetSemantics(layout: anytype, output: []WidgetSemanticsNode, scroll_semantics_fn: anytype) Error![]const WidgetSemanticsNode {
    var len: usize = 0;
    var semantic_stack: [max_widget_depth]?usize = [_]?usize{null} ** max_widget_depth;
    var hidden_depth: ?usize = null;
    var concealed_depth: ?usize = null;

    for (layout.nodes, 0..) |node, node_index| {
        if (node.depth >= max_widget_depth) return error.WidgetDepthExceeded;
        if (hidden_depth) |depth| {
            if (node.depth > depth) continue;
            hidden_depth = null;
        }
        if (concealed_depth) |depth| {
            if (node.depth > depth) continue;
            concealed_depth = null;
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
        // A disclosure widget that is not settled open conceals its
        // CONTENT from assistive tech — the section reads as collapsed
        // until the reveal lands — while the widget itself (the
        // trigger, carrying the expanded/collapsed state) stays
        // exposed. The hidden skip above drops the node too; this one
        // drops only what sits under it.
        if (widget_tree.widgetKindDisclosureAnimated(node.widget.kind) and !widget_tree.disclosureSettledOpen(layout, node_index)) {
            concealed_depth = node.depth;
        }
        if (role == .none or node.widget.id == 0) continue;
        if (len >= output.len) return error.WidgetSemanticsListFull;

        const parent_index = nearestSemanticParent(semantic_stack[0..node.depth]);
        const grid = widgetGridSemantics(layout, node_index);
        const list = widgetListSemantics(layout, node_index);
        const scroll = scroll_semantics_fn(layout, node_index);
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
            .focusable = widget_access.semanticFocusable(node.widget, actions),
            .actions = actions,
            .text_selection = widget_access.widgetTextSelectionRange(node.widget),
            .text_composition = widget_access.widgetTextCompositionRange(node.widget),
            .parent_index = parent_index,
        };
        semantic_stack[node.depth] = len;
        len += 1;
    }

    return output[0..len];
}

fn nearestSemanticParent(stack: []const ?usize) ?usize {
    var index = stack.len;
    while (index > 0) {
        index -= 1;
        if (stack[index]) |semantic_index| return semantic_index;
    }
    return null;
}

/// The role a widget is exposed under: an explicit `semantics.role`, or
/// the kind's default. Shared with the a11y audit (a11y_audit.zig), which
/// must judge widgets by the role the bridges will actually announce.
pub fn semanticRole(widget: Widget) WidgetRole {
    if (widget.semantics.role != .none) return widget.semantics.role;
    return switch (widget.kind) {
        .stack, .row, .column, .grid, .scroll_view, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .accordion, .bubble, .resizable, .alert, .card, .panel => .group,
        .data_grid, .table => .grid,
        .data_row => .row,
        .dialog, .drawer, .sheet, .popover => .dialog,
        .menu_surface, .dropdown_menu => .menu,
        .list => .list,
        .text, .status_bar => .text,
        // Media surfaces announce as images: pictorial content whose
        // TEXTURE is presentation chrome — the semantic node carries only
        // role, label, and bounds, never frame-varying producer state, so
        // session fingerprints (hashed over the a11y tree) stay identical
        // whether or not a producer is attached.
        .icon, .image, .avatar, .media_surface => .image,
        .badge => .text,
        .button, .toggle_button, .toggle => .button,
        .icon_button, .select => .button,
        .input, .text_field, .search_field, .combobox, .textarea => .textbox,
        .tooltip => .tooltip,
        .menu_item => .menuitem,
        .list_item => .listitem,
        .data_cell => .gridcell,
        .segmented_control => .tab,
        .checkbox => .checkbox,
        .radio => .radio,
        .switch_control => .switch_control,
        .slider => .slider,
        .progress => .progressbar,
        .separator, .skeleton => .none,
        .spinner => .progressbar,
        .chart => .chart,
        .split => .group,
        .split_divider => .separator,
        .tree => .tree,
        // The grouped input announces as ONE named group; the entry and
        // the accessory controls inside stay individually reachable.
        .input_group => .group,
    };
}

/// The label a widget is announced under: an explicit `semantics.label`,
/// falling back to the widget's text. Shared with the a11y audit.
pub fn semanticLabel(widget: Widget) []const u8 {
    if (widget.semantics.label.len > 0) return widget.semantics.label;
    return widget.text;
}

fn semanticValue(widget: Widget) ?f32 {
    if (widget.semantics.value) |value| return value;
    return switch (widget.kind) {
        .radio, .list_item, .menu_item, .data_cell, .segmented_control => if (widget.state.selected or widget.value >= 0.5) 1 else 0,
        .accordion, .checkbox, .switch_control, .toggle, .toggle_button => if (widget_access.booleanControlSelected(widget)) 1 else 0,
        .slider, .progress => std.math.clamp(widget.value, 0, 1),
        // The separator's aria-valuenow: the parent split's effective
        // fraction (the layout pass mirrors it onto the handle).
        .split_divider => std.math.clamp(widget.value, 0, 1),
        .spinner => null,
        // The latest datapoint of the first series, so automation can
        // assert on live chart data without pixel access.
        .chart => chartSemanticValue(widget),
        else => null,
    };
}

fn chartSemanticValue(widget: Widget) ?f32 {
    if (widget.chart.series.len == 0) return null;
    const values = widget.chart.series[0].values;
    if (values.len == 0) return null;
    return values[values.len - 1];
}

fn semanticState(widget: Widget) WidgetState {
    var state = widget.state;
    if (state.expanded == null) state.expanded = defaultExpandedState(widget);
    return state;
}

fn defaultExpandedState(widget: Widget) ?bool {
    return switch (widget.kind) {
        .accordion => widget_access.booleanControlSelected(widget),
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

fn widgetGridSemantics(layout: anytype, node_index: usize) WidgetGridSemantics {
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

fn widgetLayoutGridSemantics(layout: anytype, grid_index: usize) WidgetGridSemantics {
    const grid = layout.nodes[grid_index].widget;
    if (grid.semantics.role != .grid) return .{};
    const columns = gridSemanticColumnCount(grid);
    return .{
        .row_count = gridSemanticRowCount(grid, columns),
        .column_count = columns,
    };
}

fn widgetGridChildSemantics(layout: anytype, child_index: usize) WidgetGridSemantics {
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
    return widget_tree.gridColumnCount(grid.children.len, grid.layout.columns);
}

fn gridSemanticRowCount(grid: Widget, columns: usize) usize {
    if (grid.semantics.list_item_count) |count| return @intCast(count);
    return widget_tree.gridRowCount(grid.children.len, columns);
}

fn widgetDataRowGridSemantics(layout: anytype, row_index: usize) WidgetGridSemantics {
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

fn widgetDataCellGridSemantics(layout: anytype, cell_index: usize) WidgetGridSemantics {
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

fn dataGridRowCount(layout: anytype, grid_index: usize) usize {
    if (layout.nodes[grid_index].widget.semantics.list_item_count) |virtual_count| return @intCast(virtual_count);
    return directChildCountByKind(layout, grid_index, .data_row);
}

fn dataRowColumnCount(layout: anytype, row_index: usize) usize {
    return directChildCountByKind(layout, row_index, .data_cell);
}

fn directChildCountByKind(layout: anytype, parent_index: usize, kind: WidgetKind) usize {
    var count: usize = 0;
    for (layout.nodes) |node| {
        if (node.parent_index == parent_index and node.widget.kind == kind) count += 1;
    }
    return count;
}

fn directChildOrdinalByKind(layout: anytype, parent_index: usize, child_index: usize, kind: WidgetKind) ?usize {
    var ordinal: usize = 0;
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != parent_index or node.widget.kind != kind) continue;
        if (index == child_index) return ordinal;
        ordinal += 1;
    }
    return null;
}

fn directChildOrdinal(layout: anytype, parent_index: usize, child_index: usize) ?usize {
    var ordinal: usize = 0;
    for (layout.nodes, 0..) |node, index| {
        if (node.parent_index != parent_index) continue;
        if (index == child_index) return ordinal;
        ordinal += 1;
    }
    return null;
}

fn maxDataGridColumnCount(layout: anytype, grid_index: usize) usize {
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

fn widgetListSemantics(layout: anytype, node_index: usize) WidgetListSemantics {
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
        .item_index = widget_tree.saturatingU32(item_index),
        .item_count = widget_tree.saturatingU32(item_count),
    } };
}

pub fn widgetVirtualRangeForLayoutNode(node: WidgetLayoutNode) ?VirtualListRange {
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

pub const WidgetScrollSemantics = struct {
    metrics: WidgetScrollMetrics = .{},
    value: ?f32 = null,
    scrollable: bool = false,
};

pub fn widgetScrollSemantics(layout: anytype, node_index: usize, virtual_content_extent_fn: anytype) WidgetScrollSemantics {
    if (node_index >= layout.nodes.len) return .{};
    const node = layout.nodes[node_index];
    if (!widgetExposesScrollSemantics(node.widget)) return .{};

    const viewport = node.frame.inset(node.widget.layout.padding).normalized();
    if (viewport.isEmpty()) return .{};

    const content_extent = widgetScrollContentExtent(layout, node_index, viewport, virtual_content_extent_fn);
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

fn widgetScrollContentExtent(layout: anytype, scroll_index: usize, viewport: geometry.RectF, virtual_content_extent_fn: anytype) f32 {
    const scroll_node = layout.nodes[scroll_index];
    if (scroll_node.widget.layout.virtualized) {
        return @max(viewport.height, virtual_content_extent_fn(scroll_node.widget, viewport.height));
    }

    const scroll_depth = scroll_node.depth;
    const offset = scroll_node.widget.value;
    var bottom = viewport.maxY();
    var index = scroll_index + 1;
    while (index < layout.nodes.len and layout.nodes[index].depth > scroll_depth) {
        const node = layout.nodes[index];
        bottom = @max(bottom, node.frame.maxY() + offset);
        // A disclosure widget's own frame is authoritative for how far
        // its content currently reaches: concealed content lays out at
        // full size BELOW a closed item's header-only frame, and must
        // not inflate the scrollable extent — so its subtree is skipped
        // wholesale. Settled-open content sits inside the frame anyway,
        // and a mid-reveal extent follows the animated frame, which is
        // exactly the scrollbar motion the reveal should show.
        if (widget_tree.widgetKindDisclosureAnimated(node.widget.kind)) {
            const subtree_depth = node.depth;
            index += 1;
            while (index < layout.nodes.len and layout.nodes[index].depth > subtree_depth) : (index += 1) {}
            continue;
        }
        index += 1;
    }
    return @max(0, bottom - viewport.y);
}

fn nonNegative(value: f32) f32 {
    return if (value < 0) 0 else value;
}
