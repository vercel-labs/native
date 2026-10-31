//! Behavioral harness for dual-list-delete-fix, zig track. Injected by the
//! grader as src/eval_behavior_spec.zig and run through `native test`.
//! Asserts the same behavioral spec the ts track's harness asserts. The
//! visibleTasks accessor is read through a comptime arity switch so both
//! legitimate fixes compile: repairing the cache keeps the plain slice
//! method, deriving at view time takes the arena form.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const testing = std.testing;

var arena_state: std.heap.ArenaAllocator = undefined;

fn freshModel() main.Model {
    arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    return main.initialModel();
}

fn visible(model: *const main.Model) []const main.Task {
    const params = @typeInfo(@TypeOf(main.Model.visibleTasks)).@"fn".params;
    if (params.len == 2) return model.visibleTasks(arena_state.allocator());
    return model.visibleTasks();
}

fn visibleHas(model: *const main.Model, id: i64) bool {
    for (visible(model)) |*task| {
        if (task.id == id) return true;
    }
    return false;
}

fn typeDraft(model: *main.Model, text: []const u8) void {
    main.update(model, .{ .draft_edit = .clear });
    main.update(model, .{ .draft_edit = .{ .insert_text = text } });
}

test "seeds three tasks with two open" {
    var model = freshModel();
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 3), visible(&model).len);
    try testing.expect(model.openCount() == 2);
}

test "the reported bug: a deleted task leaves the visible list immediately" {
    var model = freshModel();
    defer arena_state.deinit();
    main.update(&model, .{ .delete = 1 });
    try testing.expectEqual(@as(usize, 2), visible(&model).len);
    try testing.expect(!visibleHas(&model, 1));
    try testing.expect(model.openCount() == 1);
}

test "delete is correct under an active filter" {
    var model = freshModel();
    defer arena_state.deinit();
    main.update(&model, .{ .set_filter = .open });
    try testing.expectEqual(@as(usize, 2), visible(&model).len);
    main.update(&model, .{ .delete = 3 });
    try testing.expectEqual(@as(usize, 1), visible(&model).len);
    try testing.expect(visibleHas(&model, 1));
    main.update(&model, .{ .set_filter = .all });
    try testing.expectEqual(@as(usize, 2), visible(&model).len);
}

test "deleting an unknown id changes nothing" {
    var model = freshModel();
    defer arena_state.deinit();
    main.update(&model, .{ .delete = 99 });
    try testing.expectEqual(@as(usize, 3), visible(&model).len);
    try testing.expect(model.openCount() == 2);
}

test "mixed deletes, toggles, and filters stay consistent" {
    var model = freshModel();
    defer arena_state.deinit();
    main.update(&model, .{ .delete = 2 });
    main.update(&model, .{ .toggle = 3 });
    main.update(&model, .{ .set_filter = .done });
    try testing.expectEqual(@as(usize, 1), visible(&model).len);
    try testing.expect(visibleHas(&model, 3));
    try testing.expect(model.openCount() == 1);
}

test "adding after a delete still works: trimmed title, fresh id, blank rejected" {
    var model = freshModel();
    defer arena_state.deinit();
    main.update(&model, .{ .delete = 2 });
    typeDraft(&model, "  Ship v2  ");
    main.update(&model, .add);
    const rows = visible(&model);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("Ship v2", rows[2].title());
    try testing.expect(rows[2].id == 4);

    typeDraft(&model, "   ");
    main.update(&model, .add);
    try testing.expectEqual(@as(usize, 3), visible(&model).len);
}
