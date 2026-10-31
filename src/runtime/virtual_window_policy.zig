//! Owned virtual-window plans. Compiler output contains bounded ordinals,
//! never layout/model pointers; copy it before invoking any other policy.
const std = @import("std");
const canvas = @import("canvas");
const limits = @import("canvas_limits.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
const max_nodes = limits.max_canvas_widget_nodes_per_view;
const max_lists = canvas.max_virtual_windows;
const missing = std.math.maxInt(u32);
pub const List = struct { node: ?usize, coverage: enum { skip, fixed, variable }, measure: bool, rows: []const u8 };
pub const Layout = struct {
    bytes: [16 + max_lists * 16 + max_lists * max_nodes * 4]u8 = undefined,
    count: usize,
    pub fn init(policy: Policy, records: []const canvas.VirtualWindowRecord, nodes: []const canvas.WidgetLayoutNode) Layout {
        if (records.len > max_lists or nodes.len > max_nodes) @panic("virtual window plan budget exceeded");
        var request: [16 + (max_lists + max_nodes) * 24]u8 = @splat(0);
        request[0] = 97;
        put(&request, 4, @intCast(records.len));
        put(&request, 8, @intCast(nodes.len));
        for (records, 0..) |record, i| {
            const at = 16 + i * 24;
            integer(&request, at, record.id);
            integer(&request, at + 8, record.item_count);
            put(&request, at + 16, @intFromBool(record.variable));
        }
        for (nodes, 0..) |node, i| {
            const at = 16 + (records.len + i) * 24;
            integer(&request, at, node.widget.id);
            integer(&request, at + 8, node.parent_index orelse 0);
            const viewport = node.frame.inset(node.widget.layout.padding).normalized();
            put(&request, at + 16, @as(u32, @intFromBool(node.parent_index != null)) |
                (@as(u32, @intFromBool(node.widget.layout.anchor != null)) << 1) |
                (@as(u32, @intFromBool(node.widget.semantics.list_item_index != null)) << 2) |
                (@as(u32, @intFromBool(viewport.isEmpty())) << 3));
        }
        var self = Layout{ .count = records.len };
        const length = policy(request[0 .. 16 + (records.len + nodes.len) * 24], &self.bytes);
        if (length < 16 or length > self.bytes.len or !std.mem.eql(u8, self.bytes[0..4], &.{ 97, 0, 0, 0 }) or
            get(&self.bytes, 4) != records.len or get(&self.bytes, 8) > records.len * nodes.len or get(&self.bytes, 12) != 0 or
            length != 16 + records.len * 16 + @as(usize, get(&self.bytes, 8)) * 4) @panic("invalid virtual window layout result");
        var consumed: usize = 0;
        for (records, 0..) |record, i| {
            const at = 16 + i * 16;
            const slot = get(&self.bytes, at);
            const flags = get(&self.bytes, at + 4);
            const coverage = flags & 3;
            const begin = get(&self.bytes, at + 8);
            const count = get(&self.bytes, at + 12);
            if ((slot != missing and (slot >= nodes.len or nodes[slot].widget.id != record.id)) or flags > 6 or coverage > 2 or
                (coverage != 0 and (slot == missing or record.id == 0)) or begin != consumed or count > nodes.len or
                count > get(&self.bytes, 8) - consumed or ((flags & 4 != 0 or count != 0) and (!record.variable or record.item_count == 0 or slot == missing)))
                @panic("invalid virtual window capability");
            var previous: ?usize = null;
            for (0..count) |j| {
                const ordinal = get(&self.bytes, 16 + records.len * 16 + (begin + j) * 4);
                if (ordinal >= nodes.len or (previous != null and ordinal <= previous.?) or nodes[ordinal].parent_index != slot or
                    nodes[ordinal].widget.layout.anchor != null or nodes[ordinal].widget.semantics.list_item_index == null)
                    @panic("invalid virtual measurement capability");
                previous = ordinal;
            }
            consumed += count;
        }
        if (consumed != get(&self.bytes, 8)) @panic("unclaimed virtual measurement result");
        return self;
    }
    pub fn list(self: *const Layout, index: usize) List {
        std.debug.assert(index < self.count);
        const at = 16 + index * 16;
        const slot = get(&self.bytes, at);
        const begin = 16 + self.count * 16 + @as(usize, get(&self.bytes, at + 8)) * 4;
        return .{ .node = if (slot == missing) null else slot, .coverage = @enumFromInt(get(&self.bytes, at + 4) & 3), .measure = get(&self.bytes, at + 4) & 4 != 0, .rows = self.bytes[begin..][0 .. @as(usize, get(&self.bytes, at + 12)) * 4] };
    }
};
pub fn row(rows: []const u8, index: usize) usize {
    return get(rows, index * 4);
}
pub fn contains(policy: Policy, id: u64, records: []const canvas.VirtualWindowRecord) bool {
    if (records.len > max_lists) @panic("virtual identity budget exceeded");
    var request: [16 + max_lists * 8]u8 = @splat(0);
    request[0..2].* = .{ 97, 1 };
    put(&request, 4, @intCast(records.len));
    integer(&request, 8, id);
    for (records, 0..) |record, i| integer(&request, 16 + i * 8, record.id);
    return scalar(policy, request[0 .. 16 + records.len * 8], 1) != 0;
}
pub const Retry = enum(u8) { stop, probe, rebuild };
pub fn retry(policy: Policy, pass: usize, had_correction: bool, undercovered: ?bool) Retry {
    var request: [16]u8 = @splat(0);
    request[0..2].* = .{ 97, 2 };
    put(&request, 4, @intCast(pass));
    put(&request, 8, @as(u32, @intFromBool(had_correction)) |
        (@as(u32, @intFromBool(undercovered != null)) << 1) | (@as(u32, @intFromBool(undercovered orelse false)) << 2));
    return @enumFromInt(scalar(policy, &request, 2));
}
pub fn corrected(policy: Policy, deltas: []const f32) bool {
    if (deltas.len > max_lists) @panic("virtual correction budget exceeded");
    var request: [16 + max_lists * 4]u8 = @splat(0);
    request[0..2].* = .{ 97, 3 };
    put(&request, 4, @intCast(deltas.len));
    for (deltas, 0..) |delta, i| put(&request, 16 + i * 4, @bitCast(delta));
    return scalar(policy, request[0 .. 16 + deltas.len * 4], 1) != 0;
}
pub fn fixedUndercovered(policy: Policy, record: canvas.VirtualWindowRecord, node: canvas.WidgetLayoutNode) bool {
    const builtin = @import("builtin");
    var request: [72]u8 = @splat(0);
    request[0..2].* = .{ 97, 4 };
    put(&request, 4, (canvas.virtual_extent_policy.numericFlags()) |
        @as(u32, if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) 2 else 0));
    for ([_]u64{ record.item_count, record.overscan, record.start_index, record.end_index }, 0..) |v, i| integer(&request, 8 + i * 8, v);
    const viewport = node.frame.inset(node.widget.layout.padding).normalized();
    for ([_]f32{ @floatFromInt(record.item_count), node.widget.layout.virtual_item_extent, record.item_extent, record.gap, viewport.height, node.widget.value }, 0..) |v, i|
        put(&request, 40 + i * 4, @bitCast(v));
    return scalar(policy, &request, 1) != 0;
}
fn scalar(policy: Policy, request: []const u8, maximum: u8) u8 {
    var out: [1]u8 = undefined;
    if (policy(request, &out) != 1 or out[0] > maximum) @panic("invalid virtual window scalar result");
    return out[0];
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn get(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn integer(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
