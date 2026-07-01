const geometry = @import("geometry");
const canvas = @import("canvas");
const automation = @import("../automation/root.zig");
const platform = @import("../platform/root.zig");
const runtime_clock = @import("clock.zig");
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
                    .source = self.loaded_source,
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
                .source = self.loaded_source,
            };
        }

        fn automationDiagnostics(self: *Runtime) automation.snapshot.Diagnostics {
            const now_ns = timestampToU64(nowNanoseconds());
            const uptime_ns = if (self.started_timestamp_ns > 0 and now_ns >= self.started_timestamp_ns) now_ns - self.started_timestamp_ns else 0;
            return .{
                .frame_index = self.last_diagnostics.frame_index,
                .command_count = self.last_diagnostics.command_count,
                .runtime_uptime_ns = uptime_ns,
            };
        }

        fn appendAutomationWidgets(self: *Runtime, window_id: platform.WindowId, widget_count: *usize) void {
            for (self.views[0..self.view_count]) |view| {
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
