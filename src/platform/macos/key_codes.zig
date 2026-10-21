//! Maps shortcut key names to macOS virtual key codes.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");

const hitoolbox_path = "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox";
const ansi_characters = "asdfhgzxcv\x00bqweryt123465=97-80]ou[ip\x00lj'k;\\,/nm.\x00\x00`";

const named = [_]struct { []const u8, u16 }{
    .{ "enter", 0x24 },    .{ "tab", 0x30 },       .{ "space", 0x31 },      .{ "backspace", 0x33 }, .{ "escape", 0x35 },
    .{ "insert", 0x72 },   .{ "home", 0x73 },      .{ "pageup", 0x74 },     .{ "delete", 0x75 },    .{ "end", 0x77 },
    .{ "pagedown", 0x79 }, .{ "arrowleft", 0x7B }, .{ "arrowright", 0x7C }, .{ "arrowdown", 0x7D }, .{ "arrowup", 0x7E },
    .{ "f1", 0x7A },       .{ "f2", 0x78 },        .{ "f3", 0x63 },         .{ "f4", 0x76 },        .{ "f5", 0x60 },
    .{ "f6", 0x61 },       .{ "f7", 0x62 },        .{ "f8", 0x64 },         .{ "f9", 0x65 },        .{ "f10", 0x6D },
    .{ "f11", 0x67 },      .{ "f12", 0x6F },
};

const Ref = ?*anyopaque;
const CopySource = *const fn () callconv(.c) Ref;
const GetProperty = *const fn (*anyopaque, Ref) callconv(.c) ?*const anyopaque;
const GetBytes = *const fn (*const anyopaque) callconv(.c) ?*const anyopaque;
const Release = *const fn (*anyopaque) callconv(.c) void;
const Translate = *const fn (*const anyopaque, u16, u16, u32, u32, u32, *u32, usize, *usize, [*]u16) callconv(.c) i32;

/// Returns the virtual key code for a shortcut key name, resolving single characters through the current layout with the Command key state when `command` is set.
pub fn keyCode(key: []const u8, command: bool) ?u16 {
    if (key.len == 1) {
        if (layoutKeyCode(std.ascii.toLower(key[0]), if (command) 1 else 0)) |code| return code;
    }
    return ansiKeyCode(key);
}

fn ansiKeyCode(key: []const u8) ?u16 {
    if (key.len == 1) {
        const ch = std.ascii.toLower(key[0]);
        if (ch == 0) return null;
        return @intCast(std.mem.indexOfScalar(u8, ansi_characters, ch) orelse return null);
    }
    for (named) |entry| {
        if (std.ascii.eqlIgnoreCase(key, entry[0])) return entry[1];
    }
    return null;
}

fn symbol(library: *anyopaque, name: [*:0]const u8, comptime T: type) ?T {
    return @ptrCast(@alignCast(std.c.dlsym(library, name) orelse return null));
}

fn layoutKeyCode(character: u8, modifier_state: u32) ?u16 {
    if (comptime builtin.os.tag != .macos) return null;
    const library = std.c.dlopen(hitoolbox_path, .{ .LAZY = true }) orelse return null;
    defer _ = std.c.dlclose(library);
    const copy_current = symbol(library, "TISCopyCurrentKeyboardLayoutInputSource", CopySource) orelse return null;
    const copy_ascii = symbol(library, "TISCopyCurrentASCIICapableKeyboardLayoutInputSource", CopySource) orelse return null;
    const get_property = symbol(library, "TISGetInputSourceProperty", GetProperty) orelse return null;
    const layout_property = symbol(library, "kTISPropertyUnicodeKeyLayoutData", *const Ref) orelse return null;
    const keyboard_type = symbol(library, "LMGetKbdType", *const fn () callconv(.c) u8) orelse return null;
    const translate = symbol(library, "UCKeyTranslate", Translate) orelse return null;
    const get_bytes = symbol(library, "CFDataGetBytePtr", GetBytes) orelse return null;
    const release = symbol(library, "CFRelease", Release) orelse return null;
    for ([_]CopySource{ copy_current, copy_ascii }) |copy| {
        const source = copy() orelse continue;
        defer release(source);
        const data = get_property(source, layout_property.*) orelse continue;
        const layout = get_bytes(data) orelse continue;
        for (0..128) |code| {
            var dead_keys: u32 = 0;
            var chars: [4]u16 = undefined;
            var len: usize = 0;
            if (translate(layout, @intCast(code), 3, modifier_state, keyboard_type(), 1, &dead_keys, chars.len, &len, &chars) == 0 and
                len == 1 and chars[0] < 128 and std.ascii.toLower(@intCast(chars[0])) == character) return @intCast(code);
        }
    }
    return null;
}

test "every valid shortcut key has a distinct ANSI key code" {
    var seen = [_]bool{false} ** 256;
    var count: usize = 0;
    var ch: u8 = 0;
    while (true) : (ch += 1) {
        if (types.isValidShortcutKey(&.{ch})) {
            const code = ansiKeyCode(&.{ch}).?;
            if (std.ascii.isUpper(ch)) {
                try std.testing.expectEqual(ansiKeyCode(&.{std.ascii.toLower(ch)}).?, code);
            } else {
                try std.testing.expect(!seen[code]);
                seen[code] = true;
                count += 1;
            }
        }
        if (ch == 255) break;
    }
    for (named) |entry| {
        try std.testing.expect(types.isValidShortcutKey(entry[0]));
        try std.testing.expectEqual(entry[1], keyCode(entry[0], false).?);
        try std.testing.expect(!seen[ansiKeyCode(entry[0]).?]);
        seen[entry[1]] = true;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 26 + 10 + 11 + 27), count);
}
