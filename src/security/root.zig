const std = @import("std");

pub const permission_window = "window";
pub const permission_filesystem = "filesystem";
pub const permission_clipboard = "clipboard";
pub const permission_network = "network";
pub const permission_global_shortcut = "globalShortcut";

pub const ExternalLinkAction = enum(c_int) {
    deny = 0,
    open_system_browser = 1,
};

pub const ExternalLinkPolicy = struct {
    action: ExternalLinkAction = .deny,
    allowed_urls: []const []const u8 = &.{},
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

test "permission checks require every requested grant" {
    try std.testing.expect(hasPermissions(&.{ permission_window, permission_filesystem }, &.{permission_window}));
    try std.testing.expect(!hasPermissions(&.{permission_window}, &.{ permission_window, permission_filesystem }));
}

test "origin checks support exact origins and wildcard" {
    try std.testing.expect(allowsOrigin(&.{ "zero://app", "zero://inline" }, "zero://inline"));
    try std.testing.expect(allowsOrigin(&.{"*"}, "https://example.invalid"));
    try std.testing.expect(!allowsOrigin(&.{"zero://app"}, "https://example.invalid"));
}
