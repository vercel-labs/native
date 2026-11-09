//! Copied accessibility facts. Native owns borrowed strings, exact identities,
//! text history, fingerprints and OS publication; compiled code derives nodes.
const std = @import("std");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const bridge = @import("widget_bridge.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Publication = enum { unchanged, deferred, publish };
const roles = [_]canvas.WidgetRole{ .none, .group, .text, .link, .image, .button, .textbox, .tooltip, .dialog, .menu, .menuitem, .list, .listitem, .row, .grid, .gridcell, .tab, .checkbox, .radio, .radiogroup, .switch_control, .slider, .progressbar, .chart, .tree, .treeitem, .separator };
const states = [_][]const u8{ "hovered", "pressed", "focused", "disabled", "selected", "required", "read_only", "invalid" };
comptime {
    if (roles.len != @typeInfo(canvas.WidgetRole).@"enum".fields.len or platform.max_widget_accessibility_nodes != 64) @compileError("update accessibility packet limits");
}
fn roleCode(role: canvas.WidgetRole) u32 {
    for (roles, 0..) |candidate, i| if (role == candidate) return @intCast(i);
    unreachable;
}
fn word(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn identity(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
fn run(policy: Policy, request: []const u8, output: []u8) void {
    if (policy(request, output) != output.len) @panic("invalid compiled accessibility result size");
}
pub fn publication(policy: Policy, published: bool, previous: u64, next: u64, allow_deferral: bool, defer_live: bool) Publication {
    var request: [20]u8 = @splat(0);
    request[0..4].* = .{ 68, 1, @intFromBool(published), @as(u8, @intFromBool(allow_deferral)) | (@as(u8, @intFromBool(defer_live)) << 1) };
    identity(&request, 4, next);
    identity(&request, 12, previous);
    var output: [4]u8 = undefined;
    run(policy, &request, &output);
    if (output[0] > 2 or !std.mem.eql(u8, output[1..], &.{ 0, 0, 0 })) @panic("invalid compiled accessibility publication");
    return @enumFromInt(output[0]);
}
pub fn flush(policy: Policy, pending: bool, frame_requested: bool, force: bool) bool {
    const request = [_]u8{ 68, 2, @intFromBool(pending), @as(u8, @intFromBool(frame_requested)) | (@as(u8, @intFromBool(force)) << 1) };
    var output: [4]u8 = undefined;
    run(policy, &request, &output);
    if (output[0] > 1 or !std.mem.eql(u8, output[1..], &.{ 0, 0, 0 })) @panic("invalid compiled accessibility flush");
    return output[0] == 1;
}
pub fn project(allocator: std.mem.Allocator, policy: Policy, semantics: []const canvas.WidgetSemanticsNode, keyboard_active: bool, focused: bool, focused_id: u64, hovered_id: u64, pressed_id: u64, output: []platform.WidgetAccessibilityNode) ![]platform.WidgetAccessibilityNode {
    if (semantics.len > 1024 or output.len > platform.max_widget_accessibility_nodes) return error.InvalidViewOptions;
    const request = try allocator.alloc(u8, 40 + semantics.len * 32);
    defer allocator.free(request);
    @memset(request, 0);
    request[0..4].* = .{ 68, 0, @intFromBool(keyboard_active), @intFromBool(focused) };
    word(request, 4, @intCast(semantics.len));
    word(request, 8, @intCast(output.len));
    identity(request, 16, focused_id);
    identity(request, 24, hovered_id);
    identity(request, 32, pressed_id);
    for (semantics, 0..) |node, i| {
        const at = 40 + i * 32;
        identity(request, at, node.id);
        word(request, at + 8, if (node.parent_index) |p| std.math.cast(u32, p) orelse std.math.maxInt(u32) else std.math.maxInt(u32));
        word(request, at + 12, roleCode(node.role));
        var state: u32 = 0;
        inline for (states, 0..) |field, bit| if (@field(node.state, field)) {
            state |= @as(u32, 1) << @intCast(bit);
        };
        word(request, at + 16, state);
        const flags: u32 = @as(u32, @intFromBool(node.list.present)) | (@as(u32, @intFromBool(node.scroll.present)) << 1) | (@as(u32, @intFromBool(node.value != null)) << 2) | (@as(u32, @intFromBool(node.focusable)) << 3) | (@as(u32, @intFromBool(node.state.expanded != null)) << 4) | (@as(u32, @intFromBool(node.state.expanded orelse false)) << 5);
        word(request, at + 20, flags);
        word(request, at + 24, @bitCast(node.value orelse @as(f32, 0)));
        var actions: u32 = 0;
        inline for (@typeInfo(platform.WidgetAccessibilityActions).@"struct".fields, 0..) |field, bit| if (@field(node.actions, field.name)) {
            actions |= @as(u32, 1) << @intCast(bit);
        };
        word(request, at + 28, actions);
    }
    const count = @min(output.len, semantics.len);
    const result = try allocator.alloc(u8, 8 + count * 28);
    defer allocator.free(result);
    run(policy, request, result);
    if (read(result, 0) != count or read(result, 4) != 0) @panic("invalid compiled accessibility node count");
    for (output[0..count], semantics[0..count], 0..) |*target, node, i| {
        const at = 8 + i * 28;
        const flags = read(result, at + 16);
        const present = read(result, at + 20);
        const actions = read(result, at + 24);
        if (read(result, at + 8) > 1 or flags > 2047 or present > 3 or actions > 2047) @panic("invalid compiled accessibility node flags");
        target.* = .{
            .id = node.id,
            .parent_id = if (read(result, at + 8) == 1) std.mem.readInt(u64, result[at..][0..8], .little) else null,
            .role = std.enums.fromInt(platform.WidgetAccessibilityRole, read(result, at + 12)) orelse @panic("invalid compiled accessibility role"),
            .label = node.label,
            .text_value = node.text_value,
            .placeholder = node.placeholder,
            .text_selection = bridge.platformWidgetAccessibilityTextRange(node.text_selection),
            .text_composition = bridge.platformWidgetAccessibilityTextRange(node.text_composition),
            .value = node.value,
            .bounds = node.bounds,
            .grid_row_index = node.grid_row_index,
            .grid_column_index = node.grid_column_index,
            .grid_row_count = node.grid_row_count,
            .grid_column_count = node.grid_column_count,
            .list_item_index = if (present & 1 != 0) node.list.item_index else null,
            .list_item_count = if (present & 1 != 0) node.list.item_count else null,
            .scroll_offset = if (present & 2 != 0) node.scroll.offset else null,
            .scroll_viewport_extent = if (present & 2 != 0) node.scroll.viewport_extent else null,
            .scroll_content_extent = if (present & 2 != 0) node.scroll.content_extent else null,
            .enabled = flags & 1 != 0,
            .focused = flags & 2 != 0,
            .hovered = flags & 4 != 0,
            .pressed = flags & 8 != 0,
            .selected = flags & 16 != 0,
            .required = flags & 32 != 0,
            .read_only = flags & 64 != 0,
            .invalid = flags & 128 != 0,
            .expanded = if (flags & 256 != 0) flags & 512 != 0 else null,
            .focusable = flags & 1024 != 0,
        };
        inline for (@typeInfo(platform.WidgetAccessibilityActions).@"struct".fields, 0..) |field, bit| @field(target.actions, field.name) = actions & (@as(u32, 1) << @intCast(bit)) != 0;
    }
    return output[0..count];
}
