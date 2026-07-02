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

test "runtime handles built-in JavaScript webview bridge commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "webview-bridge", .source = platform.WebViewSource.html("<p>WebView</p>") };
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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

test "runtime handles GPU surface options in JavaScript view bridge commands" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-view-bridge", .source = platform.WebViewSource.html("<p>GPU</p>") };
        }
    };

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.js_window_api = true;
    const view_origins = [_][]const u8{ "zero://inline", "zero://app" };
    harness.runtime.options.security.navigation.allowed_origins = &view_origins;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .bridge_message = .{
        .bytes = "{\"id\":\"gpu\",\"command\":\"zero-native.view.create\",\"payload\":{\"label\":\"canvas\",\"kind\":\"gpuSurface\",\"frame\":{\"width\":320,\"height\":240},\"gpuBackend\":\"metal\",\"gpuPixelFormat\":\"bgra8_unorm\",\"gpuPresentMode\":\"timer\",\"gpuAlphaMode\":\"opaque\",\"gpuColorSpace\":\"srgb\",\"gpuVsync\":true}}",
        .origin = "zero://inline",
        .window_id = 1,
    } });
    const response = harness.null_platform.lastBridgeResponse();
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"kind\":\"gpu_surface\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuBackend\":\"metal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuPixelFormat\":\"bgra8_unorm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuPresentMode\":\"timer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuAlphaMode\":\"opaque\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuColorSpace\":\"srgb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"gpuVsync\":true") != null);
}

test "runtime gates JavaScript view API with view permission" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "view-permission", .source = platform.WebViewSource.html("<p>Views</p>") };
        }
    };

    const view_permission = [_][]const u8{security.permission_view};
    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
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
    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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
