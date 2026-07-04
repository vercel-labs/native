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
                .press_target = canvasWidgetPressTargetForRoute(self, index, pointer, route),
                .route = route.entries,
            };
        }

        /// The press target a routed pointer event dispatches to, with the
        /// press-vs-drag disambiguation applied: a release that ends a
        /// static-text selection drag is a selection gesture, not a click,
        /// so it presses no one (the selection it made stays live for
        /// copy). A plain click collapses the selection on `.down`, so it
        /// reaches `.up` collapsed and the press lands normally.
        fn canvasWidgetPressTargetForRoute(
            self: *const Runtime,
            view_index: usize,
            pointer: canvas.WidgetPointerEvent,
            route: canvas.WidgetEventRoute,
        ) ?canvas.WidgetHit {
            const press_target = route.press_target orelse return null;
            if (pointer.phase != .up) return press_target;
            const raw = route.target orelse return press_target;
            if (raw.kind != .text) return press_target;
            if (self.views[view_index].canvas_widget_selected_text_id != raw.id) return press_target;
            const node = self.views[view_index].widgetLayoutTree().findById(raw.id) orelse return press_target;
            const selection = node.widget.text_selection orelse return press_target;
            if (selection.isCollapsed(node.widget.text.len)) return press_target;
            return null;
        }

        /// A primary pointer-down whose hit path resolves to a
        /// window-drag region (`window-drag="true"` / `.window_drag`)
        /// hands the gesture to the platform WINDOW instead of the
        /// widget pipeline: the window moves once the pointer actually
        /// moves (a plain click moves nothing) and the platform applies
        /// its double-click titlebar convention (macOS: zoom). The walk
        /// mirrors the press fall-through, so a press-claiming widget
        /// inside the region — a button in a drag header — keeps its
        /// press and this returns false. Returns true when the down was
        /// consumed; the caller then skips widget press/text/focus/
        /// command dispatch for it so no widget is left pressed while
        /// the OS owns the pointer. Platforms without the channel
        /// (`error.UnsupportedService`) degrade to dead space.
        pub fn startCanvasWidgetWindowDragFromPointer(
            self: *Runtime,
            input_event: GpuSurfaceInputEvent,
            pointer_event: CanvasWidgetPointerEvent,
        ) anyerror!bool {
            if (pointer_event.pointer.phase != .down or input_event.button != 0) return false;
            const target = pointer_event.target orelse return false;
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return false;
            if (self.views[index].kind != .gpu_surface) return false;
            const layout = self.views[index].widgetLayoutTree();
            if (canvas.widgetWindowDragTargetIndexFromNode(layout, target.index) == null) return false;
            self.options.platform.services.startWindowDrag(pointer_event.window_id) catch |err| switch (err) {
                error.UnsupportedService => return false,
                else => return err,
            };
            return true;
        }

        /// Resolve the view's stored (raw) pressed widget id through the
        /// press fall-through walk, so control activation compares the
        /// same resolved ids the press target carries.
        fn canvasWidgetResolvedPressedId(self: *const Runtime, view_index: usize, pressed_id: canvas.ObjectId) canvas.ObjectId {
            if (pressed_id == 0) return 0;
            const layout = self.views[view_index].widgetLayoutTree();
            for (layout.nodes, 0..) |node, node_index| {
                if (node.widget.id != pressed_id) continue;
                const press_index = canvas.widgetPressTargetIndexFromNode(layout, node_index) orelse return 0;
                return layout.nodes[press_index].widget.id;
            }
            return 0;
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

            // Focus follows the resolved press target (the row a press on
            // plain text lands on), not the raw hit: clicking a list
            // item's label focuses the item, and clicking an editable
            // field (which claims its own presses) focuses the field
            // exactly as before.
            const next_focus_id: canvas.ObjectId = if (pointer_event.press_target) |target| blk: {
                if (self.views[index].widgetLayoutTree().focusTargetById(target.id) != null) break :blk target.id;
                break :blk 0;
            } else 0;

            // Pointer focus renders quietly for buttons and rows, but an
            // editable text widget shows its focus affordances (ring and
            // caret) however focus arrived — the :focus-visible contract
            // text inputs have on every platform.
            const next_focus_visible_id: canvas.ObjectId = if (pointer_event.press_target) |target| blk: {
                if (target.id == next_focus_id and canvas_widget_runtime.canvasWidgetEditableTextKind(target.kind)) break :blk next_focus_id;
                break :blk 0;
            } else 0;

            if (self.views[index].canvas_widget_focused_id == next_focus_id and self.views[index].canvas_widget_focus_visible_id == next_focus_visible_id) return;
            const previous_state = self.views[index].canvasWidgetRenderState();
            self.views[index].canvas_widget_focused_id = next_focus_id;
            self.views[index].canvas_widget_focus_visible_id = next_focus_visible_id;
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

        /// Resolve cmd/ctrl+C/X/V against the view's text state before the
        /// keyboard event reaches the text editor and the app.
        ///
        /// - copy: writes the focused editable widget's selection (or the
        ///   view's static text selection) through the platform clipboard
        ///   seam; no widget state changes.
        /// - cut: copy, then stamp a delete-selection edit onto the routed
        ///   keyboard event so runtime widget and app model apply the same
        ///   removal.
        /// - paste: reads the clipboard into `paste_buffer`, clamps it to
        ///   the view's text capacity (setting `edit_truncated` loudly),
        ///   and stamps the insertion onto the routed keyboard event.
        ///
        /// Platforms without a clipboard capability report
        /// `UnsupportedService`; the shortcut degrades to a no-op instead
        /// of failing input dispatch.
        pub fn applyCanvasWidgetClipboardShortcut(
            self: *Runtime,
            input_event: GpuSurfaceInputEvent,
            keyboard_event: ?*CanvasWidgetKeyboardEvent,
            paste_buffer: []u8,
        ) anyerror!void {
            if (input_event.kind != .key_down) return;
            const action = canvas.widgetKeyboardClipboardAction(.{
                .phase = .key_down,
                .key = input_event.key,
                .modifiers = canvasWidgetKeyboardModifiers(input_event.modifiers),
            }) orelse return;
            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return;
            if (self.views[index].kind != .gpu_surface or !self.views[index].focused) return;

            switch (action) {
                .copy => {
                    const text = self.views[index].canvasWidgetCopyText() orelse return;
                    self.writeClipboard(text) catch return;
                },
                .cut => {
                    const event = keyboard_event orelse return;
                    const target = event.target orelse return;
                    const text = canvasWidgetEditableSelectionText(self, index, target) orelse return;
                    // Never delete text that did not make it onto the
                    // clipboard: a failed write turns cut into a no-op.
                    self.writeClipboard(text) catch return;
                    event.keyboard.edit = .{ .insert_text = "" };
                },
                .paste => {
                    const event = keyboard_event orelse return;
                    const target = event.target orelse return;
                    const node_index = self.views[index].canvasWidgetNodeIndexById(target.id) orelse return;
                    const widget = self.views[index].widget_layout_nodes[node_index].widget;
                    if (!canvas_widget_runtime.canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return;
                    // An empty or unavailable clipboard pastes nothing.
                    const text = self.readClipboard(paste_buffer) catch return;
                    if (text.len == 0) return;
                    const clamp = canvas_widget_runtime.clampCanvasWidgetPasteText(widget, self.views[index].widget_text_len, text);
                    event.keyboard.edit_truncated = clamp.truncated;
                    if (clamp.text.len == 0) return;
                    event.keyboard.edit = .{ .insert_text = clamp.text };
                },
            }
        }

        fn canvasWidgetEditableSelectionText(self: *Runtime, view_index: usize, target: canvas.WidgetFocusTarget) ?[]const u8 {
            const node_index = self.views[view_index].canvasWidgetNodeIndexById(target.id) orelse return null;
            const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
            if (!canvas_widget_runtime.canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;
            const range = canvas.widgetTextSelectionRange(widget) orelse return null;
            if (range.isCollapsed(widget.text.len)) return null;
            return widget.text[range.start..range.end];
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
            // Pressing anywhere outside the selected static text drops
            // the selection (macOS-style single live selection).
            if (pointer_event.pointer.phase == .down and
                self.views[index].canvas_widget_selected_text_id != 0 and
                self.views[index].canvas_widget_selected_text_id != target_id)
            {
                if (try self.views[index].clearCanvasWidgetStaticTextSelection()) |dirty| {
                    try invalidateForCanvasWidgetDirty(self, index, dirty);
                }
            }
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

            // Control activation resolves through the press fall-through:
            // the target is the claiming widget (a press on a list item's
            // text activates the item) and the stored raw pressed id is
            // resolved through the same walk so the two compare equal for
            // one gesture. For controls hit directly (checkbox, slider,
            // chip) both resolve to themselves — behavior is unchanged.
            const resolved_pressed_id = canvasWidgetResolvedPressedId(self, index, self.views[index].canvas_widget_pressed_id);
            const toggle_animation = self.views[index].canvasWidgetToggleAnimationForPointer(
                pointer_event.pointer,
                pointer_event.press_target,
                resolved_pressed_id,
            );
            const dirty = try self.views[index].applyCanvasWidgetControlPointer(
                pointer_event.pointer,
                pointer_event.press_target,
                resolved_pressed_id,
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

        /// Returns the dismissed surface's widget id (0 when nothing was
        /// dismissed). The caller dispatches the `canvas_widget_dismiss`
        /// app event at the END of input processing — an app dispatch
        /// rebuilds the tree, and the rest of the input pipeline still
        /// routes into the current one.
        pub fn dismissCanvasWidgetSurfaceFromPointerInput(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!canvas.ObjectId {
            if (pointer_event.pointer.phase != .down) return 0;
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return 0;
            if (self.views[index].kind != .gpu_surface or !self.views[index].focused) return 0;
            const focused_id = self.views[index].canvas_widget_focused_id;
            if (focused_id == 0) return 0;

            const previous_cursor = self.views[index].canvas_widget_cursor;
            const dismissal = try self.views[index].dismissCanvasWidgetSurfaceForPointerOutsideFocusedTarget(focused_id, pointer_event.route) orelse return 0;
            if (previous_cursor != self.views[index].canvas_widget_cursor) try syncCanvasWidgetCursorForView(self, index);
            try invalidateForCanvasWidgetDirty(self, index, dismissal.dirty);
            return dismissal.id;
        }

        /// Same contract as the pointer variant: returns the dismissed
        /// surface's id (0 = none); the caller dispatches the app event.
        pub fn dismissCanvasWidgetSurfaceFromKeyboardInput(self: *Runtime, input_event: GpuSurfaceInputEvent) anyerror!canvas.ObjectId {
            if (input_event.kind != .key_down) return 0;
            if (!canvasWidgetEscapeKey(input_event.key)) return 0;
            const modifiers = canvasWidgetKeyboardModifiers(input_event.modifiers);
            if (modifiers.shift or modifiers.hasNavigationModifier()) return 0;

            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return 0;
            if (self.views[index].kind != .gpu_surface or !self.views[index].focused) return 0;
            // Deliberately NOT gated on a focused widget: a surface
            // opened from a non-focusable trigger (a text crumb) floats
            // with nothing focused, and Escape must still find it — the
            // view method falls back to the topmost mounted anchored
            // surface when the focus chain yields none.
            const focused_id = self.views[index].canvas_widget_focused_id;

            const previous_cursor = self.views[index].canvas_widget_cursor;
            const dismissal = try self.views[index].dismissCanvasWidgetSurfaceFromEscape(focused_id) orelse return 0;
            if (previous_cursor != self.views[index].canvas_widget_cursor) try syncCanvasWidgetCursorForView(self, index);
            try invalidateForCanvasWidgetDirty(self, index, dismissal.dirty);
            return dismissal.id;
        }

        /// Every dismissal source (Escape, outside pointer, automation and
        /// accessibility dismiss actions) delivers the dismissed surface's
        /// id to the app, so a TEA model with an `on_dismiss` handler owns
        /// the close instead of relying on the engine's transient hide.
        pub fn dispatchCanvasWidgetDismissEvent(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, surface_id: canvas.ObjectId) anyerror!void {
            if (surface_id == 0) return;
            try self.dispatchEvent(app, .{ .canvas_widget_dismiss = .{
                .window_id = self.views[view_index].window_id,
                .view_label = self.views[view_index].label,
                .id = surface_id,
            } });
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
            // Engine-owned command dispatch fires on the resolved press
            // target, so a `command` list item/data cell activates when
            // its text children are pressed. The gesture discipline stays
            // on the raw hit (the same widget must start and end the
            // press); the release may land anywhere within the claiming
            // widget's bounds or the raw target's own bounds.
            const press = pointer_event.press_target orelse return;
            switch (pointer_event.pointer.phase) {
                .down => {
                    if (!canvasWidgetCommandFiresOnPointerDown(press.kind)) return;
                    if (!canvasWidgetPressReleaseInBounds(press, target, pointer_event.pointer.point)) return;
                    try dispatchCanvasWidgetCommandForId(self, app, index, press.id);
                },
                .up => {
                    if (canvasWidgetCommandFiresOnPointerDown(press.kind)) return;
                    const pressed_id = if (pointer_event.pointer.captured_id != 0) pointer_event.pointer.captured_id else self.views[index].canvas_widget_pressed_id;
                    if (pressed_id != target.id) return;
                    if (!canvasWidgetPressReleaseInBounds(press, target, pointer_event.pointer.point)) return;
                    try dispatchCanvasWidgetCommandForId(self, app, index, press.id);
                },
                .hover, .move, .cancel, .wheel => return,
            }
        }

        fn canvasWidgetPressReleaseInBounds(press: canvas.WidgetHit, target: canvas.WidgetHit, point: geometry.PointF) bool {
            if (press.bounds.normalized().containsPoint(point)) return true;
            return press.id != target.id and target.bounds.normalized().containsPoint(point);
        }

        pub fn dispatchCanvasWidgetCommandFromKeyboard(self: *Runtime, app: runtime_api.App(Runtime), keyboard_event: CanvasWidgetKeyboardEvent) anyerror!void {
            if (keyboard_event.keyboard.phase != .key_down or keyboard_event.keyboard.modifiers.hasNavigationModifier()) return;
            if (!canvas.isWidgetActivationKey(keyboard_event.keyboard.key)) return;
            const index = runtimeFindViewIndex(self, keyboard_event.window_id, keyboard_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            const target = keyboard_event.target orelse return;
            try dispatchCanvasWidgetCommandForId(self, app, index, target.id);
        }

        /// Returns true when the key moved keyboard focus to a DIFFERENT
        /// widget — the caller stamps it onto the routed keyboard event
        /// (`focus_moved`) so tree rows can tell selection-follows-focus
        /// arrivals from in-place collapse/expand intents.
        pub fn updateCanvasWidgetFocusFromKeyboardInput(self: *Runtime, input_event: GpuSurfaceInputEvent) anyerror!bool {
            if (input_event.kind != .key_down) return false;
            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return false;
            if (self.views[index].kind != .gpu_surface) return false;

            const current_id: ?canvas.ObjectId = if (self.views[index].canvas_widget_focused_id == 0) null else self.views[index].canvas_widget_focused_id;
            if (std.ascii.eqlIgnoreCase(input_event.key, "tab")) {
                const direction: canvas.WidgetFocusDirection = if (input_event.modifiers.shift) .backward else .forward;
                const target = if (current_id) |id|
                    self.views[index].canvasWidgetScopedFocusTarget(id, direction) orelse self.views[index].widgetLayoutTree().focusTarget(current_id, direction) orelse return false
                else
                    self.views[index].widgetLayoutTree().focusTarget(current_id, direction) orelse return false;
                return try setCanvasWidgetFocusFromKeyboardMoved(self, index, current_id, target.id);
            }

            const focused_id = current_id orelse return false;
            const layout = self.views[index].widgetLayoutTree();
            const focused = layout.focusTargetById(focused_id) orelse return false;
            if (canvasWidgetGroupFocusEdgeFromInput(input_event)) |edge| {
                // A tree row's Home/End jump to the SCOPE's edges (rows
                // nest, so the group edge walk's same-parent rule would
                // stop at one level).
                if (canvas_widget_runtime.canvasWidgetTreeFocusEdgeTarget(layout, focused, edge)) |target| {
                    return try setCanvasWidgetFocusFromKeyboardMoved(self, index, current_id, target.id);
                }
                const target = canvasWidgetGroupFocusEdgeTarget(layout, focused, edge) orelse return false;
                return try setCanvasWidgetFocusFromKeyboardMoved(self, index, current_id, target.id);
            }
            const direction = canvasWidgetSpatialFocusDirection(input_event) orelse return false;
            // The ARIA tree keymap first: Up/Down walk the scope's
            // visible rows, Left/Right move to parent / first child when
            // they are moves (collapse/expand stay routed intents).
            if (canvas_widget_runtime.canvasWidgetTreeDirectionalFocusTarget(layout, focused, direction)) |target| {
                return try setCanvasWidgetFocusFromKeyboardMoved(self, index, current_id, target.id);
            }
            if (canvasWidgetGroupDirectionalFocusTarget(layout, focused, direction)) |target| {
                return try setCanvasWidgetFocusFromKeyboardMoved(self, index, current_id, target.id);
            }
            const target = layout.focusTarget(focused_id, direction) orelse return false;
            if (!canvasWidgetSpatialFocusAllowed(layout, focused, target, direction)) return false;
            return try setCanvasWidgetFocusFromKeyboardMoved(self, index, current_id, target.id);
        }

        fn setCanvasWidgetFocusFromKeyboardMoved(self: *Runtime, view_index: usize, previous_id: ?canvas.ObjectId, target_id: canvas.ObjectId) anyerror!bool {
            try setCanvasWidgetFocusFromKeyboard(self, view_index, target_id);
            const previous = previous_id orelse 0;
            return target_id != 0 and target_id != previous;
        }

        pub fn setCanvasWidgetFocusFromKeyboard(self: *Runtime, view_index: usize, target_id: canvas.ObjectId) anyerror!void {
            if (self.views[view_index].canvas_widget_focused_id == target_id and self.views[view_index].canvas_widget_focus_visible_id == target_id) return;
            const previous_state = self.views[view_index].canvasWidgetRenderState();
            self.views[view_index].canvas_widget_focused_id = target_id;
            self.views[view_index].canvas_widget_focus_visible_id = target_id;
            // Keyboard focus landing on an editable establishes a caret:
            // without a selection the emitters draw no caret line, so a
            // tabbed-into field would render its ring but no insertion
            // point. Collapse at the end of the text, the plain caret
            // placement; a selection the widget already carries survives.
            if (target_id != 0 and self.views[view_index].canEditCanvasWidgetText(target_id)) {
                if (self.views[view_index].canvasWidgetNodeIndexById(target_id)) |node_index| {
                    const widget = &self.views[view_index].widget_layout_nodes[node_index].widget;
                    if (widget.text_selection == null) {
                        widget.text_selection = canvas.TextSelection.collapsed(widget.text.len);
                        try self.views[view_index].refreshCanvasWidgetSemantics();
                        self.views[view_index].widget_revision += 1;
                    }
                }
            }
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
    for (self.views[0..self.view_count], 0..) |*view, index| {
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
