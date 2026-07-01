const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");

const Widget = widget_model.Widget;
const WidgetActions = widget_model.WidgetActions;
const WidgetCursor = widget_model.WidgetCursor;
const WidgetHit = event_model.WidgetHit;
const WidgetKind = widget_model.WidgetKind;
const WidgetState = widget_model.WidgetState;
const defaultSemanticActions = event_model.defaultSemanticActions;
const defaultFocusable = event_model.defaultFocusable;

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

pub fn semanticFocusable(widget: Widget, actions: WidgetActions) bool {
    if (widget.id == 0 or widget.state.disabled or widget.semantics.hidden) return false;
    return widget.semantics.focusable or widget.semantics.actions.focus or actions.focus or defaultFocusable(widget);
}

pub fn isFocusable(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled or widget.semantics.hidden) return false;
    return widget.semantics.focusable or widget.semantics.actions.focus or defaultFocusable(widget);
}

pub fn isDropTarget(widget: Widget) bool {
    return widget.id != 0 and
        !widget.state.disabled and
        !widget.semantics.hidden and
        widget.semantics.actions.drop_files;
}

pub fn isDragSource(widget: Widget) bool {
    return widget.id != 0 and
        !widget.state.disabled and
        !widget.semantics.hidden and
        (widget.semantics.actions.drag or defaultSemanticActions(widget).drag);
}

pub fn isHitTarget(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled) return false;
    return switch (widget.kind) {
        .row, .column, .grid, .data_grid, .table, .data_row, .list, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .stack, .tooltip, .icon, .image, .avatar, .badge, .separator, .skeleton, .spinner => false,
        .scroll_view, .accordion, .alert, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover, .menu_surface, .dropdown_menu, .text, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .menu_item, .list_item, .data_cell, .status_bar, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .progress => true,
    };
}
