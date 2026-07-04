const std = @import("std");
const geometry = @import("geometry");
const validation = @import("validation.zig");
const shell_layout = @import("shell_layout.zig");
const runtime_state = @import("state.zig");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");

const validateWindowFrame = validation.validateWindowFrame;
const WindowSourcePolicy = runtime_state.WindowSourcePolicy;
const copySourceInto = runtime_state.copySourceInto;
const RuntimeShellLayout = shell_layout.RuntimeShellLayout;
const combinedViewportInsets = shell_layout.combinedViewportInsets;

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

pub fn RuntimeWindowStorage(comptime Runtime: type) type {
    return struct {
        const Self = @This();

        pub fn createWindow(self: *Runtime, options: platform.WindowCreateOptions) anyerror!platform.WindowInfo {
            return Self.createWindowWithSourceMode(self, options, options.source == null, .require_source);
        }

        pub fn listWindows(self: *const Runtime, output: []platform.WindowInfo) []const platform.WindowInfo {
            const count = @min(output.len, self.window_count);
            for (self.windows[0..count], 0..) |window, index| {
                output[index] = window.info;
            }
            return output[0..count];
        }

        pub fn focusWindow(self: *Runtime, window_id: platform.WindowId) anyerror!void {
            const index = Self.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            try self.options.platform.services.focusWindow(window_id);
            Self.setFocusedIndex(self, index);
            self.invalidated = true;
        }

        pub fn createWindowWithSourceMode(self: *Runtime, options: platform.WindowCreateOptions, source_reloads_from_app: bool, source_policy: WindowSourcePolicy) anyerror!platform.WindowInfo {
            const source: ?platform.WebViewSource = switch (source_policy) {
                .never_source => null,
                .require_source => options.source orelse self.loaded_source orelse return error.MissingWindowSource,
                .allow_source_less => options.source orelse self.loaded_source,
            };
            const label = if (options.label.len > 0) options.label else return error.InvalidWindowOptions;
            // A CLOSED window releases its label (and id) for
            // re-creation: model-driven windows open, close, and reopen
            // under one stable label, and the retained slot of a closed
            // window must not brick the reopen with a duplicate error.
            // Open windows still collide loudly below.
            if (Self.findWindowIndexByLabel(self, label)) |index| {
                if (!self.windows[index].info.open) Self.removeWindowAt(self, index);
            }
            if (options.id != 0) {
                if (Self.findWindowIndexById(self, options.id)) |index| {
                    if (!self.windows[index].info.open) Self.removeWindowAt(self, index);
                }
            }
            const id = if (options.id != 0) options.id else Self.allocateWindowId(self);
            try validateWindowFrame(options.default_frame);
            if (Self.findWindowIndexById(self, id) != null) return error.DuplicateWindowId;
            if (Self.findWindowIndexByLabel(self, label) != null) return error.DuplicateWindowLabel;
            const index = try Self.reserveWindow(self, id, label, options.title, source, source_reloads_from_app);
            var native_created = false;
            errdefer Self.removeWindowAt(self, index);
            errdefer if (native_created) self.options.platform.services.closeWindow(id) catch {};

            const window_options = options.windowOptions(id, self.windows[index].info.label);
            const native_info = try self.options.platform.services.createWindow(window_options);
            native_created = true;
            Self.applyNativeInfo(self, index, native_info);
            if (self.windows[index].source) |window_source| {
                try self.options.platform.services.loadWindowWebView(id, window_source);
            }
            self.invalidated = true;
            return self.windows[index].info;
        }

        pub fn reserveWindow(self: *Runtime, id: platform.WindowId, label: []const u8, title: []const u8, source: ?platform.WebViewSource, source_reloads_from_app: bool) !usize {
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
            self.windows[index].main_view_id = Self.allocateViewId(self);
            self.windows[index].source = if (source) |source_value| try Self.copySource(self, index, source_value) else null;
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

        pub fn removeWindowAt(self: *Runtime, index: usize) void {
            if (index >= self.window_count) return;
            Self.removeShellLayoutForWindow(self, self.windows[index].info.id);
            var cursor = index;
            while (cursor + 1 < self.window_count) : (cursor += 1) {
                self.windows[cursor] = self.windows[cursor + 1];
            }
            self.window_count -= 1;
        }

        pub fn copySource(self: *Runtime, index: usize, source: platform.WebViewSource) !platform.WebViewSource {
            return copySourceInto(&self.windows[index].source_storage, source);
        }

        pub fn copyLoadedSource(self: *Runtime, source: platform.WebViewSource) !platform.WebViewSource {
            return copySourceInto(&self.loaded_source_storage, source);
        }

        pub fn applyNativeInfo(self: *Runtime, index: usize, native_info: platform.WindowInfo) void {
            self.windows[index].info.frame = native_info.frame;
            self.windows[index].info.scale_factor = native_info.scale_factor;
            self.windows[index].info.open = native_info.open;
            self.windows[index].info.focused = native_info.focused;
            if (!self.windows[index].main_frame_set) {
                self.windows[index].main_frame = geometry.RectF.init(0, 0, native_info.frame.width, native_info.frame.height);
            }
            if (native_info.focused) Self.setFocusedIndex(self, index);
        }

        pub fn updateWindowState(self: *Runtime, state: platform.WindowState) !void {
            const existing_index = Self.findWindowIndexById(self, state.id);
            const index = existing_index orelse try Self.reserveWindow(self, state.id, state.label, state.title, null, true);
            var info = self.windows[index].info;
            info.frame = state.frame;
            info.scale_factor = state.scale_factor;
            info.open = state.open;
            info.focused = state.focused;
            self.windows[index].info = info;
            if (!self.windows[index].main_frame_set) {
                self.windows[index].main_frame = geometry.RectF.init(0, 0, state.frame.width, state.frame.height);
            }
            if (state.focused) Self.setFocusedIndex(self, index);
        }

        pub fn runtimeWindowStateForPersistence(self: *const Runtime, state: platform.WindowState) platform.WindowState {
            var persisted = state;
            if (Self.findWindowIndexById(self, state.id)) |index| {
                persisted.label = self.windows[index].info.label;
                persisted.title = self.windows[index].info.title;
            }
            return persisted;
        }

        pub fn shellBoundsForWindow(self: *const Runtime, window_id: platform.WindowId) geometry.RectF {
            const index = Self.findWindowIndexById(self, window_id) orelse return geometry.RectF.init(0, 0, 0, 0);
            const frame_value = self.windows[index].info.frame;
            const bounds = geometry.RectF.init(0, 0, frame_value.width, frame_value.height);
            if (self.surface.id != window_id) return bounds;
            return bounds.deflate(combinedViewportInsets(self.surface));
        }

        pub fn startupWindowFrame(native_frame: geometry.RectF, manifest_frame: geometry.RectF) geometry.RectF {
            const default_frame = (platform.WindowOptions{}).default_frame;
            if (!Self.rectsEqual(native_frame, default_frame)) return native_frame;
            return manifest_frame;
        }

        pub fn rectsEqual(a: geometry.RectF, b: geometry.RectF) bool {
            return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
        }

        pub fn canvasDirtyRegionForView(view_frame: geometry.RectF, local_dirty: geometry.RectF) ?geometry.RectF {
            const normalized_view = view_frame.normalized();
            const surface_bounds = geometry.RectF.init(0, 0, normalized_view.width, normalized_view.height);
            const clipped = geometry.RectF.intersection(surface_bounds, local_dirty.normalized());
            if (clipped.isEmpty()) return null;
            return clipped.translate(.{ .dx = normalized_view.x, .dy = normalized_view.y });
        }

        pub fn bindShellViews(self: *Runtime, window_id: platform.WindowId, views: []const app_manifest.ShellView) !void {
            if (Self.findShellLayoutIndex(self, window_id)) |index| {
                try self.shell_layouts[index].copyViews(views);
                return;
            }
            if (self.shell_layout_count >= self.shell_layouts.len) return error.WindowLimitReached;
            self.shell_layouts[self.shell_layout_count].window_id = window_id;
            try self.shell_layouts[self.shell_layout_count].copyViews(views);
            self.shell_layout_count += 1;
        }

        pub fn shellLayoutForWindow(self: *const Runtime, window_id: platform.WindowId) ?*const RuntimeShellLayout {
            const index = Self.findShellLayoutIndex(self, window_id) orelse return null;
            return &self.shell_layouts[index];
        }

        pub fn findShellLayoutIndex(self: *const Runtime, window_id: platform.WindowId) ?usize {
            for (self.shell_layouts[0..self.shell_layout_count], 0..) |layout, index| {
                if (layout.window_id == window_id) return index;
            }
            return null;
        }

        pub fn removeShellLayoutForWindow(self: *Runtime, window_id: platform.WindowId) void {
            const index = Self.findShellLayoutIndex(self, window_id) orelse return;
            var cursor = index;
            while (cursor + 1 < self.shell_layout_count) : (cursor += 1) {
                self.shell_layouts[cursor] = self.shell_layouts[cursor + 1];
            }
            self.shell_layout_count -= 1;
        }

        pub fn setFocusedIndex(self: *Runtime, focused_index: usize) void {
            for (self.windows[0..self.window_count], 0..) |*window, index| {
                window.info.focused = index == focused_index;
            }
        }

        pub fn findWindowIndexById(self: *const Runtime, id: platform.WindowId) ?usize {
            for (self.windows[0..self.window_count], 0..) |window, index| {
                if (window.info.id == id) return index;
            }
            return null;
        }

        pub fn findWindowIndexByLabel(self: *const Runtime, label: []const u8) ?usize {
            for (self.windows[0..self.window_count], 0..) |window, index| {
                if (std.mem.eql(u8, window.info.label, label)) return index;
            }
            return null;
        }

        pub fn allocateWindowId(self: *Runtime) platform.WindowId {
            while (Self.findWindowIndexById(self, self.next_window_id) != null) self.next_window_id += 1;
            const id = self.next_window_id;
            self.next_window_id += 1;
            return id;
        }

        pub fn allocateViewId(self: *Runtime) platform.ViewId {
            const id = self.next_view_id;
            self.next_view_id += 1;
            return id;
        }
    };
}
