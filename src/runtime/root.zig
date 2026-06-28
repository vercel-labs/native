const std = @import("std");
const geometry = @import("geometry");
const trace = @import("trace");
const json = @import("json");
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
const max_command_id_bytes: usize = 128;
pub const max_canvas_commands_per_view: usize = 64;
pub const max_canvas_gradient_stops_per_view: usize = 64;
pub const max_canvas_path_elements_per_view: usize = 128;
pub const max_canvas_glyphs_per_view: usize = 256;
pub const max_canvas_text_bytes_per_view: usize = 2048;

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
pub const GpuSurfaceFrameEvent = platform.GpuSurfaceFrameEvent;
pub const GpuSurfaceResizeEvent = platform.GpuSurfaceResizeEvent;
pub const GpuSurfaceInputEvent = platform.GpuSurfaceInputEvent;

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
    command: CommandEvent,
    shortcut: ShortcutEvent,
    files_dropped: platform.FileDropEvent,
    gpu_surface_frame: GpuSurfaceFrameEvent,
    gpu_surface_resized: GpuSurfaceResizeEvent,
    gpu_surface_input: GpuSurfaceInputEvent,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .lifecycle => |event_value| @tagName(event_value),
            .command => |event_value| event_value.name,
            .shortcut => "shortcut",
            .files_dropped => "files_dropped",
            .gpu_surface_frame => "gpu_surface_frame",
            .gpu_surface_resized => "gpu_surface_resized",
            .gpu_surface_input => "gpu_surface_input",
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
};

pub const Runtime = struct {
    options: Options,
    surface: platform.Surface,
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

    pub fn init(options: Options) Runtime {
        var runtime = Runtime{
            .options = options,
            .surface = options.platform.surface(),
        };
        runtime.windows = undefined;
        runtime.views = undefined;
        runtime.shell_layouts = undefined;
        return runtime;
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
        return self.createWindowWithSourceMode(options, options.source == null);
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
        }, source_reloads_from_app);
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
                    if (layout.findView(parent) == null) continue;
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
        try self.views[index].copyCanvasDisplayList(display_list);
        self.invalidateFor(.state, self.views[index].frame);
        return self.views[index].info();
    }

    pub fn canvasDisplayList(self: *const Runtime, window_id: platform.WindowId, label: []const u8) anyerror!canvas.DisplayList {
        try self.validateViewParent(window_id);
        try validateViewLabel(label);
        const index = self.findViewIndex(window_id, label) orelse return error.ViewNotFound;
        if (self.views[index].kind != .gpu_surface) return error.InvalidViewOptions;
        return self.views[index].canvasDisplayList();
    }

    pub fn listViews(self: *const Runtime, window_id: platform.WindowId, output: []platform.ViewInfo) []const platform.ViewInfo {
        const window_index = self.findWindowIndexById(window_id) orelse return output[0..0];
        if (!self.windows[window_index].info.open) return output[0..0];

        var count: usize = 0;
        if (count < output.len) {
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
        self.setFocusedView(window_id, label);
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
            .surface_resized => |surface_value| {
                self.surface = surface_value;
                if (self.findWindowIndexById(surface_value.id)) |index| {
                    self.windows[index].info.frame.width = surface_value.size.width;
                    self.windows[index].info.frame.height = surface_value.size.height;
                    self.windows[index].info.scale_factor = surface_value.scale_factor;
                }
                self.relayoutShellViews(surface_value.id) catch |err| try self.log("shell.relayout_failed", @errorName(err), &.{trace.uint("window_id", surface_value.id)});
                var detail_buffer: [160]u8 = undefined;
                var detail_writer = std.Io.Writer.fixed(&detail_buffer);
                try detail_writer.print("{{\"width\":{d},\"height\":{d},\"scale\":{d}}}", .{
                    surface_value.size.width,
                    surface_value.size.height,
                    surface_value.scale_factor,
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
                if (self.findViewIndex(frame_event.window_id, frame_event.label)) |index| {
                    self.views[index].gpu_frame_index = frame_event.frame_index;
                    self.views[index].gpu_frame_nonblank = frame_event.nonblank;
                    self.views[index].gpu_sample_color = frame_event.sample_color;
                }
                try self.dispatchEvent(app, .{ .gpu_surface_frame = frame_event });
            },
            .gpu_surface_resized => |resize_event| {
                if (self.findViewIndex(resize_event.window_id, resize_event.label)) |index| {
                    self.views[index].frame = resize_event.frame;
                }
                try self.dispatchEvent(app, .{ .gpu_surface_resized = resize_event });
                self.invalidateFor(.surface_resize, resize_event.frame);
                try self.log("gpu_surface.resize", "gpu surface resized", &.{
                    trace.string("label", resize_event.label),
                    trace.float("width", resize_event.frame.width),
                    trace.float("height", resize_event.frame.height),
                    trace.float("scale", resize_event.scale_factor),
                });
            },
            .gpu_surface_input => |input_event| {
                switch (input_event.kind) {
                    .pointer_down,
                    .key_down,
                    => {
                        self.setFocusedView(input_event.window_id, input_event.label);
                        self.invalidated = true;
                    },
                    else => {},
                }
                try self.dispatchEvent(app, .{ .gpu_surface_input = input_event });
            },
            .menu_command => |command| {
                try self.dispatchCommand(app, .{
                    .name = command.name,
                    .source = .menu,
                    .window_id = command.window_id,
                });
            },
            .files_dropped => |drop| {
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
            .files_dropped => {},
            .gpu_surface_frame => {},
            .gpu_surface_resized => {},
            .gpu_surface_input => {},
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
                .diagnostics = .{ .frame_index = self.last_diagnostics.frame_index, .command_count = self.last_diagnostics.command_count },
                .source = self.loaded_source,
            };
        }
        var view_count: usize = 0;
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
        }
        return .{
            .windows = self.automation_windows[0..count],
            .views = self.automation_views[0..view_count],
            .diagnostics = .{ .frame_index = self.last_diagnostics.frame_index, .command_count = self.last_diagnostics.command_count },
            .source = self.loaded_source,
        };
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

        const source = try self.copyLoadedSource(try app.webViewSource());
        self.loaded_source = source;

        try self.loadStartupSceneWindow(scene.windows[0], source);
        for (scene.windows[1..]) |window| {
            _ = try self.createShellWindowWithSourceMode(window, source, true);
        }

        try self.log("scene.load", "loaded app scene", &.{
            trace.string("app", app.name),
            trace.uint("windows", scene.windows.len),
        });
    }

    fn loadStartupSceneWindow(self: *Runtime, shell_window: app_manifest.ShellWindow, source: platform.WebViewSource) anyerror!void {
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
        self.windows[runtime_index].source = try self.copySource(runtime_index, source);
        self.windows[runtime_index].source_reloads_from_app = true;
        if (!self.windows[runtime_index].main_frame_set) {
            self.windows[runtime_index].main_frame = geometry.RectF.init(0, 0, startup_frame.width, startup_frame.height);
        }
        self.next_window_id = @max(self.next_window_id, window_id + 1);

        try self.options.platform.services.loadWindowWebView(window_id, self.windows[runtime_index].source.?);
        try self.applyMainWebViewState(window_id);
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

    fn createWindowWithSourceMode(self: *Runtime, options: platform.WindowCreateOptions, source_reloads_from_app: bool) anyerror!platform.WindowInfo {
        const source = options.source orelse self.loaded_source orelse return error.MissingWindowSource;
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
        try self.options.platform.services.loadWindowWebView(id, self.windows[index].source.?);
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
        return geometry.RectF.init(0, 0, frame_value.width, frame_value.height);
    }

    fn startupWindowFrame(native_frame: geometry.RectF, manifest_frame: geometry.RectF) geometry.RectF {
        const default_frame = (platform.WindowOptions{}).default_frame;
        if (!rectsEqual(native_frame, default_frame)) return native_frame;
        return manifest_frame;
    }

    fn rectsEqual(a: geometry.RectF, b: geometry.RectF) bool {
        return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
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
        try writer.print("{{\"windowId\":{d},\"paths\":[", .{drop.window_id});
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
        var scratch: [platform.max_view_label_bytes * 2 + platform.max_view_role_bytes + platform.max_view_accessibility_label_bytes + platform.max_view_text_bytes + platform.max_view_command_bytes + platform.max_webview_url_bytes]u8 = undefined;
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

    fn setFocusedView(self: *Runtime, window_id: platform.WindowId, label: []const u8) void {
        if (self.findWindowIndexById(window_id)) |window_index| {
            self.windows[window_index].main_focused = std.mem.eql(u8, label, "main");
        }
        for (self.views[0..self.view_count]) |*view| {
            if (view.window_id == window_id) view.focused = std.mem.eql(u8, view.label, label);
        }
        for (self.webviews[0..self.webview_count]) |*webview| {
            if (webview.window_id == window_id) webview.focused = std.mem.eql(u8, webview.label, label);
        }
    }

    fn clearFocusedView(self: *Runtime, window_id: platform.WindowId) void {
        if (self.findWindowIndexById(window_id)) |window_index| {
            self.windows[window_index].main_focused = false;
        }
        for (self.views[0..self.view_count]) |*view| {
            if (view.window_id == window_id) view.focused = false;
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
                self.clearFocusedView(window_id);
            };
        } else {
            self.clearFocusedView(window_id);
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

const RunContext = struct {
    runtime: *Runtime,
    app: App,
};

const RuntimeWindow = struct {
    info: platform.WindowInfo = .{},
    main_view_id: platform.ViewId = 0,
    source: ?platform.WebViewSource = null,
    source_reloads_from_app: bool = false,
    main_frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    main_frame_set: bool = false,
    main_layer: i32 = 0,
    main_parent: ?[]const u8 = null,
    main_zoom: f64 = 1.0,
    main_focused: bool = false,
    label_storage: [platform.max_window_label_bytes]u8 = undefined,
    title_storage: [platform.max_window_title_bytes]u8 = undefined,
    main_parent_storage: [platform.max_view_label_bytes]u8 = undefined,
    source_storage: RuntimeSourceStorage = .{},
};

const RuntimeMainWebViewState = struct {
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    frame_set: bool = false,
    layer: i32 = 0,
    parent: ?[]const u8 = null,
    parent_storage: [platform.max_view_label_bytes]u8 = undefined,
};

const RuntimeSourceStorage = struct {
    bytes: [platform.max_window_source_bytes]u8 = undefined,
    asset_root_path: [platform.max_window_source_bytes]u8 = undefined,
    asset_entry: [platform.max_window_source_bytes]u8 = undefined,
    asset_origin: [platform.max_window_source_bytes]u8 = undefined,
};

fn copySourceInto(storage: *RuntimeSourceStorage, source: platform.WebViewSource) !platform.WebViewSource {
    var copied = source;
    copied.bytes = try copyWindowSourceField(&storage.bytes, source.bytes);
    if (source.asset_options) |assets| {
        copied.asset_options = .{
            .root_path = try copyWindowSourceField(&storage.asset_root_path, assets.root_path),
            .entry = try copyWindowSourceField(&storage.asset_entry, assets.entry),
            .origin = try copyWindowSourceField(&storage.asset_origin, assets.origin),
            .spa_fallback = assets.spa_fallback,
        };
    }
    return copied;
}

fn copyWindowSourceField(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.WindowSourceTooLarge;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

const RuntimeWebView = struct {
    id: platform.ViewId = 0,
    window_id: platform.WindowId = 1,
    label: []const u8 = "",
    parent: ?[]const u8 = null,
    url: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    local_frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    zoom: f64 = 1.0,
    transparent: bool = false,
    bridge_enabled: bool = false,
    focused: bool = false,
    open: bool = false,
    label_storage: [platform.max_webview_label_bytes]u8 = undefined,
    parent_storage: [platform.max_view_label_bytes]u8 = undefined,
    url_storage: [platform.max_webview_url_bytes]u8 = undefined,
};

const RuntimeTrayItem = struct {
    id: platform.TrayItemId = 0,
    command: []const u8 = "",
    command_storage: [platform.max_tray_item_command_bytes]u8 = undefined,
};

const RuntimeShellLayout = struct {
    window_id: platform.WindowId = 1,
    views: [app_manifest.max_shell_views_per_window]app_manifest.ShellView = undefined,
    view_count: usize = 0,
    label_storage: [app_manifest.max_shell_views_per_window][app_manifest.max_view_label_bytes]u8 = undefined,
    parent_storage: [app_manifest.max_shell_views_per_window][app_manifest.max_view_label_bytes]u8 = undefined,

    fn viewSlice(self: *const RuntimeShellLayout) []const app_manifest.ShellView {
        return self.views[0..self.view_count];
    }

    fn copyViews(self: *RuntimeShellLayout, source: []const app_manifest.ShellView) !void {
        if (source.len > self.views.len) return error.ViewLimitReached;
        for (source, 0..) |view, index| {
            var copied = view;
            copied.label = try copyInto(&self.label_storage[index], view.label);
            copied.parent = if (view.parent) |parent| try copyInto(&self.parent_storage[index], parent) else null;
            copied.role = null;
            copied.accessibility_label = null;
            copied.url = null;
            copied.text = null;
            copied.command = null;
            self.views[index] = copied;
        }
        self.view_count = source.len;
    }
};

const ShellApplyMode = enum {
    create,
    update,
};

const FocusTraversalDirection = enum {
    next,
    previous,
};

const CanvasResourceCounts = struct {
    command_count: usize = 0,
    gradient_stop_count: usize = 0,
    path_element_count: usize = 0,
    glyph_count: usize = 0,
    text_byte_count: usize = 0,

    fn fromDisplayList(display_list: canvas.DisplayList) anyerror!CanvasResourceCounts {
        var counts: CanvasResourceCounts = .{};
        try addCanvasCount(&counts.command_count, display_list.commands.len, max_canvas_commands_per_view, error.CanvasCommandLimitReached);
        for (display_list.commands) |command| try counts.addCommand(command);
        return counts;
    }

    fn addCommand(self: *CanvasResourceCounts, command: canvas.CanvasCommand) anyerror!void {
        switch (command) {
            .push_clip, .pop_clip, .push_opacity, .pop_opacity, .transform, .draw_image, .blur => {},
            .fill_rect => |value| try self.addFill(value.fill),
            .stroke_rect => |value| try self.addStroke(value.stroke),
            .fill_rounded_rect => |value| try self.addFill(value.fill),
            .draw_line => |value| try self.addStroke(value.stroke),
            .fill_path => |value| {
                try addCanvasCount(&self.path_element_count, value.elements.len, max_canvas_path_elements_per_view, error.CanvasPathElementLimitReached);
                try self.addFill(value.fill);
            },
            .stroke_path => |value| {
                try addCanvasCount(&self.path_element_count, value.elements.len, max_canvas_path_elements_per_view, error.CanvasPathElementLimitReached);
                try self.addStroke(value.stroke);
            },
            .draw_text => |value| {
                try addCanvasCount(&self.text_byte_count, value.text.len, max_canvas_text_bytes_per_view, error.CanvasTextTooLarge);
                try addCanvasCount(&self.glyph_count, value.glyphs.len, max_canvas_glyphs_per_view, error.CanvasGlyphLimitReached);
            },
            .shadow => |value| {
                _ = value;
            },
        }
    }

    fn addStroke(self: *CanvasResourceCounts, stroke: canvas.Stroke) anyerror!void {
        try self.addFill(stroke.fill);
    }

    fn addFill(self: *CanvasResourceCounts, fill: canvas.Fill) anyerror!void {
        switch (fill) {
            .color => {},
            .linear_gradient => |gradient| try addCanvasCount(&self.gradient_stop_count, gradient.stops.len, max_canvas_gradient_stops_per_view, error.CanvasGradientStopLimitReached),
        }
    }
};

fn addCanvasCount(value: *usize, amount: usize, max_value: usize, comptime failure: anyerror) anyerror!void {
    if (amount > max_value or value.* > max_value - amount) return failure;
    value.* += amount;
}

const RuntimeView = struct {
    id: platform.ViewId = 0,
    window_id: platform.WindowId = 1,
    label: []const u8 = "",
    kind: platform.ViewKind = .toolbar,
    parent: ?[]const u8 = null,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    visible: bool = true,
    enabled: bool = true,
    role: []const u8 = "",
    accessibility_label: []const u8 = "",
    text: []const u8 = "",
    command: []const u8 = "",
    transparent: bool = false,
    bridge_enabled: bool = false,
    gpu_frame_index: u64 = 0,
    gpu_frame_nonblank: bool = false,
    gpu_sample_color: u32 = 0,
    canvas_commands: [max_canvas_commands_per_view]canvas.CanvasCommand = undefined,
    canvas_command_count: usize = 0,
    canvas_revision: u64 = 0,
    canvas_gradient_stops: [max_canvas_gradient_stops_per_view]canvas.GradientStop = undefined,
    canvas_gradient_stop_count: usize = 0,
    canvas_path_elements: [max_canvas_path_elements_per_view]canvas.PathElement = undefined,
    canvas_path_element_count: usize = 0,
    canvas_glyphs: [max_canvas_glyphs_per_view]canvas.Glyph = undefined,
    canvas_glyph_count: usize = 0,
    canvas_text_bytes: [max_canvas_text_bytes_per_view]u8 = undefined,
    canvas_text_len: usize = 0,
    focused: bool = false,
    open: bool = false,
    label_storage: [platform.max_view_label_bytes]u8 = undefined,
    parent_storage: [platform.max_view_label_bytes]u8 = undefined,
    role_storage: [platform.max_view_role_bytes]u8 = undefined,
    accessibility_label_storage: [platform.max_view_accessibility_label_bytes]u8 = undefined,
    text_storage: [platform.max_view_text_bytes]u8 = undefined,
    command_storage: [platform.max_view_command_bytes]u8 = undefined,

    fn info(self: RuntimeView) platform.ViewInfo {
        return .{
            .id = self.id,
            .window_id = self.window_id,
            .label = self.label,
            .kind = self.kind,
            .parent = self.parent,
            .frame = self.frame,
            .layer = self.layer,
            .visible = self.visible,
            .enabled = self.enabled,
            .role = self.role,
            .accessibility_label = self.accessibility_label,
            .text = self.text,
            .command = self.command,
            .url = "",
            .transparent = self.transparent,
            .bridge_enabled = self.bridge_enabled,
            .gpu_frame_index = self.gpu_frame_index,
            .gpu_frame_nonblank = self.gpu_frame_nonblank,
            .gpu_sample_color = self.gpu_sample_color,
            .canvas_revision = self.canvas_revision,
            .canvas_command_count = self.canvas_command_count,
            .focused = self.focused,
            .open = self.open,
        };
    }

    fn copyRuntimeStateFrom(self: *RuntimeView, source: *const RuntimeView) void {
        self.* = source.*;
        self.label = copyInto(&self.label_storage, source.label) catch unreachable;
        self.parent = if (source.parent) |parent| copyInto(&self.parent_storage, parent) catch unreachable else null;
        self.role = copyInto(&self.role_storage, source.role) catch unreachable;
        self.accessibility_label = copyInto(&self.accessibility_label_storage, source.accessibility_label) catch unreachable;
        self.text = copyInto(&self.text_storage, source.text) catch unreachable;
        self.command = copyInto(&self.command_storage, source.command) catch unreachable;
        self.copyCanvasDisplayList(source.canvasDisplayList()) catch unreachable;
        self.canvas_revision = source.canvas_revision;
    }

    fn canvasDisplayList(self: *const RuntimeView) canvas.DisplayList {
        return .{ .commands = self.canvas_commands[0..self.canvas_command_count] };
    }

    fn copyCanvasDisplayList(self: *RuntimeView, display_list: canvas.DisplayList) anyerror!void {
        _ = try CanvasResourceCounts.fromDisplayList(display_list);
        if (display_list.commands.len > 0 and display_list.commands.ptr == self.canvas_commands[0..].ptr) {
            self.canvas_revision += 1;
            return;
        }

        self.canvas_command_count = 0;
        self.canvas_gradient_stop_count = 0;
        self.canvas_path_element_count = 0;
        self.canvas_glyph_count = 0;
        self.canvas_text_len = 0;

        for (display_list.commands) |command| {
            self.canvas_commands[self.canvas_command_count] = try self.copyCanvasCommand(command);
            self.canvas_command_count += 1;
        }
        self.canvas_revision += 1;
    }

    fn copyCanvasCommand(self: *RuntimeView, command: canvas.CanvasCommand) anyerror!canvas.CanvasCommand {
        return switch (command) {
            .push_clip => |value| .{ .push_clip = value },
            .pop_clip => .pop_clip,
            .push_opacity => |value| .{ .push_opacity = value },
            .pop_opacity => .pop_opacity,
            .transform => |value| .{ .transform = value },
            .fill_rect => |value| blk: {
                var copy = value;
                copy.fill = try self.copyCanvasFill(value.fill);
                break :blk .{ .fill_rect = copy };
            },
            .stroke_rect => |value| blk: {
                var copy = value;
                copy.stroke = try self.copyCanvasStroke(value.stroke);
                break :blk .{ .stroke_rect = copy };
            },
            .fill_rounded_rect => |value| blk: {
                var copy = value;
                copy.fill = try self.copyCanvasFill(value.fill);
                break :blk .{ .fill_rounded_rect = copy };
            },
            .draw_line => |value| blk: {
                var copy = value;
                copy.stroke = try self.copyCanvasStroke(value.stroke);
                break :blk .{ .draw_line = copy };
            },
            .fill_path => |value| blk: {
                var copy = value;
                copy.elements = try self.copyCanvasPathElements(value.elements);
                copy.fill = try self.copyCanvasFill(value.fill);
                break :blk .{ .fill_path = copy };
            },
            .stroke_path => |value| blk: {
                var copy = value;
                copy.elements = try self.copyCanvasPathElements(value.elements);
                copy.stroke = try self.copyCanvasStroke(value.stroke);
                break :blk .{ .stroke_path = copy };
            },
            .draw_image => |value| .{ .draw_image = value },
            .draw_text => |value| blk: {
                var copy = value;
                copy.text = try self.copyCanvasText(value.text);
                copy.glyphs = try self.copyCanvasGlyphs(value.glyphs);
                break :blk .{ .draw_text = copy };
            },
            .shadow => |value| .{ .shadow = value },
            .blur => |value| .{ .blur = value },
        };
    }

    fn copyCanvasStroke(self: *RuntimeView, stroke: canvas.Stroke) anyerror!canvas.Stroke {
        var copy = stroke;
        copy.fill = try self.copyCanvasFill(stroke.fill);
        return copy;
    }

    fn copyCanvasFill(self: *RuntimeView, fill: canvas.Fill) anyerror!canvas.Fill {
        return switch (fill) {
            .color => |color| .{ .color = color },
            .linear_gradient => |gradient| .{ .linear_gradient = .{
                .start = gradient.start,
                .end = gradient.end,
                .stops = try self.copyCanvasGradientStops(gradient.stops),
            } },
        };
    }

    fn copyCanvasGradientStops(self: *RuntimeView, stops: []const canvas.GradientStop) anyerror![]const canvas.GradientStop {
        const end = self.canvas_gradient_stop_count + stops.len;
        if (end > self.canvas_gradient_stops.len) return error.CanvasGradientStopLimitReached;
        const start = self.canvas_gradient_stop_count;
        @memcpy(self.canvas_gradient_stops[start..end], stops);
        self.canvas_gradient_stop_count = end;
        return self.canvas_gradient_stops[start..end];
    }

    fn copyCanvasPathElements(self: *RuntimeView, elements: []const canvas.PathElement) anyerror![]const canvas.PathElement {
        const end = self.canvas_path_element_count + elements.len;
        if (end > self.canvas_path_elements.len) return error.CanvasPathElementLimitReached;
        const start = self.canvas_path_element_count;
        @memcpy(self.canvas_path_elements[start..end], elements);
        self.canvas_path_element_count = end;
        return self.canvas_path_elements[start..end];
    }

    fn copyCanvasGlyphs(self: *RuntimeView, glyphs: []const canvas.Glyph) anyerror![]const canvas.Glyph {
        const end = self.canvas_glyph_count + glyphs.len;
        if (end > self.canvas_glyphs.len) return error.CanvasGlyphLimitReached;
        const start = self.canvas_glyph_count;
        @memcpy(self.canvas_glyphs[start..end], glyphs);
        self.canvas_glyph_count = end;
        return self.canvas_glyphs[start..end];
    }

    fn copyCanvasText(self: *RuntimeView, text: []const u8) anyerror![]const u8 {
        const end = self.canvas_text_len + text.len;
        if (end > self.canvas_text_bytes.len) return error.CanvasTextTooLarge;
        const start = self.canvas_text_len;
        @memcpy(self.canvas_text_bytes[start..end], text);
        self.canvas_text_len = end;
        return self.canvas_text_bytes[start..end];
    }
};

const ShellResolvedView = struct {
    label: []const u8 = "",
    kind: app_manifest.ViewKind = .webview,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    absolute_frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    axis: app_manifest.ShellAxis = .row,
};

const ShellParentCursor = struct {
    label: []const u8 = "",
    x: f32 = 8,
    y: f32 = 8,
};

const ShellLayout = struct {
    remaining: geometry.RectF,
    fill_rect: geometry.RectF,
    views: [app_manifest.max_shell_views_per_window]ShellResolvedView = undefined,
    view_count: usize = 0,
    parent_cursors: [app_manifest.max_shell_views_per_window]ShellParentCursor = undefined,
    parent_cursor_count: usize = 0,

    fn init(window_frame: geometry.RectF, views: []const app_manifest.ShellView) ShellLayout {
        const base = geometry.RectF.init(0, 0, window_frame.width, window_frame.height);
        var fill_rect = base;
        for (views) |view| {
            if (view.parent != null or view.fill) continue;
            const edge = view.edge orelse continue;
            const frame = dockedShellFrame(fill_rect, view, edge);
            consumeShellRect(&fill_rect, edge, frame);
        }
        return .{
            .remaining = base,
            .fill_rect = fill_rect,
        };
    }

    fn frameFor(self: *ShellLayout, view: app_manifest.ShellView) !geometry.RectF {
        const frame = if (view.parent != null)
            try self.parentedFrame(view)
        else if (view.fill)
            self.fillFrame(view)
        else if (view.edge) |edge|
            self.dockedFrame(view, edge)
        else
            explicitShellFrame(view);
        try self.recordView(view, frame);
        return frame;
    }

    fn parentedFrame(self: *ShellLayout, view: app_manifest.ShellView) !geometry.RectF {
        const parent_label = view.parent orelse return error.InvalidViewOptions;
        const parent = self.findView(parent_label) orelse return error.InvalidViewOptions;
        if (parent.kind == .split) return self.splitChildFrame(view, parent);
        return self.stackChildFrame(view, parent);
    }

    fn stackChildFrame(self: *ShellLayout, view: app_manifest.ShellView, parent: ShellResolvedView) geometry.RectF {
        const width = constrainedShellWidth(view, view.width orelse defaultShellViewWidth(view.kind));
        const height = constrainedShellHeight(view, view.height orelse defaultShellViewHeight(view.kind, parent.frame.height));
        const cursor = self.parentCursor(parent);
        const x = view.x orelse switch (parent.axis) {
            .row => cursor.x,
            .column => 8,
        };
        const y = view.y orelse switch (parent.axis) {
            .row => centeredOffset(parent.frame.height, height),
            .column => cursor.y,
        };
        switch (parent.axis) {
            .row => if (view.x == null) {
                cursor.x = x + width + 8;
            },
            .column => if (view.y == null) {
                cursor.y = y + height + 8;
            },
        }
        return geometry.RectF.init(x, y, width, height);
    }

    fn splitChildFrame(self: *ShellLayout, view: app_manifest.ShellView, parent: ShellResolvedView) geometry.RectF {
        const cursor = self.parentCursor(parent);
        const x = view.x orelse switch (parent.axis) {
            .row => cursor.x,
            .column => 0,
        };
        const y = view.y orelse switch (parent.axis) {
            .row => 0,
            .column => cursor.y,
        };
        const remaining_width = @max(parent.frame.width - x, 0);
        const remaining_height = @max(parent.frame.height - y, 0);
        const width = constrainedShellWidth(view, view.width orelse switch (parent.axis) {
            .row => if (view.fill) remaining_width else defaultShellViewWidth(view.kind),
            .column => remaining_width,
        });
        const height = constrainedShellHeight(view, view.height orelse switch (parent.axis) {
            .row => remaining_height,
            .column => if (view.fill) remaining_height else defaultShellViewHeight(view.kind, parent.frame.height),
        });

        switch (parent.axis) {
            .row => cursor.x = @max(cursor.x, x + width),
            .column => cursor.y = @max(cursor.y, y + height),
        }
        return geometry.RectF.init(x, y, width, height);
    }

    fn fillFrame(self: *ShellLayout, view: app_manifest.ShellView) geometry.RectF {
        const width = constrainedShellWidth(view, view.width orelse self.fill_rect.width);
        const height = constrainedShellHeight(view, view.height orelse self.fill_rect.height);
        return geometry.RectF.init(
            view.x orelse self.fill_rect.x,
            view.y orelse self.fill_rect.y,
            width,
            height,
        );
    }

    fn dockedFrame(self: *ShellLayout, view: app_manifest.ShellView, edge: app_manifest.ShellEdge) geometry.RectF {
        const frame = dockedShellFrame(self.remaining, view, edge);
        consumeShellRect(&self.remaining, edge, frame);
        return frame;
    }

    fn recordView(self: *ShellLayout, view: app_manifest.ShellView, frame: geometry.RectF) !void {
        if (self.view_count >= self.views.len) return error.ViewLimitReached;
        var absolute_frame = frame;
        if (view.parent) |parent_label| {
            const parent = self.findView(parent_label) orelse return error.InvalidViewOptions;
            absolute_frame.x += parent.absolute_frame.x;
            absolute_frame.y += parent.absolute_frame.y;
        }
        self.views[self.view_count] = .{
            .label = view.label,
            .kind = view.kind,
            .frame = frame,
            .absolute_frame = absolute_frame,
            .axis = view.axis orelse .row,
        };
        self.view_count += 1;
    }

    fn findView(self: *const ShellLayout, label: []const u8) ?ShellResolvedView {
        for (self.views[0..self.view_count]) |view| {
            if (std.mem.eql(u8, view.label, label)) return view;
        }
        return null;
    }

    fn parentCursor(self: *ShellLayout, parent: ShellResolvedView) *ShellParentCursor {
        for (self.parent_cursors[0..self.parent_cursor_count]) |*cursor| {
            if (std.mem.eql(u8, cursor.label, parent.label)) return cursor;
        }
        const index = self.parent_cursor_count;
        const origin: f32 = if (parent.kind == .split) 0 else 8;
        self.parent_cursors[index] = .{ .label = parent.label, .x = origin, .y = origin };
        self.parent_cursor_count += 1;
        return &self.parent_cursors[index];
    }
};

fn shellRestorePolicy(policy: app_manifest.WindowRestorePolicy) platform.WindowRestorePolicy {
    return switch (policy) {
        .clamp_to_visible_screen => .clamp_to_visible_screen,
        .center_on_primary => .center_on_primary,
    };
}

fn shellViewOptions(window_id: platform.WindowId, view: app_manifest.ShellView, layout: *ShellLayout) !platform.ViewOptions {
    const frame = try layout.frameFor(view);
    const resolved = layout.findView(view.label) orelse return error.InvalidViewOptions;
    const platform_frame = if (view.kind == .webview and view.parent != null and isMainWebViewLabel(view.label)) resolved.absolute_frame else frame;
    return .{
        .window_id = window_id,
        .label = view.label,
        .kind = shellViewKind(view.kind),
        .parent = view.parent,
        .frame = platform_frame,
        .layer = view.layer,
        .visible = view.visible,
        .enabled = view.enabled,
        .role = view.role orelse "",
        .accessibility_label = view.accessibility_label orelse "",
        .text = view.text orelse view.role orelse "",
        .command = view.command orelse "",
        .url = view.url orelse "",
        .bridge_enabled = view.kind == .webview,
    };
}

fn shellViewKind(kind: app_manifest.ViewKind) platform.ViewKind {
    return switch (kind) {
        .webview => .webview,
        .toolbar => .toolbar,
        .titlebar_accessory => .titlebar_accessory,
        .sidebar => .sidebar,
        .statusbar => .statusbar,
        .split => .split,
        .stack => .stack,
        .button => .button,
        .icon_button => .icon_button,
        .list_item => .list_item,
        .checkbox => .checkbox,
        .toggle => .toggle,
        .segmented_control => .segmented_control,
        .text_field => .text_field,
        .search_field => .search_field,
        .label => .label,
        .spacer => .spacer,
        .gpu_surface => .gpu_surface,
        .progress_indicator => .progress_indicator,
    };
}

fn explicitShellFrame(view: app_manifest.ShellView) geometry.RectF {
    return geometry.RectF.init(
        view.x orelse 0,
        view.y orelse 0,
        constrainedShellWidth(view, view.width orelse defaultShellViewWidth(view.kind)),
        constrainedShellHeight(view, view.height orelse defaultShellViewHeight(view.kind, 0)),
    );
}

fn dockedShellFrame(remaining: geometry.RectF, view: app_manifest.ShellView, edge: app_manifest.ShellEdge) geometry.RectF {
    return switch (edge) {
        .top => frame: {
            const width = constrainedShellWidth(view, view.width orelse remaining.width);
            const height = constrainedShellHeight(view, view.height orelse defaultDockHeight(view.kind));
            break :frame geometry.RectF.init(remaining.x, remaining.y, width, height);
        },
        .bottom => frame: {
            const width = constrainedShellWidth(view, view.width orelse remaining.width);
            const height = constrainedShellHeight(view, view.height orelse defaultDockHeight(view.kind));
            break :frame geometry.RectF.init(remaining.x, remaining.y + @max(remaining.height - height, 0), width, height);
        },
        .left => frame: {
            const width = constrainedShellWidth(view, view.width orelse defaultDockWidth(view.kind));
            const height = constrainedShellHeight(view, view.height orelse remaining.height);
            break :frame geometry.RectF.init(remaining.x, remaining.y, width, height);
        },
        .right => frame: {
            const width = constrainedShellWidth(view, view.width orelse defaultDockWidth(view.kind));
            const height = constrainedShellHeight(view, view.height orelse remaining.height);
            break :frame geometry.RectF.init(remaining.x + @max(remaining.width - width, 0), remaining.y, width, height);
        },
    };
}

fn constrainedShellWidth(view: app_manifest.ShellView, width: f32) f32 {
    var result = width;
    if (view.min_width) |min_width| result = @max(result, min_width);
    if (view.max_width) |max_width| result = @min(result, max_width);
    return result;
}

fn constrainedShellHeight(view: app_manifest.ShellView, height: f32) f32 {
    var result = height;
    if (view.min_height) |min_height| result = @max(result, min_height);
    if (view.max_height) |max_height| result = @min(result, max_height);
    return result;
}

fn consumeShellRect(remaining: *geometry.RectF, edge: app_manifest.ShellEdge, frame: geometry.RectF) void {
    switch (edge) {
        .top => {
            remaining.y += frame.height;
            remaining.height = @max(remaining.height - frame.height, 0);
        },
        .bottom => {
            remaining.height = @max(remaining.height - frame.height, 0);
        },
        .left => {
            remaining.x += frame.width;
            remaining.width = @max(remaining.width - frame.width, 0);
        },
        .right => {
            remaining.width = @max(remaining.width - frame.width, 0);
        },
    }
}

fn defaultDockHeight(kind: app_manifest.ViewKind) f32 {
    return switch (kind) {
        .toolbar => 48,
        .titlebar_accessory => 36,
        .statusbar => 28,
        else => defaultShellViewHeight(kind, 0),
    };
}

fn defaultDockWidth(kind: app_manifest.ViewKind) f32 {
    return switch (kind) {
        .sidebar => 240,
        else => defaultShellViewWidth(kind),
    };
}

fn defaultShellViewWidth(kind: app_manifest.ViewKind) f32 {
    return switch (kind) {
        .button, .checkbox, .toggle => 96,
        .icon_button => 32,
        .list_item => 220,
        .segmented_control => 168,
        .label => 160,
        .spacer => 12,
        .progress_indicator => 24,
        .text_field, .search_field => 220,
        .sidebar => 240,
        else => 0,
    };
}

fn defaultShellViewHeight(kind: app_manifest.ViewKind, parent_height: f32) f32 {
    return switch (kind) {
        .button, .icon_button, .checkbox, .toggle, .segmented_control, .list_item => 32,
        .label => 24,
        .spacer => @max(parent_height, 1),
        .progress_indicator => 24,
        .text_field, .search_field => 28,
        .toolbar => 48,
        .titlebar_accessory => 36,
        .statusbar => 28,
        else => 0,
    };
}

fn centeredOffset(parent_height: f32, height: f32) f32 {
    if (parent_height <= height) return 0;
    return (parent_height - height) / 2;
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

fn sourceWebViewUrl(source: ?platform.WebViewSource) []const u8 {
    const value = source orelse return "";
    return switch (value.kind) {
        .html => "zero://inline",
        .url, .assets => value.bytes,
    };
}

fn writeWindowJson(window: platform.WindowInfo, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writeWindowJsonToWriter(window, &writer);
    return writer.buffered();
}

fn writeTrueJson(output: []u8) ![]const u8 {
    return writeBoolJson(true, output);
}

fn writeBoolJson(value: bool, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll(if (value) "true" else "false");
    return writer.buffered();
}

fn writeWebViewOkJson(label: []const u8, window_id: platform.WindowId, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"label\":");
    try json.writeString(&writer, label);
    try writer.print(",\"windowId\":{d}}}", .{window_id});
    return writer.buffered();
}

fn writeWebViewJson(webview: RuntimeWebView, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writeWebViewJsonToWriter(webview, &writer);
    return writer.buffered();
}

fn writeViewJson(view: platform.ViewInfo, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writeViewJsonToWriter(view, &writer);
    return writer.buffered();
}

fn writeCommandEventJson(event_value: CommandEvent, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"name\":");
    try json.writeString(&writer, event_value.name);
    try writer.writeAll(",\"source\":");
    try json.writeString(&writer, @tagName(event_value.source));
    try writer.print(",\"windowId\":{d},\"viewLabel\":", .{event_value.window_id});
    try json.writeString(&writer, event_value.view_label);
    try writer.print(",\"trayItemId\":{d}", .{event_value.tray_item_id});
    try writer.writeByte('}');
    return writer.buffered();
}

fn writeCommandJsonToWriter(command: Command, writer: anytype) !void {
    try writer.writeAll("{\"id\":");
    try json.writeString(writer, command.id);
    try writer.writeAll(",\"title\":");
    try json.writeString(writer, command.title);
    try writer.print(",\"enabled\":{},\"checked\":{}}}", .{ command.enabled, command.checked });
}

fn writeViewJsonToWriter(view: platform.ViewInfo, writer: anytype) !void {
    try writer.print("{{\"id\":{d},\"label\":", .{view.id});
    try json.writeString(writer, view.label);
    try writer.print(",\"windowId\":{d},\"kind\":", .{view.window_id});
    try json.writeString(writer, @tagName(view.kind));
    try writer.writeAll(",\"parent\":");
    if (view.parent) |parent| {
        try json.writeString(writer, parent);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"role\":");
    try json.writeString(writer, view.role);
    try writer.writeAll(",\"accessibilityLabel\":");
    try json.writeString(writer, view.accessibility_label);
    try writer.writeAll(",\"text\":");
    try json.writeString(writer, view.text);
    try writer.writeAll(",\"command\":");
    try json.writeString(writer, view.command);
    try writer.writeAll(",\"url\":");
    try json.writeString(writer, view.url);
    try writer.print(",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"layer\":{d},\"visible\":{},\"enabled\":{},\"transparent\":{},\"bridge\":{},\"gpuFrame\":{d},\"gpuNonblank\":{},\"gpuSampleColor\":{d},\"canvasRevision\":{d},\"canvasCommandCount\":{d},\"focused\":{},\"open\":{}}}", .{
        view.frame.x,
        view.frame.y,
        view.frame.width,
        view.frame.height,
        view.layer,
        view.visible,
        view.enabled,
        view.transparent,
        view.bridge_enabled,
        view.gpu_frame_index,
        view.gpu_frame_nonblank,
        view.gpu_sample_color,
        view.canvas_revision,
        view.canvas_command_count,
        view.focused,
        view.open,
    });
}

fn viewInfoFromWebView(webview: RuntimeWebView) platform.ViewInfo {
    return .{
        .id = webview.id,
        .window_id = webview.window_id,
        .label = webview.label,
        .kind = .webview,
        .parent = webview.parent,
        .frame = webview.frame,
        .layer = webview.layer,
        .visible = webview.open,
        .enabled = true,
        .role = "webview",
        .accessibility_label = "WebView",
        .url = webview.url,
        .transparent = webview.transparent,
        .bridge_enabled = webview.bridge_enabled,
        .focused = webview.focused,
        .open = webview.open,
    };
}

fn writeWebViewJsonToWriter(webview: RuntimeWebView, writer: anytype) !void {
    try writer.writeAll("{\"label\":");
    try json.writeString(writer, webview.label);
    try writer.print(",\"windowId\":{d},\"url\":", .{webview.window_id});
    try json.writeString(writer, webview.url);
    try writer.print(",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"layer\":{d},\"zoom\":{d},\"transparent\":{},\"bridge\":{},\"focused\":{},\"open\":{}}}", .{
        webview.frame.x,
        webview.frame.y,
        webview.frame.width,
        webview.frame.height,
        webview.layer,
        webview.zoom,
        webview.transparent,
        webview.bridge_enabled,
        webview.focused,
        webview.open,
    });
}

fn writeWindowJsonToWriter(window: platform.WindowInfo, writer: anytype) !void {
    try writer.writeAll("{\"id\":");
    try writer.print("{d}", .{window.id});
    try writer.writeAll(",\"label\":");
    try json.writeString(writer, window.label);
    try writer.writeAll(",\"title\":");
    try json.writeString(writer, window.title);
    try writer.writeAll(",\"open\":");
    try writer.writeAll(if (window.open) "true" else "false");
    try writer.writeAll(",\"focused\":");
    try writer.writeAll(if (window.focused) "true" else "false");
    try writer.print(",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"scale\":{d}", .{
        window.frame.x,
        window.frame.y,
        window.frame.width,
        window.frame.height,
        window.scale_factor,
    });
    try writer.writeByte('}');
}

fn builtinBridgeErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedService => "Native service is not available on this platform",
        error.WindowNotFound => "Window was not found",
        error.WindowLimitReached => "Window limit reached",
        error.DuplicateWindowLabel => "Window id or label already exists",
        error.MissingWindowSource => "Window source is missing",
        error.WindowSourceTooLarge => "Window source is too large",
        error.CreateFailed => "Native view creation failed",
        error.MissingWebViewUrl => "WebView URL is missing",
        error.InvalidWebViewWindowId => "windowId must be a non-negative integer",
        error.CrossWindowWebViewDenied => "WebView windowId must match the calling window",
        error.InvalidWebViewOptions => "WebView options are invalid",
        error.WebViewNotFound => "WebView was not found",
        error.WebViewLimitReached => "WebView limit reached",
        error.DuplicateWebViewLabel => "WebView label already exists",
        error.ReservedWebViewLabel => "WebView label \"main\" is reserved for the startup WebView",
        error.WebViewLabelTooLarge => "WebView label is too large",
        error.WebViewUrlTooLarge => "WebView URL is too large",
        error.UnsupportedChildWebViews => "This backend does not support child WebViews yet",
        error.UnsupportedWebViewBridge => "This backend does not support bridge-enabled child WebViews yet",
        error.UnsupportedMainWebViewFrame => "This backend does not support resizing the main WebView yet",
        error.UnsupportedMainWebViewZoom => "This backend does not support zooming the main WebView yet",
        error.UnsupportedMainWebViewLayer => "This backend does not support changing the main WebView layer",
        error.NavigationDenied => "URL is not allowed by navigation policy",
        error.InvalidExternalUrl => "External URL is invalid",
        error.ExternalUrlTooLarge => "External URL is too large",
        error.InvalidRevealPath => "Reveal path is invalid",
        error.RevealPathTooLarge => "Reveal path is too large",
        error.InvalidRecentDocumentPath => "Recent document path is invalid",
        error.RecentDocumentPathTooLarge => "Recent document path is too large",
        error.InvalidDialogOptions => "Dialog options are invalid",
        error.DialogFieldTooLarge => "Dialog field is too large",
        error.InvalidNotificationOptions => "Notification options are invalid",
        error.NotificationFieldTooLarge => "Notification field is too large",
        error.InvalidClipboardOptions => "Clipboard options are invalid",
        error.ClipboardFieldTooLarge => "Clipboard field is too large",
        error.InvalidCredentialOptions => "Credential options are invalid",
        error.CredentialFieldTooLarge => "Credential field is too large",
        error.CredentialNotFound => "Credential was not found",
        error.InvalidTrayOptions => "Tray options are invalid",
        error.TrayFieldTooLarge => "Tray field is too large",
        error.InvalidPlatformFeature => "Platform feature is invalid",
        error.InvalidWindowOptions => "Window options are invalid",
        error.InvalidCommand => "Command name is invalid",
        error.DuplicateWindowId => "Window id already exists",
        error.InvalidViewOptions => "View options are invalid",
        error.InvalidViewWindowId => "view windowId must be a non-negative integer",
        error.CrossWindowViewDenied => "view windowId must match the calling window",
        error.ViewNotFound => "View was not found",
        error.ViewLimitReached => "View limit reached",
        error.DuplicateViewLabel => "View label already exists",
        error.ViewLabelTooLarge => "View label is too large",
        error.ViewRoleTooLarge => "View role is too large",
        error.ViewAccessibilityLabelTooLarge => "View accessibility label is too large",
        error.ViewTextTooLarge => "View text is too large",
        error.UnsupportedViewKind => "This backend does not support this native view kind yet",
        error.UnsupportedViewFocus => "This backend does not support focusing this native view yet",
        error.NoSpaceLeft => "Native response buffer is too small",
        else => "Native command failed",
    };
}

fn builtinBridgeErrorCode(err: anyerror) bridge.ErrorCode {
    return switch (err) {
        error.UnsupportedService,
        error.InvalidWindowOptions,
        error.WindowNotFound,
        error.WindowLimitReached,
        error.DuplicateWindowId,
        error.DuplicateWindowLabel,
        error.MissingWindowSource,
        error.WindowSourceTooLarge,
        error.MissingWebViewUrl,
        error.InvalidWebViewWindowId,
        error.CrossWindowWebViewDenied,
        error.InvalidWebViewOptions,
        error.WebViewNotFound,
        error.WebViewLimitReached,
        error.DuplicateWebViewLabel,
        error.ReservedWebViewLabel,
        error.WebViewLabelTooLarge,
        error.WebViewUrlTooLarge,
        error.UnsupportedChildWebViews,
        error.UnsupportedWebViewBridge,
        error.UnsupportedMainWebViewFrame,
        error.UnsupportedMainWebViewZoom,
        error.UnsupportedMainWebViewLayer,
        error.InvalidCommand,
        error.InvalidViewOptions,
        error.InvalidViewWindowId,
        error.CrossWindowViewDenied,
        error.ViewNotFound,
        error.ViewLimitReached,
        error.DuplicateViewLabel,
        error.ViewLabelTooLarge,
        error.ViewRoleTooLarge,
        error.ViewAccessibilityLabelTooLarge,
        error.ViewTextTooLarge,
        error.UnsupportedViewKind,
        error.UnsupportedViewFocus,
        error.InvalidExternalUrl,
        error.ExternalUrlTooLarge,
        error.InvalidRevealPath,
        error.RevealPathTooLarge,
        error.InvalidRecentDocumentPath,
        error.RecentDocumentPathTooLarge,
        error.InvalidDialogOptions,
        error.DialogFieldTooLarge,
        error.InvalidNotificationOptions,
        error.NotificationFieldTooLarge,
        error.InvalidClipboardOptions,
        error.ClipboardFieldTooLarge,
        error.InvalidCredentialOptions,
        error.CredentialFieldTooLarge,
        error.InvalidTrayOptions,
        error.TrayFieldTooLarge,
        error.InvalidPlatformFeature,
        => .invalid_request,
        error.NavigationDenied => .invalid_request,
        else => .internal_error,
    };
}

fn jsonStringField(payload: []const u8, field: []const u8, storage: *json.StringStorage) ?[]const u8 {
    return json.stringField(payload, field, storage);
}

const AutomationNativeCommand = struct {
    name: []const u8,
    view_label: []const u8 = "",
};

const AutomationResizeCommand = struct {
    width: f32,
    height: f32,
    scale_factor: f32 = 1,
};

fn parseAutomationCommandName(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \n\r\t");
    if (trimmed.len == 0) return error.InvalidCommand;
    const separator = std.mem.indexOfAny(u8, trimmed, " \n\r\t") orelse return trimmed;
    return trimmed[0..separator];
}

fn parseAutomationViewLabel(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \n\r\t");
    if (trimmed.len == 0) return error.InvalidCommand;
    return trimmed;
}

fn parseAutomationNativeCommand(value: []const u8) !AutomationNativeCommand {
    const trimmed = std.mem.trim(u8, value, " \n\r\t");
    if (trimmed.len == 0) return error.InvalidCommand;
    const separator = std.mem.indexOfAny(u8, trimmed, " \n\r\t") orelse return .{ .name = trimmed };
    const view_label = std.mem.trim(u8, trimmed[separator + 1 ..], " \n\r\t");
    return .{
        .name = trimmed[0..separator],
        .view_label = view_label,
    };
}

fn parseAutomationResizeCommand(value: []const u8) !AutomationResizeCommand {
    var parts = std.mem.tokenizeAny(u8, value, " \n\r\t");
    const width_bytes = parts.next() orelse return error.InvalidCommand;
    const height_bytes = parts.next() orelse return error.InvalidCommand;
    const scale_bytes = parts.next();
    if (parts.next() != null) return error.InvalidCommand;
    const width = std.fmt.parseFloat(f32, width_bytes) catch return error.InvalidCommand;
    const height = std.fmt.parseFloat(f32, height_bytes) catch return error.InvalidCommand;
    const scale_factor = if (scale_bytes) |bytes| std.fmt.parseFloat(f32, bytes) catch return error.InvalidCommand else 1;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or !std.math.isFinite(scale_factor)) return error.InvalidCommand;
    if (width <= 0 or height <= 0 or scale_factor <= 0) return error.InvalidCommand;
    return .{
        .width = width,
        .height = height,
        .scale_factor = scale_factor,
    };
}

test "runtime parses automation resize commands" {
    const resize = try parseAutomationResizeCommand("900 640");
    try std.testing.expectEqual(@as(f32, 900), resize.width);
    try std.testing.expectEqual(@as(f32, 640), resize.height);
    try std.testing.expectEqual(@as(f32, 1), resize.scale_factor);

    const scaled = try parseAutomationResizeCommand("900 640 2");
    try std.testing.expectEqual(@as(f32, 2), scaled.scale_factor);

    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand("900"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand("0 640"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand("900 nan"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand("900 640 1 2"));
}

test "runtime parses automation focus view labels" {
    const label = try parseAutomationViewLabel(" refresh-button \n");
    try std.testing.expectEqualStrings("refresh-button", label);
    try std.testing.expectError(error.InvalidCommand, parseAutomationViewLabel(""));
}

fn validateCommandName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_command_id_bytes) return error.InvalidCommand;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidCommand;
    for (name) |ch| {
        if (ch == 0 or ch == '/' or ch == '\\' or ch == '\n' or ch == '\r' or ch == '\t') return error.InvalidCommand;
    }
}

fn validateRevealPath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidRevealPath;
    if (path.len > platform.max_reveal_path_bytes) return error.RevealPathTooLarge;
    for (path) |ch| {
        if (ch == 0) return error.InvalidRevealPath;
    }
}

fn validateRecentDocumentPath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidRecentDocumentPath;
    if (path.len > platform.max_recent_document_path_bytes) return error.RecentDocumentPathTooLarge;
    for (path) |ch| {
        if (ch == 0) return error.InvalidRecentDocumentPath;
    }
}

fn validateOpenDialogOptions(options: platform.OpenDialogOptions, buffer: []u8) !void {
    if (buffer.len == 0) return error.InvalidDialogOptions;
    try validateDialogString(options.title, platform.max_dialog_title_bytes, true);
    try validateDialogString(options.default_path, platform.max_dialog_path_bytes, true);
    try validateDialogFilters(options.filters);
}

fn validateSaveDialogOptions(options: platform.SaveDialogOptions, buffer: []u8) !void {
    if (buffer.len == 0) return error.InvalidDialogOptions;
    try validateDialogString(options.title, platform.max_dialog_title_bytes, true);
    try validateDialogString(options.default_path, platform.max_dialog_path_bytes, true);
    try validateDialogString(options.default_name, platform.max_dialog_path_bytes, true);
    try validateDialogFilters(options.filters);
}

fn validateMessageDialogOptions(options: platform.MessageDialogOptions) !void {
    try validateDialogString(options.title, platform.max_dialog_title_bytes, true);
    try validateDialogString(options.message, platform.max_dialog_message_bytes, true);
    try validateDialogString(options.informative_text, platform.max_dialog_message_bytes, true);
    try validateDialogString(options.primary_button, platform.max_dialog_button_bytes, false);
    try validateDialogString(options.secondary_button, platform.max_dialog_button_bytes, true);
    try validateDialogString(options.tertiary_button, platform.max_dialog_button_bytes, true);
}

fn validateDialogFilters(filters: []const platform.FileFilter) !void {
    var flattened_len: usize = 0;
    for (filters) |filter| {
        try validateDialogString(filter.name, platform.max_dialog_filter_name_bytes, true);
        for (filter.extensions) |extension| {
            try validateDialogString(extension, platform.max_dialog_filter_bytes, false);
            if (std.mem.indexOfScalar(u8, extension, ';') != null) return error.InvalidDialogOptions;
            flattened_len += extension.len;
            if (flattened_len > platform.max_dialog_filter_bytes) return error.DialogFieldTooLarge;
            flattened_len += 1;
            if (flattened_len > platform.max_dialog_filter_bytes + 1) return error.DialogFieldTooLarge;
        }
    }
}

fn validateDialogString(value: []const u8, max_len: usize, allow_empty: bool) !void {
    if (!allow_empty and value.len == 0) return error.InvalidDialogOptions;
    if (value.len > max_len) return error.DialogFieldTooLarge;
    for (value) |ch| {
        if (ch == 0) return error.InvalidDialogOptions;
    }
}

fn validateNotificationOptions(options: platform.NotificationOptions) !void {
    if (options.title.len == 0) return error.InvalidNotificationOptions;
    try validateNotificationField(options.title, platform.max_notification_title_bytes);
    try validateNotificationField(options.subtitle, platform.max_notification_subtitle_bytes);
    try validateNotificationField(options.body, platform.max_notification_body_bytes);
}

fn validateClipboardData(data: platform.ClipboardData) !void {
    try validateClipboardMimeType(data.mime_type);
    if (data.bytes.len > platform.max_clipboard_data_bytes) return error.ClipboardFieldTooLarge;
}

fn validateClipboardMimeType(mime_type: []const u8) !void {
    if (mime_type.len == 0) return error.InvalidClipboardOptions;
    if (mime_type.len > platform.max_clipboard_mime_type_bytes) return error.ClipboardFieldTooLarge;
    for (mime_type) |ch| {
        if (ch == 0 or ch == '/' or ch == '\\') {
            if (ch != '/') return error.InvalidClipboardOptions;
        }
        if (ch <= 0x20 or ch == 0x7f) return error.InvalidClipboardOptions;
    }
}

fn validateCredential(credential: platform.Credential) !void {
    try validateCredentialKey(.{ .service = credential.service, .account = credential.account });
    try validateCredentialField(credential.secret, platform.max_credential_secret_bytes);
}

fn validateCredentialKey(key: platform.CredentialKey) !void {
    try validateCredentialField(key.service, platform.max_credential_service_bytes);
    try validateCredentialField(key.account, platform.max_credential_account_bytes);
}

fn validateCredentialField(value: []const u8, max_len: usize) !void {
    if (value.len == 0) return error.InvalidCredentialOptions;
    if (value.len > max_len) return error.CredentialFieldTooLarge;
    for (value) |ch| {
        if (ch == 0) return error.InvalidCredentialOptions;
    }
}

fn validateTrayOptions(options: platform.TrayOptions) !void {
    try validateTrayField(options.icon_path, platform.max_tray_icon_path_bytes);
    try validateTrayField(options.tooltip, platform.max_tray_tooltip_bytes);
    try validateTrayMenuItems(options.items);
}

fn validateTrayMenuItems(items: []const platform.TrayMenuItem) !void {
    if (items.len > platform.max_tray_items) return error.InvalidTrayOptions;
    for (items, 0..) |item, index| {
        try validateTrayField(item.label, platform.max_tray_item_label_bytes);
        try validateTrayField(item.command, platform.max_tray_item_command_bytes);
        if (item.id != 0) {
            for (items[0..index]) |previous| {
                if (previous.id == item.id) return error.InvalidTrayOptions;
            }
        }
        if (item.command.len > 0) {
            if (item.separator or item.id == 0) return error.InvalidTrayOptions;
            try validateCommandName(item.command);
        }
        if (!item.separator and item.label.len == 0) return error.InvalidTrayOptions;
    }
}

fn validateTrayField(value: []const u8, max_len: usize) !void {
    if (value.len > max_len) return error.TrayFieldTooLarge;
    for (value) |ch| {
        if (ch == 0) return error.InvalidTrayOptions;
    }
}

fn validateNotificationField(value: []const u8, max_len: usize) !void {
    if (value.len > max_len) return error.NotificationFieldTooLarge;
    for (value) |ch| {
        if (ch == 0) return error.InvalidNotificationOptions;
    }
}

fn webViewWindowIdFromJson(payload: []const u8, default_window_id: platform.WindowId) !platform.WindowId {
    if (json.fieldValue(payload, "windowId") == null) return default_window_id;
    const window_id = jsonIntegerField(payload, "windowId") orelse return error.InvalidWebViewWindowId;
    if (window_id != default_window_id) return error.CrossWindowWebViewDenied;
    return window_id;
}

fn viewWindowIdFromJson(payload: []const u8, default_window_id: platform.WindowId) !platform.WindowId {
    if (json.fieldValue(payload, "windowId") == null) return default_window_id;
    const window_id = jsonIntegerField(payload, "windowId") orelse return error.InvalidViewWindowId;
    if (window_id != default_window_id) return error.CrossWindowViewDenied;
    return window_id;
}

fn viewKindFromString(value: []const u8) ?platform.ViewKind {
    inline for (@typeInfo(platform.ViewKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(platform.ViewKind, field.name);
    }
    if (std.mem.eql(u8, value, "titlebarAccessory")) return .titlebar_accessory;
    if (std.mem.eql(u8, value, "iconButton")) return .icon_button;
    if (std.mem.eql(u8, value, "listItem")) return .list_item;
    if (std.mem.eql(u8, value, "segmentedControl")) return .segmented_control;
    if (std.mem.eql(u8, value, "textField")) return .text_field;
    if (std.mem.eql(u8, value, "searchField")) return .search_field;
    if (std.mem.eql(u8, value, "gpuSurface")) return .gpu_surface;
    if (std.mem.eql(u8, value, "progressIndicator")) return .progress_indicator;
    return null;
}

fn platformFeatureFromString(value: []const u8) ?platform.PlatformFeature {
    inline for (@typeInfo(platform.PlatformFeature).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(platform.PlatformFeature, field.name);
    }
    if (std.mem.eql(u8, value, "mainWebView")) return .main_webview;
    if (std.mem.eql(u8, value, "childWebViews")) return .child_webviews;
    if (std.mem.eql(u8, value, "nativeViews")) return .native_views;
    if (std.mem.eql(u8, value, "nativeControlCommands")) return .native_control_commands;
    if (std.mem.eql(u8, value, "clipboardText")) return .clipboard_text;
    if (std.mem.eql(u8, value, "clipboardRichData")) return .clipboard_rich_data;
    if (std.mem.eql(u8, value, "openUrl")) return .open_url;
    if (std.mem.eql(u8, value, "revealPath")) return .reveal_path;
    if (std.mem.eql(u8, value, "recentDocuments")) return .recent_documents;
    if (std.mem.eql(u8, value, "fileDrops")) return .file_drops;
    if (std.mem.eql(u8, value, "appActivationEvents")) return .app_activation_events;
    if (std.mem.eql(u8, value, "gpuSurfaces")) return .gpu_surfaces;
    return null;
}

fn viewFrameFromJson(payload: []const u8, required: bool) !?geometry.RectF {
    const frame_payload = json.fieldValue(payload, "frame") orelse {
        if (required) return error.InvalidViewOptions;
        return null;
    };
    const width = jsonNumberField(frame_payload, "width") orelse return error.InvalidViewOptions;
    const height = jsonNumberField(frame_payload, "height") orelse return error.InvalidViewOptions;
    const frame = geometry.RectF.init(
        jsonNumberField(frame_payload, "x") orelse 0,
        jsonNumberField(frame_payload, "y") orelse 0,
        width,
        height,
    );
    if (frame.x < 0 or frame.y < 0 or frame.width < 0 or frame.height < 0) return error.InvalidViewOptions;
    return frame;
}

fn viewLayerFromJson(payload: []const u8) !?i32 {
    if (json.fieldValue(payload, "layer") == null) return null;
    const layer_bytes = json.fieldValue(payload, "layer") orelse return error.InvalidViewOptions;
    const layer_value = std.fmt.parseFloat(f64, layer_bytes) catch return error.InvalidViewOptions;
    if (!std.math.isFinite(layer_value)) return error.InvalidViewOptions;
    if (@trunc(layer_value) != layer_value) return error.InvalidViewOptions;
    const max_layer: f64 = @floatFromInt(std.math.maxInt(i32));
    const min_layer: f64 = @floatFromInt(std.math.minInt(i32));
    if (layer_value > max_layer or layer_value < min_layer) return error.InvalidViewOptions;
    return @as(i32, @intFromFloat(layer_value));
}

fn webViewFrameFromJson(payload: []const u8) !geometry.RectF {
    const frame_payload = json.fieldValue(payload, "frame") orelse payload;
    const width = jsonNumberField(frame_payload, "width") orelse return error.InvalidWebViewOptions;
    const height = jsonNumberField(frame_payload, "height") orelse return error.InvalidWebViewOptions;
    const frame = geometry.RectF.init(
        jsonNumberField(frame_payload, "x") orelse 0,
        jsonNumberField(frame_payload, "y") orelse 0,
        width,
        height,
    );
    if (frame.x < 0 or frame.y < 0 or frame.width <= 0 or frame.height <= 0) return error.InvalidWebViewOptions;
    return frame;
}

fn validateWindowFrame(frame: geometry.RectF) !void {
    if (!std.math.isFinite(frame.x) or !std.math.isFinite(frame.y) or !std.math.isFinite(frame.width) or !std.math.isFinite(frame.height)) return error.InvalidWindowOptions;
    if (frame.width <= 0 or frame.height <= 0) return error.InvalidWindowOptions;
}

fn webViewLayerFromJson(payload: []const u8) !i32 {
    if (json.fieldValue(payload, "layer") == null) return 0;
    const layer_bytes = json.fieldValue(payload, "layer") orelse return error.InvalidWebViewOptions;
    const layer_value = std.fmt.parseFloat(f64, layer_bytes) catch return error.InvalidWebViewOptions;
    if (!std.math.isFinite(layer_value)) return error.InvalidWebViewOptions;
    if (@trunc(layer_value) != layer_value) return error.InvalidWebViewOptions;
    const max_layer: f64 = @floatFromInt(std.math.maxInt(i32));
    const min_layer: f64 = @floatFromInt(std.math.minInt(i32));
    if (layer_value > max_layer or layer_value < min_layer) return error.InvalidWebViewOptions;
    return @as(i32, @intFromFloat(layer_value));
}

fn isMainWebViewLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "main");
}

fn isFocusableViewInfo(view: platform.ViewInfo) bool {
    return view.open and view.visible and view.enabled;
}

fn validateWebViewLabel(label: []const u8) !void {
    if (label.len == 0) return error.InvalidWebViewOptions;
    if (label.len > platform.max_webview_label_bytes) return error.WebViewLabelTooLarge;
}

fn validateChildWebViewLabel(label: []const u8) !void {
    try validateWebViewLabel(label);
    if (isMainWebViewLabel(label)) return error.ReservedWebViewLabel;
}

fn validateViewOptions(options: platform.ViewOptions) !void {
    try validateViewLabel(options.label);
    try validateViewFrame(options.frame);
    if (options.parent) |parent| {
        if (parent.len == 0 or parent.len > platform.max_view_label_bytes) return error.InvalidViewOptions;
    }
    if (options.role.len > platform.max_view_role_bytes) return error.ViewRoleTooLarge;
    if (options.accessibility_label.len > platform.max_view_accessibility_label_bytes) return error.ViewAccessibilityLabelTooLarge;
    if (options.text.len > platform.max_view_text_bytes) return error.ViewTextTooLarge;
    if (options.command.len > 0) try validateCommandName(options.command);
    if (options.kind != .webview and options.url.len > 0) return error.InvalidViewOptions;
}

fn validateViewLabel(label: []const u8) !void {
    if (label.len == 0) return error.InvalidViewOptions;
    if (label.len > platform.max_view_label_bytes) return error.ViewLabelTooLarge;
}

fn validateViewFrame(frame: geometry.RectF) !void {
    if (frame.x < 0 or frame.y < 0 or frame.width < 0 or frame.height < 0) return error.InvalidViewOptions;
}

fn isValidWebViewFrame(frame: geometry.RectF) bool {
    return frame.x >= 0 and frame.y >= 0 and frame.width > 0 and frame.height > 0;
}

fn webViewUrlOrigin(url: []const u8, buffer: []u8) ![]const u8 {
    if (std.mem.startsWith(u8, url, "about:")) return "about://local";
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidWebViewOptions;
    const host_start = scheme_end + 3;
    if (host_start >= url.len) return error.InvalidWebViewOptions;
    var host_end = host_start;
    while (host_end < url.len and url[host_end] != '/' and url[host_end] != '?' and url[host_end] != '#') : (host_end += 1) {}
    if (host_end == host_start) return error.InvalidWebViewOptions;
    if (host_end > buffer.len) return error.InvalidWebViewOptions;
    @memcpy(buffer[0..host_end], url[0..host_end]);
    return buffer[0..host_end];
}

fn jsonNumberField(payload: []const u8, field: []const u8) ?f32 {
    return json.numberField(payload, field);
}

fn jsonIntegerField(payload: []const u8, field: []const u8) ?platform.WindowId {
    return json.unsignedField(platform.WindowId, payload, field);
}

fn jsonBoolField(payload: []const u8, field: []const u8) ?bool {
    return json.boolField(payload, field);
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

fn testViewByLabel(views: []const platform.ViewInfo, label: []const u8) ?platform.ViewInfo {
    for (views) |view| {
        if (std.mem.eql(u8, view.label, label)) return view;
    }
    return null;
}

test "runtime loads app source into platform webview" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "test", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expectEqual(platform.WebViewSourceKind.html, harness.null_platform.loaded_source.?.kind);
    try std.testing.expectEqualStrings("<h1>Hello</h1>", harness.null_platform.loaded_source.?.bytes);
    try std.testing.expectEqual(@as(u64, 1), harness.runtime.frameDiagnostics().frame_index);
}

test "runtime lets start hook create views before startup source loads" {
    const TestApp = struct {
        created_view: bool = false,
        source_loaded_after_start: bool = false,

        fn start(context: *anyopaque, runtime: *Runtime) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = try runtime.createView(.{
                .window_id = 1,
                .label = "startup-toolbar",
                .kind = .toolbar,
                .frame = geometry.RectF.init(0, 0, 640, 44),
                .role = "toolbar",
            });
            self.created_view = true;
        }

        fn source(context: *anyopaque) anyerror!platform.WebViewSource {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.source_loaded_after_start = self.created_view;
            return platform.WebViewSource.html("<h1>Native shell</h1>");
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "startup-native-shell",
                .source = platform.WebViewSource.html(""),
                .source_fn = source,
                .start_fn = start,
            };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expect(app_state.created_view);
    try std.testing.expect(app_state.source_loaded_after_start);
    try std.testing.expectEqualStrings("<h1>Native shell</h1>", harness.null_platform.loaded_source.?.bytes);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 2), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
    try std.testing.expectEqualStrings("startup-toolbar", views[1].label);
}

test "runtime exposes startup WebView and native views through generic view API" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "views", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const toolbar = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 44),
        .role = "toolbar",
        .accessibility_label = "Main toolbar",
        .text = "Tools",
        .command = "app.toolbar",
    });
    try std.testing.expectEqual(platform.ViewKind.toolbar, toolbar.kind);
    try std.testing.expect(toolbar.id > 0);
    try std.testing.expectEqualStrings("toolbar", toolbar.label);
    try std.testing.expectEqualStrings("Main toolbar", toolbar.accessibility_label);
    try std.testing.expectEqualStrings("Tools", toolbar.text);
    try std.testing.expectEqualStrings("app.toolbar", toolbar.command);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 2), views.len);
    try std.testing.expectEqual(platform.ViewKind.webview, views[0].kind);
    try std.testing.expect(views[0].id > 0);
    try std.testing.expectEqualStrings("main", views[0].label);
    try std.testing.expect(views[0].focused);
    try std.testing.expectEqual(platform.ViewKind.toolbar, views[1].kind);
    try std.testing.expectEqual(toolbar.id, views[1].id);
    try std.testing.expectEqualStrings("toolbar", views[1].label);
    try std.testing.expect(!views[1].focused);

    try harness.runtime.focusView(1, "toolbar");
    const focused_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(!focused_views[0].focused);
    try std.testing.expect(focused_views[1].focused);

    try harness.runtime.focusView(1, "main");
    const refocused_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(refocused_views[0].focused);
    try std.testing.expect(!refocused_views[1].focused);

    try harness.runtime.focusView(1, "toolbar");
    const updated = try harness.runtime.updateView(1, "toolbar", .{
        .frame = geometry.RectF.init(0, 0, 640, 52),
        .visible = false,
        .accessibility_label = "Primary actions toolbar",
        .text = "Actions",
        .command = "app.toolbar.updated",
    });
    try std.testing.expectEqual(@as(f32, 52), updated.frame.height);
    try std.testing.expectEqual(toolbar.id, updated.id);
    try std.testing.expect(!updated.visible);
    try std.testing.expect(!updated.focused);
    try std.testing.expectEqualStrings("Primary actions toolbar", updated.accessibility_label);
    try std.testing.expectEqualStrings("Actions", updated.text);
    try std.testing.expectEqualStrings("app.toolbar.updated", updated.command);

    const repaired_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(testViewByLabel(repaired_views, "main").?.focused);
    try std.testing.expect(!testViewByLabel(repaired_views, "toolbar").?.focused);

    try harness.runtime.closeView(1, "toolbar");
    const remaining = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("main", remaining[0].label);
    try std.testing.expect(remaining[0].focused);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "action",
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 96, 32),
    });
    try harness.runtime.focusView(1, "action");
    const disabled = try harness.runtime.updateView(1, "action", .{ .enabled = false });
    try std.testing.expect(!disabled.focused);
    var repaired_disabled_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expect(testViewByLabel(repaired_disabled_views, "main").?.focused);
    try std.testing.expect(!testViewByLabel(repaired_disabled_views, "action").?.focused);
    try harness.runtime.closeView(1, "action");

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "status",
        .kind = .statusbar,
        .frame = geometry.RectF.init(0, 320, 640, 32),
    });
    try harness.runtime.focusView(1, "status");
    try harness.runtime.closeView(1, "status");
    repaired_disabled_views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), repaired_disabled_views.len);
    try std.testing.expectEqualStrings("main", repaired_disabled_views[0].label);
    try std.testing.expect(repaired_disabled_views[0].focused);
}

test "runtime createView routes webview kind through WebView backend" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-view", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview-host",
        .kind = .stack,
        .frame = geometry.RectF.init(40, 50, 360, 280),
    });

    const preview = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview",
        .kind = .webview,
        .parent = "preview-host",
        .url = "zero://app/preview.html",
        .frame = geometry.RectF.init(10, 10, 320, 240),
        .layer = 5,
        .bridge_enabled = true,
    });
    try std.testing.expectEqual(platform.ViewKind.webview, preview.kind);
    try std.testing.expect(preview.id > 0);
    try std.testing.expectEqualStrings("preview-host", preview.parent.?);
    try std.testing.expectEqualStrings("zero://app/preview.html", preview.url);
    try std.testing.expect(preview.bridge_enabled);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.webview_count);
    try std.testing.expectEqual(@as(f32, 50), preview.frame.x);
    try std.testing.expectEqual(@as(f32, 60), preview.frame.y);
    try std.testing.expectEqual(@as(f32, 50), harness.null_platform.webviews[0].frame.x);
    try std.testing.expectEqual(@as(f32, 60), harness.null_platform.webviews[0].frame.y);

    const updated = try harness.runtime.updateView(1, "preview", .{
        .url = "zero://app/updated.html",
        .layer = 8,
    });
    try std.testing.expectEqualStrings("zero://app/updated.html", updated.url);
    try std.testing.expectEqual(preview.id, updated.id);
    try std.testing.expectEqual(@as(i32, 8), updated.layer);

    const moved_host = try harness.runtime.updateView(1, "preview-host", .{
        .frame = geometry.RectF.init(80, 90, 360, 280),
    });
    try std.testing.expectEqual(@as(f32, 80), moved_host.frame.x);
    try std.testing.expectEqual(@as(f32, 90), moved_host.frame.y);
    try std.testing.expectEqual(@as(f32, 90), harness.runtime.webviews[0].frame.x);
    try std.testing.expectEqual(@as(f32, 100), harness.runtime.webviews[0].frame.y);
    try std.testing.expectEqual(@as(f32, 90), harness.null_platform.webviews[0].frame.x);
    try std.testing.expectEqual(@as(f32, 100), harness.null_platform.webviews[0].frame.y);

    const moved_preview = try harness.runtime.updateView(1, "preview", .{
        .frame = geometry.RectF.init(20, 24, 320, 240),
    });
    try std.testing.expectEqual(@as(f32, 100), moved_preview.frame.x);
    try std.testing.expectEqual(@as(f32, 114), moved_preview.frame.y);
    try std.testing.expectEqual(@as(f32, 100), harness.null_platform.webviews[0].frame.x);
    try std.testing.expectEqual(@as(f32, 114), harness.null_platform.webviews[0].frame.y);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 3), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
    const listed_preview = testViewByLabel(views, "preview").?;
    try std.testing.expectEqual(preview.id, listed_preview.id);
    try std.testing.expectEqualStrings("preview-host", listed_preview.parent.?);

    try harness.runtime.focusView(1, "preview");
    try harness.runtime.closeView(1, "preview");
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.webview_count);
    const remaining = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 2), remaining.len);
    try std.testing.expectEqualStrings("main", remaining[0].label);
    try std.testing.expect(remaining[0].focused);
}

test "runtime rejects invalid native view parents" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "native-view-parents", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expectError(error.ViewNotFound, harness.runtime.createView(.{
        .window_id = 1,
        .label = "orphan",
        .kind = .button,
        .parent = "missing",
        .frame = geometry.RectF.init(0, 0, 96, 32),
    }));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.view_count);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 44),
    });

    try std.testing.expectError(error.InvalidViewOptions, harness.runtime.createView(.{
        .window_id = 1,
        .label = "self",
        .kind = .stack,
        .parent = "self",
        .frame = geometry.RectF.init(0, 0, 120, 80),
    }));
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.view_count);

    const action = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "action",
        .kind = .button,
        .parent = "toolbar",
        .frame = geometry.RectF.init(8, 8, 96, 32),
    });
    try std.testing.expectEqualStrings("toolbar", action.parent.?);
}

test "runtime closes native view descendants and logical WebView children with parent" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "parent-close", .source = platform.WebViewSource.html("<h1>Close</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "pane",
        .kind = .stack,
        .frame = geometry.RectF.init(0, 0, 640, 360),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "controls",
        .kind = .stack,
        .parent = "pane",
        .frame = geometry.RectF.init(8, 8, 220, 96),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "action",
        .kind = .button,
        .parent = "controls",
        .frame = geometry.RectF.init(8, 8, 96, 32),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview",
        .kind = .webview,
        .parent = "pane",
        .url = "zero://app/preview.html",
        .frame = geometry.RectF.init(240, 8, 320, 240),
    });
    try std.testing.expectEqual(@as(usize, 3), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.webview_count);

    try harness.runtime.focusView(1, "action");
    try harness.runtime.closeView(1, "pane");

    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.webview_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
    try std.testing.expect(views[0].focused);
}

test "runtime traverses focus across WebViews and native controls" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "focus-traversal", .source = platform.WebViewSource.html("<h1>Focus</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 44),
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "disabled-action",
        .kind = .button,
        .frame = geometry.RectF.init(8, 8, 120, 28),
        .enabled = false,
    });
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "preview",
        .kind = .webview,
        .url = "zero://app/preview.html",
        .frame = geometry.RectF.init(0, 44, 640, 360),
    });

    const first = try harness.runtime.focusNextView(1);
    try std.testing.expectEqualStrings("toolbar", first.label);
    try std.testing.expect(first.focused);

    const second = try harness.runtime.focusNextView(1);
    try std.testing.expectEqualStrings("preview", second.label);

    const wrapped = try harness.runtime.focusNextView(1);
    try std.testing.expectEqualStrings("main", wrapped.label);

    const previous = try harness.runtime.focusPreviousView(1);
    try std.testing.expectEqualStrings("preview", previous.label);

    var views_buffer: [5]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    for (views) |view| {
        if (std.mem.eql(u8, view.label, "preview")) {
            try std.testing.expect(view.focused);
        } else {
            try std.testing.expect(!view.focused);
        }
    }
}

test "runtime rejects reserved GPU surface view kind until a backend supports it" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-surface", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
    }));

    var views_buffer: [2]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
}

test "runtime retains canvas display lists on GPU surface views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    var text_storage = [_]u8{ 'O', 'K' };
    var stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(37, 99, 235) },
    };
    var glyphs = [_]canvas.Glyph{
        .{ .id = 42, .x = 12, .y = 24, .advance = 9 },
    };
    var path = [_]canvas.PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(1, 2), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    var commands: [4]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.fillRect(.{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 320, 240),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(320, 240),
            .stops = &stops,
        } },
    });
    try builder.fillPath(.{
        .id = 2,
        .elements = &path,
        .fill = .{ .color = canvas.Color.rgb8(15, 23, 42) },
    });
    try builder.drawText(.{
        .id = 3,
        .font_id = 7,
        .size = 16,
        .origin = geometry.PointF.init(16, 32),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = text_storage[0..],
        .glyphs = &glyphs,
    });

    const info = try harness.runtime.setCanvasDisplayList(1, "canvas", builder.displayList());
    try std.testing.expectEqual(@as(u64, 1), info.canvas_revision);
    try std.testing.expectEqual(@as(usize, 3), info.canvas_command_count);

    text_storage[0] = 'N';
    stops[0].offset = 0.5;
    glyphs[0].id = 900;
    path[0].points[0] = geometry.PointF.init(99, 99);

    const retained = try harness.runtime.canvasDisplayList(1, "canvas");
    try std.testing.expectEqual(@as(usize, 3), retained.commandCount());
    switch (retained.commands[0]) {
        .fill_rect => |value| switch (value.fill) {
            .linear_gradient => |gradient| {
                try std.testing.expectEqual(@as(f32, 0), gradient.stops[0].offset);
                try std.testing.expectEqual(@as(f32, 1), gradient.stops[0].color.r);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    switch (retained.commands[1]) {
        .fill_path => |value| try std.testing.expectEqual(@as(f32, 1), value.elements[0].points[0].x),
        else => return error.TestUnexpectedResult,
    }
    switch (retained.commands[2]) {
        .draw_text => |value| {
            try std.testing.expectEqualStrings("OK", value.text);
            try std.testing.expectEqual(@as(u32, 42), value.glyphs[0].id);
        },
        else => return error.TestUnexpectedResult,
    }

    const snapshot = harness.runtime.automationSnapshot("Canvas");
    const canvas_view = testViewByLabel(snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(u64, 1), canvas_view.canvas_revision);
    try std.testing.expectEqual(@as(usize, 3), canvas_view.canvas_command_count);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try automation.snapshot.writeText(snapshot, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_revision=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_commands=3") != null);
}

test "runtime validates canvas display list command limits" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-limits", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });

    var commands: [max_canvas_commands_per_view + 1]canvas.CanvasCommand = undefined;
    for (&commands) |*command| command.* = .pop_opacity;
    try std.testing.expectError(error.CanvasCommandLimitReached, harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands }));
}

test "runtime rejects canvas display lists on non-GPU views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "native-canvas-reject", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "status",
        .kind = .statusbar,
        .frame = geometry.RectF.init(0, 220, 320, 20),
    });

    try std.testing.expectError(error.InvalidViewOptions, harness.runtime.setCanvasDisplayList(1, "status", .{}));
}

test "runtime rejects oversized shell before creating partial views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-too-large", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    var labels: [platform.max_views + 1][16]u8 = undefined;
    var shell_views: [platform.max_views + 1]app_manifest.ShellView = undefined;
    for (&shell_views, 0..) |*view, index| {
        const label = try std.fmt.bufPrint(&labels[index], "button-{d}", .{index});
        view.* = .{
            .label = label,
            .kind = .button,
            .width = 80,
            .height = 24,
        };
    }

    try std.testing.expectError(error.ViewLimitReached, harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600)));

    var views_buffer: [2]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
}

test "runtime rolls back shell views when a later view fails" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-rollback", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 44 },
        .{ .label = "canvas", .kind = .gpu_surface, .width = 320, .height = 240 },
    };

    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600)));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.webview_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.shell_layout_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);

    var views_buffer: [2]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expectEqualStrings("main", views[0].label);
}

test "runtime restores main webview state when shell creation fails after main update" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "main-shell-rollback", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    harness.runtime.windows[0].main_parent = try copyInto(&harness.runtime.windows[0].main_parent_storage, "existing-parent");
    const previous_frame = harness.runtime.windows[0].main_frame;
    const previous_frame_set = harness.runtime.windows[0].main_frame_set;
    const previous_layer = harness.runtime.windows[0].main_layer;
    const previous_parent = harness.runtime.windows[0].main_parent.?;

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "main", .kind = .webview, .fill = true, .layer = 7 },
        .{ .label = "canvas", .kind = .gpu_surface, .width = 320, .height = 240 },
    };

    try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600)));
    try std.testing.expectEqual(previous_frame.x, harness.runtime.windows[0].main_frame.x);
    try std.testing.expectEqual(previous_frame.y, harness.runtime.windows[0].main_frame.y);
    try std.testing.expectEqual(previous_frame.width, harness.runtime.windows[0].main_frame.width);
    try std.testing.expectEqual(previous_frame.height, harness.runtime.windows[0].main_frame.height);
    try std.testing.expectEqual(previous_frame_set, harness.runtime.windows[0].main_frame_set);
    try std.testing.expectEqual(previous_layer, harness.runtime.windows[0].main_layer);
    try std.testing.expectEqualStrings(previous_parent, harness.runtime.windows[0].main_parent.?);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.shell_layout_count);
}

test "runtime materializes manifest shell windows into laid out views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-materialize", .source = platform.WebViewSource.html("<h1>Host</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "refresh-button", .kind = .button, .parent = "toolbar", .accessibility_label = "Refresh workspace", .text = "Refresh", .command = "app.refresh" },
        .{ .label = "toolbar-search", .kind = .search_field, .parent = "toolbar", .text = "Search" },
        .{ .label = "toolbar-progress", .kind = .progress_indicator, .parent = "toolbar", .role = "Syncing" },
        .{ .label = "toolbar-mode", .kind = .segmented_control, .parent = "toolbar", .text = "List|Grid", .command = "app.view.mode" },
        .{ .label = "toolbar-icon", .kind = .icon_button, .parent = "toolbar", .text = "R", .command = "app.refresh.icon" },
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 52, .role = "Toolbar" },
        .{ .label = "sidebar-live", .kind = .checkbox, .parent = "sidebar", .x = 18, .y = 92, .text = "Live" },
        .{ .label = "sidebar-mode", .kind = .toggle, .parent = "sidebar", .x = 18, .y = 128, .text = "Mode" },
        .{ .label = "sidebar-row", .kind = .list_item, .parent = "sidebar", .x = 18, .y = 170, .width = 180, .text = "Inbox", .command = "app.open.inbox" },
        .{ .label = "sidebar", .kind = .sidebar, .edge = .left, .width = 240, .role = "Sidebar" },
        .{ .label = "content", .kind = .webview, .url = "zero://app/content.html", .fill = true },
        .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = 28, .text = "Ready" },
    };
    const shell_window: app_manifest.ShellWindow = .{
        .label = "shell",
        .title = "Shell",
        .width = 1000,
        .height = 700,
        .restore_policy = .center_on_primary,
        .views = &shell_views,
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const window = try harness.runtime.createShellWindow(shell_window, platform.WebViewSource.html("<h1>Shell</h1>"));
    try std.testing.expectEqual(@as(platform.WindowId, 2), window.id);
    try std.testing.expectEqualStrings("shell", window.label);

    var views_buffer: [13]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(window.id, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const refresh = testViewByLabel(views, "refresh-button").?;
    const search = testViewByLabel(views, "toolbar-search").?;
    const progress = testViewByLabel(views, "toolbar-progress").?;
    const mode = testViewByLabel(views, "toolbar-mode").?;
    const icon = testViewByLabel(views, "toolbar-icon").?;
    const sidebar = testViewByLabel(views, "sidebar").?;
    const checkbox = testViewByLabel(views, "sidebar-live").?;
    const toggle = testViewByLabel(views, "sidebar-mode").?;
    const row = testViewByLabel(views, "sidebar-row").?;
    const content = testViewByLabel(views, "content").?;
    const statusbar = testViewByLabel(views, "statusbar").?;

    try std.testing.expectEqual(platform.ViewKind.toolbar, toolbar.kind);
    try std.testing.expectEqual(@as(f32, 0), toolbar.frame.x);
    try std.testing.expectEqual(@as(f32, 0), toolbar.frame.y);
    try std.testing.expectEqual(@as(f32, 1000), toolbar.frame.width);
    try std.testing.expectEqual(@as(f32, 52), toolbar.frame.height);

    try std.testing.expectEqual(platform.ViewKind.button, refresh.kind);
    try std.testing.expectEqualStrings("toolbar", refresh.parent.?);
    try std.testing.expectEqualStrings("Refresh workspace", refresh.accessibility_label);
    try std.testing.expectEqualStrings("Refresh", refresh.text);
    try std.testing.expectEqualStrings("app.refresh", refresh.command);
    try std.testing.expectEqual(@as(f32, 8), refresh.frame.x);
    try std.testing.expectEqual(@as(f32, 10), refresh.frame.y);
    try std.testing.expectEqual(@as(f32, 96), refresh.frame.width);
    try std.testing.expectEqual(@as(f32, 32), refresh.frame.height);

    try std.testing.expectEqual(platform.ViewKind.search_field, search.kind);
    try std.testing.expectEqualStrings("toolbar", search.parent.?);
    try std.testing.expectEqualStrings("Search", search.text);
    try std.testing.expectEqual(@as(f32, 112), search.frame.x);
    try std.testing.expectEqual(@as(f32, 12), search.frame.y);
    try std.testing.expectEqual(@as(f32, 220), search.frame.width);
    try std.testing.expectEqual(@as(f32, 28), search.frame.height);

    try std.testing.expectEqual(platform.ViewKind.progress_indicator, progress.kind);
    try std.testing.expectEqualStrings("toolbar", progress.parent.?);
    try std.testing.expectEqualStrings("Syncing", progress.role);
    try std.testing.expectEqual(@as(f32, 340), progress.frame.x);
    try std.testing.expectEqual(@as(f32, 14), progress.frame.y);
    try std.testing.expectEqual(@as(f32, 24), progress.frame.width);
    try std.testing.expectEqual(@as(f32, 24), progress.frame.height);

    try std.testing.expectEqual(platform.ViewKind.segmented_control, mode.kind);
    try std.testing.expectEqualStrings("toolbar", mode.parent.?);
    try std.testing.expectEqualStrings("List|Grid", mode.text);
    try std.testing.expectEqualStrings("app.view.mode", mode.command);
    try std.testing.expectEqual(@as(f32, 372), mode.frame.x);
    try std.testing.expectEqual(@as(f32, 10), mode.frame.y);
    try std.testing.expectEqual(@as(f32, 168), mode.frame.width);
    try std.testing.expectEqual(@as(f32, 32), mode.frame.height);

    try std.testing.expectEqual(platform.ViewKind.icon_button, icon.kind);
    try std.testing.expectEqualStrings("toolbar", icon.parent.?);
    try std.testing.expectEqualStrings("R", icon.text);
    try std.testing.expectEqualStrings("app.refresh.icon", icon.command);
    try std.testing.expectEqual(@as(f32, 548), icon.frame.x);
    try std.testing.expectEqual(@as(f32, 10), icon.frame.y);
    try std.testing.expectEqual(@as(f32, 32), icon.frame.width);
    try std.testing.expectEqual(@as(f32, 32), icon.frame.height);

    try std.testing.expectEqual(platform.ViewKind.sidebar, sidebar.kind);
    try std.testing.expectEqual(@as(f32, 0), sidebar.frame.x);
    try std.testing.expectEqual(@as(f32, 52), sidebar.frame.y);
    try std.testing.expectEqual(@as(f32, 240), sidebar.frame.width);
    try std.testing.expectEqual(@as(f32, 648), sidebar.frame.height);

    try std.testing.expectEqual(platform.ViewKind.checkbox, checkbox.kind);
    try std.testing.expectEqualStrings("Live", checkbox.text);
    try std.testing.expectEqual(@as(f32, 18), checkbox.frame.x);
    try std.testing.expectEqual(@as(f32, 92), checkbox.frame.y);
    try std.testing.expectEqual(@as(f32, 96), checkbox.frame.width);
    try std.testing.expectEqual(@as(f32, 32), checkbox.frame.height);

    try std.testing.expectEqual(platform.ViewKind.toggle, toggle.kind);
    try std.testing.expectEqualStrings("Mode", toggle.text);
    try std.testing.expectEqual(@as(f32, 18), toggle.frame.x);
    try std.testing.expectEqual(@as(f32, 128), toggle.frame.y);
    try std.testing.expectEqual(@as(f32, 96), toggle.frame.width);
    try std.testing.expectEqual(@as(f32, 32), toggle.frame.height);

    try std.testing.expectEqual(platform.ViewKind.list_item, row.kind);
    try std.testing.expectEqualStrings("Inbox", row.text);
    try std.testing.expectEqualStrings("app.open.inbox", row.command);
    try std.testing.expectEqual(@as(f32, 18), row.frame.x);
    try std.testing.expectEqual(@as(f32, 170), row.frame.y);
    try std.testing.expectEqual(@as(f32, 180), row.frame.width);
    try std.testing.expectEqual(@as(f32, 32), row.frame.height);

    try std.testing.expectEqual(platform.ViewKind.statusbar, statusbar.kind);
    try std.testing.expectEqualStrings("Ready", statusbar.text);
    try std.testing.expectEqual(@as(f32, 240), statusbar.frame.x);
    try std.testing.expectEqual(@as(f32, 672), statusbar.frame.y);
    try std.testing.expectEqual(@as(f32, 760), statusbar.frame.width);
    try std.testing.expectEqual(@as(f32, 28), statusbar.frame.height);

    try std.testing.expectEqual(platform.ViewKind.webview, content.kind);
    try std.testing.expect(content.bridge_enabled);
    try std.testing.expectEqualStrings("zero://app/content.html", content.url);
    try std.testing.expectEqual(@as(f32, 240), content.frame.x);
    try std.testing.expectEqual(@as(f32, 52), content.frame.y);
    try std.testing.expectEqual(@as(f32, 760), content.frame.width);
    try std.testing.expectEqual(@as(f32, 620), content.frame.height);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .surface_resized = .{
        .id = window.id,
        .size = geometry.SizeF.init(1200, 800),
        .scale_factor = 1,
    } });

    const resized_views = harness.runtime.listViews(window.id, &views_buffer);
    const resized_toolbar = testViewByLabel(resized_views, "toolbar").?;
    const resized_sidebar = testViewByLabel(resized_views, "sidebar").?;
    const resized_content = testViewByLabel(resized_views, "content").?;
    const resized_statusbar = testViewByLabel(resized_views, "statusbar").?;

    try std.testing.expectEqual(@as(f32, 1200), resized_toolbar.frame.width);
    try std.testing.expectEqual(@as(f32, 748), resized_sidebar.frame.height);
    try std.testing.expectEqual(@as(f32, 960), resized_content.frame.width);
    try std.testing.expectEqual(@as(f32, 720), resized_content.frame.height);
    try std.testing.expectEqual(@as(f32, 772), resized_statusbar.frame.y);
}

test "runtime lays out created shell windows with native returned bounds" {
    const ShellCreatePlatform = struct {
        create_count: usize = 0,
        load_count: usize = 0,
        views: [4]platform.ViewOptions = undefined,
        view_count: usize = 0,

        fn platformValue(self: *@This()) platform.Platform {
            return .{
                .context = self,
                .name = "shell-create",
                .surface_value = .{ .id = 1, .size = geometry.SizeF.init(640, 480), .scale_factor = 1 },
                .run_fn = run,
                .services = .{
                    .context = self,
                    .create_window_fn = createWindow,
                    .load_window_webview_fn = loadWindowWebView,
                    .create_view_fn = createView,
                },
            };
        }

        fn run(context: *anyopaque, handler: platform.EventHandler, handler_context: *anyopaque) anyerror!void {
            _ = context;
            _ = handler;
            _ = handler_context;
        }

        fn createWindow(context: ?*anyopaque, options: platform.WindowOptions) anyerror!platform.WindowInfo {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.create_count += 1;
            return .{
                .id = options.id,
                .label = options.label,
                .title = options.resolvedTitle("shell-create"),
                .frame = geometry.RectF.init(20, 30, 1200, 800),
                .scale_factor = 2,
                .open = true,
                .focused = false,
            };
        }

        fn loadWindowWebView(context: ?*anyopaque, window_id: platform.WindowId, source: platform.WebViewSource) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = window_id;
            _ = source;
            self.load_count += 1;
        }

        fn createView(context: ?*anyopaque, options: platform.ViewOptions) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.views[self.view_count] = options;
            self.view_count += 1;
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 50 },
        .{ .label = "content", .kind = .webview, .url = "zero://app/content.html", .fill = true },
        .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = 40 },
    };
    const shell_window: app_manifest.ShellWindow = .{
        .label = "restored",
        .title = "Restored",
        .width = 900,
        .height = 600,
        .views = &shell_views,
    };

    var host: ShellCreatePlatform = .{};
    var runtime = Runtime.init(.{ .platform = host.platformValue() });
    const window = try runtime.createShellWindow(shell_window, platform.WebViewSource.html("<h1>Restored</h1>"));

    try std.testing.expectEqual(@as(usize, 1), host.create_count);
    try std.testing.expectEqual(@as(usize, 1), host.load_count);
    try std.testing.expectEqual(@as(f32, 1200), window.frame.width);
    try std.testing.expectEqual(@as(f32, 800), window.frame.height);
    try std.testing.expectEqual(@as(usize, 3), host.view_count);
    try std.testing.expectEqualStrings("toolbar", host.views[0].label);
    try std.testing.expectEqual(@as(f32, 1200), host.views[0].frame.width);
    try std.testing.expectEqualStrings("content", host.views[1].label);
    try std.testing.expectEqual(platform.ViewKind.webview, host.views[1].kind);
    try std.testing.expectEqual(@as(f32, 50), host.views[1].frame.y);
    try std.testing.expectEqual(@as(f32, 1200), host.views[1].frame.width);
    try std.testing.expectEqual(@as(f32, 710), host.views[1].frame.height);
    try std.testing.expectEqualStrings("statusbar", host.views[2].label);
    try std.testing.expectEqual(@as(f32, 760), host.views[2].frame.y);
    try std.testing.expectEqual(@as(f32, 1200), host.views[2].frame.width);
}

test "runtime lays out startup shell windows with native configured bounds" {
    const TestApp = struct {
        const scene_views = [_]app_manifest.ShellView{
            .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 50 },
            .{ .label = "main", .kind = .webview, .url = "zero://app/main.html", .fill = true },
            .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = 40 },
        };
        const scene_windows = [_]app_manifest.ShellWindow{.{
            .label = "main",
            .title = "Startup",
            .width = 900,
            .height = 600,
            .views = &scene_views,
        }};

        fn scene(context: *anyopaque) anyerror!app_manifest.ShellConfig {
            _ = context;
            return .{ .windows = &scene_windows };
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "startup-native-bounds",
                .source = platform.WebViewSource.html("<h1>Startup</h1>"),
                .scene_fn = scene,
            };
        }
    };

    var null_platform = platform.NullPlatform.initWithOptions(
        .{ .id = 1, .size = geometry.SizeF.init(640, 480), .scale_factor = 1 },
        .system,
        .{
            .app_name = "Startup",
            .main_window = .{
                .label = "main",
                .title = "Startup",
                .default_frame = geometry.RectF.init(32, 44, 1200, 800),
            },
        },
    );
    var runtime = Runtime.init(.{ .platform = null_platform.platform() });
    var app_state: TestApp = .{};

    try runtime.dispatchPlatformEvent(app_state.app(), .app_start);

    var windows_buffer: [1]platform.WindowInfo = undefined;
    const windows = runtime.listWindows(&windows_buffer);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqual(@as(f32, 32), windows[0].frame.x);
    try std.testing.expectEqual(@as(f32, 44), windows[0].frame.y);
    try std.testing.expectEqual(@as(f32, 1200), windows[0].frame.width);
    try std.testing.expectEqual(@as(f32, 800), windows[0].frame.height);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = runtime.listViews(1, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const main = testViewByLabel(views, "main").?;
    const statusbar = testViewByLabel(views, "statusbar").?;

    try std.testing.expectEqual(@as(f32, 1200), toolbar.frame.width);
    try std.testing.expectEqual(@as(f32, 50), main.frame.y);
    try std.testing.expectEqual(@as(f32, 1200), main.frame.width);
    try std.testing.expectEqual(@as(f32, 710), main.frame.height);
    try std.testing.expectEqual(@as(f32, 760), statusbar.frame.y);
    try std.testing.expectEqual(@as(f32, 1200), statusbar.frame.width);
}

test "runtime relayouts shell views attached to startup window" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "startup-shell-layout", .source = platform.WebViewSource.html("<h1>Startup</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 50 },
        .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
        .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = 30 },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    var views_buffer: [4]platform.ViewInfo = undefined;
    var views = harness.runtime.listViews(1, &views_buffer);
    var main = testViewByLabel(views, "main").?;
    try std.testing.expectEqual(@as(f32, 0), main.frame.x);
    try std.testing.expectEqual(@as(f32, 50), main.frame.y);
    try std.testing.expectEqual(@as(f32, 800), main.frame.width);
    try std.testing.expectEqual(@as(f32, 520), main.frame.height);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .surface_resized = .{
        .id = 1,
        .size = geometry.SizeF.init(900, 500),
        .scale_factor = 1,
    } });

    views = harness.runtime.listViews(1, &views_buffer);
    main = testViewByLabel(views, "main").?;
    const toolbar = testViewByLabel(views, "toolbar").?;
    const statusbar = testViewByLabel(views, "statusbar").?;
    try std.testing.expectEqual(@as(f32, 900), toolbar.frame.width);
    try std.testing.expectEqual(@as(f32, 470), statusbar.frame.y);
    try std.testing.expectEqual(@as(f32, 900), main.frame.width);
    try std.testing.expectEqual(@as(f32, 420), main.frame.height);
}

test "runtime relayout uses owned shell view storage" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "owned-shell-layout", .source = platform.WebViewSource.html("<h1>Owned</h1>") };
        }
    };

    var shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 50 },
        .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    shell_views[0].height = 200;

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .surface_resized = .{
        .id = 1,
        .size = geometry.SizeF.init(900, 500),
        .scale_factor = 1,
    } });

    var views_buffer: [3]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const main = testViewByLabel(views, "main").?;
    try std.testing.expectEqual(@as(f32, 50), toolbar.frame.height);
    try std.testing.expectEqual(@as(f32, 50), main.frame.y);
    try std.testing.expectEqual(@as(f32, 450), main.frame.height);
}

test "runtime clamps shell view layout constraints" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-constraints", .source = platform.WebViewSource.html("<h1>Constraints</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar-button", .kind = .button, .parent = "toolbar", .width = 12, .height = 80, .min_width = 32, .max_height = 30, .text = "Go" },
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 20, .min_height = 44 },
        .{ .label = "sidebar", .kind = .sidebar, .edge = .left, .width = 500, .max_width = 280 },
        .{ .label = "content", .kind = .webview, .url = "zero://inline", .fill = true, .max_width = 480, .max_height = 360 },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    var views_buffer: [5]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const button = testViewByLabel(views, "toolbar-button").?;
    const sidebar = testViewByLabel(views, "sidebar").?;
    const content = testViewByLabel(views, "content").?;

    try std.testing.expectEqual(@as(f32, 44), toolbar.frame.height);
    try std.testing.expectEqual(@as(f32, 32), button.frame.width);
    try std.testing.expectEqual(@as(f32, 30), button.frame.height);
    try std.testing.expectEqual(@as(f32, 7), button.frame.y);
    try std.testing.expectEqual(@as(f32, 280), sidebar.frame.width);
    try std.testing.expectEqual(@as(f32, 44), sidebar.frame.y);
    try std.testing.expectEqual(@as(f32, 556), sidebar.frame.height);
    try std.testing.expectEqual(@as(f32, 280), content.frame.x);
    try std.testing.expectEqual(@as(f32, 44), content.frame.y);
    try std.testing.expectEqual(@as(f32, 480), content.frame.width);
    try std.testing.expectEqual(@as(f32, 360), content.frame.height);
}

test "runtime lays out stack children by column axis" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-stack-axis", .source = platform.WebViewSource.html("<h1>Stack</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "sidebar", .kind = .sidebar, .edge = .left, .width = 240 },
        .{ .label = "filters", .kind = .stack, .parent = "sidebar", .x = 18, .y = 24, .width = 180, .height = 140, .axis = .column },
        .{ .label = "filter-title", .kind = .label, .parent = "filters", .text = "Filters" },
        .{ .label = "filter-live", .kind = .checkbox, .parent = "filters", .text = "Live" },
        .{ .label = "filter-mode", .kind = .toggle, .parent = "filters", .text = "Focus" },
        .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    var views_buffer: [8]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const stack = testViewByLabel(views, "filters").?;
    const title = testViewByLabel(views, "filter-title").?;
    const live = testViewByLabel(views, "filter-live").?;
    const mode = testViewByLabel(views, "filter-mode").?;

    try std.testing.expectEqual(platform.ViewKind.stack, stack.kind);
    try std.testing.expectEqualStrings("filters", title.parent.?);
    try std.testing.expectEqual(@as(f32, 8), title.frame.x);
    try std.testing.expectEqual(@as(f32, 8), title.frame.y);
    try std.testing.expectEqual(@as(f32, 8), live.frame.x);
    try std.testing.expectEqual(@as(f32, 40), live.frame.y);
    try std.testing.expectEqual(@as(f32, 8), mode.frame.x);
    try std.testing.expectEqual(@as(f32, 80), mode.frame.y);
}

test "runtime lays out split panes and parented webview frames" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shell-split", .source = platform.WebViewSource.html("<h1>Split</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 44 },
        .{ .label = "body", .kind = .split, .fill = true, .axis = .row },
        .{ .label = "navigator", .kind = .sidebar, .parent = "body", .width = 220 },
        .{ .label = "main", .kind = .webview, .parent = "body", .url = "zero://inline", .fill = true },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));

    var views_buffer: [6]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const body = testViewByLabel(views, "body").?;
    const navigator = testViewByLabel(views, "navigator").?;
    const main = testViewByLabel(views, "main").?;

    try std.testing.expectEqual(platform.ViewKind.split, body.kind);
    try std.testing.expectEqual(@as(f32, 0), body.frame.x);
    try std.testing.expectEqual(@as(f32, 44), body.frame.y);
    try std.testing.expectEqual(@as(f32, 800), body.frame.width);
    try std.testing.expectEqual(@as(f32, 556), body.frame.height);
    try std.testing.expectEqualStrings("body", navigator.parent.?);
    try std.testing.expectEqual(@as(f32, 0), navigator.frame.x);
    try std.testing.expectEqual(@as(f32, 0), navigator.frame.y);
    try std.testing.expectEqual(@as(f32, 220), navigator.frame.width);
    try std.testing.expectEqual(@as(f32, 556), navigator.frame.height);
    try std.testing.expectEqualStrings("body", main.parent.?);
    try std.testing.expectEqual(@as(f32, 220), main.frame.x);
    try std.testing.expectEqual(@as(f32, 44), main.frame.y);
    try std.testing.expectEqual(@as(f32, 580), main.frame.width);
    try std.testing.expectEqual(@as(f32, 556), main.frame.height);
}

test "runtime platform window close clears shell views and child WebViews" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "platform-close", .source = platform.WebViewSource.html("<h1>Close</h1>") };
        }
    };

    const shell_views = [_]app_manifest.ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 44 },
        .{ .label = "content", .kind = .webview, .url = "zero://inline", .fill = true },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(800, 600) });
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.createShellViews(1, &shell_views, geometry.RectF.init(0, 0, 800, 600));
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.shell_layout_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.webview_count);

    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
        .id = 1,
        .label = "main",
        .title = "Main",
        .frame = geometry.RectF.init(0, 0, 800, 600),
        .scale_factor = 1,
        .open = false,
        .focused = false,
    } });

    try std.testing.expectEqual(@as(usize, 0), harness.runtime.shell_layout_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.webview_count);
    try std.testing.expect(harness.runtime.windows[0].main_parent == null);

    var views_buffer: [4]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    try std.testing.expectEqual(@as(usize, 0), views.len);
}

test "runtime loads scene hook as native shell startup" {
    const TestApp = struct {
        const scene_views = [_]app_manifest.ShellView{
            .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 48, .role = "Toolbar" },
            .{ .label = "refresh", .kind = .button, .parent = "toolbar", .text = "Refresh", .command = "app.refresh" },
            .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
            .{ .label = "status", .kind = .statusbar, .edge = .bottom, .height = 28, .text = "Ready" },
        };
        const scene_windows = [_]app_manifest.ShellWindow{.{
            .label = "workspace",
            .title = "Scene Shell",
            .width = 900,
            .height = 600,
            .views = &scene_views,
        }};

        scene_called: bool = false,
        source_called_after_scene: bool = false,

        fn scene(context: *anyopaque) anyerror!app_manifest.ShellConfig {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.scene_called = true;
            return .{ .windows = &scene_windows };
        }

        fn source(context: *anyopaque) anyerror!platform.WebViewSource {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.source_called_after_scene = self.scene_called;
            return platform.WebViewSource.html("<h1>Scene content</h1>");
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "scene-shell",
                .source_fn = source,
                .scene_fn = scene,
            };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{ .id = 1, .size = geometry.SizeF.init(900, 600) });
    const state_store = window_state.Store.init(std.testing.io, ".zig-cache/test-runtime-scene-window-state", ".zig-cache/test-runtime-scene-window-state/windows.zon");
    harness.runtime.options.window_state_store = state_store;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expect(app_state.scene_called);
    try std.testing.expect(app_state.source_called_after_scene);
    try std.testing.expectEqualStrings("<h1>Scene content</h1>", harness.null_platform.loaded_source.?.bytes);

    var windows_buffer: [2]platform.WindowInfo = undefined;
    const windows = harness.runtime.listWindows(&windows_buffer);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings("workspace", windows[0].label);
    try std.testing.expectEqualStrings("Scene Shell", windows[0].title);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .window_frame_changed = .{
        .id = 1,
        .label = "main",
        .title = "Native Startup",
        .frame = geometry.RectF.init(0, 0, 900, 600),
        .scale_factor = 1,
        .open = true,
        .focused = true,
    } });

    const updated_windows = harness.runtime.listWindows(&windows_buffer);
    try std.testing.expectEqual(@as(usize, 1), updated_windows.len);
    try std.testing.expectEqualStrings("workspace", updated_windows[0].label);
    try std.testing.expectEqualStrings("Scene Shell", updated_windows[0].title);
    var state_buffer: [window_state.max_serialized_bytes]u8 = undefined;
    const persisted = (try state_store.loadWindow("workspace", &state_buffer)).?;
    try std.testing.expectEqualStrings("workspace", persisted.label);
    try std.testing.expectEqualStrings("Scene Shell", persisted.title);

    var views_buffer: [8]platform.ViewInfo = undefined;
    const views = harness.runtime.listViews(1, &views_buffer);
    const toolbar = testViewByLabel(views, "toolbar").?;
    const refresh = testViewByLabel(views, "refresh").?;
    const main = testViewByLabel(views, "main").?;
    const status = testViewByLabel(views, "status").?;

    try std.testing.expectEqual(platform.ViewKind.toolbar, toolbar.kind);
    try std.testing.expectEqualStrings("Toolbar", toolbar.role);
    try std.testing.expectEqual(platform.ViewKind.button, refresh.kind);
    try std.testing.expectEqualStrings("app.refresh", refresh.command);
    try std.testing.expectEqual(platform.ViewKind.webview, main.kind);
    try std.testing.expectEqual(@as(f32, 48), main.frame.y);
    try std.testing.expectEqual(@as(f32, 524), main.frame.height);
    try std.testing.expectEqual(platform.ViewKind.statusbar, status.kind);
    try std.testing.expectEqualStrings("Ready", status.text);
}

test "runtime automation snapshot includes generic views" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "snapshot-views", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "status",
        .kind = .statusbar,
        .frame = geometry.RectF.init(0, 440, 640, 40),
        .role = "status",
        .text = "Ready",
    });
    try harness.runtime.focusView(1, "status");

    const snapshot = harness.runtime.automationSnapshot("Snapshot");
    try std.testing.expect(snapshot.views.len >= 2);
    try std.testing.expectEqualStrings("main", snapshot.views[0].label);
    try std.testing.expectEqual(platform.ViewKind.webview, snapshot.views[0].kind);
    try std.testing.expect(!snapshot.views[0].focused);
    try std.testing.expectEqualStrings("status", snapshot.views[1].label);
    try std.testing.expectEqual(platform.ViewKind.statusbar, snapshot.views[1].kind);
    try std.testing.expectEqualStrings("Ready", snapshot.views[1].text);
    try std.testing.expect(snapshot.views[1].focused);
}

test "runtime configures platform keyboard shortcuts" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shortcuts", .source = platform.WebViewSource.html("<h1>Shortcuts</h1>") };
        }
    };

    const shortcuts = [_]platform.Shortcut{
        .{ .id = "command.palette", .key = "p", .modifiers = .{ .primary = true, .shift = true } },
    };
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.shortcuts = &shortcuts;
    var app_state: TestApp = .{};
    try harness.runtime.run(app_state.app());

    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.configuredShortcuts().len);
    try std.testing.expectEqualStrings("command.palette", harness.null_platform.configuredShortcuts()[0].id);
}

test "runtime dispatches app activation lifecycle events" {
    const TestApp = struct {
        events: [4]LifecycleEvent = undefined,
        len: usize = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "activation", .source = platform.WebViewSource.html("<h1>Activation</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .lifecycle => |lifecycle| {
                    self.events[self.len] = lifecycle;
                    self.len += 1;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    const event_count_before = harness.null_platform.windowEventCount();
    try harness.runtime.dispatchPlatformEvent(app, .app_activated);
    try std.testing.expectEqual(event_count_before + 1, harness.null_platform.windowEventCount());
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.lastWindowEventWindowId());
    try std.testing.expectEqualStrings("app:activate", harness.null_platform.lastWindowEventName());
    try std.testing.expectEqualStrings("{}", harness.null_platform.lastWindowEventDetail());
    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expectEqual(event_count_before + 2, harness.null_platform.windowEventCount());
    try std.testing.expectEqualStrings("app:deactivate", harness.null_platform.lastWindowEventName());

    try std.testing.expectEqual(@as(usize, 4), app_state.len);
    try std.testing.expectEqual(LifecycleEvent.start, app_state.events[0]);
    try std.testing.expectEqual(LifecycleEvent.frame, app_state.events[1]);
    try std.testing.expectEqual(LifecycleEvent.activate, app_state.events[2]);
    try std.testing.expectEqual(LifecycleEvent.deactivate, app_state.events[3]);
}

test "runtime dispatches GPU surface events" {
    const TestApp = struct {
        frame_count: u32 = 0,
        resize_count: u32 = 0,
        input_count: u32 = 0,
        last_label: []const u8 = "",
        last_input_kind: platform.GpuSurfaceInputKind = .pointer_move,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-events", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .gpu_surface_frame => |frame_event| {
                    self.frame_count += 1;
                    self.last_label = frame_event.label;
                },
                .gpu_surface_resized => |resize_event| {
                    self.resize_count += 1;
                    self.last_label = resize_event.label;
                },
                .gpu_surface_input => |input_event| {
                    self.input_count += 1;
                    self.last_label = input_event.label;
                    self.last_input_kind = input_event.kind;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(640, 360),
        .scale_factor = 2,
        .frame_index = 7,
        .timestamp_ns = 42,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.frame_count);
    try std.testing.expectEqualStrings("canvas", app_state.last_label);
    try std.testing.expect(!harness.runtime.invalidated);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "canvas",
        .frame = geometry.RectF.init(0, 0, 800, 450),
        .scale_factor = 2,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.resize_count);
    try std.testing.expect(harness.runtime.invalidated);

    harness.runtime.invalidated = false;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = 12,
        .y = 18,
        .button = 0,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_down, app_state.last_input_kind);
    try std.testing.expect(harness.runtime.invalidated);
}

test "runtime dispatches shortcut command events" {
    const TestApp = struct {
        command_count: u32 = 0,
        shortcut_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "shortcut-command", .source = platform.WebViewSource.html("<h1>Shortcuts</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_name = command.name;
                    self.last_source = command.source;
                    self.last_window_id = command.window_id;
                },
                .shortcut => {
                    self.shortcut_count += 1;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .shortcut = .{
        .id = "app.refresh",
        .key = "r",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqual(@as(u32, 1), app_state.shortcut_count);
    try std.testing.expectEqualStrings("app.refresh", app_state.last_name);
    try std.testing.expectEqual(CommandSource.shortcut, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
}

test "runtime configures platform menus" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "menus", .source = platform.WebViewSource.html("<h1>Menus</h1>") };
        }
    };

    const items = [_]platform.MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
    };
    const menus = [_]platform.Menu{.{ .title = "View", .items = &items }};
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.menus = &menus;
    var app_state: TestApp = .{};
    try harness.runtime.run(app_state.app());

    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.configuredMenus().len);
    try std.testing.expectEqualStrings("View", harness.null_platform.configuredMenus()[0].title);
    try std.testing.expectEqualStrings("app.refresh", harness.null_platform.configuredMenus()[0].items[0].command);
}

test "runtime rejects invalid platform menu shortcuts" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "invalid-menus", .source = platform.WebViewSource.html("<h1>Menus</h1>") };
        }
    };

    const items = [_]platform.MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r" },
    };
    const menus = [_]platform.Menu{.{ .title = "View", .items = &items }};
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.menus = &menus;
    var app_state: TestApp = .{};

    try std.testing.expectError(error.InvalidShortcut, harness.runtime.run(app_state.app()));
}

test "runtime rejects invalid keyboard shortcuts" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "invalid-shortcuts", .source = platform.WebViewSource.html("<h1>Shortcuts</h1>") };
        }
    };

    const long_id = [_]u8{'x'} ** (platform.max_shortcut_id_bytes + 1);
    const shortcuts = [_]platform.Shortcut{.{ .id = long_id[0..], .key = "p" }};
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.shortcuts = &shortcuts;
    var app_state: TestApp = .{};

    try std.testing.expectError(error.InvalidShortcut, harness.runtime.run(app_state.app()));
}

test "runtime rejects invalid command catalog" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "invalid-commands", .source = platform.WebViewSource.html("<h1>Commands</h1>") };
        }
    };

    const commands = [_]Command{
        .{ .id = "app.refresh", .title = "Refresh" },
        .{ .id = "app.refresh", .title = "Duplicate Refresh" },
    };
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.commands = &commands;
    var app_state: TestApp = .{};

    try std.testing.expectError(error.DuplicateCommand, harness.runtime.run(app_state.app()));
}

test "runtime rejects oversized webview source" {
    const TestApp = struct {
        bytes: [platform.max_window_source_bytes + 1]u8 = [_]u8{'x'} ** (platform.max_window_source_bytes + 1),

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "oversized-source", .source = platform.WebViewSource.html(&self.bytes) };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};

    try std.testing.expectError(error.WindowSourceTooLarge, harness.start(app_state.app()));
}

test "runtime refreshes app source and keeps reload fields owned" {
    const TestApp = struct {
        root_path: [8]u8 = "dist-one".*,
        entry: [10]u8 = "index.html".*,
        origin: [13]u8 = "zero://assets".*,

        fn source(context: *anyopaque) anyerror!platform.WebViewSource {
            const self: *@This() = @ptrCast(@alignCast(context));
            return platform.WebViewSource.assets(.{
                .root_path = self.root_path[0..],
                .entry = self.entry[0..],
                .origin = self.origin[0..],
                .spa_fallback = false,
            });
        }

        fn app(self: *@This()) App {
            return .{
                .context = self,
                .name = "asset-source",
                .source_fn = source,
            };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    const secondary = try harness.runtime.createWindow(.{
        .label = "external",
        .title = "External",
        .source = platform.WebViewSource.url("https://example.test"),
    });

    @memcpy(app_state.root_path[0..], "dist-two");
    @memcpy(app_state.entry[0..], "other.html");
    @memcpy(app_state.origin[0..], "zero://mutant");
    try harness.runtime.reloadWindows(app_state.app());

    @memcpy(app_state.root_path[0..], "dist-bad");
    @memcpy(app_state.entry[0..], "mutant.htm");
    @memcpy(app_state.origin[0..], "zero://future");

    const loaded = harness.null_platform.window_sources[0].?;
    try std.testing.expectEqual(platform.WebViewSourceKind.assets, loaded.kind);
    try std.testing.expectEqualStrings("zero://mutant", loaded.bytes);
    const assets = loaded.asset_options.?;
    try std.testing.expectEqualStrings("dist-two", assets.root_path);
    try std.testing.expectEqualStrings("other.html", assets.entry);
    try std.testing.expectEqualStrings("zero://mutant", assets.origin);
    try std.testing.expect(!assets.spa_fallback);

    const secondary_source = harness.null_platform.window_sources[@intCast(secondary.id - 1)].?;
    try std.testing.expectEqual(platform.WebViewSourceKind.url, secondary_source.kind);
    try std.testing.expectEqualStrings("https://example.test", secondary_source.bytes);
}

test "extension registry receives runtime lifecycle and command hooks" {
    const ModuleState = struct {
        started: bool = false,
        stopped: bool = false,
        commands: u32 = 0,

        fn start(context: *anyopaque, runtime_context: extensions.RuntimeContext) anyerror!void {
            try std.testing.expectEqualStrings("null", runtime_context.platform_name);
            const self: *@This() = @ptrCast(@alignCast(context));
            self.started = true;
        }

        fn stop(context: *anyopaque, runtime_context: extensions.RuntimeContext) anyerror!void {
            _ = runtime_context;
            const self: *@This() = @ptrCast(@alignCast(context));
            self.stopped = true;
        }

        fn command(context: *anyopaque, runtime_context: extensions.RuntimeContext, command_value: extensions.Command) anyerror!void {
            _ = runtime_context;
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, command_value.name, "native.ping")) self.commands += 1;
        }
    };

    var module_state: ModuleState = .{};
    const modules = [_]extensions.Module{.{
        .info = .{ .id = 1, .name = "native-test", .capabilities = &.{.{ .kind = .native_module }} },
        .context = &module_state,
        .hooks = .{ .start_fn = ModuleState.start, .stop_fn = ModuleState.stop, .command_fn = ModuleState.command },
    }};

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.extensions = .{ .modules = &modules };

    const app = App{ .context = &module_state, .name = "extensions", .source = platform.WebViewSource.html("<p>Extensions</p>") };
    try harness.start(app);
    try harness.runtime.dispatchEvent(app, .{ .command = .{ .name = "native.ping" } });
    try harness.stop(app);

    try std.testing.expect(module_state.started);
    try std.testing.expect(module_state.stopped);
    try std.testing.expectEqual(@as(u32, 1), module_state.commands);
}

test "runtime dispatches bridge messages through policy and handler registry" {
    const BridgeState = struct {
        calls: u32 = 0,

        fn ping(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqualStrings("native.ping", invocation.request.command);
            try std.testing.expectEqualStrings("zero://inline", invocation.source.origin);
            try std.testing.expectEqual(@as(u64, 4), invocation.source.window_id);
            try std.testing.expectEqualStrings("{\"source\":\"webview\",\"count\":1}", invocation.request.payload);
            return std.fmt.bufPrint(output, "{{\"pong\":true,\"calls\":{d}}}", .{self.calls});
        }
    };

    var bridge_state: BridgeState = .{};
    const policies = [_]bridge.CommandPolicy{.{ .name = "native.ping", .origins = &.{"zero://inline"} }};
    const handlers = [_]bridge.Handler{.{ .name = "native.ping", .context = &bridge_state, .invoke_fn = BridgeState.ping }};

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.bridge = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &handlers },
    };

    const app = App{ .context = &bridge_state, .name = "bridge", .source = platform.WebViewSource.html("<p>Bridge</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"native.ping\",\"payload\":{\"source\":\"webview\",\"count\":1}}",
        .origin = "zero://inline",
        .window_id = 4,
    } });

    try std.testing.expectEqual(@as(u32, 1), bridge_state.calls);
    try std.testing.expectEqual(@as(platform.WindowId, 4), harness.null_platform.lastBridgeResponseWindowId());
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"ok\":true,\"result\":{\"pong\":true,\"calls\":1}}", harness.null_platform.lastBridgeResponse());
}

test "runtime keeps async bridge response source labels stable" {
    const AsyncState = struct {
        responder: ?bridge.AsyncResponder = null,

        fn later(context: *anyopaque, invocation: bridge.Invocation, responder: bridge.AsyncResponder) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("native.later", invocation.request.command);
            try std.testing.expectEqualStrings("preview", invocation.source.webview_label);
            try std.testing.expectEqualStrings("https://example.com", invocation.source.origin);
            self.responder = responder;
        }
    };

    var async_state: AsyncState = .{};
    const policies = [_]bridge.CommandPolicy{.{ .name = "native.later", .origins = &.{"https://example.com"} }};
    const handlers = [_]bridge.AsyncHandler{.{ .name = "native.later", .context = &async_state, .invoke_fn = AsyncState.later }};

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.bridge = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .async_registry = .{ .handlers = &handlers },
    };

    var label_buffer = [_]u8{ 'p', 'r', 'e', 'v', 'i', 'e', 'w' };
    const app = App{ .context = &async_state, .name = "async-bridge", .source = platform.WebViewSource.html("<p>Bridge</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"async\",\"command\":\"native.later\",\"payload\":null}",
        .origin = "https://example.com",
        .window_id = 1,
        .webview_label = label_buffer[0..],
    } });

    @memcpy(label_buffer[0..], "changed");
    try async_state.responder.?.success("async", "{\"delayed\":true}");
    try std.testing.expectEqualStrings("preview", harness.null_platform.lastBridgeResponseWebViewLabel());
    try std.testing.expectEqualStrings("{\"id\":\"async\",\"ok\":true,\"result\":{\"delayed\":true}}", harness.null_platform.lastBridgeResponse());
}

test "runtime maps bridge dispatch failures to response errors" {
    const FailingState = struct {
        fn fail(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
            _ = context;
            _ = invocation;
            _ = output;
            return error.ExpectedFailure;
        }
    };

    var failing_state: FailingState = .{};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "native.fail", .origins = &.{"zero://inline"} },
        .{ .name = "native.missing", .origins = &.{"zero://inline"} },
        .{ .name = "native.secure", .origins = &.{"zero://inline"} },
    };
    const handlers = [_]bridge.Handler{.{ .name = "native.fail", .context = &failing_state, .invoke_fn = FailingState.fail }};

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.bridge = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &handlers },
    };

    const app = App{ .context = &failing_state, .name = "bridge-errors", .source = platform.WebViewSource.html("<p>Bridge</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"deny\",\"command\":\"native.secure\",\"payload\":null}",
        .origin = "https://example.invalid",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing\",\"command\":\"native.missing\",\"payload\":null}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"unknown_command\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"bad\",\"command\":",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    var too_large: [bridge.max_message_bytes + 1]u8 = undefined;
    @memset(too_large[0..], 'x');
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = too_large[0..],
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"payload_too_large\"") != null);

    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"fail\",\"command\":\"native.fail\",\"payload\":null}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"handler_failed\"") != null);
}

test "runtime creates lists focuses and closes windows" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "windows", .source = platform.WebViewSource.html("<p>Windows</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const info = try harness.runtime.createWindow(.{ .label = "tools", .title = "Tools" });
    try std.testing.expectEqual(@as(platform.WindowId, 2), info.id);
    var output: [platform.max_windows]platform.WindowInfo = undefined;
    const windows = harness.runtime.listWindows(&output);
    try std.testing.expectEqual(@as(usize, 2), windows.len);

    try harness.runtime.focusWindow(info.id);
    try std.testing.expect(harness.runtime.windows[1].info.focused);
    try harness.runtime.closeWindow(info.id);
    try std.testing.expect(!harness.runtime.windows[1].info.open);
}

test "runtime handles built-in JavaScript window bridge commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "window-bridge", .source = platform.WebViewSource.html("<p>Windows</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com", "https://example.org" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"palette\",\"title\":\"Palette\",\"width\":320,\"height\":240}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"palette\"") != null);
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.lastBridgeResponseWindowId());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"duplicate\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"palette\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "already exists") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"bad-frame\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"bad-frame\",\"width\":0,\"height\":240}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "Window options are invalid") != null);
    var invalid_frame_windows: [platform.max_windows]platform.WindowInfo = undefined;
    try std.testing.expectEqual(@as(usize, 2), harness.runtime.listWindows(&invalid_frame_windows).len);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"palette\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing\",\"command\":\"zero-native.window.focus\",\"payload\":{\"label\":\"missing\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "Window was not found") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3\",\"command\":\"zero-native.window.focus\",\"payload\":{\"label\":\"palette\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"4\",\"command\":\"zero-native.window.close\",\"payload\":{\"label\":\"palette\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"open\":false") != null);
}

test "runtime handles built-in JavaScript command bridge commands" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,
        last_view_label: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "command-bridge", .source = platform.WebViewSource.html("<p>Commands</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_name = command.name;
                    self.last_source = command.source;
                    self.last_window_id = command.window_id;
                    self.last_view_label = command.view_label;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const command_origins = [_][]const u8{"zero://inline"};
    harness.runtime.options.security.navigation.allowed_origins = &command_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.command.invoke\",\"payload\":{\"name\":\"app.save\"}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.save", app_state.last_name);
    try std.testing.expectEqual(CommandSource.bridge, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
    try std.testing.expectEqualStrings("", app_state.last_view_label);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"name\":\"app.save\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"source\":\"bridge\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.command.invoke\",\"payload\":{\"id\":\"app.open\"}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "toolbar",
    } });
    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqualStrings("app.open", app_state.last_name);
    try std.testing.expectEqualStrings("toolbar", app_state.last_view_label);
}

test "runtime lists command catalog through built-in JavaScript command API" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "command-list", .source = platform.WebViewSource.html("<p>Commands</p>") };
        }
    };

    const commands = [_]Command{
        .{ .id = "app.save", .title = "Save" },
        .{ .id = "app.sidebar.toggle", .title = "Sidebar", .enabled = false, .checked = true },
    };
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    harness.runtime.options.commands = &commands;
    const command_origins = [_][]const u8{"zero://inline"};
    harness.runtime.options.security.navigation.allowed_origins = &command_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.command.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });

    const response = harness.null_platform.lastBridgeResponse();
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"app.save\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"title\":\"Save\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"app.sidebar.toggle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"checked\":true") != null);
}

test "runtime gates JavaScript command API with command permission" {
    const TestApp = struct {
        command_count: u32 = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "command-permission", .source = platform.WebViewSource.html("<p>Commands</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => self.command_count += 1,
                else => {},
            }
        }
    };

    const command_permission = [_][]const u8{security.permission_command};
    var allowed: TestHarness() = undefined;
    allowed.init(.{});
    allowed.runtime.options.js_window_api = true;
    allowed.runtime.options.security.permissions = &command_permission;
    var app_state: TestApp = .{};
    try allowed.start(app_state.app());
    try allowed.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"allowed\",\"command\":\"zero-native.command.invoke\",\"payload\":{\"name\":\"app.save\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    const commands = [_]Command{.{ .id = "app.save", .title = "Save" }};
    allowed.runtime.options.commands = &commands;
    try allowed.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"list\",\"command\":\"zero-native.command.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"id\":\"app.save\"") != null);

    const filesystem_only = [_][]const u8{security.permission_filesystem};
    var denied: TestHarness() = undefined;
    denied.init(.{});
    denied.runtime.options.js_window_api = true;
    denied.runtime.options.security.permissions = &filesystem_only;
    try denied.start(app_state.app());
    try denied.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"denied\",\"command\":\"zero-native.command.invoke\",\"payload\":{\"name\":\"app.open\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    try denied.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"denied-list\",\"command\":\"zero-native.command.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test "runtime handles built-in JavaScript platform support commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "platform-support", .source = platform.WebViewSource.html("<p>Platform</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    harness.runtime.options.security.navigation.allowed_origins = &.{"zero://inline"};
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try std.testing.expect(harness.runtime.supports(.native_views));
    try std.testing.expect(!harness.runtime.supports(.gpu_surfaces));

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"native_views\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"name-selector\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"name\":\"recentDocuments\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"controls\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"nativeControlCommands\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"drops\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"fileDrops\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"activation\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"appActivationEvents\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"gpu\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"gpuSurfaces\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"result\":false") != null);

    var chromium_platform = platform.NullPlatform.initWithEngine(.{}, .chromium);
    harness.runtime.options.platform = chromium_platform.platform();
    try std.testing.expect(!harness.runtime.supports(.tray));
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"tray\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, chromium_platform.lastBridgeResponse(), "\"result\":false") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"bad\",\"command\":\"zero-native.platform.supports\",\"payload\":{\"feature\":\"missing\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, chromium_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chromium_platform.lastBridgeResponse(), "Platform feature is invalid") != null);
}

test "runtime dispatches native view command events" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,
        last_view_label: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "native-command", .source = platform.WebViewSource.html("<p>Native</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_name = command.name;
                    self.last_source = command.source;
                    self.last_window_id = command.window_id;
                    self.last_view_label = command.view_label;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.refresh",
        .window_id = 1,
        .view_label = "refresh-button",
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.refresh", app_state.last_name);
    try std.testing.expectEqual(CommandSource.native_view, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
    try std.testing.expectEqualStrings("refresh-button", app_state.last_view_label);

    _ = try harness.runtime.createView(.{
        .label = "toolbar",
        .kind = .toolbar,
        .frame = geometry.RectF.init(0, 0, 640, 48),
    });
    _ = try harness.runtime.createView(.{
        .label = "toolbar-refresh",
        .kind = .button,
        .parent = "toolbar",
        .frame = geometry.RectF.init(8, 8, 96, 32),
        .command = "app.refresh",
    });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.refresh",
        .window_id = 1,
        .view_label = "toolbar-refresh",
    } });

    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqual(CommandSource.toolbar, app_state.last_source);
    try std.testing.expectEqualStrings("toolbar-refresh", app_state.last_view_label);

    _ = try harness.runtime.createView(.{
        .label = "toolbar-stack",
        .kind = .stack,
        .parent = "toolbar",
        .frame = geometry.RectF.init(112, 8, 160, 32),
    });
    _ = try harness.runtime.createView(.{
        .label = "toolbar-nested-refresh",
        .kind = .button,
        .parent = "toolbar-stack",
        .frame = geometry.RectF.init(0, 0, 120, 28),
        .command = "app.refresh",
    });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.refresh",
        .window_id = 1,
        .view_label = "toolbar-nested-refresh",
    } });

    try std.testing.expectEqual(@as(u32, 3), app_state.command_count);
    try std.testing.expectEqual(CommandSource.toolbar, app_state.last_source);
    try std.testing.expectEqualStrings("toolbar-nested-refresh", app_state.last_view_label);

    _ = try harness.runtime.createView(.{
        .label = "sidebar",
        .kind = .sidebar,
        .frame = geometry.RectF.init(0, 48, 220, 400),
    });
    _ = try harness.runtime.createView(.{
        .label = "filters",
        .kind = .stack,
        .parent = "sidebar",
        .frame = geometry.RectF.init(16, 16, 160, 120),
    });
    _ = try harness.runtime.createView(.{
        .label = "filter-toggle",
        .kind = .toggle,
        .parent = "filters",
        .frame = geometry.RectF.init(0, 0, 120, 28),
        .command = "app.filter.toggle",
    });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.filter.toggle",
        .window_id = 1,
        .view_label = "filter-toggle",
    } });

    try std.testing.expectEqual(@as(u32, 4), app_state.command_count);
    try std.testing.expectEqual(CommandSource.native_view, app_state.last_source);
    try std.testing.expectEqualStrings("filter-toggle", app_state.last_view_label);
}

test "runtime exposes configured command catalog" {
    const commands = [_]Command{
        .{ .id = "app.refresh", .title = "Refresh" },
        .{ .id = "app.sidebar.toggle", .title = "Sidebar", .checked = true },
    };
    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.commands = &commands;

    var output: [4]Command = undefined;
    const listed = harness.runtime.listCommands(&output);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("app.refresh", listed[0].id);
    try std.testing.expectEqualStrings("Refresh", listed[0].title);
    try std.testing.expect(listed[0].enabled);
    try std.testing.expectEqualStrings("app.sidebar.toggle", listed[1].id);
    try std.testing.expect(listed[1].checked);

    var narrow_output: [1]Command = undefined;
    const narrow = harness.runtime.listCommands(&narrow_output);
    try std.testing.expectEqual(@as(usize, 1), narrow.len);
    try std.testing.expectEqualStrings("app.refresh", narrow[0].id);
}

test "runtime dispatches menu command events" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_window_id: platform.WindowId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "menu-command", .source = platform.WebViewSource.html("<p>Menu</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_name = command.name;
                    self.last_source = command.source;
                    self.last_window_id = command.window_id;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .menu_command = .{
        .name = "app.refresh",
        .window_id = 1,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.refresh", app_state.last_name);
    try std.testing.expectEqual(CommandSource.menu, app_state.last_source);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
}

test "runtime dispatches tray item commands" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_name: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_tray_item_id: platform.TrayItemId = 0,

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "tray-command", .source = platform.WebViewSource.html("<p>Tray</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_name = command.name;
                    self.last_source = command.source;
                    self.last_tray_item_id = command.tray_item_id;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.createTray(.{ .items = &.{
        .{ .id = 7, .label = "Refresh", .command = "app.refresh" },
        .{ .id = 8, .label = "Legacy" },
    } });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .tray_action = 7 });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.refresh", app_state.last_name);
    try std.testing.expectEqual(CommandSource.tray, app_state.last_source);
    try std.testing.expectEqual(@as(platform.TrayItemId, 7), app_state.last_tray_item_id);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .tray_action = 8 });
    try std.testing.expectEqual(@as(u32, 2), app_state.command_count);
    try std.testing.expectEqualStrings("tray.action", app_state.last_name);
    try std.testing.expectEqual(@as(platform.TrayItemId, 8), app_state.last_tray_item_id);

    try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.updateTrayMenu(&.{
        .{ .id = 9, .label = "One", .command = "app.one" },
        .{ .id = 9, .label = "Two" },
    }));
    try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.updateTrayMenu(&.{.{ .label = "Missing id", .command = "app.missing-id" }}));
}

test "runtime dispatches file drop events to app and window bridge" {
    const TestApp = struct {
        drop_count: u32 = 0,
        last_window_id: platform.WindowId = 0,
        last_paths: []const []const u8 = &.{},

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "file-drop", .source = platform.WebViewSource.html("<p>Drops</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .files_dropped => |drop| {
                    self.drop_count += 1;
                    self.last_window_id = drop.window_id;
                    self.last_paths = drop.paths;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const dropped_paths = [_][]const u8{ "/tmp/one\nname.txt", "/tmp/two.txt" };
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .files_dropped = .{
        .window_id = 1,
        .paths = &dropped_paths,
    } });

    try std.testing.expectEqual(@as(u32, 1), app_state.drop_count);
    try std.testing.expectEqual(@as(platform.WindowId, 1), app_state.last_window_id);
    try std.testing.expectEqual(@as(usize, 2), app_state.last_paths.len);
    try std.testing.expectEqualStrings("/tmp/one\nname.txt", app_state.last_paths[0]);
    try std.testing.expectEqualStrings("/tmp/two.txt", app_state.last_paths[1]);
    try std.testing.expectEqualStrings("drop:files", harness.null_platform.lastWindowEventName());
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastWindowEventDetail(), "\"paths\":[\"/tmp/one\\nname.txt\",\"/tmp/two.txt\"]") != null);
}

test "runtime handles built-in JavaScript webview bridge commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-bridge", .source = platform.WebViewSource.html("<p>WebView</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com", "https://example.org" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.com\",\"frame\":{\"x\":10,\"y\":20,\"width\":300,\"height\":200},\"layer\":2,\"transparent\":true,\"bridge\":false}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.webview_count);
    try std.testing.expectEqualStrings("preview", harness.null_platform.webviews[0].label);
    try std.testing.expectEqualStrings("https://example.com", harness.null_platform.webviews[0].url);
    try std.testing.expectEqual(@as(i32, 2), harness.null_platform.webviews[0].layer);
    try std.testing.expect(harness.null_platform.webviews[0].transparent);
    try std.testing.expect(!harness.null_platform.webviews[0].bridge_enabled);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.webview.setFrame\",\"payload\":{\"label\":\"preview\",\"frame\":{\"x\":11,\"y\":22,\"width\":333,\"height\":222}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(f32, 333), harness.null_platform.webviews[0].frame.width);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3\",\"command\":\"zero-native.webview.navigate\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.org\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqualStrings("https://example.org", harness.null_platform.webviews[0].url);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"4\",\"command\":\"zero-native.webview.setZoom\",\"payload\":{\"label\":\"preview\",\"zoom\":1.25}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(f64, 1.25), harness.null_platform.webviews[0].zoom);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"zoom\":1.25") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"5\",\"command\":\"zero-native.webview.setLayer\",\"payload\":{\"label\":\"preview\",\"layer\":10}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(i32, 10), harness.null_platform.webviews[0].layer);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"6\",\"command\":\"zero-native.webview.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"url\":\"zero://inline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"layer\":10") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"7\",\"command\":\"zero-native.webview.setFrame\",\"payload\":{\"label\":\"main\",\"frame\":{\"x\":0,\"y\":0,\"width\":640,\"height\":80}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"height\":80") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"zoom\":1") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"8\",\"command\":\"zero-native.webview.setZoom\",\"payload\":{\"label\":\"main\",\"zoom\":1.1}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"height\":80") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"zoom\":1.1") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"9\",\"command\":\"zero-native.webview.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "preview",
    } });
    try std.testing.expectEqualStrings("preview", harness.null_platform.lastBridgeResponseWebViewLabel());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"9\",\"command\":\"zero-native.webview.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
        .webview_label = "main",
    } });
    try std.testing.expectEqualStrings("main", harness.null_platform.lastBridgeResponseWebViewLabel());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"10\",\"command\":\"zero-native.webview.close\",\"payload\":{\"label\":\"preview\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);
}

test "runtime handles built-in JavaScript view bridge commands" {
    const TestApp = struct {
        command_count: u32 = 0,
        last_command: []const u8 = "",
        last_source: CommandSource = .runtime,
        last_view_label: []const u8 = "",

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "view-bridge", .source = platform.WebViewSource.html("<p>Views</p>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .command => |command| {
                    self.command_count += 1;
                    self.last_command = command.name;
                    self.last_source = command.source;
                    self.last_view_label = command.view_label;
                },
                else => {},
            }
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const view_origins = [_][]const u8{ "zero://inline", "zero://app" };
    harness.runtime.options.security.navigation.allowed_origins = &view_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.view.create\",\"payload\":{\"label\":\"toolbar\",\"kind\":\"toolbar\",\"frame\":{\"x\":0,\"y\":0,\"width\":640,\"height\":44},\"role\":\"toolbar\",\"accessibilityLabel\":\"Main tools\",\"text\":\"Tools\",\"command\":\"app.tools\",\"layer\":3}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"kind\":\"toolbar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"accessibilityLabel\":\"Main tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"text\":\"Tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"command\":\"app.tools\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.view_count);
    try std.testing.expectEqualStrings("Main tools", harness.null_platform.views[0].accessibility_label);
    try std.testing.expectEqualStrings("app.tools", harness.null_platform.views[0].command);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .native_command = .{
        .name = "app.tools",
        .window_id = 1,
        .view_label = "toolbar",
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.tools", app_state.last_command);
    try std.testing.expectEqual(CommandSource.toolbar, app_state.last_source);
    try std.testing.expectEqualStrings("toolbar", app_state.last_view_label);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.view.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"toolbar\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3\",\"command\":\"zero-native.view.focus\",\"payload\":{\"label\":\"toolbar\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"toolbar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3-next\",\"command\":\"zero-native.view.focusNext\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"3-prev\",\"command\":\"zero-native.view.focusPrevious\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"toolbar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"4\",\"command\":\"zero-native.view.setFrame\",\"payload\":{\"label\":\"toolbar\",\"frame\":{\"x\":0,\"y\":0,\"width\":640,\"height\":52}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"height\":52") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"5\",\"command\":\"zero-native.view.setVisible\",\"payload\":{\"label\":\"toolbar\",\"visible\":false}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"visible\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":false") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"5-list\",\"command\":\"zero-native.view.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"6\",\"command\":\"zero-native.view.update\",\"payload\":{\"label\":\"toolbar\",\"visible\":true,\"enabled\":false,\"role\":\"banner\",\"accessibilityLabel\":\"Primary actions\",\"text\":\"Actions\",\"command\":\"app.actions\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"role\":\"banner\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"accessibilityLabel\":\"Primary actions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"text\":\"Actions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"command\":\"app.actions\"") != null);
    try std.testing.expectEqualStrings("Primary actions", harness.null_platform.views[0].accessibility_label);
    try std.testing.expectEqualStrings("app.actions", harness.null_platform.views[0].command);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"7\",\"command\":\"zero-native.view.close\",\"payload\":{\"label\":\"toolbar\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"open\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"focused\":false") != null);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
}

test "runtime gates JavaScript view API with view permission" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "view-permission", .source = platform.WebViewSource.html("<p>Views</p>") };
        }
    };

    const view_permission = [_][]const u8{security.permission_view};
    var allowed: TestHarness() = undefined;
    allowed.init(.{});
    allowed.runtime.options.js_window_api = true;
    allowed.runtime.options.security.permissions = &view_permission;
    var app_state: TestApp = .{};
    try allowed.start(app_state.app());
    try allowed.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"allowed\",\"command\":\"zero-native.view.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    const command_permission = [_][]const u8{security.permission_command};
    var denied: TestHarness() = undefined;
    denied.init(.{});
    denied.runtime.options.js_window_api = true;
    denied.runtime.options.security.permissions = &command_permission;
    try denied.start(app_state.app());
    try denied.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"denied\",\"command\":\"zero-native.view.list\",\"payload\":{}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test "runtime returns closed webview info before compacting storage" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-close-response", .source = platform.WebViewSource.html("<p>WebView</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"first\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"first\",\"url\":\"https://example.com/first\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"second\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"second\",\"url\":\"https://example.com/second\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"close-first\",\"command\":\"zero-native.webview.close\",\"payload\":{\"label\":\"first\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"second\"") == null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.webview_count);
    try std.testing.expectEqualStrings("second", harness.null_platform.webviews[0].label);
}

test "runtime defaults webview commands to source window" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-source-window", .source = platform.WebViewSource.html("<p>WebView</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());
    const secondary = try harness.runtime.createWindow(.{ .label = "secondary" });

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = secondary.id,
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(secondary.id, harness.null_platform.webviews[0].window_id);
    try std.testing.expectEqual(secondary.id, harness.null_platform.lastBridgeResponseWindowId());
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"windowId\":2") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.webview.create\",\"payload\":{\"windowId\":2,\"label\":\"cross-window\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "must match the calling window") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
}

test "runtime validates webview bridge commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-validation", .source = platform.WebViewSource.html("<p>WebView</p>") };
        }
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.js_window_api = true;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com", "https://example.org" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing-url\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView URL is missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"invalid-frame\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.com\",\"frame\":{\"width\":0,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"reserved-label\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"main\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "reserved") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"native-view\",\"command\":\"zero-native.view.create\",\"payload\":{\"label\":\"native-collision\",\"kind\":\"button\",\"frame\":{\"width\":120,\"height\":32},\"text\":\"Native\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"native-collision\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"native-collision\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "View label already exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.webview_count);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"invalid-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"bad-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":1e1000}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"max-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"max-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":2147483647}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"layer\":2147483647") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"out-of-range-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"bad-layer-range\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":100000000000000000000}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"i32-overflow-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"i32-overflow-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":2147483648}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"min-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"min-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":-2147483648}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"layer\":-2147483648") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"i32-underflow-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"i32-underflow-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":-2147483649}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"fractional-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"fractional-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":1.5}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView options are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"ok\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"duplicate\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview\",\"url\":\"https://example.org\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView label already exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing-window\",\"command\":\"zero-native.webview.create\",\"payload\":{\"windowId\":99,\"label\":\"other\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "must match the calling window") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"bad-window-id\",\"command\":\"zero-native.webview.create\",\"payload\":{\"windowId\":\"1\",\"label\":\"bad-window-id\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "windowId must be a non-negative integer") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"missing-webview\",\"command\":\"zero-native.webview.setFrame\",\"payload\":{\"label\":\"missing\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView was not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    var long_label = [_]u8{'a'} ** (platform.max_webview_label_bytes + 1);
    var long_label_request_buffer: [512]u8 = undefined;
    const long_label_request = try std.fmt.bufPrint(&long_label_request_buffer, "{{\"id\":\"long-label\",\"command\":\"zero-native.webview.create\",\"payload\":{{\"label\":\"{s}\",\"url\":\"https://example.com\",\"frame\":{{\"width\":300,\"height\":200}}}}}}", .{&long_label});
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = long_label_request,
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView label is too large") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    var long_url = [_]u8{'a'} ** (platform.max_webview_url_bytes + 1);
    var long_url_request_buffer: [platform.max_webview_url_bytes + 256]u8 = undefined;
    const long_url_request = try std.fmt.bufPrint(&long_url_request_buffer, "{{\"id\":\"long-url\",\"command\":\"zero-native.webview.create\",\"payload\":{{\"label\":\"too-long-url\",\"url\":\"{s}\",\"frame\":{{\"width\":300,\"height\":200}}}}}}", .{&long_url});
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = long_url_request,
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "WebView URL is too large") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"denied-url\",\"command\":\"zero-native.webview.navigate\",\"payload\":{\"label\":\"preview\",\"url\":\"https://blocked.example\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "navigation policy") != null);

    harness.runtime.options.platform.services.set_webview_zoom_fn = null;
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"unsupported-zoom\",\"command\":\"zero-native.webview.setZoom\",\"payload\":{\"label\":\"preview\",\"zoom\":1.25}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "not available on this platform") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"escaped\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"preview \\\"quoted\\\"\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"preview \\\"quoted\\\"\"") != null);
}

test "runtime reports actionable unsupported webview capability errors" {
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedChildWebViews));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedWebViewBridge));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedMainWebViewFrame));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedMainWebViewZoom));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.UnsupportedMainWebViewLayer));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.InvalidWindowOptions));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.DuplicateWindowLabel));
    try std.testing.expectEqual(bridge.ErrorCode.invalid_request, builtinBridgeErrorCode(error.WindowNotFound));
    try std.testing.expectEqualStrings("This backend does not support child WebViews yet", builtinBridgeErrorMessage(error.UnsupportedChildWebViews));
    try std.testing.expectEqualStrings("This backend does not support bridge-enabled child WebViews yet", builtinBridgeErrorMessage(error.UnsupportedWebViewBridge));
    try std.testing.expectEqualStrings("This backend does not support resizing the main WebView yet", builtinBridgeErrorMessage(error.UnsupportedMainWebViewFrame));
    try std.testing.expectEqualStrings("This backend does not support zooming the main WebView yet", builtinBridgeErrorMessage(error.UnsupportedMainWebViewZoom));
    try std.testing.expectEqualStrings("This backend does not support changing the main WebView layer", builtinBridgeErrorMessage(error.UnsupportedMainWebViewLayer));
}

test "runtime gates JavaScript window API by origin and configured permission" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "window-api-security", .source = platform.WebViewSource.html("<p>Windows</p>") };

    var denied_origin: TestHarness() = undefined;
    denied_origin.init(.{});
    denied_origin.runtime.options.js_window_api = true;
    try denied_origin.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"origin\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "https://example.invalid",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_origin.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const filesystem_only = [_][]const u8{security.permission_filesystem};
    var denied_permission: TestHarness() = undefined;
    denied_permission.init(.{});
    denied_permission.runtime.options.js_window_api = true;
    denied_permission.runtime.options.security.permissions = &filesystem_only;
    try denied_permission.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"permission\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_permission.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const window_permission = [_][]const u8{security.permission_window};
    var allowed: TestHarness() = undefined;
    allowed.init(.{});
    allowed.runtime.options.js_window_api = true;
    allowed.runtime.options.security.permissions = &window_permission;
    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"allowed\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
}

test "runtime gates JavaScript webview API by origin and configured permission" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "webview-api-security", .source = platform.WebViewSource.html("<p>WebViews</p>") };

    var denied_origin: TestHarness() = undefined;
    denied_origin.init(.{});
    denied_origin.runtime.options.js_window_api = true;
    try denied_origin.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"origin\",\"command\":\"zero-native.webview.create\",\"payload\":{\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "https://example.invalid",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_origin.null_platform.lastBridgeResponse(), "WebView API is not permitted") != null);

    const filesystem_only = [_][]const u8{security.permission_filesystem};
    var denied_permission: TestHarness() = undefined;
    denied_permission.init(.{});
    denied_permission.runtime.options.js_window_api = true;
    denied_permission.runtime.options.security.permissions = &filesystem_only;
    try denied_permission.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"permission\",\"command\":\"zero-native.webview.create\",\"payload\":{\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_permission.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const window_permission = [_][]const u8{security.permission_window};
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    var allowed: TestHarness() = undefined;
    allowed.init(.{});
    allowed.runtime.options.js_window_api = true;
    allowed.runtime.options.security.permissions = &window_permission;
    allowed.runtime.options.security.navigation.allowed_origins = &webview_origins;
    try allowed.runtime.dispatchPlatformEvent(app, .app_start);
    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"allowed\",\"command\":\"zero-native.webview.create\",\"payload\":{\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
}

test "runtime gates built-in bridge commands through explicit policy" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "builtin-policy", .source = platform.WebViewSource.html("<p>Windows</p>") };
        }
    };

    const window_permissions = [_][]const u8{security.permission_window};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "zero-native.window.create", .permissions = &window_permissions, .origins = &.{"zero://inline"} },
        .{ .name = "zero-native.webview.create", .permissions = &window_permissions, .origins = &.{"zero://inline"} },
    };

    var harness: TestHarness() = undefined;
    harness.init(.{});
    harness.runtime.options.security.permissions = &window_permissions;
    const webview_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    harness.runtime.options.security.navigation.allowed_origins = &webview_origins;
    harness.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &policies };
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"policy-window\",\"title\":\"Policy\",\"width\":320,\"height\":240}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"webview\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"policy-webview\",\"url\":\"https://example.com\",\"frame\":{\"width\":320,\"height\":240}}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"ok\":true") != null);

    harness.runtime.options.security.permissions = &.{};
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.window.create\",\"payload\":{\"label\":\"denied-window\"}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test "runtime denies built-in dialog bridge commands by default" {
    var harness: TestHarness() = undefined;
    harness.init(.{});
    const app = App{ .context = &harness, .name = "dialog-denied", .source = platform.WebViewSource.html("<p>Dialogs</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.dialog.showMessage\",\"payload\":{\"message\":\"Hello\"}}",
        .origin = "zero://inline",
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test "runtime reports dialog bridge validation errors as invalid requests" {
    var harness: TestHarness() = undefined;
    harness.init(.{});
    const app = App{ .context = &harness, .name = "dialog-invalid", .source = platform.WebViewSource.html("<p>Dialogs</p>") };
    const dialog_permission = [_][]const u8{security.permission_dialog};
    const dialog_policy = [_]bridge.CommandPolicy{.{
        .name = "zero-native.dialog.showMessage",
        .permissions = &dialog_permission,
        .origins = &.{"zero://inline"},
    }};
    harness.runtime.options.security.permissions = &dialog_permission;
    harness.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &dialog_policy };

    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"invalid-dialog\",\"command\":\"zero-native.dialog.showMessage\",\"payload\":{\"primaryButton\":\"\"}}",
        .origin = "zero://inline",
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"internal_error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "Dialog options are invalid") != null);
}

test "runtime validates native OS actions before platform dispatch" {
    var harness: TestHarness() = undefined;
    harness.init(.{});

    var dialog_paths: [platform.max_dialog_paths_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidDialogOptions, harness.runtime.showOpenDialog(.{}, dialog_paths[0..0]));
    var small_dialog_paths: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, harness.runtime.showOpenDialog(.{}, &small_dialog_paths));
    const long_dialog_title = [_]u8{'x'} ** (platform.max_dialog_title_bytes + 1);
    try std.testing.expectError(error.DialogFieldTooLarge, harness.runtime.showOpenDialog(.{ .title = &long_dialog_title }, &dialog_paths));
    const open_result = try harness.runtime.showOpenDialog(.{ .title = "Open" }, &dialog_paths);
    try std.testing.expectEqual(@as(usize, 1), open_result.count);
    try std.testing.expectEqualStrings("/tmp/zero-native-open.txt", open_result.paths);

    var save_path: [platform.max_dialog_path_bytes]u8 = undefined;
    var small_save_path: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, harness.runtime.showSaveDialog(.{ .default_name = "report.txt" }, &small_save_path));
    const saved = (try harness.runtime.showSaveDialog(.{ .default_name = "report.txt" }, &save_path)).?;
    try std.testing.expectEqualStrings("report.txt", saved);

    try std.testing.expectError(error.InvalidDialogOptions, harness.runtime.showMessageDialog(.{ .primary_button = "" }));
    const dialog_result = try harness.runtime.showMessageDialog(.{ .message = "Proceed?", .primary_button = "OK" });
    try std.testing.expectEqual(platform.MessageDialogResult.primary, dialog_result);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.open_dialog_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.save_dialog_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.message_dialog_count);

    try std.testing.expectError(error.InvalidNotificationOptions, harness.runtime.showNotification(.{ .title = "" }));
    try harness.runtime.showNotification(.{
        .title = "Build finished",
        .subtitle = "zero-native",
        .body = "All checks passed.",
    });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.notificationCount());
    try std.testing.expectEqualStrings("Build finished", harness.null_platform.lastNotificationTitle());
    try std.testing.expectEqualStrings("zero-native", harness.null_platform.lastNotificationSubtitle());
    try std.testing.expectEqualStrings("All checks passed.", harness.null_platform.lastNotificationBody());

    try std.testing.expectError(error.NavigationDenied, harness.runtime.openExternalUrl("https://example.com/docs"));
    try std.testing.expectError(error.InvalidExternalUrl, harness.runtime.openExternalUrl("mailto:hello@example.com"));

    const allowed_urls = [_][]const u8{"https://example.com/*"};
    harness.runtime.options.security.navigation.external_links = .{
        .action = .open_system_browser,
        .allowed_urls = &allowed_urls,
    };
    try harness.runtime.openExternalUrl("https://example.com/docs");
    try std.testing.expectEqualStrings("https://example.com/docs", harness.null_platform.lastExternalUrl());

    try std.testing.expectError(error.InvalidRevealPath, harness.runtime.revealPath(""));
    try harness.runtime.revealPath("/tmp/zero-native-example.txt");
    try std.testing.expectEqualStrings("/tmp/zero-native-example.txt", harness.null_platform.lastRevealedPath());

    try std.testing.expectError(error.InvalidRecentDocumentPath, harness.runtime.addRecentDocument(""));
    try harness.runtime.addRecentDocument("/tmp/recent-zero-native-example.txt");
    try std.testing.expectEqualStrings("/tmp/recent-zero-native-example.txt", harness.null_platform.lastRecentDocumentPath());
    try harness.runtime.clearRecentDocuments();
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.recentDocumentsClearedCount());

    var clipboard_buffer: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidClipboardOptions, harness.runtime.readClipboardData("", &clipboard_buffer));
    try std.testing.expectError(error.InvalidClipboardOptions, harness.runtime.writeClipboardData(.{ .mime_type = "", .bytes = "text" }));
    try harness.runtime.writeClipboard("plain text");
    try std.testing.expectEqualStrings("plain text", try harness.runtime.readClipboard(&clipboard_buffer));
    try std.testing.expectEqualStrings("text/plain", harness.null_platform.lastClipboardMimeType());
    try harness.runtime.writeClipboardData(.{ .mime_type = "text/html", .bytes = "<strong>bold</strong>" });
    try std.testing.expectEqualStrings("text/html", harness.null_platform.lastClipboardMimeType());
    try std.testing.expectEqualStrings("<strong>bold</strong>", try harness.runtime.readClipboardData("text/html", &clipboard_buffer));

    try std.testing.expectError(error.InvalidCredentialOptions, harness.runtime.setCredential(.{ .service = "", .account = "alice", .secret = "secret-token" }));
    try std.testing.expectError(error.InvalidCredentialOptions, harness.runtime.setCredential(.{ .service = "dev.zero-native.test", .account = "alice", .secret = "" }));
    try harness.runtime.setCredential(.{ .service = "dev.zero-native.test", .account = "alice", .secret = "secret-token" });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.credentialSetCount());
    try std.testing.expectEqualStrings("dev.zero-native.test", harness.null_platform.lastCredentialService());
    try std.testing.expectEqualStrings("alice", harness.null_platform.lastCredentialAccount());
    try std.testing.expectEqualStrings("secret-token", harness.null_platform.lastCredentialSecret());

    var credential_buffer: [64]u8 = undefined;
    const secret = (try harness.runtime.getCredential(.{ .service = "dev.zero-native.test", .account = "alice" }, &credential_buffer)).?;
    try std.testing.expectEqualStrings("secret-token", secret);
    try std.testing.expectEqual(@as(?[]const u8, null), try harness.runtime.getCredential(.{ .service = "dev.zero-native.test", .account = "bob" }, &credential_buffer));
    try std.testing.expect(try harness.runtime.deleteCredential(.{ .service = "dev.zero-native.test", .account = "alice" }));
    try std.testing.expect(!try harness.runtime.deleteCredential(.{ .service = "dev.zero-native.test", .account = "alice" }));

    try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.createTray(.{ .items = &.{.{ .label = "" }} }));
    try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.updateTrayMenu(&.{.{ .label = "" }}));
    try harness.runtime.createTray(.{
        .icon_path = "/tmp/tray.png",
        .tooltip = "zero-native",
        .items = &.{
            .{ .id = 1, .label = "Open" },
            .{ .separator = true },
            .{ .id = 2, .label = "Quit", .enabled = false },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try std.testing.expectEqualStrings("/tmp/tray.png", harness.null_platform.lastTrayIconPath());
    try std.testing.expectEqualStrings("zero-native", harness.null_platform.lastTrayTooltip());
    try std.testing.expectEqual(@as(usize, 3), harness.null_platform.trayItems().len);
    try std.testing.expectEqualStrings("Open", harness.null_platform.trayItems()[0].label);
    try std.testing.expect(harness.null_platform.trayItems()[1].separator);
    try std.testing.expect(!harness.null_platform.trayItems()[2].enabled);
    try harness.runtime.updateTrayMenu(&.{.{ .id = 3, .label = "Settings" }});
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.trayUpdateCount());
    try std.testing.expectEqualStrings("Settings", harness.null_platform.trayItems()[0].label);
    try harness.runtime.removeTray();
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.trayRemoveCount());
}

test "runtime gates built-in OS bridge commands through explicit policy" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "os-bridge", .source = platform.WebViewSource.html("<p>OS</p>") };

    var denied: TestHarness() = undefined;
    denied.init(.{});
    try denied.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"open\",\"command\":\"zero-native.os.openUrl\",\"payload\":{\"url\":\"https://example.com/docs\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "OS API is not permitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const grants = [_][]const u8{ security.permission_network, security.permission_filesystem, security.permission_notifications };
    const network_permission = [_][]const u8{security.permission_network};
    const filesystem_permission = [_][]const u8{security.permission_filesystem};
    const notifications_permission = [_][]const u8{security.permission_notifications};
    const origins = [_][]const u8{"zero://inline"};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "zero-native.os.openUrl", .permissions = &network_permission, .origins = &origins },
        .{ .name = "zero-native.os.showNotification", .permissions = &notifications_permission, .origins = &origins },
        .{ .name = "zero-native.os.revealPath", .permissions = &filesystem_permission, .origins = &origins },
        .{ .name = "zero-native.os.addRecentDocument", .permissions = &filesystem_permission, .origins = &origins },
        .{ .name = "zero-native.os.clearRecentDocuments", .permissions = &filesystem_permission, .origins = &origins },
    };
    const allowed_urls = [_][]const u8{"https://example.com/*"};

    var allowed: TestHarness() = undefined;
    allowed.init(.{});
    allowed.runtime.options.security.permissions = &grants;
    allowed.runtime.options.security.navigation.external_links = .{
        .action = .open_system_browser,
        .allowed_urls = &allowed_urls,
    };
    allowed.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &policies };

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"notify\",\"command\":\"zero-native.os.showNotification\",\"payload\":{\"title\":\"Build finished\",\"subtitle\":\"zero-native\",\"body\":\"All checks passed.\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), allowed.null_platform.notificationCount());
    try std.testing.expectEqualStrings("Build finished", allowed.null_platform.lastNotificationTitle());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"open\",\"command\":\"zero-native.os.openUrl\",\"payload\":{\"url\":\"https://example.com/docs\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("https://example.com/docs", allowed.null_platform.lastExternalUrl());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"reveal\",\"command\":\"zero-native.os.revealPath\",\"payload\":{\"path\":\"/tmp/zero-native-example.txt\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("/tmp/zero-native-example.txt", allowed.null_platform.lastRevealedPath());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"recent\",\"command\":\"zero-native.os.addRecentDocument\",\"payload\":{\"path\":\"/tmp/recent-zero-native-example.txt\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("/tmp/recent-zero-native-example.txt", allowed.null_platform.lastRecentDocumentPath());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"clear-recent\",\"command\":\"zero-native.os.clearRecentDocuments\",\"payload\":{}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), allowed.null_platform.recentDocumentsClearedCount());
}

test "runtime gates built-in clipboard bridge commands through explicit policy" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "clipboard-bridge", .source = platform.WebViewSource.html("<p>Clipboard</p>") };

    var denied: TestHarness() = undefined;
    denied.init(.{});
    try denied.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"write\",\"command\":\"zero-native.clipboard.writeText\",\"payload\":{\"text\":\"plain text\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "Clipboard API is not permitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const grants = [_][]const u8{security.permission_clipboard};
    const clipboard_permission = [_][]const u8{security.permission_clipboard};
    const origins = [_][]const u8{"zero://inline"};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "zero-native.clipboard.readText", .permissions = &clipboard_permission, .origins = &origins },
        .{ .name = "zero-native.clipboard.writeText", .permissions = &clipboard_permission, .origins = &origins },
        .{ .name = "zero-native.clipboard.read", .permissions = &clipboard_permission, .origins = &origins },
        .{ .name = "zero-native.clipboard.write", .permissions = &clipboard_permission, .origins = &origins },
    };

    var allowed: TestHarness() = undefined;
    allowed.init(.{});
    allowed.runtime.options.security.permissions = &grants;
    allowed.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &policies };

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"write-text\",\"command\":\"zero-native.clipboard.writeText\",\"payload\":{\"text\":\"plain text\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("text/plain", allowed.null_platform.lastClipboardMimeType());
    try std.testing.expectEqualStrings("plain text", allowed.null_platform.lastClipboardData());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"read-text\",\"command\":\"zero-native.clipboard.readText\",\"payload\":{}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"result\":\"plain text\"") != null);

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"write-html\",\"command\":\"zero-native.clipboard.write\",\"payload\":{\"mimeType\":\"text/html\",\"data\":\"<strong>bold</strong>\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqualStrings("text/html", allowed.null_platform.lastClipboardMimeType());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"read-html\",\"command\":\"zero-native.clipboard.read\",\"payload\":{\"mimeType\":\"text/html\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"mimeType\":\"text/html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"data\":\"<strong>bold</strong>\"") != null);
}

test "runtime gates built-in credential bridge commands through explicit policy" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "credential-bridge", .source = platform.WebViewSource.html("<p>Credentials</p>") };

    var denied: TestHarness() = undefined;
    denied.init(.{});
    try denied.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"set\",\"command\":\"zero-native.credentials.set\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\",\"secret\":\"secret-token\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "Credentials API is not permitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const grants = [_][]const u8{security.permission_credentials};
    const credential_permission = [_][]const u8{security.permission_credentials};
    const origins = [_][]const u8{"zero://inline"};
    const policies = [_]bridge.CommandPolicy{
        .{ .name = "zero-native.credentials.set", .permissions = &credential_permission, .origins = &origins },
        .{ .name = "zero-native.credentials.get", .permissions = &credential_permission, .origins = &origins },
        .{ .name = "zero-native.credentials.delete", .permissions = &credential_permission, .origins = &origins },
    };

    var allowed: TestHarness() = undefined;
    allowed.init(.{});
    allowed.runtime.options.security.permissions = &grants;
    allowed.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &policies };

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"set\",\"command\":\"zero-native.credentials.set\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\",\"secret\":\"secret-token\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), allowed.null_platform.credentialSetCount());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"get\",\"command\":\"zero-native.credentials.get\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"result\":\"secret-token\"") != null);

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"delete\",\"command\":\"zero-native.credentials.delete\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"result\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), allowed.null_platform.credentialDeleteCount());

    try allowed.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"get-missing\",\"command\":\"zero-native.credentials.get\",\"payload\":{\"service\":\"dev.zero-native.test\",\"account\":\"alice\"}}",
        .origin = "zero://inline",
    } });
    try std.testing.expect(std.mem.indexOf(u8, allowed.null_platform.lastBridgeResponse(), "\"result\":null") != null);
}

test "runtime builtin JSON field reader only reads top-level fields" {
    const payload =
        \\{"nested":{"label":"wrong"},"label":"palette \"one\"","width":320,"restoreState":false}
    ;
    var buffer: [128]u8 = undefined;
    var storage = json.StringStorage.init(&buffer);
    try std.testing.expectEqualStrings("palette \"one\"", jsonStringField(payload, "label", &storage).?);
    try std.testing.expectEqual(@as(f32, 320), jsonNumberField(payload, "width").?);
    try std.testing.expectEqual(false, jsonBoolField(payload, "restoreState").?);
}

test "runtime returns bridge permission errors through platform response service" {
    var harness: TestHarness() = undefined;
    harness.init(.{});
    const app = App{ .context = &harness, .name = "bridge-denied", .source = platform.WebViewSource.html("<p>Bridge</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"native.ping\",\"payload\":null}",
        .origin = "zero://inline",
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test {
    std.testing.refAllDecls(@This());
}
