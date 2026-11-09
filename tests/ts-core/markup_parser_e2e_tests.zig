const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const c = sdk.canvas;
const e = c.ui_markup.expr;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: usize = 0;
var conversions: usize = 0;
fn documentSame(expected: anytype, actual: @TypeOf(expected)) anyerror!void {
    const T = @TypeOf(expected);
    if (T == e.ExprTree) {
        try exact(expected.len, actual.len);
        try exact(expected.root, actual.root);
        try exact(expected.nodes[0..expected.len], actual.nodes[0..actual.len]);
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| try documentSame(@field(expected, field.name), @field(actual, field.name)),
        .optional => {
            try exact(expected != null, actual != null);
            if (expected) |value| try documentSame(value, actual.?);
        },
        .pointer => |info| if (info.size == .slice) {
            try exact(expected.len, actual.len);
            for (expected, actual) |a, b| try documentSame(a, b);
        } else if (info.size == .one) try documentSame(expected.*, actual.*) else try exact(expected, actual),
        .array => for (expected, actual) |a, b| try documentSame(a, b),
        .@"union" => switch (expected) {
            inline else => |value, tag| {
                try exact(std.meta.activeTag(expected), std.meta.activeTag(actual));
                try documentSame(value, @field(actual, @tagName(tag)));
            },
        },
        else => try exact(expected, actual),
    }
}
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 106) calls += 1;
    const count = core.nativeWindowPolicy(input, output);
    if (input[0] == 106 and output[2] == 2) conversions += 1;
    return count;
}
fn compare(source: []const u8) !void {
    // Start with non-default state: long inputs preserve it, other failures
    // preserve root and diagnostic success preserves its previous contents.
    var expected: e.ExprTree = .{ .len = 1, .root = 31 };
    expected.nodes[0] = .{ .kind = .literal_bool, .boolean = true };
    var actual = expected;
    var a: e.Diagnostic = .{ .offset = 197, .message = "previous" };
    var b = a;
    const accepted = e.parse(source, &expected, &a);
    try std.testing.expectEqual(accepted, e.parseWithPolicy(observed, source, &actual, &b));
    try exact(a, b);
    try std.testing.expectEqual(expected.len, actual.len);
    try std.testing.expectEqual(expected.root, actual.root);
    for (expected.nodes[0..expected.len], actual.nodes[0..actual.len]) |left, right| {
        try exact(left, right);
        try std.testing.expectEqual(@as(u32, @bitCast(left.float)), @as(u32, @bitCast(right.float)));
        if (left.kind == .binding or left.kind == .literal_string) {
            // Empty literals still borrow their precise source position.
            try std.testing.expectEqual(@intFromPtr(left.text.ptr), @intFromPtr(right.text.ptr));
        }
    }
}
test "compiled markup parser preserves complete grammar trees partial failures and source aliases" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const corpus = [_][]const u8{
        "",                    " ",                   "\t\r\n",                "true",             "false",                              "true.x",             "true()",                                          "false(1)",                            "_a.b2",                                     "a..b",                                           "a.",
        "1 + 2 * 3 - 4 / 5",   "1 ++ 2 + 3",          "not x == y and a or b", "notable",          "android",                            "a or.b",             "a == b",                                          "(a) == (b)",                          "a + b == c",                                "a == b == c",                                    "a != b < c",
        "a < b >= c",          "(1 + 2)",             "()",                    "(1",               "1)",                                 "(1 2)",              "-1",                                              "---1",                                "not not false",                             "not -1",                                         "'a\\b'",
        "''",                  "'\x00\xff\xc3'",      "'x",                    "a + '\x00'",       "\x00",                               "\xff",
        "é",
        "9223372036854775807", "9223372036854775808", "-9223372036854775808",  "9007199254740993", "0000000000000000000000000000000001", "1.0",                "0.000000000000000000000000000000000000000000001", "1.000000059604644775390625",          "340282346638528859811704183484516925440.0", "99999999999999999999999999999999999999999999.0", "1.",
        ".5",                  "1e3",                 "0x10",                  "1_0",              "- 1",                                "unknown(1)",         "x.y(1)",                                          "now()",                               "today()",                                   "nowhere()",                                      "max(1, 2)",
        "max(1 2)",            "max(1,)",             "max(1, 2",              "max()",            "max(1)",                             "max(1,2,3)",         "max(1,2,3,4,5)",                                  "max(9223372036854775808, unknown())", "max(unknown(), 9223372036854775808)",       "max(1,2,3,4,9223372036854775808)",               "fixed(0.25, 2)",
        "percent(0.5)",        "percent(0.5, 1)",     "plural(n, 'a', 'b')",   "datetime(0)",      "pad(1, 3)",                          "upper(trim(' a '))", "min(1, max(2, 3))",
    };
    for (corpus) |source| try compare(source);
    var buffer: [512]u8 = undefined;
    for (e.function_specs) |spec| {
        for ([_][]const u8{ "", "x", "x,y", "x,y,z", "x,y,z,w", "x,y,z,w,q" }) |args| {
            try compare(try std.fmt.bufPrint(&buffer, "{s}({s})", .{ spec.name, args }));
        }
    }
}
test "compiled markup parser preserves every byte node depth and argument boundary" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var buffer: [512]u8 = @splat(' ');
    buffer[0] = '1';
    for ([_]usize{ 255, 256, 257, 512 }) |len| try compare(buffer[0..len]);
    for (0..22) |depth| {
        @memset(&buffer, ' ');
        @memset(buffer[0..depth], '(');
        buffer[depth] = '1';
        @memset(buffer[depth + 1 .. depth * 2 + 1], ')');
        try compare(buffer[0 .. depth * 2 + 1]);
        @memset(buffer[0..depth], '-');
        try compare(buffer[0 .. depth + 1]);
    }
    for (1..38) |terms| {
        var at: usize = 0;
        for (0..terms) |i| {
            if (i > 0) {
                buffer[at] = '+';
                at += 1;
            }
            buffer[at] = '1';
            at += 1;
        }
        try compare(buffer[0..at]);
    }
    for (0..256) |byte| {
        buffer[0] = @intCast(byte);
        try compare(buffer[0..1]);
        buffer[0] = '\'';
        buffer[1] = @intCast(byte);
        buffer[2] = '\'';
        try compare(buffer[0..3]);
        buffer[0] = 'x';
        buffer[1] = @intCast(byte);
        buffer[2] = 'y';
        try compare(buffer[0..3]);
    }
}
test "compiled markup parser matches generated grammar and malformed byte corpus" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const terms = [_][]const u8{ "x", "item.field", "true", "false", "0", "1.5", "9007199254740993", "'\x00\xff'", "abs(-1)", "max(1, 2)", "trim(' x ')" };
    const operators = [_][]const u8{ "+", "-", "*", "/", "++", "==", "!=", "<", "<=", ">", ">=", "and", "or" };
    var buffer: [256]u8 = undefined;
    for (terms) |a| for (terms) |b| for (operators) |op| {
        try compare(try std.fmt.bufPrint(&buffer, "({s}) {s} ({s})", .{ a, op, b }));
    };
    const alphabet = "abc_xyz.0129'+-*/=<>!(), \t\r\n\x00\xff";
    var bits: u32 = 0x9364aef1;
    for (0..4096) |i| {
        const len = i % 257;
        for (buffer[0..len]) |*byte| {
            bits = bits *% 1664525 +% 1013904223;
            byte.* = alphabet[bits % alphabet.len];
        }
        try compare(buffer[0..len]);
    }
}
test "compiled markup parser canonicalizes runtime documents and owns uncached evaluation" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    const source = "<column><text>{max(1, 2) ++ ' items'}</text><if test=\"{x > 0}\"><text>yes</text></if></column>";
    var parser = c.ui_markup.Parser.init(aa.allocator(), source);
    const raw = try parser.parse();
    const reference = try c.ui_markup.canonicalize(aa.allocator(), raw);
    calls = 0;
    conversions = 0;
    const candidate = try c.ui_markup.canonicalizeWithPolicy(observed, ab.allocator(), raw);
    try std.testing.expect(calls > 0 and conversions == 3);
    try documentSame(reference, candidate);
    const Model = struct { x: i64 = 1 };
    const Msg = union(enum) { unused: void };
    const View = c.MarkupView(Model, Msg);
    const model: Model = .{};
    var reference_view = View.fromDocument(raw);
    var candidate_view = View.fromDocument(raw);
    var left = c.Ui(Msg).init(aa.allocator());
    var right = c.Ui(Msg).init(ab.allocator());
    right.expression_policy = observed;
    const before = calls;
    const left_root = try left.finalize(try reference_view.build(&left, &model));
    const right_root = try right.finalize(try candidate_view.build(&right, &model));
    try std.testing.expect(calls > before);
    try exact(left_root.root, right_root.root);
}
