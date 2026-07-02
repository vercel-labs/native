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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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
