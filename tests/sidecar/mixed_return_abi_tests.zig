//! Regression over a REAL compiled core for the generated facade's mixed
//! update return normalization. The first dispatch returns a bare Model; the
//! second returns [Model, Cmd]. Both commit through model_snapshot, exactly the
//! host ordering that exposed tuple misclassification in scriptc 0.0.30.

const std = @import("std");
const core = @import("mixed_return_core");

test "mixed bare-model and effect-tuple returns commit through the ABI" {
    core.rt.resetAll();
    var model = core.commitModelRoot(core.initialModel());
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
