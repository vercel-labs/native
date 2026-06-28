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
    InvalidMenuOptions,
    InvalidCommand,
    InvalidPlatformFeature,
    InvalidViewOptions,
    InvalidViewWindowId,
    CrossWindowViewDenied,
    ViewNotFound,
    ViewLimitReached,
    DuplicateViewLabel,
    ViewLabelTooLarge,
    ViewRoleTooLarge,
    ViewAccessibilityLabelTooLarge,
    ViewTextTooLarge,
    UnsupportedViewKind,
    UnsupportedViewFocus,
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
    InvalidExternalUrl,
    ExternalUrlTooLarge,
    InvalidRevealPath,
    RevealPathTooLarge,
    InvalidRecentDocumentPath,
    RecentDocumentPathTooLarge,
    InvalidDialogOptions,
    DialogFieldTooLarge,
    InvalidNotificationOptions,
    NotificationFieldTooLarge,
    InvalidClipboardOptions,
    ClipboardFieldTooLarge,
    InvalidCredentialOptions,
    CredentialFieldTooLarge,
    CredentialNotFound,
    InvalidTrayOptions,
    TrayFieldTooLarge,
};

pub const WebEngine = enum {
    system,
    chromium,
};

pub const PlatformFeature = enum {
    main_webview,
    child_webviews,
    native_views,
    native_control_commands,
    menus,
    tray,
    shortcuts,
    dialogs,
    clipboard_text,
    clipboard_rich_data,
    open_url,
    reveal_path,
    notifications,
    recent_documents,
    credentials,
    file_drops,
    app_activation_events,
    gpu_surfaces,
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
pub const ViewId = u64;
pub const max_windows: usize = 16;
pub const max_window_label_bytes: usize = 64;
pub const max_window_title_bytes: usize = 128;
pub const max_window_source_bytes: usize = 4096;
pub const max_webviews: usize = 16;
pub const max_webview_label_bytes: usize = 64;
pub const max_webview_url_bytes: usize = 4096;
pub const max_external_url_bytes: usize = 4096;
pub const max_reveal_path_bytes: usize = 4096;
pub const max_recent_document_path_bytes: usize = 4096;
pub const max_notification_title_bytes: usize = 128;
pub const max_notification_subtitle_bytes: usize = 128;
pub const max_notification_body_bytes: usize = 1024;
pub const max_clipboard_mime_type_bytes: usize = 128;
pub const max_clipboard_data_bytes: usize = 65536;
pub const max_credential_service_bytes: usize = 128;
pub const max_credential_account_bytes: usize = 256;
pub const max_credential_secret_bytes: usize = 4096;
pub const max_tray_items: usize = 32;
pub const max_tray_icon_path_bytes: usize = 4096;
pub const max_tray_tooltip_bytes: usize = 256;
pub const max_tray_item_label_bytes: usize = 256;
pub const max_tray_item_command_bytes: usize = 128;
pub const max_drop_paths_bytes: usize = 8192;
pub const max_drop_paths: usize = max_drop_paths_bytes / 2 + 1;
pub const max_window_event_name_bytes: usize = 64;
pub const max_window_event_detail_bytes: usize = 8192;
pub const max_views: usize = 32;
pub const max_view_label_bytes: usize = 64;
pub const max_view_role_bytes: usize = 64;
pub const max_view_accessibility_label_bytes: usize = 256;
pub const max_view_text_bytes: usize = 1024;
pub const max_view_command_bytes: usize = 128;
pub const max_menus: usize = 16;
pub const max_menu_items: usize = 128;
pub const max_menu_title_bytes: usize = 64;
pub const max_menu_item_label_bytes: usize = 128;
pub const max_menu_command_bytes: usize = 128;
pub const max_menu_key_bytes: usize = 32;
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

pub const Menu = struct {
    title: []const u8,
    items: []const MenuItem = &.{},
};

pub const MenuItem = struct {
    label: []const u8 = "",
    command: []const u8 = "",
    key: []const u8 = "",
    modifiers: ShortcutModifiers = .{},
    separator: bool = false,
    enabled: bool = true,
    checked: bool = false,
};

pub fn validateShortcut(shortcut: Shortcut) Error!void {
    if (!isValidCommandId(shortcut.id, max_shortcut_id_bytes)) return error.InvalidShortcut;
    if (!isValidShortcutKey(shortcut.key)) return error.InvalidShortcut;
    if (!shortcut.modifiers.hasAny() and shortcutRequiresModifier(shortcut.key)) return error.InvalidShortcut;
}

pub fn validateMenus(menus: []const Menu) Error!void {
    if (menus.len > max_menus) return error.InvalidMenuOptions;
    var item_count: usize = 0;
    for (menus) |menu| {
        if (menu.title.len == 0 or menu.title.len > max_menu_title_bytes) return error.InvalidMenuOptions;
        item_count += menu.items.len;
        if (item_count > max_menu_items) return error.InvalidMenuOptions;
        for (menu.items) |item| try validateMenuItem(item);
    }
}

pub fn validateMenuItem(item: MenuItem) Error!void {
    if (item.separator) return;
    if (item.label.len == 0 or item.label.len > max_menu_item_label_bytes) return error.InvalidMenuOptions;
    if (!isValidCommandId(item.command, max_menu_command_bytes)) return error.InvalidCommand;
    if (item.key.len > 0) {
        if (!isValidShortcutKey(item.key)) return error.InvalidShortcut;
        if (item.key.len > max_menu_key_bytes) return error.InvalidShortcut;
        if (!item.modifiers.hasAny() and shortcutRequiresModifier(item.key)) return error.InvalidShortcut;
    }
}

fn isValidCommandId(command: []const u8, max_len: usize) bool {
    if (command.len == 0 or command.len > max_len) return false;
    if (std.mem.eql(u8, command, ".") or std.mem.eql(u8, command, "..")) return false;
    for (command) |ch| {
        if (ch == 0 or ch == '/' or ch == '\\' or ch == '\n' or ch == '\r' or ch == '\t') return false;
    }
    return true;
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
    focused: bool = false,
    open: bool = true,
};

pub const ViewKind = enum {
    webview,
    toolbar,
    titlebar_accessory,
    sidebar,
    statusbar,
    split,
    stack,
    button,
    icon_button,
    list_item,
    checkbox,
    toggle,
    segmented_control,
    text_field,
    search_field,
    label,
    spacer,
    gpu_surface,
    progress_indicator,
};

pub const ViewOptions = struct {
    window_id: WindowId = 1,
    label: []const u8,
    kind: ViewKind,
    parent: ?[]const u8 = null,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    visible: bool = true,
    enabled: bool = true,
    role: []const u8 = "",
    accessibility_label: []const u8 = "",
    text: []const u8 = "",
    command: []const u8 = "",
    url: []const u8 = "",
    transparent: bool = false,
    bridge_enabled: bool = false,

    pub fn webViewOptions(self: ViewOptions) WebViewOptions {
        return .{
            .window_id = self.window_id,
            .label = self.label,
            .url = self.url,
            .frame = self.frame,
            .layer = self.layer,
            .transparent = self.transparent,
            .bridge_enabled = self.bridge_enabled,
        };
    }
};

pub const ViewPatch = struct {
    frame: ?geometry.RectF = null,
    layer: ?i32 = null,
    visible: ?bool = null,
    enabled: ?bool = null,
    role: ?[]const u8 = null,
    accessibility_label: ?[]const u8 = null,
    text: ?[]const u8 = null,
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const ViewInfo = struct {
    id: ViewId = 0,
    window_id: WindowId = 1,
    label: []const u8 = "",
    kind: ViewKind = .webview,
    parent: ?[]const u8 = null,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    visible: bool = true,
    enabled: bool = true,
    role: []const u8 = "",
    accessibility_label: []const u8 = "",
    text: []const u8 = "",
    command: []const u8 = "",
    url: []const u8 = "",
    transparent: bool = false,
    bridge_enabled: bool = false,
    focused: bool = false,
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
pub const max_dialog_title_bytes: usize = 512;
pub const max_dialog_message_bytes: usize = 4096;
pub const max_dialog_button_bytes: usize = 128;
pub const max_dialog_filter_name_bytes: usize = 256;
pub const max_dialog_filter_bytes: usize = 1024;

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

pub const NotificationOptions = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    body: []const u8 = "",
};

pub const CredentialKey = struct {
    service: []const u8,
    account: []const u8,
};

pub const Credential = struct {
    service: []const u8,
    account: []const u8,
    secret: []const u8,
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
    command: []const u8 = "",
    separator: bool = false,
    enabled: bool = true,
};

pub const NativeCommandEvent = struct {
    name: []const u8,
    window_id: WindowId = 1,
    view_label: []const u8 = "",
};

pub const MenuCommandEvent = struct {
    name: []const u8,
    window_id: WindowId = 1,
};

pub const FileDropEvent = struct {
    window_id: WindowId = 1,
    paths: []const []const u8 = &.{},
};

pub const GpuSurfaceFrameEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    size: geometry.SizeF,
    scale_factor: f32 = 1,
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
};

pub const GpuSurfaceResizeEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    frame: geometry.RectF,
    scale_factor: f32 = 1,
};

pub const GpuSurfaceInputKind = enum {
    pointer_down,
    pointer_up,
    pointer_move,
    pointer_drag,
    scroll,
    key_down,
    key_up,
};

pub const GpuSurfaceInputEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    kind: GpuSurfaceInputKind,
    x: f32 = 0,
    y: f32 = 0,
    button: i32 = 0,
    delta_x: f32 = 0,
    delta_y: f32 = 0,
    modifiers: ShortcutModifiers = .{},
};

pub const ClipboardData = struct {
    mime_type: []const u8 = "text/plain",
    bytes: []const u8,
};

pub const Event = union(enum) {
    app_start,
    app_activated,
    app_deactivated,
    frame_requested,
    app_shutdown,
    surface_resized: Surface,
    window_frame_changed: WindowState,
    window_focused: WindowId,
    bridge_message: BridgeMessage,
    tray_action: TrayItemId,
    shortcut: ShortcutEvent,
    native_command: NativeCommandEvent,
    menu_command: MenuCommandEvent,
    files_dropped: FileDropEvent,
    gpu_surface_frame: GpuSurfaceFrameEvent,
    gpu_surface_resized: GpuSurfaceResizeEvent,
    gpu_surface_input: GpuSurfaceInputEvent,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .app_start => "app_start",
            .app_activated => "app_activated",
            .app_deactivated => "app_deactivated",
            .frame_requested => "frame_requested",
            .app_shutdown => "app_shutdown",
            .surface_resized => "surface_resized",
            .window_frame_changed => "window_frame_changed",
            .window_focused => "window_focused",
            .bridge_message => "bridge_message",
            .tray_action => "tray_action",
            .shortcut => "shortcut",
            .native_command => "native_command",
            .menu_command => "menu_command",
            .files_dropped => "files_dropped",
            .gpu_surface_frame => "gpu_surface_frame",
            .gpu_surface_resized => "gpu_surface_resized",
            .gpu_surface_input => "gpu_surface_input",
        };
    }
};

pub fn splitDropPaths(bytes: []const u8, output: [][]const u8) []const []const u8 {
    var count: usize = 0;
    var start: usize = 0;
    for (bytes, 0..) |ch, index| {
        if (ch != 0) continue;
        if (index > start and count < output.len) {
            output[count] = bytes[start..index];
            count += 1;
        }
        start = index + 1;
    }
    if (start < bytes.len and count < output.len) {
        output[count] = bytes[start..];
        count += 1;
    }
    return output[0..count];
}

pub const EventHandler = *const fn (context: *anyopaque, event: Event) anyerror!void;

pub const PlatformServices = struct {
    context: ?*anyopaque = null,
    read_clipboard_fn: ?*const fn (context: ?*anyopaque, buffer: []u8) anyerror![]const u8 = null,
    write_clipboard_fn: ?*const fn (context: ?*anyopaque, text: []const u8) anyerror!void = null,
    read_clipboard_data_fn: ?*const fn (context: ?*anyopaque, mime_type: []const u8, buffer: []u8) anyerror![]const u8 = null,
    write_clipboard_data_fn: ?*const fn (context: ?*anyopaque, data: ClipboardData) anyerror!void = null,
    load_webview_fn: ?*const fn (context: ?*anyopaque, source: WebViewSource) anyerror!void = null,
    load_window_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, source: WebViewSource) anyerror!void = null,
    complete_bridge_fn: ?*const fn (context: ?*anyopaque, response: []const u8) anyerror!void = null,
    complete_window_bridge_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void = null,
    complete_webview_bridge_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, webview_label: []const u8, response: []const u8) anyerror!void = null,
    create_window_fn: ?*const fn (context: ?*anyopaque, options: WindowOptions) anyerror!WindowInfo = null,
    focus_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    close_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    create_view_fn: ?*const fn (context: ?*anyopaque, options: ViewOptions) anyerror!void = null,
    update_view_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, patch: ViewPatch) anyerror!void = null,
    set_view_frame_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void = null,
    set_view_visible_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, visible: bool) anyerror!void = null,
    focus_view_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    close_view_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    create_webview_fn: ?*const fn (context: ?*anyopaque, options: WebViewOptions) anyerror!void = null,
    set_webview_frame_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void = null,
    navigate_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, url: []const u8) anyerror!void = null,
    set_webview_zoom_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, zoom: f64) anyerror!void = null,
    set_webview_layer_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, layer: i32) anyerror!void = null,
    close_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    show_open_dialog_fn: ?*const fn (context: ?*anyopaque, options: OpenDialogOptions, buffer: []u8) anyerror!OpenDialogResult = null,
    show_save_dialog_fn: ?*const fn (context: ?*anyopaque, options: SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 = null,
    show_message_dialog_fn: ?*const fn (context: ?*anyopaque, options: MessageDialogOptions) anyerror!MessageDialogResult = null,
    show_notification_fn: ?*const fn (context: ?*anyopaque, options: NotificationOptions) anyerror!void = null,
    set_credential_fn: ?*const fn (context: ?*anyopaque, credential: Credential) anyerror!void = null,
    get_credential_fn: ?*const fn (context: ?*anyopaque, key: CredentialKey, buffer: []u8) anyerror![]const u8 = null,
    delete_credential_fn: ?*const fn (context: ?*anyopaque, key: CredentialKey) anyerror!void = null,
    open_external_url_fn: ?*const fn (context: ?*anyopaque, url: []const u8) anyerror!void = null,
    reveal_path_fn: ?*const fn (context: ?*anyopaque, path: []const u8) anyerror!void = null,
    add_recent_document_fn: ?*const fn (context: ?*anyopaque, path: []const u8) anyerror!void = null,
    clear_recent_documents_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    create_tray_fn: ?*const fn (context: ?*anyopaque, options: TrayOptions) anyerror!void = null,
    update_tray_menu_fn: ?*const fn (context: ?*anyopaque, items: []const TrayMenuItem) anyerror!void = null,
    remove_tray_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    configure_security_policy_fn: ?*const fn (context: ?*anyopaque, policy: security.Policy) anyerror!void = null,
    configure_menus_fn: ?*const fn (context: ?*anyopaque, menus: []const Menu) anyerror!void = null,
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

    pub fn readClipboardData(self: PlatformServices, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
        if (self.read_clipboard_data_fn) |read_fn| return read_fn(self.context, mime_type, buffer);
        if (isPlainTextMime(mime_type)) return self.readClipboard(buffer);
        return error.UnsupportedService;
    }

    pub fn writeClipboardData(self: PlatformServices, data: ClipboardData) anyerror!void {
        if (self.write_clipboard_data_fn) |write_fn| return write_fn(self.context, data);
        if (isPlainTextMime(data.mime_type)) return self.writeClipboard(data.bytes);
        return error.UnsupportedService;
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

    pub fn createView(self: PlatformServices, options: ViewOptions) anyerror!void {
        if (self.create_view_fn) |create_fn| return create_fn(self.context, options);
        if (options.kind == .webview) return self.createWebView(options.webViewOptions());
        return error.UnsupportedViewKind;
    }

    pub fn updateView(self: PlatformServices, window_id: WindowId, label: []const u8, patch: ViewPatch) anyerror!void {
        const update_fn = self.update_view_fn orelse return error.UnsupportedViewKind;
        return update_fn(self.context, window_id, label, patch);
    }

    pub fn setViewFrame(self: PlatformServices, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
        if (self.set_view_frame_fn) |set_fn| return set_fn(self.context, window_id, label, frame);
        if (std.mem.eql(u8, label, "main")) return self.setWebViewFrame(window_id, label, frame);
        return error.UnsupportedViewKind;
    }

    pub fn setViewVisible(self: PlatformServices, window_id: WindowId, label: []const u8, visible: bool) anyerror!void {
        const set_fn = self.set_view_visible_fn orelse return error.UnsupportedViewKind;
        return set_fn(self.context, window_id, label, visible);
    }

    pub fn focusView(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        const focus_fn = self.focus_view_fn orelse {
            return error.UnsupportedViewFocus;
        };
        return focus_fn(self.context, window_id, label);
    }

    pub fn closeView(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        if (self.close_view_fn) |close_fn| return close_fn(self.context, window_id, label);
        if (!std.mem.eql(u8, label, "main")) return self.closeWebView(window_id, label);
        return error.InvalidViewOptions;
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

    pub fn showNotification(self: PlatformServices, options: NotificationOptions) anyerror!void {
        const notify_fn = self.show_notification_fn orelse return error.UnsupportedService;
        return notify_fn(self.context, options);
    }

    pub fn setCredential(self: PlatformServices, credential: Credential) anyerror!void {
        const set_fn = self.set_credential_fn orelse return error.UnsupportedService;
        return set_fn(self.context, credential);
    }

    pub fn getCredential(self: PlatformServices, key: CredentialKey, buffer: []u8) anyerror![]const u8 {
        const get_fn = self.get_credential_fn orelse return error.UnsupportedService;
        return get_fn(self.context, key, buffer);
    }

    pub fn deleteCredential(self: PlatformServices, key: CredentialKey) anyerror!void {
        const delete_fn = self.delete_credential_fn orelse return error.UnsupportedService;
        return delete_fn(self.context, key);
    }

    pub fn openExternalUrl(self: PlatformServices, url: []const u8) anyerror!void {
        const open_fn = self.open_external_url_fn orelse return error.UnsupportedService;
        return open_fn(self.context, url);
    }

    pub fn revealPath(self: PlatformServices, path: []const u8) anyerror!void {
        const reveal_fn = self.reveal_path_fn orelse return error.UnsupportedService;
        return reveal_fn(self.context, path);
    }

    pub fn addRecentDocument(self: PlatformServices, path: []const u8) anyerror!void {
        const add_fn = self.add_recent_document_fn orelse return error.UnsupportedService;
        return add_fn(self.context, path);
    }

    pub fn clearRecentDocuments(self: PlatformServices) anyerror!void {
        const clear_fn = self.clear_recent_documents_fn orelse return error.UnsupportedService;
        return clear_fn(self.context);
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

    pub fn configureMenus(self: PlatformServices, menus: []const Menu) anyerror!void {
        const configure_fn = self.configure_menus_fn orelse {
            if (menus.len == 0) return;
            return error.UnsupportedService;
        };
        return configure_fn(self.context, menus);
    }

    pub fn configureShortcuts(self: PlatformServices, shortcuts: []const Shortcut) anyerror!void {
        const configure_fn = self.configure_shortcuts_fn orelse {
            if (shortcuts.len == 0) return;
            return error.UnsupportedService;
        };
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
    supports_fn: ?*const fn (context: *anyopaque, feature: PlatformFeature) bool = null,
    services: PlatformServices = .{},
    app_info: AppInfo = .{},

    pub fn surface(self: Platform) Surface {
        return self.surface_value;
    }

    pub fn run(self: Platform, handler: EventHandler, handler_context: *anyopaque) anyerror!void {
        return self.run_fn(self.context, handler, handler_context);
    }

    pub fn supports(self: Platform, feature: PlatformFeature) bool {
        if (self.supports_fn) |supports_fn| return supports_fn(self.context, feature);
        return defaultSupportsFeature(self.services, feature);
    }
};

fn defaultSupportsFeature(services: PlatformServices, feature: PlatformFeature) bool {
    return switch (feature) {
        .main_webview => services.load_window_webview_fn != null or services.load_webview_fn != null,
        .child_webviews => services.create_webview_fn != null,
        .native_views => services.create_view_fn != null,
        .native_control_commands => services.create_view_fn != null,
        .menus => services.configure_menus_fn != null,
        .tray => services.create_tray_fn != null,
        .shortcuts => services.configure_shortcuts_fn != null,
        .dialogs => services.show_open_dialog_fn != null or services.show_save_dialog_fn != null or services.show_message_dialog_fn != null,
        .clipboard_text => services.read_clipboard_fn != null and services.write_clipboard_fn != null,
        .clipboard_rich_data => services.read_clipboard_data_fn != null and services.write_clipboard_data_fn != null,
        .open_url => services.open_external_url_fn != null,
        .reveal_path => services.reveal_path_fn != null,
        .notifications => services.show_notification_fn != null,
        .recent_documents => services.add_recent_document_fn != null or services.clear_recent_documents_fn != null,
        .credentials => services.set_credential_fn != null and services.get_credential_fn != null and services.delete_credential_fn != null,
        .file_drops => false,
        .app_activation_events => false,
        .gpu_surfaces => false,
    };
}

pub const Backend = enum {
    null,
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
            .gpu_surfaces => false,
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
        if (options.kind == .gpu_surface) return error.UnsupportedViewKind;
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

const NullView = struct {
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

fn isPlainTextMime(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "text/plain") or std.mem.eql(u8, mime_type, "text");
}

fn isValidWebViewFrame(frame: geometry.RectF) bool {
    return frame.x >= 0 and frame.y >= 0 and frame.width > 0 and frame.height > 0;
}

fn isValidViewFrame(frame: geometry.RectF) bool {
    return frame.x >= 0 and frame.y >= 0 and frame.width >= 0 and frame.height >= 0;
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

test "null platform records OS actions" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try services.showNotification(.{
        .title = "Build finished",
        .subtitle = "zero-native",
        .body = "All checks passed.",
    });
    try services.openExternalUrl("https://example.com/docs");
    try services.revealPath("/tmp/example.txt");
    try services.addRecentDocument("/tmp/recent.txt");
    try services.writeClipboard("plain text");
    try services.setCredential(.{ .service = "dev.zero-native.test", .account = "alice", .secret = "secret-token" });
    try services.createTray(.{
        .icon_path = "/tmp/tray.png",
        .tooltip = "zero-native",
        .items = &.{
            .{ .id = 1, .label = "Open" },
            .{ .separator = true },
            .{ .id = 2, .label = "Quit", .enabled = false },
        },
    });

    try std.testing.expectEqual(@as(usize, 1), null_platform.notificationCount());
    try std.testing.expectEqualStrings("Build finished", null_platform.lastNotificationTitle());
    try std.testing.expectEqualStrings("zero-native", null_platform.lastNotificationSubtitle());
    try std.testing.expectEqualStrings("All checks passed.", null_platform.lastNotificationBody());
    try std.testing.expectEqualStrings("https://example.com/docs", null_platform.lastExternalUrl());
    try std.testing.expectEqualStrings("/tmp/example.txt", null_platform.lastRevealedPath());
    try std.testing.expectEqualStrings("/tmp/recent.txt", null_platform.lastRecentDocumentPath());
    try std.testing.expectEqual(@as(usize, 1), null_platform.clipboardWriteCount());
    try std.testing.expectEqualStrings("text/plain", null_platform.lastClipboardMimeType());
    try std.testing.expectEqualStrings("plain text", null_platform.lastClipboardData());
    var clipboard_buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("plain text", try services.readClipboard(&clipboard_buffer));

    try services.writeClipboardData(.{ .mime_type = "text/html", .bytes = "<strong>bold</strong>" });
    try std.testing.expectEqual(@as(usize, 2), null_platform.clipboardWriteCount());
    try std.testing.expectEqualStrings("text/html", null_platform.lastClipboardMimeType());
    try std.testing.expectEqualStrings("<strong>bold</strong>", try services.readClipboardData("text/html", &clipboard_buffer));
    try std.testing.expectError(error.UnsupportedService, services.readClipboardData("text/plain", &clipboard_buffer));

    try std.testing.expectEqual(@as(usize, 1), null_platform.credentialSetCount());
    try std.testing.expectEqualStrings("dev.zero-native.test", null_platform.lastCredentialService());
    try std.testing.expectEqualStrings("alice", null_platform.lastCredentialAccount());
    try std.testing.expectEqualStrings("secret-token", null_platform.lastCredentialSecret());
    try std.testing.expectEqual(@as(usize, 1), null_platform.trayCreateCount());
    try std.testing.expectEqualStrings("/tmp/tray.png", null_platform.lastTrayIconPath());
    try std.testing.expectEqualStrings("zero-native", null_platform.lastTrayTooltip());
    try std.testing.expectEqual(@as(usize, 3), null_platform.trayItems().len);
    try std.testing.expectEqual(@as(TrayItemId, 1), null_platform.trayItems()[0].id);
    try std.testing.expectEqualStrings("Open", null_platform.trayItems()[0].label);
    try std.testing.expect(null_platform.trayItems()[1].separator);
    try std.testing.expectEqual(@as(TrayItemId, 2), null_platform.trayItems()[2].id);
    try std.testing.expect(!null_platform.trayItems()[2].enabled);

    var credential_buffer: [64]u8 = undefined;
    const secret = try services.getCredential(.{ .service = "dev.zero-native.test", .account = "alice" }, &credential_buffer);
    try std.testing.expectEqualStrings("secret-token", secret);
    try std.testing.expectError(error.CredentialNotFound, services.getCredential(.{ .service = "dev.zero-native.test", .account = "bob" }, &credential_buffer));
    try services.deleteCredential(.{ .service = "dev.zero-native.test", .account = "alice" });
    try std.testing.expectEqual(@as(usize, 1), null_platform.credentialDeleteCount());
    try std.testing.expectError(error.CredentialNotFound, services.getCredential(.{ .service = "dev.zero-native.test", .account = "alice" }, &credential_buffer));

    try services.clearRecentDocuments();
    try std.testing.expectEqual(@as(usize, 1), null_platform.recentDocumentsClearedCount());
    try std.testing.expectEqualStrings("", null_platform.lastRecentDocumentPath());

    try services.updateTrayMenu(&.{.{ .id = 3, .label = "Settings" }});
    try std.testing.expectEqual(@as(usize, 2), null_platform.trayUpdateCount());
    try std.testing.expectEqual(@as(usize, 1), null_platform.trayItems().len);
    try std.testing.expectEqualStrings("Settings", null_platform.trayItems()[0].label);
    try services.removeTray();
    try std.testing.expectEqual(@as(usize, 1), null_platform.trayRemoveCount());
    try std.testing.expectEqual(@as(usize, 0), null_platform.trayItems().len);
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

test "null platform records configured menus" {
    const items = [_]MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
        .{ .separator = true },
        .{ .label = "Command Palette", .command = "app.palette", .key = "p", .modifiers = .{ .primary = true, .shift = true } },
    };
    const menus = [_]Menu{.{ .title = "App", .items = &items }};
    var null_platform = NullPlatform.init(.{});
    try null_platform.platform().services.configureMenus(&menus);

    try std.testing.expectEqual(@as(usize, 1), null_platform.configuredMenus().len);
    try std.testing.expectEqualStrings("App", null_platform.configuredMenus()[0].title);
    try std.testing.expectEqual(@as(usize, 3), null_platform.configuredMenus()[0].items.len);
    try std.testing.expectEqualStrings("app.refresh", null_platform.configuredMenus()[0].items[0].command);
    try std.testing.expect(null_platform.configuredMenus()[0].items[1].separator);

    const invalid_item = [_]MenuItem{.{ .label = "Missing Command" }};
    const invalid_menu = [_]Menu{.{ .title = "Invalid", .items = &invalid_item }};
    try std.testing.expectError(error.InvalidCommand, null_platform.platform().services.configureMenus(&invalid_menu));

    const unmodified_key_item = [_]MenuItem{.{ .label = "Refresh", .command = "app.refresh", .key = "r" }};
    const unmodified_key_menu = [_]Menu{.{ .title = "Invalid", .items = &unmodified_key_item }};
    try std.testing.expectError(error.InvalidShortcut, null_platform.platform().services.configureMenus(&unmodified_key_menu));
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

test "shortcut configuration requires backend support for non-empty lists" {
    const services = PlatformServices{};
    try services.configureShortcuts(&.{});

    const shortcuts = [_]Shortcut{
        .{ .id = "command.palette", .key = "p", .modifiers = .{ .primary = true } },
    };
    try std.testing.expectError(error.UnsupportedService, services.configureShortcuts(&shortcuts));
}

test "OS actions require backend support" {
    const services = PlatformServices{};

    try std.testing.expectError(error.UnsupportedService, services.showNotification(.{ .title = "Hello" }));
    try std.testing.expectError(error.UnsupportedService, services.openExternalUrl("https://example.com"));
    try std.testing.expectError(error.UnsupportedService, services.revealPath("/tmp/example.txt"));
    try std.testing.expectError(error.UnsupportedService, services.addRecentDocument("/tmp/example.txt"));
    try std.testing.expectError(error.UnsupportedService, services.clearRecentDocuments());
    var buffer: [32]u8 = undefined;
    try std.testing.expectError(error.UnsupportedService, services.readClipboard(&buffer));
    try std.testing.expectError(error.UnsupportedService, services.writeClipboard("plain"));
    try std.testing.expectError(error.UnsupportedService, services.readClipboardData("text/html", &buffer));
    try std.testing.expectError(error.UnsupportedService, services.writeClipboardData(.{ .mime_type = "text/html", .bytes = "<b>x</b>" }));
    try std.testing.expectError(error.UnsupportedService, services.setCredential(.{ .service = "service", .account = "account", .secret = "secret" }));
    try std.testing.expectError(error.UnsupportedService, services.getCredential(.{ .service = "service", .account = "account" }, &buffer));
    try std.testing.expectError(error.UnsupportedService, services.deleteCredential(.{ .service = "service", .account = "account" }));
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

test "null platform rejects invalid native view parents" {
    var null_platform = NullPlatform.init(.{});
    const services = null_platform.platform().services;

    try std.testing.expectError(error.ViewNotFound, services.createView(.{
        .label = "orphan",
        .kind = .button,
        .parent = "missing",
        .frame = geometry.RectF.init(0, 0, 96, 32),
    }));
    try std.testing.expectError(error.InvalidViewOptions, services.createView(.{
        .label = "self",
        .kind = .stack,
        .parent = "self",
        .frame = geometry.RectF.init(0, 0, 120, 80),
    }));
    try std.testing.expectEqual(@as(usize, 0), null_platform.view_count);

    try services.createView(.{
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 44),
    });
    try services.createView(.{
        .label = "action",
        .kind = .button,
        .parent = "toolbar",
        .frame = geometry.RectF.init(8, 8, 96, 32),
    });
    try std.testing.expectEqual(@as(usize, 2), null_platform.view_count);
    try std.testing.expectEqualStrings("toolbar", null_platform.views[1].parent.?);
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

test "file drop path splitter preserves embedded newlines" {
    var output: [max_drop_paths][]const u8 = undefined;
    const paths = splitDropPaths("/tmp/one\nname.txt\x00/tmp/two.txt", output[0..]);

    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/tmp/one\nname.txt", paths[0]);
    try std.testing.expectEqualStrings("/tmp/two.txt", paths[1]);
}

test {
    std.testing.refAllDecls(@This());
}
