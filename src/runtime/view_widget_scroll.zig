const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");

const unionRects = canvas_frame_helpers.unionRects;
const CanvasWidgetScrollKeyboardTarget = canvas_widget_runtime.CanvasWidgetScrollKeyboardTarget;
const canvasWidgetScrollableKind = canvas_widget_runtime.canvasWidgetScrollableKind;

pub const CanvasWidgetScrollSource = enum {
    discrete,
    wheel,
};

/// Virtualized containers whose scroll offset stays MODEL-driven (the
/// legacy contract: children are the full item set, the source `value`
/// is the only offset channel). The engine refuses to scroll these;
/// runtime-scrolled virtual lists (declared item count) take the same
/// engine scroll paths a plain scroll_view does.
fn canvasWidgetModelDrivenVirtual(widget: canvas.Widget) bool {
    return widget.layout.virtualized and !canvas.widgetVirtualRuntimeScrolled(widget);
}

pub fn RuntimeViewCanvasWidgetScroll(comptime RuntimeView: type) type {
    return struct {
        pub fn canvasWidgetKineticScrollActive(self: *const RuntimeView) bool {
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                if (node.widget.kind != .scroll_view or canvasWidgetModelDrivenVirtual(node.widget)) continue;
                // Native drivers own momentum + rubber-band recovery.
                if (node.widget.native_scroll) continue;
                const viewport = node.frame.inset(node.widget.layout.padding).normalized();
                if (viewport.isEmpty()) continue;
                const physics = canvas.widgetScrollPhysics(node.widget, self.widget_tokens.scroll);
                if (self.canvasWidgetScrollState(index, node, viewport).needsKineticStep(physics)) return true;
            }
            return false;
        }

        pub fn applyCanvasWidgetScrollRoute(self: *RuntimeView, route: []const canvas.WidgetEventRouteEntry, delta_y: f32, source: CanvasWidgetScrollSource) anyerror!?geometry.RectF {
            var depth_limit: ?usize = null;
            while (self.deepestCanvasWidgetScrollIndex(route, depth_limit)) |scroll_index| {
                if (canvasWidgetModelDrivenVirtual(self.widget_layout_nodes[scroll_index].widget)) return null;
                const has_scroll_parent = self.deepestCanvasWidgetScrollIndex(route, self.widget_layout_nodes[scroll_index].depth) != null;
                if (has_scroll_parent and !self.canvasWidgetScrollCanConsume(scroll_index, delta_y)) {
                    depth_limit = self.widget_layout_nodes[scroll_index].depth;
                    continue;
                }
                if (try self.applyCanvasWidgetScroll(scroll_index, delta_y, source, !has_scroll_parent)) |dirty| return dirty;
                depth_limit = self.widget_layout_nodes[scroll_index].depth;
            }
            return null;
        }

        pub fn deepestCanvasWidgetScrollIndex(self: *const RuntimeView, route: []const canvas.WidgetEventRouteEntry, depth_limit: ?usize) ?usize {
            var result: ?usize = null;
            var result_depth: usize = 0;
            for (route) |entry| {
                if (!canvasWidgetScrollableKind(entry.kind) or entry.node_index >= self.widget_layout_node_count) continue;
                const depth = self.widget_layout_nodes[entry.node_index].depth;
                if (depth_limit) |limit| {
                    if (depth >= limit) continue;
                }
                if (result == null or depth > result_depth) {
                    result = entry.node_index;
                    result_depth = depth;
                }
            }
            return result;
        }

        /// Record a scroll offset change for app observation: the pending
        /// set is drained into `canvas_widget_scroll` events at the next
        /// gpu-surface dispatch point. Deduped by node id — the event
        /// reads the current state, so coalescing repeated motion on one
        /// node is lossless. Ids past the fixed bound are dropped (the
        /// scroll itself still applies and repaints).
        pub fn noteCanvasWidgetScrollEvent(self: *RuntimeView, id: canvas.ObjectId) void {
            if (id == 0) return;
            for (self.widget_scroll_event_ids[0..self.widget_scroll_event_count]) |existing| {
                if (existing == id) return;
            }
            if (self.widget_scroll_event_count >= self.widget_scroll_event_ids.len) return;
            self.widget_scroll_event_ids[self.widget_scroll_event_count] = id;
            self.widget_scroll_event_count += 1;
        }

        /// Current scroll state of the scroll container with `id`, or null
        /// when the id is not a mounted, measurable scroll view. Feeds the
        /// `canvas_widget_scroll` event payload.
        pub fn canvasWidgetScrollStateById(self: *const RuntimeView, id: canvas.ObjectId) ?canvas.ScrollState {
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                if (node.widget.id != id) continue;
                if (node.widget.kind != .scroll_view) return null;
                const viewport = node.frame.inset(node.widget.layout.padding).normalized();
                if (viewport.isEmpty()) return null;
                return self.canvasWidgetScrollState(index, node, viewport);
            }
            return null;
        }

        pub fn canvasWidgetScrollState(self: *const RuntimeView, scroll_index: usize, scroll_node: canvas.WidgetLayoutNode, viewport: geometry.RectF) canvas.ScrollState {
            const retained = self.widget_scroll_states[scroll_index];
            return .{
                .offset = scroll_node.widget.value,
                .velocity = retained.velocity,
                .viewport_extent = viewport.height,
                .content_extent = self.canvasWidgetScrollContentExtent(scroll_index, viewport),
            };
        }

        pub fn canvasWidgetScrollCanConsume(self: *const RuntimeView, scroll_index: usize, delta_y: f32) bool {
            if (scroll_index >= self.widget_layout_node_count or delta_y == 0) return false;
            const scroll_node = self.widget_layout_nodes[scroll_index];
            if (!canvasWidgetScrollableKind(scroll_node.widget.kind)) return false;
            if (canvasWidgetModelDrivenVirtual(scroll_node.widget)) return false;

            if (scroll_node.widget.kind == .textarea) {
                const max_offset = canvas.textInputMaxScrollOffsetForWidget(scroll_node.widget, self.widget_tokens);
                if (max_offset <= 0) return false;
                const current_offset = std.math.clamp(scroll_node.widget.value, 0, max_offset);
                return if (delta_y > 0) current_offset < max_offset else current_offset > 0;
            }

            const viewport = scroll_node.frame.inset(scroll_node.widget.layout.padding).normalized();
            if (viewport.isEmpty()) return false;

            const current = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport);
            const max_offset = current.maxOffset();
            if (current.offset < 0) return delta_y > 0;
            if (current.offset > max_offset) return delta_y < 0;
            return if (delta_y > 0) current.offset < max_offset else current.offset > 0;
        }

        pub fn applyCanvasWidgetScroll(self: *RuntimeView, scroll_index: usize, delta_y: f32, source: CanvasWidgetScrollSource, allow_rubberband: bool) anyerror!?geometry.RectF {
            if (scroll_index >= self.widget_layout_node_count) return null;
            const scroll_node = self.widget_layout_nodes[scroll_index];
            if (!canvasWidgetScrollableKind(scroll_node.widget.kind)) return null;
            if (scroll_node.widget.kind == .textarea) return self.applyCanvasWidgetTextareaScroll(scroll_index, delta_y, source);
            if (canvasWidgetModelDrivenVirtual(scroll_node.widget)) return null;

            const viewport = scroll_node.frame.inset(scroll_node.widget.layout.padding).normalized();
            if (viewport.isEmpty()) return null;

            const current = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport);
            // Per-region edge behavior: the region's overscroll override
            // resolved onto the scroll-physics token (off by default —
            // `applyWheel` clamps unless the effective mode is
            // rubber_band). Native-driven regions and nested-scroll
            // handoff take wheel input clamped regardless: a native
            // region's rubber-band recovery lives in the OS scroller, so
            // an engine overscroll here would have no kinetic step to
            // pull it back.
            const physics = canvas.widgetScrollPhysics(scroll_node.widget, self.widget_tokens.scroll);
            const rubberband = allow_rubberband and !scroll_node.widget.native_scroll;
            const next = switch (source) {
                .wheel => if (rubberband)
                    current.applyWheel(delta_y, physics)
                else
                    current.applyWheelClamped(delta_y, physics),
                .discrete => discrete: {
                    var state = current;
                    state.offset += delta_y;
                    state.velocity = 0;
                    break :discrete state.clamped();
                },
            };
            self.widget_scroll_states[scroll_index] = next;
            if (next.offset == current.offset) return null;

            const offset_delta = next.offset - current.offset;
            self.widget_layout_nodes[scroll_index].widget.value = next.offset;
            self.translateCanvasWidgetScrollDescendants(scroll_index, -offset_delta);
            self.noteCanvasWidgetScrollEvent(scroll_node.widget.id);

            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(scroll_index, scroll_node.frame);
        }

        pub fn applyCanvasWidgetTextareaScroll(self: *RuntimeView, scroll_index: usize, delta_y: f32, source: CanvasWidgetScrollSource) anyerror!?geometry.RectF {
            if (scroll_index >= self.widget_layout_node_count) return null;
            const widget = self.widget_layout_nodes[scroll_index].widget;
            if (widget.kind != .textarea) return null;

            const viewport = canvas.textInputViewportForWidget(widget, self.widget_tokens) orelse return null;
            const current = canvas.ScrollState{
                .offset = canvas.clampedTextInputScrollOffsetForWidget(widget, self.widget_tokens, widget.value),
                .viewport_extent = viewport.height,
                .content_extent = canvas.textInputContentExtentForWidget(widget, self.widget_tokens),
            };
            const next = switch (source) {
                .wheel => current.applyWheelClamped(delta_y, self.widget_tokens.scroll),
                .discrete => discrete: {
                    var state = current;
                    state.offset += delta_y;
                    state.velocity = 0;
                    break :discrete state.clamped();
                },
            };
            if (next.offset == current.offset) return null;

            self.widget_layout_nodes[scroll_index].widget.value = next.offset;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(scroll_index, widget.frame);
        }

        /// Absolute offset write from a native scroll driver: the OS
        /// scroller computed the offset (momentum, rubber-band — overscroll
        /// values pass through so the bounce is visible), the engine just
        /// follows. Engine velocity is zeroed; the driver owns physics.
        pub fn applyCanvasWidgetScrollDriverOffset(self: *RuntimeView, scroll_index: usize, offset: f32) anyerror!?geometry.RectF {
            if (scroll_index >= self.widget_layout_node_count) return null;
            const scroll_node = self.widget_layout_nodes[scroll_index];
            if (scroll_node.widget.kind != .scroll_view or canvasWidgetModelDrivenVirtual(scroll_node.widget)) return null;

            const viewport = scroll_node.frame.inset(scroll_node.widget.layout.padding).normalized();
            if (viewport.isEmpty()) return null;

            const current = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport);
            var next = current;
            next.offset = offset;
            next.velocity = 0;
            self.widget_scroll_states[scroll_index] = next;
            if (next.offset == current.offset) return null;

            const offset_delta = next.offset - current.offset;
            self.widget_layout_nodes[scroll_index].widget.value = next.offset;
            self.translateCanvasWidgetScrollDescendants(scroll_index, -offset_delta);
            self.noteCanvasWidgetScrollEvent(scroll_node.widget.id);

            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(scroll_index, scroll_node.frame);
        }

        pub fn applyCanvasWidgetScrollKeyboardTarget(self: *RuntimeView, scroll_index: usize, target: CanvasWidgetScrollKeyboardTarget) anyerror!?geometry.RectF {
            if (scroll_index >= self.widget_layout_node_count) return null;
            const scroll_node = self.widget_layout_nodes[scroll_index];
            if (scroll_node.widget.kind != .scroll_view or canvasWidgetModelDrivenVirtual(scroll_node.widget)) return null;

            const viewport = scroll_node.frame.inset(scroll_node.widget.layout.padding).normalized();
            if (viewport.isEmpty()) return null;

            const current = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport);
            var next = current;
            next.offset = switch (target) {
                .start => 0,
                .end => current.maxOffset(),
            };
            next.velocity = 0;
            next = next.clamped();
            self.widget_scroll_states[scroll_index] = next;
            if (next.offset == current.offset) return null;

            const offset_delta = next.offset - current.offset;
            self.widget_layout_nodes[scroll_index].widget.value = next.offset;
            self.translateCanvasWidgetScrollDescendants(scroll_index, -offset_delta);
            self.noteCanvasWidgetScrollEvent(scroll_node.widget.id);

            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(scroll_index, scroll_node.frame);
        }

        pub fn stepCanvasWidgetKineticScroll(self: *RuntimeView, dt_ms: f32) anyerror!?geometry.RectF {
            var dirty: ?geometry.RectF = null;
            var changed = false;

            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |scroll_node, scroll_index| {
                if (scroll_node.widget.kind != .scroll_view or canvasWidgetModelDrivenVirtual(scroll_node.widget)) continue;
                // Native drivers own momentum + rubber-band recovery.
                if (scroll_node.widget.native_scroll) continue;

                const viewport = scroll_node.frame.inset(scroll_node.widget.layout.padding).normalized();
                if (viewport.isEmpty()) {
                    self.widget_scroll_states[scroll_index].velocity = 0;
                    continue;
                }

                const physics = canvas.widgetScrollPhysics(scroll_node.widget, self.widget_tokens.scroll);
                const current = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport);
                if (!current.needsKineticStep(physics)) {
                    self.widget_scroll_states[scroll_index].velocity = 0;
                    continue;
                }

                const next = current.stepKinetic(dt_ms, physics);
                self.widget_scroll_states[scroll_index] = next;
                if (next.offset == current.offset) continue;

                const offset_delta = next.offset - current.offset;
                self.widget_layout_nodes[scroll_index].widget.value = next.offset;
                self.translateCanvasWidgetScrollDescendants(scroll_index, -offset_delta);
                self.noteCanvasWidgetScrollEvent(scroll_node.widget.id);
                dirty = unionRects(dirty, self.canvasWidgetDirtyBounds(scroll_index, scroll_node.frame));
                changed = true;
            }

            if (!changed) return null;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return dirty;
        }

        pub fn canvasWidgetScrollContentExtent(self: *const RuntimeView, scroll_index: usize, viewport: geometry.RectF) f32 {
            if (scroll_index < self.widget_layout_node_count and self.widget_layout_nodes[scroll_index].widget.kind == .textarea) {
                return canvas.textInputContentExtentForWidget(self.widget_layout_nodes[scroll_index].widget, self.widget_tokens);
            }
            // Virtualized containers derive their extent from the item
            // count and extent (declared count for windowed virtual
            // lists), never from the mounted descendants — walking the
            // built window would collapse the extent to the window.
            if (scroll_index < self.widget_layout_node_count and self.widget_layout_nodes[scroll_index].widget.layout.virtualized) {
                return @max(viewport.height, canvas.virtualWidgetScrollContentExtentWithTokens(self.widget_layout_nodes[scroll_index].widget, viewport.height, self.widget_tokens));
            }
            const scroll_depth = self.widget_layout_nodes[scroll_index].depth;
            const offset = self.widget_layout_nodes[scroll_index].widget.value;
            var bottom = viewport.maxY();
            var index = scroll_index + 1;
            while (index < self.widget_layout_node_count and self.widget_layout_nodes[index].depth > scroll_depth) : (index += 1) {
                bottom = @max(bottom, self.widget_layout_nodes[index].frame.maxY() + offset);
            }
            return @max(0, bottom - viewport.y);
        }

        pub fn translateCanvasWidgetScrollDescendants(self: *RuntimeView, scroll_index: usize, dy: f32) void {
            const scroll_depth = self.widget_layout_nodes[scroll_index].depth;
            var index = scroll_index + 1;
            while (index < self.widget_layout_node_count and self.widget_layout_nodes[index].depth > scroll_depth) : (index += 1) {
                const translated = self.widget_layout_nodes[index].frame.translate(.{ .dx = 0, .dy = dy });
                self.widget_layout_nodes[index].frame = translated;
                self.widget_layout_nodes[index].widget.frame = translated;
            }
        }

        pub fn scrollCanvasTextareaCaretIntoView(self: *RuntimeView, index: usize) void {
            if (index >= self.widget_layout_node_count) return;
            var widget = self.widget_layout_nodes[index].widget;
            if (widget.kind != .textarea) return;

            const viewport = canvas.textInputViewportForWidget(widget, self.widget_tokens) orelse return;
            const geometry_value = canvas.textGeometryForWidget(widget, self.widget_tokens);
            const caret = geometry_value.caret_bounds orelse return;

            var next_offset = canvas.clampedTextInputScrollOffsetForWidget(widget, self.widget_tokens, widget.value);
            const padding: f32 = 2;
            if (caret.y < viewport.y) {
                next_offset -= viewport.y - caret.y + padding;
            } else if (caret.maxY() > viewport.maxY()) {
                next_offset += caret.maxY() - viewport.maxY() + padding;
            }
            next_offset = canvas.clampedTextInputScrollOffsetForWidget(widget, self.widget_tokens, next_offset);
            if (next_offset == widget.value) return;
            widget.value = next_offset;
            self.widget_layout_nodes[index].widget.value = next_offset;
        }
    };
}
