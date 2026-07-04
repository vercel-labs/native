const geometry = @import("geometry");
const canvas = @import("canvas");
const validation = @import("validation.zig");
const canvas_limits = @import("canvas_limits.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const widget_bridge = @import("widget_bridge.zig");
const platform = @import("../platform/root.zig");

const validateCommandName = validation.validateCommandName;
const max_canvas_widget_nodes_per_view = canvas_limits.max_canvas_widget_nodes_per_view;
const max_canvas_widget_semantics_per_view = canvas_limits.max_canvas_widget_semantics_per_view;
const max_canvas_widget_text_bytes_per_view = canvas_limits.max_canvas_widget_text_bytes_per_view;
const max_canvas_widget_source_text_entries_per_view = canvas_limits.max_canvas_widget_source_text_entries_per_view;

const CanvasWidgetScrollReconcileEntry = canvas_widget_runtime.CanvasWidgetScrollReconcileEntry;
const CanvasWidgetControlReconcileEntry = canvas_widget_runtime.CanvasWidgetControlReconcileEntry;
const CanvasWidgetTextReconcileEntry = canvas_widget_runtime.CanvasWidgetTextReconcileEntry;
const CanvasWidgetSourceTextEntry = canvas_widget_runtime.CanvasWidgetSourceTextEntry;
const CanvasWidgetStepDirection = canvas_widget_runtime.CanvasWidgetStepDirection;
const canvasWidgetInteractionTargetExists = canvas_widget_runtime.canvasWidgetInteractionTargetExists;
const canvasWidgetLayoutNodeClippedBounds = canvas_widget_runtime.canvasWidgetLayoutNodeClippedBounds;
const canvasWidgetDismissibleSurfaceKind = canvas_widget_runtime.canvasWidgetDismissibleSurfaceKind;
const canvasWidgetEditableTextKind = canvas_widget_runtime.canvasWidgetEditableTextKind;
const collectCanvasWidgetControlReconcileEntries = canvas_widget_runtime.collectCanvasWidgetControlReconcileEntries;
const collectCanvasWidgetScrollReconcileEntries = canvas_widget_runtime.collectCanvasWidgetScrollReconcileEntries;
const canvasWidgetScrollStateForLayoutNode = canvas_widget_runtime.canvasWidgetScrollStateForLayoutNode;
const collectCanvasWidgetTextReconcileEntries = canvas_widget_runtime.collectCanvasWidgetTextReconcileEntries;
const canvasWidgetSourceTextFingerprint = canvas_widget_runtime.canvasWidgetSourceTextFingerprint;
const canvasWidgetLayoutNodeWithControlReconcileState = canvas_widget_runtime.canvasWidgetLayoutNodeWithControlReconcileState;
const canvasWidgetLayoutNodeWithTextReconcileState = canvas_widget_runtime.canvasWidgetLayoutNodeWithTextReconcileState;
const canvasWidgetLayoutNodeWithSourceSemantics = canvas_widget_runtime.canvasWidgetLayoutNodeWithSourceSemantics;
const applyCanvasWidgetSourceScrollSemantics = canvas_widget_runtime.applyCanvasWidgetSourceScrollSemantics;
const clampCanvasWidgetLayoutScrollOffsets = canvas_widget_runtime.clampCanvasWidgetLayoutScrollOffsets;
const clampCanvasWidgetLayoutTextOffsets = canvas_widget_runtime.clampCanvasWidgetLayoutTextOffsets;

const platformCursorFromCanvas = widget_bridge.platformCursorFromCanvas;

/// Byte offset of `inner` within `outer` when it is a subslice, else null.
fn subsliceOffset(outer: []const u8, inner: []const u8) ?usize {
    if (inner.len == 0) return 0;
    const outer_start = @intFromPtr(outer.ptr);
    const inner_start = @intFromPtr(inner.ptr);
    if (inner_start < outer_start) return null;
    const offset = inner_start - outer_start;
    if (offset + inner.len > outer.len) return null;
    return offset;
}

pub fn RuntimeViewCanvasWidgetTree(comptime RuntimeView: type) type {
    return struct {
        pub fn widgetLayoutTree(self: *const RuntimeView) canvas.WidgetLayoutTree {
            return .{ .nodes = self.widget_layout_nodes[0..self.widget_layout_node_count] };
        }

        pub fn widgetSemantics(self: *const RuntimeView) []const canvas.WidgetSemanticsNode {
            return self.widget_semantics_nodes[0..self.widget_semantics_node_count];
        }

        pub fn widgetSourceTextEntries(self: *const RuntimeView) []const CanvasWidgetSourceTextEntry {
            return self.widget_source_text_entries[0..self.widget_source_text_count];
        }

        pub fn widgetSourceScrollEntries(self: *const RuntimeView) []const canvas_widget_runtime.CanvasWidgetSourceScrollEntry {
            return self.widget_source_scroll_entries[0..self.widget_source_scroll_count];
        }

        pub fn copyCanvasWidgetSourceScroll(self: *RuntimeView, layout: canvas.WidgetLayoutTree) void {
            const entries = canvas_widget_runtime.collectCanvasWidgetScrollOffsetEntries(
                layout.nodes,
                &self.widget_source_scroll_entries,
            );
            self.widget_source_scroll_count = entries.len;
        }

        pub fn widgetSourceControlEntries(self: *const RuntimeView) []const canvas_widget_runtime.CanvasWidgetSourceControlEntry {
            return self.widget_source_control_entries[0..self.widget_source_control_count];
        }

        pub fn copyCanvasWidgetSourceControls(self: *RuntimeView, layout: canvas.WidgetLayoutTree) void {
            const entries = canvas_widget_runtime.collectCanvasWidgetSourceControlEntries(
                layout.nodes,
                &self.widget_source_control_entries,
            );
            self.widget_source_control_count = entries.len;
        }

        pub fn copyCanvasWidgetSourceText(self: *RuntimeView, layout: canvas.WidgetLayoutTree) anyerror!void {
            var entries: [max_canvas_widget_source_text_entries_per_view]CanvasWidgetSourceTextEntry = undefined;
            var entry_count: usize = 0;

            for (layout.nodes) |node| {
                if (node.widget.id == 0 or !canvasWidgetEditableTextKind(node.widget.kind)) continue;
                if (entry_count >= entries.len) break;
                const source_text = canvasWidgetSourceTextFingerprint(node.widget.text);
                entries[entry_count] = .{
                    .id = node.widget.id,
                    .kind = node.widget.kind,
                    .text_len = source_text.len,
                    .text_hash = source_text.hash,
                };
                entry_count += 1;
            }

            @memcpy(self.widget_source_text_entries[0..entry_count], entries[0..entry_count]);
            self.widget_source_text_count = entry_count;
        }

        /// `scratch` is reconcile scratch too large for the stack at the
        /// 1024-node budget; callers pass the Runtime's shared
        /// `canvas_widget_copy_scratch` (the event loop is single-threaded).
        pub fn copyWidgetLayoutTree(self: *RuntimeView, layout: canvas.WidgetLayoutTree, scratch: *canvas_widget_runtime.CanvasWidgetCopyScratch) anyerror!void {
            if (layout.nodes.len > self.widget_layout_nodes.len) return error.WidgetNodeLimitReached;
            if (layout.nodes.len > 0 and layout.nodes.ptr == self.widget_layout_nodes[0..].ptr) {
                self.widget_revision += 1;
                return;
            }

            const source_semantics = try layout.collectSemantics(&scratch.source_semantics);
            const previous_control_states = collectCanvasWidgetControlReconcileEntries(
                self.widgetLayoutTree().nodes,
                &scratch.control_entries,
            );
            const previous_scroll_states = collectCanvasWidgetScrollReconcileEntries(
                self.widgetLayoutTree().nodes,
                self.widget_scroll_states[0..self.widget_layout_node_count],
                &scratch.scroll_entries,
            );
            var previous_text_len: usize = 0;
            const previous_text_states = try collectCanvasWidgetTextReconcileEntries(
                self.widgetLayoutTree().nodes,
                self.widgetSourceTextEntries(),
                &scratch.text_entries,
                &scratch.text_bytes,
                &previous_text_len,
            );

            self.widget_layout_node_count = 0;
            self.widget_semantics_node_count = 0;
            self.widget_text_len = 0;
            self.widget_span_len = 0;
            self.widget_context_menu_len = 0;

            for (layout.nodes, 0..) |node, layout_index| {
                const text_reconciled = canvasWidgetLayoutNodeWithTextReconcileState(node, layout, layout_index, previous_text_states);
                const text_copy = try self.copyWidgetLayoutNode(text_reconciled, source_semantics);
                const copy = canvasWidgetLayoutNodeWithControlReconcileState(text_copy, layout, layout_index, previous_control_states, self.widgetSourceControlEntries());
                self.widget_layout_nodes[self.widget_layout_node_count] = copy;
                self.widget_scroll_states[self.widget_layout_node_count] = canvasWidgetScrollStateForLayoutNode(copy, previous_scroll_states);
                self.widget_layout_node_count += 1;
            }

            clampCanvasWidgetLayoutScrollOffsets(
                self.widget_layout_nodes[0..self.widget_layout_node_count],
                self.widget_scroll_states[0..self.widget_layout_node_count],
            );
            clampCanvasWidgetLayoutTextOffsets(
                self.widget_layout_nodes[0..self.widget_layout_node_count],
                self.widget_tokens,
            );

            const semantics = try self.widgetLayoutTree().collectSemantics(&self.widget_semantics_nodes);
            applyCanvasWidgetSourceScrollSemantics(self.widget_semantics_nodes[0..semantics.len], source_semantics);
            self.widget_semantics_node_count = semantics.len;
            if (self.canvas_widget_focused_id != 0 and self.widgetLayoutTree().focusTargetById(self.canvas_widget_focused_id) == null) {
                self.canvas_widget_focused_id = 0;
                self.canvas_widget_focus_visible_id = 0;
            }
            if (self.canvas_widget_focus_visible_id != 0 and (self.canvas_widget_focus_visible_id != self.canvas_widget_focused_id or self.widgetLayoutTree().focusTargetById(self.canvas_widget_focus_visible_id) == null)) {
                self.canvas_widget_focus_visible_id = 0;
            }
            if (self.canvas_widget_hovered_id != 0 and !canvasWidgetInteractionTargetExists(self.widgetLayoutTree(), self.canvas_widget_hovered_id)) {
                self.canvas_widget_hovered_id = 0;
            }
            if (self.canvas_widget_pressed_id != 0 and !canvasWidgetInteractionTargetExists(self.widgetLayoutTree(), self.canvas_widget_pressed_id)) {
                self.canvas_widget_pressed_id = 0;
            }
            self.canvas_widget_cursor = self.canvasWidgetCursorForId(self.canvas_widget_hovered_id);
            self.widget_revision += 1;
        }

        pub fn canvasWidgetCursorForId(self: *const RuntimeView, id: canvas.ObjectId) platform.Cursor {
            const index = self.canvasWidgetNodeIndexById(id) orelse return .arrow;
            const node = self.widget_layout_nodes[index];
            if (node.widget.semantics.role == .link and !node.widget.state.disabled) {
                return platformCursorFromCanvas(.pointing_hand);
            }
            return platformCursorFromCanvas(canvas.cursorForWidgetTarget(node.widget.kind, node.widget.state));
        }

        pub fn canvasWidgetRenderState(self: *const RuntimeView) canvas.WidgetRenderState {
            const focused_id: ?canvas.ObjectId = if (!self.focused or self.canvas_widget_focused_id == 0) null else self.canvas_widget_focused_id;
            return .{
                .focused_id = focused_id,
                .focus_visible_id = if (focused_id) |id| if (self.canvas_widget_focus_visible_id == id) id else null else null,
                .hovered_id = if (self.canvas_widget_hovered_id == 0) null else self.canvas_widget_hovered_id,
                .pressed_id = if (self.canvas_widget_pressed_id == 0) null else self.canvas_widget_pressed_id,
            };
        }

        pub fn reconcileCanvasWidgetRenderStateAfterScroll(self: *RuntimeView, point: ?geometry.PointF) void {
            const layout = self.widgetLayoutTree();
            if (self.canvas_widget_focused_id != 0 and layout.focusTargetById(self.canvas_widget_focused_id) == null) {
                self.canvas_widget_focused_id = 0;
                self.canvas_widget_focus_visible_id = 0;
            }
            if (self.canvas_widget_focus_visible_id != 0 and (self.canvas_widget_focus_visible_id != self.canvas_widget_focused_id or layout.focusTargetById(self.canvas_widget_focus_visible_id) == null)) {
                self.canvas_widget_focus_visible_id = 0;
            }

            var next_hovered_id = self.canvas_widget_hovered_id;
            var next_cursor = self.canvas_widget_cursor;

            if (point) |value| {
                const hit = layout.hitTestWithTokens(value, self.widget_tokens);
                next_hovered_id = if (hit) |target| target.id else 0;
                next_cursor = platformCursorFromCanvas(layout.cursorForHit(hit));
            } else if (!canvasWidgetInteractionTargetExists(layout, next_hovered_id)) {
                next_hovered_id = 0;
                next_cursor = .arrow;
            }

            var next_pressed_id = self.canvas_widget_pressed_id;
            if (!canvasWidgetInteractionTargetExists(layout, next_pressed_id)) {
                next_pressed_id = 0;
            }

            self.canvas_widget_hovered_id = next_hovered_id;
            self.canvas_widget_pressed_id = next_pressed_id;
            self.canvas_widget_cursor = next_cursor;
        }

        pub fn dismissCanvasWidgetSurfaceForFocusedTarget(self: *RuntimeView, focused_id: canvas.ObjectId) anyerror!?geometry.RectF {
            const focused_index = self.canvasWidgetNodeIndexById(focused_id) orelse return null;
            const focused_widget = self.widget_layout_nodes[focused_index].widget;
            if (canvasWidgetEditableTextKind(focused_widget.kind) and focused_widget.text_composition != null) return null;

            return self.dismissCanvasWidgetSurfaceForTargetIndex(focused_index);
        }

        pub fn dismissCanvasWidgetSurfaceForTarget(self: *RuntimeView, target_id: canvas.ObjectId) anyerror!?geometry.RectF {
            const target_index = self.canvasWidgetNodeIndexById(target_id) orelse return null;
            return self.dismissCanvasWidgetSurfaceForTargetIndex(target_index);
        }

        pub fn dismissCanvasWidgetSurfaceForTargetIndex(self: *RuntimeView, target_index: usize) anyerror!?geometry.RectF {
            const surface_index = self.canvasWidgetDismissibleSurfaceIndexForTarget(target_index) orelse return null;
            return self.dismissCanvasWidgetSurfaceAtIndex(surface_index);
        }

        pub fn dismissCanvasWidgetSurfaceForPointerOutsideFocusedTarget(self: *RuntimeView, focused_id: canvas.ObjectId, route: []const canvas.WidgetEventRouteEntry) anyerror!?geometry.RectF {
            const focused_index = self.canvasWidgetNodeIndexById(focused_id) orelse return null;
            const surface_index = self.canvasWidgetDismissibleSurfaceIndexForTarget(focused_index) orelse return null;
            if (self.canvasWidgetRouteDescendsFromIndex(route, surface_index)) return null;
            return self.dismissCanvasWidgetSurfaceAtIndex(surface_index);
        }

        pub fn dismissCanvasWidgetSurfaceAtIndex(self: *RuntimeView, surface_index: usize) anyerror!?geometry.RectF {
            if (surface_index >= self.widget_layout_node_count) return null;
            const surface = self.widget_layout_nodes[surface_index].widget;
            if (surface.semantics.hidden) return null;
            const dirty = self.canvasWidgetDirtyBounds(surface_index, surface.frame) orelse surface.frame;
            self.widget_layout_nodes[surface_index].widget.semantics.hidden = true;
            if (self.canvasWidgetIdDescendsFromIndex(self.canvas_widget_focused_id, surface_index)) {
                self.canvas_widget_focused_id = 0;
                self.canvas_widget_focus_visible_id = 0;
            }
            if (self.canvasWidgetIdDescendsFromIndex(self.canvas_widget_focus_visible_id, surface_index)) self.canvas_widget_focus_visible_id = 0;
            if (self.canvasWidgetIdDescendsFromIndex(self.canvas_widget_hovered_id, surface_index)) {
                self.canvas_widget_hovered_id = 0;
                self.canvas_widget_cursor = .arrow;
            }
            if (self.canvasWidgetIdDescendsFromIndex(self.canvas_widget_pressed_id, surface_index)) self.canvas_widget_pressed_id = 0;

            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return dirty;
        }

        pub fn canvasWidgetDismissibleSurfaceIndexForTarget(self: *const RuntimeView, target_index: usize) ?usize {
            if (target_index >= self.widget_layout_node_count) return null;
            var current: ?usize = target_index;
            while (current) |index| {
                if (index >= self.widget_layout_node_count) return null;
                const widget = self.widget_layout_nodes[index].widget;
                if (canvasWidgetDismissibleSurfaceKind(widget.kind) and !widget.semantics.hidden) return index;
                current = self.widget_layout_nodes[index].parent_index;
            }
            return null;
        }

        pub fn canvasWidgetRouteDescendsFromIndex(self: *const RuntimeView, route: []const canvas.WidgetEventRouteEntry, ancestor_index: usize) bool {
            for (route) |entry| {
                if (self.canvasWidgetNodeIndexDescendsFrom(entry.node_index, ancestor_index)) return true;
            }
            return false;
        }

        pub fn canvasWidgetScopedFocusTarget(self: *const RuntimeView, current_id: canvas.ObjectId, direction: canvas.WidgetFocusDirection) ?canvas.WidgetFocusTarget {
            const current_index = self.canvasWidgetNodeIndexById(current_id) orelse return null;
            const surface_index = self.canvasWidgetDismissibleSurfaceIndexForTarget(current_index) orelse return null;
            return self.canvasWidgetFocusTargetInScope(surface_index, current_index, direction);
        }

        pub fn canvasWidgetFocusTargetInScope(
            self: *const RuntimeView,
            surface_index: usize,
            current_index: usize,
            direction: canvas.WidgetFocusDirection,
        ) ?canvas.WidgetFocusTarget {
            if (surface_index >= self.widget_layout_node_count or current_index >= self.widget_layout_node_count) return null;
            return switch (direction) {
                .forward => self.canvasWidgetForwardFocusTargetInScope(surface_index, current_index),
                .backward => self.canvasWidgetBackwardFocusTargetInScope(surface_index, current_index),
                .left, .right, .up, .down => null,
            };
        }

        pub fn canvasWidgetForwardFocusTargetInScope(self: *const RuntimeView, surface_index: usize, current_index: usize) ?canvas.WidgetFocusTarget {
            var index = current_index + 1;
            while (index < self.widget_layout_node_count) : (index += 1) {
                if (self.canvasWidgetFocusTargetAtScopedIndex(surface_index, index)) |target| return target;
            }
            index = surface_index;
            while (index <= current_index and index < self.widget_layout_node_count) : (index += 1) {
                if (self.canvasWidgetFocusTargetAtScopedIndex(surface_index, index)) |target| return target;
            }
            return null;
        }

        pub fn canvasWidgetBackwardFocusTargetInScope(self: *const RuntimeView, surface_index: usize, current_index: usize) ?canvas.WidgetFocusTarget {
            var index = current_index;
            while (index > 0) {
                index -= 1;
                if (self.canvasWidgetFocusTargetAtScopedIndex(surface_index, index)) |target| return target;
            }
            index = self.widget_layout_node_count;
            while (index > current_index) {
                index -= 1;
                if (self.canvasWidgetFocusTargetAtScopedIndex(surface_index, index)) |target| return target;
            }
            return null;
        }

        pub fn canvasWidgetFocusTargetAtScopedIndex(self: *const RuntimeView, surface_index: usize, index: usize) ?canvas.WidgetFocusTarget {
            if (!self.canvasWidgetNodeIndexDescendsFrom(index, surface_index)) return null;
            const id = self.widget_layout_nodes[index].widget.id;
            return self.widgetLayoutTree().focusTargetById(id);
        }

        pub fn canvasWidgetIdDescendsFromIndex(self: *const RuntimeView, id: canvas.ObjectId, ancestor_index: usize) bool {
            const index = self.canvasWidgetNodeIndexById(id) orelse return false;
            return self.canvasWidgetNodeIndexDescendsFrom(index, ancestor_index);
        }

        pub fn canvasWidgetNodeIndexDescendsFrom(self: *const RuntimeView, node_index: usize, ancestor_index: usize) bool {
            if (node_index >= self.widget_layout_node_count or ancestor_index >= self.widget_layout_node_count) return false;
            var current: ?usize = node_index;
            while (current) |index| {
                if (index >= self.widget_layout_node_count) return false;
                if (index == ancestor_index) return true;
                current = self.widget_layout_nodes[index].parent_index;
            }
            return false;
        }

        pub fn canvasWidgetNodeIndexById(self: *const RuntimeView, id: canvas.ObjectId) ?usize {
            if (id == 0) return null;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                if (node.widget.id == id) return index;
            }
            return null;
        }

        pub fn canvasWidgetCommand(self: *const RuntimeView, id: canvas.ObjectId) ?[]const u8 {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.command.len == 0) return null;
            return widget.command;
        }

        pub fn canvasWidgetStepKey(self: *const RuntimeView, id: canvas.ObjectId, direction: CanvasWidgetStepDirection) []const u8 {
            const index = self.canvasWidgetNodeIndexById(id) orelse return switch (direction) {
                .increment => "arrowright",
                .decrement => "arrowleft",
            };
            return switch (self.widget_layout_nodes[index].widget.kind) {
                .grid, .scroll_view, .list, .data_grid, .table => switch (direction) {
                    .increment => "pagedown",
                    .decrement => "pageup",
                },
                else => switch (direction) {
                    .increment => "arrowright",
                    .decrement => "arrowleft",
                },
            };
        }

        pub fn refreshCanvasWidgetSemantics(self: *RuntimeView) anyerror!void {
            const semantics = try self.widgetLayoutTree().collectSemantics(&self.widget_semantics_nodes);
            self.widget_semantics_node_count = semantics.len;
        }

        pub fn canvasWidgetDirtyBounds(self: *const RuntimeView, node_index: usize, bounds: geometry.RectF) ?geometry.RectF {
            return canvasWidgetLayoutNodeClippedBounds(self.widgetLayoutTree(), node_index, bounds);
        }

        pub fn copyWidgetLayoutNode(self: *RuntimeView, node: canvas.WidgetLayoutNode, source_semantics: []const canvas.WidgetSemanticsNode) anyerror!canvas.WidgetLayoutNode {
            var copy = node;
            if (node.widget.command.len > 0) try validateCommandName(node.widget.command);
            copy.widget.text = try self.copyWidgetText(node.widget.text);
            copy.widget.spans = try self.copyWidgetSpans(node.widget.text, copy.widget.text, node.widget.spans);
            copy.widget.command = try self.copyWidgetText(node.widget.command);
            copy.widget.semantics.label = try self.copyWidgetText(node.widget.semantics.label);
            copy.widget.context_menu = try self.copyWidgetContextMenu(node.widget.context_menu);
            copy = canvasWidgetLayoutNodeWithSourceSemantics(copy, source_semantics);
            copy.widget.children = &.{};
            return copy;
        }

        /// Retain a widget's declared context-menu items: the retained tree
        /// owns its bytes (same rule as text / command / semantics labels),
        /// so a right-click can never read a label from a reused app buffer.
        pub fn copyWidgetContextMenu(self: *RuntimeView, items: []const canvas.WidgetContextMenuItem) anyerror![]const canvas.WidgetContextMenuItem {
            if (items.len == 0) return &.{};
            const end = self.widget_context_menu_len + items.len;
            if (end > self.widget_context_menu_items.len) return error.WidgetContextMenuLimitReached;
            const start = self.widget_context_menu_len;
            for (items, self.widget_context_menu_items[start..end]) |item, *entry| {
                entry.* = .{
                    .label = try self.copyWidgetText(item.label),
                    .enabled = item.enabled,
                    .separator = item.separator,
                };
            }
            self.widget_context_menu_len = end;
            return self.widget_context_menu_items[start..end];
        }

        pub fn copyWidgetText(self: *RuntimeView, text: []const u8) anyerror![]const u8 {
            const end = self.widget_text_len + text.len;
            if (end > self.widget_text_bytes.len) return error.WidgetTextTooLarge;
            const start = self.widget_text_len;
            @memcpy(self.widget_text_bytes[start..end], text);
            self.widget_text_len = end;
            return self.widget_text_bytes[start..end];
        }

        /// Retain a paragraph's inline spans. Span text that is a subslice
        /// of the paragraph's source text (the `Ui.paragraph` invariant)
        /// rebases onto the already-copied buffer; anything else copies
        /// bytes. Link payloads always copy.
        pub fn copyWidgetSpans(
            self: *RuntimeView,
            source_text: []const u8,
            copied_text: []const u8,
            spans: []const canvas.TextSpan,
        ) anyerror![]const canvas.TextSpan {
            if (spans.len == 0) return &.{};
            const end = self.widget_span_len + spans.len;
            if (end > self.widget_span_entries.len) return error.WidgetSpanLimitReached;
            const start = self.widget_span_len;
            for (spans, self.widget_span_entries[start..end]) |span, *entry| {
                entry.* = span;
                entry.text = if (subsliceOffset(source_text, span.text)) |offset|
                    copied_text[offset .. offset + span.text.len]
                else
                    try self.copyWidgetText(span.text);
                entry.link = try self.copyWidgetText(span.link);
            }
            self.widget_span_len = end;
            return self.widget_span_entries[start..end];
        }
    };
}
