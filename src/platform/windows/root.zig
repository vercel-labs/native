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

const WindowsHost = opaque {};

const WindowsEventKind = enum(c_int) {
    start = 0,
    frame = 1,
    shutdown = 2,
    resize = 3,
    window_frame = 4,
};

const WindowsEvent = extern struct {
    kind: WindowsEventKind,
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

const WindowsCallback = *const fn (context: ?*anyopaque, event: *const WindowsEvent) callconv(.c) void;
const WindowsBridgeCallback = *const fn (context: ?*anyopaque, window_id: u64, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void;
const WindowsTrayCallback = *const fn (context: ?*anyopaque, item_id: u32) callconv(.c) void;

extern fn zero_native_windows_create(app_name: [*]const u8, app_name_len: usize, window_title: [*]const u8, window_title_len: usize, bundle_id: [*]const u8, bundle_id_len: usize, icon_path: [*]const u8, icon_path_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int) ?*WindowsHost;
extern fn zero_native_windows_destroy(host: *WindowsHost) void;
extern fn zero_native_windows_run(host: *WindowsHost, callback: WindowsCallback, context: ?*anyopaque) void;
extern fn zero_native_windows_stop(host: *WindowsHost) void;
extern fn zero_native_windows_load_webview(host: *WindowsHost, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn zero_native_windows_load_window_webview(host: *WindowsHost, window_id: u64, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn zero_native_windows_set_bridge_callback(host: *WindowsHost, callback: WindowsBridgeCallback, context: ?*anyopaque) void;
extern fn zero_native_windows_bridge_respond(host: *WindowsHost, response: [*]const u8, response_len: usize) void;
extern fn zero_native_windows_bridge_respond_window(host: *WindowsHost, window_id: u64, response: [*]const u8, response_len: usize) void;
extern fn zero_native_windows_emit_window_event(host: *WindowsHost, window_id: u64, name: [*]const u8, name_len: usize, detail_json: [*]const u8, detail_json_len: usize) void;
extern fn zero_native_windows_set_security_policy(host: *WindowsHost, allowed_origins: [*]const u8, allowed_origins_len: usize, external_urls: [*]const u8, external_urls_len: usize, external_action: c_int) void;
extern fn zero_native_windows_create_window(host: *WindowsHost, window_id: u64, window_title: [*]const u8, window_title_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int) c_int;
extern fn zero_native_windows_focus_window(host: *WindowsHost, window_id: u64) c_int;
extern fn zero_native_windows_close_window(host: *WindowsHost, window_id: u64) c_int;
extern fn zero_native_windows_clipboard_read(host: *WindowsHost, buffer: [*]u8, buffer_len: usize) usize;
extern fn zero_native_windows_clipboard_write(host: *WindowsHost, text: [*]const u8, text_len: usize) void;

const WindowsOpenDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
    allow_directories: c_int,
    allow_multiple: c_int,
};

const WindowsOpenDialogResult = extern struct {
    count: usize,
    bytes_written: usize,
};

const WindowsSaveDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    default_name: [*]const u8,
    default_name_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
};

const WindowsMessageDialogOpts = extern struct {
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

extern fn zero_native_windows_show_open_dialog(host: *WindowsHost, opts: *const WindowsOpenDialogOpts, buffer: [*]u8, buffer_len: usize) WindowsOpenDialogResult;
extern fn zero_native_windows_show_save_dialog(host: *WindowsHost, opts: *const WindowsSaveDialogOpts, buffer: [*]u8, buffer_len: usize) usize;
extern fn zero_native_windows_show_message_dialog(host: *WindowsHost, opts: *const WindowsMessageDialogOpts) c_int;

extern fn zero_native_windows_create_tray(host: *WindowsHost, icon_path: [*]const u8, icon_path_len: usize, tooltip: [*]const u8, tooltip_len: usize) void;
extern fn zero_native_windows_update_tray_menu(host: *WindowsHost, item_ids: [*]const u32, labels: [*]const [*]const u8, label_lens: [*]const usize, separators: [*]const c_int, enabled_flags: [*]const c_int, count: usize) void;
extern fn zero_native_windows_remove_tray(host: *WindowsHost) void;
extern fn zero_native_windows_set_tray_callback(host: *WindowsHost, callback: WindowsTrayCallback, context: ?*anyopaque) void;

pub const WindowsPlatform = struct {
    host: *WindowsHost,
    web_engine: platform_mod.WebEngine,
    app_info: platform_mod.AppInfo,
    surface_value: platform_mod.Surface,
    state: RunState = .{},

    pub fn init(title: []const u8, size: geometry.SizeF) Error!WindowsPlatform {
        return initWithEngine(title, size, .system);
    }

    pub fn initWithEngine(title: []const u8, size: geometry.SizeF, web_engine: platform_mod.WebEngine) Error!WindowsPlatform {
        return initWithOptions(size, web_engine, .{ .app_name = title, .window_title = title });
    }

    pub fn initWithOptions(size: geometry.SizeF, web_engine: platform_mod.WebEngine, app_info: platform_mod.AppInfo) Error!WindowsPlatform {
        const window_options = app_info.resolvedMainWindow();
        const window_title = window_options.resolvedTitle(app_info.app_name);
        const frame = window_options.default_frame;
        const host = zero_native_windows_create(app_info.app_name.ptr, app_info.app_name.len, window_title.ptr, window_title.len, app_info.bundle_id.ptr, app_info.bundle_id.len, app_info.icon_path.ptr, app_info.icon_path.len, window_options.label.ptr, window_options.label.len, frame.x, frame.y, frame.width, frame.height, if (window_options.restore_state) 1 else 0) orelse return error.CreateFailed;
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

    pub fn deinit(self: *WindowsPlatform) void {
        zero_native_windows_destroy(self.host);
    }

    pub fn platform(self: *WindowsPlatform) platform_mod.Platform {
        return .{
            .context = self,
            .name = "windows",
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
            },
            .app_info = self.app_info,
        };
    }

    fn run(context: *anyopaque, handler: platform_mod.EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *WindowsPlatform = @ptrCast(@alignCast(context));
        self.state = .{
            .self = self,
            .handler = handler,
            .handler_context = handler_context,
        };
        zero_native_windows_set_bridge_callback(self.host, windowsBridgeCallback, &self.state);
        zero_native_windows_set_tray_callback(self.host, windowsTrayCallback, &self.state);
        zero_native_windows_run(self.host, windowsCallback, &self.state);
        if (self.state.failed) return error.CallbackFailed;
    }

    fn windowById(self: *const WindowsPlatform, window_id: platform_mod.WindowId) platform_mod.WindowOptions {
        var index: usize = 0;
        while (index < self.app_info.startupWindowCount()) : (index += 1) {
            const window = self.app_info.resolvedStartupWindow(index);
            if (window.id == window_id) return window;
        }
        return .{ .id = window_id, .label = "", .title = self.app_info.resolvedWindowTitle() };
    }
};

const RunState = struct {
    self: ?*WindowsPlatform = null,
    handler: ?platform_mod.EventHandler = null,
    handler_context: ?*anyopaque = null,
    failed: bool = false,

    fn emit(self: *RunState, event: platform_mod.Event) void {
        const handler = self.handler orelse return;
        const context = self.handler_context orelse return;
        handler(context, event) catch {
            self.failed = true;
            if (self.self) |windows| zero_native_windows_stop(windows.host);
        };
    }
};

fn windowsCallback(context: ?*anyopaque, event: *const WindowsEvent) callconv(.c) void {
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
            if (state.self) |windows| windows.surface_value = surface;
            state.emit(.{ .surface_resized = surface });
        },
        .window_frame => if (state.self) |windows| {
            const event_label = event.label[0..event.label_len];
            const event_title = event.title[0..event.title_len];
            const window = if (event_label.len > 0)
                platform_mod.WindowOptions{ .id = event.window_id, .label = event_label, .title = event_title }
            else
                windows.windowById(event.window_id);
            state.emit(.{ .window_frame_changed = .{
                .id = window.id,
                .label = window.label,
                .title = window.resolvedTitle(windows.app_info.app_name),
                .frame = geometry.RectF.init(@floatCast(event.x), @floatCast(event.y), @floatCast(event.width), @floatCast(event.height)),
                .scale_factor = @floatCast(event.scale),
                .open = event.open != 0,
                .focused = event.focused != 0,
            } });
        },
    }
}

fn windowsBridgeCallback(context: ?*anyopaque, window_id: u64, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    state.emit(.{ .bridge_message = .{
        .bytes = message[0..message_len],
        .origin = origin[0..origin_len],
        .window_id = window_id,
    } });
}

fn windowsTrayCallback(context: ?*anyopaque, item_id: u32) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    state.emit(.{ .tray_action = item_id });
}

fn readClipboard(context: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    return buffer[0..zero_native_windows_clipboard_read(self.host, buffer.ptr, buffer.len)];
}

fn writeClipboard(context: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    zero_native_windows_clipboard_write(self.host, text.ptr, text.len);
}

fn loadWebView(context: ?*anyopaque, source: platform_mod.WebViewSource) anyerror!void {
    try loadWindowWebView(context, 1, source);
}

fn loadWindowWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, source: platform_mod.WebViewSource) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const assets: platform_mod.WebViewAssetSource = source.asset_options orelse .{ .root_path = "", .entry = "", .origin = "", .spa_fallback = false };
    zero_native_windows_load_window_webview(
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
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    zero_native_windows_bridge_respond(self.host, response.ptr, response.len);
}

fn completeWindowBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, response: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    zero_native_windows_bridge_respond_window(self.host, window_id, response.ptr, response.len);
}

fn emitWindowEvent(context: ?*anyopaque, window_id: platform_mod.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    zero_native_windows_emit_window_event(self.host, window_id, name.ptr, name.len, detail_json.ptr, detail_json.len);
}

fn createWindow(context: ?*anyopaque, options: platform_mod.WindowOptions) anyerror!platform_mod.WindowInfo {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const title = options.resolvedTitle(self.app_info.app_name);
    const frame = options.default_frame;
    if (zero_native_windows_create_window(self.host, options.id, title.ptr, title.len, options.label.ptr, options.label.len, frame.x, frame.y, frame.width, frame.height, if (options.restore_state) 1 else 0) == 0) return error.CreateFailed;
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
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (zero_native_windows_focus_window(self.host, window_id) == 0) return error.FocusFailed;
}

fn closeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (zero_native_windows_close_window(self.host, window_id) == 0) return error.CloseFailed;
}

fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    var origins_buffer: [4096]u8 = undefined;
    var external_buffer: [4096]u8 = undefined;
    const origins = try policy_values.join(policy.navigation.allowed_origins, &origins_buffer);
    const external_urls = try policy_values.join(policy.navigation.external_links.allowed_urls, &external_buffer);
    zero_native_windows_set_security_policy(
        self.host,
        origins.ptr,
        origins.len,
        external_urls.ptr,
        external_urls.len,
        @intFromEnum(policy.navigation.external_links.action),
    );
}

fn showOpenDialog(context: ?*anyopaque, options: platform_mod.OpenDialogOptions, buffer: []u8) anyerror!platform_mod.OpenDialogResult {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = WindowsOpenDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
        .allow_directories = if (options.allow_directories) 1 else 0,
        .allow_multiple = if (options.allow_multiple) 1 else 0,
    };
    const result = zero_native_windows_show_open_dialog(self.host, &opts, buffer.ptr, buffer.len);
    return .{
        .count = result.count,
        .paths = buffer[0..result.bytes_written],
    };
}

fn showSaveDialog(context: ?*anyopaque, options: platform_mod.SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = WindowsSaveDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .default_name = options.default_name.ptr,
        .default_name_len = options.default_name.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
    };
    const written = zero_native_windows_show_save_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (written == 0) return null;
    return buffer[0..written];
}

fn showMessageDialog(context: ?*anyopaque, options: platform_mod.MessageDialogOptions) anyerror!platform_mod.MessageDialogResult {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    // Build filter string from all filters (flattenFilters not used here; message dialog doesn't have file filters)
    const opts = WindowsMessageDialogOpts{
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
    const result = zero_native_windows_show_message_dialog(self.host, &opts);
    return @enumFromInt(result);
}

fn createTray(context: ?*anyopaque, options: platform_mod.TrayOptions) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    zero_native_windows_create_tray(self.host, options.icon_path.ptr, options.icon_path.len, options.tooltip.ptr, options.tooltip.len);
    if (options.items.len > 0) {
        try updateTrayMenu(context, options.items);
    }
}

fn updateTrayMenu(context: ?*anyopaque, items: []const platform_mod.TrayMenuItem) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const max_items: usize = 32;
    const count = @min(items.len, max_items);
    var ids: [max_items]u32 = undefined;
    var labels_ptr: [max_items][*]const u8 = undefined;
    var label_lens: [max_items]usize = undefined;
    var separators: [max_items]c_int = undefined;
    var enabled_flags: [max_items]c_int = undefined;
    for (items[0..count], 0..) |item, i| {
        ids[i] = item.id;
        labels_ptr[i] = item.label.ptr;
        label_lens[i] = item.label.len;
        separators[i] = if (item.separator) 1 else 0;
        enabled_flags[i] = if (item.enabled) 1 else 0;
    }
    zero_native_windows_update_tray_menu(self.host, &ids, &labels_ptr, &label_lens, &separators, &enabled_flags, count);
}

fn removeTray(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    zero_native_windows_remove_tray(self.host);
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

test "windows platform module exports type" {
    _ = WindowsPlatform;
}

test "windows event kind count matches expectation" {
    // Ensure we have the right number of event kinds
    const kinds = [_]WindowsEventKind{ .start, .frame, .shutdown, .resize, .window_frame };
    try std.testing.expectEqual(@as(usize, 5), kinds.len);
}

test "windows open dialog opts has correct layout" {
    try std.testing.expectEqual(@as(usize, 8), @typeInfo(WindowsOpenDialogOpts).@"struct".fields.len);
}

test "windows save dialog opts has correct layout" {
    try std.testing.expectEqual(@as(usize, 8), @typeInfo(WindowsSaveDialogOpts).@"struct".fields.len);
}

test "windows message dialog opts has correct layout" {
    try std.testing.expectEqual(@as(usize, 13), @typeInfo(WindowsMessageDialogOpts).@"struct".fields.len);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}