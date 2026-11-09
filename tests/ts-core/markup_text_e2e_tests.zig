const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const e = c.ui_markup.expr;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var seen: [9]bool = @splat(false);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 103) seen[input[2]] = true;
    return core.nativeWindowPolicy(input, output);
}
fn treeFor(source: []const u8) !e.ExprTree {
    var tree: e.ExprTree = .{};
    var diagnostic: e.Diagnostic = .{};
    try std.testing.expect(e.parse(source, &tree, &diagnostic));
    return tree;
}
fn bindings(tree: *const e.ExprTree, x: e.Value, y: e.Value, z: e.Value) [e.max_expression_nodes]e.Value {
    var values: [e.max_expression_nodes]e.Value = @splat(.{ .boolean = false });
    for (tree.nodes[0..tree.len], 0..) |node, i| if (node.kind == .binding) {
        values[i] = if (std.mem.eql(u8, node.text, "x")) x else if (std.mem.eql(u8, node.text, "y")) y else z;
    };
    return values;
}
fn compare(tree: *const e.ExprTree, x: e.Value, y: e.Value, z: e.Value) !void {
    var a = bindings(tree, x, y, z);
    var b = a;
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    try exact(try e.eval(tree, &a, aa.allocator()), try e.evalWithPolicy(observed, tree, &b, ab.allocator()));
    try exact(a, b);
}
test "compiled markup text owns all nine functions with exact integer words and arbitrary bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    seen = @splat(false);
    const numbers = [_]i64{ std.math.minInt(i64), std.math.maxInt(i64), -62135596801, -62135596800, -86401, -86400, -1, 0, 1, 2, 999, 1000, 16777217, 9007199254740993, 253402300799, 253402300800 };
    for ([_][]const u8{ "thousands(x)", "date(x)", "time(x)", "datetime(x)", "plural(x, y, z)", "pad(x, 0)", "pad(x, 1)", "pad(x, 2)", "pad(x, 3)", "pad(x, 4)", "pad(x, 5)", "pad(x, 6)" }) |source| {
        const tree = try treeFor(source);
        for (numbers) |number| try compare(&tree, .{ .integer = number }, .{ .string = "one\x00\xff" }, .{ .string = "many\xc0\xaf" });
    }
    var bytes: [2051]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i);
    for ([_][]const u8{ "upper(x)", "lower(x)", "trim(x)", "upper(trim(x)) ++ lower(x)" }) |source| {
        const tree = try treeFor(source);
        for ([_]usize{ 0, 1, 255, 256, 257, 511, 512, 513, bytes.len }) |length|
            try compare(&tree, .{ .string = bytes[0..length] }, .{ .integer = 0 }, .{ .integer = 0 });
        @memset(&bytes, ' ');
        try compare(&tree, .{ .string = &bytes }, .{ .integer = 0 }, .{ .integer = 0 });
        bytes[1025] = 'A';
        try compare(&tree, .{ .string = &bytes }, .{ .integer = 0 }, .{ .integer = 0 });
        for (&bytes, 0..) |*byte, i| byte.* = @truncate(i);
    }
    for (seen) |owned| try std.testing.expect(owned);
}
test "compiled markup text preserves an entire Gregorian era and both timestamp range edges" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const tree = try treeFor("date(x)");
    // One complete 400-year era contains every leap/century/month shape.
    for (0..146097) |day| try compare(&tree, .{ .integer = (11017 + @as(i64, @intCast(day))) * 86400 }, .{ .integer = 0 }, .{ .integer = 0 });
    for ([_][]const u8{ "date(x)", "time(x)", "datetime(x)" }) |source| {
        const boundary_tree = try treeFor(source);
        for ([_]i64{ -62135596800, 253402300799, -1, 0 }) |second| {
            for ([_]i64{ -86400, -60, -1, 0, 1, 60, 86400 }) |delta|
                try compare(&boundary_tree, .{ .integer = second + delta }, .{ .integer = 0 }, .{ .integer = 0 });
        }
    }
}
test "compiled markup text retains borrowed trim and plural pointers across later policy calls" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var bytes: [1027]u8 = @splat(' ');
    bytes[513] = 'x';
    const tree = try treeFor("trim(x)");
    var values = bindings(&tree, .{ .string = &bytes }, .{ .integer = 0 }, .{ .integer = 0 });
    const result = try e.evalWithPolicy(observed, &tree, &values, std.testing.failing_allocator);
    try std.testing.expect(result.value.string.ptr == bytes[513..].ptr);
    try std.testing.expectEqualStrings("x", result.value.string);
    @memset(&bytes, ' ');
    values = bindings(&tree, .{ .string = &bytes }, .{ .integer = 0 }, .{ .integer = 0 });
    const empty = try e.evalWithPolicy(observed, &tree, &values, std.testing.failing_allocator);
    try std.testing.expect(empty.value.string.ptr == bytes[bytes.len..].ptr);
    const plural_tree = try treeFor("plural(x, y, z)");
    for ([_]i64{ 1, -1, 4294967297, std.math.minInt(i64), std.math.maxInt(i64) }) |count| {
        const singular: []const u8 = "one\x00\xff";
        const many: []const u8 = "many\xc0\xaf";
        var pv = bindings(&plural_tree, .{ .integer = count }, .{ .string = singular }, .{ .string = many });
        const picked = try e.evalWithPolicy(observed, &plural_tree, &pv, std.testing.failing_allocator);
        try std.testing.expect(picked.value.string.ptr == (if (count == 1) singular.ptr else many.ptr));
        try compare(&tree, .{ .string = " \tother\r\n" }, .{ .integer = 0 }, .{ .integer = 0 });
        try std.testing.expectEqualStrings(if (count == 1) singular else many, picked.value.string);
    }
}
test "compiled markup text retains every allocation boundary and complete failure prefix" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_][]const u8{ "upper(x)", "lower(x)", "thousands(-9223372036854775807)", "pad(-7, 6)", "datetime(0)", "upper(trim(x)) ++ pad(-7, 6) ++ date(0)" }) |source| {
        const tree = try treeFor(source);
        for (0..512) |budget| {
            var left: [512]u8 = undefined;
            var right: [512]u8 = undefined;
            var a = std.heap.FixedBufferAllocator.init(left[0..budget]);
            var b = std.heap.FixedBufferAllocator.init(right[0..budget]);
            var av = bindings(&tree, .{ .string = " \tAbC\x00\xff\xc0\xaf\r\n " }, .{ .integer = 0 }, .{ .integer = 0 });
            var bv = av;
            const expected = e.eval(&tree, &av, a.allocator());
            const actual = e.evalWithPolicy(observed, &tree, &bv, b.allocator());
            if (expected) |value| try exact(value, try actual) else |err| try std.testing.expectError(err, actual);
            try exact(av, bv);
            try std.testing.expectEqual(a.end_index, b.end_index);
        }
    }
}
const Model = struct { count: i64 = 1, timestamp: i64 = -1, bytes: []const u8 = " \tMarkup \xc3\xa9 " };
const Msg = union(enum) { tick: void };
const markup = "<column gap=\"8\"><text>{thousands(count)} {pad(count, 6)} {plural(count, 'one', 'many')}</text><text>{upper(bytes)} / {lower(bytes)} / {trim(bytes)}</text><text>{date(timestamp)} {time(timestamp)} {datetime(timestamp)}</text></column>";
const Compiled = c.CompiledMarkupView(Model, Msg, markup);
test "compiled markup text reaches both markup engines with complete widget records" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Ui = c.Ui(Msg);
    var reference = Ui.init(alloc);
    var compiled = Ui.init(alloc);
    compiled.expression_policy = observed;
    var interpreted = Ui.init(alloc);
    interpreted.expression_policy = observed;
    var interpreter = try c.MarkupView(Model, Msg).init(alloc, markup);
    const a = try reference.finalize(Compiled.build(&reference, &.{}));
    const b = try compiled.finalize(Compiled.build(&compiled, &.{}));
    const d = try interpreted.finalize(try interpreter.build(&interpreted, &.{}));
    try exact(a.root, b.root);
    try exact(a.root, d.root);
}
