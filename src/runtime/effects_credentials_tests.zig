//! Tier-4 credential effect coverage. Secrets travel through the dedicated
//! keyed worker family, the app identity is the platform service namespace,
//! permission refusal is loud, and replay reconstructs only a deterministic
//! same-length placeholder from redacted journal metadata.

const std = @import("std");
const effects_mod = @import("effects.zig");
const core = @import("core.zig");
const clock_mod = @import("clock.zig");
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

const BlockingCredentialStore = struct {
    first_entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release_first: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    first_exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    abandon_noted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    call_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    mutex: std.atomic.Mutex = .unlocked,
    first_secret: [32]u8 = undefined,
    first_secret_len: usize = 0,
    stored_secret: [32]u8 = undefined,
    stored_secret_len: usize = 0,

    fn lock(self: *BlockingCredentialStore) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn set(context: ?*anyopaque, credential: platform.Credential) anyerror!void {
        const self: *BlockingCredentialStore = @ptrCast(@alignCast(context));
        const call = self.call_count.fetchAdd(1, .acq_rel);
        if (call == 0) {
            self.lock();
            const first_len = @min(credential.secret.len, self.first_secret.len);
            @memcpy(self.first_secret[0..first_len], credential.secret[0..first_len]);
            self.first_secret_len = first_len;
            self.mutex.unlock();
            self.first_entered.store(true, .release);
            while (!self.release_first.load(.acquire)) std.atomic.spinLoopHint();
        }
        self.lock();
        const stored_len = @min(credential.secret.len, self.stored_secret.len);
        @memcpy(self.stored_secret[0..stored_len], credential.secret[0..stored_len]);
        self.stored_secret_len = stored_len;
        self.mutex.unlock();
        if (call == 0) self.first_exited.store(true, .release);
    }

    fn noteAbandoned(context: ?*anyopaque) void {
        const self: *BlockingCredentialStore = @ptrCast(@alignCast(context));
        self.abandon_noted.store(true, .release);
    }

    fn waitFor(value: *std.atomic.Value(bool)) !void {
        for (0..1_000_000) |_| {
            if (value.load(.acquire)) return;
            std.Thread.yield() catch {};
        }
        return error.TestExpectedSignal;
    }
};

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
    try std.testing.expectEqual(@as(usize, 2_560), effects_mod.max_effect_credentials_secret_bytes);
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

    fx.credentialsGet(.{ .key = 14, .credential_key = "prefix\x00suffix", .on_result = Fx.credentialsMsg(.result) });
    const nul = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.over_bound, nul.outcome);

    var oversized_secret: [effects_mod.max_effect_credentials_secret_bytes + 1]u8 = undefined;
    @memset(&oversized_secret, 's');
    fx.credentialsSet(.{ .key = 15, .credential_key = "token", .secret = &oversized_secret, .on_result = Fx.credentialsMsg(.result) });
    const secret = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.over_bound, secret.outcome);
}

test "real credential replacements coalesce and execute in issue order" {
    var backing: BlockingCredentialStore = .{};
    var services: platform.PlatformServices = .{
        .context = &backing,
        .set_credential_fn = BlockingCredentialStore.set,
        .note_blocking_call_abandoned_fn = BlockingCredentialStore.noteAbandoned,
    };
    var fx = Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindCredentialsStore(.{
        .services = &services,
        .service = "dev.native-sdk.credentials-test",
        .permitted = true,
    });

    fx.credentialsSet(.{ .key = 40, .credential_key = "token", .secret = "old", .on_result = Fx.credentialsMsg(.result) });
    try BlockingCredentialStore.waitFor(&backing.first_entered);
    fx.credentialsSet(.{ .key = 40, .credential_key = "token", .secret = "new-1", .on_result = Fx.credentialsMsg(.result) });
    fx.credentialsSet(.{ .key = 40, .credential_key = "token", .secret = "new-2", .on_result = Fx.credentialsMsg(.result) });
    fx.credentialsSet(.{ .key = 40, .credential_key = "token", .secret = "new-3", .on_result = Fx.credentialsMsg(.result) });
    fx.credentialsSet(.{ .key = 40, .credential_key = "token", .secret = "new-4", .on_result = Fx.credentialsMsg(.result) });
    fx.credentialsSet(.{ .key = 40, .credential_key = "token", .secret = "new-5", .on_result = Fx.credentialsMsg(.result) });
    try std.testing.expectEqual(@as(usize, 1), backing.call_count.load(.acquire));

    backing.release_first.store(true, .release);
    const result = try takeResult(&fx);
    try std.testing.expectEqual(effects_mod.EffectCredentialsOutcome.ok, result.outcome);
    try std.testing.expectEqual(@as(usize, 2), backing.call_count.load(.acquire));
    backing.lock();
    defer backing.mutex.unlock();
    try std.testing.expectEqualStrings("old", backing.first_secret[0..backing.first_secret_len]);
    try std.testing.expectEqualStrings("new-5", backing.stored_secret[0..backing.stored_secret_len]);
}

test "credential teardown abandons a blocked platform call at its deadline" {
    var backing: BlockingCredentialStore = .{};
    var services: platform.PlatformServices = .{
        .context = &backing,
        .set_credential_fn = BlockingCredentialStore.set,
        .note_blocking_call_abandoned_fn = BlockingCredentialStore.noteAbandoned,
    };
    var fx = Fx.init(std.testing.allocator);
    fx.credentials_join_deadline_ms = 10;
    fx.bindCredentialsStore(.{
        .services = &services,
        .service = "dev.native-sdk.credentials-test",
        .permitted = true,
    });
    fx.credentialsSet(.{ .key = 41, .credential_key = "token", .secret = "blocked", .on_result = Fx.credentialsMsg(.result) });
    try BlockingCredentialStore.waitFor(&backing.first_entered);

    const start_ns = clock_mod.monotonicNanoseconds();
    fx.deinit();
    const elapsed_ms = (clock_mod.monotonicNanoseconds() - start_ns) / std.time.ns_per_ms;
    try std.testing.expect(elapsed_ms < 2_000);
    try std.testing.expectEqual(@as(u32, 1), fx.abandoned_credentials_workers);
    try std.testing.expect(backing.abandon_noted.load(.acquire));

    backing.release_first.store(true, .release);
    try BlockingCredentialStore.waitFor(&backing.first_exited);
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
