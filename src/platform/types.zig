const std = @import("std");
const geometry = @import("geometry");
const security = @import("../security/root.zig");

pub const default_gpu_frame_interval_ns: u64 = 16_666_667;
pub const default_gpu_first_frame_latency_budget_ns: u64 = 150_000_000;

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
    InvalidGpuSurfacePixels,
    InvalidGpuSurfacePacket,
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
pub const max_widget_accessibility_nodes: usize = 64;
pub const max_gpu_surface_packet_json_bytes: usize = 128 * 1024;

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

pub const GpuSurfaceBackend = enum {
    none,
    metal,
};

pub const GpuSurfacePixelFormat = enum {
    none,
    bgra8_unorm,
};

pub const GpuSurfacePresentMode = enum {
    none,
    timer,
};

pub const GpuSurfaceAlphaMode = enum {
    none,
    @"opaque",
    premultiplied,
};

pub const GpuSurfaceColorSpace = enum {
    none,
    srgb,
    display_p3,
};

pub const GpuSurfaceStatus = enum {
    unavailable,
    initializing,
    ready,
    lost,
};

pub const CanvasFrameProfileRisk = enum {
    idle,
    low,
    moderate,
    high,
};

pub const GpuSurfaceOptions = struct {
    backend: GpuSurfaceBackend = .metal,
    pixel_format: GpuSurfacePixelFormat = .bgra8_unorm,
    present_mode: GpuSurfacePresentMode = .timer,
    alpha_mode: GpuSurfaceAlphaMode = .@"opaque",
    color_space: GpuSurfaceColorSpace = .srgb,
    vsync: bool = true,

    pub fn isSupported(self: GpuSurfaceOptions) bool {
        return self.backend == .metal and
            self.pixel_format == .bgra8_unorm and
            self.present_mode == .timer and
            self.alpha_mode == .@"opaque" and
            self.color_space == .srgb and
            self.vsync;
    }
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
    gpu_surface: GpuSurfaceOptions = .{},

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

pub const Cursor = enum {
    arrow,
    pointing_hand,
    text,
    resize_horizontal,
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
    gpu_size: geometry.SizeF = geometry.SizeF.init(0, 0),
    gpu_scale_factor: f32 = 1,
    gpu_frame_index: u64 = 0,
    gpu_timestamp_ns: u64 = 0,
    gpu_frame_interval_ns: u64 = default_gpu_frame_interval_ns,
    gpu_input_timestamp_ns: u64 = 0,
    gpu_input_latency_ns: u64 = 0,
    gpu_input_latency_budget_ns: u64 = default_gpu_frame_interval_ns,
    gpu_input_latency_budget_exceeded_count: usize = 0,
    gpu_input_latency_budget_ok: bool = true,
    gpu_first_frame_latency_ns: u64 = 0,
    gpu_first_frame_latency_budget_ns: u64 = default_gpu_first_frame_latency_budget_ns,
    gpu_first_frame_latency_budget_exceeded_count: usize = 0,
    gpu_first_frame_latency_budget_ok: bool = true,
    gpu_frame_nonblank: bool = false,
    gpu_sample_color: u32 = 0,
    gpu_backend: GpuSurfaceBackend = .none,
    gpu_pixel_format: GpuSurfacePixelFormat = .none,
    gpu_present_mode: GpuSurfacePresentMode = .none,
    gpu_alpha_mode: GpuSurfaceAlphaMode = .none,
    gpu_color_space: GpuSurfaceColorSpace = .none,
    gpu_vsync: bool = false,
    gpu_status: GpuSurfaceStatus = .unavailable,
    canvas_revision: u64 = 0,
    canvas_command_count: usize = 0,
    canvas_frame_requires_render: bool = false,
    canvas_frame_full_repaint: bool = false,
    canvas_frame_batch_count: usize = 0,
    canvas_frame_encoder_command_count: usize = 0,
    canvas_frame_encoder_cache_action_count: usize = 0,
    canvas_frame_encoder_bind_pipeline_count: usize = 0,
    canvas_frame_encoder_draw_batch_count: usize = 0,
    canvas_frame_pipeline_count: usize = 0,
    canvas_frame_pipeline_upload_count: usize = 0,
    canvas_frame_pipeline_retain_count: usize = 0,
    canvas_frame_pipeline_evict_count: usize = 0,
    canvas_frame_path_geometry_count: usize = 0,
    canvas_frame_path_geometry_vertex_count: usize = 0,
    canvas_frame_path_geometry_index_count: usize = 0,
    canvas_frame_path_geometry_upload_count: usize = 0,
    canvas_frame_path_geometry_retain_count: usize = 0,
    canvas_frame_path_geometry_evict_count: usize = 0,
    canvas_frame_image_count: usize = 0,
    canvas_frame_image_upload_count: usize = 0,
    canvas_frame_image_retain_count: usize = 0,
    canvas_frame_image_evict_count: usize = 0,
    canvas_frame_layer_count: usize = 0,
    canvas_frame_layer_opacity_count: usize = 0,
    canvas_frame_layer_clip_count: usize = 0,
    canvas_frame_layer_transform_count: usize = 0,
    canvas_frame_layer_upload_count: usize = 0,
    canvas_frame_layer_retain_count: usize = 0,
    canvas_frame_layer_evict_count: usize = 0,
    canvas_frame_resource_count: usize = 0,
    canvas_frame_resource_upload_count: usize = 0,
    canvas_frame_resource_retain_count: usize = 0,
    canvas_frame_resource_evict_count: usize = 0,
    canvas_frame_visual_effect_count: usize = 0,
    canvas_frame_visual_effect_shadow_count: usize = 0,
    canvas_frame_visual_effect_blur_count: usize = 0,
    canvas_frame_visual_effect_upload_count: usize = 0,
    canvas_frame_visual_effect_retain_count: usize = 0,
    canvas_frame_visual_effect_evict_count: usize = 0,
    canvas_frame_glyph_atlas_entry_count: usize = 0,
    canvas_frame_glyph_atlas_upload_count: usize = 0,
    canvas_frame_glyph_atlas_retain_count: usize = 0,
    canvas_frame_glyph_atlas_evict_count: usize = 0,
    canvas_frame_text_layout_count: usize = 0,
    canvas_frame_text_layout_line_count: usize = 0,
    canvas_frame_text_layout_upload_count: usize = 0,
    canvas_frame_text_layout_retain_count: usize = 0,
    canvas_frame_text_layout_evict_count: usize = 0,
    canvas_frame_gpu_packet_command_count: usize = 0,
    canvas_frame_gpu_packet_cache_action_count: usize = 0,
    canvas_frame_gpu_packet_cached_resource_command_count: usize = 0,
    canvas_frame_gpu_packet_unsupported_command_count: usize = 0,
    canvas_frame_gpu_packet_representable: bool = true,
    canvas_frame_change_count: usize = 0,
    canvas_frame_budget_exceeded_count: usize = 0,
    canvas_frame_budget_ok: bool = true,
    canvas_frame_dirty_bounds: ?geometry.RectF = null,
    canvas_frame_profile_work_units: usize = 0,
    canvas_frame_profile_risk: CanvasFrameProfileRisk = .idle,
    canvas_frame_profile_surface_area: f32 = 0,
    canvas_frame_profile_dirty_area: f32 = 0,
    canvas_frame_profile_dirty_ratio: f32 = 0,
    widget_revision: u64 = 0,
    widget_node_count: usize = 0,
    widget_semantics_count: usize = 0,
    cursor: Cursor = .arrow,
    focused: bool = false,
    open: bool = true,

    pub fn gpuFrame(self: ViewInfo) ?GpuFrame {
        if (self.kind != .gpu_surface) return null;
        return .{
            .surface_id = self.id,
            .window_id = self.window_id,
            .label = self.label,
            .size = self.gpu_size,
            .scale_factor = self.gpu_scale_factor,
            .frame_index = self.gpu_frame_index,
            .timestamp_ns = self.gpu_timestamp_ns,
            .frame_interval_ns = self.gpu_frame_interval_ns,
            .input_timestamp_ns = self.gpu_input_timestamp_ns,
            .input_latency_ns = self.gpu_input_latency_ns,
            .input_latency_budget_ns = self.gpu_input_latency_budget_ns,
            .input_latency_budget_exceeded_count = self.gpu_input_latency_budget_exceeded_count,
            .input_latency_budget_ok = self.gpu_input_latency_budget_ok,
            .first_frame_latency_ns = self.gpu_first_frame_latency_ns,
            .first_frame_latency_budget_ns = self.gpu_first_frame_latency_budget_ns,
            .first_frame_latency_budget_exceeded_count = self.gpu_first_frame_latency_budget_exceeded_count,
            .first_frame_latency_budget_ok = self.gpu_first_frame_latency_budget_ok,
            .nonblank = self.gpu_frame_nonblank,
            .sample_color = self.gpu_sample_color,
            .backend = self.gpu_backend,
            .pixel_format = self.gpu_pixel_format,
            .present_mode = self.gpu_present_mode,
            .alpha_mode = self.gpu_alpha_mode,
            .color_space = self.gpu_color_space,
            .vsync = self.gpu_vsync,
            .status = self.gpu_status,
            .canvas_revision = self.canvas_revision,
            .canvas_command_count = self.canvas_command_count,
            .canvas_frame_requires_render = self.canvas_frame_requires_render,
            .canvas_frame_full_repaint = self.canvas_frame_full_repaint,
            .canvas_frame_batch_count = self.canvas_frame_batch_count,
            .canvas_frame_encoder_command_count = self.canvas_frame_encoder_command_count,
            .canvas_frame_encoder_cache_action_count = self.canvas_frame_encoder_cache_action_count,
            .canvas_frame_encoder_bind_pipeline_count = self.canvas_frame_encoder_bind_pipeline_count,
            .canvas_frame_encoder_draw_batch_count = self.canvas_frame_encoder_draw_batch_count,
            .canvas_frame_pipeline_count = self.canvas_frame_pipeline_count,
            .canvas_frame_pipeline_upload_count = self.canvas_frame_pipeline_upload_count,
            .canvas_frame_pipeline_retain_count = self.canvas_frame_pipeline_retain_count,
            .canvas_frame_pipeline_evict_count = self.canvas_frame_pipeline_evict_count,
            .canvas_frame_path_geometry_count = self.canvas_frame_path_geometry_count,
            .canvas_frame_path_geometry_vertex_count = self.canvas_frame_path_geometry_vertex_count,
            .canvas_frame_path_geometry_index_count = self.canvas_frame_path_geometry_index_count,
            .canvas_frame_path_geometry_upload_count = self.canvas_frame_path_geometry_upload_count,
            .canvas_frame_path_geometry_retain_count = self.canvas_frame_path_geometry_retain_count,
            .canvas_frame_path_geometry_evict_count = self.canvas_frame_path_geometry_evict_count,
            .canvas_frame_image_count = self.canvas_frame_image_count,
            .canvas_frame_image_upload_count = self.canvas_frame_image_upload_count,
            .canvas_frame_image_retain_count = self.canvas_frame_image_retain_count,
            .canvas_frame_image_evict_count = self.canvas_frame_image_evict_count,
            .canvas_frame_layer_count = self.canvas_frame_layer_count,
            .canvas_frame_layer_opacity_count = self.canvas_frame_layer_opacity_count,
            .canvas_frame_layer_clip_count = self.canvas_frame_layer_clip_count,
            .canvas_frame_layer_transform_count = self.canvas_frame_layer_transform_count,
            .canvas_frame_layer_upload_count = self.canvas_frame_layer_upload_count,
            .canvas_frame_layer_retain_count = self.canvas_frame_layer_retain_count,
            .canvas_frame_layer_evict_count = self.canvas_frame_layer_evict_count,
            .canvas_frame_resource_count = self.canvas_frame_resource_count,
            .canvas_frame_resource_upload_count = self.canvas_frame_resource_upload_count,
            .canvas_frame_resource_retain_count = self.canvas_frame_resource_retain_count,
            .canvas_frame_resource_evict_count = self.canvas_frame_resource_evict_count,
            .canvas_frame_visual_effect_count = self.canvas_frame_visual_effect_count,
            .canvas_frame_visual_effect_shadow_count = self.canvas_frame_visual_effect_shadow_count,
            .canvas_frame_visual_effect_blur_count = self.canvas_frame_visual_effect_blur_count,
            .canvas_frame_visual_effect_upload_count = self.canvas_frame_visual_effect_upload_count,
            .canvas_frame_visual_effect_retain_count = self.canvas_frame_visual_effect_retain_count,
            .canvas_frame_visual_effect_evict_count = self.canvas_frame_visual_effect_evict_count,
            .canvas_frame_glyph_atlas_entry_count = self.canvas_frame_glyph_atlas_entry_count,
            .canvas_frame_glyph_atlas_upload_count = self.canvas_frame_glyph_atlas_upload_count,
            .canvas_frame_glyph_atlas_retain_count = self.canvas_frame_glyph_atlas_retain_count,
            .canvas_frame_glyph_atlas_evict_count = self.canvas_frame_glyph_atlas_evict_count,
            .canvas_frame_text_layout_count = self.canvas_frame_text_layout_count,
            .canvas_frame_text_layout_line_count = self.canvas_frame_text_layout_line_count,
            .canvas_frame_text_layout_upload_count = self.canvas_frame_text_layout_upload_count,
            .canvas_frame_text_layout_retain_count = self.canvas_frame_text_layout_retain_count,
            .canvas_frame_text_layout_evict_count = self.canvas_frame_text_layout_evict_count,
            .canvas_frame_gpu_packet_command_count = self.canvas_frame_gpu_packet_command_count,
            .canvas_frame_gpu_packet_cache_action_count = self.canvas_frame_gpu_packet_cache_action_count,
            .canvas_frame_gpu_packet_cached_resource_command_count = self.canvas_frame_gpu_packet_cached_resource_command_count,
            .canvas_frame_gpu_packet_unsupported_command_count = self.canvas_frame_gpu_packet_unsupported_command_count,
            .canvas_frame_gpu_packet_representable = self.canvas_frame_gpu_packet_representable,
            .canvas_frame_change_count = self.canvas_frame_change_count,
            .canvas_frame_budget_exceeded_count = self.canvas_frame_budget_exceeded_count,
            .canvas_frame_budget_ok = self.canvas_frame_budget_ok,
            .canvas_frame_dirty_bounds = self.canvas_frame_dirty_bounds,
            .canvas_frame_profile_work_units = self.canvas_frame_profile_work_units,
            .canvas_frame_profile_risk = self.canvas_frame_profile_risk,
            .canvas_frame_profile_surface_area = self.canvas_frame_profile_surface_area,
            .canvas_frame_profile_dirty_area = self.canvas_frame_profile_dirty_area,
            .canvas_frame_profile_dirty_ratio = self.canvas_frame_profile_dirty_ratio,
            .widget_revision = self.widget_revision,
            .widget_node_count = self.widget_node_count,
            .widget_semantics_count = self.widget_semantics_count,
        };
    }
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
    safe_area_insets: geometry.InsetsF = .{},
    keyboard_insets: geometry.InsetsF = .{},
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
    view_label: []const u8 = "",
    point: ?geometry.PointF = null,
    paths: []const []const u8 = &.{},
};

pub const GpuFrame = struct {
    surface_id: ViewId = 0,
    window_id: WindowId = 1,
    label: []const u8 = "",
    size: geometry.SizeF = geometry.SizeF.init(0, 0),
    scale_factor: f32 = 1,
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    frame_interval_ns: u64 = default_gpu_frame_interval_ns,
    input_timestamp_ns: u64 = 0,
    input_latency_ns: u64 = 0,
    input_latency_budget_ns: u64 = default_gpu_frame_interval_ns,
    input_latency_budget_exceeded_count: usize = 0,
    input_latency_budget_ok: bool = true,
    first_frame_latency_ns: u64 = 0,
    first_frame_latency_budget_ns: u64 = default_gpu_first_frame_latency_budget_ns,
    first_frame_latency_budget_exceeded_count: usize = 0,
    first_frame_latency_budget_ok: bool = true,
    nonblank: bool = false,
    sample_color: u32 = 0,
    backend: GpuSurfaceBackend = .none,
    pixel_format: GpuSurfacePixelFormat = .none,
    present_mode: GpuSurfacePresentMode = .none,
    alpha_mode: GpuSurfaceAlphaMode = .none,
    color_space: GpuSurfaceColorSpace = .none,
    vsync: bool = false,
    status: GpuSurfaceStatus = .unavailable,
    canvas_revision: u64 = 0,
    canvas_command_count: usize = 0,
    canvas_frame_requires_render: bool = false,
    canvas_frame_full_repaint: bool = false,
    canvas_frame_batch_count: usize = 0,
    canvas_frame_encoder_command_count: usize = 0,
    canvas_frame_encoder_cache_action_count: usize = 0,
    canvas_frame_encoder_bind_pipeline_count: usize = 0,
    canvas_frame_encoder_draw_batch_count: usize = 0,
    canvas_frame_pipeline_count: usize = 0,
    canvas_frame_pipeline_upload_count: usize = 0,
    canvas_frame_pipeline_retain_count: usize = 0,
    canvas_frame_pipeline_evict_count: usize = 0,
    canvas_frame_path_geometry_count: usize = 0,
    canvas_frame_path_geometry_vertex_count: usize = 0,
    canvas_frame_path_geometry_index_count: usize = 0,
    canvas_frame_path_geometry_upload_count: usize = 0,
    canvas_frame_path_geometry_retain_count: usize = 0,
    canvas_frame_path_geometry_evict_count: usize = 0,
    canvas_frame_image_count: usize = 0,
    canvas_frame_image_upload_count: usize = 0,
    canvas_frame_image_retain_count: usize = 0,
    canvas_frame_image_evict_count: usize = 0,
    canvas_frame_layer_count: usize = 0,
    canvas_frame_layer_opacity_count: usize = 0,
    canvas_frame_layer_clip_count: usize = 0,
    canvas_frame_layer_transform_count: usize = 0,
    canvas_frame_layer_upload_count: usize = 0,
    canvas_frame_layer_retain_count: usize = 0,
    canvas_frame_layer_evict_count: usize = 0,
    canvas_frame_resource_count: usize = 0,
    canvas_frame_resource_upload_count: usize = 0,
    canvas_frame_resource_retain_count: usize = 0,
    canvas_frame_resource_evict_count: usize = 0,
    canvas_frame_visual_effect_count: usize = 0,
    canvas_frame_visual_effect_shadow_count: usize = 0,
    canvas_frame_visual_effect_blur_count: usize = 0,
    canvas_frame_visual_effect_upload_count: usize = 0,
    canvas_frame_visual_effect_retain_count: usize = 0,
    canvas_frame_visual_effect_evict_count: usize = 0,
    canvas_frame_glyph_atlas_entry_count: usize = 0,
    canvas_frame_glyph_atlas_upload_count: usize = 0,
    canvas_frame_glyph_atlas_retain_count: usize = 0,
    canvas_frame_glyph_atlas_evict_count: usize = 0,
    canvas_frame_text_layout_count: usize = 0,
    canvas_frame_text_layout_line_count: usize = 0,
    canvas_frame_text_layout_upload_count: usize = 0,
    canvas_frame_text_layout_retain_count: usize = 0,
    canvas_frame_text_layout_evict_count: usize = 0,
    canvas_frame_gpu_packet_command_count: usize = 0,
    canvas_frame_gpu_packet_cache_action_count: usize = 0,
    canvas_frame_gpu_packet_cached_resource_command_count: usize = 0,
    canvas_frame_gpu_packet_unsupported_command_count: usize = 0,
    canvas_frame_gpu_packet_representable: bool = true,
    canvas_frame_change_count: usize = 0,
    canvas_frame_budget_exceeded_count: usize = 0,
    canvas_frame_budget_ok: bool = true,
    canvas_frame_dirty_bounds: ?geometry.RectF = null,
    canvas_frame_profile_work_units: usize = 0,
    canvas_frame_profile_risk: CanvasFrameProfileRisk = .idle,
    canvas_frame_profile_surface_area: f32 = 0,
    canvas_frame_profile_dirty_area: f32 = 0,
    canvas_frame_profile_dirty_ratio: f32 = 0,
    widget_revision: u64 = 0,
    widget_node_count: usize = 0,
    widget_semantics_count: usize = 0,
};

pub const GpuSurfaceFrameEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    size: geometry.SizeF,
    scale_factor: f32 = 1,
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    frame_interval_ns: u64 = default_gpu_frame_interval_ns,
    input_timestamp_ns: u64 = 0,
    input_latency_ns: u64 = 0,
    input_latency_budget_ns: u64 = default_gpu_frame_interval_ns,
    input_latency_budget_exceeded_count: usize = 0,
    input_latency_budget_ok: bool = true,
    first_frame_latency_ns: u64 = 0,
    first_frame_latency_budget_ns: u64 = default_gpu_first_frame_latency_budget_ns,
    first_frame_latency_budget_exceeded_count: usize = 0,
    first_frame_latency_budget_ok: bool = true,
    nonblank: bool = false,
    sample_color: u32 = 0,
    backend: GpuSurfaceBackend = .metal,
    pixel_format: GpuSurfacePixelFormat = .bgra8_unorm,
    present_mode: GpuSurfacePresentMode = .timer,
    alpha_mode: GpuSurfaceAlphaMode = .@"opaque",
    color_space: GpuSurfaceColorSpace = .srgb,
    vsync: bool = true,
    status: GpuSurfaceStatus = .ready,
    canvas_revision: u64 = 0,
    canvas_command_count: usize = 0,
    canvas_frame_requires_render: bool = false,
    canvas_frame_full_repaint: bool = false,
    canvas_frame_batch_count: usize = 0,
    canvas_frame_encoder_command_count: usize = 0,
    canvas_frame_encoder_cache_action_count: usize = 0,
    canvas_frame_encoder_bind_pipeline_count: usize = 0,
    canvas_frame_encoder_draw_batch_count: usize = 0,
    canvas_frame_pipeline_count: usize = 0,
    canvas_frame_pipeline_upload_count: usize = 0,
    canvas_frame_pipeline_retain_count: usize = 0,
    canvas_frame_pipeline_evict_count: usize = 0,
    canvas_frame_path_geometry_count: usize = 0,
    canvas_frame_path_geometry_vertex_count: usize = 0,
    canvas_frame_path_geometry_index_count: usize = 0,
    canvas_frame_path_geometry_upload_count: usize = 0,
    canvas_frame_path_geometry_retain_count: usize = 0,
    canvas_frame_path_geometry_evict_count: usize = 0,
    canvas_frame_image_count: usize = 0,
    canvas_frame_image_upload_count: usize = 0,
    canvas_frame_image_retain_count: usize = 0,
    canvas_frame_image_evict_count: usize = 0,
    canvas_frame_layer_count: usize = 0,
    canvas_frame_layer_opacity_count: usize = 0,
    canvas_frame_layer_clip_count: usize = 0,
    canvas_frame_layer_transform_count: usize = 0,
    canvas_frame_layer_upload_count: usize = 0,
    canvas_frame_layer_retain_count: usize = 0,
    canvas_frame_layer_evict_count: usize = 0,
    canvas_frame_resource_count: usize = 0,
    canvas_frame_resource_upload_count: usize = 0,
    canvas_frame_resource_retain_count: usize = 0,
    canvas_frame_resource_evict_count: usize = 0,
    canvas_frame_visual_effect_count: usize = 0,
    canvas_frame_visual_effect_shadow_count: usize = 0,
    canvas_frame_visual_effect_blur_count: usize = 0,
    canvas_frame_visual_effect_upload_count: usize = 0,
    canvas_frame_visual_effect_retain_count: usize = 0,
    canvas_frame_visual_effect_evict_count: usize = 0,
    canvas_frame_glyph_atlas_entry_count: usize = 0,
    canvas_frame_glyph_atlas_upload_count: usize = 0,
    canvas_frame_glyph_atlas_retain_count: usize = 0,
    canvas_frame_glyph_atlas_evict_count: usize = 0,
    canvas_frame_text_layout_count: usize = 0,
    canvas_frame_text_layout_line_count: usize = 0,
    canvas_frame_text_layout_upload_count: usize = 0,
    canvas_frame_text_layout_retain_count: usize = 0,
    canvas_frame_text_layout_evict_count: usize = 0,
    canvas_frame_gpu_packet_command_count: usize = 0,
    canvas_frame_gpu_packet_cache_action_count: usize = 0,
    canvas_frame_gpu_packet_cached_resource_command_count: usize = 0,
    canvas_frame_gpu_packet_unsupported_command_count: usize = 0,
    canvas_frame_gpu_packet_representable: bool = true,
    canvas_frame_change_count: usize = 0,
    canvas_frame_budget_exceeded_count: usize = 0,
    canvas_frame_budget_ok: bool = true,
    canvas_frame_dirty_bounds: ?geometry.RectF = null,
    canvas_frame_profile_work_units: usize = 0,
    canvas_frame_profile_risk: CanvasFrameProfileRisk = .idle,
    canvas_frame_profile_surface_area: f32 = 0,
    canvas_frame_profile_dirty_area: f32 = 0,
    canvas_frame_profile_dirty_ratio: f32 = 0,
    widget_revision: u64 = 0,
    widget_node_count: usize = 0,
    widget_semantics_count: usize = 0,
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
    pointer_cancel,
    pointer_move,
    pointer_drag,
    scroll,
    key_down,
    key_up,
    text_input,
    ime_set_composition,
    ime_commit_composition,
    ime_cancel_composition,
};

pub const GpuSurfaceInputEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    kind: GpuSurfaceInputKind,
    timestamp_ns: u64 = 0,
    pointer_id: u64 = 0,
    x: f32 = 0,
    y: f32 = 0,
    button: i32 = 0,
    pressure: f32 = 0,
    delta_x: f32 = 0,
    delta_y: f32 = 0,
    key: []const u8 = "",
    text: []const u8 = "",
    composition_cursor: ?usize = null,
    modifiers: ShortcutModifiers = .{},
};

pub const GpuSurfacePixels = struct {
    window_id: WindowId = 1,
    label: []const u8,
    width: usize,
    height: usize,
    scale_factor: f32 = 1,
    dirty_bounds: ?geometry.RectF = null,
    rgba8: []const u8,

    pub fn expectedByteLen(self: GpuSurfacePixels) ?usize {
        if (self.width == 0 or self.height == 0) return null;
        const pixels = std.math.mul(usize, self.width, self.height) catch return null;
        return std.math.mul(usize, pixels, 4) catch return null;
    }
};

pub const GpuSurfacePacket = struct {
    window_id: WindowId = 1,
    label: []const u8,
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    surface_size: geometry.SizeF = .{},
    scale_factor: f32 = 1,
    clear_color_rgba8: [4]u8 = .{ 0, 0, 0, 255 },
    requires_render: bool = false,
    command_count: usize = 0,
    cache_action_count: usize = 0,
    cached_resource_command_count: usize = 0,
    unsupported_command_count: usize = 0,
    representable: bool = true,
    json: []const u8 = "",
};

pub const WidgetAccessibilityRole = enum(c_int) {
    none = 0,
    group = 1,
    text = 2,
    image = 3,
    button = 4,
    textbox = 5,
    tooltip = 6,
    dialog = 7,
    menu = 8,
    menuitem = 9,
    list = 10,
    listitem = 11,
    row = 12,
    grid = 13,
    gridcell = 14,
    tab = 15,
    checkbox = 16,
    switch_control = 17,
    slider = 18,
    progressbar = 19,
    radio = 20,
};

pub const WidgetAccessibilityActions = struct {
    focus: bool = false,
    press: bool = false,
    toggle: bool = false,
    increment: bool = false,
    decrement: bool = false,
    set_text: bool = false,
    set_selection: bool = false,
    select: bool = false,
    drag: bool = false,
    drop_files: bool = false,
    dismiss: bool = false,
};

pub const WidgetAccessibilityTextRange = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const WidgetAccessibilityNode = struct {
    id: u64 = 0,
    parent_id: ?u64 = null,
    role: WidgetAccessibilityRole = .none,
    label: []const u8 = "",
    text_value: []const u8 = "",
    placeholder: []const u8 = "",
    text_selection: ?WidgetAccessibilityTextRange = null,
    text_composition: ?WidgetAccessibilityTextRange = null,
    value: ?f32 = null,
    bounds: geometry.RectF = .{},
    grid_row_index: ?usize = null,
    grid_column_index: ?usize = null,
    grid_row_count: ?usize = null,
    grid_column_count: ?usize = null,
    list_item_index: ?u32 = null,
    list_item_count: ?u32 = null,
    scroll_offset: ?f32 = null,
    scroll_viewport_extent: ?f32 = null,
    scroll_content_extent: ?f32 = null,
    enabled: bool = true,
    focused: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    selected: bool = false,
    expanded: ?bool = null,
    required: bool = false,
    read_only: bool = false,
    invalid: bool = false,
    focusable: bool = false,
    actions: WidgetAccessibilityActions = .{},
};

pub const WidgetAccessibilitySnapshot = struct {
    window_id: WindowId = 1,
    view_label: []const u8,
    nodes: []const WidgetAccessibilityNode = &.{},
};

pub const WidgetAccessibilityActionKind = enum(c_int) {
    focus = 0,
    press = 1,
    toggle = 2,
    increment = 3,
    decrement = 4,
    set_text = 5,
    set_selection = 6,
    select = 7,
    drag = 8,
    drop_files = 9,
    dismiss = 10,
};

pub const WidgetAccessibilityActionEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    id: u64,
    action: WidgetAccessibilityActionKind,
    text: []const u8 = "",
    selection: ?WidgetAccessibilityTextRange = null,
};

pub const ClipboardData = struct {
    mime_type: []const u8 = "text/plain",
    bytes: []const u8,
};

pub const ColorScheme = enum {
    light,
    dark,
};

pub const Appearance = struct {
    color_scheme: ColorScheme = .light,
    reduce_motion: bool = false,
    high_contrast: bool = false,
};

pub const Event = union(enum) {
    app_start,
    app_activated,
    app_deactivated,
    appearance_changed: Appearance,
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
    widget_accessibility_action: WidgetAccessibilityActionEvent,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .app_start => "app_start",
            .app_activated => "app_activated",
            .app_deactivated => "app_deactivated",
            .appearance_changed => "appearance_changed",
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
            .widget_accessibility_action => "widget_accessibility_action",
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
    set_view_cursor_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, cursor: Cursor) anyerror!void = null,
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
    configure_automation_frame_polling_fn: ?*const fn (context: ?*anyopaque, enabled: bool) anyerror!void = null,
    emit_window_event_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void = null,
    request_gpu_surface_frame_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    present_gpu_surface_pixels_fn: ?*const fn (context: ?*anyopaque, pixels: GpuSurfacePixels) anyerror!void = null,
    present_gpu_surface_packet_fn: ?*const fn (context: ?*anyopaque, packet: GpuSurfacePacket) anyerror!void = null,
    update_widget_accessibility_fn: ?*const fn (context: ?*anyopaque, snapshot: WidgetAccessibilitySnapshot) anyerror!void = null,

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

    pub fn setViewCursor(self: PlatformServices, window_id: WindowId, label: []const u8, cursor: Cursor) anyerror!void {
        const set_fn = self.set_view_cursor_fn orelse return;
        return set_fn(self.context, window_id, label, cursor);
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

    pub fn configureAutomationFramePolling(self: PlatformServices, enabled: bool) anyerror!void {
        const configure_fn = self.configure_automation_frame_polling_fn orelse return;
        return configure_fn(self.context, enabled);
    }

    pub fn emitWindowEvent(self: PlatformServices, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
        const emit_fn = self.emit_window_event_fn orelse return error.UnsupportedService;
        return emit_fn(self.context, window_id, name, detail_json);
    }

    pub fn requestGpuSurfaceFrame(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        if (label.len == 0 or label.len > max_view_label_bytes) return error.InvalidViewOptions;
        const request_fn = self.request_gpu_surface_frame_fn orelse return;
        return request_fn(self.context, window_id, label);
    }

    pub fn presentGpuSurfacePixels(self: PlatformServices, pixels: GpuSurfacePixels) anyerror!void {
        const expected = pixels.expectedByteLen() orelse return error.InvalidGpuSurfacePixels;
        if (pixels.rgba8.len != expected) return error.InvalidGpuSurfacePixels;
        if (pixels.label.len == 0 or pixels.label.len > max_view_label_bytes) return error.InvalidGpuSurfacePixels;
        const present_fn = self.present_gpu_surface_pixels_fn orelse return error.UnsupportedService;
        return present_fn(self.context, pixels);
    }

    pub fn presentGpuSurfacePacket(self: PlatformServices, packet: GpuSurfacePacket) anyerror!void {
        if (packet.label.len == 0 or packet.label.len > max_view_label_bytes) return error.InvalidGpuSurfacePacket;
        if (packet.json.len == 0 or packet.json.len > max_gpu_surface_packet_json_bytes) return error.InvalidGpuSurfacePacket;
        const present_fn = self.present_gpu_surface_packet_fn orelse return error.UnsupportedService;
        return present_fn(self.context, packet);
    }

    pub fn updateWidgetAccessibility(self: PlatformServices, snapshot: WidgetAccessibilitySnapshot) anyerror!void {
        if (snapshot.view_label.len == 0 or snapshot.view_label.len > max_view_label_bytes) return error.InvalidViewOptions;
        if (snapshot.nodes.len > max_widget_accessibility_nodes) return error.InvalidViewOptions;
        const update_fn = self.update_widget_accessibility_fn orelse return;
        return update_fn(self.context, snapshot);
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

fn isPlainTextMime(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "text/plain") or std.mem.eql(u8, mime_type, "text");
}

pub const Backend = enum {
    null,
    macos,
    linux,
    windows,
};
