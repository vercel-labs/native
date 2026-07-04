const std = @import("std");
const runtime = @import("../runtime/root.zig");
const platform = @import("../platform/root.zig");

const max_mobile_command_name_bytes: usize = 128;
const max_mobile_asset_root_bytes: usize = platform.max_webview_url_bytes;
const max_mobile_asset_entry_bytes: usize = platform.max_window_source_bytes;

pub const EmbeddedApp = struct {
    app: runtime.App,
    runtime: runtime.Runtime,

    pub fn init(app: runtime.App, platform_value: platform.Platform) EmbeddedApp {
        return .{
            .app = app,
            .runtime = runtime.Runtime.init(.{ .platform = platform_value }),
        };
    }

    pub fn start(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_start);
    }

    pub fn activate(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_activated);
    }

    pub fn deactivate(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_deactivated);
    }

    pub fn resize(self: *EmbeddedApp, surface: platform.Surface) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .surface_resized = surface });
    }

    pub fn frame(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .frame_requested);
    }

    pub fn command(self: *EmbeddedApp, name: []const u8) anyerror!void {
        try self.runtime.dispatchCommand(self.app, .{
            .name = name,
            .source = .native_view,
            .window_id = 1,
            .view_label = "mobile-header",
        });
    }

    pub fn stop(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_shutdown);
    }
};

const MobileHostApp = struct {
    null_platform: platform.NullPlatform,
    embedded: EmbeddedApp,
    last_error: ?anyerror = null,
    activation_count: usize = 0,
    deactivation_count: usize = 0,
    command_count: usize = 0,
    asset_root: [max_mobile_asset_root_bytes]u8 = undefined,
    asset_root_len: usize = 0,
    asset_entry: [max_mobile_asset_entry_bytes]u8 = undefined,
    asset_entry_len: usize = 0,
    last_command_name: [max_mobile_command_name_bytes + 1]u8 = [_]u8{0} ** (max_mobile_command_name_bytes + 1),

    fn create() !*MobileHostApp {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(MobileHostApp);
        self.null_platform = platform.NullPlatform.init(.{});
        self.last_error = null;
        self.activation_count = 0;
        self.deactivation_count = 0;
        self.command_count = 0;
        self.asset_root = undefined;
        self.asset_root_len = 0;
        self.asset_entry = undefined;
        self.asset_entry_len = 0;
        self.last_command_name = [_]u8{0} ** (max_mobile_command_name_bytes + 1);
        self.embedded = EmbeddedApp.init(.{
            .context = self,
            .name = "zero-native-mobile",
            .source_fn = mobileSource,
            .event_fn = handleEvent,
        }, self.null_platform.platform());
        return self;
    }

    fn source(self: *MobileHostApp) platform.WebViewSource {
        if (self.asset_root_len > 0) {
            return platform.WebViewSource.assets(.{
                .root_path = self.asset_root[0..self.asset_root_len],
                .entry = if (self.asset_entry_len > 0) self.asset_entry[0..self.asset_entry_len] else "index.html",
                .origin = "zero://app",
                .spa_fallback = true,
            });
        }
        return platform.WebViewSource.html(mobile_html);
    }

    fn handleEvent(context: *anyopaque, runtime_value: *runtime.Runtime, event: runtime.Event) anyerror!void {
        _ = runtime_value;
        const self: *MobileHostApp = @ptrCast(@alignCast(context));
        switch (event) {
            .lifecycle => |lifecycle| switch (lifecycle) {
                .activate => self.activation_count += 1,
                .deactivate => self.deactivation_count += 1,
                else => {},
            },
            .command => |command_event| {
                self.command_count += 1;
                const count = @min(command_event.name.len, max_mobile_command_name_bytes);
                @memcpy(self.last_command_name[0..count], command_event.name[0..count]);
                self.last_command_name[count] = 0;
            },
            else => {},
        }
    }
};

fn mobileSource(context: *anyopaque) anyerror!platform.WebViewSource {
    const self: *MobileHostApp = @ptrCast(@alignCast(context));
    return self.source();
}

const mobile_html =
    \\<!doctype html>
    \\<html>
    \\<body style="font-family: system-ui; padding: 2rem;">
    \\  <h1>zero-native mobile</h1>
    \\  <p>This content is loaded through the zero-native embedded C ABI.</p>
    \\</body>
    \\</html>
;

fn mobileApp(raw: ?*anyopaque) ?*MobileHostApp {
    const pointer = raw orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn recordError(self: *MobileHostApp, err: anyerror) void {
    self.last_error = err;
}

pub fn zero_native_app_create() ?*anyopaque {
    const self = MobileHostApp.create() catch return null;
    return self;
}

pub fn zero_native_app_destroy(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    std.heap.c_allocator.destroy(self);
}

pub fn zero_native_app_start(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.start() catch |err| recordError(self, err);
}

pub fn zero_native_app_activate(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.activate() catch |err| recordError(self, err);
}

pub fn zero_native_app_deactivate(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.deactivate() catch |err| recordError(self, err);
}

pub fn zero_native_app_stop(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.stop() catch |err| recordError(self, err);
}

pub fn zero_native_app_resize(app: ?*anyopaque, width: f32, height: f32, scale: f32, surface: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.resize(.{
        .size = .{ .width = width, .height = height },
        .scale_factor = scale,
        .native_handle = surface,
    }) catch |err| recordError(self, err);
}

pub fn zero_native_app_touch(app: ?*anyopaque, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) void {
    _ = app;
    _ = id;
    _ = phase;
    _ = x;
    _ = y;
    _ = pressure;
}

pub fn zero_native_app_command(app: ?*anyopaque, name: ?[*]const u8, len: usize) void {
    const self = mobileApp(app) orelse return;
    const ptr = name orelse {
        recordError(self, error.InvalidCommand);
        return;
    };
    self.embedded.command(ptr[0..len]) catch |err| {
        recordError(self, err);
        return;
    };
    self.last_error = null;
}

pub fn zero_native_app_frame(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.frame() catch |err| recordError(self, err);
}

pub fn zero_native_app_set_asset_root(app: ?*anyopaque, path: [*]const u8, len: usize) void {
    const self = mobileApp(app) orelse return;
    if (len > self.asset_root.len) {
        recordError(self, error.WindowSourceTooLarge);
        return;
    }
    if (len == 0) {
        self.asset_root_len = 0;
        self.last_error = null;
        return;
    }
    @memcpy(self.asset_root[0..len], path[0..len]);
    self.asset_root_len = len;
    self.last_error = null;
}

pub fn zero_native_app_set_asset_entry(app: ?*anyopaque, path: [*]const u8, len: usize) void {
    const self = mobileApp(app) orelse return;
    if (len > self.asset_entry.len) {
        recordError(self, error.WindowSourceTooLarge);
        return;
    }
    if (len == 0) {
        self.asset_entry_len = 0;
        self.last_error = null;
        return;
    }
    @memcpy(self.asset_entry[0..len], path[0..len]);
    self.asset_entry_len = len;
    self.last_error = null;
}

pub fn zero_native_app_last_command_count(app: ?*anyopaque) usize {
    const self = mobileApp(app) orelse return 0;
    return self.command_count;
}

pub fn zero_native_app_last_command_name(app: ?*anyopaque) [*:0]const u8 {
    const self = mobileApp(app) orelse return "";
    return @ptrCast(&self.last_command_name);
}

pub fn zero_native_app_last_error_name(app: ?*anyopaque) [*:0]const u8 {
    const self = mobileApp(app) orelse return "";
    const err = self.last_error orelse return "";
    return @errorName(err);
}

test "embedded app starts and loads source" {
    var null_platform = platform.NullPlatform.init(.{});
    var state: u8 = 0;
    var embedded = EmbeddedApp.init(.{
        .context = &state,
        .name = "embedded",
        .source = platform.WebViewSource.html("<p>Embedded</p>"),
    }, null_platform.platform());

    try embedded.start();
    try @import("std").testing.expectEqualStrings("<p>Embedded</p>", null_platform.loaded_source.?.bytes);
}

test "mobile C ABI can load packaged asset source" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const asset_root = "/tmp/zero-native-mobile-assets";
    zero_native_app_set_asset_root(app, asset_root, asset_root.len);
    zero_native_app_start(app);

    const self = mobileApp(app).?;
    const source = self.null_platform.loaded_source.?;
    try std.testing.expectEqual(platform.WebViewSourceKind.assets, source.kind);
    try std.testing.expectEqualStrings("zero://app", source.bytes);
    try std.testing.expect(source.asset_options != null);
    try std.testing.expectEqualStrings(asset_root, source.asset_options.?.root_path);
    try std.testing.expectEqualStrings("index.html", source.asset_options.?.entry);
    try std.testing.expect(source.asset_options.?.spa_fallback);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI can load custom packaged asset entry" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const asset_root = "/tmp/zero-native-mobile-assets";
    const asset_entry = "main.html";
    zero_native_app_set_asset_root(app, asset_root, asset_root.len);
    zero_native_app_set_asset_entry(app, asset_entry, asset_entry.len);
    zero_native_app_start(app);

    const self = mobileApp(app).?;
    const source = self.null_platform.loaded_source.?;
    try std.testing.expectEqual(platform.WebViewSourceKind.assets, source.kind);
    try std.testing.expect(source.asset_options != null);
    try std.testing.expectEqualStrings(asset_root, source.asset_options.?.root_path);
    try std.testing.expectEqualStrings(asset_entry, source.asset_options.?.entry);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI can reset asset root before startup" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const asset_root = "/tmp/zero-native-mobile-assets";
    zero_native_app_set_asset_root(app, asset_root, asset_root.len);
    zero_native_app_set_asset_root(app, asset_root, 0);
    zero_native_app_start(app);

    const self = mobileApp(app).?;
    const source = self.null_platform.loaded_source.?;
    try std.testing.expectEqual(platform.WebViewSourceKind.html, source.kind);
    try std.testing.expectEqualStrings(mobile_html, source.bytes);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI forwards activation lifecycle through embedded runtime" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    zero_native_app_start(app);
    zero_native_app_activate(app);
    zero_native_app_deactivate(app);

    const self = mobileApp(app).?;
    try std.testing.expectEqual(@as(usize, 1), self.activation_count);
    try std.testing.expectEqual(@as(usize, 1), self.deactivation_count);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI dispatches native commands through embedded runtime" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    zero_native_app_command(app, "mobile.refresh", "mobile.refresh".len);
    try std.testing.expectEqual(@as(usize, 1), zero_native_app_last_command_count(app));
    try std.testing.expectEqualStrings("mobile.refresh", std.mem.span(zero_native_app_last_command_name(app)));
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));

    zero_native_app_command(app, "", 0);
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));

    zero_native_app_command(app, "mobile.open", "mobile.open".len);
    try std.testing.expectEqual(@as(usize, 2), zero_native_app_last_command_count(app));
    try std.testing.expectEqualStrings("mobile.open", std.mem.span(zero_native_app_last_command_name(app)));
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}
