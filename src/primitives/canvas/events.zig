const std = @import("std");
const builtin = @import("builtin");
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
    /// Mechanical wheel input scrolls by its delta without kinetic velocity.
    scroll_is_detented: bool = false,
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
    /// Platform button number for down/up events (0 = primary). Motion
    /// may leave this at 0; gesture owners use the initiating down to
    /// decide whether to capture.
    button: i32 = 0,
    /// Keyboard modifiers held for this pointer event. Text editors use
    /// Shift on pointer-down to extend from the existing selection
    /// anchor instead of replacing it with a collapsed caret.
    modifiers: WidgetKeyboardModifiers = .{},
    /// Runtime-stamped outcome for a release that selected a radio:
    /// true when retained selection actually changed, false when the
    /// already-selected radio was activated again, null when this event
    /// was not a radio selection (or never crossed the runtime seam).
    /// Typed dispatch uses the stamp to keep `on_change` edge-triggered
    /// while preserving the legacy toggle/press activation fallbacks.
    radio_selection_changed: ?bool = null,
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
    /// True when the nearest `radio_group` scope owns this
    /// Arrow/Home/End key. Unlike `focus_moved`, this stays true when the
    /// target is already at the requested edge or is the group's only
    /// focusable radio, so the key cannot leak to an app-level fallback.
    /// Bare radios deliberately leave this false: they retain their
    /// legacy focus-only spatial navigation.
    radio_group_navigation: bool = false,
    /// Whether this radio-group navigation should select the routed
    /// target. A real focus move always selects; an in-place move selects
    /// only when the current radio was unchecked, avoiding duplicate
    /// change dispatches for Home-on-first / End-on-last.
    radio_group_selection: bool = false,
    /// Runtime-stamped outcome for a radio select intent. Space/Enter and
    /// radio-group navigation set this to the retained mutation result;
    /// null means the event was not a radio selection (or was routed by a
    /// direct Tree consumer). This keeps `on_change` tied to a transition,
    /// not merely to an activation key.
    radio_selection_changed: ?bool = null,
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

/// Enter in a multi-line editor normally EDITS instead of submitting.
/// A textarea with `submit_on_enter` reverses only the plain gesture:
/// Enter is left for its submit handler while Shift+Enter stays a
/// newline. The primary-modifier chord (cmd/ctrl+Enter) is deliberately
/// excluded — it is always a textarea submit chord — as is alt+Enter,
/// left free for app shortcuts. Single-line kinds return null here and
/// keep enter-to-submit. Shared by the runtime edit path and the app
/// `on_input` dispatch so retained text and the model hear the same edit.
pub fn widgetKeyboardNewlineTextEditEvent(widget: Widget, event: WidgetKeyboardEvent) ?TextInputEvent {
    if (widget.kind != .textarea) return null;
    if (widget.interaction_policy != null) return compiledTextKeyboardEdit(widget, event, 0);
    if (event.phase != .key_down or event.text.len != 0) return null;
    if (event.modifiers.control or event.modifiers.alt or event.modifiers.super) return null;
    if (!std.ascii.eqlIgnoreCase(event.key, "enter") and !std.ascii.eqlIgnoreCase(event.key, "return")) return null;
    if (widget.submit_on_enter and !event.modifiers.shift) return null;
    return .{ .insert_text = "\n" };
}

/// Editable code owns a plain Tab as indentation input. The file's
/// leading whitespace votes for tabs versus spaces; space widths 2..8
/// compete by how many indentation levels they divide cleanly, with the
/// wider width winning exact ties (4-space files also divide by 2).
/// Ambiguous or unindented source falls back to two spaces.
pub fn widgetCodeTabTextEditEvent(widget: Widget, event: WidgetKeyboardEvent) ?TextInputEvent {
    if (widget.kind != .textarea or !widget.runtime_flags.code_editor or widget.state.disabled) return null;
    if (event.phase != .key_down or event.focus_moved or event.text.len != 0) return null;
    if (event.modifiers.shift or event.modifiers.hasNavigationModifier()) return null;
    if (!std.ascii.eqlIgnoreCase(event.key, "tab")) return null;
    return .{ .insert_text = codeIndentationInsertion(widget) };
}

const CodeIndentKind = enum { none, spaces, tabs };

fn codeIndentationInsertion(widget: Widget) []const u8 {
    if (widget.interaction_policy) |callback| {
        std.debug.assert(widget.text.len <= canvas.max_widget_text_bytes_per_view);
        const request = text_policy_scratch.get().request[0 .. 8 + widget.text.len];
        @memset(request[0..8], 0);
        request[0] = 11;
        const selection = widget.text_selection orelse text_model.TextSelection.collapsed(widget.text.len);
        std.mem.writeInt(u32, request[4..8], @intCast(@min(selection.focus, widget.text.len)), .little);
        @memcpy(request[8..], widget.text);
        var output: [1]u8 = undefined;
        if (callback(request, &output) != 1) @panic("invalid compiled code indentation result");
        return switch (output[0]) {
            0 => "\t",
            2...8 => "        "[0..output[0]],
            else => @panic("invalid compiled code indentation width"),
        };
    }
    var tab_lines: usize = 0;
    var space_lines: usize = 0;
    var space_width_scores: [9]usize = @splat(0);
    var only_space_indent: ?usize = null;

    var line_start: usize = 0;
    while (line_start <= widget.text.len) {
        const newline = std.mem.indexOfScalarPos(u8, widget.text, line_start, '\n');
        const line_end = newline orelse widget.text.len;
        const line = widget.text[line_start..line_end];
        var cursor: usize = 0;
        var spaces: usize = 0;
        var tabs: usize = 0;
        while (cursor < line.len) : (cursor += 1) {
            switch (line[cursor]) {
                ' ' => spaces += 1,
                '\t' => tabs += 1,
                else => break,
            }
        }
        // Whitespace-only lines do not state a file convention.
        if (cursor < line.len and cursor > 0) {
            if (tabs > 0) {
                tab_lines += 1;
            } else {
                space_lines += 1;
                only_space_indent = if (space_lines == 1) spaces else null;
                for (2..space_width_scores.len) |width| {
                    if (spaces % width == 0) space_width_scores[width] += 1;
                }
            }
        }

        if (newline == null) break;
        line_start = line_end + 1;
    }

    const selection = widget.text_selection orelse text_model.TextSelection.collapsed(widget.text.len);
    const local_kind = codeIndentKindAt(widget.text, selection.focus);
    const tabs_win = tab_lines > space_lines or
        (tab_lines == space_lines and tab_lines > 0 and local_kind == .tabs);
    if (tabs_win) return "\t";

    var inferred_width: usize = 2;
    if (space_lines == 1) {
        const width = only_space_indent orelse 0;
        if (width >= 2 and width <= 8) inferred_width = width;
    } else if (space_lines > 1) {
        var best_width: usize = 2;
        var best_score: usize = 0;
        for (2..space_width_scores.len) |width| {
            const score = space_width_scores[width];
            if (score > best_score or (score == best_score and score > 0 and width > best_width)) {
                best_width = width;
                best_score = score;
            }
        }
        if (best_score * 2 >= space_lines) inferred_width = best_width;
    }

    return switch (inferred_width) {
        3 => "   ",
        4 => "    ",
        5 => "     ",
        6 => "      ",
        7 => "       ",
        8 => "        ",
        else => "  ",
    };
}

fn codeIndentKindAt(text: []const u8, offset: usize) CodeIndentKind {
    const caret = @min(offset, text.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..caret], '\n')) |newline| newline + 1 else 0;
    if (line_start >= text.len) return .none;
    return switch (text[line_start]) {
        '\t' => .tabs,
        ' ' => .spaces,
        else => .none,
    };
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
const max_sanitized_text_edit_bytes: usize = text_model.max_widget_text_bytes_per_view;
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

pub const TextInputPreparation = struct {
    text: []const u8,
    cursor: ?usize,
    truncated: bool,
};

/// New input preparation uses the text policy's operation 6. Borrowed
/// results refer only to the source prefix; rewritten results are copied
/// to native scratch before another compiled callback resets its arena.
pub fn widgetCompiledTextInput(widget: Widget, text: []const u8, mode: u8, cursor: ?usize, available: usize) ?TextInputPreparation {
    if (widget.kind != .textarea and !widgetKindSingleLineTextEntry(widget.kind)) return null;
    const policy = widget.interaction_policy orelse return null;
    if (text.len > text_model.max_widget_text_bytes_per_view or available > text_model.max_widget_text_bytes_per_view or mode > 2)
        @panic("compiled text input request exceeds budget");
    const scratch = text_policy_scratch.get();
    const request = scratch.request[0 .. 16 + text.len];
    @memset(request[0..16], 0);
    request[0] = 6;
    request[1] = mode;
    request[2] = @intFromBool(widgetKindSingleLineTextEntry(widget.kind));
    request[3] = @intFromBool(cursor != null);
    std.mem.writeInt(u32, request[4..8], @intCast(@min(cursor orelse 0, text.len)), .little);
    std.mem.writeInt(u32, request[8..12], @intCast(available), .little);
    @memcpy(request[16..], text);
    const len = policy(request, &scratch.result);
    if (len < 12 or len > 12 + text.len) @panic("invalid compiled text input result length");
    const flags = std.mem.readInt(u32, scratch.result[0..4], .little);
    const result_cursor = std.mem.readInt(u32, scratch.result[4..8], .little);
    const text_len = std.mem.readInt(u32, scratch.result[8..12], .little);
    if (flags > 15 or text_len > text.len or result_cursor > text_len or
        (flags & 4 != 0 and mode != 1) or (flags & 8 != 0 and mode != 2))
        @panic("invalid compiled text input result");
    if (flags == 0) {
        if (len != 12 or text_len != 0 or result_cursor != 0) @panic("invalid suppressed text input result");
        return null;
    }
    if (flags & 1 == 0 or (flags & 4 == 0 and result_cursor != 0)) @panic("invalid compiled text input flags");
    const borrowed = flags & 2 != 0;
    if (len != 12 + (if (borrowed) @as(usize, 0) else text_len) or (mode == 2 and text_len > available))
        @panic("invalid compiled text input byte budget");
    if (!borrowed) @memcpy(sanitized_text_edit_scratch.get().bytes[0..text_len], scratch.result[12..len]);
    return .{
        .text = if (borrowed) text[0..text_len] else sanitized_text_edit_scratch.get().bytes[0..text_len],
        // A clean preview is borrowed unchanged, including an authored
        // cursor beyond its length. Only rewritten previews clamp/shift it.
        .cursor = if (borrowed and mode == 1) cursor else if (flags & 4 != 0) result_cursor else null,
        .truncated = flags & 8 != 0,
    };
}

/// Resolve new input against its actual widget so compiled views use the
/// same sanitizer for direct edits, keyboard/IME and Tree fallbacks.
pub fn sanitizedTextInputEventForWidget(widget: Widget, event: TextInputEvent) ?TextInputEvent {
    if (!widgetKindSingleLineTextEntry(widget.kind) or widget.interaction_policy == null)
        return sanitizedSingleLineTextInputEvent(widget.kind, event);
    const text = switch (event) {
        .insert_text => |text| text,
        .set_composition => |composition| composition.text,
        else => return event,
    };
    // Preserve the existing over-budget pass-through/refuse-whole rule.
    if (text.len > max_sanitized_text_edit_bytes) return event;
    const composition = event == .set_composition;
    const result = widgetCompiledTextInput(widget, text, if (composition) 1 else 0, if (composition) event.set_composition.cursor else null, 0) orelse return null;
    return if (composition)
        .{ .set_composition = .{ .text = result.text, .cursor = result.cursor } }
    else
        .{ .insert_text = result.text };
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
    /// Scroll step for `scroll_by` intents, in canvas points on each
    /// axis. Keyboard and semantic scroll steps set exactly one axis;
    /// which one follows the widget's scroll-axes grant (vertical
    /// keymap on vertical-capable regions, horizontal on
    /// horizontal-only ones).
    delta: geometry.OffsetF = .{},
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

pub const WidgetDragPhase = enum {
    change,
    end,
    cancel,
};

pub const WidgetDragEvent = struct {
    source_id: ObjectId = 0,
    phase: WidgetDragPhase = .change,
    point: geometry.PointF,
    /// Total displacement from the pointer-down that began the gesture.
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
    if (widgetKeyboardLineDeleteTextEditEvent(event)) |edit| return edit;
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
    return widgetKeyboardWordDeleteTextEditEventForPlatform(builtin.os.tag, event);
}

fn widgetKeyboardWordDeleteTextEditEventForPlatform(comptime os_tag: @TypeOf(builtin.os.tag), event: WidgetKeyboardEvent) ?TextInputEvent {
    // Ctrl-primary hosts project Ctrl into BOTH `control` and `super`.
    // Accept that folded shape off macOS so Ctrl+Backspace keeps its
    // platform word-delete meaning; a bare Super/Meta chord stays inert.
    if (event.modifiers.shift) return null;
    if (event.modifiers.super) {
        if (comptime os_tag == .macos) return null;
        if (!event.modifiers.control) return null;
    }
    if (event.modifiers.alt == event.modifiers.control) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "backspace")) return .delete_word_backward;
    if (std.ascii.eqlIgnoreCase(event.key, "delete")) return .delete_word_forward;
    return null;
}

fn widgetKeyboardLineDeleteTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    return widgetKeyboardLineDeleteTextEditEventForPlatform(builtin.os.tag, event);
}

fn widgetKeyboardLineDeleteTextEditEventForPlatform(comptime os_tag: @TypeOf(builtin.os.tag), event: WidgetKeyboardEvent) ?TextInputEvent {
    // Command+Backspace is Cocoa's deleteToBeginningOfLine:. Keep it
    // macOS-only: elsewhere Primary is Ctrl and belongs to word delete.
    // Textareas deliberately use the hard newline boundary in v1; visual
    // soft-wrap deletion can layer on runtime geometry in a follow-up.
    if (comptime os_tag != .macos) return null;
    if (!event.modifiers.super or event.modifiers.control or event.modifiers.alt) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "backspace")) return .delete_to_line_start;
    return null;
}

/// Resolve the generic keyboard vocabulary against a concrete editor kind.
/// A single-line field presents model-provided line breaks as spaces, so its
/// Command+Backspace target is always offset 0; a textarea keeps the hard-line
/// boundary carried by `.delete_to_line_start`.
pub fn widgetKeyboardTextEditEventForWidget(widget: Widget, event: WidgetKeyboardEvent) ?TextInputEvent {
    if (event.edit) |edit| {
        if (edit == .delete_to_line_start and widgetKindSingleLineTextEntry(widget.kind)) return .delete_to_start;
        return edit;
    }
    if ((widget.kind == .textarea or widgetKindSingleLineTextEntry(widget.kind)) and widget.interaction_policy != null)
        return compiledTextKeyboardEdit(widget, event, 1);
    const edit = event.textEditEvent() orelse return null;
    if (edit == .delete_to_line_start and widgetKindSingleLineTextEntry(widget.kind)) return .delete_to_start;
    return edit;
}

/// Native normalizes host keys and supplies platform facts. Compiled policy
/// returns only intent; insert bytes stay borrowed from this dispatch.
fn compiledTextKeyboardResult(widget: Widget, event: WidgetKeyboardEvent, operation: u8) [2]u8 {
    const keys = [_][]const u8{ "", "enter", "return", "backspace", "delete", "arrowleft", "arrowright", "home", "end", "a" };
    var key: u8 = 0;
    for (keys[1..], 1..) |name, index| {
        if (std.ascii.eqlIgnoreCase(event.key, name)) {
            key = @intCast(index);
            break;
        }
    }
    const modifiers = event.modifiers;
    const request = [8]u8{ operation, @intFromBool(widget.kind == .textarea), @intCast(@intFromEnum(event.phase)), @as(u8, @intFromBool(modifiers.shift)) | (@as(u8, @intFromBool(modifiers.control)) << 1) |
        (@as(u8, @intFromBool(modifiers.alt)) << 2) | (@as(u8, @intFromBool(modifiers.super)) << 3), @intFromBool(builtin.os.tag == .macos), @intFromBool(widget.submit_on_enter), key, @intFromBool(event.text.len != 0) };
    var output: [2]u8 = undefined;
    if (widget.interaction_policy.?(&request, &output) != 2 or output[0] > 16 or output[1] > 1)
        @panic("invalid compiled text policy result");
    return output;
}

fn compiledTextKeyboardEdit(widget: Widget, event: WidgetKeyboardEvent, operation: u8) ?TextInputEvent {
    const result = compiledTextKeyboardResult(widget, event, operation);
    const extend = result[1] == 1;
    return switch (result[0]) {
        0 => null,
        1 => .{ .insert_text = event.text },
        2 => .{ .insert_text = "\n" },
        3 => .delete_backward,
        4 => .delete_forward,
        5 => .{ .move_caret = .{ .direction = .previous, .extend = extend } },
        6 => .{ .move_caret = .{ .direction = .next, .extend = extend } },
        7 => .{ .move_caret = .{ .direction = .start, .extend = extend } },
        8 => .{ .move_caret = .{ .direction = .end, .extend = extend } },
        9 => .{ .move_caret = .{ .direction = .previous_word, .extend = extend } },
        10 => .{ .move_caret = .{ .direction = .next_word, .extend = extend } },
        11 => .delete_word_backward,
        12 => .delete_word_forward,
        13 => .delete_to_line_start,
        14 => .{ .set_selection = .{ .anchor = 0, .focus = std.math.maxInt(usize) } },
        16 => .delete_to_start,
        else => @panic("invalid compiled text edit intent"),
    };
}

pub const TextPointerPolicyResult = struct {
    selection: text_model.TextSelection,
    anchor: TextRange,
};

const text_policy_scratch = canvas.lazy_tls.LazyTls(struct {
    request: [40 + 2 * text_model.max_widget_text_bytes_per_view]u8,
    result: [24 + text_model.max_widget_text_bytes_per_view]u8,
});

pub const TextClipboardPolicyResult = struct {
    selection: ?TextRange,
    select_all: bool,
};

/// Source-only clipboard range and default edit-menu availability. Native
/// callers retain eligibility, clipboard ownership and write-before-cut.
pub fn widgetTextClipboardState(widget: Widget) TextClipboardPolicyResult {
    if ((widget.kind == .textarea or widgetKindSingleLineTextEntry(widget.kind)) and widget.interaction_policy != null) {
        if (widget.text.len > text_model.max_widget_text_bytes_per_view) @panic("compiled clipboard request exceeds text budget");
        const request = text_policy_scratch.get().request[0 .. 24 + widget.text.len];
        @memset(request[0..24], 0);
        request[0] = 12;
        std.mem.writeInt(u32, request[4..8], @intCast(widget.text.len), .little);
        if (widget.text_selection) |selection| {
            request[1] = 1;
            std.mem.writeInt(u64, request[8..16], @intCast(selection.anchor), .little);
            std.mem.writeInt(u64, request[16..24], @intCast(selection.focus), .little);
        }
        @memcpy(request[24..], widget.text);
        var output: [12]u8 = undefined;
        if (widget.interaction_policy.?(request, &output) != output.len) @panic("invalid compiled clipboard result");
        const flags = std.mem.readInt(u32, output[0..4], .little);
        const start = std.mem.readInt(u32, output[4..8], .little);
        const end = std.mem.readInt(u32, output[8..12], .little);
        if (flags > 3 or (flags & 1 != 0 and (widget.text_selection == null or start >= end or end > widget.text.len)) or
            (flags & 1 == 0 and (start != 0 or end != 0)) or (flags & 2 != 0 and widget.text.len == 0))
            @panic("invalid compiled clipboard range");
        return .{ .selection = if (flags & 1 != 0) .{ .start = start, .end = end } else null, .select_all = flags & 2 != 0 };
    }
    const range = canvas.widgetTextSelectionRange(widget);
    return .{ .selection = if (range) |selected| if (selected.isCollapsed(widget.text.len)) null else selected else null, .select_all = widget.text.len > 0 };
}

/// Native resolves the pointer into a byte offset. Compiled policy selects
/// the run and orients its union with the gesture anchor; copy before reset.
pub fn widgetCompiledTextPointerSelection(widget: Widget, offset: usize, click_count: u8, mode: u8, anchor: TextRange) ?TextPointerPolicyResult {
    if (widget.kind != .textarea and !widgetKindSingleLineTextEntry(widget.kind)) return null;
    const policy = widget.interaction_policy orelse return null;
    if (widget.text.len > text_model.max_widget_text_bytes_per_view) @panic("compiled text pointer request exceeds text budget");
    const request = text_policy_scratch.get().request[0 .. 16 + widget.text.len];
    request[0] = 3;
    request[1] = @intFromBool(widget.kind == .textarea);
    request[2] = @min(click_count, 3);
    request[3] = mode;
    std.mem.writeInt(u32, request[4..8], @intCast(@min(offset, widget.text.len)), .little);
    std.mem.writeInt(u32, request[8..12], @intCast(@min(anchor.start, widget.text.len)), .little);
    std.mem.writeInt(u32, request[12..16], @intCast(@min(anchor.end, widget.text.len)), .little);
    @memcpy(request[16..], widget.text);
    var output: [16]u8 = undefined;
    if (policy(request, &output) != output.len) @panic("invalid compiled text pointer result");
    const result = TextPointerPolicyResult{
        .selection = .{ .anchor = std.mem.readInt(u32, output[0..4], .little), .focus = std.mem.readInt(u32, output[4..8], .little) },
        .anchor = .{ .start = std.mem.readInt(u32, output[8..12], .little), .end = std.mem.readInt(u32, output[12..16], .little) },
    };
    if (result.selection.anchor > widget.text.len or result.selection.focus > widget.text.len or
        result.anchor.start > result.anchor.end or result.anchor.end > widget.text.len)
        @panic("invalid compiled text pointer range");
    return result;
}

/// Compile the same SDK reducer used by app models. Copy edited bytes before
/// arena reset; caret-only results retain the native source without copying.
/// Painted affinity remains native metadata, including CRLF canonicalization.
pub fn widgetCompiledTextEdit(widget: Widget, state: text_model.TextEditState, edit: TextInputEvent, output: []u8) error{TextEditBufferTooSmall}!?text_model.TextEditState {
    if (widget.kind != .textarea and !widgetKindSingleLineTextEntry(widget.kind)) return null;
    const policy = widget.interaction_policy orelse return null;
    const capacity = @min(output.len, text_model.max_widget_text_bytes_per_view);
    const inserted: []const u8 = switch (edit) {
        .insert_text => |text| text,
        .set_composition => |composition| composition.text,
        else => "",
    };
    if (inserted.len > capacity) return error.TextEditBufferTooSmall;
    if (state.text.len > text_model.max_widget_text_bytes_per_view) @panic("compiled text reducer source exceeds text budget");
    const scratch = text_policy_scratch.get();
    const request = scratch.request[0 .. 40 + state.text.len + inserted.len];
    @memset(request[0..40], 0);
    request[0] = 4;
    request[1] = switch (edit) {
        .insert_text => 0,
        .delete_backward => 1,
        .delete_forward => 2,
        .delete_word_backward => 3,
        .delete_word_forward => 4,
        .delete_to_start => 5,
        .delete_to_line_start => 6,
        .clear => 7,
        .move_caret => 8,
        .set_selection => 9,
        .set_composition => 10,
        .commit_composition => 11,
        .cancel_composition => 12,
    };
    if (edit == .move_caret) {
        request[2] = switch (edit.move_caret.direction) {
            .previous => 0,
            .next => 1,
            .previous_word => 2,
            .next_word => 3,
            .start => 4,
            .end => 5,
        };
        request[3] = @intFromBool(edit.move_caret.extend);
    }
    request[4] = @intFromBool(state.composition != null);
    request[5] = @intFromBool(edit == .set_composition and edit.set_composition.cursor != null);
    std.mem.writeInt(u32, request[8..12], @intCast(state.text.len), .little);
    std.mem.writeInt(u32, request[12..16], @intCast(@min(state.selection.anchor, state.text.len)), .little);
    std.mem.writeInt(u32, request[16..20], @intCast(@min(state.selection.focus, state.text.len)), .little);
    if (state.composition) |composition| {
        std.mem.writeInt(u32, request[20..24], @intCast(@min(composition.start, state.text.len)), .little);
        std.mem.writeInt(u32, request[24..28], @intCast(@min(composition.end, state.text.len)), .little);
    }
    if (edit == .set_selection) {
        std.mem.writeInt(u32, request[28..32], @intCast(@min(edit.set_selection.anchor, state.text.len)), .little);
        std.mem.writeInt(u32, request[32..36], @intCast(@min(edit.set_selection.focus, state.text.len)), .little);
    } else if (edit == .set_composition) {
        std.mem.writeInt(u32, request[28..32], @intCast(@min(edit.set_composition.cursor orelse 0, inserted.len)), .little);
    }
    std.mem.writeInt(u32, request[36..40], @intCast(capacity), .little);
    @memcpy(request[40..][0..state.text.len], state.text);
    @memcpy(request[40 + state.text.len ..], inserted);
    const len = policy(request, &scratch.result);
    if (len == 4 and std.mem.readInt(u32, scratch.result[0..4], .little) == 0) return error.TextEditBufferTooSmall;
    if (len < 24 or len > scratch.result.len) @panic("invalid compiled text reducer result length");
    const flags = std.mem.readInt(u32, scratch.result[0..4], .little);
    if (flags != 1 and flags != 3) @panic("invalid compiled text reducer result flags");
    const retained = flags == 3;
    if ((retained and len != 24) or (!retained and len - 24 > capacity)) @panic("invalid compiled text reducer byte budget");
    const text = if (retained) state.text else output[0 .. len - 24];
    if (!retained) @memcpy(output[0 .. len - 24], scratch.result[24..len]);
    const composition_present = std.mem.readInt(u32, scratch.result[12..16], .little);
    if (composition_present > 1) @panic("invalid compiled text reducer composition flag");
    const result = text_model.TextEditState{
        .text = text,
        .selection = .{ .anchor = std.mem.readInt(u32, scratch.result[4..8], .little), .focus = std.mem.readInt(u32, scratch.result[8..12], .little), .affinity = switch (edit) {
            .set_selection => |selection| canvas.snapTextCaretSelection(state.text, selection).affinity,
            .commit_composition => canvas.snapTextCaretSelection(state.text, state.selection).affinity,
            .cancel_composition => if (state.composition == null) canvas.snapTextCaretSelection(state.text, state.selection).affinity else .upstream,
            else => .upstream,
        } },
        .composition = if (composition_present == 1) .{ .start = std.mem.readInt(u32, scratch.result[16..20], .little), .end = std.mem.readInt(u32, scratch.result[20..24], .little) } else null,
    };
    if (result.selection.anchor > text.len or result.selection.focus > text.len) @panic("invalid compiled text reducer selection");
    if (result.composition) |composition| {
        if (composition.start > composition.end or composition.end > text.len) @panic("invalid compiled text reducer composition");
    }
    return result;
}

pub const TextReconcilePolicyState = struct {
    source_unchanged: bool,
    source_matches_runtime: bool,
    previous_source_selection: ?text_model.TextSelection,
    retained_selection: ?text_model.TextSelection,
};

pub const TextReconcilePolicyResult = struct {
    retain_text: bool,
    retain_state: bool,
    retain_selection_composition: bool,
    retain_affinity: bool,
};

/// Native supplies source fingerprints and retained identity/state. The
/// compiled policy decides which editor state survives the source rebuild.
pub fn widgetCompiledTextReconcile(widget: Widget, state: TextReconcilePolicyState) ?TextReconcilePolicyResult {
    if (widget.kind != .textarea and !widgetKindSingleLineTextEntry(widget.kind)) return null;
    const policy = widget.interaction_policy orelse return null;
    var request: [40]u8 = @splat(0);
    request[0] = 5;
    request[1] = @intFromBool(state.source_unchanged);
    request[2] = @intFromBool(state.source_matches_runtime);
    request[4] = @as(u8, @intFromBool(widget.text_selection != null)) |
        (@as(u8, @intFromBool(widget.text_composition != null)) << 1);
    if (widget.text_selection) |selection| {
        request[4] |= @as(u8, @intFromBool(selection.affinity == .downstream)) << 2;
        std.mem.writeInt(u64, request[8..16], @intCast(selection.anchor), .little);
        std.mem.writeInt(u64, request[16..24], @intCast(selection.focus), .little);
    }
    if (state.retained_selection) |selection| {
        request[5] = 1 | (@as(u8, @intFromBool(selection.affinity == .downstream)) << 1);
        std.mem.writeInt(u64, request[24..32], @intCast(selection.anchor), .little);
        std.mem.writeInt(u64, request[32..40], @intCast(selection.focus), .little);
    }
    if (state.previous_source_selection) |selection| {
        request[6] = 1 | (@as(u8, @intFromBool(selection.affinity == .downstream)) << 1);
    }
    var output: [1]u8 = undefined;
    if (policy(&request, &output) != output.len or output[0] > 15) @panic("invalid compiled text reconcile result");
    const flags = output[0];
    if (flags != 0 and flags & 2 == 0) @panic("invalid compiled text reconcile retention");
    return .{
        .retain_text = flags & 1 != 0,
        .retain_state = flags & 2 != 0,
        .retain_selection_composition = flags & 4 != 0,
        .retain_affinity = flags & 8 != 0,
    };
}

pub const TextHistoryDelta = struct {
    prefix_len: usize,
    before_end: usize,
    after_end: usize,
};

pub const TextHistoryRecordResult = union(enum) { none, delta: TextHistoryDelta };

/// Compile the replacement ranges while both states still borrow native
/// storage. The fixed result is copied before history allocation/compaction.
pub fn widgetCompiledTextHistoryDelta(widget: Widget, before: text_model.TextEditState, after: text_model.TextEditState, provisional: bool) ?TextHistoryRecordResult {
    if (widget.kind != .textarea and !widgetKindSingleLineTextEntry(widget.kind)) return null;
    const policy = widget.interaction_policy orelse return null;
    const budget = text_model.max_widget_text_bytes_per_view;
    if (before.text.len > budget or after.text.len > budget) @panic("compiled text history delta exceeds byte budget");
    const request = text_policy_scratch.get().request[0 .. 24 + before.text.len + after.text.len];
    @memset(request[0..24], 0);
    request[0] = 8;
    request[1] = @intFromBool(provisional);
    request[2] = @intFromBool(after.composition != null);
    std.mem.writeInt(u32, request[4..8], @intCast(before.text.len), .little);
    std.mem.writeInt(u32, request[8..12], @intCast(after.text.len), .little);
    const removed = text_model.snapTextCaretSelection(before.text, before.selection).range(before.text.len);
    std.mem.writeInt(u32, request[12..16], @intCast(removed.start), .little);
    std.mem.writeInt(u32, request[16..20], @intCast(removed.end), .little);
    std.mem.writeInt(u32, request[20..24], @intCast(if (after.composition) |composition| composition.end else 0), .little);
    @memcpy(request[24..][0..before.text.len], before.text);
    @memcpy(request[24 + before.text.len ..], after.text);
    var output: [16]u8 = undefined;
    if (policy(request, &output) != output.len) @panic("invalid compiled text history delta result");
    const record = std.mem.readInt(u32, output[0..4], .little);
    if (record == 0) {
        if (!std.mem.allEqual(u8, output[4..], 0)) @panic("invalid empty compiled text history delta");
        return .none;
    }
    const delta = TextHistoryDelta{
        .prefix_len = std.mem.readInt(u32, output[4..8], .little),
        .before_end = std.mem.readInt(u32, output[8..12], .little),
        .after_end = std.mem.readInt(u32, output[12..16], .little),
    };
    if (record != 1 or delta.prefix_len > delta.before_end or delta.prefix_len > delta.after_end or
        delta.before_end > before.text.len or delta.after_end > after.text.len)
        @panic("invalid compiled text history delta ranges");
    return .{ .delta = delta };
}

pub const TextCompositionHistoryState = struct {
    prefix_len: usize,
    removed_len: usize,
    before_text_len: usize,
    after_text_len: usize,
    capacity: usize,
    active: bool,
    before_matches: bool,
};

pub const TextCompositionHistoryResult = struct {
    action: enum(u32) { discard, retain, remove, commit },
    after_end: usize = 0,
    inserted_len: usize = 0,
};

/// Plan a provisional entry update without borrowing text or history bytes.
/// Copy the fixed result before another policy call resets the compiler arena.
pub fn widgetCompiledTextCompositionHistory(widget: Widget, state: TextCompositionHistoryState) ?TextCompositionHistoryResult {
    if (widget.kind != .textarea and !widgetKindSingleLineTextEntry(widget.kind)) return null;
    const policy = widget.interaction_policy orelse return null;
    const budget = text_model.max_widget_text_bytes_per_view;
    if (state.before_text_len > budget or state.after_text_len > budget or state.capacity > budget or
        state.prefix_len > std.math.maxInt(u32) or state.removed_len > std.math.maxInt(u32))
        @panic("compiled text composition history exceeds byte budget");
    var request: [24]u8 = @splat(0);
    request[0] = 9;
    request[1] = @intFromBool(state.active);
    request[2] = @intFromBool(state.before_matches);
    const args = [_]usize{ state.prefix_len, state.removed_len, state.before_text_len, state.after_text_len, state.capacity };
    for (args, 0..) |value, index| std.mem.writeInt(u32, request[4 + index * 4 ..][0..4], @intCast(value), .little);
    var output: [12]u8 = undefined;
    if (policy(&request, &output) != output.len) @panic("invalid compiled text composition history result");
    const action = std.mem.readInt(u32, output[0..4], .little);
    const end = std.mem.readInt(u32, output[4..8], .little);
    const inserted = std.mem.readInt(u32, output[8..12], .little);
    if (action > 3 or (action == 0 and (end != 0 or inserted != 0)))
        @panic("invalid compiled text composition history action");
    if (action != 0 and (end < state.prefix_len or end > state.after_text_len or
        inserted != end - state.prefix_len or state.removed_len > state.capacity or inserted > state.capacity - state.removed_len))
        @panic("invalid compiled text composition history range");
    return .{ .action = @enumFromInt(action), .after_end = end, .inserted_len = inserted };
}

pub const max_text_history_timeline_entries: usize = 128;

pub const TextHistoryTimelineEntry = struct {
    target_matches: bool = false,
    kind_matches: bool = false,
    applied: bool = true,
    provisional: bool = false,
    before_matches: bool = false,
    after_matches: bool = false,
};

pub const TextHistoryTimelineResult = struct {
    matches_state: bool,
    can_undo: bool,
    can_redo: bool,
    undo_index: ?usize,
    redo_index: ?usize,
};

/// Select ordered history boundaries using native identity/hash witnesses.
/// The result contains copied indices; entry storage and serials stay native.
pub fn widgetCompiledTextHistoryTimeline(widget: Widget, entries: []const TextHistoryTimelineEntry) ?TextHistoryTimelineResult {
    if (widget.kind != .textarea and !widgetKindSingleLineTextEntry(widget.kind)) return null;
    const policy = widget.interaction_policy orelse return null;
    if (entries.len > max_text_history_timeline_entries) @panic("compiled text history timeline exceeds entry budget");
    var request: [8 + max_text_history_timeline_entries]u8 = @splat(0);
    request[0] = 10;
    std.mem.writeInt(u32, request[4..8], @intCast(entries.len), .little);
    for (entries, 0..) |entry, index| request[8 + index] =
        @as(u8, @intFromBool(entry.target_matches)) |
        (@as(u8, @intFromBool(entry.kind_matches)) << 1) |
        (@as(u8, @intFromBool(entry.applied)) << 2) |
        (@as(u8, @intFromBool(entry.provisional)) << 3) |
        (@as(u8, @intFromBool(entry.before_matches)) << 4) |
        (@as(u8, @intFromBool(entry.after_matches)) << 5);
    var output: [12]u8 = undefined;
    if (policy(request[0 .. 8 + entries.len], &output) != output.len) @panic("invalid compiled text history timeline result");
    const flags = std.mem.readInt(u32, output[0..4], .little);
    const undo = std.mem.readInt(u32, output[4..8], .little);
    const redo = std.mem.readInt(u32, output[8..12], .little);
    if (flags > 7 or undo > entries.len or redo > entries.len or
        (flags & 2 != 0 and undo == 0) or (flags & 4 != 0 and redo == 0))
        @panic("invalid compiled text history timeline indices");
    const result = TextHistoryTimelineResult{
        .matches_state = flags & 1 != 0,
        .can_undo = flags & 2 != 0,
        .can_redo = flags & 4 != 0,
        .undo_index = if (undo == 0) null else undo - 1,
        .redo_index = if (redo == 0) null else redo - 1,
    };
    if (result.undo_index) |index| {
        const entry = entries[index];
        if (!entry.target_matches or !entry.kind_matches or !entry.applied or entry.provisional or
            (result.can_undo and !entry.after_matches)) @panic("invalid compiled text history Undo boundary");
    }
    if (result.redo_index) |index| {
        const entry = entries[index];
        if (!entry.target_matches or !entry.kind_matches or entry.applied or entry.provisional or
            (result.can_redo and !entry.before_matches)) @panic("invalid compiled text history Redo boundary");
    }
    return result;
}

pub const TextHistoryReplayState = struct {
    mode: enum(u8) { start, next, commit },
    redo: bool,
    before_matches: bool,
    after_matches: bool,
    selection: text_model.TextSelection,
    before_selection: text_model.TextSelection,
    after_selection: text_model.TextSelection,
    prefix: usize,
    removed: []const u8,
    inserted: []const u8,
};

pub const TextHistoryReplayResult = union(enum) {
    none,
    clear,
    complete,
    edit: TextInputEvent,
};

/// The compiled planner returns one replay step. Insert payloads borrow the
/// native history pool; selection data is copied before any arena reset.
pub fn widgetCompiledTextHistoryReplay(widget: Widget, state: TextHistoryReplayState) ?TextHistoryReplayResult {
    if (widget.kind != .textarea and !widgetKindSingleLineTextEntry(widget.kind)) return null;
    const policy = widget.interaction_policy orelse return null;
    const budget = text_model.max_widget_text_bytes_per_view;
    if (state.removed.len > budget or state.inserted.len > budget - state.removed.len or
        state.prefix > budget - @max(state.removed.len, state.inserted.len))
        @panic("compiled text history exceeds byte budget");
    const request = text_policy_scratch.get().request[0 .. 68 + state.removed.len + state.inserted.len];
    @memset(request[0..68], 0);
    request[0] = 7;
    request[1] = @intFromEnum(state.mode);
    request[2] = @intFromBool(state.redo);
    request[3] = @as(u8, @intFromBool(state.before_matches)) | (@as(u8, @intFromBool(state.after_matches)) << 1);
    const selections = [_]text_model.TextSelection{ state.selection, state.before_selection, state.after_selection };
    for (selections, 0..) |selection, index| {
        request[4] |= @as(u8, @intFromBool(selection.affinity == .downstream)) << @intCast(index);
        const start = 8 + index * 16;
        std.mem.writeInt(u64, request[start..][0..8], @intCast(selection.anchor), .little);
        std.mem.writeInt(u64, request[start + 8 ..][0..8], @intCast(selection.focus), .little);
    }
    std.mem.writeInt(u32, request[56..60], @intCast(state.prefix), .little);
    std.mem.writeInt(u32, request[60..64], @intCast(state.removed.len), .little);
    std.mem.writeInt(u32, request[64..68], @intCast(state.inserted.len), .little);
    @memcpy(request[68..][0..state.removed.len], state.removed);
    @memcpy(request[68 + state.removed.len ..], state.inserted);
    var output: [24]u8 = undefined;
    if (policy(request, &output) != output.len or output[0] > 6 or output[1] > 1 or
        !std.mem.allEqual(u8, output[2..8], 0)) @panic("invalid compiled text history result");
    if (output[0] != 6 and !std.mem.allEqual(u8, output[1..], 0)) @panic("invalid compiled text history arguments");
    return switch (output[0]) {
        0 => .none,
        1 => .clear,
        2 => .complete,
        3 => .{ .edit = .{ .insert_text = if (state.redo) state.inserted else state.removed } },
        4 => .{ .edit = .delete_backward },
        5 => .{ .edit = .delete_forward },
        6 => .{ .edit = .{ .set_selection = .{
            .anchor = @intCast(std.mem.readInt(u64, output[8..16], .little)),
            .focus = @intCast(std.mem.readInt(u64, output[16..24], .little)),
            .affinity = if (output[1] == 1) .downstream else .upstream,
        } } },
        else => unreachable,
    };
}

pub fn widgetKeyboardTextSubmit(widget: Widget, event: WidgetKeyboardEvent) bool {
    if (!isWidgetTextEntry(widget)) return false;
    if (widget.state.disabled or event.phase != .key_down) return false;
    if (widget.interaction_policy != null) return compiledTextKeyboardResult(widget, event, 2)[0] == 15;
    if (!std.ascii.eqlIgnoreCase(event.key, "enter")) return false;
    if (widget.kind != .textarea) return !event.modifiers.hasNavigationModifier();
    return (widget.submit_on_enter and !event.modifiers.hasNavigationModifier() and !event.modifiers.shift) or
        (event.modifiers.hasCommandModifier() and !event.modifiers.alt and !event.modifiers.shift);
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
    if (widget.kind == .radio) {
        if (widgetRadioKeyboardControlIntent(widget, keyboard)) |intent| return intent;
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
        .slider => if (widgetSliderControlKeyboardValue(widget, keyboard)) |next_value|
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
        .split_divider => if (widgetSplitControlKeyboardValue(widget, keyboard)) |next_value|
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
        // Composed controls can bind a press on an ordinary container
        // (timeline items use a focusable stack). Its declared semantic
        // action must answer the same activation keys as a button.
        else => if (widget.semantics.focusable and widget.semantics.actions.press and isWidgetActivationKey(keyboard.key))
            .{ .kind = .press, .actions = .{ .press = true } }
        else
            null,
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
    // Host adapters normalize the physical Return key to "enter" before
    // it reaches this canonical event vocabulary. AppKit maps both its
    // carriage-return key event and insertNewline: selector to that name.
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

test "line delete is macOS-only and folded Ctrl-primary remains word delete elsewhere" {
    const command_backspace = WidgetKeyboardEvent{
        .phase = .key_down,
        .key = "backspace",
        .modifiers = .{ .super = true },
    };
    try std.testing.expectEqual(TextInputEvent.delete_to_line_start, widgetKeyboardLineDeleteTextEditEventForPlatform(.macos, command_backspace).?);
    try std.testing.expect(widgetKeyboardLineDeleteTextEditEventForPlatform(.linux, command_backspace) == null);
    try std.testing.expect(widgetKeyboardLineDeleteTextEditEventForPlatform(.windows, command_backspace) == null);

    const folded_control_backspace = WidgetKeyboardEvent{
        .phase = .key_down,
        .key = "backspace",
        .modifiers = .{ .super = true, .control = true },
    };
    try std.testing.expect(widgetKeyboardWordDeleteTextEditEventForPlatform(.macos, folded_control_backspace) == null);
    try std.testing.expectEqual(TextInputEvent.delete_word_backward, widgetKeyboardWordDeleteTextEditEventForPlatform(.linux, folded_control_backspace).?);
    try std.testing.expectEqual(TextInputEvent.delete_word_backward, widgetKeyboardWordDeleteTextEditEventForPlatform(.windows, folded_control_backspace).?);

    const shifted_command_backspace = WidgetKeyboardEvent{
        .phase = .key_down,
        .key = "backspace",
        .modifiers = .{ .super = true, .shift = true },
    };
    try std.testing.expectEqual(TextInputEvent.delete_to_line_start, widgetKeyboardLineDeleteTextEditEventForPlatform(.macos, shifted_command_backspace).?);

    // Widget-kind resolution is downstream of platform recognition. Stamp
    // the recognized semantic edit so these assertions stay host-neutral;
    // the explicit-platform assertions above own the macOS chord mapping.
    const recognized_line_delete = WidgetKeyboardEvent{
        .phase = .key_down,
        .edit = .delete_to_line_start,
    };
    try std.testing.expectEqual(TextInputEvent.delete_to_start, widgetKeyboardTextEditEventForWidget(.{ .kind = .input }, recognized_line_delete).?);
    try std.testing.expectEqual(TextInputEvent.delete_to_line_start, widgetKeyboardTextEditEventForWidget(.{ .kind = .textarea }, recognized_line_delete).?);
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

/// The compiled slider policy exchanges canonical f32 values. The callback
/// copies its result before resetting the scriptc arena; no tree bytes escape.
pub fn widgetCompiledSliderValue(widget: Widget, operation: u8, previous_source: ?f32, retained: f32, pressed: bool) ?f32 {
    if (widget.kind != .slider) return null;
    const policy = widget.interaction_policy orelse return null;
    var request: [14]u8 = undefined;
    request[0] = operation;
    request[1] = @as(u8, if (previous_source != null) 1 else 0) | @as(u8, if (pressed) 2 else 0);
    std.mem.writeInt(u32, request[2..6], @bitCast(widget.value), .little);
    std.mem.writeInt(u32, request[6..10], @bitCast(previous_source orelse @as(f32, 0)), .little);
    std.mem.writeInt(u32, request[10..14], @bitCast(retained), .little);
    var output: [4]u8 = undefined;
    if (policy(&request, &output) != output.len) @panic("invalid compiled slider policy result");
    const value: f32 = @bitCast(std.mem.readInt(u32, &output, .little));
    if (!std.math.isFinite(value) or (operation < 2 and (value < 0 or value > 1))) @panic("invalid compiled slider policy value");
    return value;
}

fn widgetSliderControlKeyboardValue(widget: Widget, keyboard: WidgetKeyboardEvent) ?f32 {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier() or widget.state.disabled) return null;
    if (widget.interaction_policy == null) return widgetSliderKeyboardValue(widget.value, keyboard);
    const operation: u8 = if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown"))
        (if (keyboard.modifiers.shift) @as(u8, 4) else 2)
    else if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowup"))
        (if (keyboard.modifiers.shift) @as(u8, 5) else 3)
    else if (std.ascii.eqlIgnoreCase(keyboard.key, "home"))
        6
    else if (std.ascii.eqlIgnoreCase(keyboard.key, "end"))
        7
    else
        return null;
    return widgetCompiledSliderValue(widget, operation, null, 0, false);
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

/// Width policy uses native f32 geometry and copies the result before the
/// compiler arena resets. Operation 0 applies drag, 1 reconciles retained width.
pub fn widgetCompiledResizableWidth(widget: Widget, operation: u8, current: f32, delta: f32) ?f32 {
    if (widget.kind != .resizable) return null;
    const policy = widget.interaction_policy orelse return null;
    var request: [13]u8 = undefined;
    request[0] = operation;
    for ([_]f32{ widget.frame.height, current, delta }, 0..) |value, index|
        std.mem.writeInt(u32, request[1 + index * 4 ..][0..4], @bitCast(value), .little);
    var output: [4]u8 = undefined;
    if (policy(&request, &output) != output.len) @panic("invalid compiled resizable policy result");
    const width: f32 = @bitCast(std.mem.readInt(u32, &output, .little));
    if (std.math.isNan(width) or width < 48) @panic("invalid compiled resizable policy width");
    return width;
}

pub const SplitPolicyRequest = struct {
    operation: u8,
    value: f32,
    available: f32 = 0,
    first_min: f32 = 0,
    second_min: f32 = 0,
    previous_source: ?f32 = null,
    retained: f32 = 0,
    declared_tween: bool = false,
    armed_tween: bool = false,
};

/// Canonical f32 policy exchange; the generated callback copies its result
/// before resetting the scriptc arena. The retained widget owns no ABI bytes.
pub fn widgetCompiledSplitValue(widget: Widget, input: SplitPolicyRequest) ?f32 {
    if (widget.kind != .split and widget.kind != .split_divider) return null;
    const policy = widget.interaction_policy orelse return null;
    var request: [26]u8 = undefined;
    request[0] = input.operation;
    request[1] = @as(u8, if (input.previous_source != null) 1 else 0) |
        @as(u8, if (input.declared_tween) 2 else 0) | @as(u8, if (input.armed_tween) 4 else 0);
    const values = [_]f32{ input.value, input.available, input.first_min, input.second_min, input.previous_source orelse 0, input.retained };
    for (values, 0..) |value, index| std.mem.writeInt(u32, request[2 + index * 4 ..][0..4], @bitCast(value), .little);
    var output: [4]u8 = undefined;
    if (policy(&request, &output) != output.len) @panic("invalid compiled split policy result");
    const value: f32 = @bitCast(std.mem.readInt(u32, &output, .little));
    if (!std.math.isFinite(value) or (input.operation < 2 and (value < 0 or value > 1))) @panic("invalid compiled split policy value");
    return value;
}

fn widgetSplitControlKeyboardValue(widget: Widget, keyboard: WidgetKeyboardEvent) ?f32 {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier() or widget.state.disabled) return null;
    if (widget.interaction_policy == null) return widgetSplitDividerKeyboardValue(widget.value, keyboard);
    const operation: u8 = if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft"))
        (if (keyboard.modifiers.shift) @as(u8, 5) else 3)
    else if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright"))
        (if (keyboard.modifiers.shift) @as(u8, 6) else 4)
    else if (std.ascii.eqlIgnoreCase(keyboard.key, "home"))
        7
    else if (std.ascii.eqlIgnoreCase(keyboard.key, "end"))
        8
    else
        return null;
    return widgetCompiledSplitValue(widget, .{ .operation = operation, .value = widget.value });
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

/// A radio inside a `radio_group` follows focus for the group's
/// Arrow/Home/End keymap. Space/Enter continue through the ordinary
/// activation arm below; radios outside a group never receive the
/// `radio_group_selection` stamp and keep their old behavior.
fn widgetRadioKeyboardControlIntent(widget: Widget, keyboard: WidgetKeyboardEvent) ?WidgetControlIntent {
    if (!keyboard.radio_group_selection) return null;
    const navigation_key = std.ascii.eqlIgnoreCase(keyboard.key, "arrowup") or
        std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown") or
        std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or
        std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or
        std.ascii.eqlIgnoreCase(keyboard.key, "home") or
        std.ascii.eqlIgnoreCase(keyboard.key, "end");
    if (!navigation_key) return null;
    return .{
        .kind = .select,
        .actions = .{
            .select = true,
            .press = widget.command.len > 0,
        },
    };
}

pub const ScrollPolicyRequest = struct {
    operation: u8,
    current: f32 = 0,
    viewport: f32 = 0,
    content: f32 = 0,
    delta: f32 = 0,
    previous_source: ?f32 = null,
    retained: ?f32 = null,
    granted: bool = true,
    horizontal_keymap: bool = false,
    dual_keymap: bool = false,
};

/// The callback copies two f32 results before the scriptc arena resets.
/// Scalar offset operations use dx; keyboard operations return both axes.
pub fn widgetCompiledScrollResult(widget: Widget, value: ScrollPolicyRequest) ?geometry.OffsetF {
    if (widget.kind != .scroll_view or !widget.runtime_flags.compiled_scroll_policy) return null;
    const policy = widget.interaction_policy orelse return null;
    var request: [26]u8 = undefined;
    request[0] = 128 + value.operation;
    request[1] = @as(u8, if (value.granted) 1 else 0) |
        @as(u8, if (value.previous_source != null) 2 else 0) |
        @as(u8, if (value.retained != null) 4 else 0) |
        @as(u8, if (value.horizontal_keymap) 8 else 0) |
        @as(u8, if (value.dual_keymap) 16 else 0);
    inline for (.{ value.current, value.viewport, value.content, value.delta, value.previous_source orelse @as(f32, 0), value.retained orelse @as(f32, 0) }, 0..) |number, index| {
        std.mem.writeInt(u32, request[2 + index * 4 ..][0..4], @bitCast(number), .little);
    }
    var output: [8]u8 = undefined;
    if (policy(&request, &output) != output.len) @panic("invalid compiled scroll policy result");
    const result = geometry.OffsetF.init(@bitCast(std.mem.readInt(u32, output[0..4], .little)), @bitCast(std.mem.readInt(u32, output[4..8], .little)));
    if (!std.math.isFinite(result.dx) or !std.math.isFinite(result.dy)) @panic("invalid compiled scroll policy value");
    return result;
}

pub fn widgetScrollKeyboardIntent(widget: Widget, keyboard: WidgetKeyboardEvent) ?WidgetControlIntent {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    if (widget.state.disabled) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "home")) return .{ .kind = .scroll_to_start, .actions = .{ .decrement = true } };
    if (std.ascii.eqlIgnoreCase(keyboard.key, "end")) return .{ .kind = .scroll_to_end, .actions = .{ .increment = true } };
    const delta = widgetScrollKeyboardDelta(widget, keyboard) orelse return null;
    const step = if (delta.dy != 0) delta.dy else delta.dx;
    return .{
        .kind = .scroll_by,
        .actions = .{
            .increment = step > 0,
            .decrement = step < 0,
        },
        .delta = delta,
    };
}

/// True when a scroll-intent widget takes the HORIZONTAL keymap: a
/// horizontal-only `.scroll_view`. Vertical-capable regions (including
/// `both`, whose left/right arrows step sideways below) and every other
/// scrollable kind keep the vertical keymap they always had.
fn widgetScrollKeymapHorizontalOnly(widget: Widget) bool {
    return widget.kind == .scroll_view and !widget.layout.virtualized and widget.scroll_axes == .horizontal;
}

/// The keyboard scroll step, axis-aware:
/// - vertical regions keep the exact legacy map (both arrow pairs step
///   the vertical axis — Left/Up a line up, Right/Down a line down —
///   and PageUp/PageDown page it);
/// - a horizontal-only region mirrors that whole map onto its one axis,
///   with line/page steps measured from the viewport WIDTH;
/// - a `both` region keeps the vertical map and gives Left/Right to the
///   horizontal axis — the two-axis convention native scroll views use.
pub fn widgetScrollKeyboardDelta(widget: Widget, keyboard: WidgetKeyboardEvent) ?geometry.OffsetF {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    if (widget.kind == .scroll_view and widget.runtime_flags.compiled_scroll_policy and widget.interaction_policy != null) {
        const operation: u8 = if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft")) 4 else if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright")) 5 else if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) 6 else if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) 7 else if (std.ascii.eqlIgnoreCase(keyboard.key, "pageup")) 8 else if (std.ascii.eqlIgnoreCase(keyboard.key, "pagedown")) 9 else return null;
        return widgetCompiledScrollResult(widget, .{
            .operation = operation,
            .viewport = viewport.width,
            .content = viewport.height,
            .horizontal_keymap = widgetScrollKeymapHorizontalOnly(widget),
            .dual_keymap = !widget.layout.virtualized and widget.scroll_axes == .both,
        });
    }
    if (widgetScrollKeymapHorizontalOnly(widget)) {
        const line_step = @max(24, viewport.width * 0.35);
        const page_step = @max(line_step, viewport.width * 0.85);
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) {
            return geometry.OffsetF.init(-line_step, 0);
        }
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) {
            return geometry.OffsetF.init(line_step, 0);
        }
        if (std.ascii.eqlIgnoreCase(keyboard.key, "pageup")) return geometry.OffsetF.init(-page_step, 0);
        if (std.ascii.eqlIgnoreCase(keyboard.key, "pagedown")) return geometry.OffsetF.init(page_step, 0);
        return null;
    }
    const dual = widget.kind == .scroll_view and !widget.layout.virtualized and widget.scroll_axes == .both;
    const line_step = @max(24, viewport.height * 0.35);
    const page_step = @max(line_step, viewport.height * 0.85);
    if (dual) {
        const line_step_x = @max(24, viewport.width * 0.35);
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft")) return geometry.OffsetF.init(-line_step_x, 0);
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright")) return geometry.OffsetF.init(line_step_x, 0);
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return geometry.OffsetF.init(0, -line_step);
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return geometry.OffsetF.init(0, line_step);
    } else {
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) {
            return geometry.OffsetF.init(0, -line_step);
        }
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) {
            return geometry.OffsetF.init(0, line_step);
        }
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "pageup")) return geometry.OffsetF.init(0, -page_step);
    if (std.ascii.eqlIgnoreCase(keyboard.key, "pagedown")) return geometry.OffsetF.init(0, page_step);
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
            .value = std.math.clamp(widgetCompiledSliderValue(widget, if (increment) 3 else 2, null, 0, false) orelse
                (widget.value + if (increment) @as(f32, 0.05) else @as(f32, -0.05)), 0, 1),
        },
        .grid, .scroll_view, .list, .data_grid, .table => .{
            .kind = .scroll_by,
            .actions = intent_actions,
            .delta = widgetSemanticScrollDelta(widget, direction),
        },
        else => null,
    };
}

/// Assistive scroll steps page ONE axis — the region's primary, by the
/// same range-aware rule its scroll semantics report through: vertical
/// wherever the vertical axis is granted and can move, the horizontal
/// axis on horizontal-only regions and on `both` regions whose content
/// only overflows sideways. A diagonal step would move the viewport on
/// an axis the assistive node never exposed. Range for the `both` case
/// reads the widget's own children (widget-walk trees carry them);
/// retained layout nodes drop children, and their caller — the
/// runtime's accessibility-action path — resolves the axis with live
/// extents instead (`canvasWidgetStepKey`).
fn widgetSemanticScrollDelta(widget: Widget, direction: WidgetSemanticStepDirection) geometry.OffsetF {
    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    const sign: f32 = if (direction == .increment) 1 else -1;
    const horizontal_primary = widgetScrollKeymapHorizontalOnly(widget) or
        (widget.kind == .scroll_view and !widget.layout.virtualized and widget.scroll_axes == .both and
            widgetChildrenScrollHorizontalOnly(widget, viewport));
    if (widgetCompiledScrollResult(widget, .{ .operation = if (direction == .increment) 11 else 10, .viewport = viewport.width, .content = viewport.height, .horizontal_keymap = horizontal_primary })) |delta| return delta;
    if (horizontal_primary) {
        const page_step_x = @max(@max(24, viewport.width * 0.35), viewport.width * 0.85);
        return geometry.OffsetF.init(sign * page_step_x, 0);
    }
    const page_step_y = @max(@max(24, viewport.height * 0.35), viewport.height * 0.85);
    return geometry.OffsetF.init(0, sign * page_step_y);
}

/// Whether a `both` region's mounted children overflow ONLY sideways:
/// no vertical range (nothing reaches past the fold) while something
/// reaches past the right edge. False on childless nodes — retained
/// trees drop children, and their callers resolve range elsewhere.
fn widgetChildrenScrollHorizontalOnly(widget: Widget, viewport: geometry.RectF) bool {
    if (widget.children.len == 0) return false;
    var right = viewport.maxX();
    var bottom = viewport.maxY();
    for (widget.children) |child| {
        right = @max(right, child.frame.maxX() + widget.value_x);
        bottom = @max(bottom, child.frame.maxY() + widget.value);
    }
    return bottom <= viewport.maxY() and right > viewport.maxX();
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
        .scroll_view, .accordion, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .menu_item, .list_item, .data_cell, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .split_divider, .terminal => !widget.state.disabled,
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

test "sanitizedSingleLineTextInputEvent sanitizes inserts above the former 64 KiB ceiling" {
    const testing = std.testing;
    const input = try testing.allocator.alloc(u8, 65537);
    defer testing.allocator.free(input);
    @memset(input, 'a');
    input[32768] = '\n';

    const sanitized = sanitizedSingleLineTextInputEvent(.text_field, .{ .insert_text = input }).?;
    try testing.expectEqual(@as(usize, input.len - 1), sanitized.insert_text.len);
    try testing.expect(std.mem.indexOfAny(u8, sanitized.insert_text, "\r\n") == null);
}
