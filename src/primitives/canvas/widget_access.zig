const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const text_model = @import("text.zig");

const Widget = widget_model.Widget;
const WidgetActions = widget_model.WidgetActions;
const WidgetCursor = widget_model.WidgetCursor;
const WidgetHit = event_model.WidgetHit;
const WidgetKind = widget_model.WidgetKind;
const WidgetState = widget_model.WidgetState;
const TextRange = text_model.TextRange;
const defaultSemanticActions = event_model.defaultSemanticActions;
const defaultFocusable = event_model.defaultFocusable;
const snapTextRange = text_model.snapTextRange;

/// The engine's cursor register follows NATIVE platform convention, not
/// the web's: the pointing hand is a HYPERLINK affordance, so it appears
/// only over link-role targets (link spans in text, or any widget given
/// `role = .link`). Every ordinary control — buttons, toggles, checkboxes,
/// menu items, tabs, list rows, sliders — keeps the arrow, exactly like
/// the platform's own controls do.
pub fn cursorForWidgetHit(hit: ?WidgetHit) WidgetCursor {
    const target = hit orelse return .arrow;
    if (target.role == .link and !target.state.disabled) return .pointing_hand;
    return cursorForWidgetTarget(target.kind, target.state);
}

/// The kind-level half of the register: I-beam over editable text (a
/// click places the caret, the cursor advertises it), resize arrows over
/// the divider affordances (`resizable`'s grip edge and `split_divider`),
/// arrow over everything else — including sliders, which keep the arrow
/// at rest AND during a drag on every native platform. The pointing hand
/// never comes from a kind; it is role-driven (`cursorForWidgetHit`).
pub fn cursorForWidgetTarget(kind: WidgetKind, state: WidgetState) WidgetCursor {
    if (state.disabled) return .arrow;
    return switch (kind) {
        .input, .text_field, .search_field, .combobox, .textarea => .text,
        .resizable, .split_divider => .resize_horizontal,
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

/// Widget KINDS the engine hit-tests. Kinds listed `false` are layout and
/// decoration only: pointer events pass through them to whatever they
/// contain. This is the kind-level half of hit-target-ness — the runtime's
/// `canvasWidgetRuntimeHitTarget`, both markup engines, and (via a name
/// list kept in sync by a test in ui_markup_view_tests.zig) the markup
/// validator all derive from it. The widget-level predicate is
/// `isHitTarget`: a bound press/toggle handler (stamped into
/// `semantics.actions` by the builder and both markup engines) makes ANY
/// widget a hit target, so `on_press` on a row/stack/icon works.
pub fn widgetKindHitTarget(kind: WidgetKind) bool {
    return switch (kind) {
        .row, .column, .grid, .data_grid, .table, .data_row, .list, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .stack, .tooltip, .icon, .image, .avatar, .badge, .separator, .skeleton, .spinner, .chart, .split, .tree, .input_group, .media_surface => false,
        .scroll_view, .accordion, .alert, .bubble, .card, .dialog, .drawer, .sheet, .resizable, .panel, .popover, .menu_surface, .dropdown_menu, .text, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .menu_item, .list_item, .data_cell, .status_bar, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .progress, .split_divider => true,
    };
}

pub fn isHitTarget(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled) return false;
    if (widget.semantics.actions.press or widget.semantics.actions.toggle) return true;
    if (widget.window_drag) return true;
    // A chart with hover details opted in is hoverable (the runtime
    // tracks the pointer over it to snap the detail card to the nearest
    // sample). It still claims no presses — clicks fall through to the
    // nearest claiming ancestor exactly like plain text — so this flips
    // only where hover attributes, not where clicks land.
    if (widget.kind == .chart) return widget.chart.hover_details;
    return widgetKindHitTarget(widget.kind);
}

/// Whether this widget is a live window-drag surface: a press landing
/// on it (or falling through to it) moves the WINDOW. Disabled widgets
/// stand down exactly like they do for presses.
pub fn isWindowDragRegion(widget: Widget) bool {
    return widget.id != 0 and !widget.state.disabled and widget.window_drag;
}

/// Widget KINDS that stop (claim) a press gesture themselves: interactive
/// controls, editable text (a click places the caret, never activates the
/// row around it), scroll containers, and dismissible overlay surfaces (a
/// click inside a dialog must never activate what it covers). Hit-target
/// decorations — plain text, panel, card, alert, bubble, status_bar,
/// progress — are deliberately NOT here: presses fall through them to the
/// nearest claiming ancestor (`widgetPressTargetForHit`).
///
/// See also `widgetKindDismissibleSurface` below for the overlay set the
/// runtime's dismissal machinery closes.
pub fn widgetKindClaimsPress(kind: WidgetKind) bool {
    return switch (kind) {
        .button,
        .toggle_button,
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
        .accordion,
        .slider,
        .resizable,
        .split_divider,
        .input,
        .text_field,
        .search_field,
        .combobox,
        .textarea,
        .scroll_view,
        .dialog,
        .drawer,
        .sheet,
        .popover,
        .menu_surface,
        .dropdown_menu,
        => true,
        else => false,
    };
}

/// Whether a press gesture stops at this widget instead of falling
/// through to the nearest claiming ancestor: an interactive kind
/// (`widgetKindClaimsPress`), or ANY widget with a bound press/toggle
/// handler (`on_press`/`on_toggle` stamp `semantics.actions`, and
/// engine-owned `command` dispatch only exists on kinds already claiming).
/// Disabled widgets never claim — the hit test skips them too, so a press
/// on a disabled control keeps today's behavior of landing on whatever is
/// around it.
pub fn widgetClaimsPress(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled) return false;
    if (widget.semantics.actions.press or widget.semantics.actions.toggle) return true;
    return widgetKindClaimsPress(widget.kind);
}

/// Widget KINDS the runtime's dismissal machinery closes (Escape, click
/// outside, automation/accessibility dismiss): the overlay surfaces. The
/// runtime's `canvasWidgetDismissibleSurfaceKind` delegates here and
/// `defaultSemanticActions` exposes the matching `dismiss` action, so the
/// set cannot drift. `on_dismiss` handlers only ever fire on these.
pub fn widgetKindDismissibleSurface(kind: WidgetKind) bool {
    return switch (kind) {
        .dialog,
        .drawer,
        .sheet,
        .popover,
        .menu_surface,
        .dropdown_menu,
        .tooltip,
        => true,
        else => false,
    };
}

pub fn booleanControlSelected(widget: Widget) bool {
    return widget.state.selected or widget.value >= 0.5;
}

pub fn widgetTextSelectionRange(widget: Widget) ?TextRange {
    if (!widgetSelectableTextKind(widget.kind)) return null;
    if (widget.text_selection) |selection| return snapTextRange(widget.text, selection.range(widget.text.len));
    return null;
}

/// Kinds whose `text_selection` is live state: editable text inputs plus
/// static `.text` widgets (read-only click-drag selection for copy).
pub fn widgetSelectableTextKind(kind: WidgetKind) bool {
    return widgetTextInputKind(kind) or kind == .text;
}

pub fn widgetTextCompositionRange(widget: Widget) ?TextRange {
    if (!widgetTextInputKind(widget.kind)) return null;
    if (widget.text_composition) |range| return snapTextRange(widget.text, range);
    return null;
}

pub fn widgetTextInputKind(kind: WidgetKind) bool {
    return switch (kind) {
        .input, .text_field, .search_field, .combobox, .textarea => true,
        else => false,
    };
}
