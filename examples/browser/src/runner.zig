const std = @import("std");
const build_options = @import("build_options");
const zero_native = @import("zero-native");
const app_manifest = @import("app_manifest_zon");
const manifest_shortcuts = if (@hasField(@TypeOf(app_manifest), "shortcuts")) app_manifest.shortcuts else .{};
const manifest_windows = if (@hasField(@TypeOf(app_manifest), "windows")) app_manifest.windows else .{};

pub const RunOptions = struct {
    app_name: []const u8,
    window_title: []const u8 = "",
    bundle_id: []const u8,
    icon_path: []const u8 = "assets/icon.icns",
    bridge: ?zero_native.BridgeDispatcher = null,
    builtin_bridge: zero_native.BridgePolicy = .{},
    security: zero_native.SecurityPolicy = .{},
    shortcuts: ?[]const zero_native.Shortcut = null,

    fn appInfo(self: RunOptions, buffers: *StateBuffers) zero_native.AppInfo {
        var info: zero_native.AppInfo = .{
            .app_name = self.app_name,
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

    fn resolvedShortcuts(self: RunOptions, storage: *ShortcutStorage) []const zero_native.Shortcut {
        return self.shortcuts orelse storage.fromManifest();
    }
};

const ShortcutStorage = struct {
    shortcuts: [zero_native.platform.max_shortcuts]zero_native.Shortcut = undefined,

    fn fromManifest(self: *ShortcutStorage) []const zero_native.Shortcut {
        comptime {
            if (manifest_shortcuts.len > zero_native.platform.max_shortcuts) {
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
    restored_windows: [zero_native.platform.max_windows]zero_native.WindowOptions = undefined,
};

fn manifestWindowOptions(buffers: *StateBuffers) []const zero_native.WindowOptions {
    comptime {
        if (manifest_windows.len > zero_native.platform.max_windows) {
            @compileError("app.zon defines too many windows");
        }
    }

    inline for (manifest_windows, 0..) |window, index| {
        buffers.restored_windows[index] = manifestWindow(window, index);
    }
    return buffers.restored_windows[0..manifest_windows.len];
}

fn manifestWindow(comptime window: anytype, comptime index: usize) zero_native.WindowOptions {
    return .{
        .id = index + 1,
        .label = windowLabel(window, index),
        .title = windowTitle(window),
        .default_frame = zero_native.geometry.RectF.init(
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

fn windowRestorePolicy(comptime window: anytype) zero_native.WindowRestorePolicy {
    if (comptime !@hasField(@TypeOf(window), "restore_policy")) return .clamp_to_visible_screen;
    const value = window.restore_policy;
    if (comptime std.mem.eql(u8, value, "clamp_to_visible_screen")) return .clamp_to_visible_screen;
    if (comptime std.mem.eql(u8, value, "center_on_primary")) return .center_on_primary;
    @compileError("unknown app.zon window restore_policy");
}

fn shortcutModifiers(comptime shortcut: anytype) zero_native.ShortcutModifiers {
    const values = if (@hasField(@TypeOf(shortcut), "modifiers")) shortcut.modifiers else .{};
    var modifiers: zero_native.ShortcutModifiers = .{};
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

pub fn runWithOptions(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
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

fn runNull(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    var null_platform = zero_native.NullPlatform.initWithOptions(.{}, webEngine(), app_info);
    try runRuntime(app, options, init, null_platform.platform());
}

fn runMacos(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    var mac_platform = try zero_native.platform.macos.MacPlatform.initWithOptions(zero_native.geometry.SizeF.init(1120, 780), webEngine(), app_info);
    defer mac_platform.deinit();
    try runRuntime(app, options, init, mac_platform.platform());
}

fn runLinux(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    var linux_platform = try zero_native.platform.linux.LinuxPlatform.initWithOptions(zero_native.geometry.SizeF.init(960, 720), webEngine(), app_info);
    defer linux_platform.deinit();
    try runRuntime(app, options, init, linux_platform.platform());
}

fn runWindows(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    var windows_platform = try zero_native.platform.windows.WindowsPlatform.initWithOptions(zero_native.geometry.SizeF.init(960, 720), webEngine(), app_info);
    defer windows_platform.deinit();
    try runRuntime(app, options, init, windows_platform.platform());
}

fn runRuntime(app: zero_native.App, options: RunOptions, init: std.process.Init, platform: zero_native.Platform) !void {
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    var runtime = zero_native.Runtime.init(.{
        .platform = platform,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .security = options.security,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) zero_native.automation.Server.init(init.io, ".zig-cache/zero-native-automation", options.window_title) else null,
    });
    try runtime.run(app);
}

fn webEngine() zero_native.WebEngine {
    if (comptime std.mem.eql(u8, build_options.web_engine, "chromium")) return .chromium;
    return .system;
}
