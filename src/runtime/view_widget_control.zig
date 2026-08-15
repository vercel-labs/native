const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");

const unionRects = canvas_frame_helpers.unionRects;
const canvasWidgetResizableMinWidth = canvas_widget_runtime.canvasWidgetResizableMinWidth;
const canvasWidgetBooleanSelected = canvas_widget_runtime.canvasWidgetBooleanSelected;
const canvasWidgetSwitchControlKind = canvas_widget_runtime.canvasWidgetSwitchControlKind;
const canvasWidgetSelectableSelected = canvas_widget_runtime.canvasWidgetSelectableSelected;
const canvasWidgetSelectionClearsSiblings = canvas_widget_runtime.canvasWidgetSelectionClearsSiblings;

pub const CanvasWidgetToggleAnimation = struct {
    id: canvas.ObjectId,
    selected: bool,
    travel: f32,
    dirty_bounds: ?geometry.RectF,
};

fn setCanvasWidgetNodeWidth(node: *canvas.WidgetLayoutNode, width: f32) void {
    node.frame.width = width;
    node.widget.frame.width = width;
}

pub fn RuntimeViewCanvasWidgetControl(comptime RuntimeView: type) type {
    return struct {
        pub fn canvasWidgetToggleAnimation(self: *const RuntimeView, id: canvas.ObjectId) ?CanvasWidgetToggleAnimation {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetSwitchControlKind(widget.kind) or widget.state.disabled) return null;
            const travel = canvas.toggleWidgetKnobTravel(widget, self.widget_tokens);
            if (travel <= 0) return null;
            return .{
                .id = id,
                .selected = canvasWidgetBooleanSelected(widget),
                .travel = travel,
                .dirty_bounds = self.canvasWidgetDirtyBounds(index, widget.frame),
            };
        }

        pub fn canvasWidgetToggleAnimationForPointer(
            self: *const RuntimeView,
            pointer: canvas.WidgetPointerEvent,
            target: ?canvas.WidgetHit,
            pressed_id: canvas.ObjectId,
        ) ?CanvasWidgetToggleAnimation {
            if (pointer.phase != .up or pressed_id == 0) return null;
            const hit = target orelse return null;
            if (!canvasWidgetSwitchControlKind(hit.kind) or hit.id != pressed_id) return null;
            if (!hit.bounds.normalized().containsPoint(pointer.point)) return null;
            return self.canvasWidgetToggleAnimation(pressed_id);
        }

        pub fn canvasWidgetToggleAnimationForKeyboard(self: *const RuntimeView, id: canvas.ObjectId, keyboard: canvas.WidgetKeyboardEvent) ?CanvasWidgetToggleAnimation {
            if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
            if (!canvas.isWidgetActivationKey(keyboard.key)) return null;
            return self.canvasWidgetToggleAnimation(id);
        }

        pub fn applyCanvasWidgetControlPointer(self: *RuntimeView, pointer: canvas.WidgetPointerEvent, target: ?canvas.WidgetHit, pressed_id: canvas.ObjectId) anyerror!?geometry.RectF {
            return switch (pointer.phase) {
                .down => if (target) |hit| try self.applyCanvasWidgetSliderValue(hit.id, pointer.point) else null,
                .move => if (pressed_id != 0) blk: {
                    if (try self.applyCanvasWidgetSliderValue(pressed_id, pointer.point)) |dirty| break :blk dirty;
                    if (try self.applyCanvasWidgetSplitPointer(pressed_id, pointer.point)) |dirty| break :blk dirty;
                    break :blk try self.applyCanvasWidgetResizableDelta(pressed_id, pointer.delta.dx);
                } else null,
                .up => blk: {
                    if (pressed_id == 0) break :blk null;
                    if (try self.applyCanvasWidgetSliderValue(pressed_id, pointer.point)) |dirty| break :blk dirty;
                    const hit = target orelse break :blk null;
                    if (!hit.bounds.normalized().containsPoint(pointer.point)) break :blk null;
                    if (hit.id != pressed_id) break :blk null;
                    if (try self.toggleCanvasWidgetBooleanControl(pressed_id)) |dirty| break :blk dirty;
                    break :blk try self.setCanvasWidgetSelected(pressed_id, true);
                },
                .hover, .cancel, .wheel => null,
            };
        }

        /// Divider drag: the captured `.split_divider` follows the
        /// pointer's absolute x within the parent split's content box.
        /// The runtime applies the fraction as the optimistic echo
        /// (frames move geometrically; the model's rebuild is the exact
        /// layout) and notes a resize event so the split's `on_resize`
        /// Msg dispatches with the applied fraction.
        pub fn applyCanvasWidgetSplitPointer(self: *RuntimeView, id: canvas.ObjectId, point: geometry.PointF) anyerror!?geometry.RectF {
            const divider_index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const divider = self.widget_layout_nodes[divider_index].widget;
            if (divider.kind != .split_divider or divider.state.disabled) return null;
            const split_index = self.widget_layout_nodes[divider_index].parent_index orelse return null;
            if (split_index >= self.widget_layout_node_count) return null;
            const split_node = self.widget_layout_nodes[split_index];
            if (split_node.widget.kind != .split) return null;

            const content = split_node.frame.inset(split_node.widget.layout.padding).normalized();
            const divider_extent = self.widget_layout_nodes[divider_index].frame.width;
            const available = content.width - divider_extent;
            if (!(available > 0)) return null;
            const fraction = (point.x - content.x - divider_extent * 0.5) / available;
            // A live drag owns the fraction: an armed layout tween on
            // this split retires here, so the pointer's per-step echoes
            // (live re-wrap) never fight the tween's slide — the
            // source-declared tween re-arms on the first rebuild after
            // release.
            self.removeCanvasWidgetLayoutTween(split_node.widget.id);
            return self.applyCanvasWidgetSplitFraction(split_index, fraction);
        }

        /// Apply a first-pane fraction to a split: clamp against the
        /// panes' min widths, move the divider and pane frames (pane
        /// content translates with its pane; internal reflow waits for
        /// the model's rebuild), and note the resize event.
        pub fn applyCanvasWidgetSplitFraction(self: *RuntimeView, split_index: usize, requested_fraction: f32) anyerror!?geometry.RectF {
            return self.applyCanvasWidgetSplitFractionMoved(split_index, requested_fraction, true);
        }

        /// The tween-step variant of the fraction apply: the identical
        /// geometric move WITHOUT the resize note. A drag's per-step
        /// echo is the live re-wrap channel (the app rebuilds at every
        /// pointer width); a tween's steps slide already-laid content
        /// under the pane clip, so a per-step echo would resurrect the
        /// per-frame rebuild the tween exists to retire — the tween
        /// notes once at arm (the destination) and once at settle (the
        /// applied fraction), never per step.
        pub fn applyCanvasWidgetSplitFractionSlide(self: *RuntimeView, split_index: usize, requested_fraction: f32) anyerror!?geometry.RectF {
            return self.applyCanvasWidgetSplitFractionMoved(split_index, requested_fraction, false);
        }

        pub fn applyCanvasWidgetSplitFractionMoved(self: *RuntimeView, split_index: usize, requested_fraction: f32, note_resize: bool) anyerror!?geometry.RectF {
            if (split_index >= self.widget_layout_node_count) return null;
            const split_node = self.widget_layout_nodes[split_index];
            if (split_node.widget.kind != .split or split_node.widget.state.disabled) return null;
            if (!std.math.isFinite(requested_fraction)) return null;

            var pane_indices: [2]?usize = .{ null, null };
            var divider_index: ?usize = null;
            var child = split_index + 1;
            const split_depth = split_node.depth;
            while (child < self.widget_layout_node_count and self.widget_layout_nodes[child].depth > split_depth) : (child += 1) {
                if (self.widget_layout_nodes[child].parent_index != split_index) continue;
                const kind = self.widget_layout_nodes[child].widget.kind;
                if (kind == .split_divider) {
                    if (divider_index == null) divider_index = child;
                } else if (pane_indices[0] == null) {
                    pane_indices[0] = child;
                } else if (pane_indices[1] == null) {
                    pane_indices[1] = child;
                }
            }
            const first_index = pane_indices[0] orelse return null;
            const second_index = pane_indices[1] orelse return null;
            const handle_index = divider_index orelse return null;

            const content = split_node.frame.inset(split_node.widget.layout.padding).normalized();
            const divider_extent = self.widget_layout_nodes[handle_index].frame.width;
            const available = @max(0, content.width - divider_extent);
            const first_min = @max(0, self.widget_layout_nodes[first_index].widget.layout.min_size.width);
            const second_min = @max(0, self.widget_layout_nodes[second_index].widget.layout.min_size.width);
            const fraction = canvas.splitEffectiveFraction(@max(requested_fraction, 0.0001), available, first_min, second_min);
            const previous_fraction = canvas.splitEffectiveFraction(self.widget_layout_nodes[handle_index].widget.value, available, first_min, second_min);
            if (fraction == previous_fraction) return null;

            const first_width = available * fraction;
            const divider_x = content.x + first_width;
            const dx = divider_x - self.widget_layout_nodes[handle_index].frame.x;
            if (dx == 0) return null;

            self.widget_layout_nodes[split_index].widget.value = fraction;
            self.widget_layout_nodes[handle_index].widget.value = fraction;
            setCanvasWidgetNodeWidth(&self.widget_layout_nodes[first_index], first_width);
            self.widget_layout_nodes[handle_index].frame.x = divider_x;
            self.widget_layout_nodes[handle_index].widget.frame.x = divider_x;
            const second_x = divider_x + divider_extent;
            const second_width = @max(0, content.maxX() - second_x);
            self.widget_layout_nodes[second_index].frame.x = second_x;
            self.widget_layout_nodes[second_index].widget.frame.x = second_x;
            setCanvasWidgetNodeWidth(&self.widget_layout_nodes[second_index], second_width);
            self.translateCanvasWidgetDescendantsX(second_index, dx);

            if (note_resize) self.noteCanvasWidgetResizeEvent(split_node.widget.id);
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(split_index, split_node.frame);
        }

        /// Note a split whose fraction changed since the last app
        /// dispatch (the resize twin of `noteCanvasWidgetScrollEvent`):
        /// deduped by id, coalesced losslessly — the dispatched event
        /// reads the CURRENT fraction.
        pub fn noteCanvasWidgetResizeEvent(self: *RuntimeView, id: canvas.ObjectId) void {
            if (id == 0) return;
            for (self.widget_resize_event_ids[0..self.widget_resize_event_count]) |pending| {
                if (pending == id) return;
            }
            if (self.widget_resize_event_count >= self.widget_resize_event_ids.len) return;
            self.widget_resize_event_ids[self.widget_resize_event_count] = id;
            self.widget_resize_event_count += 1;
        }

        /// Note a slider whose value changed from a pointer gesture
        /// since the last app dispatch (the change twin of
        /// `noteCanvasWidgetResizeEvent`): deduped by id, coalesced
        /// losslessly — the dispatched event reads the CURRENT value.
        pub fn noteCanvasWidgetChangeEvent(self: *RuntimeView, id: canvas.ObjectId) void {
            if (id == 0) return;
            for (self.widget_change_event_ids[0..self.widget_change_event_count]) |pending| {
                if (pending == id) return;
            }
            if (self.widget_change_event_count >= self.widget_change_event_ids.len) return;
            self.widget_change_event_ids[self.widget_change_event_count] = id;
            self.widget_change_event_count += 1;
        }

        /// Horizontal twin of `translateCanvasWidgetScrollDescendants`:
        /// shift a pane subtree sideways when its pane edge moves.
        pub fn translateCanvasWidgetDescendantsX(self: *RuntimeView, node_index: usize, dx: f32) void {
            const depth = self.widget_layout_nodes[node_index].depth;
            var index = node_index + 1;
            while (index < self.widget_layout_node_count and self.widget_layout_nodes[index].depth > depth) : (index += 1) {
                const translated = self.widget_layout_nodes[index].frame.translate(.{ .dx = dx, .dy = 0 });
                self.widget_layout_nodes[index].frame = translated;
                self.widget_layout_nodes[index].widget.frame = translated;
            }
        }

        pub fn applyCanvasWidgetResizableDelta(self: *RuntimeView, id: canvas.ObjectId, delta_x: f32) anyerror!?geometry.RectF {
            if (!std.math.isFinite(delta_x) or delta_x == 0) return null;
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.kind != .resizable or widget.state.disabled) return null;
            if (!std.math.isFinite(widget.frame.width)) return null;

            const previous_frame = self.widget_layout_nodes[index].frame;
            const min_width = canvasWidgetResizableMinWidth(widget);
            const next_width = @max(min_width, previous_frame.width + delta_x);
            if (next_width == previous_frame.width) return null;

            self.widget_layout_nodes[index].frame.width = next_width;
            self.widget_layout_nodes[index].widget.frame.width = next_width;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            const dirty = unionRects(previous_frame, self.widget_layout_nodes[index].frame) orelse self.widget_layout_nodes[index].frame;
            return self.canvasWidgetDirtyBounds(index, dirty);
        }

        pub fn applyCanvasWidgetControlKeyboard(self: *RuntimeView, id: canvas.ObjectId, keyboard: canvas.WidgetKeyboardEvent) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;

            const intent = canvas.widgetKeyboardControlIntent(widget, keyboard) orelse return null;
            return self.applyCanvasWidgetControlIntent(index, intent);
        }

        pub fn applyCanvasWidgetControlIntent(self: *RuntimeView, index: usize, intent: canvas.WidgetControlIntent) anyerror!?geometry.RectF {
            if (index >= self.widget_layout_node_count) return null;
            const widget = self.widget_layout_nodes[index].widget;
            const id = widget.id;
            return switch (intent.kind) {
                .toggle => blk: {
                    // Tree rows toggle their DISCLOSURE, not selection:
                    // flip the expanded echo (the model owns the real
                    // state through on_toggle; rows appear/disappear on
                    // its rebuild).
                    if (widget.semantics.role == .treeitem) break :blk try self.toggleCanvasWidgetTreeItemExpanded(index);
                    break :blk try self.toggleCanvasWidgetBooleanControl(id);
                },
                .set_value => blk: {
                    const next_value = intent.value orelse break :blk null;
                    // Divider keyboard steps apply to the PARENT split's
                    // fraction (and note the resize event), exactly like
                    // a drag.
                    if (widget.kind == .split_divider) {
                        const split_index = self.widget_layout_nodes[index].parent_index orelse break :blk null;
                        break :blk try self.applyCanvasWidgetSplitFraction(split_index, next_value);
                    }
                    break :blk try self.setCanvasWidgetValue(index, next_value);
                },
                .select => try self.setCanvasWidgetSelected(id, true),
                .scroll_to_start => try self.applyCanvasWidgetScrollKeyboardTarget(index, .start),
                .scroll_to_end => try self.applyCanvasWidgetScrollKeyboardTarget(index, .end),
                .scroll_by => try self.applyCanvasWidgetScroll(index, intent.delta, .discrete, false),
                .press => null,
            };
        }

        /// The expanded-state optimistic echo for a tree row's
        /// collapse/expand intent: semantics report the new state
        /// immediately; the model's rebuild is truth (source wins on
        /// the next layout apply — rows are not reconcile-retained).
        pub fn toggleCanvasWidgetTreeItemExpanded(self: *RuntimeView, index: usize) anyerror!?geometry.RectF {
            if (index >= self.widget_layout_node_count) return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.semantics.role != .treeitem or widget.state.disabled) return null;
            const expanded = widget.state.expanded orelse return null;
            self.widget_layout_nodes[index].widget.state.expanded = !expanded;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, widget.frame);
        }

        /// A pointer gesture on a slider — a click anywhere on the rail
        /// (the thumb jumps to the pressed point, the standard native
        /// scrubber behavior) or a drag continuing from one — maps the
        /// pointer's x to the proportional value and applies it as the
        /// optimistic echo. The change is also NOTED for the app: the
        /// pointer path has no dispatch of its own (releases resolve
        /// press/toggle/select intents, none of which a slider claims,
        /// and keyboard steps dispatch through the keyboard path), so
        /// without the note a rail click would move the thumb visually
        /// while the model never heard `on_change` — a seek bar that
        /// snapped back on the next position tick.
        pub fn applyCanvasWidgetSliderValue(self: *RuntimeView, id: canvas.ObjectId, point: geometry.PointF) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.kind != .slider or widget.state.disabled or widget.frame.width <= 0) return null;

            const next_value = std.math.clamp((point.x - widget.frame.x) / widget.frame.width, 0, 1);
            const dirty = try self.setCanvasWidgetValue(index, next_value) orelse return null;
            self.noteCanvasWidgetChangeEvent(id);
            return dirty;
        }

        pub fn toggleCanvasWidgetBooleanControl(self: *RuntimeView, id: canvas.ObjectId) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if ((widget.kind != .accordion and widget.kind != .checkbox and widget.kind != .toggle_button and widget.kind != .toggle and !canvasWidgetSwitchControlKind(widget.kind)) or widget.state.disabled) return null;

            const selected = canvasWidgetBooleanSelected(widget);
            self.widget_layout_nodes[index].widget.state.selected = !selected;
            self.widget_layout_nodes[index].widget.value = if (!selected) 1 else 0;
            // Disclosure widgets note the toggle for the NEXT rebuild:
            // this optimistic echo already flipped the retained state,
            // so the rebuild-time flip detection that arms the
            // disclosure tween would otherwise see both poses agreeing
            // and skip the animation.
            if (canvas.widgetKindDisclosureAnimated(widget.kind)) {
                self.noteCanvasWidgetDisclosureToggle(widget.id);
            }
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, widget.frame);
        }

        pub fn setCanvasWidgetSelected(self: *RuntimeView, id: canvas.ObjectId, selected: bool) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.state.disabled) return null;
            const tree_row = widget.semantics.role == .treeitem;
            switch (widget.kind) {
                .list_item, .menu_item, .data_cell, .segmented_control, .radio => {},
                else => if (!tree_row) return null,
            }
            // Menu rows split into two registers by what their group
            // DECLARES: a select-style picker marks its committed option
            // `selected`, so activation MOVES that selection (and the
            // checkmark with it); an actions menu declares no committed
            // row, so activation fires the item and mints NO selection —
            // a "Duplicate" row must never come back checked. The group's
            // declared row is the whole distinction; there is no separate
            // menu mode flag.
            if (selected and widget.kind == .menu_item and !canvasWidgetMenuGroupHasCommittedRow(self, index)) return null;

            var dirty: ?geometry.RectF = null;
            var changed = false;
            if (selected and tree_row) {
                // Tree selection is single-select across the WHOLE tree
                // scope (rows nest at any depth, so parent-scoped
                // clearing would leave one selection per level).
                const scope = canvas_widget_runtime.canvasWidgetTreeScopeIndex(self.widgetLayoutTree(), index);
                for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |*node, row_index| {
                    if (row_index == index) continue;
                    if (node.widget.semantics.role != .treeitem) continue;
                    if (canvas_widget_runtime.canvasWidgetTreeScopeIndex(self.widgetLayoutTree(), row_index) != scope) continue;
                    if (!canvasWidgetSelectableSelected(node.widget)) continue;
                    node.widget.state.selected = false;
                    node.widget.value = 0;
                    dirty = unionRects(dirty, self.canvasWidgetDirtyBounds(row_index, node.frame));
                    changed = true;
                }
            } else if (selected and widget.kind == .radio) {
                // A radio group is one logical selection scope even when
                // layout containers wrap its radios. Nearest-ancestor
                // resolution also isolates nested radio groups. A bare
                // radio deliberately falls back to its direct parent.
                const scope = canvas_widget_runtime.canvasWidgetRadioGroupScopeIndex(self.widgetLayoutTree(), index);
                const parent_index = self.widget_layout_nodes[index].parent_index;
                for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |*node, radio_index| {
                    if (radio_index == index or node.widget.kind != .radio) continue;
                    if (scope) |radio_group_index| {
                        if (canvas_widget_runtime.canvasWidgetRadioGroupScopeIndex(self.widgetLayoutTree(), radio_index) != radio_group_index) continue;
                    } else if (node.parent_index != parent_index or canvas_widget_runtime.canvasWidgetRadioGroupScopeIndex(self.widgetLayoutTree(), radio_index) != null) continue;
                    if (!canvasWidgetSelectableSelected(node.widget)) continue;
                    node.widget.state.selected = false;
                    node.widget.value = 0;
                    dirty = unionRects(dirty, self.canvasWidgetDirtyBounds(radio_index, node.frame));
                    changed = true;
                }
            } else if (selected and canvasWidgetSelectionClearsSiblings(widget.kind)) {
                const parent_index = self.widget_layout_nodes[index].parent_index;
                for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |*node, sibling_index| {
                    if (sibling_index == index) continue;
                    if (node.parent_index != parent_index or node.widget.kind != widget.kind) continue;
                    if (!canvasWidgetSelectableSelected(node.widget)) continue;
                    node.widget.state.selected = false;
                    node.widget.value = 0;
                    dirty = unionRects(dirty, self.canvasWidgetDirtyBounds(sibling_index, node.frame));
                    changed = true;
                }
            }

            const target_value: f32 = if (selected) 1 else 0;
            if (self.widget_layout_nodes[index].widget.state.selected != selected or self.widget_layout_nodes[index].widget.value != target_value) {
                dirty = unionRects(dirty, self.canvasWidgetDirtyBounds(index, self.widget_layout_nodes[index].frame));
                changed = true;
            }
            if (!changed) return null;
            self.widget_layout_nodes[index].widget.state.selected = selected;
            self.widget_layout_nodes[index].widget.value = target_value;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return dirty orelse self.widget_layout_nodes[index].frame;
        }

        /// Whether the menu group containing `index` currently has a
        /// committed (selected) row — the item itself or any sibling
        /// menu_item under the same parent. Sibling scope matches the
        /// selection-clearing scope, so the two rules always agree on
        /// what "the group" is.
        fn canvasWidgetMenuGroupHasCommittedRow(self: *const RuntimeView, index: usize) bool {
            const parent_index = self.widget_layout_nodes[index].parent_index;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count]) |*node| {
                if (node.parent_index != parent_index or node.widget.kind != .menu_item) continue;
                if (canvasWidgetSelectableSelected(node.widget)) return true;
            }
            return false;
        }

        pub fn setCanvasWidgetValue(self: *RuntimeView, index: usize, value: f32) anyerror!?geometry.RectF {
            if (index >= self.widget_layout_node_count) return null;
            const widget = self.widget_layout_nodes[index].widget;
            const next_value = std.math.clamp(value, 0, 1);
            if (next_value == widget.value) return null;
            self.widget_layout_nodes[index].widget.value = next_value;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, widget.frame);
        }
    };
}
