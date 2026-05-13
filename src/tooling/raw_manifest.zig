const web_engine = @import("web_engine.zig");

pub const RawManifest = struct {
    id: []const u8,
    name: []const u8,
    display_name: ?[]const u8 = null,
    version: []const u8,
    icons: []const []const u8 = &.{},
    platforms: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},
    capabilities: []const []const u8 = &.{},
    bridge: RawBridge = .{},
    web_engine: []const u8 = @tagName(web_engine.default_engine),
    cef: RawCef = .{},
    frontend: ?RawFrontend = null,
    security: RawSecurity = .{},
    windows: []const RawWindow = &.{},
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
    restore_state: bool = true,
    frameless: bool = false,
    transparent: bool = false,
    always_on_top: bool = false,
};
