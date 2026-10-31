const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const policy = sdk.runtime.testing.builtin_coordination_policy;
const methods = sdk.runtime.testing.builtin_bridge_methods;
var modes: [3]usize = @splat(0);
fn compiled(input: []const u8, output: []u8) usize {
    if (input[0] == 89) modes[input[2]] += 1;
    return core.nativeWindowPolicy(input, output);
}
const commands = [_][]const u8{
    "native-sdk.command.invoke",
    "native-sdk.command.list",
    "native-sdk.platform.supports",
    "native-sdk.window.list",
    "native-sdk.window.create",
    "native-sdk.window.focus",
    "native-sdk.window.close",
    "native-sdk.view.create",
    "native-sdk.view.list",
    "native-sdk.view.update",
    "native-sdk.view.setFrame",
    "native-sdk.view.setVisible",
    "native-sdk.view.focus",
    "native-sdk.view.focusNext",
    "native-sdk.view.focusPrevious",
    "native-sdk.view.close",
    "native-sdk.webview.create",
    "native-sdk.webview.list",
    "native-sdk.webview.setFrame",
    "native-sdk.webview.navigate",
    "native-sdk.webview.setZoom",
    "native-sdk.webview.setLayer",
    "native-sdk.webview.close",
    "native-sdk.dialog.openFile",
    "native-sdk.dialog.saveFile",
    "native-sdk.dialog.showMessage",
    "native-sdk.os.showNotification",
    "native-sdk.os.openUrl",
    "native-sdk.os.revealPath",
    "native-sdk.os.addRecentDocument",
    "native-sdk.os.clearRecentDocuments",
    "native-sdk.credentials.set",
    "native-sdk.credentials.get",
    "native-sdk.credentials.delete",
    "native-sdk.clipboard.readText",
    "native-sdk.clipboard.writeText",
    "native-sdk.clipboard.read",
    "native-sdk.clipboard.write",
    "custom",
    "native-sdk.view.",
    "native-sdk.webview.unknown",
    "native-sdk.window.list\x00",
    "native-sdk.os.openUrlX",
    "\xff\x00",
};
test "compiled builtin coordination preserves every native error code and complete message" {
    _ = core.initialModel();
    const errors = [_]anyerror{
        error.UnsupportedService,
        error.UnsupportedWindowTransparency,
        error.WindowNotFound,
        error.WindowLimitReached,
        error.DuplicateWindowLabel,
        error.MissingWindowSource,
        error.WindowSourceTooLarge,
        error.CreateFailed,
        error.MissingWebViewUrl,
        error.InvalidWebViewWindowId,
        error.CrossWindowWebViewDenied,
        error.InvalidWebViewOptions,
        error.WebViewNotFound,
        error.WebViewLayerNotBuilt,
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
        error.NavigationDenied,
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
        error.CredentialNotFound,
        error.InvalidTrayOptions,
        error.TrayFieldTooLarge,
        error.InvalidPlatformFeature,
        error.InvalidWindowOptions,
        error.InvalidCommand,
        error.DuplicateWindowId,
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
        error.WidgetNodeLimitReached,
        error.WidgetTextTooLarge,
        error.WidgetSemanticsListFull,
        error.DuplicateWidgetId,
        error.UnsupportedViewKind,
        error.UnsupportedViewFocus,
        error.NoSpaceLeft,
        error.NewUnrecognizedError,
    };
    for (errors) |err| {
        const result = policy.errorInfo(compiled, err);
        try exact(sdk.runtime.testing.builtinBridgeErrorCode(err), result.errorCode());
        try exact(sdk.runtime.testing.builtinBridgeErrorMessage(err), result.message());
    }
}
test "compiled builtin coordination preserves family admission and complete legacy permission selection" {
    _ = core.initialModel();
    const prefixes = [_][]const u8{ "native-sdk.command.", "native-sdk.window.", "native-sdk.view.", "native-sdk.webview.", "native-sdk.platform.", "native-sdk.dialog.", "native-sdk.os.", "native-sdk.clipboard.", "native-sdk.credentials." };
    const permissions = [_]?[]const u8{ "command", "window", "view", "window", "window", null, null, null, null };
    for (prefixes, 0..) |prefix, i| {
        const p = policy.route(compiled, .none, prefix);
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), @intFromEnum(p.family()));
        try exact(permissions[i], p.permission());
        try exact(policy.Verb.unknown, p.verb());
        const miss = policy.route(compiled, .none, prefix[0 .. prefix.len - 1]);
        try exact(policy.Family.none, miss.family());
    }
    for ([_][]const u8{ "", "native-sdk.viewing.list", "Native-sdk.view.list", "\xff\x00" }) |value| {
        const p = policy.route(compiled, .none, value);
        try exact(policy.Family.none, p.family());
    }
}
test "compiled builtin coordination preserves exact long names without transport truncation" {
    _ = core.initialModel();
    const bytes = try std.testing.allocator.alloc(u8, 16385);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0xff);
    @memcpy(bytes[0..16], "native-sdk.view.");
    const p = policy.route(compiled, .none, bytes);
    try exact(policy.Family.view, p.family());
    try exact(policy.Verb.unknown, p.verb());
    try exact(@as([]const u8, "View API is not permitted"), p.deniedMessage());
    try exact(@as([]const u8, "Unknown view command"), p.unknownMessage());
}
fn invoke(h: anytype, family: policy.Family, request: sdk.bridge.Request, output: []u8, result: []u8) []const u8 {
    const app = sdk.App{ .context = h, .name = "builtin-coordination", .source = sdk.platform.WebViewSource.html("") };
    return switch (family) {
        .none => unreachable,
        .command => methods.dispatchCommandBridgeCommand(&h.runtime, app, request, 1, "main", result, output),
        .window => methods.dispatchWindowBridgeCommand(&h.runtime, request, result, output),
        .view => methods.dispatchViewBridgeCommand(&h.runtime, request, 1, result, output),
        .webview => methods.dispatchWebViewBridgeCommand(&h.runtime, request, 1, result, output),
        .platform => methods.dispatchPlatformBridgeCommand(&h.runtime, request, result, output),
        .dialog => methods.dispatchDialogBridgeCommand(&h.runtime, request, result, output),
        .os => methods.dispatchOsBridgeCommand(&h.runtime, request, "zero://inline", result, output),
        .clipboard => methods.dispatchClipboardBridgeCommand(&h.runtime, request, result, output),
        .credentials => methods.dispatchCredentialBridgeCommand(&h.runtime, request, result, output),
    };
}
test "compiled builtin coordination preserves all native verbs wrong families and complete response buffers" {
    _ = core.initialModel();
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    b.runtime.builtin_coordination_policy = compiled;
    for (commands) |command| for (std.meta.tags(policy.Family)[1..]) |family| {
        var left: [4096]u8 = @splat(0xa5);
        var right = left;
        var lr: [4096]u8 = @splat(0x5a);
        var rr = lr;
        const request = sdk.bridge.Request{ .id = "raw\xff\x00\"id", .command = command, .payload = "{}" };
        try exact(invoke(a, family, request, &left, &lr), invoke(b, family, request, &right, &rr));
        try exact(left, right);
        try exact(lr, rr);
    };
}
test "compiled builtin coordination preserves small buffers and web layer refusal precedence" {
    _ = core.initialModel();
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    b.runtime.builtin_coordination_policy = compiled;
    for ([_]bool{ false, true }) |web| for ([_][]const u8{ "native-sdk.webview.unknown", "native-sdk.view.create", "native-sdk.platform.supports", "native-sdk.window.list" }) |command| for ([_]usize{ 0, 1, 8, 32, 255, 512 }) |length| {
        a.runtime.options.web_layer = web;
        b.runtime.options.web_layer = web;
        var left: [512]u8 = @splat(0xa5);
        var right = left;
        var lr: [512]u8 = @splat(0x5a);
        var rr = lr;
        const family: policy.Family = if (std.mem.startsWith(u8, command, "native-sdk.webview.")) .webview else if (std.mem.startsWith(u8, command, "native-sdk.view.")) .view else if (std.mem.startsWith(u8, command, "native-sdk.window.")) .window else .platform;
        const request = sdk.bridge.Request{ .id = "small", .command = command, .payload = "{}" };
        try exact(invoke(a, family, request, left[0..length], lr[0..length]), invoke(b, family, request, right[0..length], rr[0..length]));
        try exact(left, right);
        try exact(lr, rr);
    };
}
test "compiled builtin coordination preserves notification action permission and original error precedence" {
    _ = core.initialModel();
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    b.runtime.builtin_coordination_policy = compiled;
    for ([_]bool{ false, true }) |allowed| for ([_][]const u8{ "{}", "{\"actionCommand\":\"\"}", "{\"actionCommand\":\"go\"}", "{\"actionCommand\":4}", "invalid" }) |payload| {
        for ([_]*Harness{ a, b }) |h| h.runtime.options.builtin_bridge = .{ .enabled = true, .commands = if (allowed) &.{.{ .name = "native-sdk.command.invoke", .origins = &.{"zero://inline"} }} else &.{} };
        var left: [4096]u8 = @splat(0xa5);
        var right = left;
        var lr: [4096]u8 = @splat(0x5a);
        var rr = lr;
        const request = sdk.bridge.Request{ .id = "notification", .command = "native-sdk.os.showNotification", .payload = payload };
        try exact(invoke(a, .os, request, &left, &lr), invoke(b, .os, request, &right, &rr));
        try exact(left, right);
        try exact(lr, rr);
    };
}
test "compiled builtin coordination binds production dispatch with complete snapshots and origin gates" {
    _ = core.initialModel();
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    for ([_]*Harness{ a, b }, 0..) |h, i| {
        try h.start(.{ .context = h, .name = "builtin-coordination", .source = sdk.platform.WebViewSource.html(""), .builtin_coordination_policy = if (i == 1) compiled else null });
        h.runtime.started_timestamp_ns = 0;
        h.runtime.options.security.navigation.allowed_origins = &.{"zero://inline"};
        h.runtime.options.security.permissions = &.{"window"};
    }
    try std.testing.expect(b.runtime.builtin_coordination_policy != null);
    for ([_]bool{ false, true }) |js| for ([_][]const u8{ "zero://inline", "denied" }) |origin| for (commands) |command| {
        var raw: [512]u8 = undefined;
        // The malformed-byte corpus is covered by direct native dispatch, not JSON construction.
        if (std.mem.indexOfScalar(u8, command, 0) != null or command[0..].len > 0 and command[0] == 0xff) continue;
        const request = try std.fmt.bufPrint(&raw, "{{\"id\":\"route\",\"command\":\"{s}\",\"payload\":{{}}}}", .{command});
        for ([_]*Harness{ a, b }) |h| {
            h.runtime.options.js_window_api = js;
            try h.runtime.dispatchPlatformEvent(.{ .context = h, .name = "builtin-coordination", .source = sdk.platform.WebViewSource.html("") }, .{ .bridge_message = .{ .bytes = request, .origin = origin, .window_id = 1 } });
        }
        try exact(a.null_platform.lastBridgeResponse(), b.null_platform.lastBridgeResponse());
        try exact(a.runtime.automationSnapshot("builtin-coordination"), b.runtime.automationSnapshot("builtin-coordination"));
    };
    for (modes) |count| try std.testing.expect(count > 0);
}

test "compiled builtin coordination preserves successful window view and webview capability sequences" {
    _ = core.initialModel();
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    for ([_]*Harness{ a, b }, 0..) |h, i| {
        h.runtime.options.web_layer = true;
        h.runtime.options.security.navigation.allowed_origins = &.{ "zero://inline", "https://example.invalid" };
        try h.start(.{ .context = h, .name = "builtin-coordination", .source = sdk.platform.WebViewSource.html(""), .builtin_coordination_policy = if (i == 1) compiled else null });
        h.runtime.started_timestamp_ns = 0;
    }
    const Case = struct { family: policy.Family, command: []const u8, payload: []const u8 = "{}" };
    const cases = [_]Case{
        .{ .family = .command, .command = "native-sdk.command.list" },
        .{ .family = .platform, .command = "native-sdk.platform.supports", .payload = "{\"feature\":\"native_views\"}" },
        .{ .family = .window, .command = "native-sdk.window.create", .payload = "{\"label\":\"palette\",\"title\":\"Palette\",\"width\":320,\"height\":240}" },
        .{ .family = .window, .command = "native-sdk.window.focus", .payload = "{\"label\":\"palette\"}" },
        .{ .family = .window, .command = "native-sdk.window.list" },
        .{ .family = .view, .command = "native-sdk.view.create", .payload = "{\"label\":\"toolbar\",\"kind\":\"toolbar\",\"frame\":{\"width\":640,\"height\":44},\"text\":\"Tools\"}" },
        .{ .family = .view, .command = "native-sdk.view.update", .payload = "{\"label\":\"toolbar\",\"text\":\"Actions\",\"enabled\":false}" },
        .{ .family = .view, .command = "native-sdk.view.setFrame", .payload = "{\"label\":\"toolbar\",\"frame\":{\"x\":1,\"y\":2,\"width\":300,\"height\":40}}" },
        .{ .family = .view, .command = "native-sdk.view.setVisible", .payload = "{\"label\":\"toolbar\",\"visible\":false}" },
        .{ .family = .webview, .command = "native-sdk.webview.create", .payload = "{\"label\":\"preview\",\"url\":\"https://example.invalid/\",\"frame\":{\"width\":300,\"height\":200}}" },
        .{ .family = .webview, .command = "native-sdk.webview.setFrame", .payload = "{\"label\":\"preview\",\"frame\":{\"width\":333,\"height\":222}}" },
        .{ .family = .webview, .command = "native-sdk.webview.navigate", .payload = "{\"label\":\"preview\",\"url\":\"https://example.invalid/next\"}" },
        .{ .family = .webview, .command = "native-sdk.webview.setZoom", .payload = "{\"label\":\"preview\",\"zoom\":1.25}" },
        .{ .family = .webview, .command = "native-sdk.webview.setLayer", .payload = "{\"label\":\"preview\",\"layer\":10}" },
        .{ .family = .webview, .command = "native-sdk.webview.list" },
        .{ .family = .webview, .command = "native-sdk.webview.close", .payload = "{\"label\":\"preview\"}" },
        .{ .family = .view, .command = "native-sdk.view.close", .payload = "{\"label\":\"toolbar\"}" },
        .{ .family = .window, .command = "native-sdk.window.close", .payload = "{\"label\":\"palette\"}" },
    };
    for (cases) |case| {
        var left: [4096]u8 = @splat(0xa5);
        var right = left;
        var lr: [4096]u8 = @splat(0x5a);
        var rr = lr;
        const request = sdk.bridge.Request{ .id = "success", .command = case.command, .payload = case.payload };
        const response = invoke(a, case.family, request, &left, &lr);
        if (std.mem.indexOf(u8, response, "\"ok\":true") == null)
            std.debug.print("{s}: {s}\n", .{ case.command, response });
        try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
        try exact(response, invoke(b, case.family, request, &right, &rr));
        try exact(left, right);
        try exact(lr, rr);
        try exact(a.runtime.automationSnapshot("builtin-coordination"), b.runtime.automationSnapshot("builtin-coordination"));
    }
}
