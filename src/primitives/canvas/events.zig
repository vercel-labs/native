const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_model = @import("text.zig");
const widget_model = @import("widgets.zig");

const ObjectId = canvas.ObjectId;
const TextInputEvent = text_model.TextInputEvent;
const TextRange = text_model.TextRange;
const Widget = widget_model.Widget;
const WidgetActions = widget_model.WidgetActions;
const WidgetKind = widget_model.WidgetKind;
const WidgetRole = widget_model.WidgetRole;
const WidgetState = widget_model.WidgetState;

pub const WidgetLayoutNode = struct {
    widget: Widget,
    frame: geometry.RectF,
    depth: usize,
    parent_index: ?usize = null,
};

pub const WidgetHit = struct {
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
    depth: usize,
    index: usize,
    state: WidgetState,
};

pub const WidgetPointerPhase = enum {
    hover,
    down,
    move,
    up,
    cancel,
    wheel,
};

pub const WidgetPointerEvent = struct {
    phase: WidgetPointerPhase,
    point: geometry.PointF,
    delta: geometry.OffsetF = .{},
    captured_id: ?ObjectId = null,
};

pub const WidgetKeyboardPhase = enum {
    key_down,
    key_up,
    text_input,
};

pub const WidgetKeyboardModifiers = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn hasCommandModifier(self: WidgetKeyboardModifiers) bool {
        return self.control or self.super;
    }

    pub fn hasNavigationModifier(self: WidgetKeyboardModifiers) bool {
        return self.control or self.alt or self.super;
    }
};

pub const WidgetKeyboardEvent = struct {
    phase: WidgetKeyboardPhase,
    focused_id: ?ObjectId = null,
    key: []const u8 = "",
    text: []const u8 = "",
    edit: ?TextInputEvent = null,
    modifiers: WidgetKeyboardModifiers = .{},

    pub fn textEditEvent(self: WidgetKeyboardEvent) ?TextInputEvent {
        if (self.edit) |edit| return edit;
        return widgetKeyboardTextEditEvent(self);
    }
};

pub const WidgetControlIntentKind = enum {
    press,
    toggle,
    select,
    set_value,
    scroll_by,
    scroll_to_start,
    scroll_to_end,
};

pub const WidgetControlIntent = struct {
    kind: WidgetControlIntentKind,
    actions: WidgetActions = .{},
    value: ?f32 = null,
    delta: f32 = 0,
};

pub const WidgetSemanticAction = enum {
    press,
    toggle,
    select,
    increment,
    decrement,
};

pub const WidgetFileDropEvent = struct {
    point: geometry.PointF,
    paths: []const []const u8 = &.{},
};

pub const WidgetDragEvent = struct {
    source_id: ObjectId = 0,
    point: geometry.PointF,
    delta: geometry.OffsetF = .{},
};

pub const WidgetEventPhase = enum {
    capture,
    target,
    bubble,
};

pub const WidgetEventRouteEntry = struct {
    phase: WidgetEventPhase,
    node_index: usize,
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
};

pub const WidgetEventRoute = struct {
    target: ?WidgetHit = null,
    entries: []const WidgetEventRouteEntry = &.{},
};

pub const WidgetKeyboardRoute = struct {
    target: ?WidgetFocusTarget = null,
    entries: []const WidgetEventRouteEntry = &.{},
};

pub const WidgetFocusDirection = enum {
    forward,
    backward,
    left,
    right,
    up,
    down,
};

pub const WidgetFocusTarget = struct {
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
    index: usize,
    state: WidgetState,
};

pub const WidgetScrollMetrics = struct {
    present: bool = false,
    offset: f32 = 0,
    viewport_extent: f32 = 0,
    content_extent: f32 = 0,
};

pub const WidgetListMetrics = struct {
    present: bool = false,
    item_index: u32 = 0,
    item_count: u32 = 0,
};

pub const WidgetSemanticsNode = struct {
    id: ObjectId,
    role: WidgetRole,
    label: []const u8,
    value: ?f32 = null,
    text_value: []const u8 = "",
    placeholder: []const u8 = "",
    grid_row_index: ?usize = null,
    grid_column_index: ?usize = null,
    grid_row_count: ?usize = null,
    grid_column_count: ?usize = null,
    list: WidgetListMetrics = .{},
    scroll: WidgetScrollMetrics = .{},
    bounds: geometry.RectF,
    state: WidgetState,
    focusable: bool = false,
    actions: WidgetActions = .{},
    text_selection: ?TextRange = null,
    text_composition: ?TextRange = null,
    parent_index: ?usize = null,
};

pub const WidgetInvalidationKind = enum {
    added,
    removed,
    changed,
};

pub const WidgetInvalidation = struct {
    kind: WidgetInvalidationKind,
    id: ObjectId,
    previous_index: ?usize = null,
    next_index: ?usize = null,
    dirty_bounds: ?geometry.RectF = null,
    layout_dirty: bool = false,
    paint_dirty: bool = false,
    semantics_dirty: bool = false,
};

fn widgetKeyboardTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    return switch (event.phase) {
        .text_input => if (event.text.len > 0 and !event.modifiers.hasCommandModifier()) .{ .insert_text = event.text } else null,
        .key_down => widgetKeyboardKeyDownTextEditEvent(event),
        .key_up => null,
    };
}

fn widgetKeyboardKeyDownTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (widgetKeyboardSelectAllTextEditEvent(event)) |edit| return edit;
    if (widgetKeyboardCommandTextNavigationEvent(event)) |edit| return edit;
    if (widgetKeyboardWordTextNavigationEvent(event)) |edit| return edit;
    if (widgetKeyboardWordDeleteTextEditEvent(event)) |edit| return edit;
    if (event.modifiers.hasNavigationModifier()) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "backspace")) return .delete_backward;
    if (std.ascii.eqlIgnoreCase(event.key, "delete")) return .delete_forward;
    if (std.ascii.eqlIgnoreCase(event.key, "arrowleft")) return .{ .move_caret = .{ .direction = .previous, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "arrowright")) return .{ .move_caret = .{ .direction = .next, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "home")) return .{ .move_caret = .{ .direction = .start, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "end")) return .{ .move_caret = .{ .direction = .end, .extend = event.modifiers.shift } };
    return null;
}

fn widgetKeyboardCommandTextNavigationEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (!event.modifiers.super or event.modifiers.alt) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "arrowleft")) return .{ .move_caret = .{ .direction = .start, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "arrowright")) return .{ .move_caret = .{ .direction = .end, .extend = event.modifiers.shift } };
    return null;
}

fn widgetKeyboardWordTextNavigationEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (event.modifiers.super) return null;
    if (event.modifiers.alt == event.modifiers.control) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "arrowleft")) return .{ .move_caret = .{ .direction = .previous_word, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "arrowright")) return .{ .move_caret = .{ .direction = .next_word, .extend = event.modifiers.shift } };
    return null;
}

fn widgetKeyboardWordDeleteTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (event.modifiers.super or event.modifiers.shift) return null;
    if (event.modifiers.alt == event.modifiers.control) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "backspace")) return .delete_word_backward;
    if (std.ascii.eqlIgnoreCase(event.key, "delete")) return .delete_word_forward;
    return null;
}

fn widgetKeyboardSelectAllTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (!event.modifiers.hasCommandModifier() or event.modifiers.alt or event.modifiers.shift) return null;
    if (!std.ascii.eqlIgnoreCase(event.key, "a")) return null;
    return .{ .set_selection = .{ .anchor = 0, .focus = std.math.maxInt(usize) } };
}

pub fn widgetKeyboardControlIntent(widget: Widget, keyboard: WidgetKeyboardEvent) ?WidgetControlIntent {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    if (widget.state.disabled) return null;
    return switch (widget.kind) {
        .button, .icon_button, .select, .combobox => if (isWidgetActivationKey(keyboard.key))
            .{ .kind = .press, .actions = .{ .press = true } }
        else
            null,
        .accordion, .checkbox, .switch_control, .toggle, .toggle_button => if (isWidgetActivationKey(keyboard.key))
            .{ .kind = .toggle, .actions = .{ .toggle = true } }
        else
            null,
        .radio, .list_item, .menu_item, .data_cell, .segmented_control => if (isWidgetActivationKey(keyboard.key))
            .{
                .kind = .select,
                .actions = .{
                    .select = true,
                    .press = widget.command.len > 0,
                },
            }
        else
            null,
        .slider => if (widgetSliderKeyboardValue(widget.value, keyboard)) |next_value|
            .{
                .kind = .set_value,
                .actions = .{
                    .increment = next_value > widget.value,
                    .decrement = next_value < widget.value,
                },
                .value = std.math.clamp(next_value, 0, 1),
            }
        else
            null,
        .grid => if (widget.layout.virtualized) widgetScrollKeyboardIntent(widget, keyboard) else null,
        .scroll_view, .list, .data_grid, .table => widgetScrollKeyboardIntent(widget, keyboard),
        else => null,
    };
}

pub fn widgetSemanticControlIntent(widget: Widget, action: WidgetSemanticAction) ?WidgetControlIntent {
    return widgetSemanticControlIntentWithActions(widget, action, semanticActions(widget));
}

pub fn widgetSemanticControlIntentWithActions(widget: Widget, action: WidgetSemanticAction, actions: WidgetActions) ?WidgetControlIntent {
    if (widget.state.disabled or widget.semantics.hidden) return null;
    return switch (action) {
        .press => if (actions.press)
            widgetSemanticPressControlIntent(widget, actions)
        else
            null,
        .toggle => if (actions.toggle)
            .{ .kind = .toggle, .actions = .{ .toggle = true } }
        else
            null,
        .select => if (actions.select)
            .{
                .kind = .select,
                .actions = .{
                    .select = true,
                    .press = actions.press,
                },
            }
        else
            null,
        .increment => widgetSemanticStepControlIntent(widget, .increment, actions),
        .decrement => widgetSemanticStepControlIntent(widget, .decrement, actions),
    };
}

fn widgetSemanticPressControlIntent(widget: Widget, actions: WidgetActions) WidgetControlIntent {
    return switch (widget.kind) {
        .radio, .list_item, .menu_item, .data_cell, .segmented_control => if (actions.select)
            .{
                .kind = .select,
                .actions = .{
                    .press = true,
                    .select = true,
                },
            }
        else
            .{ .kind = .press, .actions = .{ .press = true } },
        else => .{ .kind = .press, .actions = .{ .press = true } },
    };
}

pub fn isWidgetActivationKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "space") or std.ascii.eqlIgnoreCase(key, "enter");
}

pub fn widgetSliderKeyboardValue(current: f32, keyboard: WidgetKeyboardEvent) ?f32 {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    const step: f32 = if (keyboard.modifiers.shift) 0.1 else 0.05;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) {
        return current - step;
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) {
        return current + step;
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "home")) return 0;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "end")) return 1;
    return null;
}

pub fn widgetScrollKeyboardIntent(widget: Widget, keyboard: WidgetKeyboardEvent) ?WidgetControlIntent {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    if (widget.state.disabled) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "home")) return .{ .kind = .scroll_to_start, .actions = .{ .decrement = true } };
    if (std.ascii.eqlIgnoreCase(keyboard.key, "end")) return .{ .kind = .scroll_to_end, .actions = .{ .increment = true } };
    const delta = widgetScrollKeyboardDelta(widget, keyboard) orelse return null;
    return .{
        .kind = .scroll_by,
        .actions = .{
            .increment = delta > 0,
            .decrement = delta < 0,
        },
        .delta = delta,
    };
}

pub fn widgetScrollKeyboardDelta(widget: Widget, keyboard: WidgetKeyboardEvent) ?f32 {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    const line_step = @max(24, viewport.height * 0.35);
    const page_step = @max(line_step, viewport.height * 0.85);
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) {
        return -line_step;
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) {
        return line_step;
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "pageup")) return -page_step;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "pagedown")) return page_step;
    return null;
}

const WidgetSemanticStepDirection = enum {
    increment,
    decrement,
};

fn widgetSemanticStepControlIntent(widget: Widget, direction: WidgetSemanticStepDirection, actions: WidgetActions) ?WidgetControlIntent {
    const increment = direction == .increment;
    if (increment and !actions.increment) return null;
    if (!increment and !actions.decrement) return null;

    const intent_actions = WidgetActions{
        .increment = increment,
        .decrement = !increment,
    };
    return switch (widget.kind) {
        .slider => .{
            .kind = .set_value,
            .actions = intent_actions,
            .value = std.math.clamp(widget.value + if (increment) @as(f32, 0.05) else @as(f32, -0.05), 0, 1),
        },
        .grid, .scroll_view, .list, .data_grid, .table => .{
            .kind = .scroll_by,
            .actions = intent_actions,
            .delta = widgetSemanticScrollDelta(widget, direction),
        },
        else => null,
    };
}

fn widgetSemanticScrollDelta(widget: Widget, direction: WidgetSemanticStepDirection) f32 {
    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    const line_step = @max(24, viewport.height * 0.35);
    const page_step = @max(line_step, viewport.height * 0.85);
    return if (direction == .increment) page_step else -page_step;
}

pub fn semanticActions(widget: Widget) WidgetActions {
    if (widget.state.disabled) return .{};
    var actions = defaultSemanticActions(widget);
    actions.focus = actions.focus or widget.semantics.actions.focus;
    actions.press = actions.press or widget.semantics.actions.press;
    actions.toggle = actions.toggle or widget.semantics.actions.toggle;
    actions.increment = actions.increment or widget.semantics.actions.increment;
    actions.decrement = actions.decrement or widget.semantics.actions.decrement;
    actions.set_text = actions.set_text or widget.semantics.actions.set_text;
    actions.set_selection = actions.set_selection or widget.semantics.actions.set_selection;
    actions.select = actions.select or widget.semantics.actions.select;
    actions.drag = actions.drag or widget.semantics.actions.drag;
    actions.drop_files = actions.drop_files or widget.semantics.actions.drop_files;
    actions.dismiss = actions.dismiss or widget.semantics.actions.dismiss;
    if (widget.state.read_only) {
        actions.set_text = false;
    }
    return actions;
}

pub fn defaultSemanticActions(widget: Widget) WidgetActions {
    if (widget.state.disabled) return .{};

    var actions = WidgetActions{
        .focus = widget.semantics.focusable or defaultFocusable(widget),
    };
    switch (widget.kind) {
        .button, .icon_button, .select => actions.press = true,
        .menu_item => {
            actions.press = true;
            actions.select = true;
        },
        .accordion, .checkbox, .switch_control, .toggle, .toggle_button => actions.toggle = true,
        .radio => {
            actions.select = true;
            if (widget.command.len > 0) actions.press = true;
        },
        .input, .text_field, .search_field, .combobox, .textarea => {
            if (widget.kind == .combobox) actions.press = true;
            actions.set_text = true;
            actions.set_selection = true;
        },
        .slider => {
            actions.increment = true;
            actions.decrement = true;
        },
        .resizable => actions.drag = true,
        .dialog, .drawer, .sheet, .popover, .menu_surface, .dropdown_menu, .tooltip => actions.dismiss = true,
        .list_item, .segmented_control, .data_cell => {
            actions.select = true;
            if (widget.command.len > 0) actions.press = true;
        },
        else => {},
    }
    return actions;
}

pub fn defaultFocusable(widget: Widget) bool {
    return switch (widget.kind) {
        .scroll_view, .accordion, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .menu_item, .list_item, .data_cell, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider => !widget.state.disabled,
        else => false,
    };
}
