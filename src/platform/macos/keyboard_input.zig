//! macOS keyboard synthesis: CGEventPost for chords, gated by the Accessibility grant.
const std = @import("std");
const types = @import("../types.zig");
const key_codes = @import("key_codes.zig");

const CFStringRef = *const anyopaque;
const CFDictionaryRef = *const anyopaque;
const CGEventRef = *anyopaque;
const CGEventSourceRef = *anyopaque;

extern fn CFRelease(object: *const anyopaque) void;
extern fn CFDictionaryCreate(allocator: ?*const anyopaque, keys: [*]const ?*const anyopaque, values: [*]const ?*const anyopaque, count: isize, key_callbacks: *const anyopaque, value_callbacks: *const anyopaque) ?CFDictionaryRef;
extern const kCFBooleanTrue: *const anyopaque;
extern const kCFTypeDictionaryKeyCallBacks: [6]usize;
extern const kCFTypeDictionaryValueCallBacks: [5]usize;

extern fn CGEventSourceCreate(state_id: i32) ?CGEventSourceRef;
extern fn CGEventCreateKeyboardEvent(source: ?CGEventSourceRef, virtual_key: u16, key_down: bool) ?CGEventRef;
extern fn CGEventSetFlags(event: CGEventRef, flags: u64) void;
extern fn CGEventPost(tap: u32, event: CGEventRef) void;

extern fn AXIsProcessTrusted() u8;
extern fn AXIsProcessTrustedWithOptions(options: ?CFDictionaryRef) u8;
extern const kAXTrustedCheckOptionPrompt: CFStringRef;

const event_source_combined_session: i32 = 0;
const hid_event_tap: u32 = 0;

const flag_shift: u64 = 0x0002_0000;
const flag_control: u64 = 0x0004_0000;
const flag_option: u64 = 0x0008_0000;
const flag_command: u64 = 0x0010_0000;
const flag_numeric_pad: u64 = 0x0020_0000;
const flag_function: u64 = 0x0080_0000;

pub fn sendKeyChord(_: ?*anyopaque, chord: types.KeyChord) anyerror!void {
    if (AXIsProcessTrusted() == 0) return error.KeyboardInputAccessDenied;
    const key_code = key_codes.keyCode(chord.key(), chord.modifiers.command or chord.modifiers.primary) orelse return error.KeyboardInputFailed;
    const source = CGEventSourceCreate(event_source_combined_session);
    defer if (source) |value| CFRelease(value);
    const down = CGEventCreateKeyboardEvent(source, key_code, true) orelse return error.KeyboardInputFailed;
    defer CFRelease(down);
    const up = CGEventCreateKeyboardEvent(source, key_code, false) orelse return error.KeyboardInputFailed;
    defer CFRelease(up);
    const flags = eventFlags(chord);
    CGEventSetFlags(down, flags);
    CGEventSetFlags(up, flags);
    CGEventPost(hid_event_tap, down);
    CGEventPost(hid_event_tap, up);
}

pub fn access(_: ?*anyopaque, prompt: bool) anyerror!types.KeyboardInputAccess {
    const trusted = if (prompt) trustedWithPrompt() else AXIsProcessTrusted() != 0;
    return if (trusted) .granted else .denied;
}

fn trustedWithPrompt() bool {
    const keys = [_]?*const anyopaque{kAXTrustedCheckOptionPrompt};
    const values = [_]?*const anyopaque{kCFBooleanTrue};
    const options = CFDictionaryCreate(null, &keys, &values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse
        return AXIsProcessTrusted() != 0;
    defer CFRelease(options);
    return AXIsProcessTrustedWithOptions(options) != 0;
}

fn eventFlags(chord: types.KeyChord) u64 {
    var flags: u64 = 0;
    if (chord.modifiers.primary or chord.modifiers.command) flags |= flag_command;
    if (chord.modifiers.control) flags |= flag_control;
    if (chord.modifiers.option) flags |= flag_option;
    if (chord.modifiers.shift) flags |= flag_shift;
    const name = chord.key();
    if (std.mem.startsWith(u8, name, "arrow")) {
        flags |= flag_numeric_pad | flag_function;
    } else if (name.len > 1 and name[0] == 'f' and std.ascii.isDigit(name[1])) {
        flags |= flag_function;
    } else for ([_][]const u8{ "home", "end", "pageup", "pagedown", "delete", "insert" }) |entry| {
        if (std.mem.eql(u8, name, entry)) flags |= flag_function;
    }
    return flags;
}
