const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const validation = @import("validation.zig");
const runtime_api = @import("api.zig");
const canvas_frame_helpers = @import("canvas_frame.zig");
const runtime_canvas_widget_display = @import("canvas_widget_display.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const widget_bridge = @import("widget_bridge.zig");

const GpuSurfaceInputEvent = runtime_api.GpuSurfaceInputEvent;
const CanvasWidgetPointerEvent = runtime_api.CanvasWidgetPointerEvent;
const CanvasWidgetKeyboardEvent = runtime_api.CanvasWidgetKeyboardEvent;
const CanvasWidgetFileDropEvent = runtime_api.CanvasWidgetFileDropEvent;
const CanvasWidgetDragEvent = runtime_api.CanvasWidgetDragEvent;
const validateViewLabel = validation.validateViewLabel;
const platformCursorFromCanvas = widget_bridge.platformCursorFromCanvas;
const canvasWidgetPointerEventFromGpuInput = canvas_frame_helpers.canvasWidgetPointerEventFromGpuInput;
const canvasWidgetKeyboardEventFromGpuInput = canvas_frame_helpers.canvasWidgetKeyboardEventFromGpuInput;
const canvasWidgetTextInputEventFromGpuInput = canvas_frame_helpers.canvasWidgetTextInputEventFromGpuInput;
const canvasWidgetEscapeKey = canvas_frame_helpers.canvasWidgetEscapeKey;
const canvasWidgetKeyboardModifiers = canvas_frame_helpers.canvasWidgetKeyboardModifiers;
const canvasWidgetInteractionTargetExists = canvas_widget_runtime.canvasWidgetInteractionTargetExists;
const canvasWidgetCommandable = canvas_widget_runtime.canvasWidgetCommandable;
const canvasWidgetCommandFiresOnPointerDown = canvas_widget_runtime.canvasWidgetCommandFiresOnPointerDown;
const canvasWidgetGroupFocusEdgeFromInput = canvas_widget_runtime.canvasWidgetGroupFocusEdgeFromInput;
const canvasWidgetSpatialFocusDirection = canvas_widget_runtime.canvasWidgetSpatialFocusDirection;
const canvasWidgetSpatialFocusAllowed = canvas_widget_runtime.canvasWidgetSpatialFocusAllowed;
const canvasWidgetGroupDirectionalFocusTarget = canvas_widget_runtime.canvasWidgetGroupDirectionalFocusTarget;
const canvasWidgetGroupFocusEdgeTarget = canvas_widget_runtime.canvasWidgetGroupFocusEdgeTarget;

pub fn RuntimeCanvasWidgetEvents(comptime Runtime: type) type {
    return struct {
        pub fn routeCanvasWidgetPointerInput(self: *const Runtime, input_event: GpuSurfaceInputEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetPointerEvent {
            try validateRuntimeViewParent(self, input_event.window_id);
            try validateViewLabel(input_event.label);
            var pointer = canvasWidgetPointerEventFromGpuInput(input_event) orelse return null;
            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            switch (pointer.phase) {
                .move, .up, .cancel => {
                    if (self.views[index].canvas_widget_pressed_id != 0) {
                        pointer.captured_id = self.views[index].canvas_widget_pressed_id;
                    }
                },
                .hover, .down, .wheel => {},
            }

            const route = try self.views[index].widgetLayoutTree().routePointerEventWithTokens(pointer, self.views[index].widget_tokens, output);
            return .{
                .window_id = input_event.window_id,
                .view_label = self.views[index].label,
                .pointer = pointer,
                .target = route.target,
                .route = route.entries,
            };
        }

        pub fn routeCanvasWidgetKeyboardInput(self: *const Runtime, input_event: GpuSurfaceInputEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetKeyboardEvent {
            try validateRuntimeViewParent(self, input_event.window_id);
            try validateViewLabel(input_event.label);
            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (!self.views[index].focused) return null;
            const focused_id = self.views[index].canvas_widget_focused_id;
            if (focused_id == 0) return null;
            const keyboard = canvasWidgetKeyboardEventFromGpuInput(input_event, focused_id) orelse return null;

            const route = try self.views[index].widgetLayoutTree().routeKeyboardEvent(keyboard, output);
            if (route.target == null) return null;
            return .{
                .window_id = input_event.window_id,
                .view_label = self.views[index].label,
                .keyboard = keyboard,
                .target = route.target,
                .route = route.entries,
            };
        }

        pub fn routeCanvasWidgetTextInput(self: *const Runtime, input_event: GpuSurfaceInputEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetKeyboardEvent {
            try validateRuntimeViewParent(self, input_event.window_id);
            try validateViewLabel(input_event.label);
            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (!self.views[index].focused) return null;
            const focused_id = self.views[index].canvas_widget_focused_id;
            if (focused_id == 0) return null;
            const keyboard = canvasWidgetTextInputEventFromGpuInput(input_event, focused_id) orelse return null;

            const route = try self.views[index].widgetLayoutTree().routeKeyboardEvent(keyboard, output);
            if (route.target == null) return null;
            return .{
                .window_id = input_event.window_id,
                .view_label = self.views[index].label,
                .keyboard = keyboard,
                .target = route.target,
                .route = route.entries,
            };
        }

        pub fn routeCanvasWidgetFileDrop(self: *const Runtime, drop: platform.FileDropEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetFileDropEvent {
            try validateRuntimeViewParent(self, drop.window_id);
            if (drop.view_label.len == 0 or drop.paths.len == 0) return null;
            try validateViewLabel(drop.view_label);
            const point = drop.point orelse return null;
            const index = runtimeFindViewIndex(self, drop.window_id, drop.view_label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

            const widget_drop = canvas.WidgetFileDropEvent{
                .point = point,
                .paths = drop.paths,
            };
            const route = try self.views[index].widgetLayoutTree().routeFileDropEvent(widget_drop, output);
            if (route.target == null) return null;
            return .{
                .window_id = drop.window_id,
                .view_label = self.views[index].label,
                .drop = widget_drop,
                .target = route.target,
                .route = route.entries,
            };
        }

        pub fn routeCanvasWidgetDragInput(self: *const Runtime, input_event: GpuSurfaceInputEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetDragEvent {
            try validateRuntimeViewParent(self, input_event.window_id);
            if (input_event.kind != .pointer_drag) return null;
            try validateViewLabel(input_event.label);
            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            const source_id = self.views[index].canvas_widget_pressed_id;
            if (source_id == 0) return null;

            const drag = canvas.WidgetDragEvent{
                .source_id = source_id,
                .point = geometry.PointF.init(input_event.x, input_event.y),
                .delta = geometry.OffsetF.init(input_event.delta_x, input_event.delta_y),
            };
            const route = try self.views[index].widgetLayoutTree().routeDragEvent(drag, output);
            if (route.target == null) return null;
            return .{
                .window_id = input_event.window_id,
                .view_label = self.views[index].label,
                .drag = drag,
                .source = route.target,
                .route = route.entries,
            };
        }

        pub fn updateCanvasWidgetFocusFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
            if (pointer_event.pointer.phase != .down) return;
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;

            const next_focus_id: canvas.ObjectId = if (pointer_event.target) |target| blk: {
                if (self.views[index].widgetLayoutTree().focusTargetById(target.id) != null) break :blk target.id;
                break :blk 0;
            } else 0;

            if (self.views[index].canvas_widget_focused_id == next_focus_id and self.views[index].canvas_widget_focus_visible_id == 0) return;
            const previous_state = self.views[index].canvasWidgetRenderState();
            self.views[index].canvas_widget_focused_id = next_focus_id;
            self.views[index].canvas_widget_focus_visible_id = 0;
            try invalidateForCanvasWidgetRenderStateChange(self, index, previous_state, self.views[index].canvasWidgetRenderState());
        }

        pub fn updateCanvasWidgetInteractionFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;

            const target_id: canvas.ObjectId = if (pointer_event.target) |target| target.id else 0;
            const hit_target = self.views[index].widgetLayoutTree().hitTestWithTokens(pointer_event.pointer.point, self.views[index].widget_tokens);
            const hit_target_id: canvas.ObjectId = if (hit_target) |target| target.id else 0;
            const hit_cursor = platformCursorFromCanvas(self.views[index].widgetLayoutTree().cursorForHit(hit_target));
            var next_hovered_id = self.views[index].canvas_widget_hovered_id;
            var next_pressed_id = self.views[index].canvas_widget_pressed_id;
            var next_cursor = self.views[index].canvas_widget_cursor;

            switch (pointer_event.pointer.phase) {
                .hover, .move => {
                    next_hovered_id = hit_target_id;
                    next_cursor = hit_cursor;
                },
                .down => {
                    next_hovered_id = target_id;
                    next_pressed_id = target_id;
                    next_cursor = platformCursorFromCanvas(self.views[index].widgetLayoutTree().cursorForHit(pointer_event.target));
                },
                .up => {
                    next_hovered_id = hit_target_id;
                    next_pressed_id = 0;
                    next_cursor = hit_cursor;
                },
                .cancel => {
                    next_hovered_id = 0;
                    next_pressed_id = 0;
                    next_cursor = .arrow;
                },
                .wheel => {},
            }

            const interaction_changed = self.views[index].canvas_widget_hovered_id != next_hovered_id or
                self.views[index].canvas_widget_pressed_id != next_pressed_id;
            const cursor_changed = self.views[index].canvas_widget_cursor != next_cursor;
            if (!interaction_changed and !cursor_changed) return;

            const previous_state = self.views[index].canvasWidgetRenderState();
            self.views[index].canvas_widget_hovered_id = next_hovered_id;
            self.views[index].canvas_widget_pressed_id = next_pressed_id;
            self.views[index].canvas_widget_cursor = next_cursor;
            if (cursor_changed) try syncCanvasWidgetCursorForView(self, index);
            if (interaction_changed) try invalidateForCanvasWidgetRenderStateChange(self, index, previous_state, self.views[index].canvasWidgetRenderState());
        }

        pub fn syncCanvasWidgetCursorForView(self: *Runtime, view_index: usize) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            try self.options.platform.services.setViewCursor(
                self.views[view_index].window_id,
                self.views[view_index].label,
                self.views[view_index].canvas_widget_cursor,
            );
        }

        pub fn invalidateForCanvasWidgetRenderStateChange(self: *Runtime, view_index: usize, previous: canvas.WidgetRenderState, next: canvas.WidgetRenderState) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            const local_dirty = self.views[view_index].widgetLayoutTree().renderStateDirtyBounds(previous, next);
            invalidateForCanvasWidgetRenderStateDirty(self, view_index, local_dirty);
            const publish_accessibility = previous.focused_id != next.focused_id;
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwnedWithAccessibility(self, view_index, publish_accessibility);
        }

        pub fn invalidateForCanvasWidgetRenderStateDirty(self: *Runtime, view_index: usize, local_dirty: ?geometry.RectF) void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            const dirty = local_dirty orelse return;
            if (canvasDirtyRegionForView(self.views[view_index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
                return;
            }
            self.invalidateFor(.state, self.views[view_index].frame);
        }

        pub fn canvasWidgetRenderStateAfterLayout(previous: canvas.WidgetRenderState, layout: canvas.WidgetLayoutTree) canvas.WidgetRenderState {
            const next_focused_id = if (previous.focused_id) |id| if (layout.focusTargetById(id) != null) id else null else null;
            return .{
                .focused_id = next_focused_id,
                .focus_visible_id = if (previous.focus_visible_id) |id| if (next_focused_id != null and next_focused_id.? == id and layout.focusTargetById(id) != null) id else null else null,
                .hovered_id = if (previous.hovered_id) |id| if (canvasWidgetInteractionTargetExists(layout, id)) id else null else null,
                .pressed_id = if (previous.pressed_id) |id| if (canvasWidgetInteractionTargetExists(layout, id)) id else null else null,
            };
        }

        pub fn canvasWidgetRenderStatesEqual(a: canvas.WidgetRenderState, b: canvas.WidgetRenderState) bool {
            return a.focused_id == b.focused_id and
                a.focus_visible_id == b.focus_visible_id and
                a.hovered_id == b.hovered_id and
                a.pressed_id == b.pressed_id;
        }

        pub fn updateCanvasWidgetScrollFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
            if (pointer_event.pointer.phase != .wheel) return;
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;

            const dirty = try self.views[index].applyCanvasWidgetScrollRoute(pointer_event.route, pointer_event.pointer.delta.dy, .wheel) orelse return;
            const previous_cursor = self.views[index].canvas_widget_cursor;
            self.views[index].reconcileCanvasWidgetRenderStateAfterScroll(pointer_event.pointer.point);
            if (previous_cursor != self.views[index].canvas_widget_cursor) try syncCanvasWidgetCursorForView(self, index);
            if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[index].frame);
            }
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwnedSkippingAccessibility(self, index);
        }

        pub fn updateCanvasWidgetTextFromKeyboard(self: *Runtime, keyboard_event: CanvasWidgetKeyboardEvent) anyerror!void {
            const index = runtimeFindViewIndex(self, keyboard_event.window_id, keyboard_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            const target = keyboard_event.target orelse return;
            const edit = self.views[index].canvasWidgetKeyboardTextEdit(target, keyboard_event.keyboard) orelse return;

            const dirty = try self.views[index].applyCanvasWidgetTextEdit(target.id, edit) orelse return;
            if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[index].frame);
            }
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
        }

        pub fn updateCanvasWidgetTextFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;

            const target_id: canvas.ObjectId = switch (pointer_event.pointer.phase) {
                .down => if (pointer_event.target) |target| target.id else 0,
                .move => self.views[index].canvas_widget_pressed_id,
                else => return,
            };
            if (target_id == 0) return;

            const dirty = try self.views[index].applyCanvasWidgetTextPointer(
                target_id,
                pointer_event.pointer.point,
                pointer_event.pointer.phase == .move,
            ) orelse return;
            if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[index].frame);
            }
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
        }

        pub fn updateCanvasWidgetControlFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;

            const toggle_animation = self.views[index].canvasWidgetToggleAnimationForPointer(
                pointer_event.pointer,
                pointer_event.target,
                self.views[index].canvas_widget_pressed_id,
            );
            const dirty = try self.views[index].applyCanvasWidgetControlPointer(
                pointer_event.pointer,
                pointer_event.target,
                self.views[index].canvas_widget_pressed_id,
            ) orelse return;
            if (toggle_animation) |animation| try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).scheduleCanvasWidgetToggleAnimation(self, index, animation);
            if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[index].frame);
            }
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
        }

        pub fn updateCanvasWidgetControlFromKeyboard(self: *Runtime, keyboard_event: CanvasWidgetKeyboardEvent) anyerror!void {
            const index = runtimeFindViewIndex(self, keyboard_event.window_id, keyboard_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            const target = keyboard_event.target orelse return;

            const toggle_animation = self.views[index].canvasWidgetToggleAnimationForKeyboard(target.id, keyboard_event.keyboard);
            const dirty = try self.views[index].applyCanvasWidgetControlKeyboard(target.id, keyboard_event.keyboard) orelse return;
            if (toggle_animation) |animation| try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).scheduleCanvasWidgetToggleAnimation(self, index, animation);
            const previous_cursor = self.views[index].canvas_widget_cursor;
            if (target.kind == .scroll_view) self.views[index].reconcileCanvasWidgetRenderStateAfterScroll(null);
            if (previous_cursor != self.views[index].canvas_widget_cursor) try syncCanvasWidgetCursorForView(self, index);
            if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[index].frame);
            }
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
        }

        pub fn dismissCanvasWidgetSurfaceFromPointerInput(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!bool {
            if (pointer_event.pointer.phase != .down) return false;
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return false;
            if (self.views[index].kind != .gpu_surface or !self.views[index].focused) return false;
            const focused_id = self.views[index].canvas_widget_focused_id;
            if (focused_id == 0) return false;

            const previous_cursor = self.views[index].canvas_widget_cursor;
            const dirty = try self.views[index].dismissCanvasWidgetSurfaceForPointerOutsideFocusedTarget(focused_id, pointer_event.route) orelse return false;
            if (previous_cursor != self.views[index].canvas_widget_cursor) try syncCanvasWidgetCursorForView(self, index);
            try invalidateForCanvasWidgetDirty(self, index, dirty);
            return true;
        }

        pub fn dismissCanvasWidgetSurfaceFromKeyboardInput(self: *Runtime, input_event: GpuSurfaceInputEvent) anyerror!bool {
            if (input_event.kind != .key_down) return false;
            if (!canvasWidgetEscapeKey(input_event.key)) return false;
            const modifiers = canvasWidgetKeyboardModifiers(input_event.modifiers);
            if (modifiers.shift or modifiers.hasNavigationModifier()) return false;

            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return false;
            if (self.views[index].kind != .gpu_surface or !self.views[index].focused) return false;
            const focused_id = self.views[index].canvas_widget_focused_id;
            if (focused_id == 0) return false;

            const previous_cursor = self.views[index].canvas_widget_cursor;
            const dirty = try self.views[index].dismissCanvasWidgetSurfaceForFocusedTarget(focused_id) orelse return false;
            if (previous_cursor != self.views[index].canvas_widget_cursor) try syncCanvasWidgetCursorForView(self, index);
            try invalidateForCanvasWidgetDirty(self, index, dirty);
            return true;
        }

        pub fn dispatchCanvasWidgetCommandForId(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, id: canvas.ObjectId) anyerror!void {
            if (view_index >= self.view_count) return error.ViewNotFound;
            const node_index = self.views[view_index].canvasWidgetNodeIndexById(id) orelse return;
            const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
            if (!canvasWidgetCommandable(widget.kind)) return;
            const command = self.views[view_index].canvasWidgetCommand(id) orelse return;
            try self.dispatchCommand(app, .{
                .name = command,
                .source = .native_view,
                .window_id = self.views[view_index].window_id,
                .view_label = self.views[view_index].label,
            });
        }

        pub fn dispatchCanvasWidgetCommandFromPointer(self: *Runtime, app: runtime_api.App(Runtime), pointer_event: CanvasWidgetPointerEvent) anyerror!void {
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            const target = pointer_event.target orelse return;
            switch (pointer_event.pointer.phase) {
                .down => {
                    if (!canvasWidgetCommandFiresOnPointerDown(target.kind)) return;
                    if (!target.bounds.normalized().containsPoint(pointer_event.pointer.point)) return;
                    try dispatchCanvasWidgetCommandForId(self, app, index, target.id);
                },
                .up => {
                    if (canvasWidgetCommandFiresOnPointerDown(target.kind)) return;
                    const pressed_id = if (pointer_event.pointer.captured_id != 0) pointer_event.pointer.captured_id else self.views[index].canvas_widget_pressed_id;
                    if (pressed_id != target.id) return;
                    if (!target.bounds.normalized().containsPoint(pointer_event.pointer.point)) return;
                    try dispatchCanvasWidgetCommandForId(self, app, index, target.id);
                },
                .hover, .move, .cancel, .wheel => return,
            }
        }

        pub fn dispatchCanvasWidgetCommandFromKeyboard(self: *Runtime, app: runtime_api.App(Runtime), keyboard_event: CanvasWidgetKeyboardEvent) anyerror!void {
            if (keyboard_event.keyboard.phase != .key_down or keyboard_event.keyboard.modifiers.hasNavigationModifier()) return;
            if (!canvas.isWidgetActivationKey(keyboard_event.keyboard.key)) return;
            const index = runtimeFindViewIndex(self, keyboard_event.window_id, keyboard_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            const target = keyboard_event.target orelse return;
            try dispatchCanvasWidgetCommandForId(self, app, index, target.id);
        }

        pub fn updateCanvasWidgetFocusFromKeyboardInput(self: *Runtime, input_event: GpuSurfaceInputEvent) anyerror!void {
            if (input_event.kind != .key_down) return;
            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;

            const current_id: ?canvas.ObjectId = if (self.views[index].canvas_widget_focused_id == 0) null else self.views[index].canvas_widget_focused_id;
            if (std.ascii.eqlIgnoreCase(input_event.key, "tab")) {
                const direction: canvas.WidgetFocusDirection = if (input_event.modifiers.shift) .backward else .forward;
                const target = if (current_id) |id|
                    self.views[index].canvasWidgetScopedFocusTarget(id, direction) orelse self.views[index].widgetLayoutTree().focusTarget(current_id, direction) orelse return
                else
                    self.views[index].widgetLayoutTree().focusTarget(current_id, direction) orelse return;
                try setCanvasWidgetFocusFromKeyboard(self, index, target.id);
                return;
            }

            const focused_id = current_id orelse return;
            const layout = self.views[index].widgetLayoutTree();
            const focused = layout.focusTargetById(focused_id) orelse return;
            if (canvasWidgetGroupFocusEdgeFromInput(input_event)) |edge| {
                const target = canvasWidgetGroupFocusEdgeTarget(layout, focused, edge) orelse return;
                try setCanvasWidgetFocusFromKeyboard(self, index, target.id);
                return;
            }
            const direction = canvasWidgetSpatialFocusDirection(input_event) orelse return;
            if (canvasWidgetGroupDirectionalFocusTarget(layout, focused, direction)) |target| {
                try setCanvasWidgetFocusFromKeyboard(self, index, target.id);
                return;
            }
            const target = layout.focusTarget(focused_id, direction) orelse return;
            if (!canvasWidgetSpatialFocusAllowed(layout, focused, target, direction)) return;
            try setCanvasWidgetFocusFromKeyboard(self, index, target.id);
        }

        pub fn setCanvasWidgetFocusFromKeyboard(self: *Runtime, view_index: usize, target_id: canvas.ObjectId) anyerror!void {
            if (self.views[view_index].canvas_widget_focused_id == target_id and self.views[view_index].canvas_widget_focus_visible_id == target_id) return;
            const previous_state = self.views[view_index].canvasWidgetRenderState();
            self.views[view_index].canvas_widget_focused_id = target_id;
            self.views[view_index].canvas_widget_focus_visible_id = target_id;
            try invalidateForCanvasWidgetRenderStateChange(self, view_index, previous_state, self.views[view_index].canvasWidgetRenderState());
        }

        pub fn invalidateForWidgetInvalidations(self: *Runtime, view_frame: geometry.RectF, invalidations: []const canvas.WidgetInvalidation) void {
            var emitted_dirty_region = false;
            for (invalidations) |invalidation| {
                const local_dirty = invalidation.dirty_bounds orelse continue;
                if (canvasDirtyRegionForView(view_frame, local_dirty)) |dirty_region| {
                    self.invalidateFor(.state, dirty_region);
                    emitted_dirty_region = true;
                }
            }
            if (!emitted_dirty_region and invalidations.len > 0) self.invalidateFor(.state, null);
        }

        pub fn invalidateForCanvasWidgetDirty(self: *Runtime, view_index: usize, dirty: geometry.RectF) anyerror!void {
            if (canvasDirtyRegionForView(self.views[view_index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[view_index].frame);
            }
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, view_index);
        }
    };
}

fn validateRuntimeViewParent(self: anytype, window_id: platform.WindowId) !void {
    const index = runtimeFindWindowIndexById(self, window_id) orelse return error.WindowNotFound;
    if (!self.windows[index].info.open) return error.WindowNotFound;
}

fn runtimeFindWindowIndexById(self: anytype, id: platform.WindowId) ?usize {
    for (self.windows[0..self.window_count], 0..) |window, index| {
        if (window.info.id == id) return index;
    }
    return null;
}

fn runtimeFindViewIndex(self: anytype, window_id: platform.WindowId, label: []const u8) ?usize {
    for (self.views[0..self.view_count], 0..) |view, index| {
        if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
    }
    return null;
}

fn canvasDirtyRegionForView(view_frame: geometry.RectF, local_dirty: geometry.RectF) ?geometry.RectF {
    const normalized_view = view_frame.normalized();
    const surface_bounds = geometry.RectF.init(0, 0, normalized_view.width, normalized_view.height);
    const clipped = geometry.RectF.intersection(surface_bounds, local_dirty.normalized());
    if (clipped.isEmpty()) return null;
    return clipped.translate(.{ .dx = normalized_view.x, .dy = normalized_view.y });
}
