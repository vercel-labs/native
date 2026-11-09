//! Copied numeric boundary for compiled portable control appearance.
const std = @import("std");
const widget_model = @import("widgets.zig");
const token_model = @import("tokens.zig");
const drawing = @import("drawing.zig");
const Widget = widget_model.Widget;
const Tokens = token_model.DesignTokens;
const Visual = token_model.ControlVisualTokens;
const Color = drawing.Color;
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Family = enum(u8) { button, text_input, selection, surface, component, list, select };
const table_names = .{ "button_default", "button_primary", "button_secondary", "button_outline", "button_ghost", "button_destructive", "toggle_button", "accordion", "alert", "bubble", "card", "dialog", "drawer", "sheet", "select", "input", "text_field", "search_field", "combobox", "textarea", "list_item", "menu_item", "data_cell", "tabs", "segmented_control", "button_group", "checkbox", "radio", "switch_control", "slider", "progress", "scrollbar", "panel", "resizable", "popover", "menu_surface", "dropdown_menu", "tooltip", "avatar", "badge", "separator", "skeleton", "spinner" };
comptime {
    const names = .{ "stack", "row", "column", "grid", "data_grid", "table", "scroll_view", "list", "breadcrumb", "button_group", "pagination", "radio_group", "tabs", "toggle_group", "accordion", "bubble", "resizable", "alert", "card", "dialog", "drawer", "sheet", "panel", "popover", "menu_surface", "dropdown_menu", "text", "icon", "image", "avatar", "badge", "button", "toggle_button", "icon_button", "select", "input", "text_field", "search_field", "combobox", "textarea", "tooltip", "menu_item", "list_item", "data_row", "data_cell", "status_bar", "segmented_control", "checkbox", "radio", "switch_control", "toggle", "slider", "progress", "separator", "skeleton", "spinner", "chart", "split", "split_divider", "tree", "input_group", "media_surface", "terminal" };
    const actual = @typeInfo(widget_model.WidgetKind).@"enum".fields;
    if (actual.len != names.len) @compileError("update control appearance kind wire");
    for (names, actual) |name, field| if (!std.mem.eql(u8, name, field.name)) @compileError("control appearance kind wire changed");
}
fn header(out: []u8, widget: Widget, tokens: Tokens, op: u8, family: u8) void {
    @memset(out, 0);
    out[0..8].* = .{ 16, op, family, @intCast(@intFromEnum(widget.kind)), @intCast(@intFromEnum(widget.variant)), @intCast(@intFromEnum(widget.size)), @as(u8, @intFromBool(widget.state.disabled)) | (@as(u8, @intFromBool(widget.state.pressed)) << 1) | (@as(u8, @intFromBool(widget.state.selected)) << 2) | (@as(u8, @intFromBool(widget.state.hovered)) << 3) | (@as(u8, @intFromBool(widget.style.quiet_hover)) << 4), @as(u8, @intFromBool(widget.group_segment != .none)) | (@as(u8, @intFromBool(tokens.controls.button_group_style == .detached)) << 1) };
}
fn table(tokens: Tokens, index: u8) Visual {
    if (index == 255) return .{};
    inline for (table_names, 0..) |name, i| if (index == i) return @field(tokens.controls, name);
    @panic("invalid compiled appearance table");
}
pub fn visual(widget: Widget, tokens: Tokens, family: Family) Visual {
    var input: [8]u8 = undefined;
    header(&input, widget, tokens, 0, @intFromEnum(family));
    var output: [4]u8 = undefined;
    if (widget.appearance_policy.?(&input, &output) != 4 or output[2] > 1 or output[3] != 0 or (output[2] == 1 and output[1] == 255)) @panic("invalid compiled appearance family");
    const primary = table(tokens, output[0]);
    if (output[2] == 0) return primary;
    var request: [320]u8 = undefined;
    header(&request, widget, tokens, 1, 0);
    putVisual(request[8..164], primary);
    putVisual(request[164..320], table(tokens, output[1]));
    var merged: [156]u8 = undefined;
    if (widget.appearance_policy.?(&request, &merged) != merged.len) @panic("invalid compiled appearance fallback");
    return readVisual(&merged);
}
pub fn context(widget: Widget, tokens: Tokens, op: u8, value: Visual, fallback: Color, scalar_value: f32) [496]u8 {
    var out: [496]u8 = undefined;
    header(&out, widget, tokens, op, 0);
    putVisual(out[8..164], value);
    var style_mask: u32 = 0;
    inline for (.{ "background", "foreground", "accent", "accent_foreground", "border", "focus_ring" }, 0..) |name, i| if (@field(widget.style, name)) |color_value| {
        style_mask |= @as(u32, 1) << @intCast(i);
        putColor(out[168 + i * 16 ..][0..16], color_value);
    };
    if (widget.style.radius) |v| {
        style_mask |= 64;
        putFloat(out[264..268], v);
    }
    if (widget.style.stroke_width) |v| {
        style_mask |= 128;
        putFloat(out[268..272], v);
    }
    std.mem.writeInt(u32, out[164..168], style_mask, .little);
    inline for (.{ "surface", "surface_subtle", "surface_pressed", "accent", "accent_text", "destructive", "text", "background" }, 0..) |name, i| putColor(out[272 + i * 16 ..][0..16], @field(tokens.colors, name));
    inline for (.{ "disabled_alpha", "hover_fill_alpha", "pressed_fill_alpha", "secondary_hover_alpha", "destructive_wash_alpha", "destructive_wash_hover_alpha", "destructive_wash_pressed_alpha", "badge_destructive_wash_alpha", "selection_wash_alpha" }, 0..) |name, i| putFloat(out[400 + i * 4 ..][0..4], @field(tokens.states, name));
    putFloat(out[436..440], tokens.radius.md);
    putFloat(out[440..444], tokens.radius.lg);
    putFloat(out[444..448], tokens.stroke.hairline);
    putFloat(out[448..452], tokens.stroke.regular);
    if (tokens.controls.button_disabled_border) |v| {
        std.mem.writeInt(u32, out[452..456], 1, .little);
        putColor(out[456..472], v);
    }
    putColor(out[472..488], fallback);
    putFloat(out[488..492], scalar_value);
    std.mem.writeInt(u32, out[492..496], numericFlags(), .little);
    return out;
}
pub fn color(widget: Widget, tokens: Tokens, op: u8, value: Visual, fallback: Color) Color {
    const request = context(widget, tokens, op, value, fallback, 0);
    var out: [16]u8 = undefined;
    if (widget.appearance_policy.?(&request, &out) != out.len) @panic("invalid compiled appearance color");
    return readColor(&out);
}
pub fn scalar(widget: Widget, tokens: Tokens, op: u8, value: Visual, fallback: f32) f32 {
    const request = context(widget, tokens, op, value, .{}, fallback);
    var out: [4]u8 = undefined;
    if (widget.appearance_policy.?(&request, &out) != out.len) @panic("invalid compiled appearance scalar");
    return readFloat(&out);
}
pub fn detached(widget: Widget, tokens: Tokens) bool {
    const request = context(widget, tokens, 31, .{}, .{}, 0);
    var out: [1]u8 = undefined;
    if (widget.appearance_policy.?(&request, &out) != 1 or out[0] > 1) @panic("invalid compiled appearance group");
    return out[0] == 1;
}
const visual_colors = .{ "background", "hover_background", "active_background", "pressed_background", "disabled_background", "disabled_foreground", "foreground", "active_foreground", "border" };
fn putVisual(out: []u8, value: Visual) void {
    @memset(out, 0);
    var mask: u32 = 0;
    inline for (visual_colors, 0..) |name, i| if (@field(value, name)) |v| {
        mask |= @as(u32, 1) << @intCast(i);
        putColor(out[4 + i * 16 ..][0..16], v);
    };
    if (value.radius) |v| {
        mask |= 512;
        putFloat(out[148..152], v);
    }
    if (value.stroke_width) |v| {
        mask |= 1024;
        putFloat(out[152..156], v);
    }
    std.mem.writeInt(u32, out[0..4], mask, .little);
}
fn readVisual(bytes: []const u8) Visual {
    const mask = std.mem.readInt(u32, bytes[0..4], .little);
    if (mask > 2047) @panic("invalid compiled visual presence");
    var value: Visual = .{};
    inline for (visual_colors, 0..) |name, i| if (mask & (@as(u32, 1) << @intCast(i)) != 0) {
        @field(value, name) = readColor(bytes[4 + i * 16 ..][0..16]);
    };
    if (mask & 512 != 0) value.radius = readFloat(bytes[148..152]);
    if (mask & 1024 != 0) value.stroke_width = readFloat(bytes[152..156]);
    return value;
}
fn putFloat(bytes: []u8, v: f32) void {
    std.mem.writeInt(u32, bytes[0..4], @bitCast(v), .little);
}
fn readFloat(bytes: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
}
fn putColor(bytes: []u8, v: Color) void {
    inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| putFloat(bytes[i * 4 ..][0..4], @field(v, name));
}
fn readColor(bytes: []const u8) Color {
    var v: Color = undefined;
    inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| @field(v, name) = readFloat(bytes[i * 4 ..][0..4]);
    return v;
}

fn numericFlags() u32 {
    var negative_zero: f32 = -0.0;
    std.mem.doNotOptimizeAway(&negative_zero);
    return if (@as(u32, @bitCast(@max(0, negative_zero))) == 0x80000000) 4 else 0;
}
