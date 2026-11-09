//! Keyboard input shared by every host: the parsed key vocabulary, chords, and access status.
const std = @import("std");
const types = @import("types.zig");

/// One key press, posted as key down then key up with exactly these modifiers.
pub const KeyChord = struct {
    name: [types.max_shortcut_key_bytes]u8 = @splat(0),
    name_len: u8 = 0,
    modifiers: types.ShortcutModifiers = .{},

    /// Builds a chord from a shortcut-vocabulary key name, lowercased; null for any name `isValidShortcutKey` rejects.
    pub fn init(key_name: []const u8, modifiers: types.ShortcutModifiers) ?KeyChord {
        if (!types.isValidShortcutKey(key_name)) return null;
        var chord: KeyChord = .{ .name_len = @intCast(key_name.len), .modifiers = modifiers };
        _ = std.ascii.lowerString(&chord.name, key_name);
        return chord;
    }

    pub fn key(self: *const KeyChord) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Whether the OS delivers input this process synthesizes; `not_required` means no grant exists to ask for.
pub const Access = enum { granted, denied, not_required };

test "chords keep the lowercased shortcut key and reject other names" {
    try std.testing.expectEqualStrings("arrowleft", KeyChord.init("ArrowLeft", .{}).?.key());
    for ([_][]const u8{ "", "f13", "ctrl", "vv", " ", "arrowleft " }) |name| {
        try std.testing.expectEqual(@as(?KeyChord, null), KeyChord.init(name, .{}));
    }
}
