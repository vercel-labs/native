const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const m = sdk.canvas.ui_markup;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: usize = 0;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 109) calls += 1;
    return core.nativeWindowPolicy(input, output);
}
// Compare every initialized value, including exact numeric bits and every
// borrowed byte-slice address; storage allocations themselves are independent.
fn same(expected: anytype, actual: @TypeOf(expected)) anyerror!void {
    const T = @TypeOf(expected);
    if (T == m.expr.ExprTree) {
        try exact(expected.len, actual.len);
        try exact(expected.root, actual.root);
        try same(expected.nodes[0..expected.len], actual.nodes[0..actual.len]);
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| try same(@field(expected, field.name), @field(actual, field.name)),
        .optional => {
            try exact(expected != null, actual != null);
            if (expected) |value| try same(value, actual.?);
        },
        .pointer => |info| if (info.size == .slice) {
            try exact(expected.len, actual.len);
            if (info.child == u8) try exact(@intFromPtr(expected.ptr), @intFromPtr(actual.ptr));
            for (expected, actual) |a, b| try same(a, b);
        } else if (info.size == .one) try same(expected.*, actual.*) else try exact(expected, actual),
        .array => for (expected, actual) |a, b| try same(a, b),
        .@"union" => switch (expected) {
            inline else => |value, tag| {
                try exact(std.meta.activeTag(expected), std.meta.activeTag(actual));
                try same(value, @field(actual, @tagName(tag)));
            },
        },
        else => try exact(expected, actual),
    }
}
fn compare(document: m.MarkupDocument, failure: usize, resize_failure: usize) !usize {
    defer core.rt.frameReset();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    var ab = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ab.deinit();
    var fa = std.testing.FailingAllocator.init(aa.allocator(), .{ .fail_index = failure, .resize_fail_index = resize_failure });
    var fb = std.testing.FailingAllocator.init(ab.allocator(), .{ .fail_index = failure, .resize_fail_index = resize_failure });
    const a = m.canonicalize(fa.allocator(), document);
    const before = calls;
    const b = m.canonicalizeWithPolicy(observed, fb.allocator(), document);
    if (a) |value| try same(value, try b) else |err| try std.testing.expectError(err, b);
    try std.testing.expect(calls == before + 2);
    try exact(fa.alloc_index, fb.alloc_index);
    try exact(fa.resize_index, fb.resize_index);
    try exact(fa.allocated_bytes, fb.allocated_bytes);
    try exact(fa.freed_bytes, fb.freed_bytes);
    try exact(fa.has_induced_failure, fb.has_induced_failure);
    return fa.alloc_index;
}
fn check(document: m.MarkupDocument) !void {
    _ = try compare(document, std.math.maxInt(usize), std.math.maxInt(usize));
}
fn checkSource(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = m.Parser.init(arena.allocator(), source);
    try check(try parser.parse());
}
test "compiled markup canonicalization preserves complete typed trees expression bits and borrowed aliases" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<row/>",
        "<import src=\"parts.native\"/><template name=\"t\" args=\"x\"><text>{x} {max(1, 2)} tail{unfinished</text></template><row a=\"literal\" b=\"{ x }\" c=\"{ a == b }\" d=\"{x + 1}\" e=\"{ }\" f=\"{\" on-press=\"tag:{item.id}\" on-hold=\"bare\" on-drag=\"broken:{}\"/>",
        "<text>{} { } {true} {9223372036854775807} {9223372036854775808} {1.23456789} {'café'} {invalid(1)} {x == y}</text>",
        "<text>{a}{b}{{x}}suffix{\n x \t}prefix{missing</text>",
        "<template name=\"t\"><text>no interpolation</text></template>",
    }) |source| try checkSource(source);
    try check(.{});
}
test "compiled markup canonicalization preserves every arena failure and cached input state" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "<template name=\"t\"><text>A {x} {max(1, 2)} {'suffix'} {unterminated</text></template><row a=\"{x + 1}\" b=\"bad\" on-press=\"go:{item.id}\"><text>{x}{ }{bad(1)} {1.25} {'x'}</text><row/></row>";
    var parser = m.Parser.init(arena.allocator(), source);
    const raw = try parser.parse();
    const cached = try m.canonicalize(arena.allocator(), raw);
    for ([_]m.MarkupDocument{ raw, cached }) |document| for ([_]usize{ 0, 1, std.math.maxInt(usize) }) |resize| {
        const attempts = try compare(document, std.math.maxInt(usize), resize);
        for (0..attempts + 1) |failure| _ = try compare(document, failure, resize);
    };
    const typed: m.TypedAttrValue = .{ .binding = "retained" };
    const attrs = [_]m.MarkupAttr{.{ .name = "a", .value = "replacement", .line = 7, .column = 3, .typed = &typed }};
    const text = [_]m.TypedTextSegment{.{ .literal = "retained text cache" }};
    const root: m.MarkupNode = .{ .kind = .text, .attrs = &attrs, .text = "no braces", .typed_text = &text };
    try check(.{ .root = root, .imports = &.{root}, .source_bytes = 731 });
}
test "compiled markup canonicalization preserves every raw attribute and interpolation byte" {
    _ = core.initialModel();
    var value: [64]u8 = undefined;
    const cases = [_][]const u8{ "{c}", "{{c}}", "{ {c} }", "{a=={c}}", "go:{{c}}", "before{{c}}after", "{c}{", "{{c}\t}" };
    for (0..256) |byte| for (cases) |format| {
        const at = std.mem.indexOf(u8, format, "{c}").?;
        @memcpy(value[0..at], format[0..at]);
        value[at] = @intCast(byte);
        @memcpy(value[at + 1 ..][0 .. format.len - at - 3], format[at + 3 ..]);
        const text = value[0 .. format.len - 2];
        const attrs = [_]m.MarkupAttr{ .{ .name = "value", .value = text, .line = 3, .column = 7 }, .{ .name = "on-press", .value = text, .line = 9, .column = 2 } };
        try check(.{ .root = .{ .kind = .text, .text = text, .attrs = &attrs } });
    };
}
test "compiled markup canonicalization preserves document traversal and large unbounded text" {
    _ = core.initialModel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source: std.ArrayListUnmanaged(u8) = .empty;
    const a = arena.allocator();
    for (0..128) |_| try source.appendSlice(a, "<row a=\"{x + 1}\">");
    try source.appendSlice(a, "<text>");
    try source.appendNTimes(a, 'x', 65537);
    try source.appendSlice(a, "{count} {'end'}</text>");
    for (0..128) |_| try source.appendSlice(a, "</row>");
    try checkSource(source.items);
}
