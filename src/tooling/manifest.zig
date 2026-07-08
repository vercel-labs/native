const std = @import("std");
const app_icon_tool = @import("app_icon");
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
    /// One human-facing sentence about the app: the About panel credits
    /// line on macOS. Optional — absent means no credits line.
    description: ?[]const u8 = null,
    version: []const u8,
    icons: []const []const u8 = &.{},
    platforms: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},
    capabilities: []const []const u8 = &.{},
    bridge_commands: []const BridgeCommandMetadata = &.{},
    web_engine: []const u8 = "system",
    /// The built-in theme pack the app selects (`theme = "geist"`).
    /// Optional — absent keeps the house register. Validated against
    /// the known pack names so a typo is a check error, never a silent
    /// default-theme fallback.
    theme: ?[]const u8 = null,
    cef: web_engine_tool.CefConfig = .{},
    frontend: ?FrontendMetadata = null,
    security: SecurityMetadata = .{},
    windows: []const WindowMetadata = &.{},
    shell: ShellMetadata = .{},
    commands: []const CommandMetadata = &.{},
    menus: []const MenuMetadata = &.{},
    shortcuts: []const ShortcutMetadata = &.{},
    file_associations: []const FileAssociationMetadata = &.{},
    url_schemes: []const UrlSchemeMetadata = &.{},

    pub fn displayName(self: Metadata) []const u8 {
        return self.display_name orelse self.name;
    }

    pub fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.display_name) |value| allocator.free(value);
        if (self.description) |value| allocator.free(value);
        if (self.theme) |value| allocator.free(value);
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
            allocator.free(window.titlebar);
        }
        if (self.windows.len > 0) allocator.free(self.windows);
        for (self.shell.windows) |window| {
            allocator.free(window.label);
            if (window.title) |title| allocator.free(title);
            allocator.free(window.restore_policy);
            allocator.free(window.titlebar);
            for (window.views) |view| {
                allocator.free(view.label);
                allocator.free(view.kind);
                if (view.parent) |parent| allocator.free(parent);
                if (view.edge) |edge| allocator.free(edge);
                if (view.axis) |axis| allocator.free(axis);
                if (view.role) |role| allocator.free(role);
                if (view.accessibility_label) |accessibility_label| allocator.free(accessibility_label);
                if (view.url) |url| allocator.free(url);
                if (view.text) |text| allocator.free(text);
                if (view.command) |command| allocator.free(command);
                if (view.gpu_backend) |gpu_backend| allocator.free(gpu_backend);
                if (view.gpu_pixel_format) |gpu_pixel_format| allocator.free(gpu_pixel_format);
                if (view.gpu_present_mode) |gpu_present_mode| allocator.free(gpu_present_mode);
                if (view.gpu_alpha_mode) |gpu_alpha_mode| allocator.free(gpu_alpha_mode);
                if (view.gpu_color_space) |gpu_color_space| allocator.free(gpu_color_space);
            }
            if (window.views.len > 0) allocator.free(window.views);
        }
        if (self.shell.windows.len > 0) allocator.free(self.shell.windows);
        for (self.shell.chrome.tabs) |tab| {
            allocator.free(tab.id);
            allocator.free(tab.label);
            allocator.free(tab.icon);
        }
        if (self.shell.chrome.tabs.len > 0) allocator.free(self.shell.chrome.tabs);
        if (self.shell.chrome.primary_action) |action| {
            allocator.free(action.id);
            allocator.free(action.label);
            allocator.free(action.icon);
        }
        for (self.commands) |command| {
            allocator.free(command.id);
            allocator.free(command.title);
        }
        if (self.commands.len > 0) allocator.free(self.commands);
        for (self.menus) |menu| {
            allocator.free(menu.title);
            for (menu.items) |item| {
                allocator.free(item.label);
                allocator.free(item.command);
                allocator.free(item.key);
                for (item.modifiers) |value| allocator.free(value);
                if (item.modifiers.len > 0) allocator.free(item.modifiers);
            }
            if (menu.items.len > 0) allocator.free(menu.items);
        }
        if (self.menus.len > 0) allocator.free(self.menus);
        for (self.shortcuts) |shortcut| {
            allocator.free(shortcut.id);
            allocator.free(shortcut.key);
            for (shortcut.modifiers) |value| allocator.free(value);
            if (shortcut.modifiers.len > 0) allocator.free(shortcut.modifiers);
        }
        if (self.shortcuts.len > 0) allocator.free(self.shortcuts);
        for (self.file_associations) |association| {
            allocator.free(association.name);
            allocator.free(association.role);
            for (association.extensions) |value| allocator.free(value);
            if (association.extensions.len > 0) allocator.free(association.extensions);
            for (association.mime_types) |value| allocator.free(value);
            if (association.mime_types.len > 0) allocator.free(association.mime_types);
            if (association.icon) |icon| allocator.free(icon);
        }
        if (self.file_associations.len > 0) allocator.free(self.file_associations);
        for (self.url_schemes) |scheme| {
            allocator.free(scheme.scheme);
            allocator.free(scheme.role);
        }
        if (self.url_schemes.len > 0) allocator.free(self.url_schemes);
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
    resizable: bool = true,
    restore_state: bool = true,
    titlebar: []const u8 = "standard",
    min_width: f32 = 0,
    min_height: f32 = 0,
};

pub const ShellMetadata = struct {
    windows: []const ShellWindowMetadata = &.{},
    chrome: ShellChromeMetadata = .{},
};

pub const ShellChromeMetadata = struct {
    tabs: []const ShellTabMetadata = &.{},
    primary_action: ?ShellPrimaryActionMetadata = null,
};

pub const ShellTabMetadata = struct {
    id: []const u8,
    label: []const u8,
    icon: []const u8 = "",
};

pub const ShellPrimaryActionMetadata = struct {
    id: []const u8,
    label: []const u8,
    icon: []const u8 = "",
};

pub const ShellWindowMetadata = struct {
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
    min_width: f32 = 0,
    min_height: f32 = 0,
    views: []const ShellViewMetadata = &.{},
};

pub const ShellViewMetadata = struct {
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

pub const ShortcutMetadata = struct {
    id: []const u8,
    key: []const u8,
    modifiers: []const []const u8 = &.{},
};

pub const CommandMetadata = struct {
    id: []const u8,
    title: []const u8 = "",
    enabled: bool = true,
    checked: bool = false,
};

pub const MenuMetadata = struct {
    title: []const u8,
    items: []const MenuItemMetadata = &.{},
};

pub const MenuItemMetadata = struct {
    label: []const u8 = "",
    command: []const u8 = "",
    key: []const u8 = "",
    modifiers: []const []const u8 = &.{},
    separator: bool = false,
    enabled: bool = true,
    checked: bool = false,
};

pub const FileAssociationMetadata = struct {
    name: []const u8,
    role: []const u8 = "viewer",
    extensions: []const []const u8 = &.{},
    mime_types: []const []const u8 = &.{},
    icon: ?[]const u8 = null,
};

pub const UrlSchemeMetadata = struct {
    scheme: []const u8,
    role: []const u8 = "viewer",
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
const RawShell = raw_manifest.RawShell;
const RawShellWindow = raw_manifest.RawShellWindow;
const RawShellView = raw_manifest.RawShellView;
const RawCommand = raw_manifest.RawCommand;
const RawMenu = raw_manifest.RawMenu;
const RawMenuItem = raw_manifest.RawMenuItem;
const RawShortcut = raw_manifest.RawShortcut;
const RawFileAssociation = raw_manifest.RawFileAssociation;
const RawUrlScheme = raw_manifest.RawUrlScheme;

pub fn validateFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ValidationResult {
    const source = try readFile(allocator, io, path);
    defer allocator.free(source);

    const metadata = parseText(allocator, source) catch return .{
        .ok = false,
        .message = zonParseFailureMessage(allocator, source) orelse "app.zon metadata could not be parsed",
    };
    defer metadata.deinit(allocator);

    if (metadata.description) |description| {
        app_manifest.validateDescription(description) catch return .{
            .ok = false,
            .message = "app.zon description is invalid - it must be one non-empty line of at most 256 bytes with no control characters (it becomes the About panel credits line)",
        };
    }
    if (metadata.theme) |theme_name| {
        if (!isKnownThemePack(theme_name)) return .{
            .ok = false,
            .message = "app.zon theme is invalid - expected one of: house, geist",
        };
    }
    validateIconPaths(metadata.icons) catch return .{ .ok = false, .message = "app.zon icons are invalid" };
    if (try checkIconSources(allocator, io, std.fs.path.dirname(path) orelse ".", metadata.icons)) |icon_message| {
        return .{ .ok = false, .message = icon_message };
    }
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
    const windows = convertWindows(allocator, metadata.windows) catch return .{ .ok = false, .message = "app.zon windows are invalid" };
    defer allocator.free(windows);
    const shell = parseShell(allocator, metadata.shell) catch return .{ .ok = false, .message = "app.zon shell is invalid" };
    defer deinitParsedShell(allocator, shell);
    const commands = parseCommands(allocator, metadata.commands) catch return .{ .ok = false, .message = "app.zon commands are invalid" };
    defer allocator.free(commands);
    const menus = parseMenus(allocator, metadata.menus) catch return .{ .ok = false, .message = "app.zon menus are invalid" };
    defer deinitParsedMenus(allocator, menus);
    const shortcuts = parseShortcuts(allocator, metadata.shortcuts) catch return .{ .ok = false, .message = "app.zon shortcuts are invalid" };
    defer allocator.free(shortcuts);
    const file_associations = parseFileAssociations(allocator, metadata.file_associations) catch return .{ .ok = false, .message = "app.zon file associations are invalid" };
    defer allocator.free(file_associations);
    const url_schemes = parseUrlSchemes(allocator, metadata.url_schemes) catch return .{ .ok = false, .message = "app.zon URL schemes are invalid" };
    defer allocator.free(url_schemes);
    const manifest_web_engine = parseWebEngine(metadata.web_engine) catch return .{ .ok = false, .message = "app.zon web engine is invalid" };
    const platform_settings = parsePlatformSettings(allocator, metadata.platforms) catch return .{ .ok = false, .message = "app.zon platforms are invalid" };
    defer allocator.free(platform_settings);

    const manifest: app_manifest.Manifest = .{
        .identity = .{ .id = metadata.id, .name = metadata.name, .display_name = metadata.display_name, .description = metadata.description },
        .version = parseVersion(metadata.version) catch return .{ .ok = false, .message = "app.zon version is invalid" },
        .permissions = permissions,
        .capabilities = capabilities,
        .bridge = .{ .commands = bridge_commands },
        .frontend = frontend,
        .security = security,
        .platforms = platform_settings,
        .windows = windows,
        .shell = shell,
        .commands = commands,
        .menus = menus,
        .shortcuts = shortcuts,
        .file_associations = file_associations,
        .url_schemes = url_schemes,
        .cef = .{ .dir = metadata.cef.dir, .auto_install = metadata.cef.auto_install },
        .package = .{ .web_engine = manifest_web_engine },
    };
    app_manifest.validateManifest(manifest) catch return .{ .ok = false, .message = "manifest fields failed semantic validation" };
    return .{ .ok = true, .message = "app.zon is valid" };
}

/// Re-parse a failed manifest with std.zon diagnostics enabled so the
/// message names the line and column instead of a bare "could not be
/// parsed". Returns null when no diagnostic could be produced; the
/// (allocated) message intentionally lives until process exit.
fn zonParseFailureMessage(allocator: std.mem.Allocator, source: []const u8) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const source_z = scratch.dupeZ(u8, source) catch return null;
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(scratch);
    @setEvalBranchQuota(2000);
    if (std.zon.parse.fromSliceAlloc(RawManifest, scratch, source_z, &diag, .{})) |_| {
        return null;
    } else |_| {
        const rendered = std.fmt.allocPrint(scratch, "{f}", .{&diag}) catch return null;
        const first_line_end = std.mem.indexOfScalar(u8, rendered, '\n') orelse rendered.len;
        const first_line = std.mem.trim(u8, rendered[0..first_line_end], " \n");
        if (first_line.len == 0) return null;
        return std.fmt.allocPrint(allocator, "app.zon could not be parsed - {s}", .{first_line}) catch null;
    }
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
    @setEvalBranchQuota(2000);
    const raw = try std.zon.parse.fromSliceAlloc(RawManifest, scratch, source_z, null, .{});
    return .{
        .id = try allocator.dupe(u8, raw.id),
        .name = try allocator.dupe(u8, raw.name),
        .display_name = if (raw.display_name) |value| try allocator.dupe(u8, value) else null,
        .description = if (raw.description) |value| try allocator.dupe(u8, value) else null,
        .theme = if (raw.theme) |value| try allocator.dupe(u8, value) else null,
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
        .shell = try convertRawShell(allocator, raw.shell),
        .commands = try convertRawCommands(allocator, raw.commands),
        .menus = try convertRawMenus(allocator, raw.menus),
        .shortcuts = try convertRawShortcuts(allocator, raw.shortcuts),
        .file_associations = try convertRawFileAssociations(allocator, raw.file_associations),
        .url_schemes = try convertRawUrlSchemes(allocator, raw.url_schemes),
    };
}

fn duplicateOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |payload| try allocator.dupe(u8, payload) else null;
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
            .resizable = window.resizable,
            .restore_state = window.restore_state,
            .titlebar = try allocator.dupe(u8, window.titlebar),
            .min_width = window.min_width,
            .min_height = window.min_height,
        };
    }
    return converted;
}

fn convertRawShell(allocator: std.mem.Allocator, shell: RawShell) !ShellMetadata {
    return .{
        .windows = try convertRawShellWindows(allocator, shell.windows),
        .chrome = try convertRawShellChrome(allocator, shell.chrome),
    };
}

fn convertRawShellChrome(allocator: std.mem.Allocator, chrome: raw_manifest.RawShellChrome) !ShellChromeMetadata {
    var converted: ShellChromeMetadata = .{};
    if (chrome.tabs.len > 0) {
        const tabs = try allocator.alloc(ShellTabMetadata, chrome.tabs.len);
        for (chrome.tabs, 0..) |tab, index| {
            tabs[index] = .{
                .id = try allocator.dupe(u8, tab.id),
                .label = try allocator.dupe(u8, tab.label),
                .icon = try allocator.dupe(u8, tab.icon),
            };
        }
        converted.tabs = tabs;
    }
    if (chrome.primary_action) |action| {
        converted.primary_action = .{
            .id = try allocator.dupe(u8, action.id),
            .label = try allocator.dupe(u8, action.label),
            .icon = try allocator.dupe(u8, action.icon),
        };
    }
    return converted;
}

fn convertRawShellWindows(allocator: std.mem.Allocator, windows: []const RawShellWindow) ![]const ShellWindowMetadata {
    if (windows.len == 0) return &.{};
    const converted = try allocator.alloc(ShellWindowMetadata, windows.len);
    for (windows, 0..) |window, index| {
        converted[index] = .{
            .label = try allocator.dupe(u8, window.label),
            .title = try duplicateOptionalString(allocator, window.title),
            .width = window.width,
            .height = window.height,
            .x = window.x,
            .y = window.y,
            .resizable = window.resizable,
            .restore_state = window.restore_state,
            .restore_policy = try allocator.dupe(u8, window.restore_policy),
            .titlebar = try allocator.dupe(u8, window.titlebar),
            .min_width = window.min_width,
            .min_height = window.min_height,
            .views = try convertRawShellViews(allocator, window.views),
        };
    }
    return converted;
}

fn convertRawShellViews(allocator: std.mem.Allocator, views: []const RawShellView) ![]const ShellViewMetadata {
    if (views.len == 0) return &.{};
    const converted = try allocator.alloc(ShellViewMetadata, views.len);
    for (views, 0..) |view, index| {
        converted[index] = .{
            .label = try allocator.dupe(u8, view.label),
            .kind = try allocator.dupe(u8, view.kind),
            .parent = try duplicateOptionalString(allocator, view.parent),
            .edge = try duplicateOptionalString(allocator, view.edge),
            .axis = try duplicateOptionalString(allocator, view.axis),
            .x = view.x,
            .y = view.y,
            .width = view.width,
            .height = view.height,
            .min_width = view.min_width,
            .min_height = view.min_height,
            .max_width = view.max_width,
            .max_height = view.max_height,
            .fill = view.fill,
            .layer = view.layer,
            .visible = view.visible,
            .enabled = view.enabled,
            .role = try duplicateOptionalString(allocator, view.role),
            .accessibility_label = try duplicateOptionalString(allocator, view.accessibility_label),
            .url = try duplicateOptionalString(allocator, view.url),
            .text = try duplicateOptionalString(allocator, view.text),
            .command = try duplicateOptionalString(allocator, view.command),
            .gpu_backend = try duplicateOptionalString(allocator, view.gpu_backend),
            .gpu_pixel_format = try duplicateOptionalString(allocator, view.gpu_pixel_format),
            .gpu_present_mode = try duplicateOptionalString(allocator, view.gpu_present_mode),
            .gpu_alpha_mode = try duplicateOptionalString(allocator, view.gpu_alpha_mode),
            .gpu_color_space = try duplicateOptionalString(allocator, view.gpu_color_space),
            .gpu_vsync = view.gpu_vsync,
        };
    }
    return converted;
}

fn convertRawShortcuts(allocator: std.mem.Allocator, shortcuts: []const RawShortcut) ![]const ShortcutMetadata {
    if (shortcuts.len == 0) return &.{};
    const converted = try allocator.alloc(ShortcutMetadata, shortcuts.len);
    for (shortcuts, 0..) |shortcut, index| {
        converted[index] = .{
            .id = try allocator.dupe(u8, shortcut.id),
            .key = try allocator.dupe(u8, shortcut.key),
            .modifiers = try duplicateStringList(allocator, shortcut.modifiers),
        };
    }
    return converted;
}

fn convertRawCommands(allocator: std.mem.Allocator, commands: []const RawCommand) ![]const CommandMetadata {
    if (commands.len == 0) return &.{};
    const converted = try allocator.alloc(CommandMetadata, commands.len);
    for (commands, 0..) |command, index| {
        converted[index] = .{
            .id = try allocator.dupe(u8, command.id),
            .title = try allocator.dupe(u8, command.title),
            .enabled = command.enabled,
            .checked = command.checked,
        };
    }
    return converted;
}

fn convertRawMenus(allocator: std.mem.Allocator, menus: []const RawMenu) ![]const MenuMetadata {
    if (menus.len == 0) return &.{};
    const converted = try allocator.alloc(MenuMetadata, menus.len);
    for (menus, 0..) |menu, index| {
        converted[index] = .{
            .title = try allocator.dupe(u8, menu.title),
            .items = try convertRawMenuItems(allocator, menu.items),
        };
    }
    return converted;
}

fn convertRawMenuItems(allocator: std.mem.Allocator, items: []const RawMenuItem) ![]const MenuItemMetadata {
    if (items.len == 0) return &.{};
    const converted = try allocator.alloc(MenuItemMetadata, items.len);
    for (items, 0..) |item, index| {
        converted[index] = .{
            .label = try allocator.dupe(u8, item.label),
            .command = try allocator.dupe(u8, item.command),
            .key = try allocator.dupe(u8, item.key),
            .modifiers = try duplicateStringList(allocator, item.modifiers),
            .separator = item.separator,
            .enabled = item.enabled,
            .checked = item.checked,
        };
    }
    return converted;
}

fn convertRawFileAssociations(allocator: std.mem.Allocator, associations: []const RawFileAssociation) ![]const FileAssociationMetadata {
    if (associations.len == 0) return &.{};
    const converted = try allocator.alloc(FileAssociationMetadata, associations.len);
    for (associations, 0..) |association, index| {
        converted[index] = .{
            .name = try allocator.dupe(u8, association.name),
            .role = try allocator.dupe(u8, association.role),
            .extensions = try duplicateStringList(allocator, association.extensions),
            .mime_types = try duplicateStringList(allocator, association.mime_types),
            .icon = try duplicateOptionalString(allocator, association.icon),
        };
    }
    return converted;
}

fn convertRawUrlSchemes(allocator: std.mem.Allocator, schemes: []const RawUrlScheme) ![]const UrlSchemeMetadata {
    if (schemes.len == 0) return &.{};
    const converted = try allocator.alloc(UrlSchemeMetadata, schemes.len);
    for (schemes, 0..) |scheme, index| {
        converted[index] = .{
            .scheme = try allocator.dupe(u8, scheme.scheme),
            .role = try allocator.dupe(u8, scheme.role),
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
    var buffer: [1024]u8 = undefined;
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
    errdefer allocator.free(converted);
    for (windows, 0..) |window, index| {
        converted[index] = .{
            .label = window.label,
            .title = window.title,
            .width = window.width,
            .height = window.height,
            .x = window.x,
            .y = window.y,
            .resizable = window.resizable,
            .restore_state = window.restore_state,
            .titlebar = try parseTitlebarStyle(window.titlebar),
            .min_width = try parseWindowMinSize(window.min_width),
            .min_height = try parseWindowMinSize(window.min_height),
        };
    }
    return converted;
}

fn parseShell(allocator: std.mem.Allocator, shell: ShellMetadata) !app_manifest.ShellConfig {
    const chrome = try parseShellChrome(allocator, shell.chrome);
    errdefer if (chrome.tabs.len > 0) allocator.free(chrome.tabs);
    if (shell.windows.len == 0) return .{ .chrome = chrome };
    const windows = try allocator.alloc(app_manifest.ShellWindow, shell.windows.len);
    errdefer allocator.free(windows);
    var initialized: usize = 0;
    errdefer {
        for (windows[0..initialized]) |window| {
            if (window.views.len > 0) allocator.free(window.views);
        }
    }
    for (shell.windows, 0..) |window, index| {
        // Parse the fallible scalar fields BEFORE allocating the views
        // slice, so a bad policy/titlebar string cannot leak it.
        const restore_policy = try parseRestorePolicy(window.restore_policy);
        const titlebar = try parseTitlebarStyle(window.titlebar);
        const min_width = try parseWindowMinSize(window.min_width);
        const min_height = try parseWindowMinSize(window.min_height);
        const views = try parseShellViews(allocator, window.views);
        windows[index] = .{
            .label = window.label,
            .title = window.title,
            .width = window.width,
            .height = window.height,
            .x = window.x,
            .y = window.y,
            .resizable = window.resizable,
            .restore_state = window.restore_state,
            .restore_policy = restore_policy,
            .titlebar = titlebar,
            .min_width = min_width,
            .min_height = min_height,
            .views = views,
        };
        initialized += 1;
    }
    return .{ .windows = windows, .chrome = chrome };
}

/// Declared platform chrome from app.zon metadata: the strings pass
/// through (Metadata owns them, exactly like window/view labels); only
/// the tabs slice is parse-owned. Structural rules live in
/// `app_manifest.validateShellChrome`, which `parseShell`'s caller runs
/// over the whole shell.
fn parseShellChrome(allocator: std.mem.Allocator, chrome: ShellChromeMetadata) !app_manifest.ShellChrome {
    var parsed: app_manifest.ShellChrome = .{};
    if (chrome.tabs.len > 0) {
        const tabs = try allocator.alloc(app_manifest.ShellTab, chrome.tabs.len);
        for (chrome.tabs, 0..) |tab, index| {
            tabs[index] = .{ .id = tab.id, .label = tab.label, .icon = tab.icon };
        }
        parsed.tabs = tabs;
    }
    if (chrome.primary_action) |action| {
        parsed.primary_action = .{ .id = action.id, .label = action.label, .icon = action.icon };
    }
    return parsed;
}

fn parseShellViews(allocator: std.mem.Allocator, values: []const ShellViewMetadata) ![]const app_manifest.ShellView {
    if (values.len == 0) return &.{};
    const views = try allocator.alloc(app_manifest.ShellView, values.len);
    errdefer allocator.free(views);
    for (values, 0..) |view, index| {
        views[index] = .{
            .label = view.label,
            .kind = try parseViewKind(view.kind),
            .parent = view.parent,
            .edge = if (view.edge) |edge| try parseShellEdge(edge) else null,
            .axis = if (view.axis) |axis| try parseShellAxis(axis) else null,
            .x = view.x,
            .y = view.y,
            .width = view.width,
            .height = view.height,
            .min_width = view.min_width,
            .min_height = view.min_height,
            .max_width = view.max_width,
            .max_height = view.max_height,
            .fill = view.fill,
            .layer = view.layer,
            .visible = view.visible,
            .enabled = view.enabled,
            .role = view.role,
            .accessibility_label = view.accessibility_label,
            .url = view.url,
            .text = view.text,
            .command = view.command,
            .gpu_backend = if (view.gpu_backend) |value| try parseGpuSurfaceBackend(value) else null,
            .gpu_pixel_format = if (view.gpu_pixel_format) |value| try parseGpuSurfacePixelFormat(value) else null,
            .gpu_present_mode = if (view.gpu_present_mode) |value| try parseGpuSurfacePresentMode(value) else null,
            .gpu_alpha_mode = if (view.gpu_alpha_mode) |value| try parseGpuSurfaceAlphaMode(value) else null,
            .gpu_color_space = if (view.gpu_color_space) |value| try parseGpuSurfaceColorSpace(value) else null,
            .gpu_vsync = view.gpu_vsync,
        };
    }
    return views;
}

fn deinitParsedShell(allocator: std.mem.Allocator, shell: app_manifest.ShellConfig) void {
    for (shell.windows) |window| {
        if (window.views.len > 0) allocator.free(window.views);
    }
    if (shell.windows.len > 0) allocator.free(shell.windows);
    if (shell.chrome.tabs.len > 0) allocator.free(shell.chrome.tabs);
}

fn deinitParsedMenus(allocator: std.mem.Allocator, menus: []const app_manifest.Menu) void {
    for (menus) |menu| {
        if (menu.items.len > 0) allocator.free(menu.items);
    }
    if (menus.len > 0) allocator.free(menus);
}

/// The built-in theme pack names, kept in step with the canvas
/// `ThemePack` enum (tooling deliberately does not link the canvas
/// module; the runner re-validates at comptime, so a drift here shows
/// up as a build error in the app, never a silently shipped typo).
fn isKnownThemePack(name: []const u8) bool {
    const known = [_][]const u8{ "house", "geist" };
    for (known) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn validateIconPaths(icons: []const []const u8) !void {
    for (icons, 0..) |icon, index| {
        try validateRelativePath(icon);
        for (icons[0..index]) |previous| {
            if (std.mem.eql(u8, previous, icon)) return error.DuplicateIcon;
        }
    }
}

/// The app-icon teaching checks `native validate` and `native check`
/// share with packaging (same messages, no packaging): every `.icons`
/// entry must be a generatable source (.png/.svg) or a prebuilt
/// container (.icns/.ico), and a source file that exists must decode to
/// a square image. A missing file is packaging's problem (it warns and
/// falls back); an undersized source prints the upscaling warning
/// without failing validation. Returns the error message or null when
/// the icons pass. The returned message is allocated and intentionally
/// lives until process exit (same policy as `zonParseFailureMessage`).
fn checkIconSources(allocator: std.mem.Allocator, io: std.Io, manifest_dir: []const u8, icons: []const []const u8) !?[]const u8 {
    for (icons) |icon_path| {
        const is_prebuilt = app_icon_tool.pathHasExtension(icon_path, ".icns") or
            app_icon_tool.pathHasExtension(icon_path, ".ico");
        const kind = app_icon_tool.sourceKindForPath(icon_path) orelse {
            if (is_prebuilt) continue;
            var buffer: [512]u8 = undefined;
            return try allocator.dupe(u8, app_icon_tool.formatBadExtensionMessage(&buffer, icon_path));
        };

        const resolved = try std.fs.path.join(allocator, &.{ manifest_dir, icon_path });
        defer allocator.free(resolved);
        const bytes = readFile(allocator, io, resolved) catch continue;
        defer allocator.free(bytes);
        switch (try app_icon_tool.loadSource(allocator, bytes, kind)) {
            .ok => |loaded| {
                var source = loaded;
                defer source.deinit(allocator);
                if (kind == .png and source.width < app_icon_tool.min_recommended_source_size) {
                    var buffer: [512]u8 = undefined;
                    std.debug.print("{s}\n", .{app_icon_tool.formatSmallSourceMessage(&buffer, icon_path, source.width, source.height)});
                }
            },
            .issue => |issue| {
                var buffer: [512]u8 = undefined;
                const message = switch (issue) {
                    .not_square => |dims| app_icon_tool.formatNotSquareMessage(&buffer, icon_path, dims.width, dims.height),
                    .unsupported => app_icon_tool.formatUnsupportedMessage(&buffer, icon_path),
                };
                return try allocator.dupe(u8, message);
            },
        }
    }
    return null;
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
    if (std.mem.eql(u8, value, "command")) return .command;
    if (std.mem.eql(u8, value, "view")) return .view;
    if (std.mem.eql(u8, value, "dialog")) return .dialog;
    if (std.mem.eql(u8, value, "credentials")) return .credentials;
    return .{ .custom = value };
}

fn parseCapability(value: []const u8) !app_manifest.Capability {
    if (std.mem.eql(u8, value, "native_module")) return .native_module;
    if (std.mem.eql(u8, value, "webview")) return .webview;
    if (std.mem.eql(u8, value, "js_bridge")) return .js_bridge;
    if (std.mem.eql(u8, value, "native_views")) return .native_views;
    if (std.mem.eql(u8, value, "gpu_surfaces")) return .gpu_surfaces;
    if (std.mem.eql(u8, value, "menus")) return .menus;
    if (std.mem.eql(u8, value, "shortcuts")) return .shortcuts;
    if (std.mem.eql(u8, value, "tray")) return .tray;
    if (std.mem.eql(u8, value, "filesystem")) return .filesystem;
    if (std.mem.eql(u8, value, "network")) return .network;
    if (std.mem.eql(u8, value, "notifications")) return .notifications;
    if (std.mem.eql(u8, value, "dialog")) return .dialog;
    if (std.mem.eql(u8, value, "clipboard")) return .clipboard;
    if (std.mem.eql(u8, value, "credentials")) return .credentials;
    if (std.mem.eql(u8, value, "open_url")) return .open_url;
    if (std.mem.eql(u8, value, "reveal_path")) return .reveal_path;
    if (std.mem.eql(u8, value, "recent_documents")) return .recent_documents;
    if (std.mem.eql(u8, value, "file_drops")) return .file_drops;
    if (std.mem.eql(u8, value, "app_activation_events")) return .app_activation_events;
    if (std.mem.eql(u8, value, "file_associations")) return .file_associations;
    if (std.mem.eql(u8, value, "url_schemes")) return .url_schemes;
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

fn parseShortcuts(allocator: std.mem.Allocator, values: []const ShortcutMetadata) ![]const app_manifest.Shortcut {
    if (values.len == 0) return &.{};
    var shortcuts: std.ArrayList(app_manifest.Shortcut) = .empty;
    errdefer shortcuts.deinit(allocator);
    for (values) |value| {
        try shortcuts.append(allocator, .{
            .id = value.id,
            .key = value.key,
            .modifiers = try parseShortcutModifiers(value.modifiers),
        });
    }
    return shortcuts.toOwnedSlice(allocator);
}

fn parseCommands(allocator: std.mem.Allocator, values: []const CommandMetadata) ![]const app_manifest.Command {
    if (values.len == 0) return &.{};
    var commands: std.ArrayList(app_manifest.Command) = .empty;
    errdefer commands.deinit(allocator);
    for (values) |value| {
        try commands.append(allocator, .{
            .id = value.id,
            .title = value.title,
            .enabled = value.enabled,
            .checked = value.checked,
        });
    }
    return commands.toOwnedSlice(allocator);
}

fn parseMenus(allocator: std.mem.Allocator, values: []const MenuMetadata) ![]const app_manifest.Menu {
    if (values.len == 0) return &.{};
    var menus: std.ArrayList(app_manifest.Menu) = .empty;
    errdefer {
        for (menus.items) |menu| {
            if (menu.items.len > 0) allocator.free(menu.items);
        }
        menus.deinit(allocator);
    }
    for (values) |value| {
        try menus.append(allocator, .{
            .title = value.title,
            .items = try parseMenuItems(allocator, value.items),
        });
    }
    return menus.toOwnedSlice(allocator);
}

fn parseMenuItems(allocator: std.mem.Allocator, values: []const MenuItemMetadata) ![]const app_manifest.MenuItem {
    if (values.len == 0) return &.{};
    var items: std.ArrayList(app_manifest.MenuItem) = .empty;
    errdefer items.deinit(allocator);
    for (values) |value| {
        try items.append(allocator, .{
            .label = value.label,
            .command = value.command,
            .key = value.key,
            .modifiers = try parseShortcutModifiers(value.modifiers),
            .separator = value.separator,
            .enabled = value.enabled,
            .checked = value.checked,
        });
    }
    return items.toOwnedSlice(allocator);
}

fn parseFileAssociations(allocator: std.mem.Allocator, values: []const FileAssociationMetadata) ![]const app_manifest.FileAssociation {
    if (values.len == 0) return &.{};
    var associations: std.ArrayList(app_manifest.FileAssociation) = .empty;
    errdefer associations.deinit(allocator);
    for (values) |value| {
        try associations.append(allocator, .{
            .name = value.name,
            .role = try parseAssociationRole(value.role),
            .extensions = value.extensions,
            .mime_types = value.mime_types,
            .icon = value.icon,
        });
    }
    return associations.toOwnedSlice(allocator);
}

fn parseUrlSchemes(allocator: std.mem.Allocator, values: []const UrlSchemeMetadata) ![]const app_manifest.UrlScheme {
    if (values.len == 0) return &.{};
    var schemes: std.ArrayList(app_manifest.UrlScheme) = .empty;
    errdefer schemes.deinit(allocator);
    for (values) |value| {
        try schemes.append(allocator, .{
            .scheme = value.scheme,
            .role = try parseAssociationRole(value.role),
        });
    }
    return schemes.toOwnedSlice(allocator);
}

fn parseAssociationRole(value: []const u8) !app_manifest.AssociationRole {
    if (std.mem.eql(u8, value, "viewer")) return .viewer;
    if (std.mem.eql(u8, value, "editor")) return .editor;
    if (std.mem.eql(u8, value, "shell")) return .shell;
    if (std.mem.eql(u8, value, "none")) return .none;
    return error.InvalidAssociationRole;
}

fn parseShortcutModifiers(values: []const []const u8) !app_manifest.ShortcutModifiers {
    var modifiers: app_manifest.ShortcutModifiers = .{};
    for (values) |value| {
        if (std.mem.eql(u8, value, "primary")) {
            modifiers.primary = true;
        } else if (std.mem.eql(u8, value, "command")) {
            modifiers.command = true;
        } else if (std.mem.eql(u8, value, "control")) {
            modifiers.control = true;
        } else if (std.mem.eql(u8, value, "option") or std.mem.eql(u8, value, "alt")) {
            modifiers.option = true;
        } else if (std.mem.eql(u8, value, "shift")) {
            modifiers.shift = true;
        } else {
            return error.InvalidShortcut;
        }
    }
    return modifiers;
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

fn parseRestorePolicy(value: []const u8) !app_manifest.WindowRestorePolicy {
    if (std.mem.eql(u8, value, "clamp_to_visible_screen")) return .clamp_to_visible_screen;
    if (std.mem.eql(u8, value, "center_on_primary")) return .center_on_primary;
    return error.InvalidWindowRestorePolicy;
}

fn parseTitlebarStyle(value: []const u8) !app_manifest.WindowTitlebarStyle {
    if (std.mem.eql(u8, value, "standard")) return .standard;
    if (std.mem.eql(u8, value, "hidden_inset")) return .hidden_inset;
    if (std.mem.eql(u8, value, "hidden_inset_tall")) return .hidden_inset_tall;
    if (std.mem.eql(u8, value, "chromeless")) return .chromeless;
    return error.InvalidWindowTitlebarStyle;
}

/// Same validation posture as the titlebar style: a min-size floor the
/// host cannot honor (negative or non-finite) is a manifest error, not
/// a silent clamp. 0 is the "no floor" sentinel.
fn parseWindowMinSize(value: f32) !f32 {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidWindowMinSize;
    return value;
}

fn parseViewKind(value: []const u8) !app_manifest.ViewKind {
    if (std.mem.eql(u8, value, "webview")) return .webview;
    if (std.mem.eql(u8, value, "toolbar")) return .toolbar;
    if (std.mem.eql(u8, value, "titlebar_accessory")) return .titlebar_accessory;
    if (std.mem.eql(u8, value, "sidebar")) return .sidebar;
    if (std.mem.eql(u8, value, "statusbar")) return .statusbar;
    if (std.mem.eql(u8, value, "split")) return .split;
    if (std.mem.eql(u8, value, "stack")) return .stack;
    if (std.mem.eql(u8, value, "button")) return .button;
    if (std.mem.eql(u8, value, "icon_button")) return .icon_button;
    if (std.mem.eql(u8, value, "list_item")) return .list_item;
    if (std.mem.eql(u8, value, "checkbox")) return .checkbox;
    if (std.mem.eql(u8, value, "toggle")) return .toggle;
    if (std.mem.eql(u8, value, "segmented_control")) return .segmented_control;
    if (std.mem.eql(u8, value, "text_field")) return .text_field;
    if (std.mem.eql(u8, value, "search_field")) return .search_field;
    if (std.mem.eql(u8, value, "label")) return .label;
    if (std.mem.eql(u8, value, "spacer")) return .spacer;
    if (std.mem.eql(u8, value, "gpu_surface")) return .gpu_surface;
    if (std.mem.eql(u8, value, "progress_indicator")) return .progress_indicator;
    return error.InvalidViewKind;
}

fn parseGpuSurfaceBackend(value: []const u8) !app_manifest.GpuSurfaceBackend {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "metal")) return .metal;
    if (std.mem.eql(u8, value, "software")) return .software;
    return error.InvalidViewKind;
}

fn parseGpuSurfacePixelFormat(value: []const u8) !app_manifest.GpuSurfacePixelFormat {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "bgra8_unorm")) return .bgra8_unorm;
    return error.InvalidViewKind;
}

fn parseGpuSurfacePresentMode(value: []const u8) !app_manifest.GpuSurfacePresentMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "timer")) return .timer;
    return error.InvalidViewKind;
}

fn parseGpuSurfaceAlphaMode(value: []const u8) !app_manifest.GpuSurfaceAlphaMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "opaque")) return .@"opaque";
    if (std.mem.eql(u8, value, "premultiplied")) return .premultiplied;
    return error.InvalidViewKind;
}

fn parseGpuSurfaceColorSpace(value: []const u8) !app_manifest.GpuSurfaceColorSpace {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "srgb")) return .srgb;
    if (std.mem.eql(u8, value, "display_p3")) return .display_p3;
    return error.InvalidViewKind;
}

fn parseShellEdge(value: []const u8) !app_manifest.ShellEdge {
    if (std.mem.eql(u8, value, "top")) return .top;
    if (std.mem.eql(u8, value, "right")) return .right;
    if (std.mem.eql(u8, value, "bottom")) return .bottom;
    if (std.mem.eql(u8, value, "left")) return .left;
    return error.InvalidLayout;
}

fn parseShellAxis(value: []const u8) !app_manifest.ShellAxis {
    if (std.mem.eql(u8, value, "row") or std.mem.eql(u8, value, "horizontal")) return .row;
    if (std.mem.eql(u8, value, "column") or std.mem.eql(u8, value, "vertical")) return .column;
    return error.InvalidLayout;
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
        \\  .description = "An example app for the manifest parser.",
        \\  .version = "1.2.3",
        \\  .icons = .{ "assets/icon.png" },
        \\  .platforms = .{ "macos", "linux" },
        \\  .capabilities = .{
        \\    "native_module", "webview", "js_bridge", "native_views", "gpu_surfaces", "menus", "shortcuts", "tray",
        \\    "dialog", "credentials", "file_drops", "file_associations", "url_schemes",
        \\    "open_url", "reveal_path", "recent_documents", "app_activation_events",
        \\  },
        \\  .bridge = .{ .commands = .{ .{ .name = "native.ping" } } },
        \\  .web_engine = "chromium",
        \\  .cef = .{ .dir = "third_party/cef/macos", .auto_install = true },
        \\  .commands = .{
        \\    .{ .id = "app.refresh", .title = "Refresh" },
        \\    .{ .id = "app.sidebar.toggle", .title = "Sidebar", .checked = true },
        \\  },
        \\  .menus = .{
        \\    .{
        \\      .title = "View",
        \\      .items = .{
        \\        .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ "primary" } },
        \\        .{ .separator = true },
        \\        .{ .label = "Sidebar", .command = "app.sidebar.toggle", .checked = true },
        \\      },
        \\    },
        \\  },
        \\  .shortcuts = .{
        \\    .{ .id = "command.palette", .key = "p", .modifiers = .{ "primary", "shift" } },
        \\  },
        \\  .file_associations = .{
        \\    .{ .name = "Markdown Document", .extensions = .{ "md", ".markdown" }, .mime_types = .{ "text/markdown" }, .icon = "assets/markdown.icns" },
        \\  },
        \\  .url_schemes = .{
        \\    .{ .scheme = "example-app" },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("com.example.app", metadata.id);
    try std.testing.expectEqualStrings("example", metadata.name);
    try std.testing.expectEqualStrings("Example App", metadata.displayName());
    try std.testing.expectEqualStrings("An example app for the manifest parser.", metadata.description.?);
    try std.testing.expectEqualStrings("1.2.3", metadata.version);
    try std.testing.expectEqualStrings("assets/icon.png", metadata.icons[0]);
    try std.testing.expectEqualStrings("linux", metadata.platforms[1]);
    try std.testing.expectEqualStrings("webview", metadata.capabilities[1]);
    try std.testing.expectEqualStrings("native_views", metadata.capabilities[3]);
    try std.testing.expectEqualStrings("gpu_surfaces", metadata.capabilities[4]);
    try std.testing.expectEqualStrings("dialog", metadata.capabilities[8]);
    try std.testing.expectEqualStrings("file_drops", metadata.capabilities[10]);
    try std.testing.expectEqualStrings("url_schemes", metadata.capabilities[12]);
    const parsed_capabilities = try parseCapabilities(std.testing.allocator, metadata.capabilities);
    defer std.testing.allocator.free(parsed_capabilities);
    try std.testing.expectEqual(app_manifest.CapabilityKind.native_views, parsed_capabilities[3].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.gpu_surfaces, parsed_capabilities[4].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.menus, parsed_capabilities[5].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.shortcuts, parsed_capabilities[6].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.tray, parsed_capabilities[7].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.file_drops, parsed_capabilities[10].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.file_associations, parsed_capabilities[11].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.url_schemes, parsed_capabilities[12].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.open_url, parsed_capabilities[13].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.reveal_path, parsed_capabilities[14].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.recent_documents, parsed_capabilities[15].kind());
    try std.testing.expectEqual(app_manifest.CapabilityKind.app_activation_events, parsed_capabilities[16].kind());
    try std.testing.expectEqualStrings("native.ping", metadata.bridge_commands[0].name);
    try std.testing.expectEqualStrings("app.refresh", metadata.commands[0].id);
    try std.testing.expectEqualStrings("Refresh", metadata.commands[0].title);
    try std.testing.expect(metadata.commands[0].enabled);
    try std.testing.expect(metadata.commands[1].checked);
    try std.testing.expectEqualStrings("View", metadata.menus[0].title);
    try std.testing.expectEqualStrings("Refresh", metadata.menus[0].items[0].label);
    try std.testing.expectEqualStrings("app.refresh", metadata.menus[0].items[0].command);
    try std.testing.expectEqualStrings("primary", metadata.menus[0].items[0].modifiers[0]);
    try std.testing.expect(metadata.menus[0].items[1].separator);
    try std.testing.expect(metadata.menus[0].items[2].checked);
    try std.testing.expectEqualStrings("command.palette", metadata.shortcuts[0].id);
    try std.testing.expectEqualStrings("primary", metadata.shortcuts[0].modifiers[0]);
    try std.testing.expectEqualStrings("Markdown Document", metadata.file_associations[0].name);
    try std.testing.expectEqualStrings(".markdown", metadata.file_associations[0].extensions[1]);
    try std.testing.expectEqualStrings("text/markdown", metadata.file_associations[0].mime_types[0]);
    try std.testing.expectEqualStrings("assets/markdown.icns", metadata.file_associations[0].icon.?);
    try std.testing.expectEqualStrings("example-app", metadata.url_schemes[0].scheme);
    try std.testing.expectEqualStrings("chromium", metadata.web_engine);
    try std.testing.expectEqualStrings("third_party/cef/macos", metadata.cef.dir);
    try std.testing.expect(metadata.cef.auto_install);
    try std.testing.expectEqual(@as(u32, 2), (try parseVersion(metadata.version)).minor);

    const associations = try parseFileAssociations(std.testing.allocator, metadata.file_associations);
    defer std.testing.allocator.free(associations);
    const schemes = try parseUrlSchemes(std.testing.allocator, metadata.url_schemes);
    defer std.testing.allocator.free(schemes);
    const menus = try parseMenus(std.testing.allocator, metadata.menus);
    defer deinitParsedMenus(std.testing.allocator, menus);
    const commands = try parseCommands(std.testing.allocator, metadata.commands);
    defer std.testing.allocator.free(commands);
    try app_manifest.validateManifest(.{
        .identity = .{ .id = metadata.id, .name = metadata.name },
        .version = try parseVersion(metadata.version),
        .commands = commands,
        .menus = menus,
        .file_associations = associations,
        .url_schemes = schemes,
    });
}

test "manifest metadata parser reads structured security policy" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .permissions = .{ "window", "filesystem", "credentials" },
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
    try std.testing.expectEqualStrings("credentials", metadata.permissions[2]);
    try std.testing.expectEqualStrings("native.ping", metadata.bridge_commands[0].name);
    try std.testing.expectEqualStrings("filesystem", metadata.bridge_commands[0].permissions[0]);
    try std.testing.expectEqualStrings("zero://app", metadata.bridge_commands[0].origins[0]);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173", metadata.security.navigation.allowed_origins[1]);
    try std.testing.expectEqualStrings("open_system_browser", metadata.security.navigation.external_links.action);
    try std.testing.expectEqualStrings("https://example.com/*", metadata.security.navigation.external_links.allowed_urls[0]);
}

test "manifest metadata parser reads declared platform chrome" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .shell = .{
        \\    .chrome = .{
        \\      .tabs = .{
        \\        .{ .id = "tabs.home", .label = "Home", .icon = "menu" },
        \\        .{ .id = "tabs.settings", .label = "Settings", .icon = "settings" },
        \\      },
        \\      .primary_action = .{ .id = "action.new", .label = "New", .icon = "plus" },
        \\    },
        \\    .windows = .{
        \\      .{
        \\        .label = "main",
        \\        .views = .{
        \\          .{ .label = "content", .kind = "webview", .url = "zero://app/index.html", .fill = true },
        \\        },
        \\      },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), metadata.shell.chrome.tabs.len);
    try std.testing.expectEqualStrings("tabs.home", metadata.shell.chrome.tabs[0].id);
    try std.testing.expectEqualStrings("Home", metadata.shell.chrome.tabs[0].label);
    try std.testing.expectEqualStrings("menu", metadata.shell.chrome.tabs[0].icon);
    try std.testing.expectEqualStrings("action.new", metadata.shell.chrome.primary_action.?.id);

    // The parsed shell carries the declaration through to the shared
    // manifest validation, which accepts it whole.
    const shell = try parseShell(std.testing.allocator, metadata.shell);
    defer deinitParsedShell(std.testing.allocator, shell);
    try std.testing.expectEqual(@as(usize, 2), shell.chrome.tabs.len);
    try std.testing.expectEqualStrings("tabs.settings", shell.chrome.tabs[1].id);
    try std.testing.expectEqualStrings("plus", shell.chrome.primary_action.?.icon);
    try app_manifest.validateShellChrome(shell.chrome);
}

test "manifest metadata parser reads shell windows and views" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .shell = .{
        \\    .windows = .{
        \\      .{
        \\        .label = "main",
        \\        .title = "Example",
        \\        .width = 1100,
        \\        .height = 760,
        \\        .restore_policy = "center_on_primary",
        \\        .views = .{
        \\          .{ .label = "toolbar", .kind = "toolbar", .edge = "top", .height = 44, .role = "toolbar" },
        \\          .{ .label = "content", .kind = "webview", .url = "zero://app/index.html", .fill = true, .min_width = 640, .min_height = 400, .max_width = 1440, .max_height = 900 },
        \\          .{ .label = "status", .kind = "statusbar", .edge = "bottom", .height = 24, .text = "Ready" },
        \\          .{ .label = "toolbar-stack", .kind = "stack", .parent = "toolbar", .axis = "column" },
        \\          .{ .label = "refresh-icon", .kind = "icon_button", .parent = "toolbar", .text = "R", .command = "app.refresh.icon" },
        \\          .{ .label = "save", .kind = "button", .parent = "toolbar", .accessibility_label = "Save document", .text = "Save", .command = "app.save" },
        \\          .{ .label = "mode", .kind = "segmented_control", .parent = "toolbar", .text = "List|Grid", .command = "app.view.mode" },
        \\          .{ .label = "syncing", .kind = "progress_indicator", .parent = "toolbar", .role = "Syncing" },
        \\          .{ .label = "nav-row", .kind = "list_item", .parent = "toolbar-stack", .text = "Inbox", .command = "app.open.inbox" },
        \\          .{ .label = "canvas", .kind = "gpu_surface", .gpu_backend = "metal", .gpu_pixel_format = "bgra8_unorm", .gpu_present_mode = "timer", .gpu_alpha_mode = "opaque", .gpu_color_space = "srgb", .gpu_vsync = true },
        \\        },
        \\      },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("main", metadata.shell.windows[0].label);
    try std.testing.expectEqualStrings("center_on_primary", metadata.shell.windows[0].restore_policy);
    try std.testing.expectEqualStrings("toolbar", metadata.shell.windows[0].views[0].kind);
    try std.testing.expectEqualStrings("zero://app/index.html", metadata.shell.windows[0].views[1].url.?);
    try std.testing.expect(metadata.shell.windows[0].views[1].fill);
    try std.testing.expectEqual(@as(?f32, 640), metadata.shell.windows[0].views[1].min_width);
    try std.testing.expectEqual(@as(?f32, 400), metadata.shell.windows[0].views[1].min_height);
    try std.testing.expectEqual(@as(?f32, 1440), metadata.shell.windows[0].views[1].max_width);
    try std.testing.expectEqual(@as(?f32, 900), metadata.shell.windows[0].views[1].max_height);
    try std.testing.expectEqualStrings("stack", metadata.shell.windows[0].views[3].kind);
    try std.testing.expectEqualStrings("column", metadata.shell.windows[0].views[3].axis.?);
    try std.testing.expectEqualStrings("icon_button", metadata.shell.windows[0].views[4].kind);
    try std.testing.expectEqualStrings("app.save", metadata.shell.windows[0].views[5].command.?);
    try std.testing.expectEqualStrings("Save document", metadata.shell.windows[0].views[5].accessibility_label.?);
    try std.testing.expectEqualStrings("segmented_control", metadata.shell.windows[0].views[6].kind);
    try std.testing.expectEqualStrings("progress_indicator", metadata.shell.windows[0].views[7].kind);
    try std.testing.expectEqualStrings("list_item", metadata.shell.windows[0].views[8].kind);
    try std.testing.expectEqualStrings("gpu_surface", metadata.shell.windows[0].views[9].kind);
    try std.testing.expectEqualStrings("metal", metadata.shell.windows[0].views[9].gpu_backend.?);
    try std.testing.expectEqualStrings("bgra8_unorm", metadata.shell.windows[0].views[9].gpu_pixel_format.?);
    try std.testing.expectEqualStrings("timer", metadata.shell.windows[0].views[9].gpu_present_mode.?);
    try std.testing.expectEqualStrings("opaque", metadata.shell.windows[0].views[9].gpu_alpha_mode.?);
    try std.testing.expectEqualStrings("srgb", metadata.shell.windows[0].views[9].gpu_color_space.?);
    try std.testing.expect(metadata.shell.windows[0].views[9].gpu_vsync.?);

    const shell = try parseShell(std.testing.allocator, metadata.shell);
    defer deinitParsedShell(std.testing.allocator, shell);
    try std.testing.expectEqual(app_manifest.ViewKind.webview, shell.windows[0].views[1].kind);
    try std.testing.expectEqual(@as(?f32, 640), shell.windows[0].views[1].min_width);
    try std.testing.expectEqual(@as(?f32, 400), shell.windows[0].views[1].min_height);
    try std.testing.expectEqual(@as(?f32, 1440), shell.windows[0].views[1].max_width);
    try std.testing.expectEqual(@as(?f32, 900), shell.windows[0].views[1].max_height);
    try std.testing.expectEqual(app_manifest.ViewKind.stack, shell.windows[0].views[3].kind);
    try std.testing.expectEqual(app_manifest.ShellAxis.column, shell.windows[0].views[3].axis.?);
    try std.testing.expectEqual(app_manifest.ViewKind.icon_button, shell.windows[0].views[4].kind);
    try std.testing.expectEqualStrings("Save document", shell.windows[0].views[5].accessibility_label.?);
    try std.testing.expectEqual(app_manifest.ViewKind.segmented_control, shell.windows[0].views[6].kind);
    try std.testing.expectEqual(app_manifest.ViewKind.progress_indicator, shell.windows[0].views[7].kind);
    try std.testing.expectEqual(app_manifest.ViewKind.list_item, shell.windows[0].views[8].kind);
    try std.testing.expectEqual(app_manifest.ViewKind.gpu_surface, shell.windows[0].views[9].kind);
    try std.testing.expectEqual(app_manifest.GpuSurfaceBackend.metal, shell.windows[0].views[9].gpu_backend.?);
    try std.testing.expectEqual(app_manifest.GpuSurfacePixelFormat.bgra8_unorm, shell.windows[0].views[9].gpu_pixel_format.?);
    try std.testing.expectEqual(app_manifest.GpuSurfacePresentMode.timer, shell.windows[0].views[9].gpu_present_mode.?);
    try std.testing.expectEqual(app_manifest.GpuSurfaceAlphaMode.@"opaque", shell.windows[0].views[9].gpu_alpha_mode.?);
    try std.testing.expectEqual(app_manifest.GpuSurfaceColorSpace.srgb, shell.windows[0].views[9].gpu_color_space.?);
    try std.testing.expect(shell.windows[0].views[9].gpu_vsync.?);
    try std.testing.expectEqual(app_manifest.ShellEdge.top, shell.windows[0].views[0].edge.?);
    try app_manifest.validateManifest(.{
        .identity = .{ .id = metadata.id, .name = metadata.name },
        .version = try parseVersion(metadata.version),
        .shell = shell,
    });
}

test "manifest parser reads window titlebar styles" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .windows = .{
        \\    .{ .label = "main", .resizable = false, .titlebar = "hidden_inset" },
        \\    .{ .label = "tall", .titlebar = "hidden_inset_tall" },
        \\    .{ .label = "skinned", .titlebar = "chromeless" },
        \\  },
        \\  .shell = .{
        \\    .windows = .{
        \\      .{ .label = "scene", .titlebar = "hidden_inset_tall", .views = .{ .{ .label = "content", .kind = "webview", .url = "zero://app/index.html" } } },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hidden_inset", metadata.windows[0].titlebar);
    try std.testing.expect(!metadata.windows[0].resizable);
    try std.testing.expectEqualStrings("hidden_inset_tall", metadata.windows[1].titlebar);
    try std.testing.expectEqualStrings("chromeless", metadata.windows[2].titlebar);
    try std.testing.expectEqualStrings("hidden_inset_tall", metadata.shell.windows[0].titlebar);

    const windows = try convertWindows(std.testing.allocator, metadata.windows);
    defer std.testing.allocator.free(windows);
    try std.testing.expectEqual(app_manifest.WindowTitlebarStyle.hidden_inset, windows[0].titlebar);
    try std.testing.expect(!windows[0].resizable);
    try std.testing.expectEqual(app_manifest.WindowTitlebarStyle.hidden_inset_tall, windows[1].titlebar);
    try std.testing.expectEqual(app_manifest.WindowTitlebarStyle.chromeless, windows[2].titlebar);

    const shell = try parseShell(std.testing.allocator, metadata.shell);
    defer deinitParsedShell(std.testing.allocator, shell);
    try std.testing.expectEqual(app_manifest.WindowTitlebarStyle.hidden_inset_tall, shell.windows[0].titlebar);
}

test "manifest parser reads window min sizes" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .windows = .{
        \\    .{ .label = "main", .min_width = 596, .min_height = 420 },
        \\  },
        \\  .shell = .{
        \\    .windows = .{
        \\      .{ .label = "scene", .min_width = 596, .min_height = 420, .views = .{ .{ .label = "content", .kind = "webview", .url = "zero://app/index.html" } } },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(f32, 596), metadata.windows[0].min_width);
    try std.testing.expectEqual(@as(f32, 420), metadata.windows[0].min_height);
    try std.testing.expectEqual(@as(f32, 596), metadata.shell.windows[0].min_width);

    const windows = try convertWindows(std.testing.allocator, metadata.windows);
    defer std.testing.allocator.free(windows);
    try std.testing.expectEqual(@as(f32, 596), windows[0].min_width);
    try std.testing.expectEqual(@as(f32, 420), windows[0].min_height);

    const shell = try parseShell(std.testing.allocator, metadata.shell);
    defer deinitParsedShell(std.testing.allocator, shell);
    try std.testing.expectEqual(@as(f32, 596), shell.windows[0].min_width);
    try std.testing.expectEqual(@as(f32, 420), shell.windows[0].min_height);
}

test "manifest parser rejects negative window min sizes" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .windows = .{
        \\    .{ .label = "main", .min_width = -1 },
        \\  },
        \\  .shell = .{
        \\    .windows = .{
        \\      .{ .label = "scene", .min_height = -20, .views = .{ .{ .label = "content", .kind = "webview", .url = "zero://app/index.html" } } },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidWindowMinSize, convertWindows(std.testing.allocator, metadata.windows));
    try std.testing.expectError(error.InvalidWindowMinSize, parseShell(std.testing.allocator, metadata.shell));
}

test "manifest parser rejects unknown window titlebar style" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .windows = .{
        \\    .{ .label = "main", .titlebar = "transparent" },
        \\  },
        \\  .shell = .{
        \\    .windows = .{
        \\      .{ .label = "scene", .titlebar = "frameless", .views = .{ .{ .label = "content", .kind = "webview", .url = "zero://app/index.html" } } },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidWindowTitlebarStyle, convertWindows(std.testing.allocator, metadata.windows));
    try std.testing.expectError(error.InvalidWindowTitlebarStyle, parseShell(std.testing.allocator, metadata.shell));
}

test "manifest parser rejects invalid shell view kind" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .shell = .{
        \\    .windows = .{
        \\      .{ .views = .{ .{ .label = "content", .kind = "unknown", .url = "zero://app/index.html" } } },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidViewKind, parseShell(std.testing.allocator, metadata.shell));
}

test "manifest parser rejects duplicate compatibility and shell window labels" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .windows = .{
        \\    .{ .label = "main" },
        \\  },
        \\  .shell = .{
        \\    .windows = .{
        \\      .{ .label = "main", .views = .{ .{ .label = "content", .kind = "webview", .url = "zero://app/index.html" } } },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    const windows = try convertWindows(std.testing.allocator, metadata.windows);
    defer std.testing.allocator.free(windows);
    const shell = try parseShell(std.testing.allocator, metadata.shell);
    defer deinitParsedShell(std.testing.allocator, shell);

    try std.testing.expectError(error.DuplicateWindow, app_manifest.validateManifest(.{
        .identity = .{ .id = metadata.id, .name = metadata.name },
        .version = try parseVersion(metadata.version),
        .windows = windows,
        .shell = shell,
    }));
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

test "validate surfaces the non-square icon teaching error with dimensions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-validate-icon-nonsquare";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");

    // A 6x4 white PNG source.
    const pixels = try gpa.alloc(u8, 6 * 4 * 4);
    @memset(pixels, 255);
    const encoded = try app_icon_tool.encodePng(gpa, pixels, 6, 4);
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/assets/icon.png", .data = encoded });
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/app.zon", .data =
        \\.{
        \\  .id = "dev.example.app",
        \\  .name = "demo",
        \\  .version = "1.0.0",
        \\  .icons = .{"assets/icon.png"},
        \\}
    });

    const result = try validateFile(gpa, std.testing.io, root ++ "/app.zon");
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.message, "6x4") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.message, "square") != null);
}

test "validate rejects unsupported icon extensions naming the accepted forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-validate-icon-ext";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root);
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/app.zon", .data =
        \\.{
        \\  .id = "dev.example.app",
        \\  .name = "demo",
        \\  .version = "1.0.0",
        \\  .icons = .{"assets/icon.jpg"},
        \\}
    });

    const result = try validateFile(gpa, std.testing.io, root ++ "/app.zon");
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.message, ".png") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.message, ".svg") != null);
}

test "validate reports an unreadable icon source naming the accepted forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-validate-icon-bad";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/assets/icon.png", .data = "this is not a png" });
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/app.zon", .data =
        \\.{
        \\  .id = "dev.example.app",
        \\  .name = "demo",
        \\  .version = "1.0.0",
        \\  .icons = .{"assets/icon.png"},
        \\}
    });

    const result = try validateFile(gpa, std.testing.io, root ++ "/app.zon");
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.message, "could not be read") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.message, ".png") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.message, ".svg") != null);
}

test "validate accepts a square icon source and prebuilt containers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-validate-icon-ok";
    try cwd.deleteTree(std.testing.io, root);
    defer cwd.deleteTree(std.testing.io, root) catch {};
    try cwd.createDirPath(std.testing.io, root ++ "/assets");

    const pixels = try gpa.alloc(u8, 600 * 600 * 4);
    @memset(pixels, 128);
    const encoded = try app_icon_tool.encodePng(gpa, pixels, 600, 600);
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/assets/icon.png", .data = encoded });
    try cwd.writeFile(std.testing.io, .{ .sub_path = root ++ "/app.zon", .data =
        \\.{
        \\  .id = "dev.example.app",
        \\  .name = "demo",
        \\  .version = "1.0.0",
        \\  .icons = .{ "assets/icon.png", "assets/prebuilt.icns", "assets/prebuilt.ico" },
        \\}
    });

    const result = try validateFile(gpa, std.testing.io, root ++ "/app.zon");
    try std.testing.expect(result.ok);
}

test "manifest validates the theme pack name" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.0.0",
        \\  .theme = "geist",
        \\}
    );
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("geist", metadata.theme.?);
    // The known-pack check is the tooling half of the contract; the
    // runner re-validates the same names at comptime in the app build.
    try std.testing.expect(isKnownThemePack("house"));
    try std.testing.expect(isKnownThemePack("geist"));
    try std.testing.expect(!isKnownThemePack("neon"));
}
