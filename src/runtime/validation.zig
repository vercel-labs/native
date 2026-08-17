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
    try validateNotificationField(options.id, platform.max_notification_id_bytes);
    try validateNotificationField(options.title, platform.max_notification_title_bytes);
    try validateNotificationField(options.subtitle, platform.max_notification_subtitle_bytes);
    try validateNotificationField(options.body, platform.max_notification_body_bytes);
    try validateNotificationField(options.action_label, platform.max_notification_action_label_bytes);
    try validateNotificationField(options.action_command, platform.max_notification_action_command_bytes);
    if ((options.action_label.len == 0) != (options.action_command.len == 0)) return error.InvalidNotificationOptions;
    if (options.action_command.len > 0) try validateCommandName(options.action_command);
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
    try validateTrayPresentation(options.presentation);
    try validateTrayField(options.tooltip, platform.max_tray_tooltip_bytes);
    try validateTrayField(options.activation_command, platform.max_tray_item_command_bytes);
    try validateTrayField(options.alternate_activation_command, platform.max_tray_item_command_bytes);
    try validateTrayField(options.open_command, platform.max_tray_item_command_bytes);
    if (options.activation_command.len > 0) try validateCommandName(options.activation_command);
    if (options.alternate_activation_command.len > 0) try validateCommandName(options.alternate_activation_command);
    if (options.open_command.len > 0) try validateCommandName(options.open_command);
    try validateTrayMenuItems(options.items);
}

pub fn validateStatusItemId(status_item_id: platform.StatusItemId) !void {
    if (status_item_id == 0) return error.InvalidTrayOptions;
}

pub fn validateTrayShell(shell: platform.TrayShell) !void {
    try validateTrayField(shell.icon_path, platform.max_tray_icon_path_bytes);
    try validateTrayField(shell.tooltip, platform.max_tray_tooltip_bytes);
    try validateTrayField(shell.activation_command, platform.max_tray_item_command_bytes);
    try validateTrayField(shell.alternate_activation_command, platform.max_tray_item_command_bytes);
    try validateTrayField(shell.open_command, platform.max_tray_item_command_bytes);
    if (shell.activation_command.len > 0) try validateCommandName(shell.activation_command);
    if (shell.alternate_activation_command.len > 0) try validateCommandName(shell.alternate_activation_command);
    if (shell.open_command.len > 0) try validateCommandName(shell.open_command);
}

pub fn validateTrayTitle(title: []const u8) !void {
    try validateTrayField(title, platform.max_tray_title_bytes);
}

pub fn validateTrayPresentation(presentation: platform.TrayPresentation) !void {
    try validateTrayTitle(presentation.title);
    if (!std.math.isFinite(presentation.width) or presentation.width < 0) return error.InvalidTrayOptions;
    if (!std.math.isFinite(presentation.icon_opacity) or presentation.icon_opacity < 0 or presentation.icon_opacity > 1) return error.InvalidTrayOptions;
    if (!std.math.isFinite(presentation.font_size) or presentation.font_size < 0 or presentation.font_size > 64) return error.InvalidTrayOptions;
}

pub fn validateTrayMenuItems(items: []const platform.TrayMenuItem) !void {
    if (items.len > platform.max_tray_items) return error.InvalidTrayOptions;
    var fallback_row_count: usize = 0;
    for (items, 0..) |item, index| {
        try validateTrayField(item.label, platform.max_tray_item_label_bytes);
        try validateTrayField(item.command, platform.max_tray_item_command_bytes);
        try validateTrayField(item.detail, platform.max_tray_item_detail_bytes);
        try validateTrayField(item.key, platform.max_menu_key_bytes);
        if (item.role != .command and item.role != .agent and item.command.len > 0) return error.InvalidTrayOptions;
        if (item.detail.len > 0 and item.role != .info and item.role != .hero and item.role != .agent and item.role != .context) return error.InvalidTrayOptions;
        if (item.separator and (item.detail.len > 0 or item.role != .command)) return error.InvalidTrayOptions;
        if ((item.role == .segmented) != (item.segmented != null)) return error.InvalidTrayOptions;
        if ((item.role == .chart) != (item.chart != null)) return error.InvalidTrayOptions;
        if (item.metric != null and item.role != .hero) return error.InvalidTrayOptions;
        if ((item.role == .segmented or item.role == .chart) and item.id != 0) return error.InvalidTrayOptions;
        if ((item.role == .segmented or item.role == .chart) and item.label.len != 0) return error.InvalidTrayOptions;
        if (item.id != 0) {
            for (items[0..index]) |previous| {
                if (previous.id == item.id) return error.InvalidTrayOptions;
            }
        }
        if (item.command.len > 0) {
            if (item.separator or item.id == 0) return error.InvalidTrayOptions;
            try validateCommandName(item.command);
        }
        if (!item.separator and item.label.len == 0 and item.role != .segmented and item.role != .chart and item.metric == null) return error.InvalidTrayOptions;
        if (item.key.len > 0) {
            if (item.separator or item.command.len == 0) return error.InvalidTrayOptions;
            if (!platform.isValidShortcutBinding(item.key, item.modifiers)) return error.InvalidTrayOptions;
        }
        if (item.segmented) |segmented| {
            try validateTraySegmentedRow(items, index, segmented);
            fallback_row_count += segmented.options.len;
        } else {
            fallback_row_count += 1;
        }
        if (item.metric) |metric| try validateTrayMetricRow(metric);
        if (item.chart) |chart| try validateTrayChartRow(chart);
    }
    if (fallback_row_count > platform.max_tray_items) return error.InvalidTrayOptions;
}

fn validateTrayMetricRow(metric: platform.TrayMetricRow) !void {
    try validateTrayField(metric.primary_text, platform.max_tray_item_label_bytes);
    try validateTrayField(metric.secondary_text, platform.max_tray_item_detail_bytes);
    try validateTrayField(metric.accessibility_label, platform.max_tray_chart_text_bytes);
    if (metric.primary_text.len == 0 or metric.accessibility_label.len == 0) return error.InvalidTrayOptions;
}

fn validateTraySegmentedRow(items: []const platform.TrayMenuItem, row_index: usize, row: platform.TraySegmentedRow) !void {
    if (row.options.len == 0 or row.options.len > platform.max_tray_segment_options) return error.InvalidTrayOptions;
    var selected_count: usize = 0;
    for (row.options, 0..) |option, option_index| {
        if (option.id == 0) return error.InvalidTrayOptions;
        try validateTrayField(option.label, platform.max_tray_segment_label_bytes);
        try validateTrayField(option.command, platform.max_tray_item_command_bytes);
        if (option.label.len == 0 or option.command.len == 0) return error.InvalidTrayOptions;
        try validateCommandName(option.command);
        if (option.selected) selected_count += 1;
        for (row.options[0..option_index]) |previous| {
            if (previous.id == option.id) return error.InvalidTrayOptions;
        }
        for (items, 0..) |other, other_index| {
            if (other_index == row_index) continue;
            if (other.id == option.id) return error.InvalidTrayOptions;
            if (other.segmented) |other_segmented| {
                for (other_segmented.options) |other_option| {
                    if (other_option.id == option.id) return error.InvalidTrayOptions;
                }
            }
        }
    }
    if (selected_count > 1) return error.InvalidTrayOptions;
}

fn validateTrayChartRow(chart: platform.TrayChartRow) !void {
    if (chart.values.len == 0 or chart.values.len > platform.max_tray_chart_values) return error.InvalidTrayOptions;
    if (!std.math.isFinite(chart.min_value) or !std.math.isFinite(chart.max_value) or !(chart.max_value > chart.min_value)) return error.InvalidTrayOptions;
    try validateTrayField(chart.leading_caption, platform.max_tray_chart_text_bytes);
    try validateTrayField(chart.trailing_summary, platform.max_tray_chart_text_bytes);
    try validateTrayField(chart.accessibility_label, platform.max_tray_chart_text_bytes);
    if (chart.accessibility_label.len == 0) return error.InvalidTrayOptions;
    for (chart.values) |value| {
        if (!std.math.isFinite(value) or value < chart.min_value or value > chart.max_value) return error.InvalidTrayOptions;
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

test "typed rich tray rows validate bounded data and shared option ids" {
    const segments = [_]platform.TraySegmentOption{
        .{ .id = 11, .label = "Day", .command = "range.day", .selected = true },
        .{ .id = 12, .label = "Week", .command = "range.week" },
    };
    const values = [_]f32{ 0.2, 0.5, 1.0 };
    try validateTrayMenuItems(&.{
        .{ .role = .hero, .metric = .{ .primary_text = "2,494 requests", .secondary_text = "Today · production", .accessibility_label = "2,494 requests today in production" } },
        .{ .role = .segmented, .segmented = .{ .options = &segments } },
        .{ .role = .chart, .chart = .{ .values = &values, .min_value = 0, .max_value = 1, .leading_caption = "CPU", .trailing_summary = "42%", .accessibility_label = "CPU history, 42 percent" } },
    });

    const duplicate_segments = [_]platform.TraySegmentOption{
        .{ .id = 11, .label = "Day", .command = "range.day" },
        .{ .id = 11, .label = "Week", .command = "range.week" },
    };
    try std.testing.expectError(error.InvalidTrayOptions, validateTrayMenuItems(&.{
        .{ .role = .segmented, .segmented = .{ .options = &duplicate_segments } },
    }));
    const out_of_range = [_]f32{1.1};
    try std.testing.expectError(error.InvalidTrayOptions, validateTrayMenuItems(&.{
        .{ .role = .chart, .chart = .{ .values = &out_of_range, .min_value = 0, .max_value = 1, .accessibility_label = "bad" } },
    }));
}
