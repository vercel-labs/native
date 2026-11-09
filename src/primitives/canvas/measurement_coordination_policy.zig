//! Native-owned request buffers and copied portable measurement continuations.
const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const tokens_model = @import("tokens.zig");
const metric = @import("widget_metric_policy.zig");
const container = @import("container_layout_policy.zig");
pub const Policy = @import("surface_layout_policy.zig").Policy;
fn word(b: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], value, .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn put(b: []u8, at: usize, value: f32) void {
    word(b, at, @bitCast(value));
}
fn float(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn absent(b: []const u8, first: usize, end: usize) void {
    if (!std.mem.allEqual(u8, b[first..end], 0)) @panic("invalid absent measurement fields");
}
pub const WrappedAction = enum(u32) { done, intrinsic, paragraph, row_width, bubble_width, child_height };
pub const WrappedResult = struct {
    bytes: [32]u8,
    pub fn action(self: WrappedResult) WrappedAction {
        return @enumFromInt(read(&self.bytes, 4));
    }
    pub fn index(self: WrappedResult) usize {
        return read(&self.bytes, 8);
    }
    pub fn height(self: WrappedResult) f32 {
        return float(&self.bytes, 12);
    }
    pub fn width(self: WrappedResult) f32 {
        return float(&self.bytes, 16);
    }
};
pub const WrappedPlan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, widget: widgets.Widget, tokens: tokens_model.DesignTokens, width: f32, depth: usize, limit: usize, variable_row: bool, accordion_content: bool, selected: bool) !WrappedPlan {
        const count = widget.children.len;
        const request = try allocator.alloc(u8, try std.math.add(usize, 288, try std.math.mul(usize, count, 32)));
        @memset(request, 0);
        request[0..4].* = .{ 34, 1, if (accordion_content) 2 else if (variable_row) 1 else 0, @as(u8, @intFromBool(widget.layout.virtualized)) | (@as(u8, @intFromBool(widget.layout.padding_is_kind_default)) << 1) | (@as(u8, @intFromBool(selected)) << 2) };
        word(request, 4, std.math.cast(u32, count) orelse @panic("wrapped child count exceeds wire range"));
        word(request, 8, std.math.cast(u32, depth) orelse std.math.maxInt(u32));
        word(request, 12, @intCast(limit));
        for ([_]f32{ width, widget.frame.height, widget.layout.min_size.height, widget.layout.max_size.height }, 0..) |value, i| put(request, 16 + i * 4, value);
        const registers = metric.Request.init(.intrinsic, widget, tokens, 0);
        @memcpy(request[64..288], &registers.bytes);
        return .{ .allocator = allocator, .policy = tokens.measurement_coordination_policy.?, .request = request, .count = count };
    }
    pub fn deinit(self: WrappedPlan) void {
        self.allocator.free(self.request);
    }
    pub fn setChild(self: WrappedPlan, index: usize, child: widgets.Widget, flow: bool) void {
        const at = 288 + index * 32;
        word(self.request, at, @as(u32, @intFromBool(flow)) | (@as(u32, @intFromBool(child.kind == .bubble)) << 1) | (@as(u32, @intFromBool(child.variant == .ghost)) << 2));
        put(self.request, at + 4, child.frame.width);
        put(self.request, at + 20, child.layout.min_size.width);
        put(self.request, at + 24, child.layout.max_size.width);
    }
    pub fn run(self: WrappedPlan) WrappedResult {
        var result: WrappedResult = .{ .bytes = @splat(0xa5) };
        if (self.policy(self.request, &result.bytes) != 32 or read(&result.bytes, 0) != 1 or read(&result.bytes, 4) > 5) @panic("invalid wrapped measurement result");
        absent(&result.bytes, 20, 32);
        const action = result.action();
        if (action == .done) {
            absent(&result.bytes, 8, 12);
            absent(&result.bytes, 16, 20);
        } else {
            absent(&result.bytes, 12, 16);
            if (action == .intrinsic or action == .paragraph) {
                absent(&result.bytes, 8, 12);
                if (read(self.request, 40) & @as(u32, if (action == .intrinsic) 1 else 2) != 0) @panic("repeated wrapped measurement");
                if (action == .intrinsic) absent(&result.bytes, 16, 20);
            } else {
                const index = result.index();
                if (index >= self.count or read(self.request, 288 + index * 32) & 1 == 0 or read(self.request, 304 + index * 32) & @as(u32, if (action == .child_height) 2 else 1) != 0) @panic("invalid wrapped child continuation");
            }
        }
        return result;
    }
    pub fn reply(self: WrappedPlan, result: WrappedResult, value: f32) void {
        switch (result.action()) {
            .done => unreachable,
            .intrinsic, .paragraph => {
                const intrinsic = result.action() == .intrinsic;
                put(self.request, if (intrinsic) 32 else 36, value);
                word(self.request, 40, read(self.request, 40) | @as(u32, if (intrinsic) 1 else 2));
            },
            .row_width, .bubble_width, .child_height => {
                const at = 288 + result.index() * 32;
                const height = result.action() == .child_height;
                put(self.request, at + @as(usize, if (height) 12 else 8), value);
                word(self.request, at + 16, read(self.request, at + 16) | @as(u32, if (height) 2 else 1));
            },
        }
    }
};
pub const ChildAction = enum(u32) { done, main, cross };
pub const ChildResult = struct {
    bytes: [64]u8,
    pub fn action(self: ChildResult) ChildAction {
        return @enumFromInt(read(&self.bytes, 4));
    }
    pub fn dimension(self: ChildResult) usize {
        return read(&self.bytes, 8);
    }
    pub fn child(self: ChildResult) container.Child {
        return .{ .flags = read(&self.bytes, 16), .grow = float(&self.bytes, 20), .main = float(&self.bytes, 24), .cross = float(&self.bytes, 28), .offset_main = float(&self.bytes, 32), .offset_cross = float(&self.bytes, 36), .min_main = float(&self.bytes, 40), .max_main = float(&self.bytes, 44), .min_cross = float(&self.bytes, 48), .max_cross = float(&self.bytes, 52), .measured_main = float(&self.bytes, 56), .measured_cross = float(&self.bytes, 60) };
    }
};
pub const ChildPlan = struct {
    policy: Policy,
    request: [80]u8 = @splat(0),
    pub fn init(widget: widgets.Widget, tokens: tokens_model.DesignTokens, axis: u8, fill: bool, stretch: bool, measure_cross: bool) ChildPlan {
        var self: ChildPlan = .{ .policy = tokens.measurement_coordination_policy.? };
        self.request[0..7].* = .{ 35, 1, axis, @as(u8, @intFromBool(fill)) | (@as(u8, @intFromBool(stretch)) << 1) | (@as(u8, @intFromBool(measure_cross)) << 2) | (@as(u8, @intFromBool(tokens.controls.tabs_indicator == .underline)) << 3) | (@as(u8, @intFromBool(tokens.metrics.tabs_list_full_width)) << 4), @intFromEnum(widget.kind), @intFromEnum(widget.variant), @import("render_plan_policy.zig").numericFlags() };
        const values = [_]f32{ widget.frame.x, widget.frame.y, widget.frame.width, widget.frame.height, widget.layout.min_size.width, widget.layout.min_size.height, widget.layout.max_size.width, widget.layout.max_size.height, widget.layout.grow };
        for (values, 0..) |value, i| put(&self.request, 16 + i * 4, value);
        return self;
    }
    pub fn run(self: ChildPlan) ChildResult {
        var result: ChildResult = .{ .bytes = @splat(0xa5) };
        if (self.policy(&self.request, &result.bytes) != 64 or read(&result.bytes, 0) != 1 or read(&result.bytes, 4) > 2) @panic("invalid axis measurement result");
        absent(&result.bytes, 12, 16);
        if (result.action() == .done) {
            absent(&result.bytes, 8, 12);
            if (read(&result.bytes, 16) > 31) @panic("invalid axis child flags");
        } else {
            absent(&result.bytes, 16, 64);
            if (result.dimension() > 1 or read(&self.request, 8) & @as(u32, if (result.action() == .main) 1 else 2) != 0) @panic("invalid axis continuation");
        }
        return result;
    }
    pub fn reply(self: *ChildPlan, result: ChildResult, size: geometry.SizeF) void {
        const main = result.action() == .main;
        std.debug.assert(result.action() != .done);
        put(&self.request, if (main) 52 else 56, if (result.dimension() == 0) size.width else size.height);
        word(&self.request, 8, read(&self.request, 8) | @as(u32, if (main) 1 else 2));
    }
};
pub const SpanResult = struct {
    bytes: [16]u8,
    pub fn pending(self: SpanResult) bool {
        return read(&self.bytes, 4) == 1;
    }
    pub fn index(self: SpanResult) usize {
        return read(&self.bytes, 8);
    }
    pub fn found(self: SpanResult) bool {
        return read(&self.bytes, 12) == 1;
    }
};
pub const SpanPlan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, widget: widgets.Widget, depth: usize, limit: usize) !SpanPlan {
        const count = widget.children.len;
        const request = try allocator.alloc(u8, try std.math.add(usize, 16, try std.math.mul(usize, count, 4)));
        @memset(request, 0);
        request[0..4].* = .{ 36, 1, @intFromEnum(widget.kind), @intFromBool(widget.spans.len > 0) };
        word(request, 4, std.math.cast(u32, depth) orelse std.math.maxInt(u32));
        word(request, 8, @intCast(limit));
        word(request, 12, std.math.cast(u32, count) orelse @panic("span child count exceeds wire range"));
        return .{ .allocator = allocator, .policy = policy, .request = request, .count = count };
    }
    pub fn deinit(self: SpanPlan) void {
        self.allocator.free(self.request);
    }
    pub fn run(self: SpanPlan) SpanResult {
        var result: SpanResult = .{ .bytes = @splat(0xa5) };
        if (self.policy(self.request, &result.bytes) != 16 or read(&result.bytes, 0) != 1 or read(&result.bytes, 4) > 1 or read(&result.bytes, 12) > 1) @panic("invalid span subtree result");
        if (result.pending()) {
            if (result.index() >= self.count or read(self.request, 16 + result.index() * 4) != 0) @panic("invalid span child continuation");
            absent(&result.bytes, 12, 16);
        } else absent(&result.bytes, 8, 12);
        return result;
    }
    pub fn reply(self: SpanPlan, result: SpanResult, found: bool) void {
        std.debug.assert(result.pending());
        word(self.request, 16 + result.index() * 4, if (found) 2 else 1);
    }
};
pub const AxisAction = enum(u32) { done, child, first_spans, second_spans, wrapped };
pub const AxisResult = struct {
    bytes: [32]u8,
    pub fn action(self: AxisResult) AxisAction {
        return @enumFromInt(read(&self.bytes, 4));
    }
    pub fn index(self: AxisResult) usize {
        return read(&self.bytes, 8);
    }
    pub fn width(self: AxisResult) f32 {
        return float(&self.bytes, 16);
    }
};
pub const AxisPlan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    result: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, count: usize, content: geometry.RectF, axis: u8, main: u8, cross: u8, gap: f32) !AxisPlan {
        const request = try allocator.alloc(u8, try std.math.add(usize, 64, try std.math.mul(usize, count, 64)));
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, try std.math.add(usize, 44, try std.math.mul(usize, count, 16)));
        @memset(request, 0);
        request[0..3].* = .{ 37, 1, @import("render_plan_policy.zig").numericFlags() };
        word(request, 4, std.math.cast(u32, count) orelse @panic("axis child count exceeds wire range"));
        request[16..24].* = .{ 5, 0, axis, main, cross, 0, 0, 0 };
        word(request, 24, @intCast(count));
        for ([_]f32{ content.x, content.y, content.width, content.height, gap }, 0..) |value, i| put(request, 28 + i * 4, value);
        return .{ .allocator = allocator, .policy = policy, .request = request, .result = result, .count = count };
    }
    pub fn deinit(self: AxisPlan) void {
        self.allocator.free(self.result);
        self.allocator.free(self.request);
    }
    pub fn setFlow(self: AxisPlan, index: usize, flow: bool) void {
        word(self.request, 64 + index * 64, @intFromBool(flow));
    }
    pub fn run(self: AxisPlan) AxisResult {
        @memset(self.result, 0xa5);
        const written = self.policy(self.request, self.result);
        if (written < 32 or read(self.result, 0) != 1 or read(self.result, 4) > 4) @panic("invalid axis coordination result");
        const result: AxisResult = .{ .bytes = self.result[0..32].* };
        absent(&result.bytes, 12, 16);
        absent(&result.bytes, 20, 32);
        if (result.action() == .done) {
            if (written != self.result.len or read(self.result, 32) != self.count) @panic("invalid axis allocation length");
            absent(&result.bytes, 8, 20);
        } else {
            const index = result.index();
            if (written != 32 or index >= self.count or read(self.request, 64 + index * 64) & 1 == 0) @panic("invalid axis child continuation");
            const state = read(self.request, 112 + index * 64);
            const bit: u32 = switch (result.action()) {
                .done => unreachable,
                .child => 1,
                .first_spans => 2,
                .second_spans => 4,
                .wrapped => 8,
            };
            if (state & bit != 0) @panic("repeated axis coordination query");
            if (result.action() != .wrapped) absent(&result.bytes, 16, 20);
        }
        return result;
    }
    pub fn replyChild(self: AxisPlan, result: AxisResult, child: container.Child) void {
        std.debug.assert(result.action() == .child);
        const at = 64 + result.index() * 64;
        word(self.request, at, child.flags);
        const values = [_]f32{ child.grow, child.main, child.cross, child.offset_main, child.offset_cross, child.min_main, child.max_main, child.min_cross, child.max_cross, child.measured_main, child.measured_cross };
        for (values, 0..) |value, i| put(self.request, at + 4 + i * 4, value);
        word(self.request, at + 48, 1);
    }
    pub fn replySpans(self: AxisPlan, result: AxisResult, found: bool) void {
        std.debug.assert(result.action() == .first_spans or result.action() == .second_spans);
        const at = 64 + result.index() * 64;
        const first = result.action() == .first_spans;
        word(self.request, at + @as(usize, if (first) 52 else 56), @intFromBool(found));
        word(self.request, at + 48, read(self.request, at + 48) | @as(u32, if (first) 2 else 4));
    }
    pub fn replyHeight(self: AxisPlan, result: AxisResult, height: f32) void {
        std.debug.assert(result.action() == .wrapped);
        const at = 64 + result.index() * 64;
        put(self.request, at + 60, height);
        word(self.request, at + 48, read(self.request, at + 48) | 8);
    }
    pub fn used(self: AxisPlan) f32 {
        return float(self.result, 36);
    }
    pub fn overflow(self: AxisPlan) f32 {
        return float(self.result, 40);
    }
    pub fn frame(self: AxisPlan, index: usize) geometry.RectF {
        const at = 44 + index * 16;
        return .init(float(self.result, at), float(self.result, at + 4), float(self.result, at + 8), float(self.result, at + 12));
    }
};
