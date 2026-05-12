const std = @import("std");
const json = @import("json");

pub const max_resource_id_bytes: usize = 32;
pub const max_resource_name_bytes: usize = 128;
pub const max_resource_mime_bytes: usize = 128;
pub const max_resource_count: usize = 128;
pub const default_ttl_ns: i128 = 5 * 60 * std.time.ns_per_s;

pub const Error = error{
    ResourceLimitReached,
    ResourceNotFound,
    ResourceExpired,
    ResourceOriginMismatch,
    ResourceWindowMismatch,
    InvalidResourceMetadata,
    InvalidResourceProvider,
    NoSpaceLeft,
};

pub const Options = struct {
    mime: []const u8 = "application/octet-stream",
    name: []const u8 = "",
    origin: []const u8 = "",
    window_id: u64 = 0,
    ttl_ns: ?i128 = default_ttl_ns,
    one_shot: bool = true,

    pub fn download(name: []const u8, mime: []const u8) Options {
        return .{ .name = name, .mime = mime };
    }

    pub fn withTtlSeconds(self: Options, seconds: u64) Options {
        var options = self;
        options.ttl_ns = @as(i128, @intCast(seconds)) * std.time.ns_per_s;
        return options;
    }

    pub fn reusable(self: Options) Options {
        var options = self;
        options.one_shot = false;
        return options;
    }

    pub fn withoutTtl(self: Options) Options {
        var options = self;
        options.ttl_ns = null;
        return options;
    }
};

pub const Descriptor = struct {
    id: []const u8,
    url: []const u8,
    mime: []const u8,
    name: []const u8 = "",
    size: ?usize = null,
    one_shot: bool = false,
};

pub const CloseReason = enum {
    complete,
    cancel,
    revoke,
    expired,
    failure,
};

pub const StreamProvider = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, output: []u8) anyerror!usize,
    close_fn: ?*const fn (context: *anyopaque, reason: CloseReason) void = null,
    size: ?usize = null,

    fn read(self: StreamProvider, output: []u8) !usize {
        return self.read_fn(self.context, output);
    }

    fn close(self: StreamProvider, reason: CloseReason) void {
        if (self.close_fn) |close_fn| close_fn(self.context, reason);
    }
};

const Payload = union(enum) {
    bytes: []u8,
    stream: StreamProvider,
};

const Entry = struct {
    id: []u8,
    url: []u8,
    payload: Payload,
    bytes_offset: usize = 0,
    mime: []u8,
    name: []u8,
    origin: []u8,
    window_id: u64,
    expires_at_ns: ?i128,
    one_shot: bool,

    fn descriptor(self: Entry) Descriptor {
        return .{
            .id = self.id,
            .url = self.url,
            .mime = self.mime,
            .name = self.name,
            .size = switch (self.payload) {
                .bytes => |bytes| bytes.len,
                .stream => |provider| provider.size,
            },
            .one_shot = self.one_shot,
        };
    }
};

pub const Source = struct {
    origin: []const u8 = "",
    window_id: u64 = 1,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    nonce_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |entry| self.freeEntry(entry);
        self.entries.deinit(self.allocator);
    }

    pub fn registerBytes(self: *Registry, bytes: []const u8, options: Options, now_ns: i128) !Descriptor {
        self.pruneExpired(now_ns);
        if (self.entries.items.len >= max_resource_count) return error.ResourceLimitReached;
        try validateMetadata(options);

        var id_buffer: [max_resource_id_bytes]u8 = undefined;
        const id = try self.generateId(&id_buffer, now_ns);
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        const url = try std.fmt.allocPrint(self.allocator, "zero://native/resource/{s}", .{owned_id});
        errdefer self.allocator.free(url);
        const owned_bytes = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned_bytes);
        const owned_mime = try self.allocator.dupe(u8, options.mime);
        errdefer self.allocator.free(owned_mime);
        const owned_name = try self.allocator.dupe(u8, options.name);
        errdefer self.allocator.free(owned_name);
        const owned_origin = try self.allocator.dupe(u8, options.origin);
        errdefer self.allocator.free(owned_origin);

        const entry: Entry = .{
            .id = owned_id,
            .url = url,
            .payload = .{ .bytes = owned_bytes },
            .mime = owned_mime,
            .name = owned_name,
            .origin = owned_origin,
            .window_id = options.window_id,
            .expires_at_ns = if (options.ttl_ns) |ttl| now_ns + ttl else null,
            .one_shot = options.one_shot,
        };
        try self.entries.append(self.allocator, entry);
        return entry.descriptor();
    }

    pub fn registerStream(self: *Registry, provider: StreamProvider, options: Options, now_ns: i128) !Descriptor {
        self.pruneExpired(now_ns);
        if (self.entries.items.len >= max_resource_count) return error.ResourceLimitReached;
        try validateMetadata(options);

        var id_buffer: [max_resource_id_bytes]u8 = undefined;
        const id = try self.generateId(&id_buffer, now_ns);
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        const url = try std.fmt.allocPrint(self.allocator, "zero://native/resource/{s}", .{owned_id});
        errdefer self.allocator.free(url);
        const owned_mime = try self.allocator.dupe(u8, options.mime);
        errdefer self.allocator.free(owned_mime);
        const owned_name = try self.allocator.dupe(u8, options.name);
        errdefer self.allocator.free(owned_name);
        const owned_origin = try self.allocator.dupe(u8, options.origin);
        errdefer self.allocator.free(owned_origin);

        const entry: Entry = .{
            .id = owned_id,
            .url = url,
            .payload = .{ .stream = provider },
            .mime = owned_mime,
            .name = owned_name,
            .origin = owned_origin,
            .window_id = options.window_id,
            .expires_at_ns = if (options.ttl_ns) |ttl| now_ns + ttl else null,
            .one_shot = options.one_shot,
        };
        try self.entries.append(self.allocator, entry);
        return entry.descriptor();
    }

    pub fn fetchBytes(self: *Registry, id: []const u8, source: Source, now_ns: i128, output: []u8) ![]const u8 {
        const index = self.findIndex(id) orelse return error.ResourceNotFound;
        const entry = self.entries.items[index];
        if (entry.expires_at_ns) |expires| {
            if (now_ns >= expires) {
                self.removeAt(index);
                return error.ResourceExpired;
            }
        }
        if (entry.origin.len > 0 and !std.mem.eql(u8, entry.origin, source.origin)) return error.ResourceOriginMismatch;
        if (entry.window_id != 0 and entry.window_id != source.window_id) return error.ResourceWindowMismatch;
        const bytes = switch (entry.payload) {
            .bytes => |bytes| bytes,
            .stream => return error.InvalidResourceProvider,
        };
        if (output.len < bytes.len) return error.NoSpaceLeft;
        @memcpy(output[0..bytes.len], bytes);
        const len = bytes.len;
        if (entry.one_shot) self.removeAt(index);
        return output[0..len];
    }

    pub fn readStream(self: *Registry, id: []const u8, source: Source, now_ns: i128, output: []u8) !usize {
        const index = self.findIndex(id) orelse return error.ResourceNotFound;
        var entry = &self.entries.items[index];
        if (entry.expires_at_ns) |expires| {
            if (now_ns >= expires) {
                self.closeEntry(entry.*, .expired);
                self.removeAt(index);
                return error.ResourceExpired;
            }
        }
        if (entry.origin.len > 0 and !std.mem.eql(u8, entry.origin, source.origin)) return error.ResourceOriginMismatch;
        if (entry.window_id != 0 and entry.window_id != source.window_id) return error.ResourceWindowMismatch;
        switch (entry.payload) {
            .bytes => |bytes| {
                if (entry.bytes_offset >= bytes.len) return 0;
                const count = @min(output.len, bytes.len - entry.bytes_offset);
                @memcpy(output[0..count], bytes[entry.bytes_offset..][0..count]);
                entry.bytes_offset += count;
                return count;
            },
            .stream => |provider| return provider.read(output),
        }
    }

    pub fn closeStream(self: *Registry, id: []const u8, reason: CloseReason) bool {
        const index = self.findIndex(id) orelse return false;
        const entry = self.entries.items[index];
        self.closeEntry(entry, reason);
        if (entry.one_shot or reason == .revoke or reason == .expired) {
            self.removeAt(index);
        }
        return true;
    }

    pub fn revoke(self: *Registry, id: []const u8) bool {
        const index = self.findIndex(id) orelse return false;
        self.closeEntry(self.entries.items[index], .revoke);
        self.removeAt(index);
        return true;
    }

    fn findIndex(self: *const Registry, id: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, id)) return index;
        }
        return null;
    }

    fn removeAt(self: *Registry, index: usize) void {
        const entry = self.entries.orderedRemove(index);
        self.freeEntry(entry);
    }

    fn pruneExpired(self: *Registry, now_ns: i128) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (self.entries.items[index].expires_at_ns) |expires| {
                if (now_ns >= expires) {
                    self.closeEntry(self.entries.items[index], .expired);
                    self.removeAt(index);
                    continue;
                }
            }
            index += 1;
        }
    }

    fn closeEntry(self: *Registry, entry: Entry, reason: CloseReason) void {
        _ = self;
        switch (entry.payload) {
            .bytes => {},
            .stream => |provider| provider.close(reason),
        }
    }

    fn freeEntry(self: *Registry, entry: Entry) void {
        self.allocator.free(entry.id);
        self.allocator.free(entry.url);
        switch (entry.payload) {
            .bytes => |bytes| self.allocator.free(bytes),
            .stream => {},
        }
        self.allocator.free(entry.mime);
        self.allocator.free(entry.name);
        self.allocator.free(entry.origin);
    }

    fn generateId(self: *Registry, buffer: *[max_resource_id_bytes]u8, now_ns: i128) ![]const u8 {
        self.nonce_counter +%= 1;
        var seed: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&seed);
        try writer.print("{x}:{x}:{x}", .{ now_ns, self.nonce_counter, self.entries.items.len });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(writer.buffered(), &digest, .{});
        const alphabet = "0123456789abcdef";
        for (digest[0..16], 0..) |byte, index| {
            buffer[index * 2] = alphabet[byte >> 4];
            buffer[index * 2 + 1] = alphabet[byte & 0x0f];
        }
        return buffer[0..32];
    }
};

pub fn writeDescriptorJson(output: []u8, descriptor: Descriptor) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"kind\":\"resource\",\"id\":");
    try json.writeString(&writer, descriptor.id);
    try writer.writeAll(",\"url\":");
    try json.writeString(&writer, descriptor.url);
    try writer.writeAll(",\"mime\":");
    try json.writeString(&writer, descriptor.mime);
    if (descriptor.size) |size| try writer.print(",\"size\":{d}", .{size});
    if (descriptor.name.len > 0) {
        try writer.writeAll(",\"name\":");
        try json.writeString(&writer, descriptor.name);
    }
    if (descriptor.one_shot) try writer.writeAll(",\"oneShot\":true");
    try writer.writeAll("}");
    return writer.buffered();
}

fn validateMetadata(options: Options) !void {
    if (options.mime.len == 0 or options.mime.len > max_resource_mime_bytes) return error.InvalidResourceMetadata;
    if (options.name.len > max_resource_name_bytes) return error.InvalidResourceMetadata;
}

test "resource registry creates fetch descriptors" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const descriptor = try registry.registerBytes("hello", .{
        .mime = "text/plain",
        .name = "hello.txt",
        .origin = "zero://app",
        .window_id = 1,
    }, 100);

    try std.testing.expectEqualStrings("text/plain", descriptor.mime);
    try std.testing.expect(descriptor.one_shot);
    try std.testing.expect(std.mem.startsWith(u8, descriptor.url, "zero://native/resource/"));

    var output: [512]u8 = undefined;
    const json_bytes = try writeDescriptorJson(&output, descriptor);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"kind\":\"resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"oneShot\":true") != null);

    var fetch_buffer: [32]u8 = undefined;
    const bytes = try registry.fetchBytes(descriptor.id, .{ .origin = "zero://app", .window_id = 1 }, 101, &fetch_buffer);
    try std.testing.expectEqualStrings("hello", bytes);
}

test "resource registry enforces origin and expiration" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const descriptor = try registry.registerBytes("secret", .{ .origin = "zero://app", .ttl_ns = 10 }, 100);
    var fetch_buffer: [32]u8 = undefined;
    try std.testing.expectError(error.ResourceOriginMismatch, registry.fetchBytes(descriptor.id, .{ .origin = "https://example.com" }, 101, &fetch_buffer));
    try std.testing.expectError(error.ResourceExpired, registry.fetchBytes(descriptor.id, .{ .origin = "zero://app" }, 111, &fetch_buffer));
}

test "resource options default to one-shot TTL and support reusable downloads" {
    const defaults = Options{};
    try std.testing.expect(defaults.one_shot);
    try std.testing.expectEqual(@as(?i128, default_ttl_ns), defaults.ttl_ns);

    const options = Options.download("report.csv", "text/csv").reusable().withoutTtl();
    try std.testing.expectEqualStrings("report.csv", options.name);
    try std.testing.expectEqualStrings("text/csv", options.mime);
    try std.testing.expect(!options.one_shot);
    try std.testing.expect(options.ttl_ns == null);

    const short_lived = options.withTtlSeconds(30);
    try std.testing.expectEqual(@as(?i128, 30 * std.time.ns_per_s), short_lived.ttl_ns);
}

test "resource registry one-shot fetch copies bytes and frees entry" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const descriptor = try registry.registerBytes("consume me", .{ .one_shot = true }, 100);

    var fetch_buffer: [32]u8 = undefined;
    const bytes = try registry.fetchBytes(descriptor.id, .{}, 101, &fetch_buffer);
    try std.testing.expectEqualStrings("consume me", bytes);
    try std.testing.expectEqual(@as(usize, 0), registry.entries.items.len);
    try std.testing.expectError(error.ResourceNotFound, registry.fetchBytes(descriptor.id, .{}, 102, &fetch_buffer));
}

test "resource registry streams provider chunks and closes" {
    const State = struct {
        bytes: []const u8 = "stream me",
        offset: usize = 0,
        close_reason: ?CloseReason = null,

        fn read(context: *anyopaque, output: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.offset >= self.bytes.len) return 0;
            const count = @min(output.len, self.bytes.len - self.offset);
            @memcpy(output[0..count], self.bytes[self.offset..][0..count]);
            self.offset += count;
            return count;
        }

        fn close(context: *anyopaque, reason: CloseReason) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.close_reason = reason;
        }
    };

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var state = State{};

    const descriptor = try registry.registerStream(.{
        .context = &state,
        .read_fn = State.read,
        .close_fn = State.close,
        .size = state.bytes.len,
    }, .{ .mime = "text/plain" }, 100);

    try std.testing.expectEqual(@as(?usize, state.bytes.len), descriptor.size);
    var chunk: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try registry.readStream(descriptor.id, .{}, 101, &chunk));
    try std.testing.expectEqualStrings("stre", &chunk);
    try std.testing.expectEqual(@as(usize, 4), try registry.readStream(descriptor.id, .{}, 101, &chunk));
    try std.testing.expectEqualStrings("am m", &chunk);
    try std.testing.expectEqual(@as(usize, 1), try registry.readStream(descriptor.id, .{}, 101, &chunk));
    try std.testing.expectEqualStrings("e", chunk[0..1]);
    try std.testing.expectEqual(@as(usize, 0), try registry.readStream(descriptor.id, .{}, 101, &chunk));
    try std.testing.expect(registry.closeStream(descriptor.id, .complete));
    try std.testing.expectEqual(CloseReason.complete, state.close_reason.?);
    try std.testing.expectEqual(@as(usize, 0), registry.entries.items.len);
}
