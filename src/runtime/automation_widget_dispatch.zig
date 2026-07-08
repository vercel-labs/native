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
const AutomationProvenanceTarget = automation_commands.AutomationProvenanceTarget;
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
                .set_text => try setAutomationCanvasWidgetText(self, app, view_index, action.id, action.value),
                .set_selection => try editAutomationCanvasWidgetText(self, view_index, action.id, .{ .set_selection = try parseAutomationTextSelection(action.value) }),
                .set_composition => try editAutomationCanvasWidgetText(self, view_index, action.id, .{ .set_composition = .{ .text = action.value } }),
                .commit_composition => try editAutomationCanvasWidgetText(self, view_index, action.id, .commit_composition),
                .cancel_composition => try editAutomationCanvasWidgetText(self, view_index, action.id, .cancel_composition),
                .select => try selectAutomationCanvasWidget(self, view_index, action.id),
                .drag => try dispatchAutomationCanvasWidgetDrag(self, app, view_index, action.id, action.value),
                .drop_files => try dispatchAutomationCanvasWidgetFileDrop(self, app, view_index, action.id, action.value),
                .dismiss => try dismissAutomationCanvasWidget(self, app, view_index, action.id),
            }
        }

        pub fn dispatchAutomationWidgetClick(self: *Runtime, app: runtime_api.App(Runtime), target: AutomationWidgetTarget) anyerror!void {
            const view_index = try automationWidgetTargetViewIndex(self, target);
            const point = try automationWidgetAimPoint(self, view_index, target.id);
            const window_id = self.views[view_index].window_id;
            const label = self.views[view_index].label;
            const timestamp_ns = automationInputTimestampNs();

            // One synthetic click is one atomic gesture: the down and up
            // land in the same automation dispatch with no present in
            // between, so an outer refresh batch (the per-input batches
            // nest inside it) coalesces the whole click — press state,
            // release state, and the Msg-driven rebuild — into a single
            // display-list emission with the same final content.
            CanvasWidgetDisplayMethods().beginCanvasWidgetDisplayListRefreshBatch(self);
            var click_batch_active = true;
            errdefer if (click_batch_active) {
                // Flush, not drop: half a click may already have changed
                // widget state that must reach the retained display list.
                CanvasWidgetDisplayMethods().endCanvasWidgetDisplayListRefreshBatch(self) catch {
                    CanvasWidgetDisplayMethods().cancelCanvasWidgetDisplayListRefreshBatch(self);
                };
            };

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
            try CanvasWidgetDisplayMethods().endCanvasWidgetDisplayListRefreshBatch(self);
            click_batch_active = false;
        }

        /// Drive a press-and-hold gesture through the real pointer+timer
        /// path: pointer-down at the control's aim point (the routed
        /// pointer event arms the app's hold timer exactly as a live
        /// press does), the reserved hold timer fired as the platform
        /// would fire it at ~350 ms, then the release — which the fired
        /// hold suppresses, one gesture one Msg. Automation is
        /// time-warped, never path-warped: every step is the event a
        /// live run dispatches. On a target without a hold handler
        /// nothing arms, the fire no-ops, and the release presses — the
        /// same click a real user's long-press-and-release produces.
        pub fn dispatchAutomationWidgetHold(self: *Runtime, app: runtime_api.App(Runtime), target: AutomationWidgetTarget) anyerror!void {
            const view_index = try automationWidgetTargetViewIndex(self, target);
            const point = try automationWidgetAimPoint(self, view_index, target.id);
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
            try self.dispatchPlatformEvent(app, .{ .timer = .{
                .id = platform.press_hold_timer_id,
                .timestamp_ns = timestamp_ns,
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
            // A fired hold's release deliberately does not cancel the
            // platform timer the down armed (the app never cancels a
            // timer that already fired); the wall-clock fire would be a
            // harmless no-op, but cancel it so a live run leaves no
            // pending one-shot behind.
            self.cancelTimer(platform.press_hold_timer_id) catch {};
        }

        /// Drive a secondary click (right/ctrl-click) as the full
        /// button-1 stream a real one produces: the runtime resolves a
        /// context menu on the down (app-declared items, editable-text
        /// and selected-text defaults) and otherwise dispatches the
        /// context-press event — the desktop press-and-hold alternative
        /// whose press target's `on_hold` Msg dispatches immediately.
        pub fn dispatchAutomationWidgetContextPress(self: *Runtime, app: runtime_api.App(Runtime), target: AutomationWidgetTarget) anyerror!void {
            const view_index = try automationWidgetTargetViewIndex(self, target);
            const point = try automationWidgetAimPoint(self, view_index, target.id);
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
                .button = 1,
            } });
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = window_id,
                .label = label,
                .kind = .pointer_up,
                .timestamp_ns = timestamp_ns,
                .x = point.x,
                .y = point.y,
                .button = 1,
            } });
        }

        /// Invoke one of the target widget's DECLARED context-menu items
        /// (`widget-context-menu <view> <id> <item-index>`). The OS
        /// menu's tracking loop cannot be driven programmatically, so
        /// the verb skips presentation and dispatches the SELECTION on
        /// the same path a real pick takes: it arms the pending request
        /// exactly as presenting would, then delivers a
        /// `context_menu_action` platform event — which journals,
        /// replays, and resolves through `dispatchContextMenuAction`
        /// into the widget's `.context_menu` handler. Named errors say
        /// why an invocation cannot happen: no declared menu, an index
        /// past the declared items, a separator slot, or a disabled
        /// item — the same items the snapshot lists per widget.
        pub fn dispatchAutomationWidgetContextMenuItem(self: *Runtime, app: runtime_api.App(Runtime), item: automation_commands.AutomationWidgetContextMenuItem) anyerror!void {
            const view_index = try automationWidgetTargetViewIndex(self, item.target);
            const node_index = self.views[view_index].canvasWidgetNodeIndexById(item.target.id) orelse return error.InvalidCommand;
            const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
            if (widget.context_menu.len == 0) return error.ContextMenuUndeclared;
            if (item.item_index >= widget.context_menu.len) return error.ContextMenuItemOutOfRange;
            const declared = widget.context_menu[item.item_index];
            if (declared.separator) return error.ContextMenuItemSeparator;
            if (!declared.enabled) return error.ContextMenuItemDisabled;

            self.canvas_widget_context_menu_pending = .{
                .window_id = self.views[view_index].window_id,
                .token = widget.id,
                .kind = .app,
            };
            try self.dispatchPlatformEvent(app, .{ .context_menu_action = .{
                .window_id = self.views[view_index].window_id,
                .view_label = self.views[view_index].label,
                .token = widget.id,
                .item_id = @intCast(item.item_index + 1),
            } });
        }

        /// Where a pointer verb lands on a widget: the control's aim
        /// point, not the geometric center — a stretched selection
        /// control (switch as a bare column child) draws its glyph at
        /// the left edge of a wide frame, and the frame's center can sit
        /// under an overlapping later-painted sibling. A real user
        /// clicks the knob.
        fn automationWidgetAimPoint(self: *Runtime, view_index: usize, id: canvas.ObjectId) anyerror!geometry.PointF {
            const layout = self.views[view_index].widgetLayoutTree();
            if (!canvasWidgetInteractionTargetExists(layout, id)) return error.InvalidCommand;
            const node = layout.findById(id) orelse return error.InvalidCommand;
            const bounds = node.frame.normalized();
            if (bounds.isEmpty()) return error.InvalidCommand;
            var aim_widget = node.widget;
            aim_widget.frame = node.frame;
            return canvas.widgetControlAimPoint(aim_widget, self.views[view_index].widget_tokens);
        }

        pub fn dispatchAutomationWidgetWheel(self: *Runtime, app: runtime_api.App(Runtime), wheel: AutomationWidgetWheel) anyerror!void {
            const view_index = try automationWidgetTargetViewIndex(self, wheel.target);
            const layout = self.views[view_index].widgetLayoutTree();
            // Named reasons, not a blanket InvalidCommand: the snapshot's
            // degraded error line carries the error NAME (plus the command
            // arguments as detail), so a failed wheel says WHY. The common
            // trap is aiming at a plain layout node — wheel the scrollable
            // widget (scroll/list/grid id from the snapshot) instead.
            const node = layout.findById(wheel.target.id) orelse return error.WheelTargetUnknown;
            if (!canvasWidgetInteractionTargetExists(layout, wheel.target.id)) return error.WheelTargetNotInteractive;
            const bounds = node.frame.normalized();
            if (bounds.isEmpty()) return error.WheelTargetHasEmptyBounds;
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
            const view_index = try automationGpuSurfaceViewIndexByLabel(self, key.view_label);
            try self.focusView(self.views[view_index].window_id, self.views[view_index].label);
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = self.views[view_index].window_id,
                .label = self.views[view_index].label,
                .kind = .key_down,
                .timestamp_ns = automationInputTimestampNs(),
                .key = key.key,
                .text = key.text,
                .modifiers = .{
                    .shift = key.modifiers.shift,
                    .control = key.modifiers.control,
                    .option = key.modifiers.option,
                    .command = key.modifiers.command,
                    .primary = key.modifiers.primary,
                },
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

        pub fn dismissAutomationCanvasWidget(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, id: canvas.ObjectId) anyerror!void {
            if (view_index >= self.view_count) return error.ViewNotFound;
            self.views[view_index].recordGpuSurfaceInputTimestamp(automationInputTimestampNs());
            const dismissal = try self.views[view_index].dismissCanvasWidgetSurfaceForTarget(id) orelse return error.InvalidCommand;
            try CanvasWidgetEventMethods().invalidateForCanvasWidgetDirty(self, view_index, dismissal.dirty);
            try CanvasWidgetEventMethods().dispatchCanvasWidgetDismissEvent(self, app, view_index, dismissal.id);
        }

        pub fn focusAutomationCanvasWidget(self: *Runtime, view_index: usize, id: canvas.ObjectId) anyerror!void {
            if (view_index >= self.view_count) return error.ViewNotFound;
            const target = self.views[view_index].widgetLayoutTree().focusTargetById(id) orelse return error.InvalidCommand;
            try self.focusView(self.views[view_index].window_id, self.views[view_index].label);
            // Programmatic focus (autofocus, automation `focus`) follows
            // the pointer contract, not the keyboard one: buttons and
            // rows take focus QUIETLY (no ring), editable text kinds show
            // their affordances however focus arrived. A later Tab still
            // moves focus with the visible ring. Without this gate, a
            // window-level default focus landing on a button dressed an
            // idle control in the focus ring.
            const focus_visible_id: canvas.ObjectId = if (canvas_widget_runtime.canvasWidgetEditableTextKind(target.kind)) target.id else 0;
            if (self.views[view_index].canvas_widget_focused_id != target.id or self.views[view_index].canvas_widget_focus_visible_id != focus_visible_id) {
                const previous_state = self.views[view_index].canvasWidgetRenderState();
                self.views[view_index].canvas_widget_focused_id = target.id;
                self.views[view_index].canvas_widget_focus_visible_id = focus_visible_id;
                // A focus change repaints; record the automation input so
                // the completing frame publishes (same contract as select
                // and text edits). Callers that dispatch a follow-up input
                // event simply overwrite this with their own timestamp.
                self.views[view_index].recordGpuSurfaceInputTimestamp(automationInputTimestampNs());
                try CanvasWidgetEventMethods().invalidateForCanvasWidgetRenderStateChange(self, view_index, previous_state, self.views[view_index].canvasWidgetRenderState());
            }
        }

        pub fn dispatchAutomationWidgetKey(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, id: canvas.ObjectId, key: []const u8) anyerror!void {
            try focusAutomationCanvasWidget(self, view_index, id);
            // An automation KEY action emulates the KEYBOARD contract on
            // its target. Plain list rows are transparent to keys under
            // QUIET focus (the quiet-list-row rule in the keyboard
            // routing), so the synthesized activation must reach the row
            // the way a Tab-then-key would: escalate exactly this target
            // kind to the ring register before dispatching. Every other
            // kind keeps the quiet programmatic focus it always had.
            if (self.views[view_index].canvasWidgetNodeIndexById(id)) |node_index| {
                const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
                const plain_list_row = widget.kind == .list_item and widget.semantics.role != .treeitem;
                if (plain_list_row and self.views[view_index].canvas_widget_focus_visible_id != id) {
                    const previous_state = self.views[view_index].canvasWidgetRenderState();
                    self.views[view_index].canvas_widget_focus_visible_id = id;
                    try CanvasWidgetEventMethods().invalidateForCanvasWidgetRenderStateChange(self, view_index, previous_state, self.views[view_index].canvasWidgetRenderState());
                }
            }
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
            // Record the automation input so the frame this repaint
            // presents resolves it into an input latency and republishes
            // observable state (dispatchGpuSurfaceFrame invalidates on a
            // recorded latency; steady-state completions stay quiet).
            // Without this, the snapshot's gpu_frame only advanced when a
            // PREVIOUS interaction happened to leave a dangling pending
            // input for this frame to resolve — a timing accident that a
            // loaded CI runner loses ("menu item automation select did
            // not request a GPU frame").
            self.views[view_index].recordGpuSurfaceInputTimestamp(automationInputTimestampNs());
            try CanvasWidgetEventMethods().invalidateForCanvasWidgetDirty(self, view_index, dirty);
        }

        /// Replace an editable widget's text through the SAME input-event
        /// path real typing uses: focus, a select-all key, then the
        /// replacement text as a text-input event. Each step routes
        /// through `dispatchGpuSurfaceInput`, so the app receives the
        /// matching `.canvas_widget_keyboard` events and an elm-style
        /// model's `on_input` mirror stays consistent with the runtime
        /// editor — writing the editor state directly produced on-screen
        /// state no real user could reach.
        pub fn setAutomationCanvasWidgetText(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize, id: canvas.ObjectId, text: []const u8) anyerror!void {
            try focusAutomationCanvasWidget(self, view_index, id);
            if (!self.views[view_index].canEditCanvasWidgetText(id)) return error.InvalidCommand;
            const window_id = self.views[view_index].window_id;
            const label = self.views[view_index].label;
            const timestamp_ns = automationInputTimestampNs();

            // Select all (the platform primary shortcut), exactly like a
            // user pressing cmd/ctrl+a in the focused field.
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = window_id,
                .label = label,
                .kind = .key_down,
                .timestamp_ns = timestamp_ns,
                .key = "a",
                .modifiers = .{ .primary = true },
            } });
            if (text.len == 0) {
                // Empty replacement: delete the selection.
                try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                    .window_id = window_id,
                    .label = label,
                    .kind = .key_down,
                    .timestamp_ns = timestamp_ns,
                    .key = "backspace",
                } });
                return;
            }
            try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .window_id = window_id,
                .label = label,
                .kind = .text_input,
                .timestamp_ns = timestamp_ns,
                .text = text,
            } });
        }

        pub fn editAutomationCanvasWidgetText(self: *Runtime, view_index: usize, id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!void {
            try focusAutomationCanvasWidget(self, view_index, id);
            if (!self.views[view_index].canEditCanvasWidgetText(id)) return error.InvalidCommand;
            const dirty = try self.views[view_index].applyCanvasWidgetTextEdit(id, edit) orelse return;
            // Same observability contract as selectAutomationCanvasWidget:
            // the repaint this edit triggers must publish its completing
            // frame, so record the automation input it resolves.
            self.views[view_index].recordGpuSurfaceInputTimestamp(automationInputTimestampNs());
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
            const view_index = try automationGpuSurfaceViewIndexByLabel(self, action.view_label);
            const actions = canvasWidgetActionsForId(self, view_index, action.id) orelse return error.InvalidCommand;
            if (!automationWidgetActionSupported(actions, action.action)) return error.InvalidCommand;
            return view_index;
        }

        fn automationWidgetTargetViewIndex(self: *Runtime, target: AutomationWidgetTarget) anyerror!usize {
            return automationGpuSurfaceViewIndexByLabel(self, target.view_label);
        }

        /// The `provenance` verb: resolve the view (and, for point
        /// queries, hit-test the widget id), then ask the app that
        /// authored the view to answer from its retained provenance
        /// table. Every path writes `provenance.txt` — the CLI polls the
        /// artifact, so silence would be a hang, and errors teach.
        pub fn dispatchAutomationProvenance(self: *Runtime, app: runtime_api.App(Runtime), target: AutomationProvenanceTarget) anyerror!void {
            const server = self.options.automation orelse return;
            self.command_count += 1;
            const view_index = automationGpuSurfaceViewIndexByLabel(self, target.view_label) catch {
                try publishAutomationProvenanceError(server, target.view_label, target.id, "no open gpu_surface view with this label - `native automate list` names the open views");
                return error.ViewNotFound;
            };
            const layout = self.views[view_index].widgetLayoutTree();
            var id = target.id;
            if (target.point) |point| {
                const hit = layout.hitTest(point) orelse {
                    try publishAutomationProvenanceError(server, target.view_label, 0, "no widget at the given point (view-local points; the snapshot's bounds= fields name each widget's rectangle)");
                    return error.InvalidCommand;
                };
                id = hit.id;
            } else if (layout.findById(id) == null) {
                try publishAutomationProvenanceError(server, target.view_label, id, "no widget with this id in the view - ids go stale across rebuilds, re-read the snapshot");
                return error.InvalidCommand;
            }
            self.automation_provenance_published = false;
            try app.event(self, .{ .automation_provenance = .{
                .window_id = self.views[view_index].window_id,
                .view_label = self.views[view_index].label,
                .widget_id = id,
            } });
            if (!self.automation_provenance_published) {
                try publishAutomationProvenanceError(server, target.view_label, id, "the app exposes no widget provenance - it needs the markup interpreter (UiAppFeatures.runtime_markup) running under automation; compiled-only (release) views report none");
            }
        }

        /// Resolve a widget verb's gpu_surface view by label across ALL
        /// open windows — snapshots enumerate every window's views, so
        /// the verbs must reach them too (a model-declared settings
        /// window's canvas is as drivable as the main one). Labels are
        /// the verb's whole address; `UiApp` keeps canvas labels unique
        /// per window, and for hand-rolled duplicates the first open
        /// match in window order wins, deterministically.
        pub fn automationGpuSurfaceViewIndexByLabel(self: *Runtime, view_label: []const u8) anyerror!usize {
            try validateViewLabel(view_label);
            for (self.views[0..self.view_count], 0..) |*view, index| {
                if (!view.open or view.kind != .gpu_surface) continue;
                if (!std.mem.eql(u8, view.label, view_label)) continue;
                const window_index = runtimeFindWindowIndexById(self, view.window_id) orelse continue;
                if (!self.windows[window_index].info.open) continue;
                return index;
            }
            return error.ViewNotFound;
        }

        fn CanvasWidgetDisplayMethods() type {
            return runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime);
        }

        fn CanvasWidgetEventMethods() type {
            return runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
        }
    };
}

fn publishAutomationProvenanceError(server: anytype, view_label: []const u8, id: u64, message: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("provenance error view={s} id={d} message=\"{s}\"\n", .{ view_label, id, message });
    try server.publishProvenanceResponse(writer.buffered());
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
