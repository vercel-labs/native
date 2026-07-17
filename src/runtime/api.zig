const std = @import("std");
const trace = @import("trace");
const canvas = @import("canvas");
const automation = @import("../automation/root.zig");
const bridge = @import("../bridge/root.zig");
const extensions = @import("../extensions/root.zig");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const runtime_effects = @import("effects.zig");
const runtime_session_record = @import("session_record.zig");
const runtime_view = @import("view.zig");
const security = @import("../security/root.zig");
const widget_bridge = @import("widget_bridge.zig");
const window_state = @import("../window_state/root.zig");

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
pub const TimerEvent = platform.TimerEvent;
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
    /// Where a press on `target` actually lands: the deepest widget on the
    /// hit path that claims presses — equal to `target` for interactive
    /// widgets, the nearest pressable ancestor when the raw hit is plain
    /// text/decoration, and null when nothing on the path is pressable OR
    /// when this `.up` ended a text-selection drag (dragging selects,
    /// clicking presses). Press-family dispatch (typed `on_press`, engine
    /// `command`s, control activation) resolves through this; hover,
    /// cursor, and text selection stay on `target`.
    press_target: ?canvas.WidgetHit = null,
    route: []const canvas.WidgetEventRouteEntry = &.{},
    /// A text edit this pointer gesture performed on `target` (the
    /// search field's built-in clear affordance). The runtime already
    /// applied it (the optimistic echo; the source tree is truth on the
    /// next rebuild); `UiApp` maps it through the tree's handler table
    /// to the field's `on_input` Msg so a model-owned buffer clears too.
    edit: ?canvas.TextInputEvent = null,
};

pub const CanvasWidgetKeyboardEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    keyboard: canvas.WidgetKeyboardEvent,
    target: ?canvas.WidgetFocusTarget = null,
    route: []const canvas.WidgetEventRouteEntry = &.{},
};

/// A scroll container's offset changed from a user gesture (wheel,
/// kinetic momentum steps, keyboard, or an accessibility scroll action).
/// `scroll` is the post-change state — offset, viewport and content
/// extents (`maxOffset()` derives the range) — read at dispatch time, so
/// rapid motion coalesces into the latest state per node. Programmatic
/// source-tree offset changes do not emit this event: the model already
/// knows those.
pub const CanvasWidgetScrollEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    /// The scroll container's structural widget id.
    id: canvas.ObjectId,
    scroll: canvas.ScrollState,
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

/// A dismissible floating surface (dialog, drawer, sheet, popover,
/// menu-surface, dropdown-menu) was dismissed by a user gesture — Escape,
/// a pointer press outside it, or an automation/accessibility dismiss
/// action. The runtime hides the surface immediately (the optimistic
/// echo; the source tree is truth on the next rebuild) and delivers this
/// event so a TEA model can OWN the close: `UiApp` maps it through the
/// tree's handler table to the surface's `on_dismiss` Msg.
pub const CanvasWidgetDismissEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    /// The dismissed surface's structural widget id.
    id: canvas.ObjectId,
};

/// A split container's fraction changed from a user resize — divider
/// drag, keyboard adjustment on the focused divider, or an assistive
/// increment/decrement. The runtime already applied the fraction (the
/// optimistic echo; the source tree is truth on the next rebuild) and
/// delivers this event so a TEA model can OWN it: `UiApp` maps it
/// through the tree's handler table to the split's `on_resize` Msg.
pub const CanvasWidgetResizeEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    /// The split container's structural widget id.
    id: canvas.ObjectId,
    /// The applied first-pane fraction (already clamped against the
    /// panes' min widths).
    fraction: f32,
};

/// A slider's value changed from a pointer gesture — a click on the rail
/// (the thumb jumps to the pressed point) or a scrubbing drag. The
/// runtime already applied the value (the optimistic echo; the source
/// tree is truth on the next rebuild) and delivers this event so a TEA
/// model can OWN it: `UiApp` maps it through the tree's handler table to
/// the slider's `on_value`/`on_change` Msg. Keyboard steps and assistive
/// increment/decrement do not emit this event — they already dispatch
/// through the keyboard path (`msgForKeyboard`).
pub const CanvasWidgetChangeEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    /// The slider's structural widget id.
    id: canvas.ObjectId,
    /// The applied value (already clamped to 0...1).
    value: f32,
};

/// A secondary-button press (right/ctrl-click, touch long-press) whose
/// route offered NO context menu — no app-declared items, no editable or
/// selected-text default. Delivered with the resolved press target so
/// `UiApp` can treat it as the press-and-hold alternative: the target's
/// `on_hold` Msg dispatches immediately. Widgets with a declared context
/// menu never see this — the native menu wins.
pub const CanvasWidgetContextPressEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    /// The deepest press-claiming widget on the hit route (the same
    /// resolution primary presses use).
    press_target: ?canvas.WidgetHit = null,
};

/// The user selected an item from a widget's app-declared native context
/// menu (`ElementOptions.context_menu`). `item_index` indexes the
/// widget's declared items; `UiApp` maps it to the item's `Msg` through
/// the tree's handler table (`Tree.msgForContextMenu`).
pub const CanvasWidgetContextMenuEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    target_id: canvas.ObjectId,
    item_index: usize,
};

/// A right/ctrl-click landed on a widget with a declared context menu,
/// but the platform could not present it natively (this host has no
/// native menu presenter, or presenting failed). The app loop answers by
/// presenting the SAME declared items as an anchored canvas surface —
/// one authored menu, platform-appropriate presentation.
pub const CanvasWidgetContextMenuRequestEvent = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8,
    target_id: canvas.ObjectId,
};

/// A window the RUNTIME knew as open was closed by the platform — the
/// user clicked its close button (or the host tore it down). Never
/// emitted for `runtime.closeWindow` calls the app itself made through
/// the reconcile path before the platform echo arrives with the window
/// already forgotten. The model owns the consequence, matching the
/// dismissal precedent: `UiApp` maps this to the declared window's
/// `on_close` Msg, and the next rebuild's declared window set is truth —
/// a model that keeps declaring the window gets it back.
pub const WindowClosedEvent = struct {
    window_id: platform.WindowId,
    /// The window's label from runtime storage (stable for the dispatch).
    label: []const u8,
};

/// An automation `provenance` query for a live widget: the runtime has
/// already resolved the view and (for point queries) hit-tested the
/// widget id; the app that authored the view answers from its retained
/// provenance table and publishes the response through the automation
/// server. Slices are valid for the synchronous dispatch only.
pub const AutomationProvenanceEvent = struct {
    window_id: platform.WindowId,
    view_label: []const u8,
    widget_id: u64,
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
    timer: TimerEvent,
    /// The platform loop was nudged from another thread
    /// (`PlatformServices.wake_fn`): apps drain their effect completion
    /// queues here, on the loop thread, and dispatch the resulting Msgs.
    effects_wake,
    /// A platform audio player report (load acknowledgment, position
    /// tick, completion, failure): the ui-app layer routes it back
    /// through `Effects.takeAudioMsg` into the app's `on_event` Msg.
    audio: platform.AudioEvent,
    files_dropped: platform.FileDropEvent,
    gpu_surface_frame: GpuSurfaceFrameEvent,
    gpu_surface_resized: GpuSurfaceResizeEvent,
    gpu_surface_input: GpuSurfaceInputEvent,
    canvas_widget_pointer: CanvasWidgetPointerEvent,
    canvas_widget_keyboard: CanvasWidgetKeyboardEvent,
    canvas_widget_scroll: CanvasWidgetScrollEvent,
    canvas_widget_file_drop: CanvasWidgetFileDropEvent,
    canvas_widget_drag: CanvasWidgetDragEvent,
    canvas_widget_context_menu: CanvasWidgetContextMenuEvent,
    canvas_widget_context_menu_request: CanvasWidgetContextMenuRequestEvent,
    canvas_widget_dismiss: CanvasWidgetDismissEvent,
    canvas_widget_context_press: CanvasWidgetContextPressEvent,
    canvas_widget_resize: CanvasWidgetResizeEvent,
    canvas_widget_change: CanvasWidgetChangeEvent,
    window_closed: WindowClosedEvent,
    automation_provenance: AutomationProvenanceEvent,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .lifecycle => |event_value| @tagName(event_value),
            .appearance_changed => "appearance_changed",
            .command => |event_value| event_value.name,
            .shortcut => "shortcut",
            .timer => "timer",
            .effects_wake => "effects_wake",
            .audio => "audio",
            .files_dropped => "files_dropped",
            .gpu_surface_frame => "gpu_surface_frame",
            .gpu_surface_resized => "gpu_surface_resized",
            .gpu_surface_input => "gpu_surface_input",
            .canvas_widget_pointer => "canvas_widget_pointer",
            .canvas_widget_keyboard => "canvas_widget_keyboard",
            .canvas_widget_scroll => "canvas_widget_scroll",
            .canvas_widget_file_drop => "canvas_widget_file_drop",
            .canvas_widget_drag => "canvas_widget_drag",
            .canvas_widget_context_menu => "canvas_widget_context_menu",
            .canvas_widget_context_menu_request => "canvas_widget_context_menu_request",
            .canvas_widget_dismiss => "canvas_widget_dismiss",
            .canvas_widget_context_press => "canvas_widget_context_press",
            .canvas_widget_resize => "canvas_widget_resize",
            .canvas_widget_change => "canvas_widget_change",
            .window_closed => "window_closed",
            .automation_provenance => "automation_provenance",
        };
    }
};

/// Session-replay control, type-erased over the app's Msg union so the
/// replay driver can steer any app through its `App` value: `.arm`
/// switches the app's effects channel into replay mode (fake executor,
/// journaled results as the only terminal source) before the first
/// replayed event; `.feed` delivers one journaled effect result into
/// the stub executor's pending request with the matching key.
pub const ReplayControl = union(enum) {
    arm,
    feed: runtime_effects.EffectResultRecord,
};

pub fn App(comptime Runtime: type) type {
    return struct {
        const Self = @This();
        const StartFn = *const fn (context: *anyopaque, runtime: *Runtime) anyerror!void;
        const EventFn = *const fn (context: *anyopaque, runtime: *Runtime, event: Event) anyerror!void;
        const SourceFn = *const fn (context: *anyopaque) anyerror!platform.WebViewSource;
        const SceneFn = *const fn (context: *anyopaque) anyerror!app_manifest.ShellConfig;
        const StopFn = *const fn (context: *anyopaque, runtime: *Runtime) anyerror!void;
        const ReplayFn = *const fn (context: *anyopaque, control: ReplayControl) anyerror!void;

        context: *anyopaque,
        name: []const u8,
        source: platform.WebViewSource = platform.WebViewSource.html(""),
        source_fn: ?SourceFn = null,
        scene_fn: ?SceneFn = null,
        start_fn: ?StartFn = null,
        event_fn: ?EventFn = null,
        stop_fn: ?StopFn = null,
        /// Session-replay hook (`UiApp` wires it automatically). Null
        /// means the app cannot be replayed with effect stubbing —
        /// replay refuses journals that carry effect results for it.
        replay_fn: ?ReplayFn = null,

        pub fn start(self: Self, runtime: *Runtime) anyerror!void {
            if (self.start_fn) |start_fn| try start_fn(self.context, runtime);
        }

        pub fn event(self: Self, runtime: *Runtime, event_value: Event) anyerror!void {
            if (self.event_fn) |event_fn| try event_fn(self.context, runtime, event_value);
        }

        pub fn webViewSource(self: Self) anyerror!platform.WebViewSource {
            if (self.source_fn) |source_fn| return source_fn(self.context);
            return self.source;
        }

        pub fn scene(self: Self) anyerror!?app_manifest.ShellConfig {
            if (self.scene_fn) |scene_fn| return try scene_fn(self.context);
            return null;
        }

        pub fn stop(self: Self, runtime: *Runtime) anyerror!void {
            if (self.stop_fn) |stop_fn| try stop_fn(self.context, runtime);
        }

        /// Steer the app's replay hook. `error.ReplayUnsupported` when
        /// the app registered none.
        pub fn replayControl(self: Self, control: ReplayControl) anyerror!void {
            const replay_fn = self.replay_fn orelse return error.ReplayUnsupported;
            try replay_fn(self.context, control);
        }
    };
}

pub const Options = struct {
    platform: platform.Platform,
    /// Allocator for the runtime's on-demand storage (registered
    /// canvas font bytes, sized per file at registration, and adopted
    /// media-surface texture buffers, one frame-budget buffer per
    /// texture entry allocated at first adoption — a runtime with no
    /// registered fonts and no media producers allocates nothing; the
    /// fixed-capacity per-view storage stays embedded in the Runtime
    /// struct). The default suits process-lifetime runtimes; embedders
    /// that create and destroy runtimes in one process (tests, the docs
    /// wasm preview host) pass their own and call `Runtime.deinit`. The
    /// runtime captures this into its `owned_allocator` at init:
    /// mutating `options.allocator` on a live runtime retargets
    /// nothing — pick the owning allocator here, before init.
    allocator: std.mem.Allocator = std.heap.page_allocator,
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
    /// Whether this build ships the embedded web layer. The app runner
    /// sets it from the build graph's app.zon inference (declare-to-use:
    /// a .frontend block, the "webview" capability, or a .shell webview
    /// view). When false, every webview-creating path fails fast with
    /// `error.WebViewLayerNotBuilt` and its teaching message instead of
    /// reaching a platform host whose web layer was compiled out.
    web_layer: bool = true,
    gpu_surface_frame_diagnostics: bool = true,
    /// Pixels-only presentation hosts (the mobile embed host) opt in to
    /// keeping the view's keyed command mirror alive across PIXEL
    /// presents: the mirror then describes what the presented pixel
    /// buffer shows, so the next frame's dirty bounds refine to the
    /// commands that actually changed (a keystroke repaints the field,
    /// not the window) instead of degrading to the summary union on
    /// every Msg rebuild. Must stay false on any platform that wires a
    /// gpu-surface packet presenter — a later packet patch would target
    /// a dictionary the host never adopted (the patch gate additionally
    /// refuses pixel-adopted baselines as defense in depth).
    pixel_present_retained_baseline: bool = false,
    /// Optional render memo for the CPU pixel present path (see
    /// `canvas.ReferenceRenderMemo`): pixels-only hosts that re-render
    /// the retained scene every changed frame attach one so heavyweight
    /// per-pixel commands replay their stored output and scaled image
    /// draws blend from scale-once panels. Purely an optimization —
    /// output bytes are identical with or without it. Must outlive the
    /// runtime; null (the default) changes nothing.
    pixel_present_render_memo: ?*canvas.ReferenceRenderMemo = null,
    /// The process environment spawned effect children inherit (the app
    /// runner threads it through from `std.process.Init`). `null` lets
    /// the effect system resolve a fallback for hosts without a process
    /// `Init` (embed/mobile): the libc/PEB environment where available,
    /// `.empty` otherwise.
    environ: ?std.process.Environ = null,
    /// Session recorder (record/replay): when set, the dispatch choke
    /// point journals every platform event, the effects channel journals
    /// every drained result, and each published frame appends a state
    /// fingerprint checkpoint. The app runner arms this from
    /// `NATIVE_SDK_SESSION_RECORD=<path>`.
    session_recorder: ?*runtime_session_record.SessionRecorder = null,
};
