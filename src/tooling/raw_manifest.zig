const web_engine = @import("web_engine.zig");

pub const RawManifest = struct {
    id: []const u8,
    name: []const u8,
    display_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    version: []const u8,
    icons: []const []const u8 = &.{},
    platforms: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},
    capabilities: []const []const u8 = &.{},
    persist: ?RawPersist = null,
    service_packages: []const RawServicePackage = &.{},
    /// Which carrier runs src/services operations: "auto" (the default child
    /// carrier), "in_process", or "child".
    service_carrier: []const u8 = "auto",
    /// In-process service pool width (1-16); 0 keeps the runtime default
    /// (min(4, cores)).
    service_pool_size: u8 = 0,
    bridge: RawBridge = .{},
    web_engine: []const u8 = @tagName(web_engine.default_engine),
    webview_layer: []const u8 = "auto",
    /// How a TypeScript core compiles: "external" (the default and only
    /// lane — the external core compiler). The removed transpiled
    /// lane's spelling is refused with a teaching at validation.
    core_compiler: []const u8 = "external",
    theme: ?[]const u8 = null,
    theme_accent: ?[]const u8 = null,
    cef: RawCef = .{},
    frontend: ?RawFrontend = null,
    security: RawSecurity = .{},
    assets: RawAssets = .{},
    windows: []const RawWindow = &.{},
    shell: RawShell = .{},
    commands: []const RawCommand = &.{},
    menus: []const RawMenu = &.{},
    shortcuts: []const RawShortcut = &.{},
    file_associations: []const RawFileAssociation = &.{},
    url_schemes: []const RawUrlScheme = &.{},
    dmg: RawDmg = .{},
};

pub const RawServicePackage = struct {
    name: []const u8,
    version: []const u8,
    content_hash: []const u8,
};

pub const RawPersist = struct {
    version: u64,
    debounce_ms: u32 = 500,
    restore: RawPersistRestore,
};

pub const RawPersistRestore = struct {
    ok: []const u8,
    none: []const u8,
    err: []const u8,
};

pub const RawCef = struct {
    dir: []const u8 = web_engine.default_cef_dir,
    auto_install: bool = false,
};

pub const RawBridge = struct {
    commands: []const RawBridgeCommand = &.{},
};

pub const RawBridgeCommand = struct {
    name: []const u8,
    permissions: []const []const u8 = &.{},
    origins: []const []const u8 = &.{},
};

pub const RawFrontend = struct {
    dist: []const u8 = "dist",
    entry: []const u8 = "index.html",
    spa_fallback: bool = true,
    dev: ?RawFrontendDev = null,
};

pub const RawFrontendDev = struct {
    url: []const u8,
    command: []const []const u8 = &.{},
    ready_path: []const u8 = "/",
    timeout_ms: u32 = 30_000,
};

pub const RawSecurity = struct {
    navigation: RawNavigation = .{},
};

/// Launch-registered assets (the TypeScript-core wiring's image channel):
/// each image is read once at launch and registered on the installing
/// frame under its declared `ImageId` — the id markup avatar bindings
/// reference.
pub const RawAssets = struct {
    images: []const RawImageAsset = &.{},
};

pub const RawImageAsset = struct {
    id: u64,
    path: []const u8,
};

pub const RawNavigation = struct {
    allowed_origins: []const []const u8 = &.{},
    external_links: RawExternalLinks = .{},
};

pub const RawExternalLinks = struct {
    action: []const u8 = "deny",
    allowed_urls: []const []const u8 = &.{},
};

pub const RawWindow = struct {
    label: []const u8 = "main",
    title: ?[]const u8 = null,
    width: f32 = 720,
    height: f32 = 480,
    x: ?f32 = null,
    y: ?f32 = null,
    resizable: bool = true,
    restore_state: bool = true,
    titlebar: []const u8 = "standard",
    transparent: bool = false,
    always_on_top: bool = false,
    click_through: bool = false,
    activate_on_show: bool = true,
    initially_hidden: bool = false,
    allows_fullscreen: bool = true,
    min_width: f32 = 0,
    min_height: f32 = 0,
    close_policy: []const u8 = "quit",
};

pub const RawShell = struct {
    windows: []const RawShellWindow = &.{},
    chrome: RawShellChrome = .{},
};

pub const RawShellChrome = struct {
    tabs: []const RawShellTab = &.{},
    primary_action: ?RawShellPrimaryAction = null,
};

pub const RawShellTab = struct {
    id: []const u8,
    label: []const u8,
    icon: []const u8 = "",
};

pub const RawShellPrimaryAction = struct {
    id: []const u8,
    label: []const u8,
    icon: []const u8 = "",
};

pub const RawShellWindow = struct {
    label: []const u8 = "main",
    title: ?[]const u8 = null,
    width: f32 = 720,
    height: f32 = 480,
    x: ?f32 = null,
    y: ?f32 = null,
    resizable: bool = true,
    restore_state: bool = true,
    restore_policy: []const u8 = "clamp_to_visible_screen",
    titlebar: []const u8 = "standard",
    transparent: bool = false,
    always_on_top: bool = false,
    click_through: bool = false,
    activate_on_show: bool = true,
    initially_hidden: bool = false,
    allows_fullscreen: bool = true,
    min_width: f32 = 0,
    min_height: f32 = 0,
    close_policy: []const u8 = "quit",
    views: []const RawShellView = &.{},
};

pub const RawShellView = struct {
    label: []const u8,
    kind: []const u8,
    parent: ?[]const u8 = null,
    edge: ?[]const u8 = null,
    axis: ?[]const u8 = null,
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
    gpu_backend: ?[]const u8 = null,
    gpu_pixel_format: ?[]const u8 = null,
    gpu_present_mode: ?[]const u8 = null,
    gpu_alpha_mode: ?[]const u8 = null,
    gpu_color_space: ?[]const u8 = null,
    gpu_vsync: ?bool = null,
};

pub const RawShortcut = struct {
    id: []const u8,
    key: []const u8,
    modifiers: []const []const u8 = &.{},
};

pub const RawCommand = struct {
    id: []const u8,
    title: []const u8 = "",
    enabled: bool = true,
    checked: bool = false,
};

pub const RawMenu = struct {
    title: []const u8,
    items: []const RawMenuItem = &.{},
};

pub const RawMenuItem = struct {
    label: []const u8 = "",
    command: []const u8 = "",
    key: []const u8 = "",
    modifiers: []const []const u8 = &.{},
    separator: bool = false,
    enabled: bool = true,
    checked: bool = false,
};

pub const RawFileAssociation = struct {
    name: []const u8,
    role: []const u8 = "viewer",
    extensions: []const []const u8 = &.{},
    mime_types: []const []const u8 = &.{},
    icon: ?[]const u8 = null,
};

pub const RawUrlScheme = struct {
    scheme: []const u8,
    role: []const u8 = "viewer",
};

pub const RawDmgPosition = struct {
    x: u16,
    y: u16,
};

/// One visible Finder item in an explicitly art-directed DMG. `app` names
/// the packaged bundle (and may override its DMG-only display name),
/// `applications` creates the conventional alias,
/// `file` copies a project-relative file or directory, and `link` creates a
/// symlink to an absolute path. An explicit list replaces the legacy fixed
/// app/Applications pair.
pub const RawDmgItem = struct {
    kind: []const u8,
    path: ?[]const u8 = null,
    name: ?[]const u8 = null,
    position: RawDmgPosition,
};

/// Finder presentation for the macOS archive produced by
/// `native package --target macos --archive`. The defaults are a complete
/// drag-to-Applications layout; apps only declare this block when they want
/// to art-direct it.
pub const RawDmg = struct {
    volume_name: ?[]const u8 = null,
    background: ?[]const u8 = null,
    window_width: u16 = 660,
    window_height: u16 = 400,
    icon_size: u16 = 128,
    app_position: RawDmgPosition = .{ .x = 166, .y = 182 },
    applications_position: RawDmgPosition = .{ .x = 486, .y = 182 },
    applications_link: bool = true,
    items: []const RawDmgItem = &.{},
};
