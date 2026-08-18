//! Lossless JSON-to-ZON syntax adapter for app manifests. JSON is the
//! authoring format; generated/ejected Zig build graphs feed this equivalent
//! module to the existing comptime runner so both syntaxes have one runtime
//! feature implementation.

const std = @import("std");

pub fn convertAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), source, .{});
    if (root != .object) return error.ExpectedObject;

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try writeValue(&out.writer, root, 0);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn writeValue(writer: *std.Io.Writer, value: std.json.Value, depth: usize) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
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

test "converts the complete JSON value vocabulary to a Zig manifest module" {
    const converted = try convertAlloc(std.testing.allocator,
        \\{
        \\  "$schema": "https://native-sdk.dev/schemas/app.schema.json",
        \\  "id": "dev.example.app",
        \\  "name": "example",
        \\  "version": "1.0.0",
        \\  "dock_visible": true,
        \\  "windows": [{ "label": "main", "width": 480.5 }],
        \\  "frontend": null
        \\}
    );
    defer std.testing.allocator.free(converted);
    try std.testing.expect(std.mem.indexOf(u8, converted, "$schema") == null);
    try std.testing.expect(std.mem.indexOf(u8, converted, ".id = \"dev.example.app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, ".windows = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, ".frontend = null") != null);
}
