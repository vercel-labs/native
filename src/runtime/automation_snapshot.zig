const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const canvas = @import("canvas");
const automation = @import("../automation/root.zig");
const platform = @import("../platform/root.zig");
const canvas_limits = @import("canvas_limits.zig");
const runtime_clock = @import("clock.zig");
const runtime_frame_profile = @import("frame_profile.zig");
const widget_bridge = @import("widget_bridge.zig");
const runtime_api = @import("api.zig");
const snapshot_policy = @import("snapshot_policy.zig");

const FrameDiagnostics = runtime_api.FrameDiagnostics;
const nowNanoseconds = runtime_clock.nowNanoseconds;
const timestampToU64 = runtime_clock.timestampToU64;
const widgetRoleName = widget_bridge.widgetRoleName;
const canvasWidgetActions = widget_bridge.canvasWidgetActions;
const canvasTextRange = widget_bridge.canvasTextRange;

pub fn RuntimeAutomationSnapshot(comptime Runtime: type) type {
    return struct {
        pub fn automationSnapshot(self: *Runtime, title: []const u8) automation.snapshot.Input {
            if (self.snapshot_policy == null) return @import("automation_snapshot_reference.zig").RuntimeAutomationSnapshot(Runtime).automationSnapshot(self, title);
            const count = bounded(self, self.window_count, self.automation_windows.len);
            if (count == 0) {
                self.automation_windows[0] = .{ .id = 1, .title = title, .bounds = geometry.RectF.fromSize(self.surface.size), .focused = true };
                return .{
                    .serialization_policy = self.snapshot_policy,
                    .windows = self.automation_windows[0..1],
                    .views = &.{},
                    .widgets = &.{},
                    .commands = self.options.commands,
                    .menus = self.options.menus,
                    .diagnostics = automationDiagnostics(self),
                    .frame_profile = automationFrameProfile(self),
                    .trays = automationTrays(self),
                    .audio = automationAudio(self),
                    .video = automationVideo(self),
                    .errors = self.dispatchErrors(),
                    .source = self.loaded_source,
                    .widget_node_budget = canvas_limits.max_canvas_widget_nodes_per_view,
                    .widget_semantics_budget = canvas_limits.max_canvas_widget_semantics_per_view,
                    .widget_context_menu_item_budget = canvas_limits.max_canvas_widget_context_menu_items_per_view,
                    .text_layout_plan_budget = canvas_limits.max_canvas_text_layouts_per_view,
                    .text_layout_line_budget = canvas_limits.max_canvas_text_layout_lines_per_view,
                };
            }
            var view_count: usize = 0;
            var widget_count: usize = 0;
            var menu_item_count: usize = 0;
            for (self.windows[0..count], 0..) |window, index| {
                self.automation_windows[index] = .{
                    .id = window.info.id,
                    .title = if (window.info.title.len > 0) window.info.title else title,
                    .bounds = window.info.frame,
                    .focused = window.info.focused,
                };
                if (view_count < self.automation_views.len) {
                    const views = self.listViews(window.info.id, self.automation_views[view_count..]);
                    view_count += views.len;
                }
                appendAutomationWidgets(self, window.info.id, &widget_count, &menu_item_count);
            }
            return .{
                .serialization_policy = self.snapshot_policy,
                .windows = self.automation_windows[0..count],
                .views = self.automation_views[0..view_count],
                .widgets = self.automation_widgets[0..widget_count],
                .commands = self.options.commands,
                .menus = self.options.menus,
                .diagnostics = automationDiagnostics(self),
                .frame_profile = automationFrameProfile(self),
                .trays = automationTrays(self),
                .audio = automationAudio(self),
                .video = automationVideo(self),
                .errors = self.dispatchErrors(),
                .source = self.loaded_source,
                .widget_node_budget = canvas_limits.max_canvas_widget_nodes_per_view,
                .widget_semantics_budget = canvas_limits.max_canvas_widget_semantics_per_view,
                .widget_context_menu_item_budget = canvas_limits.max_canvas_widget_context_menu_items_per_view,
                .text_layout_plan_budget = canvas_limits.max_canvas_text_layouts_per_view,
                .text_layout_line_budget = canvas_limits.max_canvas_text_layout_lines_per_view,
            };
        }

        /// Every live status item as the runtime last applied it. Menu
        /// bar contents live outside window captures, so identifiers
        /// are explicit in both snapshots and automation commands.
        fn automationTrays(self: *Runtime) []const automation.snapshot.Tray {
            var tray_count: usize = 0;
            var item_offset: usize = 0;
            for (self.status_items) |status_item| {
                if (snapshot_policy.plan(self.snapshot_policy, .bounded, .{ .flags = @intFromBool(status_item.active), .words = .{ 1, self.automation_trays.len - tray_count, 0, 0, 0, 0, 0, 0 } }).flags != 0) continue;
                const count = bounded(self, status_item.item_count, self.automation_tray_items.len - item_offset);
                for (status_item.items[0..count], 0..) |item, index| {
                    self.automation_tray_items[item_offset + index] = .{
                        .id = item.id,
                        .label = item.label,
                        .command = item.command,
                        .separator = item.separator,
                        .enabled = item.enabled,
                        .detail = item.detail,
                        .role = item.role,
                        .key = item.key,
                        .modifiers = item.modifiers,
                        .segmented = item.segmented,
                        .metric = item.metric,
                        .chart = item.chart,
                    };
                }
                self.automation_trays[tray_count] = .{
                    .id = status_item.id,
                    .visible = status_item.visible,
                    .title = status_item.title,
                    .items = self.automation_tray_items[item_offset .. item_offset + count],
                };
                tray_count += 1;
                item_offset += count;
            }
            return self.automation_trays[0..tray_count];
        }

        /// Live audio playback as the ui-app layer last mirrored it
        /// (`Runtime.audio_*`), or null when nothing is loaded. The
        /// player is outside every window capture, so the snapshot's
        /// advancing `position_ms` is the automation-visible evidence
        /// music is actually playing.
        fn automationAudio(self: *Runtime) ?automation.snapshot.Audio {
            if (presence(self) & 1 == 0) return null;
            return .{
                .key = self.audio_key,
                .playing = self.audio_playing,
                .buffering = self.audio_buffering,
                .source = @tagName(self.audio_source),
                .position_ms = self.audio_position_ms,
                .duration_ms = self.audio_duration_ms,
                .spectrum_events = self.audio_spectrum_events,
                .spectrum_bands = &self.audio_spectrum_bands,
            };
        }

        /// Live video playback as the ui-app layer last mirrored it
        /// (`Runtime.video_*`), or null when nothing is loaded — the
        /// audio report's twin. Texture contents stay out of every
        /// snapshot; the transport line plus the surface's placeholder
        /// widget are the automation-visible evidence.
        fn automationVideo(self: *Runtime) ?automation.snapshot.Video {
            if (presence(self) & 2 == 0) return null;
            return .{
                .key = self.video_key,
                .surface = self.video_surface_id,
                .playing = self.video_playing,
                .buffering = self.video_buffering,
                .looping = self.video_looping,
                .muted = self.video_muted,
                .source = @tagName(self.video_source),
                .position_ms = self.video_position_ms,
                .duration_ms = self.video_duration_ms,
                .width = self.video_width,
                .height = self.video_height,
            };
        }

        /// The frame profile's per-stage p50/p90 stats, non-null while
        /// `profile on` is active. Percentile sorting happens HERE — the
        /// snapshot path — never in the frame path; entries land in
        /// runtime-owned storage so the returned slices stay plain values.
        fn automationFrameProfile(self: *Runtime) ?automation.snapshot.FrameProfile {
            if (presence(self) & 4 == 0) return null;
            inline for (comptime std.enums.values(runtime_frame_profile.FrameProfileStage), 0..) |stage, index| {
                const stats = self.frame_profile.stats(stage);
                self.automation_frame_profile_stages[index] = .{
                    .name = stage.name(),
                    .p50_us = stats.p50_us,
                    .p90_us = stats.p90_us,
                    .max_us = stats.max_us,
                    .count = stats.total,
                };
            }
            return .{ .stages = &self.automation_frame_profile_stages };
        }

        fn automationDiagnostics(self: *Runtime) automation.snapshot.Diagnostics {
            const now_ns = timestampToU64(nowNanoseconds());
            const uptime_ns = snapshot_policy.plan(self.snapshot_policy, .uptime, .{ .words = .{ self.started_timestamp_ns, now_ns, 0, 0, 0, 0, 0, 0 } }).words[0];
            return .{
                .frame_index = self.last_diagnostics.frame_index,
                .command_count = self.last_diagnostics.command_count,
                .runtime_uptime_ns = uptime_ns,
                .dispatch_error_count = self.dispatch_error_total,
                .dropped_trace_records = self.dropped_trace_records,
                .publisher_pid = currentProcessId(),
                .markup_watch_armed = self.markup_watch_armed,
            };
        }

        /// The publishing process's pid, stamped into every snapshot so
        /// the automation CLI can refuse dropbox files whose publisher is
        /// gone — stale files were once served as live state. 0 on
        /// platforms without a process table.
        fn currentProcessId() u32 {
            return switch (builtin.os.tag) {
                .windows => std.os.windows.GetCurrentProcessId(),
                .wasi, .freestanding, .emscripten => 0,
                else => @intCast(@max(0, std.posix.system.getpid())),
            };
        }

        fn appendAutomationWidgets(self: *Runtime, window_id: platform.WindowId, widget_count: *usize, menu_item_count: *usize) void {
            for (self.views[0..self.view_count]) |*view| {
                if (snapshot_policy.plan(self.snapshot_policy, .view, .{ .flags = bit(view.open, 1) | bit(view.kind == .gpu_surface, 2), .words = .{ view.window_id, window_id, 0, 0, 0, 0, 0, 0 } }).flags == 0) continue;
                const layout = view.widgetLayoutTree();
                const semantics = view.widgetSemantics();
                const count = bounded(self, semantics.len, self.automation_widgets.len - widget_count.*);
                for (semantics[0..count]) |node| {
                    const state = widgetProjection(self, view, semantics, node);
                    self.automation_widgets[widget_count.*] = .{
                        .window_id = view.window_id,
                        .view_label = view.label,
                        .id = node.id,
                        .role = widgetRoleName(node.role),
                        .name = node.label,
                        .parent_id = if (state.flags & 32 != 0) semantics[@intCast(state.words[0])].id else null,
                        .value = node.value,
                        .text_value = node.text_value,
                        .placeholder = node.placeholder,
                        .grid_row_index = node.grid_row_index,
                        .grid_column_index = node.grid_column_index,
                        .grid_row_count = node.grid_row_count,
                        .grid_column_count = node.grid_column_count,
                        .list = .{
                            .present = node.list.present,
                            .item_index = node.list.item_index,
                            .item_count = node.list.item_count,
                        },
                        .scroll = .{
                            .present = node.scroll.present,
                            .offset = node.scroll.offset,
                            .viewport_extent = node.scroll.viewport_extent,
                            .content_extent = node.scroll.content_extent,
                        },
                        .virtual_range = virtualProjection(self, layout.virtualRangeById(node.id)),
                        .bounds = .{ .x = state.floats[0], .y = state.floats[1], .width = state.floats[2], .height = state.floats[3] },
                        .focused = state.flags & 2 != 0,
                        .enabled = state.flags & 4 != 0,
                        .hovered = state.flags & 8 != 0,
                        .pressed = state.flags & 16 != 0,
                        .selected = state.flags & 1 != 0,
                        .expanded = node.state.expanded,
                        .required = node.state.required,
                        .read_only = node.state.read_only,
                        .invalid = node.state.invalid,
                        .actions = canvasWidgetActions(node.actions),
                        .text_selection = canvasTextRange(node.text_selection),
                        .text_composition = canvasTextRange(node.text_composition),
                        .context_menu = automationWidgetContextMenu(self, layout, node.id, menu_item_count),
                    };
                    widget_count.* += 1;
                }
            }
        }

        /// Copy a widget's declared context-menu items into the
        /// snapshot's runtime-owned item storage (labels alias the
        /// view's bounded menu storage). The storage is sized for every
        /// view's full budget, so `count < declared.len` can only mean
        /// a budget invariant broke elsewhere — the copy stays bounded
        /// regardless.
        fn automationWidgetContextMenu(self: *Runtime, layout: canvas.WidgetLayoutTree, id: canvas.ObjectId, menu_item_count: *usize) []const automation.snapshot.WidgetContextMenuItem {
            const node = layout.findById(id) orelse return &.{};
            const declared = node.widget.context_menu;
            if (declared.len == 0) return &.{};
            const start = menu_item_count.*;
            const count = bounded(self, declared.len, self.automation_widget_menu_items.len - start);
            for (declared[0..count], self.automation_widget_menu_items[start .. start + count]) |item, *slot| {
                slot.* = .{
                    .label = item.label,
                    .enabled = item.enabled,
                    .separator = item.separator,
                };
            }
            menu_item_count.* = start + count;
            return self.automation_widget_menu_items[start .. start + count];
        }

        fn bit(value: bool, mask: u32) u32 {
            return if (value) mask else 0;
        }

        fn bounded(self: *Runtime, count: usize, capacity: usize) usize {
            return @intCast(snapshot_policy.plan(self.snapshot_policy, .bounded, .{ .flags = 1, .words = .{ count, capacity, 0, 0, 0, 0, 0, 0 } }).words[0]);
        }

        fn presence(self: *Runtime) u8 {
            return snapshot_policy.plan(self.snapshot_policy, .presence, .{ .flags = bit(self.audio_active, 1) | bit(self.video_active, 2) | bit(self.frame_profile.enabled, 4) }).flags;
        }

        fn widgetProjection(self: *Runtime, view: anytype, semantics: []const canvas.WidgetSemanticsNode, node: canvas.WidgetSemanticsNode) snapshot_policy.Plan {
            return snapshot_policy.plan(self.snapshot_policy, .widget, .{
                .flags = bit(node.state.selected, 1) | bit(node.value != null, 2) |
                    bit(node.state.focused, 8) | bit(view.keyboard_active, 16) | bit(view.focused, 32) |
                    bit(node.state.disabled, 64) | bit(node.state.hovered, 128) | bit(node.state.pressed, 256) | bit(node.parent_index != null, 1024),
                .words = .{ node.id, view.canvas_widget_focused_id, view.canvas_widget_hovered_id, view.canvas_widget_pressed_id, node.parent_index orelse 0, semantics.len, @intFromEnum(node.role), 0 },
                .floats = .{ node.value orelse 0, node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height, view.frame.x, view.frame.y },
            });
        }

        fn virtualProjection(self: *Runtime, range: ?canvas.VirtualListRange) automation.snapshot.WidgetVirtualRange {
            const value = range orelse canvas.VirtualListRange{};
            const projection = snapshot_policy.plan(self.snapshot_policy, .virtual_range, .{ .flags = @intFromBool(range != null), .words = .{ value.start_index, value.end_index, value.first_visible_index, value.last_visible_index, 0, 0, 0, 0 } });
            return .{ .present = projection.flags != 0, .start_index = @intCast(projection.words[0]), .end_index = @intCast(projection.words[1]), .first_visible_index = @intCast(projection.words[2]), .last_visible_index = @intCast(projection.words[3]), .rendered_count = @intCast(projection.words[4]) };
        }

        pub fn frameDiagnostics(self: *Runtime) FrameDiagnostics {
            return self.last_diagnostics;
        }
    };
}
