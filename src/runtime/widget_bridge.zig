const std = @import("std");
const canvas = @import("canvas");
const automation = @import("../automation/root.zig");
const platform = @import("../platform/root.zig");

pub const CanvasWidgetAccessibilityActionKind = enum {
    focus,
    press,
    toggle,
    increment,
    decrement,
    set_text,
    set_selection,
    set_composition,
    commit_composition,
    cancel_composition,
    select,
    drag,
    drop_files,
    dismiss,
};

pub const CanvasWidgetAccessibilityAction = struct {
    id: canvas.ObjectId,
    action: CanvasWidgetAccessibilityActionKind,
    text: []const u8 = "",
    selection: ?canvas.TextSelection = null,
};

pub fn platformCursorFromCanvas(cursor: canvas.WidgetCursor) platform.Cursor {
    return switch (cursor) {
        .arrow => .arrow,
        .pointing_hand => .pointing_hand,
        .text => .text,
        .resize_horizontal => .resize_horizontal,
    };
}

pub fn widgetRoleName(role: canvas.WidgetRole) []const u8 {
    return switch (role) {
        .none => "none",
        .group => "group",
        .text => "text",
        .link => "link",
        .image => "image",
        .button => "button",
        .textbox => "textbox",
        .tooltip => "tooltip",
        .dialog => "dialog",
        .menu => "menu",
        .menuitem => "menuitem",
        .list => "list",
        .listitem => "listitem",
        .row => "row",
        .grid => "grid",
        .gridcell => "gridcell",
        .tab => "tab",
        .checkbox => "checkbox",
        .radio => "radio",
        .switch_control => "switch",
        .slider => "slider",
        .progressbar => "progressbar",
        .chart => "chart",
        .tree => "tree",
        .treeitem => "treeitem",
        .separator => "separator",
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

pub fn canvasWidgetActions(actions: canvas.WidgetActions) automation.snapshot.WidgetActions {
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

pub fn platformWidgetAccessibilityNodeById(nodes: []const platform.WidgetAccessibilityNode, id: u64) ?platform.WidgetAccessibilityNode {
    if (id == 0) return null;
    for (nodes) |node| {
        if (node.id == id) return node;
    }
    return null;
}

pub fn canvasWidgetSemanticsById(nodes: []const canvas.WidgetSemanticsNode, id: canvas.ObjectId) ?canvas.WidgetSemanticsNode {
    if (id == 0) return null;
    for (nodes) |node| {
        if (node.id == id) return node;
    }
    return null;
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

pub fn canvasTextRange(range: ?canvas.TextRange) ?automation.snapshot.TextRange {
    if (range) |value| return .{ .start = value.start, .end = value.end };
    return null;
}

pub fn canvasVirtualRange(range: ?canvas.VirtualListRange) automation.snapshot.WidgetVirtualRange {
    const value = range orelse return .{};
    return .{
        .present = true,
        .start_index = saturatingU32(value.start_index),
        .end_index = saturatingU32(value.end_index),
        .first_visible_index = saturatingU32(value.first_visible_index),
        .last_visible_index = saturatingU32(value.last_visible_index),
        .rendered_count = saturatingU32(value.itemCount()),
    };
}

pub fn saturatingU32(value: usize) u32 {
    return if (value > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(value);
}

pub fn canvasWidgetAccessibilityActionSupported(actions: canvas.WidgetActions, action: CanvasWidgetAccessibilityActionKind) bool {
    return switch (action) {
        .focus => actions.focus,
        .press => actions.press,
        .toggle => actions.toggle,
        .increment => actions.increment,
        .decrement => actions.decrement,
        .set_text => actions.set_text,
        .set_selection => actions.set_selection,
        .set_composition, .commit_composition, .cancel_composition => actions.set_text,
        .select => actions.select,
        .drag => actions.drag,
        .drop_files => actions.drop_files,
        .dismiss => actions.dismiss,
    };
}

pub fn canvasWidgetAccessibilityActionKindFromPlatform(action: platform.WidgetAccessibilityActionKind) CanvasWidgetAccessibilityActionKind {
    return switch (action) {
        .focus => .focus,
        .press => .press,
        .toggle => .toggle,
        .increment => .increment,
        .decrement => .decrement,
        .set_text => .set_text,
        .set_selection => .set_selection,
        .set_composition => .set_composition,
        .commit_composition => .commit_composition,
        .cancel_composition => .cancel_composition,
        .select => .select,
        .drag => .drag,
        .drop_files => .drop_files,
        .dismiss => .dismiss,
    };
}

/// The inverse of `canvasWidgetAccessibilityActionKindFromPlatform`: the
/// direct verb surfaces (embed hosts, automation `widget_action`
/// commands) reach the dispatch without a platform event, and the
/// session journal needs one to record the verb outer-wins.
pub fn platformWidgetAccessibilityActionKindFromCanvas(action: CanvasWidgetAccessibilityActionKind) platform.WidgetAccessibilityActionKind {
    return switch (action) {
        .focus => .focus,
        .press => .press,
        .toggle => .toggle,
        .increment => .increment,
        .decrement => .decrement,
        .set_text => .set_text,
        .set_selection => .set_selection,
        .set_composition => .set_composition,
        .commit_composition => .commit_composition,
        .cancel_composition => .cancel_composition,
        .select => .select,
        .drag => .drag,
        .drop_files => .drop_files,
        .dismiss => .dismiss,
    };
}
