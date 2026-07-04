//! Chart plot data for the `.chart` widget kind: model-derived series
//! rendered through the vector path pipeline as one leaf
//! widget — a line (with optional area fill), bars, or a min/max band —
//! with token-driven series colors so charts retheme like every other
//! widget.
//!
//! Determinism is the design center: the same series always downsamples
//! to the same points and renders the same pixels on the reference
//! renderer, so charts are golden-testable. Downsampling is index-bucket
//! min/max decimation (each bucket contributes its extremes in index
//! order), which preserves spikes a mean would flatten and is a pure
//! function of the input — no randomness, no layout dependence.
//!
//! Budgets: series points are bounded at `max_chart_points_per_series`
//! per series (the `Ui.chart` builder downsamples anything longer, so a
//! 10k-point star-history series renders instead of erroring), and the
//! per-frame path-element scratch in the widget renderer is bounded at
//! `max_chart_path_elements_per_frame`, mirroring the runtime's per-view
//! `max_canvas_path_elements_per_view` budget (a lockstep test keeps the
//! two from drifting).

const std = @import("std");
const text_spans_model = @import("text_spans.zig");

/// Token-only series color (the same closed vocabulary inline text spans
/// use), so charts re-resolve against live design tokens on retheme.
pub const ChartSeriesColor = text_spans_model.TextSpanColor;

/// Upper bound on stored points per series. `Ui.chart` downsamples
/// longer inputs deterministically; 256 points is one point per ~4px on
/// a full-width desktop chart pane. Sparkline-sized series (60 samples)
/// pass through verbatim.
pub const max_chart_points_per_series: usize = 256;

/// Per-frame path-element scratch budget for chart rendering (the widget
/// renderer builds line/band path elements into threadlocal scratch that
/// must survive until the runtime copies the display list). Mirrors the
/// runtime's `canvas_limits.max_canvas_path_elements_per_view`: a frame
/// that would exceed this fails loudly with `ChartPathElementListFull`,
/// exactly when the per-view path budget would have refused the copy
/// anyway. A filled line series costs at most `2n + 3` elements
/// (polyline + closed baseline polygon), so the budget holds ~7 maximal
/// filled series — or dozens of sparkline-sized ones — per frame.
pub const max_chart_path_elements_per_frame: usize = 2048;

pub const ChartSeriesKind = enum {
    /// Polyline through the values; `fill` adds a translucent area down
    /// to the baseline (zero when the domain includes it, else the
    /// domain floor).
    line,
    /// One bar per value. Bars always grow from zero (the dataviz
    /// baseline discipline): the auto domain includes 0, and negative
    /// values hang below the zero line.
    bar,
    /// Min/max envelope: `values` is the upper edge, `low` the lower.
    /// An empty `low` fills to the baseline like `line` + `fill`, minus
    /// the stroke.
    band,
};

/// One data series. `values` are y samples at uniform x steps, oldest
/// first (the scope-trace convention the system-monitor sparklines use).
pub const ChartSeries = struct {
    kind: ChartSeriesKind = .line,
    values: []const f32 = &.{},
    /// Lower edge for `.band` series (must pair with `values` by index;
    /// extra tail values in either slice are ignored). Unused otherwise.
    low: []const f32 = &.{},
    color: ChartSeriesColor = .accent,
    /// `.line` only: fill the area between the line and the baseline
    /// with a translucent tint of `color`.
    fill: bool = false,
    /// Series name for the semantics summary ("cpu", "stars"). Optional;
    /// the kind tag stands in when empty.
    label: []const u8 = "",
};

/// Everything a `.chart` widget carries beyond its frame: the series and
/// the plot options.
pub const ChartData = struct {
    series: []const ChartSeries = &.{},
    /// Explicit y domain; null derives each side from the data (bars
    /// force 0 into the derived domain).
    y_min: ?f32 = null,
    y_max: ?f32 = null,
    /// Horizontal token-hairline gridlines at even divisions of the plot
    /// (0 = none — gridlines are opt-in, not default).
    grid_lines: u8 = 0,
    /// Draw a hairline at the baseline (zero clamped into the domain).
    baseline: bool = false,
};

pub const ChartDomain = struct {
    min: f32,
    max: f32,

    pub fn span(self: ChartDomain) f32 {
        return self.max - self.min;
    }
};

/// The y domain a chart renders against: explicit bounds win per side;
/// otherwise the min/max across every series (including band lower
/// edges), with 0 forced in when any series is bars. Degenerate domains
/// (no finite data, or min == max) expand symmetrically so a flat series
/// renders as a centered trace instead of dividing by zero. Pure over
/// the data — same input, same domain, same pixels.
pub fn chartDomain(data: ChartData) ChartDomain {
    var has_value = false;
    var low: f32 = 0;
    var high: f32 = 0;
    for (data.series) |series| {
        accumulateChartExtremes(series.values, &has_value, &low, &high);
        if (series.kind == .band) accumulateChartExtremes(series.low, &has_value, &low, &high);
        if (series.kind == .bar and has_value) {
            low = @min(low, 0);
            high = @max(high, 0);
        }
    }
    if (!has_value) {
        low = 0;
        high = 1;
    }
    if (data.y_min) |value| {
        if (std.math.isFinite(value)) low = value;
    }
    if (data.y_max) |value| {
        if (std.math.isFinite(value)) high = value;
    }
    if (!(high > low)) {
        const center = low;
        low = center - 0.5;
        high = center + 0.5;
    }
    return .{ .min = low, .max = high };
}

fn accumulateChartExtremes(values: []const f32, has_value: *bool, low: *f32, high: *f32) void {
    for (values) |value| {
        if (!std.math.isFinite(value)) continue;
        if (!has_value.*) {
            has_value.* = true;
            low.* = value;
            high.* = value;
        } else {
            low.* = @min(low.*, value);
            high.* = @max(high.*, value);
        }
    }
}

/// Number of points `downsampleChartValues` produces for an input of
/// `len` values.
pub fn downsampledChartLen(len: usize) usize {
    return @min(len, max_chart_points_per_series);
}

/// Deterministic min/max bucket decimation into `output` (which must
/// hold `downsampledChartLen(values.len)` entries; the returned slice is
/// that prefix of it). Inputs at or under the cap copy verbatim. Longer
/// inputs split into `max_chart_points_per_series / 2` index buckets;
/// each bucket contributes its minimum and maximum (first occurrence on
/// ties), emitted in index order, so spikes survive and a repeated run
/// always produces byte-identical points. Non-finite values compare as
/// themselves and pass through — rendering skips them.
pub fn downsampleChartValues(values: []const f32, output: []f32) []const f32 {
    const out_len = downsampledChartLen(values.len);
    std.debug.assert(output.len >= out_len);
    if (values.len <= max_chart_points_per_series) {
        @memcpy(output[0..values.len], values);
        return output[0..values.len];
    }

    const bucket_count = max_chart_points_per_series / 2;
    for (0..bucket_count) |bucket| {
        const start = bucket * values.len / bucket_count;
        const end = (bucket + 1) * values.len / bucket_count;
        var min_index = start;
        var max_index = start;
        for (values[start..end], start..) |value, index| {
            // NaN never orders below/above, so a NaN-only bucket keeps
            // its first value; finite values win comparisons as usual.
            if (value < values[min_index] or (std.math.isNan(values[min_index]) and !std.math.isNan(value))) min_index = index;
            if (value > values[max_index] or (std.math.isNan(values[max_index]) and !std.math.isNan(value))) max_index = index;
        }
        const first = @min(min_index, max_index);
        const second = @max(min_index, max_index);
        output[bucket * 2] = values[first];
        output[bucket * 2 + 1] = values[second];
    }
    return output[0..out_len];
}

/// Content equality for retained-tree invalidation: a chart repaints
/// exactly when its data changed. Float comparison is bitwise via the
/// value compare (NaN != NaN forces a repaint — harmless, and honest for
/// data that cannot be equal to itself).
pub fn chartDataEqual(a: ChartData, b: ChartData) bool {
    if (a.series.len != b.series.len) return false;
    if (!optionalF32Equal(a.y_min, b.y_min)) return false;
    if (!optionalF32Equal(a.y_max, b.y_max)) return false;
    if (a.grid_lines != b.grid_lines) return false;
    if (a.baseline != b.baseline) return false;
    for (a.series, b.series) |sa, sb| {
        if (sa.kind != sb.kind) return false;
        if (sa.color != sb.color) return false;
        if (sa.fill != sb.fill) return false;
        if (!std.mem.eql(u8, sa.label, sb.label)) return false;
        if (!f32SlicesEqual(sa.values, sb.values)) return false;
        if (!f32SlicesEqual(sa.low, sb.low)) return false;
    }
    return true;
}

fn optionalF32Equal(a: ?f32, b: ?f32) bool {
    if (a) |value_a| {
        const value_b = b orelse return false;
        return value_a == value_b;
    }
    return b == null;
}

fn f32SlicesEqual(a: []const f32, b: []const f32) bool {
    if (a.len != b.len) return false;
    for (a, b) |value_a, value_b| {
        if (value_a != value_b) return false;
    }
    return true;
}
