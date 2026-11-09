//! Copied grid and scrolling continuations; native executes measurement queries.
const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const surface = @import("surface_layout_policy.zig");
const virtual = @import("virtual_flow_policy.zig");
pub const Policy = surface.Policy;

fn word(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn put(bytes: []u8, at: usize, value: f32) void {
    word(bytes, at, @bitCast(value));
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(read(bytes, at));
}
fn length(base: usize, count: usize, stride: usize) !usize {
    return std.math.add(usize, base, try std.math.mul(usize, count, stride));
}
fn absent(bytes: []const u8, first: usize, end: usize) void {
    if (!std.mem.allEqual(u8, bytes[first..end], 0)) @panic("invalid absent flow measurement fields");
}
fn rect(bytes: []const u8, at: usize) geometry.RectF {
    return .init(float(bytes, at), float(bytes, at + 4), float(bytes, at + 8), float(bytes, at + 12));
}
pub const GridResult = struct {
    bytes: [32]u8,
    pub fn pending(self: GridResult) bool {
        return read(&self.bytes, 4) == 1;
    }
    pub fn index(self: GridResult) usize {
        return read(&self.bytes, 8);
    }
};
pub const GridPlan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    result: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, count: usize, flows: usize, content: geometry.RectF, columns: usize, overscan: usize, gap: f32, item_extent: f32, scroll: f32, windowed: bool) !GridPlan {
        const request = try allocator.alloc(u8, try length(128, count, 64));
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, try length(32, count, 32));
        @memset(request, 0);
        request[0..4].* = .{ 38, 1, @import("render_plan_policy.zig").numericFlags(), @intFromBool(windowed) };
        word(request, 4, std.math.cast(u32, count) orelse @panic("grid measurement count exceeds wire range"));
        const packet = request[16..92];
        packet[0..4].* = .{ 4, 0, @as(u8, @intFromBool(windowed)) | (surface.anchorFlags(0, false) >> 2) | @as(u8, if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) 4 else 0), 0 };
        for ([_]usize{ flows, columns, overscan }, 0..) |value, i| std.mem.writeInt(u64, packet[4 + i * 8 ..][0..8], value, .little);
        const values = [_]f32{ content.x, content.y, content.width, content.height, gap, item_extent, 0, scroll, @floatFromInt(flows), @floatFromInt(columns), @floatFromInt(flows -| 1), @floatFromInt(columns -| 1) };
        for (values, 0..) |value, i| put(packet, 28 + i * 4, value);
        return .{ .allocator = allocator, .policy = policy, .request = request, .result = result, .count = count };
    }
    pub fn deinit(self: GridPlan) void {
        self.allocator.free(self.request);
        self.allocator.free(self.result);
    }
    pub fn setChild(self: GridPlan, index: usize, child: widgets.Widget, flow: bool, fills_width: bool) void {
        const at = 128 + index * 64;
        word(self.request, at, @as(u32, @intFromBool(flow)) | (@as(u32, @intFromBool(fills_width)) << 1));
        const values = [_]f32{ child.frame.x, child.frame.y, child.frame.width, child.frame.height, child.layout.min_size.width, child.layout.min_size.height, child.layout.max_size.width, child.layout.max_size.height };
        for (values, 0..) |value, i| put(self.request, at + 8 + i * 4, value);
    }
    pub fn run(self: GridPlan) GridResult {
        @memset(self.result, 0xa5);
        const written = self.policy(self.request, self.result);
        if (written < 32 or read(self.result, 0) != 1 or read(self.result, 4) > 1) @panic("invalid grid measurement result");
        const result: GridResult = .{ .bytes = self.result[0..32].* };
        if (result.pending()) {
            const index = result.index();
            if (written != 32 or index >= self.count or read(self.request, 128 + index * 64) & 1 == 0 or read(self.request, 132 + index * 64) != 0) @panic("invalid grid measurement continuation");
            absent(&result.bytes, 12, 32);
        } else {
            if (written != self.result.len or read(self.result, 24) > 1) @panic("invalid grid frame length or admission");
            absent(&result.bytes, 8, 12);
            absent(&result.bytes, 20, 24);
            absent(&result.bytes, 28, 32);
            if (!self.active()) absent(&result.bytes, 12, 20);
            for (0..self.count) |i| {
                const at = 32 + i * 32;
                if (read(self.result, at) > 1) @panic("invalid grid frame flags");
                if (self.enabled(i)) {
                    if (read(self.request, 128 + i * 64) & 1 == 0 or read(self.result, at + 4) >= read(self.result, at + 8) or read(self.result, at + 8) > self.count) @panic("invalid grid frame identity");
                    absent(self.result, at + 12, at + 16);
                } else absent(self.result, at, at + 32);
            }
        }
        return result;
    }
    pub fn reply(self: GridPlan, result: GridResult, height: f32) void {
        std.debug.assert(result.pending());
        const at = 128 + result.index() * 64;
        word(self.request, at + 4, 1);
        put(self.request, at + 40, height);
    }
    pub fn active(self: GridPlan) bool {
        return read(self.result, 24) != 0;
    }
    pub fn rows(self: GridPlan) u32 {
        return read(self.result, 12);
    }
    pub fn extent(self: GridPlan) f32 {
        return float(self.result, 16);
    }
    pub fn enabled(self: GridPlan, index: usize) bool {
        return read(self.result, 32 + index * 32) != 0;
    }
    pub fn itemIndex(self: GridPlan, index: usize) u32 {
        return read(self.result, 36 + index * 32);
    }
    pub fn itemCount(self: GridPlan, index: usize) u32 {
        return read(self.result, 40 + index * 32);
    }
    pub fn frame(self: GridPlan, index: usize) geometry.RectF {
        return rect(self.result, 48 + index * 32);
    }
};

pub const FlowAction = enum(u32) { done, extent, height, width };
pub const FlowResult = struct {
    bytes: [32]u8,
    pub fn action(self: FlowResult) FlowAction {
        return @enumFromInt(read(&self.bytes, 4));
    }
    pub fn index(self: FlowResult) usize {
        return read(&self.bytes, 8);
    }
    pub fn width(self: FlowResult) f32 {
        return float(&self.bytes, 16);
    }
};
pub const FlowPlan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    result: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, count: usize, operation: u8, options: virtual.Options) !FlowPlan {
        // Reuse the established host conversion facts without borrowing any
        // compiler result or retaining the temporary allocation's storage.
        _ = try length(128, count, 64);
        _ = try length(48, count, 32);
        const base = try virtual.Plan.init(allocator, policy, count, options);
        defer base.deinit();
        const request = try allocator.alloc(u8, try length(144, count, 72));
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, try length(80, count, 32));
        @memset(request, 0);
        request[0..4].* = .{ 39, 1, operation, @import("render_plan_policy.zig").numericFlags() };
        word(request, 4, std.math.cast(u32, count) orelse @panic("flow measurement count exceeds wire range"));
        @memcpy(request[16..][0..base.request.len], base.request);
        request[17] = operation;
        return .{ .allocator = allocator, .policy = policy, .request = request, .result = result, .count = count };
    }
    pub fn deinit(self: FlowPlan) void {
        self.allocator.free(self.request);
        self.allocator.free(self.result);
    }
    fn state(self: FlowPlan, index: usize) usize {
        return 144 + self.count * 64 + index * 8;
    }
    pub fn setChild(self: FlowPlan, index: usize, child: widgets.Widget, absolute: usize, flow: bool, fills_width: bool) void {
        const at = 144 + index * 64;
        word(self.request, at, @intFromBool(flow));
        const values = [_]f32{ @floatFromInt(absolute), child.frame.width, child.frame.height, child.layout.min_size.width, child.layout.max_size.width, child.layout.min_size.height, child.layout.max_size.height, child.frame.x, child.frame.y };
        for (values, 0..) |value, i| put(self.request, at + 4 + i * 4, value);
        word(self.request, self.state(index) + 4, @intFromBool(fills_width));
    }
    pub fn run(self: FlowPlan) FlowResult {
        @memset(self.result, 0xa5);
        const written = self.policy(self.request, self.result);
        if (written < 32 or read(self.result, 0) != 1 or read(self.result, 4) > 3) @panic("invalid flow measurement result");
        const result: FlowResult = .{ .bytes = self.result[0..32].* };
        absent(&result.bytes, 12, 16);
        absent(&result.bytes, 20, 24);
        absent(&result.bytes, 28, 32);
        if (result.action() == .done) {
            if (written != self.result.len or read(self.result, 24) > 1 or read(self.result, 32) != self.count or (if (self.request[2] == 2) read(self.result, 36) != 4 else read(self.result, 36) > 1)) @panic("invalid flow allocation length or mode");
            absent(&result.bytes, 8, 12);
            absent(&result.bytes, 16, 20);
            for (0..self.count) |i| {
                const at = 80 + i * 32;
                if (read(self.result, at) != 0 and read(self.result, at) != 1 and read(self.result, at) != 3) @panic("invalid flow frame flags");
                if (self.enabled(i) and read(self.request, 144 + i * 64) == 0) @panic("invalid flow frame admission");
                if (!self.enabled(i)) absent(self.result, at, at + 32);
            }
        } else {
            const index = result.index();
            if (written != 32 or index >= self.count or read(self.request, 144 + index * 64) != 1 or read(self.result, 24) != 0) @panic("invalid flow child continuation");
            if (result.action() == .extent) {
                if (read(self.request, 8) != 0 or self.request[2] != 0) @panic("invalid repeated flow extent query");
            } else if (read(self.request, self.state(index)) != 0 or (result.action() == .width) != (self.request[2] == 2)) @panic("invalid repeated flow measurement");
            if (result.action() != .height) absent(&result.bytes, 16, 20);
        }
        return result;
    }
    pub fn reply(self: FlowPlan, result: FlowResult, value: f32) void {
        switch (result.action()) {
            .done => unreachable,
            .extent => {
                word(self.request, 8, 1);
                put(self.request, 116, value);
            },
            .height, .width => {
                word(self.request, self.state(result.index()), 1);
                put(self.request, 144 + result.index() * 64 + @as(usize, if (result.action() == .height) 40 else 44), value);
            },
        }
    }
    pub fn active(self: FlowPlan) bool {
        return read(self.result, 24) != 0;
    }
    pub fn itemCount(self: FlowPlan) u32 {
        return read(self.result, 40);
    }
    pub fn extent(self: FlowPlan) f32 {
        return float(self.result, 44);
    }
    pub fn mode(self: FlowPlan) u32 {
        return read(self.result, 36);
    }
    pub fn enabled(self: FlowPlan, index: usize) bool {
        return read(self.result, 80 + index * 32) & 1 != 0;
    }
    pub fn itemIndex(self: FlowPlan, index: usize) u32 {
        return read(self.result, 84 + index * 32);
    }
    pub fn frame(self: FlowPlan, index: usize) geometry.RectF {
        return rect(self.result, 88 + index * 32);
    }
};
