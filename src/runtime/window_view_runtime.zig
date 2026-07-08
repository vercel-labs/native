const std = @import("std");
const geometry = @import("geometry");
const validation = @import("validation.zig");
const runtime_api = @import("api.zig");
const bridge_payload = @import("bridge_payload.zig");
const bridge_responses = @import("bridge_responses.zig");
const runtime_canvas_widget_events = @import("canvas_widget_events.zig");
const runtime_clock = @import("clock.zig");
const runtime_state = @import("state.zig");
const runtime_window_storage = @import("window_storage.zig");
const platform = @import("../platform/root.zig");
const security = @import("../security/root.zig");

const isMainWebViewLabel = validation.isMainWebViewLabel;
const validateChildWebViewLabel = validation.validateChildWebViewLabel;
const validateViewOptions = validation.validateViewOptions;
const validateViewLabel = validation.validateViewLabel;
const validateViewFrame = validation.validateViewFrame;
const isValidWebViewFrame = validation.isValidWebViewFrame;
const validateCommandName = validation.validateCommandName;

const webViewUrlOrigin = bridge_payload.webViewUrlOrigin;
const writeWebViewJsonToWriter = bridge_responses.writeWebViewJsonToWriter;
const viewInfoFromWebView = bridge_responses.viewInfoFromWebView;
const RuntimeWebView = runtime_state.RuntimeWebView;
const FocusTraversalDirection = runtime_state.FocusTraversalDirection;
const sourceWebViewUrl = runtime_state.sourceWebViewUrl;
const nowNanoseconds = runtime_clock.nowNanoseconds;
const timestampToU64 = runtime_clock.timestampToU64;
const CommandSource = runtime_api.CommandSource;

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

fn isFocusableViewInfo(view: platform.ViewInfo) bool {
    return view.open and view.visible and view.enabled;
}

pub fn RuntimeWindowViewRuntime(comptime Runtime: type) type {
    const CanvasWidgetEventMethods = runtime_canvas_widget_events.RuntimeCanvasWidgetEvents(Runtime);
    const WindowStorageMethods = runtime_window_storage.RuntimeWindowStorage(Runtime);

    return struct {
        const Self = @This();

        pub fn createView(self: *Runtime, options: platform.ViewOptions) anyerror!platform.ViewInfo {
            try Self.validateViewParent(self, options.window_id);
            try validateViewOptions(options);
            if (Self.viewLabelExists(self, options.window_id, options.label)) return error.DuplicateViewLabel;
            try Self.validateViewParentLink(self, options.window_id, options.label, options.parent);
            if (options.kind == .webview) return Self.createWebViewView(self, options);
            if (self.view_count >= platform.max_views) return error.ViewLimitReached;

            try self.options.platform.services.createView(options);
            var reserved = false;
            errdefer {
                if (reserved) {
                    if (Self.findViewIndex(self, options.window_id, options.label)) |index| Self.removeViewAt(self, index);
                }
                self.options.platform.services.closeView(options.window_id, options.label) catch {};
            }
            try Self.reserveView(self, options);
            reserved = true;
            self.invalidateFor(.command, options.frame);
            return self.views[self.view_count - 1].info();
        }

        pub fn updateView(self: *Runtime, window_id: platform.WindowId, label: []const u8, patch: platform.ViewPatch) anyerror!platform.ViewInfo {
            try Self.validateViewParent(self, window_id);
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
            if (patch.url != null and !isMainWebViewLabel(label) and Self.findWebViewIndex(self, window_id, label) == null) return error.InvalidViewOptions;

            if (isMainWebViewLabel(label) or Self.findWebViewIndex(self, window_id, label) != null) {
                return Self.updateWebViewView(self, window_id, label, patch);
            }

            const index = Self.findViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            try self.options.platform.services.updateView(window_id, label, patch);
            if (patch.frame) |view_frame| self.views[index].frame = view_frame;
            if (patch.layer) |layer| self.views[index].layer = layer;
            if (patch.visible) |visible| self.views[index].visible = visible;
            if (patch.enabled) |enabled| self.views[index].enabled = enabled;
            if (patch.role) |role| self.views[index].role = try copyInto(&self.views[index].role_storage, role);
            if (patch.accessibility_label) |accessibility_label| self.views[index].accessibility_label = try copyInto(&self.views[index].accessibility_label_storage, accessibility_label);
            if (patch.text) |text| self.views[index].text = try copyInto(&self.views[index].text_storage, text);
            if (patch.command) |command| self.views[index].command = try copyInto(&self.views[index].command_storage, command);
            if (patch.frame != null) try Self.relayoutDescendantWebViewBackends(self, window_id, label);
            self.invalidateFor(.command, patch.frame);
            if (self.views[index].focused and !isFocusableViewInfo(self.views[index].info())) {
                Self.ensureFocusableViewFocused(self, window_id);
            }
            return self.views[index].info();
        }

        pub fn closeView(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!void {
            try Self.validateViewParent(self, window_id);
            try validateViewLabel(label);
            if (isMainWebViewLabel(label)) return error.InvalidViewOptions;

            if (Self.findWebViewIndex(self, window_id, label)) |webview_index| {
                const was_focused = self.webviews[webview_index].focused;
                try self.options.platform.services.closeWebView(window_id, label);
                Self.removeWebViewAt(self, webview_index);
                if (was_focused) Self.ensureFocusableViewFocused(self, window_id);
                self.invalidateFor(.command, null);
                return;
            }

            _ = Self.findViewIndex(self, window_id, label) orelse return error.ViewNotFound;
            const was_focused = Self.viewTreeHasFocused(self, window_id, label);
            try Self.closeDescendantWebViewBackends(self, window_id, label);
            try self.options.platform.services.closeView(window_id, label);
            Self.removeDescendantViewsForParent(self, window_id, label);
            Self.removeDescendantWebViewsForParent(self, window_id, label);
            if (Self.findViewIndex(self, window_id, label)) |current_index| Self.removeViewAt(self, current_index);
            if (was_focused) Self.ensureFocusableViewFocused(self, window_id);
            self.invalidateFor(.command, null);
        }

        pub fn listViews(self: *const Runtime, window_id: platform.WindowId, output: []platform.ViewInfo) []const platform.ViewInfo {
            const window_index = WindowStorageMethods.findWindowIndexById(self, window_id) orelse return output[0..0];
            if (!self.windows[window_index].info.open) return output[0..0];

            var count: usize = 0;
            if (self.windows[window_index].source != null and count < output.len) {
                output[count] = viewInfoFromWebView(Self.mainWebViewInfo(self, window_index));
                count += 1;
            }
            for (self.views[0..self.view_count]) |*view| {
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
            try Self.validateViewParent(self, window_id);
            try validateViewLabel(label);
            if (!Self.viewLabelExists(self, window_id, label)) return error.ViewNotFound;
            try self.options.platform.services.focusView(window_id, label);
            try Self.setFocusedView(self, window_id, label);
            self.invalidateFor(.command, null);
        }

        /// Native-surface adoption: install an app-owned platform view
        /// handle (macOS: an NSView* — a `VZVirtualMachineView`, an
        /// `MKMapView`) as the fill content of an existing NATIVE view.
        /// The container keeps participating in shell layout; the platform
        /// keeps the adopted surface sized to it. Webview-backed labels
        /// reject — a webview already owns its backing view. Platforms
        /// without the capability reject with `error.UnsupportedService`
        /// (`supports(.view_surface_adoption)` is the honest pre-check).
        pub fn adoptViewSurface(self: *Runtime, window_id: platform.WindowId, label: []const u8, surface_handle: *anyopaque) anyerror!void {
            try Self.validateViewParent(self, window_id);
            try validateViewLabel(label);
            if (isMainWebViewLabel(label) or Self.findWebViewIndex(self, window_id, label) != null) return error.InvalidViewOptions;
            if (Self.findViewIndex(self, window_id, label) == null) return error.ViewNotFound;
            try self.options.platform.services.adoptViewSurface(window_id, label, surface_handle);
            self.invalidateFor(.command, null);
        }

        /// Remove an adopted surface from its container; the app-owned
        /// platform view stays alive for the caller to reuse.
        pub fn releaseViewSurface(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!void {
            try Self.validateViewParent(self, window_id);
            try validateViewLabel(label);
            if (Self.findViewIndex(self, window_id, label) == null) return error.ViewNotFound;
            try self.options.platform.services.releaseViewSurface(window_id, label);
            self.invalidateFor(.command, null);
        }

        pub fn focusNextView(self: *Runtime, window_id: platform.WindowId) anyerror!platform.ViewInfo {
            return Self.focusAdjacentView(self, window_id, .next);
        }

        pub fn focusPreviousView(self: *Runtime, window_id: platform.WindowId) anyerror!platform.ViewInfo {
            return Self.focusAdjacentView(self, window_id, .previous);
        }

        pub fn validateWebViewParent(self: *Runtime, window_id: platform.WindowId) !void {
            const index = WindowStorageMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            if (!self.windows[index].info.open) return error.WindowNotFound;
        }

        pub fn validateWebViewUrl(self: *Runtime, url: []const u8) !void {
            if (url.len == 0) return error.MissingWebViewUrl;
            if (url.len > platform.max_webview_url_bytes) return error.WebViewUrlTooLarge;
            var origin_buffer: [512]u8 = undefined;
            const origin = try webViewUrlOrigin(url, &origin_buffer);
            if (!security.allowsOrigin(self.options.security.navigation.allowed_origins, origin)) return error.NavigationDenied;
        }

        pub fn writeWebViewListJson(self: *Runtime, source_window_id: platform.WindowId, output: []u8) ![]const u8 {
            try Self.validateWebViewParent(self, source_window_id);
            var writer = std.Io.Writer.fixed(output);
            try writer.writeByte('[');
            const window_index = WindowStorageMethods.findWindowIndexById(self, source_window_id) orelse return error.WindowNotFound;
            try writeWebViewJsonToWriter(Self.mainWebViewInfo(self, window_index), &writer);
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

        pub fn reserveWebView(self: *Runtime, id: platform.ViewId, window_id: platform.WindowId, label: []const u8, parent: ?[]const u8, url: []const u8, local_frame: geometry.RectF, platform_frame: geometry.RectF, layer: i32, transparent: bool, bridge_enabled: bool) !void {
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

        pub fn findWebViewIndex(self: *const Runtime, window_id: platform.WindowId, label: []const u8) ?usize {
            for (self.webviews[0..self.webview_count], 0..) |webview, index| {
                if (webview.open and webview.window_id == window_id and std.mem.eql(u8, webview.label, label)) return index;
            }
            return null;
        }

        /// The current parent-local frame of a child webview, as last
        /// applied by the runtime (shell relayout or view patches). Null
        /// when no such webview exists. Lets frame owners above the
        /// runtime (`UiApp` webview panes) reconcile against the actual
        /// state instead of a cache a shell relayout can silently stomp.
        pub fn webViewLocalFrame(self: *const Runtime, window_id: platform.WindowId, label: []const u8) ?geometry.RectF {
            const index = Self.findWebViewIndex(self, window_id, label) orelse return null;
            return self.webviews[index].local_frame;
        }

        pub fn removeWebViewAt(self: *Runtime, index: usize) void {
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

        pub fn removeWebViewsForWindow(self: *Runtime, window_id: platform.WindowId) void {
            var index: usize = 0;
            while (index < self.webview_count) {
                if (self.webviews[index].window_id == window_id) {
                    Self.removeWebViewAt(self, index);
                } else {
                    index += 1;
                }
            }
        }

        pub fn mainWebViewInfo(self: *const Runtime, window_index: usize) RuntimeWebView {
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

        pub fn createWebViewView(self: *Runtime, options: platform.ViewOptions) !platform.ViewInfo {
            try validateChildWebViewLabel(options.label);
            try Self.validateWebViewUrl(self, options.url);
            if (!isValidWebViewFrame(options.frame)) return error.InvalidWebViewOptions;
            if (self.webview_count >= platform.max_webviews) return error.WebViewLimitReached;
            var platform_options = options;
            platform_options.frame = try Self.platformFrameForView(self, options.window_id, options.parent, options.frame);
            try self.options.platform.services.createView(platform_options);
            var reserved = false;
            errdefer {
                if (reserved) {
                    if (Self.findWebViewIndex(self, options.window_id, options.label)) |index| Self.removeWebViewAt(self, index);
                }
                self.options.platform.services.closeView(options.window_id, options.label) catch {};
            }
            try Self.reserveWebView(self, WindowStorageMethods.allocateViewId(self), options.window_id, options.label, options.parent, options.url, options.frame, platform_options.frame, options.layer, options.transparent, options.bridge_enabled);
            reserved = true;
            self.invalidateFor(.command, platform_options.frame);
            return viewInfoFromWebView(self.webviews[self.webview_count - 1]);
        }

        pub fn setMainWebViewParent(self: *Runtime, window_id: platform.WindowId, parent: ?[]const u8) !void {
            const index = WindowStorageMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            self.windows[index].main_parent = if (parent) |value| try copyInto(&self.windows[index].main_parent_storage, value) else null;
        }

        pub fn updateWebViewView(self: *Runtime, window_id: platform.WindowId, label: []const u8, patch: platform.ViewPatch) !platform.ViewInfo {
            if (patch.visible != null or patch.enabled != null or patch.role != null or patch.accessibility_label != null or patch.text != null or patch.command != null) return error.InvalidViewOptions;
            if (isMainWebViewLabel(label)) {
                const window_index = WindowStorageMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
                if (patch.url != null) return error.InvalidViewOptions;
                if (patch.frame) |view_frame| {
                    if (!isValidWebViewFrame(view_frame)) return error.InvalidWebViewOptions;
                    if (self.windows[window_index].source != null) {
                        try self.options.platform.services.setWebViewFrame(window_id, label, view_frame);
                    }
                    self.windows[window_index].main_frame = view_frame;
                    self.windows[window_index].main_frame_set = true;
                    try Self.relayoutDescendantWebViewBackends(self, window_id, label);
                }
                if (patch.layer) |layer| {
                    if (self.windows[window_index].source != null) {
                        try self.options.platform.services.setWebViewLayer(window_id, label, layer);
                    }
                    self.windows[window_index].main_layer = layer;
                }
                self.invalidateFor(.command, patch.frame);
                return viewInfoFromWebView(Self.mainWebViewInfo(self, window_index));
            }

            const webview_index = Self.findWebViewIndex(self, window_id, label) orelse return error.WebViewNotFound;
            if (patch.frame) |view_frame| {
                if (!isValidWebViewFrame(view_frame)) return error.InvalidWebViewOptions;
                const platform_frame = try Self.platformFrameForView(self, window_id, self.webviews[webview_index].parent, view_frame);
                try self.options.platform.services.setWebViewFrame(window_id, label, platform_frame);
                self.webviews[webview_index].local_frame = view_frame;
                self.webviews[webview_index].frame = platform_frame;
                try Self.relayoutDescendantWebViewBackends(self, window_id, label);
            }
            if (patch.layer) |layer| {
                try self.options.platform.services.setWebViewLayer(window_id, label, layer);
                self.webviews[webview_index].layer = layer;
            }
            if (patch.url) |url| {
                try Self.validateWebViewUrl(self, url);
                try self.options.platform.services.navigateWebView(window_id, label, url);
                self.webviews[webview_index].url = try copyInto(&self.webviews[webview_index].url_storage, url);
            }
            self.invalidateFor(.command, patch.frame);
            return viewInfoFromWebView(self.webviews[webview_index]);
        }

        pub fn validateViewParent(self: *const Runtime, window_id: platform.WindowId) !void {
            const index = WindowStorageMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            if (!self.windows[index].info.open) return error.WindowNotFound;
        }

        pub fn validateViewParentLink(self: *const Runtime, window_id: platform.WindowId, label: []const u8, parent: ?[]const u8) !void {
            const parent_label = parent orelse return;
            if (std.mem.eql(u8, parent_label, label)) return error.InvalidViewOptions;
            if (!Self.viewLabelExists(self, window_id, parent_label)) return error.ViewNotFound;
        }

        pub fn platformFrameForView(self: *const Runtime, window_id: platform.WindowId, parent: ?[]const u8, base_frame: geometry.RectF) !geometry.RectF {
            var platform_frame = base_frame;
            if (parent) |parent_label| {
                const parent_frame = try Self.absoluteViewFrame(self, window_id, parent_label, 0);
                platform_frame.x += parent_frame.x;
                platform_frame.y += parent_frame.y;
            }
            return platform_frame;
        }

        pub fn localFrameForView(self: *const Runtime, window_id: platform.WindowId, parent: ?[]const u8, base_frame: geometry.RectF) !geometry.RectF {
            var local_frame = base_frame;
            if (parent) |parent_label| {
                const parent_frame = try Self.absoluteViewFrame(self, window_id, parent_label, 0);
                local_frame.x -= parent_frame.x;
                local_frame.y -= parent_frame.y;
            }
            return local_frame;
        }

        pub fn absoluteViewFrame(self: *const Runtime, window_id: platform.WindowId, label: []const u8, depth: usize) !geometry.RectF {
            if (depth >= platform.max_views + platform.max_webviews + 1) return error.InvalidViewOptions;
            if (isMainWebViewLabel(label)) {
                const window_index = WindowStorageMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
                return Self.mainWebViewInfo(self, window_index).frame;
            }
            if (Self.findViewIndex(self, window_id, label)) |index| {
                var absolute_frame = self.views[index].frame;
                if (self.views[index].parent) |parent| {
                    const parent_frame = try Self.absoluteViewFrame(self, window_id, parent, depth + 1);
                    absolute_frame.x += parent_frame.x;
                    absolute_frame.y += parent_frame.y;
                }
                return absolute_frame;
            }
            if (Self.findWebViewIndex(self, window_id, label)) |index| {
                return self.webviews[index].frame;
            }
            return error.ViewNotFound;
        }

        pub fn relayoutDescendantWebViewBackends(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8) !void {
            try Self.relayoutDescendantWebViewBackendsDepth(self, window_id, parent_label, 0);
        }

        pub fn relayoutDescendantWebViewBackendsDepth(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8, depth: usize) !void {
            if (depth >= platform.max_views + platform.max_webviews) return;
            for (self.views[0..self.view_count]) |*view| {
                if (view.window_id != window_id) continue;
                const parent = view.parent orelse continue;
                if (std.mem.eql(u8, parent, parent_label)) {
                    try Self.relayoutDescendantWebViewBackendsDepth(self, window_id, view.label, depth + 1);
                }
            }
            for (self.webviews[0..self.webview_count], 0..) |webview, index| {
                if (webview.window_id != window_id) continue;
                const parent = webview.parent orelse continue;
                if (std.mem.eql(u8, parent, parent_label)) {
                    const platform_frame = try Self.platformFrameForView(self, window_id, webview.parent, webview.local_frame);
                    try self.options.platform.services.setWebViewFrame(window_id, webview.label, platform_frame);
                    self.webviews[index].frame = platform_frame;
                    try Self.relayoutDescendantWebViewBackendsDepth(self, window_id, webview.label, depth + 1);
                }
            }
        }

        pub fn reserveView(self: *Runtime, options: platform.ViewOptions) !void {
            const index = self.view_count;
            self.views[index] = .{
                .id = WindowStorageMethods.allocateViewId(self),
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

        pub fn findViewIndex(self: *const Runtime, window_id: platform.WindowId, label: []const u8) ?usize {
            for (self.views[0..self.view_count], 0..) |*view, index| {
                if (view.open and view.window_id == window_id and std.mem.eql(u8, view.label, label)) return index;
            }
            return null;
        }

        pub fn commandSourceForNativeView(self: *const Runtime, window_id: platform.WindowId, label: []const u8) CommandSource {
            const index = Self.findViewIndex(self, window_id, label) orelse return .native_view;
            // Walk by POINTER: a View embeds its widget storage, so a
            // by-value copy here is megabytes of stack — more than a
            // mobile main thread has (iOS caps it at 1MB, and this runs
            // on the host's display-link tick via automation commands).
            var view = &self.views[index];
            var depth: usize = 0;
            while (depth < platform.max_views) : (depth += 1) {
                if (view.kind == .toolbar) return .toolbar;
                const parent_label = view.parent orelse return .native_view;
                const parent_index = Self.findViewIndex(self, window_id, parent_label) orelse return .native_view;
                view = &self.views[parent_index];
            }
            return .native_view;
        }

        pub fn setFocusedView(self: *Runtime, window_id: platform.WindowId, label: []const u8) anyerror!void {
            if (WindowStorageMethods.findWindowIndexById(self, window_id)) |window_index| {
                self.windows[window_index].main_focused = std.mem.eql(u8, label, "main");
            }
            for (self.views[0..self.view_count], 0..) |*view, view_index| {
                if (view.window_id != window_id) continue;
                const previous_state = view.canvasWidgetRenderState();
                view.focused = std.mem.eql(u8, view.label, label);
                const next_state = view.canvasWidgetRenderState();
                if (!CanvasWidgetEventMethods.canvasWidgetRenderStatesEqual(previous_state, next_state)) {
                    try CanvasWidgetEventMethods.invalidateForCanvasWidgetRenderStateChange(self, view_index, previous_state, next_state);
                }
            }
            for (self.webviews[0..self.webview_count]) |*webview| {
                if (webview.window_id == window_id) webview.focused = std.mem.eql(u8, webview.label, label);
            }
        }

        pub fn clearFocusedView(self: *Runtime, window_id: platform.WindowId) anyerror!void {
            if (WindowStorageMethods.findWindowIndexById(self, window_id)) |window_index| {
                self.windows[window_index].main_focused = false;
            }
            for (self.views[0..self.view_count], 0..) |*view, view_index| {
                if (view.window_id != window_id) continue;
                const previous_state = view.canvasWidgetRenderState();
                view.focused = false;
                const next_state = view.canvasWidgetRenderState();
                if (!CanvasWidgetEventMethods.canvasWidgetRenderStatesEqual(previous_state, next_state)) {
                    try CanvasWidgetEventMethods.invalidateForCanvasWidgetRenderStateChange(self, view_index, previous_state, next_state);
                }
            }
            for (self.webviews[0..self.webview_count]) |*webview| {
                if (webview.window_id == window_id) webview.focused = false;
            }
        }

        pub fn ensureFocusableViewFocused(self: *Runtime, window_id: platform.WindowId) void {
            var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
            const views = Self.listViews(self, window_id, &views_buffer);
            var first_focusable: ?[]const u8 = null;
            for (views) |view| {
                if (!isFocusableViewInfo(view)) continue;
                if (first_focusable == null) first_focusable = view.label;
                if (view.focused) return;
            }
            if (first_focusable) |label| {
                Self.focusView(self, window_id, label) catch {
                    Self.clearFocusedView(self, window_id) catch {};
                };
            } else {
                Self.clearFocusedView(self, window_id) catch {};
            }
        }

        pub fn focusAdjacentView(self: *Runtime, window_id: platform.WindowId, direction: FocusTraversalDirection) anyerror!platform.ViewInfo {
            try Self.validateViewParent(self, window_id);

            var views_buffer: [platform.max_views + platform.max_webviews + 1]platform.ViewInfo = undefined;
            const views = Self.listViews(self, window_id, &views_buffer);
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
            try Self.focusView(self, window_id, target.label);

            var focused = target;
            focused.focused = true;
            return focused;
        }

        pub fn viewLabelExists(self: *const Runtime, window_id: platform.WindowId, label: []const u8) bool {
            if (isMainWebViewLabel(label) and WindowStorageMethods.findWindowIndexById(self, window_id) != null) return true;
            return Self.findViewIndex(self, window_id, label) != null or Self.findWebViewIndex(self, window_id, label) != null;
        }

        pub fn removeViewAt(self: *Runtime, index: usize) void {
            if (index >= self.view_count) return;
            var cursor = index;
            while (cursor + 1 < self.view_count) : (cursor += 1) {
                const next = &self.views[cursor + 1];
                self.views[cursor].copyRuntimeStateFrom(next, &self.canvas_widget_copy_scratch);
            }
            self.view_count -= 1;
        }

        pub fn removeViewsForWindow(self: *Runtime, window_id: platform.WindowId) void {
            var index: usize = 0;
            while (index < self.view_count) {
                if (self.views[index].window_id == window_id) {
                    Self.removeViewAt(self, index);
                } else {
                    index += 1;
                }
            }
        }

        pub fn removeDescendantViewsForParent(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8) void {
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
                Self.removeDescendantViewsForParent(self, window_id, child_label);
                Self.removeDescendantWebViewsForParent(self, window_id, child_label);
                if (Self.findViewIndex(self, window_id, child_label)) |child_index| Self.removeViewAt(self, child_index);
                index = 0;
            }
        }

        pub fn removeDescendantWebViewsForParent(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8) void {
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
                Self.removeDescendantViewsForParent(self, window_id, child_label);
                Self.removeDescendantWebViewsForParent(self, window_id, child_label);
                if (Self.findWebViewIndex(self, window_id, child_label)) |child_index| Self.removeWebViewAt(self, child_index);
                index = 0;
            }
        }

        pub fn closeDescendantWebViewBackends(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8) !void {
            try Self.closeDescendantWebViewBackendsDepth(self, window_id, parent_label, 0);
        }

        pub fn closeDescendantWebViewBackendsDepth(self: *Runtime, window_id: platform.WindowId, parent_label: []const u8, depth: usize) !void {
            if (depth >= platform.max_views + platform.max_webviews) return;
            for (self.views[0..self.view_count]) |*view| {
                if (view.window_id != window_id) continue;
                const parent = view.parent orelse continue;
                if (std.mem.eql(u8, parent, parent_label)) {
                    try Self.closeDescendantWebViewBackendsDepth(self, window_id, view.label, depth + 1);
                }
            }
            for (self.webviews[0..self.webview_count]) |webview| {
                if (webview.window_id != window_id) continue;
                const parent = webview.parent orelse continue;
                if (std.mem.eql(u8, parent, parent_label)) {
                    try Self.closeDescendantWebViewBackendsDepth(self, window_id, webview.label, depth + 1);
                    try self.options.platform.services.closeWebView(window_id, webview.label);
                }
            }
        }

        pub fn viewTreeHasFocused(self: *const Runtime, window_id: platform.WindowId, label: []const u8) bool {
            return Self.viewTreeHasFocusedDepth(self, window_id, label, 0);
        }

        pub fn viewTreeHasFocusedDepth(self: *const Runtime, window_id: platform.WindowId, label: []const u8, depth: usize) bool {
            if (depth >= platform.max_views + platform.max_webviews) return false;
            if (Self.findViewIndex(self, window_id, label)) |index| {
                if (self.views[index].focused) return true;
            }
            if (Self.findWebViewIndex(self, window_id, label)) |index| {
                if (self.webviews[index].focused) return true;
            }
            for (self.views[0..self.view_count]) |*view| {
                if (view.window_id != window_id) continue;
                const parent = view.parent orelse continue;
                if (std.mem.eql(u8, parent, label) and Self.viewTreeHasFocusedDepth(self, window_id, view.label, depth + 1)) return true;
            }
            for (self.webviews[0..self.webview_count]) |webview| {
                if (webview.window_id != window_id) continue;
                const parent = webview.parent orelse continue;
                if (std.mem.eql(u8, parent, label) and Self.viewTreeHasFocusedDepth(self, window_id, webview.label, depth + 1)) return true;
            }
            return false;
        }
    };
}
