const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const validation = @import("validation.zig");
const runtime_api = @import("api.zig");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");
const runtime_canvas_widget_display = @import("canvas_widget_display.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const runtime_view = @import("view.zig");
const widget_bridge = @import("widget_bridge.zig");

const canvasRenderAnimationStartNsForView = runtime_view.canvasRenderAnimationStartNsForView;

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

/// Multi-click chain window: a primary pointer-down within this many
/// nanoseconds of the previous one (and within the slop below) raises
/// the click count instead of starting over. 500 ms is the common
/// platform default double-click speed; the runtime derives the count
/// itself instead of threading a host click count because (a) the
/// derivation runs identically on every platform including the null
/// platform tests, and (b) it reads only fields the session journal
/// already records (timestamp, point, button), so replay reproduces
/// the exact same gesture without a journal format change. The
/// tradeoff — the user's system double-click speed setting is not
/// consulted — is accepted and pinned here.
const canvas_widget_multi_click_interval_ns: u64 = 500 * std.time.ns_per_ms;

/// Movement slop per axis (canvas points) between chained clicks: a
/// hand tremor keeps the chain, a click somewhere else breaks it.
const canvas_widget_multi_click_slop: f32 = 4.0;

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
            // FRAMEWORK BEHAVIOR CHANGE (deliberate, scoped): a QUIETLY
            // focused plain list row routes no keyboard input — keys
            // reach the app as target-less events, exactly as if nothing
            // were focused. Quiet focus is the pointer/programmatic
            // contract (no ring); on a list row it is bookkeeping, not a
            // keyboard cursor, and letting it claim keys made a stale
            // clicked row swallow the arrows/Enter an app-level
            // selection model owns. The Tab-established ring register
            // (focus_visible) keeps today's behavior in full: activation
            // keys select, arrows walk rows. Tree rows (role treeitem)
            // are exempt — their roving-focus keymap is the feature.
            if (canvasWidgetQuietListRowFocus(self, index, focused_id)) return null;
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

        /// Whether keyboard focus sits QUIETLY (no visible ring) on a
        /// plain list row — the one focus state the keyboard seams above
        /// treat as transparent. Quiet focus lands on rows from pointer
        /// presses and programmatic focus; it exists so activation can
        /// find "the thing the user last touched", not to make the row a
        /// keyboard cursor. Plain means `kind == .list_item` without the
        /// treeitem role: ARIA tree rows carry a roving-focus keymap by
        /// design and keep every key they have today.
        fn canvasWidgetQuietListRowFocus(self: *const Runtime, index: usize, focused_id: canvas.ObjectId) bool {
            if (focused_id == 0) return false;
            if (self.views[index].canvas_widget_focus_visible_id == focused_id) return false;
            const node_index = self.views[index].canvasWidgetNodeIndexById(focused_id) orelse return false;
            const widget = self.views[index].widget_layout_nodes[node_index].widget;
            return widget.kind == .list_item and widget.semantics.role != .treeitem;
        }

        /// Stamp the routed pointer event with its click count and
        /// advance the view's multi-click chain. Downs count (a rapid
        /// same-spot primary down raises the count, anything else
        /// restarts at 1); moves and ups carry the count of the press
        /// that started the gesture, so a double-click drag extends by
        /// words all the way to its release. Timestamps of 0 (a host or
        /// test that never stamps them) never chain — such inputs
        /// honestly degrade to single clicks instead of making every
        /// click a double-click.
        pub fn updateCanvasWidgetClickCountFromPointer(self: *Runtime, input_event: GpuSurfaceInputEvent, pointer_event: *CanvasWidgetPointerEvent) void {
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            switch (pointer_event.pointer.phase) {
                .down => {
                    if (input_event.button != 0) {
                        // A non-primary press breaks the chain (its own
                        // gesture — middle-click — never multi-clicks
                        // text; right-click was consumed by the context
                        // menu path before reaching here).
                        self.views[index].canvas_widget_click_count = 0;
                        self.views[index].canvas_widget_click_timestamp_ns = 0;
                        return;
                    }
                    const previous_count = self.views[index].canvas_widget_click_count;
                    const previous_timestamp = self.views[index].canvas_widget_click_timestamp_ns;
                    const previous_point = self.views[index].canvas_widget_click_point;
                    const point = pointer_event.pointer.point;
                    const chained = previous_count != 0 and
                        previous_timestamp != 0 and
                        input_event.timestamp_ns >= previous_timestamp and
                        input_event.timestamp_ns - previous_timestamp <= canvas_widget_multi_click_interval_ns and
                        @abs(point.x - previous_point.x) <= canvas_widget_multi_click_slop and
                        @abs(point.y - previous_point.y) <= canvas_widget_multi_click_slop;
                    // Clamp at 3: a fourth rapid click repeats the
                    // triple behavior, the platform text-view rule.
                    const count: u8 = if (chained) @min(previous_count + 1, 3) else 1;
                    self.views[index].canvas_widget_click_count = count;
                    self.views[index].canvas_widget_click_timestamp_ns = input_event.timestamp_ns;
                    self.views[index].canvas_widget_click_point = point;
                    pointer_event.pointer.click_count = count;
                },
                .move, .up => {
                    pointer_event.pointer.click_count = @max(self.views[index].canvas_widget_click_count, 1);
                },
                .hover, .cancel, .wheel => {},
            }
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

            // Hover and cursor resolve through the hover-target walk (the
            // press fall-through): a composite row is ONE interactive
            // surface, so a pointer over the row's own text/icon/badge
            // children keeps the row's wash and cursor instead of holing
            // them per child. The pressed id stays the RAW hit — static
            // text drag-selection extends against it, so resolving it
            // would break click-drag copy inside pressable rows.
            const layout_tree = self.views[index].widgetLayoutTree();
            const target_id: canvas.ObjectId = if (pointer_event.target) |target| target.id else 0;
            const hover_target = layout_tree.hoverTargetForHit(pointer_event.target);
            const hover_target_id: canvas.ObjectId = if (hover_target) |value| value.id else 0;
            const hit_target = layout_tree.hoverTargetForHit(layout_tree.hitTestWithTokens(pointer_event.pointer.point, self.views[index].widget_tokens));
            const hit_target_id: canvas.ObjectId = if (hit_target) |value| value.id else 0;
            const hit_cursor = platformCursorFromCanvas(layout_tree.cursorForHit(hit_target));
            var next_hovered_id = self.views[index].canvas_widget_hovered_id;
            var next_pressed_id = self.views[index].canvas_widget_pressed_id;
            var next_cursor = self.views[index].canvas_widget_cursor;

            switch (pointer_event.pointer.phase) {
                .hover, .move => {
                    next_hovered_id = hit_target_id;
                    next_cursor = hit_cursor;
                },
                .down => {
                    next_hovered_id = hover_target_id;
                    next_pressed_id = target_id;
                    next_cursor = platformCursorFromCanvas(layout_tree.cursorForHit(hover_target));
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

            // Hover-detail chrome (chart cursor + floating card) tracks
            // the pointer, but only SNAPPED: the stored point updates
            // whenever the pointer is over a hover-detail widget, and a
            // repaint fires only when the snapped sample index changes —
            // gliding within one sample costs nothing.
            const next_hover_point: ?geometry.PointF = if (pointer_event.pointer.phase != .cancel and
                canvasChartHoverIndexForId(self, index, next_hovered_id, pointer_event.pointer.point) != null)
                pointer_event.pointer.point
            else
                null;
            const hover_detail_changed = !std.meta.eql(
                canvasChartHoverKey(self, index, self.views[index].canvas_widget_hovered_id, self.views[index].canvas_widget_hover_point),
                canvasChartHoverKey(self, index, next_hovered_id, next_hover_point),
            );

            // Anchored-tooltip hover intent steps on hover-target
            // transitions (a pointer gliding within one trigger is
            // free); the armed delay itself fires on presented-frame
            // timestamps in advanceCanvasTooltipIntentForFrame. A
            // .cancel carries no trustworthy position, so it steps the
            // machine point-blind (immediate hide semantics).
            const tooltip_intent_point: ?geometry.PointF = if (pointer_event.pointer.phase == .cancel) null else pointer_event.pointer.point;
            if (self.views[index].canvas_widget_hovered_id != next_hovered_id) {
                try updateCanvasTooltipIntentForHoverChange(self, index, next_hovered_id, tooltip_intent_point);
            }
            // While a pointer-shown tooltip is up, EVERY move also steps
            // the travel check: crossing the anchor gap or gliding over
            // the tooltip's own frame usually changes no hover target
            // (the tooltip is deliberately not hit-tested), so the
            // transition gate above cannot see it.
            if (pointer_event.pointer.phase == .hover or pointer_event.pointer.phase == .move) {
                try updateCanvasTooltipIntentForPointerTravel(self, index, next_hovered_id, pointer_event.pointer.point);
            }
            // A press ends the tooltip conversation outright — pending
            // reveal, shown tooltip, and warm window alike (after the
            // hover step above, so a down that also moved the hover
            // cannot re-arm or warm past the press).
            if (pointer_event.pointer.phase == .down) {
                try updateCanvasTooltipIntentForPress(self, index);
            }

            const interaction_changed = self.views[index].canvas_widget_hovered_id != next_hovered_id or
                self.views[index].canvas_widget_pressed_id != next_pressed_id or
                hover_detail_changed;
            const cursor_changed = self.views[index].canvas_widget_cursor != next_cursor;
            // The stored point only advances when the snapped sample (or
            // any other interaction) changes: hover chrome is a pure
            // function of the snapped index, so a stale point that maps
            // to the same sample renders the same pixels.
            if (!interaction_changed and !cursor_changed) return;

            const previous_state = self.views[index].canvasWidgetRenderState();
            self.views[index].canvas_widget_hovered_id = next_hovered_id;
            self.views[index].canvas_widget_pressed_id = next_pressed_id;
            self.views[index].canvas_widget_hover_point = next_hover_point;
            self.views[index].canvas_widget_cursor = next_cursor;
            if (cursor_changed) try syncCanvasWidgetCursorForView(self, index);
            if (interaction_changed) try invalidateForCanvasWidgetRenderStateChange(self, index, previous_state, self.views[index].canvasWidgetRenderState());
        }

        /// The (widget id, snapped sample index) pair chart hover chrome
        /// renders for, or null when the id/point pair paints none — the
        /// equality key that gates hover-detail repaints.
        const CanvasChartHoverKey = struct { id: canvas.ObjectId, index: usize };

        fn canvasChartHoverKey(self: *Runtime, view_index: usize, hovered_id: canvas.ObjectId, point: ?geometry.PointF) ?CanvasChartHoverKey {
            const hover_point = point orelse return null;
            const sample = canvasChartHoverIndexForId(self, view_index, hovered_id, hover_point) orelse return null;
            return .{ .id = hovered_id, .index = sample };
        }

        /// The anchored-tooltip hover-intent state machine, stepped on
        /// every hover-target transition. Anchored tooltips are
        /// runtime-owned presentation chrome — the model never hears
        /// hover:
        ///   - the pointer reaches a tooltip's trigger: arm the show
        ///     delay (`tooltip-delay`, default the
        ///     `tooltip_show_delay_ms` token) on the recorded clock —
        ///     unless the shared warm window is open or the delay is 0,
        ///     which show immediately;
        ///   - the pointer leaves before the delay fires: disarm, show
        ///     nothing (sweeping a toolbar flashes no tooltips);
        ///   - a SHOWN tooltip's trigger loses the pointer: hide it and
        ///     open the warm window (`tooltip_warm_window_ms`), so the
        ///     neighboring trigger explains itself instantly.
        /// `now` is `canvasRenderAnimationStartNsForView` — the freshest
        /// journaled input/frame timestamp, never a wall clock — so a
        /// recorded sweep replays every show/hide frame byte-identically.
        ///
        /// `point` is the pointer position that produced this
        /// transition, when one exists: it lets a SHOWN tooltip hold
        /// through a move into its own frame or across the anchor gap
        /// (see `updateCanvasTooltipIntentForPointerTravel`). Pass null
        /// for point-blind steps — pointer cancel, and scroll paths
        /// without a live pointer position — which keep the classic
        /// immediate-hide semantics.
        fn updateCanvasTooltipIntentForHoverChange(self: *Runtime, view_index: usize, next_hovered_id: canvas.ObjectId, point: ?geometry.PointF) anyerror!void {
            const view = &self.views[view_index];
            const now_ns = canvasRenderAnimationStartNsForView(view);
            const tooltip_index: ?usize = blk: {
                if (next_hovered_id == 0) break :blk null;
                const hovered_index = view.canvasWidgetNodeIndexById(next_hovered_id) orelse break :blk null;
                break :blk view.canvasWidgetOwnedTooltipIndex(hovered_index);
            };
            const tooltip_id: canvas.ObjectId = if (tooltip_index) |node_index| view.widget_layout_nodes[node_index].widget.id else 0;

            var shown_changed = false;
            // The pointer sitting inside the shown tooltip's own frame
            // holds it open (WCAG 1.4.13: hover-revealed content must be
            // hoverable; Base UI tooltips default `hoverable`). The
            // tooltip stays OUT of hit-testing — it is presentation
            // chrome, and claiming hover or presses would put a
            // non-interactive surface into interaction routing and the
            // a11y tree's hover story — so the hold is a geometric test
            // against the shown frame here in the intent machine.
            const held_by_content = canvasTooltipShownContentContains(view, point);
            // A FOCUS-shown tooltip is held by the keyboard, not the
            // pointer: hover leaving some other widget must not tear it
            // down (the shadcn/Base UI focus-open holds through pointer
            // traffic). Only the focus path — or a completed pointer
            // intent below, which takes over the single shown slot —
            // moves it.
            if (view.canvas_tooltip_shown_id != 0 and view.canvas_tooltip_shown_id != tooltip_id and !view.canvas_tooltip_shown_from_focus) {
                // Crossing the anchor gap: a leave whose pointer is still
                // inside the transit corridor keeps the tooltip up (the
                // travel step opens the bounded grace); one that owns a
                // DIFFERENT tooltip transfers immediately (the warm-window
                // sweep), and everything else hides on the spot.
                const held_in_transit = tooltip_id == 0 and canvasTooltipTravelRegionContains(view, point);
                if (!held_by_content and !held_in_transit) {
                    hideShownCanvasTooltipWithWarmth(view, now_ns);
                    shown_changed = true;
                }
            }
            if (view.canvas_tooltip_armed_id != 0 and view.canvas_tooltip_armed_id != tooltip_id) {
                view.canvas_tooltip_armed_id = 0;
                view.canvas_tooltip_armed_owner_id = 0;
                view.canvas_tooltip_deadline_ns = 0;
            }
            if (tooltip_index) |node_index| {
                // Hover reached through the shown tooltip's frame belongs
                // to the tooltip, not to whatever sits beneath it: never
                // arm (or warm-show) a trigger the pointer is not
                // actually on.
                if (view.canvas_tooltip_shown_id != tooltip_id and tooltip_id != 0 and !held_by_content) {
                    const delay_ns = canvasTooltipShowDelayNs(view.widget_layout_nodes[node_index].widget, view.widget_tokens);
                    if (delay_ns == 0 or now_ns < view.canvas_tooltip_warm_until_ns) {
                        view.canvas_tooltip_shown_id = tooltip_id;
                        view.canvas_tooltip_shown_owner_id = next_hovered_id;
                        view.canvas_tooltip_shown_from_focus = false;
                        view.canvas_tooltip_armed_id = 0;
                        view.canvas_tooltip_armed_owner_id = 0;
                        view.canvas_tooltip_deadline_ns = 0;
                        view.canvas_tooltip_transit_deadline_ns = 0;
                        if (point) |value| view.canvas_tooltip_pointer_from = value;
                        shown_changed = true;
                    } else if (view.canvas_tooltip_armed_id != tooltip_id) {
                        view.canvas_tooltip_armed_id = tooltip_id;
                        view.canvas_tooltip_armed_owner_id = next_hovered_id;
                        view.canvas_tooltip_deadline_ns = now_ns + delay_ns;
                        // Seed the transit apex at arm time: a dwell that
                        // completes on the frame clock has no pointer
                        // position of its own, and the corridor for the
                        // eventual leave must fan out from a point that
                        // was really on the trigger.
                        if (point) |value| view.canvas_tooltip_pointer_from = value;
                    }
                }
            }
            if (shown_changed) try commitCanvasTooltipVisibility(self, view_index);
        }

        /// The travel half of hoverable tooltip content, stepped on
        /// EVERY pointer move while a pointer-shown tooltip is up (the
        /// hover-change step alone cannot see moves that stay on one
        /// hover target while crossing the anchor gap or the tooltip's
        /// frame, because the tooltip is deliberately not hit-tested):
        ///   - on the owning trigger or inside the shown tooltip's
        ///     frame: held — remember the position as the corridor apex
        ///     and close any running transit;
        ///   - outside both but inside the transit corridor (the convex
        ///     fan from the apex to the trigger and tooltip frames —
        ///     Base UI's safe-polygon shape): keep the tooltip up and
        ///     re-arm the bounded deadline, so a slow deliberate
        ///     crossing never races a timer (WCAG 1.4.13) while a
        ///     pointer that parks in the gap still resolves on the
        ///     frame clock, replay-deterministically;
        ///   - outside the corridor: hide with the usual pointer-hide
        ///     warm window.
        /// The safe-polygon corridor was chosen over a pure transit
        /// time window because it keeps every motion AWAY from the
        /// tooltip hiding on the move itself — the pre-hoverable
        /// semantics tests and recorded sessions pin — and holds only
        /// motion that is honestly en route to the content; the
        /// deadline bounds it so replay and long-idle behavior stay
        /// deterministic (Base UI's safe polygon is unbounded).
        fn updateCanvasTooltipIntentForPointerTravel(self: *Runtime, view_index: usize, next_hovered_id: canvas.ObjectId, point: geometry.PointF) anyerror!void {
            const view = &self.views[view_index];
            if (view.canvas_tooltip_shown_id == 0 or view.canvas_tooltip_shown_from_focus) {
                view.canvas_tooltip_transit_deadline_ns = 0;
                return;
            }
            const now_ns = canvasRenderAnimationStartNsForView(view);
            const on_owner = next_hovered_id != 0 and next_hovered_id == view.canvas_tooltip_shown_owner_id;
            if (on_owner or canvasTooltipShownContentContains(view, point)) {
                view.canvas_tooltip_pointer_from = point;
                view.canvas_tooltip_transit_deadline_ns = 0;
                return;
            }
            if (canvasTooltipTravelRegionContains(view, point)) {
                view.canvas_tooltip_transit_deadline_ns = now_ns + tooltip_transit_grace_ms * std.time.ns_per_ms;
                return;
            }
            hideShownCanvasTooltipWithWarmth(view, now_ns);
            try commitCanvasTooltipVisibility(self, view_index);
        }

        /// Hide the pointer-shown tooltip and open the shared warm
        /// window — the one pointer-hide shape every path shares. Any
        /// in-flight transit grace dies with the tooltip it was holding.
        fn hideShownCanvasTooltipWithWarmth(view: anytype, now_ns: u64) void {
            view.canvas_tooltip_shown_id = 0;
            view.canvas_tooltip_shown_owner_id = 0;
            view.canvas_tooltip_shown_from_focus = false;
            view.canvas_tooltip_warm_until_ns = now_ns + canvasTooltipWarmWindowNs(view.widget_tokens);
            view.canvas_tooltip_transit_deadline_ns = 0;
        }

        /// Whether `point` sits inside the SHOWN tooltip's own frame —
        /// the hoverable-content test. Null points (cancel, point-blind
        /// scroll steps) never hold.
        fn canvasTooltipShownContentContains(view: anytype, point: ?geometry.PointF) bool {
            const value = point orelse return false;
            if (view.canvas_tooltip_shown_id == 0 or view.canvas_tooltip_shown_from_focus) return false;
            const node_index = view.canvasWidgetNodeIndexById(view.canvas_tooltip_shown_id) orelse return false;
            return view.widget_layout_nodes[node_index].frame.containsPoint(value);
        }

        /// Whether `point` sits inside the transit corridor between the
        /// pointer's last held position and the shown tooltip: the
        /// convex fan from the apex to the tooltip's frame plus the fan
        /// back to the owning trigger's frame (so content-to-trigger
        /// returns cross the same gap). This is Base UI's safe-polygon
        /// shape, evaluated against journaled pointer positions only.
        fn canvasTooltipTravelRegionContains(view: anytype, point: ?geometry.PointF) bool {
            const value = point orelse return false;
            if (view.canvas_tooltip_shown_id == 0 or view.canvas_tooltip_shown_from_focus) return false;
            const apex = view.canvas_tooltip_pointer_from;
            if (view.canvasWidgetNodeIndexById(view.canvas_tooltip_shown_id)) |node_index| {
                if (canvasTooltipTravelFanContains(apex, view.widget_layout_nodes[node_index].frame, value)) return true;
            }
            if (view.canvasWidgetNodeIndexById(view.canvas_tooltip_shown_owner_id)) |node_index| {
                if (canvasTooltipTravelFanContains(apex, view.widget_layout_nodes[node_index].frame, value)) return true;
            }
            return false;
        }

        /// Point-in-convex-hull for the fan from `apex` over `rect`:
        /// the rect itself plus the four apex-to-adjacent-corner
        /// triangles cover exactly the hull of {apex} ∪ rect.
        fn canvasTooltipTravelFanContains(apex: geometry.PointF, rect: geometry.RectF, point: geometry.PointF) bool {
            if (rect.containsPoint(point)) return true;
            const corners = [4]geometry.PointF{
                .{ .x = rect.x, .y = rect.y },
                .{ .x = rect.maxX(), .y = rect.y },
                .{ .x = rect.maxX(), .y = rect.maxY() },
                .{ .x = rect.x, .y = rect.maxY() },
            };
            inline for (0..4) |index| {
                if (canvasTooltipPointInTriangle(point, apex, corners[index], corners[(index + 1) % 4])) return true;
            }
            return false;
        }

        /// Sign-consistency point-in-triangle (boundary counts as
        /// inside; degenerate triangles — an apex on the rect edge —
        /// collapse to their boundary and stay honest).
        fn canvasTooltipPointInTriangle(p: geometry.PointF, a: geometry.PointF, b: geometry.PointF, c: geometry.PointF) bool {
            const d1 = canvasTooltipCross(p, a, b);
            const d2 = canvasTooltipCross(p, b, c);
            const d3 = canvasTooltipCross(p, c, a);
            const has_neg = d1 < 0 or d2 < 0 or d3 < 0;
            const has_pos = d1 > 0 or d2 > 0 or d3 > 0;
            return !(has_neg and has_pos);
        }

        fn canvasTooltipCross(p: geometry.PointF, a: geometry.PointF, b: geometry.PointF) f32 {
            return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
        }

        /// The armed show delay fires on the presented frame's RECORDED
        /// timestamp (never a wall clock) — the layout-tween discipline —
        /// so session replay reproduces the exact frame a dwell's tooltip
        /// appears on. The frame pump in planCanvasFrameForView keeps
        /// frames coming while a delay is armed.
        pub fn advanceCanvasTooltipIntentForFrame(self: *Runtime, view_index: usize, timestamp_ns: u64) anyerror!void {
            const view = &self.views[view_index];
            // A transit grace that ran out resolves here, on the same
            // recorded frame clock the show delay fires on: the pointer
            // parked in the corridor without arriving, so the tooltip
            // hides with the usual pointer-hide warmth — a
            // deterministic frame in replay, exactly like the show.
            if (view.canvas_tooltip_shown_id != 0 and !view.canvas_tooltip_shown_from_focus and
                view.canvas_tooltip_transit_deadline_ns != 0 and timestamp_ns >= view.canvas_tooltip_transit_deadline_ns)
            {
                hideShownCanvasTooltipWithWarmth(view, timestamp_ns);
                try commitCanvasTooltipVisibility(self, view_index);
            }
            if (view.canvas_tooltip_armed_id == 0) return;
            if (timestamp_ns < view.canvas_tooltip_deadline_ns) return;
            view.canvas_tooltip_shown_id = view.canvas_tooltip_armed_id;
            view.canvas_tooltip_shown_owner_id = view.canvas_tooltip_armed_owner_id;
            view.canvas_tooltip_shown_from_focus = false;
            view.canvas_tooltip_armed_id = 0;
            view.canvas_tooltip_armed_owner_id = 0;
            view.canvas_tooltip_deadline_ns = 0;
            view.canvas_tooltip_transit_deadline_ns = 0;
            try commitCanvasTooltipVisibility(self, view_index);
        }

        /// Pointer-down resets the WHOLE intent machine: a press on the
        /// armed trigger cancels the pending reveal (no tooltip mid- or
        /// post-activation), a press on a shown tooltip's trigger
        /// dismisses it, and the warm window closes with it — an
        /// activated control has explained itself, so the post-click
        /// hover must earn the full delay again instead of instantly
        /// re-showing. This is shadcn's Base UI-backed default (a
        /// trigger press closes its tooltip) and the platform norm —
        /// macOS help tags vanish on any click. Any-press semantics are
        /// deliberate: a down elsewhere has already moved hover or is
        /// moving focus off the trigger, so the broad reset never fights
        /// the narrower paths, and it keeps window-drag and capture
        /// corners honest.
        /// A view that stops being FOCUSED drops its whole tooltip
        /// conversation — armed delay, shown tooltip (focus-owned AND
        /// pointer-owned), warm window, transit grace — and re-stamps
        /// the tooltip hidden. The focus-shown tooltip's blur-hides
        /// contract (shadcn's Base UI-backed default) extends to the
        /// VIEW: the widget focus bookkeeping survives a view switch so
        /// focus can return where it was, but a tooltip is transient
        /// explanation for the interaction the user just left — keeping
        /// one painted (or letting a warm window smolder) in a view
        /// that no longer hears the keyboard is a stale affordance, and
        /// its semantics node would keep claiming visible in the a11y
        /// tree. Both focus seams call this: per-view focus moves
        /// (setFocusedView, from input and from the focus commands) and
        /// window-level focus loss (clearFocusedView).
        pub fn resetCanvasTooltipIntentForViewBlur(self: *Runtime, view_index: usize) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            const view = &self.views[view_index];
            const had_shown = view.canvas_tooltip_shown_id != 0;
            view.canvas_tooltip_armed_id = 0;
            view.canvas_tooltip_armed_owner_id = 0;
            view.canvas_tooltip_deadline_ns = 0;
            view.canvas_tooltip_warm_until_ns = 0;
            view.canvas_tooltip_transit_deadline_ns = 0;
            view.canvas_tooltip_shown_id = 0;
            view.canvas_tooltip_shown_owner_id = 0;
            view.canvas_tooltip_shown_from_focus = false;
            if (had_shown) try commitCanvasTooltipVisibility(self, view_index);
        }

        /// The press reset, keyed by the raw input's view identity: the
        /// entry point for pointer-downs that never reach the widget
        /// press pipeline — secondary-button downs consumed by the
        /// context-menu gesture and primary downs consumed by a
        /// window-drag region. "Pointer-down dismisses" is documented
        /// for ANY down (shadcn's Base UI-backed default; macOS help
        /// tags vanish on any click), so those consumed downs must
        /// reset the machine too.
        pub fn updateCanvasTooltipIntentForPressInput(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!void {
            const index = runtimeFindViewIndex(self, window_id, label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            try updateCanvasTooltipIntentForPress(self, index);
        }

        fn updateCanvasTooltipIntentForPress(self: *Runtime, view_index: usize) anyerror!void {
            const view = &self.views[view_index];
            view.canvas_tooltip_armed_id = 0;
            view.canvas_tooltip_armed_owner_id = 0;
            view.canvas_tooltip_deadline_ns = 0;
            view.canvas_tooltip_warm_until_ns = 0;
            view.canvas_tooltip_transit_deadline_ns = 0;
            if (view.canvas_tooltip_shown_id == 0) return;
            view.canvas_tooltip_shown_id = 0;
            view.canvas_tooltip_shown_owner_id = 0;
            view.canvas_tooltip_shown_from_focus = false;
            try commitCanvasTooltipVisibility(self, view_index);
        }

        /// Keyboard FOCUS-VISIBLE reaching a tooltip-owning trigger
        /// reveals its tooltip IMMEDIATELY — keyboard navigation is
        /// deliberate, so there is no dwell to prove intent (shadcn's
        /// Base UI-backed default: tooltips open instantly on keyboard
        /// focus, and WCAG 1.4.13 wants hover/focus-revealed content
        /// reachable without pointer timing). Focus moving on (or
        /// clearing) hides a focus-shown tooltip just as immediately,
        /// and deliberately WITHOUT opening the pointer's warm window:
        /// warmth is a pointer-sweep courtesy, and tabbing through a
        /// toolbar should not make later hovers instant. Only the
        /// keyboard focus path calls this — pointer-established
        /// focus-visible (an editable's caret contract) keeps tooltips
        /// on the hover-intent path, mirroring Base UI's focus-visible
        /// guard against click-focus opens.
        fn updateCanvasTooltipIntentForFocusVisibleChange(self: *Runtime, view_index: usize, focus_visible_id: canvas.ObjectId) anyerror!void {
            const view = &self.views[view_index];
            const tooltip_index: ?usize = blk: {
                if (focus_visible_id == 0) break :blk null;
                const focused_index = view.canvasWidgetNodeIndexById(focus_visible_id) orelse break :blk null;
                break :blk view.canvasWidgetOwnedTooltipIndex(focused_index);
            };
            const tooltip_id: canvas.ObjectId = if (tooltip_index) |node_index| view.widget_layout_nodes[node_index].widget.id else 0;

            var shown_changed = false;
            if (view.canvas_tooltip_shown_id != 0 and view.canvas_tooltip_shown_from_focus and view.canvas_tooltip_shown_id != tooltip_id) {
                view.canvas_tooltip_shown_id = 0;
                view.canvas_tooltip_shown_owner_id = 0;
                view.canvas_tooltip_shown_from_focus = false;
                shown_changed = true;
            }
            if (tooltip_id != 0) {
                if (view.canvas_tooltip_shown_id != tooltip_id) {
                    view.canvas_tooltip_shown_id = tooltip_id;
                    shown_changed = true;
                }
                // Focus re-affirms an already pointer-shown tooltip too:
                // the keyboard now holds it, so pointer leave (which
                // opens the warm window) no longer hides it — blur will.
                // Any pointer transit grace dies with the handover.
                view.canvas_tooltip_shown_owner_id = focus_visible_id;
                view.canvas_tooltip_shown_from_focus = true;
                view.canvas_tooltip_transit_deadline_ns = 0;
                // A pending pointer dwell for the SAME tooltip is
                // redundant now; a dwell on another trigger keeps
                // running (the pointer's own intent may still complete
                // and take over the shown slot — last intent wins).
                if (view.canvas_tooltip_armed_id == tooltip_id) {
                    view.canvas_tooltip_armed_id = 0;
                    view.canvas_tooltip_armed_owner_id = 0;
                    view.canvas_tooltip_deadline_ns = 0;
                }
            }
            if (shown_changed) try commitCanvasTooltipVisibility(self, view_index);
        }

        /// Keyboard activation (Space/Enter on the focused trigger)
        /// dismisses that trigger's armed or shown tooltip and closes
        /// the warm window — the keyboard mirror of the pointer-down
        /// reset above, per shadcn's Base UI-backed default that
        /// keyboard activation counts as a press for close-on-click.
        /// Scoped to the activated trigger's OWN tooltip, and skipped
        /// for editable text targets, where Space/Enter type instead of
        /// activating.
        pub fn updateCanvasTooltipIntentForKeyboardActivation(self: *Runtime, keyboard_event: CanvasWidgetKeyboardEvent) anyerror!void {
            if (keyboard_event.keyboard.phase != .key_down or keyboard_event.keyboard.modifiers.hasNavigationModifier()) return;
            if (!canvas.isWidgetActivationKey(keyboard_event.keyboard.key)) return;
            const target = keyboard_event.target orelse return;
            if (canvas_widget_runtime.canvasWidgetEditableTextKind(target.kind)) return;
            const index = runtimeFindViewIndex(self, keyboard_event.window_id, keyboard_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            const view = &self.views[index];
            const tooltip_id: canvas.ObjectId = blk: {
                const target_index = view.canvasWidgetNodeIndexById(target.id) orelse break :blk 0;
                const tooltip_index = view.canvasWidgetOwnedTooltipIndex(target_index) orelse break :blk 0;
                break :blk view.widget_layout_nodes[tooltip_index].widget.id;
            };
            if (tooltip_id == 0) return;
            var matched = false;
            if (view.canvas_tooltip_armed_id == tooltip_id) {
                view.canvas_tooltip_armed_id = 0;
                view.canvas_tooltip_armed_owner_id = 0;
                view.canvas_tooltip_deadline_ns = 0;
                matched = true;
            }
            const dismissed_shown = view.canvas_tooltip_shown_id == tooltip_id;
            if (dismissed_shown) {
                view.canvas_tooltip_shown_id = 0;
                view.canvas_tooltip_shown_owner_id = 0;
                view.canvas_tooltip_shown_from_focus = false;
                view.canvas_tooltip_transit_deadline_ns = 0;
                matched = true;
            }
            if (matched) view.canvas_tooltip_warm_until_ns = 0;
            if (dismissed_shown) try commitCanvasTooltipVisibility(self, index);
        }

        /// Re-stamp anchored-tooltip visibility after an intent
        /// transition and repaint the affected tooltip frames — the
        /// dismissal echo's invalidation shape.
        fn commitCanvasTooltipVisibility(self: *Runtime, view_index: usize) anyerror!void {
            const view = &self.views[view_index];
            var dirty: ?geometry.RectF = null;
            for (view.widget_layout_nodes[0..view.widget_layout_node_count], 0..) |node, node_index| {
                if (node.widget.kind != .tooltip) continue;
                if (!canvas.widgetIsAnchored(node.widget)) continue;
                const hidden = node.widget.id == 0 or node.widget.id != view.canvas_tooltip_shown_id;
                if (node.widget.semantics.hidden == hidden) continue;
                const bounds = view.canvasWidgetDirtyBounds(node_index, node.frame) orelse node.frame;
                dirty = if (dirty) |current| current.unionWith(bounds) else bounds;
            }
            view.applyCanvasTooltipVisibility();
            try view.refreshCanvasWidgetSemantics();
            view.widget_revision += 1;
            try invalidateForCanvasWidgetDirty(self, view_index, dirty orelse view.frame);
        }

        /// Bound on the anchor-gap transit grace, in milliseconds. Each
        /// in-corridor pointer move re-arms it, so it only ever fires
        /// for a pointer PARKED between trigger and tooltip — 400ms of
        /// stillness in a gap a few points wide is abandonment, not
        /// transit. Deliberately a constant, not a theme token: the
        /// corridor's timing is interaction mechanics (like
        /// double-click windows), and Base UI exposes no knob for its
        /// safe polygon either.
        const tooltip_transit_grace_ms: u64 = 400;

        fn canvasTooltipShowDelayNs(widget: canvas.Widget, tokens: canvas.DesignTokens) u64 {
            const delay_ms: u64 = if (widget.tooltip_delay_ms >= 0)
                @intCast(widget.tooltip_delay_ms)
            else
                tokens.metrics.tooltip_show_delay_ms;
            return delay_ms * std.time.ns_per_ms;
        }

        fn canvasTooltipWarmWindowNs(tokens: canvas.DesignTokens) u64 {
            return @as(u64, tokens.metrics.tooltip_warm_window_ms) * std.time.ns_per_ms;
        }

        fn canvasChartHoverIndexForId(self: *Runtime, view_index: usize, hovered_id: canvas.ObjectId, point: geometry.PointF) ?usize {
            if (hovered_id == 0) return null;
            const layout = self.views[view_index].widgetLayoutTree();
            const node = layout.findById(hovered_id) orelse return null;
            var widget = node.widget;
            widget.frame = node.frame;
            return canvas.chartWidgetHoverIndex(widget, self.views[view_index].widget_tokens, point);
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

        /// Mirror the view's window-drag regions to the platform (see
        /// `platform.WindowDragRegion`): recompute from the freshly
        /// retained layout on every install and push only when the
        /// mirror actually changed, so a hit-testing platform
        /// (Windows answering `WM_NCHITTEST`) tracks header moves and
        /// visibility flips without being spammed by unrelated
        /// rebuilds. Platforms without the service (macOS, whose drag
        /// path starts from the live pointer gesture) skip even the
        /// collection walk. A view that never had drag regions never
        /// pushes; one whose regions disappeared pushes the empty
        /// mirror once to clear the platform side.
        pub fn syncCanvasWidgetWindowDragRegionsForView(self: *Runtime, view_index: usize) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            if (self.options.platform.services.set_window_drag_regions_fn == null) return;
            const view = &self.views[view_index];
            var regions: [canvas_limits.max_canvas_widget_window_drag_regions_per_view]platform.WindowDragRegion = undefined;
            const count = collectCanvasWidgetWindowDragRegions(view.widgetLayoutTree(), &regions);
            if (view.canvas_widget_drag_regions_pushed) {
                if (count == view.canvas_widget_drag_region_count and windowDragRegionsEqual(regions[0..count], view.canvas_widget_drag_regions[0..count])) return;
            } else if (count == 0) {
                return;
            }
            try self.options.platform.services.setWindowDragRegions(view.window_id, view.label, regions[0..count]);
            @memcpy(view.canvas_widget_drag_regions[0..count], regions[0..count]);
            view.canvas_widget_drag_region_count = count;
            view.canvas_widget_drag_regions_pushed = true;
        }

        pub fn invalidateForCanvasWidgetRenderStateChange(self: *Runtime, view_index: usize, previous: canvas.WidgetRenderState, next: canvas.WidgetRenderState) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            // Tokens matter here: chart hover chrome (axis gutters, the
            // floating detail card) measures text through the view's
            // live tokens, so the dirty region must measure the same way.
            const local_dirty = self.views[view_index].widgetLayoutTree().renderStateDirtyBoundsWithTokens(previous, next, self.views[view_index].widget_tokens);
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
                // The hover point rides with the hovered widget: it
                // survives exactly when the hover survives.
                .hover_point = if (previous.hovered_id) |id| if (canvasWidgetInteractionTargetExists(layout, id)) previous.hover_point else null else null,
            };
        }

        pub fn canvasWidgetRenderStatesEqual(a: canvas.WidgetRenderState, b: canvas.WidgetRenderState) bool {
            return a.focused_id == b.focused_id and
                a.focus_visible_id == b.focus_visible_id and
                a.hovered_id == b.hovered_id and
                a.pressed_id == b.pressed_id and
                canvasOptionalPointsEqual(a.hover_point, b.hover_point);
        }

        fn canvasOptionalPointsEqual(a: ?geometry.PointF, b: ?geometry.PointF) bool {
            if (a) |point_a| {
                const point_b = b orelse return false;
                return point_a.x == point_b.x and point_a.y == point_b.y;
            }
            return b == null;
        }

        /// Scroll moved content under a (possibly stationary) pointer:
        /// reconcile the hover against the new layout, then step the
        /// tooltip intent machine on the hover-target transition
        /// exactly like a pointer move would — a trigger scrolled out
        /// from under the pointer disarms its pending reveal and hides
        /// its shown tooltip (usual warm window), and a trigger the
        /// scroll brings under the pointer arms the normal delay. The
        /// step is deliberately point-blind (immediate-hide semantics,
        /// no transit corridor): the pointer did not move, the content
        /// did, and a scroll is the reader moving on — Base UI closes
        /// open tooltips on scroll for the same reason. `point` is the
        /// live pointer position when the path has one (the wheel); it
        /// re-seeds the corridor apex for whatever the scroll armed or
        /// warm-showed, so a later leave fans out from the truth.
        pub fn reconcileCanvasWidgetRenderStateAfterScrollWithTooltipIntent(self: *Runtime, view_index: usize, point: ?geometry.PointF) anyerror!void {
            const previous_hovered_id = self.views[view_index].canvas_widget_hovered_id;
            self.views[view_index].reconcileCanvasWidgetRenderStateAfterScroll(point);
            const next_hovered_id = self.views[view_index].canvas_widget_hovered_id;
            if (next_hovered_id == previous_hovered_id) return;
            try updateCanvasTooltipIntentForHoverChange(self, view_index, next_hovered_id, null);
            if (point) |value| {
                const view = &self.views[view_index];
                if (next_hovered_id != 0 and (view.canvas_tooltip_armed_owner_id == next_hovered_id or
                    (view.canvas_tooltip_shown_owner_id == next_hovered_id and !view.canvas_tooltip_shown_from_focus)))
                {
                    view.canvas_tooltip_pointer_from = value;
                }
            }
        }

        pub fn updateCanvasWidgetScrollFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
            if (pointer_event.pointer.phase != .wheel) return;
            const index = runtimeFindViewIndex(self, pointer_event.window_id, pointer_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;

            const dirty = try self.views[index].applyCanvasWidgetScrollRoute(pointer_event.route, pointer_event.pointer.delta.dy, .wheel) orelse return;
            const previous_cursor = self.views[index].canvas_widget_cursor;
            try reconcileCanvasWidgetRenderStateAfterScrollWithTooltipIntent(self, index, pointer_event.pointer.point);
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

        /// The ONE derivation seam for keyboard-driven editor mutations:
        /// `canvasWidgetKeyboardTextEdit` maps the routed key to the edit
        /// the retained editor applies, and that same edit is STAMPED
        /// onto the event the app dispatch consumes — so the model's
        /// `on_input` hears exactly what the editor did (the cut/paste
        /// and clear-button stamping precedent, made the rule). Before
        /// the stamp, edits that only THIS derivation produced — Escape's
        /// search-field clear, Escape's composition cancel, the
        /// single-line ArrowUp/Down caret jumps — mutated the editor
        /// while the app-side dispatch re-derived the key on its own and
        /// heard nothing: the field visibly cleared while `model.query`
        /// kept the stale term, and the next keystroke dispatched
        /// against it. Stamping happens even when applying changes
        /// nothing (an Escape in an already-empty field), so a model
        /// whose mirror diverged still hears the clear and resyncs.
        pub fn updateCanvasWidgetTextFromKeyboard(self: *Runtime, keyboard_event: *CanvasWidgetKeyboardEvent) anyerror!void {
            const index = runtimeFindViewIndex(self, keyboard_event.window_id, keyboard_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
            const target = keyboard_event.target orelse return;
            const edit = self.views[index].canvasWidgetKeyboardTextEdit(target, keyboard_event.keyboard) orelse return;
            keyboard_event.keyboard.edit = edit;

            const dirty = try self.views[index].applyCanvasWidgetTextEdit(target.id, edit) orelse return;
            if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[index].frame);
            }
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
        }

        pub fn updateCanvasWidgetTextFromPointer(self: *Runtime, pointer_event: *CanvasWidgetPointerEvent) anyerror!void {
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

            // The search field's built-in clear affordance: a press
            // inside the trailing clear region clears through the
            // standard text-edit path instead of placing the caret, and
            // the edit is stamped onto the event so the app's `on_input`
            // hears it (the clipboard cut/paste precedent).
            if (pointer_event.pointer.phase == .down) {
                if (try applyCanvasWidgetClearButtonPress(self, index, target_id, pointer_event.pointer.point)) {
                    pointer_event.edit = .clear;
                    return;
                }
            }

            const dirty = try self.views[index].applyCanvasWidgetTextPointer(
                target_id,
                pointer_event.pointer.point,
                pointer_event.pointer.phase == .move,
                pointer_event.pointer.click_count,
            ) orelse return;
            if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[index].frame);
            }
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
        }

        /// Apply the search field's built-in clear when `point` presses
        /// its trailing clear region: the standard text-edit path (so
        /// selection/composition state resets exactly like Escape's
        /// clear). Returns whether the press was consumed.
        fn applyCanvasWidgetClearButtonPress(self: *Runtime, index: usize, target_id: canvas.ObjectId, point: geometry.PointF) anyerror!bool {
            const node_index = self.views[index].canvasWidgetNodeIndexById(target_id) orelse return false;
            const widget = self.views[index].widget_layout_nodes[node_index].widget;
            const hit_rect = canvas.textInputClearButtonHitRect(widget, self.views[index].widget_tokens) orelse return false;
            if (!hit_rect.containsPoint(point)) return false;
            const dirty = try self.views[index].applyCanvasWidgetTextEdit(target_id, .clear) orelse return true;
            if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
            } else {
                self.invalidateFor(.state, self.views[index].frame);
            }
            _ = try runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
            return true;
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
            if (target.kind == .scroll_view) try reconcileCanvasWidgetRenderStateAfterScrollWithTooltipIntent(self, index, null);
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
        /// Two keys dismiss: Escape (any dismissible surface, with the
        /// topmost-mounted fallback) and Tab (focus departure — but ONLY
        /// when the keyboard sits inside an open menu or on its trigger;
        /// the menu closes uncommitted and the Tab is consumed, leaving
        /// focus back on the trigger).
        pub fn dismissCanvasWidgetSurfaceFromKeyboardInput(self: *Runtime, input_event: GpuSurfaceInputEvent) anyerror!canvas.ObjectId {
            if (input_event.kind != .key_down) return 0;
            const escape = canvasWidgetEscapeKey(input_event.key);
            const tab = std.ascii.eqlIgnoreCase(input_event.key, "tab");
            if (!escape and !tab) return 0;
            const modifiers = canvasWidgetKeyboardModifiers(input_event.modifiers);
            if (modifiers.hasNavigationModifier()) return 0;
            // Shift+Tab is still focus departure; Shift+Escape is not a
            // dismissal chord at all.
            if (escape and modifiers.shift) return 0;

            const index = runtimeFindViewIndex(self, input_event.window_id, input_event.label) orelse return 0;
            if (self.views[index].kind != .gpu_surface or !self.views[index].focused) return 0;
            // Deliberately NOT gated on a focused widget: a surface
            // opened from a non-focusable trigger (a text crumb) floats
            // with nothing focused, and Escape must still find it — the
            // view method falls back to the topmost mounted anchored
            // surface when the focus chain yields none.
            const focused_id = self.views[index].canvas_widget_focused_id;
            // Tab-away has no fallback: with nothing focused there is no
            // focus to depart, so an unrelated Tab never tears down a
            // floating menu the way Escape deliberately does.
            if (tab and focused_id == 0) return 0;

            const previous_cursor = self.views[index].canvas_widget_cursor;
            const dismissal = (if (tab)
                try self.views[index].dismissCanvasWidgetMenuSurfaceForFocusDeparture(focused_id)
            else
                try self.views[index].dismissCanvasWidgetSurfaceFromEscape(focused_id)) orelse return 0;
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
            const target = keyboard_event.target orelse return;
            // Activation keys press any commandable target; the menu-open
            // arrows press select/combobox triggers too — the same keymap
            // the control-intent resolver applies for `on_press`, kept in
            // lockstep so command-string apps open their pickers from the
            // keyboard exactly like TEA apps.
            const arrow_opens = (target.kind == .select or target.kind == .combobox) and
                canvas.isWidgetMenuOpenArrowKey(keyboard_event.keyboard.key) and
                !(target.state.expanded orelse false);
            if (!canvas.isWidgetActivationKey(keyboard_event.keyboard.key) and !arrow_opens) return;
            if (arrow_opens and keyboard_event.keyboard.focus_moved) return;
            const index = runtimeFindViewIndex(self, keyboard_event.window_id, keyboard_event.view_label) orelse return;
            if (self.views[index].kind != .gpu_surface) return;
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
            // FRAMEWORK BEHAVIOR CHANGE (deliberate, scoped — the same
            // seam as the keyboard-routing gate below): arrows and
            // Home/End never escalate QUIET focus on a plain list row
            // into the visible ring register. Only Tab (handled above)
            // enters the keyboard-contract; from quiet row focus the
            // navigation keys fall through to the app, whose selection
            // model owns them. Ring-visible rows keep the full group
            // walk unchanged; tree rows are exempt.
            if (canvasWidgetQuietListRowFocus(self, index, focused_id)) return false;
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
            // The open-select keymap: ArrowDown/Up on a select/combobox
            // trigger whose anchored menu is MOUNTED moves the keyboard
            // into the menu (the marked row when one is selected, else
            // the first/last row). Without a mounted menu the arrows fall
            // through to the control resolver, which turns them into the
            // trigger's press — the model-owned open.
            if ((focused.kind == .select or focused.kind == .combobox) and (direction == .down or direction == .up)) {
                if (self.views[index].canvasWidgetOwnedMenuSurfaceIndex(focused.index)) |surface_index| {
                    if (self.views[index].canvasWidgetMenuSurfaceEntryId(surface_index, direction == .up)) |entry_id| {
                        return try setCanvasWidgetFocusFromKeyboardMoved(self, index, current_id, entry_id);
                    }
                }
            }
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
            // Keyboard focus-visible is the tooltip's second reveal
            // path: landing on a tooltip-owning trigger shows it
            // immediately, moving on hides the previous one (see
            // updateCanvasTooltipIntentForFocusVisibleChange).
            try updateCanvasTooltipIntentForFocusVisibleChange(self, view_index, target_id);
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

/// Collect the layout's window-drag region mirror: every visible
/// `window_drag` widget's frame, each followed by the frames of the
/// press-claiming widgets inside it as `exclusion` entries — the same
/// carve-outs `widgetWindowDragTargetIndexFromNode` applies point by
/// point, precomputed as rectangles for platforms that answer a native
/// hit-test (Windows `WM_NCHITTEST`). Frames are the canvas view's
/// local logical coordinates, exactly as retained. Regions are
/// appended transactionally: when the output fills mid-region the
/// WHOLE region rolls back, because a drag rect without its exclusions
/// would hand a button's press to the OS move loop, while a missing
/// drag rect only loses dragging on that band.
pub fn collectCanvasWidgetWindowDragRegions(layout: canvas.WidgetLayoutTree, output: []platform.WindowDragRegion) usize {
    var count: usize = 0;
    for (layout.nodes, 0..) |node, node_index| {
        if (!canvas.widgetIsWindowDragRegion(node.widget)) continue;
        if (canvas_widget_runtime.canvasWidgetLayoutNodeHidden(layout, node_index)) continue;
        if (!canvas_widget_runtime.canvasWidgetLayoutNodeFrameVisible(layout, node_index)) continue;
        const region_start = count;
        if (count >= output.len) break;
        output[count] = .{ .frame = node.frame.normalized() };
        count += 1;
        var overflow = false;
        for (layout.nodes, 0..) |candidate, candidate_index| {
            if (candidate_index == node_index) continue;
            if (!canvas.widgetClaimsPress(candidate.widget)) continue;
            if (canvas_widget_runtime.canvasWidgetLayoutNodeHidden(layout, candidate_index)) continue;
            if (!canvas_widget_runtime.canvasWidgetLayoutNodeFrameVisible(layout, candidate_index)) continue;
            if (!canvasWidgetNodeHasAncestor(layout, candidate_index, node_index)) continue;
            if (count >= output.len) {
                overflow = true;
                break;
            }
            output[count] = .{ .frame = candidate.frame.normalized(), .exclusion = true };
            count += 1;
        }
        if (overflow) {
            count = region_start;
            break;
        }
    }
    return count;
}

fn canvasWidgetNodeHasAncestor(layout: canvas.WidgetLayoutTree, node_index: usize, ancestor_index: usize) bool {
    if (node_index >= layout.nodes.len) return false;
    var current: ?usize = layout.nodes[node_index].parent_index;
    while (current) |index| {
        if (index >= layout.nodes.len) return false;
        if (index == ancestor_index) return true;
        current = layout.nodes[index].parent_index;
    }
    return false;
}

fn windowDragRegionsEqual(a: []const platform.WindowDragRegion, b: []const platform.WindowDragRegion) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.meta.eql(left, right)) return false;
    }
    return true;
}
