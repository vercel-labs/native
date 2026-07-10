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
//! display-list builder's path-element store is bounded at
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

/// Path-element budget for the display-list builder's own element store
/// (the widget renderer builds chart line/band elements — and the
/// spinner's and checkbox's — directly into the builder, so the emitted
/// commands own their geometry for the builder's lifetime). Mirrors the
/// runtime's `canvas_limits.max_canvas_path_elements_per_view`: a frame
/// that would exceed this fails loudly with `ChartPathElementListFull`,
/// exactly when the per-view path budget would have refused the copy
/// anyway. A filled line series costs at most `2n + 3` elements
/// (polyline + closed baseline polygon), so the budget holds ~7 maximal
/// filled series — or dozens of sparkline-sized ones — per frame.
pub const max_chart_path_elements_per_frame: usize = 2048;

/// Per-frame byte budget for the formatted tick/tooltip label scratch
/// (threadlocal frame-lifetime storage: the emitted `drawText` commands
/// slice into it until the runtime copies the display list). A y axis
/// labels at most a handful of ticks and a
/// hover tooltip a row per series, each `max_chart_value_label_bytes`
/// long, so 2 KiB holds dozens of charts per frame; overflow fails
/// loudly with `ChartLabelBytesFull`.
pub const max_chart_label_bytes_per_frame: usize = 2048;

/// Longest formatted value label: the integer digits of f32's full
/// range (39 for 3.4e38) plus sign, decimal point, and three decimals
/// all fit, so `formatChartValue` can never fail mid-frame.
pub const max_chart_value_label_bytes: usize = 48;

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
    /// Category labels for the x axis, one per sample index (label i
    /// names sample i of the longest series). Empty = no x axis. The
    /// renderer thins them deterministically to fit the plot width —
    /// every Nth label draws, in the muted text register, in a gutter
    /// reserved below the plot. `Ui.chart` drops labels entirely when
    /// any series was downsampled (bucketed indices no longer name the
    /// samples the labels were written for — silence over a lie).
    x_labels: []const []const u8 = &.{},
    /// Numeric tick labels for the y axis (opt-in): domain min, max,
    /// and every gridline value, formatted deterministically by
    /// `formatChartValue` and drawn in the muted text register inside a
    /// gutter reserved left of the plot.
    y_labels: bool = false,
    /// Pointer-hover point details (opt-in): hovering the plot snaps to
    /// the nearest sample index and shows a floating card with that
    /// index's label and every series' value. Runtime-interaction
    /// chrome only — static renders (goldens, docs tiles) never carry a
    /// hover point, so they stay byte-identical. Also makes the chart a
    /// hover hit target; presses still fall through like text.
    hover_details: bool = false,
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
    if (a.y_labels != b.y_labels) return false;
    if (a.hover_details != b.hover_details) return false;
    if (a.x_labels.len != b.x_labels.len) return false;
    for (a.x_labels, b.x_labels) |label_a, label_b| {
        if (!std.mem.eql(u8, label_a, label_b)) return false;
    }
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

// ------------------------------------------------------- value formatting

/// Decimal places that keep adjacent ticks distinct without inventing
/// precision: a step of 25 labels whole numbers, 0.25 labels two
/// places. Capped at three places — a chart axis is a reading aid, not
/// a data table. Non-finite/zero steps fall back to two places (the
/// same register the semantics summary uses).
pub fn chartTickDecimals(step: f32) u8 {
    if (!std.math.isFinite(step) or step <= 0) return 2;
    if (step >= 1) return 0;
    if (step >= 0.1) return 1;
    if (step >= 0.01) return 2;
    return 3;
}

/// Deterministic, honest number formatting for tick and tooltip labels:
/// plain decimal notation at the given precision with trailing zeros
/// (and a bare trailing point) trimmed, so 0.50 reads "0.5" and 3.00
/// reads "3". Never rounds *up* the amount of information shown — the
/// digits drawn are exactly `{d:.N}`'s. Non-finite values label
/// themselves ("nan", "inf") rather than pretending to be data. The
/// buffer must hold `max_chart_value_label_bytes`.
pub fn formatChartValue(buffer: []u8, value: f32, decimals: u8) []const u8 {
    std.debug.assert(buffer.len >= max_chart_value_label_bytes);
    if (!std.math.isFinite(value)) {
        const name: []const u8 = if (std.math.isNan(value)) "nan" else if (value > 0) "inf" else "-inf";
        @memcpy(buffer[0..name.len], name);
        return buffer[0..name.len];
    }
    const printed = switch (decimals) {
        0 => std.fmt.bufPrint(buffer, "{d:.0}", .{value}),
        1 => std.fmt.bufPrint(buffer, "{d:.1}", .{value}),
        2 => std.fmt.bufPrint(buffer, "{d:.2}", .{value}),
        else => std.fmt.bufPrint(buffer, "{d:.3}", .{value}),
    } catch unreachable; // The buffer bound above covers f32's full range.
    var text = printed;
    if (std.mem.indexOfScalar(u8, text, '.') != null) {
        while (text.len > 0 and text[text.len - 1] == '0') text = text[0 .. text.len - 1];
        if (text.len > 0 and text[text.len - 1] == '.') text = text[0 .. text.len - 1];
    }
    // "-0" reads as a rounding artifact, not a value: normalize to "0".
    if (std.mem.eql(u8, text, "-0")) return text[1..];
    return text;
}

/// The y tick lattice labeled charts ride: values at a "nice" step (1,
/// 2, or 5 times a power of ten), so every label is EXACT at its
/// step-derived precision — a label never rounds away from the line it
/// names. `desired_intervals` is a density hint (labeled charts reuse
/// `grid_lines + 1`); the chosen step is the nice value nearest
/// span/desired, and ticks run from the first lattice point at or above
/// the domain min to the last at or below the max. Pure over the domain
/// and the hint — same inputs, same lattice, same pixels.
pub const ChartTickLattice = struct {
    start: f32,
    step: f32,
    count: usize,
    decimals: u8,

    pub fn value(self: ChartTickLattice, index: usize) f32 {
        return self.start + self.step * @as(f32, @floatFromInt(index));
    }
};

/// Bound on lattice ticks: past this an axis is a texture, not a
/// reading aid (a 256-hint chart still labels at most this many).
pub const max_chart_axis_ticks: usize = 12;

pub fn chartTickLattice(domain: ChartDomain, desired_intervals: usize) ChartTickLattice {
    const span = domain.span();
    const intervals: f32 = @floatFromInt(@max(1, @min(desired_intervals, max_chart_axis_ticks)));
    const raw_step = span / intervals;
    // Snap the raw step to the nice ladder: 1/2/5 x 10^k, choosing the
    // smallest rung at or above raw (so ticks never exceed the hint by
    // more than the ladder's ratio).
    const magnitude = std.math.pow(f32, 10, @floor(std.math.log10(raw_step)));
    const normalized = raw_step / magnitude;
    const nice: f32 = if (normalized <= 1) 1 else if (normalized <= 2) 2 else if (normalized <= 5) 5 else 10;
    const step = nice * magnitude;
    const start = @ceil(domain.min / step) * step;
    // Half-step slack absorbs float error at the top edge (a tick that
    // lands on the max must not fall off it).
    var count: usize = 0;
    while (count < max_chart_axis_ticks + 1) : (count += 1) {
        const tick = start + step * @as(f32, @floatFromInt(count));
        if (tick > domain.max + step * 0.001) break;
    }
    return .{ .start = start, .step = step, .count = count, .decimals = chartTickDecimals(step) };
}

// ------------------------------------------------------------------ hover

/// Sample count hover snaps over: the longest series (every series maps
/// index i to the same x, so the densest one defines the x lattice).
pub fn chartPointCount(data: ChartData) usize {
    var count: usize = 0;
    for (data.series) |series| count = @max(count, series.values.len);
    return count;
}

/// Nearest sample index for a horizontal fraction (0..1) across the
/// plot — the inverse of the renderer's x mappings, pure and clamped.
/// Line/band points sit on the lattice i/(count-1) (nearest =
/// round(fraction*(count-1))); a bars-only chart lays samples in
/// equal-width slots instead, so the hovered index is the slot under
/// the pointer. Null when there is nothing to snap to.
pub fn chartHoverIndex(data: ChartData, fraction: f32) ?usize {
    const count = chartPointCount(data);
    if (count == 0 or !std.math.isFinite(fraction)) return null;
    if (count == 1) return 0;
    const clamped = std.math.clamp(fraction, 0, 1);
    var bars_only = true;
    for (data.series) |series| {
        if (series.values.len > 0 and series.kind != .bar) bars_only = false;
    }
    if (bars_only) {
        const slot: usize = @intFromFloat(clamped * @as(f32, @floatFromInt(count)));
        return @min(slot, count - 1);
    }
    const index: usize = @intFromFloat(@round(clamped * @as(f32, @floatFromInt(count - 1))));
    return @min(index, count - 1);
}
