const std = @import("std");

pub const permission_window = "window";
pub const permission_command = "command";
pub const permission_view = "view";
pub const permission_dialog = "dialog";
pub const permission_filesystem = "filesystem";
pub const permission_clipboard = "clipboard";
pub const permission_network = "network";
pub const permission_notifications = "notifications";
pub const permission_credentials = "credentials";

pub const ExternalLinkAction = enum(c_int) {
    deny = 0,
    open_system_browser = 1,
};

pub const ExternalLinkPolicy = struct {
    action: ExternalLinkAction = .deny,
    allowed_urls: []const []const u8 = &.{},
};

/// A configuration that current external-link matching intentionally treats
/// literally. This is advisory only: callers keep the configured policy and
/// the matcher keeps its exact/prefix semantics.
pub const ExternalUrlPatternDiagnostic = enum {
    unsupported_host_wildcard,
    invalid_wildcard_prefix,
};

pub const NavigationPolicy = struct {
    allowed_origins: []const []const u8 = &.{ "zero://app", "zero://inline" },
    external_links: ExternalLinkPolicy = .{},
};

pub const Policy = struct {
    permissions: []const []const u8 = &.{},
    navigation: NavigationPolicy = .{},
};

pub fn hasPermission(grants: []const []const u8, permission: []const u8) bool {
    for (grants) |grant| {
        if (std.mem.eql(u8, grant, permission)) return true;
    }
    return false;
}

pub fn hasPermissions(grants: []const []const u8, required: []const []const u8) bool {
    for (required) |permission| {
        if (!hasPermission(grants, permission)) return false;
    }
    return true;
}

pub fn allowsOrigin(allowed_origins: []const []const u8, origin: []const u8) bool {
    for (allowed_origins) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) return true;
        if (std.mem.eql(u8, allowed, origin)) return true;
    }
    return false;
}

pub fn allowsExternalUrl(policy: ExternalLinkPolicy, url: []const u8) bool {
    if (policy.action != .open_system_browser) return false;
    for (policy.allowed_urls) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) return true;
        if (std.mem.eql(u8, allowed, url)) return true;
        if (externalWildcardPrefixValid(allowed)) {
            const prefix = allowed[0 .. allowed.len - 1];
            if (std.mem.startsWith(u8, url, prefix)) return true;
        }
    }
    return false;
}

/// Return an actionable diagnostic for an external-link pattern that the
/// matcher cannot expand as an author likely intended. Asterisks outside the
/// host are deliberately left alone: exact matches and final prefix wildcards
/// can use them as literal URL data.
pub fn externalUrlPatternDiagnostic(pattern: []const u8) ?ExternalUrlPatternDiagnostic {
    if (std.mem.eql(u8, pattern, "*")) return null;
    if (std.mem.endsWith(u8, pattern, "*") and !externalWildcardPrefixValid(pattern)) {
        return .invalid_wildcard_prefix;
    }
    if (externalUrlHostContainsWildcard(pattern)) return .unsupported_host_wildcard;
    return null;
}

fn externalWildcardPrefixValid(pattern: []const u8) bool {
    if (!std.mem.endsWith(u8, pattern, "*")) return false;
    const prefix = pattern[0 .. pattern.len - 1];
    const scheme = if (std.mem.startsWith(u8, prefix, "https://"))
        "https://"
    else if (std.mem.startsWith(u8, prefix, "http://"))
        "http://"
    else
        return false;
    const rest = prefix[scheme.len..];
    const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    return slash_index > 0;
}

/// Scan just the URL host, not user information, path, query, or fragment.
/// This is intentionally a small structural scan rather than a URL parser: it
/// mirrors the prefix boundary the security matcher already recognizes and
/// never allocates on the startup path.
fn externalUrlHostContainsWildcard(pattern: []const u8) bool {
    const scheme_len: usize = if (std.mem.startsWith(u8, pattern, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, pattern, "http://"))
        "http://".len
    else
        return false;
    const after_scheme = pattern[scheme_len..];
    const authority_end = std.mem.indexOfAny(u8, after_scheme, "/?#") orelse after_scheme.len;
    const authority = after_scheme[0..authority_end];
    const host_and_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
        authority[at + 1 ..]
    else
        authority;
    const host = if (std.mem.startsWith(u8, host_and_port, "[")) block: {
        const closing_bracket = std.mem.indexOfScalar(u8, host_and_port, ']') orelse break :block host_and_port;
        break :block host_and_port[0 .. closing_bracket + 1];
    } else if (std.mem.indexOfScalar(u8, host_and_port, ':')) |port_start|
        host_and_port[0..port_start]
    else
        host_and_port;
    return std.mem.indexOfScalar(u8, host, '*') != null;
}

test "permission checks require every requested grant" {
    try std.testing.expect(hasPermissions(&.{ permission_window, permission_filesystem }, &.{permission_window}));
    try std.testing.expect(!hasPermissions(&.{permission_window}, &.{ permission_window, permission_filesystem }));
}

test "origin checks support exact origins and wildcard" {
    try std.testing.expect(allowsOrigin(&.{ "zero://app", "zero://inline" }, "zero://inline"));
    try std.testing.expect(allowsOrigin(&.{"*"}, "https://example.invalid"));
    try std.testing.expect(!allowsOrigin(&.{"zero://app"}, "https://example.invalid"));
}

test "external URL checks require open-browser action and allowed URL pattern" {
    try std.testing.expect(!allowsExternalUrl(.{
        .action = .deny,
        .allowed_urls = &.{"https://example.com/*"},
    }, "https://example.com/docs"));
    try std.testing.expect(allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"https://example.com/*"},
    }, "https://example.com/docs"));
    try std.testing.expect(allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"https://example.com/docs"},
    }, "https://example.com/docs"));
    try std.testing.expect(!allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"https://example.com/*"},
    }, "https://other.example/docs"));
    try std.testing.expect(!allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"https://example.com/*"},
    }, "https://example.com.evil/docs"));
    try std.testing.expect(!allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"https://example.com*"},
    }, "https://example.com.evil/docs"));

    try std.testing.expect(allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"http://example.com/docs/*"},
    }, "http://example.com/docs/guide"));
    try std.testing.expect(allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"https://example.com/docs"},
    }, "https://example.com/docs"));
    try std.testing.expect(!allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"https://example.com/docs/*"},
    }, "https://example.com/blog/guide"));
    try std.testing.expect(!allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"https://example.com/docs/*"},
    }, "http://example.com/docs/guide"));
    try std.testing.expect(allowsExternalUrl(.{
        .action = .open_system_browser,
        .allowed_urls = &.{"*"},
    }, "https://any.example/docs"));
}

test "external URL pattern diagnostics identify unsupported host wildcards only" {
    try std.testing.expectEqual(
        ExternalUrlPatternDiagnostic.unsupported_host_wildcard,
        externalUrlPatternDiagnostic("https://*.example.com/*").?,
    );
    try std.testing.expectEqual(
        ExternalUrlPatternDiagnostic.unsupported_host_wildcard,
        externalUrlPatternDiagnostic("https://*/*").?,
    );
    try std.testing.expectEqual(
        ExternalUrlPatternDiagnostic.unsupported_host_wildcard,
        externalUrlPatternDiagnostic("https://*/").?,
    );
    try std.testing.expectEqual(
        ExternalUrlPatternDiagnostic.invalid_wildcard_prefix,
        externalUrlPatternDiagnostic("https://example.com*").?,
    );
    try std.testing.expect(externalUrlPatternDiagnostic("*") == null);
    try std.testing.expect(externalUrlPatternDiagnostic("https://example.com/docs/*") == null);
    try std.testing.expect(externalUrlPatternDiagnostic("https://user*@example.com/docs") == null);
    try std.testing.expect(externalUrlPatternDiagnostic("https://example.com/docs/*/guide") == null);
    try std.testing.expect(externalUrlPatternDiagnostic("https://example.com/docs?tag=*&page=1") == null);
    try std.testing.expect(externalUrlPatternDiagnostic("https://example.com/docs#part*two") == null);

    const host_wildcard_policy: ExternalLinkPolicy = .{
        .action = .open_system_browser,
        .allowed_urls = &.{ "https://*.example.com/*", "https://*/*", "https://*/" },
    };
    try std.testing.expect(!allowsExternalUrl(host_wildcard_policy, "https://example.com/docs"));
    try std.testing.expect(!allowsExternalUrl(host_wildcard_policy, "https://docs.example.com/guide"));
    try std.testing.expect(!allowsExternalUrl(host_wildcard_policy, "https://other.example/guide"));
}
