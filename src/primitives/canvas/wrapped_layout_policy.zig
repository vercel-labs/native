const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
pub const Policy = @import("surface_layout_policy.zig").Policy;

pub const Mode = enum(u32) { fallback, paragraph, column, overlay, alert, accordion, row, accordion_content };
pub const Action = enum(u32) { fallback, authored, paragraph, children, header };
pub const Options = struct {
    kind: widgets.WidgetKind,
    spans: bool = false,
    virtualized: bool = false,
    titled: bool = false,
    open: bool = false,
    variable_row: bool = false,
    depth: usize = 0,
    depth_limit: usize = 32,
    width: f32,
    authored_height: f32 = 0,
    min_height: f32 = 0,
    max_height: f32 = 0,
    padding: geometry.InsetsF = .{},
    gap: f32 = 0,
    title_height: f32 = 0,
    indent: f32 = 0,
    floor: f32 = 0,
    inset: f32 = 0,
    title_gap: f32 = 0,
};

/// Requests and copied results remain native-owned across recursive text
/// measurements. The policy never resets the enclosing app/view arena.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    result: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, count: usize, options: Options) !Plan {
        const request = try allocator.alloc(u8, 80 + count * 16);
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, 20 + count * 8);
        @memset(request, 0);
        request[0] = 7;
        request[2] = @intCast(widgets.widgetKindCode(options.kind));
        request[3] = @as(u8, if (options.spans) 1 else 0) | @as(u8, if (options.virtualized) 2 else 0) | @as(u8, if (options.titled) 4 else 0) | @as(u8, if (options.open) 8 else 0) | @as(u8, if (options.variable_row) 16 else 0);
        std.mem.writeInt(u32, request[4..8], std.math.cast(u32, count) orelse @panic("wrapped child count exceeds wire range"), .little);
        std.mem.writeInt(u32, request[8..12], std.math.cast(u32, options.depth) orelse @panic("wrapped depth exceeds wire range"), .little);
        std.mem.writeInt(u32, request[12..16], std.math.cast(u32, options.depth_limit) orelse @panic("wrapped depth limit exceeds wire range"), .little);
        const values = [_]f32{ options.width, options.authored_height, options.min_height, options.max_height, options.padding.left, options.padding.right, options.padding.top, options.padding.bottom, options.gap, options.title_height, options.indent, options.floor, 0, 0, options.inset, options.title_gap };
        for (values, 0..) |value, i| put(request[16 + i * 4 ..][0..4], value);
        return .{ .allocator = allocator, .policy = policy, .request = request, .result = result, .count = count };
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.result);
        self.allocator.free(self.request);
    }
    pub fn setChild(self: Plan, index: usize, authored_width: f32, bubble: bool) void {
        const bytes = self.request[80 + index * 16 ..][0..16];
        std.mem.writeInt(u32, bytes[0..4], 1 | @as(u32, if (bubble) 2 else 0), .little);
        put(bytes[4..8], authored_width);
    }
    pub fn resolveWidth(self: Plan, index: usize, value: f32) void {
        const bytes = self.request[80 + index * 16 ..][0..16];
        std.mem.writeInt(u32, bytes[0..4], std.mem.readInt(u32, bytes[0..4], .little) | 4, .little);
        put(bytes[8..12], value);
    }
    pub fn setHeight(self: Plan, index: usize, value: f32) void {
        put(self.request[92 + index * 16 ..][0..4], value);
    }
    pub fn setParagraph(self: Plan, value: f32) void {
        put(self.request[64..68], value);
    }
    pub fn setFallback(self: Plan, value: f32) void {
        put(self.request[68..72], value);
    }
    pub fn run(self: Plan, operation: u8) void {
        self.request[1] = operation;
        if (self.policy(self.request, self.result) != self.result.len or std.mem.readInt(u32, self.result[0..4], .little) != self.count) @panic("invalid compiled wrapped plan");
    }
    pub fn action(self: Plan) Action {
        return @enumFromInt(std.mem.readInt(u32, self.result[4..8], .little));
    }
    pub fn mode(self: Plan) Mode {
        return @enumFromInt(std.mem.readInt(u32, self.result[16..20], .little));
    }
    pub fn innerWidth(self: Plan) f32 {
        return get(self.result[8..12]);
    }
    pub fn height(self: Plan) f32 {
        return get(self.result[12..16]);
    }
    pub fn width(self: Plan, index: usize) f32 {
        return get(self.result[20 + index * 8 ..][0..4]);
    }
    pub fn query(self: Plan, index: usize) u32 {
        return std.mem.readInt(u32, self.result[24 + index * 8 ..][0..4], .little);
    }
};
fn put(bytes: *[4]u8, value: f32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}
fn get(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}
