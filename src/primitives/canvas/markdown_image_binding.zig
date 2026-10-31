//! Convert authored registered-image boundary records without rounding ids.
const std = @import("std");
const markdown = @import("markdown.zig");
const reflect = @import("ui_markup_reflect.zig");

fn number(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => @floatFromInt(value),
        .float => @floatCast(value),
        else => unreachable,
    };
}
fn word(value: anytype, limit: f64) error{InvalidImageIdentity}!u32 {
    const n = number(value);
    if (!std.math.isFinite(n) or n < 0 or n >= limit or @floor(n) != n) return error.InvalidImageIdentity;
    return @intFromFloat(n);
}
fn identity(value: anytype) error{InvalidImageIdentity}!u64 {
    if (comptime @typeInfo(@TypeOf(value)) == .pointer) return identity(value.*);
    const T = reflect.Pointee(@TypeOf(value));
    switch (@typeInfo(T)) {
        .int => return std.math.cast(u64, value) orelse error.InvalidImageIdentity,
        .float => {
            const n = number(value);
            if (!std.math.isFinite(n) or n < 0 or n >= 9007199254740992 or @floor(n) != n) return error.InvalidImageIdentity;
            return @intFromFloat(n);
        },
        .@"struct" => return @as(u64, try word(value.imageLower, 4294967296)) | (@as(u64, try word(value.imageUpper, 2147483648)) << 32),
        else => unreachable,
    }
}
pub fn convert(arena: std.mem.Allocator, items: anytype) ![]const markdown.ResolvedImage {
    const Item = std.meta.Elem(@TypeOf(items));
    if (comptime Item == markdown.ResolvedImage) return items;
    const output = try arena.alloc(markdown.ResolvedImage, items.len);
    for (items, output, 0..) |item, *result, index| result.* = .{
        .source = items[index].source[0..],
        .image = try identity(item.image),
        .width = @floatCast(number(item.width)),
        .height = @floatCast(number(item.height)),
    };
    return output;
}

test "Markdown image boundary accepts pointers and exact words while refusing malformed shapes" {
    const Identity = struct { imageLower: f64, imageUpper: f64 };
    const Item = struct { source: []const u8, image: *const Identity, width: i64, height: f64 };
    try std.testing.expect(reflect.isMarkdownImageItem(*const Item));
    const BadIdentity = struct { imageLower: bool, imageUpper: f64 };
    const Bad = struct { source: []const u8, image: BadIdentity, width: i64, height: f64 };
    try std.testing.expect(!reflect.isMarkdownImageItem(Bad));
    try std.testing.expect(!reflect.isMarkdownImageItem(struct { image: Identity, width: i64, height: f64 }));
    const id: Identity = .{ .imageLower = 4294967295, .imageUpper = 2147483647 };
    const item: Item = .{ .source = "source\x00\xff", .image = &id, .width = 9, .height = 7.25 };
    const items = [_]*const Item{&item};
    const result = try convert(std.testing.allocator, items[0..]);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(u64, 0x7fff_ffff_ffff_ffff), result[0].image);
    try std.testing.expectEqualStrings(item.source, result[0].source);
    try std.testing.expectEqual(@as(f32, 9), result[0].width);
    try std.testing.expectEqual(@as(f32, 7.25), result[0].height);
    for ([_]Identity{
        .{ .imageLower = -1, .imageUpper = 0 }, .{ .imageLower = 4294967296, .imageUpper = 0 },
        .{ .imageLower = 0.5, .imageUpper = 0 }, .{ .imageLower = 0, .imageUpper = 2147483648 },
        .{ .imageLower = std.math.nan(f64), .imageUpper = 0 }, .{ .imageLower = 0, .imageUpper = std.math.inf(f64) },
    }) |bad| try std.testing.expectError(error.InvalidImageIdentity, identity(bad));
    try std.testing.expectError(error.InvalidImageIdentity, identity(@as(f64, 9007199254740992)));
    try std.testing.expectEqual(@as(u64, 9007199254740991), try identity(@as(f64, 9007199254740991)));
    const native = [_]markdown.ResolvedImage{.{ .source = "native", .image = 0xffff_ffff_ffff_ffff, .width = 2, .height = 3 }};
    const passthrough = try convert(std.testing.allocator, native[0..]);
    try std.testing.expectEqual(native[0].image, passthrough[0].image);
    try std.testing.expectEqual(native[0..].ptr, passthrough.ptr);
    const scalar: u64 = 0x7fff_ffff_ffff_ffff;
    const ScalarItem = struct { source: [3]u8, image: *const u64, width: f32, height: f32 };
    try std.testing.expect(reflect.isMarkdownImageItem(ScalarItem));
    const scalars = [_]ScalarItem{.{ .source = .{ 'p', 0, 255 }, .image = &scalar, .width = 2, .height = 3 }};
    const converted = try convert(std.testing.allocator, scalars[0..]);
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqual(scalar, converted[0].image);
    try std.testing.expectEqualStrings("p\x00\xff", converted[0].source);
}
