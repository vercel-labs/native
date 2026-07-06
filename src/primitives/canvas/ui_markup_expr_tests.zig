//! Tests for the markup expression layer: grammar and evaluator units,
//! the closed function library, complexity bounds taught one past, hostile
//! inputs (deep nesting, huge literals, division by zero, unicode in
//! string ops), a seed-pinned parser fuzz (matching the hostile-corpus
//! shape of markdown_hostile_tests.zig), and engine parity — the runtime
//! interpreter and the comptime-compiled engine must produce identical
//! trees, texts, and dispatch for the same expressions, floats included.

const std = @import("std");
const canvas = @import("root.zig");
const markup = @import("ui_markup.zig");
const expr = @import("ui_markup_expr.zig");
const markup_view = @import("ui_markup_view.zig");

const testing = std.testing;
const Value = expr.Value;

// --------------------------------------------------------- eval harness

/// Parse and evaluate a binding-free expression.
fn evalSource(arena: std.mem.Allocator, source: []const u8) !expr.EvalOutcome {
    var tree: expr.ExprTree = .{};
    var diagnostic: expr.Diagnostic = .{};
    if (!expr.parse(source, &tree, &diagnostic)) {
        std.debug.print("parse failed for \"{s}\": {s}\n", .{ source, diagnostic.message });
        return error.TestUnexpectedResult;
    }
    var values: [expr.max_expression_nodes]Value = undefined;
    return expr.eval(&tree, &values, arena);
}

fn expectValue(source: []const u8, expected: Value) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try evalSource(arena_state.allocator(), source);
    switch (outcome) {
        .value => |value| {
            if (!Value.eql(value, expected) or std.meta.activeTag(value) != std.meta.activeTag(expected)) {
                std.debug.print("\"{s}\" evaluated to {any}, expected {any}\n", .{ source, value, expected });
                return error.TestUnexpectedResult;
            }
        },
        .fail => |message| {
            std.debug.print("\"{s}\" failed: {s}\n", .{ source, message });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectString(source: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try evalSource(arena_state.allocator(), source);
    switch (outcome) {
        .value => |value| {
            if (value != .string) {
                std.debug.print("\"{s}\" evaluated to {any}, expected string \"{s}\"\n", .{ source, value, expected });
                return error.TestUnexpectedResult;
            }
            try testing.expectEqualStrings(expected, value.string);
        },
        .fail => |message| {
            std.debug.print("\"{s}\" failed: {s}\n", .{ source, message });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectEvalFail(source: []const u8, expected_message: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try evalSource(arena_state.allocator(), source);
    switch (outcome) {
        .value => |value| {
            std.debug.print("\"{s}\" evaluated to {any}, expected failure \"{s}\"\n", .{ source, value, expected_message });
            return error.TestUnexpectedResult;
        },
        .fail => |message| try testing.expectEqualStrings(expected_message, message),
    }
}

fn expectParseFail(source: []const u8, expected_message: []const u8) !void {
    var tree: expr.ExprTree = .{};
    var diagnostic: expr.Diagnostic = .{};
    if (expr.parse(source, &tree, &diagnostic)) {
        std.debug.print("\"{s}\" parsed, expected failure \"{s}\"\n", .{ source, expected_message });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings(expected_message, diagnostic.message);
}

// ------------------------------------------------------ grammar and types

test "arithmetic follows precedence, promotes int/float, and divides into floats" {
    try expectValue("1 + 2 * 3", .{ .integer = 7 });
    try expectValue("(1 + 2) * 3", .{ .integer = 9 });
    try expectValue("10 - 4 - 3", .{ .integer = 3 });
    try expectValue("2 * 3 + 1", .{ .integer = 7 });
    try expectValue("-5 + 2", .{ .integer = -3 });
    try expectValue("--5", .{ .integer = 5 });
    try expectValue("1 + 0.5", .{ .float = 1.5 });
    try expectValue("2.5 * 2", .{ .float = 5.0 });
    // Division always produces a float; whole-number contexts wrap it in
    // round()/floor()/ceil().
    try expectValue("7 / 2", .{ .float = 3.5 });
    try expectValue("6 / 3", .{ .float = 2.0 });
}

test "comparisons and equality follow the value discipline" {
    try expectValue("1 < 2", .{ .boolean = true });
    try expectValue("2 <= 2", .{ .boolean = true });
    try expectValue("3 > 4", .{ .boolean = false });
    try expectValue("4 >= 5", .{ .boolean = false });
    try expectValue("1.5 > 1", .{ .boolean = true });
    try expectValue("1 == 1.0", .{ .boolean = true });
    try expectValue("'done' == 'done'", .{ .boolean = true });
    try expectValue("'done' != 'open'", .{ .boolean = true });
    // Mixed-type equality is simply not equal — never an error.
    try expectValue("'1' == 1", .{ .boolean = false });
    try expectValue("true != 1", .{ .boolean = true });
}

test "boolean logic takes booleans and evaluates both sides" {
    try expectValue("true and false", .{ .boolean = false });
    try expectValue("true or false", .{ .boolean = true });
    try expectValue("not false", .{ .boolean = true });
    try expectValue("not 1 > 2", .{ .boolean = true });
    try expectValue("1 < 2 and 2 < 3", .{ .boolean = true });
    try expectValue("1 < 2 or 1 / 1 > 0", .{ .boolean = true });
}

test "concatenation joins any values with interpolation formatting" {
    try expectString("'a' ++ 'b'", "ab");
    try expectString("'n=' ++ 3", "n=3");
    try expectString("1.5 ++ ' pts'", "1.5 pts");
    try expectString("'flag: ' ++ true", "flag: true");
    try expectString("'sum ' ++ (1 + 2)", "sum 3");
}

test "type mismatches teach instead of coercing" {
    // Statically known mismatches fail the checker with the SAME message
    // eval reports, so every surface teaches with one voice.
    var tree: expr.ExprTree = .{};
    var diagnostic: expr.Diagnostic = .{};
    try testing.expect(expr.parse("'a' - 1", &tree, &diagnostic));
    const unknown: [expr.max_expression_nodes]?expr.ValueKind = @splat(null);
    try testing.expectError(error.ExprType, expr.checkTypes(&tree, &unknown, &diagnostic));
    try testing.expectEqualStrings(expr.arithmetic_type_message, diagnostic.message);

    try expectEvalFail("'a' - 1", expr.arithmetic_type_message);
    try expectEvalFail("'a' * 2", expr.arithmetic_type_message);
    try expectEvalFail("'a' < 'b'", expr.ordering_type_message);
    try expectEvalFail("1 and true", expr.logic_type_message);
    try expectEvalFail("not 3", expr.logic_type_message);
    try expectEvalFail("-'a'", expr.negate_type_message);
}

test "static checking resolves known result kinds and leaves unknowns open" {
    var tree: expr.ExprTree = .{};
    var diagnostic: expr.Diagnostic = .{};
    const unknown: [expr.max_expression_nodes]?expr.ValueKind = @splat(null);

    try testing.expect(expr.parse("1 + 2", &tree, &diagnostic));
    try testing.expectEqual(@as(?expr.ValueKind, .integer), try expr.checkTypes(&tree, &unknown, &diagnostic));

    try testing.expect(expr.parse("1 / 2", &tree, &diagnostic));
    try testing.expectEqual(@as(?expr.ValueKind, .float), try expr.checkTypes(&tree, &unknown, &diagnostic));

    try testing.expect(expr.parse("a > b", &tree, &diagnostic));
    try testing.expectEqual(@as(?expr.ValueKind, .boolean), try expr.checkTypes(&tree, &unknown, &diagnostic));

    try testing.expect(expr.parse("a ++ b", &tree, &diagnostic));
    try testing.expectEqual(@as(?expr.ValueKind, .string), try expr.checkTypes(&tree, &unknown, &diagnostic));

    // A binding whose kind is unknown flows through as unknown.
    try testing.expect(expr.parse("a + 1", &tree, &diagnostic));
    try testing.expectEqual(@as(?expr.ValueKind, null), try expr.checkTypes(&tree, &unknown, &diagnostic));

    // Known binding kinds resolve the result and catch mismatches.
    var kinds: [expr.max_expression_nodes]?expr.ValueKind = @splat(null);
    try testing.expect(expr.parse("a + 1", &tree, &diagnostic));
    kinds[0] = .string; // node 0 is the binding
    try testing.expectError(error.ExprType, expr.checkTypes(&tree, &kinds, &diagnostic));
    try testing.expectEqualStrings(expr.arithmetic_type_message, diagnostic.message);
}

// ------------------------------------------------------- function library

test "number formatting: fixed, thousands, percent" {
    try expectString("fixed(3.14159, 2)", "3.14");
    try expectString("fixed(2, 2)", "2.00");
    try expectString("fixed(1.005, 0)", "1");
    try expectString("fixed(0.5, 1)", "0.5");
    // Rounding is half away from zero (std.fmt's decimal renderer).
    try expectString("fixed(-1.25, 1)", "-1.3");
    try expectString("fixed(1.25, 1)", "1.3");
    try expectString("thousands(1234567)", "1,234,567");
    try expectString("thousands(-1234)", "-1,234");
    try expectString("thousands(999)", "999");
    try expectString("thousands(0)", "0");
    try expectString("percent(0.42)", "42%");
    try expectString("percent(0.417, 1)", "41.7%");
    try expectString("percent(1)", "100%");
    try expectEvalFail("fixed(1.5, 9)", expr.digits_range_message);
    try expectEvalFail("fixed(1.5, -1)", expr.digits_range_message);
}

test "date and time formatting is pure UTC from a model timestamp" {
    try expectString("date(0)", "1970-01-01");
    try expectString("time(0)", "00:00");
    try expectString("datetime(0)", "1970-01-01 00:00");
    try expectString("date(86399)", "1970-01-01");
    try expectString("time(86399)", "23:59");
    // 2026-07-05 14:03:20 UTC.
    try expectString("datetime(1783260200)", "2026-07-05 14:03");
    // Pre-epoch timestamps floor-divide correctly.
    try expectString("date(-1)", "1969-12-31");
    try expectString("time(-1)", "23:59");
    // Leap day.
    try expectString("date(951782400)", "2000-02-29");
    // Out of the formattable range: loud, never wrong.
    try expectEvalFail("date(999999999999)", expr.timestamp_range_message);
    try expectEvalFail("date(-999999999999)", expr.timestamp_range_message);
    // Reading the clock is an effect: the parser teaches where it lives.
    try expectParseFail("now()", expr.clock_function_message);
    try expectParseFail("today()", expr.clock_function_message);
}

test "string functions map ASCII and pass unicode through unharmed" {
    try expectString("upper('done')", "DONE");
    try expectString("lower('DONE')", "done");
    try expectString("trim('  x  ')", "x");
    try expectString("trim('')", "");
    // Unicode bytes pass through byte-for-byte: case mapping is ASCII-only
    // (locale-aware casing is model territory), and UTF-8 stays valid.
    try expectString("upper('café → naïve')", "CAFé → NAïVE");
    try expectString("lower('ÉCOLE')", "École");
    try expectString("trim(' 日本語 ')", "日本語");
}

test "numeric functions: min, max, abs, round, floor, ceil, plural" {
    try expectValue("min(3, 5)", .{ .integer = 3 });
    try expectValue("max(3, 5)", .{ .integer = 5 });
    try expectValue("min(1.5, 2)", .{ .float = 1.5 });
    try expectValue("abs(-4)", .{ .integer = 4 });
    try expectValue("abs(-2.5)", .{ .float = 2.5 });
    try expectValue("round(2.5)", .{ .integer = 3 });
    try expectValue("round(-2.5)", .{ .integer = -3 });
    try expectValue("floor(2.9)", .{ .integer = 2 });
    try expectValue("floor(-2.1)", .{ .integer = -3 });
    try expectValue("ceil(2.1)", .{ .integer = 3 });
    try expectValue("round(7)", .{ .integer = 7 });
    try expectValue("round(7 / 2)", .{ .integer = 4 });
    try expectString("plural(1, 'item', 'items')", "item");
    try expectString("plural(0, 'item', 'items')", "items");
    try expectString("plural(2, 'item', 'items')", "items");
    try expectString("plural(2, 'card', 'cards') ++ ' left'", "cards left");
}

test "pad zero-pads whole numbers for mm:ss counters" {
    try expectString("pad(7, 2)", "07");
    try expectString("pad(0, 4)", "0000");
    try expectString("pad(59, 2)", "59");
    // The sign precedes the zeros and does not count toward the width.
    try expectString("pad(-7, 3)", "-007");
    // Wider than the width prints in full, never truncates.
    try expectString("pad(1234, 2)", "1234");
    try expectString("pad(-1234, 2)", "-1234");
    // The motivating case: a seconds counter formatted as mm:ss.
    try expectString("pad(floor(125 / 60), 2) ++ ':' ++ pad(125 - 60 * floor(125 / 60), 2)", "02:05");
    // Floats mirror thousands: whole numbers only, round() a float first.
    try expectEvalFail("pad(7.9, 2)", findSignature("pad"));
    try expectString("pad(round(7.9), 2)", "08");
    // Width mirrors fixed's digits bound (0-6), taught one past each end.
    try expectString("pad(7, 6)", "000007");
    try expectEvalFail("pad(7, 7)", expr.digits_range_message);
    try expectEvalFail("pad(7, -1)", expr.digits_range_message);
}

test "function misuse fails with the signature as the teaching message" {
    try expectParseFail("fixed(1)", findSignature("fixed"));
    try expectParseFail("plural(1, 'a')", findSignature("plural"));
    try expectParseFail("upper('a', 'b')", findSignature("upper"));
    try expectParseFail("pad(7)", findSignature("pad"));
    try expectParseFail("pad(7, 2, 3)", findSignature("pad"));
    try expectParseFail("sparkle(1)", expr.unknown_function_message);
    try expectEvalFail("thousands(1.5)", findSignature("thousands"));
    try expectEvalFail("upper(3)", findSignature("upper"));
    try expectEvalFail("plural('x', 'a', 'b')", findSignature("plural"));
    try expectEvalFail("pad('x', 2)", findSignature("pad"));
    try expectEvalFail("pad(7, 'x')", expr.digits_range_message);
}

fn findSignature(name: []const u8) []const u8 {
    return expr.findFunction(name).?.signature;
}

// ------------------------------------------------------- hostile inputs

test "division by zero and overflow are loud, defined failures" {
    try expectEvalFail("1 / 0", expr.division_by_zero_message);
    try expectEvalFail("1.5 / 0.0", expr.division_by_zero_message);
    try expectEvalFail("0 / 0", expr.division_by_zero_message);
    try expectEvalFail("9223372036854775807 + 1", expr.integer_overflow_message);
    try expectEvalFail("-9223372036854775807 - 2", expr.integer_overflow_message);
    try expectEvalFail("9223372036854775807 * 2", expr.integer_overflow_message);
    try expectEvalFail("abs(-9223372036854775807 - 1)", expr.abs_overflow_message);
    // f32 arithmetic overflowing to infinity is an error, never a
    // silently rendered "inf".
    try expectEvalFail("340000000000000000000000000000000000000.0 * 10.0", expr.non_finite_message);
}

test "huge literals are rejected at parse time" {
    try expectParseFail("123456789012345678901234567890", expr.integer_literal_overflow_message);
    // A float literal past f32's range never becomes inf.
    const big = "9" ** 60 ++ ".0";
    try expectParseFail(big, expr.number_literal_range_message);
}

test "complexity bounds are taught one past" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Length: at the bound parses, one past teaches.
    {
        const at = try padExpression(arena, expr.max_expression_bytes);
        var tree: expr.ExprTree = .{};
        var diagnostic: expr.Diagnostic = .{};
        try testing.expect(expr.parse(at, &tree, &diagnostic));
        const past = try padExpression(arena, expr.max_expression_bytes + 1);
        try expectParseFail(past, expr.expression_too_long_message);
    }

    // Depth: 16 nested parens parse, 17 teach.
    {
        const at = "(" ** (expr.max_expression_depth - 1) ++ "1" ++ ")" ** (expr.max_expression_depth - 1);
        var tree: expr.ExprTree = .{};
        var diagnostic: expr.Diagnostic = .{};
        try testing.expect(expr.parse(at, &tree, &diagnostic));
        const past = "(" ** expr.max_expression_depth ++ "1" ++ ")" ** expr.max_expression_depth;
        try expectParseFail(past, expr.expression_too_deep_message);
    }

    // Node count: 64 nodes parse, 65 teach ("1+1+..." is 2 nodes per term
    // pair; build one that lands exactly at the bound).
    {
        var at: std.ArrayListUnmanaged(u8) = .empty;
        try at.appendSlice(arena, "1");
        var nodes: usize = 1;
        while (nodes + 2 <= expr.max_expression_nodes) : (nodes += 2) {
            try at.appendSlice(arena, "+1");
        }
        var tree: expr.ExprTree = .{};
        var diagnostic: expr.Diagnostic = .{};
        try testing.expect(expr.parse(at.items, &tree, &diagnostic));
        try testing.expectEqual(@as(u16, @intCast(nodes)), tree.len);
        try at.appendSlice(arena, "+1");
        try expectParseFail(at.items, expr.expression_too_many_nodes_message);
    }

    // Call args: the grammar caps at 4 before arity even applies.
    try expectParseFail("min(1, 2, 3, 4, 5)", expr.expression_too_many_args_message);

    // Chained comparisons are a parse error, not a surprise.
    try expectParseFail("1 < 2 < 3", expr.comparison_chain_message);
    try expectParseFail("a == b == c", expr.comparison_chain_message);

    // Unterminated strings teach the quoting rule.
    try expectParseFail("'unclosed", expr.unterminated_string_message);
}

/// A syntactically valid expression of exactly `len` bytes (few nodes, so
/// only the length bound is in play): '1' padded with parenthesized space.
fn padExpression(arena: std.mem.Allocator, len: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "'");
    try out.appendNTimes(arena, 'x', len - 2);
    try out.appendSlice(arena, "'");
    return out.items;
}

test "hostile parser fuzz: seed-pinned byte soup never crashes or hangs" {
    // Deterministic across runs: the seed is a constant, matching the
    // markdown hostile corpus's generator discipline.
    var prng = std.Random.DefaultPrng.init(0x5eed_0001);
    const random = prng.random();
    const alphabet = "abz_.019 +-*/()<>=!'\"{}, andornotminmaxfixed\xc3\xa9\xe2\x8c\x98\x00";
    var buffer: [expr.max_expression_bytes + 8]u8 = undefined;
    var accepted: usize = 0;
    for (0..2_000) |_| {
        const len = random.intRangeAtMost(usize, 0, buffer.len - 1);
        for (buffer[0..len]) |*byte| {
            byte.* = alphabet[random.intRangeLessThan(usize, 0, alphabet.len)];
        }
        var tree: expr.ExprTree = .{};
        var diagnostic: expr.Diagnostic = .{};
        if (expr.parse(buffer[0..len], &tree, &diagnostic)) {
            accepted += 1;
            try testing.expect(tree.len > 0 and tree.len <= expr.max_expression_nodes);
            try testing.expect(tree.root < tree.len);
            // Post-order invariant: every child index is below its parent,
            // which is what makes evaluation total by construction.
            for (tree.nodes[0..tree.len], 0..) |node, index| {
                switch (node.kind) {
                    .negate, .logical_not => try testing.expect(node.lhs < index),
                    .add, .subtract, .multiply, .divide, .concat, .equal, .not_equal, .less, .less_equal, .greater, .greater_equal, .logical_and, .logical_or => {
                        try testing.expect(node.lhs < index and node.rhs < index);
                    },
                    .call => for (node.args[0..node.arg_count]) |arg| try testing.expect(arg < index),
                    else => {},
                }
            }
        } else {
            try testing.expect(diagnostic.message.len > 0);
        }
    }
    // The soup should be finding both outcomes, or the corpus is dead.
    try testing.expect(accepted > 0);
}

test "generated valid expressions parse, check, and evaluate deterministically" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed_0002);
    const random = prng.random();

    for (0..300) |_| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try genNumeric(random, arena, &out, 0);
        var tree: expr.ExprTree = .{};
        var diagnostic: expr.Diagnostic = .{};
        if (!expr.parse(out.items, &tree, &diagnostic)) {
            // Only the complexity bounds may reject a generated expression.
            const bounded = diagnostic.message.ptr == expr.expression_too_many_nodes_message.ptr or
                diagnostic.message.ptr == expr.expression_too_deep_message.ptr or
                diagnostic.message.ptr == expr.expression_too_long_message.ptr;
            if (!bounded) {
                std.debug.print("generated \"{s}\" failed to parse: {s}\n", .{ out.items, diagnostic.message });
                return error.TestUnexpectedResult;
            }
            continue;
        }
        const unknown: [expr.max_expression_nodes]?expr.ValueKind = @splat(null);
        var type_diag: expr.Diagnostic = .{};
        _ = expr.checkTypes(&tree, &unknown, &type_diag) catch {
            std.debug.print("generated \"{s}\" failed the checker: {s}\n", .{ out.items, type_diag.message });
            return error.TestUnexpectedResult;
        };
        // Evaluation is deterministic: two runs agree exactly (bit-for-bit
        // for floats — both engines run this same evaluator).
        var values_a: [expr.max_expression_nodes]Value = undefined;
        var values_b: [expr.max_expression_nodes]Value = undefined;
        const first = try expr.eval(&tree, &values_a, arena);
        const second = try expr.eval(&tree, &values_b, arena);
        switch (first) {
            .value => |value| {
                try testing.expect(second == .value);
                try testing.expectEqual(std.meta.activeTag(value), std.meta.activeTag(second.value));
                switch (value) {
                    .float => |float| try testing.expectEqual(@as(u32, @bitCast(float)), @as(u32, @bitCast(second.value.float))),
                    .integer => |int| try testing.expectEqual(int, second.value.integer),
                    .boolean => |flag| try testing.expectEqual(flag, second.value.boolean),
                    .string => |text| try testing.expectEqualStrings(text, second.value.string),
                }
            },
            .fail => |message| {
                try testing.expect(second == .fail);
                try testing.expectEqualStrings(message, second.fail);
            },
        }
    }
}

/// Generate a random numeric expression (integers, floats, arithmetic,
/// numeric functions) of bounded depth.
fn genNumeric(random: std.Random, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), depth: usize) error{OutOfMemory}!void {
    if (depth >= 4 or random.intRangeLessThan(u8, 0, 3) == 0) {
        var buffer: [32]u8 = undefined;
        if (random.boolean()) {
            const int = random.intRangeAtMost(i32, -1000, 1000);
            try out.appendSlice(arena, std.fmt.bufPrint(&buffer, "({d})", .{int}) catch unreachable);
        } else {
            const float = @as(f32, @floatFromInt(random.intRangeAtMost(i32, -10000, 10000))) / 100.0;
            try out.appendSlice(arena, std.fmt.bufPrint(&buffer, "({d:.2})", .{float}) catch unreachable);
        }
        return;
    }
    switch (random.intRangeLessThan(u8, 0, 6)) {
        0, 1, 2 => {
            const ops = [_][]const u8{ " + ", " - ", " * ", " / " };
            try out.appendSlice(arena, "(");
            try genNumeric(random, arena, out, depth + 1);
            try out.appendSlice(arena, ops[random.intRangeLessThan(usize, 0, ops.len)]);
            try genNumeric(random, arena, out, depth + 1);
            try out.appendSlice(arena, ")");
        },
        3 => {
            const fns = [_][]const u8{ "abs", "round", "floor", "ceil" };
            try out.appendSlice(arena, fns[random.intRangeLessThan(usize, 0, fns.len)]);
            try out.appendSlice(arena, "(");
            try genNumeric(random, arena, out, depth + 1);
            try out.appendSlice(arena, ")");
        },
        4 => {
            const fns = [_][]const u8{ "min", "max" };
            try out.appendSlice(arena, fns[random.intRangeLessThan(usize, 0, fns.len)]);
            try out.appendSlice(arena, "(");
            try genNumeric(random, arena, out, depth + 1);
            try out.appendSlice(arena, ", ");
            try genNumeric(random, arena, out, depth + 1);
            try out.appendSlice(arena, ")");
        },
        else => {
            try out.appendSlice(arena, "-");
            try genNumeric(random, arena, out, depth + 1);
        },
    }
}

// ---------------------------------------------------------- engine parity

const ParityModel = struct {
    count: usize = 3,
    total: usize = 12,
    price: f32 = 19.99,
    fraction: f32 = 0.417,
    stamp: i64 = 1783260200,
    label: []const u8 = "  Mixed Case  ",
    busy: bool = false,
    items: []const Item = &.{
        .{ .id = 1, .qty = 1 },
        .{ .id = 2, .qty = 4 },
    },

    const Item = struct { id: u32, qty: u32 };

    pub fn doneCount(model: *const ParityModel) usize {
        return model.total - model.count;
    }
};

const ParityMsg = union(enum) {
    press,
    pick: u32,
};

/// Every operator and every library function, both engines, one tree:
/// text interpolation, attribute values, if tests, and template args all
/// carry expressions.
const parity_source =
    \\<template name="stat" args="title value">
    \\  <row gap="4">
    \\    <text>{title}</text>
    \\    <badge>{value}</badge>
    \\    <if test="{value == 'none'}"><text>empty</text></if>
    \\  </row>
    \\</template>
    \\<column gap="8">
    \\  <text>{count} of {total} ({percent(count / total, 1)})</text>
    \\  <text>{count + 1} {count - 1} {count * 2} {fixed(count / total, 2)}</text>
    \\  <text>{'$' ++ fixed(price, 2)} {thousands(1234567 + count)}</text>
    \\  <text>{plural(count, 'item', 'items')} · {upper(trim(label))} · {lower('SHOUT')}</text>
    \\  <text>{date(stamp)} {time(stamp)} {datetime(stamp)}</text>
    \\  <text>{min(count, 2)} {max(count, 2)} {abs(0 - count)} {round(price)} {floor(price)} {ceil(fraction)}</text>
    \\  <text>{pad(count, 2)}:{pad(doneCount, 2)} {pad(0 - count, 3)} {pad(total * 100, 2)}</text>
    \\  <text>{-price} {not busy} {count > 1 and not busy} {count == 3 or busy} {fraction >= 0.5}</text>
    \\  <progress value="{fraction * 100}" />
    \\  <if test="{count > 0 and doneCount >= 9}">
    \\    <text>on track</text>
    \\  </if>
    \\  <else>
    \\    <text>behind</text>
    \\  </else>
    \\  <button disabled="{doneCount == 0}" on-press="press">Clear</button>
    \\  <for each="items" as="item" key="id">
    \\    <row gap="2">
    \\      <text>{plural(item.qty, 'unit', 'units')} {item.qty * 10 + item.id}</text>
    \\      <badge selected="{item.qty > 1}" on-press="pick:{item.id}">{item.qty}</badge>
    \\    </row>
    \\  </for>
    \\  <use template="stat" title="{'open: ' ++ count}" value="{plural(doneCount, 'one', 'many')}" />
    \\</column>
;

const ParityUi = canvas.Ui(ParityMsg);
const ParityInterpreter = markup_view.MarkupView(ParityModel, ParityMsg);
const ParityCompiled = canvas.CompiledMarkupView(ParityModel, ParityMsg, parity_source);

fn collectTexts(widget: canvas.Widget, out: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator) !void {
    try out.append(allocator, widget.text);
    for (widget.children) |child| try collectTexts(child, out, allocator);
}

test "expression parity: interpreter and compiled engine agree on every operator and function" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = ParityModel{};

    var view = try ParityInterpreter.init(arena, parity_source);
    var interpreted_ui = ParityUi.init(arena);
    const interpreted = try interpreted_ui.finalize(view.build(&interpreted_ui, &model) catch |err| {
        std.debug.print("interpreter failed at {d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        return err;
    });

    var compiled_ui = ParityUi.init(arena);
    const compiled = try compiled_ui.finalize(ParityCompiled.build(&compiled_ui, &model));

    // Same rendered text, byte for byte (floats format through the one
    // shared evaluator, so this is the bit-for-bit float check).
    var interpreted_texts: std.ArrayListUnmanaged([]const u8) = .empty;
    var compiled_texts: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectTexts(interpreted.root, &interpreted_texts, arena);
    try collectTexts(compiled.root, &compiled_texts, arena);
    try testing.expectEqual(interpreted_texts.items.len, compiled_texts.items.len);
    for (interpreted_texts.items, compiled_texts.items) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }

    // Same handler table: ids, events, and message payloads.
    try testing.expectEqual(interpreted.handlers.len, compiled.handlers.len);
    for (interpreted.handlers, compiled.handlers) |expected, actual| {
        try testing.expectEqual(expected.id, actual.id);
        try testing.expectEqual(expected.event, actual.event);
    }

    // Pin the evaluated texts so parity cannot be vacuous.
    try expectHasText(interpreted_texts.items, "3 of 12 (25.0%)");
    try expectHasText(interpreted_texts.items, "4 2 6 0.25");
    try expectHasText(interpreted_texts.items, "$19.99 1,234,570");
    try expectHasText(interpreted_texts.items, "items · MIXED CASE · shout");
    try expectHasText(interpreted_texts.items, "2026-07-05 14:03 2026-07-05 14:03");
    try expectHasText(interpreted_texts.items, "2 3 3 20 19 1");
    try expectHasText(interpreted_texts.items, "03:09 -003 1200");
    try expectHasText(interpreted_texts.items, "-19.99 true true true false");
    try expectHasText(interpreted_texts.items, "on track");
    try expectHasText(interpreted_texts.items, "unit 11");
    try expectHasText(interpreted_texts.items, "units 42");
    try expectHasText(interpreted_texts.items, "open: 3");
    try expectHasText(interpreted_texts.items, "many");
}

fn expectHasText(texts: []const []const u8, expected: []const u8) !void {
    for (texts) |text| {
        if (std.mem.eql(u8, text, expected)) return;
    }
    std.debug.print("no widget carries the text \"{s}\"\n", .{expected});
    return error.TestUnexpectedResult;
}

test "expression failures carry the evaluator's teaching message in the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = ParityModel{};

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        // Division by zero is value-dependent: the build fails loudly.
        .{ .source = "<column><text>{count / (count - 3)}</text></column>", .message = expr.division_by_zero_message },
        // A string minus a number is an error, not a NaN.
        .{ .source = "<column><text>{label - 1}</text></column>", .message = expr.arithmetic_type_message },
        // Ordering strings is an error.
        .{ .source = "<column><text>{label > 'a'}</text></column>", .message = expr.ordering_type_message },
        // The clock teaching error names the model as now()'s home.
        .{ .source = "<column><text>{now()}</text></column>", .message = expr.clock_function_message },
        // Unknown bindings inside expressions keep the binding error.
        .{ .source = "<column><text>{missing + 1}</text></column>", .message = "binding does not name a model field" },
    };
    for (cases) |case| {
        var view = try ParityInterpreter.init(arena, case.source);
        var ui = ParityUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expectEqualStrings(case.message, view.diagnostic.message);
    }
}

test "expressions stay out of message tags and each iterables" {
    // Message tags are static: a computed name never parses.
    try testing.expectEqual(@as(?markup.MessageExpression, null), markup.parseMessageExpression("'msg' ++ suffix"));
    try testing.expectEqual(@as(?markup.MessageExpression, null), markup.parseMessageExpression("pick:{item.id + 1}"));

    // for each is path-only: an expression iterable is a build error
    // (filtering/sorting is a deliberate deferral, not an accident).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = ParityModel{};
    var view = try ParityInterpreter.init(arena, "<column><for each=\"{items}\" as=\"i\"><text>{i.id}</text></for></column>");
    var ui = ParityUi.init(arena);
    try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
}

test "validate checks interpolation expressions and expression string literals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Valid expressions in text and attributes pass the model-free pass.
    {
        var parser = markup.Parser.init(arena_state.allocator(), "<column>\n  <text>{plural(n, 'item', 'items')} at {percent(f, 1)}</text>\n</column>");
        try testing.expectEqual(@as(?markup.MarkupErrorInfo, null), markup.validate(try parser.parse()));
    }
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "<column>\n  <text>{count +} open</text>\n</column>", .message = expr.expected_operand_message },
        .{ .source = "<column>\n  <text>{sparkle(count)}</text>\n</column>", .message = expr.unknown_function_message },
        .{ .source = "<column>\n  <text>{now()}</text>\n</column>", .message = expr.clock_function_message },
        .{ .source = "<column>\n  <text>{'a' - 1}</text>\n</column>", .message = expr.arithmetic_type_message },
        .{ .source = "<column>\n  <text>open {count</text>\n</column>", .message = markup.unterminated_interpolation_message },
        // The tofu guard reaches expression string literals: text an
        // expression can inject into a label rides the same check.
        .{ .source = "<column>\n  <text>{plural(n, '\xe2\x8c\x98', 'keys')}</text>\n</column>", .message = markup.font_coverage_message },
        .{ .source = "<row>\n  <button label=\"{plural(n, '\xe2\x8c\x98', 'keys')}\" on-press=\"go\">Go</button>\n</row>", .message = markup.font_coverage_message },
        .{ .source = "<column>\n  <if test=\"{count >}\"><text>x</text></if>\n</column>", .message = expr.expected_operand_message },
    };
    for (cases) |case| {
        var parser = markup.Parser.init(arena_state.allocator(), case.source);
        const info = markup.validate(try parser.parse()) orelse {
            std.debug.print("expected \"{s}\" for: {s}\n", .{ case.message, case.source });
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(case.message, info.message);
        try testing.expect(info.line > 0);
        try testing.expect(info.column > 0);
    }
}

test "arena-computed bindings stay out of expression comparisons" {
    const ArenaModel = struct {
        count: usize = 1,

        pub fn summary(model: *const @This(), arena: std.mem.Allocator) []const u8 {
            _ = model;
            return arena.dupe(u8, "formatted") catch "";
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = ArenaModel{};

    // Arena scalars work as expression operands anywhere else...
    {
        var view = try markup_view.MarkupView(ArenaModel, ParityMsg).init(arena, "<column><text>{upper(summary)}</text></column>");
        var ui = ParityUi.init(arena);
        const tree = try ui.finalize(try view.build(&ui, &model));
        try testing.expectEqualStrings("FORMATTED", tree.root.children[0].text);
    }
    // ...but a comparison operand rejects them with the equality rule's
    // teaching message, exactly like {a == b}.
    {
        var view = try markup_view.MarkupView(ArenaModel, ParityMsg).init(arena, "<column><if test=\"{summary == 'formatted'}\"><text>x</text></if></column>");
        var ui = ParityUi.init(arena);
        try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
        try testing.expectEqualStrings(markup.arena_scalar_equality_message, view.diagnostic.message);
    }
}

test "expression bounds hold inside markup attributes end to end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One past the depth bound inside an attribute value, through the
    // validator (what native markup check runs)...
    const deep = "(" ** expr.max_expression_depth ++ "1" ++ ")" ** expr.max_expression_depth;
    const source = try std.fmt.allocPrint(arena, "<row gap=\"{{{s}}}\" />", .{deep});
    var parser = markup.Parser.init(arena, source);
    const info = markup.validate(try parser.parse()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(expr.expression_too_deep_message, info.message);

    // ...and through the interpreter, with the same message.
    const model = ParityModel{};
    var view = try ParityInterpreter.init(arena, source);
    var ui = ParityUi.init(arena);
    try testing.expectError(error.MarkupBuild, view.build(&ui, &model));
    try testing.expectEqualStrings(expr.expression_too_deep_message, view.diagnostic.message);
}
