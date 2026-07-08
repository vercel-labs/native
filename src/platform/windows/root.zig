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
    shortcut = 5,
    native_command = 6,
    app_activated = 7,
    app_deactivated = 8,
    files_dropped = 9,
    menu_command = 10,
    tray_action = 11,
    gpu_surface_frame = 12,
    gpu_surface_resize = 13,
    gpu_surface_input = 14,
    wake = 15,
    timer = 16,
    appearance = 17,
    audio = 18,
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
    shortcut_id: [*]const u8,
    shortcut_id_len: usize,
    shortcut_key: [*]const u8,
    shortcut_key_len: usize,
    shortcut_modifiers: u32,
    command_name: [*]const u8,
    command_name_len: usize,
    view_label: [*]const u8,
    view_label_len: usize,
    drop_paths: [*]const u8,
    drop_paths_len: usize,
    tray_item_id: u32,
    frame_index: u64,
    timestamp_ns: u64,
    frame_interval_ns: u64,
    nonblank: c_int,
    sample_color: u32,
    /// Nonzero when the frame completed logically while the top-level
    /// window was minimized (heartbeat pacing; nothing painted) — its
    /// timestamp is pacing policy, never a latency endpoint.
    occluded: c_int,
    input_kind: c_int,
    button: c_int,
    delta_x: f64,
    delta_y: f64,
    key_text: [*]const u8,
    key_text_len: usize,
    input_text: [*]const u8,
    input_text_len: usize,
    has_composition_cursor: c_int,
    composition_cursor: usize,
    timer_id: u64,
    color_scheme: c_int,
    reduce_motion: c_int,
    high_contrast: c_int,
    /// Audio player report payload (`kind == .audio`): the report kind
    /// ordinal plus the live transport readout. `audio_buffering` is the
    /// honest stream-stall mirror (an un-paused stream waiting for
    /// bytes), distinct from `audio_playing` (the transport intent).
    audio_kind: c_int,
    audio_position_ms: u64,
    audio_duration_ms: u64,
    audio_playing: c_int,
    audio_buffering: c_int,
    /// SPECTRUM report payload: the 32 band magnitude bytes on the
    /// documented scale (log-spaced 50 Hz..16 kHz buckets, linear-in-dB
    /// from -60 dBFS at 0 to full scale at 255). Zeros elsewhere.
    audio_bands: [platform_mod.audio_spectrum_band_count]u8,
};

const WindowsCallback = *const fn (context: ?*anyopaque, event: *const WindowsEvent) callconv(.c) void;
const WindowsBridgeCallback = *const fn (context: ?*anyopaque, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void;

const shortcut_modifier_primary: u32 = 1 << 0;
const shortcut_modifier_command: u32 = 1 << 1;
const shortcut_modifier_control: u32 = 1 << 2;
const shortcut_modifier_option: u32 = 1 << 3;
const shortcut_modifier_shift: u32 = 1 << 4;

extern fn native_sdk_windows_create(app_name: [*]const u8, app_name_len: usize, window_title: [*]const u8, window_title_len: usize, bundle_id: [*]const u8, bundle_id_len: usize, icon_path: [*]const u8, icon_path_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int, resizable: c_int, titlebar_style: c_int, min_width: f64, min_height: f64) ?*WindowsHost;
extern fn native_sdk_windows_destroy(host: *WindowsHost) void;
extern fn native_sdk_windows_run(host: *WindowsHost, callback: WindowsCallback, context: ?*anyopaque) void;
extern fn native_sdk_windows_stop(host: *WindowsHost) void;
extern fn native_sdk_windows_wake(host: *WindowsHost) void;
extern fn native_sdk_windows_request_frame(host: *WindowsHost) void;
extern fn native_sdk_windows_decode_image(bytes: [*]const u8, bytes_len: usize, pixels: [*]u8, pixels_len: usize, out_width: *usize, out_height: *usize) c_int;
extern fn native_sdk_windows_load_webview(host: *WindowsHost, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn native_sdk_windows_load_window_webview(host: *WindowsHost, window_id: u64, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn native_sdk_windows_set_bridge_callback(host: *WindowsHost, callback: WindowsBridgeCallback, context: ?*anyopaque) void;
extern fn native_sdk_windows_bridge_respond(host: *WindowsHost, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_windows_bridge_respond_window(host: *WindowsHost, window_id: u64, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_windows_bridge_respond_webview(host: *WindowsHost, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_windows_emit_window_event(host: *WindowsHost, window_id: u64, name: [*]const u8, name_len: usize, detail_json: [*]const u8, detail_json_len: usize) void;
extern fn native_sdk_windows_set_security_policy(host: *WindowsHost, allowed_origins: [*]const u8, allowed_origins_len: usize, external_urls: [*]const u8, external_urls_len: usize, external_action: c_int) void;
extern fn native_sdk_windows_set_menus(host: *WindowsHost, menu_titles: [*]const [*]const u8, menu_title_lens: [*]const usize, menu_count: usize, item_menu_indices: [*]const u32, item_labels: [*]const [*]const u8, item_label_lens: [*]const usize, item_commands: [*]const [*]const u8, item_command_lens: [*]const usize, item_keys: [*]const [*]const u8, item_key_lens: [*]const usize, item_modifiers: [*]const u32, item_separators: [*]const c_int, item_enabled: [*]const c_int, item_checked: [*]const c_int, item_count: usize) void;
extern fn native_sdk_windows_set_shortcuts(host: *WindowsHost, ids: [*]const [*]const u8, id_lens: [*]const usize, keys: [*]const [*]const u8, key_lens: [*]const usize, modifiers: [*]const u32, count: usize) void;
extern fn native_sdk_windows_create_window(host: *WindowsHost, window_id: u64, window_title: [*]const u8, window_title_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int, resizable: c_int, titlebar_style: c_int, min_width: f64, min_height: f64) c_int;
extern fn native_sdk_windows_start_window_drag(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_set_window_drag_regions(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, rects: [*]const f64, exclusions: [*]const c_int, count: usize) c_int;
extern fn native_sdk_windows_window_chrome(host: *WindowsHost, window_id: u64, top: *f64, left: *f64, bottom: *f64, right: *f64, buttons_x: *f64, buttons_y: *f64, buttons_width: *f64, buttons_height: *f64) c_int;
extern fn native_sdk_windows_start_timer(host: *WindowsHost, timer_id: u64, interval_ns: u64, repeats: c_int) void;
extern fn native_sdk_windows_cancel_timer(host: *WindowsHost, timer_id: u64) void;
extern fn native_sdk_windows_focus_window(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_close_window(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_minimize_window(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_create_view(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, kind: c_int, parent: [*]const u8, parent_len: usize, x: f64, y: f64, width: f64, height: f64, layer: c_int, visible: c_int, enabled: c_int, role: [*]const u8, role_len: usize, accessibility_label: [*]const u8, accessibility_label_len: usize, text: [*]const u8, text_len: usize, command: [*]const u8, command_len: usize) c_int;
extern fn native_sdk_windows_update_view(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, has_frame: c_int, x: f64, y: f64, width: f64, height: f64, has_layer: c_int, layer: c_int, has_visible: c_int, visible: c_int, has_enabled: c_int, enabled: c_int, has_role: c_int, role: [*]const u8, role_len: usize, has_accessibility_label: c_int, accessibility_label: [*]const u8, accessibility_label_len: usize, has_text: c_int, text: [*]const u8, text_len: usize, has_command: c_int, command: [*]const u8, command_len: usize) c_int;
extern fn native_sdk_windows_set_view_frame(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, width: f64, height: f64) c_int;
extern fn native_sdk_windows_set_view_visible(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, visible: c_int) c_int;
extern fn native_sdk_windows_focus_view(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_close_view(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_request_gpu_surface_frame(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_note_gpu_surface_input(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_present_gpu_surface_pixels(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, width: usize, height: usize, scale: f64, has_dirty_rect: c_int, dirty_x: f64, dirty_y: f64, dirty_width: f64, dirty_height: f64, rgba8: [*]const u8, rgba8_len: usize) c_int;
extern fn native_sdk_windows_create_webview(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, url: [*]const u8, url_len: usize, x: f64, y: f64, width: f64, height: f64, layer: c_int, transparent: c_int, bridge_enabled: c_int) c_int;
extern fn native_sdk_windows_set_webview_frame(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, width: f64, height: f64) c_int;
extern fn native_sdk_windows_navigate_webview(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, url: [*]const u8, url_len: usize) c_int;
extern fn native_sdk_windows_set_webview_zoom(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, zoom: f64) c_int;
extern fn native_sdk_windows_set_webview_layer(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, layer: c_int) c_int;
extern fn native_sdk_windows_close_webview(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_open_external_url(host: *WindowsHost, url: [*]const u8, url_len: usize) c_int;
extern fn native_sdk_windows_reveal_path(host: *WindowsHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_windows_show_open_dialog(host: *WindowsHost, opts: *const WindowsOpenDialogOpts, buffer: [*]u8, buffer_len: usize) WindowsOpenDialogResult;
extern fn native_sdk_windows_show_save_dialog(host: *WindowsHost, opts: *const WindowsSaveDialogOpts, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_windows_show_message_dialog(host: *WindowsHost, opts: *const WindowsMessageDialogOpts) c_int;
extern fn native_sdk_windows_show_notification(host: *WindowsHost, title: [*]const u8, title_len: usize, subtitle: [*]const u8, subtitle_len: usize, body: [*]const u8, body_len: usize) c_int;
extern fn native_sdk_windows_create_tray(host: *WindowsHost, icon_path: [*]const u8, icon_path_len: usize, tooltip: [*]const u8, tooltip_len: usize) c_int;
extern fn native_sdk_windows_update_tray_menu(host: *WindowsHost, item_ids: [*]const u32, labels: [*]const [*]const u8, label_lens: [*]const usize, separators: [*]const c_int, enabled_flags: [*]const c_int, count: usize) c_int;
extern fn native_sdk_windows_remove_tray(host: *WindowsHost) void;
extern fn native_sdk_windows_add_recent_document(host: *WindowsHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_windows_clear_recent_documents(host: *WindowsHost) c_int;
extern fn native_sdk_windows_set_credential(host: *WindowsHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize, secret: [*]const u8, secret_len: usize) c_int;
extern fn native_sdk_windows_get_credential(host: *WindowsHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_windows_delete_credential(host: *WindowsHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize) c_int;
extern fn native_sdk_windows_clipboard_read(host: *WindowsHost, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_windows_clipboard_write(host: *WindowsHost, text: [*]const u8, text_len: usize) void;
extern fn native_sdk_windows_clipboard_read_data(host: *WindowsHost, mime_type: [*]const u8, mime_type_len: usize, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_windows_clipboard_write_data(host: *WindowsHost, mime_type: [*]const u8, mime_type_len: usize, bytes: [*]const u8, bytes_len: usize) c_int;
extern fn native_sdk_windows_audio_load(host: *WindowsHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_windows_audio_load_url(host: *WindowsHost, url: [*]const u8, url_len: usize, cache_path: [*]const u8, cache_path_len: usize, expected_bytes: u64) c_int;
extern fn native_sdk_windows_audio_play(host: *WindowsHost) c_int;
extern fn native_sdk_windows_audio_pause(host: *WindowsHost) c_int;
extern fn native_sdk_windows_audio_stop(host: *WindowsHost) c_int;
extern fn native_sdk_windows_audio_seek(host: *WindowsHost, position_ms: u64) c_int;
extern fn native_sdk_windows_audio_set_volume(host: *WindowsHost, volume: f64) c_int;
extern fn native_sdk_windows_audio_spectrum_supported(host: *WindowsHost) c_int;

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
        const host = native_sdk_windows_create(app_info.app_name.ptr, app_info.app_name.len, window_title.ptr, window_title.len, app_info.bundle_id.ptr, app_info.bundle_id.len, app_info.icon_path.ptr, app_info.icon_path.len, window_options.label.ptr, window_options.label.len, frame.x, frame.y, frame.width, frame.height, if (window_options.restore_state) 1 else 0, if (window_options.resizable) 1 else 0, titlebarStyleInt(window_options.titlebar), minSizeFloor(window_options.min_width), minSizeFloor(window_options.min_height)) orelse return error.CreateFailed;
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
        native_sdk_windows_destroy(self.host);
    }

    pub fn platform(self: *WindowsPlatform) platform_mod.Platform {
        return .{
            .context = self,
            .name = "windows",
            .surface_value = self.surface_value,
            .run_fn = run,
            .supports_fn = supportsFeature,
            .services = .{
                .context = self,
                .read_clipboard_fn = readClipboard,
                .write_clipboard_fn = writeClipboard,
                .read_clipboard_data_fn = readClipboardData,
                .write_clipboard_data_fn = writeClipboardData,
                .load_webview_fn = loadWebView,
                .load_window_webview_fn = loadWindowWebView,
                .complete_bridge_fn = completeBridge,
                .complete_window_bridge_fn = completeWindowBridge,
                .complete_webview_bridge_fn = completeWebViewBridge,
                .create_window_fn = createWindow,
                .focus_window_fn = focusWindow,
                .close_window_fn = closeWindow,
                .minimize_window_fn = minimizeWindow,
                .start_window_drag_fn = startWindowDrag,
                .set_window_drag_regions_fn = setWindowDragRegions,
                .window_chrome_fn = windowChrome,
                .create_view_fn = createView,
                .update_view_fn = updateView,
                .set_view_frame_fn = setViewFrame,
                .set_view_visible_fn = setViewVisible,
                .focus_view_fn = focusView,
                .close_view_fn = closeView,
                .request_gpu_surface_frame_fn = requestGpuSurfaceFrame,
                .note_gpu_surface_input_fn = noteGpuSurfaceInput,
                .present_gpu_surface_pixels_fn = presentGpuSurfacePixels,
                .create_webview_fn = createWebView,
                .set_webview_frame_fn = setWebViewFrame,
                .navigate_webview_fn = navigateWebView,
                .set_webview_zoom_fn = setWebViewZoom,
                .set_webview_layer_fn = setWebViewLayer,
                .close_webview_fn = closeWebView,
                .show_open_dialog_fn = showOpenDialog,
                .show_save_dialog_fn = showSaveDialog,
                .show_message_dialog_fn = showMessageDialog,
                .show_notification_fn = showNotification,
                .create_tray_fn = createTray,
                .update_tray_menu_fn = updateTrayMenu,
                .remove_tray_fn = removeTray,
                .open_external_url_fn = openExternalUrl,
                .reveal_path_fn = revealPath,
                .add_recent_document_fn = addRecentDocument,
                .clear_recent_documents_fn = clearRecentDocuments,
                .set_credential_fn = setCredential,
                .get_credential_fn = getCredential,
                .delete_credential_fn = deleteCredential,
                .audio_load_fn = audioLoad,
                .audio_load_url_fn = audioLoadUrl,
                .audio_play_fn = audioPlay,
                .audio_pause_fn = audioPause,
                .audio_stop_fn = audioStop,
                .audio_seek_fn = audioSeek,
                .audio_set_volume_fn = audioSetVolume,
                .configure_security_policy_fn = configureSecurityPolicy,
                .configure_menus_fn = configureMenus,
                .configure_shortcuts_fn = configureShortcuts,
                .emit_window_event_fn = emitWindowEvent,
                .start_timer_fn = startTimer,
                .cancel_timer_fn = cancelTimer,
                .wake_fn = wake,
                .request_frame_fn = requestFrame,
                .decode_image_fn = decodeImage,
            },
            .app_info = self.app_info,
        };
    }

    fn supportsFeature(context: *anyopaque, feature: platform_mod.PlatformFeature) bool {
        const self: *WindowsPlatform = @ptrCast(@alignCast(context));
        return switch (feature) {
            .main_webview,
            .child_webviews,
            .native_views,
            .native_control_commands,
            .menus,
            .tray,
            .shortcuts,
            .dialogs,
            .clipboard_text,
            .clipboard_rich_data,
            .open_url,
            .reveal_path,
            .notifications,
            .recent_documents,
            .credentials,
            .file_drops,
            .app_activation_events,
            .gpu_surfaces,
            .audio_playback,
            .audio_streaming,
            => self.web_engine == .system,
            // Spectrum analysis captures the app's OWN audio session
            // through process-scoped WASAPI loopback, which the OS grew
            // in Windows 10 2004 — the host probes the activation
            // support live instead of assuming the build.
            .audio_spectrum => self.web_engine == .system and audioSpectrumAvailable(self.host),
            // Native scroll drivers, native context menus, and app-owned
            // view-surface adoption are macOS-only today; Win32 keeps
            // the engine's wheel physics (TrackPopupMenu is the natural
            // future context-menu seam — the tray already uses it).
            .gpu_surface_scroll_drivers, .context_menus, .view_surface_adoption => false,
        };
    }

    /// Live probe for process-scoped loopback capture (the host asks
    /// the audio activation API rather than trusting a version check).
    /// Test builds link no Win32 host, so they answer the honest floor.
    fn audioSpectrumAvailable(host: *WindowsHost) bool {
        if (comptime @import("builtin").is_test) return false;
        if (@import("builtin").target.os.tag != .windows) return false;
        return native_sdk_windows_audio_spectrum_supported(host) != 0;
    }

    fn run(context: *anyopaque, handler: platform_mod.EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *WindowsPlatform = @ptrCast(@alignCast(context));
        self.state = .{
            .self = self,
            .handler = handler,
            .handler_context = handler_context,
        };
        native_sdk_windows_set_bridge_callback(self.host, windowsBridgeCallback, &self.state);
        native_sdk_windows_run(self.host, windowsCallback, &self.state);
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
            if (self.self) |windows| native_sdk_windows_stop(windows.host);
        };
    }
};

fn windowsCallback(context: ?*anyopaque, event: *const WindowsEvent) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    switch (event.kind) {
        .start => state.emit(.app_start),
        .frame => state.emit(.frame_requested),
        .shutdown => state.emit(.app_shutdown),
        .app_activated => state.emit(.app_activated),
        .app_deactivated => state.emit(.app_deactivated),
        .files_dropped => {
            var paths_buffer: [platform_mod.max_drop_paths][]const u8 = undefined;
            const paths = platform_mod.splitDropPaths(event.drop_paths[0..event.drop_paths_len], paths_buffer[0..]);
            state.emit(.{ .files_dropped = .{
                .window_id = event.window_id,
                .paths = paths,
            } });
        },
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
        .shortcut => state.emit(.{ .shortcut = .{
            .id = event.shortcut_id[0..event.shortcut_id_len],
            .key = event.shortcut_key[0..event.shortcut_key_len],
            .modifiers = shortcutModifiersFromFlags(event.shortcut_modifiers),
            .window_id = event.window_id,
        } }),
        .native_command => state.emit(.{ .native_command = .{
            .name = event.command_name[0..event.command_name_len],
            .window_id = event.window_id,
            .view_label = event.view_label[0..event.view_label_len],
        } }),
        .menu_command => state.emit(.{ .menu_command = .{
            .name = event.command_name[0..event.command_name_len],
            .window_id = event.window_id,
        } }),
        .tray_action => state.emit(.{ .tray_action = event.tray_item_id }),
        .gpu_surface_frame => state.emit(.{ .gpu_surface_frame = .{
            .window_id = event.window_id,
            .label = event.view_label[0..event.view_label_len],
            .size = geometry.SizeF.init(@floatCast(event.width), @floatCast(event.height)),
            .scale_factor = @floatCast(event.scale),
            .frame_index = event.frame_index,
            .timestamp_ns = event.timestamp_ns,
            .frame_interval_ns = event.frame_interval_ns,
            .nonblank = event.nonblank != 0,
            .sample_color = event.sample_color,
            .occluded = event.occluded != 0,
            .backend = .software,
            .pixel_format = .bgra8_unorm,
            .present_mode = .timer,
            .alpha_mode = .@"opaque",
            .color_space = .srgb,
            .vsync = true,
            .status = .ready,
        } }),
        .gpu_surface_resize => state.emit(.{ .gpu_surface_resized = .{
            .window_id = event.window_id,
            .label = event.view_label[0..event.view_label_len],
            .frame = geometry.RectF.init(@floatCast(event.x), @floatCast(event.y), @floatCast(event.width), @floatCast(event.height)),
            .scale_factor = @floatCast(event.scale),
        } }),
        .gpu_surface_input => state.emit(.{ .gpu_surface_input = gpuSurfaceInputEventFromWindowsEvent(event) }),
        .wake => state.emit(.wake),
        .timer => state.emit(.{ .timer = .{
            .id = event.timer_id,
            .timestamp_ns = event.timestamp_ns,
        } }),
        .appearance => state.emit(.{ .appearance_changed = .{
            .color_scheme = if (event.color_scheme == 1) .dark else .light,
            .reduce_motion = event.reduce_motion != 0,
            .high_contrast = event.high_contrast != 0,
        } }),
        .audio => state.emit(.{ .audio = .{
            .kind = audioEventKindFromInt(event.audio_kind),
            .position_ms = event.audio_position_ms,
            .duration_ms = event.audio_duration_ms,
            .playing = event.audio_playing != 0,
            .buffering = event.audio_buffering != 0,
            .bands = event.audio_bands,
        } }),
    }
}

/// Ordinals match the audio report kinds in webview2_host.cpp (the same
/// set the macOS host uses); anything unknown degrades to `.failed` so a
/// host/SDK skew is loud in the app instead of undefined behavior here.
fn audioEventKindFromInt(value: c_int) platform_mod.AudioEventKind {
    return switch (value) {
        0 => .loaded,
        1 => .position,
        2 => .completed,
        4 => .spectrum,
        else => .failed,
    };
}

fn gpuSurfaceInputEventFromWindowsEvent(event: *const WindowsEvent) platform_mod.GpuSurfaceInputEvent {
    return .{
        .window_id = event.window_id,
        .label = event.view_label[0..event.view_label_len],
        .kind = gpuSurfaceInputKindFromInt(event.input_kind),
        .timestamp_ns = event.timestamp_ns,
        .x = @floatCast(event.x),
        .y = @floatCast(event.y),
        .button = event.button,
        .delta_x = @floatCast(event.delta_x),
        .delta_y = @floatCast(event.delta_y),
        .key = event.key_text[0..event.key_text_len],
        .text = event.input_text[0..event.input_text_len],
        .composition_cursor = if (event.has_composition_cursor != 0) event.composition_cursor else null,
        .modifiers = shortcutModifiersFromFlags(event.shortcut_modifiers),
    };
}

fn gpuSurfaceInputKindFromInt(value: c_int) platform_mod.GpuSurfaceInputKind {
    return switch (value) {
        0 => .pointer_down,
        1 => .pointer_up,
        2 => .pointer_move,
        3 => .pointer_drag,
        4 => .scroll,
        5 => .key_down,
        6 => .key_up,
        7 => .text_input,
        8 => .ime_set_composition,
        9 => .ime_commit_composition,
        10 => .ime_cancel_composition,
        11 => .pointer_cancel,
        else => .pointer_move,
    };
}

fn windowsBridgeCallback(context: ?*anyopaque, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    state.emit(.{ .bridge_message = .{
        .bytes = message[0..message_len],
        .origin = origin[0..origin_len],
        .window_id = window_id,
        .webview_label = webview_label[0..webview_label_len],
    } });
}

fn readClipboard(context: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_windows_clipboard_read(self.host, buffer.ptr, buffer.len);
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

fn writeClipboard(context: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_clipboard_write(self.host, text.ptr, text.len);
}

fn readClipboardData(context: ?*anyopaque, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_windows_clipboard_read_data(self.host, mime_type.ptr, mime_type.len, buffer.ptr, buffer.len);
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

fn writeClipboardData(context: ?*anyopaque, data: platform_mod.ClipboardData) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_clipboard_write_data(self.host, data.mime_type.ptr, data.mime_type.len, data.bytes.ptr, data.bytes.len) == 0) return error.UnsupportedService;
}

fn loadWebView(context: ?*anyopaque, source: platform_mod.WebViewSource) anyerror!void {
    try loadWindowWebView(context, 1, source);
}

fn loadWindowWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, source: platform_mod.WebViewSource) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const assets: platform_mod.WebViewAssetSource = source.asset_options orelse .{ .root_path = "", .entry = "", .origin = "", .spa_fallback = false };
    native_sdk_windows_load_window_webview(
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
    native_sdk_windows_bridge_respond(self.host, response.ptr, response.len);
}

fn completeWindowBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, response: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_bridge_respond_window(self.host, window_id, response.ptr, response.len);
}

fn completeWebViewBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
    if (std.mem.eql(u8, webview_label, "main")) return completeWindowBridge(context, window_id, response);
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_bridge_respond_webview(self.host, window_id, webview_label.ptr, webview_label.len, response.ptr, response.len);
}

fn emitWindowEvent(context: ?*anyopaque, window_id: platform_mod.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_emit_window_event(self.host, window_id, name.ptr, name.len, detail_json.ptr, detail_json.len);
}

/// Thread-safe: `PostMessage` into the existing message loop, whose
/// window procedure emits `.wake` on the loop thread.
fn wake(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_wake(self.host);
}

/// Thread-safe like `wake`: `PostMessage` into the message loop, whose
/// window procedure emits one `.frame` event on the loop thread. The
/// automation arrival watcher calls this when a command lands so
/// consumption never depends on the host's own frame pump.
fn requestFrame(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_request_frame(self.host);
}

/// WIC-backed image decoding (PNG, JPEG, ... — every codec the OS
/// ships) into straight-alpha RGBA8.
fn decodeImage(context: ?*anyopaque, bytes: []const u8, buffer: []u8) anyerror!platform_mod.DecodedImage {
    _ = context;
    var width: usize = 0;
    var height: usize = 0;
    return switch (native_sdk_windows_decode_image(bytes.ptr, bytes.len, buffer.ptr, buffer.len, &width, &height)) {
        1 => .{ .width = width, .height = height, .rgba8 = buffer[0 .. width * height * 4] },
        -1 => error.ImageTooLarge,
        else => error.ImageDecodeFailed,
    };
}

fn titlebarStyleInt(style: platform_mod.WindowTitlebarStyle) c_int {
    return switch (style) {
        .standard => 0,
        .hidden_inset => 1,
        .hidden_inset_tall => 2,
        .chromeless => 3,
    };
}

/// Zero/negative/non-finite floors are the "no floor" sentinel (the
/// host leaves that axis at its natural minimum).
fn minSizeFloor(value: f32) f64 {
    return if (std.math.isFinite(value) and value > 0) value else 0;
}

fn createWindow(context: ?*anyopaque, options: platform_mod.WindowOptions) anyerror!platform_mod.WindowInfo {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const title = options.resolvedTitle(self.app_info.app_name);
    const frame = options.default_frame;
    if (native_sdk_windows_create_window(self.host, options.id, title.ptr, title.len, options.label.ptr, options.label.len, frame.x, frame.y, frame.width, frame.height, if (options.restore_state) 1 else 0, if (options.resizable) 1 else 0, titlebarStyleInt(options.titlebar), minSizeFloor(options.min_width), minSizeFloor(options.min_height)) == 0) return error.CreateFailed;
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
    if (native_sdk_windows_focus_window(self.host, window_id) == 0) return error.FocusFailed;
}

fn closeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_close_window(self.host, window_id) == 0) return error.CloseFailed;
}

fn minimizeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_minimize_window(self.host, window_id) == 0) return error.WindowNotFound;
}

fn startWindowDrag(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_start_window_drag(self.host, window_id) == 0) return error.WindowNotFound;
}

/// Drag-region mirror capacity per push: the runtime's own per-view cap
/// (`max_canvas_widget_window_drag_regions_per_view` = 32) bounds it in
/// practice; the flat buffers below are sized for that with headroom.
const max_drag_region_push: usize = 64;

/// Push the canvas view's window-drag region mirror to the host, which
/// answers `WM_NCHITTEST` with `HTCAPTION` inside a region (minus its
/// exclusions) so drag, double-click-maximize, and the right-click
/// system menu are the OS's own caption behavior on hidden-titlebar
/// windows.
fn setWindowDragRegions(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, regions: []const platform_mod.WindowDragRegion) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (regions.len > max_drag_region_push) return error.WindowLimitReached;
    var rects: [max_drag_region_push * 4]f64 = undefined;
    var exclusions: [max_drag_region_push]c_int = undefined;
    for (regions, 0..) |region, index| {
        rects[index * 4 + 0] = region.frame.x;
        rects[index * 4 + 1] = region.frame.y;
        rects[index * 4 + 2] = region.frame.width;
        rects[index * 4 + 3] = region.frame.height;
        exclusions[index] = if (region.exclusion) 1 else 0;
    }
    if (native_sdk_windows_set_window_drag_regions(self.host, window_id, label.ptr, label.len, &rects, &exclusions, regions.len) == 0) return error.ViewNotFound;
}

/// Chrome overlay geometry for hidden-titlebar windows: how far the
/// DWM-drawn caption-button band (top) and the min/max/close cluster
/// (trailing edge) overlay the content, plus the cluster's frame in
/// content coordinates — all in logical points. Standard-chrome windows
/// report zero.
fn windowChrome(context: ?*anyopaque, window_id: platform_mod.WindowId) platform_mod.WindowChrome {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    var top: f64 = 0;
    var left: f64 = 0;
    var bottom: f64 = 0;
    var right: f64 = 0;
    var buttons_x: f64 = 0;
    var buttons_y: f64 = 0;
    var buttons_width: f64 = 0;
    var buttons_height: f64 = 0;
    if (native_sdk_windows_window_chrome(self.host, window_id, &top, &left, &bottom, &right, &buttons_x, &buttons_y, &buttons_width, &buttons_height) == 0) return .{};
    return .{
        .insets = .{
            .top = @floatCast(top),
            .left = @floatCast(left),
            .bottom = @floatCast(bottom),
            .right = @floatCast(right),
        },
        .buttons = geometry.RectF.init(@floatCast(buttons_x), @floatCast(buttons_y), @floatCast(buttons_width), @floatCast(buttons_height)),
    };
}

fn startTimer(context: ?*anyopaque, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_start_timer(self.host, id, interval_ns, if (repeats) 1 else 0);
}

fn cancelTimer(context: ?*anyopaque, id: u64) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_cancel_timer(self.host, id);
}

fn createView(context: ?*anyopaque, options: platform_mod.ViewOptions) anyerror!void {
    if (options.kind == .webview) return createWebView(context, options.webViewOptions());
    if (!isSupportedNativeViewKind(options.kind)) return error.UnsupportedViewKind;
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const frame = options.frame;
    const parent = options.parent orelse "";
    if (native_sdk_windows_create_view(
        self.host,
        options.window_id,
        options.label.ptr,
        options.label.len,
        viewKindInt(options.kind),
        parent.ptr,
        parent.len,
        frame.x,
        frame.y,
        frame.width,
        frame.height,
        options.layer,
        if (options.visible) 1 else 0,
        if (options.enabled) 1 else 0,
        options.role.ptr,
        options.role.len,
        options.accessibility_label.ptr,
        options.accessibility_label.len,
        options.text.ptr,
        options.text.len,
        options.command.ptr,
        options.command.len,
    ) == 0) return error.CreateFailed;
}

fn updateView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, patch: platform_mod.ViewPatch) anyerror!void {
    if (patch.url != null) return error.InvalidViewOptions;
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const frame = patch.frame orelse geometry.RectF.init(0, 0, 0, 0);
    const role = patch.role orelse "";
    const accessibility_label = patch.accessibility_label orelse "";
    const text = patch.text orelse "";
    const command = patch.command orelse "";
    if (native_sdk_windows_update_view(
        self.host,
        window_id,
        label.ptr,
        label.len,
        if (patch.frame != null) 1 else 0,
        frame.x,
        frame.y,
        frame.width,
        frame.height,
        if (patch.layer != null) 1 else 0,
        patch.layer orelse 0,
        if (patch.visible != null) 1 else 0,
        if (patch.visible orelse false) 1 else 0,
        if (patch.enabled != null) 1 else 0,
        if (patch.enabled orelse false) 1 else 0,
        if (patch.role != null) 1 else 0,
        role.ptr,
        role.len,
        if (patch.accessibility_label != null) 1 else 0,
        accessibility_label.ptr,
        accessibility_label.len,
        if (patch.text != null) 1 else 0,
        text.ptr,
        text.len,
        if (patch.command != null) 1 else 0,
        command.ptr,
        command.len,
    ) == 0) return error.ViewNotFound;
}

fn setViewFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_windows_set_view_frame(self.host, window_id, label.ptr, label.len, frame.x, frame.y, frame.width, frame.height) == 0) return error.ViewNotFound;
}

fn setViewVisible(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, visible: bool) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_windows_set_view_visible(self.host, window_id, label.ptr, label.len, if (visible) 1 else 0) == 0) return error.ViewNotFound;
}

fn focusView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewFocus;
    if (native_sdk_windows_focus_view(self.host, window_id, label.ptr, label.len) == 0) return error.UnsupportedViewFocus;
}

fn closeView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_windows_close_view(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn requestGpuSurfaceFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_request_gpu_surface_frame(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn noteGpuSurfaceInput(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return;
    _ = native_sdk_windows_note_gpu_surface_input(self.host, window_id, label.ptr, label.len);
}

fn presentGpuSurfacePixels(context: ?*anyopaque, pixels: platform_mod.GpuSurfacePixels) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const dirty_bounds = if (pixels.dirty_bounds) |bounds| bounds.normalized() else geometry.RectF{};
    if (native_sdk_windows_present_gpu_surface_pixels(
        self.host,
        pixels.window_id,
        pixels.label.ptr,
        pixels.label.len,
        pixels.width,
        pixels.height,
        pixels.scale_factor,
        if (pixels.dirty_bounds != null) 1 else 0,
        dirty_bounds.x,
        dirty_bounds.y,
        dirty_bounds.width,
        dirty_bounds.height,
        pixels.rgba8.ptr,
        pixels.rgba8.len,
    ) == 0) return error.ViewNotFound;
}

fn createWebView(context: ?*anyopaque, options: platform_mod.WebViewOptions) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const frame = options.frame;
    if (native_sdk_windows_create_webview(self.host, options.window_id, options.label.ptr, options.label.len, options.url.ptr, options.url.len, frame.x, frame.y, frame.width, frame.height, options.layer, if (options.transparent) 1 else 0, if (options.bridge_enabled) 1 else 0) == 0) return error.CreateFailed;
}

fn setWebViewFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_set_webview_frame(self.host, window_id, label.ptr, label.len, frame.x, frame.y, frame.width, frame.height) == 0) return error.WebViewNotFound;
}

fn navigateWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, url: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (std.mem.eql(u8, label, "main")) return error.InvalidWebViewOptions;
    if (native_sdk_windows_navigate_webview(self.host, window_id, label.ptr, label.len, url.ptr, url.len) == 0) return error.WebViewNotFound;
}

fn setWebViewZoom(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, zoom: f64) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (std.mem.eql(u8, label, "main")) return error.UnsupportedMainWebViewZoom;
    if (native_sdk_windows_set_webview_zoom(self.host, window_id, label.ptr, label.len, zoom) == 0) return error.WebViewNotFound;
}

fn setWebViewLayer(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, layer: i32) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) {
        if (std.mem.eql(u8, label, "main")) return error.UnsupportedMainWebViewLayer;
        return error.UnsupportedChildWebViews;
    }
    if (native_sdk_windows_set_webview_layer(self.host, window_id, label.ptr, label.len, layer) == 0) return error.WebViewNotFound;
}

fn closeWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (std.mem.eql(u8, label, "main")) return error.InvalidWebViewOptions;
    if (native_sdk_windows_close_webview(self.host, window_id, label.ptr, label.len) == 0) return error.WebViewNotFound;
}

fn showOpenDialog(context: ?*anyopaque, options: platform_mod.OpenDialogOptions, buffer: []u8) anyerror!platform_mod.OpenDialogResult {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
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
    const result = native_sdk_windows_show_open_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (result.bytes_written > buffer.len) return error.NoSpaceLeft;
    return .{ .count = result.count, .paths = buffer[0..result.bytes_written] };
}

fn showSaveDialog(context: ?*anyopaque, options: platform_mod.SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
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
    const written = native_sdk_windows_show_save_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (written > buffer.len) return error.NoSpaceLeft;
    if (written == 0) return null;
    return buffer[0..written];
}

fn showMessageDialog(context: ?*anyopaque, options: platform_mod.MessageDialogOptions) anyerror!platform_mod.MessageDialogResult {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
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
    return @enumFromInt(native_sdk_windows_show_message_dialog(self.host, &opts));
}

fn showNotification(context: ?*anyopaque, options: platform_mod.NotificationOptions) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_show_notification(
        self.host,
        options.title.ptr,
        options.title.len,
        options.subtitle.ptr,
        options.subtitle.len,
        options.body.ptr,
        options.body.len,
    ) == 0) return error.UnsupportedService;
}

const max_tray_items: usize = 32;

fn createTray(context: ?*anyopaque, options: platform_mod.TrayOptions) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_create_tray(self.host, options.icon_path.ptr, options.icon_path.len, options.tooltip.ptr, options.tooltip.len) == 0) return error.UnsupportedService;
    if (options.items.len > 0) {
        try updateTrayMenu(context, options.items);
    }
}

fn updateTrayMenu(context: ?*anyopaque, items: []const platform_mod.TrayMenuItem) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const count = @min(items.len, max_tray_items);
    var ids: [max_tray_items]u32 = undefined;
    var labels: [max_tray_items][*]const u8 = undefined;
    var label_lens: [max_tray_items]usize = undefined;
    var separators: [max_tray_items]c_int = undefined;
    var enabled_flags: [max_tray_items]c_int = undefined;
    for (items[0..count], 0..) |item, index| {
        ids[index] = item.id;
        labels[index] = item.label.ptr;
        label_lens[index] = item.label.len;
        separators[index] = if (item.separator) 1 else 0;
        enabled_flags[index] = if (item.enabled) 1 else 0;
    }
    if (native_sdk_windows_update_tray_menu(self.host, &ids, &labels, &label_lens, &separators, &enabled_flags, count) == 0) return error.UnsupportedService;
}

fn removeTray(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    native_sdk_windows_remove_tray(self.host);
}

fn openExternalUrl(context: ?*anyopaque, url: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_open_external_url(self.host, url.ptr, url.len) == 0) return error.UnsupportedService;
}

fn revealPath(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_reveal_path(self.host, path.ptr, path.len) == 0) return error.UnsupportedService;
}

fn addRecentDocument(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_add_recent_document(self.host, path.ptr, path.len) == 0) return error.UnsupportedService;
}

fn clearRecentDocuments(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_clear_recent_documents(self.host) == 0) return error.UnsupportedService;
}

fn setCredential(context: ?*anyopaque, credential: platform_mod.Credential) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_set_credential(
        self.host,
        credential.service.ptr,
        credential.service.len,
        credential.account.ptr,
        credential.account.len,
        credential.secret.ptr,
        credential.secret.len,
    ) == 0) return error.UnsupportedService;
}

fn getCredential(context: ?*anyopaque, key: platform_mod.CredentialKey, buffer: []u8) anyerror![]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const len = native_sdk_windows_get_credential(
        self.host,
        key.service.ptr,
        key.service.len,
        key.account.ptr,
        key.account.len,
        buffer.ptr,
        buffer.len,
    );
    if (len == 0) return error.CredentialNotFound;
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

fn deleteCredential(context: ?*anyopaque, key: platform_mod.CredentialKey) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_delete_credential(
        self.host,
        key.service.ptr,
        key.service.len,
        key.account.ptr,
        key.account.len,
    ) == 0) return error.CredentialNotFound;
}

/// Map the audio host's synchronous load result: 0 loaded, 1 the file is
/// missing/unreadable, anything else a decode failure. The asynchronous
/// `.loaded` acknowledgment (with the decoded duration) follows as an
/// `.audio` event on the message loop.
fn audioLoad(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    return switch (native_sdk_windows_audio_load(self.host, path.ptr, path.len)) {
        0 => {},
        1 => error.AudioSourceNotFound,
        else => error.AudioDecodeFailed,
    };
}

/// Map the streaming host's synchronous result: 1 a verified cache entry
/// is playing locally, 0 a progressive stream started (the `.loaded`
/// acknowledgment follows when the topology is ready), anything else the
/// URL itself was unusable. Network failures after this point are
/// asynchronous and arrive as `.audio`/`.failed` events.
fn audioLoadUrl(context: ?*anyopaque, url: []const u8, cache_path: []const u8, expected_bytes: u64) anyerror!platform_mod.AudioLoadResolution {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    return switch (native_sdk_windows_audio_load_url(self.host, url.ptr, url.len, cache_path.ptr, cache_path.len, expected_bytes)) {
        0 => .stream,
        1 => .cache,
        else => error.InvalidAudioOptions,
    };
}

fn audioPlay(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_audio_play(self.host) == 0) return error.InvalidAudioOptions;
}

fn audioPause(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_windows_audio_pause(self.host);
}

fn audioStop(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_windows_audio_stop(self.host);
}

fn audioSeek(context: ?*anyopaque, position_ms: u64) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_audio_seek(self.host, position_ms) == 0) return error.InvalidAudioOptions;
}

fn audioSetVolume(context: ?*anyopaque, volume: f32) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_windows_audio_set_volume(self.host, volume);
}

fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    var origins_buffer: [4096]u8 = undefined;
    var external_buffer: [4096]u8 = undefined;
    const origins = try policy_values.join(policy.navigation.allowed_origins, &origins_buffer);
    const external_urls = try policy_values.join(policy.navigation.external_links.allowed_urls, &external_buffer);
    native_sdk_windows_set_security_policy(
        self.host,
        origins.ptr,
        origins.len,
        external_urls.ptr,
        external_urls.len,
        @intFromEnum(policy.navigation.external_links.action),
    );
}

fn configureMenus(context: ?*anyopaque, menus: []const platform_mod.Menu) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    try platform_mod.validateMenus(menus);
    if (menus.len > 0 and self.web_engine != .system) return error.UnsupportedService;

    var menu_titles: [platform_mod.max_menus][*]const u8 = undefined;
    var menu_title_lens: [platform_mod.max_menus]usize = undefined;
    var item_menu_indices: [platform_mod.max_menu_items]u32 = undefined;
    var item_labels: [platform_mod.max_menu_items][*]const u8 = undefined;
    var item_label_lens: [platform_mod.max_menu_items]usize = undefined;
    var item_commands: [platform_mod.max_menu_items][*]const u8 = undefined;
    var item_command_lens: [platform_mod.max_menu_items]usize = undefined;
    var item_keys: [platform_mod.max_menu_items][*]const u8 = undefined;
    var item_key_lens: [platform_mod.max_menu_items]usize = undefined;
    var item_modifiers: [platform_mod.max_menu_items]u32 = undefined;
    var item_separators: [platform_mod.max_menu_items]c_int = undefined;
    var item_enabled: [platform_mod.max_menu_items]c_int = undefined;
    var item_checked: [platform_mod.max_menu_items]c_int = undefined;

    var item_count: usize = 0;
    for (menus, 0..) |menu, menu_index| {
        menu_titles[menu_index] = menu.title.ptr;
        menu_title_lens[menu_index] = menu.title.len;
        for (menu.items) |item| {
            item_menu_indices[item_count] = @intCast(menu_index);
            item_labels[item_count] = item.label.ptr;
            item_label_lens[item_count] = item.label.len;
            item_commands[item_count] = item.command.ptr;
            item_command_lens[item_count] = item.command.len;
            item_keys[item_count] = item.key.ptr;
            item_key_lens[item_count] = item.key.len;
            item_modifiers[item_count] = shortcutModifierFlags(item.modifiers);
            item_separators[item_count] = if (item.separator) 1 else 0;
            item_enabled[item_count] = if (item.enabled) 1 else 0;
            item_checked[item_count] = if (item.checked) 1 else 0;
            item_count += 1;
        }
    }

    native_sdk_windows_set_menus(
        self.host,
        menu_titles[0..menus.len].ptr,
        menu_title_lens[0..menus.len].ptr,
        menus.len,
        item_menu_indices[0..item_count].ptr,
        item_labels[0..item_count].ptr,
        item_label_lens[0..item_count].ptr,
        item_commands[0..item_count].ptr,
        item_command_lens[0..item_count].ptr,
        item_keys[0..item_count].ptr,
        item_key_lens[0..item_count].ptr,
        item_modifiers[0..item_count].ptr,
        item_separators[0..item_count].ptr,
        item_enabled[0..item_count].ptr,
        item_checked[0..item_count].ptr,
        item_count,
    );
}

fn configureShortcuts(context: ?*anyopaque, shortcuts: []const platform_mod.Shortcut) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (shortcuts.len > platform_mod.max_shortcuts) return error.InvalidShortcut;
    var ids: [platform_mod.max_shortcuts][*]const u8 = undefined;
    var id_lens: [platform_mod.max_shortcuts]usize = undefined;
    var keys: [platform_mod.max_shortcuts][*]const u8 = undefined;
    var key_lens: [platform_mod.max_shortcuts]usize = undefined;
    var modifiers: [platform_mod.max_shortcuts]u32 = undefined;
    for (shortcuts, 0..) |shortcut, index| {
        try platform_mod.validateShortcut(shortcut);
        ids[index] = shortcut.id.ptr;
        id_lens[index] = shortcut.id.len;
        keys[index] = shortcut.key.ptr;
        key_lens[index] = shortcut.key.len;
        modifiers[index] = shortcutModifierFlags(shortcut.modifiers);
    }
    native_sdk_windows_set_shortcuts(self.host, ids[0..shortcuts.len].ptr, id_lens[0..shortcuts.len].ptr, keys[0..shortcuts.len].ptr, key_lens[0..shortcuts.len].ptr, modifiers[0..shortcuts.len].ptr, shortcuts.len);
}

fn shortcutModifierFlags(modifiers: platform_mod.ShortcutModifiers) u32 {
    var flags: u32 = 0;
    if (modifiers.primary) flags |= shortcut_modifier_primary;
    if (modifiers.command) flags |= shortcut_modifier_command;
    if (modifiers.control) flags |= shortcut_modifier_control;
    if (modifiers.option) flags |= shortcut_modifier_option;
    if (modifiers.shift) flags |= shortcut_modifier_shift;
    return flags;
}

fn shortcutModifiersFromFlags(flags: u32) platform_mod.ShortcutModifiers {
    return .{
        .primary = (flags & shortcut_modifier_primary) != 0,
        .command = (flags & shortcut_modifier_command) != 0,
        .control = (flags & shortcut_modifier_control) != 0,
        .option = (flags & shortcut_modifier_option) != 0,
        .shift = (flags & shortcut_modifier_shift) != 0,
    };
}

fn isSupportedNativeViewKind(kind: platform_mod.ViewKind) bool {
    return switch (kind) {
        .toolbar,
        .titlebar_accessory,
        .sidebar,
        .statusbar,
        .split,
        .stack,
        .button,
        .icon_button,
        .list_item,
        .checkbox,
        .toggle,
        .segmented_control,
        .text_field,
        .search_field,
        .label,
        .spacer,
        .progress_indicator,
        .gpu_surface,
        => true,
        .webview,
        => false,
    };
}

test "windows supports native container and control kinds" {
    try std.testing.expect(isSupportedNativeViewKind(.split));
    try std.testing.expect(isSupportedNativeViewKind(.stack));
    try std.testing.expect(isSupportedNativeViewKind(.icon_button));
    try std.testing.expect(isSupportedNativeViewKind(.list_item));
    try std.testing.expect(isSupportedNativeViewKind(.gpu_surface));
}

test "windows gpu surface input preserves key and text" {
    const label = "canvas";
    const key = "enter";
    const text = "\n";
    var event = std.mem.zeroes(WindowsEvent);
    event.window_id = 7;
    event.view_label = label.ptr;
    event.view_label_len = label.len;
    event.input_kind = 5;
    event.timestamp_ns = 123_000_000;
    event.x = 12;
    event.y = 18;
    event.button = 1;
    event.delta_x = -2;
    event.delta_y = 4;
    event.key_text = key.ptr;
    event.key_text_len = key.len;
    event.input_text = text.ptr;
    event.input_text_len = text.len;
    event.shortcut_modifiers = shortcut_modifier_primary | shortcut_modifier_shift;

    const input = gpuSurfaceInputEventFromWindowsEvent(&event);
    try std.testing.expectEqual(@as(platform_mod.WindowId, 7), input.window_id);
    try std.testing.expectEqualStrings("canvas", input.label);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.key_down, input.kind);
    try std.testing.expectEqual(@as(u64, 123_000_000), input.timestamp_ns);
    try std.testing.expectEqual(@as(f32, 12), input.x);
    try std.testing.expectEqual(@as(f32, 18), input.y);
    try std.testing.expectEqual(@as(i32, 1), input.button);
    try std.testing.expectEqual(@as(f32, -2), input.delta_x);
    try std.testing.expectEqual(@as(f32, 4), input.delta_y);
    try std.testing.expectEqualStrings("enter", input.key);
    try std.testing.expectEqualStrings("\n", input.text);
    try std.testing.expect(input.modifiers.primary);
    try std.testing.expect(input.modifiers.shift);
}

test "windows gpu surface input maps pointer cancel" {
    var event = std.mem.zeroes(WindowsEvent);
    event.input_kind = 11;
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.pointer_cancel, gpuSurfaceInputEventFromWindowsEvent(&event).kind);
}

test "windows gpu surface input maps ime text and composition events" {
    // A GCS_COMPSTR preedit update: kind 8 carries the full preedit text
    // plus a UTF-8 byte cursor (the host converts GCS_CURSORPOS UTF-16
    // units into bytes before emitting).
    const preedit = "\xe3\x81\x8b\xe3\x82\x99"; // "か" + combining voiced mark
    var set_event = std.mem.zeroes(WindowsEvent);
    set_event.input_kind = 8;
    set_event.input_text = preedit.ptr;
    set_event.input_text_len = preedit.len;
    set_event.has_composition_cursor = 1;
    set_event.composition_cursor = 3;
    const set_input = gpuSurfaceInputEventFromWindowsEvent(&set_event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.ime_set_composition, set_input.kind);
    try std.testing.expectEqualStrings(preedit, set_input.text);
    try std.testing.expectEqual(@as(?usize, 3), set_input.composition_cursor);

    // A GCS_RESULTSTR commit that differs from the preedit arrives as a
    // plain text_input with no cursor (the cancel travelled separately).
    var text_event = std.mem.zeroes(WindowsEvent);
    text_event.input_kind = 7;
    const committed = "が";
    text_event.input_text = committed.ptr;
    text_event.input_text_len = committed.len;
    const text_input = gpuSurfaceInputEventFromWindowsEvent(&text_event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.text_input, text_input.kind);
    try std.testing.expectEqualStrings(committed, text_input.text);
    try std.testing.expectEqual(@as(?usize, null), text_input.composition_cursor);

    // Commit-of-preedit and cancel are empty-text notifications: the
    // runtime already buffers the composition text.
    var commit_event = std.mem.zeroes(WindowsEvent);
    commit_event.input_kind = 9;
    const commit_input = gpuSurfaceInputEventFromWindowsEvent(&commit_event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.ime_commit_composition, commit_input.kind);
    try std.testing.expectEqual(@as(usize, 0), commit_input.text.len);
    try std.testing.expectEqual(@as(?usize, null), commit_input.composition_cursor);

    var cancel_event = std.mem.zeroes(WindowsEvent);
    cancel_event.input_kind = 10;
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.ime_cancel_composition, gpuSurfaceInputEventFromWindowsEvent(&cancel_event).kind);
}

test "windows chromium reports unsupported native surfaces" {
    var system = testPlatformWithEngine(.system);
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .main_webview));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .child_webviews));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .native_views));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .native_control_commands));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .menus));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .gpu_surfaces));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .audio_playback));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .audio_streaming));

    var chromium = testPlatformWithEngine(.chromium);
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .main_webview));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .child_webviews));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .native_views));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .native_control_commands));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .menus));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .shortcuts));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .gpu_surfaces));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .audio_playback));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .audio_streaming));
}

test "windows audio event maps kinds and payload" {
    var event = std.mem.zeroes(WindowsEvent);
    event.audio_kind = 1;
    event.audio_position_ms = 1_500;
    event.audio_duration_ms = 120_000;
    event.audio_playing = 1;
    event.audio_buffering = 1;
    try std.testing.expectEqual(platform_mod.AudioEventKind.position, audioEventKindFromInt(event.audio_kind));
    try std.testing.expectEqual(platform_mod.AudioEventKind.loaded, audioEventKindFromInt(0));
    try std.testing.expectEqual(platform_mod.AudioEventKind.completed, audioEventKindFromInt(2));
    // Unknown ordinals degrade loudly to failed, never to silence.
    try std.testing.expectEqual(platform_mod.AudioEventKind.failed, audioEventKindFromInt(3));
    try std.testing.expectEqual(platform_mod.AudioEventKind.failed, audioEventKindFromInt(99));
}

fn testPlatformWithEngine(web_engine: platform_mod.WebEngine) WindowsPlatform {
    return .{
        .host = undefined,
        .web_engine = web_engine,
        .app_info = .{},
        .surface_value = .{},
    };
}

fn viewKindInt(kind: platform_mod.ViewKind) c_int {
    return switch (kind) {
        .webview => 0,
        .toolbar => 1,
        .titlebar_accessory => 2,
        .sidebar => 3,
        .statusbar => 4,
        .split => 5,
        .stack => 6,
        .button => 7,
        .icon_button => 17,
        .list_item => 18,
        .text_field => 8,
        .search_field => 9,
        .label => 10,
        .spacer => 11,
        .gpu_surface => 12,
        .checkbox => 13,
        .toggle => 14,
        .progress_indicator => 15,
        .segmented_control => 16,
    };
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
