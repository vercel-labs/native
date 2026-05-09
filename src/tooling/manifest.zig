const std = @import("std");
const app_manifest = @import("app_manifest");
const diagnostics = @import("diagnostics");
const raw_manifest = @import("raw_manifest.zig");
const web_engine_tool = @import("web_engine.zig");

pub const ValidationResult = struct {
    ok: bool,
    message: []const u8,
};

pub const Metadata = struct {
    id: []const u8,
    name: []const u8,
    display_name: ?[]const u8 = null,
    version: []const u8,
    icons: []const []const u8 = &.{},
    platforms: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},
    capabilities: []const []const u8 = &.{},
    bridge_commands: []const BridgeCommandMetadata = &.{},
    web_engine: []const u8 = "system",
    cef: web_engine_tool.CefConfig = .{},
    frontend: ?FrontendMetadata = null,
    security: SecurityMetadata = .{},
    windows: []const WindowMetadata = &.{},

    pub fn displayName(self: Metadata) []const u8 {
        return self.display_name orelse self.name;
    }

    pub fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.display_name) |value| allocator.free(value);
        allocator.free(self.version);
        allocator.free(self.web_engine);
        allocator.free(self.cef.dir);
        for (self.icons) |value| allocator.free(value);
        if (self.icons.len > 0) allocator.free(self.icons);
        for (self.platforms) |value| allocator.free(value);
        if (self.platforms.len > 0) allocator.free(self.platforms);
        for (self.permissions) |value| allocator.free(value);
        if (self.permissions.len > 0) allocator.free(self.permissions);
        for (self.capabilities) |value| allocator.free(value);
        if (self.capabilities.len > 0) allocator.free(self.capabilities);
        for (self.bridge_commands) |command| {
            allocator.free(command.name);
            for (command.permissions) |value| allocator.free(value);
            if (command.permissions.len > 0) allocator.free(command.permissions);
            for (command.origins) |value| allocator.free(value);
            if (command.origins.len > 0) allocator.free(command.origins);
        }
        if (self.bridge_commands.len > 0) allocator.free(self.bridge_commands);
        if (self.frontend) |frontend| {
            allocator.free(frontend.dist);
            allocator.free(frontend.entry);
            if (frontend.dev) |dev| {
                allocator.free(dev.url);
                for (dev.command) |value| allocator.free(value);
                if (dev.command.len > 0) allocator.free(dev.command);
                allocator.free(dev.ready_path);
            }
        }
        for (self.security.navigation.allowed_origins) |value| allocator.free(value);
        if (self.security.navigation.allowed_origins.len > 0) allocator.free(self.security.navigation.allowed_origins);
        if (!std.mem.eql(u8, self.security.navigation.external_links.action, "deny") or self.security.navigation.external_links.allowed_urls.len > 0) {
            allocator.free(self.security.navigation.external_links.action);
        }
        for (self.security.navigation.external_links.allowed_urls) |value| allocator.free(value);
        if (self.security.navigation.external_links.allowed_urls.len > 0) allocator.free(self.security.navigation.external_links.allowed_urls);
        for (self.windows) |window| {
            allocator.free(window.label);
            if (window.title) |title| allocator.free(title);
        }
        if (self.windows.len > 0) allocator.free(self.windows);
    }
};

pub const BridgeCommandMetadata = struct {
    name: []const u8,
    permissions: []const []const u8 = &.{},
    origins: []const []const u8 = &.{},
};

pub const WindowMetadata = struct {
    label: []const u8 = "main",
    title: ?[]const u8 = null,
    width: f32 = 720,
    height: f32 = 480,
    x: ?f32 = null,
    y: ?f32 = null,
    restore_state: bool = true,
    frameless: bool = false,
    transparent: bool = false,
    always_on_top: bool = false,
};

pub const FrontendDevMetadata = struct {
    url: []const u8,
    command: []const []const u8 = &.{},
    ready_path: []const u8 = "/",
    timeout_ms: u32 = 30_000,
};

pub const FrontendMetadata = struct {
    dist: []const u8 = "dist",
    entry: []const u8 = "index.html",
    spa_fallback: bool = true,
    dev: ?FrontendDevMetadata = null,
};

pub const ExternalLinkMetadata = struct {
    action: []const u8 = "deny",
    allowed_urls: []const []const u8 = &.{},
};

pub const NavigationMetadata = struct {
    allowed_origins: []const []const u8 = &.{},
    external_links: ExternalLinkMetadata = .{},
};

pub const SecurityMetadata = struct {
    navigation: NavigationMetadata = .{},
};

const RawManifest = raw_manifest.RawManifest;
const RawBridge = raw_manifest.RawBridge;
const RawBridgeCommand = raw_manifest.RawBridgeCommand;
const RawFrontend = raw_manifest.RawFrontend;
const RawFrontendDev = raw_manifest.RawFrontendDev;
const RawSecurity = raw_manifest.RawSecurity;
const RawNavigation = raw_manifest.RawNavigation;
const RawExternalLinks = raw_manifest.RawExternalLinks;
const RawWindow = raw_manifest.RawWindow;

pub fn validateFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ValidationResult {
    const source = try readFile(allocator, io, path);
    defer allocator.free(source);

    const metadata = parseText(allocator, source) catch return .{ .ok = false, .message = "app.zon metadata could not be parsed" };
    defer metadata.deinit(allocator);

    validateIconPaths(metadata.icons) catch return .{ .ok = false, .message = "app.zon icons are invalid" };
    const permissions = parsePermissions(allocator, metadata.permissions) catch return .{ .ok = false, .message = "app.zon permissions are invalid" };
    defer allocator.free(permissions);
    const capabilities = parseCapabilities(allocator, metadata.capabilities) catch return .{ .ok = false, .message = "app.zon capabilities are invalid" };
    defer allocator.free(capabilities);
    const bridge_commands = parseBridgeCommands(allocator, metadata.bridge_commands) catch return .{ .ok = false, .message = "app.zon bridge commands are invalid" };
    defer {
        for (bridge_commands) |command| allocator.free(command.permissions);
        allocator.free(bridge_commands);
    }
    const frontend = if (metadata.frontend) |frontend_value| convertFrontend(frontend_value) else null;
    const security = convertSecurity(metadata.security) catch return .{ .ok = false, .message = "app.zon security policy is invalid" };
    const windows = try convertWindows(allocator, metadata.windows);
    defer allocator.free(windows);
    const manifest_web_engine = parseWebEngine(metadata.web_engine) catch return .{ .ok = false, .message = "app.zon web engine is invalid" };

    const manifest: app_manifest.Manifest = .{
        .identity = .{ .id = metadata.id, .name = metadata.name, .display_name = metadata.display_name },
        .version = parseVersion(metadata.version) catch return .{ .ok = false, .message = "app.zon version is invalid" },
        .permissions = permissions,
        .capabilities = capabilities,
        .bridge = .{ .commands = bridge_commands },
        .frontend = frontend,
        .security = security,
        .platforms = parsePlatformSettings(allocator, metadata.platforms) catch return .{ .ok = false, .message = "app.zon platforms are invalid" },
        .windows = windows,
        .cef = .{ .dir = metadata.cef.dir, .auto_install = metadata.cef.auto_install },
        .package = .{ .web_engine = manifest_web_engine },
    };
    app_manifest.validateManifest(manifest) catch return .{ .ok = false, .message = "manifest fields failed semantic validation" };
    return .{ .ok = true, .message = "app.zon is valid" };
}

pub fn readMetadata(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Metadata {
    const source = try readFile(allocator, io, path);
    defer allocator.free(source);
    return parseText(allocator, source);
}

pub fn parseText(allocator: std.mem.Allocator, source: []const u8) !Metadata {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const source_z = try scratch.dupeZ(u8, source);
    const raw = try std.zon.parse.fromSliceAlloc(RawManifest, scratch, source_z, null, .{});
    return .{
        .id = try allocator.dupe(u8, raw.id),
        .name = try allocator.dupe(u8, raw.name),
        .display_name = if (raw.display_name) |value| try allocator.dupe(u8, value) else null,
        .version = try allocator.dupe(u8, raw.version),
        .icons = try duplicateStringList(allocator, raw.icons),
        .platforms = try duplicateStringList(allocator, raw.platforms),
        .permissions = try duplicateStringList(allocator, raw.permissions),
        .capabilities = try duplicateStringList(allocator, raw.capabilities),
        .bridge_commands = try convertRawBridgeCommands(allocator, raw.bridge.commands),
        .web_engine = try allocator.dupe(u8, raw.web_engine),
        .cef = .{
            .dir = try allocator.dupe(u8, raw.cef.dir),
            .auto_install = raw.cef.auto_install,
        },
        .frontend = try convertRawFrontend(allocator, raw.frontend),
        .security = try convertRawSecurity(allocator, raw.security),
        .windows = try convertRawWindows(allocator, raw.windows),
    };
}

fn duplicateStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
    }
    return out;
}

fn convertRawBridgeCommands(allocator: std.mem.Allocator, commands: []const RawBridgeCommand) ![]const BridgeCommandMetadata {
    if (commands.len == 0) return &.{};
    const converted = try allocator.alloc(BridgeCommandMetadata, commands.len);
    for (commands, 0..) |command, index| {
        converted[index] = .{
            .name = try allocator.dupe(u8, command.name),
            .permissions = try duplicateStringList(allocator, command.permissions),
            .origins = try duplicateStringList(allocator, command.origins),
        };
    }
    return converted;
}

fn convertRawFrontend(allocator: std.mem.Allocator, frontend: ?RawFrontend) !?FrontendMetadata {
    const value = frontend orelse return null;
    return .{
        .dist = try allocator.dupe(u8, value.dist),
        .entry = try allocator.dupe(u8, value.entry),
        .spa_fallback = value.spa_fallback,
        .dev = if (value.dev) |dev| .{
            .url = try allocator.dupe(u8, dev.url),
            .command = try duplicateStringList(allocator, dev.command),
            .ready_path = try allocator.dupe(u8, dev.ready_path),
            .timeout_ms = dev.timeout_ms,
        } else null,
    };
}

fn convertRawSecurity(allocator: std.mem.Allocator, security: RawSecurity) !SecurityMetadata {
    const external_action = if (security.navigation.external_links.allowed_urls.len == 0 and
        std.mem.eql(u8, security.navigation.external_links.action, "deny"))
        "deny"
    else
        try allocator.dupe(u8, security.navigation.external_links.action);
    return .{
        .navigation = .{
            .allowed_origins = try duplicateStringList(allocator, security.navigation.allowed_origins),
            .external_links = .{
                .action = external_action,
                .allowed_urls = try duplicateStringList(allocator, security.navigation.external_links.allowed_urls),
            },
        },
    };
}

fn convertRawWindows(allocator: std.mem.Allocator, windows: []const RawWindow) ![]const WindowMetadata {
    if (windows.len == 0) return &.{};
    const converted = try allocator.alloc(WindowMetadata, windows.len);
    for (windows, 0..) |window, index| {
        converted[index] = .{
            .label = try allocator.dupe(u8, window.label),
            .title = if (window.title) |title| try allocator.dupe(u8, title) else null,
            .width = window.width,
            .height = window.height,
            .x = window.x,
            .y = window.y,
            .restore_state = window.restore_state,
            .frameless = window.frameless,
            .transparent = window.transparent,
            .always_on_top = window.always_on_top,
        };
    }
    return converted;
}

pub fn parseVersion(value: []const u8) !app_manifest.Version {
    var parts = std.mem.splitScalar(u8, value, '.');
    const major = try parseVersionNumber(parts.next() orelse return error.InvalidVersion);
    const minor = try parseVersionNumber(parts.next() orelse return error.InvalidVersion);
    const patch_text = parts.next() orelse return error.InvalidVersion;
    if (parts.next() != null) return error.InvalidVersion;
    return .{
        .major = major,
        .minor = minor,
        .patch = try parseVersionNumber(patch_text),
    };
}

pub fn printDiagnostic(result: ValidationResult) void {
    const severity: diagnostics.Severity = if (result.ok) .info else .@"error";
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    diagnostics.formatShort(.{ .severity = severity, .code = diagnostics.code("manifest", if (result.ok) "valid" else "invalid"), .message = result.message }, &writer) catch return;
    std.debug.print("{s}\n", .{writer.buffered()});
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn convertFrontend(frontend: FrontendMetadata) app_manifest.FrontendConfig {
    return .{
        .dist = frontend.dist,
        .entry = frontend.entry,
        .spa_fallback = frontend.spa_fallback,
        .dev = if (frontend.dev) |dev| .{
            .url = dev.url,
            .command = dev.command,
            .ready_path = dev.ready_path,
            .timeout_ms = dev.timeout_ms,
        } else null,
    };
}

fn convertSecurity(security: SecurityMetadata) !app_manifest.SecurityConfig {
    return .{
        .navigation = .{
            .allowed_origins = if (security.navigation.allowed_origins.len > 0) security.navigation.allowed_origins else &.{ "zero://app", "zero://inline" },
            .external_links = .{
                .action = parseExternalLinkAction(security.navigation.external_links.action) catch return error.InvalidSecurity,
                .allowed_urls = security.navigation.external_links.allowed_urls,
            },
        },
    };
}

fn convertWindows(allocator: std.mem.Allocator, windows: []const WindowMetadata) ![]const app_manifest.Window {
    if (windows.len == 0) return &.{};
    const converted = try allocator.alloc(app_manifest.Window, windows.len);
    for (windows, 0..) |window, index| {
        converted[index] = .{
            .label = window.label,
            .title = window.title,
            .width = window.width,
            .height = window.height,
            .x = window.x,
            .y = window.y,
            .restore_state = window.restore_state,
            .frameless = window.frameless,
            .transparent = window.transparent,
            .always_on_top = window.always_on_top,
        };
    }
    return converted;
}

fn validateIconPaths(icons: []const []const u8) !void {
    for (icons, 0..) |icon, index| {
        try validateRelativePath(icon);
        for (icons[0..index]) |previous| {
            if (std.mem.eql(u8, previous, icon)) return error.DuplicateIcon;
        }
    }
}

fn parseCapabilities(allocator: std.mem.Allocator, values: []const []const u8) ![]const app_manifest.Capability {
    var capabilities: std.ArrayList(app_manifest.Capability) = .empty;
    errdefer capabilities.deinit(allocator);
    for (values) |value| {
        try capabilities.append(allocator, parseCapability(value) catch return error.InvalidCapability);
    }
    return capabilities.toOwnedSlice(allocator);
}

fn parsePermissions(allocator: std.mem.Allocator, values: []const []const u8) ![]const app_manifest.Permission {
    var permissions: std.ArrayList(app_manifest.Permission) = .empty;
    errdefer permissions.deinit(allocator);
    for (values) |value| {
        try permissions.append(allocator, parsePermission(value));
    }
    return permissions.toOwnedSlice(allocator);
}

fn parsePermission(value: []const u8) app_manifest.Permission {
    if (std.mem.eql(u8, value, "network")) return .network;
    if (std.mem.eql(u8, value, "filesystem")) return .filesystem;
    if (std.mem.eql(u8, value, "camera")) return .camera;
    if (std.mem.eql(u8, value, "microphone")) return .microphone;
    if (std.mem.eql(u8, value, "location")) return .location;
    if (std.mem.eql(u8, value, "notifications")) return .notifications;
    if (std.mem.eql(u8, value, "clipboard")) return .clipboard;
    if (std.mem.eql(u8, value, "window")) return .window;
    return .{ .custom = value };
}

fn parseCapability(value: []const u8) !app_manifest.Capability {
    if (std.mem.eql(u8, value, "native_module")) return .native_module;
    if (std.mem.eql(u8, value, "webview")) return .webview;
    if (std.mem.eql(u8, value, "js_bridge")) return .js_bridge;
    if (std.mem.eql(u8, value, "filesystem")) return .filesystem;
    if (std.mem.eql(u8, value, "network")) return .network;
    if (std.mem.eql(u8, value, "clipboard")) return .clipboard;
    return error.InvalidCapability;
}

fn parseBridgeCommands(allocator: std.mem.Allocator, values: []const BridgeCommandMetadata) ![]const app_manifest.BridgeCommand {
    var commands: std.ArrayList(app_manifest.BridgeCommand) = .empty;
    errdefer commands.deinit(allocator);
    for (values) |value| {
        try commands.append(allocator, .{
            .name = value.name,
            .permissions = try parsePermissions(allocator, value.permissions),
            .origins = value.origins,
        });
    }
    return commands.toOwnedSlice(allocator);
}

fn parsePlatformSettings(allocator: std.mem.Allocator, values: []const []const u8) ![]const app_manifest.PlatformSettings {
    if (values.len == 0) return &.{};
    var platforms: std.ArrayList(app_manifest.PlatformSettings) = .empty;
    errdefer platforms.deinit(allocator);
    for (values) |value| {
        try platforms.append(allocator, .{ .platform = parsePlatform(value) });
    }
    return platforms.toOwnedSlice(allocator);
}

fn parsePlatform(value: []const u8) app_manifest.Platform {
    if (std.mem.eql(u8, value, "macos")) return .macos;
    if (std.mem.eql(u8, value, "windows")) return .windows;
    if (std.mem.eql(u8, value, "linux")) return .linux;
    if (std.mem.eql(u8, value, "ios")) return .ios;
    if (std.mem.eql(u8, value, "android")) return .android;
    if (std.mem.eql(u8, value, "web")) return .web;
    return .unknown;
}

fn parseExternalLinkAction(value: []const u8) !app_manifest.ExternalLinkAction {
    if (std.mem.eql(u8, value, "deny")) return .deny;
    if (std.mem.eql(u8, value, "open_system_browser")) return .open_system_browser;
    return error.InvalidAction;
}

fn parseWebEngine(value: []const u8) !app_manifest.WebEngine {
    if (std.mem.eql(u8, value, "system")) return .system;
    if (std.mem.eql(u8, value, "chromium")) return .chromium;
    return error.InvalidWebEngine;
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidPath;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) return error.InvalidPath;
    var segment_start: usize = 0;
    for (path, 0..) |ch, index| {
        if (ch == 0 or ch == '\\') return error.InvalidPath;
        if (ch == '/') {
            try validatePathSegment(path[segment_start..index]);
            segment_start = index + 1;
        }
    }
    try validatePathSegment(path[segment_start..]);
}

fn validatePathSegment(segment: []const u8) !void {
    if (segment.len == 0) return error.InvalidPath;
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;
}

fn parseVersionNumber(value: []const u8) !u32 {
    if (value.len == 0) return error.InvalidVersion;
    return std.fmt.parseUnsigned(u32, value, 10);
}

test "manifest metadata parser reads identity version and lists" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .display_name = "Example App",
        \\  .version = "1.2.3",
        \\  .icons = .{ "assets/icon.png" },
        \\  .platforms = .{ "macos", "linux" },
        \\  .capabilities = .{ "native_module", "webview", "js_bridge" },
        \\  .bridge = .{ .commands = .{ .{ .name = "native.ping" } } },
        \\  .web_engine = "chromium",
        \\  .cef = .{ .dir = "third_party/cef/macos", .auto_install = true },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("com.example.app", metadata.id);
    try std.testing.expectEqualStrings("example", metadata.name);
    try std.testing.expectEqualStrings("Example App", metadata.displayName());
    try std.testing.expectEqualStrings("1.2.3", metadata.version);
    try std.testing.expectEqualStrings("assets/icon.png", metadata.icons[0]);
    try std.testing.expectEqualStrings("linux", metadata.platforms[1]);
    try std.testing.expectEqualStrings("webview", metadata.capabilities[1]);
    try std.testing.expectEqualStrings("native.ping", metadata.bridge_commands[0].name);
    try std.testing.expectEqualStrings("chromium", metadata.web_engine);
    try std.testing.expectEqualStrings("third_party/cef/macos", metadata.cef.dir);
    try std.testing.expect(metadata.cef.auto_install);
    try std.testing.expectEqual(@as(u32, 2), (try parseVersion(metadata.version)).minor);
}

test "manifest metadata parser reads structured security policy" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .permissions = .{ "window", "filesystem" },
        \\  .bridge = .{
        \\    .commands = .{
        \\      .{ .name = "native.ping", .permissions = .{ "filesystem" }, .origins = .{ "zero://app" } },
        \\    },
        \\  },
        \\  .security = .{
        \\    .navigation = .{
        \\      .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
        \\      .external_links = .{
        \\        .action = "open_system_browser",
        \\        .allowed_urls = .{ "https://example.com/*" },
        \\      },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("window", metadata.permissions[0]);
    try std.testing.expectEqualStrings("native.ping", metadata.bridge_commands[0].name);
    try std.testing.expectEqualStrings("filesystem", metadata.bridge_commands[0].permissions[0]);
    try std.testing.expectEqualStrings("zero://app", metadata.bridge_commands[0].origins[0]);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173", metadata.security.navigation.allowed_origins[1]);
    try std.testing.expectEqualStrings("open_system_browser", metadata.security.navigation.external_links.action);
    try std.testing.expectEqualStrings("https://example.com/*", metadata.security.navigation.external_links.allowed_urls[0]);
}

test "manifest metadata parser reads frontend config" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .frontend = .{
        \\    .dist = "frontend/dist",
        \\    .entry = "index.html",
        \\    .spa_fallback = false,
        \\    .dev = .{
        \\      .url = "http://127.0.0.1:5173/",
        \\      .command = .{ "npm", "run", "dev" },
        \\      .ready_path = "/health",
        \\      .timeout_ms = 12000,
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("frontend/dist", metadata.frontend.?.dist);
    try std.testing.expectEqual(false, metadata.frontend.?.spa_fallback);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173/", metadata.frontend.?.dev.?.url);
    try std.testing.expectEqualStrings("npm", metadata.frontend.?.dev.?.command[0]);
    try std.testing.expectEqual(@as(u32, 12000), metadata.frontend.?.dev.?.timeout_ms);
}

test "manifest parser reads frameless transparent always_on_top window flags" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "0.1.0",
        \\  .windows = .{
        \\    .{
        \\      .label = "overlay",
        \\      .width = 160,
        \\      .height = 160,
        \\      .frameless = true,
        \\      .transparent = true,
        \\      .always_on_top = true,
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), metadata.windows.len);
    const window = metadata.windows[0];
    try std.testing.expectEqualStrings("overlay", window.label);
    try std.testing.expect(window.frameless);
    try std.testing.expect(window.transparent);
    try std.testing.expect(window.always_on_top);
}

test "manifest parser defaults floating window flags to false" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "0.1.0",
        \\  .windows = .{ .{ .label = "main" } },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    const window = metadata.windows[0];
    try std.testing.expect(!window.frameless);
    try std.testing.expect(!window.transparent);
    try std.testing.expect(!window.always_on_top);
}
