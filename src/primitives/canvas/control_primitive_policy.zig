//! Copied primitive plans. All resource pointers and drawing buffers stay native.
const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const drawing = @import("drawing.zig");
const tokens_model = @import("tokens.zig");
const widgets = @import("widgets.zig");
const svg = @import("svg_icon.zig");
const Tokens = tokens_model.DesignTokens;
const Policy = @import("surface_layout_policy.zig").Policy;
pub const RadiusKind = enum(u8) { selection, tab };
fn put(bytes: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(value), .little);
}
fn get(bytes: []const u8, at: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little));
}
fn word(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn invoke(tokens: Tokens, request: []const u8, result: []u8) void {
    const policy: Policy = tokens.control_command_policy orelse @panic("missing control primitive owner");
    if (policy(request, result) != result.len) @panic("invalid control primitive result");
}
pub fn partId(tokens: Tokens, id: u64, slot: u64) u64 {
    var request: [32]u8 = @splat(0);
    request[0..3].* = .{ 47, 0, 1 };
    word(&request, 8, id);
    word(&request, 16, slot);
    var result: [8]u8 = undefined;
    invoke(tokens, &request, &result);
    return std.mem.readInt(u64, &result, .little);
}
pub fn overlayId(tokens: Tokens, seed: u64, id: u64, ordinal: u64) u64 {
    var request: [32]u8 = @splat(0);
    request[0..3].* = .{ 47, 1, 1 };
    word(&request, 8, seed);
    word(&request, 16, id);
    word(&request, 24, ordinal);
    var result: [8]u8 = undefined;
    invoke(tokens, &request, &result);
    return std.mem.readInt(u64, &result, .little);
}
pub fn radius(kind: RadiusKind, widget: widgets.Widget, visual: tokens_model.ControlVisualTokens, fallback: f32, tokens: Tokens) drawing.Radius {
    var request: [40]u8 = @splat(0);
    request[0..8].* = .{ 47, 2, 1, @intFromEnum(kind), @intFromEnum(widget.size), @import("render_plan_policy.zig").numericFlags(), @import("control_geometry_policy.zig").signalingFlags(), @as(u8, @intFromBool(widget.style.radius != null)) | (@as(u8, @intFromBool(visual.radius != null)) << 1) | (@as(u8, @intFromBool(tokens.controls.tabs_indicator == .underline)) << 2) | (@as(u8, @intFromBool(widget.appearance_policy != null)) << 3) | (@as(u8, @intFromBool(tokens.controls.tabs.radius != null)) << 4) };
    for ([_]f32{ widget.style.radius orelse 0, visual.radius orelse 0, fallback, tokens.controls.tabs.radius orelse 0, tokens.radius.lg, widgets.tabs_list_inset }, 0..) |value, i| put(&request, 8 + i * 4, value);
    // Consume the actual appearance owner under the same admission as the
    // native radius helpers; custom results and observable calls are retained.
    if (widget.appearance_policy != null) {
        const appearance = @import("control_appearance_policy.zig");
        if (kind == .selection) {
            if (widget.style.radius != null or visual.radius != null)
                put(&request, 32, appearance.scalar(widget, Tokens{}, 19, visual, fallback));
        } else if (widget.style.radius == null) {
            if (visual.radius != null or tokens.controls.tabs_indicator != .underline)
                put(&request, 32, appearance.scalar(widget, Tokens{}, 22, .{}, visual.radius orelse tokens.controls.tabs.radius orelse tokens.radius.lg));
        }
    }
    var result: [4]u8 = undefined;
    invoke(tokens, &request, &result);
    return drawing.Radius.all(get(&result, 0));
}
pub const Transform = struct { forward: drawing.Affine, inverse: drawing.Affine };
fn affine(bytes: []const u8, at: usize) drawing.Affine {
    return .{ .a = get(bytes, at), .b = get(bytes, at + 4), .c = get(bytes, at + 8), .d = get(bytes, at + 12), .tx = get(bytes, at + 16), .ty = get(bytes, at + 20) };
}
pub fn transform(frame: geometry.RectF, box: geometry.RectF, tokens: Tokens) ?Transform {
    var request: [64]u8 = @splat(0);
    request[0..4].* = .{ 48, 0, 1, @import("render_plan_policy.zig").numericFlags() };
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| {
        put(&request, 8 + i * 4, @field(frame, name));
        put(&request, 24 + i * 4, @field(box, name));
    }
    var result: [64]u8 = @splat(0xa5);
    invoke(tokens, &request, &result);
    const flags = std.mem.readInt(u32, result[4..8], .little);
    if (std.mem.readInt(u32, result[0..4], .little) != 1 or flags > 1 or !std.mem.allEqual(u8, result[56..], 0)) @panic("invalid vector transform result");
    if (flags == 0) {
        if (!std.mem.allEqual(u8, result[8..], 0)) @panic("invalid empty vector transform");
        return null;
    }
    return .{ .forward = affine(&result, 8), .inverse = affine(&result, 32) };
}
pub const Paint = struct {
    fill: bool,
    stroke: bool,
    fill_id: u64,
    stroke_id: u64,
    fill_color: drawing.Color,
    stroke_color: drawing.Color,
    width: f32,
    cap: @import("vector.zig").LineCap,
};
fn tag(value: svg.Paint) u8 {
    return switch (value) {
        .none => 0,
        .current_color => 1,
        .color => 2,
    };
}
fn authored(value: svg.Paint) drawing.Color {
    return switch (value) {
        .color => |ink| ink,
        else => .{},
    };
}
fn color(bytes: []const u8, at: usize) drawing.Color {
    return .rgba(get(bytes, at), get(bytes, at + 4), get(bytes, at + 8), get(bytes, at + 12));
}
pub fn paint(id: u64, first_slot: u64, index: u64, current: drawing.Color, style: svg.IconStyle, stroke_phase: bool, tokens: Tokens) Paint {
    var request: [96]u8 = @splat(0);
    request[0..8].* = .{ 48, 1, 1, tag(style.fill), tag(style.stroke), @intFromEnum(style.linecap), @intFromBool(builtin.mode == .Debug or builtin.mode == .ReleaseSafe), @intFromBool(stroke_phase) };
    word(&request, 8, id);
    word(&request, 16, first_slot);
    word(&request, 24, index);
    for ([_]drawing.Color{ current, authored(style.fill), authored(style.stroke) }, 0..) |value, i| {
        inline for (.{ "r", "g", "b", "a" }, 0..) |name, j| put(&request, 32 + i * 16 + j * 4, @field(value, name));
    }
    put(&request, 80, style.stroke_width);
    var result: [64]u8 = @splat(0xa5);
    invoke(tokens, &request, &result);
    const flags = std.mem.readInt(u32, result[4..8], .little);
    const cap = std.mem.readInt(u32, result[60..64], .little);
    if (std.mem.readInt(u32, result[0..4], .little) != 1 or flags > 3 or cap > 1) @panic("invalid vector paint result");
    if (flags & 1 == 0 and (!std.mem.allEqual(u8, result[8..16], 0) or !std.mem.allEqual(u8, result[24..40], 0))) @panic("invalid absent vector fill");
    if (flags & 2 == 0 and (!std.mem.allEqual(u8, result[16..24], 0) or !std.mem.allEqual(u8, result[40..64], 0))) @panic("invalid absent vector stroke");
    return .{ .fill = flags & 1 != 0, .stroke = flags & 2 != 0, .fill_id = std.mem.readInt(u64, result[8..16], .little), .stroke_id = std.mem.readInt(u64, result[16..24], .little), .fill_color = color(&result, 24), .stroke_color = color(&result, 40), .width = get(&result, 56), .cap = @enumFromInt(cap) };
}
