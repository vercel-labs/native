const std = @import("std");

pub const default_dir = ".zig-cache/zero-native-automation";
pub const max_command_bytes: usize = 16 * 1024 + 64;

pub const Error = error{
    InvalidCommand,
    CommandTooLarge,
};

pub const Action = enum {
    reload,
    wait,
    resize,
    bridge,
    native_command,
    widget_action,
    menu_command,
    shortcut,
    focus_view,
    focus_next_view,
    focus_previous_view,
};

pub const Command = struct {
    action: Action,
    value: []const u8 = "",

    pub fn parse(line: []const u8) Error!Command {
        const trimmed = std.mem.trim(u8, line, " \n\r\t");
        if (trimmed.len == 0) return error.InvalidCommand;
        const separator = std.mem.indexOfScalar(u8, trimmed, ' ');
        const action_text = if (separator) |index| trimmed[0..index] else trimmed;
        const value = if (separator) |index| std.mem.trim(u8, trimmed[index + 1 ..], " \n\r\t") else "";
        if (std.mem.eql(u8, action_text, "reload")) return .{ .action = .reload };
        if (std.mem.eql(u8, action_text, "wait")) return .{ .action = .wait, .value = value };
        if (std.mem.eql(u8, action_text, "resize") and value.len > 0) return .{ .action = .resize, .value = value };
        if (std.mem.eql(u8, action_text, "bridge") and value.len > 0) return .{ .action = .bridge, .value = value };
        if (std.mem.eql(u8, action_text, "native-command") and value.len > 0) return .{ .action = .native_command, .value = value };
        if (std.mem.eql(u8, action_text, "widget-action") and value.len > 0) return .{ .action = .widget_action, .value = value };
        if (std.mem.eql(u8, action_text, "menu-command") and value.len > 0) return .{ .action = .menu_command, .value = value };
        if (std.mem.eql(u8, action_text, "shortcut") and value.len > 0) return .{ .action = .shortcut, .value = value };
        if (std.mem.eql(u8, action_text, "focus") and value.len > 0) return .{ .action = .focus_view, .value = value };
        if (std.mem.eql(u8, action_text, "focus-next")) return .{ .action = .focus_next_view };
        if (std.mem.eql(u8, action_text, "focus-previous")) return .{ .action = .focus_previous_view };
        return error.InvalidCommand;
    }
};

pub fn commandLine(action: []const u8, value: []const u8, output: []u8) ![]const u8 {
    if (action.len + value.len + 2 > max_command_bytes) return error.CommandTooLarge;
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll(action);
    if (value.len > 0) try writer.print(" {s}", .{value});
    try writer.writeAll("\n");
    return writer.buffered();
}

test "commands parse reload and wait" {
    const reload = try Command.parse("reload");
    try std.testing.expectEqual(Action.reload, reload.action);
    const wait = try Command.parse("wait frame");
    try std.testing.expectEqual(Action.wait, wait.action);
    try std.testing.expectEqualStrings("frame", wait.value);
    const bridge = try Command.parse("bridge {\"id\":\"1\",\"command\":\"native.ping\",\"payload\":{\"source\":\"smoke test\"}}");
    try std.testing.expectEqual(Action.bridge, bridge.action);
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"command\":\"native.ping\",\"payload\":{\"source\":\"smoke test\"}}", bridge.value);
    const resize = try Command.parse("resize 900 640");
    try std.testing.expectEqual(Action.resize, resize.action);
    try std.testing.expectEqualStrings("900 640", resize.value);
    const native_command = try Command.parse("native-command app.refresh refresh-button");
    try std.testing.expectEqual(Action.native_command, native_command.action);
    try std.testing.expectEqualStrings("app.refresh refresh-button", native_command.value);
    const widget_action = try Command.parse("widget-action canvas 2 press");
    try std.testing.expectEqual(Action.widget_action, widget_action.action);
    try std.testing.expectEqualStrings("canvas 2 press", widget_action.value);
    const menu_command = try Command.parse("menu-command app.refresh");
    try std.testing.expectEqual(Action.menu_command, menu_command.action);
    const shortcut = try Command.parse("shortcut app.refresh");
    try std.testing.expectEqual(Action.shortcut, shortcut.action);
    const focus = try Command.parse("focus refresh-button");
    try std.testing.expectEqual(Action.focus_view, focus.action);
    try std.testing.expectEqualStrings("refresh-button", focus.value);
    const focus_next = try Command.parse("focus-next");
    try std.testing.expectEqual(Action.focus_next_view, focus_next.action);
    const focus_previous = try Command.parse("focus-previous");
    try std.testing.expectEqual(Action.focus_previous_view, focus_previous.action);
}
