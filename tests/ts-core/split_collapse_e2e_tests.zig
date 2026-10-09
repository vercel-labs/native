const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("split_core");
const decoder = @import("split_decoder");
const reference = @import("split-collapse-reference/main.zig");
const parity = @import("effects_media_parity.zig");
const testing = std.testing;
const canvas = sdk.canvas;
const Host = sdk.TsCoreHost(core);

test {
    _ = @import("split-collapse-reference/tests.zig");
}

fn clock(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn traceCommand(cmd: []const u8, at: *usize, expected: []const u8) !void {
    try testing.expectEqual(@as(u8, 4), cmd[at.*]);
    at.* += 1;
    const name_len = cmd[at.*];
    at.* += 1;
    try testing.expectEqualStrings("native-sdk.debug.log", cmd[at.*..][0..name_len]);
    at.* += name_len;
    const length = std.mem.readInt(u32, cmd[at.*..][0..4], .little);
    at.* += 4;
    try testing.expectEqualStrings(expected, cmd[at.*..][0..length]);
    at.* += length;
}

test "Split Collapse exact frame channel and complete cadence bytes survive ABI collection" {
    const Adapter = sdk.TsUiApp(core);
    const options = Adapter.mobileOptions(.{}, .{ .name = "split-collapse", .scene = reference.shell_scene, .canvas_label = reference.canvas_label });
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    Host.init(&fx);
    Host.dispatch(&fx, .{ .configure_manual = "1" });
    Host.dispatch(&fx, .toggle);
    var previous: u64 = 0;
    for ([_]u64{ 9_007_199_254_740_993, 9_007_199_254_740_994, 9_007_199_344_740_993, std.math.maxInt(u64) }) |timestamp| {
        const before = core.snapshotModel();
        const fraction = before.fraction;
        const next_count = before.tween_frame_count + 1;
        const message = options.on_frame.?(before, .{ .size = .init(800, 520), .timestamp_ns = timestamp, .frame_interval_ns = std.math.maxInt(u64) }).?;
        var decimal: [20]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&decimal, "{d}", .{timestamp}), message.frame_tick);
        const result = core.update(before, message);
        var log: [128]u8 = undefined;
        const expected = if (previous == 0)
            try std.fmt.bufPrint(&log, "tween-frame dt_ms=start fraction={d:.3}\n", .{fraction})
        else
            try std.fmt.bufPrint(&log, "tween-frame dt_ms={d:.1} fraction={d:.3}\n", .{ @as(f64, @floatFromInt(timestamp -| previous)) / 1_000_000, fraction });
        var at: usize = 0;
        try traceCommand(result.cmd, &at, expected);
        if (result.model.tween == null) {
            try traceCommand(result.cmd, &at, try std.fmt.bufPrint(&log, "tween-done frames={d}\n", .{next_count}));
        }
        try testing.expectEqual(at, result.cmd.len);
        try testing.expectEqual(timestamp, clock(result.model.last_frame_ns));
        core.rt.frameReset();
        try testing.expectEqual(timestamp, clock(core.snapshotModel().last_frame_ns));
        previous = timestamp;
    }
    try testing.expect(options.on_frame.?(core.snapshotModel(), .{ .timestamp_ns = 1 }) == null);
}

test "native timer rejects nanosecond conversion overflow with one complete terminal" {
    var fx = reference.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.startTimer(.{ .key = 17, .interval_ms = std.math.maxInt(u64) / std.time.ns_per_ms + 1, .mode = .repeating, .on_fire = reference.Effects.timerMsg(.auto_toggle) });
    try testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
    const terminal = fx.takeMsg().?.auto_toggle;
    try testing.expectEqual(@as(u64, 17), terminal.key);
    try testing.expectEqual(@as(u64, 0), terminal.timestamp_ns);
    try testing.expectEqual(sdk.EffectTimerOutcome.rejected, terminal.outcome);
    try testing.expect(fx.takeMsg() == null);
    fx.startTimer(.{ .key = 18, .interval_ms = std.math.maxInt(u64) / std.time.ns_per_ms, .mode = .repeating, .on_fire = reference.Effects.timerMsg(.auto_toggle) });
    try testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    try testing.expectEqual(std.math.maxInt(u64) / std.time.ns_per_ms, fx.pendingTimerAt(0).?.interval_ms);
}
fn compare(expected: *const reference.Model) !void {
    const actual = Host.model();
    try testing.expectEqual(expected.collapsed, actual.collapsed);
    try testing.expectEqual(@as(f64, expected.fraction), actual.fraction);
    try testing.expectEqual(expected.tween != null, actual.tween != null);
    if (expected.tween) |tween| {
        try testing.expectEqual(@as(f64, tween.from), actual.tween.?.from);
        try testing.expectEqual(@as(f64, tween.to), actual.tween.?.to);
        try testing.expectEqual(tween.start_ns, clock(actual.tween.?.start_ns));
    }
    try testing.expectEqual(@as(i64, expected.tween_frame_count), actual.tween_frame_count);
    try testing.expectEqual(expected.last_frame_ns, clock(actual.last_frame_ns));
    try testing.expectEqual(expected.manual_mode, actual.manual_mode());
    try testing.expectEqualStrings(@tagName(expected.appearance.color_scheme), @tagName(actual.color_scheme));
    try testing.expectEqual(expected.appearance.reduce_motion, actual.reduce_motion);
    try testing.expectEqual(expected.appearance.high_contrast, actual.high_contrast);
    try testing.expectEqual(@as(f64, expected.pane_fraction()), actual.pane_fraction());
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected.toggle_label(), actual.toggle_label(arena.allocator()));
    try testing.expectEqualStrings(expected.content_hint(), actual.content_hint(arena.allocator()));
    core.rt.frameReset();
}

fn viewParity(expected: *const reference.Model, markup: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var before_ui = reference.Ui.init(arena.allocator());
    const before = try before_ui.finalize(if (markup) reference.CompiledSplitView.build(&before_ui, expected) else reference.rootView(&before_ui, expected));
    const Ui = canvas.Ui(core.Msg);
    var after_ui = Ui.init(arena.allocator());
    const after = try after_ui.finalize(decoder.build(&after_ui, Host.model()));
    core.rt.frameReset();
    try parity.equal(before.root, after.root);
    try testing.expectEqual(before.handlers.len, after.handlers.len);
    for (before.handlers, after.handlers) |a, b| try testing.expectEqual(a.id, b.id);
    var left: [128]canvas.WidgetLayoutNode = undefined;
    var right: [128]canvas.WidgetLayoutNode = undefined;
    for ([_]sdk.geometry.RectF{ .init(0, 0, 800, 520), .init(0, 0, 640, 480), .init(0, 0, 1200, 700) }) |frame|
        try parity.equal(try canvas.layoutWidgetTree(before.root, frame, &left), try canvas.layoutWidgetTree(after.root, frame, &right));
}

test "Split Collapse retains complete model and widget parity in all three modes" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    for (0..3) |mode| {
        Host.init(&fx);
        Host.dispatch(&fx, .{ .configure_manual = if (mode == 1) "1" else "0" });
        Host.dispatch(&fx, .{ .configure_markup = if (mode == 2) "1" else "0" });
        var native = reference.initModel(mode == 1);
        try compare(&native);
        try viewParity(&native, mode == 2);
        reference.update(&native, .toggle);
        Host.dispatch(&fx, .toggle);
        try compare(&native);
        try viewParity(&native, mode == 2);
        reference.update(&native, .{ .split_resized = 0.21 });
        Host.dispatch(&fx, .{ .split_resized = 0.21 });
        try compare(&native);
        if (mode == 1) {
            for ([_]u64{ 0, 9_007_199_254_740_993, 9_007_199_254_740_992, 9_007_199_254_740_994, 9_007_199_294_740_993, 9_007_199_344_740_993, 9_007_199_434_740_993 }) |ns| {
                var decimal: [20]u8 = undefined;
                reference.update(&native, .{ .frame_tick = ns });
                Host.dispatch(&fx, .{ .frame_tick = try std.fmt.bufPrint(&decimal, "{d}", .{ns}) });
                try compare(&native);
                try viewParity(&native, false);
            }
        }
        reference.update(&native, .{ .set_appearance = .{ .color_scheme = .dark, .reduce_motion = true, .high_contrast = true } });
        Host.dispatch(&fx, .{ .set_appearance = .{ .colorScheme = .dark, .reduceMotion = true, .highContrast = true } });
        try compare(&native);
        try viewParity(&native, mode == 2);
    }
}

test "Split Collapse preserves exact endpoint clocks and reversal at every elapsed nanosecond sample" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    for ([_]u64{ 1, 4_294_967_295, 9_007_199_254_740_993, std.math.maxInt(u64) - 180_000_000 }) |start| {
        Host.init(&fx);
        Host.dispatch(&fx, .{ .configure_manual = "" });
        var native = reference.initModel(true);
        reference.update(&native, .toggle);
        Host.dispatch(&fx, .toggle);
        var decimal: [20]u8 = undefined;
        var elapsed: u64 = 0;
        while (elapsed <= 180_000_000) : (elapsed += 1_000_000) {
            reference.update(&native, .{ .frame_tick = start + elapsed });
            Host.dispatch(&fx, .{ .frame_tick = try std.fmt.bufPrint(&decimal, "{d}", .{start + elapsed}) });
            try compare(&native);
            if (elapsed == 90_000_000) {
                reference.update(&native, .toggle);
                Host.dispatch(&fx, .toggle);
                try compare(&native);
            }
        }
    }
}

test "Split Collapse launch parsing keeps signed zero underscores overflow and mode precedence" {
    for ([_][]const u8{ "", "0", "-0", "+0", "1", "00", "0_0", "1__0", "_1", "1_", " 1", "1 ", "-1", "18446744073709551615", "18446744073709551616", "18446744073709", "18446744073710" }) |text| {
        var fx = Host.Fx.init(testing.allocator);
        defer fx.deinit();
        fx.executor = .fake;
        Host.init(&fx);
        Host.dispatch(&fx, .{ .configure_auto = text });
        const expected = std.fmt.parseInt(u64, text, 10) catch 0;
        // Zero/invalid launches arm nothing; valid oversized intervals
        // receive the native timer's explicit overflow rejection.
        const admitted = expected != 0 and expected <= std.math.maxInt(u64) / std.time.ns_per_ms;
        try testing.expectEqual(@as(usize, if (admitted) 1 else 0), fx.pendingTimerCount());
        if (admitted) {
            const timer = fx.pendingTimerAt(0).?;
            try testing.expectEqual(expected, timer.interval_ms);
            try testing.expectEqual(sdk.TimerMode.repeating, timer.mode);
        }
    }
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    Host.init(&fx);
    Host.dispatch(&fx, .{ .configure_manual = "1" });
    Host.dispatch(&fx, .{ .configure_markup = "1" });
    try testing.expect(!Host.model().manual_mode());
}
