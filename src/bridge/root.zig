const std = @import("std");
const json = @import("json");
const security = @import("../security/root.zig");

pub const max_message_bytes: usize = 1024 * 1024;
// Responses/results may carry base64-encoded HTTP bodies (e.g. images) from the
// native net.fetch bridge, so these are sized generously (48 MB). Buffers of this
// size must never live on the stack — see the shared static buffers below.
pub const max_response_bytes: usize = 48 * 1024 * 1024;
pub const max_result_bytes: usize = 48 * 1024 * 1024;
pub const max_id_bytes: usize = 64;
pub const max_command_bytes: usize = 128;

// Bridge dispatch runs on the single main event-loop thread, so these large
// buffers are shared statics rather than per-call stack arrays (a 48 MB stack
// allocation would overflow the thread stack).
var shared_response_buffer: [max_response_bytes]u8 = undefined;
var shared_result_buffer: [max_result_bytes]u8 = undefined;

pub fn sharedResponseBuffer() []u8 {
    return &shared_response_buffer;
}

pub fn sharedResultBuffer() []u8 {
    return &shared_result_buffer;
}

const null_json = "null";

pub const ErrorCode = enum {
    invalid_request,
    unknown_command,
    permission_denied,
    handler_failed,
    payload_too_large,
    internal_error,

    pub fn jsonName(self: ErrorCode) []const u8 {
        return @tagName(self);
    }
};

pub const ParseError = error{
    InvalidRequest,
    PayloadTooLarge,
};

pub const Source = struct {
    origin: []const u8 = "",
    window_id: u64 = 1,
};

pub const Request = struct {
    id: []const u8,
    command: []const u8,
    payload: []const u8 = null_json,
};

pub const Invocation = struct {
    request: Request,
    source: Source,
};

pub const CommandPolicy = struct {
    name: []const u8,
    permissions: []const []const u8 = &.{},
    origins: []const []const u8 = &.{},
};

pub const Policy = struct {
    enabled: bool = false,
    permissions: []const []const u8 = &.{},
    commands: []const CommandPolicy = &.{},

    pub fn allows(self: Policy, command: []const u8, origin: []const u8) bool {
        if (!self.enabled) return false;
        const command_policy = self.find(command) orelse return false;
        if (!security.hasPermissions(self.permissions, command_policy.permissions)) return false;
        if (command_policy.origins.len == 0) return true;
        for (command_policy.origins) |allowed| {
            if (std.mem.eql(u8, allowed, "*")) return true;
            if (std.mem.eql(u8, allowed, origin)) return true;
        }
        return false;
    }

    pub fn find(self: Policy, command: []const u8) ?CommandPolicy {
        for (self.commands) |command_policy| {
            if (std.mem.eql(u8, command_policy.name, command)) return command_policy;
        }
        return null;
    }
};

pub const HandlerFn = *const fn (context: *anyopaque, invocation: Invocation, output: []u8) anyerror![]const u8;
pub const AsyncRespondFn = *const fn (context: *anyopaque, source: Source, response: []const u8) anyerror!void;
pub const AsyncHandlerFn = *const fn (context: *anyopaque, invocation: Invocation, responder: AsyncResponder) anyerror!void;

pub const Handler = struct {
    name: []const u8,
    context: *anyopaque,
    invoke_fn: HandlerFn,
};

pub const AsyncResponder = struct {
    context: *anyopaque,
    source: Source,
    respond_fn: AsyncRespondFn,

    pub fn respond(self: AsyncResponder, response: []const u8) anyerror!void {
        return self.respond_fn(self.context, self.source, response);
    }

    pub fn success(self: AsyncResponder, id: []const u8, result: []const u8) anyerror!void {
        try self.respond(writeSuccessResponse(sharedResponseBuffer(), id, result));
    }

    pub fn fail(self: AsyncResponder, id: []const u8, code: ErrorCode, message: []const u8) anyerror!void {
        try self.respond(writeErrorResponse(sharedResponseBuffer(), id, code, message));
    }
};

pub const AsyncHandler = struct {
    name: []const u8,
    context: *anyopaque,
    invoke_fn: AsyncHandlerFn,
};

pub const Registry = struct {
    handlers: []const Handler = &.{},

    pub fn find(self: Registry, command: []const u8) ?Handler {
        for (self.handlers) |handler| {
            if (std.mem.eql(u8, handler.name, command)) return handler;
        }
        return null;
    }
};

pub const AsyncRegistry = struct {
    handlers: []const AsyncHandler = &.{},

    pub fn find(self: AsyncRegistry, command: []const u8) ?AsyncHandler {
        for (self.handlers) |handler| {
            if (std.mem.eql(u8, handler.name, command)) return handler;
        }
        return null;
    }
};

pub const Dispatcher = struct {
    policy: Policy = .{},
    registry: Registry = .{},
    async_registry: AsyncRegistry = .{},

    pub fn dispatch(self: Dispatcher, raw: []const u8, source: Source, output: []u8) []const u8 {
        if (raw.len > max_message_bytes) {
            return writeErrorResponse(output, "", .payload_too_large, "Bridge request is too large");
        }

        const request = parseRequest(raw) catch {
            return writeErrorResponse(output, "", .invalid_request, "Bridge request is malformed");
        };

        if (!self.policy.allows(request.command, source.origin)) {
            return writeErrorResponse(output, request.id, .permission_denied, "Bridge command is not permitted");
        }

        const handler = self.registry.find(request.command) orelse {
            return writeErrorResponse(output, request.id, .unknown_command, "Bridge command is not registered");
        };

        const result = handler.invoke_fn(handler.context, .{ .request = request, .source = source }, sharedResultBuffer()) catch |err| {
            return writeErrorResponse(output, request.id, .handler_failed, @errorName(err));
        };
        return writeSuccessResponse(output, request.id, if (result.len == 0) null_json else result);
    }
};

pub fn parseRequest(raw: []const u8) ParseError!Request {
    if (raw.len > max_message_bytes) return error.PayloadTooLarge;
    var index: usize = 0;
    try skipWhitespace(raw, &index);
    try expectByte(raw, &index, '{');

    var id: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var payload: []const u8 = null_json;

    try skipWhitespace(raw, &index);
    if (peekByte(raw, index) == '}') {
        index += 1;
    } else {
        while (true) {
            try skipWhitespace(raw, &index);
            const key = try parseSimpleString(raw, &index);
            try skipWhitespace(raw, &index);
            try expectByte(raw, &index, ':');
            try skipWhitespace(raw, &index);

            if (std.mem.eql(u8, key, "id")) {
                id = try parseSimpleString(raw, &index);
            } else if (std.mem.eql(u8, key, "command")) {
                command = try parseSimpleString(raw, &index);
            } else if (std.mem.eql(u8, key, "payload")) {
                const start = index;
                try skipJsonValue(raw, &index);
                payload = raw[start..index];
            } else {
                try skipJsonValue(raw, &index);
            }

            try skipWhitespace(raw, &index);
            const next = peekByte(raw, index) orelse return error.InvalidRequest;
            if (next == ',') {
                index += 1;
                continue;
            }
            if (next == '}') {
                index += 1;
                break;
            }
            return error.InvalidRequest;
        }
    }

    try skipWhitespace(raw, &index);
    if (index != raw.len) return error.InvalidRequest;

    const request_id = id orelse return error.InvalidRequest;
    const command_name = command orelse return error.InvalidRequest;
    if (!validId(request_id) or !validCommand(command_name)) return error.InvalidRequest;
    return .{ .id = request_id, .command = command_name, .payload = payload };
}

pub fn writeSuccessResponse(output: []u8, id: []const u8, result: []const u8) []const u8 {
    const value = if (result.len == 0) null_json else result;
    if (!json.isValidValue(value)) {
        return writeErrorResponse(output, id, .handler_failed, "Bridge command returned invalid JSON");
    }
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("{\"id\":") catch return output[0..0];
    json.writeString(&writer, id) catch return output[0..0];
    writer.writeAll(",\"ok\":true,\"result\":") catch return output[0..0];
    writer.writeAll(value) catch return output[0..0];
    writer.writeAll("}") catch return output[0..0];
    return writer.buffered();
}

pub fn writeErrorResponse(output: []u8, id: []const u8, code: ErrorCode, message: []const u8) []const u8 {
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("{\"id\":") catch return output[0..0];
    json.writeString(&writer, id) catch return output[0..0];
    writer.writeAll(",\"ok\":false,\"error\":{\"code\":") catch return output[0..0];
    json.writeString(&writer, code.jsonName()) catch return output[0..0];
    writer.writeAll(",\"message\":") catch return output[0..0];
    json.writeString(&writer, message) catch return output[0..0];
    writer.writeAll("}}") catch return output[0..0];
    return writer.buffered();
}

pub fn writeJsonStringValue(output: []u8, value: []const u8) []const u8 {
    var writer = std.Io.Writer.fixed(output);
    json.writeString(&writer, value) catch return output[0..0];
    return writer.buffered();
}

pub fn isValidJsonValue(raw: []const u8) bool {
    return json.isValidValue(raw);
}

fn validId(value: []const u8) bool {
    if (value.len == 0 or value.len > max_id_bytes) return false;
    for (value) |ch| {
        if (ch <= 0x1f or ch == '"' or ch == '\\') return false;
    }
    return true;
}

fn validCommand(value: []const u8) bool {
    if (value.len == 0 or value.len > max_command_bytes) return false;
    for (value) |ch| {
        if (ch <= 0x1f or ch == '"' or ch == '\\' or ch == '/' or ch == ' ') return false;
    }
    return true;
}

fn skipWhitespace(raw: []const u8, index: *usize) ParseError!void {
    while (index.* < raw.len) : (index.* += 1) {
        switch (raw[index.*]) {
            ' ', '\n', '\r', '\t' => {},
            else => return,
        }
    }
}

fn expectByte(raw: []const u8, index: *usize, expected: u8) ParseError!void {
    if (peekByte(raw, index.*) != expected) return error.InvalidRequest;
    index.* += 1;
}

fn peekByte(raw: []const u8, index: usize) ?u8 {
    if (index >= raw.len) return null;
    return raw[index];
}

fn parseSimpleString(raw: []const u8, index: *usize) ParseError![]const u8 {
    try expectByte(raw, index, '"');
    const start = index.*;
    while (index.* < raw.len) : (index.* += 1) {
        const ch = raw[index.*];
        if (ch == '"') {
            const value = raw[start..index.*];
            index.* += 1;
            return value;
        }
        if (ch == '\\' or ch <= 0x1f) return error.InvalidRequest;
    }
    return error.InvalidRequest;
}

fn skipJsonValue(raw: []const u8, index: *usize) ParseError!void {
    const start = peekByte(raw, index.*) orelse return error.InvalidRequest;
    switch (start) {
        '"' => try skipJsonString(raw, index),
        '{' => try skipJsonContainer(raw, index, '{', '}'),
        '[' => try skipJsonContainer(raw, index, '[', ']'),
        else => try skipJsonAtom(raw, index),
    }
}

fn skipJsonString(raw: []const u8, index: *usize) ParseError!void {
    try expectByte(raw, index, '"');
    while (index.* < raw.len) : (index.* += 1) {
        const ch = raw[index.*];
        if (ch == '"') {
            index.* += 1;
            return;
        }
        if (ch == '\\') {
            index.* += 1;
            if (index.* >= raw.len) return error.InvalidRequest;
        } else if (ch <= 0x1f) {
            return error.InvalidRequest;
        }
    }
    return error.InvalidRequest;
}

fn skipJsonContainer(raw: []const u8, index: *usize, open: u8, close: u8) ParseError!void {
    try expectByte(raw, index, open);
    try skipWhitespace(raw, index);
    if (peekByte(raw, index.*) == close) {
        index.* += 1;
        return;
    }
    while (true) {
        try skipWhitespace(raw, index);
        if (open == '{') {
            try skipJsonString(raw, index);
            try skipWhitespace(raw, index);
            try expectByte(raw, index, ':');
            try skipWhitespace(raw, index);
        }
        try skipJsonValue(raw, index);
        try skipWhitespace(raw, index);
        const next = peekByte(raw, index.*) orelse return error.InvalidRequest;
        if (next == ',') {
            index.* += 1;
            continue;
        }
        if (next == close) {
            index.* += 1;
            return;
        }
        return error.InvalidRequest;
    }
}

fn skipJsonAtom(raw: []const u8, index: *usize) ParseError!void {
    const start = index.*;
    while (index.* < raw.len) : (index.* += 1) {
        switch (raw[index.*]) {
            ',', '}', ']', ' ', '\n', '\r', '\t' => break,
            else => {},
        }
    }
    if (start == index.*) return error.InvalidRequest;
    const atom = raw[start..index.*];
    if (std.mem.eql(u8, atom, "true") or std.mem.eql(u8, atom, "false") or std.mem.eql(u8, atom, "null")) return;
    _ = std.fmt.parseFloat(f64, atom) catch return error.InvalidRequest;
}

test "bridge parses request envelope and raw payload" {
    const request = try parseRequest(
        \\{"id":"1","command":"native.ping","payload":{"text":"hello","count":2}}
    );
    try std.testing.expectEqualStrings("1", request.id);
    try std.testing.expectEqualStrings("native.ping", request.command);
    try std.testing.expectEqualStrings("{\"text\":\"hello\",\"count\":2}", request.payload);
}

test "bridge rejects malformed or oversized requests" {
    try std.testing.expectError(error.InvalidRequest, parseRequest("{}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"id\":\"\",\"command\":\"native.ping\"}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"id\":\"1\",\"command\":\"bad command\"}"));
}

test "bridge writes success and error responses" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"id\":\"abc\",\"ok\":true,\"result\":{\"pong\":true}}",
        writeSuccessResponse(&buffer, "abc", "{\"pong\":true}"),
    );
    try std.testing.expectEqualStrings(
        "{\"id\":\"abc\",\"ok\":false,\"error\":{\"code\":\"permission_denied\",\"message\":\"Denied\"}}",
        writeErrorResponse(&buffer, "abc", .permission_denied, "Denied"),
    );
}

test "bridge validates and writes JSON result values" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("\"hello \\\"user\\\"\"",
        writeJsonStringValue(&buffer, "hello \"user\""));
    try std.testing.expect(isValidJsonValue("{\"pong\":true}"));
    try std.testing.expect(isValidJsonValue("{\"escaped\\\"key\":true}"));
    try std.testing.expect(isValidJsonValue("\"hello\""));
    try std.testing.expect(isValidJsonValue("null"));
    try std.testing.expect(!isValidJsonValue("raw \"user\" text"));
    try std.testing.expect(!isValidJsonValue("{\"partial\":true"));

    const response = writeSuccessResponse(&buffer, "abc", "raw \"user\" text");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"handler_failed\"") != null);
}

test "dispatcher enforces policy and invokes registered handler" {
    const State = struct {
        fn ping(context: *anyopaque, invocation: Invocation, output: []u8) anyerror![]const u8 {
            _ = context;
            _ = output;
            try std.testing.expectEqualStrings("{\"value\":1}", invocation.request.payload);
            try std.testing.expectEqualStrings("zero://inline", invocation.source.origin);
            return "{\"pong\":true}";
        }
    };

    var state: u8 = 0;
    const policies = [_]CommandPolicy{.{ .name = "native.ping", .origins = &.{"zero://inline"} }};
    const handlers = [_]Handler{.{ .name = "native.ping", .context = &state, .invoke_fn = State.ping }};
    const dispatcher: Dispatcher = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &handlers },
    };

    var buffer: [256]u8 = undefined;
    const response = dispatcher.dispatch(
        \\{"id":"1","command":"native.ping","payload":{"value":1}}
    , .{ .origin = "zero://inline" }, &buffer);
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"ok\":true,\"result\":{\"pong\":true}}", response);
}

test "dispatcher rejects invalid handler result JSON" {
    const State = struct {
        fn unsafe(context: *anyopaque, invocation: Invocation, output: []u8) anyerror![]const u8 {
            _ = context;
            _ = invocation;
            _ = output;
            return "hello \"user\"";
        }
    };

    var state: u8 = 0;
    const policies = [_]CommandPolicy{.{ .name = "native.unsafe", .origins = &.{"zero://inline"} }};
    const handlers = [_]Handler{.{ .name = "native.unsafe", .context = &state, .invoke_fn = State.unsafe }};
    const dispatcher: Dispatcher = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &handlers },
    };

    var buffer: [256]u8 = undefined;
    const response = dispatcher.dispatch(
        \\{"id":"1","command":"native.unsafe","payload":null}
    , .{ .origin = "zero://inline" }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"handler_failed\"") != null);
}

test "dispatcher requires command permissions and matching origins" {
    const policies = [_]CommandPolicy{.{ .name = "native.secure", .permissions = &.{"filesystem"}, .origins = &.{"zero://app"} }};
    const wildcard_policies = [_]CommandPolicy{.{ .name = "native.anywhere", .permissions = &.{"filesystem"}, .origins = &.{"*"} }};
    const dispatcher: Dispatcher = .{
        .policy = .{ .enabled = true, .permissions = &.{"filesystem"}, .commands = &policies },
        .registry = .{},
    };
    const wildcard: Dispatcher = .{
        .policy = .{ .enabled = true, .permissions = &.{"filesystem"}, .commands = &wildcard_policies },
        .registry = .{},
    };
    const denied_by_origin: Dispatcher = .{
        .policy = .{ .enabled = true, .permissions = &.{"filesystem"}, .commands = &policies },
        .registry = .{},
    };
    const denied_by_permission: Dispatcher = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{},
    };

    try std.testing.expect(dispatcher.policy.allows("native.secure", "zero://app"));
    try std.testing.expect(wildcard.policy.allows("native.anywhere", "https://example.com"));
    try std.testing.expect(!denied_by_origin.policy.allows("native.secure", "zero://inline"));
    try std.testing.expect(!denied_by_permission.policy.allows("native.secure", "zero://app"));
}

test "dispatcher reports permission denial before unknown command" {
    const dispatcher: Dispatcher = .{};
    var buffer: [256]u8 = undefined;
    const response = dispatcher.dispatch(
        \\{"id":"1","command":"native.ping","payload":null}
    , .{}, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"permission_denied\"") != null);
}
