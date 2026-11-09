//! System-wide shortcuts through `RegisterHotKey` on a message-only window.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const key_codes = @import("key_codes.zig");

const HWND = ?*anyopaque;
const WindowProc = *const fn (HWND, c_uint, usize, isize) callconv(.winapi) isize;
const WindowClass = extern struct {
    size: c_uint = @sizeOf(WindowClass),
    style: c_uint = 0,
    proc: WindowProc,
    class_extra: c_int = 0,
    window_extra: c_int = 0,
    instance: ?*anyopaque,
    icon: ?*anyopaque = null,
    cursor: ?*anyopaque = null,
    background: ?*anyopaque = null,
    menu_name: ?[*:0]const u16 = null,
    class_name: [*:0]const u16,
    small_icon: ?*anyopaque = null,
};

const wm_hotkey: c_uint = 0x0312;
const wm_timer: c_uint = 0x0113;
const user_data: c_int = -21;
const poll_timer: usize = 1;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("NativeSdkGlobalShortcuts");

extern "user32" fn RegisterClassExW(class: *const WindowClass) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, name: ?[*:0]const u16, style: u32, x: c_int, y: c_int, width: c_int, height: c_int, parent: HWND, menu: ?*anyopaque, instance: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) c_int;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: c_uint, wparam: usize, lparam: isize) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: c_int, value: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) isize;
extern "user32" fn RegisterHotKey(hwnd: HWND, id: c_int, modifiers: c_uint, vk: c_uint) callconv(.winapi) c_int;
extern "user32" fn UnregisterHotKey(hwnd: HWND, id: c_int) callconv(.winapi) c_int;
extern "user32" fn SetTimer(hwnd: HWND, id: usize, elapse_ms: c_uint, callback: ?*const anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hwnd: HWND, id: usize) callconv(.winapi) c_int;
extern "user32" fn GetAsyncKeyState(vk: c_int) callconv(.winapi) i16;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub fn available() bool {
    return builtin.os.tag == .windows and !builtin.is_test;
}

const Entry = struct {
    binding: types.OwnedShortcut,
    id: c_int = 0,
    vk: c_uint = 0,
    registered: bool = false,
    pressed: bool = false,
};

pub const Registry = struct {
    entries: [types.max_global_shortcuts]Entry = undefined,
    count: usize = 0,
    sink: types.GlobalShortcutSink = .{},
    hwnd: HWND = null,
    polling: bool = false,
    next_id: c_int = 0,

    pub fn configure(self: *Registry, shortcuts: []const types.Shortcut, sink: types.GlobalShortcutSink, statuses: []types.GlobalShortcutStatus) !void {
        if (comptime !available()) return error.UnsupportedService;
        self.sink = sink;
        if (self.hwnd == null) {
            const instance = GetModuleHandleW(null);
            _ = RegisterClassExW(&.{ .proc = windowProc, .instance = instance, .class_name = class_name });
            self.hwnd = CreateWindowExW(0, class_name, null, 0, 0, 0, 0, 0, @ptrFromInt(@as(usize, @bitCast(@as(isize, -3)))), null, instance, null) orelse return error.UnsupportedService;
            _ = SetWindowLongPtrW(self.hwnd, user_data, @bitCast(@intFromPtr(self)));
        }
        for (self.entries[0..self.count]) |*entry| {
            for (shortcuts) |shortcut| {
                if (entry.binding.matches(shortcut)) break;
            } else self.retire(entry);
        }
        var next: [types.max_global_shortcuts]Entry = undefined;
        var count: usize = 0;
        for (shortcuts, statuses) |shortcut, *status| {
            status.* = .registered;
            for (self.entries[0..self.count]) |*entry| {
                if (entry.registered and entry.binding.matches(shortcut)) {
                    next[count] = entry.*;
                    entry.registered = false;
                    break;
                }
            } else {
                self.next_id = @mod(self.next_id, 0xBFFF) + 1;
                const vk = key_codes.virtualKey(shortcut.key) orelse {
                    status.* = .rejected;
                    continue;
                };
                next[count] = .{ .binding = .init(shortcut), .id = self.next_id, .vk = vk, .registered = true };
                if (RegisterHotKey(self.hwnd, self.next_id, modifierMask(shortcut.modifiers), vk) == 0) {
                    status.* = if (GetLastError() == 1409) .conflict else .rejected;
                    continue;
                }
            }
            count += 1;
        }
        @memcpy(self.entries[0..count], next[0..count]);
        self.count = count;
        self.updatePolling();
    }

    pub fn deinit(self: *Registry) void {
        if (comptime !available()) return;
        for (self.entries[0..self.count]) |*entry| self.retire(entry);
        self.count = 0;
        self.updatePolling();
        if (self.hwnd != null) _ = DestroyWindow(self.hwnd);
        self.hwnd = null;
    }

    fn retire(self: *Registry, entry: *Entry) void {
        if (entry.pressed) self.sink.push(.{ .shortcut = entry.binding.shortcut(), .phase = .released });
        entry.pressed = false;
        if (entry.registered) _ = UnregisterHotKey(self.hwnd, entry.id);
        entry.registered = false;
    }

    fn update(self: *Registry, hot_key: ?c_int) void {
        for (self.entries[0..self.count]) |*entry| {
            const repeated = if (hot_key) |id| entry.id == id and entry.pressed else false;
            if (repeated) self.sink.push(.{ .shortcut = entry.binding.shortcut(), .phase = .released });
            const pressing = if (hot_key) |id| entry.id == id or entry.pressed else entry.pressed and GetAsyncKeyState(@intCast(entry.vk)) < 0;
            if (pressing == entry.pressed and !repeated) continue;
            entry.pressed = pressing;
            self.sink.push(.{ .shortcut = entry.binding.shortcut(), .phase = if (pressing) .pressed else .released });
        }
        self.updatePolling();
    }

    fn updatePolling(self: *Registry) void {
        var held = false;
        for (self.entries[0..self.count]) |entry| held = held or entry.pressed;
        if (held and !self.polling) self.polling = SetTimer(self.hwnd, poll_timer, 10, null) != 0;
        if (!held and self.polling) {
            _ = KillTimer(self.hwnd, poll_timer);
            self.polling = false;
        }
    }
};

fn windowProc(hwnd: HWND, msg: c_uint, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const raw = GetWindowLongPtrW(hwnd, user_data);
    if (raw == 0 or (msg != wm_hotkey and !(msg == wm_timer and wparam == poll_timer))) return DefWindowProcW(hwnd, msg, wparam, lparam);
    const registry: *Registry = @ptrFromInt(@as(usize, @bitCast(raw)));
    registry.update(if (msg == wm_hotkey) @intCast(wparam & 0xFFFF) else null);
    return 0;
}

fn modifierMask(modifiers: types.ShortcutModifiers) c_uint {
    return 0x4000 | @as(c_uint, if (modifiers.option) 1 else 0) | @as(c_uint, if (modifiers.primary or modifiers.control) 2 else 0) |
        @as(c_uint, if (modifiers.shift) 4 else 0) | @as(c_uint, if (modifiers.command) 8 else 0);
}
