//! Behavioral harness for ts-countdown-bugfix. The grader copies this next to
//! the transpiled core.zig and the rt kernel, then runs `zig test harness.zig`.
//! Asserts the intended countdown behavior from the prompt — each test
//! isolates one of the planted drifts.

const std = @import("std");
const core = @import("core.zig");
const rt = core.rt;

fn freshModel() *const core.Model {
    rt.resetAll();
    const committed = core.commitModelRoot(core.initialModel());
    rt.frameReset();
    return committed;
}

fn dispatch(model: *const core.Model, msg: core.Msg) *const core.Model {
    const next = core.update(model, msg);
    const committed = core.commitModelRoot(next);
    rt.frameReset();
    return committed;
}

test "ticks only count down while running" {
    var model = freshModel();
    const initial = model.remainingSeconds;
    model = dispatch(model, .tick);
    try std.testing.expect(model.remainingSeconds == initial);

    model = dispatch(model, .start);
    try std.testing.expect(model.running);
    model = dispatch(model, .tick);
    try std.testing.expect(model.remainingSeconds == initial - 1);

    model = dispatch(model, .pause);
    try std.testing.expect(!model.running);
    model = dispatch(model, .tick);
    try std.testing.expect(model.remainingSeconds == initial - 1);
}

test "completion fires exactly once, stops the timer, floors at zero" {
    var model = freshModel();
    model = dispatch(model, .{ .set_duration = 2 });
    model = dispatch(model, .start);
    model = dispatch(model, .tick);
    try std.testing.expect(model.remainingSeconds == 1);
    try std.testing.expect(model.completedCount == 0);
    model = dispatch(model, .tick);
    try std.testing.expect(model.remainingSeconds == 0);
    try std.testing.expect(model.completedCount == 1);
    try std.testing.expect(!model.running);
    // Finished sessions do not keep counting or re-completing.
    model = dispatch(model, .tick);
    model = dispatch(model, .tick);
    try std.testing.expect(model.remainingSeconds == 0);
    try std.testing.expect(model.completedCount == 1);
    // start alone does not restart a finished session.
    model = dispatch(model, .start);
    try std.testing.expect(!model.running);
}

test "reset restores the configured duration and keeps the completed count" {
    var model = freshModel();
    model = dispatch(model, .{ .set_duration = 90 });
    model = dispatch(model, .start);
    model = dispatch(model, .tick);
    model = dispatch(model, .tick);
    try std.testing.expect(model.remainingSeconds == 88);
    model = dispatch(model, .reset);
    try std.testing.expect(model.remainingSeconds == 90);
    try std.testing.expect(!model.running);

    // Run a 1-second session to completion, then reset: count survives.
    model = dispatch(model, .{ .set_duration = 1 });
    model = dispatch(model, .start);
    model = dispatch(model, .tick);
    try std.testing.expect(model.completedCount == 1);
    model = dispatch(model, .reset);
    try std.testing.expect(model.completedCount == 1);
    try std.testing.expect(model.remainingSeconds == 1);
}

test "set_duration is guarded: ignored while running and for non-positive values" {
    var model = freshModel();
    model = dispatch(model, .{ .set_duration = 60 });
    try std.testing.expect(model.durationSeconds == 60);
    try std.testing.expect(model.remainingSeconds == 60);

    model = dispatch(model, .start);
    model = dispatch(model, .{ .set_duration = 10 });
    try std.testing.expect(model.durationSeconds == 60);
    try std.testing.expect(model.remainingSeconds == 60);

    model = dispatch(model, .pause);
    model = dispatch(model, .{ .set_duration = 0 });
    try std.testing.expect(model.durationSeconds == 60);
    model = dispatch(model, .{ .set_duration = -5 });
    try std.testing.expect(model.durationSeconds == 60);
}
