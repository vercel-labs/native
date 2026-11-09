//! Copies layout and retained observations to the portable region owner.
//! Native retains all buffers, measurement capabilities and OS execution.
const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");
const limits = @import("canvas_limits.zig");
const RuntimeView = @import("view.zig").RuntimeView;
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { stamp, drivers, drag, record };
pub const Options = struct {
    nodes: []const canvas.WidgetLayoutNode = &.{},
    tokens: canvas.DesignTokens = .{},
    frame: geometry.RectF = .zero(),
    supported: bool = false,
    drag_service: bool = false,
    drag_pushed: bool = false,
    drag_capacity: usize = limits.max_canvas_widget_window_drag_regions_per_view,
    previous: []const platform.WindowDragRegion = &.{},
    tracked_ids: []const u64 = &.{},
    tracked_offsets: []const geometry.OffsetF = &.{},
    measure_view: ?*const RuntimeView = null,
    record_id: u64 = 0,
};
pub const Program = struct {
    stamp_count: usize = 0,
    stamps: [limits.max_canvas_widget_nodes_per_view]usize = undefined,
    driver_count: usize = 0,
    drivers: [platform.max_gpu_surface_scroll_drivers]platform.GpuSurfaceScrollDriver = undefined,
    occluder_count: usize = 0,
    occluders: [platform.max_gpu_surface_scroll_occluders]platform.GpuSurfaceScrollOccluder = undefined,
    region_count: usize = 0,
    regions: [limits.max_canvas_widget_window_drag_regions_per_view]platform.WindowDragRegion = undefined,
    detail: u32 = 0,
    pub fn stamp(self: *const Program, nodes: []canvas.WidgetLayoutNode) void {
        for (self.stamps[0..self.stamp_count]) |index| nodes[index].widget.runtime_flags.native_scroll = true;
    }
};
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn float(bytes: []u8, at: usize, value: f32) void {
    put(bytes, at, @bitCast(value));
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn wide(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}
fn scalar(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
fn rect(bytes: []const u8, at: usize) geometry.RectF {
    return .init(scalar(bytes, at), scalar(bytes, at + 4), scalar(bytes, at + 8), scalar(bytes, at + 12));
}
fn writeRect(bytes: []u8, at: usize, value: geometry.RectF) void {
    for ([_]f32{ value.x, value.y, value.width, value.height }, 0..) |v, i| float(bytes, at + i * 4, v);
}
pub fn plan(policy: Policy, mode: Mode, options: Options) ?Program {
    const callback = policy orelse return null;
    const count = options.nodes.len;
    if (count > limits.max_canvas_widget_nodes_per_view or options.tracked_ids.len > platform.max_gpu_surface_scroll_drivers or options.tracked_ids.len != options.tracked_offsets.len or options.previous.len > limits.max_canvas_widget_window_drag_regions_per_view or options.drag_capacity > limits.max_canvas_widget_window_drag_regions_per_view)
        @panic("host input-region observation capacity");
    const tracked_at = 64 + count * 128;
    const previous_at = tracked_at + options.tracked_ids.len * 16;
    const request = std.heap.page_allocator.alloc(u8, previous_at + options.previous.len * 20) catch @panic("host input-region observation allocation");
    defer std.heap.page_allocator.free(request);
    @memset(request, 0);
    request[0..4].* = .{ 79, 1, @intFromEnum(mode), 0 };
    put(request, 4, @intCast(count));
    put(request, 8, @intCast(options.tracked_ids.len));
    put(request, 12, @intCast(options.previous.len));
    put(request, 20, @as(u32, @intFromBool(options.supported)) | (@as(u32, @intFromBool(options.drag_service)) << 1) | (@as(u32, @intFromBool(options.drag_pushed)) << 2));
    put(request, 24, @intFromBool(options.tokens.scroll.overscroll == .rubber_band));
    put(request, 28, @intCast(options.drag_capacity));
    writeRect(request, 32, options.frame);
    if (mode == .record) std.mem.writeInt(u64, request[40..48], options.record_id, .little);
    for ([_]i32{ options.tokens.layer.base, options.tokens.layer.overlay, options.tokens.layer.modal, options.tokens.layer.floating }, 0..) |v, i| put(request, 48 + i * 4, @bitCast(v));
    for (options.nodes, 0..) |node, i| {
        const n = node.widget;
        const bytes = request[64 + i * 128 ..][0..128];
        put(bytes, 0, canvas.widgetKindCode(n.kind));
        put(bytes, 8, if (node.parent_index) |p| @intCast(p) else std.math.maxInt(u32));
        put(bytes, 12, @intCast(node.depth));
        std.mem.writeInt(u64, bytes[16..24], n.id, .little);
        put(bytes, 24, @as(u32, @intFromBool(n.semantics.hidden)) | (@as(u32, @intFromBool(n.state.disabled)) << 1) | (@as(u32, @intFromBool(n.state.selected)) << 2) | (@as(u32, @intFromBool(n.layout.anchor != null)) << 3) | (@as(u32, @intFromBool(n.layout.clip_content)) << 4) | (@as(u32, @intFromBool(n.window_drag)) << 6) | (@as(u32, @intFromBool(n.layer != null)) << 9));
        put(bytes, 28, (@as(u32, @intFromBool(n.semantics.actions.press)) << 1) | (@as(u32, @intFromBool(n.semantics.actions.toggle)) << 2) | (@as(u32, @intFromBool(n.semantics.actions.drag)) << 8));
        float(bytes, 32, n.value);
        put(bytes, 36, @bitCast(n.layer orelse 0));
        writeRect(bytes, 40, node.frame);
        const values = [_]f32{ n.transform.a, n.transform.b, n.transform.c, n.transform.d, n.transform.tx, n.transform.ty, n.layout.padding.top, n.layout.padding.right, n.layout.padding.bottom, n.layout.padding.left, n.value_x };
        for (values, 0..) |v, j| float(bytes, 56 + j * 4, v);
        std.mem.writeInt(u64, bytes[100..108], n.layout.virtual_item_count, .little);
        put(bytes, 108, @as(u32, @intFromBool(n.layout.virtualized)) | (@as(u32, @intFromBool(n.scrim)) << 1) | (@as(u32, @intFromEnum(n.scroll_axes)) << 2) | (@as(u32, @intFromEnum(n.overscroll)) << 4));
    }
    for (options.tracked_ids, options.tracked_offsets, 0..) |id, offset, i| {
        const at = tracked_at + i * 16;
        std.mem.writeInt(u64, request[at..][0..8], id, .little);
        float(request, at + 8, offset.dx);
        float(request, at + 12, offset.dy);
    }
    for (options.previous, 0..) |region, i| {
        const at = previous_at + i * 20;
        writeRect(request, at, region.frame);
        put(request, at + 16, @intFromBool(region.exclusion));
    }
    var output: [32 + limits.max_canvas_widget_nodes_per_view * 4 + platform.max_gpu_surface_scroll_drivers * 64 + platform.max_gpu_surface_scroll_occluders * 16 + limits.max_canvas_widget_window_drag_regions_per_view * 20]u8 = undefined;
    var observations: usize = 0;
    var length: usize = undefined;
    while (true) {
        @memset(&output, 0xa5);
        length = callback(request, &output);
        if (length < 32 or length > output.len or word(&output, 0) != 1 or word(&output, 4) != @intFromEnum(mode)) @panic("invalid compiled host input-region header");
        if (word(&output, 8) != 1) break;
        const index = word(&output, 28);
        const axes = word(&output, 12);
        if (mode != .drivers or length != 48 or index >= count or (axes != 1 and axes != 3) or word(&output, 16) != 0 or word(&output, 20) != 0 or word(&output, 24) != 0 or observations >= platform.max_gpu_surface_scroll_drivers)
            @panic("invalid compiled host input-region measurement");
        const at = 64 + @as(usize, index) * 128;
        if (word(request, at + 112) != 0) @panic("repeated compiled host input-region measurement");
        const view = options.measure_view orelse @panic("missing host input-region measurement capability");
        const viewport = rect(&output, 32);
        float(request, at + 116, view.canvasWidgetScrollContentExtent(index, viewport));
        if (axes & 2 != 0) float(request, at + 120, view.canvasWidgetScrollContentExtentX(index, viewport));
        put(request, at + 112, 1);
        observations += 1;
    }
    if (word(&output, 8) != 0) @panic("invalid compiled host input-region status");
    var result = Program{ .stamp_count = word(&output, 12), .driver_count = word(&output, 16), .occluder_count = word(&output, 20), .region_count = word(&output, 24), .detail = word(&output, 28) };
    if (result.stamp_count > count or result.driver_count > result.drivers.len or result.occluder_count > result.occluders.len or result.region_count > options.drag_capacity or length != 32 + result.stamp_count * 4 + result.driver_count * 64 + result.occluder_count * 16 + result.region_count * 20 or (mode != .stamp and mode != .drivers and result.stamp_count != 0) or (mode != .drivers and (result.driver_count != 0 or result.occluder_count != 0)) or (mode != .drag and result.region_count != 0) or (mode == .drag and result.detail > 1) or (mode == .record and result.detail != std.math.maxInt(u32) and (result.detail > options.tracked_ids.len or result.detail >= platform.max_gpu_surface_scroll_drivers)) or ((mode == .stamp or mode == .drivers) and result.detail != 0))
        @panic("invalid compiled host input-region program");
    var at: usize = 32;
    for (result.stamps[0..result.stamp_count], 0..) |*index, i| {
        index.* = word(&output, at);
        if (index.* >= count or (i > 0 and result.stamps[i - 1] >= index.*)) @panic("invalid compiled host input-region stamp");
        at += 4;
    }
    for (result.drivers[0..result.driver_count]) |*driver| {
        const flags = word(&output, at + 20);
        const mask = word(&output, at + 16);
        if (flags > 31 or mask >= (@as(u32, 1) << @intCast(result.occluder_count)) or wide(&output, at) == 0 or wide(&output, at + 56) != 0) @panic("invalid compiled host input-region driver");
        driver.* = .{ .id = wide(&output, at), .parent_id = wide(&output, at + 8), .occluder_mask = mask, .frame = rect(&output, at + 24), .content_size = .{ .width = scalar(&output, at + 40), .height = scalar(&output, at + 44) }, .offset_x = scalar(&output, at + 48), .offset_y = scalar(&output, at + 52), .set_offset_x = flags & 1 != 0, .set_offset_y = flags & 2 != 0, .rubber_band = flags & 4 != 0, .scrolls_x = flags & 8 != 0, .scrolls_y = flags & 16 != 0 };
        at += 64;
    }
    for (result.occluders[0..result.occluder_count]) |*occluder| {
        occluder.* = .{ .frame = rect(&output, at) };
        at += 16;
    }
    for (result.regions[0..result.region_count]) |*region| {
        if (word(&output, at + 16) > 1) @panic("invalid compiled host input-region exclusion");
        region.* = .{ .frame = rect(&output, at), .exclusion = word(&output, at + 16) != 0 };
        at += 20;
    }
    return result;
}
