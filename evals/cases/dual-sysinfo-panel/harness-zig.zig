//! Behavioral harness for dual-sysinfo-panel, zig track. Injected by the
//! grader as src/eval_behavior_spec.zig (a test import is appended to
//! src/main.zig) and run through `native test`, so it compiles against the
//! agent's real Model/Msg/update with the SDK in scope. Drives update with
//! the deterministic fake effects executor and asserts the same behavioral
//! spec the ts track's harness asserts: Refresh issues exactly one
//! collect-mode spawn of /usr/bin/uname -srm, results parse into the three
//! values, failures are honest, re-entry is guarded.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const testing = std.testing;

const Rig = struct {
    model: main.Model,
    fx: main.Effects,

    fn init() Rig {
        var fx = main.Effects.init(testing.allocator);
        fx.executor = .fake;
        return .{ .model = main.initialModel(), .fx = fx };
    }

    fn deinit(self: *Rig) void {
        self.fx.deinit();
    }

    fn dispatch(self: *Rig, msg: main.Msg) void {
        main.update(&self.model, msg, &self.fx);
    }

    /// Drain every fed effect result through the real dispatch path.
    fn drain(self: *Rig) void {
        while (self.fx.takeMsg()) |msg| main.update(&self.model, msg, &self.fx);
    }

    /// Refresh, then assert exactly one live collect spawn and return it.
    fn refreshedSpawn(self: *Rig) !main.Effects.SpawnRequest {
        self.dispatch(.refresh);
        const request = self.fx.pendingSpawnAt(0) orelse return error.NoSpawnIssued;
        try testing.expectEqual(@as(usize, 1), self.fx.pendingSpawnCount());
        return request;
    }
};

test "starts idle and empty" {
    var rig = Rig.init();
    defer rig.deinit();
    try testing.expect(rig.model.phase == .idle);
    try testing.expect(rig.model.osName().len == 0);
    try testing.expect(rig.model.releaseName().len == 0);
    try testing.expect(rig.model.machineName().len == 0);
    try testing.expect(rig.model.fail_code == 0);
}

test "refresh spawns uname -srm in collect mode and enters probing" {
    var rig = Rig.init();
    defer rig.deinit();
    const request = try rig.refreshedSpawn();
    try testing.expectEqual(native_sdk.EffectOutputMode.collect, request.output);
    try testing.expectEqual(@as(usize, 2), request.argv.len);
    try testing.expectEqualStrings("/usr/bin/uname", request.argv[0]);
    try testing.expectEqualStrings("-srm", request.argv[1]);
    try testing.expect(rig.model.phase == .probing);
}

test "a second refresh while probing issues nothing" {
    var rig = Rig.init();
    defer rig.deinit();
    _ = try rig.refreshedSpawn();
    rig.dispatch(.refresh);
    try testing.expectEqual(@as(usize, 1), rig.fx.pendingSpawnCount());
    try testing.expect(rig.model.phase == .probing);
}

test "a clean exit parses the three fields" {
    var rig = Rig.init();
    defer rig.deinit();
    const request = try rig.refreshedSpawn();
    try rig.fx.feedLine(request.key, "Darwin 24.6.0 arm64");
    try rig.fx.feedExit(request.key, 0);
    rig.drain();
    try testing.expect(rig.model.phase == .ok);
    try testing.expectEqualStrings("Darwin", rig.model.osName());
    try testing.expectEqualStrings("24.6.0", rig.model.releaseName());
    try testing.expectEqualStrings("arm64", rig.model.machineName());
    try testing.expect(rig.model.fail_code == 0);
}

test "the machine value is the rest of the line, not just one token" {
    var rig = Rig.init();
    defer rig.deinit();
    const request = try rig.refreshedSpawn();
    try rig.fx.feedLine(request.key, "Linux 6.8.0-45-generic x86_64 GNU");
    try rig.fx.feedExit(request.key, 0);
    rig.drain();
    try testing.expect(rig.model.phase == .ok);
    try testing.expectEqualStrings("Linux", rig.model.osName());
    try testing.expectEqualStrings("6.8.0-45-generic", rig.model.releaseName());
    try testing.expectEqualStrings("x86_64 GNU", rig.model.machineName());
}

test "a non-zero exit is a failure carrying the code" {
    var rig = Rig.init();
    defer rig.deinit();
    const request = try rig.refreshedSpawn();
    try rig.fx.feedExit(request.key, 3);
    rig.drain();
    try testing.expect(rig.model.phase == .failed);
    try testing.expect(rig.model.fail_code == 3);
}

test "a spawn failure is a failure, never silence" {
    var rig = Rig.init();
    defer rig.deinit();
    const request = try rig.refreshedSpawn();
    try rig.fx.feedExitReason(request.key, -1, .spawn_failed);
    rig.drain();
    try testing.expect(rig.model.phase == .failed);
}

test "a new refresh clears previous values and failures" {
    var rig = Rig.init();
    defer rig.deinit();
    const first = try rig.refreshedSpawn();
    try rig.fx.feedLine(first.key, "Darwin 24.6.0 arm64");
    try rig.fx.feedExit(first.key, 0);
    rig.drain();
    try testing.expect(rig.model.phase == .ok);

    rig.dispatch(.refresh);
    try testing.expect(rig.model.phase == .probing);
    try testing.expect(rig.model.osName().len == 0);
    try testing.expect(rig.model.releaseName().len == 0);
    try testing.expect(rig.model.machineName().len == 0);

    // Fail it, then refresh again: the failure clears too.
    const second = rig.fx.pendingSpawnAt(0) orelse return error.NoSpawnIssued;
    try rig.fx.feedExit(second.key, 7);
    rig.drain();
    try testing.expect(rig.model.phase == .failed);
    try testing.expect(rig.model.fail_code == 7);
    rig.dispatch(.refresh);
    try testing.expect(rig.model.phase == .probing);
    try testing.expect(rig.model.fail_code == 0);
}
