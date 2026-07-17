const std = @import("std");
const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const widget_access = @import("widget_access.zig");
const widget_metrics = @import("widget_metrics.zig");

const FontId = @import("root.zig").FontId;
const Builder = @import("commands.zig").Builder;
const Color = drawing_model.Color;
const DrawText = text_model.DrawText;
const TextWrap = text_model.TextWrap;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextRange = text_model.TextRange;
const TextSelection = text_model.TextSelection;
const DesignTokens = token_model.DesignTokens;
const Widget = widget_model.Widget;
const snapTextSelection = text_model.snapTextSelection;
const snapTextOffset = text_model.snapTextOffset;
const snapTextRange = text_model.snapTextRange;
const measureTextWidthForFont = text_model.measureTextWidthForFont;
const nextTextLineEnd = text_model.nextTextLineEnd;
const isTextBreakByte = text_model.isTextBreakByte;
const textLineRange = text_model.textLineRange;
const textLineCaretX = text_model.textLineCaretX;
const layoutTextCaretRect = text_model.layoutTextCaretRect;
const layoutTextOffsetForPoint = text_model.layoutTextOffsetForPoint;
const TextLineIterator = text_model.TextLineIterator;

pub fn widgetPlaceholder(widget: Widget) []const u8 {
    if (widget.placeholder.len > 0) return widget.placeholder;
    return switch (widget.kind) {
        .select, .search_field, .combobox => widget.semantics.label,
        else => "",
    };
}

// ---------------------------------------------------------------------------
// Single-line presentation: a single-line field NEVER paints a second line.
//
// Edits into single-line kinds are sanitized at the runtime's derivation
// seam (`sanitizedSingleLineTextInputEvent`), but the retained VALUE can
// still legitimately hold a line break — a model-set value, an old journal,
// a host API write. The honest presentation for such a value is the one
// the paint layers already give whitespace: `\n`/`\r` lay out and measure
// as a SPACE (nothing inked, one space advance) instead of breaking the
// line. The substitution is byte-for-byte (1 → 1), so every caret,
// selection, composition, and hit-test offset computed against the
// presented bytes addresses the raw value unchanged — and because the
// presented bytes contain no `\n`, the single-line layout (`wrap = .none`)
// produces exactly one line on every renderer: the GPU engine, the
// reference renderer, and packet hosts that draw engine-broken lines
// verbatim. Copy, semantics, and automation still read the RAW value.
//
// The clip is the independent second guard: `widgetTextInputClipsText`
// forces the content-rect clip whenever the raw value holds a break, so
// even a path that somehow lays out raw bytes (presentation scratch
// exhausted) stays inside the field's border.

/// The editable kinds that present single-line: every text-input kind but
/// the textarea (the one genuinely multi-line editor). Deliberately
/// includes the tall wrapping `text_field` variant — its kind contract is
/// single-line entry, and `\n`-as-space is consistent under word wrap too.
fn widgetTextInputPresentsSingleLine(kind: widget_model.WidgetKind) bool {
    return kind != .textarea and widget_access.widgetTextInputKind(kind);
}

fn textContainsLineBreakByte(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "\r\n") != null;
}

/// Whether this widget's PAINTED text differs from its raw value (a
/// single-line kind whose value holds a line break). Render emitters use
/// it to persist the presented bytes for the display list's lifetime.
pub fn widgetTextInputTextNeedsPresentation(widget: Widget) bool {
    return widgetTextInputPresentsSingleLine(widget.kind) and textContainsLineBreakByte(widget.text);
}

/// Presentation scratch, lazily heap-allocated per thread (the
/// `lazy_tls` pattern all canvas scratch uses; the event loop is
/// single-threaded): `slot` holds ONE presented text at a time — the
/// transient buffer the geometry seams (caret, selection, hit-test,
/// scroll measures) substitute into. Every entry point re-derives it,
/// and within one widget's computation repeated derivations write
/// identical bytes, so the aliasing is harmless. Sized to the runtime's
/// per-view widget-text budget (65536). Nothing EMITTED may retain a
/// slice into it: render emitters persist presented bytes into the
/// display-list builder via `persistWidgetTextInputPresentedText`, whose
/// storage lives exactly as long as the emitted commands do.
const WidgetTextPresentationScratch = struct {
    slot: [65536]u8,
};
const widget_text_presentation_scratch = @import("lazy_tls.zig").LazyTls(WidgetTextPresentationScratch);

/// The text a single-line field lays out, measures, and paints: the raw
/// value with `\n`/`\r` presented as spaces (same byte length). Returns
/// the raw slice untouched when nothing needs presenting — the
/// overwhelmingly common case costs one byte scan.
pub fn widgetTextInputPresentedText(widget: Widget) []const u8 {
    if (!widgetTextInputPresentsSingleLine(widget.kind)) return widget.text;
    return presentedSingleLineText(widget.text);
}

fn presentedSingleLineText(text: []const u8) []const u8 {
    if (!textContainsLineBreakByte(text)) return text;
    const scratch = widget_text_presentation_scratch.get();
    if (text.len > scratch.slot.len) return text;
    for (text, 0..) |byte, index| {
        scratch.slot[index] = if (byte == '\n' or byte == '\r') ' ' else byte;
    }
    return scratch.slot[0..text.len];
}

/// Persist presented bytes into the display-list BUILDER so an emitted
/// command outlives the shared slot (a later widget's presentation
/// overwrites it) — builder-owned storage, because the builder contract
/// lets a display list accumulate across several emit calls or be held
/// while another builder emits, and the emitted `draw_text` must stay
/// intact through both. Falls back to the RAW value — stable,
/// view-owned storage — when the builder's text store is full (only
/// possible on a frame already over the per-view draw-text budget); the
/// forced clip contains that fallback inside the field's border.
pub fn persistWidgetTextInputPresentedText(builder: *Builder, raw: []const u8, presented: []const u8) []const u8 {
    if (presented.ptr == raw.ptr) return raw;
    return builder.allocTextBytes(presented) catch raw;
}

pub fn textSelectionForWidgetPoint(widget: Widget, point: geometry.PointF, anchor: ?usize, tokens: DesignTokens) ?TextSelection {
    const offset = textOffsetForWidgetPoint(widget, point, tokens) orelse return null;
    const selection = if (anchor) |anchor_offset|
        TextSelection{ .anchor = anchor_offset, .focus = offset }
    else
        TextSelection.collapsed(offset);
    return snapTextSelection(widget.text, selection);
}

pub fn textOffsetForWidgetPoint(widget: Widget, point: geometry.PointF, tokens: DesignTokens) ?usize {
    if (!widget_access.widgetTextInputKind(widget.kind)) return null;
    if (widget.state.disabled) return null;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, tokens, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, tokens.colors.text, layout_options);
    return layoutTextOffsetForPoint(draw_text, layout_options, point);
}

pub fn widgetTextInputSize(widget: Widget, tokens: DesignTokens) f32 {
    return widget_metrics.widgetBodyTextSize(widget, tokens);
}

pub fn widgetTextInputLayoutOptions(widget: Widget, tokens: DesignTokens, text_size: f32, inset: f32) TextLayoutOptions {
    const line_height = widgetTextInputLineHeight(text_size);
    const trailing_inset = widgetTextInputTrailingInset(widget, text_size, inset);
    return .{
        .max_width = @max(1, widget.frame.width - inset - trailing_inset),
        .line_height = line_height,
        .wrap = widgetTextInputWrap(widget, line_height),
        // Never elide input text: a single-line field keeps its overflow
        // reachable (caret, selection, and scroll address every byte),
        // so the honest treatment is the frame clip, not an ellipsis
        // hiding the caret's own neighborhood.
        .overflow = .clip,
        .measure = tokens.text_measure,
    };
}

fn widgetTextInputLineHeight(text_size: f32) f32 {
    return widget_metrics.widgetLineHeight(text_size);
}

fn widgetTextInputWrap(widget: Widget, line_height: f32) TextWrap {
    if (widget.kind == .textarea) return .word;
    if (widget.kind == .text_field and widget.frame.height >= line_height * 2.25) return .word;
    return .none;
}

fn widgetTextInputVerticalInset(widget: Widget, tokens: DesignTokens, text_size: f32, options: TextLayoutOptions) f32 {
    if (options.wrap != .none) return widget_metrics.widgetControlInset(widget, tokens, tokens.spacing.sm);
    return @max(0, (widget.frame.height - widgetTextInputLineHeight(text_size)) * 0.5);
}

fn widgetTextInputScrollOffset(widget: Widget, tokens: DesignTokens, text_size: f32, text_inset: f32, options: TextLayoutOptions) f32 {
    if (widget.kind != .textarea) return 0;
    return std.math.clamp(widget.value, 0, widgetTextInputMaxScrollOffset(widget, tokens, text_size, text_inset, options));
}

/// Advance the horizontal scroll math reserves past the last glyph so a
/// caret parked at the end of the value lands inside the clip instead of
/// exactly on its trailing edge (the caret bar is one point wide).
const text_input_caret_reserve: f32 = 1;

/// The single-line field's horizontal scroll offset: the same retained
/// `value` channel the textarea scrolls vertically, clamped so the field
/// never shows trailing emptiness while text could fill the span. Zero
/// whenever the value fits — a short value renders exactly as an
/// unscrolled field always has.
fn widgetTextInputHorizontalScrollOffset(widget: Widget, tokens: DesignTokens, text_size: f32, text_inset: f32, options: TextLayoutOptions) f32 {
    if (options.wrap != .none) return 0;
    return std.math.clamp(widget.value, 0, widgetTextInputMaxHorizontalScrollOffset(widget, tokens, text_size, text_inset, options));
}

fn widgetTextInputMaxHorizontalScrollOffset(widget: Widget, tokens: DesignTokens, text_size: f32, text_inset: f32, options: TextLayoutOptions) f32 {
    if (options.wrap != .none or widget.text.len == 0) return 0;
    const viewport = widgetTextInputClipRect(widget, tokens, text_size, text_inset, options);
    if (viewport.width <= 0) return 0;
    // Measure the PRESENTED bytes — the ones the field lays out and
    // paints — so a value holding a line break scrolls by the same
    // single-line extent it draws.
    const text_width = measureTextWidthForFont(options.measure, tokens.typography.font_id, widgetTextInputPresentedText(widget), text_size);
    return @max(0, text_width + text_input_caret_reserve - viewport.width);
}

pub fn widgetTextInputOrigin(widget: Widget, tokens: DesignTokens, text_size: f32, inset: f32, options: TextLayoutOptions) geometry.PointF {
    if (options.wrap != .none) {
        const scroll_offset = widgetTextInputScrollOffset(widget, tokens, text_size, inset, options);
        return geometry.PointF.init(
            widget.frame.x + inset,
            widget.frame.y + widgetTextInputVerticalInset(widget, tokens, text_size, options) + text_size - scroll_offset,
        );
    }
    // Single-line fields scroll horizontally through the same origin:
    // selection rects, composition underlines, the caret, and hit-testing
    // all derive their geometry from this point, so shifting it moves
    // every text affordance together. The offset stays in logical
    // coordinates here — `widgetTextInputDrawText` snaps the final point.
    const scroll_offset = widgetTextInputHorizontalScrollOffset(widget, tokens, text_size, inset, options);
    const origin = textInputOriginForFrame(widget.frame, text_size, inset);
    return geometry.PointF.init(origin.x - scroll_offset, origin.y);
}

pub fn widgetTextInputClipRect(widget: Widget, tokens: DesignTokens, text_size: f32, inset: f32, options: TextLayoutOptions) geometry.RectF {
    const vertical_inset = widgetTextInputVerticalInset(widget, tokens, text_size, options);
    const trailing_inset = widgetTextInputTrailingInset(widget, text_size, inset);
    return widget.frame.normalized().deflate(.{
        .top = vertical_inset,
        .right = trailing_inset,
        .bottom = vertical_inset,
        .left = inset,
    });
}

pub fn textInputViewportForWidget(widget: Widget, tokens: DesignTokens) ?geometry.RectF {
    if (!widget_access.widgetTextInputKind(widget.kind)) return null;
    if (widget.state.disabled) return null;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, tokens, text_size, text_inset);
    return widgetTextInputClipRect(widget, tokens, text_size, text_inset, options);
}

pub fn textInputContentExtentForWidget(widget: Widget, tokens: DesignTokens) f32 {
    if (!widget_access.widgetTextInputKind(widget.kind)) return 0;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, tokens, text_size, text_inset);
    const line_height = widgetTextInputLineHeight(text_size);
    return @as(f32, @floatFromInt(widgetTextInputLineCount(widget, tokens.typography.font_id, text_size, options))) * line_height;
}

pub fn textInputMaxScrollOffsetForWidget(widget: Widget, tokens: DesignTokens) f32 {
    if (!widget_access.widgetTextInputKind(widget.kind)) return 0;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, tokens, text_size, text_inset);
    return widgetTextInputMaxScrollOffset(widget, tokens, text_size, text_inset, options);
}

pub fn clampedTextInputScrollOffsetForWidget(widget: Widget, tokens: DesignTokens, offset: f32) f32 {
    if (!widget_access.widgetTextInputKind(widget.kind)) return 0;
    return std.math.clamp(offset, 0, textInputMaxScrollOffsetForWidget(widget, tokens));
}

/// The furthest a single-line field may scroll horizontally: value width
/// (plus the caret's own advance) past the visible span, zero when the
/// value fits or the field wraps.
pub fn textInputMaxHorizontalScrollOffsetForWidget(widget: Widget, tokens: DesignTokens) f32 {
    if (!widget_access.widgetTextInputKind(widget.kind)) return 0;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, tokens, text_size, text_inset);
    return widgetTextInputMaxHorizontalScrollOffset(widget, tokens, text_size, text_inset, options);
}

pub fn clampedTextInputHorizontalScrollOffsetForWidget(widget: Widget, tokens: DesignTokens, offset: f32) f32 {
    if (!widget_access.widgetTextInputKind(widget.kind)) return 0;
    return std.math.clamp(offset, 0, textInputMaxHorizontalScrollOffsetForWidget(widget, tokens));
}

/// Keep-visible edge margin for the single-line caret: enough neighbor
/// glyphs stay in view to give the caret context, shrinking with the
/// field so tiny spans still fit both margins plus the caret.
fn textInputCaretVisibleMargin(viewport_width: f32) f32 {
    return @min(8, viewport_width * 0.25);
}

/// The minimally-adjusted horizontal scroll offset that keeps the
/// selection's focus end visible inside the field's content rect (with a
/// small edge margin for context). Fields whose value fits, wrapping
/// fields, and fields without a selection just clamp — the offset only
/// moves when the caret would otherwise leave the visible span.
pub fn textInputCaretVisibleScrollOffsetForWidget(widget: Widget, tokens: DesignTokens, offset: f32) f32 {
    const clamped = clampedTextInputHorizontalScrollOffsetForWidget(widget, tokens, offset);
    if (!widget_access.widgetTextInputKind(widget.kind)) return clamped;
    const selection = widget.text_selection orelse return clamped;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, tokens, text_size, text_inset);
    if (options.wrap != .none) return clamped;
    const viewport = widgetTextInputClipRect(widget, tokens, text_size, text_inset, options);
    if (viewport.width <= 0) return clamped;

    // Caret x in content (unscrolled) coordinates: the width of the value
    // up to the caret byte, measured on the same seam the line layout and
    // selection rects measure with — the PRESENTED bytes (byte offsets
    // are interchangeable: the presentation substitutes 1:1).
    const caret_offset = snapTextOffset(widget.text, selection.focus);
    const caret_x = measureTextWidthForFont(options.measure, tokens.typography.font_id, widgetTextInputPresentedText(widget)[0..caret_offset], text_size);
    const margin = textInputCaretVisibleMargin(viewport.width);
    var next = clamped;
    const scrolled_in = caret_x + text_input_caret_reserve + margin - viewport.width;
    const scrolled_back = caret_x - margin;
    if (next < scrolled_in) next = scrolled_in;
    if (next > scrolled_back) next = scrolled_back;
    return clampedTextInputHorizontalScrollOffsetForWidget(widget, tokens, next);
}

/// Whether the field's painted text needs the content-rect clip: a
/// textarea always clips (its overflow scrolls vertically), a single-line
/// field clips once its value can scroll, and an overflowing placeholder
/// clips at the same border the value would. Short values emit no clip,
/// exactly as before fields scrolled.
pub fn widgetTextInputClipsText(widget: Widget, tokens: DesignTokens, text_size: f32, text_inset: f32, options: TextLayoutOptions) bool {
    if (widget.kind == .textarea) return true;
    // A raw value holding a line break ALWAYS clips: presentation lays it
    // out as one line, but the clip is the independent guard that keeps
    // even a raw-bytes fallback (presentation scratch exhausted) from
    // painting a second line outside the field's border.
    if (widgetTextInputTextNeedsPresentation(widget)) return true;
    if (options.wrap != .none) return false;
    if (widgetTextInputMaxHorizontalScrollOffset(widget, tokens, text_size, text_inset, options) > 0) return true;
    if (widget.text.len == 0) {
        const placeholder = widgetPlaceholder(widget);
        if (placeholder.len == 0) return false;
        const viewport = widgetTextInputClipRect(widget, tokens, text_size, text_inset, options);
        return measureTextWidthForFont(options.measure, tokens.typography.font_id, placeholder, text_size) > viewport.width;
    }
    return false;
}

fn widgetTextInputMaxScrollOffset(widget: Widget, tokens: DesignTokens, text_size: f32, text_inset: f32, options: TextLayoutOptions) f32 {
    const viewport = widgetTextInputClipRect(widget, tokens, text_size, text_inset, options);
    return @max(0, textInputContentExtentForWidgetWithOptions(widget, tokens.typography.font_id, text_size, options) - viewport.height);
}

fn textInputContentExtentForWidgetWithOptions(widget: Widget, font_id: FontId, text_size: f32, options: TextLayoutOptions) f32 {
    return @as(f32, @floatFromInt(widgetTextInputLineCount(widget, font_id, text_size, options))) * widgetTextInputLineHeight(text_size);
}

fn widgetTextInputLineCount(widget: Widget, font_id: FontId, text_size: f32, options: TextLayoutOptions) usize {
    // Count lines over the PRESENTED bytes: a single-line field's value
    // holding a `\n` still lays out (and therefore extends) as one line.
    const text = widgetTextInputPresentedText(widget);
    if (text.len == 0) return 1;
    var count: usize = 0;
    var start: usize = 0;
    while (start <= text.len) {
        const end = nextTextLineEnd(text, start, font_id, text_size, options);
        count += 1;
        if (end >= text.len) break;
        start = end;
        if (start < text.len and text[start] == '\n') start += 1;
        while (options.wrap == .word and start < text.len and isTextBreakByte(text[start])) start += 1;
    }
    return @max(1, count);
}

pub fn widgetTextInputDrawText(
    widget: Widget,
    tokens: DesignTokens,
    text_size: f32,
    origin: geometry.PointF,
    color: Color,
    options: TextLayoutOptions,
) DrawText {
    return .{
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, origin),
        .color = color,
        // The presented bytes: identical to `widget.text` unless a
        // single-line field's value holds a line break (then `\n`/`\r`
        // present as spaces — one line, same byte offsets). Geometry
        // consumers (caret, selection, hit-test) and the paint emitters
        // both build from this seam, so they can never disagree.
        .text = widgetTextInputPresentedText(widget),
        .text_layout = options,
    };
}

pub fn widgetTextInputInset(widget: Widget, tokens: DesignTokens) f32 {
    const text_size = widgetTextInputSize(widget, tokens);
    return switch (widget.kind) {
        .search_field, .combobox => widget_metrics.widgetControlInset(widget, tokens, tokens.spacing.md) + @max(widget_metrics.widgetSizedDensityValue(widget, tokens, 8), text_size - 2) + widget_metrics.widgetControlInset(widget, tokens, tokens.spacing.sm),
        else => widget_metrics.widgetControlInset(widget, tokens, tokens.spacing.md),
    };
}

fn widgetTextInputTrailingInset(widget: Widget, text_size: f32, inset: f32) f32 {
    if (widget.kind == .combobox) return inset + @max(8, text_size - 4);
    // A search field holding text reserves the trailing slot for the
    // built-in clear affordance so the text never runs under the x.
    if (widgetTextInputShowsClearButton(widget)) return inset + widgetTextInputClearIconSize(text_size);
    return inset;
}

/// Whether the field currently shows the built-in trailing clear
/// affordance: search fields (the searchable kind) show it whenever they
/// hold text — zero attributes, exactly like the leading glass.
pub fn widgetTextInputShowsClearButton(widget: Widget) bool {
    return widget.kind == .search_field and widget.text.len > 0 and !widget.state.disabled;
}

fn widgetTextInputClearIconSize(text_size: f32) f32 {
    return @max(8, text_size - 4);
}

/// The clear affordance's ICON rect (the drawn x). Render and hit-test
/// share this geometry; null when the field shows no clear button.
pub fn textInputClearButtonRect(widget: Widget, tokens: DesignTokens) ?geometry.RectF {
    if (!widgetTextInputShowsClearButton(widget)) return null;
    const text_size = widgetTextInputSize(widget, tokens);
    const icon_size = widgetTextInputClearIconSize(text_size);
    const inset = widget_metrics.widgetControlInset(widget, tokens, tokens.spacing.md);
    return geometry.RectF.init(
        widget.frame.x + widget.frame.width - inset - icon_size,
        widget.frame.y + @max(0, (widget.frame.height - icon_size) * 0.5),
        icon_size,
        icon_size,
    );
}

/// The clear affordance's HIT rect: the icon zone widened to the field's
/// trailing edge and full height, so the target meets pointer-size
/// expectations without growing the drawn glyph.
pub fn textInputClearButtonHitRect(widget: Widget, tokens: DesignTokens) ?geometry.RectF {
    const icon = textInputClearButtonRect(widget, tokens) orelse return null;
    const pad = tokens.spacing.sm;
    const left = @max(widget.frame.x, icon.x - pad);
    return geometry.RectF.init(
        left,
        widget.frame.y,
        @max(0, widget.frame.x + widget.frame.width - left),
        widget.frame.height,
    );
}

pub const WidgetTextGeometry = struct {
    caret_bounds: ?geometry.RectF = null,
    selection_bounds: ?geometry.RectF = null,
    selection_rect_count: usize = 0,
    composition_bounds: ?geometry.RectF = null,
    composition_rect_count: usize = 0,
};

pub fn textGeometryForWidget(widget: Widget, tokens: DesignTokens) WidgetTextGeometry {
    var value: WidgetTextGeometry = .{};
    if (!widget_access.widgetTextInputKind(widget.kind)) return value;
    if (widget.state.disabled) return value;

    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, tokens, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, tokens.colors.text, layout_options);

    if (widget_access.widgetTextSelectionRange(widget)) |range| {
        if (range.isCollapsed(widget.text.len)) {
            value.caret_bounds = layoutTextCaretRect(draw_text, layout_options, range.start);
        } else {
            const bounds = textRangeBounds(draw_text, layout_options, range);
            value.selection_bounds = bounds.bounds;
            value.selection_rect_count = bounds.rect_count;
        }
    }
    if (widget_access.widgetTextCompositionRange(widget)) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            const bounds = textRangeBounds(draw_text, layout_options, range);
            value.composition_bounds = bounds.bounds;
            value.composition_rect_count = bounds.rect_count;
        }
    }
    return value;
}

const TextRangeBounds = struct {
    bounds: ?geometry.RectF = null,
    rect_count: usize = 0,
};

fn textRangeBounds(text: DrawText, options: TextLayoutOptions, range: TextRange) TextRangeBounds {
    const normalized = snapTextRange(text.text, range);
    if (normalized.isCollapsed(text.text.len)) return .{};

    var value: TextRangeBounds = .{};
    var lines = TextLineIterator.init(text, options);
    while (lines.next()) |line| {
        const line_range = textLineRange(text, line);
        const start = @max(normalized.start, line_range.start);
        const end = @min(normalized.end, line_range.end);
        if (start >= end) continue;

        const x0 = textLineCaretX(text, line, start);
        const x1 = textLineCaretX(text, line, end);
        const left = @min(x0, x1);
        const right = @max(x0, x1);
        value.bounds = unionOptionalBounds(
            value.bounds,
            geometry.RectF.init(left, line.bounds.y, @max(1, right - left), @max(1, line.bounds.height)),
        );
        value.rect_count += 1;
    }
    return value;
}

fn textInputOriginForFrame(frame: geometry.RectF, size: f32, inset: f32) geometry.PointF {
    const line_height = size * 1.25;
    return geometry.PointF.init(
        frame.x + inset,
        frame.y + @max(size, (frame.height - line_height) * 0.5 + size),
    );
}

fn pixelSnapScale(tokens: DesignTokens) ?f32 {
    const scale = tokens.pixel_snap.scale;
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    return scale;
}

fn pixelSnapValueWithScale(value: f32, scale: f32) f32 {
    return @round(value * scale) / scale;
}

fn pixelSnapTextPoint(tokens: DesignTokens, point: geometry.PointF) geometry.PointF {
    if (!tokens.pixel_snap.text) return point;
    const scale = pixelSnapScale(tokens) orelse return point;
    return geometry.PointF.init(
        pixelSnapValueWithScale(point.x, scale),
        pixelSnapValueWithScale(point.y, scale),
    );
}

fn unionOptionalBounds(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    if (a) |rect_a| {
        if (b) |rect_b| return geometry.RectF.unionWith(rect_a.normalized(), rect_b.normalized());
        return rect_a.normalized();
    }
    if (b) |rect_b| return rect_b.normalized();
    return null;
}
