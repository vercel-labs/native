//! Behavioral harness for dual-list-delete-fix, ts track. The grader copies
//! this next to the transpiled core.zig and the rt kernel, then runs
//! `zig test harness.zig`. Asserts the shared behavioral spec: the visible
//! list is correct after EVERY change — delete under each filter included —
//! while the starter's add/toggle/filter behavior stays intact.

const std = @import("std");
const core = @import("core.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;

fn fresh() void {
    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();
}

fn dispatch(msg: core.Msg) void {
    g_model = core.commitModelRoot(core.update(g_model, msg));
    rt.frameReset();
}

fn typeDraft(text: []const u8) void {
    dispatch(.{ .draft_edit = .clear });
    dispatch(.{ .draft_edit = .{ .insert_text = text } });
}

fn visibleHas(id: i64) bool {
    for (core.visibleTasks(g_model)) |task| {
        if (task.id == id) return true;
    }
    return false;
}

test "seeds three tasks with two open" {
    fresh();
    try std.testing.expectEqual(@as(usize, 3), core.visibleTasks(g_model).len);
    try std.testing.expect(core.openCount(g_model) == 2);
}

test "the reported bug: a deleted task leaves the visible list immediately" {
    fresh();
    dispatch(.{ .delete = 1 });
    try std.testing.expectEqual(@as(usize, 2), core.visibleTasks(g_model).len);
    try std.testing.expect(!visibleHas(1));
    try std.testing.expect(core.openCount(g_model) == 1);
}

test "delete is correct under an active filter" {
    fresh();
    dispatch(.{ .set_filter = .open });
    try std.testing.expectEqual(@as(usize, 2), core.visibleTasks(g_model).len);
    dispatch(.{ .delete = 3 });
    try std.testing.expectEqual(@as(usize, 1), core.visibleTasks(g_model).len);
    try std.testing.expect(visibleHas(1));
    dispatch(.{ .set_filter = .all });
    try std.testing.expectEqual(@as(usize, 2), core.visibleTasks(g_model).len);
}

test "deleting an unknown id changes nothing" {
    fresh();
    dispatch(.{ .delete = 99 });
    try std.testing.expectEqual(@as(usize, 3), core.visibleTasks(g_model).len);
    try std.testing.expect(core.openCount(g_model) == 2);
}

test "mixed deletes, toggles, and filters stay consistent" {
    fresh();
    dispatch(.{ .delete = 2 });
    dispatch(.{ .toggle = 3 });
    dispatch(.{ .set_filter = .done });
    try std.testing.expectEqual(@as(usize, 1), core.visibleTasks(g_model).len);
    try std.testing.expect(visibleHas(3));
    try std.testing.expect(core.openCount(g_model) == 1);
}

test "adding after a delete still works: trimmed title, fresh id, blank rejected" {
    fresh();
    dispatch(.{ .delete = 2 });
    typeDraft("  Ship v2  ");
    dispatch(.add);
    const rows = core.visibleTasks(g_model);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("Ship v2", rows[2].title);
    try std.testing.expect(rows[2].id == 4);

    typeDraft("   ");
    dispatch(.add);
    try std.testing.expectEqual(@as(usize, 3), core.visibleTasks(g_model).len);
}
