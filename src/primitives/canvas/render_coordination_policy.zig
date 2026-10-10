//! Copied paint recipes and sibling programs. Display-list storage stays native.
const std = @import("std");
const widgets = @import("widgets.zig");
const tokens = @import("tokens.zig");
const widget_access = @import("widget_access.zig");
pub const reference = @import("widget_tree.zig");
pub const Policy = @import("surface_layout_policy.zig").Policy;
pub const Mode = enum(u8) { tree, retained };
pub const Status = enum(u32) { ready, hidden, depth };
pub const Opcode = enum(u32) { backdrop, draw, scrim, children, separators, scrollbars, reactions };
pub const Draw = enum(u32) {
    container,
    data_row,
    tabs,
    alert,
    card,
    dialog,
    drawer,
    sheet,
    accordion,
    bubble,
    panel,
    popover,
    menu,
    text,
    code_paragraph,
    spans,
    icon,
    image,
    media,
    terminal,
    avatar,
    badge,
    button,
    icon_button,
    select,
    text_field,
    code_editor,
    search,
    tooltip,
    menu_item,
    list_item,
    data_cell,
    status,
    segmented,
    checkbox,
    radio,
    toggle,
    slider,
    progress,
    separator,
    split_divider,
    skeleton,
    spinner,
    chart,
    input_group,
};
pub const Command = struct { opcode: Opcode, arg: u32 };
fn word(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub const Recipe = struct {
    status: Status,
    count: usize,
    commands: [6]Command,
    pub fn init(policy: Policy, mode: Mode, widget: widgets.Widget, t: tokens.DesignTokens, depth: usize, disclosure: u8, code_paragraph: bool) Recipe {
        var request: [32]u8 = @splat(0);
        request[0..4].* = .{ 43, 1, @intFromEnum(mode), disclosure };
        var flags: u32 = 0;
        for ([_]bool{ widget.layout.clip_content, widget.layout.virtualized, widget.spans.len > 0, code_paragraph, widget.runtime_flags.code_editor, widget.runtime_flags.native_scroll, widget_access.booleanControlSelected(widget), widget.children.len > 0, widget.semantics.hidden, t.controls.button_group_style == .detached, widget.scrim }, 0..) |value, i|
            flags |= @as(u32, @intFromBool(value)) << @intCast(i);
        word(&request, 4, flags);
        std.mem.writeInt(u64, request[8..16], depth, .little);
        word(&request, 16, @bitCast(widget.layout.gap));
        word(&request, 20, @intFromEnum(widget.kind));
        var result: [64]u8 = @splat(0xa5);
        if (policy(&request, &result) != 64 or read(&result, 0) != 1 or read(&result, 4) > 2 or read(&result, 8) > 6 or read(&result, 12) != 0)
            @panic("invalid render recipe result");
        const count = read(&result, 8);
        if (read(&result, 4) != 0 and count != 0) @panic("invalid inactive render recipe");
        if (!std.mem.allEqual(u8, result[16 + count * 8 ..], 0)) @panic("invalid render recipe tail");
        var recipe: Recipe = .{ .status = @enumFromInt(read(&result, 4)), .count = count, .commands = undefined };
        for (recipe.commands[0..count], 0..) |*command, i| {
            const op = read(&result, 16 + i * 8);
            const arg = read(&result, 20 + i * 8);
            if (op > @intFromEnum(Opcode.reactions)) @panic("invalid render capability");
            const valid = switch (@as(Opcode, @enumFromInt(op))) {
                .draw => arg <= @intFromEnum(Draw.input_group),
                .children => arg & ~@as(u32, 0x303) == 0,
                .separators, .scrollbars => arg <= 1,
                else => arg == 0,
            };
            if (!valid) @panic("invalid render capability arguments");
            command.* = .{ .opcode = @enumFromInt(op), .arg = arg };
        }
        return recipe;
    }
};
pub const ChildPlan = struct {
    allocator: std.mem.Allocator,
    result: []u8,
    count: usize,
    pub fn init(allocator: std.mem.Allocator, policy: Policy, children: []const widgets.Widget, t: tokens.DesignTokens, stamp: bool) !ChildPlan {
        const count = std.math.cast(u32, children.len) orelse @panic("render child count exceeds wire range");
        const request = try allocator.alloc(u8, try std.math.add(usize, 32, try std.math.mul(usize, children.len, 12)));
        defer allocator.free(request);
        const result = try allocator.alloc(u8, try std.math.add(usize, 8, try std.math.mul(usize, children.len, 8)));
        errdefer allocator.free(result);
        @memset(request, 0);
        request[0..4].* = .{ 44, 1, @intFromBool(stamp), 0 };
        word(request, 4, count);
        for ([_]i32{ t.layer.base, t.layer.modal, t.layer.overlay, t.layer.floating }, 0..) |layer, i| word(request, 8 + i * 4, @bitCast(layer));
        for (children, 0..) |child, i| {
            const at = 32 + i * 12;
            word(request, at, @intFromEnum(child.kind));
            word(request, at + 4, @as(u32, @intFromBool(child.semantics.hidden)) | (@as(u32, @intFromBool(child.layer != null)) << 1));
            if (child.layer) |layer| word(request, at + 8, @bitCast(layer));
        }
        @memset(result, 0xa5);
        if (policy(request, result) != result.len or read(result, 0) != 1 or read(result, 4) != count) @panic("invalid render child result");
        const plan: ChildPlan = .{ .allocator = allocator, .result = result, .count = count };
        for (0..count) |i| {
            if (plan.index(i) >= count or read(result, 12 + i * 8) > 3) @panic("invalid render child entry");
            for (0..i) |j| if (plan.index(i) == plan.index(j)) @panic("duplicate render child entry");
        }
        return plan;
    }
    pub fn deinit(self: ChildPlan) void {
        self.allocator.free(self.result);
    }
    pub fn index(self: ChildPlan, ordinal: usize) usize {
        return read(self.result, 8 + ordinal * 8);
    }
    pub fn segment(self: ChildPlan, ordinal: usize) widgets.WidgetGroupSegment {
        return @enumFromInt(read(self.result, 12 + ordinal * 8));
    }
};

/// Actual layer boundaries are copied from the portable composition owner.
pub const ChromePlan = struct {
    prefix: usize,
    suffix: usize,
    pub fn init(policy: Policy, prefix_budget: usize, suffix_budget: usize, count: usize, before: ?usize, variable: bool) error{InvalidChromeCommandCount}!ChromePlan {
        var request: [40]u8 = @splat(0);
        request[0..4].* = .{ 67, 1, @as(u8, @intFromBool(before != null)) | (@as(u8, @intFromBool(variable)) << 1), 0 };
        for ([_]usize{ prefix_budget, suffix_budget, count, before orelse 0 }, 0..) |value, i|
            std.mem.writeInt(u64, request[8 + i * 8 ..][0..8], value, .little);
        var result: [24]u8 = @splat(0xa5);
        if (policy(&request, &result) != result.len or read(&result, 0) != 1 or read(&result, 4) > 1 or !std.mem.allEqual(u8, result[16..], 0))
            @panic("invalid chrome composition result");
        if (read(&result, 4) == 1) {
            if (!std.mem.allEqual(u8, result[8..], 0)) @panic("invalid rejected chrome composition");
            return error.InvalidChromeCommandCount;
        }
        const plan: ChromePlan = .{ .prefix = read(&result, 8), .suffix = read(&result, 12) };
        if (plan.prefix > count or plan.suffix > count - plan.prefix or plan.prefix + plan.suffix != count)
            @panic("invalid chrome composition span");
        return plan;
    }
};
