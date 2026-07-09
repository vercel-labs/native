const std = @import("std");
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

pub fn RuntimeViewCanvasWidgetText(comptime RuntimeView: type) type {
    return struct {
        pub fn applyCanvasWidgetTextEdit(self: *RuntimeView, target_id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(target_id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;

            const previous_bounds = widget.frame;
            var edit_buffer: [max_canvas_widget_text_bytes_per_view]u8 = undefined;
            const current_state = canvas.TextEditState{
                .text = widget.text,
                .selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len),
                .composition = widget.text_composition,
            };
            const next_state = try current_state.apply(edit, &edit_buffer);
            if (canvasWidgetTextEditUnchanged(current_state, next_state)) return null;

            try self.rewriteCanvasWidgetTextStorage(index, next_state);
            self.scrollCanvasTextInputCaretIntoView(index);
            const semantics = try self.widgetLayoutTree().collectSemantics(&self.widget_semantics_nodes);
            self.widget_semantics_node_count = semantics.len;
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, unionRects(previous_bounds, self.widget_layout_nodes[index].frame) orelse self.widget_layout_nodes[index].frame);
        }

        pub fn canvasWidgetKeyboardTextEdit(self: *const RuntimeView, target: canvas.WidgetFocusTarget, keyboard: canvas.WidgetKeyboardEvent) ?canvas.TextInputEvent {
            const index = self.canvasWidgetNodeIndexById(target.id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;

            if (keyboard.phase == .key_down and !keyboard.modifiers.shift and !keyboard.modifiers.hasNavigationModifier() and canvasWidgetEscapeKey(keyboard.key)) {
                if (widget.text_composition != null) return .cancel_composition;
                if (widget.kind == .search_field or widget.kind == .combobox) return .clear;
                return null;
            }

            // Multi-line editing contract: Enter (plain or shift) inserts
            // a newline; submit rides the primary-modifier chord instead.
            // Shared with the app dispatch path so the model's `on_input`
            // hears exactly the edit the retained text applied.
            if (canvas.widgetKeyboardNewlineTextEditEvent(widget.kind, keyboard)) |newline_edit| {
                return newline_edit;
            }

            if (canvasWidgetSingleLineTextKind(widget.kind) and keyboard.phase == .key_down and keyboard.text.len == 0 and !keyboard.modifiers.hasNavigationModifier()) {
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return .{ .move_caret = .{ .direction = .start, .extend = keyboard.modifiers.shift } };
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return .{ .move_caret = .{ .direction = .end, .extend = keyboard.modifiers.shift } };
            }

            return keyboard.textEditEvent();
        }

        pub fn canEditCanvasWidgetText(self: *const RuntimeView, id: canvas.ObjectId) bool {
            const index = self.canvasWidgetNodeIndexById(id) orelse return false;
            const layout = self.widgetLayoutTree();
            if (canvasWidgetLayoutNodeHidden(layout, index)) return false;
            if (!canvasWidgetLayoutNodeFrameVisible(layout, index)) return false;
            const widget = self.widget_layout_nodes[index].widget;
            return canvasWidgetEditableTextKind(widget.kind) and !widget.state.disabled;
        }

        pub fn applyCanvasWidgetTextPointer(self: *RuntimeView, target_id: canvas.ObjectId, point: geometry.PointF, extend: bool, click_count: u8) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(target_id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.state.disabled) return null;
            if (canvas.widgetStaticTextSelectable(widget)) return applyCanvasWidgetStaticTextPointer(self, index, target_id, point, extend);
            if (!canvasWidgetEditableTextKind(widget.kind)) return null;

            const current_selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
            const next_selection = canvasWidgetEditableTextPointerSelection(self, widget, point, extend, click_count, current_selection) orelse return null;
            // A widget with NO stored selection must store one even when
            // it matches the implied default: the emitters draw a caret
            // only for a present selection, so short-circuiting here left
            // a click into an empty field (or past the end of the text)
            // caretless.
            if (widget.text_selection != null and canvasTextSelectionsEqual(current_selection, next_selection) and widget.text_composition == null) return null;

            self.widget_layout_nodes[index].widget.text_selection = next_selection;
            self.widget_layout_nodes[index].widget.text_composition = null;
            self.scrollCanvasTextInputCaretIntoView(index);
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
            extend: bool,
            click_count: u8,
            current_selection: canvas.TextSelection,
        ) ?canvas.TextSelection {
            if (click_count >= 2) {
                const offset = canvas.textOffsetForWidgetPoint(widget, point, self.widget_tokens) orelse return null;
                const unit = canvasWidgetMultiClickUnitSelection(widget, offset, click_count);
                if (!extend) {
                    self.canvas_widget_multi_click_anchor = unit.range(widget.text.len);
                    return unit;
                }
                return canvasWidgetMultiClickDragSelection(self.canvas_widget_multi_click_anchor, unit, widget.text.len);
            }
            const anchor: ?usize = if (extend) current_selection.anchor else null;
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
        /// anchor. Cross-widget selection is out of scope: the selection
        /// model is the widget's own `text_selection` — there is no
        /// document model ordering text across widgets to extend into.
        fn applyCanvasWidgetStaticTextPointer(self: *RuntimeView, index: usize, target_id: canvas.ObjectId, point: geometry.PointF, extend: bool) anyerror!?geometry.RectF {
            const widget = self.widget_layout_nodes[index].widget;
            if (extend and self.canvas_widget_selected_text_id != target_id) return null;
            const current_selection = widget.text_selection orelse canvas.TextSelection.collapsed(0);
            const anchor: ?usize = if (extend) current_selection.anchor else null;
            const next_selection = canvas.staticTextSelectionForWidgetPoint(widget, point, anchor, self.widget_tokens) orelse return null;
            if (self.canvas_widget_selected_text_id == target_id and widget.text_selection != null and canvasTextSelectionsEqual(current_selection, next_selection)) return null;

            self.widget_layout_nodes[index].widget.text_selection = next_selection;
            self.canvas_widget_selected_text_id = target_id;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, widget.frame);
        }

        /// Drop the view's static text selection (pointer pressed
        /// elsewhere, or the copy source went away). Returns the dirty
        /// bounds of the widget that lost its highlight.
        pub fn clearCanvasWidgetStaticTextSelection(self: *RuntimeView) anyerror!?geometry.RectF {
            const id = self.canvas_widget_selected_text_id;
            if (id == 0) return null;
            self.canvas_widget_selected_text_id = 0;
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            if (self.widget_layout_nodes[index].widget.text_selection == null) return null;
            self.widget_layout_nodes[index].widget.text_selection = null;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, self.widget_layout_nodes[index].frame);
        }

        /// The text a copy shortcut should place on the clipboard: the
        /// focused editable widget's selection when it has one, else the
        /// view's static text selection.
        pub fn canvasWidgetCopyText(self: *const RuntimeView) ?[]const u8 {
            if (self.canvas_widget_focused_id != 0) {
                if (canvasWidgetSelectionSliceById(self, self.canvas_widget_focused_id, true)) |slice| return slice;
            }
            if (self.canvas_widget_selected_text_id != 0) {
                if (canvasWidgetSelectionSliceById(self, self.canvas_widget_selected_text_id, false)) |slice| return slice;
            }
            return null;
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
            var temp: [max_canvas_widget_text_bytes_per_view]u8 = undefined;
            var text_ranges: [max_canvas_widget_nodes_per_view]WidgetTextStorageRange = undefined;
            var label_ranges: [max_canvas_widget_nodes_per_view]WidgetTextStorageRange = undefined;
            var command_ranges: [max_canvas_widget_nodes_per_view]WidgetTextStorageRange = undefined;
            var temp_len: usize = 0;

            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                const text = if (index == edited_index) next_state.text else node.widget.text;
                text_ranges[index] = try appendWidgetTextStorageRange(&temp, &temp_len, text);
                label_ranges[index] = try appendWidgetTextStorageRange(&temp, &temp_len, node.widget.semantics.label);
                command_ranges[index] = try appendWidgetTextStorageRange(&temp, &temp_len, node.widget.command);
            }

            @memcpy(self.widget_text_bytes[0..temp_len], temp[0..temp_len]);
            self.widget_text_len = temp_len;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |*node, index| {
                const text_range = text_ranges[index];
                const label_range = label_ranges[index];
                const command_range = command_ranges[index];
                node.widget.text = self.widget_text_bytes[text_range.start..text_range.end];
                node.widget.semantics.label = self.widget_text_bytes[label_range.start..label_range.end];
                node.widget.command = self.widget_text_bytes[command_range.start..command_range.end];
            }
            self.widget_layout_nodes[edited_index].widget.text_selection = next_state.selection;
            self.widget_layout_nodes[edited_index].widget.text_composition = next_state.composition;
        }

        pub fn setCanvasWidgetTextValue(self: *RuntimeView, id: canvas.ObjectId, text: []const u8) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;
            if (std.mem.eql(u8, widget.text, text) and widget.text_composition == null and textSelectionCollapsedAt(widget.text_selection, text.len)) return null;

            try self.rewriteCanvasWidgetTextStorage(index, .{
                .text = text,
                .selection = canvas.TextSelection.collapsed(text.len),
                .composition = null,
            });
            self.scrollCanvasTextInputCaretIntoView(index);
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, self.widget_layout_nodes[index].frame);
        }
    };
}
