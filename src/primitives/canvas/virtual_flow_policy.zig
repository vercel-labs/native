const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const surface = @import("surface_layout_policy.zig");
pub const Policy = surface.Policy;
pub const Options = struct {
    content: geometry.RectF,
    first: usize = 0,
    declared: usize = 0,
    anchor: usize = 0,
    overscan: usize = 0,
    semantic: usize = 0,
    grid_rows: usize = 0,
    flow_count: usize = 0,
    gap: f32 = 0,
    item_extent: f32 = 0,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    anchor_extent: f32 = 0,
    total_extent: f32 = 0,
    horizontal: bool = false,
    vertical: bool = false,
    grid: bool = false,
};
/// Native owns all request/result bytes across recursive measurement calls.
/// Integer-to-f32 facts expose the host's exact usize conversion, while the
/// compiled planner chooses ranges, indices, semantics and row geometry.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    result: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, count: usize, options: Options) !Plan {
        const request = try allocator.alloc(u8, 128 + count * 64);
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, 48 + count * 32);
        @memset(request, 0);
        request[0] = 8;
        request[2] = (surface.anchorFlags(0, false) >> 3) | @as(u8, if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) 2 else 0);
        request[3] = @as(u8, if (options.horizontal) 1 else 0) | @as(u8, if (options.vertical) 2 else 0) | @as(u8, if (options.grid) 4 else 0);
        std.mem.writeInt(u32, request[4..8], std.math.cast(u32, count) orelse @panic("virtual flow child count exceeds wire range"), .little);
        for ([_]usize{ options.first, options.declared, options.anchor, options.overscan, options.semantic, options.grid_rows }, 0..) |value, i| std.mem.writeInt(u64, request[8 + i * 8 ..][0..8], value, .little);
        const values = [_]f32{ @floatFromInt(options.flow_count), @floatFromInt(options.first +% options.flow_count), @floatFromInt(options.declared), @floatFromInt(options.grid_rows), @floatFromInt(options.semantic), options.content.x, options.content.y, options.content.width, options.content.height, options.gap, options.item_extent, 0, options.scroll_x, options.scroll_y, options.anchor_extent, options.total_extent };
        for (values, 0..) |value, i| put(request[56 + i * 4 ..][0..4], value);
        return .{ .allocator = allocator, .policy = policy, .request = request, .result = result, .count = count };
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.result);
        self.allocator.free(self.request);
    }
    pub fn setChild(self: Plan, index: usize, widget: @import("widgets.zig").Widget, absolute: usize) void {
        const bytes = self.request[128 + index * 64 ..][0..64];
        std.mem.writeInt(u32, bytes[0..4], 1, .little);
        const values = [_]f32{ @floatFromInt(absolute), widget.frame.width, widget.frame.height, widget.layout.min_size.width, widget.layout.max_size.width, widget.layout.min_size.height, widget.layout.max_size.height, widget.frame.x, widget.frame.y };
        for (values, 0..) |value, i| put(bytes[4 + i * 4 ..][0..4], value);
    }
    pub fn setExtent(self: Plan, value: f32) void {
        put(self.request[100..104], value);
    }
    pub fn setHeight(self: Plan, index: usize, value: f32) void {
        put(self.request[168 + index * 64 ..][0..4], value);
    }
    pub fn setIntrinsicWidth(self: Plan, index: usize, value: f32) void {
        put(self.request[172 + index * 64 ..][0..4], value);
    }
    pub fn setFrame(self: Plan, index: usize, value: geometry.RectF) void {
        for ([_]f32{ value.x, value.y, value.width, value.height }, 0..) |v, i| put(self.request[176 + index * 64 + i * 4 ..][0..4], v);
    }
    pub fn run(self: Plan, operation: u8) void {
        self.request[1] = operation;
        if (self.policy(self.request, self.result) != self.result.len or std.mem.readInt(u32, self.result[0..4], .little) != self.count) @panic("invalid compiled virtual flow plan");
    }
    pub fn mode(self: Plan) u32 {
        return std.mem.readInt(u32, self.result[4..8], .little);
    }
    pub fn itemCount(self: Plan) u32 {
        return std.mem.readInt(u32, self.result[8..12], .little);
    }
    pub fn itemExtent(self: Plan) f32 {
        return get(self.result[12..16]);
    }
    pub fn contentExtent(self: Plan) f32 {
        return get(self.result[16..20]);
    }
    pub fn content(self: Plan) geometry.RectF {
        return .init(get(self.result[24..28]), get(self.result[28..32]), get(self.result[32..36]), get(self.result[36..40]));
    }
    pub fn enabled(self: Plan, index: usize) bool {
        return std.mem.readInt(u32, self.result[48 + index * 32 ..][0..4], .little) & 1 != 0;
    }
    pub fn needsWidth(self: Plan, index: usize) bool {
        return std.mem.readInt(u32, self.result[48 + index * 32 ..][0..4], .little) & 2 != 0;
    }
    pub fn itemIndex(self: Plan, index: usize) u32 {
        return std.mem.readInt(u32, self.result[52 + index * 32 ..][0..4], .little);
    }
    pub fn frame(self: Plan, index: usize) geometry.RectF {
        const bytes = self.result[56 + index * 32 ..][0..16];
        return .init(get(bytes[0..4]), get(bytes[4..8]), get(bytes[8..12]), get(bytes[12..16]));
    }
};
fn put(bytes: *[4]u8, value: f32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}
fn get(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}
