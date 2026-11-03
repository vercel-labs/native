//! Windows keyboard synthesis: SendInput with virtual keys for chords.
const std = @import("std");
const types = @import("../types.zig");
const key_codes = @import("key_codes.zig");

const input_keyboard: u32 = 1;
const keyeventf_extendedkey: u32 = 0x0001;
const keyeventf_keyup: u32 = 0x0002;

const vk_shift: u16 = 0x10;
const vk_control: u16 = 0x11;
const vk_menu: u16 = 0x12;
const vk_lwin: u16 = 0x5B;
const vk_rwin: u16 = 0x5C;
const vk_mask: u16 = 0xE8;

const modifier_groups = [_][3]u16{
    .{ vk_control, 0xA2, 0xA3 },
    .{ vk_menu, 0xA4, 0xA5 },
    .{ vk_shift, 0xA0, 0xA1 },
    .{ vk_lwin, vk_lwin, vk_rwin },
};

const max_inputs = 2 * (2 + 2 * modifier_groups.len) + 2;

const KeyboardInput = extern struct {
    virtual_key: u16,
    scan: u16,
    flags: u32,
    time: u32 = 0,
    extra_info: usize = 0,
};

const Input = extern struct {
    kind: u32 = input_keyboard,
    keyboard: KeyboardInput,
    mouse_input_padding: [8]u8 = @splat(0),
};

extern "user32" fn SendInput(count: u32, inputs: [*]const Input, size: c_int) callconv(.winapi) u32;
extern "user32" fn GetAsyncKeyState(vk: c_int) callconv(.winapi) i16;
extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) callconv(.winapi) u32;

pub fn sendKeyChord(_: ?*anyopaque, chord: types.KeyChord) anyerror!void {
    const key = key_codes.virtualKey(chord.key()) orelse return error.KeyboardInputFailed;
    var held: [modifier_groups.len][2]bool = undefined;
    for (modifier_groups, &held) |group, *sides| sides.* = .{ GetAsyncKeyState(group[1]) < 0, GetAsyncKeyState(group[2]) < 0 };
    var inputs: [max_inputs]Input = undefined;
    const count = chordInputs(chord.modifiers, key, held, &inputs);
    for (inputs[0..count]) |*input| input.keyboard.scan = @truncate(MapVirtualKeyW(input.keyboard.virtual_key, 0));
    const sent: usize = SendInput(@intCast(count), &inputs, @sizeOf(Input));
    if (sent == count) return;
    const tail = @min(sent, count - sent);
    if (tail > 0) _ = SendInput(@intCast(tail), inputs[count - tail ..].ptr, @sizeOf(Input));
    return error.KeyboardInputBlocked;
}

pub fn access(_: ?*anyopaque, _: bool) anyerror!types.KeyboardInputAccess {
    return .not_required;
}

/// Lifts held modifiers the chord lacks, presses missing chord modifiers, taps the key, then mirrors every step in reverse.
/// A lifted Alt or Win gets a mask tap on both ends so neither the synthetic nor the user's later release opens a menu.
fn chordInputs(modifiers: types.ShortcutModifiers, key: u16, held: [modifier_groups.len][2]bool, inputs: *[max_inputs]Input) usize {
    const wanted = [modifier_groups.len]bool{ modifiers.primary or modifiers.control, modifiers.option, modifiers.shift, modifiers.command };
    var half: usize = 0;
    if ((!wanted[1] and (held[1][0] or held[1][1])) or (!wanted[3] and (held[3][0] or held[3][1]))) {
        inputs[0] = virtualKeyInput(vk_mask, false);
        inputs[1] = virtualKeyInput(vk_mask, true);
        half = 2;
    }
    for (modifier_groups, wanted, held) |group, want, sides| {
        if (want) continue;
        for (sides, group[1..]) |down, vk| {
            if (!down) continue;
            inputs[half] = virtualKeyInput(vk, true);
            half += 1;
        }
    }
    for (modifier_groups, wanted, held) |group, want, sides| {
        if (!want or sides[0] or sides[1]) continue;
        inputs[half] = virtualKeyInput(group[0], false);
        half += 1;
    }
    const count = 2 * half + 2;
    inputs[half] = virtualKeyInput(key, false);
    inputs[half + 1] = virtualKeyInput(key, true);
    for (0..half) |i| {
        inputs[count - 1 - i] = inputs[i];
        inputs[count - 1 - i].keyboard.flags ^= keyeventf_keyup;
    }
    return count;
}

fn virtualKeyInput(vk: u16, key_up: bool) Input {
    const extended = switch (vk) {
        0x21...0x28, 0x2D, 0x2E, 0xA3, 0xA5, vk_lwin, vk_rwin => true,
        else => false,
    };
    return .{ .keyboard = .{
        .virtual_key = vk,
        .scan = 0,
        .flags = (if (key_up) keyeventf_keyup else 0) | (if (extended) keyeventf_extendedkey else 0),
    } };
}

test "input records match the Win32 INPUT layout" {
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 40 else 28), @sizeOf(Input));
    try std.testing.expectEqual(@as(usize, @sizeOf(usize)), @offsetOf(Input, "keyboard"));
}

test "chord inputs lift stray held modifiers, keep held chord modifiers, and mask a lifted Alt on both ends" {
    const v: u16 = 0x56;
    const cases = [_]struct { types.ShortcutModifiers, [modifier_groups.len][2]bool, []const struct { u16, bool } }{
        .{ .{ .primary = true }, @splat(.{ false, false }), &.{ .{ 0x11, false }, .{ v, false }, .{ v, true }, .{ 0x11, true } } },
        .{ .{ .primary = true }, .{ .{ true, false }, .{ false, false }, .{ false, false }, .{ false, false } }, &.{ .{ v, false }, .{ v, true } } },
        .{ .{ .primary = true }, .{ .{ false, false }, .{ false, false }, .{ false, true }, .{ false, false } }, &.{ .{ 0xA1, true }, .{ 0x11, false }, .{ v, false }, .{ v, true }, .{ 0x11, true }, .{ 0xA1, false } } },
        .{ .{ .primary = true }, .{ .{ false, false }, .{ true, false }, .{ false, false }, .{ false, false } }, &.{ .{ vk_mask, false }, .{ vk_mask, true }, .{ 0xA4, true }, .{ 0x11, false }, .{ v, false }, .{ v, true }, .{ 0x11, true }, .{ 0xA4, false }, .{ vk_mask, false }, .{ vk_mask, true } } },
        .{ .{ .command = true }, .{ .{ false, false }, .{ false, false }, .{ false, false }, .{ false, true } }, &.{ .{ v, false }, .{ v, true } } },
    };
    for (cases) |case| {
        var inputs: [max_inputs]Input = undefined;
        const count = chordInputs(case[0], v, case[1], &inputs);
        try std.testing.expectEqual(case[2].len, count);
        for (case[2], inputs[0..count]) |want, got| {
            try std.testing.expectEqual(want[0], got.keyboard.virtual_key);
            try std.testing.expectEqual(want[1], got.keyboard.flags & keyeventf_keyup != 0);
        }
    }
    var inputs: [max_inputs]Input = undefined;
    try std.testing.expectEqual(@as(usize, max_inputs), chordInputs(.{}, v, @splat(.{ true, true }), &inputs));
}
