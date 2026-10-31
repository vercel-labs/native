//! Storage, numeric and geometry capabilities for compiled scroll programs.
const canvas = @import("canvas");
const geometry = @import("geometry");
const programs = @import("scroll_mutation_policy.zig");

pub const Outcome = struct { dirty: ?geometry.RectF = null, changed: bool = false };

pub fn run(self: anytype, policy: programs.Policy, comptime mode: programs.Mode, index: usize, comptime axis: canvas.ScrollAxis, source: u8, delta: f32, offset_x: f32, offset_y: f32, allow_rubberband: bool) anyerror!Outcome {
    var facts: u32 = if (allow_rubberband) 128 else 0;
    var node: canvas.WidgetLayoutNode = undefined;
    if (index < self.widget_layout_node_count) {
        node = self.widget_layout_nodes[index];
        facts |= programs.nodeFacts(node);
    }
    var viewport: geometry.RectF = undefined;
    var current: canvas.ScrollState = undefined;
    var next: canvas.ScrollState = undefined;
    var current_axis: canvas.ScrollAxisState = undefined;
    var next_axis: canvas.ScrollAxisState = undefined;
    var physics: canvas.ScrollPhysics = undefined;
    var moved = geometry.OffsetF{};
    var dirty: ?geometry.RectF = null;
    var phase: u8 = 0;
    while (true) {
        const program = programs.plan(policy, mode, phase, source, axis == .vertical, facts);
        for (0..program.count) |i| switch (program.instruction(i)) {
            .viewport => {
                viewport = node.frame.inset(node.widget.layout.padding).normalized();
                if (!viewport.isEmpty()) facts |= 256;
            },
            .textarea_viewport => {
                if (canvas.textInputViewportForWidget(node.widget, self.widget_tokens)) |value| {
                    viewport = value;
                    facts |= 256;
                }
            },
            .region_state => {
                if (mode == .kinetic) physics = canvas.widgetScrollPhysics(node.widget, self.widget_tokens.scroll);
                current = self.canvasWidgetScrollState(index, node, viewport);
                if (mode == .axis) physics = canvas.widgetScrollPhysics(node.widget, self.widget_tokens.scroll);
                next = current;
                current_axis = current.axis(axis);
            },
            .textarea_state => {
                const vertical = axis == .vertical;
                current_axis = .{
                    .offset = if (vertical) canvas.clampedTextInputScrollOffsetForWidget(node.widget, self.widget_tokens, node.widget.value) else canvas.clampedTextInputHorizontalScrollOffsetForWidget(node.widget, self.widget_tokens, node.widget.value_x),
                    .viewport_extent = if (vertical) viewport.height else viewport.width,
                    .content_extent = if (vertical) canvas.textInputContentExtentForWidget(node.widget, self.widget_tokens) else canvas.textInputContentWidthForWidget(node.widget, self.widget_tokens),
                };
                physics = self.widget_tokens.scroll;
            },
            .delegate_textarea => return run(self, policy, .textarea, index, axis, source, delta, 0, 0, false),
            .wheel => next_axis = current_axis.applyWheel(delta, physics),
            .wheel_clamped => next_axis = current_axis.applyWheelClamped(delta, physics),
            .discrete => {
                next_axis = current_axis;
                if (mode == .axis) {
                    if (canvas.widgetCompiledScrollResult(node.widget, .{ .operation = 1, .current = current_axis.offset, .viewport = current_axis.viewport_extent, .content = current_axis.content_extent, .delta = delta })) |result| {
                        next_axis.offset = result.dx;
                        next_axis.velocity = 0;
                    } else {
                        next_axis.offset += delta;
                        next_axis.velocity = 0;
                        next_axis = next_axis.clamped();
                    }
                } else {
                    next_axis.offset += delta;
                    next_axis.velocity = 0;
                    next_axis = next_axis.clamped();
                }
            },
            .zero_velocity => next_axis.velocity = 0,
            .store_axis => {
                self.widget_scroll_states[index] = current.withAxis(axis, next_axis);
                if (next_axis.offset != current_axis.offset) facts |= 512;
            },
            .compare_axis => if (next_axis.offset != current_axis.offset) {
                facts |= 512;
            },
            .write_axis => switch (axis) {
                .vertical => self.widget_layout_nodes[index].widget.value = next_axis.offset,
                .horizontal => self.widget_layout_nodes[index].widget.value_x = next_axis.offset,
            },
            .translate_axis => self.translateCanvasWidgetScrollDescendants(index, if (axis == .vertical) .{ .dy = -(next_axis.offset - current_axis.offset) } else .{ .dx = -(next_axis.offset - current_axis.offset) }),
            .event => self.noteCanvasWidgetScrollEvent(node.widget.id),
            .semantics => try self.refreshCanvasWidgetSemantics(),
            .revision => self.widget_revision += 1,
            .dirty, .accumulate_dirty => dirty = self.canvasWidgetDirtyBounds(index, if (mode == .textarea) node.widget.frame else node.frame),
            .driver_y => {
                next.offset_y = offset_y;
                next.velocity_y = 0;
            },
            .driver_x => {
                next.offset_x = offset_x;
                next.velocity_x = 0;
            },
            .target_y => next = next.withAxis(.vertical, target(node.widget, current.axis(.vertical), source)),
            .target_x => next = next.withAxis(.horizontal, target(node.widget, current.axis(.horizontal), source)),
            .store_state => {
                self.widget_scroll_states[index] = next;
                if (mode == .kinetic) {
                    if (moved.dx != 0 or moved.dy != 0) facts |= 512;
                } else if (next.offset_y != current.offset_y or next.offset_x != current.offset_x) facts |= 512;
            },
            .write_both => {
                self.widget_layout_nodes[index].widget.value = next.offset_y;
                self.widget_layout_nodes[index].widget.value_x = next.offset_x;
            },
            .translate_both => {
                const offset = if (mode == .kinetic) moved else geometry.OffsetF.init(next.offset_x - current.offset_x, next.offset_y - current.offset_y);
                self.translateCanvasWidgetScrollDescendants(index, .{ .dx = -offset.dx, .dy = -offset.dy });
            },
            .clear_velocities => {
                self.widget_scroll_states[index].velocity_y = 0;
                self.widget_scroll_states[index].velocity_x = 0;
            },
            .probe_y => {
                facts &= ~@as(u32, 1024);
                if (current.axis(.vertical).needsKineticStep(physics)) facts |= 1024;
            },
            .probe_x => {
                facts &= ~@as(u32, 1024);
                if (current.axis(.horizontal).needsKineticStep(physics)) facts |= 1024;
            },
            .kinetic_y => {
                const value = current.axis(.vertical).stepKinetic(delta, physics);
                next = next.withAxis(.vertical, value);
                moved.dy = value.offset - current.offset_y;
            },
            .kinetic_x => {
                const value = current.axis(.horizontal).stepKinetic(delta, physics);
                next = next.withAxis(.horizontal, value);
                moved.dx = value.offset - current.offset_x;
            },
            .zero_y => next.velocity_y = 0,
            .zero_x => next.velocity_x = 0,
        };
        if (program.next == 255) return .{ .dirty = dirty, .changed = facts & 512 != 0 };
        phase = program.next;
    }
}

pub fn finish(self: anytype, policy: programs.Policy, changed: bool) anyerror!void {
    const program = programs.plan(policy, .finish, 0, 0, false, if (changed) 512 else 0);
    for (0..program.count) |i| switch (program.instruction(i)) {
        .semantics => try self.refreshCanvasWidgetSemantics(),
        .revision => self.widget_revision += 1,
        else => unreachable,
    };
}

fn target(widget: canvas.Widget, current: canvas.ScrollAxisState, source: u8) canvas.ScrollAxisState {
    var next = current;
    next.offset = if (canvas.widgetCompiledScrollResult(widget, .{ .operation = if (source == 0) 12 else 13, .viewport = current.viewport_extent, .content = current.content_extent })) |result| result.dx else if (source == 0) 0 else current.maxOffset();
    next.velocity = 0;
    return next.clamped();
}
