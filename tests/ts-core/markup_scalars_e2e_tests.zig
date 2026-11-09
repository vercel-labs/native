const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const e = c.ui_markup.expr;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var seen: [37]bool = @splat(false);
var blocks: usize = 0;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 105) {
        seen[input[2]] = true;
        if (input[5] == 2) blocks += 1;
    }
    return core.nativeWindowPolicy(input, output);
}
fn treeFor(source: []const u8) !e.ExprTree {
    var tree: e.ExprTree = .{};
    var diagnostic: e.Diagnostic = .{};
    try std.testing.expect(e.parse(source, &tree, &diagnostic));
    return tree;
}
fn bindings(tree: *const e.ExprTree, x: e.Value, y: e.Value) [e.max_expression_nodes]e.Value {
    var values: [e.max_expression_nodes]e.Value = @splat(.{ .boolean = false });
    for (tree.nodes[0..tree.len], 0..) |node, i| if (node.kind == .binding) {
        values[i] = if (std.mem.eql(u8, node.text, "x")) x else y;
    };
    return values;
}
fn sameValue(expected: e.Value, actual: e.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    if (expected == .float) {
        // NaN payloads and signs are part of the copied value too.
        try std.testing.expectEqual(@as(u32, @bitCast(expected.float)), @as(u32, @bitCast(actual.float)));
    } else try exact(expected, actual);
}
fn compare(tree: *const e.ExprTree, x: e.Value, y: e.Value) !void {
    var a = bindings(tree, x, y);
    var b = a;
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    const expected = try e.eval(tree, &a, aa.allocator());
    const actual = try e.evalWithPolicy(observed, tree, &b, ab.allocator());
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    if (expected == .value) try sameValue(expected.value, actual.value) else try exact(expected, actual);
    for (a, b) |left, right| try sameValue(left, right);
}
const unary = [_][]const u8{ "-x", "abs(x)", "round(x)", "floor(x)", "ceil(x)" };
const binary = [_][]const u8{ "x + y", "x - y", "x * y", "x / y", "x == y", "x != y", "x < y", "x <= y", "x > y", "x >= y", "min(x, y)", "max(x, y)" };
test "compiled markup scalars preserve exact i64 arithmetic overflow and complete intermediate slots" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const edges = [_]i64{ std.math.minInt(i64), std.math.minInt(i64) + 1, -9007199254740993, -4294967297, -65536, -1, 0, 1, 65535, 65536, 4294967295, 4294967296, 9007199254740993, std.math.maxInt(i64) - 1, std.math.maxInt(i64) };
    for (unary) |source| {
        const tree = try treeFor(source);
        for (edges) |a| try compare(&tree, .{ .integer = a }, .{ .integer = 0 });
    }
    for (binary) |source| {
        const tree = try treeFor(source);
        for (edges) |a| for (edges) |b| try compare(&tree, .{ .integer = a }, .{ .integer = b });
        var bits: u64 = 0x976a2d93b7c8e541;
        for (0..2048) |_| {
            bits = bits *% 6364136223846793005 +% 1442695040888963407;
            const a: i64 = @bitCast(bits);
            bits = bits *% 6364136223846793005 +% 1442695040888963407;
            const b: i64 = @bitCast(bits);
            try compare(&tree, .{ .integer = a }, .{ .integer = b });
            try compare(&tree, .{ .integer = @as(i32, @truncate(a)) }, .{ .integer = @as(i32, @truncate(b)) });
        }
    }
}
test "compiled markup scalars preserve f32 primitives NaNs signed zero and rounding boundaries" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const floats = [_]u32{ 0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x00800000, 0x3effffff, 0x3f000000, 0x3f000001, 0xbf000000, 0xbf000001, 0x3f7fffff, 0x3f800000, 0x3f800001, 0x4b800000, 0x5a000000, 0xda000000, 0x5a000001, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc54321, 0x7f812345 };
    for (unary) |source| {
        const tree = try treeFor(source);
        for (floats) |bits| try compare(&tree, .{ .float = @bitCast(bits) }, .{ .integer = 0 });
    }
    for (binary) |source| {
        const tree = try treeFor(source);
        for (floats) |a| for (floats) |b| try compare(&tree, .{ .float = @bitCast(a) }, .{ .float = @bitCast(b) });
        var bits: u32 = 0x9475ac31;
        for (0..1024) |_| {
            bits = bits *% 1664525 +% 1013904223;
            const a: f32 = @bitCast(bits);
            bits = bits *% 1664525 +% 1013904223;
            const b: f32 = @bitCast(bits);
            try compare(&tree, .{ .float = a }, .{ .float = b });
            try compare(&tree, .{ .integer = 9007199254740993 }, .{ .float = b });
            try compare(&tree, .{ .float = a }, .{ .integer = std.math.minInt(i64) });
        }
    }
}
test "compiled markup scalars preserve boolean logic arbitrary bytes and unbounded equality" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var a: [4097]u8 = undefined;
    for (&a, 0..) |*byte, i| byte.* = @truncate(i);
    var b = a;
    for ([_][]const u8{ "x == y", "x != y" }) |source| {
        const tree = try treeFor(source);
        for ([_]usize{ 0, 1, 255, 256, 257, 4096, 4097 }) |len| {
            try compare(&tree, .{ .string = a[0..len] }, .{ .string = b[0..len] });
            if (len > 0) {
                for ([_]usize{ 0, len / 2, len - 1 }) |position| {
                    b[position] ^= 255;
                    try compare(&tree, .{ .string = a[0..len] }, .{ .string = b[0..len] });
                    b[position] ^= 255;
                }
                try compare(&tree, .{ .string = a[0..len] }, .{ .string = b[0 .. len - 1] });
            }
        }
    }
    for ([_][]const u8{ "not x", "x and y", "x or y", "x == y", "x != y" }) |source| {
        const tree = try treeFor(source);
        for ([_]bool{ false, true }) |x| for ([_]bool{ false, true }) |y| try compare(&tree, .{ .boolean = x }, .{ .boolean = y });
    }
}
test "compiled markup scalars preserve eager failures type errors and all allocation prefixes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const values = [_]e.Value{ .{ .string = "\x00\xff" }, .{ .boolean = false }, .{ .integer = std.math.minInt(i64) }, .{ .float = std.math.nan(f32) } };
    for (unary ++ binary ++ [_][]const u8{ "not x", "x and y", "x or y", "false and (x / y > 0)", "true or (x / y > 0)", "(x + y) ++ (1 / 0)", "(1 / 0) ++ abs(x)" }) |source| {
        const tree = try treeFor(source);
        for (values) |x| for (values) |y| try compare(&tree, x, y);
    }
    const tree = try treeFor("'prefix ' ++ (x * y) ++ ' / ' ++ abs(x) ++ ' / ' ++ round(y)");
    for (0..256) |budget| {
        var left: [256]u8 = undefined;
        var right: [256]u8 = undefined;
        var aa = std.heap.FixedBufferAllocator.init(left[0..budget]);
        var ab = std.heap.FixedBufferAllocator.init(right[0..budget]);
        var a = bindings(&tree, .{ .integer = -12345 }, .{ .float = 0.125 });
        var b = a;
        const expected = e.eval(&tree, &a, aa.allocator());
        const actual = e.evalWithPolicy(observed, &tree, &b, ab.allocator());
        if (expected) |result| try exact(result, try actual) else |err| try std.testing.expectError(err, actual);
        try exact(a, b);
        try std.testing.expectEqual(aa.end_index, ab.end_index);
    }
}
test "compiled markup scalars own direct equality and truthiness without borrowing output" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const values = [_]e.Value{ .{ .string = "" }, .{ .string = "\x00\xff" }, .{ .integer = 0 }, .{ .integer = std.math.minInt(i64) }, .{ .integer = std.math.maxInt(i64) }, .{ .float = -0.0 }, .{ .float = std.math.nan(f32) }, .{ .float = std.math.inf(f32) }, .{ .float = 0.125 }, .{ .boolean = false }, .{ .boolean = true } };
    for (values) |a| {
        try std.testing.expectEqual(a.truthy(), e.truthyWithPolicy(observed, a));
        try std.testing.expectEqual(a.truthy(), e.truthyWithPolicy(null, a));
        for (values) |b| {
            try std.testing.expectEqual(e.Value.eql(a, b), e.equalWithPolicy(observed, a, b));
            try std.testing.expectEqual(e.Value.eql(a, b), e.equalWithPolicy(null, a, b));
        }
    }
}
const Model = struct { x: i64 = 9007199254740993, y: i64 = 1, f: f32 = -0.5, truth: bool = false, bytes: []const u8 = "\x00\xff" };
const Msg = union(enum) { tick: void, choose: bool };
const markup = "<column gap=\"8\"><text>{x + y} / {x - y} / {x * y} / {-x} / {abs(x)}</text><text>{x / y} / {min(x, y)} / {max(x, y)}</text><text>{round(f)} / {floor(f)} / {ceil(f)} / {abs(f)}</text><text>{x == y} / {x != y}</text><if test=\"{x < y}\"><text>Less</text></if><if test=\"{x <= y}\"><text>At most</text></if><if test=\"{x > y}\"><text>Greater</text></if><if test=\"{x >= y}\"><text>At least</text></if><text>{not truth} / {truth and true} / {truth or true} / {bytes == bytes}</text><if test=\"{bytes}\"><text>Text condition</text></if><if test=\"{f}\"><text>Float condition</text></if><if test=\"{x}\"><text>Integer condition</text></if><if test=\"{x == y}\"><text>Attribute equality</text></if><checkbox checked=\"{truth}\" disabled=\"{y}\" on-change=\"tick\">Flag</checkbox><text><span mono=\"{truth}\" italic=\"{y}\" underline=\"{bytes}\">Flags</span></text><button on-press=\"choose:{truth}\">Choose</button></column>";
const Compiled = c.CompiledMarkupView(Model, Msg, markup);
test "compiled markup scalars reach both engines with complete records and every capability" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    seen = @splat(false);
    blocks = 0;
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
    for ([_]Model{ .{}, .{ .x = std.math.maxInt(i64) - 1, .y = 1, .f = -0.0 }, .{ .x = 16777217, .y = 16777216, .f = 1.005, .truth = true }, .{ .x = 0, .y = 1, .f = -0.0, .bytes = "" } }) |model| {
        const a = try reference.finalize(Compiled.build(&reference, &model));
        const b = try compiled.finalize(Compiled.build(&compiled, &model));
        const d = try interpreted.finalize(try interpreter.build(&interpreted, &model));
        try exact(a.root, b.root);
        try exact(a.root, d.root);
    }
    for ([_]usize{ 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16, 27, 28, 29, 30, 31, 32, 36 }) |capability|
        try std.testing.expect(seen[capability]);
    try std.testing.expect(blocks > 0);
}
