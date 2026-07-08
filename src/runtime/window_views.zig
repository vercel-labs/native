const std = @import("std");
const geometry = @import("geometry");
const validation = @import("validation.zig");
const shell_layout = @import("shell_layout.zig");
const runtime_state = @import("state.zig");
const runtime_window_storage = @import("window_storage.zig");
const runtime_window_view_runtime = @import("window_view_runtime.zig");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");

const isMainWebViewLabel = validation.isMainWebViewLabel;
const RuntimeMainWebViewState = runtime_state.RuntimeMainWebViewState;
const ShellApplyMode = runtime_state.ShellApplyMode;
const ShellLayout = shell_layout.ShellLayout;
const shellRestorePolicy = shell_layout.shellRestorePolicy;
const shellViewOptions = shell_layout.shellViewOptions;

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

pub fn RuntimeWindowViews(comptime Runtime: type) type {
    const WindowStorageMethods = runtime_window_storage.RuntimeWindowStorage(Runtime);
    const WindowViewRuntimeMethods = runtime_window_view_runtime.RuntimeWindowViewRuntime(Runtime);

    return struct {
        const Self = @This();

        pub const createWindow = WindowStorageMethods.createWindow;
        pub const listWindows = WindowStorageMethods.listWindows;
        pub const focusWindow = WindowStorageMethods.focusWindow;
        pub const createWindowWithSourceMode = WindowStorageMethods.createWindowWithSourceMode;
        pub const reserveWindow = WindowStorageMethods.reserveWindow;
        pub const removeWindowAt = WindowStorageMethods.removeWindowAt;
        pub const copySource = WindowStorageMethods.copySource;
        pub const copyLoadedSource = WindowStorageMethods.copyLoadedSource;
        pub const applyNativeInfo = WindowStorageMethods.applyNativeInfo;
        pub const runtimeWindowStateForPersistence = WindowStorageMethods.runtimeWindowStateForPersistence;
        pub const shellBoundsForWindow = WindowStorageMethods.shellBoundsForWindow;
        pub const startupWindowFrame = WindowStorageMethods.startupWindowFrame;
        pub const rectsEqual = WindowStorageMethods.rectsEqual;
        pub const canvasDirtyRegionForView = WindowStorageMethods.canvasDirtyRegionForView;
        pub const bindShellViews = WindowStorageMethods.bindShellViews;
        pub const shellLayoutForWindow = WindowStorageMethods.shellLayoutForWindow;
        pub const findShellLayoutIndex = WindowStorageMethods.findShellLayoutIndex;
        pub const removeShellLayoutForWindow = WindowStorageMethods.removeShellLayoutForWindow;
        pub const setFocusedIndex = WindowStorageMethods.setFocusedIndex;
        pub const findWindowIndexById = WindowStorageMethods.findWindowIndexById;
        pub const findWindowIndexByLabel = WindowStorageMethods.findWindowIndexByLabel;
        pub const allocateWindowId = WindowStorageMethods.allocateWindowId;
        pub const allocateViewId = WindowStorageMethods.allocateViewId;

        pub const createView = WindowViewRuntimeMethods.createView;
        pub const updateView = WindowViewRuntimeMethods.updateView;
        pub const closeView = WindowViewRuntimeMethods.closeView;
        pub const listViews = WindowViewRuntimeMethods.listViews;
        pub const focusView = WindowViewRuntimeMethods.focusView;
        pub const adoptViewSurface = WindowViewRuntimeMethods.adoptViewSurface;
        pub const releaseViewSurface = WindowViewRuntimeMethods.releaseViewSurface;
        pub const focusNextView = WindowViewRuntimeMethods.focusNextView;
        pub const focusPreviousView = WindowViewRuntimeMethods.focusPreviousView;
        pub const validateWebViewParent = WindowViewRuntimeMethods.validateWebViewParent;
        pub const validateWebViewUrl = WindowViewRuntimeMethods.validateWebViewUrl;
        pub const writeWebViewListJson = WindowViewRuntimeMethods.writeWebViewListJson;
        pub const reserveWebView = WindowViewRuntimeMethods.reserveWebView;
        pub const findWebViewIndex = WindowViewRuntimeMethods.findWebViewIndex;
        pub const webViewLocalFrame = WindowViewRuntimeMethods.webViewLocalFrame;
        pub const removeWebViewAt = WindowViewRuntimeMethods.removeWebViewAt;
        pub const removeWebViewsForWindow = WindowViewRuntimeMethods.removeWebViewsForWindow;
        pub const mainWebViewInfo = WindowViewRuntimeMethods.mainWebViewInfo;
        pub const createWebViewView = WindowViewRuntimeMethods.createWebViewView;
        pub const setMainWebViewParent = WindowViewRuntimeMethods.setMainWebViewParent;
        pub const updateWebViewView = WindowViewRuntimeMethods.updateWebViewView;
        pub const validateViewParent = WindowViewRuntimeMethods.validateViewParent;
        pub const validateViewParentLink = WindowViewRuntimeMethods.validateViewParentLink;
        pub const platformFrameForView = WindowViewRuntimeMethods.platformFrameForView;
        pub const localFrameForView = WindowViewRuntimeMethods.localFrameForView;
        pub const absoluteViewFrame = WindowViewRuntimeMethods.absoluteViewFrame;
        pub const relayoutDescendantWebViewBackends = WindowViewRuntimeMethods.relayoutDescendantWebViewBackends;
        pub const relayoutDescendantWebViewBackendsDepth = WindowViewRuntimeMethods.relayoutDescendantWebViewBackendsDepth;
        pub const reserveView = WindowViewRuntimeMethods.reserveView;
        pub const findViewIndex = WindowViewRuntimeMethods.findViewIndex;
        pub const commandSourceForNativeView = WindowViewRuntimeMethods.commandSourceForNativeView;
        pub const setFocusedView = WindowViewRuntimeMethods.setFocusedView;
        pub const clearFocusedView = WindowViewRuntimeMethods.clearFocusedView;
        pub const ensureFocusableViewFocused = WindowViewRuntimeMethods.ensureFocusableViewFocused;
        pub const focusAdjacentView = WindowViewRuntimeMethods.focusAdjacentView;
        pub const viewLabelExists = WindowViewRuntimeMethods.viewLabelExists;
        pub const removeViewAt = WindowViewRuntimeMethods.removeViewAt;
        pub const removeViewsForWindow = WindowViewRuntimeMethods.removeViewsForWindow;
        pub const removeDescendantViewsForParent = WindowViewRuntimeMethods.removeDescendantViewsForParent;
        pub const removeDescendantWebViewsForParent = WindowViewRuntimeMethods.removeDescendantWebViewsForParent;
        pub const closeDescendantWebViewBackends = WindowViewRuntimeMethods.closeDescendantWebViewBackends;
        pub const closeDescendantWebViewBackendsDepth = WindowViewRuntimeMethods.closeDescendantWebViewBackendsDepth;
        pub const viewTreeHasFocused = WindowViewRuntimeMethods.viewTreeHasFocused;
        pub const viewTreeHasFocusedDepth = WindowViewRuntimeMethods.viewTreeHasFocusedDepth;

        pub fn closeWindow(self: *Runtime, window_id: platform.WindowId) anyerror!void {
            const index = Self.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            // Flip the runtime flag BEFORE the platform call: hosts that
            // run the close delegate synchronously (macOS `performClose`
            // fires `windowWillClose` inline) echo a frame-changed
            // open=false event, and the open->closed TRANSITION — which
            // dispatches the `window_closed` app event — must stay
            // reserved for closes the app did not initiate.
            const was_open = self.windows[index].info.open;
            const was_focused = self.windows[index].info.focused;
            self.windows[index].info.open = false;
            self.windows[index].info.focused = false;
            self.options.platform.services.closeWindow(window_id) catch |err| {
                self.windows[index].info.open = was_open;
                self.windows[index].info.focused = was_focused;
                return err;
            };
            Self.removeWindowRuntimeViews(self, window_id);
            self.invalidated = true;
        }

        /// The real OS minimize verb for a tracked window (app-drawn
        /// window controls on chromeless windows). No runtime
        /// bookkeeping moves: a minimized window stays open and keeps
        /// its views — it comes back from the Dock/taskbar.
        pub fn minimizeWindow(self: *Runtime, window_id: platform.WindowId) anyerror!void {
            if (Self.findWindowIndexById(self, window_id) == null) return error.WindowNotFound;
            try self.options.platform.services.minimizeWindow(window_id);
        }

        pub fn updateWindowState(self: *Runtime, state: platform.WindowState) !void {
            try WindowStorageMethods.updateWindowState(self, state);
            if (!state.open) Self.removeWindowRuntimeViews(self, state.id);
        }

        pub fn createShellWindow(self: *Runtime, shell_window: app_manifest.ShellWindow, source: ?platform.WebViewSource) anyerror!platform.WindowInfo {
            return Self.createShellWindowWithSourceMode(self, shell_window, source, source == null);
        }

        /// A shell window that NEVER hosts the app webview source, even
        /// when one is loaded: the shape for model-declared canvas
        /// windows (UiApp secondary windows), whose whole content is
        /// their gpu_surface view — a hybrid app's loaded source must
        /// not silently materialize a webview under the canvas.
        pub fn createSourcelessShellWindow(self: *Runtime, shell_window: app_manifest.ShellWindow) anyerror!platform.WindowInfo {
            return Self.createShellWindowWithSourcePolicy(self, shell_window, null, false, .never_source);
        }

        pub fn createShellWindowWithSourceMode(self: *Runtime, shell_window: app_manifest.ShellWindow, source: ?platform.WebViewSource, source_reloads_from_app: bool) anyerror!platform.WindowInfo {
            return Self.createShellWindowWithSourcePolicy(self, shell_window, source, source_reloads_from_app, .allow_source_less);
        }

        pub fn createShellWindowWithSourcePolicy(self: *Runtime, shell_window: app_manifest.ShellWindow, source: ?platform.WebViewSource, source_reloads_from_app: bool, source_policy: runtime_state.WindowSourcePolicy) anyerror!platform.WindowInfo {
            const window_frame = geometry.RectF.init(
                shell_window.x orelse 0,
                shell_window.y orelse 0,
                shell_window.width,
                shell_window.height,
            );
            const info = try Self.createWindowWithSourceMode(self, .{
                .label = shell_window.label,
                .title = shell_window.title orelse "",
                .default_frame = window_frame,
                .resizable = shell_window.resizable,
                .restore_state = shell_window.restore_state,
                .restore_policy = shellRestorePolicy(shell_window.restore_policy),
                .titlebar = shell_layout.shellTitlebarStyle(shell_window.titlebar),
                .show = shell_layout.shellWindowShowMode(shell_window),
                .min_width = shell_window.min_width,
                .min_height = shell_window.min_height,
                .source = source,
            }, source_reloads_from_app, source_policy);
            errdefer Self.closeWindow(self, info.id) catch {};

            try Self.createShellViews(self, info.id, shell_window.views, Self.shellBoundsForWindow(self, info.id));
            return info;
        }

        pub fn createShellViews(self: *Runtime, window_id: platform.WindowId, views: []const app_manifest.ShellView, bounds: geometry.RectF) anyerror!void {
            if (views.len > app_manifest.max_shell_views_per_window) return error.ViewLimitReached;
            try Self.validateShellViewCreatePlan(self, window_id, views);

            var main_state: RuntimeMainWebViewState = undefined;
            try Self.captureMainWebViewState(self, window_id, &main_state);
            errdefer Self.restoreMainWebViewState(self, window_id, &main_state) catch {};

            var created_labels: [app_manifest.max_shell_views_per_window][]const u8 = undefined;
            var created_count: usize = 0;
            errdefer Self.rollbackCreatedShellViews(self, window_id, created_labels[0..created_count]);

            try Self.applyShellViews(self, window_id, views, bounds, .create, &created_labels, &created_count);
            try Self.bindShellViews(self, window_id, views);
        }

        pub fn relayoutShellViews(self: *Runtime, window_id: platform.WindowId) anyerror!void {
            const binding = Self.shellLayoutForWindow(self, window_id) orelse return;
            try Self.applyShellViews(self, window_id, binding.viewSlice(), Self.shellBoundsForWindow(self, window_id), .update, null, null);
        }

        pub fn validateShellViewCreatePlan(self: *Runtime, window_id: platform.WindowId, views: []const app_manifest.ShellView) anyerror!void {
            try Self.validateViewParent(self, window_id);

            var native_view_count: usize = 0;
            var child_webview_count: usize = 0;
            for (views, 0..) |view, index| {
                for (views[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.label, view.label)) return error.DuplicateViewLabel;
                }

                if (view.kind == .webview and isMainWebViewLabel(view.label)) continue;
                if (Self.viewLabelExists(self, window_id, view.label)) return error.DuplicateViewLabel;

                if (view.kind == .webview) {
                    child_webview_count += 1;
                } else {
                    native_view_count += 1;
                }
            }

            if (native_view_count > platform.max_views - self.view_count) return error.ViewLimitReached;
            if (child_webview_count > platform.max_webviews - self.webview_count) return error.WebViewLimitReached;
        }

        pub fn applyShellViews(self: *Runtime, window_id: platform.WindowId, views: []const app_manifest.ShellView, bounds: geometry.RectF, mode: ShellApplyMode, tracked_labels: ?*[app_manifest.max_shell_views_per_window][]const u8, tracked_count: ?*usize) anyerror!void {
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
                    const did_create = try Self.applyShellView(self, try shellViewOptions(window_id, view, &layout), mode);
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

        pub fn applyShellView(self: *Runtime, options: platform.ViewOptions, mode: ShellApplyMode) anyerror!bool {
            switch (mode) {
                .create => {
                    if (options.kind == .webview and isMainWebViewLabel(options.label)) {
                        try Self.setMainWebViewParent(self, options.window_id, options.parent);
                        _ = try Self.updateView(self, options.window_id, options.label, .{
                            .frame = options.frame,
                            .layer = options.layer,
                        });
                        return false;
                    }
                    _ = try Self.createView(self, options);
                    return true;
                },
                .update => {
                    if (options.kind == .webview and isMainWebViewLabel(options.label)) {
                        try Self.setMainWebViewParent(self, options.window_id, options.parent);
                    }
                    _ = Self.updateView(self, options.window_id, options.label, .{
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

        pub fn rollbackCreatedShellViews(self: *Runtime, window_id: platform.WindowId, labels: []const []const u8) void {
            var index = labels.len;
            while (index > 0) {
                index -= 1;
                Self.closeView(self, window_id, labels[index]) catch {};
            }
        }

        pub fn captureMainWebViewState(self: *Runtime, window_id: platform.WindowId, state: *RuntimeMainWebViewState) !void {
            const index = Self.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            const window = self.windows[index];
            state.* = .{
                .frame = window.main_frame,
                .frame_set = window.main_frame_set,
                .layer = window.main_layer,
            };
            state.parent = if (window.main_parent) |parent| try copyInto(&state.parent_storage, parent) else null;
        }

        pub fn restoreMainWebViewState(self: *Runtime, window_id: platform.WindowId, state: *const RuntimeMainWebViewState) !void {
            const index = Self.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            const window = self.windows[index];
            var restore_error: ?anyerror = null;

            if (window.source != null) {
                if (window.main_frame_set != state.frame_set or !Self.rectsEqual(window.main_frame, state.frame)) {
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

        pub fn removeWindowRuntimeViews(self: *Runtime, window_id: platform.WindowId) void {
            if (Self.findWindowIndexById(self, window_id)) |index| self.windows[index].main_parent = null;
            Self.removeShellLayoutForWindow(self, window_id);
            Self.removeViewsForWindow(self, window_id);
            Self.removeWebViewsForWindow(self, window_id);
        }
    };
}
