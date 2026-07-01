const std = @import("std");
const geometry = @import("geometry");
const platform_info = @import("platform_info");
const security = @import("../security/root.zig");
const types = @import("types.zig");

const default_gpu_frame_interval_ns = types.default_gpu_frame_interval_ns;
const default_gpu_first_frame_latency_budget_ns = types.default_gpu_first_frame_latency_budget_ns;
const Error = types.Error;
const WebEngine = types.WebEngine;
const PlatformFeature = types.PlatformFeature;
const WebViewSourceKind = types.WebViewSourceKind;
const WebViewAssetSource = types.WebViewAssetSource;
const WebViewSource = types.WebViewSource;
const WindowId = types.WindowId;
const ViewId = types.ViewId;
const max_windows = types.max_windows;
const max_window_label_bytes = types.max_window_label_bytes;
const max_window_title_bytes = types.max_window_title_bytes;
const max_window_source_bytes = types.max_window_source_bytes;
const max_webviews = types.max_webviews;
const max_webview_label_bytes = types.max_webview_label_bytes;
const max_webview_url_bytes = types.max_webview_url_bytes;
const max_external_url_bytes = types.max_external_url_bytes;
const max_reveal_path_bytes = types.max_reveal_path_bytes;
const max_recent_document_path_bytes = types.max_recent_document_path_bytes;
const max_notification_title_bytes = types.max_notification_title_bytes;
const max_notification_subtitle_bytes = types.max_notification_subtitle_bytes;
const max_notification_body_bytes = types.max_notification_body_bytes;
const max_clipboard_mime_type_bytes = types.max_clipboard_mime_type_bytes;
const max_clipboard_data_bytes = types.max_clipboard_data_bytes;
const max_credential_service_bytes = types.max_credential_service_bytes;
const max_credential_account_bytes = types.max_credential_account_bytes;
const max_credential_secret_bytes = types.max_credential_secret_bytes;
const max_tray_items = types.max_tray_items;
const max_tray_icon_path_bytes = types.max_tray_icon_path_bytes;
const max_tray_tooltip_bytes = types.max_tray_tooltip_bytes;
const max_tray_item_label_bytes = types.max_tray_item_label_bytes;
const max_tray_item_command_bytes = types.max_tray_item_command_bytes;
const max_drop_paths_bytes = types.max_drop_paths_bytes;
const max_drop_paths = types.max_drop_paths;
const max_window_event_name_bytes = types.max_window_event_name_bytes;
const max_window_event_detail_bytes = types.max_window_event_detail_bytes;
const max_views = types.max_views;
const max_view_label_bytes = types.max_view_label_bytes;
const max_view_role_bytes = types.max_view_role_bytes;
const max_view_accessibility_label_bytes = types.max_view_accessibility_label_bytes;
const max_view_text_bytes = types.max_view_text_bytes;
const max_view_command_bytes = types.max_view_command_bytes;
const max_menus = types.max_menus;
const max_menu_items = types.max_menu_items;
const max_menu_title_bytes = types.max_menu_title_bytes;
const max_menu_item_label_bytes = types.max_menu_item_label_bytes;
const max_menu_command_bytes = types.max_menu_command_bytes;
const max_menu_key_bytes = types.max_menu_key_bytes;
const max_shortcuts = types.max_shortcuts;
const max_shortcut_id_bytes = types.max_shortcut_id_bytes;
const max_shortcut_key_bytes = types.max_shortcut_key_bytes;
const max_widget_accessibility_nodes = types.max_widget_accessibility_nodes;
const max_gpu_surface_packet_json_bytes = types.max_gpu_surface_packet_json_bytes;
const ShortcutModifiers = types.ShortcutModifiers;
const Shortcut = types.Shortcut;
const ShortcutEvent = types.ShortcutEvent;
const Menu = types.Menu;
const MenuItem = types.MenuItem;
const validateShortcut = types.validateShortcut;
const validateMenus = types.validateMenus;
const validateMenuItem = types.validateMenuItem;
const isValidShortcutKey = types.isValidShortcutKey;
const WindowRestorePolicy = types.WindowRestorePolicy;
const WindowOptions = types.WindowOptions;
const WindowState = types.WindowState;
const WindowInfo = types.WindowInfo;
const WindowCreateOptions = types.WindowCreateOptions;
const WebViewOptions = types.WebViewOptions;
const WebViewInfo = types.WebViewInfo;
const ViewKind = types.ViewKind;
const GpuSurfaceBackend = types.GpuSurfaceBackend;
const GpuSurfacePixelFormat = types.GpuSurfacePixelFormat;
const GpuSurfacePresentMode = types.GpuSurfacePresentMode;
const GpuSurfaceAlphaMode = types.GpuSurfaceAlphaMode;
const GpuSurfaceColorSpace = types.GpuSurfaceColorSpace;
const GpuSurfaceStatus = types.GpuSurfaceStatus;
const CanvasFrameProfileRisk = types.CanvasFrameProfileRisk;
const GpuSurfaceOptions = types.GpuSurfaceOptions;
const ViewOptions = types.ViewOptions;
const ViewPatch = types.ViewPatch;
const Cursor = types.Cursor;
const ViewInfo = types.ViewInfo;
const AppInfo = types.AppInfo;
const Surface = types.Surface;
const BridgeMessage = types.BridgeMessage;
const max_dialog_path_bytes = types.max_dialog_path_bytes;
const max_dialog_paths_bytes = types.max_dialog_paths_bytes;
const max_dialog_title_bytes = types.max_dialog_title_bytes;
const max_dialog_message_bytes = types.max_dialog_message_bytes;
const max_dialog_button_bytes = types.max_dialog_button_bytes;
const max_dialog_filter_name_bytes = types.max_dialog_filter_name_bytes;
const max_dialog_filter_bytes = types.max_dialog_filter_bytes;
const FileFilter = types.FileFilter;
const OpenDialogOptions = types.OpenDialogOptions;
const OpenDialogResult = types.OpenDialogResult;
const SaveDialogOptions = types.SaveDialogOptions;
const MessageDialogStyle = types.MessageDialogStyle;
const MessageDialogResult = types.MessageDialogResult;
const MessageDialogOptions = types.MessageDialogOptions;
const NotificationOptions = types.NotificationOptions;
const CredentialKey = types.CredentialKey;
const Credential = types.Credential;
const TrayItemId = types.TrayItemId;
const TrayOptions = types.TrayOptions;
const TrayMenuItem = types.TrayMenuItem;
const NativeCommandEvent = types.NativeCommandEvent;
const MenuCommandEvent = types.MenuCommandEvent;
const FileDropEvent = types.FileDropEvent;
const GpuFrame = types.GpuFrame;
const GpuSurfaceFrameEvent = types.GpuSurfaceFrameEvent;
const GpuSurfaceResizeEvent = types.GpuSurfaceResizeEvent;
const GpuSurfaceInputKind = types.GpuSurfaceInputKind;
const GpuSurfaceInputEvent = types.GpuSurfaceInputEvent;
const GpuSurfacePixels = types.GpuSurfacePixels;
const GpuSurfacePacket = types.GpuSurfacePacket;
const WidgetAccessibilityRole = types.WidgetAccessibilityRole;
const WidgetAccessibilityActions = types.WidgetAccessibilityActions;
const WidgetAccessibilityTextRange = types.WidgetAccessibilityTextRange;
const WidgetAccessibilityNode = types.WidgetAccessibilityNode;
const WidgetAccessibilitySnapshot = types.WidgetAccessibilitySnapshot;
const WidgetAccessibilityActionKind = types.WidgetAccessibilityActionKind;
const WidgetAccessibilityActionEvent = types.WidgetAccessibilityActionEvent;
const ClipboardData = types.ClipboardData;
const ColorScheme = types.ColorScheme;
const Appearance = types.Appearance;
const Event = types.Event;
const splitDropPaths = types.splitDropPaths;
const EventHandler = types.EventHandler;
const PlatformServices = types.PlatformServices;
const Platform = types.Platform;
const Backend = types.Backend;
pub const NullPlatform = struct {
    surface_value: Surface = .{},
    web_engine: WebEngine = .system,
    app_info: AppInfo = .{},
    gpu_surfaces: bool = false,
    gpu_surface_packets: bool = true,
    requested_frames: u32 = 1,
    loaded_source: ?WebViewSource = null,
    security_policy: security.Policy = .{},
    menus: [max_menus]Menu = undefined,
    menu_items: [max_menu_items]MenuItem = undefined,
    menu_count: usize = 0,
    menu_item_count: usize = 0,
    shortcuts: [max_shortcuts]Shortcut = undefined,
    shortcut_count: usize = 0,
    window_sources: [max_windows]?WebViewSource = [_]?WebViewSource{null} ** max_windows,
    windows: [max_windows]WindowInfo = undefined,
    window_count: usize = 0,
    views: [max_views]NullView = undefined,
    view_count: usize = 0,
    webviews: [max_webviews]NullWebView = undefined,
    webview_count: usize = 0,
    bridge_response: [16 * 1024]u8 = undefined,
    bridge_response_len: usize = 0,
    bridge_response_window_id: WindowId = 0,
    bridge_response_webview_label: []const u8 = "main",
    external_url: [max_external_url_bytes]u8 = undefined,
    external_url_len: usize = 0,
    revealed_path: [max_reveal_path_bytes]u8 = undefined,
    revealed_path_len: usize = 0,
    recent_document_path: [max_recent_document_path_bytes]u8 = undefined,
    recent_document_path_len: usize = 0,
    recent_documents_cleared_count: usize = 0,
    open_dialog_count: usize = 0,
    save_dialog_count: usize = 0,
    message_dialog_count: usize = 0,
    message_dialog_result: MessageDialogResult = .primary,
    notification_title: [max_notification_title_bytes]u8 = undefined,
    notification_title_len: usize = 0,
    notification_subtitle: [max_notification_subtitle_bytes]u8 = undefined,
    notification_subtitle_len: usize = 0,
    notification_body: [max_notification_body_bytes]u8 = undefined,
    notification_body_len: usize = 0,
    notification_count: usize = 0,
    clipboard_mime_type: [max_clipboard_mime_type_bytes]u8 = undefined,
    clipboard_mime_type_len: usize = 0,
    clipboard_data: [max_clipboard_data_bytes]u8 = undefined,
    clipboard_data_len: usize = 0,
    clipboard_write_count: usize = 0,
    credential_service: [max_credential_service_bytes]u8 = undefined,
    credential_service_len: usize = 0,
    credential_account: [max_credential_account_bytes]u8 = undefined,
    credential_account_len: usize = 0,
    credential_secret: [max_credential_secret_bytes]u8 = undefined,
    credential_secret_len: usize = 0,
    credential_set_count: usize = 0,
    credential_delete_count: usize = 0,
    tray_icon_path: [max_tray_icon_path_bytes]u8 = undefined,
    tray_icon_path_len: usize = 0,
    tray_tooltip: [max_tray_tooltip_bytes]u8 = undefined,
    tray_tooltip_len: usize = 0,
    tray_items: [max_tray_items]TrayMenuItem = undefined,
    tray_item_count: usize = 0,
    tray_create_count: usize = 0,
    tray_update_count: usize = 0,
    tray_remove_count: usize = 0,
    window_event_window_id: WindowId = 0,
    window_event_name: [max_window_event_name_bytes]u8 = undefined,
    window_event_name_len: usize = 0,
    window_event_detail: [max_window_event_detail_bytes]u8 = undefined,
    window_event_detail_len: usize = 0,
    window_event_count: usize = 0,
    gpu_surface_present_window_id: WindowId = 0,
    gpu_surface_present_label_storage: [max_view_label_bytes]u8 = undefined,
    gpu_surface_present_label_len: usize = 0,
    gpu_surface_present_width: usize = 0,
    gpu_surface_present_height: usize = 0,
    gpu_surface_present_scale_factor: f32 = 1,
    gpu_surface_present_dirty_bounds: ?geometry.RectF = null,
    gpu_surface_present_byte_len: usize = 0,
    gpu_surface_present_sample_rgba: [4]u8 = .{ 0, 0, 0, 0 },
    gpu_surface_present_count: usize = 0,
    gpu_surface_packet_present_window_id: WindowId = 0,
    gpu_surface_packet_present_label_storage: [max_view_label_bytes]u8 = undefined,
    gpu_surface_packet_present_label_len: usize = 0,
    gpu_surface_packet_present_frame_index: u64 = 0,
    gpu_surface_packet_present_timestamp_ns: u64 = 0,
    gpu_surface_packet_present_surface_size: geometry.SizeF = .{},
    gpu_surface_packet_present_scale_factor: f32 = 1,
    gpu_surface_packet_present_clear_color_rgba8: [4]u8 = .{ 0, 0, 0, 255 },
    gpu_surface_packet_present_requires_render: bool = false,
    gpu_surface_packet_present_command_count: usize = 0,
    gpu_surface_packet_present_cache_action_count: usize = 0,
    gpu_surface_packet_present_cached_resource_command_count: usize = 0,
    gpu_surface_packet_present_unsupported_command_count: usize = 0,
    gpu_surface_packet_present_representable: bool = true,
    gpu_surface_packet_present_json_len: usize = 0,
    gpu_surface_packet_present_count: usize = 0,
    gpu_surface_frame_request_window_id: WindowId = 0,
    gpu_surface_frame_request_label_storage: [max_view_label_bytes]u8 = undefined,
    gpu_surface_frame_request_label_len: usize = 0,
    gpu_surface_frame_request_count: usize = 0,
    view_cursor_window_id: WindowId = 0,
    view_cursor_label_storage: [max_view_label_bytes]u8 = undefined,
    view_cursor_label_len: usize = 0,
    view_cursor: Cursor = .arrow,
    view_cursor_count: usize = 0,

    pub fn init(surface_value: Surface) NullPlatform {
        return .{ .surface_value = surface_value };
    }

    pub fn initWithEngine(surface_value: Surface, web_engine: WebEngine) NullPlatform {
        return .{ .surface_value = surface_value, .web_engine = web_engine };
    }

    pub fn initWithOptions(surface_value: Surface, web_engine: WebEngine, app_info: AppInfo) NullPlatform {
        return .{ .surface_value = surface_value, .web_engine = web_engine, .app_info = app_info };
    }

    pub fn platform(self: *NullPlatform) Platform {
        return .{
            .context = self,
            .name = "null",
            .surface_value = self.surface_value,
            .run_fn = run,
            .supports_fn = supportsFeature,
            .services = .{
                .context = self,
                .read_clipboard_fn = readClipboard,
                .write_clipboard_fn = writeClipboard,
                .read_clipboard_data_fn = readClipboardData,
                .write_clipboard_data_fn = writeClipboardData,
                .load_webview_fn = loadWebView,
                .load_window_webview_fn = loadWindowWebView,
                .complete_bridge_fn = completeBridge,
                .complete_window_bridge_fn = completeWindowBridge,
                .complete_webview_bridge_fn = completeWebViewBridge,
                .create_window_fn = createWindow,
                .focus_window_fn = focusWindow,
                .close_window_fn = closeWindow,
                .create_view_fn = createView,
                .update_view_fn = updateView,
                .set_view_frame_fn = setViewFrame,
                .set_view_visible_fn = setViewVisible,
                .set_view_cursor_fn = setViewCursor,
                .focus_view_fn = focusView,
                .close_view_fn = closeView,
                .create_webview_fn = createWebView,
                .set_webview_frame_fn = setWebViewFrame,
                .navigate_webview_fn = navigateWebView,
                .set_webview_zoom_fn = setWebViewZoom,
                .set_webview_layer_fn = setWebViewLayer,
                .close_webview_fn = closeWebView,
                .show_open_dialog_fn = showOpenDialog,
                .show_save_dialog_fn = showSaveDialog,
                .show_message_dialog_fn = showMessageDialog,
                .show_notification_fn = showNotification,
                .set_credential_fn = setCredential,
                .get_credential_fn = getCredential,
                .delete_credential_fn = deleteCredential,
                .create_tray_fn = createTray,
                .update_tray_menu_fn = updateTrayMenu,
                .remove_tray_fn = removeTray,
                .open_external_url_fn = openExternalUrl,
                .reveal_path_fn = revealPath,
                .add_recent_document_fn = addRecentDocument,
                .clear_recent_documents_fn = clearRecentDocuments,
                .configure_security_policy_fn = configureSecurityPolicy,
                .configure_menus_fn = configureMenus,
                .configure_shortcuts_fn = configureShortcuts,
                .emit_window_event_fn = emitWindowEvent,
                .request_gpu_surface_frame_fn = requestGpuSurfaceFrame,
                .present_gpu_surface_pixels_fn = presentGpuSurfacePixels,
                .present_gpu_surface_packet_fn = presentGpuSurfacePacket,
            },
            .app_info = self.app_info,
        };
    }

    fn supportsFeature(context: *anyopaque, feature: PlatformFeature) bool {
        const self: *NullPlatform = @ptrCast(@alignCast(context));
        return switch (feature) {
            .main_webview,
            .child_webviews,
            .native_views,
            .native_control_commands,
            .menus,
            .shortcuts,
            .dialogs,
            .clipboard_text,
            .clipboard_rich_data,
            .open_url,
            .reveal_path,
            .notifications,
            .recent_documents,
            .credentials,
            .file_drops,
            .app_activation_events,
            => true,
            .gpu_surfaces => self.gpu_surfaces,
            .tray => self.web_engine == .system,
        };
    }

    pub fn hostInfo(self: NullPlatform) platform_info.HostInfo {
        _ = self;
        const target = platform_info.Target.current();
        return platform_info.detectHost(.{ .target = target });
    }

    fn run(context: *anyopaque, handler: EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context));
        try handler(handler_context, .app_start);
        try handler(handler_context, .{ .appearance_changed = .{} });
        try handler(handler_context, .{ .surface_resized = self.surface_value });
        const count = self.app_info.startupWindowCount();
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const window = self.app_info.resolvedStartupWindow(index);
            try handler(handler_context, .{ .window_frame_changed = .{
                .id = window.id,
                .label = window.label,
                .title = window.resolvedTitle(self.app_info.app_name),
                .frame = window.default_frame,
                .scale_factor = self.surface_value.scale_factor,
                .open = true,
                .focused = index == 0,
            } });
        }
        var frame: u32 = 0;
        while (frame < self.requested_frames) : (frame += 1) {
            try handler(handler_context, .frame_requested);
        }
        try handler(handler_context, .app_shutdown);
    }

    fn loadWebView(context: ?*anyopaque, source: WebViewSource) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.loaded_source = source;
        self.window_sources[0] = source;
    }

    fn readClipboard(context: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
        return readClipboardData(context, "text/plain", buffer);
    }

    fn writeClipboard(context: ?*anyopaque, text: []const u8) anyerror!void {
        try writeClipboardData(context, .{ .mime_type = "text/plain", .bytes = text });
    }

    fn readClipboardData(context: ?*anyopaque, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, mime_type, self.lastClipboardMimeType())) return error.UnsupportedService;
        return try copyInto(buffer, self.lastClipboardData());
    }

    fn writeClipboardData(context: ?*anyopaque, data: ClipboardData) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.clipboard_mime_type = undefined;
        self.clipboard_data = undefined;
        self.clipboard_mime_type_len = (try copyInto(&self.clipboard_mime_type, data.mime_type)).len;
        self.clipboard_data_len = (try copyInto(&self.clipboard_data, data.bytes)).len;
        self.clipboard_write_count += 1;
    }

    fn loadWindowWebView(context: ?*anyopaque, window_id: WindowId, source: WebViewSource) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (window_id == 1) self.loaded_source = source;
        const index = self.findWindowIndex(window_id) orelse if (window_id == 1 and self.window_count == 0) blk: {
            self.windows[0] = .{
                .id = 1,
                .label = "main",
                .title = self.app_info.resolvedWindowTitle(),
                .frame = geometry.RectF.fromSize(self.surface_value.size),
                .scale_factor = self.surface_value.scale_factor,
                .open = true,
                .focused = true,
            };
            self.window_count = 1;
            break :blk 0;
        } else return error.WindowNotFound;
        if (index >= self.window_sources.len) return error.WindowNotFound;
        self.window_sources[index] = source;
    }

    fn completeBridge(context: ?*anyopaque, response: []const u8) anyerror!void {
        try recordBridgeResponse(context, 1, "main", response);
    }

    fn completeWindowBridge(context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void {
        try recordBridgeResponse(context, window_id, "main", response);
    }

    fn completeWebViewBridge(context: ?*anyopaque, window_id: WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
        try recordBridgeResponse(context, window_id, webview_label, response);
    }

    fn recordBridgeResponse(context: ?*anyopaque, window_id: WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const count = @min(response.len, self.bridge_response.len);
        @memcpy(self.bridge_response[0..count], response[0..count]);
        self.bridge_response_len = count;
        self.bridge_response_window_id = window_id;
        self.bridge_response_webview_label = webview_label;
    }

    fn createWindow(context: ?*anyopaque, options: WindowOptions) anyerror!WindowInfo {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (self.window_count >= max_windows) return error.WindowLimitReached;
        for (self.windows[0..self.window_count]) |window| {
            if (window.id == options.id) return error.DuplicateWindowId;
            if (std.mem.eql(u8, window.label, options.label)) return error.DuplicateWindowLabel;
        }
        const info: WindowInfo = .{
            .id = options.id,
            .label = options.label,
            .title = options.resolvedTitle(self.app_info.app_name),
            .frame = options.default_frame,
            .scale_factor = self.surface_value.scale_factor,
            .open = true,
            .focused = false,
        };
        self.windows[self.window_count] = info;
        self.window_count += 1;
        return info;
    }

    fn focusWindow(context: ?*anyopaque, window_id: WindowId) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const focused_index = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
        for (self.windows[0..self.window_count], 0..) |*window, index| {
            window.focused = index == focused_index;
        }
    }

    fn closeWindow(context: ?*anyopaque, window_id: WindowId) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
        self.windows[index].open = false;
        self.windows[index].focused = false;
        self.removeViewsForWindow(window_id);
        self.removeWebViewsForWindow(window_id);
    }

    fn createView(context: ?*anyopaque, options: ViewOptions) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (options.kind == .webview) return createWebView(context, options.webViewOptions());
        if (options.kind == .gpu_surface and !self.gpu_surfaces) return error.UnsupportedViewKind;
        try self.validateViewOptions(options);
        if (self.findViewIndex(options.window_id, options.label) != null) return error.DuplicateViewLabel;
        if (self.view_count >= max_views) return error.ViewLimitReached;
        const index = self.view_count;
        self.view_count += 1;
        self.views[index] = .{
            .window_id = options.window_id,
            .kind = options.kind,
            .frame = options.frame,
            .layer = options.layer,
            .visible = options.visible,
            .enabled = options.enabled,
            .gpu_size = if (options.kind == .gpu_surface) options.frame.size() else geometry.SizeF.init(0, 0),
            .gpu_backend = if (options.kind == .gpu_surface) options.gpu_surface.backend else .none,
            .gpu_pixel_format = if (options.kind == .gpu_surface) options.gpu_surface.pixel_format else .none,
            .gpu_present_mode = if (options.kind == .gpu_surface) options.gpu_surface.present_mode else .none,
            .gpu_alpha_mode = if (options.kind == .gpu_surface) options.gpu_surface.alpha_mode else .none,
            .gpu_color_space = if (options.kind == .gpu_surface) options.gpu_surface.color_space else .none,
            .gpu_vsync = options.kind == .gpu_surface and options.gpu_surface.vsync,
            .gpu_status = if (options.kind == .gpu_surface) .ready else .unavailable,
            .open = true,
        };
        try self.copyViewStrings(index, options.label, options.parent, options.role, options.accessibility_label, options.text, options.command);
    }

    fn updateView(context: ?*anyopaque, window_id: WindowId, label: []const u8, patch: ViewPatch) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (patch.frame) |frame| {
            if (!isValidViewFrame(frame)) return error.InvalidViewOptions;
            self.views[index].frame = frame;
        }
        if (patch.layer) |layer| self.views[index].layer = layer;
        if (patch.visible) |visible| self.views[index].visible = visible;
        if (patch.enabled) |enabled| self.views[index].enabled = enabled;
        if (patch.role) |role| {
            if (role.len > max_view_role_bytes) return error.ViewRoleTooLarge;
            self.views[index].role = try copyInto(&self.views[index].role_storage, role);
        }
        if (patch.accessibility_label) |accessibility_label| {
            if (accessibility_label.len > max_view_accessibility_label_bytes) return error.ViewAccessibilityLabelTooLarge;
            self.views[index].accessibility_label = try copyInto(&self.views[index].accessibility_label_storage, accessibility_label);
        }
        if (patch.text) |text| {
            if (text.len > max_view_text_bytes) return error.ViewTextTooLarge;
            self.views[index].text = try copyInto(&self.views[index].text_storage, text);
        }
        if (patch.command) |command| {
            if (command.len > max_view_command_bytes) return error.InvalidCommand;
            self.views[index].command = try copyInto(&self.views[index].command_storage, command);
        }
        if (patch.url != null) return error.InvalidViewOptions;
    }

    fn setViewFrame(context: ?*anyopaque, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (!isValidViewFrame(frame)) return error.InvalidViewOptions;
        self.views[index].frame = frame;
    }

    fn setViewVisible(context: ?*anyopaque, window_id: WindowId, label: []const u8, visible: bool) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        self.views[index].visible = visible;
    }

    fn setViewCursor(context: ?*anyopaque, window_id: WindowId, label: []const u8, cursor: Cursor) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.UnsupportedViewKind;
        self.view_cursor_window_id = window_id;
        self.view_cursor_label_storage = undefined;
        self.view_cursor_label_len = (try copyInto(&self.view_cursor_label_storage, label)).len;
        self.view_cursor = cursor;
        self.view_cursor_count += 1;
    }

    fn focusView(context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, label, "main")) {
            if (self.findWindowIndex(window_id)) |window_index| {
                if (!self.windows[window_index].open) return error.WindowNotFound;
            } else if (window_id != 1) {
                return error.WindowNotFound;
            }
            return;
        }
        if (self.findWebViewIndex(window_id, label) != null) return;
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (!self.views[index].enabled or !self.views[index].visible) return error.UnsupportedViewFocus;
    }

    fn closeView(context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        var label_storage: [max_view_label_bytes]u8 = undefined;
        const view_label = copyInto(&label_storage, self.views[index].label) catch unreachable;
        self.removeChildViewsForParent(window_id, view_label);
        if (self.findViewIndex(window_id, view_label)) |current_index| self.removeViewAt(current_index);
    }

    fn createWebView(context: ?*anyopaque, options: WebViewOptions) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (self.findWindowIndex(options.window_id)) |window_index| {
            if (!self.windows[window_index].open) return error.WindowNotFound;
        } else if (options.window_id != 1) {
            return error.WindowNotFound;
        }
        if (options.label.len == 0) return error.InvalidWebViewOptions;
        if (options.url.len == 0) return error.MissingWebViewUrl;
        if (options.label.len > max_webview_label_bytes) return error.WebViewLabelTooLarge;
        if (options.url.len > max_webview_url_bytes) return error.WebViewUrlTooLarge;
        if (!isValidWebViewFrame(options.frame)) return error.InvalidWebViewOptions;
        if (self.findWebViewIndex(options.window_id, options.label) != null) return error.DuplicateWebViewLabel;
        if (self.webview_count >= max_webviews) return error.WebViewLimitReached;
        const index = self.webview_count;
        self.webview_count += 1;
        var webview = &self.webviews[index];
        webview.window_id = options.window_id;
        webview.frame = options.frame;
        webview.layer = options.layer;
        webview.transparent = options.transparent;
        webview.bridge_enabled = options.bridge_enabled;
        webview.open = true;
        @memcpy(webview.label_storage[0..options.label.len], options.label);
        @memcpy(webview.url_storage[0..options.url.len], options.url);
        webview.label = webview.label_storage[0..options.label.len];
        webview.url = webview.url_storage[0..options.url.len];
    }

    fn setWebViewFrame(context: ?*anyopaque, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, label, "main")) {
            _ = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
            if (!isValidWebViewFrame(frame)) return error.InvalidWebViewOptions;
            return;
        }
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        if (!isValidWebViewFrame(frame)) return error.InvalidWebViewOptions;
        self.webviews[index].frame = frame;
    }

    fn navigateWebView(context: ?*anyopaque, window_id: WindowId, label: []const u8, url: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        if (url.len == 0) return error.MissingWebViewUrl;
        if (url.len > max_webview_url_bytes) return error.WebViewUrlTooLarge;
        var webview = &self.webviews[index];
        @memcpy(webview.url_storage[0..url.len], url);
        webview.url = webview.url_storage[0..url.len];
    }

    fn setWebViewZoom(context: ?*anyopaque, window_id: WindowId, label: []const u8, zoom: f64) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, label, "main")) {
            _ = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
            if (zoom < 0.25 or zoom > 5.0) return error.InvalidWebViewOptions;
            return;
        }
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        if (zoom < 0.25 or zoom > 5.0) return error.InvalidWebViewOptions;
        self.webviews[index].zoom = zoom;
    }

    fn setWebViewLayer(context: ?*anyopaque, window_id: WindowId, label: []const u8, layer: i32) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, label, "main")) {
            _ = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
            return;
        }
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        self.webviews[index].layer = layer;
    }

    fn closeWebView(context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        self.removeWebViewAt(index);
    }

    fn showOpenDialog(context: ?*anyopaque, options: OpenDialogOptions, buffer: []u8) anyerror!OpenDialogResult {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        _ = options;
        const path = "/tmp/zero-native-open.txt";
        const copied = try copyInto(buffer, path);
        self.open_dialog_count += 1;
        return .{ .count = 1, .paths = copied };
    }

    fn showSaveDialog(context: ?*anyopaque, options: SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const path = if (options.default_name.len > 0) options.default_name else "/tmp/zero-native-save.txt";
        const copied = try copyInto(buffer, path);
        self.save_dialog_count += 1;
        return copied;
    }

    fn showMessageDialog(context: ?*anyopaque, options: MessageDialogOptions) anyerror!MessageDialogResult {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        _ = options;
        self.message_dialog_count += 1;
        return self.message_dialog_result;
    }

    fn showNotification(context: ?*anyopaque, options: NotificationOptions) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.notification_title = undefined;
        self.notification_subtitle = undefined;
        self.notification_body = undefined;
        self.notification_title_len = (try copyInto(&self.notification_title, options.title)).len;
        self.notification_subtitle_len = (try copyInto(&self.notification_subtitle, options.subtitle)).len;
        self.notification_body_len = (try copyInto(&self.notification_body, options.body)).len;
        self.notification_count += 1;
    }

    fn setCredential(context: ?*anyopaque, credential: Credential) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.credential_service = undefined;
        self.credential_account = undefined;
        self.credential_secret = undefined;
        self.credential_service_len = (try copyInto(&self.credential_service, credential.service)).len;
        self.credential_account_len = (try copyInto(&self.credential_account, credential.account)).len;
        self.credential_secret_len = (try copyInto(&self.credential_secret, credential.secret)).len;
        self.credential_set_count += 1;
    }

    fn getCredential(context: ?*anyopaque, key: CredentialKey, buffer: []u8) anyerror![]const u8 {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (self.credential_secret_len == 0) return error.CredentialNotFound;
        if (!std.mem.eql(u8, key.service, self.lastCredentialService()) or !std.mem.eql(u8, key.account, self.lastCredentialAccount())) return error.CredentialNotFound;
        return try copyInto(buffer, self.lastCredentialSecret());
    }

    fn deleteCredential(context: ?*anyopaque, key: CredentialKey) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (self.credential_secret_len == 0) return error.CredentialNotFound;
        if (!std.mem.eql(u8, key.service, self.lastCredentialService()) or !std.mem.eql(u8, key.account, self.lastCredentialAccount())) return error.CredentialNotFound;
        self.credential_secret_len = 0;
        self.credential_delete_count += 1;
    }

    fn createTray(context: ?*anyopaque, options: TrayOptions) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.tray_icon_path = undefined;
        self.tray_tooltip = undefined;
        self.tray_icon_path_len = (try copyInto(&self.tray_icon_path, options.icon_path)).len;
        self.tray_tooltip_len = (try copyInto(&self.tray_tooltip, options.tooltip)).len;
        try updateTrayMenu(context, options.items);
        self.tray_create_count += 1;
    }

    fn updateTrayMenu(context: ?*anyopaque, items: []const TrayMenuItem) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (items.len > self.tray_items.len) return error.InvalidTrayOptions;
        for (items, 0..) |item, index| self.tray_items[index] = item;
        self.tray_item_count = items.len;
        self.tray_update_count += 1;
    }

    fn removeTray(context: ?*anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.tray_item_count = 0;
        self.tray_remove_count += 1;
    }

    fn openExternalUrl(context: ?*anyopaque, url: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.external_url = undefined;
        self.external_url_len = 0;
        self.external_url_len = (try copyInto(&self.external_url, url)).len;
    }

    fn revealPath(context: ?*anyopaque, path: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.revealed_path = undefined;
        self.revealed_path_len = 0;
        self.revealed_path_len = (try copyInto(&self.revealed_path, path)).len;
    }

    fn addRecentDocument(context: ?*anyopaque, path: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.recent_document_path = undefined;
        self.recent_document_path_len = 0;
        self.recent_document_path_len = (try copyInto(&self.recent_document_path, path)).len;
    }

    fn clearRecentDocuments(context: ?*anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.recent_document_path_len = 0;
        self.recent_documents_cleared_count += 1;
    }

    fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.security_policy = policy;
    }

    fn configureMenus(context: ?*anyopaque, menus: []const Menu) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        try validateMenus(menus);
        self.menu_count = 0;
        self.menu_item_count = 0;
        for (menus) |menu| {
            const start = self.menu_item_count;
            for (menu.items) |item| {
                self.menu_items[self.menu_item_count] = item;
                self.menu_item_count += 1;
            }
            const end = self.menu_item_count;
            self.menus[self.menu_count] = .{
                .title = menu.title,
                .items = self.menu_items[start..end],
            };
            self.menu_count += 1;
        }
    }

    fn configureShortcuts(context: ?*anyopaque, shortcuts: []const Shortcut) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (shortcuts.len > self.shortcuts.len) return error.InvalidShortcut;
        for (shortcuts, 0..) |shortcut, index| {
            try validateShortcut(shortcut);
            self.shortcuts[index] = shortcut;
        }
        self.shortcut_count = shortcuts.len;
    }

    fn emitWindowEvent(context: ?*anyopaque, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.window_event_name = undefined;
        self.window_event_detail = undefined;
        self.window_event_window_id = window_id;
        self.window_event_name_len = (try copyInto(&self.window_event_name, name)).len;
        self.window_event_detail_len = (try copyInto(&self.window_event_detail, detail_json)).len;
        self.window_event_count += 1;
    }

    fn presentGpuSurfacePixels(context: ?*anyopaque, pixels: GpuSurfacePixels) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surfaces) return error.UnsupportedService;
        const view_index = self.findViewIndex(pixels.window_id, pixels.label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidGpuSurfacePixels;
        const expected = pixels.expectedByteLen() orelse return error.InvalidGpuSurfacePixels;
        if (pixels.rgba8.len != expected) return error.InvalidGpuSurfacePixels;

        self.gpu_surface_present_window_id = pixels.window_id;
        self.gpu_surface_present_label_storage = undefined;
        self.gpu_surface_present_label_len = (try copyInto(&self.gpu_surface_present_label_storage, pixels.label)).len;
        self.gpu_surface_present_width = pixels.width;
        self.gpu_surface_present_height = pixels.height;
        self.gpu_surface_present_scale_factor = pixels.scale_factor;
        self.gpu_surface_present_dirty_bounds = pixels.dirty_bounds;
        self.gpu_surface_present_byte_len = pixels.rgba8.len;
        self.gpu_surface_present_sample_rgba = if (pixels.rgba8.len >= 4)
            .{ pixels.rgba8[0], pixels.rgba8[1], pixels.rgba8[2], pixels.rgba8[3] }
        else
            .{ 0, 0, 0, 0 };
        self.gpu_surface_present_count += 1;
    }

    fn requestGpuSurfaceFrame(context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surfaces) return error.UnsupportedService;
        const view_index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;

        self.gpu_surface_frame_request_window_id = window_id;
        self.gpu_surface_frame_request_label_storage = undefined;
        self.gpu_surface_frame_request_label_len = (try copyInto(&self.gpu_surface_frame_request_label_storage, label)).len;
        self.gpu_surface_frame_request_count += 1;
    }

    fn presentGpuSurfacePacket(context: ?*anyopaque, packet: GpuSurfacePacket) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surfaces) return error.UnsupportedService;
        if (!self.gpu_surface_packets) return error.UnsupportedService;
        const view_index = self.findViewIndex(packet.window_id, packet.label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidGpuSurfacePacket;
        if (packet.json.len == 0 or packet.json.len > max_gpu_surface_packet_json_bytes) return error.InvalidGpuSurfacePacket;

        self.gpu_surface_packet_present_window_id = packet.window_id;
        self.gpu_surface_packet_present_label_storage = undefined;
        self.gpu_surface_packet_present_label_len = (try copyInto(&self.gpu_surface_packet_present_label_storage, packet.label)).len;
        self.gpu_surface_packet_present_frame_index = packet.frame_index;
        self.gpu_surface_packet_present_timestamp_ns = packet.timestamp_ns;
        self.gpu_surface_packet_present_surface_size = packet.surface_size;
        self.gpu_surface_packet_present_scale_factor = packet.scale_factor;
        self.gpu_surface_packet_present_clear_color_rgba8 = packet.clear_color_rgba8;
        self.gpu_surface_packet_present_requires_render = packet.requires_render;
        self.gpu_surface_packet_present_command_count = packet.command_count;
        self.gpu_surface_packet_present_cache_action_count = packet.cache_action_count;
        self.gpu_surface_packet_present_cached_resource_command_count = packet.cached_resource_command_count;
        self.gpu_surface_packet_present_unsupported_command_count = packet.unsupported_command_count;
        self.gpu_surface_packet_present_representable = packet.representable;
        self.gpu_surface_packet_present_json_len = packet.json.len;
        self.gpu_surface_packet_present_count += 1;
    }

    fn findWindowIndex(self: *const NullPlatform, window_id: WindowId) ?usize {
        for (self.windows[0..self.window_count], 0..) |window, index| {
            if (window.id == window_id) return index;
        }
        return null;
    }

    fn findWebViewIndex(self: *const NullPlatform, window_id: WindowId, label: []const u8) ?usize {
        for (self.webviews[0..self.webview_count], 0..) |webview, index| {
            if (webview.open and webview.window_id == window_id and std.mem.eql(u8, webview.label, label)) return index;
        }
        return null;
    }

    fn findViewIndex(self: *const NullPlatform, window_id: WindowId, label: []const u8) ?usize {
        for (self.views[0..self.view_count], 0..) |view, index| {
            if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
        }
        return null;
    }

    fn validateViewOptions(self: *const NullPlatform, options: ViewOptions) !void {
        if (self.findWindowIndex(options.window_id)) |window_index| {
            if (!self.windows[window_index].open) return error.WindowNotFound;
        } else if (options.window_id != 1) {
            return error.WindowNotFound;
        }
        if (options.label.len == 0) return error.InvalidViewOptions;
        if (options.label.len > max_view_label_bytes) return error.ViewLabelTooLarge;
        if (options.role.len > max_view_role_bytes) return error.ViewRoleTooLarge;
        if (options.accessibility_label.len > max_view_accessibility_label_bytes) return error.ViewAccessibilityLabelTooLarge;
        if (options.text.len > max_view_text_bytes) return error.ViewTextTooLarge;
        if (options.command.len > max_view_command_bytes) return error.InvalidCommand;
        if (!isValidViewFrame(options.frame)) return error.InvalidViewOptions;
        if (options.url.len > 0) return error.InvalidViewOptions;
        if (options.kind == .gpu_surface and !options.gpu_surface.isSupported()) return error.UnsupportedViewKind;
        if (options.parent) |parent| {
            if (parent.len == 0 or parent.len > max_view_label_bytes) return error.InvalidViewOptions;
            if (std.mem.eql(u8, parent, options.label)) return error.InvalidViewOptions;
            if (!std.mem.eql(u8, parent, "main") and self.findViewIndex(options.window_id, parent) == null and self.findWebViewIndex(options.window_id, parent) == null) return error.ViewNotFound;
        }
        if (std.mem.eql(u8, options.label, "main")) return error.DuplicateViewLabel;
        if (self.findWebViewIndex(options.window_id, options.label) != null) return error.DuplicateViewLabel;
    }

    fn copyViewStrings(self: *NullPlatform, index: usize, label: []const u8, parent: ?[]const u8, role: []const u8, accessibility_label: []const u8, text: []const u8, command: []const u8) !void {
        self.views[index].label = try copyInto(&self.views[index].label_storage, label);
        self.views[index].parent = if (parent) |value| try copyInto(&self.views[index].parent_storage, value) else null;
        self.views[index].role = try copyInto(&self.views[index].role_storage, role);
        self.views[index].accessibility_label = try copyInto(&self.views[index].accessibility_label_storage, accessibility_label);
        self.views[index].text = try copyInto(&self.views[index].text_storage, text);
        self.views[index].command = try copyInto(&self.views[index].command_storage, command);
    }

    fn removeViewAt(self: *NullPlatform, index: usize) void {
        if (index >= self.view_count) return;
        var cursor = index;
        while (cursor + 1 < self.view_count) : (cursor += 1) {
            const next = self.views[cursor + 1];
            self.views[cursor] = .{
                .window_id = next.window_id,
                .kind = next.kind,
                .frame = next.frame,
                .layer = next.layer,
                .visible = next.visible,
                .enabled = next.enabled,
                .accessibility_label = next.accessibility_label,
                .command = next.command,
                .open = next.open,
            };
            self.copyViewStrings(cursor, next.label, next.parent, next.role, next.accessibility_label, next.text, next.command) catch unreachable;
        }
        self.view_count -= 1;
    }

    fn removeViewsForWindow(self: *NullPlatform, window_id: WindowId) void {
        var index: usize = 0;
        while (index < self.view_count) {
            if (self.views[index].window_id == window_id) {
                self.removeViewAt(index);
            } else {
                index += 1;
            }
        }
    }

    fn removeChildViewsForParent(self: *NullPlatform, window_id: WindowId, parent_label: []const u8) void {
        var index: usize = 0;
        while (index < self.view_count) {
            const parent = self.views[index].parent orelse {
                index += 1;
                continue;
            };
            if (self.views[index].window_id != window_id or !std.mem.eql(u8, parent, parent_label)) {
                index += 1;
                continue;
            }

            var child_label_storage: [max_view_label_bytes]u8 = undefined;
            const child_label = copyInto(&child_label_storage, self.views[index].label) catch unreachable;
            self.removeChildViewsForParent(window_id, child_label);
            if (self.findViewIndex(window_id, child_label)) |child_index| self.removeViewAt(child_index);
            index = 0;
        }
    }

    fn removeWebViewAt(self: *NullPlatform, index: usize) void {
        if (index >= self.webview_count) return;
        var cursor = index;
        while (cursor + 1 < self.webview_count) : (cursor += 1) {
            const next = self.webviews[cursor + 1];
            self.webviews[cursor] = .{
                .window_id = next.window_id,
                .frame = next.frame,
                .layer = next.layer,
                .transparent = next.transparent,
                .bridge_enabled = next.bridge_enabled,
                .zoom = next.zoom,
                .open = next.open,
            };
            @memcpy(self.webviews[cursor].label_storage[0..next.label.len], next.label);
            @memcpy(self.webviews[cursor].url_storage[0..next.url.len], next.url);
            self.webviews[cursor].label = self.webviews[cursor].label_storage[0..next.label.len];
            self.webviews[cursor].url = self.webviews[cursor].url_storage[0..next.url.len];
        }
        self.webview_count -= 1;
    }

    fn removeWebViewsForWindow(self: *NullPlatform, window_id: WindowId) void {
        var index: usize = 0;
        while (index < self.webview_count) {
            if (self.webviews[index].window_id == window_id) {
                self.removeWebViewAt(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn lastBridgeResponse(self: *const NullPlatform) []const u8 {
        return self.bridge_response[0..self.bridge_response_len];
    }

    pub fn lastBridgeResponseWindowId(self: *const NullPlatform) WindowId {
        return self.bridge_response_window_id;
    }

    pub fn lastBridgeResponseWebViewLabel(self: *const NullPlatform) []const u8 {
        return self.bridge_response_webview_label;
    }

    pub fn lastExternalUrl(self: *const NullPlatform) []const u8 {
        return self.external_url[0..self.external_url_len];
    }

    pub fn lastRevealedPath(self: *const NullPlatform) []const u8 {
        return self.revealed_path[0..self.revealed_path_len];
    }

    pub fn lastRecentDocumentPath(self: *const NullPlatform) []const u8 {
        return self.recent_document_path[0..self.recent_document_path_len];
    }

    pub fn recentDocumentsClearedCount(self: *const NullPlatform) usize {
        return self.recent_documents_cleared_count;
    }

    pub fn lastNotificationTitle(self: *const NullPlatform) []const u8 {
        return self.notification_title[0..self.notification_title_len];
    }

    pub fn lastNotificationSubtitle(self: *const NullPlatform) []const u8 {
        return self.notification_subtitle[0..self.notification_subtitle_len];
    }

    pub fn lastNotificationBody(self: *const NullPlatform) []const u8 {
        return self.notification_body[0..self.notification_body_len];
    }

    pub fn notificationCount(self: *const NullPlatform) usize {
        return self.notification_count;
    }

    pub fn lastClipboardMimeType(self: *const NullPlatform) []const u8 {
        return self.clipboard_mime_type[0..self.clipboard_mime_type_len];
    }

    pub fn lastClipboardData(self: *const NullPlatform) []const u8 {
        return self.clipboard_data[0..self.clipboard_data_len];
    }

    pub fn clipboardWriteCount(self: *const NullPlatform) usize {
        return self.clipboard_write_count;
    }

    pub fn lastCredentialService(self: *const NullPlatform) []const u8 {
        return self.credential_service[0..self.credential_service_len];
    }

    pub fn lastCredentialAccount(self: *const NullPlatform) []const u8 {
        return self.credential_account[0..self.credential_account_len];
    }

    pub fn lastCredentialSecret(self: *const NullPlatform) []const u8 {
        return self.credential_secret[0..self.credential_secret_len];
    }

    pub fn credentialSetCount(self: *const NullPlatform) usize {
        return self.credential_set_count;
    }

    pub fn credentialDeleteCount(self: *const NullPlatform) usize {
        return self.credential_delete_count;
    }

    pub fn lastTrayIconPath(self: *const NullPlatform) []const u8 {
        return self.tray_icon_path[0..self.tray_icon_path_len];
    }

    pub fn lastTrayTooltip(self: *const NullPlatform) []const u8 {
        return self.tray_tooltip[0..self.tray_tooltip_len];
    }

    pub fn trayItems(self: *const NullPlatform) []const TrayMenuItem {
        return self.tray_items[0..self.tray_item_count];
    }

    pub fn trayCreateCount(self: *const NullPlatform) usize {
        return self.tray_create_count;
    }

    pub fn trayUpdateCount(self: *const NullPlatform) usize {
        return self.tray_update_count;
    }

    pub fn trayRemoveCount(self: *const NullPlatform) usize {
        return self.tray_remove_count;
    }

    pub fn lastWindowEventWindowId(self: *const NullPlatform) WindowId {
        return self.window_event_window_id;
    }

    pub fn lastWindowEventName(self: *const NullPlatform) []const u8 {
        return self.window_event_name[0..self.window_event_name_len];
    }

    pub fn lastWindowEventDetail(self: *const NullPlatform) []const u8 {
        return self.window_event_detail[0..self.window_event_detail_len];
    }

    pub fn windowEventCount(self: *const NullPlatform) usize {
        return self.window_event_count;
    }

    pub fn configuredShortcuts(self: *const NullPlatform) []const Shortcut {
        return self.shortcuts[0..self.shortcut_count];
    }

    pub fn configuredMenus(self: *const NullPlatform) []const Menu {
        return self.menus[0..self.menu_count];
    }
};

pub const NullWebView = struct {
    window_id: WindowId = 1,
    label: []const u8 = "",
    url: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    transparent: bool = false,
    bridge_enabled: bool = false,
    zoom: f64 = 1.0,
    open: bool = false,
    label_storage: [max_webview_label_bytes]u8 = undefined,
    url_storage: [max_webview_url_bytes]u8 = undefined,
};

pub const NullView = struct {
    window_id: WindowId = 1,
    label: []const u8 = "",
    kind: ViewKind = .toolbar,
    parent: ?[]const u8 = null,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    visible: bool = true,
    enabled: bool = true,
    role: []const u8 = "",
    accessibility_label: []const u8 = "",
    text: []const u8 = "",
    command: []const u8 = "",
    gpu_size: geometry.SizeF = geometry.SizeF.init(0, 0),
    gpu_backend: GpuSurfaceBackend = .none,
    gpu_pixel_format: GpuSurfacePixelFormat = .none,
    gpu_present_mode: GpuSurfacePresentMode = .none,
    gpu_alpha_mode: GpuSurfaceAlphaMode = .none,
    gpu_color_space: GpuSurfaceColorSpace = .none,
    gpu_vsync: bool = false,
    gpu_status: GpuSurfaceStatus = .unavailable,
    open: bool = false,
    label_storage: [max_view_label_bytes]u8 = undefined,
    parent_storage: [max_view_label_bytes]u8 = undefined,
    role_storage: [max_view_role_bytes]u8 = undefined,
    accessibility_label_storage: [max_view_accessibility_label_bytes]u8 = undefined,
    text_storage: [max_view_text_bytes]u8 = undefined,
    command_storage: [max_view_command_bytes]u8 = undefined,
};

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

fn isValidWebViewFrame(frame: geometry.RectF) bool {
    return frame.x >= 0 and frame.y >= 0 and frame.width > 0 and frame.height > 0;
}

fn isValidViewFrame(frame: geometry.RectF) bool {
    return frame.x >= 0 and frame.y >= 0 and frame.width >= 0 and frame.height >= 0;
}
