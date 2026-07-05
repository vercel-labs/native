//! Static text selection: click-drag selection within one `.text` widget
//! (plain wrapped text or a span paragraph), the primitive layer under
//! copy-from-static-text. Scope is deliberately per-widget — selection
//! state is the widget's own `text_selection` and there is no document
//! model spanning widgets, so cross-widget selection is out (documented in
//! the runtime seam). Everything here mirrors the exact layout the
//! renderer uses (`emitTextWidget` / `emitTextSpansWidget`) so hit mapping
//! and highlight rects line up with drawn glyphs.

const std = @import("std");
const geometry = @import("geometry");
const text_model = @import("text.zig");
const text_spans_model = @import("text_spans.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const widget_metrics = @import("widget_metrics.zig");

const DesignTokens = token_model.DesignTokens;
const DrawText = text_model.DrawText;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextLine = text_model.TextLine;
const TextRange = text_model.TextRange;
const TextSelection = text_model.TextSelection;
const TextSelectionRect = text_model.TextSelectionRect;
const Widget = widget_model.Widget;

/// Static paragraphs run longer than text inputs; plain-text selection
/// supports up to this many wrapped lines (beyond it, selection quietly
/// reports unsupported for the widget — layout itself still draws).
pub const max_static_text_layout_lines: usize = 64;

/// True for widgets whose text supports pointer selection without being
/// editable: `.text` leaves (plain or span paragraphs) with content.
pub fn widgetStaticTextSelectable(widget: Widget) bool {
    if (widget.kind != .text) return false;
    if (widget.id == 0 or widget.state.disabled or widget.semantics.hidden) return false;
    return widget.text.len > 0;
}

/// Selection for a pointer point over a static text widget: collapsed at
/// the hit offset on press, anchored drag extension when `anchor` is set.
pub fn staticTextSelectionForWidgetPoint(
    widget: Widget,
    point: geometry.PointF,
    anchor: ?usize,
    tokens: DesignTokens,
) ?TextSelection {
    const offset = staticTextOffsetForWidgetPoint(widget, point, tokens) orelse return null;
    const selection = if (anchor) |anchor_offset|
        TextSelection{ .anchor = anchor_offset, .focus = offset }
    else
        TextSelection.collapsed(offset);
    return text_model.snapTextSelection(widget.text, selection);
}

/// Byte offset into `widget.text` for a widget-space point, clamped to
/// the nearest line/edge so drags keep tracking outside the glyph boxes.
pub fn staticTextOffsetForWidgetPoint(widget: Widget, point: geometry.PointF, tokens: DesignTokens) ?usize {
    if (!widgetStaticTextSelectable(widget)) return null;
    if (widget.spans.len > 0) {
        const content = widget.frame.inset(widget.layout.padding);
        const options = widget_metrics.widgetTextSpanLayoutOptions(widget, tokens, content.width);
        return text_spans_model.textSpanOffsetForPoint(
            widget.text,
            widget.spans,
            options,
            geometry.PointF.init(point.x - content.x, point.y - content.y),
        );
    }
    const draw_text = staticTextDrawText(widget, tokens);
    var lines: [max_static_text_layout_lines]TextLine = undefined;
    return text_model.layoutTextOffsetForPoint(draw_text, draw_text.text_layout.?, point, &lines) catch null;
}

/// Widget-space highlight rects for a selection range over a static text
/// widget: one rect per selected line. Returns the rects that fit in
/// `output` (overflow truncates deterministically).
pub fn staticTextSelectionRects(
    widget: Widget,
    tokens: DesignTokens,
    range: TextRange,
    output: []TextSelectionRect,
) []const TextSelectionRect {
    if (widget.kind != .text or widget.text.len == 0) return output[0..0];
    if (widget.spans.len > 0) {
        const content = widget.frame.inset(widget.layout.padding);
        const options = widget_metrics.widgetTextSpanLayoutOptions(widget, tokens, content.width);
        const rects = text_spans_model.textSpanSelectionRects(widget.text, widget.spans, options, range, output);
        for (output[0..rects.len]) |*rect| {
            rect.rect.x += content.x;
            rect.rect.y += content.y;
        }
        return output[0..rects.len];
    }
    const draw_text = staticTextDrawText(widget, tokens);
    var lines: [max_static_text_layout_lines]TextLine = undefined;
    const rects = text_model.layoutTextSelectionRects(draw_text, draw_text.text_layout.?, range, &lines, output) catch return output[0..0];
    return rects;
}

/// The exact draw command `emitTextWidget` builds for a plain `.text`
/// widget (same origin math, same layout options), so selection geometry
/// and rendered glyphs share one source of truth. Color is irrelevant to
/// geometry and left at the default.
pub fn staticTextDrawText(widget: Widget, tokens: DesignTokens) DrawText {
    const text_size = widget_metrics.widgetBodyTextSize(widget, tokens);
    return .{
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, staticTextOrigin(widget.frame, text_size)),
        .color = tokens.colors.text,
        .text = widget.text,
        .text_layout = staticTextLayoutOptions(widget, tokens, text_size),
    };
}

fn staticTextLayoutOptions(widget: Widget, tokens: DesignTokens, text_size: f32) TextLayoutOptions {
    return .{
        .max_width = widget.frame.width,
        .line_height = text_size * 1.25,
        // Mirrors `emitTextWidget`: honest single-line text lays out
        // (and therefore selects/hit-maps) as the one line it paints.
        .wrap = if (widget.text_no_wrap) .none else .word,
        .alignment = widget.text_alignment,
        .measure = tokens.text_measure,
    };
}

// Mirrors `textOrigin` in widget_render.zig (private there); a divergence
// here would misalign selection against drawn text.
fn staticTextOrigin(frame: geometry.RectF, size: f32) geometry.PointF {
    const line_height = size * 1.25;
    return geometry.PointF.init(
        frame.x,
        frame.y + @max(size, (frame.height - line_height) * 0.5 + size),
    );
}

fn pixelSnapTextPoint(tokens: DesignTokens, point: geometry.PointF) geometry.PointF {
    if (!tokens.pixel_snap.text) return point;
    const scale = tokens.pixel_snap.scale;
    if (!std.math.isFinite(scale) or scale <= 0) return point;
    return geometry.PointF.init(
        @round(point.x * scale) / scale,
        @round(point.y * scale) / scale,
    );
}
