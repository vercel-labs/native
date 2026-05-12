const std = @import("std");
const json = @import("json");

pub const max_resource_id_bytes: usize = 32;
pub const max_resource_name_bytes: usize = 128;
pub const max_resource_mime_bytes: usize = 128;
pub const max_resource_count: usize = 128;

pub const Error = error{
    ResourceLimitReached,
    ResourceNotFound,
    ResourceExpired,
    ResourceOriginMismatch,
    ResourceWindowMismatch,
    InvalidResourceMetadata,
    NoSpaceLeft,
};

pub const Options = struct {
    mime: []const u8 = "application/octet-stream",
    name: []const u8 = "",
    origin: []const u8 = "",
    window_id: u64 = 0,
    ttl_ns: ?i128 = null,
    one_shot: bool = false,
};

pub const Descriptor = struct {
    id: []const u8,
    url: []const u8,
    mime: []const u8,
    name: []const u8 = "",
    size: usize,
    one_shot: bool = false,
};

const Entry = struct {
    id: []u8,
    url: []u8,
    bytes: []u8,
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
            .size = self.bytes.len,
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
            .bytes = owned_bytes,
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

    pub fn fetchBytes(self: *Registry, id: []const u8, source: Source, now_ns: i128) ![]const u8 {
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
        const bytes = entry.bytes;
        if (entry.one_shot) _ = self.entries.orderedRemove(index);
        return bytes;
    }

    pub fn revoke(self: *Registry, id: []const u8) bool {
        const index = self.findIndex(id) orelse return false;
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

    fn freeEntry(self: *Registry, entry: Entry) void {
        self.allocator.free(entry.id);
        self.allocator.free(entry.url);
        self.allocator.free(entry.bytes);
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
    try writer.print(",\"size\":{d}", .{descriptor.size});
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
    try std.testing.expect(std.mem.startsWith(u8, descriptor.url, "zero://native/resource/"));

    var output: [512]u8 = undefined;
    const json_bytes = try writeDescriptorJson(&output, descriptor);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"kind\":\"resource\"") != null);

    const bytes = try registry.fetchBytes(descriptor.id, .{ .origin = "zero://app", .window_id = 1 }, 101);
    try std.testing.expectEqualStrings("hello", bytes);
}

test "resource registry enforces origin and expiration" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const descriptor = try registry.registerBytes("secret", .{ .origin = "zero://app", .ttl_ns = 10 }, 100);
    try std.testing.expectError(error.ResourceOriginMismatch, registry.fetchBytes(descriptor.id, .{ .origin = "https://example.com" }, 101));
    try std.testing.expectError(error.ResourceExpired, registry.fetchBytes(descriptor.id, .{ .origin = "zero://app" }, 111));
}
