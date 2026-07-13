const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

test "seeds four expenses and totals them" {
    var model = main.initialModel();
    try testing.expect(model.expenseCount() == 4);
    try testing.expect(model.totalCents() == 55450);
}

test "removal drops exactly the named row; reset restores the seeds" {
    var model = main.initialModel();
    main.update(&model, .{ .remove = 3 });
    try testing.expect(model.expenseCount() == 3);
    try testing.expect(model.totalCents() == 49050);
    main.update(&model, .{ .remove = 99 });
    try testing.expect(model.expenseCount() == 3);
    main.update(&model, .reset);
    try testing.expect(model.expenseCount() == 4);
    try testing.expect(model.totalCents() == 55450);
}

test "the view binds the table and totals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    var view = try canvas.MarkupView(main.Model, main.Msg).init(arena, main.app_markup);
    var ui = main.AppUi.init(arena);
    const node = view.build(&ui, &model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    const tree = try ui.finalize(node);
    try testing.expect(tree.root.children.len > 0);
}
