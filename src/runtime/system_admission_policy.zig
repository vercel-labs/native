//! Copied descriptor facts; native retains borrowed buffers and OS execution.
const std = @import("std");
const platform = @import("../platform/root.zig");
const reference = @import("validation.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { field, open, save, message, notification, clipboard, filter };
pub const Field = enum(u8) { reveal, recent, dialog_title, dialog_path, dialog_message, required_button, optional_button, filter_name, extension, notification_id, notification_title, notification_subtitle, notification_body, action_label, action_command, mime, clipboard_bytes, command };
comptime {
    if (platform.max_reveal_path_bytes != 4096 or platform.max_recent_document_path_bytes != 4096 or platform.max_dialog_path_bytes != 4096 or platform.max_dialog_title_bytes != 512 or platform.max_dialog_message_bytes != 4096 or platform.max_dialog_button_bytes != 128 or platform.max_dialog_filter_name_bytes != 256 or platform.max_dialog_filter_bytes != 1024 or platform.max_notification_id_bytes != 128 or platform.max_notification_title_bytes != 128 or platform.max_notification_subtitle_bytes != 128 or platform.max_notification_body_bytes != 1024 or platform.max_notification_action_label_bytes != 128 or platform.max_notification_action_command_bytes != 128 or platform.max_clipboard_mime_type_bytes != 128 or platform.max_clipboard_data_bytes != 65536 or reference.max_command_id_bytes != 128) @compileError("update system admission transport bounds");
}
pub const Program = struct {
    status: u32,
    next: u32,
    pub fn admit(self: Program) !void {
        return switch (self.status) {
            0 => {},
            1 => error.InvalidRevealPath,
            2 => error.RevealPathTooLarge,
            3 => error.InvalidRecentDocumentPath,
            4 => error.RecentDocumentPathTooLarge,
            5 => error.InvalidDialogOptions,
            6 => error.DialogFieldTooLarge,
            7 => error.InvalidNotificationOptions,
            8 => error.NotificationFieldTooLarge,
            9 => error.InvalidCommand,
            10 => error.InvalidClipboardOptions,
            11 => error.ClipboardFieldTooLarge,
            else => unreachable,
        };
    }
};
pub fn request(mode: Mode) [64]u8 {
    var bytes: [64]u8 = @splat(0);
    bytes[0..3].* = .{ 86, 1, @intFromEnum(mode) };
    return bytes;
}
pub fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn wide(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
pub fn plan(policy: Policy, bytes: []const u8) Program {
    var output: [16]u8 = @splat(0xa5);
    if (policy(bytes, &output) != output.len or std.mem.readInt(u32, output[0..4], .little) != 1 or std.mem.readInt(u32, output[4..8], .little) != bytes[2]) @panic("invalid compiled system admission header");
    const result = Program{ .status = std.mem.readInt(u32, output[8..12], .little), .next = std.mem.readInt(u32, output[12..16], .little) };
    if (result.status > 11 or result.next > 1025 or (bytes[2] != @intFromEnum(Mode.filter) and result.next != 0)) @panic("invalid compiled system admission result");
    return result;
}
fn capacity(kind: Field) usize {
    return switch (kind) {
        .reveal, .recent, .dialog_path, .dialog_message => 4096,
        .dialog_title => 512,
        .filter_name => 256,
        .extension, .notification_body => 1024,
        .clipboard_bytes => 0,
        else => 128,
    };
}
pub fn field(policy: Policy, kind: Field, value: []const u8) u32 {
    var bytes: [32 + 4096]u8 = @splat(0);
    bytes[0..4].* = .{ 86, 1, 0, @intFromEnum(kind) };
    wide(&bytes, 8, value.len);
    const count = @min(value.len, capacity(kind));
    @memcpy(bytes[32..][0..count], value[0..count]);
    return plan(policy, bytes[0 .. 32 + count]).status;
}
pub fn reveal(policy: ?Policy, path: []const u8) !void {
    const compiled = policy orelse return reference.validateRevealPath(path);
    try (Program{ .status = field(compiled, .reveal, path), .next = 0 }).admit();
}
pub fn recent(policy: ?Policy, path: []const u8) !void {
    const compiled = policy orelse return reference.validateRecentDocumentPath(path);
    try (Program{ .status = field(compiled, .recent, path), .next = 0 }).admit();
}
fn filters(policy: Policy, values: []const platform.FileFilter) !void {
    var count: u32 = 0;
    for (values) |value| {
        try (Program{ .status = field(policy, .filter_name, value.name), .next = 0 }).admit();
        for (value.extensions) |extension| {
            var bytes = request(.filter);
            put(&bytes, 8, count);
            wide(&bytes, 16, extension.len);
            put(&bytes, 32, field(policy, .extension, extension));
            const result = plan(policy, &bytes);
            try result.admit();
            count = result.next;
        }
    }
}
pub fn open(policy: ?Policy, options: platform.OpenDialogOptions, buffer: []u8) !void {
    const compiled = policy orelse return reference.validateOpenDialogOptions(options, buffer);
    var bytes = request(.open);
    wide(&bytes, 8, buffer.len);
    put(&bytes, 32, field(compiled, .dialog_title, options.title));
    put(&bytes, 36, field(compiled, .dialog_path, options.default_path));
    try plan(compiled, &bytes).admit();
    try filters(compiled, options.filters);
}
pub fn save(policy: ?Policy, options: platform.SaveDialogOptions, buffer: []u8) !void {
    const compiled = policy orelse return reference.validateSaveDialogOptions(options, buffer);
    var bytes = request(.save);
    wide(&bytes, 8, buffer.len);
    put(&bytes, 32, field(compiled, .dialog_title, options.title));
    put(&bytes, 36, field(compiled, .dialog_path, options.default_path));
    put(&bytes, 40, field(compiled, .dialog_path, options.default_name));
    try plan(compiled, &bytes).admit();
    try filters(compiled, options.filters);
}
pub fn message(policy: ?Policy, options: platform.MessageDialogOptions) !void {
    const compiled = policy orelse return reference.validateMessageDialogOptions(options);
    var bytes = request(.message);
    const values = [_][]const u8{ options.title, options.message, options.informative_text, options.primary_button, options.secondary_button, options.tertiary_button };
    const kinds = [_]Field{ .dialog_title, .dialog_message, .dialog_message, .required_button, .optional_button, .optional_button };
    for (values, kinds, 0..) |value, kind, i| put(&bytes, 32 + i * 4, field(compiled, kind, value));
    try plan(compiled, &bytes).admit();
}
pub fn notification(policy: ?Policy, options: platform.NotificationOptions) !void {
    const compiled = policy orelse return reference.validateNotificationOptions(options);
    var bytes = request(.notification);
    wide(&bytes, 8, options.title.len);
    wide(&bytes, 16, options.action_label.len);
    wide(&bytes, 24, options.action_command.len);
    const values = [_][]const u8{ options.id, options.title, options.subtitle, options.body, options.action_label, options.action_command };
    const kinds = [_]Field{ .notification_id, .notification_title, .notification_subtitle, .notification_body, .action_label, .action_command };
    for (values, kinds, 0..) |value, kind, i| put(&bytes, 32 + i * 4, field(compiled, kind, value));
    put(&bytes, 56, field(compiled, .command, options.action_command));
    try plan(compiled, &bytes).admit();
}
pub fn mime(policy: ?Policy, value: []const u8) !void {
    const compiled = policy orelse return reference.validateClipboardMimeType(value);
    try (Program{ .status = field(compiled, .mime, value), .next = 0 }).admit();
}
pub fn clipboard(policy: ?Policy, value: platform.ClipboardData) !void {
    const compiled = policy orelse return reference.validateClipboardData(value);
    var bytes = request(.clipboard);
    wide(&bytes, 8, value.bytes.len);
    put(&bytes, 32, field(compiled, .mime, value.mime_type));
    try plan(compiled, &bytes).admit();
}
