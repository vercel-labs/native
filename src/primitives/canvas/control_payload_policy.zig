//! Copied primitive facts and results. No drawing or borrowed buffer crosses.
const std = @import("std");
const geometry = @import("geometry");
const drawing = @import("drawing.zig");
const tokens_model = @import("tokens.zig");
const widgets = @import("widgets.zig");
const appearance = @import("control_appearance_policy.zig");
pub const Family = @import("control_command_policy.zig").Family;
pub const Role = enum(u8) { fill, border, ink, placeholder, mark, active, knob, attention };
pub const Operation = enum(u8) { seam, select, centered_icon, search_icon, menu, list, checkmark, radio_dot, progress_radius, slider_radius, label_x, shifted_label };
fn put(bytes: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(value), .little);
}
fn get(bytes: []const u8, at: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little));
}
pub fn color(widget: widgets.Widget, tokens: tokens_model.DesignTokens, visual: tokens_model.ControlVisualTokens, family: Family, role: Role) drawing.Color {
    var request: [560]u8 = @splat(0);
    request[0..5].* = .{ 46, 0, @intFromEnum(family), @intFromEnum(role), @as(u8, @intFromBool(tokens.controls.tabs_indicator == .underline)) | (@as(u8, @intFromBool(widget.state.focused)) << 1) | (@as(u8, @intFromBool(widget.state.hovered)) << 2) };
    request[8..504].* = appearance.context(widget, tokens, 2, visual, tokens.colors.border, 0);
    for ([_]drawing.Color{ tokens.colors.border, tokens.colors.text_muted, tokens.colors.focus_ring }, 0..) |value, i| {
        inline for (.{ "r", "g", "b", "a" }, 0..) |name, j| put(&request, 504 + i * 16 + j * 4, @field(value, name));
    }
    put(&request, 552, widget.value);
    var result: [16]u8 = undefined;
    const policy = tokens.control_command_policy orelse @panic("missing control payload owner");
    if (policy(&request, &result) != result.len) @panic("invalid control payload color result");
    return .rgba(get(&result, 0), get(&result, 4), get(&result, 8), get(&result, 12));
}
pub fn frames(op: Operation, frame: geometry.RectF, values: [4]f32, auxiliary: geometry.RectF, tokens: tokens_model.DesignTokens) [3]geometry.RectF {
    var request: [128]u8 = @splat(0);
    request[0..4].* = .{ 46, 1, @intFromEnum(op), @import("render_plan_policy.zig").numericFlags() };
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| {
        put(&request, 16 + i * 4, @field(frame, name));
        put(&request, 32 + i * 4, @field(auxiliary, name));
    }
    for (values, 0..) |value, i| put(&request, 48 + i * 4, value);
    var result: [64]u8 = @splat(0xa5);
    const policy = tokens.control_command_policy orelse @panic("missing control payload owner");
    if (policy(&request, &result) != result.len or std.mem.readInt(u32, result[0..4], .little) != 1 or !std.mem.allEqual(u8, result[4..8], 0) or !std.mem.allEqual(u8, result[56..], 0)) @panic("invalid control payload geometry result");
    var copied: [3]geometry.RectF = undefined;
    for (&copied, 0..) |*rect, i| {
        const at = 8 + i * 16;
        rect.* = .init(get(&result, at), get(&result, at + 4), get(&result, at + 8), get(&result, at + 12));
    }
    return copied;
}
