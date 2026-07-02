const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const trace = support.trace;
const json = support.json;
const canvas = support.canvas;
const automation = support.automation;
const bridge = support.bridge;
const app_manifest = support.app_manifest;
const platform = support.platform;
const security = support.security;
const extensions = support.extensions;
const window_state = support.window_state;
const runtime_module = support.runtime_module;
const bridge_payload = support.bridge_payload;
const canvas_frame = support.canvas_frame;
const App = support.App;
const Runtime = support.Runtime;
const Options = support.Options;
const Event = support.Event;
const LifecycleEvent = support.LifecycleEvent;
const CommandEvent = support.CommandEvent;
const Command = support.Command;
const CommandSource = support.CommandSource;
const FrameDiagnostics = support.FrameDiagnostics;
const ShortcutEvent = support.ShortcutEvent;
const Appearance = support.Appearance;
const GpuFrame = support.GpuFrame;
const GpuSurfaceFrameEvent = support.GpuSurfaceFrameEvent;
const GpuSurfaceResizeEvent = support.GpuSurfaceResizeEvent;
const GpuSurfaceInputEvent = support.GpuSurfaceInputEvent;
const CanvasWidgetPointerEvent = support.CanvasWidgetPointerEvent;
const CanvasWidgetKeyboardEvent = support.CanvasWidgetKeyboardEvent;
const CanvasWidgetDisplayListChrome = support.CanvasWidgetDisplayListChrome;
const CanvasPresentationMode = support.CanvasPresentationMode;
const CanvasPresentationResult = support.CanvasPresentationResult;
const CanvasWidgetAccessibilityActionKind = support.CanvasWidgetAccessibilityActionKind;
const CanvasWidgetAccessibilityAction = support.CanvasWidgetAccessibilityAction;
const CanvasWidgetFileDropEvent = support.CanvasWidgetFileDropEvent;
const CanvasWidgetDragEvent = support.CanvasWidgetDragEvent;
const InvalidationReason = support.InvalidationReason;
const TestHarness = support.TestHarness;
const max_canvas_commands_per_view = support.max_canvas_commands_per_view;
const max_canvas_widget_nodes_per_view = support.max_canvas_widget_nodes_per_view;
const jsonStringField = support.jsonStringField;
const jsonNumberField = support.jsonNumberField;
const jsonBoolField = support.jsonBoolField;
const canvasRenderAnimationFinalOverrideNoop = support.canvasRenderAnimationFinalOverrideNoop;
const copyInto = support.copyInto;
const writeViewJson = support.writeViewJson;
const canvasFrameScratchStorage = support.canvasFrameScratchStorage;
const runtimeViewInfo = support.runtimeViewInfo;
const runtimeViewCanvasFrameRenderOverrides = support.runtimeViewCanvasFrameRenderOverrides;
const runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides = support.runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides;
const runtimeViewWidgetSemantics = support.runtimeViewWidgetSemantics;
const runtimeViewSetCanvasWidgetSelected = support.runtimeViewSetCanvasWidgetSelected;
const runtimeViewCanvasWidgetDirtyBounds = support.runtimeViewCanvasWidgetDirtyBounds;
const dispatchAutomationWidgetAction = support.dispatchAutomationWidgetAction;
const shellBoundsForWindow = support.shellBoundsForWindow;
const reloadWindows = support.reloadWindows;
const canvasWidgetSemanticsById = support.canvasWidgetSemanticsById;
const platformWidgetAccessibilityNodeById = support.platformWidgetAccessibilityNodeById;
const builtinBridgeErrorCode = support.builtinBridgeErrorCode;
const builtinBridgeErrorMessage = support.builtinBridgeErrorMessage;
const testViewByLabel = support.testViewByLabel;
const testCanvasWidgetPartId = support.testCanvasWidgetPartId;

test "runtime creates lists focuses and closes windows" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "windows", .source = platform.WebViewSource.html("<p>Windows</p>") };
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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
    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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
    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
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
    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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
