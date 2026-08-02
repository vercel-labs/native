//! Behavioral harness for ts-expenses-filter. The grader copies this next to
//! the transpiled core.zig and the rt kernel, then runs `zig test harness.zig`.
//! Asserts the pre-existing ledger behavior stayed intact and the new
//! exclusive category filter with derived views works as specified.

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

fn seeded() *const core.Model {
    var model = freshModel();
    model = dispatch(model, .{ .add_expense = .{ .label = "coffee", .amountCents = 450, .category = .food } });
    model = dispatch(model, .{ .add_expense = .{ .label = "train", .amountCents = 1200, .category = .travel } });
    model = dispatch(model, .{ .add_expense = .{ .label = "lunch", .amountCents = 900, .category = .food } });
    model = dispatch(model, .{ .add_expense = .{ .label = "rope", .amountCents = 3000, .category = .gear } });
    return model;
}

test "existing behavior intact: add, count, total, remove" {
    var model = seeded();
    try std.testing.expect(core.expenseCount(model) == 4);
    try std.testing.expect(core.totalCents(model) == 5550);
    const second = model.expenses[1].id;
    model = dispatch(model, .{ .remove_expense = second });
    try std.testing.expect(core.expenseCount(model) == 3);
    try std.testing.expect(core.totalCents(model) == 4350);
}

test "filter starts cleared and shows everything" {
    const model = seeded();
    try std.testing.expect(model.filter == null);
    try std.testing.expect(core.visibleExpenses(model).len == 4);
    try std.testing.expect(core.visibleTotalCents(model) == 5550);
}

test "setting a category filters the visible list and total, exclusively" {
    var model = seeded();
    model = dispatch(model, .{ .set_filter = .food });
    const food = core.visibleExpenses(model);
    try std.testing.expect(food.len == 2);
    for (food) |expense| try std.testing.expect(expense.category == .food);
    try std.testing.expect(core.visibleTotalCents(model) == 1350);
    // The unfiltered helpers are untouched by the filter.
    try std.testing.expect(core.expenseCount(model) == 4);
    try std.testing.expect(core.totalCents(model) == 5550);

    model = dispatch(model, .{ .set_filter = .gear });
    try std.testing.expect(core.visibleExpenses(model).len == 1);
    try std.testing.expect(core.visibleTotalCents(model) == 3000);

    model = dispatch(model, .{ .set_filter = null });
    try std.testing.expect(core.visibleExpenses(model).len == 4);
}

test "removal works the same under an active filter" {
    var model = seeded();
    model = dispatch(model, .{ .set_filter = .food });
    const visible = core.visibleExpenses(model);
    const target = visible[0].id;
    const remaining = core.visibleTotalCents(model) - visible[0].amountCents;
    model = dispatch(model, .{ .remove_expense = target });
    try std.testing.expect(core.expenseCount(model) == 3);
    try std.testing.expect(core.visibleExpenses(model).len == 1);
    try std.testing.expect(core.visibleTotalCents(model) == remaining);
}
