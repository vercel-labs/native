const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_habits_core");
const reference = @import("habits_reference.zig");
const canvas = sdk.canvas;

fn compare(native: *const reference.Model, model: *const core.Model) !void {
    try std.testing.expectEqual(native.habit_count, model.habits.len);
    try std.testing.expectEqual(@as(i64, native.next_id), model.next_id);
    try std.testing.expectEqualStrings(@tagName(native.filter), @tagName(model.filter));
    try std.testing.expectEqual(@as(f64, native.chrome_leading), model.chrome_leading);
    try std.testing.expectEqual(@as(f64, native.header_height), model.header_height);
    for (native.habits[0..native.habit_count], model.habits) |*a, b| {
        try std.testing.expectEqual(@as(i64, a.id), b.id);
        try std.testing.expectEqualStrings(a.name(), b.name);
        try std.testing.expectEqual(@as(i64, a.streak), b.streak);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const summary = native.summaryLine(allocator);
    defer allocator.free(summary);
    try std.testing.expectEqualStrings(summary, model.summaryLine(allocator));
    const visible = native.visible(allocator);
    defer allocator.free(visible);
    const actual = model.visible(allocator);
    try std.testing.expectEqual(visible.len, actual.len);
    for (visible, actual) |*a, b| {
        try std.testing.expectEqual(@as(i64, a.id), b.id);
        try std.testing.expectEqualStrings(a.name(), b.name);
        try std.testing.expectEqual(@as(i64, a.streak), b.streak);
    }
}
fn step(native: *reference.Model, model: *const core.Model, a: reference.Msg, b: core.Msg) !*const core.Model {
    reference.update(native, a);
    const result = core.update(model, b);
    try compare(native, result);
    return result;
}
test "compiled Habits core matches every native owned record through capacity filtering chrome and repeated arena cycles" {
    var native = reference.initialModel();
    const initial = core.initialModel();
    var model = initial;
    defer core.rt.frameReset();
    try compare(&native, model);
    for (0..80) |i| {
        model = try step(&native, model, .add, .add);
        const id: u32 = @intCast(i % 65 + 1);
        model = try step(&native, model, .{ .done = id }, .{ .done = id });
        model = try step(&native, model, .{ .set_filter = .active }, .{ .set_filter = .active });
        model = try step(&native, model, .{ .set_filter = .all }, .{ .set_filter = .all });
        core.rt.frameReset();
    }
    for ([_]f32{ 0, 52, 72, 23.125 }) |top| {
        const chrome = sdk.WindowChrome{ .insets = .{ .left = 78, .top = top }, .buttons = .init(20, 19, 52, 14) };
        model = try step(&native, model, .{ .chrome_changed = chrome }, .{ .chrome_changed = .{ .insets = .{ .top = chrome.insets.top, .left = chrome.insets.left, .right = 0, .bottom = 0 }, .buttons = .{ .x = 20, .y = 19, .width = 52, .height = 14 }, .tabsProjected = false } });
    }
    model = try step(&native, model, .{ .done = 999 }, .{ .done = 999 });
    try std.testing.expectEqual(@as(usize, 64), model.habits.len);
}
test "compiled Habits policies preserve borrowed model names and complete view bytes" {
    const model = core.initialModel();
    defer core.rt.frameReset();
    const allocator = std.testing.allocator;
    const bytes = core.nativeView(allocator);
    defer allocator.free(bytes);
    const saved = try allocator.dupe(u8, bytes);
    defer allocator.free(saved);
    const name = model.habits[0].name;
    for (0..64) |_| {
        const request = [_]u8{ 0, '#', 'd', 'f', '2', '6', '7', '0' };
        var result: [4]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 4), core.nativeThemePolicy(&request, &result));
        try std.testing.expectEqualStrings("Meditate", name);
        try std.testing.expectEqualSlices(u8, saved, bytes);
        try std.testing.expectEqual(@as(usize, 3), model.habits.len);
    }
}
test {
    _ = @import("habits_reference_tests.zig");
}

fn equal(expected: anytype, actual: @TypeOf(expected)) anyerror!void {
    const T = @TypeOf(expected);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| try equal(@field(expected, field.name), @field(actual, field.name)),
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
    const allocator = arena.allocator();
    var a = reference.HabitsUi.init(allocator);
    const expected = try a.finalize(reference.CompiledHabitsView.build(&a, native));
    const Ui = canvas.Ui(core.Msg);
    const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));
    var b = Ui.init(allocator);
    const actual = try b.finalize(View.build(&b, model));
    try equal(expected.root, actual.root);
    try std.testing.expectEqual(expected.handlers.len, actual.handlers.len);
    for (expected.handlers, actual.handlers) |old, new| {
        try std.testing.expectEqual(old.id, new.id);
        const a_msg = expected.msgForPointer(old.id, .up);
        const b_msg = actual.msgForPointer(new.id, .up);
        try std.testing.expectEqual(a_msg != null, b_msg != null);
        if (a_msg) |msg| {
            try std.testing.expectEqualStrings(@tagName(msg), @tagName(b_msg.?));
            switch (msg) {
                .done => |id| try std.testing.expectEqual(@as(i64, id), b_msg.?.done),
                .set_filter => |filter| try std.testing.expectEqualStrings(@tagName(filter), @tagName(b_msg.?.set_filter)),
                else => {},
            }
        }
    }
    var left: [1024]canvas.WidgetLayoutNode = undefined;
    var right: [1024]canvas.WidgetLayoutNode = undefined;
    const l = try canvas.layoutWidgetTree(expected.root, .init(0, 0, 720, 520), &left);
    const v = try canvas.layoutWidgetTree(actual.root, .init(0, 0, 720, 520), &right);
    try equal(l, v);
}
test "ported Habits preserves every native widget field handler identity and complete layout" {
    var native = reference.initialModel();
    var model = core.initialModel();
    defer core.rt.frameReset();
    try viewParity(&native, model);
    for (0..8) |i| {
        model = try step(&native, model, .add, .add);
        try viewParity(&native, model);
        model = try step(&native, model, .{ .done = @intCast(i + 1) }, .{ .done = @intCast(i + 1) });
        model = try step(&native, model, .{ .set_filter = .active }, .{ .set_filter = .active });
        try viewParity(&native, model);
        model = try step(&native, model, .{ .set_filter = .all }, .{ .set_filter = .all });
        try viewParity(&native, model);
        core.rt.frameReset();
    }
}
