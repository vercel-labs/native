//! Copied primitive geometry. The native adapter owns storage and font
//! measurements; portable code chooses shapes and scroll presentation.
const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const tokens_model = @import("tokens.zig");
const events = @import("events.zig");
const drawing = @import("drawing.zig");
pub const Policy = @import("surface_layout_policy.zig").Policy;
pub const reference_controls = @import("widget_render_controls.zig");
pub const reference_scroll = @import("widget_render_scroll.zig");
pub const Shape = enum(u8) { choice, toggle, slider, progress, scrollbar, corner, scroll_metrics, underline, segment };
pub const Result = struct {
    flags: u32,
    rects: [3]geometry.RectF,
    vertical: events.WidgetScrollMetrics,
    horizontal: events.WidgetScrollMetrics,
    scalar: f32,
};
fn word(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}
fn read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn float(b: []u8, at: usize, v: f32) void {
    word(b, at, @bitCast(v));
}
fn getFloat(b: []const u8, at: usize) f32 {
    return @bitCast(read(b, at));
}
fn putRect(b: []u8, at: usize, r: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| float(b, at + i * 4, @field(r, name));
}
fn getRect(b: []const u8, at: usize) geometry.RectF {
    return .init(getFloat(b, at), getFloat(b, at + 4), getFloat(b, at + 8), getFloat(b, at + 12));
}
fn metric(b: []const u8, at: usize) events.WidgetScrollMetrics {
    if (read(b, at) > 1) @panic("invalid compiled control metric presence");
    if (read(b, at) == 0 and !std.mem.allEqual(u8, b[at + 4 ..][0..12], 0)) @panic("invalid compiled absent control metric");
    return .{ .present = read(b, at) == 1, .offset = getFloat(b, at + 4), .viewport_extent = getFloat(b, at + 8), .content_extent = getFloat(b, at + 12) };
}
pub const Request = struct {
    bytes: [160]u8 = @splat(0),
    pub fn init(shape: Shape, widget: widgets.Widget, tokens: tokens_model.DesignTokens) Request {
        var self: Request = .{};
        self.bytes[0..4].* = .{ 29, 1, @intFromEnum(shape), @import("render_plan_policy.zig").numericFlags() };
        self.bytes[8] = @intFromEnum(tokens.density);
        self.bytes[9] = @intFromEnum(widget.size);
        self.bytes[10] = signalingFlags();
        word(&self.bytes, 4, @intFromBool(tokens.pixel_snap.geometry));
        putRect(&self.bytes, 16, widget.frame);
        float(&self.bytes, 32, tokens.pixel_snap.scale);
        float(&self.bytes, 36, widget.value);
        float(&self.bytes, 40, widget.value_x);
        float(&self.bytes, 44, tokens.metrics.slider_track_height);
        float(&self.bytes, 48, tokens.metrics.slider_thumb_width);
        float(&self.bytes, 52, tokens.metrics.slider_thumb_height);
        float(&self.bytes, 56, tokens.metrics.tabs_indicator_thickness);
        inline for (.{ "left", "right", "top", "bottom" }, 0..) |name, i| float(&self.bytes, 112 + i * 4, @field(widget.layout.padding, name));
        return self;
    }
    pub fn flags(self: *Request, bits: u32) void {
        word(&self.bytes, 4, read(&self.bytes, 4) | bits);
    }
    pub fn measurement(self: *Request, at: usize, value: f32) void {
        float(&self.bytes, at, value);
    }
    pub fn run(self: Request, policy: Policy) Result {
        return evaluate(&self.bytes, policy);
    }
};
pub fn evaluate(request: []const u8, policy: Policy) Result {
    var out: [96]u8 = @splat(0xa5);
    if (policy(request, &out) != out.len or read(&out, 0) != 1 or read(&out, 4) > 31 or read(&out, 92) != 0) @panic("invalid compiled control geometry result");
    const flags = read(&out, 4);
    var rects: [3]geometry.RectF = undefined;
    for (&rects, 0..) |*r, i| {
        if (flags & (@as(u32, 1) << @intCast(i)) == 0 and !std.mem.allEqual(u8, out[8 + i * 16 ..][0..16], 0)) @panic("invalid compiled absent control shape");
        r.* = getRect(&out, 8 + i * 16);
    }
    return .{ .flags = flags, .rects = rects, .vertical = metric(&out, 56), .horizontal = metric(&out, 72), .scalar = getFloat(&out, 88) };
}
pub fn controls(widget: widgets.Widget, tokens: tokens_model.DesignTokens, shape: Shape) Result {
    return Request.init(shape, widget, tokens).run(tokens.control_geometry_policy orelse @panic("missing control geometry owner"));
}
pub fn underline(widget: widgets.Widget, tokens: tokens_model.DesignTokens, text_width: f32, icon_width: f32, inset: f32) ?geometry.RectF {
    var r = Request.init(.underline, widget, tokens);
    if (tokens.controls.tabs_indicator == .underline) r.flags(8);
    r.measurement(60, text_width);
    r.measurement(64, icon_width);
    r.measurement(68, inset);
    const out = r.run(tokens.control_geometry_policy.?);
    return if (out.flags & 1 == 0) null else out.rects[0];
}
pub fn segment(widget: widgets.Widget, tokens: tokens_model.DesignTokens, radius: drawing.Radius, detached: bool) drawing.Radius {
    var r = Request.init(.segment, widget, tokens);
    if (detached) r.flags(2048);
    word(&r.bytes, 80, @intFromEnum(widget.group_segment));
    inline for (.{ "top_left", "top_right", "bottom_right", "bottom_left" }, 0..) |name, i| r.measurement(132 + i * 4, @field(radius, name));
    const out = r.run(tokens.control_geometry_policy.?).rects[0];
    return .{ .top_left = out.x, .top_right = out.y, .bottom_right = out.width, .bottom_left = out.height };
}
fn scrollRequest(shape: Shape, frame: geometry.RectF, vertical: events.WidgetScrollMetrics, horizontal: events.WidgetScrollMetrics, tokens: tokens_model.DesignTokens, axis: tokens_model.ScrollAxis) Request {
    var r = Request.init(shape, .{ .kind = .scroll_view, .frame = frame }, tokens);
    if (axis == .horizontal) r.flags(4);
    if (vertical.present) r.flags(16);
    if (horizontal.present) r.flags(32);
    r.measurement(84, vertical.offset);
    r.measurement(88, vertical.viewport_extent);
    r.measurement(92, vertical.content_extent);
    r.measurement(100, horizontal.offset);
    r.measurement(104, horizontal.viewport_extent);
    r.measurement(108, horizontal.content_extent);
    return r;
}
pub fn scrollbar(frame: geometry.RectF, metrics: events.WidgetScrollMetrics, tokens: tokens_model.DesignTokens, axis: tokens_model.ScrollAxis, reserved_end: f32, snapped: bool) ?@import("widget_render_scroll.zig").ScrollbarGeometry {
    var r = scrollRequest(.scrollbar, frame, metrics, .{}, tokens, axis);
    r.measurement(80, reserved_end);
    if (snapped) r.flags(1024);
    const out = r.run(tokens.control_geometry_policy.?);
    return if (out.flags & 1 == 0) null else .{ .track = out.rects[0], .thumb = out.rects[1] };
}
pub fn corner(frame: geometry.RectF, vertical: events.WidgetScrollMetrics, horizontal: events.WidgetScrollMetrics, tokens: tokens_model.DesignTokens, axis: tokens_model.ScrollAxis) f32 {
    return scrollRequest(.corner, frame, vertical, horizontal, tokens, axis).run(tokens.control_geometry_policy.?).scalar;
}
pub fn scrollMetrics(widget: widgets.Widget, tokens: tokens_model.DesignTokens) Result {
    var r = Request.init(.scroll_metrics, widget, tokens);
    if (widget.kind == .scroll_view) r.flags(512);
    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    if (widget.kind == .scroll_view and !viewport.isEmpty()) {
        if (widget.layout.virtualized) {
            r.flags(64);
            r.measurement(128, @import("widget_layout.zig").virtualWidgetScrollContentExtentWithTokens(widget, viewport.height, tokens));
        }
        if (widget.scroll_axes.scrollsVertically()) r.flags(128);
        if (widget.scroll_axes.scrollsHorizontally()) r.flags(256);
    }
    const length = std.math.add(usize, 160, std.math.mul(usize, widget.children.len, 16) catch @panic("control geometry child capacity")) catch @panic("control geometry byte capacity");
    var small: [672]u8 = undefined;
    const bytes = if (length <= small.len) small[0..length] else std.heap.page_allocator.alloc(u8, length) catch @panic("control geometry allocation failed");
    defer if (length > small.len) std.heap.page_allocator.free(bytes);
    @memcpy(bytes[0..160], &r.bytes);
    word(bytes, 12, std.math.cast(u32, widget.children.len) orelse @panic("control geometry child capacity"));
    for (widget.children, 0..) |child, i| putRect(bytes, 160 + i * 16, child.frame);
    return evaluate(bytes, tokens.control_geometry_policy.?);
}

// Read probe results through volatile storage: an optimizer may otherwise
// infer that minimum-number with a finite operand can never produce NaN,
// despite the target instruction's signaling-operand behavior.
pub noinline fn signalingFlags() u8 {
    var signaling: u32 = 0x7f800001;
    const input: *volatile u32 = &signaling;
    const value: f32 = @bitCast(input.*);
    var results: [5]f32 = undefined;
    const output: *volatile [5]f32 = &results;
    output.* = .{ std.math.clamp(value, @as(f32, 0), @as(f32, 1)), @min(value, @as(f32, 44)), @min(@as(f32, 44), value), @max(value, @as(f32, 0)), @max(@as(f32, 0), value) };
    const observed = output.*;
    return @as(u8, @intFromBool(observed[0] == 0)) |
        (@as(u8, @intFromBool(std.math.isNan(observed[1]))) << 1) |
        (@as(u8, @intFromBool(std.math.isNan(observed[2]))) << 2) |
        (@as(u8, @intFromBool(std.math.isNan(observed[3]))) << 3) |
        (@as(u8, @intFromBool(std.math.isNan(observed[4]))) << 4);
}
