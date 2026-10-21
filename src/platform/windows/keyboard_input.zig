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
    const modifiers = modifierKeys(chord.modifiers);
    var inputs: [20]Input = undefined;
    var half: usize = 0;
    for ([_][3]u16{ modifier_groups[1], modifier_groups[3] }) |group| {
        if (std.mem.indexOfScalar(u16, modifiers.keys[0..modifiers.len], group[0]) == null and (GetAsyncKeyState(group[1]) < 0 or GetAsyncKeyState(group[2]) < 0)) {
            inputs[0] = virtualKeyInput(vk_mask, false);
            half = 1;
        }
    }
    for (modifier_groups) |group| {
        const left = GetAsyncKeyState(group[1]) < 0;
        const right = GetAsyncKeyState(group[2]) < 0;
        if (std.mem.indexOfScalar(u16, modifiers.keys[0..modifiers.len], group[0]) != null) {
            if (left or right) continue;
            inputs[half] = virtualKeyInput(group[0], false);
            half += 1;
            continue;
        }
        for ([_]struct { bool, u16 }{ .{ left, group[1] }, .{ right, group[2] } }) |side| {
            if (!side[0]) continue;
            inputs[half] = virtualKeyInput(side[1], true);
            half += 1;
        }
    }
    const count = 2 * half + 2;
    inputs[half] = virtualKeyInput(key, false);
    inputs[half + 1] = virtualKeyInput(key, true);
    for (0..half) |i| {
        inputs[count - 1 - i] = inputs[i];
        inputs[count - 1 - i].keyboard.flags ^= keyeventf_keyup;
    }
    const sent: usize = SendInput(@intCast(count), &inputs, @sizeOf(Input));
    if (sent == count) return;
    const tail = @min(sent, count - sent);
    if (tail > 0) _ = SendInput(@intCast(tail), inputs[count - tail ..].ptr, @sizeOf(Input));
    return error.KeyboardInputBlocked;
}

pub fn access(_: ?*anyopaque, _: bool) anyerror!types.KeyboardInputAccess {
    return .not_required;
}

const ModifierKeys = struct {
    keys: [4]u16 = undefined,
    len: usize = 0,
};

fn modifierKeys(modifiers: types.ShortcutModifiers) ModifierKeys {
    var result: ModifierKeys = .{};
    for ([_]struct { bool, u16 }{
        .{ modifiers.primary or modifiers.control, vk_control },
        .{ modifiers.option, vk_menu },
        .{ modifiers.shift, vk_shift },
        .{ modifiers.command, vk_lwin },
    }) |entry| {
        if (!entry[0]) continue;
        result.keys[result.len] = entry[1];
        result.len += 1;
    }
    return result;
}

fn virtualKeyInput(vk: u16, key_up: bool) Input {
    const extended = switch (vk) {
        0x21...0x28, 0x2D, 0x2E, 0xA3, 0xA5, vk_lwin, vk_rwin => true,
        else => false,
    };
    return .{ .keyboard = .{
        .virtual_key = vk,
        .scan = @truncate(MapVirtualKeyW(vk, 0)),
        .flags = (if (key_up) keyeventf_keyup else 0) | (if (extended) keyeventf_extendedkey else 0),
    } };
}

test "input records match the Win32 INPUT layout" {
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 40 else 28), @sizeOf(Input));
    try std.testing.expectEqual(@as(usize, @sizeOf(usize)), @offsetOf(Input, "keyboard"));
}
