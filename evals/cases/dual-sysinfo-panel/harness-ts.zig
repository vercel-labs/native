//! Behavioral harness for dual-sysinfo-panel, ts track. The grader copies
//! this next to the transpiled core.zig, the rt kernel, and cmdview.zig,
//! then runs `zig test harness.zig`. Asserts the shared behavioral spec:
//! Refresh issues exactly one collect-mode spawn of /usr/bin/uname -srm,
//! results parse into the three fields, failures are honest, re-entry is
//! guarded.

const std = @import("std");
const core = @import("core.zig");
const cmdview = @import("cmdview.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;
var g_buf: [4096]u8 = undefined;

fn fresh() void {
    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();
}

fn dispatch(msg: core.Msg) []const u8 {
    const r = core.update(g_model, msg);
    g_model = core.commitModelRoot(r.model);
    @memcpy(g_buf[0..r.cmd.len], r.cmd);
    rt.frameReset();
    return g_buf[0..r.cmd.len];
}

test "starts idle and empty" {
    fresh();
    try std.testing.expect(g_model.phase == .idle);
    try std.testing.expect(core.osName(g_model).len == 0);
    try std.testing.expect(core.releaseName(g_model).len == 0);
    try std.testing.expect(core.machineName(g_model).len == 0);
    try std.testing.expect(g_model.fail_code == 0);
}

test "refresh spawns uname -srm in collect mode and enters probing" {
    fresh();
    const cmd = dispatch(.refresh);
    const spawn = cmdview.findOp(cmd, .spawn) orelse return error.NoSpawnIssued;
    try std.testing.expectEqual(@as(u8, 1), spawn.mode); // collect
    try std.testing.expectEqual(@as(u8, 2), spawn.arg_count);
    try std.testing.expectEqualStrings("/usr/bin/uname", spawn.arg(0));
    try std.testing.expectEqualStrings("-srm", spawn.arg(1));
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).info_done), spawn.exit_tag);
    try std.testing.expectEqual(@intFromEnum(std.meta.Tag(core.Msg).info_failed), spawn.err_tag);
    try std.testing.expect(g_model.phase == .probing);
}

test "a second refresh while probing issues nothing" {
    fresh();
    _ = dispatch(.refresh);
    const second = dispatch(.refresh);
    try std.testing.expectEqual(@as(usize, 0), cmdview.countOps(second, .spawn));
    try std.testing.expect(g_model.phase == .probing);
}

test "a clean exit parses the three fields" {
    fresh();
    _ = dispatch(.refresh);
    _ = dispatch(.{ .info_done = .{ .code = 0, .output = "Darwin 24.6.0 arm64\n" } });
    try std.testing.expect(g_model.phase == .ok);
    try std.testing.expectEqualStrings("Darwin", core.osName(g_model));
    try std.testing.expectEqualStrings("24.6.0", core.releaseName(g_model));
    try std.testing.expectEqualStrings("arm64", core.machineName(g_model));
    try std.testing.expect(g_model.fail_code == 0);
}

test "the machine value is the rest of the line, not just one token" {
    fresh();
    _ = dispatch(.refresh);
    _ = dispatch(.{ .info_done = .{ .code = 0, .output = "Linux 6.8.0-45-generic x86_64 GNU\n" } });
    try std.testing.expect(g_model.phase == .ok);
    try std.testing.expectEqualStrings("Linux", core.osName(g_model));
    try std.testing.expectEqualStrings("6.8.0-45-generic", core.releaseName(g_model));
    try std.testing.expectEqualStrings("x86_64 GNU", core.machineName(g_model));
}

test "a non-zero exit is a failure carrying the code" {
    fresh();
    _ = dispatch(.refresh);
    _ = dispatch(.{ .info_done = .{ .code = 3, .output = "" } });
    try std.testing.expect(g_model.phase == .failed);
    try std.testing.expect(g_model.fail_code == 3);
}

test "a spawn failure is a failure, never silence" {
    fresh();
    _ = dispatch(.refresh);
    _ = dispatch(.{ .info_failed = "spawn_failed" });
    try std.testing.expect(g_model.phase == .failed);
}

test "a new refresh clears previous values and failures" {
    fresh();
    _ = dispatch(.refresh);
    _ = dispatch(.{ .info_done = .{ .code = 0, .output = "Darwin 24.6.0 arm64\n" } });
    _ = dispatch(.refresh);
    try std.testing.expect(g_model.phase == .probing);
    try std.testing.expect(core.osName(g_model).len == 0);
    try std.testing.expect(core.releaseName(g_model).len == 0);
    try std.testing.expect(core.machineName(g_model).len == 0);

    // Fail it, then refresh again: the failure clears too.
    _ = dispatch(.{ .info_done = .{ .code = 7, .output = "" } });
    try std.testing.expect(g_model.fail_code == 7);
    _ = dispatch(.refresh);
    try std.testing.expect(g_model.phase == .probing);
    try std.testing.expect(g_model.fail_code == 0);
}
