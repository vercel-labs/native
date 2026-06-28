const std = @import("std");
const protocol = @import("protocol.zig");
const snapshot = @import("snapshot.zig");

pub const Server = struct {
    io: std.Io,
    directory: []const u8 = protocol.default_dir,
    title: []const u8 = "zero-native",

    pub fn init(io: std.Io, directory: []const u8, title: []const u8) Server {
        return .{ .io = io, .directory = directory, .title = title };
    }

    pub fn publish(self: Server, input_value: snapshot.Input) !void {
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.directory);
        var text_buffer: [4 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&text_buffer);
        try snapshot.writeText(input_value, &writer);
        var path_buffer: [256]u8 = undefined;
        try writePath(self.io, self.path("snapshot.txt", &path_buffer), writer.buffered());
        var a11y_buffer: [4 * 1024]u8 = undefined;
        var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
        try snapshot.writeA11yText(input_value, &a11y_writer);
        try writePath(self.io, self.path("accessibility.txt", &path_buffer), a11y_writer.buffered());
        var windows_buffer: [512]u8 = undefined;
        var windows_writer = std.Io.Writer.fixed(&windows_buffer);
        for (input_value.windows) |window| {
            try windows_writer.print("window @w{d} \"{s}\" focused={any}\n", .{ window.id, window.title, window.focused });
        }
        try writePath(self.io, self.path("windows.txt", &path_buffer), windows_writer.buffered());
    }

    pub fn publishBridgeResponse(self: Server, response: []const u8) !void {
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.directory);
        var path_buffer: [256]u8 = undefined;
        try writePath(self.io, self.path("bridge-response.txt", &path_buffer), response);
    }

    pub fn takeCommand(self: Server, buffer: []u8) !?protocol.Command {
        var path_buffer: [256]u8 = undefined;
        const command_path = self.path("command.txt", &path_buffer);
        const bytes = readPath(self.io, command_path, buffer) catch return null;
        if (bytes.len == buffer.len) return error.CommandTooLarge;
        const line = std.mem.trim(u8, bytes, " \n\r\t");
        if (line.len == 0 or std.mem.eql(u8, line, "done")) return null;
        const command = protocol.Command.parse(line) catch return null;
        try writePath(self.io, command_path, "done\n");
        return command;
    }

    fn path(self: Server, name: []const u8, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.directory, name }) catch unreachable;
    }
};

fn writePath(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn readPath(io: std.Io, path: []const u8, buffer: []u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return buffer[0..try file.readPositionalAll(io, buffer, 0)];
}

fn resetTestDirectory(io: std.Io, path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, path) catch {};
    try cwd.createDirPath(io, path);
}

test "server stores directory metadata" {
    const server = Server.init(std.testing.io, ".zig-cache/test-webview-automation", "Test");
    try std.testing.expectEqualStrings("Test", server.title);
}

test "server writes bridge response artifact" {
    const server = Server.init(std.testing.io, ".zig-cache/test-webview-automation", "Test");
    try server.publishBridgeResponse("{\"id\":\"1\",\"ok\":true}");

    var buffer: [128]u8 = undefined;
    var path_buffer: [256]u8 = undefined;
    const bytes = try readPath(std.testing.io, server.path("bridge-response.txt", &path_buffer), &buffer);
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"ok\":true}", bytes);
}

test "server consumes automation command files" {
    const directory = ".zig-cache/test-webview-automation-command";
    try resetTestDirectory(std.testing.io, directory);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    const server = Server.init(std.testing.io, directory, "Test");
    var path_buffer: [256]u8 = undefined;
    const command_path = server.path("command.txt", &path_buffer);

    try writePath(std.testing.io, command_path, "native-command app.refresh refresh-button\n");

    var command_buffer: [256]u8 = undefined;
    const native_command = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.native_command, native_command.action);
    try std.testing.expectEqualStrings("app.refresh refresh-button", native_command.value);

    var done_buffer: [16]u8 = undefined;
    const done = try readPath(std.testing.io, command_path, &done_buffer);
    try std.testing.expectEqualStrings("done\n", done);
    try std.testing.expect(try server.takeCommand(&command_buffer) == null);

    try writePath(std.testing.io, command_path, "focus-next\n");
    const focus_next = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.focus_next_view, focus_next.action);
    try std.testing.expectEqualStrings("", focus_next.value);

    try writePath(std.testing.io, command_path, "widget-action canvas 2 press\n");
    const widget_action = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.widget_action, widget_action.action);
    try std.testing.expectEqualStrings("canvas 2 press", widget_action.value);
}
