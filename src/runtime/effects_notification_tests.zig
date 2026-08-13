//! Desktop-notification effect coverage: `fx.showNotification` reaches
//! the existing platform notification service on the loop thread, rejects
//! malformed input before dispatch, and stays inert under fake execution
//! and session replay so tests/replays never produce user-visible alerts.

const std = @import("std");
const platform = @import("../platform/root.zig");
const effects_mod = @import("effects.zig");

const Msg = enum { unused };
const TestEffects = effects_mod.Effects(Msg);

test "notification effect delivers validated fields to the platform service" {
    var null_platform = platform.NullPlatform.init(.{});
    var host = null_platform.platform();
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host.services);

    fx.showNotification(.{
        .id = "build-status",
        .title = "Build finished",
        .subtitle = "native-sdk",
        .body = "All checks passed.",
        .action_label = "Open",
        .action_command = "build.open",
    });

    try std.testing.expectEqual(@as(usize, 1), null_platform.notificationCount());
    try std.testing.expectEqualStrings("Build finished", null_platform.lastNotificationTitle());
    try std.testing.expectEqualStrings("native-sdk", null_platform.lastNotificationSubtitle());
    try std.testing.expectEqualStrings("All checks passed.", null_platform.lastNotificationBody());
    try std.testing.expectEqualStrings("build-status", null_platform.lastNotificationId());
    try std.testing.expectEqualStrings("Open", null_platform.lastNotificationActionLabel());
    try std.testing.expectEqualStrings("build.open", null_platform.lastNotificationActionCommand());
}

test "notification effect rejects malformed and over-bound requests" {
    var null_platform = platform.NullPlatform.init(.{});
    var host = null_platform.platform();
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host.services);

    const long_title = [_]u8{'x'} ** (platform.max_notification_title_bytes + 1);
    const long_id = [_]u8{'x'} ** (platform.max_notification_id_bytes + 1);
    fx.showNotification(.{ .title = "" });
    fx.showNotification(.{ .title = "bad\x00title" });
    fx.showNotification(.{ .title = &long_title });
    fx.showNotification(.{ .id = &long_id, .title = "Bad id" });
    fx.showNotification(.{ .title = "Missing command", .action_label = "Open" });
    fx.showNotification(.{ .title = "Missing label", .action_command = "build.open" });
    fx.showNotification(.{ .title = "Invalid command", .action_label = "Open", .action_command = "../open" });

    try std.testing.expectEqual(@as(usize, 0), null_platform.notificationCount());
}

test "notification effect is inert without a service and during fake execution or replay" {
    var unbound = TestEffects.init(std.testing.allocator);
    defer unbound.deinit();
    unbound.showNotification(.{ .title = "No host" });

    var null_platform = platform.NullPlatform.init(.{});
    var host = null_platform.platform();
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host.services);

    fx.executor = .fake;
    fx.showNotification(.{ .title = "Fake" });
    try std.testing.expectEqual(@as(usize, 0), null_platform.notificationCount());

    fx.armReplay();
    fx.showNotification(.{ .title = "Replay" });
    try std.testing.expectEqual(@as(usize, 0), null_platform.notificationCount());
}
