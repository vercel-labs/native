// Frozen native projection used before compiled accessibility ownership.
const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const platform = native_sdk.platform;
pub const View = struct {
    keyboard_active: bool = false,
    focused: bool = false,
    canvas_widget_focused_id: u64 = 0,
    canvas_widget_hovered_id: u64 = 0,
    canvas_widget_pressed_id: u64 = 0,
};
pub fn project(semantics: []const canvas.WidgetSemanticsNode, index: usize, view: View, history: struct { can_undo: bool = false, can_redo: bool = false }) platform.WidgetAccessibilityNode {
    const node = semantics[index];
    const focused = node.state.focused or (view.keyboard_active and view.focused and node.id == view.canvas_widget_focused_id);
    return .{
        .id = node.id,
        .parent_id = canvasWidgetSemanticParentId(semantics, node.parent_index),
        .role = platformWidgetAccessibilityRole(node.role),
        .label = node.label,
        .text_value = node.text_value,
        .placeholder = node.placeholder,
        .text_selection = platformWidgetAccessibilityTextRange(node.text_selection),
        .text_composition = platformWidgetAccessibilityTextRange(node.text_composition),
        .value = node.value,
        .bounds = node.bounds,
        .grid_row_index = node.grid_row_index,
        .grid_column_index = node.grid_column_index,
        .grid_row_count = node.grid_row_count,
        .grid_column_count = node.grid_column_count,
        .list_item_index = if (node.list.present) node.list.item_index else null,
        .list_item_count = if (node.list.present) node.list.item_count else null,
        .scroll_offset = if (node.scroll.present) node.scroll.offset else null,
        .scroll_viewport_extent = if (node.scroll.present) node.scroll.viewport_extent else null,
        .scroll_content_extent = if (node.scroll.present) node.scroll.content_extent else null,
        .enabled = !node.state.disabled,
        .focused = focused,
        .hovered = node.state.hovered or (node.id != 0 and node.id == view.canvas_widget_hovered_id),
        .pressed = node.state.pressed or (node.id != 0 and node.id == view.canvas_widget_pressed_id),
        .selected = canvasWidgetSelectedState(node),
        .expanded = node.state.expanded,
        .required = node.state.required,
        .read_only = node.state.read_only,
        .invalid = node.state.invalid,
        .can_undo = history.can_undo,
        .can_redo = history.can_redo,
        .focusable = node.focusable,
        .actions = platformWidgetAccessibilityActions(node.actions),
    };
}

pub fn platformWidgetAccessibilityRole(role: canvas.WidgetRole) platform.WidgetAccessibilityRole {
    return switch (role) {
        .none => .none,
        .group => .group,
        .text => .text,
        // The platform accessibility enum has no link role yet; a link is
        // exposed as a pressable button, which keeps it activatable from
        // assistive tech.
        .link => .button,
        .image => .image,
        .button => .button,
        .textbox => .textbox,
        .tooltip => .tooltip,
        .dialog => .dialog,
        .menu => .menu,
        .menuitem => .menuitem,
        .list => .list,
        .listitem => .listitem,
        .row => .row,
        .grid => .grid,
        .gridcell => .gridcell,
        .tab => .tab,
        .checkbox => .checkbox,
        .radio => .radio,
        .radiogroup => .radiogroup,
        .switch_control => .switch_control,
        .slider => .slider,
        .progressbar => .progressbar,
        // The platform accessibility enum has no chart role; a chart is
        // exposed as an image carrying the series-summary label.
        .chart => .image,
        // The platform accessibility enum has no tree/treeitem/separator
        // roles yet; trees expose as lists (rows as list items, still
        // focusable and selectable from assistive tech) and the split
        // divider as a plain group whose value carries the fraction.
        .tree => .list,
        .treeitem => .listitem,
        .separator => .group,
    };
}

pub fn platformWidgetAccessibilityActions(actions: canvas.WidgetActions) platform.WidgetAccessibilityActions {
    return .{
        .focus = actions.focus,
        .press = actions.press,
        .toggle = actions.toggle,
        .increment = actions.increment,
        .decrement = actions.decrement,
        .set_text = actions.set_text,
        .set_selection = actions.set_selection,
        .select = actions.select,
        .drag = actions.drag,
        .drop_files = actions.drop_files,
        .dismiss = actions.dismiss,
    };
}

pub fn platformWidgetAccessibilityTextRange(range: ?canvas.TextRange) ?platform.WidgetAccessibilityTextRange {
    const value = range orelse return null;
    return .{ .start = value.start, .end = value.end };
}

pub fn canvasWidgetSemanticParentId(nodes: []const canvas.WidgetSemanticsNode, parent_index: ?usize) ?u64 {
    const index = parent_index orelse return null;
    if (index >= nodes.len) return null;
    return nodes[index].id;
}

pub fn canvasWidgetSelectedState(node: canvas.WidgetSemanticsNode) bool {
    if (node.state.selected) return true;
    const value = node.value orelse return false;
    if (value < 0.5) return false;
    return switch (node.role) {
        .checkbox, .radio, .switch_control, .listitem, .gridcell, .tab => true,
        else => false,
    };
}
