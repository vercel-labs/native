//! Behavioral harness for ts-habits-core. The grader copies this next to the
//! transpiled core.zig and the rt kernel, then runs `zig test harness.zig`.
//! It drives the emitted core through the real dispatch cycle
//! (update -> commitModelRoot -> frameReset) and asserts the case
//! requirements from the prompt.

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

test "seeded model: three habits, none done today, empty draft, all filter" {
    const model = freshModel();
    try std.testing.expect(model.habits.len == 3);
    try std.testing.expect(core.doneCount(model) == 0);
    for (model.habits) |habit| try std.testing.expect(!habit.doneToday);
    try std.testing.expect(model.draft.len == 0);
    try std.testing.expect(model.filter == .all);
    try std.testing.expect(core.visibleHabits(model).len == 3);
}

test "toggle done increments the streak; toggling back decrements it" {
    var model = freshModel();
    const id = model.habits[0].id;
    const streak_before = model.habits[0].streak;

    model = dispatch(model, .{ .toggle_done = id });
    try std.testing.expect(model.habits[0].doneToday);
    try std.testing.expect(model.habits[0].streak == streak_before + 1);
    try std.testing.expect(core.doneCount(model) == 1);
    // Other habits untouched.
    try std.testing.expect(!model.habits[1].doneToday);
    try std.testing.expect(!model.habits[2].doneToday);

    model = dispatch(model, .{ .toggle_done = id });
    try std.testing.expect(!model.habits[0].doneToday);
    try std.testing.expect(model.habits[0].streak == streak_before);
    try std.testing.expect(core.doneCount(model) == 0);
}

test "add through the draft path trims spaces, initializes the habit, clears the draft" {
    var model = freshModel();
    model = dispatch(model, .{ .draft_edit = "  focus  " });
    model = dispatch(model, .add);
    try std.testing.expect(model.habits.len == 4);
    const added = model.habits[3];
    try std.testing.expect(std.mem.eql(u8, added.name, "focus"));
    try std.testing.expect(added.streak == 0);
    try std.testing.expect(!added.doneToday);
    try std.testing.expect(model.draft.len == 0);
    // Ids stay unique.
    for (model.habits[0..3]) |habit| try std.testing.expect(habit.id != added.id);
}

test "blank or all-spaces drafts add nothing" {
    var model = freshModel();
    model = dispatch(model, .add);
    try std.testing.expect(model.habits.len == 3);
    model = dispatch(model, .{ .draft_edit = "   " });
    model = dispatch(model, .add);
    try std.testing.expect(model.habits.len == 3);
}

test "filters partition the list and counts stay live" {
    var model = freshModel();
    const first = model.habits[0].id;
    const second = model.habits[1].id;
    model = dispatch(model, .{ .toggle_done = first });
    model = dispatch(model, .{ .toggle_done = second });
    try std.testing.expect(core.doneCount(model) == 2);

    model = dispatch(model, .{ .set_filter = .done });
    const done = core.visibleHabits(model);
    try std.testing.expect(done.len == 2);
    for (done) |habit| try std.testing.expect(habit.doneToday);

    model = dispatch(model, .{ .set_filter = .active });
    const active = core.visibleHabits(model);
    try std.testing.expect(active.len == 1);
    for (active) |habit| try std.testing.expect(!habit.doneToday);

    model = dispatch(model, .{ .set_filter = .all });
    try std.testing.expect(core.visibleHabits(model).len == 3);
}
