const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const policy = sdk.runtime.testing.system_admission_policy;
const reference = sdk.runtime.testing.reference_descriptor_validation;
var modes: [7]usize = @splat(0);
var comparisons: usize = 0;
fn compiled(input: []const u8, output: []u8) usize {
    if (input[0] == 86) modes[input[2]] += 1;
    return core.nativeWindowPolicy(input, output);
}
fn failure(outcome: anyerror!void) ?anyerror {
    outcome catch |err| return err;
    return null;
}
fn compare(a: anyerror!void, b: anyerror!void) !void {
    try std.testing.expectEqual(failure(a), failure(b));
    comparisons += 1;
}
fn result(a: anytype, b: @TypeOf(a)) !void {
    const left = a catch |err| {
        try std.testing.expectError(err, b);
        return;
    };
    try exact(left, try b);
}
test "compiled system admission preserves path MIME and opaque payload boundaries" {
    var bytes: [65537]u8 = @splat('x');
    for ([_]usize{ 0, 1, 2, 127, 128, 129, 255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097, 65535, 65536, 65537 }) |size| {
        const value = bytes[0..size];
        try compare(reference.validateRevealPath(value), policy.reveal(compiled, value));
        try compare(reference.validateRecentDocumentPath(value), policy.recent(compiled, value));
        try compare(reference.validateClipboardMimeType(value), policy.mime(compiled, value));
        try compare(reference.validateClipboardData(.{ .mime_type = "text/plain", .bytes = value }), policy.clipboard(compiled, .{ .mime_type = "text/plain", .bytes = value }));
        if (size > 0) {
            bytes[size - 1] = 0;
            try compare(reference.validateRevealPath(value), policy.reveal(compiled, value));
            try compare(reference.validateRecentDocumentPath(value), policy.recent(compiled, value));
            try compare(reference.validateClipboardMimeType(value), policy.mime(compiled, value));
            bytes[size - 1] = 'x';
        }
    }
    for ([_][]const u8{ "", ".", "..", "/", "text/plain", "a/b/c", "a\\b", "white space", "a\x00b", "\n", "\t", "\x7f", "\xff\xfe" }) |value| {
        try compare(reference.validateRevealPath(value), policy.reveal(compiled, value));
        try compare(reference.validateRecentDocumentPath(value), policy.recent(compiled, value));
        try compare(reference.validateClipboardMimeType(value), policy.mime(compiled, value));
        try compare(reference.validateClipboardData(.{ .mime_type = value, .bytes = &bytes }), policy.clipboard(compiled, .{ .mime_type = value, .bytes = &bytes }));
    }
}
test "compiled system admission preserves every dialog field and complete refusal precedence" {
    var bytes: [4097]u8 = @splat('x');
    var buffer: [8]u8 = undefined;
    for ([_]usize{ 0, 1, 127, 128, 129, 255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097 }) |size| for ([_]bool{ false, true }) |nul| {
        if (size > 0) bytes[size - 1] = if (nul) 0 else 'x';
        const value = bytes[0..size];
        for ([_]usize{ 0, 1 }) |output_size| {
            const open = sdk.platform.OpenDialogOptions{ .title = value, .default_path = value, .filters = &.{.{ .name = value, .extensions = &.{value} }} };
            const save = sdk.platform.SaveDialogOptions{ .title = value, .default_path = value, .default_name = value, .filters = open.filters };
            try compare(reference.validateOpenDialogOptions(open, buffer[0..output_size]), policy.open(compiled, open, buffer[0..output_size]));
            try compare(reference.validateSaveDialogOptions(save, buffer[0..output_size]), policy.save(compiled, save, buffer[0..output_size]));
        }
        inline for (.{ "title", "message", "informative_text", "primary_button", "secondary_button", "tertiary_button" }) |member| {
            var options = sdk.platform.MessageDialogOptions{};
            @field(options, member) = value;
            try compare(reference.validateMessageDialogOptions(options), policy.message(compiled, options));
        }
        if (size > 0) bytes[size - 1] = 'x';
    };
    for ([_][]const u8{ "", "valid", "bad\x00", "\xff", "bad;extension", "a/b" }) |value| {
        const filters = [_]sdk.platform.FileFilter{ .{ .name = value, .extensions = &.{value} }, .{ .name = "second", .extensions = &.{"txt"} } };
        const open = sdk.platform.OpenDialogOptions{ .filters = &filters };
        try compare(reference.validateOpenDialogOptions(open, &buffer), policy.open(compiled, open, &buffer));
    }
}
test "compiled system admission preserves exact filter accumulation across groups" {
    var bytes: [1025]u8 = @splat('x');
    var extensions: [1025][]const u8 = @splat("x");
    var buffer: [1]u8 = undefined;
    for ([_]usize{ 0, 1, 511, 512, 513, 1024, 1025 }) |count| {
        const filters = [_]sdk.platform.FileFilter{ .{ .name = "", .extensions = extensions[0..count] }, .{ .name = "next", .extensions = &.{"z"} } };
        const options = sdk.platform.OpenDialogOptions{ .filters = &filters };
        try compare(reference.validateOpenDialogOptions(options, &buffer), policy.open(compiled, options, &buffer));
    }
    for ([_]usize{ 1, 1023, 1024, 1025 }) |count| for ([_][]const u8{ "", "x", "x;", "\x00" }) |tail| {
        const options = sdk.platform.SaveDialogOptions{ .filters = &.{.{ .name = "", .extensions = &.{ bytes[0..count], tail } }} };
        try compare(reference.validateSaveDialogOptions(options, &buffer), policy.save(compiled, options, &buffer));
    };
}
test "compiled system admission preserves notification field order and paired action commands" {
    var bytes: [1025]u8 = @splat('x');
    for ([_]usize{ 0, 1, 127, 128, 129, 1023, 1024, 1025 }) |size| for ([_]bool{ false, true }) |nul| {
        if (size > 0) bytes[size - 1] = if (nul) 0 else 'x';
        inline for (.{ "id", "title", "subtitle", "body", "action_label", "action_command" }) |member| {
            var options = sdk.platform.NotificationOptions{ .title = "Notice" };
            @field(options, member) = bytes[0..size];
            try compare(reference.validateNotificationOptions(options), policy.notification(compiled, options));
        }
        const options = sdk.platform.NotificationOptions{ .id = bytes[0..size], .title = if (nul) "" else "Notice", .action_label = "open", .action_command = "a/b" };
        try compare(reference.validateNotificationOptions(options), policy.notification(compiled, options));
        if (size > 0) bytes[size - 1] = 'x';
    };
    for ([_][]const u8{ "", ".", "..", "white space", "valid.command", "a/b", "a\\b", "a\n", "a\r", "a\t", "a\x00b", "\xff" }) |value| for ([_][]const u8{ "", "Action", "a\x00" }) |caption| {
        const options = sdk.platform.NotificationOptions{ .title = "Notice", .action_label = caption, .action_command = value };
        try compare(reference.validateNotificationOptions(options), policy.notification(compiled, options));
    };
}
fn state(a: anytype, b: @TypeOf(a)) !void {
    try exact(a.runtime.automationSnapshot("system-admission"), b.runtime.automationSnapshot("system-admission"));
    const left = &a.null_platform;
    const right = &b.null_platform;
    inline for (.{ "open_dialog_count", "save_dialog_count", "message_dialog_count", "message_dialog_result" }) |member| try exact(@field(left, member), @field(right, member));
    inline for (.{ "lastRevealedPath", "lastRecentDocumentPath", "lastClipboardMimeType", "lastClipboardData", "lastNotificationId", "lastNotificationTitle", "lastNotificationSubtitle", "lastNotificationBody", "lastNotificationActionLabel", "lastNotificationActionCommand" }) |name| try exact(@field(sdk.platform.NullPlatform, name)(left), @field(sdk.platform.NullPlatform, name)(right));
    try exact(left.clipboardWriteCount(), right.clipboardWriteCount());
    try exact(left.notificationCount(), right.notificationCount());
    try exact(left.notificationReplacementCount(), right.notificationReplacementCount());
}
test "compiled system admission preserves complete runtime services and borrowed output buffers" {
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    for ([_]*Harness{ a, b }, 0..) |h, i| {
        try h.start(.{ .context = h, .name = "system-admission", .source = sdk.platform.WebViewSource.html(""), .system_admission_policy = if (i == 1) compiled else null });
        h.runtime.started_timestamp_ns = 0;
    }
    for ([_][]const u8{ "", "bad\x00", "healthy", "\xff", "retry" }) |value| {
        try compare(a.runtime.revealPath(value), b.runtime.revealPath(value));
        try compare(a.runtime.addRecentDocument(value), b.runtime.addRecentDocument(value));
        try compare(a.runtime.writeClipboardData(.{ .mime_type = "text/plain", .bytes = value }), b.runtime.writeClipboardData(.{ .mime_type = "text/plain", .bytes = value }));
        try compare(a.runtime.showNotification(.{ .id = "notice", .title = value }), b.runtime.showNotification(.{ .id = "notice", .title = value }));
        try state(a, b);
        var left: [128]u8 = @splat(0xa5);
        var right: [128]u8 = @splat(0xa5);
        for ([_]usize{ 0, 1, 128 }) |capacity| {
            try result(a.runtime.showOpenDialog(.{ .title = value }, left[0..capacity]), b.runtime.showOpenDialog(.{ .title = value }, right[0..capacity]));
            try result(a.runtime.showSaveDialog(.{ .default_name = value }, left[0..capacity]), b.runtime.showSaveDialog(.{ .default_name = value }, right[0..capacity]));
            try result(a.runtime.readClipboardData("text/plain", left[0..capacity]), b.runtime.readClipboardData("text/plain", right[0..capacity]));
            try exact(left, right);
            try state(a, b);
        }
        try result(a.runtime.showMessageDialog(.{ .primary_button = value }), b.runtime.showMessageDialog(.{ .primary_button = value }));
        try state(a, b);
    }
}
test "compiled system admission notification effects stay inert for fake execution and replay" {
    const Fx = sdk.Effects(enum { unused });
    var host = sdk.platform.NullPlatform.init(.{});
    var native = host.platform();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.system_admission_policy = compiled;
    fx.bindServices(&native.services);
    fx.showNotification(.{ .title = "healthy" });
    fx.showNotification(.{ .title = "bad\x00" });
    try std.testing.expectEqual(@as(usize, 1), host.notificationCount());
    const before = modes[4];
    fx.executor = .fake;
    fx.showNotification(.{ .title = "fake" });
    fx.executor = .real;
    fx.armReplay();
    fx.showNotification(.{ .title = "replay" });
    try std.testing.expectEqual(before, modes[4]);
    try std.testing.expectEqual(@as(usize, 1), host.notificationCount());
}
test "compiled system admission exercises all modes and complete descriptor corpus" {
    try std.testing.expect(comparisons > 500);
    for (modes) |count| try std.testing.expect(count > 0);
}
