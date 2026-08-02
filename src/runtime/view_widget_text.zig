const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");

const unionRects = canvas_frame_helpers.unionRects;
const canvasWidgetEscapeKey = canvas_frame_helpers.canvasWidgetEscapeKey;
const max_canvas_widget_nodes_per_view = canvas_limits.max_canvas_widget_nodes_per_view;
const max_canvas_widget_text_bytes_per_view = canvas_limits.max_canvas_widget_text_bytes_per_view;
const WidgetTextStorageRange = canvas_widget_runtime.WidgetTextStorageRange;
const canvasWidgetEditableTextKind = canvas_widget_runtime.canvasWidgetEditableTextKind;
const canvasWidgetLayoutNodeHidden = canvas_widget_runtime.canvasWidgetLayoutNodeHidden;
const canvasWidgetLayoutNodeFrameVisible = canvas_widget_runtime.canvasWidgetLayoutNodeFrameVisible;
const canvasWidgetSingleLineTextKind = canvas_widget_runtime.canvasWidgetSingleLineTextKind;
const appendWidgetTextStorageRange = canvas_widget_runtime.appendWidgetTextStorageRange;
const canvasWidgetTextEditUnchanged = canvas_widget_runtime.canvasWidgetTextEditUnchanged;
const canvasTextSelectionsEqual = canvas_widget_runtime.canvasTextSelectionsEqual;
const textSelectionCollapsedAt = canvas_widget_runtime.textSelectionCollapsedAt;

pub const CanvasWidgetTextHistoryEntry = struct {
    serial: u64 = 0,
    target_id: canvas.ObjectId = 0,
    target_kind: canvas.WidgetKind = .text,
    byte_start: usize = 0,
    removed_len: usize = 0,
    inserted_len: usize = 0,
    prefix_len: usize = 0,
    before_text_len: usize = 0,
    after_text_len: usize = 0,
    before_hash: u64 = 0,
    after_hash: u64 = 0,
    before_selection: canvas.TextSelection = .{},
    after_selection: canvas.TextSelection = .{},
    applied: bool = true,
    /// An active IME preedit is one logical edit whose inserted bytes can
    /// change many times before commit. The entry stays out of undo/redo
    /// lookup until the composition resolves.
    provisional_composition: bool = false,
};

pub const CanvasWidgetTextHistoryShortcutResult = struct {
    edit: canvas.TextInputEvent,
    serial: u64,
    redo: bool,
};

pub const CanvasWidgetTextHistoryAvailability = struct {
    can_undo: bool = false,
    can_redo: bool = false,
};

const max_text_history_edits_per_shortcut = 3;

/// One event-loop thread performs at most one retained widget edit at a time.
/// Keep the maximal edit/rewrite workspaces in lazy per-thread storage: with
/// practical code-file budgets these buffers no longer fit on mobile and
/// Windows default stacks, while unused host threads still pay only the TLS
/// pointer supplied by `LazyTls`.
const CanvasWidgetTextEditScratch = struct {
    edit_buffer: [max_canvas_widget_text_bytes_per_view]u8,
    rewrite_buffer: [max_canvas_widget_text_bytes_per_view]u8,
    text_ranges: [max_canvas_widget_nodes_per_view]WidgetTextStorageRange,
    label_ranges: [max_canvas_widget_nodes_per_view]WidgetTextStorageRange,
    command_ranges: [max_canvas_widget_nodes_per_view]WidgetTextStorageRange,
};
const canvas_widget_text_edit_scratch = canvas.lazy_tls.LazyTls(CanvasWidgetTextEditScratch);

pub fn RuntimeViewCanvasWidgetText(comptime RuntimeView: type) type {
    return struct {
        pub fn applyCanvasWidgetTextEdit(self: *RuntimeView, target_id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!?geometry.RectF {
            return applyCanvasWidgetTextEditWithHistory(self, target_id, edit, true);
        }

        pub fn applyCanvasWidgetTextEditWithoutHistory(self: *RuntimeView, target_id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!?geometry.RectF {
            return applyCanvasWidgetTextEditWithHistory(self, target_id, edit, false);
        }

        pub fn canvasWidgetTextEditNeedsLargeStorage(
            self: *const RuntimeView,
            target_id: canvas.ObjectId,
            edit: canvas.TextInputEvent,
        ) bool {
            if (self.widget_text_bytes_heap_owned) return false;
            _ = self.canvasWidgetNodeIndexById(target_id) orelse return false;
            const inserted_len = switch (edit) {
                .insert_text => |text| text.len,
                .set_composition => |composition| composition.text.len,
                else => 0,
            };
            return self.widget_text_len +| inserted_len > self.widget_text_bytes.len;
        }

        fn applyCanvasWidgetTextEditWithHistory(self: *RuntimeView, target_id: canvas.ObjectId, edit: canvas.TextInputEvent, record_history: bool) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(target_id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;

            const previous_bounds = widget.frame;
            const scratch = canvas_widget_text_edit_scratch.get();
            const current_state = canvas.TextEditState{
                .text = widget.text,
                .selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len),
                .composition = widget.text_composition,
            };
            const next_state = try current_state.apply(edit, &scratch.edit_buffer);
            if (canvasWidgetTextEditUnchanged(current_state, next_state)) return null;
            try validateCanvasWidgetTextStorageRewrite(self, index, next_state);

            const starts_composition = current_state.composition == null and next_state.composition != null;
            const history_recorded = record_history and
                (starts_composition or
                    (current_state.composition == null and
                        !std.mem.eql(u8, current_state.text, next_state.text))) and
                recordCanvasWidgetTextHistory(self, target_id, widget.kind, current_state, next_state, starts_composition);
            self.rewriteCanvasWidgetTextStorage(index, next_state) catch |err| {
                if (history_recorded) removeCanvasWidgetTextHistoryEntry(self, self.canvas_widget_text_history_entry_count - 1);
                return err;
            };
            if (record_history and current_state.composition != null) {
                updateCanvasWidgetTextCompositionHistory(self, target_id, next_state);
            }
            self.scrollCanvasTextInputCaretIntoView(index);
            const semantics = try self.widgetLayoutTree().collectSemantics(&self.widget_semantics_nodes);
            self.widget_semantics_node_count = semantics.len;
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, unionRects(previous_bounds, self.widget_layout_nodes[index].frame) orelse self.widget_layout_nodes[index].frame);
        }

        /// The leading edge of a non-empty selection. At a soft-wrap
        /// boundary one byte offset has two painted caret stops; selected
        /// text beginning there starts on the downstream visual line.
        fn canvasWidgetTextSelectionStartPosition(self: *RuntimeView, widget: canvas.Widget, offset: usize) canvas.TextCaretPosition {
            const upstream_position = canvas.TextCaretPosition{
                .offset = offset,
                .affinity = .upstream,
            };
            var upstream_widget = widget;
            upstream_widget.text_selection = canvas.TextSelection.collapsedAt(upstream_position);
            var downstream_widget = widget;
            downstream_widget.text_selection = canvas.TextSelection.collapsedAt(.{
                .offset = offset,
                .affinity = .downstream,
            });
            if (canvas.textGeometryForWidget(upstream_widget, self.widget_tokens).caret_bounds) |upstream_caret| {
                if (canvas.textGeometryForWidget(downstream_widget, self.widget_tokens).caret_bounds) |downstream_caret| {
                    if (downstream_caret.y > upstream_caret.y) {
                        return .{
                            .offset = offset,
                            .affinity = .downstream,
                        };
                    }
                }
            }
            return upstream_position;
        }

        pub fn canvasWidgetKeyboardTextEdit(self: *RuntimeView, target: canvas.WidgetFocusTarget, keyboard: canvas.WidgetKeyboardEvent) ?canvas.TextInputEvent {
            const index = self.canvasWidgetNodeIndexById(target.id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;

            const plain_vertical_navigation_key = widget.kind == .textarea and
                (keyboard.phase == .key_down or keyboard.phase == .key_up) and
                keyboard.text.len == 0 and
                !keyboard.modifiers.hasNavigationModifier() and
                (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup") or
                    std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown"));
            // A physical arrow gesture ends with key_up. Keep the preferred
            // x coordinate through that release so separately pressed arrows
            // form the same vertical-navigation run as auto-repeat keydowns.
            if (!plain_vertical_navigation_key) clearCanvasWidgetTextVerticalGoal(self);

            if (keyboard.phase == .key_down and !keyboard.modifiers.shift and !keyboard.modifiers.hasNavigationModifier() and canvasWidgetEscapeKey(keyboard.key)) {
                if (widget.text_composition != null) return .cancel_composition;
                if (widget.kind == .search_field or widget.kind == .combobox) return .clear;
                return null;
            }

            // Multi-line editing contract: Enter (plain or shift) inserts
            // a newline; submit rides the primary-modifier chord instead.
            // Shared with the app dispatch path so the model's `on_input`
            // hears exactly the edit the retained text applied.
            if (canvas.widgetCodeTabTextEditEvent(widget, keyboard)) |tab_edit| {
                return tab_edit;
            }
            if (canvas.widgetKeyboardNewlineTextEditEvent(widget.kind, keyboard)) |newline_edit| {
                return newline_edit;
            }

            // macOS textarea navigation differs deliberately from the
            // single-line field keymap: Command+Left/Right is scoped to
            // the PAINTED visual line (including soft wraps), while
            // Command+Up/Down reaches the document boundary. Return an
            // explicit selection for the line moves so the exact target is
            // stamped onto on-input and controlled TextBuffers mirror it.
            if (comptime builtin.os.tag == .macos) {
                if (widget.kind == .textarea and
                    keyboard.phase == .key_down and
                    keyboard.text.len == 0 and
                    keyboard.modifiers.super and
                    !keyboard.modifiers.control and
                    !keyboard.modifiers.alt)
                {
                    const selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
                    const moving_left = std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft");
                    const moving_right = std.ascii.eqlIgnoreCase(keyboard.key, "arrowright");
                    if (moving_left or moving_right) {
                        const range = selection.range(widget.text.len);
                        const origin_position = if (!keyboard.modifiers.shift and !selection.isCollapsed(widget.text.len))
                            if (moving_left)
                                canvasWidgetTextSelectionStartPosition(self, widget, range.start)
                            else
                                canvas.TextCaretPosition{ .offset = range.end, .affinity = .upstream }
                        else
                            canvas.TextCaretPosition{
                                .offset = selection.focus,
                                .affinity = selection.affinity,
                            };
                        var caret_widget = widget;
                        caret_widget.text_selection = canvas.TextSelection.collapsedAt(origin_position);
                        const caret = canvas.textGeometryForWidget(caret_widget, self.widget_tokens).caret_bounds orelse return null;
                        const frame = widget.frame.normalized();
                        const target_x = if (moving_left) frame.x - 1 else frame.maxX() + 1;
                        const target_position = canvas.textCaretPositionForWidgetPoint(
                            widget,
                            geometry.PointF.init(target_x, caret.y + caret.height * 0.5),
                            self.widget_tokens,
                        ) orelse return null;
                        return .{ .set_selection = if (keyboard.modifiers.shift)
                            .{
                                .anchor = selection.anchor,
                                .focus = target_position.offset,
                                .affinity = target_position.affinity,
                            }
                        else
                            canvas.TextSelection.collapsedAt(target_position) };
                    }
                    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) {
                        return .{ .move_caret = .{ .direction = .start, .extend = keyboard.modifiers.shift } };
                    }
                    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) {
                        return .{ .move_caret = .{ .direction = .end, .extend = keyboard.modifiers.shift } };
                    }
                }
            }

            // A soft-wrap boundary has two painted caret stops at one byte
            // offset. Plain horizontal movement crosses that visual seam
            // before advancing to another scalar: Right moves upstream ->
            // downstream, and Left moves downstream -> upstream. Shift
            // variants keep their ordinary byte-extending selection rule.
            if (widget.kind == .textarea and
                keyboard.phase == .key_down and
                keyboard.text.len == 0 and
                !keyboard.modifiers.shift and
                !keyboard.modifiers.hasNavigationModifier())
            {
                const moving_left = std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft");
                const moving_right = std.ascii.eqlIgnoreCase(keyboard.key, "arrowright");
                const selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
                if (!selection.isCollapsed(widget.text.len) and (moving_left or moving_right)) {
                    const range = selection.range(widget.text.len);
                    const target_offset = if (moving_left) range.start else range.end;
                    const target_position = if (moving_left)
                        canvasWidgetTextSelectionStartPosition(self, widget, target_offset)
                    else
                        canvas.TextCaretPosition{ .offset = target_offset, .affinity = .upstream };
                    return .{ .set_selection = canvas.TextSelection.collapsedAt(target_position) };
                }
                if (selection.isCollapsed(widget.text.len) and
                    ((moving_left and selection.affinity == .downstream) or
                        (moving_right and selection.affinity == .upstream)))
                {
                    var current_widget = widget;
                    current_widget.text_selection = canvas.TextSelection.collapsedAt(.{
                        .offset = selection.focus,
                        .affinity = selection.affinity,
                    });
                    const current_caret = canvas.textGeometryForWidget(current_widget, self.widget_tokens).caret_bounds orelse return null;
                    const next_affinity: canvas.TextCaretAffinity = if (moving_left) .upstream else .downstream;
                    var next_widget = widget;
                    next_widget.text_selection = canvas.TextSelection.collapsedAt(.{
                        .offset = selection.focus,
                        .affinity = next_affinity,
                    });
                    const next_caret = canvas.textGeometryForWidget(next_widget, self.widget_tokens).caret_bounds orelse return null;
                    const crosses_wrap = if (moving_left)
                        next_caret.y < current_caret.y
                    else
                        next_caret.y > current_caret.y;
                    if (crosses_wrap) {
                        return .{ .set_selection = canvas.TextSelection.collapsedAt(.{
                            .offset = selection.focus,
                            .affinity = next_affinity,
                        }) };
                    }
                }
                if (selection.isCollapsed(widget.text.len) and moving_left) {
                    var movement_scratch: [1]u8 = undefined;
                    const moved = (canvas.TextEditState{
                        .text = widget.text,
                        .selection = selection,
                        .composition = widget.text_composition,
                    }).apply(
                        .{ .move_caret = .{ .direction = .previous } },
                        &movement_scratch,
                    ) catch return null;
                    const target_position = canvasWidgetTextSelectionStartPosition(
                        self,
                        widget,
                        moved.selection.focus,
                    );
                    if (target_position.affinity == .downstream) {
                        return .{ .set_selection = canvas.TextSelection.collapsedAt(target_position) };
                    }
                }
            }

            // Plain Up/Down follows the textarea's PAINTED visual lines,
            // including soft wraps. Resolve the current caret rectangle
            // through the same streaming layout used to draw it, then
            // hit-test the neighboring line at the caret's x coordinate.
            // The explicit selection is stamped onto on-input, keeping a
            // controlled TextBuffer's selection byte-identical to the
            // retained editor.
            if (widget.kind == .textarea and
                keyboard.phase == .key_down and
                keyboard.text.len == 0 and
                !keyboard.modifiers.hasNavigationModifier())
            {
                const moving_up = std.ascii.eqlIgnoreCase(keyboard.key, "arrowup");
                const moving_down = std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown");
                if (moving_up or moving_down) {
                    const selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
                    const range = selection.range(widget.text.len);
                    const origin_position = if (!keyboard.modifiers.shift and !selection.isCollapsed(widget.text.len))
                        canvasWidgetTextSelectionStartPosition(self, widget, range.start)
                    else
                        canvas.TextCaretPosition{
                            .offset = selection.focus,
                            .affinity = selection.affinity,
                        };
                    var caret_widget = widget;
                    caret_widget.text_selection = canvas.TextSelection.collapsedAt(origin_position);
                    const caret = canvas.textGeometryForWidget(caret_widget, self.widget_tokens).caret_bounds orelse return null;
                    const vertical_witness_matches =
                        self.canvas_widget_text_vertical_goal_id == target.id and
                        self.canvas_widget_text_vertical_goal_text_len == widget.text.len and
                        self.canvas_widget_text_vertical_goal_focus == selection.focus and
                        self.canvas_widget_text_vertical_goal_affinity == selection.affinity and
                        self.canvas_widget_text_vertical_goal_frame.width == widget.frame.width and
                        self.canvas_widget_text_vertical_goal_frame.height == widget.frame.height;
                    const text_hash = textHistoryHash(widget.text);
                    const continues_vertical_navigation =
                        vertical_witness_matches and
                        self.canvas_widget_text_vertical_goal_text_hash == text_hash;
                    const goal_x = if (continues_vertical_navigation)
                        self.canvas_widget_text_vertical_goal_x
                    else
                        caret.x - widget.frame.x;
                    const target_y = if (moving_up)
                        caret.y - caret.height * 0.5
                    else
                        caret.y + caret.height * 1.5;
                    const target_position = canvas.textCaretPositionForWidgetPoint(
                        widget,
                        geometry.PointF.init(widget.frame.x + goal_x, target_y),
                        self.widget_tokens,
                    ) orelse return null;
                    self.canvas_widget_text_vertical_goal_id = target.id;
                    self.canvas_widget_text_vertical_goal_x = goal_x;
                    self.canvas_widget_text_vertical_goal_text_len = widget.text.len;
                    self.canvas_widget_text_vertical_goal_text_hash = text_hash;
                    self.canvas_widget_text_vertical_goal_focus = target_position.offset;
                    self.canvas_widget_text_vertical_goal_affinity = target_position.affinity;
                    self.canvas_widget_text_vertical_goal_frame = widget.frame;
                    return .{ .set_selection = if (keyboard.modifiers.shift)
                        .{
                            .anchor = selection.anchor,
                            .focus = target_position.offset,
                            .affinity = target_position.affinity,
                        }
                    else
                        canvas.TextSelection.collapsedAt(target_position) };
                }
            }

            // On a CLOSED combobox these same arrows are the trigger's
            // OPEN keys (`widgetKeyboardControlIntent`'s menu-open
            // mapping, which the app dispatch resolves BEFORE any
            // stamped edit): platform convention is that opening wins
            // and the caret does not move, so the derivation yields no
            // edit and the retained editor agrees with the model's "no
            // edit" verdict. The app-side fallback derivation for
            // events that never crossed the runtime
            // (`textEditEvent()`'s generic keymap) has no ArrowUp/Down
            // arm at all, so both derivations stay in agreement. Once
            // the picker is OPEN the focus step walks the arrows into
            // the mounted menu before routing reaches the trigger; an
            // arrow that still lands on an EXPANDED trigger (no
            // focusable menu entry mounted) keeps the caret jump — the
            // control resolver ignores it there, so both sides hear
            // the same move.
            const arrow_opens_combobox = widget.kind == .combobox and !(widget.state.expanded orelse false);
            if (!arrow_opens_combobox and canvasWidgetSingleLineTextKind(widget.kind) and keyboard.phase == .key_down and keyboard.text.len == 0 and !keyboard.modifiers.hasNavigationModifier()) {
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return .{ .move_caret = .{ .direction = .start, .extend = keyboard.modifiers.shift } };
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return .{ .move_caret = .{ .direction = .end, .extend = keyboard.modifiers.shift } };
            }

            return keyboard.textEditEvent();
        }

        /// Resolve Command/Ctrl+Z against the focused editor's delta
        /// history. The returned first edit and replay serial express one
        /// logical step as ordinary TextInputEvents so both the retained
        /// editor and a controlled app-side TextBuffer reach byte-identical
        /// text and selection.
        pub fn canvasWidgetTextHistoryShortcut(
            self: *RuntimeView,
            target: canvas.WidgetFocusTarget,
            keyboard: canvas.WidgetKeyboardEvent,
        ) ?CanvasWidgetTextHistoryShortcutResult {
            if (keyboard.phase != .key_down or
                !keyboard.modifiers.super or
                keyboard.modifiers.alt or
                !std.ascii.eqlIgnoreCase(keyboard.key, "z"))
            {
                return null;
            }
            const node_index = self.canvasWidgetNodeIndexById(target.id) orelse return null;
            const widget = self.widget_layout_nodes[node_index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled or widget.text_composition != null) return null;
            clearCanvasWidgetTextVerticalGoal(self);

            const redo = keyboard.modifiers.shift;
            const history_index = canvasWidgetTextHistoryIndex(self, target.id, widget.kind, redo) orelse return null;
            const entry = self.canvas_widget_text_history_entries[history_index];
            const expected_len = if (redo) entry.before_text_len else entry.after_text_len;
            const expected_hash = if (redo) entry.before_hash else entry.after_hash;
            if (widget.text.len != expected_len or textHistoryHash(widget.text) != expected_hash) {
                clearCanvasWidgetTextHistory(self, target.id);
                return null;
            }

            const removed = canvasWidgetTextHistoryRemoved(self, entry);
            const inserted = canvasWidgetTextHistoryInserted(self, entry);
            var output: [max_text_history_edits_per_shortcut]?canvas.TextInputEvent = .{ null, null, null };
            var edit_count: usize = 0;
            if (redo) {
                buildCanvasWidgetTextRedoEdits(entry, removed, inserted, widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len), &output, &edit_count);
            } else {
                buildCanvasWidgetTextUndoEdits(entry, removed, inserted, widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len), &output, &edit_count);
            }
            if (edit_count == 0) return null;
            return .{
                .edit = output[0].?,
                .serial = entry.serial,
                .redo = redo,
            };
        }

        /// Availability for native Edit-menu validation. A direction is
        /// exposed only when its nearest history boundary still matches the
        /// retained bytes; controlled source replacement can otherwise leave
        /// an entry mounted but stale until the next shortcut retires it.
        pub fn canvasWidgetTextHistoryAvailability(
            self: *const RuntimeView,
            target_id: canvas.ObjectId,
        ) CanvasWidgetTextHistoryAvailability {
            const node_index = self.canvasWidgetNodeIndexById(target_id) orelse return .{};
            const widget = self.widget_layout_nodes[node_index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or
                widget.state.disabled or
                widget.text_composition != null)
            {
                return .{};
            }

            const current_hash = textHistoryHash(widget.text);
            var availability: CanvasWidgetTextHistoryAvailability = .{};
            if (canvasWidgetTextHistoryIndex(self, target_id, widget.kind, false)) |history_index| {
                const entry = self.canvas_widget_text_history_entries[history_index];
                availability.can_undo = widget.text.len == entry.after_text_len and current_hash == entry.after_hash;
            }
            if (canvasWidgetTextHistoryIndex(self, target_id, widget.kind, true)) |history_index| {
                const entry = self.canvas_widget_text_history_entries[history_index];
                availability.can_redo = widget.text.len == entry.before_text_len and current_hash == entry.before_hash;
            }
            return availability;
        }

        /// Derive the next edit of a compound history replay from the
        /// retained entry's current location. The preceding edit may have
        /// rebuilt the controlled tree and compacted history bytes, so no
        /// borrowed payload survives across this call boundary.
        pub fn canvasWidgetTextHistoryReplayNext(
            self: *RuntimeView,
            target: canvas.WidgetFocusTarget,
            serial: u64,
            redo: bool,
        ) ?canvas.TextInputEvent {
            if (serial == 0 or self.canvas_widget_focused_id != target.id) {
                if (serial != 0) clearCanvasWidgetTextHistory(self, target.id);
                return null;
            }
            const node_index = self.canvasWidgetNodeIndexById(target.id) orelse return null;
            const widget = self.widget_layout_nodes[node_index].widget;
            if (widget.kind != target.kind or
                !self.canEditCanvasWidgetText(target.id) or
                widget.text_composition != null)
            {
                return null;
            }
            const history_index = canvasWidgetTextHistoryIndexForSerial(self, serial) orelse return null;
            const entry = self.canvas_widget_text_history_entries[history_index];
            if (entry.target_id != target.id or
                entry.target_kind != target.kind or
                entry.provisional_composition or
                entry.applied == redo)
            {
                return null;
            }

            const selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
            const current_hash = textHistoryHash(widget.text);
            const desired_len = if (redo) entry.after_text_len else entry.before_text_len;
            const desired_hash = if (redo) entry.after_hash else entry.before_hash;
            const desired_selection = if (redo) entry.after_selection else entry.before_selection;
            if (widget.text.len == desired_len and current_hash == desired_hash) {
                if (canvasTextSelectionsEqual(selection, desired_selection)) {
                    self.canvas_widget_text_history_entries[history_index].applied = redo;
                    return null;
                }
                return .{ .set_selection = desired_selection };
            }

            const source_len = if (redo) entry.before_text_len else entry.after_text_len;
            const source_hash = if (redo) entry.before_hash else entry.after_hash;
            if (widget.text.len != source_len or current_hash != source_hash) {
                clearCanvasWidgetTextHistory(self, target.id);
                return null;
            }

            const removed = canvasWidgetTextHistoryRemoved(self, entry);
            const inserted = canvasWidgetTextHistoryInserted(self, entry);
            var output: [max_text_history_edits_per_shortcut]?canvas.TextInputEvent = .{ null, null, null };
            var edit_count: usize = 0;
            if (redo) {
                buildCanvasWidgetTextRedoEdits(entry, removed, inserted, selection, &output, &edit_count);
            } else {
                buildCanvasWidgetTextUndoEdits(entry, removed, inserted, selection, &output, &edit_count);
            }
            return if (edit_count > 0) output[0] else null;
        }

        /// Commit a pending undo/redo direction only after one replay edit
        /// applied successfully and reached the entry's complete target
        /// state. A storage-budget refusal therefore leaves `applied`
        /// untouched, so the same shortcut remains available after capacity
        /// is freed. Compound replays call this after every select/replace/
        /// restore step; only the final one can satisfy all three witnesses.
        pub fn commitCanvasWidgetTextHistoryReplayIfComplete(
            self: *RuntimeView,
            target: canvas.WidgetFocusTarget,
            serial: u64,
            redo: bool,
        ) void {
            if (serial == 0) return;
            const node_index = self.canvasWidgetNodeIndexById(target.id) orelse return;
            const widget = self.widget_layout_nodes[node_index].widget;
            if (widget.kind != target.kind) return;
            const history_index = canvasWidgetTextHistoryIndexForSerial(self, serial) orelse return;
            const entry = self.canvas_widget_text_history_entries[history_index];
            if (entry.target_id != target.id or
                entry.target_kind != target.kind or
                entry.provisional_composition or
                entry.applied == redo)
            {
                return;
            }
            const desired_len = if (redo) entry.after_text_len else entry.before_text_len;
            const desired_hash = if (redo) entry.after_hash else entry.before_hash;
            const desired_selection = if (redo) entry.after_selection else entry.before_selection;
            const selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
            if (widget.text.len != desired_len or
                textHistoryHash(widget.text) != desired_hash or
                !canvasTextSelectionsEqual(selection, desired_selection))
            {
                return;
            }
            self.canvas_widget_text_history_entries[history_index].applied = redo;
        }

        fn recordCanvasWidgetTextHistory(
            self: *RuntimeView,
            target_id: canvas.ObjectId,
            target_kind: canvas.WidgetKind,
            before: canvas.TextEditState,
            after: canvas.TextEditState,
            provisional_composition: bool,
        ) bool {
            const before_hash = textHistoryHash(before.text);
            if (!canvasWidgetTextHistoryMatchesState(self, target_id, target_kind, before.text.len, before_hash)) {
                clearCanvasWidgetTextHistory(self, target_id);
            }

            // The composition range identifies the inserted side even when
            // the first preedit is empty (and the before/after text is
            // byte-identical). The removed side is the selection the IME
            // replaced when it opened.
            const before_selection = canvas.snapTextCaretSelection(before.text, before.selection);
            const delta = if (provisional_composition) blk: {
                const inserted = after.composition orelse return false;
                const removed = before_selection.range(before.text.len);
                var prefix_len = removed.start;
                var before_end = removed.end;
                var after_end = inserted.end;
                // A later preedit rewrite can complete a CRLF with either
                // adjacent delimiter even when the first preview did not.
                // Retain that shared context from the start so the committed
                // history replacement never addresses only half of the pair.
                if (prefix_len > 0 and before.text[prefix_len - 1] == '\r') {
                    prefix_len -= 1;
                }
                if (before_end < before.text.len and
                    after_end < after.text.len and
                    before.text[before_end] == '\n' and
                    after.text[after_end] == '\n')
                {
                    before_end += 1;
                    after_end += 1;
                }
                break :blk CanvasWidgetTextHistoryDelta{
                    .prefix_len = prefix_len,
                    .before_end = before_end,
                    .after_end = after_end,
                };
            } else canvasWidgetTextHistoryDelta(before.text, after.text);
            const removed_len = delta.before_end - delta.prefix_len;
            const inserted_len = delta.after_end - delta.prefix_len;
            const byte_len = removed_len + inserted_len;
            if (byte_len == 0 and !provisional_composition) return false;

            // A completed new edit forks this widget's history: only its
            // redo branch disappears; other editors in the same view keep
            // theirs. A provisional composition defers the fork until
            // commit, so canceling a no-op preedit preserves Redo too.
            if (!provisional_composition) {
                var cursor = self.canvas_widget_text_history_entry_count;
                while (cursor > 0) {
                    cursor -= 1;
                    const entry = self.canvas_widget_text_history_entries[cursor];
                    if (entry.target_id == target_id and !entry.applied) {
                        removeCanvasWidgetTextHistoryEntry(self, cursor);
                    }
                }
            }

            if (byte_len > self.canvas_widget_text_history_bytes.len) {
                clearCanvasWidgetTextHistory(self, target_id);
                return false;
            }
            while (self.canvas_widget_text_history_entry_count >= self.canvas_widget_text_history_entries.len or
                self.canvas_widget_text_history_byte_count + byte_len > self.canvas_widget_text_history_bytes.len)
            {
                if (self.canvas_widget_text_history_entry_count == 0) return false;
                removeCanvasWidgetTextHistoryEntry(self, 0);
            }

            const byte_start = self.canvas_widget_text_history_byte_count;
            const removed_end = byte_start + removed_len;
            const inserted_end = removed_end + inserted_len;
            @memcpy(
                self.canvas_widget_text_history_bytes[byte_start..removed_end],
                before.text[delta.prefix_len..delta.before_end],
            );
            @memcpy(
                self.canvas_widget_text_history_bytes[removed_end..inserted_end],
                after.text[delta.prefix_len..delta.after_end],
            );
            self.canvas_widget_text_history_byte_count = inserted_end;
            const after_hash = textHistoryHash(after.text);
            const serial = self.canvas_widget_text_history_next_serial;
            self.canvas_widget_text_history_next_serial +%= 1;
            if (self.canvas_widget_text_history_next_serial == 0) self.canvas_widget_text_history_next_serial = 1;
            self.canvas_widget_text_history_entries[self.canvas_widget_text_history_entry_count] = .{
                .serial = serial,
                .target_id = target_id,
                .target_kind = target_kind,
                .byte_start = byte_start,
                .removed_len = removed_len,
                .inserted_len = inserted_len,
                .prefix_len = delta.prefix_len,
                .before_text_len = before.text.len,
                .after_text_len = after.text.len,
                .before_hash = before_hash,
                .after_hash = after_hash,
                .before_selection = before_selection,
                .after_selection = after.selection,
                .provisional_composition = provisional_composition,
            };
            self.canvas_widget_text_history_entry_count += 1;
            return true;
        }

        /// A controlled source replacement can change the retained buffer
        /// without flowing through the text editor. Before a subsequent
        /// edit forks redo, verify that the applied history boundary still
        /// describes that buffer; otherwise retire only this widget's stale
        /// timeline and let the new edit begin a fresh one.
        fn canvasWidgetTextHistoryMatchesState(
            self: *const RuntimeView,
            target_id: canvas.ObjectId,
            target_kind: canvas.WidgetKind,
            text_len: usize,
            text_hash: u64,
        ) bool {
            var latest_applied: ?usize = null;
            for (self.canvas_widget_text_history_entries[0..self.canvas_widget_text_history_entry_count], 0..) |entry, index| {
                if (entry.target_id != target_id) continue;
                if (entry.target_kind != target_kind) return false;
                if (entry.provisional_composition) return false;
                if (entry.applied) latest_applied = index;
            }
            if (latest_applied) |index| {
                const entry = self.canvas_widget_text_history_entries[index];
                return text_len == entry.after_text_len and text_hash == entry.after_hash;
            }
            for (self.canvas_widget_text_history_entries[0..self.canvas_widget_text_history_entry_count]) |entry| {
                if (entry.target_id != target_id or entry.target_kind != target_kind or entry.provisional_composition or entry.applied) continue;
                return text_len == entry.before_text_len and text_hash == entry.before_hash;
            }
            return true;
        }

        /// Rewrite the inserted side of the active composition's single
        /// provisional entry. The original removed bytes stay untouched,
        /// so commit becomes one undo step and a no-op cancel simply drops
        /// the provisional entry while all older edits remain available.
        fn updateCanvasWidgetTextCompositionHistory(
            self: *RuntimeView,
            target_id: canvas.ObjectId,
            after: canvas.TextEditState,
        ) void {
            var provisional_index = canvasWidgetTextCompositionHistoryIndex(self, target_id) orelse return;
            var provisional = self.canvas_widget_text_history_entries[provisional_index];
            if (provisional.prefix_len + provisional.removed_len > provisional.before_text_len) {
                removeCanvasWidgetTextHistoryEntry(self, provisional_index);
                return;
            }
            const suffix_len = provisional.before_text_len - provisional.prefix_len - provisional.removed_len;
            if (after.text.len < provisional.prefix_len + suffix_len) {
                removeCanvasWidgetTextHistoryEntry(self, provisional_index);
                return;
            }
            const after_end = after.text.len - suffix_len;
            const inserted = after.text[provisional.prefix_len..after_end];
            const new_inserted_len = inserted.len;
            const new_entry_byte_len = provisional.removed_len + new_inserted_len;
            if (new_entry_byte_len > self.canvas_widget_text_history_bytes.len) {
                removeCanvasWidgetTextHistoryEntry(self, provisional_index);
                return;
            }

            while (self.canvas_widget_text_history_byte_count - provisional.inserted_len + new_inserted_len >
                self.canvas_widget_text_history_bytes.len)
            {
                if (provisional_index == 0) {
                    removeCanvasWidgetTextHistoryEntry(self, provisional_index);
                    return;
                }
                removeCanvasWidgetTextHistoryEntry(self, 0);
                provisional_index = canvasWidgetTextCompositionHistoryIndex(self, target_id) orelse return;
                provisional = self.canvas_widget_text_history_entries[provisional_index];
            }

            const inserted_start = provisional.byte_start + provisional.removed_len;
            const old_tail_start = inserted_start + provisional.inserted_len;
            const old_byte_count = self.canvas_widget_text_history_byte_count;
            if (new_inserted_len > provisional.inserted_len) {
                const growth = new_inserted_len - provisional.inserted_len;
                std.mem.copyBackwards(
                    u8,
                    self.canvas_widget_text_history_bytes[old_tail_start + growth .. old_byte_count + growth],
                    self.canvas_widget_text_history_bytes[old_tail_start..old_byte_count],
                );
                for (self.canvas_widget_text_history_entries[provisional_index + 1 .. self.canvas_widget_text_history_entry_count]) |*entry| {
                    entry.byte_start += growth;
                }
                self.canvas_widget_text_history_byte_count += growth;
            } else if (new_inserted_len < provisional.inserted_len) {
                const shrink = provisional.inserted_len - new_inserted_len;
                std.mem.copyForwards(
                    u8,
                    self.canvas_widget_text_history_bytes[old_tail_start - shrink .. old_byte_count - shrink],
                    self.canvas_widget_text_history_bytes[old_tail_start..old_byte_count],
                );
                for (self.canvas_widget_text_history_entries[provisional_index + 1 .. self.canvas_widget_text_history_entry_count]) |*entry| {
                    entry.byte_start -= shrink;
                }
                self.canvas_widget_text_history_byte_count -= shrink;
            }
            @memcpy(
                self.canvas_widget_text_history_bytes[inserted_start .. inserted_start + new_inserted_len],
                inserted,
            );

            const after_hash = textHistoryHash(after.text);
            self.canvas_widget_text_history_entries[provisional_index].inserted_len = new_inserted_len;
            self.canvas_widget_text_history_entries[provisional_index].after_text_len = after.text.len;
            self.canvas_widget_text_history_entries[provisional_index].after_hash = after_hash;
            self.canvas_widget_text_history_entries[provisional_index].after_selection = after.selection;
            if (after.composition != null) return;
            if (after.text.len == provisional.before_text_len and after_hash == provisional.before_hash) {
                removeCanvasWidgetTextHistoryEntry(self, provisional_index);
                return;
            }

            // The composition committed a net edit, so it now forks Redo.
            // Remove that branch before exposing the provisional entry to
            // shortcut lookup; compaction can move the entry, hence refind.
            var cursor = self.canvas_widget_text_history_entry_count;
            while (cursor > 0) {
                cursor -= 1;
                const entry = self.canvas_widget_text_history_entries[cursor];
                if (entry.target_id == target_id and !entry.applied) {
                    removeCanvasWidgetTextHistoryEntry(self, cursor);
                }
            }
            provisional_index = canvasWidgetTextCompositionHistoryIndex(self, target_id) orelse return;
            self.canvas_widget_text_history_entries[provisional_index].provisional_composition = false;
        }

        fn canvasWidgetTextCompositionHistoryIndex(self: *const RuntimeView, target_id: canvas.ObjectId) ?usize {
            var index = self.canvas_widget_text_history_entry_count;
            while (index > 0) {
                index -= 1;
                const entry = self.canvas_widget_text_history_entries[index];
                if (entry.target_id == target_id and entry.provisional_composition) return index;
            }
            return null;
        }

        fn canvasWidgetTextHistoryIndex(self: *const RuntimeView, target_id: canvas.ObjectId, target_kind: canvas.WidgetKind, redo: bool) ?usize {
            if (redo) {
                for (self.canvas_widget_text_history_entries[0..self.canvas_widget_text_history_entry_count], 0..) |entry, index| {
                    if (entry.target_id == target_id and entry.target_kind == target_kind and !entry.applied and !entry.provisional_composition) return index;
                }
                return null;
            }
            var index = self.canvas_widget_text_history_entry_count;
            while (index > 0) {
                index -= 1;
                const entry = self.canvas_widget_text_history_entries[index];
                if (entry.target_id == target_id and entry.target_kind == target_kind and entry.applied and !entry.provisional_composition) return index;
            }
            return null;
        }

        fn canvasWidgetTextHistoryIndexForSerial(self: *const RuntimeView, serial: u64) ?usize {
            for (self.canvas_widget_text_history_entries[0..self.canvas_widget_text_history_entry_count], 0..) |entry, index| {
                if (entry.serial == serial) return index;
            }
            return null;
        }

        fn canvasWidgetTextHistoryRemoved(self: *const RuntimeView, entry: CanvasWidgetTextHistoryEntry) []const u8 {
            return self.canvas_widget_text_history_bytes[entry.byte_start .. entry.byte_start + entry.removed_len];
        }

        fn canvasWidgetTextHistoryInserted(self: *const RuntimeView, entry: CanvasWidgetTextHistoryEntry) []const u8 {
            const start = entry.byte_start + entry.removed_len;
            return self.canvas_widget_text_history_bytes[start .. start + entry.inserted_len];
        }

        fn clearCanvasWidgetTextHistory(self: *RuntimeView, target_id: canvas.ObjectId) void {
            var index = self.canvas_widget_text_history_entry_count;
            while (index > 0) {
                index -= 1;
                if (self.canvas_widget_text_history_entries[index].target_id == target_id) {
                    removeCanvasWidgetTextHistoryEntry(self, index);
                }
            }
        }

        /// History belongs to one mounted editor incarnation. Widget ids are
        /// stable structural handles, but an id can disappear or return as a
        /// different kind across rebuilds; neither case may inherit edits
        /// from the retired control.
        pub fn pruneCanvasWidgetTextHistory(self: *RuntimeView) void {
            var index = self.canvas_widget_text_history_entry_count;
            while (index > 0) {
                index -= 1;
                const entry = self.canvas_widget_text_history_entries[index];
                const node_index = self.canvasWidgetNodeIndexById(entry.target_id) orelse {
                    removeCanvasWidgetTextHistoryEntry(self, index);
                    continue;
                };
                const widget = self.widget_layout_nodes[node_index].widget;
                if (widget.kind != entry.target_kind or !canvasWidgetEditableTextKind(widget.kind)) {
                    removeCanvasWidgetTextHistoryEntry(self, index);
                }
            }
            if (self.canvas_widget_text_vertical_goal_id != 0) {
                const node_index = self.canvasWidgetNodeIndexById(self.canvas_widget_text_vertical_goal_id) orelse {
                    clearCanvasWidgetTextVerticalGoal(self);
                    return;
                };
                if (self.widget_layout_nodes[node_index].widget.kind != .textarea) {
                    clearCanvasWidgetTextVerticalGoal(self);
                }
            }
        }

        fn removeCanvasWidgetTextHistoryEntry(self: *RuntimeView, remove_index: usize) void {
            if (remove_index >= self.canvas_widget_text_history_entry_count) return;
            var write_byte: usize = 0;
            var write_entry: usize = 0;
            for (self.canvas_widget_text_history_entries[0..self.canvas_widget_text_history_entry_count], 0..) |entry, index| {
                if (index == remove_index) continue;
                const entry_byte_len = entry.removed_len + entry.inserted_len;
                const source = self.canvas_widget_text_history_bytes[entry.byte_start .. entry.byte_start + entry_byte_len];
                if (write_byte != entry.byte_start) {
                    std.mem.copyForwards(
                        u8,
                        self.canvas_widget_text_history_bytes[write_byte .. write_byte + entry_byte_len],
                        source,
                    );
                }
                var moved = entry;
                moved.byte_start = write_byte;
                self.canvas_widget_text_history_entries[write_entry] = moved;
                write_byte += entry_byte_len;
                write_entry += 1;
            }
            self.canvas_widget_text_history_entry_count = write_entry;
            self.canvas_widget_text_history_byte_count = write_byte;
        }

        pub fn clearCanvasWidgetTextVerticalGoal(self: *RuntimeView) void {
            self.canvas_widget_text_vertical_goal_id = 0;
            self.canvas_widget_text_vertical_goal_x = 0;
            self.canvas_widget_text_vertical_goal_text_len = 0;
            self.canvas_widget_text_vertical_goal_text_hash = 0;
            self.canvas_widget_text_vertical_goal_focus = 0;
            self.canvas_widget_text_vertical_goal_affinity = .upstream;
            self.canvas_widget_text_vertical_goal_frame = .{};
        }

        pub fn canEditCanvasWidgetText(self: *const RuntimeView, id: canvas.ObjectId) bool {
            const index = self.canvasWidgetNodeIndexById(id) orelse return false;
            const layout = self.widgetLayoutTree();
            if (canvasWidgetLayoutNodeHidden(layout, index)) return false;
            if (!canvasWidgetLayoutNodeFrameVisible(layout, index)) return false;
            const widget = self.widget_layout_nodes[index].widget;
            return canvasWidgetEditableTextKind(widget.kind) and !widget.state.disabled;
        }

        pub fn applyCanvasWidgetTextPointer(
            self: *RuntimeView,
            target_id: canvas.ObjectId,
            point: geometry.PointF,
            dragging: bool,
            shift_extend: bool,
            click_count: u8,
        ) anyerror!?geometry.RectF {
            clearCanvasWidgetTextVerticalGoal(self);
            const index = self.canvasWidgetNodeIndexById(target_id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.state.disabled) return null;
            if (canvas.widgetStaticTextSelectable(widget)) {
                return applyCanvasWidgetStaticTextPointer(self, index, target_id, point, dragging);
            }
            if (!canvasWidgetEditableTextKind(widget.kind)) return null;

            const current_selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
            const next_selection = canvasWidgetEditableTextPointerSelection(
                self,
                widget,
                point,
                dragging,
                shift_extend,
                click_count,
                current_selection,
            ) orelse return null;
            // A widget with NO stored selection must store one even when
            // it matches the implied default: the emitters draw a caret
            // only for a present selection, so short-circuiting here left
            // a click into an empty field (or past the end of the text)
            // caretless.
            if (widget.text_selection != null and canvasTextSelectionsEqual(current_selection, next_selection) and widget.text_composition == null) return null;

            self.widget_layout_nodes[index].widget.text_selection = next_selection;
            self.widget_layout_nodes[index].widget.text_composition = null;
            if (widget.text_composition != null) {
                updateCanvasWidgetTextCompositionHistory(self, target_id, .{
                    .text = widget.text,
                    .selection = next_selection,
                    .composition = null,
                });
            }
            // A pointer-placed caret is a caret change like any other: a
            // drag past a scrolled single-line field's edge lands on an
            // off-screen offset, and the field follows it.
            if (canvasWidgetSingleLineTextKind(widget.kind)) self.scrollCanvasTextInputCaretIntoView(index);
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, widget.frame);
        }

        /// The selection a pointer event produces in an editable text
        /// widget, by click count. Count 1 is the classic gesture:
        /// press places the caret, drag extends per-character from the
        /// press anchor. Counts 2 and 3 are the multi-click family —
        /// the down selects a whole RUN (the word/whitespace/
        /// punctuation cluster under the pointer, or the line/whole
        /// text for a triple), remembers it as the gesture's anchor
        /// run, and the drag unions the run under the pointer with
        /// that anchor, so extension works in both directions and the
        /// anchor word is never lost. Everything lands in the same
        /// `text_selection` state the keyboard, clipboard, and
        /// renderer already consume — no parallel selection model.
        fn canvasWidgetEditableTextPointerSelection(
            self: *RuntimeView,
            widget: canvas.Widget,
            point: geometry.PointF,
            dragging: bool,
            shift_extend: bool,
            click_count: u8,
            current_selection: canvas.TextSelection,
        ) ?canvas.TextSelection {
            if (click_count >= 2) {
                const offset = canvas.textOffsetForWidgetPoint(widget, point, self.widget_tokens) orelse return null;
                const unit = canvasWidgetMultiClickUnitSelection(widget, offset, click_count);
                if (shift_extend) {
                    // Shift+double/triple-click starts a fresh unit-wise
                    // extension from the standing selection anchor. It is
                    // not a drag continuation: the old multi-click anchor
                    // may belong to an unrelated gesture or widget.
                    const anchor_unit = canvasWidgetMultiClickUnitSelection(
                        widget,
                        current_selection.anchor,
                        click_count,
                    ).range(widget.text.len);
                    self.canvas_widget_multi_click_anchor = anchor_unit;
                    return canvasWidgetMultiClickDragSelection(anchor_unit, unit, widget.text.len);
                }
                if (!dragging) {
                    self.canvas_widget_multi_click_anchor = unit.range(widget.text.len);
                    return unit;
                }
                return canvasWidgetMultiClickDragSelection(self.canvas_widget_multi_click_anchor, unit, widget.text.len);
            }
            const anchor: ?usize = if (dragging or shift_extend) current_selection.anchor else null;
            return canvas.textSelectionForWidgetPoint(widget, point, anchor, self.widget_tokens);
        }

        /// The run one multi-click selects at `offset`. Triple-click
        /// pins the platform convention: single-line kinds (input,
        /// text field, search field, combobox) select the entire text;
        /// a textarea selects the clicked hard-newline line. Double
        /// selects the word/whitespace/punctuation run — the same
        /// boundaries the caret's word-jump uses.
        fn canvasWidgetMultiClickUnitSelection(widget: canvas.Widget, offset: usize, click_count: u8) canvas.TextSelection {
            if (click_count >= 3) {
                if (canvasWidgetSingleLineTextKind(widget.kind)) return .{ .anchor = 0, .focus = widget.text.len };
                return canvas.textLineSelectionAtOffset(widget.text, offset);
            }
            return canvas.textWordSelectionAtOffset(widget.text, offset);
        }

        /// Union the run under the drag pointer with the gesture's
        /// anchor run, oriented so the selection FOCUS sits at the
        /// dragged edge (a shift-arrow after the drag keeps extending
        /// from where the pointer stopped): dragging before the anchor
        /// run anchors at its end, dragging past it anchors at its
        /// start, and a pointer back inside the anchor run restores
        /// exactly the anchor run.
        fn canvasWidgetMultiClickDragSelection(anchor: canvas.TextRange, unit: canvas.TextSelection, text_len: usize) canvas.TextSelection {
            const anchor_range = anchor.normalized(text_len);
            const unit_range = unit.range(text_len);
            if (unit_range.start < anchor_range.start) {
                return .{ .anchor = anchor_range.end, .focus = unit_range.start };
            }
            if (unit_range.end > anchor_range.end) {
                return .{ .anchor = anchor_range.start, .focus = unit_range.end };
            }
            return .{ .anchor = anchor_range.start, .focus = anchor_range.end };
        }

        /// Click-drag selection inside one static `.text` widget. Press
        /// collapses at the hit offset, drag extends from the press
        /// anchor. Ordinary widgets remain independently selectable;
        /// bounded code paragraphs opt into one ordered source group.
        fn applyCanvasWidgetStaticTextPointer(self: *RuntimeView, index: usize, target_id: canvas.ObjectId, point: geometry.PointF, extend: bool) anyerror!?geometry.RectF {
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.static_text_group_id != 0) {
                return applyCanvasWidgetStaticTextGroupPointer(
                    self,
                    target_id,
                    point,
                    extend,
                    widget.static_text_group_id,
                );
            }
            if (extend and self.canvas_widget_selected_text_id != target_id) return null;
            const current_selection = widget.text_selection orelse canvas.TextSelection.collapsed(0);
            const anchor: ?usize = if (extend) current_selection.anchor else null;
            const next_selection = canvas.staticTextSelectionForWidgetPoint(widget, point, anchor, self.widget_tokens) orelse return null;
            if (self.canvas_widget_selected_text_id == target_id and widget.text_selection != null and canvasTextSelectionsEqual(current_selection, next_selection)) return null;

            self.widget_layout_nodes[index].widget.text_selection = next_selection;
            self.canvas_widget_selected_text_id = target_id;
            self.canvas_widget_selected_text_group_id = 0;
            self.canvas_widget_selected_text_group_anchor = 0;
            self.canvas_widget_selected_text_group_focus = 0;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, widget.frame);
        }

        fn applyCanvasWidgetStaticTextGroupPointer(
            self: *RuntimeView,
            target_id: canvas.ObjectId,
            point: geometry.PointF,
            extend: bool,
            group_id: canvas.ObjectId,
        ) anyerror!?geometry.RectF {
            if (extend and
                (self.canvas_widget_selected_text_id != target_id or
                    self.canvas_widget_selected_text_group_id != group_id))
            {
                return null;
            }

            var point_index: ?usize = null;
            var point_offset: usize = 0;
            var best_distance = std.math.inf(f32);
            const layout = self.widgetLayoutTree();
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, candidate_index| {
                const candidate = node.widget;
                if (candidate.static_text_group_id != group_id or
                    canvasWidgetLayoutNodeHidden(layout, candidate_index) or
                    !canvas.widgetStaticTextSelectable(candidate))
                {
                    continue;
                }
                const frame = candidate.frame.normalized();
                const dx = if (point.x < frame.x)
                    frame.x - point.x
                else if (point.x > frame.maxX())
                    point.x - frame.maxX()
                else
                    0;
                const dy = if (point.y < frame.y)
                    frame.y - point.y
                else if (point.y > frame.maxY())
                    point.y - frame.maxY()
                else
                    0;
                const distance = dx * dx + dy * dy;
                if (distance > best_distance) continue;
                const local = canvas.staticTextSelectionForWidgetPoint(
                    candidate,
                    point,
                    null,
                    self.widget_tokens,
                ) orelse continue;
                if (distance == best_distance and point_index != null) continue;
                best_distance = distance;
                point_index = candidate_index;
                point_offset = local.focus;
            }
            const selected_index = point_index orelse return null;
            const selected_widget = self.widget_layout_nodes[selected_index].widget;
            const focus = selected_widget.static_text_group_offset + point_offset;
            const anchor = if (extend)
                self.canvas_widget_selected_text_group_anchor
            else
                focus;
            const selection_start = @min(anchor, focus);
            const selection_end = @max(anchor, focus);

            var dirty: ?geometry.RectF = null;
            var changed = false;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |*node, candidate_index| {
                const candidate = node.widget;
                if (candidate.static_text_group_id != group_id) {
                    continue;
                }
                const source_start = candidate.static_text_group_offset;
                const source_end = source_start +| candidate.text.len;
                const next_selection: ?canvas.TextSelection = if (selection_start == selection_end)
                    if (candidate_index == selected_index)
                        canvas.TextSelection.collapsed(point_offset)
                    else
                        null
                else if (@max(selection_start, source_start) < @min(selection_end, source_end))
                    .{
                        .anchor = @max(selection_start, source_start) - source_start,
                        .focus = @min(selection_end, source_end) - source_start,
                    }
                else
                    null;
                const current_selection = candidate.text_selection;
                const same = if (current_selection) |current|
                    if (next_selection) |next|
                        canvasTextSelectionsEqual(current, next)
                    else
                        false
                else
                    next_selection == null;
                if (same) continue;
                node.widget.text_selection = next_selection;
                changed = true;
                dirty = unionRects(
                    dirty,
                    self.canvasWidgetDirtyBounds(candidate_index, candidate.frame),
                );
            }
            if (!changed and
                self.canvas_widget_selected_text_id == target_id and
                self.canvas_widget_selected_text_group_anchor == anchor and
                self.canvas_widget_selected_text_group_focus == focus)
            {
                return null;
            }

            self.canvas_widget_selected_text_id = target_id;
            self.canvas_widget_selected_text_group_id = group_id;
            self.canvas_widget_selected_text_group_anchor = anchor;
            self.canvas_widget_selected_text_group_focus = focus;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return dirty;
        }

        /// Drop the view's static text selection (pointer pressed
        /// elsewhere, or the copy source went away). Returns the dirty
        /// bounds of the widget that lost its highlight.
        pub fn clearCanvasWidgetStaticTextSelection(self: *RuntimeView) anyerror!?geometry.RectF {
            const id = self.canvas_widget_selected_text_id;
            if (id == 0) return null;
            self.canvas_widget_selected_text_id = 0;
            const group_id = self.canvas_widget_selected_text_group_id;
            self.canvas_widget_selected_text_group_id = 0;
            self.canvas_widget_selected_text_group_anchor = 0;
            self.canvas_widget_selected_text_group_focus = 0;
            if (group_id != 0) {
                var dirty: ?geometry.RectF = null;
                var changed = false;
                for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |*node, index| {
                    if (node.widget.static_text_group_id != group_id or
                        node.widget.text_selection == null)
                    {
                        continue;
                    }
                    node.widget.text_selection = null;
                    changed = true;
                    dirty = unionRects(
                        dirty,
                        self.canvasWidgetDirtyBounds(index, node.widget.frame),
                    );
                }
                if (!changed) return null;
                try self.refreshCanvasWidgetSemantics();
                self.widget_revision += 1;
                return dirty;
            }
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            if (self.widget_layout_nodes[index].widget.text_selection == null) return null;
            self.widget_layout_nodes[index].widget.text_selection = null;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, self.widget_layout_nodes[index].frame);
        }

        /// The text a copy shortcut should place on the clipboard: the
        /// focused editable widget's selection or focused terminal's
        /// emulator selection when it has one, else the view's static
        /// text selection.
        pub fn canvasWidgetCopyText(self: *const RuntimeView, group_buffer: []u8) ?[]const u8 {
            if (self.canvas_widget_focused_id != 0) {
                if (self.canvasWidgetNodeIndexById(self.canvas_widget_focused_id)) |index| {
                    const focused = self.widget_layout_nodes[index].widget;
                    if (!focused.state.disabled and focused.kind == .terminal) {
                        if (focused.terminal.grid) |grid| {
                            if (grid.selection_active) return grid.selection_text;
                        }
                    }
                }
                if (canvasWidgetSelectionSliceById(self, self.canvas_widget_focused_id, true)) |slice| return slice;
            }
            if (self.canvas_widget_selected_text_id != 0) {
                if (self.canvas_widget_selected_text_group_id != 0) {
                    return canvasWidgetStaticTextGroupCopy(self, group_buffer);
                }
                if (canvasWidgetSelectionSliceById(self, self.canvas_widget_selected_text_id, false)) |slice| return slice;
            }
            return null;
        }

        fn canvasWidgetStaticTextGroupCopy(self: *const RuntimeView, output: []u8) ?[]const u8 {
            const group_id = self.canvas_widget_selected_text_group_id;
            if (group_id == 0) return null;
            const start = @min(
                self.canvas_widget_selected_text_group_anchor,
                self.canvas_widget_selected_text_group_focus,
            );
            const end = @max(
                self.canvas_widget_selected_text_group_anchor,
                self.canvas_widget_selected_text_group_focus,
            );
            if (start >= end or end - start > output.len) return null;
            var copied: usize = 0;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count]) |node| {
                const widget = node.widget;
                if (widget.static_text_group_id != group_id) {
                    continue;
                }
                const source_start = widget.static_text_group_offset;
                const source_end = source_start +| widget.text.len;
                const copy_start = @max(start, source_start);
                const copy_end = @min(end, source_end);
                if (copy_start >= copy_end) continue;
                const destination_start = copy_start - start;
                const len = copy_end - copy_start;
                @memcpy(
                    output[destination_start..][0..len],
                    widget.text[copy_start - source_start ..][0..len],
                );
                copied += len;
            }
            if (copied != end - start) return null;
            return output[0 .. end - start];
        }

        fn canvasWidgetSelectionSliceById(self: *const RuntimeView, id: canvas.ObjectId, editable_only: bool) ?[]const u8 {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.state.disabled) return null;
            if (editable_only and !canvasWidgetEditableTextKind(widget.kind)) return null;
            const range = canvas.widgetTextSelectionRange(widget) orelse return null;
            if (range.isCollapsed(widget.text.len)) return null;
            return widget.text[range.start..range.end];
        }

        pub fn rewriteCanvasWidgetTextStorage(self: *RuntimeView, edited_index: usize, next_state: canvas.TextEditState) anyerror!void {
            try validateCanvasWidgetTextStorageRewrite(self, edited_index, next_state);
            const text_changed = !std.mem.eql(
                u8,
                self.widget_layout_nodes[edited_index].widget.text,
                next_state.text,
            );
            const scratch = canvas_widget_text_edit_scratch.get();
            var temp_len: usize = 0;

            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                const text = if (index == edited_index) next_state.text else node.widget.text;
                scratch.text_ranges[index] = try appendWidgetTextStorageRange(&scratch.rewrite_buffer, &temp_len, text);
                scratch.label_ranges[index] = try appendWidgetTextStorageRange(&scratch.rewrite_buffer, &temp_len, node.widget.semantics.label);
                scratch.command_ranges[index] = try appendWidgetTextStorageRange(&scratch.rewrite_buffer, &temp_len, node.widget.command);
            }

            @memcpy(self.widget_text_bytes[0..temp_len], scratch.rewrite_buffer[0..temp_len]);
            self.widget_text_len = temp_len;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |*node, index| {
                const text_range = scratch.text_ranges[index];
                const label_range = scratch.label_ranges[index];
                const command_range = scratch.command_ranges[index];
                node.widget.text = self.widget_text_bytes[text_range.start..text_range.end];
                node.widget.semantics.label = self.widget_text_bytes[label_range.start..label_range.end];
                node.widget.command = self.widget_text_bytes[command_range.start..command_range.end];
            }
            self.widget_layout_nodes[edited_index].widget.text_selection = next_state.selection;
            self.widget_layout_nodes[edited_index].widget.text_composition = next_state.composition;
            if (text_changed) {
                self.widget_layout_nodes[edited_index].widget.code_content_width_generation = 0;
                canvas.cacheTextInputContentWidthForWidget(
                    &self.widget_layout_nodes[edited_index].widget,
                    self.widget_tokens,
                );
            }
        }

        /// Prove a retained text rewrite fits before any editor history is
        /// forked, evicted, or cleared. The immediately following rewrite
        /// charges these exact three slices for every retained node.
        fn validateCanvasWidgetTextStorageRewrite(self: *const RuntimeView, edited_index: usize, next_state: canvas.TextEditState) anyerror!void {
            var required_len: usize = 0;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                const text = if (index == edited_index) next_state.text else node.widget.text;
                const values = [_][]const u8{
                    text,
                    node.widget.semantics.label,
                    node.widget.command,
                };
                for (values) |value| {
                    if (value.len > self.widget_text_bytes.len - required_len) return error.WidgetTextTooLarge;
                    required_len += value.len;
                }
            }
        }

        pub fn setCanvasWidgetTextValue(self: *RuntimeView, id: canvas.ObjectId, text: []const u8) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;
            if (std.mem.eql(u8, widget.text, text) and widget.text_composition == null and textSelectionCollapsedAt(widget.text_selection, text.len)) return null;

            const next_state = canvas.TextEditState{
                .text = text,
                .selection = canvas.TextSelection.collapsed(text.len),
                .composition = null,
            };
            try validateCanvasWidgetTextStorageRewrite(self, index, next_state);
            clearCanvasWidgetTextVerticalGoal(self);
            clearCanvasWidgetTextHistory(self, id);
            try self.rewriteCanvasWidgetTextStorage(index, next_state);
            self.scrollCanvasTextInputCaretIntoView(index);
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, self.widget_layout_nodes[index].frame);
        }
    };
}

const CanvasWidgetTextHistoryDelta = struct {
    prefix_len: usize,
    before_end: usize,
    after_end: usize,
};

fn canvasWidgetTextHistoryDelta(before: []const u8, after: []const u8) CanvasWidgetTextHistoryDelta {
    var prefix_len: usize = 0;
    const shared_len = @min(before.len, after.len);
    while (prefix_len < shared_len and before[prefix_len] == after[prefix_len]) prefix_len += 1;
    prefix_len = @min(
        canvas.snapTextCaretPosition(before, .{ .offset = prefix_len }).offset,
        canvas.snapTextCaretPosition(after, .{ .offset = prefix_len }).offset,
    );

    var suffix_len: usize = 0;
    while (suffix_len < before.len - prefix_len and
        suffix_len < after.len - prefix_len and
        before[before.len - suffix_len - 1] == after[after.len - suffix_len - 1])
    {
        suffix_len += 1;
    }
    // A common byte suffix can begin inside a shared UTF-8 sequence when
    // two codepoints share continuation bytes, or between the CR and LF
    // when this edit completed a CRLF. Shrink it until both replacement
    // ends are caret-safe boundaries.
    while (suffix_len > 0) {
        const before_end = before.len - suffix_len;
        const after_end = after.len - suffix_len;
        if (canvas.snapTextCaretPosition(before, .{ .offset = before_end }).offset == before_end and
            canvas.snapTextCaretPosition(after, .{ .offset = after_end }).offset == after_end)
        {
            break;
        }
        suffix_len -= 1;
    }
    return .{
        .prefix_len = prefix_len,
        .before_end = before.len - suffix_len,
        .after_end = after.len - suffix_len,
    };
}

fn textHistoryHash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

fn historySelectionCollapsedAt(selection: canvas.TextSelection, offset: usize) bool {
    return selection.anchor == offset and selection.focus == offset;
}

fn historySingleCodepoint(text: []const u8) bool {
    return text.len > 0 and canvas.snapTextOffset(text, text.len - 1) == 0;
}

fn appendCanvasWidgetTextHistoryEdit(
    output: *[max_text_history_edits_per_shortcut]?canvas.TextInputEvent,
    count: *usize,
    edit: canvas.TextInputEvent,
) void {
    if (count.* >= output.len) return;
    output[count.*] = edit;
    count.* += 1;
}

fn buildCanvasWidgetTextUndoEdits(
    entry: CanvasWidgetTextHistoryEntry,
    removed: []const u8,
    inserted: []const u8,
    current_selection: canvas.TextSelection,
    output: *[max_text_history_edits_per_shortcut]?canvas.TextInputEvent,
    count: *usize,
) void {
    const prefix = entry.prefix_len;
    if (removed.len == 0 and
        historySingleCodepoint(inserted) and
        historySelectionCollapsedAt(current_selection, prefix + inserted.len) and
        canvasTextSelectionsEqual(entry.before_selection, canvas.TextSelection.collapsed(prefix)))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .delete_backward);
        return;
    }
    if (inserted.len == 0 and
        historySelectionCollapsedAt(current_selection, prefix) and
        canvasTextSelectionsEqual(entry.before_selection, canvas.TextSelection.collapsed(prefix + removed.len)))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .insert_text = removed });
        return;
    }

    const replacement_selection = canvas.TextSelection{ .anchor = prefix, .focus = prefix + inserted.len };
    if (!canvasTextSelectionsEqual(current_selection, replacement_selection)) {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .set_selection = replacement_selection });
    }
    appendCanvasWidgetTextHistoryEdit(output, count, .{ .insert_text = removed });
    const insertion_selection = canvas.TextSelection.collapsed(prefix + removed.len);
    if (!canvasTextSelectionsEqual(insertion_selection, entry.before_selection)) {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .set_selection = entry.before_selection });
    }
}

fn buildCanvasWidgetTextRedoEdits(
    entry: CanvasWidgetTextHistoryEntry,
    removed: []const u8,
    inserted: []const u8,
    current_selection: canvas.TextSelection,
    output: *[max_text_history_edits_per_shortcut]?canvas.TextInputEvent,
    count: *usize,
) void {
    const prefix = entry.prefix_len;
    if (removed.len == 0 and
        historySelectionCollapsedAt(current_selection, prefix) and
        canvasTextSelectionsEqual(entry.after_selection, canvas.TextSelection.collapsed(prefix + inserted.len)))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .insert_text = inserted });
        return;
    }
    if (historySingleCodepoint(removed) and
        inserted.len == 0 and
        historySelectionCollapsedAt(current_selection, prefix + removed.len) and
        canvasTextSelectionsEqual(entry.after_selection, canvas.TextSelection.collapsed(prefix)))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .delete_backward);
        return;
    }
    if (historySingleCodepoint(removed) and
        inserted.len == 0 and
        historySelectionCollapsedAt(current_selection, prefix) and
        canvasTextSelectionsEqual(entry.after_selection, canvas.TextSelection.collapsed(prefix)))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .delete_forward);
        return;
    }

    const replacement_selection = canvas.TextSelection{ .anchor = prefix, .focus = prefix + removed.len };
    if (!canvasTextSelectionsEqual(current_selection, replacement_selection)) {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .set_selection = replacement_selection });
    }
    appendCanvasWidgetTextHistoryEdit(output, count, .{ .insert_text = inserted });
    const insertion_selection = canvas.TextSelection.collapsed(prefix + inserted.len);
    if (!canvasTextSelectionsEqual(insertion_selection, entry.after_selection)) {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .set_selection = entry.after_selection });
    }
}
