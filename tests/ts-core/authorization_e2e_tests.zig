const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const policy = sdk.runtime.testing.authorization_policy;
var modes: [7]usize = @splat(0);
fn compiled(input: []const u8, output: []u8) usize {
    if (input[0] == 88) modes[input[2]] += 1;
    return core.nativeWindowPolicy(input, output);
}
fn result(a: anytype, b: anytype) !void {
    const left = a catch |err| {
        try std.testing.expectError(err, b);
        return;
    };
    try exact(left, try b);
}
const corpus = [_][]const u8{ "", "window", "Window", "window\x00", "clipboard", "*", "**", "zero://inline", "zero://app", "https://a", "https://a/", "https://a/*", "https://a*", "https://a.evil/x", "https://a/x", "http://a/one*", "http://a/one/two", "http://a/*/two*", "HTTPS://a/*", "https:///*", "https:///x", "odd://a/*", "\xff\x00\xfe" };
test "compiled authorization preserves complete exact grants and origin wildcard scopes" {
    for (corpus) |a| for (corpus) |b| {
        try exact(sdk.security.hasPermission(&.{ a, a }, b), policy.hasPermission(compiled, &.{ a, a }, b));
        try exact(sdk.security.hasPermissions(&.{ a, a }, &.{ a, b }), policy.hasPermissions(compiled, &.{ a, a }, &.{ a, b }));
        try exact(sdk.security.allowsOrigin(&.{ a, a }, b), policy.allowsOrigin(compiled, &.{ a, a }, b));
    };
    try std.testing.expect(policy.hasPermissions(compiled, &.{}, &.{}));
    try std.testing.expect(!policy.hasPermission(compiled, &.{}, ""));
    try std.testing.expect(!policy.allowsOrigin(compiled, &.{}, ""));
}
test "compiled authorization preserves full external patterns and malformed authority bytes" {
    for (corpus) |a| for (corpus) |b| for ([_]sdk.security.ExternalLinkAction{ .deny, .open_system_browser }) |action| {
        const value = sdk.security.ExternalLinkPolicy{ .action = action, .allowed_urls = &.{ a, a } };
        try exact(sdk.security.allowsExternalUrl(value, b), policy.allowsExternalUrl(compiled, value, b));
    };
}
test "compiled authorization preserves first command lookup and complete ordered tables" {
    for (corpus) |name| for ([_]bool{ false, true }) |enabled| for ([_][]const []const u8{ &.{}, &.{"*"}, &.{"window"}, &.{ "window", "clipboard" } }) |grants| {
        const commands = [_]sdk.bridge.CommandPolicy{
            .{ .name = name, .permissions = &.{ "window", "window" }, .origins = &.{"zero://inline"} },
            .{ .name = name },
            .{ .name = "other", .permissions = &.{"clipboard"}, .origins = &.{"*"} },
        };
        const value = sdk.bridge.Policy{ .enabled = enabled, .permissions = grants, .commands = &commands };
        for ([_][]const u8{ name, "other", "missing" }) |command| for ([_][]const u8{ "", "zero://inline", "elsewhere", "\xff\x00" }) |origin| try exact(value.allows(command, origin), policy.bridgeAllows(compiled, value, command, origin));
    };
}
test "compiled authorization preserves unlimited text and tables beyond transport scratch" {
    const bytes = try std.testing.allocator.alloc(u8, 16385);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    var grants: [257][]const u8 = @splat("miss");
    grants[256] = bytes;
    try std.testing.expect(policy.hasPermission(compiled, &grants, bytes));
    try std.testing.expect(policy.allowsOrigin(compiled, &grants, bytes));
    bytes[16384] = 0xff;
    try std.testing.expect(policy.hasPermissions(compiled, &grants, &.{ bytes, bytes }));
    try std.testing.expect(!policy.hasPermission(compiled, &grants, bytes[0..16384]));
    const value = sdk.bridge.Policy{ .enabled = true, .permissions = &grants, .commands = &.{.{ .name = bytes, .permissions = &.{bytes}, .origins = &.{bytes} }} };
    try std.testing.expect(policy.bridgeAllows(compiled, value, bytes, bytes));
    try std.testing.expect(!policy.bridgeAllows(compiled, value, bytes[0..16384], bytes));
}
test "compiled authorization preserves builtin policy precedence and compatibility permissions" {
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    b.runtime.authorization_policy = compiled;
    for ([_]bool{ false, true }) |enabled| for ([_]bool{ false, true }) |js| for ([_]?[]const u8{ null, "", "window", "clipboard", "missing", "\xff\x00" }) |permission| for ([_][]const []const u8{ &.{}, &.{"window"}, &.{"clipboard"}, &.{"*"}, &.{"missing"} }) |grants| {
        for ([_]*Harness{ a, b }) |h| {
            h.runtime.options.js_window_api = js;
            h.runtime.options.security.permissions = grants;
            h.runtime.options.security.navigation.allowed_origins = &.{"zero://inline"};
            h.runtime.options.builtin_bridge = .{ .enabled = enabled, .permissions = &.{"clipboard"}, .commands = &.{ .{ .name = "one", .permissions = &.{"clipboard"}, .origins = &.{"zero://inline"} }, .{ .name = "one" } } };
        }
        for ([_][]const u8{ "one", "missing" }) |command| for ([_][]const u8{ "zero://inline", "denied" }) |origin| try exact(sdk.runtime.testing.builtin_bridge_methods.allowsBuiltinBridgeCommand(&a.runtime, command, origin, permission), sdk.runtime.testing.builtin_bridge_methods.allowsBuiltinBridgeCommand(&b.runtime, command, origin, permission));
    };
}
test "compiled authorization preserves external admission precedence and exact field boundaries" {
    const value = sdk.security.ExternalLinkPolicy{ .action = .open_system_browser, .allowed_urls = &.{"*"} };
    for (corpus) |url| try result(policy.validateExternalUrl(null, value, url), policy.validateExternalUrl(compiled, value, url));
    for ([_][]const u8{ "http://", "http://a/\x00", "http://a/\x7f", "http://a/\xff", "https://a/ x" }) |url| for ([_]sdk.security.ExternalLinkAction{ .deny, .open_system_browser }) |action| try result(policy.validateExternalUrl(null, .{ .action = action, .allowed_urls = &.{"*"} }, url), policy.validateExternalUrl(compiled, .{ .action = action, .allowed_urls = &.{"*"} }, url));
    const bytes = try std.testing.allocator.alloc(u8, sdk.platform.max_external_url_bytes + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    @memcpy(bytes[0..8], "https://");
    for ([_]usize{ bytes.len - 2, bytes.len - 1, bytes.len }) |count| try result(policy.validateExternalUrl(null, value, bytes[0..count]), policy.validateExternalUrl(compiled, value, bytes[0..count]));
    bytes[0] = 0;
    try result(policy.validateExternalUrl(null, value, bytes), policy.validateExternalUrl(compiled, value, bytes));
}
const HandlerState = struct {
    calls: usize = 0,
    fn invoke(context: *anyopaque, invocation: sdk.bridge.Invocation, output: []u8) ![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), invocation.source.window_id);
        try std.testing.expectEqualStrings("preview", invocation.source.webview_label);
        if (std.mem.eql(u8, invocation.request.command, "fail")) return error.ExpectedFailure;
        if (std.mem.eql(u8, invocation.request.command, "invalid")) return "invalid json";
        if (std.mem.eql(u8, invocation.request.command, "empty")) return "";
        return std.fmt.bufPrint(output, "{{\"calls\":{d},\"payload\":{s}}}", .{ self.calls, invocation.request.payload });
    }
};
test "compiled authorization preserves complete bridge response buffers and handler ownership" {
    var states: [2]HandlerState = .{ .{}, .{} };
    const commands = [_]sdk.bridge.CommandPolicy{ .{ .name = "one" }, .{ .name = "missing" }, .{ .name = "fail" }, .{ .name = "empty" }, .{ .name = "invalid" } };
    for ([_]bool{ false, true }) |enabled| for ([_][]const u8{ "{}", "{\"id\":\"x\",\"command\":\"one\",\"payload\":{\"bytes\":[0,255]}}", "{\"id\":\"x\",\"command\":\"missing\"}", "{\"id\":\"x\",\"command\":\"fail\"}", "{\"id\":\"x\",\"command\":\"empty\"}", "{\"id\":\"x\",\"command\":\"invalid\"}", "{\"id\":\"x\",\"command\":\"denied\"}", "{\"id\":\"x\",\"command\":\"one\",\"payload\":[]}" }) |raw| {
        var outputs: [2][4096]u8 = @splat(@splat(0xa5));
        var lengths: [2]usize = undefined;
        for (&states, 0..) |*state, i| {
            const handlers = [_]sdk.bridge.Handler{ .{ .name = "one", .context = state, .invoke_fn = HandlerState.invoke }, .{ .name = "fail", .context = state, .invoke_fn = HandlerState.invoke }, .{ .name = "empty", .context = state, .invoke_fn = HandlerState.invoke }, .{ .name = "invalid", .context = state, .invoke_fn = HandlerState.invoke } };
            const dispatcher = sdk.bridge.Dispatcher{ .policy = .{ .enabled = enabled, .commands = &commands }, .registry = .{ .handlers = &handlers } };
            lengths[i] = policy.dispatch(if (i == 0) null else compiled, dispatcher, raw, .{ .window_id = std.math.maxInt(u64), .webview_label = "preview" }, &outputs[i]).len;
        }
        try exact(states[0], states[1]);
        try exact(lengths[0], lengths[1]);
        try exact(outputs[0], outputs[1]);
    };
}
test "compiled authorization binds runtime synchronous gates with complete snapshots" {
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    for ([_]*Harness{ a, b }, 0..) |h, i| {
        try h.start(.{ .context = h, .name = "authorization", .source = sdk.platform.WebViewSource.html(""), .authorization_policy = if (i == 1) compiled else null });
        h.runtime.started_timestamp_ns = 0;
        h.runtime.options.js_window_api = true;
        h.runtime.options.security.navigation.allowed_origins = &.{"zero://inline"};
        h.runtime.options.security.permissions = &.{"window"};
    }
    for ([_][]const u8{ "zero://inline", "denied" }) |origin| for ([_][]const u8{ "{\"id\":\"window\",\"command\":\"native-sdk.window.list\"}", "{\"id\":\"custom\",\"command\":\"custom\"}", "invalid" }) |raw| {
        for ([_]*Harness{ a, b }) |h| try h.runtime.dispatchPlatformEvent(.{ .context = h, .name = "authorization", .source = sdk.platform.WebViewSource.html("") }, .{ .bridge_message = .{ .bytes = raw, .origin = origin, .window_id = 1 } });
        try exact(a.null_platform.lastBridgeResponse(), b.null_platform.lastBridgeResponse());
        try exact(a.null_platform.lastBridgeResponseWindowId(), b.null_platform.lastBridgeResponseWindowId());
        try exact(a.runtime.automationSnapshot("authorization"), b.runtime.automationSnapshot("authorization"));
    };
    for (modes) |count| try std.testing.expect(count > 0);
}
test "compiled authorization preserves async denial source lifetime and deferred responses" {
    const Async = struct {
        calls: usize = 0,
        responder: ?sdk.bridge.AsyncResponder = null,
        fn invoke(context: *anyopaque, _: sdk.bridge.Invocation, responder: sdk.bridge.AsyncResponder) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.responder = responder;
        }
    };
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    b.runtime.authorization_policy = compiled;
    var states: [2]Async = .{ .{}, .{} };
    for ([_][]const u8{ "denied", "allowed" }) |origin| {
        for ([_]*Harness{ a, b }, 0..) |h, i| {
            const handlers = [_]sdk.bridge.AsyncHandler{.{ .name = "later", .context = &states[i], .invoke_fn = Async.invoke }};
            h.runtime.options.bridge = .{ .policy = .{ .enabled = true, .commands = &.{.{ .name = "later", .origins = &.{"allowed"} }} }, .async_registry = .{ .handlers = &handlers } };
            var label = "preview".*;
            var source = "allowed".*;
            try h.runtime.dispatchPlatformEvent(.{ .context = h, .name = "authorization", .source = sdk.platform.WebViewSource.html("") }, .{ .bridge_message = .{
                .bytes = "{\"id\":\"later\",\"command\":\"later\"}",
                .origin = if (std.mem.eql(u8, origin, "allowed")) &source else origin,
                .window_id = std.math.maxInt(u64),
                .webview_label = &label,
            } });
            @memset(&label, 'x');
            @memset(&source, 'x');
            if (states[i].responder) |responder| {
                try std.testing.expectEqualStrings("preview", responder.source.webview_label);
                try std.testing.expectEqualStrings("allowed", responder.source.origin);
                try std.testing.expectEqual(std.math.maxInt(u64), responder.source.window_id);
                try responder.success("later", "{\"done\":true}");
                states[i].responder = null;
            }
        }
        try exact(states[0].calls, states[1].calls);
        try exact(a.null_platform.lastBridgeResponse(), b.null_platform.lastBridgeResponse());
        try exact(a.null_platform.lastBridgeResponseWindowId(), b.null_platform.lastBridgeResponseWindowId());
        try exact(a.null_platform.lastBridgeResponseWebViewLabel(), b.null_platform.lastBridgeResponseWebViewLabel());
    }
    try std.testing.expectEqual(@as(usize, 1), states[0].calls);
}
