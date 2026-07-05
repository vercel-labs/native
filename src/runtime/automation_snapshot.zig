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

const FrameDiagnostics = runtime_api.FrameDiagnostics;
const nowNanoseconds = runtime_clock.nowNanoseconds;
const timestampToU64 = runtime_clock.timestampToU64;
const widgetRoleName = widget_bridge.widgetRoleName;
const canvasWidgetSemanticParentId = widget_bridge.canvasWidgetSemanticParentId;
const canvasWidgetSelectedState = widget_bridge.canvasWidgetSelectedState;
const canvasWidgetActions = widget_bridge.canvasWidgetActions;
const canvasTextRange = widget_bridge.canvasTextRange;
const canvasVirtualRange = widget_bridge.canvasVirtualRange;

pub fn RuntimeAutomationSnapshot(comptime Runtime: type) type {
    return struct {
        pub fn automationSnapshot(self: *Runtime, title: []const u8) automation.snapshot.Input {
            const count = @min(self.window_count, self.automation_windows.len);
            if (count == 0) {
                self.automation_windows[0] = .{ .id = 1, .title = title, .bounds = geometry.RectF.fromSize(self.surface.size), .focused = true };
                return .{
                    .windows = self.automation_windows[0..1],
                    .views = &.{},
                    .widgets = &.{},
                    .diagnostics = automationDiagnostics(self),
                    .frame_profile = automationFrameProfile(self),
                    .tray = automationTray(self),
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
                appendAutomationWidgets(self, window.info.id, &widget_count);
            }
            return .{
                .windows = self.automation_windows[0..count],
                .views = self.automation_views[0..view_count],
                .widgets = self.automation_widgets[0..widget_count],
                .diagnostics = automationDiagnostics(self),
                .frame_profile = automationFrameProfile(self),
                .tray = automationTray(self),
                .errors = self.dispatchErrors(),
                .source = self.loaded_source,
                .widget_node_budget = canvas_limits.max_canvas_widget_nodes_per_view,
                .widget_semantics_budget = canvas_limits.max_canvas_widget_semantics_per_view,
                .widget_context_menu_item_budget = canvas_limits.max_canvas_widget_context_menu_items_per_view,
                .text_layout_plan_budget = canvas_limits.max_canvas_text_layouts_per_view,
                .text_layout_line_budget = canvas_limits.max_canvas_text_layout_lines_per_view,
            };
        }

        /// The live tray as the runtime last applied it: title +
        /// dropdown rows, or null when no status item exists. The menu
        /// bar is outside every window capture, so the snapshot is the
        /// only automation-visible evidence of the model-driven tray.
        fn automationTray(self: *Runtime) ?automation.snapshot.Tray {
            if (!self.tray_created) return null;
            const count = @min(self.tray_item_count, self.automation_tray_items.len);
            for (self.tray_items[0..count], 0..) |item, index| {
                self.automation_tray_items[index] = .{
                    .id = item.id,
                    .label = item.label,
                    .command = item.command,
                    .separator = item.separator,
                    .enabled = item.enabled,
                };
            }
            return .{
                .title = self.tray_title,
                .items = self.automation_tray_items[0..count],
            };
        }

        /// The frame profile's per-stage p50/p90 stats, non-null while
        /// `profile on` is active. Percentile sorting happens HERE — the
        /// snapshot path — never in the frame path; entries land in
        /// runtime-owned storage so the returned slices stay plain values.
        fn automationFrameProfile(self: *Runtime) ?automation.snapshot.FrameProfile {
            if (!self.frame_profile.enabled) return null;
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
            const uptime_ns = if (self.started_timestamp_ns > 0 and now_ns >= self.started_timestamp_ns) now_ns - self.started_timestamp_ns else 0;
            return .{
                .frame_index = self.last_diagnostics.frame_index,
                .command_count = self.last_diagnostics.command_count,
                .runtime_uptime_ns = uptime_ns,
                .dispatch_error_count = self.dispatch_error_total,
                .dropped_trace_records = self.dropped_trace_records,
                .publisher_pid = currentProcessId(),
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

        fn appendAutomationWidgets(self: *Runtime, window_id: platform.WindowId, widget_count: *usize) void {
            for (self.views[0..self.view_count]) |*view| {
                if (!view.open or view.window_id != window_id or view.kind != .gpu_surface) continue;
                const layout = view.widgetLayoutTree();
                const semantics = view.widgetSemantics();
                for (semantics) |node| {
                    if (widget_count.* >= self.automation_widgets.len) return;
                    self.automation_widgets[widget_count.*] = .{
                        .window_id = view.window_id,
                        .view_label = view.label,
                        .id = node.id,
                        .role = widgetRoleName(node.role),
                        .name = node.label,
                        .parent_id = canvasWidgetSemanticParentId(semantics, node.parent_index),
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
                        .virtual_range = canvasVirtualRange(layout.virtualRangeById(node.id)),
                        .bounds = node.bounds.translate(geometry.OffsetF.init(view.frame.x, view.frame.y)),
                        .focused = node.state.focused or (view.focused and node.id == view.canvas_widget_focused_id),
                        .enabled = !node.state.disabled,
                        .hovered = node.state.hovered or (node.id != 0 and node.id == view.canvas_widget_hovered_id),
                        .pressed = node.state.pressed or (node.id != 0 and node.id == view.canvas_widget_pressed_id),
                        .selected = canvasWidgetSelectedState(node),
                        .expanded = node.state.expanded,
                        .required = node.state.required,
                        .read_only = node.state.read_only,
                        .invalid = node.state.invalid,
                        .actions = canvasWidgetActions(node.actions),
                        .text_selection = canvasTextRange(node.text_selection),
                        .text_composition = canvasTextRange(node.text_composition),
                    };
                    widget_count.* += 1;
                }
            }
        }

        pub fn frameDiagnostics(self: *Runtime) FrameDiagnostics {
            return self.last_diagnostics;
        }
    };
}
