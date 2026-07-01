const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const widget_model = @import("widgets.zig");

const ObjectId = canvas.ObjectId;
const TextInputEvent = canvas.TextInputEvent;
const TextRange = canvas.TextRange;
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
