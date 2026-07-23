const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");

const unionRects = canvas_frame_helpers.unionRects;
const CanvasWidgetScrollKeyboardTarget = canvas_widget_runtime.CanvasWidgetScrollKeyboardTarget;
const canvasWidgetScrollableKind = canvas_widget_runtime.canvasWidgetScrollableKind;
const canvasWidgetSingleLineTextKind = canvas_widget_runtime.canvasWidgetSingleLineTextKind;

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

fn unionOptionalRects(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    const first = a orelse return b;
    const second = b orelse return first;
    return unionRects(first, second);
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
                const state = self.canvasWidgetScrollState(index, node, viewport);
                if (canvas.widgetScrollsAxis(node.widget, .vertical) and state.axis(.vertical).needsKineticStep(physics)) return true;
                if (canvas.widgetScrollsAxis(node.widget, .horizontal) and state.axis(.horizontal).needsKineticStep(physics)) return true;
            }
            return false;
        }

        /// Route a wheel/trackpad scroll: EACH AXIS resolves
        /// independently to the nearest ancestor scrollable on that
        /// axis. A horizontal timeline holding a vertical list splits a
        /// diagonal gesture — `dy` scrolls the list, `dx` reaches the
        /// timeline — and a vertical-only tree behaves byte-identically
        /// to the one-axis routing this generalizes (every scrollable
        /// there grants the vertical axis and nothing grants the
        /// horizontal one). Both axes route even at delta 0: a wheel
        /// event has always overwritten the landing region's velocity,
        /// so a purely horizontal gesture stills a vertical flick the
        /// same way a zero-delta vertical wheel did.
        pub fn applyCanvasWidgetScrollRoute(self: *RuntimeView, route: []const canvas.WidgetEventRouteEntry, delta: geometry.OffsetF, source: CanvasWidgetScrollSource) anyerror!?geometry.RectF {
            const vertical = try applyCanvasWidgetScrollAxisRoute(self, route, .vertical, delta.dy, source);
            const horizontal = try applyCanvasWidgetScrollAxisRoute(self, route, .horizontal, delta.dx, source);
            return unionOptionalRects(vertical, horizontal);
        }

        fn applyCanvasWidgetScrollAxisRoute(self: *RuntimeView, route: []const canvas.WidgetEventRouteEntry, comptime axis: canvas.ScrollAxis, delta: f32, source: CanvasWidgetScrollSource) anyerror!?geometry.RectF {
            var depth_limit: ?usize = null;
            while (self.deepestCanvasWidgetScrollIndexForAxis(route, axis, depth_limit)) |scroll_index| {
                if (canvasWidgetModelDrivenVirtual(self.widget_layout_nodes[scroll_index].widget)) return null;
                const has_scroll_parent = self.deepestCanvasWidgetScrollIndexForAxis(route, axis, self.widget_layout_nodes[scroll_index].depth) != null;
                if (has_scroll_parent and !self.canvasWidgetScrollCanConsumeAxis(scroll_index, axis, delta)) {
                    depth_limit = self.widget_layout_nodes[scroll_index].depth;
                    continue;
                }
                if (try self.applyCanvasWidgetScrollAxis(scroll_index, axis, delta, source, !has_scroll_parent)) |dirty| return dirty;
                depth_limit = self.widget_layout_nodes[scroll_index].depth;
            }
            return null;
        }

        pub fn deepestCanvasWidgetScrollIndex(self: *const RuntimeView, route: []const canvas.WidgetEventRouteEntry, depth_limit: ?usize) ?usize {
            return self.deepestCanvasWidgetScrollIndexForAxis(route, .vertical, depth_limit);
        }

        /// The deepest routed widget that scrolls on `axis`. The axis
        /// filter is what makes per-axis routing independent: a
        /// vertical-only list is invisible to the horizontal walk, so
        /// `dx` passes through it to the horizontal ancestor.
        pub fn deepestCanvasWidgetScrollIndexForAxis(self: *const RuntimeView, route: []const canvas.WidgetEventRouteEntry, comptime axis: canvas.ScrollAxis, depth_limit: ?usize) ?usize {
            var result: ?usize = null;
            var result_depth: usize = 0;
            for (route) |entry| {
                if (!canvasWidgetScrollableKind(entry.kind) or entry.node_index >= self.widget_layout_node_count) continue;
                if (!canvas.widgetScrollsAxis(self.widget_layout_nodes[entry.node_index].widget, axis)) continue;
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

        /// The region's two-axis scroll state. An axis the region does
        /// not grant is QUIET: offset and velocity 0 and the content
        /// extent pinned to the viewport, so `on_scroll` consumers and
        /// the routing/consume checks read `maxOffset() == 0` — never a
        /// falsely scrollable inactive axis (a vertical list whose rows
        /// happen to overhang sideways stays horizontally inert).
        pub fn canvasWidgetScrollState(self: *const RuntimeView, scroll_index: usize, scroll_node: canvas.WidgetLayoutNode, viewport: geometry.RectF) canvas.ScrollState {
            const retained = self.widget_scroll_states[scroll_index];
            const vertical = canvas.widgetScrollsAxis(scroll_node.widget, .vertical);
            const horizontal = canvas.widgetScrollsAxis(scroll_node.widget, .horizontal);
            return .{
                .offset_y = if (vertical) scroll_node.widget.value else 0,
                .offset_x = if (horizontal) scroll_node.widget.value_x else 0,
                .velocity_y = if (vertical) retained.velocity_y else 0,
                .velocity_x = if (horizontal) retained.velocity_x else 0,
                .viewport_extent_y = viewport.height,
                .viewport_extent_x = viewport.width,
                .content_extent_y = if (vertical) self.canvasWidgetScrollContentExtent(scroll_index, viewport) else viewport.height,
                .content_extent_x = if (horizontal) self.canvasWidgetScrollContentExtentX(scroll_index, viewport) else viewport.width,
            };
        }

        pub fn canvasWidgetScrollCanConsumeAxis(self: *const RuntimeView, scroll_index: usize, comptime axis: canvas.ScrollAxis, delta: f32) bool {
            if (scroll_index >= self.widget_layout_node_count or delta == 0) return false;
            const scroll_node = self.widget_layout_nodes[scroll_index];
            if (!canvasWidgetScrollableKind(scroll_node.widget.kind)) return false;
            if (canvasWidgetModelDrivenVirtual(scroll_node.widget)) return false;
            if (!canvas.widgetScrollsAxis(scroll_node.widget, axis)) return false;

            if (scroll_node.widget.kind == .textarea) {
                const max_offset = canvas.textInputMaxScrollOffsetForWidget(scroll_node.widget, self.widget_tokens);
                if (max_offset <= 0) return false;
                const current_offset = std.math.clamp(scroll_node.widget.value, 0, max_offset);
                return if (delta > 0) current_offset < max_offset else current_offset > 0;
            }

            const viewport = scroll_node.frame.inset(scroll_node.widget.layout.padding).normalized();
            if (viewport.isEmpty()) return false;

            const current = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport).axis(axis);
            const max_offset = current.maxOffset();
            if (current.offset < 0) return delta > 0;
            if (current.offset > max_offset) return delta < 0;
            return if (delta > 0) current.offset < max_offset else current.offset > 0;
        }

        pub fn applyCanvasWidgetScroll(self: *RuntimeView, scroll_index: usize, delta: geometry.OffsetF, source: CanvasWidgetScrollSource, allow_rubberband: bool) anyerror!?geometry.RectF {
            const vertical = try self.applyCanvasWidgetScrollAxis(scroll_index, .vertical, delta.dy, source, allow_rubberband);
            const horizontal = try self.applyCanvasWidgetScrollAxis(scroll_index, .horizontal, delta.dx, source, allow_rubberband);
            return unionOptionalRects(vertical, horizontal);
        }

        pub fn applyCanvasWidgetScrollAxis(self: *RuntimeView, scroll_index: usize, comptime axis: canvas.ScrollAxis, delta: f32, source: CanvasWidgetScrollSource, allow_rubberband: bool) anyerror!?geometry.RectF {
            if (scroll_index >= self.widget_layout_node_count) return null;
            const scroll_node = self.widget_layout_nodes[scroll_index];
            if (!canvasWidgetScrollableKind(scroll_node.widget.kind)) return null;
            if (scroll_node.widget.kind == .textarea) {
                if (axis != .vertical) return null;
                return self.applyCanvasWidgetTextareaScroll(scroll_index, delta, source);
            }
            if (canvasWidgetModelDrivenVirtual(scroll_node.widget)) return null;
            if (!canvas.widgetScrollsAxis(scroll_node.widget, axis)) return null;

            const viewport = scroll_node.frame.inset(scroll_node.widget.layout.padding).normalized();
            if (viewport.isEmpty()) return null;

            const state = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport);
            const current = state.axis(axis);
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
                    current.applyWheel(delta, physics)
                else
                    current.applyWheelClamped(delta, physics),
                .discrete => discrete: {
                    var axis_state = current;
                    axis_state.offset += delta;
                    axis_state.velocity = 0;
                    break :discrete axis_state.clamped();
                },
            };
            self.widget_scroll_states[scroll_index] = state.withAxis(axis, next);
            if (next.offset == current.offset) return null;

            const offset_delta = next.offset - current.offset;
            switch (axis) {
                .vertical => {
                    self.widget_layout_nodes[scroll_index].widget.value = next.offset;
                    self.translateCanvasWidgetScrollDescendants(scroll_index, .{ .dy = -offset_delta });
                },
                .horizontal => {
                    self.widget_layout_nodes[scroll_index].widget.value_x = next.offset;
                    self.translateCanvasWidgetScrollDescendants(scroll_index, .{ .dx = -offset_delta });
                },
            }
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
            const current = canvas.ScrollAxisState{
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
        /// scroller computed the offsets (momentum, rubber-band — overscroll
        /// values pass through so the bounce is visible), the engine just
        /// follows. Engine velocity is zeroed; the driver owns physics.
        pub fn applyCanvasWidgetScrollDriverOffset(self: *RuntimeView, scroll_index: usize, offset_x: f32, offset_y: f32) anyerror!?geometry.RectF {
            if (scroll_index >= self.widget_layout_node_count) return null;
            const scroll_node = self.widget_layout_nodes[scroll_index];
            if (scroll_node.widget.kind != .scroll_view or canvasWidgetModelDrivenVirtual(scroll_node.widget)) return null;

            const viewport = scroll_node.frame.inset(scroll_node.widget.layout.padding).normalized();
            if (viewport.isEmpty()) return null;

            const current = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport);
            var next = current;
            // Driver offsets land only on axes the region grants: the
            // sync pins the native scroller's range on ungranted axes,
            // and a stray report there must not displace content.
            if (canvas.widgetScrollsAxis(scroll_node.widget, .vertical)) {
                next.offset_y = offset_y;
                next.velocity_y = 0;
            }
            if (canvas.widgetScrollsAxis(scroll_node.widget, .horizontal)) {
                next.offset_x = offset_x;
                next.velocity_x = 0;
            }
            self.widget_scroll_states[scroll_index] = next;
            if (next.offset_y == current.offset_y and next.offset_x == current.offset_x) return null;

            const offset_delta = geometry.OffsetF.init(next.offset_x - current.offset_x, next.offset_y - current.offset_y);
            self.widget_layout_nodes[scroll_index].widget.value = next.offset_y;
            self.widget_layout_nodes[scroll_index].widget.value_x = next.offset_x;
            self.translateCanvasWidgetScrollDescendants(scroll_index, .{ .dx = -offset_delta.dx, .dy = -offset_delta.dy });
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

            // Home/End land at the content origin/terminus on EVERY axis
            // the region grants: a vertical list jumps top/bottom exactly
            // as before, a horizontal shelf jumps to its left/right edge,
            // and a freely scrolling region jumps to the corner (the
            // NSScrollView document begin/end convention).
            const current = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport);
            var next = current;
            if (canvas.widgetScrollsAxis(scroll_node.widget, .vertical)) {
                var axis_state = current.axis(.vertical);
                axis_state.offset = switch (target) {
                    .start => 0,
                    .end => axis_state.maxOffset(),
                };
                axis_state.velocity = 0;
                next = next.withAxis(.vertical, axis_state.clamped());
            }
            if (canvas.widgetScrollsAxis(scroll_node.widget, .horizontal)) {
                var axis_state = current.axis(.horizontal);
                axis_state.offset = switch (target) {
                    .start => 0,
                    .end => axis_state.maxOffset(),
                };
                axis_state.velocity = 0;
                next = next.withAxis(.horizontal, axis_state.clamped());
            }
            self.widget_scroll_states[scroll_index] = next;
            if (next.offset_y == current.offset_y and next.offset_x == current.offset_x) return null;

            self.widget_layout_nodes[scroll_index].widget.value = next.offset_y;
            self.widget_layout_nodes[scroll_index].widget.value_x = next.offset_x;
            self.translateCanvasWidgetScrollDescendants(scroll_index, .{
                .dx = -(next.offset_x - current.offset_x),
                .dy = -(next.offset_y - current.offset_y),
            });
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
                    self.widget_scroll_states[scroll_index].velocity_y = 0;
                    self.widget_scroll_states[scroll_index].velocity_x = 0;
                    continue;
                }

                const physics = canvas.widgetScrollPhysics(scroll_node.widget, self.widget_tokens.scroll);
                const current = self.canvasWidgetScrollState(scroll_index, scroll_node, viewport);
                var next = current;
                var moved = geometry.OffsetF{};

                if (canvas.widgetScrollsAxis(scroll_node.widget, .vertical)) {
                    const current_y = current.axis(.vertical);
                    if (current_y.needsKineticStep(physics)) {
                        const next_y = current_y.stepKinetic(dt_ms, physics);
                        next = next.withAxis(.vertical, next_y);
                        moved.dy = next_y.offset - current_y.offset;
                    } else {
                        next.velocity_y = 0;
                    }
                } else {
                    next.velocity_y = 0;
                }

                if (canvas.widgetScrollsAxis(scroll_node.widget, .horizontal)) {
                    const current_x = current.axis(.horizontal);
                    if (current_x.needsKineticStep(physics)) {
                        const next_x = current_x.stepKinetic(dt_ms, physics);
                        next = next.withAxis(.horizontal, next_x);
                        moved.dx = next_x.offset - current_x.offset;
                    } else {
                        next.velocity_x = 0;
                    }
                } else {
                    next.velocity_x = 0;
                }

                self.widget_scroll_states[scroll_index] = next;
                if (moved.dx == 0 and moved.dy == 0) continue;

                self.widget_layout_nodes[scroll_index].widget.value = next.offset_y;
                self.widget_layout_nodes[scroll_index].widget.value_x = next.offset_x;
                self.translateCanvasWidgetScrollDescendants(scroll_index, .{ .dx = -moved.dx, .dy = -moved.dy });
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

        /// The horizontal content extent: how far the region's mounted
        /// descendants reach rightward, rebased to offset 0. Textareas
        /// and virtualized containers never scroll horizontally, so
        /// their horizontal content pins to the viewport width. Closed
        /// disclosure subtrees are skipped — concealed content lays out
        /// at full size and must not inflate the scrollable range on
        /// either axis (the semantics walker applies the same rule).
        pub fn canvasWidgetScrollContentExtentX(self: *const RuntimeView, scroll_index: usize, viewport: geometry.RectF) f32 {
            if (scroll_index < self.widget_layout_node_count and
                (self.widget_layout_nodes[scroll_index].widget.kind == .textarea or self.widget_layout_nodes[scroll_index].widget.layout.virtualized))
            {
                return viewport.width;
            }
            return canvas_widget_runtime.canvasWidgetLayoutScrollContentExtentX(
                self.widget_layout_nodes[0..self.widget_layout_node_count],
                scroll_index,
                viewport,
            );
        }

        pub fn translateCanvasWidgetScrollDescendants(self: *RuntimeView, scroll_index: usize, offset: geometry.OffsetF) void {
            const scroll_depth = self.widget_layout_nodes[scroll_index].depth;
            var index = scroll_index + 1;
            while (index < self.widget_layout_node_count and self.widget_layout_nodes[index].depth > scroll_depth) : (index += 1) {
                const translated = self.widget_layout_nodes[index].frame.translate(offset);
                self.widget_layout_nodes[index].frame = translated;
                self.widget_layout_nodes[index].widget.frame = translated;
            }
        }

        /// Keep the editable field's caret inside its visible span after
        /// a text or caret change: textareas scroll vertically, single-
        /// line fields horizontally — both through the widget's retained
        /// `value` offset channel.
        pub fn scrollCanvasTextInputCaretIntoView(self: *RuntimeView, index: usize) void {
            if (index >= self.widget_layout_node_count) return;
            var widget = self.widget_layout_nodes[index].widget;
            if (canvasWidgetSingleLineTextKind(widget.kind)) {
                const next_offset = canvas.textInputCaretVisibleScrollOffsetForWidget(widget, self.widget_tokens, widget.value);
                if (next_offset == widget.value) return;
                self.widget_layout_nodes[index].widget.value = next_offset;
                return;
            }
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
