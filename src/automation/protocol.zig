const std = @import("std");

pub const default_dir = ".zig-cache/native-sdk-automation";
pub const max_command_bytes: usize = 16 * 1024 + 64;

/// CLI <-> app dropbox protocol version. Both binaries bake this
/// constant at THEIR build time: the app stamps it into every snapshot
/// header (`protocol=N`), the CLI refuses a snapshot whose version is not
/// its own — so a stale `native` binary driving a freshly built app (or
/// the reverse) fails loudly, naming both versions, instead of silently
/// reading yesterday's state. Bump on ANY shape change a stale binary
/// would misread: the dropbox directory name, the snapshot header/format,
/// or the command vocabulary.
///
/// History: 1 = the first stamped version (post-rename dropbox
/// `.zig-cache/native-sdk-automation`, publisher_pid liveness, stdout
/// payloads). 2 = the gesture verbs (`widget-hold`,
/// `widget-context-press`) and per-window snapshot view/widget scoping.
/// 3 = the `profile on|off` verb and the snapshot's `frame_profile`
/// per-stage timing line.
/// Snapshots without a `protocol=` field predate the handshake entirely.
pub const version: u32 = 3;

pub const Error = error{
    InvalidCommand,
    CommandTooLarge,
};

pub const Action = enum {
    reload,
    wait,
    resize,
    screenshot,
    bridge,
    native_command,
    widget_action,
    widget_click,
    widget_hold,
    widget_context_press,
    widget_drag,
    widget_wheel,
    widget_key,
    menu_command,
    shortcut,
    tray_action,
    focus_view,
    focus_next_view,
    focus_previous_view,
    /// `profile on|off`: toggle per-stage frame timing; while on, the
    /// snapshot carries a `frame_profile` line of rolling p50/p90s.
    profile,
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
        if (std.mem.eql(u8, action_text, "screenshot") and value.len > 0) return .{ .action = .screenshot, .value = value };
        if (std.mem.eql(u8, action_text, "bridge") and value.len > 0) return .{ .action = .bridge, .value = value };
        if (std.mem.eql(u8, action_text, "native-command") and value.len > 0) return .{ .action = .native_command, .value = value };
        if (std.mem.eql(u8, action_text, "widget-action") and value.len > 0) return .{ .action = .widget_action, .value = value };
        if (std.mem.eql(u8, action_text, "widget-click") and value.len > 0) return .{ .action = .widget_click, .value = value };
        if (std.mem.eql(u8, action_text, "widget-hold") and value.len > 0) return .{ .action = .widget_hold, .value = value };
        if (std.mem.eql(u8, action_text, "widget-context-press") and value.len > 0) return .{ .action = .widget_context_press, .value = value };
        if (std.mem.eql(u8, action_text, "widget-drag") and value.len > 0) return .{ .action = .widget_drag, .value = value };
        if (std.mem.eql(u8, action_text, "widget-wheel") and value.len > 0) return .{ .action = .widget_wheel, .value = value };
        if (std.mem.eql(u8, action_text, "widget-key") and value.len > 0) return .{ .action = .widget_key, .value = value };
        if (std.mem.eql(u8, action_text, "menu-command") and value.len > 0) return .{ .action = .menu_command, .value = value };
        if (std.mem.eql(u8, action_text, "shortcut") and value.len > 0) return .{ .action = .shortcut, .value = value };
        if (std.mem.eql(u8, action_text, "tray-action") and value.len > 0) return .{ .action = .tray_action, .value = value };
        if (std.mem.eql(u8, action_text, "focus") and value.len > 0) return .{ .action = .focus_view, .value = value };
        if (std.mem.eql(u8, action_text, "focus-next")) return .{ .action = .focus_next_view };
        if (std.mem.eql(u8, action_text, "focus-previous")) return .{ .action = .focus_previous_view };
        if (std.mem.eql(u8, action_text, "profile") and (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "off"))) {
            return .{ .action = .profile, .value = value };
        }
        return error.InvalidCommand;
    }
};

pub const max_screenshot_label_bytes: usize = 64;

/// Artifact file name for a view screenshot: `screenshot-<label>.png` with
/// any byte outside [A-Za-z0-9._-] replaced by `-` so labels can never
/// escape the automation directory.
pub fn screenshotFileName(view_label: []const u8, output: []u8) ![]const u8 {
    if (view_label.len == 0) return error.InvalidCommand;
    if (view_label.len > max_screenshot_label_bytes) return error.CommandTooLarge;
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("screenshot-") catch return error.CommandTooLarge;
    for (view_label) |byte| {
        const safe: u8 = switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => byte,
            else => '-',
        };
        writer.writeByte(safe) catch return error.CommandTooLarge;
    }
    writer.writeAll(".png") catch return error.CommandTooLarge;
    return writer.buffered();
}

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
    const screenshot = try Command.parse("screenshot inbox-canvas");
    try std.testing.expectEqual(Action.screenshot, screenshot.action);
    try std.testing.expectEqualStrings("inbox-canvas", screenshot.value);
    const scaled_screenshot = try Command.parse("screenshot inbox-canvas 2");
    try std.testing.expectEqual(Action.screenshot, scaled_screenshot.action);
    try std.testing.expectEqualStrings("inbox-canvas 2", scaled_screenshot.value);
    try std.testing.expectError(error.InvalidCommand, Command.parse("screenshot"));
    const native_command = try Command.parse("native-command app.refresh refresh-button");
    try std.testing.expectEqual(Action.native_command, native_command.action);
    try std.testing.expectEqualStrings("app.refresh refresh-button", native_command.value);
    const widget_action = try Command.parse("widget-action canvas 2 press");
    try std.testing.expectEqual(Action.widget_action, widget_action.action);
    try std.testing.expectEqualStrings("canvas 2 press", widget_action.value);
    const widget_click = try Command.parse("widget-click canvas 2");
    try std.testing.expectEqual(Action.widget_click, widget_click.action);
    try std.testing.expectEqualStrings("canvas 2", widget_click.value);
    const widget_hold = try Command.parse("widget-hold canvas 2");
    try std.testing.expectEqual(Action.widget_hold, widget_hold.action);
    try std.testing.expectEqualStrings("canvas 2", widget_hold.value);
    try std.testing.expectError(error.InvalidCommand, Command.parse("widget-hold"));
    const widget_context_press = try Command.parse("widget-context-press canvas 2");
    try std.testing.expectEqual(Action.widget_context_press, widget_context_press.action);
    try std.testing.expectEqualStrings("canvas 2", widget_context_press.value);
    try std.testing.expectError(error.InvalidCommand, Command.parse("widget-context-press"));
    const widget_drag = try Command.parse("widget-drag canvas 2 0.2 0.8");
    try std.testing.expectEqual(Action.widget_drag, widget_drag.action);
    try std.testing.expectEqualStrings("canvas 2 0.2 0.8", widget_drag.value);
    const widget_wheel = try Command.parse("widget-wheel canvas 2 18");
    try std.testing.expectEqual(Action.widget_wheel, widget_wheel.action);
    try std.testing.expectEqualStrings("canvas 2 18", widget_wheel.value);
    const widget_key = try Command.parse("widget-key canvas tab");
    try std.testing.expectEqual(Action.widget_key, widget_key.action);
    try std.testing.expectEqualStrings("canvas tab", widget_key.value);
    const menu_command = try Command.parse("menu-command app.refresh");
    try std.testing.expectEqual(Action.menu_command, menu_command.action);
    const shortcut = try Command.parse("shortcut app.refresh");
    try std.testing.expectEqual(Action.shortcut, shortcut.action);
    const tray_action = try Command.parse("tray-action 4");
    try std.testing.expectEqual(Action.tray_action, tray_action.action);
    try std.testing.expectEqualStrings("4", tray_action.value);
    try std.testing.expectError(error.InvalidCommand, Command.parse("tray-action"));
    const focus = try Command.parse("focus refresh-button");
    try std.testing.expectEqual(Action.focus_view, focus.action);
    try std.testing.expectEqualStrings("refresh-button", focus.value);
    const focus_next = try Command.parse("focus-next");
    try std.testing.expectEqual(Action.focus_next_view, focus_next.action);
    const focus_previous = try Command.parse("focus-previous");
    try std.testing.expectEqual(Action.focus_previous_view, focus_previous.action);
    const profile_on = try Command.parse("profile on");
    try std.testing.expectEqual(Action.profile, profile_on.action);
    try std.testing.expectEqualStrings("on", profile_on.value);
    const profile_off = try Command.parse("profile off");
    try std.testing.expectEqual(Action.profile, profile_off.action);
    try std.testing.expectEqualStrings("off", profile_off.value);
    try std.testing.expectError(error.InvalidCommand, Command.parse("profile"));
    try std.testing.expectError(error.InvalidCommand, Command.parse("profile maybe"));
}

test "screenshot file names stay inside the automation directory" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("screenshot-inbox-canvas.png", try screenshotFileName("inbox-canvas", &buffer));
    try std.testing.expectEqualStrings("screenshot-..-evil.png", try screenshotFileName("../evil", &buffer));
    try std.testing.expectEqualStrings("screenshot-a-b.png", try screenshotFileName("a/b", &buffer));
    try std.testing.expectError(error.InvalidCommand, screenshotFileName("", &buffer));
    try std.testing.expectError(error.CommandTooLarge, screenshotFileName("x" ** 65, &buffer));
}
