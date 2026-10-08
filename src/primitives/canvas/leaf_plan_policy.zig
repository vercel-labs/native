//! Copied leaf programs and geometry. Resource pointers and retained buffers stay native.
const std = @import("std");
const geometry = @import("geometry");
const tokens_model = @import("tokens.zig");
const widgets = @import("widgets.zig");
const drawing = @import("drawing.zig");
const Tokens = tokens_model.DesignTokens;
const Policy = @import("surface_layout_policy.zig").Policy;
pub const Family = enum(u8) { image, avatar, badge, separator, divider, status, skeleton, wash, row_line, table };
pub const Opcode = enum(u32) { fill, stroke, clip, image, unclip, text, border_query, content_query, icon, focus, status_separator, status_text, line, rows, accent_fill };
pub const Facts = struct { text: bool = false, image: bool = false, cover: bool = false, icon: bool = false, focused: bool = false, hovered: bool = false, pressed: bool = false, scalar: f32 = 0 };
pub const Command = struct { opcode: Opcode, slot: u32, id: u64 };
fn word(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}
fn put(b: []u8, at: usize, v: f32) void {
    word(b, at, @bitCast(v));
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn get(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn invoke(t: Tokens, request: []const u8, result: []u8) void {
    const policy = t.control_command_policy orelse @panic("missing leaf plan owner");
    if (policy(request, result) != result.len) @panic("invalid leaf plan result length");
}
pub const Program = struct {
    count: usize,
    commands: [6]Command,
    pub fn init(t: Tokens, family: Family, phase: u8, widget: widgets.Widget, facts: Facts) Program {
        var request: [40]u8 = @splat(0);
        request[0..6].* = .{ 49, 0, 1, @intFromEnum(family), phase, @as(u8, @intFromBool(facts.text)) | (@as(u8, @intFromBool(facts.image)) << 1) | (@as(u8, @intFromBool(facts.cover)) << 2) | (@as(u8, @intFromBool(facts.icon)) << 3) | (@as(u8, @intFromBool(facts.focused)) << 4) | (@as(u8, @intFromBool(facts.hovered)) << 5) | (@as(u8, @intFromBool(facts.pressed)) << 6) };
        inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| put(&request, 8 + i * 4, @field(widget.frame, name));
        put(&request, 24, facts.scalar);
        std.mem.writeInt(u64, request[28..36], widget.id, .little);
        var result: [104]u8 = @splat(0xa5);
        invoke(t, &request, &result);
        const count = read(&result, 4);
        if (read(&result, 0) != 1 or count > 6) @panic("invalid leaf program header");
        if (!std.mem.allEqual(u8, result[8 + count * 16 ..], 0)) @panic("invalid leaf program tail");
        var p: Program = .{ .count = count, .commands = undefined };
        for (p.commands[0..count], 0..) |*command, i| {
            const at = 8 + i * 16;
            const op = read(&result, at);
            const slot = read(&result, at + 4);
            if (op > @intFromEnum(Opcode.accent_fill) or slot > 9) @panic("invalid leaf drawing capability");
            command.* = .{ .opcode = @enumFromInt(op), .slot = slot, .id = std.mem.readInt(u64, result[at + 8 ..][0..8], .little) };
        }
        return p;
    }
};
pub const GeometryOperation = enum(u8) { raw, text, badge_content, separator, divider, status_separator, status_text, row_line, pill_fallback };
pub const Geometry = struct { admitted: bool, rects: [2]geometry.RectF, points: [2]geometry.PointF, max_width: f32, line_height: f32, scalar: f32, sampling: drawing.ImageSampling };
pub fn payload(t: Tokens, op: GeometryOperation, frame: geometry.RectF, values: [8]f32, flags: u8, sampling: drawing.ImageSampling) Geometry {
    var request: [112]u8 = @splat(0);
    request[0..8].* = .{ 49, 1, 1, @intFromEnum(op), @import("render_plan_policy.zig").numericFlags(), @import("control_geometry_policy.zig").signalingFlags(), flags, @as(u8, @intFromBool(t.pixel_snap.geometry)) | (@as(u8, @intFromBool(t.pixel_snap.text)) << 1) };
    put(&request, 56, t.pixel_snap.scale);
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| put(&request, 8 + i * 4, @field(frame, name));
    for (values, 0..) |v, i| put(&request, 24 + i * 4, v);
    word(&request, 76, @intFromEnum(sampling));
    var result: [80]u8 = @splat(0xa5);
    invoke(t, &request, &result);
    if (read(&result, 0) != 1 or read(&result, 4) > 1 or read(&result, 68) > 1 or !std.mem.allEqual(u8, result[72..], 0)) @panic("invalid leaf geometry result");
    return .{ .admitted = read(&result, 4) == 1, .rects = .{ rect(&result, 8), rect(&result, 24) }, .points = .{ .init(get(&result, 40), get(&result, 44)), .init(get(&result, 48), get(&result, 52)) }, .max_width = get(&result, 56), .line_height = get(&result, 60), .scalar = get(&result, 64), .sampling = @enumFromInt(read(&result, 68)) };
}
fn rect(b: []const u8, at: usize) geometry.RectF {
    return .init(get(b, at), get(b, at + 4), get(b, at + 8), get(b, at + 12));
}
pub fn copiedFrame(t: Tokens, value: geometry.RectF) geometry.RectF {
    return payload(t, .raw, value, @splat(0), 0, .nearest).rects[0];
}
pub fn pillFallback(t: Tokens, value: geometry.RectF) f32 {
    return payload(t, .pill_fallback, value, @splat(0), 0, .nearest).scalar;
}
pub const RowPlan = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, t: Tokens, children: anytype, parent: ?usize) !RowPlan {
        const count = std.math.cast(u32, children.len) orelse @panic("leaf row count exceeds wire range");
        const request = try allocator.alloc(u8, try std.math.add(usize, 24, try std.math.mul(usize, children.len, 16)));
        defer allocator.free(request);
        const result = try allocator.alloc(u8, try std.math.add(usize, 8, try std.math.mul(usize, children.len, 4)));
        errdefer allocator.free(result);
        @memset(request, 0);
        request[0..4].* = .{ 49, 2, 1, @intFromBool(parent != null) };
        word(request, 8, count);
        std.mem.writeInt(u64, request[16..24], parent orelse 0, .little);
        for (children, 0..) |child, i| {
            const at = 24 + i * 16;
            const widget = if (@hasField(@TypeOf(child), "widget")) child.widget else child;
            word(request, at, @intFromEnum(widget.kind));
            word(request, at + 4, @intFromBool(widget.semantics.hidden));
            if (@hasField(@TypeOf(child), "parent_index")) std.mem.writeInt(u64, request[at + 8 ..][0..8], child.parent_index orelse std.math.maxInt(u64), .little);
        }
        @memset(result, 0xa5);
        invoke(t, request, result);
        const length = read(result, 4);
        if (read(result, 0) != 1 or length > count or !std.mem.allEqual(u8, result[8 + length * 4 ..], 0)) @panic("invalid leaf row plan");
        const plan: RowPlan = .{ .allocator = allocator, .bytes = result, .count = length };
        var previous: ?usize = null;
        for (0..length) |i| {
            const index_ = plan.index(i);
            if (index_ >= count or (previous != null and index_ <= previous.?)) @panic("invalid leaf row order");
            previous = index_;
        }
        return plan;
    }
    pub fn deinit(self: RowPlan) void {
        self.allocator.free(self.bytes);
    }
    pub fn index(self: RowPlan, ordinal: usize) usize {
        return read(self.bytes, 8 + ordinal * 4);
    }
};
