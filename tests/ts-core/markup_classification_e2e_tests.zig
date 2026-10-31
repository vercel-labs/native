const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const m = sdk.canvas.ui_markup;
var channels: [3]usize = @splat(0);
fn owned(input: []const u8, output: []u8) usize {
    if (input[0] == 109) channels[input[3]] += 1;
    const size = core.nativeWindowPolicy(input, output);
    core.rt.frameReset();
    return size;
}
fn identical(a: anytype, b: @TypeOf(a)) anyerror!void {
    switch (@typeInfo(@TypeOf(a))) {
        .@"struct" => |info| inline for (info.fields) |field| try identical(@field(a, field.name), @field(b, field.name)),
        .@"union" => {
            try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
            switch (a) {
                inline else => |value, tag| try identical(value, @field(b, @tagName(tag))),
            }
        },
        .optional => {
            try std.testing.expectEqual(a != null, b != null);
            if (a) |value| try identical(value, b.?);
        },
        .pointer => |info| if (info.size == .slice) {
            try std.testing.expectEqual(a.len, b.len);
            try std.testing.expectEqual(@intFromPtr(a.ptr), @intFromPtr(b.ptr));
            try std.testing.expectEqualSlices(info.child, a, b);
        } else try std.testing.expectEqual(a, b),
        else => try std.testing.expectEqual(a, b),
    }
}
fn check(name: []const u8, value: []const u8) !void {
    const attribute = m.MarkupAttr{ .name = name, .value = value, .line = 3, .column = 7 };
    try identical(m.parseAttrExpression(value), m.parseAttrExpressionWithPolicy(owned, value));
    try identical(m.classifyAttrValue(name, value), m.attrTypedWithPolicy(owned, attribute));
}
test "compiled markup classification preserves raw and event grammars with exact borrowed spans" {
    _ = core.initialModel();
    channels = @splat(0);
    for ([_][]const u8{ "", "text", "on-", "on-press", "on-input", "onward", "ON-press" }) |name| {
        for ([_][]const u8{
            "",         "plain",          "{",             "}",         "{}",      "{ }",      "{\t}",        "{\n}",       "{x}",           "{ x }",      "{x.y}",           "{x.}",
            "{a == b}", "{ a  ==  b.c }", "{a == b == c}", "{a === b}", "{1 + 2}", "{'x'}",    "{unknown()}", "tick",       "tick:{row.id}", "tick:{}",    "tick:{ row.id }", "tick:{row.id}:extra",
            "tick:",    "tick::{}",       "a.b",           "_x",        "0x",      " leading", "\x00\xff",    "{\x00\xff}", "\xc3\xa9",      "{\xc3\xa9}",
        }) |value| try check(name, value);
    }
    // Every short sequence of grammar boundary bytes exercises malformed
    // prefixes/suffixes and first-equality selection without parsing a tree.
    const alphabet = "{} :.=a0\t";
    var bytes: [4]u8 = undefined;
    for (0..alphabet.len * alphabet.len * alphabet.len) |n| {
        bytes[0] = '{';
        bytes[1] = alphabet[n % alphabet.len];
        bytes[2] = alphabet[(n / alphabet.len) % alphabet.len];
        bytes[3] = alphabet[n / (alphabet.len * alphabet.len)];
        for (1..5) |len| {
            try check("value", bytes[0..len]);
            try check("on-press", bytes[0..len]);
        }
    }
    try std.testing.expect(channels[1] > 0 and channels[2] > 0 and channels[0] == 0);
}
test "compiled markup classification preserves every explicit cached union payload without invoking a program" {
    _ = core.initialModel();
    var tree: m.expr.ExprTree = .{};
    const cache = [_]m.TypedAttrValue{
        .{ .literal = "cached\x00\xff" },
        .{ .binding = "cached.path" },
        .{ .equals = .{ .left = "left", .right = "right" } },
        .{ .expression = .{ .inner = "cached + 1", .tree = &tree } },
        .{ .message = .{ .tag = "tick", .payload = "cached.payload" } },
        .invalid,
    };
    channels = @splat(0);
    for (&cache) |*typed| for ([_][]const u8{ "value", "on-press" }) |name| {
        const attribute = m.MarkupAttr{ .name = name, .value = "{ malformed raw", .typed = typed, .line = 1, .column = 1 };
        try identical(m.attrTyped(attribute), m.attrTypedWithPolicy(owned, attribute));
    };
    try std.testing.expectEqual([_]usize{ 0, 0, 0 }, channels);
}
