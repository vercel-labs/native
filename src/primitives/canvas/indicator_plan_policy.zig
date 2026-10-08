//! Copied spinner plans. Native supplies resolved appearance, platform sine and
//! cosine, drawing capabilities and path storage; geometry, pose and identities
//! stay portable.
const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const tokens_model = @import("tokens.zig");
const drawing = @import("drawing.zig");
const Tokens = tokens_model.DesignTokens;
pub const Mode = enum(u8) { render, anchors };
pub const Action = enum(u32) { done, appearance };
pub const Anchors = struct { count: usize, center: geometry.PointF, arc_id: u64, segment_ids: [15]u64 };
fn word(b: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], value, .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn put(b: []u8, at: usize, value: f32) void {
    word(b, at, @bitCast(value));
}
fn get(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn invoke(t: Tokens, bytes: []const u8, result: []u8) void {
    @memset(result, 0xa5);
    const policy = t.control_command_policy orelse @panic("missing indicator plan owner");
    if (policy(bytes, result) != result.len) @panic("invalid indicator plan result length");
    if (read(result, 0) != 1) @panic("invalid indicator plan result header");
}
fn packet(widget: widgets.Widget, t: Tokens, mode: Mode) [256]u8 {
    var bytes: [256]u8 = @splat(0);
    bytes[0..7].* = .{ 51, @intFromEnum(mode), 1, @import("render_plan_policy.zig").numericFlags(), @intFromEnum(t.metrics.spinner_style), @as(u8, @intFromBool(t.pixel_snap.geometry)) << 1, @import("control_geometry_policy.zig").signalingFlags() };
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| put(&bytes, 8 + i * 4, @field(widget.frame, name));
    put(&bytes, 24, widget.value);
    std.mem.writeInt(u64, bytes[28..36], widget.id, .little);
    word(&bytes, 52, t.metrics.spinner_segment_count);
    inline for (.{ "spinner_segment_length_ratio", "spinner_segment_thickness_ratio", "spinner_segment_radius_ratio", "spinner_tail_opacity" }, 0..) |name, i| put(&bytes, 56 + i * 4, @field(t.metrics, name));
    word(&bytes, 72, t.motion.durationMs(.slow));
    put(&bytes, 80, t.pixel_snap.scale);
    return bytes;
}
/// Motion anchors for the runtime's looping animations.
pub fn anchors(widget: widgets.Widget, t: Tokens) Anchors {
    const bytes = packet(widget, t, .anchors);
    var result: [160]u8 = undefined;
    invoke(t, &bytes, &result);
    const count = read(&result, 16);
    if (read(&result, 4) != 0 or read(&result, 8) != 0 or read(&result, 12) != 0 or count < 3 or count > 15 or read(&result, 36) != 0 or !std.mem.allEqual(u8, result[40 + count * 8 ..], 0)) @panic("invalid indicator anchors");
    var out: Anchors = .{ .count = count, .center = .init(get(&result, 20), get(&result, 24)), .arc_id = std.mem.readInt(u64, result[28..36], .little), .segment_ids = @splat(0) };
    for (out.segment_ids[0..count], 0..) |*id, i| id.* = std.mem.readInt(u64, result[40 + i * 8 ..][0..8], .little);
    return out;
}
pub const Plan = struct {
    bytes: [256]u8,
    output: [40 + 15 * 256]u8 = undefined,
    token: Tokens,
    pub fn init(widget: widgets.Widget, t: Tokens) Plan {
        return .{ .bytes = packet(widget, t, .render), .token = t };
    }
    pub fn run(self: *Plan) Action {
        invoke(self.token, &self.bytes, &self.output);
        const action = read(&self.output, 4);
        const commands = read(&self.output, 8);
        if (action > 1 or commands > 15 or (action == 1 and commands != 0)) @panic("invalid indicator plan shape");
        if (action == 1) {
            const angles = read(&self.output, 16);
            if (angles > 16 or !std.mem.allEqual(u8, self.output[20..40], 0) or !std.mem.allEqual(u8, self.output[40 + angles * 4 ..], 0)) @panic("invalid indicator appearance query");
            return .appearance;
        }
        for (0..commands) |i| {
            const at = 40 + i * 256;
            const elements = read(&self.output, at + 12);
            if (read(&self.output, at + 8) > 1 or elements > 8 or !std.mem.allEqual(u8, self.output[at + 32 + elements * 28 .. at + 256], 0)) @panic("invalid indicator command");
            for (0..elements) |e| if (read(&self.output, at + 32 + e * 28) > 3) @panic("invalid indicator path element");
        }
        if (!std.mem.allEqual(u8, self.output[16..40], 0) or !std.mem.allEqual(u8, self.output[40 + commands * 256 ..], 0)) @panic("invalid indicator plan tail");
        return @enumFromInt(action);
    }
    /// The stroke fallback the appearance owner resolves for the arc.
    pub fn strokeFallback(self: Plan) f32 {
        return get(&self.output, 12);
    }
    /// Reply with resolved appearance and the platform sine/cosine of every
    /// requested angle, evaluated as the native reference pairs them.
    pub fn reply(self: *Plan, ink: drawing.Color, stroke: f32) void {
        self.bytes[5] |= 1;
        inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| put(&self.bytes, 36 + i * 4, @field(ink, name));
        put(&self.bytes, 76, stroke);
        for (0..read(&self.output, 16)) |i| {
            const angle = get(&self.output, 40 + i * 4);
            put(&self.bytes, 96 + i * 8, @sin(angle));
            put(&self.bytes, 100 + i * 8, @cos(angle));
        }
    }
    pub fn count(self: Plan) usize {
        return read(&self.output, 8);
    }
    pub fn strokeWidth(self: Plan) f32 {
        return get(&self.output, 12);
    }
    pub fn commandId(self: Plan, index: usize) u64 {
        return std.mem.readInt(u64, self.output[40 + index * 256 ..][0..8], .little);
    }
    pub fn stroked(self: Plan, index: usize) bool {
        return read(&self.output, 40 + index * 256 + 8) == 1;
    }
    pub fn color(self: Plan, index: usize) drawing.Color {
        const at = 40 + index * 256 + 16;
        return .rgba(get(&self.output, at), get(&self.output, at + 4), get(&self.output, at + 8), get(&self.output, at + 12));
    }
    pub fn elementCount(self: Plan, index: usize) usize {
        return read(&self.output, 40 + index * 256 + 12);
    }
    pub fn element(self: Plan, index: usize, ordinal: usize) drawing.PathElement {
        const at = 40 + index * 256 + 32 + ordinal * 28;
        return .{ .verb = switch (read(&self.output, at)) {
            0 => .move_to,
            1 => .line_to,
            2 => .cubic_to,
            3 => .close,
            else => unreachable,
        }, .points = .{ point(&self.output, at + 4), point(&self.output, at + 12), point(&self.output, at + 20) } };
    }
    fn point(b: []const u8, offset: usize) geometry.PointF {
        return .init(get(b, offset), get(b, offset + 4));
    }
};
