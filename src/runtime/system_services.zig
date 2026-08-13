const std = @import("std");
const credentials_store = @import("credentials_store.zig");
const json = @import("json");
const validation = @import("validation.zig");
const bridge_payload = @import("bridge_payload.zig");
const bridge_responses = @import("bridge_responses.zig");
const bridge = @import("../bridge/root.zig");
const platform = @import("../platform/root.zig");
const security = @import("../security/root.zig");

const jsonStringField = bridge_payload.jsonStringField;
const jsonBoolField = bridge_payload.jsonBoolField;
const platformFeatureFromString = bridge_payload.platformFeatureFromString;
const writeBoolJson = bridge_responses.writeBoolJson;
const writeTrueJson = bridge_responses.writeTrueJson;

const validateClipboardData = validation.validateClipboardData;
const validateClipboardMimeType = validation.validateClipboardMimeType;
const validateCredential = validation.validateCredential;
const validateCredentialKey = validation.validateCredentialKey;
const validateMessageDialogOptions = validation.validateMessageDialogOptions;
const validateNotificationOptions = validation.validateNotificationOptions;
const validateOpenDialogOptions = validation.validateOpenDialogOptions;
const validateRecentDocumentPath = validation.validateRecentDocumentPath;
const validateRevealPath = validation.validateRevealPath;
const validateSaveDialogOptions = validation.validateSaveDialogOptions;
const validateTrayMenuItems = validation.validateTrayMenuItems;
const validateTrayOptions = validation.validateTrayOptions;
const validateTrayShell = validation.validateTrayShell;
const validateTrayTitle = validation.validateTrayTitle;

fn optionalNotificationString(payload: []const u8, field: []const u8, storage: *json.StringStorage) ![]const u8 {
    if (json.fieldValue(payload, field) == null) return "";
    return jsonStringField(payload, field, storage) orelse error.InvalidNotificationOptions;
}

pub fn RuntimeSystemServices(comptime Runtime: type) type {
    return struct {
        pub fn readClipboard(self: *Runtime, buffer: []u8) anyerror![]const u8 {
            return self.readClipboardData("text/plain", buffer);
        }

        pub fn writeClipboard(self: *Runtime, text: []const u8) anyerror!void {
            try self.writeClipboardData(.{ .mime_type = "text/plain", .bytes = text });
        }

        pub fn readClipboardData(self: *Runtime, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
            try validateClipboardMimeType(mime_type);
            return self.options.platform.services.readClipboardData(mime_type, buffer);
        }

        pub fn writeClipboardData(self: *Runtime, data: platform.ClipboardData) anyerror!void {
            try validateClipboardData(data);
            try self.options.platform.services.writeClipboardData(data);
        }

        pub fn openExternalUrl(self: *Runtime, url: []const u8) anyerror!void {
            try validateExternalUrl(self, url);
            try self.options.platform.services.openExternalUrl(url);
        }

        pub fn revealPath(self: *Runtime, path: []const u8) anyerror!void {
            try validateRevealPath(path);
            try self.options.platform.services.revealPath(path);
        }

        pub fn addRecentDocument(self: *Runtime, path: []const u8) anyerror!void {
            try validateRecentDocumentPath(path);
            try self.options.platform.services.addRecentDocument(path);
        }

        pub fn clearRecentDocuments(self: *Runtime) anyerror!void {
            try self.options.platform.services.clearRecentDocuments();
        }

        pub fn showOpenDialog(self: *Runtime, options: platform.OpenDialogOptions, buffer: []u8) anyerror!platform.OpenDialogResult {
            try validateOpenDialogOptions(options, buffer);
            return self.options.platform.services.showOpenDialog(options, buffer);
        }

        pub fn showSaveDialog(self: *Runtime, options: platform.SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
            try validateSaveDialogOptions(options, buffer);
            return self.options.platform.services.showSaveDialog(options, buffer);
        }

        pub fn showMessageDialog(self: *Runtime, options: platform.MessageDialogOptions) anyerror!platform.MessageDialogResult {
            try validateMessageDialogOptions(options);
            return self.options.platform.services.showMessageDialog(options);
        }

        pub fn showNotification(self: *Runtime, options: platform.NotificationOptions) anyerror!void {
            try validateNotificationOptions(options);
            try self.options.platform.services.showNotification(options);
        }

        pub fn setCredential(self: *Runtime, credential: platform.Credential) anyerror!void {
            try validateCredential(credential);
            const execution = credentials_store.execute(.{
                .services = &self.options.platform.services,
                .service = credential.service,
                .permitted = true,
            }, .set, credential.account, credential.secret, &.{});
            try credentialOutcome(execution.outcome);
        }

        pub fn getCredential(self: *Runtime, key: platform.CredentialKey, buffer: []u8) anyerror!?[]const u8 {
            try validateCredentialKey(key);
            const execution = credentials_store.execute(.{
                .services = &self.options.platform.services,
                .service = key.service,
                .permitted = true,
            }, .get, key.account, "", buffer);
            if (execution.outcome == .miss) return null;
            try credentialOutcome(execution.outcome);
            return buffer[0..execution.len];
        }

        pub fn deleteCredential(self: *Runtime, key: platform.CredentialKey) anyerror!bool {
            try validateCredentialKey(key);
            const execution = credentials_store.execute(.{
                .services = &self.options.platform.services,
                .service = key.service,
                .permitted = true,
            }, .delete, key.account, "", &.{});
            if (execution.outcome == .miss) return false;
            try credentialOutcome(execution.outcome);
            return true;
        }

        fn credentialOutcome(outcome: credentials_store.Outcome) anyerror!void {
            return switch (outcome) {
                .ok => {},
                .miss => error.CredentialNotFound,
                .locked => error.UnsupportedService,
                .denied => error.PermissionDenied,
                .over_bound => error.CredentialFieldTooLarge,
                .io_failed, .rejected => error.CredentialStoreFailed,
            };
        }

        pub fn formatLocalTime(self: *Runtime, timestamp_ms: i64, style: platform.LocalTimeStyle, buffer: []u8) anyerror![]const u8 {
            return self.options.platform.services.formatLocalTime(timestamp_ms, style, buffer);
        }

        pub fn createStatusItem(self: *Runtime, status_item_id: platform.StatusItemId, options: platform.TrayOptions) anyerror!void {
            try validation.validateStatusItemId(status_item_id);
            try validateTrayOptions(options);
            const status_item = try statusItemSlot(self, status_item_id);
            const was_active = status_item.active;
            try self.options.platform.services.createStatusItem(status_item_id, options);
            try storeTrayItems(status_item, options.items);
            const title = if (options.presentation.title.len > 0) options.presentation.title else options.title;
            status_item.title = try copyInto(&status_item.title_storage, title);
            status_item.id = status_item_id;
            status_item.active = true;
            status_item.visible = options.visible;
            if (!was_active) self.status_item_count += 1;
        }

        pub fn createTray(self: *Runtime, options: platform.TrayOptions) anyerror!void {
            return self.createStatusItem(platform.primary_status_item_id, options);
        }

        pub fn updateStatusItemShell(self: *Runtime, status_item_id: platform.StatusItemId, shell: platform.TrayShell) anyerror!void {
            try validation.validateStatusItemId(status_item_id);
            try validateTrayShell(shell);
            const status_item = findStatusItem(self, status_item_id) orelse return error.InvalidTrayOptions;
            try self.options.platform.services.updateStatusItemShell(status_item_id, shell);
            status_item.visible = shell.visible;
        }

        pub fn updateStatusItemMenu(self: *Runtime, status_item_id: platform.StatusItemId, items: []const platform.TrayMenuItem) anyerror!void {
            try validation.validateStatusItemId(status_item_id);
            try validateTrayMenuItems(items);
            const status_item = findStatusItem(self, status_item_id) orelse return error.InvalidTrayOptions;
            try self.options.platform.services.updateStatusItemMenu(status_item_id, items);
            try storeTrayItems(status_item, items);
        }

        pub fn updateTrayMenu(self: *Runtime, items: []const platform.TrayMenuItem) anyerror!void {
            return self.updateStatusItemMenu(platform.primary_status_item_id, items);
        }

        /// Retitle the live status-bar button without re-creating the
        /// status item (a model-driven badge like "3 open" in the menu
        /// bar rides this seam). Platforms without the
        /// title seam report `UnsupportedService`; the menu keeps working.
        pub fn updateStatusItemTitle(self: *Runtime, status_item_id: platform.StatusItemId, title: []const u8) anyerror!void {
            try validation.validateStatusItemId(status_item_id);
            try validateTrayTitle(title);
            const status_item = findStatusItem(self, status_item_id) orelse return error.InvalidTrayOptions;
            try self.options.platform.services.updateStatusItemTitle(status_item_id, title);
            status_item.title = try copyInto(&status_item.title_storage, title);
        }

        pub fn updateTrayTitle(self: *Runtime, title: []const u8) anyerror!void {
            return self.updateStatusItemTitle(platform.primary_status_item_id, title);
        }

        pub fn updateStatusItemPresentation(self: *Runtime, status_item_id: platform.StatusItemId, presentation: platform.TrayPresentation) anyerror!void {
            try validation.validateStatusItemId(status_item_id);
            try validation.validateTrayPresentation(presentation);
            const status_item = findStatusItem(self, status_item_id) orelse return error.InvalidTrayOptions;
            try self.options.platform.services.updateStatusItemPresentation(status_item_id, presentation);
            status_item.title = try copyInto(&status_item.title_storage, presentation.title);
        }

        pub fn updateTrayPresentation(self: *Runtime, presentation: platform.TrayPresentation) anyerror!void {
            return self.updateStatusItemPresentation(platform.primary_status_item_id, presentation);
        }

        pub fn removeStatusItem(self: *Runtime, status_item_id: platform.StatusItemId) anyerror!void {
            try validation.validateStatusItemId(status_item_id);
            const status_item = findStatusItem(self, status_item_id) orelse return;
            try self.options.platform.services.removeStatusItem(status_item_id);
            status_item.* = .{};
            self.status_item_count -= 1;
        }

        pub fn removeTray(self: *Runtime) anyerror!void {
            return self.removeStatusItem(platform.primary_status_item_id);
        }

        pub fn statusItemExists(self: *const Runtime, status_item_id: platform.StatusItemId) bool {
            return findStatusItemConst(self, status_item_id) != null;
        }

        pub fn statusItemMenuItemExists(self: *const Runtime, status_item_id: platform.StatusItemId, item_id: platform.TrayItemId) bool {
            const status_item = findStatusItemConst(self, status_item_id) orelse return false;
            for (status_item.items[0..status_item.item_count]) |item| {
                if (item.id == item_id) return true;
            }
            return false;
        }

        pub fn trayItemExists(self: *const Runtime, item_id: platform.TrayItemId) bool {
            return self.statusItemMenuItemExists(platform.primary_status_item_id, item_id);
        }

        pub fn statusItemCommandNameForItem(self: *const Runtime, status_item_id: platform.StatusItemId, item_id: platform.TrayItemId) []const u8 {
            const status_item = findStatusItemConst(self, status_item_id) orelse return "tray.action";
            for (status_item.items[0..status_item.item_count]) |item| {
                if (item.id == item_id and item.command.len > 0) return item.command;
            }
            return "tray.action";
        }

        pub fn trayCommandNameForItem(self: *const Runtime, item_id: platform.TrayItemId) []const u8 {
            return self.statusItemCommandNameForItem(platform.primary_status_item_id, item_id);
        }

        pub fn supportsFeatureFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var scratch: [64]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const feature_name = jsonStringField(payload, "feature", &storage) orelse jsonStringField(payload, "name", &storage) orelse return error.InvalidPlatformFeature;
            const feature = platformFeatureFromString(feature_name) orelse return error.InvalidPlatformFeature;
            return writeBoolJson(self.supports(feature), output);
        }

        pub fn readClipboardTextFromJson(self: *Runtime, output: []u8) ![]const u8 {
            var value_buffer: [bridge.max_result_bytes]u8 = undefined;
            const value = try self.readClipboard(&value_buffer);
            var writer = std.Io.Writer.fixed(output);
            try json.writeString(&writer, value);
            return writer.buffered();
        }

        pub fn writeClipboardTextFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const text = jsonStringField(payload, "text", &storage) orelse jsonStringField(payload, "data", &storage) orelse jsonStringField(payload, "value", &storage) orelse return error.InvalidClipboardOptions;
            try self.writeClipboard(text);
            return writeTrueJson(output);
        }

        pub fn readClipboardDataFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var mime_storage_buffer: [platform.max_clipboard_mime_type_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&mime_storage_buffer);
            const mime_type = jsonStringField(payload, "mimeType", &storage) orelse jsonStringField(payload, "type", &storage) orelse "text/plain";
            var value_buffer: [bridge.max_result_bytes]u8 = undefined;
            const value = try self.readClipboardData(mime_type, &value_buffer);
            var writer = std.Io.Writer.fixed(output);
            try writer.writeAll("{\"mimeType\":");
            try json.writeString(&writer, mime_type);
            try writer.writeAll(",\"data\":");
            try json.writeString(&writer, value);
            try writer.writeByte('}');
            return writer.buffered();
        }

        pub fn writeClipboardDataFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const mime_type = jsonStringField(payload, "mimeType", &storage) orelse jsonStringField(payload, "type", &storage) orelse "text/plain";
            const data = jsonStringField(payload, "data", &storage) orelse jsonStringField(payload, "text", &storage) orelse jsonStringField(payload, "value", &storage) orelse return error.InvalidClipboardOptions;
            try self.writeClipboardData(.{ .mime_type = mime_type, .bytes = data });
            return writeTrueJson(output);
        }

        pub fn setCredentialFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const service = jsonStringField(payload, "service", &storage) orelse return error.InvalidCredentialOptions;
            const account = jsonStringField(payload, "account", &storage) orelse return error.InvalidCredentialOptions;
            const secret = jsonStringField(payload, "secret", &storage) orelse jsonStringField(payload, "value", &storage) orelse return error.InvalidCredentialOptions;
            try self.setCredential(.{ .service = service, .account = account, .secret = secret });
            return writeTrueJson(output);
        }

        pub fn getCredentialFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const service = jsonStringField(payload, "service", &storage) orelse return error.InvalidCredentialOptions;
            const account = jsonStringField(payload, "account", &storage) orelse return error.InvalidCredentialOptions;
            var secret_buffer: [platform.max_credential_secret_bytes]u8 = undefined;
            const secret = try self.getCredential(.{ .service = service, .account = account }, &secret_buffer);
            var writer = std.Io.Writer.fixed(output);
            if (secret) |value| {
                try json.writeString(&writer, value);
            } else {
                try writer.writeAll("null");
            }
            return writer.buffered();
        }

        pub fn deleteCredentialFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const service = jsonStringField(payload, "service", &storage) orelse return error.InvalidCredentialOptions;
            const account = jsonStringField(payload, "account", &storage) orelse return error.InvalidCredentialOptions;
            var writer = std.Io.Writer.fixed(output);
            try writer.writeAll(if (try self.deleteCredential(.{ .service = service, .account = account })) "true" else "false");
            return writer.buffered();
        }

        pub fn showNotificationFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const title = jsonStringField(payload, "title", &storage) orelse return error.InvalidNotificationOptions;
            const subtitle = try optionalNotificationString(payload, "subtitle", &storage);
            const body = if (json.fieldValue(payload, "body") != null)
                try optionalNotificationString(payload, "body", &storage)
            else
                try optionalNotificationString(payload, "message", &storage);
            const notification_id = try optionalNotificationString(payload, "id", &storage);
            const action_label = try optionalNotificationString(payload, "actionLabel", &storage);
            const action_command = try optionalNotificationString(payload, "actionCommand", &storage);
            try self.showNotification(.{
                .id = notification_id,
                .title = title,
                .subtitle = subtitle,
                .body = body,
                .action_label = action_label,
                .action_command = action_command,
            });
            return writeTrueJson(output);
        }

        pub fn openExternalUrlFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const url = jsonStringField(payload, "url", &storage) orelse return error.InvalidExternalUrl;
            try self.openExternalUrl(url);
            return writeTrueJson(output);
        }

        pub fn revealPathFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const path = jsonStringField(payload, "path", &storage) orelse return error.InvalidRevealPath;
            try self.revealPath(path);
            return writeTrueJson(output);
        }

        pub fn addRecentDocumentFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const path = jsonStringField(payload, "path", &storage) orelse return error.InvalidRecentDocumentPath;
            try self.addRecentDocument(path);
            return writeTrueJson(output);
        }

        pub fn clearRecentDocumentsFromJson(self: *Runtime, output: []u8) ![]const u8 {
            try self.clearRecentDocuments();
            return writeTrueJson(output);
        }

        pub fn openFileDialogFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const title = jsonStringField(payload, "title", &storage) orelse "";
            const default_path = jsonStringField(payload, "defaultPath", &storage) orelse "";
            const allow_dirs = jsonBoolField(payload, "allowDirectories") orelse false;
            const allow_multi = jsonBoolField(payload, "allowMultiple") orelse false;
            var dialog_buffer: [platform.max_dialog_paths_bytes]u8 = undefined;
            const result = try self.showOpenDialog(.{
                .title = title,
                .default_path = default_path,
                .allow_directories = allow_dirs,
                .allow_multiple = allow_multi,
            }, &dialog_buffer);

            var writer = std.Io.Writer.fixed(output);
            if (result.count == 0) {
                try writer.writeAll("null");
            } else {
                try writer.writeByte('[');
                var start: usize = 0;
                var i: usize = 0;
                for (result.paths, 0..) |ch, pos| {
                    if (ch == '\n') {
                        if (i > 0) try writer.writeByte(',');
                        try json.writeString(&writer, result.paths[start..pos]);
                        start = pos + 1;
                        i += 1;
                    }
                }
                if (start < result.paths.len) {
                    if (i > 0) try writer.writeByte(',');
                    try json.writeString(&writer, result.paths[start..]);
                }
                try writer.writeByte(']');
            }
            return writer.buffered();
        }

        pub fn saveFileDialogFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const title = jsonStringField(payload, "title", &storage) orelse "";
            const default_path = jsonStringField(payload, "defaultPath", &storage) orelse "";
            const default_name = jsonStringField(payload, "defaultName", &storage) orelse "";
            var dialog_buffer: [platform.max_dialog_path_bytes]u8 = undefined;
            const path = try self.showSaveDialog(.{
                .title = title,
                .default_path = default_path,
                .default_name = default_name,
            }, &dialog_buffer);

            var writer = std.Io.Writer.fixed(output);
            if (path) |p| {
                try json.writeString(&writer, p);
            } else {
                try writer.writeAll("null");
            }
            return writer.buffered();
        }

        pub fn showMessageDialogFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const title = jsonStringField(payload, "title", &storage) orelse "";
            const message = jsonStringField(payload, "message", &storage) orelse "";
            const informative = jsonStringField(payload, "informativeText", &storage) orelse "";
            const primary = jsonStringField(payload, "primaryButton", &storage) orelse "OK";
            const secondary = jsonStringField(payload, "secondaryButton", &storage) orelse "";
            const tertiary = jsonStringField(payload, "tertiaryButton", &storage) orelse "";
            const style_str = jsonStringField(payload, "style", &storage) orelse "info";
            const style: platform.MessageDialogStyle = if (std.mem.eql(u8, style_str, "warning"))
                .warning
            else if (std.mem.eql(u8, style_str, "critical"))
                .critical
            else
                .info;

            const result = try self.showMessageDialog(.{
                .style = style,
                .title = title,
                .message = message,
                .informative_text = informative,
                .primary_button = primary,
                .secondary_button = secondary,
                .tertiary_button = tertiary,
            });

            var writer = std.Io.Writer.fixed(output);
            try json.writeString(&writer, @tagName(result));
            return writer.buffered();
        }
    };
}

fn storeTrayItems(status_item: anytype, items: []const platform.TrayMenuItem) !void {
    status_item.item_count = 0;
    for (items, 0..) |item, index| {
        status_item.items[index].id = item.id;
        status_item.items[index].command = try copyInto(&status_item.items[index].command_storage, item.command);
        status_item.items[index].label = try copyInto(&status_item.items[index].label_storage, item.label);
        status_item.items[index].detail = try copyInto(&status_item.items[index].detail_storage, item.detail);
        status_item.items[index].separator = item.separator;
        status_item.items[index].enabled = item.enabled;
        status_item.items[index].role = item.role;
        status_item.items[index].key = try copyInto(&status_item.items[index].key_storage, item.key);
        status_item.items[index].modifiers = item.modifiers;
    }
    status_item.item_count = items.len;
}

fn findStatusItem(self: anytype, status_item_id: platform.StatusItemId) ?@TypeOf(&self.status_items[0]) {
    for (&self.status_items) |*status_item| {
        if (status_item.active and status_item.id == status_item_id) return status_item;
    }
    return null;
}

fn findStatusItemConst(self: anytype, status_item_id: platform.StatusItemId) ?@TypeOf(&self.status_items[0]) {
    for (&self.status_items) |*status_item| {
        if (status_item.active and status_item.id == status_item_id) return status_item;
    }
    return null;
}

fn statusItemSlot(self: anytype, status_item_id: platform.StatusItemId) !@TypeOf(&self.status_items[0]) {
    if (findStatusItem(self, status_item_id)) |status_item| return status_item;
    if (self.status_item_count >= self.status_items.len) return error.InvalidTrayOptions;
    for (&self.status_items) |*status_item| {
        if (!status_item.active) return status_item;
    }
    return error.InvalidTrayOptions;
}

fn validateExternalUrl(self: anytype, url: []const u8) !void {
    if (url.len == 0) return error.InvalidExternalUrl;
    if (url.len > platform.max_external_url_bytes) return error.ExternalUrlTooLarge;
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidExternalUrl;
    for (url) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return error.InvalidExternalUrl;
    }
    if (!security.allowsExternalUrl(self.options.security.navigation.external_links, url)) return error.NavigationDenied;
}

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}
