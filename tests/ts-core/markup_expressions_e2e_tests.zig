const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const e = c.ui_markup.expr;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: usize = 0;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 102) calls += 1;
    return core.nativeWindowPolicy(input, output);
}
fn compare(source: []const u8, x: e.Value, y: e.Value, z: e.Value) !void {
    var tree: e.ExprTree = .{};
    var diagnostic: e.Diagnostic = .{};
    try std.testing.expect(e.parse(source, &tree, &diagnostic));
    var a: [e.max_expression_nodes]e.Value = @splat(.{ .boolean = false });
    for (tree.nodes[0..tree.len], 0..) |node, i| {
        if (node.kind == .binding) a[i] = if (std.mem.eql(u8, node.text, "x")) x else if (std.mem.eql(u8, node.text, "y")) y else z;
    }
    var b = a;
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    const expected = try e.eval(&tree, &a, aa.allocator());
    const before = calls;
    const actual = try e.evalWithPolicy(observed, &tree, &b, ab.allocator());
    try std.testing.expectEqual(before + 1, calls);
    try exact(expected, actual);
    // Includes slots committed before a failing node; later slots must stay
    // untouched. Compare float bits and complete strings, not display labels.
    try exact(a, b);
    for (a, b) |left, right| if (left == .float) {
        try std.testing.expectEqual(@as(u32, @bitCast(left.float)), @as(u32, @bitCast(right.float)));
    };
}
test "compiled markup expressions preserve all operators functions exact numbers and failure order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const values = [_]e.Value{
        .{ .integer = std.math.minInt(i64) },         .{ .integer = std.math.maxInt(i64) },
        .{ .integer = 9007199254740993 },             .{ .integer = 16777217 },
        .{ .integer = -1 },                           .{ .integer = 0 },
        .{ .integer = 1 },                            .{ .integer = 6 },
        .{ .integer = 7 },                            .{ .float = -0.0 },
        .{ .float = 0.0 },                            .{ .float = -1.5 },
        .{ .float = 1.25 },                           .{ .float = std.math.floatMax(f32) },
        .{ .float = std.math.inf(f32) },              .{ .float = std.math.nan(f32) },
        .{ .float = @bitCast(@as(u32, 0xffc01234)) }, .{ .string = " \tAbC\xc3\xa9\n " },
        .{ .string = "" },                            .{ .boolean = false },
        .{ .boolean = true },
    };
    const expressions = [_][]const u8{
        "x",               "1",         "1.25",                   "'literal'",             "true",                "-x",            "not x",                  "x + y",                  "x - y",       "x * y",        "x / y",      "x ++ y",
        "x == y",          "x != y",    "x < y",                  "x <= y",                "x > y",               "x >= y",        "x and y",                "x or y",                 "fixed(x, y)", "thousands(x)", "percent(x)", "percent(x, y)",
        "date(x)",         "time(x)",   "datetime(x)",            "upper(x)",              "lower(x)",            "trim(x)",       "min(x, y)",              "max(x, y)",              "abs(x)",      "round(x)",     "floor(x)",   "ceil(x)",
        "plural(x, y, z)", "pad(x, y)", "(x / y) ++ fixed(z, y)", "false and (x / y > 0)", "true or (x / y > 0)", "(x + y) ++ -z", "fixed(x, y) ++ (1 / 0)", "(1 / 0) ++ fixed(x, y)",
    };
    for (expressions) |source| for (values) |x| for (values) |y| {
        try compare(source, x, y, .{ .string = "plural" });
    };
}
test "compiled markup expressions preserve allocation failure and caller-owned binding bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var tree: e.ExprTree = .{};
    var diagnostic: e.Diagnostic = .{};
    try std.testing.expect(e.parse("upper(x) ++ fixed(12, 6)", &tree, &diagnostic));
    for (0..100) |budget| {
        var left: [100]u8 = undefined;
        var right: [100]u8 = undefined;
        var a = std.heap.FixedBufferAllocator.init(left[0..budget]);
        var b = std.heap.FixedBufferAllocator.init(right[0..budget]);
        var av: [e.max_expression_nodes]e.Value = @splat(.{ .boolean = false });
        av[0] = .{ .string = "synthetic binding" };
        var bv = av;
        const expected = e.eval(&tree, &av, a.allocator());
        const actual = e.evalWithPolicy(observed, &tree, &bv, b.allocator());
        if (expected) |value| try exact(value, try actual) else |err| try std.testing.expectError(err, actual);
        try exact(av, bv);
        try std.testing.expectEqual(a.end_index, b.end_index);
    }
}
const Model = struct { x: i64 = 16777217, y: f32 = 1.25, z: []const u8 = " hello " };
const Msg = union(enum) { tick: void };
const fixture_source = "<column gap=\"{round(y * 2)}\"><text>{fixed(y, 2)} / {thousands(x)} / {upper(trim(z))}</text><text>{x + 1} {x / 2} {pad(-42, 6)}</text><if test=\"{x > y and true}\"><text>Visible</text></if></column>";
const Compiled = c.CompiledMarkupView(Model, Msg, fixture_source);
test "compiled markup expressions reach both markup engines and retain complete widget trees" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Ui = c.Ui(Msg);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var reference_ui = Ui.init(alloc);
    const reference = try reference_ui.finalize(Compiled.build(&reference_ui, &.{}));
    var compiled_ui = Ui.init(alloc);
    compiled_ui.expression_policy = observed;
    const before = calls;
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &.{}));
    try std.testing.expect(calls > before);
    var interpreted_ui = Ui.init(alloc);
    interpreted_ui.expression_policy = observed;
    var interpreter = try c.MarkupView(Model, Msg).init(alloc, fixture_source);
    const previous = calls;
    const interpreted = try interpreted_ui.finalize(try interpreter.build(&interpreted_ui, &.{}));
    try std.testing.expect(calls > previous);
    try exact(reference.root, compiled.root);
    try exact(reference.root, interpreted.root);
}

test "compiled markup expressions accept the complete maximum node budget" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const expression = "-1" ++ " + 1" ** 31;
    var tree: e.ExprTree = .{};
    var diagnostic: e.Diagnostic = .{};
    try std.testing.expect(e.parse(expression, &tree, &diagnostic));
    try std.testing.expectEqual(e.max_expression_nodes, tree.len);
    try compare(expression, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 0 });
}
