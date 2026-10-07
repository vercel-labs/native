//! Copied layout programs. Native retains source widgets and all output slots.
const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const events = @import("events.zig");
pub const Policy = @import("surface_layout_policy.zig").Policy;
pub const max_depth = 32;
pub const Route = enum(u8) { leaf, horizontal, button_group, tabs, vertical, grid, virtual_grid, virtual_vertical, scroll, split, accordion, alert, stack, spans };
pub fn referenceRoute(widget: widgets.Widget) Route {
    return switch (widget.kind) {
        .row, .breadcrumb, .pagination, .radio_group, .toggle_group, .data_row, .list_item => .horizontal,
        .button_group => .button_group,
        .tabs => .tabs,
        .column, .input_group, .tree, .menu_surface, .dropdown_menu => .vertical,
        .grid => if (widget.layout.virtualized) .virtual_grid else .grid,
        .data_grid, .table, .list => if (widget.layout.virtualized) .virtual_vertical else .vertical,
        .scroll_view => if (widget.layout.virtualized) .virtual_vertical else .scroll,
        .split => .split,
        .accordion => .accordion,
        .alert => .alert,
        .stack, .bubble, .card, .resizable, .panel, .popover, .dialog, .drawer, .sheet => .stack,
        .text => .spans,
        .data_cell => if (widget.spans.len > 0) .spans else .horizontal,
        .icon, .image, .avatar, .badge, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .tooltip, .menu_item, .status_bar, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .progress, .separator, .skeleton, .spinner, .chart, .split_divider, .media_surface, .terminal => .leaf,
    };
}
fn word(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn integer(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn put(bytes: []u8, at: usize, value: f32) void {
    word(bytes, at, @bitCast(value));
}
fn float(bytes: []const u8, at: usize) f32 {
    return @bitCast(read(bytes, at));
}
fn size(base: usize, count: usize, stride: usize) !usize {
    return std.math.add(usize, base, try std.math.mul(usize, count, stride));
}
fn absent(bytes: []const u8, first: usize, end: usize) void {
    if (!std.mem.allEqual(u8, bytes[first..end], 0)) @panic("invalid absent layout fields");
}
fn rect(bytes: []const u8, at: usize) geometry.RectF {
    return .init(float(bytes, at), float(bytes, at + 4), float(bytes, at + 8), float(bytes, at + 12));
}
fn putRect(bytes: []u8, at: usize, value: geometry.RectF) void {
    for ([_]f32{ value.x, value.y, value.width, value.height }, 0..) |v, i| put(bytes, at + i * 4, v);
}
pub fn admission(policy: Policy, widget: widgets.Widget, depth: usize, len: usize, capacity: usize) error{ WidgetDepthExceeded, WidgetLayoutListFull }!Route {
    var request: [32]u8 = @splat(0);
    request[0..4].* = .{ 40, 1, @intFromEnum(widget.kind), @as(u8, @intFromBool(widget.layout.virtualized)) | (@as(u8, @intFromBool(widget.spans.len > 0)) << 1) };
    integer(&request, 8, depth);
    integer(&request, 16, len);
    integer(&request, 24, capacity);
    var result: [4]u8 = @splat(0xa5);
    if (policy(&request, &result) != 4 or result[0] > 2 or result[1] > @intFromEnum(Route.spans)) @panic("invalid layout admission result");
    absent(&result, 2, 4);
    if (result[0] != 0) absent(&result, 1, 4);
    return switch (result[0]) {
        0 => @enumFromInt(result[1]),
        1 => error.WidgetDepthExceeded,
        2 => error.WidgetLayoutListFull,
        else => unreachable,
    };
}
pub const Mode = enum(u8) { stack, modal, anchor, split, spans, slide };
pub const Action = enum(u32) { done, bounds, fraction };
pub const Result = struct {
    bytes: [32]u8,
    pub fn action(self: Result) Action {
        return @enumFromInt(read(&self.bytes, 4));
    }
    pub fn index(self: Result) usize {
        return read(&self.bytes, 8);
    }
    pub fn span(self: Result) usize {
        return read(&self.bytes, 12);
    }
    pub fn available(self: Result) f32 {
        return float(&self.bytes, 16);
    }
    pub fn firstMin(self: Result) f32 {
        return float(&self.bytes, 20);
    }
    pub fn secondMin(self: Result) f32 {
        return float(&self.bytes, 24);
    }
};
pub const ChildPlan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    result: []u8,
    count: usize,
    span_count: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, count: usize, span_count: usize, mode: Mode, content: geometry.RectF, gap: f32) !ChildPlan {
        const request = try allocator.alloc(u8, try size(try size(64, count, 64), span_count, 24));
        errdefer allocator.free(request);
        const result = try allocator.alloc(u8, try size(32, count, 32));
        @memset(request, 0);
        request[0..4].* = .{ 41, 1, @intFromEnum(mode), @import("render_plan_policy.zig").numericFlags() };
        word(request, 4, std.math.cast(u32, count) orelse @panic("layout child count exceeds wire range"));
        word(request, 8, std.math.cast(u32, span_count) orelse @panic("layout span count exceeds wire range"));
        putRect(request, 16, content);
        put(request, 32, gap);
        return .{ .allocator = allocator, .policy = policy, .request = request, .result = result, .count = count, .span_count = span_count };
    }
    pub fn deinit(self: ChildPlan) void {
        self.allocator.free(self.request);
        self.allocator.free(self.result);
    }
    pub fn setChild(self: ChildPlan, index: usize, child: widgets.Widget, fills: bool) void {
        const at = 64 + index * 64;
        word(self.request, at, @intFromEnum(child.kind));
        word(self.request, at + 4, @as(u32, @intFromBool(child.layout.anchor != null)) | (@as(u32, @intFromBool(fills)) << 1));
        putRect(self.request, at + 8, child.frame);
        for ([_]f32{ child.layout.min_size.width, child.layout.min_size.height, child.layout.max_size.width, child.layout.max_size.height }, 0..) |v, i| put(self.request, at + 24 + i * 4, v);
    }
    pub fn setNode(self: ChildPlan, index: usize, node: events.WidgetLayoutNode) void {
        self.setChild(index, node.widget, false);
        const at = 64 + index * 64;
        putRect(self.request, at + 8, node.frame);
        integer(self.request, at + 40, node.depth);
        std.mem.writeInt(u64, self.request[at + 48 ..][0..8], if (node.parent_index) |parent| parent else std.math.maxInt(u64), .little);
    }
    pub fn setRoot(self: ChildPlan, index: usize) void {
        word(self.request, 44, std.math.cast(u32, index) orelse @panic("layout slide root exceeds wire range"));
    }
    fn spanAt(self: ChildPlan, index: usize) usize {
        return 64 + self.count * 64 + index * 24;
    }
    pub fn setLink(self: ChildPlan, index: usize, link: bool) void {
        word(self.request, self.spanAt(index), @intFromBool(link));
    }
    pub fn run(self: ChildPlan) Result {
        @memset(self.result, 0xa5);
        const written = self.policy(self.request, self.result);
        if (written < 32 or read(self.result, 0) != 1 or read(self.result, 4) > 2) @panic("invalid layout child result");
        const result: Result = .{ .bytes = self.result[0..32].* };
        if (result.action() == .done) {
            if (written != self.result.len or result.index() > self.count) @panic("invalid layout child program length");
            absent(&result.bytes, 12, 32);
            var scratch = std.heap.stackFallback(256, std.heap.page_allocator);
            const validator_allocator = scratch.get();
            const seen = validator_allocator.alloc(bool, self.count) catch @panic("layout identity validation allocation failed");
            defer validator_allocator.free(seen);
            @memset(seen, false);
            for (0..result.index()) |i| {
                const at = 32 + i * 32;
                if (read(self.result, at) >= self.count or read(self.result, at + 4) == 0 or read(self.result, at + 4) > 4) @panic("invalid layout child program");
                absent(self.result, at + 12, at + 16);
                if (read(self.result, at + 4) & 1 == 0) absent(self.result, at + 8, at + 12);
                // Each source child/output slot is applied at most once.
                const source_index = read(self.result, at);
                if (seen[source_index]) @panic("duplicate layout child identity");
                seen[source_index] = true;
            }
            absent(self.result, 32 + result.index() * 32, self.result.len);
        } else {
            if (written != 32) @panic("invalid layout continuation length");
            if (result.action() == .bounds) {
                if (self.request[2] != @intFromEnum(Mode.spans) or result.index() >= self.count or result.span() >= self.span_count or read(self.request, self.spanAt(result.span())) != 1 or read(self.request, self.spanAt(result.span()) + 4) != 0) @panic("invalid span bound continuation");
                absent(&result.bytes, 16, 32);
            } else {
                if ((self.request[2] != @intFromEnum(Mode.split) and self.request[2] != @intFromEnum(Mode.slide)) or read(self.request, 12) != 0) @panic("invalid split fraction continuation");
                absent(&result.bytes, 8, 16);
                absent(&result.bytes, 28, 32);
            }
        }
        return result;
    }
    pub fn replyBounds(self: ChildPlan, result: Result, bounds: ?geometry.RectF) void {
        std.debug.assert(result.action() == .bounds);
        const at = self.spanAt(result.span());
        word(self.request, at + 4, if (bounds == null) 1 else 2);
        if (bounds) |bounds_frame| putRect(self.request, at + 8, bounds_frame);
    }
    pub fn replyFraction(self: ChildPlan, result: Result, fraction: f32) void {
        std.debug.assert(result.action() == .fraction);
        word(self.request, 12, 1);
        put(self.request, 40, fraction);
    }
    pub fn source(self: ChildPlan, index: usize) usize {
        return read(self.result, 32 + index * 32);
    }
    pub fn flags(self: ChildPlan, index: usize) u32 {
        return read(self.result, 36 + index * 32);
    }
    pub fn value(self: ChildPlan, index: usize) f32 {
        return float(self.result, 40 + index * 32);
    }
    pub fn frame(self: ChildPlan, index: usize) geometry.RectF {
        return rect(self.result, 48 + index * 32);
    }
};

pub const RetainedPlan = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    request: []u8,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, nodes: []const events.WidgetLayoutNode) !RetainedPlan {
        const request = try allocator.alloc(u8, try size(32, nodes.len, 24));
        @memset(request, 0);
        request[0..2].* = .{ 42, 1 };
        word(request, 4, std.math.cast(u32, nodes.len) orelse @panic("retained layout count exceeds wire range"));
        const plan: RetainedPlan = .{ .allocator = allocator, .policy = policy, .request = request };
        for (nodes, 0..) |node, i| plan.setNode(i, node);
        return plan;
    }
    pub fn deinit(self: RetainedPlan) void {
        self.allocator.free(self.request);
    }
    pub fn setNode(self: RetainedPlan, index: usize, node: events.WidgetLayoutNode) void {
        const at = 32 + index * 24;
        word(self.request, at, @intFromBool(node.widget.layout.anchor != null));
        word(self.request, at + 4, @intFromEnum(node.widget.kind));
        integer(self.request, at + 8, node.depth);
        std.mem.writeInt(u64, self.request[at + 16 ..][0..8], if (node.parent_index) |parent| parent else std.math.maxInt(u64), .little);
    }
    fn run(self: RetainedPlan, mode: u8, cursor: usize, other: usize) [16]u8 {
        self.request[2] = mode;
        integer(self.request, 8, cursor);
        integer(self.request, 16, other);
        var result: [16]u8 = @splat(0xa5);
        if (self.policy(self.request, &result) != 16 or read(&result, 0) != 1 or read(&result, 4) > 1) @panic("invalid retained layout result");
        if (mode != 2 or read(&result, 4) == 0) absent(&result, 4, 8);
        return result;
    }
    pub fn nesting(self: RetainedPlan, index: usize) usize {
        const result = self.run(0, index, 0);
        absent(&result, 12, 16);
        return read(&result, 8);
    }
    pub fn maximum(self: RetainedPlan) usize {
        const result = self.run(1, 0, 0);
        absent(&result, 12, 16);
        return read(&result, 8);
    }
    pub const Next = struct { index: usize, parent: usize };
    pub fn next(self: RetainedPlan, cursor: usize, depth: usize) ?Next {
        const result = self.run(2, cursor, depth);
        if (read(&result, 4) == 0) {
            absent(&result, 8, 16);
            return null;
        }
        const index = read(&result, 8);
        const parent = read(&result, 12);
        if (index < @max(1, cursor) or index >= read(self.request, 4) or parent >= read(self.request, 4)) @panic("invalid retained layout selection");
        return .{ .index = index, .parent = parent };
    }
    pub fn advance(self: RetainedPlan, cursor: usize, len: usize) usize {
        const result = self.run(3, cursor, len);
        const next_cursor = std.math.cast(usize, std.mem.readInt(u64, result[8..16], .little)) orelse @panic("retained cursor exceeds host range");
        if (next_cursor <= cursor) @panic("retained layout made no progress");
        return next_cursor;
    }
};
