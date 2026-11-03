//! A compiled core's global shortcuts through the real effects engine and the null platform host.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("global_shortcut_core");
const testing = std.testing;
const Host = sdk.TsCoreHost(core);

fn expectEntry(index: usize, id: []const u8, state: []const u8, arm: []const u8) !void {
    const log = Host.model().log;
    try testing.expect(index < log.len);
    try testing.expectEqualStrings(id, log[index].id);
    try testing.expectEqualStrings(state, @tagName(log[index].state));
    try testing.expectEqualStrings(arm, @tagName(log[index].arm));
}

test "reports reach the declaring arm in order, a removed held shortcut still releases, and an invalid id is rejected" {
    var host = sdk.platform.NullPlatform.init(.{});
    defer host.deinit();
    var platform = host.platform();
    var fx: Host.Fx = .init(testing.allocator);
    defer fx.deinit();
    fx.bindServices(&platform.services);
    Host.init(&fx);
    Host.drain(&fx);
    try expectEntry(0, "a", "registered", "a");

    try testing.expect(host.pushGlobalShortcut("a", .pressed));
    Host.drain(&fx);
    try testing.expect(host.pushGlobalShortcut("a", .released));
    Host.drain(&fx);
    try testing.expect(host.pushGlobalShortcut("a", .pressed));
    Host.drain(&fx);
    try expectEntry(1, "a", "pressed", "a");
    try expectEntry(2, "a", "released", "a");
    try expectEntry(3, "a", "pressed", "a");

    Host.dispatch(&fx, .swap);
    Host.drain(&fx);
    try expectEntry(4, "a", "released", "a");
    try expectEntry(5, "b", "registered", "b");
    try testing.expectEqual(@as(usize, 6), Host.model().log.len);

    Host.dispatch(&fx, .invalidate);
    Host.drain(&fx);
    try expectEntry(6, "", "rejected", "bad");
    try testing.expectEqual(@as(usize, 7), Host.model().log.len);

    Host.dispatch(&fx, .noop);
    Host.drain(&fx);
    try testing.expectEqual(@as(usize, 7), Host.model().log.len);
}
