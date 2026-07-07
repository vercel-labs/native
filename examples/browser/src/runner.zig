const std = @import("std");
const build_options = @import("build_options");
const native_sdk = @import("native_sdk");
const app_manifest = @import("app_manifest_zon");
const manifest_shortcuts = if (@hasField(@TypeOf(app_manifest), "shortcuts")) app_manifest.shortcuts else .{};
const manifest_windows = if (@hasField(@TypeOf(app_manifest), "windows")) app_manifest.windows else .{};

pub const RunOptions = struct {
    app_name: []const u8,
    window_title: []const u8 = "",
    bundle_id: []const u8,
    icon_path: []const u8 = "assets/icon.png",
    bridge: ?native_sdk.BridgeDispatcher = null,
    builtin_bridge: native_sdk.BridgePolicy = .{},
    security: native_sdk.SecurityPolicy = .{},
    shortcuts: ?[]const native_sdk.Shortcut = null,

    fn appInfo(self: RunOptions, buffers: *StateBuffers) native_sdk.AppInfo {
        var info: native_sdk.AppInfo = .{
            .app_name = self.app_name,
            // The identity the OS shows (application menu, Dock, About
            // panel) reads straight from app.zon at comptime, so dev
            // runs carry the same display name and version a packaged
            // bundle gets from its Info.plist.
            .display_name = manifestStringField("display_name"),
            .version = manifestStringField("version"),
            .description = manifestStringField("description"),
            .has_web_content = manifestHasWebContent(),
            .window_title = self.window_title,
            .bundle_id = self.bundle_id,
            .icon_path = self.icon_path,
        };
        const windows = manifestWindowOptions(buffers);
        if (windows.len > 0) {
            info.main_window = windows[0];
            info.windows = windows;
        }
        return info;
    }

    fn resolvedShortcuts(self: RunOptions, storage: *ShortcutStorage) []const native_sdk.Shortcut {
        return self.shortcuts orelse storage.fromManifest();
    }
};

const ShortcutStorage = struct {
    shortcuts: [native_sdk.platform.max_shortcuts]native_sdk.Shortcut = undefined,

    fn fromManifest(self: *ShortcutStorage) []const native_sdk.Shortcut {
        comptime {
            if (manifest_shortcuts.len > native_sdk.platform.max_shortcuts) {
                @compileError("app.zon defines too many shortcuts");
            }
        }

        inline for (manifest_shortcuts, 0..) |shortcut, index| {
            self.shortcuts[index] = .{
                .id = shortcut.id,
                .key = shortcut.key,
                .modifiers = shortcutModifiers(shortcut),
            };
        }
        return self.shortcuts[0..manifest_shortcuts.len];
    }
};

const StateBuffers = struct {
    restored_windows: [native_sdk.platform.max_windows]native_sdk.WindowOptions = undefined,
};

/// A top-level app.zon string field (`display_name`, `version`,
/// `description`), or "" when the manifest omits it — optional identity
/// stays optional all the way into `AppInfo`.
fn manifestStringField(comptime field: []const u8) []const u8 {
    if (comptime !@hasField(@TypeOf(app_manifest), field)) return "";
    const value = @field(app_manifest, field);
    if (comptime @TypeOf(value) == @TypeOf(null)) return "";
    return value;
}

/// Whether app.zon declares web content: the `webview` capability or a
/// `frontend` block. Hosts build honest default menus from this — web
/// items like Reload only exist when a webview can answer them, so
/// canvas-only apps never ship dead menu items.
fn manifestHasWebContent() bool {
    if (comptime @hasField(@TypeOf(app_manifest), "frontend")) return true;
    if (comptime !@hasField(@TypeOf(app_manifest), "capabilities")) return false;
    inline for (app_manifest.capabilities) |capability| {
        if (comptime std.mem.eql(u8, capability, "webview")) return true;
    }
    return false;
}

fn manifestWindowOptions(buffers: *StateBuffers) []const native_sdk.WindowOptions {
    comptime {
        if (manifest_windows.len > native_sdk.platform.max_windows) {
            @compileError("app.zon defines too many windows");
        }
    }

    inline for (manifest_windows, 0..) |window, index| {
        buffers.restored_windows[index] = manifestWindow(window, index);
    }
    return buffers.restored_windows[0..manifest_windows.len];
}

fn manifestWindow(comptime window: anytype, comptime index: usize) native_sdk.WindowOptions {
    return .{
        .id = index + 1,
        .label = windowLabel(window, index),
        .title = windowTitle(window),
        .default_frame = native_sdk.geometry.RectF.init(
            windowFloat(window, "x", 0),
            windowFloat(window, "y", 0),
            windowFloat(window, "width", 720),
            windowFloat(window, "height", 480),
        ),
        .resizable = windowBool(window, "resizable", true),
        .restore_state = windowBool(window, "restore_state", true),
        .restore_policy = windowRestorePolicy(window),
    };
}

fn windowLabel(comptime window: anytype, comptime index: usize) []const u8 {
    if (comptime @hasField(@TypeOf(window), "label")) return window.label;
    return if (index == 0) "main" else "window";
}

fn windowTitle(comptime window: anytype) []const u8 {
    if (comptime !@hasField(@TypeOf(window), "title")) return "";
    const title = window.title;
    if (comptime @TypeOf(title) == @TypeOf(null)) return "";
    return title;
}

fn windowFloat(comptime window: anytype, comptime field: []const u8, comptime default_value: f32) f32 {
    if (comptime @hasField(@TypeOf(window), field)) return @field(window, field);
    return default_value;
}

fn windowBool(comptime window: anytype, comptime field: []const u8, comptime default_value: bool) bool {
    if (comptime @hasField(@TypeOf(window), field)) return @field(window, field);
    return default_value;
}

fn windowRestorePolicy(comptime window: anytype) native_sdk.WindowRestorePolicy {
    if (comptime !@hasField(@TypeOf(window), "restore_policy")) return .clamp_to_visible_screen;
    const value = window.restore_policy;
    if (comptime std.mem.eql(u8, value, "clamp_to_visible_screen")) return .clamp_to_visible_screen;
    if (comptime std.mem.eql(u8, value, "center_on_primary")) return .center_on_primary;
    @compileError("unknown app.zon window restore_policy");
}

fn shortcutModifiers(comptime shortcut: anytype) native_sdk.ShortcutModifiers {
    const values = if (@hasField(@TypeOf(shortcut), "modifiers")) shortcut.modifiers else .{};
    var modifiers: native_sdk.ShortcutModifiers = .{};
    inline for (values) |value| {
        const modifier: []const u8 = value;
        if (comptime std.mem.eql(u8, modifier, "primary")) {
            modifiers.primary = true;
        } else if (comptime std.mem.eql(u8, modifier, "command")) {
            modifiers.command = true;
        } else if (comptime std.mem.eql(u8, modifier, "control")) {
            modifiers.control = true;
        } else if (comptime std.mem.eql(u8, modifier, "option") or std.mem.eql(u8, modifier, "alt")) {
            modifiers.option = true;
        } else if (comptime std.mem.eql(u8, modifier, "shift")) {
            modifiers.shift = true;
        } else {
            @compileError("unknown app.zon shortcut modifier");
        }
    }
    return modifiers;
}

pub fn runWithOptions(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
        try runMacos(app, options, init);
    } else if (comptime std.mem.eql(u8, build_options.platform, "linux")) {
        try runLinux(app, options, init);
    } else if (comptime std.mem.eql(u8, build_options.platform, "windows")) {
        try runWindows(app, options, init);
    } else {
        try runNull(app, options, init);
    }
}

fn runNull(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    var null_platform = native_sdk.NullPlatform.initWithOptions(.{}, webEngine(), app_info);
    try runRuntime(app, options, init, null_platform.platform());
}

fn runMacos(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    var mac_platform = try native_sdk.platform.macos.MacPlatform.initWithOptions(native_sdk.geometry.SizeF.init(1120, 780), webEngine(), app_info);
    defer mac_platform.deinit();
    try runRuntime(app, options, init, mac_platform.platform());
}

fn runLinux(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    var linux_platform = try native_sdk.platform.linux.LinuxPlatform.initWithOptions(native_sdk.geometry.SizeF.init(960, 720), webEngine(), app_info);
    defer linux_platform.deinit();
    try runRuntime(app, options, init, linux_platform.platform());
}

fn runWindows(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    var windows_platform = try native_sdk.platform.windows.WindowsPlatform.initWithOptions(native_sdk.geometry.SizeF.init(960, 720), webEngine(), app_info);
    defer windows_platform.deinit();
    try runRuntime(app, options, init, windows_platform.platform());
}

fn runRuntime(app: native_sdk.App, options: RunOptions, init: std.process.Init, platform: native_sdk.Platform) !void {
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    // The Runtime is tens of megabytes; construct on the heap (default
    // main-thread stacks overflow on a stack instance).
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    native_sdk.Runtime.initAt(runtime, .{
        .platform = platform,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .security = options.security,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", options.window_title) else null,
    });
    try runtime.run(app);
}

fn webEngine() native_sdk.WebEngine {
    if (comptime std.mem.eql(u8, build_options.web_engine, "chromium")) return .chromium;
    return .system;
}
