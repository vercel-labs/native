//! Native numeric conversion and borrowed-buffer transport for automation.
const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");
const reference = @import("automation_commands.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const AutomationNativeCommand = reference.AutomationNativeCommand;
pub const AutomationWidgetActionKind = reference.AutomationWidgetActionKind;
pub const AutomationWidgetAction = reference.AutomationWidgetAction;
pub const AutomationWidgetTarget = reference.AutomationWidgetTarget;
pub const AutomationProvenanceTarget = reference.AutomationProvenanceTarget;
pub const AutomationWidgetWheel = reference.AutomationWidgetWheel;
pub const AutomationWidgetContextMenuItem = reference.AutomationWidgetContextMenuItem;
pub const AutomationWidgetKey = reference.AutomationWidgetKey;
pub const AutomationWidgetPinch = reference.AutomationWidgetPinch;
pub const AutomationWidgetPointerDrag = reference.AutomationWidgetPointerDrag;
pub const AutomationResizeCommand = reference.AutomationResizeCommand;
pub const AutomationTrayTarget = reference.AutomationTrayTarget;
pub const AutomationScreenshotCommand = reference.AutomationScreenshotCommand;

const Program = struct {
    bytes: []u8,
    input: []const u8,
    fn deinit(self: Program) void {
        std.heap.page_allocator.free(self.bytes);
    }
    fn word(self: Program, at: usize) u32 {
        return std.mem.readInt(u32, self.bytes[at..][0..4], .little);
    }
    fn entry(self: Program, index: usize) usize {
        if (index >= self.word(20)) @panic("missing automation field");
        return 24 + index * 24;
    }
    fn string(self: Program, index: usize) []const u8 {
        const at = self.entry(index);
        if (self.word(at) != 0) @panic("invalid automation string kind");
        return self.input[self.word(at + 4)..][0..self.word(at + 8)];
    }
    fn integer(self: Program, index: usize, comptime T: type) T {
        const at = self.entry(index);
        if (self.word(at) == 0 or self.word(at) == 5 or self.word(at) == 6) @panic("invalid automation integer kind");
        return std.math.cast(T, std.mem.readInt(u64, self.bytes[at + 16 ..][0..8], .little)) orelse @panic("invalid automation integer width");
    }
    fn float(self: Program, index: usize) f32 {
        const at = self.entry(index);
        if (self.word(at) != 5 and self.word(at) != 6) @panic("invalid automation float kind");
        return @bitCast(self.word(at + 16));
    }
    fn validate(self: Program, len: usize, mode: u8, capacity: usize) void {
        if (len < 24 or len > self.bytes.len) @panic("invalid automation program extent");
        if (self.word(0) != 1 or self.word(4) != mode or self.word(8) > 2 or self.word(12) > 13 or self.word(16) > 31) @panic("invalid automation program header");
        const count: usize = self.word(20);
        if (count > (len - 24) / 24 or len != 24 + count * 24 or (mode == 14 and count > capacity)) @panic("invalid automation field count");
        for (0..count) |i| {
            const at = self.entry(i);
            if (self.word(at) > 7 or self.word(at + 12) > 3) @panic("invalid automation conversion recipe");
            const offset: usize = self.word(at + 4);
            if (offset > self.input.len or self.word(at + 8) > self.input.len - offset) @panic("invalid automation borrowed span");
        }
    }
};

fn parse(policy: Policy, mode: u8, input: []const u8, capacity: usize) !Program {
    const allocator = std.heap.page_allocator;
    if (input.len > std.math.maxInt(u32) or capacity > std.math.maxInt(u32)) return error.InvalidCommand;
    const max_fields = @max(@as(usize, 6), input.len / 2 + 1);
    var program = Program{ .bytes = try allocator.alloc(u8, 24 + max_fields * 24), .input = input };
    errdefer program.deinit();
    @memset(program.bytes, 0xa5);
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);
    try request.appendSlice(allocator, &.{ 90, 1, mode, 0 });
    var words: [12]u8 = @splat(0);
    std.mem.writeInt(u32, words[0..4], @intCast(input.len), .little);
    std.mem.writeInt(u32, words[4..8], @intCast(capacity), .little);
    try request.appendSlice(allocator, &words);
    try request.appendSlice(allocator, input);
    var size = policy(request.items, program.bytes);
    program.validate(size, mode, capacity);
    if (program.word(8) == 0) {
        if (mode == 14) return program;
        return error.InvalidCommand;
    }
    if (program.word(8) != 1) @panic("automation conversion recipe expected");
    const count: usize = program.word(20);
    const facts = try request.addManyAsSlice(allocator, count * 12);
    @memset(facts, 0);
    for (0..count) |i| {
        const at = program.entry(i);
        const kind = program.word(at);
        if (kind == 0 or kind >= 6) continue;
        const token = input[program.word(at + 4)..][0..program.word(at + 8)];
        const value: ?u64 = switch (kind) {
            1 => std.fmt.parseInt(u64, token, 10) catch null,
            2 => if (std.fmt.parseInt(u32, token, 10)) |v| v else |_| null,
            3 => if (std.fmt.parseInt(usize, token, 10)) |v| v else |_| null,
            4 => if (std.fmt.parseUnsigned(u32, token, 10)) |v| v else |_| null,
            5 => if (std.fmt.parseFloat(f32, token)) |v| @as(u32, @bitCast(v)) else |_| null,
            else => unreachable,
        };
        if (value) |v| {
            std.mem.writeInt(u32, facts[i * 12 ..][0..4], 1, .little);
            std.mem.writeInt(u64, facts[i * 12 + 4 ..][0..8], v, .little);
        }
    }
    request.items[3] = 1;
    size = policy(request.items, program.bytes);
    program.validate(size, mode, capacity);
    if (program.word(8) == 0) return error.InvalidCommand;
    if (program.word(8) != 2 or program.word(20) != count) @panic("automation admission expected");
    return program;
}

pub fn parseAutomationCommandName(policy: ?Policy, value: []const u8) ![]const u8 {
    const compiled = policy orelse return reference.parseAutomationCommandName(value);
    const p = try parse(compiled, 0, value, 0);
    defer p.deinit();
    return p.string(0);
}

pub fn parseAutomationTrayItemId(policy: ?Policy, value: []const u8) !platform.TrayItemId {
    const compiled = policy orelse return reference.parseAutomationTrayItemId(value);
    const p = try parse(compiled, 1, value, 0);
    defer p.deinit();
    return p.integer(0, platform.TrayItemId);
}

pub fn parseAutomationTrayTarget(policy: ?Policy, value: []const u8) !AutomationTrayTarget {
    const compiled = policy orelse return reference.parseAutomationTrayTarget(value);
    const p = try parse(compiled, 2, value, 0);
    defer p.deinit();
    return .{ .status_item_id = p.integer(0, platform.StatusItemId), .item_id = p.integer(1, platform.TrayItemId) };
}

pub fn parseAutomationViewLabel(policy: ?Policy, value: []const u8) ![]const u8 {
    const compiled = policy orelse return reference.parseAutomationViewLabel(value);
    const p = try parse(compiled, 3, value, 0);
    defer p.deinit();
    return p.string(0);
}

pub fn parseAutomationNativeCommand(policy: ?Policy, value: []const u8) !AutomationNativeCommand {
    const compiled = policy orelse return reference.parseAutomationNativeCommand(value);
    const p = try parse(compiled, 4, value, 0);
    defer p.deinit();
    return .{ .name = p.string(0), .view_label = p.string(1) };
}

pub fn parseAutomationWidgetAction(policy: ?Policy, value: []const u8) !AutomationWidgetAction {
    const compiled = policy orelse return reference.parseAutomationWidgetAction(value);
    const p = try parse(compiled, 5, value, 0);
    defer p.deinit();
    return .{ .view_label = p.string(0), .id = p.integer(1, canvas.ObjectId), .action = @enumFromInt(p.word(12)), .value = p.string(2) };
}

pub fn parseAutomationWidgetTarget(policy: ?Policy, value: []const u8) !AutomationWidgetTarget {
    const compiled = policy orelse return reference.parseAutomationWidgetTarget(value);
    const p = try parse(compiled, 6, value, 0);
    defer p.deinit();
    return .{ .view_label = p.string(0), .id = p.integer(1, canvas.ObjectId) };
}

pub fn parseAutomationProvenanceTarget(policy: ?Policy, value: []const u8) !AutomationProvenanceTarget {
    const compiled = policy orelse return reference.parseAutomationProvenanceTarget(value);
    const p = try parse(compiled, 7, value, 0);
    defer p.deinit();
    return if (p.word(12) == 1) .{ .view_label = p.string(0), .point = geometry.PointF.init(p.float(1), p.float(2)) } else .{ .view_label = p.string(0), .id = p.integer(1, canvas.ObjectId) };
}

pub fn parseAutomationWidgetWheel(policy: ?Policy, value: []const u8) !AutomationWidgetWheel {
    const compiled = policy orelse return reference.parseAutomationWidgetWheel(value);
    const p = try parse(compiled, 8, value, 0);
    defer p.deinit();
    return .{ .target = .{ .view_label = p.string(0), .id = p.integer(1, canvas.ObjectId) }, .delta_y = p.float(2), .delta_x = p.float(3) };
}

pub fn parseAutomationWidgetContextMenuItem(policy: ?Policy, value: []const u8) !AutomationWidgetContextMenuItem {
    const compiled = policy orelse return reference.parseAutomationWidgetContextMenuItem(value);
    const p = try parse(compiled, 9, value, 0);
    defer p.deinit();
    return .{ .target = .{ .view_label = p.string(0), .id = p.integer(1, canvas.ObjectId) }, .item_index = p.integer(2, usize) };
}

pub fn parseAutomationWidgetKey(policy: ?Policy, value: []const u8) !AutomationWidgetKey {
    const compiled = policy orelse return reference.parseAutomationWidgetKey(value);
    const p = try parse(compiled, 10, value, 0);
    defer p.deinit();
    return .{ .view_label = p.string(0), .key = p.string(1), .text = p.string(2), .modifiers = .{ .shift = p.word(16) & 1 != 0, .control = p.word(16) & 2 != 0, .option = p.word(16) & 4 != 0, .command = p.word(16) & 8 != 0, .primary = p.word(16) & 16 != 0 } };
}

pub fn parseAutomationWidgetPinch(policy: ?Policy, value: []const u8) !AutomationWidgetPinch {
    const compiled = policy orelse return reference.parseAutomationWidgetPinch(value);
    const p = try parse(compiled, 11, value, 0);
    defer p.deinit();
    return .{ .view_label = p.string(0), .scale = p.float(1), .point = if (p.word(12) == 1) geometry.PointF.init(p.float(2), p.float(3)) else null };
}

pub fn parseAutomationWidgetPointerDrag(policy: ?Policy, value: []const u8) !AutomationWidgetPointerDrag {
    const compiled = policy orelse return reference.parseAutomationWidgetPointerDrag(value);
    const p = try parse(compiled, 12, value, 0);
    defer p.deinit();
    return .{ .target = .{ .view_label = p.string(0), .id = p.integer(1, canvas.ObjectId) }, .start_x_ratio = p.float(2), .end_x_ratio = p.float(3), .start_y_ratio = p.float(4), .end_y_ratio = p.float(5) };
}

pub fn parseAutomationScreenshotCommand(policy: ?Policy, value: []const u8) !AutomationScreenshotCommand {
    const compiled = policy orelse return reference.parseAutomationScreenshotCommand(value);
    const p = try parse(compiled, 13, value, 0);
    defer p.deinit();
    return .{ .view_label = p.string(0), .scale = if (p.word(12) == 1) p.float(1) else null };
}

pub fn parseAutomationDropPaths(policy: ?Policy, value: []const u8, output: [][]const u8) ![]const []const u8 {
    const compiled = policy orelse return reference.parseAutomationDropPaths(value, output);
    const p = try parse(compiled, 14, value, output.len);
    defer p.deinit();
    for (0..p.word(20)) |index| output[index] = p.string(index);
    if (p.word(8) == 0) return error.InvalidCommand;
    return output[0..p.word(20)];
}

pub fn parseAutomationTextSelection(policy: ?Policy, value: []const u8) !canvas.TextSelection {
    const compiled = policy orelse return reference.parseAutomationTextSelection(value);
    const p = try parse(compiled, 15, value, 0);
    defer p.deinit();
    return .{ .anchor = p.integer(0, usize), .focus = p.integer(1, usize) };
}

pub fn parseAutomationDragDelta(policy: ?Policy, value: []const u8) !geometry.OffsetF {
    const compiled = policy orelse return reference.parseAutomationDragDelta(value);
    const p = try parse(compiled, 16, value, 0);
    defer p.deinit();
    return geometry.OffsetF.init(p.float(0), p.float(1));
}

pub fn parseAutomationResizeCommand(policy: ?Policy, value: []const u8) !AutomationResizeCommand {
    const compiled = policy orelse return reference.parseAutomationResizeCommand(value);
    const p = try parse(compiled, 17, value, 0);
    defer p.deinit();
    return .{ .width = p.float(0), .height = p.float(1), .scale_factor = p.float(2) };
}
