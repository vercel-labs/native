const std = @import("std");
const protocol = @import("automation_protocol");

const automation_dir = protocol.default_dir;

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    const command = args[0];
    if (std.mem.eql(u8, command, "list")) {
        try printFile(io, "windows.txt");
    } else if (std.mem.eql(u8, command, "snapshot")) {
        try printFile(io, "snapshot.txt");
    } else if (std.mem.eql(u8, command, "screenshot")) {
        std.debug.print("screenshot capture is not available for this backend\n", .{});
        return error.UnsupportedCommand;
    } else if (std.mem.eql(u8, command, "reload")) {
        try sendCommand(allocator, io, "reload", "");
    } else if (std.mem.eql(u8, command, "resize")) {
        if (args.len < 3 or args.len > 4) return usage();
        const value = if (args.len == 4)
            try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ args[1], args[2], args[3] })
        else
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "resize", value);
    } else if (std.mem.eql(u8, command, "menu-command")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "menu-command", args[1]);
    } else if (std.mem.eql(u8, command, "native-command")) {
        if (args.len < 2 or args.len > 3) return usage();
        if (args.len == 3) {
            const value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
            defer allocator.free(value);
            try sendCommand(allocator, io, "native-command", value);
        } else {
            try sendCommand(allocator, io, "native-command", args[1]);
        }
    } else if (std.mem.eql(u8, command, "widget-action")) {
        if (args.len < 4) return usage();
        const value = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-action", value);
    } else if (std.mem.eql(u8, command, "widget-click")) {
        if (args.len != 3) return usage();
        const value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-click", value);
    } else if (std.mem.eql(u8, command, "widget-drag")) {
        if (args.len != 5 and args.len != 7) return usage();
        const value = if (args.len == 7)
            try std.fmt.allocPrint(allocator, "{s} {s} {s} {s} {s} {s}", .{ args[1], args[2], args[3], args[4], args[5], args[6] })
        else
            try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ args[1], args[2], args[3], args[4] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-drag", value);
    } else if (std.mem.eql(u8, command, "widget-wheel")) {
        if (args.len != 4) return usage();
        const value = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ args[1], args[2], args[3] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-wheel", value);
    } else if (std.mem.eql(u8, command, "widget-key")) {
        if (args.len < 3) return usage();
        const value = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-key", value);
    } else if (std.mem.eql(u8, command, "shortcut")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "shortcut", args[1]);
    } else if (std.mem.eql(u8, command, "focus")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "focus", args[1]);
    } else if (std.mem.eql(u8, command, "focus-next")) {
        if (args.len != 1) return usage();
        try sendCommand(allocator, io, "focus-next", "");
    } else if (std.mem.eql(u8, command, "focus-previous")) {
        if (args.len != 1) return usage();
        try sendCommand(allocator, io, "focus-previous", "");
    } else if (std.mem.eql(u8, command, "wait")) {
        try waitForFile(allocator, io, "snapshot.txt", "ready=true");
    } else if (std.mem.eql(u8, command, "bridge")) {
        if (args.len < 2) return usage();
        deleteAutomationFile(io, "bridge-response.txt");
        try sendCommand(allocator, io, "bridge", args[1]);
        try waitForFile(allocator, io, "bridge-response.txt", "");
    } else {
        return usage();
    }
}

fn usage() void {
    std.debug.print(
        \\usage: zero-native automate <command>
        \\
        \\commands:
        \\  list
        \\  snapshot
        \\  screenshot
        \\  reload
        \\  resize <width> <height> [scale]
        \\  menu-command <id>
        \\  native-command <id> [view-label]
        \\  widget-action <view-label> <widget-id> <action> [value]
        \\  widget-click <view-label> <widget-id>   (ids are the bare number; snapshots print #id)
        \\  widget-drag <view-label> <widget-id> <start-x-ratio> <end-x-ratio> [start-y-ratio end-y-ratio]
        \\  widget-wheel <view-label> <widget-id> <delta-y>
        \\  widget-key <view-label> <key> [text]
        \\  shortcut <id>
        \\  focus <view-label>
        \\  focus-next
        \\  focus-previous
        \\  wait
        \\  bridge <request-json>
        \\
    , .{});
}

fn sendCommand(allocator: std.mem.Allocator, io: std.Io, action: []const u8, value: []const u8) !void {
    const buffer = try allocator.alloc(u8, protocol.max_command_bytes);
    defer allocator.free(buffer);
    const line = try protocol.commandLine(action, value, buffer);
    try std.Io.Dir.cwd().createDirPath(io, automation_dir);
    var command_path: [256]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path(&command_path, "command.txt"), .data = line });
    std.debug.print("queued {s}\n", .{action});
}

fn printFile(io: std.Io, name: []const u8) !void {
    var file_path: [256]u8 = undefined;
    const bytes = readFile(std.heap.page_allocator, io, path(&file_path, name)) catch return fail("no app connected");
    defer std.heap.page_allocator.free(bytes);
    std.debug.print("{s}", .{bytes});
}

fn waitForFile(allocator: std.mem.Allocator, io: std.Io, name: []const u8, marker: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        var file_path: [256]u8 = undefined;
        const bytes = readFile(allocator, io, path(&file_path, name)) catch {
            try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
            continue;
        };
        if (marker.len == 0 or std.mem.indexOf(u8, bytes, marker) != null) {
            std.debug.print("{s}", .{bytes});
            allocator.free(bytes);
            return;
        }
        allocator.free(bytes);
        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
    }
    return fail("timed out waiting for automation");
}

fn deleteAutomationFile(io: std.Io, name: []const u8) void {
    var file_path: [256]u8 = undefined;
    std.Io.Dir.cwd().deleteFile(io, path(&file_path, name)) catch {};
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn path(buffer: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ automation_dir, name }) catch unreachable;
}

fn fail(message: []const u8) error{AutomationCommandFailed} {
    std.debug.print("error: {s}\n", .{message});
    return error.AutomationCommandFailed;
}
