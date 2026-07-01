const std = @import("std");
const geometry = @import("geometry");
const trace = @import("trace");
const json = @import("json");
const validation = @import("validation.zig");
const bridge_payload = @import("bridge_payload.zig");
const bridge_responses = @import("bridge_responses.zig");
const automation_commands = @import("automation_commands.zig");
const shell_layout = @import("shell_layout.zig");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const runtime_state = @import("state.zig");
const runtime_view = @import("view.zig");
const widget_bridge = @import("widget_bridge.zig");
const canvas = @import("canvas");
const automation = @import("../automation/root.zig");
const bridge = @import("../bridge/root.zig");
const extensions = @import("../extensions/root.zig");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const security = @import("../security/root.zig");
const window_state = @import("../window_state/root.zig");

const max_async_bridge_responses: usize = 64;
const max_bridge_origin_bytes: usize = 512;
const max_command_id_bytes = validation.max_command_id_bytes;
pub const max_canvas_commands_per_view = canvas_limits.max_canvas_commands_per_view;
pub const max_canvas_gradient_stops_per_view = canvas_limits.max_canvas_gradient_stops_per_view;
pub const max_canvas_path_elements_per_view = canvas_limits.max_canvas_path_elements_per_view;
pub const max_canvas_glyphs_per_view = canvas_limits.max_canvas_glyphs_per_view;
pub const max_canvas_text_bytes_per_view = canvas_limits.max_canvas_text_bytes_per_view;
const max_canvas_diff_changes_per_view = canvas_limits.max_canvas_diff_changes_per_view;
const max_canvas_render_animations_per_view = canvas_limits.max_canvas_render_animations_per_view;
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
const max_canvas_text_layouts_per_view = canvas_limits.max_canvas_text_layouts_per_view;
threadlocal var canvas_frame_text_layout_plans_scratch: [max_canvas_text_layouts_per_view]canvas.TextLayoutPlan = undefined;
threadlocal var canvas_frame_text_layout_lines_scratch: [max_canvas_text_layouts_per_view]canvas.TextLine = undefined;
threadlocal var canvas_frame_text_layout_cache_entries_scratch: [max_canvas_text_layouts_per_view]canvas.TextLayoutCacheEntry = undefined;
threadlocal var canvas_frame_text_layout_cache_actions_scratch: [max_canvas_text_layouts_per_view * 2]canvas.TextLayoutCacheAction = undefined;

const validateCommandName = validation.validateCommandName;
const validateRevealPath = validation.validateRevealPath;
const validateRecentDocumentPath = validation.validateRecentDocumentPath;
const validateOpenDialogOptions = validation.validateOpenDialogOptions;
const validateSaveDialogOptions = validation.validateSaveDialogOptions;
const validateMessageDialogOptions = validation.validateMessageDialogOptions;
const validateNotificationOptions = validation.validateNotificationOptions;
const validateClipboardData = validation.validateClipboardData;
const validateClipboardMimeType = validation.validateClipboardMimeType;
const validateCredential = validation.validateCredential;
const validateCredentialKey = validation.validateCredentialKey;
const validateTrayOptions = validation.validateTrayOptions;
const validateTrayMenuItems = validation.validateTrayMenuItems;
const validateWindowFrame = validation.validateWindowFrame;
const isMainWebViewLabel = validation.isMainWebViewLabel;
const validateWebViewLabel = validation.validateWebViewLabel;
const validateChildWebViewLabel = validation.validateChildWebViewLabel;
const validateViewOptions = validation.validateViewOptions;
const validateViewLabel = validation.validateViewLabel;
const validateViewFrame = validation.validateViewFrame;
const isValidWebViewFrame = validation.isValidWebViewFrame;

const jsonStringField = bridge_payload.jsonStringField;
const webViewWindowIdFromJson = bridge_payload.webViewWindowIdFromJson;
const viewWindowIdFromJson = bridge_payload.viewWindowIdFromJson;
const viewKindFromString = bridge_payload.viewKindFromString;
const gpuSurfaceOptionsFromJson = bridge_payload.gpuSurfaceOptionsFromJson;
const platformFeatureFromString = bridge_payload.platformFeatureFromString;
const viewFrameFromJson = bridge_payload.viewFrameFromJson;
const viewLayerFromJson = bridge_payload.viewLayerFromJson;
const webViewFrameFromJson = bridge_payload.webViewFrameFromJson;
const webViewLayerFromJson = bridge_payload.webViewLayerFromJson;
const webViewUrlOrigin = bridge_payload.webViewUrlOrigin;
const jsonNumberField = bridge_payload.jsonNumberField;
const writeWindowJson = bridge_responses.writeWindowJson;
const writeTrueJson = bridge_responses.writeTrueJson;
const writeBoolJson = bridge_responses.writeBoolJson;
const writeWebViewOkJson = bridge_responses.writeWebViewOkJson;
const writeWebViewJson = bridge_responses.writeWebViewJson;
const writeViewJson = bridge_responses.writeViewJson;
const writeCommandEventJson = bridge_responses.writeCommandEventJson;
const writeCommandJsonToWriter = bridge_responses.writeCommandJsonToWriter;
const writeViewJsonToWriter = bridge_responses.writeViewJsonToWriter;
const viewInfoFromWebView = bridge_responses.viewInfoFromWebView;
const writeWebViewJsonToWriter = bridge_responses.writeWebViewJsonToWriter;
const writeWindowJsonToWriter = bridge_responses.writeWindowJsonToWriter;
const builtinBridgeErrorMessage = bridge_responses.builtinBridgeErrorMessage;
const builtinBridgeErrorCode = bridge_responses.builtinBridgeErrorCode;
const jsonIntegerField = bridge_payload.jsonIntegerField;
const jsonBoolField = bridge_payload.jsonBoolField;

const AutomationNativeCommand = automation_commands.AutomationNativeCommand;
const AutomationWidgetActionKind = automation_commands.AutomationWidgetActionKind;
const AutomationWidgetAction = automation_commands.AutomationWidgetAction;
const AutomationWidgetTarget = automation_commands.AutomationWidgetTarget;
const AutomationWidgetWheel = automation_commands.AutomationWidgetWheel;
const AutomationWidgetKey = automation_commands.AutomationWidgetKey;
const AutomationWidgetPointerDrag = automation_commands.AutomationWidgetPointerDrag;
const AutomationResizeCommand = automation_commands.AutomationResizeCommand;
const parseAutomationCommandName = automation_commands.parseAutomationCommandName;
const parseAutomationViewLabel = automation_commands.parseAutomationViewLabel;
const parseAutomationNativeCommand = automation_commands.parseAutomationNativeCommand;
const parseAutomationWidgetAction = automation_commands.parseAutomationWidgetAction;
const parseAutomationWidgetTarget = automation_commands.parseAutomationWidgetTarget;
const parseAutomationWidgetWheel = automation_commands.parseAutomationWidgetWheel;
const parseAutomationWidgetKey = automation_commands.parseAutomationWidgetKey;
const parseAutomationWidgetPointerDrag = automation_commands.parseAutomationWidgetPointerDrag;
const automationWidgetActionSupported = automation_commands.automationWidgetActionSupported;
const parseAutomationDropPaths = automation_commands.parseAutomationDropPaths;
const parseAutomationTextSelection = automation_commands.parseAutomationTextSelection;
const parseAutomationDragDelta = automation_commands.parseAutomationDragDelta;
const parseAutomationResizeCommand = automation_commands.parseAutomationResizeCommand;

const RuntimeShellLayout = shell_layout.RuntimeShellLayout;
const ShellLayout = shell_layout.ShellLayout;
const shellRestorePolicy = shell_layout.shellRestorePolicy;
const sceneNeedsMainWebView = shell_layout.sceneNeedsMainWebView;
const shellViewOptions = shell_layout.shellViewOptions;
const combinedViewportInsets = shell_layout.combinedViewportInsets;

pub const CanvasPixelSize = canvas_frame_helpers.CanvasPixelSize;
pub const canvasSurfacePixelSize = canvas_frame_helpers.canvasSurfacePixelSize;
pub const canvasFramePixelSize = canvas_frame_helpers.canvasFramePixelSize;
const appendCanvasSummaryChange = canvas_frame_helpers.appendCanvasSummaryChange;
const canvasDirtyBoundsFromChanges = canvas_frame_helpers.canvasDirtyBoundsFromChanges;
const canvasFrameBudgetIsUnset = canvas_frame_helpers.canvasFrameBudgetIsUnset;
const canvasFullRepaintBounds = canvas_frame_helpers.canvasFullRepaintBounds;
const sizesEqual = canvas_frame_helpers.sizesEqual;
const normalizedCanvasPresentationScale = canvas_frame_helpers.normalizedCanvasPresentationScale;
const canvasColorToRgba8 = canvas_frame_helpers.canvasColorToRgba8;
const clippedCanvasDirtyBounds = canvas_frame_helpers.clippedCanvasDirtyBounds;
const unionRects = canvas_frame_helpers.unionRects;
const canvasWidgetPointerEventFromGpuInput = canvas_frame_helpers.canvasWidgetPointerEventFromGpuInput;
const canvasWidgetInputBatchesDisplayListRefresh = canvas_frame_helpers.canvasWidgetInputBatchesDisplayListRefresh;
const canvasWidgetKeyboardEventFromGpuInput = canvas_frame_helpers.canvasWidgetKeyboardEventFromGpuInput;
const canvasWidgetTextInputEventFromGpuInput = canvas_frame_helpers.canvasWidgetTextInputEventFromGpuInput;
const canvasWidgetEscapeKey = canvas_frame_helpers.canvasWidgetEscapeKey;
const canvasWidgetKeyboardModifiers = canvas_frame_helpers.canvasWidgetKeyboardModifiers;
const mergeCanvasRenderOverrides = canvas_frame_helpers.mergeCanvasRenderOverrides;
const findCanvasRenderOverrideIndex = canvas_frame_helpers.findCanvasRenderOverrideIndex;
const canvasRenderOverrideNoop = canvas_frame_helpers.canvasRenderOverrideNoop;
const canvasRenderAnimationFinalOverrideNoop = canvas_frame_helpers.canvasRenderAnimationFinalOverrideNoop;
const canvasRenderAnimationActive = canvas_frame_helpers.canvasRenderAnimationActive;
const platformCanvasFrameProfileRisk = canvas_frame_helpers.platformCanvasFrameProfileRisk;
const gpuSurfaceFrameEventFromGpuFrame = canvas_frame_helpers.gpuSurfaceFrameEventFromGpuFrame;

const WidgetTextStorageRange = canvas_widget_runtime.WidgetTextStorageRange;
const CanvasWidgetScrollReconcileEntry = canvas_widget_runtime.CanvasWidgetScrollReconcileEntry;
const CanvasWidgetControlReconcileEntry = canvas_widget_runtime.CanvasWidgetControlReconcileEntry;
const CanvasWidgetTextReconcileEntry = canvas_widget_runtime.CanvasWidgetTextReconcileEntry;
const CanvasWidgetScrollKeyboardTarget = canvas_widget_runtime.CanvasWidgetScrollKeyboardTarget;
const CanvasWidgetStepDirection = canvas_widget_runtime.CanvasWidgetStepDirection;
const canvasWidgetInteractionTargetExists = canvas_widget_runtime.canvasWidgetInteractionTargetExists;
const canvasWidgetSelectableTargetExists = canvas_widget_runtime.canvasWidgetSelectableTargetExists;
const collectCanvasWidgetControlReconcileEntries = canvas_widget_runtime.collectCanvasWidgetControlReconcileEntries;
const collectCanvasWidgetScrollReconcileEntries = canvas_widget_runtime.collectCanvasWidgetScrollReconcileEntries;
const canvasWidgetScrollStateForLayoutNode = canvas_widget_runtime.canvasWidgetScrollStateForLayoutNode;
const collectCanvasWidgetTextReconcileEntries = canvas_widget_runtime.collectCanvasWidgetTextReconcileEntries;
const canvasWidgetEditableTextKind = canvas_widget_runtime.canvasWidgetEditableTextKind;
const canvasWidgetLayoutTreeWithRuntimeReconcileState = canvas_widget_runtime.canvasWidgetLayoutTreeWithRuntimeReconcileState;
const canvasWidgetCommandable = canvas_widget_runtime.canvasWidgetCommandable;
const canvasWidgetCommandFiresOnPointerDown = canvas_widget_runtime.canvasWidgetCommandFiresOnPointerDown;
const canvasWidgetKineticScrollFrameMs = canvas_widget_runtime.canvasWidgetKineticScrollFrameMs;
const RuntimeView = runtime_view.RuntimeView;
const CanvasDisplayListScratch = runtime_view.CanvasDisplayListScratch;
const CanvasWidgetScrollSource = runtime_view.CanvasWidgetScrollSource;
const CanvasWidgetToggleAnimation = runtime_view.CanvasWidgetToggleAnimation;
const canvasRenderAnimationStartNsForView = runtime_view.canvasRenderAnimationStartNsForView;
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
const canvasWidgetAccessibilityActionSupported = widget_bridge.canvasWidgetAccessibilityActionSupported;
const canvasWidgetAccessibilitySemanticAction = widget_bridge.canvasWidgetAccessibilitySemanticAction;
const canvasWidgetAccessibilityActionKindFromPlatform = widget_bridge.canvasWidgetAccessibilityActionKindFromPlatform;
const canvasWidgetGroupFocusEdgeFromInput = canvas_widget_runtime.canvasWidgetGroupFocusEdgeFromInput;
const canvasWidgetSpatialFocusDirection = canvas_widget_runtime.canvasWidgetSpatialFocusDirection;
const canvasWidgetSpatialFocusAllowed = canvas_widget_runtime.canvasWidgetSpatialFocusAllowed;
const canvasWidgetGroupDirectionalFocusTarget = canvas_widget_runtime.canvasWidgetGroupDirectionalFocusTarget;
const canvasWidgetGroupFocusEdgeTarget = canvas_widget_runtime.canvasWidgetGroupFocusEdgeTarget;

pub const max_canvas_widget_nodes_per_view = canvas_limits.max_canvas_widget_nodes_per_view;
pub const max_canvas_widget_semantics_per_view = canvas_limits.max_canvas_widget_semantics_per_view;
pub const max_canvas_widget_text_bytes_per_view = canvas_limits.max_canvas_widget_text_bytes_per_view;
const max_canvas_widget_invalidations_per_view = canvas_limits.max_canvas_widget_invalidations_per_view;

pub const LifecycleEvent = enum {
    start,
    activate,
    deactivate,
    frame,
    stop,
};

pub const CommandEvent = struct {
    name: []const u8,
    source: CommandSource = .runtime,
    window_id: platform.WindowId = 0,
    view_label: []const u8 = "",
    tray_item_id: platform.TrayItemId = 0,
};

pub const Command = app_manifest.Command;

pub const CommandSource = enum {
    runtime,
    menu,
    shortcut,
    toolbar,
    tray,
    native_view,
    bridge,
};

pub const ShortcutEvent = platform.ShortcutEvent;
pub const Appearance = platform.Appearance;
pub const GpuFrame = platform.GpuFrame;
pub const GpuSurfaceFrameEvent = platform.GpuSurfaceFrameEvent;
pub const GpuSurfaceResizeEvent = platform.GpuSurfaceResizeEvent;
pub const GpuSurfaceInputEvent = platform.GpuSurfaceInputEvent;

pub const CanvasWidgetPointerEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    pointer: canvas.WidgetPointerEvent,
    target: ?canvas.WidgetHit = null,
    route: []const canvas.WidgetEventRouteEntry = &.{},
};

pub const CanvasWidgetKeyboardEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    keyboard: canvas.WidgetKeyboardEvent,
    target: ?canvas.WidgetFocusTarget = null,
    route: []const canvas.WidgetEventRouteEntry = &.{},
};

pub const CanvasWidgetDisplayListChrome = runtime_view.CanvasWidgetDisplayListChrome;

pub const CanvasPresentationMode = enum {
    skipped,
    gpu_packet,
    pixels,
};

pub const CanvasPresentationResult = struct {
    frame: canvas.CanvasFrame,
    mode: CanvasPresentationMode = .skipped,
    packet_command_count: usize = 0,
    packet_cache_action_count: usize = 0,
    packet_cached_resource_command_count: usize = 0,
    packet_unsupported_command_count: usize = 0,
    packet_representable: bool = true,
};

pub const CanvasWidgetAccessibilityActionKind = widget_bridge.CanvasWidgetAccessibilityActionKind;
pub const CanvasWidgetAccessibilityAction = widget_bridge.CanvasWidgetAccessibilityAction;

pub const CanvasWidgetFileDropEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    drop: canvas.WidgetFileDropEvent,
    target: ?canvas.WidgetHit = null,
    route: []const canvas.WidgetEventRouteEntry = &.{},
};

pub const CanvasWidgetDragEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    drag: canvas.WidgetDragEvent,
    source: ?canvas.WidgetHit = null,
    route: []const canvas.WidgetEventRouteEntry = &.{},
};

pub const InvalidationReason = enum {
    startup,
    surface_resize,
    command,
    state,
};

pub const FrameDiagnostics = struct {
    frame_index: u64 = 0,
    command_count: usize = 0,
    dirty_region_count: usize = 0,
    resource_upload_count: usize = 0,
    duration_ns: u64 = 0,
};

pub const Event = union(enum) {
    lifecycle: LifecycleEvent,
    appearance_changed: Appearance,
    command: CommandEvent,
    shortcut: ShortcutEvent,
    files_dropped: platform.FileDropEvent,
    gpu_surface_frame: GpuSurfaceFrameEvent,
    gpu_surface_resized: GpuSurfaceResizeEvent,
    gpu_surface_input: GpuSurfaceInputEvent,
    canvas_widget_pointer: CanvasWidgetPointerEvent,
    canvas_widget_keyboard: CanvasWidgetKeyboardEvent,
    canvas_widget_file_drop: CanvasWidgetFileDropEvent,
    canvas_widget_drag: CanvasWidgetDragEvent,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .lifecycle => |event_value| @tagName(event_value),
            .appearance_changed => "appearance_changed",
            .command => |event_value| event_value.name,
            .shortcut => "shortcut",
            .files_dropped => "files_dropped",
            .gpu_surface_frame => "gpu_surface_frame",
            .gpu_surface_resized => "gpu_surface_resized",
            .gpu_surface_input => "gpu_surface_input",
            .canvas_widget_pointer => "canvas_widget_pointer",
            .canvas_widget_keyboard => "canvas_widget_keyboard",
            .canvas_widget_file_drop => "canvas_widget_file_drop",
            .canvas_widget_drag => "canvas_widget_drag",
        };
    }
};

const StartFn = *const fn (context: *anyopaque, runtime: *Runtime) anyerror!void;
const EventFn = *const fn (context: *anyopaque, runtime: *Runtime, event: Event) anyerror!void;
const SourceFn = *const fn (context: *anyopaque) anyerror!platform.WebViewSource;
const SceneFn = *const fn (context: *anyopaque) anyerror!app_manifest.ShellConfig;
const StopFn = *const fn (context: *anyopaque, runtime: *Runtime) anyerror!void;

pub const App = struct {
    context: *anyopaque,
    name: []const u8,
    source: platform.WebViewSource = platform.WebViewSource.html(""),
    source_fn: ?SourceFn = null,
    scene_fn: ?SceneFn = null,
    start_fn: ?StartFn = null,
    event_fn: ?EventFn = null,
    stop_fn: ?StopFn = null,

    pub fn start(self: App, runtime: *Runtime) anyerror!void {
        if (self.start_fn) |start_fn| try start_fn(self.context, runtime);
    }

    pub fn event(self: App, runtime: *Runtime, event_value: Event) anyerror!void {
        if (self.event_fn) |event_fn| try event_fn(self.context, runtime, event_value);
    }

    pub fn webViewSource(self: App) anyerror!platform.WebViewSource {
        if (self.source_fn) |source_fn| return source_fn(self.context);
        return self.source;
    }

    pub fn scene(self: App) anyerror!?app_manifest.ShellConfig {
        if (self.scene_fn) |scene_fn| return try scene_fn(self.context);
        return null;
    }

    pub fn stop(self: App, runtime: *Runtime) anyerror!void {
        if (self.stop_fn) |stop_fn| try stop_fn(self.context, runtime);
    }
};

pub const Options = struct {
    platform: platform.Platform,
    trace_sink: ?trace.Sink = null,
    log_path: ?[]const u8 = null,
    extensions: ?extensions.ModuleRegistry = null,
    bridge: ?bridge.Dispatcher = null,
    builtin_bridge: bridge.Policy = .{},
    security: security.Policy = .{},
    commands: []const Command = &.{},
    menus: []const platform.Menu = &.{},
    shortcuts: []const platform.Shortcut = &.{},
    automation: ?automation.Server = null,
    window_state_store: ?window_state.Store = null,
    js_window_api: bool = false,
    gpu_surface_frame_diagnostics: bool = true,
};

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
    shell_layouts: [platform.max_windows]RuntimeShellLayout = undefined,
    shell_layout_count: usize = 0,
    next_window_id: platform.WindowId = 2,
    next_view_id: platform.ViewId = 1,
    invalidated: bool = true,
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
    async_bridge_responses: [max_async_bridge_responses]AsyncBridgeResponseSlot = [_]AsyncBridgeResponseSlot{.{}} ** max_async_bridge_responses,
    automation_windows: [automation.snapshot.max_windows]automation.snapshot.Window = undefined,
    automation_views: [automation.snapshot.max_views]platform.ViewInfo = undefined,
    automation_widgets: [automation.snapshot.max_widgets]automation.snapshot.Widget = undefined,
    widget_event_route_entries: [canvas.max_widget_depth * 2]canvas.WidgetEventRouteEntry = undefined,
    canvas_widget_display_list_refresh_batch_depth: usize = 0,
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

    pub fn init(options: Options) Runtime {
        return .{
            .options = options,
            .surface = options.platform.surface(),
            .started_timestamp_ns = timestampToU64(nowNanoseconds()),
            .windows = undefined,
            .views = undefined,
            .shell_layouts = undefined,
        };
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

    pub fn run(self: *Runtime, app: App) anyerror!void {
        var init_fields: [3]trace.Field = undefined;
        init_fields[0] = trace.string("app", app.name);
        init_fields[1] = trace.string("platform", self.options.platform.name);
        var init_field_count: usize = 2;
        if (self.options.log_path) |log_path| {
            init_fields[init_field_count] = trace.string("log_path", log_path);
            init_field_count += 1;
        }
        try self.log("runtime.init", "runtime initialized", init_fields[0..init_field_count]);
        try app_manifest.validateCommands(self.options.commands);
        try self.options.platform.services.configureSecurityPolicy(self.options.security);
        try self.options.platform.services.configureMenus(self.options.menus);
        try self.options.platform.services.configureShortcuts(self.options.shortcuts);
        if (self.options.automation != null) {
            try self.options.platform.services.configureAutomationFramePolling(true);
        }
        defer if (self.options.automation != null) {
            self.options.platform.services.configureAutomationFramePolling(false) catch {};
        };

        var context: RunContext = .{ .runtime = self, .app = app };
        try self.options.platform.run(handlePlatformEvent, &context);

        try self.log("runtime.done", "runtime finished", &.{});
    }

    fn reservePrimaryStartupWindow(self: *Runtime) anyerror!void {
        const app_info = self.options.platform.app_info;
        if (app_info.startupWindowCount() == 0) return;
        const window = app_info.resolvedStartupWindow(0);
        if (self.findWindowIndexById(window.id) != null) return;

        const runtime_index = try self.reserveWindow(window.id, window.label, window.resolvedTitle(app_info.app_name), null, true);
        self.windows[runtime_index].info.frame = window.default_frame;
        self.windows[runtime_index].main_frame = geometry.RectF.init(0, 0, window.default_frame.width, window.default_frame.height);
        self.next_window_id = @max(self.next_window_id, window.id + 1);
    }

    pub fn createWindow(self: *Runtime, options: platform.WindowCreateOptions) anyerror!platform.WindowInfo {
        return self.createWindowWithSourceMode(options, options.source == null, .require_source);
    }

    pub fn listWindows(self: *const Runtime, output: []platform.WindowInfo) []const platform.WindowInfo {
        const count = @min(output.len, self.window_count);
        for (self.windows[0..count], 0..) |window, index| {
            output[index] = window.info;
        }
        return output[0..count];
    }

    pub fn focusWindow(self: *Runtime, window_id: platform.WindowId) anyerror!void {
        const index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        try self.options.platform.services.focusWindow(window_id);
        self.setFocusedIndex(index);
        self.invalidated = true;
    }

    pub fn closeWindow(self: *Runtime, window_id: platform.WindowId) anyerror!void {
        const index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        try self.options.platform.services.closeWindow(window_id);
        self.windows[index].info.open = false;
        self.windows[index].info.focused = false;
        self.removeWindowRuntimeViews(window_id);
        self.invalidated = true;
    }

    pub fn listCommands(self: *const Runtime, output: []Command) []const Command {
        const count = @min(output.len, self.options.commands.len);
        for (self.options.commands[0..count], 0..) |command, index| {
            output[index] = command;
        }
        return output[0..count];
    }

    pub fn createShellWindow(self: *Runtime, shell_window: app_manifest.ShellWindow, source: ?platform.WebViewSource) anyerror!platform.WindowInfo {
        return self.createShellWindowWithSourceMode(shell_window, source, source == null);
    }

    fn createShellWindowWithSourceMode(self: *Runtime, shell_window: app_manifest.ShellWindow, source: ?platform.WebViewSource, source_reloads_from_app: bool) anyerror!platform.WindowInfo {
        const window_frame = geometry.RectF.init(
            shell_window.x orelse 0,
            shell_window.y orelse 0,
            shell_window.width,
            shell_window.height,
        );
        const info = try self.createWindowWithSourceMode(.{
            .label = shell_window.label,
            .title = shell_window.title orelse "",
            .default_frame = window_frame,
            .resizable = shell_window.resizable,
            .restore_state = shell_window.restore_state,
            .restore_policy = shellRestorePolicy(shell_window.restore_policy),
            .source = source,
        }, source_reloads_from_app, .allow_source_less);
        errdefer self.closeWindow(info.id) catch {};

        try self.createShellViews(info.id, shell_window.views, self.shellBoundsForWindow(info.id));
        return info;
    }

    pub fn createShellViews(self: *Runtime, window_id: platform.WindowId, views: []const app_manifest.ShellView, bounds: geometry.RectF) anyerror!void {
        if (views.len > app_manifest.max_shell_views_per_window) return error.ViewLimitReached;
        try self.validateShellViewCreatePlan(window_id, views);

        var main_state: RuntimeMainWebViewState = undefined;
        try self.captureMainWebViewState(window_id, &main_state);
        errdefer self.restoreMainWebViewState(window_id, &main_state) catch {};

        var created_labels: [app_manifest.max_shell_views_per_window][]const u8 = undefined;
        var created_count: usize = 0;
        errdefer self.rollbackCreatedShellViews(window_id, created_labels[0..created_count]);

        try self.applyShellViews(window_id, views, bounds, .create, &created_labels, &created_count);
        try self.bindShellViews(window_id, views);
    }

    pub fn relayoutShellViews(self: *Runtime, window_id: platform.WindowId) anyerror!void {
        const binding = self.shellLayoutForWindow(window_id) orelse return;
        try self.applyShellViews(window_id, binding.viewSlice(), self.shellBoundsForWindow(window_id), .update, null, null);
    }

    fn validateShellViewCreatePlan(self: *Runtime, window_id: platform.WindowId, views: []const app_manifest.ShellView) anyerror!void {
        try self.validateViewParent(window_id);

        var native_view_count: usize = 0;
        var child_webview_count: usize = 0;
        for (views, 0..) |view, index| {
            for (views[0..index]) |previous| {
                if (std.mem.eql(u8, previous.label, view.label)) return error.DuplicateViewLabel;
            }

            if (view.kind == .webview and isMainWebViewLabel(view.label)) continue;
            if (self.viewLabelExists(window_id, view.label)) return error.DuplicateViewLabel;

            if (view.kind == .webview) {
                child_webview_count += 1;
            } else {
                native_view_count += 1;
            }
        }

        if (native_view_count > platform.max_views - self.view_count) return error.ViewLimitReached;
        if (child_webview_count > platform.max_webviews - self.webview_count) return error.WebViewLimitReached;
    }

    fn applyShellViews(self: *Runtime, window_id: platform.WindowId, views: []const app_manifest.ShellView, bounds: geometry.RectF, mode: ShellApplyMode, tracked_labels: ?*[app_manifest.max_shell_views_per_window][]const u8, tracked_count: ?*usize) anyerror!void {
        var layout = ShellLayout.init(bounds, views);
        var created: [app_manifest.max_shell_views_per_window]bool = [_]bool{false} ** app_manifest.max_shell_views_per_window;
        var created_count: usize = 0;
        while (created_count < views.len) {
            var progressed = false;
            for (views, 0..) |view, index| {
                if (created[index]) continue;
                if (view.parent) |parent| {
                    if (!layout.containsView(parent)) continue;
                }
                const did_create = try self.applyShellView(try shellViewOptions(window_id, view, &layout), mode);
                if (did_create) {
                    if (tracked_labels) |labels| {
                        const count = tracked_count.?;
                        labels[count.*] = view.label;
                        count.* += 1;
                    }
                }
                created[index] = true;
                created_count += 1;
                progressed = true;
            }
            if (!progressed) return error.InvalidViewOptions;
        }
    }

    fn applyShellView(self: *Runtime, options: platform.ViewOptions, mode: ShellApplyMode) anyerror!bool {
        switch (mode) {
            .create => {
                if (options.kind == .webview and isMainWebViewLabel(options.label)) {
                    try self.setMainWebViewParent(options.window_id, options.parent);
                    _ = try self.updateView(options.window_id, options.label, .{
                        .frame = options.frame,
                        .layer = options.layer,
                    });
                    return false;
                }
                _ = try self.createView(options);
                return true;
            },
            .update => {
                if (options.kind == .webview and isMainWebViewLabel(options.label)) {
                    try self.setMainWebViewParent(options.window_id, options.parent);
                }
                _ = self.updateView(options.window_id, options.label, .{
                    .frame = options.frame,
                    .layer = options.layer,
                }) catch |err| switch (err) {
                    error.ViewNotFound,
                    error.WebViewNotFound,
                    => return false,
                    else => return err,
                };
                return false;
            },
        }
    }

    fn rollbackCreatedShellViews(self: *Runtime, window_id: platform.WindowId, labels: []const []const u8) void {
        var index = labels.len;
        while (index > 0) {
            index -= 1;
            self.closeView(window_id, labels[index]) catch {};
        }
    }

    fn captureMainWebViewState(self: *Runtime, window_id: platform.WindowId, state: *RuntimeMainWebViewState) !void {
        const index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        const window = self.windows[index];
        state.* = .{
            .frame = window.main_frame,
            .frame_set = window.main_frame_set,
            .layer = window.main_layer,
        };
        state.parent = if (window.main_parent) |parent| try copyInto(&state.parent_storage, parent) else null;
    }

    fn restoreMainWebViewState(self: *Runtime, window_id: platform.WindowId, state: *const RuntimeMainWebViewState) !void {
        const index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        const window = self.windows[index];
        var restore_error: ?anyerror = null;

        if (window.source != null) {
            if (window.main_frame_set != state.frame_set or !rectsEqual(window.main_frame, state.frame)) {
                self.options.platform.services.setWebViewFrame(window_id, "main", state.frame) catch |err| {
                    restore_error = err;
                };
            }
            if (window.main_layer != state.layer) {
                self.options.platform.services.setWebViewLayer(window_id, "main", state.layer) catch |err| {
                    if (restore_error == null) restore_error = err;
                };
            }
        }

        self.windows[index].main_frame = state.frame;
        self.windows[index].main_frame_set = state.frame_set;
        self.windows[index].main_layer = state.layer;
        self.windows[index].main_parent = if (state.parent) |parent| try copyInto(&self.windows[index].main_parent_storage, parent) else null;

        if (restore_error) |err| return err;
    }

    pub fn createView(self: *Runtime, options: platform.ViewOptions) anyerror!platform.ViewInfo {
        try self.validateViewParent(options.window_id);
        try validateViewOptions(options);
        if (self.viewLabelExists(options.window_id, options.label)) return error.DuplicateViewLabel;
        try self.validateViewParentLink(options.window_id, options.label, options.parent);
        if (options.kind == .webview) return self.createWebViewView(options);
        if (self.view_count >= platform.max_views) return error.ViewLimitReached;

        try self.options.platform.services.createView(options);
        var reserved = false;
        errdefer {
            if (reserved) {
                if (self.findViewIndex(options.window_id, options.label)) |index| self.removeViewAt(index);
            }
            self.options.platform.services.closeView(options.window_id, options.label) catch {};
        }
        try self.reserveView(options);
        reserved = true;
        self.invalidateFor(.command, options.frame);
        return self.views[self.view_count - 1].info();
    }

    pub fn updateView(self: *Runtime, window_id: platform.WindowId, label: []const u8, patch: platform.ViewPatch) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        if (patch.frame) |view_frame| try validateViewFrame(view_frame);
        if (patch.role) |role| {
            if (role.len > platform.max_view_role_bytes) return error.ViewRoleTooLarge;
        }
        if (patch.accessibility_label) |accessibility_label| {
            if (accessibility_label.len > platform.max_view_accessibility_label_bytes) return error.ViewAccessibilityLabelTooLarge;
        }
        if (patch.text) |text| {
            if (text.len > platform.max_view_text_bytes) return error.ViewTextTooLarge;
        }
        if (patch.command) |command| {
            if (command.len > 0) try validateCommandName(command);
        }
        if (patch.url != null and !isMainWebViewLabel(label) and self.findWebViewIndex(window_id, label) == null) return error.InvalidViewOptions;

        if (isMainWebViewLabel(label) or self.findWebViewIndex(window_id, label) != null) {
            return self.updateWebViewView(window_id, label, patch);
        }

        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        try self.options.platform.services.updateView(window_id, label, patch);
        if (patch.frame) |view_frame| self.views[index].frame = view_frame;
        if (patch.layer) |layer| self.views[index].layer = layer;
        if (patch.visible) |visible| self.views[index].visible = visible;
        if (patch.enabled) |enabled| self.views[index].enabled = enabled;
        if (patch.role) |role| self.views[index].role = try copyInto(&self.views[index].role_storage, role);
        if (patch.accessibility_label) |accessibility_label| self.views[index].accessibility_label = try copyInto(&self.views[index].accessibility_label_storage, accessibility_label);
        if (patch.text) |text| self.views[index].text = try copyInto(&self.views[index].text_storage, text);
        if (patch.command) |command| self.views[index].command = try copyInto(&self.views[index].command_storage, command);
        if (patch.frame != null) try self.relayoutDescendantWebViewBackends(window_id, label);
        self.invalidateFor(.command, patch.frame);
        if (self.views[index].focused and !isFocusableViewInfo(self.views[index].info())) {
            self.ensureFocusableViewFocused(window_id);
        }
        return self.views[index].info();
    }

    pub fn closeView(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!void {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        if (isMainWebViewLabel(label)) return error.InvalidViewOptions;

        if (self.findWebViewIndex(window_id, label)) |webview_index| {
            const was_focused = self.webviews[webview_index].focused;
            try self.options.platform.services.closeWebView(window_id, label);
            self.removeWebViewAt(webview_index);
            if (was_focused) self.ensureFocusableViewFocused(window_id);
            self.invalidateFor(.command, null);
            return;
        }

        _ = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        const was_focused = self.viewTreeHasFocused(window_id, label);
        try self.closeDescendantWebViewBackends(window_id, label);
        try self.options.platform.services.closeView(window_id, label);
        self.removeDescendantViewsForParent(window_id, label);
        self.removeDescendantWebViewsForParent(window_id, label);
        if (self.findViewIndex(window_id, label)) |current_index| self.removeViewAt(current_index);
        if (was_focused) self.ensureFocusableViewFocused(window_id);
        self.invalidateFor(.command, null);
    }

    pub fn setCanvasDisplayList(self: *Runtime, window_id: platform.WindowId, label: []const u8, display_list: canvas.DisplayList) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        var canvas_changes: [max_canvas_diff_changes_per_view]canvas.DiffChange = undefined;
        const changes = try canvas.DisplayList.diff(self.views[index].canvasDisplayList(), display_list, &canvas_changes);
        try self.views[index].copyCanvasDisplayList(display_list);
        self.views[index].canvas_display_list_widget_owned = false;
        self.views[index].canvas_widget_display_list_prefix_count = 0;
        self.views[index].canvas_widget_display_list_suffix_count = 0;
        self.views[index].canvas_widget_display_list_reserved_count = 0;
        self.invalidateForCanvasChanges(self.views[index].frame, changes);
        if (changes.len > 0) try self.requestCanvasFrameForView(index);
        return self.views[index].info();
    }

    pub fn canvasDisplayList(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!canvas.DisplayList {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        return self.views[index].canvasDisplayList();
    }

    pub fn setCanvasRenderAnimations(self: *Runtime, window_id: platform.WindowId, label: []const u8, animations: []const canvas.CanvasRenderAnimation) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        try validateCanvasRenderAnimations(animations);
        try self.views[index].copyCanvasRenderAnimations(animations);
        self.invalidateFor(.state, self.views[index].frame);
        try self.requestCanvasFrameForView(index);
        return self.views[index].info();
    }

    pub fn clearCanvasRenderAnimations(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        if (self.views[index].canvas_render_animation_count == 0 and self.views[index].canvas_frame_render_override_count == 0) return self.views[index].info();
        self.views[index].canvas_render_animation_count = 0;
        self.invalidateFor(.state, self.views[index].frame);
        try self.requestCanvasFrameForView(index);
        return self.views[index].info();
    }

    pub fn canvasRenderAnimations(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror![]const canvas.CanvasRenderAnimation {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        return self.views[index].canvasRenderAnimations();
    }

    pub fn canvasRenderAnimationStartNs(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!u64 {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        return canvasRenderAnimationStartNsForView(&self.views[index]);
    }

    pub fn canvasFramePlan(self: *const Runtime, window_id: platform.WindowId, label: []const u8, previous: ?canvas.DisplayList, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage) anyerror!canvas.CanvasFrame {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

        var frame_options = options;
        if (frame_options.surface_size.isEmpty()) frame_options.surface_size = self.views[index].frame.size();
        return self.views[index].canvasDisplayList().framePlan(previous, frame_options, storage);
    }

    pub fn nextCanvasFrame(self: *Runtime, window_id: platform.WindowId, label: []const u8, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage) anyerror!canvas.CanvasFrame {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        return try self.planCanvasFrameForView(index, options, storage, true);
    }

    pub fn nextCanvasGpuPacket(self: *Runtime, window_id: platform.WindowId, label: []const u8, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage, output: []canvas.CanvasGpuCommand) anyerror!canvas.CanvasGpuPacket {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        const canvas_frame = try self.planCanvasFrameForView(index, options, storage, true);
        return try canvas_frame.gpuPacket(output);
    }

    pub fn presentNextCanvasGpuPacket(
        self: *Runtime,
        window_id: platform.WindowId,
        label: []const u8,
        options: canvas.CanvasFrameOptions,
        storage: canvas.CanvasFrameStorage,
        clear_color: canvas.Color,
        output: []canvas.CanvasGpuCommand,
        packet_json_buffer: []u8,
    ) anyerror!canvas.CanvasGpuPacket {
        return try self.presentNextCanvasGpuPacketWithScale(window_id, label, options, storage, clear_color, output, packet_json_buffer, null);
    }

    pub fn presentNextCanvasGpuPacketWithScale(
        self: *Runtime,
        window_id: platform.WindowId,
        label: []const u8,
        options: canvas.CanvasFrameOptions,
        storage: canvas.CanvasFrameStorage,
        clear_color: canvas.Color,
        output: []canvas.CanvasGpuCommand,
        packet_json_buffer: []u8,
        packet_scale: ?f32,
    ) anyerror!canvas.CanvasGpuPacket {
        const canvas_frame = try self.nextCanvasFrame(window_id, label, options, storage);
        var packet = try canvas_frame.gpuPacket(output);
        packet.scale = normalizedCanvasPresentationScale(packet_scale, canvas_frame.scale);
        if (!packet.requiresRender()) return packet;
        var writer = std.Io.Writer.fixed(packet_json_buffer);
        packet.writeJson(&writer) catch return error.UnsupportedService;
        try self.options.platform.services.presentGpuSurfacePacket(.{
            .window_id = window_id,
            .label = label,
            .frame_index = packet.frame_index,
            .timestamp_ns = packet.timestamp_ns,
            .surface_size = packet.surface_size,
            .scale_factor = packet.scale,
            .clear_color_rgba8 = canvasColorToRgba8(clear_color),
            .requires_render = packet.requiresRender(),
            .command_count = packet.commandCount(),
            .cache_action_count = packet.cacheActionCount(),
            .cached_resource_command_count = packet.cachedResourceCommandCount(),
            .unsupported_command_count = packet.unsupported_command_count,
            .representable = packet.fullyRepresentable(),
            .json = writer.buffered(),
        });
        if (self.findViewIndex(window_id, label)) |index| {
            self.views[index].recordCanvasFramePresentationComplete(canvas_frame);
        }
        return packet;
    }

    pub fn presentNextCanvasFrame(
        self: *Runtime,
        window_id: platform.WindowId,
        label: []const u8,
        options: canvas.CanvasFrameOptions,
        storage: canvas.CanvasFrameStorage,
        gpu_commands: []canvas.CanvasGpuCommand,
        packet_json_buffer: []u8,
        pixels: []u8,
        scratch: []u8,
        clear_color: canvas.Color,
        pixel_scale: ?f32,
    ) anyerror!CanvasPresentationResult {
        const canvas_frame = try self.nextCanvasFrame(window_id, label, options, storage);
        if (!canvas_frame.requiresRender()) {
            return .{ .frame = canvas_frame, .mode = .skipped };
        }

        if (gpu_commands.len > 0 and packet_json_buffer.len > 0 and self.options.platform.services.present_gpu_surface_packet_fn != null) {
            var packet = try canvas_frame.gpuPacket(gpu_commands);
            packet.scale = normalizedCanvasPresentationScale(pixel_scale, canvas_frame.scale);
            const result = CanvasPresentationResult{
                .frame = canvas_frame,
                .mode = .gpu_packet,
                .packet_command_count = packet.commandCount(),
                .packet_cache_action_count = packet.cacheActionCount(),
                .packet_cached_resource_command_count = packet.cachedResourceCommandCount(),
                .packet_unsupported_command_count = packet.unsupported_command_count,
                .packet_representable = packet.fullyRepresentable(),
            };
            if (packet.fullyRepresentable()) {
                var writer = std.Io.Writer.fixed(packet_json_buffer);
                const packet_presented = blk: {
                    packet.writeJson(&writer) catch break :blk false;
                    self.options.platform.services.presentGpuSurfacePacket(.{
                        .window_id = window_id,
                        .label = label,
                        .frame_index = packet.frame_index,
                        .timestamp_ns = packet.timestamp_ns,
                        .surface_size = packet.surface_size,
                        .scale_factor = packet.scale,
                        .clear_color_rgba8 = canvasColorToRgba8(clear_color),
                        .requires_render = packet.requiresRender(),
                        .command_count = packet.commandCount(),
                        .cache_action_count = packet.cacheActionCount(),
                        .cached_resource_command_count = packet.cachedResourceCommandCount(),
                        .unsupported_command_count = packet.unsupported_command_count,
                        .representable = packet.fullyRepresentable(),
                        .json = writer.buffered(),
                    }) catch |err| switch (err) {
                        error.UnsupportedService => break :blk false,
                        else => return err,
                    };
                    break :blk true;
                };
                if (packet_presented) {
                    if (self.findViewIndex(window_id, label)) |index| {
                        self.views[index].recordCanvasFramePresentationComplete(canvas_frame);
                    }
                    return result;
                }
            }
        }

        var pixel_frame = canvas_frame;
        if (pixel_scale) |scale| pixel_frame.scale = scale;
        try self.presentCanvasFramePixelsWithRecord(window_id, label, pixel_frame, canvas_frame, pixels, scratch, clear_color);
        return .{
            .frame = canvas_frame,
            .mode = .pixels,
            .packet_representable = false,
        };
    }

    pub fn presentCanvasFramePixels(
        self: *Runtime,
        window_id: platform.WindowId,
        label: []const u8,
        canvas_frame: canvas.CanvasFrame,
        pixels: []u8,
        scratch: []u8,
        clear_color: canvas.Color,
    ) anyerror!void {
        try self.presentCanvasFramePixelsWithRecord(window_id, label, canvas_frame, canvas_frame, pixels, scratch, clear_color);
    }

    fn presentCanvasFramePixelsWithRecord(
        self: *Runtime,
        window_id: platform.WindowId,
        label: []const u8,
        canvas_frame: canvas.CanvasFrame,
        record_frame: canvas.CanvasFrame,
        pixels: []u8,
        scratch: []u8,
        clear_color: canvas.Color,
    ) anyerror!void {
        if (!canvas_frame.requiresRender()) return;
        const pixel_size = try canvasFramePixelSize(canvas_frame);
        var surface = if (scratch.len >= pixel_size.byte_len)
            try canvas.ReferenceRenderSurface.initWithScratch(pixel_size.width, pixel_size.height, pixels, scratch)
        else
            try canvas.ReferenceRenderSurface.init(pixel_size.width, pixel_size.height, pixels);
        surface = surface.withImages(canvas_frame.image_resources);
        try surface.renderPass(canvas_frame.renderPass(), clear_color);
        try self.options.platform.services.presentGpuSurfacePixels(.{
            .window_id = window_id,
            .label = label,
            .width = pixel_size.width,
            .height = pixel_size.height,
            .scale_factor = canvas_frame.scale,
            .dirty_bounds = canvas_frame.dirty_bounds,
            .rgba8 = surface.pixels,
        });
        if (self.findViewIndex(window_id, label)) |index| {
            self.views[index].recordCanvasFramePresentationComplete(record_frame);
        }
    }

    pub fn presentNextCanvasFramePixels(
        self: *Runtime,
        window_id: platform.WindowId,
        label: []const u8,
        options: canvas.CanvasFrameOptions,
        storage: canvas.CanvasFrameStorage,
        pixels: []u8,
        scratch: []u8,
        clear_color: canvas.Color,
    ) anyerror!canvas.CanvasFrame {
        const canvas_frame = try self.nextCanvasFrame(window_id, label, options, storage);
        try self.presentCanvasFramePixels(window_id, label, canvas_frame, pixels, scratch, clear_color);
        return canvas_frame;
    }

    fn planCanvasFrameForView(self: *Runtime, index: usize, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage, record: bool) anyerror!canvas.CanvasFrame {
        var frame_options = options;
        if (frame_options.surface_size.isEmpty()) {
            frame_options.surface_size = if (self.views[index].gpu_size.isEmpty()) self.views[index].frame.size() else self.views[index].gpu_size;
        }
        if (canvasFrameBudgetIsUnset(frame_options.budget)) {
            frame_options.budget = self.views[index].canvas_frame_budget;
        }
        frame_options.previous_resource_cache = self.views[index].canvasFrameResourceCache();
        frame_options.previous_pipeline_cache = self.views[index].canvasFramePipelineCache();
        frame_options.previous_path_geometry_cache = self.views[index].canvasFramePathGeometryCache();
        frame_options.previous_image_cache = self.views[index].canvasFrameImageCache();
        frame_options.previous_layer_cache = self.views[index].canvasFrameLayerCache();
        frame_options.previous_visual_effect_cache = self.views[index].canvasFrameVisualEffectCache();
        frame_options.previous_glyph_atlas_cache = self.views[index].canvasFrameGlyphAtlasCache();
        frame_options.previous_text_layout_cache = self.views[index].canvasFrameTextLayoutCache();
        const scheduled_render_overrides = try self.views[index].sampleCanvasRenderAnimations(
            frame_options.timestamp_ns,
            &self.canvas_frame_render_override_samples,
        );
        const render_overrides = try mergeCanvasRenderOverrides(
            scheduled_render_overrides,
            frame_options.render_overrides,
            &self.canvas_frame_render_override_combined,
        );
        if (frame_options.previous_render_overrides.len == 0) {
            frame_options.previous_render_overrides = self.views[index].canvasFrameRenderOverrides();
        }
        frame_options.render_overrides = render_overrides;

        const display_list = self.views[index].canvasDisplayList();
        const canvas_changed = self.views[index].canvas_revision != self.views[index].presented_canvas_revision;
        const canvas_surface_changed = !sizesEqual(self.views[index].presented_canvas_surface_size, frame_options.surface_size) or
            self.views[index].presented_canvas_scale != frame_options.scale;
        if (!frame_options.full_repaint and
            self.views[index].presented_canvas_valid and
            !canvas_changed and
            !canvas_surface_changed and
            frame_options.previous_render_overrides.len == 0 and
            frame_options.render_overrides.len == 0)
        {
            const canvas_frame = canvas.CanvasFrame{
                .frame_index = frame_options.frame_index,
                .timestamp_ns = frame_options.timestamp_ns,
                .surface_size = frame_options.surface_size,
                .scale = frame_options.scale,
                .display_list = display_list,
                .image_resources = frame_options.image_resources,
                .changes = storage.changes[0..0],
                .budget = frame_options.budget,
            };
            self.views[index].recordCanvasFrame(canvas_frame);
            return canvas_frame;
        }

        var render_plan = try display_list.renderPlan(storage.render_commands);
        const render_override_dirty_bounds = canvas.renderOverrideDirtyBounds(render_plan.commands, frame_options.previous_render_overrides, frame_options.render_overrides);
        const render_animation_dirty_bounds = self.views[index].canvasRenderAnimationDirtyBoundsForOverrides(frame_options.previous_render_overrides, frame_options.render_overrides);
        render_plan.bounds = canvas.applyRenderOverrides(storage.render_commands[0..render_plan.commandCount()], frame_options.render_overrides);
        const batch_plan = try render_plan.batchPlan(storage.render_batches);
        const pipeline_cache_plan = if (storage.pipeline_cache_entries.len == 0 and storage.pipeline_cache_actions.len == 0)
            canvas.RenderPipelineCachePlan{}
        else
            try batch_plan.cachePlan(
                frame_options.previous_pipeline_cache,
                frame_options.frame_index,
                storage.pipeline_cache_entries,
                storage.pipeline_cache_actions,
            );
        const path_geometry_plan = if (storage.path_geometries.len == 0)
            canvas.RenderPathGeometryPlan{}
        else
            try render_plan.pathGeometryPlan(storage.path_geometries);
        const path_geometry_cache_plan = if (storage.path_geometry_cache_entries.len == 0 and storage.path_geometry_cache_actions.len == 0)
            canvas.RenderPathGeometryCachePlan{}
        else
            try path_geometry_plan.cachePlan(
                frame_options.previous_path_geometry_cache,
                frame_options.frame_index,
                storage.path_geometry_cache_entries,
                storage.path_geometry_cache_actions,
            );
        const image_plan = if (storage.images.len == 0)
            canvas.RenderImagePlan{}
        else
            try render_plan.imagePlanWithResources(frame_options.image_resources, storage.images);
        const image_cache_plan = if (storage.image_cache_entries.len == 0 and storage.image_cache_actions.len == 0)
            canvas.RenderImageCachePlan{}
        else
            try image_plan.cachePlan(
                frame_options.previous_image_cache,
                frame_options.frame_index,
                storage.image_cache_entries,
                storage.image_cache_actions,
            );
        const layer_plan = if (storage.layers.len == 0)
            canvas.RenderLayerPlan{}
        else
            try render_plan.layerPlan(storage.layers);
        const layer_cache_plan = if (storage.layer_cache_entries.len == 0 and storage.layer_cache_actions.len == 0)
            canvas.RenderLayerCachePlan{}
        else
            try layer_plan.cachePlan(
                frame_options.previous_layer_cache,
                frame_options.frame_index,
                storage.layer_cache_entries,
                storage.layer_cache_actions,
            );
        const resource_plan = try display_list.resourcePlan(storage.resources);
        const resource_cache_plan = try resource_plan.cachePlan(
            frame_options.previous_resource_cache,
            frame_options.frame_index,
            storage.resource_cache_entries,
            storage.resource_cache_actions,
        );
        const visual_effect_plan = if (storage.visual_effects.len == 0)
            canvas.VisualEffectPlan{}
        else
            try display_list.visualEffectPlan(storage.visual_effects);
        const visual_effect_cache_plan = if (storage.visual_effect_cache_entries.len == 0 and storage.visual_effect_cache_actions.len == 0)
            canvas.VisualEffectCachePlan{}
        else
            try visual_effect_plan.cachePlan(
                frame_options.previous_visual_effect_cache,
                frame_options.frame_index,
                storage.visual_effect_cache_entries,
                storage.visual_effect_cache_actions,
            );
        const glyph_atlas_plan = try display_list.glyphAtlasPlan(storage.glyph_atlas_entries);
        const glyph_atlas_cache_plan = try glyph_atlas_plan.cachePlanWithRetention(
            frame_options.previous_glyph_atlas_cache,
            frame_options.frame_index,
            frame_options.glyph_atlas_cache_retention_frames,
            storage.glyph_atlas_cache_entries,
            storage.glyph_atlas_cache_actions,
        );
        const text_layout_plan = try display_list.textLayoutPlan(frame_options.text_layout_options, storage.text_layout_plans, storage.text_layout_lines);
        const text_layout_cache_plan = if (storage.text_layout_cache_entries.len == 0 and storage.text_layout_cache_actions.len == 0)
            canvas.TextLayoutCachePlan{}
        else
            try text_layout_plan.cachePlanWithRetention(
                frame_options.previous_text_layout_cache,
                frame_options.frame_index,
                frame_options.text_layout_cache_retention_frames,
                storage.text_layout_cache_entries,
                storage.text_layout_cache_actions,
            );

        const full_repaint = frame_options.full_repaint or
            !self.views[index].presented_canvas_valid or
            canvas_surface_changed or
            (canvas_changed and (self.views[index].presented_canvas_has_unkeyed or self.views[index].currentCanvasHasUnkeyed()));
        const changes = if (full_repaint)
            storage.changes[0..0]
        else
            try self.views[index].diffPresentedCanvasSummary(storage.changes);
        const dirty_bounds = if (full_repaint)
            canvasFullRepaintBounds(frame_options.surface_size, render_plan.bounds)
        else
            clippedCanvasDirtyBounds(unionRects(canvasDirtyBoundsFromChanges(changes), unionRects(render_override_dirty_bounds, render_animation_dirty_bounds)), frame_options.surface_size);

        const canvas_frame = canvas.CanvasFrame{
            .frame_index = frame_options.frame_index,
            .timestamp_ns = frame_options.timestamp_ns,
            .surface_size = frame_options.surface_size,
            .scale = frame_options.scale,
            .full_repaint = full_repaint,
            .display_list = display_list,
            .render_plan = render_plan,
            .batch_plan = batch_plan,
            .pipeline_cache_plan = pipeline_cache_plan,
            .path_geometry_plan = path_geometry_plan,
            .path_geometry_cache_plan = path_geometry_cache_plan,
            .image_plan = image_plan,
            .image_cache_plan = image_cache_plan,
            .layer_plan = layer_plan,
            .layer_cache_plan = layer_cache_plan,
            .resource_plan = resource_plan,
            .resource_cache_plan = resource_cache_plan,
            .visual_effect_plan = visual_effect_plan,
            .visual_effect_cache_plan = visual_effect_cache_plan,
            .glyph_atlas_plan = glyph_atlas_plan,
            .glyph_atlas_cache_plan = glyph_atlas_cache_plan,
            .text_layout_plan = text_layout_plan,
            .text_layout_cache_plan = text_layout_cache_plan,
            .image_resources = frame_options.image_resources,
            .changes = changes,
            .dirty_bounds = dirty_bounds,
            .budget = frame_options.budget,
        };
        if (record) {
            try self.views[index].copyCanvasFramePipelineCache(canvas_frame.pipeline_cache_plan.entries);
            try self.views[index].copyCanvasFramePathGeometryCache(canvas_frame.path_geometry_cache_plan.entries);
            try self.views[index].copyCanvasFrameImageCache(canvas_frame.image_cache_plan.entries);
            try self.views[index].copyCanvasFrameLayerCache(canvas_frame.layer_cache_plan.entries);
            try self.views[index].copyCanvasFrameResourceCache(canvas_frame.resource_cache_plan.entries);
            try self.views[index].copyCanvasFrameVisualEffectCache(canvas_frame.visual_effect_cache_plan.entries);
            try self.views[index].copyCanvasFrameGlyphAtlasCache(canvas_frame.glyph_atlas_cache_plan.entries);
            try self.views[index].copyCanvasFrameTextLayoutCache(canvas_frame.text_layout_cache_plan.entries);
            try self.views[index].copyPresentedCanvasSummary(display_list, canvas_frame.surface_size, canvas_frame.scale);
            self.views[index].recordCanvasFrame(canvas_frame);
            try self.views[index].copyCanvasFrameRenderOverrides(frame_options.render_overrides);
            if (self.views[index].pruneCompletedNoopCanvasRenderAnimations(frame_options.timestamp_ns)) {
                self.views[index].compactCanvasFrameRenderOverrideNoops();
            }
            if (self.views[index].canvasRenderAnimationsActive(frame_options.timestamp_ns)) {
                self.invalidateFor(.state, self.views[index].frame);
            }
        } else {
            self.views[index].recordCanvasFrame(canvas_frame);
        }
        return canvas_frame;
    }

    fn canvasFrameScratchStorage(self: *Runtime) canvas.CanvasFrameStorage {
        return .{
            .render_commands = &self.canvas_frame_render_commands,
            .render_batches = &self.canvas_frame_render_batches,
            .pipeline_cache_entries = &self.canvas_frame_pipeline_cache_entries,
            .pipeline_cache_actions = &self.canvas_frame_pipeline_cache_actions,
            .path_geometries = &self.canvas_frame_path_geometries,
            .path_geometry_cache_entries = &self.canvas_frame_path_geometry_cache_entries,
            .path_geometry_cache_actions = &self.canvas_frame_path_geometry_cache_actions,
            .images = &self.canvas_frame_images,
            .image_cache_entries = &self.canvas_frame_image_cache_entries,
            .image_cache_actions = &self.canvas_frame_image_cache_actions,
            .layers = &self.canvas_frame_layers,
            .layer_cache_entries = &self.canvas_frame_layer_cache_entries,
            .layer_cache_actions = &self.canvas_frame_layer_cache_actions,
            .resources = &self.canvas_frame_resources,
            .resource_cache_entries = &self.canvas_frame_resource_cache_entries,
            .resource_cache_actions = &self.canvas_frame_resource_cache_actions,
            .visual_effects = &self.canvas_frame_visual_effects,
            .visual_effect_cache_entries = &self.canvas_frame_visual_effect_cache_entries,
            .visual_effect_cache_actions = &self.canvas_frame_visual_effect_cache_actions,
            .glyph_atlas_entries = &self.canvas_frame_glyph_atlas_entries,
            .glyph_atlas_cache_entries = &self.canvas_frame_glyph_atlas_cache_entries,
            .glyph_atlas_cache_actions = &self.canvas_frame_glyph_atlas_cache_actions,
            .text_layout_plans = &canvas_frame_text_layout_plans_scratch,
            .text_layout_lines = &canvas_frame_text_layout_lines_scratch,
            .text_layout_cache_entries = &canvas_frame_text_layout_cache_entries_scratch,
            .text_layout_cache_actions = &canvas_frame_text_layout_cache_actions_scratch,
            .changes = &self.canvas_frame_changes,
        };
    }

    pub fn gpuSurfaceFrame(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!platform.GpuFrame {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        return self.views[index].info().gpuFrame() orelse error.InvalidViewOptions;
    }

    pub fn setCanvasFrameBudget(self: *Runtime, window_id: platform.WindowId, label: []const u8, budget: canvas.CanvasFrameBudget) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        self.views[index].canvas_frame_budget = budget;
        self.views[index].refreshCanvasFrameBudgetStatus();
        return self.views[index].info();
    }

    pub fn setGpuSurfaceInputLatencyBudget(self: *Runtime, window_id: platform.WindowId, label: []const u8, budget_ns: u64) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        self.views[index].gpu_input_latency_budget_ns = budget_ns;
        self.views[index].gpu_input_latency_budget_custom = true;
        self.views[index].refreshGpuSurfaceInputLatencyBudgetStatus();
        return self.views[index].info();
    }

    pub fn setCanvasWidgetLayout(self: *Runtime, window_id: platform.WindowId, label: []const u8, layout: canvas.WidgetLayoutTree) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        if (layout.nodes.len > max_canvas_widget_nodes_per_view) return error.WidgetNodeLimitReached;
        const previous_layout = self.views[index].widgetLayoutTree();
        var source_semantics_buffer: [max_canvas_widget_semantics_per_view]canvas.WidgetSemanticsNode = undefined;
        const source_semantics = try layout.collectSemantics(&source_semantics_buffer);
        var reconciled_nodes: [max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode = undefined;
        var previous_control_entries: [max_canvas_widget_nodes_per_view]CanvasWidgetControlReconcileEntry = undefined;
        var previous_text_entries: [max_canvas_widget_nodes_per_view]CanvasWidgetTextReconcileEntry = undefined;
        var previous_text_bytes: [max_canvas_widget_text_bytes_per_view]u8 = undefined;
        const tokens = self.views[index].widget_tokens;
        const reconciled_layout = try canvasWidgetLayoutTreeWithRuntimeReconcileState(
            previous_layout,
            layout,
            source_semantics,
            self.views[index].widgetSourceTextEntries(),
            &reconciled_nodes,
            &previous_control_entries,
            &previous_text_entries,
            &previous_text_bytes,
            tokens,
        );
        var widget_invalidations: [max_canvas_widget_invalidations_per_view]canvas.WidgetInvalidation = undefined;
        const invalidations = try canvas.WidgetLayoutTree.diffWithTokens(previous_layout, reconciled_layout, tokens, &widget_invalidations);
        const previous_render_state = self.views[index].canvasWidgetRenderState();
        const next_render_state = canvasWidgetRenderStateAfterLayout(previous_render_state, reconciled_layout);
        const render_state_changed = !canvasWidgetRenderStatesEqual(previous_render_state, next_render_state);
        const render_state_dirty = if (render_state_changed)
            previous_layout.renderStateDirtyBoundsWithTokens(previous_render_state, next_render_state, tokens)
        else
            null;
        const previous_cursor = self.views[index].canvas_widget_cursor;
        const previous_widget_revision = self.views[index].widget_revision;
        try self.views[index].copyWidgetLayoutTree(reconciled_layout);
        try self.views[index].copyCanvasWidgetSourceText(layout);
        const widget_revision_changed = self.views[index].widget_revision != previous_widget_revision;
        if (previous_cursor != self.views[index].canvas_widget_cursor) try self.syncCanvasWidgetCursorForView(index);
        self.invalidateForWidgetInvalidations(self.views[index].frame, invalidations);
        if (render_state_changed) self.invalidateForCanvasWidgetRenderStateDirty(index, render_state_dirty);
        const layout_dirty = invalidations.len > 0 or render_state_changed;
        const requested_frame = try self.refreshCanvasWidgetDisplayListIfOwned(index);
        if ((layout_dirty or widget_revision_changed) and !requested_frame) try self.requestCanvasFrameForView(index);
        return self.views[index].info();
    }

    pub fn canvasWidgetLayout(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!canvas.WidgetLayoutTree {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        return self.views[index].widgetLayoutTree();
    }

    pub fn canvasWidgetSemantics(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror![]const canvas.WidgetSemanticsNode {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        return self.views[index].widgetSemantics();
    }

    pub fn dispatchCanvasWidgetAccessibilityAction(self: *Runtime, app: App, window_id: platform.WindowId, label: []const u8, action: CanvasWidgetAccessibilityAction) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        if (action.id == 0) return error.InvalidCommand;
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        const actions = self.canvasWidgetActionsForId(index, action.id) orelse return error.InvalidCommand;
        if (!canvasWidgetAccessibilityActionSupported(actions, action.action)) return error.InvalidCommand;

        if (canvasWidgetAccessibilitySemanticAction(action.action)) |semantic_action| {
            if (try self.dispatchCanvasWidgetSemanticControlAction(app, index, action.id, semantic_action, actions)) {
                return self.views[index].info();
            }
        }

        switch (action.action) {
            .focus => try self.focusAutomationCanvasWidget(index, action.id),
            .press => try self.dispatchAutomationWidgetKey(app, index, action.id, "enter"),
            .toggle => try self.dispatchAutomationWidgetKey(app, index, action.id, "space"),
            .increment => try self.dispatchAutomationWidgetKey(app, index, action.id, self.views[index].canvasWidgetStepKey(action.id, .increment)),
            .decrement => try self.dispatchAutomationWidgetKey(app, index, action.id, self.views[index].canvasWidgetStepKey(action.id, .decrement)),
            .set_text => try self.setAutomationCanvasWidgetText(index, action.id, action.text),
            .set_selection => try self.editAutomationCanvasWidgetText(index, action.id, .{ .set_selection = action.selection orelse return error.InvalidCommand }),
            .set_composition => try self.editAutomationCanvasWidgetText(index, action.id, .{ .set_composition = .{ .text = action.text } }),
            .commit_composition => try self.editAutomationCanvasWidgetText(index, action.id, .commit_composition),
            .cancel_composition => try self.editAutomationCanvasWidgetText(index, action.id, .cancel_composition),
            .select => try self.selectAutomationCanvasWidget(index, action.id),
            .drag => try self.dispatchAutomationCanvasWidgetDrag(app, index, action.id, action.text),
            .drop_files => try self.dispatchAutomationCanvasWidgetFileDrop(app, index, action.id, action.text),
            .dismiss => try self.dismissAutomationCanvasWidget(index, action.id),
        }
        return self.views[index].info();
    }

    pub fn stepCanvasWidgetKineticScroll(self: *Runtime, window_id: platform.WindowId, label: []const u8, dt_ms: f32) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

        const dirty = try self.views[index].stepCanvasWidgetKineticScroll(dt_ms) orelse return self.views[index].info();
        const previous_cursor = self.views[index].canvas_widget_cursor;
        self.views[index].reconcileCanvasWidgetRenderStateAfterScroll(null);
        if (previous_cursor != self.views[index].canvas_widget_cursor) try self.syncCanvasWidgetCursorForView(index);
        try self.invalidateForCanvasWidgetDirty(index, dirty);
        _ = try self.refreshCanvasWidgetDisplayListIfOwned(index);
        return self.views[index].info();
    }

    pub fn setCanvasWidgetDesignTokens(self: *Runtime, window_id: platform.WindowId, label: []const u8, tokens: canvas.DesignTokens) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        if (std.meta.eql(self.views[index].widget_tokens, tokens)) return self.views[index].info();
        self.views[index].widget_tokens = tokens;
        self.views[index].widget_revision += 1;
        if (self.views[index].canvas_display_list_widget_owned) {
            _ = try self.refreshCanvasWidgetDisplayList(index);
        }
        return self.views[index].info();
    }

    pub fn canvasWidgetDesignTokens(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!canvas.DesignTokens {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        return self.views[index].widget_tokens;
    }

    pub fn canvasWidgetTextGeometry(self: *const Runtime, window_id: platform.WindowId, label: []const u8, id: canvas.ObjectId) anyerror!canvas.WidgetTextGeometry {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        if (id == 0) return error.InvalidCommand;
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        const node = self.views[index].widgetLayoutTree().findById(id) orelse return error.InvalidCommand;
        if (!canvasWidgetEditableTextKind(node.widget.kind)) return error.InvalidCommand;
        return canvas.textGeometryForWidget(node.widget, self.views[index].widget_tokens);
    }

    pub fn editCanvasWidgetText(self: *Runtime, window_id: platform.WindowId, label: []const u8, id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        if (id == 0) return error.InvalidCommand;
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        if (!self.views[index].canEditCanvasWidgetText(id)) return error.InvalidCommand;

        const dirty = try self.views[index].applyCanvasWidgetTextEdit(id, edit) orelse return self.views[index].info();
        try self.invalidateForCanvasWidgetDirty(index, dirty);
        _ = try self.refreshCanvasWidgetDisplayListIfOwned(index);
        return self.views[index].info();
    }

    pub fn emitCanvasWidgetDisplayList(self: *Runtime, window_id: platform.WindowId, label: []const u8, tokens: canvas.DesignTokens) anyerror!platform.ViewInfo {
        return self.emitCanvasWidgetDisplayListWithChrome(window_id, label, tokens, .{});
    }

    pub fn emitCanvasWidgetDisplayListWithStoredTokens(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!platform.ViewInfo {
        return self.emitCanvasWidgetDisplayListWithStoredTokensAndChrome(window_id, label, .{});
    }

    pub fn emitCanvasWidgetDisplayListWithChrome(self: *Runtime, window_id: platform.WindowId, label: []const u8, tokens: canvas.DesignTokens, chrome: CanvasWidgetDisplayListChrome) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        if (!std.meta.eql(self.views[index].widget_tokens, tokens)) {
            self.views[index].widget_tokens = tokens;
            self.views[index].widget_revision += 1;
        }

        return self.emitCanvasWidgetDisplayListForViewWithChrome(index, chrome);
    }

    pub fn emitCanvasWidgetDisplayListWithStoredTokensAndChrome(self: *Runtime, window_id: platform.WindowId, label: []const u8, chrome: CanvasWidgetDisplayListChrome) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

        return self.emitCanvasWidgetDisplayListForViewWithChrome(index, chrome);
    }

    fn emitCanvasWidgetDisplayListForViewWithChrome(self: *Runtime, index: usize, chrome: CanvasWidgetDisplayListChrome) anyerror!platform.ViewInfo {
        try self.views[index].validateCanvasWidgetDisplayListChrome(chrome);
        const previous_prefix_count = self.views[index].canvas_widget_display_list_prefix_count;
        const previous_suffix_count = self.views[index].canvas_widget_display_list_suffix_count;
        const previous_reserved_count = self.views[index].canvas_widget_display_list_reserved_count;
        const previous_owned = self.views[index].canvas_display_list_widget_owned;
        errdefer {
            self.views[index].canvas_widget_display_list_prefix_count = previous_prefix_count;
            self.views[index].canvas_widget_display_list_suffix_count = previous_suffix_count;
            self.views[index].canvas_widget_display_list_reserved_count = previous_reserved_count;
            self.views[index].canvas_display_list_widget_owned = previous_owned;
        }
        self.views[index].canvas_widget_display_list_prefix_count = chrome.prefix_command_count;
        self.views[index].canvas_widget_display_list_suffix_count = chrome.suffix_command_count;
        self.views[index].canvas_widget_display_list_reserved_count = chrome.reserved_command_count;
        _ = try self.refreshCanvasWidgetDisplayList(index);
        self.views[index].canvas_display_list_widget_owned = true;
        try self.publishCanvasWidgetAccessibility(index);
        return self.views[index].info();
    }

    fn refreshCanvasWidgetDisplayListIfOwned(self: *Runtime, view_index: usize) anyerror!bool {
        return self.refreshCanvasWidgetDisplayListIfOwnedWithAccessibility(view_index, true);
    }

    fn refreshCanvasWidgetDisplayListIfOwnedSkippingAccessibility(self: *Runtime, view_index: usize) anyerror!bool {
        return self.refreshCanvasWidgetDisplayListIfOwnedWithAccessibility(view_index, false);
    }

    fn refreshCanvasWidgetDisplayListIfOwnedWithAccessibility(self: *Runtime, view_index: usize, publish_accessibility: bool) anyerror!bool {
        if (self.canvas_widget_display_list_refresh_batch_depth > 0) {
            if (view_index >= self.canvas_widget_display_list_refresh_pending.len) return false;
            self.canvas_widget_display_list_refresh_pending[view_index] = true;
            self.canvas_widget_accessibility_publish_pending[view_index] = self.canvas_widget_accessibility_publish_pending[view_index] or publish_accessibility;
            return false;
        }
        return self.refreshCanvasWidgetDisplayListIfOwnedWithAccessibilityImmediate(view_index, publish_accessibility);
    }

    fn refreshCanvasWidgetDisplayListIfOwnedWithAccessibilityImmediate(self: *Runtime, view_index: usize, publish_accessibility: bool) anyerror!bool {
        if (view_index >= self.view_count) return false;
        if (self.views[view_index].kind != .gpu_surface) return false;
        if (publish_accessibility) try self.publishCanvasWidgetAccessibility(view_index);
        if (!self.views[view_index].canvas_display_list_widget_owned) return false;
        return self.refreshCanvasWidgetDisplayList(view_index);
    }

    fn beginCanvasWidgetDisplayListRefreshBatch(self: *Runtime) void {
        self.canvas_widget_display_list_refresh_batch_depth += 1;
    }

    fn cancelCanvasWidgetDisplayListRefreshBatch(self: *Runtime) void {
        if (self.canvas_widget_display_list_refresh_batch_depth == 0) return;
        self.canvas_widget_display_list_refresh_batch_depth -= 1;
        if (self.canvas_widget_display_list_refresh_batch_depth != 0) return;
        for (0..self.canvas_widget_display_list_refresh_pending.len) |index| {
            self.canvas_widget_display_list_refresh_pending[index] = false;
            self.canvas_widget_accessibility_publish_pending[index] = false;
        }
    }

    fn endCanvasWidgetDisplayListRefreshBatch(self: *Runtime) anyerror!void {
        if (self.canvas_widget_display_list_refresh_batch_depth == 0) return;
        self.canvas_widget_display_list_refresh_batch_depth -= 1;
        if (self.canvas_widget_display_list_refresh_batch_depth != 0) return;

        const count = @min(self.view_count, self.canvas_widget_display_list_refresh_pending.len);
        for (0..count) |index| {
            if (!self.canvas_widget_display_list_refresh_pending[index]) continue;
            const publish_accessibility = self.canvas_widget_accessibility_publish_pending[index];
            self.canvas_widget_display_list_refresh_pending[index] = false;
            self.canvas_widget_accessibility_publish_pending[index] = false;
            _ = try self.refreshCanvasWidgetDisplayListIfOwnedWithAccessibilityImmediate(index, publish_accessibility);
        }
    }

    fn requestCanvasFrameForView(self: *Runtime, view_index: usize) anyerror!void {
        if (view_index >= self.view_count) return;
        if (self.views[view_index].kind != .gpu_surface) return;
        self.options.platform.services.requestGpuSurfaceFrame(
            self.views[view_index].window_id,
            self.views[view_index].label,
        ) catch |err| switch (err) {
            error.UnsupportedService => return,
            else => return err,
        };
    }

    fn advanceCanvasWidgetKineticScrollForFrame(self: *Runtime, view_index: usize, frame_interval_ns: u64, skip_step: bool) anyerror!void {
        if (view_index >= self.view_count) return;
        if (self.views[view_index].kind != .gpu_surface) return;
        if (!self.views[view_index].canvasWidgetKineticScrollActive()) return;

        if (skip_step) {
            try self.requestCanvasFrameForView(view_index);
            return;
        }

        _ = try self.stepCanvasWidgetKineticScroll(
            self.views[view_index].window_id,
            self.views[view_index].label,
            canvasWidgetKineticScrollFrameMs(frame_interval_ns),
        );
    }

    fn scheduleCanvasWidgetToggleAnimation(self: *Runtime, view_index: usize, animation: CanvasWidgetToggleAnimation) anyerror!void {
        if (view_index >= self.view_count) return;
        if (self.views[view_index].kind != .gpu_surface) return;
        if (animation.id == 0 or animation.travel <= 0) return;

        const motion = self.views[view_index].widget_tokens.motion;
        const duration_ms = motion.durationMs(.fast);
        if (duration_ms == 0) {
            self.views[view_index].removeCanvasRenderAnimation(canvas.toggleWidgetKnobCommandId(animation.id));
            return;
        }

        const from_tx = if (animation.selected) animation.travel else -animation.travel;
        const render_animation = motion.animation(.{
            .id = canvas.toggleWidgetKnobCommandId(animation.id),
            .start_ns = canvasRenderAnimationStartNsForView(&self.views[view_index]),
            .duration = .fast,
            .from_transform = canvas.Affine.translate(from_tx, 0),
            .to_transform = canvas.Affine.identity(),
        });
        self.views[view_index].replaceCanvasRenderAnimation(render_animation) catch |err| switch (err) {
            error.RenderAnimationListFull => return,
            else => return err,
        };
        self.views[view_index].replaceCanvasRenderAnimationDirtyBounds(render_animation.id, animation.dirty_bounds) catch {};
    }

    fn publishCanvasWidgetAccessibility(self: *Runtime, view_index: usize) anyerror!void {
        if (view_index >= self.view_count) return;
        const view = &self.views[view_index];
        if (view.kind != .gpu_surface) return;
        var nodes: [platform.max_widget_accessibility_nodes]platform.WidgetAccessibilityNode = undefined;
        const semantics = view.widgetSemantics();
        const count = @min(semantics.len, nodes.len);
        for (semantics[0..count], 0..) |node, index| {
            nodes[index] = .{
                .id = node.id,
                .parent_id = canvasWidgetSemanticParentId(semantics, node.parent_index),
                .role = platformWidgetAccessibilityRole(node.role),
                .label = node.label,
                .text_value = node.text_value,
                .placeholder = node.placeholder,
                .text_selection = platformWidgetAccessibilityTextRange(node.text_selection),
                .text_composition = platformWidgetAccessibilityTextRange(node.text_composition),
                .value = node.value,
                .bounds = node.bounds,
                .grid_row_index = node.grid_row_index,
                .grid_column_index = node.grid_column_index,
                .grid_row_count = node.grid_row_count,
                .grid_column_count = node.grid_column_count,
                .list_item_index = if (node.list.present) node.list.item_index else null,
                .list_item_count = if (node.list.present) node.list.item_count else null,
                .scroll_offset = if (node.scroll.present) node.scroll.offset else null,
                .scroll_viewport_extent = if (node.scroll.present) node.scroll.viewport_extent else null,
                .scroll_content_extent = if (node.scroll.present) node.scroll.content_extent else null,
                .enabled = !node.state.disabled,
                .focused = node.state.focused or (view.focused and node.id == view.canvas_widget_focused_id),
                .hovered = node.state.hovered or (node.id != 0 and node.id == view.canvas_widget_hovered_id),
                .pressed = node.state.pressed or (node.id != 0 and node.id == view.canvas_widget_pressed_id),
                .selected = canvasWidgetSelectedState(node),
                .expanded = node.state.expanded,
                .required = node.state.required,
                .read_only = node.state.read_only,
                .invalid = node.state.invalid,
                .focusable = node.focusable,
                .actions = platformWidgetAccessibilityActions(node.actions),
            };
        }
        try self.options.platform.services.updateWidgetAccessibility(.{
            .window_id = view.window_id,
            .view_label = view.label,
            .nodes = nodes[0..count],
        });
    }

    fn refreshCanvasWidgetDisplayList(self: *Runtime, view_index: usize) anyerror!bool {
        if (view_index >= self.view_count) return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;

        var commands: [max_canvas_commands_per_view]canvas.CanvasCommand = undefined;
        var chrome_storage = CanvasDisplayListScratch{};
        var builder = canvas.Builder.init(&commands);
        const current = self.views[view_index].canvasDisplayList();
        const prefix_count = self.views[view_index].canvas_widget_display_list_prefix_count;
        const suffix_count = self.views[view_index].canvas_widget_display_list_suffix_count;
        if (prefix_count > current.commands.len or suffix_count > current.commands.len - prefix_count) return error.InvalidCommand;
        for (current.commands[0..prefix_count]) |command| try chrome_storage.appendCopiedCommand(&builder, command);
        try self.views[view_index].widgetLayoutTree().emitDisplayListWithState(&builder, self.views[view_index].widget_tokens, self.views[view_index].canvasWidgetRenderState());
        const suffix_start = current.commands.len - suffix_count;
        for (current.commands[suffix_start..current.commands.len]) |command| try chrome_storage.appendCopiedCommand(&builder, command);

        const display_list = builder.displayList();
        if (display_list.commands.len + self.views[view_index].canvas_widget_display_list_reserved_count > max_canvas_commands_per_view) {
            return error.CanvasCommandLimitReached;
        }
        var canvas_changes: [max_canvas_diff_changes_per_view]canvas.DiffChange = undefined;
        const changes = try canvas.DisplayList.diff(self.views[view_index].canvasDisplayList(), display_list, &canvas_changes);
        try self.views[view_index].copyCanvasDisplayList(display_list);
        self.invalidateForCanvasChanges(self.views[view_index].frame, changes);
        if (changes.len > 0) {
            try self.requestCanvasFrameForView(view_index);
            return true;
        }
        return false;
    }

    pub fn routeCanvasWidgetPointerInput(self: *const Runtime, input_event: GpuSurfaceInputEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetPointerEvent {
        try self.validateViewParent(input_event.window_id);
        try validateViewLabel(input_event.label);
        var pointer = canvasWidgetPointerEventFromGpuInput(input_event) orelse return null;
        const index = self.findViewIndex(input_event.window_id, input_event.label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        switch (pointer.phase) {
            .move, .up, .cancel => {
                if (self.views[index].canvas_widget_pressed_id != 0) {
                    pointer.captured_id = self.views[index].canvas_widget_pressed_id;
                }
            },
            .hover, .down, .wheel => {},
        }

        const route = try self.views[index].widgetLayoutTree().routePointerEventWithTokens(pointer, self.views[index].widget_tokens, output);
        return .{
            .window_id = input_event.window_id,
            .view_label = self.views[index].label,
            .pointer = pointer,
            .target = route.target,
            .route = route.entries,
        };
    }

    pub fn routeCanvasWidgetKeyboardInput(self: *const Runtime, input_event: GpuSurfaceInputEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetKeyboardEvent {
        try self.validateViewParent(input_event.window_id);
        try validateViewLabel(input_event.label);
        const index = self.findViewIndex(input_event.window_id, input_event.label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        if (!self.views[index].focused) return null;
        const focused_id = self.views[index].canvas_widget_focused_id;
        if (focused_id == 0) return null;
        const keyboard = canvasWidgetKeyboardEventFromGpuInput(input_event, focused_id) orelse return null;

        const route = try self.views[index].widgetLayoutTree().routeKeyboardEvent(keyboard, output);
        if (route.target == null) return null;
        return .{
            .window_id = input_event.window_id,
            .view_label = self.views[index].label,
            .keyboard = keyboard,
            .target = route.target,
            .route = route.entries,
        };
    }

    pub fn routeCanvasWidgetTextInput(self: *const Runtime, input_event: GpuSurfaceInputEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetKeyboardEvent {
        try self.validateViewParent(input_event.window_id);
        try validateViewLabel(input_event.label);
        const index = self.findViewIndex(input_event.window_id, input_event.label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        if (!self.views[index].focused) return null;
        const focused_id = self.views[index].canvas_widget_focused_id;
        if (focused_id == 0) return null;
        const keyboard = canvasWidgetTextInputEventFromGpuInput(input_event, focused_id) orelse return null;

        const route = try self.views[index].widgetLayoutTree().routeKeyboardEvent(keyboard, output);
        if (route.target == null) return null;
        return .{
            .window_id = input_event.window_id,
            .view_label = self.views[index].label,
            .keyboard = keyboard,
            .target = route.target,
            .route = route.entries,
        };
    }

    pub fn routeCanvasWidgetFileDrop(self: *const Runtime, drop: platform.FileDropEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetFileDropEvent {
        try self.validateViewParent(drop.window_id);
        if (drop.view_label.len == 0 or drop.paths.len == 0) return null;
        try validateViewLabel(drop.view_label);
        const point = drop.point orelse return null;
        const index = self.findViewIndex(drop.window_id, drop.view_label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;

        const widget_drop = canvas.WidgetFileDropEvent{
            .point = point,
            .paths = drop.paths,
        };
        const route = try self.views[index].widgetLayoutTree().routeFileDropEvent(widget_drop, output);
        if (route.target == null) return null;
        return .{
            .window_id = drop.window_id,
            .view_label = self.views[index].label,
            .drop = widget_drop,
            .target = route.target,
            .route = route.entries,
        };
    }

    pub fn routeCanvasWidgetDragInput(self: *const Runtime, input_event: GpuSurfaceInputEvent, output: []canvas.WidgetEventRouteEntry) anyerror!?CanvasWidgetDragEvent {
        try self.validateViewParent(input_event.window_id);
        if (input_event.kind != .pointer_drag) return null;
        try validateViewLabel(input_event.label);
        const index = self.findViewIndex(input_event.window_id, input_event.label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        const source_id = self.views[index].canvas_widget_pressed_id;
        if (source_id == 0) return null;

        const drag = canvas.WidgetDragEvent{
            .source_id = source_id,
            .point = geometry.PointF.init(input_event.x, input_event.y),
            .delta = geometry.OffsetF.init(input_event.delta_x, input_event.delta_y),
        };
        const route = try self.views[index].widgetLayoutTree().routeDragEvent(drag, output);
        if (route.target == null) return null;
        return .{
            .window_id = input_event.window_id,
            .view_label = self.views[index].label,
            .drag = drag,
            .source = route.target,
            .route = route.entries,
        };
    }

    fn updateCanvasWidgetFocusFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
        if (pointer_event.pointer.phase != .down) return;
        const index = self.findViewIndex(pointer_event.window_id, pointer_event.view_label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;

        const next_focus_id: canvas.ObjectId = if (pointer_event.target) |target| blk: {
            if (self.views[index].widgetLayoutTree().focusTargetById(target.id) != null) break :blk target.id;
            break :blk 0;
        } else 0;

        if (self.views[index].canvas_widget_focused_id == next_focus_id and self.views[index].canvas_widget_focus_visible_id == 0) return;
        const previous_state = self.views[index].canvasWidgetRenderState();
        self.views[index].canvas_widget_focused_id = next_focus_id;
        self.views[index].canvas_widget_focus_visible_id = 0;
        try self.invalidateForCanvasWidgetRenderStateChange(index, previous_state, self.views[index].canvasWidgetRenderState());
    }

    fn updateCanvasWidgetInteractionFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
        const index = self.findViewIndex(pointer_event.window_id, pointer_event.view_label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;

        const target_id: canvas.ObjectId = if (pointer_event.target) |target| target.id else 0;
        const hit_target = self.views[index].widgetLayoutTree().hitTestWithTokens(pointer_event.pointer.point, self.views[index].widget_tokens);
        const hit_target_id: canvas.ObjectId = if (hit_target) |target| target.id else 0;
        const hit_cursor = platformCursorFromCanvas(self.views[index].widgetLayoutTree().cursorForHit(hit_target));
        var next_hovered_id = self.views[index].canvas_widget_hovered_id;
        var next_pressed_id = self.views[index].canvas_widget_pressed_id;
        var next_cursor = self.views[index].canvas_widget_cursor;

        switch (pointer_event.pointer.phase) {
            .hover, .move => {
                next_hovered_id = hit_target_id;
                next_cursor = hit_cursor;
            },
            .down => {
                next_hovered_id = target_id;
                next_pressed_id = target_id;
                next_cursor = platformCursorFromCanvas(self.views[index].widgetLayoutTree().cursorForHit(pointer_event.target));
            },
            .up => {
                next_hovered_id = hit_target_id;
                next_pressed_id = 0;
                next_cursor = hit_cursor;
            },
            .cancel => {
                next_hovered_id = 0;
                next_pressed_id = 0;
                next_cursor = .arrow;
            },
            .wheel => {},
        }

        const interaction_changed = self.views[index].canvas_widget_hovered_id != next_hovered_id or
            self.views[index].canvas_widget_pressed_id != next_pressed_id;
        const cursor_changed = self.views[index].canvas_widget_cursor != next_cursor;
        if (!interaction_changed and !cursor_changed) return;

        const previous_state = self.views[index].canvasWidgetRenderState();
        self.views[index].canvas_widget_hovered_id = next_hovered_id;
        self.views[index].canvas_widget_pressed_id = next_pressed_id;
        self.views[index].canvas_widget_cursor = next_cursor;
        if (cursor_changed) try self.syncCanvasWidgetCursorForView(index);
        if (interaction_changed) try self.invalidateForCanvasWidgetRenderStateChange(index, previous_state, self.views[index].canvasWidgetRenderState());
    }

    fn syncCanvasWidgetCursorForView(self: *Runtime, view_index: usize) anyerror!void {
        if (view_index >= self.view_count) return;
        if (self.views[view_index].kind != .gpu_surface) return;
        try self.options.platform.services.setViewCursor(
            self.views[view_index].window_id,
            self.views[view_index].label,
            self.views[view_index].canvas_widget_cursor,
        );
    }

    fn invalidateForCanvasWidgetRenderStateChange(self: *Runtime, view_index: usize, previous: canvas.WidgetRenderState, next: canvas.WidgetRenderState) anyerror!void {
        if (view_index >= self.view_count) return;
        if (self.views[view_index].kind != .gpu_surface) return;
        const local_dirty = self.views[view_index].widgetLayoutTree().renderStateDirtyBounds(previous, next);
        self.invalidateForCanvasWidgetRenderStateDirty(view_index, local_dirty);
        const publish_accessibility = previous.focused_id != next.focused_id;
        _ = try self.refreshCanvasWidgetDisplayListIfOwnedWithAccessibility(view_index, publish_accessibility);
    }

    fn invalidateForCanvasWidgetRenderStateDirty(self: *Runtime, view_index: usize, local_dirty: ?geometry.RectF) void {
        if (view_index >= self.view_count) return;
        if (self.views[view_index].kind != .gpu_surface) return;
        const dirty = local_dirty orelse return;
        if (canvasDirtyRegionForView(self.views[view_index].frame, dirty)) |dirty_region| {
            self.invalidateFor(.state, dirty_region);
            return;
        }
        self.invalidateFor(.state, self.views[view_index].frame);
    }

    fn canvasWidgetRenderStateAfterLayout(previous: canvas.WidgetRenderState, layout: canvas.WidgetLayoutTree) canvas.WidgetRenderState {
        const next_focused_id = if (previous.focused_id) |id| if (layout.focusTargetById(id) != null) id else null else null;
        return .{
            .focused_id = next_focused_id,
            .focus_visible_id = if (previous.focus_visible_id) |id| if (next_focused_id != null and next_focused_id.? == id and layout.focusTargetById(id) != null) id else null else null,
            .hovered_id = if (previous.hovered_id) |id| if (canvasWidgetInteractionTargetExists(layout, id)) id else null else null,
            .pressed_id = if (previous.pressed_id) |id| if (canvasWidgetInteractionTargetExists(layout, id)) id else null else null,
        };
    }

    fn canvasWidgetRenderStatesEqual(a: canvas.WidgetRenderState, b: canvas.WidgetRenderState) bool {
        return a.focused_id == b.focused_id and
            a.focus_visible_id == b.focus_visible_id and
            a.hovered_id == b.hovered_id and
            a.pressed_id == b.pressed_id;
    }

    fn updateCanvasWidgetScrollFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
        if (pointer_event.pointer.phase != .wheel) return;
        const index = self.findViewIndex(pointer_event.window_id, pointer_event.view_label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;

        const dirty = try self.views[index].applyCanvasWidgetScrollRoute(pointer_event.route, pointer_event.pointer.delta.dy, .wheel) orelse return;
        const previous_cursor = self.views[index].canvas_widget_cursor;
        self.views[index].reconcileCanvasWidgetRenderStateAfterScroll(pointer_event.pointer.point);
        if (previous_cursor != self.views[index].canvas_widget_cursor) try self.syncCanvasWidgetCursorForView(index);
        if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
            self.invalidateFor(.state, dirty_region);
        } else {
            self.invalidateFor(.state, self.views[index].frame);
        }
        _ = try self.refreshCanvasWidgetDisplayListIfOwnedSkippingAccessibility(index);
    }

    fn updateCanvasWidgetTextFromKeyboard(self: *Runtime, keyboard_event: CanvasWidgetKeyboardEvent) anyerror!void {
        const index = self.findViewIndex(keyboard_event.window_id, keyboard_event.view_label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;
        const target = keyboard_event.target orelse return;
        const edit = self.views[index].canvasWidgetKeyboardTextEdit(target, keyboard_event.keyboard) orelse return;

        const dirty = try self.views[index].applyCanvasWidgetTextEdit(target.id, edit) orelse return;
        if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
            self.invalidateFor(.state, dirty_region);
        } else {
            self.invalidateFor(.state, self.views[index].frame);
        }
        _ = try self.refreshCanvasWidgetDisplayListIfOwned(index);
    }

    fn updateCanvasWidgetTextFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
        const index = self.findViewIndex(pointer_event.window_id, pointer_event.view_label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;

        const target_id: canvas.ObjectId = switch (pointer_event.pointer.phase) {
            .down => if (pointer_event.target) |target| target.id else 0,
            .move => self.views[index].canvas_widget_pressed_id,
            else => return,
        };
        if (target_id == 0) return;

        const dirty = try self.views[index].applyCanvasWidgetTextPointer(
            target_id,
            pointer_event.pointer.point,
            pointer_event.pointer.phase == .move,
        ) orelse return;
        if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
            self.invalidateFor(.state, dirty_region);
        } else {
            self.invalidateFor(.state, self.views[index].frame);
        }
        _ = try self.refreshCanvasWidgetDisplayListIfOwned(index);
    }

    fn updateCanvasWidgetControlFromPointer(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
        const index = self.findViewIndex(pointer_event.window_id, pointer_event.view_label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;

        const toggle_animation = self.views[index].canvasWidgetToggleAnimationForPointer(
            pointer_event.pointer,
            pointer_event.target,
            self.views[index].canvas_widget_pressed_id,
        );
        const dirty = try self.views[index].applyCanvasWidgetControlPointer(
            pointer_event.pointer,
            pointer_event.target,
            self.views[index].canvas_widget_pressed_id,
        ) orelse return;
        if (toggle_animation) |animation| try self.scheduleCanvasWidgetToggleAnimation(index, animation);
        if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
            self.invalidateFor(.state, dirty_region);
        } else {
            self.invalidateFor(.state, self.views[index].frame);
        }
        _ = try self.refreshCanvasWidgetDisplayListIfOwned(index);
    }

    fn updateCanvasWidgetControlFromKeyboard(self: *Runtime, keyboard_event: CanvasWidgetKeyboardEvent) anyerror!void {
        const index = self.findViewIndex(keyboard_event.window_id, keyboard_event.view_label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;
        const target = keyboard_event.target orelse return;

        const toggle_animation = self.views[index].canvasWidgetToggleAnimationForKeyboard(target.id, keyboard_event.keyboard);
        const dirty = try self.views[index].applyCanvasWidgetControlKeyboard(target.id, keyboard_event.keyboard) orelse return;
        if (toggle_animation) |animation| try self.scheduleCanvasWidgetToggleAnimation(index, animation);
        const previous_cursor = self.views[index].canvas_widget_cursor;
        if (target.kind == .scroll_view) self.views[index].reconcileCanvasWidgetRenderStateAfterScroll(null);
        if (previous_cursor != self.views[index].canvas_widget_cursor) try self.syncCanvasWidgetCursorForView(index);
        if (canvasDirtyRegionForView(self.views[index].frame, dirty)) |dirty_region| {
            self.invalidateFor(.state, dirty_region);
        } else {
            self.invalidateFor(.state, self.views[index].frame);
        }
        _ = try self.refreshCanvasWidgetDisplayListIfOwned(index);
    }

    fn dismissCanvasWidgetSurfaceFromPointerInput(self: *Runtime, pointer_event: CanvasWidgetPointerEvent) anyerror!bool {
        if (pointer_event.pointer.phase != .down) return false;
        const index = self.findViewIndex(pointer_event.window_id, pointer_event.view_label) orelse return false;
        if (self.views[index].kind != .gpu_surface or !self.views[index].focused) return false;
        const focused_id = self.views[index].canvas_widget_focused_id;
        if (focused_id == 0) return false;

        const previous_cursor = self.views[index].canvas_widget_cursor;
        const dirty = try self.views[index].dismissCanvasWidgetSurfaceForPointerOutsideFocusedTarget(focused_id, pointer_event.route) orelse return false;
        if (previous_cursor != self.views[index].canvas_widget_cursor) try self.syncCanvasWidgetCursorForView(index);
        try self.invalidateForCanvasWidgetDirty(index, dirty);
        return true;
    }

    fn dismissCanvasWidgetSurfaceFromKeyboardInput(self: *Runtime, input_event: GpuSurfaceInputEvent) anyerror!bool {
        if (input_event.kind != .key_down) return false;
        if (!canvasWidgetEscapeKey(input_event.key)) return false;
        const modifiers = canvasWidgetKeyboardModifiers(input_event.modifiers);
        if (modifiers.shift or modifiers.hasNavigationModifier()) return false;

        const index = self.findViewIndex(input_event.window_id, input_event.label) orelse return false;
        if (self.views[index].kind != .gpu_surface or !self.views[index].focused) return false;
        const focused_id = self.views[index].canvas_widget_focused_id;
        if (focused_id == 0) return false;

        const previous_cursor = self.views[index].canvas_widget_cursor;
        const dirty = try self.views[index].dismissCanvasWidgetSurfaceForFocusedTarget(focused_id) orelse return false;
        if (previous_cursor != self.views[index].canvas_widget_cursor) try self.syncCanvasWidgetCursorForView(index);
        try self.invalidateForCanvasWidgetDirty(index, dirty);
        return true;
    }

    fn dispatchCanvasWidgetCommandForId(self: *Runtime, app: App, view_index: usize, id: canvas.ObjectId) anyerror!void {
        if (view_index >= self.view_count) return error.ViewNotFound;
        const node_index = self.views[view_index].canvasWidgetNodeIndexById(id) orelse return;
        const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
        if (!canvasWidgetCommandable(widget.kind)) return;
        const command = self.views[view_index].canvasWidgetCommand(id) orelse return;
        try self.dispatchCommand(app, .{
            .name = command,
            .source = .native_view,
            .window_id = self.views[view_index].window_id,
            .view_label = self.views[view_index].label,
        });
    }

    fn dispatchCanvasWidgetCommandFromPointer(self: *Runtime, app: App, pointer_event: CanvasWidgetPointerEvent) anyerror!void {
        const index = self.findViewIndex(pointer_event.window_id, pointer_event.view_label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;
        const target = pointer_event.target orelse return;
        switch (pointer_event.pointer.phase) {
            .down => {
                if (!canvasWidgetCommandFiresOnPointerDown(target.kind)) return;
                if (!target.bounds.normalized().containsPoint(pointer_event.pointer.point)) return;
                try self.dispatchCanvasWidgetCommandForId(app, index, target.id);
            },
            .up => {
                if (canvasWidgetCommandFiresOnPointerDown(target.kind)) return;
                const pressed_id = if (pointer_event.pointer.captured_id != 0) pointer_event.pointer.captured_id else self.views[index].canvas_widget_pressed_id;
                if (pressed_id != target.id) return;
                if (!target.bounds.normalized().containsPoint(pointer_event.pointer.point)) return;
                try self.dispatchCanvasWidgetCommandForId(app, index, target.id);
            },
            .hover, .move, .cancel, .wheel => return,
        }
    }

    fn dispatchCanvasWidgetCommandFromKeyboard(self: *Runtime, app: App, keyboard_event: CanvasWidgetKeyboardEvent) anyerror!void {
        if (keyboard_event.keyboard.phase != .key_down or keyboard_event.keyboard.modifiers.hasNavigationModifier()) return;
        if (!canvas.isWidgetActivationKey(keyboard_event.keyboard.key)) return;
        const index = self.findViewIndex(keyboard_event.window_id, keyboard_event.view_label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;
        const target = keyboard_event.target orelse return;
        try self.dispatchCanvasWidgetCommandForId(app, index, target.id);
    }

    fn updateCanvasWidgetFocusFromKeyboardInput(self: *Runtime, input_event: GpuSurfaceInputEvent) anyerror!void {
        if (input_event.kind != .key_down) return;
        const index = self.findViewIndex(input_event.window_id, input_event.label) orelse return;
        if (self.views[index].kind != .gpu_surface) return;

        const current_id: ?canvas.ObjectId = if (self.views[index].canvas_widget_focused_id == 0) null else self.views[index].canvas_widget_focused_id;
        if (std.ascii.eqlIgnoreCase(input_event.key, "tab")) {
            const direction: canvas.WidgetFocusDirection = if (input_event.modifiers.shift) .backward else .forward;
            const target = if (current_id) |id|
                self.views[index].canvasWidgetScopedFocusTarget(id, direction) orelse self.views[index].widgetLayoutTree().focusTarget(current_id, direction) orelse return
            else
                self.views[index].widgetLayoutTree().focusTarget(current_id, direction) orelse return;
            try self.setCanvasWidgetFocusFromKeyboard(index, target.id);
            return;
        }

        const focused_id = current_id orelse return;
        const layout = self.views[index].widgetLayoutTree();
        const focused = layout.focusTargetById(focused_id) orelse return;
        if (canvasWidgetGroupFocusEdgeFromInput(input_event)) |edge| {
            const target = canvasWidgetGroupFocusEdgeTarget(layout, focused, edge) orelse return;
            try self.setCanvasWidgetFocusFromKeyboard(index, target.id);
            return;
        }
        const direction = canvasWidgetSpatialFocusDirection(input_event) orelse return;
        if (canvasWidgetGroupDirectionalFocusTarget(layout, focused, direction)) |target| {
            try self.setCanvasWidgetFocusFromKeyboard(index, target.id);
            return;
        }
        const target = layout.focusTarget(focused_id, direction) orelse return;
        if (!canvasWidgetSpatialFocusAllowed(layout, focused, target, direction)) return;
        try self.setCanvasWidgetFocusFromKeyboard(index, target.id);
    }

    fn setCanvasWidgetFocusFromKeyboard(self: *Runtime, view_index: usize, target_id: canvas.ObjectId) anyerror!void {
        if (self.views[view_index].canvas_widget_focused_id == target_id and self.views[view_index].canvas_widget_focus_visible_id == target_id) return;
        const previous_state = self.views[view_index].canvasWidgetRenderState();
        self.views[view_index].canvas_widget_focused_id = target_id;
        self.views[view_index].canvas_widget_focus_visible_id = target_id;
        try self.invalidateForCanvasWidgetRenderStateChange(view_index, previous_state, self.views[view_index].canvasWidgetRenderState());
    }

    fn invalidateForCanvasChanges(self: *Runtime, view_frame: geometry.RectF, changes: []const canvas.DiffChange) void {
        var emitted_dirty_region = false;
        for (changes) |change| {
            const local_dirty = change.dirty_bounds orelse continue;
            if (canvasDirtyRegionForView(view_frame, local_dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
                emitted_dirty_region = true;
            }
        }
        if (!emitted_dirty_region and changes.len > 0) self.invalidateFor(.state, view_frame);
    }

    fn invalidateForWidgetInvalidations(self: *Runtime, view_frame: geometry.RectF, invalidations: []const canvas.WidgetInvalidation) void {
        var emitted_dirty_region = false;
        for (invalidations) |invalidation| {
            const local_dirty = invalidation.dirty_bounds orelse continue;
            if (canvasDirtyRegionForView(view_frame, local_dirty)) |dirty_region| {
                self.invalidateFor(.state, dirty_region);
                emitted_dirty_region = true;
            }
        }
        if (!emitted_dirty_region and invalidations.len > 0) self.invalidateFor(.state, null);
    }

    pub fn listViews(self: *const Runtime, window_id: platform.WindowId, output: []platform.ViewInfo) []const platform.ViewInfo {
        const window_index = self.findWindowIndexById(window_id) orelse return output[0..0];
        if (!self.windows[window_index].info.open) return output[0..0];

        var count: usize = 0;
        if (self.windows[window_index].source != null and count < output.len) {
            output[count] = viewInfoFromWebView(self.mainWebViewInfo(window_index));
            count += 1;
        }
        for (self.views[0..self.view_count]) |view| {
            if (!view.open or view.window_id != window_id) continue;
            if (count >= output.len) return output[0..count];
            output[count] = view.info();
            count += 1;
        }
        for (self.webviews[0..self.webview_count]) |webview| {
            if (!webview.open or webview.window_id != window_id) continue;
            if (count >= output.len) return output[0..count];
            output[count] = viewInfoFromWebView(webview);
            count += 1;
        }
        return output[0..count];
    }

    pub fn focusView(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!void {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        if (!self.viewLabelExists(window_id, label)) return error.ViewNotFound;
        try self.options.platform.services.focusView(window_id, label);
        try self.setFocusedView(window_id, label);
        self.invalidateFor(.command, null);
    }

    pub fn focusNextView(self: *Runtime, window_id: platform.WindowId) anyerror!platform.ViewInfo {
        return self.focusAdjacentView(window_id, .next);
    }

    pub fn focusPreviousView(self: *Runtime, window_id: platform.WindowId) anyerror!platform.ViewInfo {
        return self.focusAdjacentView(window_id, .previous);
    }

    pub fn readClipboard(self: *Runtime, buffer: []u8) anyerror![]const u8 {
        return self.readClipboardData("text/plain", buffer);
    }

    pub fn writeClipboard(self: *Runtime, text: []const u8) anyerror!void {
        try self.writeClipboardData(.{ .mime_type = "text/plain", .bytes = text });
    }

    pub fn readClipboardData(self: *Runtime, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
        try validateClipboardMimeType(mime_type);
        return self.options.platform.services.readClipboardData(mime_type, buffer);
    }

    pub fn writeClipboardData(self: *Runtime, data: platform.ClipboardData) anyerror!void {
        try validateClipboardData(data);
        try self.options.platform.services.writeClipboardData(data);
    }

    pub fn openExternalUrl(self: *Runtime, url: []const u8) anyerror!void {
        try self.validateExternalUrl(url);
        try self.options.platform.services.openExternalUrl(url);
    }

    pub fn revealPath(self: *Runtime, path: []const u8) anyerror!void {
        try validateRevealPath(path);
        try self.options.platform.services.revealPath(path);
    }

    pub fn addRecentDocument(self: *Runtime, path: []const u8) anyerror!void {
        try validateRecentDocumentPath(path);
        try self.options.platform.services.addRecentDocument(path);
    }

    pub fn clearRecentDocuments(self: *Runtime) anyerror!void {
        try self.options.platform.services.clearRecentDocuments();
    }

    pub fn showOpenDialog(self: *Runtime, options: platform.OpenDialogOptions, buffer: []u8) anyerror!platform.OpenDialogResult {
        try validateOpenDialogOptions(options, buffer);
        return self.options.platform.services.showOpenDialog(options, buffer);
    }

    pub fn showSaveDialog(self: *Runtime, options: platform.SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
        try validateSaveDialogOptions(options, buffer);
        return self.options.platform.services.showSaveDialog(options, buffer);
    }

    pub fn showMessageDialog(self: *Runtime, options: platform.MessageDialogOptions) anyerror!platform.MessageDialogResult {
        try validateMessageDialogOptions(options);
        return self.options.platform.services.showMessageDialog(options);
    }

    pub fn showNotification(self: *Runtime, options: platform.NotificationOptions) anyerror!void {
        try validateNotificationOptions(options);
        try self.options.platform.services.showNotification(options);
    }

    pub fn setCredential(self: *Runtime, credential: platform.Credential) anyerror!void {
        try validateCredential(credential);
        try self.options.platform.services.setCredential(credential);
    }

    pub fn getCredential(self: *Runtime, key: platform.CredentialKey, buffer: []u8) anyerror!?[]const u8 {
        try validateCredentialKey(key);
        return self.options.platform.services.getCredential(key, buffer) catch |err| switch (err) {
            error.CredentialNotFound => null,
            else => |e| return e,
        };
    }

    pub fn deleteCredential(self: *Runtime, key: platform.CredentialKey) anyerror!bool {
        try validateCredentialKey(key);
        self.options.platform.services.deleteCredential(key) catch |err| switch (err) {
            error.CredentialNotFound => return false,
            else => |e| return e,
        };
        return true;
    }

    pub fn createTray(self: *Runtime, options: platform.TrayOptions) anyerror!void {
        try validateTrayOptions(options);
        try self.options.platform.services.createTray(options);
        try self.storeTrayItems(options.items);
    }

    pub fn updateTrayMenu(self: *Runtime, items: []const platform.TrayMenuItem) anyerror!void {
        try validateTrayMenuItems(items);
        try self.options.platform.services.updateTrayMenu(items);
        try self.storeTrayItems(items);
    }

    pub fn removeTray(self: *Runtime) anyerror!void {
        try self.options.platform.services.removeTray();
        self.tray_item_count = 0;
    }

    pub fn emitWindowEvent(self: *Runtime, window_id: platform.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
        if (!json.isValidValue(detail_json)) return error.InvalidJsonEventDetail;
        try self.options.platform.services.emitWindowEvent(window_id, name, detail_json);
    }

    pub fn respondToBridge(self: *Runtime, source: bridge.Source, response: []const u8) anyerror!void {
        try self.completeBridgeResponse(source.window_id, source.webview_label, response);
    }

    pub fn dispatchPlatformEvent(self: *Runtime, app: App, event_value: platform.Event) anyerror!void {
        if ((event_value != .frame_requested and event_value != .gpu_surface_frame) or self.invalidated) {
            const event_fields = [_]trace.Field{trace.string("event", event_value.name())};
            try self.log("platform.event", null, &event_fields);
        }

        switch (event_value) {
            .app_start => {
                try self.reservePrimaryStartupWindow();
                try app.start(self);
                if (self.options.extensions) |registry| try registry.startAll(self.extensionContext());
                try self.dispatchEvent(app, .{ .lifecycle = .start });
                if (try app.scene()) |scene| {
                    try self.loadScene(app, scene);
                } else {
                    try self.loadStartupWindows(app);
                }
                self.invalidateFor(.startup, null);
                try self.log("app.start", "app started", &.{trace.string("app", app.name)});
            },
            .app_activated => {
                try self.dispatchEvent(app, .{ .lifecycle = .activate });
                self.emitAppLifecycleEvent("app:activate") catch |err| try self.log("app.activate.emit_failed", @errorName(err), &.{});
            },
            .app_deactivated => {
                try self.dispatchEvent(app, .{ .lifecycle = .deactivate });
                self.emitAppLifecycleEvent("app:deactivate") catch |err| try self.log("app.deactivate.emit_failed", @errorName(err), &.{});
            },
            .appearance_changed => |appearance| {
                self.appearance = appearance;
                try self.dispatchEvent(app, .{ .appearance_changed = appearance });
            },
            .surface_resized => |surface_value| {
                self.surface = surface_value;
                if (self.findWindowIndexById(surface_value.id)) |index| {
                    self.windows[index].info.frame.width = surface_value.size.width;
                    self.windows[index].info.frame.height = surface_value.size.height;
                    self.windows[index].info.scale_factor = surface_value.scale_factor;
                }
                self.relayoutShellViews(surface_value.id) catch |err| try self.log("shell.relayout_failed", @errorName(err), &.{trace.uint("window_id", surface_value.id)});
                var detail_buffer: [512]u8 = undefined;
                var detail_writer = std.Io.Writer.fixed(&detail_buffer);
                try detail_writer.print("{{\"width\":{d},\"height\":{d},\"scale\":{d},\"safeAreaInsets\":{{\"top\":{d},\"right\":{d},\"bottom\":{d},\"left\":{d}}},\"keyboardInsets\":{{\"top\":{d},\"right\":{d},\"bottom\":{d},\"left\":{d}}}}}", .{
                    surface_value.size.width,
                    surface_value.size.height,
                    surface_value.scale_factor,
                    surface_value.safe_area_insets.top,
                    surface_value.safe_area_insets.right,
                    surface_value.safe_area_insets.bottom,
                    surface_value.safe_area_insets.left,
                    surface_value.keyboard_insets.top,
                    surface_value.keyboard_insets.right,
                    surface_value.keyboard_insets.bottom,
                    surface_value.keyboard_insets.left,
                });
                self.emitWindowEvent(surface_value.id, "resize", detail_writer.buffered()) catch |err| try self.log("window.resize.emit_failed", @errorName(err), &.{});
                self.invalidateFor(.surface_resize, geometry.RectF.fromSize(surface_value.size));
                const fields = [_]trace.Field{
                    trace.float("width", surface_value.size.width),
                    trace.float("height", surface_value.size.height),
                    trace.float("scale", surface_value.scale_factor),
                };
                try self.log("surface.resize", "surface updated", &fields);
            },
            .window_frame_changed => |state| {
                self.updateWindowState(state) catch |err| try self.log("window.state.update_failed", @errorName(err), &.{trace.string("label", state.label)});
                self.relayoutShellViews(state.id) catch |err| try self.log("shell.relayout_failed", @errorName(err), &.{trace.uint("window_id", state.id)});
                if (self.options.window_state_store) |store| {
                    store.saveWindow(self.runtimeWindowStateForPersistence(state)) catch |err| try self.log("window.state.save_failed", @errorName(err), &.{trace.string("label", state.label)});
                }
                try self.log("window.frame", "window frame updated", &.{
                    trace.string("label", state.label),
                    trace.float("x", state.frame.x),
                    trace.float("y", state.frame.y),
                    trace.float("width", state.frame.width),
                    trace.float("height", state.frame.height),
                });
            },
            .window_focused => |window_id| {
                if (self.findWindowIndexById(window_id)) |index| self.setFocusedIndex(index);
                self.invalidated = true;
            },
            .frame_requested => try self.frame(app),
            .bridge_message => |message| try self.handleBridgeMessage(app, message),
            .tray_action => |item_id| {
                try self.log("tray.action", "tray item selected", &.{trace.uint("item_id", item_id)});
                try self.dispatchCommand(app, .{
                    .name = self.trayCommandNameForItem(item_id),
                    .source = .tray,
                    .tray_item_id = item_id,
                });
            },
            .shortcut => |shortcut| {
                try self.dispatchCommand(app, .{
                    .name = shortcut.id,
                    .source = .shortcut,
                    .window_id = shortcut.window_id,
                });
                try self.dispatchEvent(app, .{ .shortcut = shortcut });
                self.emitShortcutEvent(shortcut) catch |err| try self.log("shortcut.emit_failed", @errorName(err), &.{trace.string("id", shortcut.id)});
                self.invalidateFor(.command, null);
            },
            .native_command => |command| {
                try self.dispatchCommand(app, .{
                    .name = command.name,
                    .source = self.commandSourceForNativeView(command.window_id, command.view_label),
                    .window_id = command.window_id,
                    .view_label = command.view_label,
                });
            },
            .gpu_surface_frame => |frame_event| {
                var enriched_frame_event = frame_event;
                if (self.findViewIndex(frame_event.window_id, frame_event.label)) |index| {
                    const had_pending_input = self.views[index].gpu_pending_input_timestamp_ns != 0;
                    if (!sizesEqual(self.views[index].gpu_size, frame_event.size) or self.views[index].gpu_scale_factor != frame_event.scale_factor) {
                        self.views[index].presented_canvas_valid = false;
                    }
                    self.views[index].gpu_size = frame_event.size;
                    self.views[index].gpu_scale_factor = frame_event.scale_factor;
                    self.views[index].gpu_frame_index = frame_event.frame_index;
                    self.views[index].gpu_timestamp_ns = frame_event.timestamp_ns;
                    self.views[index].recordGpuSurfaceFrameInterval(frame_event.frame_interval_ns);
                    self.views[index].recordGpuSurfaceFirstFrameLatency(frame_event.timestamp_ns);
                    self.views[index].recordGpuSurfaceInputLatencyForFrame(frame_event.timestamp_ns);
                    try self.advanceCanvasWidgetKineticScrollForFrame(index, frame_event.frame_interval_ns, had_pending_input);
                    self.views[index].gpu_frame_nonblank = frame_event.nonblank;
                    self.views[index].gpu_sample_color = frame_event.sample_color;
                    self.views[index].gpu_backend = frame_event.backend;
                    self.views[index].gpu_pixel_format = frame_event.pixel_format;
                    self.views[index].gpu_present_mode = frame_event.present_mode;
                    self.views[index].gpu_alpha_mode = frame_event.alpha_mode;
                    self.views[index].gpu_color_space = frame_event.color_space;
                    self.views[index].gpu_vsync = frame_event.vsync;
                    self.views[index].gpu_status = frame_event.status;
                    if (self.options.gpu_surface_frame_diagnostics) {
                        const preview_frame = try self.planCanvasFrameForView(index, .{
                            .frame_index = frame_event.frame_index,
                            .timestamp_ns = frame_event.timestamp_ns,
                            .surface_size = frame_event.size,
                            .scale = frame_event.scale_factor,
                        }, self.canvasFrameScratchStorage(), false);
                        const preview_render_pass = preview_frame.renderPass();
                        const preview_gpu_packet_summary = preview_frame.gpuPacketSummary();
                        const preview_budget_status = preview_frame.budgetStatus();
                        enriched_frame_event.canvas_revision = self.views[index].canvas_revision;
                        enriched_frame_event.frame_interval_ns = self.views[index].gpu_frame_interval_ns;
                        enriched_frame_event.input_timestamp_ns = self.views[index].gpu_input_timestamp_ns;
                        enriched_frame_event.input_latency_ns = self.views[index].gpu_input_latency_ns;
                        enriched_frame_event.input_latency_budget_ns = self.views[index].gpu_input_latency_budget_ns;
                        enriched_frame_event.input_latency_budget_exceeded_count = self.views[index].gpu_input_latency_budget_exceeded_count;
                        enriched_frame_event.input_latency_budget_ok = self.views[index].gpu_input_latency_budget_ok;
                        enriched_frame_event.first_frame_latency_ns = self.views[index].gpu_first_frame_latency_ns;
                        enriched_frame_event.first_frame_latency_budget_ns = self.views[index].gpu_first_frame_latency_budget_ns;
                        enriched_frame_event.first_frame_latency_budget_exceeded_count = self.views[index].gpu_first_frame_latency_budget_exceeded_count;
                        enriched_frame_event.first_frame_latency_budget_ok = self.views[index].gpu_first_frame_latency_budget_ok;
                        enriched_frame_event.canvas_command_count = self.views[index].canvas_command_count;
                        enriched_frame_event.canvas_frame_requires_render = preview_frame.requiresRender();
                        enriched_frame_event.canvas_frame_full_repaint = preview_frame.full_repaint;
                        enriched_frame_event.canvas_frame_batch_count = preview_frame.batch_plan.batchCount();
                        enriched_frame_event.canvas_frame_encoder_command_count = preview_render_pass.encoderCommandCount();
                        enriched_frame_event.canvas_frame_encoder_cache_action_count = preview_render_pass.encoderCacheActionCount();
                        enriched_frame_event.canvas_frame_encoder_bind_pipeline_count = preview_render_pass.encoderBindPipelineCount();
                        enriched_frame_event.canvas_frame_encoder_draw_batch_count = preview_render_pass.encoderDrawBatchCount();
                        enriched_frame_event.canvas_frame_pipeline_count = preview_frame.pipeline_cache_plan.entryCount();
                        enriched_frame_event.canvas_frame_pipeline_upload_count = preview_frame.pipeline_cache_plan.uploadCount();
                        enriched_frame_event.canvas_frame_pipeline_retain_count = preview_frame.pipeline_cache_plan.retainCount();
                        enriched_frame_event.canvas_frame_pipeline_evict_count = preview_frame.pipeline_cache_plan.evictCount();
                        enriched_frame_event.canvas_frame_path_geometry_count = preview_frame.path_geometry_plan.geometryCount();
                        enriched_frame_event.canvas_frame_path_geometry_vertex_count = preview_frame.path_geometry_plan.vertexCount();
                        enriched_frame_event.canvas_frame_path_geometry_index_count = preview_frame.path_geometry_plan.indexCount();
                        enriched_frame_event.canvas_frame_path_geometry_upload_count = preview_frame.path_geometry_cache_plan.uploadCount();
                        enriched_frame_event.canvas_frame_path_geometry_retain_count = preview_frame.path_geometry_cache_plan.retainCount();
                        enriched_frame_event.canvas_frame_path_geometry_evict_count = preview_frame.path_geometry_cache_plan.evictCount();
                        enriched_frame_event.canvas_frame_image_count = preview_frame.image_plan.imageCount();
                        enriched_frame_event.canvas_frame_image_upload_count = preview_frame.image_cache_plan.uploadCount();
                        enriched_frame_event.canvas_frame_image_retain_count = preview_frame.image_cache_plan.retainCount();
                        enriched_frame_event.canvas_frame_image_evict_count = preview_frame.image_cache_plan.evictCount();
                        enriched_frame_event.canvas_frame_layer_count = preview_frame.layer_plan.layerCount();
                        enriched_frame_event.canvas_frame_layer_opacity_count = preview_frame.layer_plan.opacityLayerCount();
                        enriched_frame_event.canvas_frame_layer_clip_count = preview_frame.layer_plan.clipLayerCount();
                        enriched_frame_event.canvas_frame_layer_transform_count = preview_frame.layer_plan.transformLayerCount();
                        enriched_frame_event.canvas_frame_layer_upload_count = preview_frame.layer_cache_plan.uploadCount();
                        enriched_frame_event.canvas_frame_layer_retain_count = preview_frame.layer_cache_plan.retainCount();
                        enriched_frame_event.canvas_frame_layer_evict_count = preview_frame.layer_cache_plan.evictCount();
                        enriched_frame_event.canvas_frame_resource_count = preview_frame.resource_plan.resourceCount();
                        enriched_frame_event.canvas_frame_resource_upload_count = preview_frame.resource_cache_plan.uploadCount();
                        enriched_frame_event.canvas_frame_resource_retain_count = preview_frame.resource_cache_plan.retainCount();
                        enriched_frame_event.canvas_frame_resource_evict_count = preview_frame.resource_cache_plan.evictCount();
                        enriched_frame_event.canvas_frame_visual_effect_count = preview_frame.visual_effect_plan.effectCount();
                        enriched_frame_event.canvas_frame_visual_effect_shadow_count = preview_frame.visual_effect_plan.shadowCount();
                        enriched_frame_event.canvas_frame_visual_effect_blur_count = preview_frame.visual_effect_plan.blurCount();
                        enriched_frame_event.canvas_frame_visual_effect_upload_count = preview_frame.visual_effect_cache_plan.uploadCount();
                        enriched_frame_event.canvas_frame_visual_effect_retain_count = preview_frame.visual_effect_cache_plan.retainCount();
                        enriched_frame_event.canvas_frame_visual_effect_evict_count = preview_frame.visual_effect_cache_plan.evictCount();
                        enriched_frame_event.canvas_frame_glyph_atlas_entry_count = preview_frame.glyph_atlas_plan.entryCount();
                        enriched_frame_event.canvas_frame_glyph_atlas_upload_count = preview_frame.glyph_atlas_cache_plan.uploadCount();
                        enriched_frame_event.canvas_frame_glyph_atlas_retain_count = preview_frame.glyph_atlas_cache_plan.retainCount();
                        enriched_frame_event.canvas_frame_glyph_atlas_evict_count = preview_frame.glyph_atlas_cache_plan.evictCount();
                        enriched_frame_event.canvas_frame_text_layout_count = preview_frame.text_layout_plan.planCount();
                        enriched_frame_event.canvas_frame_text_layout_line_count = preview_frame.text_layout_plan.lineCount();
                        enriched_frame_event.canvas_frame_text_layout_upload_count = preview_frame.text_layout_cache_plan.uploadCount();
                        enriched_frame_event.canvas_frame_text_layout_retain_count = preview_frame.text_layout_cache_plan.retainCount();
                        enriched_frame_event.canvas_frame_text_layout_evict_count = preview_frame.text_layout_cache_plan.evictCount();
                        enriched_frame_event.canvas_frame_gpu_packet_command_count = preview_gpu_packet_summary.command_count;
                        enriched_frame_event.canvas_frame_gpu_packet_cache_action_count = preview_gpu_packet_summary.cache_action_count;
                        enriched_frame_event.canvas_frame_gpu_packet_cached_resource_command_count = preview_gpu_packet_summary.cached_resource_command_count;
                        enriched_frame_event.canvas_frame_gpu_packet_unsupported_command_count = preview_gpu_packet_summary.unsupported_command_count;
                        enriched_frame_event.canvas_frame_gpu_packet_representable = preview_gpu_packet_summary.fullyRepresentable();
                        enriched_frame_event.canvas_frame_change_count = preview_frame.changes.len;
                        enriched_frame_event.canvas_frame_budget_exceeded_count = preview_budget_status.exceededCount();
                        enriched_frame_event.canvas_frame_budget_ok = preview_budget_status.ok();
                        enriched_frame_event.canvas_frame_dirty_bounds = preview_frame.dirty_bounds;
                        const preview_profile = preview_frame.profile();
                        enriched_frame_event.canvas_frame_profile_work_units = preview_profile.work_units;
                        enriched_frame_event.canvas_frame_profile_risk = platformCanvasFrameProfileRisk(preview_profile.risk);
                        enriched_frame_event.canvas_frame_profile_surface_area = preview_profile.surface_area;
                        enriched_frame_event.canvas_frame_profile_dirty_area = preview_profile.dirty_area;
                        enriched_frame_event.canvas_frame_profile_dirty_ratio = preview_profile.dirty_ratio;
                        enriched_frame_event.widget_revision = self.views[index].widget_revision;
                        enriched_frame_event.widget_node_count = self.views[index].widget_layout_node_count;
                        enriched_frame_event.widget_semantics_count = self.views[index].widget_semantics_node_count;
                    } else if (self.views[index].info().gpuFrame()) |gpu_frame| {
                        enriched_frame_event = gpuSurfaceFrameEventFromGpuFrame(gpu_frame);
                    }
                }
                try self.dispatchEvent(app, .{ .gpu_surface_frame = enriched_frame_event });
            },
            .gpu_surface_resized => |resize_event| {
                if (self.findViewIndex(resize_event.window_id, resize_event.label)) |index| {
                    const previous_frame = self.views[index].frame;
                    const previous_size = self.views[index].gpu_size;
                    const previous_scale = self.views[index].gpu_scale_factor;
                    const next_size = resize_event.frame.size();
                    const frame_changed = !rectsEqual(previous_frame, resize_event.frame);
                    const surface_changed = !sizesEqual(previous_size, next_size) or previous_scale != resize_event.scale_factor;
                    self.views[index].frame = resize_event.frame;
                    self.views[index].gpu_size = next_size;
                    self.views[index].gpu_scale_factor = resize_event.scale_factor;
                    if (surface_changed) self.views[index].presented_canvas_valid = false;
                    if (self.views[index].gpu_status == .unavailable) self.views[index].gpu_status = .ready;
                    if (frame_changed or surface_changed) self.invalidateFor(.surface_resize, resize_event.frame);
                }
                try self.dispatchEvent(app, .{ .gpu_surface_resized = resize_event });
                try self.log("gpu_surface.resize", "gpu surface resized", &.{
                    trace.string("label", resize_event.label),
                    trace.float("width", resize_event.frame.width),
                    trace.float("height", resize_event.frame.height),
                    trace.float("scale", resize_event.scale_factor),
                });
            },
            .gpu_surface_input => |input_event| {
                var canvas_widget_refresh_batch_active = canvasWidgetInputBatchesDisplayListRefresh(input_event.kind);
                if (canvas_widget_refresh_batch_active) self.beginCanvasWidgetDisplayListRefreshBatch();
                errdefer {
                    if (canvas_widget_refresh_batch_active) self.cancelCanvasWidgetDisplayListRefreshBatch();
                }

                if (self.findViewIndex(input_event.window_id, input_event.label)) |index| {
                    self.views[index].recordGpuSurfaceInputTimestamp(input_event.timestamp_ns);
                }
                switch (input_event.kind) {
                    .pointer_down,
                    .key_down,
                    => {
                        try self.setFocusedView(input_event.window_id, input_event.label);
                        self.invalidated = true;
                    },
                    else => {},
                }
                const widget_pointer_event = self.routeCanvasWidgetPointerInput(input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                    error.WindowNotFound,
                    error.ViewNotFound,
                    error.InvalidViewOptions,
                    => null,
                    else => return err,
                };
                if (widget_pointer_event) |pointer_event| {
                    _ = try self.dismissCanvasWidgetSurfaceFromPointerInput(pointer_event);
                    try self.updateCanvasWidgetControlFromPointer(pointer_event);
                    try self.updateCanvasWidgetInteractionFromPointer(pointer_event);
                    try self.updateCanvasWidgetTextFromPointer(pointer_event);
                    try self.updateCanvasWidgetScrollFromPointer(pointer_event);
                    try self.updateCanvasWidgetFocusFromPointer(pointer_event);
                }
                const widget_drag_event = self.routeCanvasWidgetDragInput(input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                    error.WindowNotFound,
                    error.ViewNotFound,
                    error.InvalidViewOptions,
                    => null,
                    else => return err,
                };
                const widget_surface_dismissed = try self.dismissCanvasWidgetSurfaceFromKeyboardInput(input_event);
                if (!widget_surface_dismissed) try self.updateCanvasWidgetFocusFromKeyboardInput(input_event);
                const widget_keyboard_event = if (widget_surface_dismissed)
                    null
                else
                    self.routeCanvasWidgetKeyboardInput(input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                        error.WindowNotFound,
                        error.ViewNotFound,
                        error.InvalidViewOptions,
                        => null,
                        else => return err,
                    };
                if (widget_keyboard_event) |keyboard_event| {
                    try self.updateCanvasWidgetControlFromKeyboard(keyboard_event);
                    try self.updateCanvasWidgetTextFromKeyboard(keyboard_event);
                }
                const widget_text_input_event = if (widget_surface_dismissed)
                    null
                else
                    self.routeCanvasWidgetTextInput(input_event, &self.widget_event_route_entries) catch |err| switch (err) {
                        error.WindowNotFound,
                        error.ViewNotFound,
                        error.InvalidViewOptions,
                        => null,
                        else => return err,
                    };
                if (widget_text_input_event) |text_input_event| {
                    try self.updateCanvasWidgetTextFromKeyboard(text_input_event);
                }
                if (canvas_widget_refresh_batch_active) {
                    try self.endCanvasWidgetDisplayListRefreshBatch();
                    canvas_widget_refresh_batch_active = false;
                }
                if (widget_pointer_event) |pointer_event| {
                    try self.dispatchCanvasWidgetCommandFromPointer(app, pointer_event);
                    try self.dispatchEvent(app, .{ .canvas_widget_pointer = pointer_event });
                }
                if (widget_drag_event) |drag_event| {
                    try self.dispatchEvent(app, .{ .canvas_widget_drag = drag_event });
                }
                if (widget_keyboard_event) |keyboard_event| {
                    try self.dispatchCanvasWidgetCommandFromKeyboard(app, keyboard_event);
                    try self.dispatchEvent(app, .{ .canvas_widget_keyboard = keyboard_event });
                }
                if (widget_text_input_event) |text_input_event| {
                    try self.dispatchEvent(app, .{ .canvas_widget_keyboard = text_input_event });
                }
                try self.dispatchEvent(app, .{ .gpu_surface_input = input_event });
            },
            .widget_accessibility_action => |action_event| {
                _ = try self.dispatchCanvasWidgetAccessibilityAction(app, action_event.window_id, action_event.label, .{
                    .id = action_event.id,
                    .action = canvasWidgetAccessibilityActionKindFromPlatform(action_event.action),
                    .text = action_event.text,
                    .selection = if (action_event.selection) |selection| .{ .anchor = selection.start, .focus = selection.end } else null,
                });
            },
            .menu_command => |command| {
                try self.dispatchCommand(app, .{
                    .name = command.name,
                    .source = .menu,
                    .window_id = command.window_id,
                });
            },
            .files_dropped => |drop| {
                const widget_drop_event = self.routeCanvasWidgetFileDrop(drop, &self.widget_event_route_entries) catch |err| switch (err) {
                    error.WindowNotFound,
                    error.ViewNotFound,
                    error.InvalidViewOptions,
                    => null,
                    else => return err,
                };
                if (widget_drop_event) |drop_event| {
                    try self.dispatchEvent(app, .{ .canvas_widget_file_drop = drop_event });
                }
                try self.dispatchEvent(app, .{ .files_dropped = drop });
                self.emitFileDropEvent(drop) catch |err| try self.log("drop.files.emit_failed", @errorName(err), &.{trace.uint("window_id", drop.window_id)});
                self.invalidateFor(.command, null);
            },
            .app_shutdown => {
                try self.dispatchEvent(app, .{ .lifecycle = .stop });
                if (self.options.extensions) |registry| try registry.stopAll(self.extensionContext());
                try app.stop(self);
                try self.log("app.stop", "app stopped", &.{trace.string("app", app.name)});
            },
        }
    }

    pub fn dispatchEvent(self: *Runtime, app: App, event_value: Event) anyerror!void {
        const event_fields = [_]trace.Field{trace.string("event", event_value.name())};
        try self.log("runtime.event", null, &event_fields);
        try app.event(self, event_value);

        switch (event_value) {
            .command => {
                if (self.options.extensions) |registry| {
                    try registry.dispatchCommand(self.extensionContext(), .{ .name = event_value.command.name });
                }
                self.invalidateFor(.command, null);
            },
            .shortcut => {
                self.invalidateFor(.command, null);
            },
            .appearance_changed => {
                self.invalidateFor(.state, null);
            },
            .files_dropped => {},
            .gpu_surface_frame => {},
            .gpu_surface_resized => {},
            .gpu_surface_input => {},
            .canvas_widget_pointer => {},
            .canvas_widget_keyboard => {},
            .canvas_widget_file_drop => {},
            .canvas_widget_drag => {},
            .lifecycle => {},
        }
    }

    pub fn dispatchCommand(self: *Runtime, app: App, command: CommandEvent) anyerror!void {
        try validateCommandName(command.name);
        try self.dispatchEvent(app, .{ .command = command });
    }

    pub fn frame(self: *Runtime, app: App) anyerror!void {
        const start_ns = nowNanoseconds();
        try self.consumeAutomationCommand(app);
        if (!self.invalidated) return;

        try self.publishAutomation();
        self.frame_index += 1;
        self.last_diagnostics = .{
            .frame_index = self.frame_index,
            .command_count = self.command_count,
            .dirty_region_count = self.dirty_region_count,
            .resource_upload_count = 0,
            .duration_ns = @intCast(@max(0, nowNanoseconds() - start_ns)),
        };
        self.command_count = 0;
        self.dirty_region_count = 0;
        self.invalidated = false;
        try self.log("runtime.frame", "frame published", &.{
            trace.uint("frame", self.frame_index),
            trace.uint("dirty_regions", self.last_diagnostics.dirty_region_count),
        });
        try app.event(self, .{ .lifecycle = .frame });
    }

    pub fn automationSnapshot(self: *Runtime, title: []const u8) automation.snapshot.Input {
        const count = @min(self.window_count, self.automation_windows.len);
        if (count == 0) {
            self.automation_windows[0] = .{ .id = 1, .title = title, .bounds = geometry.RectF.fromSize(self.surface.size), .focused = true };
            return .{
                .windows = self.automation_windows[0..1],
                .views = &.{},
                .widgets = &.{},
                .diagnostics = self.automationDiagnostics(),
                .source = self.loaded_source,
            };
        }
        var view_count: usize = 0;
        var widget_count: usize = 0;
        for (self.windows[0..count], 0..) |window, index| {
            self.automation_windows[index] = .{
                .id = window.info.id,
                .title = if (window.info.title.len > 0) window.info.title else title,
                .bounds = window.info.frame,
                .focused = window.info.focused,
            };
            if (view_count < self.automation_views.len) {
                const views = self.listViews(window.info.id, self.automation_views[view_count..]);
                view_count += views.len;
            }
            self.appendAutomationWidgets(window.info.id, &widget_count);
        }
        return .{
            .windows = self.automation_windows[0..count],
            .views = self.automation_views[0..view_count],
            .widgets = self.automation_widgets[0..widget_count],
            .diagnostics = self.automationDiagnostics(),
            .source = self.loaded_source,
        };
    }

    fn automationDiagnostics(self: *Runtime) automation.snapshot.Diagnostics {
        const now_ns = timestampToU64(nowNanoseconds());
        const uptime_ns = if (self.started_timestamp_ns > 0 and now_ns >= self.started_timestamp_ns) now_ns - self.started_timestamp_ns else 0;
        return .{
            .frame_index = self.last_diagnostics.frame_index,
            .command_count = self.last_diagnostics.command_count,
            .runtime_uptime_ns = uptime_ns,
        };
    }

    pub fn dispatchAutomationCommand(self: *Runtime, app: App, line: []const u8) anyerror!void {
        try self.dispatchAutomationProtocolCommand(app, try automation.protocol.Command.parse(line));
    }

    fn appendAutomationWidgets(self: *Runtime, window_id: platform.WindowId, widget_count: *usize) void {
        for (self.views[0..self.view_count]) |view| {
            if (!view.open or view.window_id != window_id or view.kind != .gpu_surface) continue;
            const layout = view.widgetLayoutTree();
            const semantics = view.widgetSemantics();
            for (semantics) |node| {
                if (widget_count.* >= self.automation_widgets.len) return;
                self.automation_widgets[widget_count.*] = .{
                    .window_id = view.window_id,
                    .view_label = view.label,
                    .id = node.id,
                    .role = widgetRoleName(node.role),
                    .name = node.label,
                    .parent_id = canvasWidgetSemanticParentId(semantics, node.parent_index),
                    .value = node.value,
                    .text_value = node.text_value,
                    .placeholder = node.placeholder,
                    .grid_row_index = node.grid_row_index,
                    .grid_column_index = node.grid_column_index,
                    .grid_row_count = node.grid_row_count,
                    .grid_column_count = node.grid_column_count,
                    .list = .{
                        .present = node.list.present,
                        .item_index = node.list.item_index,
                        .item_count = node.list.item_count,
                    },
                    .scroll = .{
                        .present = node.scroll.present,
                        .offset = node.scroll.offset,
                        .viewport_extent = node.scroll.viewport_extent,
                        .content_extent = node.scroll.content_extent,
                    },
                    .virtual_range = canvasVirtualRange(layout.virtualRangeById(node.id)),
                    .bounds = node.bounds.translate(geometry.OffsetF.init(view.frame.x, view.frame.y)),
                    .focused = node.state.focused or (view.focused and node.id == view.canvas_widget_focused_id),
                    .enabled = !node.state.disabled,
                    .hovered = node.state.hovered or (node.id != 0 and node.id == view.canvas_widget_hovered_id),
                    .pressed = node.state.pressed or (node.id != 0 and node.id == view.canvas_widget_pressed_id),
                    .selected = canvasWidgetSelectedState(node),
                    .expanded = node.state.expanded,
                    .required = node.state.required,
                    .read_only = node.state.read_only,
                    .invalid = node.state.invalid,
                    .actions = canvasWidgetActions(node.actions),
                    .text_selection = canvasTextRange(node.text_selection),
                    .text_composition = canvasTextRange(node.text_composition),
                };
                widget_count.* += 1;
            }
        }
    }

    pub fn frameDiagnostics(self: *Runtime) FrameDiagnostics {
        return self.last_diagnostics;
    }

    pub fn supports(self: *const Runtime, feature: platform.PlatformFeature) bool {
        return self.options.platform.supports(feature);
    }

    fn handlePlatformEvent(context: *anyopaque, event_value: platform.Event) anyerror!void {
        const run_context: *RunContext = @ptrCast(@alignCast(context));
        try run_context.runtime.dispatchPlatformEvent(run_context.app, event_value);
    }

    fn loadStartupWindows(self: *Runtime, app: App) anyerror!void {
        const source = try self.copyLoadedSource(try app.webViewSource());
        self.loaded_source = source;
        const app_info = self.options.platform.app_info;
        const count = app_info.startupWindowCount();
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const window = app_info.resolvedStartupWindow(index);
            const runtime_index = if (self.findWindowIndexById(window.id)) |runtime_index| blk: {
                self.windows[runtime_index].source = try self.copySource(runtime_index, source);
                break :blk runtime_index;
            } else blk: {
                const runtime_index = try self.reserveWindow(window.id, window.label, window.resolvedTitle(app_info.app_name), source, true);
                self.windows[runtime_index].info.frame = window.default_frame;
                self.windows[runtime_index].main_frame = geometry.RectF.init(0, 0, window.default_frame.width, window.default_frame.height);
                break :blk runtime_index;
            };
            self.windows[runtime_index].source_reloads_from_app = true;
            if (index > 0) {
                _ = try self.options.platform.services.createWindow(window);
            }
            try self.options.platform.services.loadWindowWebView(window.id, self.windows[runtime_index].source.?);
            try self.applyMainWebViewState(window.id);
            self.next_window_id = @max(self.next_window_id, window.id + 1);
        }
        try self.log("webview.load", "loaded webview source", &.{
            trace.string("kind", @tagName(source.kind)),
            trace.uint("bytes", source.bytes.len),
        });
    }

    fn loadScene(self: *Runtime, app: App, scene: app_manifest.ShellConfig) anyerror!void {
        try app_manifest.validateShell(scene, &.{});
        if (scene.windows.len == 0) {
            try self.log("scene.load", "loaded empty app scene", &.{trace.string("app", app.name)});
            return;
        }

        const source = if (sceneNeedsMainWebView(scene) or !appUsesDefaultEmptyWebViewSource(app))
            try self.copyLoadedSource(try app.webViewSource())
        else
            null;
        self.loaded_source = source;

        try self.loadStartupSceneWindow(scene.windows[0], source);
        for (scene.windows[1..]) |window| {
            _ = try self.createShellWindowWithSourceMode(window, source, source != null);
        }

        try self.log("scene.load", "loaded app scene", &.{
            trace.string("app", app.name),
            trace.uint("windows", scene.windows.len),
        });
    }

    fn loadStartupSceneWindow(self: *Runtime, shell_window: app_manifest.ShellWindow, source: ?platform.WebViewSource) anyerror!void {
        const app_info = self.options.platform.app_info;
        const startup_window = app_info.resolvedStartupWindow(0);
        const window_id = startup_window.id;
        const manifest_frame = geometry.RectF.init(
            shell_window.x orelse 0,
            shell_window.y orelse 0,
            shell_window.width,
            shell_window.height,
        );
        const startup_frame = startupWindowFrame(startup_window.default_frame, manifest_frame);

        const runtime_index = if (self.findWindowIndexById(window_id)) |index| index else try self.reserveWindow(
            window_id,
            shell_window.label,
            shell_window.title orelse app_info.resolvedWindowTitle(),
            null,
            true,
        );
        if (self.findWindowIndexByLabel(shell_window.label)) |label_index| {
            if (label_index != runtime_index) return error.DuplicateWindowLabel;
        }

        self.windows[runtime_index].info.label = try copyInto(&self.windows[runtime_index].label_storage, shell_window.label);
        self.windows[runtime_index].info.title = try copyInto(&self.windows[runtime_index].title_storage, shell_window.title orelse app_info.resolvedWindowTitle());
        self.windows[runtime_index].info.frame = startup_frame;
        self.windows[runtime_index].source = if (source) |source_value| try self.copySource(runtime_index, source_value) else null;
        self.windows[runtime_index].source_reloads_from_app = source != null;
        if (!self.windows[runtime_index].main_frame_set) {
            self.windows[runtime_index].main_frame = geometry.RectF.init(0, 0, startup_frame.width, startup_frame.height);
        }
        self.next_window_id = @max(self.next_window_id, window_id + 1);

        if (self.windows[runtime_index].source) |window_source| {
            try self.options.platform.services.loadWindowWebView(window_id, window_source);
            try self.applyMainWebViewState(window_id);
        }
        try self.createShellViews(window_id, shell_window.views, self.shellBoundsForWindow(window_id));
    }

    fn applyMainWebViewState(self: *Runtime, window_id: platform.WindowId) anyerror!void {
        const window_index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        const window = self.windows[window_index];
        if (window.main_frame_set) {
            try self.options.platform.services.setWebViewFrame(window_id, "main", window.main_frame);
        }
        if (window.main_layer != 0) {
            try self.options.platform.services.setWebViewLayer(window_id, "main", window.main_layer);
        }
        if (window.main_zoom != 1.0) {
            try self.options.platform.services.setWebViewZoom(window_id, "main", window.main_zoom);
        }
    }

    fn loadWebView(self: *Runtime, app: App) anyerror!void {
        const source = try self.copyLoadedSource(try app.webViewSource());
        self.loaded_source = source;
        try self.options.platform.services.loadWindowWebView(1, source);
    }

    fn reloadWindows(self: *Runtime, app: App) anyerror!void {
        const source = try self.copyLoadedSource(try app.webViewSource());
        self.loaded_source = source;
        if (self.window_count == 0) {
            try self.options.platform.services.loadWindowWebView(1, source);
            return;
        }
        for (self.windows[0..self.window_count], 0..) |*window, index| {
            if (window.source == null or window.source_reloads_from_app) {
                window.source = try self.copySource(index, source);
            }
            const window_source = window.source orelse source;
            try self.options.platform.services.loadWindowWebView(window.info.id, window_source);
        }
    }

    fn handleBridgeMessage(self: *Runtime, app: App, message: platform.BridgeMessage) anyerror!void {
        self.command_count += 1;
        if (try self.handleBuiltinBridgeMessage(app, message)) return;
        var dispatcher = self.options.bridge orelse bridge.Dispatcher{};
        if (self.options.security.permissions.len > 0) dispatcher.policy.permissions = self.options.security.permissions;
        var response_buffer: [bridge.max_response_bytes]u8 = undefined;
        if (try self.handleAsyncBridgeMessage(dispatcher, message)) {
            self.invalidateFor(.command, null);
            return;
        }
        const response = dispatcher.dispatch(message.bytes, .{ .origin = message.origin, .window_id = message.window_id, .webview_label = message.webview_label }, &response_buffer);
        try self.completeBridgeResponse(message.window_id, message.webview_label, response);
        self.invalidateFor(.command, null);
        try self.log("bridge.dispatch", "bridge request handled", &.{
            trace.uint("request_bytes", message.bytes.len),
            trace.uint("response_bytes", response.len),
        });
    }

    fn handleAsyncBridgeMessage(self: *Runtime, dispatcher: bridge.Dispatcher, message: platform.BridgeMessage) anyerror!bool {
        const request = bridge.parseRequest(message.bytes) catch return false;
        const handler = dispatcher.async_registry.find(request.command) orelse return false;
        if (!dispatcher.policy.allows(request.command, message.origin)) {
            var response_buffer: [bridge.max_response_bytes]u8 = undefined;
            const response = bridge.writeErrorResponse(&response_buffer, request.id, .permission_denied, "Bridge command is not permitted");
            try self.completeBridgeResponse(message.window_id, message.webview_label, response);
            return true;
        }
        const source_slot = self.reserveAsyncBridgeResponse(.{
            .origin = message.origin,
            .window_id = message.window_id,
            .webview_label = message.webview_label,
        }) catch |err| {
            var response_buffer: [bridge.max_response_bytes]u8 = undefined;
            const response = bridge.writeErrorResponse(&response_buffer, request.id, .internal_error, @errorName(err));
            try self.completeBridgeResponse(message.window_id, message.webview_label, response);
            return true;
        };
        errdefer source_slot.release();
        try handler.invoke_fn(handler.context, .{
            .request = request,
            .source = source_slot.source,
        }, .{
            .context = source_slot,
            .source = source_slot.source,
            .respond_fn = asyncBridgeRespond,
        });
        return true;
    }

    fn asyncBridgeRespond(context: *anyopaque, source: bridge.Source, response: []const u8) anyerror!void {
        _ = source;
        const slot: *AsyncBridgeResponseSlot = @ptrCast(@alignCast(context));
        try slot.respond(response);
    }

    fn reserveAsyncBridgeResponse(self: *Runtime, source: bridge.Source) !*AsyncBridgeResponseSlot {
        for (&self.async_bridge_responses) |*slot| {
            if (slot.in_use) continue;
            try slot.init(self, source);
            return slot;
        }
        return error.AsyncBridgeResponseLimitReached;
    }

    fn publishAutomation(self: *Runtime) anyerror!void {
        const server = self.options.automation orelse return;
        try server.publish(self.automationSnapshot(server.title));
    }

    fn consumeAutomationCommand(self: *Runtime, app: App) anyerror!void {
        const server = self.options.automation orelse return;
        var buffer: [automation.protocol.max_command_bytes]u8 = undefined;
        const command = try server.takeCommand(&buffer) orelse return;
        try self.dispatchAutomationProtocolCommand(app, command);
    }

    fn dispatchAutomationProtocolCommand(self: *Runtime, app: App, command: automation.protocol.Command) anyerror!void {
        switch (command.action) {
            .reload => {
                self.command_count += 1;
                try self.reloadWindows(app);
                self.invalidateFor(.command, null);
            },
            .bridge => {
                try self.handleBridgeMessage(app, .{ .bytes = command.value, .origin = "zero://inline", .window_id = 1, .webview_label = "main" });
            },
            .resize => {
                const parsed = try parseAutomationResizeCommand(command.value);
                try self.dispatchPlatformEvent(app, .{ .surface_resized = .{
                    .id = 1,
                    .size = geometry.SizeF.init(parsed.width, parsed.height),
                    .scale_factor = parsed.scale_factor,
                } });
            },
            .native_command => {
                const parsed = try parseAutomationNativeCommand(command.value);
                try self.dispatchPlatformEvent(app, .{ .native_command = .{
                    .name = parsed.name,
                    .window_id = 1,
                    .view_label = parsed.view_label,
                } });
            },
            .widget_action => {
                try self.dispatchAutomationWidgetAction(app, try parseAutomationWidgetAction(command.value));
            },
            .widget_click => {
                try self.dispatchAutomationWidgetClick(app, try parseAutomationWidgetTarget(command.value));
            },
            .widget_drag => {
                try self.dispatchAutomationWidgetPointerDrag(app, try parseAutomationWidgetPointerDrag(command.value));
            },
            .widget_wheel => {
                try self.dispatchAutomationWidgetWheel(app, try parseAutomationWidgetWheel(command.value));
            },
            .widget_key => {
                try self.dispatchAutomationWidgetKeyInput(app, try parseAutomationWidgetKey(command.value));
            },
            .menu_command => {
                try self.dispatchPlatformEvent(app, .{ .menu_command = .{
                    .name = try parseAutomationCommandName(command.value),
                    .window_id = 1,
                } });
            },
            .shortcut => {
                try self.dispatchPlatformEvent(app, .{ .shortcut = .{
                    .id = try parseAutomationCommandName(command.value),
                    .key = "",
                    .window_id = 1,
                } });
            },
            .focus_view => {
                try self.focusView(1, try parseAutomationViewLabel(command.value));
            },
            .focus_next_view => {
                _ = try self.focusNextView(1);
            },
            .focus_previous_view => {
                _ = try self.focusPreviousView(1);
            },
            .wait => {},
        }
    }

    fn dispatchAutomationWidgetAction(self: *Runtime, app: App, action: AutomationWidgetAction) anyerror!void {
        const view_index = try self.automationWidgetActionViewIndex(action);
        switch (action.action) {
            .focus => try self.focusAutomationCanvasWidget(view_index, action.id),
            .press => try self.dispatchAutomationWidgetKey(app, view_index, action.id, "enter"),
            .toggle => try self.dispatchAutomationWidgetKey(app, view_index, action.id, "space"),
            .increment => try self.dispatchAutomationWidgetKey(app, view_index, action.id, self.views[view_index].canvasWidgetStepKey(action.id, .increment)),
            .decrement => try self.dispatchAutomationWidgetKey(app, view_index, action.id, self.views[view_index].canvasWidgetStepKey(action.id, .decrement)),
            .set_text => try self.setAutomationCanvasWidgetText(view_index, action.id, action.value),
            .set_selection => try self.editAutomationCanvasWidgetText(view_index, action.id, .{ .set_selection = try parseAutomationTextSelection(action.value) }),
            .set_composition => try self.editAutomationCanvasWidgetText(view_index, action.id, .{ .set_composition = .{ .text = action.value } }),
            .commit_composition => try self.editAutomationCanvasWidgetText(view_index, action.id, .commit_composition),
            .cancel_composition => try self.editAutomationCanvasWidgetText(view_index, action.id, .cancel_composition),
            .select => try self.selectAutomationCanvasWidget(view_index, action.id),
            .drag => try self.dispatchAutomationCanvasWidgetDrag(app, view_index, action.id, action.value),
            .drop_files => try self.dispatchAutomationCanvasWidgetFileDrop(app, view_index, action.id, action.value),
            .dismiss => try self.dismissAutomationCanvasWidget(view_index, action.id),
        }
    }

    fn dispatchCanvasWidgetSemanticControlAction(
        self: *Runtime,
        app: App,
        view_index: usize,
        id: canvas.ObjectId,
        action: canvas.WidgetSemanticAction,
        actions: canvas.WidgetActions,
    ) anyerror!bool {
        if (view_index >= self.view_count) return error.ViewNotFound;
        const node_index = self.views[view_index].canvasWidgetNodeIndexById(id) orelse return false;
        const widget = self.views[view_index].widget_layout_nodes[node_index].widget;
        const intent = canvas.widgetSemanticControlIntentWithActions(widget, action, actions) orelse return false;

        self.views[view_index].recordGpuSurfaceInputTimestamp(automationInputTimestampNs());
        self.beginCanvasWidgetDisplayListRefreshBatch();
        var batch_active = true;
        errdefer if (batch_active) self.cancelCanvasWidgetDisplayListRefreshBatch();

        if (self.views[view_index].widgetLayoutTree().focusTargetById(id) != null) {
            try self.focusAutomationCanvasWidget(view_index, id);
        }

        const toggle_animation = if (intent.kind == .toggle) self.views[view_index].canvasWidgetToggleAnimation(id) else null;
        const dirty = try self.views[view_index].applyCanvasWidgetControlIntent(node_index, intent);
        if (toggle_animation) |animation| try self.scheduleCanvasWidgetToggleAnimation(view_index, animation);
        if (dirty) |bounds| {
            const previous_cursor = self.views[view_index].canvas_widget_cursor;
            switch (intent.kind) {
                .scroll_by, .scroll_to_start, .scroll_to_end => self.views[view_index].reconcileCanvasWidgetRenderStateAfterScroll(null),
                else => {},
            }
            if (previous_cursor != self.views[view_index].canvas_widget_cursor) try self.syncCanvasWidgetCursorForView(view_index);
            try self.invalidateForCanvasWidgetDirty(view_index, bounds);
        }

        try self.endCanvasWidgetDisplayListRefreshBatch();
        batch_active = false;

        if (action == .press and intent.actions.press) {
            try self.dispatchCanvasWidgetCommandForId(app, view_index, id);
        }
        return true;
    }

    fn dispatchAutomationWidgetClick(self: *Runtime, app: App, target: AutomationWidgetTarget) anyerror!void {
        const view_index = try self.automationWidgetTargetViewIndex(target);
        const layout = self.views[view_index].widgetLayoutTree();
        if (!canvasWidgetInteractionTargetExists(layout, target.id)) return error.InvalidCommand;
        const node = layout.findById(target.id) orelse return error.InvalidCommand;
        const bounds = node.frame.normalized();
        if (bounds.isEmpty()) return error.InvalidCommand;
        const point = bounds.center();
        const window_id = self.views[view_index].window_id;
        const label = self.views[view_index].label;
        const timestamp_ns = automationInputTimestampNs();

        try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = window_id,
            .label = label,
            .kind = .pointer_down,
            .timestamp_ns = timestamp_ns,
            .x = point.x,
            .y = point.y,
            .button = 0,
        } });
        try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = window_id,
            .label = label,
            .kind = .pointer_up,
            .timestamp_ns = timestamp_ns,
            .x = point.x,
            .y = point.y,
            .button = 0,
        } });
    }

    fn dispatchAutomationWidgetWheel(self: *Runtime, app: App, wheel: AutomationWidgetWheel) anyerror!void {
        const view_index = try self.automationWidgetTargetViewIndex(wheel.target);
        const layout = self.views[view_index].widgetLayoutTree();
        if (!canvasWidgetInteractionTargetExists(layout, wheel.target.id)) return error.InvalidCommand;
        const node = layout.findById(wheel.target.id) orelse return error.InvalidCommand;
        const bounds = node.frame.normalized();
        if (bounds.isEmpty()) return error.InvalidCommand;
        const point = bounds.center();
        const timestamp_ns = automationInputTimestampNs();
        try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = self.views[view_index].window_id,
            .label = self.views[view_index].label,
            .kind = .scroll,
            .timestamp_ns = timestamp_ns,
            .x = point.x,
            .y = point.y,
            .delta_y = wheel.delta_y,
        } });
    }

    fn dispatchAutomationWidgetKeyInput(self: *Runtime, app: App, key: AutomationWidgetKey) anyerror!void {
        try self.validateViewParent(1);
        try validateViewLabel(key.view_label);
        const view_index = self.findViewIndex(1, key.view_label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;
        try self.focusView(self.views[view_index].window_id, self.views[view_index].label);
        try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = self.views[view_index].window_id,
            .label = self.views[view_index].label,
            .kind = .key_down,
            .timestamp_ns = automationInputTimestampNs(),
            .key = key.key,
            .text = key.text,
        } });
    }

    fn dispatchAutomationWidgetPointerDrag(self: *Runtime, app: App, drag: AutomationWidgetPointerDrag) anyerror!void {
        const view_index = try self.automationWidgetTargetViewIndex(drag.target);
        const layout = self.views[view_index].widgetLayoutTree();
        if (!canvasWidgetInteractionTargetExists(layout, drag.target.id)) return error.InvalidCommand;
        const node = layout.findById(drag.target.id) orelse return error.InvalidCommand;
        const bounds = node.frame.normalized();
        if (bounds.isEmpty()) return error.InvalidCommand;
        const start = geometry.PointF.init(
            bounds.x + bounds.width * drag.start_x_ratio,
            bounds.y + bounds.height * drag.start_y_ratio,
        );
        const end = geometry.PointF.init(
            bounds.x + bounds.width * drag.end_x_ratio,
            bounds.y + bounds.height * drag.end_y_ratio,
        );
        const timestamp_ns = automationInputTimestampNs();

        try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = self.views[view_index].window_id,
            .label = self.views[view_index].label,
            .kind = .pointer_down,
            .timestamp_ns = timestamp_ns,
            .x = start.x,
            .y = start.y,
            .button = 0,
        } });
        try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = self.views[view_index].window_id,
            .label = self.views[view_index].label,
            .kind = .pointer_drag,
            .timestamp_ns = timestamp_ns,
            .x = end.x,
            .y = end.y,
            .delta_x = end.x - start.x,
            .delta_y = end.y - start.y,
            .button = 0,
        } });
        try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = self.views[view_index].window_id,
            .label = self.views[view_index].label,
            .kind = .pointer_up,
            .timestamp_ns = timestamp_ns,
            .x = end.x,
            .y = end.y,
            .button = 0,
        } });
    }

    fn automationWidgetActionViewIndex(self: *Runtime, action: AutomationWidgetAction) anyerror!usize {
        try self.validateViewParent(1);
        try validateViewLabel(action.view_label);
        const view_index = self.findViewIndex(1, action.view_label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;
        const actions = self.canvasWidgetActionsForId(view_index, action.id) orelse return error.InvalidCommand;
        if (!automationWidgetActionSupported(actions, action.action)) return error.InvalidCommand;
        return view_index;
    }

    fn automationWidgetTargetViewIndex(self: *Runtime, target: AutomationWidgetTarget) anyerror!usize {
        try self.validateViewParent(1);
        try validateViewLabel(target.view_label);
        const view_index = self.findViewIndex(1, target.view_label) orelse return error.ViewNotFound;
        if (self.views[view_index].kind != .gpu_surface) return error.InvalidViewOptions;
        return view_index;
    }

    fn canvasWidgetActionsForId(self: *const Runtime, view_index: usize, id: canvas.ObjectId) ?canvas.WidgetActions {
        if (view_index >= self.view_count or id == 0) return null;
        for (self.views[view_index].widgetSemantics()) |node| {
            if (node.id == id) return node.actions;
        }
        return null;
    }

    fn dismissAutomationCanvasWidget(self: *Runtime, view_index: usize, id: canvas.ObjectId) anyerror!void {
        if (view_index >= self.view_count) return error.ViewNotFound;
        self.views[view_index].recordGpuSurfaceInputTimestamp(automationInputTimestampNs());
        const dirty = try self.views[view_index].dismissCanvasWidgetSurfaceForTarget(id) orelse return error.InvalidCommand;
        try self.invalidateForCanvasWidgetDirty(view_index, dirty);
    }

    fn focusAutomationCanvasWidget(self: *Runtime, view_index: usize, id: canvas.ObjectId) anyerror!void {
        if (view_index >= self.view_count) return error.ViewNotFound;
        const target = self.views[view_index].widgetLayoutTree().focusTargetById(id) orelse return error.InvalidCommand;
        try self.focusView(self.views[view_index].window_id, self.views[view_index].label);
        if (self.views[view_index].canvas_widget_focused_id != target.id or self.views[view_index].canvas_widget_focus_visible_id != target.id) {
            const previous_state = self.views[view_index].canvasWidgetRenderState();
            self.views[view_index].canvas_widget_focused_id = target.id;
            self.views[view_index].canvas_widget_focus_visible_id = target.id;
            try self.invalidateForCanvasWidgetRenderStateChange(view_index, previous_state, self.views[view_index].canvasWidgetRenderState());
        }
    }

    fn dispatchAutomationWidgetKey(self: *Runtime, app: App, view_index: usize, id: canvas.ObjectId, key: []const u8) anyerror!void {
        try self.focusAutomationCanvasWidget(view_index, id);
        try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = self.views[view_index].window_id,
            .label = self.views[view_index].label,
            .kind = .key_down,
            .timestamp_ns = automationInputTimestampNs(),
            .key = key,
        } });
    }

    fn selectAutomationCanvasWidget(self: *Runtime, view_index: usize, id: canvas.ObjectId) anyerror!void {
        const layout = self.views[view_index].widgetLayoutTree();
        if (!canvasWidgetSelectableTargetExists(layout, id)) return error.InvalidCommand;
        if (layout.focusTargetById(id) != null) {
            try self.focusAutomationCanvasWidget(view_index, id);
        }
        const dirty = try self.views[view_index].setCanvasWidgetSelected(id, true) orelse return;
        try self.invalidateForCanvasWidgetDirty(view_index, dirty);
    }

    fn setAutomationCanvasWidgetText(self: *Runtime, view_index: usize, id: canvas.ObjectId, text: []const u8) anyerror!void {
        try self.focusAutomationCanvasWidget(view_index, id);
        const dirty = try self.views[view_index].setCanvasWidgetTextValue(id, text) orelse return;
        try self.invalidateForCanvasWidgetDirty(view_index, dirty);
    }

    fn editAutomationCanvasWidgetText(self: *Runtime, view_index: usize, id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!void {
        try self.focusAutomationCanvasWidget(view_index, id);
        if (!self.views[view_index].canEditCanvasWidgetText(id)) return error.InvalidCommand;
        const dirty = try self.views[view_index].applyCanvasWidgetTextEdit(id, edit) orelse return;
        try self.invalidateForCanvasWidgetDirty(view_index, dirty);
    }

    fn dispatchAutomationCanvasWidgetDrag(self: *Runtime, app: App, view_index: usize, id: canvas.ObjectId, value: []const u8) anyerror!void {
        if (view_index >= self.view_count) return error.ViewNotFound;
        const delta = try parseAutomationDragDelta(value);
        const layout = self.views[view_index].widgetLayoutTree();
        if (!canvasWidgetInteractionTargetExists(layout, id)) return error.InvalidCommand;
        const node = layout.findById(id) orelse return error.InvalidCommand;
        const bounds = node.frame.normalized();
        if (bounds.isEmpty()) return error.InvalidCommand;

        const window_id = self.views[view_index].window_id;
        const label = self.views[view_index].label;
        const origin = bounds.center();
        const previous_pressed_id = self.views[view_index].canvas_widget_pressed_id;
        const previous_state = self.views[view_index].canvasWidgetRenderState();
        self.views[view_index].canvas_widget_pressed_id = id;
        if (previous_pressed_id != id) try self.invalidateForCanvasWidgetRenderStateChange(view_index, previous_state, self.views[view_index].canvasWidgetRenderState());
        errdefer {
            if (view_index < self.view_count and self.views[view_index].canvas_widget_pressed_id == id) {
                self.views[view_index].canvas_widget_pressed_id = previous_pressed_id;
            }
        }

        try self.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = window_id,
            .label = label,
            .kind = .pointer_drag,
            .x = origin.x + delta.dx,
            .y = origin.y + delta.dy,
            .delta_x = delta.dx,
            .delta_y = delta.dy,
        } });

        if (self.findViewIndex(window_id, label)) |current_index| {
            if (self.views[current_index].canvas_widget_pressed_id == id) {
                const release_previous_state = self.views[current_index].canvasWidgetRenderState();
                self.views[current_index].canvas_widget_pressed_id = 0;
                try self.invalidateForCanvasWidgetRenderStateChange(current_index, release_previous_state, self.views[current_index].canvasWidgetRenderState());
            }
        }
    }

    fn dispatchAutomationCanvasWidgetFileDrop(self: *Runtime, app: App, view_index: usize, id: canvas.ObjectId, value: []const u8) anyerror!void {
        if (view_index >= self.view_count) return error.ViewNotFound;
        const layout = self.views[view_index].widgetLayoutTree();
        if (!canvasWidgetInteractionTargetExists(layout, id)) return error.InvalidCommand;
        var paths_buffer: [platform.max_drop_paths][]const u8 = undefined;
        const paths = try parseAutomationDropPaths(value, paths_buffer[0..]);
        const node = layout.findById(id) orelse return error.InvalidCommand;
        const bounds = node.frame.normalized();
        if (bounds.isEmpty()) return error.InvalidCommand;

        try self.dispatchPlatformEvent(app, .{ .files_dropped = .{
            .window_id = self.views[view_index].window_id,
            .view_label = self.views[view_index].label,
            .point = bounds.center(),
            .paths = paths,
        } });
    }

    fn invalidateForCanvasWidgetDirty(self: *Runtime, view_index: usize, dirty: geometry.RectF) anyerror!void {
        if (canvasDirtyRegionForView(self.views[view_index].frame, dirty)) |dirty_region| {
            self.invalidateFor(.state, dirty_region);
        } else {
            self.invalidateFor(.state, self.views[view_index].frame);
        }
        _ = try self.refreshCanvasWidgetDisplayListIfOwned(view_index);
    }

    fn createWindowWithSourceMode(self: *Runtime, options: platform.WindowCreateOptions, source_reloads_from_app: bool, source_policy: WindowSourcePolicy) anyerror!platform.WindowInfo {
        const source = options.source orelse self.loaded_source orelse switch (source_policy) {
            .require_source => return error.MissingWindowSource,
            .allow_source_less => null,
        };
        const id = if (options.id != 0) options.id else self.allocateWindowId();
        const label = if (options.label.len > 0) options.label else return error.InvalidWindowOptions;
        try validateWindowFrame(options.default_frame);
        if (self.findWindowIndexById(id) != null) return error.DuplicateWindowId;
        if (self.findWindowIndexByLabel(label) != null) return error.DuplicateWindowLabel;
        const index = try self.reserveWindow(id, label, options.title, source, source_reloads_from_app);
        var native_created = false;
        errdefer self.removeWindowAt(index);
        errdefer if (native_created) self.options.platform.services.closeWindow(id) catch {};

        const window_options = options.windowOptions(id, self.windows[index].info.label);
        const native_info = try self.options.platform.services.createWindow(window_options);
        native_created = true;
        self.applyNativeInfo(index, native_info);
        if (self.windows[index].source) |window_source| {
            try self.options.platform.services.loadWindowWebView(id, window_source);
        }
        self.invalidated = true;
        return self.windows[index].info;
    }

    fn reserveWindow(self: *Runtime, id: platform.WindowId, label: []const u8, title: []const u8, source: ?platform.WebViewSource, source_reloads_from_app: bool) !usize {
        if (self.window_count >= platform.max_windows) return error.WindowLimitReached;
        if (label.len == 0) return error.InvalidWindowOptions;
        const index = self.window_count;
        self.windows[index] = .{};
        const copied_label = try copyInto(&self.windows[index].label_storage, label);
        const copied_title = try copyInto(&self.windows[index].title_storage, title);
        self.windows[index].info = .{
            .id = id,
            .label = copied_label,
            .title = copied_title,
            .open = true,
            .focused = self.window_count == 0,
        };
        self.windows[index].main_view_id = self.allocateViewId();
        self.windows[index].source = if (source) |source_value| try self.copySource(index, source_value) else null;
        self.windows[index].source_reloads_from_app = source_reloads_from_app;
        self.windows[index].main_frame = geometry.RectF.init(0, 0, self.windows[index].info.frame.width, self.windows[index].info.frame.height);
        self.windows[index].main_frame_set = false;
        self.windows[index].main_layer = 0;
        self.windows[index].main_zoom = 1.0;
        self.windows[index].main_focused = self.windows[index].info.focused;
        self.window_count += 1;
        self.next_window_id = @max(self.next_window_id, id + 1);
        return index;
    }

    fn removeWindowAt(self: *Runtime, index: usize) void {
        if (index >= self.window_count) return;
        self.removeShellLayoutForWindow(self.windows[index].info.id);
        var cursor = index;
        while (cursor + 1 < self.window_count) : (cursor += 1) {
            self.windows[cursor] = self.windows[cursor + 1];
        }
        self.window_count -= 1;
    }

    fn copySource(self: *Runtime, index: usize, source: platform.WebViewSource) !platform.WebViewSource {
        return copySourceInto(&self.windows[index].source_storage, source);
    }

    fn copyLoadedSource(self: *Runtime, source: platform.WebViewSource) !platform.WebViewSource {
        return copySourceInto(&self.loaded_source_storage, source);
    }

    fn applyNativeInfo(self: *Runtime, index: usize, native_info: platform.WindowInfo) void {
        self.windows[index].info.frame = native_info.frame;
        self.windows[index].info.scale_factor = native_info.scale_factor;
        self.windows[index].info.open = native_info.open;
        self.windows[index].info.focused = native_info.focused;
        if (!self.windows[index].main_frame_set) {
            self.windows[index].main_frame = geometry.RectF.init(0, 0, native_info.frame.width, native_info.frame.height);
        }
        if (native_info.focused) self.setFocusedIndex(index);
    }

    fn updateWindowState(self: *Runtime, state: platform.WindowState) !void {
        const existing_index = self.findWindowIndexById(state.id);
        const index = existing_index orelse try self.reserveWindow(state.id, state.label, state.title, null, true);
        var info = self.windows[index].info;
        info.frame = state.frame;
        info.scale_factor = state.scale_factor;
        info.open = state.open;
        info.focused = state.focused;
        self.windows[index].info = info;
        if (!self.windows[index].main_frame_set) {
            self.windows[index].main_frame = geometry.RectF.init(0, 0, state.frame.width, state.frame.height);
        }
        if (!state.open) self.removeWindowRuntimeViews(state.id);
        if (state.focused) self.setFocusedIndex(index);
    }

    fn runtimeWindowStateForPersistence(self: *const Runtime, state: platform.WindowState) platform.WindowState {
        var persisted = state;
        if (self.findWindowIndexById(state.id)) |index| {
            persisted.label = self.windows[index].info.label;
            persisted.title = self.windows[index].info.title;
        }
        return persisted;
    }

    fn removeWindowRuntimeViews(self: *Runtime, window_id: platform.WindowId) void {
        if (self.findWindowIndexById(window_id)) |index| self.windows[index].main_parent = null;
        self.removeShellLayoutForWindow(window_id);
        self.removeViewsForWindow(window_id);
        self.removeWebViewsForWindow(window_id);
    }

    fn shellBoundsForWindow(self: *const Runtime, window_id: platform.WindowId) geometry.RectF {
        const index = self.findWindowIndexById(window_id) orelse return geometry.RectF.init(0, 0, 0, 0);
        const frame_value = self.windows[index].info.frame;
        const bounds = geometry.RectF.init(0, 0, frame_value.width, frame_value.height);
        if (self.surface.id != window_id) return bounds;
        return bounds.deflate(combinedViewportInsets(self.surface));
    }

    fn startupWindowFrame(native_frame: geometry.RectF, manifest_frame: geometry.RectF) geometry.RectF {
        const default_frame = (platform.WindowOptions{}).default_frame;
        if (!rectsEqual(native_frame, default_frame)) return native_frame;
        return manifest_frame;
    }

    fn rectsEqual(a: geometry.RectF, b: geometry.RectF) bool {
        return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
    }

    fn canvasDirtyRegionForView(view_frame: geometry.RectF, local_dirty: geometry.RectF) ?geometry.RectF {
        const normalized_view = view_frame.normalized();
        const surface_bounds = geometry.RectF.init(0, 0, normalized_view.width, normalized_view.height);
        const clipped = geometry.RectF.intersection(surface_bounds, local_dirty.normalized());
        if (clipped.isEmpty()) return null;
        return clipped.translate(.{ .dx = normalized_view.x, .dy = normalized_view.y });
    }

    fn bindShellViews(self: *Runtime, window_id: platform.WindowId, views: []const app_manifest.ShellView) !void {
        if (self.findShellLayoutIndex(window_id)) |index| {
            try self.shell_layouts[index].copyViews(views);
            return;
        }
        if (self.shell_layout_count >= self.shell_layouts.len) return error.WindowLimitReached;
        self.shell_layouts[self.shell_layout_count].window_id = window_id;
        try self.shell_layouts[self.shell_layout_count].copyViews(views);
        self.shell_layout_count += 1;
    }

    fn shellLayoutForWindow(self: *const Runtime, window_id: platform.WindowId) ?*const RuntimeShellLayout {
        const index = self.findShellLayoutIndex(window_id) orelse return null;
        return &self.shell_layouts[index];
    }

    fn findShellLayoutIndex(self: *const Runtime, window_id: platform.WindowId) ?usize {
        for (self.shell_layouts[0..self.shell_layout_count], 0..) |layout, index| {
            if (layout.window_id == window_id) return index;
        }
        return null;
    }

    fn removeShellLayoutForWindow(self: *Runtime, window_id: platform.WindowId) void {
        const index = self.findShellLayoutIndex(window_id) orelse return;
        var cursor = index;
        while (cursor + 1 < self.shell_layout_count) : (cursor += 1) {
            self.shell_layouts[cursor] = self.shell_layouts[cursor + 1];
        }
        self.shell_layout_count -= 1;
    }

    fn setFocusedIndex(self: *Runtime, focused_index: usize) void {
        for (self.windows[0..self.window_count], 0..) |*window, index| {
            window.info.focused = index == focused_index;
        }
    }

    fn findWindowIndexById(self: *const Runtime, id: platform.WindowId) ?usize {
        for (self.windows[0..self.window_count], 0..) |window, index| {
            if (window.info.id == id) return index;
        }
        return null;
    }

    fn findWindowIndexByLabel(self: *const Runtime, label: []const u8) ?usize {
        for (self.windows[0..self.window_count], 0..) |window, index| {
            if (std.mem.eql(u8, window.info.label, label)) return index;
        }
        return null;
    }

    fn allocateWindowId(self: *Runtime) platform.WindowId {
        while (self.findWindowIndexById(self.next_window_id) != null) self.next_window_id += 1;
        const id = self.next_window_id;
        self.next_window_id += 1;
        return id;
    }

    fn allocateViewId(self: *Runtime) platform.ViewId {
        const id = self.next_view_id;
        self.next_view_id += 1;
        return id;
    }

    fn handleBuiltinBridgeMessage(self: *Runtime, app: App, message: platform.BridgeMessage) anyerror!bool {
        const request = bridge.parseRequest(message.bytes) catch return false;
        const is_command = std.mem.startsWith(u8, request.command, "zero-native.command.");
        const is_window = std.mem.startsWith(u8, request.command, "zero-native.window.");
        const is_view = std.mem.startsWith(u8, request.command, "zero-native.view.");
        const is_webview = std.mem.startsWith(u8, request.command, "zero-native.webview.");
        const is_platform = std.mem.startsWith(u8, request.command, "zero-native.platform.");
        const is_dialog = std.mem.startsWith(u8, request.command, "zero-native.dialog.");
        const is_os = std.mem.startsWith(u8, request.command, "zero-native.os.");
        const is_clipboard = std.mem.startsWith(u8, request.command, "zero-native.clipboard.");
        const is_credentials = std.mem.startsWith(u8, request.command, "zero-native.credentials.");
        if (!is_command and !is_window and !is_view and !is_webview and !is_platform and !is_dialog and !is_os and !is_clipboard and !is_credentials) return false;

        var response_buffer: [bridge.max_response_bytes]u8 = undefined;
        var result_buffer: [bridge.max_result_bytes]u8 = undefined;
        const js_permission: ?[]const u8 = if (is_command)
            security.permission_command
        else if (is_view)
            security.permission_view
        else if (is_window or is_webview or is_platform)
            security.permission_window
        else
            null;
        if (!self.allowsBuiltinBridgeCommand(request.command, message.origin, js_permission)) {
            const message_text = if (is_view)
                "View API is not permitted"
            else if (is_webview)
                "WebView API is not permitted"
            else if (is_window)
                "Window API is not permitted"
            else if (is_command)
                "Command API is not permitted"
            else if (is_platform)
                "Platform API is not permitted"
            else if (is_os)
                "OS API is not permitted"
            else if (is_clipboard)
                "Clipboard API is not permitted"
            else if (is_credentials)
                "Credentials API is not permitted"
            else
                "Dialog API is not permitted";
            const result = bridge.writeErrorResponse(&response_buffer, request.id, .permission_denied, message_text);
            try self.completeBridgeResponse(message.window_id, message.webview_label, result);
            self.invalidateFor(.command, null);
            return true;
        }
        const result = if (is_command)
            self.dispatchCommandBridgeCommand(app, request, message.window_id, message.webview_label, &result_buffer, &response_buffer)
        else if (is_window)
            self.dispatchWindowBridgeCommand(request, &result_buffer, &response_buffer)
        else if (is_view)
            self.dispatchViewBridgeCommand(request, message.window_id, &result_buffer, &response_buffer)
        else if (is_webview)
            self.dispatchWebViewBridgeCommand(request, message.window_id, &result_buffer, &response_buffer)
        else if (is_platform)
            self.dispatchPlatformBridgeCommand(request, &result_buffer, &response_buffer)
        else if (is_dialog)
            self.dispatchDialogBridgeCommand(request, &result_buffer, &response_buffer)
        else if (is_clipboard)
            self.dispatchClipboardBridgeCommand(request, &result_buffer, &response_buffer)
        else if (is_credentials)
            self.dispatchCredentialBridgeCommand(request, &result_buffer, &response_buffer)
        else
            self.dispatchOsBridgeCommand(request, &result_buffer, &response_buffer);

        try self.completeBridgeResponse(message.window_id, message.webview_label, result);
        self.invalidateFor(.command, null);
        return true;
    }

    fn completeBridgeResponse(self: *Runtime, window_id: platform.WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
        try self.options.platform.services.completeWebViewBridge(window_id, webview_label, response);
        if (self.options.automation) |server| {
            server.publishBridgeResponse(response) catch |err| try self.log("automation.bridge_response_failed", @errorName(err), &.{});
        }
    }

    fn emitShortcutEvent(self: *Runtime, shortcut: platform.ShortcutEvent) anyerror!void {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.writeAll("{\"id\":");
        try json.writeString(&writer, shortcut.id);
        try writer.writeAll(",\"command\":");
        try json.writeString(&writer, shortcut.id);
        try writer.writeAll(",\"key\":");
        try json.writeString(&writer, shortcut.key);
        try writer.print(",\"windowId\":{d},\"modifiers\":{{\"primary\":{},\"command\":{},\"control\":{},\"option\":{},\"shift\":{}}}}}", .{
            shortcut.window_id,
            shortcut.modifiers.primary,
            shortcut.modifiers.command,
            shortcut.modifiers.control,
            shortcut.modifiers.option,
            shortcut.modifiers.shift,
        });
        try self.emitWindowEvent(shortcut.window_id, "shortcut", writer.buffered());
    }

    fn emitAppLifecycleEvent(self: *Runtime, name: []const u8) anyerror!void {
        for (self.windows[0..self.window_count]) |window| {
            if (window.info.open) try self.emitWindowEvent(window.info.id, name, "{}");
        }
    }

    fn emitFileDropEvent(self: *Runtime, drop: platform.FileDropEvent) anyerror!void {
        var buffer: [platform.max_window_event_detail_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.print("{{\"windowId\":{d}", .{drop.window_id});
        if (drop.view_label.len > 0) {
            try writer.writeAll(",\"viewLabel\":");
            try json.writeString(&writer, drop.view_label);
        }
        if (drop.point) |point| {
            try writer.print(",\"x\":{d},\"y\":{d}", .{ point.x, point.y });
        }
        try writer.writeAll(",\"paths\":[");
        for (drop.paths, 0..) |path, index| {
            if (index > 0) try writer.writeByte(',');
            try json.writeString(&writer, path);
        }
        try writer.writeAll("]}");
        try self.emitWindowEvent(drop.window_id, "drop:files", writer.buffered());
    }

    fn allowsBuiltinBridgeCommand(self: *Runtime, command: []const u8, origin: []const u8, js_permission: ?[]const u8) bool {
        var policy = self.options.builtin_bridge;
        if (self.options.security.permissions.len > 0) policy.permissions = self.options.security.permissions;
        if (policy.enabled) return policy.allows(command, origin);
        const permission = js_permission orelse return false;
        if (!self.options.js_window_api) return false;
        if (!security.allowsOrigin(self.options.security.navigation.allowed_origins, origin)) return false;
        if (self.options.security.permissions.len == 0) return true;
        return security.hasPermission(self.options.security.permissions, permission) or
            (!std.mem.eql(u8, permission, security.permission_window) and security.hasPermission(self.options.security.permissions, security.permission_window));
    }

    fn dispatchCommandBridgeCommand(self: *Runtime, app: App, request: bridge.Request, source_window_id: platform.WindowId, source_view_label: []const u8, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.command.invoke"))
            self.invokeCommandFromJson(app, request.payload, source_window_id, source_view_label, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.command.list"))
            self.writeCommandListJson(result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown command command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn dispatchPlatformBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.platform.supports"))
            self.supportsFeatureFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown platform command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn dispatchWindowBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.window.list"))
            self.writeWindowListJson(result_buffer) catch return bridge.writeErrorResponse(response_buffer, request.id, .internal_error, "Failed to list windows")
        else if (std.mem.eql(u8, request.command, "zero-native.window.create"))
            self.createWindowFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.window.focus"))
            self.focusWindowFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.window.close"))
            self.closeWindowFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown window command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn invokeCommandFromJson(self: *Runtime, app: App, payload: []const u8, source_window_id: platform.WindowId, source_view_label: []const u8, output: []u8) ![]const u8 {
        var scratch: [max_command_id_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const name = jsonStringField(payload, "name", &storage) orelse jsonStringField(payload, "id", &storage) orelse return error.InvalidCommand;
        const view_label = if (std.mem.eql(u8, source_view_label, "main")) "" else source_view_label;
        const event: CommandEvent = .{
            .name = name,
            .source = .bridge,
            .window_id = source_window_id,
            .view_label = view_label,
        };
        try self.dispatchCommand(app, event);
        return writeCommandEventJson(event, output);
    }

    fn writeCommandListJson(self: *Runtime, output: []u8) ![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        try writer.writeByte('[');
        for (self.options.commands, 0..) |command, index| {
            if (index > 0) try writer.writeByte(',');
            try writeCommandJsonToWriter(command, &writer);
        }
        try writer.writeByte(']');
        return writer.buffered();
    }

    fn dispatchViewBridgeCommand(self: *Runtime, request: bridge.Request, source_window_id: platform.WindowId, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.view.create"))
            self.createViewFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.view.list"))
            self.writeViewListJson(source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.view.update"))
            self.updateViewFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.view.setFrame"))
            self.setViewFrameFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.view.setVisible"))
            self.setViewVisibleFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.view.focus"))
            self.focusViewFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.view.focusNext"))
            self.focusNextViewFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.view.focusPrevious"))
            self.focusPreviousViewFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.view.close"))
            self.closeViewFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown view command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn dispatchWebViewBridgeCommand(self: *Runtime, request: bridge.Request, source_window_id: platform.WindowId, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.webview.create"))
            self.createWebViewFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.webview.list"))
            self.writeWebViewListJson(source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.webview.setFrame"))
            self.setWebViewFrameFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.webview.navigate"))
            self.navigateWebViewFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.webview.setZoom"))
            self.setWebViewZoomFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.webview.setLayer"))
            self.setWebViewLayerFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.webview.close"))
            self.closeWebViewFromJson(request.payload, source_window_id, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown WebView command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn dispatchDialogBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.dialog.openFile"))
            self.openFileDialogFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.dialog.saveFile"))
            self.saveFileDialogFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.dialog.showMessage"))
            self.showMessageDialogFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown dialog command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn dispatchOsBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.os.openUrl"))
            self.openExternalUrlFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.os.showNotification"))
            self.showNotificationFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.os.revealPath"))
            self.revealPathFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.os.addRecentDocument"))
            self.addRecentDocumentFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.os.clearRecentDocuments"))
            self.clearRecentDocumentsFromJson(result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown OS command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn dispatchCredentialBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.credentials.set"))
            self.setCredentialFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.credentials.get"))
            self.getCredentialFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.credentials.delete"))
            self.deleteCredentialFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown credentials command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn dispatchClipboardBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.clipboard.readText"))
            self.readClipboardTextFromJson(result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.clipboard.writeText"))
            self.writeClipboardTextFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.clipboard.read"))
            self.readClipboardDataFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.clipboard.write"))
            self.writeClipboardDataFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, builtinBridgeErrorCode(err), builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown clipboard command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn readClipboardTextFromJson(self: *Runtime, output: []u8) ![]const u8 {
        var value_buffer: [bridge.max_result_bytes]u8 = undefined;
        const value = try self.readClipboard(&value_buffer);
        var writer = std.Io.Writer.fixed(output);
        try json.writeString(&writer, value);
        return writer.buffered();
    }

    fn supportsFeatureFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var scratch: [64]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const feature_name = jsonStringField(payload, "feature", &storage) orelse jsonStringField(payload, "name", &storage) orelse return error.InvalidPlatformFeature;
        const feature = platformFeatureFromString(feature_name) orelse return error.InvalidPlatformFeature;
        return writeBoolJson(self.supports(feature), output);
    }

    fn writeClipboardTextFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const text = jsonStringField(payload, "text", &storage) orelse jsonStringField(payload, "data", &storage) orelse jsonStringField(payload, "value", &storage) orelse return error.InvalidClipboardOptions;
        try self.writeClipboard(text);
        return writeTrueJson(output);
    }

    fn readClipboardDataFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var mime_storage_buffer: [platform.max_clipboard_mime_type_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&mime_storage_buffer);
        const mime_type = jsonStringField(payload, "mimeType", &storage) orelse jsonStringField(payload, "type", &storage) orelse "text/plain";
        var value_buffer: [bridge.max_result_bytes]u8 = undefined;
        const value = try self.readClipboardData(mime_type, &value_buffer);
        var writer = std.Io.Writer.fixed(output);
        try writer.writeAll("{\"mimeType\":");
        try json.writeString(&writer, mime_type);
        try writer.writeAll(",\"data\":");
        try json.writeString(&writer, value);
        try writer.writeByte('}');
        return writer.buffered();
    }

    fn writeClipboardDataFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const mime_type = jsonStringField(payload, "mimeType", &storage) orelse jsonStringField(payload, "type", &storage) orelse "text/plain";
        const data = jsonStringField(payload, "data", &storage) orelse jsonStringField(payload, "text", &storage) orelse jsonStringField(payload, "value", &storage) orelse return error.InvalidClipboardOptions;
        try self.writeClipboardData(.{ .mime_type = mime_type, .bytes = data });
        return writeTrueJson(output);
    }

    fn setCredentialFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const service = jsonStringField(payload, "service", &storage) orelse return error.InvalidCredentialOptions;
        const account = jsonStringField(payload, "account", &storage) orelse return error.InvalidCredentialOptions;
        const secret = jsonStringField(payload, "secret", &storage) orelse jsonStringField(payload, "value", &storage) orelse return error.InvalidCredentialOptions;
        try self.setCredential(.{ .service = service, .account = account, .secret = secret });
        return writeTrueJson(output);
    }

    fn getCredentialFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const service = jsonStringField(payload, "service", &storage) orelse return error.InvalidCredentialOptions;
        const account = jsonStringField(payload, "account", &storage) orelse return error.InvalidCredentialOptions;
        var secret_buffer: [platform.max_credential_secret_bytes]u8 = undefined;
        const secret = try self.getCredential(.{ .service = service, .account = account }, &secret_buffer);
        var writer = std.Io.Writer.fixed(output);
        if (secret) |value| {
            try json.writeString(&writer, value);
        } else {
            try writer.writeAll("null");
        }
        return writer.buffered();
    }

    fn deleteCredentialFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const service = jsonStringField(payload, "service", &storage) orelse return error.InvalidCredentialOptions;
        const account = jsonStringField(payload, "account", &storage) orelse return error.InvalidCredentialOptions;
        var writer = std.Io.Writer.fixed(output);
        try writer.writeAll(if (try self.deleteCredential(.{ .service = service, .account = account })) "true" else "false");
        return writer.buffered();
    }

    fn showNotificationFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const title = jsonStringField(payload, "title", &storage) orelse return error.InvalidNotificationOptions;
        const subtitle = jsonStringField(payload, "subtitle", &storage) orelse "";
        const body = jsonStringField(payload, "body", &storage) orelse jsonStringField(payload, "message", &storage) orelse "";
        try self.showNotification(.{
            .title = title,
            .subtitle = subtitle,
            .body = body,
        });
        return writeTrueJson(output);
    }

    fn openExternalUrlFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const url = jsonStringField(payload, "url", &storage) orelse return error.InvalidExternalUrl;
        try self.openExternalUrl(url);
        return writeTrueJson(output);
    }

    fn revealPathFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const path = jsonStringField(payload, "path", &storage) orelse return error.InvalidRevealPath;
        try self.revealPath(path);
        return writeTrueJson(output);
    }

    fn addRecentDocumentFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const path = jsonStringField(payload, "path", &storage) orelse return error.InvalidRecentDocumentPath;
        try self.addRecentDocument(path);
        return writeTrueJson(output);
    }

    fn clearRecentDocumentsFromJson(self: *Runtime, output: []u8) ![]const u8 {
        try self.clearRecentDocuments();
        return writeTrueJson(output);
    }

    fn openFileDialogFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const title = jsonStringField(payload, "title", &storage) orelse "";
        const default_path = jsonStringField(payload, "defaultPath", &storage) orelse "";
        const allow_dirs = jsonBoolField(payload, "allowDirectories") orelse false;
        const allow_multi = jsonBoolField(payload, "allowMultiple") orelse false;
        var dialog_buffer: [platform.max_dialog_paths_bytes]u8 = undefined;
        const result = try self.showOpenDialog(.{
            .title = title,
            .default_path = default_path,
            .allow_directories = allow_dirs,
            .allow_multiple = allow_multi,
        }, &dialog_buffer);

        var writer = std.Io.Writer.fixed(output);
        if (result.count == 0) {
            try writer.writeAll("null");
        } else {
            try writer.writeByte('[');
            var start: usize = 0;
            var i: usize = 0;
            for (result.paths, 0..) |ch, pos| {
                if (ch == '\n') {
                    if (i > 0) try writer.writeByte(',');
                    try json.writeString(&writer, result.paths[start..pos]);
                    start = pos + 1;
                    i += 1;
                }
            }
            if (start < result.paths.len) {
                if (i > 0) try writer.writeByte(',');
                try json.writeString(&writer, result.paths[start..]);
            }
            try writer.writeByte(']');
        }
        return writer.buffered();
    }

    fn saveFileDialogFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const title = jsonStringField(payload, "title", &storage) orelse "";
        const default_path = jsonStringField(payload, "defaultPath", &storage) orelse "";
        const default_name = jsonStringField(payload, "defaultName", &storage) orelse "";
        var dialog_buffer: [platform.max_dialog_path_bytes]u8 = undefined;
        const path = try self.showSaveDialog(.{
            .title = title,
            .default_path = default_path,
            .default_name = default_name,
        }, &dialog_buffer);

        var writer = std.Io.Writer.fixed(output);
        if (path) |p| {
            try json.writeString(&writer, p);
        } else {
            try writer.writeAll("null");
        }
        return writer.buffered();
    }

    fn showMessageDialogFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const title = jsonStringField(payload, "title", &storage) orelse "";
        const message = jsonStringField(payload, "message", &storage) orelse "";
        const informative = jsonStringField(payload, "informativeText", &storage) orelse "";
        const primary = jsonStringField(payload, "primaryButton", &storage) orelse "OK";
        const secondary = jsonStringField(payload, "secondaryButton", &storage) orelse "";
        const tertiary = jsonStringField(payload, "tertiaryButton", &storage) orelse "";
        const style_str = jsonStringField(payload, "style", &storage) orelse "info";
        const style: platform.MessageDialogStyle = if (std.mem.eql(u8, style_str, "warning"))
            .warning
        else if (std.mem.eql(u8, style_str, "critical"))
            .critical
        else
            .info;

        const result = try self.showMessageDialog(.{
            .style = style,
            .title = title,
            .message = message,
            .informative_text = informative,
            .primary_button = primary,
            .secondary_button = secondary,
            .tertiary_button = tertiary,
        });

        var writer = std.Io.Writer.fixed(output);
        try json.writeString(&writer, @tagName(result));
        return writer.buffered();
    }

    fn createWindowFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const label = jsonStringField(payload, "label", &storage) orelse "window";
        const title = jsonStringField(payload, "title", &storage) orelse "";
        const width = jsonNumberField(payload, "width") orelse 720;
        const height = jsonNumberField(payload, "height") orelse 480;
        const x = jsonNumberField(payload, "x") orelse 0;
        const y = jsonNumberField(payload, "y") orelse 0;
        const source = if (jsonStringField(payload, "url", &storage)) |url| platform.WebViewSource.url(url) else null;
        const info = try self.createWindow(.{
            .label = label,
            .title = title,
            .default_frame = geometry.RectF.init(x, y, width, height),
            .restore_state = jsonBoolField(payload, "restoreState") orelse true,
            .source = source,
        });
        return writeWindowJson(info, output);
    }

    fn createViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_view_label_bytes * 2 + platform.max_view_role_bytes + platform.max_view_accessibility_label_bytes + platform.max_view_text_bytes + platform.max_view_command_bytes + platform.max_webview_url_bytes + 96]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
        const kind_str = jsonStringField(payload, "kind", &storage) orelse return error.InvalidViewOptions;
        const kind = viewKindFromString(kind_str) orelse return error.UnsupportedViewKind;
        const window_id = try viewWindowIdFromJson(payload, source_window_id);
        const role = jsonStringField(payload, "role", &storage) orelse "";
        const accessibility_label = jsonStringField(payload, "accessibilityLabel", &storage) orelse jsonStringField(payload, "accessibility_label", &storage) orelse "";
        const text = jsonStringField(payload, "text", &storage) orelse "";
        const command = jsonStringField(payload, "command", &storage) orelse "";
        const parent = jsonStringField(payload, "parent", &storage);
        const url = jsonStringField(payload, "url", &storage) orelse "";
        const info = try self.createView(.{
            .window_id = window_id,
            .label = label,
            .kind = kind,
            .parent = parent,
            .frame = (try viewFrameFromJson(payload, kind == .webview)) orelse geometry.RectF.init(0, 0, 0, 0),
            .layer = try viewLayerFromJson(payload) orelse 0,
            .visible = jsonBoolField(payload, "visible") orelse true,
            .enabled = jsonBoolField(payload, "enabled") orelse true,
            .role = role,
            .accessibility_label = accessibility_label,
            .text = text,
            .command = command,
            .url = url,
            .transparent = jsonBoolField(payload, "transparent") orelse false,
            .bridge_enabled = jsonBoolField(payload, "bridge") orelse false,
            .gpu_surface = try gpuSurfaceOptionsFromJson(payload, &storage),
        });
        return writeViewJson(info, output);
    }

    fn updateViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_view_label_bytes + platform.max_view_role_bytes + platform.max_view_accessibility_label_bytes + platform.max_view_text_bytes + platform.max_view_command_bytes + platform.max_webview_url_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
        const window_id = try viewWindowIdFromJson(payload, source_window_id);
        const patch: platform.ViewPatch = .{
            .frame = try viewFrameFromJson(payload, false),
            .layer = try viewLayerFromJson(payload),
            .visible = jsonBoolField(payload, "visible"),
            .enabled = jsonBoolField(payload, "enabled"),
            .role = jsonStringField(payload, "role", &storage),
            .accessibility_label = jsonStringField(payload, "accessibilityLabel", &storage) orelse jsonStringField(payload, "accessibility_label", &storage),
            .text = jsonStringField(payload, "text", &storage),
            .command = jsonStringField(payload, "command", &storage),
            .url = jsonStringField(payload, "url", &storage),
        };
        const info = try self.updateView(window_id, label, patch);
        return writeViewJson(info, output);
    }

    fn setViewFrameFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_view_label_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
        const window_id = try viewWindowIdFromJson(payload, source_window_id);
        const info = try self.updateView(window_id, label, .{ .frame = try viewFrameFromJson(payload, true) });
        return writeViewJson(info, output);
    }

    fn setViewVisibleFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_view_label_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
        const visible = jsonBoolField(payload, "visible") orelse return error.InvalidViewOptions;
        const window_id = try viewWindowIdFromJson(payload, source_window_id);
        const info = try self.updateView(window_id, label, .{ .visible = visible });
        return writeViewJson(info, output);
    }

    fn focusViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_view_label_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
        const window_id = try viewWindowIdFromJson(payload, source_window_id);
        try self.focusView(window_id, label);
        var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
        for (self.listViews(window_id, &views_buffer)) |view| {
            if (std.mem.eql(u8, view.label, label)) return writeViewJson(view, output);
        }
        return error.ViewNotFound;
    }

    fn focusNextViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        const window_id = try viewWindowIdFromJson(payload, source_window_id);
        const info = try self.focusNextView(window_id);
        return writeViewJson(info, output);
    }

    fn focusPreviousViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        const window_id = try viewWindowIdFromJson(payload, source_window_id);
        const info = try self.focusPreviousView(window_id);
        return writeViewJson(info, output);
    }

    fn closeViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_view_label_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse return error.InvalidViewOptions;
        const window_id = try viewWindowIdFromJson(payload, source_window_id);
        var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
        for (self.listViews(window_id, &views_buffer)) |view| {
            if (std.mem.eql(u8, view.label, label)) {
                var closed = view;
                closed.open = false;
                closed.focused = false;
                const result = try writeViewJson(closed, output);
                try self.closeView(window_id, label);
                return result;
            }
        }
        return error.ViewNotFound;
    }

    fn writeViewListJson(self: *Runtime, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        try self.validateViewParent(source_window_id);
        var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
        const views = self.listViews(source_window_id, &views_buffer);
        var writer = std.Io.Writer.fixed(output);
        try writer.writeByte('[');
        for (views, 0..) |view, index| {
            if (index > 0) try writer.writeByte(',');
            try writeViewJsonToWriter(view, &writer);
        }
        try writer.writeByte(']');
        return writer.buffered();
    }

    fn createWebViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_webview_label_bytes + platform.max_webview_url_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse "webview";
        const url = jsonStringField(payload, "url", &storage) orelse return error.MissingWebViewUrl;
        const window_id = try webViewWindowIdFromJson(payload, source_window_id);
        const webview_frame = try webViewFrameFromJson(payload);
        const layer = try webViewLayerFromJson(payload);
        const transparent = jsonBoolField(payload, "transparent") orelse false;
        const bridge_enabled = jsonBoolField(payload, "bridge") orelse false;
        try self.validateWebViewParent(window_id);
        try validateChildWebViewLabel(label);
        try self.validateWebViewUrl(url);
        if (self.findWebViewIndex(window_id, label) != null) return error.DuplicateWebViewLabel;
        if (self.viewLabelExists(window_id, label)) return error.DuplicateViewLabel;
        if (self.webview_count >= platform.max_webviews) return error.WebViewLimitReached;
        try self.options.platform.services.createWebView(.{
            .window_id = window_id,
            .label = label,
            .url = url,
            .frame = webview_frame,
            .layer = layer,
            .transparent = transparent,
            .bridge_enabled = bridge_enabled,
        });
        var reserved = false;
        errdefer {
            if (reserved) {
                if (self.findWebViewIndex(window_id, label)) |index| self.removeWebViewAt(index);
            }
            self.options.platform.services.closeWebView(window_id, label) catch {};
        }
        try self.reserveWebView(self.allocateViewId(), window_id, label, null, url, webview_frame, webview_frame, layer, transparent, bridge_enabled);
        reserved = true;
        return writeWebViewJson(self.webviews[self.webview_count - 1], output);
    }

    fn setWebViewFrameFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_webview_label_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse "webview";
        const window_id = try webViewWindowIdFromJson(payload, source_window_id);
        const webview_frame = try webViewFrameFromJson(payload);
        try self.validateWebViewParent(window_id);
        try validateWebViewLabel(label);
        if (isMainWebViewLabel(label)) {
            const window_index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
            try self.options.platform.services.setWebViewFrame(window_id, label, webview_frame);
            self.windows[window_index].main_frame = webview_frame;
            self.windows[window_index].main_frame_set = true;
            try self.relayoutDescendantWebViewBackends(window_id, label);
            return writeWebViewJson(self.mainWebViewInfo(window_index), output);
        }
        const webview_index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        try self.options.platform.services.setWebViewFrame(window_id, label, webview_frame);
        self.webviews[webview_index].local_frame = try self.localFrameForView(window_id, self.webviews[webview_index].parent, webview_frame);
        self.webviews[webview_index].frame = webview_frame;
        try self.relayoutDescendantWebViewBackends(window_id, label);
        return writeWebViewJson(self.webviews[webview_index], output);
    }

    fn navigateWebViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_webview_label_bytes + platform.max_webview_url_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse "webview";
        const url = jsonStringField(payload, "url", &storage) orelse return error.MissingWebViewUrl;
        const window_id = try webViewWindowIdFromJson(payload, source_window_id);
        try self.validateWebViewParent(window_id);
        try validateWebViewLabel(label);
        try self.validateWebViewUrl(url);
        if (isMainWebViewLabel(label)) return error.InvalidWebViewOptions;
        const webview_index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        try self.options.platform.services.navigateWebView(window_id, label, url);
        self.webviews[webview_index].url = try copyInto(&self.webviews[webview_index].url_storage, url);
        return writeWebViewJson(self.webviews[webview_index], output);
    }

    fn setWebViewZoomFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_webview_label_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse "webview";
        const zoom_f32 = jsonNumberField(payload, "zoom") orelse return error.InvalidWebViewOptions;
        const zoom: f64 = @floatCast(zoom_f32);
        if (zoom < 0.25 or zoom > 5.0) return error.InvalidWebViewOptions;
        const window_id = try webViewWindowIdFromJson(payload, source_window_id);
        try self.validateWebViewParent(window_id);
        try validateWebViewLabel(label);
        if (isMainWebViewLabel(label)) {
            const window_index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
            try self.options.platform.services.setWebViewZoom(window_id, label, zoom);
            self.windows[window_index].main_zoom = zoom;
            return writeWebViewJson(self.mainWebViewInfo(window_index), output);
        }
        const webview_index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        try self.options.platform.services.setWebViewZoom(window_id, label, zoom);
        self.webviews[webview_index].zoom = zoom;
        return writeWebViewJson(self.webviews[webview_index], output);
    }

    fn setWebViewLayerFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_webview_label_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse "webview";
        const window_id = try webViewWindowIdFromJson(payload, source_window_id);
        try self.validateWebViewParent(window_id);
        try validateWebViewLabel(label);
        const layer = try webViewLayerFromJson(payload);
        if (isMainWebViewLabel(label)) {
            const window_index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
            try self.options.platform.services.setWebViewLayer(window_id, label, layer);
            self.windows[window_index].main_layer = layer;
            return writeWebViewJson(self.mainWebViewInfo(window_index), output);
        }
        const webview_index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        try self.options.platform.services.setWebViewLayer(window_id, label, layer);
        self.webviews[webview_index].layer = layer;
        return writeWebViewJson(self.webviews[webview_index], output);
    }

    fn closeWebViewFromJson(self: *Runtime, payload: []const u8, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        var scratch: [platform.max_webview_label_bytes]u8 = undefined;
        var storage = json.StringStorage.init(&scratch);
        const label = jsonStringField(payload, "label", &storage) orelse "webview";
        const window_id = try webViewWindowIdFromJson(payload, source_window_id);
        try self.validateWebViewParent(window_id);
        try validateWebViewLabel(label);
        if (isMainWebViewLabel(label)) return error.InvalidWebViewOptions;
        const webview_index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        var closed_info = self.webviews[webview_index];
        closed_info.open = false;
        closed_info.focused = false;
        const result = try writeWebViewJson(closed_info, output);
        try self.options.platform.services.closeWebView(window_id, label);
        const was_focused = self.webviews[webview_index].focused;
        self.removeWebViewAt(webview_index);
        if (was_focused) self.ensureFocusableViewFocused(window_id);
        return result;
    }

    fn validateWebViewParent(self: *Runtime, window_id: platform.WindowId) !void {
        const index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        if (!self.windows[index].info.open) return error.WindowNotFound;
    }

    fn validateWebViewUrl(self: *Runtime, url: []const u8) !void {
        if (url.len == 0) return error.MissingWebViewUrl;
        if (url.len > platform.max_webview_url_bytes) return error.WebViewUrlTooLarge;
        var origin_buffer: [512]u8 = undefined;
        const origin = try webViewUrlOrigin(url, &origin_buffer);
        if (!security.allowsOrigin(self.options.security.navigation.allowed_origins, origin)) return error.NavigationDenied;
    }

    fn validateExternalUrl(self: *Runtime, url: []const u8) !void {
        if (url.len == 0) return error.InvalidExternalUrl;
        if (url.len > platform.max_external_url_bytes) return error.ExternalUrlTooLarge;
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidExternalUrl;
        for (url) |ch| {
            if (ch <= 0x20 or ch == 0x7f) return error.InvalidExternalUrl;
        }
        if (!security.allowsExternalUrl(self.options.security.navigation.external_links, url)) return error.NavigationDenied;
    }

    fn writeWebViewListJson(self: *Runtime, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
        try self.validateWebViewParent(source_window_id);
        var writer = std.Io.Writer.fixed(output);
        try writer.writeByte('[');
        const window_index = self.findWindowIndexById(source_window_id) orelse return error.WindowNotFound;
        try writeWebViewJsonToWriter(self.mainWebViewInfo(window_index), &writer);
        var written: usize = 1;
        for (self.webviews[0..self.webview_count]) |webview| {
            if (webview.window_id != source_window_id or !webview.open) continue;
            if (written > 0) try writer.writeByte(',');
            try writeWebViewJsonToWriter(webview, &writer);
            written += 1;
        }
        try writer.writeByte(']');
        return writer.buffered();
    }

    fn reserveWebView(self: *Runtime, id: platform.ViewId, window_id: platform.WindowId, label: []const u8, parent: ?[]const u8, url: []const u8, local_frame: geometry.RectF, platform_frame: geometry.RectF, layer: i32, transparent: bool, bridge_enabled: bool) !void {
        const index = self.webview_count;
        self.webviews[index] = .{
            .id = id,
            .window_id = window_id,
            .frame = platform_frame,
            .local_frame = local_frame,
            .layer = layer,
            .transparent = transparent,
            .bridge_enabled = bridge_enabled,
            .open = true,
        };
        self.webviews[index].label = try copyInto(&self.webviews[index].label_storage, label);
        self.webviews[index].parent = if (parent) |value| try copyInto(&self.webviews[index].parent_storage, value) else null;
        self.webviews[index].url = try copyInto(&self.webviews[index].url_storage, url);
        self.webview_count += 1;
    }

    fn findWebViewIndex(self: *const Runtime, window_id: platform.WindowId, label: []const u8) ?usize {
        for (self.webviews[0..self.webview_count], 0..) |webview, index| {
            if (webview.open and webview.window_id == window_id and std.mem.eql(u8, webview.label, label)) return index;
        }
        return null;
    }

    fn removeWebViewAt(self: *Runtime, index: usize) void {
        if (index >= self.webview_count) return;
        var cursor = index;
        while (cursor + 1 < self.webview_count) : (cursor += 1) {
            const next = self.webviews[cursor + 1];
            self.webviews[cursor] = .{
                .id = next.id,
                .window_id = next.window_id,
                .frame = next.frame,
                .local_frame = next.local_frame,
                .layer = next.layer,
                .zoom = next.zoom,
                .transparent = next.transparent,
                .bridge_enabled = next.bridge_enabled,
                .focused = next.focused,
                .open = next.open,
            };
            self.webviews[cursor].label = copyInto(&self.webviews[cursor].label_storage, next.label) catch unreachable;
            self.webviews[cursor].parent = if (next.parent) |parent| copyInto(&self.webviews[cursor].parent_storage, parent) catch unreachable else null;
            self.webviews[cursor].url = copyInto(&self.webviews[cursor].url_storage, next.url) catch unreachable;
        }
        self.webview_count -= 1;
    }

    fn removeWebViewsForWindow(self: *Runtime, window_id: platform.WindowId) void {
        var index: usize = 0;
        while (index < self.webview_count) {
            if (self.webviews[index].window_id == window_id) {
                self.removeWebViewAt(index);
            } else {
                index += 1;
            }
        }
    }

    fn mainWebViewInfo(self: *const Runtime, window_index: usize) RuntimeWebView {
        const window = self.windows[window_index];
        const fallback_frame = geometry.RectF.init(0, 0, window.info.frame.width, window.info.frame.height);
        return .{
            .id = window.main_view_id,
            .window_id = window.info.id,
            .label = "main",
            .parent = window.main_parent,
            .url = sourceWebViewUrl(window.source),
            .frame = if (window.main_frame_set) window.main_frame else fallback_frame,
            .layer = window.main_layer,
            .zoom = window.main_zoom,
            .transparent = false,
            .bridge_enabled = true,
            .focused = window.main_focused,
            .open = window.info.open,
        };
    }

    fn createWebViewView(self: *Runtime, options: platform.ViewOptions) !platform.ViewInfo {
        try validateChildWebViewLabel(options.label);
        try self.validateWebViewUrl(options.url);
        if (!isValidWebViewFrame(options.frame)) return error.InvalidWebViewOptions;
        if (self.webview_count >= platform.max_webviews) return error.WebViewLimitReached;
        var platform_options = options;
        platform_options.frame = try self.platformFrameForView(options.window_id, options.parent, options.frame);
        try self.options.platform.services.createView(platform_options);
        var reserved = false;
        errdefer {
            if (reserved) {
                if (self.findWebViewIndex(options.window_id, options.label)) |index| self.removeWebViewAt(index);
            }
            self.options.platform.services.closeView(options.window_id, options.label) catch {};
        }
        try self.reserveWebView(self.allocateViewId(), options.window_id, options.label, options.parent, options.url, options.frame, platform_options.frame, options.layer, options.transparent, options.bridge_enabled);
        reserved = true;
        self.invalidateFor(.command, platform_options.frame);
        return viewInfoFromWebView(self.webviews[self.webview_count - 1]);
    }

    fn setMainWebViewParent(self: *Runtime, window_id: platform.WindowId, parent: ?[]const u8) !void {
        const index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        self.windows[index].main_parent = if (parent) |value| try copyInto(&self.windows[index].main_parent_storage, value) else null;
    }

    fn updateWebViewView(self: *Runtime, window_id: platform.WindowId, label: []const u8, patch: platform.ViewPatch) !platform.ViewInfo {
        if (patch.visible != null or patch.enabled != null or patch.role != null or patch.accessibility_label != null or patch.text != null or patch.command != null) return error.InvalidViewOptions;
        if (isMainWebViewLabel(label)) {
            const window_index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
            if (patch.url != null) return error.InvalidViewOptions;
            if (patch.frame) |view_frame| {
                if (!isValidWebViewFrame(view_frame)) return error.InvalidWebViewOptions;
                if (self.windows[window_index].source != null) {
                    try self.options.platform.services.setWebViewFrame(window_id, label, view_frame);
                }
                self.windows[window_index].main_frame = view_frame;
                self.windows[window_index].main_frame_set = true;
                try self.relayoutDescendantWebViewBackends(window_id, label);
            }
            if (patch.layer) |layer| {
                if (self.windows[window_index].source != null) {
                    try self.options.platform.services.setWebViewLayer(window_id, label, layer);
                }
                self.windows[window_index].main_layer = layer;
            }
            self.invalidateFor(.command, patch.frame);
            return viewInfoFromWebView(self.mainWebViewInfo(window_index));
        }

        const webview_index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        if (patch.frame) |view_frame| {
            if (!isValidWebViewFrame(view_frame)) return error.InvalidWebViewOptions;
            const platform_frame = try self.platformFrameForView(window_id, self.webviews[webview_index].parent, view_frame);
            try self.options.platform.services.setWebViewFrame(window_id, label, platform_frame);
            self.webviews[webview_index].local_frame = view_frame;
            self.webviews[webview_index].frame = platform_frame;
            try self.relayoutDescendantWebViewBackends(window_id, label);
        }
        if (patch.layer) |layer| {
            try self.options.platform.services.setWebViewLayer(window_id, label, layer);
            self.webviews[webview_index].layer = layer;
        }
        if (patch.url) |url| {
            try self.validateWebViewUrl(url);
            try self.options.platform.services.navigateWebView(window_id, label, url);
            self.webviews[webview_index].url = try copyInto(&self.webviews[webview_index].url_storage, url);
        }
        self.invalidateFor(.command, patch.frame);
        return viewInfoFromWebView(self.webviews[webview_index]);
    }

    fn validateViewParent(self: *const Runtime, window_id: platform.WindowId) !void {
        const index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        if (!self.windows[index].info.open) return error.WindowNotFound;
    }

    fn validateViewParentLink(self: *const Runtime, window_id: platform.WindowId, label: []const u8, parent: ?[]const u8) !void {
        const parent_label = parent orelse return;
        if (std.mem.eql(u8, parent_label, label)) return error.InvalidViewOptions;
        if (!self.viewLabelExists(window_id, parent_label)) return error.ViewNotFound;
    }

    fn platformFrameForView(self: *const Runtime, window_id: platform.WindowId, parent: ?[]const u8, base_frame: geometry.RectF) !geometry.RectF {
        var platform_frame = base_frame;
        if (parent) |parent_label| {
            const parent_frame = try self.absoluteViewFrame(window_id, parent_label, 0);
            platform_frame.x += parent_frame.x;
            platform_frame.y += parent_frame.y;
        }
        return platform_frame;
    }

    fn localFrameForView(self: *const Runtime, window_id: platform.WindowId, parent: ?[]const u8, base_frame: geometry.RectF) !geometry.RectF {
        var local_frame = base_frame;
        if (parent) |parent_label| {
            const parent_frame = try self.absoluteViewFrame(window_id, parent_label, 0);
            local_frame.x -= parent_frame.x;
            local_frame.y -= parent_frame.y;
        }
        return local_frame;
    }

    fn absoluteViewFrame(self: *const Runtime, window_id: platform.WindowId, label: []const u8, depth: usize) !geometry.RectF {
        if (depth >= platform.max_views + platform.max_webviews + 1) return error.InvalidViewOptions;
        if (isMainWebViewLabel(label)) {
            const window_index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
            return self.mainWebViewInfo(window_index).frame;
        }
        if (self.findViewIndex(window_id, label)) |index| {
            var absolute_frame = self.views[index].frame;
            if (self.views[index].parent) |parent| {
                const parent_frame = try self.absoluteViewFrame(window_id, parent, depth + 1);
                absolute_frame.x += parent_frame.x;
                absolute_frame.y += parent_frame.y;
            }
            return absolute_frame;
        }
        if (self.findWebViewIndex(window_id, label)) |index| {
            return self.webviews[index].frame;
        }
        return error.ViewNotFound;
    }

    fn relayoutDescendantWebViewBackends(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8) !void {
        try self.relayoutDescendantWebViewBackendsDepth(window_id, parent_label, 0);
    }

    fn relayoutDescendantWebViewBackendsDepth(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8, depth: usize) !void {
        if (depth >= platform.max_views + platform.max_webviews) return;
        for (self.views[0..self.view_count]) |view| {
            if (view.window_id != window_id) continue;
            const parent = view.parent orelse continue;
            if (std.mem.eql(u8, parent, parent_label)) {
                try self.relayoutDescendantWebViewBackendsDepth(window_id, view.label, depth + 1);
            }
        }
        for (self.webviews[0..self.webview_count], 0..) |webview, index| {
            if (webview.window_id != window_id) continue;
            const parent = webview.parent orelse continue;
            if (std.mem.eql(u8, parent, parent_label)) {
                const platform_frame = try self.platformFrameForView(window_id, webview.parent, webview.local_frame);
                try self.options.platform.services.setWebViewFrame(window_id, webview.label, platform_frame);
                self.webviews[index].frame = platform_frame;
                try self.relayoutDescendantWebViewBackendsDepth(window_id, webview.label, depth + 1);
            }
        }
    }

    fn reserveView(self: *Runtime, options: platform.ViewOptions) !void {
        const index = self.view_count;
        self.views[index] = .{
            .id = self.allocateViewId(),
            .window_id = options.window_id,
            .kind = options.kind,
            .frame = options.frame,
            .layer = options.layer,
            .visible = options.visible,
            .enabled = options.enabled,
            .transparent = options.transparent,
            .bridge_enabled = options.bridge_enabled,
            .gpu_size = if (options.kind == .gpu_surface) options.frame.size() else geometry.SizeF.init(0, 0),
            .gpu_backend = if (options.kind == .gpu_surface) options.gpu_surface.backend else .none,
            .gpu_pixel_format = if (options.kind == .gpu_surface) options.gpu_surface.pixel_format else .none,
            .gpu_present_mode = if (options.kind == .gpu_surface) options.gpu_surface.present_mode else .none,
            .gpu_alpha_mode = if (options.kind == .gpu_surface) options.gpu_surface.alpha_mode else .none,
            .gpu_color_space = if (options.kind == .gpu_surface) options.gpu_surface.color_space else .none,
            .gpu_vsync = options.kind == .gpu_surface and options.gpu_surface.vsync,
            .gpu_status = if (options.kind == .gpu_surface) .ready else .unavailable,
            .gpu_surface_created_timestamp_ns = if (options.kind == .gpu_surface) timestampToU64(nowNanoseconds()) else 0,
            .focused = false,
            .open = true,
        };
        self.views[index].label = try copyInto(&self.views[index].label_storage, options.label);
        self.views[index].parent = if (options.parent) |parent| try copyInto(&self.views[index].parent_storage, parent) else null;
        self.views[index].role = try copyInto(&self.views[index].role_storage, options.role);
        self.views[index].accessibility_label = try copyInto(&self.views[index].accessibility_label_storage, options.accessibility_label);
        self.views[index].text = try copyInto(&self.views[index].text_storage, options.text);
        self.views[index].command = try copyInto(&self.views[index].command_storage, options.command);
        self.view_count += 1;
    }

    fn findViewIndex(self: *const Runtime, window_id: platform.WindowId, label: []const u8) ?usize {
        for (self.views[0..self.view_count], 0..) |view, index| {
            if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
        }
        return null;
    }

    fn commandSourceForNativeView(self: *const Runtime, window_id: platform.WindowId, label: []const u8) CommandSource {
        const index = self.findViewIndex(window_id, label) orelse return .native_view;
        var view = self.views[index];
        var depth: usize = 0;
        while (depth < platform.max_views) : (depth += 1) {
            if (view.kind == .toolbar) return .toolbar;
            const parent_label = view.parent orelse return .native_view;
            const parent_index = self.findViewIndex(window_id, parent_label) orelse return .native_view;
            view = self.views[parent_index];
        }
        return .native_view;
    }

    fn setFocusedView(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!void {
        if (self.findWindowIndexById(window_id)) |window_index| {
            self.windows[window_index].main_focused = std.mem.eql(u8, label, "main");
        }
        for (self.views[0..self.view_count], 0..) |*view, view_index| {
            if (view.window_id != window_id) continue;
            const previous_state = view.canvasWidgetRenderState();
            view.focused = std.mem.eql(u8, view.label, label);
            const next_state = view.canvasWidgetRenderState();
            if (!canvasWidgetRenderStatesEqual(previous_state, next_state)) {
                try self.invalidateForCanvasWidgetRenderStateChange(view_index, previous_state, next_state);
            }
        }
        for (self.webviews[0..self.webview_count]) |*webview| {
            if (webview.window_id == window_id) webview.focused = std.mem.eql(u8, webview.label, label);
        }
    }

    fn clearFocusedView(self: *Runtime, window_id: platform.WindowId) anyerror!void {
        if (self.findWindowIndexById(window_id)) |window_index| {
            self.windows[window_index].main_focused = false;
        }
        for (self.views[0..self.view_count], 0..) |*view, view_index| {
            if (view.window_id != window_id) continue;
            const previous_state = view.canvasWidgetRenderState();
            view.focused = false;
            const next_state = view.canvasWidgetRenderState();
            if (!canvasWidgetRenderStatesEqual(previous_state, next_state)) {
                try self.invalidateForCanvasWidgetRenderStateChange(view_index, previous_state, next_state);
            }
        }
        for (self.webviews[0..self.webview_count]) |*webview| {
            if (webview.window_id == window_id) webview.focused = false;
        }
    }

    fn ensureFocusableViewFocused(self: *Runtime, window_id: platform.WindowId) void {
        var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
        const views = self.listViews(window_id, &views_buffer);
        var first_focusable: ?[]const u8 = null;
        for (views) |view| {
            if (!isFocusableViewInfo(view)) continue;
            if (first_focusable == null) first_focusable = view.label;
            if (view.focused) return;
        }
        if (first_focusable) |label| {
            self.focusView(window_id, label) catch {
                self.clearFocusedView(window_id) catch {};
            };
        } else {
            self.clearFocusedView(window_id) catch {};
        }
    }

    fn focusAdjacentView(self: *Runtime, window_id: platform.WindowId, direction: FocusTraversalDirection) anyerror!platform.ViewInfo {
        try self.validateViewParent(window_id);

        var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
        const views = self.listViews(window_id, &views_buffer);
        var focusable: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
        var focusable_count: usize = 0;
        var focused_index: ?usize = null;
        for (views) |view| {
            if (!isFocusableViewInfo(view)) continue;
            if (view.focused) focused_index = focusable_count;
            focusable[focusable_count] = view;
            focusable_count += 1;
        }
        if (focusable_count == 0) return error.UnsupportedViewFocus;

        const target_index = switch (direction) {
            .next => if (focused_index) |index| (index + 1) % focusable_count else 0,
            .previous => if (focused_index) |index| if (index == 0) focusable_count - 1 else index - 1 else focusable_count - 1,
        };
        const target = focusable[target_index];
        try self.focusView(window_id, target.label);

        var focused = target;
        focused.focused = true;
        return focused;
    }

    fn storeTrayItems(self: *Runtime, items: []const platform.TrayMenuItem) !void {
        self.tray_item_count = 0;
        for (items, 0..) |item, index| {
            self.tray_items[index].id = item.id;
            self.tray_items[index].command = try copyInto(&self.tray_items[index].command_storage, item.command);
        }
        self.tray_item_count = items.len;
    }

    fn trayCommandNameForItem(self: *const Runtime, item_id: platform.TrayItemId) []const u8 {
        for (self.tray_items[0..self.tray_item_count]) |item| {
            if (item.id == item_id and item.command.len > 0) return item.command;
        }
        return "tray.action";
    }

    fn viewLabelExists(self: *const Runtime, window_id: platform.WindowId, label: []const u8) bool {
        if (isMainWebViewLabel(label) and self.findWindowIndexById(window_id) != null) return true;
        return self.findViewIndex(window_id, label) != null or self.findWebViewIndex(window_id, label) != null;
    }

    fn removeViewAt(self: *Runtime, index: usize) void {
        if (index >= self.view_count) return;
        var cursor = index;
        while (cursor + 1 < self.view_count) : (cursor += 1) {
            const next = &self.views[cursor + 1];
            self.views[cursor].copyRuntimeStateFrom(next);
        }
        self.view_count -= 1;
    }

    fn removeViewsForWindow(self: *Runtime, window_id: platform.WindowId) void {
        var index: usize = 0;
        while (index < self.view_count) {
            if (self.views[index].window_id == window_id) {
                self.removeViewAt(index);
            } else {
                index += 1;
            }
        }
    }

    fn removeDescendantViewsForParent(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8) void {
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

            var child_label_storage: [platform.max_view_label_bytes]u8 = undefined;
            const child_label = copyInto(&child_label_storage, self.views[index].label) catch unreachable;
            self.removeDescendantViewsForParent(window_id, child_label);
            self.removeDescendantWebViewsForParent(window_id, child_label);
            if (self.findViewIndex(window_id, child_label)) |child_index| self.removeViewAt(child_index);
            index = 0;
        }
    }

    fn removeDescendantWebViewsForParent(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8) void {
        var index: usize = 0;
        while (index < self.webview_count) {
            const parent = self.webviews[index].parent orelse {
                index += 1;
                continue;
            };
            if (self.webviews[index].window_id != window_id or !std.mem.eql(u8, parent, parent_label)) {
                index += 1;
                continue;
            }

            var child_label_storage: [@max(platform.max_view_label_bytes, platform.max_webview_label_bytes)]u8 = undefined;
            const child_label = copyInto(&child_label_storage, self.webviews[index].label) catch unreachable;
            self.removeDescendantViewsForParent(window_id, child_label);
            self.removeDescendantWebViewsForParent(window_id, child_label);
            if (self.findWebViewIndex(window_id, child_label)) |child_index| self.removeWebViewAt(child_index);
            index = 0;
        }
    }

    fn closeDescendantWebViewBackends(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8) !void {
        try self.closeDescendantWebViewBackendsDepth(window_id, parent_label, 0);
    }

    fn closeDescendantWebViewBackendsDepth(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8, depth: usize) !void {
        if (depth >= platform.max_views + platform.max_webviews) return;
        for (self.views[0..self.view_count]) |view| {
            if (view.window_id != window_id) continue;
            const parent = view.parent orelse continue;
            if (std.mem.eql(u8, parent, parent_label)) {
                try self.closeDescendantWebViewBackendsDepth(window_id, view.label, depth + 1);
            }
        }
        for (self.webviews[0..self.webview_count]) |webview| {
            if (webview.window_id != window_id) continue;
            const parent = webview.parent orelse continue;
            if (std.mem.eql(u8, parent, parent_label)) {
                try self.closeDescendantWebViewBackendsDepth(window_id, webview.label, depth + 1);
                try self.options.platform.services.closeWebView(window_id, webview.label);
            }
        }
    }

    fn viewTreeHasFocused(self: *const Runtime, window_id: platform.WindowId, label: []const u8) bool {
        return self.viewTreeHasFocusedDepth(window_id, label, 0);
    }

    fn viewTreeHasFocusedDepth(self: *const Runtime, window_id: platform.WindowId, label: []const u8, depth: usize) bool {
        if (depth >= platform.max_views + platform.max_webviews) return false;
        if (self.findViewIndex(window_id, label)) |index| {
            if (self.views[index].focused) return true;
        }
        if (self.findWebViewIndex(window_id, label)) |index| {
            if (self.webviews[index].focused) return true;
        }
        for (self.views[0..self.view_count]) |view| {
            if (view.window_id != window_id) continue;
            const parent = view.parent orelse continue;
            if (std.mem.eql(u8, parent, label) and self.viewTreeHasFocusedDepth(window_id, view.label, depth + 1)) return true;
        }
        for (self.webviews[0..self.webview_count]) |webview| {
            if (webview.window_id != window_id) continue;
            const parent = webview.parent orelse continue;
            if (std.mem.eql(u8, parent, label) and self.viewTreeHasFocusedDepth(window_id, webview.label, depth + 1)) return true;
        }
        return false;
    }

    fn focusWindowFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const window_id = try self.resolveWindowSelector(payload, &storage);
        try self.focusWindow(window_id);
        const index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        return writeWindowJson(self.windows[index].info, output);
    }

    fn closeWindowFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const window_id = try self.resolveWindowSelector(payload, &storage);
        const index = self.findWindowIndexById(window_id) orelse return error.WindowNotFound;
        var info = self.windows[index].info;
        info.open = false;
        info.focused = false;
        try self.closeWindow(window_id);
        return writeWindowJson(info, output);
    }

    fn resolveWindowSelector(self: *Runtime, payload: []const u8, storage: *json.StringStorage) !platform.WindowId {
        if (jsonIntegerField(payload, "id")) |id| return id;
        if (jsonStringField(payload, "label", storage)) |label| {
            const index = self.findWindowIndexByLabel(label) orelse return error.WindowNotFound;
            return self.windows[index].info.id;
        }
        return error.WindowNotFound;
    }

    fn writeWindowListJson(self: *Runtime, output: []u8) ![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        try writer.writeByte('[');
        for (self.windows[0..self.window_count], 0..) |window, index| {
            if (index > 0) try writer.writeByte(',');
            try writeWindowJsonToWriter(window.info, &writer);
        }
        try writer.writeByte(']');
        return writer.buffered();
    }

    fn log(self: *Runtime, name_value: []const u8, message: ?[]const u8, fields: []const trace.Field) trace.WriteError!void {
        if (self.options.trace_sink) |sink| {
            try trace.writeRecord(sink, trace.event(self.nextTimestamp(), .info, name_value, message, fields));
        }
    }

    fn extensionContext(self: *Runtime) extensions.RuntimeContext {
        return .{ .platform_name = self.options.platform.name };
    }

    fn nextTimestamp(self: *Runtime) trace.Timestamp {
        self.timestamp_ns = nowNanoseconds();
        return trace.Timestamp.fromNanoseconds(self.timestamp_ns);
    }
};

fn nowNanoseconds() i128 {
    switch (@import("builtin").os.tag) {
        .windows, .wasi => return 0,
        else => {
            var ts: std.posix.timespec = undefined;
            switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
                .SUCCESS => return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec,
                else => return 0,
            }
        },
    }
}

fn timestampToU64(value: i128) u64 {
    if (value <= 0) return 0;
    return @intCast(@min(value, std.math.maxInt(u64)));
}

fn automationInputTimestampNs() u64 {
    return timestampToU64(nowNanoseconds());
}

const RunContext = struct {
    runtime: *Runtime,
    app: App,
};

fn appUsesDefaultEmptyWebViewSource(app: App) bool {
    return app.source_fn == null and
        app.source.kind == .html and
        app.source.bytes.len == 0 and
        app.source.asset_options == null;
}

const AsyncBridgeResponseSlot = struct {
    in_use: bool = false,
    runtime: ?*Runtime = null,
    source: bridge.Source = .{},
    origin_storage: [max_bridge_origin_bytes]u8 = undefined,
    webview_label_storage: [platform.max_webview_label_bytes]u8 = undefined,

    fn init(self: *AsyncBridgeResponseSlot, runtime: *Runtime, source: bridge.Source) !void {
        if (source.origin.len > self.origin_storage.len) return error.BridgeOriginTooLarge;
        if (source.webview_label.len > self.webview_label_storage.len) return error.WebViewLabelTooLarge;
        self.runtime = runtime;
        self.source = .{
            .origin = try copyInto(&self.origin_storage, source.origin),
            .window_id = source.window_id,
            .webview_label = try copyInto(&self.webview_label_storage, source.webview_label),
        };
        self.in_use = true;
    }

    fn release(self: *AsyncBridgeResponseSlot) void {
        self.in_use = false;
        self.runtime = null;
        self.source = .{};
    }

    fn respond(self: *AsyncBridgeResponseSlot, response: []const u8) anyerror!void {
        if (!self.in_use) return error.AsyncBridgeResponseAlreadyCompleted;
        const runtime = self.runtime orelse return error.AsyncBridgeResponseAlreadyCompleted;
        const source = self.source;
        defer self.release();
        try runtime.respondToBridge(source, response);
    }
};

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

fn validateCanvasRenderAnimations(animations: []const canvas.CanvasRenderAnimation) !void {
    if (animations.len > max_canvas_render_animations_per_view) return error.RenderAnimationListFull;
    for (animations) |animation| {
        if (animation.id == 0) return error.InvalidViewOptions;
    }
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

        pub fn init(self: *Self, surface: platform.Surface) void {
            self.null_platform = platform.NullPlatform.init(surface);
            self.trace_sink = trace.BufferSink.init(&self.trace_records);
            self.runtime = Runtime.init(.{
                .platform = self.null_platform.platform(),
                .trace_sink = self.trace_sink.sink(),
            });
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
