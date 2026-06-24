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
    DuplicatePlatform,
    DuplicateWindow,
    DuplicateShortcut,
    InvalidUrl,
    InvalidPath,
    InvalidCommand,
    InvalidShortcut,
    InvalidTimeout,
    InvalidKeyword,
    MissingRequiredField,
    NoSpaceLeft,
};

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
    custom: []const u8,

    pub fn kind(self: Permission) PermissionKind {
        return std.meta.activeTag(self);
    }
};

pub const CapabilityKind = enum {
    native_module,
    webview,
    js_bridge,
    filesystem,
    network,
    clipboard,
    custom,
};

pub const Capability = union(CapabilityKind) {
    native_module: void,
    webview: void,
    js_bridge: void,
    filesystem: void,
    network: void,
    clipboard: void,
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
    shortcuts: []const Shortcut = &.{},
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
    try validateShortcuts(manifest.shortcuts);
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

pub fn validateShortcuts(shortcuts: []const Shortcut) ValidationError!void {
    for (shortcuts, 0..) |shortcut, i| {
        try validateName(shortcut.id);
        try validateShortcutKey(shortcut.key);
        for (shortcuts[0..i]) |previous| {
            if (std.mem.eql(u8, previous.id, shortcut.id)) return error.DuplicateShortcut;
            if (std.ascii.eqlIgnoreCase(previous.key, shortcut.key) and shortcutModifiersEql(previous.modifiers, shortcut.modifiers)) return error.DuplicateShortcut;
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
    if (key.len == 0 or key.len > 32) return error.InvalidShortcut;
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

    const invalid_key: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{
            .{ .id = "invalid", .key = "@", .modifiers = .{ .primary = true } },
        },
    };
    try std.testing.expectError(error.InvalidShortcut, validateManifest(invalid_key));
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
    const permissions = [_]Permission{ .network, .clipboard, .window, .{ .custom = "com.example.custom" } };
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
    try validatePermissions(&.{ .network, .clipboard, .{ .custom = "com.example.custom" } });
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
    try validateCapabilities(&.{ .native_module, .webview, .{ .custom = "com.example.native-camera" } });
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
