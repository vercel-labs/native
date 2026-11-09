//! Copied paint boundary. Portable code owns all damage geometry; native code
//! supplies requested font measurements and caller-owned result storage.
const std = @import("std");
const geometry = @import("geometry");
const widgets = @import("widgets.zig");
const tokens_model = @import("tokens.zig");
const events = @import("events.zig");
const changes = @import("widget_change_policy.zig");
const text_metrics = @import("text_metrics.zig");
pub const Policy = changes.Policy;
const missing = std.math.maxInt(u32);
const header_size = 544;
const node_size = 128;
const tables = .{ "button_default", "button_primary", "button_secondary", "button_outline", "button_ghost", "button_destructive", "toggle_button", "accordion", "alert", "bubble", "card", "dialog", "drawer", "sheet", "select", "input", "text_field", "search_field", "combobox", "textarea", "list_item", "menu_item", "data_cell", "tabs", "segmented_control", "button_group", "checkbox", "radio", "switch_control", "slider", "progress", "scrollbar", "panel", "resizable", "popover", "menu_surface", "dropdown_menu", "tooltip", "avatar", "badge", "separator", "skeleton", "spinner" };
const sizes = [_]widgets.WidgetSize{ .sm, .default, .lg, .icon, .heading, .display };
pub fn owner(layout: anytype) ?Policy {
    const T = switch (@typeInfo(@TypeOf(layout))) {
        .pointer => |p| p.child,
        else => @TypeOf(layout),
    };
    if (comptime @hasField(T, "paint_policy")) return layout.paint_policy;
    return null;
}
fn word(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("paint wire capacity"), .little);
}
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn float(bytes: []u8, at: usize, value: f32) void {
    word(bytes, at, @as(u32, @bitCast(value)));
}
fn readFloat(bytes: []const u8, at: usize) f32 {
    return @bitCast(read(bytes, at));
}
fn rect(bytes: []u8, at: usize, value: geometry.RectF) void {
    inline for (.{ "x", "y", "width", "height" }, 0..) |name, i| float(bytes, at + i * 4, @field(value, name));
}
fn optional(bytes: []const u8, at: usize) ?geometry.RectF {
    if (read(bytes, at) == 0) return null;
    return .init(readFloat(bytes, at + 4), readFloat(bytes, at + 8), readFloat(bytes, at + 12), readFloat(bytes, at + 16));
}
fn sizeCode(size: widgets.WidgetSize) usize {
    for (sizes, 0..) |candidate, i| if (size == candidate) return i;
    unreachable;
}
fn writeNode(bytes: []u8, node: events.WidgetLayoutNode) void {
    const w = node.widget;
    word(bytes, 0, widgets.widgetKindCode(w.kind));
    word(bytes, 4, sizeCode(w.size));
    word(bytes, 8, @intFromEnum(w.variant));
    word(bytes, 12, if (node.parent_index) |p| @as(u32, @truncate(p)) else missing);
    word(bytes, 124, if (node.parent_index) |p| @as(u64, p) >> 32 else 0);
    word(bytes, 16, @as(u32, @truncate(node.depth)));
    word(bytes, 120, @as(u64, node.depth) >> 32);
    const alignment: u32 = switch (w.text_alignment) {
        .start => 0,
        .center => 1,
        .end => 2,
    };
    const flags = @as(u32, @intFromBool(w.semantics.hidden)) | (@as(u32, @intFromBool(w.layout.clip_content)) << 1) |
        (@as(u32, @intFromBool(w.layout.anchor != null)) << 2) | (@as(u32, @intFromBool(w.scrim)) << 3) |
        (@as(u32, @intFromBool(w.text.len > 0)) << 4) | (@as(u32, @intFromBool(w.icon.len > 0)) << 5) |
        (@as(u32, @intFromBool(w.style.border != null)) << 6) | (@as(u32, @intFromBool(w.style.stroke_width != null)) << 7) |
        (@as(u32, @intFromBool(w.group_segment != .none)) << 8) | (alignment << 9) | (@as(u32, @intFromBool(node.parent_index != null)) << 11);
    word(bytes, 20, flags);
    word(bytes, 24, changes.stateBits(w.state));
    word(bytes, 28, if (w.backdrop_blur_token) |t| @intFromEnum(t) else missing);
    rect(bytes, 32, node.frame);
    rect(bytes, 48, w.frame);
    inline for (.{ "a", "b", "c", "d", "tx", "ty" }, 0..) |name, i| float(bytes, 64 + i * 4, @field(w.transform, name));
    float(bytes, 88, w.value);
    float(bytes, 92, w.style.stroke_width orelse 0);
    if (w.style.border) |border| inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| float(bytes, 96 + i * 4, @field(border, name));
    float(bytes, 112, w.backdrop_blur);
}
fn writeTokens(bytes: []u8, tokens: tokens_model.DesignTokens) void {
    const values = [_]f32{
        tokens.stroke.focus,                         tokens.stroke.focus_offset,                              tokens.stroke.regular,                                                        tokens.stroke.hairline,
        @floatFromInt(@intFromEnum(tokens.density)), @floatFromInt(@intFromBool(tokens.pixel_snap.geometry)), tokens.pixel_snap.scale,                                                      tokens.typography.label_size,
        tokens.metrics.tabs_label_size_step,         tokens.metrics.tabs_trigger_inset,                       tokens.metrics.size_inset_step,                                               tokens.metrics.icon_text_step,
        tokens.metrics.button_icon_gap,              tokens.metrics.tabs_indicator_thickness,                 tokens.metrics.slider_thumb_width,                                            tokens.metrics.slider_thumb_height,
        tokens.shadow.sm.y,                          tokens.shadow.sm.blur,                                   tokens.shadow.sm.spread,                                                      tokens.shadow.md.y,
        tokens.shadow.md.blur,                       tokens.shadow.md.spread,                                 tokens.blur.none,                                                             tokens.blur.sm,
        tokens.blur.md,                              tokens.colors.scrim.a,                                   @floatFromInt(@intFromBool(tokens.controls.button_group_style == .detached)), @floatFromInt(@intFromBool(tokens.controls.tabs_indicator == .underline)),
        tokens.blur.scrim,                           0,                                                       0,                                                                            0,
    };
    for (values, 0..) |v, i| float(bytes, 64 + i * 4, v);
    inline for (tables, 0..) |name, i| {
        const value = @field(tokens.controls, name).stroke_width;
        word(bytes, 192 + i * 8, @intFromBool(value != null));
        float(bytes, 196 + i * 8, value orelse 0);
    }
}
pub const Plan = struct {
    allocator: std.mem.Allocator,
    request: []u8,
    result: []u8,
    length: usize,
    pub fn diff(allocator: std.mem.Allocator, policy: Policy, previous: anytype, next: anytype, tokens: tokens_model.DesignTokens, previous_root: ?geometry.RectF, next_root: ?geometry.RectF, change: changes.Plan) std.mem.Allocator.Error!Plan {
        return init(allocator, policy, previous.nodes, next.nodes, tokens, previous_root, next_root, 1, change.result[0 .. 16 + change.length * 16], change.length);
    }
    pub fn render(allocator: std.mem.Allocator, policy: Policy, layout: anytype, tokens: tokens_model.DesignTokens, change: changes.RenderPlan) std.mem.Allocator.Error!Plan {
        return init(allocator, policy, layout.nodes, &.{}, tokens, null, null, 2, change.result[0 .. 32 + change.length * 16 + (change.group_lengths[0] + change.group_lengths[1]) * 4], 1);
    }
    fn init(allocator: std.mem.Allocator, policy: Policy, previous: []const events.WidgetLayoutNode, next: []const events.WidgetLayoutNode, tokens: tokens_model.DesignTokens, previous_root: ?geometry.RectF, next_root: ?geometry.RectF, mode: u8, payload: []const u8, length: usize) std.mem.Allocator.Error!Plan {
        const total = std.math.add(usize, previous.len, next.len) catch @panic("paint node capacity");
        const base_size = std.math.add(usize, header_size, std.math.mul(usize, total, node_size) catch @panic("paint byte capacity")) catch @panic("paint byte capacity");
        const request = try allocator.alloc(u8, std.math.add(usize, base_size, payload.len) catch @panic("paint payload capacity"));
        errdefer allocator.free(request);
        @memset(request, 0);
        request[0..4].* = .{ 26, 0, 2, @import("render_plan_policy.zig").numericFlags() };
        word(request, 4, previous.len);
        word(request, 8, next.len);
        word(request, 12, payload.len);
        word(request, 16, mode);
        word(request, 28, @as(u32, @intFromBool(previous_root != null)) | (@as(u32, @intFromBool(next_root != null)) << 1));
        if (previous_root) |r| rect(request, 32, r);
        if (next_root) |r| rect(request, 48, r);
        writeTokens(request, tokens);
        for (previous, 0..) |n, i| writeNode(request[header_size + i * node_size ..][0..node_size], n);
        for (next, 0..) |n, i| writeNode(request[header_size + (previous.len + i) * node_size ..][0..node_size], n);
        const measurements = try allocator.alloc(u8, std.math.add(usize, 8, std.math.mul(usize, total, 8) catch @panic("paint measurement capacity")) catch @panic("paint measurement capacity"));
        defer allocator.free(measurements);
        @memset(measurements, 0xa5);
        @memcpy(request[base_size..], payload);
        const measured = policy(request, measurements);
        if (measured < 8 or measured > measurements.len or !std.mem.eql(u8, measurements[0..4], &.{ 1, 0, 0, 0 })) @panic("invalid compiled paint measurement header");
        const measure_count = read(measurements, 4);
        if (measure_count > total or measured != 8 + @as(usize, measure_count) * 8) @panic("invalid compiled paint measurement count");
        // Validate the entire request list before calling the native capability.
        for (0..measure_count) |i| {
            const slot = read(measurements, 8 + i * 8);
            if (slot >= total) @panic("invalid compiled paint measurement slot");
            for (0..i) |earlier| if (read(measurements, 8 + earlier * 8) == slot) @panic("duplicate compiled paint measurement slot");
        }
        for (0..measure_count) |i| {
            const slot = read(measurements, 8 + i * 8);
            const node = if (slot < previous.len) previous[slot] else next[slot - previous.len];
            const size = readFloat(measurements, 12 + i * 8);
            const width = text_metrics.measureTextWidthForFontWithPolicy(tokens.text_measure, tokens.text_run_policy, tokens.typography.font_id, node.widget.text, size);
            float(request, header_size + @as(usize, slot) * node_size + 116, width);
        }
        request[1] = mode;
        word(request, 12, payload.len);
        @memcpy(request[base_size..], payload);
        const result = try allocator.alloc(u8, std.math.add(usize, 8, std.math.mul(usize, length, 20) catch @panic("paint result capacity")) catch @panic("paint result capacity"));
        errdefer allocator.free(result);
        @memset(result, 0xa5);
        const written = policy(request, result);
        if (written != result.len or !std.mem.eql(u8, result[0..4], &.{ 1, mode, 0, 0 }) or read(result, 4) != length) @panic("invalid compiled paint result header");
        for (0..length) |i| {
            const at = 8 + i * 20;
            if (read(result, at) > 1) @panic("invalid compiled paint result presence");
            if (read(result, at) == 0 and !std.mem.allEqual(u8, result[at + 4 ..][0..16], 0)) @panic("invalid compiled absent paint bounds");
        }
        return .{ .allocator = allocator, .request = request, .result = result, .length = length };
    }
    pub fn bounds(self: Plan, slot: usize) ?geometry.RectF {
        return optional(self.result, 8 + slot * 20);
    }
    pub fn deinit(self: Plan) void {
        self.allocator.free(self.request);
        self.allocator.free(self.result);
    }
};
