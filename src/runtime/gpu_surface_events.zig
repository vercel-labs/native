const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");
const runtime_api = @import("api.zig");
const canvas_frame_helpers = @import("canvas_frame.zig");
const runtime_canvas_widget_context_menu = @import("canvas_widget_context_menu.zig");
const runtime_canvas_widget_display = @import("canvas_widget_display.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");
const runtime_canvas_widget_scroll_drivers = @import("canvas_widget_scroll_drivers.zig");

const canvasWidgetInputBatchesDisplayListRefresh = canvas_frame_helpers.canvasWidgetInputBatchesDisplayListRefresh;
const gpuSurfaceFrameEventFromGpuFrame = canvas_frame_helpers.gpuSurfaceFrameEventFromGpuFrame;
const platformCanvasFrameProfileRisk = canvas_frame_helpers.platformCanvasFrameProfileRisk;
const sizesEqual = canvas_frame_helpers.sizesEqual;

pub fn RuntimeGpuSurfaceEvents(comptime Runtime: type) type {
    return struct {
        pub fn dispatchGpuSurfaceFrame(self: *Runtime, app: runtime_api.App(Runtime), frame_event: platform.GpuSurfaceFrameEvent) anyerror!void {
            // Media-surface adoption rides the compositor's
            // presented-frame clock: staged producer frames (latest
            // wins) are sampled once per frame event, BEFORE view state
            // and the app dispatch, so a changed texture invalidates
            // the very frame this event is about to present. Idle
            // channels cost one fenced flag check each.
            self.adoptMediaSurfaceFrames();
            var enriched_frame_event = frame_event;
            var had_pending_input = false;
            if (runtimeFindViewIndex(self, frame_event.window_id, frame_event.label)) |index| {
                had_pending_input = self.views[index].gpu_pending_input_timestamp_ns != 0;
                // The requested frame arrived: deferred accessibility
                // publishes flush after this event's present (below).
                self.views[index].gpu_canvas_frame_requested = false;
                const first_frame_latency_was_recorded = self.views[index].gpu_first_frame_latency_recorded;
                if (!sizesEqual(self.views[index].gpu_size, frame_event.size) or self.views[index].gpu_scale_factor != frame_event.scale_factor) {
                    self.views[index].presented_canvas_valid = false;
                }
                self.views[index].gpu_size = frame_event.size;
                self.views[index].gpu_scale_factor = frame_event.scale_factor;
                self.views[index].gpu_frame_index = frame_event.frame_index;
                // Completion cadence for the frame profile: the MEASURED
                // gap between consecutive completion-event stamps (the
                // event's frame_interval_ns is the screen's nominal
                // interval, useless for drop detection). Profiling-gated;
                // a dropped frame shows as max >> p50 on this channel.
                if (self.frame_profile.enabled) {
                    const previous_timestamp_ns = self.views[index].gpu_timestamp_ns;
                    if (previous_timestamp_ns > 0 and frame_event.timestamp_ns > previous_timestamp_ns) {
                        self.frame_profile.recordNs(.interval, frame_event.timestamp_ns - previous_timestamp_ns);
                    }
                }
                self.views[index].gpu_timestamp_ns = frame_event.timestamp_ns;
                self.views[index].recordGpuSurfaceFrameInterval(frame_event.frame_interval_ns);
                self.views[index].recordGpuSurfaceFirstFrameLatency(frame_event.timestamp_ns);
                // Host-stamped packet decode/draw splits ride the frame
                // event (zero on completion-only frames): feed the frame
                // profile's host stages while profiling is on.
                if (frame_event.packet_decode_ns > 0) self.frame_profile.recordNs(.host_decode, frame_event.packet_decode_ns);
                if (frame_event.packet_draw_ns > 0) self.frame_profile.recordNs(.host_draw, frame_event.packet_draw_ns);
                try CanvasWidgetDisplayMethods().advanceCanvasWidgetKineticScrollForFrame(self, index, frame_event.frame_interval_ns, had_pending_input);
                // Layout tweens step on the frame event's RECORDED
                // timestamp (never a wall clock), so session replay
                // reproduces identical layouts frame for frame. Stepped
                // before the pending-event dispatch below so the resize
                // event each step notes reaches the app THIS frame.
                try self.advanceCanvasWidgetLayoutTweensForFrame(index, frame_event.timestamp_ns);
                // The disclosure tween steps on the same recorded clock,
                // so accordion reveals replay frame for frame exactly
                // like split fractions do.
                try self.advanceCanvasWidgetDisclosureTweenForFrame(index, frame_event.timestamp_ns);
                // The anchored-tooltip hover-intent delay fires on the
                // same recorded clock: a dwell past the delay shows its
                // tooltip on a deterministic frame, replayed exactly.
                try self.advanceCanvasTooltipIntentForFrame(index, frame_event.timestamp_ns);
                try dispatchPendingCanvasWidgetScrollEvents(self, app, index);
                // A settling tween notes its ONE split-resize event with
                // no input in flight; drain it here so the controlled
                // echo (`on_resize` -> model -> `value`) and any
                // structural swap ride the SAME frame the settle
                // painted. Mid-flight steps note nothing: they slide
                // content the reconcile already laid out at the target
                // fraction, so there is no per-step echo to deliver.
                try dispatchPendingCanvasWidgetResizeEvents(self, app, index);
                // Observable snapshots (automation, bridge state) only
                // republish when the runtime is invalidated, and a frame
                // completion carrying a NEW discrete fact may have no
                // other invalidation source, leaving the published
                // snapshot stale forever. Two such facts invalidate here
                // (a third — a resolved input latency — is checked after
                // the app dispatch below, where the responding present
                // stamps it):
                //   - the host-reported nonblank verdict changed (the
                //     first nonblank presentation on an idle boot has no
                //     resize and no input to piggyback on);
                //   - this frame recorded the first-frame latency.
                // Steady-state frames carry no new fact and stay quiet —
                // a timer-mode surface must not republish observable
                // state 60 times a second.
                const first_frame_latency_recorded = !first_frame_latency_was_recorded and self.views[index].gpu_first_frame_latency_recorded;
                if (self.views[index].gpu_frame_nonblank != frame_event.nonblank or first_frame_latency_recorded) {
                    self.invalidateFor(.state, self.views[index].frame);
                }
                self.views[index].gpu_frame_nonblank = frame_event.nonblank;
                self.views[index].gpu_sample_color = frame_event.sample_color;
                self.views[index].gpu_backend = frame_event.backend;
                self.views[index].gpu_pixel_format = frame_event.pixel_format;
                self.views[index].gpu_present_mode = frame_event.present_mode;
                self.views[index].gpu_alpha_mode = frame_event.alpha_mode;
                self.views[index].gpu_color_space = frame_event.color_space;
                self.views[index].gpu_vsync = frame_event.vsync;
                self.views[index].gpu_status = frame_event.status;
                if (self.options.gpu_surface_frame_diagnostics) {
                    try enrichGpuSurfaceFrameDiagnostics(self, index, &enriched_frame_event);
                } else if (self.views[index].info().gpuFrame()) |gpu_frame| {
                    enriched_frame_event = gpuSurfaceFrameEventFromGpuFrame(gpu_frame);
                    // GpuFrame is persistent surface state; the occluded
                    // fact is per-completion metadata and must survive
                    // the rebuild so the app sees it honestly.
                    enriched_frame_event.occluded = frame_event.occluded;
                }
                // Native scroll drivers reconcile against live host state
                // on every presented frame (the relayout-stomp lesson: a
                // one-shot frame patch races shell relayout): frames,
                // content extents, and diverged offsets all self-heal here.
                ScrollDriverMethods().syncCanvasWidgetScrollDriversForView(self, index);
            }
            try self.dispatchEvent(app, .{ .gpu_surface_frame = enriched_frame_event });
            // Post-present bookkeeping (the app's present ran inside the
            // dispatch above; the view may have moved, so re-resolve it):
            //   - gpu_input_latency stamps at the RESPONDING present's
            //     completion (the present paths stamp it synchronously);
            //     an input that presented nothing falls back to this
            //     completion event's timestamp, the old pacing-channel
            //     semantics. Either way a resolved latency is a new
            //     discrete fact for observable snapshots.
            //   - accessibility publishes the input dispatch deferred off
            //     the glass path flush here, after the pixels moved.
            if (runtimeFindViewIndex(self, frame_event.window_id, frame_event.label)) |index| {
                // An occluded logical completion is not a latency
                // endpoint: its timestamp is the host's deliberate
                // occluded heartbeat, not a present. It still RESOLVES
                // the pending input (see the view method's comment), so
                // neither this deliberately slow completion nor the
                // eventual de-occlusion flush can be billed to the
                // input as a manufactured budget overrun.
                if (frame_event.occluded) {
                    self.views[index].resolveGpuSurfaceInputForOccludedFrame();
                } else {
                    self.views[index].recordGpuSurfaceInputLatencyForFrame(frame_event.timestamp_ns);
                }
                const input_latency_recorded = had_pending_input and self.views[index].gpu_pending_input_timestamp_ns == 0;
                if (input_latency_recorded) {
                    self.invalidateFor(.state, self.views[index].frame);
                }
            }
            try CanvasWidgetDisplayMethods().flushDeferredCanvasWidgetAccessibility(self);
        }

        pub fn dispatchGpuSurfaceResized(self: *Runtime, app: runtime_api.App(Runtime), resize_event: platform.GpuSurfaceResizeEvent) anyerror!void {
            if (runtimeFindViewIndex(self, resize_event.window_id, resize_event.label)) |index| {
                const previous_frame = self.views[index].frame;
                const previous_size = self.views[index].gpu_size;
                const previous_scale = self.views[index].gpu_scale_factor;
                const next_size = resize_event.frame.size();
                const frame_changed = !rectsEqual(previous_frame, resize_event.frame);
                const surface_changed = !sizesEqual(previous_size, next_size) or previous_scale != resize_event.scale_factor;
                self.views[index].frame = resize_event.frame;
                self.views[index].gpu_size = next_size;
                self.views[index].gpu_scale_factor = resize_event.scale_factor;
                if (surface_changed) self.views[index].presented_canvas_valid = false;
                if (self.views[index].gpu_status == .unavailable) self.views[index].gpu_status = .ready;
                if (frame_changed or surface_changed) self.invalidateFor(.surface_resize, resize_event.frame);
            }
            try self.dispatchEvent(app, .{ .gpu_surface_resized = resize_event });
        }

        pub fn dispatchGpuSurfaceInput(self: *Runtime, app: runtime_api.App(Runtime), input_event: platform.GpuSurfaceInputEvent) anyerror!void {
            // Tell the host input landed BEFORE anything dispatches:
            // hosts that throttle occluded/minimized frame completions
            // to a heartbeat must let this input's responding frame fire
            // at full promptness (automation drives covered windows
            // constantly, and the responding present is the
            // input-latency stamp's endpoint). Hosts without occluded
            // pacing no-op.
            self.options.platform.services.noteGpuSurfaceInput(input_event.window_id, input_event.label) catch {};
            // Secondary-button (right/ctrl-click, touch long-press) input
            // is the context-menu gesture: the press presents the
            // native menu and the whole button-1 stream is consumed so a
            // right-click never acts as a primary press.
            if (ContextMenuMethods().canvasWidgetContextPointerInput(input_event)) {
                if (runtimeFindViewIndex(self, input_event.window_id, input_event.label)) |index| {
                    self.views[index].recordGpuSurfaceInputTimestamp(input_event.timestamp_ns);
                }
                // The whole consumed stream still feeds the tooltip
                // intent choke point: every pointer-carrying event
                // updates the stored position (a later point-blind
                // reconcile must hit-test where the pointer really is),
                // the secondary down resets the machine before the menu
                // presents ("pointer-down dismisses" holds for EVERY
                // button — no tooltip floats behind or over the native
                // menu), and a consumed cancel is still the pointer
                // leaving the view.
                try CanvasWidgetEventMethods().reconcileCanvasTooltipIntentForConsumedPointerInput(self, input_event);
                if (input_event.kind == .pointer_down) {
                    try setFocusedView(self, input_event.window_id, input_event.label);
                    self.invalidated = true;
                    try ContextMenuMethods().presentCanvasWidgetContextMenuFromPointer(self, app, input_event);
                }
                try self.dispatchEvent(app, .{ .gpu_surface_input = input_event });
                return;
            }
            // Accessibility publishes requested anywhere inside this
            // dispatch (widget-state refreshes, the Msg rebuild's
            // emission) defer to after the responding present: the
            // platform publish is the single largest pre-present cost a
            // click pays (~2 ms of host tree assembly on live macOS) and
            // semantics consumers tolerate milliseconds.
            self.canvas_widget_accessibility_defer_depth += 1;
            defer self.canvas_widget_accessibility_defer_depth -= 1;
            var canvas_widget_refresh_batch_active = canvasWidgetInputBatchesDisplayListRefresh(input_event.kind);
            if (canvas_widget_refresh_batch_active) CanvasWidgetDisplayMethods().beginCanvasWidgetDisplayListRefreshBatch(self);
            // The batch now spans the app dispatches below, so an error
            // mid-dispatch must FLUSH the deferred refreshes rather than
            // drop them — widget state already changed, and a dropped
            // refresh would leave the retained display list stale.
            errdefer {
                if (canvas_widget_refresh_batch_active) CanvasWidgetDisplayMethods().endCanvasWidgetDisplayListRefreshBatch(self) catch {
                    CanvasWidgetDisplayMethods().cancelCanvasWidgetDisplayListRefreshBatch(self);
                };
            }

            if (runtimeFindViewIndex(self, input_event.window_id, input_event.label)) |index| {
                self.views[index].recordGpuSurfaceInputTimestamp(input_event.timestamp_ns);
            }
            switch (input_event.kind) {
                .pointer_down,
                .key_down,
                => {
                    try setFocusedView(self, input_event.window_id, input_event.label);
                    self.invalidated = true;
                },
                else => {},
            }
            var widget_pointer_event = CanvasWidgetEventMethods().routeCanvasWidgetPointerInput(self, input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                error.WindowNotFound,
                error.ViewNotFound,
                error.InvalidViewOptions,
                => null,
                else => return err,
            };
            var dismissed_surface_id: canvas.ObjectId = 0;
            var window_drag_started = false;
            if (widget_pointer_event) |*pointer_event| {
                // Click count stamps first: every pass below (and the
                // app's `canvas_widget_pointer` dispatch at the end)
                // sees the same double/triple-click verdict for this
                // input.
                CanvasWidgetEventMethods().updateCanvasWidgetClickCountFromPointer(self, input_event, pointer_event);
                dismissed_surface_id = try CanvasWidgetEventMethods().dismissCanvasWidgetSurfaceFromPointerInput(self, pointer_event.*);
                // A down consumed by a window-drag region skips the whole
                // widget press pipeline: the OS owns the pointer from here
                // (the matching move/up may never reach the view), so no
                // widget may be left pressed, no text selection may start,
                // and keyboard focus stays where it was — exactly like a
                // click on the native titlebar. Dismissal above still ran:
                // clicking the header closes an open surface first.
                window_drag_started = try CanvasWidgetEventMethods().startCanvasWidgetWindowDragFromPointer(self, input_event, pointer_event.*);
                if (window_drag_started) {
                    // The drag consumed the down, but "pointer-down
                    // dismisses" still holds — and the down still
                    // carried a position the intent machine must
                    // record: the OS owning the pointer from here must
                    // not strand an armed or shown tooltip (the
                    // matching up may never arrive), and a later
                    // point-blind reconcile must hit-test where the
                    // pointer really went down.
                    try CanvasWidgetEventMethods().reconcileCanvasTooltipIntentForConsumedPointerInput(self, input_event);
                } else {
                    try CanvasWidgetEventMethods().updateCanvasWidgetControlFromPointer(self, pointer_event.*);
                    try CanvasWidgetEventMethods().updateCanvasWidgetInteractionFromPointer(self, pointer_event.*);
                    // The text pass may stamp a clear edit onto the
                    // event for the app dispatch below.
                    try CanvasWidgetEventMethods().updateCanvasWidgetTextFromPointer(self, pointer_event);
                    try CanvasWidgetEventMethods().updateCanvasWidgetScrollFromPointer(self, pointer_event.*);
                    try CanvasWidgetEventMethods().updateCanvasWidgetFocusFromPointer(self, pointer_event.*);
                }
            }
            const widget_drag_event = CanvasWidgetEventMethods().routeCanvasWidgetDragInput(self, input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                error.WindowNotFound,
                error.ViewNotFound,
                error.InvalidViewOptions,
                => null,
                else => return err,
            };
            const keyboard_dismissed_id = try CanvasWidgetEventMethods().dismissCanvasWidgetSurfaceFromKeyboardInput(self, input_event);
            if (keyboard_dismissed_id != 0) dismissed_surface_id = keyboard_dismissed_id;
            const widget_surface_dismissed = keyboard_dismissed_id != 0;
            const widget_focus_moved = if (widget_surface_dismissed)
                false
            else
                try CanvasWidgetEventMethods().updateCanvasWidgetFocusFromKeyboardInput(self, input_event);
            var widget_keyboard_event = if (widget_surface_dismissed)
                null
            else
                CanvasWidgetEventMethods().routeCanvasWidgetKeyboardInput(self, input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                    error.WindowNotFound,
                    error.ViewNotFound,
                    error.InvalidViewOptions,
                    => null,
                    else => return err,
                };
            // The routed event targets the (possibly just-moved) focused
            // widget; the flag lets tree rows tell "focus arrived here"
            // from "an arrow landed here in place".
            if (widget_keyboard_event) |*keyboard_event| {
                keyboard_event.keyboard.focus_moved = widget_focus_moved;
            }
            // Clipboard shortcuts resolve against the raw input (copy has
            // no routed target when a static text selection is live) and
            // may stamp a paste/cut edit onto the routed keyboard event;
            // the pasted bytes live in this frame until dispatch returns.
            var clipboard_paste_buffer: [platform.max_clipboard_data_bytes]u8 = undefined;
            if (!widget_surface_dismissed) {
                try CanvasWidgetEventMethods().applyCanvasWidgetClipboardShortcut(
                    self,
                    input_event,
                    if (widget_keyboard_event) |*keyboard_event| keyboard_event else null,
                    &clipboard_paste_buffer,
                );
            }
            // The text pass stamps the edit it derived and applied onto
            // the event (Escape's clear included), so the app dispatch
            // below hears exactly the edit the retained editor performed.
            if (widget_keyboard_event) |*keyboard_event| {
                // Keyboard activation counts as a press for tooltips:
                // Space/Enter on the focused trigger dismisses its
                // armed/shown tooltip before the control mutation and
                // app dispatch observe the input.
                try CanvasWidgetEventMethods().updateCanvasTooltipIntentForKeyboardActivation(self, keyboard_event.*);
                try CanvasWidgetEventMethods().updateCanvasWidgetControlFromKeyboard(self, keyboard_event.*);
                try CanvasWidgetEventMethods().updateCanvasWidgetTextFromKeyboard(self, keyboard_event);
            }
            var widget_text_input_event = if (widget_surface_dismissed)
                null
            else
                CanvasWidgetEventMethods().routeCanvasWidgetTextInput(self, input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                    error.WindowNotFound,
                    error.ViewNotFound,
                    error.InvalidViewOptions,
                    => null,
                    else => return err,
                };
            if (widget_text_input_event) |*text_input_event| {
                try CanvasWidgetEventMethods().updateCanvasWidgetTextFromKeyboard(self, text_input_event);
            }
            // The refresh batch stays open across the app dispatches
            // below: a click's pointer-up used to emit once for the
            // widget-state change and once more for the Msg-driven
            // rebuild (whose setCanvasWidgetLayout refresh is
            // batch-aware) — the same display list built twice in one
            // input cycle. One batch spanning input mutation AND app
            // dispatch coalesces them into a single emission at the end
            // of this function, after which the display list is exactly
            // what the two-emission sequence produced.
            // Dismissal reaches the app first (the model closes its open
            // flag before any press-family Msg from the same input), and
            // only here — after every runtime-side mutation above stopped
            // routing into the pre-dismissal tree.
            if (dismissed_surface_id != 0) {
                if (runtimeFindViewIndex(self, input_event.window_id, input_event.label)) |index| {
                    try CanvasWidgetEventMethods().dispatchCanvasWidgetDismissEvent(self, app, index, dismissed_surface_id);
                }
            }
            if (widget_pointer_event) |pointer_event| {
                if (!window_drag_started) {
                    try CanvasWidgetEventMethods().dispatchCanvasWidgetCommandFromPointer(self, app, pointer_event);
                }
                try self.dispatchEvent(app, .{ .canvas_widget_pointer = pointer_event });
            }
            if (widget_drag_event) |drag_event| {
                try self.dispatchEvent(app, .{ .canvas_widget_drag = drag_event });
            }
            if (widget_keyboard_event) |keyboard_event| {
                try CanvasWidgetEventMethods().dispatchCanvasWidgetCommandFromKeyboard(self, app, keyboard_event);
                try self.dispatchEvent(app, .{ .canvas_widget_keyboard = keyboard_event });
            } else if (input_event.kind == .key_down and !widget_surface_dismissed) {
                // No focused widget routed this key_down (nothing is
                // focused, or the focused id is gone from the tree): the
                // key still reaches the app, as a TARGET-LESS keyboard
                // event. This is the app-level key-fallback seam — the
                // honest home for unmodified media keys (a bare-space
                // transport toggle), which chrome shortcuts deliberately
                // refuse (`validateShortcut` demands a modifier so global
                // registration can never steal typing). The ui-app layer
                // maps it through `Options.on_key`; with a target present
                // the routed event above carries the same fallback duty
                // once widget dispatch declines the key. A key that just
                // dismissed a surface was consumed by the dismissal and
                // never falls through.
                if (runtimeFindViewIndex(self, input_event.window_id, input_event.label)) |index| {
                    if (self.views[index].kind == .gpu_surface and self.views[index].focused) {
                        try self.dispatchEvent(app, .{ .canvas_widget_keyboard = .{
                            .window_id = input_event.window_id,
                            .view_label = self.views[index].label,
                            .keyboard = .{
                                .phase = .key_down,
                                .key = input_event.key,
                                .text = input_event.text,
                                .modifiers = canvas_frame_helpers.canvasWidgetKeyboardModifiers(input_event.modifiers),
                            },
                        } });
                    }
                }
            }
            if (widget_text_input_event) |text_input_event| {
                try self.dispatchEvent(app, .{ .canvas_widget_keyboard = text_input_event });
            }
            // Wheel and keyboard scroll mutations above noted pending
            // scroll events on the view; deliver them after the input's
            // own dispatches so the app observes inputs before offsets.
            // Split-fraction changes (divider drag, keyboard steps)
            // follow the same drain discipline.
            if (runtimeFindViewIndex(self, input_event.window_id, input_event.label)) |index| {
                try dispatchPendingCanvasWidgetScrollEvents(self, app, index);
                try dispatchPendingCanvasWidgetResizeEvents(self, app, index);
                // Slider values a pointer gesture changed (rail click,
                // scrub drag) follow the same drain discipline, so the
                // app's `on_change` hears the applied value this input.
                try dispatchPendingCanvasWidgetChangeEvents(self, app, index);
            }
            try self.dispatchEvent(app, .{ .gpu_surface_input = input_event });
            if (canvas_widget_refresh_batch_active) {
                try CanvasWidgetDisplayMethods().endCanvasWidgetDisplayListRefreshBatch(self);
                canvas_widget_refresh_batch_active = false;
            }
            // Deferred accessibility publishes with a frame in flight
            // ride that frame's post-present flush; ones without (this
            // input changed semantics but no pixels) publish now — there
            // is no present to protect.
            try CanvasWidgetDisplayMethods().settleDeferredCanvasWidgetAccessibility(self);
        }

        /// Drain the view's pending scroll-event set into
        /// `canvas_widget_scroll` app events. Each entry reads the node's
        /// CURRENT scroll state, so motion that occurred since the note
        /// (kinetic steps, further wheel ticks) is already folded in.
        /// Also called from the accessibility semantic-action path so
        /// assistive scrolls observe like wheel scrolls.
        pub fn dispatchPendingCanvasWidgetScrollEvents(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            if (self.views[view_index].widget_scroll_event_count == 0) return;

            // Copy-then-reset: app dispatch can rebuild the view (or
            // scroll again), which may note fresh entries for the next
            // drain without aliasing this one.
            const pending_ids = self.views[view_index].widget_scroll_event_ids;
            const pending_count = self.views[view_index].widget_scroll_event_count;
            self.views[view_index].widget_scroll_event_count = 0;
            for (pending_ids[0..pending_count]) |id| {
                const scroll = self.views[view_index].canvasWidgetScrollStateById(id) orelse continue;
                try self.dispatchEvent(app, .{ .canvas_widget_scroll = .{
                    .window_id = self.views[view_index].window_id,
                    .view_label = self.views[view_index].label,
                    .id = id,
                    .scroll = scroll,
                } });
            }
        }

        /// Drain the view's pending split-resize set into
        /// `canvas_widget_resize` app events. Each entry reads the
        /// node's CURRENT fraction, so several coalesced drag steps
        /// deliver the final value (the scroll-drain contract) — except
        /// while a layout tween is armed on the split: then the event
        /// carries the tween's DESTINATION, so the arm echo tells the
        /// controlled model where the panes are heading and its one
        /// rebuild lays content out at the target the slide reveals.
        pub fn dispatchPendingCanvasWidgetResizeEvents(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            if (self.views[view_index].widget_resize_event_count == 0) return;

            // Copy-then-reset: app dispatch can rebuild the view, which
            // may note fresh entries for the next drain.
            const pending_ids = self.views[view_index].widget_resize_event_ids;
            const pending_count = self.views[view_index].widget_resize_event_count;
            self.views[view_index].widget_resize_event_count = 0;
            for (pending_ids[0..pending_count]) |id| {
                const node_index = self.views[view_index].canvasWidgetNodeIndexById(id) orelse continue;
                const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
                if (widget.kind != .split) continue;
                const fraction = if (self.views[view_index].findCanvasWidgetLayoutTween(id)) |tween| tween.spec.to else widget.value;
                try self.dispatchEvent(app, .{ .canvas_widget_resize = .{
                    .window_id = self.views[view_index].window_id,
                    .view_label = self.views[view_index].label,
                    .id = id,
                    .fraction = fraction,
                } });
            }
        }

        /// Drain the view's pending slider-change set into
        /// `canvas_widget_change` app events. Each entry reads the
        /// node's CURRENT value, so several coalesced drag steps
        /// deliver the final value (the scroll-drain contract). Only
        /// pointer gestures note entries — sliders never change on
        /// frame ticks, so unlike splits (whose tweens note resize
        /// events per frame step) this drain has no frame-path caller.
        pub fn dispatchPendingCanvasWidgetChangeEvents(self: *Runtime, app: runtime_api.App(Runtime), view_index: usize) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            if (self.views[view_index].widget_change_event_count == 0) return;

            // Copy-then-reset: app dispatch can rebuild the view, which
            // may note fresh entries for the next drain.
            const pending_ids = self.views[view_index].widget_change_event_ids;
            const pending_count = self.views[view_index].widget_change_event_count;
            self.views[view_index].widget_change_event_count = 0;
            for (pending_ids[0..pending_count]) |id| {
                const node_index = self.views[view_index].canvasWidgetNodeIndexById(id) orelse continue;
                const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
                if (widget.kind != .slider) continue;
                try self.dispatchEvent(app, .{ .canvas_widget_change = .{
                    .window_id = self.views[view_index].window_id,
                    .view_label = self.views[view_index].label,
                    .id = id,
                    .value = widget.value,
                } });
            }
        }

        fn enrichGpuSurfaceFrameDiagnostics(self: *Runtime, index: usize, enriched_frame_event: *platform.GpuSurfaceFrameEvent) anyerror!void {
            const preview_frame = try CanvasFrameMethods().planCanvasFrameForView(self, index, .{
                .frame_index = enriched_frame_event.frame_index,
                .timestamp_ns = enriched_frame_event.timestamp_ns,
                .surface_size = enriched_frame_event.size,
                .scale = enriched_frame_event.scale_factor,
            }, CanvasFrameMethods().canvasFrameScratchStorage(self), false);
            const preview_render_pass = preview_frame.renderPass();
            const preview_gpu_packet_summary = preview_frame.gpuPacketSummary();
            const preview_budget_status = preview_frame.budgetStatus();
            enriched_frame_event.canvas_revision = self.views[index].canvas_revision;
            enriched_frame_event.frame_interval_ns = self.views[index].gpu_frame_interval_ns;
            enriched_frame_event.input_timestamp_ns = self.views[index].gpu_input_timestamp_ns;
            enriched_frame_event.input_latency_ns = self.views[index].gpu_input_latency_ns;
            enriched_frame_event.input_latency_budget_ns = self.views[index].gpu_input_latency_budget_ns;
            enriched_frame_event.input_latency_budget_exceeded_count = self.views[index].gpu_input_latency_budget_exceeded_count;
            enriched_frame_event.input_latency_budget_ok = self.views[index].gpu_input_latency_budget_ok;
            enriched_frame_event.first_frame_latency_ns = self.views[index].gpu_first_frame_latency_ns;
            enriched_frame_event.first_frame_latency_budget_ns = self.views[index].gpu_first_frame_latency_budget_ns;
            enriched_frame_event.first_frame_latency_budget_exceeded_count = self.views[index].gpu_first_frame_latency_budget_exceeded_count;
            enriched_frame_event.first_frame_latency_budget_ok = self.views[index].gpu_first_frame_latency_budget_ok;
            enriched_frame_event.canvas_command_count = self.views[index].canvas_command_count;
            enriched_frame_event.canvas_frame_requires_render = preview_frame.requiresRender();
            enriched_frame_event.canvas_frame_full_repaint = preview_frame.full_repaint;
            enriched_frame_event.canvas_frame_batch_count = preview_frame.batch_plan.batchCount();
            enriched_frame_event.canvas_frame_encoder_command_count = preview_render_pass.encoderCommandCount();
            enriched_frame_event.canvas_frame_encoder_cache_action_count = preview_render_pass.encoderCacheActionCount();
            enriched_frame_event.canvas_frame_encoder_bind_pipeline_count = preview_render_pass.encoderBindPipelineCount();
            enriched_frame_event.canvas_frame_encoder_draw_batch_count = preview_render_pass.encoderDrawBatchCount();
            enriched_frame_event.canvas_frame_pipeline_count = preview_frame.pipeline_cache_plan.entryCount();
            enriched_frame_event.canvas_frame_pipeline_upload_count = preview_frame.pipeline_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_pipeline_retain_count = preview_frame.pipeline_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_pipeline_evict_count = preview_frame.pipeline_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_path_geometry_count = preview_frame.path_geometry_plan.geometryCount();
            enriched_frame_event.canvas_frame_path_geometry_vertex_count = preview_frame.path_geometry_plan.vertexCount();
            enriched_frame_event.canvas_frame_path_geometry_index_count = preview_frame.path_geometry_plan.indexCount();
            enriched_frame_event.canvas_frame_path_geometry_upload_count = preview_frame.path_geometry_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_path_geometry_retain_count = preview_frame.path_geometry_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_path_geometry_evict_count = preview_frame.path_geometry_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_image_count = preview_frame.image_plan.imageCount();
            enriched_frame_event.canvas_frame_image_upload_count = preview_frame.image_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_image_retain_count = preview_frame.image_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_image_evict_count = preview_frame.image_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_layer_count = preview_frame.layer_plan.layerCount();
            enriched_frame_event.canvas_frame_layer_opacity_count = preview_frame.layer_plan.opacityLayerCount();
            enriched_frame_event.canvas_frame_layer_clip_count = preview_frame.layer_plan.clipLayerCount();
            enriched_frame_event.canvas_frame_layer_transform_count = preview_frame.layer_plan.transformLayerCount();
            enriched_frame_event.canvas_frame_layer_upload_count = preview_frame.layer_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_layer_retain_count = preview_frame.layer_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_layer_evict_count = preview_frame.layer_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_resource_count = preview_frame.resource_plan.resourceCount();
            enriched_frame_event.canvas_frame_resource_upload_count = preview_frame.resource_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_resource_retain_count = preview_frame.resource_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_resource_evict_count = preview_frame.resource_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_visual_effect_count = preview_frame.visual_effect_plan.effectCount();
            enriched_frame_event.canvas_frame_visual_effect_shadow_count = preview_frame.visual_effect_plan.shadowCount();
            enriched_frame_event.canvas_frame_visual_effect_blur_count = preview_frame.visual_effect_plan.blurCount();
            enriched_frame_event.canvas_frame_visual_effect_upload_count = preview_frame.visual_effect_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_visual_effect_retain_count = preview_frame.visual_effect_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_visual_effect_evict_count = preview_frame.visual_effect_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_glyph_atlas_entry_count = preview_frame.glyph_atlas_plan.entryCount();
            enriched_frame_event.canvas_frame_glyph_atlas_upload_count = preview_frame.glyph_atlas_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_glyph_atlas_retain_count = preview_frame.glyph_atlas_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_glyph_atlas_evict_count = preview_frame.glyph_atlas_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_text_layout_count = preview_frame.text_layout_plan.planCount();
            enriched_frame_event.canvas_frame_text_layout_line_count = preview_frame.text_layout_plan.lineCount();
            enriched_frame_event.canvas_frame_text_layout_upload_count = preview_frame.text_layout_cache_plan.uploadCount();
            enriched_frame_event.canvas_frame_text_layout_retain_count = preview_frame.text_layout_cache_plan.retainCount();
            enriched_frame_event.canvas_frame_text_layout_evict_count = preview_frame.text_layout_cache_plan.evictCount();
            enriched_frame_event.canvas_frame_gpu_packet_command_count = preview_gpu_packet_summary.command_count;
            enriched_frame_event.canvas_frame_gpu_packet_cache_action_count = preview_gpu_packet_summary.cache_action_count;
            enriched_frame_event.canvas_frame_gpu_packet_cached_resource_command_count = preview_gpu_packet_summary.cached_resource_command_count;
            enriched_frame_event.canvas_frame_gpu_packet_unsupported_command_count = preview_gpu_packet_summary.unsupported_command_count;
            enriched_frame_event.canvas_frame_gpu_packet_representable = preview_gpu_packet_summary.fullyRepresentable();
            enriched_frame_event.canvas_frame_change_count = preview_frame.changes.len;
            enriched_frame_event.canvas_frame_budget_exceeded_count = preview_budget_status.exceededCount();
            enriched_frame_event.canvas_frame_budget_ok = preview_budget_status.ok();
            enriched_frame_event.canvas_frame_dirty_bounds = preview_frame.dirty_bounds;
            const preview_profile = preview_frame.profile();
            enriched_frame_event.canvas_frame_profile_work_units = preview_profile.work_units;
            enriched_frame_event.canvas_frame_profile_risk = platformCanvasFrameProfileRisk(preview_profile.risk);
            enriched_frame_event.canvas_frame_profile_surface_area = preview_profile.surface_area;
            enriched_frame_event.canvas_frame_profile_dirty_area = preview_profile.dirty_area;
            enriched_frame_event.canvas_frame_profile_dirty_ratio = preview_profile.dirty_ratio;
            enriched_frame_event.widget_revision = self.views[index].widget_revision;
            enriched_frame_event.widget_node_count = self.views[index].widget_layout_node_count;
            enriched_frame_event.widget_semantics_count = self.views[index].widget_semantics_node_count;
        }

        fn CanvasFrameMethods() type {
            return canvas_frame_helpers.RuntimeCanvasFrames(Runtime);
        }

        fn CanvasWidgetDisplayMethods() type {
            return runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime);
        }

        fn CanvasWidgetEventMethods() type {
            return runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
        }

        fn ContextMenuMethods() type {
            return runtime_canvas_widget_context_menu.RuntimeCanvasWidgetContextMenu(Runtime);
        }

        fn ScrollDriverMethods() type {
            return runtime_canvas_widget_scroll_drivers.RuntimeCanvasWidgetScrollDrivers(Runtime);
        }
    };
}

fn setFocusedView(self: anytype, window_id: platform.WindowId, label: []const u8) !void {
    if (runtimeFindWindowIndexById(self, window_id)) |window_index| {
        self.windows[window_index].main_focused = std.mem.eql(u8, label, "main");
    }
    for (self.views[0..self.view_count], 0..) |*view, view_index| {
        if (view.window_id != window_id) continue;
        const previous_state = view.canvasWidgetRenderState();
        const was_focused = view.focused;
        view.focused = std.mem.eql(u8, view.label, label);
        const next_state = view.canvasWidgetRenderState();
        if (!runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(@TypeOf(self.*)).canvasWidgetRenderStatesEqual(previous_state, next_state)) {
            try runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(@TypeOf(self.*)).invalidateForCanvasWidgetRenderStateChange(self, view_index, previous_state, next_state);
        }
        // A view losing focus drops its tooltip state and re-stamps
        // hidden — input landing in a sibling view must not leave the
        // blurred view's tooltip floating.
        if (was_focused and !view.focused) {
            try runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(@TypeOf(self.*)).resetCanvasTooltipIntentForViewBlur(self, view_index);
        }
    }
    for (self.webviews[0..self.webview_count]) |*webview| {
        if (webview.window_id == window_id) webview.focused = std.mem.eql(u8, webview.label, label);
    }
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

fn rectsEqual(a: geometry.RectF, b: geometry.RectF) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}
