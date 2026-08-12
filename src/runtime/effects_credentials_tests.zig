//! Tier-4 credential effect coverage. Secrets travel through the dedicated
//! keyed worker family, the app identity is the platform service namespace,
//! permission refusal is loud, and replay reconstructs only a deterministic
//! same-length placeholder from redacted journal metadata.

const std = @import("std");
const effects_mod = @import("effects.zig");
const core = @import("core.zig");
const platform = @import("../platform/root.zig");

const Msg = union(enum) { result: effects_mod.EffectCredentialsResult };
const Fx = effects_mod.Effects(Msg);

test "credential test harness opts into hermetic backing" {
    const harness = try core.TestHarness().createWithCredentials(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    try std.testing.expect(harness.runtime.options.credentials_enabled);
    try std.testing.expectEqualStrings("dev.native_sdk.app", harness.runtime.options.platform.app_info.bundle_id);
}

fn takeResult(fx: *Fx) !effects_mod.EffectCredentialsResult {
    for (0..100_000) |_| {
        if (fx.takeMsg()) |msg| return msg.result;
        std.Thread.yield() catch {};
    }
    return error.TestExpectedMsg;
}

test "credential effects round-trip through the hermetic platform backing" {
    var null_platform = platform.NullPlatform.init(.{});
    defer null_platform.deinit();
    var services = null_platform.platform();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindCredentialsStore(.{
        .services = &services.services,
        .service = "dev.native-sdk.credentials-test",
        .permitted = true,
    });

    fx.credentialsSet(.{
        .key = 1,
        .credential_key = "api-token",
        .secret = "live-secret",
        .on_result = Fx.credentialsMsg(.result),
    });
    const set = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, set.outcome);
    try std.testing.expectEqualStrings("dev.native-sdk.credentials-test", null_platform.lastCredentialService());
    try std.testing.expectEqualStrings("api-token", null_platform.lastCredentialAccount());

    fx.credentialsGet(.{ .key = 2, .credential_key = "api-token", .on_result = Fx.credentialsMsg(.result) });
    const get = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, get.outcome);
    try std.testing.expectEqualStrings("live-secret", get.bytes);

    fx.credentialsDelete(.{ .key = 3, .credential_key = "api-token", .on_result = Fx.credentialsMsg(.result) });
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, (try takeResult(&fx)).outcome);
    fx.credentialsGet(.{ .key = 4, .credential_key = "api-token", .on_result = Fx.credentialsMsg(.result) });
    const miss = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.miss, miss.outcome);
    try std.testing.expectEqualStrings("", miss.bytes);

    // Delete is idempotent even though the platform reports absence.
    fx.credentialsDelete(.{ .key = 5, .credential_key = "api-token", .on_result = Fx.credentialsMsg(.result) });
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, (try takeResult(&fx)).outcome);

    // Uint8Array includes the empty byte string; presence is independent
    // from payload length all the way through the platform adapter.
    fx.credentialsSet(.{
        .key = 6,
        .credential_key = "empty",
        .secret = "",
        .on_result = Fx.credentialsMsg(.result),
    });
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, (try takeResult(&fx)).outcome);
    fx.credentialsGet(.{ .key = 7, .credential_key = "empty", .on_result = Fx.credentialsMsg(.result) });
    const empty = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, empty.outcome);
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);

    // The TypeScript surface accepts Uint8Array, not text: zeros and invalid
    // UTF-8 must survive the complete worker/platform/result path.
    const binary = [_]u8{ 0x00, 0xff, 0x80, 0x41, 0x00 };
    fx.credentialsSet(.{
        .key = 8,
        .credential_key = "binary",
        .secret = &binary,
        .on_result = Fx.credentialsMsg(.result),
    });
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, (try takeResult(&fx)).outcome);
    fx.credentialsGet(.{ .key = 9, .credential_key = "binary", .on_result = Fx.credentialsMsg(.result) });
    const binary_get = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, binary_get.outcome);
    try std.testing.expectEqualSlices(u8, &binary, binary_get.bytes);
}

test "credential permission and bounds failures are staged closed outcomes" {
    var null_platform = platform.NullPlatform.init(.{});
    defer null_platform.deinit();
    var services = null_platform.platform();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();

    // A refused batch remains loud and ordered even though no worker starts.
    fx.credentialsSet(.{ .key = 10, .credential_key = "one", .secret = "a", .on_result = Fx.credentialsMsg(.result) });
    fx.credentialsGet(.{ .key = 11, .credential_key = "two", .on_result = Fx.credentialsMsg(.result) });
    fx.credentialsDelete(.{ .key = 12, .credential_key = "three", .on_result = Fx.credentialsMsg(.result) });
    const denied_set = try takeResult(&fx);
    const denied_get = try takeResult(&fx);
    const denied_delete = try takeResult(&fx);
    try std.testing.expectEqual(@as(u64, 10), denied_set.key);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOperation.set, denied_set.operation);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.denied, denied_set.outcome);
    try std.testing.expectEqual(@as(u64, 11), denied_get.key);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOperation.get, denied_get.operation);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.denied, denied_get.outcome);
    try std.testing.expectEqual(@as(u64, 12), denied_delete.key);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOperation.delete, denied_delete.operation);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.denied, denied_delete.outcome);

    fx.bindCredentialsStore(.{
        .services = &services.services,
        .service = "dev.native-sdk.credentials-test",
        .permitted = true,
    });
    var oversized_key: [effects_mod.max_effect_credentials_key_bytes + 1]u8 = undefined;
    @memset(&oversized_key, 'k');
    fx.credentialsGet(.{ .key = 13, .credential_key = &oversized_key, .on_result = Fx.credentialsMsg(.result) });
    const bounded = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.over_bound, bounded.outcome);
}

test "credential effects replace by key and own four slots" {
    var null_platform = platform.NullPlatform.init(.{});
    defer null_platform.deinit();
    var services = null_platform.platform();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindCredentialsStore(.{
        .services = &services.services,
        .service = "dev.native-sdk.credentials-test",
        .permitted = true,
    });

    fx.credentialsGet(.{ .key = 30, .credential_key = "old", .on_result = Fx.credentialsMsg(.result) });
    fx.credentialsGet(.{ .key = 30, .credential_key = "replacement", .on_result = Fx.credentialsMsg(.result) });
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    try std.testing.expectEqualStrings("replacement", blk: {
        var at: usize = 0;
        const payload = fx.pendingHostAt(0).?.payload;
        const len: usize = std.mem.readInt(u32, payload[0..4], .little);
        at += 4;
        break :blk payload[at .. at + len];
    });

    // The replacement occupies one credential-reserved slot; three more fit,
    // while the fifth concurrent operation is rejected without borrowing a
    // file/fetch or record-store slot.
    fx.credentialsGet(.{ .key = 31, .credential_key = "a", .on_result = Fx.credentialsMsg(.result) });
    fx.credentialsGet(.{ .key = 32, .credential_key = "b", .on_result = Fx.credentialsMsg(.result) });
    fx.credentialsGet(.{ .key = 33, .credential_key = "c", .on_result = Fx.credentialsMsg(.result) });
    try std.testing.expectEqual(effects_mod.max_credentials_effects, fx.pendingHostCount());
    fx.credentialsGet(.{ .key = 34, .credential_key = "full", .on_result = Fx.credentialsMsg(.result) });
    const rejected = try takeResult(&fx);
    try std.testing.expectEqual(@as(u64, 34), rejected.key);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.rejected, rejected.outcome);
}

test "credential replay delivers a deterministic redacted placeholder" {
    var null_platform = platform.NullPlatform.init(.{});
    defer null_platform.deinit();
    var services = null_platform.platform();
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindCredentialsStore(.{
        .services = &services.services,
        .service = "dev.native-sdk.credentials-test",
        .permitted = true,
    });

    fx.credentialsGet(.{ .key = 20, .credential_key = "token", .on_result = Fx.credentialsMsg(.result) });
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    const request = fx.pendingHostAt(0).?;
    try std.testing.expectEqualStrings("core.credentials.get", request.name);

    const digest = [_]u8{0x5a} ** 32;
    try fx.feedCredentialsResult(20, .get, .ok, 12, digest);
    const first = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, first.outcome);
    try std.testing.expectEqual(@as(usize, 12), first.bytes.len);
    try std.testing.expect(!std.mem.eql(u8, "live-secret", first.bytes));
    var first_copy: [12]u8 = undefined;
    @memcpy(&first_copy, first.bytes);

    fx.credentialsGet(.{ .key = 21, .credential_key = "token", .on_result = Fx.credentialsMsg(.result) });
    try fx.feedCredentialsResult(21, .get, .ok, 12, digest);
    const second = try takeResult(&fx);
    try std.testing.expectEqualSlices(u8, &first_copy, second.bytes);

    fx.credentialsGet(.{ .key = 22, .credential_key = "missing", .on_result = Fx.credentialsMsg(.result) });
    try fx.feedCredentialsResult(22, .get, .miss, 0, [_]u8{0} ** 32);
    const miss = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.miss, miss.outcome);
    try std.testing.expectEqualStrings("", miss.bytes);
}
