//! Copied presentation facts; font shaping, identities and drawing stay native.
const std = @import("std");
const geometry = @import("geometry");
const tokens_model = @import("tokens.zig");
const drawing = @import("drawing.zig");
pub const reference_controls = @import("widget_render_controls.zig");
pub const reference_style = @import("widget_render_style.zig");
pub const reference_input = @import("widget_text_input.zig");
pub const Operation = enum(u8) { snap_rect, geometry_point, text_point, origin, layout, label_frame, aligned_origin, glyph_size, focus_rect, focus_radius, hairline, icon_label, composition, input_clip, input_origin, input_layout, clear_icon, clear_hit, trailing_inset };
pub const Result = struct { rects: [2]geometry.RectF, radius: drawing.Radius, point: geometry.PointF, scalar: f32, auxiliary: f32, wrap: @import("text.zig").TextWrap };
fn word(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn getFloat(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn getRect(b: []const u8, at: usize) geometry.RectF {
    return .init(getFloat(b, at), getFloat(b, at + 4), getFloat(b, at + 8), getFloat(b, at + 12));
}
pub const Request = struct {
    bytes: [128]u8 = @splat(0),
    pub fn init(op: Operation, frame: geometry.RectF, tokens: tokens_model.DesignTokens) Request {
        var self: Request = .{};
        self.bytes[0..4].* = .{ 30, 1, @intFromEnum(op), @import("render_plan_policy.zig").numericFlags() };
        self.flags(@as(u32, @intFromBool(tokens.pixel_snap.geometry)) | (@as(u32, @intFromBool(tokens.pixel_snap.text)) << 1));
        inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| self.float(16 + i * 4, @field(frame, name));
        self.float(48, tokens.pixel_snap.scale);
        self.float(84, tokens.stroke.focus_offset);
        self.float(88, tokens.stroke.regular);
        return self;
    }
    pub fn flags(self: *Request, bits: u32) void {
        word(&self.bytes, 4, read(&self.bytes, 4) | bits);
    }
    pub fn float(self: *Request, at: usize, value: f32) void {
        word(&self.bytes, at, @bitCast(value));
    }
    pub fn radius(self: *Request, value: drawing.Radius) void {
        inline for (.{ "top_left", "top_right", "bottom_right", "bottom_left" }, 0..) |name, i| self.float(32 + i * 4, @field(value, name));
    }
    pub fn run(self: Request, tokens: tokens_model.DesignTokens) Result {
        var out: [80]u8 = @splat(0xa5);
        const policy = tokens.control_geometry_policy orelse @panic("missing control content owner");
        if (policy(&self.bytes, &out) != out.len or read(&out, 0) != 1 or read(&out, 4) > 63 or read(&out, 72) > 1 or (self.bytes[2] != @intFromEnum(Operation.input_layout) and read(&out, 72) != 0) or !std.mem.allEqual(u8, out[76..], 0)) @panic("invalid compiled control content result");
        const flags_ = read(&out, 4);
        const expected: u32 = switch (@as(Operation, @enumFromInt(self.bytes[2]))) {
            .snap_rect, .label_frame, .focus_rect, .composition, .input_clip, .clear_icon, .clear_hit => 1,
            .geometry_point, .text_point, .origin, .aligned_origin, .input_origin => 8,
            .layout, .input_layout => 48,
            .glyph_size, .trailing_inset => 16,
            .focus_radius => 4,
            .hairline => 21,
            .icon_label => if (read(&self.bytes, 4) & 8 != 0) 3 else 1,
        };
        if (flags_ != expected) @panic("invalid compiled control content presence");
        inline for (.{ .{ @as(u32, 1), @as(usize, 8), @as(usize, 16) }, .{ 2, 24, 16 }, .{ 4, 40, 16 }, .{ 8, 56, 8 }, .{ 16, 64, 4 }, .{ 32, 68, 4 } }) |field| {
            if (flags_ & field[0] == 0 and !std.mem.allEqual(u8, out[field[1]..][0..field[2]], 0)) @panic("invalid compiled absent control content");
        }
        return .{ .rects = .{ getRect(&out, 8), getRect(&out, 24) }, .radius = .{ .top_left = getFloat(&out, 40), .top_right = getFloat(&out, 44), .bottom_right = getFloat(&out, 48), .bottom_left = getFloat(&out, 52) }, .point = .init(getFloat(&out, 56), getFloat(&out, 60)), .scalar = getFloat(&out, 64), .auxiliary = getFloat(&out, 68), .wrap = @enumFromInt(read(&out, 72)) };
    }
};
pub fn rect(op: Operation, frame: geometry.RectF, tokens: tokens_model.DesignTokens) geometry.RectF {
    return Request.init(op, frame, tokens).run(tokens).rects[0];
}
pub fn point(op: Operation, value: geometry.PointF, tokens: tokens_model.DesignTokens) geometry.PointF {
    return Request.init(op, .init(value.x, value.y, 0, 0), tokens).run(tokens).point;
}
pub fn text(op: Operation, frame: geometry.RectF, size: f32, inset: f32, measured: f32, alignment: u8, tokens: tokens_model.DesignTokens) Result {
    var r = Request.init(op, frame, tokens);
    r.float(52, size);
    r.float(56, inset);
    r.float(60, measured);
    r.bytes[8] = alignment;
    return r.run(tokens);
}
pub fn hairline(value: drawing.StrokeRect, tokens: tokens_model.DesignTokens) drawing.StrokeRect {
    var r = Request.init(.hairline, value.rect, tokens);
    r.radius(value.radius);
    r.float(88, value.stroke.width);
    const out = r.run(tokens);
    var copied = value;
    copied.rect = out.rects[0];
    copied.radius = out.radius;
    copied.stroke.width = out.scalar;
    return copied;
}
