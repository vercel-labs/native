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
/// 4 = the `provenance` verb (widget id or point -> authored markup) and
/// its `provenance.txt` response artifact, the write-back read half.
/// 5 = the `widget-context-menu` verb (invoke a declared context-menu
/// item by target widget + item index, through the same
/// `context_menu_action` dispatch a native selection takes) and the
/// snapshot's per-widget `context_menu=[...]` item listing.
/// 6 = the queued command dropbox: numbered `command-<n>.txt` entries
/// (claimed exclusively by writers, consumed lowest-number-first by the
/// app, DELETED as the consumption ack) replace the single-entry
/// `command.txt` slot that rapid back-to-back writers could overwrite
/// before the app drained it. A v5 CLI against a v6 app writes a
/// `command.txt` the app never touches (and times out loudly on its own
/// consumption wait); a v6 CLI against a v5 app queues files the app
/// never touches (same loud timeout) — and both directions are refused
/// up front by this handshake whenever a live snapshot exists.
/// Snapshots without a `protocol=` field predate the handshake entirely.
pub const version: u32 = 6;

/// How many commands may sit in the dropbox queue at once. Automation
/// drivers are scripts, not firehoses: the app drains one command per
/// presented frame (milliseconds apart once the arrival watcher wakes
/// it), so a handful of entries absorbs any realistic burst. The bound is
/// enforced by WRITERS — the CLI retries a full queue at its consumption
/// cadence up to its existing timeout, then refuses loudly naming this
/// depth — because the consumer can only ever shrink the queue.
pub const max_queued_commands: usize = 8;

pub const queue_file_prefix = "command-";
pub const queue_file_suffix = ".txt";

/// Queue entry file name for a claim sequence: `command-<n>.txt`. Both
/// sides build names through here so the on-disk shape lives in exactly
/// one place.
pub fn queueFileName(sequence: u64, output: []u8) Error![]const u8 {
    return std.fmt.bufPrint(output, "{s}{d}{s}", .{ queue_file_prefix, sequence, queue_file_suffix }) catch error.CommandTooLarge;
}

/// The claim sequence of a queue entry name, or null for every other
/// dropbox file — snapshots, response artifacts, and notably the retired
/// v5 single-slot `command.txt`, whose bare name has no `-<n>` and so
/// never parses as queue traffic (a stale v5 writer's slot sits inert
/// until that writer's own consumption wait fails loudly).
pub fn queueFileSequence(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, queue_file_prefix)) return null;
    if (!std.mem.endsWith(u8, name, queue_file_suffix)) return null;
    if (name.len <= queue_file_prefix.len + queue_file_suffix.len) return null;
    const digits = name[queue_file_prefix.len .. name.len - queue_file_suffix.len];
    return std.fmt.parseUnsigned(u64, digits, 10) catch null;
}

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
    /// `widget-context-menu <view-label> <id> <item-index>`: invoke one
    /// of the widget's DECLARED context-menu items without running the
    /// OS menu's tracking loop (which cannot be driven programmatically)
    /// — the selection dispatches as the same `context_menu_action`
    /// platform event a real pick produces, so it journals and replays.
    widget_context_menu,
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
    /// `provenance <view-label> <widget-id>` or
    /// `provenance <view-label> at <x> <y>`: report the markup that
    /// authored a live widget (file, byte span, line:column, template
    /// chain, iteration keys) into `provenance.txt`.
    provenance,
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
        if (std.mem.eql(u8, action_text, "widget-context-menu") and value.len > 0) return .{ .action = .widget_context_menu, .value = value };
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
        if (std.mem.eql(u8, action_text, "provenance") and value.len > 0) return .{ .action = .provenance, .value = value };
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
    const widget_context_menu = try Command.parse("widget-context-menu canvas 2 1");
    try std.testing.expectEqual(Action.widget_context_menu, widget_context_menu.action);
    try std.testing.expectEqualStrings("canvas 2 1", widget_context_menu.value);
    try std.testing.expectError(error.InvalidCommand, Command.parse("widget-context-menu"));
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
    const provenance_by_id = try Command.parse("provenance kanban-canvas 42");
    try std.testing.expectEqual(Action.provenance, provenance_by_id.action);
    try std.testing.expectEqualStrings("kanban-canvas 42", provenance_by_id.value);
    const provenance_at = try Command.parse("provenance kanban-canvas at 120 64");
    try std.testing.expectEqual(Action.provenance, provenance_at.action);
    try std.testing.expectEqualStrings("kanban-canvas at 120 64", provenance_at.value);
    try std.testing.expectError(error.InvalidCommand, Command.parse("provenance"));
}

test "queue entry names round-trip and reject non-queue files" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("command-1.txt", try queueFileName(1, &buffer));
    try std.testing.expectEqualStrings("command-42.txt", try queueFileName(42, &buffer));
    try std.testing.expectEqual(@as(?u64, 1), queueFileSequence("command-1.txt"));
    try std.testing.expectEqual(@as(?u64, 42), queueFileSequence("command-42.txt"));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), queueFileSequence(try queueFileName(std.math.maxInt(u64), &buffer)));
    // The retired v5 single-slot name, response artifacts, and malformed
    // sequences are all non-queue files.
    try std.testing.expectEqual(@as(?u64, null), queueFileSequence("command.txt"));
    try std.testing.expectEqual(@as(?u64, null), queueFileSequence("command-.txt"));
    try std.testing.expectEqual(@as(?u64, null), queueFileSequence("command-x.txt"));
    try std.testing.expectEqual(@as(?u64, null), queueFileSequence("command-1.png"));
    try std.testing.expectEqual(@as(?u64, null), queueFileSequence("snapshot.txt"));
    try std.testing.expectEqual(@as(?u64, null), queueFileSequence("bridge-response.txt"));
}

test "screenshot file names stay inside the automation directory" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("screenshot-inbox-canvas.png", try screenshotFileName("inbox-canvas", &buffer));
    try std.testing.expectEqualStrings("screenshot-..-evil.png", try screenshotFileName("../evil", &buffer));
    try std.testing.expectEqualStrings("screenshot-a-b.png", try screenshotFileName("a/b", &buffer));
    try std.testing.expectError(error.InvalidCommand, screenshotFileName("", &buffer));
    try std.testing.expectError(error.CommandTooLarge, screenshotFileName("x" ** 65, &buffer));
}
