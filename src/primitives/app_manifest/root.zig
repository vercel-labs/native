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

pub fn validateManifest(manifest: Manifest) ValidationError!void {
    try validateIdentity(manifest.identity);
    try validateVersion(manifest.version);
    try validateIcons(manifest.icons);
    try validatePermissions(manifest.permissions);
    try validateCapabilities(manifest.capabilities);
    try validateBridge(manifest.bridge);
    if (manifest.frontend) |frontend| try validateFrontend(frontend);
    try validateSecurity(manifest.security);
    try validatePlatforms(manifest.platforms);
    try validateWindows(manifest.windows);
    try validateShell(manifest.shell, manifest.windows);
    try validateCommands(manifest.commands);
    try validateMenus(manifest.menus);
    try validateShortcutsForPlatforms(manifest.shortcuts, manifest.platforms);
    try validateFileAssociations(manifest.file_associations);
    try validateUrlSchemes(manifest.url_schemes);
    try validateCefConfig(manifest.package.web_engine, manifest.cef);
    try validatePackageMetadata(manifest.package);
    try validateUpdates(manifest.updates);
}

pub fn validateIdentity(identity: AppIdentity) ValidationError!void {
    try validateAppId(identity.id, .reverse_dns);
    try validateName(identity.name);
    if (identity.display_name) |display_name| try validateName(display_name);
    if (identity.organization) |organization| try validateName(organization);
    if (identity.homepage) |homepage| try validateUrl(homepage);
}

pub fn validateVersion(version: Version) ValidationError!void {
    if (version.pre) |pre| try validateVersionPart(pre);
    if (version.build) |build| try validateVersionPart(build);
}

pub fn validateWindows(windows: []const Window) ValidationError!void {
    for (windows, 0..) |window, index| {
        if (window.label.len == 0) return error.InvalidName;
        if (window.width <= 0 or window.height <= 0) return error.InvalidDimension;
        var prior: usize = 0;
        while (prior < index) : (prior += 1) {
            if (std.mem.eql(u8, windows[prior].label, window.label)) return error.DuplicateWindow;
        }
    }
}

pub fn validateShell(shell: ShellConfig, compatibility_windows: []const Window) ValidationError!void {
    if (shell.windows.len > max_shell_windows) return error.InvalidLayout;
    for (shell.windows, 0..) |window, index| {
        try validateShellWindow(window);
        for (compatibility_windows) |compatibility_window| {
            if (std.mem.eql(u8, compatibility_window.label, window.label)) return error.DuplicateWindow;
        }
        for (shell.windows[0..index]) |previous| {
            if (std.mem.eql(u8, previous.label, window.label)) return error.DuplicateWindow;
        }
    }
}

fn validateShellWindow(window: ShellWindow) ValidationError!void {
    if (window.label.len == 0) return error.InvalidName;
    try validateName(window.label);
    if (window.title) |title| try validateName(title);
    if (window.width <= 0 or window.height <= 0) return error.InvalidDimension;
    if (window.views.len > max_shell_views_per_window) return error.InvalidLayout;
    try validateShellViews(window.views);
}

fn validateShellViews(views: []const ShellView) ValidationError!void {
    for (views, 0..) |view, index| {
        if (view.label.len == 0 or view.label.len > max_view_label_bytes) return error.InvalidName;
        try validateName(view.label);
        for (views[0..index]) |previous| {
            if (std.mem.eql(u8, previous.label, view.label)) return error.DuplicateView;
        }
        if (view.parent) |parent| {
            try validateName(parent);
            if (std.mem.eql(u8, parent, view.label) or shellViewIndex(views, parent) == null) return error.InvalidLayout;
        }
        if (view.width) |width| if (width <= 0) return error.InvalidDimension;
        if (view.height) |height| if (height <= 0) return error.InvalidDimension;
        if (view.min_width) |min_width| if (min_width < 0) return error.InvalidDimension;
        if (view.min_height) |min_height| if (min_height < 0) return error.InvalidDimension;
        if (view.max_width) |max_width| if (max_width <= 0) return error.InvalidDimension;
        if (view.max_height) |max_height| if (max_height <= 0) return error.InvalidDimension;
        if (view.min_width) |min_width| {
            if (view.max_width) |max_width| if (min_width > max_width) return error.InvalidDimension;
        }
        if (view.min_height) |min_height| {
            if (view.max_height) |max_height| if (min_height > max_height) return error.InvalidDimension;
        }
        if (view.role) |role| {
            if (role.len > max_view_role_bytes) return error.InvalidName;
            try validateName(role);
        }
        if (view.accessibility_label) |accessibility_label| {
            if (accessibility_label.len > max_view_accessibility_label_bytes) return error.InvalidName;
            try validateFreeText(accessibility_label);
        }
        if (view.text) |text| try validateFreeText(text);
        if (view.command) |command| {
            try validateCommandId(command);
        }
        if (view.url) |url| try validateViewUrl(url);
        if (view.kind == .webview and view.url == null) return error.MissingRequiredField;
    }
    try validateShellViewParentGraph(views);
}

const ShellViewVisitState = enum {
    unvisited,
    visiting,
    visited,
};

fn validateShellViewParentGraph(views: []const ShellView) ValidationError!void {
    var states = [_]ShellViewVisitState{.unvisited} ** max_shell_views_per_window;
    for (views, 0..) |_, index| {
        try validateShellViewParentAcyclic(views, index, &states);
    }
}

fn validateShellViewParentAcyclic(views: []const ShellView, index: usize, states: *[max_shell_views_per_window]ShellViewVisitState) ValidationError!void {
    switch (states[index]) {
        .visited => return,
        .visiting => return error.InvalidLayout,
        .unvisited => {},
    }

    states[index] = .visiting;
    if (views[index].parent) |parent| {
        const parent_index = shellViewIndex(views, parent) orelse return error.InvalidLayout;
        try validateShellViewParentAcyclic(views, parent_index, states);
    }
    states[index] = .visited;
}

fn shellViewIndex(views: []const ShellView, label: []const u8) ?usize {
    for (views, 0..) |view, index| {
        if (std.mem.eql(u8, view.label, label)) return index;
    }
    return null;
}

pub fn validateShortcuts(shortcuts: []const Shortcut) ValidationError!void {
    return validateShortcutsForPlatforms(shortcuts, &.{});
}

pub fn validateCommands(commands: []const Command) ValidationError!void {
    if (commands.len > max_commands) return error.InvalidCommand;
    for (commands, 0..) |command, index| {
        try validateCommandId(command.id);
        if (command.title.len > max_command_title_bytes) return error.InvalidName;
        try validateFreeText(command.title);
        for (commands[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, command.id)) return error.DuplicateCommand;
        }
    }
}

fn validateCommandId(id: []const u8) ValidationError!void {
    if (id.len == 0 or id.len > max_command_id_bytes) return error.InvalidCommand;
    try validateName(id);
    for (id) |ch| {
        if (ch == '\n' or ch == '\r' or ch == '\t') return error.InvalidCommand;
    }
}

pub fn validateMenus(menus: []const Menu) ValidationError!void {
    if (menus.len > max_menus) return error.InvalidLayout;
    var item_count: usize = 0;
    for (menus) |menu| {
        if (menu.title.len > max_menu_title_bytes) return error.InvalidName;
        try validateName(menu.title);
        item_count += menu.items.len;
        if (item_count > max_menu_items) return error.InvalidLayout;
        for (menu.items) |item| try validateMenuItem(item);
    }
}

fn validateMenuItem(item: MenuItem) ValidationError!void {
    if (item.separator) return;
    if (item.label.len > max_menu_item_label_bytes) return error.InvalidName;
    try validateName(item.label);
    try validateCommandId(item.command);
    if (item.key.len > 0) {
        if (item.key.len > max_menu_key_bytes) return error.InvalidShortcut;
        try validateShortcutKey(item.key);
        if (!shortcutModifiersHasAny(item.modifiers) and shortcutRequiresModifier(item.key)) return error.InvalidShortcut;
    }
}

pub fn validateFileAssociations(file_associations: []const FileAssociation) ValidationError!void {
    if (file_associations.len > max_file_associations) return error.InvalidPath;
    for (file_associations, 0..) |association, i| {
        try validateName(association.name);
        if (association.extensions.len == 0 and association.mime_types.len == 0) return error.MissingRequiredField;
        if (association.extensions.len > max_file_association_extensions) return error.InvalidPath;
        if (association.mime_types.len > max_file_association_mime_types) return error.InvalidPath;
        if (association.icon) |icon| try validateRelativePath(icon);
        for (association.extensions, 0..) |extension, extension_index| {
            try validateFileExtension(extension);
            for (association.extensions[0..extension_index]) |previous| {
                if (std.ascii.eqlIgnoreCase(extensionBody(previous), extensionBody(extension))) return error.DuplicateFileAssociation;
            }
        }
        for (association.mime_types, 0..) |mime_type, mime_index| {
            try validateMimeType(mime_type);
            for (association.mime_types[0..mime_index]) |previous| {
                if (std.ascii.eqlIgnoreCase(previous, mime_type)) return error.DuplicateFileAssociation;
            }
        }
        for (file_associations[0..i]) |previous| {
            if (std.mem.eql(u8, previous.name, association.name)) return error.DuplicateFileAssociation;
            for (association.extensions) |extension| {
                for (previous.extensions) |previous_extension| {
                    if (std.ascii.eqlIgnoreCase(extensionBody(previous_extension), extensionBody(extension))) return error.DuplicateFileAssociation;
                }
            }
        }
    }
}

pub fn validateUrlSchemes(url_schemes: []const UrlScheme) ValidationError!void {
    if (url_schemes.len > max_url_schemes) return error.InvalidUrl;
    for (url_schemes, 0..) |scheme, i| {
        try validateUrlScheme(scheme.scheme);
        for (url_schemes[0..i]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.scheme, scheme.scheme)) return error.DuplicateUrlScheme;
        }
    }
}

pub fn validateShortcutsForPlatforms(shortcuts: []const Shortcut, platforms: []const PlatformSettings) ValidationError!void {
    if (shortcuts.len > max_shortcuts) return error.InvalidShortcut;
    for (shortcuts, 0..) |shortcut, i| {
        if (shortcut.id.len > max_shortcut_id_bytes) return error.InvalidShortcut;
        try validateName(shortcut.id);
        try validateShortcutKey(shortcut.key);
        if (!shortcutModifiersHasAny(shortcut.modifiers) and shortcutRequiresModifier(shortcut.key)) return error.InvalidShortcut;
        for (shortcuts[0..i]) |previous| {
            if (std.mem.eql(u8, previous.id, shortcut.id)) return error.DuplicateShortcut;
            if (std.ascii.eqlIgnoreCase(previous.key, shortcut.key) and shortcutModifiersCollide(previous.modifiers, shortcut.modifiers, platforms)) return error.DuplicateShortcut;
        }
    }
}

pub fn validateCefConfig(web_engine: WebEngine, cef: CefConfig) ValidationError!void {
    _ = web_engine;
    if (cef.dir.len == 0) return error.InvalidPath;
    try validateRelativePath(cef.dir);
}

pub const AppIdMode = enum {
    reverse_dns,
    simple,
};

pub fn validateAppId(id: []const u8, mode: AppIdMode) ValidationError!void {
    if (id.len == 0) return error.InvalidId;
    if (id[0] == '.' or id[id.len - 1] == '.') return error.InvalidId;

    var segments: usize = 0;
    var segment_start: usize = 0;
    var segment_len: usize = 0;

    for (id, 0..) |ch, i| {
        if (ch == 0 or ch == '/' or ch == '\\') return error.InvalidId;
        if (ch == '.') {
            try validateIdSegment(id[segment_start..i], segment_len);
            segments += 1;
            segment_start = i + 1;
            segment_len = 0;
            continue;
        }
        if (!isLowerAlpha(ch) and !isDigit(ch) and ch != '-' and ch != '_') return error.InvalidId;
        segment_len += 1;
    }

    try validateIdSegment(id[segment_start..], segment_len);
    segments += 1;

    if (mode == .reverse_dns and segments < 2) return error.InvalidId;
}

pub fn validateName(name: []const u8) ValidationError!void {
    if (name.len == 0) return error.InvalidName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    for (name) |ch| {
        if (ch == 0 or ch == '/' or ch == '\\') return error.InvalidName;
    }
}

pub fn validateUrl(url: []const u8) ValidationError!void {
    const prefix_len: usize = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        return error.InvalidUrl;

    if (url.len == prefix_len) return error.InvalidUrl;
    const rest = url[prefix_len..];
    const slash_index = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..slash_index];
    if (host.len == 0) return error.InvalidUrl;
    for (host) |ch| {
        if (ch == 0 or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') return error.InvalidUrl;
    }
}

fn validateFileExtension(extension: []const u8) ValidationError!void {
    if (extension.len == 0) return error.InvalidPath;
    const body = extensionBody(extension);
    if (body.len == 0) return error.InvalidPath;
    for (body) |ch| {
        if (!isLowerAlpha(ch) and !isUpperAlpha(ch) and !isDigit(ch) and ch != '-' and ch != '_') return error.InvalidPath;
    }
}

fn extensionBody(extension: []const u8) []const u8 {
    return if (extension.len > 0 and extension[0] == '.') extension[1..] else extension;
}

fn validateMimeType(mime_type: []const u8) ValidationError!void {
    const slash_index = std.mem.indexOfScalar(u8, mime_type, '/') orelse return error.InvalidPath;
    if (slash_index == 0 or slash_index + 1 >= mime_type.len) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, mime_type[slash_index + 1 ..], '/') != null) return error.InvalidPath;
    try validateMimeToken(mime_type[0..slash_index]);
    try validateMimeToken(mime_type[slash_index + 1 ..]);
}

fn validateMimeToken(token: []const u8) ValidationError!void {
    if (token.len == 0) return error.InvalidPath;
    for (token) |ch| {
        if (!isMimeTokenChar(ch)) return error.InvalidPath;
    }
}

fn isMimeTokenChar(ch: u8) bool {
    return ch >= '!' and ch <= '~' and
        ch != '(' and ch != ')' and ch != '<' and ch != '>' and ch != '@' and
        ch != ',' and ch != ';' and ch != ':' and ch != '\\' and ch != '"' and
        ch != '/' and ch != '[' and ch != ']' and ch != '?' and ch != '=';
}

fn validateUrlScheme(scheme: []const u8) ValidationError!void {
    if (scheme.len == 0) return error.InvalidUrl;
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "file")) return error.InvalidUrl;
    if (!isLowerAlpha(scheme[0])) return error.InvalidUrl;
    for (scheme[1..]) |ch| {
        if (!isLowerAlpha(ch) and !isDigit(ch) and ch != '+' and ch != '-' and ch != '.') return error.InvalidUrl;
    }
}

pub fn validateIcons(icons: []const Icon) ValidationError!void {
    for (icons, 0..) |icon, i| {
        if (icon.asset.len == 0) return error.MissingRequiredField;
        if (icon.size == 0 or icon.scale == 0) return error.InvalidVersion;
        for (icons[0..i]) |previous| {
            if (previous.size == icon.size and previous.scale == icon.scale and previous.purpose == icon.purpose) {
                return error.DuplicateIcon;
            }
        }
    }
}

pub fn validatePermissions(permissions: []const Permission) ValidationError!void {
    for (permissions, 0..) |permission, i| {
        if (permission == .custom) try validateName(permission.custom);
        for (permissions[0..i]) |previous| {
            if (permissionEql(previous, permission)) return error.DuplicatePermission;
        }
    }
}

pub fn validateCapabilities(capabilities: []const Capability) ValidationError!void {
    for (capabilities, 0..) |capability, i| {
        if (capability == .custom) try validateName(capability.custom);
        for (capabilities[0..i]) |previous| {
            if (previous.kind() == capability.kind()) {
                if (capability != .custom or std.mem.eql(u8, previous.custom, capability.custom)) return error.DuplicateCapability;
            }
        }
    }
}

pub fn validateBridge(bridge: BridgeConfig) ValidationError!void {
    for (bridge.commands, 0..) |command, i| {
        try validateName(command.name);
        try validatePermissions(command.permissions);
        for (command.origins) |origin| try validateBridgeOrigin(origin);
        for (bridge.commands[0..i]) |previous| {
            if (std.mem.eql(u8, previous.name, command.name)) return error.DuplicateBridgeCommand;
        }
    }
}

pub fn validateFrontend(frontend: FrontendConfig) ValidationError!void {
    try validateRelativePath(frontend.dist);
    try validateRelativePath(frontend.entry);
    if (frontend.dev) |dev| {
        try validateUrl(dev.url);
        if (dev.command.len == 0) return error.MissingRequiredField;
        for (dev.command) |arg| {
            if (arg.len == 0) return error.InvalidCommand;
            for (arg) |ch| {
                if (ch == 0) return error.InvalidCommand;
            }
        }
        try validateReadyPath(dev.ready_path);
        if (dev.timeout_ms == 0) return error.InvalidTimeout;
    }
}

pub fn validateBridgeOrigin(origin: []const u8) ValidationError!void {
    if (std.mem.eql(u8, origin, "*")) return;
    if (std.mem.startsWith(u8, origin, "http://") or std.mem.startsWith(u8, origin, "https://")) {
        return validateUrl(origin);
    }
    if (std.mem.startsWith(u8, origin, "file://") or std.mem.startsWith(u8, origin, "zero://")) {
        const value = origin[std.mem.indexOf(u8, origin, "://").? + 3 ..];
        if (value.len == 0) return error.InvalidUrl;
        for (value) |ch| {
            if (ch == 0 or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') return error.InvalidUrl;
        }
        return;
    }
    return error.InvalidUrl;
}

fn validateViewUrl(url: []const u8) ValidationError!void {
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) return validateUrl(url);
    if (std.mem.startsWith(u8, url, "file://") or std.mem.startsWith(u8, url, "zero://")) {
        const value = url[std.mem.indexOf(u8, url, "://").? + 3 ..];
        if (value.len == 0) return error.InvalidUrl;
        for (value) |ch| {
            if (ch == 0 or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') return error.InvalidUrl;
        }
        return;
    }
    return error.InvalidUrl;
}

fn validateFreeText(text: []const u8) ValidationError!void {
    for (text) |ch| {
        if (ch == 0) return error.InvalidName;
    }
}

pub fn validateSecurity(security: SecurityConfig) ValidationError!void {
    for (security.navigation.allowed_origins) |origin| try validateBridgeOrigin(origin);
    for (security.navigation.external_links.allowed_urls) |url| try validateExternalUrlPattern(url);
}

pub fn validateUpdates(updates: UpdateConfig) ValidationError!void {
    if (updates.feed_url) |url| try validateExternalUrlPattern(url);
    if (updates.public_key) |key| if (key.len == 0) return error.MissingRequiredField;
}

fn validateExternalUrlPattern(url: []const u8) ValidationError!void {
    if (std.mem.eql(u8, url, "*")) return;
    if (std.mem.endsWith(u8, url, "*")) {
        const prefix = url[0 .. url.len - 1];
        if (prefix.len == 0) return error.InvalidUrl;
        if (std.mem.indexOfAny(u8, prefix, " \t\r\n\x00") != null) return error.InvalidUrl;
        if (std.mem.startsWith(u8, prefix, "http://") or std.mem.startsWith(u8, prefix, "https://")) return;
        return error.InvalidUrl;
    }
    return validateUrl(url);
}

fn validateRelativePath(path: []const u8) ValidationError!void {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidPath;
    if (path.len >= 3 and isAsciiAlpha(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) return error.InvalidPath;

    var segment_start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == 0) return error.InvalidPath;
        if (ch == '\\') return error.InvalidPath;
        if (ch == '/') {
            try validatePathSegment(path[segment_start..i]);
            segment_start = i + 1;
        }
    }
    try validatePathSegment(path[segment_start..]);
}

fn validatePathSegment(segment: []const u8) ValidationError!void {
    if (segment.len == 0) return error.InvalidPath;
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;
}

fn validateReadyPath(path: []const u8) ValidationError!void {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    for (path) |ch| {
        if (ch == 0 or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') return error.InvalidPath;
    }
}

fn validateShortcutKey(key: []const u8) ValidationError!void {
    if (key.len == 0 or key.len > max_shortcut_key_bytes) return error.InvalidShortcut;
    if (key.len == 1) {
        if (isPortableShortcutKey(key[0])) return;
        return error.InvalidShortcut;
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
        if (std.ascii.eqlIgnoreCase(key, special)) return;
    }
    return error.InvalidShortcut;
}

fn isPortableShortcutKey(ch: u8) bool {
    if (std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch)) return true;
    return switch (ch) {
        '=', '-', ',', '.', '/', ';', '\'', '[', ']', '\\', '`' => true,
        else => false,
    };
}

fn shortcutRequiresModifier(key: []const u8) bool {
    if (key.len == 1) return true;
    return std.ascii.eqlIgnoreCase(key, "space") or
        std.ascii.eqlIgnoreCase(key, "enter") or
        std.ascii.eqlIgnoreCase(key, "tab") or
        std.ascii.eqlIgnoreCase(key, "backspace");
}

pub fn validatePlatforms(platforms: []const PlatformSettings) ValidationError!void {
    for (platforms, 0..) |settings, i| {
        if (settings.platform == .unknown) return error.MissingRequiredField;
        if (settings.id_override) |id_override| try validateAppId(id_override, .reverse_dns);
        if (settings.min_os_version) |min_os_version| try validateVersionPart(min_os_version);
        try validatePermissions(settings.permissions);
        if (settings.category) |category| try validateName(category);
        for (platforms[0..i]) |previous| {
            if (previous.platform == settings.platform) return error.DuplicatePlatform;
        }
    }
}

pub fn validatePackageMetadata(metadata: PackageMetadata) ValidationError!void {
    if (metadata.license) |license| try validateName(license);
    if (metadata.repository) |repository| try validateUrl(repository);

    for (metadata.authors) |author| {
        if (author.len == 0) return error.MissingRequiredField;
        for (author) |ch| {
            if (ch == 0) return error.InvalidName;
        }
    }

    for (metadata.keywords) |keyword| {
        try validateKeyword(keyword);
    }
}

pub fn versionString(version: Version, output: []u8) ValidationError![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    writer.print("{d}.{d}.{d}", .{ version.major, version.minor, version.patch }) catch return error.NoSpaceLeft;
    if (version.pre) |pre| {
        try validateVersionPart(pre);
        writer.print("-{s}", .{pre}) catch return error.NoSpaceLeft;
    }
    if (version.build) |build| {
        try validateVersionPart(build);
        writer.print("+{s}", .{build}) catch return error.NoSpaceLeft;
    }
    return writer.buffered();
}

fn validateIdSegment(segment: []const u8, segment_len: usize) ValidationError!void {
    if (segment_len == 0) return error.InvalidId;
    if (segment[0] == '-' or segment[segment.len - 1] == '-') return error.InvalidId;
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidId;
}

fn validateVersionPart(part: []const u8) ValidationError!void {
    if (part.len == 0) return error.InvalidVersion;
    for (part) |ch| {
        if (!isLowerAlpha(ch) and !isUpperAlpha(ch) and !isDigit(ch) and ch != '-' and ch != '.') return error.InvalidVersion;
    }
}

fn validateKeyword(keyword: []const u8) ValidationError!void {
    if (keyword.len == 0) return error.InvalidKeyword;
    for (keyword) |ch| {
        if (!isLowerAlpha(ch) and !isDigit(ch) and ch != '-' and ch != '_') return error.InvalidKeyword;
    }
}

fn permissionEql(a: Permission, b: Permission) bool {
    if (a.kind() != b.kind()) return false;
    return switch (a) {
        .custom => |a_custom| std.mem.eql(u8, a_custom, b.custom),
        else => true,
    };
}

fn shortcutModifiersEql(a: ShortcutModifiers, b: ShortcutModifiers) bool {
    return a.primary == b.primary and
        a.command == b.command and
        a.control == b.control and
        a.option == b.option and
        a.shift == b.shift;
}

fn shortcutModifiersCollide(a: ShortcutModifiers, b: ShortcutModifiers, platforms: []const PlatformSettings) bool {
    if (shortcutModifiersEql(a, b)) return true;

    var check_macos = platforms.len == 0;
    var check_control_primary = platforms.len == 0;
    for (platforms) |settings| {
        switch (settings.platform) {
            .macos => check_macos = true,
            .windows, .linux => check_control_primary = true,
            .ios, .android, .web, .unknown => {},
        }
    }

    if (check_macos and shortcutModifiersEql(resolveShortcutModifiers(a, .command), resolveShortcutModifiers(b, .command))) return true;
    if (check_control_primary and shortcutModifiersEql(resolveShortcutModifiers(a, .control), resolveShortcutModifiers(b, .control))) return true;
    return false;
}

const PrimaryModifierTarget = enum {
    command,
    control,
};

fn resolveShortcutModifiers(modifiers: ShortcutModifiers, primary_target: PrimaryModifierTarget) ShortcutModifiers {
    var resolved = modifiers;
    switch (primary_target) {
        .command => resolved.command = resolved.command or resolved.primary,
        .control => resolved.control = resolved.control or resolved.primary,
    }
    resolved.primary = false;
    return resolved;
}

fn shortcutModifiersHasAny(modifiers: ShortcutModifiers) bool {
    return modifiers.primary or modifiers.command or modifiers.control or modifiers.option or modifiers.shift;
}

fn isLowerAlpha(ch: u8) bool {
    return ch >= 'a' and ch <= 'z';
}

fn isUpperAlpha(ch: u8) bool {
    return ch >= 'A' and ch <= 'Z';
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isAsciiAlpha(ch: u8) bool {
    return isLowerAlpha(ch) or isUpperAlpha(ch);
}

test "valid minimal manifest" {
    const manifest: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    };

    try validateManifest(manifest);
}

test "manifest validates shell windows and views" {
    const shell_views = [_]ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 44, .role = "toolbar" },
        .{ .label = "content", .kind = .webview, .url = "zero://app/index.html", .fill = true },
        .{ .label = "status", .kind = .statusbar, .edge = .bottom, .height = 24, .text = "Ready" },
        .{ .label = "save", .kind = .button, .parent = "toolbar", .accessibility_label = "Save document", .text = "Save", .command = "app.save" },
    };
    const shell_windows = [_]ShellWindow{.{
        .label = "main",
        .title = "Example",
        .width = 1100,
        .height = 760,
        .views = &shell_views,
    }};
    try validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &shell_windows },
    });

    const compatibility_windows = [_]Window{.{ .label = "main" }};
    try std.testing.expectError(error.DuplicateWindow, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .windows = &compatibility_windows,
        .shell = .{ .windows = &shell_windows },
    }));

    const duplicate_views = [_]ShellView{
        .{ .label = "content", .kind = .webview, .url = "zero://app/index.html" },
        .{ .label = "content", .kind = .label, .text = "Duplicate" },
    };
    const duplicate_window = [_]ShellWindow{.{ .views = &duplicate_views }};
    try std.testing.expectError(error.DuplicateView, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &duplicate_window },
    }));

    const missing_url_views = [_]ShellView{.{ .label = "content", .kind = .webview }};
    const missing_url_window = [_]ShellWindow{.{ .views = &missing_url_views }};
    try std.testing.expectError(error.MissingRequiredField, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &missing_url_window },
    }));

    const orphan_views = [_]ShellView{.{ .label = "save", .kind = .button, .parent = "missing", .command = "app.save" }};
    const orphan_window = [_]ShellWindow{.{ .views = &orphan_views }};
    try std.testing.expectError(error.InvalidLayout, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &orphan_window },
    }));

    const invalid_command_views = [_]ShellView{.{ .label = "save", .kind = .button, .command = "app\tsave" }};
    const invalid_command_window = [_]ShellWindow{.{ .views = &invalid_command_views }};
    try std.testing.expectError(error.InvalidCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &invalid_command_window },
    }));

    const cyclic_views = [_]ShellView{
        .{ .label = "first", .kind = .stack, .parent = "second" },
        .{ .label = "second", .kind = .stack, .parent = "first" },
    };
    const cyclic_window = [_]ShellWindow{.{ .views = &cyclic_views }};
    try std.testing.expectError(error.InvalidLayout, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &cyclic_window },
    }));

    const too_long_label = "012345678901234567890123456789012345678901234567890123456789abcde";
    try std.testing.expectEqual(@as(usize, max_view_label_bytes + 1), too_long_label.len);
    const too_long_label_views = [_]ShellView{.{ .label = too_long_label, .kind = .label, .text = "Too long" }};
    const too_long_label_window = [_]ShellWindow{.{ .views = &too_long_label_views }};
    try std.testing.expectError(error.InvalidName, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &too_long_label_window },
    }));

    const invalid_constraints_views = [_]ShellView{.{ .label = "content", .kind = .webview, .url = "zero://app/index.html", .min_width = 400, .max_width = 320 }};
    const invalid_constraints_window = [_]ShellWindow{.{ .views = &invalid_constraints_views }};
    try std.testing.expectError(error.InvalidDimension, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &invalid_constraints_window },
    }));
}

test "manifest validates keyboard shortcuts" {
    const manifest: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{
            .{ .id = "command.palette", .key = "p", .modifiers = .{ .primary = true, .shift = true } },
            .{ .id = "help", .key = "f", .modifiers = .{ .primary = true } },
        },
    };

    try validateManifest(manifest);

    const duplicate: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{
            .{ .id = "first", .key = "p", .modifiers = .{ .primary = true } },
            .{ .id = "second", .key = "P", .modifiers = .{ .primary = true } },
        },
    };
    try std.testing.expectError(error.DuplicateShortcut, validateManifest(duplicate));

    const windows_alias_duplicate: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .platforms = &.{.{ .platform = .windows }},
        .shortcuts = &.{
            .{ .id = "primary", .key = "p", .modifiers = .{ .primary = true } },
            .{ .id = "control", .key = "p", .modifiers = .{ .control = true } },
        },
    };
    try std.testing.expectError(error.DuplicateShortcut, validateManifest(windows_alias_duplicate));

    const macos_alias_duplicate: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .platforms = &.{.{ .platform = .macos }},
        .shortcuts = &.{
            .{ .id = "primary", .key = "p", .modifiers = .{ .primary = true } },
            .{ .id = "command", .key = "p", .modifiers = .{ .command = true } },
        },
    };
    try std.testing.expectError(error.DuplicateShortcut, validateManifest(macos_alias_duplicate));

    const macos_control_distinct: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .platforms = &.{.{ .platform = .macos }},
        .shortcuts = &.{
            .{ .id = "primary", .key = "p", .modifiers = .{ .primary = true } },
            .{ .id = "control", .key = "p", .modifiers = .{ .control = true } },
        },
    };
    try validateManifest(macos_control_distinct);

    const invalid_key: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{
            .{ .id = "invalid", .key = "@", .modifiers = .{ .primary = true } },
        },
    };
    try std.testing.expectError(error.InvalidShortcut, validateManifest(invalid_key));

    const unmodified_text_key: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{
            .{ .id = "text-entry", .key = "p" },
        },
    };
    try std.testing.expectError(error.InvalidShortcut, validateManifest(unmodified_text_key));

    const too_many = [_]Shortcut{.{ .id = "duplicate-ok-for-limit-check", .key = "p" }} ** (max_shortcuts + 1);
    const too_many_manifest: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &too_many,
    };
    try std.testing.expectError(error.InvalidShortcut, validateManifest(too_many_manifest));

    const long_id = [_]u8{'x'} ** (max_shortcut_id_bytes + 1);
    const long_id_manifest: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{.{ .id = long_id[0..], .key = "p" }},
    };
    try std.testing.expectError(error.InvalidShortcut, validateManifest(long_id_manifest));
}

test "manifest validates command metadata" {
    const commands = [_]Command{
        .{ .id = "app.refresh", .title = "Refresh" },
        .{ .id = "app.sidebar.toggle", .title = "Sidebar", .checked = true },
        .{ .id = "app.disabled", .enabled = false },
    };

    try validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &commands,
    });

    const duplicate_commands = [_]Command{
        .{ .id = "app.refresh" },
        .{ .id = "app.refresh" },
    };
    try std.testing.expectError(error.DuplicateCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &duplicate_commands,
    }));

    const invalid_id_commands = [_]Command{.{ .id = "bad/name" }};
    try std.testing.expectError(error.InvalidName, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &invalid_id_commands,
    }));

    const invalid_control_commands = [_]Command{.{ .id = "app\nrefresh" }};
    try std.testing.expectError(error.InvalidCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &invalid_control_commands,
    }));

    const long_title = [_]u8{'x'} ** (max_command_title_bytes + 1);
    const long_title_commands = [_]Command{.{ .id = "app.long-title", .title = long_title[0..] }};
    try std.testing.expectError(error.InvalidName, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &long_title_commands,
    }));
}

test "manifest validates native menus" {
    const view_items = [_]MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
        .{ .separator = true },
        .{ .label = "Sidebar", .command = "app.sidebar.toggle", .checked = true },
    };
    const menus = [_]Menu{.{ .title = "View", .items = &view_items }};

    try validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &menus,
    });

    const missing_command_items = [_]MenuItem{.{ .label = "Refresh" }};
    const missing_command_menus = [_]Menu{.{ .title = "View", .items = &missing_command_items }};
    try std.testing.expectError(error.InvalidCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &missing_command_menus,
    }));

    const invalid_command_items = [_]MenuItem{.{ .label = "Refresh", .command = "app\rrefresh" }};
    const invalid_command_menus = [_]Menu{.{ .title = "View", .items = &invalid_command_items }};
    try std.testing.expectError(error.InvalidCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &invalid_command_menus,
    }));

    const invalid_key_items = [_]MenuItem{.{ .label = "Refresh", .command = "app.refresh", .key = "r" }};
    const invalid_key_menus = [_]Menu{.{ .title = "View", .items = &invalid_key_items }};
    try std.testing.expectError(error.InvalidShortcut, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &invalid_key_menus,
    }));

    const too_many = [_]Menu{.{ .title = "View" }} ** (max_menus + 1);
    try std.testing.expectError(error.InvalidLayout, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &too_many,
    }));
}

test "manifest validates file associations and URL schemes" {
    const doc_extensions = [_][]const u8{ "md", ".markdown" };
    const doc_mime_types = [_][]const u8{ "text/markdown", "application/vnd.zero-native.note+json" };
    const file_associations = [_]FileAssociation{.{
        .name = "Markdown Document",
        .extensions = &doc_extensions,
        .mime_types = &doc_mime_types,
        .icon = "assets/markdown.icns",
    }};
    const url_schemes = [_]UrlScheme{.{ .scheme = "zero-native" }};

    try validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &file_associations,
        .url_schemes = &url_schemes,
    });

    const duplicate_associations = [_]FileAssociation{
        .{ .name = "Markdown", .extensions = &.{"md"} },
        .{ .name = "Other Markdown", .extensions = &.{"MD"} },
    };
    try std.testing.expectError(error.DuplicateFileAssociation, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &duplicate_associations,
    }));

    const missing_match = [_]FileAssociation{.{ .name = "Empty" }};
    try std.testing.expectError(error.MissingRequiredField, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &missing_match,
    }));

    const separator_mime_types = [_][]const u8{"text/plain;x-scheme-handler/zero"};
    const separator_mime_associations = [_]FileAssociation{.{ .name = "Bad MIME", .mime_types = &separator_mime_types }};
    try std.testing.expectError(error.InvalidPath, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &separator_mime_associations,
    }));

    const parameter_mime_types = [_][]const u8{"text/plain;charset=utf-8"};
    const parameter_mime_associations = [_]FileAssociation{.{ .name = "Bad MIME Parameter", .mime_types = &parameter_mime_types }};
    try std.testing.expectError(error.InvalidPath, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &parameter_mime_associations,
    }));

    const reserved_schemes = [_]UrlScheme{.{ .scheme = "https" }};
    try std.testing.expectError(error.InvalidUrl, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .url_schemes = &reserved_schemes,
    }));

    const duplicate_schemes = [_]UrlScheme{
        .{ .scheme = "acme" },
        .{ .scheme = "acme" },
    };
    try std.testing.expectError(error.DuplicateUrlScheme, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .url_schemes = &duplicate_schemes,
    }));
}

test "frontend validation accepts managed dev server config" {
    const command = [_][]const u8{ "npm", "run", "dev", "--", "--host", "127.0.0.1" };
    try validateFrontend(.{
        .dist = "dist",
        .entry = "index.html",
        .spa_fallback = true,
        .dev = .{
            .url = "http://127.0.0.1:5173/",
            .command = &command,
            .ready_path = "/",
            .timeout_ms = 30_000,
        },
    });
}

test "frontend validation rejects unsafe paths and incomplete dev config" {
    try std.testing.expectError(error.InvalidPath, validateFrontend(.{ .dist = "../dist" }));
    try std.testing.expectError(error.InvalidPath, validateFrontend(.{ .entry = "/index.html" }));
    try std.testing.expectError(error.MissingRequiredField, validateFrontend(.{ .dev = .{ .url = "http://127.0.0.1:5173/" } }));
    const command = [_][]const u8{"npm"};
    try std.testing.expectError(error.InvalidUrl, validateFrontend(.{ .dev = .{ .url = "ws://127.0.0.1:5173/", .command = &command } }));
    try std.testing.expectError(error.InvalidTimeout, validateFrontend(.{ .dev = .{ .url = "http://127.0.0.1:5173/", .command = &command, .timeout_ms = 0 } }));
}

test "valid rich manifest" {
    const icons = [_]Icon{
        .{ .asset = "icons/app-128", .size = 128, .scale = 1, .purpose = .any },
        .{ .asset = "icons/app-256", .size = 256, .scale = 1, .purpose = .maskable },
    };
    const permissions = [_]Permission{ .network, .clipboard, .window, .command, .view, .dialog, .credentials, .{ .custom = "com.example.custom" } };
    const bridge_permissions = [_]Permission{.clipboard};
    const bridge_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    const bridge_commands = [_]BridgeCommand{.{ .name = "native.ping", .permissions = &bridge_permissions, .origins = &bridge_origins }};
    const platform_permissions = [_]Permission{.notifications};
    const platforms = [_]PlatformSettings{
        .{
            .platform = .macos,
            .id_override = "com.example.app.macos",
            .min_os_version = "14.0",
            .permissions = &platform_permissions,
            .category = "productivity",
            .entitlements = "macos.entitlements",
        },
        .{ .platform = .linux },
    };
    const authors = [_][]const u8{"Example Team"};
    const keywords = [_][]const u8{ "native", "zig" };
    const manifest: Manifest = .{
        .identity = .{
            .id = "com.example.app",
            .name = "example",
            .display_name = "Example App",
            .organization = "Example",
            .homepage = "https://example.com/app",
        },
        .version = .{ .major = 1, .minor = 2, .patch = 3, .pre = "beta.1", .build = "20260506" },
        .icons = &icons,
        .permissions = &permissions,
        .bridge = .{ .commands = &bridge_commands },
        .security = .{
            .navigation = .{
                .allowed_origins = &.{ "zero://app", "http://127.0.0.1:5173" },
                .external_links = .{
                    .action = .open_system_browser,
                    .allowed_urls = &.{"https://example.com/*"},
                },
            },
        },
        .platforms = &platforms,
        .package = .{
            .kind = .app,
            .license = "Apache-2.0",
            .authors = &authors,
            .repository = "https://example.com/repo",
            .keywords = &keywords,
        },
    };

    try validateManifest(manifest);
}

test "app id validation" {
    try validateAppId("com.example.app", .reverse_dns);
    try validateAppId("my-tool", .simple);

    try std.testing.expectError(error.InvalidId, validateAppId("", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("example", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("Com.example.app", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("com/example/app", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("com..example", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId(".com.example", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("com.example.", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("com.example.app!", .reverse_dns));
}

test "name validation" {
    try validateName("Example App");
    try validateName("Apache-2.0");

    try std.testing.expectError(error.InvalidName, validateName(""));
    try std.testing.expectError(error.InvalidName, validateName("."));
    try std.testing.expectError(error.InvalidName, validateName(".."));
    try std.testing.expectError(error.InvalidName, validateName("bad/name"));
    try std.testing.expectError(error.InvalidName, validateName("bad\\name"));
    try std.testing.expectError(error.InvalidName, validateName("bad\x00name"));
}

test "version validation and formatting" {
    var buffer: [64]u8 = undefined;

    try validateVersion(.{ .major = 1, .minor = 2, .patch = 3 });
    try std.testing.expectEqualStrings("1.2.3", try versionString(.{ .major = 1, .minor = 2, .patch = 3 }, &buffer));
    try std.testing.expectEqualStrings("1.2.3-beta.1", try versionString(.{ .major = 1, .minor = 2, .patch = 3, .pre = "beta.1" }, &buffer));
    try std.testing.expectEqualStrings("1.2.3+20260506", try versionString(.{ .major = 1, .minor = 2, .patch = 3, .build = "20260506" }, &buffer));
    try std.testing.expectEqualStrings("1.2.3-beta.1+20260506", try versionString(.{ .major = 1, .minor = 2, .patch = 3, .pre = "beta.1", .build = "20260506" }, &buffer));
    try std.testing.expectError(error.InvalidVersion, validateVersion(.{ .major = 1, .minor = 2, .patch = 3, .pre = "" }));
    try std.testing.expectError(error.InvalidVersion, validateVersion(.{ .major = 1, .minor = 2, .patch = 3, .build = "bad!" }));
    try std.testing.expectError(error.NoSpaceLeft, versionString(.{ .major = 123, .minor = 456, .patch = 789 }, buffer[0..4]));
}

test "url validation" {
    try validateUrl("https://example.com");
    try validateUrl("http://example.com/path");

    try std.testing.expectError(error.InvalidUrl, validateUrl("ftp://example.com"));
    try std.testing.expectError(error.InvalidUrl, validateUrl("https://"));
    try std.testing.expectError(error.InvalidUrl, validateUrl("https:///path"));
    try std.testing.expectError(error.InvalidUrl, validateUrl("https://bad host"));
}

test "icon validation catches zero values and duplicates" {
    try validateIcons(&.{.{ .asset = "icons/app", .size = 128, .scale = 1, .purpose = .any }});

    try std.testing.expectError(error.MissingRequiredField, validateIcons(&.{.{ .asset = "", .size = 128 }}));
    try std.testing.expectError(error.InvalidVersion, validateIcons(&.{.{ .asset = "icons/app", .size = 0 }}));
    try std.testing.expectError(error.InvalidVersion, validateIcons(&.{.{ .asset = "icons/app", .size = 128, .scale = 0 }}));
    try std.testing.expectError(error.DuplicateIcon, validateIcons(&.{
        .{ .asset = "icons/a", .size = 128, .scale = 1, .purpose = .any },
        .{ .asset = "icons/b", .size = 128, .scale = 1, .purpose = .any },
    }));
}

test "permission validation catches duplicates" {
    try validatePermissions(&.{ .network, .clipboard, .command, .view, .dialog, .credentials, .{ .custom = "com.example.custom" } });
    try std.testing.expectError(error.DuplicatePermission, validatePermissions(&.{ .network, .network }));
    try std.testing.expectError(error.DuplicatePermission, validatePermissions(&.{ .{ .custom = "com.example.custom" }, .{ .custom = "com.example.custom" } }));
    try std.testing.expectError(error.InvalidName, validatePermissions(&.{.{ .custom = "bad/name" }}));
}

test "platform validation catches duplicates and invalid overrides" {
    try validatePlatforms(&.{ .{ .platform = .macos, .id_override = "com.example.app.macos" }, .{ .platform = .linux } });

    try std.testing.expectError(error.DuplicatePlatform, validatePlatforms(&.{ .{ .platform = .macos }, .{ .platform = .macos } }));
    try std.testing.expectError(error.MissingRequiredField, validatePlatforms(&.{.{ .platform = .unknown }}));
    try std.testing.expectError(error.InvalidId, validatePlatforms(&.{.{ .platform = .windows, .id_override = "Example.App" }}));
    try std.testing.expectError(error.InvalidVersion, validatePlatforms(&.{.{ .platform = .ios, .min_os_version = "bad!" }}));
}

test "capability validation catches duplicates and invalid custom names" {
    try validateCapabilities(&.{
        .native_module,
        .webview,
        .native_views,
        .menus,
        .shortcuts,
        .tray,
        .notifications,
        .dialog,
        .credentials,
        .open_url,
        .reveal_path,
        .recent_documents,
        .file_drops,
        .app_activation_events,
        .file_associations,
        .url_schemes,
        .{ .custom = "com.example.native-camera" },
    });
    try std.testing.expectError(error.DuplicateCapability, validateCapabilities(&.{ .webview, .webview }));
    try std.testing.expectError(error.DuplicateCapability, validateCapabilities(&.{ .{ .custom = "custom" }, .{ .custom = "custom" } }));
    try std.testing.expectError(error.InvalidName, validateCapabilities(&.{.{ .custom = "bad/name" }}));
}

test "bridge validation catches duplicate commands and invalid origins" {
    try validateBridge(.{ .commands = &.{.{ .name = "native.ping", .origins = &.{"zero://inline"} }} });
    try std.testing.expectError(error.DuplicateBridgeCommand, validateBridge(.{ .commands = &.{ .{ .name = "native.ping" }, .{ .name = "native.ping" } } }));
    try std.testing.expectError(error.InvalidUrl, validateBridge(.{ .commands = &.{.{ .name = "native.ping", .origins = &.{"bad origin"} }} }));
    try std.testing.expectError(error.InvalidName, validateBridge(.{ .commands = &.{.{ .name = "" }} }));
}

test "security validation catches invalid navigation and external policies" {
    try validateSecurity(.{ .navigation = .{
        .allowed_origins = &.{ "zero://app", "https://example.com" },
        .external_links = .{ .action = .open_system_browser, .allowed_urls = &.{"https://example.com/*"} },
    } });

    try std.testing.expectError(error.InvalidUrl, validateSecurity(.{ .navigation = .{ .allowed_origins = &.{"bad origin"} } }));
    try std.testing.expectError(error.InvalidUrl, validateSecurity(.{ .navigation = .{ .external_links = .{ .allowed_urls = &.{"ssh://example.com"} } } }));
}

test "package metadata validation catches empty authors and invalid keywords" {
    try validatePackageMetadata(.{
        .kind = .cli,
        .license = "Apache-2.0",
        .authors = &.{"Example"},
        .repository = "https://example.com/repo",
        .keywords = &.{ "zig", "native-apps" },
    });

    try std.testing.expectError(error.MissingRequiredField, validatePackageMetadata(.{ .authors = &.{""} }));
    try std.testing.expectError(error.InvalidKeyword, validatePackageMetadata(.{ .keywords = &.{""} }));
    try std.testing.expectError(error.InvalidKeyword, validatePackageMetadata(.{ .keywords = &.{"Bad"} }));
    try std.testing.expectError(error.InvalidUrl, validatePackageMetadata(.{ .repository = "ssh://example.com/repo" }));
}

test {
    std.testing.refAllDecls(@This());
}
