const std = @import("std");
const geometry = @import("geometry");
pub const Policy = @import("surface_layout_policy.zig").Policy;
pub const Options = struct {
    axis: u8 = 0,
    stopped: bool = false,
    has_title: bool = false,
    columns: usize = 0,
    min_size: geometry.SizeF = .{},
    padding: geometry.InsetsF = .{},
    gap: f32 = 0,
    content: geometry.SizeF = .{},
    title: geometry.SizeF = .{},
    floor: geometry.SizeF = .{},
    inset: f32 = 0,
    icon: f32 = 0,
    text_gap: f32 = 0,
    title_gap: f32 = 0,
};
pub const Child = struct {
    flags: u32 = 0,
    measured: geometry.SizeF = .{},
    authored: geometry.SizeF = .{},
    min_size: geometry.SizeF = .{},
    max_size: geometry.SizeF = .{},
    wrapped_height: f32 = 0,
};

/// Native owns request/result storage across recursive measurements. Only
/// raw measurements, authored facts and native integer conversion facts cross
/// the boundary; policy never collects a borrowed app/view arena.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    result: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, count: usize, options: Options) !Plan {
        const request = try allocator.alloc(u8, 96 + count * 40);
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, 12 + count * 12);
        @memset(request, 0);
        request[0] = 6;
        request[2] = options.axis;
        request[3] = @as(u8, if (options.stopped) 1 else 0) | @as(u8, if (options.has_title) 2 else 0);
        std.mem.writeInt(u32, request[4..8], std.math.cast(u32, count) orelse @panic("intrinsic child count exceeds wire range"), .little);
        std.mem.writeInt(u64, request[8..16], options.columns, .little);
        put(request[16..20], @floatFromInt(options.columns));
        put(request[20..24], @floatFromInt(options.columns -| 1));
        const values = [_]f32{ options.min_size.width, options.min_size.height, options.padding.left, options.padding.right, options.padding.top, options.padding.bottom, options.gap, options.content.width, options.content.height, options.title.width, options.title.height, options.floor.width, options.floor.height, options.inset, options.icon, options.text_gap, options.title_gap };
        for (values, 0..) |value, i| put(request[24 + i * 4 ..][0..4], value);
        return .{ .allocator = allocator, .policy = policy, .request = request, .result = result, .count = count };
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.result);
        self.allocator.free(self.request);
    }
    pub fn setChild(self: Plan, index: usize, facts: Child) void {
        const bytes = self.request[96 + index * 40 ..][0..40];
        std.mem.writeInt(u32, bytes[0..4], facts.flags, .little);
        const values = [_]f32{ facts.measured.width, facts.measured.height, facts.authored.width, facts.authored.height, facts.min_size.width, facts.min_size.height, facts.max_size.width, facts.max_size.height, facts.wrapped_height };
        for (values, 0..) |value, i| put(bytes[4 + i * 4 ..][0..4], value);
    }
    pub fn setWrappedHeight(self: Plan, index: usize, height: f32) void {
        put(self.request[96 + index * 40 + 36 ..][0..4], height);
    }
    pub fn run(self: Plan, operation: u8) void {
        self.request[1] = operation;
        if (self.policy(self.request, self.result) != self.result.len or std.mem.readInt(u32, self.result[0..4], .little) != self.count) @panic("invalid compiled intrinsic plan");
    }
    pub fn size(self: Plan) geometry.SizeF {
        return .init(get(self.result[4..8]), get(self.result[8..12]));
    }
    pub fn child(self: Plan, index: usize) geometry.SizeF {
        const bytes = self.result[12 + index * 12 ..][0..8];
        return .init(get(bytes[0..4]), get(bytes[4..8]));
    }
    pub fn measurementWidth(self: Plan, index: usize) f32 {
        return get(self.result[20 + index * 12 ..][0..4]);
    }
};
fn put(bytes: *[4]u8, value: f32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}
fn get(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}
