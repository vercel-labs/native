const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_atlas = @import("text_atlas.zig");
const text_layout_types = @import("text_layout_types.zig");
const text_layout_cache = @import("text_layout_cache.zig");
const text_layout_hash = @import("text_layout_hash.zig");
const text_measure_cache = @import("text_measure_cache.zig");
const text_metrics = @import("text_metrics.zig");

const Error = canvas.Error;
const FontId = canvas.FontId;
const DisplayList = canvas.DisplayList;
const Glyph = text_atlas.Glyph;
const max_text_bounds_layout_lines: usize = 64;

pub const DrawText = text_layout_types.DrawText;
pub const TextWrap = text_layout_types.TextWrap;
pub const TextOverflow = text_layout_types.TextOverflow;
pub const TextAlign = text_layout_types.TextAlign;
pub const TextLayoutOptions = text_layout_types.TextLayoutOptions;
pub const TextLine = text_layout_types.TextLine;
pub const TextLayout = text_layout_types.TextLayout;
pub const TextLayoutKey = text_layout_types.TextLayoutKey;
pub const TextLayoutPlan = text_layout_cache.TextLayoutPlan;
pub const TextLayoutPlanSet = text_layout_cache.TextLayoutPlanSet;
pub const TextLayoutCacheEntry = text_layout_cache.TextLayoutCacheEntry;
pub const TextLayoutCacheActionKind = text_layout_cache.TextLayoutCacheActionKind;
pub const TextLayoutCacheAction = text_layout_cache.TextLayoutCacheAction;
pub const TextLayoutCachePlan = text_layout_cache.TextLayoutCachePlan;
pub const TextLayoutCachePlanner = text_layout_cache.TextLayoutCachePlanner;
pub const mono_advance_em = text_metrics.mono_advance_em;
pub const estimateTextWidth = text_metrics.estimateTextWidth;
pub const estimateTextWidthForFont = text_metrics.estimateTextWidthForFont;
pub const estimateTextWidthForFace = text_metrics.estimateTextWidthForFace;
pub const estimateTextAdvanceForBytes = text_metrics.estimateTextAdvanceForBytes;
pub const estimatedGlyphAdvance = text_metrics.estimatedGlyphAdvance;
pub const TextMeasureProvider = text_metrics.TextMeasureProvider;
pub const TextInkMetrics = text_metrics.TextInkMetrics;
pub const measureTextWidthForFont = text_metrics.measureTextWidthForFont;
pub const measureTextAdvance = text_metrics.measureTextAdvance;

/// The measurement provider a DrawText carries via its layout options, if
/// any. Runs without layout options always measure with the estimator.
fn drawTextMeasure(text: DrawText) ?*const text_metrics.TextMeasureProvider {
    if (text.text_layout) |options| {
        if (options.measure) |measure| return measure;
    }
    return text.measure;
}

const textLayoutOptionsForDrawText = text_layout_hash.textLayoutOptionsForDrawText;
const textLayoutKey = text_layout_hash.textLayoutKey;
pub const textLayoutKeysEqual = text_layout_hash.textLayoutKeysEqual;

/// The elision marker: U+2026 HORIZONTAL ELLIPSIS, taken from the run's
/// own face. Both bundled faces cover it; a registered face that lacks
/// it takes the same documented fallback every uncovered codepoint does
/// (the face's `.notdef` advance in layout, the block glyph in paint),
/// so the painted extent and the measured extent still agree.
pub const text_ellipsis = "\u{2026}";
pub const text_ellipsis_codepoint: u21 = 0x2026;

/// Advance of the ellipsis marker on the run's measurement seam — the
/// injected provider when the run carries one, the deterministic
/// estimator otherwise. Elision decisions and ellipsis painting must
/// both use this so the marker never overruns the box it promised. The
/// estimator answers from a comptime constant: this runs once per
/// overflowing line every frame, and the marker's codepoint never
/// changes.
pub fn textEllipsisAdvance(measure: ?*const text_metrics.TextMeasureProvider, font_id: FontId, size: f32) f32 {
    if (measure) |provider| return provider.measureWidth(font_id, size, text_ellipsis);
    return text_metrics.estimatedTextEllipsisAdvance(font_id, size);
}

/// True when a run's options ask for single-line trailing elision:
/// `wrap = .none` bounded by a real width with the (default) ellipsis
/// overflow policy. Wrapping runs and unbounded runs never elide.
fn lineElisionEnabled(options: TextLayoutOptions) bool {
    return options.wrap == .none and
        options.overflow == .ellipsis and
        options.max_width > 0 and
        options.max_width != std.math.inf(f32);
}

/// Exact-fit slack for the elision decision. A label box computed from
/// positioned frame edges and the same label measured as one run drift
/// apart by f32 arithmetic dust (~1e-3 px at window coordinates), and
/// falling off the elision cliff over dust swaps a whole glyph for the
/// marker. An eighth of a point sits far above that noise and far below
/// the smallest real overflow (a glyph), and any overhang it admits is
/// sub-pixel — within the layout audit's own epsilon. Mirrors the
/// audit's wrap slack.
pub const text_elision_slack: f32 = 0.125;

/// A line's elision result: how much of it painting inks, plus the
/// advance reserved for the trailing ellipsis. `ellipsis_advance == 0`
/// on an elided line means not even the marker fits (`max_width`
/// narrower than the ellipsis itself) — paint nothing rather than lie.
const LineElision = struct {
    text_len: ?usize = null,
    glyph_len: ?usize = null,
    ellipsis_advance: f32 = 0,
    /// Width of the painted bytes, measured by the elision check on the
    /// run's own seam. Line-bounds construction reuses it so a fitting
    /// line costs exactly one measure, the same as before elision
    /// existed — the fits-check IS the bounds measure.
    painted_width: ?f32 = null,
};

/// Trailing-elision point for the plain line `text[start..end)`. Returns
/// no-op elision when the line fits `max_width`. Otherwise walks cluster
/// prefixes with the same seam the line breaker measures with, keeping
/// the widest prefix whose width plus the ellipsis advance still fits,
/// and trims trailing break bytes so the marker hugs the kept glyphs
/// ("Quarterly …" never paints as "Quarterly  …"). Prefix and ellipsis
/// are measured as two runs; any kern between the last kept glyph and
/// the marker is forfeited, which can only make the painted line
/// narrower than the budget, never wider.
fn plainLineElision(text: []const u8, start: usize, end: usize, font_id: FontId, size: f32, options: TextLayoutOptions) LineElision {
    if (!lineElisionEnabled(options) or end <= start) return .{};
    if (options.measure == null) return estimatedPlainLineElision(text, start, end, font_id, size, options);
    if (text_measure_cache.textRunAdvances(options.measure.?, font_id, size, text)) |advances| {
        return advancePlainLineElision(text, start, end, font_id, size, options, advances);
    }
    const full_width = measureTextWidthForFont(options.measure, font_id, text[start..end], size);
    if (full_width <= options.max_width + text_elision_slack) return .{ .painted_width = full_width };
    const ellipsis_advance = textEllipsisAdvance(options.measure, font_id, size);
    if (ellipsis_advance > options.max_width) return .{ .text_len = 0, .ellipsis_advance = 0, .painted_width = 0 };
    const budget = options.max_width - ellipsis_advance;
    var fit = start;
    var fit_width: f32 = 0;
    var index = start;
    while (index < end) {
        const next_index = nextTextOffset(text, index);
        const next_width = measureTextWidthForFont(options.measure, font_id, text[start..next_index], size);
        if (next_width > budget) break;
        index = next_index;
        fit = index;
        fit_width = next_width;
    }
    var trimmed = fit;
    while (trimmed > start and isTextBreakByte(text[trimmed - 1])) trimmed -= 1;
    const painted_width = if (trimmed == fit)
        fit_width
    else
        measureTextWidthForFont(options.measure, font_id, text[start..trimmed], size);
    return .{ .text_len = trimmed - start, .ellipsis_advance = ellipsis_advance, .painted_width = painted_width };
}

/// The batched-provider half of `plainLineElision`, fused into ONE
/// cluster walk over the run's fetched advances — the same fusion the
/// estimator half performs, and valid for the same reason: batched
/// advances are additive by contract (a slice's width is the sum of its
/// per-cluster advances in accumulation order), so a single pass
/// accumulates the full width AND tracks the widest prefix that leaves
/// room for the marker. The advance accumulation performs the identical
/// f32 additions the old per-prefix provider measurement summed, so the
/// kept prefix is byte-identical for any provider whose prefix widths
/// are its advance sums (pinned by the seam-parity tests). The trailing
/// break-byte trim subtracts the byte's own advance; the subtraction can
/// drift from a fresh prefix measure by an ulp, which only feeds painted
/// bounds — never a break or elision decision.
fn advancePlainLineElision(text: []const u8, start: usize, end: usize, font_id: FontId, size: f32, options: TextLayoutOptions, advances: []const f32) LineElision {
    const ellipsis_advance = textEllipsisAdvance(options.measure, font_id, size);
    const budget = options.max_width - ellipsis_advance;
    var width: f32 = 0;
    var fit = start;
    var fit_width: f32 = 0;
    var index = start;
    while (index < end) {
        const next_index = nextTextOffset(text, index);
        width += advances[index];
        if (width <= budget) {
            fit = next_index;
            fit_width = width;
        }
        index = next_index;
    }
    if (width <= options.max_width + text_elision_slack) return .{ .painted_width = width };
    if (ellipsis_advance > options.max_width) return .{ .text_len = 0, .ellipsis_advance = 0, .painted_width = 0 };
    var trimmed = fit;
    var painted_width = fit_width;
    while (trimmed > start and isTextBreakByte(text[trimmed - 1])) {
        painted_width -= advances[trimmed - 1];
        trimmed -= 1;
    }
    return .{ .text_len = trimmed - start, .ellipsis_advance = ellipsis_advance, .painted_width = @max(0, painted_width) };
}

/// The estimator half of `plainLineElision`, fused into ONE cluster
/// walk. Estimator cluster advances are additive (a run's width is
/// exactly the sum of its per-cluster advances, in the same
/// accumulation order), so a single pass accumulates the full width AND
/// tracks the widest prefix that leaves room for the marker — an
/// eligible line therefore costs exactly the one measure its bounds
/// always cost, elided or not. The provider path above cannot fuse:
/// prefix re-measures are what honor kerning. Trimming a trailing break
/// byte subtracts its own advance instead of measuring the prefix
/// again.
fn estimatedPlainLineElision(text: []const u8, start: usize, end: usize, font_id: FontId, size: f32, options: TextLayoutOptions) LineElision {
    const ellipsis_advance = text_metrics.estimatedTextEllipsisAdvance(font_id, size);
    const budget = options.max_width - ellipsis_advance;
    var width: f32 = 0;
    var fit = start;
    var fit_width: f32 = 0;
    var index = start;
    while (index < end) {
        const next_index = nextTextOffset(text, index);
        const advance = estimateTextAdvanceForBytes(font_id, text[index..next_index], size);
        width += advance;
        if (width <= budget) {
            fit = next_index;
            fit_width = width;
        }
        index = next_index;
    }
    if (width <= options.max_width + text_elision_slack) return .{ .painted_width = width };
    if (ellipsis_advance > options.max_width) return .{ .text_len = 0, .ellipsis_advance = 0, .painted_width = 0 };
    var trimmed = fit;
    var painted_width = fit_width;
    while (trimmed > start and isTextBreakByte(text[trimmed - 1])) {
        painted_width -= estimateTextAdvanceForBytes(font_id, text[trimmed - 1 .. trimmed], size);
        trimmed -= 1;
    }
    return .{ .text_len = trimmed - start, .ellipsis_advance = ellipsis_advance, .painted_width = @max(0, painted_width) };
}

/// Trailing-elision point for the shaped glyph line
/// `glyphs[glyph_start..glyph_end)`: the glyph-advance mirror of
/// `plainLineElision`, also mapping the kept glyphs back to their text
/// range so serialized lines carry the matching painted bytes.
fn glyphLineElision(text: DrawText, glyph_start: usize, glyph_end: usize, line_text_start: usize, options: TextLayoutOptions) LineElision {
    if (!lineElisionEnabled(options) or glyph_end <= glyph_start) return .{};
    var full_width: f32 = 0;
    for (text.glyphs[glyph_start..glyph_end]) |glyph| full_width += estimatedGlyphAdvance(glyph, text.size);
    if (full_width <= options.max_width + text_elision_slack) return .{};
    const ellipsis_advance = textEllipsisAdvance(options.measure, text.font_id, text.size);
    if (ellipsis_advance > options.max_width) return .{ .text_len = 0, .glyph_len = 0, .ellipsis_advance = 0 };
    const budget = options.max_width - ellipsis_advance;
    var fit = glyph_start;
    var index = glyph_start;
    var width: f32 = 0;
    while (index < glyph_end) {
        const next_width = width + estimatedGlyphAdvance(text.glyphs[index], text.size);
        if (next_width > budget) break;
        width = next_width;
        index += 1;
        fit = index;
    }
    while (fit > glyph_start and isGlyphTextBreak(text, fit - 1)) fit -= 1;
    const painted_range = textRangeForGlyphRangeWithGlyphs(text.text, text.glyphs, glyph_start, fit - glyph_start);
    return .{
        .text_len = painted_range.end -| line_text_start,
        .glyph_len = fit - glyph_start,
        .ellipsis_advance = ellipsis_advance,
    };
}

pub const TextLayoutPlanner = struct {
    plans: []TextLayoutPlan,
    lines: []TextLine,
    plan_len: usize = 0,
    line_len: usize = 0,

    pub fn init(plans: []TextLayoutPlan, lines: []TextLine) TextLayoutPlanner {
        return .{ .plans = plans, .lines = lines };
    }

    pub fn reset(self: *TextLayoutPlanner) void {
        self.plan_len = 0;
        self.line_len = 0;
    }

    pub fn build(self: *TextLayoutPlanner, display_list: DisplayList, options: TextLayoutOptions) Error!TextLayoutPlanSet {
        self.reset();
        if (self.plans.len == 0 and self.lines.len == 0) return .{};

        for (display_list.commands) |command| {
            switch (command) {
                .draw_text => |value| try self.consumeText(value, options),
                else => {},
            }
        }
        return .{ .plans = self.plans[0..self.plan_len] };
    }

    fn consumeText(self: *TextLayoutPlanner, text: DrawText, options: TextLayoutOptions) Error!void {
        if (self.plan_len >= self.plans.len) return error.TextLayoutPlanListFull;
        const plan = try layoutTextRunPlan(text, options, self.lines[self.line_len..]);
        self.plans[self.plan_len] = plan;
        self.plan_len += 1;
        self.line_len += plan.lineCount();
    }
};

const text_interaction = @import("text_interaction.zig");

pub const TextRange = text_interaction.TextRange;
pub const TextSelectionRect = text_interaction.TextSelectionRect;
pub const TextSelection = text_interaction.TextSelection;
pub const TextCaretDirection = text_interaction.TextCaretDirection;
pub const TextCaretMove = text_interaction.TextCaretMove;
pub const TextCompositionUpdate = text_interaction.TextCompositionUpdate;
pub const TextInputEvent = text_interaction.TextInputEvent;
pub const TextEditState = text_interaction.TextEditState;
pub const TextBuffer = text_interaction.TextBuffer;
pub const applyTextInputEvent = text_interaction.applyTextInputEvent;
pub const snapTextSelection = text_interaction.snapTextSelection;
pub const snapTextRange = text_interaction.snapTextRange;
pub const previousTextOffset = text_interaction.previousTextOffset;
pub const nextTextOffset = text_interaction.nextTextOffset;
pub const previousTextWordOffset = text_interaction.previousTextWordOffset;
pub const nextTextWordOffset = text_interaction.nextTextWordOffset;
pub const snapTextOffset = text_interaction.snapTextOffset;
pub const utf8SequenceLength = text_interaction.utf8SequenceLength;
pub const isUtf8ContinuationByte = text_interaction.isUtf8ContinuationByte;

pub fn layoutTextRun(text: DrawText, options: TextLayoutOptions, output: []TextLine) Error!TextLayout {
    return (try layoutTextRunPlan(text, options, output)).layout;
}

pub fn layoutTextRunPlan(text: DrawText, options: TextLayoutOptions, output: []TextLine) Error!TextLayoutPlan {
    const effective_options = textLayoutOptionsForDrawText(options, text);
    var len: usize = 0;
    var bounds: ?geometry.RectF = null;
    var lines = TextLineIterator.init(text, effective_options);
    while (lines.next()) |line| {
        if (len >= output.len) return error.TextLayoutLineListFull;
        output[len] = line;
        len += 1;
        bounds = unionOptionalBounds(bounds, line.bounds);
    }
    return .{
        .key = textLayoutKey(text, effective_options),
        .layout = .{ .lines = output[0..len], .bounds = bounds },
    };
}

/// Streams a run's lines one at a time — the same lines `layoutTextRun`
/// materializes, without a line buffer or a line-count cap. Point/offset
/// queries (caret rect, selection rects, hit testing) walk this instead
/// of materializing the layout: an editable widget's text is bounded by
/// its own byte budget, not by any fixed per-query line list, so a query
/// against a long document must not be able to fail on line count.
pub const TextLineIterator = struct {
    text: DrawText,
    options: TextLayoutOptions,
    line_height_value: f32,
    /// Line index so far; each line's baseline derives from it.
    index: usize = 0,
    /// Byte cursor (plain runs) or glyph cursor (glyph runs).
    cursor: usize = 0,
    finished: bool = false,

    pub fn init(text: DrawText, options: TextLayoutOptions) TextLineIterator {
        return .{ .text = text, .options = options, .line_height_value = lineHeight(text, options) };
    }

    pub fn next(self: *TextLineIterator) ?TextLine {
        if (self.finished) return null;
        if (self.text.glyphs.len > 0) return self.nextGlyphLine();
        return self.nextPlainLine();
    }

    fn nextPlainLine(self: *TextLineIterator) ?TextLine {
        const bytes = self.text.text;
        if (bytes.len == 0) {
            self.finished = true;
            return self.emit(0, 0, 0, 0, .{});
        }
        const start = self.cursor;
        const end = nextTextLineEnd(bytes, start, self.text.font_id, self.text.size, self.options);
        if (end >= bytes.len) {
            self.finished = true;
        } else {
            var next_start = end;
            if (next_start < bytes.len and bytes[next_start] == '\n') {
                // A hard break starts the next line immediately after
                // the newline. Its leading whitespace is editable
                // content, so it must contribute paint and caret width.
                next_start += 1;
            } else {
                // Only soft word wraps elide their break separators.
                while (self.options.wrap == .word and next_start < bytes.len and isTextBreakByte(bytes[next_start])) next_start += 1;
            }
            self.cursor = next_start;
        }
        const elision = plainLineElision(bytes, start, end, self.text.font_id, self.text.size, self.options);
        return self.emit(start, end - start, start, end - start, elision);
    }

    fn nextGlyphLine(self: *TextLineIterator) ?TextLine {
        var glyph_start = self.cursor;
        while (self.options.wrap == .word and glyph_start < self.text.glyphs.len and isGlyphTextBreak(self.text, glyph_start)) glyph_start += 1;
        if (glyph_start >= self.text.glyphs.len) {
            self.finished = true;
            // A run whose glyphs are all breaks still lays out as one
            // empty line (the buffered path's fallback emission).
            if (self.index == 0) return self.emit(0, 0, 0, 0, .{});
            return null;
        }
        const glyph_end = nextGlyphLineEnd(self.text, glyph_start, self.options);
        const range = textRangeForGlyphRangeWithGlyphs(self.text.text, self.text.glyphs, glyph_start, glyph_end - glyph_start);
        self.cursor = glyph_end;
        const elision = glyphLineElision(self.text, glyph_start, glyph_end, range.start, self.options);
        return self.emit(range.start, range.byteLen(self.text.text.len), glyph_start, glyph_end - glyph_start, elision);
    }

    fn emit(self: *TextLineIterator, text_start: usize, text_len: usize, glyph_start: usize, glyph_len: usize, elision: LineElision) TextLine {
        const line = textLineAt(self.text, text_start, text_len, glyph_start, glyph_len, self.index, self.line_height_value, self.options, elision);
        self.index += 1;
        return line;
    }
};

/// Conservative ink allowance around a text run's metric box. Command
/// bounds must cover everything a command may ink (stroke bounds inflate
/// by stroke width, blur bounds by the radius); text metrics only cover
/// advances, and real glyph outlines overhang them: fallback glyphs can
/// extend above the bundled face's cap-height anchor, a wide glyph behind
/// the flat 0.65em multibyte estimate (arrows, dingbats) pokes up to
/// ~0.3em past the last advance, descenders plus anti-aliasing spill a
/// hair below the 0.25em descent box, and italic or negative-LSB glyphs
/// lean slightly left of the pen. Renderers clip to command bounds, so a
/// metric-tight box visibly shaved fallback and tail glyphs off screenshots.
fn textInkInsets(size: f32) geometry.InsetsF {
    const em = @max(0, size);
    return geometry.InsetsF.init(em * 0.35, em * 0.35, em * 0.1, em * 0.1);
}

pub fn textBounds(value: DrawText) ?geometry.RectF {
    if (value.text_layout) |options| {
        var lines: [max_text_bounds_layout_lines]TextLine = undefined;
        if (layoutTextRun(value, options, &lines)) |layout| {
            return textBoundsForLines(value, layout.lines);
        } else |_| {}

        // Bounds must remain truthful even when the fixed layout scratch
        // cannot materialize every line. Stream the same iterator used by
        // caret and selection queries; this keeps long wrapped paragraphs
        // from falling back to a metric box that can clip host-shaped ink.
        const effective_options = textLayoutOptionsForDrawText(options, value);
        var iterator = TextLineIterator.init(value, effective_options);
        var bounds: ?geometry.RectF = null;
        while (iterator.next()) |line| {
            bounds = unionOptionalBounds(bounds, textLineInkBounds(value, line));
        }
        if (bounds) |value_bounds| return value_bounds.inflate(textInkInsets(value.size));
    }

    const metric = metricTextBounds(value) orelse return null;
    var bounds = metric.inflate(textInkInsets(value.size));
    if (value.text_layout == null and value.glyphs.len == 0) {
        if (drawTextMeasure(value)) |provider| {
            if (provider.measureInk(value.font_id, value.size, value.text)) |metrics| {
                bounds = bounds.unionWith(geometry.RectF.init(
                    value.origin.x + metrics.min_x,
                    value.origin.y - metrics.max_y,
                    metrics.max_x - metrics.min_x,
                    metrics.max_y - metrics.min_y,
                ));
            }
        }
    }
    return bounds;
}

fn textBoundsForLines(value: DrawText, lines: []const TextLine) ?geometry.RectF {
    var bounds: ?geometry.RectF = null;
    for (lines) |line| {
        bounds = unionOptionalBounds(bounds, textLineInkBounds(value, line));
    }
    return if (bounds) |value_bounds| value_bounds.inflate(textInkInsets(value.size)) else null;
}

fn textLineInkBounds(value: DrawText, line: TextLine) geometry.RectF {
    var bounds = line.bounds;
    if (value.glyphs.len > 0) return bounds;
    if (drawTextMeasure(value)) |provider| {
        const start = @min(line.text_start, value.text.len);
        const end = @min(value.text.len, start + line.paintedTextLen());
        if (end > start) {
            if (provider.measureInk(value.font_id, value.size, value.text[start..end])) |line_metrics| {
                bounds = bounds.unionWith(geometry.RectF.init(
                    line.bounds.x + line_metrics.min_x,
                    line.baseline - line_metrics.max_y,
                    line_metrics.max_x - line_metrics.min_x,
                    line_metrics.max_y - line_metrics.min_y,
                ));
            }
        }
        if (line.hasEllipsis()) {
            if (provider.measureInk(value.font_id, value.size, text_ellipsis)) |ellipsis_metrics| {
                bounds = bounds.unionWith(geometry.RectF.init(
                    line.bounds.maxX() - line.ellipsis_advance + ellipsis_metrics.min_x,
                    line.baseline - ellipsis_metrics.max_y,
                    ellipsis_metrics.max_x - ellipsis_metrics.min_x,
                    ellipsis_metrics.max_y - ellipsis_metrics.min_y,
                ));
            }
        }
    }
    return bounds;
}

fn metricTextBounds(value: DrawText) ?geometry.RectF {
    if (value.glyphs.len == 0 and value.text.len == 0) return null;

    var min_x = value.origin.x;
    var min_y = value.origin.y - value.size;
    var max_x = value.origin.x;
    var max_y = value.origin.y + value.size * 0.25;
    if (value.glyphs.len > 0) {
        min_x = value.origin.x + value.glyphs[0].x;
        max_x = min_x + estimatedGlyphAdvance(value.glyphs[0], value.size);
        min_y = value.origin.y + value.glyphs[0].y - value.size;
        max_y = value.origin.y + value.glyphs[0].y + value.size * 0.25;
        for (value.glyphs[1..]) |glyph| {
            const glyph_x = value.origin.x + glyph.x;
            const glyph_y = value.origin.y + glyph.y;
            min_x = @min(min_x, glyph_x);
            max_x = @max(max_x, glyph_x + estimatedGlyphAdvance(glyph, value.size));
            min_y = @min(min_y, glyph_y - value.size);
            max_y = @max(max_y, glyph_y + value.size * 0.25);
        }
    } else {
        max_x = value.origin.x + measureTextWidthForFont(drawTextMeasure(value), value.font_id, value.text, value.size);
    }

    return geometry.RectF.init(
        min_x,
        min_y,
        @max(value.size * 0.25, max_x - min_x),
        @max(value.size * 1.25, max_y - min_y),
    );
}

/// Caret rectangle for `offset`, streaming the run's lines — no line
/// buffer and no line-count failure mode: the caret of an arbitrarily
/// long document always resolves.
pub fn layoutTextCaretRect(text: DrawText, options: TextLayoutOptions, offset: usize) ?geometry.RectF {
    return layoutTextCaretRectWithAffinity(text, options, offset, .upstream);
}

pub fn layoutTextCaretRectWithAffinity(
    text: DrawText,
    options: TextLayoutOptions,
    offset: usize,
    affinity: canvas.TextCaretAffinity,
) ?geometry.RectF {
    const line = streamTextLineForOffset(text, options, snapTextOffset(text.text, offset), affinity) orelse return null;
    return textCaretRectForLine(text, line, offset);
}

pub fn textCaretRectForLayout(text: DrawText, layout: TextLayout, offset: usize) ?geometry.RectF {
    return textCaretRectForLayoutWithAffinity(text, layout, offset, .upstream);
}

pub fn textCaretRectForLayoutWithAffinity(
    text: DrawText,
    layout: TextLayout,
    offset: usize,
    affinity: canvas.TextCaretAffinity,
) ?geometry.RectF {
    const line = textLineForOffset(layout, text.text.len, snapTextOffset(text.text, offset), affinity) orelse return null;
    return textCaretRectForLine(text, line, offset);
}

fn textCaretRectForLine(text: DrawText, line: TextLine, offset: usize) geometry.RectF {
    const x = textLineCaretX(text, line, offset);
    return geometry.RectF.init(x, line.bounds.y, 1, @max(1, line.bounds.height));
}

/// Selection rectangles for `range`, streaming the run's lines. A range
/// spanning more lines than `output` holds folds the overflow into the
/// last rectangle (a bounding highlight) instead of failing: selection
/// drawing degrades, it never errors — select-all over a long document
/// is an ordinary render, not a capacity fault.
pub fn layoutTextSelectionRects(
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    output: []TextSelectionRect,
) []const TextSelectionRect {
    const normalized = snapTextRange(text.text, range);
    if (normalized.isCollapsed(text.text.len)) return output[0..0];

    var accumulator = TextSelectionRectAccumulator{ .output = output };
    var lines = TextLineIterator.init(text, options);
    while (lines.next()) |line| {
        accumulateTextSelectionRect(&accumulator, text, line, normalized);
    }
    return accumulator.slice();
}

pub fn textSelectionRectsForLayout(text: DrawText, layout: TextLayout, range: TextRange, output: []TextSelectionRect) []const TextSelectionRect {
    const normalized = snapTextRange(text.text, range);
    if (normalized.isCollapsed(text.text.len)) return output[0..0];

    var accumulator = TextSelectionRectAccumulator{ .output = output };
    for (layout.lines) |line| {
        accumulateTextSelectionRect(&accumulator, text, line, normalized);
    }
    return accumulator.slice();
}

const TextSelectionRectAccumulator = struct {
    output: []TextSelectionRect,
    len: usize = 0,

    fn add(self: *TextSelectionRectAccumulator, range: TextRange, rect: geometry.RectF) void {
        if (self.output.len == 0) return;
        if (self.len == self.output.len) {
            // The caller's rect budget is full: widen the last rect to
            // cover this line too, so the highlight stays a truthful
            // bound over the whole range instead of erroring out.
            const last = &self.output[self.len - 1];
            last.range = TextRange.init(last.range.start, range.end);
            last.rect = last.rect.unionWith(rect);
            return;
        }
        self.output[self.len] = .{ .range = range, .rect = rect };
        self.len += 1;
    }

    fn slice(self: *const TextSelectionRectAccumulator) []const TextSelectionRect {
        return self.output[0..self.len];
    }
};

fn accumulateTextSelectionRect(accumulator: *TextSelectionRectAccumulator, text: DrawText, line: TextLine, normalized: TextRange) void {
    const line_range = textLineRange(text, line);
    const start = @max(normalized.start, line_range.start);
    const end = @min(normalized.end, line_range.end);
    if (start >= end) return;

    const x0 = textLineCaretX(text, line, start);
    const x1 = textLineCaretX(text, line, end);
    const left = @min(x0, x1);
    const right = @max(x0, x1);
    accumulator.add(
        TextRange.init(start, end),
        geometry.RectF.init(left, line.bounds.y, @max(1, right - left), @max(1, line.bounds.height)),
    );
}

/// Byte offset for a point, streaming the run's lines — hit testing a
/// click in a long document has no line-count failure mode.
pub fn layoutTextOffsetForPoint(text: DrawText, options: TextLayoutOptions, point: geometry.PointF) ?usize {
    const position = layoutTextCaretPositionForPoint(text, options, point) orelse return null;
    return position.offset;
}

pub fn layoutTextCaretPositionForPoint(
    text: DrawText,
    options: TextLayoutOptions,
    point: geometry.PointF,
) ?canvas.TextCaretPosition {
    var lines = TextLineIterator.init(text, options);
    var candidate: ?TextLine = null;
    var previous: ?TextLine = null;
    var candidate_previous: ?TextLine = null;
    while (lines.next()) |line| {
        candidate = line;
        candidate_previous = previous;
        if (point.y < line.bounds.y + line.bounds.height) break;
        previous = line;
    }
    const line = candidate orelse return null;
    return textCaretPositionForLine(text, line, candidate_previous, point.x);
}

pub fn textOffsetForLayoutPoint(text: DrawText, layout: TextLayout, point: geometry.PointF) ?usize {
    const position = textCaretPositionForLayoutPoint(text, layout, point) orelse return null;
    return position.offset;
}

pub fn textCaretPositionForLayoutPoint(
    text: DrawText,
    layout: TextLayout,
    point: geometry.PointF,
) ?canvas.TextCaretPosition {
    var previous: ?TextLine = null;
    for (layout.lines) |line| {
        if (point.y < line.bounds.y + line.bounds.height) {
            return textCaretPositionForLine(text, line, previous, point.x);
        }
        previous = line;
    }
    const line = previous orelse return null;
    const before = if (layout.lines.len > 1) layout.lines[layout.lines.len - 2] else null;
    return textCaretPositionForLine(text, line, before, point.x);
}

fn textCaretPositionForLine(
    text: DrawText,
    line: TextLine,
    previous: ?TextLine,
    x: f32,
) canvas.TextCaretPosition {
    const offset = textLineOffsetForX(text, line, x);
    const range = textLineRange(text, line);
    const affinity: canvas.TextCaretAffinity = if (previous) |previous_line|
        if (offset == range.start and textLineRange(text, previous_line).end == offset)
            .downstream
        else
            .upstream
    else
        .upstream;
    return .{ .offset = offset, .affinity = affinity };
}

/// Streaming twin of `textLineForOffset`: the line containing
/// `offset` (already snapped), with the same neighbor semantics.
fn streamTextLineForOffset(
    text: DrawText,
    options: TextLayoutOptions,
    offset: usize,
    affinity: canvas.TextCaretAffinity,
) ?TextLine {
    const normalized = @min(offset, text.text.len);
    var lines = TextLineIterator.init(text, options);
    var previous: ?TextLine = null;
    while (lines.next()) |line| {
        const range = textLineRangeForLength(text.text.len, line);
        if (normalized < range.start) return previous orelse line;
        if (normalized < range.end) return line;
        if (normalized == range.end) {
            if (affinity == .upstream) return line;
            const next_line = lines.next() orelse return line;
            const next_range = textLineRangeForLength(text.text.len, next_line);
            return if (next_range.start == normalized) next_line else line;
        }
        previous = line;
    }
    return previous;
}

pub fn nextTextLineEnd(text: []const u8, start: usize, font_id: FontId, size: f32, options: TextLayoutOptions) usize {
    const max_width = if (options.max_width > 0) options.max_width else std.math.inf(f32);
    if (options.wrap == .none or max_width == std.math.inf(f32)) {
        return nextExplicitLineEnd(text, start);
    }

    // Batched provider path: fetch the run's per-cluster advances once
    // (cached across the run's lines and across rebuilds) and break from
    // cumulative sums — O(L) per run instead of measuring the growing
    // line prefix once per cluster (O(L²), one provider round-trip
    // each). Falls through to the unbatched loop when the provider has
    // no batched entry or the host declined this run.
    if (options.measure) |provider| {
        if (text_measure_cache.textRunAdvances(provider, font_id, size, text)) |advances| {
            return nextTextLineEndFromAdvances(text, start, max_width, options.wrap, advances);
        }
    }

    var index = start;
    var last_break: ?usize = null;
    while (index < text.len) {
        if (text[index] == '\n') return index;
        const next_index = nextTextOffset(text, index);
        const next_width = measureTextWidthForFont(options.measure, font_id, text[start..next_index], size);
        if (isTextBreakByte(text[index])) last_break = next_index;
        if (next_width > max_width) {
            if (index == start) return next_index;
            if (options.wrap == .word) {
                if (last_break) |break_index| {
                    if (break_index > start) return trimTrailingTextBreak(text, start, break_index);
                }
            }
            return index;
        }
        index = next_index;
    }
    return text.len;
}

/// The batched twin of the unbatched `nextTextLineEnd` loop below it:
/// the same cursor walk, the same break bookkeeping, the same return
/// points — only `next_width` comes from accumulating the run's
/// per-cluster advances instead of re-measuring the growing prefix.
/// The accumulation performs the identical f32 additions a per-prefix
/// provider whose widths are its advance sums would produce, so the
/// chosen break offsets are byte-identical (pinned by the seam-parity
/// tests, including kerning-ish non-uniform advances and multi-byte
/// clusters).
fn nextTextLineEndFromAdvances(text: []const u8, start: usize, max_width: f32, wrap: TextWrap, advances: []const f32) usize {
    var index = start;
    var width: f32 = 0;
    var last_break: ?usize = null;
    while (index < text.len) {
        if (text[index] == '\n') return index;
        const next_index = nextTextOffset(text, index);
        const next_width = width + advances[index];
        if (isTextBreakByte(text[index])) last_break = next_index;
        if (next_width > max_width) {
            if (index == start) return next_index;
            if (wrap == .word) {
                if (last_break) |break_index| {
                    if (break_index > start) return trimTrailingTextBreak(text, start, break_index);
                }
            }
            return index;
        }
        width = next_width;
        index = next_index;
    }
    return text.len;
}

fn nextGlyphLineEnd(text: DrawText, start: usize, options: TextLayoutOptions) usize {
    const max_width = if (options.max_width > 0) options.max_width else std.math.inf(f32);
    if (options.wrap == .none or max_width == std.math.inf(f32)) return text.glyphs.len;

    var index = start;
    var width: f32 = 0;
    var last_break: ?usize = null;
    while (index < text.glyphs.len) {
        if (isGlyphTextBreak(text, index)) last_break = index;
        const next_width = width + estimatedGlyphAdvance(text.glyphs[index], text.size);
        if (next_width > max_width) {
            if (index == start) return index + 1;
            if (options.wrap == .word) {
                if (last_break) |break_index| {
                    if (break_index > start) return break_index;
                }
            }
            return index;
        }
        width = next_width;
        index += 1;
    }
    return text.glyphs.len;
}

fn nextExplicitLineEnd(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\n') return index;
    }
    return text.len;
}

fn trimTrailingTextBreak(text: []const u8, start: usize, end: usize) usize {
    var trimmed = end;
    while (trimmed > start and isTextBreakByte(text[trimmed - 1])) {
        trimmed -= 1;
    }
    return if (trimmed == start) end else trimmed;
}

fn textLineAt(
    text: DrawText,
    text_start: usize,
    text_len: usize,
    glyph_start: usize,
    glyph_len: usize,
    line_index: usize,
    line_height_value: f32,
    options: TextLayoutOptions,
    elision: LineElision,
) TextLine {
    const baseline = text.origin.y + @as(f32, @floatFromInt(line_index)) * line_height_value;
    // Bounds cover the painted extent: the kept prefix plus the trailing
    // ellipsis on an elided line, so alignment centers what is actually
    // inked and audits see the true painted width. A plain line whose
    // elision check already measured it reuses that width instead of
    // measuring again.
    const painted_text_len = elision.text_len orelse text_len;
    const painted_glyph_len = elision.glyph_len orelse glyph_len;
    const plain_line = painted_glyph_len == 0 or glyph_start >= text.glyphs.len;
    var raw_bounds = if (plain_line and elision.painted_width != null)
        geometry.RectF.init(text.origin.x, baseline - text.size, elision.painted_width.?, line_height_value)
    else
        textLineBounds(text, text_start, painted_text_len, glyph_start, painted_glyph_len, baseline, line_height_value);
    raw_bounds.width += elision.ellipsis_advance;
    const line_bounds = alignTextLineBounds(raw_bounds, options);
    return .{
        .text_start = text_start,
        .text_len = text_len,
        .glyph_start = glyph_start,
        .glyph_len = glyph_len,
        .bounds = line_bounds,
        .baseline = baseline,
        .elided_text_len = elision.text_len,
        .elided_glyph_len = elision.glyph_len,
        .ellipsis_advance = elision.ellipsis_advance,
    };
}

fn alignTextLineBounds(bounds: geometry.RectF, options: TextLayoutOptions) geometry.RectF {
    const max_width = nonNegative(options.max_width);
    if (max_width <= 0 or bounds.width >= max_width) return bounds;
    const extra = max_width - bounds.width;
    const dx = switch (options.alignment) {
        .start => 0,
        .center => extra * 0.5,
        .end => extra,
    };
    return bounds.translate(geometry.OffsetF.init(dx, 0));
}

fn textLineForOffset(
    layout: TextLayout,
    text_len: usize,
    offset: usize,
    affinity: canvas.TextCaretAffinity,
) ?TextLine {
    if (layout.lines.len == 0) return null;
    const normalized = @min(offset, text_len);
    var previous: ?TextLine = null;
    for (layout.lines, 0..) |line, index| {
        const range = textLineRangeForLength(text_len, line);
        if (normalized < range.start) return previous orelse line;
        if (normalized < range.end) return line;
        if (normalized == range.end) {
            if (affinity == .upstream or index + 1 >= layout.lines.len) return line;
            const next_line = layout.lines[index + 1];
            const next_range = textLineRangeForLength(text_len, next_line);
            return if (next_range.start == normalized) next_line else line;
        }
        previous = line;
    }
    return previous;
}

pub fn textLineRange(text: DrawText, line: TextLine) TextRange {
    return textLineRangeForLength(text.text.len, line);
}

fn textLineRangeForLength(text_len: usize, line: TextLine) TextRange {
    const start = @min(line.text_start, text_len);
    const end = @min(text_len, start + line.text_len);
    return TextRange.init(start, end);
}

pub fn textLineCaretX(text: DrawText, line: TextLine, offset: usize) f32 {
    const range = textLineRange(text, line);
    const snapped = clampTextOffsetToRange(text.text, range, offset);
    const x = if (line.glyph_len > 0 and line.glyph_start < text.glyphs.len)
        textLineGlyphCaretX(text, line, range, snapped)
    else
        line.bounds.x + measureTextWidthForFont(drawTextMeasure(text), text.font_id, text.text[range.start..snapped], text.size);
    // Offsets in an elided line's hidden tail pin to the painted right
    // edge (after the ellipsis): selection highlights stay inside the
    // box while the range itself still covers every hidden byte.
    if (line.isElided()) return @min(x, line.bounds.maxX());
    return x;
}

fn textLineGlyphCaretX(text: DrawText, line: TextLine, range: TextRange, offset: usize) f32 {
    if (range.end <= range.start) return line.bounds.x;
    if (offset <= range.start) return line.bounds.x;
    if (offset >= range.end) return line.bounds.x + line.bounds.width;

    if (textGlyphLineHasExplicitRanges(text, line)) {
        return textLineExplicitGlyphCaretX(text, line, range, offset);
    }

    const scalar_count = utf8ScalarCount(text.text[range.start..range.end]);
    if (scalar_count == 0) return line.bounds.x;
    const scalar_index = utf8ScalarIndexForOffset(text.text[range.start..range.end], offset - range.start);
    const glyph_offset = @min(line.glyph_len, (scalar_index * line.glyph_len) / scalar_count);
    if (glyph_offset == 0) return line.bounds.x;
    if (glyph_offset >= line.glyph_len or line.glyph_start + glyph_offset >= text.glyphs.len) return line.bounds.x + line.bounds.width;

    const raw_bounds = textLineBounds(text, line.text_start, line.text_len, line.glyph_start, line.glyph_len, line.baseline, line.bounds.height);
    const first_x = text.glyphs[line.glyph_start].x;
    const glyph = text.glyphs[line.glyph_start + glyph_offset];
    return text.origin.x + glyph.x - first_x + (line.bounds.x - raw_bounds.x);
}

fn textLineOffsetForX(text: DrawText, line: TextLine, x: f32) usize {
    const range = textLineRange(text, line);
    if (x <= line.bounds.x) return range.start;
    // Elided lines: the hidden tail has no painted geometry, so a point
    // past the painted right edge means "everything" (a rightward sweep
    // selects the whole line, hidden bytes included) and a point on the
    // ellipsis itself means the kept prefix.
    if (line.isElided()) {
        if (x >= line.bounds.maxX()) return range.end;
        if (x >= line.bounds.maxX() - line.ellipsis_advance) {
            return snapTextOffset(text.text, @min(range.end, line.text_start + line.paintedTextLen()));
        }
    }
    if (line.glyph_len > 0 and line.glyph_start < text.glyphs.len) {
        return textLineGlyphOffsetForX(text, line, range, x);
    }

    var cursor = range.start;
    var caret_x = line.bounds.x;
    while (cursor < range.end) {
        const next_cursor = nextTextOffset(text.text, cursor);
        const advance = @max(1, measureTextAdvance(drawTextMeasure(text), text.font_id, text.size, text.text, range.start, cursor, next_cursor));
        if (x < caret_x + advance * 0.5) return cursor;
        caret_x += advance;
        cursor = next_cursor;
    }
    return range.end;
}

fn textLineGlyphOffsetForX(text: DrawText, line: TextLine, range: TextRange, x: f32) usize {
    const glyph_end = @min(text.glyphs.len, line.glyph_start + line.glyph_len);
    const raw_bounds = textLineBounds(text, line.text_start, line.text_len, line.glyph_start, line.glyph_len, line.baseline, line.bounds.height);
    const first_x = text.glyphs[line.glyph_start].x;
    const dx = line.bounds.x - raw_bounds.x;
    if (textGlyphLineHasExplicitRanges(text, line)) {
        return textLineExplicitGlyphOffsetForX(text, line, range, x, first_x, dx);
    }

    for (text.glyphs[line.glyph_start..glyph_end], 0..) |glyph, glyph_index| {
        const glyph_x = text.origin.x + glyph.x - first_x + dx;
        const advance = @max(1, estimatedGlyphAdvance(glyph, text.size));
        if (x < glyph_x + advance * 0.5) {
            const glyph_range = textRangeForGlyph(text.text, text.glyphs, line.glyph_start + glyph_index);
            return clampTextOffsetToRange(text.text, range, glyph_range.start);
        }
    }
    return range.end;
}

fn clampTextOffsetToRange(text: []const u8, range: TextRange, offset: usize) usize {
    const snapped = snapTextOffset(text, offset);
    if (snapped < range.start) return range.start;
    if (snapped > range.end) return range.end;
    return snapped;
}

fn utf8ScalarIndexForOffset(text: []const u8, offset: usize) usize {
    const target = snapTextOffset(text, offset);
    var cursor: usize = 0;
    var index: usize = 0;
    while (cursor < target) : (index += 1) {
        cursor = nextTextOffset(text, cursor);
    }
    return index;
}

fn lineHeight(text: DrawText, options: TextLayoutOptions) f32 {
    return if (options.line_height > 0) options.line_height else text.size * 1.25;
}

pub fn textLineBounds(text: DrawText, text_start: usize, text_len: usize, glyph_start: usize, glyph_len: usize, baseline: f32, line_height_value: f32) geometry.RectF {
    if (glyph_len > 0 and glyph_start < text.glyphs.len) {
        const glyphs = text.glyphs[glyph_start..@min(text.glyphs.len, glyph_start + glyph_len)];
        const origin_x = glyphs[0].x;
        var min_x: f32 = 0;
        var max_x = estimatedGlyphAdvance(glyphs[0], text.size);
        var min_y = baseline - text.size;
        var max_y = min_y + line_height_value;
        for (glyphs) |glyph| {
            const glyph_x = glyph.x - origin_x;
            min_x = @min(min_x, glyph_x);
            max_x = @max(max_x, glyph_x + estimatedGlyphAdvance(glyph, text.size));
            min_y = @min(min_y, baseline + glyph.y - text.size);
            max_y = @max(max_y, baseline + glyph.y + text.size * 0.25);
        }
        return geometry.RectF.init(text.origin.x + min_x, min_y, @max(0, max_x - min_x), @max(0, max_y - min_y));
    }
    return geometry.RectF.init(
        text.origin.x,
        baseline - text.size,
        plainLineSliceWidth(text, text_start, @min(text.text.len, text_start + text_len)),
        line_height_value,
    );
}

/// Width of the plain line `text.text[start..end)` on the run's own
/// measurement seam. With a batch-capable provider this sums the run's
/// ALREADY-CACHED per-cluster advances (a peek hit right after the line
/// breaker or the elision check fetched them — line bounds stop costing
/// one provider round-trip per line per frame). It deliberately never
/// fetches: bounds run per frame over every retained run, and fetching
/// here turned one memoized host width per single-line run into a full
/// host shape per run per frame once the retained set outgrew the
/// cache. Unbatched (and estimator) runs keep the historical per-slice
/// measure byte-identically.
fn plainLineSliceWidth(text: DrawText, start: usize, end: usize) f32 {
    if (drawTextMeasure(text)) |provider| {
        if (text_measure_cache.cachedTextRunAdvances(provider, text.font_id, text.size, text.text)) |advances| {
            return text_measure_cache.advanceSliceWidth(advances, start, end);
        }
    }
    return measureTextWidthForFont(drawTextMeasure(text), text.font_id, text.text[start..end], text.size);
}

pub fn isTextBreakByte(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isGlyphTextBreak(text: DrawText, glyph_index: usize) bool {
    if (glyph_index >= text.glyphs.len) return false;
    const range = textRangeForGlyph(text.text, text.glyphs, glyph_index);
    return range.start < range.end and isTextBreakByte(text.text[range.start]);
}

fn textRangeForGlyph(text: []const u8, glyphs: []const Glyph, glyph_index: usize) TextRange {
    if (glyph_index >= glyphs.len) return TextRange.init(text.len, text.len);
    const glyph = glyphs[glyph_index];
    if (glyph.text_len > 0) return snapTextRange(text, TextRange.init(glyph.text_start, glyph.text_start + glyph.text_len));
    return textRangeForGlyphRange(text, glyph_index, 1, glyphs.len);
}

fn textRangeForGlyphRangeWithGlyphs(text: []const u8, glyphs: []const Glyph, glyph_start: usize, glyph_len: usize) TextRange {
    if (glyph_len == 0 or glyph_start >= glyphs.len) return textRangeForGlyphRange(text, glyph_start, glyph_len, glyphs.len);
    const glyph_end = @min(glyphs.len, glyph_start + glyph_len);
    var explicit_start: usize = text.len;
    var explicit_end: usize = 0;
    for (glyphs[glyph_start..glyph_end]) |glyph| {
        if (glyph.text_len == 0) return textRangeForGlyphRange(text, glyph_start, glyph_len, glyphs.len);
        const range = snapTextRange(text, TextRange.init(glyph.text_start, glyph.text_start + glyph.text_len));
        explicit_start = @min(explicit_start, range.start);
        explicit_end = @max(explicit_end, range.end);
    }
    return TextRange.init(explicit_start, explicit_end);
}

fn textRangeForGlyphRange(text: []const u8, glyph_start: usize, glyph_len: usize, glyph_count: usize) TextRange {
    if (text.len == 0 or glyph_count == 0) return TextRange.init(0, 0);
    const scalar_count = utf8ScalarCount(text);
    if (scalar_count == 0) return TextRange.init(0, 0);

    const glyph_end = @min(glyph_count, glyph_start + glyph_len);
    const start_scalar = @min(scalar_count, (glyph_start * scalar_count) / glyph_count);
    const end_scalar = @min(scalar_count, ((glyph_end * scalar_count) + glyph_count - 1) / glyph_count);
    return TextRange.init(textOffsetForScalarIndex(text, start_scalar), textOffsetForScalarIndex(text, end_scalar));
}

fn textGlyphLineHasExplicitRanges(text: DrawText, line: TextLine) bool {
    if (line.glyph_len == 0 or line.glyph_start >= text.glyphs.len) return false;
    const glyph_end = @min(text.glyphs.len, line.glyph_start + line.glyph_len);
    for (text.glyphs[line.glyph_start..glyph_end]) |glyph| {
        if (glyph.text_len == 0) return false;
    }
    return true;
}

fn textLineExplicitGlyphCaretX(text: DrawText, line: TextLine, range: TextRange, offset: usize) f32 {
    const glyph_end = @min(text.glyphs.len, line.glyph_start + line.glyph_len);
    const raw_bounds = textLineBounds(text, line.text_start, line.text_len, line.glyph_start, line.glyph_len, line.baseline, line.bounds.height);
    const first_x = text.glyphs[line.glyph_start].x;
    const dx = line.bounds.x - raw_bounds.x;

    for (line.glyph_start..glyph_end) |glyph_index| {
        const glyph = text.glyphs[glyph_index];
        const glyph_range = textRangeForGlyph(text.text, text.glyphs, glyph_index);
        if (glyph_range.end <= range.start or glyph_range.start >= range.end) continue;

        const glyph_x = text.origin.x + glyph.x - first_x + dx;
        if (offset <= glyph_range.start) return glyph_x;
        if (offset < glyph_range.end) {
            const advance = @max(1, estimatedGlyphAdvance(glyph, text.size));
            return glyph_x + glyphTextRangeRatio(text.text, glyph_range, offset) * advance;
        }
    }
    return line.bounds.x + line.bounds.width;
}

fn textLineExplicitGlyphOffsetForX(text: DrawText, line: TextLine, range: TextRange, x: f32, first_x: f32, dx: f32) usize {
    const glyph_end = @min(text.glyphs.len, line.glyph_start + line.glyph_len);
    for (line.glyph_start..glyph_end) |glyph_index| {
        const glyph = text.glyphs[glyph_index];
        const glyph_range = textRangeForGlyph(text.text, text.glyphs, glyph_index);
        if (glyph_range.end <= range.start or glyph_range.start >= range.end) continue;

        const glyph_x = text.origin.x + glyph.x - first_x + dx;
        if (x <= glyph_x) return @max(range.start, glyph_range.start);

        const advance = @max(1, estimatedGlyphAdvance(glyph, text.size));
        if (x < glyph_x + advance) {
            return textOffsetForGlyphRangeRatio(text.text, glyph_range, (x - glyph_x) / advance);
        }
    }
    return range.end;
}

fn glyphTextRangeRatio(text: []const u8, range: TextRange, offset: usize) f32 {
    const normalized = snapTextRange(text, range);
    if (normalized.end <= normalized.start) return 0;
    const scalar_count = utf8ScalarCount(text[normalized.start..normalized.end]);
    if (scalar_count == 0) return 0;
    const scalar_index = utf8ScalarIndexForOffset(text[normalized.start..normalized.end], offset - normalized.start);
    return @as(f32, @floatFromInt(@min(scalar_index, scalar_count))) / @as(f32, @floatFromInt(scalar_count));
}

fn textOffsetForGlyphRangeRatio(text: []const u8, range: TextRange, ratio: f32) usize {
    const normalized = snapTextRange(text, range);
    const scalar_count = utf8ScalarCount(text[normalized.start..normalized.end]);
    if (scalar_count == 0) return normalized.start;
    const clamped = std.math.clamp(if (std.math.isFinite(ratio)) ratio else 0, 0, 1);
    const scalar_index: usize = @intFromFloat(@floor(clamped * @as(f32, @floatFromInt(scalar_count)) + 0.5));
    return normalized.start + textOffsetForScalarIndex(text[normalized.start..normalized.end], @min(scalar_index, scalar_count));
}

fn textOffsetForScalarIndex(text: []const u8, scalar_index: usize) usize {
    var offset: usize = 0;
    var index: usize = 0;
    while (offset < text.len and index < scalar_index) : (index += 1) {
        offset = nextTextOffset(text, offset);
    }
    return offset;
}

fn utf8ScalarCount(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        count += 1;
        index += @min(utf8SequenceLength(text[index]), text.len - index);
    }
    return count;
}

fn unionOptionalBounds(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    if (a) |left| {
        if (b) |right| return left.normalized().unionWith(right.normalized());
        return left;
    }
    return b;
}
fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
