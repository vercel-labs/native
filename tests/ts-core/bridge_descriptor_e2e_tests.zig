const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const policy = sdk.runtime.testing.bridge_descriptor_policy;
const reference = sdk.runtime.testing.reference_bridge_payload;
var modes: [6]usize = @splat(0);
fn compiled(input: []const u8, output: []u8) usize {
    if (input[0] == 87) modes[input[2]] += 1;
    return core.nativeWindowPolicy(input, output);
}
fn result(a: anytype, b: anytype) !void {
    const left = a catch |err| {
        try std.testing.expectError(err, b);
        return;
    };
    try exact(left, try b);
}
fn gpu(payload: []const u8) !void {
    var left: [1024]u8 = @splat(0xa5);
    var right: [1024]u8 = @splat(0xa5);
    var a = policy.StringStorage.init(&left);
    var b = policy.StringStorage.init(&right);
    try result(reference.gpuSurfaceOptionsFromJson(payload, &a), policy.gpuSurfaceOptionsFromJson(compiled, payload, &b));
    try exact(left, right);
    try std.testing.expectEqual(a.index, b.index);
}
test "compiled bridge descriptors preserve every native enum and complete compatibility vocabulary" {
    inline for (.{ sdk.platform.ViewKind, sdk.platform.WindowTitlebarStyle, sdk.platform.PlatformFeature }, 0..) |T, family| {
        inline for (@typeInfo(T).@"enum".fields) |field| {
            const value = @field(T, field.name);
            switch (family) {
                0 => try std.testing.expectEqual(value, policy.viewKindFromString(compiled, field.name).?),
                1 => try std.testing.expectEqual(value, policy.windowTitlebarStyleFromString(compiled, field.name).?),
                2 => try std.testing.expectEqual(value, policy.platformFeatureFromString(compiled, field.name).?),
                else => unreachable,
            }
        }
    }
    for ([_][]const u8{ "", "NONE", "none", "webview", "titlebarAccessory", "iconButton", "listItem", "segmentedControl", "textField", "searchField", "gpuSurface", "progressIndicator", "hiddenInset", "hiddenInsetTall", "mainWebView", "childWebViews", "nativeViews", "nativeControlCommands", "clipboardText", "clipboardRichData", "openUrl", "revealPath", "recentDocuments", "fileDrops", "appActivationEvents", "gpuSurfaces", "gpuSurfaceScrollDrivers", "contextMenus", "viewSurfaceAdoption", "audioPlayback", "audioStreaming", "audioSpectrum", "microphoneCapture", "systemAudioCapture", "windowHideOnClose", "videoPlayback", "keyboardInput", "webview\x00", "\xff", " webview", "webview " }) |name| {
        try std.testing.expectEqual(reference.viewKindFromString(name), policy.viewKindFromString(compiled, name));
        try std.testing.expectEqual(reference.windowTitlebarStyleFromString(name), policy.windowTitlebarStyleFromString(compiled, name));
        try std.testing.expectEqual(reference.platformFeatureFromString(name), policy.platformFeatureFromString(compiled, name));
    }
    var bytes: [1024]u8 = @splat('x');
    for ([_]usize{ 0, 1, 63, 64, 65, 1024 }) |count| try std.testing.expectEqual(reference.viewKindFromString(bytes[0..count]), policy.viewKindFromString(compiled, bytes[0..count]));
}
test "compiled bridge descriptors preserve GPU defaults aliases wrong types and decoding ownership" {
    try gpu("{}");
    inline for (.{ "gpuBackend", "gpuPixelFormat", "gpuPresentMode", "gpuAlphaMode", "gpuColorSpace" }, .{ "gpu_backend", "gpu_pixel_format", "gpu_present_mode", "gpu_alpha_mode", "gpu_color_space" }) |camel, snake| {
        var text: [1024]u8 = undefined;
        for ([_][]const u8{ "none", "metal", "direct2d", "software", "bgra8_unorm", "timer", "opaque", "premultiplied", "srgb", "display_p3", "unknown", "", "NONE", "no\\u006ee" }) |value| {
            try gpu(try std.fmt.bufPrint(&text, "{{\"{s}\":\"{s}\",\"{s}\":\"none\"}}", .{ camel, value, snake }));
            try gpu(try std.fmt.bufPrint(&text, "{{\"{s}\":12,\"{s}\":\"{s}\"}}", .{ camel, snake, value }));
        }
    }
    for ([_][]const u8{ "{\"gpuBackend\":\"bad\",\"gpuPixelFormat\":\"bgra8\\u005funorm\"}", "{\"gpuBackend\":null,\"gpu_backend\":\"metal\"}", "{\"gpuVsync\":false,\"gpu_vsync\":true}", "{\"gpuVsync\":12,\"gpu_vsync\":false}", "{\"gpuBackend\":\"m\\u0065tal\",\"gpuColorSpace\":\"display_p3\"}" }) |payload| try gpu(payload);
}
test "compiled bridge descriptors preserve exact window identity and complete refusal precedence" {
    var bytes: [256]u8 = undefined;
    for ([_]u64{ 0, 1, 9007199254740992, 9007199254740993, std.math.maxInt(u64) }) |owner| {
        for ([_][]const u8{ "{}", "{\"windowId\":null}", "{\"windowId\":-1}", "{\"windowId\":0.5}", "{\"windowId\":\"1\"}", "{\"windowId\":18446744073709551616}" }) |payload| {
            try result(reference.webViewWindowIdFromJson(payload, owner), policy.webViewWindowIdFromJson(compiled, payload, owner));
            try result(reference.viewWindowIdFromJson(payload, owner), policy.viewWindowIdFromJson(compiled, payload, owner));
        }
        for ([_]u64{ owner, owner ^ 1 }) |value| {
            const payload = try std.fmt.bufPrint(&bytes, "{{\"windowId\":{d}}}", .{value});
            try result(reference.webViewWindowIdFromJson(payload, owner), policy.webViewWindowIdFromJson(compiled, payload, owner));
            try result(reference.viewWindowIdFromJson(payload, owner), policy.viewWindowIdFromJson(compiled, payload, owner));
        }
    }
}
test "compiled bridge descriptors preserve every view and WebView frame field" {
    var text: [256]u8 = undefined;
    for ([_][]const u8{ "{}", "{\"frame\":null}", "{\"frame\":{}}", "{\"width\":1,\"height\":2}", "{\"frame\":{\"width\":0,\"height\":0}}", "{\"frame\":{\"width\":1,\"height\":2,\"x\":\"bad\",\"y\":null}}" }) |payload| {
        for ([_]bool{ false, true }) |required| try result(reference.viewFrameFromJson(payload, required), policy.viewFrameFromJson(compiled, payload, required));
        try result(reference.webViewFrameFromJson(payload), policy.webViewFrameFromJson(compiled, payload));
    }
    for ([_][]const u8{ "x", "y", "width", "height" }) |field| for ([_][]const u8{ "-1", "-0", "0", "0.1", "1", "1e38", "1e39", "null", "\"1\"", "false", "[]", "{}" }) |value| {
        const payload = try std.fmt.bufPrint(&text, "{{\"frame\":{{\"{s}\":{s},\"width\":20,\"height\":30}}}}", .{ field, value });
        for ([_]bool{ false, true }) |required| try result(reference.viewFrameFromJson(payload, required), policy.viewFrameFromJson(compiled, payload, required));
        try result(reference.webViewFrameFromJson(payload), policy.webViewFrameFromJson(compiled, payload));
    };
}
test "compiled bridge descriptors preserve signed layers parsing and optional defaults" {
    var text: [128]u8 = undefined;
    for ([_][]const u8{ "{}", "{\"layer\":null}" }) |payload| {
        try result(reference.viewLayerFromJson(payload), policy.viewLayerFromJson(compiled, payload));
        try result(reference.webViewLayerFromJson(payload), policy.webViewLayerFromJson(compiled, payload));
    }
    for ([_][]const u8{ "-2147483649", "-2147483648", "-0", "0", "2147483647", "2147483648", "0.5", "1e39", "false", "[]", "\"1\"" }) |value| {
        const payload = try std.fmt.bufPrint(&text, "{{\"layer\":{s}}}", .{value});
        try result(reference.viewLayerFromJson(payload), policy.viewLayerFromJson(compiled, payload));
        try result(reference.webViewLayerFromJson(payload), policy.webViewLayerFromJson(compiled, payload));
    }
}
fn origin(url: []const u8, capacity: usize) !void {
    var left: [2048]u8 = @splat(0xa5);
    var right: [2048]u8 = @splat(0xa5);
    const expected = reference.webViewUrlOrigin(url, left[0..capacity]) catch |err| {
        try std.testing.expectError(err, policy.webViewUrlOrigin(compiled, url, right[0..capacity]));
        try exact(left, right);
        return;
    };
    const actual = try policy.webViewUrlOrigin(compiled, url, right[0..capacity]);
    try exact(expected, actual);
    try exact(left, right);
    if (!std.mem.startsWith(u8, url, "about:")) try std.testing.expect(actual.ptr == right[0..].ptr);
}
test "compiled bridge descriptors preserve complete origin bytes and borrowed buffer extents" {
    for ([_][]const u8{ "", "about:", "about:anything", "ABOUT:blank", "about", "://", "://host", ":///", "https://", "https://?q", "odd://host", "odd://host/path", "odd://host?query", "odd://host#fragment", "x:://a", "scheme://a\x00b/path", "\xff://\xfe" }) |url| {
        for ([_]usize{ 0, 1, 9, 10, 11, 2048 }) |capacity| try origin(url, capacity);
    }
    var bytes: [1536]u8 = @splat('x');
    for ([_]usize{ 253, 254, 255, 256, 257, 509, 510, 511, 512, 513 }) |position| {
        @memcpy(bytes[position..][0..3], "://");
        bytes[position + 263] = '/';
        for ([_]usize{ 0, position + 262, position + 263, 2048 }) |capacity| try origin(&bytes, capacity);
        @memset(bytes[position..][0..3], 'x');
        bytes[position + 263] = 'x';
    }
}
test "compiled bridge descriptors bind runtime services and preserve complete retry snapshots" {
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    for ([_]*Harness{ a, b }, 0..) |h, i| {
        try h.start(.{ .context = h, .name = "bridge-descriptors", .source = sdk.platform.WebViewSource.html(""), .bridge_descriptor_policy = if (i == 1) compiled else null });
        h.runtime.started_timestamp_ns = 0;
    }
    var left: [4096]u8 = @splat(0xa5);
    var right: [4096]u8 = @splat(0xa5);
    for ([_][]const u8{ "{\"feature\":\"nativeViews\"}", "{\"feature\":\"unknown\"}", "{\"feature\":\"gpuSurfaces\"}" }) |payload| try result(sdk.runtime.testing.command_services.supportsFeatureFromJson(&a.runtime, payload, &left), sdk.runtime.testing.command_services.supportsFeatureFromJson(&b.runtime, payload, &right));
    for ([_][]const u8{ "{\"label\":\"test\",\"kind\":\"textField\",\"frame\":{\"width\":20,\"height\":10}}", "{\"label\":\"bad\",\"kind\":\"unknown\"}", "{\"label\":\"retry\",\"kind\":\"gpuSurface\",\"gpuBackend\":\"software\"}" }) |payload| {
        try result(sdk.runtime.testing.builtin_bridge_methods.createViewFromJson(&a.runtime, payload, 1, &left), sdk.runtime.testing.builtin_bridge_methods.createViewFromJson(&b.runtime, payload, 1, &right));
        try exact(a.runtime.automationSnapshot("bridge-descriptors"), b.runtime.automationSnapshot("bridge-descriptors"));
        try exact(left, right);
    }
}
