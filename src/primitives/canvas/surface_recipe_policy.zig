//! Copied surface plans and explicit font/registry/drawing capabilities.
const std = @import("std");
const geometry = @import("geometry");
const c = @import("root.zig");
const style = @import("widget_render_style.zig");
const metrics = @import("widget_metrics.zig");
const text = @import("text.zig");
const drawing = @import("drawing.zig");
const icons = @import("icons.zig");
pub const reference = @import("widget_render_surfaces.zig");
pub const Operation = enum(u8) { alert, card, modal, panel, bubble, bubble_radius, bubble_ink, pill_rect, reactions, accordion, chevron, tabs, grip, floating, alert_mark };
fn word(b: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], value, .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn float(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn rect(b: []const u8, at: usize) geometry.RectF {
    return .init(float(b, at), float(b, at + 4), float(b, at + 8), float(b, at + 12));
}
fn point(b: []const u8, at: usize) geometry.PointF {
    return .init(float(b, at), float(b, at + 4));
}
fn radius(b: []const u8, at: usize) drawing.Radius {
    return .{ .top_left = float(b, at), .top_right = float(b, at + 4), .bottom_right = float(b, at + 8), .bottom_left = float(b, at + 12) };
}
fn color(b: []const u8, at: usize) drawing.Color {
    return .{ .r = float(b, at), .g = float(b, at + 4), .b = float(b, at + 8), .a = float(b, at + 12) };
}
pub const Plan = struct {
    bytes: [1088]u8,
    pub fn pill(self: *const Plan) ?geometry.RectF {
        return if (read(&self.bytes, 8) & 4 != 0) rect(&self.bytes, 16) else null;
    }
    pub fn bubbleRadius(self: *const Plan) drawing.Radius {
        if (read(&self.bytes, 8) != 1) @panic("missing surface radius");
        return radius(&self.bytes, 16);
    }
    pub fn contentTokens(self: *const Plan, tokens: c.DesignTokens) c.DesignTokens {
        var copied = tokens;
        if (read(&self.bytes, 8) & 2 != 0) {
            copied.colors.text = color(&self.bytes, 32);
            copied.colors.text_muted = color(&self.bytes, 48);
        }
        return copied;
    }
    pub fn emit(self: *const Plan, builder: *c.Builder, widget: c.Widget, tokens: c.DesignTokens) c.Error!void {
        for (0..read(&self.bytes, 4)) |i| {
            const at = 64 + i * 128;
            const id = @import("widgets.zig").widgetCommandPartId(.{ .widget_id = widget.id, .slot = read(&self.bytes, at + 4) });
            const bounds = rect(&self.bytes, at + 8);
            const arc = radius(&self.bytes, at + 24);
            const ink = color(&self.bytes, at + 40);
            const stroke: drawing.Stroke = .{ .fill = .{ .color = ink }, .width = float(&self.bytes, at + 56) };
            switch (read(&self.bytes, at)) {
                0 => try builder.fillRoundedRect(.{ .id = id, .rect = bounds, .radius = arc, .fill = .{ .color = ink } }),
                1 => try builder.strokeRect(.{ .id = id, .rect = bounds, .radius = arc, .stroke = stroke }),
                2 => try builder.shadow(.{ .id = id, .rect = bounds, .radius = arc, .offset = .{ .dx = 0, .dy = float(&self.bytes, at + 60) }, .blur = float(&self.bytes, at + 64), .spread = float(&self.bytes, at + 68), .color = ink }),
                3 => try builder.drawText(.{ .id = id, .font_id = tokens.typography.font_id, .size = float(&self.bytes, at + 60), .origin = point(&self.bytes, at + 72), .color = ink, .text = widget.text, .text_layout = .{ .max_width = float(&self.bytes, at + 64), .line_height = float(&self.bytes, at + 68), .wrap = @enumFromInt(read(&self.bytes, at + 80)), .alignment = @enumFromInt(read(&self.bytes, at + 84)), .overflow = @enumFromInt(read(&self.bytes, at + 88)), .measure = tokens.text_measure } }),
                4 => try builder.drawLine(.{ .id = id, .from = point(&self.bytes, at + 8), .to = point(&self.bytes, at + 16), .stroke = stroke }),
                5 => {
                    const registry = icons.resolve(switch (read(&self.bytes, at + 92)) {
                        0 => "info",
                        1 => "alert",
                        2 => "chevron-down",
                        else => unreachable,
                    }) orelse continue;
                    const transform: drawing.Affine = .{ .a = float(&self.bytes, at + 96), .b = float(&self.bytes, at + 100), .c = float(&self.bytes, at + 104), .d = float(&self.bytes, at + 108), .tx = float(&self.bytes, at + 112), .ty = float(&self.bytes, at + 116) };
                    const flipped = read(&self.bytes, at + 80) == 1;
                    if (flipped) try builder.transform(transform);
                    try @import("widget_render_controls.zig").emitVectorIconWithTokens(builder, widget.id, read(&self.bytes, at + 4), bounds, ink, registry, tokens);
                    if (flipped) try builder.transform(transform);
                },
                6 => try builder.fillRect(.{ .id = id, .rect = bounds, .fill = .{ .color = ink } }),
                else => unreachable,
            }
        }
    }
};
pub const Request = struct {
    bytes: [560]u8 = @splat(0),
    pub fn putFloat(self: *Request, at: usize, value: f32) void {
        word(&self.bytes, at, @bitCast(value));
    }
    pub fn putColor(self: *Request, at: usize, value: drawing.Color) void {
        inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| self.putFloat(at + i * 4, @field(value, name));
    }
    fn optionalColor(self: *Request, at: usize, value: ?drawing.Color, bit: u32) void {
        if (value) |v| {
            word(&self.bytes, 8, read(&self.bytes, 8) | bit);
            self.putColor(at, v);
        }
    }
    fn putRadius(self: *Request, at: usize, value: drawing.Radius) void {
        inline for (.{ "top_left", "top_right", "bottom_right", "bottom_left" }, 0..) |name, i| self.putFloat(at + i * 4, @field(value, name));
    }
    pub fn init(op: Operation, widget: c.Widget, tokens: c.DesignTokens, visual: c.ControlVisualTokens, fallback_radius: f32) Request {
        var self: Request = .{};
        self.bytes[0..4].* = .{ 31, 1, @intFromEnum(op), @import("render_plan_policy.zig").numericFlags() };
        const bits: u32 = @as(u32, @intFromBool(widget.text.len > 0)) | (@as(u32, @intFromBool(widget.state.focused)) << 1) | (@as(u32, @intFromBool(@import("widget_access.zig").booleanControlSelected(widget))) << 2) | (@as(u32, @intFromBool(widget.kind == .resizable)) << 3) | (@as(u32, @intFromBool(tokens.controls.tabs_indicator == .underline)) << 4) | (@as(u32, @intFromBool(tokens.pixel_snap.geometry)) << 5) | (@as(u32, @intFromBool(tokens.pixel_snap.text)) << 6) | (@as(u32, @intFromBool(widget.style.radius != null)) << 8) | (@as(u32, @intFromBool(widget.kind == .bubble)) << 9);
        word(&self.bytes, 4, bits);
        self.bytes[12] = @intFromEnum(widget.variant);
        self.bytes[13] = @intFromEnum(widget.text_alignment);
        self.bytes[14] = @intFromEnum(widget.text_overflow);
        self.bytes[15] = @import("control_geometry_policy.zig").signalingFlags();
        inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| self.putFloat(16 + i * 4, @field(widget.frame, name));
        self.putRadius(32, style.controlRadius(widget, visual, fallback_radius));
        self.putFloat(48, switch (op) {
            .card => metrics.widgetTypographySizeWithTokens(widget, tokens.typography.body_size + 1, tokens),
            .modal => metrics.widgetTypographySizeWithTokens(widget, tokens.typography.title_size, tokens),
            .pill_rect, .reactions => metrics.widgetLabelTextSize(widget, tokens),
            else => metrics.widgetBodyTextSize(widget, tokens),
        });
        self.putFloat(52, if (op == .alert) metrics.widgetAlertInset(widget, tokens) else metrics.widgetControlInset(widget, tokens, if (op == .modal) tokens.spacing.xl else tokens.spacing.lg));
        self.putFloat(56, metrics.widgetSizedDensityValue(widget, tokens, 16));
        self.putFloat(60, metrics.widgetControlInset(widget, tokens, tokens.spacing.md));
        self.putFloat(64, @import("widget_layout.zig").accordionHeaderHeight(widget, tokens));
        self.putFloat(68, tokens.pixel_snap.scale);
        inline for (.{ "top", "right", "bottom", "left" }, 0..) |name, i| self.putFloat(72 + i * 4, @field(widget.layout.padding, name));
        const shadow = if (op == .panel) tokens.shadow.sm else tokens.shadow.md;
        self.putFloat(88, shadow.y);
        self.putFloat(92, shadow.blur);
        self.putFloat(96, shadow.spread);
        self.putFloat(100, style.controlStrokeWidth(widget, visual, tokens.stroke.hairline));
        self.putFloat(104, style.controlStrokeWidth(widget, visual, tokens.stroke.regular));
        self.putFloat(108, tokens.radius.lg);
        self.putFloat(112, widget.style.radius orelse 0);
        self.putFloat(120, tokens.stroke.focus_offset);
        self.putFloat(124, tokens.stroke.focus);
        self.putRadius(128, style.widgetRadius(widget, tokens.radius.md));
        self.putFloat(144, metrics.widgetSizedDensityValue(widget, tokens, 6));
        self.putFloat(148, metrics.widgetSizedDensityValue(widget, tokens, 4));
        self.putFloat(152, metrics.widgetSizedDensityValue(widget, tokens, 10));
        self.putColor(160, if (op == .alert) style.alertBackgroundColor(widget, visual, tokens) else if (op == .tabs) style.widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_subtle) else style.surfaceStateBackground(widget, visual, tokens));
        self.putColor(176, if (op == .alert) style.alertBorderColor(widget, visual, tokens) else widget.style.border orelse visual.border orelse tokens.colors.border);
        const foreground = if (op == .alert and widget.variant == .destructive) widget.style.accent orelse tokens.colors.destructive else if (op == .grip or (op == .panel and widget.kind == .resizable)) visual.foreground orelse visual.border orelse tokens.colors.text_muted else visual.foreground orelse tokens.colors.text;
        self.putColor(192, style.widgetForegroundColor(widget, tokens, foreground));
        self.putColor(208, style.widgetForegroundColor(widget, tokens, tokens.colors.text_muted));
        self.putColor(224, tokens.colors.shadow);
        self.putColor(240, tokens.colors.background);
        self.putColor(256, tokens.colors.surface_subtle);
        self.putColor(272, tokens.colors.text);
        self.putColor(288, tokens.colors.accent);
        self.putColor(304, tokens.colors.accent_text);
        self.putColor(320, tokens.colors.destructive);
        self.optionalColor(336, tokens.controls.button_destructive.background, 128);
        self.optionalColor(352, tokens.controls.bubble.background, 16);
        self.optionalColor(368, tokens.controls.bubble.border, 32);
        self.optionalColor(384, tokens.controls.bubble.foreground, 64);
        self.optionalColor(400, widget.style.background, 1);
        self.optionalColor(416, widget.style.border, 2);
        self.optionalColor(432, widget.style.accent, 4);
        self.optionalColor(448, widget.style.accent_foreground, 8);
        self.optionalColor(480, widget.style.background orelse visual.background, 256);
        self.optionalColor(496, widget.style.border orelse visual.border, 512);
        self.putColor(512, style.widgetFocusRingFill(widget, tokens).color);
        return self;
    }
    pub fn run(self_: Request, widget: c.Widget, tokens: c.DesignTokens) Plan {
        var self = self_;
        var copied: Plan = .{ .bytes = @splat(0xa5) };
        const policy = tokens.control_geometry_policy orelse @panic("missing surface recipe owner");
        for (0..2) |phase| {
            if (policy(&self.bytes, &copied.bytes) != copied.bytes.len or read(&copied.bytes, 0) != 1 or read(&copied.bytes, 4) > 8 or read(&copied.bytes, 8) > 15 or read(&copied.bytes, 12) != 0) @panic("invalid compiled surface copied");
            const pending = read(&copied.bytes, 8) & 8 != 0;
            if (pending) {
                if (phase != 0 or (self.bytes[2] != @intFromEnum(Operation.pill_rect) and self.bytes[2] != @intFromEnum(Operation.reactions)) or read(&copied.bytes, 8) != 8 or read(&copied.bytes, 4) != 0 or !std.mem.allEqual(u8, copied.bytes[16..], 0)) @panic("invalid surface measurement continuation");
                self.putFloat(116, text.measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, widget.text, float(&self.bytes, 48)));
                word(&self.bytes, 4, read(&self.bytes, 4) | 128);
                continue;
            }
            const op: Operation = @enumFromInt(self.bytes[2]);
            const presence = read(&copied.bytes, 8);
            switch (op) {
                .bubble_radius => {
                    if (presence != 1 or read(&copied.bytes, 4) != 0) @panic("invalid surface radius result");
                },
                .bubble_ink => {
                    if ((presence != 0 and presence != 2) or read(&copied.bytes, 4) != 0) @panic("invalid surface ink result");
                },
                .pill_rect, .reactions => {
                    if (presence != 0 and presence != 4) @panic("invalid surface pill result");
                },
                else => {
                    if (presence != 0) @panic("unexpected surface auxiliary result");
                },
            }
            validate(&copied);
            return copied;
        }
        @panic("incomplete compiled surface measurement");
    }
};
fn validate(copied: *const Plan) void {
    const b = &copied.bytes;
    const count = read(b, 4);
    const flags = read(b, 8);
    if (flags != 0 and flags != 1 and flags != 2 and flags != 4) @panic("invalid surface auxiliary presence");
    if (flags & 5 == 0 and !std.mem.allEqual(u8, b[16..32], 0)) @panic("invalid absent surface geometry");
    if (flags & 2 == 0 and !std.mem.allEqual(u8, b[32..64], 0)) @panic("invalid absent surface ink");
    if (!std.mem.allEqual(u8, b[64 + @as(usize, count) * 128 ..], 0)) @panic("invalid unused surface commands");
    for (0..count) |i| {
        const at = 64 + i * 128;
        const kind = read(b, at);
        const slot = read(b, at + 4);
        if (kind > 6 or slot > 10 or slot == 0 or !std.mem.allEqual(u8, b[at + 120 ..][0..8], 0)) @panic("invalid surface command identity");
        const ranges: []const [2]usize = switch (kind) {
            0, 6 => &.{.{ 56, 120 }},
            1 => &.{.{ 60, 120 }},
            2 => &.{ .{ 56, 60 }, .{ 72, 120 } },
            3 => &.{ .{ 8, 40 }, .{ 56, 60 }, .{ 92, 120 } },
            4 => &.{ .{ 24, 40 }, .{ 60, 120 } },
            5 => &.{ .{ 24, 40 }, .{ 56, 80 }, .{ 84, 92 } },
            else => unreachable,
        };
        for (ranges) |range| if (!std.mem.allEqual(u8, b[at + range[0] .. at + range[1]], 0)) @panic("invalid unused surface command fields");
        if (kind == 5 and read(b, at + 80) == 0 and !std.mem.allEqual(u8, b[at + 96 ..][0..24], 0)) @panic("invalid absent surface transform");
        if (kind == 3 and (read(b, at + 80) > 1 or read(b, at + 84) > 2 or read(b, at + 88) > 1)) @panic("invalid surface text layout");
        if (kind == 5 and (read(b, at + 92) > 2 or read(b, at + 80) > 1)) @panic("invalid surface registry descriptor");
    }
}
pub fn plan(op: Operation, widget: c.Widget, tokens: c.DesignTokens, visual: c.ControlVisualTokens, fallback_radius: f32) Plan {
    return Request.init(op, widget, tokens, visual, fallback_radius).run(widget, tokens);
}
pub fn emit(op: Operation, builder: *c.Builder, widget: c.Widget, tokens: c.DesignTokens, visual: c.ControlVisualTokens, fallback_radius: f32) c.Error!void {
    const copied = plan(op, widget, tokens, visual, fallback_radius);
    try copied.emit(builder, widget, tokens);
}
