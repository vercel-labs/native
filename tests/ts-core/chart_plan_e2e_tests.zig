//! Complete chart drawing, interaction and copied continuations against native.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const exact = @import("component_construction_e2e_tests.zig").exact;
const Observation = struct { font: c.FontId, size: u32, length: usize, hash: u64 };
const Trace = struct { count: usize = 0, entries: [1024]Observation = undefined };
fn measured(context: ?*anyopaque, font: c.FontId, size: f32, bytes: []const u8) f32 {
    const t: *Trace = @ptrCast(@alignCast(context.?));
    std.debug.assert(t.count < t.entries.len);
    t.entries[t.count] = .{ .font = font, .size = @bitCast(size), .length = bytes.len, .hash = std.hash.Wyhash.hash(0, bytes) };
    t.count += 1;
    return @as(f32, @floatFromInt(bytes.len)) * size * 0.45;
}
fn compare(widget: c.Widget, tokens: c.DesignTokens, capacity: usize, retained: bool, hover: bool, path_used: usize, label_used: usize) !void {
    var trace: Trace = .{};
    const provider: c.TextMeasureProvider = .{ .context = &trace, .measure_fn = measured };
    var reference = tokens;
    reference.text_measure = &provider;
    var compiled = reference;
    compiled.control_command_policy = core.nativeWindowPolicy;
    var as: [1024]c.CanvasCommand = undefined;
    var bs: [1024]c.CanvasCommand = undefined;
    var a = c.Builder.init(as[0..capacity]);
    var b = c.Builder.init(bs[0..capacity]);
    a.path_element_len = path_used;
    b.path_element_len = path_used;
    a.label_byte_len = label_used;
    b.label_byte_len = label_used;
    const nodes = [_]c.WidgetLayoutNode{.{ .widget = widget, .frame = widget.frame, .depth = 0 }};
    const tree: c.WidgetLayoutTree = .{ .nodes = &nodes, .root_bounds = .init(-20, -10, 400, 250) };
    const state: c.WidgetRenderState = if (hover) .{ .hovered_id = widget.id, .hover_point = .init(150.25, 60.5) } else .{};
    c.bumpTextMeasureGeneration();
    const ae: ?anyerror = if (retained) blk: {
        tree.emitDisplayListWithState(&a, reference, state) catch |err| break :blk err;
        break :blk null;
    } else blk: {
        c.emitWidgetTree(&a, widget, reference) catch |err| break :blk err;
        break :blk null;
    };
    const expected_count = trace.count;
    const expected_entries = trace.entries;
    trace.count = 0;
    c.bumpTextMeasureGeneration();
    const be: ?anyerror = if (retained) blk: {
        tree.emitDisplayListWithState(&b, compiled, state) catch |err| break :blk err;
        break :blk null;
    } else blk: {
        c.emitWidgetTree(&b, widget, compiled) catch |err| break :blk err;
        break :blk null;
    };
    try std.testing.expectEqual(ae, be);
    try std.testing.expectEqual(expected_count, trace.count);
    try exact(expected_entries[0..expected_count], trace.entries[0..trace.count]);
    try std.testing.expectEqual(a.path_element_len, b.path_element_len);
    try std.testing.expectEqual(a.label_byte_len, b.label_byte_len);
    try exact(a.displayList().commands, b.displayList().commands);
    core.rt.frameReset();
    try exact(a.displayList().commands, b.displayList().commands);
    if (hover) {
        c.bumpTextMeasureGeneration();
        const expected = tree.renderStateDirtyBoundsWithTokens(.{}, state, reference);
        c.bumpTextMeasureGeneration();
        try exact(expected, tree.renderStateDirtyBoundsWithTokens(.{}, state, compiled));
    }
}
fn chart(series: []const c.ChartSeries, flags: usize) c.Widget {
    return .{ .id = 0xfedcba9876543210, .kind = .chart, .frame = .init(3.125, 7.5, 273.25, 137.75), .chart = .{
        .series = series,
        .baseline = flags & 1 != 0,
        .y_labels = flags & 2 != 0,
        .hover_details = flags & 4 != 0,
        .grid_lines = if (flags & 8 != 0) 7 else 0,
        .x_labels = if (flags & 16 != 0) &.{ "oldest", "", "Caf\xc3\xa9\xff\x00", "newest longer label" } else &.{},
    }, .layout = .{ .padding = .{ .top = 2.25, .left = 3.125, .right = 4.5, .bottom = 5.75 } } };
}
test "compiled widget metric charts preserve complete line bar area band commands and measurement order" {
    _ = core.initialModel();
    for (std.enums.values(c.ChartSeriesKind)) |kind| for (0..32) |flags| for ([_]bool{ false, true }) |retained| {
        const series = [_]c.ChartSeries{ .{ .kind = kind, .values = &.{ -2.25, 4.5, 0, 1.125 }, .low = &.{ -3.5, -0.0, 0.5 }, .fill = true, .label = "Primary\xff\x00", .color = .accent }, .{ .kind = .line, .values = &.{2.5}, .color = .text_muted }, .{ .kind = .bar, .values = &.{} } };
        var t = c.DesignTokens.theme(.{ .pack = if (flags & 1 != 0) .house else .geist });
        t.pixel_snap = .{ .geometry = flags & 8 != 0, .text = flags & 8 != 0, .scale = 1.25 };
        t.colors.accent = c.Color.rgba(-0.0, 0.25, 0.75, 0.625);
        compare(chart(&series, flags), t, 1024, retained, flags & 4 != 0, 0, 0) catch |err| {
            std.debug.print("chart kind {t} flags {d} retained {}\n", .{ kind, flags, retained });
            return err;
        };
    };
}
test "compiled widget metric charts preserve every command path and label failure prefix" {
    _ = core.initialModel();
    const series = [_]c.ChartSeries{ .{ .kind = .line, .values = &.{ 1, 2, 3, 4 }, .fill = true, .label = "line" }, .{ .kind = .band, .values = &.{ 3, 4, 3, 4 }, .low = &.{ 1, 2, 1, 2 } }, .{ .kind = .bar, .values = &.{ -1, 0, 1, 2 } } };
    const widget = chart(&series, 31);
    for (0..60) |capacity| try compare(widget, .{}, capacity, true, true, 0, 0);
    for (0..20) |remaining| try compare(widget, .{}, 1024, true, true, c.max_chart_path_elements_per_frame - remaining, 0);
    for (0..64) |remaining| try compare(widget, .{}, 1024, true, true, 0, c.max_chart_label_bytes_per_frame - remaining);
}
test "compiled widget metric charts preserve exceptional samples explicit domains and raw palette words" {
    _ = core.initialModel();
    for ([_]u32{ 0, 0x80000000, 1, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345, 0xff812345 }) |word| for (std.enums.values(c.ChartSeriesKind)) |kind| {
        var value: f32 = @bitCast(word);
        std.mem.doNotOptimizeAway(&value);
        const series = [_]c.ChartSeries{.{ .kind = kind, .values = &.{ value, 1, -0.0, 3 }, .low = &.{ -1, value, 0 }, .fill = true }};
        var widget = chart(&series, 31);
        widget.style.stroke_width = value;
        var t = c.DesignTokens{};
        t.colors.accent = c.Color.rgba(value, -0.0, 0.625, value);
        t.colors.text_muted = c.Color.rgba(-0.0, value, 0.375, value);
        for ([_]bool{ false, true }) |fixed| {
            widget.chart.y_min = if (fixed) value else null;
            widget.chart.y_max = if (fixed) 5.25 else null;
            try compare(widget, t, 1024, true, true, 0, 0);
        }
    };
}
test "compiled widget metric charts preserve plot and hover admission across bounds slots and hidden nodes" {
    _ = core.initialModel();
    var trace: Trace = .{};
    const provider: c.TextMeasureProvider = .{ .context = &trace, .measure_fn = measured };
    for (std.enums.values(c.ChartSeriesKind)) |kind| for ([_]f32{ 0, 10.25, 273.25 }) |width| for (0..32) |flags| {
        const series = [_]c.ChartSeries{.{ .kind = kind, .values = &.{ 0, 1, 2, 3 } }};
        var widget = chart(&series, flags);
        widget.frame.width = width;
        const t: c.DesignTokens = .{ .text_measure = &provider };
        var compiled = t;
        compiled.control_command_policy = core.nativeWindowPolicy;
        trace.count = 0;
        c.bumpTextMeasureGeneration();
        const expected = c.chartWidgetPlotRect(widget, t);
        const count = trace.count;
        const entries = trace.entries;
        trace.count = 0;
        c.bumpTextMeasureGeneration();
        try exact(expected, c.chartWidgetPlotRect(widget, compiled));
        try std.testing.expectEqual(count, trace.count);
        try exact(entries[0..count], trace.entries[0..trace.count]);
        for ([_]f32{ -100, 3.125, 45.5, 150.25, 276.375, 800, std.math.nan(f32), std.math.inf(f32) }) |x| {
            trace.count = 0;
            const a = c.chartWidgetHoverIndex(widget, t, .init(x, 60));
            trace.count = 0;
            try std.testing.expectEqual(a, c.chartWidgetHoverIndex(widget, compiled, .init(x, 60)));
        }
        core.rt.frameReset();
        for ([_]bool{ false, true }) |hidden| {
            widget.semantics.hidden = hidden;
            try compare(widget, .{}, 1024, true, true, 0, 0);
        }
    };
}
test "compiled widget metric chart continuations preserve exact large indices nested calls and caller tails" {
    _ = core.initialModel();
    var t = c.DesignTokens{};
    t.control_command_policy = core.nativeWindowPolicy;
    const widget = chart(&.{.{ .values = &.{ 1, 2, 3 } }}, 31);
    var plan = c.chart_plan_policy.Plan.init(widget, t, .hover_draw, .zero(), .zero(), .{ .index = 16777217, .plot = .init(0, 0, 160, 90), .sample_x = 15, .card = .init(10, 10, 120, 80) });
    defer plan.deinit();
    try std.testing.expectEqual(c.chart_plan_policy.Action.fill_rect, plan.run());
    try std.testing.expectEqual(@as(usize, 16777217), plan.index());
    const saved = try std.testing.allocator.dupe(u8, plan.output[0..plan.length]);
    defer std.testing.allocator.free(saved);
    _ = c.leaf_plan_policy.Program.init(t, .image, 0, .{ .kind = .image }, .{});
    core.rt.frameReset();
    try std.testing.expectEqualSlices(u8, saved, plan.output[0..plan.length]);
    try std.testing.expect(std.mem.allEqual(u8, plan.output[plan.length..], 0xa5));
    while (true) {
        const action = plan.run();
        try std.testing.expectEqual(@as(usize, 16777217), plan.index());
        if (action == .done) break;
        if (action == .measure) plan.reply(12.5);
        core.rt.frameReset();
    }
}

test "compiled widget metric chart lattice preserves production numeric ABI at powers and neighboring float words" {
    _ = core.initialModel();
    var t = c.DesignTokens{};
    t.control_command_policy = core.nativeWindowPolicy;
    var widget = chart(&.{}, 0);
    widget.chart.y_min = 0;
    widget.chart.y_max = 1;
    var plan = c.chart_plan_policy.Plan.init(widget, t, .plot, .zero(), .zero(), null);
    defer plan.deinit();
    var exponent: i32 = -45;
    while (exponent <= 38) : (exponent += 1) {
        const power = std.math.pow(f32, 10, @as(f32, @floatFromInt(exponent)));
        var delta: i32 = -64;
        while (delta <= 64) : (delta += 1) {
            const raw = @as(i64, @as(u32, @bitCast(power))) + delta;
            if (raw <= 0 or raw >= 0x7f800000) continue;
            try compareLattice(&plan, @intCast(raw));
        }
    }
    var rng: u32 = 0x12345678;
    for (0..2000) |_| {
        rng = rng *% 1664525 +% 1013904223;
        try compareLattice(&plan, rng % 0x7f7fffff + 1);
    }
}
fn compareLattice(plan: *c.chart_plan_policy.Plan, raw: u32) !void {
    @memset(plan.bytes[240..416], 0);
    std.mem.writeInt(u32, plan.bytes[116..120], raw, .little);
    const high: f32 = @bitCast(raw);
    const expected = c.chartTickLattice(.{ .min = 0, .max = high }, 1);
    try std.testing.expectEqual(c.chart_plan_policy.Action.done, plan.run());
    exact(expected.start, plan.scalar(72)) catch |err| {
        std.debug.print("chart lattice raw {x} log mode {d}\n", .{ raw, plan.bytes[4] });
        return err;
    };
    try exact(expected.step, plan.scalar(76));
    try exact(@as(f32, @floatFromInt(expected.count)), plan.scalar(80));
    try exact(@as(f32, @floatFromInt(expected.decimals)), plan.scalar(84));
    core.rt.frameReset();
}
