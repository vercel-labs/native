const std = @import("std");
const geometry = @import("geometry");
const trace = @import("trace");
const json = @import("json");
const automation = @import("../automation/root.zig");
const bridge = @import("../bridge/root.zig");
const extensions = @import("../extensions/root.zig");
const platform = @import("../platform/root.zig");
const security = @import("../security/root.zig");
const window_state = @import("../window_state/root.zig");

pub const LifecycleEvent = enum {
    start,
    frame,
    stop,
};

pub const CommandEvent = struct {
    name: []const u8,
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
    command: CommandEvent,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .lifecycle => |event_value| @tagName(event_value),
            .command => |event_value| event_value.name,
        };
    }
};

const StartFn = *const fn (context: *anyopaque, runtime: *Runtime) anyerror!void;
const EventFn = *const fn (context: *anyopaque, runtime: *Runtime, event: Event) anyerror!void;
const SourceFn = *const fn (context: *anyopaque) anyerror!platform.WebViewSource;
const StopFn = *const fn (context: *anyopaque, runtime: *Runtime) anyerror!void;

pub const App = struct {
    context: *anyopaque,
    name: []const u8,
    source: platform.WebViewSource,
    source_fn: ?SourceFn = null,
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
    automation: ?automation.Server = null,
    window_state_store: ?window_state.Store = null,
    js_window_api: bool = false,
};

pub const Runtime = struct {
    options: Options,
    surface: platform.Surface,
    windows: [platform.max_windows]RuntimeWindow = undefined,
    window_count: usize = 0,
    webviews: [platform.max_webviews]RuntimeWebView = undefined,
    webview_count: usize = 0,
    next_window_id: platform.WindowId = 2,
    invalidated: bool = true,
    timestamp_ns: i128 = 0,
    frame_index: u64 = 0,
    command_count: usize = 0,
    dirty_regions: [8]geometry.RectF = undefined,
    dirty_region_count: usize = 0,
    last_invalidation_reason: InvalidationReason = .startup,
    last_diagnostics: FrameDiagnostics = .{},
    loaded_source: ?platform.WebViewSource = null,
    automation_windows: [automation.snapshot.max_windows]automation.snapshot.Window = undefined,

    pub fn init(options: Options) Runtime {
        var runtime = Runtime{
            .options = options,
            .surface = options.platform.surface(),
        };
        runtime.windows = undefined;
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
        try self.options.platform.services.configureSecurityPolicy(self.options.security);

        var context: RunContext = .{ .runtime = self, .app = app };
        try self.options.platform.run(handlePlatformEvent, &context);

        try self.log("runtime.done", "runtime finished", &.{});
    }

    pub fn createWindow(self: *Runtime, options: platform.WindowCreateOptions) anyerror!platform.WindowInfo {
        const source = options.source orelse self.loaded_source orelse return error.MissingWindowSource;
        const id = if (options.id != 0) options.id else self.allocateWindowId();
        const label = if (options.label.len > 0) options.label else return error.InvalidWindowOptions;
        if (self.findWindowIndexById(id) != null) return error.DuplicateWindowId;
        if (self.findWindowIndexByLabel(label) != null) return error.DuplicateWindowLabel;
        const index = try self.reserveWindow(id, label, options.title, source);
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
        self.removeWebViewsForWindow(window_id);
        self.invalidated = true;
    }

    pub fn emitWindowEvent(self: *Runtime, window_id: platform.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
        if (!json.isValidValue(detail_json)) return error.InvalidJsonEventDetail;
        try self.options.platform.services.emitWindowEvent(window_id, name, detail_json);
    }

    pub fn respondToBridge(self: *Runtime, source: bridge.Source, response: []const u8) anyerror!void {
        try self.completeBridgeResponse(source.window_id, source.webview_label, response);
    }

    pub fn dispatchPlatformEvent(self: *Runtime, app: App, event_value: platform.Event) anyerror!void {
        if (event_value != .frame_requested or self.invalidated) {
            const event_fields = [_]trace.Field{trace.string("event", event_value.name())};
            try self.log("platform.event", null, &event_fields);
        }

        switch (event_value) {
            .app_start => {
                try app.start(self);
                if (self.options.extensions) |registry| try registry.startAll(self.extensionContext());
                try self.dispatchEvent(app, .{ .lifecycle = .start });
                try self.loadStartupWindows(app);
                self.invalidateFor(.startup, null);
                try self.log("app.start", "app started", &.{trace.string("app", app.name)});
            },
            .surface_resized => |surface_value| {
                self.surface = surface_value;
                if (self.findWindowIndexById(surface_value.id)) |index| {
                    self.windows[index].info.frame.width = surface_value.size.width;
                    self.windows[index].info.frame.height = surface_value.size.height;
                    self.windows[index].info.scale_factor = surface_value.scale_factor;
                }
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
                if (self.options.window_state_store) |store| {
                    store.saveWindow(state) catch |err| try self.log("window.state.save_failed", @errorName(err), &.{trace.string("label", state.label)});
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
            .bridge_message => |message| try self.handleBridgeMessage(message),
            .tray_action => |item_id| {
                try self.log("tray.action", "tray item selected", &.{trace.uint("item_id", item_id)});
                try self.dispatchEvent(app, .{ .command = .{ .name = "tray.action" } });
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
            .lifecycle => {},
        }
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
                .diagnostics = .{ .frame_index = self.last_diagnostics.frame_index, .command_count = self.last_diagnostics.command_count },
                .source = self.loaded_source,
            };
        }
        for (self.windows[0..count], 0..) |window, index| {
            self.automation_windows[index] = .{
                .id = window.info.id,
                .title = if (window.info.title.len > 0) window.info.title else title,
                .bounds = window.info.frame,
                .focused = window.info.focused,
            };
        }
        return .{
            .windows = self.automation_windows[0..count],
            .diagnostics = .{ .frame_index = self.last_diagnostics.frame_index, .command_count = self.last_diagnostics.command_count },
            .source = self.loaded_source,
        };
    }

    pub fn frameDiagnostics(self: *Runtime) FrameDiagnostics {
        return self.last_diagnostics;
    }

    fn handlePlatformEvent(context: *anyopaque, event_value: platform.Event) anyerror!void {
        const run_context: *RunContext = @ptrCast(@alignCast(context));
        try run_context.runtime.dispatchPlatformEvent(run_context.app, event_value);
    }

    fn loadStartupWindows(self: *Runtime, app: App) anyerror!void {
        const source = try app.webViewSource();
        self.loaded_source = source;
        const app_info = self.options.platform.app_info;
        const count = app_info.startupWindowCount();
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const window = app_info.resolvedStartupWindow(index);
            if (self.findWindowIndexById(window.id) == null) {
                const runtime_index = try self.reserveWindow(window.id, window.label, window.resolvedTitle(app_info.app_name), source);
                self.windows[runtime_index].info.frame = window.default_frame;
                self.windows[runtime_index].main_frame = geometry.RectF.init(0, 0, window.default_frame.width, window.default_frame.height);
            }
            if (index > 0) {
                _ = try self.options.platform.services.createWindow(window);
            }
            try self.options.platform.services.loadWindowWebView(window.id, source);
            self.next_window_id = @max(self.next_window_id, window.id + 1);
        }
        try self.log("webview.load", "loaded webview source", &.{
            trace.string("kind", @tagName(source.kind)),
            trace.uint("bytes", source.bytes.len),
        });
    }

    fn loadWebView(self: *Runtime, app: App) anyerror!void {
        const source = try app.webViewSource();
        self.loaded_source = source;
        try self.options.platform.services.loadWindowWebView(1, source);
    }

    fn reloadWindows(self: *Runtime, app: App) anyerror!void {
        const source = try app.webViewSource();
        self.loaded_source = source;
        if (self.window_count == 0) {
            try self.options.platform.services.loadWindowWebView(1, source);
            return;
        }
        for (self.windows[0..self.window_count]) |*window| {
            const window_source = if (window.source) |stored| stored else source;
            try self.options.platform.services.loadWindowWebView(window.info.id, window_source);
        }
    }

    fn handleBridgeMessage(self: *Runtime, message: platform.BridgeMessage) anyerror!void {
        self.command_count += 1;
        if (try self.handleBuiltinBridgeMessage(message)) return;
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
        try handler.invoke_fn(handler.context, .{
            .request = request,
            .source = .{ .origin = message.origin, .window_id = message.window_id, .webview_label = message.webview_label },
        }, .{
            .context = self,
            .source = .{ .origin = message.origin, .window_id = message.window_id, .webview_label = message.webview_label },
            .respond_fn = asyncBridgeRespond,
        });
        return true;
    }

    fn asyncBridgeRespond(context: *anyopaque, source: bridge.Source, response: []const u8) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        try self.respondToBridge(source, response);
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
                try self.handleBridgeMessage(.{ .bytes = command.value, .origin = "zero://inline", .window_id = 1, .webview_label = "main" });
            },
            .wait => {},
        }
    }

    fn reserveWindow(self: *Runtime, id: platform.WindowId, label: []const u8, title: []const u8, source: ?platform.WebViewSource) !usize {
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
        self.windows[index].source = if (source) |source_value| try self.copySource(index, source_value) else null;
        self.windows[index].main_frame = geometry.RectF.init(0, 0, self.windows[index].info.frame.width, self.windows[index].info.frame.height);
        self.windows[index].main_frame_set = false;
        self.windows[index].main_layer = 100;
        self.window_count += 1;
        self.next_window_id = @max(self.next_window_id, id + 1);
        return index;
    }

    fn removeWindowAt(self: *Runtime, index: usize) void {
        if (index >= self.window_count) return;
        var cursor = index;
        while (cursor + 1 < self.window_count) : (cursor += 1) {
            self.windows[cursor] = self.windows[cursor + 1];
        }
        self.window_count -= 1;
    }

    fn copySource(self: *Runtime, index: usize, source: platform.WebViewSource) !platform.WebViewSource {
        if (source.bytes.len > self.windows[index].source_storage.len) return error.WindowSourceTooLarge;
        var copied = source;
        @memcpy(self.windows[index].source_storage[0..source.bytes.len], source.bytes);
        copied.bytes = self.windows[index].source_storage[0..source.bytes.len];
        return copied;
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
        const index = self.findWindowIndexById(state.id) orelse try self.reserveWindow(state.id, state.label, state.title, null);
        var info = self.windows[index].info;
        info.frame = state.frame;
        info.scale_factor = state.scale_factor;
        info.open = state.open;
        info.focused = state.focused;
        if (state.title.len > 0) info.title = try copyInto(&self.windows[index].title_storage, state.title);
        if (state.label.len > 0 and !std.mem.eql(u8, state.label, info.label)) info.label = try copyInto(&self.windows[index].label_storage, state.label);
        self.windows[index].info = info;
        if (!self.windows[index].main_frame_set) {
            self.windows[index].main_frame = geometry.RectF.init(0, 0, state.frame.width, state.frame.height);
        }
        if (!state.open) self.removeWebViewsForWindow(state.id);
        if (state.focused) self.setFocusedIndex(index);
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

    fn handleBuiltinBridgeMessage(self: *Runtime, message: platform.BridgeMessage) anyerror!bool {
        const request = bridge.parseRequest(message.bytes) catch return false;
        const is_window = std.mem.startsWith(u8, request.command, "zero-native.window.");
        const is_webview = std.mem.startsWith(u8, request.command, "zero-native.webview.");
        const is_dialog = std.mem.startsWith(u8, request.command, "zero-native.dialog.");
        if (!is_window and !is_webview and !is_dialog) return false;

        var response_buffer: [bridge.max_response_bytes]u8 = undefined;
        var result_buffer: [bridge.max_result_bytes]u8 = undefined;
        if (!self.allowsBuiltinBridgeCommand(request.command, message.origin, is_window or is_webview)) {
            const message_text = if (is_webview)
                "WebView API is not permitted"
            else if (is_window)
                "Window API is not permitted"
            else
                "Dialog API is not permitted";
            const result = bridge.writeErrorResponse(&response_buffer, request.id, .permission_denied, message_text);
            try self.completeBridgeResponse(message.window_id, message.webview_label, result);
            self.invalidateFor(.command, null);
            return true;
        }
        const result = if (is_window)
            self.dispatchWindowBridgeCommand(request, &result_buffer, &response_buffer)
        else if (is_webview)
            self.dispatchWebViewBridgeCommand(request, message.window_id, &result_buffer, &response_buffer)
        else
            self.dispatchDialogBridgeCommand(request, &result_buffer, &response_buffer);

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

    fn allowsBuiltinBridgeCommand(self: *Runtime, command: []const u8, origin: []const u8, uses_window_permission: bool) bool {
        var policy = self.options.builtin_bridge;
        if (self.options.security.permissions.len > 0) policy.permissions = self.options.security.permissions;
        if (policy.enabled) return policy.allows(command, origin);
        if (!uses_window_permission or !self.options.js_window_api) return false;
        if (!security.allowsOrigin(self.options.security.navigation.allowed_origins, origin)) return false;
        if (self.options.security.permissions.len == 0) return true;
        return security.hasPermission(self.options.security.permissions, security.permission_window);
    }

    fn dispatchWindowBridgeCommand(self: *Runtime, request: bridge.Request, result_buffer: []u8, response_buffer: []u8) []const u8 {
        const result = if (std.mem.eql(u8, request.command, "zero-native.window.list"))
            self.writeWindowListJson(result_buffer) catch return bridge.writeErrorResponse(response_buffer, request.id, .internal_error, "Failed to list windows")
        else if (std.mem.eql(u8, request.command, "zero-native.window.create"))
            self.createWindowFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, .internal_error, builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.window.focus"))
            self.focusWindowFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, .internal_error, builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.window.close"))
            self.closeWindowFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, .internal_error, builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown window command");
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
            self.openFileDialogFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, .internal_error, builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.dialog.saveFile"))
            self.saveFileDialogFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, .internal_error, builtinBridgeErrorMessage(err))
        else if (std.mem.eql(u8, request.command, "zero-native.dialog.showMessage"))
            self.showMessageDialogFromJson(request.payload, result_buffer) catch |err| return bridge.writeErrorResponse(response_buffer, request.id, .internal_error, builtinBridgeErrorMessage(err))
        else
            return bridge.writeErrorResponse(response_buffer, request.id, .unknown_command, "Unknown dialog command");
        return bridge.writeSuccessResponse(response_buffer, request.id, result);
    }

    fn openFileDialogFromJson(self: *Runtime, payload: []const u8, output: []u8) ![]const u8 {
        var storage = json.StringStorage.init(output);
        const title = jsonStringField(payload, "title", &storage) orelse "";
        const default_path = jsonStringField(payload, "defaultPath", &storage) orelse "";
        const allow_dirs = jsonBoolField(payload, "allowDirectories") orelse false;
        const allow_multi = jsonBoolField(payload, "allowMultiple") orelse false;
        var dialog_buffer: [platform.max_dialog_paths_bytes]u8 = undefined;
        const result = try self.options.platform.services.showOpenDialog(.{
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
        const path = try self.options.platform.services.showSaveDialog(.{
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

        const result = try self.options.platform.services.showMessageDialog(.{
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
        errdefer self.options.platform.services.closeWebView(window_id, label) catch {};
        try self.reserveWebView(window_id, label, url, webview_frame, layer, transparent, bridge_enabled);
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
            return writeWebViewJson(self.mainWebViewInfo(window_index), output);
        }
        const webview_index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        try self.options.platform.services.setWebViewFrame(window_id, label, webview_frame);
        self.webviews[webview_index].frame = webview_frame;
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
            return writeWebViewJson(self.mainWebViewInfo(window_index), output);
        }
        const webview_index = self.findWebViewIndex(window_id, label) orelse return error.WebViewNotFound;
        try self.options.platform.services.setWebViewZoom(window_id, label, zoom);
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
        try self.options.platform.services.closeWebView(window_id, label);
        const result = try writeWebViewJson(self.webviews[webview_index], output);
        self.removeWebViewAt(webview_index);
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

    fn reserveWebView(self: *Runtime, window_id: platform.WindowId, label: []const u8, url: []const u8, webview_frame: geometry.RectF, layer: i32, transparent: bool, bridge_enabled: bool) !void {
        const index = self.webview_count;
        self.webviews[index] = .{
            .window_id = window_id,
            .frame = webview_frame,
            .layer = layer,
            .transparent = transparent,
            .bridge_enabled = bridge_enabled,
            .open = true,
        };
        self.webviews[index].label = try copyInto(&self.webviews[index].label_storage, label);
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
                .window_id = next.window_id,
                .frame = next.frame,
                .layer = next.layer,
                .transparent = next.transparent,
                .bridge_enabled = next.bridge_enabled,
                .open = next.open,
            };
            self.webviews[cursor].label = copyInto(&self.webviews[cursor].label_storage, next.label) catch unreachable;
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
            .window_id = window.info.id,
            .label = "main",
            .url = sourceWebViewUrl(window.source),
            .frame = if (window.main_frame_set) window.main_frame else fallback_frame,
            .layer = window.main_layer,
            .transparent = false,
            .bridge_enabled = true,
            .open = window.info.open,
        };
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
    source: ?platform.WebViewSource = null,
    main_frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    main_frame_set: bool = false,
    main_layer: i32 = 100,
    label_storage: [platform.max_window_label_bytes]u8 = undefined,
    title_storage: [platform.max_window_title_bytes]u8 = undefined,
    source_storage: [platform.max_window_source_bytes]u8 = undefined,
};

const RuntimeWebView = struct {
    window_id: platform.WindowId = 1,
    label: []const u8 = "",
    url: []const u8 = "",
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    transparent: bool = false,
    bridge_enabled: bool = false,
    open: bool = false,
    label_storage: [platform.max_webview_label_bytes]u8 = undefined,
    url_storage: [platform.max_webview_url_bytes]u8 = undefined,
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

fn writeWebViewJsonToWriter(webview: RuntimeWebView, writer: anytype) !void {
    try writer.writeAll("{\"label\":");
    try json.writeString(writer, webview.label);
    try writer.print(",\"windowId\":{d},\"url\":", .{webview.window_id});
    try json.writeString(writer, webview.url);
    try writer.print(",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"layer\":{d},\"transparent\":{},\"bridge\":{},\"open\":{}}}", .{
        webview.frame.x,
        webview.frame.y,
        webview.frame.width,
        webview.frame.height,
        webview.layer,
        webview.transparent,
        webview.bridge_enabled,
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
        error.NavigationDenied => "WebView URL is not allowed by navigation policy",
        error.InvalidWindowOptions => "Window options are invalid",
        error.DuplicateWindowId => "Window id already exists",
        error.NoSpaceLeft => "Native response buffer is too small",
        else => "Native command failed",
    };
}

fn builtinBridgeErrorCode(err: anyerror) bridge.ErrorCode {
    return switch (err) {
        error.UnsupportedService,
        error.MissingWebViewUrl,
        error.InvalidWebViewWindowId,
        error.CrossWindowWebViewDenied,
        error.InvalidWebViewOptions,
        error.WindowNotFound,
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
        => .invalid_request,
        error.NavigationDenied => .invalid_request,
        else => .internal_error,
    };
}

fn jsonStringField(payload: []const u8, field: []const u8, storage: *json.StringStorage) ?[]const u8 {
    return json.stringField(payload, field, storage);
}

fn webViewWindowIdFromJson(payload: []const u8, default_window_id: platform.WindowId) !platform.WindowId {
    if (json.fieldValue(payload, "windowId") == null) return default_window_id;
    const window_id = jsonIntegerField(payload, "windowId") orelse return error.InvalidWebViewWindowId;
    if (window_id != default_window_id) return error.CrossWindowWebViewDenied;
    return window_id;
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

fn webViewLayerFromJson(payload: []const u8) !i32 {
    if (json.fieldValue(payload, "layer") == null) return 0;
    const layer_value = jsonNumberField(payload, "layer") orelse return error.InvalidWebViewOptions;
    if (!std.math.isFinite(layer_value)) return error.InvalidWebViewOptions;
    const max_layer: f32 = @floatFromInt(std.math.maxInt(i32));
    const min_layer: f32 = @floatFromInt(std.math.minInt(i32));
    if (layer_value > max_layer) return std.math.maxInt(i32);
    if (layer_value < min_layer) return std.math.minInt(i32);
    return @as(i32, @intFromFloat(layer_value));
}

fn isMainWebViewLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "main");
}

fn validateWebViewLabel(label: []const u8) !void {
    if (label.len == 0) return error.InvalidWebViewOptions;
    if (label.len > platform.max_webview_label_bytes) return error.WebViewLabelTooLarge;
}

fn validateChildWebViewLabel(label: []const u8) !void {
    try validateWebViewLabel(label);
    if (isMainWebViewLabel(label)) return error.ReservedWebViewLabel;
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
        .bytes = "{\"id\":\"2\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"palette\"") != null);

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

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"8\",\"command\":\"zero-native.webview.setZoom\",\"payload\":{\"label\":\"main\",\"zoom\":1.1}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"label\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"height\":80") != null);

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
        .bytes = "{\"id\":\"invalid-layer\",\"command\":\"zero-native.webview.create\",\"payload\":{\"label\":\"bad-layer\",\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200},\"layer\":1e1000}}",
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
