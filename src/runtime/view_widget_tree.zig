const geometry = @import("geometry");
const canvas = @import("canvas");
const validation = @import("validation.zig");
const canvas_limits = @import("canvas_limits.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const widget_bridge = @import("widget_bridge.zig");
const platform = @import("../platform/root.zig");

const validateCommandName = validation.validateCommandName;
const max_canvas_widget_nodes_per_view = canvas_limits.max_canvas_widget_nodes_per_view;
const max_canvas_widget_semantics_per_view = canvas_limits.max_canvas_widget_semantics_per_view;
const max_canvas_widget_text_bytes_per_view = canvas_limits.max_canvas_widget_text_bytes_per_view;
const max_canvas_widget_source_text_entries_per_view = canvas_limits.max_canvas_widget_source_text_entries_per_view;

const CanvasWidgetScrollReconcileEntry = canvas_widget_runtime.CanvasWidgetScrollReconcileEntry;
const CanvasWidgetSurfaceDismissal = canvas_widget_runtime.CanvasWidgetSurfaceDismissal;
const CanvasWidgetControlReconcileEntry = canvas_widget_runtime.CanvasWidgetControlReconcileEntry;
const CanvasWidgetTextReconcileEntry = canvas_widget_runtime.CanvasWidgetTextReconcileEntry;
const CanvasWidgetSourceTextEntry = canvas_widget_runtime.CanvasWidgetSourceTextEntry;
const CanvasWidgetStepDirection = canvas_widget_runtime.CanvasWidgetStepDirection;
const canvasWidgetInteractionTargetExists = canvas_widget_runtime.canvasWidgetInteractionTargetExists;
const canvasWidgetLayoutNodeClippedBounds = canvas_widget_runtime.canvasWidgetLayoutNodeClippedBounds;
const canvasWidgetDismissibleSurfaceKind = canvas_widget_runtime.canvasWidgetDismissibleSurfaceKind;
const canvasWidgetEditableTextKind = canvas_widget_runtime.canvasWidgetEditableTextKind;
const collectCanvasWidgetControlReconcileEntries = canvas_widget_runtime.collectCanvasWidgetControlReconcileEntries;
const collectCanvasWidgetScrollReconcileEntries = canvas_widget_runtime.collectCanvasWidgetScrollReconcileEntries;
const canvasWidgetScrollStateForLayoutNode = canvas_widget_runtime.canvasWidgetScrollStateForLayoutNode;
const collectCanvasWidgetTextReconcileEntries = canvas_widget_runtime.collectCanvasWidgetTextReconcileEntries;
const canvasWidgetSourceTextFingerprint = canvas_widget_runtime.canvasWidgetSourceTextFingerprint;
const canvasWidgetLayoutNodeWithControlReconcileState = canvas_widget_runtime.canvasWidgetLayoutNodeWithControlReconcileState;
const canvasWidgetLayoutNodeWithTextReconcileState = canvas_widget_runtime.canvasWidgetLayoutNodeWithTextReconcileState;
const canvasWidgetLayoutNodeWithSourceSemantics = canvas_widget_runtime.canvasWidgetLayoutNodeWithSourceSemantics;
const applyCanvasWidgetSourceScrollSemantics = canvas_widget_runtime.applyCanvasWidgetSourceScrollSemantics;
const clampCanvasWidgetLayoutScrollOffsets = canvas_widget_runtime.clampCanvasWidgetLayoutScrollOffsets;
const clampCanvasWidgetLayoutTextOffsets = canvas_widget_runtime.clampCanvasWidgetLayoutTextOffsets;

const platformCursorFromCanvas = widget_bridge.platformCursorFromCanvas;

/// Byte offset of `inner` within `outer` when it is a subslice, else null.
fn subsliceOffset(outer: []const u8, inner: []const u8) ?usize {
    if (inner.len == 0) return 0;
    const outer_start = @intFromPtr(outer.ptr);
    const inner_start = @intFromPtr(inner.ptr);
    if (inner_start < outer_start) return null;
    const offset = inner_start - outer_start;
    if (offset + inner.len > outer.len) return null;
    return offset;
}

/// Total retained-pool demand of a layout, mirrored charge-for-charge
/// from `copyWidgetLayoutNode` and its helpers (text/icon/command/label
/// bytes, span text unless it rebases as a subslice of the widget text,
/// span links, context-menu labels, chart labels/values/lows). Checked
/// BEFORE `copyWidgetLayoutTree` resets the pools so a budget overflow
/// is loud AND atomic — the previous tree stays applied instead of a
/// torn partial copy.
fn validateWidgetLayoutPoolBudgets(
    layout: canvas.WidgetLayoutTree,
    previous_texts: *const canvas_widget_runtime.CanvasWidgetTextEntryIndex,
) anyerror!void {
    var text_len: usize = 0;
    var span_len: usize = 0;
    var menu_len: usize = 0;
    var series_len: usize = 0;
    var points_len: usize = 0;
    var x_labels_len: usize = 0;
    for (layout.nodes, 0..) |node, node_index| {
        // The copy loop charges the RECONCILED node (runtime editor text
        // can outgrow the source's) — mirror the same transform.
        const widget = canvasWidgetLayoutNodeWithTextReconcileState(node, layout, node_index, previous_texts).widget;
        text_len += widget.text.len + widget.icon.len + widget.command.len + widget.semantics.label.len;
        span_len += widget.spans.len;
        for (widget.spans) |span| {
            if (subsliceOffset(widget.text, span.text) == null) text_len += span.text.len;
            text_len += span.link.len;
        }
        menu_len += widget.context_menu.len;
        for (widget.context_menu) |item| text_len += item.label.len;
        series_len += widget.chart.series.len;
        for (widget.chart.series) |series| {
            text_len += series.label.len;
            points_len += series.values.len + series.low.len;
        }
        x_labels_len += widget.chart.x_labels.len;
        for (widget.chart.x_labels) |label| text_len += label.len;
    }
    if (span_len > canvas_limits.max_canvas_widget_spans_per_view) return error.WidgetSpanLimitReached;
    if (menu_len > canvas_limits.max_canvas_widget_context_menu_items_per_view) return error.WidgetContextMenuLimitReached;
    if (series_len > canvas_limits.max_canvas_widget_chart_series_per_view) return error.WidgetChartSeriesLimitReached;
    if (points_len > canvas_limits.max_canvas_widget_chart_points_per_view) return error.WidgetChartPointsLimitReached;
    if (x_labels_len > canvas_limits.max_canvas_widget_chart_x_labels_per_view) return error.WidgetChartLabelsLimitReached;
    if (text_len > max_canvas_widget_text_bytes_per_view) return error.WidgetTextTooLarge;
}

pub fn RuntimeViewCanvasWidgetTree(comptime RuntimeView: type) type {
    return struct {
        pub fn widgetLayoutTree(self: *const RuntimeView) canvas.WidgetLayoutTree {
            return .{ .nodes = self.widget_layout_nodes[0..self.widget_layout_node_count] };
        }

        pub fn widgetSemantics(self: *const RuntimeView) []const canvas.WidgetSemanticsNode {
            return self.widget_semantics_nodes[0..self.widget_semantics_node_count];
        }

        pub fn widgetSourceTextEntries(self: *const RuntimeView) []const CanvasWidgetSourceTextEntry {
            return self.widget_source_text_entries[0..self.widget_source_text_count];
        }

        pub fn widgetSourceScrollEntries(self: *const RuntimeView) []const canvas_widget_runtime.CanvasWidgetSourceScrollEntry {
            return self.widget_source_scroll_entries[0..self.widget_source_scroll_count];
        }

        pub fn copyCanvasWidgetSourceScroll(self: *RuntimeView, layout: canvas.WidgetLayoutTree) void {
            const entries = canvas_widget_runtime.collectCanvasWidgetScrollOffsetEntries(
                layout.nodes,
                &self.widget_source_scroll_entries,
            );
            self.widget_source_scroll_count = entries.len;
        }

        /// Resolve the SOURCE layout's autofocus request (edge-triggered)
        /// and refresh the tracked set: returns the first widget in tree
        /// order whose `autofocus` flag is set now but was not on the
        /// previous rebuild — newly mounted editors and freshly flipped
        /// flags focus, level-held flags never re-steal.
        pub fn canvasWidgetAutofocusTarget(self: *RuntimeView, layout: canvas.WidgetLayoutTree) ?canvas.ObjectId {
            var target: ?canvas.ObjectId = null;
            var new_ids: [canvas_limits.max_canvas_widget_autofocus_per_view]canvas.ObjectId = undefined;
            var new_count: usize = 0;
            for (layout.nodes) |node| {
                if (!node.widget.autofocus or node.widget.id == 0) continue;
                if (target == null) {
                    var seen = false;
                    for (self.widget_autofocus_ids[0..self.widget_autofocus_count]) |previous_id| {
                        if (previous_id == node.widget.id) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) target = node.widget.id;
                }
                if (new_count < new_ids.len) {
                    new_ids[new_count] = node.widget.id;
                    new_count += 1;
                }
            }
            @memcpy(self.widget_autofocus_ids[0..new_count], new_ids[0..new_count]);
            self.widget_autofocus_count = new_count;
            return target;
        }

        pub fn widgetSourceControlEntries(self: *const RuntimeView) []const canvas_widget_runtime.CanvasWidgetSourceControlEntry {
            return self.widget_source_control_entries[0..self.widget_source_control_count];
        }

        pub fn copyCanvasWidgetSourceControls(self: *RuntimeView, layout: canvas.WidgetLayoutTree) void {
            const entries = canvas_widget_runtime.collectCanvasWidgetSourceControlEntries(
                layout.nodes,
                &self.widget_source_control_entries,
            );
            self.widget_source_control_count = entries.len;
        }

        pub fn copyCanvasWidgetSourceText(self: *RuntimeView, layout: canvas.WidgetLayoutTree) anyerror!void {
            var entries: [max_canvas_widget_source_text_entries_per_view]CanvasWidgetSourceTextEntry = undefined;
            var entry_count: usize = 0;

            for (layout.nodes) |node| {
                if (node.widget.id == 0 or !canvasWidgetEditableTextKind(node.widget.kind)) continue;
                if (entry_count >= entries.len) break;
                const source_text = canvasWidgetSourceTextFingerprint(node.widget.text);
                entries[entry_count] = .{
                    .id = node.widget.id,
                    .kind = node.widget.kind,
                    .text_len = source_text.len,
                    .text_hash = source_text.hash,
                };
                entry_count += 1;
            }

            @memcpy(self.widget_source_text_entries[0..entry_count], entries[0..entry_count]);
            self.widget_source_text_count = entry_count;
        }

        /// `scratch` is reconcile scratch too large for the stack at the
        /// 1024-node budget; callers pass the Runtime's shared
        /// `canvas_widget_copy_scratch` (the event loop is single-threaded).
        pub fn copyWidgetLayoutTree(self: *RuntimeView, layout: canvas.WidgetLayoutTree, scratch: *canvas_widget_runtime.CanvasWidgetCopyScratch) anyerror!void {
            if (layout.nodes.len > self.widget_layout_nodes.len) return error.WidgetNodeLimitReached;
            var anchored_count: usize = 0;
            for (layout.nodes) |node| {
                if (canvas.widgetIsAnchored(node.widget)) anchored_count += 1;
            }
            if (anchored_count > canvas_limits.max_canvas_widget_anchored_per_view) return error.WidgetAnchoredSurfaceLimitReached;
            if (layout.nodes.len > 0 and layout.nodes.ptr == self.widget_layout_nodes[0..].ptr) {
                self.widget_revision += 1;
                return;
            }

            const source_semantics = try layout.collectSemantics(&scratch.source_semantics);
            const previous_control_states = collectCanvasWidgetControlReconcileEntries(
                self.widgetLayoutTree().nodes,
                &scratch.control_entries,
            );
            // A live pointer press is VIEW state (`canvas_widget_pressed_id`),
            // never stamped on retained widgets: mark the pressed control's
            // entry so the control reconcile can protect a mid-gesture drag
            // (a slider mid-drag keeps its thumb through a source move).
            if (self.canvas_widget_pressed_id != 0) {
                for (scratch.control_entries[0..previous_control_states.len]) |*entry| {
                    if (entry.id == self.canvas_widget_pressed_id) entry.state.pressed = true;
                }
            }
            const previous_scroll_states = collectCanvasWidgetScrollReconcileEntries(
                self.widgetLayoutTree().nodes,
                self.widget_scroll_states[0..self.widget_layout_node_count],
                &scratch.scroll_entries,
            );
            var previous_text_len: usize = 0;
            const previous_text_states = try collectCanvasWidgetTextReconcileEntries(
                self.widgetLayoutTree().nodes,
                self.widgetSourceTextEntries(),
                &scratch.text_entries,
                &scratch.text_bytes,
                &previous_text_len,
            );

            // Per-pass probe-table indices over the collected entry lists
            // (shared per-thread scratch; see the reconcile-id-index note
            // in canvas_widget_runtime.zig). Lookups return exactly what
            // the linear scans returned; only the search cost changes.
            const index_scratch = canvas_widget_runtime.canvas_widget_reconcile_index_scratch.get();
            index_scratch.controls.build(previous_control_states);
            index_scratch.source_controls.build(self.widgetSourceControlEntries());
            index_scratch.texts.build(previous_text_states);
            index_scratch.semantics.build(source_semantics);

            // Validate every retained-pool budget BEFORE the pools reset:
            // the copy loop below is destructive, and a mid-loop overflow
            // used to leave a TORN retained tree on screen (a partial
            // node count, interaction state resolved against half a
            // view) until the next successful dispatch. Charges mirror
            // the loop exactly — including runtime-reconciled editor
            // text, which can be longer than the source's. Same teaching
            // errors as the copy path, which stays as the structural
            // backstop; the display-list side already follows this
            // pattern (`copyCanvasDisplayList` counts before it copies).
            try validateWidgetLayoutPoolBudgets(layout, &index_scratch.texts);

            // Keyboard-focus return for unmounting anchored surfaces:
            // when the focus sits INSIDE an anchored menu that this
            // rebuild removes (the commit-closes-the-picker flow), the
            // focus returns to the surface's trigger instead of dropping
            // to nothing. Captured against the OLD tree before the pools
            // reset.
            var focus_return_id: canvas.ObjectId = 0;
            if (self.canvas_widget_focused_id != 0) {
                if (self.canvasWidgetNodeIndexById(self.canvas_widget_focused_id)) |focused_index| {
                    var current: ?usize = self.widget_layout_nodes[focused_index].parent_index;
                    while (current) |ancestor_index| {
                        const ancestor = self.widget_layout_nodes[ancestor_index].widget;
                        if (canvas.widgetIsAnchored(ancestor) and canvasWidgetDismissibleSurfaceKind(ancestor.kind)) {
                            focus_return_id = self.canvasWidgetAnchorTriggerFocusId(ancestor_index) orelse 0;
                            break;
                        }
                        current = self.widget_layout_nodes[ancestor_index].parent_index;
                    }
                }
            }

            self.widget_layout_node_count = 0;
            self.widget_semantics_node_count = 0;
            self.widget_text_len = 0;
            self.widget_span_len = 0;
            self.widget_context_menu_len = 0;
            self.widget_chart_series_len = 0;
            self.widget_chart_points_len = 0;
            self.widget_chart_x_labels_len = 0;

            for (layout.nodes, 0..) |node, layout_index| {
                const text_reconciled = canvasWidgetLayoutNodeWithTextReconcileState(node, layout, layout_index, &index_scratch.texts);
                const text_copy = try self.copyWidgetLayoutNode(text_reconciled, &index_scratch.semantics);
                const copy = canvasWidgetLayoutNodeWithControlReconcileState(text_copy, layout, layout_index, &index_scratch.controls, &index_scratch.source_controls);
                self.widget_layout_nodes[self.widget_layout_node_count] = copy;
                self.widget_scroll_states[self.widget_layout_node_count] = canvasWidgetScrollStateForLayoutNode(copy, previous_scroll_states);
                self.widget_layout_node_count += 1;
            }

            clampCanvasWidgetLayoutScrollOffsets(
                self.widget_layout_nodes[0..self.widget_layout_node_count],
                self.widget_scroll_states[0..self.widget_layout_node_count],
            );
            clampCanvasWidgetLayoutTextOffsets(
                self.widget_layout_nodes[0..self.widget_layout_node_count],
                self.widget_tokens,
            );

            // Anchored-tooltip hover intent survives the rebuild the way
            // hover/press ids do: drop state whose tooltip unmounted,
            // then re-stamp runtime-owned visibility BEFORE semantics
            // collect, so the a11y snapshot (and the replay fingerprint
            // riding it) always reflects the intent machine.
            self.pruneCanvasTooltipIntent();
            self.applyCanvasTooltipVisibility();

            const semantics = try self.widgetLayoutTree().collectSemantics(&self.widget_semantics_nodes);
            applyCanvasWidgetSourceScrollSemantics(self.widget_semantics_nodes[0..semantics.len], &index_scratch.semantics);
            self.widget_semantics_node_count = semantics.len;
            if (self.canvas_widget_focused_id != 0 and self.widgetLayoutTree().focusTargetById(self.canvas_widget_focused_id) == null) {
                const return_id = if (focus_return_id != 0 and self.widgetLayoutTree().focusTargetById(focus_return_id) != null) focus_return_id else 0;
                self.canvas_widget_focused_id = return_id;
                self.canvas_widget_focus_visible_id = return_id;
                // The focus-return ring is not a keyboard ARRIVAL:
                // reveals fire only on focus-visible transitions (the
                // dismissal seam's rule), so the returned ring never
                // grants adoption-time tooltip reveals either.
                self.canvas_widget_focus_visible_keyboard = false;
            }
            if (self.canvas_widget_focus_visible_id != 0 and (self.canvas_widget_focus_visible_id != self.canvas_widget_focused_id or self.widgetLayoutTree().focusTargetById(self.canvas_widget_focus_visible_id) == null)) {
                self.canvas_widget_focus_visible_id = 0;
                self.canvas_widget_focus_visible_keyboard = false;
            }
            if (self.canvas_widget_hovered_id != 0 and !canvasWidgetInteractionTargetExists(self.widgetLayoutTree(), self.canvas_widget_hovered_id)) {
                self.canvas_widget_hovered_id = 0;
            }
            // Hover-Msg entries whose widgets this rebuild unmounted owe
            // their leave edge; survivors keep standing (the adoption
            // reconcile re-hit-tests the stored pointer position right
            // after, wherever one exists).
            self.pruneCanvasWidgetHoverMsgChain();
            // The hover point belongs to the hovered widget's detail
            // chrome; without a hovered widget it means nothing.
            if (self.canvas_widget_hovered_id == 0) self.canvas_widget_hover_point = null;
            if (self.canvas_widget_pressed_id != 0 and !canvasWidgetInteractionTargetExists(self.widgetLayoutTree(), self.canvas_widget_pressed_id)) {
                self.canvas_widget_pressed_id = 0;
            }
            self.canvas_widget_cursor = self.canvasWidgetCursorForId(self.canvas_widget_hovered_id);
            self.widget_revision += 1;
        }

        /// Cursor for a retained widget id, mirroring the canvas layer's
        /// `cursorForWidgetHit`: the pointing hand is role-driven (links
        /// only — the native register keeps controls on the arrow), and
        /// everything else resolves through the kind mapping.
        pub fn canvasWidgetCursorForId(self: *const RuntimeView, id: canvas.ObjectId) platform.Cursor {
            const index = self.canvasWidgetNodeIndexById(id) orelse return .arrow;
            const node = self.widget_layout_nodes[index];
            if (node.widget.semantics.role == .link and !node.widget.state.disabled) {
                return platformCursorFromCanvas(.pointing_hand);
            }
            return platformCursorFromCanvas(canvas.cursorForWidgetTarget(node.widget.kind, node.widget.state));
        }

        pub fn canvasWidgetRenderState(self: *const RuntimeView) canvas.WidgetRenderState {
            const focused_id: ?canvas.ObjectId = if (!self.focused or self.canvas_widget_focused_id == 0) null else self.canvas_widget_focused_id;
            return .{
                .focused_id = focused_id,
                .focus_visible_id = if (focused_id) |id| if (self.canvas_widget_focus_visible_id == id) id else null else null,
                .hovered_id = if (self.canvas_widget_hovered_id == 0) null else self.canvas_widget_hovered_id,
                // The STORED pressed id is the raw hit (text drag-selection
                // extends against it); the pressed WASH resolves through
                // the press fall-through so a click anywhere in a
                // composite row lights the row, matching the hover walk.
                .pressed_id = if (self.canvas_widget_pressed_id == 0) null else canvasWidgetPressWashTargetId(self, self.canvas_widget_pressed_id),
                .hover_point = if (self.canvas_widget_hovered_id == 0) null else self.canvas_widget_hover_point,
                // Closing disclosure widgets keep painting their content
                // (clipped to the shrinking frame) only while the
                // disclosure tween names them here.
                .revealing_disclosure_ids = self.canvasWidgetRevealingDisclosureIds(),
            };
        }

        /// The widget the pressed WASH belongs to for a raw pressed id:
        /// the nearest press-claiming widget on the ancestor path (the
        /// same walk presses dispatch through), or the raw id when
        /// nothing on the path claims.
        fn canvasWidgetPressWashTargetId(self: *const RuntimeView, id: canvas.ObjectId) canvas.ObjectId {
            const index = self.canvasWidgetNodeIndexById(id) orelse return id;
            const layout = self.widgetLayoutTree();
            const target_index = canvas.widgetPressTargetIndexFromNode(layout, index) orelse return id;
            return layout.nodes[target_index].widget.id;
        }

        /// Recompute the standing hover-Msg chain from a raw hit — the
        /// pointer and scroll seams call this with the SAME raw hit the
        /// wash resolution consumed, so containment and the wash always
        /// agree on where the pointer stands.
        pub fn setCanvasWidgetHoverMsgChainForHit(self: *RuntimeView, hit: ?canvas.WidgetHit) void {
            const chain = self.widgetLayoutTree().hoverMsgChainForHit(hit, &self.canvas_widget_hover_msg_chain);
            self.canvas_widget_hover_msg_chain_len = chain.len;
        }

        /// Point-blind prune of the standing hover-Msg chain: drop
        /// entries whose widgets left the tree (their leave edge is
        /// due), keep the rest — the wash's exact rebuild rule (an id
        /// survives a rebuild until a re-hit-test says otherwise).
        pub fn pruneCanvasWidgetHoverMsgChain(self: *RuntimeView) void {
            const layout = self.widgetLayoutTree();
            var kept: usize = 0;
            for (self.canvas_widget_hover_msg_chain[0..self.canvas_widget_hover_msg_chain_len]) |id| {
                if (!canvasWidgetInteractionTargetExists(layout, id)) continue;
                self.canvas_widget_hover_msg_chain[kept] = id;
                kept += 1;
            }
            self.canvas_widget_hover_msg_chain_len = kept;
        }

        pub fn reconcileCanvasWidgetRenderStateAfterScroll(self: *RuntimeView, point: ?geometry.PointF) void {
            const layout = self.widgetLayoutTree();
            if (self.canvas_widget_focused_id != 0 and layout.focusTargetById(self.canvas_widget_focused_id) == null) {
                self.canvas_widget_focused_id = 0;
                self.canvas_widget_focus_visible_id = 0;
                self.canvas_widget_focus_visible_keyboard = false;
            }
            if (self.canvas_widget_focus_visible_id != 0 and (self.canvas_widget_focus_visible_id != self.canvas_widget_focused_id or layout.focusTargetById(self.canvas_widget_focus_visible_id) == null)) {
                self.canvas_widget_focus_visible_id = 0;
                self.canvas_widget_focus_visible_keyboard = false;
            }

            var next_hovered_id = self.canvas_widget_hovered_id;
            var next_cursor = self.canvas_widget_cursor;

            if (point) |value| {
                // Same hover-target walk as live pointer moves: the wash
                // and cursor a scroll settles on must match what a real
                // move to this point would produce. The hover-Msg chain
                // re-resolves from the same raw hit — content sliding
                // out from under a stationary pointer fires the same
                // leave a real move off it would — but only while a
                // hover-capable pointer is live: on touch, the stored
                // position is a lifted finger's last contact, and a
                // fling must never hover what slides under it.
                const raw = layout.hitTestWithTokens(value, self.widget_tokens);
                const hit = layout.hoverTargetForHit(raw);
                next_hovered_id = if (hit) |target| target.id else 0;
                next_cursor = platformCursorFromCanvas(layout.cursorForHit(hit));
                if (self.canvas_widget_hover_pointer_live) {
                    // The chain re-hits at the PROVEN pointer's own
                    // anchor, never the passed point: the passed point
                    // follows `canvas_last_pointer_position`, which any
                    // device updates — a touch drag must not steer the
                    // mouse's containment. On single-pointer hosts the
                    // two are the same position.
                    self.setCanvasWidgetHoverMsgChainForHit(layout.hitTestWithTokens(self.canvas_widget_hover_pointer_position, self.widget_tokens));
                } else {
                    self.pruneCanvasWidgetHoverMsgChain();
                }
            } else {
                if (!canvasWidgetInteractionTargetExists(layout, next_hovered_id)) {
                    next_hovered_id = 0;
                    next_cursor = .arrow;
                }
                // No trustworthy position: like the wash, entries
                // survive by id until their widgets leave the tree.
                self.pruneCanvasWidgetHoverMsgChain();
            }

            var next_pressed_id = self.canvas_widget_pressed_id;
            if (!canvasWidgetInteractionTargetExists(layout, next_pressed_id)) {
                next_pressed_id = 0;
            }

            self.canvas_widget_hovered_id = next_hovered_id;
            self.canvas_widget_pressed_id = next_pressed_id;
            self.canvas_widget_cursor = next_cursor;
        }

        /// Escape's dismissal resolution: the nearest dismissible surface
        /// up the focused widget's chain when something is focused, and
        /// otherwise — or when the chain finds none — the topmost MOUNTED
        /// anchored surface in the view. The fallback is what makes
        /// surfaces opened from NON-focusable triggers dismissible: a
        /// text-crumb trigger takes no focus on click, so nothing is
        /// focused while its menu floats, and the focus-rooted walk alone
        /// would leave Escape dead. A focused editable with live IME
        /// composition always wins: Escape cancels the composition and
        /// never dismisses a surface, not even through the fallback.
        /// With SEVERAL surfaces anchored on one stack (the select
        /// trigger's focus-shown tooltip floating over its open menu),
        /// each Escape peels exactly one, topmost (last-mounted) first —
        /// the tooltip goes, then the menu.
        pub fn dismissCanvasWidgetSurfaceFromEscape(self: *RuntimeView, focused_id: canvas.ObjectId) anyerror!?CanvasWidgetSurfaceDismissal {
            if (focused_id != 0) {
                if (self.canvasWidgetNodeIndexById(focused_id)) |focused_index| {
                    const focused_widget = self.widget_layout_nodes[focused_index].widget;
                    if (canvasWidgetEditableTextKind(focused_widget.kind) and focused_widget.text_composition != null) return null;
                    if (try self.dismissCanvasWidgetSurfaceForTargetIndex(focused_index)) |dismissal| return dismissal;
                }
            }
            const surface_index = self.canvasWidgetTopmostAnchoredDismissibleIndex() orelse return null;
            return self.dismissCanvasWidgetSurfaceAtIndex(surface_index);
        }

        /// Focus-departure dismissal (Tab while the keyboard sits inside
        /// an open menu — or on the trigger that owns one): a menu is a
        /// transient choice, so moving the keyboard on closes it WITHOUT
        /// committing, exactly like a click outside. Scoped to menu
        /// surfaces only: Tab through a persistent popover's form fields
        /// must not tear the popover down. The lookup scans FOR menu
        /// kinds rather than kind-checking whatever floats topmost — a
        /// trigger can anchor a tooltip beside its menu, and the
        /// focus-visible tooltip shadowing the open menu left Tab unable
        /// to close it.
        pub fn dismissCanvasWidgetMenuSurfaceForFocusDeparture(self: *RuntimeView, focused_id: canvas.ObjectId) anyerror!?CanvasWidgetSurfaceDismissal {
            const focused_index = self.canvasWidgetNodeIndexById(focused_id) orelse return null;
            const surface_index = canvasWidgetSurfaceIndexForTargetInScope(self, focused_index, .menu) orelse return null;
            return self.dismissCanvasWidgetSurfaceAtIndex(surface_index);
        }

        pub fn dismissCanvasWidgetSurfaceForTarget(self: *RuntimeView, target_id: canvas.ObjectId) anyerror!?CanvasWidgetSurfaceDismissal {
            const target_index = self.canvasWidgetNodeIndexById(target_id) orelse return null;
            return self.dismissCanvasWidgetSurfaceForTargetIndex(target_index);
        }

        pub fn dismissCanvasWidgetSurfaceForTargetIndex(self: *RuntimeView, target_index: usize) anyerror!?CanvasWidgetSurfaceDismissal {
            const surface_index = self.canvasWidgetDismissibleSurfaceIndexForTarget(target_index) orelse return null;
            return self.dismissCanvasWidgetSurfaceAtIndex(surface_index);
        }

        /// Outside-click light dismissal targets INTERACTIVE surfaces
        /// only. A tooltip's whole lifecycle already belongs to the
        /// intent machine's own causes on any outside down — hover
        /// leave, focus moving with the click, the press itself — so
        /// letting the topmost tooltip absorb this gesture would both
        /// double-cover those and leave the menu beneath it floating
        /// after the user clicked away.
        pub fn dismissCanvasWidgetSurfaceForPointerOutsideFocusedTarget(self: *RuntimeView, focused_id: canvas.ObjectId, route: []const canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetSurfaceDismissal {
            const focused_index = self.canvasWidgetNodeIndexById(focused_id) orelse return null;
            const surface_index = canvasWidgetSurfaceIndexForTargetInScope(self, focused_index, .interactive) orelse return null;
            if (self.canvasWidgetRouteDescendsFromIndex(route, surface_index)) return null;
            // Clicking the ANCHOR region of an anchored surface (the
            // trigger, or the stack that wraps trigger + surface) is the
            // trigger's own toggle gesture: skip the outside-dismiss so a
            // click on the open picker's trigger dispatches exactly one
            // Msg (the toggle), never dismiss-then-reopen.
            if (canvas.widgetIsAnchored(self.widget_layout_nodes[surface_index].widget)) {
                if (self.widget_layout_nodes[surface_index].parent_index) |anchor_index| {
                    if (self.canvasWidgetRouteDescendsFromIndex(route, anchor_index)) return null;
                }
            }
            return self.dismissCanvasWidgetSurfaceAtIndex(surface_index);
        }

        pub fn dismissCanvasWidgetSurfaceAtIndex(self: *RuntimeView, surface_index: usize) anyerror!?CanvasWidgetSurfaceDismissal {
            if (surface_index >= self.widget_layout_node_count) return null;
            const surface = self.widget_layout_nodes[surface_index].widget;
            if (surface.semantics.hidden) return null;
            const dirty = self.canvasWidgetDirtyBounds(surface_index, surface.frame) orelse surface.frame;
            self.widget_layout_nodes[surface_index].widget.semantics.hidden = true;
            // A dismissed anchored tooltip leaves the intent machine too,
            // or the next visibility stamp would undo the dismissal. No
            // warm window: Escape is a deliberate dismissal, not the
            // pointer moving on to the next trigger.
            if (surface.kind == .tooltip) {
                if (self.canvas_tooltip_shown_id == surface.id) {
                    // Covers the focus-shown path too: Escape on the
                    // focused trigger clears the reason flag with the
                    // slot, and focus (still on the trigger) does not
                    // re-reveal — reveals fire only on focus-visible
                    // TRANSITIONS, so tabbing away and back re-earns it.
                    // The one non-transition reveal — the adoption
                    // binding-reconcile, which honors a STANDING
                    // keyboard ring when a rebuild swaps the tooltip it
                    // owns — is blocked by consuming that standing
                    // intent here: when the ring rests on the dismissed
                    // tooltip's owner, the dismissal spends
                    // `canvas_widget_focus_visible_keyboard` (its only
                    // readers are the tooltip reveal gates; the ring
                    // itself renders from `canvas_widget_focus_visible_id`
                    // and stays painted), so a rebuild that rekeys the
                    // tooltip cannot resurrect it one frame after
                    // Escape. Same design as the keyboard-activation
                    // dismissal seam in canvas_widget_events.zig.
                    if (self.canvas_widget_focus_visible_id != 0 and
                        self.canvas_widget_focus_visible_id == self.canvas_tooltip_shown_owner_id)
                    {
                        self.canvas_widget_focus_visible_keyboard = false;
                    }
                    self.canvas_tooltip_shown_id = 0;
                    self.canvas_tooltip_shown_owner_id = 0;
                    self.canvas_tooltip_transit_deadline_ns = 0;
                    self.canvas_tooltip_shown_from_focus = false;
                }
                if (self.canvas_tooltip_armed_id == surface.id) {
                    self.canvas_tooltip_armed_id = 0;
                    self.canvas_tooltip_armed_owner_id = 0;
                    self.canvas_tooltip_deadline_ns = 0;
                }
            }
            if (self.canvasWidgetIdDescendsFromIndex(self.canvas_widget_focused_id, surface_index)) {
                // A dismissal that swallows the focus returns it to the
                // surface's own trigger when the surface is anchored (the
                // Escape-closes-the-picker flow keeps the keyboard on the
                // select), and clears it otherwise.
                const return_id = self.canvasWidgetAnchorTriggerFocusId(surface_index) orelse 0;
                self.canvas_widget_focused_id = return_id;
                self.canvas_widget_focus_visible_id = return_id;
                // Same rule as the rebuild's focus return: a returned
                // ring is not a keyboard arrival, so it earns no
                // reveal — here or at a later layout adoption.
                self.canvas_widget_focus_visible_keyboard = false;
            }
            if (self.canvasWidgetIdDescendsFromIndex(self.canvas_widget_focus_visible_id, surface_index)) {
                self.canvas_widget_focus_visible_id = 0;
                self.canvas_widget_focus_visible_keyboard = false;
            }
            if (self.canvasWidgetIdDescendsFromIndex(self.canvas_widget_hovered_id, surface_index)) {
                self.canvas_widget_hovered_id = 0;
                self.canvas_widget_cursor = .arrow;
            }
            if (self.canvasWidgetIdDescendsFromIndex(self.canvas_widget_pressed_id, surface_index)) self.canvas_widget_pressed_id = 0;
            // Hover-Msg listeners inside the dismissed surface owe their
            // leave edge — the surface is gone from under the pointer;
            // listeners outside it keep standing (the wash rule).
            {
                var kept: usize = 0;
                for (self.canvas_widget_hover_msg_chain[0..self.canvas_widget_hover_msg_chain_len]) |id| {
                    if (self.canvasWidgetIdDescendsFromIndex(id, surface_index)) continue;
                    self.canvas_widget_hover_msg_chain[kept] = id;
                    kept += 1;
                }
                self.canvas_widget_hover_msg_chain_len = kept;
            }

            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return .{ .id = surface.id, .dirty = dirty };
        }

        /// Which anchored dismissible surfaces a lookup means to see. A
        /// widget stack can anchor SEVERAL surfaces at once (a select
        /// trigger with both its dropdown-menu and a tooltip), so every
        /// consumer names the population it is really after — grabbing
        /// "the anchored child" and kind-checking the winner let a
        /// focus-visible tooltip shadow the open menu mounted before it.
        pub const CanvasWidgetAnchoredSurfaceScope = enum {
            /// Every dismissible surface, tooltips included. Escape and
            /// the automation/accessibility dismiss actions peel
            /// whatever floats TOPMOST, one surface per gesture.
            any,
            /// Surfaces that can hold interaction and keyboard focus —
            /// everything but tooltips, which are hover chrome the
            /// intent machine owns: outside-click dismissal and focus
            /// scoping.
            interactive,
            /// Menu surfaces only (`menu_surface`/`dropdown_menu`): the
            /// open-select keymap and Tab's focus-departure close.
            menu,
        };

        fn canvasWidgetAnchoredSurfaceKindInScope(kind: canvas.WidgetKind, comptime scope: CanvasWidgetAnchoredSurfaceScope) bool {
            if (!canvasWidgetDismissibleSurfaceKind(kind)) return false;
            return switch (scope) {
                .any => true,
                .interactive => kind != .tooltip,
                .menu => kind == .menu_surface or kind == .dropdown_menu,
            };
        }

        pub fn canvasWidgetDismissibleSurfaceIndexForTarget(self: *const RuntimeView, target_index: usize) ?usize {
            return canvasWidgetSurfaceIndexForTargetInScope(self, target_index, .any);
        }

        /// The nearest in-scope surface up the target's chain: the first
        /// visible dismissible ancestor, or an in-scope anchored surface
        /// HANGING OFF an ancestor (the ancestor is its anchor) — Escape
        /// on the focused trigger, or on the stack wrapping trigger +
        /// surface, closes its own menu even though the surface is a
        /// descendant, not an ancestor, of the focus. A visible ancestor
        /// surface OUTSIDE the scope shields rather than defers: the
        /// keyboard living in a persistent popover must not reach past
        /// it to a menu further out.
        fn canvasWidgetSurfaceIndexForTargetInScope(self: *const RuntimeView, target_index: usize, comptime scope: CanvasWidgetAnchoredSurfaceScope) ?usize {
            if (target_index >= self.widget_layout_node_count) return null;
            var current: ?usize = target_index;
            while (current) |index| {
                if (index >= self.widget_layout_node_count) return null;
                const widget = self.widget_layout_nodes[index].widget;
                if (canvasWidgetDismissibleSurfaceKind(widget.kind) and !widget.semantics.hidden) {
                    return if (canvasWidgetAnchoredSurfaceKindInScope(widget.kind, scope)) index else null;
                }
                if (canvasWidgetAnchoredChildIndexInScope(self, index, scope)) |surface_index| return surface_index;
                current = self.widget_layout_nodes[index].parent_index;
            }
            return null;
        }

        /// The topmost (last-mounted) visible anchored dismissible surface
        /// whose anchor is `anchor_index`, or null.
        pub fn canvasWidgetAnchoredDismissibleChildIndex(self: *const RuntimeView, anchor_index: usize) ?usize {
            return canvasWidgetAnchoredChildIndexInScope(self, anchor_index, .any);
        }

        /// The topmost visible anchored child of `anchor_index` whose
        /// kind is IN SCOPE — the scope filters DURING the scan, so an
        /// out-of-scope sibling mounted later (the tooltip above the
        /// menu) never masks the surface the caller asked for.
        fn canvasWidgetAnchoredChildIndexInScope(self: *const RuntimeView, anchor_index: usize, comptime scope: CanvasWidgetAnchoredSurfaceScope) ?usize {
            var found: ?usize = null;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                if (node.parent_index != anchor_index) continue;
                if (!canvas.widgetIsAnchored(node.widget)) continue;
                if (!canvasWidgetAnchoredSurfaceKindInScope(node.widget.kind, scope)) continue;
                if (node.widget.semantics.hidden) continue;
                found = index;
            }
            return found;
        }

        /// The anchored menu surface a trigger owns: the topmost visible
        /// anchored `menu_surface`/`dropdown_menu` hanging off the trigger
        /// itself or off its parent — the stack wrapping trigger + surface
        /// in the composed select/combobox pattern.
        pub fn canvasWidgetOwnedMenuSurfaceIndex(self: *const RuntimeView, trigger_index: usize) ?usize {
            if (trigger_index >= self.widget_layout_node_count) return null;
            if (canvasWidgetAnchoredMenuChildIndex(self, trigger_index)) |surface_index| return surface_index;
            const parent_index = self.widget_layout_nodes[trigger_index].parent_index orelse return null;
            const surface_index = canvasWidgetAnchoredMenuChildIndex(self, parent_index) orelse return null;
            return if (surface_index == trigger_index) null else surface_index;
        }

        fn canvasWidgetAnchoredMenuChildIndex(self: *const RuntimeView, anchor_index: usize) ?usize {
            return canvasWidgetAnchoredChildIndexInScope(self, anchor_index, .menu);
        }

        /// The anchored tooltip a trigger owns: the last-mounted anchored
        /// `.tooltip` child of the trigger itself or of its parent — the
        /// stack wrapping trigger + tooltip, mirroring the anchored-menu
        /// ownership shape. Deliberately IGNORES the hidden flag: the
        /// runtime itself stamps non-shown anchored tooltips hidden, and
        /// arming must find them to show them.
        pub fn canvasWidgetOwnedTooltipIndex(self: *const RuntimeView, trigger_index: usize) ?usize {
            return canvasWidgetOwnedTooltipIndexInNodes(self.widget_layout_nodes[0..self.widget_layout_node_count], trigger_index);
        }

        /// The ID of the anchored tooltip `owner_id` owns in the
        /// CURRENT retained tree, or 0 (no such owner / no owned
        /// tooltip). The layout-adoption reconcile compares this value
        /// across a rebuild — captured against the outgoing tree in
        /// `setCanvasWidgetLayout`, re-read against the adopted one —
        /// to see a binding that changed beneath a STABLE owner: a
        /// tooltip mounted, replaced, rekeyed, or reparented under a
        /// trigger whose own ID survived produces no hover or focus
        /// delta, so only this comparison can arm (or reveal) it.
        pub fn canvasWidgetOwnedTooltipIdForOwner(self: *const RuntimeView, owner_id: canvas.ObjectId) canvas.ObjectId {
            if (owner_id == 0) return 0;
            const owner_index = self.canvasWidgetNodeIndexById(owner_id) orelse return 0;
            const tooltip_index = self.canvasWidgetOwnedTooltipIndex(owner_index) orelse return 0;
            return self.widget_layout_nodes[tooltip_index].widget.id;
        }

        /// Stamp hover-intent visibility onto every ANCHORED tooltip
        /// node: hidden unless it is the intent machine's shown tooltip.
        /// Anchored tooltips are runtime-owned chrome, so the stamp
        /// overrides authored visibility; static (non-anchored) tooltips
        /// are never touched. Runs at tree adoption (each rebuild) and
        /// after every intent transition.
        pub fn applyCanvasTooltipVisibility(self: *RuntimeView) void {
            self.applyCanvasTooltipVisibilityToNodes(self.widget_layout_nodes[0..self.widget_layout_node_count]);
        }

        /// The same stamp over an arbitrary node slice, against the
        /// view's LIVE shown register.
        pub fn applyCanvasTooltipVisibilityToNodes(self: *const RuntimeView, nodes: []canvas.WidgetLayoutNode) void {
            applyCanvasTooltipVisibilityToNodesForShownId(self, nodes, self.canvas_tooltip_shown_id);
        }

        /// The stamp against an EXPLICIT shown id. The rebuild path
        /// normalizes the RECONCILED scratch tree with it BEFORE diffing
        /// against the retained tree (see `setCanvasWidgetLayout`),
        /// passing the PROSPECTIVE prune verdict from
        /// `canvasTooltipShownIdSurvivingLayout` rather than mutating
        /// the live registers first: the retained side carries the
        /// intent machine's hidden stamps while the source declares
        /// authored visibility, so diffing them un-normalized reported
        /// the runtime's own stamp as a spurious visibility
        /// invalidation on every rebuild that contained a hidden
        /// anchored tooltip — and mutating the registers before the
        /// fallible adoption steps left a FAILED adoption with the old
        /// tree stamped visible and cleared registers (an unhideable
        /// tooltip).
        pub fn applyCanvasTooltipVisibilityToNodesForShownId(self: *const RuntimeView, nodes: []canvas.WidgetLayoutNode, shown_id: canvas.ObjectId) void {
            _ = self;
            for (nodes) |*node| {
                if (node.widget.kind != .tooltip) continue;
                if (!canvas.widgetIsAnchored(node.widget)) continue;
                node.widget.semantics.hidden = node.widget.id == 0 or node.widget.id != shown_id;
            }
        }

        /// Drop intent state whose tooltip OR owning trigger left the
        /// tree on a rebuild — the interaction-id pruning policy
        /// hovered/pressed ids follow, applied to both ends of the
        /// tooltip binding. The tooltip node surviving is not enough:
        /// a trigger that vanished, was rekeyed (a new id is a new
        /// widget), re-parented away from its tooltip, or disabled
        /// (disabled widgets leave both hover and focus routing, so
        /// nothing could ever hide the tooltip again) invalidates the
        /// slot, and the pruned slot re-stamps hidden through the
        /// `applyCanvasTooltipVisibility` call that follows adoption.
        /// The warm window survives rebuilds that keep the bindings
        /// alive (warmth belongs to the pointer, not to any one
        /// widget), but a pruned binding closes it: instant re-shows
        /// earned against widgets the rebuild replaced are not earned
        /// at all.
        pub fn pruneCanvasTooltipIntent(self: *RuntimeView) void {
            self.pruneCanvasTooltipIntentForLayout(self.widgetLayoutTree());
        }

        /// The same prune against an arbitrary layout. Runs inside
        /// `copyWidgetLayoutTree` against the freshly retained tree —
        /// AFTER every fallible adoption step has succeeded, which is
        /// what keeps the registers transactional: the rebuild path's
        /// pre-diff stamp reads only the VERDICT
        /// (`canvasTooltipShownIdSurvivingLayout`) so a failed adoption
        /// leaves both the old tree and the registers that can hide its
        /// tooltip intact.
        pub fn pruneCanvasTooltipIntentForLayout(self: *RuntimeView, layout: canvas.WidgetLayoutTree) void {
            if (self.canvas_tooltip_armed_id != 0 and !canvasTooltipIntentBindingAlive(layout, self.canvas_tooltip_armed_id, self.canvas_tooltip_armed_owner_id, false)) {
                self.canvas_tooltip_armed_id = 0;
                self.canvas_tooltip_armed_owner_id = 0;
                self.canvas_tooltip_deadline_ns = 0;
                self.canvas_tooltip_warm_until_ns = 0;
            }
            if (self.canvas_tooltip_shown_id != 0 and !canvasTooltipIntentBindingAlive(layout, self.canvas_tooltip_shown_id, self.canvas_tooltip_shown_owner_id, self.canvas_tooltip_shown_from_focus)) {
                self.canvas_tooltip_shown_id = 0;
                self.canvas_tooltip_shown_owner_id = 0;
                self.canvas_tooltip_shown_from_focus = false;
                self.canvas_tooltip_warm_until_ns = 0;
                self.canvas_tooltip_transit_deadline_ns = 0;
            }
        }

        /// The shown-tooltip prune VERDICT against a prospective
        /// layout, WITHOUT the register mutation: the shown id that
        /// would survive adopting `layout`, or 0 when the rebuild kills
        /// the binding. `setCanvasWidgetLayout` stamps the reconciled
        /// scratch tree with this ahead of the diff (so the diff
        /// reports the hide a binding-breaking rebuild really causes,
        /// and an unchanged rebuild diffs clean) while the live
        /// registers stay untouched until the fallible adoption steps —
        /// the diff itself and the retained-pool validation/copy —
        /// succeed; `copyWidgetLayoutTree`'s own prune then applies the
        /// same verdict for real. A failed adoption therefore leaves
        /// the OLD tree with the registers that own its stamps: the
        /// tooltip that is still painted is still hideable.
        pub fn canvasTooltipShownIdSurvivingLayout(self: *const RuntimeView, layout: canvas.WidgetLayoutTree) canvas.ObjectId {
            if (self.canvas_tooltip_shown_id == 0) return 0;
            if (!canvasTooltipIntentBindingAlive(layout, self.canvas_tooltip_shown_id, self.canvas_tooltip_shown_owner_id, self.canvas_tooltip_shown_from_focus)) return 0;
            return self.canvas_tooltip_shown_id;
        }

        /// Both ends of a tooltip intent slot are still live: the
        /// tooltip node exists and is anchored, its recorded owner
        /// still exists AND still resolves to this very tooltip
        /// (`canvasWidgetOwnedTooltipIndex`, the inverse of the arming
        /// walk), and the owner remains reachable by the routing that
        /// earned the slot — focus targeting for focus-shown tooltips,
        /// hover/interaction targeting for pointer ones. Both
        /// predicates already reject disabled and hidden widgets, so
        /// "the trigger can no longer be left" implies "the tooltip
        /// must not stay".
        fn canvasTooltipIntentBindingAlive(layout: canvas.WidgetLayoutTree, tooltip_id: canvas.ObjectId, owner_id: canvas.ObjectId, from_focus: bool) bool {
            const tooltip_index = canvasWidgetNodeIndexByIdInNodes(layout.nodes, tooltip_id) orelse return false;
            const tooltip_widget = layout.nodes[tooltip_index].widget;
            if (tooltip_widget.kind != .tooltip or !canvas.widgetIsAnchored(tooltip_widget)) return false;
            const owner_index = canvasWidgetNodeIndexByIdInNodes(layout.nodes, owner_id) orelse return false;
            const owned_index = canvasWidgetOwnedTooltipIndexInNodes(layout.nodes, owner_index) orelse return false;
            if (owned_index != tooltip_index) return false;
            if (from_focus) return layout.focusTargetById(owner_id) != null;
            return canvasWidgetInteractionTargetExists(layout, owner_id);
        }

        /// True while the intent machine needs presented frames to keep
        /// coming: an armed show delay and a running transit grace both
        /// fire only on a frame timestamp, so the frame pump
        /// re-invalidates until they resolve (the render-animation
        /// pump's policy exactly).
        pub fn canvasTooltipIntentArmed(self: *const RuntimeView) bool {
            return self.canvas_tooltip_armed_id != 0 or self.canvas_tooltip_transit_deadline_ns != 0;
        }

        /// Keyboard entry point into an anchored menu surface: the marked
        /// (`selected`) row when the menu has one, otherwise the first
        /// focusable row for an ArrowDown entry or the last for ArrowUp —
        /// the open-select keymap.
        pub fn canvasWidgetMenuSurfaceEntryId(self: *const RuntimeView, surface_index: usize, from_end: bool) ?canvas.ObjectId {
            var first: ?canvas.ObjectId = null;
            var last: ?canvas.ObjectId = null;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, node_index| {
                if (node.widget.kind != .menu_item and node.widget.kind != .list_item) continue;
                if (!self.canvasWidgetNodeIndexDescendsFrom(node_index, surface_index)) continue;
                if (self.widgetLayoutTree().focusTargetById(node.widget.id) == null) continue;
                if (node.widget.state.selected) return node.widget.id;
                if (first == null) first = node.widget.id;
                last = node.widget.id;
            }
            return if (from_end) last else first;
        }

        /// The focusable trigger the dismissed anchored surface returns
        /// keyboard focus to: the surface's anchor when the anchor itself
        /// takes focus, otherwise the anchor's first focusable child
        /// OUTSIDE the surface (the select trigger in the stack pattern).
        pub fn canvasWidgetAnchorTriggerFocusId(self: *const RuntimeView, surface_index: usize) ?canvas.ObjectId {
            if (surface_index >= self.widget_layout_node_count) return null;
            if (!canvas.widgetIsAnchored(self.widget_layout_nodes[surface_index].widget)) return null;
            const anchor_index = self.widget_layout_nodes[surface_index].parent_index orelse return null;
            const anchor_id = self.widget_layout_nodes[anchor_index].widget.id;
            if (self.widgetLayoutTree().focusTargetById(anchor_id) != null) return anchor_id;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, node_index| {
                if (node.parent_index != anchor_index or node_index == surface_index) continue;
                if (self.widgetLayoutTree().focusTargetById(node.widget.id) != null) return node.widget.id;
            }
            return null;
        }

        /// The topmost visible anchored dismissible surface in the whole
        /// view — highest node index, matching both the anchored late
        /// z-pass paint order and reverse-order hit-testing, so "topmost"
        /// here is the surface the user sees on top. Ancestor-hidden
        /// subtrees are skipped: a surface inside a hidden branch is not
        /// on screen and must not swallow Escape.
        pub fn canvasWidgetTopmostAnchoredDismissibleIndex(self: *const RuntimeView) ?usize {
            var found: ?usize = null;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                if (!canvas.widgetIsAnchored(node.widget)) continue;
                if (!canvasWidgetDismissibleSurfaceKind(node.widget.kind)) continue;
                if (canvasWidgetNodeHiddenInTree(self, index)) continue;
                found = index;
            }
            return found;
        }

        /// True when the node or any of its ancestors carries the
        /// semantics `hidden` flag (the dismissal echo, or an app-hidden
        /// branch).
        fn canvasWidgetNodeHiddenInTree(self: *const RuntimeView, node_index: usize) bool {
            var current: ?usize = node_index;
            while (current) |index| {
                if (index >= self.widget_layout_node_count) return true;
                if (self.widget_layout_nodes[index].widget.semantics.hidden) return true;
                current = self.widget_layout_nodes[index].parent_index;
            }
            return false;
        }

        pub fn canvasWidgetRouteDescendsFromIndex(self: *const RuntimeView, route: []const canvas.WidgetEventRouteEntry, ancestor_index: usize) bool {
            for (route) |entry| {
                if (self.canvasWidgetNodeIndexDescendsFrom(entry.node_index, ancestor_index)) return true;
            }
            return false;
        }

        /// Tab cycling scopes to the INTERACTIVE surface around the
        /// focus: a tooltip can never hold a focus target, so scoping to
        /// one (the trigger's visible tooltip shadowing its popover or
        /// menu) would always come up empty and spill the keyboard out
        /// of the trap into the page's global walk.
        pub fn canvasWidgetScopedFocusTarget(self: *const RuntimeView, current_id: canvas.ObjectId, direction: canvas.WidgetFocusDirection) ?canvas.WidgetFocusTarget {
            const current_index = self.canvasWidgetNodeIndexById(current_id) orelse return null;
            const surface_index = canvasWidgetSurfaceIndexForTargetInScope(self, current_index, .interactive) orelse return null;
            return self.canvasWidgetFocusTargetInScope(surface_index, current_index, direction);
        }

        pub fn canvasWidgetFocusTargetInScope(
            self: *const RuntimeView,
            surface_index: usize,
            current_index: usize,
            direction: canvas.WidgetFocusDirection,
        ) ?canvas.WidgetFocusTarget {
            if (surface_index >= self.widget_layout_node_count or current_index >= self.widget_layout_node_count) return null;
            return switch (direction) {
                .forward => self.canvasWidgetForwardFocusTargetInScope(surface_index, current_index),
                .backward => self.canvasWidgetBackwardFocusTargetInScope(surface_index, current_index),
                .left, .right, .up, .down => null,
            };
        }

        pub fn canvasWidgetForwardFocusTargetInScope(self: *const RuntimeView, surface_index: usize, current_index: usize) ?canvas.WidgetFocusTarget {
            var index = current_index + 1;
            while (index < self.widget_layout_node_count) : (index += 1) {
                if (self.canvasWidgetFocusTargetAtScopedIndex(surface_index, index)) |target| return target;
            }
            index = surface_index;
            while (index <= current_index and index < self.widget_layout_node_count) : (index += 1) {
                if (self.canvasWidgetFocusTargetAtScopedIndex(surface_index, index)) |target| return target;
            }
            return null;
        }

        pub fn canvasWidgetBackwardFocusTargetInScope(self: *const RuntimeView, surface_index: usize, current_index: usize) ?canvas.WidgetFocusTarget {
            var index = current_index;
            while (index > 0) {
                index -= 1;
                if (self.canvasWidgetFocusTargetAtScopedIndex(surface_index, index)) |target| return target;
            }
            index = self.widget_layout_node_count;
            while (index > current_index) {
                index -= 1;
                if (self.canvasWidgetFocusTargetAtScopedIndex(surface_index, index)) |target| return target;
            }
            return null;
        }

        pub fn canvasWidgetFocusTargetAtScopedIndex(self: *const RuntimeView, surface_index: usize, index: usize) ?canvas.WidgetFocusTarget {
            if (!self.canvasWidgetNodeIndexDescendsFrom(index, surface_index)) return null;
            const id = self.widget_layout_nodes[index].widget.id;
            return self.widgetLayoutTree().focusTargetById(id);
        }

        pub fn canvasWidgetIdDescendsFromIndex(self: *const RuntimeView, id: canvas.ObjectId, ancestor_index: usize) bool {
            const index = self.canvasWidgetNodeIndexById(id) orelse return false;
            return self.canvasWidgetNodeIndexDescendsFrom(index, ancestor_index);
        }

        pub fn canvasWidgetNodeIndexDescendsFrom(self: *const RuntimeView, node_index: usize, ancestor_index: usize) bool {
            if (node_index >= self.widget_layout_node_count or ancestor_index >= self.widget_layout_node_count) return false;
            var current: ?usize = node_index;
            while (current) |index| {
                if (index >= self.widget_layout_node_count) return false;
                if (index == ancestor_index) return true;
                current = self.widget_layout_nodes[index].parent_index;
            }
            return false;
        }

        pub fn canvasWidgetNodeIndexById(self: *const RuntimeView, id: canvas.ObjectId) ?usize {
            if (id == 0) return null;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                if (node.widget.id == id) return index;
            }
            return null;
        }

        pub fn canvasWidgetCommand(self: *const RuntimeView, id: canvas.ObjectId) ?[]const u8 {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.command.len == 0) return null;
            return widget.command;
        }

        pub fn canvasWidgetStepKey(self: *const RuntimeView, id: canvas.ObjectId, direction: CanvasWidgetStepDirection) []const u8 {
            const index = self.canvasWidgetNodeIndexById(id) orelse return switch (direction) {
                .increment => "arrowright",
                .decrement => "arrowleft",
            };
            return switch (self.widget_layout_nodes[index].widget.kind) {
                .grid, .scroll_view, .list, .data_grid, .table => switch (direction) {
                    .increment => "pagedown",
                    .decrement => "pageup",
                },
                else => switch (direction) {
                    .increment => "arrowright",
                    .decrement => "arrowleft",
                },
            };
        }

        pub fn refreshCanvasWidgetSemantics(self: *RuntimeView) anyerror!void {
            const semantics = try self.widgetLayoutTree().collectSemantics(&self.widget_semantics_nodes);
            self.widget_semantics_node_count = semantics.len;
        }

        pub fn canvasWidgetDirtyBounds(self: *const RuntimeView, node_index: usize, bounds: geometry.RectF) ?geometry.RectF {
            return canvasWidgetLayoutNodeClippedBounds(self.widgetLayoutTree(), node_index, bounds);
        }

        pub fn copyWidgetLayoutNode(self: *RuntimeView, node: canvas.WidgetLayoutNode, source_semantics: *const canvas_widget_runtime.CanvasWidgetSemanticsIndex) anyerror!canvas.WidgetLayoutNode {
            var copy = node;
            if (node.widget.command.len > 0) try validateCommandName(node.widget.command);
            copy.widget.text = try self.copyWidgetText(node.widget.text);
            copy.widget.spans = try self.copyWidgetSpans(node.widget.text, copy.widget.text, node.widget.spans);
            copy.widget.icon = try self.copyWidgetText(node.widget.icon);
            copy.widget.command = try self.copyWidgetText(node.widget.command);
            copy.widget.semantics.label = try self.copyWidgetText(node.widget.semantics.label);
            copy.widget.context_menu = try self.copyWidgetContextMenu(node.widget.context_menu);
            copy.widget.chart = try self.copyWidgetChart(node.widget.chart);
            copy = canvasWidgetLayoutNodeWithSourceSemantics(copy, source_semantics);
            copy.widget.children = &.{};
            return copy;
        }

        /// Retain a widget's declared context-menu items: the retained tree
        /// owns its bytes (same rule as text / command / semantics labels),
        /// so a right-click can never read a label from a reused app buffer.
        pub fn copyWidgetContextMenu(self: *RuntimeView, items: []const canvas.WidgetContextMenuItem) anyerror![]const canvas.WidgetContextMenuItem {
            if (items.len == 0) return &.{};
            const end = self.widget_context_menu_len + items.len;
            if (end > self.widget_context_menu_items.len) return error.WidgetContextMenuLimitReached;
            const start = self.widget_context_menu_len;
            for (items, self.widget_context_menu_items[start..end]) |item, *entry| {
                entry.* = .{
                    .label = try self.copyWidgetText(item.label),
                    .enabled = item.enabled,
                    .separator = item.separator,
                };
            }
            self.widget_context_menu_len = end;
            return self.widget_context_menu_items[start..end];
        }

        /// Retain a `.chart` widget's plot data: series entries, their
        /// point arrays, and their labels all copy into per-view storage
        /// (same ownership rule as text/spans — a repaint can never read
        /// samples from a reused app buffer). Bounded by the per-view
        /// chart budgets in `canvas_limits`.
        pub fn copyWidgetChart(self: *RuntimeView, data: canvas.ChartData) anyerror!canvas.ChartData {
            var copy = data;
            copy.x_labels = try copyWidgetChartLabels(self, data.x_labels);
            if (data.series.len == 0) {
                copy.series = &.{};
                return copy;
            }
            const end = self.widget_chart_series_len + data.series.len;
            if (end > self.widget_chart_series_entries.len) return error.WidgetChartSeriesLimitReached;
            const start = self.widget_chart_series_len;
            self.widget_chart_series_len = end;
            for (data.series, self.widget_chart_series_entries[start..end]) |series, *entry| {
                entry.* = series;
                entry.values = try copyWidgetChartPoints(self, series.values);
                entry.low = try copyWidgetChartPoints(self, series.low);
                entry.label = try self.copyWidgetText(series.label);
            }
            copy.series = self.widget_chart_series_entries[start..end];
            return copy;
        }

        /// Retain a chart's x-axis category labels: the slice entries land
        /// in per-view label storage, the bytes ride the widget-text
        /// budget — same ownership rule as series labels.
        fn copyWidgetChartLabels(self: *RuntimeView, labels: []const []const u8) anyerror![]const []const u8 {
            if (labels.len == 0) return &.{};
            const end = self.widget_chart_x_labels_len + labels.len;
            if (end > self.widget_chart_x_labels.len) return error.WidgetChartLabelsLimitReached;
            const start = self.widget_chart_x_labels_len;
            self.widget_chart_x_labels_len = end;
            for (labels, self.widget_chart_x_labels[start..end]) |label, *entry| {
                entry.* = try self.copyWidgetText(label);
            }
            return self.widget_chart_x_labels[start..end];
        }

        fn copyWidgetChartPoints(self: *RuntimeView, points: []const f32) anyerror![]const f32 {
            if (points.len == 0) return &.{};
            const end = self.widget_chart_points_len + points.len;
            if (end > self.widget_chart_points.len) return error.WidgetChartPointsLimitReached;
            const start = self.widget_chart_points_len;
            @memcpy(self.widget_chart_points[start..end], points);
            self.widget_chart_points_len = end;
            return self.widget_chart_points[start..end];
        }

        pub fn copyWidgetText(self: *RuntimeView, text: []const u8) anyerror![]const u8 {
            const end = self.widget_text_len + text.len;
            if (end > self.widget_text_bytes.len) return error.WidgetTextTooLarge;
            const start = self.widget_text_len;
            @memcpy(self.widget_text_bytes[start..end], text);
            self.widget_text_len = end;
            return self.widget_text_bytes[start..end];
        }

        /// Retain a paragraph's inline spans. Span text that is a subslice
        /// of the paragraph's source text (the `Ui.paragraph` invariant)
        /// rebases onto the already-copied buffer; anything else copies
        /// bytes. Link payloads always copy.
        pub fn copyWidgetSpans(
            self: *RuntimeView,
            source_text: []const u8,
            copied_text: []const u8,
            spans: []const canvas.TextSpan,
        ) anyerror![]const canvas.TextSpan {
            if (spans.len == 0) return &.{};
            const end = self.widget_span_len + spans.len;
            if (end > self.widget_span_entries.len) return error.WidgetSpanLimitReached;
            const start = self.widget_span_len;
            for (spans, self.widget_span_entries[start..end]) |span, *entry| {
                entry.* = span;
                entry.text = if (subsliceOffset(source_text, span.text)) |offset|
                    copied_text[offset .. offset + span.text.len]
                else
                    try self.copyWidgetText(span.text);
                entry.link = try self.copyWidgetText(span.link);
            }
            self.widget_span_len = end;
            return self.widget_span_entries[start..end];
        }
    };
}

/// Node index by widget id over a bare node slice — the retained
/// tree's `canvasWidgetNodeIndexById` generalized so the tooltip
/// binding checks can run against the RECONCILED scratch tree before
/// adoption (the pre-diff visibility normalization) exactly as they
/// run against the retained one.
fn canvasWidgetNodeIndexByIdInNodes(nodes: []const canvas.WidgetLayoutNode, id: canvas.ObjectId) ?usize {
    if (id == 0) return null;
    for (nodes, 0..) |node, index| {
        if (node.widget.id == id) return index;
    }
    return null;
}

/// The anchored tooltip a trigger owns, over a bare node slice: the
/// last-mounted anchored `.tooltip` child of the trigger itself or of
/// its parent — the stack-wraps-trigger-plus-tooltip ownership shape,
/// mirroring the anchored-menu walk. Deliberately IGNORES the hidden
/// flag: the runtime itself stamps non-shown anchored tooltips hidden,
/// and arming must find them to show them.
fn canvasWidgetOwnedTooltipIndexInNodes(nodes: []const canvas.WidgetLayoutNode, trigger_index: usize) ?usize {
    if (trigger_index >= nodes.len) return null;
    if (canvasWidgetAnchoredTooltipChildIndexInNodes(nodes, trigger_index)) |tooltip_index| return tooltip_index;
    const parent_index = nodes[trigger_index].parent_index orelse return null;
    return canvasWidgetAnchoredTooltipChildIndexInNodes(nodes, parent_index);
}

fn canvasWidgetAnchoredTooltipChildIndexInNodes(nodes: []const canvas.WidgetLayoutNode, anchor_index: usize) ?usize {
    var found: ?usize = null;
    for (nodes, 0..) |node, index| {
        if (node.parent_index != anchor_index) continue;
        if (node.widget.kind != .tooltip) continue;
        if (!canvas.widgetIsAnchored(node.widget)) continue;
        found = index;
    }
    return found;
}
