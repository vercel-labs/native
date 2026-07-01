const std = @import("std");
const types = @import("types.zig");

const ValidationError = types.ValidationError;
const max_shortcuts = types.max_shortcuts;
const max_shortcut_id_bytes = types.max_shortcut_id_bytes;
const max_shortcut_key_bytes = types.max_shortcut_key_bytes;
const max_shell_windows = types.max_shell_windows;
const max_shell_views_per_window = types.max_shell_views_per_window;
const max_view_label_bytes = types.max_view_label_bytes;
const max_view_role_bytes = types.max_view_role_bytes;
const max_view_accessibility_label_bytes = types.max_view_accessibility_label_bytes;
const max_command_id_bytes = types.max_command_id_bytes;
const max_commands = types.max_commands;
const max_command_title_bytes = types.max_command_title_bytes;
const max_menus = types.max_menus;
const max_menu_items = types.max_menu_items;
const max_menu_title_bytes = types.max_menu_title_bytes;
const max_menu_item_label_bytes = types.max_menu_item_label_bytes;
const max_menu_key_bytes = types.max_menu_key_bytes;
const max_file_associations = types.max_file_associations;
const max_file_association_extensions = types.max_file_association_extensions;
const max_file_association_mime_types = types.max_file_association_mime_types;
const max_url_schemes = types.max_url_schemes;
const Platform = types.Platform;
const PackageKind = types.PackageKind;
const WebEngine = types.WebEngine;
const CefConfig = types.CefConfig;
const IconPurpose = types.IconPurpose;
const PermissionKind = types.PermissionKind;
const Permission = types.Permission;
const CapabilityKind = types.CapabilityKind;
const Capability = types.Capability;
const AppIdentity = types.AppIdentity;
const Version = types.Version;
const Icon = types.Icon;
const PlatformSettings = types.PlatformSettings;
const BridgeCommand = types.BridgeCommand;
const BridgeConfig = types.BridgeConfig;
const ExternalLinkAction = types.ExternalLinkAction;
const ExternalLinkPolicy = types.ExternalLinkPolicy;
const NavigationPolicy = types.NavigationPolicy;
const SecurityConfig = types.SecurityConfig;
const FrontendDevConfig = types.FrontendDevConfig;
const FrontendConfig = types.FrontendConfig;
const WindowRestorePolicy = types.WindowRestorePolicy;
const Window = types.Window;
const ViewKind = types.ViewKind;
const GpuSurfaceBackend = types.GpuSurfaceBackend;
const GpuSurfacePixelFormat = types.GpuSurfacePixelFormat;
const GpuSurfacePresentMode = types.GpuSurfacePresentMode;
const GpuSurfaceAlphaMode = types.GpuSurfaceAlphaMode;
const GpuSurfaceColorSpace = types.GpuSurfaceColorSpace;
const ShellEdge = types.ShellEdge;
const ShellAxis = types.ShellAxis;
const ShellView = types.ShellView;
const ShellWindow = types.ShellWindow;
const ShellConfig = types.ShellConfig;
const ShortcutModifiers = types.ShortcutModifiers;
const Shortcut = types.Shortcut;
const Command = types.Command;
const Menu = types.Menu;
const MenuItem = types.MenuItem;
const AssociationRole = types.AssociationRole;
const FileAssociation = types.FileAssociation;
const UrlScheme = types.UrlScheme;
const PackageMetadata = types.PackageMetadata;
const UpdateConfig = types.UpdateConfig;
const Manifest = types.Manifest;
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
        if (view.url) |url| {
            if (view.kind != .webview) return error.InvalidUrl;
            try validateViewUrl(url);
        } else if (view.kind == .webview) {
            return error.MissingRequiredField;
        }
        if (view.kind != .gpu_surface and view.hasGpuSurfaceOptions()) return error.InvalidViewKind;
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
        try validateExternalWildcardPrefix(prefix);
        return;
    }
    return validateUrl(url);
}

fn validateExternalWildcardPrefix(prefix: []const u8) ValidationError!void {
    const prefix_len: usize = if (std.mem.startsWith(u8, prefix, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, prefix, "http://"))
        "http://".len
    else
        return error.InvalidUrl;

    const rest = prefix[prefix_len..];
    const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUrl;
    if (slash_index == 0) return error.InvalidUrl;
    const host = rest[0..slash_index];
    for (host) |ch| {
        if (ch == 0 or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') return error.InvalidUrl;
    }
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
