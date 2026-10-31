const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const compiled_commands = sdk.runtime.testing.automation_command_policy;
const reference = sdk.runtime.testing.automation_commands;
const complete = @import("surface_layout_e2e_tests.zig").expectComplete;
var modes: [18][2]usize = @splat(@splat(0));
fn compiled(input: []const u8, output: []u8) usize {
    std.debug.assert(input[0] == 90 and input[2] < 18 and input[3] < 2);
    modes[input[2]][input[3]] += 1;
    return core.nativeWindowPolicy(input, output);
}
fn borrowed(expected: anytype, actual: @TypeOf(expected)) !void {
    switch (@typeInfo(@TypeOf(expected))) {
        .@"struct" => |info| inline for (info.fields) |field| try borrowed(@field(expected, field.name), @field(actual, field.name)),
        .pointer => |info| if (info.size == .slice and info.child == u8) {
            if (expected.len > 0) try std.testing.expectEqual(@intFromPtr(expected.ptr), @intFromPtr(actual.ptr));
            try std.testing.expectEqual(expected.len, actual.len);
        },
        else => {},
    }
}
fn compare(comptime name: []const u8, input: []const u8) !void {
    const actual = @field(compiled_commands, "parseAutomation" ++ name)(compiled, input);
    if (@field(reference, "parseAutomation" ++ name)(input)) |expected| {
        const value = try actual;
        try complete(expected, value);
        try borrowed(expected, value);
    } else |err| try std.testing.expectError(err, actual);
}
const names = .{ "CommandName", "TrayItemId", "TrayTarget", "ViewLabel", "NativeCommand", "WidgetAction", "WidgetTarget", "ProvenanceTarget", "WidgetWheel", "WidgetContextMenuItem", "WidgetKey", "WidgetPinch", "WidgetPointerDrag", "ScreenshotCommand", "TextSelection", "DragDelta", "ResizeCommand" };
const corpus = [_][]const u8{
    "",                         " ",                        "\t\n\r",               "main",                           "main 1",                             "main +1",              "main -0",                  "main 0",             "main 18446744073709551615", "main 18446744073709551616",
    "1",                        "+1",                       "-0",                   "-1",                             "4294967295",                         "4294967296",           "1_000",                    "1 2",                "+1 +2",                     "1 2 3",
    "0 2",                      "1 0",                      "0001",                 "main 1 press",                   " main\t1\nSET-TEXT \xff\x00words\r", "main 1 set_selection", "main 1 set-selection 0 1", "main 1 press extra", "main at 1 2",               "main AT 1 2",
    "main at nan 1",            "main at inf 0",            "main at -0 1e-45",     "main at 0x1p0 -0x1p1",           "main at 1 2 extra",                  "main 1 -0",            "main 1 2",                 "main 1 2 -3",        "main 1 2 nan",              "main 1 2 3 extra",
    "main 1 0.25 0.75",         "main 1 0.25 0.75 0.1 0.9", "main 1 0.25 0.75 0.1", "main 1 0.25 0.75 0.1 0.9 extra", "main 1 1e39 0",                      "main 1 1e-50 -1e-50",  "main 2 1 3",               "main 2",             "main nan",                  "main inf",
    "main -0",                  "main 0",                   "main 1e-50",           "main 0x1p0",                     "main 1 4",                           "main 1 4 5",           "main 1 4 5 extra",         "main cmd+c text",    "main CTRL+SHIFT+ArrowLeft", "main alt+option+super+meta+cmd+a",
    "main cmd+unknown+a words", "main cmd++",               "main cmd+",            "main +",                         "main shift+cmd+ctrl+alt+z",          "main shift+\xff\x00",  "900 640",                  "900 640 2",          "900 640 2 extra",           "900 nan 2",
    "0 640",                    "900 640 -0",               "900 640 1e-50",        "\xff\x00 1 2",                   "a b c d e f g",
};
test "compiled automation commands preserve all native results and exact borrowed spans" {
    _ = core.initialModel();
    inline for (names) |name| for (corpus) |input| try compare(name, input);
    var paths: [8][]const u8 = undefined;
    _ = try compiled_commands.parseAutomationDropPaths(compiled, "a b", &paths);
    for (modes) |phases| {
        try std.testing.expect(phases[0] > 0);
        try std.testing.expect(phases[1] > 0);
    }
}
test "compiled automation commands preserve every action alias and value admission" {
    _ = core.initialModel();
    inline for (std.meta.fields(reference.AutomationWidgetActionKind)) |field| {
        for ([_][]const u8{ "", " x", " 0 1", " \xff\x00" }) |value| {
            var buffer: [160]u8 = undefined;
            const input = try std.fmt.bufPrint(&buffer, "main 1 {s}{s}", .{ field.name, value });
            try compare("WidgetAction", input);
            for (input) |*byte| {
                if (byte.* == '_') byte.* = '-';
                byte.* = std.ascii.toUpper(byte.*);
            }
            try compare("WidgetAction", input);
        }
    }
}
test "compiled automation commands preserve all byte separators without Unicode trimming" {
    _ = core.initialModel();
    for (0..256) |byte| {
        const input = [_]u8{ @intCast(byte), 'm', @intCast(byte), '1', @intCast(byte) };
        inline for (names) |name| try compare(name, &input);
    }
}
test "compiled automation commands preserve numeric lexical boundaries and float32 bits" {
    _ = core.initialModel();
    for ([_][]const u8{ "0", "-0", "+0", "+1", "-1", "1_0", "_1", "1_", "01", "0x10", "1e3", "4294967295", "4294967296", "9007199254740993", "18446744073709551615", "18446744073709551616", "inf", "+inf", "nan", "-nan", "0x1p-149", "0x1p-150", "0x1.fffffep127", "3.4028236e38", "-1e-50", "1e-45" }) |number| {
        var buffer: [256]u8 = undefined;
        inline for (.{ "main {s}", "main 1 {s}", "main {s} 1 2", "main 1 {s} 0", "{s} 1", "900 640 {s}" }) |format| {
            const input = try std.fmt.bufPrint(&buffer, format, .{number});
            inline for (names) |name| try compare(name, input);
        }
    }
}
test "compiled automation commands preserve bounded drop-path writes and borrowed buffers" {
    _ = core.initialModel();
    for (corpus) |input| for (0..9) |capacity| {
        var left: [8][]const u8 = @splat("sentinel");
        var right = left;
        const actual = compiled_commands.parseAutomationDropPaths(compiled, input, right[0..capacity]);
        if (reference.parseAutomationDropPaths(input, left[0..capacity])) |expected| {
            const value = try actual;
            try complete(expected, value);
            for (expected, value) |a, b| try borrowed(a, b);
            try complete(left[capacity..], right[capacity..]);
        } else |err| {
            try std.testing.expectError(err, actual);
            try complete(left, right);
        }
    };
    const input = try std.testing.allocator.alloc(u8, 8193);
    defer std.testing.allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = if (i % 2 == 0) 'x' else ' ';
    var left: [4097][]const u8 = undefined;
    var right: [4097][]const u8 = undefined;
    const expected = try reference.parseAutomationDropPaths(input, &left);
    const value = try compiled_commands.parseAutomationDropPaths(compiled, input, &right);
    try complete(expected, value);
    for (expected, value) |a, b| try borrowed(a, b);
}
test "compiled automation commands refuse failed numeric capabilities without precision loss" {
    _ = core.initialModel();
    const value = try compiled_commands.parseAutomationWidgetTarget(compiled, "main 9007199254740993");
    try std.testing.expectEqual(@as(u64, 9007199254740993), value.id);
    try std.testing.expectError(error.InvalidCommand, compiled_commands.parseAutomationWidgetTarget(compiled, "main 18446744073709551616"));
    for (modes) |phases| {
        try std.testing.expect(phases[0] > 0);
        try std.testing.expect(phases[1] > 0);
    }
}
