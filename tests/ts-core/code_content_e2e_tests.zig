//! Actual shipped scriptc lexer against complete independent native output.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const code = canvas.code;
const owner = canvas.CodeContentPolicy;
const Ui = canvas.Ui(core.Msg);
const exact = @import("component_construction_e2e_tests.zig").exact;

fn compare(source: []const u8, language: code.Language, before: *code.HighlightState, after: *code.HighlightState) !void {
    var expected_storage: [canvas.text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    var actual_storage: [canvas.text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const expected = code.highlightWithState(source, language, &expected_storage, before);
    const actual = owner.highlight(core.nativeWindowPolicy, source, language, &actual_storage, after);
    core.rt.frameReset();
    try std.testing.expectEqualDeep(before.*, after.*);
    try std.testing.expectEqualDeep(expected, actual);
    var at: usize = 0;
    for (actual) |span| {
        try std.testing.expectEqual(@intFromPtr(source.ptr) + at, @intFromPtr(span.text.ptr));
        at += span.text.len;
    }
    try std.testing.expectEqual(source.len, at);
}

const corpus = [_][]const u8{
    "const café = 1; // comment\n/* still */ return @call(x); true false nil Array String usize;\x00\xff\xc0\xaf",
    "return <Outer icon={<Inner a={count < limit ? <Leaf /> : null} />} data=\"x\">text</Outer>;",
    "<main title=\"a\\\" b='c'>\n<!-- comment\nend -->text</main>",
    "---\nname: value\n'it''s': true\nitems: [&ref, !tag, ~]\nurl: https://x/#fragment\n# comment\n...",
    "#include <stdio.h>\n'a 'static 'é' '\\x41' '\\u{1_f600}' 0xff 1.2_3 // tail",
    "# Title\n> quote\n1. item\n- item\n```ts\nconst x = 1;\n```\n[text](url) ![image](x) `code` **bold** \\_ <!-- x -->",
    "SELECT true FROM table WHERE key = 'it''s'; -- SQL\nbody { color: red; width: 1px; }",
    "/* open comment",
    "'unterminated \\ quote",
    "",
};

test "compiled code content preserves complete spans and state at every source chunk boundary" {
    var cases: usize = 0;
    for (std.enums.values(code.Language)) |language| for (corpus) |source| for (0..source.len + 1) |split| {
        var before: code.HighlightState = .{};
        var after = before;
        try compare(source[0..split], language, &before, &after);
        try compare(source[split..], language, &before, &after);
        cases += 2;
    };
    try std.testing.expect(cases > 20_000);
}

test "compiled code content retains exact u64 state including all inactive context slots" {
    for ([_]usize{ 0, 1, 0xffff_ffff, 0x1_0000_0000, 9_007_199_254_740_993 }) |depth| {
        var before: code.HighlightState = .{ .html_expression_depth = depth, .html_tag_expression_base = depth };
        for (0..32) |i| {
            before.html_tag_context_bases[i] = std.math.maxInt(usize) - i;
            before.html_element_expression_bases[i] = 9_007_199_254_740_993 + i;
        }
        var after = before;
        try compare("{}", .tsx, &before, &after);
        try compare("<Leaf a={true} />", .tsx, &before, &after);
        try compare("", .plain, &before, &after);
    }
}

test "compiled code content span overflow preserves bytes and continues state through large inputs" {
    const pattern = "const x = 1; ";
    const source = try std.testing.allocator.alloc(u8, pattern.len * 800 + 7);
    defer std.testing.allocator.free(source);
    for (0..800) |i| @memcpy(source[i * pattern.len ..][0..pattern.len], pattern);
    @memcpy(source[pattern.len * 800 ..], "/* open");
    for (std.enums.values(code.Language)) |language| {
        var before: code.HighlightState = .{};
        var after = before;
        try compare(source, language, &before, &after);
        try compare("end */ const next = true;", language, &before, &after);
    }
}

fn codeInput(_: canvas.TextInputEvent) core.Msg {
    return .increment_and_persist;
}

test "compiled code content preserves complete component trees decorations chunks and typed routes" {
    const large = try std.testing.allocator.alloc(u8, 16_384);
    defer std.testing.allocator.free(large);
    for (large, 0..) |*byte, i| byte.* = if (i % 32 == 31) '\n' else if (i % 5 == 0) '\xff' else 'a';
    const sources = [_][]const u8{ "", "\n", "x\n", corpus[0], corpus[1], corpus[5], large };
    for (std.enums.values(code.Language)) |language| for (sources) |source| for (0..16) |facts| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var reference = Ui.init(arena.allocator());
        var compiled = Ui.init(arena.allocator());
        compiled.code_content_policy = core.nativeWindowPolicy;
        const options: Ui.CodeOptions = .{ .language = language, .editable = facts & 1 != 0, .wrap = facts & 2 != 0, .line_numbers = facts & 4 != 0, .height = if (facts & 8 != 0) 120 else 0, .width = 320, .grow = 1, .min_width = 20, .key = .{ .str = "source" }, .semantics = .{ .label = "Code\x00\xff" }, .on_input = codeInput, .added_lines = &.{ 1, 32, 64, 96, 128, 128 }, .removed_lines = &.{ 2, 31, 63, 95, 127 } };
        const expected = try reference.finalize(reference.code(options, source));
        const actual = try compiled.finalize(compiled.code(options, source));
        core.rt.frameReset();
        try exact(expected, actual);
        var before: [1024]canvas.WidgetLayoutNode = undefined;
        var after: [1024]canvas.WidgetLayoutNode = undefined;
        try exact(try canvas.layoutWidgetTree(expected.root, .init(0, 0, 320, 240), &before), try canvas.layoutWidgetTree(actual.root, .init(0, 0, 320, 240), &after));
        if (options.editable) try exact(expected.msgForTextEdit(expected.root.id, .{ .insert_text = "changed" }), actual.msgForTextEdit(actual.root.id, .{ .insert_text = "changed" }));
    };
}

test "compiled code content retains invalid decoration failure and exact u64 span budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const usize{ &.{0}, &.{129}, &.{std.math.maxInt(usize)}, &.{1} }) |lines| {
        var reference = Ui.init(arena.allocator());
        var compiled = Ui.init(arena.allocator());
        compiled.code_content_policy = core.nativeWindowPolicy;
        const options: Ui.CodeOptions = .{ .added_lines = lines, .removed_lines = &.{1} };
        const before = reference.code(options, "const x = 1;");
        const after = compiled.code(options, "const x = 1;");
        try std.testing.expect(reference.failed and compiled.failed);
        try exact(before, after);
        core.rt.frameReset();
    }
    for ([_]usize{ 0, 480, 511, 512, 9_007_199_254_740_993, std.math.maxInt(usize) - 64 }) |used| {
        const actual = owner.spanBudget(core.nativeWindowPolicy, used, 2, 32);
        try std.testing.expectEqual(used + @as(usize, if (used + 33 > 512) 1 else 32), actual.used);
        try std.testing.expectEqual(@as(usize, 1), actual.remaining);
        try std.testing.expectEqual(used + 33 > 512, actual.plain);
        core.rt.frameReset();
    }
}
