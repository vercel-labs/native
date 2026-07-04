//! Chart widget tests: deterministic downsampling, domain derivation,
//! command emission per series kind, path-budget compliance at 10k
//! points, and light/dark reference-render goldens (pixel-hash
//! signatures over the deterministic CPU renderer).

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const chart_model = @import("chart.zig");

const Widget = canvas.Widget;
const WidgetKind = canvas.WidgetKind;
const CanvasCommand = canvas.CanvasCommand;
const Builder = canvas.Builder;
const DisplayList = canvas.DisplayList;
const RenderCommand = support.RenderCommand;
const ReferenceRenderSurface = support.ReferenceRenderSurface;
const DesignTokens = support.DesignTokens;
const Color = support.Color;
const emitWidgetTree = support.emitWidgetTree;
const testing = std.testing;

// ------------------------------------------------------------ downsampling

test "downsampling passes short series through verbatim" {
    const values = [_]f32{ 0.1, 0.9, 0.4 };
    var output: [chart_model.max_chart_points_per_series]f32 = undefined;
    const result = chart_model.downsampleChartValues(&values, &output);
    try testing.expectEqualSlices(f32, &values, result);

    // Exactly at the cap stays verbatim too.
    var at_cap: [chart_model.max_chart_points_per_series]f32 = undefined;
    for (&at_cap, 0..) |*value, index| value.* = @floatFromInt(index);
    const capped = chart_model.downsampleChartValues(&at_cap, &output);
    try testing.expectEqualSlices(f32, &at_cap, capped);
}

test "downsampling a 10k-point series is deterministic and preserves spikes" {
    var values: [10_000]f32 = undefined;
    var state: u64 = 0x5eed;
    for (&values, 0..) |*value, index| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        value.* = @as(f32, @floatFromInt(state >> 40)) / 16777216.0 + @as(f32, @floatFromInt(index)) * 0.0001;
    }
    // A spike the decimation must not flatten.
    values[7_777] = 100;
    values[3_333] = -100;

    var first: [chart_model.max_chart_points_per_series]f32 = undefined;
    var second: [chart_model.max_chart_points_per_series]f32 = undefined;
    const a = chart_model.downsampleChartValues(&values, &first);
    const b = chart_model.downsampleChartValues(&values, &second);
    try testing.expectEqual(chart_model.max_chart_points_per_series, a.len);
    try testing.expectEqualSlices(f32, a, b);

    var has_high = false;
    var has_low = false;
    for (a) |value| {
        if (value == 100) has_high = true;
        if (value == -100) has_low = true;
    }
    try testing.expect(has_high);
    try testing.expect(has_low);
}

test "downsampling emits bucket extremes in index order" {
    // 512 values, cap 256 -> 128 buckets of 4. Bucket 0 holds
    // {5, 1, 9, 3}: min (1, index 1) before max (9, index 2).
    var values: [512]f32 = undefined;
    @memset(&values, 4);
    values[0] = 5;
    values[1] = 1;
    values[2] = 9;
    values[3] = 3;
    var output: [chart_model.max_chart_points_per_series]f32 = undefined;
    const result = chart_model.downsampleChartValues(&values, &output);
    try testing.expectEqual(@as(f32, 1), result[0]);
    try testing.expectEqual(@as(f32, 9), result[1]);
}

// ----------------------------------------------------------------- domain

test "chart domain derives from data, forces zero for bars, honors overrides" {
    const line_values = [_]f32{ 2, 4, 6 };
    const line_series = [_]canvas.ChartSeries{.{ .kind = .line, .values = &line_values }};
    const line_domain = canvas.chartDomain(.{ .series = &line_series });
    try testing.expectEqual(@as(f32, 2), line_domain.min);
    try testing.expectEqual(@as(f32, 6), line_domain.max);

    // Bars anchor at zero even when every value is positive.
    const bar_series = [_]canvas.ChartSeries{.{ .kind = .bar, .values = &line_values }};
    const bar_domain = canvas.chartDomain(.{ .series = &bar_series });
    try testing.expectEqual(@as(f32, 0), bar_domain.min);
    try testing.expectEqual(@as(f32, 6), bar_domain.max);

    // Explicit bounds win per side.
    const pinned = canvas.chartDomain(.{ .series = &line_series, .y_min = 0, .y_max = 1 });
    try testing.expectEqual(@as(f32, 0), pinned.min);
    try testing.expectEqual(@as(f32, 1), pinned.max);

    // Band lower edges participate.
    const low_values = [_]f32{ -1, 0, 1 };
    const band_series = [_]canvas.ChartSeries{.{ .kind = .band, .values = &line_values, .low = &low_values }};
    const band_domain = canvas.chartDomain(.{ .series = &band_series });
    try testing.expectEqual(@as(f32, -1), band_domain.min);

    // Flat data expands symmetrically; no data defaults to 0..1.
    const flat_values = [_]f32{ 3, 3, 3 };
    const flat_series = [_]canvas.ChartSeries{.{ .values = &flat_values }};
    const flat_domain = canvas.chartDomain(.{ .series = &flat_series });
    try testing.expectEqual(@as(f32, 2.5), flat_domain.min);
    try testing.expectEqual(@as(f32, 3.5), flat_domain.max);
    const empty_domain = canvas.chartDomain(.{});
    try testing.expectEqual(@as(f32, 0), empty_domain.min);
    try testing.expectEqual(@as(f32, 1), empty_domain.max);
}

// --------------------------------------------------------------- emission

fn chartWidget(series: []const canvas.ChartSeries) Widget {
    return .{
        .id = 91,
        .kind = WidgetKind.chart,
        .frame = geometry.RectF.init(0, 0, 120, 40),
        .chart = .{ .series = series },
    };
}

test "line series emit one stroke path through token-colored points" {
    const values = [_]f32{ 0, 1, 0.5, 0.75 };
    const series = [_]canvas.ChartSeries{.{ .kind = .line, .values = &values, .fill = true, .color = .accent }};
    var widget = chartWidget(&series);
    widget.chart.y_min = 0;
    widget.chart.y_max = 1;
    const tokens = DesignTokens{};
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, widget, tokens);
    const display_list = builder.displayList();
    // Fill polygon + polyline stroke.
    try testing.expectEqual(@as(usize, 2), display_list.commandCount());
    var stroke_count: usize = 0;
    var fill_count: usize = 0;
    for (display_list.commands) |command| {
        switch (command) {
            .stroke_path => |stroke| {
                stroke_count += 1;
                try testing.expectEqual(values.len, stroke.elements.len);
                try support.expectFillColor(tokens.colors.accent, stroke.stroke.fill);
            },
            .fill_path => |fill| {
                fill_count += 1;
                // Polyline + two baseline corners + close.
                try testing.expectEqual(values.len + 3, fill.elements.len);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(@as(usize, 1), stroke_count);
    try testing.expectEqual(@as(usize, 1), fill_count);
}

test "bar series emit one snapped rect per value from a zero baseline" {
    const values = [_]f32{ 0.25, 0.5, 0, 1 };
    const series = [_]canvas.ChartSeries{.{ .kind = .bar, .values = &values }};
    const widget = chartWidget(&series);
    const tokens = DesignTokens{};
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, widget, tokens);
    const display_list = builder.displayList();
    // Zero draws nothing (zero looks like zero): 3 bars, not 4.
    try testing.expectEqual(@as(usize, 3), display_list.commandCount());
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |bar| {
                try support.expectFillColor(tokens.colors.accent, bar.fill);
                // Bars sit on the plot floor (baseline zero).
                try testing.expectEqual(@as(f32, 40), bar.rect.maxY());
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "band series emit one closed envelope fill" {
    const values = [_]f32{ 3, 4, 5 };
    const low_values = [_]f32{ 1, 2, 3 };
    const series = [_]canvas.ChartSeries{.{ .kind = .band, .values = &values, .low = &low_values }};
    const widget = chartWidget(&series);
    const tokens = DesignTokens{};
    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, widget, tokens);
    const display_list = builder.displayList();
    try testing.expectEqual(@as(usize, 1), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_path => |fill| {
            // Upper polyline + reversed lower edge + close.
            try testing.expectEqual(values.len + low_values.len + 1, fill.elements.len);
            try testing.expectEqual(canvas.PathVerb.close, fill.elements[fill.elements.len - 1].verb);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "empty, single-point, and non-finite series degrade instead of erroring" {
    const tokens = DesignTokens{};

    // Empty series: zero commands, no error.
    const empty_series = [_]canvas.ChartSeries{.{ .kind = .line, .values = &.{} }};
    var empty_commands: [4]CanvasCommand = undefined;
    var empty_builder = Builder.init(&empty_commands);
    try emitWidgetTree(&empty_builder, chartWidget(&empty_series), tokens);
    try testing.expectEqual(@as(usize, 0), empty_builder.displayList().commandCount());

    // A single sample has no line: a dot renders instead.
    const single = [_]f32{0.5};
    const single_series = [_]canvas.ChartSeries{.{ .kind = .line, .values = &single }};
    var single_commands: [4]CanvasCommand = undefined;
    var single_builder = Builder.init(&single_commands);
    try emitWidgetTree(&single_builder, chartWidget(&single_series), tokens);
    const single_list = single_builder.displayList();
    try testing.expectEqual(@as(usize, 1), single_list.commandCount());
    try testing.expect(single_list.commands[0] == .fill_rounded_rect);

    // Non-finite values are skipped, finite neighbors still draw.
    const mixed = [_]f32{ 0.2, std.math.nan(f32), 0.8, std.math.inf(f32), 0.4 };
    const mixed_series = [_]canvas.ChartSeries{.{ .kind = .line, .values = &mixed }};
    var mixed_commands: [4]CanvasCommand = undefined;
    var mixed_builder = Builder.init(&mixed_commands);
    try emitWidgetTree(&mixed_builder, chartWidget(&mixed_series), tokens);
    const mixed_list = mixed_builder.displayList();
    try testing.expectEqual(@as(usize, 1), mixed_list.commandCount());
    switch (mixed_list.commands[0]) {
        .stroke_path => |stroke| try testing.expectEqual(@as(usize, 3), stroke.elements.len),
        else => return error.TestUnexpectedResult,
    }

    // An all-NaN series draws nothing.
    const all_nan = [_]f32{ std.math.nan(f32), std.math.nan(f32) };
    const nan_series = [_]canvas.ChartSeries{.{ .kind = .line, .values = &all_nan }};
    var nan_commands: [4]CanvasCommand = undefined;
    var nan_builder = Builder.init(&nan_commands);
    try emitWidgetTree(&nan_builder, chartWidget(&nan_series), tokens);
    try testing.expectEqual(@as(usize, 0), nan_builder.displayList().commandCount());
}

test "gridlines and baseline draw as token hairlines" {
    const values = [_]f32{ -1, 1 };
    const series = [_]canvas.ChartSeries{.{ .kind = .line, .values = &values }};
    var widget = chartWidget(&series);
    widget.chart.grid_lines = 3;
    widget.chart.baseline = true;
    const tokens = DesignTokens{};
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, widget, tokens);
    const display_list = builder.displayList();
    // 3 gridlines + baseline + polyline stroke.
    try testing.expectEqual(@as(usize, 5), display_list.commandCount());
    var hairlines: usize = 0;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rect => |line| {
                hairlines += 1;
                try support.expectFillColor(tokens.colors.border, line.fill);
            },
            .stroke_path => {},
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(@as(usize, 4), hairlines);
}

// ------------------------------------------------------------ path budget

test "a downsampled 10k-point multi-series chart renders within the frame path budget" {
    var raw: [10_000]f32 = undefined;
    for (&raw, 0..) |*value, index| value.* = @sin(@as(f32, @floatFromInt(index)) * 0.01);

    // Downsample the way Ui.chart does, then emit three filled line
    // series — the star-history shape — and count every path element the
    // frame references.
    var storage: [3][chart_model.max_chart_points_per_series]f32 = undefined;
    var series: [3]canvas.ChartSeries = undefined;
    for (&series, 0..) |*entry, index| {
        const points = chart_model.downsampleChartValues(&raw, &storage[index]);
        try testing.expectEqual(chart_model.max_chart_points_per_series, points.len);
        entry.* = .{ .kind = .line, .values = points, .fill = true };
    }
    const widget = Widget{
        .id = 92,
        .kind = WidgetKind.chart,
        .frame = geometry.RectF.init(0, 0, 640, 240),
        .chart = .{ .series = &series },
    };
    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, widget, DesignTokens{});
    var total_elements: usize = 0;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .stroke_path => |stroke| total_elements += stroke.elements.len,
            .fill_path => |fill| total_elements += fill.elements.len,
            else => {},
        }
    }
    try testing.expect(total_elements > 0);
    try testing.expect(total_elements <= chart_model.max_chart_path_elements_per_frame);
}

// ----------------------------------------------------------------- golden

const golden_width = 240;
const golden_height = 80;

/// Three tiles — line+fill, bars, band — in one deterministic frame.
fn goldenChartRoot() Widget {
    const line_values = comptime blk: {
        var values: [60]f32 = undefined;
        for (&values, 0..) |*value, index| {
            const i: f32 = @floatFromInt(index);
            value.* = 0.5 + 0.4 * @sin(i * 0.22) + 0.002 * i;
        }
        break :blk values;
    };
    const bar_values = comptime blk: {
        var values: [24]f32 = undefined;
        for (&values, 0..) |*value, index| {
            const i: f32 = @floatFromInt(index);
            value.* = @mod(i * 0.37, 1.0);
        }
        break :blk values;
    };
    const band_high = comptime blk: {
        var values: [40]f32 = undefined;
        for (&values, 0..) |*value, index| {
            const i: f32 = @floatFromInt(index);
            value.* = 0.7 + 0.2 * @sin(i * 0.3);
        }
        break :blk values;
    };
    const band_low = comptime blk: {
        var values: [40]f32 = undefined;
        for (&values, 0..) |*value, index| {
            const i: f32 = @floatFromInt(index);
            value.* = 0.3 + 0.15 * @sin(i * 0.3 + 1.0);
        }
        break :blk values;
    };
    const children = comptime [_]Widget{
        .{
            .id = 101,
            .kind = WidgetKind.chart,
            .frame = geometry.RectF.init(4, 4, 72, 72),
            .chart = .{
                .series = &.{.{ .kind = .line, .values = &line_values, .fill = true, .color = .accent }},
                .y_min = 0,
                .y_max = 1,
                .grid_lines = 2,
            },
        },
        .{
            .id = 102,
            .kind = WidgetKind.chart,
            .frame = geometry.RectF.init(84, 4, 72, 72),
            .chart = .{
                .series = &.{.{ .kind = .bar, .values = &bar_values, .color = .success }},
                .y_min = 0,
                .y_max = 1,
                .baseline = true,
            },
        },
        .{
            .id = 103,
            .kind = WidgetKind.chart,
            .frame = geometry.RectF.init(164, 4, 72, 72),
            .chart = .{
                .series = &.{.{ .kind = .band, .values = &band_high, .low = &band_low, .color = .info }},
                .y_min = 0,
                .y_max = 1,
            },
        },
    };
    return .{
        .id = 100,
        .kind = WidgetKind.stack,
        .frame = geometry.RectF.init(0, 0, golden_width, golden_height),
        .children = &children,
    };
}

fn renderGoldenCharts(tokens: DesignTokens, pixels: []u8) !void {
    var commands: [64]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, goldenChartRoot(), tokens);
    var render_commands: [64]RenderCommand = undefined;
    const plan = try (DisplayList{ .commands = builder.displayList().commands }).renderPlan(&render_commands);
    @memset(pixels, 0);
    const surface = try ReferenceRenderSurface.init(golden_width, golden_height, pixels);
    try surface.renderPass(.{
        .commands = plan.commands,
        .surface_size = geometry.SizeF.init(golden_width, golden_height),
        .full_repaint = true,
    }, tokens.colors.background);
}

test "chart golden: line + bar + band render byte-identically in light and dark" {
    var pixels: [golden_width * golden_height * 4]u8 = undefined;

    const light = DesignTokens.theme(.{ .color_scheme = .light });
    try renderGoldenCharts(light, &pixels);
    // Sanity beyond the hash: the corner clears with the theme
    // background, and chart ink exists.
    const surface = try ReferenceRenderSurface.init(golden_width, golden_height, &pixels);
    const background = colorRgba8(light.colors.background);
    try support.expectPixelRgba8(background, surface, golden_width - 1, golden_height - 1);
    var ink: usize = 0;
    var index: usize = 0;
    while (index < pixels.len) : (index += 4) {
        if (pixels[index] != background[0] or pixels[index + 1] != background[1]) ink += 1;
    }
    try testing.expect(ink > 300);
    const light_signature = support.referenceSurfaceSignature(&pixels);
    try renderGoldenCharts(light, &pixels);
    try testing.expectEqual(light_signature, support.referenceSurfaceSignature(&pixels));

    // Review artifacts for deliberate golden updates: set
    // CHART_GOLDEN_DUMP=1 to write both themes as PNGs into
    // /tmp/chart-shots/ before pinning new signatures.
    if (std.c.getenv("CHART_GOLDEN_DUMP") != null) {
        try dumpGoldenPng("/tmp/chart-shots/golden-light.png", &pixels);
    }

    const dark = DesignTokens.theme(.{ .color_scheme = .dark });
    try renderGoldenCharts(dark, &pixels);
    const dark_signature = support.referenceSurfaceSignature(&pixels);
    try testing.expect(light_signature != dark_signature);
    if (std.c.getenv("CHART_GOLDEN_DUMP") != null) {
        try dumpGoldenPng("/tmp/chart-shots/golden-dark.png", &pixels);
    }

    // Pinned goldens: update deliberately when chart rendering changes,
    // reviewing the rendered pixels first (see reference_tests.zig
    // conventions).
    try testing.expectEqual(@as(u64, golden_light_signature), light_signature);
    try testing.expectEqual(@as(u64, golden_dark_signature), dark_signature);
}

// Pinned after pixel review of the CHART_GOLDEN_DUMP artifacts (line +
// area fill + gridlines in accent, zero-baseline bars in success, band
// envelope in info; both themes clear with their background token).
// Regenerated for the shadcn default palette: the accent series is now
// the blue-violet primary and the gridline/border neutrals moved to the
// neutral scale; geometry is unchanged.
const golden_light_signature: u64 = 8077067691017829510;
const golden_dark_signature: u64 = 6697849663957189366;

fn dumpGoldenPng(path: []const u8, pixels: []const u8) !void {
    const io = testing.io;
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse ".") catch {};
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try canvas.png.writeRgba8(&writer.interface, golden_width, golden_height, pixels);
    try writer.interface.flush();
}

fn colorRgba8(color: Color) [4]u8 {
    return .{
        @intFromFloat(@round(std.math.clamp(color.r, 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(color.g, 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(color.b, 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(color.a, 0, 1) * 255)),
    };
}
