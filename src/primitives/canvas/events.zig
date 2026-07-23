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
    /// Semantic role of the hit widget (kind alone cannot distinguish a
    /// link hotspot from plain text, and links want a pointer cursor).
    role: WidgetRole = .none,
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
    /// How many rapid same-spot primary clicks this pointer event is
    /// part of: 1 = plain click, 2 = double (text inputs select the
    /// word under the pointer), 3 = triple (select all / the clicked
    /// line). The runtime derives it from recorded event timestamps —
    /// hosts do not forward a native click count — and clamps at 3, so
    /// a fourth rapid click repeats the triple behavior like platform
    /// text views. `.move` events during a drag carry the count of the
    /// press that started the gesture, which is how a double-click
    /// drag knows to extend by words.
    click_count: u8 = 1,
    /// The host's pointer identity (`GpuSurfaceInputEvent.pointer_id`),
    /// forwarded so per-pointer state can tell devices apart on hosts
    /// that distinguish them: the hover-Msg containment gate scopes its
    /// hover-capable-pointer proof to this id, so a touch contact can
    /// never ride a mouse's proof. Desktop hosts with one pointer leave
    /// it 0.
    pointer_id: u64 = 0,
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
    /// True when the runtime moved keyboard focus in response to this
    /// key BEFORE routing, so the event targets the newly focused
    /// widget (tree row navigation, group focus moves). Tree rows use
    /// it to tell "selection followed focus onto me" (dispatch select)
    /// from "an arrow landed on me in place" (collapse/expand intent).
    focus_moved: bool = false,
    edit: ?TextInputEvent = null,
    /// True when the runtime clamped a clipboard paste to fit capacity
    /// before building `edit`; apps that care about lost bytes must check
    /// this instead of assuming the whole clipboard landed.
    edit_truncated: bool = false,
    modifiers: WidgetKeyboardModifiers = .{},

    pub fn textEditEvent(self: WidgetKeyboardEvent) ?TextInputEvent {
        if (self.edit) |edit| return edit;
        return widgetKeyboardTextEditEvent(self);
    }
};

/// Enter in a multi-line editor EDITS instead of submitting: a textarea
/// maps a plain Enter keydown to a newline insert, and Shift+Enter stays
/// a newline too so single-line muscle memory never destroys text. The
/// primary-modifier chord (cmd/ctrl+Enter) is deliberately excluded —
/// that is the textarea's submit chord — as is alt+Enter, left free for
/// app shortcuts. Single-line kinds return null here and keep
/// enter-to-submit. Shared by the runtime edit path and the app `on_input`
/// dispatch so the retained text and the model always hear the same edit.
pub fn widgetKeyboardNewlineTextEditEvent(kind: WidgetKind, event: WidgetKeyboardEvent) ?TextInputEvent {
    if (kind != .textarea) return null;
    if (event.phase != .key_down or event.text.len != 0) return null;
    if (event.modifiers.control or event.modifiers.alt or event.modifiers.super) return null;
    if (!std.ascii.eqlIgnoreCase(event.key, "enter") and !std.ascii.eqlIgnoreCase(event.key, "return")) return null;
    return .{ .insert_text = "\n" };
}

/// The single-line text-entry kinds: their value can never hold a line
/// break (Enter submits instead of editing — see
/// `widgetKeyboardNewlineTextEditEvent`), so text inserted into them
/// sanitizes through `sanitizedSingleLineTextInputEvent`. The textarea is
/// the one genuinely multi-line editable kind and stays out.
pub fn widgetKindSingleLineTextEntry(kind: WidgetKind) bool {
    return kind == .input or kind == .text_field or kind == .search_field or kind == .combobox;
}

/// Sanitized-edit scratch: the rewritten insert bytes live here until the
/// next edit that needs rewriting. Sound for the same reason the runtime's
/// paste buffer is: the event loop is single-threaded, at most one
/// insert-bearing edit is derived per dispatched input, and every consumer
/// (retained editor apply, the app's `on_input` Msg, model mirrors) reads
/// the stamped bytes synchronously within that dispatch. Sized to the
/// runtime's per-view widget-text budget
/// (`max_canvas_widget_text_bytes_per_view`), the largest insert the
/// editor could accept anyway.
const max_sanitized_text_edit_bytes: usize = 65536;
const SanitizedTextEditScratch = struct {
    bytes: [max_sanitized_text_edit_bytes]u8,
};
const sanitized_text_edit_scratch = @import("lazy_tls.zig").LazyTls(SanitizedTextEditScratch);

fn textContainsLineBreakByte(text: []const u8) bool {
    // Raw byte scan is UTF-8 safe: 0x0A/0x0D never appear inside a
    // multibyte sequence.
    return std.mem.indexOfAny(u8, text, "\r\n") != null;
}

/// The ONE sanitization rule for text entering a single-line field, at
/// the edit-derivation seam every insertion source flows through
/// (clipboard paste — shortcut and context menu —, typed/automation
/// `text_input`, IME composition, and the app-side fallback derivation):
///
///   line breaks are STRIPPED from inserted text — U+000A and U+000D
///   removed outright, lines joined with nothing between them.
///
/// This is the HTML value sanitization algorithm for single-line inputs
/// ("Strip newlines from the value",
/// https://html.spec.whatwg.org/multipage/input.html), which is also what
/// Chromium does when pasting multi-line text into an `<input>` — the
/// dominant convention. (WebKit historically substituted spaces; there is
/// no spec for the paste path itself, so the value-sanitization rule
/// wins.)
///
/// Contracts, in declaration order:
///   - multi-line kinds (textarea) and non-insert edits pass through
///     untouched;
///   - an insert that strips to NOTHING is suppressed (null): pasting
///     bare newlines inserts nothing and never eats a live selection,
///     and an Enter whose host stuffed "\r"/"\n" into the key event
///     stays not-an-insert;
///   - a composition update strips the same way but an EMPTY result is
///     kept (an empty preview is meaningful — it clears the previous
///     one), with the preview cursor shifted left past the removed
///     bytes, so the IME COMMIT (which lands whatever the preview
///     holds) can never commit a line break into a single-line field;
///   - an insert too large for the scratch passes through untouched —
///     the editor apply rejects over-budget inserts loudly anyway.
///
/// Deterministic derivation: the session journal records the RAW
/// platform event; replaying it re-derives the identical sanitized edit
/// here, so recorded multi-line pastes replay byte-identically.
pub fn sanitizedSingleLineTextInputEvent(kind: WidgetKind, event: TextInputEvent) ?TextInputEvent {
    if (!widgetKindSingleLineTextEntry(kind)) return event;
    switch (event) {
        .insert_text => |text| {
            if (!textContainsLineBreakByte(text)) return event;
            if (text.len > max_sanitized_text_edit_bytes) return event;
            const stripped = stripLineBreakBytes(text, &sanitized_text_edit_scratch.get().bytes);
            if (stripped.len == 0) return null;
            return .{ .insert_text = stripped };
        },
        .set_composition => |composition| {
            if (!textContainsLineBreakByte(composition.text)) return event;
            if (composition.text.len > max_sanitized_text_edit_bytes) return event;
            const cursor = @min(composition.cursor orelse composition.text.len, composition.text.len);
            var stripped_cursor: usize = cursor;
            for (composition.text[0..cursor]) |byte| {
                if (byte == '\n' or byte == '\r') stripped_cursor -= 1;
            }
            const stripped = stripLineBreakBytes(composition.text, &sanitized_text_edit_scratch.get().bytes);
            return .{ .set_composition = .{
                .text = stripped,
                .cursor = if (composition.cursor == null and stripped_cursor == stripped.len) null else stripped_cursor,
            } };
        },
        else => return event,
    }
}

fn stripLineBreakBytes(text: []const u8, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (text) |byte| {
        if (byte == '\n' or byte == '\r') continue;
        buffer[len] = byte;
        len += 1;
    }
    return buffer[0..len];
}

/// The clipboard intent of a key event: cmd+C/X/V on macOS, ctrl+C/X/V
/// elsewhere (`hasCommandModifier` covers both). Shift/alt variants are
/// deliberately excluded so shift+ctrl+V-style paste-special chords stay
/// available to apps.
pub const WidgetClipboardAction = enum {
    copy,
    cut,
    paste,
};

pub fn widgetKeyboardClipboardAction(event: WidgetKeyboardEvent) ?WidgetClipboardAction {
    if (event.phase != .key_down) return null;
    if (!event.modifiers.hasCommandModifier() or event.modifiers.alt or event.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "c")) return .copy;
    if (std.ascii.eqlIgnoreCase(event.key, "x")) return .cut;
    if (std.ascii.eqlIgnoreCase(event.key, "v")) return .paste;
    return null;
}

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
    /// Where a press on `target` actually lands: the deepest widget on the
    /// hit path that claims presses (`widgetClaimsPress`). Equal to
    /// `target` for interactive widgets; the nearest pressable ancestor
    /// when the raw hit is plain text/decoration; null when nothing on the
    /// path is pressable.
    press_target: ?WidgetHit = null,
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
    // Tree rows are ROLE-driven (any pressable row becomes one by
    // carrying `role = .treeitem`), so their keymap resolves before the
    // kind switch.
    if (widget.semantics.role == .treeitem) {
        if (widgetTreeItemKeyboardControlIntent(widget, keyboard)) |intent| return intent;
    }
    return switch (widget.kind) {
        .button, .icon_button => if (isWidgetActivationKey(keyboard.key))
            .{ .kind = .press, .actions = .{ .press = true } }
        else
            null,
        // The closed-trigger open keys: Enter/Space press, and
        // ArrowDown/Up ALSO press so an arrow on a closed select opens
        // its model-owned picker. With the picker mounted the runtime's
        // focus step consumes the arrows first (they walk into the
        // anchored menu), and a trigger marked `expanded` never
        // re-presses from an arrow — pressing an open trigger would
        // toggle it closed.
        .select, .combobox => if (isWidgetActivationKey(keyboard.key) or
            (isWidgetMenuOpenArrowKey(keyboard.key) and !(widget.state.expanded orelse false)))
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
        // The split divider is the ARIA separator: horizontal arrows
        // adjust the parent split's fraction, Home/End jump to the
        // clamp edges (the runtime clamps against the panes' min
        // widths when it applies the value).
        .split_divider => if (widgetSplitDividerKeyboardValue(widget.value, keyboard)) |next_value|
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
    if (widget.semantics.role == .treeitem and actions.select) {
        return .{
            .kind = .select,
            .actions = .{
                .press = true,
                .select = true,
            },
        };
    }
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

/// The editable text-entry widget kinds: a focused one of these owns
/// typing outright. Key routing treats the set STRUCTURALLY — a focused
/// text entry consumes character keys whether or not the app bound
/// `on_input`, so an app-level key fallback (a bare-space transport
/// toggle, single-letter accelerators) can never fire while the user is
/// typing. One definition serves the typed-dispatch path (`Ui.Tree`)
/// and the ui-app fallback gate.
pub fn isWidgetTextEntry(widget: Widget) bool {
    return switch (widget.kind) {
        .input, .text_field, .search_field, .combobox, .textarea => true,
        else => false,
    };
}

/// The arrow keys that open a closed select/combobox trigger's picker
/// (and, once it is mounted, walk into it).
pub fn isWidgetMenuOpenArrowKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "arrowdown") or std.ascii.eqlIgnoreCase(key, "arrowup");
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

/// Fraction steps for the split divider: the slider's step sizes, on the
/// horizontal axis only (the vertical arrows stay free for tree/list
/// focus travel around the divider).
pub fn widgetSplitDividerKeyboardValue(current: f32, keyboard: WidgetKeyboardEvent) ?f32 {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    const step: f32 = if (keyboard.modifiers.shift) 0.1 else 0.05;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft")) return current - step;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright")) return current + step;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "home")) return 0;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "end")) return 1;
    return null;
}

/// The ARIA tree-row keymap, resolved on the routed keyboard target:
/// - Enter/Space activate (select, plus press when a command is bound).
/// - A key that MOVED focus onto this row (`focus_moved`) selects it —
///   selection follows focus, dispatched through the row's press
///   handler so the model owns it.
/// - Left on an expanded row collapses, Right on a collapsed row
///   expands (both as toggle intents — the model owns the state through
///   `on_toggle`; the runtime's focus pass already handled the
///   move-to-parent / move-to-first-child cases by moving focus, which
///   arrives here as `focus_moved`).
fn widgetTreeItemKeyboardControlIntent(widget: Widget, keyboard: WidgetKeyboardEvent) ?WidgetControlIntent {
    if (isWidgetActivationKey(keyboard.key)) {
        return .{
            .kind = .select,
            .actions = .{
                .select = true,
                .press = widget.command.len > 0,
            },
        };
    }
    const navigation_key = std.ascii.eqlIgnoreCase(keyboard.key, "arrowup") or
        std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown") or
        std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or
        std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or
        std.ascii.eqlIgnoreCase(keyboard.key, "home") or
        std.ascii.eqlIgnoreCase(keyboard.key, "end");
    if (!navigation_key) return null;
    if (keyboard.focus_moved) {
        return .{
            .kind = .select,
            .actions = .{
                .select = true,
                .press = widget.command.len > 0,
            },
        };
    }
    const expanded = widget.state.expanded orelse return null;
    if (expanded and std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft")) {
        return .{ .kind = .toggle, .actions = .{ .toggle = true } };
    }
    if (!expanded and std.ascii.eqlIgnoreCase(keyboard.key, "arrowright")) {
        return .{ .kind = .toggle, .actions = .{ .toggle = true } };
    }
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
        .split_divider => {
            actions.drag = true;
            actions.increment = true;
            actions.decrement = true;
        },
        .dialog, .drawer, .sheet, .popover, .menu_surface, .dropdown_menu, .tooltip => actions.dismiss = true,
        .list_item, .segmented_control, .data_cell => {
            actions.select = true;
            if (widget.command.len > 0) actions.press = true;
        },
        else => {},
    }
    // Tree rows are role-driven: any row carrying `role = .treeitem` is
    // selectable through the tree keymap and assistive select actions.
    if (widget.semantics.role == .treeitem) {
        actions.select = true;
        if (widget.command.len > 0) actions.press = true;
    }
    return actions;
}

pub fn defaultFocusable(widget: Widget) bool {
    // Tree rows are role-driven: `role = .treeitem` on any row makes it
    // part of the tree's roving keyboard focus set.
    if (widget.semantics.role == .treeitem) return !widget.state.disabled;
    return switch (widget.kind) {
        .scroll_view, .accordion, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .menu_item, .list_item, .data_cell, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .split_divider => !widget.state.disabled,
        else => false,
    };
}

test "sanitizedSingleLineTextInputEvent strips line breaks per the HTML value-sanitization rule" {
    const testing = std.testing;
    // Interior LF, CR, and CRLF all strip outright — lines join with
    // nothing between them (the Chromium <input> paste behavior).
    const pasted = sanitizedSingleLineTextInputEvent(.input, .{ .insert_text = "alpha\nbeta\r\ngamma\r" }).?;
    try testing.expectEqualStrings("alphabetagamma", pasted.insert_text);

    // Every single-line kind sanitizes; the textarea keeps its breaks.
    for ([_]WidgetKind{ .input, .text_field, .search_field, .combobox }) |kind| {
        const stripped = sanitizedSingleLineTextInputEvent(kind, .{ .insert_text = "a\nb" }).?;
        try testing.expectEqualStrings("ab", stripped.insert_text);
    }
    const textarea = sanitizedSingleLineTextInputEvent(.textarea, .{ .insert_text = "a\nb" }).?;
    try testing.expectEqualStrings("a\nb", textarea.insert_text);

    // Break-free inserts pass through as the SAME slice (zero copy), and
    // the deliberately-empty insert (cut's delete-selection) survives.
    const clean: TextInputEvent = .{ .insert_text = "plain" };
    try testing.expectEqual(clean.insert_text.ptr, sanitizedSingleLineTextInputEvent(.input, clean).?.insert_text.ptr);
    const cut = sanitizedSingleLineTextInputEvent(.input, .{ .insert_text = "" }).?;
    try testing.expectEqualStrings("", cut.insert_text);

    // An insert that is ONLY line breaks suppresses: pasting bare
    // newlines inserts nothing, and an Enter whose host stuffed "\r"
    // into the key event stays not-an-insert.
    try testing.expect(sanitizedSingleLineTextInputEvent(.input, .{ .insert_text = "\r\n\n" }) == null);

    // Non-insert edits pass through untouched.
    const moved = sanitizedSingleLineTextInputEvent(.input, .{ .move_caret = .{ .direction = .end } }).?;
    try testing.expect(moved.move_caret.direction == .end);
}

test "sanitizedSingleLineTextInputEvent strips composition text and shifts the preview cursor" {
    const testing = std.testing;
    // "ab\ncd" with the cursor after "cd" (offset 5): the stripped
    // preview is "abcd" with the cursor at 4.
    const preview = sanitizedSingleLineTextInputEvent(.combobox, .{ .set_composition = .{ .text = "ab\ncd", .cursor = 5 } }).?;
    try testing.expectEqualStrings("abcd", preview.set_composition.text);
    try testing.expectEqual(@as(usize, 4), preview.set_composition.cursor.?);

    // A cursor BEFORE the break does not shift.
    const early = sanitizedSingleLineTextInputEvent(.search_field, .{ .set_composition = .{ .text = "ab\ncd", .cursor = 2 } }).?;
    try testing.expectEqual(@as(usize, 2), early.set_composition.cursor.?);

    // A null cursor (end-of-preview) stays null.
    const tail = sanitizedSingleLineTextInputEvent(.input, .{ .set_composition = .{ .text = "a\r\nb" } }).?;
    try testing.expectEqualStrings("ab", tail.set_composition.text);
    try testing.expect(tail.set_composition.cursor == null);

    // An all-breaks preview is KEPT as the empty preview (it clears the
    // previous one) rather than suppressed.
    const cleared = sanitizedSingleLineTextInputEvent(.input, .{ .set_composition = .{ .text = "\n" } }).?;
    try testing.expectEqualStrings("", cleared.set_composition.text);

    // A textarea preview keeps its newline.
    const multi = sanitizedSingleLineTextInputEvent(.textarea, .{ .set_composition = .{ .text = "a\nb" } }).?;
    try testing.expectEqualStrings("a\nb", multi.set_composition.text);
}
