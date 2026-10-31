const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const m = sdk.canvas.ui_markup;
const shapes = @import("native_sdk").canvas.ui_markup_shapes;
const complete = @import("surface_layout_e2e_tests.zig").expectComplete;
var modes: [5]usize = @splat(0);
fn owned(input: []const u8, output: []u8) usize {
    if (input[0] == 115) modes[input[2]] += 1;
    const n = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return n;
}
fn shape(source: []const u8, mode: u8) !void {
    errdefer std.debug.print("shape mode={d}: {s}\n", .{ mode, source });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = m.Parser.init(arena.allocator(), source);
    const raw = try parser.parse();
    for ([_]bool{ false, true }) |typed| {
        const doc = if (typed) try m.canonicalize(arena.allocator(), raw) else raw;
        var node = doc.root.?;
        node.src_path = "components/check.native";
        const a = switch (mode) {
            0 => m.contextMenuShapeError(node),
            1 => m.spanShapeError(node),
            2 => m.reactionsShapeError(node),
            else => unreachable,
        };
        const b = shapes.shape(owned, node, mode);
        try complete(a, b);
        if (a) |info| try std.testing.expectEqual(@intFromPtr(info.path.ptr), @intFromPtr(b.?.path.ptr));
    }
}
test "compiled markup shapes preserve recursive menu rules and diagnostic ordering" {
    _ = core.initialModel();
    modes = @splat(0);
    for ([_][]const u8{
        "<context-menu><menu-item on-press=\"tick\">Run</menu-item><separator/></context-menu>",
        "<context-menu><for each=\"rows\" as=\"row\"><if test=\"{yes}\"><menu-item on-press=\"pick:{row.id}\">{upper(row.name)}</menu-item></if><else><separator/></else></for><else><menu-item on-press=\"tick\">Empty</menu-item></else></context-menu>",
        "<context-menu/>",
        "<context-menu bad=\"x\"><text>wrong</text></context-menu>",
        "<context-menu><separator bad=\"x\"/></context-menu>",
        "<context-menu><separator><text>x</text></separator></context-menu>",
        "<context-menu><else><separator/></else></context-menu>",
        "<context-menu><if><separator/></if></context-menu>",
        "<context-menu><if test=\"{}\"><separator/></if></context-menu>",
        "<context-menu><if test=\"{1 + true}\"><separator/></if></context-menu>",
        "<context-menu><for as=\"row\"><separator/></for></context-menu>",
        "<context-menu><for each=\"rows\"><separator/></for></context-menu>",
        "<context-menu><for each=\"rows\" as=\"row\"/></context-menu>",
        "<context-menu><for each=\"rows\" as=\"row\"><if test=\"true\"/></for></context-menu>",
        "<context-menu><text>wrong</text></context-menu>",
        "<context-menu><use template=\"thing\"/></context-menu>",
        "<context-menu><menu-item bad=\"x\"/></context-menu>",
        "<context-menu><menu-item/></context-menu>",
        "<context-menu><menu-item on-press=\"tick\"/></context-menu>",
        "<context-menu><menu-item on-press=\"tick:{ row.id }\">Run</menu-item></context-menu>",
        "<context-menu><menu-item disabled=\"{upper(1)}\" on-press=\"bad:{}\">Run</menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"bad:{}\" disabled=\"{upper(1)}\">Run</menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"tick\"><text>nested</text></menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"tick\">first\n{unknown()} second</menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"tick\">first\n{1 + true} second</menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"tick\">first\n{plural(n, '\xe2\x8c\x98', 'keys')} second</menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"tick\">first\n\xe2\x8c\x98 second</menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"tick\">first\n{unclosed</menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"tick\">{bad()} {</menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"tick\">\xff {bad()}</menu-item></context-menu>",
        "<context-menu><menu-item on-press=\"tick\">{x == y} {1 + 2} {trim(' x ')}</menu-item></context-menu>",
    }) |source| try shape(source, 0);
    try std.testing.expect(modes[0] > 0 and modes[3] > 0 and modes[4] > 0);
}
test "compiled markup shapes preserve span and reaction vocabularies before content" {
    _ = core.initialModel();
    for ([_][]const u8{
        "<span>text</span>",                     "<span weight=\"bold\" scale=\"1.25\" mono italic=\"{yes}\" underline=\"false\" foreground=\"accent\">{raw}</span>",
        "<span weight=\"bad\"/>",                "<span scale=\"0\" weight=\"bad\"/>",
        "<span scale=\"1e-46\"/>",               "<span scale=\"-1\"/>",
        "<span scale=\"inf\"/>",                 "<span scale=\"nan\"/>",
        "<span scale=\"nope\"/>",                "<span scale=\"{a + b}\">x</span>",
        "<span weight=\"{upper(1)}\">x</span>",  "<span scale=\"{1 + true}\">x</span>",
        "<span mono=\"{}\">x</span>",            "<span foreground=\"bad\">x</span>",
        "<span foreground=\"{color}\">x</span>", "<span bad=\"true\"/>",
        "<span/>",                               "<span><span>nested</span></span>",
        "<span>unclosed {</span>", // shape alone deliberately does not validate text
    }) |source| try shape(source, 1);
    for ([_][]const u8{
        "<reactions>One</reactions>",                              "<reactions text-alignment=\"end\">Two</reactions>",
        "<reactions text-alignment=\"{alignment}\">x</reactions>", "<reactions text-alignment=\"bad\"/>",
        "<reactions bad=\"x\"/>",                                  "<reactions/>",
        "<reactions><text>x</text></reactions>",                   "<reactions>unclosed {</reactions>",
    }) |source| try shape(source, 2);
}
test "compiled markup shapes preserve exact malformed UTF8 spans and borrowed identity" {
    _ = core.initialModel();
    var bytes: [4]u8 = undefined;
    for (0..256) |lead| {
        bytes[0] = @intCast(lead);
        for ([_]u8{ 0, 0x28, 0x7f, 0x80, 0x90, 0x9f, 0xa0, 0xbf, 0xff }) |tail| {
            @memset(bytes[1..], tail);
            for (1..5) |len| {
                const a = m.firstUncoveredCodepoint(bytes[0..len]);
                const b = shapes.firstUncovered(owned, bytes[0..len]);
                try complete(a, b);
                if (a) |found| try std.testing.expectEqual(@intFromPtr(found.bytes.ptr), @intFromPtr(b.?.bytes.ptr));
            }
        }
    }
    for ([_][]const u8{ "{\xff}", "prefix {unclosed\xff", "\t\r\n\x7f", "Cafe\xc3\xa9", "a\n\xe2\x8c\x98", "\xf4\x8f\xbf\xbf" }) |text| {
        try complete(m.firstUncoveredCodepoint(text), shapes.firstUncovered(owned, text));
    }
}
test "compiled markup shapes preserve structural expression kinds and all definite diagnostics" {
    _ = core.initialModel();
    for ([_][]const u8{
        "x",          "-x",         "not x",        "x + y",        "x / y",         "x ++ y",       "x == y",          "x < y",     "x and y",       "x or y",
        "fixed(x,y)", "percent(x)", "percent(x,y)", "thousands(x)", "upper(x)",      "lower(x)",     "trim(x)",         "date(x)",   "time(x)",       "datetime(x)",
        "min(x,y)",   "max(x,y)",   "abs(x)",       "round(x)",     "floor(x)",      "ceil(x)",      "plural(x,y,z)",   "pad(x,y)",  "-'s'",          "not 1",
        "'s' + 2",    "1 < false",  "1 and true",   "upper(1)",     "fixed(true,1)", "fixed(1,1.5)", "percent(1,true)", "date(1.5)", "plural(1,2,3)",
    }) |source| {
        var tree: m.expr.ExprTree = .{};
        var parse_diag: m.expr.Diagnostic = .{};
        try std.testing.expect(m.expr.parse(source, &tree, &parse_diag));
        for (0..5) |left| for (0..5) |right| {
            var kinds: [m.expr.max_expression_nodes]?m.expr.ValueKind = @splat(null);
            var binding: usize = 0;
            for (tree.nodes[0..tree.len], 0..) |node, index| if (node.kind == .binding) {
                const n = if (binding == 0) left else right;
                kinds[index] = if (n == 0) null else @enumFromInt(n - 1);
                binding += 1;
            };
            var a: m.expr.Diagnostic = .{};
            var b: m.expr.Diagnostic = .{};
            const av = m.expr.checkTypes(&tree, &kinds, &a);
            const bv = shapes.checkTypes(owned, &tree, &kinds, &b);
            if (av) |value| try std.testing.expectEqual(value, try bv) else |err| try std.testing.expectError(err, bv);
            try complete(a, b);
        };
    }
}
