//! Maps shortcut key names to Windows virtual-key codes.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");

const punctuation = "=-,./;'[]\\`";
const punctuation_codes = [_]u16{ 0xBB, 0xBD, 0xBC, 0xBE, 0xBF, 0xBA, 0xDE, 0xDB, 0xDD, 0xDC, 0xC0 };

const named = [_]struct { []const u8, u16 }{
    .{ "escape", 0x1B },    .{ "enter", 0x0D },   .{ "tab", 0x09 },        .{ "space", 0x20 },     .{ "backspace", 0x08 },
    .{ "arrowleft", 0x25 }, .{ "arrowup", 0x26 }, .{ "arrowright", 0x27 }, .{ "arrowdown", 0x28 }, .{ "delete", 0x2E },
    .{ "home", 0x24 },      .{ "end", 0x23 },     .{ "pageup", 0x21 },     .{ "pagedown", 0x22 },  .{ "insert", 0x2D },
    .{ "f1", 0x70 },        .{ "f2", 0x71 },      .{ "f3", 0x72 },         .{ "f4", 0x73 },        .{ "f5", 0x74 },
    .{ "f6", 0x75 },        .{ "f7", 0x76 },      .{ "f8", 0x77 },         .{ "f9", 0x78 },        .{ "f10", 0x79 },
    .{ "f11", 0x7A },       .{ "f12", 0x7B },
};

extern "user32" fn VkKeyScanW(ch: u16) callconv(.winapi) i16;

/// Returns the Windows virtual-key code for a shortcut key name; punctuation resolves through the active layout on Windows.
pub fn virtualKey(key: []const u8) ?u16 {
    if (comptime builtin.os.tag == .windows) {
        if (key.len == 1 and std.mem.indexOfScalar(u8, punctuation, key[0]) != null) {
            const scan = VkKeyScanW(key[0]);
            if (scan != -1 and scan >> 8 == 0) return @intCast(scan & 0xFF);
        }
    }
    return tableKey(key);
}

fn tableKey(key: []const u8) ?u16 {
    if (key.len == 1) {
        const ch = std.ascii.toUpper(key[0]);
        if (std.ascii.isAlphanumeric(ch)) return ch;
        return punctuation_codes[std.mem.indexOfScalar(u8, punctuation, ch) orelse return null];
    }
    for (named) |entry| {
        if (std.ascii.eqlIgnoreCase(key, entry[0])) return entry[1];
    }
    return null;
}

test "every valid shortcut key has a distinct virtual key" {
    var seen = [_]bool{false} ** 256;
    var count: usize = 0;
    var ch: u8 = 0;
    while (true) : (ch += 1) {
        if (types.isValidShortcutKey(&.{ch}) and !std.ascii.isUpper(ch)) {
            const code = tableKey(&.{ch}).?;
            try std.testing.expect(!seen[code]);
            seen[code] = true;
            count += 1;
        }
        if (ch == 255) break;
    }
    for (named) |entry| {
        try std.testing.expect(types.isValidShortcutKey(entry[0]));
        try std.testing.expect(!seen[tableKey(entry[0]).?]);
        seen[entry[1]] = true;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 26 + 10 + 11 + 27), count);
}
