const std = @import("std");

pub const ValidationError = error{
    InvalidId,
    InvalidName,
    InvalidVersion,
    InvalidDimension,
    DuplicateIcon,
    DuplicatePermission,
    DuplicateCapability,
    DuplicateBridgeCommand,
    DuplicateCommand,
    DuplicatePlatform,
    DuplicateWindow,
    DuplicateView,
    DuplicateShortcut,
    DuplicateFileAssociation,
    DuplicateUrlScheme,
    InvalidViewKind,
    InvalidLayout,
    InvalidUrl,
    InvalidPath,
    InvalidCommand,
    InvalidShortcut,
    InvalidTimeout,
    InvalidKeyword,
    MissingRequiredField,
    NoSpaceLeft,
};

pub const max_shortcuts: usize = 64;
pub const max_shortcut_id_bytes: usize = 64;
pub const max_shortcut_key_bytes: usize = 32;
pub const max_shell_windows: usize = 16;
pub const max_shell_views_per_window: usize = 128;
pub const max_view_label_bytes: usize = 64;
pub const max_view_role_bytes: usize = 64;
pub const max_view_accessibility_label_bytes: usize = 256;
pub const max_command_id_bytes: usize = 128;
pub const max_commands: usize = 256;
pub const max_command_title_bytes: usize = 128;
pub const max_menus: usize = 16;
pub const max_menu_items: usize = 128;
pub const max_menu_title_bytes: usize = 64;
pub const max_menu_item_label_bytes: usize = 128;
pub const max_menu_key_bytes: usize = 32;
pub const max_file_associations: usize = 32;
pub const max_file_association_extensions: usize = 32;
pub const max_file_association_mime_types: usize = 32;
pub const max_url_schemes: usize = 32;

pub const Platform = enum {
    macos,
    windows,
    linux,
    ios,
    android,
    web,
    unknown,
};

pub const PackageKind = enum {
    app,
    cli,
    library,
    plugin,
    test_fixture,
};

pub const WebEngine = enum {
    system,
    chromium,
};

pub const CefConfig = struct {
    dir: []const u8 = "third_party/cef/macos",
    auto_install: bool = false,
};

pub const IconPurpose = enum {
    any,
    maskable,
    monochrome,
};

pub const PermissionKind = enum {
    network,
    filesystem,
    camera,
    microphone,
    location,
    notifications,
    clipboard,
    window,
    command,
    view,
    dialog,
    credentials,
    custom,
};

pub const Permission = union(PermissionKind) {
    network: void,
    filesystem: void,
    camera: void,
    microphone: void,
    location: void,
    notifications: void,
    clipboard: void,
    window: void,
    command: void,
    view: void,
    dialog: void,
    credentials: void,
    custom: []const u8,

    pub fn kind(self: Permission) PermissionKind {
        return std.meta.activeTag(self);
    }
};

pub const CapabilityKind = enum {
    native_module,
    webview,
    js_bridge,
    native_views,
    gpu_surfaces,
    menus,
    shortcuts,
    tray,
    filesystem,
    network,
    notifications,
    dialog,
    clipboard,
    credentials,
    open_url,
    reveal_path,
    recent_documents,
    file_drops,
    app_activation_events,
    file_associations,
    url_schemes,
    custom,
};

pub const Capability = union(CapabilityKind) {
    native_module: void,
    webview: void,
    js_bridge: void,
    native_views: void,
    gpu_surfaces: void,
    menus: void,
    shortcuts: void,
    tray: void,
    filesystem: void,
    network: void,
    notifications: void,
    dialog: void,
    clipboard: void,
    credentials: void,
    open_url: void,
    reveal_path: void,
    recent_documents: void,
    file_drops: void,
    app_activation_events: void,
    file_associations: void,
    url_schemes: void,
    custom: []const u8,

    pub fn kind(self: Capability) CapabilityKind {
        return std.meta.activeTag(self);
    }
};

pub const AppIdentity = struct {
    id: []const u8,
    name: []const u8,
    display_name: ?[]const u8 = null,
    organization: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: ?[]const u8 = null,
    build: ?[]const u8 = null,
};

pub const Icon = struct {
    asset: []const u8,
    size: u32,
    scale: u32 = 1,
    purpose: ?IconPurpose = null,
};

pub const PlatformSettings = struct {
    platform: Platform,
    id_override: ?[]const u8 = null,
    min_os_version: ?[]const u8 = null,
    permissions: []const Permission = &.{},
    category: ?[]const u8 = null,
    entitlements: ?[]const u8 = null,
    profile: ?[]const u8 = null,
};

pub const BridgeCommand = struct {
    name: []const u8,
    permissions: []const Permission = &.{},
    origins: []const []const u8 = &.{},
};

pub const BridgeConfig = struct {
    commands: []const BridgeCommand = &.{},
};

pub const ExternalLinkAction = enum {
    deny,
    open_system_browser,
};

pub const ExternalLinkPolicy = struct {
    action: ExternalLinkAction = .deny,
    allowed_urls: []const []const u8 = &.{},
};

pub const NavigationPolicy = struct {
    allowed_origins: []const []const u8 = &.{ "zero://app", "zero://inline" },
    external_links: ExternalLinkPolicy = .{},
};

pub const SecurityConfig = struct {
    navigation: NavigationPolicy = .{},
};

pub const FrontendDevConfig = struct {
    url: []const u8,
    command: []const []const u8 = &.{},
    ready_path: []const u8 = "/",
    timeout_ms: u32 = 30_000,
};

pub const FrontendConfig = struct {
    dist: []const u8 = "dist",
    entry: []const u8 = "index.html",
    spa_fallback: bool = true,
    dev: ?FrontendDevConfig = null,
};

pub const WindowRestorePolicy = enum {
    clamp_to_visible_screen,
    center_on_primary,
};

pub const Window = struct {
    label: []const u8 = "main",
    title: ?[]const u8 = null,
    width: f32 = 720,
    height: f32 = 480,
    x: ?f32 = null,
    y: ?f32 = null,
    resizable: bool = true,
    restore_state: bool = true,
    restore_policy: WindowRestorePolicy = .clamp_to_visible_screen,
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

pub const ShellEdge = enum {
    top,
    right,
    bottom,
    left,
};

pub const ShellAxis = enum {
    row,
    column,
};

pub const ShellView = struct {
    label: []const u8,
    kind: ViewKind,
    parent: ?[]const u8 = null,
    edge: ?ShellEdge = null,
    axis: ?ShellAxis = null,
    x: ?f32 = null,
    y: ?f32 = null,
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,
    fill: bool = false,
    layer: i32 = 0,
    visible: bool = true,
    enabled: bool = true,
    role: ?[]const u8 = null,
    accessibility_label: ?[]const u8 = null,
    url: ?[]const u8 = null,
    text: ?[]const u8 = null,
    command: ?[]const u8 = null,
    gpu_backend: ?GpuSurfaceBackend = null,
    gpu_pixel_format: ?GpuSurfacePixelFormat = null,
    gpu_present_mode: ?GpuSurfacePresentMode = null,
    gpu_alpha_mode: ?GpuSurfaceAlphaMode = null,
    gpu_color_space: ?GpuSurfaceColorSpace = null,
    gpu_vsync: ?bool = null,

    pub fn hasGpuSurfaceOptions(self: ShellView) bool {
        return self.gpu_backend != null or
            self.gpu_pixel_format != null or
            self.gpu_present_mode != null or
            self.gpu_alpha_mode != null or
            self.gpu_color_space != null or
            self.gpu_vsync != null;
    }
};

pub const ShellWindow = struct {
    label: []const u8 = "main",
    title: ?[]const u8 = null,
    width: f32 = 720,
    height: f32 = 480,
    x: ?f32 = null,
    y: ?f32 = null,
    resizable: bool = true,
    restore_state: bool = true,
    restore_policy: WindowRestorePolicy = .clamp_to_visible_screen,
    views: []const ShellView = &.{},
};

pub const ShellConfig = struct {
    windows: []const ShellWindow = &.{},
};

pub const ShortcutModifiers = struct {
    primary: bool = false,
    command: bool = false,
    control: bool = false,
    option: bool = false,
    shift: bool = false,
};

pub const Shortcut = struct {
    id: []const u8,
    key: []const u8,
    modifiers: ShortcutModifiers = .{},
};

pub const Command = struct {
    id: []const u8,
    title: []const u8 = "",
    enabled: bool = true,
    checked: bool = false,
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

pub const AssociationRole = enum {
    viewer,
    editor,
    shell,
    none,
};

pub const FileAssociation = struct {
    name: []const u8,
    role: AssociationRole = .viewer,
    extensions: []const []const u8 = &.{},
    mime_types: []const []const u8 = &.{},
    icon: ?[]const u8 = null,
};

pub const UrlScheme = struct {
    scheme: []const u8,
    role: AssociationRole = .viewer,
};

pub const PackageMetadata = struct {
    kind: PackageKind = .app,
    web_engine: WebEngine = .system,
    license: ?[]const u8 = null,
    authors: []const []const u8 = &.{},
    repository: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
};

pub const UpdateConfig = struct {
    feed_url: ?[]const u8 = null,
    public_key: ?[]const u8 = null,
    check_on_start: bool = false,
};

pub const Manifest = struct {
    identity: AppIdentity,
    version: Version,
    icons: []const Icon = &.{},
    permissions: []const Permission = &.{},
    capabilities: []const Capability = &.{},
    bridge: BridgeConfig = .{},
    frontend: ?FrontendConfig = null,
    security: SecurityConfig = .{},
    platforms: []const PlatformSettings = &.{},
    windows: []const Window = &.{},
    shell: ShellConfig = .{},
    commands: []const Command = &.{},
    menus: []const Menu = &.{},
    shortcuts: []const Shortcut = &.{},
    file_associations: []const FileAssociation = &.{},
    url_schemes: []const UrlScheme = &.{},
    cef: CefConfig = .{},
    package: PackageMetadata = .{},
    updates: UpdateConfig = .{},
};
