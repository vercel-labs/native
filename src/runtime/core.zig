const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const trace = @import("trace");
const json = @import("json");
const validation = @import("validation.zig");
const runtime_api = @import("api.zig");
const bridge_responses = @import("bridge_responses.zig");
const runtime_async_bridge = @import("async_bridge.zig");
const runtime_automation_snapshot = @import("automation_snapshot.zig");
const automation_commands = @import("automation_commands.zig");
const runtime_automation_widget_dispatch = @import("automation_widget_dispatch.zig");
const runtime_clock = @import("clock.zig");
const shell_layout = @import("shell_layout.zig");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");
const runtime_canvas_images = @import("canvas_images.zig");
const runtime_canvas_fonts = @import("canvas_fonts.zig");
const runtime_canvas_widget_context_menu = @import("canvas_widget_context_menu.zig");
const runtime_canvas_widget_display = @import("canvas_widget_display.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");
const runtime_canvas_widget_scroll_drivers = @import("canvas_widget_scroll_drivers.zig");
const runtime_canvas_widget_state = @import("canvas_widget_state.zig");
const runtime_canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const runtime_frame_profile = @import("frame_profile.zig");
const runtime_gpu_surface_events = @import("gpu_surface_events.zig");
const runtime_flow = @import("flow.zig");
const runtime_session_state = @import("session_state.zig");
const runtime_state = @import("state.zig");
const runtime_system_services = @import("system_services.zig");
const runtime_builtin_bridge = @import("builtin_bridge.zig");
const runtime_view = @import("view.zig");
const runtime_window_views = @import("window_views.zig");
const widget_bridge = @import("widget_bridge.zig");
const canvas = @import("canvas");
const automation = @import("../automation/root.zig");
const bridge = @import("../bridge/root.zig");
const extensions = @import("../extensions/root.zig");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const runtime_effects = @import("effects.zig");
const security = @import("../security/root.zig");

const max_async_bridge_responses = runtime_async_bridge.max_async_bridge_responses;
pub const max_canvas_commands_per_view = canvas_limits.max_canvas_commands_per_view;
pub const max_canvas_gradient_stops_per_view = canvas_limits.max_canvas_gradient_stops_per_view;
pub const max_canvas_path_elements_per_view = canvas_limits.max_canvas_path_elements_per_view;
pub const max_canvas_glyphs_per_view = canvas_limits.max_canvas_glyphs_per_view;
pub const max_canvas_text_bytes_per_view = canvas_limits.max_canvas_text_bytes_per_view;
const max_canvas_diff_changes_per_view = canvas_limits.max_canvas_diff_changes_per_view;
const max_canvas_render_overrides_per_view = canvas_limits.max_canvas_render_overrides_per_view;
const max_canvas_pipelines_per_view = canvas_limits.max_canvas_pipelines_per_view;
const max_canvas_pipeline_cache_actions_per_view = canvas_limits.max_canvas_pipeline_cache_actions_per_view;
const max_canvas_path_geometries_per_view = canvas_limits.max_canvas_path_geometries_per_view;
const max_canvas_path_geometry_cache_actions_per_view = canvas_limits.max_canvas_path_geometry_cache_actions_per_view;
const max_canvas_images_per_view = canvas_limits.max_canvas_images_per_view;
const max_canvas_image_cache_actions_per_view = canvas_limits.max_canvas_image_cache_actions_per_view;
const max_canvas_layers_per_view = canvas_limits.max_canvas_layers_per_view;
const max_canvas_layer_cache_actions_per_view = canvas_limits.max_canvas_layer_cache_actions_per_view;
const max_canvas_resources_per_view = canvas_limits.max_canvas_resources_per_view;
const max_canvas_resource_cache_actions_per_view = canvas_limits.max_canvas_resource_cache_actions_per_view;
const max_canvas_visual_effects_per_view = canvas_limits.max_canvas_visual_effects_per_view;
const max_canvas_visual_effect_cache_actions_per_view = canvas_limits.max_canvas_visual_effect_cache_actions_per_view;
const validateCommandName = validation.validateCommandName;

const writeViewJson = bridge_responses.writeViewJson;
const builtinBridgeErrorMessage = bridge_responses.builtinBridgeErrorMessage;
const builtinBridgeErrorCode = bridge_responses.builtinBridgeErrorCode;

const AutomationWidgetAction = automation_commands.AutomationWidgetAction;
const AutomationWidgetTarget = automation_commands.AutomationWidgetTarget;
const AutomationWidgetWheel = automation_commands.AutomationWidgetWheel;
const AutomationWidgetKey = automation_commands.AutomationWidgetKey;
const AutomationWidgetPointerDrag = automation_commands.AutomationWidgetPointerDrag;
const parseAutomationCommandName = automation_commands.parseAutomationCommandName;
const parseAutomationViewLabel = automation_commands.parseAutomationViewLabel;
const parseAutomationNativeCommand = automation_commands.parseAutomationNativeCommand;
const parseAutomationWidgetAction = automation_commands.parseAutomationWidgetAction;
const parseAutomationWidgetTarget = automation_commands.parseAutomationWidgetTarget;
const parseAutomationWidgetWheel = automation_commands.parseAutomationWidgetWheel;
const parseAutomationWidgetKey = automation_commands.parseAutomationWidgetKey;
const parseAutomationWidgetPointerDrag = automation_commands.parseAutomationWidgetPointerDrag;
const parseAutomationResizeCommand = automation_commands.parseAutomationResizeCommand;

const RuntimeShellLayout = shell_layout.RuntimeShellLayout;
const sceneNeedsMainWebView = shell_layout.sceneNeedsMainWebView;

pub const CanvasPixelSize = canvas_frame_helpers.CanvasPixelSize;
pub const CanvasScreenshot = canvas_frame_helpers.CanvasScreenshot;
pub const canvasSurfacePixelSize = canvas_frame_helpers.canvasSurfacePixelSize;
pub const canvasFramePixelSize = canvas_frame_helpers.canvasFramePixelSize;

const RuntimeView = runtime_view.RuntimeView;
const nowNanoseconds = runtime_clock.nowNanoseconds;
const timestampToU64 = runtime_clock.timestampToU64;
const RuntimeWindow = runtime_state.RuntimeWindow;
const RuntimeMainWebViewState = runtime_state.RuntimeMainWebViewState;
const RuntimeSourceStorage = runtime_state.RuntimeSourceStorage;
const RuntimeWebView = runtime_state.RuntimeWebView;
const RuntimeTrayItem = runtime_state.RuntimeTrayItem;
const ShellApplyMode = runtime_state.ShellApplyMode;
const WindowSourcePolicy = runtime_state.WindowSourcePolicy;
const FocusTraversalDirection = runtime_state.FocusTraversalDirection;
const copySourceInto = runtime_state.copySourceInto;
const sourceWebViewUrl = runtime_state.sourceWebViewUrl;
const AsyncBridgeResponseSlot = runtime_async_bridge.AsyncBridgeResponseSlot(Runtime);
const platformCursorFromCanvas = widget_bridge.platformCursorFromCanvas;
const widgetRoleName = widget_bridge.widgetRoleName;
const platformWidgetAccessibilityRole = widget_bridge.platformWidgetAccessibilityRole;
const canvasWidgetActions = widget_bridge.canvasWidgetActions;
const platformWidgetAccessibilityActions = widget_bridge.platformWidgetAccessibilityActions;
const platformWidgetAccessibilityTextRange = widget_bridge.platformWidgetAccessibilityTextRange;
const platformWidgetAccessibilityNodeById = widget_bridge.platformWidgetAccessibilityNodeById;
const canvasWidgetSemanticsById = widget_bridge.canvasWidgetSemanticsById;
const canvasWidgetSemanticParentId = widget_bridge.canvasWidgetSemanticParentId;
const canvasWidgetSelectedState = widget_bridge.canvasWidgetSelectedState;
const canvasTextRange = widget_bridge.canvasTextRange;
const canvasVirtualRange = widget_bridge.canvasVirtualRange;
const canvasWidgetAccessibilityActionKindFromPlatform = widget_bridge.canvasWidgetAccessibilityActionKindFromPlatform;

pub const max_canvas_widget_nodes_per_view = canvas_limits.max_canvas_widget_nodes_per_view;
pub const max_canvas_widget_semantics_per_view = canvas_limits.max_canvas_widget_semantics_per_view;
pub const max_canvas_widget_text_bytes_per_view = canvas_limits.max_canvas_widget_text_bytes_per_view;
const max_canvas_widget_invalidations_per_view = canvas_limits.max_canvas_widget_invalidations_per_view;

pub const LifecycleEvent = runtime_api.LifecycleEvent;
pub const CommandEvent = runtime_api.CommandEvent;
pub const Command = runtime_api.Command;
pub const CommandSource = runtime_api.CommandSource;
pub const ShortcutEvent = runtime_api.ShortcutEvent;
pub const TimerEvent = runtime_api.TimerEvent;
pub const Appearance = runtime_api.Appearance;
pub const GpuFrame = runtime_api.GpuFrame;
pub const GpuSurfaceFrameEvent = runtime_api.GpuSurfaceFrameEvent;
pub const GpuSurfaceResizeEvent = runtime_api.GpuSurfaceResizeEvent;
pub const GpuSurfaceInputEvent = runtime_api.GpuSurfaceInputEvent;
pub const CanvasWidgetPointerEvent = runtime_api.CanvasWidgetPointerEvent;
pub const CanvasWidgetKeyboardEvent = runtime_api.CanvasWidgetKeyboardEvent;
pub const CanvasWidgetScrollEvent = runtime_api.CanvasWidgetScrollEvent;
pub const CanvasWidgetDisplayListChrome = runtime_api.CanvasWidgetDisplayListChrome;
pub const CanvasPresentationMode = runtime_api.CanvasPresentationMode;
pub const CanvasPresentationResult = runtime_api.CanvasPresentationResult;
pub const CanvasWidgetAccessibilityActionKind = runtime_api.CanvasWidgetAccessibilityActionKind;
pub const CanvasWidgetAccessibilityAction = runtime_api.CanvasWidgetAccessibilityAction;
pub const CanvasWidgetFileDropEvent = runtime_api.CanvasWidgetFileDropEvent;
pub const CanvasWidgetDragEvent = runtime_api.CanvasWidgetDragEvent;
pub const CanvasWidgetContextMenuEvent = runtime_api.CanvasWidgetContextMenuEvent;
pub const CanvasWidgetContextMenuRequestEvent = runtime_api.CanvasWidgetContextMenuRequestEvent;
pub const CanvasWidgetDismissEvent = runtime_api.CanvasWidgetDismissEvent;
pub const CanvasWidgetContextPressEvent = runtime_api.CanvasWidgetContextPressEvent;
pub const CanvasWidgetResizeEvent = runtime_api.CanvasWidgetResizeEvent;
pub const CanvasWidgetChangeEvent = runtime_api.CanvasWidgetChangeEvent;
pub const WindowClosedEvent = runtime_api.WindowClosedEvent;
pub const AutomationProvenanceEvent = runtime_api.AutomationProvenanceEvent;
pub const InvalidationReason = runtime_api.InvalidationReason;
pub const FrameDiagnostics = runtime_api.FrameDiagnostics;
pub const Event = runtime_api.Event;
pub const App = runtime_api.App(Runtime);
pub const Options = runtime_api.Options;
pub const ReplayControl = runtime_api.ReplayControl;

/// Bounded ring of degraded dispatch errors kept for snapshots and
/// queries: handler/update errors are caught, recorded here, and
/// the app continues. The oldest record is dropped when full; the
/// lifetime total keeps counting.
pub const max_dispatch_errors: usize = 16;
pub const DispatchError = automation.snapshot.DispatchError;

/// What dispatch does with a caught handler/update error AFTER recording
/// it in the dispatch-error ring. Production loops always `.degrade`: the app keeps
/// running and the error stays observable through `dispatchErrors()`,
/// traces, and snapshots. The TestHarness sets `.propagate` so capacity
/// errors (e.g. `error.WidgetLayoutListFull` from a view that outgrew
/// its per-view budget) fail tests instead of leaving silent stale
/// frames. Automation command dispatch is exempt: driver misuse
/// always degrades, regardless of policy.
pub const DispatchErrorPolicy = enum { degrade, propagate };

pub const Runtime = struct {
    options: Options,
    surface: platform.Surface,
    appearance: platform.Appearance = .{},
    windows: [platform.max_windows]RuntimeWindow = undefined,
    window_count: usize = 0,
    views: [platform.max_views]RuntimeView = undefined,
    view_count: usize = 0,
    webviews: [platform.max_webviews]RuntimeWebView = undefined,
    webview_count: usize = 0,
    tray_items: [platform.max_tray_items]RuntimeTrayItem = undefined,
    tray_item_count: usize = 0,
    tray_created: bool = false,
    tray_title: []const u8 = "",
    tray_title_storage: [platform.max_tray_title_bytes]u8 = undefined,
    /// Audio playback mirror for the automation snapshot, stamped by
    /// the ui-app layer whenever a dispatch or effect drain may have
    /// moved the effects channel's playback state. Like the tray, the
    /// player itself lives outside every window capture, so this is
    /// the only automation-visible evidence music is playing.
    audio_active: bool = false,
    audio_key: u64 = 0,
    audio_playing: bool = false,
    /// A streamed source is stalled waiting for network bytes —
    /// snapshot-visible so automation can pin the honest buffering
    /// state apart from playing (a stream is silent while buffering
    /// even though the transport is not paused).
    audio_buffering: bool = false,
    /// Where the playback's bytes come from — the resolved end of the
    /// `playAudio` source cascade (local file, verified cache entry,
    /// network stream).
    audio_source: runtime_effects.EffectAudioSource = .local,
    audio_position_ms: u64 = 0,
    audio_duration_ms: u64 = 0,
    /// The latest `.spectrum` band bytes and the delivery count for the
    /// active playback — snapshot-visible so automation can prove real
    /// analysis is flowing (the count moves while playing, holds on
    /// pause) without a screen capture. Zero events on a host that
    /// cannot analyze: honest absence, visible as such.
    audio_spectrum_bands: [platform.audio_spectrum_band_count]u8 = @splat(0),
    audio_spectrum_events: u64 = 0,
    shell_layouts: [platform.max_windows]RuntimeShellLayout = undefined,
    shell_layout_count: usize = 0,
    next_window_id: platform.WindowId = 2,
    next_view_id: platform.ViewId = 1,
    invalidated: bool = true,
    /// Whether the app's stop hook (`App.stop`) has been delivered.
    /// Normally the platform's `.app_shutdown` event delivers it; the
    /// run loop's exit path checks this flag and delivers a missed stop
    /// itself (an error unwind can end the loop without a shutdown
    /// event), so the hook runs exactly once and always while the
    /// platform's service table is still alive. Apps use the hook to
    /// release platform-backed resources (the UiApp effects channel
    /// silences audio, disarms timers, and severs its services binding
    /// there) because their own deinit typically runs from a `defer` in
    /// main AFTER the runner has already destroyed platform and runtime.
    app_stop_delivered: bool = false,
    started_timestamp_ns: u64 = 0,
    timestamp_ns: i128 = 0,
    frame_index: u64 = 0,
    command_count: usize = 0,
    dirty_regions: [8]geometry.RectF = undefined,
    dirty_region_count: usize = 0,
    last_invalidation_reason: InvalidationReason = .startup,
    last_diagnostics: FrameDiagnostics = .{},
    loaded_source: ?platform.WebViewSource = null,
    loaded_source_storage: RuntimeSourceStorage = .{},
    /// Degraded dispatch errors, oldest first (see `max_dispatch_errors`).
    dispatch_errors: [max_dispatch_errors]DispatchError = [_]DispatchError{.{}} ** max_dispatch_errors,
    dispatch_error_len: usize = 0,
    /// See `DispatchErrorPolicy`: production loops always degrade;
    /// the TestHarness propagates so capacity errors fail tests instead
    /// of leaving silent stale frames.
    dispatch_error_policy: DispatchErrorPolicy = .degrade,
    /// Lifetime count of degraded dispatch errors (including ones the
    /// bounded ring has since dropped).
    dispatch_error_total: u64 = 0,
    /// Trace records dropped because a sink was full or failing; a
    /// logging failure never fails dispatch.
    dropped_trace_records: u64 = 0,
    /// Whether an installing UiApp armed the markup hot-reload watch
    /// (see `setMarkupWatchArmed`); stamped into the snapshot header.
    markup_watch_armed: bool = false,
    /// Per-stage frame timing (rolling p50/p90 windows), toggled at
    /// runtime by `native automate profile on|off` and read by the
    /// snapshot's `frame_profile` line. Larger than the small-default
    /// copy bound, so `initAt` assigns it explicitly.
    frame_profile: runtime_frame_profile.FrameProfile = .{},
    async_bridge_responses: [max_async_bridge_responses]AsyncBridgeResponseSlot = [_]AsyncBridgeResponseSlot{.{}} ** max_async_bridge_responses,
    automation_windows: [automation.snapshot.max_windows]automation.snapshot.Window = undefined,
    /// Snapshot-side storage for the frame profile's per-stage stats
    /// (the snapshot Input only references runtime-owned memory).
    automation_frame_profile_stages: [runtime_frame_profile.frame_profile_stage_count]automation.snapshot.FrameProfileStage = undefined,
    automation_views: [automation.snapshot.max_views]platform.ViewInfo = undefined,
    automation_widgets: [automation.snapshot.max_widgets]automation.snapshot.Widget = undefined,
    /// Snapshot-side storage for per-widget declared context-menu items
    /// (the snapshot Input only references runtime-owned memory; labels
    /// alias the views' bounded menu storage). Sized so every view can
    /// list its full per-view item budget — the snapshot never truncates
    /// menus the runtime accepted.
    automation_widget_menu_items: [canvas_limits.max_canvas_widget_context_menu_items_per_view * platform.max_views]automation.snapshot.WidgetContextMenuItem = undefined,
    automation_tray_items: [platform.max_tray_items]automation.snapshot.TrayItem = undefined,
    /// Handshake for the `provenance` verb: cleared before the query is
    /// evented to the app, set by the app's response publish — so the
    /// dispatcher can answer with a teaching error when no app-side
    /// provenance table exists (builder-only apps, release engines).
    automation_provenance_published: bool = false,
    widget_event_route_entries: [canvas.max_widget_depth * 2]canvas.WidgetEventRouteEntry = undefined,
    /// The in-flight native context-menu request: set when the
    /// platform is asked to present, resolved by the matching
    /// `context_menu_action` event. At most one menu tracks at a time.
    canvas_widget_context_menu_pending: ?runtime_canvas_widget_context_menu.PendingCanvasWidgetContextMenu = null,
    canvas_widget_display_list_refresh_batch_depth: usize = 0,
    /// Nonzero while a gpu-surface input dispatch is live: accessibility
    /// publishes requested inside it defer to after the responding
    /// present (the platform publish is milliseconds-tolerant; the glass
    /// is not). Depth-counted because automation gestures nest input
    /// dispatches.
    canvas_widget_accessibility_defer_depth: usize = 0,
    // Scratch for setCanvasWidgetLayout's reconcile pass: too large for the
    // stack at the current node cap, and the event loop is single-threaded.
    canvas_widget_reconcile_nodes: [canvas_limits.max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode = undefined,
    canvas_widget_source_semantics_scratch: [canvas_limits.max_canvas_widget_semantics_per_view]canvas.WidgetSemanticsNode = undefined,
    // More reconcile-pass scratch that outgrew the stack when the widget
    // budgets quadrupled (256 -> 1024 nodes): previous control/scroll/text reconcile
    // entries, the previous text byte pool, and the invalidation diff.
    canvas_widget_reconcile_control_entries: [canvas_limits.max_canvas_widget_nodes_per_view]runtime_canvas_widget_runtime.CanvasWidgetControlReconcileEntry = undefined,
    canvas_widget_reconcile_scroll_entries: [canvas_limits.max_canvas_widget_nodes_per_view]runtime_canvas_widget_runtime.CanvasWidgetSourceScrollEntry = undefined,
    canvas_widget_reconcile_text_entries: [canvas_limits.max_canvas_widget_nodes_per_view]runtime_canvas_widget_runtime.CanvasWidgetTextReconcileEntry = undefined,
    canvas_widget_reconcile_text_bytes: [canvas_limits.max_canvas_widget_text_bytes_per_view]u8 = undefined,
    canvas_widget_invalidations_scratch: [canvas_limits.max_canvas_widget_invalidations_per_view]canvas.WidgetInvalidation = undefined,
    canvas_widget_copy_scratch: runtime_canvas_widget_runtime.CanvasWidgetCopyScratch = undefined,
    canvas_widget_display_list_refresh_pending: [platform.max_views]bool = [_]bool{false} ** platform.max_views,
    canvas_widget_accessibility_publish_pending: [platform.max_views]bool = [_]bool{false} ** platform.max_views,
    canvas_frame_render_commands: [max_canvas_commands_per_view]canvas.RenderCommand = undefined,
    canvas_frame_render_batches: [max_canvas_commands_per_view]canvas.RenderBatch = undefined,
    canvas_frame_pipeline_cache_entries: [max_canvas_pipelines_per_view]canvas.RenderPipelineCacheEntry = undefined,
    canvas_frame_pipeline_cache_actions: [max_canvas_pipeline_cache_actions_per_view]canvas.RenderPipelineCacheAction = undefined,
    canvas_frame_path_geometries: [max_canvas_path_geometries_per_view]canvas.RenderPathGeometry = undefined,
    canvas_frame_path_geometry_cache_entries: [max_canvas_path_geometries_per_view]canvas.RenderPathGeometryCacheEntry = undefined,
    canvas_frame_path_geometry_cache_actions: [max_canvas_path_geometry_cache_actions_per_view]canvas.RenderPathGeometryCacheAction = undefined,
    canvas_frame_images: [max_canvas_images_per_view]canvas.RenderImage = undefined,
    canvas_frame_image_cache_entries: [max_canvas_images_per_view]canvas.RenderImageCacheEntry = undefined,
    canvas_frame_image_cache_actions: [max_canvas_image_cache_actions_per_view]canvas.RenderImageCacheAction = undefined,
    canvas_frame_layers: [max_canvas_layers_per_view]canvas.RenderLayer = undefined,
    canvas_frame_layer_cache_entries: [max_canvas_layers_per_view]canvas.RenderLayerCacheEntry = undefined,
    canvas_frame_layer_cache_actions: [max_canvas_layer_cache_actions_per_view]canvas.RenderLayerCacheAction = undefined,
    canvas_frame_resources: [max_canvas_resources_per_view]canvas.RenderResource = undefined,
    canvas_frame_resource_cache_entries: [max_canvas_resources_per_view]canvas.RenderResourceCacheEntry = undefined,
    canvas_frame_resource_cache_actions: [max_canvas_resource_cache_actions_per_view]canvas.RenderResourceCacheAction = undefined,
    canvas_frame_visual_effects: [max_canvas_visual_effects_per_view]canvas.VisualEffect = undefined,
    canvas_frame_visual_effect_cache_entries: [max_canvas_visual_effects_per_view]canvas.VisualEffectCacheEntry = undefined,
    canvas_frame_visual_effect_cache_actions: [max_canvas_visual_effect_cache_actions_per_view]canvas.VisualEffectCacheAction = undefined,
    canvas_frame_glyph_atlas_entries: [max_canvas_glyphs_per_view]canvas.GlyphAtlasEntry = undefined,
    canvas_frame_glyph_atlas_cache_entries: [max_canvas_glyphs_per_view]canvas.GlyphAtlasCacheEntry = undefined,
    canvas_frame_glyph_atlas_cache_actions: [max_canvas_glyphs_per_view * 2]canvas.GlyphAtlasCacheAction = undefined,
    canvas_frame_changes: [max_canvas_diff_changes_per_view]canvas.DiffChange = undefined,
    canvas_frame_render_override_samples: [max_canvas_render_overrides_per_view]canvas.CanvasRenderOverride = undefined,
    canvas_frame_render_override_combined: [max_canvas_render_overrides_per_view]canvas.CanvasRenderOverride = undefined,
    /// Runtime-registered canvas images (see canvas_images.zig): entry
    /// metadata, the per-slot pixel pool, and the `ReferenceImage` scratch
    /// the frame planner hands to renderers each plan.
    canvas_image_entries: [canvas_limits.max_registered_canvas_images]runtime_canvas_images.CanvasImageEntry = [_]runtime_canvas_images.CanvasImageEntry{.{}} ** canvas_limits.max_registered_canvas_images,
    canvas_image_count: usize = 0,
    canvas_image_pixels: [canvas_limits.max_registered_canvas_images][canvas_limits.max_registered_canvas_image_pixel_bytes]u8 = undefined,
    canvas_image_resources_scratch: [canvas_limits.max_registered_canvas_images]canvas.ReferenceImage = undefined,
    /// Runtime-registered canvas fonts (see canvas_fonts.zig): entry
    /// metadata, the per-slot TrueType byte pool with parsed face views
    /// over it, the `ReferenceFont` scratch the frame planner hands to
    /// renderers, and the font-aware measure provider installed on first
    /// registration for platforms without host-side text measurement.
    canvas_font_entries: [canvas_limits.max_registered_canvas_fonts]runtime_canvas_fonts.CanvasFontEntry = [_]runtime_canvas_fonts.CanvasFontEntry{.{}} ** canvas_limits.max_registered_canvas_fonts,
    canvas_font_count: usize = 0,
    canvas_font_bytes: [canvas_limits.max_registered_canvas_fonts][canvas_limits.max_registered_canvas_font_bytes]u8 = undefined,
    canvas_font_faces: [canvas_limits.max_registered_canvas_fonts]canvas.font_ttf.Face = undefined,
    canvas_font_resources_scratch: [canvas_limits.max_registered_canvas_fonts]canvas.ReferenceFont = undefined,
    canvas_font_measure_provider: canvas.TextMeasureProvider = .{ .measure_fn = runtime_canvas_fonts.unboundCanvasFontMeasure },
    /// Platform text measurement captured at init and owned by the
    /// runtime so pointers stamped into design tokens stay valid for the
    /// runtime's lifetime. Null when the platform has no `measure_text_fn`
    /// (the null platform), keeping layout on the deterministic estimator.
    text_measure_provider: ?canvas.TextMeasureProvider = null,

    pub fn init(options: Options) Runtime {
        var self: Runtime = undefined;
        initAt(&self, options);
        return self;
    }

    /// Construct in place. The Runtime is tens of megabytes of fixed-capacity
    /// storage; by-value construction materializes a stack temporary in Debug
    /// builds that overflows default thread stacks, so every embedding
    /// constructs through a pointer.
    pub fn initAt(self: *Runtime, options: Options) void {
        inline for (@typeInfo(Runtime).@"struct".fields) |field| {
            if (comptime fieldHasSmallDefault(field)) {
                @field(self, field.name) = @as(*const field.type, @ptrCast(@alignCast(field.default_value_ptr.?))).*;
            }
        }
        self.options = options;
        self.surface = options.platform.surface();
        // The profile rings exceed the small-default copy bound above;
        // assign explicitly so the disabled state is never undefined.
        self.frame_profile = .{};
        self.started_timestamp_ns = timestampToU64(nowNanoseconds());
        self.text_measure_provider = if (options.platform.services.measure_text_fn) |measure_fn|
            .{
                .context = options.platform.services.context,
                .measure_fn = measure_fn,
                .measure_advances_fn = options.platform.services.measure_text_advances_fn,
            }
        else
            null;
        // Measured-text caches (batched advances, retained wrap results)
        // key on provider identity, and a fresh runtime can recycle a
        // predecessor's provider context address in the same process
        // (tests do constantly): bump the generation so nothing measured
        // against a previous runtime's provider can be served to this one.
        canvas.bumpTextMeasureGeneration();
    }

    fn fieldHasSmallDefault(comptime field: std.builtin.Type.StructField) bool {
        // Large fixed-capacity arrays default to undefined; skip writing
        // them so construction touches kilobytes, not megabytes.
        return field.default_value_ptr != null and @sizeOf(field.type) <= 4096;
    }

    pub fn invalidate(self: *Runtime) void {
        self.invalidateFor(.state, null);
    }

    pub fn invalidateFor(self: *Runtime, reason: InvalidationReason, dirty_region: ?geometry.RectF) void {
        self.invalidated = true;
        self.last_invalidation_reason = reason;
        if (dirty_region) |region| {
            if (self.dirty_region_count < self.dirty_regions.len) {
                self.dirty_regions[self.dirty_region_count] = region;
                self.dirty_region_count += 1;
            }
        }
    }

    pub fn pendingDirtyRegions(self: *const Runtime) []const geometry.RectF {
        return self.dirty_regions[0..self.dirty_region_count];
    }

    /// The most recent handler/update errors dispatch caught and
    /// degraded instead of terminating the app, oldest first.
    /// Also published in automation snapshots (`error event=... name=...`
    /// lines) and traced as `dispatch.error` records.
    pub fn dispatchErrors(self: *const Runtime) []const DispatchError {
        return self.dispatch_errors[0..self.dispatch_error_len];
    }

    /// Lifetime count of degraded dispatch errors, including records the
    /// bounded ring has since dropped.
    pub fn dispatchErrorTotal(self: *const Runtime) u64 {
        return self.dispatch_error_total;
    }

    /// Called by an installing UiApp when it arms (or skips) the markup
    /// hot-reload watch; published in the automation snapshot header as
    /// `markup_watch=armed|off` so a dev loop can prove — without
    /// bisecting — whether editing a .native source will reload the app.
    pub fn setMarkupWatchArmed(self: *Runtime, armed: bool) void {
        self.markup_watch_armed = armed;
    }

    const FlowMethods = runtime_flow.RuntimeFlow(Runtime);
    pub const run = FlowMethods.run;
    pub const emitWindowEvent = FlowMethods.emitWindowEvent;
    pub const respondToBridge = FlowMethods.respondToBridge;
    pub const dispatchPlatformEvent = FlowMethods.dispatchPlatformEvent;
    pub const dispatchEvent = FlowMethods.dispatchEvent;
    pub const dispatchCommand = FlowMethods.dispatchCommand;
    pub const frame = FlowMethods.frame;
    pub const automationSnapshot = FlowMethods.automationSnapshot;
    pub const dispatchAutomationCommand = FlowMethods.dispatchAutomationCommand;
    pub const frameDiagnostics = FlowMethods.frameDiagnostics;
    pub const supports = FlowMethods.supports;
    const reloadWindows = FlowMethods.reloadWindows;

    const SessionStateMethods = runtime_session_state.RuntimeSessionState(Runtime);
    pub const sessionStateFingerprint = SessionStateMethods.sessionStateFingerprint;

    const WindowViewMethods = runtime_window_views.RuntimeWindowViews(Runtime);
    pub const createWindow = WindowViewMethods.createWindow;
    pub const listWindows = WindowViewMethods.listWindows;
    pub const focusWindow = WindowViewMethods.focusWindow;
    pub const closeWindow = WindowViewMethods.closeWindow;
    pub const minimizeWindow = WindowViewMethods.minimizeWindow;
    pub const createShellWindow = WindowViewMethods.createShellWindow;
    pub const createSourcelessShellWindow = WindowViewMethods.createSourcelessShellWindow;
    pub const createShellViews = WindowViewMethods.createShellViews;
    pub const relayoutShellViews = WindowViewMethods.relayoutShellViews;
    pub const createView = WindowViewMethods.createView;
    pub const updateView = WindowViewMethods.updateView;
    pub const closeView = WindowViewMethods.closeView;
    pub const listViews = WindowViewMethods.listViews;
    pub const focusView = WindowViewMethods.focusView;
    pub const adoptViewSurface = WindowViewMethods.adoptViewSurface;
    pub const releaseViewSurface = WindowViewMethods.releaseViewSurface;
    pub const focusNextView = WindowViewMethods.focusNextView;
    pub const focusPreviousView = WindowViewMethods.focusPreviousView;
    const createShellWindowWithSourceMode = WindowViewMethods.createShellWindowWithSourceMode;
    const validateShellViewCreatePlan = WindowViewMethods.validateShellViewCreatePlan;
    const applyShellViews = WindowViewMethods.applyShellViews;
    const applyShellView = WindowViewMethods.applyShellView;
    const rollbackCreatedShellViews = WindowViewMethods.rollbackCreatedShellViews;
    const captureMainWebViewState = WindowViewMethods.captureMainWebViewState;
    const restoreMainWebViewState = WindowViewMethods.restoreMainWebViewState;
    const createWindowWithSourceMode = WindowViewMethods.createWindowWithSourceMode;
    const reserveWindow = WindowViewMethods.reserveWindow;
    const removeWindowAt = WindowViewMethods.removeWindowAt;
    const copySource = WindowViewMethods.copySource;
    const copyLoadedSource = WindowViewMethods.copyLoadedSource;
    const applyNativeInfo = WindowViewMethods.applyNativeInfo;
    const updateWindowState = WindowViewMethods.updateWindowState;
    const runtimeWindowStateForPersistence = WindowViewMethods.runtimeWindowStateForPersistence;
    const removeWindowRuntimeViews = WindowViewMethods.removeWindowRuntimeViews;
    const shellBoundsForWindow = WindowViewMethods.shellBoundsForWindow;
    const startupWindowFrame = WindowViewMethods.startupWindowFrame;
    const rectsEqual = WindowViewMethods.rectsEqual;
    const canvasDirtyRegionForView = WindowViewMethods.canvasDirtyRegionForView;
    const bindShellViews = WindowViewMethods.bindShellViews;
    const shellLayoutForWindow = WindowViewMethods.shellLayoutForWindow;
    const findShellLayoutIndex = WindowViewMethods.findShellLayoutIndex;
    const removeShellLayoutForWindow = WindowViewMethods.removeShellLayoutForWindow;
    const setFocusedIndex = WindowViewMethods.setFocusedIndex;
    const findWindowIndexById = WindowViewMethods.findWindowIndexById;
    const findWindowIndexByLabel = WindowViewMethods.findWindowIndexByLabel;
    const allocateWindowId = WindowViewMethods.allocateWindowId;
    const allocateViewId = WindowViewMethods.allocateViewId;
    const validateWebViewParent = WindowViewMethods.validateWebViewParent;
    const validateWebViewUrl = WindowViewMethods.validateWebViewUrl;
    const writeWebViewListJson = WindowViewMethods.writeWebViewListJson;
    const reserveWebView = WindowViewMethods.reserveWebView;
    const findWebViewIndex = WindowViewMethods.findWebViewIndex;
    pub const webViewLocalFrame = WindowViewMethods.webViewLocalFrame;
    const removeWebViewAt = WindowViewMethods.removeWebViewAt;
    const removeWebViewsForWindow = WindowViewMethods.removeWebViewsForWindow;
    const mainWebViewInfo = WindowViewMethods.mainWebViewInfo;
    const createWebViewView = WindowViewMethods.createWebViewView;
    const setMainWebViewParent = WindowViewMethods.setMainWebViewParent;
    const updateWebViewView = WindowViewMethods.updateWebViewView;
    const validateViewParent = WindowViewMethods.validateViewParent;
    const validateViewParentLink = WindowViewMethods.validateViewParentLink;
    const platformFrameForView = WindowViewMethods.platformFrameForView;
    const localFrameForView = WindowViewMethods.localFrameForView;
    const absoluteViewFrame = WindowViewMethods.absoluteViewFrame;
    const relayoutDescendantWebViewBackends = WindowViewMethods.relayoutDescendantWebViewBackends;
    const relayoutDescendantWebViewBackendsDepth = WindowViewMethods.relayoutDescendantWebViewBackendsDepth;
    const reserveView = WindowViewMethods.reserveView;
    const findViewIndex = WindowViewMethods.findViewIndex;
    const commandSourceForNativeView = WindowViewMethods.commandSourceForNativeView;
    const setFocusedView = WindowViewMethods.setFocusedView;
    const clearFocusedView = WindowViewMethods.clearFocusedView;
    const ensureFocusableViewFocused = WindowViewMethods.ensureFocusableViewFocused;
    const focusAdjacentView = WindowViewMethods.focusAdjacentView;
    const viewLabelExists = WindowViewMethods.viewLabelExists;
    const removeViewAt = WindowViewMethods.removeViewAt;
    const removeViewsForWindow = WindowViewMethods.removeViewsForWindow;
    const removeDescendantViewsForParent = WindowViewMethods.removeDescendantViewsForParent;
    const removeDescendantWebViewsForParent = WindowViewMethods.removeDescendantWebViewsForParent;
    const closeDescendantWebViewBackends = WindowViewMethods.closeDescendantWebViewBackends;
    const closeDescendantWebViewBackendsDepth = WindowViewMethods.closeDescendantWebViewBackendsDepth;
    const viewTreeHasFocused = WindowViewMethods.viewTreeHasFocused;
    const viewTreeHasFocusedDepth = WindowViewMethods.viewTreeHasFocusedDepth;

    const SystemServiceMethods = runtime_system_services.RuntimeSystemServices(Runtime);
    pub const readClipboard = SystemServiceMethods.readClipboard;
    pub const writeClipboard = SystemServiceMethods.writeClipboard;
    pub const readClipboardData = SystemServiceMethods.readClipboardData;
    pub const writeClipboardData = SystemServiceMethods.writeClipboardData;
    pub const openExternalUrl = SystemServiceMethods.openExternalUrl;
    pub const revealPath = SystemServiceMethods.revealPath;
    pub const addRecentDocument = SystemServiceMethods.addRecentDocument;
    pub const clearRecentDocuments = SystemServiceMethods.clearRecentDocuments;
    pub const showOpenDialog = SystemServiceMethods.showOpenDialog;
    pub const showSaveDialog = SystemServiceMethods.showSaveDialog;
    pub const showMessageDialog = SystemServiceMethods.showMessageDialog;
    pub const showNotification = SystemServiceMethods.showNotification;
    pub const setCredential = SystemServiceMethods.setCredential;
    pub const getCredential = SystemServiceMethods.getCredential;
    pub const deleteCredential = SystemServiceMethods.deleteCredential;
    pub const createTray = SystemServiceMethods.createTray;
    pub const updateTrayMenu = SystemServiceMethods.updateTrayMenu;
    pub const updateTrayTitle = SystemServiceMethods.updateTrayTitle;
    pub const removeTray = SystemServiceMethods.removeTray;
    const trayCommandNameForItem = SystemServiceMethods.trayCommandNameForItem;
    const supportsFeatureFromJson = SystemServiceMethods.supportsFeatureFromJson;
    const readClipboardTextFromJson = SystemServiceMethods.readClipboardTextFromJson;
    const writeClipboardTextFromJson = SystemServiceMethods.writeClipboardTextFromJson;
    const readClipboardDataFromJson = SystemServiceMethods.readClipboardDataFromJson;
    const writeClipboardDataFromJson = SystemServiceMethods.writeClipboardDataFromJson;
    const setCredentialFromJson = SystemServiceMethods.setCredentialFromJson;
    const getCredentialFromJson = SystemServiceMethods.getCredentialFromJson;
    const deleteCredentialFromJson = SystemServiceMethods.deleteCredentialFromJson;
    const showNotificationFromJson = SystemServiceMethods.showNotificationFromJson;
    const openExternalUrlFromJson = SystemServiceMethods.openExternalUrlFromJson;
    const revealPathFromJson = SystemServiceMethods.revealPathFromJson;
    const addRecentDocumentFromJson = SystemServiceMethods.addRecentDocumentFromJson;
    const clearRecentDocumentsFromJson = SystemServiceMethods.clearRecentDocumentsFromJson;
    const openFileDialogFromJson = SystemServiceMethods.openFileDialogFromJson;
    const saveFileDialogFromJson = SystemServiceMethods.saveFileDialogFromJson;
    const showMessageDialogFromJson = SystemServiceMethods.showMessageDialogFromJson;

    /// Start (or replace) a platform timer. The platform delivers `.timer`
    /// events carrying `id` until `cancelTimer` (or after the first fire when
    /// `repeats` is false). Ids at or above
    /// `platform.reserved_timer_id_base` are reserved for the framework.
    pub fn startTimer(self: *Runtime, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
        return self.options.platform.services.startTimer(id, interval_ns, repeats);
    }

    pub fn cancelTimer(self: *Runtime, id: u64) anyerror!void {
        return self.options.platform.services.cancelTimer(id);
    }

    /// The platform's text measurement wrapped as a canvas provider; on
    /// platforms without one (null platform, tests), the runtime's
    /// font-aware provider once fonts are registered (registered ids
    /// measure with their parsed face, everything else keeps the
    /// deterministic estimator — see canvas_fonts.zig); otherwise null,
    /// keeping layout on the estimator exactly as before. Platforms WITH
    /// host measurement keep it for registered ids too: the host learned
    /// the face at registration, so measurement and drawing share one
    /// resolution. Provider values live on the runtime, so returned
    /// pointers are stable for the runtime's lifetime and tokens stamped
    /// with them compare equal frame to frame.
    pub fn textMeasureProvider(self: *const Runtime) ?*const canvas.TextMeasureProvider {
        if (self.text_measure_provider) |*provider| return provider;
        if (self.canvas_font_count > 0) return &self.canvas_font_measure_provider;
        return null;
    }

    /// `tokens` with the platform text measurement stamped in. Runtimes and
    /// apps should pass tokens through this before layout so measured text
    /// agrees with the fonts presentation draws.
    pub fn tokensWithTextMeasure(self: *const Runtime, tokens: canvas.DesignTokens) canvas.DesignTokens {
        var next = tokens;
        next.text_measure = self.textMeasureProvider();
        return next;
    }

    /// Viewport chrome insets for a window's content: the safe-area and
    /// system-keyboard insets the platform reported for the window's
    /// surface, combined edge-wise (the same rule shell views lay out
    /// with). Zero for windows without a matching surface and on desktop
    /// platforms, which report no insets — canvas layout deflated by this
    /// is byte-identical there. Mobile shims feed the insets through the
    /// embed viewport export so notches, status bars, home indicators, and
    /// the on-screen keyboard inset widget layout at the runtime level
    /// instead of per-app view math.
    pub fn viewportInsetsForWindow(self: *const Runtime, window_id: platform.WindowId) geometry.InsetsF {
        if (self.surface.id != window_id) return .{};
        return shell_layout.combinedViewportInsets(self.surface);
    }

    /// The safe-area share of `viewportInsetsForWindow`: what the platform
    /// reported as OS overlay (notch, status bar, home indicator) without
    /// the keyboard's contribution. Apps that subscribe to window chrome
    /// take ownership of exactly this share (see `UiApp.on_chrome`), so
    /// the runtime needs it split out to keep insetting only the rest.
    pub fn safeAreaInsetsForWindow(self: *const Runtime, window_id: platform.WindowId) geometry.InsetsF {
        if (self.surface.id != window_id) return .{};
        return self.surface.safe_area_insets;
    }

    /// The OS window-control cluster's frame in a canvas view's LOCAL
    /// coordinates (Windows: the DWM min/max/close buttons; macOS: the
    /// traffic lights), from the platform's live chrome report. Zero-sized
    /// when no controls overlay the content — standard-chrome windows,
    /// fullscreen, platforms without the concept — and translated by the
    /// view's window-content frame so a docked canvas judges the overlap
    /// in its own space. This is the geometry `UiApp` consults to keep a
    /// drag header's content out from under the cluster.
    pub fn windowControlsForView(self: *const Runtime, window_id: platform.WindowId, label: []const u8) geometry.RectF {
        const zero = geometry.RectF.init(0, 0, 0, 0);
        const buttons = self.options.platform.services.windowChrome(window_id).buttons.normalized();
        if (buttons.width <= 0 or buttons.height <= 0) return zero;
        const view_frame = (self.absoluteViewFrame(window_id, label, 0) catch return buttons).normalized();
        return geometry.RectF.init(buttons.x - view_frame.x, buttons.y - view_frame.y, buttons.width, buttons.height);
    }

    pub fn listCommands(self: *const Runtime, output: []Command) []const Command {
        const count = @min(output.len, self.options.commands.len);
        for (self.options.commands[0..count], 0..) |command, index| {
            output[index] = command;
        }
        return output[0..count];
    }

    const CanvasFrameMethods = canvas_frame_helpers.RuntimeCanvasFrames(Runtime);
    pub const setCanvasDisplayList = CanvasFrameMethods.setCanvasDisplayList;
    pub const canvasDisplayList = CanvasFrameMethods.canvasDisplayList;
    pub const setCanvasRenderAnimations = CanvasFrameMethods.setCanvasRenderAnimations;
    pub const clearCanvasRenderAnimations = CanvasFrameMethods.clearCanvasRenderAnimations;
    pub const canvasRenderAnimations = CanvasFrameMethods.canvasRenderAnimations;
    pub const canvasRenderAnimationStartNs = CanvasFrameMethods.canvasRenderAnimationStartNs;
    pub const canvasFramePlan = CanvasFrameMethods.canvasFramePlan;
    pub const nextCanvasFrame = CanvasFrameMethods.nextCanvasFrame;
    pub const nextCanvasGpuPacket = CanvasFrameMethods.nextCanvasGpuPacket;
    pub const presentNextCanvasGpuPacket = CanvasFrameMethods.presentNextCanvasGpuPacket;
    pub const presentNextCanvasGpuPacketWithScale = CanvasFrameMethods.presentNextCanvasGpuPacketWithScale;
    pub const presentNextCanvasFrame = CanvasFrameMethods.presentNextCanvasFrame;
    pub const presentCanvasFramePixels = CanvasFrameMethods.presentCanvasFramePixels;
    pub const presentNextCanvasFramePixels = CanvasFrameMethods.presentNextCanvasFramePixels;
    pub const renderCanvasScreenshot = CanvasFrameMethods.renderCanvasScreenshot;
    pub const renderCanvasScreenshotWithMemo = CanvasFrameMethods.renderCanvasScreenshotWithMemo;
    pub const canvasScreenshotPixelSize = CanvasFrameMethods.canvasScreenshotPixelSize;
    const planCanvasFrameForView = CanvasFrameMethods.planCanvasFrameForView;
    pub const canvasFrameScratchStorage = CanvasFrameMethods.canvasFrameScratchStorage;
    pub const gpuSurfaceFrame = CanvasFrameMethods.gpuSurfaceFrame;
    pub const setCanvasFrameBudget = CanvasFrameMethods.setCanvasFrameBudget;
    pub const setGpuSurfaceInputLatencyBudget = CanvasFrameMethods.setGpuSurfaceInputLatencyBudget;
    const requestCanvasFrameForView = CanvasFrameMethods.requestCanvasFrameForView;
    const invalidateForCanvasChanges = CanvasFrameMethods.invalidateForCanvasChanges;

    const CanvasImageMethods = runtime_canvas_images.RuntimeCanvasImages(Runtime);
    pub const registerCanvasImage = CanvasImageMethods.registerCanvasImage;
    pub const registerCanvasImageBytes = CanvasImageMethods.registerCanvasImageBytes;
    pub const unregisterCanvasImage = CanvasImageMethods.unregisterCanvasImage;
    pub const registeredCanvasImages = CanvasImageMethods.registeredCanvasImages;
    pub const registeredCanvasImage = CanvasImageMethods.registeredCanvasImage;
    pub const registeredCanvasImageCount = CanvasImageMethods.registeredCanvasImageCount;
    pub const canvasImageRegistryBinding = CanvasImageMethods.canvasImageRegistryBinding;

    const CanvasFontMethods = runtime_canvas_fonts.RuntimeCanvasFonts(Runtime);
    pub const registerCanvasFont = CanvasFontMethods.registerCanvasFont;
    pub const registeredCanvasFonts = CanvasFontMethods.registeredCanvasFonts;
    pub const registeredCanvasFontFace = CanvasFontMethods.registeredCanvasFontFace;
    pub const registeredCanvasFontCount = CanvasFontMethods.registeredCanvasFontCount;

    const CanvasWidgetStateMethods = runtime_canvas_widget_state.RuntimeCanvasWidgetState(Runtime);
    pub const setCanvasWidgetLayout = CanvasWidgetStateMethods.setCanvasWidgetLayout;
    pub const canvasWidgetLayout = CanvasWidgetStateMethods.canvasWidgetLayout;
    pub const canvasWidgetSemantics = CanvasWidgetStateMethods.canvasWidgetSemantics;
    pub const dispatchCanvasWidgetAccessibilityAction = CanvasWidgetStateMethods.dispatchCanvasWidgetAccessibilityAction;
    pub const stepCanvasWidgetKineticScroll = CanvasWidgetStateMethods.stepCanvasWidgetKineticScroll;
    pub const startCanvasWidgetLayoutTween = CanvasWidgetStateMethods.startCanvasWidgetLayoutTween;
    pub const advanceCanvasWidgetLayoutTweensForFrame = CanvasWidgetStateMethods.advanceCanvasWidgetLayoutTweensForFrame;
    pub const advanceCanvasWidgetDisclosureTweenForFrame = CanvasWidgetStateMethods.advanceCanvasWidgetDisclosureTweenForFrame;
    pub const setCanvasWidgetDesignTokens = CanvasWidgetStateMethods.setCanvasWidgetDesignTokens;
    pub const canvasWidgetDesignTokens = CanvasWidgetStateMethods.canvasWidgetDesignTokens;
    pub const canvasWidgetTextGeometry = CanvasWidgetStateMethods.canvasWidgetTextGeometry;
    pub const editCanvasWidgetText = CanvasWidgetStateMethods.editCanvasWidgetText;

    const CanvasWidgetDisplayMethods = runtime_canvas_widget_display.RuntimeCanvasWidgetDisplay(Runtime);
    pub const emitCanvasWidgetDisplayList = CanvasWidgetDisplayMethods.emitCanvasWidgetDisplayList;
    pub const emitCanvasWidgetDisplayListWithStoredTokens = CanvasWidgetDisplayMethods.emitCanvasWidgetDisplayListWithStoredTokens;
    pub const emitCanvasWidgetDisplayListWithChrome = CanvasWidgetDisplayMethods.emitCanvasWidgetDisplayListWithChrome;
    pub const emitCanvasWidgetDisplayListWithStoredTokensAndChrome = CanvasWidgetDisplayMethods.emitCanvasWidgetDisplayListWithStoredTokensAndChrome;
    const emitCanvasWidgetDisplayListForViewWithChrome = CanvasWidgetDisplayMethods.emitCanvasWidgetDisplayListForViewWithChrome;
    const refreshCanvasWidgetDisplayListIfOwned = CanvasWidgetDisplayMethods.refreshCanvasWidgetDisplayListIfOwned;
    const refreshCanvasWidgetDisplayListIfOwnedSkippingAccessibility = CanvasWidgetDisplayMethods.refreshCanvasWidgetDisplayListIfOwnedSkippingAccessibility;
    const refreshCanvasWidgetDisplayListIfOwnedWithAccessibility = CanvasWidgetDisplayMethods.refreshCanvasWidgetDisplayListIfOwnedWithAccessibility;
    const refreshCanvasWidgetDisplayListIfOwnedWithAccessibilityImmediate = CanvasWidgetDisplayMethods.refreshCanvasWidgetDisplayListIfOwnedWithAccessibilityImmediate;
    const beginCanvasWidgetDisplayListRefreshBatch = CanvasWidgetDisplayMethods.beginCanvasWidgetDisplayListRefreshBatch;
    const cancelCanvasWidgetDisplayListRefreshBatch = CanvasWidgetDisplayMethods.cancelCanvasWidgetDisplayListRefreshBatch;
    const endCanvasWidgetDisplayListRefreshBatch = CanvasWidgetDisplayMethods.endCanvasWidgetDisplayListRefreshBatch;
    const advanceCanvasWidgetKineticScrollForFrame = CanvasWidgetDisplayMethods.advanceCanvasWidgetKineticScrollForFrame;
    const scheduleCanvasWidgetToggleAnimation = CanvasWidgetDisplayMethods.scheduleCanvasWidgetToggleAnimation;
    const publishCanvasWidgetAccessibility = CanvasWidgetDisplayMethods.publishCanvasWidgetAccessibility;
    const refreshCanvasWidgetDisplayList = CanvasWidgetDisplayMethods.refreshCanvasWidgetDisplayList;

    const CanvasWidgetEventMethods = runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
    pub const routeCanvasWidgetPointerInput = CanvasWidgetEventMethods.routeCanvasWidgetPointerInput;
    pub const routeCanvasWidgetKeyboardInput = CanvasWidgetEventMethods.routeCanvasWidgetKeyboardInput;
    pub const routeCanvasWidgetTextInput = CanvasWidgetEventMethods.routeCanvasWidgetTextInput;
    pub const routeCanvasWidgetFileDrop = CanvasWidgetEventMethods.routeCanvasWidgetFileDrop;
    pub const routeCanvasWidgetDragInput = CanvasWidgetEventMethods.routeCanvasWidgetDragInput;
    pub const startCanvasWidgetWindowDragFromPointer = CanvasWidgetEventMethods.startCanvasWidgetWindowDragFromPointer;
    const updateCanvasWidgetFocusFromPointer = CanvasWidgetEventMethods.updateCanvasWidgetFocusFromPointer;
    const updateCanvasWidgetInteractionFromPointer = CanvasWidgetEventMethods.updateCanvasWidgetInteractionFromPointer;
    const syncCanvasWidgetCursorForView = CanvasWidgetEventMethods.syncCanvasWidgetCursorForView;
    const invalidateForCanvasWidgetRenderStateChange = CanvasWidgetEventMethods.invalidateForCanvasWidgetRenderStateChange;
    const invalidateForCanvasWidgetRenderStateDirty = CanvasWidgetEventMethods.invalidateForCanvasWidgetRenderStateDirty;
    const canvasWidgetRenderStateAfterLayout = CanvasWidgetEventMethods.canvasWidgetRenderStateAfterLayout;
    const canvasWidgetRenderStatesEqual = CanvasWidgetEventMethods.canvasWidgetRenderStatesEqual;
    const updateCanvasWidgetScrollFromPointer = CanvasWidgetEventMethods.updateCanvasWidgetScrollFromPointer;
    const updateCanvasWidgetTextFromKeyboard = CanvasWidgetEventMethods.updateCanvasWidgetTextFromKeyboard;
    const updateCanvasWidgetTextFromPointer = CanvasWidgetEventMethods.updateCanvasWidgetTextFromPointer;
    const updateCanvasWidgetControlFromPointer = CanvasWidgetEventMethods.updateCanvasWidgetControlFromPointer;
    const updateCanvasWidgetControlFromKeyboard = CanvasWidgetEventMethods.updateCanvasWidgetControlFromKeyboard;
    const dismissCanvasWidgetSurfaceFromPointerInput = CanvasWidgetEventMethods.dismissCanvasWidgetSurfaceFromPointerInput;
    const dismissCanvasWidgetSurfaceFromKeyboardInput = CanvasWidgetEventMethods.dismissCanvasWidgetSurfaceFromKeyboardInput;
    const dispatchCanvasWidgetCommandForId = CanvasWidgetEventMethods.dispatchCanvasWidgetCommandForId;
    const dispatchCanvasWidgetCommandFromPointer = CanvasWidgetEventMethods.dispatchCanvasWidgetCommandFromPointer;
    const dispatchCanvasWidgetCommandFromKeyboard = CanvasWidgetEventMethods.dispatchCanvasWidgetCommandFromKeyboard;
    const updateCanvasWidgetFocusFromKeyboardInput = CanvasWidgetEventMethods.updateCanvasWidgetFocusFromKeyboardInput;
    const setCanvasWidgetFocusFromKeyboard = CanvasWidgetEventMethods.setCanvasWidgetFocusFromKeyboard;
    const invalidateForWidgetInvalidations = CanvasWidgetEventMethods.invalidateForWidgetInvalidations;
    const invalidateForCanvasWidgetDirty = CanvasWidgetEventMethods.invalidateForCanvasWidgetDirty;

    const GpuSurfaceEventMethods = runtime_gpu_surface_events.RuntimeGpuSurfaceEvents(Runtime);
    const dispatchGpuSurfaceFrame = GpuSurfaceEventMethods.dispatchGpuSurfaceFrame;
    const dispatchGpuSurfaceResized = GpuSurfaceEventMethods.dispatchGpuSurfaceResized;
    const dispatchGpuSurfaceInput = GpuSurfaceEventMethods.dispatchGpuSurfaceInput;

    const AutomationWidgetMethods = runtime_automation_widget_dispatch.RuntimeAutomationWidgetDispatch(Runtime);
    const dispatchAutomationWidgetAction = AutomationWidgetMethods.dispatchAutomationWidgetAction;
    const dispatchAutomationWidgetClick = AutomationWidgetMethods.dispatchAutomationWidgetClick;
    const dispatchAutomationWidgetHold = AutomationWidgetMethods.dispatchAutomationWidgetHold;
    const dispatchAutomationWidgetContextPress = AutomationWidgetMethods.dispatchAutomationWidgetContextPress;
    const dispatchAutomationWidgetWheel = AutomationWidgetMethods.dispatchAutomationWidgetWheel;
    const dispatchAutomationWidgetKeyInput = AutomationWidgetMethods.dispatchAutomationWidgetKeyInput;
    const dispatchAutomationWidgetPointerDrag = AutomationWidgetMethods.dispatchAutomationWidgetPointerDrag;
    const canvasWidgetActionsForId = AutomationWidgetMethods.canvasWidgetActionsForId;
    const dismissAutomationCanvasWidget = AutomationWidgetMethods.dismissAutomationCanvasWidget;
    const focusAutomationCanvasWidget = AutomationWidgetMethods.focusAutomationCanvasWidget;
    const dispatchAutomationWidgetKey = AutomationWidgetMethods.dispatchAutomationWidgetKey;
    const selectAutomationCanvasWidget = AutomationWidgetMethods.selectAutomationCanvasWidget;
    const setAutomationCanvasWidgetText = AutomationWidgetMethods.setAutomationCanvasWidgetText;
    const editAutomationCanvasWidgetText = AutomationWidgetMethods.editAutomationCanvasWidgetText;
    const composeAutomationCanvasWidgetText = AutomationWidgetMethods.composeAutomationCanvasWidgetText;
    const dispatchAutomationCanvasWidgetDrag = AutomationWidgetMethods.dispatchAutomationCanvasWidgetDrag;
    const dispatchAutomationCanvasWidgetFileDrop = AutomationWidgetMethods.dispatchAutomationCanvasWidgetFileDrop;
};

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

fn isFocusableViewInfo(view: platform.ViewInfo) bool {
    return view.open and view.visible and view.enabled;
}

pub fn TestHarness() type {
    return struct {
        const Self = @This();

        null_platform: platform.NullPlatform = platform.NullPlatform.init(.{}),
        trace_records: [64]trace.Record = undefined,
        trace_sink: trace.BufferSink = undefined,
        runtime: Runtime = undefined,

        /// The harness embeds the multi-megabyte Runtime, so stack
        /// instances overflow test threads; create on the heap.
        pub fn create(gpa: std.mem.Allocator, surface: platform.Surface) !*Self {
            const self = try gpa.create(Self);
            self.init(surface);
            return self;
        }

        pub fn destroy(self: *Self, gpa: std.mem.Allocator) void {
            gpa.destroy(self);
        }

        pub fn init(self: *Self, surface: platform.Surface) void {
            self.null_platform = platform.NullPlatform.init(surface);
            self.trace_sink = trace.BufferSink.init(&self.trace_records);
            Runtime.initAt(&self.runtime, .{
                .platform = self.null_platform.platform(),
                .trace_sink = self.trace_sink.sink(),
                // Real-executor effect tests spawn processes that must
                // see the parent environment (HOME, PATH), exactly as
                // the app runner threads it from `std.process.Init`.
                .environ = if (builtin.is_test) std.testing.environ else null,
            });
            // Tests fail loud on handler/update errors; production
            // loops keep the degrade default. Tests that exercise
            // the degrade path set `.degrade` back explicitly.
            self.runtime.dispatch_error_policy = .propagate;
        }

        pub fn start(self: *Self, app: App) anyerror!void {
            try self.runtime.dispatchPlatformEvent(app, .app_start);
            try self.runtime.dispatchPlatformEvent(app, .{ .surface_resized = self.null_platform.surface_value });
            try self.runtime.dispatchPlatformEvent(app, .frame_requested);
        }

        pub fn stop(self: *Self, app: App) anyerror!void {
            try self.runtime.dispatchPlatformEvent(app, .app_shutdown);
        }
    };
}

const testingWriteViewJson = writeViewJson;
const testingCopyInto = copyInto;
const testingCanvasWidgetSemanticsById = canvasWidgetSemanticsById;
const testingPlatformWidgetAccessibilityNodeById = platformWidgetAccessibilityNodeById;
const testingBuiltinBridgeErrorCode = builtinBridgeErrorCode;
const testingBuiltinBridgeErrorMessage = builtinBridgeErrorMessage;

pub const testing = struct {
    pub fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
        return testingCopyInto(buffer, value);
    }

    pub fn writeViewJson(view: platform.ViewInfo, output: []u8) ![]const u8 {
        return testingWriteViewJson(view, output);
    }

    pub fn canvasFrameScratchStorage(runtime: *Runtime) canvas.CanvasFrameStorage {
        return runtime.canvasFrameScratchStorage();
    }

    pub fn runtimeViewInfo(view: anytype) platform.ViewInfo {
        return view.info();
    }

    pub fn runtimeViewCanvasFrameRenderOverrides(view: anytype) []const canvas.CanvasRenderOverride {
        return view.canvasFrameRenderOverrides();
    }

    pub fn runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides(
        view: anytype,
        previous: []const canvas.CanvasRenderOverride,
        next: []const canvas.CanvasRenderOverride,
    ) ?geometry.RectF {
        return view.canvasRenderAnimationDirtyBoundsForOverrides(previous, next);
    }

    pub fn runtimeViewWidgetSemantics(view: anytype) []const canvas.WidgetSemanticsNode {
        return view.widgetSemantics();
    }

    pub fn runtimeViewSetCanvasWidgetSelected(view: anytype, id: canvas.ObjectId, selected: bool) anyerror!?geometry.RectF {
        return view.setCanvasWidgetSelected(id, selected);
    }

    pub fn runtimeViewCanvasWidgetDirtyBounds(view: anytype, node_index: usize, bounds: geometry.RectF) ?geometry.RectF {
        return view.canvasWidgetDirtyBounds(node_index, bounds);
    }

    pub fn dispatchAutomationWidgetAction(runtime: *Runtime, app: App, action: anytype) anyerror!void {
        const normalized: AutomationWidgetAction = .{
            .view_label = action.view_label,
            .id = action.id,
            .action = action.action,
            .value = if (@hasField(@TypeOf(action), "value")) action.value else "",
        };
        return runtime.dispatchAutomationWidgetAction(app, normalized);
    }

    pub fn shellBoundsForWindow(runtime: *const Runtime, window_id: platform.WindowId) geometry.RectF {
        return runtime.shellBoundsForWindow(window_id);
    }

    pub fn reloadWindows(runtime: *Runtime, app: App) anyerror!void {
        return runtime.reloadWindows(app);
    }

    pub fn canvasWidgetSemanticsById(nodes: []const canvas.WidgetSemanticsNode, id: canvas.ObjectId) ?canvas.WidgetSemanticsNode {
        return testingCanvasWidgetSemanticsById(nodes, id);
    }

    pub fn platformWidgetAccessibilityNodeById(nodes: []const platform.WidgetAccessibilityNode, id: u64) ?platform.WidgetAccessibilityNode {
        return testingPlatformWidgetAccessibilityNodeById(nodes, id);
    }

    pub fn builtinBridgeErrorCode(err: anyerror) bridge.ErrorCode {
        return testingBuiltinBridgeErrorCode(err);
    }

    pub fn builtinBridgeErrorMessage(err: anyerror) []const u8 {
        return testingBuiltinBridgeErrorMessage(err);
    }
};

test {
    std.testing.refAllDecls(@This());
}
