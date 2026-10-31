const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

fn typeDraft(model: *main.Model, text: []const u8) void {
    main.update(model, .{ .draft_edit = .clear });
    main.update(model, .{ .draft_edit = .{ .insert_text = text } });
}

test "seeds three tasks with two open" {
    var model = main.initialModel();
    try testing.expectEqual(@as(usize, 3), model.visibleTasks().len);
    try testing.expect(model.openCount() == 2);
}

test "adding takes the trimmed draft and rejects blanks" {
    var model = main.initialModel();
    typeDraft(&model, "  Ship v2  ");
    main.update(&model, .add);
    const tasks = model.visibleTasks();
    try testing.expectEqual(@as(usize, 4), tasks.len);
    try testing.expectEqualStrings("Ship v2", tasks[3].title());
    try testing.expectEqualStrings("", model.draftText());

    typeDraft(&model, "   ");
    main.update(&model, .add);
    try testing.expectEqual(@as(usize, 4), model.visibleTasks().len);
}

test "toggling and filtering keep the list and count consistent" {
    var model = main.initialModel();
    main.update(&model, .{ .toggle = 1 });
    try testing.expect(model.openCount() == 1);
    main.update(&model, .{ .set_filter = .open });
    try testing.expectEqual(@as(usize, 1), model.visibleTasks().len);
    try testing.expectEqualStrings("Update the docs", model.visibleTasks()[0].title());
    main.update(&model, .{ .set_filter = .done });
    try testing.expectEqual(@as(usize, 2), model.visibleTasks().len);
}

test "the view binds the list, chips, draft, and count" {
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
