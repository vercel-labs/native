const std = @import("std");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub fn put(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.cast(u32, value) orelse @panic("glyph atlas integer overflow"), .little);
}
pub fn integer(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
pub fn float(bytes: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(value), .little);
}
pub fn readFloat(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
pub fn resultValid(bytes: []const u8, capacity: usize) bool {
    if (bytes.len < 16) return false;
    const count: usize = word(bytes, 0);
    if (count > capacity or count > (bytes.len - 16) / 32 or bytes.len != 16 + count * 32 or word(bytes, 4) > 1 or word(bytes, 8) != 0 or word(bytes, 12) != 0) return false;
    for (0..count) |i| {
        const at = 16 + i * 32;
        if (word(bytes, at + 16) > 3 or word(bytes, at + 20) > 3) return false;
    }
    return true;
}
test "glyph atlas copied transport bounds counts padding and subpixel values" {
    var bytes: [48]u8 = @splat(0);
    put(&bytes, 0, 1);
    try std.testing.expect(resultValid(&bytes, 1));
    try std.testing.expect(!resultValid(&bytes, 0));
    for ([_]usize{ 0, 4, 8, 12, 32, 36 }) |at| {
        const saved = word(&bytes, at);
        put(&bytes, at, 0xffffffff);
        try std.testing.expect(!resultValid(&bytes, 1));
        put(&bytes, at, saved);
    }
    for (0..48) |length| try std.testing.expect(!resultValid(bytes[0..length], 1));
}
