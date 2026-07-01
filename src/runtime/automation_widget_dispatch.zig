const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const validation = @import("validation.zig");
const runtime_api = @import("api.zig");
const automation_commands = @import("automation_commands.zig");
const runtime_clock = @import("clock.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const runtime_canvas_widget_display = @import("canvas_widget_display.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");

const AutomationWidgetAction = automation_commands.AutomationWidgetAction;
const AutomationWidgetTarget = automation_commands.AutomationWidgetTarget;
const AutomationWidgetWheel = automation_commands.AutomationWidgetWheel;
const AutomationWidgetKey = automation_commands.AutomationWidgetKey;
const AutomationWidgetPointerDrag = automation_commands.AutomationWidgetPointerDrag;
const automationWidgetActionSupported = automation_commands.automationWidgetActionSupported;
const parseAutomationTextSelection = automation_commands.parseAutomationTextSelection;
const parseAutomationDragDelta = automation_commands.parseAutomationDragDelta;
const parseAutomationDropPaths = automation_commands.parseAutomationDropPaths;
const automationInputTimestampNs = runtime_clock.automationInputTimestampNs;
const canvasWidgetInteractionTargetExists = canvas_widget_runtime.canvasWidgetInteractionTargetExists;
const canvasWidgetSelectableTargetExists = canvas_widget_runtime.canvasWidgetSelectableTargetExists;
const validateViewLabel = validation.validateViewLabel;

pub fn RuntimeAutomationWidgetDispatch(comptime Runtime: type) type {
    return struct {
        pub fn dispatchAutomationWidgetAction(self: *Runtime, app: runtime_api.App(Runtime), action: AutomationWidgetAction) anyerror!void {
            const view_index = try automationWidgetActionViewIndex(self, action);
            switch (action.action) {
                .focus => try focusAutomationCanvasWidget(self, view_index, action.id),
                .press => try dispatchAutomationWidgetKey(self, app, view_index, action.id, "enter"),
                .toggle => try dispatchAutomationWidgetKey(self, app, view_index, action.id, "space"),
                .increment => try dispatchAutomationWidgetKey(self, app, view_index, action.id, self.views[view_index].canvasWidgetStepKey(action.id, .increment)),
                .decrement => try dispatchAutomationWidgetKey(self, app, view_index, action.id, self.views[view_index].canvasWidgetStepKey(action.id, .decrement)),
                .set_text => try setAutomationCanvasWidgetText(self, view_index, action.id, action.value),
                .set_selection => try editAutomationCanvasWidgetText(self, view_index, action.id, .{ .set_selection = try parseAutomationTextSelection(action.value) }),
                .set_composition => try editAutomationCanvasWidgetText(self, view_index, action.id, .{ .set_composition = .{ .text = action.value } }),
                .commit_composition => try editAutomationCanvasWidgetText(self, view_index, action.id, .commit_composition),
                .cancel_composition => try editAutomationCanvasWidgetText(self, view_index, action.id, .cancel_composition),
                .select => try selectAutomationCanvasWidget(self, view_index, action.id),
                .drag => try dispatchAutomationCanvasWidgetDrag(self, app, view_index, action.id, action.value),
                .drop_files => try dispatchAutomationCanvasWidgetFileDrop(self, app, view_index, action.id, action.value),
                .dismiss => try dismissAutomationCanvasWidget(self, view_index, action.id),
            }
        }

        pub fn dispatchCanvasWidgetSemanticControlAction(
            self: *Runtime,
            app: runtime_api.App(Runtime),
            view_index: usize,
            id: canvas.ObjectId,
            action: canvas.WidgetSemanticAction,
            actions: canvas.WidgetActions,
        ) anyerror!bool {
            if (view_index >= self.view_count) return error.ViewNotFound;
            const node_index = self.views[view_index].canvasWidgetNodeIndexById(id) orelse return false;
            const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
            const intent = canvas.widgetSemanticControlIntentWithActions(widget, action, actions) orelse return false;

            self.views[view_index].recordGpuSurfaceInputTimestamp(automationInputTimestampNs());
            CanvasWidgetDisplayMethods().beginCanvasWidgetDisplayListRefreshBatch(self);
            var batch_active = true;
            errdefer if (batch_active) CanvasWidgetDisplayMethods().cancelCanvasWidgetDisplayListRefreshBatch(self);

            if (self.views[view_index].widgetLayoutTree().focusTargetById(id) != null) {
                try focusAutomationCanvasWidget(self, view_index, id);
            }

            const toggle_animation = if (intent.kind == .toggle) self.views[view_index].canvasWidgetToggleAnimation(id) else null;
            const dirty = try self.views[view_index].applyCanvasWidgetControlIntent(node_index, intent);
            if (toggle_animation) |animation| try CanvasWidgetDisplayMethods().scheduleCanvasWidgetToggleAnimation(self, view_index, animation);
            if (dirty) |bounds| {
                const previous_cursor = self.views[view_index].canvas_widget_cursor;
                switch (intent.kind) {
                    .scroll_by, .scroll_to_start, .scroll_to_end => self.views[view_index].reconcileCanvasWidgetRenderStateAfterScroll(null),
                    else => {},
                }
                if (previous_cursor != self.views[view_index].canvas_widget_cursor) try CanvasWidgetEventMethods().syncCanvasWidgetCursorForView(self, view_index);
                try CanvasWidgetEventMethods().invalidateForCanvasWidgetDirty(self, view_index, bounds);
            }

            try CanvasWidgetDisplayMethods().endCanvasWidgetDisplayListRefreshBatch(self);
            batch_active = false;

            if (action == .press and intent.actions.press) {
                try CanvasWidgetEventMethods().dispatchCanvasWidgetCommandForId(self, app, view_index, id);
            }
            return true;
        }

        pub fn dispatchAutomationWidgetClick(self: *Runtime, app: runtime_api.App(Runtime), target: AutomationWidgetTarget) anyerror!void {
            const view_index = try automationWidgetTargetViewIndex(self, target);
            const layout = self.views[view_index].widgetLayoutTree();
            if (!canvasWidgetInteractionTargetExists(layout, target.id)) return error.InvalidCommand;
            const node = layout.findById(target.id) orelse return error.InvalidCommand;
            const bounds = node.frame.normalized();
            if (bounds.isEmpty()) return error.InvalidCommand;
            const point = bounds.center();
            const window_id = self.views[view_index].window_id;
            const label = self.views[view_index].label;
            const timestamp_ns = automationInputTimestampNs();

            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = window_id,
                .label = label,
                .kind = .pointer_down,
                .timestamp_ns = timestamp_ns,
                .x = point.x,
                .y = point.y,
                .button = 0,
            } });
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = window_id,
                .label = label,
                .kind = .pointer_up,
                .timestamp_ns = timestamp_ns,
                .x = point.x,
                .y = point.y,
                .button = 0,
            } });
        }

        pub fn dispatchAutomationWidgetWheel(self: *Runtime, app: runtime_api.App(Runtime), wheel: AutomationWidgetWheel) anyerror!void {
            const view_index = try automationWidgetTargetViewIndex(self, wheel.target);
            const layout = self.views[view_index].widgetLayoutTree();
            if (!canvasWidgetInteractionTargetExists(layout, wheel.target.id)) return error.InvalidCommand;
            const node = layout.findById(wheel.target.id) orelse return error.InvalidCommand;
            const bounds = node.frame.normalized();
            if (bounds.isEmpty()) return error.InvalidCommand;
            const point = bounds.center();
            const timestamp_ns = automationInputTimestampNs();
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = self.views[view_index].window_id,
                .label = self.views[view_index].label,
                .kind = .scroll,
                .timestamp_ns = timestamp_ns,
                .x = point.x,
                .y = point.y,
                .delta_y = wheel.delta_y,
            } });
        }

        pub fn dispatchAutomationWidgetKeyInput(self: *Runtime, app: runtime_api.App(Runtime), key: AutomationWidgetKey) anyerror!void {
            try validateRuntimeViewParent(self, 1);
            try validateViewLabel(key.view_label);
            const view_index = runtimeFindViewIndex(self, 1, key.view_label) orelse return error.ViewNotFound;
            if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;
            try self.focusView(self.views[view_index].window_id, self.views[view_index].label);
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = self.views[view_index].window_id,
                .label = self.views[view_index].label,
                .kind = .key_down,
                .timestamp_ns = automationInputTimestampNs(),
                .key = key.key,
                .text = key.text,
            } });
        }

        pub fn dispatchAutomationWidgetPointerDrag(self: *Runtime, app: runtime_api.App(Runtime), drag: AutomationWidgetPointerDrag) anyerror!void {
            const view_index = try automationWidgetTargetViewIndex(self, drag.target);
            const layout = self.views[view_index].widgetLayoutTree();
            if (!canvasWidgetInteractionTargetExists(layout, drag.target.id)) return error.InvalidCommand;
            const node = layout.findById(drag.target.id) orelse return error.InvalidCommand;
            const bounds = node.frame.normalized();
            if (bounds.isEmpty()) return error.InvalidCommand;
            const start = geometry.PointF.init(
                bounds.x + bounds.width * drag.start_x_ratio,
                bounds.y + bounds.height * drag.start_y_ratio,
            );
            const end = geometry.PointF.init(
                bounds.x + bounds.width * drag.end_x_ratio,
                bounds.y + bounds.height * drag.end_y_ratio,
            );
            const timestamp_ns = automationInputTimestampNs();

            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = self.views[view_index].window_id,
                .label = self.views[view_index].label,
                .kind = .pointer_down,
                .timestamp_ns = timestamp_ns,
                .x = start.x,
                .y = start.y,
                .button = 0,
            } });
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = self.views[view_index].window_id,
                .label = self.views[view_index].label,
                .kind = .pointer_drag,
                .timestamp_ns = timestamp_ns,
                .x = end.x,
                .y = end.y,
                .delta_x = end.x - start.x,
                .delta_y = end.y - start.y,
                .button = 0,
            } });
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = self.views[view_index].window_id,
                .label = self.views[view_index].label,
                .kind = .pointer_up,
                .timestamp_ns = timestamp_ns,
                .x = end.x,
                .y = end.y,
                .button = 0,
            } });
        }

        pub fn canvasWidgetActionsForId(self: *const Runtime, view_index: usize, id: canvas.ObjectId) ?canvas.WidgetActions {
            if (view_index >= self.view_count or id == 0) return null;
            for (self.views[view_index].widgetSemantics()) |node| {
                if (node.id == id) return node.actions;
            }
            return null;
        }

        pub fn dismissAutomationCanvasWidget(self: *Runtime, view_index: usize, id: canvas.ObjectId) anyerror!void {
            if (view_index >= self.view_count) return error.ViewNotFound;
            self.views[view_index].recordGpuSurfaceInputTimestamp(automationInputTimestampNs());
            const dirty = try self.views[view_index].dismissCanvasWidgetSurfaceForTarget(id) orelse return error.InvalidCommand;
            try CanvasWidgetEventMethods().invalidateForCanvasWidgetDirty(self, view_index, dirty);
        }

        pub fn focusAutomationCanvasWidget(self: *Runtime, view_index: usize, id: canvas.ObjectId) anyerror!void {
            if (view_index >= self.view_count) return error.ViewNotFound;
            const target = self.views[view_index].widgetLayoutTree().focusTargetById(id) orelse return error.InvalidCommand;
            try self.focusView(self.views[view_index].window_id, self.views[view_index].label);
            if (self.views[view_index].canvas_widget_focused_id != target.id or self.views[view_index].canvas_widget_focus_visible_id != target.id) {
                const previous_state = self.views[view_index].canvasWidgetRenderState();
                self.views[view_index].canvas_widget_focused_id = target.id;
                self.views[view_index].canvas_widget_focus_visible_id = target.id;
                try CanvasWidgetEventMethods().invalidateForCanvasWidgetRenderStateChange(self, view_index, previous_state, self.views[view_index].canvasWidgetRenderState());
            }
        }

        pub fn dispatchAutomationWidgetKey(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, id: canvas.ObjectId, key: []const u8) anyerror!void {
            try focusAutomationCanvasWidget(self, view_index, id);
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = self.views[view_index].window_id,
                .label = self.views[view_index].label,
                .kind = .key_down,
                .timestamp_ns = automationInputTimestampNs(),
                .key = key,
            } });
        }

        pub fn selectAutomationCanvasWidget(self: *Runtime, view_index: usize, id: canvas.ObjectId) anyerror!void {
            const layout = self.views[view_index].widgetLayoutTree();
            if (!canvasWidgetSelectableTargetExists(layout, id)) return error.InvalidCommand;
            if (layout.focusTargetById(id) != null) {
                try focusAutomationCanvasWidget(self, view_index, id);
            }
            const dirty = try self.views[view_index].setCanvasWidgetSelected(id, true) orelse return;
            try CanvasWidgetEventMethods().invalidateForCanvasWidgetDirty(self, view_index, dirty);
        }

        pub fn setAutomationCanvasWidgetText(self: *Runtime, view_index: usize, id: canvas.ObjectId, text: []const u8) anyerror!void {
            try focusAutomationCanvasWidget(self, view_index, id);
            const dirty = try self.views[view_index].setCanvasWidgetTextValue(id, text) orelse return;
            try CanvasWidgetEventMethods().invalidateForCanvasWidgetDirty(self, view_index, dirty);
        }

        pub fn editAutomationCanvasWidgetText(self: *Runtime, view_index: usize, id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!void {
            try focusAutomationCanvasWidget(self, view_index, id);
            if (!self.views[view_index].canEditCanvasWidgetText(id)) return error.InvalidCommand;
            const dirty = try self.views[view_index].applyCanvasWidgetTextEdit(id, edit) orelse return;
            try CanvasWidgetEventMethods().invalidateForCanvasWidgetDirty(self, view_index, dirty);
        }

        pub fn dispatchAutomationCanvasWidgetDrag(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, id: canvas.ObjectId, value: []const u8) anyerror!void {
            if (view_index >= self.view_count) return error.ViewNotFound;
            const delta = try parseAutomationDragDelta(value);
            const layout = self.views[view_index].widgetLayoutTree();
            if (!canvasWidgetInteractionTargetExists(layout, id)) return error.InvalidCommand;
            const node = layout.findById(id) orelse return error.InvalidCommand;
            const bounds = node.frame.normalized();
            if (bounds.isEmpty()) return error.InvalidCommand;

            const window_id = self.views[view_index].window_id;
            const label = self.views[view_index].label;
            const origin = bounds.center();
            const previous_pressed_id = self.views[view_index].canvas_widget_pressed_id;
            const previous_state = self.views[view_index].canvasWidgetRenderState();
            self.views[view_index].canvas_widget_pressed_id = id;
            if (previous_pressed_id != id) try CanvasWidgetEventMethods().invalidateForCanvasWidgetRenderStateChange(self, view_index, previous_state, self.views[view_index].canvasWidgetRenderState());
            errdefer {
                if (view_index < self.view_count and self.views[view_index].canvas_widget_pressed_id == id) {
                    self.views[view_index].canvas_widget_pressed_id = previous_pressed_id;
                }
            }

            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = window_id,
                .label = label,
                .kind = .pointer_drag,
                .x = origin.x + delta.dx,
                .y = origin.y + delta.dy,
                .delta_x = delta.dx,
                .delta_y = delta.dy,
            } });

            if (runtimeFindViewIndex(self, window_id, label)) |current_index| {
                if (self.views[current_index].canvas_widget_pressed_id == id) {
                    const release_previous_state = self.views[current_index].canvasWidgetRenderState();
                    self.views[current_index].canvas_widget_pressed_id = 0;
                    try CanvasWidgetEventMethods().invalidateForCanvasWidgetRenderStateChange(self, current_index, release_previous_state, self.views[current_index].canvasWidgetRenderState());
                }
            }
        }

        pub fn dispatchAutomationCanvasWidgetFileDrop(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, id: canvas.ObjectId, value: []const u8) anyerror!void {
            if (view_index >= self.view_count) return error.ViewNotFound;
            const layout = self.views[view_index].widgetLayoutTree();
            if (!canvasWidgetInteractionTargetExists(layout, id)) return error.InvalidCommand;
            var paths_buffer: [platform.max_drop_paths][]const u8 = undefined;
            const paths = try parseAutomationDropPaths(value, paths_buffer[0..]);
            const node = layout.findById(id) orelse return error.InvalidCommand;
            const bounds = node.frame.normalized();
            if (bounds.isEmpty()) return error.InvalidCommand;

            try self.dispatchPlatformEvent(app, .{ .files_dropped = .{
                .window_id = self.views[view_index].window_id,
                .view_label = self.views[view_index].label,
                .point = bounds.center(),
                .paths = paths,
            } });
        }

        fn automationWidgetActionViewIndex(self: *Runtime, action: AutomationWidgetAction) anyerror!usize {
            try validateRuntimeViewParent(self, 1);
            try validateViewLabel(action.view_label);
            const view_index = runtimeFindViewIndex(self, 1, action.view_label) orelse return error.ViewNotFound;
            if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;
            const actions = canvasWidgetActionsForId(self, view_index, action.id) orelse return error.InvalidCommand;
            if (!automationWidgetActionSupported(actions, action.action)) return error.InvalidCommand;
            return view_index;
        }

        fn automationWidgetTargetViewIndex(self: *Runtime, target: AutomationWidgetTarget) anyerror!usize {
            try validateRuntimeViewParent(self, 1);
            try validateViewLabel(target.view_label);
            const view_index = runtimeFindViewIndex(self, 1, target.view_label) orelse return error.ViewNotFound;
            if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;
            return view_index;
        }

        fn CanvasWidgetDisplayMethods() type {
            return runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime);
        }

        fn CanvasWidgetEventMethods() type {
            return runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
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
