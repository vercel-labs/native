const std = @import("std");
const geometry = @import("geometry");
const platform_mod = @import("../root.zig");
const policy_values = @import("../policy_values.zig");
const security = @import("../../security/root.zig");

pub const Error = error{
    CallbackFailed,
    CreateFailed,
    FocusFailed,
    CloseFailed,
};

const GtkHost = opaque {};

const GtkEventKind = enum(c_int) {
    start = 0,
    frame = 1,
    shutdown = 2,
    resize = 3,
    window_frame = 4,
};

const GtkEvent = extern struct {
    kind: GtkEventKind,
    window_id: u64,
    width: f64,
    height: f64,
    scale: f64,
    x: f64,
    y: f64,
    open: c_int,
    focused: c_int,
    label: [*]const u8,
    label_len: usize,
    title: [*]const u8,
    title_len: usize,
};

const GtkCallback = *const fn (context: ?*anyopaque, event: *const GtkEvent) callconv(.c) void;
const GtkBridgeCallback = *const fn (context: ?*anyopaque, window_id: u64, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void;
const GtkResourceStreamReadCallback = *const fn (context: ?*anyopaque, id: [*]const u8, id_len: usize, origin: [*]const u8, origin_len: usize, window_id: u64, buffer: [*]u8, buffer_len: usize) callconv(.c) isize;
const GtkResourceStreamCloseCallback = *const fn (context: ?*anyopaque, id: [*]const u8, id_len: usize, reason: platform_mod.ResourceCloseReason) callconv(.c) void;

extern fn zero_native_gtk_create(app_name: [*]const u8, app_name_len: usize, window_title: [*]const u8, window_title_len: usize, bundle_id: [*]const u8, bundle_id_len: usize, icon_path: [*]const u8, icon_path_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int) ?*GtkHost;
extern fn zero_native_gtk_destroy(host: *GtkHost) void;
extern fn zero_native_gtk_run(host: *GtkHost, callback: GtkCallback, context: ?*anyopaque) void;
extern fn zero_native_gtk_stop(host: *GtkHost) void;
extern fn zero_native_gtk_load_webview(host: *GtkHost, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn zero_native_gtk_load_window_webview(host: *GtkHost, window_id: u64, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn zero_native_gtk_set_bridge_callback(host: *GtkHost, callback: GtkBridgeCallback, context: ?*anyopaque) void;
extern fn zero_native_gtk_bridge_respond(host: *GtkHost, response: [*]const u8, response_len: usize) void;
extern fn zero_native_gtk_bridge_respond_window(host: *GtkHost, window_id: u64, response: [*]const u8, response_len: usize) void;
extern fn zero_native_gtk_emit_window_event(host: *GtkHost, window_id: u64, name: [*]const u8, name_len: usize, detail_json: [*]const u8, detail_json_len: usize) void;
extern fn zero_native_gtk_set_security_policy(host: *GtkHost, allowed_origins: [*]const u8, allowed_origins_len: usize, external_urls: [*]const u8, external_urls_len: usize, external_action: c_int) void;
extern fn zero_native_gtk_register_resource_bytes(host: *GtkHost, id: [*]const u8, id_len: usize, mime: [*]const u8, mime_len: usize, bytes: [*]const u8, bytes_len: usize, origin: [*]const u8, origin_len: usize, window_id: u64, expires_at_ns: i64, has_expiry: c_int, one_shot: c_int) c_int;
extern fn zero_native_gtk_register_resource_stream(host: *GtkHost, id: [*]const u8, id_len: usize, mime: [*]const u8, mime_len: usize, origin: [*]const u8, origin_len: usize, window_id: u64, expires_at_ns: i64, has_expiry: c_int, one_shot: c_int, size: u64, has_size: c_int, callback_context: ?*anyopaque, read_callback: GtkResourceStreamReadCallback, close_callback: GtkResourceStreamCloseCallback) c_int;
extern fn zero_native_gtk_revoke_resource(host: *GtkHost, id: [*]const u8, id_len: usize) void;
extern fn zero_native_gtk_create_window(host: *GtkHost, window_id: u64, window_title: [*]const u8, window_title_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int) c_int;
extern fn zero_native_gtk_focus_window(host: *GtkHost, window_id: u64) c_int;
extern fn zero_native_gtk_close_window(host: *GtkHost, window_id: u64) c_int;
extern fn zero_native_gtk_clipboard_read(host: *GtkHost, buffer: [*]u8, buffer_len: usize) usize;
extern fn zero_native_gtk_clipboard_write(host: *GtkHost, text: [*]const u8, text_len: usize) void;

const GtkOpenDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
    allow_directories: c_int,
    allow_multiple: c_int,
};

const GtkOpenDialogResult = extern struct {
    count: usize,
    bytes_written: usize,
};

const GtkSaveDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    default_name: [*]const u8,
    default_name_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
};

const GtkMessageDialogOpts = extern struct {
    style: c_int,
    title: [*]const u8,
    title_len: usize,
    message: [*]const u8,
    message_len: usize,
    informative_text: [*]const u8,
    informative_text_len: usize,
    primary_button: [*]const u8,
    primary_button_len: usize,
    secondary_button: [*]const u8,
    secondary_button_len: usize,
    tertiary_button: [*]const u8,
    tertiary_button_len: usize,
};

extern fn zero_native_gtk_show_open_dialog(host: *GtkHost, opts: *const GtkOpenDialogOpts, buffer: [*]u8, buffer_len: usize) GtkOpenDialogResult;
extern fn zero_native_gtk_show_save_dialog(host: *GtkHost, opts: *const GtkSaveDialogOpts, buffer: [*]u8, buffer_len: usize) usize;
extern fn zero_native_gtk_show_message_dialog(host: *GtkHost, opts: *const GtkMessageDialogOpts) c_int;

pub const LinuxPlatform = struct {
    host: *GtkHost,
    web_engine: platform_mod.WebEngine,
    app_info: platform_mod.AppInfo,
    surface_value: platform_mod.Surface,
    state: RunState = .{},

    pub fn init(title: []const u8, size: geometry.SizeF) Error!LinuxPlatform {
        return initWithEngine(title, size, .system);
    }

    pub fn initWithEngine(title: []const u8, size: geometry.SizeF, web_engine: platform_mod.WebEngine) Error!LinuxPlatform {
        return initWithOptions(size, web_engine, .{ .app_name = title, .window_title = title });
    }

    pub fn initWithOptions(size: geometry.SizeF, web_engine: platform_mod.WebEngine, app_info: platform_mod.AppInfo) Error!LinuxPlatform {
        const window_options = app_info.resolvedMainWindow();
        const window_title = window_options.resolvedTitle(app_info.app_name);
        const frame = window_options.default_frame;
        const host = zero_native_gtk_create(app_info.app_name.ptr, app_info.app_name.len, window_title.ptr, window_title.len, app_info.bundle_id.ptr, app_info.bundle_id.len, app_info.icon_path.ptr, app_info.icon_path.len, window_options.label.ptr, window_options.label.len, frame.x, frame.y, frame.width, frame.height, if (window_options.restore_state) 1 else 0) orelse return error.CreateFailed;
        return .{
            .host = host,
            .web_engine = web_engine,
            .app_info = app_info,
            .surface_value = .{
                .id = 1,
                .size = size,
                .scale_factor = 1,
            },
        };
    }

    pub fn deinit(self: *LinuxPlatform) void {
        zero_native_gtk_destroy(self.host);
    }

    pub fn platform(self: *LinuxPlatform) platform_mod.Platform {
        return .{
            .context = self,
            .name = "linux",
            .surface_value = self.surface_value,
            .run_fn = run,
            .services = .{
                .context = self,
                .read_clipboard_fn = readClipboard,
                .write_clipboard_fn = writeClipboard,
                .load_webview_fn = loadWebView,
                .load_window_webview_fn = loadWindowWebView,
                .complete_bridge_fn = completeBridge,
                .complete_window_bridge_fn = completeWindowBridge,
                .create_window_fn = createWindow,
                .focus_window_fn = focusWindow,
                .close_window_fn = closeWindow,
                .show_open_dialog_fn = showOpenDialog,
                .show_save_dialog_fn = showSaveDialog,
                .show_message_dialog_fn = showMessageDialog,
                .create_tray_fn = createTray,
                .update_tray_menu_fn = updateTrayMenu,
                .remove_tray_fn = removeTray,
                .configure_security_policy_fn = configureSecurityPolicy,
                .emit_window_event_fn = emitWindowEvent,
                .register_resource_bytes_fn = registerResourceBytes,
                .register_resource_stream_fn = registerResourceStream,
                .revoke_resource_fn = revokeResource,
            },
            .app_info = self.app_info,
        };
    }

    fn run(context: *anyopaque, handler: platform_mod.EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *LinuxPlatform = @ptrCast(@alignCast(context));
        self.state = .{
            .self = self,
            .handler = handler,
            .handler_context = handler_context,
        };
        zero_native_gtk_set_bridge_callback(self.host, gtkBridgeCallback, &self.state);
        zero_native_gtk_run(self.host, gtkCallback, &self.state);
        if (self.state.failed) return error.CallbackFailed;
    }

    fn windowById(self: *const LinuxPlatform, window_id: platform_mod.WindowId) platform_mod.WindowOptions {
        var index: usize = 0;
        while (index < self.app_info.startupWindowCount()) : (index += 1) {
            const window = self.app_info.resolvedStartupWindow(index);
            if (window.id == window_id) return window;
        }
        return .{ .id = window_id, .label = "", .title = self.app_info.resolvedWindowTitle() };
    }
};

const RunState = struct {
    self: ?*LinuxPlatform = null,
    handler: ?platform_mod.EventHandler = null,
    handler_context: ?*anyopaque = null,
    failed: bool = false,

    fn emit(self: *RunState, event: platform_mod.Event) void {
        const handler = self.handler orelse return;
        const context = self.handler_context orelse return;
        handler(context, event) catch {
            self.failed = true;
            if (self.self) |linux| zero_native_gtk_stop(linux.host);
        };
    }
};

fn gtkCallback(context: ?*anyopaque, event: *const GtkEvent) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    switch (event.kind) {
        .start => state.emit(.app_start),
        .frame => state.emit(.frame_requested),
        .shutdown => state.emit(.app_shutdown),
        .resize => {
            const surface: platform_mod.Surface = .{
                .id = event.window_id,
                .size = geometry.SizeF.init(@floatCast(event.width), @floatCast(event.height)),
                .scale_factor = @floatCast(event.scale),
            };
            if (state.self) |linux| linux.surface_value = surface;
            state.emit(.{ .surface_resized = surface });
        },
        .window_frame => if (state.self) |linux| {
            const event_label = event.label[0..event.label_len];
            const event_title = event.title[0..event.title_len];
            const window = if (event_label.len > 0)
                platform_mod.WindowOptions{ .id = event.window_id, .label = event_label, .title = event_title }
            else
                linux.windowById(event.window_id);
            state.emit(.{ .window_frame_changed = .{
                .id = window.id,
                .label = window.label,
                .title = window.resolvedTitle(linux.app_info.app_name),
                .frame = geometry.RectF.init(@floatCast(event.x), @floatCast(event.y), @floatCast(event.width), @floatCast(event.height)),
                .scale_factor = @floatCast(event.scale),
                .open = event.open != 0,
                .focused = event.focused != 0,
            } });
        },
    }
}

fn gtkBridgeCallback(context: ?*anyopaque, window_id: u64, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    state.emit(.{ .bridge_message = .{
        .bytes = message[0..message_len],
        .origin = origin[0..origin_len],
        .window_id = window_id,
    } });
}

fn readClipboard(context: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    return buffer[0..zero_native_gtk_clipboard_read(self.host, buffer.ptr, buffer.len)];
}

fn writeClipboard(context: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    zero_native_gtk_clipboard_write(self.host, text.ptr, text.len);
}

fn loadWebView(context: ?*anyopaque, source: platform_mod.WebViewSource) anyerror!void {
    try loadWindowWebView(context, 1, source);
}

fn loadWindowWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, source: platform_mod.WebViewSource) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    const assets: platform_mod.WebViewAssetSource = source.asset_options orelse .{ .root_path = "", .entry = "", .origin = "", .spa_fallback = false };
    zero_native_gtk_load_window_webview(
        self.host,
        window_id,
        source.bytes.ptr,
        source.bytes.len,
        switch (source.kind) {
            .html => 0,
            .url => 1,
            .assets => 2,
        },
        assets.root_path.ptr,
        assets.root_path.len,
        assets.entry.ptr,
        assets.entry.len,
        assets.origin.ptr,
        assets.origin.len,
        if (assets.spa_fallback) 1 else 0,
    );
}

fn completeBridge(context: ?*anyopaque, response: []const u8) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    zero_native_gtk_bridge_respond(self.host, response.ptr, response.len);
}

fn completeWindowBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, response: []const u8) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    zero_native_gtk_bridge_respond_window(self.host, window_id, response.ptr, response.len);
}

fn emitWindowEvent(context: ?*anyopaque, window_id: platform_mod.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    zero_native_gtk_emit_window_event(self.host, window_id, name.ptr, name.len, detail_json.ptr, detail_json.len);
}

fn registerResourceBytes(context: ?*anyopaque, id: []const u8, mime: []const u8, bytes: []const u8, origin: []const u8, window_id: platform_mod.WindowId, expires_at_ns: ?i128, one_shot: bool) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine == .chromium) return error.UnsupportedService;
    if (zero_native_gtk_register_resource_bytes(self.host, id.ptr, id.len, mime.ptr, mime.len, bytes.ptr, bytes.len, origin.ptr, origin.len, window_id, optionalTimestampForC(expires_at_ns), if (expires_at_ns != null) 1 else 0, if (one_shot) 1 else 0) == 0) return error.ResourceLimitReached;
}

fn registerResourceStream(context: ?*anyopaque, registration: platform_mod.ResourceStreamRegistration) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    if (zero_native_gtk_register_resource_stream(
        self.host,
        registration.id.ptr,
        registration.id.len,
        registration.mime.ptr,
        registration.mime.len,
        registration.origin.ptr,
        registration.origin.len,
        registration.window_id,
        optionalTimestampForC(registration.expires_at_ns),
        if (registration.expires_at_ns != null) 1 else 0,
        if (registration.one_shot) 1 else 0,
        @intCast(registration.size orelse 0),
        if (registration.size != null) 1 else 0,
        registration.callback_context,
        registration.read_fn,
        registration.close_fn,
    ) == 0) return error.ResourceLimitReached;
}

fn revokeResource(context: ?*anyopaque, id: []const u8) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine == .chromium) return error.UnsupportedService;
    zero_native_gtk_revoke_resource(self.host, id.ptr, id.len);
}

fn optionalTimestampForC(value: ?i128) i64 {
    const timestamp = value orelse return 0;
    if (timestamp > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (timestamp < std.math.minInt(i64)) return std.math.minInt(i64);
    return @intCast(timestamp);
}

fn createWindow(context: ?*anyopaque, options: platform_mod.WindowOptions) anyerror!platform_mod.WindowInfo {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    const title = options.resolvedTitle(self.app_info.app_name);
    const frame = options.default_frame;
    if (zero_native_gtk_create_window(self.host, options.id, title.ptr, title.len, options.label.ptr, options.label.len, frame.x, frame.y, frame.width, frame.height, if (options.restore_state) 1 else 0) == 0) return error.CreateFailed;
    return .{
        .id = options.id,
        .label = options.label,
        .title = title,
        .frame = frame,
        .scale_factor = 1,
        .open = true,
        .focused = false,
    };
}

fn focusWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    if (zero_native_gtk_focus_window(self.host, window_id) == 0) return error.FocusFailed;
}

fn closeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    if (zero_native_gtk_close_window(self.host, window_id) == 0) return error.CloseFailed;
}

fn showOpenDialog(context: ?*anyopaque, options: platform_mod.OpenDialogOptions, buffer: []u8) anyerror!platform_mod.OpenDialogResult {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = GtkOpenDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
        .allow_directories = if (options.allow_directories) 1 else 0,
        .allow_multiple = if (options.allow_multiple) 1 else 0,
    };
    const result = zero_native_gtk_show_open_dialog(self.host, &opts, buffer.ptr, buffer.len);
    return .{ .count = result.count, .paths = buffer[0..result.bytes_written] };
}

fn showSaveDialog(context: ?*anyopaque, options: platform_mod.SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = GtkSaveDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .default_name = options.default_name.ptr,
        .default_name_len = options.default_name.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
    };
    const written = zero_native_gtk_show_save_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (written == 0) return null;
    return buffer[0..written];
}

fn showMessageDialog(context: ?*anyopaque, options: platform_mod.MessageDialogOptions) anyerror!platform_mod.MessageDialogResult {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    const opts = GtkMessageDialogOpts{
        .style = @intFromEnum(options.style),
        .title = options.title.ptr,
        .title_len = options.title.len,
        .message = options.message.ptr,
        .message_len = options.message.len,
        .informative_text = options.informative_text.ptr,
        .informative_text_len = options.informative_text.len,
        .primary_button = options.primary_button.ptr,
        .primary_button_len = options.primary_button.len,
        .secondary_button = options.secondary_button.ptr,
        .secondary_button_len = options.secondary_button.len,
        .tertiary_button = options.tertiary_button.ptr,
        .tertiary_button_len = options.tertiary_button.len,
    };
    return @enumFromInt(zero_native_gtk_show_message_dialog(self.host, &opts));
}

fn createTray(context: ?*anyopaque, options: platform_mod.TrayOptions) anyerror!void {
    _ = context;
    _ = options;
    return error.UnsupportedService;
}

fn updateTrayMenu(context: ?*anyopaque, items: []const platform_mod.TrayMenuItem) anyerror!void {
    _ = context;
    _ = items;
    return error.UnsupportedService;
}

fn removeTray(context: ?*anyopaque) anyerror!void {
    _ = context;
    return error.UnsupportedService;
}

fn flattenFilters(filters: []const platform_mod.FileFilter, buffer: []u8) []const u8 {
    var offset: usize = 0;
    for (filters) |filter| {
        for (filter.extensions) |ext| {
            if (offset > 0 and offset < buffer.len) {
                buffer[offset] = ';';
                offset += 1;
            }
            const end = @min(offset + ext.len, buffer.len);
            if (end > offset) {
                @memcpy(buffer[offset..end], ext[0..(end - offset)]);
                offset = end;
            }
        }
    }
    return buffer[0..offset];
}

fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
    const self: *LinuxPlatform = @ptrCast(@alignCast(context.?));
    var origins_buffer: [4096]u8 = undefined;
    var external_buffer: [4096]u8 = undefined;
    const origins = try policy_values.join(policy.navigation.allowed_origins, &origins_buffer);
    const external_urls = try policy_values.join(policy.navigation.external_links.allowed_urls, &external_buffer);
    zero_native_gtk_set_security_policy(
        self.host,
        origins.ptr,
        origins.len,
        external_urls.ptr,
        external_urls.len,
        @intFromEnum(policy.navigation.external_links.action),
    );
}

test "linux platform module exports type" {
    _ = LinuxPlatform;
}
