//! Native-owned storage for portable per-node measurement continuations.
const std = @import("std");
const geometry = @import("geometry");
const metric = @import("widget_metric_policy.zig");
const widgets = @import("widgets.zig");
const tokens_model = @import("tokens.zig");
pub const Action = enum(u32) { done, title, row, child, wrapped };
pub const Result = struct {
    bytes: [32]u8,
    pub fn action(self: Result) Action {
        return @enumFromInt(read(&self.bytes, 4));
    }
    pub fn index(self: Result) usize {
        return read(&self.bytes, 8);
    }
    pub fn size(self: Result) geometry.SizeF {
        return .init(float(&self.bytes, 12), float(&self.bytes, 16));
    }
    pub fn textSize(self: Result) f32 {
        return float(&self.bytes, 20);
    }
    pub fn width(self: Result) f32 {
        return float(&self.bytes, 24);
    }
};
pub const Plan = struct {
    allocator: std.mem.Allocator,
    policy: @import("surface_layout_policy.zig").Policy,
    request: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, widget: widgets.Widget, tokens: tokens_model.DesignTokens, depth: usize, limit: usize, selected: bool) !Plan {
        const count = widget.children.len;
        const request = try allocator.alloc(u8, try std.math.add(usize, 288, try std.math.mul(usize, count, 44)));
        @memset(request, 0);
        request[0] = 33;
        request[1] = 1;
        request[2] = @intFromBool(bothNaNMaximumKeepsSignaling());
        request[3] = @as(u8, @intFromBool(widget.layout.virtualized)) | (@as(u8, @intFromBool(widget.layout.padding_is_kind_default)) << 1) | (@as(u8, @intFromBool(selected)) << 2) | (@as(u8, @intFromBool(widget.scroll_axes == .horizontal)) << 3) | (@as(u8, @intFromBool(tokens.controls.button_group_style == .detached)) << 4);
        word(request, 4, std.math.cast(u32, depth) orelse std.math.maxInt(u32));
        word(request, 8, @intCast(limit));
        word(request, 12, std.math.cast(u32, count) orelse @panic("intrinsic measurement child count exceeds wire range"));
        put(request, 32, tokens.metrics.button_group_gap);
        put(request, 36, tokens.metrics.tabs_gap);
        std.mem.writeInt(u64, request[40..48], widget.layout.columns, .little);
        put(request, 48, @floatFromInt(widget.layout.columns));
        put(request, 52, @floatFromInt(widget.layout.columns -| 1));
        put(request, 56, tokens.spacing.xl);
        const registers = metric.Request.init(.intrinsic, widget, tokens, 0);
        @memcpy(request[64..288], &registers.bytes);
        return .{ .allocator = allocator, .policy = tokens.intrinsic_layout_policy.?, .request = request, .count = count };
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.request);
    }
    pub fn setChild(self: Plan, index: usize, child: widgets.Widget, flow: bool) void {
        const at = 288 + index * 40;
        word(self.request, at, @as(u32, @intFromBool(flow)) | (@as(u32, @intFromBool(child.kind == .separator)) << 1));
        const values = [_]f32{ child.frame.width, child.frame.height, child.layout.min_size.width, child.layout.min_size.height, child.layout.max_size.width, child.layout.max_size.height };
        for (values, 0..) |value, i| put(self.request, at + 12 + i * 4, value);
    }
    pub fn reply(self: Plan, result: Result, size: geometry.SizeF) void {
        switch (result.action()) {
            .done => unreachable,
            .title => {
                put(self.request, 20, size.width);
                word(self.request, 16, read(self.request, 16) | 1);
            },
            .row => {
                put(self.request, 24, size.width);
                put(self.request, 28, size.height);
                word(self.request, 16, read(self.request, 16) | 2);
            },
            .child => {
                const index = result.index();
                put(self.request, 292 + index * 40, size.width);
                put(self.request, 296 + index * 40, size.height);
                word(self.request, 288 + self.count * 40 + index * 4, 1);
            },
            .wrapped => {
                const index = result.index();
                put(self.request, 324 + index * 40, size.height);
                word(self.request, 288 + self.count * 40 + index * 4, 3);
            },
        }
    }
    pub fn run(self: Plan) Result {
        var result: Result = .{ .bytes = @splat(0xa5) };
        if (self.policy(self.request, &result.bytes) != 32 or read(&result.bytes, 0) != 1 or read(&result.bytes, 4) > 4 or read(&result.bytes, 28) != 0) @panic("invalid intrinsic measurement result");
        const action = result.action();
        const index = result.index();
        if (action == .child or action == .wrapped) {
            if (index >= self.count or read(self.request, 288 + index * 40) & 1 == 0 or read(self.request, 288 + self.count * 40 + index * 4) != @as(u32, if (action == .child) 0 else 1)) @panic("invalid intrinsic child continuation");
        } else if (index != 0) @panic("invalid intrinsic measurement index");
        const ranges: []const [2]usize = switch (action) {
            .done => &.{.{ 20, 32 }},
            .title => &.{ .{ 12, 20 }, .{ 24, 32 } },
            .row, .child => &.{.{ 12, 32 }},
            .wrapped => &.{ .{ 12, 24 }, .{ 28, 32 } },
        };
        for (ranges) |range| if (!std.mem.allEqual(u8, result.bytes[range[0]..range[1]], 0)) @panic("invalid absent intrinsic measurement fields");
        if (action == .title and read(self.request, 16) & 1 != 0 or action == .row and read(self.request, 16) & 2 != 0) @panic("repeated intrinsic measurement continuation");
        return result;
    }
};
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
// LLVM's target maximum can retain the second signaling word only when both
// operands are NaN. This representation fact is distinct from the one-NaN probe.
noinline fn bothNaNMaximumKeepsSignaling() bool {
    var words = [_]u32{ 0x7fc12345, 0x7f812345 };
    const input: *volatile [2]u32 = &words;
    const values = input.*;
    var result: u32 = 0;
    const output: *volatile u32 = &result;
    output.* = @bitCast(@max(@as(f32, @bitCast(values[0])), @as(f32, @bitCast(values[1]))));
    return output.* == values[1];
}
