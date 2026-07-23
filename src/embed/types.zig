const platform = @import("../platform/root.zig");

pub const max_mobile_command_name_bytes: usize = 128;
pub const max_mobile_input_text_bytes: usize = 512;
pub const max_mobile_asset_root_bytes: usize = platform.max_webview_url_bytes;
pub const max_mobile_asset_entry_bytes: usize = platform.max_window_source_path_bytes;
pub const mobile_gpu_surface_label = "mobile-surface";

pub const MobileWidgetRole = enum(c_int) {
    none = 0,
    group = 1,
    text = 2,
    image = 3,
    button = 4,
    textbox = 5,
    tooltip = 6,
    dialog = 7,
    menu = 8,
    menuitem = 9,
    list = 10,
    listitem = 11,
    row = 12,
    grid = 13,
    gridcell = 14,
    tab = 15,
    checkbox = 16,
    switch_control = 17,
    slider = 18,
    progressbar = 19,
    radio = 20,
};

pub const MobileWidgetFlag = enum(u32) {
    focused = 1 << 0,
    hovered = 1 << 1,
    pressed = 1 << 2,
    selected = 1 << 3,
    disabled = 1 << 4,
    focusable = 1 << 5,
    expanded = 1 << 6,
    collapsed = 1 << 7,
    required = 1 << 8,
    read_only = 1 << 9,
    invalid = 1 << 10,
};

pub const MobileWidgetAction = enum(u32) {
    focus = 1 << 0,
    press = 1 << 1,
    toggle = 1 << 2,
    increment = 1 << 3,
    decrement = 1 << 4,
    set_text = 1 << 5,
    set_selection = 1 << 6,
    select = 1 << 7,
    drag = 1 << 8,
    drop_files = 1 << 9,
    dismiss = 1 << 10,
};

pub const MobileWidgetActionKind = enum(c_int) {
    focus = 0,
    press = 1,
    toggle = 2,
    increment = 3,
    decrement = 4,
    set_text = 5,
    set_selection = 6,
    set_composition = 7,
    commit_composition = 8,
    cancel_composition = 9,
    select = 10,
    drag = 11,
    drop_files = 12,
    dismiss = 13,
};

pub const MobileWidgetSemantics = extern struct {
    id: u64 = 0,
    parent_id: u64 = 0,
    role: c_int = @intFromEnum(MobileWidgetRole.none),
    flags: u32 = 0,
    actions: u32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    value: f32 = 0,
    has_value: c_int = 0,
    label: ?[*]const u8 = null,
    label_len: usize = 0,
    text: ?[*]const u8 = null,
    text_len: usize = 0,
    placeholder: ?[*]const u8 = null,
    placeholder_len: usize = 0,
    text_selection_start: isize = -1,
    text_selection_end: isize = -1,
    text_composition_start: isize = -1,
    text_composition_end: isize = -1,
    grid_row_index: isize = -1,
    grid_column_index: isize = -1,
    grid_row_count: isize = -1,
    grid_column_count: isize = -1,
    list_item_index: isize = -1,
    list_item_count: isize = -1,
    scroll_offset: f32 = 0,
    scroll_viewport_extent: f32 = 0,
    scroll_content_extent: f32 = 0,
    has_scroll: c_int = 0,
};

pub const MobileWidgetTextGeometry = extern struct {
    id: u64 = 0,
    has_caret_bounds: c_int = 0,
    caret_x: f32 = 0,
    caret_y: f32 = 0,
    caret_width: f32 = 0,
    caret_height: f32 = 0,
    has_selection_bounds: c_int = 0,
    selection_x: f32 = 0,
    selection_y: f32 = 0,
    selection_width: f32 = 0,
    selection_height: f32 = 0,
    selection_rect_count: usize = 0,
    has_composition_bounds: c_int = 0,
    composition_x: f32 = 0,
    composition_y: f32 = 0,
    composition_width: f32 = 0,
    composition_height: f32 = 0,
    composition_rect_count: usize = 0,
};

pub const MobileWidgetActionRequest = extern struct {
    id: u64 = 0,
    action: c_int = @intFromEnum(MobileWidgetActionKind.focus),
    text: ?[*]const u8 = null,
    text_len: usize = 0,
    selection_anchor: usize = 0,
    selection_focus: usize = 0,
    has_selection: c_int = 0,
};

/// Focus / IME-intent state for the mobile surface. `active` is nonzero
/// when an editable text widget owns focus — the platform shim shows the
/// system keyboard while it is set and hides it when it clears.
/// `widget_id` is the focused widget (editable or not; 0 when nothing is
/// focused) and the bounds are its frame in view points, so the shim can
/// keep the caret visible above the keyboard.
pub const MobileTextInputState = extern struct {
    active: c_int = 0,
    widget_id: u64 = 0,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

/// Viewport push for `native_sdk_app_viewport`: surface geometry plus
/// safe-area and keyboard insets. Passed by pointer — the positional form
/// (11 f32 interleaved with a pointer) is the SysV C-ABI shape Zig 0.16.0's
/// self-hosted x86_64 backend mis-lowers, spilling later floats a slot off.
pub const MobileViewport = extern struct {
    width: f32 = 0,
    height: f32 = 0,
    scale: f32 = 1,
    surface: ?*anyopaque = null,
    safe_top: f32 = 0,
    safe_right: f32 = 0,
    safe_bottom: f32 = 0,
    safe_left: f32 = 0,
    keyboard_top: f32 = 0,
    keyboard_right: f32 = 0,
    keyboard_bottom: f32 = 0,
    keyboard_left: f32 = 0,
};

pub const MobileViewportState = extern struct {
    width: f32 = 0,
    height: f32 = 0,
    scale: f32 = 1,
    has_surface: c_int = 0,
    safe_top: f32 = 0,
    safe_right: f32 = 0,
    safe_bottom: f32 = 0,
    safe_left: f32 = 0,
    keyboard_top: f32 = 0,
    keyboard_right: f32 = 0,
    keyboard_bottom: f32 = 0,
    keyboard_left: f32 = 0,
    content_x: f32 = 0,
    content_y: f32 = 0,
    content_width: f32 = 0,
    content_height: f32 = 0,
};

/// Platform text-measure callback registered through
/// `native_sdk_app_set_text_measure`: returns the typographic width of a
/// single-line UTF-8 run at `size` for `font_id` (1 = sans, 2 = mono),
/// measured with the same font resolution the shim's presentation would
/// draw with (CoreText on iOS, mirroring the desktop
/// `native_sdk_appkit_measure_text` seam). Return a negative value to
/// fall back to the deterministic estimator for that run (e.g. invalid
/// UTF-8).
pub const MobileTextMeasureFn = *const fn (
    context: ?*anyopaque,
    font_id: u64,
    size: f64,
    text: ?[*]const u8,
    text_len: usize,
) callconv(.c) f64;

// ------------------------------------------------------------------ audio
//
// The platform audio service over the embed C ABI. A mobile shim that owns
// a real audio player (the iOS toolkit host: AVAudioPlayer for local files
// and verified cache entries, AVPlayer for progressive URL streams)
// registers this callback table through `native_sdk_app_set_audio_service`
// and reports everything asynchronous back through
// `native_sdk_app_audio_event`. Hosts without a registered service decline
// audio honestly: `audio_playback`/`audio_streaming` report unsupported and
// `fx.playAudio` degrades to one explicit `.failed` Msg — never a silent
// fake player inside a real app.

/// Synchronous local-file load. Returns 0 when the player loaded and
/// decoded the file (the asynchronous `.loaded` acknowledgment with the
/// real duration follows as an audio event), 1 when the file is missing
/// or unreadable, anything else for a decode failure — the exact
/// contract of the macOS host's `native_sdk_appkit_audio_load`.
pub const MobileAudioLoadFn = *const fn (
    context: ?*anyopaque,
    path: ?[*]const u8,
    path_len: usize,
) callconv(.c) c_int;

/// URL source resolution. Returns 1 when a verified cache entry at
/// `cache_path` is playing locally (no network), 0 when a progressive
/// stream started (the `.loaded` acknowledgment follows when the item is
/// ready; the same bytes fill `cache_path` for the next play, gated by
/// `expected_bytes`), anything else when the URL itself is unusable.
pub const MobileAudioLoadUrlFn = *const fn (
    context: ?*anyopaque,
    url: ?[*]const u8,
    url_len: usize,
    cache_path: ?[*]const u8,
    cache_path_len: usize,
    expected_bytes: u64,
) callconv(.c) c_int;

/// Transport calls without arguments (play/pause/stop). Play returns
/// nonzero when it applied to a loaded player and 0 when there is no
/// player to start; pause and stop results are advisory.
pub const MobileAudioTransportFn = *const fn (context: ?*anyopaque) callconv(.c) c_int;

/// Seek to an absolute position (the player clamps to the duration).
/// Returns nonzero when it applied, 0 when there is no player.
pub const MobileAudioSeekFn = *const fn (context: ?*anyopaque, position_ms: u64) callconv(.c) c_int;

/// Set playback volume (0.0–1.0, pre-clamped by the runtime). The result
/// is advisory.
pub const MobileAudioSetVolumeFn = *const fn (context: ?*anyopaque, volume: f64) callconv(.c) c_int;

/// The audio service callback table (`native_sdk_audio_service_t` in the
/// shim headers). Registration is tiered and all-or-nothing per tier:
/// local playback needs every entry except `load_url`; `load_url` on top
/// of that enables streaming (`audio_streaming`). A table with only some
/// playback entries is refused — a player that can start but not stop is
/// not a player.
pub const MobileAudioService = extern struct {
    load: ?MobileAudioLoadFn = null,
    load_url: ?MobileAudioLoadUrlFn = null,
    play: ?MobileAudioTransportFn = null,
    pause: ?MobileAudioTransportFn = null,
    stop: ?MobileAudioTransportFn = null,
    seek: ?MobileAudioSeekFn = null,
    set_volume: ?MobileAudioSetVolumeFn = null,

    pub fn playbackComplete(self: MobileAudioService) bool {
        return self.load != null and self.play != null and self.pause != null and
            self.stop != null and self.seek != null and self.set_volume != null;
    }

    pub fn empty(self: MobileAudioService) bool {
        return self.load == null and self.load_url == null and self.play == null and
            self.pause == null and self.stop == null and self.seek == null and
            self.set_volume == null;
    }
};

// ------------------------------------------------------------ image decode
//
// The platform image-decode service over the embed C ABI. A mobile shim
// that owns a real image codec (the iOS toolkit host: CGImageSource, the
// same ImageIO family the macOS host decodes through; the Android toolkit
// host: BitmapFactory over JNI) registers this callback table through
// `native_sdk_app_set_image_service`, and the runtime's
// `fx.registerImageBytes` decodes encoded bytes (PNG, JPEG, ...) through
// it — the same `PlatformServices.decode_image_fn` seam the desktop
// platform codecs serve. Hosts without a registered service decline
// honestly: `registerImageBytes` reports `error.UnsupportedService` and
// image/avatar widgets keep their fallback (initials) — never a bundled
// codec pretending to be the platform's.

/// Synchronous decode of encoded image bytes into tightly packed,
/// row-major, straight-alpha (non-premultiplied) RGBA8 written into
/// `pixels`, reporting the dimensions through the out parameters. Returns
/// 1 when the image decoded (`*out_width * *out_height * 4` bytes fill a
/// prefix of `pixels`), -1 when the decoded pixels do not fit
/// `pixels_len`, anything else for undecodable bytes — the exact contract
/// of the macOS host's `native_sdk_appkit_decode_image`.
pub const MobileImageDecodeFn = *const fn (
    context: ?*anyopaque,
    bytes: ?[*]const u8,
    bytes_len: usize,
    pixels: ?[*]u8,
    pixels_len: usize,
    out_width: ?*usize,
    out_height: ?*usize,
) callconv(.c) c_int;

/// The image service callback table (`native_sdk_image_service_t` in the
/// shim headers). One tier today: a table with `decode` registers the
/// platform codec, an empty table clears it back to the honest decline.
pub const MobileImageService = extern struct {
    decode: ?MobileImageDecodeFn = null,

    pub fn complete(self: MobileImageService) bool {
        return self.decode != null;
    }

    pub fn empty(self: MobileImageService) bool {
        return self.decode == null;
    }
};

/// Dimensions of a canvas render produced by
/// `native_sdk_app_render_pixels` (tightly packed RGBA8).
pub const MobileCanvasPixels = extern struct {
    width: usize = 0,
    height: usize = 0,
    byte_len: usize = 0,
};

/// Result of `native_sdk_app_render_pixels_damage`: the surface
/// dimensions (identical meaning to `MobileCanvasPixels`) plus the
/// damaged region this call wrote into the caller's RETAINED buffer, in
/// device pixels. `damage_width == 0 or damage_height == 0` means
/// nothing changed since the previous call — the buffer already shows
/// the current frame and the host skips its upload entirely. A first
/// call (and any size or scale change) reports the full surface.
pub const MobileCanvasPixelsDamage = extern struct {
    width: usize = 0,
    height: usize = 0,
    byte_len: usize = 0,
    damage_x: usize = 0,
    damage_y: usize = 0,
    damage_width: usize = 0,
    damage_height: usize = 0,
    /// The retained-canvas revision the buffer now REFLECTS. The host's
    /// re-render gate must compare `native_sdk_app_gpu_frame_state`'s
    /// `canvas_revision` against THIS value, not against its own last
    /// sighting: a revision whose frame has not presented yet delivers
    /// empty damage with the OLD revision, telling the host to call
    /// again next tick (the runtime presents one frame pump after the
    /// change that produced it — gating on sightings alone strands that
    /// present's damage and leaves stale pixels on the glass).
    revision: u64 = 0,
};

pub const MobileGpuFrameState = extern struct {
    surface_id: u64 = 0,
    window_id: u64 = 0,
    width: f32 = 0,
    height: f32 = 0,
    scale: f32 = 1,
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    frame_interval_ns: u64 = platform.default_gpu_frame_interval_ns,
    input_timestamp_ns: u64 = 0,
    input_latency_ns: u64 = 0,
    input_latency_budget_ns: u64 = platform.default_gpu_frame_interval_ns,
    input_latency_budget_exceeded_count: usize = 0,
    input_latency_budget_ok: c_int = 1,
    first_frame_latency_ns: u64 = 0,
    first_frame_latency_budget_ns: u64 = platform.default_gpu_first_frame_latency_budget_ns,
    first_frame_latency_budget_exceeded_count: usize = 0,
    first_frame_latency_budget_ok: c_int = 1,
    nonblank: c_int = 0,
    sample_color: u32 = 0,
    status: c_int = @intFromEnum(platform.GpuSurfaceStatus.unavailable),
    vsync: c_int = 0,
    canvas_revision: u64 = 0,
    canvas_command_count: usize = 0,
    canvas_frame_requires_render: c_int = 0,
    canvas_frame_full_repaint: c_int = 0,
    canvas_frame_batch_count: usize = 0,
    canvas_frame_budget_exceeded_count: usize = 0,
    canvas_frame_budget_ok: c_int = 1,
    widget_revision: u64 = 0,
    widget_node_count: usize = 0,
    widget_semantics_count: usize = 0,
};
