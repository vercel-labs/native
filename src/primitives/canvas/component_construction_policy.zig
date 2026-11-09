//! Owned packets for portable construction; IDs, routes, tokens and arenas
//! remain native capabilities. A malformed compiled result never falls back.
const std = @import("std");
const widgets = @import("widgets.zig");
const tokens = @import("tokens.zig");
const geometry = @import("geometry");
const Color = @import("drawing.zig").Color;
pub const Policy = *const fn ([]const u8, []u8) usize;
const Widget = widgets.Widget;
const color_fields = .{ "background", "foreground", "accent", "accent_foreground", "border", "focus_ring" };
const ref_fields = .{ "background", "foreground", "accent", "accent_foreground", "border_color", "focus_ring", "radius" };
const action_fields = .{ "focus", "press", "toggle", "increment", "decrement", "set_text", "set_selection", "select", "drag", "drop_files", "dismiss" };
comptime {
    @setEvalBranchQuota(10000);
    const names = .{ "stack", "row", "column", "grid", "data_grid", "table", "scroll_view", "list", "breadcrumb", "button_group", "pagination", "radio_group", "tabs", "toggle_group", "accordion", "bubble", "resizable", "alert", "card", "dialog", "drawer", "sheet", "panel", "popover", "menu_surface", "dropdown_menu", "text", "icon", "image", "avatar", "badge", "button", "toggle_button", "icon_button", "select", "input", "text_field", "search_field", "combobox", "textarea", "tooltip", "menu_item", "list_item", "data_row", "data_cell", "status_bar", "segmented_control", "checkbox", "radio", "switch_control", "toggle", "slider", "progress", "separator", "skeleton", "spinner", "chart", "split", "split_divider", "tree", "input_group", "media_surface", "terminal" };
    const actual = @typeInfo(widgets.WidgetKind).@"enum".fields;
    if (actual.len != names.len) @compileError("update construction kind wire");
    for (names, actual) |name, field| if (!std.mem.eql(u8, name, field.name)) @compileError("construction kind wire changed");
    const colors = .{ "background", "surface", "surface_subtle", "surface_pressed", "text", "text_muted", "syntax_plain", "syntax_comment", "syntax_keyword", "syntax_literal", "syntax_function", "syntax_property", "syntax_constant", "border", "accent", "accent_text", "destructive", "destructive_text", "success", "success_text", "warning", "warning_text", "info", "info_text", "focus_ring", "shadow", "scrim", "disabled" };
    const color_actual = @typeInfo(tokens.ColorTokens).@"struct".fields;
    if (color_actual.len != colors.len) @compileError("update construction token wire");
    for (colors, color_actual) |name, field| if (!std.mem.eql(u8, name, field.name)) @compileError("construction color wire changed");
    guardEnum(std.meta.FieldEnum(tokens.ColorTokens), colors);
    const radii = .{ "sm", "md", "lg", "xl", "none" };
    const radius_actual = @typeInfo(tokens.RadiusTokens).@"struct".fields;
    if (radius_actual.len != radii.len) @compileError("update construction radius wire");
    for (radii, radius_actual) |name, field| if (!std.mem.eql(u8, name, field.name)) @compileError("construction radius wire changed");
    guardEnum(std.meta.FieldEnum(tokens.RadiusTokens), radii);
    const builtins = .{ "accordion", "alert", "avatar", "badge", "breadcrumb", "bubble", "button", "button_group", "card", "checkbox", "combobox", "dialog", "drawer", "dropdown_menu", "input", "pagination", "progress", "radio_group", "resizable", "select", "separator", "sheet", "skeleton", "slider", "spinner", "switch_control", "table", "tabs", "textarea", "toggle", "toggle_group", "tooltip" };
    const builtin_actual = @typeInfo(widgets.BuiltinComponentKind).@"enum".fields;
    if (builtin_actual.len != builtins.len) @compileError("update construction builtin wire");
    for (builtins, builtin_actual) |name, field| if (!std.mem.eql(u8, name, field.name)) @compileError("construction builtin wire changed");
    guardEnum(widgets.WidgetSize, .{ "default", "sm", "lg", "icon", "heading", "display" });
    guardEnum(widgets.WidgetVariant, .{ "default", "primary", "secondary", "outline", "ghost", "destructive" });
    guardEnum(widgets.WidgetCrossAlignment, .{ "stretch", "start", "center", "end" });
    guardEnum(widgets.WidgetAnchorPlacement, .{ "below", "above" });
    guardEnum(widgets.WidgetAnchorAlignment, .{ "start", "end", "stretch" });
    guardEnum(widgets.WidgetRole, .{ "none", "group", "text", "link", "image", "button", "textbox", "tooltip", "dialog", "menu", "menuitem", "list", "listitem", "row", "grid", "gridcell", "tab", "checkbox", "radio", "radiogroup", "switch_control", "slider", "progressbar", "chart", "tree", "treeitem", "separator" });
    const action_actual = @typeInfo(widgets.WidgetActions).@"struct".fields;
    if (action_actual.len != action_fields.len) @compileError("update construction action wire");
    for (action_fields, action_actual) |name, field| if (!std.mem.eql(u8, name, field.name)) @compileError("construction action wire changed");
}

fn guardEnum(comptime T: type, comptime names: anytype) void {
    const fields = @typeInfo(T).@"enum".fields;
    if (fields.len != names.len) @compileError("update construction enum wire");
    for (names, fields, 0..) |name, field, i| if (!std.mem.eql(u8, name, field.name) or field.value != i) @compileError("construction enum wire changed");
}

pub fn element(policy: Policy, widget: *Widget, options: anytype) void {
    var input: [40]u8 = @splat(0);
    input[0..6].* = .{ 17, 0, @intCast(@intFromEnum(widget.kind)), @intCast(@intFromEnum(options.size)), @as(u8, @intFromBool(options.checked)) | (@as(u8, @intFromBool(options.selected)) << 1) | (@as(u8, @intFromBool(options.padding != null)) << 2), @intCast(@intFromEnum(options.cross)) };
    const values = [_]f32{ options.width, options.height, options.min_width, options.max_width, options.padding orelse 0, options.gap, options.value };
    for (values, 0..) |value, i| putFloat(input[8 + i * 4 ..][0..4], value);
    // These facts describe the target's max-number zero convention,
    // independent of authored values; TS selects the result's source word.
    var negative: f32 = -0.0;
    var positive: f32 = 0.0;
    std.mem.doNotOptimizeAway(&negative);
    std.mem.doNotOptimizeAway(&positive);
    const flags: u32 = @as(u32, @intFromBool(@as(u32, @bitCast(@max(negative, positive))) == 0x80000000)) | (@as(u32, @intFromBool(@as(u32, @bitCast(@max(positive, negative))) == 0x80000000)) << 1);
    std.mem.writeInt(u32, input[36..40], flags, .little);
    var out: [44]u8 = undefined;
    if (policy(&input, &out) != out.len or out[0] > 1 or out[1] > 3 or out[2] > 1 or out[3] != 0) @panic("invalid compiled element construction");
    widget.state.selected = out[0] == 1;
    widget.layout.cross_alignment = @enumFromInt(out[1]);
    widget.layout.padding_is_kind_default = out[2] == 1;
    widget.layout.gap = readFloat(out[4..8]);
    readPadding(&widget.layout, out[8..24]);
    widget.layout.min_size = .{ .width = readFloat(out[24..28]), .height = readFloat(out[28..32]) };
    widget.layout.max_size = .{ .width = readFloat(out[32..36]), .height = readFloat(out[36..40]) };
    widget.value = readFloat(out[40..44]);
}

pub const FinalPlan = struct { make_span: bool, split: bool };
pub fn finalize(policy: Policy, widget: *Widget, refs: anytype, live_tokens: tokens.DesignTokens, wrap: ?bool, two_children: bool, handlers: u16) FinalPlan {
    var input: [592]u8 = @splat(0);
    input[0..5].* = .{ 17, 1, @intCast(@intFromEnum(widget.kind)), if (wrap) |v| if (v) 2 else 1 else 0, @as(u8, @intFromBool(widget.spans.len > 0)) | (@as(u8, @intFromBool(widget.text.len > 0)) << 1) | (@as(u8, @intFromBool(two_children)) << 2) | (@as(u8, @intFromBool(widget.hover_msgs)) << 3) | (@as(u8, @intFromBool(widget.text_no_wrap)) << 4) };
    inline for (ref_fields, 0..) |name, i| input[8 + i] = if (@field(refs, name)) |v| @intCast(@intFromEnum(v)) else 255;
    std.mem.writeInt(u16, input[16..18], actionsMask(widget.semantics.actions), .little);
    std.mem.writeInt(u16, input[18..20], handlers, .little);
    var mask: u32 = 0;
    inline for (color_fields, 0..) |name, i| if (@field(widget.style, name)) |v| {
        mask |= @as(u32, 1) << @intCast(i);
        putColor(input[24 + i * 16 ..][0..16], v);
    };
    if (widget.style.radius) |v| {
        mask |= 64;
        putFloat(input[120..124], v);
    }
    std.mem.writeInt(u32, input[20..24], mask, .little);
    inline for (@typeInfo(tokens.ColorTokens).@"struct".fields, 0..) |field, i| putColor(input[124 + i * 16 ..][0..16], @field(live_tokens.colors, field.name));
    inline for (@typeInfo(tokens.RadiusTokens).@"struct".fields, 0..) |field, i| putFloat(input[572 + i * 4 ..][0..4], @field(live_tokens.radius, field.name));
    var out: [108]u8 = undefined;
    if (policy(&input, &out) != out.len or std.mem.readInt(u16, out[0..2], .little) > 2047 or out[2] > 15 or out[3] != 0) @panic("invalid compiled final construction");
    mask = std.mem.readInt(u32, out[4..8], .little);
    if (mask > 127) @panic("invalid compiled construction style presence");
    widget.semantics.actions = readActions(std.mem.readInt(u16, out[0..2], .little));
    widget.text_no_wrap = out[2] & 2 != 0;
    widget.hover_msgs = out[2] & 8 != 0;
    inline for (color_fields, 0..) |name, i| @field(widget.style, name) = if (mask & (@as(u32, 1) << @intCast(i)) != 0) readColor(out[8 + i * 16 ..][0..16]) else null;
    widget.style.radius = if (mask & 64 != 0) readFloat(out[104..108]) else null;
    if (out[2] & 4 != 0 and (widget.kind != .split or !two_children)) @panic("invalid compiled split child capacity");
    if (out[2] & 1 != 0 and (widget.kind != .text or widget.spans.len != 0 or widget.text.len == 0)) @panic("invalid compiled span ownership");
    return .{ .make_span = out[2] & 1 != 0, .split = out[2] & 4 != 0 };
}

pub const Synthesized = struct { widget: Widget, item_identity: bool };
pub fn synthesize(policy: Policy, stage: u8, disabled: bool, separator: bool, enabled: bool, value: f32, point: ?geometry.PointF, arena: std.mem.Allocator) error{OutOfMemory}!Synthesized {
    var input: [24]u8 = @splat(0);
    input[0..4].* = .{ 17, 2, stage, @as(u8, @intFromBool(disabled)) | (@as(u8, @intFromBool(separator)) << 1) | (@as(u8, @intFromBool(enabled)) << 2) | (@as(u8, @intFromBool(point != null)) << 3) };
    putFloat(input[8..12], value);
    if (point) |v| {
        putFloat(input[12..16], v.x);
        putFloat(input[16..20], v.y);
    }
    var out: [64]u8 = undefined;
    const len = policy(&input, &out);
    if (len < 24 or len > out.len or out[0] > 62 or out[1] > 1 or out[2] > 1 or out[3] > 1 or out[20] > 1 or out[21] > 2 or out[22] > 1 or out[23] > 1) @panic("invalid compiled synthesized construction");
    var widget: Widget = .{
        .kind = @enumFromInt(out[0]),
        .state = .{ .disabled = out[1] == 1 },
        .value = readFloat(out[4..8]),
        .semantics = .{ .label = try arena.dupe(u8, out[24..len]), .actions = .{ .press = out[2] == 1 } },
    };
    if (out[23] == 1) widget.layout.anchor = .{
        .placement = @enumFromInt(out[20]),
        .alignment = @enumFromInt(out[21]),
        .offset = readFloat(out[8..12]),
        .point = if (out[3] == 1) .{ .x = readFloat(out[12..16]), .y = readFloat(out[16..20]) } else null,
    };
    return .{ .widget = widget, .item_identity = out[22] == 1 };
}

pub fn builtin(policy: Policy, component: widgets.BuiltinComponentKind, widget: *Widget, options: widgets.BuiltinComponentOptions) void {
    var input: [36]u8 = @splat(0);
    input[0..8].* = .{ 17, 3, @intCast(@intFromEnum(component)), if (options.variant) |v| @intCast(@intFromEnum(v)) else 255, if (options.size) |v| @intCast(@intFromEnum(v)) else 255, @intCast(@intFromEnum(options.semantics.role)), @intCast(@intFromEnum(options.layout.cross_alignment)), @as(u8, @intFromBool(options.layout.clip_content)) | (@as(u8, @intFromBool(options.layout.padding_is_kind_default)) << 1) };
    putPadding(input[8..24], options.layout);
    putFloat(input[24..28], options.layout.gap);
    putFloat(input[28..32], options.layout.min_size.width);
    putFloat(input[32..36], options.layout.min_size.height);
    var out: [36]u8 = undefined;
    if (policy(&input, &out) != out.len or out[0] > 62 or out[1] > 5 or out[2] > 5 or out[3] >= @typeInfo(widgets.WidgetRole).@"enum".fields.len or out[4] > 3 or out[5] > 1 or out[6] > 1 or out[7] != 0) @panic("invalid compiled builtin construction");
    widget.kind = @enumFromInt(out[0]);
    widget.variant = @enumFromInt(out[1]);
    widget.size = @enumFromInt(out[2]);
    widget.semantics.role = @enumFromInt(out[3]);
    widget.layout.cross_alignment = @enumFromInt(out[4]);
    widget.layout.clip_content = out[5] == 1;
    widget.layout.padding_is_kind_default = out[6] == 1;
    readPadding(&widget.layout, out[8..24]);
    widget.layout.gap = readFloat(out[24..28]);
    widget.layout.min_size = .{ .width = readFloat(out[28..32]), .height = readFloat(out[32..36]) };
}

fn actionsMask(value: widgets.WidgetActions) u16 {
    var result: u16 = 0;
    inline for (action_fields, 0..) |name, i| if (@field(value, name)) {
        result |= @as(u16, 1) << @intCast(i);
    };
    return result;
}
fn readActions(mask: u16) widgets.WidgetActions {
    var result: widgets.WidgetActions = .{};
    inline for (action_fields, 0..) |name, i| @field(result, name) = mask & (@as(u16, 1) << @intCast(i)) != 0;
    return result;
}
fn putPadding(bytes: []u8, value: widgets.WidgetLayoutStyle) void {
    inline for (.{ "top", "right", "bottom", "left" }, 0..) |name, i| putFloat(bytes[i * 4 ..][0..4], @field(value.padding, name));
}
fn readPadding(value: *widgets.WidgetLayoutStyle, bytes: []const u8) void {
    inline for (.{ "top", "right", "bottom", "left" }, 0..) |name, i| @field(value.padding, name) = readFloat(bytes[i * 4 ..][0..4]);
}
fn putFloat(bytes: []u8, value: f32) void {
    std.mem.writeInt(u32, bytes[0..4], @bitCast(value), .little);
}
fn readFloat(bytes: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
}
fn putColor(bytes: []u8, value: Color) void {
    inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| putFloat(bytes[i * 4 ..][0..4], @field(value, name));
}
fn readColor(bytes: []const u8) Color {
    var value: Color = undefined;
    inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| @field(value, name) = readFloat(bytes[i * 4 ..][0..4]);
    return value;
}
