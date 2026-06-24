const std = @import("std");
const geometry = @import("geometry");
const platform_info = @import("platform_info");
const security = @import("../security/root.zig");

pub const Error = error{
    UnsupportedService,
    WindowNotFound,
    WindowLimitReached,
    DuplicateWindowId,
    DuplicateWindowLabel,
    MissingWindowSource,
    WindowSourceTooLarge,
    FocusFailed,
    CloseFailed,
    InvalidShortcut,
    MissingWebViewUrl,
    InvalidWebViewOptions,
    WebViewNotFound,
    WebViewLimitReached,
    DuplicateWebViewLabel,
    WebViewLabelTooLarge,
    WebViewUrlTooLarge,
    UnsupportedChildWebViews,
    UnsupportedWebViewBridge,
    UnsupportedMainWebViewFrame,
    UnsupportedMainWebViewZoom,
    UnsupportedMainWebViewLayer,
    NavigationDenied,
};

pub const WebEngine = enum {
    system,
    chromium,
};

pub const WebViewSourceKind = enum {
    html,
    url,
    assets,
};

pub const WebViewAssetSource = struct {
    root_path: []const u8,
    entry: []const u8 = "index.html",
    origin: []const u8 = "zero://app",
    spa_fallback: bool = true,
};

pub const WebViewSource = struct {
    kind: WebViewSourceKind,
    bytes: []const u8,
    asset_options: ?WebViewAssetSource = null,

    pub fn html(bytes: []const u8) WebViewSource {
        return .{ .kind = .html, .bytes = bytes };
    }

    pub fn url(bytes: []const u8) WebViewSource {
        return .{ .kind = .url, .bytes = bytes };
    }

    pub fn assets(options: WebViewAssetSource) WebViewSource {
        return .{ .kind = .assets, .bytes = options.origin, .asset_options = options };
    }
};

pub const WindowId = u64;
pub const max_windows: usize = 16;
pub const max_window_label_bytes: usize = 64;
pub const max_window_title_bytes: usize = 128;
pub const max_window_source_bytes: usize = 4096;
pub const max_webviews: usize = 16;
pub const max_webview_label_bytes: usize = 64;
pub const max_webview_url_bytes: usize = 4096;
pub const max_shortcuts: usize = 64;
pub const max_shortcut_id_bytes: usize = 64;
pub const max_shortcut_key_bytes: usize = 32;

pub const ShortcutModifiers = struct {
    primary: bool = false,
    command: bool = false,
    control: bool = false,
    option: bool = false,
    shift: bool = false,

    pub fn hasAny(self: ShortcutModifiers) bool {
        return self.primary or self.command or self.control or self.option or self.shift;
    }
};

pub const Shortcut = struct {
    id: []const u8,
    key: []const u8,
    modifiers: ShortcutModifiers = .{},
};

pub const ShortcutEvent = struct {
    id: []const u8,
    key: []const u8,
    modifiers: ShortcutModifiers = .{},
    window_id: WindowId = 1,
};

pub fn validateShortcut(shortcut: Shortcut) Error!void {
    if (shortcut.id.len == 0 or shortcut.id.len > max_shortcut_id_bytes) return error.InvalidShortcut;
    if (!isValidShortcutKey(shortcut.key)) return error.InvalidShortcut;
    if (!shortcut.modifiers.hasAny() and shortcutRequiresModifier(shortcut.key)) return error.InvalidShortcut;
}

pub fn isValidShortcutKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_shortcut_key_bytes) return false;
    if (key.len == 1) {
        const ch = key[0];
        if (std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch)) return true;
        return switch (ch) {
            '=', '-', ',', '.', '/', ';', '\'', '[', ']', '\\', '`' => true,
            else => false,
        };
    }
    const specials = [_][]const u8{
        "escape",
        "enter",
        "tab",
        "space",
        "backspace",
        "arrowleft",
        "arrowright",
        "arrowup",
        "arrowdown",
    };
    for (&specials) |special| {
        if (std.ascii.eqlIgnoreCase(key, special)) return true;
    }
    return false;
}

fn shortcutRequiresModifier(key: []const u8) bool {
    if (key.len == 1) return true;
    return std.ascii.eqlIgnoreCase(key, "space") or
        std.ascii.eqlIgnoreCase(key, "enter") or
        std.ascii.eqlIgnoreCase(key, "tab") or
        std.ascii.eqlIgnoreCase(key, "backspace");
}

pub const WindowRestorePolicy = enum {
    clamp_to_visible_screen,
    center_on_primary,
};

pub const WindowOptions = struct {
    id: WindowId = 1,
    label: []const u8 = "main",
    title: []const u8 = "",
    default_frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    resizable: bool = true,
    restore_state: bool = true,
    restore_policy: WindowRestorePolicy = .clamp_to_visible_screen,

    pub fn resolvedTitle(self: WindowOptions, app_name: []const u8) []const u8 {
        return if (self.title.len > 0) self.title else app_name;
    }
};

pub const WindowState = struct {
    id: WindowId = 1,
    label: []const u8 = "main",
    title: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    scale_factor: f32 = 1,
    open: bool = true,
    focused: bool = true,
    maximized: bool = false,
    fullscreen: bool = false,
};

pub const WindowInfo = struct {
    id: WindowId = 1,
    label: []const u8 = "main",
    title: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    scale_factor: f32 = 1,
    open: bool = true,
    focused: bool = false,

    pub fn state(self: WindowInfo) WindowState {
        return .{
            .id = self.id,
            .label = self.label,
            .title = self.title,
            .frame = self.frame,
            .scale_factor = self.scale_factor,
            .open = self.open,
            .focused = self.focused,
        };
    }
};

pub const WindowCreateOptions = struct {
    id: WindowId = 0,
    label: []const u8 = "",
    title: []const u8 = "",
    default_frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    resizable: bool = true,
    restore_state: bool = true,
    restore_policy: WindowRestorePolicy = .clamp_to_visible_screen,
    source: ?WebViewSource = null,

    pub fn windowOptions(self: WindowCreateOptions, id: WindowId, label: []const u8) WindowOptions {
        return .{
            .id = id,
            .label = label,
            .title = self.title,
            .default_frame = self.default_frame,
            .resizable = self.resizable,
            .restore_state = self.restore_state,
            .restore_policy = self.restore_policy,
        };
    }
};

pub const WebViewOptions = struct {
    window_id: WindowId = 1,
    label: []const u8,
    url: []const u8,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    transparent: bool = false,
    bridge_enabled: bool = false,
};

pub const WebViewInfo = struct {
    window_id: WindowId = 1,
    label: []const u8 = "webview",
    url: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    zoom: f64 = 1.0,
    transparent: bool = false,
    bridge_enabled: bool = false,
    open: bool = true,
};

pub const AppInfo = struct {
    app_name: []const u8 = "zero-native",
    window_title: []const u8 = "",
    bundle_id: []const u8 = "dev.zero_native.app",
    icon_path: []const u8 = "",
    main_window: WindowOptions = .{},
    windows: []const WindowOptions = &.{},

    pub fn resolvedWindowTitle(self: AppInfo) []const u8 {
        if (self.window_title.len > 0) return self.window_title;
        return self.main_window.resolvedTitle(self.app_name);
    }

    pub fn resolvedMainWindow(self: AppInfo) WindowOptions {
        var window = self.main_window;
        if (window.title.len == 0) window.title = self.resolvedWindowTitle();
        return window;
    }

    pub fn startupWindowCount(self: AppInfo) usize {
        return if (self.windows.len > 0) self.windows.len else 1;
    }

    pub fn resolvedStartupWindow(self: AppInfo, index: usize) WindowOptions {
        var window = if (self.windows.len > 0) self.windows[index] else self.main_window;
        if (window.id == 0 or (self.windows.len > 0 and index > 0 and window.id == 1)) {
            window.id = @intCast(index + 1);
        }
        if (window.label.len == 0) window.label = if (index == 0) "main" else "window";
        if (window.title.len == 0) window.title = self.resolvedWindowTitle();
        return window;
    }
};

pub const Surface = struct {
    id: u64 = 1,
    size: geometry.SizeF = geometry.SizeF.init(640, 360),
    scale_factor: f32 = 1,
    native_handle: ?*anyopaque = null,
};

pub const BridgeMessage = struct {
    bytes: []const u8,
    origin: []const u8 = "",
    window_id: WindowId = 1,
    webview_label: []const u8 = "main",
};

pub const max_dialog_path_bytes: usize = 4096;
pub const max_dialog_paths_bytes: usize = 16 * 4096;

pub const FileFilter = struct {
    name: []const u8,
    extensions: []const []const u8,
};

pub const OpenDialogOptions = struct {
    title: []const u8 = "",
    default_path: []const u8 = "",
    filters: []const FileFilter = &.{},
    allow_directories: bool = false,
    allow_multiple: bool = false,
};

pub const OpenDialogResult = struct {
    count: usize,
    paths: []const u8,
};

pub const SaveDialogOptions = struct {
    title: []const u8 = "",
    default_path: []const u8 = "",
    default_name: []const u8 = "",
    filters: []const FileFilter = &.{},
};

pub const MessageDialogStyle = enum(c_int) {
    info = 0,
    warning = 1,
    critical = 2,
};

pub const MessageDialogResult = enum(c_int) {
    primary = 0,
    secondary = 1,
    tertiary = 2,
};

pub const MessageDialogOptions = struct {
    style: MessageDialogStyle = .info,
    title: []const u8 = "",
    message: []const u8 = "",
    informative_text: []const u8 = "",
    primary_button: []const u8 = "OK",
    secondary_button: []const u8 = "",
    tertiary_button: []const u8 = "",
};

pub const TrayItemId = u32;

pub const TrayOptions = struct {
    icon_path: []const u8 = "",
    tooltip: []const u8 = "",
    items: []const TrayMenuItem = &.{},
};

pub const TrayMenuItem = struct {
    id: TrayItemId = 0,
    label: []const u8 = "",
    separator: bool = false,
    enabled: bool = true,
};

pub const Event = union(enum) {
    app_start,
    frame_requested,
    app_shutdown,
    surface_resized: Surface,
    window_frame_changed: WindowState,
    window_focused: WindowId,
    bridge_message: BridgeMessage,
    tray_action: TrayItemId,
    shortcut: ShortcutEvent,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .app_start => "app_start",
            .frame_requested => "frame_requested",
            .app_shutdown => "app_shutdown",
            .surface_resized => "surface_resized",
            .window_frame_changed => "window_frame_changed",
            .window_focused => "window_focused",
            .bridge_message => "bridge_message",
            .tray_action => "tray_action",
            .shortcut => "shortcut",
        };
    }
};

pub const EventHandler = *const fn (context: *anyopaque, event: Event) anyerror!void;

pub const PlatformServices = struct {
    context: ?*anyopaque = null,
    read_clipboard_fn: ?*const fn (context: ?*anyopaque, buffer: []u8) anyerror![]const u8 = null,
    write_clipboard_fn: ?*const fn (context: ?*anyopaque, text: []const u8) anyerror!void = null,
    load_webview_fn: ?*const fn (context: ?*anyopaque, source: WebViewSource) anyerror!void = null,
    load_window_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, source: WebViewSource) anyerror!void = null,
    complete_bridge_fn: ?*const fn (context: ?*anyopaque, response: []const u8) anyerror!void = null,
    complete_window_bridge_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void = null,
    complete_webview_bridge_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, webview_label: []const u8, response: []const u8) anyerror!void = null,
    create_window_fn: ?*const fn (context: ?*anyopaque, options: WindowOptions) anyerror!WindowInfo = null,
    focus_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    close_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    create_webview_fn: ?*const fn (context: ?*anyopaque, options: WebViewOptions) anyerror!void = null,
    set_webview_frame_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void = null,
    navigate_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, url: []const u8) anyerror!void = null,
    set_webview_zoom_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, zoom: f64) anyerror!void = null,
    set_webview_layer_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, layer: i32) anyerror!void = null,
    close_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    show_open_dialog_fn: ?*const fn (context: ?*anyopaque, options: OpenDialogOptions, buffer: []u8) anyerror!OpenDialogResult = null,
    show_save_dialog_fn: ?*const fn (context: ?*anyopaque, options: SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 = null,
    show_message_dialog_fn: ?*const fn (context: ?*anyopaque, options: MessageDialogOptions) anyerror!MessageDialogResult = null,
    create_tray_fn: ?*const fn (context: ?*anyopaque, options: TrayOptions) anyerror!void = null,
    update_tray_menu_fn: ?*const fn (context: ?*anyopaque, items: []const TrayMenuItem) anyerror!void = null,
    remove_tray_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    configure_security_policy_fn: ?*const fn (context: ?*anyopaque, policy: security.Policy) anyerror!void = null,
    configure_shortcuts_fn: ?*const fn (context: ?*anyopaque, shortcuts: []const Shortcut) anyerror!void = null,
    emit_window_event_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void = null,

    pub fn readClipboard(self: PlatformServices, buffer: []u8) anyerror![]const u8 {
        const read_fn = self.read_clipboard_fn orelse return error.UnsupportedService;
        return read_fn(self.context, buffer);
    }

    pub fn writeClipboard(self: PlatformServices, text: []const u8) anyerror!void {
        const write_fn = self.write_clipboard_fn orelse return error.UnsupportedService;
        return write_fn(self.context, text);
    }

    pub fn loadWebView(self: PlatformServices, source: WebViewSource) anyerror!void {
        if (self.load_window_webview_fn) |load_fn| return load_fn(self.context, 1, source);
        const load_fn = self.load_webview_fn orelse return error.UnsupportedService;
        return load_fn(self.context, source);
    }

    pub fn loadWindowWebView(self: PlatformServices, window_id: WindowId, source: WebViewSource) anyerror!void {
        if (self.load_window_webview_fn) |load_fn| return load_fn(self.context, window_id, source);
        if (window_id == 1) return self.loadWebView(source);
        return error.UnsupportedService;
    }

    pub fn completeBridge(self: PlatformServices, response: []const u8) anyerror!void {
        if (self.complete_window_bridge_fn) |complete_fn| return complete_fn(self.context, 1, response);
        const complete_fn = self.complete_bridge_fn orelse return error.UnsupportedService;
        return complete_fn(self.context, response);
    }

    pub fn completeWindowBridge(self: PlatformServices, window_id: WindowId, response: []const u8) anyerror!void {
        if (self.complete_window_bridge_fn) |complete_fn| return complete_fn(self.context, window_id, response);
        if (window_id == 1) return self.completeBridge(response);
        return error.UnsupportedService;
    }

    pub fn completeWebViewBridge(self: PlatformServices, window_id: WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
        if (self.complete_webview_bridge_fn) |complete_fn| return complete_fn(self.context, window_id, webview_label, response);
        if (!std.mem.eql(u8, webview_label, "main")) return error.UnsupportedService;
        return self.completeWindowBridge(window_id, response);
    }

    pub fn createWindow(self: PlatformServices, options: WindowOptions) anyerror!WindowInfo {
        const create_fn = self.create_window_fn orelse return error.UnsupportedService;
        return create_fn(self.context, options);
    }

    pub fn focusWindow(self: PlatformServices, window_id: WindowId) anyerror!void {
        const focus_fn = self.focus_window_fn orelse return error.UnsupportedService;
        return focus_fn(self.context, window_id);
    }

    pub fn closeWindow(self: PlatformServices, window_id: WindowId) anyerror!void {
        const close_fn = self.close_window_fn orelse return error.UnsupportedService;
        return close_fn(self.context, window_id);
    }

    pub fn createWebView(self: PlatformServices, options: WebViewOptions) anyerror!void {
        const create_fn = self.create_webview_fn orelse return error.UnsupportedService;
        return create_fn(self.context, options);
    }

    pub fn setWebViewFrame(self: PlatformServices, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
        const set_fn = self.set_webview_frame_fn orelse return error.UnsupportedService;
        return set_fn(self.context, window_id, label, frame);
    }

    pub fn navigateWebView(self: PlatformServices, window_id: WindowId, label: []const u8, url: []const u8) anyerror!void {
        const navigate_fn = self.navigate_webview_fn orelse return error.UnsupportedService;
        return navigate_fn(self.context, window_id, label, url);
    }

    pub fn setWebViewZoom(self: PlatformServices, window_id: WindowId, label: []const u8, zoom: f64) anyerror!void {
        const zoom_fn = self.set_webview_zoom_fn orelse return error.UnsupportedService;
        return zoom_fn(self.context, window_id, label, zoom);
    }

    pub fn setWebViewLayer(self: PlatformServices, window_id: WindowId, label: []const u8, layer: i32) anyerror!void {
        const layer_fn = self.set_webview_layer_fn orelse return error.UnsupportedService;
        return layer_fn(self.context, window_id, label, layer);
    }

    pub fn closeWebView(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        const close_fn = self.close_webview_fn orelse return error.UnsupportedService;
        return close_fn(self.context, window_id, label);
    }

    pub fn showOpenDialog(self: PlatformServices, options: OpenDialogOptions, buffer: []u8) anyerror!OpenDialogResult {
        const open_fn = self.show_open_dialog_fn orelse return error.UnsupportedService;
        return open_fn(self.context, options, buffer);
    }

    pub fn showSaveDialog(self: PlatformServices, options: SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
        const save_fn = self.show_save_dialog_fn orelse return error.UnsupportedService;
        return save_fn(self.context, options, buffer);
    }

    pub fn showMessageDialog(self: PlatformServices, options: MessageDialogOptions) anyerror!MessageDialogResult {
        const msg_fn = self.show_message_dialog_fn orelse return error.UnsupportedService;
        return msg_fn(self.context, options);
    }

    pub fn createTray(self: PlatformServices, options: TrayOptions) anyerror!void {
        const tray_fn = self.create_tray_fn orelse return error.UnsupportedService;
        return tray_fn(self.context, options);
    }

    pub fn updateTrayMenu(self: PlatformServices, items: []const TrayMenuItem) anyerror!void {
        const update_fn = self.update_tray_menu_fn orelse return error.UnsupportedService;
        return update_fn(self.context, items);
    }

    pub fn removeTray(self: PlatformServices) anyerror!void {
        const remove_fn = self.remove_tray_fn orelse return error.UnsupportedService;
        return remove_fn(self.context);
    }

    pub fn configureSecurityPolicy(self: PlatformServices, policy: security.Policy) anyerror!void {
        const configure_fn = self.configure_security_policy_fn orelse return error.UnsupportedService;
        return configure_fn(self.context, policy);
    }

    pub fn configureShortcuts(self: PlatformServices, shortcuts: []const Shortcut) anyerror!void {
        const configure_fn = self.configure_shortcuts_fn orelse return;
        return configure_fn(self.context, shortcuts);
    }

    pub fn emitWindowEvent(self: PlatformServices, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
        const emit_fn = self.emit_window_event_fn orelse return error.UnsupportedService;
        return emit_fn(self.context, window_id, name, detail_json);
    }
};

pub const Platform = struct {
    context: *anyopaque,
    name: []const u8,
    surface_value: Surface,
    run_fn: *const fn (context: *anyopaque, handler: EventHandler, handler_context: *anyopaque) anyerror!void,
    services: PlatformServices = .{},
    app_info: AppInfo = .{},

    pub fn surface(self: Platform) Surface {
        return self.surface_value;
    }

    pub fn run(self: Platform, handler: EventHandler, handler_context: *anyopaque) anyerror!void {
        return self.run_fn(self.context, handler, handler_context);
    }
};

pub const Backend = enum {
    @"null",
    macos,
    linux,
    windows,
};

pub const NullPlatform = struct {
    surface_value: Surface = .{},
    web_engine: WebEngine = .system,
    app_info: AppInfo = .{},
    requested_frames: u32 = 1,
    loaded_source: ?WebViewSource = null,
    security_policy: security.Policy = .{},
    shortcuts: [max_shortcuts]Shortcut = undefined,
    shortcut_count: usize = 0,
    window_sources: [max_windows]?WebViewSource = [_]?WebViewSource{null} ** max_windows,
    windows: [max_windows]WindowInfo = undefined,
    window_count: usize = 0,
    webviews: [max_webviews]NullWebView = undefined,
    webview_count: usize = 0,
    bridge_response: [16 * 1024]u8 = undefined,
    bridge_response_len: usize = 0,
    bridge_response_window_id: WindowId = 0,
    bridge_response_webview_label: []const u8 = "main",

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
            .services = .{
                .context = self,
                .load_webview_fn = loadWebView,
                .load_window_webview_fn = loadWindowWebView,
                .complete_bridge_fn = completeBridge,
                .complete_window_bridge_fn = completeWindowBridge,
                .complete_webview_bridge_fn = completeWebViewBridge,
                .create_window_fn = createWindow,
                .focus_window_fn = focusWindow,
                .close_window_fn = closeWindow,
                .create_webview_fn = createWebView,
                .set_webview_frame_fn = setWebViewFrame,
                .navigate_webview_fn = navigateWebView,
                .set_webview_zoom_fn = setWebViewZoom,
                .set_webview_layer_fn = setWebViewLayer,
                .close_webview_fn = closeWebView,
                .configure_security_policy_fn = configureSecurityPolicy,
                .configure_shortcuts_fn = configureShortcuts,
                .emit_window_event_fn = emitWindowEvent,
            },
            .app_info = self.app_info,
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
        self.removeWebViewsForWindow(window_id);
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

    fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.security_policy = policy;
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
        _ = context;
        _ = window_id;
        _ = name;
        _ = detail_json;
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

    pub fn configuredShortcuts(self: *const NullPlatform) []const Shortcut {
        return self.shortcuts[0..self.shortcut_count];
    }
};

const NullWebView = struct {
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

fn isValidWebViewFrame(frame: geometry.RectF) bool {
    return frame.x >= 0 and frame.y >= 0 and frame.width > 0 and frame.height > 0;
}

pub const macos = @import("macos/root.zig");
pub const linux = @import("linux/root.zig");
pub const windows = @import("windows/root.zig");

test "null platform emits deterministic lifecycle events" {
    const Recorder = struct {
        names: [5][]const u8 = undefined,
        len: usize = 0,

        fn handle(context: *anyopaque, event: Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.names[self.len] = event.name();
            self.len += 1;
        }
    };

    var null_platform = NullPlatform.init(.{});
    var recorder: Recorder = .{};
    try null_platform.platform().run(Recorder.handle, &recorder);

    try std.testing.expectEqual(@as(usize, 5), recorder.len);
    try std.testing.expectEqualStrings("app_start", recorder.names[0]);
    try std.testing.expectEqualStrings("surface_resized", recorder.names[1]);
    try std.testing.expectEqualStrings("window_frame_changed", recorder.names[2]);
    try std.testing.expectEqualStrings("frame_requested", recorder.names[3]);
    try std.testing.expectEqualStrings("app_shutdown", recorder.names[4]);
}

test "null platform records loaded webview source" {
    var null_platform = NullPlatform.initWithOptions(.{}, .chromium, .{ .app_name = "Demo", .window_title = "Demo Window" });
    try null_platform.platform().services.loadWebView(WebViewSource.html("<h1>Hello</h1>"));

    try std.testing.expectEqual(WebEngine.chromium, null_platform.web_engine);
    try std.testing.expectEqualStrings("Demo Window", null_platform.app_info.resolvedWindowTitle());
    try std.testing.expectEqual(WebViewSourceKind.html, null_platform.loaded_source.?.kind);
    try std.testing.expectEqualStrings("<h1>Hello</h1>", null_platform.loaded_source.?.bytes);
}

test "null platform records bridge response window routing" {
    var null_platform = NullPlatform.init(.{});
    try null_platform.platform().services.completeWindowBridge(7, "{\"ok\":true}");

    try std.testing.expectEqual(@as(WindowId, 7), null_platform.lastBridgeResponseWindowId());
    try std.testing.expectEqualStrings("{\"ok\":true}", null_platform.lastBridgeResponse());
}

test "null platform records configured shortcuts" {
    const shortcuts = [_]Shortcut{
        .{ .id = "command.palette", .key = "p", .modifiers = .{ .primary = true, .shift = true } },
    };
    var null_platform = NullPlatform.init(.{});
    try null_platform.platform().services.configureShortcuts(&shortcuts);

    try std.testing.expectEqual(@as(usize, 1), null_platform.configuredShortcuts().len);
    try std.testing.expectEqualStrings("command.palette", null_platform.configuredShortcuts()[0].id);
    try std.testing.expect(null_platform.configuredShortcuts()[0].modifiers.primary);
    try std.testing.expect(null_platform.configuredShortcuts()[0].modifiers.shift);

    const long_key = [_]u8{'x'} ** (max_shortcut_key_bytes + 1);
    const invalid = [_]Shortcut{.{ .id = "invalid", .key = long_key[0..] }};
    try std.testing.expectError(error.InvalidShortcut, null_platform.platform().services.configureShortcuts(&invalid));

    const invalid_key = [_]Shortcut{.{ .id = "invalid", .key = "@" }};
    try std.testing.expectError(error.InvalidShortcut, null_platform.platform().services.configureShortcuts(&invalid_key));

    const unmodified_text_key = [_]Shortcut{.{ .id = "text", .key = "p" }};
    try std.testing.expectError(error.InvalidShortcut, null_platform.platform().services.configureShortcuts(&unmodified_text_key));
}

test "webview bridge fallback only routes main responses" {
    const Recorder = struct {
        window_id: WindowId = 0,
        response: []const u8 = "",

        fn completeWindow(context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.window_id = window_id;
            self.response = response;
        }
    };

    var recorder: Recorder = .{};
    const services = PlatformServices{
        .context = &recorder,
        .complete_window_bridge_fn = Recorder.completeWindow,
    };

    try services.completeWebViewBridge(3, "main", "{\"ok\":true}");
    try std.testing.expectEqual(@as(WindowId, 3), recorder.window_id);
    try std.testing.expectEqualStrings("{\"ok\":true}", recorder.response);
    try std.testing.expectError(error.UnsupportedService, services.completeWebViewBridge(3, "preview", "{\"ok\":true}"));
}

test "null platform records webview lifecycle" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try services.createWebView(.{
        .label = "preview",
        .url = "https://example.com",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    });
    try std.testing.expectEqual(@as(usize, 1), null_platform.webview_count);
    try std.testing.expectEqualStrings("preview", null_platform.webviews[0].label);
    try std.testing.expectError(error.DuplicateWebViewLabel, services.createWebView(.{
        .label = "preview",
        .url = "https://example.org",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    }));

    try services.setWebViewFrame(1, "preview", geometry.RectF.init(11, 22, 333, 222));
    try std.testing.expectEqual(@as(f32, 333), null_platform.webviews[0].frame.width);
    try services.navigateWebView(1, "preview", "https://example.org");
    try std.testing.expectEqualStrings("https://example.org", null_platform.webviews[0].url);
    try services.closeWebView(1, "preview");
    try std.testing.expectEqual(@as(usize, 0), null_platform.webview_count);
}

test "null platform preserves shifted webview storage after close" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try services.createWebView(.{
        .label = "first",
        .url = "https://example.com/first",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    });
    try services.createWebView(.{
        .label = "second",
        .url = "https://example.com/second",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    });

    try services.closeWebView(1, "first");
    try std.testing.expectEqual(@as(usize, 1), null_platform.webview_count);
    try std.testing.expectEqualStrings("second", null_platform.webviews[0].label);
    try std.testing.expectEqualStrings("https://example.com/second", null_platform.webviews[0].url);

    try services.createWebView(.{
        .label = "third",
        .url = "https://example.com/third",
        .frame = geometry.RectF.init(10, 20, 300, 200),
    });
    try std.testing.expectEqualStrings("second", null_platform.webviews[0].label);
    try std.testing.expectEqualStrings("https://example.com/second", null_platform.webviews[0].url);
    try std.testing.expectEqualStrings("third", null_platform.webviews[1].label);
    try std.testing.expectEqualStrings("https://example.com/third", null_platform.webviews[1].url);
}

test "null platform requires an open main window for main webview operations" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try std.testing.expectError(error.WindowNotFound, services.setWebViewFrame(1, "main", geometry.RectF.init(0, 0, 320, 240)));
    try std.testing.expectError(error.WindowNotFound, services.setWebViewZoom(1, "main", 1.25));
    try std.testing.expectError(error.WindowNotFound, services.setWebViewLayer(1, "main", 10));

    _ = try services.createWindow(.{ .id = 1, .label = "main" });
    try services.setWebViewFrame(1, "main", geometry.RectF.init(0, 0, 320, 240));
    try services.setWebViewZoom(1, "main", 1.25);
    try services.setWebViewLayer(1, "main", 10);
}

test "webview asset source records production bundle options" {
    const source = WebViewSource.assets(.{ .root_path = "dist", .entry = "index.html" });

    try std.testing.expectEqual(WebViewSourceKind.assets, source.kind);
    try std.testing.expectEqualStrings("zero://app", source.bytes);
    try std.testing.expectEqualStrings("dist", source.asset_options.?.root_path);
    try std.testing.expect(source.asset_options.?.spa_fallback);
}

test {
    std.testing.refAllDecls(@This());
}
