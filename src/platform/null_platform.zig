const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
const platform_info = @import("platform_info");
const security = @import("../security/root.zig");
const types = @import("types.zig");

const default_gpu_frame_interval_ns = types.default_gpu_frame_interval_ns;
const default_gpu_first_frame_latency_budget_ns = types.default_gpu_first_frame_latency_budget_ns;
const Error = types.Error;
const WebEngine = types.WebEngine;
const PlatformFeature = types.PlatformFeature;
const WebViewSourceKind = types.WebViewSourceKind;
const WebViewAssetSource = types.WebViewAssetSource;
const WebViewSource = types.WebViewSource;
const WindowId = types.WindowId;
const WindowTitlebarStyle = types.WindowTitlebarStyle;
const ViewId = types.ViewId;
const max_windows = types.max_windows;
const max_window_label_bytes = types.max_window_label_bytes;
const max_window_title_bytes = types.max_window_title_bytes;
const max_window_source_bytes = types.max_window_source_bytes;
const max_webviews = types.max_webviews;
const max_webview_label_bytes = types.max_webview_label_bytes;
const max_webview_url_bytes = types.max_webview_url_bytes;
const max_external_url_bytes = types.max_external_url_bytes;
const max_reveal_path_bytes = types.max_reveal_path_bytes;
const max_recent_document_path_bytes = types.max_recent_document_path_bytes;
const max_notification_title_bytes = types.max_notification_title_bytes;
const max_notification_subtitle_bytes = types.max_notification_subtitle_bytes;
const max_notification_body_bytes = types.max_notification_body_bytes;
const max_clipboard_mime_type_bytes = types.max_clipboard_mime_type_bytes;
const max_clipboard_data_bytes = types.max_clipboard_data_bytes;
const max_credential_service_bytes = types.max_credential_service_bytes;
const max_credential_account_bytes = types.max_credential_account_bytes;
const max_credential_secret_bytes = types.max_credential_secret_bytes;
const max_tray_items = types.max_tray_items;
const max_tray_icon_path_bytes = types.max_tray_icon_path_bytes;
const max_tray_title_bytes = types.max_tray_title_bytes;
const max_tray_tooltip_bytes = types.max_tray_tooltip_bytes;
const max_tray_item_label_bytes = types.max_tray_item_label_bytes;
const max_tray_item_command_bytes = types.max_tray_item_command_bytes;
const max_drop_paths_bytes = types.max_drop_paths_bytes;
const max_drop_paths = types.max_drop_paths;
const max_window_event_name_bytes = types.max_window_event_name_bytes;
const max_window_event_detail_bytes = types.max_window_event_detail_bytes;
const max_views = types.max_views;
const max_view_label_bytes = types.max_view_label_bytes;
const max_view_role_bytes = types.max_view_role_bytes;
const max_view_accessibility_label_bytes = types.max_view_accessibility_label_bytes;
const max_view_text_bytes = types.max_view_text_bytes;
const max_view_command_bytes = types.max_view_command_bytes;
const max_menus = types.max_menus;
const max_menu_items = types.max_menu_items;
const max_menu_title_bytes = types.max_menu_title_bytes;
const max_menu_item_label_bytes = types.max_menu_item_label_bytes;
const max_menu_command_bytes = types.max_menu_command_bytes;
const max_menu_key_bytes = types.max_menu_key_bytes;
const max_shortcuts = types.max_shortcuts;
const max_shortcut_id_bytes = types.max_shortcut_id_bytes;
const max_shortcut_key_bytes = types.max_shortcut_key_bytes;
const max_widget_accessibility_nodes = types.max_widget_accessibility_nodes;
const max_gpu_surface_packet_json_bytes = types.max_gpu_surface_packet_json_bytes;
const ShortcutModifiers = types.ShortcutModifiers;
const Shortcut = types.Shortcut;
const ShortcutEvent = types.ShortcutEvent;
const Menu = types.Menu;
const MenuItem = types.MenuItem;
const validateShortcut = types.validateShortcut;
const validateMenus = types.validateMenus;
const validateMenuItem = types.validateMenuItem;
const isValidShortcutKey = types.isValidShortcutKey;
const WindowRestorePolicy = types.WindowRestorePolicy;
const WindowOptions = types.WindowOptions;
const WindowState = types.WindowState;
const WindowInfo = types.WindowInfo;
const WindowCreateOptions = types.WindowCreateOptions;
const WebViewOptions = types.WebViewOptions;
const WebViewInfo = types.WebViewInfo;
const ViewKind = types.ViewKind;
const GpuSurfaceBackend = types.GpuSurfaceBackend;
const GpuSurfacePixelFormat = types.GpuSurfacePixelFormat;
const GpuSurfacePresentMode = types.GpuSurfacePresentMode;
const GpuSurfaceAlphaMode = types.GpuSurfaceAlphaMode;
const GpuSurfaceColorSpace = types.GpuSurfaceColorSpace;
const GpuSurfaceStatus = types.GpuSurfaceStatus;
const CanvasFrameProfileRisk = types.CanvasFrameProfileRisk;
const GpuSurfaceOptions = types.GpuSurfaceOptions;
const ViewOptions = types.ViewOptions;
const ViewPatch = types.ViewPatch;
const Cursor = types.Cursor;
const ViewInfo = types.ViewInfo;
const AppInfo = types.AppInfo;
const Surface = types.Surface;
const BridgeMessage = types.BridgeMessage;
const max_dialog_path_bytes = types.max_dialog_path_bytes;
const max_dialog_paths_bytes = types.max_dialog_paths_bytes;
const max_dialog_title_bytes = types.max_dialog_title_bytes;
const max_dialog_message_bytes = types.max_dialog_message_bytes;
const max_dialog_button_bytes = types.max_dialog_button_bytes;
const max_dialog_filter_name_bytes = types.max_dialog_filter_name_bytes;
const max_dialog_filter_bytes = types.max_dialog_filter_bytes;
const FileFilter = types.FileFilter;
const OpenDialogOptions = types.OpenDialogOptions;
const OpenDialogResult = types.OpenDialogResult;
const SaveDialogOptions = types.SaveDialogOptions;
const MessageDialogStyle = types.MessageDialogStyle;
const MessageDialogResult = types.MessageDialogResult;
const MessageDialogOptions = types.MessageDialogOptions;
const NotificationOptions = types.NotificationOptions;
const CredentialKey = types.CredentialKey;
const Credential = types.Credential;
const TrayItemId = types.TrayItemId;
const TrayOptions = types.TrayOptions;
const TrayMenuItem = types.TrayMenuItem;
const NativeCommandEvent = types.NativeCommandEvent;
const MenuCommandEvent = types.MenuCommandEvent;
const TimerEvent = types.TimerEvent;
const FileDropEvent = types.FileDropEvent;
const GpuFrame = types.GpuFrame;
const GpuSurfaceFrameEvent = types.GpuSurfaceFrameEvent;
const GpuSurfaceResizeEvent = types.GpuSurfaceResizeEvent;
const GpuSurfaceInputKind = types.GpuSurfaceInputKind;
const GpuSurfaceInputEvent = types.GpuSurfaceInputEvent;
const GpuSurfacePixels = types.GpuSurfacePixels;
const GpuSurfacePacket = types.GpuSurfacePacket;
const GpuSurfaceImagePixels = types.GpuSurfaceImagePixels;
const max_gpu_surface_scroll_drivers = types.max_gpu_surface_scroll_drivers;
const GpuSurfaceScrollDriver = types.GpuSurfaceScrollDriver;
const max_context_menu_items = types.max_context_menu_items;
const ContextMenuItem = types.ContextMenuItem;
const ContextMenuRequest = types.ContextMenuRequest;
const WidgetAccessibilityRole = types.WidgetAccessibilityRole;
const WidgetAccessibilityActions = types.WidgetAccessibilityActions;
const WidgetAccessibilityTextRange = types.WidgetAccessibilityTextRange;
const WidgetAccessibilityNode = types.WidgetAccessibilityNode;
const WidgetAccessibilitySnapshot = types.WidgetAccessibilitySnapshot;
const WidgetAccessibilityActionKind = types.WidgetAccessibilityActionKind;
const WidgetAccessibilityActionEvent = types.WidgetAccessibilityActionEvent;
const ClipboardData = types.ClipboardData;
const ColorScheme = types.ColorScheme;
const Appearance = types.Appearance;
const Event = types.Event;
const splitDropPaths = types.splitDropPaths;
const EventHandler = types.EventHandler;
const PlatformServices = types.PlatformServices;
const Platform = types.Platform;
const Backend = types.Backend;

pub const max_null_timers: usize = 16;
/// Matches the runtime image registry's slot count
/// (`canvas_limits.max_registered_canvas_images`).
pub const max_gpu_surface_images: usize = 16;

/// One recorded side-channel image upload (see `gpu_surface_images`).
pub const NullGpuSurfaceImage = struct {
    id: u64 = 0,
    width: usize = 0,
    height: usize = 0,
    byte_len: usize = 0,
    sample_rgba: [4]u8 = .{ 0, 0, 0, 0 },
};

pub const NullTimer = struct {
    id: u64 = 0,
    interval_ns: u64 = 0,
    repeats: bool = false,
    active: bool = false,
};

/// Duration table entries for the fake audio player (see
/// `setAudioDuration`): a loaded path whose tail matches `suffix` reports
/// `duration_ms`. A table instead of real decoding keeps tests hermetic —
/// no audio files, no codecs, still honest durations.
pub const max_null_audio_durations: usize = 8;

pub const NullAudioDuration = struct {
    suffix: [128]u8 = undefined,
    suffix_len: usize = 0,
    duration_ms: u64 = 0,
};

/// Every loaded path without a table entry reports this duration.
pub const default_null_audio_duration_ms: u64 = 120_000;

/// How many distinct URLs the fake track cache remembers. Enough for
/// resolution-order suites; a real host's cache is the filesystem.
pub const max_null_audio_cached_urls: usize = 8;

/// The fake audio player's whole state: what a deterministic host would
/// know. Position never advances on its own — tests move it explicitly
/// with `advanceAudio`, mirroring how `fireTimer` drives timers.
/// `streaming` is true while the loaded source is a URL being streamed
/// (not a local file and not a fake-cache hit) — completing a streamed
/// track flips its URL into the fake cache, so the next `audioLoadUrl`
/// of the same URL resolves `.cache` deterministically.
pub const NullAudio = struct {
    loaded: bool = false,
    playing: bool = false,
    streaming: bool = false,
    /// This streamed playback is filling the fake cache: its URL joins
    /// `audio_cached_url_hashes` when it runs to completion (the real
    /// host's atomic install at download end). Stream-only playbacks
    /// (empty cache path) never join.
    cache_fill: bool = false,
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    volume: f32 = 1.0,
    path_storage: [types.max_audio_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub fn path(self: *const NullAudio) []const u8 {
        return self.path_storage[0..self.path_len];
    }
};

pub const NullPlatform = struct {
    surface_value: Surface = .{},
    web_engine: WebEngine = .system,
    app_info: AppInfo = .{},
    gpu_surfaces: bool = false,
    gpu_surface_packets: bool = true,
    /// Model a host that decodes the compact binary packet encoding.
    /// Off by default so existing JSON-asserting tests keep exercising
    /// the JSON wire format; the runtime's per-present negotiation
    /// (binary refused -> JSON attempt in the same frame) is exactly
    /// what a disabled toggle exercises.
    gpu_surface_packet_binary: bool = false,
    /// Model a binary host that ALSO applies incremental `patch`
    /// presents. Disabling it models a binary host without retained
    /// command state (or one that lost it): patch payloads are refused
    /// with `error.UnsupportedService`, which the runtime answers with a
    /// FULL keyed present in the same frame — the resync negotiation the
    /// patch tests pin.
    gpu_surface_packet_binary_patch: bool = true,
    /// Enable the deterministic test image decoder: strict PNGs in the
    /// exact subset `canvas.png.writeRgba8` emits decode through the seam
    /// real platforms serve with CGImageSource/gdk-pixbuf/WIC. Tests
    /// encode raw RGBA fixtures with the canvas PNG writer and exercise
    /// the full decode→register→draw path without bundling a codec.
    image_decode: bool = false,
    image_decode_count: usize = 0,
    requested_frames: u32 = 1,
    loaded_source: ?WebViewSource = null,
    security_policy: security.Policy = .{},
    menus: [max_menus]Menu = undefined,
    menu_items: [max_menu_items]MenuItem = undefined,
    menu_count: usize = 0,
    menu_item_count: usize = 0,
    shortcuts: [max_shortcuts]Shortcut = undefined,
    shortcut_count: usize = 0,
    window_sources: [max_windows]?WebViewSource = [_]?WebViewSource{null} ** max_windows,
    windows: [max_windows]WindowInfo = undefined,
    /// Captured `WindowOptions.resizable` per created window, indexed
    /// like `windows` — `WindowInfo` does not carry it, and tests need
    /// to assert the flag survives to the platform seam (the macOS host
    /// used to drop it at the C ABI).
    window_resizable: [max_windows]bool = [_]bool{true} ** max_windows,
    /// Captured `WindowOptions.titlebar` per created window, indexed
    /// like `windows` — same seam-regression purpose as
    /// `window_resizable` (the startup create used to hardcode it).
    window_titlebar: [max_windows]WindowTitlebarStyle = [_]WindowTitlebarStyle{.standard} ** max_windows,
    /// Minimize calls per window (`minimize_window_fn`), indexed like
    /// `windows`: the observable seam for app-drawn minimize controls —
    /// the null platform has no Dock to genie into, so the count IS the
    /// behavior tests pin.
    window_minimize_count: [max_windows]u32 = [_]u32{0} ** max_windows,
    /// Modeled occlusion per window, indexed like `windows`: true while
    /// the modeled window does not reach the glass (minimized, or a
    /// test covered it via `setWindowOccluded`). Drives the
    /// occluded-emission rule for `.spectrum` reports (`audioSpectrum`
    /// answers null while every open window is occluded), mirroring the
    /// macOS/Windows hosts. Defaults to false — a modeled window is on
    /// glass unless a test says otherwise — so window-less harnesses
    /// and every suite that never occludes keep their reports.
    window_occluded: [max_windows]bool = [_]bool{false} ** max_windows,
    /// Captured `WindowOptions.show` per created window: the
    /// present-before-show policy that must survive to the create seam.
    window_show: [max_windows]types.WindowShowMode = [_]types.WindowShowMode{.immediate} ** max_windows,
    /// Captured `WindowOptions.min_width`/`min_height` per created
    /// window — the content min-size floor that must survive to the
    /// create seam (macOS applies it as `contentMinSize`); same
    /// seam-regression purpose as `window_resizable`.
    window_min_width: [max_windows]f32 = [_]f32{0} ** max_windows,
    window_min_height: [max_windows]f32 = [_]f32{0} ** max_windows,
    /// Live visibility per window, modeling the macOS host: immediate
    /// windows are visible at create; `.on_first_present` windows stay
    /// hidden until their first gpu-surface present (or an explicit
    /// `focusWindow`) shows them.
    window_visible: [max_windows]bool = [_]bool{false} ** max_windows,
    /// The present-before-show ORDERING seam: a per-platform op counter
    /// stamps when each window's first gpu-surface present landed and
    /// when it became visible (0 = never), so tests can assert the
    /// present strictly precedes visibility.
    show_op_seq: usize = 0,
    window_first_present_seq: [max_windows]usize = [_]usize{0} ** max_windows,
    window_shown_seq: [max_windows]usize = [_]usize{0} ** max_windows,
    /// Window ids handed to `startWindowDrag`, in call order: the
    /// window-drag region channel's recording seam. A double-click is
    /// two recorded calls (the host side decides drag vs zoom from the
    /// native event's click count).
    window_drag_starts: [max_windows * 4]WindowId = [_]WindowId{0} ** (max_windows * 4),
    window_drag_start_count: usize = 0,
    /// Chrome overlay geometry `windowChrome` reports for every window
    /// — settable so tests model a hidden-titlebar macOS host (insets
    /// plus the traffic-light cluster frame).
    window_chrome: types.WindowChrome = .{},
    /// The last drag-region mirror pushed through
    /// `setWindowDragRegions` (the Windows `WM_NCHITTEST` seam), so
    /// tests assert what a hit-testing platform would consult. One
    /// mirror suffices: the runtime pushes per canvas view and the
    /// tests drive a single canvas.
    window_drag_regions: [16]types.WindowDragRegion = undefined,
    window_drag_region_count: usize = 0,
    window_drag_region_push_count: usize = 0,
    window_count: usize = 0,
    views: [max_views]NullView = undefined,
    view_count: usize = 0,
    webviews: [max_webviews]NullWebView = undefined,
    webview_count: usize = 0,
    bridge_response: [16 * 1024]u8 = undefined,
    bridge_response_len: usize = 0,
    bridge_response_window_id: WindowId = 0,
    bridge_response_webview_label: []const u8 = "main",
    external_url: [max_external_url_bytes]u8 = undefined,
    external_url_len: usize = 0,
    revealed_path: [max_reveal_path_bytes]u8 = undefined,
    revealed_path_len: usize = 0,
    recent_document_path: [max_recent_document_path_bytes]u8 = undefined,
    recent_document_path_len: usize = 0,
    recent_documents_cleared_count: usize = 0,
    open_dialog_count: usize = 0,
    save_dialog_count: usize = 0,
    message_dialog_count: usize = 0,
    message_dialog_result: MessageDialogResult = .primary,
    notification_title: [max_notification_title_bytes]u8 = undefined,
    notification_title_len: usize = 0,
    notification_subtitle: [max_notification_subtitle_bytes]u8 = undefined,
    notification_subtitle_len: usize = 0,
    notification_body: [max_notification_body_bytes]u8 = undefined,
    notification_body_len: usize = 0,
    notification_count: usize = 0,
    clipboard_mime_type: [max_clipboard_mime_type_bytes]u8 = undefined,
    clipboard_mime_type_len: usize = 0,
    clipboard_data: [max_clipboard_data_bytes]u8 = undefined,
    clipboard_data_len: usize = 0,
    clipboard_write_count: usize = 0,
    credential_service: [max_credential_service_bytes]u8 = undefined,
    credential_service_len: usize = 0,
    credential_account: [max_credential_account_bytes]u8 = undefined,
    credential_account_len: usize = 0,
    credential_secret: [max_credential_secret_bytes]u8 = undefined,
    credential_secret_len: usize = 0,
    credential_set_count: usize = 0,
    credential_delete_count: usize = 0,
    webview_navigate_count: usize = 0,
    tray_icon_path: [max_tray_icon_path_bytes]u8 = undefined,
    tray_icon_path_len: usize = 0,
    tray_title: [max_tray_title_bytes]u8 = undefined,
    tray_title_len: usize = 0,
    tray_tooltip: [max_tray_tooltip_bytes]u8 = undefined,
    tray_tooltip_len: usize = 0,
    tray_items: [max_tray_items]TrayMenuItem = undefined,
    tray_item_count: usize = 0,
    tray_create_count: usize = 0,
    tray_update_count: usize = 0,
    tray_title_update_count: usize = 0,
    tray_remove_count: usize = 0,
    window_event_window_id: WindowId = 0,
    window_event_name: [max_window_event_name_bytes]u8 = undefined,
    window_event_name_len: usize = 0,
    window_event_detail: [max_window_event_detail_bytes]u8 = undefined,
    window_event_detail_len: usize = 0,
    window_event_count: usize = 0,
    gpu_surface_present_window_id: WindowId = 0,
    gpu_surface_present_label_storage: [max_view_label_bytes]u8 = undefined,
    gpu_surface_present_label_len: usize = 0,
    gpu_surface_present_width: usize = 0,
    gpu_surface_present_height: usize = 0,
    gpu_surface_present_scale_factor: f32 = 1,
    gpu_surface_present_dirty_bounds: ?geometry.RectF = null,
    gpu_surface_present_byte_len: usize = 0,
    gpu_surface_present_sample_rgba: [4]u8 = .{ 0, 0, 0, 0 },
    gpu_surface_present_count: usize = 0,
    gpu_surface_packet_present_window_id: WindowId = 0,
    gpu_surface_packet_present_label_storage: [max_view_label_bytes]u8 = undefined,
    gpu_surface_packet_present_label_len: usize = 0,
    gpu_surface_packet_present_frame_index: u64 = 0,
    gpu_surface_packet_present_timestamp_ns: u64 = 0,
    gpu_surface_packet_present_surface_size: geometry.SizeF = .{},
    gpu_surface_packet_present_scale_factor: f32 = 1,
    gpu_surface_packet_present_clear_color_rgba8: [4]u8 = .{ 0, 0, 0, 255 },
    gpu_surface_packet_present_requires_render: bool = false,
    gpu_surface_packet_present_command_count: usize = 0,
    gpu_surface_packet_present_cache_action_count: usize = 0,
    gpu_surface_packet_present_cached_resource_command_count: usize = 0,
    gpu_surface_packet_present_unsupported_command_count: usize = 0,
    gpu_surface_packet_present_representable: bool = true,
    gpu_surface_packet_present_json_len: usize = 0,
    gpu_surface_packet_present_binary_len: usize = 0,
    /// First bytes of the last binary packet payload (magic + version +
    /// header), enough for tests to pin the wire framing without
    /// retaining whole packets.
    gpu_surface_packet_present_binary_prefix: [16]u8 = [_]u8{0} ** 16,
    gpu_surface_packet_present_binary_count: usize = 0,
    /// Full copy of the last binary packet payload, so patch tests can
    /// decode the wire bytes and replay them against a reference retained
    /// store (the Zig-side twin of the AppKit host's command dictionary).
    gpu_surface_packet_present_binary_storage: [types.max_gpu_surface_packet_binary_bytes]u8 = undefined,
    /// Wire load-action code of the last binary present (byte 5 of the
    /// payload: 1 load / 2 clear / 3 patch).
    gpu_surface_packet_present_binary_load_action: u8 = 0,
    /// How many of the recorded binary presents were incremental patches.
    gpu_surface_packet_present_binary_patch_count: usize = 0,
    gpu_surface_packet_present_count: usize = 0,
    gpu_surface_frame_request_window_id: WindowId = 0,
    gpu_surface_frame_request_label_storage: [max_view_label_bytes]u8 = undefined,
    gpu_surface_frame_request_label_len: usize = 0,
    gpu_surface_frame_request_count: usize = 0,
    /// Binary image-upload side-channel recorder: mirrors a packet host's
    /// host-wide texture store (create/replace on upload, drop on remove)
    /// so tests assert the register → re-register → unregister lifecycle
    /// without a real GPU. Disable `gpu_surface_image_uploads` to model a
    /// platform without the seam (`error.UnsupportedService`).
    gpu_surface_image_uploads: bool = true,
    gpu_surface_images: [max_gpu_surface_images]NullGpuSurfaceImage = [_]NullGpuSurfaceImage{.{}} ** max_gpu_surface_images,
    gpu_surface_image_count: usize = 0,
    gpu_surface_image_upload_count: usize = 0,
    gpu_surface_image_remove_count: usize = 0,
    gpu_surface_image_upload_id: u64 = 0,
    gpu_surface_image_upload_width: usize = 0,
    gpu_surface_image_upload_height: usize = 0,
    gpu_surface_image_upload_byte_len: usize = 0,
    gpu_surface_image_upload_sample_rgba: [4]u8 = .{ 0, 0, 0, 0 },
    gpu_surface_image_remove_id: u64 = 0,
    timers: [max_null_timers]NullTimer = [_]NullTimer{.{}} ** max_null_timers,
    timer_count: usize = 0,
    timer_start_count: usize = 0,
    timer_cancel_count: usize = 0,
    /// Whether this modeled host has an audio player. On by default (the
    /// fake below stands in for AVAudioPlayer); tests modelling a
    /// player-less host set it false, which nulls the services AND the
    /// feature report — the same shape as a GTK host whose runtime-loaded
    /// GStreamer is absent.
    audio_playback: bool = true,
    /// Whether this modeled host can stream URL audio sources. On by
    /// default (paired with `audio_playback`, standing in for AVPlayer);
    /// off models a host with a local player but no streaming path —
    /// `audioLoadUrl` is absent and URL playback degrades to one loud
    /// `.failed` Msg, the same explicit degrade a player-less host ships.
    audio_streaming: bool = true,
    /// Whether this modeled host can analyze its own playback into
    /// `.spectrum` band events. On by default (the deterministic fake
    /// generator below stands in for a real analysis tap); off models a
    /// host that plays but cannot reach PCM — `audioSpectrum` answers
    /// null and the feature reports false, so consumers exercise the
    /// honest-absence path (resting glass, never fake dancing).
    audio_spectrum: bool = true,
    /// Whether the modeled filesystem holds the local audio files apps
    /// name in `audioLoad`. On by default (loads succeed hermetically);
    /// off models the gitignored-assets-absent machine: every local load
    /// answers `error.AudioSourceNotFound`, which is exactly what makes
    /// the effects layer fall through to a URL source — the
    /// resolution-order suites pivot on this flag.
    audio_local_files: bool = true,
    /// The deterministic fake audio player: services mutate it, tests
    /// read it and synthesize the events a live host would deliver
    /// (`takeAudioLoaded`, `advanceAudio`).
    audio: NullAudio = .{},
    /// A `.loaded` acknowledgment waiting to be taken — set by a
    /// successful `audioLoad`, consumed by `takeAudioLoaded`.
    audio_loaded_pending: bool = false,
    audio_durations: [max_null_audio_durations]NullAudioDuration = [_]NullAudioDuration{.{}} ** max_null_audio_durations,
    audio_duration_count: usize = 0,
    /// The fake track cache: hashes of URLs whose streamed playback ran
    /// to completion. `audioLoadUrl` answers `.cache` for these — the
    /// deterministic stand-in for a verified on-disk cache entry, so the
    /// "second play is local" story tests hermetically.
    audio_cached_url_hashes: [max_null_audio_cached_urls]u64 = @splat(0),
    audio_cached_url_count: usize = 0,
    audio_load_count: usize = 0,
    audio_load_url_count: usize = 0,
    audio_play_count: usize = 0,
    audio_pause_count: usize = 0,
    audio_stop_count: usize = 0,
    audio_seek_count: usize = 0,
    audio_volume_count: usize = 0,
    /// Pending cross-thread wake requests. Incremented atomically because
    /// `wake_fn` is the one service worker threads call; tests and the
    /// embed host drain it on their own thread via `takeWake` and then
    /// dispatch the `.wake` platform event themselves.
    wake_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Pending cross-thread frame requests (`request_frame_fn`), counted
    /// atomically like `wake_count`: the automation arrival watcher calls
    /// it from its own thread, and a scripted run loop (or test) drains
    /// it via `takeFrameRequest` into `.frame_requested` dispatches.
    frame_request_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    view_cursor_window_id: WindowId = 0,
    view_cursor_label_storage: [max_view_label_bytes]u8 = undefined,
    view_cursor_label_len: usize = 0,
    view_cursor: Cursor = .arrow,
    view_cursor_count: usize = 0,
    /// Native scroll-driver recorder. Opt-in (like `gpu_surfaces`): tests
    /// modelling a platform with native scroll drivers set this true;
    /// everything else keeps the engine's wheel physics untouched.
    gpu_surface_scroll_drivers: bool = false,
    scroll_driver_window_id: WindowId = 0,
    scroll_driver_label_storage: [max_view_label_bytes]u8 = undefined,
    scroll_driver_label_len: usize = 0,
    scroll_drivers: [max_gpu_surface_scroll_drivers]GpuSurfaceScrollDriver = undefined,
    scroll_driver_count: usize = 0,
    scroll_driver_set_count: usize = 0,
    /// Lifetime count of driver entries pushed with `set_offset = true`
    /// (the runtime forcing its offset into the native scroller).
    scroll_driver_set_offset_count: usize = 0,
    /// Whether this modeled host presents native context menus. On by
    /// default (the recorder below stands in for the OS menu); tests
    /// modelling a presenter-less host (the anchored-surface fallback
    /// path) set it false, which nulls the service AND the feature
    /// report — the same shape as a real host without a presenter.
    context_menus: bool = true,
    /// Native context-menu recorder: presentations record the request and
    /// return; tests then feed the selection back as a
    /// `.context_menu_action` platform event.
    context_menu_request_count: usize = 0,
    context_menu_window_id: WindowId = 0,
    context_menu_label_storage: [max_view_label_bytes]u8 = undefined,
    context_menu_label_len: usize = 0,
    context_menu_point: geometry.PointF = .{},
    context_menu_token: u64 = 0,
    context_menu_items: [max_context_menu_items]ContextMenuItem = undefined,
    context_menu_item_count: usize = 0,
    context_menu_label_bytes: [max_context_menu_items * 64]u8 = undefined,
    context_menu_label_bytes_len: usize = 0,

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
                .set_window_drag_regions_fn = setWindowDragRegions,
                .create_view_fn = createView,
                .update_view_fn = updateView,
                .set_view_frame_fn = setViewFrame,
                .set_view_visible_fn = setViewVisible,
                .set_view_cursor_fn = setViewCursor,
                .focus_view_fn = focusView,
                .close_view_fn = closeView,
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
                .create_tray_fn = createTray,
                .update_tray_menu_fn = updateTrayMenu,
                .update_tray_title_fn = updateTrayTitle,
                .remove_tray_fn = removeTray,
                .open_external_url_fn = openExternalUrl,
                .reveal_path_fn = revealPath,
                .add_recent_document_fn = addRecentDocument,
                .clear_recent_documents_fn = clearRecentDocuments,
                .configure_security_policy_fn = configureSecurityPolicy,
                .configure_menus_fn = configureMenus,
                .configure_shortcuts_fn = configureShortcuts,
                .emit_window_event_fn = emitWindowEvent,
                .start_timer_fn = startTimer,
                .cancel_timer_fn = cancelTimer,
                .audio_load_fn = if (self.audio_playback) audioLoad else null,
                .audio_load_url_fn = if (self.audio_playback and self.audio_streaming) audioLoadUrl else null,
                .audio_play_fn = if (self.audio_playback) audioPlay else null,
                .audio_pause_fn = if (self.audio_playback) audioPause else null,
                .audio_stop_fn = if (self.audio_playback) audioStop else null,
                .audio_seek_fn = if (self.audio_playback) audioSeek else null,
                .audio_set_volume_fn = if (self.audio_playback) audioSetVolume else null,
                .wake_fn = wakeService,
                .request_frame_fn = requestFrameService,
                .request_gpu_surface_frame_fn = requestGpuSurfaceFrame,
                .present_gpu_surface_pixels_fn = presentGpuSurfacePixels,
                .present_gpu_surface_packet_fn = presentGpuSurfacePacket,
                .present_gpu_surface_packet_binary_fn = presentGpuSurfacePacketBinary,
                .upload_gpu_surface_image_fn = uploadGpuSurfaceImage,
                .remove_gpu_surface_image_fn = removeGpuSurfaceImage,
                .decode_image_fn = decodeImage,
                .set_gpu_surface_scroll_drivers_fn = setGpuSurfaceScrollDrivers,
                .show_context_menu_fn = if (self.context_menus) showContextMenu else null,
            },
            .app_info = self.app_info,
        };
    }

    fn supportsFeature(context: *anyopaque, feature: PlatformFeature) bool {
        const self: *NullPlatform = @ptrCast(@alignCast(context));
        return switch (feature) {
            .main_webview,
            .child_webviews,
            .native_views,
            .native_control_commands,
            .menus,
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
            => true,
            .gpu_surfaces => self.gpu_surfaces,
            .gpu_surface_scroll_drivers => self.gpu_surface_scroll_drivers,
            .context_menus => self.context_menus,
            .tray => self.web_engine == .system,
            // The null platform has no real view hierarchy to adopt an
            // app-owned platform view into — reporting support would be a
            // lie the first adopt call exposes.
            .view_surface_adoption => false,
            .audio_playback => self.audio_playback,
            .audio_streaming => self.audio_playback and self.audio_streaming,
            .audio_spectrum => self.audio_playback and self.audio_spectrum,
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
        try handler(handler_context, .{ .appearance_changed = .{} });
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

    fn readClipboard(context: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
        return readClipboardData(context, "text/plain", buffer);
    }

    fn writeClipboard(context: ?*anyopaque, text: []const u8) anyerror!void {
        try writeClipboardData(context, .{ .mime_type = "text/plain", .bytes = text });
    }

    fn readClipboardData(context: ?*anyopaque, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, mime_type, self.lastClipboardMimeType())) return error.UnsupportedService;
        return try copyInto(buffer, self.lastClipboardData());
    }

    fn writeClipboardData(context: ?*anyopaque, data: ClipboardData) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.clipboard_mime_type = undefined;
        self.clipboard_data = undefined;
        self.clipboard_mime_type_len = (try copyInto(&self.clipboard_mime_type, data.mime_type)).len;
        self.clipboard_data_len = (try copyInto(&self.clipboard_data, data.bytes)).len;
        self.clipboard_write_count += 1;
    }

    fn loadWindowWebView(context: ?*anyopaque, window_id: WindowId, source: WebViewSource) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (window_id == 1) self.loaded_source = source;
        const index = self.findWindowIndex(window_id) orelse if (window_id == 1 and self.window_count == 0) blk: {
            self.windows[0] = .{
                .id = 1,
                .label = "main",
                .title = self.app_info.resolvedWindowTitle(),
                .frame = geometry.RectF.fromSize(self.surface_value.size),
                .scale_factor = self.surface_value.scale_factor,
                .open = true,
                .focused = true,
            };
            self.window_count = 1;
            break :blk 0;
        } else return error.WindowNotFound;
        if (index >= self.window_sources.len) return error.WindowNotFound;
        self.window_sources[index] = source;
    }

    fn completeBridge(context: ?*anyopaque, response: []const u8) anyerror!void {
        try recordBridgeResponse(context, 1, "main", response);
    }

    fn completeWindowBridge(context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void {
        try recordBridgeResponse(context, window_id, "main", response);
    }

    fn completeWebViewBridge(context: ?*anyopaque, window_id: WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
        try recordBridgeResponse(context, window_id, webview_label, response);
    }

    fn recordBridgeResponse(context: ?*anyopaque, window_id: WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const count = @min(response.len, self.bridge_response.len);
        @memcpy(self.bridge_response[0..count], response[0..count]);
        self.bridge_response_len = count;
        self.bridge_response_window_id = window_id;
        self.bridge_response_webview_label = webview_label;
    }

    fn createWindow(context: ?*anyopaque, options: WindowOptions) anyerror!WindowInfo {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        // A CLOSED window releases its label and id for re-creation —
        // mirroring the real hosts, where a closed NSWindow is gone from
        // the host dictionaries. Model-driven windows reopen under one
        // stable label.
        var scan: usize = 0;
        while (scan < self.window_count) {
            const window = self.windows[scan];
            if (!window.open and (window.id == options.id or std.mem.eql(u8, window.label, options.label))) {
                self.removeWindowAt(scan);
                continue;
            }
            scan += 1;
        }
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
        self.window_resizable[self.window_count] = options.resizable;
        self.window_titlebar[self.window_count] = options.titlebar;
        self.window_show[self.window_count] = options.show;
        self.window_min_width[self.window_count] = options.min_width;
        self.window_min_height[self.window_count] = options.min_height;
        self.window_first_present_seq[self.window_count] = 0;
        // Present-before-show: deferred windows are created hidden and
        // become visible on their first gpu-surface present.
        if (options.show == .immediate) {
            self.window_visible[self.window_count] = true;
            self.show_op_seq += 1;
            self.window_shown_seq[self.window_count] = self.show_op_seq;
        } else {
            self.window_visible[self.window_count] = false;
            self.window_shown_seq[self.window_count] = 0;
        }
        self.window_count += 1;
        return info;
    }

    /// Present-before-show bookkeeping shared by every gpu-surface
    /// present path: stamp the window's first present, then make a
    /// deferred window visible — present strictly before visibility.
    fn recordGpuSurfacePresentForWindow(self: *NullPlatform, window_id: WindowId) void {
        const index = self.findWindowIndex(window_id) orelse return;
        if (self.window_first_present_seq[index] == 0) {
            self.show_op_seq += 1;
            self.window_first_present_seq[index] = self.show_op_seq;
        }
        if (!self.window_visible[index] and self.window_show[index] == .on_first_present) {
            self.window_visible[index] = true;
            self.show_op_seq += 1;
            self.window_shown_seq[index] = self.show_op_seq;
        }
    }

    fn startWindowDrag(context: ?*anyopaque, window_id: WindowId) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        _ = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
        if (self.window_drag_start_count >= self.window_drag_starts.len) return error.WindowLimitReached;
        self.window_drag_starts[self.window_drag_start_count] = window_id;
        self.window_drag_start_count += 1;
    }

    fn windowChrome(context: ?*anyopaque, window_id: WindowId) types.WindowChrome {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        _ = window_id;
        return self.window_chrome;
    }

    fn setWindowDragRegions(context: ?*anyopaque, window_id: WindowId, label: []const u8, regions: []const types.WindowDragRegion) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        // A mirror push, not a window operation: accept any id (the
        // runtime may install layouts before this platform tracks the
        // window), mirroring how `windowChrome` answers for all ids.
        _ = window_id;
        _ = label;
        if (regions.len > self.window_drag_regions.len) return error.WindowLimitReached;
        for (regions, 0..) |region, index| self.window_drag_regions[index] = region;
        self.window_drag_region_count = regions.len;
        self.window_drag_region_push_count += 1;
    }

    fn focusWindow(context: ?*anyopaque, window_id: WindowId) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const focused_index = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
        for (self.windows[0..self.window_count], 0..) |*window, index| {
            window.focused = index == focused_index;
        }
        // An explicit focus shows a still-deferred window (the macOS
        // host's makeKeyAndOrderFront override of present-before-show).
        if (!self.window_visible[focused_index]) {
            self.window_visible[focused_index] = true;
            self.show_op_seq += 1;
            self.window_shown_seq[focused_index] = self.show_op_seq;
        }
        // Focusing brings a window back to the glass (clicking the Dock
        // restores a minimized window and orders it in), so the modeled
        // occlusion clears — spectrum reports resume on the next beat.
        self.window_occluded[focused_index] = false;
    }

    fn closeWindow(context: ?*anyopaque, window_id: WindowId) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
        self.windows[index].open = false;
        self.windows[index].focused = false;
        self.removeViewsForWindow(window_id);
        self.removeWebViewsForWindow(window_id);
    }

    fn minimizeWindow(context: ?*anyopaque, window_id: WindowId) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
        // A minimized window stays OPEN (it comes back from the Dock);
        // only focus leaves. The count is the pinned observable. A
        // minimized window is off the glass, so the modeled occlusion
        // flips too — the real hosts' spectrum gating keys on exactly
        // this fact.
        self.windows[index].focused = false;
        self.window_minimize_count[index] += 1;
        self.window_occluded[index] = true;
    }

    fn createView(context: ?*anyopaque, options: ViewOptions) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (options.kind == .webview) return createWebView(context, options.webViewOptions());
        if (options.kind == .gpu_surface and !self.gpu_surfaces) return error.UnsupportedViewKind;
        try self.validateViewOptions(options);
        if (self.findViewIndex(options.window_id, options.label) != null) return error.DuplicateViewLabel;
        if (self.view_count >= max_views) return error.ViewLimitReached;
        const index = self.view_count;
        self.view_count += 1;
        self.views[index] = .{
            .window_id = options.window_id,
            .kind = options.kind,
            .frame = options.frame,
            .layer = options.layer,
            .visible = options.visible,
            .enabled = options.enabled,
            .gpu_size = if (options.kind == .gpu_surface) options.frame.size() else geometry.SizeF.init(0, 0),
            .gpu_backend = if (options.kind == .gpu_surface) options.gpu_surface.backend else .none,
            .gpu_pixel_format = if (options.kind == .gpu_surface) options.gpu_surface.pixel_format else .none,
            .gpu_present_mode = if (options.kind == .gpu_surface) options.gpu_surface.present_mode else .none,
            .gpu_alpha_mode = if (options.kind == .gpu_surface) options.gpu_surface.alpha_mode else .none,
            .gpu_color_space = if (options.kind == .gpu_surface) options.gpu_surface.color_space else .none,
            .gpu_vsync = options.kind == .gpu_surface and options.gpu_surface.vsync,
            .gpu_status = if (options.kind == .gpu_surface) .ready else .unavailable,
            .open = true,
        };
        try self.copyViewStrings(index, options.label, options.parent, options.role, options.accessibility_label, options.text, options.command);
    }

    fn updateView(context: ?*anyopaque, window_id: WindowId, label: []const u8, patch: ViewPatch) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (patch.frame) |frame| {
            if (!isValidViewFrame(frame)) return error.InvalidViewOptions;
            self.views[index].frame = frame;
        }
        if (patch.layer) |layer| self.views[index].layer = layer;
        if (patch.visible) |visible| self.views[index].visible = visible;
        if (patch.enabled) |enabled| self.views[index].enabled = enabled;
        if (patch.role) |role| {
            if (role.len > max_view_role_bytes) return error.ViewRoleTooLarge;
            self.views[index].role = try copyInto(&self.views[index].role_storage, role);
        }
        if (patch.accessibility_label) |accessibility_label| {
            if (accessibility_label.len > max_view_accessibility_label_bytes) return error.ViewAccessibilityLabelTooLarge;
            self.views[index].accessibility_label = try copyInto(&self.views[index].accessibility_label_storage, accessibility_label);
        }
        if (patch.text) |text| {
            if (text.len > max_view_text_bytes) return error.ViewTextTooLarge;
            self.views[index].text = try copyInto(&self.views[index].text_storage, text);
        }
        if (patch.command) |command| {
            if (command.len > max_view_command_bytes) return error.InvalidCommand;
            self.views[index].command = try copyInto(&self.views[index].command_storage, command);
        }
        if (patch.url != null) return error.InvalidViewOptions;
    }

    fn setViewFrame(context: ?*anyopaque, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (!isValidViewFrame(frame)) return error.InvalidViewOptions;
        self.views[index].frame = frame;
    }

    fn setViewVisible(context: ?*anyopaque, window_id: WindowId, label: []const u8, visible: bool) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        self.views[index].visible = visible;
    }

    fn setViewCursor(context: ?*anyopaque, window_id: WindowId, label: []const u8, cursor: Cursor) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.UnsupportedViewKind;
        self.view_cursor_window_id = window_id;
        self.view_cursor_label_storage = undefined;
        self.view_cursor_label_len = (try copyInto(&self.view_cursor_label_storage, label)).len;
        self.view_cursor = cursor;
        self.view_cursor_count += 1;
    }

    fn focusView(context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, label, "main")) {
            if (self.findWindowIndex(window_id)) |window_index| {
                if (!self.windows[window_index].open) return error.WindowNotFound;
            } else if (window_id != 1) {
                return error.WindowNotFound;
            }
            return;
        }
        if (self.findWebViewIndex(window_id, label) != null) return;
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (!self.views[index].enabled or !self.views[index].visible) return error.UnsupportedViewFocus;
    }

    fn closeView(context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        var label_storage: [max_view_label_bytes]u8 = undefined;
        const view_label = copyInto(&label_storage, self.views[index].label) catch unreachable;
        self.removeChildViewsForParent(window_id, view_label);
        if (self.findViewIndex(window_id, view_label)) |current_index| self.removeViewAt(current_index);
    }

    fn createWebView(context: ?*anyopaque, options: WebViewOptions) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (self.findWindowIndex(options.window_id)) |window_index| {
            if (!self.windows[window_index].open) return error.WindowNotFound;
        } else if (options.window_id != 1) {
            return error.WindowNotFound;
        }
        if (options.label.len == 0) return error.InvalidWebViewOptions;
        if (options.url.len == 0) return error.MissingWebViewUrl;
        if (options.label.len > max_webview_label_bytes) return error.WebViewLabelTooLarge;
        if (options.url.len > max_webview_url_bytes) return error.WebViewUrlTooLarge;
        if (!isValidWebViewFrame(options.frame)) return error.InvalidWebViewOptions;
        if (self.findWebViewIndex(options.window_id, options.label) != null) return error.DuplicateWebViewLabel;
        if (self.webview_count >= max_webviews) return error.WebViewLimitReached;
        const index = self.webview_count;
        self.webview_count += 1;
        var webview = &self.webviews[index];
        webview.window_id = options.window_id;
        webview.frame = options.frame;
        webview.layer = options.layer;
        webview.transparent = options.transparent;
        webview.bridge_enabled = options.bridge_enabled;
        webview.open = true;
        @memcpy(webview.label_storage[0..options.label.len], options.label);
        @memcpy(webview.url_storage[0..options.url.len], options.url);
        webview.label = webview.label_storage[0..options.label.len];
        webview.url = webview.url_storage[0..options.url.len];
    }

    fn setWebViewFrame(context: ?*anyopaque, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, label, "main")) {
            _ = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
            if (!isValidWebViewFrame(frame)) return error.InvalidWebViewOptions;
            return;
        }
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        if (!isValidWebViewFrame(frame)) return error.InvalidWebViewOptions;
        self.webviews[index].frame = frame;
    }

    fn navigateWebView(context: ?*anyopaque, window_id: WindowId, label: []const u8, url: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        if (url.len == 0) return error.MissingWebViewUrl;
        if (url.len > max_webview_url_bytes) return error.WebViewUrlTooLarge;
        var webview = &self.webviews[index];
        @memcpy(webview.url_storage[0..url.len], url);
        webview.url = webview.url_storage[0..url.len];
        self.webview_navigate_count += 1;
    }

    fn setWebViewZoom(context: ?*anyopaque, window_id: WindowId, label: []const u8, zoom: f64) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, label, "main")) {
            _ = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
            if (zoom < 0.25 or zoom > 5.0) return error.InvalidWebViewOptions;
            return;
        }
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        if (zoom < 0.25 or zoom > 5.0) return error.InvalidWebViewOptions;
        self.webviews[index].zoom = zoom;
    }

    fn setWebViewLayer(context: ?*anyopaque, window_id: WindowId, label: []const u8, layer: i32) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, label, "main")) {
            _ = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
            return;
        }
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        self.webviews[index].layer = layer;
    }

    fn closeWebView(context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        self.removeWebViewAt(index);
    }

    fn showOpenDialog(context: ?*anyopaque, options: OpenDialogOptions, buffer: []u8) anyerror!OpenDialogResult {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        _ = options;
        const path = "/tmp/native-sdk-open.txt";
        const copied = try copyInto(buffer, path);
        self.open_dialog_count += 1;
        return .{ .count = 1, .paths = copied };
    }

    fn showSaveDialog(context: ?*anyopaque, options: SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        const path = if (options.default_name.len > 0) options.default_name else "/tmp/native-sdk-save.txt";
        const copied = try copyInto(buffer, path);
        self.save_dialog_count += 1;
        return copied;
    }

    fn showMessageDialog(context: ?*anyopaque, options: MessageDialogOptions) anyerror!MessageDialogResult {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        _ = options;
        self.message_dialog_count += 1;
        return self.message_dialog_result;
    }

    fn showNotification(context: ?*anyopaque, options: NotificationOptions) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.notification_title = undefined;
        self.notification_subtitle = undefined;
        self.notification_body = undefined;
        self.notification_title_len = (try copyInto(&self.notification_title, options.title)).len;
        self.notification_subtitle_len = (try copyInto(&self.notification_subtitle, options.subtitle)).len;
        self.notification_body_len = (try copyInto(&self.notification_body, options.body)).len;
        self.notification_count += 1;
    }

    fn setCredential(context: ?*anyopaque, credential: Credential) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.credential_service = undefined;
        self.credential_account = undefined;
        self.credential_secret = undefined;
        self.credential_service_len = (try copyInto(&self.credential_service, credential.service)).len;
        self.credential_account_len = (try copyInto(&self.credential_account, credential.account)).len;
        self.credential_secret_len = (try copyInto(&self.credential_secret, credential.secret)).len;
        self.credential_set_count += 1;
    }

    fn getCredential(context: ?*anyopaque, key: CredentialKey, buffer: []u8) anyerror![]const u8 {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (self.credential_secret_len == 0) return error.CredentialNotFound;
        if (!std.mem.eql(u8, key.service, self.lastCredentialService()) or !std.mem.eql(u8, key.account, self.lastCredentialAccount())) return error.CredentialNotFound;
        return try copyInto(buffer, self.lastCredentialSecret());
    }

    fn deleteCredential(context: ?*anyopaque, key: CredentialKey) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (self.credential_secret_len == 0) return error.CredentialNotFound;
        if (!std.mem.eql(u8, key.service, self.lastCredentialService()) or !std.mem.eql(u8, key.account, self.lastCredentialAccount())) return error.CredentialNotFound;
        self.credential_secret_len = 0;
        self.credential_delete_count += 1;
    }

    fn createTray(context: ?*anyopaque, options: TrayOptions) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.tray_icon_path = undefined;
        self.tray_title = undefined;
        self.tray_tooltip = undefined;
        self.tray_icon_path_len = (try copyInto(&self.tray_icon_path, options.icon_path)).len;
        self.tray_title_len = (try copyInto(&self.tray_title, options.title)).len;
        self.tray_tooltip_len = (try copyInto(&self.tray_tooltip, options.tooltip)).len;
        try updateTrayMenu(context, options.items);
        self.tray_create_count += 1;
    }

    fn updateTrayMenu(context: ?*anyopaque, items: []const TrayMenuItem) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (items.len > self.tray_items.len) return error.InvalidTrayOptions;
        for (items, 0..) |item, index| self.tray_items[index] = item;
        self.tray_item_count = items.len;
        self.tray_update_count += 1;
    }

    fn updateTrayTitle(context: ?*anyopaque, title: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.tray_title = undefined;
        self.tray_title_len = (try copyInto(&self.tray_title, title)).len;
        self.tray_title_update_count += 1;
    }

    fn removeTray(context: ?*anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.tray_item_count = 0;
        self.tray_remove_count += 1;
    }

    fn openExternalUrl(context: ?*anyopaque, url: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.external_url = undefined;
        self.external_url_len = 0;
        self.external_url_len = (try copyInto(&self.external_url, url)).len;
    }

    fn revealPath(context: ?*anyopaque, path: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.revealed_path = undefined;
        self.revealed_path_len = 0;
        self.revealed_path_len = (try copyInto(&self.revealed_path, path)).len;
    }

    fn addRecentDocument(context: ?*anyopaque, path: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.recent_document_path = undefined;
        self.recent_document_path_len = 0;
        self.recent_document_path_len = (try copyInto(&self.recent_document_path, path)).len;
    }

    fn clearRecentDocuments(context: ?*anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.recent_document_path_len = 0;
        self.recent_documents_cleared_count += 1;
    }

    fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.security_policy = policy;
    }

    fn configureMenus(context: ?*anyopaque, menus: []const Menu) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        try validateMenus(menus);
        self.menu_count = 0;
        self.menu_item_count = 0;
        for (menus) |menu| {
            const start = self.menu_item_count;
            for (menu.items) |item| {
                self.menu_items[self.menu_item_count] = item;
                self.menu_item_count += 1;
            }
            const end = self.menu_item_count;
            self.menus[self.menu_count] = .{
                .title = menu.title,
                .items = self.menu_items[start..end],
            };
            self.menu_count += 1;
        }
    }

    fn configureShortcuts(context: ?*anyopaque, shortcuts: []const Shortcut) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (shortcuts.len > self.shortcuts.len) return error.InvalidShortcut;
        for (shortcuts, 0..) |shortcut, index| {
            try validateShortcut(shortcut);
            self.shortcuts[index] = shortcut;
        }
        self.shortcut_count = shortcuts.len;
    }

    fn startTimer(context: ?*anyopaque, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.timer_start_count += 1;
        const entry: NullTimer = .{ .id = id, .interval_ns = interval_ns, .repeats = repeats, .active = true };
        if (self.findTimerIndex(id)) |index| {
            self.timers[index] = entry;
            return;
        }
        if (self.timer_count >= max_null_timers) return error.UnsupportedService;
        self.timers[self.timer_count] = entry;
        self.timer_count += 1;
    }

    fn cancelTimer(context: ?*anyopaque, id: u64) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.timer_cancel_count += 1;
        if (self.findTimerIndex(id)) |index| self.timers[index].active = false;
    }

    fn audioLoad(context: ?*anyopaque, path: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.audio_load_count += 1;
        if (path.len > self.audio.path_storage.len) return error.AudioPathTooLarge;
        // Model the assets-absent machine: the local file is not there,
        // exactly the synchronous refusal a real host's open gives.
        if (!self.audio_local_files) return error.AudioSourceNotFound;
        @memcpy(self.audio.path_storage[0..path.len], path);
        self.audio.path_len = path.len;
        self.audio.loaded = true;
        self.audio.playing = false;
        self.audio.streaming = false;
        self.audio.position_ms = 0;
        self.audio.duration_ms = self.audioDurationFor(path);
        self.audio_loaded_pending = true;
    }

    /// URL sources, deterministically: a URL whose streamed playback has
    /// completed before answers `.cache` (the fake stand-in for a
    /// verified on-disk entry — no network, plays as a local file);
    /// anything else "streams" (`.stream`) and joins the fake cache when
    /// `advanceAudio` runs it to completion. `cache_path` gates caching
    /// like the real seam: empty means stream-only, never cached.
    /// Durations come from the same suffix table local loads use — URLs
    /// end in the same track file names.
    fn audioLoadUrl(context: ?*anyopaque, url: []const u8, cache_path: []const u8, expected_bytes: u64) anyerror!types.AudioLoadResolution {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        _ = expected_bytes;
        self.audio_load_url_count += 1;
        if (url.len > self.audio.path_storage.len) return error.AudioPathTooLarge;
        const caching = cache_path.len > 0;
        const cached = caching and self.audioUrlCached(url);
        @memcpy(self.audio.path_storage[0..url.len], url);
        self.audio.path_len = url.len;
        self.audio.loaded = true;
        self.audio.playing = false;
        self.audio.streaming = !cached;
        self.audio.cache_fill = caching and !cached;
        self.audio.position_ms = 0;
        self.audio.duration_ms = self.audioDurationFor(url);
        self.audio_loaded_pending = true;
        return if (cached) .cache else .stream;
    }

    fn audioPlay(context: ?*anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.audio_play_count += 1;
        if (!self.audio.loaded) return error.InvalidAudioOptions;
        self.audio.playing = true;
    }

    fn audioPause(context: ?*anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.audio_pause_count += 1;
        self.audio.playing = false;
    }

    fn audioStop(context: ?*anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.audio_stop_count += 1;
        self.audio = .{ .volume = self.audio.volume };
        self.audio_loaded_pending = false;
    }

    fn audioSeek(context: ?*anyopaque, position_ms: u64) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.audio_seek_count += 1;
        if (!self.audio.loaded) return error.InvalidAudioOptions;
        self.audio.position_ms = @min(position_ms, self.audio.duration_ms);
    }

    fn audioSetVolume(context: ?*anyopaque, volume: f32) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.audio_volume_count += 1;
        self.audio.volume = volume;
    }

    fn audioUrlHash(url: []const u8) u64 {
        return std.hash.Wyhash.hash(0, url);
    }

    fn audioUrlCached(self: *const NullPlatform, url: []const u8) bool {
        const hash = audioUrlHash(url);
        for (self.audio_cached_url_hashes[0..self.audio_cached_url_count]) |cached| {
            if (cached == hash) return true;
        }
        return false;
    }

    /// Flip a completed stream's URL into the fake cache — the
    /// deterministic analog of the host's verify-then-rename install. A
    /// full table drops the entry (the next play streams again), which
    /// is also an honest cache behavior.
    fn audioRecordCached(self: *NullPlatform, url: []const u8) void {
        if (self.audioUrlCached(url)) return;
        if (self.audio_cached_url_count >= max_null_audio_cached_urls) return;
        self.audio_cached_url_hashes[self.audio_cached_url_count] = audioUrlHash(url);
        self.audio_cached_url_count += 1;
    }

    fn audioDurationFor(self: *const NullPlatform, path: []const u8) u64 {
        for (self.audio_durations[0..self.audio_duration_count]) |entry| {
            const suffix = entry.suffix[0..entry.suffix_len];
            if (suffix.len <= path.len and std.mem.eql(u8, path[path.len - suffix.len ..], suffix)) {
                return entry.duration_ms;
            }
        }
        return default_null_audio_duration_ms;
    }

    /// Test helper: register a duration for any loaded path ending in
    /// `suffix`. Paths without a match report
    /// `default_null_audio_duration_ms`.
    pub fn setAudioDuration(self: *NullPlatform, suffix: []const u8, duration_ms: u64) !void {
        if (suffix.len == 0 or suffix.len > 128) return error.InvalidAudioOptions;
        if (self.audio_duration_count >= max_null_audio_durations) return error.InvalidAudioOptions;
        var entry = &self.audio_durations[self.audio_duration_count];
        @memcpy(entry.suffix[0..suffix.len], suffix);
        entry.suffix_len = suffix.len;
        entry.duration_ms = duration_ms;
        self.audio_duration_count += 1;
    }

    /// Consume the pending `.loaded` acknowledgment, returning the
    /// platform event a live host would deliver after a successful load
    /// (or null when no load is waiting). Dispatch it through the runtime,
    /// like `fireTimer`.
    pub fn takeAudioLoaded(self: *NullPlatform) ?Event {
        if (!self.audio_loaded_pending) return null;
        self.audio_loaded_pending = false;
        return .{ .audio = .{
            .kind = .loaded,
            .position_ms = self.audio.position_ms,
            .duration_ms = self.audio.duration_ms,
            .playing = self.audio.playing,
        } };
    }

    /// Test helper: advance fake playback by `delta_ms` and synthesize
    /// the event a live host's position timer would deliver — a
    /// `.position` tick, or `.completed` when the track end is reached
    /// (which stops playback, matching AVAudioPlayer). Returns null when
    /// nothing is loaded or playing; position never advances on its own.
    pub fn advanceAudio(self: *NullPlatform, delta_ms: u64) ?Event {
        if (!self.audio.loaded or !self.audio.playing) return null;
        self.audio.position_ms = @min(self.audio.position_ms + delta_ms, self.audio.duration_ms);
        if (self.audio.position_ms >= self.audio.duration_ms) {
            self.audio.playing = false;
            self.audio.position_ms = self.audio.duration_ms;
            // A cache-filling stream that ran to completion installs its
            // cache entry — the next `audioLoadUrl` of this URL answers
            // `.cache`, deterministically modeling "faster next time".
            if (self.audio.streaming and self.audio.cache_fill) {
                self.audioRecordCached(self.audio.path());
            }
            return .{ .audio = .{
                .kind = .completed,
                .position_ms = self.audio.position_ms,
                .duration_ms = self.audio.duration_ms,
                .playing = false,
            } };
        }
        return .{ .audio = .{
            .kind = .position,
            .position_ms = self.audio.position_ms,
            .duration_ms = self.audio.duration_ms,
            .playing = true,
        } };
    }

    /// Test helper: synthesize a mid-stream stall — the `.position`
    /// event a live host's tick delivers while the stream waits for
    /// network bytes (`buffering = true`, position held). Only a
    /// streaming playback can stall; local files and cache hits never
    /// buffer, so anything else answers null.
    pub fn stallAudio(self: *NullPlatform) ?Event {
        if (!self.audio.loaded or !self.audio.playing or !self.audio.streaming) return null;
        return .{ .audio = .{
            .kind = .position,
            .position_ms = self.audio.position_ms,
            .duration_ms = self.audio.duration_ms,
            .playing = true,
            .buffering = true,
        } };
    }

    /// Test helper: synthesize the `.spectrum` band report a live host's
    /// analysis tap would deliver at this instant — the deterministic
    /// fake generator standing in for a real FFT, a pure function of
    /// (loaded source, playback position), so the same fake playback
    /// always paints the same bars and the journal round-trips exactly.
    /// The shape mirrors the reference scale: a mid-weighted comb whose
    /// motion derives from the position clock, quantized to the u8 band
    /// bytes real hosts emit. Null while nothing is audibly playing
    /// (pause and stop starve the stream exactly like real hosts) and on
    /// a modeled host that cannot analyze (`audio_spectrum = false`).
    pub fn audioSpectrum(self: *NullPlatform) ?Event {
        if (!self.audio_playback or !self.audio_spectrum) return null;
        if (!self.audio.loaded or !self.audio.playing) return null;
        // The occluded-emission rule, modeled: bands describe a display,
        // so while every open window is off the glass (minimized or
        // test-occluded via `setWindowOccluded`) the host emits nothing
        // — the journal shows honest silence for the stretch, and the
        // next report after a reveal carries current bands. Keyed on
        // the modeled occlusion flag ONLY (default false), so
        // window-less harnesses keep their deterministic reports.
        if (self.allOpenWindowsOccluded()) return null;
        var event = Event{ .audio = .{
            .kind = .spectrum,
            .position_ms = self.audio.position_ms,
            .duration_ms = self.audio.duration_ms,
            .playing = true,
        } };
        const seed: f32 = @floatFromInt(audioUrlHash(self.audio.path()) % 97);
        const phase = @as(f32, @floatFromInt(self.audio.position_ms)) / 1000.0;
        for (&event.audio.bands, 0..) |*band, index| {
            const x: f32 = @floatFromInt(index);
            // Lows tall, highs rolled off — the plausible silhouette a
            // consumer can sanity-check band ordering against.
            const envelope = 0.35 + 0.65 * @exp(-x * x / 420.0);
            const wave = 0.6 * @abs(@sin(phase * (3.4 + seed * 0.026) + x * 0.55 + seed)) +
                0.4 * @abs(@sin(phase * 7.3 + x * 1.35 + seed * 0.5));
            band.* = @intFromFloat(std.math.clamp(envelope * wave, 0.0, 1.0) * 255.0);
        }
        return event;
    }

    /// Test helper: synthesize an asynchronous decode/device failure,
    /// the `.failed` event a live host would deliver. Unloads the player
    /// like a real failure would.
    pub fn failAudio(self: *NullPlatform) ?Event {
        if (!self.audio.loaded) return null;
        self.audio = .{ .volume = self.audio.volume };
        self.audio_loaded_pending = false;
        return .{ .audio = .{ .kind = .failed } };
    }

    fn wakeService(context: ?*anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        _ = self.wake_count.fetchAdd(1, .release);
    }

    fn requestFrameService(context: ?*anyopaque) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        _ = self.frame_request_count.fetchAdd(1, .release);
    }

    /// Deterministic decode seam for tests (see `image_decode`): parses
    /// the strict PNG subset the canvas writer emits. Off by default so
    /// the null platform models codec-less hosts.
    fn decodeImage(context: ?*anyopaque, bytes: []const u8, buffer: []u8) anyerror!types.DecodedImage {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.image_decode) return error.UnsupportedService;
        self.image_decode_count += 1;
        const decoded = canvas.png.decodeRgba8(bytes, buffer) catch |err| return switch (err) {
            error.PngPixelBufferTooSmall => error.ImageTooLarge,
            else => error.ImageDecodeFailed,
        };
        return .{ .width = decoded.width, .height = decoded.height, .rgba8 = decoded.rgba8 };
    }

    /// Consume one pending wake request, returning the `.wake` platform
    /// event a live loop would deliver (or null when none are pending).
    /// Tests dispatch the returned event through the runtime, mirroring
    /// how host loops marshal `wake_fn` calls back onto their own thread.
    pub fn takeWake(self: *NullPlatform) ?Event {
        var current = self.wake_count.load(.acquire);
        while (current > 0) {
            if (self.wake_count.cmpxchgWeak(current, current - 1, .acq_rel, .acquire)) |actual| {
                current = actual;
            } else {
                return .wake;
            }
        }
        return null;
    }

    pub fn pendingWakeCount(self: *const NullPlatform) usize {
        return self.wake_count.load(.acquire);
    }

    /// Consume one pending cross-thread frame request, returning the
    /// `.frame_requested` event a live loop would deliver (or null when
    /// none are pending) — `takeWake`'s twin for `request_frame_fn`.
    pub fn takeFrameRequest(self: *NullPlatform) ?Event {
        var current = self.frame_request_count.load(.acquire);
        while (current > 0) {
            if (self.frame_request_count.cmpxchgWeak(current, current - 1, .acq_rel, .acquire)) |actual| {
                current = actual;
            } else {
                return .frame_requested;
            }
        }
        return null;
    }

    pub fn pendingFrameRequestCount(self: *const NullPlatform) usize {
        return self.frame_request_count.load(.acquire);
    }

    /// Test helper: synthesize the platform event a live timer would deliver.
    /// Returns null when the timer was never started or has been cancelled.
    /// A non-repeating timer deactivates after firing once, matching host
    /// backends. Dispatch the returned event through the runtime to drive
    /// timers deterministically in tests.
    pub fn fireTimer(self: *NullPlatform, id: u64, timestamp_ns: u64) ?Event {
        const index = self.findTimerIndex(id) orelse return null;
        if (!self.timers[index].active) return null;
        if (!self.timers[index].repeats) self.timers[index].active = false;
        return .{ .timer = .{ .id = id, .timestamp_ns = timestamp_ns } };
    }

    pub fn startedTimer(self: *const NullPlatform, id: u64) ?NullTimer {
        const index = self.findTimerIndex(id) orelse return null;
        return self.timers[index];
    }

    pub fn activeTimerCount(self: *const NullPlatform) usize {
        var count: usize = 0;
        for (self.timers[0..self.timer_count]) |timer| {
            if (timer.active) count += 1;
        }
        return count;
    }

    pub fn timerStartCount(self: *const NullPlatform) usize {
        return self.timer_start_count;
    }

    pub fn timerCancelCount(self: *const NullPlatform) usize {
        return self.timer_cancel_count;
    }

    fn findTimerIndex(self: *const NullPlatform, id: u64) ?usize {
        for (self.timers[0..self.timer_count], 0..) |timer, index| {
            if (timer.id == id) return index;
        }
        return null;
    }

    fn emitWindowEvent(context: ?*anyopaque, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.window_event_name = undefined;
        self.window_event_detail = undefined;
        self.window_event_window_id = window_id;
        self.window_event_name_len = (try copyInto(&self.window_event_name, name)).len;
        self.window_event_detail_len = (try copyInto(&self.window_event_detail, detail_json)).len;
        self.window_event_count += 1;
    }

    fn presentGpuSurfacePixels(context: ?*anyopaque, pixels: GpuSurfacePixels) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surfaces) return error.UnsupportedService;
        const view_index = self.findViewIndex(pixels.window_id, pixels.label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidGpuSurfacePixels;
        const expected = pixels.expectedByteLen() orelse return error.InvalidGpuSurfacePixels;
        if (pixels.rgba8.len != expected) return error.InvalidGpuSurfacePixels;

        self.gpu_surface_present_window_id = pixels.window_id;
        self.gpu_surface_present_label_storage = undefined;
        self.gpu_surface_present_label_len = (try copyInto(&self.gpu_surface_present_label_storage, pixels.label)).len;
        self.gpu_surface_present_width = pixels.width;
        self.gpu_surface_present_height = pixels.height;
        self.gpu_surface_present_scale_factor = pixels.scale_factor;
        self.gpu_surface_present_dirty_bounds = pixels.dirty_bounds;
        self.gpu_surface_present_byte_len = pixels.rgba8.len;
        self.gpu_surface_present_sample_rgba = if (pixels.rgba8.len >= 4)
            .{ pixels.rgba8[0], pixels.rgba8[1], pixels.rgba8[2], pixels.rgba8[3] }
        else
            .{ 0, 0, 0, 0 };
        self.gpu_surface_present_count += 1;
        self.recordGpuSurfacePresentForWindow(pixels.window_id);
    }

    fn requestGpuSurfaceFrame(context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surfaces) return error.UnsupportedService;
        const view_index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;

        self.gpu_surface_frame_request_window_id = window_id;
        self.gpu_surface_frame_request_label_storage = undefined;
        self.gpu_surface_frame_request_label_len = (try copyInto(&self.gpu_surface_frame_request_label_storage, label)).len;
        self.gpu_surface_frame_request_count += 1;
    }

    fn presentGpuSurfacePacket(context: ?*anyopaque, packet: GpuSurfacePacket) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surfaces) return error.UnsupportedService;
        if (!self.gpu_surface_packets) return error.UnsupportedService;
        const view_index = self.findViewIndex(packet.window_id, packet.label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidGpuSurfacePacket;
        if (packet.json.len == 0 or packet.json.len > max_gpu_surface_packet_json_bytes) return error.InvalidGpuSurfacePacket;

        self.gpu_surface_packet_present_window_id = packet.window_id;
        self.gpu_surface_packet_present_label_storage = undefined;
        self.gpu_surface_packet_present_label_len = (try copyInto(&self.gpu_surface_packet_present_label_storage, packet.label)).len;
        self.gpu_surface_packet_present_frame_index = packet.frame_index;
        self.gpu_surface_packet_present_timestamp_ns = packet.timestamp_ns;
        self.gpu_surface_packet_present_surface_size = packet.surface_size;
        self.gpu_surface_packet_present_scale_factor = packet.scale_factor;
        self.gpu_surface_packet_present_clear_color_rgba8 = packet.clear_color_rgba8;
        self.gpu_surface_packet_present_requires_render = packet.requires_render;
        self.gpu_surface_packet_present_command_count = packet.command_count;
        self.gpu_surface_packet_present_cache_action_count = packet.cache_action_count;
        self.gpu_surface_packet_present_cached_resource_command_count = packet.cached_resource_command_count;
        self.gpu_surface_packet_present_unsupported_command_count = packet.unsupported_command_count;
        self.gpu_surface_packet_present_representable = packet.representable;
        self.gpu_surface_packet_present_json_len = packet.json.len;
        self.gpu_surface_packet_present_count += 1;
        self.recordGpuSurfacePresentForWindow(packet.window_id);
    }

    /// Binary-encoding twin of `presentGpuSurfacePacket`: same recorder
    /// fields plus the binary length and a payload prefix, gated by the
    /// `gpu_surface_packet_binary` toggle so tests choose which wire
    /// encoding a modeled host accepts.
    fn presentGpuSurfacePacketBinary(context: ?*anyopaque, packet: GpuSurfacePacket) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surfaces) return error.UnsupportedService;
        if (!self.gpu_surface_packets) return error.UnsupportedService;
        if (!self.gpu_surface_packet_binary) return error.UnsupportedService;
        const view_index = self.findViewIndex(packet.window_id, packet.label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidGpuSurfacePacket;
        if (packet.binary.len == 0 or packet.binary.len > types.max_gpu_surface_packet_binary_bytes) return error.InvalidGpuSurfacePacket;
        // Wire byte 5 is the load-action code; 3 = incremental patch. A
        // host modeled without retained state refuses patches, which the
        // runtime answers with a full keyed present in the same frame.
        const load_action: u8 = if (packet.binary.len > 5) packet.binary[5] else 0;
        if (load_action == 3 and !self.gpu_surface_packet_binary_patch) return error.UnsupportedService;

        self.gpu_surface_packet_present_window_id = packet.window_id;
        self.gpu_surface_packet_present_label_storage = undefined;
        self.gpu_surface_packet_present_label_len = (try copyInto(&self.gpu_surface_packet_present_label_storage, packet.label)).len;
        self.gpu_surface_packet_present_frame_index = packet.frame_index;
        self.gpu_surface_packet_present_timestamp_ns = packet.timestamp_ns;
        self.gpu_surface_packet_present_surface_size = packet.surface_size;
        self.gpu_surface_packet_present_scale_factor = packet.scale_factor;
        self.gpu_surface_packet_present_clear_color_rgba8 = packet.clear_color_rgba8;
        self.gpu_surface_packet_present_requires_render = packet.requires_render;
        self.gpu_surface_packet_present_command_count = packet.command_count;
        self.gpu_surface_packet_present_cache_action_count = packet.cache_action_count;
        self.gpu_surface_packet_present_cached_resource_command_count = packet.cached_resource_command_count;
        self.gpu_surface_packet_present_unsupported_command_count = packet.unsupported_command_count;
        self.gpu_surface_packet_present_representable = packet.representable;
        self.gpu_surface_packet_present_json_len = 0;
        self.gpu_surface_packet_present_binary_len = packet.binary.len;
        const prefix_len = @min(packet.binary.len, self.gpu_surface_packet_present_binary_prefix.len);
        @memcpy(self.gpu_surface_packet_present_binary_prefix[0..prefix_len], packet.binary[0..prefix_len]);
        @memcpy(self.gpu_surface_packet_present_binary_storage[0..packet.binary.len], packet.binary);
        self.gpu_surface_packet_present_binary_load_action = load_action;
        if (load_action == 3) self.gpu_surface_packet_present_binary_patch_count += 1;
        self.gpu_surface_packet_present_binary_count += 1;
        self.gpu_surface_packet_present_count += 1;
        self.recordGpuSurfacePresentForWindow(packet.window_id);
    }

    fn uploadGpuSurfaceImage(context: ?*anyopaque, image: GpuSurfaceImagePixels) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surfaces) return error.UnsupportedService;
        if (!self.gpu_surface_image_uploads) return error.UnsupportedService;
        const expected = image.expectedByteLen() orelse return error.InvalidGpuSurfaceImage;
        if (image.rgba8.len != expected) return error.InvalidGpuSurfaceImage;

        const index = self.findGpuSurfaceImageIndex(image.id) orelse blk: {
            if (self.gpu_surface_image_count >= max_gpu_surface_images) return error.InvalidGpuSurfaceImage;
            const index = self.gpu_surface_image_count;
            self.gpu_surface_image_count += 1;
            break :blk index;
        };
        const sample: [4]u8 = if (image.rgba8.len >= 4)
            .{ image.rgba8[0], image.rgba8[1], image.rgba8[2], image.rgba8[3] }
        else
            .{ 0, 0, 0, 0 };
        self.gpu_surface_images[index] = .{
            .id = image.id,
            .width = image.width,
            .height = image.height,
            .byte_len = image.rgba8.len,
            .sample_rgba = sample,
        };
        self.gpu_surface_image_upload_id = image.id;
        self.gpu_surface_image_upload_width = image.width;
        self.gpu_surface_image_upload_height = image.height;
        self.gpu_surface_image_upload_byte_len = image.rgba8.len;
        self.gpu_surface_image_upload_sample_rgba = sample;
        self.gpu_surface_image_upload_count += 1;
    }

    fn removeGpuSurfaceImage(context: ?*anyopaque, id: u64) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surfaces) return error.UnsupportedService;
        if (!self.gpu_surface_image_uploads) return error.UnsupportedService;

        self.gpu_surface_image_remove_id = id;
        self.gpu_surface_image_remove_count += 1;
        const index = self.findGpuSurfaceImageIndex(id) orelse return;
        const last = self.gpu_surface_image_count - 1;
        if (index != last) self.gpu_surface_images[index] = self.gpu_surface_images[last];
        self.gpu_surface_images[last] = .{};
        self.gpu_surface_image_count = last;
    }

    /// The recorded side-channel entry for `id`, or null when the id was
    /// never uploaded (or has been removed) — the store a packet host
    /// would consult on an upload cache action.
    pub fn gpuSurfaceImage(self: *const NullPlatform, id: u64) ?NullGpuSurfaceImage {
        const index = self.findGpuSurfaceImageIndex(id) orelse return null;
        return self.gpu_surface_images[index];
    }

    fn findGpuSurfaceImageIndex(self: *const NullPlatform, id: u64) ?usize {
        for (self.gpu_surface_images[0..self.gpu_surface_image_count], 0..) |image, index| {
            if (image.id == id) return index;
        }
        return null;
    }

    fn findWindowIndex(self: *const NullPlatform, window_id: WindowId) ?usize {
        for (self.windows[0..self.window_count], 0..) |window, index| {
            if (window.id == window_id) return index;
        }
        return null;
    }

    fn findWebViewIndex(self: *const NullPlatform, window_id: WindowId, label: []const u8) ?usize {
        for (self.webviews[0..self.webview_count], 0..) |webview, index| {
            if (webview.open and webview.window_id == window_id and std.mem.eql(u8, webview.label, label)) return index;
        }
        return null;
    }

    fn findViewIndex(self: *const NullPlatform, window_id: WindowId, label: []const u8) ?usize {
        for (self.views[0..self.view_count], 0..) |view, index| {
            if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
        }
        return null;
    }

    fn validateViewOptions(self: *const NullPlatform, options: ViewOptions) !void {
        if (self.findWindowIndex(options.window_id)) |window_index| {
            if (!self.windows[window_index].open) return error.WindowNotFound;
        } else if (options.window_id != 1) {
            return error.WindowNotFound;
        }
        if (options.label.len == 0) return error.InvalidViewOptions;
        if (options.label.len > max_view_label_bytes) return error.ViewLabelTooLarge;
        if (options.role.len > max_view_role_bytes) return error.ViewRoleTooLarge;
        if (options.accessibility_label.len > max_view_accessibility_label_bytes) return error.ViewAccessibilityLabelTooLarge;
        if (options.text.len > max_view_text_bytes) return error.ViewTextTooLarge;
        if (options.command.len > max_view_command_bytes) return error.InvalidCommand;
        if (!isValidViewFrame(options.frame)) return error.InvalidViewOptions;
        if (options.url.len > 0) return error.InvalidViewOptions;
        if (options.kind == .gpu_surface and !options.gpu_surface.isSupported()) return error.UnsupportedViewKind;
        if (options.parent) |parent| {
            if (parent.len == 0 or parent.len > max_view_label_bytes) return error.InvalidViewOptions;
            if (std.mem.eql(u8, parent, options.label)) return error.InvalidViewOptions;
            if (!std.mem.eql(u8, parent, "main") and self.findViewIndex(options.window_id, parent) == null and self.findWebViewIndex(options.window_id, parent) == null) return error.ViewNotFound;
        }
        if (std.mem.eql(u8, options.label, "main")) return error.DuplicateViewLabel;
        if (self.findWebViewIndex(options.window_id, options.label) != null) return error.DuplicateViewLabel;
    }

    fn copyViewStrings(self: *NullPlatform, index: usize, label: []const u8, parent: ?[]const u8, role: []const u8, accessibility_label: []const u8, text: []const u8, command: []const u8) !void {
        self.views[index].label = try copyInto(&self.views[index].label_storage, label);
        self.views[index].parent = if (parent) |value| try copyInto(&self.views[index].parent_storage, value) else null;
        self.views[index].role = try copyInto(&self.views[index].role_storage, role);
        self.views[index].accessibility_label = try copyInto(&self.views[index].accessibility_label_storage, accessibility_label);
        self.views[index].text = try copyInto(&self.views[index].text_storage, text);
        self.views[index].command = try copyInto(&self.views[index].command_storage, command);
    }

    fn removeViewAt(self: *NullPlatform, index: usize) void {
        if (index >= self.view_count) return;
        var cursor = index;
        while (cursor + 1 < self.view_count) : (cursor += 1) {
            const next = self.views[cursor + 1];
            self.views[cursor] = .{
                .window_id = next.window_id,
                .kind = next.kind,
                .frame = next.frame,
                .layer = next.layer,
                .visible = next.visible,
                .enabled = next.enabled,
                .accessibility_label = next.accessibility_label,
                .command = next.command,
                .open = next.open,
            };
            self.copyViewStrings(cursor, next.label, next.parent, next.role, next.accessibility_label, next.text, next.command) catch unreachable;
        }
        self.view_count -= 1;
    }

    /// Test seam: the USER closed a window. Real hosts' window
    /// delegates tear the native window out of their records before
    /// emitting the open=false frame event (macOS `windowWillClose`),
    /// so the fake host mirrors that — remove the window and its views
    /// here, then dispatch the returned event through the runtime.
    pub fn userCloseWindow(self: *NullPlatform, window_id: WindowId) ?Event {
        const index = self.findWindowIndex(window_id) orelse return null;
        const info = self.windows[index];
        self.removeViewsForWindow(window_id);
        self.removeWebViewsForWindow(window_id);
        self.removeWindowAt(index);
        return .{ .window_frame_changed = .{
            .id = info.id,
            .label = info.label,
            .title = info.title,
            .frame = info.frame,
            .scale_factor = info.scale_factor,
            .open = false,
            .focused = false,
        } };
    }

    /// Test seam: minimize calls observed for a window (the null host
    /// has no Dock, so the count is the pinned behavior).
    pub fn minimizeCountForWindow(self: *const NullPlatform, window_id: WindowId) u32 {
        const index = self.findWindowIndex(window_id) orelse return 0;
        return self.window_minimize_count[index];
    }

    /// Test seam: model a window leaving or returning to the glass
    /// without a minimize verb (fully covered by another app, revealed
    /// again) — the occlusion fact the real hosts' spectrum gating
    /// reads. Minimize sets the same flag; focus clears it.
    pub fn setWindowOccluded(self: *NullPlatform, window_id: WindowId, occluded: bool) !void {
        const index = self.findWindowIndex(window_id) orelse return error.WindowNotFound;
        self.window_occluded[index] = occluded;
    }

    /// Whether every open modeled window is off the glass — the
    /// occluded-emission rule's gate. False while ANY open window is
    /// unoccluded, and false with no windows at all (a window-less
    /// harness models an app whose display nobody took away).
    fn allOpenWindowsOccluded(self: *const NullPlatform) bool {
        var any_open = false;
        for (self.windows[0..self.window_count], 0..) |window, index| {
            if (!window.open) continue;
            any_open = true;
            if (!self.window_occluded[index]) return false;
        }
        return any_open;
    }

    fn removeWindowAt(self: *NullPlatform, index: usize) void {
        if (index >= self.window_count) return;
        var cursor = index;
        while (cursor + 1 < self.window_count) : (cursor += 1) {
            self.windows[cursor] = self.windows[cursor + 1];
            self.window_resizable[cursor] = self.window_resizable[cursor + 1];
            self.window_min_width[cursor] = self.window_min_width[cursor + 1];
            self.window_min_height[cursor] = self.window_min_height[cursor + 1];
            self.window_minimize_count[cursor] = self.window_minimize_count[cursor + 1];
            self.window_occluded[cursor] = self.window_occluded[cursor + 1];
        }
        self.window_count -= 1;
    }

    fn removeViewsForWindow(self: *NullPlatform, window_id: WindowId) void {
        var index: usize = 0;
        while (index < self.view_count) {
            if (self.views[index].window_id == window_id) {
                self.removeViewAt(index);
            } else {
                index += 1;
            }
        }
    }

    fn removeChildViewsForParent(self: *NullPlatform, window_id: WindowId, parent_label: []const u8) void {
        var index: usize = 0;
        while (index < self.view_count) {
            const parent = self.views[index].parent orelse {
                index += 1;
                continue;
            };
            if (self.views[index].window_id != window_id or !std.mem.eql(u8, parent, parent_label)) {
                index += 1;
                continue;
            }

            var child_label_storage: [max_view_label_bytes]u8 = undefined;
            const child_label = copyInto(&child_label_storage, self.views[index].label) catch unreachable;
            self.removeChildViewsForParent(window_id, child_label);
            if (self.findViewIndex(window_id, child_label)) |child_index| self.removeViewAt(child_index);
            index = 0;
        }
    }

    fn removeWebViewAt(self: *NullPlatform, index: usize) void {
        if (index >= self.webview_count) return;
        var cursor = index;
        while (cursor + 1 < self.webview_count) : (cursor += 1) {
            const next = self.webviews[cursor + 1];
            self.webviews[cursor] = .{
                .window_id = next.window_id,
                .frame = next.frame,
                .layer = next.layer,
                .transparent = next.transparent,
                .bridge_enabled = next.bridge_enabled,
                .zoom = next.zoom,
                .open = next.open,
            };
            @memcpy(self.webviews[cursor].label_storage[0..next.label.len], next.label);
            @memcpy(self.webviews[cursor].url_storage[0..next.url.len], next.url);
            self.webviews[cursor].label = self.webviews[cursor].label_storage[0..next.label.len];
            self.webviews[cursor].url = self.webviews[cursor].url_storage[0..next.url.len];
        }
        self.webview_count -= 1;
    }

    fn removeWebViewsForWindow(self: *NullPlatform, window_id: WindowId) void {
        var index: usize = 0;
        while (index < self.webview_count) {
            if (self.webviews[index].window_id == window_id) {
                self.removeWebViewAt(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn lastBridgeResponse(self: *const NullPlatform) []const u8 {
        return self.bridge_response[0..self.bridge_response_len];
    }

    pub fn lastBridgeResponseWindowId(self: *const NullPlatform) WindowId {
        return self.bridge_response_window_id;
    }

    pub fn lastBridgeResponseWebViewLabel(self: *const NullPlatform) []const u8 {
        return self.bridge_response_webview_label;
    }

    pub fn lastExternalUrl(self: *const NullPlatform) []const u8 {
        return self.external_url[0..self.external_url_len];
    }

    pub fn lastRevealedPath(self: *const NullPlatform) []const u8 {
        return self.revealed_path[0..self.revealed_path_len];
    }

    pub fn lastRecentDocumentPath(self: *const NullPlatform) []const u8 {
        return self.recent_document_path[0..self.recent_document_path_len];
    }

    pub fn recentDocumentsClearedCount(self: *const NullPlatform) usize {
        return self.recent_documents_cleared_count;
    }

    pub fn lastNotificationTitle(self: *const NullPlatform) []const u8 {
        return self.notification_title[0..self.notification_title_len];
    }

    pub fn lastNotificationSubtitle(self: *const NullPlatform) []const u8 {
        return self.notification_subtitle[0..self.notification_subtitle_len];
    }

    pub fn lastNotificationBody(self: *const NullPlatform) []const u8 {
        return self.notification_body[0..self.notification_body_len];
    }

    pub fn notificationCount(self: *const NullPlatform) usize {
        return self.notification_count;
    }

    pub fn lastClipboardMimeType(self: *const NullPlatform) []const u8 {
        return self.clipboard_mime_type[0..self.clipboard_mime_type_len];
    }

    pub fn lastClipboardData(self: *const NullPlatform) []const u8 {
        return self.clipboard_data[0..self.clipboard_data_len];
    }

    pub fn clipboardWriteCount(self: *const NullPlatform) usize {
        return self.clipboard_write_count;
    }

    pub fn lastCredentialService(self: *const NullPlatform) []const u8 {
        return self.credential_service[0..self.credential_service_len];
    }

    pub fn lastCredentialAccount(self: *const NullPlatform) []const u8 {
        return self.credential_account[0..self.credential_account_len];
    }

    pub fn lastCredentialSecret(self: *const NullPlatform) []const u8 {
        return self.credential_secret[0..self.credential_secret_len];
    }

    pub fn credentialSetCount(self: *const NullPlatform) usize {
        return self.credential_set_count;
    }

    pub fn credentialDeleteCount(self: *const NullPlatform) usize {
        return self.credential_delete_count;
    }

    pub fn lastTrayIconPath(self: *const NullPlatform) []const u8 {
        return self.tray_icon_path[0..self.tray_icon_path_len];
    }

    pub fn lastTrayTitle(self: *const NullPlatform) []const u8 {
        return self.tray_title[0..self.tray_title_len];
    }

    pub fn lastTrayTooltip(self: *const NullPlatform) []const u8 {
        return self.tray_tooltip[0..self.tray_tooltip_len];
    }

    pub fn trayItems(self: *const NullPlatform) []const TrayMenuItem {
        return self.tray_items[0..self.tray_item_count];
    }

    pub fn trayCreateCount(self: *const NullPlatform) usize {
        return self.tray_create_count;
    }

    pub fn trayUpdateCount(self: *const NullPlatform) usize {
        return self.tray_update_count;
    }

    pub fn trayTitleUpdateCount(self: *const NullPlatform) usize {
        return self.tray_title_update_count;
    }

    pub fn trayRemoveCount(self: *const NullPlatform) usize {
        return self.tray_remove_count;
    }

    pub fn lastWindowEventWindowId(self: *const NullPlatform) WindowId {
        return self.window_event_window_id;
    }

    pub fn lastWindowEventName(self: *const NullPlatform) []const u8 {
        return self.window_event_name[0..self.window_event_name_len];
    }

    pub fn lastWindowEventDetail(self: *const NullPlatform) []const u8 {
        return self.window_event_detail[0..self.window_event_detail_len];
    }

    pub fn windowEventCount(self: *const NullPlatform) usize {
        return self.window_event_count;
    }

    pub fn configuredShortcuts(self: *const NullPlatform) []const Shortcut {
        return self.shortcuts[0..self.shortcut_count];
    }

    pub fn configuredMenus(self: *const NullPlatform) []const Menu {
        return self.menus[0..self.menu_count];
    }

    fn setGpuSurfaceScrollDrivers(context: ?*anyopaque, window_id: WindowId, label: []const u8, drivers: []const GpuSurfaceScrollDriver) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        if (!self.gpu_surface_scroll_drivers) return error.UnsupportedService;
        self.scroll_driver_set_count += 1;
        self.scroll_driver_window_id = window_id;
        const label_value = try copyInto(&self.scroll_driver_label_storage, label);
        self.scroll_driver_label_len = label_value.len;
        const count = @min(drivers.len, self.scroll_drivers.len);
        @memcpy(self.scroll_drivers[0..count], drivers[0..count]);
        self.scroll_driver_count = count;
        for (drivers) |driver| {
            if (driver.set_offset) self.scroll_driver_set_offset_count += 1;
        }
    }

    fn showContextMenu(context: ?*anyopaque, request: ContextMenuRequest) anyerror!void {
        const self: *NullPlatform = @ptrCast(@alignCast(context.?));
        self.context_menu_request_count += 1;
        self.context_menu_window_id = request.window_id;
        const label_value = try copyInto(&self.context_menu_label_storage, request.view_label);
        self.context_menu_label_len = label_value.len;
        self.context_menu_point = request.point;
        self.context_menu_token = request.token;
        self.context_menu_label_bytes_len = 0;
        var count: usize = 0;
        for (request.items) |item| {
            if (count >= self.context_menu_items.len) break;
            const start = self.context_menu_label_bytes_len;
            const end = start + item.label.len;
            if (end > self.context_menu_label_bytes.len) return error.NoSpaceLeft;
            @memcpy(self.context_menu_label_bytes[start..end], item.label);
            self.context_menu_label_bytes_len = end;
            self.context_menu_items[count] = .{
                .id = item.id,
                .label = self.context_menu_label_bytes[start..end],
                .enabled = item.enabled,
                .separator = item.separator,
            };
            count += 1;
        }
        self.context_menu_item_count = count;
    }

    pub fn scrollDrivers(self: *const NullPlatform) []const GpuSurfaceScrollDriver {
        return self.scroll_drivers[0..self.scroll_driver_count];
    }

    pub fn scrollDriverLabel(self: *const NullPlatform) []const u8 {
        return self.scroll_driver_label_storage[0..self.scroll_driver_label_len];
    }

    pub fn contextMenuItems(self: *const NullPlatform) []const ContextMenuItem {
        return self.context_menu_items[0..self.context_menu_item_count];
    }

    pub fn contextMenuLabel(self: *const NullPlatform) []const u8 {
        return self.context_menu_label_storage[0..self.context_menu_label_len];
    }
};

pub const NullWebView = struct {
    window_id: WindowId = 1,
    label: []const u8 = "",
    url: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    transparent: bool = false,
    bridge_enabled: bool = false,
    zoom: f64 = 1.0,
    open: bool = false,
    label_storage: [max_webview_label_bytes]u8 = undefined,
    url_storage: [max_webview_url_bytes]u8 = undefined,
};

pub const NullView = struct {
    window_id: WindowId = 1,
    label: []const u8 = "",
    kind: ViewKind = .toolbar,
    parent: ?[]const u8 = null,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    visible: bool = true,
    enabled: bool = true,
    role: []const u8 = "",
    accessibility_label: []const u8 = "",
    text: []const u8 = "",
    command: []const u8 = "",
    gpu_size: geometry.SizeF = geometry.SizeF.init(0, 0),
    gpu_backend: GpuSurfaceBackend = .none,
    gpu_pixel_format: GpuSurfacePixelFormat = .none,
    gpu_present_mode: GpuSurfacePresentMode = .none,
    gpu_alpha_mode: GpuSurfaceAlphaMode = .none,
    gpu_color_space: GpuSurfaceColorSpace = .none,
    gpu_vsync: bool = false,
    gpu_status: GpuSurfaceStatus = .unavailable,
    open: bool = false,
    label_storage: [max_view_label_bytes]u8 = undefined,
    parent_storage: [max_view_label_bytes]u8 = undefined,
    role_storage: [max_view_role_bytes]u8 = undefined,
    accessibility_label_storage: [max_view_accessibility_label_bytes]u8 = undefined,
    text_storage: [max_view_text_bytes]u8 = undefined,
    command_storage: [max_view_command_bytes]u8 = undefined,
};

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

fn isValidWebViewFrame(frame: geometry.RectF) bool {
    return frame.x >= 0 and frame.y >= 0 and frame.width > 0 and frame.height > 0;
}

fn isValidViewFrame(frame: geometry.RectF) bool {
    return frame.x >= 0 and frame.y >= 0 and frame.width >= 0 and frame.height >= 0;
}
