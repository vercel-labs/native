const std = @import("std");
const zero_native = @import("zero-native");
const model = @import("model.zig");
const scene = @import("scene.zig");

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;

const canvas_label = model.canvas_label;
const canvas_sidebar_width = model.canvas_sidebar_width;
const canvas_content_y = model.canvas_content_y;
const canvas_content_height = model.canvas_content_height;
const content_scroll_id = model.content_scroll_id;
const canvas_status_text_id = model.canvas_status_text_id;
const componentCommandPartId = model.componentCommandPartId;
const rect = model.rect;

const componentFrameStatus = scene.componentFrameStatus;

pub fn componentSnapshotWidget(snapshot: zero_native.automation.snapshot.Input, id: u64) ?zero_native.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (widget.id == id and std.mem.eql(u8, widget.view_label, canvas_label)) return widget;
    }
    return null;
}

pub fn componentStatusText(runtime: *const zero_native.Runtime) ![]const u8 {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    const node = layout.findById(canvas_status_text_id) orelse return error.TestUnexpectedResult;
    return node.widget.text;
}

pub fn expectComponentStatusContains(runtime: *const zero_native.Runtime, text: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, try componentStatusText(runtime), text) != null);
}

pub fn resetComponentDirty(runtime: *zero_native.Runtime) void {
    runtime.invalidated = false;
    runtime.dirty_region_count = 0;
}

pub fn componentWidgetCenter(runtime: *const zero_native.Runtime, id: canvas.ObjectId) !geometry.PointF {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    return node.frame.center();
}

pub fn dispatchComponentPointerClick(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId) !void {
    try dispatchComponentPointerClickAtTimestamp(runtime, app, id, 0);
}

pub fn dispatchComponentPointerClickAtTimestamp(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId, timestamp_ns: u64) !void {
    const point = try componentWidgetCenter(runtime, id);
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .timestamp_ns = timestamp_ns,
        .x = point.x,
        .y = point.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .timestamp_ns = timestamp_ns,
        .x = point.x,
        .y = point.y,
        .button = 0,
    } });
}

pub fn dispatchComponentPointerWheel(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId, delta_y: f32) !void {
    const point = try componentWidgetCenter(runtime, id);
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .scroll,
        .x = point.x,
        .y = point.y,
        .delta_y = delta_y,
    } });
}

pub fn dispatchComponentPointerDrag(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId, start_ratio: f32, end_ratio: f32) !void {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    const start = geometry.PointF.init(node.frame.x + node.frame.width * start_ratio, node.frame.center().y);
    const end = geometry.PointF.init(node.frame.x + node.frame.width * end_ratio, node.frame.center().y);
    try dispatchComponentPointerDragPoints(runtime, app, start, end);
}

pub fn dispatchComponentPointerDragByDelta(runtime: *zero_native.Runtime, app: zero_native.App, id: canvas.ObjectId, delta_x: f32) !void {
    const point = try componentWidgetCenter(runtime, id);
    try dispatchComponentPointerDragPoints(runtime, app, point, geometry.PointF.init(point.x + delta_x, point.y));
}

pub fn dispatchComponentPointerDragPoints(runtime: *zero_native.Runtime, app: zero_native.App, start: geometry.PointF, end: geometry.PointF) !void {
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = start.x,
        .y = start.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_drag,
        .x = end.x,
        .y = end.y,
        .delta_x = end.x - start.x,
        .delta_y = end.y - start.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .x = end.x,
        .y = end.y,
        .button = 0,
    } });
}
