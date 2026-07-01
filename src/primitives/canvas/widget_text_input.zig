const std = @import("std");
const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const widget_access = @import("widget_access.zig");
const widget_metrics = @import("widget_metrics.zig");

const FontId = @import("root.zig").FontId;
const Color = drawing_model.Color;
const DrawText = text_model.DrawText;
const TextWrap = text_model.TextWrap;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextLayout = text_model.TextLayout;
const TextLine = text_model.TextLine;
const TextRange = text_model.TextRange;
const TextSelection = text_model.TextSelection;
const DesignTokens = token_model.DesignTokens;
const Widget = widget_model.Widget;
const snapTextSelection = text_model.snapTextSelection;
const snapTextRange = text_model.snapTextRange;
const nextTextLineEnd = text_model.nextTextLineEnd;
const isTextBreakByte = text_model.isTextBreakByte;
const textLineRange = text_model.textLineRange;
const textLineCaretX = text_model.textLineCaretX;
const layoutTextRun = text_model.layoutTextRun;
const textCaretRectForLayout = text_model.textCaretRectForLayout;
const layoutTextOffsetForPoint = text_model.layoutTextOffsetForPoint;

const max_widget_text_layout_lines: usize = 16;

pub fn widgetPlaceholder(widget: Widget) []const u8 {
    if (widget.placeholder.len > 0) return widget.placeholder;
    return switch (widget.kind) {
        .select, .search_field, .combobox => widget.semantics.label,
        else => "",
    };
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
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, tokens.colors.text, layout_options);
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    return layoutTextOffsetForPoint(draw_text, layout_options, point, &lines) catch null;
}

pub fn widgetTextInputSize(widget: Widget, tokens: DesignTokens) f32 {
    return widget_metrics.widgetBodyTextSize(widget, tokens);
}

pub fn widgetTextInputLayoutOptions(widget: Widget, text_size: f32, inset: f32) TextLayoutOptions {
    const line_height = widgetTextInputLineHeight(text_size);
    const trailing_inset = widgetTextInputTrailingInset(widget, text_size, inset);
    return .{
        .max_width = @max(1, widget.frame.width - inset - trailing_inset),
        .line_height = line_height,
        .wrap = widgetTextInputWrap(widget, line_height),
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

pub fn widgetTextInputOrigin(widget: Widget, tokens: DesignTokens, text_size: f32, inset: f32, options: TextLayoutOptions) geometry.PointF {
    if (options.wrap != .none) {
        const scroll_offset = widgetTextInputScrollOffset(widget, tokens, text_size, inset, options);
        return geometry.PointF.init(
            widget.frame.x + inset,
            widget.frame.y + widgetTextInputVerticalInset(widget, tokens, text_size, options) + text_size - scroll_offset,
        );
    }
    return textInputOriginForFrame(widget.frame, text_size, inset);
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
    const options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    return widgetTextInputClipRect(widget, tokens, text_size, text_inset, options);
}

pub fn textInputContentExtentForWidget(widget: Widget, tokens: DesignTokens) f32 {
    if (!widget_access.widgetTextInputKind(widget.kind)) return 0;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const line_height = widgetTextInputLineHeight(text_size);
    return @as(f32, @floatFromInt(widgetTextInputLineCount(widget, tokens.typography.font_id, text_size, options))) * line_height;
}

pub fn textInputMaxScrollOffsetForWidget(widget: Widget, tokens: DesignTokens) f32 {
    if (!widget_access.widgetTextInputKind(widget.kind)) return 0;
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    return widgetTextInputMaxScrollOffset(widget, tokens, text_size, text_inset, options);
}

pub fn clampedTextInputScrollOffsetForWidget(widget: Widget, tokens: DesignTokens, offset: f32) f32 {
    if (!widget_access.widgetTextInputKind(widget.kind)) return 0;
    return std.math.clamp(offset, 0, textInputMaxScrollOffsetForWidget(widget, tokens));
}

fn widgetTextInputMaxScrollOffset(widget: Widget, tokens: DesignTokens, text_size: f32, text_inset: f32, options: TextLayoutOptions) f32 {
    const viewport = widgetTextInputClipRect(widget, tokens, text_size, text_inset, options);
    return @max(0, textInputContentExtentForWidgetWithOptions(widget, tokens.typography.font_id, text_size, options) - viewport.height);
}

fn textInputContentExtentForWidgetWithOptions(widget: Widget, font_id: FontId, text_size: f32, options: TextLayoutOptions) f32 {
    return @as(f32, @floatFromInt(widgetTextInputLineCount(widget, font_id, text_size, options))) * widgetTextInputLineHeight(text_size);
}

fn widgetTextInputLineCount(widget: Widget, font_id: FontId, text_size: f32, options: TextLayoutOptions) usize {
    if (widget.text.len == 0) return 1;
    var count: usize = 0;
    var start: usize = 0;
    while (start <= widget.text.len) {
        const end = nextTextLineEnd(widget.text, start, font_id, text_size, options);
        count += 1;
        if (end >= widget.text.len) break;
        start = end;
        if (start < widget.text.len and widget.text[start] == '\n') start += 1;
        while (options.wrap == .word and start < widget.text.len and isTextBreakByte(widget.text[start])) start += 1;
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
        .text = widget.text,
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
    return inset;
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
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, tokens.colors.text, layout_options);

    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    const layout = layoutTextRun(draw_text, layout_options, &lines) catch return value;

    if (widget_access.widgetTextSelectionRange(widget)) |range| {
        if (range.isCollapsed(widget.text.len)) {
            value.caret_bounds = textCaretRectForLayout(draw_text, layout, range.start);
        } else {
            const bounds = textRangeBoundsForLayout(draw_text, layout, range);
            value.selection_bounds = bounds.bounds;
            value.selection_rect_count = bounds.rect_count;
        }
    }
    if (widget_access.widgetTextCompositionRange(widget)) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            const bounds = textRangeBoundsForLayout(draw_text, layout, range);
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

fn textRangeBoundsForLayout(text: DrawText, layout: TextLayout, range: TextRange) TextRangeBounds {
    const normalized = snapTextRange(text.text, range);
    if (normalized.isCollapsed(text.text.len)) return .{};

    var value: TextRangeBounds = .{};
    for (layout.lines) |line| {
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
