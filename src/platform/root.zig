const std = @import("std");
const geometry = @import("geometry");
const platform_info = @import("platform_info");
const security = @import("../security/root.zig");

pub const Error = error{
    UnsupportedService,
    WindowNotFound,
    WindowLimitReached,
    DuplicateWindowId,
    DuplicateWindowLabel,
    MissingWindowSource,
    WindowSourceTooLarge,
    FocusFailed,
    CloseFailed,
};

pub const WebEngine = enum {
    system,
    chromium,
};

pub const WebViewSourceKind = enum {
    html,
    url,
    assets,
};

pub const WebViewAssetSource = struct {
    root_path: []const u8,
    entry: []const u8 = "index.html",
    origin: []const u8 = "zero://app",
    spa_fallback: bool = true,
};

pub const WebViewSource = struct {
    kind: WebViewSourceKind,
    bytes: []const u8,
    asset_options: ?WebViewAssetSource = null,

    pub fn html(bytes: []const u8) WebViewSource {
        return .{ .kind = .html, .bytes = bytes };
    }

    pub fn url(bytes: []const u8) WebViewSource {
        return .{ .kind = .url, .bytes = bytes };
    }

    pub fn assets(options: WebViewAssetSource) WebViewSource {
        return .{ .kind = .assets, .bytes = options.origin, .asset_options = options };
    }
};

pub const WindowId = u64;
pub const max_windows: usize = 16;
pub const max_window_label_bytes: usize = 64;
pub const max_window_title_bytes: usize = 128;
pub const max_window_source_bytes: usize = 4096;

pub const WindowRestorePolicy = enum {
    clamp_to_visible_screen,
    center_on_primary,
};

pub const WindowOptions = struct {
    id: WindowId = 1,
    label: []const u8 = "main",
    title: []const u8 = "",
    default_frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    resizable: bool = true,
    restore_state: bool = true,
    restore_policy: WindowRestorePolicy = .clamp_to_visible_screen,

    pub fn resolvedTitle(self: WindowOptions, app_name: []const u8) []const u8 {
        return if (self.title.len > 0) self.title else app_name;
    }
};

pub const WindowState = struct {
    id: WindowId = 1,
    label: []const u8 = "main",
    title: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    scale_factor: f32 = 1,
    open: bool = true,
    focused: bool = true,
    maximized: bool = false,
    fullscreen: bool = false,
};

pub const WindowInfo = struct {
    id: WindowId = 1,
    label: []const u8 = "main",
    title: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    scale_factor: f32 = 1,
    open: bool = true,
    focused: bool = false,

    pub fn state(self: WindowInfo) WindowState {
        return .{
            .id = self.id,
            .label = self.label,
            .title = self.title,
            .frame = self.frame,
            .scale_factor = self.scale_factor,
            .open = self.open,
            .focused = self.focused,
        };
    }
};

pub const WindowCreateOptions = struct {
    id: WindowId = 0,
    label: []const u8 = "",
    title: []const u8 = "",
    default_frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    resizable: bool = true,
    restore_state: bool = true,
    restore_policy: WindowRestorePolicy = .clamp_to_visible_screen,
    source: ?WebViewSource = null,

    pub fn windowOptions(self: WindowCreateOptions, id: WindowId, label: []const u8) WindowOptions {
        return .{
            .id = id,
            .label = label,
            .title = self.title,
            .default_frame = self.default_frame,
            .resizable = self.resizable,
            .restore_state = self.restore_state,
            .restore_policy = self.restore_policy,
        };
    }
};

pub const AppInfo = struct {
    app_name: []const u8 = "zero-native",
    window_title: []const u8 = "",
    bundle_id: []const u8 = "dev.zero_native.app",
    icon_path: []const u8 = "",
    main_window: WindowOptions = .{},
    windows: []const WindowOptions = &.{},

    pub fn resolvedWindowTitle(self: AppInfo) []const u8 {
        if (self.window_title.len > 0) return self.window_title;
        return self.main_window.resolvedTitle(self.app_name);
    }

    pub fn resolvedMainWindow(self: AppInfo) WindowOptions {
        var window = self.main_window;
        if (window.title.len == 0) window.title = self.resolvedWindowTitle();
        return window;
    }

    pub fn startupWindowCount(self: AppInfo) usize {
        return if (self.windows.len > 0) self.windows.len else 1;
    }

    pub fn resolvedStartupWindow(self: AppInfo, index: usize) WindowOptions {
        var window = if (self.windows.len > 0) self.windows[index] else self.main_window;
        if (window.id == 0 or (self.windows.len > 0 and index > 0 and window.id == 1)) {
            window.id = @intCast(index + 1);
        }
        if (window.label.len == 0) window.label = if (index == 0) "main" else "window";
        if (window.title.len == 0) window.title = self.resolvedWindowTitle();
        return window;
    }
};

pub const Surface = struct {
    id: u64 = 1,
    size: geometry.SizeF = geometry.SizeF.init(640, 360),
    scale_factor: f32 = 1,
    native_handle: ?*anyopaque = null,
};

pub const BridgeMessage = struct {
    bytes: []const u8,
    origin: []const u8 = "",
    window_id: WindowId = 1,
};

pub const max_dialog_path_bytes: usize = 4096;
pub const max_dialog_paths_bytes: usize = 16 * 4096;

pub const FileFilter = struct {
    name: []const u8,
    extensions: []const []const u8,
};

pub const OpenDialogOptions = struct {
    title: []const u8 = "",
    default_path: []const u8 = "",
    filters: []const FileFilter = &.{},
    allow_directories: bool = false,
    allow_multiple: bool = false,
};

pub const OpenDialogResult = struct {
    count: usize,
    paths: []const u8,
};

pub const SaveDialogOptions = struct {
    title: []const u8 = "",
    default_path: []const u8 = "",
    default_name: []const u8 = "",
    filters: []const FileFilter = &.{},
};

pub const MessageDialogStyle = enum(c_int) {
    info = 0,
    warning = 1,
    critical = 2,
};

pub const MessageDialogResult = enum(c_int) {
    primary = 0,
    secondary = 1,
    tertiary = 2,
};

pub const MessageDialogOptions = struct {
    style: MessageDialogStyle = .info,
    title: []const u8 = "",
    message: []const u8 = "",
    informative_text: []const u8 = "",
    primary_button: []const u8 = "OK",
    secondary_button: []const u8 = "",
    tertiary_button: []const u8 = "",
};

pub const TrayItemId = u32;

pub const TrayOptions = struct {
    icon_path: []const u8 = "",
    tooltip: []const u8 = "",
    items: []const TrayMenuItem = &.{},
};

pub const TrayMenuItem = struct {
    id: TrayItemId = 0,
    label: []const u8 = "",
    separator: bool = false,
    enabled: bool = true,
};

pub const Event = union(enum) {
    app_start,
    frame_requested,
    app_shutdown,
    surface_resized: Surface,
    window_frame_changed: WindowState,
    window_focused: WindowId,
    bridge_message: BridgeMessage,
    tray_action: TrayItemId,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .app_start => "app_start",
            .frame_requested => "frame_requested",
            .app_shutdown => "app_shutdown",
            .surface_resized => "surface_resized",
            .window_frame_changed => "window_frame_changed",
            .window_focused => "window_focused",
            .bridge_message => "bridge_message",
            .tray_action => "tray_action",
        };
    }
};

pub const EventHandler = *const fn (context: *anyopaque, event: Event) anyerror!void;

pub const PlatformServices = struct {
    context: ?*anyopaque = null,
    read_clipboard_fn: ?*const fn (context: ?*anyopaque, buffer: []u8) anyerror![]const u8 = null,
    write_clipboard_fn: ?*const fn (context: ?*anyopaque, text: []const u8) anyerror!void = null,
    load_webview_fn: ?*const fn (context: ?*anyopaque, source: WebViewSource) anyerror!void = null,
    load_window_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, source: WebViewSource) anyerror!void = null,
    complete_bridge_fn: ?*const fn (context: ?*anyopaque, response: []const u8) anyerror!void = null,
    complete_window_bridge_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void = null,
    create_window_fn: ?*const fn (context: ?*anyopaque, options: WindowOptions) anyerror!WindowInfo = null,
    focus_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    close_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    show_open_dialog_fn: ?*const fn (context: ?*anyopaque, options: OpenDialogOptions, buffer: []u8) anyerror!OpenDialogResult = null,
    show_save_dialog_fn: ?*const fn (context: ?*anyopaque, options: SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 = null,
    show_message_dialog_fn: ?*const fn (context: ?*anyopaque, options: MessageDialogOptions) anyerror!MessageDialogResult = null,
    http_fetch_fn: ?*const fn (context: ?*anyopaque, url: []const u8, buffer: []u8) anyerror![]const u8 = null,
    create_tray_fn: ?*const fn (context: ?*anyopaque, options: TrayOptions) anyerror!void = null,
    update_tray_menu_fn: ?*const fn (context: ?*anyopaque, items: []const TrayMenuItem) anyerror!void = null,
    remove_tray_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    configure_security_policy_fn: ?*const fn (context: ?*anyopaque, policy: security.Policy) anyerror!void = null,
    emit_window_event_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void = null,

    pub fn readClipboard(self: PlatformServices, buffer: []u8) anyerror![]const u8 {
        const read_fn = self.read_clipboard_fn orelse return error.UnsupportedService;
        return read_fn(self.context, buffer);
    }

    pub fn writeClipboard(self: PlatformServices, text: []const u8) anyerror!void {
        const write_fn = self.write_clipboard_fn orelse return error.UnsupportedService;
        return write_fn(self.context, text);
    }

    pub fn loadWebView(self: PlatformServices, source: WebViewSource) anyerror!void {
        if (self.load_window_webview_fn) |load_fn| return load_fn(self.context, 1, source);
        const load_fn = self.load_webview_fn orelse return error.UnsupportedService;
        return load_fn(self.context, source);
    }

    pub fn loadWindowWebView(self: PlatformServices, window_id: WindowId, source: WebViewSource) anyerror!void {
        if (self.load_window_webview_fn) |load_fn| return load_fn(self.context, window_id, source);
        if (window_id == 1) return self.loadWebView(source);
        return error.UnsupportedService;
    }

    pub fn completeBridge(self: PlatformServices, response: []const u8) anyerror!void {
        if (self.complete_window_bridge_fn) |complete_fn| return complete_fn(self.context, 1, response);
        const complete_fn = self.complete_bridge_fn orelse return error.UnsupportedService;
        return complete_fn(self.context, response);
    }

    pub fn completeWindowBridge(self: PlatformServices, window_id: WindowId, response: []const u8) anyerror!void {
        if (self.complete_window_bridge_fn) |complete_fn| return complete_fn(self.context, window_id, response);
        if (window_id == 1) return self.completeBridge(response);
        return error.UnsupportedService;
    }

    pub fn createWindow(self: PlatformServices, options: WindowOptions) anyerror!WindowInfo {
        const create_fn = self.create_window_fn orelse return error.UnsupportedService;
        return create_fn(self.context, options);
    }

    pub fn focusWindow(self: PlatformServices, window_id: WindowId) anyerror!void {
        const focus_fn = self.focus_window_fn orelse return error.UnsupportedService;
        return focus_fn(self.context, window_id);
    }

    pub fn closeWindow(self: PlatformServices, window_id: WindowId) anyerror!void {
        const close_fn = self.close_window_fn orelse return error.UnsupportedService;
        return close_fn(self.context, window_id);
    }

    pub fn showOpenDialog(self: PlatformServices, options: OpenDialogOptions, buffer: []u8) anyerror!OpenDialogResult {
        const open_fn = self.show_open_dialog_fn orelse return error.UnsupportedService;
        return open_fn(self.context, options, buffer);
    }

    pub fn showSaveDialog(self: PlatformServices, options: SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
        const save_fn = self.show_save_dialog_fn orelse return error.UnsupportedService;
        return save_fn(self.context, options, buffer);
    }

    pub fn showMessageDialog(self: PlatformServices, options: MessageDialogOptions) anyerror!MessageDialogResult {
        const msg_fn = self.show_message_dialog_fn orelse return error.UnsupportedService;
        return msg_fn(self.context, options);
    }

    pub fn httpFetch(self: PlatformServices, url: []const u8, buffer: []u8) anyerror![]const u8 {
        const fetch_fn = self.http_fetch_fn orelse return error.UnsupportedService;
        return fetch_fn(self.context, url, buffer);
    }

    pub fn createTray(self: PlatformServices, options: TrayOptions) anyerror!void {
        const tray_fn = self.create_tray_fn orelse return error.UnsupportedService;
        return tray_fn(self.context, options);
    }

    pub fn updateTrayMenu(self: PlatformServices, items: []const TrayMenuItem) anyerror!void {
        const update_fn = self.update_tray_menu_fn orelse return error.UnsupportedService;
        return update_fn(self.context, items);
    }

    pub fn removeTray(self: PlatformServices) anyerror!void {
        const remove_fn = self.remove_tray_fn orelse return error.UnsupportedService;
        return remove_fn(self.context);
    }

    pub fn configureSecurityPolicy(self: PlatformServices, policy: security.Policy) anyerror!void {
        const configure_fn = self.configure_security_policy_fn orelse return error.UnsupportedService;
        return configure_fn(self.context, policy);
    }

    pub fn emitWindowEvent(self: PlatformServices, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
        const emit_fn = self.emit_window_event_fn orelse return error.UnsupportedService;
        return emit_fn(self.context, window_id, name, detail_json);
    }
};

pub const Platform = struct {
    context: *anyopaque,
    name: []const u8,
    surface_value: Surface,
    run_fn: *const fn (context: *anyopaque, handler: EventHandler, handler_context: *anyopaque) anyerror!void,
    services: PlatformServices = .{},
    app_info: AppInfo = .{},

    pub fn surface(self: Platform) Surface {
        return self.surface_value;
    }

    pub fn run(self: Platform, handler: EventHandler, handler_context: *anyopaque) anyerror!void {
        return self.run_fn(self.context, handler, handler_context);
    }
};

pub const Backend = enum {
    @"null",
    macos,
    linux,
    windows,
};

pub const NullPlatform = struct {
    surface_value: Surface = .{},
    web_engine: WebEngine = .system,
    app_info: AppInfo = .{},
    requested_frames: u32 = 1,
    loaded_source: ?WebViewSource = null,
    security_policy: security.Policy = .{},
    window_sources: [max_windows]?WebViewSource = [_]?WebViewSource{null} ** max_windows,
    windows: [max_windows]WindowInfo = undefined,
    window_count: usize = 0,
    bridge_response: [16 * 1024]u8 = undefined,
    bridge_response_len: usize = 0,
    bridge_response_window_id: WindowId = 0,

    pub fn init(surface_value: Surface) NullPlatform {
        return .{ .surface_value = surface_value };
    }

    pub fn initWithEngine(surface_value: Surface, web_engine: WebEngine) NullPlatform {
        return .{ .surface_value = surface_value, .web_engine = web_engine };
    }

    pub fn initWithOptions(surface_value: Surface, web_engine: WebEngine, app_info: AppInfo) NullPlatform {
        return .{ .surface_value = surface_value, .web_engine = web_engine, .app_info = app_info };
    }

    pub fn platform(self: *NullPlatform) Platform {
        return .{
            .context = self,
            .name = "null",
            .surface_value = self.surface_value,
            .run_fn = run,
            .services = .{
                .context = self,
                .load_webview_fn = loadWebView,
                .load_window_webview_fn = loadWindowWebView,
                .complete_bridge_fn = completeBridge,
                .complete_window_bridge_fn = completeWindowBridge,
                .create_window_fn = createWindow,
                .focus_window_fn = focusWindow,
                .close_window_fn = closeWindow,
                .configure_security_policy_fn = configureSecurityPolicy,
                .emit_window_event_fn = emitWindowEvent,
            },
            .app_info = self.app_info,
        };
    }

    pub fn hostInfo(self: NullPlatform) platform_info.HostInfo {
        _ = self;
        const target = platform_info.Target.current();
        return platform_info.detectHost(.{ .target = target });
    }

    fn run(context: *anyopaque, handler: EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context));
        try handler(handler_context, .app_start);
        try handler(handler_context, .{ .surface_resized = self.surface_value });
        const count = self.app_info.startupWindowCount();
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const window = self.app_info.resolvedStartupWindow(index);
            try handler(handler_context, .{ .window_frame_changed = .{
                .id = window.id,
                .label = window.label,
                .title = window.resolvedTitle(self.app_info.app_name),
                .frame = window.default_frame,
                .scale_factor = self.surface_value.scale_factor,
                .open = true,
                .focused = index == 0,
            } });
        }
        var frame: u32 = 0;
        while (frame < self.requested_frames) : (frame += 1) {
            try handler(handler_context, .frame_requested);
        }
        try handler(handler_context, .app_shutdown);
    }

    fn loadWebView(context: ?*anyopaque, source: WebViewSource) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.loaded_source = source;
        self.window_sources[0] = source;
    }

    fn loadWindowWebView(context: ?*anyopaque, window_id: WindowId, source: WebViewSource) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (window_id == 1) self.loaded_source = source;
        const index = self.findWindowIndex(window_id) orelse if (window_id == 1) 0 else return error.WindowNotFound;
        if (index >= self.window_sources.len) return error.WindowNotFound;
        self.window_sources[index] = source;
    }

    fn completeBridge(context: ?*anyopaque, response: []const u8) anyerror!void {
        try recordBridgeResponse(context, 1, response);
    }

    fn completeWindowBridge(context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void {
        try recordBridgeResponse(context, window_id, response);
    }

    fn recordBridgeResponse(context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const count = @min(response.len, self.bridge_response.len);
        @memcpy(self.bridge_response[0..count], response[0..count]);
        self.bridge_response_len = count;
        self.bridge_response_window_id = window_id;
    }

    fn createWindow(context: ?*anyopaque, options: WindowOptions) anyerror!WindowInfo {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (self.window_count >= max_windows) return error.WindowLimitReached;
        for (self.windows[0..self.window_count]) |window| {
            if (window.id == options.id) return error.DuplicateWindowId;
            if (std.mem.eql(u8, window.label, options.label)) return error.DuplicateWindowLabel;
        }
        const info: WindowInfo = .{
            .id = options.id,
            .label = options.label,
            .title = options.resolvedTitle(self.app_info.app_name),
            .frame = options.default_frame,
            .scale_factor = self.surface_value.scale_factor,
            .open = true,
            .focused = false,
        };
        self.windows[self.window_count] = info;
        self.window_count += 1;
        return info;
    }

    fn focusWindow(context: ?*anyopaque, window_id: WindowId) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const focused_index = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
        for (self.windows[0..self.window_count], 0..) |*window, index| {
            window.focused = index == focused_index;
        }
    }

    fn closeWindow(context: ?*anyopaque, window_id: WindowId) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
        self.windows[index].open = false;
        self.windows[index].focused = false;
    }

    fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.security_policy = policy;
    }

    fn emitWindowEvent(context: ?*anyopaque, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
        _ = context;
        _ = window_id;
        _ = name;
        _ = detail_json;
    }

    fn findWindowIndex(self: *const NullPlatform, window_id: WindowId) ?usize {
        for (self.windows[0..self.window_count], 0..) |window, index| {
            if (window.id == window_id) return index;
        }
        return null;
    }

    pub fn lastBridgeResponse(self: *const NullPlatform) []const u8 {
        return self.bridge_response[0..self.bridge_response_len];
    }

    pub fn lastBridgeResponseWindowId(self: *const NullPlatform) WindowId {
        return self.bridge_response_window_id;
    }
};

pub const macos = @import("macos/root.zig");
pub const linux = @import("linux/root.zig");
pub const windows = @import("windows/root.zig");

test "null platform emits deterministic lifecycle events" {
    const Recorder = struct {
        names: [5][]const u8 = undefined,
        len: usize = 0,

        fn handle(context: *anyopaque, event: Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.names[self.len] = event.name();
            self.len += 1;
        }
    };

    var null_platform = NullPlatform.init(.{});
    var recorder: Recorder = .{};
    try null_platform.platform().run(Recorder.handle, &recorder);

    try std.testing.expectEqual(@as(usize, 5), recorder.len);
    try std.testing.expectEqualStrings("app_start", recorder.names[0]);
    try std.testing.expectEqualStrings("surface_resized", recorder.names[1]);
    try std.testing.expectEqualStrings("window_frame_changed", recorder.names[2]);
    try std.testing.expectEqualStrings("frame_requested", recorder.names[3]);
    try std.testing.expectEqualStrings("app_shutdown", recorder.names[4]);
}

test "null platform records loaded webview source" {
    var null_platform = NullPlatform.initWithOptions(.{}, .chromium, .{ .app_name = "Demo", .window_title = "Demo Window" });
    try null_platform.platform().services.loadWebView(WebViewSource.html("<h1>Hello</h1>"));

    try std.testing.expectEqual(WebEngine.chromium, null_platform.web_engine);
    try std.testing.expectEqualStrings("Demo Window", null_platform.app_info.resolvedWindowTitle());
    try std.testing.expectEqual(WebViewSourceKind.html, null_platform.loaded_source.?.kind);
    try std.testing.expectEqualStrings("<h1>Hello</h1>", null_platform.loaded_source.?.bytes);
}

test "null platform records bridge response window routing" {
    var null_platform = NullPlatform.init(.{});
    try null_platform.platform().services.completeWindowBridge(7, "{\"ok\":true}");

    try std.testing.expectEqual(@as(WindowId, 7), null_platform.lastBridgeResponseWindowId());
    try std.testing.expectEqualStrings("{\"ok\":true}", null_platform.lastBridgeResponse());
}

test "webview asset source records production bundle options" {
    const source = WebViewSource.assets(.{ .root_path = "dist", .entry = "index.html" });

    try std.testing.expectEqual(WebViewSourceKind.assets, source.kind);
    try std.testing.expectEqualStrings("zero://app", source.bytes);
    try std.testing.expectEqualStrings("dist", source.asset_options.?.root_path);
    try std.testing.expect(source.asset_options.?.spa_fallback);
}

test {
    std.testing.refAllDecls(@This());
}
