const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("inbox_core");
const decoder = @import("inbox_decoder");
const reference = @import("inbox_reference.zig");
const canvas = sdk.canvas;

fn compare(native: *const reference.Model, model: *const core.Model) !void {
    try std.testing.expectEqual(native.task_count, model.tasks.len);
    try std.testing.expectEqual(@as(i64, native.next_id), model.next_id);
    try std.testing.expectEqualStrings(@tagName(native.filter), @tagName(model.filter));
    try std.testing.expectEqual(@as(f64, native.chrome_leading), model.chrome_leading);
    try std.testing.expectEqual(@as(f64, native.header_height), model.header_height);
    try std.testing.expectEqualStrings(native.draft(), model.draft_buffer.text);
    try std.testing.expectEqual(native.draft_buffer.truncated, model.draft_truncated);
    try std.testing.expectEqual(@as(i64, @intCast(native.draft_buffer.selection.anchor)), model.draft_buffer.selection.anchor);
    try std.testing.expectEqual(@as(i64, @intCast(native.draft_buffer.selection.focus)), model.draft_buffer.selection.focus);
    try std.testing.expectEqual(native.draft_buffer.composition != null, model.draft_buffer.composition != null);
    if (native.draft_buffer.composition) |range| {
        try std.testing.expectEqual(@as(i64, @intCast(range.start)), model.draft_buffer.composition.?.start);
        try std.testing.expectEqual(@as(i64, @intCast(range.end)), model.draft_buffer.composition.?.end);
    }
    for (native.tasks[0..native.task_count], model.tasks) |*a, b| {
        try std.testing.expectEqual(@as(i64, a.id), b.id);
        try std.testing.expectEqualStrings(a.title(), b.title);
        try std.testing.expectEqual(a.done, b.done);
    }
    try std.testing.expectEqual(native.draftEmpty(), model.draftEmpty());
    try std.testing.expectEqual(@as(i64, @intCast(native.openCount())), model.openCount());
    try std.testing.expectEqual(@as(i64, @intCast(native.doneCount())), model.doneCount());
}
fn step(native: *reference.Model, model: *const core.Model, a: reference.Msg, b: core.Msg) !*const core.Model {
    reference.update(native, a);
    const result = core.update(model, b);
    try compare(native, result);
    return result;
}
fn edit(native: *reference.Model, model: *const core.Model, a: canvas.TextInputEvent, b: core.TextInputEvent) !*const core.Model {
    return step(native, model, .{ .draft_edit = a }, .{ .draft_edit = b });
}
fn equal(expected: anytype, actual: @TypeOf(expected)) anyerror!void {
    const T = @TypeOf(expected);
    // Callback implementation addresses differ between compiled policies
    // and their native reference. Compare all widget data; the complete
    // driver snapshots and replay exercise the callback behavior.
    if (comptime @typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (comptime @typeInfo(Child) == .pointer and @typeInfo(@typeInfo(Child).pointer.child) == .@"fn") return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "compiled_scroll_policy")) continue;
            try equal(@field(expected, field.name), @field(actual, field.name));
        },
        .optional => {
            try std.testing.expectEqual(expected != null, actual != null);
            if (expected) |value| try equal(value, actual.?);
        },
        .pointer => |info| if (info.size == .slice) {
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |a, b| try equal(a, b);
        } else try std.testing.expectEqual(expected, actual),
        .array => for (expected, actual) |a, b| try equal(a, b),
        .@"union" => |info| if (info.tag_type != null) {
            try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
            switch (expected) {
                inline else => |value, tag| try equal(value, @field(actual, @tagName(tag))),
            }
        } else @compileError("untagged parity value"),
        else => try std.testing.expectEqual(expected, actual),
    }
}

fn viewParity(native: *const reference.Model, model: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var a = reference.InboxUi.init(arena.allocator());
    const expected = try a.finalize(reference.CompiledInboxView.build(&a, native));
    const Ui = canvas.Ui(core.Msg);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    for (0..2) |backend| {
        var b = Ui.init(arena.allocator());
        const root = if (backend == 0) View.build(&b, model) else decoder.build(&b, model);
        core.rt.frameReset();
        const actual = try b.finalize(root);
        try equal(expected.root, actual.root);
        try std.testing.expectEqual(expected.handlers.len, actual.handlers.len);
        for (expected.handlers, actual.handlers) |old, new| {
            try std.testing.expectEqual(old.id, new.id);
            const menu_len = if (old.action == .context_menu) old.action.context_menu.len else 0;
            try std.testing.expectEqual(menu_len, if (new.action == .context_menu) new.action.context_menu.len else 0);
            for (0..menu_len) |index| {
                const before = expected.msgForContextMenu(old.id, index);
                const after = actual.msgForContextMenu(new.id, index);
                try std.testing.expectEqual(before != null, after != null);
                if (before) |msg| {
                    try std.testing.expectEqualStrings(@tagName(msg), @tagName(after.?));
                    try std.testing.expectEqual(@as(i64, msg.toggle), after.?.toggle);
                }
            }
            const am = expected.msgForPointer(old.id, .up);
            const bm = actual.msgForPointer(new.id, .up);
            try std.testing.expectEqual(am != null, bm != null);
            if (am) |msg| {
                try std.testing.expectEqualStrings(@tagName(msg), @tagName(bm.?));
                switch (msg) {
                    .toggle => |id| try std.testing.expectEqual(@as(i64, id), bm.?.toggle),
                    .set_filter => |filter| try std.testing.expectEqualStrings(@tagName(filter), @tagName(bm.?.set_filter)),
                    else => {},
                }
            }
        }
        var left: [1024]canvas.WidgetLayoutNode = undefined;
        var right: [1024]canvas.WidgetLayoutNode = undefined;
        for ([_]sdk.geometry.RectF{ .init(0, 0, 520, 400), .init(0, 0, 720, 520), .init(0, 0, 960, 720) }) |frame| {
            try equal(try canvas.layoutWidgetTree(expected.root, frame, &left), try canvas.layoutWidgetTree(actual.root, frame, &right));
        }
    }
}
test "compiled Inbox retains complete editing state, UTF-8 capacity recovery, whitespace and keyed menus" {
    var native = reference.initModel();
    var model = core.initialModel();
    defer core.rt.frameReset();
    try compare(&native, model);
    try viewParity(&native, model);
    model = try edit(&native, model, .{ .insert_text = "  \t " }, .{ .insert_text = "  \t " });
    model = try step(&native, model, .add, .add);
    try std.testing.expectEqualStrings("Task 4", model.tasks[3].title);
    model = try edit(&native, model, .clear, .clear);
    model = try edit(&native, model, .{ .insert_text = "  Caf\xc3\xa9 task  " }, .{ .insert_text = "  Caf\xc3\xa9 task  " });
    model = try step(&native, model, .add, .add);
    try std.testing.expectEqualStrings("Caf\xc3\xa9 task", model.tasks[4].title);
    model = try edit(&native, model, .{ .insert_text = "ab" }, .{ .insert_text = "ab" });
    model = try edit(&native, model, .{ .set_selection = .{ .anchor = 1, .focus = 2 } }, .{ .set_selection = .{ .anchor = 1, .focus = 2 } });
    model = try edit(&native, model, .{ .set_composition = .{ .text = "\xe6\x97\xa5\xe6\x9c\xac", .cursor = 3 } }, .{ .set_composition = .{ .text = "\xe6\x97\xa5\xe6\x9c\xac", .cursor = 3 } });
    model = try edit(&native, model, .cancel_composition, .cancel_composition);
    model = try edit(&native, model, .{ .set_composition = .{ .text = "\xc3\xa9", .cursor = null } }, .{ .set_composition = .{ .text = "\xc3\xa9", .cursor = null } });
    model = try edit(&native, model, .commit_composition, .commit_composition);
    model = try edit(&native, model, .delete_backward, .delete_backward);
    model = try edit(&native, model, .clear, .clear);
    model = try edit(&native, model, .{ .insert_text = "abcdefghijklmnopqrstuvwxyz12345\xc3\xa9" }, .{ .insert_text = "abcdefghijklmnopqrstuvwxyz12345\xc3\xa9" });
    try std.testing.expectEqual(@as(usize, 31), model.draft_buffer.text.len);
    try std.testing.expect(model.draft_truncated);
    try viewParity(&native, model);
    model = try step(&native, model, .add, .add);
    for (0..70) |i| {
        model = try step(&native, model, .add, .add);
        const id: u32 = @intCast(i % 64 + 1);
        model = try step(&native, model, .{ .toggle = id }, .{ .toggle = id });
        model = try step(&native, model, .{ .set_filter = .active }, .{ .set_filter = .active });
        model = try step(&native, model, .{ .set_filter = .done }, .{ .set_filter = .done });
        model = try step(&native, model, .{ .set_filter = .all }, .{ .set_filter = .all });
        core.rt.frameReset();
    }
    try viewParity(&native, model);
    model = try edit(&native, model, .{ .insert_text = "cleared even at capacity" }, .{ .insert_text = "cleared even at capacity" });
    model = try step(&native, model, .add, .add);
    try std.testing.expectEqual(@as(usize, 64), model.tasks.len);
    try std.testing.expectEqualStrings("", model.draft_buffer.text);
    model = try step(&native, model, .clear_done, .clear_done);
    model = try step(&native, model, .{ .toggle = 999 }, .{ .toggle = 999 });
    for ([_]f32{ 0, 52, 72, 23.125 }) |top| {
        const chrome = sdk.WindowChrome{ .insets = .{ .left = 78.125, .top = top }, .buttons = .init(20, 19, 52, 14) };
        model = try step(&native, model, .{ .chrome_changed = chrome }, .{ .chrome_changed = .{ .insets = .{ .top = top, .left = 78.125, .right = 0, .bottom = 0 }, .buttons = .{ .x = 20, .y = 19, .width = 52, .height = 14 }, .tabsProjected = false } });
        try viewParity(&native, model);
    }
}
test {
    _ = @import("inbox_reference_tests.zig");
}

test "compiled Inbox menu decoder validates bounds and native arena ownership" {
    try decoder.testContextMenuRecords();
}
