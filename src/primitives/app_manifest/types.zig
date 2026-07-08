const std = @import("std");

pub const ValidationError = error{
    InvalidId,
    InvalidName,
    InvalidDescription,
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
/// The declared platform-chrome tab cap: the platform tab-bar idiom
/// holds two to five destinations, and a set that would not fit a real
/// system bar is refused at validation instead of squeezed at runtime.
pub const max_shell_tabs: usize = 5;
/// Chrome tab/action labels are control titles, not prose.
pub const max_shell_chrome_label_bytes: usize = max_command_title_bytes;
/// Chrome icon references are icon-vocabulary names (optionally
/// `app:`-namespaced), never paths.
pub const max_shell_chrome_icon_bytes: usize = 64;
pub const max_menus: usize = 16;
pub const max_menu_items: usize = 128;
pub const max_menu_title_bytes: usize = 64;
pub const max_menu_item_label_bytes: usize = 128;
pub const max_menu_key_bytes: usize = 32;
pub const max_file_associations: usize = 32;
pub const max_file_association_extensions: usize = 32;
pub const max_file_association_mime_types: usize = 32;
pub const max_url_schemes: usize = 32;
/// Cap for the identity `description` — one sentence, not a README.
pub const max_description_bytes: usize = 256;

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
    /// One human-facing sentence about the app (the About-panel credits
    /// line on macOS). Single line, at most `max_description_bytes`.
    description: ?[]const u8 = null,
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

/// How the window draws its titlebar chrome. `.hidden_inset` is the
/// modern editor-app shape: content extends under a transparent titlebar
/// with the title hidden (macOS keeps the traffic lights). The app's
/// own header takes over the titlebar's job: mark it
/// `window-drag="true"` so it moves the window, and pad it by the
/// runtime's chrome insets so it clears the traffic lights. Platforms
/// without the concept keep standard chrome.
///
/// `.hidden_inset_tall` is the same shape with the TALL titlebar band —
/// the unified-toolbar height (~52pt vs ~28pt), where
/// macOS vertically centers the traffic lights in the band. Declare it
/// when the header row replacing the titlebar is toolbar-height, so the
/// lights center against it instead of sitting high.
///
/// `.chromeless` removes ALL OS chrome — the titlebar band AND the
/// system window buttons (macOS drops the traffic lights, Windows the
/// DWM caption buttons, Linux the header-bar CSD). An EXPLICIT opt-in
/// for fully-skinned apps whose chassis draws its OWN working
/// close/minimize controls (wired to the runtime's real window-action
/// effects); ordinary apps should declare the hidden styles above,
/// which keep the real OS controls on every desktop.
pub const WindowTitlebarStyle = enum {
    standard,
    hidden_inset,
    hidden_inset_tall,
    chromeless,
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
    /// Titlebar chrome for the window the HOST creates at startup —
    /// threaded through the platform create call, so the main window
    /// can hide its titlebar before the scene loads.
    titlebar: WindowTitlebarStyle = .standard,
    /// Content min-size floor the window itself enforces (macOS
    /// `contentMinSize`): the resize stops at the floor instead of the
    /// layout clamping/clipping panes below it. 0 = no floor.
    min_width: f32 = 0,
    min_height: f32 = 0,
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
    software,
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
    /// Titlebar chrome. Windows the runtime CREATES (scene windows
    /// beyond the first, model-declared windows) apply it at create
    /// time. The STARTUP window is created by the host from app
    /// options before the scene loads — app.zon's `.shell.windows[0]`
    /// (or a top-level `.windows[0]`) threads it through to that
    /// create, and the scene's first window here should declare the
    /// SAME style so the two never disagree.
    titlebar: WindowTitlebarStyle = .standard,
    /// Content min-size floor the window itself enforces (macOS
    /// `contentMinSize`): the resize stops at the floor instead of the
    /// layout clamping/clipping panes below it. 0 = no floor. Like
    /// `titlebar`, the STARTUP window applies it at the host create —
    /// app.zon's first window declaration threads it through — and
    /// runtime-created windows apply their own declaration at create.
    min_width: f32 = 0,
    min_height: f32 = 0,
    views: []const ShellView = &.{},
};

/// One declared platform-chrome tab. `id` is a command id: a tap on the
/// projected native control dispatches it through the same command event
/// path menus and native header buttons use, and the app maps it to a
/// Msg via `on_command` — the bar is never the source of truth for
/// selection. `icon` names an icon from the icon vocabulary (a built-in
/// name, or `app:<name>` for an app-registered icon); the projecting
/// host rasterizes the app's own glyph into a template image the system
/// control tints, so the artwork is the app's while the bar's styling
/// stays whatever the OS ships.
pub const ShellTab = struct {
    id: []const u8,
    label: []const u8,
    icon: []const u8 = "",
};

/// The optional single primary action declared beside the tab set — the
/// one floating action button of the platform idiom. Same shape and
/// dispatch contract as a tab: `id` is the command a press dispatches,
/// `label` the accessibility title, `icon` the vocabulary glyph.
pub const ShellPrimaryAction = struct {
    id: []const u8,
    label: []const u8,
    icon: []const u8 = "",
};

/// Declared platform chrome: UI the app asks the HOST to project as
/// REAL native controls (on iOS an actual system tab bar and a real
/// button — current with whatever the OS ships, never imitated in
/// canvas). Selection state lives in the app's model; the projected bar
/// mirrors it (`selected_tab_fn`) and taps dispatch command events back
/// into update, so the projection is deterministic and replayable.
/// Hosts without a projection (desktop windows today, Android until its
/// round lands) leave the declaration inert: nothing renders, nothing
/// dispatches, and the app's own canvas chrome stays in charge.
pub const ShellChrome = struct {
    tabs: []const ShellTab = &.{},
    primary_action: ?ShellPrimaryAction = null,
};

pub const ShellConfig = struct {
    windows: []const ShellWindow = &.{},
    chrome: ShellChrome = .{},
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
