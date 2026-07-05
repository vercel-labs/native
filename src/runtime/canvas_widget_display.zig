const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const validation = @import("validation.zig");
const runtime_api = @import("api.zig");
const runtime_view = @import("view.zig");
const canvas_limits = @import("canvas_limits.zig");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const widget_bridge = @import("widget_bridge.zig");

const CanvasWidgetDisplayListChrome = runtime_api.CanvasWidgetDisplayListChrome;
const CanvasWidgetToggleAnimation = runtime_view.CanvasWidgetToggleAnimation;
const CanvasDisplayListScratch = runtime_view.CanvasDisplayListScratch;
const max_canvas_commands_per_view = canvas_limits.max_canvas_commands_per_view;
const max_canvas_diff_changes_per_view = canvas_limits.max_canvas_diff_changes_per_view;
const validateViewLabel = validation.validateViewLabel;
const canvasRenderAnimationStartNsForView = runtime_view.canvasRenderAnimationStartNsForView;
const canvasWidgetKineticScrollFrameMs = canvas_widget_runtime.canvasWidgetKineticScrollFrameMs;
const canvasWidgetSemanticParentId = widget_bridge.canvasWidgetSemanticParentId;
const platformWidgetAccessibilityRole = widget_bridge.platformWidgetAccessibilityRole;
const platformWidgetAccessibilityTextRange = widget_bridge.platformWidgetAccessibilityTextRange;
const platformWidgetAccessibilityActions = widget_bridge.platformWidgetAccessibilityActions;
const canvasWidgetSelectedState = widget_bridge.canvasWidgetSelectedState;

pub fn RuntimeCanvasWidgetDisplay(comptime Runtime: type) type {
    return struct {
        pub fn emitCanvasWidgetDisplayList(self: *Runtime, window_id: platform.WindowId, label: []const u8, tokens: canvas.DesignTokens) anyerror!platform.ViewInfo {
            return emitCanvasWidgetDisplayListWithChrome(self, window_id, label, tokens, .{});
        }

        pub fn emitCanvasWidgetDisplayListWithStoredTokens(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!platform.ViewInfo {
            return emitCanvasWidgetDisplayListWithStoredTokensAndChrome(self, window_id, label, .{});
        }

        pub fn emitCanvasWidgetDisplayListWithChrome(self: *Runtime, window_id: platform.WindowId, label: []const u8, tokens: canvas.DesignTokens, chrome: CanvasWidgetDisplayListChrome) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
            if (!std.meta.eql(self.views[index].widget_tokens, tokens)) {
                self.views[index].widget_tokens = tokens;
                self.views[index].widget_revision += 1;
            }

            return emitCanvasWidgetDisplayListForViewWithChrome(self, index, chrome);
        }

        pub fn emitCanvasWidgetDisplayListWithStoredTokensAndChrome(self: *Runtime, window_id: platform.WindowId, label: []const u8, chrome: CanvasWidgetDisplayListChrome) anyerror!platform.ViewInfo {
            try validateRuntimeViewParent(self, window_id);
            try validateViewLabel(label);
            const index = runtimeFindViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

            return emitCanvasWidgetDisplayListForViewWithChrome(self, index, chrome);
        }

        pub fn emitCanvasWidgetDisplayListForViewWithChrome(self: *Runtime, index: usize, chrome: CanvasWidgetDisplayListChrome) anyerror!platform.ViewInfo {
            try self.views[index].validateCanvasWidgetDisplayListChrome(chrome);
            const previous_prefix_count = self.views[index].canvas_widget_display_list_prefix_count;
            const previous_suffix_count = self.views[index].canvas_widget_display_list_suffix_count;
            const previous_reserved_count = self.views[index].canvas_widget_display_list_reserved_count;
            const previous_owned = self.views[index].canvas_display_list_widget_owned;
            errdefer {
                self.views[index].canvas_widget_display_list_prefix_count = previous_prefix_count;
                self.views[index].canvas_widget_display_list_suffix_count = previous_suffix_count;
                self.views[index].canvas_widget_display_list_reserved_count = previous_reserved_count;
                self.views[index].canvas_display_list_widget_owned = previous_owned;
            }
            self.views[index].canvas_widget_display_list_prefix_count = chrome.prefix_command_count;
            self.views[index].canvas_widget_display_list_suffix_count = chrome.suffix_command_count;
            self.views[index].canvas_widget_display_list_reserved_count = chrome.reserved_command_count;
            _ = try refreshCanvasWidgetDisplayList(self, index);
            self.views[index].canvas_display_list_widget_owned = true;
            // The declared clear color: every widget app presents its
            // tokens' background (UiApp derives it the same way), so a
            // display-list emission — a rebuild, including a theme change
            // that never presents — keeps offscreen screenshots clearing
            // with LIVE tokens instead of the last presented frame's color.
            self.views[index].canvas_clear_color = self.views[index].widget_tokens.colors.background;
            try publishCanvasWidgetAccessibility(self, index);
            return self.views[index].info();
        }

        pub fn refreshCanvasWidgetDisplayListIfOwned(self: *Runtime, view_index: usize) anyerror!bool {
            return refreshCanvasWidgetDisplayListIfOwnedWithAccessibility(self, view_index, true);
        }

        pub fn refreshCanvasWidgetDisplayListIfOwnedSkippingAccessibility(self: *Runtime, view_index: usize) anyerror!bool {
            return refreshCanvasWidgetDisplayListIfOwnedWithAccessibility(self, view_index, false);
        }

        pub fn refreshCanvasWidgetDisplayListIfOwnedWithAccessibility(self: *Runtime, view_index: usize, publish_accessibility: bool) anyerror!bool {
            if (self.canvas_widget_display_list_refresh_batch_depth > 0) {
                if (view_index >= self.canvas_widget_display_list_refresh_pending.len) return false;
                self.canvas_widget_display_list_refresh_pending[view_index] = true;
                self.canvas_widget_accessibility_publish_pending[view_index] = self.canvas_widget_accessibility_publish_pending[view_index] or publish_accessibility;
                return false;
            }
            return refreshCanvasWidgetDisplayListIfOwnedWithAccessibilityImmediate(self, view_index, publish_accessibility);
        }

        pub fn refreshCanvasWidgetDisplayListIfOwnedWithAccessibilityImmediate(self: *Runtime, view_index: usize, publish_accessibility: bool) anyerror!bool {
            if (view_index >= self.view_count) return false;
            if (self.views[view_index].kind != .gpu_surface) return false;
            if (publish_accessibility) try publishCanvasWidgetAccessibility(self, view_index);
            if (!self.views[view_index].canvas_display_list_widget_owned) return false;
            return refreshCanvasWidgetDisplayList(self, view_index);
        }

        pub fn beginCanvasWidgetDisplayListRefreshBatch(self: *Runtime) void {
            self.canvas_widget_display_list_refresh_batch_depth += 1;
        }

        pub fn cancelCanvasWidgetDisplayListRefreshBatch(self: *Runtime) void {
            if (self.canvas_widget_display_list_refresh_batch_depth == 0) return;
            self.canvas_widget_display_list_refresh_batch_depth -= 1;
            if (self.canvas_widget_display_list_refresh_batch_depth != 0) return;
            for (0..self.canvas_widget_display_list_refresh_pending.len) |index| {
                self.canvas_widget_display_list_refresh_pending[index] = false;
                self.canvas_widget_accessibility_publish_pending[index] = false;
            }
        }

        pub fn endCanvasWidgetDisplayListRefreshBatch(self: *Runtime) anyerror!void {
            if (self.canvas_widget_display_list_refresh_batch_depth == 0) return;
            self.canvas_widget_display_list_refresh_batch_depth -= 1;
            if (self.canvas_widget_display_list_refresh_batch_depth != 0) return;

            const count = @min(self.view_count, self.canvas_widget_display_list_refresh_pending.len);
            for (0..count) |index| {
                if (!self.canvas_widget_display_list_refresh_pending[index]) continue;
                const publish_accessibility = self.canvas_widget_accessibility_publish_pending[index];
                self.canvas_widget_display_list_refresh_pending[index] = false;
                self.canvas_widget_accessibility_publish_pending[index] = false;
                _ = try refreshCanvasWidgetDisplayListIfOwnedWithAccessibilityImmediate(self, index, publish_accessibility);
            }
        }

        pub fn advanceCanvasWidgetKineticScrollForFrame(self: *Runtime, view_index: usize, frame_interval_ns: u64, skip_step: bool) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            if (!self.views[view_index].canvasWidgetKineticScrollActive()) return;

            if (skip_step) {
                try canvas_frame_helpers.RuntimeCanvasFrames(Runtime).requestCanvasFrameForView(self, view_index);
                return;
            }

            _ = try self.stepCanvasWidgetKineticScroll(
                self.views[view_index].window_id,
                self.views[view_index].label,
                canvasWidgetKineticScrollFrameMs(frame_interval_ns),
            );
        }

        pub fn scheduleCanvasWidgetToggleAnimation(self: *Runtime, view_index: usize, animation: CanvasWidgetToggleAnimation) anyerror!void {
            if (view_index >= self.view_count) return;
            if (self.views[view_index].kind != .gpu_surface) return;
            if (animation.id == 0 or animation.travel <= 0) return;

            const motion = self.views[view_index].widget_tokens.motion;
            const duration_ms = motion.durationMs(.fast);
            if (duration_ms == 0) {
                self.views[view_index].removeCanvasRenderAnimation(canvas.toggleWidgetKnobCommandId(animation.id));
                return;
            }

            const from_tx = if (animation.selected) animation.travel else -animation.travel;
            const render_animation = motion.animation(.{
                .id = canvas.toggleWidgetKnobCommandId(animation.id),
                .start_ns = canvasRenderAnimationStartNsForView(&self.views[view_index]),
                .duration = .fast,
                .from_transform = canvas.Affine.translate(from_tx, 0),
                .to_transform = canvas.Affine.identity(),
            });
            self.views[view_index].replaceCanvasRenderAnimation(render_animation) catch |err| switch (err) {
                error.RenderAnimationListFull => return,
                else => return err,
            };
            self.views[view_index].replaceCanvasRenderAnimationDirtyBounds(render_animation.id, animation.dirty_bounds) catch {};
        }

        pub fn publishCanvasWidgetAccessibility(self: *Runtime, view_index: usize) anyerror!void {
            if (view_index >= self.view_count) return;
            const view = &self.views[view_index];
            if (view.kind != .gpu_surface) return;
            // Frame-profile `a11y` stage: node assembly + the platform
            // publish, riding every owned refresh. No-op unless
            // profiling is on.
            const a11y_begin = self.frame_profile.begin();
            defer self.frame_profile.end(.a11y, a11y_begin);
            var nodes: [platform.max_widget_accessibility_nodes]platform.WidgetAccessibilityNode = undefined;
            const semantics = view.widgetSemantics();
            const count = @min(semantics.len, nodes.len);
            for (semantics[0..count], 0..) |node, index| {
                nodes[index] = .{
                    .id = node.id,
                    .parent_id = canvasWidgetSemanticParentId(semantics, node.parent_index),
                    .role = platformWidgetAccessibilityRole(node.role),
                    .label = node.label,
                    .text_value = node.text_value,
                    .placeholder = node.placeholder,
                    .text_selection = platformWidgetAccessibilityTextRange(node.text_selection),
                    .text_composition = platformWidgetAccessibilityTextRange(node.text_composition),
                    .value = node.value,
                    .bounds = node.bounds,
                    .grid_row_index = node.grid_row_index,
                    .grid_column_index = node.grid_column_index,
                    .grid_row_count = node.grid_row_count,
                    .grid_column_count = node.grid_column_count,
                    .list_item_index = if (node.list.present) node.list.item_index else null,
                    .list_item_count = if (node.list.present) node.list.item_count else null,
                    .scroll_offset = if (node.scroll.present) node.scroll.offset else null,
                    .scroll_viewport_extent = if (node.scroll.present) node.scroll.viewport_extent else null,
                    .scroll_content_extent = if (node.scroll.present) node.scroll.content_extent else null,
                    .enabled = !node.state.disabled,
                    .focused = node.state.focused or (view.focused and node.id == view.canvas_widget_focused_id),
                    .hovered = node.state.hovered or (node.id != 0 and node.id == view.canvas_widget_hovered_id),
                    .pressed = node.state.pressed or (node.id != 0 and node.id == view.canvas_widget_pressed_id),
                    .selected = canvasWidgetSelectedState(node),
                    .expanded = node.state.expanded,
                    .required = node.state.required,
                    .read_only = node.state.read_only,
                    .invalid = node.state.invalid,
                    .focusable = node.focusable,
                    .actions = platformWidgetAccessibilityActions(node.actions),
                };
            }
            try self.options.platform.services.updateWidgetAccessibility(.{
                .window_id = view.window_id,
                .view_label = view.label,
                .nodes = nodes[0..count],
            });
        }

        pub fn refreshCanvasWidgetDisplayList(self: *Runtime, view_index: usize) anyerror!bool {
            if (view_index >= self.view_count) return error.ViewNotFound;
            if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;

            // Frame-profile `emit` stage: every display-list emission
            // funnels through this refresh (install, rebuild, and the
            // input-driven widget-state refreshes alike). No-op unless
            // profiling is on.
            const emit_begin = self.frame_profile.begin();
            defer self.frame_profile.end(.emit, emit_begin);

            var commands: [max_canvas_commands_per_view]canvas.CanvasCommand = undefined;
            var chrome_storage = CanvasDisplayListScratch{};
            var builder = canvas.Builder.init(&commands);
            const current = self.views[view_index].canvasDisplayList();
            const prefix_count = self.views[view_index].canvas_widget_display_list_prefix_count;
            const suffix_count = self.views[view_index].canvas_widget_display_list_suffix_count;
            if (prefix_count > current.commands.len or suffix_count > current.commands.len - prefix_count) return error.InvalidCommand;
            for (current.commands[0..prefix_count]) |command| try chrome_storage.appendCopiedCommand(&builder, command);
            try self.views[view_index].widgetLayoutTree().emitDisplayListWithState(&builder, self.views[view_index].widget_tokens, self.views[view_index].canvasWidgetRenderState());
            const suffix_start = current.commands.len - suffix_count;
            for (current.commands[suffix_start..current.commands.len]) |command| try chrome_storage.appendCopiedCommand(&builder, command);

            const display_list = builder.displayList();
            if (display_list.commands.len + self.views[view_index].canvas_widget_display_list_reserved_count > max_canvas_commands_per_view) {
                return error.CanvasCommandLimitReached;
            }
            var canvas_changes: [max_canvas_diff_changes_per_view]canvas.DiffChange = undefined;
            const changes = try canvas.DisplayList.diff(self.views[view_index].canvasDisplayList(), display_list, &canvas_changes);
            try self.views[view_index].copyCanvasDisplayList(display_list);
            reconcileCanvasWidgetCaretBlink(self, view_index);
            reconcileCanvasWidgetSpinners(self, view_index);
            canvas_frame_helpers.RuntimeCanvasFrames(Runtime).invalidateForCanvasChanges(self, self.views[view_index].frame, changes);
            if (changes.len > 0) {
                try canvas_frame_helpers.RuntimeCanvasFrames(Runtime).requestCanvasFrameForView(self, view_index);
                return true;
            }
            return false;
        }

        /// Keep the caret's looping blink animation in step with the
        /// display list just emitted: while a focused editable draws its
        /// caret, a ping-pong opacity animation on the caret command
        /// fades it out and back (500 ms per sweep, solid right after
        /// activity — every refresh re-arms the phase, so the caret
        /// holds steady while the user types or moves it). When no caret
        /// is showing the animation is removed so the view goes idle.
        fn reconcileCanvasWidgetCaretBlink(self: *Runtime, view_index: usize) void {
            const view = &self.views[view_index];
            const desired = canvasWidgetCaretBlinkTarget(view);
            const previous = view.canvas_widget_caret_blink_id;
            const desired_id: canvas.ObjectId = if (desired) |target| target.command_id else 0;
            if (previous != 0 and previous != desired_id) {
                view.removeCanvasRenderAnimation(previous);
                view.canvas_widget_caret_blink_id = 0;
            }
            const target = desired orelse return;
            view.replaceCanvasRenderAnimation(.{
                .id = target.command_id,
                .start_ns = canvasRenderAnimationStartNsForView(view) + caret_blink_solid_ns,
                .duration_ms = caret_blink_sweep_ms,
                .easing = .standard,
                .from_opacity = 1,
                .to_opacity = 0,
                .loop = .ping_pong,
            }) catch return;
            view.replaceCanvasRenderAnimationDirtyBounds(target.command_id, target.bounds) catch {};
            view.canvas_widget_caret_blink_id = target.command_id;
        }

        /// Keep each visible spinner's looping rotation animation in
        /// step with the display list just emitted: a `.wrap` rotation
        /// over the arc command spins it continuously (one turn per
        /// `spinner_rotation_turn_ms`, linear so the wrap is seamless)
        /// without re-emitting the display list. Arming preserves the
        /// existing animation's phase — a refresh mid-spin (hover,
        /// unrelated state) must not snap the arc back to its start.
        /// When a spinner unmounts (or hides) its animation is removed,
        /// so a view with no other work parks instead of pumping frames
        /// forever. Reduced motion arms nothing: the arc renders as a
        /// static pose.
        fn reconcileCanvasWidgetSpinners(self: *Runtime, view_index: usize) void {
            const view = &self.views[view_index];
            var desired_ids: [canvas_limits.max_canvas_widget_spinner_animations_per_view]canvas.ObjectId = undefined;
            var desired_count: usize = 0;

            const reduce_motion = view.widget_tokens.motion.durationMs(.slow) == 0;
            if (!reduce_motion) {
                const layout = view.widgetLayoutTree();
                for (layout.nodes, 0..) |node, node_index| {
                    if (node.widget.kind != .spinner or node.widget.id == 0) continue;
                    if (canvas.isWidgetHiddenInAncestors(layout, node_index)) continue;
                    if (node.widget.opacity <= 0) continue;
                    if (node.frame.normalized().isEmpty()) continue;
                    if (desired_count >= desired_ids.len) break;
                    const command_id = canvas.spinnerWidgetArcCommandId(node.widget.id);
                    const start_ns = existingCanvasRenderAnimationStartNs(view, command_id) orelse canvasRenderAnimationStartNsForView(view);
                    // The emitters paint at the LAYOUT frame (`node.frame`,
                    // pixel-snapped inside `spinnerWidgetRotationCenter`),
                    // so the rotation center matches the arc's geometry.
                    var laid_out = node.widget;
                    laid_out.frame = node.frame;
                    view.replaceCanvasRenderAnimation(.{
                        .id = command_id,
                        .start_ns = start_ns,
                        .duration_ms = spinner_rotation_turn_ms,
                        .easing = .linear,
                        .from_rotation = 0,
                        .to_rotation = 360,
                        .rotation_center = canvas.spinnerWidgetRotationCenter(laid_out, view.widget_tokens),
                        .loop = .wrap,
                    }) catch break;
                    view.replaceCanvasRenderAnimationDirtyBounds(command_id, node.frame) catch {};
                    desired_ids[desired_count] = command_id;
                    desired_count += 1;
                }
            }

            // Remove animations of spinners no longer visible.
            for (view.canvas_widget_spinner_ids[0..view.canvas_widget_spinner_count]) |previous_id| {
                var still_desired = false;
                for (desired_ids[0..desired_count]) |desired_id| {
                    if (desired_id == previous_id) {
                        still_desired = true;
                        break;
                    }
                }
                if (!still_desired) view.removeCanvasRenderAnimation(previous_id);
            }
            @memcpy(view.canvas_widget_spinner_ids[0..desired_count], desired_ids[0..desired_count]);
            view.canvas_widget_spinner_count = desired_count;
        }

        fn existingCanvasRenderAnimationStartNs(view: anytype, id: canvas.ObjectId) ?u64 {
            for (view.canvasRenderAnimations()) |animation| {
                if (animation.id == id) return animation.start_ns;
            }
            return null;
        }

        fn canvasWidgetCaretBlinkTarget(view: anytype) ?CanvasWidgetCaretBlinkTarget {
            if (!view.focused) return null;
            const focused_id = view.canvas_widget_focused_id;
            if (focused_id == 0 or view.canvas_widget_focus_visible_id != focused_id) return null;
            if (!view.canEditCanvasWidgetText(focused_id)) return null;
            const node_index = view.canvasWidgetNodeIndexById(focused_id) orelse return null;
            const widget = view.widget_layout_nodes[node_index].widget;
            // Mirror the emitters' caret gate: a caret line is drawn only
            // for a collapsed selection.
            const selection = canvas.widgetTextSelectionRange(widget) orelse return null;
            if (!selection.isCollapsed(widget.text.len)) return null;
            return .{
                .command_id = canvas.textCaretCommandId(widget.kind, widget.id),
                .bounds = view.widget_layout_nodes[node_index].frame,
            };
        }
    };
}

const CanvasWidgetCaretBlinkTarget = struct {
    command_id: canvas.ObjectId,
    bounds: geometry.RectF,
};

/// One full spinner revolution — linear, so the wrap seam is invisible.
const spinner_rotation_turn_ms: u32 = 1000;

/// One blink sweep (fade out or back) — a full cycle is two sweeps.
const caret_blink_sweep_ms: u32 = 500;
/// Post-activity hold before the first fade, the native caret shape:
/// typing or moving the caret keeps it solid.
const caret_blink_solid_ns: u64 = 500 * std.time.ns_per_ms;

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
