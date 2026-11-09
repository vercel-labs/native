//! Native transport and capability selectors for compiled builtin coordination.
const std = @import("std");
const security = @import("../security/root.zig");
const bridge = @import("../bridge/root.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Family = enum(u8) { none, command, window, view, webview, platform, dialog, os, clipboard, credentials };
pub const Verb = enum(u8) {
    unknown,
    command_invoke,
    command_list,
    platform_supports,
    window_list,
    window_create,
    window_focus,
    window_close,
    view_create,
    view_list,
    view_update,
    view_setFrame,
    view_setVisible,
    view_focus,
    view_focusNext,
    view_focusPrevious,
    view_close,
    webview_create,
    webview_list,
    webview_setFrame,
    webview_navigate,
    webview_setZoom,
    webview_setLayer,
    webview_close,
    dialog_openFile,
    dialog_saveFile,
    dialog_showMessage,
    os_showNotification,
    os_openUrl,
    os_revealPath,
    os_addRecentDocument,
    os_clearRecentDocuments,
    credentials_set,
    credentials_get,
    credentials_delete,
    clipboard_readText,
    clipboard_writeText,
    clipboard_read,
    clipboard_write,
};
pub const Program = struct {
    bytes: [512]u8 = @splat(0xa5),
    len: usize = 0,
    fn word(self: *const Program, at: usize) u32 {
        return std.mem.readInt(u32, self.bytes[at..][0..4], .little);
    }
    fn short(self: *const Program, at: usize) usize {
        return std.mem.readInt(u16, self.bytes[at..][0..2], .little);
    }
    pub fn family(self: *const Program) Family {
        return @enumFromInt(self.bytes[8]);
    }
    pub fn verb(self: *const Program) Verb {
        return @enumFromInt(self.bytes[9]);
    }
    pub fn permission(self: *const Program) ?[]const u8 {
        return switch (self.bytes[10]) {
            0 => null,
            1 => security.permission_command,
            2 => security.permission_window,
            3 => security.permission_view,
            else => unreachable,
        };
    }
    pub fn deniedMessage(self: *const Program) []const u8 {
        return self.bytes[16..][0..self.short(12)];
    }
    pub fn unknownMessage(self: *const Program) []const u8 {
        const length = self.short(12);
        return self.bytes[16 + length ..][0..self.short(14)];
    }
    pub fn errorCode(self: *const Program) bridge.ErrorCode {
        return @enumFromInt(self.bytes[8]);
    }
    pub fn message(self: *const Program) []const u8 {
        return self.bytes[16..self.len];
    }
    pub fn notificationDenied(self: *const Program) bool {
        return self.bytes[8] == 1;
    }
};
fn run(policy: Policy, input: []const u8) Program {
    var result = Program{};
    result.len = policy(input, &result.bytes);
    if (result.len < 16 or result.len > result.bytes.len or result.word(0) != 1 or result.word(4) != input[2]) @panic("invalid compiled builtin coordination program");
    if (input[2] == 0) {
        if (result.bytes[8] > 9 or result.bytes[9] > 38 or result.bytes[10] > 3 or result.bytes[11] != 0 or result.len != 16 + result.short(12) + result.short(14)) @panic("invalid compiled builtin route");
    } else {
        if (result.bytes[9] != 0 or result.bytes[10] != 0 or result.bytes[11] != 0 or result.len != 16 + result.word(12)) @panic("invalid compiled builtin result");
        if (input[2] == 1 and result.bytes[8] != @intFromEnum(bridge.ErrorCode.invalid_request) and result.bytes[8] != @intFromEnum(bridge.ErrorCode.internal_error)) @panic("invalid compiled builtin error code");
        if (input[2] == 2 and result.bytes[8] > 1) @panic("invalid compiled notification admission");
    }
    return result;
}
fn textProgram(policy: Policy, mode: u8, context: Family, value: []const u8) Program {
    var storage = std.heap.stackFallback(4096, std.heap.page_allocator);
    var writer = std.Io.Writer.Allocating.init(storage.get());
    defer writer.deinit();
    writer.writer.writeAll(&.{ 89, 1, mode, @intFromEnum(context), 0, 0, 0, 0 }) catch @panic("builtin transport allocation failed");
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .little);
    writer.writer.writeAll(&length) catch @panic("builtin transport allocation failed");
    writer.writer.writeAll(value) catch @panic("builtin transport allocation failed");
    return run(policy, writer.written());
}
pub fn route(policy: Policy, context: Family, command: []const u8) Program {
    return textProgram(policy, 0, context, command);
}
pub fn errorInfo(policy: Policy, err: anyerror) Program {
    return textProgram(policy, 1, .none, @errorName(err));
}
pub fn notification(policy: Policy, has_action: bool, allowed: bool) Program {
    return run(policy, &.{ 89, 1, 2, @intFromBool(has_action), @intFromBool(allowed), 0, 0, 0 });
}
