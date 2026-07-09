const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");

pub const max_command_id_bytes: usize = 128;

pub fn validateCommandName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_command_id_bytes) return error.InvalidCommand;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidCommand;
    for (name) |ch| {
        if (ch == 0 or ch == '/' or ch == '\\' or ch == '\n' or ch == '\r' or ch == '\t') return error.InvalidCommand;
    }
}

pub fn validateRevealPath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidRevealPath;
    if (path.len > platform.max_reveal_path_bytes) return error.RevealPathTooLarge;
    for (path) |ch| {
        if (ch == 0) return error.InvalidRevealPath;
    }
}

pub fn validateRecentDocumentPath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidRecentDocumentPath;
    if (path.len > platform.max_recent_document_path_bytes) return error.RecentDocumentPathTooLarge;
    for (path) |ch| {
        if (ch == 0) return error.InvalidRecentDocumentPath;
    }
}

pub fn validateOpenDialogOptions(options: platform.OpenDialogOptions, buffer: []u8) !void {
    if (buffer.len == 0) return error.InvalidDialogOptions;
    try validateDialogString(options.title, platform.max_dialog_title_bytes, true);
    try validateDialogString(options.default_path, platform.max_dialog_path_bytes, true);
    try validateDialogFilters(options.filters);
}

pub fn validateSaveDialogOptions(options: platform.SaveDialogOptions, buffer: []u8) !void {
    if (buffer.len == 0) return error.InvalidDialogOptions;
    try validateDialogString(options.title, platform.max_dialog_title_bytes, true);
    try validateDialogString(options.default_path, platform.max_dialog_path_bytes, true);
    try validateDialogString(options.default_name, platform.max_dialog_path_bytes, true);
    try validateDialogFilters(options.filters);
}

pub fn validateMessageDialogOptions(options: platform.MessageDialogOptions) !void {
    try validateDialogString(options.title, platform.max_dialog_title_bytes, true);
    try validateDialogString(options.message, platform.max_dialog_message_bytes, true);
    try validateDialogString(options.informative_text, platform.max_dialog_message_bytes, true);
    try validateDialogString(options.primary_button, platform.max_dialog_button_bytes, false);
    try validateDialogString(options.secondary_button, platform.max_dialog_button_bytes, true);
    try validateDialogString(options.tertiary_button, platform.max_dialog_button_bytes, true);
}

fn validateDialogFilters(filters: []const platform.FileFilter) !void {
    var flattened_len: usize = 0;
    for (filters) |filter| {
        try validateDialogString(filter.name, platform.max_dialog_filter_name_bytes, true);
        for (filter.extensions) |extension| {
            try validateDialogString(extension, platform.max_dialog_filter_bytes, false);
            if (std.mem.indexOfScalar(u8, extension, ';') != null) return error.InvalidDialogOptions;
            flattened_len += extension.len;
            if (flattened_len > platform.max_dialog_filter_bytes) return error.DialogFieldTooLarge;
            flattened_len += 1;
            if (flattened_len > platform.max_dialog_filter_bytes + 1) return error.DialogFieldTooLarge;
        }
    }
}

fn validateDialogString(value: []const u8, max_len: usize, allow_empty: bool) !void {
    if (!allow_empty and value.len == 0) return error.InvalidDialogOptions;
    if (value.len > max_len) return error.DialogFieldTooLarge;
    for (value) |ch| {
        if (ch == 0) return error.InvalidDialogOptions;
    }
}

pub fn validateNotificationOptions(options: platform.NotificationOptions) !void {
    if (options.title.len == 0) return error.InvalidNotificationOptions;
    try validateNotificationField(options.title, platform.max_notification_title_bytes);
    try validateNotificationField(options.subtitle, platform.max_notification_subtitle_bytes);
    try validateNotificationField(options.body, platform.max_notification_body_bytes);
}

pub fn validateClipboardData(data: platform.ClipboardData) !void {
    try validateClipboardMimeType(data.mime_type);
    if (data.bytes.len > platform.max_clipboard_data_bytes) return error.ClipboardFieldTooLarge;
}

pub fn validateClipboardMimeType(mime_type: []const u8) !void {
    if (mime_type.len == 0) return error.InvalidClipboardOptions;
    if (mime_type.len > platform.max_clipboard_mime_type_bytes) return error.ClipboardFieldTooLarge;
    for (mime_type) |ch| {
        if (ch == 0 or ch == '/' or ch == '\\') {
            if (ch != '/') return error.InvalidClipboardOptions;
        }
        if (ch <= 0x20 or ch == 0x7f) return error.InvalidClipboardOptions;
    }
}

pub fn validateCredential(credential: platform.Credential) !void {
    try validateCredentialKey(.{ .service = credential.service, .account = credential.account });
    try validateCredentialField(credential.secret, platform.max_credential_secret_bytes);
}

pub fn validateCredentialKey(key: platform.CredentialKey) !void {
    try validateCredentialField(key.service, platform.max_credential_service_bytes);
    try validateCredentialField(key.account, platform.max_credential_account_bytes);
}

fn validateCredentialField(value: []const u8, max_len: usize) !void {
    if (value.len == 0) return error.InvalidCredentialOptions;
    if (value.len > max_len) return error.CredentialFieldTooLarge;
    for (value) |ch| {
        if (ch == 0) return error.InvalidCredentialOptions;
    }
}

pub fn validateTrayOptions(options: platform.TrayOptions) !void {
    try validateTrayField(options.icon_path, platform.max_tray_icon_path_bytes);
    try validateTrayField(options.title, platform.max_tray_title_bytes);
    try validateTrayField(options.tooltip, platform.max_tray_tooltip_bytes);
    try validateTrayField(options.popover_window, platform.max_tray_popover_window_bytes);
    try validateTrayMenuItems(options.items);
}

pub fn validateTrayTitle(title: []const u8) !void {
    try validateTrayField(title, platform.max_tray_title_bytes);
}

pub fn validateTrayMenuItems(items: []const platform.TrayMenuItem) !void {
    if (items.len > platform.max_tray_items) return error.InvalidTrayOptions;
    for (items, 0..) |item, index| {
        try validateTrayField(item.label, platform.max_tray_item_label_bytes);
        try validateTrayField(item.command, platform.max_tray_item_command_bytes);
        if (item.id != 0) {
            for (items[0..index]) |previous| {
                if (previous.id == item.id) return error.InvalidTrayOptions;
            }
        }
        if (item.command.len > 0) {
            if (item.separator or item.id == 0) return error.InvalidTrayOptions;
            try validateCommandName(item.command);
        }
        if (!item.separator and item.label.len == 0) return error.InvalidTrayOptions;
    }
}

fn validateTrayField(value: []const u8, max_len: usize) !void {
    if (value.len > max_len) return error.TrayFieldTooLarge;
    for (value) |ch| {
        if (ch == 0) return error.InvalidTrayOptions;
    }
}

fn validateNotificationField(value: []const u8, max_len: usize) !void {
    if (value.len > max_len) return error.NotificationFieldTooLarge;
    for (value) |ch| {
        if (ch == 0) return error.InvalidNotificationOptions;
    }
}

pub fn validateWindowFrame(frame: geometry.RectF) !void {
    if (!std.math.isFinite(frame.x) or !std.math.isFinite(frame.y) or !std.math.isFinite(frame.width) or !std.math.isFinite(frame.height)) return error.InvalidWindowOptions;
    if (frame.width <= 0 or frame.height <= 0) return error.InvalidWindowOptions;
}

pub fn isMainWebViewLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "main");
}

pub fn validateWebViewLabel(label: []const u8) !void {
    if (label.len == 0) return error.InvalidWebViewOptions;
    if (label.len > platform.max_webview_label_bytes) return error.WebViewLabelTooLarge;
}

pub fn validateChildWebViewLabel(label: []const u8) !void {
    try validateWebViewLabel(label);
    if (isMainWebViewLabel(label)) return error.ReservedWebViewLabel;
}

pub fn validateViewOptions(options: platform.ViewOptions) !void {
    try validateViewLabel(options.label);
    try validateViewFrame(options.frame);
    if (options.parent) |parent| {
        if (parent.len == 0 or parent.len > platform.max_view_label_bytes) return error.InvalidViewOptions;
    }
    if (options.role.len > platform.max_view_role_bytes) return error.ViewRoleTooLarge;
    if (options.accessibility_label.len > platform.max_view_accessibility_label_bytes) return error.ViewAccessibilityLabelTooLarge;
    if (options.text.len > platform.max_view_text_bytes) return error.ViewTextTooLarge;
    if (options.command.len > 0) try validateCommandName(options.command);
    if (options.kind != .webview and options.url.len > 0) return error.InvalidViewOptions;
    if (options.kind == .gpu_surface and !options.gpu_surface.isSupported()) return error.UnsupportedViewKind;
}

pub fn validateViewLabel(label: []const u8) !void {
    if (label.len == 0) return error.InvalidViewOptions;
    if (label.len > platform.max_view_label_bytes) return error.ViewLabelTooLarge;
}

pub fn validateViewFrame(frame: geometry.RectF) !void {
    if (frame.x < 0 or frame.y < 0 or frame.width < 0 or frame.height < 0) return error.InvalidViewOptions;
}

pub fn isValidWebViewFrame(frame: geometry.RectF) bool {
    return frame.x >= 0 and frame.y >= 0 and frame.width > 0 and frame.height > 0;
}
