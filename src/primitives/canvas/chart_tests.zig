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

// ------------------------------------------------------- value formatting

test "chart value formatting is deterministic, trimmed, and honest" {
    var buffer: [chart_model.max_chart_value_label_bytes]u8 = undefined;
    // Step-driven decimals: whole steps label whole numbers, fractional
    // steps add exactly the places that keep neighbors distinct.
    try testing.expectEqual(@as(u8, 0), chart_model.chartTickDecimals(25));
    try testing.expectEqual(@as(u8, 1), chart_model.chartTickDecimals(0.25));
    try testing.expectEqual(@as(u8, 2), chart_model.chartTickDecimals(0.025));
    try testing.expectEqual(@as(u8, 3), chart_model.chartTickDecimals(0.0025));
    try testing.expectEqual(@as(u8, 2), chart_model.chartTickDecimals(0));

    try testing.expectEqualStrings("3", chart_model.formatChartValue(&buffer, 3.0, 2));
    try testing.expectEqualStrings("0.5", chart_model.formatChartValue(&buffer, 0.5, 2));
    try testing.expectEqualStrings("0.42", chart_model.formatChartValue(&buffer, 0.42, 2));
    try testing.expectEqualStrings("-1.5", chart_model.formatChartValue(&buffer, -1.5, 1));
    try testing.expectEqualStrings("237", chart_model.formatChartValue(&buffer, 237, 0));
    // A negative rounding remainder never labels as "-0".
    try testing.expectEqualStrings("0", chart_model.formatChartValue(&buffer, -0.001, 1));
    // Non-finite values name themselves instead of posing as data.
    try testing.expectEqualStrings("nan", chart_model.formatChartValue(&buffer, std.math.nan(f32), 2));
    try testing.expectEqualStrings("inf", chart_model.formatChartValue(&buffer, std.math.inf(f32), 2));
    // f32's full range fits the label buffer (the formatter must never
    // fail mid-frame).
    _ = chart_model.formatChartValue(&buffer, -std.math.floatMax(f32), 3);
}

test "the y tick lattice snaps to nice steps so labels are exact" {
    // 0..0.74 with a 4-interval hint: nice step 0.2, ticks 0/0.2/0.4/0.6
    // — every label names its line exactly (no rounding lie).
    const lattice = chart_model.chartTickLattice(.{ .min = 0, .max = 0.74 }, 4);
    try testing.expectEqual(@as(f32, 0.2), lattice.step);
    try testing.expectEqual(@as(usize, 4), lattice.count);
    try testing.expectEqual(@as(u8, 1), lattice.decimals);
    try testing.expectEqual(@as(f32, 0), lattice.value(0));
    try testing.expectEqual(@as(f32, 0.6000000238418579), lattice.value(3));

    // 0..1 with a 2-interval hint: 0, 0.5, 1 — the tick can land on the
    // domain max.
    const unit = chart_model.chartTickLattice(.{ .min = 0, .max = 1 }, 2);
    try testing.expectEqual(@as(f32, 0.5), unit.step);
    try testing.expectEqual(@as(usize, 3), unit.count);

    // A domain that starts off-lattice: 0.13..0.94 hints 3 -> step 0.5?
    // raw 0.27 -> nice 0.5; first tick at 0.5 only. Labels float where
    // their values are, never pinned to the edges.
    const offset = chart_model.chartTickLattice(.{ .min = 0.13, .max = 0.94 }, 3);
    try testing.expectEqual(@as(f32, 0.5), offset.step);
    try testing.expectEqual(@as(usize, 1), offset.count);

    // Large spans label whole numbers.
    const large = chart_model.chartTickLattice(.{ .min = 0, .max = 500 }, 4);
    try testing.expectEqual(@as(f32, 200), large.step);
    try testing.expectEqual(@as(u8, 0), large.decimals);

    // The tick count is bounded: a huge hint cannot turn the axis into
    // a texture.
    const dense = chart_model.chartTickLattice(.{ .min = 0, .max = 1 }, 200);
    try testing.expect(dense.count <= chart_model.max_chart_axis_ticks + 1);
}

// ------------------------------------------------------------------ hover

test "hover snapping inverts the x mapping for lattice and slot charts" {
    const line_values = [_]f32{ 0, 1, 2, 3 };
    const line_data = canvas.ChartData{ .series = &.{.{ .kind = .line, .values = &line_values }} };
    // Lattice: 4 points at fractions 0, 1/3, 2/3, 1 — the midpoint of a
    // segment rounds to its nearer end.
    try testing.expectEqual(@as(?usize, 0), chart_model.chartHoverIndex(line_data, 0));
    try testing.expectEqual(@as(?usize, 1), chart_model.chartHoverIndex(line_data, 0.34));
    try testing.expectEqual(@as(?usize, 3), chart_model.chartHoverIndex(line_data, 1));
    try testing.expectEqual(@as(?usize, 3), chart_model.chartHoverIndex(line_data, 2)); // clamped
    // Bars-only: equal-width slots, hovered index = slot under pointer.
    const bar_data = canvas.ChartData{ .series = &.{.{ .kind = .bar, .values = &line_values }} };
    try testing.expectEqual(@as(?usize, 0), chart_model.chartHoverIndex(bar_data, 0.2));
    try testing.expectEqual(@as(?usize, 1), chart_model.chartHoverIndex(bar_data, 0.3));
    try testing.expectEqual(@as(?usize, 3), chart_model.chartHoverIndex(bar_data, 0.99));
    // Nothing to snap to.
    try testing.expectEqual(@as(?usize, null), chart_model.chartHoverIndex(.{}, 0.5));
    try testing.expectEqual(@as(?usize, null), chart_model.chartHoverIndex(line_data, std.math.nan(f32)));
}

// ------------------------------------------------------------- axis labels

test "axis labels draw muted in reserved gutters and thin to fit" {
    const values = [_]f32{ 0.2, 0.8, 0.4, 0.6, 0.3, 0.7 };
    const labels = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun" };
    var widget = Widget{
        .id = 93,
        .kind = WidgetKind.chart,
        .frame = geometry.RectF.init(0, 0, 240, 120),
        .chart = .{
            .series = &.{.{ .kind = .line, .values = &values }},
            .y_min = 0,
            .y_max = 1,
            .grid_lines = 1,
            .x_labels = &labels,
            .y_labels = true,
        },
    };
    const tokens = DesignTokens{};
    var commands: [32]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, widget, tokens);
    const display_list = builder.displayList();
    // Every label draws muted. The y lattice (0, 0.5, 1: min, gridline,
    // max) and all six month labels appear — 240px fits every "jan"-
    // size label — and y ticks right-align into the left gutter.
    const plot = canvas.chartWidgetPlotRect(widget, tokens);
    var x_label_count: usize = 0;
    var y_label_count: usize = 0;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                try testing.expect(std.meta.eql(tokens.colors.text_muted, text.color));
                var is_month = false;
                for (labels) |label| {
                    if (std.mem.eql(u8, text.text, label)) is_month = true;
                }
                if (is_month) {
                    x_label_count += 1;
                } else {
                    y_label_count += 1;
                    try testing.expect(text.origin.x < plot.x);
                    const on_lattice = std.mem.eql(u8, text.text, "0") or
                        std.mem.eql(u8, text.text, "0.5") or
                        std.mem.eql(u8, text.text, "1");
                    try testing.expect(on_lattice);
                }
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), y_label_count);
    try testing.expectEqual(@as(usize, 6), x_label_count);

    // A narrow plot thins deterministically: every Nth label, never a
    // collision, at least one drawn.
    widget.frame = geometry.RectF.init(0, 0, 80, 120);
    var narrow_commands: [32]CanvasCommand = undefined;
    var narrow_builder = Builder.init(&narrow_commands);
    try emitWidgetTree(&narrow_builder, widget, tokens);
    var narrow_x_labels: usize = 0;
    const narrow_plot = canvas.chartWidgetPlotRect(widget, tokens);
    for (narrow_builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                for (labels) |label| {
                    if (std.mem.eql(u8, text.text, label)) narrow_x_labels += 1;
                }
            },
            else => {},
        }
    }
    try testing.expect(narrow_x_labels >= 1);
    try testing.expect(narrow_x_labels < 6);

    // Labels reserve gutters: the plot is strictly inside the frame.
    try testing.expect(narrow_plot.x > widget.frame.x);
    try testing.expect(narrow_plot.maxY() < widget.frame.maxY());
}

test "emitted tick labels survive a later emit into another builder" {
    // The builder contract (the `allocPathElements` rule): a display
    // list may be HELD while another builder emits, and it may
    // accumulate several emit calls — either way every emitted command
    // stays intact. Label bytes live in the BUILDER's own store, so a
    // second chart's labels can never overwrite a held list's text the
    // way a per-emit-reset scratch pool would.
    var widget = Widget{
        .id = 93,
        .kind = WidgetKind.chart,
        .frame = geometry.RectF.init(0, 0, 240, 120),
        .chart = .{
            .series = &.{.{ .kind = .line, .values = &[_]f32{ 0.2, 0.8 } }},
            .y_min = 0,
            .y_max = 1,
            .grid_lines = 1,
            .y_labels = true,
        },
    };
    const tokens = DesignTokens{};
    var commands: [32]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, widget, tokens);

    // A second chart over a DIFFERENT domain emits different label
    // bytes into another builder while the first list is held.
    widget.chart.y_min = 0;
    widget.chart.y_max = 4;
    var other_commands: [32]CanvasCommand = undefined;
    var other_builder = Builder.init(&other_commands);
    try emitWidgetTree(&other_builder, widget, tokens);

    // The held list still reads the FIRST chart's lattice ("0", "0.5",
    // "1"), not the second's ("0", "2", "4") or a byte mix.
    try expectChartTickLabels(builder.displayList(), &.{ "0", "0.5", "1" });
    try expectChartTickLabels(other_builder.displayList(), &.{ "0", "2", "4" });

    // Accumulating both charts into ONE builder keeps both intact too.
    var accumulated_commands: [64]CanvasCommand = undefined;
    var accumulated = Builder.init(&accumulated_commands);
    widget.chart.y_min = 0;
    widget.chart.y_max = 1;
    try emitWidgetTree(&accumulated, widget, tokens);
    var second = widget;
    second.id = 94;
    second.chart.y_min = 0;
    second.chart.y_max = 4;
    try emitWidgetTree(&accumulated, second, tokens);
    try expectChartTickLabels(accumulated.displayList(), &.{ "0", "0.5", "1", "0", "2", "4" });
}

fn expectChartTickLabels(display_list: DisplayList, expected: []const []const u8) !void {
    var index: usize = 0;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                try testing.expect(index < expected.len);
                try testing.expectEqualStrings(expected[index], text.text);
                index += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(expected.len, index);
}

test "hover-detail chrome renders only under interaction and is deterministic" {
    const values = [_]f32{ 0.2, 0.8, 0.4, 0.6 };
    const labels = [_][]const u8{ "q1", "q2", "q3", "q4" };
    const chart_widget = Widget{
        .id = 94,
        .kind = WidgetKind.chart,
        // Explicit author size: layout honors min/max both set.
        .layout = .{
            .min_size = geometry.SizeF.init(300, 140),
            .max_size = geometry.SizeF.init(300, 140),
        },
        .chart = .{
            .series = &.{.{ .kind = .line, .values = &values, .label = "cpu" }},
            .y_min = 0,
            .y_max = 1,
            .x_labels = &labels,
            .hover_details = true,
        },
    };
    const root = Widget{
        .id = 90,
        .kind = WidgetKind.stack,
        .frame = geometry.RectF.init(0, 0, 480, 200),
        .children = &.{chart_widget},
    };
    const tokens = DesignTokens{};
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTreeWithTokens(root, root.frame, tokens, &nodes);

    // Static state: no hover chrome (the card's shadow is the tell — a
    // cold chart emits none), with or without hover_details.
    var cold_commands: [64]CanvasCommand = undefined;
    var cold_builder = Builder.init(&cold_commands);
    try layout.emitDisplayListWithState(&cold_builder, tokens, .{});
    for (cold_builder.displayList().commands) |command| {
        try testing.expect(std.meta.activeTag(command) != .shadow);
    }
    const cold_count = cold_builder.displayList().commandCount();

    // Hovered with a live pointer: cursor hairline, point dot, card
    // chrome, title, and the series row appear. Mid-plot on a 4-point
    // lattice snaps to index 2, so the title repeats sample 2's axis
    // label ("q3" draws once as an axis label, once as the card title).
    const hover_point = geometry.PointF.init(150, 70);
    const state = canvas.WidgetRenderState{ .hovered_id = 94, .hover_point = hover_point };
    var hot_commands: [64]CanvasCommand = undefined;
    var hot_builder = Builder.init(&hot_commands);
    try layout.emitDisplayListWithState(&hot_builder, tokens, state);
    try testing.expect(hot_builder.displayList().commandCount() > cold_count);
    var title_count: usize = 0;
    var saw_row_name = false;
    var saw_value = false;
    var saw_shadow = false;
    for (hot_builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.eql(u8, text.text, "q3")) title_count += 1;
                if (std.mem.eql(u8, text.text, "cpu")) saw_row_name = true;
                if (std.mem.eql(u8, text.text, "0.4")) saw_value = true;
            },
            .shadow => saw_shadow = true,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2), title_count);
    try testing.expect(saw_row_name);
    try testing.expect(saw_value);
    try testing.expect(saw_shadow);

    // Deterministic: the same state emits the same commands.
    var again_commands: [64]CanvasCommand = undefined;
    var again_builder = Builder.init(&again_commands);
    try layout.emitDisplayListWithState(&again_builder, tokens, state);
    try testing.expectEqual(hot_builder.displayList().commandCount(), again_builder.displayList().commandCount());

    // The runtime's repaint gate: both a point inside sample 2's snap
    // range and the emitted geometry agree on the index.
    var hovered = chart_widget;
    hovered.frame = layout.nodes[1].frame;
    try testing.expectEqual(@as(?usize, 2), canvas.chartWidgetHoverIndex(hovered, tokens, hover_point));
    try testing.expectEqual(@as(?usize, null), canvas.chartWidgetHoverIndex(root, tokens, hover_point));
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

const golden_width = 340;
const golden_height = 80;

/// Four tiles — line+fill, bars, band, and a labeled bar chart (x
/// category labels + y ticks in the muted register) — in one
/// deterministic frame.
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
        .{
            .id = 104,
            .kind = WidgetKind.chart,
            .frame = geometry.RectF.init(244, 4, 92, 72),
            .chart = .{
                .series = &.{.{ .kind = .bar, .values = &.{ 0.35, 0.8, 0.55, 0.95 }, .color = .accent }},
                .y_min = 0,
                .y_max = 1,
                .grid_lines = 1,
                .x_labels = &.{ "q1", "q2", "q3", "q4" },
                .y_labels = true,
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
    // /tmp/chart-shots/ before pinning new signatures. `std.c.getenv`
    // needs libc, which this module's test build only links on macOS;
    // the dump gate compiles away elsewhere and the golden assertions
    // below run everywhere.
    if (goldenDumpRequested()) {
        try dumpGoldenPng("/tmp/chart-shots/golden-light.png", &pixels);
    }

    const dark = DesignTokens.theme(.{ .color_scheme = .dark });
    try renderGoldenCharts(dark, &pixels);
    const dark_signature = support.referenceSurfaceSignature(&pixels);
    try testing.expect(light_signature != dark_signature);
    if (goldenDumpRequested()) {
        try dumpGoldenPng("/tmp/chart-shots/golden-dark.png", &pixels);
    }

    // Pinned goldens: update deliberately when chart rendering changes,
    // reviewing the rendered pixels first (see reference_tests.zig
    // conventions).
    try testing.expectEqual(@as(u64, golden_light_signature), light_signature);
    try testing.expectEqual(@as(u64, golden_dark_signature), dark_signature);
}

// Pinned after pixel review of the CHART_GOLDEN_DUMP artifacts. Four
// tiles: a line series (accent — the monochrome primary: near-black in
// light, porcelain in dark) whose stroke ends with butt caps (the wire
// default for a stroke that declares no linecap), an area fill with
// gridlines in the same accent, zero-baseline bars in success with a
// band envelope in info, and the labeled register — muted y ticks (1,
// 0.5, 0) on the gridline lattice and deterministically thinned x
// category labels (q1, q3) under the bars. Both themes clear with their
// background token. Update deliberately when chart rendering changes,
// reviewing the dumped pixels first.
const golden_light_signature: u64 = 4743613392161459263;
const golden_dark_signature: u64 = 13208780493823093371;

fn goldenDumpRequested() bool {
    if (comptime !@import("builtin").link_libc) return false;
    return std.c.getenv("CHART_GOLDEN_DUMP") != null;
}

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
