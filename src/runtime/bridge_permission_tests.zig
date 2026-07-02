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

test "runtime gates JavaScript window API by origin and configured permission" {
    var app_state: u8 = 0;
    const app = App{ .context = &app_state, .name = "window-api-security", .source = platform.WebViewSource.html("<p>Windows</p>") };
    const Harness = TestHarness();

    const denied_origin = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(denied_origin);
    denied_origin.init(.{});
    denied_origin.runtime.options.js_window_api = true;
    try denied_origin.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"origin\",\"command\":\"zero-native.window.list\",\"payload\":null}",
        .origin = "https://example.invalid",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_origin.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);

    const filesystem_only = [_][]const u8{security.permission_filesystem};
    const denied_permission = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(denied_permission);
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
    const allowed = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(allowed);
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
    const Harness = TestHarness();

    const denied_origin = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(denied_origin);
    denied_origin.init(.{});
    denied_origin.runtime.options.js_window_api = true;
    try denied_origin.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"origin\",\"command\":\"zero-native.webview.create\",\"payload\":{\"url\":\"https://example.com\",\"frame\":{\"width\":300,\"height\":200}}}",
        .origin = "https://example.invalid",
        .window_id = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, denied_origin.null_platform.lastBridgeResponse(), "WebView API is not permitted") != null);

    const filesystem_only = [_][]const u8{security.permission_filesystem};
    const denied_permission = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(denied_permission);
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
    const allowed = try std.testing.allocator.create(Harness);
    defer std.testing.allocator.destroy(allowed);
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

    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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
    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    const app = App{ .context = harness, .name = "dialog-denied", .source = platform.WebViewSource.html("<p>Dialogs</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"zero-native.dialog.showMessage\",\"payload\":{\"message\":\"Hello\"}}",
        .origin = "zero://inline",
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}

test "runtime reports dialog bridge validation errors as invalid requests" {
    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    const app = App{ .context = harness, .name = "dialog-invalid", .source = platform.WebViewSource.html("<p>Dialogs</p>") };
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
    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
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

    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
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

    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
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

    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
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

    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
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

    const denied = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(denied);
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

    const allowed = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(allowed);
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
    const harness = try std.testing.allocator.create(TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{});
    const app = App{ .context = harness, .name = "bridge-denied", .source = platform.WebViewSource.html("<p>Bridge</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{
        .bytes = "{\"id\":\"1\",\"command\":\"native.ping\",\"payload\":null}",
        .origin = "zero://inline",
    } });

    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"permission_denied\"") != null);
}
