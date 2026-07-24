const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const security = @import("../security/root.zig");

pub const default_gpu_frame_interval_ns: u64 = 16_666_667;
pub const default_gpu_first_frame_latency_budget_ns: u64 = 150_000_000;

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
    InvalidShortcut,
    InvalidMenuOptions,
    InvalidCommand,
    InvalidPlatformFeature,
    InvalidViewOptions,
    InvalidViewWindowId,
    CrossWindowViewDenied,
    ViewNotFound,
    ViewLimitReached,
    DuplicateViewLabel,
    ViewLabelTooLarge,
    ViewRoleTooLarge,
    ViewAccessibilityLabelTooLarge,
    ViewTextTooLarge,
    UnsupportedViewKind,
    UnsupportedViewFocus,
    MissingWebViewUrl,
    InvalidWebViewOptions,
    WebViewNotFound,
    WebViewLimitReached,
    DuplicateWebViewLabel,
    WebViewLabelTooLarge,
    WebViewUrlTooLarge,
    UnsupportedChildWebViews,
    UnsupportedWebViewBridge,
    UnsupportedMainWebViewFrame,
    UnsupportedMainWebViewZoom,
    UnsupportedMainWebViewLayer,
    NavigationDenied,
    InvalidExternalUrl,
    ExternalUrlTooLarge,
    InvalidRevealPath,
    RevealPathTooLarge,
    InvalidRecentDocumentPath,
    RecentDocumentPathTooLarge,
    InvalidDialogOptions,
    DialogFieldTooLarge,
    InvalidNotificationOptions,
    NotificationFieldTooLarge,
    InvalidClipboardOptions,
    ClipboardFieldTooLarge,
    InvalidCredentialOptions,
    CredentialFieldTooLarge,
    CredentialNotFound,
    InvalidTrayOptions,
    TrayFieldTooLarge,
    InvalidAudioOptions,
    AudioPathTooLarge,
    AudioSourceNotFound,
    AudioDecodeFailed,
    InvalidVideoOptions,
    VideoPathTooLarge,
    VideoSourceNotFound,
    VideoDecodeFailed,
    InvalidGpuSurfacePixels,
    InvalidGpuSurfacePacket,
    InvalidGpuSurfaceImage,
    InvalidGpuSurfaceFont,
};

pub const WebEngine = enum {
    system,
    chromium,
};

pub const PlatformFeature = enum {
    main_webview,
    child_webviews,
    native_views,
    native_control_commands,
    menus,
    tray,
    shortcuts,
    dialogs,
    clipboard_text,
    clipboard_rich_data,
    open_url,
    reveal_path,
    notifications,
    recent_documents,
    credentials,
    file_drops,
    app_activation_events,
    gpu_surfaces,
    /// Per-scrollable-region native scroll drivers for gpu-surface canvas
    /// views (macOS: invisible `NSScrollView`s that own scroll input,
    /// momentum, rubber-band, and overlay scrollbars).
    gpu_surface_scroll_drivers,
    /// Native context menus presented at the pointer (macOS: `NSMenu`
    /// `popUpMenuPositioningItem`). Selection returns asynchronously as a
    /// `context_menu_action` event.
    context_menus,
    /// Adopting an app-owned platform view (macOS: an NSView* the app
    /// constructed — a `VZVirtualMachineView`, an `MKMapView`) as the fill
    /// content of a declared native view container, via
    /// `PlatformServices.adoptViewSurface`. macOS system host only today.
    view_surface_adoption,
    /// Single-player audio file playback (macOS: AVAudioPlayer in the
    /// AppKit host; Windows: a Media Foundation media session in the
    /// Win32 host; Linux: a GStreamer playbin in the GTK host, loaded at
    /// runtime — a host without the library reports false here and
    /// answers `error.UnsupportedService`, named unsupported, not
    /// half-implemented; the null platform: a deterministic fake).
    /// Position ticks and the completion arrive as `.audio` events.
    audio_playback,
    /// URL audio sources on the same single player (macOS: AVPlayer in
    /// the AppKit host; Windows: the same Media Foundation session over
    /// its network source; Linux: the same playbin over its HTTP
    /// source): progressive streaming that starts before the
    /// download finishes, plus a byte-verified local cache fill so the
    /// next play of the same URL is local. Hosts with `audio_playback`
    /// but no streaming path answer `error.UnsupportedService` from
    /// `audioLoadUrl` — named unsupported, not half-implemented.
    audio_streaming,
    /// Real spectrum analysis of the app's own playback: hosts that can
    /// reach the player's PCM deliver `.audio`/`.spectrum` events (32
    /// band magnitudes, see `AudioEvent.bands`) at a steady coarse
    /// cadence while audio is audibly playing (macOS: an
    /// MTAudioProcessingTap on the single AVPlayer + vDSP FFT; Windows:
    /// process-scoped WASAPI loopback capture of THIS app's audio
    /// session only + an in-box FFT; Linux: the GStreamer `spectrum`
    /// element as the playbin's audio-filter). Hosts that cannot
    /// analyze report false here and simply never emit `.spectrum`
    /// events — honest absence, never fabricated bands; the null
    /// platform ships a deterministic fake generator behind the same
    /// flag.
    ///
    /// The occluded-emission rule: `.spectrum` bands describe a
    /// display, so a host that knows none of the app's windows reaches
    /// the glass emits no spectrum events for the duration — playback
    /// and the position/loaded/completed reports continue untouched,
    /// the journal records the stretch as honest silence, and emission
    /// resumes with the first analysis beat after reveal (within one
    /// ~40 ms report). macOS keys on window occlusion (minimized,
    /// fully covered, hidden, inactive Space) and skips the FFT while
    /// parked; Windows keys on every window minimized (the same signal
    /// its frame heartbeat trusts); Linux/GTK has no cross-backend
    /// visibility fact (the documented frame-pacing reasoning) and
    /// keeps emitting; the null platform models the rule through its
    /// windows' modeled occlusion so the suites can pin it.
    audio_spectrum,
    /// The `close_policy = .hide` window shape: the host can intercept
    /// the user's close affordance, keep the window alive off the
    /// glass, and re-show it later (`show_window_fn`, tray actions, the
    /// macOS Dock reopen). macOS and Windows implement it; GTK reports
    /// false — Linux has no status-item affordance in this toolkit, so
    /// a hidden window would be unreachable, and window create refuses
    /// the policy with a teaching error instead. The null platform
    /// models full support.
    window_hide_on_close,
    /// Single-player video playback into a media-surface texture channel
    /// (macOS: AVFoundation — one AVPlayer whose AVPlayerItemVideoOutput
    /// frames feed the surface's producer; the null platform: a
    /// deterministic fake). The core never sees pixels: apps send
    /// transport commands and receive `.video` events (load
    /// acknowledgment with dimensions and duration, coarse position
    /// ticks, one completion at natural end, failures), while decoded
    /// frames flow platform-side through the `VideoFrameSink` handed to
    /// the load verbs. Windows (Media Foundation) and Linux (GStreamer)
    /// do not implement the decoder yet: their hosts answer the load
    /// verbs with a teaching and `error.UnsupportedService` — named
    /// unsupported, not half-implemented — and report false here.
    video_playback,
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
pub const ViewId = u64;
pub const max_windows: usize = 16;
pub const max_window_label_bytes: usize = 64;
pub const max_window_title_bytes: usize = 128;
/// Budget for a window's webview source payload — for `.html` sources this
/// is the whole inline document, so it must comfortably hold a real page
/// (a 4096 cap silently blanked apps whose inline HTML outgrew it).
pub const max_window_source_bytes: usize = 65536;
/// Budget for the path-shaped source fields (asset root, entry, origin),
/// which never need the full document budget.
pub const max_window_source_path_bytes: usize = 4096;
pub const max_webviews: usize = 16;
pub const max_webview_label_bytes: usize = 64;
pub const max_webview_url_bytes: usize = 4096;
pub const max_external_url_bytes: usize = 4096;
pub const max_reveal_path_bytes: usize = 4096;
pub const max_recent_document_path_bytes: usize = 4096;
pub const max_notification_title_bytes: usize = 128;
pub const max_notification_subtitle_bytes: usize = 128;
pub const max_notification_body_bytes: usize = 1024;
pub const max_clipboard_mime_type_bytes: usize = 128;
pub const max_clipboard_data_bytes: usize = 65536;
pub const max_credential_service_bytes: usize = 128;
pub const max_credential_account_bytes: usize = 256;
pub const max_credential_secret_bytes: usize = 4096;
pub const max_tray_items: usize = 32;
pub const max_tray_icon_path_bytes: usize = 4096;
pub const max_tray_title_bytes: usize = 64;
pub const max_tray_tooltip_bytes: usize = 256;
pub const max_tray_item_label_bytes: usize = 256;
pub const max_tray_item_command_bytes: usize = 128;
pub const max_drop_paths_bytes: usize = 8192;
pub const max_drop_paths: usize = max_drop_paths_bytes / 2 + 1;
pub const max_window_event_name_bytes: usize = 64;
pub const max_window_event_detail_bytes: usize = 8192;
pub const max_views: usize = 32;
pub const max_view_label_bytes: usize = 64;
pub const max_view_role_bytes: usize = 64;
pub const max_view_accessibility_label_bytes: usize = 256;
pub const max_view_text_bytes: usize = 1024;
pub const max_view_command_bytes: usize = 128;
pub const max_menus: usize = 16;
pub const max_menu_items: usize = 128;
pub const max_menu_title_bytes: usize = 64;
pub const max_menu_item_label_bytes: usize = 128;
pub const max_menu_command_bytes: usize = 128;
pub const max_menu_key_bytes: usize = 32;
pub const max_shortcuts: usize = 64;
pub const max_shortcut_id_bytes: usize = 64;
pub const max_shortcut_key_bytes: usize = 32;
pub const max_widget_accessibility_nodes: usize = 64;
pub const max_gpu_surface_packet_json_bytes: usize = 128 * 1024;
/// Payload bound for the compact binary gpu-surface packet encoding
/// (`present_gpu_surface_packet_binary_fn`). Sized so a worst-case
/// text-heavy frame still rides the packet path instead of falling back
/// to the software pixel raster: the per-view budgets allow 2048 draw
/// commands (~96 B of fixed binary fields each ≈ 192 KiB), every
/// measured wrapped line (8192 lines × 12 B of pen data ≈ 96 KiB), and
/// the view's whole text pool carried twice — once on the run, once
/// sliced across its lines (2 × 32 KiB = 64 KiB) — totalling ≈ 352 KiB;
/// 512 KiB leaves headroom for gradients, paths, and format growth. The
/// buffer is a single static per UiApp instance, so the cost is fixed
/// address space, not per-frame allocation.
pub const max_gpu_surface_packet_binary_bytes: usize = 512 * 1024;
/// Bound for the fallback-detail command-kind name recorded when a
/// packet present falls back because a command is not representable
/// (fits every `CanvasCommand` tag name).
pub const max_gpu_present_fallback_detail_bytes: usize = 32;
/// Per-image bound for the binary gpu-surface image upload side-channel;
/// matches the runtime registry's per-slot bound
/// (`canvas_limits.max_registered_canvas_image_pixel_bytes`). Applies to
/// ORDINARY registered-image ids only: the registry refuses anything
/// larger at registration, so an over-bound upload of a registered image
/// can only be an engine bug and is refused loudly here rather than
/// copied into host allocations.
pub const max_gpu_surface_image_pixel_bytes: usize = 1024 * 1024;
/// Per-image bound for uploads in the media-surface texture namespace
/// (ids with `canvas.media_surface_image_id_bit` set — producer-pushed
/// dynamic textures, structurally disjoint from registered-image ids):
/// video scale, not avatar scale. Matches the producer channel's
/// per-frame budget (`canvas_limits.max_media_surface_pixel_bytes`; a
/// lockstep test in media_surface_tests.zig pins the pair), so a frame
/// the producer accepted — a full 1920x1080 RGBA8 frame included — can
/// never be refused between adoption and host presentation.
pub const max_gpu_surface_media_image_pixel_bytes: usize = 8 * 1024 * 1024;
/// Per-font bound for the gpu-surface font registration side-channel;
/// matches the runtime registry's per-slot bound
/// (`canvas_limits.max_registered_canvas_font_bytes`), sized so full
/// CJK faces register (Noto Sans SC's TrueType build, the largest
/// measured, is 17.8 MB).
pub const max_gpu_surface_font_bytes: usize = 24 * 1024 * 1024;

pub const ShortcutModifiers = struct {
    primary: bool = false,
    command: bool = false,
    control: bool = false,
    option: bool = false,
    shift: bool = false,

    pub fn hasAny(self: ShortcutModifiers) bool {
        return self.primary or self.command or self.control or self.option or self.shift;
    }
};

pub const Shortcut = struct {
    id: []const u8,
    key: []const u8,
    modifiers: ShortcutModifiers = .{},
};

pub const ShortcutEvent = struct {
    id: []const u8,
    key: []const u8,
    modifiers: ShortcutModifiers = .{},
    window_id: WindowId = 1,
};

pub const Menu = struct {
    title: []const u8,
    items: []const MenuItem = &.{},
};

pub const MenuItem = struct {
    label: []const u8 = "",
    command: []const u8 = "",
    key: []const u8 = "",
    modifiers: ShortcutModifiers = .{},
    separator: bool = false,
    enabled: bool = true,
    checked: bool = false,
};

pub fn validateShortcut(shortcut: Shortcut) Error!void {
    if (!isValidCommandId(shortcut.id, max_shortcut_id_bytes)) return error.InvalidShortcut;
    if (!isValidShortcutKey(shortcut.key)) return error.InvalidShortcut;
    if (!shortcut.modifiers.hasAny() and shortcutRequiresModifier(shortcut.key)) return error.InvalidShortcut;
}

pub fn validateMenus(menus: []const Menu) Error!void {
    if (menus.len > max_menus) return error.InvalidMenuOptions;
    var item_count: usize = 0;
    for (menus) |menu| {
        if (menu.title.len == 0 or menu.title.len > max_menu_title_bytes) return error.InvalidMenuOptions;
        item_count += menu.items.len;
        if (item_count > max_menu_items) return error.InvalidMenuOptions;
        for (menu.items) |item| try validateMenuItem(item);
    }
}

pub fn validateMenuItem(item: MenuItem) Error!void {
    if (item.separator) return;
    if (item.label.len == 0 or item.label.len > max_menu_item_label_bytes) return error.InvalidMenuOptions;
    if (!isValidCommandId(item.command, max_menu_command_bytes)) return error.InvalidCommand;
    if (item.key.len > 0) {
        if (!isValidShortcutKey(item.key)) return error.InvalidShortcut;
        if (item.key.len > max_menu_key_bytes) return error.InvalidShortcut;
        if (!item.modifiers.hasAny() and shortcutRequiresModifier(item.key)) return error.InvalidShortcut;
    }
}

fn isValidCommandId(command: []const u8, max_len: usize) bool {
    if (command.len == 0 or command.len > max_len) return false;
    if (std.mem.eql(u8, command, ".") or std.mem.eql(u8, command, "..")) return false;
    for (command) |ch| {
        if (ch == 0 or ch == '/' or ch == '\\' or ch == '\n' or ch == '\r' or ch == '\t') return false;
    }
    return true;
}

pub fn isValidShortcutKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_shortcut_key_bytes) return false;
    if (key.len == 1) {
        const ch = key[0];
        if (std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch)) return true;
        return switch (ch) {
            '=', '-', ',', '.', '/', ';', '\'', '[', ']', '\\', '`' => true,
            else => false,
        };
    }
    const specials = [_][]const u8{
        "escape",
        "enter",
        "tab",
        "space",
        "backspace",
        "arrowleft",
        "arrowright",
        "arrowup",
        "arrowdown",
        "delete",
        "home",
        "end",
        "pageup",
        "pagedown",
        "insert",
        "f1",
        "f2",
        "f3",
        "f4",
        "f5",
        "f6",
        "f7",
        "f8",
        "f9",
        "f10",
        "f11",
        "f12",
    };
    for (&specials) |special| {
        if (std.ascii.eqlIgnoreCase(key, special)) return true;
    }
    return false;
}

fn shortcutRequiresModifier(key: []const u8) bool {
    if (key.len == 1) return true;
    return std.ascii.eqlIgnoreCase(key, "space") or
        std.ascii.eqlIgnoreCase(key, "enter") or
        std.ascii.eqlIgnoreCase(key, "tab") or
        std.ascii.eqlIgnoreCase(key, "backspace");
}

pub const WindowRestorePolicy = enum {
    clamp_to_visible_screen,
    center_on_primary,
};

/// How the window draws its titlebar chrome.
/// `.hidden_inset` is the modern editor-app shape: content extends under a
/// transparent titlebar with the title hidden (macOS:
/// `NSWindowStyleMaskFullSizeContentView` + `titlebarAppearsTransparent`
/// + `titleVisibility` hidden — the traffic lights stay). The app's own
/// header becomes the drag surface through the widget `window_drag`
/// channel (`start_window_drag_fn`), and it lays out around the traffic
/// lights via `window_chrome_fn`. Platforms without the concept
/// ignore it (standard chrome).
///
/// `.hidden_inset_tall` is the same shape with the TALL titlebar band —
/// the unified-toolbar height (~52pt vs ~28pt), where the
/// system vertically centers the traffic lights in the band (macOS: an
/// empty borderless `NSToolbar` + `NSWindowToolbarStyleUnified` +
/// `titlebarSeparatorStyle = .none` — pure geometry, nothing drawn).
/// Pick it when the app's own header row is toolbar-height, so the
/// lights sit centered against the header instead of hugging its top.
///
/// `.chromeless` is the fully-skinned-app shape: NO OS chrome at all —
/// no titlebar band and no system window buttons (macOS: a borderless
/// styleMask, so the traffic lights are gone too; Windows: a
/// caption-less `WS_POPUP` window; Linux: `gtk_window_set_decorated
/// FALSE`). An EXPLICIT opt-in for apps whose chassis draws its OWN
/// working close/minimize controls wired to real window actions
/// (`close_window_fn` / `minimize_window_fn`); ordinary apps should use
/// the hidden styles above, which keep the real OS controls — a window
/// with no chrome and no replacement controls is an affordance lie.
/// Drag still rides the widget `window_drag` channel.
pub const WindowTitlebarStyle = enum {
    standard,
    hidden_inset,
    hidden_inset_tall,
    chromeless,
};

/// The host-reported form factor (size class) of the surface an app
/// runs on, riding the window-chrome channel beside the inset geometry.
/// `.unknown` is the honest default everywhere the host has not said —
/// desktop windows, tests, hosts that predate the report — so apps keep
/// their own width-derived fallback and a missing report never lies.
/// Mobile hosts report the platform's real size class (UIKit's
/// horizontal size class on iOS): `.compact` is the phone-class shape,
/// `.regular` the tablet/desktop-class one. Because the report arrives
/// through the same chrome channel apps already map into a Msg, the
/// value lives in the model and replays deterministically with the rest
/// of the journal.
pub const FormFactor = enum(u8) {
    unknown,
    compact,
    regular,
};

/// What `window_chrome_fn` reports for a window: where OS window chrome
/// overlays the app's content, so a hidden-titlebar header can pad AND
/// vertically center against it honestly instead of hardcoding pixel
/// counts. All-zero on standard-chrome windows, in fullscreen (the
/// system hides the band and the lights), and on platforms without the
/// concept.
pub const WindowChrome = struct {
    /// The band at each edge where OS chrome overlays the content.
    /// The window-control cluster lands on the edge its platform puts
    /// it: macOS reports the titlebar band height on top (~28pt
    /// compact, ~52pt tall) and the traffic lights' extent on the LEFT
    /// (margin included); Windows reports the caption-button band
    /// height on top and the min/max/close cluster's extent on the
    /// RIGHT. A header that pads BOTH `insets.left` and `insets.right`
    /// therefore clears the controls on every platform with no
    /// per-platform code — the unused edge is honestly zero.
    insets: geometry.InsetsF = .{},
    /// The window-control cluster's bounding frame (macOS: the three
    /// traffic lights; Windows: the DWM-drawn min/max/close buttons) in
    /// content coordinates, top-left origin — the vertical truth a
    /// header needs to center its controls against the cluster
    /// (`buttons.y + buttons.height / 2` is their centerline).
    /// Zero-sized when no controls overlay the content.
    buttons: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    /// The host-reported form factor of the surface, `.unknown` when the
    /// host reports none (desktop windows, tests). Apps that switch
    /// shells on width keep that derivation as the fallback and prefer
    /// this field when present.
    form_factor: FormFactor = .unknown,
    /// True while the host projects the app's declared chrome tabs
    /// (`ShellConfig.chrome.tabs`) as REAL native controls — an actual
    /// system tab bar owning the tab affordance. An app whose canvas
    /// composes its own tab switcher yields it when this is set (the
    /// native bar is the one switcher) and keeps it everywhere the
    /// declaration is inert. Rides the chrome channel so the flag lands
    /// in the model as a Msg and replays with the journal.
    tabs_projected: bool = false,
};

/// One rectangle of a window's DRAG-REGION mirror (`window-drag="true"`
/// in markup / `.window_drag` on a widget), in the canvas view's local
/// logical coordinates. The runtime pushes the mirror through
/// `set_window_drag_regions_fn` after every layout install so platforms
/// whose native titlebar behavior lives in a hit-test (Windows:
/// `WM_NCHITTEST` answering `HTCAPTION`, which buys drag,
/// double-click-to-maximize, and the right-click system menu from the
/// OS) can answer without a round trip into the runtime. `exclusion`
/// rectangles are the press-claiming widgets INSIDE a drag region — a
/// button in a drag header keeps its press, exactly like the runtime's
/// own pointer walk — and a point counts as draggable only when it is
/// inside a region rect and outside every exclusion rect. Platforms
/// that start drags from the live pointer gesture instead (macOS:
/// `performWindowDragWithEvent:`) leave the service null and the
/// runtime skips the mirror entirely.
pub const WindowDragRegion = struct {
    frame: geometry.RectF,
    exclusion: bool = false,
};

/// When a created window first becomes visible.
/// `.immediate` is the classic shape: ordered front at create — right
/// for webview windows, whose engine paints its own first frame.
/// `.on_first_present` is the canvas-window contract: the window is
/// created ORDERED OUT and becomes visible only after its first canvas
/// frame has completed presentation (macOS: the packet/pixel present
/// lands, then `makeKeyAndOrderFront`), so the user never sees a blank
/// window while the first frame renders. Platforms keep a short
/// fallback deadline so a wedged first frame cannot leave the window
/// invisible forever.
pub const WindowShowMode = enum {
    immediate,
    on_first_present,
};

/// What the user's close affordance (the red traffic light, cmd+W, the
/// caption X) does to this window.
/// `.quit` is the default and today's behavior unchanged: the window
/// really closes, and the last close follows the host's exit semantics.
/// `.hide` is the menu-bar/tray-app shape: the close affordance hides
/// the window instead — it stays alive in the host's records (no
/// shutdown), `WindowState.hidden` flips true on the frame channel,
/// and `Effects.showWindow` / the macOS Dock reopen bring it back.
/// Hosts that cannot re-show a hidden window (GTK has no status item
/// to click) refuse `.hide` at create time with a teaching error —
/// never a silent no-op that strands the window.
/// Deliberate enum room for a future `.event` tier (model-decides
/// close, for unsaved-changes flows) — not implemented yet.
pub const WindowClosePolicy = enum {
    quit,
    hide,
};

pub const WindowOptions = struct {
    id: WindowId = 1,
    label: []const u8 = "main",
    title: []const u8 = "",
    default_frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    resizable: bool = true,
    restore_state: bool = true,
    restore_policy: WindowRestorePolicy = .clamp_to_visible_screen,
    titlebar: WindowTitlebarStyle = .standard,
    show: WindowShowMode = .immediate,
    /// Content min-size floor the WINDOW enforces (macOS
    /// `contentMinSize`): the user cannot resize below it, so declared
    /// layout floors stop clamping/clipping panes instead of stopping
    /// the resize. 0 = no floor on that axis. Applied at create; it
    /// does not grow an already-smaller restored frame.
    min_width: f32 = 0,
    min_height: f32 = 0,
    /// What the user's close affordance does — see `WindowClosePolicy`.
    /// Fixed at create like the titlebar: it is host window state.
    close_policy: WindowClosePolicy = .quit,

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
    /// True while the window is alive but off the glass because its
    /// `close_policy = .hide` intercepted a user close (the menu-bar-app
    /// shape): the window keeps its views and native identity, `open`
    /// stays true, and a show — `Effects.showWindow`, a tray action's
    /// consequence, the macOS Dock reopen — flips it back. Distinct from
    /// minimized (which keeps a Dock/taskbar affordance) and from
    /// closed (`open = false`, the window is gone). Session-transient:
    /// never persisted to the window-state store, so every launch
    /// starts shown.
    hidden: bool = false,
};

pub const WindowInfo = struct {
    id: WindowId = 1,
    label: []const u8 = "main",
    title: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 720, 480),
    scale_factor: f32 = 1,
    open: bool = true,
    focused: bool = false,
    /// Alive but policy-hidden — see `WindowState.hidden`.
    hidden: bool = false,

    pub fn state(self: WindowInfo) WindowState {
        return .{
            .id = self.id,
            .label = self.label,
            .title = self.title,
            .frame = self.frame,
            .scale_factor = self.scale_factor,
            .open = self.open,
            .focused = self.focused,
            .hidden = self.hidden,
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
    titlebar: WindowTitlebarStyle = .standard,
    show: WindowShowMode = .immediate,
    /// Window-enforced content min-size floor (see
    /// `WindowOptions.min_width`/`min_height`); 0 = no floor.
    min_width: f32 = 0,
    min_height: f32 = 0,
    /// See `WindowOptions.close_policy`.
    close_policy: WindowClosePolicy = .quit,
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
            .titlebar = self.titlebar,
            .show = self.show,
            .min_width = self.min_width,
            .min_height = self.min_height,
            .close_policy = self.close_policy,
        };
    }
};

pub const WebViewOptions = struct {
    window_id: WindowId = 1,
    label: []const u8,
    url: []const u8,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    transparent: bool = false,
    bridge_enabled: bool = false,
};

pub const WebViewInfo = struct {
    window_id: WindowId = 1,
    label: []const u8 = "webview",
    url: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    zoom: f64 = 1.0,
    transparent: bool = false,
    bridge_enabled: bool = false,
    focused: bool = false,
    open: bool = true,
};

pub const ViewKind = enum {
    webview,
    toolbar,
    titlebar_accessory,
    sidebar,
    statusbar,
    split,
    stack,
    button,
    icon_button,
    list_item,
    checkbox,
    toggle,
    segmented_control,
    text_field,
    search_field,
    label,
    spacer,
    gpu_surface,
    progress_indicator,
};

pub const GpuSurfaceBackend = enum {
    none,
    metal,
    /// CPU rasterization (reference renderer) presented through the
    /// platform's pixel blit path. Platforms without a GPU packet renderer
    /// (Linux/GTK) report this backend in their frame events; manifests
    /// declaring another backend fall back to it rather than erroring.
    software,
};

pub const GpuSurfacePixelFormat = enum {
    none,
    bgra8_unorm,
};

pub const GpuSurfacePresentMode = enum {
    none,
    timer,
};

/// Which presentation path last painted a gpu_surface view: the GPU
/// packet presenter (`presentGpuSurfacePacket`) or the CPU
/// reference-rendered pixel fallback (`presentGpuSurfacePixels`).
/// `.none` until the first successful present. Stamped only after the
/// platform present call returned success — a failed packet attempt
/// that fell back to pixels reports `.pixels`, and idle skipped frames
/// (no repaint needed) keep the previous value.
pub const GpuPresentPath = enum {
    none,
    packet,
    pixels,
};

/// HOW the most recent packet-path present moved its commands: a `full`
/// present ships the whole command list (and, on the binary wire,
/// rebuilds the host's retained command dictionary), a `patch` present
/// ships only an edit script (upserts + evicts + the draw-order vector)
/// against that retained state. `.none` before the first packet present.
/// Patch presents are why frame cost scales with what CHANGED instead of
/// with view size; snapshots surface this as `present_mode=` next to the
/// patch byte/edit counters.
pub const GpuPresentPacketMode = enum {
    none,
    full,
    patch,
};

/// WHY the most recent frame left the GPU packet path for the CPU pixel
/// fallback. `.none` while frames present through the packet path (or
/// before the first present). The two paths rasterize text and shapes
/// differently, so an oscillating view flips visibly between CoreText
/// and bundled-face glyphs — this reason plus the running
/// `gpu_present_fallback_frame_count` make every silent flip loud in
/// automation snapshots.
pub const GpuPresentFallbackReason = enum {
    none,
    /// The packet JSON did not fit the transport buffer; the view info
    /// carries needed vs available bytes.
    json_overflow,
    /// The compact binary packet encoding did not fit the transport
    /// buffer; the view info carries needed vs available bytes.
    binary_overflow,
    /// At least one planned command is not representable as a packet
    /// command; the view info names the first offending command kind.
    unsupported_command,
    /// The platform declared no packet presenter (or refused the
    /// present call with `error.UnsupportedService`).
    missing_service,
    /// The host refused an incremental `patch` present (retained state
    /// lost, generation mismatch, retained-command budget, or a decode
    /// failure). The runtime answers by re-presenting FULL in the same
    /// frame, so this reason is transient unless every frame refuses —
    /// the cumulative `present_fallback_frames` counter keeps the
    /// history visible either way.
    patch_refused,
};

pub const GpuSurfaceAlphaMode = enum {
    none,
    @"opaque",
    premultiplied,
};

pub const GpuSurfaceColorSpace = enum {
    none,
    srgb,
    display_p3,
};

pub const GpuSurfaceStatus = enum {
    unavailable,
    initializing,
    ready,
    lost,
};

pub const CanvasFrameProfileRisk = enum {
    idle,
    low,
    moderate,
    high,
};

pub const GpuSurfaceOptions = struct {
    backend: GpuSurfaceBackend = .metal,
    pixel_format: GpuSurfacePixelFormat = .bgra8_unorm,
    present_mode: GpuSurfacePresentMode = .timer,
    alpha_mode: GpuSurfaceAlphaMode = .@"opaque",
    color_space: GpuSurfaceColorSpace = .srgb,
    vsync: bool = true,

    pub fn isSupported(self: GpuSurfaceOptions) bool {
        return (self.backend == .metal or self.backend == .software) and
            self.pixel_format == .bgra8_unorm and
            self.present_mode == .timer and
            self.alpha_mode == .@"opaque" and
            self.color_space == .srgb and
            self.vsync;
    }
};

pub const ViewOptions = struct {
    window_id: WindowId = 1,
    label: []const u8,
    kind: ViewKind,
    parent: ?[]const u8 = null,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    visible: bool = true,
    enabled: bool = true,
    role: []const u8 = "",
    accessibility_label: []const u8 = "",
    text: []const u8 = "",
    command: []const u8 = "",
    url: []const u8 = "",
    transparent: bool = false,
    bridge_enabled: bool = false,
    gpu_surface: GpuSurfaceOptions = .{},

    pub fn webViewOptions(self: ViewOptions) WebViewOptions {
        return .{
            .window_id = self.window_id,
            .label = self.label,
            .url = self.url,
            .frame = self.frame,
            .layer = self.layer,
            .transparent = self.transparent,
            .bridge_enabled = self.bridge_enabled,
        };
    }
};

pub const ViewPatch = struct {
    frame: ?geometry.RectF = null,
    layer: ?i32 = null,
    visible: ?bool = null,
    enabled: ?bool = null,
    role: ?[]const u8 = null,
    accessibility_label: ?[]const u8 = null,
    text: ?[]const u8 = null,
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const Cursor = enum {
    arrow,
    pointing_hand,
    text,
    resize_horizontal,
};

pub const ViewInfo = struct {
    id: ViewId = 0,
    window_id: WindowId = 1,
    label: []const u8 = "",
    kind: ViewKind = .webview,
    parent: ?[]const u8 = null,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    visible: bool = true,
    enabled: bool = true,
    role: []const u8 = "",
    accessibility_label: []const u8 = "",
    text: []const u8 = "",
    command: []const u8 = "",
    url: []const u8 = "",
    transparent: bool = false,
    bridge_enabled: bool = false,
    gpu_size: geometry.SizeF = geometry.SizeF.init(0, 0),
    gpu_scale_factor: f32 = 1,
    gpu_frame_index: u64 = 0,
    gpu_timestamp_ns: u64 = 0,
    gpu_frame_interval_ns: u64 = default_gpu_frame_interval_ns,
    gpu_input_timestamp_ns: u64 = 0,
    gpu_input_latency_ns: u64 = 0,
    gpu_input_latency_budget_ns: u64 = default_gpu_frame_interval_ns,
    gpu_input_latency_budget_exceeded_count: usize = 0,
    gpu_input_latency_budget_ok: bool = true,
    gpu_first_frame_latency_ns: u64 = 0,
    gpu_first_frame_latency_budget_ns: u64 = default_gpu_first_frame_latency_budget_ns,
    gpu_first_frame_latency_budget_exceeded_count: usize = 0,
    gpu_first_frame_latency_budget_ok: bool = true,
    gpu_frame_nonblank: bool = false,
    gpu_sample_color: u32 = 0,
    gpu_backend: GpuSurfaceBackend = .none,
    gpu_pixel_format: GpuSurfacePixelFormat = .none,
    gpu_present_mode: GpuSurfacePresentMode = .none,
    gpu_alpha_mode: GpuSurfaceAlphaMode = .none,
    gpu_color_space: GpuSurfaceColorSpace = .none,
    gpu_vsync: bool = false,
    gpu_status: GpuSurfaceStatus = .unavailable,
    /// The path that last painted this surface (see `GpuPresentPath`).
    gpu_present_path: GpuPresentPath = .none,
    /// Why the most recent packet attempt fell back to pixels (see
    /// `GpuPresentFallbackReason`); `.none` while the packet path holds.
    gpu_present_fallback_reason: GpuPresentFallbackReason = .none,
    /// Encoded packet bytes the last overflow fallback needed (0 unless
    /// the reason is an overflow).
    gpu_present_fallback_needed_bytes: usize = 0,
    /// Transport bytes that were available to that overflowing encode.
    gpu_present_fallback_limit_bytes: usize = 0,
    /// First unrepresentable command kind behind an
    /// `unsupported_command` fallback ("" otherwise).
    gpu_present_fallback_command_kind: []const u8 = "",
    /// Running count of frames this view painted through the pixel
    /// fallback after a packet attempt (never resets while the view is
    /// open, so snapshots catch oscillation that self-heals between
    /// polls).
    gpu_present_fallback_frame_count: usize = 0,
    /// How the last packet present moved its commands (see
    /// `GpuPresentPacketMode`): `patch` while incremental presentation
    /// holds, `full` on baselines/resyncs, `none` before the first
    /// packet present.
    gpu_present_packet_mode: GpuPresentPacketMode = .none,
    /// Encoded bytes of the last patch present (0 while presents are
    /// full) — the number that makes the incremental win measurable
    /// against the full-present size.
    gpu_present_patch_bytes: usize = 0,
    /// Commands the last patch inserted or replaced.
    gpu_present_patch_upsert_count: usize = 0,
    /// Commands the last patch evicted.
    gpu_present_patch_evict_count: usize = 0,
    /// Commands currently retained host-side for this view (the engine's
    /// mirror of the host dictionary; 0 while no baseline is
    /// established).
    gpu_present_retained_command_count: usize = 0,
    canvas_revision: u64 = 0,
    canvas_command_count: usize = 0,
    canvas_frame_requires_render: bool = false,
    canvas_frame_full_repaint: bool = false,
    canvas_frame_batch_count: usize = 0,
    canvas_frame_encoder_command_count: usize = 0,
    canvas_frame_encoder_cache_action_count: usize = 0,
    canvas_frame_encoder_bind_pipeline_count: usize = 0,
    canvas_frame_encoder_draw_batch_count: usize = 0,
    canvas_frame_pipeline_count: usize = 0,
    canvas_frame_pipeline_upload_count: usize = 0,
    canvas_frame_pipeline_retain_count: usize = 0,
    canvas_frame_pipeline_evict_count: usize = 0,
    canvas_frame_path_geometry_count: usize = 0,
    canvas_frame_path_geometry_vertex_count: usize = 0,
    canvas_frame_path_geometry_index_count: usize = 0,
    canvas_frame_path_geometry_upload_count: usize = 0,
    canvas_frame_path_geometry_retain_count: usize = 0,
    canvas_frame_path_geometry_evict_count: usize = 0,
    canvas_frame_image_count: usize = 0,
    canvas_frame_image_upload_count: usize = 0,
    canvas_frame_image_retain_count: usize = 0,
    canvas_frame_image_evict_count: usize = 0,
    canvas_frame_layer_count: usize = 0,
    canvas_frame_layer_opacity_count: usize = 0,
    canvas_frame_layer_clip_count: usize = 0,
    canvas_frame_layer_transform_count: usize = 0,
    canvas_frame_layer_upload_count: usize = 0,
    canvas_frame_layer_retain_count: usize = 0,
    canvas_frame_layer_evict_count: usize = 0,
    canvas_frame_resource_count: usize = 0,
    canvas_frame_resource_upload_count: usize = 0,
    canvas_frame_resource_retain_count: usize = 0,
    canvas_frame_resource_evict_count: usize = 0,
    canvas_frame_visual_effect_count: usize = 0,
    canvas_frame_visual_effect_shadow_count: usize = 0,
    canvas_frame_visual_effect_blur_count: usize = 0,
    canvas_frame_visual_effect_upload_count: usize = 0,
    canvas_frame_visual_effect_retain_count: usize = 0,
    canvas_frame_visual_effect_evict_count: usize = 0,
    canvas_frame_glyph_atlas_entry_count: usize = 0,
    canvas_frame_glyph_atlas_upload_count: usize = 0,
    canvas_frame_glyph_atlas_retain_count: usize = 0,
    canvas_frame_glyph_atlas_evict_count: usize = 0,
    canvas_frame_text_layout_count: usize = 0,
    canvas_frame_text_layout_line_count: usize = 0,
    canvas_frame_text_layout_upload_count: usize = 0,
    canvas_frame_text_layout_retain_count: usize = 0,
    canvas_frame_text_layout_evict_count: usize = 0,
    canvas_frame_gpu_packet_command_count: usize = 0,
    canvas_frame_gpu_packet_cache_action_count: usize = 0,
    canvas_frame_gpu_packet_cached_resource_command_count: usize = 0,
    canvas_frame_gpu_packet_unsupported_command_count: usize = 0,
    canvas_frame_gpu_packet_representable: bool = true,
    canvas_frame_change_count: usize = 0,
    canvas_frame_budget_exceeded_count: usize = 0,
    canvas_frame_budget_ok: bool = true,
    canvas_frame_dirty_bounds: ?geometry.RectF = null,
    canvas_frame_profile_work_units: usize = 0,
    canvas_frame_profile_risk: CanvasFrameProfileRisk = .idle,
    canvas_frame_profile_surface_area: f32 = 0,
    canvas_frame_profile_dirty_area: f32 = 0,
    canvas_frame_profile_dirty_ratio: f32 = 0,
    widget_revision: u64 = 0,
    widget_node_count: usize = 0,
    widget_semantics_count: usize = 0,
    /// Declared context-menu entries retained across all widgets of the
    /// view (the runtime's per-view budget headroom rides in automation
    /// snapshots as `context_menu_items=declared/budget`).
    widget_context_menu_item_count: usize = 0,
    cursor: Cursor = .arrow,
    focused: bool = false,
    open: bool = true,

    pub fn gpuFrame(self: ViewInfo) ?GpuFrame {
        if (self.kind != .gpu_surface) return null;
        return .{
            .surface_id = self.id,
            .window_id = self.window_id,
            .label = self.label,
            .size = self.gpu_size,
            .scale_factor = self.gpu_scale_factor,
            .frame_index = self.gpu_frame_index,
            .timestamp_ns = self.gpu_timestamp_ns,
            .frame_interval_ns = self.gpu_frame_interval_ns,
            .input_timestamp_ns = self.gpu_input_timestamp_ns,
            .input_latency_ns = self.gpu_input_latency_ns,
            .input_latency_budget_ns = self.gpu_input_latency_budget_ns,
            .input_latency_budget_exceeded_count = self.gpu_input_latency_budget_exceeded_count,
            .input_latency_budget_ok = self.gpu_input_latency_budget_ok,
            .first_frame_latency_ns = self.gpu_first_frame_latency_ns,
            .first_frame_latency_budget_ns = self.gpu_first_frame_latency_budget_ns,
            .first_frame_latency_budget_exceeded_count = self.gpu_first_frame_latency_budget_exceeded_count,
            .first_frame_latency_budget_ok = self.gpu_first_frame_latency_budget_ok,
            .nonblank = self.gpu_frame_nonblank,
            .sample_color = self.gpu_sample_color,
            .backend = self.gpu_backend,
            .pixel_format = self.gpu_pixel_format,
            .present_mode = self.gpu_present_mode,
            .alpha_mode = self.gpu_alpha_mode,
            .color_space = self.gpu_color_space,
            .vsync = self.gpu_vsync,
            .status = self.gpu_status,
            .canvas_revision = self.canvas_revision,
            .canvas_command_count = self.canvas_command_count,
            .canvas_frame_requires_render = self.canvas_frame_requires_render,
            .canvas_frame_full_repaint = self.canvas_frame_full_repaint,
            .canvas_frame_batch_count = self.canvas_frame_batch_count,
            .canvas_frame_encoder_command_count = self.canvas_frame_encoder_command_count,
            .canvas_frame_encoder_cache_action_count = self.canvas_frame_encoder_cache_action_count,
            .canvas_frame_encoder_bind_pipeline_count = self.canvas_frame_encoder_bind_pipeline_count,
            .canvas_frame_encoder_draw_batch_count = self.canvas_frame_encoder_draw_batch_count,
            .canvas_frame_pipeline_count = self.canvas_frame_pipeline_count,
            .canvas_frame_pipeline_upload_count = self.canvas_frame_pipeline_upload_count,
            .canvas_frame_pipeline_retain_count = self.canvas_frame_pipeline_retain_count,
            .canvas_frame_pipeline_evict_count = self.canvas_frame_pipeline_evict_count,
            .canvas_frame_path_geometry_count = self.canvas_frame_path_geometry_count,
            .canvas_frame_path_geometry_vertex_count = self.canvas_frame_path_geometry_vertex_count,
            .canvas_frame_path_geometry_index_count = self.canvas_frame_path_geometry_index_count,
            .canvas_frame_path_geometry_upload_count = self.canvas_frame_path_geometry_upload_count,
            .canvas_frame_path_geometry_retain_count = self.canvas_frame_path_geometry_retain_count,
            .canvas_frame_path_geometry_evict_count = self.canvas_frame_path_geometry_evict_count,
            .canvas_frame_image_count = self.canvas_frame_image_count,
            .canvas_frame_image_upload_count = self.canvas_frame_image_upload_count,
            .canvas_frame_image_retain_count = self.canvas_frame_image_retain_count,
            .canvas_frame_image_evict_count = self.canvas_frame_image_evict_count,
            .canvas_frame_layer_count = self.canvas_frame_layer_count,
            .canvas_frame_layer_opacity_count = self.canvas_frame_layer_opacity_count,
            .canvas_frame_layer_clip_count = self.canvas_frame_layer_clip_count,
            .canvas_frame_layer_transform_count = self.canvas_frame_layer_transform_count,
            .canvas_frame_layer_upload_count = self.canvas_frame_layer_upload_count,
            .canvas_frame_layer_retain_count = self.canvas_frame_layer_retain_count,
            .canvas_frame_layer_evict_count = self.canvas_frame_layer_evict_count,
            .canvas_frame_resource_count = self.canvas_frame_resource_count,
            .canvas_frame_resource_upload_count = self.canvas_frame_resource_upload_count,
            .canvas_frame_resource_retain_count = self.canvas_frame_resource_retain_count,
            .canvas_frame_resource_evict_count = self.canvas_frame_resource_evict_count,
            .canvas_frame_visual_effect_count = self.canvas_frame_visual_effect_count,
            .canvas_frame_visual_effect_shadow_count = self.canvas_frame_visual_effect_shadow_count,
            .canvas_frame_visual_effect_blur_count = self.canvas_frame_visual_effect_blur_count,
            .canvas_frame_visual_effect_upload_count = self.canvas_frame_visual_effect_upload_count,
            .canvas_frame_visual_effect_retain_count = self.canvas_frame_visual_effect_retain_count,
            .canvas_frame_visual_effect_evict_count = self.canvas_frame_visual_effect_evict_count,
            .canvas_frame_glyph_atlas_entry_count = self.canvas_frame_glyph_atlas_entry_count,
            .canvas_frame_glyph_atlas_upload_count = self.canvas_frame_glyph_atlas_upload_count,
            .canvas_frame_glyph_atlas_retain_count = self.canvas_frame_glyph_atlas_retain_count,
            .canvas_frame_glyph_atlas_evict_count = self.canvas_frame_glyph_atlas_evict_count,
            .canvas_frame_text_layout_count = self.canvas_frame_text_layout_count,
            .canvas_frame_text_layout_line_count = self.canvas_frame_text_layout_line_count,
            .canvas_frame_text_layout_upload_count = self.canvas_frame_text_layout_upload_count,
            .canvas_frame_text_layout_retain_count = self.canvas_frame_text_layout_retain_count,
            .canvas_frame_text_layout_evict_count = self.canvas_frame_text_layout_evict_count,
            .canvas_frame_gpu_packet_command_count = self.canvas_frame_gpu_packet_command_count,
            .canvas_frame_gpu_packet_cache_action_count = self.canvas_frame_gpu_packet_cache_action_count,
            .canvas_frame_gpu_packet_cached_resource_command_count = self.canvas_frame_gpu_packet_cached_resource_command_count,
            .canvas_frame_gpu_packet_unsupported_command_count = self.canvas_frame_gpu_packet_unsupported_command_count,
            .canvas_frame_gpu_packet_representable = self.canvas_frame_gpu_packet_representable,
            .canvas_frame_change_count = self.canvas_frame_change_count,
            .canvas_frame_budget_exceeded_count = self.canvas_frame_budget_exceeded_count,
            .canvas_frame_budget_ok = self.canvas_frame_budget_ok,
            .canvas_frame_dirty_bounds = self.canvas_frame_dirty_bounds,
            .canvas_frame_profile_work_units = self.canvas_frame_profile_work_units,
            .canvas_frame_profile_risk = self.canvas_frame_profile_risk,
            .canvas_frame_profile_surface_area = self.canvas_frame_profile_surface_area,
            .canvas_frame_profile_dirty_area = self.canvas_frame_profile_dirty_area,
            .canvas_frame_profile_dirty_ratio = self.canvas_frame_profile_dirty_ratio,
            .widget_revision = self.widget_revision,
            .widget_node_count = self.widget_node_count,
            .widget_semantics_count = self.widget_semantics_count,
        };
    }
};

pub const AppInfo = struct {
    app_name: []const u8 = "native-sdk",
    /// The human-facing application name (app.zon `display_name`) the
    /// host shows wherever the OS names the app: the application menu
    /// and its About/Hide/Quit items, the Dock tile, the app switcher,
    /// and the About panel. Falls back through the window title to
    /// `app_name` (the binary name) via `resolvedDisplayName`.
    display_name: []const u8 = "",
    /// The app version (app.zon `version`), shown in the About panel.
    version: []const u8 = "",
    /// The one-line app description (app.zon `description`), shown as
    /// the About panel's credits line when present.
    description: []const u8 = "",
    /// Whether the manifest declares web content (the `webview`
    /// capability or a `frontend` block). Hosts use it to build honest
    /// default menus: web items like Reload only exist when a webview
    /// can answer them.
    has_web_content: bool = false,
    /// Whether the manifest declares the "tray" capability (a status
    /// item). Close policy `.hide` leans on it where the OS has no
    /// built-in re-show affordance: hiding a window on windows removes
    /// its taskbar entry and windows has no dock-reopen path, so only a
    /// tray icon can bring the hidden window back. The Windows host
    /// folds this into its `window_hide_on_close` answer; macOS ignores
    /// it (the Dock reopen path always exists).
    declares_tray: bool = false,
    window_title: []const u8 = "",
    bundle_id: []const u8 = "dev.native_sdk.app",
    icon_path: []const u8 = "",
    main_window: WindowOptions = .{},
    windows: []const WindowOptions = &.{},

    pub fn resolvedWindowTitle(self: AppInfo) []const u8 {
        if (self.window_title.len > 0) return self.window_title;
        return self.main_window.resolvedTitle(self.app_name);
    }

    /// The name the OS should call the app: the manifest display name
    /// when declared, else the window title, else the binary name —
    /// never empty, so hosts can use it unconditionally.
    pub fn resolvedDisplayName(self: AppInfo) []const u8 {
        if (self.display_name.len > 0) return self.display_name;
        if (self.window_title.len > 0) return self.window_title;
        return self.app_name;
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
    safe_area_insets: geometry.InsetsF = .{},
    keyboard_insets: geometry.InsetsF = .{},
    native_handle: ?*anyopaque = null,
};

pub const BridgeMessage = struct {
    bytes: []const u8,
    origin: []const u8 = "",
    window_id: WindowId = 1,
    webview_label: []const u8 = "main",
};

pub const max_dialog_path_bytes: usize = 4096;
pub const max_dialog_paths_bytes: usize = 16 * 4096;
pub const max_dialog_title_bytes: usize = 512;
pub const max_dialog_message_bytes: usize = 4096;
pub const max_dialog_button_bytes: usize = 128;
pub const max_dialog_filter_name_bytes: usize = 256;
pub const max_dialog_filter_bytes: usize = 1024;

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

pub const NotificationOptions = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    body: []const u8 = "",
};

pub const CredentialKey = struct {
    service: []const u8,
    account: []const u8,
};

pub const Credential = struct {
    service: []const u8,
    account: []const u8,
    secret: []const u8,
};

pub const TrayItemId = u32;

pub const TrayOptions = struct {
    icon_path: []const u8 = "",
    /// Status-bar button title, shown when no icon resolves (macOS
    /// `NSStatusItem` menu-bar extras render it directly in the menu bar).
    title: []const u8 = "",
    tooltip: []const u8 = "",
    items: []const TrayMenuItem = &.{},
};

pub const TrayMenuItem = struct {
    id: TrayItemId = 0,
    label: []const u8 = "",
    command: []const u8 = "",
    separator: bool = false,
    enabled: bool = true,
};

pub const NativeCommandEvent = struct {
    name: []const u8,
    window_id: WindowId = 1,
    view_label: []const u8 = "",
};

pub const MenuCommandEvent = struct {
    name: []const u8,
    window_id: WindowId = 1,
};

/// Timer ids at or above this value are reserved for the framework's own
/// internal timers (for example the ui-app markup watch poll). Application
/// code must pick ids below this value when calling `startTimer`.
pub const reserved_timer_id_base: u64 = 0xffff_ffff_0000_0000;

/// Reserved framework timer id for the press-and-hold gesture
/// (`ElementOptions.on_hold`): the ui-app layer arms it on pointer-down
/// over a widget with a hold handler and dispatches the hold Msg when it
/// fires first. Defined at the platform layer so the automation dispatch
/// can fire the SAME timer a real gesture arms (`widget-hold`) without
/// knowing the app type.
pub const press_hold_timer_id: u64 = reserved_timer_id_base | 0x2e70_601d;

pub const TimerEvent = struct {
    id: u64,
    timestamp_ns: u64 = 0,
};

/// Longest audio file path `audioLoad` accepts; longer paths are rejected
/// with `error.AudioPathTooLarge` before the platform is asked.
pub const max_audio_path_bytes: usize = 1024;

/// How many band magnitudes every `.audio`/`.spectrum` event carries:
/// 32 buckets with log-spaced center frequencies covering roughly
/// 50 Hz .. 16 kHz — the audible span a bar analyzer honestly resolves.
/// The count is part of the event ABI on every host, so a consumer can
/// bind the array without negotiation.
pub const audio_spectrum_band_count: usize = 32;

/// The `.spectrum` magnitude reference scale: a band byte maps linearly
/// in DECIBELS from the analysis floor to full scale — 0 is at or below
/// `audio_spectrum_floor_db` dBFS (silence prints a row of zeros), 255
/// is 0 dBFS. Consumers divide by 255 for a 0..1 level; equal visual
/// steps are equal dB steps, which is how hardware analyzers read.
pub const audio_spectrum_floor_db: f32 = -60.0;

/// How the platform's audio player reports back. `loaded` answers a
/// successful `audioLoad` with the real decoded duration; `position` ticks
/// at the host's honest coarse cadence (about every 500ms) only while
/// playing; `completed` fires exactly once when a track reaches its natural
/// end; `failed` reports an asynchronous decode/device failure. Pause,
/// stop, seek, and volume never echo events — the caller already knows.
/// `spectrum` carries the real band magnitudes of the audio the app is
/// producing (see `AudioEvent.bands`) at a steady ~25 Hz cadence, only
/// while audio is audibly playing — pause, stop, and a buffering stall
/// starve the stream, so everything derived from it freezes honestly.
pub const AudioEventKind = enum(u8) {
    loaded,
    position,
    completed,
    failed,
    spectrum,
};

/// One report from the platform audio player. Positions and durations are
/// in milliseconds; `playing` is the player's honest state at emit time.
/// `buffering` is true while a streamed source is stalled waiting for
/// network bytes — distinct from `playing`, which reports the transport
/// intent; a stream can be "playing" (not paused) yet buffering (silent
/// until bytes arrive). Local-file playback never buffers.
pub const AudioEvent = struct {
    kind: AudioEventKind,
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    playing: bool = false,
    buffering: bool = false,
    /// `.spectrum` payload: `audio_spectrum_band_count` band magnitudes
    /// on the documented scale (log-spaced 50 Hz..16 kHz buckets; byte
    /// value linear-in-dB from `audio_spectrum_floor_db` dBFS at 0 to
    /// full scale at 255). All zeros on every other event kind. Plain
    /// bytes by design: the array journals verbatim at the event
    /// boundary, so replay repaints identical bars.
    bands: [audio_spectrum_band_count]u8 = @splat(0),
};

/// How `audioLoadUrl` resolved a URL source. `.cache` means a verified
/// local cache entry existed and plays as a plain local file — no
/// network is touched; `.stream` means playback streams progressively
/// from the network (starting as soon as enough bytes arrive) while the
/// same bytes are downloaded into the cache for the next play.
pub const AudioLoadResolution = enum(u8) {
    cache,
    stream,
};

/// Longest video source string (local path or URL) `videoLoad`/
/// `videoLoadUrl` accepts; longer strings are rejected with
/// `error.VideoPathTooLarge` before the platform is asked.
pub const max_video_path_bytes: usize = 1024;

/// How the platform's video player reports back — the audio vocabulary,
/// verbatim. `loaded` answers a successful load with the stream's real
/// pixel dimensions and the player's duration estimate; `position` ticks
/// at the host's honest coarse cadence (about every 500ms) only while
/// playing, carrying the stream's `buffering` flag; `completed` fires
/// exactly once when a non-looping video reaches its natural end (a
/// looping player wraps and keeps ticking — a video that never ends
/// never completes); `failed` reports an asynchronous decode/device
/// failure. Pause, stop, seek, volume, mute, and loop never echo events
/// — the caller already knows. Pixels never ride events: decoded frames
/// flow through the `VideoFrameSink` handed to the load verb.
pub const VideoEventKind = enum(u8) {
    loaded,
    position,
    completed,
    failed,
};

/// One report from the platform video player. Positions and durations
/// are in milliseconds; `playing`/`buffering` carry the audio event's
/// exact semantics (transport intent vs a stalled stream). `width` and
/// `height` are the STREAM's decoded pixel dimensions, reported on
/// `.loaded` (0 elsewhere) — the honest source geometry even when the
/// host downscales frames to fit the texture channel's pixel budget.
pub const VideoEvent = struct {
    kind: VideoEventKind,
    /// Which LOAD this event reports on: the engine mints a fresh
    /// token per `videoLoad`/`videoLoadUrl` and the host echoes it in
    /// every event that playback produces. The single player replaces
    /// in place, and an event emitted by the replaced playback can
    /// still be queued when the replacement lands — the token is how
    /// the engine swallows it instead of resetting (or misattributing
    /// events to) the playback that replaced it.
    token: u64 = 0,
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    playing: bool = false,
    buffering: bool = false,
    width: u64 = 0,
    height: u64 = 0,
};

/// Where a platform video decoder delivers frames: a type-erased,
/// copyable handle to one media-surface texture channel claim. The pair
/// `context`/`generation` addresses process-lifetime slot memory fenced
/// by a generation stamp (the media-surface thread contract), so the
/// host may call `push_fn` from ANY thread — a decode callback, a frame
/// timer — and a push after the claim was released lands in inert
/// memory and reports `error.MediaSurfaceReleased` instead of touching
/// freed state. `rgba8` is one tightly-packed straight-alpha RGBA8
/// frame, copied before the call returns. A zeroed sink (`push_fn`
/// null) is inert: hosts must tolerate it and simply decode nowhere.
pub const VideoFrameSink = struct {
    context: ?*anyopaque = null,
    generation: u64 = 0,
    push_fn: ?*const fn (context: ?*anyopaque, generation: u64, width: usize, height: usize, rgba8: []const u8) anyerror!void = null,

    /// Push one frame through the sink; inert sinks drop it silently.
    pub fn push(self: VideoFrameSink, width: usize, height: usize, rgba8: []const u8) anyerror!void {
        const push_fn = self.push_fn orelse return;
        return push_fn(self.context, self.generation, width, height, rgba8);
    }
};

pub const FileDropEvent = struct {
    window_id: WindowId = 1,
    view_label: []const u8 = "",
    point: ?geometry.PointF = null,
    paths: []const []const u8 = &.{},
};

pub const GpuFrame = struct {
    surface_id: ViewId = 0,
    window_id: WindowId = 1,
    label: []const u8 = "",
    size: geometry.SizeF = geometry.SizeF.init(0, 0),
    scale_factor: f32 = 1,
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    frame_interval_ns: u64 = default_gpu_frame_interval_ns,
    input_timestamp_ns: u64 = 0,
    input_latency_ns: u64 = 0,
    input_latency_budget_ns: u64 = default_gpu_frame_interval_ns,
    input_latency_budget_exceeded_count: usize = 0,
    input_latency_budget_ok: bool = true,
    first_frame_latency_ns: u64 = 0,
    first_frame_latency_budget_ns: u64 = default_gpu_first_frame_latency_budget_ns,
    first_frame_latency_budget_exceeded_count: usize = 0,
    first_frame_latency_budget_ok: bool = true,
    nonblank: bool = false,
    sample_color: u32 = 0,
    backend: GpuSurfaceBackend = .none,
    pixel_format: GpuSurfacePixelFormat = .none,
    present_mode: GpuSurfacePresentMode = .none,
    alpha_mode: GpuSurfaceAlphaMode = .none,
    color_space: GpuSurfaceColorSpace = .none,
    vsync: bool = false,
    status: GpuSurfaceStatus = .unavailable,
    canvas_revision: u64 = 0,
    canvas_command_count: usize = 0,
    canvas_frame_requires_render: bool = false,
    canvas_frame_full_repaint: bool = false,
    canvas_frame_batch_count: usize = 0,
    canvas_frame_encoder_command_count: usize = 0,
    canvas_frame_encoder_cache_action_count: usize = 0,
    canvas_frame_encoder_bind_pipeline_count: usize = 0,
    canvas_frame_encoder_draw_batch_count: usize = 0,
    canvas_frame_pipeline_count: usize = 0,
    canvas_frame_pipeline_upload_count: usize = 0,
    canvas_frame_pipeline_retain_count: usize = 0,
    canvas_frame_pipeline_evict_count: usize = 0,
    canvas_frame_path_geometry_count: usize = 0,
    canvas_frame_path_geometry_vertex_count: usize = 0,
    canvas_frame_path_geometry_index_count: usize = 0,
    canvas_frame_path_geometry_upload_count: usize = 0,
    canvas_frame_path_geometry_retain_count: usize = 0,
    canvas_frame_path_geometry_evict_count: usize = 0,
    canvas_frame_image_count: usize = 0,
    canvas_frame_image_upload_count: usize = 0,
    canvas_frame_image_retain_count: usize = 0,
    canvas_frame_image_evict_count: usize = 0,
    canvas_frame_layer_count: usize = 0,
    canvas_frame_layer_opacity_count: usize = 0,
    canvas_frame_layer_clip_count: usize = 0,
    canvas_frame_layer_transform_count: usize = 0,
    canvas_frame_layer_upload_count: usize = 0,
    canvas_frame_layer_retain_count: usize = 0,
    canvas_frame_layer_evict_count: usize = 0,
    canvas_frame_resource_count: usize = 0,
    canvas_frame_resource_upload_count: usize = 0,
    canvas_frame_resource_retain_count: usize = 0,
    canvas_frame_resource_evict_count: usize = 0,
    canvas_frame_visual_effect_count: usize = 0,
    canvas_frame_visual_effect_shadow_count: usize = 0,
    canvas_frame_visual_effect_blur_count: usize = 0,
    canvas_frame_visual_effect_upload_count: usize = 0,
    canvas_frame_visual_effect_retain_count: usize = 0,
    canvas_frame_visual_effect_evict_count: usize = 0,
    canvas_frame_glyph_atlas_entry_count: usize = 0,
    canvas_frame_glyph_atlas_upload_count: usize = 0,
    canvas_frame_glyph_atlas_retain_count: usize = 0,
    canvas_frame_glyph_atlas_evict_count: usize = 0,
    canvas_frame_text_layout_count: usize = 0,
    canvas_frame_text_layout_line_count: usize = 0,
    canvas_frame_text_layout_upload_count: usize = 0,
    canvas_frame_text_layout_retain_count: usize = 0,
    canvas_frame_text_layout_evict_count: usize = 0,
    canvas_frame_gpu_packet_command_count: usize = 0,
    canvas_frame_gpu_packet_cache_action_count: usize = 0,
    canvas_frame_gpu_packet_cached_resource_command_count: usize = 0,
    canvas_frame_gpu_packet_unsupported_command_count: usize = 0,
    canvas_frame_gpu_packet_representable: bool = true,
    canvas_frame_change_count: usize = 0,
    canvas_frame_budget_exceeded_count: usize = 0,
    canvas_frame_budget_ok: bool = true,
    canvas_frame_dirty_bounds: ?geometry.RectF = null,
    canvas_frame_profile_work_units: usize = 0,
    canvas_frame_profile_risk: CanvasFrameProfileRisk = .idle,
    canvas_frame_profile_surface_area: f32 = 0,
    canvas_frame_profile_dirty_area: f32 = 0,
    canvas_frame_profile_dirty_ratio: f32 = 0,
    widget_revision: u64 = 0,
    widget_node_count: usize = 0,
    widget_semantics_count: usize = 0,
};

pub const GpuSurfaceFrameEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    size: geometry.SizeF,
    scale_factor: f32 = 1,
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    frame_interval_ns: u64 = default_gpu_frame_interval_ns,
    input_timestamp_ns: u64 = 0,
    input_latency_ns: u64 = 0,
    input_latency_budget_ns: u64 = default_gpu_frame_interval_ns,
    input_latency_budget_exceeded_count: usize = 0,
    input_latency_budget_ok: bool = true,
    first_frame_latency_ns: u64 = 0,
    first_frame_latency_budget_ns: u64 = default_gpu_first_frame_latency_budget_ns,
    first_frame_latency_budget_exceeded_count: usize = 0,
    first_frame_latency_budget_ok: bool = true,
    nonblank: bool = false,
    sample_color: u32 = 0,
    /// Host-stamped durations of the most recent packet present's
    /// decode and draw (0 when no packet present happened since the
    /// last frame event) — recorded into the runtime's frame profile
    /// as the `host_decode`/`host_draw` stages while profiling is on.
    packet_decode_ns: u64 = 0,
    packet_draw_ns: u64 = 0,
    /// The host completed this frame LOGICALLY while the window was
    /// occluded: nothing reached the glass and the completion rides the
    /// host's deliberate occluded pacing (a slow heartbeat), so its
    /// timestamp keeps frame-channel consumers current but is never a
    /// valid endpoint for latency measurements.
    occluded: bool = false,
    backend: GpuSurfaceBackend = .metal,
    pixel_format: GpuSurfacePixelFormat = .bgra8_unorm,
    present_mode: GpuSurfacePresentMode = .timer,
    alpha_mode: GpuSurfaceAlphaMode = .@"opaque",
    color_space: GpuSurfaceColorSpace = .srgb,
    vsync: bool = true,
    status: GpuSurfaceStatus = .ready,
    canvas_revision: u64 = 0,
    canvas_command_count: usize = 0,
    canvas_frame_requires_render: bool = false,
    canvas_frame_full_repaint: bool = false,
    canvas_frame_batch_count: usize = 0,
    canvas_frame_encoder_command_count: usize = 0,
    canvas_frame_encoder_cache_action_count: usize = 0,
    canvas_frame_encoder_bind_pipeline_count: usize = 0,
    canvas_frame_encoder_draw_batch_count: usize = 0,
    canvas_frame_pipeline_count: usize = 0,
    canvas_frame_pipeline_upload_count: usize = 0,
    canvas_frame_pipeline_retain_count: usize = 0,
    canvas_frame_pipeline_evict_count: usize = 0,
    canvas_frame_path_geometry_count: usize = 0,
    canvas_frame_path_geometry_vertex_count: usize = 0,
    canvas_frame_path_geometry_index_count: usize = 0,
    canvas_frame_path_geometry_upload_count: usize = 0,
    canvas_frame_path_geometry_retain_count: usize = 0,
    canvas_frame_path_geometry_evict_count: usize = 0,
    canvas_frame_image_count: usize = 0,
    canvas_frame_image_upload_count: usize = 0,
    canvas_frame_image_retain_count: usize = 0,
    canvas_frame_image_evict_count: usize = 0,
    canvas_frame_layer_count: usize = 0,
    canvas_frame_layer_opacity_count: usize = 0,
    canvas_frame_layer_clip_count: usize = 0,
    canvas_frame_layer_transform_count: usize = 0,
    canvas_frame_layer_upload_count: usize = 0,
    canvas_frame_layer_retain_count: usize = 0,
    canvas_frame_layer_evict_count: usize = 0,
    canvas_frame_resource_count: usize = 0,
    canvas_frame_resource_upload_count: usize = 0,
    canvas_frame_resource_retain_count: usize = 0,
    canvas_frame_resource_evict_count: usize = 0,
    canvas_frame_visual_effect_count: usize = 0,
    canvas_frame_visual_effect_shadow_count: usize = 0,
    canvas_frame_visual_effect_blur_count: usize = 0,
    canvas_frame_visual_effect_upload_count: usize = 0,
    canvas_frame_visual_effect_retain_count: usize = 0,
    canvas_frame_visual_effect_evict_count: usize = 0,
    canvas_frame_glyph_atlas_entry_count: usize = 0,
    canvas_frame_glyph_atlas_upload_count: usize = 0,
    canvas_frame_glyph_atlas_retain_count: usize = 0,
    canvas_frame_glyph_atlas_evict_count: usize = 0,
    canvas_frame_text_layout_count: usize = 0,
    canvas_frame_text_layout_line_count: usize = 0,
    canvas_frame_text_layout_upload_count: usize = 0,
    canvas_frame_text_layout_retain_count: usize = 0,
    canvas_frame_text_layout_evict_count: usize = 0,
    canvas_frame_gpu_packet_command_count: usize = 0,
    canvas_frame_gpu_packet_cache_action_count: usize = 0,
    canvas_frame_gpu_packet_cached_resource_command_count: usize = 0,
    canvas_frame_gpu_packet_unsupported_command_count: usize = 0,
    canvas_frame_gpu_packet_representable: bool = true,
    canvas_frame_change_count: usize = 0,
    canvas_frame_budget_exceeded_count: usize = 0,
    canvas_frame_budget_ok: bool = true,
    canvas_frame_dirty_bounds: ?geometry.RectF = null,
    canvas_frame_profile_work_units: usize = 0,
    canvas_frame_profile_risk: CanvasFrameProfileRisk = .idle,
    canvas_frame_profile_surface_area: f32 = 0,
    canvas_frame_profile_dirty_area: f32 = 0,
    canvas_frame_profile_dirty_ratio: f32 = 0,
    widget_revision: u64 = 0,
    widget_node_count: usize = 0,
    widget_semantics_count: usize = 0,
};

pub const GpuSurfaceResizeEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    frame: geometry.RectF,
    scale_factor: f32 = 1,
};

pub const GpuSurfaceInputKind = enum {
    pointer_down,
    pointer_up,
    pointer_cancel,
    pointer_move,
    pointer_drag,
    scroll,
    key_down,
    key_up,
    text_input,
    ime_set_composition,
    ime_commit_composition,
    ime_cancel_composition,
    // Trackpad gestures are phase-explicit (every source models phases:
    // NSEvent.phase on macOS, GTK GestureZoom begin/scale-changed/end,
    // Windows precision-touchpad gesture messages), and the family stays
    // open for rotate/smart-zoom later. Only the macOS host emits these
    // today; Windows (precision touchpad) and Linux (GTK GestureZoom)
    // are staged follow-ups — on those platforms the kinds simply never
    // arrive.
    pinch_begin,
    pinch_change,
    pinch_end,
};

/// Reserved bit in `GpuSurfaceInputEvent.pointer_id`: a host that can
/// identify a TOUCH-sourced pointer event stamps it (a
/// `GDK_SOURCE_TOUCHSCREEN` device on GTK; a mouse message whose
/// `GetMessageExtraInfo` carries the touch `MI_WP_SIGNATURE` on
/// Windows, where the OS synthesizes mouse-shaped moves for taps), and
/// the runtime's hover-Msg containment then refuses to treat that
/// pointer as hover-capable — the mechanical backstop for the "touch
/// never synthesizes hover" contract even where the OS fakes a hover
/// move. Hosts that cannot identify the source leave ids unstamped;
/// unstamped ids keep today's behavior. The bit rides the EXISTING id
/// field, so journals and the input codec are unchanged.
pub const touch_pointer_id_bit: u64 = 1 << 63;

pub const GpuSurfaceInputEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    kind: GpuSurfaceInputKind,
    timestamp_ns: u64 = 0,
    /// Host pointer identity, when the host distinguishes pointers
    /// (per-sequence touch ids, `WM_POINTER` ids); 0 on single-pointer
    /// hosts. Touch-sourced events additionally carry
    /// `touch_pointer_id_bit`.
    pointer_id: u64 = 0,
    x: f32 = 0,
    y: f32 = 0,
    button: i32 = 0,
    pressure: f32 = 0,
    delta_x: f32 = 0,
    delta_y: f32 = 0,
    key: []const u8 = "",
    text: []const u8 = "",
    composition_cursor: ?usize = null,
    modifiers: ShortcutModifiers = .{},
    /// Pinch magnification DELTA for this event: nonzero only on
    /// `pinch_change`, 0 on begin/end. The delta is MULTIPLICATIVE: the
    /// cumulative gesture scale is the running product of `(1 + scale)`
    /// across the gesture's change events. On macOS this is AppKit's
    /// raw per-event `NSEvent.magnification`, forwarded untransformed —
    /// raw magnification IS the multiplicative per-event delta, the
    /// convention every browser engine ships (see the doctrine note at
    /// `magnifyWithEvent:` in appkit_host.m), so the product matches
    /// the zoom the same gesture performs in Safari and Chrome. The
    /// host guarantees `1 + scale > 0` on every event (a per-event
    /// floor clamps the physically impossible). The pointer anchor rides
    /// `x`/`y` (view-local, same space as pointer events) — the pointer
    /// location during the gesture, NOT a midpoint between the fingers:
    /// hosts report gesture events at the pointer (AppKit's
    /// `locationInWindow`), and zoom-at-cursor is the anchoring apps
    /// want.
    scale: f32 = 0,
};

/// Pinch gesture phase for the app-level pinch channel (`Options.on_pinch`
/// / the TS core's `pinchMsg` export). Every source is phase-explicit
/// (NSEvent phases, GTK GestureZoom, Windows precision-touchpad gestures);
/// a host-cancelled gesture folds into `.end` — pinch delivers incremental
/// deltas the app applies as they arrive, so there is no transient state
/// to roll back the way `pointer_cancel` rolls back an in-flight press.
/// A terminal host event (Ended or Cancelled) that still measured a
/// nonzero magnification delivers that delta as a final `.change` before
/// the `.end`, so the cumulative product always matches what the OS
/// reported.
pub const PinchPhase = enum {
    begin,
    change,
    end,
};

/// The pinch channel's app-facing record, derived from the raw
/// `gpu_surface_input` pinch events. Pinch bypasses the widget pipeline
/// deliberately: it is a view-global gesture (timeline/canvas zoom), the
/// `on_key`-fallback shape rather than a widget-targeted event.
pub const PinchEvent = struct {
    /// Source identity: which window and gpu-surface view the gesture
    /// happened on (the `GpuFrame` identity shape, because `x`/`y` are
    /// view-local — a coordinate without its view is not a position).
    /// Multi-window and multi-view apps tell pinches apart by these.
    /// `label` is borrowed for the callback, like every event slice:
    /// a model that keeps it must copy.
    window_id: WindowId = 1,
    label: []const u8 = "",
    phase: PinchPhase,
    /// Magnification DELTA for this event: nonzero only on `.change`,
    /// 0 on begin/end. The delta is MULTIPLICATIVE — the cumulative
    /// gesture scale is the running product of `(1 + scale)` across the
    /// gesture's change events; apply it memorylessly
    /// (`zoom *= 1 + scale`), no gesture-start bookkeeping. On macOS
    /// this is AppKit's raw per-event `NSEvent.magnification`, which IS
    /// that multiplicative delta per the browser-engine convention, so
    /// the product matches the zoom the same gesture performs in Safari
    /// and Chrome. Every event keeps `1 + scale > 0`.
    scale: f32 = 0,
    /// The pointer anchor, view-local canvas points (the pointer-event
    /// space): where the zoom should anchor. This is the POINTER
    /// location during the gesture (AppKit reports gesture events at
    /// `locationInWindow`), not a midpoint between the fingers — raw
    /// touch positions are trackpad-normalized and never reach view
    /// space, and zoom-at-cursor is what apps want anyway.
    x: f32 = 0,
    y: f32 = 0,
};

/// A wheel/trackpad scroll over a gpu surface, for the app-level wheel
/// channel (`on_wheel` — the pinch channel's sibling). Deltas are the
/// host's scroll units in view points, sign as the platform reports it
/// (natural scrolling on hosts that apply it); `x`/`y` locate the
/// pointer in view-local canvas points.
pub const WheelEvent = struct {
    window_id: WindowId = 1,
    label: []const u8 = "",
    delta_x: f32 = 0,
    delta_y: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    modifiers: ShortcutModifiers = .{},
};

/// Upper bound on native scroll drivers per gpu-surface view (one per
/// scrollable canvas region).
pub const max_gpu_surface_scroll_drivers: usize = 16;

/// Upper bound on scroll OCCLUDERS per gpu-surface view (floating
/// surfaces and modal catchers that hit-block regions beneath them).
pub const max_gpu_surface_scroll_occluders: usize = 8;

/// A surface that hit-blocks scroll regions beneath it: anchored
/// floating surfaces (popovers, dropdowns, tooltips) at their frames,
/// and modal surfaces (dialog/drawer/sheet input catchers) as the whole
/// view. The host must not route a wheel to a driver whose
/// `occluder_mask` includes an occluder containing the point — the
/// engine's hit test would give that point to the overlay's branch, so
/// the native fast path has to decline it the same way (the wheel then
/// rides the wire, where real hit-testing decides).
pub const GpuSurfaceScrollOccluder = struct {
    frame: geometry.RectF,
};

/// One native scroll driver's desired state, pushed by the runtime on
/// every widget-layout install and every presented frame (self-healing
/// against host-side relayouts). Coordinates are view-local canvas points
/// (top-left origin, y-down) — the host converts to its own convention.
pub const GpuSurfaceScrollDriver = struct {
    /// Stable identity: the scroll widget's structural id. Drivers are
    /// reconciled host-side by this id (create / update / remove).
    id: u64,
    /// The scroll region's layout frame, view-local.
    frame: geometry.RectF,
    /// Total scrollable content size for the region. The vertical max
    /// scroll offset is `content_size.height - frame.height`; the
    /// horizontal one is `content_size.width - frame.width` (a region
    /// that does not scroll horizontally reports `width ==
    /// frame.width`, so the horizontal max is 0 and the native
    /// scroller never travels sideways).
    content_size: geometry.SizeF,
    /// The runtime's current scroll offsets (canvas points, y-down,
    /// x-rightward).
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    /// True when the runtime changed that axis's offset from a
    /// non-driver source (keyboard scroll, programmatic scroll, rebuild
    /// clamp): the host must write that offset into the native
    /// scroller. False leaves the axis alone — the driver owns it. Per
    /// axis, so a programmatic vertical write can never push a stale
    /// horizontal offset over native motion whose coalesced report is
    /// still in flight (and vice versa).
    set_offset_x: bool = false,
    set_offset_y: bool = false,
    /// Edge behavior for this region's native scroller: false (the
    /// default) pins scrolling at the content edges, true lets the OS
    /// scroller bounce past them. Reconciled on every push like the
    /// frame and content size, and armed per axis through the grants
    /// below.
    rubber_band: bool = false,
    /// The nearest ANCESTOR driver's id (0 = none): the widget-tree
    /// containment chain, pushed so the host can restrict wheel-owner
    /// resolution to the hit region and its ancestors — geometric
    /// overlap alone would let an unrelated background region behind a
    /// floating surface steal an axis the engine's route would never
    /// give it.
    parent_id: u64 = 0,
    /// Which occluders (by bit index into the sync call's occluder
    /// array) hit-block THIS region: every pushed occluder that is not
    /// an ancestor of the region — a scroll region inside an open
    /// popover is not blocked by its own surface.
    occluder_mask: u32 = 0,
    /// Which axes the region GRANTS (`canvas.widgetScrollsAxis`): the
    /// host arms elasticity and scroller chrome only on granted axes.
    /// Distinct from having range right now — a granted axis with short
    /// content keeps its scroller parked but may still bounce, while an
    /// ungranted axis must never move, bounce, or grow a scroller.
    scrolls_x: bool = false,
    scrolls_y: bool = true,
};

/// A native scroll driver reported a new content offset (the user
/// scrolled through the OS scroller). Offsets are view-local canvas
/// points; rubber-band overscroll passes through as values below 0 or
/// beyond the max offset.
pub const GpuSurfaceScrollDriverEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    driver_id: u64,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    timestamp_ns: u64 = 0,
};

/// Upper bound on items in one native context menu.
pub const max_context_menu_items: usize = 32;

/// One native context-menu entry (the chrome-menu item shape, minus the
/// command string: selections come back by `id`).
pub const ContextMenuItem = struct {
    /// Non-zero selection id reported back in `ContextMenuActionEvent`.
    id: u32 = 0,
    label: []const u8 = "",
    enabled: bool = true,
    separator: bool = false,
};

/// A request to present a native context menu at a pointer location
/// (view-local canvas points, y-down). Presentation is asynchronous: the
/// platform shows the menu on its own loop turn and reports the selection
/// (or dismissal) as a `context_menu_action` event carrying `token`.
pub const ContextMenuRequest = struct {
    window_id: WindowId = 1,
    view_label: []const u8 = "",
    point: geometry.PointF = .{},
    /// Opaque correlation token echoed back on the action event (the
    /// runtime mints one per request, so a superseded menu's late
    /// dismissal can never resolve its successor's request).
    token: u64 = 0,
    items: []const ContextMenuItem = &.{},
};

/// The user selected a native context-menu item (or dismissed the menu:
/// `item_id` 0).
pub const ContextMenuActionEvent = struct {
    window_id: WindowId = 1,
    view_label: []const u8 = "",
    token: u64 = 0,
    item_id: u32 = 0,
};

pub const GpuSurfacePixels = struct {
    window_id: WindowId = 1,
    label: []const u8,
    width: usize,
    height: usize,
    scale_factor: f32 = 1,
    dirty_bounds: ?geometry.RectF = null,
    rgba8: []const u8,

    pub fn expectedByteLen(self: GpuSurfacePixels) ?usize {
        if (self.width == 0 or self.height == 0) return null;
        const pixels = std.math.mul(usize, self.width, self.height) catch return null;
        return std.math.mul(usize, pixels, 4) catch return null;
    }
};

/// One runtime-registered canvas image's pixels for the binary upload
/// side-channel (`upload_gpu_surface_image_fn`): tightly packed,
/// row-major, straight-alpha RGBA8, exactly `width * height * 4` bytes.
/// Uploads are keyed by `id` host-wide (not per view) — packets reference
/// images by id + content fingerprint only and never carry pixel
/// payloads, so registering an image can never push a frame over the
/// packet JSON bound.
pub const GpuSurfaceImagePixels = struct {
    id: u64,
    width: usize,
    height: usize,
    rgba8: []const u8,

    pub fn expectedByteLen(self: GpuSurfaceImagePixels) ?usize {
        if (self.id == 0 or self.width == 0 or self.height == 0) return null;
        const pixels = std.math.mul(usize, self.width, self.height) catch return null;
        return std.math.mul(usize, pixels, 4) catch return null;
    }
};

/// One runtime-registered font face for the gpu-surface font
/// side-channel (`register_gpu_surface_font_fn`): raw TrueType bytes
/// keyed by the canvas font id host-wide. The engine validates the bytes
/// (a parseable TrueType face under the registry bounds) before this
/// call, so hosts may treat a decode failure as a hard error rather than
/// a fallback. Ids are permanent per RUNTIME (one runtime never
/// re-registers an id with different bytes), but host font state is
/// per-process and runtimes are not: a later runtime may re-register an
/// id a still-live earlier runtime also holds, and the host resolves the
/// most recent registration (last wins).
pub const GpuSurfaceFontData = struct {
    id: u64,
    ttf: []const u8,
};

pub const GpuSurfacePacket = struct {
    window_id: WindowId = 1,
    label: []const u8,
    frame_index: u64 = 0,
    timestamp_ns: u64 = 0,
    surface_size: geometry.SizeF = .{},
    scale_factor: f32 = 1,
    clear_color_rgba8: [4]u8 = .{ 0, 0, 0, 255 },
    requires_render: bool = false,
    command_count: usize = 0,
    cache_action_count: usize = 0,
    cached_resource_command_count: usize = 0,
    unsupported_command_count: usize = 0,
    representable: bool = true,
    /// UTF-8 JSON packet payload (`present_gpu_surface_packet_fn`).
    /// Exactly one of `json`/`binary` is non-empty per present call.
    json: []const u8 = "",
    /// Compact binary packet payload
    /// (`present_gpu_surface_packet_binary_fn`): the length-prefixed
    /// little-endian encoding produced by
    /// `CanvasGpuPacket.writeBinary`, ~5-10x denser than the JSON
    /// encoding on text-heavy frames because field names, decimal
    /// formatting, and the host-unused glyph arrays never ride it.
    binary: []const u8 = "",
};

pub const WidgetAccessibilityRole = enum(c_int) {
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

pub const WidgetAccessibilityActions = struct {
    focus: bool = false,
    press: bool = false,
    toggle: bool = false,
    increment: bool = false,
    decrement: bool = false,
    set_text: bool = false,
    set_selection: bool = false,
    select: bool = false,
    drag: bool = false,
    drop_files: bool = false,
    dismiss: bool = false,
};

pub const WidgetAccessibilityTextRange = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const WidgetAccessibilityNode = struct {
    id: u64 = 0,
    parent_id: ?u64 = null,
    role: WidgetAccessibilityRole = .none,
    label: []const u8 = "",
    text_value: []const u8 = "",
    placeholder: []const u8 = "",
    text_selection: ?WidgetAccessibilityTextRange = null,
    text_composition: ?WidgetAccessibilityTextRange = null,
    value: ?f32 = null,
    bounds: geometry.RectF = .{},
    grid_row_index: ?usize = null,
    grid_column_index: ?usize = null,
    grid_row_count: ?usize = null,
    grid_column_count: ?usize = null,
    list_item_index: ?u32 = null,
    list_item_count: ?u32 = null,
    scroll_offset: ?f32 = null,
    scroll_viewport_extent: ?f32 = null,
    scroll_content_extent: ?f32 = null,
    enabled: bool = true,
    focused: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    selected: bool = false,
    expanded: ?bool = null,
    required: bool = false,
    read_only: bool = false,
    invalid: bool = false,
    focusable: bool = false,
    actions: WidgetAccessibilityActions = .{},
};

pub const WidgetAccessibilitySnapshot = struct {
    window_id: WindowId = 1,
    view_label: []const u8,
    nodes: []const WidgetAccessibilityNode = &.{},
};

pub const WidgetAccessibilityActionKind = enum(c_int) {
    focus = 0,
    press = 1,
    toggle = 2,
    increment = 3,
    decrement = 4,
    set_text = 5,
    set_selection = 6,
    select = 7,
    drag = 8,
    drop_files = 9,
    dismiss = 10,
    // The composition verbs never arrive from desktop assistive-tech
    // bridges (AppKit has no AX composition action); they exist so the
    // DIRECT verb surfaces (embed hosts, automation commands) and the
    // session journal can carry every accessibility verb as one
    // `widget_accessibility_action` — replay re-runs the verb, focus
    // included, instead of replaying its untargeted ime children.
    set_composition = 11,
    commit_composition = 12,
    cancel_composition = 13,
};

pub const WidgetAccessibilityActionEvent = struct {
    window_id: WindowId = 1,
    label: []const u8,
    id: u64,
    action: WidgetAccessibilityActionKind,
    text: []const u8 = "",
    selection: ?WidgetAccessibilityTextRange = null,
};

pub const ClipboardData = struct {
    mime_type: []const u8 = "text/plain",
    bytes: []const u8,
};

pub const ColorScheme = enum {
    light,
    dark,
};

pub const Appearance = struct {
    color_scheme: ColorScheme = .light,
    reduce_motion: bool = false,
    high_contrast: bool = false,
};

pub const Event = union(enum) {
    app_start,
    app_activated,
    app_deactivated,
    appearance_changed: Appearance,
    frame_requested,
    app_shutdown,
    surface_resized: Surface,
    window_frame_changed: WindowState,
    window_focused: WindowId,
    bridge_message: BridgeMessage,
    tray_action: TrayItemId,
    shortcut: ShortcutEvent,
    native_command: NativeCommandEvent,
    menu_command: MenuCommandEvent,
    timer: TimerEvent,
    /// A cross-thread nudge posted through `PlatformServices.wake_fn`:
    /// worker threads (effect executors) ask the platform loop to deliver
    /// this on its own thread so the runtime can drain completion queues
    /// without ever touching app state off-thread.
    wake,
    files_dropped: FileDropEvent,
    gpu_surface_frame: GpuSurfaceFrameEvent,
    gpu_surface_resized: GpuSurfaceResizeEvent,
    gpu_surface_input: GpuSurfaceInputEvent,
    gpu_surface_scroll_driver: GpuSurfaceScrollDriverEvent,
    context_menu_action: ContextMenuActionEvent,
    widget_accessibility_action: WidgetAccessibilityActionEvent,
    /// Audio player reports: load acknowledgment, coarse position ticks
    /// while playing, one completion at natural end, async failures.
    audio: AudioEvent,
    /// Video player reports — the same shape, plus the stream's decoded
    /// dimensions on `.loaded`. Pixels never ride here.
    video: VideoEvent,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .app_start => "app_start",
            .app_activated => "app_activated",
            .app_deactivated => "app_deactivated",
            .appearance_changed => "appearance_changed",
            .frame_requested => "frame_requested",
            .app_shutdown => "app_shutdown",
            .surface_resized => "surface_resized",
            .window_frame_changed => "window_frame_changed",
            .window_focused => "window_focused",
            .bridge_message => "bridge_message",
            .tray_action => "tray_action",
            .shortcut => "shortcut",
            .native_command => "native_command",
            .menu_command => "menu_command",
            .timer => "timer",
            .wake => "wake",
            .files_dropped => "files_dropped",
            .gpu_surface_frame => "gpu_surface_frame",
            .gpu_surface_resized => "gpu_surface_resized",
            .gpu_surface_input => "gpu_surface_input",
            .gpu_surface_scroll_driver => "gpu_surface_scroll_driver",
            .context_menu_action => "context_menu_action",
            .widget_accessibility_action => "widget_accessibility_action",
            .audio => "audio",
            .video => "video",
        };
    }
};

pub fn splitDropPaths(bytes: []const u8, output: [][]const u8) []const []const u8 {
    var count: usize = 0;
    var start: usize = 0;
    for (bytes, 0..) |ch, index| {
        if (ch != 0) continue;
        if (index > start and count < output.len) {
            output[count] = bytes[start..index];
            count += 1;
        }
        start = index + 1;
    }
    if (start < bytes.len and count < output.len) {
        output[count] = bytes[start..];
        count += 1;
    }
    return output[0..count];
}

pub const EventHandler = *const fn (context: *anyopaque, event: Event) anyerror!void;

pub const PlatformServices = struct {
    context: ?*anyopaque = null,
    read_clipboard_fn: ?*const fn (context: ?*anyopaque, buffer: []u8) anyerror![]const u8 = null,
    write_clipboard_fn: ?*const fn (context: ?*anyopaque, text: []const u8) anyerror!void = null,
    read_clipboard_data_fn: ?*const fn (context: ?*anyopaque, mime_type: []const u8, buffer: []u8) anyerror![]const u8 = null,
    write_clipboard_data_fn: ?*const fn (context: ?*anyopaque, data: ClipboardData) anyerror!void = null,
    load_webview_fn: ?*const fn (context: ?*anyopaque, source: WebViewSource) anyerror!void = null,
    load_window_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, source: WebViewSource) anyerror!void = null,
    complete_bridge_fn: ?*const fn (context: ?*anyopaque, response: []const u8) anyerror!void = null,
    complete_window_bridge_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, response: []const u8) anyerror!void = null,
    complete_webview_bridge_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, webview_label: []const u8, response: []const u8) anyerror!void = null,
    create_window_fn: ?*const fn (context: ?*anyopaque, options: WindowOptions) anyerror!WindowInfo = null,
    focus_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    close_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    /// The real OS minimize verb (macOS miniaturize-to-Dock, Windows
    /// `SW_MINIMIZE`, GTK `gtk_window_minimize`), for app-drawn window
    /// controls — chromeless windows have no system button to click.
    /// Platforms without the concept leave this null.
    minimize_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    /// The real OS show verb: unhide + activate (macOS deminiaturize +
    /// makeKeyAndOrderFront + activate, Windows SW_RESTORE/SW_SHOW +
    /// foreground, GTK `gtk_window_present`) — the counterpart to a
    /// `close_policy = .hide` hide, and the tray "Open" consequence.
    /// Platforms without the concept leave this null.
    show_window_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    /// The graceful app quit: terminate through the SAME shutdown path
    /// a last-window close takes — but the host QUEUES the emit, so
    /// `app_shutdown` dispatches on its NEXT loop turn, only after the
    /// dispatch that requested the quit has returned. Never emit
    /// synchronously from inside this call: the request arrives mid
    /// dispatch (the command whose update returned it is still on the
    /// recorder's staged-event stack), and a nested emit seals the
    /// session journal before the requesting command commits — the
    /// record is lost and replay diverges. Before the run loop starts
    /// (a quit from App.start's update, or from a boot command in the
    /// synchronous first canvas frame) the host parks the request and
    /// drains it at top level after the current callback returns.
    /// Either way `app.stop` runs exactly once, and the shutdown is
    /// journaled like any platform event. The null platform's
    /// `quit_pending`/`takeQueuedQuit` seam is the reference model of
    /// the queued shape. Platforms without the concept leave this
    /// null.
    quit_app_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    /// Hand the ACTIVE pointer-down to the platform as a window-drag
    /// gesture (the hidden-titlebar drag-region channel): the window
    /// moves once the pointer actually moves — a plain click moves
    /// nothing — and the platform applies its own double-click titlebar
    /// convention (macOS: zoom, honoring the user's titlebar
    /// double-click preference). Must be called during dispatch of the
    /// pointer-down that starts the gesture. Platforms without the
    /// concept leave this null; the runtime then treats the press as
    /// dead space (GTK/Win32 scoped out like window resizability).
    start_window_drag_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) anyerror!void = null,
    /// Window-chrome overlay geometry: the bands where OS window
    /// controls overlay the CONTENT of a `hidden_inset`/
    /// `hidden_inset_tall` window plus the control cluster's own frame
    /// (macOS: titlebar band height on top, traffic lights on the
    /// leading edge and their live button frames — all zero in
    /// fullscreen, where the system hides them). Standard-titlebar
    /// windows and platforms without the concept report the zero
    /// `WindowChrome`; the null default is the same honest zero.
    window_chrome_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId) WindowChrome = null,
    /// Replace the platform's mirror of a canvas view's window-drag
    /// regions (see `WindowDragRegion`). Called by the runtime after
    /// every layout install whose regions changed; an empty slice
    /// clears the mirror. Platforms that resolve drags from the live
    /// pointer gesture (macOS) leave this null.
    set_window_drag_regions_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, regions: []const WindowDragRegion) anyerror!void = null,
    create_view_fn: ?*const fn (context: ?*anyopaque, options: ViewOptions) anyerror!void = null,
    update_view_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, patch: ViewPatch) anyerror!void = null,
    set_view_frame_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void = null,
    set_view_visible_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, visible: bool) anyerror!void = null,
    set_view_cursor_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, cursor: Cursor) anyerror!void = null,
    focus_view_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    close_view_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    adopt_view_surface_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, surface_handle: *anyopaque) anyerror!void = null,
    release_view_surface_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    create_webview_fn: ?*const fn (context: ?*anyopaque, options: WebViewOptions) anyerror!void = null,
    set_webview_frame_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void = null,
    navigate_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, url: []const u8) anyerror!void = null,
    set_webview_zoom_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, zoom: f64) anyerror!void = null,
    set_webview_layer_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, layer: i32) anyerror!void = null,
    close_webview_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    show_open_dialog_fn: ?*const fn (context: ?*anyopaque, options: OpenDialogOptions, buffer: []u8) anyerror!OpenDialogResult = null,
    show_save_dialog_fn: ?*const fn (context: ?*anyopaque, options: SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 = null,
    show_message_dialog_fn: ?*const fn (context: ?*anyopaque, options: MessageDialogOptions) anyerror!MessageDialogResult = null,
    show_notification_fn: ?*const fn (context: ?*anyopaque, options: NotificationOptions) anyerror!void = null,
    set_credential_fn: ?*const fn (context: ?*anyopaque, credential: Credential) anyerror!void = null,
    get_credential_fn: ?*const fn (context: ?*anyopaque, key: CredentialKey, buffer: []u8) anyerror![]const u8 = null,
    delete_credential_fn: ?*const fn (context: ?*anyopaque, key: CredentialKey) anyerror!void = null,
    open_external_url_fn: ?*const fn (context: ?*anyopaque, url: []const u8) anyerror!void = null,
    reveal_path_fn: ?*const fn (context: ?*anyopaque, path: []const u8) anyerror!void = null,
    add_recent_document_fn: ?*const fn (context: ?*anyopaque, path: []const u8) anyerror!void = null,
    clear_recent_documents_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    create_tray_fn: ?*const fn (context: ?*anyopaque, options: TrayOptions) anyerror!void = null,
    update_tray_menu_fn: ?*const fn (context: ?*anyopaque, items: []const TrayMenuItem) anyerror!void = null,
    update_tray_title_fn: ?*const fn (context: ?*anyopaque, title: []const u8) anyerror!void = null,
    remove_tray_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    configure_security_policy_fn: ?*const fn (context: ?*anyopaque, policy: security.Policy) anyerror!void = null,
    configure_menus_fn: ?*const fn (context: ?*anyopaque, menus: []const Menu) anyerror!void = null,
    configure_shortcuts_fn: ?*const fn (context: ?*anyopaque, shortcuts: []const Shortcut) anyerror!void = null,
    emit_window_event_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void = null,
    request_gpu_surface_frame_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    /// Input was dispatched to the surface: hosts that throttle occluded
    /// frame completions to a heartbeat must let the input's responding
    /// frame fire at full promptness (one-shot). Optional — hosts without
    /// occluded pacing simply omit it.
    note_gpu_surface_input_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8) anyerror!void = null,
    start_timer_fn: ?*const fn (context: ?*anyopaque, id: u64, interval_ns: u64, repeats: bool) anyerror!void = null,
    cancel_timer_fn: ?*const fn (context: ?*anyopaque, id: u64) anyerror!void = null,
    /// Load a local audio file into THE app's single audio player,
    /// replacing whatever was loaded before, paused at position zero. A
    /// successful load is acknowledged asynchronously with one
    /// `.audio`/`.loaded` event carrying the real decoded duration; an
    /// unreadable path fails synchronously (`error.AudioSourceNotFound` /
    /// `error.AudioDecodeFailed`). One player is the whole surface — a
    /// music app plays one track at a time, and pretending otherwise
    /// would be mixer design this layer has not earned. Loop-thread only,
    /// like every audio entry below.
    audio_load_fn: ?*const fn (context: ?*anyopaque, path: []const u8) anyerror!void = null,
    /// Load a URL audio source into the same single player. The platform
    /// resolves it honestly in two steps: a verified cache entry at
    /// `cache_path` (present AND `expected_bytes` matches when non-zero —
    /// a partial or stale entry never plays; it is discarded and
    /// re-streamed) answers `.cache` and plays as a plain local file;
    /// otherwise playback STREAMS progressively from the network —
    /// starting as soon as enough bytes arrive, never download-then-play
    /// — while the same bytes download into `cache_path` (written beside
    /// it and atomically renamed into place only after the size verifies)
    /// and the call answers `.stream`. An empty `cache_path` disables
    /// caching (stream only). The `.loaded` acknowledgment, `buffering`
    /// flags on position ticks, completion, and mid-stream network
    /// failures (`.failed`) all arrive as ordinary `.audio` events.
    audio_load_url_fn: ?*const fn (context: ?*anyopaque, url: []const u8, cache_path: []const u8, expected_bytes: u64) anyerror!AudioLoadResolution = null,
    /// Start or resume the loaded player. While playing the platform
    /// emits `.audio`/`.position` events at a coarse honest cadence
    /// (about every 500ms — position is a readout, not a frame clock)
    /// and one `.audio`/`.completed` when the track ends naturally.
    audio_play_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    /// Pause in place; position holds and ticks stop. No event echoes —
    /// the caller commanded it, so the caller already knows.
    audio_pause_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    /// Stop and unload the player entirely; a new `audio_load_fn` call is
    /// required before anything can play again.
    audio_stop_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    /// Jump the loaded player to `position_ms` (clamped to the duration).
    /// Works while playing or paused.
    audio_seek_fn: ?*const fn (context: ?*anyopaque, position_ms: u64) anyerror!void = null,
    /// Set the player volume, `0.0` (silent) through `1.0` (full).
    audio_set_volume_fn: ?*const fn (context: ?*anyopaque, volume: f32) anyerror!void = null,
    /// Load a local video file into THE app's single video player,
    /// leaving it PAUSED at position zero (transport is a separate
    /// verb, exactly like audio). Loading replaces whatever was loaded
    /// before. Success is asynchronous: a `.video`/`.loaded` event
    /// carries the stream's decoded dimensions and the player's
    /// duration estimate; an unreadable path fails synchronously
    /// (`error.VideoSourceNotFound` / `error.VideoDecodeFailed`).
    /// Decoded frames flow through `sink` from whatever thread the
    /// host's decode path runs on — the core never sees pixels. One
    /// player is the whole surface, like the audio channel it mirrors.
    video_load_fn: ?*const fn (context: ?*anyopaque, path: []const u8, token: u64, sink: VideoFrameSink) anyerror!void = null,
    /// Load an http(s) video source into the same single player,
    /// streaming progressively (playable before the download finishes;
    /// `buffering` flags on position ticks report stalls honestly).
    /// Same acknowledgment, sink, and replace semantics as
    /// `video_load_fn`.
    video_load_url_fn: ?*const fn (context: ?*anyopaque, url: []const u8, token: u64, sink: VideoFrameSink) anyerror!void = null,
    /// Start or resume the loaded player. While playing the platform
    /// emits `.video`/`.position` events at the audio tier's coarse
    /// honest cadence (about every 500ms — a readout, never the frame
    /// clock; frames pace themselves through the sink) and one
    /// `.video`/`.completed` when a non-looping video ends naturally.
    video_play_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    /// Pause in place; position holds, ticks and frame pushes stop, and
    /// the surface keeps its last adopted frame. No event echoes.
    video_pause_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    /// Stop and unload the player entirely; a new load is required
    /// before anything can play again.
    video_stop_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    /// Jump the loaded player to `position_ms` (clamped to the
    /// duration). Works while playing or paused; a paused seek still
    /// pushes the sought frame so scrubbing is visible.
    video_seek_fn: ?*const fn (context: ?*anyopaque, position_ms: u64) anyerror!void = null,
    /// Set the player volume, `0.0` (silent) through `1.0` (full) —
    /// independent of mute, which is a separate reversible switch.
    video_set_volume_fn: ?*const fn (context: ?*anyopaque, volume: f32) anyerror!void = null,
    /// Mute or unmute the player's audio track without touching the
    /// volume setting (the transport keeps playing either way).
    video_set_muted_fn: ?*const fn (context: ?*anyopaque, muted: bool) anyerror!void = null,
    /// Enable or disable looping: a looping player wraps from the
    /// natural end back to zero and keeps playing — no `.completed`
    /// event, because the playback never ends.
    video_set_loop_fn: ?*const fn (context: ?*anyopaque, loop: bool) anyerror!void = null,
    /// Nudge the platform event loop from ANY thread: the platform must
    /// deliver a `.wake` event on its loop thread as soon as possible.
    /// One of exactly two `PlatformServices` entries that may be called
    /// off-thread (the other is `request_frame_fn`); every implementation
    /// must be thread-safe (macOS: main-queue dispatch, GTK: `g_idle_add`,
    /// Win32: `PostMessage`, null platform: an atomic counter tests drain
    /// explicitly).
    ///
    /// CONTRACT — bounded, non-blocking, enqueue-only. The
    /// implementation must schedule the `.wake` delivery and return: it
    /// must never synchronously wait on the loop thread (a
    /// dispatch_sync-style marshal, a Win32 `SendMessage`) or on the
    /// posting thread. The first-party implementations are the model —
    /// macOS `dispatch_async` onto the main queue, GTK `g_idle_add`,
    /// Win32 `PostMessageW`, the null platform's atomic counter — the
    /// exact enqueue-only shape `request_frame_fn` documents for the
    /// media-surface producer wake, so the call stays bounded and never
    /// blocks on I/O. This contract is what the runtime's channel
    /// posting guarantee is conditioned on: `ChannelHandle.post` never
    /// blocks GIVEN a conforming wake, and because the runtime holds no
    /// channel lock across the call, a violating implementation hangs
    /// only its own posting thread — it can never entangle the
    /// runtime's lock graph. A violator still inside the call when the
    /// runtime tears down is ABANDONED after a bounded quiesce; see
    /// `note_channel_wake_abandoned_fn` for the consequence the
    /// platform must then honor.
    wake_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    /// Teardown consequence of an abandoned wake call. The runtime's
    /// effects teardown waits (bounded) for posts still inside
    /// `wake_fn`; a call that outlives the deadline — only possible
    /// when the wake violates its enqueue-only contract above — is
    /// abandoned, and it still holds `context` and may execute into the
    /// platform at ANY later time. The runtime reports that abandon
    /// here, synchronously, while the platform is still alive — and
    /// keeps its own half of the bargain: the `PlatformServices` VALUE
    /// the stale call reads on resume is a process-lived snapshot the
    /// runtime published at bind, never runtime-owned storage (see
    /// `Effects.bindServices`). A platform receiving this call must
    /// latch it, and its destruction path must consult the latch:
    /// destruction is SKIPPED and the platform deliberately leaked,
    /// process-lived, so the stale call can never execute into freed
    /// host state (the abandoned-worker idiom the effect workers
    /// already follow). The leak must cover EVERYTHING `context`
    /// transitively reaches — for the first-party desktop platforms
    /// that is the wrapper struct itself plus the native host behind
    /// it, which is why runners heap-allocate the wrapper
    /// (`createWithOptions`) and gate its free on the latch
    /// (`destroy`), never leaving it on a stack frame that unwinds at
    /// runner return. Every first-party platform wires this seam and
    /// gates both `deinit` and its storage on the latch; embedders
    /// providing their own `Platform` must do the same — or guarantee
    /// a conforming `wake_fn`, under which the teardown deadline is
    /// never met and this is never called. Loop-thread, teardown-only,
    /// unlike `wake_fn` itself.
    note_channel_wake_abandoned_fn: ?*const fn (context: ?*anyopaque) void = null,
    /// Ask the platform loop, from ANY thread, to deliver ONE
    /// `frame_requested` event on its loop thread soon — the same event a
    /// resize or an input-driven frame produces, so everything that rides
    /// the frame boundary (the automation command drain, the snapshot
    /// republish, session recording) sees an ordinary frame. Requests
    /// coalesce: asking while one is already queued or a frame tick is
    /// already armed is a no-op. This is the automation arrival watcher's
    /// wake path, and like `wake_fn` every implementation must be
    /// thread-safe (macOS: main-queue dispatch, GTK: `g_idle_add`, Win32:
    /// `PostMessage`, null platform: an atomic counter the scripted run
    /// loop reads).
    request_frame_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    present_gpu_surface_pixels_fn: ?*const fn (context: ?*anyopaque, pixels: GpuSurfacePixels) anyerror!void = null,
    present_gpu_surface_packet_fn: ?*const fn (context: ?*anyopaque, packet: GpuSurfacePacket) anyerror!void = null,
    /// Compact binary variant of the packet presenter: same packet
    /// metadata, payload in `packet.binary` instead of `packet.json`.
    /// This fn's presence is the capability flag — the runtime prefers
    /// it when wired and drops to the JSON presenter when the call
    /// itself answers `error.UnsupportedService`, so negotiation is a
    /// per-present conversation and the JSON path survives for
    /// compatibility and wire-level debugging.
    present_gpu_surface_packet_binary_fn: ?*const fn (context: ?*anyopaque, packet: GpuSurfacePacket) anyerror!void = null,
    /// Binary side-channel for gpu-surface image pixels: create or
    /// replace the host texture for `image.id` out-of-band, so packets
    /// carry only id + fingerprint references. Host-wide (not per view);
    /// re-uploading an id replaces its texture. Null on platforms without
    /// a packet renderer (GTK/Win32/null default) — the software pixel
    /// path reads registered images from the frame plan instead.
    upload_gpu_surface_image_fn: ?*const fn (context: ?*anyopaque, image: GpuSurfaceImagePixels) anyerror!void = null,
    /// Drop the host texture for a previously uploaded image id (the
    /// unregister path). Removing an unknown id is a no-op, not an error.
    remove_gpu_surface_image_fn: ?*const fn (context: ?*anyopaque, id: u64) anyerror!void = null,
    /// Register a runtime-registered font face with the host so the
    /// host-side text pipeline (measurement AND packet text drawing)
    /// resolves the font id to this exact face. Required on platforms
    /// that provide `measure_text_fn` — a host that measures and draws
    /// with its own font resolution but cannot learn a registered face
    /// would silently substitute the default family, so the runtime
    /// fails font registration loudly there instead. Null on platforms
    /// without host-side text (GTK/Win32/null default), where the engine
    /// measures with the parsed face and inks it through the reference
    /// renderer.
    ///
    /// Returns the host's ownership token for THIS registration of the
    /// id. Host font state is per-process while ids are only permanent
    /// per-runtime, so two live runtimes can register the same id (last
    /// wins); the token names which registration a later unregister may
    /// remove — the runtime stores it beside the captured unregister
    /// owner and passes it back at teardown. Platforms that retain no
    /// per-id host state (a stateless accept) return 0: there was
    /// nothing installed, so there is nothing a token could own, and an
    /// unregister carrying 0 removes nothing.
    register_gpu_surface_font_fn: ?*const fn (context: ?*anyopaque, font: GpuSurfaceFontData) anyerror!u64 = null,
    /// Teardown twin of the registration seam above: return whatever
    /// per-id state the host retained for a registered face (descriptor
    /// tables, size/measurement caches) when the runtime that registered
    /// the id deinits. Fonts are per-runtime but host font state is
    /// per-process, so without this seam an embedder cycling runtimes
    /// with fresh ids grows host state for the process lifetime.
    /// `token` is the ownership token the matching register call
    /// returned: the host removes the id's state ONLY while the id's
    /// current registration still carries that token, so an older
    /// runtime's deinit can never tear down a newer runtime's live face
    /// under a shared id. A stale token (the id was re-registered since)
    /// is a no-op accept — the registration it owned is already gone,
    /// which is exactly the state its owner asked for. Unregistering an
    /// id the host never saw is likewise a no-op, not an error. Null on
    /// platforms whose register seam is itself null (GTK/Win32 default)
    /// — with no host font state there is nothing to return.
    unregister_gpu_surface_font_fn: ?*const fn (context: ?*anyopaque, id: u64, token: u64) anyerror!void = null,
    update_widget_accessibility_fn: ?*const fn (context: ?*anyopaque, snapshot: WidgetAccessibilitySnapshot) anyerror!void = null,
    /// Reconcile the native scroll drivers for a gpu-surface view against
    /// the full desired set: create missing drivers, update frames /
    /// content extents / (per set-offset flag) offsets, remove drivers whose
    /// id is absent. Idempotent — the runtime calls this on every layout
    /// install and every presented frame. Null on platforms without
    /// native scroll drivers (GTK / Win32 / null default), which keeps
    /// scrolling on the engine's wheel physics.
    set_gpu_surface_scroll_drivers_fn: ?*const fn (context: ?*anyopaque, window_id: WindowId, label: []const u8, drivers: []const GpuSurfaceScrollDriver, occluders: []const GpuSurfaceScrollOccluder) anyerror!void = null,
    /// Present a native context menu at the request's pointer location.
    /// Asynchronous: the selection (or dismissal) arrives later as a
    /// `context_menu_action` event echoing `request.token`. Null on
    /// platforms without native menus.
    show_context_menu_fn: ?*const fn (context: ?*anyopaque, request: ContextMenuRequest) anyerror!void = null,
    /// Single-line text measurement matching the fonts the platform draws
    /// with: returns the typographic width of `text` at `size` for
    /// `font_id` (the canvas font id namespace). Null on platforms without
    /// real font metrics (the null platform), which keeps layout on the
    /// deterministic estimator.
    measure_text_fn: ?*const fn (context: ?*anyopaque, font_id: u64, size: f32, text: []const u8) f32 = null,
    /// Batched single-line text measurement: fill `advances` (per byte,
    /// `text.len` entries) with per-cluster typographic advances for the
    /// same font resolution `measure_text_fn` measures with — the advance
    /// of the UTF-8 cluster starting at byte `i` at index `i`, exactly 0
    /// at continuation bytes — and return true. Return false when the
    /// host cannot answer (invalid UTF-8, unresolvable font); the engine
    /// then keeps its per-prefix measurement path for that run. This is
    /// the O(L) seam line breaking batches through: one host call per
    /// text run instead of one `measure_text_fn` round-trip per cluster
    /// of every growing line prefix. Null on platforms without host-side
    /// text metrics (GTK / Win32 / the null platform), whose layout
    /// already runs on the engine's deterministic estimator or the
    /// engine-side registered-face provider — both batch engine-side
    /// without any platform seam.
    measure_text_advances_fn: ?*const fn (context: ?*anyopaque, font_id: u64, size: f32, text: []const u8, advances: []f32) bool = null,
    /// Decode encoded image bytes (PNG, JPEG, ... — whatever the platform
    /// codec supports) into tightly packed, row-major, straight-alpha
    /// (non-premultiplied) RGBA8 written into `buffer`, returning the
    /// dimensions plus the pixel slice (a prefix of `buffer`). The
    /// framework bundles no image decoders: macOS decodes through
    /// CGImageSource (ImageIO), GTK through gdk-pixbuf, Win32 through WIC.
    /// Implementations may use `buffer` as decode scratch, so callers size
    /// it for their pixel bound, not the exact image. Errors:
    /// `error.ImageDecodeFailed` for undecodable bytes,
    /// `error.ImageTooLarge` when the decoded pixels do not fit `buffer`.
    /// Null on platforms without a codec (the null platform by default),
    /// which surfaces as `error.UnsupportedService`.
    decode_image_fn: ?*const fn (context: ?*anyopaque, bytes: []const u8, buffer: []u8) anyerror!DecodedImage = null,

    pub fn readClipboard(self: PlatformServices, buffer: []u8) anyerror![]const u8 {
        const read_fn = self.read_clipboard_fn orelse return error.UnsupportedService;
        return read_fn(self.context, buffer);
    }

    pub fn writeClipboard(self: PlatformServices, text: []const u8) anyerror!void {
        const write_fn = self.write_clipboard_fn orelse return error.UnsupportedService;
        return write_fn(self.context, text);
    }

    pub fn readClipboardData(self: PlatformServices, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
        if (self.read_clipboard_data_fn) |read_fn| return read_fn(self.context, mime_type, buffer);
        if (isPlainTextMime(mime_type)) return self.readClipboard(buffer);
        return error.UnsupportedService;
    }

    pub fn writeClipboardData(self: PlatformServices, data: ClipboardData) anyerror!void {
        if (self.write_clipboard_data_fn) |write_fn| return write_fn(self.context, data);
        if (isPlainTextMime(data.mime_type)) return self.writeClipboard(data.bytes);
        return error.UnsupportedService;
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

    pub fn completeWebViewBridge(self: PlatformServices, window_id: WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
        if (self.complete_webview_bridge_fn) |complete_fn| return complete_fn(self.context, window_id, webview_label, response);
        if (!std.mem.eql(u8, webview_label, "main")) return error.UnsupportedService;
        return self.completeWindowBridge(window_id, response);
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

    pub fn minimizeWindow(self: PlatformServices, window_id: WindowId) anyerror!void {
        const minimize_fn = self.minimize_window_fn orelse return error.UnsupportedService;
        return minimize_fn(self.context, window_id);
    }

    pub fn showWindow(self: PlatformServices, window_id: WindowId) anyerror!void {
        const show_fn = self.show_window_fn orelse return error.UnsupportedService;
        return show_fn(self.context, window_id);
    }

    pub fn quitApp(self: PlatformServices) anyerror!void {
        const quit_fn = self.quit_app_fn orelse return error.UnsupportedService;
        return quit_fn(self.context);
    }

    pub fn startWindowDrag(self: PlatformServices, window_id: WindowId) anyerror!void {
        const drag_fn = self.start_window_drag_fn orelse return error.UnsupportedService;
        return drag_fn(self.context, window_id);
    }

    /// Zero when the platform has no window-chrome-overlay concept —
    /// the honest cross-platform default (a header padding by these
    /// insets pads nothing on GTK/Win32/null).
    pub fn windowChrome(self: PlatformServices, window_id: WindowId) WindowChrome {
        const chrome_fn = self.window_chrome_fn orelse return .{};
        return chrome_fn(self.context, window_id);
    }

    /// No-op on platforms without the mirror (macOS/null default):
    /// their drag path starts from the live pointer gesture instead,
    /// so there is nothing to keep in sync.
    pub fn setWindowDragRegions(self: PlatformServices, window_id: WindowId, label: []const u8, regions: []const WindowDragRegion) anyerror!void {
        const set_fn = self.set_window_drag_regions_fn orelse return;
        return set_fn(self.context, window_id, label, regions);
    }

    pub fn createView(self: PlatformServices, options: ViewOptions) anyerror!void {
        if (self.create_view_fn) |create_fn| return create_fn(self.context, options);
        if (options.kind == .webview) return self.createWebView(options.webViewOptions());
        return error.UnsupportedViewKind;
    }

    pub fn updateView(self: PlatformServices, window_id: WindowId, label: []const u8, patch: ViewPatch) anyerror!void {
        const update_fn = self.update_view_fn orelse return error.UnsupportedViewKind;
        return update_fn(self.context, window_id, label, patch);
    }

    pub fn setViewFrame(self: PlatformServices, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
        if (self.set_view_frame_fn) |set_fn| return set_fn(self.context, window_id, label, frame);
        if (std.mem.eql(u8, label, "main")) return self.setWebViewFrame(window_id, label, frame);
        return error.UnsupportedViewKind;
    }

    pub fn setViewVisible(self: PlatformServices, window_id: WindowId, label: []const u8, visible: bool) anyerror!void {
        const set_fn = self.set_view_visible_fn orelse return error.UnsupportedViewKind;
        return set_fn(self.context, window_id, label, visible);
    }

    pub fn setViewCursor(self: PlatformServices, window_id: WindowId, label: []const u8, cursor: Cursor) anyerror!void {
        const set_fn = self.set_view_cursor_fn orelse return;
        return set_fn(self.context, window_id, label, cursor);
    }

    pub fn focusView(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        const focus_fn = self.focus_view_fn orelse {
            return error.UnsupportedViewFocus;
        };
        return focus_fn(self.context, window_id, label);
    }

    pub fn closeView(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        if (self.close_view_fn) |close_fn| return close_fn(self.context, window_id, label);
        if (!std.mem.eql(u8, label, "main")) return self.closeWebView(window_id, label);
        return error.InvalidViewOptions;
    }

    /// Native-surface adoption: install an app-owned platform view handle
    /// (macOS: an NSView* the app constructed — a `VZVirtualMachineView`,
    /// an `MKMapView`) as the fill content of an existing native view. The
    /// platform keeps the surface sized to the container across shell
    /// relayout, and drops it when the container closes. Platforms without
    /// the capability reject explicitly instead of pretending.
    pub fn adoptViewSurface(self: PlatformServices, window_id: WindowId, label: []const u8, surface_handle: *anyopaque) anyerror!void {
        const adopt_fn = self.adopt_view_surface_fn orelse return error.UnsupportedService;
        return adopt_fn(self.context, window_id, label, surface_handle);
    }

    /// Remove an adopted surface from its container; the app-owned view
    /// itself stays alive for the caller to reuse.
    pub fn releaseViewSurface(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        const release_fn = self.release_view_surface_fn orelse return error.UnsupportedService;
        return release_fn(self.context, window_id, label);
    }

    pub fn createWebView(self: PlatformServices, options: WebViewOptions) anyerror!void {
        const create_fn = self.create_webview_fn orelse return error.UnsupportedService;
        return create_fn(self.context, options);
    }

    pub fn setWebViewFrame(self: PlatformServices, window_id: WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
        const set_fn = self.set_webview_frame_fn orelse return error.UnsupportedService;
        return set_fn(self.context, window_id, label, frame);
    }

    pub fn navigateWebView(self: PlatformServices, window_id: WindowId, label: []const u8, url: []const u8) anyerror!void {
        const navigate_fn = self.navigate_webview_fn orelse return error.UnsupportedService;
        return navigate_fn(self.context, window_id, label, url);
    }

    pub fn setWebViewZoom(self: PlatformServices, window_id: WindowId, label: []const u8, zoom: f64) anyerror!void {
        const zoom_fn = self.set_webview_zoom_fn orelse return error.UnsupportedService;
        return zoom_fn(self.context, window_id, label, zoom);
    }

    pub fn setWebViewLayer(self: PlatformServices, window_id: WindowId, label: []const u8, layer: i32) anyerror!void {
        const layer_fn = self.set_webview_layer_fn orelse return error.UnsupportedService;
        return layer_fn(self.context, window_id, label, layer);
    }

    pub fn closeWebView(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        const close_fn = self.close_webview_fn orelse return error.UnsupportedService;
        return close_fn(self.context, window_id, label);
    }

    pub fn setGpuSurfaceScrollDrivers(self: PlatformServices, window_id: WindowId, label: []const u8, drivers: []const GpuSurfaceScrollDriver, occluders: []const GpuSurfaceScrollOccluder) anyerror!void {
        const set_fn = self.set_gpu_surface_scroll_drivers_fn orelse return error.UnsupportedService;
        return set_fn(self.context, window_id, label, drivers, occluders);
    }

    pub fn showContextMenu(self: PlatformServices, request: ContextMenuRequest) anyerror!void {
        const show_fn = self.show_context_menu_fn orelse return error.UnsupportedService;
        return show_fn(self.context, request);
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

    pub fn showNotification(self: PlatformServices, options: NotificationOptions) anyerror!void {
        const notify_fn = self.show_notification_fn orelse return error.UnsupportedService;
        return notify_fn(self.context, options);
    }

    pub fn setCredential(self: PlatformServices, credential: Credential) anyerror!void {
        const set_fn = self.set_credential_fn orelse return error.UnsupportedService;
        return set_fn(self.context, credential);
    }

    pub fn getCredential(self: PlatformServices, key: CredentialKey, buffer: []u8) anyerror![]const u8 {
        const get_fn = self.get_credential_fn orelse return error.UnsupportedService;
        return get_fn(self.context, key, buffer);
    }

    pub fn deleteCredential(self: PlatformServices, key: CredentialKey) anyerror!void {
        const delete_fn = self.delete_credential_fn orelse return error.UnsupportedService;
        return delete_fn(self.context, key);
    }

    pub fn openExternalUrl(self: PlatformServices, url: []const u8) anyerror!void {
        const open_fn = self.open_external_url_fn orelse return error.UnsupportedService;
        return open_fn(self.context, url);
    }

    pub fn revealPath(self: PlatformServices, path: []const u8) anyerror!void {
        const reveal_fn = self.reveal_path_fn orelse return error.UnsupportedService;
        return reveal_fn(self.context, path);
    }

    pub fn addRecentDocument(self: PlatformServices, path: []const u8) anyerror!void {
        const add_fn = self.add_recent_document_fn orelse return error.UnsupportedService;
        return add_fn(self.context, path);
    }

    pub fn clearRecentDocuments(self: PlatformServices) anyerror!void {
        const clear_fn = self.clear_recent_documents_fn orelse return error.UnsupportedService;
        return clear_fn(self.context);
    }

    pub fn createTray(self: PlatformServices, options: TrayOptions) anyerror!void {
        const tray_fn = self.create_tray_fn orelse return error.UnsupportedService;
        return tray_fn(self.context, options);
    }

    pub fn updateTrayMenu(self: PlatformServices, items: []const TrayMenuItem) anyerror!void {
        const update_fn = self.update_tray_menu_fn orelse return error.UnsupportedService;
        return update_fn(self.context, items);
    }

    /// Retitle the live status-bar button without re-creating the item
    /// (re-creating flickers and can reshuffle the macOS menu bar). Added
    /// for model-driven tray state (e.g. an open-count badge in the
    /// title).
    pub fn updateTrayTitle(self: PlatformServices, title: []const u8) anyerror!void {
        const title_fn = self.update_tray_title_fn orelse return error.UnsupportedService;
        return title_fn(self.context, title);
    }

    pub fn removeTray(self: PlatformServices) anyerror!void {
        const remove_fn = self.remove_tray_fn orelse return error.UnsupportedService;
        return remove_fn(self.context);
    }

    pub fn configureSecurityPolicy(self: PlatformServices, policy: security.Policy) anyerror!void {
        const configure_fn = self.configure_security_policy_fn orelse return error.UnsupportedService;
        return configure_fn(self.context, policy);
    }

    pub fn configureMenus(self: PlatformServices, menus: []const Menu) anyerror!void {
        const configure_fn = self.configure_menus_fn orelse {
            if (menus.len == 0) return;
            return error.UnsupportedService;
        };
        return configure_fn(self.context, menus);
    }

    pub fn configureShortcuts(self: PlatformServices, shortcuts: []const Shortcut) anyerror!void {
        const configure_fn = self.configure_shortcuts_fn orelse {
            if (shortcuts.len == 0) return;
            return error.UnsupportedService;
        };
        return configure_fn(self.context, shortcuts);
    }

    pub fn emitWindowEvent(self: PlatformServices, window_id: WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
        const emit_fn = self.emit_window_event_fn orelse return error.UnsupportedService;
        return emit_fn(self.context, window_id, name, detail_json);
    }

    pub fn requestGpuSurfaceFrame(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        if (label.len == 0 or label.len > max_view_label_bytes) return error.InvalidViewOptions;
        const request_fn = self.request_gpu_surface_frame_fn orelse return;
        return request_fn(self.context, window_id, label);
    }

    /// Tell the host an input was dispatched to this surface, so an
    /// occluded-heartbeat host lets the responding frame fire promptly.
    /// Silently a no-op on hosts without occluded pacing.
    pub fn noteGpuSurfaceInput(self: PlatformServices, window_id: WindowId, label: []const u8) anyerror!void {
        if (label.len == 0 or label.len > max_view_label_bytes) return error.InvalidViewOptions;
        const note_fn = self.note_gpu_surface_input_fn orelse return;
        return note_fn(self.context, window_id, label);
    }

    /// Start (or replace) a repeating or one-shot timer identified by `id`.
    /// The platform delivers `.timer` events carrying the id until the timer
    /// is cancelled (or after the first fire when `repeats` is false).
    /// Starting an id that is already running replaces the existing timer.
    pub fn startTimer(self: PlatformServices, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
        const start_fn = self.start_timer_fn orelse return error.UnsupportedService;
        return start_fn(self.context, id, interval_ns, repeats);
    }

    pub fn cancelTimer(self: PlatformServices, id: u64) anyerror!void {
        const cancel_fn = self.cancel_timer_fn orelse return error.UnsupportedService;
        return cancel_fn(self.context, id);
    }

    /// Load a local audio file into the app's single audio player (see
    /// `audio_load_fn`). Platforms without audio playback answer
    /// `error.UnsupportedService`; bad arguments are rejected here before
    /// the platform is asked.
    pub fn audioLoad(self: PlatformServices, path: []const u8) anyerror!void {
        if (path.len == 0) return error.InvalidAudioOptions;
        if (path.len > max_audio_path_bytes) return error.AudioPathTooLarge;
        const load_fn = self.audio_load_fn orelse return error.UnsupportedService;
        return load_fn(self.context, path);
    }

    /// Load a URL audio source into the app's single audio player,
    /// resolving cache-vs-stream honestly (see `audio_load_url_fn`).
    /// Platforms without a streaming path answer
    /// `error.UnsupportedService`; bad arguments are rejected here
    /// before the platform is asked. URLs and cache paths share the
    /// local-path length bound — both travel the same fixed buffers.
    pub fn audioLoadUrl(self: PlatformServices, url: []const u8, cache_path: []const u8, expected_bytes: u64) anyerror!AudioLoadResolution {
        if (url.len == 0) return error.InvalidAudioOptions;
        if (url.len > max_audio_path_bytes) return error.AudioPathTooLarge;
        if (cache_path.len > max_audio_path_bytes) return error.AudioPathTooLarge;
        const load_fn = self.audio_load_url_fn orelse return error.UnsupportedService;
        return load_fn(self.context, url, cache_path, expected_bytes);
    }

    pub fn audioPlay(self: PlatformServices) anyerror!void {
        const play_fn = self.audio_play_fn orelse return error.UnsupportedService;
        return play_fn(self.context);
    }

    pub fn audioPause(self: PlatformServices) anyerror!void {
        const pause_fn = self.audio_pause_fn orelse return error.UnsupportedService;
        return pause_fn(self.context);
    }

    pub fn audioStop(self: PlatformServices) anyerror!void {
        const stop_fn = self.audio_stop_fn orelse return error.UnsupportedService;
        return stop_fn(self.context);
    }

    pub fn audioSeek(self: PlatformServices, position_ms: u64) anyerror!void {
        const seek_fn = self.audio_seek_fn orelse return error.UnsupportedService;
        return seek_fn(self.context, position_ms);
    }

    pub fn audioSetVolume(self: PlatformServices, volume: f32) anyerror!void {
        if (!(volume >= 0.0 and volume <= 1.0)) return error.InvalidAudioOptions;
        const volume_fn = self.audio_set_volume_fn orelse return error.UnsupportedService;
        return volume_fn(self.context, volume);
    }

    /// Load a local video file into the app's single video player (see
    /// `video_load_fn`). Platforms without video playback answer
    /// `error.UnsupportedService`; bad arguments are rejected here
    /// before the platform is asked.
    pub fn videoLoad(self: PlatformServices, path: []const u8, token: u64, sink: VideoFrameSink) anyerror!void {
        if (path.len == 0) return error.InvalidVideoOptions;
        if (path.len > max_video_path_bytes) return error.VideoPathTooLarge;
        const load_fn = self.video_load_fn orelse return error.UnsupportedService;
        return load_fn(self.context, path, token, sink);
    }

    /// Load an http(s) video source into the app's single video player,
    /// streaming progressively (see `video_load_url_fn`). Platforms
    /// without video playback answer `error.UnsupportedService`; bad
    /// arguments are rejected here before the platform is asked —
    /// including any non-http(s) scheme: hosts hand the URL to their
    /// media stack whole (AVPlayer opens file: URLs happily), so the
    /// seam is where the streaming-only contract holds for every
    /// caller, not just the engine's own gated loads.
    pub fn videoLoadUrl(self: PlatformServices, url: []const u8, token: u64, sink: VideoFrameSink) anyerror!void {
        if (url.len == 0) return error.InvalidVideoOptions;
        if (url.len > max_video_path_bytes) return error.VideoPathTooLarge;
        const uri = std.Uri.parse(url) catch return error.InvalidVideoOptions;
        const scheme_ok = std.ascii.eqlIgnoreCase(uri.scheme, "http") or
            std.ascii.eqlIgnoreCase(uri.scheme, "https");
        if (!scheme_ok) return error.InvalidVideoOptions;
        const load_fn = self.video_load_url_fn orelse return error.UnsupportedService;
        return load_fn(self.context, url, token, sink);
    }

    pub fn videoPlay(self: PlatformServices) anyerror!void {
        const play_fn = self.video_play_fn orelse return error.UnsupportedService;
        return play_fn(self.context);
    }

    pub fn videoPause(self: PlatformServices) anyerror!void {
        const pause_fn = self.video_pause_fn orelse return error.UnsupportedService;
        return pause_fn(self.context);
    }

    pub fn videoStop(self: PlatformServices) anyerror!void {
        const stop_fn = self.video_stop_fn orelse return error.UnsupportedService;
        return stop_fn(self.context);
    }

    pub fn videoSeek(self: PlatformServices, position_ms: u64) anyerror!void {
        const seek_fn = self.video_seek_fn orelse return error.UnsupportedService;
        return seek_fn(self.context, position_ms);
    }

    pub fn videoSetVolume(self: PlatformServices, volume: f32) anyerror!void {
        if (!(volume >= 0.0 and volume <= 1.0)) return error.InvalidVideoOptions;
        const volume_fn = self.video_set_volume_fn orelse return error.UnsupportedService;
        return volume_fn(self.context, volume);
    }

    pub fn videoSetMuted(self: PlatformServices, muted: bool) anyerror!void {
        const muted_fn = self.video_set_muted_fn orelse return error.UnsupportedService;
        return muted_fn(self.context, muted);
    }

    pub fn videoSetLoop(self: PlatformServices, loop: bool) anyerror!void {
        const loop_fn = self.video_set_loop_fn orelse return error.UnsupportedService;
        return loop_fn(self.context, loop);
    }

    /// Ask the platform loop to deliver a `.wake` event on its own thread.
    /// Safe to call from any thread; a missing implementation is an error
    /// so callers never assume a nudge happened when it did not.
    pub fn wake(self: PlatformServices) anyerror!void {
        const wake_fn = self.wake_fn orelse return error.UnsupportedService;
        return wake_fn(self.context);
    }

    /// Report that an in-flight `wake_fn` call was abandoned at
    /// teardown (see `note_channel_wake_abandoned_fn` for the platform
    /// obligation this triggers). Loop-thread, teardown-only. A
    /// platform without the seam simply cannot be told — the caller's
    /// own warning still names the leak, and a conforming `wake_fn`
    /// never reaches this in the first place.
    pub fn noteChannelWakeAbandoned(self: PlatformServices) void {
        const note_fn = self.note_channel_wake_abandoned_fn orelse return;
        note_fn(self.context);
    }

    /// Ask the platform loop to deliver one `frame_requested` event on
    /// its own thread. Safe to call from any thread; a missing
    /// implementation is an error so callers never assume a frame is
    /// coming when it is not.
    pub fn requestFrame(self: PlatformServices) anyerror!void {
        const request_fn = self.request_frame_fn orelse return error.UnsupportedService;
        return request_fn(self.context);
    }

    pub fn presentGpuSurfacePixels(self: PlatformServices, pixels: GpuSurfacePixels) anyerror!void {
        const expected = pixels.expectedByteLen() orelse return error.InvalidGpuSurfacePixels;
        if (pixels.rgba8.len != expected) return error.InvalidGpuSurfacePixels;
        if (pixels.label.len == 0 or pixels.label.len > max_view_label_bytes) return error.InvalidGpuSurfacePixels;
        const present_fn = self.present_gpu_surface_pixels_fn orelse return error.UnsupportedService;
        return present_fn(self.context, pixels);
    }

    pub fn presentGpuSurfacePacket(self: PlatformServices, packet: GpuSurfacePacket) anyerror!void {
        if (packet.label.len == 0 or packet.label.len > max_view_label_bytes) return error.InvalidGpuSurfacePacket;
        if (packet.json.len == 0 or packet.json.len > max_gpu_surface_packet_json_bytes) return error.InvalidGpuSurfacePacket;
        const present_fn = self.present_gpu_surface_packet_fn orelse return error.UnsupportedService;
        return present_fn(self.context, packet);
    }

    pub fn presentGpuSurfacePacketBinary(self: PlatformServices, packet: GpuSurfacePacket) anyerror!void {
        if (packet.label.len == 0 or packet.label.len > max_view_label_bytes) return error.InvalidGpuSurfacePacket;
        if (packet.binary.len == 0 or packet.binary.len > max_gpu_surface_packet_binary_bytes) return error.InvalidGpuSurfacePacket;
        const present_fn = self.present_gpu_surface_packet_binary_fn orelse return error.UnsupportedService;
        return present_fn(self.context, packet);
    }

    pub fn uploadGpuSurfaceImage(self: PlatformServices, image: GpuSurfaceImagePixels) anyerror!void {
        const expected = image.expectedByteLen() orelse return error.InvalidGpuSurfaceImage;
        if (image.rgba8.len != expected) return error.InvalidGpuSurfaceImage;
        // Two honest bounds, keyed by the id namespace: hosts copy every
        // upload into host-owned allocations (AppKit's NSData + NSImage
        // store), so each bound teaches the real cost of its id space.
        // Ordinary registered images are avatar-scale by the registry's
        // own slot bound; media-surface textures (the reserved high-bit
        // namespace) are video-scale by the producer channel's frame
        // budget — the bound the producer already enforced, so nothing a
        // producer staged can fail here.
        const bound = if ((image.id & canvas.media_surface_image_id_bit) != 0)
            max_gpu_surface_media_image_pixel_bytes
        else
            max_gpu_surface_image_pixel_bytes;
        if (image.rgba8.len > bound) return error.InvalidGpuSurfaceImage;
        const upload_fn = self.upload_gpu_surface_image_fn orelse return error.UnsupportedService;
        return upload_fn(self.context, image);
    }

    pub fn removeGpuSurfaceImage(self: PlatformServices, id: u64) anyerror!void {
        if (id == 0) return error.InvalidGpuSurfaceImage;
        const remove_fn = self.remove_gpu_surface_image_fn orelse return error.UnsupportedService;
        return remove_fn(self.context, id);
    }

    /// Returns the host's ownership token for this registration (0 from
    /// hosts that retain no per-id state) — see
    /// `register_gpu_surface_font_fn`.
    pub fn registerGpuSurfaceFont(self: PlatformServices, font: GpuSurfaceFontData) anyerror!u64 {
        if (font.id == 0) return error.InvalidGpuSurfaceFont;
        if (font.ttf.len == 0 or font.ttf.len > max_gpu_surface_font_bytes) return error.InvalidGpuSurfaceFont;
        const register_fn = self.register_gpu_surface_font_fn orelse return error.UnsupportedService;
        return register_fn(self.context, font);
    }

    /// `token` must be the value the matching `registerGpuSurfaceFont`
    /// returned; a stale token is a no-op accept — see
    /// `unregister_gpu_surface_font_fn`.
    pub fn unregisterGpuSurfaceFont(self: PlatformServices, id: u64, token: u64) anyerror!void {
        if (id == 0) return error.InvalidGpuSurfaceFont;
        const unregister_fn = self.unregister_gpu_surface_font_fn orelse return error.UnsupportedService;
        return unregister_fn(self.context, id, token);
    }

    pub fn updateWidgetAccessibility(self: PlatformServices, snapshot: WidgetAccessibilitySnapshot) anyerror!void {
        if (snapshot.view_label.len == 0 or snapshot.view_label.len > max_view_label_bytes) return error.InvalidViewOptions;
        if (snapshot.nodes.len > max_widget_accessibility_nodes) return error.InvalidViewOptions;
        const update_fn = self.update_widget_accessibility_fn orelse return;
        return update_fn(self.context, snapshot);
    }

    /// Decode encoded image bytes through the platform codec into
    /// straight-alpha RGBA8 (see `decode_image_fn`). Loop-thread only.
    pub fn decodeImage(self: PlatformServices, bytes: []const u8, buffer: []u8) anyerror!DecodedImage {
        if (bytes.len == 0) return error.ImageDecodeFailed;
        const decode_fn = self.decode_image_fn orelse return error.UnsupportedService;
        return decode_fn(self.context, bytes, buffer);
    }
};

/// A platform-decoded image: tightly packed, row-major, straight-alpha
/// RGBA8 pixels (`width * height * 4` bytes) sliced from the caller's
/// decode buffer.
pub const DecodedImage = struct {
    width: usize,
    height: usize,
    rgba8: []const u8,
};

pub const Platform = struct {
    context: *anyopaque,
    name: []const u8,
    surface_value: Surface,
    run_fn: *const fn (context: *anyopaque, handler: EventHandler, handler_context: *anyopaque) anyerror!void,
    supports_fn: ?*const fn (context: *anyopaque, feature: PlatformFeature) bool = null,
    services: PlatformServices = .{},
    app_info: AppInfo = .{},

    pub fn surface(self: Platform) Surface {
        return self.surface_value;
    }

    pub fn run(self: Platform, handler: EventHandler, handler_context: *anyopaque) anyerror!void {
        return self.run_fn(self.context, handler, handler_context);
    }

    pub fn supports(self: Platform, feature: PlatformFeature) bool {
        if (self.supports_fn) |supports_fn| return supports_fn(self.context, feature);
        return defaultSupportsFeature(self.services, feature);
    }
};

fn defaultSupportsFeature(services: PlatformServices, feature: PlatformFeature) bool {
    return switch (feature) {
        .main_webview => services.load_window_webview_fn != null or services.load_webview_fn != null,
        .child_webviews => services.create_webview_fn != null,
        .native_views => services.create_view_fn != null,
        .native_control_commands => services.create_view_fn != null,
        .menus => services.configure_menus_fn != null,
        .tray => services.create_tray_fn != null,
        .shortcuts => services.configure_shortcuts_fn != null,
        .dialogs => services.show_open_dialog_fn != null or services.show_save_dialog_fn != null or services.show_message_dialog_fn != null,
        .clipboard_text => services.read_clipboard_fn != null and services.write_clipboard_fn != null,
        .clipboard_rich_data => services.read_clipboard_data_fn != null and services.write_clipboard_data_fn != null,
        .open_url => services.open_external_url_fn != null,
        .reveal_path => services.reveal_path_fn != null,
        .notifications => services.show_notification_fn != null,
        .recent_documents => services.add_recent_document_fn != null or services.clear_recent_documents_fn != null,
        .credentials => services.set_credential_fn != null and services.get_credential_fn != null and services.delete_credential_fn != null,
        .file_drops => false,
        .app_activation_events => false,
        .gpu_surfaces => false,
        .gpu_surface_scroll_drivers => services.set_gpu_surface_scroll_drivers_fn != null,
        .context_menus => services.show_context_menu_fn != null,
        .view_surface_adoption => services.adopt_view_surface_fn != null,
        .audio_playback => services.audio_load_fn != null,
        .audio_streaming => services.audio_load_url_fn != null,
        // Spectrum analysis rides no service verb — the events arrive
        // spontaneously with playback — so the generic services probe
        // cannot see it; platforms that analyze answer through their own
        // `supports_fn` (like file_drops and gpu_surfaces above).
        .audio_spectrum => false,
        // Hide-on-close is host close-delegate behavior, not a service
        // verb: hosts that implement it answer through their own
        // `supports_fn`. The generic floor is honest refusal.
        .window_hide_on_close => false,
        // The load verb's presence alone is not proof of a decoder:
        // staged hosts register a teaching load that always refuses, so
        // they answer false through their own `supports_fn`. The
        // generic floor still probes the verb for embedders that wire a
        // real one.
        .video_playback => services.video_load_fn != null,
    };
}

fn isPlainTextMime(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "text/plain") or std.mem.eql(u8, mime_type, "text");
}

pub const Backend = enum {
    null,
    macos,
    linux,
    windows,
};
