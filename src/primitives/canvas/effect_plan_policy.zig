//! Copied surface effect plans. Native supplies resolved appearance, surface
//! radii and drawing; container, blur, scrim and clip decisions stay portable.
const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const tokens_model = @import("tokens.zig");
const drawing = @import("drawing.zig");
const Tokens = tokens_model.DesignTokens;
pub const Mode = enum(u8) { container, backdrop, scrim, clip };
pub const Op = enum(u32) { fill_round, blur, fill_rect };
pub const ClipSource = enum(u32) { none, bubble, large, extra_large, medium };
pub const Command = struct { id: u64, op: Op, rect: geometry.RectF, radius: f32, color: drawing.Color };
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
fn putRect(b: []u8, at: usize, value: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| put(b, at + i * 4, @field(value, name));
}
fn rect(b: []const u8, at: usize) geometry.RectF {
    return .init(get(b, at), get(b, at + 4), get(b, at + 8), get(b, at + 12));
}
fn putColor(b: []u8, at: usize, color: drawing.Color) void {
    inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| put(b, at + i * 4, @field(color, name));
}
pub const Plan = struct {
    bytes: [128]u8 = @splat(0),
    output: [112]u8 = undefined,
    token: Tokens,
    pub fn init(mode: Mode, widget: widgets.Widget, t: Tokens, viewport: ?geometry.RectF) Plan {
        var p: Plan = .{ .token = t };
        const actions = widget.semantics.actions;
        const facts = (@as(u32, @intFromBool(widget.state.disabled)) << 1) | (@as(u32, @intFromBool(actions.press)) << 2) | (@as(u32, @intFromBool(actions.toggle)) << 3) | (@as(u32, @intFromBool(actions.drag)) << 4) |
            (@as(u32, @intFromBool(widget.style.background != null)) << 5) | (@as(u32, @intFromBool(widget.state.selected)) << 6) | (@as(u32, @intFromBool(widget.state.pressed)) << 7) | (@as(u32, @intFromBool(widget.state.hovered)) << 8) |
            (@as(u32, @intFromBool(widget.style.quiet_hover)) << 9) | (@as(u32, @intFromBool(widget.style.radius != null)) << 10) | (@as(u32, @intFromBool(widget.scrim)) << 11) | (@as(u32, @intFromBool(widget.backdrop_blur_token != null)) << 12) |
            (@as(u32, @intFromBool(widget.layout.clip_content)) << 13) | (@as(u32, @intFromBool(viewport != null)) << 14);
        p.bytes[0..5].* = .{ 52, @intFromEnum(mode), 1, @import("render_plan_policy.zig").numericFlags(), @import("control_geometry_policy.zig").signalingFlags() };
        word(&p.bytes, 8, facts);
        std.mem.writeInt(u64, p.bytes[12..20], widget.id, .little);
        putRect(&p.bytes, 20, widget.frame);
        putColor(&p.bytes, 36, widget.style.background orelse .{});
        put(&p.bytes, 52, widget.style.radius orelse 0);
        put(&p.bytes, 56, widget.backdrop_blur);
        put(&p.bytes, 60, if (widget.backdrop_blur_token) |token| t.blur.value(token) else 0);
        putColor(&p.bytes, 64, t.colors.scrim);
        put(&p.bytes, 80, t.blur.scrim);
        putRect(&p.bytes, 84, viewport orelse .{});
        word(&p.bytes, 100, @intFromEnum(widget.kind));
        return p;
    }
    pub fn run(self: *Plan) void {
        @memset(&self.output, 0xa5);
        const policy = self.token.control_command_policy orelse @panic("missing effect plan owner");
        if (policy(&self.bytes, &self.output) != self.output.len) @panic("invalid effect plan result length");
        const commands = read(&self.output, 8);
        if (read(&self.output, 0) != 1 or read(&self.output, 4) > 1 or commands > 2 or (read(&self.output, 4) == 1 and commands != 0)) @panic("invalid effect plan result header");
        for (0..commands) |i| if (read(&self.output, 16 + i * 48 + 8) > @intFromEnum(Op.fill_rect)) @panic("invalid effect drawing capability");
        if (!std.mem.allEqual(u8, self.output[16 + commands * 48 ..], 0)) @panic("invalid effect plan tail");
    }
    /// The container asks the appearance owner for its list-row feedback fill.
    pub fn wantsListFill(self: Plan) bool {
        return read(&self.output, 4) == 1;
    }
    pub fn reply(self: *Plan, color: drawing.Color) void {
        self.bytes[9] |= 0x80;
        putColor(&self.bytes, 104, color);
    }
    pub fn scalar(self: Plan) f32 {
        return get(&self.output, 12);
    }
    pub fn flag(self: Plan) bool {
        const value = read(&self.output, 12);
        if (value > 1) @panic("invalid effect plan verdict");
        return value == 1;
    }
    pub fn clipSource(self: Plan) ClipSource {
        const value = read(&self.output, 12);
        if (value > @intFromEnum(ClipSource.medium)) @panic("invalid effect clip source");
        return @enumFromInt(value);
    }
    pub fn count(self: Plan) usize {
        return read(&self.output, 8);
    }
    pub fn command(self: Plan, index: usize) Command {
        const at = 16 + index * 48;
        return .{ .id = std.mem.readInt(u64, self.output[at..][0..8], .little), .op = @enumFromInt(read(&self.output, at + 8)), .rect = rect(&self.output, at + 12), .radius = get(&self.output, at + 28), .color = .rgba(get(&self.output, at + 32), get(&self.output, at + 36), get(&self.output, at + 40), get(&self.output, at + 44)) };
    }
};
