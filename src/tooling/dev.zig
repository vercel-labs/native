const std = @import("std");
const manifest_tool = @import("manifest.zig");
const process_tree = @import("process_tree.zig");

pub const Error = error{
    MissingFrontend,
    MissingDevConfig,
    MissingBinary,
    InvalidUrl,
    Timeout,
};

pub const Options = struct {
    metadata: manifest_tool.Metadata,
    base_env: ?*const std.process.Environ.Map = null,
    binary_path: ?[]const u8 = null,
    url_override: ?[]const u8 = null,
    command_override: ?[]const []const u8 = null,
    timeout_ms: ?u32 = null,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const frontend = options.metadata.frontend orelse return error.MissingFrontend;
    const dev = frontend.dev orelse return error.MissingDevConfig;
    const url = options.url_override orelse dev.url;
    const command = options.command_override orelse dev.command;
    const timeout_ms = options.timeout_ms orelse dev.timeout_ms;

    // Both children go into their own process groups (see process_tree):
    // a dev-server command spawns the real server as ITS child, and the
    // app must die with the session even when this CLI is signalled —
    // an orphaned automation-enabled app keeps publishing snapshots that
    // impersonate the next build.
    var dev_child: ?std.process.Child = null;
    if (command.len > 0) {
        dev_child = try std.process.spawn(io, .{
            .argv = command,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
            .pgid = process_tree.spawnPgid(),
        });
    }
    // Capture group ids at spawn: wait()/kill() clear the child's id.
    const dev_group: i32 = if (dev_child) |*child| (if (child.id) |id| @as(i32, @intCast(id)) else 0) else 0;
    if (dev_group > 0) process_tree.own(dev_group);
    defer if (dev_child) |*child| {
        child.kill(io);
        if (dev_group > 0) process_tree.releaseAndKill(dev_group);
    };

    try waitUntilReady(io, url, dev.ready_path, timeout_ms);

    const binary_path = options.binary_path orelse return error.MissingBinary;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    if (options.base_env) |base_env| {
        const keys = base_env.keys();
        const values = base_env.values();
        for (keys, values) |key, value| try env.put(key, value);
    }
    try env.put("NATIVE_SDK_FRONTEND_URL", url);
    try env.put("NATIVE_SDK_MODE", "dev");
    try env.put("NATIVE_SDK_HMR", "1");

    const app_args = [_][]const u8{binary_path};
    var app_child = try std.process.spawn(io, .{
        .argv = &app_args,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env,
        .pgid = process_tree.spawnPgid(),
    });
    const app_group: i32 = if (app_child.id) |id| @as(i32, @intCast(id)) else 0;
    if (app_group > 0) process_tree.own(app_group);
    defer if (app_group > 0) process_tree.releaseAndKill(app_group);
    _ = try app_child.wait(io);
}

pub const UrlParts = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub fn parseHttpUrl(url: []const u8) Error!UrlParts {
    const default_port: u16 = if (std.mem.startsWith(u8, url, "http://"))
        80
    else if (std.mem.startsWith(u8, url, "https://"))
        443
    else
        return error.InvalidUrl;
    const rest = url[if (default_port == 80) "http://".len else "https://".len ..];
    const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash_index];
    if (host_port.len == 0) return error.InvalidUrl;
    const path = if (slash_index < rest.len) rest[slash_index..] else "/";

    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        if (colon == 0 or colon + 1 >= host_port.len) return error.InvalidUrl;
        return .{
            .host = host_port[0..colon],
            .port = std.fmt.parseUnsigned(u16, host_port[colon + 1 ..], 10) catch return error.InvalidUrl,
            .path = path,
        };
    }

    return .{ .host = host_port, .port = default_port, .path = path };
}

fn waitUntilReady(io: std.Io, url: []const u8, ready_path: []const u8, timeout_ms: u32) !void {
    const parts = try parseHttpUrl(url);
    const host = if (std.mem.eql(u8, parts.host, "localhost")) "127.0.0.1" else parts.host;
    const path = if (ready_path.len > 0) ready_path else parts.path;
    var waited_ms: u32 = 0;
    while (waited_ms <= timeout_ms) : (waited_ms += 100) {
        const address = std.Io.net.IpAddress.resolve(io, host, parts.port) catch {
            sleepPollInterval(io);
            continue;
        };
        if (std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp })) |stream| {
            if (httpReady(io, stream, parts.host, path)) {
                stream.close(io);
                return;
            }
            stream.close(io);
        } else |_| {
            sleepPollInterval(io);
        }
    }
    return error.Timeout;
}

fn httpReady(io: std.Io, stream: std.Io.net.Stream, host: []const u8, path: []const u8) bool {
    var request_buffer: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host }) catch return false;
    var write_buffer: [512]u8 = undefined;
    var stream_writer = std.Io.net.Stream.writer(stream, io, &write_buffer);
    stream_writer.interface.writeAll(request) catch return false;
    stream_writer.interface.flush() catch return false;
    var response_buffer: [64]u8 = undefined;
    var read_buffer: [512]u8 = undefined;
    var stream_reader = std.Io.net.Stream.reader(stream, io, &read_buffer);
    const len = stream_reader.interface.readSliceShort(&response_buffer) catch return false;
    const response = response_buffer[0..len];
    return std.mem.startsWith(u8, response, "HTTP/1.1 2") or
        std.mem.startsWith(u8, response, "HTTP/1.0 2") or
        std.mem.startsWith(u8, response, "HTTP/1.1 3") or
        std.mem.startsWith(u8, response, "HTTP/1.0 3");
}

fn sleepPollInterval(io: std.Io) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
}

test "parse dev server urls" {
    const vite = try parseHttpUrl("http://127.0.0.1:5173/");
    try std.testing.expectEqualStrings("127.0.0.1", vite.host);
    try std.testing.expectEqual(@as(u16, 5173), vite.port);
    try std.testing.expectEqualStrings("/", vite.path);

    const next = try parseHttpUrl("http://localhost:3000/app");
    try std.testing.expectEqualStrings("localhost", next.host);
    try std.testing.expectEqual(@as(u16, 3000), next.port);
    try std.testing.expectEqualStrings("/app", next.path);
}

test "parse dev server urls rejects unsupported schemes" {
    try std.testing.expectError(error.InvalidUrl, parseHttpUrl("ws://localhost:5173/"));
    try std.testing.expectError(error.InvalidUrl, parseHttpUrl("http://:5173/"));
}
