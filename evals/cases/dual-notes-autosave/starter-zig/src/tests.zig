const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

fn edit(model: *main.Model, event: canvas.TextInputEvent) void {
    main.update(model, .{ .edit = event });
}

test "selection switches the editor to that note's body" {
    var model = main.initialModel();
    try testing.expectEqualStrings("milk, eggs", model.editorText());
    main.update(&model, .{ .select = 2 });
    try testing.expectEqualStrings("Ideas", model.selectedTitle());
    try testing.expectEqualStrings("native first", model.editorText());
    // Unknown ids change nothing.
    main.update(&model, .{ .select = 99 });
    try testing.expectEqualStrings("native first", model.editorText());
}

test "edits splice the selected note's body and leave the others alone" {
    var model = main.initialModel();
    edit(&model, .clear);
    edit(&model, .{ .insert_text = "call mom" });
    try testing.expectEqualStrings("call mom", model.editorText());
    main.update(&model, .{ .select = 3 });
    try testing.expectEqualStrings("demo the panel", model.editorText());
    main.update(&model, .{ .select = 1 });
    try testing.expectEqualStrings("call mom", model.editorText());
}

test "the view binds the notes and editor" {
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
