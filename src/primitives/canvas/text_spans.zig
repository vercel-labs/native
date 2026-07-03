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
pub const max_text_span_runs_per_paragraph: usize = 128;
pub const max_text_span_lines_per_paragraph: usize = 64;

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
    return switch (ref) {
        inline else => |tag| @field(colors, @tagName(tag)),
    };
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

/// Single-line (unwrapped) advance of the whole paragraph: the intrinsic
/// width seam for widget sizing. Measures per-span with the span's font.
pub fn textSpansIntrinsicWidth(spans: []const TextSpan, options: TextSpanLayoutOptions) f32 {
    var width: f32 = 0;
    for (spans, 0..) |span, index| {
        if (index >= max_text_spans_per_paragraph) break;
        var start: usize = 0;
        var cursor: usize = 0;
        while (cursor < span.text.len) {
            if (span.text[cursor] == '\n') {
                width += measureSpanSlice(span, span.text[start..cursor], options);
                start = cursor + 1;
            }
            cursor += 1;
        }
        width += measureSpanSlice(span, span.text[start..], options);
    }
    return width;
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
    return text_metrics.measureTextWidthForFont(
        options.measure,
        textSpanFontId(span, options.typography),
        slice,
        textSpanSize(span, options.size),
    );
}

const LayoutState = struct {
    spans: []const TextSpan,
    options: TextSpanLayoutOptions,
    runs: []TextSpanRun,
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
        if (self.run_len >= self.runs.len or self.line_index >= max_text_span_lines_per_paragraph) {
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
pub fn layoutTextSpans(spans: []const TextSpan, options: TextSpanLayoutOptions, runs_storage: []TextSpanRun) TextSpanLayout {
    var state = LayoutState{
        .spans = spans,
        .options = options,
        .runs = runs_storage,
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
        if (isSpanBreakByte(byte)) {
            const end = spanWhitespaceEnd(text, offset);
            // Whitespace at a fresh line start is consumed by the wrap;
            // mid-line whitespace is held back until the next word lands.
            if (state.line_has_content) {
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
        state.pen_x + state.pending_width + total_width > state.max_width;
    if (should_wrap_word) {
        state.breakLine();
    } else {
        state.flushPendingWhitespace();
    }

    for (pieces[0..piece_len]) |piece| {
        const slice = state.spans[piece.span_index].text[piece.start..piece.end];
        if (state.pen_x + piece.width > state.max_width) {
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
            if (state.pen_x + next_width > state.max_width) {
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
    while (end < text.len and text[end] != '\n' and !isSpanBreakByte(text[end])) end += 1;
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
