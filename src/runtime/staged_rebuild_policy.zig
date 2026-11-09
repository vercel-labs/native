//! Copied staged-rebuild programs. Native owns source/retained records and
//! geometry mutations; compiler results are copied before any further call.
const std = @import("std");
const canvas = @import("canvas");
const limits = @import("canvas_limits.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Kind = enum(u8) { done, split, restore_scroll, clamp_scroll, reveal_tabs, anchors };
pub const Step = struct { kind: Kind, index: usize, depth: usize };
pub const Program = struct {
    input: [32 + limits.max_canvas_widget_nodes_per_view * 8]u8 = @splat(0),
    count: usize,
    policy: Policy,
    pub fn init(policy: Policy, count: usize, maximum: usize) Program {
        if (count > limits.max_canvas_widget_nodes_per_view or maximum > 1024) @panic("staged rebuild exceeds budget");
        var self = Program{ .count = count, .policy = policy };
        self.input[0] = 96;
        word(&self.input, 4, count);
        word(&self.input, 16, maximum);
        return self;
    }
    pub fn setNode(self: *Program, index: usize, node: canvas.WidgetLayoutNode, depth: usize) void {
        word(&self.input, 32 + index * 8, @intFromBool(node.widget.kind == .split and node.widget.id != 0));
        word(&self.input, 36 + index * 8, depth);
    }
    pub fn refreshAdmission(self: *Program, nodes: []const canvas.WidgetLayoutNode) void {
        for (nodes, 0..) |node, i| word(&self.input, 32 + i * 8, @intFromBool(node.widget.kind == .split and node.widget.id != 0));
    }
    pub fn next(self: *Program) Step {
        var output: [24]u8 = undefined;
        if (self.policy(self.input[0 .. 32 + self.count * 8], &output) != output.len or
            output[0] != 96 or output[1] != 0 or output[2] > 5 or output[3] != 0 or read(&output, 20) != 0)
            @panic("invalid staged rebuild result");
        const kind: Kind = @enumFromInt(output[2]);
        const index = read(&output, 4);
        const cursor = read(&output, 8);
        const phase = read(&output, 12);
        const depth = read(&output, 16);
        const old_depth = read(&self.input, 12);
        const old_phase = read(&self.input, 20);
        const old_cursor = read(&self.input, 8);
        if (cursor > self.count or phase > 3 or depth > read(&self.input, 16) or
            (kind == .split and (index >= self.count or index < old_cursor or cursor <= index or read(&self.input, 32 + index * 8) != 1 or read(&self.input, 36 + index * 8) != old_depth)) or
            (kind != .split and index != 0) or
            (kind != .done and !(depth > old_depth or (depth == old_depth and (phase > old_phase or (phase == old_phase and cursor > old_cursor))))))
            @panic("invalid staged rebuild progress");
        word(&self.input, 8, cursor);
        word(&self.input, 12, depth);
        word(&self.input, 20, phase);
        return .{ .kind = kind, .index = index, .depth = old_depth };
    }
};
pub const SplitKind = enum(u8) { keep, enter_slide, value_only, slide, relayout };
pub const Split = struct { kind: SplitKind, value: f32 };
pub fn split(policy: Policy, node: canvas.WidgetLayoutNode, previous: ?f32, source: ?f32, armed: bool, dragging: bool) Split {
    var input: [32]u8 = @splat(0);
    input[0..3].* = .{ 96, 1, bit(previous != null, 0) | bit(source != null, 1) | bit(node.widget.children.len != 0, 2) |
        bit(node.widget.resize_duration_ms != 0, 3) | bit(node.widget.resize_origin >= 0, 4) | bit(armed, 5) | bit(dragging, 6) };
    float(&input, 4, node.widget.value);
    float(&input, 8, node.widget.resize_origin);
    float(&input, 12, source orelse 0);
    float(&input, 16, previous orelse 0);
    var output: [12]u8 = undefined;
    if (policy(&input, &output) != output.len or output[0] != 96 or output[1] != 1 or output[2] > 4 or output[3] != 0 or read(&output, 8) != 0)
        @panic("invalid staged split result");
    const kind: SplitKind = @enumFromInt(output[2]);
    if ((kind == .enter_slide and (previous != null or node.widget.children.len == 0)) or
        (kind != .keep and kind != .enter_slide and previous == null) or
        ((kind == .slide or kind == .relayout) and node.widget.children.len == 0))
        @panic("invalid staged split capability");
    return .{ .kind = kind, .value = @bitCast(read(&output, 4)) };
}
fn bit(value: bool, shift: u3) u8 {
    return @as(u8, @intFromBool(value)) << shift;
}
fn word(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @intCast(value), .little);
}
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn float(bytes: []u8, at: usize, value: f32) void {
    word(bytes, at, @as(u32, @bitCast(value)));
}
