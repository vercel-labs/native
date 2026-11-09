//! Native-owned transport and execution for compiled authorization decisions.
const std = @import("std");
const bridge = @import("../bridge/root.zig");
const security = @import("../security/root.zig");
const platform = @import("../platform/root.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { permission, permissions, origin, external, bridge_command, builtin, external_admission };
const Packet = struct {
    writer: std.Io.Writer.Allocating,
    fn init(allocator: std.mem.Allocator, mode: Mode, flags: [4]u8) Packet {
        var self = Packet{ .writer = .init(allocator) };
        self.append(&.{ 88, 1, @intFromEnum(mode), flags[0], flags[1], flags[2], flags[3], 0 });
        return self;
    }
    fn append(self: *Packet, value: []const u8) void {
        self.writer.writer.writeAll(value) catch @panic("authorization transport allocation failed");
    }
    fn integer(self: *Packet, value: usize) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @intCast(value), .little);
        self.append(&bytes);
    }
    fn field(self: *Packet, value: []const u8) void {
        self.integer(value.len);
        self.append(value);
    }
    fn list(self: *Packet, values: []const []const u8) void {
        self.integer(values.len);
        for (values) |value| self.field(value);
    }
    fn commands(self: *Packet, values: []const bridge.CommandPolicy) void {
        self.integer(values.len);
        for (values) |value| {
            self.field(value.name);
            self.list(value.permissions);
            self.list(value.origins);
        }
    }
    fn finish(self: *Packet, policy: Policy) Program {
        const input = self.writer.written();
        var result = Program{ .bytes = @splat(0xa5) };
        if (policy(input, &result.bytes) != 16 or result.word(0) != 1 or result.word(4) != input[2] or result.word(8) > 1 or result.word(12) > 3) @panic("invalid compiled authorization program");
        return result;
    }
};
pub const Program = struct {
    bytes: [16]u8,
    pub fn word(self: *const Program, at: usize) u32 {
        return std.mem.readInt(u32, self.bytes[at..][0..4], .little);
    }
    fn allowed(self: *const Program) bool {
        if (self.word(12) != 0) @panic("unexpected authorization error");
        return self.word(8) == 1;
    }
};
pub fn hasPermission(policy: ?Policy, grants: []const []const u8, permission: []const u8) bool {
    const compiled = policy orelse return security.hasPermission(grants, permission);
    var storage = std.heap.stackFallback(4096, std.heap.page_allocator);
    var packet = Packet.init(storage.get(), .permission, @splat(0));
    defer packet.writer.deinit();
    packet.list(grants);
    packet.field(permission);
    return packet.finish(compiled).allowed();
}
pub fn hasPermissions(policy: ?Policy, grants: []const []const u8, required: []const []const u8) bool {
    const compiled = policy orelse return security.hasPermissions(grants, required);
    var storage = std.heap.stackFallback(4096, std.heap.page_allocator);
    var packet = Packet.init(storage.get(), .permissions, @splat(0));
    defer packet.writer.deinit();
    packet.list(grants);
    packet.list(required);
    return packet.finish(compiled).allowed();
}
pub fn allowsOrigin(policy: ?Policy, allowed: []const []const u8, origin: []const u8) bool {
    const compiled = policy orelse return security.allowsOrigin(allowed, origin);
    var storage = std.heap.stackFallback(4096, std.heap.page_allocator);
    var packet = Packet.init(storage.get(), .origin, @splat(0));
    defer packet.writer.deinit();
    packet.list(allowed);
    packet.field(origin);
    return packet.finish(compiled).allowed();
}
pub fn allowsExternalUrl(policy: ?Policy, value: security.ExternalLinkPolicy, url: []const u8) bool {
    const compiled = policy orelse return security.allowsExternalUrl(value, url);
    var storage = std.heap.stackFallback(4096, std.heap.page_allocator);
    var packet = Packet.init(storage.get(), .external, .{ @intFromBool(value.action == .open_system_browser), 0, 0, 0 });
    defer packet.writer.deinit();
    packet.list(value.allowed_urls);
    packet.field(url);
    return packet.finish(compiled).allowed();
}
pub fn bridgeAllows(policy: ?Policy, value: bridge.Policy, command: []const u8, origin: []const u8) bool {
    const compiled = policy orelse return value.allows(command, origin);
    var storage = std.heap.stackFallback(4096, std.heap.page_allocator);
    var packet = Packet.init(storage.get(), .bridge_command, .{ @intFromBool(value.enabled), 0, 0, 0 });
    defer packet.writer.deinit();
    packet.list(value.permissions);
    packet.commands(value.commands);
    packet.field(command);
    packet.field(origin);
    return packet.finish(compiled).allowed();
}
pub fn builtinAllows(policy: Policy, value: bridge.Policy, navigation: security.Policy, js_window_api: bool, command: []const u8, origin: []const u8, permission: ?[]const u8) bool {
    var storage = std.heap.stackFallback(4096, std.heap.page_allocator);
    var packet = Packet.init(storage.get(), .builtin, .{ @intFromBool(value.enabled), @intFromBool(js_window_api), @intFromBool(permission != null), 0 });
    defer packet.writer.deinit();
    packet.list(navigation.permissions);
    packet.list(value.permissions);
    packet.commands(value.commands);
    packet.list(navigation.navigation.allowed_origins);
    packet.field(command);
    packet.field(origin);
    packet.field(permission orelse "");
    return packet.finish(policy).allowed();
}
pub fn validateExternalUrl(policy: ?Policy, value: security.ExternalLinkPolicy, url: []const u8) !void {
    const compiled = policy orelse {
        if (url.len == 0) return error.InvalidExternalUrl;
        if (url.len > platform.max_external_url_bytes) return error.ExternalUrlTooLarge;
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidExternalUrl;
        for (url) |ch| if (ch <= 0x20 or ch == 0x7f) return error.InvalidExternalUrl;
        if (!security.allowsExternalUrl(value, url)) return error.NavigationDenied;
        return;
    };
    var storage = std.heap.stackFallback(4096, std.heap.page_allocator);
    var packet = Packet.init(storage.get(), .external_admission, .{ @intFromBool(value.action == .open_system_browser), 0, 0, 0 });
    defer packet.writer.deinit();
    packet.list(value.allowed_urls);
    packet.field(url);
    packet.integer(platform.max_external_url_bytes);
    const result = packet.finish(compiled);
    switch (result.word(12)) {
        0 => if (result.word(8) != 1) @panic("invalid compiled external admission"),
        1 => return error.InvalidExternalUrl,
        2 => return error.ExternalUrlTooLarge,
        3 => return error.NavigationDenied,
        else => unreachable,
    }
}
/// Parsing, handler lookup/execution and response buffers remain native capabilities.
pub fn dispatch(policy: ?Policy, value: bridge.Dispatcher, raw: []const u8, source: bridge.Source, output: []u8) []const u8 {
    const compiled = policy orelse return value.dispatch(raw, source, output);
    if (raw.len > bridge.max_message_bytes) return bridge.writeErrorResponse(output, "", .payload_too_large, "Bridge request is too large");
    const request = bridge.parseRequest(raw) catch return bridge.writeErrorResponse(output, "", .invalid_request, "Bridge request is malformed");
    if (!bridgeAllows(compiled, value.policy, request.command, source.origin)) return bridge.writeErrorResponse(output, request.id, .permission_denied, "Bridge command is not permitted");
    const handler = value.registry.find(request.command) orelse return bridge.writeErrorResponse(output, request.id, .unknown_command, "Bridge command is not registered");
    var result_buffer: [bridge.max_result_bytes]u8 = undefined;
    const result = handler.invoke_fn(handler.context, .{ .request = request, .source = source }, &result_buffer) catch |err| return bridge.writeErrorResponse(output, request.id, .handler_failed, @errorName(err));
    return bridge.writeSuccessResponse(output, request.id, result);
}
