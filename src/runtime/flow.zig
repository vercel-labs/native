const std = @import("std");
const geometry = @import("geometry");
const trace = @import("trace");
const json = @import("json");
const validation = @import("validation.zig");
const runtime_api = @import("api.zig");
const runtime_async_bridge = @import("async_bridge.zig");
const runtime_automation_snapshot = @import("automation_snapshot.zig");
const runtime_automation_widget_dispatch = @import("automation_widget_dispatch.zig");
const automation_commands = @import("automation_commands.zig");
const launch_timing = @import("launch_timing.zig");
const runtime_clock = @import("clock.zig");
const shell_layout = @import("shell_layout.zig");
const runtime_builtin_bridge = @import("builtin_bridge.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");
const runtime_canvas_widget_context_menu = @import("canvas_widget_context_menu.zig");
const runtime_canvas_widget_scroll_drivers = @import("canvas_widget_scroll_drivers.zig");
const runtime_gpu_surface_events = @import("gpu_surface_events.zig");
const runtime_system_services = @import("system_services.zig");
const runtime_window_views = @import("window_views.zig");
const widget_bridge = @import("widget_bridge.zig");
const automation = @import("../automation/root.zig");
const bridge = @import("../bridge/root.zig");
const extensions = @import("../extensions/root.zig");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const security = @import("../security/root.zig");

const validateCommandName = validation.validateCommandName;
const sceneNeedsMainWebView = shell_layout.sceneNeedsMainWebView;
const nowNanoseconds = runtime_clock.nowNanoseconds;
const canvasWidgetAccessibilityActionKindFromPlatform = widget_bridge.canvasWidgetAccessibilityActionKindFromPlatform;
const parseAutomationCommandName = automation_commands.parseAutomationCommandName;
const parseAutomationViewLabel = automation_commands.parseAutomationViewLabel;
const parseAutomationNativeCommand = automation_commands.parseAutomationNativeCommand;
const parseAutomationWidgetAction = automation_commands.parseAutomationWidgetAction;
const parseAutomationWidgetTarget = automation_commands.parseAutomationWidgetTarget;
const parseAutomationProvenanceTarget = automation_commands.parseAutomationProvenanceTarget;
const parseAutomationWidgetWheel = automation_commands.parseAutomationWidgetWheel;
const parseAutomationWidgetContextMenuItem = automation_commands.parseAutomationWidgetContextMenuItem;
const parseAutomationWidgetKey = automation_commands.parseAutomationWidgetKey;
const parseAutomationWidgetPinch = automation_commands.parseAutomationWidgetPinch;
const parseAutomationWidgetPointerDrag = automation_commands.parseAutomationWidgetPointerDrag;
const parseAutomationResizeCommand = automation_commands.parseAutomationResizeCommand;
const parseAutomationTrayItemId = automation_commands.parseAutomationTrayItemId;
const parseAutomationScreenshotCommand = automation_commands.parseAutomationScreenshotCommand;
const canvas = @import("canvas");

pub fn RuntimeFlow(comptime Runtime: type) type {
    return struct {
        const App = runtime_api.App(Runtime);
        const Event = runtime_api.Event;
        const CommandEvent = runtime_api.CommandEvent;
        const FrameDiagnostics = runtime_api.FrameDiagnostics;
        const AsyncBridgeResponseSlot = runtime_async_bridge.AsyncBridgeResponseSlot(Runtime);
        const RunContext = struct {
            runtime: *Runtime,
            app: App,
        };

        fn WindowViewMethods() type {
            return runtime_window_views.RuntimeWindowViews(Runtime);
        }

        fn SystemServiceMethods() type {
            return runtime_system_services.RuntimeSystemServices(Runtime);
        }

        fn GpuSurfaceEventMethods() type {
            return runtime_gpu_surface_events.RuntimeGpuSurfaceEvents(Runtime);
        }

        fn ScrollDriverMethods() type {
            return runtime_canvas_widget_scroll_drivers.RuntimeCanvasWidgetScrollDrivers(Runtime);
        }

        fn ContextMenuMethods() type {
            return runtime_canvas_widget_context_menu.RuntimeCanvasWidgetContextMenu(Runtime);
        }

        fn CanvasWidgetEventMethods() type {
            return runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
        }

        fn AutomationWidgetMethods() type {
            return runtime_automation_widget_dispatch.RuntimeAutomationWidgetDispatch(Runtime);
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
            log(self, "runtime.init", "runtime initialized", init_fields[0..init_field_count]);
            try app_manifest.validateCommands(self.options.commands);
            try self.options.platform.services.configureSecurityPolicy(self.options.security);
            try self.options.platform.services.configureMenus(self.options.menus);
            try self.options.platform.services.configureShortcuts(self.options.shortcuts);
            // Automation liveness: the drain (`consumeAutomationCommand`,
            // in `frame` below) runs at most once per frame_requested
            // turn, and an idle app produces no frames — so a queued
            // command must WAKE the loop the way user input does. The
            // arrival watcher polls the dropbox slot on its own thread
            // and asks the platform for one coalesced frame tick through
            // its thread-safe `request_frame_fn` whenever a command is
            // pending. Consumption itself stays on the frame boundary,
            // so command order, one-command-per-frame, and session
            // recording/replay (commands nest inside recorded
            // frame_requested events) are unchanged; only the frame's
            // ARRIVAL time moves. No automation server (any non-dev
            // build) means no thread and no polls at all.
            var command_watcher: automation.Watcher = undefined;
            var command_watcher_running = false;
            if (self.options.automation) |server| {
                if (self.options.platform.services.request_frame_fn) |request_fn| {
                    command_watcher_running = command_watcher.start(server, .{
                        .context = self.options.platform.services.context,
                        .request_fn = request_fn,
                    });
                    if (!command_watcher_running) {
                        log(self, "automation.watcher_failed", "automation command watcher thread did not start; commands drain on the next unrelated frame", &.{});
                    }
                } else {
                    // A platform without the cross-thread frame request
                    // keeps the old behavior (commands drain on whatever
                    // frame arrives next); say so once instead of wedging
                    // silently.
                    log(self, "automation.watcher_unsupported", "platform has no cross-thread frame request; automation commands drain on the next unrelated frame", &.{});
                }
            }
            // Stopped (joined) before the platform loop's resources go
            // away, so the watcher can never call into a dead host.
            defer if (command_watcher_running) command_watcher.stop();

            // Media-surface wake teardown: producers a slow app forgot
            // to release may push (and try to wake this platform) at
            // any later time from their own threads. Disarm their wake
            // bindings before the caller's later-declared defers tear
            // the host down — declared BEFORE the app-stop defer below
            // so it runs AFTER the stop hook (LIFO), letting the hook
            // join producer threads first. The same run-exit ordering
            // that stops the automation arrival watcher.
            defer self.disarmMediaSurfaceWakes();

            // Teardown ordering contract: everything the app must do
            // against the live platform — silencing an active audio
            // player, disarming platform timers, joining effect workers
            // that post through the platform's wake service — happens in
            // the app's stop hook, and that hook is guaranteed to run
            // before run() returns. The app's OWN deinit cannot serve
            // this purpose: it is typically a `defer` in main that runs
            // only after the runner's later-declared defers have already
            // destroyed the platform host and freed the runtime, so any
            // platform service call from there dereferences freed memory
            // (the quit-while-audio-plays use-after-free). The platform's
            // `.app_shutdown` event delivers the stop hook on the normal
            // quit path; this defer delivers it when the loop exits any
            // other way (an error unwind, a host that stops without a
            // shutdown event) — exactly once either way, gated by
            // `app_stop_delivered`.
            defer if (!self.app_stop_delivered) {
                self.app_stop_delivered = true;
                app.stop(self) catch |err| log(self, "app.stop.failed", @errorName(err), &.{trace.string("app", app.name)});
            };

            var context: RunContext = .{ .runtime = self, .app = app };
            try self.options.platform.run(handlePlatformEvent, &context);

            log(self, "runtime.done", "runtime finished", &.{});
        }

        fn reservePrimaryStartupWindow(self: *Runtime) anyerror!void {
            const app_info = self.options.platform.app_info;
            if (app_info.startupWindowCount() == 0) return;
            const window = app_info.resolvedStartupWindow(0);
            if (WindowViewMethods().findWindowIndexById(self, window.id) != null) return;

            const runtime_index = try WindowViewMethods().reserveWindow(self, window.id, window.label, window.resolvedTitle(app_info.app_name), null, true);
            self.windows[runtime_index].info.frame = window.default_frame;
            self.windows[runtime_index].main_frame = geometry.RectF.init(0, 0, window.default_frame.width, window.default_frame.height);
            self.next_window_id = @max(self.next_window_id, window.id + 1);
        }

        pub fn emitWindowEvent(self: *Runtime, window_id: platform.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
            if (!json.isValidValue(detail_json)) return error.InvalidJsonEventDetail;
            try self.options.platform.services.emitWindowEvent(window_id, name, detail_json);
        }

        pub fn respondToBridge(self: *Runtime, source: bridge.Source, response: []const u8) anyerror!void {
            try completeBridgeResponse(self, source.window_id, source.webview_label, response);
        }

        pub fn dispatchPlatformEvent(self: *Runtime, app: App, event_value: platform.Event) anyerror!void {
            // Session recording: stage the event on entry, commit it on
            // exit — so effect results drained DURING dispatch precede
            // the event record in the journal (replay feeds them before
            // dispatching), and nested dispatches (automation commands
            // inside frame_requested) commit innermost-first. One state
            // fingerprint checkpoint follows each published frame.
            if (self.options.session_recorder) |recorder| recorder.stageEvent(event_value);
            defer if (self.options.session_recorder) |recorder| {
                recorder.commitEvent();
                if (recorder.wantsCheckpoint(self.frame_index)) {
                    recorder.recordCheckpoint(self.frame_index, self.sessionStateFingerprint());
                }
                // Seal on shutdown, here rather than only at run() exit:
                // a host that terminates without unwinding the platform
                // loop still leaves a whole journal behind.
                if (event_value == .app_shutdown) recorder.finish();
            };

            if ((event_value != .frame_requested and event_value != .gpu_surface_frame) or self.invalidated) {
                const event_fields = [_]trace.Field{trace.string("event", event_value.name())};
                log(self, "platform.event", null, &event_fields);
            }

            switch (event_value) {
                .app_start => {
                    // A startup failure must be loud and attributable.
                    // Without this record the error unwinds into the
                    // platform stop path and the only trace is a bare
                    // `app.stop` right after `start` — which reads like a
                    // clean exit while the main window sits blank.
                    errdefer |err| recordDispatchError(self, "app_start", err);
                    launch_timing.lap("app_start");
                    try reservePrimaryStartupWindow(self);
                    try app.start(self);
                    if (self.options.extensions) |registry| try registry.startAll(extensionContext(self));
                    try dispatchEvent(self, app, .{ .lifecycle = .start });
                    launch_timing.lap("app_started");
                    if (try app.scene()) |scene| {
                        try loadScene(self, app, scene);
                    } else {
                        try loadStartupWindows(self, app);
                    }
                    launch_timing.lap("scene_loaded");
                    self.invalidateFor(.startup, null);
                    log(self, "app.start", "app started", &.{trace.string("app", app.name)});
                },
                .app_activated => {
                    self.app_active = true;
                    try dispatchEvent(self, app, .{ .lifecycle = .activate });
                    emitAppLifecycleEvent(self, "app:activate") catch |err| log(self, "app.activate.emit_failed", @errorName(err), &.{});
                },
                .app_deactivated => {
                    // The app-active register flips FIRST — before the
                    // tooltip reset and before the app hears the
                    // lifecycle event — so a model that rebuilds FROM
                    // its deactivation callback adopts under a runtime
                    // that already knows the app is inactive: the
                    // adoption arm's reveal/arm paths are gated on this
                    // register and stay silent.
                    self.app_active = false;
                    // Deactivation drops every tooltip conversation in
                    // every window (see the seam's own rationale) BEFORE
                    // the app hears the lifecycle event, so a model that
                    // rebuilds on deactivate adopts against clean
                    // tooltip state instead of a stale shown slot.
                    try CanvasWidgetEventMethods().resetCanvasTooltipIntentForAppDeactivation(self);
                    try dispatchEvent(self, app, .{ .lifecycle = .deactivate });
                    emitAppLifecycleEvent(self, "app:deactivate") catch |err| log(self, "app.deactivate.emit_failed", @errorName(err), &.{});
                },
                .appearance_changed => |appearance| {
                    self.appearance = appearance;
                    // Appearance flips re-resolve theme typography (and a
                    // host may re-resolve its fonts with it): cached
                    // advance batches and retained wrap results must miss
                    // rather than serve metrics measured under the
                    // previous appearance.
                    canvas.bumpTextMeasureGeneration();
                    try dispatchEvent(self, app, .{ .appearance_changed = appearance });
                },
                .surface_resized => |surface_value| {
                    self.surface = surface_value;
                    if (WindowViewMethods().findWindowIndexById(self, surface_value.id)) |index| {
                        self.windows[index].info.frame.width = surface_value.size.width;
                        self.windows[index].info.frame.height = surface_value.size.height;
                        self.windows[index].info.scale_factor = surface_value.scale_factor;
                    }
                    WindowViewMethods().relayoutShellViews(self, surface_value.id) catch |err| log(self, "shell.relayout_failed", @errorName(err), &.{trace.uint("window_id", surface_value.id)});
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
                    emitWindowEvent(self, surface_value.id, "resize", detail_writer.buffered()) catch |err| log(self, "window.resize.emit_failed", @errorName(err), &.{});
                    self.invalidateFor(.surface_resize, geometry.RectF.fromSize(surface_value.size));
                    const fields = [_]trace.Field{
                        trace.float("width", surface_value.size.width),
                        trace.float("height", surface_value.size.height),
                        trace.float("scale", surface_value.scale_factor),
                    };
                    log(self, "surface.resize", "surface updated", &fields);
                },
                .window_frame_changed => |state| {
                    // A user (or host) close arrives as open=false on a
                    // window the runtime knew as open; a close the app
                    // itself made through `closeWindow` already flipped
                    // the flag, so the echo never re-fires. Capture the
                    // transition BEFORE the update.
                    const was_open = if (WindowViewMethods().findWindowIndexById(self, state.id)) |index| self.windows[index].info.open else false;
                    WindowViewMethods().updateWindowState(self, state) catch |err| log(self, "window.state.update_failed", @errorName(err), &.{trace.string("label", state.label)});
                    WindowViewMethods().relayoutShellViews(self, state.id) catch |err| log(self, "shell.relayout_failed", @errorName(err), &.{trace.uint("window_id", state.id)});
                    if (self.options.window_state_store) |store| {
                        store.saveWindow(WindowViewMethods().runtimeWindowStateForPersistence(self, state)) catch |err| log(self, "window.state.save_failed", @errorName(err), &.{trace.string("label", state.label)});
                    }
                    log(self, "window.frame", "window frame updated", &.{
                        trace.string("label", state.label),
                        trace.float("x", state.frame.x),
                        trace.float("y", state.frame.y),
                        trace.float("width", state.frame.width),
                        trace.float("height", state.frame.height),
                    });
                    if (was_open and !state.open) {
                        // The model owns the consequence (the dismissal
                        // precedent): the app maps this to a Msg and its
                        // next declared window set is truth. The label
                        // comes from runtime storage, which outlives the
                        // event's transient slices.
                        const label = if (WindowViewMethods().findWindowIndexById(self, state.id)) |index| self.windows[index].info.label else state.label;
                        try dispatchEvent(self, app, .{ .window_closed = .{ .window_id = state.id, .label = label } });
                    }
                },
                .window_focused => |window_id| {
                    // setFocusedIndex is the window-key seam: the
                    // window LOSING key here also drops its views'
                    // tooltip conversations there.
                    if (WindowViewMethods().findWindowIndexById(self, window_id)) |index| try WindowViewMethods().setFocusedIndex(self, index);
                    self.invalidated = true;
                },
                .frame_requested => try frame(self, app),
                .bridge_message => |message| try handleBridgeMessage(self, app, message),
                .tray_action => |item_id| {
                    log(self, "tray.action", "tray item selected", &.{trace.uint("item_id", item_id)});
                    try dispatchCommand(self, app, .{
                        .name = SystemServiceMethods().trayCommandNameForItem(self, item_id),
                        .source = .tray,
                        .tray_item_id = item_id,
                    });
                },
                .shortcut => |shortcut| {
                    try dispatchCommand(self, app, .{
                        .name = shortcut.id,
                        .source = .shortcut,
                        .window_id = shortcut.window_id,
                    });
                    try dispatchEvent(self, app, .{ .shortcut = shortcut });
                    emitShortcutEvent(self, shortcut) catch |err| log(self, "shortcut.emit_failed", @errorName(err), &.{trace.string("id", shortcut.id)});
                    self.invalidateFor(.command, null);
                },
                .native_command => |command| {
                    try dispatchCommand(self, app, .{
                        .name = command.name,
                        .source = WindowViewMethods().commandSourceForNativeView(self, command.window_id, command.view_label),
                        .window_id = command.window_id,
                        .view_label = command.view_label,
                    });
                },
                // The interactive-surface family below degrades on error
                // instead of propagating: an error that escapes
                // `dispatchPlatformEvent` reaches the platform callback,
                // latches its failure flag, and exits the whole app — so a
                // runtime-side capacity or render fault on a keystroke,
                // click, scroll, resize, or frame tick must land in the
                // dispatch-error ring (loud, queryable, traced at `.err`)
                // while the app keeps running. The failing interaction is
                // refused; the next one starts clean. The TestHarness's
                // `.propagate` policy still returns the error so tests
                // fail loud instead of leaving silent stale frames.
                .gpu_surface_frame => |frame_event| GpuSurfaceEventMethods().dispatchGpuSurfaceFrame(self, app, frame_event) catch |err| {
                    recordDispatchError(self, "gpu_surface_frame", err);
                    if (self.dispatch_error_policy == .propagate) return err;
                },
                .gpu_surface_resized => |resize_event| {
                    GpuSurfaceEventMethods().dispatchGpuSurfaceResized(self, app, resize_event) catch |err| {
                        recordDispatchError(self, "gpu_surface_resized", err);
                        if (self.dispatch_error_policy == .propagate) return err;
                    };
                    log(self, "gpu_surface.resize", "gpu surface resized", &.{
                        trace.string("label", resize_event.label),
                        trace.float("width", resize_event.frame.width),
                        trace.float("height", resize_event.frame.height),
                        trace.float("scale", resize_event.scale_factor),
                    });
                },
                .gpu_surface_input => |input_event| GpuSurfaceEventMethods().dispatchGpuSurfaceInput(self, app, input_event) catch |err| {
                    recordDispatchError(self, "gpu_surface_input", err);
                    if (self.dispatch_error_policy == .propagate) return err;
                },
                .gpu_surface_scroll_driver => |driver_event| ScrollDriverMethods().dispatchGpuSurfaceScrollDriver(self, app, driver_event) catch |err| {
                    recordDispatchError(self, "gpu_surface_scroll_driver", err);
                    if (self.dispatch_error_policy == .propagate) return err;
                },
                .context_menu_action => |action_event| ContextMenuMethods().dispatchContextMenuAction(self, app, action_event) catch |err| {
                    recordDispatchError(self, "context_menu_action", err);
                    if (self.dispatch_error_policy == .propagate) return err;
                },
                .widget_accessibility_action => |action_event| {
                    _ = self.dispatchCanvasWidgetAccessibilityAction(app, action_event.window_id, action_event.label, .{
                        .id = action_event.id,
                        .action = canvasWidgetAccessibilityActionKindFromPlatform(action_event.action),
                        .text = action_event.text,
                        .selection = if (action_event.selection) |selection| .{ .anchor = selection.start, .focus = selection.end } else null,
                    }) catch |err| {
                        recordDispatchError(self, "widget_accessibility_action", err);
                        if (self.dispatch_error_policy == .propagate) return err;
                    };
                },
                .menu_command => |command| {
                    try dispatchCommand(self, app, .{
                        .name = command.name,
                        .source = .menu,
                        .window_id = command.window_id,
                    });
                },
                .timer => |timer_event| {
                    try dispatchEvent(self, app, .{ .timer = timer_event });
                },
                .audio => |audio_event| {
                    try dispatchEvent(self, app, .{ .audio = audio_event });
                },
                .wake => {
                    try dispatchEvent(self, app, .effects_wake);
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
                        try dispatchEvent(self, app, .{ .canvas_widget_file_drop = drop_event });
                    }
                    try dispatchEvent(self, app, .{ .files_dropped = drop });
                    emitFileDropEvent(self, drop) catch |err| log(self, "drop.files.emit_failed", @errorName(err), &.{trace.uint("window_id", drop.window_id)});
                    self.invalidateFor(.command, null);
                },
                .app_shutdown => {
                    try dispatchEvent(self, app, .{ .lifecycle = .stop });
                    if (self.options.extensions) |registry| try registry.stopAll(extensionContext(self));
                    // Marked delivered BEFORE the call: if the hook itself
                    // errors, the run loop's exit path must not invoke it a
                    // second time (the hook contract is exactly-once).
                    self.app_stop_delivered = true;
                    try app.stop(self);
                    log(self, "app.stop", "app stopped", &.{trace.string("app", app.name)});
                },
            }
        }

        pub fn dispatchEvent(self: *Runtime, app: App, event_value: Event) anyerror!void {
            const event_fields = [_]trace.Field{trace.string("event", event_value.name())};
            log(self, "runtime.event", null, &event_fields);
            // A handler/update error degrades — recorded and observable,
            // never fatal. Propagating it would reach the platform
            // callback, set `failed`, and exit the whole app. The tag
            // name (not `Event.name()`, which for commands aliases
            // transient command-name storage) keeps ring records static.
            // Under the TestHarness's `.propagate` policy the recorded
            // error additionally returns, so capacity errors fail tests
            // instead of leaving silent stale frames.
            app.event(self, event_value) catch |err| {
                recordDispatchError(self, @tagName(event_value), err);
                if (self.dispatch_error_policy == .propagate) return err;
            };

            switch (event_value) {
                .command => {
                    if (self.options.extensions) |registry| {
                        registry.dispatchCommand(extensionContext(self), .{ .name = event_value.command.name }) catch |err| {
                            recordDispatchError(self, "extension.command", err);
                        };
                    }
                    self.invalidateFor(.command, null);
                },
                .shortcut => {
                    self.invalidateFor(.command, null);
                },
                .appearance_changed => {
                    self.invalidateFor(.state, null);
                },
                .timer => {},
                .effects_wake => {},
                .audio => {},
                .files_dropped => {},
                .gpu_surface_frame => {},
                .gpu_surface_resized => {},
                .gpu_surface_input => {},
                .canvas_widget_pointer => {},
                .canvas_widget_keyboard => {},
                .canvas_widget_scroll => {},
                .canvas_widget_file_drop => {},
                .canvas_widget_drag => {},
                .canvas_widget_context_menu => {
                    self.invalidateFor(.command, null);
                },
                .canvas_widget_context_menu_request => {
                    // The app loop answers by mounting the anchored
                    // fallback surface: a visual change.
                    self.invalidateFor(.command, null);
                },
                .canvas_widget_dismiss => {},
                .canvas_widget_context_press => {},
                .canvas_widget_resize => {},
                .canvas_widget_change => {},
                .window_closed => {
                    self.invalidateFor(.state, null);
                },
                .automation_provenance => {},
                .lifecycle => {},
            }
        }

        pub fn dispatchCommand(self: *Runtime, app: App, command: CommandEvent) anyerror!void {
            try validateCommandName(command.name);
            try dispatchEvent(self, app, .{ .command = command });
        }

        pub fn frame(self: *Runtime, app: App) anyerror!void {
            const start_ns = nowNanoseconds();
            // A media-surface producer's wake arrives as THIS event (the
            // platform's cross-thread frame request): adopt staged
            // frames here so an idle app's push reaches the runtime —
            // adoption's invalidation then arms the prompt gpu-surface
            // frame that composites it (`noteCanvasImagesChanged` ->
            // `requestCanvasFrameForView`). Runs before the invalidation
            // check below because adoption IS an invalidation source; a
            // busy app pays one fenced flag check per idle channel, and
            // the gpu-surface frame dispatch's own adoption call keeps
            // pacing consumption for hosts whose frame events do not
            // pass through here.
            self.adoptMediaSurfaceFrames();
            try consumeAutomationCommand(self, app);
            if (!self.invalidated) return;

            try publishAutomation(self);
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
            log(self, "runtime.frame", "frame published", &.{
                trace.uint("frame", self.frame_index),
                trace.uint("dirty_regions", self.last_diagnostics.dirty_region_count),
            });
            app.event(self, .{ .lifecycle = .frame }) catch |err| {
                recordDispatchError(self, "lifecycle", err);
                if (self.dispatch_error_policy == .propagate) return err;
            };
        }

        fn AutomationSnapshotMethods() type {
            return runtime_automation_snapshot.RuntimeAutomationSnapshot(Runtime);
        }

        pub fn automationSnapshot(self: *Runtime, title: []const u8) automation.snapshot.Input {
            return AutomationSnapshotMethods().automationSnapshot(self, title);
        }

        pub fn dispatchAutomationCommand(self: *Runtime, app: App, line: []const u8) anyerror!void {
            try dispatchAutomationProtocolCommand(self, app, try automation.protocol.Command.parse(line));
        }

        pub fn frameDiagnostics(self: *Runtime) FrameDiagnostics {
            return AutomationSnapshotMethods().frameDiagnostics(self);
        }

        pub fn supports(self: *const Runtime, feature: platform.PlatformFeature) bool {
            return self.options.platform.supports(feature);
        }

        fn handlePlatformEvent(context: *anyopaque, event_value: platform.Event) anyerror!void {
            const run_context: *RunContext = @ptrCast(@alignCast(context));
            try run_context.runtime.dispatchPlatformEvent(run_context.app, event_value);
        }

        fn loadStartupWindows(self: *Runtime, app: App) anyerror!void {
            // Scene-less startup always materializes the app's webview
            // source into the main window; a native-only build cannot.
            if (!self.options.web_layer) return error.WebViewLayerNotBuilt;
            const source = try WindowViewMethods().copyLoadedSource(self, try app.webViewSource());
            self.loaded_source = source;
            const app_info = self.options.platform.app_info;
            const count = app_info.startupWindowCount();
            var index: usize = 0;
            while (index < count) : (index += 1) {
                const window = app_info.resolvedStartupWindow(index);
                const runtime_index = if (WindowViewMethods().findWindowIndexById(self, window.id)) |runtime_index| blk: {
                    self.windows[runtime_index].source = try WindowViewMethods().copySource(self, runtime_index, source);
                    break :blk runtime_index;
                } else blk: {
                    const runtime_index = try WindowViewMethods().reserveWindow(self, window.id, window.label, window.resolvedTitle(app_info.app_name), source, true);
                    self.windows[runtime_index].info.frame = window.default_frame;
                    self.windows[runtime_index].main_frame = geometry.RectF.init(0, 0, window.default_frame.width, window.default_frame.height);
                    break :blk runtime_index;
                };
                self.windows[runtime_index].source_reloads_from_app = true;
                if (index > 0) {
                    _ = try self.options.platform.services.createWindow(window);
                }
                try self.options.platform.services.loadWindowWebView(window.id, self.windows[runtime_index].source.?);
                try applyMainWebViewState(self, window.id);
                self.next_window_id = @max(self.next_window_id, window.id + 1);
            }
            log(self, "webview.load", "loaded webview source", &.{
                trace.string("kind", @tagName(source.kind)),
                trace.uint("bytes", source.bytes.len),
            });
        }

        fn loadScene(self: *Runtime, app: App, scene: app_manifest.ShellConfig) anyerror!void {
            try app_manifest.validateShell(scene, &.{});
            if (scene.windows.len == 0) {
                log(self, "scene.load", "loaded empty app scene", &.{trace.string("app", app.name)});
                return;
            }

            const source = if (sceneNeedsMainWebView(scene) or !appUsesDefaultEmptyWebViewSource(App, app))
                try WindowViewMethods().copyLoadedSource(self, try app.webViewSource())
            else
                null;
            if (source != null and !self.options.web_layer) return error.WebViewLayerNotBuilt;
            self.loaded_source = source;

            try loadStartupSceneWindow(self, scene.windows[0], source);
            for (scene.windows[1..]) |window| {
                _ = try WindowViewMethods().createShellWindowWithSourceMode(self, window, source, source != null);
            }

            log(self, "scene.load", "loaded app scene", &.{
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
            const startup_frame = WindowViewMethods().startupWindowFrame(startup_window.default_frame, manifest_frame);

            const runtime_index = if (WindowViewMethods().findWindowIndexById(self, window_id)) |index| index else try WindowViewMethods().reserveWindow(
                self,
                window_id,
                shell_window.label,
                shell_window.title orelse app_info.resolvedWindowTitle(),
                null,
                true,
            );
            if (WindowViewMethods().findWindowIndexByLabel(self, shell_window.label)) |label_index| {
                if (label_index != runtime_index) return error.DuplicateWindowLabel;
            }

            self.windows[runtime_index].info.label = try copyInto(&self.windows[runtime_index].label_storage, shell_window.label);
            self.windows[runtime_index].info.title = try copyInto(&self.windows[runtime_index].title_storage, shell_window.title orelse app_info.resolvedWindowTitle());
            self.windows[runtime_index].info.frame = startup_frame;
            self.windows[runtime_index].source = if (source) |source_value| try WindowViewMethods().copySource(self, runtime_index, source_value) else null;
            self.windows[runtime_index].source_reloads_from_app = source != null;
            if (!self.windows[runtime_index].main_frame_set) {
                self.windows[runtime_index].main_frame = geometry.RectF.init(0, 0, startup_frame.width, startup_frame.height);
            }
            self.next_window_id = @max(self.next_window_id, window_id + 1);

            if (self.windows[runtime_index].source) |window_source| {
                try self.options.platform.services.loadWindowWebView(window_id, window_source);
                try applyMainWebViewState(self, window_id);
            }
            try WindowViewMethods().createShellViews(self, window_id, shell_window.views, WindowViewMethods().shellBoundsForWindow(self, window_id));
        }

        fn applyMainWebViewState(self: *Runtime, window_id: platform.WindowId) anyerror!void {
            const window_index = WindowViewMethods().findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
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
            if (!self.options.web_layer) return error.WebViewLayerNotBuilt;
            const source = try WindowViewMethods().copyLoadedSource(self, try app.webViewSource());
            self.loaded_source = source;
            try self.options.platform.services.loadWindowWebView(1, source);
        }

        pub fn reloadWindows(self: *Runtime, app: App) anyerror!void {
            // Reload re-materializes webview sources; native-only builds
            // have none to reload.
            if (!self.options.web_layer) return error.WebViewLayerNotBuilt;
            const source = try WindowViewMethods().copyLoadedSource(self, try app.webViewSource());
            self.loaded_source = source;
            if (self.window_count == 0) {
                try self.options.platform.services.loadWindowWebView(1, source);
                return;
            }
            for (self.windows[0..self.window_count], 0..) |*window, index| {
                if (window.source == null or window.source_reloads_from_app) {
                    window.source = try WindowViewMethods().copySource(self, index, source);
                }
                const window_source = window.source orelse source;
                try self.options.platform.services.loadWindowWebView(window.info.id, window_source);
            }
        }

        fn handleBridgeMessage(self: *Runtime, app: App, message: platform.BridgeMessage) anyerror!void {
            self.command_count += 1;
            if (try handleBuiltinBridgeMessage(self, app, message)) return;
            var dispatcher = self.options.bridge orelse bridge.Dispatcher{};
            if (self.options.security.permissions.len > 0) dispatcher.policy.permissions = self.options.security.permissions;
            var response_buffer: [bridge.max_response_bytes]u8 = undefined;
            if (try handleAsyncBridgeMessage(self, dispatcher, message)) {
                self.invalidateFor(.command, null);
                return;
            }
            const response = dispatcher.dispatch(message.bytes, .{ .origin = message.origin, .window_id = message.window_id, .webview_label = message.webview_label }, &response_buffer);
            try completeBridgeResponse(self, message.window_id, message.webview_label, response);
            self.invalidateFor(.command, null);
            log(self, "bridge.dispatch", "bridge request handled", &.{
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
                try completeBridgeResponse(self, message.window_id, message.webview_label, response);
                return true;
            }
            const source_slot = reserveAsyncBridgeResponse(self, .{
                .origin = message.origin,
                .window_id = message.window_id,
                .webview_label = message.webview_label,
            }) catch |err| {
                var response_buffer: [bridge.max_response_bytes]u8 = undefined;
                const response = bridge.writeErrorResponse(&response_buffer, request.id, .internal_error, @errorName(err));
                try completeBridgeResponse(self, message.window_id, message.webview_label, response);
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
            try server.publish(automationSnapshot(self, server.title));
        }

        fn consumeAutomationCommand(self: *Runtime, app: App) anyerror!void {
            const server = self.options.automation orelse return;
            var buffer: [automation.protocol.max_command_bytes]u8 = undefined;
            // Automation command errors ALWAYS degrade, regardless of
            // `dispatch_error_policy`: a stale widget target or a
            // malformed command is driver misuse, not an app fault —
            // propagating would escape the frame_requested platform
            // callback and kill the whole app under test, and the
            // TestHarness's `.propagate` policy is for app errors. The
            // record invalidates state, so the next published snapshot
            // carries the error where the driver can see it.
            const command = (server.takeCommand(&buffer) catch |err| {
                recordDispatchError(self, "automation.command", err);
                return;
            }) orelse return;
            dispatchAutomationProtocolCommand(self, app, command) catch |err| {
                recordDispatchErrorDetail(self, automationCommandEventName(command.action), err, command.value);
            };
        }

        /// Stable static event names for degraded automation command
        /// errors — one per widget action, a generic fallback for
        /// the rest (parse errors included).
        fn automationCommandEventName(action: automation.protocol.Action) []const u8 {
            return switch (action) {
                .widget_click => "automation.widget_click",
                .widget_hold => "automation.widget_hold",
                .widget_context_press => "automation.widget_context_press",
                .widget_context_menu => "automation.widget_context_menu",
                .widget_action => "automation.widget_action",
                .widget_drag => "automation.widget_drag",
                .widget_wheel => "automation.widget_wheel",
                .widget_key => "automation.widget_key",
                .widget_pinch => "automation.widget_pinch",
                .tray_action => "automation.tray_action",
                .provenance => "automation.provenance",
                else => "automation.command",
            };
        }

        fn dispatchAutomationProtocolCommand(self: *Runtime, app: App, command: automation.protocol.Command) anyerror!void {
            switch (command.action) {
                .reload => {
                    self.command_count += 1;
                    try reloadWindows(self, app);
                    self.invalidateFor(.command, null);
                },
                .bridge => {
                    try handleBridgeMessage(self, app, .{ .bytes = command.value, .origin = "zero://inline", .window_id = 1, .webview_label = "main" });
                },
                .resize => {
                    const parsed = try parseAutomationResizeCommand(command.value);
                    try dispatchPlatformEvent(self, app, .{ .surface_resized = .{
                        .id = 1,
                        .size = geometry.SizeF.init(parsed.width, parsed.height),
                        .scale_factor = parsed.scale_factor,
                    } });
                },
                .screenshot => {
                    publishAutomationScreenshot(self, command.value) catch |err| {
                        log(self, "automation.screenshot_failed", @errorName(err), &.{});
                    };
                },
                .native_command => {
                    const parsed = try parseAutomationNativeCommand(command.value);
                    try dispatchPlatformEvent(self, app, .{ .native_command = .{
                        .name = parsed.name,
                        .window_id = 1,
                        .view_label = parsed.view_label,
                    } });
                },
                .widget_action => {
                    try AutomationWidgetMethods().dispatchAutomationWidgetAction(self, app, try parseAutomationWidgetAction(command.value));
                },
                .widget_click => {
                    try AutomationWidgetMethods().dispatchAutomationWidgetClick(self, app, try parseAutomationWidgetTarget(command.value));
                },
                .widget_hold => {
                    try AutomationWidgetMethods().dispatchAutomationWidgetHold(self, app, try parseAutomationWidgetTarget(command.value));
                },
                .widget_context_press => {
                    try AutomationWidgetMethods().dispatchAutomationWidgetContextPress(self, app, try parseAutomationWidgetTarget(command.value));
                },
                .widget_context_menu => {
                    try AutomationWidgetMethods().dispatchAutomationWidgetContextMenuItem(self, app, try parseAutomationWidgetContextMenuItem(command.value));
                },
                .widget_drag => {
                    try AutomationWidgetMethods().dispatchAutomationWidgetPointerDrag(self, app, try parseAutomationWidgetPointerDrag(command.value));
                },
                .widget_wheel => {
                    try AutomationWidgetMethods().dispatchAutomationWidgetWheel(self, app, try parseAutomationWidgetWheel(command.value));
                },
                .widget_key => {
                    try AutomationWidgetMethods().dispatchAutomationWidgetKeyInput(self, app, try parseAutomationWidgetKey(command.value));
                },
                .widget_pinch => {
                    try AutomationWidgetMethods().dispatchAutomationWidgetPinch(self, app, try parseAutomationWidgetPinch(command.value));
                },
                .menu_command => {
                    try dispatchPlatformEvent(self, app, .{ .menu_command = .{
                        .name = try parseAutomationCommandName(command.value),
                        .window_id = 1,
                    } });
                },
                .shortcut => {
                    try dispatchPlatformEvent(self, app, .{ .shortcut = .{
                        .id = try parseAutomationCommandName(command.value),
                        .key = "",
                        .window_id = 1,
                    } });
                },
                .tray_action => {
                    // Drive a status-item dropdown row through the
                    // SAME platform event a real NSStatusItem menu click
                    // emits, so command resolution, `.tray` source, and
                    // UiApp's window fallback are all the real path. A
                    // stale or unknown item id is loud driver misuse,
                    // like widget-click on an unmounted widget.
                    const item_id = try parseAutomationTrayItemId(command.value);
                    if (!self.tray_created or !SystemServiceMethods().trayItemExists(self, item_id)) return error.InvalidCommand;
                    try dispatchPlatformEvent(self, app, .{ .tray_action = item_id });
                },
                .focus_view => {
                    try WindowViewMethods().focusView(self, 1, try parseAutomationViewLabel(command.value));
                },
                .focus_next_view => {
                    _ = try WindowViewMethods().focusNextView(self, 1);
                },
                .focus_previous_view => {
                    _ = try WindowViewMethods().focusPreviousView(self, 1);
                },
                .profile => {
                    // Toggle per-stage frame timing. Turning it on
                    // starts a fresh window (stale samples from an
                    // earlier session would skew the percentiles);
                    // turning it off stops recording and drops the
                    // snapshot's `frame_profile` line.
                    self.command_count += 1;
                    const enable = std.mem.eql(u8, command.value, "on");
                    if (!enable and !std.mem.eql(u8, command.value, "off")) return error.InvalidCommand;
                    if (enable and !self.frame_profile.enabled) self.frame_profile.reset();
                    self.frame_profile.enabled = enable;
                    self.invalidateFor(.command, null);
                },
                .provenance => {
                    try AutomationWidgetMethods().dispatchAutomationProvenance(self, app, try parseAutomationProvenanceTarget(command.value));
                },
                .wait => {},
            }
        }

        /// Render the named gpu_surface view's current canvas frame through
        /// the deterministic reference renderer and publish it as a PNG
        /// (`screenshot-<label>.png`) in the automation directory. The
        /// screenshot renders at scale 1 unless the command carries an
        /// explicit scale, so an unchanged scene produces byte-identical
        /// artifacts across captures.
        pub fn publishAutomationScreenshot(self: *Runtime, value: []const u8) anyerror!void {
            const server = self.options.automation orelse return;
            const parsed = try parseAutomationScreenshotCommand(value);
            // Screenshots address a gpu_surface view by label across ALL
            // open windows, like the widget verbs — a secondary window's
            // canvas captures the same way the main one does.
            const view_index = try AutomationWidgetMethods().automationGpuSurfaceViewIndexByLabel(self, parsed.view_label);
            const window_id = self.views[view_index].window_id;
            const allocator = std.heap.page_allocator;
            const pixel_size = try self.canvasScreenshotPixelSize(window_id, parsed.view_label, parsed.scale);
            const pixels = try allocator.alloc(u8, pixel_size.byte_len);
            defer allocator.free(pixels);
            const scratch = try allocator.alloc(u8, pixel_size.byte_len);
            defer allocator.free(scratch);
            const screenshot = try self.renderCanvasScreenshot(window_id, parsed.view_label, parsed.scale, pixels, scratch);
            var writer = try std.Io.Writer.Allocating.initCapacity(
                allocator,
                try canvas.png.encodedRgba8ByteLen(screenshot.width, screenshot.height),
            );
            defer writer.deinit();
            try canvas.png.writeRgba8(&writer.writer, screenshot.width, screenshot.height, screenshot.rgba8);
            try server.publishScreenshot(parsed.view_label, writer.written());
            // A screenshot taken during a recorded session marks a pixel
            // checkpoint: replay re-renders the same view at the same
            // scale through the same deterministic reference renderer
            // and compares hashes.
            if (self.options.session_recorder) |recorder| {
                recorder.recordScreenshot(
                    parsed.view_label,
                    parsed.scale orelse 1,
                    std.hash.Wyhash.hash(0, writer.written()),
                    writer.written().len,
                );
            }
            log(self, "automation.screenshot", "screenshot published", &.{
                trace.string("view", parsed.view_label),
                trace.uint("width", screenshot.width),
                trace.uint("height", screenshot.height),
                trace.uint("bytes", writer.written().len),
            });
        }

        const BuiltinBridgeMethods = runtime_builtin_bridge.RuntimeBuiltinBridge(Runtime);
        const allowsBuiltinBridgeCommand = BuiltinBridgeMethods.allowsBuiltinBridgeCommand;
        const dispatchCommandBridgeCommand = BuiltinBridgeMethods.dispatchCommandBridgeCommand;
        const dispatchPlatformBridgeCommand = BuiltinBridgeMethods.dispatchPlatformBridgeCommand;
        const dispatchWindowBridgeCommand = BuiltinBridgeMethods.dispatchWindowBridgeCommand;
        const invokeCommandFromJson = BuiltinBridgeMethods.invokeCommandFromJson;
        const writeCommandListJson = BuiltinBridgeMethods.writeCommandListJson;
        const dispatchViewBridgeCommand = BuiltinBridgeMethods.dispatchViewBridgeCommand;
        const dispatchWebViewBridgeCommand = BuiltinBridgeMethods.dispatchWebViewBridgeCommand;
        const dispatchDialogBridgeCommand = BuiltinBridgeMethods.dispatchDialogBridgeCommand;
        const dispatchOsBridgeCommand = BuiltinBridgeMethods.dispatchOsBridgeCommand;
        const dispatchCredentialBridgeCommand = BuiltinBridgeMethods.dispatchCredentialBridgeCommand;
        const dispatchClipboardBridgeCommand = BuiltinBridgeMethods.dispatchClipboardBridgeCommand;
        const createWindowFromJson = BuiltinBridgeMethods.createWindowFromJson;
        const createViewFromJson = BuiltinBridgeMethods.createViewFromJson;
        const updateViewFromJson = BuiltinBridgeMethods.updateViewFromJson;
        const setViewFrameFromJson = BuiltinBridgeMethods.setViewFrameFromJson;
        const setViewVisibleFromJson = BuiltinBridgeMethods.setViewVisibleFromJson;
        const focusViewFromJson = BuiltinBridgeMethods.focusViewFromJson;
        const focusNextViewFromJson = BuiltinBridgeMethods.focusNextViewFromJson;
        const focusPreviousViewFromJson = BuiltinBridgeMethods.focusPreviousViewFromJson;
        const closeViewFromJson = BuiltinBridgeMethods.closeViewFromJson;
        const writeViewListJson = BuiltinBridgeMethods.writeViewListJson;
        const createWebViewFromJson = BuiltinBridgeMethods.createWebViewFromJson;
        const setWebViewFrameFromJson = BuiltinBridgeMethods.setWebViewFrameFromJson;
        const navigateWebViewFromJson = BuiltinBridgeMethods.navigateWebViewFromJson;
        const setWebViewZoomFromJson = BuiltinBridgeMethods.setWebViewZoomFromJson;
        const setWebViewLayerFromJson = BuiltinBridgeMethods.setWebViewLayerFromJson;
        const closeWebViewFromJson = BuiltinBridgeMethods.closeWebViewFromJson;
        const focusWindowFromJson = BuiltinBridgeMethods.focusWindowFromJson;
        const closeWindowFromJson = BuiltinBridgeMethods.closeWindowFromJson;
        const resolveWindowSelector = BuiltinBridgeMethods.resolveWindowSelector;
        const writeWindowListJson = BuiltinBridgeMethods.writeWindowListJson;

        fn handleBuiltinBridgeMessage(self: *Runtime, app: App, message: platform.BridgeMessage) anyerror!bool {
            const request = bridge.parseRequest(message.bytes) catch return false;
            const is_command = std.mem.startsWith(u8, request.command, "native-sdk.command.");
            const is_window = std.mem.startsWith(u8, request.command, "native-sdk.window.");
            const is_view = std.mem.startsWith(u8, request.command, "native-sdk.view.");
            const is_webview = std.mem.startsWith(u8, request.command, "native-sdk.webview.");
            const is_platform = std.mem.startsWith(u8, request.command, "native-sdk.platform.");
            const is_dialog = std.mem.startsWith(u8, request.command, "native-sdk.dialog.");
            const is_os = std.mem.startsWith(u8, request.command, "native-sdk.os.");
            const is_clipboard = std.mem.startsWith(u8, request.command, "native-sdk.clipboard.");
            const is_credentials = std.mem.startsWith(u8, request.command, "native-sdk.credentials.");
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
            if (!allowsBuiltinBridgeCommand(self, request.command, message.origin, js_permission)) {
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
                try completeBridgeResponse(self, message.window_id, message.webview_label, result);
                self.invalidateFor(.command, null);
                return true;
            }
            const result = if (is_command)
                dispatchCommandBridgeCommand(self, app, request, message.window_id, message.webview_label, &result_buffer, &response_buffer)
            else if (is_window)
                dispatchWindowBridgeCommand(self, request, &result_buffer, &response_buffer)
            else if (is_view)
                dispatchViewBridgeCommand(self, request, message.window_id, &result_buffer, &response_buffer)
            else if (is_webview)
                dispatchWebViewBridgeCommand(self, request, message.window_id, &result_buffer, &response_buffer)
            else if (is_platform)
                dispatchPlatformBridgeCommand(self, request, &result_buffer, &response_buffer)
            else if (is_dialog)
                dispatchDialogBridgeCommand(self, request, &result_buffer, &response_buffer)
            else if (is_clipboard)
                dispatchClipboardBridgeCommand(self, request, &result_buffer, &response_buffer)
            else if (is_credentials)
                dispatchCredentialBridgeCommand(self, request, &result_buffer, &response_buffer)
            else
                dispatchOsBridgeCommand(self, request, &result_buffer, &response_buffer);

            try completeBridgeResponse(self, message.window_id, message.webview_label, result);
            self.invalidateFor(.command, null);
            return true;
        }

        fn completeBridgeResponse(self: *Runtime, window_id: platform.WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
            try self.options.platform.services.completeWebViewBridge(window_id, webview_label, response);
            if (self.options.automation) |server| {
                server.publishBridgeResponse(response) catch |err| log(self, "automation.bridge_response_failed", @errorName(err), &.{});
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
            try emitWindowEvent(self, shortcut.window_id, "shortcut", writer.buffered());
        }

        fn emitAppLifecycleEvent(self: *Runtime, name: []const u8) anyerror!void {
            for (self.windows[0..self.window_count]) |window| {
                if (window.info.open) try emitWindowEvent(self, window.info.id, name, "{}");
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
            try emitWindowEvent(self, drop.window_id, "drop:files", writer.buffered());
        }

        /// Trace logging never fails dispatch: a full or failing
        /// sink drops the record and counts the loss where snapshots can
        /// see it (`dropped_trace_records`).
        fn log(self: *Runtime, name_value: []const u8, message: ?[]const u8, fields: []const trace.Field) void {
            logAt(self, .info, name_value, message, fields);
        }

        fn logAt(self: *Runtime, level: trace.Level, name_value: []const u8, message: ?[]const u8, fields: []const trace.Field) void {
            const sink = self.options.trace_sink orelse return;
            trace.writeRecord(sink, trace.event(nextTimestamp(self), level, name_value, message, fields)) catch {
                self.dropped_trace_records +%= 1;
            };
        }

        /// A handler/update error must degrade, never terminate the
        /// app: record it in the bounded ring (queryable through
        /// `Runtime.dispatchErrors` and the automation snapshot), trace
        /// it at `.err`, and republish observable state.
        fn recordDispatchError(self: *Runtime, event_name: []const u8, err: anyerror) void {
            recordDispatchErrorDetail(self, event_name, err, "");
        }

        /// `detail` is copied (truncated) into the record so the snapshot
        /// error line carries failure context — for automation commands,
        /// the command arguments, so a failed widget verb names its
        /// target.
        fn recordDispatchErrorDetail(self: *Runtime, event_name: []const u8, err: anyerror, detail: []const u8) void {
            self.dispatch_error_total +%= 1;
            var record: automation.snapshot.DispatchError = .{
                .timestamp_ns = runtime_clock.timestampToU64(nowNanoseconds()),
                .event = event_name,
                .error_name = @errorName(err),
            };
            record.setDetail(detail);
            if (self.dispatch_error_len == self.dispatch_errors.len) {
                std.mem.copyForwards(automation.snapshot.DispatchError, self.dispatch_errors[0 .. self.dispatch_errors.len - 1], self.dispatch_errors[1..]);
                self.dispatch_errors[self.dispatch_errors.len - 1] = record;
            } else {
                self.dispatch_errors[self.dispatch_error_len] = record;
                self.dispatch_error_len += 1;
            }
            logAt(self, .err, "dispatch.error", @errorName(err), &.{trace.string("event", event_name)});
            self.invalidateFor(.state, null);
        }

        fn extensionContext(self: *Runtime) extensions.RuntimeContext {
            return .{ .platform_name = self.options.platform.name };
        }

        fn nextTimestamp(self: *Runtime) trace.Timestamp {
            self.timestamp_ns = nowNanoseconds();
            return trace.Timestamp.fromNanoseconds(self.timestamp_ns);
        }
    };
}

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

fn appUsesDefaultEmptyWebViewSource(comptime App: type, app: App) bool {
    return app.source_fn == null and
        app.source.kind == .html and
        app.source.bytes.len == 0 and
        app.source.asset_options == null;
}
