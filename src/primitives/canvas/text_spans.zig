//! Inline styled text runs ("spans") within one wrapped paragraph.
//!
//! A paragraph is one logical text block whose bytes are split into up to
//! `max_text_spans_per_paragraph` spans, each carrying its own weight,
//! slant, font family (mono), color token, decorations, and optional link
//! payload. Layout is span-aware: line breaking measures every piece with
//! the font the piece will draw with (the injected `TextMeasureProvider`
//! when present, the deterministic estimator otherwise) and composes lines
//! across span boundaries.
//!
//! The layout output is a flat, capacity-bounded run list: each run is a
//! contiguous slice of one span placed on one line. Renderers draw one
//! single-line text command per run, so the entire existing text pipeline
//! (atlas, caching, GPU packet, reference renderer, platform rasterizers)
//! is reused unchanged. Weight and slant map onto the reserved sans font
//! id variants (`default_sans_bold_font_id`, ...); hosts that have not
//! mapped those ids yet fall back to the regular face, and because the
//! measurement seam carries the same font id, what is measured always
//! matches what is drawn.
//!
//! Everything here is allocation-free and deterministic. Capacity overflow
//! never fails: layout truncates (dropping trailing runs) and reports it
//! via `TextSpanLayout.truncated`.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const token_model = @import("tokens.zig");
const text_measure_cache = @import("text_measure_cache.zig");
const text_metrics = @import("text_metrics.zig");
const text_interaction = @import("text_interaction.zig");

const FontId = canvas.FontId;
const Color = @import("drawing.zig").Color;
const TextWrap = @import("text_layout_types.zig").TextWrap;
const TextAlign = @import("text_layout_types.zig").TextAlign;

/// Capacity conventions (documented in `src/runtime/canvas_limits.zig`
/// style): a paragraph carries at most this many spans; layout emits at
/// most `max_text_span_runs_per_paragraph` runs across at most
/// `max_text_span_lines_per_paragraph` lines. Overflow truncates
/// deterministically instead of failing.
pub const max_text_spans_per_paragraph: usize = 32;
pub const max_text_span_lines_per_paragraph: usize = 128;
// A maximally split highlighted paragraph can add one run at every span
// boundary in addition to one run per visual line.
pub const max_text_span_runs_per_paragraph: usize =
    max_text_span_lines_per_paragraph + max_text_spans_per_paragraph;

pub const TextSpanWeight = enum {
    regular,
    medium,
    bold,
};

/// A color design token referenced by name — the same namespace style
/// attributes use (`canvas.ColorTokenName`), so themed apps re-resolve
/// span colors on retheme without storing raw color values in the view.
pub const TextSpanColor = std.meta.FieldEnum(token_model.ColorTokens);

/// One styled run of paragraph text. `text` is the span's byte slice;
/// builders that assemble a paragraph keep every span's `text` a subslice
/// of the paragraph's concatenated plain text so retained-state copies can
/// rebase instead of duplicating bytes.
pub const TextSpan = struct {
    text: []const u8 = "",
    weight: TextSpanWeight = .regular,
    italic: bool = false,
    monospace: bool = false,
    /// Foreground override as a design-token reference. Null inherits the
    /// paragraph foreground. Link spans with no explicit color render with
    /// the accent color.
    color: ?TextSpanColor = null,
    /// Background highlight as a design-token reference. Null draws no
    /// background. Renderers fill the run's full line-box rect (the same
    /// geometry selection highlights use) behind the glyphs, so adjacent
    /// runs of the same background abut without seams. Purely visual:
    /// backgrounds never affect measurement or layout (#86, intra-line
    /// diff emphasis).
    background: ?TextSpanColor = null,
    /// Visual underline decoration. Independent from `link`: clickable
    /// spans remain undecorated unless this is true.
    underline: bool = false,
    strikethrough: bool = false,
    /// Relative size multiplier against the paragraph base size; 0 means
    /// inherit (1.0). Headings are spans with `scale` > 1 so their pixel
    /// size stays derived from live typography tokens.
    scale: f32 = 0,
    /// Link payload (URL or app-defined id). Empty means no link. Link
    /// spans are hit-testable through a paragraph link child widget and
    /// carry `role = link` semantics.
    link: []const u8 = "",
};

pub const TextSpanLayoutOptions = struct {
    /// Paragraph base font size; span `scale` multiplies it.
    size: f32,
    /// 0 derives `size * max_scale * 1.25`, matching the single-style text
    /// widget convention.
    line_height: f32 = 0,
    /// 0 (or non-finite) disables wrapping.
    max_width: f32 = 0,
    wrap: TextWrap = .word,
    alignment: TextAlign = .start,
    typography: token_model.TypographyTokens = .{},
    /// Injected measurement; null falls back to the deterministic
    /// estimator (golden-stable).
    measure: ?*const text_metrics.TextMeasureProvider = null,
};

/// One laid-out segment: a contiguous slice of one span on one line.
pub const TextSpanRun = struct {
    span_index: usize = 0,
    text: []const u8 = "",
    line_index: usize = 0,
    /// Position relative to the paragraph origin (alignment applied).
    x: f32 = 0,
    width: f32 = 0,
    /// Baseline relative to the paragraph top.
    baseline: f32 = 0,
    /// Resolved font size for this run (`size * span scale`).
    size: f32 = 0,
    font_id: FontId = 0,
};

pub const TextSpanLayout = struct {
    runs: []const TextSpanRun = &.{},
    line_count: usize = 0,
    line_height: f32 = 0,
    /// Tight paragraph bounds: max line advance x line_count*line_height.
    size: geometry.SizeF = .{},
    /// True when span, run, or line capacity truncated the layout.
    truncated: bool = false,
};

/// Resolve the font id a span draws (and therefore measures) with. Weight
/// and slant map onto the reserved sans variant ids only when the app uses
/// the default sans font; custom fonts keep their id and degrade weight to
/// the base face. Mono ignores weight/slant (a single mono face ships).
pub fn textSpanFontId(span: TextSpan, typography: token_model.TypographyTokens) FontId {
    if (span.monospace) return typography.mono_font_id;
    if (typography.font_id != canvas.default_sans_font_id) return typography.font_id;
    return switch (span.weight) {
        .regular => if (span.italic) canvas.default_sans_italic_font_id else canvas.default_sans_font_id,
        .medium => if (span.italic) canvas.default_sans_bold_italic_font_id else canvas.default_sans_medium_font_id,
        .bold => if (span.italic) canvas.default_sans_bold_italic_font_id else canvas.default_sans_bold_font_id,
    };
}

pub fn textSpanColorValue(colors: token_model.ColorTokens, ref: TextSpanColor) Color {
    return token_model.colorTokenValue(colors, ref);
}

pub fn textSpanScale(span: TextSpan) f32 {
    if (!std.math.isFinite(span.scale) or span.scale <= 0) return 1;
    return span.scale;
}

fn textSpanSize(span: TextSpan, base_size: f32) f32 {
    return base_size * textSpanScale(span);
}

/// The paragraph-wide scale: the largest span scale, so one uniform line
/// height fits every run (mixed-scale paragraphs are top-aligned to it).
pub fn textSpansMaxScale(spans: []const TextSpan) f32 {
    var max_scale: f32 = 1;
    for (spans) |span| max_scale = @max(max_scale, textSpanScale(span));
    return max_scale;
}

pub fn textSpanLineHeight(spans: []const TextSpan, options: TextSpanLayoutOptions) f32 {
    if (options.line_height > 0) return options.line_height;
    return options.size * textSpansMaxScale(spans) * 1.25;
}

/// Widest logical-line advance of an unwrapped paragraph: the intrinsic
/// width seam for widget sizing. Measures per-span with the span's font
/// while carrying each line across span boundaries.
pub fn textSpansIntrinsicWidth(spans: []const TextSpan, options: TextSpanLayoutOptions) f32 {
    var width: f32 = 0;
    var max_width: f32 = 0;
    for (spans, 0..) |span, index| {
        if (index >= max_text_spans_per_paragraph) break;
        var start: usize = 0;
        var cursor: usize = 0;
        while (cursor < span.text.len) {
            if (span.text[cursor] == '\r') {
                // CR is presentation-free. In CRLF source the following
                // LF owns the hard break; a bare CR remains selectable and
                // copyable without painting a fallback control glyph.
                width += measureSpanSlice(span, span.text[start..cursor], options);
                start = cursor + 1;
            } else if (span.text[cursor] == '\n') {
                width += measureSpanSlice(span, span.text[start..cursor], options);
                max_width = @max(max_width, width);
                width = 0;
                start = cursor + 1;
            }
            cursor += 1;
        }
        width += measureSpanSlice(span, span.text[start..], options);
    }
    return @max(max_width, width);
}

/// Wrapped paragraph height at `max_width`: the vertical-extent seam the
/// widget layout uses so stacked paragraphs reserve their real height.
pub fn textSpansWrappedHeight(spans: []const TextSpan, options: TextSpanLayoutOptions) f32 {
    var runs: [max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const layout = layoutTextSpans(spans, options, &runs);
    return layout.size.height;
}

fn measureSpanSlice(span: TextSpan, slice: []const u8, options: TextSpanLayoutOptions) f32 {
    if (slice.len == 0) return 0;
    const first_cr = std.mem.indexOfScalar(u8, slice, '\r') orelse
        return measureSpanSliceExact(span, slice, options);
    var width: f32 = 0;
    var start: usize = 0;
    var cr: ?usize = first_cr;
    while (cr) |index| {
        width += measureSpanSliceExact(span, slice[start..index], options);
        start = index + 1;
        cr = std.mem.indexOfScalarPos(u8, slice, start, '\r');
    }
    width += measureSpanSliceExact(span, slice[start..], options);
    return width;
}

fn measureSpanSliceExact(span: TextSpan, slice: []const u8, options: TextSpanLayoutOptions) f32 {
    if (slice.len == 0) return 0;
    const font_id = textSpanFontId(span, options.typography);
    const size = textSpanSize(span, options.size);
    // Batched provider path: every slice the span breaker measures is a
    // subslice of `span.text`, so one batched fetch per span (cached
    // across slices, lines, and rebuilds) answers all of them as advance
    // sums — words, held-back whitespace, cluster-wrap prefixes, and
    // selection prefixes stop costing one provider round-trip each. The
    // byte-order sum equals the per-cluster accumulation exactly
    // (continuation zeros are f32 identities), so any provider whose
    // slice widths are its advance sums breaks lines byte-identically
    // to the unbatched seam (pinned by the span parity tests).
    if (spanSliceAdvances(span, slice, options, font_id, size)) |advances| {
        var width: f32 = 0;
        for (advances) |advance| width += advance;
        return width;
    }
    return text_metrics.measureTextWidthForFont(options.measure, font_id, slice, size);
}

/// The batched advances of `slice` within its span, or null when the
/// seam is unbatched (no provider, no batched entry, host declined) or
/// `slice` does not alias `span.text` (hand-built spans). The slice
/// aliases threadlocal cache storage: consumed immediately by the one
/// caller above.
fn spanSliceAdvances(span: TextSpan, slice: []const u8, options: TextSpanLayoutOptions, font_id: FontId, size: f32) ?[]const f32 {
    const provider = options.measure orelse return null;
    if (provider.measure_advances_fn == null) return null;
    const base = @intFromPtr(span.text.ptr);
    const start = @intFromPtr(slice.ptr);
    if (start < base) return null;
    const offset = start - base;
    if (offset + slice.len > span.text.len) return null;
    const advances = text_measure_cache.textRunAdvances(provider, font_id, size, span.text) orelse return null;
    return advances[offset..][0..slice.len];
}

pub const TextSpanRunVisibleSlice = struct {
    text: []const u8,
    /// Horizontal offset from the original run origin.
    x: f32 = 0,
};

fn textSpanRunPrefixWidth(
    span: TextSpan,
    run: TextSpanRun,
    options: TextSpanLayoutOptions,
    end: usize,
) f32 {
    return measureSpanSlice(span, run.text[0..@min(end, run.text.len)], options);
}

/// First scalar boundary whose measured prefix reaches `target_x`.
/// The logarithmic search keeps long runs outside the batched-advance
/// scratch bound from turning viewport cropping into a quadratic prefix
/// walk.
fn textSpanRunBoundaryForX(
    span: TextSpan,
    run: TextSpanRun,
    options: TextSpanLayoutOptions,
    target_x: f32,
) usize {
    if (target_x <= 0) return 0;
    if (target_x >= run.width) return run.text.len;

    var low: usize = 0;
    var high = run.text.len;
    while (text_interaction.nextTextOffset(run.text, low) < high) {
        var middle = text_interaction.snapTextOffset(
            run.text,
            low + (high - low) / 2,
        );
        if (middle <= low) middle = text_interaction.nextTextOffset(run.text, low);
        if (middle >= high) middle = text_interaction.previousTextOffset(run.text, high);
        if (middle <= low or middle >= high) break;
        if (textSpanRunPrefixWidth(span, run, options, middle) < target_x) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return high;
}

fn textSpanRunScalarAdvance(
    span: TextSpan,
    run: TextSpanRun,
    options: TextSpanLayoutOptions,
    start: usize,
) f32 {
    const end = text_interaction.nextTextOffset(run.text, start);
    return @max(
        0,
        textSpanRunPrefixWidth(span, run, options, end) -
            textSpanRunPrefixWidth(span, run, options, start),
    );
}

fn textSpanRunPreviousClusterStart(
    span: TextSpan,
    run: TextSpanRun,
    options: TextSpanLayoutOptions,
    start: usize,
) usize {
    var cursor = start;
    while (cursor > 0) {
        const previous = text_interaction.previousTextOffset(run.text, cursor);
        if (textSpanRunScalarAdvance(span, run, options, previous) > 0) return previous;
        cursor = previous;
    }
    return start;
}

fn textSpanRunGuardEnd(
    span: TextSpan,
    run: TextSpanRun,
    options: TextSpanLayoutOptions,
    start: usize,
) usize {
    var cursor = start;
    var found_guard = false;
    while (cursor < run.text.len) {
        if (textSpanRunScalarAdvance(span, run, options, cursor) > 0) {
            if (found_guard) return cursor;
            found_guard = true;
        }
        cursor = text_interaction.nextTextOffset(run.text, cursor);
    }
    return run.text.len;
}

fn unbatchedTextSpanRunVisibleSlice(
    span: TextSpan,
    run: TextSpanRun,
    options: TextSpanLayoutOptions,
    min_x: f32,
    max_x: f32,
) ?TextSpanRunVisibleSlice {
    const first_boundary = textSpanRunBoundaryForX(span, run, options, @max(0, min_x));
    if (first_boundary == run.text.len and min_x >= run.width) return null;
    const visible_start = text_interaction.previousTextOffset(run.text, first_boundary);
    const first = textSpanRunPreviousClusterStart(span, run, options, visible_start);
    const last_boundary = textSpanRunBoundaryForX(span, run, options, max_x);
    const last = textSpanRunGuardEnd(span, run, options, last_boundary);
    if (first >= last) return null;
    return .{
        .text = run.text[first..last],
        .x = textSpanRunPrefixWidth(span, run, options, first),
    };
}

/// Return the measured portion of `run` needed to cover the horizontal
/// interval `[min_x, max_x]`, plus one shaped cluster of guard ink on each
/// side. Batched providers supply their exact per-cluster advances; the
/// unbatched seam uses a logarithmic contextual-prefix search. A provider
/// may represent a multi-codepoint cluster by placing its advance on the
/// first scalar and zero on the rest, so cut points are chosen only at the
/// next positive-advance cluster start.
pub fn textSpanRunVisibleSlice(
    span: TextSpan,
    run: TextSpanRun,
    options: TextSpanLayoutOptions,
    min_x: f32,
    max_x: f32,
) ?TextSpanRunVisibleSlice {
    if (run.text.len == 0) return null;
    if (!std.math.isFinite(min_x) or
        !std.math.isFinite(max_x) or
        min_x <= 0 and max_x >= run.width)
    {
        return .{ .text = run.text };
    }

    const measured_advances = spanSliceAdvances(span, run.text, options, run.font_id, run.size);
    if (measured_advances == null) {
        return unbatchedTextSpanRunVisibleSlice(span, run, options, min_x, max_x);
    }
    var cursor: usize = 0;
    var x: f32 = 0;
    var previous_cluster_start: ?usize = null;
    var previous_cluster_x: f32 = 0;
    var first: usize = 0;
    var first_x: f32 = 0;
    var found_first = false;
    var right_guard_seen = false;

    while (cursor < run.text.len) {
        const next = text_interaction.nextTextOffset(run.text, cursor);
        var advance: f32 = 0;
        for (measured_advances.?[cursor..next]) |value| advance += value;
        advance = @max(0, advance);

        if (std.math.isFinite(advance) and advance > 0) {
            if (!found_first and x + advance > @max(0, min_x)) {
                if (previous_cluster_start) |start| {
                    first = start;
                    first_x = previous_cluster_x;
                } else {
                    first = cursor;
                    first_x = x;
                }
                found_first = true;
            }

            if (found_first and x >= max_x) {
                if (right_guard_seen) {
                    if (first >= cursor) return null;
                    return .{
                        .text = run.text[first..cursor],
                        .x = first_x,
                    };
                }
                right_guard_seen = true;
            }

            previous_cluster_start = cursor;
            previous_cluster_x = x;
        }
        x += advance;
        cursor = next;
    }

    if (!found_first) {
        // A zero-width run cannot be cropped meaningfully; retain it so a
        // platform shaper still receives the original cluster sequence.
        if (x <= 0) return .{ .text = run.text };
        return null;
    }
    return .{
        .text = run.text[first..],
        .x = first_x,
    };
}

const LayoutState = struct {
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    runs: []TextSpanRun,
    /// First absolute visual line retained in `runs`. Earlier lines are
    /// still measured so the returned extent and absolute baselines stay
    /// identical to a full paragraph layout.
    run_line_start: usize = 0,
    run_len: usize = 0,
    line_index: usize = 0,
    line_run_start: usize = 0,
    pen_x: f32 = 0,
    max_line_width: f32 = 0,
    line_has_content: bool = false,
    line_height: f32 = 0,
    baseline_offset: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    truncated: bool = false,
    /// Inter-word whitespace is held back until the next word lands on the
    /// same line, so line breaks never leave trailing spaces in runs (and
    /// alignment math stays exact).
    pending_span: usize = 0,
    pending_slice: []const u8 = "",
    pending_width: f32 = 0,

    fn baseline(self: *const LayoutState) f32 {
        return self.baseline_offset + @as(f32, @floatFromInt(self.line_index)) * self.line_height;
    }

    fn recordPendingWhitespace(self: *LayoutState, span_index: usize, slice: []const u8, width: f32) void {
        self.flushPendingWhitespace();
        self.pending_span = span_index;
        self.pending_slice = slice;
        self.pending_width = width;
    }

    fn flushPendingWhitespace(self: *LayoutState) void {
        if (self.pending_slice.len == 0) return;
        const slice = self.pending_slice;
        const width = self.pending_width;
        const span_index = self.pending_span;
        self.dropPendingWhitespace();
        self.place(span_index, slice, width);
    }

    fn dropPendingWhitespace(self: *LayoutState) void {
        self.pending_slice = "";
        self.pending_width = 0;
    }

    /// Append `slice` of span `span_index` at the pen. Merges into the
    /// previous run when it continues the same span on the same line.
    fn place(self: *LayoutState, span_index: usize, slice: []const u8, width: f32) void {
        if (slice.len == 0) return;
        defer {
            self.pen_x += width;
            self.max_line_width = @max(self.max_line_width, self.pen_x);
            self.line_has_content = true;
        }
        if (self.line_index < self.run_line_start) return;
        if (self.run_len > self.line_run_start) {
            const previous = &self.runs[self.run_len - 1];
            if (previous.span_index == span_index and
                previous.line_index == self.line_index and
                previous.text.ptr + previous.text.len == slice.ptr)
            {
                previous.text = previous.text.ptr[0 .. previous.text.len + slice.len];
                previous.width += width;
                return;
            }
        }
        if (self.run_len >= self.runs.len or
            self.line_index >= self.run_line_start +| max_text_span_lines_per_paragraph)
        {
            self.truncated = true;
            return;
        }
        const span = self.spans[span_index];
        self.runs[self.run_len] = .{
            .span_index = span_index,
            .text = slice,
            .line_index = self.line_index,
            .x = self.pen_x,
            .width = width,
            .baseline = self.baseline(),
            .size = textSpanSize(span, self.options.size),
            .font_id = textSpanFontId(span, self.options.typography),
        };
        self.run_len += 1;
    }

    fn breakLine(self: *LayoutState) void {
        self.dropPendingWhitespace();
        self.alignLine();
        self.line_run_start = self.run_len;
        self.line_index += 1;
        self.pen_x = 0;
        self.line_has_content = false;
    }

    fn alignLine(self: *LayoutState) void {
        if (self.options.alignment == .start) return;
        if (!std.math.isFinite(self.max_width)) return;
        const extra = self.max_width - self.pen_x;
        if (extra <= 0) return;
        const dx = switch (self.options.alignment) {
            .start => 0,
            .center => extra * 0.5,
            .end => extra,
        };
        for (self.runs[self.line_run_start..self.run_len]) |*run| run.x += dx;
    }
};

/// Lay the paragraph out into `runs_storage`. Never fails: capacity
/// overflow truncates trailing content and sets `truncated`.
///
/// Provider-measured paragraphs ride the retained wrap cache below:
/// steady-state rebuilds of an unchanged paragraph at an unchanged
/// width rebase the cached runs onto the caller's storage without
/// measuring anything. Estimator paragraphs (measure == null) go
/// straight to the uncached breaker — that path stays byte-identical
/// to the pre-cache behavior (goldens, signatures, reference renders).
pub fn layoutTextSpans(spans: []const TextSpan, options: TextSpanLayoutOptions, runs_storage: []TextSpanRun) TextSpanLayout {
    if (options.measure != null and runs_storage.len >= max_text_span_runs_per_paragraph) {
        const cache = span_wrap_cache.get();
        const key = spanWrapKey(spans, options);
        if (findSpanWrapEntry(cache, key)) |entry_index| {
            if (rebaseSpanWrapEntry(cache, entry_index, spans, options, runs_storage)) |layout| return layout;
        }
        const layout = layoutTextSpansUncached(spans, options, 0, runs_storage);
        storeSpanWrapEntry(cache, key, spans, layout);
        return layout;
    }
    return layoutTextSpansUncached(spans, options, 0, runs_storage);
}

/// Lay out the full paragraph while retaining only the bounded visual-line
/// page beginning at `first_line`. Runs keep absolute line indexes and
/// baselines, so a viewport can paint later pages without changing the
/// paragraph's measured size or allocating source-sized storage.
pub fn layoutTextSpansFromLine(
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    first_line: usize,
    runs_storage: []TextSpanRun,
) TextSpanLayout {
    if (first_line == 0) return layoutTextSpans(spans, options, runs_storage);
    return layoutTextSpansUncached(spans, options, first_line, runs_storage);
}

fn layoutTextSpansUncached(
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    first_line: usize,
    runs_storage: []TextSpanRun,
) TextSpanLayout {
    var state = LayoutState{
        .spans = spans,
        .options = options,
        .runs = runs_storage,
        .run_line_start = first_line,
        .line_height = textSpanLineHeight(spans, options),
        .baseline_offset = options.size * textSpansMaxScale(spans),
        .max_width = if (options.wrap != .none and options.max_width > 0 and std.math.isFinite(options.max_width))
            options.max_width
        else
            std.math.inf(f32),
    };
    if (spans.len > max_text_spans_per_paragraph) state.truncated = true;
    const span_count = @min(spans.len, max_text_spans_per_paragraph);

    var span_index: usize = 0;
    var offset: usize = 0;
    while (span_index < span_count) {
        const text = spans[span_index].text;
        if (offset >= text.len) {
            span_index += 1;
            offset = 0;
            continue;
        }
        const byte = text[offset];
        if (byte == '\n') {
            state.breakLine();
            offset += 1;
            continue;
        }
        if (byte == '\r') {
            // Preserve the byte in paragraph offsets/clipboard data but do
            // not place it in a glyph run. LF remains the single hard-line
            // delimiter for both Unix and Windows source.
            offset += 1;
            continue;
        }
        if (isSpanBreakByte(byte)) {
            const end = spanWhitespaceEnd(text, offset);
            // Prose consumes whitespace at a fresh line start, but a
            // monospace span is preformatted content (markdown fences are
            // assembled from these) and must keep its source indentation.
            // In both cases whitespace is held until the next word lands,
            // so trailing spaces still never widen a rendered line.
            if (state.line_has_content or spans[span_index].monospace) {
                const slice = text[offset..end];
                state.recordPendingWhitespace(span_index, slice, measureSpanSlice(spans[span_index], slice, options));
            }
            offset = end;
            continue;
        }
        placeWord(&state, span_count, &span_index, &offset);
    }
    state.dropPendingWhitespace();
    state.alignLine();

    const line_count = state.line_index + @intFromBool(state.line_has_content or state.run_len > state.line_run_start or state.line_index == 0);
    return .{
        .runs = state.runs[0..state.run_len],
        .line_count = line_count,
        .line_height = state.line_height,
        .size = geometry.SizeF.init(
            state.max_line_width,
            @as(f32, @floatFromInt(line_count)) * state.line_height,
        ),
        .truncated = state.truncated,
    };
}

// ------------------------------------------------------------------
// Retained wrap cache (provider-measured paragraphs only).
//
// A rebuild re-lays-out every mounted paragraph whether it changed or
// not: widget layout asks for wrapped heights (often several times per
// paragraph while heights bubble), rendering lays the runs out again to
// emit commands, and interaction queries lay out once more. With a live
// measure provider each of those used to reach the host; with the
// batched advance cache they still re-break every line. This cache
// retains the RESULT: keyed on the paragraph's layout-affecting content
// (text bytes and the style fields that pick a font or size — weight,
// slant, mono, scale; colors, decorations, and links never feed
// measurement, so a retheme that only recolors keeps hitting), the base
// size, the wrap width, wrap and alignment modes, the line height, the
// typography font ids, the provider identity, and the global measure
// generation (`bumpTextMeasureGeneration`: font registration, appearance
// flips, runtime construction — the same invalidation the advance cache
// obeys).
//
// Values store runs in OFFSET form (span index + byte range) rather
// than byte slices: retained span storage is rewritten every rebuild,
// so cached pointers would dangle. A hit rebases the offsets onto the
// caller's current spans, whose bytes hash-match the key.
//
// Bounded and threadlocal like the advance cache (and the planner
// scratch in text_layout_cache.zig): least-recently-used slot eviction,
// no allocation, one cache per thread on the single-threaded frame
// path. Only requests with full-capacity run storage participate, so a
// truncated layout against a smaller caller buffer can never be served
// to (or captured from) a caller with different capacity.
// ------------------------------------------------------------------

/// Sized past the mounted hot set: a transcript screen's visible
/// paragraphs times the couple of candidate widths height bubbling asks
/// for (each wrap width is its own key). Least-recently-used eviction
/// degrades to a 100% miss rate when the steadily revisited set
/// outgrows the slots, so capacity errs generously (256 x ~4 KiB of
/// threadlocal storage).
pub const span_wrap_cache_capacity: usize = 256;

const SpanWrapKey = struct {
    fingerprint: u64 = 0,
    span_count: usize = 0,
    size_bits: u32 = 0,
    line_height_bits: u32 = 0,
    max_width_bits: u32 = 0,
    wrap: TextWrap = .word,
    alignment: TextAlign = .start,
    font_id: FontId = 0,
    mono_font_id: FontId = 0,
    provider_context: usize = 0,
    provider_fn: usize = 0,
    generation: u64 = 0,
    used: bool = false,
};

/// One cached run in offset form; `size` and `font_id` are recomputed
/// from the (hash-matched) span at rebase time, so they are not stored.
const SpanWrapRun = struct {
    span_index: u32 = 0,
    text_start: u32 = 0,
    text_len: u32 = 0,
    line_index: u32 = 0,
    x: f32 = 0,
    width: f32 = 0,
    baseline: f32 = 0,
};

const SpanWrapEntry = struct {
    key: SpanWrapKey = .{},
    run_len: usize = 0,
    line_count: usize = 0,
    line_height: f32 = 0,
    size: geometry.SizeF = .{},
    truncated: bool = false,
    last_used: u64 = 0,
};

/// The whole per-thread wrap cache behind one lazily heap-allocated
/// pointer (~1 MiB that would otherwise sit in the static TLS template
/// every OS thread's loader clones). Init happens on the first cached
/// `layoutTextSpans` call of a thread — the layout thread by
/// construction — so threads that never wrap spans never allocate it.
/// `runs` carries no default and stays uninitialized, exactly like the
/// `= undefined` static it replaces.
const SpanWrapCache = struct {
    entries: [span_wrap_cache_capacity]SpanWrapEntry = @splat(.{}),
    runs: [span_wrap_cache_capacity][max_text_span_runs_per_paragraph]SpanWrapRun,
    use_tick: u64 = 0,
    hit_count: u64 = 0,
    miss_count: u64 = 0,
};
const span_wrap_cache = @import("lazy_tls.zig").LazyTls(SpanWrapCache);

/// Cache observability for tests and benchmarks.
pub fn textSpanWrapCacheHitCount() u64 {
    const cache = span_wrap_cache.peek() orelse return 0;
    return cache.hit_count;
}

pub fn textSpanWrapCacheMissCount() u64 {
    const cache = span_wrap_cache.peek() orelse return 0;
    return cache.miss_count;
}

fn spanWrapKey(spans: []const TextSpan, options: TextSpanLayoutOptions) SpanWrapKey {
    var hasher = std.hash.Wyhash.init(0x7370616e77726170);
    const span_count = @min(spans.len, max_text_spans_per_paragraph);
    for (spans[0..span_count]) |span| {
        // Length prefix keeps concatenation honest ("ab"+"c" never
        // hashes like "a"+"bc"); only layout-affecting style fields
        // fold in (see the module comment above).
        hasher.update(std.mem.asBytes(&span.text.len));
        hasher.update(span.text);
        hasher.update(&[_]u8{
            @intFromEnum(span.weight),
            @intFromBool(span.italic),
            @intFromBool(span.monospace),
        });
        hasher.update(std.mem.asBytes(&span.scale));
    }
    const provider = options.measure.?;
    return .{
        .fingerprint = hasher.final(),
        .span_count = spans.len,
        .size_bits = @bitCast(options.size),
        .line_height_bits = @bitCast(options.line_height),
        .max_width_bits = @bitCast(options.max_width),
        .wrap = options.wrap,
        .alignment = options.alignment,
        .font_id = options.typography.font_id,
        .mono_font_id = options.typography.mono_font_id,
        .provider_context = @intFromPtr(provider.context),
        .provider_fn = @intFromPtr(provider.measure_fn),
        .generation = text_measure_cache.textMeasureGeneration(),
        .used = true,
    };
}

fn spanWrapKeysEqual(a: SpanWrapKey, b: SpanWrapKey) bool {
    return a.used and b.used and
        a.fingerprint == b.fingerprint and
        a.span_count == b.span_count and
        a.size_bits == b.size_bits and
        a.line_height_bits == b.line_height_bits and
        a.max_width_bits == b.max_width_bits and
        a.wrap == b.wrap and
        a.alignment == b.alignment and
        a.font_id == b.font_id and
        a.mono_font_id == b.mono_font_id and
        a.provider_context == b.provider_context and
        a.provider_fn == b.provider_fn and
        a.generation == b.generation;
}

fn findSpanWrapEntry(cache: *SpanWrapCache, key: SpanWrapKey) ?usize {
    for (&cache.entries, 0..) |*entry, index| {
        if (spanWrapKeysEqual(entry.key, key)) {
            cache.use_tick += 1;
            entry.last_used = cache.use_tick;
            cache.hit_count += 1;
            return index;
        }
    }
    cache.miss_count += 1;
    return null;
}

fn storeSpanWrapEntry(cache: *SpanWrapCache, key: SpanWrapKey, spans: []const TextSpan, layout: TextSpanLayout) void {
    if (layout.runs.len > max_text_span_runs_per_paragraph) return;
    // Offsets require every run to alias its span's bytes; the breaker
    // only ever emits subslices of span.text, so a failure here would be
    // a bug upstream — decline to cache rather than store a lie.
    for (layout.runs) |run| {
        if (spanRunOffset(spans, run) == null) return;
    }

    var victim: usize = 0;
    var victim_tick: u64 = std.math.maxInt(u64);
    for (&cache.entries, 0..) |*entry, index| {
        const tick = if (entry.key.used) entry.last_used else 0;
        if (tick < victim_tick) {
            victim_tick = tick;
            victim = index;
        }
    }
    cache.use_tick += 1;
    for (layout.runs, 0..) |run, run_index| {
        const offset = spanRunOffset(spans, run).?;
        cache.runs[victim][run_index] = .{
            .span_index = @intCast(run.span_index),
            .text_start = @intCast(offset),
            .text_len = @intCast(run.text.len),
            .line_index = @intCast(run.line_index),
            .x = run.x,
            .width = run.width,
            .baseline = run.baseline,
        };
    }
    cache.entries[victim] = .{
        .key = key,
        .run_len = layout.runs.len,
        .line_count = layout.line_count,
        .line_height = layout.line_height,
        .size = layout.size,
        .truncated = layout.truncated,
        .last_used = cache.use_tick,
    };
}

fn spanRunOffset(spans: []const TextSpan, run: TextSpanRun) ?usize {
    if (run.span_index >= spans.len) return null;
    const base = @intFromPtr(spans[run.span_index].text.ptr);
    const start = @intFromPtr(run.text.ptr);
    if (start < base) return null;
    const offset = start - base;
    if (offset + run.text.len > spans[run.span_index].text.len) return null;
    return offset;
}

/// Materialize a cached layout onto the caller's storage: run slices
/// rebase onto the CURRENT spans' bytes (hash-matched to the cached
/// paragraph), per-run size and font id re-derive from the span and
/// typography exactly as the breaker derives them. Null when a cached
/// offset does not fit the current spans — only reachable through a
/// content-hash collision, and answered by re-laying-out instead of
/// serving mismatched geometry.
fn rebaseSpanWrapEntry(cache: *SpanWrapCache, entry_index: usize, spans: []const TextSpan, options: TextSpanLayoutOptions, runs_storage: []TextSpanRun) ?TextSpanLayout {
    const entry = &cache.entries[entry_index];
    for (cache.runs[entry_index][0..entry.run_len]) |cached| {
        if (cached.span_index >= spans.len) return null;
        if (cached.text_start + cached.text_len > spans[cached.span_index].text.len) return null;
    }
    for (cache.runs[entry_index][0..entry.run_len], 0..) |cached, run_index| {
        const span = spans[cached.span_index];
        runs_storage[run_index] = .{
            .span_index = cached.span_index,
            .text = span.text[cached.text_start .. cached.text_start + cached.text_len],
            .line_index = cached.line_index,
            .x = cached.x,
            .width = cached.width,
            .baseline = cached.baseline,
            .size = textSpanSize(span, options.size),
            .font_id = textSpanFontId(span, options.typography),
        };
    }
    return .{
        .runs = runs_storage[0..entry.run_len],
        .line_count = entry.line_count,
        .line_height = entry.line_height,
        .size = entry.size,
        .truncated = entry.truncated,
    };
}

const max_word_pieces = max_text_spans_per_paragraph;

const WordPiece = struct {
    span_index: usize,
    start: usize,
    end: usize,
    width: f32,
};

/// Collect the word starting at (span_index, offset) — consecutive
/// non-break pieces, crossing span boundaries when no whitespace divides
/// them — measure it, and place it with word wrapping. Words wider than
/// the wrap width fall back to cluster wrapping.
fn placeWord(state: *LayoutState, span_count: usize, span_index: *usize, offset: *usize) void {
    var pieces: [max_word_pieces]WordPiece = undefined;
    var piece_len: usize = 0;
    var total_width: f32 = 0;

    var cursor_span = span_index.*;
    var cursor_offset = offset.*;
    while (cursor_span < span_count and piece_len < pieces.len) {
        const text = state.spans[cursor_span].text;
        if (cursor_offset >= text.len) {
            cursor_span += 1;
            cursor_offset = 0;
            continue;
        }
        if (text[cursor_offset] == '\n' or isSpanBreakByte(text[cursor_offset])) break;
        const end = spanWordEnd(text, cursor_offset);
        const width = measureSpanSlice(state.spans[cursor_span], text[cursor_offset..end], state.options);
        pieces[piece_len] = .{ .span_index = cursor_span, .start = cursor_offset, .end = end, .width = width };
        piece_len += 1;
        total_width += width;
        cursor_offset = end;
    }

    const should_wrap_word = state.options.wrap == .word and
        state.line_has_content and
        state.pen_x + state.pending_width + total_width > state.max_width + span_break_slack;
    if (should_wrap_word) {
        state.breakLine();
    } else {
        state.flushPendingWhitespace();
    }

    for (pieces[0..piece_len]) |piece| {
        const slice = state.spans[piece.span_index].text[piece.start..piece.end];
        if (state.pen_x + piece.width > state.max_width + span_break_slack) {
            placeClusterWrapped(state, piece.span_index, slice);
        } else {
            state.place(piece.span_index, slice, piece.width);
        }
    }

    span_index.* = cursor_span;
    offset.* = cursor_offset;
}

/// Cluster-granularity wrapping for pieces wider than the remaining line
/// (single oversized words, and `wrap == .character`). Prefix widths are
/// measured through the same provider seam so kerning is honored.
fn placeClusterWrapped(state: *LayoutState, span_index: usize, slice: []const u8) void {
    const span = state.spans[span_index];
    var start: usize = 0;
    while (start < slice.len) {
        var end = start;
        var width: f32 = 0;
        while (end < slice.len) {
            const next = text_interaction.nextTextOffset(slice, end);
            const next_width = measureSpanSlice(span, slice[start..next], state.options);
            if (state.pen_x + next_width > state.max_width + span_break_slack) {
                if (end == start and !state.line_has_content) {
                    // A single cluster wider than the line still occupies it.
                    end = next;
                    width = next_width;
                }
                break;
            }
            end = next;
            width = next_width;
        }
        if (end == start) {
            state.breakLine();
            continue;
        }
        state.place(span_index, slice[start..end], width);
        start = end;
        if (start < slice.len) state.breakLine();
    }
}

/// Line-break tolerance absorbing f32 association noise. Intrinsic sizing
/// measures a paragraph as whole slices while the breaker accumulates
/// per-word (and per-cluster) measures, and the two sums can differ by an
/// ulp (~1e-5 px on a realistic line) purely from addition order — enough
/// to re-wrap a paragraph laid out at exactly its measured intrinsic
/// width, painting its last word over the content below. 1/64 px is
/// orders of magnitude above that noise and far below any real glyph
/// advance, so genuine overflow still breaks exactly as before.
const span_break_slack: f32 = 0.015625;

fn isSpanBreakByte(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn spanWhitespaceEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and isSpanBreakByte(text[end])) end += 1;
    return end;
}

fn spanWordEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and text[end] != '\n' and text[end] != '\r' and !isSpanBreakByte(text[end])) end += 1;
    return end;
}

/// Union bounds (relative to the paragraph origin) of every run belonging
/// to `span_index`. Frames link hit areas; a link that wraps across lines
/// gets the union rect of its segments (v1 caveat: for wrapped links this
/// includes the horizontal stretch between line fragments).
pub fn textSpanBounds(layout: TextSpanLayout, span_index: usize) ?geometry.RectF {
    var bounds: ?geometry.RectF = null;
    for (layout.runs) |run| {
        if (run.span_index != span_index) continue;
        const rect = textSpanRunBounds(layout, run);
        bounds = if (bounds) |existing| existing.unionWith(rect) else rect;
    }
    return bounds;
}

/// Bounds of a single run (relative to the paragraph origin), spanning
/// the full line box height so hit areas cover the whole line.
pub fn textSpanRunBounds(layout: TextSpanLayout, run: TextSpanRun) geometry.RectF {
    const top = @as(f32, @floatFromInt(run.line_index)) * layout.line_height;
    return geometry.RectF.init(run.x, top, run.width, layout.line_height);
}

/// Byte range of `run` inside the paragraph's concatenated plain text.
/// Builders (`ui.paragraph`, markdown) keep every span's bytes a subslice
/// of the paragraph text, so a run's offsets fall out of pointer
/// arithmetic; hand-built spans that alias other storage return null and
/// selection quietly degrades to unsupported for that paragraph.
pub fn textSpanRunParagraphRange(paragraph: []const u8, run: TextSpanRun) ?text_interaction.TextRange {
    if (run.text.len == 0 or paragraph.len == 0) return null;
    const base = @intFromPtr(paragraph.ptr);
    const run_start = @intFromPtr(run.text.ptr);
    if (run_start < base) return null;
    const start = run_start - base;
    const end = start + run.text.len;
    if (end > paragraph.len) return null;
    return text_interaction.TextRange.init(start, end);
}

/// Paragraph byte offset for a point relative to the paragraph origin.
/// Clamps vertically to the nearest line and horizontally to that line's
/// run edges, so drag selection keeps working when the pointer leaves the
/// text. Null when the paragraph has no runs or its spans do not index
/// into `paragraph` (see `textSpanRunParagraphRange`).
pub fn textSpanOffsetForPoint(
    paragraph: []const u8,
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    point: geometry.PointF,
) ?usize {
    var runs: [max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    var layout = layoutTextSpans(spans, options, &runs);
    if (layout.line_count == 0 or layout.line_height <= 0) return null;

    const raw_line = point.y / layout.line_height;
    const max_line = layout.line_count - 1;
    const line_index: usize = if (raw_line < 0)
        0
    else
        @min(max_line, @as(usize, @intFromFloat(@floor(raw_line))));

    // Page the same bounded paragraph layout the viewport painter uses.
    // Page zero deliberately retains only 128 visual lines; without this
    // handoff every point below that page collapsed onto its last source
    // offset even though later runs were visibly painted.
    if (line_index >= max_text_span_lines_per_paragraph) {
        layout = layoutTextSpansFromLine(spans, options, line_index, &runs);
    }
    if (layout.runs.len == 0) {
        // Preformatted whitespace is valid selectable source even though
        // the layout deliberately keeps it out of painted runs. Preserve
        // both edges so a drag can select/copy an all-whitespace block.
        if (paragraphOnlyUnpaintedWhitespace(paragraph)) {
            const source_line_count = 1 + std.mem.count(u8, paragraph, "\n") -
                @intFromBool(paragraph[paragraph.len - 1] == '\n');
            const source_line: usize = if (raw_line < 0)
                0
            else
                @min(source_line_count - 1, @as(usize, @intFromFloat(@floor(raw_line))));
            const edge = unpaintedWhitespaceLineRange(paragraph, source_line);
            const width = textSpanParagraphRangeWidth(
                paragraph,
                spans,
                options,
                text_interaction.TextRange.init(
                    edge.start,
                    if (edge.end > edge.start and paragraph[edge.end - 1] == '\n')
                        edge.end - 1
                    else
                        edge.end,
                ),
            ) orelse 0;
            const midpoint = if (width > 0)
                width * 0.5
            else if (options.max_width > 0 and std.math.isFinite(options.max_width))
                options.max_width * 0.5
            else
                0;
            return if (point.x < midpoint) edge.start else edge.end;
        }
        // A later page made only of trailing blank logical lines has no
        // glyph run to map. Its nearest source edge is the paragraph end.
        return if (paragraph.len > 0) paragraph.len else null;
    }

    var result: ?usize = null;
    var first_range: ?text_interaction.TextRange = null;
    var last_range: ?text_interaction.TextRange = null;
    var first_x: f32 = 0;
    var last_end_x: f32 = 0;
    for (layout.runs) |run| {
        if (run.line_index != line_index) continue;
        const range = textSpanRunParagraphRange(paragraph, run) orelse return null;
        if (first_range == null) {
            first_range = range;
            first_x = run.x;
        }
        last_range = range;
        last_end_x = run.x + run.width;
        if (point.x >= run.x and point.x < run.x + run.width) {
            result = range.start + spanRunOffsetForX(spans[run.span_index], run, options, point.x - run.x);
        }
    }
    if (result) |offset| return offset;
    const first = first_range orelse return lineFallbackOffset(paragraph, layout, line_index);
    if (point.x < first_x) return first.start;
    if (last_range) |last| {
        if (point.x >= last_end_x) return textSpanLineSourceEnd(paragraph, last.end);
    }
    return first.start;
}

fn paragraphOnlyUnpaintedWhitespace(paragraph: []const u8) bool {
    if (paragraph.len == 0) return false;
    for (paragraph) |byte| {
        if (byte != '\n' and byte != '\r' and !isSpanBreakByte(byte)) return false;
    }
    return true;
}

fn unpaintedWhitespaceLineRange(paragraph: []const u8, line_index: usize) text_interaction.TextRange {
    var start: usize = 0;
    var line: usize = 0;
    while (line < line_index) : (line += 1) {
        const newline = std.mem.indexOfScalarPos(u8, paragraph, start, '\n') orelse
            return text_interaction.TextRange.init(paragraph.len, paragraph.len);
        start = newline + 1;
    }
    const newline = std.mem.indexOfScalarPos(u8, paragraph, start, '\n');
    return text_interaction.TextRange.init(start, if (newline) |index| index + 1 else paragraph.len);
}

fn textSpanParagraphRangeWidth(
    paragraph: []const u8,
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    range: text_interaction.TextRange,
) ?f32 {
    if (range.start >= range.end) return 0;
    const paragraph_base = @intFromPtr(paragraph.ptr);
    var covered = range.start;
    var width: f32 = 0;
    for (spans) |span| {
        const span_start_ptr = @intFromPtr(span.text.ptr);
        if (span_start_ptr < paragraph_base) return null;
        const span_start = span_start_ptr - paragraph_base;
        const span_end = span_start + span.text.len;
        if (span_end > paragraph.len) return null;
        const start = @max(range.start, span_start);
        const end = @min(range.end, span_end);
        if (start >= end) continue;
        if (start > covered) return null;
        width += measureSpanSlice(
            span,
            span.text[start - span_start .. end - span_start],
            options,
        );
        covered = @max(covered, end);
        if (covered >= range.end) return width;
    }
    return null;
}

/// Extend a painted run edge through source bytes that deliberately carry
/// no ink at the end of its visual line: spaces/tabs and one explicit
/// newline. A wrapped word begins the next line without being consumed.
fn textSpanLineSourceEnd(paragraph: []const u8, painted_end: usize) usize {
    var end = @min(painted_end, paragraph.len);
    while (end < paragraph.len and isSpanBreakByte(paragraph[end])) end += 1;
    if (end < paragraph.len and paragraph[end] == '\r') end += 1;
    if (end < paragraph.len and paragraph[end] == '\n') end += 1;
    return end;
}

/// Offset within `run.text` for a run-relative x, midpoint rule per
/// codepoint, mirroring the plain-text `textLineOffsetForX`.
fn spanRunOffsetForX(span: TextSpan, run: TextSpanRun, options: TextSpanLayoutOptions, x: f32) usize {
    if (x <= 0) return 0;
    var cursor: usize = 0;
    var caret_x: f32 = 0;
    while (cursor < run.text.len) {
        const next_cursor = text_interaction.nextTextOffset(run.text, cursor);
        const next_x = @max(caret_x + 1, measureSpanSlice(span, run.text[0..next_cursor], options));
        if (x < (caret_x + next_x) * 0.5) return cursor;
        caret_x = next_x;
        cursor = next_cursor;
    }
    return run.text.len;
}

/// When a line exists but has no runs (blank line from an explicit "\n"),
/// selection lands on the nearest following run's start; an entirely
/// runless paragraph cannot happen here (guarded by the caller).
fn lineFallbackOffset(paragraph: []const u8, layout: TextSpanLayout, line_index: usize) ?usize {
    for (layout.runs) |run| {
        if (run.line_index < line_index) continue;
        const range = textSpanRunParagraphRange(paragraph, run) orelse return null;
        return range.start;
    }
    for (0..layout.runs.len) |back| {
        const run = layout.runs[layout.runs.len - 1 - back];
        const range = textSpanRunParagraphRange(paragraph, run) orelse return null;
        return range.end;
    }
    return null;
}

/// Selection highlight rects (relative to the paragraph origin) for a
/// paragraph byte range: one rect per line, spanning the selected extent
/// across that line's runs. A range spanning more lines than `output`
/// holds folds the overflow into the last rectangle, matching plain text
/// selection so long selections stay truthfully highlighted.
pub fn textSpanSelectionRects(
    paragraph: []const u8,
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    range: text_interaction.TextRange,
    output: []text_interaction.TextSelectionRect,
) []const text_interaction.TextSelectionRect {
    const normalized = text_interaction.snapTextRange(paragraph, range);
    if (normalized.isCollapsed(paragraph.len)) return output[0..0];
    if (output.len == 0) return output[0..0];

    var runs: [max_text_span_runs_per_paragraph]TextSpanRun = undefined;
    const first_layout = layoutTextSpans(spans, options, &runs);
    if (first_layout.line_height <= 0 or first_layout.line_count == 0) return output[0..0];

    const page_count = (first_layout.line_count +
        max_text_span_lines_per_paragraph - 1) /
        max_text_span_lines_per_paragraph;
    const first_page = textSpanSelectionFirstPage(
        paragraph,
        spans,
        options,
        normalized.start,
        page_count,
        &runs,
    ) orelse return output[0..0];
    var len: usize = 0;
    var page_index = first_page;
    while (page_index < page_count) : (page_index += 1) {
        const first_line = page_index * max_text_span_lines_per_paragraph;
        const layout = if (page_index == 0)
            first_layout
        else
            layoutTextSpansFromLine(spans, options, first_line, &runs);
        const page_end = appendTextSpanSelectionPage(
            paragraph,
            spans,
            options,
            normalized,
            layout,
            output,
            &len,
        );
        if (page_end >= normalized.end) break;
    }
    return output[0..len];
}

/// Earliest visual-line page whose retained source runs can intersect a
/// selection beginning at `offset`. Non-empty pages stay logarithmic; when
/// explicit newlines create an empty page, inspect the surrounding gap
/// because emptiness alone does not order that page against the offset.
fn textSpanSelectionFirstPage(
    paragraph: []const u8,
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    offset: usize,
    page_count: usize,
    runs: []TextSpanRun,
) ?usize {
    var low: usize = 0;
    var high = page_count;
    var candidate: ?usize = null;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const page_end = textSpanSelectionPageEnd(
            paragraph,
            spans,
            options,
            middle,
            runs,
        );
        if (page_end) |end| {
            if (end <= offset) {
                low = middle + 1;
            } else {
                candidate = middle;
                high = middle;
            }
            continue;
        }

        // A runless page may sit between source before and after `offset`.
        // Find its nearest retained neighbor on each side before deciding
        // which half can be discarded.
        var left = middle;
        var left_end: ?usize = null;
        while (left > low) {
            left -= 1;
            left_end = textSpanSelectionPageEnd(
                paragraph,
                spans,
                options,
                left,
                runs,
            );
            if (left_end != null) break;
        }
        if (left_end) |end| {
            if (end > offset) {
                candidate = left;
                high = left;
                continue;
            }
        }

        var right = middle + 1;
        var right_end: ?usize = null;
        while (right < high) : (right += 1) {
            right_end = textSpanSelectionPageEnd(
                paragraph,
                spans,
                options,
                right,
                runs,
            );
            if (right_end != null) break;
        }
        if (right_end) |end| {
            if (end > offset) return right;
            low = right + 1;
            continue;
        }

        // No retained run in this interval precedes the best page already
        // found by the binary search.
        return candidate;
    }
    return candidate;
}

fn textSpanSelectionPageEnd(
    paragraph: []const u8,
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    page_index: usize,
    runs: []TextSpanRun,
) ?usize {
    const layout = layoutTextSpansFromLine(
        spans,
        options,
        page_index * max_text_span_lines_per_paragraph,
        runs,
    );
    var page_end: ?usize = null;
    for (layout.runs) |run| {
        const run_range = textSpanRunParagraphRange(paragraph, run) orelse continue;
        page_end = @max(page_end orelse 0, run_range.end);
    }
    return page_end;
}

/// Append selection geometry from one absolute visual-line page. Returns
/// the furthest paragraph byte represented by that page so the caller can
/// stop once the selected tail has been covered.
fn appendTextSpanSelectionPage(
    paragraph: []const u8,
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    normalized: text_interaction.TextRange,
    layout: TextSpanLayout,
    output: []text_interaction.TextSelectionRect,
    len: *usize,
) usize {
    var page_end: usize = 0;
    var current_line: ?usize = null;
    var line_left: f32 = 0;
    var line_right: f32 = 0;
    var line_range = text_interaction.TextRange.init(0, 0);
    for (layout.runs) |run| {
        const run_range = textSpanRunParagraphRange(paragraph, run) orelse continue;
        page_end = @max(page_end, run_range.end);
        const start = @max(normalized.start, run_range.start);
        const end = @min(normalized.end, run_range.end);
        if (start >= end) continue;

        const span = spans[run.span_index];
        const x0 = run.x + measureSpanSlice(span, run.text[0 .. start - run_range.start], options);
        const x1 = run.x + measureSpanSlice(span, run.text[0 .. end - run_range.start], options);
        if (current_line) |line| {
            if (line == run.line_index) {
                line_left = @min(line_left, @min(x0, x1));
                line_right = @max(line_right, @max(x0, x1));
                line_range = text_interaction.TextRange.init(@min(line_range.start, start), @max(line_range.end, end));
                continue;
            }
            flushSpanSelectionLine(layout, line, line_left, line_right, line_range, output, len);
        }
        current_line = run.line_index;
        line_left = @min(x0, x1);
        line_right = @max(x0, x1);
        line_range = text_interaction.TextRange.init(start, end);
    }
    if (current_line) |line| {
        flushSpanSelectionLine(layout, line, line_left, line_right, line_range, output, len);
    }
    return page_end;
}

fn flushSpanSelectionLine(
    layout: TextSpanLayout,
    line_index: usize,
    left: f32,
    right: f32,
    range: text_interaction.TextRange,
    output: []text_interaction.TextSelectionRect,
    len: *usize,
) void {
    const top = @as(f32, @floatFromInt(line_index)) * layout.line_height;
    const selection = text_interaction.TextSelectionRect{
        .range = range,
        .rect = geometry.RectF.init(left, top, @max(1, right - left), @max(1, layout.line_height)),
    };
    if (len.* >= output.len) {
        const last = &output[output.len - 1];
        last.range = text_interaction.TextRange.init(last.range.start, range.end);
        last.rect = last.rect.unionWith(selection.rect);
        return;
    }
    output[len.*] = selection;
    len.* += 1;
}

/// Deep equality for widget invalidation: styles, text bytes, and link
/// payload bytes.
pub fn textSpansEqual(a: []const TextSpan, b: []const TextSpan) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.text, right.text)) return false;
        if (left.weight != right.weight) return false;
        if (left.italic != right.italic) return false;
        if (left.monospace != right.monospace) return false;
        if (left.color != right.color) return false;
        if (left.background != right.background) return false;
        if (left.underline != right.underline) return false;
        if (left.strikethrough != right.strikethrough) return false;
        if (left.scale != right.scale) return false;
        if (!std.mem.eql(u8, left.link, right.link)) return false;
    }
    return true;
}

/// True when any span carries a link payload.
pub fn textSpansHaveLinks(spans: []const TextSpan) bool {
    for (spans) |span| {
        if (span.link.len > 0) return true;
    }
    return false;
}

pub fn textSpanLinkCount(spans: []const TextSpan) usize {
    var count: usize = 0;
    for (spans) |span| {
        if (span.link.len > 0) count += 1;
    }
    return count;
}
