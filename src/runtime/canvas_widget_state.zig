const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const validation = @import("validation.zig");
const runtime_api = @import("api.zig");
const canvas_limits = @import("canvas_limits.zig");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const runtime_canvas_widget_scroll_drivers = @import("canvas_widget_scroll_drivers.zig");
const launch_timing = @import("launch_timing.zig");
const runtime_canvas_widget_display = @import("canvas_widget_display.zig");
const runtime_view = @import("view.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");
const runtime_automation_widget_dispatch = @import("automation_widget_dispatch.zig");
const widget_bridge = @import("widget_bridge.zig");

const validateViewLabel = validation.validateViewLabel;
const max_canvas_widget_nodes_per_view = canvas_limits.max_canvas_widget_nodes_per_view;
const max_canvas_widget_semantics_per_view = canvas_limits.max_canvas_widget_semantics_per_view;
const max_canvas_widget_text_bytes_per_view = canvas_limits.max_canvas_widget_text_bytes_per_view;
const max_canvas_widget_invalidations_per_view = canvas_limits.max_canvas_widget_invalidations_per_view;
const CanvasWidgetControlReconcileEntry = canvas_widget_runtime.CanvasWidgetControlReconcileEntry;
const CanvasWidgetTextReconcileEntry = canvas_widget_runtime.CanvasWidgetTextReconcileEntry;
const canvasWidgetLayoutTreeWithRuntimeReconcileState = canvas_widget_runtime.canvasWidgetLayoutTreeWithRuntimeReconcileState;
const canvasWidgetEditableTextKind = canvas_widget_runtime.canvasWidgetEditableTextKind;
const canvasWidgetAccessibilityActionSupported = widget_bridge.canvasWidgetAccessibilityActionSupported;
const platformWidgetAccessibilityActionKindFromCanvas = widget_bridge.platformWidgetAccessibilityActionKindFromCanvas;
const canvasWidgetBooleanSelected = canvas_widget_runtime.canvasWidgetBooleanSelected;

pub fn RuntimeCanvasWidgetState(comptime Runtime: type) type {
    return struct {
        pub fn setCanvasWidgetLayout(self: *Runtime, window_id: platform.WindowId, label: []const u8, layout: canvas.WidgetLayoutTree) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (layout.nodes.len > max_canvas_widget_nodes_per_view) return error.WidgetNodeLimitReached;

            // Frame-profile `reconcile` stage: reconcile + diff + state
            // copies, ending BEFORE the display-list refresh below so the
            // `emit` stage (stamped at its own choke point) is never
            // double-counted. No-op unless profiling is on.
            const reconcile_begin = self.frame_profile.begin();
            // Launch lap (env-gated, once per process): the startup
            // frame's reconcile begins here, splitting view build from
            // reconcile+emit inside the built -> emitted window.
            launch_timing.lapOnce("first_reconcile_begin");

            // Source-driven autofocus resolves against the PREVIOUS
            // rebuild's flags (edge-triggered) before any state is
            // replaced; the focus applies after the new tree lands.
            const autofocus_target = self.views[index].canvasWidgetAutofocusTarget(layout);
            const previous_layout = self.views[index].widgetLayoutTree();
            const source_semantics = try layout.collectSemantics(&self.canvas_widget_source_semantics_scratch);
            const reconciled_nodes = &self.canvas_widget_reconcile_nodes;
            const tokens = self.views[index].widget_tokens;
            // Reconcile scratch lives on the Runtime, not the stack: at
            // the 1024-node budget these arrays total several hundred
            // KiB, and the single-threaded event loop makes the shared
            // buffers safe.
            // Armed split-tween ids (plus the pressed split, if any):
            // the reconcile's split restore uses these to pick the
            // slide shape — keep the source's target-fraction child
            // layout and move the boundary geometrically — over the
            // re-lay shape a settled fraction (or a live drag) takes.
            var armed_tween_ids: [canvas_limits.max_canvas_widget_layout_tweens_per_view]canvas.ObjectId = undefined;
            const armed_tween_count = self.views[index].canvas_widget_layout_tween_count;
            for (self.views[index].canvas_widget_layout_tweens[0..armed_tween_count], 0..) |tween, tween_index| {
                armed_tween_ids[tween_index] = tween.spec.id;
            }
            const reconciled_layout = try canvasWidgetLayoutTreeWithRuntimeReconcileState(
                previous_layout,
                layout,
                source_semantics,
                self.views[index].widgetSourceTextEntries(),
                self.views[index].widgetSourceScrollEntries(),
                self.views[index].widgetSourceControlEntries(),
                reconciled_nodes,
                &self.canvas_widget_reconcile_control_entries,
                &self.canvas_widget_reconcile_scroll_entries,
                &self.canvas_widget_reconcile_text_entries,
                &self.canvas_widget_reconcile_text_bytes,
                tokens,
                armed_tween_ids[0..armed_tween_count],
                canvasWidgetPressedSplitId(self, index),
            );
            // Native scroll drivers: mark natively driven scroll
            // regions before the copy so rebuild-time clamping and display
            // emission both see the flag (engine scrollbar + engine clamp
            // stand down; the OS scroller owns them).
            ScrollDriverMethods(Runtime).stampCanvasWidgetNativeScroll(self, reconciled_nodes[0..reconciled_layout.nodes.len]);
            // Engine-side rebuild clamp AFTER the stamp: natively driven
            // regions skip it, so a rebuild landing mid-rubber-band keeps
            // the OS scroller's overscrolled offset instead of clamping it
            // and force-pushing the clamp into the live bounce (visible
            // jitter). Non-driver platforms clamp exactly as before.
            canvas_widget_runtime.clampCanvasWidgetLayoutScrollOffsets(reconciled_nodes[0..reconciled_layout.nodes.len], null);
            const invalidations = try canvas.WidgetLayoutTree.diffWithTokens(previous_layout, reconciled_layout, tokens, &self.canvas_widget_invalidations_scratch);
            const previous_render_state = self.views[index].canvasWidgetRenderState();
            const next_render_state = CanvasWidgetEventMethods(Runtime).canvasWidgetRenderStateAfterLayout(previous_render_state, reconciled_layout);
            const render_state_changed = !CanvasWidgetEventMethods(Runtime).canvasWidgetRenderStatesEqual(previous_render_state, next_render_state);
            const render_state_dirty = if (render_state_changed)
                previous_layout.renderStateDirtyBoundsWithTokens(previous_render_state, next_render_state, tokens)
            else
                null;
            // Disclosure tween planning reads BOTH poses — the retained
            // tree the user is looking at and the reconciled tree this
            // rebuild declared — so it runs before the copy below
            // replaces the former. The plan applies after the copy,
            // where it can restore the previous pose onto the freshly
            // retained nodes.
            const disclosure_plan = planCanvasWidgetDisclosureTween(self, index, previous_layout, reconciled_layout);
            const previous_cursor = self.views[index].canvas_widget_cursor;
            const previous_widget_revision = self.views[index].widget_revision;
            try self.views[index].copyWidgetLayoutTree(reconciled_layout, &self.canvas_widget_copy_scratch);
            try self.views[index].copyCanvasWidgetSourceText(layout);
            self.views[index].copyCanvasWidgetSourceScroll(layout);
            self.views[index].copyCanvasWidgetSourceControls(layout);
            // Push the reconciled regions (frames, content extents,
            // diverged offsets) to the native scroll drivers.
            ScrollDriverMethods(Runtime).syncCanvasWidgetScrollDriversForView(self, index);
            // Mirror the window-drag regions to hit-testing platforms
            // (Windows WM_NCHITTEST); no-op wherever the service is
            // absent, and pushes only on actual change.
            try CanvasWidgetEventMethods(Runtime).syncCanvasWidgetWindowDragRegionsForView(self, index);
            const widget_revision_changed = self.views[index].widget_revision != previous_widget_revision;
            if (previous_cursor != self.views[index].canvas_widget_cursor) try CanvasWidgetEventMethods(Runtime).syncCanvasWidgetCursorForView(self, index);
            CanvasWidgetEventMethods(Runtime).invalidateForWidgetInvalidations(self, self.views[index].frame, invalidations);
            if (render_state_changed) CanvasWidgetEventMethods(Runtime).invalidateForCanvasWidgetRenderStateDirty(self, index, render_state_dirty);
            const layout_dirty = invalidations.len > 0 or render_state_changed;
            if (autofocus_target) |autofocus_id| {
                // The same focus write every other focus source performs
                // (view focus + focused/visible ids + invalidation);
                // widgets that are not focusable ignore the request.
                if (self.views[index].widgetLayoutTree().focusTargetById(autofocus_id) != null) {
                    try AutomationWidgetMethods(Runtime).focusAutomationCanvasWidget(self, index, autofocus_id);
                }
            }
            self.frame_profile.end(.reconcile, reconcile_begin);
            // Source-declared layout tweens, AFTER the reconciled tree is
            // retained (the arm reads the kept fraction as its `from`)
            // and BEFORE the display refresh (a reduced-motion snap must
            // paint in this rebuild's frame, not the next one). Both
            // markup engines and the Zig builder lower `resize-duration`
            // into the same widget fields, so this one walk is the whole
            // consumer.
            try armSourceDeclaredLayoutTweens(self, index, layout);
            // Disclosure tween application, still BEFORE the display
            // refresh: an armed reveal restores the previous pose onto
            // the retained frames so THIS rebuild keeps painting what
            // the user was looking at, and the tween walks it to the
            // declared pose one presented frame at a time.
            try applyCanvasWidgetDisclosureTweenPlan(self, index, disclosure_plan);
            const requested_frame = try CanvasWidgetDisplayMethods(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
            if ((layout_dirty or widget_revision_changed) and !requested_frame) try CanvasFrameMethods(Runtime).requestCanvasFrameForView(self, index);
            return self.views[index].info();
        }

        pub fn canvasWidgetLayout(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!canvas.WidgetLayoutTree {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return self.views[index].widgetLayoutTree();
        }

        pub fn canvasWidgetSemantics(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror![]const canvas.WidgetSemanticsNode {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return self.views[index].widgetSemantics();
        }

        pub fn dispatchCanvasWidgetAccessibilityAction(
            self: *Runtime,
            app: runtime_api.App(Runtime),
            window_id: platform.WindowId,
            label: []const u8,
            action: runtime_api.CanvasWidgetAccessibilityAction,
        ) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            if (action.id == 0) return error.InvalidCommand;
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            const actions = AutomationWidgetMethods(Runtime).canvasWidgetActionsForId(self, index, action.id) orelse return error.InvalidCommand;
            if (!canvasWidgetAccessibilityActionSupported(actions, action.action)) return error.InvalidCommand;

            // Session recording, outer-wins on BOTH entry surfaces: the
            // platform AX path arrives with its journaled tag-23 event
            // already on the recorder's staging stack (flow.zig staged
            // it), but the DIRECT verb surfaces (an embed host's
            // `widgetAction`, automation `widget_action` commands) reach
            // here with no platform event at all. Their verbs journal
            // only UNTARGETED children routed by focus, while the focus
            // write itself (`focusAutomationCanvasWidget`) is a direct
            // unjournaled state change — so a fresh replay delivered the
            // children against whatever focus the session happened to
            // hold and a first-in-session composition landed nowhere.
            // Stage the same synthetic `widget_accessibility_action`
            // record the platform path carries: its suppression window
            // keeps the children out of the journal and replay re-runs
            // this whole dispatch — focus included — through the tag-23
            // arm in flow.zig. When the platform event IS already staged,
            // this nested stage lands inside its suppression window as a
            // never-written placeholder, so no double record; the commit
            // below pops it symmetrically. Effect results drained during
            // the verb still write through ahead of the record, and
            // event_count/checkpoint ordinals only ever see the one
            // surviving record (checkpoints fire at staging depth 0).
            if (self.options.session_recorder) |recorder| recorder.stageEvent(.{ .widget_accessibility_action = .{
                .window_id = window_id,
                .label = label,
                .id = action.id,
                .action = platformWidgetAccessibilityActionKindFromCanvas(action.action),
                .text = action.text,
                .selection = if (action.selection) |selection| .{ .start = selection.anchor, .end = selection.focus } else null,
            } });
            defer if (self.options.session_recorder) |recorder| recorder.commitEvent();

            // Every assistive action rides the SAME machinery the
            // automation widget verbs use — the key-driven activation for
            // press/toggle/increment/decrement (quiet-list-row ring
            // escalation included), the text editor for set_text and the
            // composition family, the selection/dismiss verbs for the
            // rest. An earlier "direct" shortcut here applied semantic
            // control intents to the retained tree instead: it flipped
            // echoes (toggle state, slider value) and dispatched only the
            // widget's `command` string, so a widget wired through message
            // handlers (an `on_press` tab, an `on_toggle` checkbox) kept
            // reporting success while the app's model never heard the
            // action — an advertised action an assistive-technology user
            // could not actually invoke. The key-driven route reaches the
            // same typed dispatch a real keyboard user's activation does,
            // so anything a keyboard can actuate, an AX client can too.
            switch (action.action) {
                .focus => try AutomationWidgetMethods(Runtime).focusAutomationCanvasWidget(self, index, action.id),
                .press => try AutomationWidgetMethods(Runtime).dispatchAutomationWidgetKey(self, app, index, action.id, "enter"),
                .toggle => try AutomationWidgetMethods(Runtime).dispatchAutomationWidgetKey(self, app, index, action.id, "space"),
                .increment => try AutomationWidgetMethods(Runtime).dispatchAutomationWidgetKey(self, app, index, action.id, self.views[index].canvasWidgetStepKey(action.id, .increment)),
                .decrement => try AutomationWidgetMethods(Runtime).dispatchAutomationWidgetKey(self, app, index, action.id, self.views[index].canvasWidgetStepKey(action.id, .decrement)),
                .set_text => try AutomationWidgetMethods(Runtime).setAutomationCanvasWidgetText(self, app, index, action.id, action.text),
                .set_selection => try AutomationWidgetMethods(Runtime).editAutomationCanvasWidgetText(self, app, index, action.id, .{ .set_selection = action.selection orelse return error.InvalidCommand }),
                .set_composition => try AutomationWidgetMethods(Runtime).composeAutomationCanvasWidgetText(self, app, index, action.id, .ime_set_composition, action.text),
                .commit_composition => try AutomationWidgetMethods(Runtime).composeAutomationCanvasWidgetText(self, app, index, action.id, .ime_commit_composition, ""),
                .cancel_composition => try AutomationWidgetMethods(Runtime).composeAutomationCanvasWidgetText(self, app, index, action.id, .ime_cancel_composition, ""),
                .select => try AutomationWidgetMethods(Runtime).selectAutomationCanvasWidget(self, index, action.id),
                .drag => try AutomationWidgetMethods(Runtime).dispatchAutomationCanvasWidgetDrag(self, app, index, action.id, action.text),
                .drop_files => try AutomationWidgetMethods(Runtime).dispatchAutomationCanvasWidgetFileDrop(self, app, index, action.id, action.text),
                .dismiss => try AutomationWidgetMethods(Runtime).dismissAutomationCanvasWidget(self, app, index, action.id),
            }
            // Key-driven action routes above dispatch real input events
            // whose refresh batches defer the platform publish; the AX
            // client reads the tree next, so force-flush here too.
            try CanvasWidgetDisplayMethods(Runtime).flushDeferredCanvasWidgetAccessibility(self);
            return self.views[index].info();
        }

        pub fn stepCanvasWidgetKineticScroll(self: *Runtime, window_id: platform.WindowId, label: []const u8, dt_ms: f32) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

            const dirty = try self.views[index].stepCanvasWidgetKineticScroll(dt_ms) orelse return self.views[index].info();
            const previous_cursor = self.views[index].canvas_widget_cursor;
            self.views[index].reconcileCanvasWidgetRenderStateAfterScroll(null);
            if (previous_cursor != self.views[index].canvas_widget_cursor) try CanvasWidgetEventMethods(Runtime).syncCanvasWidgetCursorForView(self, index);
            try CanvasWidgetEventMethods(Runtime).invalidateForCanvasWidgetDirty(self, index, dirty);
            _ = try CanvasWidgetDisplayMethods(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
            return self.views[index].info();
        }

        /// Arm (or retarget) a runtime-driven layout tween: the split's
        /// first-pane fraction eases from its CURRENT retained value to
        /// `tween.to` over `tween.duration_ms`, one step per presented
        /// frame, sampled from the frame event's recorded timestamp —
        /// so a recorded session replays to identical frames and idle
        /// apps present nothing (the tween itself keeps the frame
        /// channel armed only while it runs).
        ///
        /// Contract, in declaration order:
        ///   - id 0 or a non-split id is a teaching error;
        ///   - already at the target (and nothing armed): no-op;
        ///   - reduce-motion appearance or duration 0: SNAP through the
        ///     same mutation path a divider drag uses (dirty region,
        ///     resize event, reconcile survival), never animate;
        ///   - re-declared with the same target while armed: no-op —
        ///     the per-rebuild declarative hook calls this every
        ///     rebuild and must not restart the clock;
        ///   - re-declared with a NEW target while armed: retarget from
        ///     the current animated value, fresh clock;
        ///   - every tween slot taken: snap (motion degrades under
        ///     pressure; the state change always lands).
        ///
        /// Resize echoes: arming (or retargeting) notes ONE resize
        /// event carrying the DESTINATION, and the settle step notes
        /// one with the applied fraction — never one per step. The arm
        /// echo is what lets a controlled split's model rebuild at the
        /// target ONCE, so the reconcile keeps the target-wrapped
        /// content and the tween slides it under the pane clip with
        /// zero mid-flight re-wraps (the disclosure doctrine,
        /// horizontal). A divider DRAG keeps its per-step echoes: a
        /// drag tracks the pointer and must re-wrap live.
        pub fn startCanvasWidgetLayoutTween(self: *Runtime, window_id: platform.WindowId, label: []const u8, tween: canvas.CanvasWidgetLayoutTween) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            try startCanvasWidgetLayoutTweenForView(self, index, tween, true);
            return self.views[index].info();
        }

        /// The tween contract's core, shared by the public command above
        /// and the source-declared lowering in `setCanvasWidgetLayout`
        /// (a split whose SOURCE declares `resize_duration_ms` arms the
        /// same tween the Zig hook would, so both authoring surfaces
        /// step identical fractions on identical frame clocks).
        /// `announce` notes the destination resize event on a fresh arm
        /// or retarget — true for the command/hook path (the app's
        /// model has not seen the target yet and needs one rebuild at
        /// it), false for the source-declared path (the source that
        /// armed this tween IS the target declaration; echoing it back
        /// would be a redundant rebuild).
        fn startCanvasWidgetLayoutTweenForView(self: *Runtime, index: usize, tween: canvas.CanvasWidgetLayoutTween, announce: bool) anyerror!void {
            if (tween.id == 0) return error.InvalidCommand;
            if (!std.math.isFinite(tween.to)) return error.InvalidCommand;
            const node_index = self.views[index].canvasWidgetNodeIndexById(tween.id) orelse return error.InvalidCommand;
            if (self.views[index].widget_layout_nodes[node_index].widget.kind != .split) return error.InvalidCommand;
            const current = self.views[index].widget_layout_nodes[node_index].widget.value;

            const snap = self.appearance.reduce_motion or tween.duration_ms == 0;
            if (self.views[index].findCanvasWidgetLayoutTween(tween.id)) |active| {
                if (snap) {
                    // Reduce motion arrived (or the declaration turned
                    // instant) while armed: retire the tween and land
                    // on the target through the snap path below.
                    self.views[index].removeCanvasWidgetLayoutTween(tween.id);
                } else {
                    if (active.spec.to == tween.to) return;
                    active.spec = tween;
                    active.from = current;
                    active.start_ns = 0;
                    if (announce) self.views[index].noteCanvasWidgetResizeEvent(tween.id);
                    try CanvasFrameMethods(Runtime).requestCanvasFrameForView(self, index);
                    return;
                }
            }
            if (current == tween.to) return;

            if (!snap and self.views[index].armCanvasWidgetLayoutTween(.{ .spec = tween, .from = current })) {
                if (announce) self.views[index].noteCanvasWidgetResizeEvent(tween.id);
                try CanvasFrameMethods(Runtime).requestCanvasFrameForView(self, index);
                return;
            }
            if (try self.views[index].applyCanvasWidgetSplitFraction(node_index, tween.to)) |dirty| {
                try CanvasWidgetEventMethods(Runtime).invalidateForCanvasWidgetDirty(self, index, dirty);
            }
        }

        /// The SOURCE-declared half of the layout tween: a split whose
        /// tree declares a nonzero `resize_duration_ms` treats its
        /// declared `value` as the tween target. Called by
        /// `setCanvasWidgetLayout` after the reconciled tree lands (the
        /// reconcile kept the rendered fraction instead of snapping it
        /// to the moved source), so every rebuild re-declares the tween
        /// exactly like the Zig `layout_tweens` hook does — idempotent
        /// per target, retargeting on a new one, snapping under reduced
        /// motion. Skips:
        ///   - value 0: the "unset" sentinel (a bare split lays out at
        ///     0.5); nothing declares a target, so nothing tweens;
        ///   - a pressed divider: a live drag owns the fraction — the
        ///     tween re-arms on the first rebuild after release.
        fn armSourceDeclaredLayoutTweens(self: *Runtime, index: usize, source: canvas.WidgetLayoutTree) anyerror!void {
            for (source.nodes) |node| {
                if (node.widget.kind != .split or node.widget.id == 0) continue;
                if (node.widget.resize_duration_ms == 0) continue;
                if (node.widget.value == 0) continue;
                if (canvasWidgetSplitDividerPressed(self, index, node.widget.id)) continue;
                startCanvasWidgetLayoutTweenForView(self, index, .{
                    .id = node.widget.id,
                    .to = node.widget.value,
                    .duration_ms = node.widget.resize_duration_ms,
                    .easing = node.widget.resize_easing,
                }, false) catch |err| switch (err) {
                    // The id vanished in reconcile (hidden pane, dropped
                    // subtree): nothing to move — same tolerance as the
                    // Zig hook's stale-id skip.
                    error.InvalidCommand => continue,
                    else => return err,
                };
            }
        }

        /// Whether the RETAINED tree's pressed widget is this split's
        /// synthesized divider — a live drag. The drag owns the fraction
        /// while it lasts, so the source-declared tween stands down and
        /// re-arms on the first rebuild after release.
        fn canvasWidgetSplitDividerPressed(self: *Runtime, index: usize, split_id: canvas.ObjectId) bool {
            return canvasWidgetPressedSplitId(self, index) == split_id and split_id != 0;
        }

        /// The split whose synthesized divider the RETAINED tree holds
        /// pressed (0 when no divider is pressed): the reconcile keeps
        /// live re-wrap for exactly this split while a drag lasts.
        fn canvasWidgetPressedSplitId(self: *Runtime, index: usize) canvas.ObjectId {
            const pressed_id = self.views[index].canvas_widget_pressed_id;
            if (pressed_id == 0) return 0;
            const divider_index = self.views[index].canvasWidgetNodeIndexById(pressed_id) orelse return 0;
            const divider = self.views[index].widget_layout_nodes[divider_index];
            if (divider.widget.kind != .split_divider) return 0;
            const parent_index = divider.parent_index orelse return 0;
            if (parent_index >= self.views[index].widget_layout_node_count) return 0;
            return self.views[index].widget_layout_nodes[parent_index].widget.id;
        }

        /// What `setCanvasWidgetLayout` should do about DISCLOSURE
        /// motion this rebuild, decided by diffing the two poses:
        ///   - `arm`: the rebuild flipped at least one disclosure
        ///     widget and the reflow is pure vertical — play the diff;
        ///   - `refresh`: no flip, but a tween is in flight — re-point
        ///     its targets at the new tree and re-apply the mid-flight
        ///     pose the copy just stomped;
        ///   - `retire`: an in-flight tween can no longer replay (the
        ///     node sequence changed, motion got disabled, or the
        ///     reflow stopped being disclosure-shaped) — the new pose
        ///     stands snapped;
        ///   - `none`: nothing armed, nothing to arm.
        const CanvasWidgetDisclosureAction = enum { none, arm, refresh, retire };

        const CanvasWidgetDisclosurePlan = struct {
            action: CanvasWidgetDisclosureAction = .none,
            duration_ms: u32 = 0,
            revealing_ids: [canvas_limits.max_canvas_widget_disclosure_flips_per_view]canvas.ObjectId = undefined,
            revealing_id_count: usize = 0,
            moves: [canvas_limits.max_canvas_widget_disclosure_moves_per_view]runtime_view.CanvasWidgetDisclosureMove = undefined,
            move_count: usize = 0,
        };

        /// The planning half of the disclosure tween (see
        /// `CanvasWidgetDisclosureTweenState` for the design): pure
        /// reads over the previous retained pose and the reconciled
        /// next pose, no mutation — the caller applies the plan after
        /// the reconciled tree is retained.
        fn planCanvasWidgetDisclosureTween(self: *Runtime, view_index: usize, previous: canvas.WidgetLayoutTree, next: canvas.WidgetLayoutTree) CanvasWidgetDisclosurePlan {
            var plan = CanvasWidgetDisclosurePlan{};
            const view = &self.views[view_index];
            const was_active = view.canvas_widget_disclosure_tween.active;
            const retire_or_none: CanvasWidgetDisclosureAction = if (was_active) .retire else .none;

            // The tween replays frame motion BY NODE INDEX, which is
            // only meaningful while both rebuilds describe the same
            // node sequence. A pure disclosure flip preserves it —
            // children lay out open or closed — so a mismatch means
            // this rebuild changed more than disclosure: snap.
            if (previous.nodes.len != next.nodes.len) {
                plan.action = retire_or_none;
                return plan;
            }
            for (previous.nodes, next.nodes) |previous_node, next_node| {
                if (previous_node.widget.kind != next_node.widget.kind or previous_node.widget.id != next_node.widget.id) {
                    plan.action = retire_or_none;
                    return plan;
                }
            }

            // Flips: a disclosure widget whose OPEN state changed
            // across the rebuild, or whose toggle the runtime echoed
            // since the last one (the echo already flipped the retained
            // state, so the state comparison alone would miss it).
            var flips_overflowed = false;
            for (next.nodes, 0..) |node, node_index| {
                if (!canvas.widgetKindDisclosureAnimated(node.widget.kind) or node.widget.id == 0) continue;
                const was_open = canvasWidgetBooleanSelected(previous.nodes[node_index].widget);
                const now_open = canvasWidgetBooleanSelected(node.widget);
                if (was_open == now_open and !view.canvasWidgetDisclosureTogglePending(node.widget.id)) continue;
                if (plan.revealing_id_count >= plan.revealing_ids.len) {
                    flips_overflowed = true;
                    break;
                }
                plan.revealing_ids[plan.revealing_id_count] = node.widget.id;
                plan.revealing_id_count += 1;
            }
            if (flips_overflowed) {
                plan.action = retire_or_none;
                return plan;
            }
            if (plan.revealing_id_count == 0) {
                plan.action = if (was_active) .refresh else .none;
                return plan;
            }

            // Default-on motion from the register: the `normal` class
            // duration and house easing, no app declaration anywhere.
            // Reduced motion (or a zeroed register) snaps.
            plan.duration_ms = view.widget_tokens.motion.durationMs(.normal);
            if (self.appearance.reduce_motion or plan.duration_ms == 0) {
                plan.action = retire_or_none;
                return plan;
            }

            // The layout diff this tween will play. Disclosure reflow is
            // vertical by construction; any horizontal delta means the
            // rebuild moved more than disclosure (a resize riding the
            // same dispatch), and a diff too large to record cannot
            // replay honestly — both snap.
            for (previous.nodes, next.nodes, 0..) |previous_node, next_node, node_index| {
                if (previous_node.frame.x != next_node.frame.x or previous_node.frame.width != next_node.frame.width) {
                    plan.action = retire_or_none;
                    return plan;
                }
                if (previous_node.frame.y == next_node.frame.y and previous_node.frame.height == next_node.frame.height) continue;
                if (plan.move_count >= plan.moves.len) {
                    plan.action = retire_or_none;
                    return plan;
                }
                plan.moves[plan.move_count] = .{
                    .node_index = node_index,
                    .from_y = previous_node.frame.y,
                    .from_height = previous_node.frame.height,
                    .to_y = next_node.frame.y,
                    .to_height = next_node.frame.height,
                };
                plan.move_count += 1;
            }
            // A flip that moved nothing (an empty section, or a toggle
            // echo the model ignored) has no motion to play.
            if (plan.move_count == 0) {
                plan.action = if (was_active) .refresh else .none;
                return plan;
            }
            plan.action = .arm;
            return plan;
        }

        /// The applying half: runs after the reconciled tree is
        /// retained. Arming restores the PREVIOUS pose onto the
        /// retained frames (the user keeps looking at what they were
        /// looking at; the tween walks it to the declared pose on the
        /// frame clock); refreshing re-applies an in-flight pose that
        /// the copy stomped. Toggle-echo notes are consumed here on
        /// every rebuild — applied or ignored, a note never outlives
        /// the rebuild that had the chance to animate it.
        fn applyCanvasWidgetDisclosureTweenPlan(self: *Runtime, view_index: usize, plan: CanvasWidgetDisclosurePlan) anyerror!void {
            const view = &self.views[view_index];
            view.canvas_widget_disclosure_pending_count = 0;
            switch (plan.action) {
                .none => {},
                .retire => view.clearCanvasWidgetDisclosureTween(),
                .refresh => try refreshCanvasWidgetDisclosurePose(self, view_index),
                .arm => {
                    view.canvas_widget_disclosure_tween = .{
                        .active = true,
                        .duration_ms = plan.duration_ms,
                        .easing = view.widget_tokens.motion.easing,
                        .spring = view.widget_tokens.motion.spring,
                    };
                    const tween = &view.canvas_widget_disclosure_tween;
                    @memcpy(tween.revealing_ids[0..plan.revealing_id_count], plan.revealing_ids[0..plan.revealing_id_count]);
                    tween.revealing_id_count = plan.revealing_id_count;
                    @memcpy(tween.moves[0..plan.move_count], plan.moves[0..plan.move_count]);
                    tween.move_count = plan.move_count;
                    for (tween.moves[0..tween.move_count]) |move| {
                        if (move.node_index >= view.widget_layout_node_count) continue;
                        const node = &view.widget_layout_nodes[move.node_index];
                        node.frame.y = move.from_y;
                        node.frame.height = move.from_height;
                        node.widget.frame = node.frame;
                    }
                    view.widget_revision += 1;
                    try view.refreshCanvasWidgetSemantics();
                    try CanvasFrameMethods(Runtime).requestCanvasFrameForView(self, view_index);
                },
            }
        }

        /// A rebuild landed while a disclosure tween is in flight
        /// without flipping anything (the split tween's "same target
        /// re-declared" case): the copy stomped the mid-flight pose
        /// with the target pose, so re-point each move's target at the
        /// fresh tree and re-apply the pose at the last eased progress —
        /// the user never sees the one-frame pop, and the clock keeps
        /// running.
        fn refreshCanvasWidgetDisclosurePose(self: *Runtime, view_index: usize) anyerror!void {
            const view = &self.views[view_index];
            const tween = &view.canvas_widget_disclosure_tween;
            var moved = false;
            for (tween.moves[0..tween.move_count]) |*move| {
                if (move.node_index >= view.widget_layout_node_count) continue;
                const node = &view.widget_layout_nodes[move.node_index];
                move.to_y = node.frame.y;
                move.to_height = node.frame.height;
                const y = move.from_y + (move.to_y - move.from_y) * tween.progress;
                const height = move.from_height + (move.to_height - move.from_height) * tween.progress;
                if (node.frame.y == y and node.frame.height == height) continue;
                node.frame.y = y;
                node.frame.height = height;
                node.widget.frame = node.frame;
                moved = true;
            }
            if (moved) {
                view.widget_revision += 1;
                try view.refreshCanvasWidgetSemantics();
            }
            try CanvasFrameMethods(Runtime).requestCanvasFrameForView(self, view_index);
        }

        /// One presented frame's worth of disclosure motion for a view,
        /// the layout tween advance's sibling: sample the eased progress
        /// at the frame's RECORDED timestamp (replay-deterministic, no
        /// wall clock), walk every recorded move to its interpolated
        /// frame, and land dirty regions through the same widget-dirty
        /// path a drag uses — so mid-tween presents stay region-scoped
        /// patches. The settle frame snaps every move to its exact
        /// target, retires the tween (emptying the revealing set, which
        /// drops a closing item's clipped content from the next
        /// emission), and stops requesting frames.
        pub fn advanceCanvasWidgetDisclosureTweenForFrame(self: *Runtime, view_index: usize, timestamp_ns: u64) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            const view = &self.views[view_index];
            if (!view.canvas_widget_disclosure_tween.active) return;
            const tween = &view.canvas_widget_disclosure_tween;

            // First advancing frame stamps the clock — the split
            // tween's discipline, so the ramp runs on the frame clock
            // from the first frame that could have painted it.
            if (tween.start_ns == 0 or timestamp_ns < tween.start_ns) {
                tween.start_ns = timestamp_ns;
            }
            const progress = canvas.layoutTweenProgress(tween.easing, tween.spring, tween.start_ns, tween.duration_ms, timestamp_ns);
            const done = progress >= 1;
            tween.progress = progress;

            var dirty: ?geometry.RectF = null;
            for (tween.moves[0..tween.move_count]) |move| {
                if (move.node_index >= view.widget_layout_node_count) continue;
                const node = &view.widget_layout_nodes[move.node_index];
                const y = if (done) move.to_y else move.from_y + (move.to_y - move.from_y) * progress;
                const height = if (done) move.to_height else move.from_height + (move.to_height - move.from_height) * progress;
                if (node.frame.y == y and node.frame.height == height) continue;
                dirty = unionDisclosureDirty(dirty, node.frame.normalized());
                node.frame.y = y;
                node.frame.height = height;
                node.widget.frame = node.frame;
                dirty = unionDisclosureDirty(dirty, node.frame.normalized());
            }
            // Retire BEFORE the refresh below so the settle emission
            // paints with an empty revealing set.
            if (done) view.clearCanvasWidgetDisclosureTween();
            if (dirty) |region| {
                view.widget_revision += 1;
                try view.refreshCanvasWidgetSemantics();
                try CanvasWidgetEventMethods(Runtime).invalidateForCanvasWidgetDirty(self, view_index, region);
            } else if (done) {
                // Nothing moved on the settle frame, but the revealing
                // set just emptied — re-emit so closing items drop
                // their clipped content.
                _ = try CanvasWidgetDisplayMethods(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, view_index);
            }
            if (!done) try CanvasFrameMethods(Runtime).requestCanvasFrameForView(self, view_index);
        }

        /// One presented frame's worth of layout-tween motion for a
        /// view, called from the frame event dispatch (the kinetic
        /// scroll's sibling). Each active tween samples its eased
        /// fraction at the frame's timestamp and lands it through the
        /// split-drag GEOMETRY (pane frames move, the second pane's
        /// subtree translates, dirty regions ride the retained diff) —
        /// but NOT the drag's per-step resize echo: mid-flight steps
        /// slide content the reconcile already laid out at the tween's
        /// target fraction, cropped by the pane's built-in clip, so a
        /// per-step echo would rebuild and re-wrap the panes every
        /// frame for nothing (the exact cost this doctrine retires).
        /// The settle step snaps to the exact target, notes the ONE
        /// resize echo carrying the applied fraction (the controlled
        /// echo and any structural swap ride it), and retires; while
        /// any tween remains active the next frame is requested, so
        /// the channel disarms itself the frame after the last one
        /// settles.
        pub fn advanceCanvasWidgetLayoutTweensForFrame(self: *Runtime, view_index: usize, timestamp_ns: u64) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            if (!self.views[view_index].canvasWidgetLayoutTweensActive()) return;

            var tween_index: usize = 0;
            while (tween_index < self.views[view_index].canvas_widget_layout_tween_count) {
                const tween = &self.views[view_index].canvas_widget_layout_tweens[tween_index];
                // The widget vanished from the tree (the model dropped
                // the split): retire silently, nothing to move.
                const node_index = self.views[view_index].canvasWidgetNodeIndexById(tween.spec.id) orelse {
                    self.views[view_index].removeCanvasWidgetLayoutTween(tween.spec.id);
                    continue;
                };
                // First advancing frame stamps the clock: the ramp runs
                // on the frame clock from the first frame that could
                // have painted it, the manual idiom's discipline.
                if (tween.start_ns == 0 or timestamp_ns < tween.start_ns) {
                    tween.start_ns = timestamp_ns;
                }
                const progress = canvas.layoutTweenProgress(tween.spec.easing, tween.spec.spring, tween.start_ns, tween.spec.duration_ms, timestamp_ns);
                const done = progress >= 1;
                const value = if (done) tween.spec.to else tween.from + (tween.spec.to - tween.from) * progress;
                const dirty = if (done)
                    try self.views[view_index].applyCanvasWidgetSplitFraction(node_index, value)
                else
                    try self.views[view_index].applyCanvasWidgetSplitFractionSlide(node_index, value);
                if (dirty) |region| {
                    try CanvasWidgetEventMethods(Runtime).invalidateForCanvasWidgetDirty(self, view_index, region);
                }
                if (done) {
                    // A settle that moved nothing because the last step
                    // already sat EXACTLY on the target still owes the
                    // app its one settle echo. A settle that moved
                    // nothing because the pane-min clamp PARKED the
                    // fraction short of the target owes nothing: the
                    // model already holds the target it declared, and
                    // echoing the parked fraction every settle would
                    // rebuild-and-re-arm forever.
                    if (dirty == null and self.views[view_index].widget_layout_nodes[node_index].widget.value == tween.spec.to) {
                        self.views[view_index].noteCanvasWidgetResizeEvent(tween.spec.id);
                    }
                    // removeCanvasWidgetLayoutTween swap-removes, so the
                    // slot at tween_index now holds an unvisited tween.
                    self.views[view_index].removeCanvasWidgetLayoutTween(tween.spec.id);
                    continue;
                }
                tween_index += 1;
            }
            if (self.views[view_index].canvasWidgetLayoutTweensActive()) {
                try CanvasFrameMethods(Runtime).requestCanvasFrameForView(self, view_index);
            }
        }

        pub fn setCanvasWidgetDesignTokens(self: *Runtime, window_id: platform.WindowId, label: []const u8, tokens: canvas.DesignTokens) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (std.meta.eql(self.views[index].widget_tokens, tokens)) return self.views[index].info();
            self.views[index].widget_tokens = tokens;
            self.views[index].widget_revision += 1;
            if (self.views[index].canvas_display_list_widget_owned) {
                _ = try CanvasWidgetDisplayMethods(Runtime).refreshCanvasWidgetDisplayList(self, index);
            }
            return self.views[index].info();
        }

        pub fn canvasWidgetDesignTokens(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!canvas.DesignTokens {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            return self.views[index].widget_tokens;
        }

        pub fn canvasWidgetTextGeometry(self: *const Runtime, window_id: platform.WindowId, label: []const u8, id: canvas.ObjectId) anyerror!canvas.WidgetTextGeometry {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            if (id == 0) return error.InvalidCommand;
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            const node = self.views[index].widgetLayoutTree().findById(id) orelse return error.InvalidCommand;
            if (!canvasWidgetEditableTextKind(node.widget.kind)) return error.InvalidCommand;
            return canvas.textGeometryForWidget(node.widget, self.views[index].widget_tokens);
        }

        pub fn editCanvasWidgetText(self: *Runtime, window_id: platform.WindowId, label: []const u8, id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            if (id == 0) return error.InvalidCommand;
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (!self.views[index].canEditCanvasWidgetText(id)) return error.InvalidCommand;

            const dirty = try self.views[index].applyCanvasWidgetTextEdit(id, edit) orelse return self.views[index].info();
            try CanvasWidgetEventMethods(Runtime).invalidateForCanvasWidgetDirty(self, index, dirty);
            _ = try CanvasWidgetDisplayMethods(Runtime).refreshCanvasWidgetDisplayListIfOwned(self, index);
            return self.views[index].info();
        }
    };
}

fn CanvasFrameMethods(comptime Runtime: type) type {
    return canvas_frame_helpers.RuntimeCanvasFrames(Runtime);
}

fn CanvasWidgetDisplayMethods(comptime Runtime: type) type {
    return runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime);
}

fn CanvasWidgetEventMethods(comptime Runtime: type) type {
    return runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
}

fn AutomationWidgetMethods(comptime Runtime: type) type {
    return runtime_automation_widget_dispatch.RuntimeAutomationWidgetDispatch(Runtime);
}

fn ScrollDriverMethods(comptime Runtime: type) type {
    return runtime_canvas_widget_scroll_drivers.RuntimeCanvasWidgetScrollDrivers(Runtime);
}

/// Dirty-region accumulation for disclosure steps: the union of every
/// moved frame's before and after — the moving band, not the surface.
fn unionDisclosureDirty(current: ?geometry.RectF, frame: geometry.RectF) ?geometry.RectF {
    if (frame.isEmpty()) return current;
    const existing = current orelse return frame;
    return geometry.RectF.unionWith(existing, frame);
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
