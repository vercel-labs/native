//! Regression over a REAL compiled core for boot command encoding and mixed
//! update return normalization. A boot fetch encodes while the facade module
//! initializes; later dispatches return a bare Model and [Model, Cmd].

const std = @import("std");
const core = @import("mixed_return_core");

test "a boot fetch encodes after its lookup tables initialize" {
    core.rt.resetAll();
    const initial = core.initialModel();
    try std.testing.expectEqual(@as(i64, 0), initial.model.n);

    const cmd = initial.cmd;
    try std.testing.expectEqualSlices(u8, &.{ 0x09, 0, 4, 3, 0 }, cmd[0..5]); // fetch, empty key, fetched/failed tags, GET
    try std.testing.expectEqual(@as(u32, 500), std.mem.readInt(u32, cmd[5..9], .little));
    var at: usize = 9;
    const url_len: usize = @intCast(std.mem.readInt(u32, cmd[at..][0..4], .little));
    at += 4;
    try std.testing.expectEqualStrings("https://example.test/boot", cmd[at..][0..url_len]);
    at += url_len;
    try std.testing.expectEqual(@as(u8, 1), cmd[at]); // one header
    at += 1;
    const name_len: usize = cmd[at];
    at += 1;
    try std.testing.expectEqualStrings("accept", cmd[at..][0..name_len]);
    at += name_len;
    const value_len: usize = @intCast(std.mem.readInt(u32, cmd[at..][0..4], .little));
    at += 4;
    try std.testing.expectEqualStrings("text/plain", cmd[at..][0..value_len]);
    at += value_len;
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, cmd[at..][0..4], .little)); // empty body
    at += 4;
    try std.testing.expectEqual(cmd.len, at);
}

test "mixed bare-model and effect-tuple returns commit through the ABI" {
    core.rt.resetAll();
    var model = core.commitModelRoot(core.initialModel().model);
    try std.testing.expectEqual(@as(i64, 0), model.n);
    core.rt.frameReset();

    const bare = core.update(model, .{ .tick = -1 });
    try std.testing.expectEqualSlices(u8, "", bare.cmd);
    model = core.commitModelRoot(bare.model);
    try std.testing.expectEqual(@as(i64, 0), model.n);
    core.rt.frameReset();

    const effect = core.update(model, .{ .tick = 1000 });
    try std.testing.expect(effect.cmd.len > 0);
    model = core.commitModelRoot(effect.model);
    try std.testing.expectEqual(@as(i64, 0), model.n);
    core.rt.frameReset();
}
