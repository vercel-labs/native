//! Lossless JSON-to-ZON syntax adapter for app manifests. JSON is the
//! authoring format; generated/ejected Zig build graphs feed this equivalent
//! module to the existing comptime runner so both syntaxes have one runtime
//! feature implementation.

const std = @import("std");

pub fn convertAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Keep numeric tokens as authored. Parsing through f64 first can round a
    // valid u64 manifest value before the generated ZON module sees it.
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), source, .{ .parse_numbers = false });
    if (root != .object) return error.ExpectedObject;
    try validateValue(root);

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try writeValue(&out.writer, root, 0);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn validateSource(allocator: std.mem.Allocator, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), source, .{ .parse_numbers = false });
    if (root != .object) return error.ExpectedObject;
    try validateValue(root);
}

pub fn isJsonPath(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".json");
}

fn validateValue(value: std.json.Value) !void {
    switch (value) {
        .null => return error.NullNotAllowed,
        .array => |array| for (array.items) |item| try validateValue(item),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| try validateValue(entry.value_ptr.*);
        },
        else => {},
    }
}

fn writeValue(writer: *std.Io.Writer, value: std.json.Value, depth: usize) !void {
    switch (value) {
        .null => return error.NullNotAllowed,
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writer.print("{d}", .{float}),
        .number_string => |number| try writer.writeAll(number),
        .string => |string| try writer.print("\"{f}\"", .{std.zig.fmtString(string)}),
        .array => |array| {
            if (array.items.len == 0) return writer.writeAll(".{}");
            try writer.writeAll(".{\n");
            for (array.items) |item| {
                try indent(writer, depth + 1);
                try writeValue(writer, item, depth + 1);
                try writer.writeAll(",\n");
            }
            try indent(writer, depth);
            try writer.writeByte('}');
        },
        .object => |object| {
            if (object.count() == 0) return writer.writeAll(".{}");
            try writer.writeAll(".{\n");
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                // $schema is editor metadata, not an app runtime field.
                if (depth == 0 and std.mem.eql(u8, entry.key_ptr.*, "$schema")) continue;
                try indent(writer, depth + 1);
                try writer.print(".{f} = ", .{std.zig.fmtId(entry.key_ptr.*)});
                try writeValue(writer, entry.value_ptr.*, depth + 1);
                try writer.writeAll(",\n");
            }
            try indent(writer, depth);
            try writer.writeByte('}');
        },
    }
}

fn indent(writer: *std.Io.Writer, depth: usize) !void {
    try writer.splatByteAll(' ', depth * 4);
}

test "converts a JSON manifest to a Zig manifest module" {
    const converted = try convertAlloc(std.testing.allocator,
        \\{
        \\  "$schema": "https://schema.native-sdk.dev/app/v1.json",
        \\  "id": "dev.example.app",
        \\  "name": "example",
        \\  "version": "1.0.0",
        \\  "dock_visible": true,
        \\  "windows": [{ "label": "main", "width": 480.5 }]
        \\}
    );
    defer std.testing.allocator.free(converted);
    try std.testing.expect(std.mem.indexOf(u8, converted, "$schema") == null);
    try std.testing.expect(std.mem.indexOf(u8, converted, ".id = \"dev.example.app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, ".windows = .{") != null);
}

test "JSON manifests reject explicit null and recognize extension case-insensitively" {
    try std.testing.expectError(error.NullNotAllowed, convertAlloc(std.testing.allocator,
        \\{ "id": "dev.example.app", "name": "example", "version": "1.0.0", "theme": null }
    ));
    try std.testing.expect(isJsonPath("app.json"));
    try std.testing.expect(isJsonPath("config/APP.JSON"));
    try std.testing.expect(!isJsonPath("app.zon"));
}

test "JSON-to-ZON conversion preserves numeric tokens exactly" {
    const converted = try convertAlloc(std.testing.allocator,
        \\{
        \\  "assets": { "images": [{ "id": 9007199254740993.0, "path": "assets/cover.png" }] },
        \\  "frontend": { "dev": { "url": "http://127.0.0.1:5173/", "timeout_ms": 1e3 } }
        \\}
    );
    defer std.testing.allocator.free(converted);
    try std.testing.expect(std.mem.indexOf(u8, converted, ".id = 9007199254740993.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, ".timeout_ms = 1e3") != null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source_z = try arena.allocator().dupeZ(u8, converted);
    const Parsed = struct {
        assets: struct { images: []const struct { id: u64, path: []const u8 } },
        frontend: struct { dev: struct { url: []const u8, timeout_ms: u32 } },
    };
    const parsed = try std.zon.parse.fromSliceAlloc(Parsed, arena.allocator(), source_z, null, .{});
    try std.testing.expectEqual(@as(u64, 9_007_199_254_740_993), parsed.assets.images[0].id);
    try std.testing.expectEqual(@as(u32, 1000), parsed.frontend.dev.timeout_ms);
}
