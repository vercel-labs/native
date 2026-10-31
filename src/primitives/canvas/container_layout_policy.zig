const std = @import("std");
const geometry = @import("geometry");

pub const Policy = @import("surface_layout_policy.zig").Policy;

/// Only authored facts, native measurements and semantic kind/theme facts
/// cross this boundary. Native owns all buffers; results are copied before
/// traversal, and only the enclosing app cycle collects the compiled arena.
pub const Child = struct {
    flags: u32 = 0,
    grow: f32 = 0,
    main: f32 = 0,
    cross: f32 = 0,
    offset_main: f32 = 0,
    offset_cross: f32 = 0,
    min_main: f32 = 0,
    max_main: f32 = 0,
    min_cross: f32 = 0,
    max_cross: f32 = 0,
    measured_main: f32 = 0,
    measured_cross: f32 = 0,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    result: []u8,
    count: usize,

    pub fn init(allocator: std.mem.Allocator, policy: Policy, count: usize, content: geometry.RectF, axis: u8, main_alignment: u8, cross_alignment: u8, gap: f32) !Plan {
        const request = try allocator.alloc(u8, 36 + count * 48);
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, 12 + count * 16);
        @memset(request, 0);
        request[0..8].* = .{ 5, 0, axis, main_alignment, cross_alignment, 0, 0, 0 };
        std.mem.writeInt(u32, request[8..12], std.math.cast(u32, count) orelse @panic("container child count exceeds wire range"), .little);
        for ([_]f32{ content.x, content.y, content.width, content.height, gap }, 0..) |value, i| put(request[12 + i * 4 ..][0..4], value);
        return .{ .allocator = allocator, .policy = policy, .request = request, .result = result, .count = count };
    }

    pub fn deinit(self: Plan) void {
        self.allocator.free(self.result);
        self.allocator.free(self.request);
    }

    pub fn setChild(self: Plan, index: usize, child: Child) void {
        const bytes = self.request[36 + index * 48 ..][0..48];
        std.mem.writeInt(u32, bytes[0..4], child.flags, .little);
        const values = [_]f32{ child.grow, child.main, child.cross, child.offset_main, child.offset_cross, child.min_main, child.max_main, child.min_cross, child.max_cross, child.measured_main, child.measured_cross };
        for (values, 0..) |value, i| put(bytes[4 + i * 4 ..][0..4], value);
    }

    pub fn setMeasuredMain(self: Plan, index: usize, value: f32) void {
        put(self.request[36 + index * 48 + 40 ..][0..4], value);
    }

    pub fn run(self: Plan, operation: u8) void {
        self.request[1] = operation;
        const expected = 12 + self.count * @as(usize, if (operation == 0) 4 else 16);
        if (self.policy(self.request, self.result) != expected or std.mem.readInt(u32, self.result[0..4], .little) != self.count) @panic("invalid compiled container plan");
    }

    pub fn cross(self: Plan, index: usize) f32 {
        return get(self.result[12 + index * 4 ..][0..4]);
    }

    pub fn frame(self: Plan, index: usize) geometry.RectF {
        const bytes = self.result[12 + index * 16 ..][0..16];
        return .init(get(bytes[0..4]), get(bytes[4..8]), get(bytes[8..12]), get(bytes[12..16]));
    }

    pub fn used(self: Plan) f32 {
        return get(self.result[4..8]);
    }

    pub fn overflow(self: Plan) f32 {
        return get(self.result[8..12]);
    }
};

fn put(bytes: *[4]u8, value: f32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}
fn get(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}
