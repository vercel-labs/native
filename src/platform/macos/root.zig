const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const platform_mod = @import("../root.zig");
const policy_values = @import("../policy_values.zig");
const security = @import("../../security/root.zig");
// The packaging pipeline's one-image icon machinery: dev runs borrow its
// macOS mask/inset render so the Dock tile matches `native package`.
const app_icon = @import("canvas").app_icon;

pub const Error = error{
    CallbackFailed,
    CreateFailed,
    FocusFailed,
    CloseFailed,
};

const AppKitHost = opaque {};

const AppKitEventKind = enum(c_int) {
    start = 0,
    frame = 1,
    shutdown = 2,
    resize = 3,
    window_frame = 4,
    shortcut = 5,
    native_command = 6,
    menu_command = 7,
    app_activated = 8,
    app_deactivated = 9,
    files_dropped = 10,
    gpu_surface_frame = 11,
    gpu_surface_resize = 12,
    gpu_surface_input = 13,
    widget_accessibility_action = 14,
    appearance_changed = 15,
    timer = 16,
    wake = 17,
    gpu_surface_scroll_driver = 18,
    context_menu_action = 19,
    audio = 20,
};

const AppKitEvent = extern struct {
    kind: AppKitEventKind,
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
    shortcut_id: [*]const u8,
    shortcut_id_len: usize,
    shortcut_key: [*]const u8,
    shortcut_key_len: usize,
    shortcut_modifiers: u32,
    command_name: [*]const u8,
    command_name_len: usize,
    view_label: [*]const u8,
    view_label_len: usize,
    key_text: [*]const u8,
    key_text_len: usize,
    input_text: [*]const u8,
    input_text_len: usize,
    drop_paths: [*]const u8,
    drop_paths_len: usize,
    frame_index: u64,
    timestamp_ns: u64,
    frame_interval_ns: u64,
    nonblank: c_int,
    sample_color: u32,
    input_kind: c_int,
    button: c_int,
    delta_x: f64,
    delta_y: f64,
    widget_id: u64,
    widget_action: c_int,
    widget_text: [*]const u8,
    widget_text_len: usize,
    has_widget_text_selection: c_int,
    widget_text_selection_start: usize,
    widget_text_selection_end: usize,
    has_composition_cursor: c_int,
    composition_cursor: usize,
    color_scheme: c_int,
    reduce_motion: c_int,
    high_contrast: c_int,
    timer_id: u64,
    scroll_driver_offset_y: f64,
    menu_item_id: u32,
    /// Host-stamped packet decode/draw durations riding the frame
    /// event (0 when no packet present happened since the last one).
    packet_decode_ns: u64,
    packet_draw_ns: u64,
    /// Nonzero when the frame completed logically while the window was
    /// occluded (no glass flip; heartbeat pacing) — its timestamp is
    /// pacing policy, never a latency measurement endpoint.
    occluded: c_int,
    /// Audio player report payload (`kind == .audio`): the
    /// `AudioEventKind` ordinal plus the player's position/duration
    /// readout at emit time.
    audio_kind: c_int,
    audio_position_ms: u64,
    audio_duration_ms: u64,
    audio_playing: c_int,
    /// Nonzero while a streamed source is stalled waiting for network
    /// bytes (distinct from `audio_playing`, the transport intent).
    audio_buffering: c_int,
    /// SPECTRUM report payload: the 32 band magnitude bytes on the
    /// documented scale (log-spaced 50 Hz..16 kHz buckets, linear-in-dB
    /// from -60 dBFS at 0 to full scale at 255). Zeros elsewhere.
    audio_bands: [platform_mod.audio_spectrum_band_count]u8,
};

const AppKitCallback = *const fn (context: ?*anyopaque, event: *const AppKitEvent) callconv(.c) void;
const AppKitBridgeCallback = *const fn (context: ?*anyopaque, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void;

const shortcut_modifier_primary: u32 = 1 << 0;
const shortcut_modifier_command: u32 = 1 << 1;
const shortcut_modifier_control: u32 = 1 << 2;
const shortcut_modifier_option: u32 = 1 << 3;
const shortcut_modifier_shift: u32 = 1 << 4;

extern fn native_sdk_appkit_create(app_name: [*]const u8, app_name_len: usize, display_name: [*]const u8, display_name_len: usize, version: [*]const u8, version_len: usize, about_description: [*]const u8, about_description_len: usize, has_web_content: c_int, window_title: [*]const u8, window_title_len: usize, bundle_id: [*]const u8, bundle_id_len: usize, icon_path: [*]const u8, icon_path_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int, resizable: c_int, titlebar_style: c_int, show_policy: c_int) ?*AppKitHost;
extern fn native_sdk_appkit_destroy(host: *AppKitHost) void;
extern fn native_sdk_appkit_set_dock_icon_rgba(host: *AppKitHost, pixels: [*]const u8, width: usize, height: usize) void;
extern fn native_sdk_appkit_set_dock_icon_file(host: *AppKitHost, path: [*]const u8, path_len: usize) void;
extern fn native_sdk_appkit_run(host: *AppKitHost, callback: AppKitCallback, context: ?*anyopaque) void;
extern fn native_sdk_appkit_stop(host: *AppKitHost) void;
extern fn native_sdk_appkit_load_webview(host: *AppKitHost, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn native_sdk_appkit_load_window_webview(host: *AppKitHost, window_id: u64, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn native_sdk_appkit_set_bridge_callback(host: *AppKitHost, callback: AppKitBridgeCallback, context: ?*anyopaque) void;
extern fn native_sdk_appkit_bridge_respond(host: *AppKitHost, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_appkit_bridge_respond_window(host: *AppKitHost, window_id: u64, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_appkit_bridge_respond_webview(host: *AppKitHost, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_appkit_emit_window_event(host: *AppKitHost, window_id: u64, name: [*]const u8, name_len: usize, detail_json: [*]const u8, detail_json_len: usize) void;
extern fn native_sdk_appkit_set_security_policy(host: *AppKitHost, allowed_origins: [*]const u8, allowed_origins_len: usize, external_urls: [*]const u8, external_urls_len: usize, external_action: c_int) void;
extern fn native_sdk_appkit_set_menus(host: *AppKitHost, menu_titles: [*]const [*]const u8, menu_title_lens: [*]const usize, menu_count: usize, item_menu_indices: [*]const u32, item_labels: [*]const [*]const u8, item_label_lens: [*]const usize, item_commands: [*]const [*]const u8, item_command_lens: [*]const usize, item_keys: [*]const [*]const u8, item_key_lens: [*]const usize, item_modifiers: [*]const u32, item_separators: [*]const c_int, item_enabled: [*]const c_int, item_checked: [*]const c_int, item_count: usize) void;
extern fn native_sdk_appkit_set_shortcuts(host: *AppKitHost, ids: [*]const [*]const u8, id_lens: [*]const usize, keys: [*]const [*]const u8, key_lens: [*]const usize, modifiers: [*]const u32, count: usize) void;
extern fn native_sdk_appkit_request_frame(host: *AppKitHost) void;
extern fn native_sdk_appkit_create_window(host: *AppKitHost, window_id: u64, window_title: [*]const u8, window_title_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int, resizable: c_int, titlebar_style: c_int, show_policy: c_int) c_int;
extern fn native_sdk_appkit_set_window_content_min_size(host: *AppKitHost, window_id: u64, min_width: f64, min_height: f64) c_int;
extern fn native_sdk_appkit_focus_window(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_close_window(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_minimize_window(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_start_window_drag(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_window_chrome_insets(host: *AppKitHost, window_id: u64, top: *f64, left: *f64, bottom: *f64, right: *f64, buttons_x: *f64, buttons_y: *f64, buttons_width: *f64, buttons_height: *f64) c_int;
extern fn native_sdk_appkit_create_view(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, kind: c_int, parent: [*]const u8, parent_len: usize, x: f64, y: f64, width: f64, height: f64, layer: c_int, visible: c_int, enabled: c_int, role: [*]const u8, role_len: usize, accessibility_label: [*]const u8, accessibility_label_len: usize, text: [*]const u8, text_len: usize, command: [*]const u8, command_len: usize) c_int;
extern fn native_sdk_appkit_update_view(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, has_frame: c_int, x: f64, y: f64, width: f64, height: f64, has_layer: c_int, layer: c_int, has_visible: c_int, visible: c_int, has_enabled: c_int, enabled: c_int, has_role: c_int, role: [*]const u8, role_len: usize, has_accessibility_label: c_int, accessibility_label: [*]const u8, accessibility_label_len: usize, has_text: c_int, text: [*]const u8, text_len: usize, has_command: c_int, command: [*]const u8, command_len: usize) c_int;
extern fn native_sdk_appkit_set_view_frame(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, width: f64, height: f64) c_int;
extern fn native_sdk_appkit_set_view_visible(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, visible: c_int) c_int;
extern fn native_sdk_appkit_set_view_cursor(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, cursor: c_int) c_int;
extern fn native_sdk_appkit_focus_view(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_close_view(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_adopt_view_surface(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, ns_view: *anyopaque) c_int;
extern fn native_sdk_appkit_release_view_surface(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_request_gpu_surface_frame(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_note_gpu_surface_input(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_set_gpu_surface_scroll_drivers(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, drivers: [*]const AppKitScrollDriver, count: usize) c_int;
extern fn native_sdk_appkit_show_context_menu(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, token: u64, items: [*]const AppKitContextMenuItem, count: usize) c_int;
extern fn native_sdk_appkit_start_timer(host: *AppKitHost, timer_id: u64, interval_ns: u64, repeats: c_int) void;
extern fn native_sdk_appkit_cancel_timer(host: *AppKitHost, timer_id: u64) void;
extern fn native_sdk_appkit_audio_load(host: *AppKitHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_appkit_audio_load_url(host: *AppKitHost, url: [*]const u8, url_len: usize, cache_path: [*]const u8, cache_path_len: usize, expected_bytes: u64) c_int;
extern fn native_sdk_appkit_audio_play(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_audio_pause(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_audio_stop(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_audio_seek(host: *AppKitHost, position_ms: u64) c_int;
extern fn native_sdk_appkit_audio_set_volume(host: *AppKitHost, volume: f64) c_int;
extern fn native_sdk_appkit_wake(host: *AppKitHost) void;
extern fn native_sdk_appkit_present_gpu_surface_pixels(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, width: usize, height: usize, scale: f64, has_dirty_rect: c_int, dirty_x: f64, dirty_y: f64, dirty_width: f64, dirty_height: f64, rgba8: [*]const u8, rgba8_len: usize) c_int;
extern fn native_sdk_appkit_present_gpu_surface_packet(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, surface_width: f64, surface_height: f64, scale: f64, clear_r: u8, clear_g: u8, clear_b: u8, clear_a: u8, requires_render: c_int, command_count: usize, unsupported_command_count: usize, representable: c_int, json: [*]const u8, json_len: usize) c_int;
extern fn native_sdk_appkit_present_gpu_surface_packet_binary(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, surface_width: f64, surface_height: f64, scale: f64, clear_r: u8, clear_g: u8, clear_b: u8, clear_a: u8, requires_render: c_int, command_count: usize, unsupported_command_count: usize, representable: c_int, packet: [*]const u8, packet_len: usize) c_int;
extern fn native_sdk_appkit_upload_gpu_surface_image(host: *AppKitHost, image_id: u64, width: usize, height: usize, rgba8: [*]const u8, rgba8_len: usize) c_int;
extern fn native_sdk_appkit_remove_gpu_surface_image(host: *AppKitHost, image_id: u64) c_int;
extern fn native_sdk_appkit_update_widget_accessibility(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, nodes: [*]const AppKitWidgetAccessibilityNode, node_count: usize) c_int;
extern fn native_sdk_appkit_create_webview(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, url: [*]const u8, url_len: usize, x: f64, y: f64, width: f64, height: f64, layer: c_int, transparent: c_int, bridge_enabled: c_int) c_int;
extern fn native_sdk_appkit_set_webview_frame(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, width: f64, height: f64) c_int;
extern fn native_sdk_appkit_navigate_webview(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, url: [*]const u8, url_len: usize) c_int;
extern fn native_sdk_appkit_set_webview_zoom(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, zoom: f64) c_int;
extern fn native_sdk_appkit_set_webview_layer(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, layer: c_int) c_int;
extern fn native_sdk_appkit_close_webview(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_clipboard_read(host: *AppKitHost, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_appkit_measure_text(font_id: u64, size: f64, text: [*]const u8, text_len: usize) f64;
extern fn native_sdk_appkit_measure_text_advances(font_id: u64, size: f64, text: [*]const u8, text_len: usize, advances: [*]f32) c_int;
extern fn native_sdk_appkit_register_font(font_id: u64, bytes: [*]const u8, bytes_len: usize) c_int;
extern fn native_sdk_appkit_register_bundled_fonts() void;
extern fn native_sdk_appkit_decode_image(bytes: [*]const u8, bytes_len: usize, pixels: [*]u8, pixels_len: usize, out_width: *usize, out_height: *usize) c_int;
extern fn native_sdk_appkit_clipboard_write(host: *AppKitHost, text: [*]const u8, text_len: usize) void;
extern fn native_sdk_appkit_clipboard_read_data(host: *AppKitHost, mime_type: [*]const u8, mime_type_len: usize, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_appkit_clipboard_write_data(host: *AppKitHost, mime_type: [*]const u8, mime_type_len: usize, bytes: [*]const u8, bytes_len: usize) c_int;
extern fn native_sdk_appkit_show_notification(host: *AppKitHost, title: [*]const u8, title_len: usize, subtitle: [*]const u8, subtitle_len: usize, body: [*]const u8, body_len: usize) c_int;
extern fn native_sdk_appkit_open_external_url(host: *AppKitHost, url: [*]const u8, url_len: usize) c_int;
extern fn native_sdk_appkit_reveal_path(host: *AppKitHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_appkit_add_recent_document(host: *AppKitHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_appkit_clear_recent_documents(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_set_credential(host: *AppKitHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize, secret: [*]const u8, secret_len: usize) c_int;
extern fn native_sdk_appkit_get_credential(host: *AppKitHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_appkit_delete_credential(host: *AppKitHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize) c_int;

const AppKitScrollDriver = extern struct {
    driver_id: u64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    content_width: f64,
    content_height: f64,
    offset_y: f64,
    set_offset: c_int,
    rubber_band: c_int,
};

const AppKitContextMenuItem = extern struct {
    item_id: u32,
    label: [*]const u8,
    label_len: usize,
    enabled: c_int,
    separator: c_int,
};

const AppKitOpenDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
    allow_directories: c_int,
    allow_multiple: c_int,
};

const AppKitOpenDialogResult = extern struct {
    count: usize,
    bytes_written: usize,
};

const AppKitSaveDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    default_name: [*]const u8,
    default_name_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
};

const AppKitMessageDialogOpts = extern struct {
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

const AppKitWidgetAccessibilityNode = extern struct {
    id: u64,
    role: c_int,
    label: [*]const u8,
    label_len: usize,
    text_value: [*]const u8,
    text_value_len: usize,
    placeholder: [*]const u8,
    placeholder_len: usize,
    has_text_selection: c_int,
    text_selection_start: usize,
    text_selection_end: usize,
    has_text_composition: c_int,
    text_composition_start: usize,
    text_composition_end: usize,
    has_value: c_int,
    value: f64,
    has_grid_row_index: c_int,
    grid_row_index: usize,
    has_grid_column_index: c_int,
    grid_column_index: usize,
    has_grid_row_count: c_int,
    grid_row_count: usize,
    has_grid_column_count: c_int,
    grid_column_count: usize,
    has_list_item_index: c_int,
    list_item_index: u32,
    has_list_item_count: c_int,
    list_item_count: u32,
    has_scroll_offset: c_int,
    scroll_offset: f64,
    has_scroll_viewport_extent: c_int,
    scroll_viewport_extent: f64,
    has_scroll_content_extent: c_int,
    scroll_content_extent: f64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    state_flags: u32,
    action_flags: u32,
};

const widget_state_enabled: u32 = 1 << 0;
const widget_state_focused: u32 = 1 << 1;
const widget_state_selected: u32 = 1 << 2;
const widget_state_pressed: u32 = 1 << 3;
const widget_state_expanded: u32 = 1 << 4;
const widget_state_collapsed: u32 = 1 << 5;
const widget_state_required: u32 = 1 << 6;
const widget_state_read_only: u32 = 1 << 7;
const widget_state_invalid: u32 = 1 << 8;
const widget_action_focus: u32 = 1 << 0;
const widget_action_press: u32 = 1 << 1;
const widget_action_toggle: u32 = 1 << 2;
const widget_action_increment: u32 = 1 << 3;
const widget_action_decrement: u32 = 1 << 4;
const widget_action_set_text: u32 = 1 << 5;
const widget_action_set_selection: u32 = 1 << 6;
const widget_action_select: u32 = 1 << 7;
const widget_action_drag: u32 = 1 << 8;
const widget_action_drop_files: u32 = 1 << 9;
const widget_action_dismiss: u32 = 1 << 10;

const AppKitTrayCallback = *const fn (context: ?*anyopaque, item_id: u32) callconv(.c) void;

extern fn native_sdk_appkit_show_open_dialog(host: *AppKitHost, opts: *const AppKitOpenDialogOpts, buffer: [*]u8, buffer_len: usize) AppKitOpenDialogResult;
extern fn native_sdk_appkit_show_save_dialog(host: *AppKitHost, opts: *const AppKitSaveDialogOpts, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_appkit_show_message_dialog(host: *AppKitHost, opts: *const AppKitMessageDialogOpts) c_int;
extern fn native_sdk_appkit_create_tray(host: *AppKitHost, icon_path: [*]const u8, icon_path_len: usize, title: [*]const u8, title_len: usize, tooltip: [*]const u8, tooltip_len: usize) void;
extern fn native_sdk_appkit_update_tray_menu(host: *AppKitHost, item_ids: [*]const u32, labels: [*]const [*]const u8, label_lens: [*]const usize, separators: [*]const c_int, enabled_flags: [*]const c_int, count: usize) void;
extern fn native_sdk_appkit_update_tray_title(host: *AppKitHost, title: [*]const u8, title_len: usize) void;
extern fn native_sdk_appkit_remove_tray(host: *AppKitHost) void;
extern fn native_sdk_appkit_set_tray_callback(host: *AppKitHost, callback: AppKitTrayCallback, context: ?*anyopaque) void;

/// Whether a Dock icon path names a raw image source (.png/.svg) that
/// `native package` would inset and mask onto the macOS icon grid.
/// Debug builds only: dev runs are unbundled, so the Dock shows exactly
/// the file the host is handed — a full-bleed square source would sit
/// sharp-cornered next to every masked tile. Release apps read their
/// icon from the bundle's .icns (already masked at package time), and
/// prebuilt .icns paths ship untouched in every mode.
fn devDockIconNeedsMask(path: []const u8) bool {
    if (builtin.mode != .Debug) return false;
    return app_icon.sourceKindForPath(path) != null;
}

/// The toolkit's default app icon, the same bytes `native package`
/// embeds as its fallback: unbundled runs whose configured icon file is
/// absent render this instead of showing the generic executable tile,
/// so a dev run and the packaged app fall back to the same picture from
/// ONE committed source (src/tooling/default_icon.png) — apps that ship
/// no icon of their own never carry a copy that can drift stale.
const default_icon_png = @embedFile("../../tooling/default_icon.png");

/// How the startup Dock icon resolves for this process.
const DockIconPlan = enum {
    /// The host loads the configured icon file itself (the classic
    /// path; also every bundled run, where the .app's own icon must
    /// never be overridden).
    host_file,
    /// Debug dev run with a raw square source: background-render the
    /// packaging mask/inset and hand the host pixels.
    masked_render,
    /// Unbundled run with no icon file on disk: background-render the
    /// embedded toolkit default.
    embedded_default,
};

fn planDockIcon(path: []const u8) DockIconPlan {
    if (iconFileExists(path)) {
        return if (devDockIconNeedsMask(path)) .masked_render else .host_file;
    }
    // No icon file. Inside a packaged .app the bundle's .icns already
    // owns the tile — hands off. Anywhere else (dev runs from the build
    // cache, plain zig-out binaries) macOS would show the generic
    // executable tile, so the embedded default steps in.
    if (processIsBundled()) return .host_file;
    return .embedded_default;
}

/// Existence probe for the configured Dock icon file. `access(2)`
/// directly: this sits on the launch path, where a stat is noise but an
/// event-loop `std.Io` instance is not; the host re-reads the file
/// asynchronously anyway, so a race here only re-selects the fallback.
fn iconFileExists(path: []const u8) bool {
    // Hermetic guard: this file compiles into every desktop target's
    // test build, and non-macOS builds must never reference the libc
    // symbol below, so the probe answers false at comptime there.
    if (comptime builtin.os.tag != .macos) return false;
    var buffer: [1024:0]u8 = undefined;
    if (path.len == 0 or path.len >= buffer.len) return false;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return std.c.access(buffer[0..path.len :0].ptr, std.c.F_OK) == 0;
}

/// Whether this process runs from inside a packaged .app bundle (the
/// executable lives under Contents/MacOS). Unbundled processes get the
/// dev-run icon fallbacks; bundled ones keep their Info.plist identity.
fn processIsBundled() bool {
    // Same hermetic guard as `iconFileExists`: the executable-path
    // lookup below exists only on macOS, and non-macOS test builds of
    // this file must never reference it.
    if (comptime builtin.os.tag != .macos) return false;
    var buffer: [4096]u8 = undefined;
    var size: u32 = buffer.len;
    if (std.c._NSGetExecutablePath(&buffer, &size) != 0) return false;
    const path = std.mem.sliceTo(buffer[0..], 0);
    return std.mem.indexOf(u8, path, ".app/Contents/MacOS/") != null;
}

/// Ceiling for a dev Dock icon source read. The pipeline caps sources at
/// 16384px on a side; any honest PNG/SVG source sits far below this.
const max_dev_dock_icon_source_bytes: usize = 32 * 1024 * 1024;

/// Start the background masked render for a raw dev icon source. Kept
/// off the launch path on purpose (the same reason the host decodes
/// .icns files off it): the Debug-mode render costs real milliseconds,
/// and the Dock tile updating a few frames after launch is
/// imperceptible. Every failure falls back to the host's plain file
/// load — the pre-parity behavior — so a broken source still shows
/// whatever the file holds and packaging stays the surface that reports
/// icon problems with teaching messages.
fn spawnDevDockIconRender(host: *AppKitHost, path: []const u8) void {
    const gpa = std.heap.c_allocator;
    const path_copy = gpa.dupe(u8, path) catch {
        native_sdk_appkit_set_dock_icon_file(host, path.ptr, path.len);
        return;
    };
    const thread = std.Thread.spawn(.{}, devDockIconRenderMain, .{ host, path_copy }) catch {
        gpa.free(path_copy);
        native_sdk_appkit_set_dock_icon_file(host, path.ptr, path.len);
        return;
    };
    thread.detach();
}

fn devDockIconRenderMain(host: *AppKitHost, path: []u8) void {
    const gpa = std.heap.c_allocator;
    defer gpa.free(path);
    renderDevDockIcon(gpa, host, path) catch {
        native_sdk_appkit_set_dock_icon_file(host, path.ptr, path.len);
    };
}

/// Start the background render of the embedded default icon (see
/// `default_icon_png`). Same off-the-launch-path policy as the masked
/// dev render; failure means no Dock icon, exactly the pre-fallback
/// behavior for a missing file.
fn spawnDefaultDockIconRender(host: *AppKitHost) void {
    const thread = std.Thread.spawn(.{}, defaultDockIconRenderMain, .{host}) catch return;
    thread.detach();
}

fn defaultDockIconRenderMain(host: *AppKitHost) void {
    const gpa = std.heap.c_allocator;
    var source = switch (app_icon.loadSource(gpa, default_icon_png, .png) catch return) {
        .ok => |value| value,
        .issue => return,
    };
    defer source.deinit(gpa);
    // The exact packaging render: the default is pre-shaped (transparent
    // corners), so it ships through untouched at the master size and the
    // dev tile equals the packaged fallback tile.
    const rgba = app_icon.renderMacosCanvas(gpa, &source, app_icon.master_size) catch return;
    defer gpa.free(rgba);
    native_sdk_appkit_set_dock_icon_rgba(host, rgba.ptr, app_icon.master_size, app_icon.master_size);
}

/// Render the masked macOS canvas for a raw icon source and hand the
/// pixels to the AppKit host. `renderMacosCanvas` is the exact packaging
/// render: full-bleed art is inset to the icon-grid artwork square and
/// masked by the standard rounded rectangle, while pre-shaped art (all
/// four corners already transparent) ships untouched, never
/// double-inset. Rendered at the pipeline's 1024 master size — the same
/// canvas the packaged .icns tops out at — so the dev tile and the
/// packaged tile are the same picture.
fn renderDevDockIcon(gpa: std.mem.Allocator, host: *AppKitHost, path: []const u8) !void {
    const kind = app_icon.sourceKindForPath(path) orelse return error.UnsupportedImage;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_dev_dock_icon_source_bytes));
    defer gpa.free(bytes);
    var source = switch (try app_icon.loadSource(gpa, bytes, kind)) {
        .ok => |value| value,
        // Undecodable or non-square: fall back to the raw file load
        // (the caller's catch) instead of guessing at a crop here.
        .issue => return error.UnsupportedImage,
    };
    defer source.deinit(gpa);
    const rgba = try app_icon.renderMacosCanvas(gpa, &source, app_icon.master_size);
    defer gpa.free(rgba);
    native_sdk_appkit_set_dock_icon_rgba(host, rgba.ptr, app_icon.master_size, app_icon.master_size);
}

pub const MacPlatform = struct {
    host: *AppKitHost,
    web_engine: platform_mod.WebEngine,
    app_info: platform_mod.AppInfo,
    surface_value: platform_mod.Surface,
    state: RunState = .{},

    pub fn init(title: []const u8, size: geometry.SizeF) Error!MacPlatform {
        return initWithEngine(title, size, .system);
    }

    pub fn initWithEngine(title: []const u8, size: geometry.SizeF, web_engine: platform_mod.WebEngine) Error!MacPlatform {
        return initWithOptions(size, web_engine, .{ .app_name = title, .window_title = title });
    }

    pub fn initWithOptions(size: geometry.SizeF, web_engine: platform_mod.WebEngine, app_info: platform_mod.AppInfo) Error!MacPlatform {
        const window_options = app_info.resolvedMainWindow();
        const window_title = window_options.resolvedTitle(app_info.app_name);
        const frame = window_options.default_frame;
        const display_name = app_info.resolvedDisplayName();
        // Dev-run Dock icon parity: a raw square icon source (.png/.svg)
        // gets the packaging pipeline's macOS mask/inset before it
        // reaches the Dock, so the dev tile matches the packaged one —
        // and an unbundled run with NO icon file gets the embedded
        // toolkit default, the same fallback `native package` ships.
        // For both render plans the host's own file load is suppressed
        // (an empty path at create) and a background render delivers
        // the pixels instead. Prebuilt .icns paths that exist — and
        // every bundled run, whose icon comes from the bundle — keep
        // the classic load byte-for-byte.
        const dock_icon = planDockIcon(app_info.icon_path);
        const icon_path = if (dock_icon == .host_file) app_info.icon_path else "";
        const host = native_sdk_appkit_create(app_info.app_name.ptr, app_info.app_name.len, display_name.ptr, display_name.len, app_info.version.ptr, app_info.version.len, app_info.description.ptr, app_info.description.len, if (app_info.has_web_content) 1 else 0, window_title.ptr, window_title.len, app_info.bundle_id.ptr, app_info.bundle_id.len, icon_path.ptr, icon_path.len, window_options.label.ptr, window_options.label.len, frame.x, frame.y, frame.width, frame.height, if (window_options.restore_state) 1 else 0, if (window_options.resizable) 1 else 0, titlebarStyleInt(window_options.titlebar), showModeInt(window_options.show)) orelse return error.CreateFailed;
        switch (dock_icon) {
            .host_file => {},
            .masked_render => spawnDevDockIconRender(host, app_info.icon_path),
            .embedded_default => spawnDefaultDockIconRender(host),
        }
        // The startup window's declared content min-size floor
        // (AppKit `contentMinSize`); the create call above registers
        // the window under its id, so the floor applies right after.
        applyWindowContentMinSize(host, window_options.id, window_options.min_width, window_options.min_height);
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

    pub fn deinit(self: *MacPlatform) void {
        native_sdk_appkit_destroy(self.host);
    }

    pub fn platform(self: *MacPlatform) platform_mod.Platform {
        return .{
            .context = self,
            .name = "macos",
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
                .window_chrome_fn = windowChrome,
                .create_view_fn = createView,
                .update_view_fn = updateView,
                .set_view_frame_fn = setViewFrame,
                .set_view_visible_fn = setViewVisible,
                .set_view_cursor_fn = setViewCursor,
                .focus_view_fn = focusView,
                .close_view_fn = closeView,
                .adopt_view_surface_fn = adoptViewSurface,
                .release_view_surface_fn = releaseViewSurface,
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
                .set_credential_fn = setCredential,
                .get_credential_fn = getCredential,
                .delete_credential_fn = deleteCredential,
                .open_external_url_fn = openExternalUrl,
                .reveal_path_fn = revealPath,
                .add_recent_document_fn = addRecentDocument,
                .clear_recent_documents_fn = clearRecentDocuments,
                .create_tray_fn = createTray,
                .update_tray_menu_fn = updateTrayMenu,
                .update_tray_title_fn = updateTrayTitle,
                .remove_tray_fn = removeTray,
                .configure_security_policy_fn = configureSecurityPolicy,
                .configure_menus_fn = configureMenus,
                .configure_shortcuts_fn = configureShortcuts,
                .emit_window_event_fn = emitWindowEvent,
                .start_timer_fn = startTimer,
                .cancel_timer_fn = cancelTimer,
                .audio_load_fn = audioLoad,
                .audio_load_url_fn = audioLoadUrl,
                .audio_play_fn = audioPlay,
                .audio_pause_fn = audioPause,
                .audio_stop_fn = audioStop,
                .audio_seek_fn = audioSeek,
                .audio_set_volume_fn = audioSetVolume,
                .wake_fn = wake,
                .request_frame_fn = requestFrame,
                .request_gpu_surface_frame_fn = requestGpuSurfaceFrame,
                .note_gpu_surface_input_fn = noteGpuSurfaceInput,
                .set_gpu_surface_scroll_drivers_fn = setGpuSurfaceScrollDrivers,
                .show_context_menu_fn = showContextMenu,
                .present_gpu_surface_pixels_fn = presentGpuSurfacePixels,
                .present_gpu_surface_packet_fn = presentGpuSurfacePacket,
                .present_gpu_surface_packet_binary_fn = presentGpuSurfacePacketBinary,
                .upload_gpu_surface_image_fn = uploadGpuSurfaceImage,
                .remove_gpu_surface_image_fn = removeGpuSurfaceImage,
                .register_gpu_surface_font_fn = registerGpuSurfaceFont,
                .update_widget_accessibility_fn = updateWidgetAccessibility,
                .measure_text_fn = measureText,
                .measure_text_advances_fn = measureTextAdvances,
                .decode_image_fn = decodeImage,
            },
            .app_info = self.app_info,
        };
    }

    fn supportsFeature(context: *anyopaque, feature: platform_mod.PlatformFeature) bool {
        const self: *MacPlatform = @ptrCast(@alignCast(context));
        return switch (feature) {
            .main_webview,
            .child_webviews,
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
            .app_activation_events,
            => true,
            .context_menus => true,
            .native_views,
            .native_control_commands,
            .menus,
            .file_drops,
            .gpu_surfaces,
            .gpu_surface_scroll_drivers,
            .view_surface_adoption,
            // Audio lives in the AppKit host (one AVPlayer for local
            // files and streamed URL sources); the Chromium host stubs
            // the C ABI and reports honestly unsupported rather than
            // half-implementing a second player. Spectrum analysis
            // ships with the player (an MTAudioProcessingTap feeding
            // vDSP — both in-box on every macOS this toolkit runs on),
            // so its report rides the same engine gate.
            .audio_playback,
            .audio_streaming,
            .audio_spectrum,
            => self.web_engine == .system,
        };
    }

    fn run(context: *anyopaque, handler: platform_mod.EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *MacPlatform = @ptrCast(@alignCast(context));
        self.state = .{
            .self = self,
            .handler = handler,
            .handler_context = handler_context,
        };
        native_sdk_appkit_set_bridge_callback(self.host, appkitBridgeCallback, &self.state);
        native_sdk_appkit_set_tray_callback(self.host, appkitTrayCallback, &self.state);
        native_sdk_appkit_run(self.host, appkitCallback, &self.state);
        if (self.state.failed) return error.CallbackFailed;
    }

    fn windowById(self: *const MacPlatform, window_id: platform_mod.WindowId) platform_mod.WindowOptions {
        var index: usize = 0;
        while (index < self.app_info.startupWindowCount()) : (index += 1) {
            const window = self.app_info.resolvedStartupWindow(index);
            if (window.id == window_id) return window;
        }
        return .{ .id = window_id, .label = "", .title = self.app_info.resolvedWindowTitle() };
    }
};

const RunState = struct {
    self: ?*MacPlatform = null,
    handler: ?platform_mod.EventHandler = null,
    handler_context: ?*anyopaque = null,
    failed: bool = false,

    fn emit(self: *RunState, event: platform_mod.Event) void {
        const handler = self.handler orelse return;
        const context = self.handler_context orelse return;
        handler(context, event) catch |err| {
            // The app is about to terminate through `CallbackFailed`;
            // name the error that latched the failure (and, in builds
            // that carry one, its return trace) so the exit is
            // attributable instead of a bare CallbackFailed.
            std.debug.print("platform callback failed: {s} (event {s})\n", .{ @errorName(err), @tagName(event) });
            if (@errorReturnTrace()) |error_trace| std.debug.dumpErrorReturnTrace(error_trace);
            self.failed = true;
            if (self.self) |mac| native_sdk_appkit_stop(mac.host);
        };
    }
};

fn appkitCallback(context: ?*anyopaque, event: *const AppKitEvent) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    switch (event.kind) {
        .start => state.emit(.app_start),
        .frame => state.emit(.frame_requested),
        .shutdown => state.emit(.app_shutdown),
        .app_activated => state.emit(.app_activated),
        .app_deactivated => state.emit(.app_deactivated),
        .appearance_changed => state.emit(.{ .appearance_changed = .{
            .color_scheme = appKitColorScheme(event.color_scheme),
            .reduce_motion = event.reduce_motion != 0,
            .high_contrast = event.high_contrast != 0,
        } }),
        .resize => {
            const surface: platform_mod.Surface = .{
                .id = event.window_id,
                .size = geometry.SizeF.init(@floatCast(event.width), @floatCast(event.height)),
                .scale_factor = @floatCast(event.scale),
            };
            if (state.self) |mac| mac.surface_value = surface;
            state.emit(.{ .surface_resized = surface });
        },
        .window_frame => if (state.self) |mac| {
            const event_label = event.label[0..event.label_len];
            const window = if (event_label.len > 0)
                platform_mod.WindowOptions{ .id = event.window_id, .label = event_label, .title = mac.app_info.resolvedWindowTitle() }
            else
                mac.windowById(event.window_id);
            state.emit(.{ .window_frame_changed = .{
                .id = window.id,
                .label = window.label,
                .title = window.resolvedTitle(mac.app_info.app_name),
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
        .timer => state.emit(.{ .timer = .{
            .id = event.timer_id,
            .timestamp_ns = event.timestamp_ns,
        } }),
        .wake => state.emit(.wake),
        .files_dropped => {
            var paths_buffer: [platform_mod.max_drop_paths][]const u8 = undefined;
            const paths = platform_mod.splitDropPaths(event.drop_paths[0..event.drop_paths_len], paths_buffer[0..]);
            state.emit(.{ .files_dropped = .{
                .window_id = event.window_id,
                .paths = paths,
            } });
        },
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
            .packet_decode_ns = event.packet_decode_ns,
            .packet_draw_ns = event.packet_draw_ns,
            .occluded = event.occluded != 0,
            .backend = .metal,
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
        .gpu_surface_input => state.emit(.{ .gpu_surface_input = gpuSurfaceInputEventFromAppKitEvent(event) }),
        .gpu_surface_scroll_driver => state.emit(.{ .gpu_surface_scroll_driver = .{
            .window_id = event.window_id,
            .label = event.view_label[0..event.view_label_len],
            .driver_id = event.widget_id,
            .offset_y = @floatCast(event.scroll_driver_offset_y),
            .timestamp_ns = event.timestamp_ns,
        } }),
        .context_menu_action => state.emit(.{ .context_menu_action = .{
            .window_id = event.window_id,
            .view_label = event.view_label[0..event.view_label_len],
            .token = event.widget_id,
            .item_id = event.menu_item_id,
        } }),
        .audio => state.emit(.{ .audio = .{
            .kind = audioEventKindFromInt(event.audio_kind),
            .position_ms = event.audio_position_ms,
            .duration_ms = event.audio_duration_ms,
            .playing = event.audio_playing != 0,
            .buffering = event.audio_buffering != 0,
            .bands = event.audio_bands,
        } }),
        .widget_accessibility_action => if (widgetAccessibilityActionFromInt(event.widget_action)) |action| {
            state.emit(.{ .widget_accessibility_action = .{
                .window_id = event.window_id,
                .label = event.view_label[0..event.view_label_len],
                .id = event.widget_id,
                .action = action,
                .text = appKitEventBytes(event.widget_text, event.widget_text_len),
                .selection = widgetAccessibilitySelectionFromAppKitEvent(event),
            } });
        },
    }
}

fn appKitColorScheme(value: c_int) platform_mod.ColorScheme {
    return switch (value) {
        1 => .dark,
        else => .light,
    };
}

fn appkitBridgeCallback(context: ?*anyopaque, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    state.emit(.{ .bridge_message = .{
        .bytes = message[0..message_len],
        .origin = origin[0..origin_len],
        .window_id = window_id,
        .webview_label = webview_label[0..webview_label_len],
    } });
}

/// Ordinals match `native_sdk_appkit_audio_event_kind_t` in
/// appkit_host.h; anything unknown degrades to `.failed` so a host/SDK
/// skew is loud in the app instead of undefined behavior here.
fn audioEventKindFromInt(value: c_int) platform_mod.AudioEventKind {
    return switch (value) {
        0 => .loaded,
        1 => .position,
        2 => .completed,
        4 => .spectrum,
        else => .failed,
    };
}

fn gpuSurfaceInputEventFromAppKitEvent(event: *const AppKitEvent) platform_mod.GpuSurfaceInputEvent {
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

fn readClipboard(context: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_appkit_clipboard_read(self.host, buffer.ptr, buffer.len);
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

/// CoreText-backed text measurement matching `NativeSdkPacketDrawText`'s
/// font resolution. Negative host results (invalid UTF-8) are surfaced as
/// negative so the canvas provider falls back to its estimator.
/// Headless text services for session replay: the SAME CoreText
/// measurement, canvas-font registration, and bundled-font activation a
/// live host performs, with no window and no run loop — so a journal
/// recorded against this host measures (and therefore lays out and
/// renders) identically under a headless replay on the same platform.
pub fn installHeadlessTextServices(services: *platform_mod.PlatformServices) void {
    native_sdk_appkit_register_bundled_fonts();
    services.measure_text_fn = measureText;
    services.measure_text_advances_fn = measureTextAdvances;
    services.register_gpu_surface_font_fn = registerGpuSurfaceFont;
}

fn measureText(context: ?*anyopaque, font_id: u64, size: f32, text: []const u8) f32 {
    _ = context;
    return @floatCast(native_sdk_appkit_measure_text(font_id, size, text.ptr, text.len));
}

/// Batched CoreText measurement: per-cluster advances for the whole run
/// in one host call (see the layout contract on the platform service).
/// A zero host answer (invalid UTF-8, unresolvable font) surfaces as
/// false so the canvas seam keeps its per-prefix path for that run.
fn measureTextAdvances(context: ?*anyopaque, font_id: u64, size: f32, text: []const u8, advances: []f32) bool {
    _ = context;
    if (text.len == 0) return true;
    if (advances.len < text.len) return false;
    return native_sdk_appkit_measure_text_advances(font_id, size, text.ptr, text.len, advances.ptr) == 1;
}

/// CGImageSource-backed image decoding (PNG, JPEG, ... — every codec
/// ImageIO ships) into straight-alpha RGBA8.
fn decodeImage(context: ?*anyopaque, bytes: []const u8, buffer: []u8) anyerror!platform_mod.DecodedImage {
    _ = context;
    var width: usize = 0;
    var height: usize = 0;
    return switch (native_sdk_appkit_decode_image(bytes.ptr, bytes.len, buffer.ptr, buffer.len, &width, &height)) {
        1 => .{ .width = width, .height = height, .rgba8 = buffer[0 .. width * height * 4] },
        -1 => error.ImageTooLarge,
        else => error.ImageDecodeFailed,
    };
}

fn writeClipboard(context: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_clipboard_write(self.host, text.ptr, text.len);
}

fn readClipboardData(context: ?*anyopaque, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_appkit_clipboard_read_data(self.host, mime_type.ptr, mime_type.len, buffer.ptr, buffer.len);
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

fn writeClipboardData(context: ?*anyopaque, data: platform_mod.ClipboardData) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_clipboard_write_data(self.host, data.mime_type.ptr, data.mime_type.len, data.bytes.ptr, data.bytes.len) == 0) return error.UnsupportedService;
}

fn loadWebView(context: ?*anyopaque, source: platform_mod.WebViewSource) anyerror!void {
    try loadWindowWebView(context, 1, source);
}

fn loadWindowWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, source: platform_mod.WebViewSource) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const assets: platform_mod.WebViewAssetSource = source.asset_options orelse .{ .root_path = "", .entry = "", .origin = "", .spa_fallback = false };
    native_sdk_appkit_load_window_webview(
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_bridge_respond(self.host, response.ptr, response.len);
}

fn completeWindowBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, response: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_bridge_respond_window(self.host, window_id, response.ptr, response.len);
}

fn completeWebViewBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_bridge_respond_webview(self.host, window_id, webview_label.ptr, webview_label.len, response.ptr, response.len);
}

fn emitWindowEvent(context: ?*anyopaque, window_id: platform_mod.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_emit_window_event(self.host, window_id, name.ptr, name.len, detail_json.ptr, detail_json.len);
}

fn titlebarStyleInt(style: platform_mod.WindowTitlebarStyle) c_int {
    return switch (style) {
        .standard => 0,
        .hidden_inset => 1,
        .hidden_inset_tall => 2,
        .chromeless => 3,
    };
}

fn showModeInt(mode: platform_mod.WindowShowMode) c_int {
    return switch (mode) {
        .immediate => 0,
        .on_first_present => 1,
    };
}

/// Apply a declared content min-size floor to a created window
/// (AppKit `contentMinSize`). Zero/negative/non-finite floors are the
/// "no floor" sentinel and skip the call — the window keeps AppKit's
/// default minimum.
fn applyWindowContentMinSize(host: *AppKitHost, window_id: u64, min_width: f32, min_height: f32) void {
    const width: f64 = if (std.math.isFinite(min_width) and min_width > 0) min_width else 0;
    const height: f64 = if (std.math.isFinite(min_height) and min_height > 0) min_height else 0;
    if (width <= 0 and height <= 0) return;
    _ = native_sdk_appkit_set_window_content_min_size(host, window_id, width, height);
}

fn createWindow(context: ?*anyopaque, options: platform_mod.WindowOptions) anyerror!platform_mod.WindowInfo {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const title = options.resolvedTitle(self.app_info.app_name);
    const frame = options.default_frame;
    if (native_sdk_appkit_create_window(self.host, options.id, title.ptr, title.len, options.label.ptr, options.label.len, frame.x, frame.y, frame.width, frame.height, if (options.restore_state) 1 else 0, if (options.resizable) 1 else 0, titlebarStyleInt(options.titlebar), showModeInt(options.show)) == 0) return error.CreateFailed;
    applyWindowContentMinSize(self.host, options.id, options.min_width, options.min_height);
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_focus_window(self.host, window_id) == 0) return error.FocusFailed;
}

fn closeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_close_window(self.host, window_id) == 0) return error.CloseFailed;
}

fn minimizeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_minimize_window(self.host, window_id) == 0) return error.WindowNotFound;
}

fn startWindowDrag(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_start_window_drag(self.host, window_id) == 0) return error.WindowNotFound;
}

fn windowChrome(context: ?*anyopaque, window_id: platform_mod.WindowId) platform_mod.WindowChrome {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var top: f64 = 0;
    var left: f64 = 0;
    var bottom: f64 = 0;
    var right: f64 = 0;
    var buttons_x: f64 = 0;
    var buttons_y: f64 = 0;
    var buttons_width: f64 = 0;
    var buttons_height: f64 = 0;
    if (native_sdk_appkit_window_chrome_insets(self.host, window_id, &top, &left, &bottom, &right, &buttons_x, &buttons_y, &buttons_width, &buttons_height) == 0) return .{};
    return .{
        .insets = .{
            .top = @floatCast(top),
            .left = @floatCast(left),
            .bottom = @floatCast(bottom),
            .right = @floatCast(right),
        },
        .buttons = geometry.RectF.init(
            @floatCast(buttons_x),
            @floatCast(buttons_y),
            @floatCast(buttons_width),
            @floatCast(buttons_height),
        ),
    };
}

fn createView(context: ?*anyopaque, options: platform_mod.ViewOptions) anyerror!void {
    if (options.kind == .webview) return createWebView(context, options.webViewOptions());
    if (!isSupportedNativeViewKind(options.kind)) return error.UnsupportedViewKind;
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const frame = options.frame;
    const parent = options.parent orelse "";
    if (native_sdk_appkit_create_view(
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const frame = patch.frame orelse geometry.RectF.init(0, 0, 0, 0);
    const role = patch.role orelse "";
    const accessibility_label = patch.accessibility_label orelse "";
    const text = patch.text orelse "";
    const command = patch.command orelse "";
    if (native_sdk_appkit_update_view(
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_appkit_set_view_frame(self.host, window_id, label.ptr, label.len, frame.x, frame.y, frame.width, frame.height) == 0) return error.ViewNotFound;
}

fn setViewVisible(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, visible: bool) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_appkit_set_view_visible(self.host, window_id, label.ptr, label.len, if (visible) 1 else 0) == 0) return error.ViewNotFound;
}

fn setViewCursor(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, cursor: platform_mod.Cursor) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_appkit_set_view_cursor(self.host, window_id, label.ptr, label.len, appKitCursor(cursor)) == 0) return error.ViewNotFound;
}

fn focusView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewFocus;
    if (native_sdk_appkit_focus_view(self.host, window_id, label.ptr, label.len) == 0) return error.UnsupportedViewFocus;
}

fn closeView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_appkit_close_view(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn adoptViewSurface(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, surface_handle: *anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_adopt_view_surface(self.host, window_id, label.ptr, label.len, surface_handle) == 0) return error.ViewNotFound;
}

fn releaseViewSurface(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_release_view_surface(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn startTimer(context: ?*anyopaque, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_start_timer(self.host, id, interval_ns, if (repeats) 1 else 0);
}

fn cancelTimer(context: ?*anyopaque, id: u64) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_cancel_timer(self.host, id);
}

/// Map the audio host's synchronous load result: 0 loaded, 1 the file is
/// missing/unreadable, anything else a decode failure. The asynchronous
/// `.loaded` acknowledgment (with the decoded duration) follows as an
/// `.audio` event on the run loop.
fn audioLoad(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    return switch (native_sdk_appkit_audio_load(self.host, path.ptr, path.len)) {
        0 => {},
        1 => error.AudioSourceNotFound,
        else => error.AudioDecodeFailed,
    };
}

/// Map the streaming host's synchronous result: 1 a verified cache
/// entry is playing locally, 0 a progressive stream started (the
/// `.loaded` acknowledgment follows when the item is ready), anything
/// else the URL itself was unusable. Network failures after this point
/// are asynchronous and arrive as `.audio`/`.failed` events.
fn audioLoadUrl(context: ?*anyopaque, url: []const u8, cache_path: []const u8, expected_bytes: u64) anyerror!platform_mod.AudioLoadResolution {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    return switch (native_sdk_appkit_audio_load_url(self.host, url.ptr, url.len, cache_path.ptr, cache_path.len, expected_bytes)) {
        0 => .stream,
        1 => .cache,
        else => error.InvalidAudioOptions,
    };
}

fn audioPlay(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_audio_play(self.host) == 0) return error.InvalidAudioOptions;
}

fn audioPause(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_audio_pause(self.host);
}

fn audioStop(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_audio_stop(self.host);
}

fn audioSeek(context: ?*anyopaque, position_ms: u64) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_audio_seek(self.host, position_ms) == 0) return error.InvalidAudioOptions;
}

fn audioSetVolume(context: ?*anyopaque, volume: f32) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_audio_set_volume(self.host, volume);
}

/// Thread-safe: dispatches onto the main queue, which emits `.wake` on
/// the AppKit run loop. One of the two services worker threads may call.
fn wake(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_wake(self.host);
}

/// Thread-safe like `wake`: dispatches onto the main queue, which emits
/// one coalesced `frame` event on the AppKit run loop. The automation
/// arrival watcher calls this when a command lands so an idle app runs
/// the frame that drains it — no timers involved, so the wake works even
/// when the app is backgrounded and its timers are being coalesced.
fn requestFrame(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_request_frame(self.host);
}

fn requestGpuSurfaceFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_request_gpu_surface_frame(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn noteGpuSurfaceInput(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return;
    _ = native_sdk_appkit_note_gpu_surface_input(self.host, window_id, label.ptr, label.len);
}

fn setGpuSurfaceScrollDrivers(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, drivers: []const platform_mod.GpuSurfaceScrollDriver) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    var specs: [platform_mod.max_gpu_surface_scroll_drivers]AppKitScrollDriver = undefined;
    const count = @min(drivers.len, specs.len);
    for (drivers[0..count], 0..) |driver, index| {
        specs[index] = .{
            .driver_id = driver.id,
            .x = driver.frame.x,
            .y = driver.frame.y,
            .width = driver.frame.width,
            .height = driver.frame.height,
            .content_width = driver.content_size.width,
            .content_height = driver.content_size.height,
            .offset_y = driver.offset_y,
            .set_offset = if (driver.set_offset) 1 else 0,
            .rubber_band = if (driver.rubber_band) 1 else 0,
        };
    }
    if (native_sdk_appkit_set_gpu_surface_scroll_drivers(self.host, window_id, label.ptr, label.len, &specs, count) == 0) return error.ViewNotFound;
}

fn showContextMenu(context: ?*anyopaque, request: platform_mod.ContextMenuRequest) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var items: [platform_mod.max_context_menu_items]AppKitContextMenuItem = undefined;
    const count = @min(request.items.len, items.len);
    for (request.items[0..count], 0..) |item, index| {
        items[index] = .{
            .item_id = item.id,
            .label = item.label.ptr,
            .label_len = item.label.len,
            .enabled = if (item.enabled) 1 else 0,
            .separator = if (item.separator) 1 else 0,
        };
    }
    if (native_sdk_appkit_show_context_menu(
        self.host,
        request.window_id,
        request.view_label.ptr,
        request.view_label.len,
        request.point.x,
        request.point.y,
        request.token,
        &items,
        count,
    ) == 0) return error.WindowNotFound;
}

fn presentGpuSurfacePixels(context: ?*anyopaque, pixels: platform_mod.GpuSurfacePixels) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const dirty_bounds = if (pixels.dirty_bounds) |bounds| bounds.normalized() else geometry.RectF{};
    if (native_sdk_appkit_present_gpu_surface_pixels(
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

fn presentGpuSurfacePacket(context: ?*anyopaque, packet: platform_mod.GpuSurfacePacket) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const result = native_sdk_appkit_present_gpu_surface_packet(
        self.host,
        packet.window_id,
        packet.label.ptr,
        packet.label.len,
        packet.surface_size.width,
        packet.surface_size.height,
        packet.scale_factor,
        packet.clear_color_rgba8[0],
        packet.clear_color_rgba8[1],
        packet.clear_color_rgba8[2],
        packet.clear_color_rgba8[3],
        if (packet.requires_render) 1 else 0,
        packet.command_count,
        packet.unsupported_command_count,
        if (packet.representable) 1 else 0,
        packet.json.ptr,
        packet.json.len,
    );
    switch (result) {
        1 => return,
        0 => return error.UnsupportedService,
        -1 => return error.ViewNotFound,
        else => return error.InvalidGpuSurfacePacket,
    }
}

/// Compact binary twin of `presentGpuSurfacePacket`: identical result
/// contract (0 = refused, which the runtime answers by retrying the
/// JSON encoding in the same frame before its pixel fallback).
fn presentGpuSurfacePacketBinary(context: ?*anyopaque, packet: platform_mod.GpuSurfacePacket) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const result = native_sdk_appkit_present_gpu_surface_packet_binary(
        self.host,
        packet.window_id,
        packet.label.ptr,
        packet.label.len,
        packet.surface_size.width,
        packet.surface_size.height,
        packet.scale_factor,
        packet.clear_color_rgba8[0],
        packet.clear_color_rgba8[1],
        packet.clear_color_rgba8[2],
        packet.clear_color_rgba8[3],
        if (packet.requires_render) 1 else 0,
        packet.command_count,
        packet.unsupported_command_count,
        if (packet.representable) 1 else 0,
        packet.binary.ptr,
        packet.binary.len,
    );
    switch (result) {
        1 => return,
        0 => return error.UnsupportedService,
        -1 => return error.ViewNotFound,
        else => return error.InvalidGpuSurfacePacket,
    }
}

fn uploadGpuSurfaceImage(context: ?*anyopaque, image: platform_mod.GpuSurfaceImagePixels) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_upload_gpu_surface_image(
        self.host,
        image.id,
        image.width,
        image.height,
        image.rgba8.ptr,
        image.rgba8.len,
    ) == 0) return error.InvalidGpuSurfaceImage;
}

fn removeGpuSurfaceImage(context: ?*anyopaque, id: u64) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_remove_gpu_surface_image(self.host, id) == 0) return error.InvalidGpuSurfaceImage;
}

/// Registered canvas fonts feed the host's single font-resolution seam
/// (measurement AND packet text drawing), which exists on both web
/// engines, so this is deliberately not gated on `web_engine`.
fn registerGpuSurfaceFont(context: ?*anyopaque, font: platform_mod.GpuSurfaceFontData) anyerror!void {
    _ = context;
    if (native_sdk_appkit_register_font(font.id, font.ttf.ptr, font.ttf.len) == 0) return error.InvalidGpuSurfaceFont;
}

fn updateWidgetAccessibility(context: ?*anyopaque, snapshot: platform_mod.WidgetAccessibilitySnapshot) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (snapshot.nodes.len > platform_mod.max_widget_accessibility_nodes) return error.InvalidViewOptions;
    var nodes: [platform_mod.max_widget_accessibility_nodes]AppKitWidgetAccessibilityNode = undefined;
    for (snapshot.nodes, 0..) |node, index| {
        nodes[index] = .{
            .id = node.id,
            .role = @intFromEnum(node.role),
            .label = node.label.ptr,
            .label_len = node.label.len,
            .text_value = node.text_value.ptr,
            .text_value_len = node.text_value.len,
            .placeholder = node.placeholder.ptr,
            .placeholder_len = node.placeholder.len,
            .has_text_selection = if (node.text_selection != null) 1 else 0,
            .text_selection_start = if (node.text_selection) |range| range.start else 0,
            .text_selection_end = if (node.text_selection) |range| range.end else 0,
            .has_text_composition = if (node.text_composition != null) 1 else 0,
            .text_composition_start = if (node.text_composition) |range| range.start else 0,
            .text_composition_end = if (node.text_composition) |range| range.end else 0,
            .has_value = if (node.value != null) 1 else 0,
            .value = node.value orelse 0,
            .has_grid_row_index = if (node.grid_row_index != null) 1 else 0,
            .grid_row_index = node.grid_row_index orelse 0,
            .has_grid_column_index = if (node.grid_column_index != null) 1 else 0,
            .grid_column_index = node.grid_column_index orelse 0,
            .has_grid_row_count = if (node.grid_row_count != null) 1 else 0,
            .grid_row_count = node.grid_row_count orelse 0,
            .has_grid_column_count = if (node.grid_column_count != null) 1 else 0,
            .grid_column_count = node.grid_column_count orelse 0,
            .has_list_item_index = if (node.list_item_index != null) 1 else 0,
            .list_item_index = node.list_item_index orelse 0,
            .has_list_item_count = if (node.list_item_count != null) 1 else 0,
            .list_item_count = node.list_item_count orelse 0,
            .has_scroll_offset = if (node.scroll_offset != null) 1 else 0,
            .scroll_offset = node.scroll_offset orelse 0,
            .has_scroll_viewport_extent = if (node.scroll_viewport_extent != null) 1 else 0,
            .scroll_viewport_extent = node.scroll_viewport_extent orelse 0,
            .has_scroll_content_extent = if (node.scroll_content_extent != null) 1 else 0,
            .scroll_content_extent = node.scroll_content_extent orelse 0,
            .x = node.bounds.x,
            .y = node.bounds.y,
            .width = node.bounds.width,
            .height = node.bounds.height,
            .state_flags = widgetStateFlags(node),
            .action_flags = widgetActionFlags(node.actions),
        };
    }
    if (native_sdk_appkit_update_widget_accessibility(
        self.host,
        snapshot.window_id,
        snapshot.view_label.ptr,
        snapshot.view_label.len,
        nodes[0..snapshot.nodes.len].ptr,
        snapshot.nodes.len,
    ) == 0) return error.ViewNotFound;
}

fn widgetStateFlags(node: platform_mod.WidgetAccessibilityNode) u32 {
    var flags: u32 = 0;
    if (node.enabled) flags |= widget_state_enabled;
    if (node.focused) flags |= widget_state_focused;
    if (node.selected) flags |= widget_state_selected;
    if (node.pressed) flags |= widget_state_pressed;
    if (node.expanded) |expanded| {
        flags |= if (expanded) widget_state_expanded else widget_state_collapsed;
    }
    if (node.required) flags |= widget_state_required;
    if (node.read_only) flags |= widget_state_read_only;
    if (node.invalid) flags |= widget_state_invalid;
    return flags;
}

fn widgetActionFlags(actions: platform_mod.WidgetAccessibilityActions) u32 {
    var flags: u32 = 0;
    if (actions.focus) flags |= widget_action_focus;
    if (actions.press) flags |= widget_action_press;
    if (actions.toggle) flags |= widget_action_toggle;
    if (actions.increment) flags |= widget_action_increment;
    if (actions.decrement) flags |= widget_action_decrement;
    if (actions.set_text) flags |= widget_action_set_text;
    if (actions.set_selection) flags |= widget_action_set_selection;
    if (actions.select) flags |= widget_action_select;
    if (actions.drag) flags |= widget_action_drag;
    if (actions.drop_files) flags |= widget_action_drop_files;
    if (actions.dismiss) flags |= widget_action_dismiss;
    return flags;
}

fn appKitCursor(cursor: platform_mod.Cursor) c_int {
    return switch (cursor) {
        .arrow => 0,
        .pointing_hand => 1,
        .text => 2,
        .resize_horizontal => 3,
    };
}

fn createWebView(context: ?*anyopaque, options: platform_mod.WebViewOptions) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const frame = options.frame;
    if (native_sdk_appkit_create_webview(self.host, options.window_id, options.label.ptr, options.label.len, options.url.ptr, options.url.len, frame.x, frame.y, frame.width, frame.height, options.layer, if (options.transparent) 1 else 0, if (options.bridge_enabled) 1 else 0) == 0) return error.CreateFailed;
}

fn setWebViewFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_set_webview_frame(self.host, window_id, label.ptr, label.len, frame.x, frame.y, frame.width, frame.height) == 0) return error.WebViewNotFound;
}

fn navigateWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, url: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_navigate_webview(self.host, window_id, label.ptr, label.len, url.ptr, url.len) == 0) return error.WebViewNotFound;
}

fn setWebViewZoom(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, zoom: f64) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_set_webview_zoom(self.host, window_id, label.ptr, label.len, zoom) == 0) return error.WebViewNotFound;
}

fn setWebViewLayer(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, layer: i32) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_set_webview_layer(self.host, window_id, label.ptr, label.len, layer) == 0) return error.WebViewNotFound;
}

fn closeWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_close_webview(self.host, window_id, label.ptr, label.len) == 0) return error.WebViewNotFound;
}

fn showNotification(context: ?*anyopaque, options: platform_mod.NotificationOptions) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_show_notification(
        self.host,
        options.title.ptr,
        options.title.len,
        options.subtitle.ptr,
        options.subtitle.len,
        options.body.ptr,
        options.body.len,
    ) == 0) return error.UnsupportedService;
}

fn setCredential(context: ?*anyopaque, credential: platform_mod.Credential) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_set_credential(
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_appkit_get_credential(
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_delete_credential(
        self.host,
        key.service.ptr,
        key.service.len,
        key.account.ptr,
        key.account.len,
    ) == 0) return error.CredentialNotFound;
}

fn openExternalUrl(context: ?*anyopaque, url: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_open_external_url(self.host, url.ptr, url.len) == 0) return error.UnsupportedService;
}

fn revealPath(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_reveal_path(self.host, path.ptr, path.len) == 0) return error.UnsupportedService;
}

fn addRecentDocument(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_add_recent_document(self.host, path.ptr, path.len) == 0) return error.UnsupportedService;
}

fn clearRecentDocuments(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_clear_recent_documents(self.host) == 0) return error.UnsupportedService;
}

fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var origins_buffer: [4096]u8 = undefined;
    var external_buffer: [4096]u8 = undefined;
    const origins = try policy_values.join(policy.navigation.allowed_origins, &origins_buffer);
    const external_urls = try policy_values.join(policy.navigation.external_links.allowed_urls, &external_buffer);
    native_sdk_appkit_set_security_policy(
        self.host,
        origins.ptr,
        origins.len,
        external_urls.ptr,
        external_urls.len,
        @intFromEnum(policy.navigation.external_links.action),
    );
}

fn configureMenus(context: ?*anyopaque, menus: []const platform_mod.Menu) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
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

    native_sdk_appkit_set_menus(
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
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
    native_sdk_appkit_set_shortcuts(self.host, ids[0..shortcuts.len].ptr, id_lens[0..shortcuts.len].ptr, keys[0..shortcuts.len].ptr, key_lens[0..shortcuts.len].ptr, modifiers[0..shortcuts.len].ptr, shortcuts.len);
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

fn widgetAccessibilityActionFromInt(value: c_int) ?platform_mod.WidgetAccessibilityActionKind {
    return switch (value) {
        0 => .focus,
        1 => .press,
        2 => .toggle,
        3 => .increment,
        4 => .decrement,
        5 => .set_text,
        6 => .set_selection,
        7 => .select,
        8 => .drag,
        9 => .drop_files,
        10 => .dismiss,
        else => null,
    };
}

fn appKitEventBytes(bytes: [*]const u8, len: usize) []const u8 {
    if (len == 0 or @intFromPtr(bytes) == 0) return "";
    return bytes[0..len];
}

fn widgetAccessibilitySelectionFromAppKitEvent(event: *const AppKitEvent) ?platform_mod.WidgetAccessibilityTextRange {
    if (event.has_widget_text_selection == 0) return null;
    return .{
        .start = event.widget_text_selection_start,
        .end = event.widget_text_selection_end,
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

test "macos supports native container and control kinds" {
    try std.testing.expect(isSupportedNativeViewKind(.split));
    try std.testing.expect(isSupportedNativeViewKind(.stack));
    try std.testing.expect(isSupportedNativeViewKind(.icon_button));
    try std.testing.expect(isSupportedNativeViewKind(.list_item));
    try std.testing.expect(isSupportedNativeViewKind(.gpu_surface));
}

test "macos chromium reports unsupported native surfaces" {
    var system = testPlatformWithEngine(.system);
    try std.testing.expect(MacPlatform.supportsFeature(&system, .native_views));
    try std.testing.expect(MacPlatform.supportsFeature(&system, .native_control_commands));
    try std.testing.expect(MacPlatform.supportsFeature(&system, .menus));
    try std.testing.expect(MacPlatform.supportsFeature(&system, .gpu_surfaces));
    try std.testing.expect(MacPlatform.supportsFeature(&system, .view_surface_adoption));

    var chromium = testPlatformWithEngine(.chromium);
    try std.testing.expect(MacPlatform.supportsFeature(&chromium, .main_webview));
    try std.testing.expect(MacPlatform.supportsFeature(&chromium, .child_webviews));
    try std.testing.expect(MacPlatform.supportsFeature(&chromium, .tray));
    try std.testing.expect(MacPlatform.supportsFeature(&chromium, .shortcuts));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .native_views));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .native_control_commands));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .menus));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .file_drops));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .gpu_surfaces));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .view_surface_adoption));
}

fn testPlatformWithEngine(web_engine: platform_mod.WebEngine) MacPlatform {
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

fn showOpenDialog(context: ?*anyopaque, options: platform_mod.OpenDialogOptions, buffer: []u8) anyerror!platform_mod.OpenDialogResult {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = AppKitOpenDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
        .allow_directories = if (options.allow_directories) 1 else 0,
        .allow_multiple = if (options.allow_multiple) 1 else 0,
    };
    const result = native_sdk_appkit_show_open_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (result.bytes_written > buffer.len) return error.NoSpaceLeft;
    return .{
        .count = result.count,
        .paths = buffer[0..result.bytes_written],
    };
}

fn showSaveDialog(context: ?*anyopaque, options: platform_mod.SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = AppKitSaveDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .default_name = options.default_name.ptr,
        .default_name_len = options.default_name.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
    };
    const written = native_sdk_appkit_show_save_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (written > buffer.len) return error.NoSpaceLeft;
    if (written == 0) return null;
    return buffer[0..written];
}

fn showMessageDialog(context: ?*anyopaque, options: platform_mod.MessageDialogOptions) anyerror!platform_mod.MessageDialogResult {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const opts = AppKitMessageDialogOpts{
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
    const result = native_sdk_appkit_show_message_dialog(self.host, &opts);
    return @enumFromInt(result);
}

const max_tray_items: usize = 32;

fn createTray(context: ?*anyopaque, options: platform_mod.TrayOptions) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_create_tray(self.host, options.icon_path.ptr, options.icon_path.len, options.title.ptr, options.title.len, options.tooltip.ptr, options.tooltip.len);
    if (options.items.len > 0) {
        try updateTrayMenu(context, options.items);
    }
}

fn updateTrayMenu(context: ?*anyopaque, items: []const platform_mod.TrayMenuItem) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const count = @min(items.len, max_tray_items);
    var ids: [max_tray_items]u32 = undefined;
    var labels: [max_tray_items][*]const u8 = undefined;
    var label_lens: [max_tray_items]usize = undefined;
    var separators: [max_tray_items]c_int = undefined;
    var enabled_flags: [max_tray_items]c_int = undefined;
    for (items[0..count], 0..) |item, i| {
        ids[i] = item.id;
        labels[i] = item.label.ptr;
        label_lens[i] = item.label.len;
        separators[i] = if (item.separator) 1 else 0;
        enabled_flags[i] = if (item.enabled) 1 else 0;
    }
    native_sdk_appkit_update_tray_menu(self.host, &ids, &labels, &label_lens, &separators, &enabled_flags, count);
}

fn updateTrayTitle(context: ?*anyopaque, title: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_update_tray_title(self.host, title.ptr, title.len);
}

fn removeTray(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_remove_tray(self.host);
}

fn appkitTrayCallback(context: ?*anyopaque, item_id: u32) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    state.emit(.{ .tray_action = item_id });
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

test "mac platform module exports type" {
    _ = MacPlatform;
}

test "mac dock icon fallback renders the embedded toolkit default" {
    // The exact pipeline `defaultDockIconRenderMain` hands the host:
    // decode the embedded default and render the packaging canvas. This
    // proves the runtime Dock path can consume the embedded bytes — no
    // per-app icon file needed for the default tile.
    const gpa = std.testing.allocator;
    var source = switch (try app_icon.loadSource(gpa, default_icon_png, .png)) {
        .ok => |value| value,
        .issue => return error.TestUnexpectedResult,
    };
    defer source.deinit(gpa);
    const rgba = try app_icon.renderMacosCanvas(gpa, &source, app_icon.master_size);
    defer gpa.free(rgba);
    const size = app_icon.master_size;
    try std.testing.expectEqual(size * size * 4, rgba.len);
    // Pre-shaped icon: the canvas corner stays transparent (the rounded
    // plate never reaches it) …
    try std.testing.expectEqual(@as(u8, 0), rgba[(2 * size + 2) * 4 + 3]);
    // … and the plate is the dark-NEUTRAL gradient: an opaque gray
    // (r == g == b, well below mid-tone) below the layered-sheet mark.
    const plate_index = ((size * 850 / 1024) * size + size / 2) * 4;
    const r = rgba[plate_index];
    try std.testing.expectEqual(@as(u8, 255), rgba[plate_index + 3]);
    try std.testing.expectEqual(r, rgba[plate_index + 1]);
    try std.testing.expectEqual(r, rgba[plate_index + 2]);
    try std.testing.expect(r >= 15 and r <= 60);
}

test "mac dock icon plan uses the embedded default only without a file" {
    // The file-existence and bundle probes are comptime-stubbed to
    // false off macOS, where this plan never runs — only the macOS test
    // build exercises the real probes.
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    // Missing file, unbundled test binary: the embedded default.
    try std.testing.expectEqual(DockIconPlan.embedded_default, planDockIcon("assets/does-not-exist.icns"));
    try std.testing.expectEqual(DockIconPlan.embedded_default, planDockIcon(""));
    // A real file keeps the classic host load (or the Debug masked
    // render for raw sources) — an app's own icon always wins.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.icns", .data = "stub" });
    var path_buffer: [256]u8 = undefined;
    // tmpDir lives under .zig-cache/tmp/ relative to the test cwd.
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/icon.icns", .{tmp.sub_path[0..]});
    try std.testing.expectEqual(DockIconPlan.host_file, planDockIcon(path));
}

test "mac widget accessibility maps retained action flags" {
    try std.testing.expectEqual(@as(u32, 0), widgetActionFlags(.{}));
    const flags = widgetActionFlags(.{
        .focus = true,
        .press = true,
        .toggle = true,
        .increment = true,
        .decrement = true,
        .set_text = true,
        .set_selection = true,
        .select = true,
        .drag = true,
        .drop_files = true,
        .dismiss = true,
    });
    try std.testing.expect(flags & widget_action_focus != 0);
    try std.testing.expect(flags & widget_action_press != 0);
    try std.testing.expect(flags & widget_action_toggle != 0);
    try std.testing.expect(flags & widget_action_increment != 0);
    try std.testing.expect(flags & widget_action_decrement != 0);
    try std.testing.expect(flags & widget_action_set_text != 0);
    try std.testing.expect(flags & widget_action_set_selection != 0);
    try std.testing.expect(flags & widget_action_select != 0);
    try std.testing.expect(flags & widget_action_drag != 0);
    try std.testing.expect(flags & widget_action_drop_files != 0);
    try std.testing.expect(flags & widget_action_dismiss != 0);
}

test "mac widget accessibility maps widget state flags" {
    const expanded = widgetStateFlags(.{ .enabled = true, .expanded = true, .required = true, .read_only = true, .invalid = true });
    try std.testing.expect(expanded & widget_state_enabled != 0);
    try std.testing.expect(expanded & widget_state_expanded != 0);
    try std.testing.expect(expanded & widget_state_collapsed == 0);
    try std.testing.expect(expanded & widget_state_required != 0);
    try std.testing.expect(expanded & widget_state_read_only != 0);
    try std.testing.expect(expanded & widget_state_invalid != 0);

    const collapsed = widgetStateFlags(.{ .enabled = true, .expanded = false });
    try std.testing.expect(collapsed & widget_state_enabled != 0);
    try std.testing.expect(collapsed & widget_state_collapsed != 0);
    try std.testing.expect(collapsed & widget_state_expanded == 0);
}

test "mac widget accessibility maps retained action events" {
    try std.testing.expectEqual(platform_mod.WidgetAccessibilityActionKind.drag, widgetAccessibilityActionFromInt(8).?);
    try std.testing.expectEqual(platform_mod.WidgetAccessibilityActionKind.drop_files, widgetAccessibilityActionFromInt(9).?);
    try std.testing.expectEqual(platform_mod.WidgetAccessibilityActionKind.dismiss, widgetAccessibilityActionFromInt(10).?);
    try std.testing.expect(widgetAccessibilityActionFromInt(11) == null);
}

test "mac widget accessibility action preserves text payload" {
    const text = "Search customers";
    var event = std.mem.zeroes(AppKitEvent);
    event.widget_text = text.ptr;
    event.widget_text_len = text.len;
    event.has_widget_text_selection = 1;
    event.widget_text_selection_start = 2;
    event.widget_text_selection_end = 8;

    try std.testing.expectEqualStrings("Search customers", appKitEventBytes(event.widget_text, event.widget_text_len));
    try std.testing.expectEqualDeep(platform_mod.WidgetAccessibilityTextRange{ .start = 2, .end = 8 }, widgetAccessibilitySelectionFromAppKitEvent(&event).?);

    event.widget_text_len = 0;
    event.has_widget_text_selection = 0;
    try std.testing.expectEqualStrings("", appKitEventBytes(event.widget_text, event.widget_text_len));
    try std.testing.expect(widgetAccessibilitySelectionFromAppKitEvent(&event) == null);
}

test "mac gpu surface input preserves key and text" {
    const label = "canvas";
    const key = "enter";
    const text = "\n";
    var event = std.mem.zeroes(AppKitEvent);
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

    const input = gpuSurfaceInputEventFromAppKitEvent(&event);
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

test "mac gpu surface input preserves ime composition cursor" {
    const label = "canvas";
    const text = "compose";
    var event = std.mem.zeroes(AppKitEvent);
    event.window_id = 9;
    event.view_label = label.ptr;
    event.view_label_len = label.len;
    event.input_kind = 8;
    event.input_text = text.ptr;
    event.input_text_len = text.len;
    event.has_composition_cursor = 1;
    event.composition_cursor = 4;

    const input = gpuSurfaceInputEventFromAppKitEvent(&event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.ime_set_composition, input.kind);
    try std.testing.expectEqualStrings("compose", input.text);
    try std.testing.expectEqual(@as(?usize, 4), input.composition_cursor);
}

test "mac gpu surface input maps pointer cancel" {
    var event = std.mem.zeroes(AppKitEvent);
    event.input_kind = 11;

    const input = gpuSurfaceInputEventFromAppKitEvent(&event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.pointer_cancel, input.kind);
}

test "mac appearance event maps color scheme" {
    try std.testing.expectEqual(platform_mod.ColorScheme.light, appKitColorScheme(0));
    try std.testing.expectEqual(platform_mod.ColorScheme.dark, appKitColorScheme(1));
    try std.testing.expectEqual(platform_mod.ColorScheme.light, appKitColorScheme(42));
}

test "mac appearance event carries accessibility preferences" {
    var event = std.mem.zeroes(AppKitEvent);
    event.color_scheme = 1;
    event.reduce_motion = 1;
    event.high_contrast = 1;

    try std.testing.expectEqual(platform_mod.ColorScheme.dark, appKitColorScheme(event.color_scheme));
    try std.testing.expect(event.reduce_motion != 0);
    try std.testing.expect(event.high_contrast != 0);
}
