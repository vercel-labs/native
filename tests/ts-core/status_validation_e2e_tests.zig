const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const platform = native_sdk.platform;
const admission = native_sdk.runtime.testing.status_validation;
const reference = native_sdk.runtime.testing.native_validation;

fn equal(expected: anyerror!void, actual: anyerror!void) !void {
    const left: ?anyerror = if (expected) |_| null else |err| err;
    const right: ?anyerror = if (actual) |_| null else |err| err;
    try std.testing.expectEqual(left, right);
    core.rt.frameReset();
}
fn menu(items: []const platform.TrayMenuItem) !void {
    try equal(reference.validateTrayMenuItems(items), admission.menu(core.nativeWindowPolicy, items));
}

test "compiled command status field admission preserves all byte bounds and error precedence" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var bytes: [4097]u8 = undefined;
    for ([_]u8{ 0, 'A', '.', '/', 0xff }) |byte| {
        @memset(&bytes, byte);
        for ([_]usize{ 0, 1, 2, 63, 64, 65, 127, 128, 129, 255, 256, 257, 4096, 4097 }) |length| {
            const value = bytes[0..length];
            try equal(reference.validateTrayTitle(value), admission.title(core.nativeWindowPolicy, value));
            const options = [_]platform.TrayOptions{ .{ .icon_path = value }, .{ .title = value }, .{ .presentation = .{ .title = value } }, .{ .tooltip = value }, .{ .activation_command = value }, .{ .alternate_activation_command = value }, .{ .open_command = value } };
            for (options) |option| try equal(reference.validateTrayOptions(option), admission.options(core.nativeWindowPolicy, option));
            const shells = [_]platform.TrayShell{ .{ .icon_path = value }, .{ .tooltip = value }, .{ .activation_command = value }, .{ .alternate_activation_command = value }, .{ .open_command = value } };
            for (shells) |shell| try equal(reference.validateTrayShell(shell), admission.shell(core.nativeWindowPolicy, shell));
        }
    }
    @memset(&bytes, 'A');
    const ordered = [_]platform.TrayOptions{ .{ .activation_command = "a/b", .open_command = bytes[0..129] }, .{ .title = bytes[0..65], .presentation = .{ .width = std.math.nan(f32) } }, .{ .presentation = .{ .width = -1 }, .tooltip = bytes[0..257] }, .{ .activation_command = "a/b", .alternate_activation_command = "\x00" } };
    for (ordered) |option| try equal(reference.validateTrayOptions(option), admission.options(core.nativeWindowPolicy, option));
    for ([_]platform.StatusItemId{ 0, 1, std.math.maxInt(u32) }) |id| try equal(reference.validateStatusItemId(id), admission.identity(core.nativeWindowPolicy, id));
}

test "compiled command status presentation retains finite f32 boundaries and signed zero" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const values = [_]f32{ -std.math.inf(f32), std.math.inf(f32), std.math.nan(f32), -1, -0.0, 0, 0.5, 1, 64, 65, std.math.floatMax(f32), @bitCast(@as(u32, 1)), @bitCast(@as(u32, 0x80000001)) };
    for (values) |value| {
        for ([_]platform.TrayPresentation{ .{ .width = value }, .{ .icon_opacity = value }, .{ .font_size = value }, .{ .title = "\x00", .width = value } }) |presentation| try equal(reference.validateTrayPresentation(presentation), admission.presentation(core.nativeWindowPolicy, presentation));
    }
}

test "compiled command status rich rows preserve every role and raw shortcut admission" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    inline for (@typeInfo(platform.TrayItemRole).@"enum".fields) |role| for ([_]bool{ false, true }) |separator| for ([_]platform.TrayItemId{ 0, 1, std.math.maxInt(u32) }) |id| for ([_][]const u8{ "", "label", "\xff" }) |label| for ([_][]const u8{ "", "app.sync", ".", "a/b" }) |command| for ([_][]const u8{ "", "detail" }) |detail| {
        try menu(&.{.{ .id = id, .label = label, .command = command, .detail = detail, .role = @enumFromInt(role.value), .separator = separator }});
    };
    var byte: [1]u8 = undefined;
    for (0..256) |raw| {
        byte[0] = @intCast(raw);
        for (0..32) |mask| try menu(&.{.{ .id = 1, .label = "Run", .command = "app.run", .key = &byte, .modifiers = modifiers(mask) }});
    }
    for ([_][]const u8{ "escape", "ESCAPE", "Enter", "tab", "space", "backspace", "arrowleft", "ARROWRIGHT", "arrowup", "arrowdown", "delete", "home", "end", "pageup", "pagedown", "insert", "f1", "F12", "f0", "f13", "unknown", "\x00" }) |key| for (0..32) |mask| try menu(&.{.{ .id = 1, .label = "Run", .command = "app.run", .key = key, .modifiers = modifiers(mask) }});
    const large: [257]u8 = @splat('A');
    try menu(&.{.{ .id = 1, .label = "Run", .command = "a/b", .detail = &large }});
    try menu(&.{.{ .id = 1, .label = &large, .command = "\x00" }});
}
fn modifiers(mask: usize) platform.ShortcutModifiers {
    return .{ .primary = mask & 1 != 0, .command = mask & 2 != 0, .control = mask & 4 != 0, .option = mask & 8 != 0, .shift = mask & 16 != 0 };
}

test "compiled command status transport bounds every simultaneous rich payload" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const text: [4096]u8 = @splat('A');
    var choices: [8]platform.TraySegmentOption = undefined;
    for (&choices, 0..) |*option, slot| option.* = .{ .id = @intCast(slot + 1), .label = text[0..64], .command = text[0..128] };
    const values: [32]f32 = @splat(0.5);
    var rows: [32]platform.TrayMenuItem = undefined;
    for (&rows) |*row| row.* = .{
        .label = text[0..256],
        .command = text[0..128],
        .detail = text[0..256],
        .key = text[0..32],
        .segmented = .{ .options = &choices },
        .metric = .{ .primary_text = text[0..256], .secondary_text = text[0..256], .accessibility_label = text[0..128] },
        .chart = .{ .values = &values, .leading_caption = text[0..128], .trailing_summary = text[0..128], .accessibility_label = text[0..128] },
    };
    const options = platform.TrayOptions{
        .icon_path = &text,
        .title = text[0..64],
        .tooltip = text[0..256],
        .presentation = .{ .title = text[0..64] },
        .activation_command = text[0..128],
        .alternate_activation_command = text[0..128],
        .open_command = text[0..128],
        .items = &rows,
    };
    try equal(reference.validateTrayOptions(options), admission.options(core.nativeWindowPolicy, options));
    try menu(&rows);
}

test "compiled command status segments preserve selection duplicate and oversized cross-row ordering" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var options: [9]platform.TraySegmentOption = undefined;
    for (&options, 0..) |*option, slot| option.* = .{ .id = @intCast(slot + 1), .label = "Option", .command = "app.option" };
    for (0..10) |count| {
        const masks: usize = @as(usize, 1) << @intCast(@min(count, 8));
        for (0..masks) |mask| {
            for (&options, 0..) |*option, slot| option.selected = mask & (@as(usize, 1) << @intCast(slot)) != 0;
            try menu(&.{.{ .role = .segmented, .segmented = .{ .options = options[0..count] } }});
        }
    }
    for ([_][]const u8{ "", "\x00", "Option" }) |label| for ([_][]const u8{ "", ".", "a/b", "app.option" }) |command| {
        options[0] = .{ .id = 1, .label = label, .command = command };
        options[1] = .{ .id = 1, .label = "Duplicate", .command = "app.second" };
        try menu(&.{.{ .role = .segmented, .segmented = .{ .options = options[0..2] } }});
    };
    var oversized: [257]platform.TraySegmentOption = undefined;
    for (&oversized, 0..) |*option, slot| option.* = .{ .id = @intCast(slot + 100), .label = "Other", .command = "app.other" };
    const long: [257]u8 = @splat('A');
    var first = [_]platform.TraySegmentOption{ .{ .id = std.math.maxInt(u32), .label = "First", .command = "app.first" }, .{ .id = 2, .label = "Second", .command = "app.second" } };
    for ([_]usize{ 8, 127, 128, 255, 256 }) |duplicate_at| {
        oversized[duplicate_at].id = std.math.maxInt(u32);
        // This future field is too large, but the earlier duplicate must win.
        try menu(&.{ .{ .role = .segmented, .segmented = .{ .options = &first } }, .{ .role = .segmented, .label = &long, .segmented = .{ .options = &oversized } } });
        first[0].label = "\x00";
        try menu(&.{ .{ .role = .segmented, .segmented = .{ .options = &first } }, .{ .role = .segmented, .segmented = .{ .options = &oversized } } });
        first[0].label = "First";
        oversized[duplicate_at].id = @intCast(duplicate_at + 100);
    }
    // Later-option duplication must not preempt an earlier field-length error.
    first[0].label = long[0..65];
    oversized[256].id = 2;
    try menu(&.{ .{ .role = .segmented, .segmented = .{ .options = &first } }, .{ .role = .segmented, .segmented = .{ .options = &oversized } } });
}

test "compiled command status metrics charts and aggregate fallback retain complete constraints" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var values: [33]f32 = @splat(0.5);
    const large: [257]u8 = @splat('A');
    for ([_][]const u8{ "", "Metric", "\x00", &large }) |primary| for ([_][]const u8{ "", "Accessible", "\x00", large[0..129] }) |accessible| try menu(&.{.{ .role = .hero, .metric = .{ .primary_text = primary, .accessibility_label = accessible } }});
    for ([_]usize{ 0, 1, 32, 33 }) |count| for ([_]f32{ -std.math.inf(f32), std.math.nan(f32), -1, -0.0, 0, 0.5, 1, 2, std.math.inf(f32) }) |value| {
        values[0] = value;
        try menu(&.{.{ .role = .chart, .chart = .{ .values = values[0..count], .accessibility_label = "Chart" } }});
    };
    for ([_]f32{ -std.math.inf(f32), std.math.nan(f32), -1, -0.0, 0, 0.5, 1, 2, std.math.inf(f32) }) |low| for ([_]f32{ -std.math.inf(f32), std.math.nan(f32), -1, -0.0, 0, 0.5, 1, 2, std.math.inf(f32) }) |high| {
        try menu(&.{.{ .role = .chart, .chart = .{ .values = &.{0.5}, .min_value = low, .max_value = high, .accessibility_label = "Chart" } }});
    };
    var segments: [4][8]platform.TraySegmentOption = undefined;
    var rows: [33]platform.TrayMenuItem = undefined;
    for (&segments, 0..) |*segment, row| {
        for (segment, 0..) |*option, slot| option.* = .{ .id = @intCast(row * 8 + slot + 1), .label = "Choice", .command = "app.choice" };
        rows[row] = .{ .role = .segmented, .segmented = .{ .options = segment } };
    }
    rows[4] = .{ .label = "Extra" };
    try menu(rows[0..4]);
    try menu(rows[0..5]);
    for (&rows) |*row| row.* = .{ .label = "Readout", .role = .info };
    try menu(rows[0..32]);
    try menu(&rows);
}
