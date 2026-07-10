const std = @import("std");
const geometry = @import("geometry");
const json = @import("json");
const validation = @import("validation.zig");
const bridge_payload = @import("bridge_payload.zig");
const bridge_responses = @import("bridge_responses.zig");
const runtime_api = @import("api.zig");
const runtime_system_services = @import("system_services.zig");
const runtime_window_views = @import("window_views.zig");
const bridge = @import("../bridge/root.zig");
const platform = @import("../platform/root.zig");
const security = @import("../security/root.zig");

const max_command_id_bytes = validation.max_command_id_bytes;
const isMainWebViewLabel = validation.isMainWebViewLabel;
const validateWebViewLabel = validation.validateWebViewLabel;
const validateChildWebViewLabel = validation.validateChildWebViewLabel;
const jsonStringField = bridge_payload.jsonStringField;
const jsonNumberField = bridge_payload.jsonNumberField;
const jsonIntegerField = bridge_payload.jsonIntegerField;
const jsonBoolField = bridge_payload.jsonBoolField;
const webViewWindowIdFromJson = bridge_payload.webViewWindowIdFromJson;
const viewWindowIdFromJson = bridge_payload.viewWindowIdFromJson;
const viewKindFromString = bridge_payload.viewKindFromString;
const gpuSurfaceOptionsFromJson = bridge_payload.gpuSurfaceOptionsFromJson;
const viewFrameFromJson = bridge_payload.viewFrameFromJson;
const viewLayerFromJson = bridge_payload.viewLayerFromJson;
const webViewFrameFromJson = bridge_payload.webViewFrameFromJson;
const webViewLayerFromJson = bridge_payload.webViewLayerFromJson;
const writeWindowJson = bridge_responses.writeWindowJson;
const writeWebViewJson = bridge_responses.writeWebViewJson;
const writeViewJson = bridge_responses.writeViewJson;
const writeCommandEventJson = bridge_responses.writeCommandEventJson;
const writeCommandJsonToWriter = bridge_responses.writeCommandJsonToWriter;
const writeViewJsonToWriter = bridge_responses.writeViewJsonToWriter;
const writeWindowJsonToWriter = bridge_responses.writeWindowJsonToWriter;
const writeWebViewJsonToWriter = bridge_responses.writeWebViewJsonToWriter;
const builtinBridgeErrorMessage = bridge_responses.builtinBridgeErrorMessage;
const builtinBridgeErrorCode = bridge_responses.builtinBridgeErrorCode;
const CommandEvent = runtime_api.CommandEvent;

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

pub fn RuntimeBuiltinBridge(comptime Runtime: type) type {
    const App = runtime_api.App(Runtime);
    const SystemServiceMethods = runtime_system_services.RuntimeSystemServices(Runtime);
    const WindowViewMethods = runtime_window_views.RuntimeWindowViews(Runtime);

    return struct {
        const Self = @This();

        pub fn allowsBuiltinBridgeCommand(self: *Runtime, command: []const u8, origin: []const u8, js_permission: ?[]const u8) bool {
            var policy = self.options.builtin_bridge;
            if (self.options.security.permissions.len > 0) policy.permissions = self.options.security.permissions;
            if (policy.enabled) return policy.allows(command, origin);
            const permission = js_permission orelse return false;
            if (!self.options.js_window_api) return false;
            if (!security.allowsOrigin(self.options.security.navigation.allowed_origins, origin)) return false;
            if (self.options.security.permissions.len == 0) return true;
            return security.hasPermission(self.options.security.permissions, permission) or
                (!std.mem.eql(u8, permission, security.permission_window) and security.hasPermission(self.options.security.permissions, security.permission_window));
        }

        pub fn dispatchCommandBridgeCommand(self: *Runtime, app: App, request: bridge.Request, source_window_id: platform.WindowId, source_view_label: []const u8, result_buffer: []u8, response_buffer: []u8) []const u8 {
            const result = if (std.mem.eql(u8, request.command, "native-sdk.command.invoke"))
                Self.invokeCommandFromJson(self, app, request.payload, source_window_id, source_view_label, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.command.list"))
                Self.writeCommandListJson(self, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else
                return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown command command");
            return bridge.writeSuccessResponse(response_buffer, request.id, result);
        }

        pub fn dispatchPlatformBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
            const result = if (std.mem.eql(u8, request.command, "native-sdk.platform.supports"))
                SystemServiceMethods.supportsFeatureFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else
                return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown platform command");
            return bridge.writeSuccessResponse(response_buffer, request.id, result);
        }

        pub fn dispatchWindowBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
            const result = if (std.mem.eql(u8, request.command, "native-sdk.window.list"))
                Self.writeWindowListJson(self, result_buffer) catch return bridge.writeErrorResponse(response_buffer, request.id, .internal_error, "Failed to list windows")
            else if (std.mem.eql(u8, request.command, "native-sdk.window.create"))
                Self.createWindowFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.window.focus"))
                Self.focusWindowFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.window.close"))
                Self.closeWindowFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else
                return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown window command");
            return bridge.writeSuccessResponse(response_buffer, request.id, result);
        }

        pub fn invokeCommandFromJson(self: *Runtime, app: App, payload: []const u8, source_window_id: platform.WindowId, source_view_label: []const u8, output: []u8) ![]const u8 {
            var scratch: [max_command_id_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const name = jsonStringField(payload, "name", &storage) orelse jsonStringField(payload, "id", &storage) orelse return error.InvalidCommand;
            const view_label = if (std.mem.eql(u8, source_view_label, "main")) "" else source_view_label;
            const event: CommandEvent = .{
                .name = name,
                .source = .bridge,
                .window_id = source_window_id,
                .view_label = view_label,
            };
            try self.dispatchCommand(app, event);
            return writeCommandEventJson(event, output);
        }

        pub fn writeCommandListJson(self: *Runtime, output: []u8) ![]const u8 {
            var writer = std.Io.Writer.fixed(output);
            try writer.writeByte('[');
            for (self.options.commands, 0..) |command, index| {
                if (index > 0) try writer.writeByte(',');
                try writeCommandJsonToWriter(command, &writer);
            }
            try writer.writeByte(']');
            return writer.buffered();
        }

        pub fn dispatchViewBridgeCommand(self: *Runtime, request: bridge.Request, source_window_id: platform.WindowId, result_buffer: []u8, response_buffer: []u8) []const u8 {
            const result = if (std.mem.eql(u8, request.command, "native-sdk.view.create"))
                Self.createViewFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.view.list"))
                Self.writeViewListJson(self, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.view.update"))
                Self.updateViewFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.view.setFrame"))
                Self.setViewFrameFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.view.setVisible"))
                Self.setViewVisibleFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.view.focus"))
                Self.focusViewFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.view.focusNext"))
                Self.focusNextViewFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.view.focusPrevious"))
                Self.focusPreviousViewFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.view.close"))
                Self.closeViewFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else
                return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown view command");
            return bridge.writeSuccessResponse(response_buffer, request.id, result);
        }

        pub fn dispatchWebViewBridgeCommand(self: *Runtime, request: bridge.Request, source_window_id: platform.WindowId, result_buffer: []u8, response_buffer: []u8) []const u8 {
            // A native-only build has no webviews to command (and no page
            // to command them from); every webview verb answers with the
            // teaching error instead of a misleading not-found.
            if (!self.options.web_layer) {
                return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(error.WebViewLayerNotBuilt), builtinBridgeErrorMessage(error.WebViewLayerNotBuilt));
            }
            const result = if (std.mem.eql(u8, request.command, "native-sdk.webview.create"))
                Self.createWebViewFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.webview.list"))
                WindowViewMethods.writeWebViewListJson(self, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.webview.setFrame"))
                Self.setWebViewFrameFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.webview.navigate"))
                Self.navigateWebViewFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.webview.setZoom"))
                Self.setWebViewZoomFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.webview.setLayer"))
                Self.setWebViewLayerFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.webview.close"))
                Self.closeWebViewFromJson(self, request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else
                return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown WebView command");
            return bridge.writeSuccessResponse(response_buffer, request.id, result);
        }

        pub fn dispatchDialogBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
            const result = if (std.mem.eql(u8, request.command, "native-sdk.dialog.openFile"))
                SystemServiceMethods.openFileDialogFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.dialog.saveFile"))
                SystemServiceMethods.saveFileDialogFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.dialog.showMessage"))
                SystemServiceMethods.showMessageDialogFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else
                return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown dialog command");
            return bridge.writeSuccessResponse(response_buffer, request.id, result);
        }

        pub fn dispatchOsBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
            const result = if (std.mem.eql(u8, request.command, "native-sdk.os.openUrl"))
                SystemServiceMethods.openExternalUrlFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.os.showNotification"))
                SystemServiceMethods.showNotificationFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.os.revealPath"))
                SystemServiceMethods.revealPathFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.os.addRecentDocument"))
                SystemServiceMethods.addRecentDocumentFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.os.clearRecentDocuments"))
                SystemServiceMethods.clearRecentDocumentsFromJson(self, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else
                return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown OS command");
            return bridge.writeSuccessResponse(response_buffer, request.id, result);
        }

        pub fn dispatchCredentialBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
            const result = if (std.mem.eql(u8, request.command, "native-sdk.credentials.set"))
                SystemServiceMethods.setCredentialFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.credentials.get"))
                SystemServiceMethods.getCredentialFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.credentials.delete"))
                SystemServiceMethods.deleteCredentialFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else
                return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown credentials command");
            return bridge.writeSuccessResponse(response_buffer, request.id, result);
        }

        pub fn dispatchClipboardBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
            const result = if (std.mem.eql(u8, request.command, "native-sdk.clipboard.readText"))
                SystemServiceMethods.readClipboardTextFromJson(self, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.clipboard.writeText"))
                SystemServiceMethods.writeClipboardTextFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.clipboard.read"))
                SystemServiceMethods.readClipboardDataFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else if (std.mem.eql(u8, request.command, "native-sdk.clipboard.write"))
                SystemServiceMethods.writeClipboardDataFromJson(self, request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
            else
                return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown clipboard command");
            return bridge.writeSuccessResponse(response_buffer, request.id, result);
        }

        pub fn createWindowFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const label = jsonStringField(payload, "label", &storage) orelse "window";
            const title = jsonStringField(payload, "title", &storage) orelse "";
            const width = jsonNumberField(payload, "width") orelse 720;
            const height = jsonNumberField(payload, "height") orelse 480;
            const x = jsonNumberField(payload, "x") orelse 0;
            const y = jsonNumberField(payload, "y") orelse 0;
            const source = if (jsonStringField(payload, "url", &storage)) |url| platform.WebViewSource.url(url) else null;
            const info = try self.createWindow(.{
                .label = label,
                .title = title,
                .default_frame = geometry.RectF.init(x, y, width, height),
                .restore_state = jsonBoolField(payload, "restoreState") orelse true,
                .source = source,
            });
            return writeWindowJson(info, output);
        }

        pub fn createViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_view_label_bytes * 2 + platform.max_view_role_bytes + platform.max_view_accessibility_label_bytes + platform.max_view_text_bytes + platform.max_view_command_bytes + platform.max_webview_url_bytes + 96]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
            const kind_str = jsonStringField(payload, "kind", &storage) orelse return error.InvalidViewOptions;
            const kind = viewKindFromString(kind_str) orelse return error.UnsupportedViewKind;
            const window_id = try viewWindowIdFromJson(payload, source_window_id);
            const role = jsonStringField(payload, "role", &storage) orelse "";
            const accessibility_label = jsonStringField(payload, "accessibilityLabel", &storage) orelse jsonStringField(payload, "accessibility_label", &storage) orelse "";
            const text = jsonStringField(payload, "text", &storage) orelse "";
            const command = jsonStringField(payload, "command", &storage) orelse "";
            const parent = jsonStringField(payload, "parent", &storage);
            const url = jsonStringField(payload, "url", &storage) orelse "";
            const info = try self.createView(.{
                .window_id = window_id,
                .label = label,
                .kind = kind,
                .parent = parent,
                .frame = (try viewFrameFromJson(payload, kind == .webview)) orelse geometry.RectF.init(0, 0, 0, 0),
                .layer = try viewLayerFromJson(payload) orelse 0,
                .visible = jsonBoolField(payload, "visible") orelse true,
                .enabled = jsonBoolField(payload, "enabled") orelse true,
                .role = role,
                .accessibility_label = accessibility_label,
                .text = text,
                .command = command,
                .url = url,
                .transparent = jsonBoolField(payload, "transparent") orelse false,
                .bridge_enabled = jsonBoolField(payload, "bridge") orelse false,
                .gpu_surface = try gpuSurfaceOptionsFromJson(payload, &storage),
            });
            return writeViewJson(info, output);
        }

        pub fn updateViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_view_label_bytes + platform.max_view_role_bytes + platform.max_view_accessibility_label_bytes + platform.max_view_text_bytes + platform.max_view_command_bytes + platform.max_webview_url_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
            const window_id = try viewWindowIdFromJson(payload, source_window_id);
            const patch: platform.ViewPatch = .{
                .frame = try viewFrameFromJson(payload, false),
                .layer = try viewLayerFromJson(payload),
                .visible = jsonBoolField(payload, "visible"),
                .enabled = jsonBoolField(payload, "enabled"),
                .role = jsonStringField(payload, "role", &storage),
                .accessibility_label = jsonStringField(payload, "accessibilityLabel", &storage) orelse jsonStringField(payload, "accessibility_label", &storage),
                .text = jsonStringField(payload, "text", &storage),
                .command = jsonStringField(payload, "command", &storage),
                .url = jsonStringField(payload, "url", &storage),
            };
            const info = try self.updateView(window_id, label, patch);
            return writeViewJson(info, output);
        }

        pub fn setViewFrameFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_view_label_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
            const window_id = try viewWindowIdFromJson(payload, source_window_id);
            const info = try self.updateView(window_id, label, .{ .frame = try viewFrameFromJson(payload, true) });
            return writeViewJson(info, output);
        }

        pub fn setViewVisibleFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_view_label_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
            const visible = jsonBoolField(payload, "visible") orelse return error.InvalidViewOptions;
            const window_id = try viewWindowIdFromJson(payload, source_window_id);
            const info = try self.updateView(window_id, label, .{ .visible = visible });
            return writeViewJson(info, output);
        }

        pub fn focusViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_view_label_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
            const window_id = try viewWindowIdFromJson(payload, source_window_id);
            try self.focusView(window_id, label);
            var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
            for (self.listViews(window_id, &views_buffer)) |view| {
                if (std.mem.eql(u8, view.label, label)) return writeViewJson(view, output);
            }
            return error.ViewNotFound;
        }

        pub fn focusNextViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            const window_id = try viewWindowIdFromJson(payload, source_window_id);
            const info = try self.focusNextView(window_id);
            return writeViewJson(info, output);
        }

        pub fn focusPreviousViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            const window_id = try viewWindowIdFromJson(payload, source_window_id);
            const info = try self.focusPreviousView(window_id);
            return writeViewJson(info, output);
        }

        pub fn closeViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_view_label_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
            const window_id = try viewWindowIdFromJson(payload, source_window_id);
            var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
            for (self.listViews(window_id, &views_buffer)) |view| {
                if (std.mem.eql(u8, view.label, label)) {
                    var closed = view;
                    closed.open = false;
                    closed.focused = false;
                    const result = try writeViewJson(closed, output);
                    try self.closeView(window_id, label);
                    return result;
                }
            }
            return error.ViewNotFound;
        }

        pub fn writeViewListJson(self: *Runtime, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            try WindowViewMethods.validateViewParent(self, source_window_id);
            var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
            const views = self.listViews(source_window_id, &views_buffer);
            var writer = std.Io.Writer.fixed(output);
            try writer.writeByte('[');
            for (views, 0..) |view, index| {
                if (index > 0) try writer.writeByte(',');
                try writeViewJsonToWriter(view, &writer);
            }
            try writer.writeByte(']');
            return writer.buffered();
        }

        pub fn createWebViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_webview_label_bytes + platform.max_webview_url_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse "webview";
            const url = jsonStringField(payload, "url", &storage) orelse return error.MissingWebViewUrl;
            const window_id = try webViewWindowIdFromJson(payload, source_window_id);
            const webview_frame = try webViewFrameFromJson(payload);
            const layer = try webViewLayerFromJson(payload);
            const transparent = jsonBoolField(payload, "transparent") orelse false;
            const bridge_enabled = jsonBoolField(payload, "bridge") orelse false;
            try WindowViewMethods.validateWebViewParent(self, window_id);
            try validateChildWebViewLabel(label);
            try WindowViewMethods.validateWebViewUrl(self, url);
            if (WindowViewMethods.findWebViewIndex(self, window_id, label) != null) return error.DuplicateWebViewLabel;
            if (WindowViewMethods.viewLabelExists(self, window_id, label)) return error.DuplicateViewLabel;
            if (self.webview_count >= platform.max_webviews) return error.WebViewLimitReached;
            try self.options.platform.services.createWebView(.{
                .window_id = window_id,
                .label = label,
                .url = url,
                .frame = webview_frame,
                .layer = layer,
                .transparent = transparent,
                .bridge_enabled = bridge_enabled,
            });
            var reserved = false;
            errdefer {
                if (reserved) {
                    if (WindowViewMethods.findWebViewIndex(self, window_id, label)) |index| WindowViewMethods.removeWebViewAt(self, index);
                }
                self.options.platform.services.closeWebView(window_id, label) catch {};
            }
            try WindowViewMethods.reserveWebView(self, WindowViewMethods.allocateViewId(
                self,
            ), window_id, label, null, url, webview_frame, webview_frame, layer, transparent, bridge_enabled);
            reserved = true;
            return writeWebViewJson(self.webviews[self.webview_count - 1], output);
        }

        pub fn setWebViewFrameFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_webview_label_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse "webview";
            const window_id = try webViewWindowIdFromJson(payload, source_window_id);
            const webview_frame = try webViewFrameFromJson(payload);
            try WindowViewMethods.validateWebViewParent(self, window_id);
            try validateWebViewLabel(label);
            if (isMainWebViewLabel(label)) {
                const window_index = WindowViewMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
                try self.options.platform.services.setWebViewFrame(window_id, label, webview_frame);
                self.windows[window_index].main_frame = webview_frame;
                self.windows[window_index].main_frame_set = true;
                try WindowViewMethods.relayoutDescendantWebViewBackends(self, window_id, label);
                return writeWebViewJson(WindowViewMethods.mainWebViewInfo(self, window_index), output);
            }
            const webview_index = WindowViewMethods.findWebViewIndex(self, window_id, label) orelse return error.WebViewNotFound;
            try self.options.platform.services.setWebViewFrame(window_id, label, webview_frame);
            self.webviews[webview_index].local_frame = try WindowViewMethods.localFrameForView(self, window_id, self.webviews[webview_index].parent, webview_frame);
            self.webviews[webview_index].frame = webview_frame;
            try WindowViewMethods.relayoutDescendantWebViewBackends(self, window_id, label);
            return writeWebViewJson(self.webviews[webview_index], output);
        }

        pub fn navigateWebViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_webview_label_bytes + platform.max_webview_url_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse "webview";
            const url = jsonStringField(payload, "url", &storage) orelse return error.MissingWebViewUrl;
            const window_id = try webViewWindowIdFromJson(payload, source_window_id);
            try WindowViewMethods.validateWebViewParent(self, window_id);
            try validateWebViewLabel(label);
            try WindowViewMethods.validateWebViewUrl(self, url);
            if (isMainWebViewLabel(label)) return error.InvalidWebViewOptions;
            const webview_index = WindowViewMethods.findWebViewIndex(self, window_id, label) orelse return error.WebViewNotFound;
            try self.options.platform.services.navigateWebView(window_id, label, url);
            self.webviews[webview_index].url = try copyInto(&self.webviews[webview_index].url_storage, url);
            return writeWebViewJson(self.webviews[webview_index], output);
        }

        pub fn setWebViewZoomFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_webview_label_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse "webview";
            const zoom_f32 = jsonNumberField(payload, "zoom") orelse return error.InvalidWebViewOptions;
            const zoom: f64 = @floatCast(zoom_f32);
            if (zoom < 0.25 or zoom > 5.0) return error.InvalidWebViewOptions;
            const window_id = try webViewWindowIdFromJson(payload, source_window_id);
            try WindowViewMethods.validateWebViewParent(self, window_id);
            try validateWebViewLabel(label);
            if (isMainWebViewLabel(label)) {
                const window_index = WindowViewMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
                try self.options.platform.services.setWebViewZoom(window_id, label, zoom);
                self.windows[window_index].main_zoom = zoom;
                return writeWebViewJson(WindowViewMethods.mainWebViewInfo(self, window_index), output);
            }
            const webview_index = WindowViewMethods.findWebViewIndex(self, window_id, label) orelse return error.WebViewNotFound;
            try self.options.platform.services.setWebViewZoom(window_id, label, zoom);
            self.webviews[webview_index].zoom = zoom;
            return writeWebViewJson(self.webviews[webview_index], output);
        }

        pub fn setWebViewLayerFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_webview_label_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse "webview";
            const window_id = try webViewWindowIdFromJson(payload, source_window_id);
            try WindowViewMethods.validateWebViewParent(self, window_id);
            try validateWebViewLabel(label);
            const layer = try webViewLayerFromJson(payload);
            if (isMainWebViewLabel(label)) {
                const window_index = WindowViewMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
                try self.options.platform.services.setWebViewLayer(window_id, label, layer);
                self.windows[window_index].main_layer = layer;
                return writeWebViewJson(WindowViewMethods.mainWebViewInfo(self, window_index), output);
            }
            const webview_index = WindowViewMethods.findWebViewIndex(self, window_id, label) orelse return error.WebViewNotFound;
            try self.options.platform.services.setWebViewLayer(window_id, label, layer);
            self.webviews[webview_index].layer = layer;
            return writeWebViewJson(self.webviews[webview_index], output);
        }

        pub fn closeWebViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            var scratch: [platform.max_webview_label_bytes]u8 = undefined;
            var storage = json.StringStorage.init(&scratch);
            const label = jsonStringField(payload, "label", &storage) orelse "webview";
            const window_id = try webViewWindowIdFromJson(payload, source_window_id);
            try WindowViewMethods.validateWebViewParent(self, window_id);
            try validateWebViewLabel(label);
            if (isMainWebViewLabel(label)) return error.InvalidWebViewOptions;
            const webview_index = WindowViewMethods.findWebViewIndex(self, window_id, label) orelse return error.WebViewNotFound;
            var closed_info = self.webviews[webview_index];
            closed_info.open = false;
            closed_info.focused = false;
            const result = try writeWebViewJson(closed_info, output);
            try self.options.platform.services.closeWebView(window_id, label);
            const was_focused = self.webviews[webview_index].focused;
            WindowViewMethods.removeWebViewAt(self, webview_index);
            if (was_focused) WindowViewMethods.ensureFocusableViewFocused(self, window_id);
            return result;
        }

        pub fn focusWindowFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const window_id = try Self.resolveWindowSelector(self, payload, &storage);
            try self.focusWindow(window_id);
            const index = WindowViewMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            return writeWindowJson(self.windows[index].info, output);
        }

        pub fn closeWindowFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
            var storage = json.StringStorage.init(output);
            const window_id = try Self.resolveWindowSelector(self, payload, &storage);
            const index = WindowViewMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            var info = self.windows[index].info;
            info.open = false;
            info.focused = false;
            try self.closeWindow(window_id);
            return writeWindowJson(info, output);
        }

        pub fn resolveWindowSelector(self: *Runtime, payload: []const u8, storage: *json.StringStorage) !platform.WindowId {
            if (jsonIntegerField(payload, "id")) |id| return id;
            if (jsonStringField(payload, "label", storage)) |label| {
                const index = WindowViewMethods.findWindowIndexByLabel(self, label) orelse return error.WindowNotFound;
                return self.windows[index].info.id;
            }
            return error.WindowNotFound;
        }

        pub fn writeWindowListJson(self: *Runtime, output: []u8) ![]const u8 {
            var writer = std.Io.Writer.fixed(output);
            try writer.writeByte('[');
            for (self.windows[0..self.window_count], 0..) |window, index| {
                if (index > 0) try writer.writeByte(',');
                try writeWindowJsonToWriter(window.info, &writer);
            }
            try writer.writeByte(']');
            return writer.buffered();
        }
    };
}
