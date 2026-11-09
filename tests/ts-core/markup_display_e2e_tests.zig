const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const e = c.ui_markup.expr;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var seen: [3][4]bool = @splat(@splat(false));
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 104) seen[input[2]][input[3] - 1] = true;
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
fn compare(tree: *const e.ExprTree, x: e.Value, y: e.Value) !void {
    var a = bindings(tree, x, y);
    var b = a;
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    try exact(try e.eval(tree, &a, aa.allocator()), try e.evalWithPolicy(observed, tree, &b, ab.allocator()));
    try exact(a, b);
}
test "compiled markup display preserves exact i64 fixed and percent conversion at every precision" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_][]const u8{ "fixed(x, y)", "percent(x, y)", "percent(x)", "x ++ ' / ' ++ fixed(x, y) ++ ' / ' ++ percent(x, y)" }) |source| {
        const tree = try treeFor(source);
        for ([_]i64{ std.math.minInt(i64), std.math.minInt(i64) + 1, -9007199254740993, -16777217, -1, 0, 1, 7, 16777217, 9007199254740993, std.math.maxInt(i64) }) |number| {
            for (0..7) |digits| try compare(&tree, .{ .integer = number }, .{ .integer = @intCast(digits) });
        }
    }
}
test "compiled markup display preserves f32 bits rounding signed zero and nonfinite failures" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const floats = [_]u32{ 0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x00800000, 0x3f000000, 0xbf000000, 0x3f7fffff, 0x3f800000, 0x3f800001, 0x41200000, 0x4b800001, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc54321 };
    for ([_][]const u8{ "x ++ ' / '", "fixed(x, y)", "percent(x, y)", "percent(x)" }) |source| {
        const tree = try treeFor(source);
        for (floats) |bits| for (0..7) |digits| try compare(&tree, .{ .float = @bitCast(bits) }, .{ .integer = @intCast(digits) });
        var bits: u32 = 0x9475ac31;
        for (0..2048) |_| {
            bits = bits *% 1664525 +% 1013904223;
            try compare(&tree, .{ .float = @bitCast(bits) }, .{ .integer = @intCast(bits % 7) });
        }
    }
}
test "compiled markup display retains complete eager failure prefixes and digits priority" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_][]const u8{ "fixed(x, y)", "percent(x, y)", "fixed(x, y) ++ (1 / 0)", "(1 / 0) ++ fixed(x, y)" }) |source| {
        const tree = try treeFor(source);
        for ([_]e.Value{ .{ .string = "no" }, .{ .boolean = true }, .{ .float = std.math.inf(f32) }, .{ .integer = 1 } }) |value| {
            for ([_]e.Value{ .{ .integer = -1 }, .{ .integer = 7 }, .{ .integer = std.math.minInt(i64) }, .{ .integer = 6 }, .{ .float = 1 }, .{ .string = "2" }, .{ .boolean = false } }) |digits|
                try compare(&tree, value, digits);
        }
    }
}
test "compiled markup display preserves interpolation bytes and every allocation boundary" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var bytes: [1027]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i);
    for ([_]e.Value{ .{ .string = bytes[0..0] }, .{ .string = &bytes }, .{ .integer = std.math.minInt(i64) }, .{ .float = -0.0 }, .{ .float = @bitCast(@as(u32, 0x7fc12345)) }, .{ .boolean = false }, .{ .boolean = true } }) |value| {
        for (0..1152) |budget| {
            var left: [1152]u8 = undefined;
            var right: [1152]u8 = undefined;
            var aa = std.heap.FixedBufferAllocator.init(left[0..budget]);
            var ab = std.heap.FixedBufferAllocator.init(right[0..budget]);
            var a: std.ArrayListUnmanaged(u8) = .empty;
            var b: std.ArrayListUnmanaged(u8) = .empty;
            const expected = e.appendValue(&a, aa.allocator(), value);
            const actual = e.appendValueWithPolicy(observed, &b, ab.allocator(), value);
            if (expected) |_| try actual else |err| try std.testing.expectError(err, actual);
            try std.testing.expectEqualSlices(u8, a.items, b.items);
            try std.testing.expectEqual(aa.end_index, ab.end_index);
        }
    }
    for ([_][]const u8{ "fixed(x, 0)", "fixed(x, 6)", "percent(x, 0)", "percent(x, 6)", "'prefix ' ++ fixed(x, 6) ++ true ++ percent(x, 6)" }) |source| {
        const tree = try treeFor(source);
        for ([_]e.Value{ .{ .integer = std.math.minInt(i64) }, .{ .float = 0.125 }, .{ .float = std.math.floatMax(f32) } }) |value| {
            for (0..256) |budget| {
                var left: [256]u8 = undefined;
                var right: [256]u8 = undefined;
                var aa = std.heap.FixedBufferAllocator.init(left[0..budget]);
                var ab = std.heap.FixedBufferAllocator.init(right[0..budget]);
                var a = bindings(&tree, value, .{ .integer = 0 });
                var b = a;
                const expected = e.eval(&tree, &a, aa.allocator());
                const actual = e.evalWithPolicy(observed, &tree, &b, ab.allocator());
                if (expected) |result| try exact(result, try actual) else |err| try std.testing.expectError(err, actual);
                try exact(a, b);
                try std.testing.expectEqual(aa.end_index, ab.end_index);
            }
        }
    }
}
const Model = struct { number: i64 = std.math.minInt(i64), fraction: f32 = -0.125, truth: bool = true, bytes: []const u8 = "Caf\xc3\xa9" };
const Msg = union(enum) { tick: void };
const markup = "<column gap=\"8\"><text>{number} / {fraction} / {truth} / {bytes}</text><text>{fixed(number, 6)} / {fixed(fraction, 3)} / {percent(fraction, 2)}</text><text>{number ++ ' ' ++ truth ++ fraction}</text><text><span weight=\"bold\">{fixed(number, 2)}</span> <span>{percent(fraction)}</span></text></column>";
const Compiled = c.CompiledMarkupView(Model, Msg, markup);
test "compiled markup display reaches both engines and span interpolation with complete records" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    seen = @splat(@splat(false));
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
    for ([_]Model{ .{}, .{ .number = std.math.maxInt(i64), .fraction = -0.0, .truth = false }, .{ .number = 9007199254740993, .fraction = 1.005 } }) |model| {
        const a = try reference.finalize(Compiled.build(&reference, &model));
        const b = try compiled.finalize(Compiled.build(&compiled, &model));
        const d = try interpreted.finalize(try interpreter.build(&interpreted, &model));
        try exact(a.root, b.root);
        try exact(a.root, d.root);
    }
    for (seen[0]) |owned| try std.testing.expect(owned);
    try std.testing.expect(seen[1][1] and seen[1][2] and seen[2][2]);
}
