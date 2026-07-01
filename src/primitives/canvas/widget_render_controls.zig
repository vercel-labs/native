const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const widget_access = @import("widget_access.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_text_input = @import("widget_text_input.zig");
const widget_render_style = @import("widget_render_style.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Builder = canvas.Builder;
const Color = drawing_model.Color;
const Radius = drawing_model.Radius;
const Stroke = drawing_model.Stroke;
const DrawText = text_model.DrawText;
const TextWrap = text_model.TextWrap;
const TextAlign = text_model.TextAlign;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextLine = text_model.TextLine;
const TextRange = text_model.TextRange;
const TextSelectionRect = text_model.TextSelectionRect;
const DesignTokens = token_model.DesignTokens;
const ControlVisualTokens = token_model.ControlVisualTokens;
const Widget = widget_model.Widget;

const booleanControlSelected = widget_access.booleanControlSelected;
const widgetTextSelectionRange = widget_access.widgetTextSelectionRange;
const widgetTextCompositionRange = widget_access.widgetTextCompositionRange;
const widgetPlaceholder = widget_text_input.widgetPlaceholder;
const widgetTextInputSize = widget_text_input.widgetTextInputSize;
const widgetTextInputLayoutOptions = widget_text_input.widgetTextInputLayoutOptions;
const widgetTextInputOrigin = widget_text_input.widgetTextInputOrigin;
const widgetTextInputClipRect = widget_text_input.widgetTextInputClipRect;
const widgetTextInputDrawText = widget_text_input.widgetTextInputDrawText;
const widgetTextInputInset = widget_text_input.widgetTextInputInset;
const widgetButtonTextSize = widget_metrics.widgetButtonTextSize;
const widgetBodyTextSize = widget_metrics.widgetBodyTextSize;
const widgetLabelTextSize = widget_metrics.widgetLabelTextSize;
const widgetTypographySize = widget_metrics.widgetTypographySize;
const widgetButtonInset = widget_metrics.widgetButtonInset;
const widgetControlInset = widget_metrics.widgetControlInset;
const widgetSizedDensityValue = widget_metrics.widgetSizedDensityValue;
const estimateTextWidth = text_model.estimateTextWidth;
const layoutTextCaretRect = text_model.layoutTextCaretRect;
const layoutTextSelectionRects = text_model.layoutTextSelectionRects;
const textInputAffordanceColor = widget_render_style.textInputAffordanceColor;
const textSelectionFillColor = widget_render_style.textSelectionFillColor;
const colorFill = widget_render_style.colorFill;
const widgetBackgroundFill = widget_render_style.widgetBackgroundFill;
const widgetAccentFill = widget_render_style.widgetAccentFill;
const widgetBorderFill = widget_render_style.widgetBorderFill;
const widgetFocusRingFill = widget_render_style.widgetFocusRingFill;
const widgetBackgroundColor = widget_render_style.widgetBackgroundColor;
const widgetAccentColor = widget_render_style.widgetAccentColor;
const widgetBorderColor = widget_render_style.widgetBorderColor;
const widgetForegroundColor = widget_render_style.widgetForegroundColor;
const widgetAccentForegroundColor = widget_render_style.widgetAccentForegroundColor;
const widgetRadius = widget_render_style.widgetRadius;
const controlRadius = widget_render_style.controlRadius;
const controlStrokeWidth = widget_render_style.controlStrokeWidth;
const buttonFill = widget_render_style.buttonFill;
const buttonTextColorForWidget = widget_render_style.buttonTextColorForWidget;
const buttonBorderFill = widget_render_style.buttonBorderFill;
const buttonControlVisualTokens = widget_render_style.buttonControlVisualTokens;
const selectControlVisualTokens = widget_render_style.selectControlVisualTokens;
const buttonStateBackground = widget_render_style.buttonStateBackground;
const textInputControlVisualTokens = widget_render_style.textInputControlVisualTokens;
const textInputFill = widget_render_style.textInputFill;
const textInputBorderFill = widget_render_style.textInputBorderFill;
const listItemControlVisualTokens = widget_render_style.listItemControlVisualTokens;
const selectionControlVisualTokens = widget_render_style.selectionControlVisualTokens;
const surfaceControlVisualTokens = widget_render_style.surfaceControlVisualTokens;
const buttonStrokeWidth = widget_render_style.buttonStrokeWidth;
const listItemFillColor = widget_render_style.listItemFillColor;

const max_widget_text_range_rects: usize = 4;
const max_widget_text_layout_lines: usize = 16;

fn pixelSnapScale(tokens: DesignTokens) ?f32 {
    const scale = tokens.pixel_snap.scale;
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    return scale;
}

fn pixelSnapValueWithScale(value: f32, scale: f32) f32 {
    return @round(value * scale) / scale;
}

fn pixelSnapGeometryRect(tokens: DesignTokens, rect: geometry.RectF) geometry.RectF {
    if (!tokens.pixel_snap.geometry) return rect;
    const scale = pixelSnapScale(tokens) orelse return rect;
    const normalized = rect.normalized();
    const x0 = pixelSnapValueWithScale(normalized.x, scale);
    const y0 = pixelSnapValueWithScale(normalized.y, scale);
    const x1 = pixelSnapValueWithScale(normalized.maxX(), scale);
    const y1 = pixelSnapValueWithScale(normalized.maxY(), scale);
    return geometry.RectF.init(x0, y0, @max(0, x1 - x0), @max(0, y1 - y0));
}

fn pixelSnapGeometryPoint(tokens: DesignTokens, point: geometry.PointF) geometry.PointF {
    if (!tokens.pixel_snap.geometry) return point;
    const scale = pixelSnapScale(tokens) orelse return point;
    return geometry.PointF.init(
        pixelSnapValueWithScale(point.x, scale),
        pixelSnapValueWithScale(point.y, scale),
    );
}

fn pixelSnapTextPoint(tokens: DesignTokens, point: geometry.PointF) geometry.PointF {
    if (!tokens.pixel_snap.text) return point;
    const scale = pixelSnapScale(tokens) orelse return point;
    return geometry.PointF.init(
        pixelSnapValueWithScale(point.x, scale),
        pixelSnapValueWithScale(point.y, scale),
    );
}

pub fn emitButtonWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = buttonControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetButtonTextSize(widget, tokens);
    const text_inset = widgetButtonInset(widget, tokens);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = buttonFill(widget, tokens),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = buttonBorderFill(widget, tokens),
            .width = buttonStrokeWidth(widget, tokens),
        },
    });
    if (widget.state.focused) {
        try builder.strokeRect(.{
            .id = widgetPartId(widget.id, 3),
            .rect = widget.frame,
            .radius = radius,
            .stroke = .{
                .fill = widgetFocusRingFill(widget, tokens),
                .width = tokens.stroke.focus,
            },
        });
    }
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 4),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
        .color = buttonTextColorForWidget(widget, tokens),
        .text = widget.text,
        .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .center, .none),
    });
}

pub fn emitIconButtonWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = buttonControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = buttonFill(widget, tokens),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else buttonBorderFill(widget, tokens),
            .width = if (widget.state.focused) tokens.stroke.focus else buttonStrokeWidth(widget, tokens),
        },
    });
    if (widget.text.len > 0) {
        const size = iconGlyphSize(widget, tokens);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = size,
            .origin = pixelSnapTextPoint(tokens, centeredTextOrigin(widget.frame, widget.text, size)),
            .color = buttonTextColorForWidget(widget, tokens),
            .text = widget.text,
        });
    }
}

pub fn emitSelectWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = selectControlVisualTokens(tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const chevron_size = @max(widgetSizedDensityValue(widget, tokens, 8), text_size - 4);
    const chevron_extent = chevron_size + inset;
    const text_frame = geometry.RectF.init(
        widget.frame.x + inset,
        widget.frame.y,
        @max(1, widget.frame.width - inset * 2 - chevron_extent),
        widget.frame.height,
    );
    const placeholder = widgetPlaceholder(widget);
    const visible_text = if (widget.text.len > 0) widget.text else placeholder;
    const is_placeholder = widget.text.len == 0 and placeholder.len > 0;

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    if (visible_text.len > 0) {
        const text_color = if (is_placeholder)
            widgetForegroundColor(widget, tokens, tokens.colors.text_muted)
        else
            widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(text_frame, text_size, 0)),
            .color = text_color,
            .text = visible_text,
            .text_layout = boundedTextLayout(text_frame, text_size, 0, .start, .none),
        });
    }
    try emitSelectChevron(builder, widget, tokens, visual, inset, chevron_size);
}

fn emitSelectChevron(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens, inset: f32, chevron_size: f32) Error!void {
    const center = geometry.PointF.init(widget.frame.x + widget.frame.width - inset - chevron_size * 0.5, widget.frame.y + widget.frame.height * 0.5);
    const half = chevron_size * 0.36;
    const drop = chevron_size * 0.28;
    const left = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x - half, center.y - drop * 0.5));
    const mid = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x, center.y + drop * 0.5));
    const right = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x + half, center.y - drop * 0.5));
    const stroke = Stroke{
        .fill = colorFill(widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted)),
        .width = tokens.stroke.regular,
    };
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 4), .from = left, .to = mid, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 5), .from = mid, .to = right, .stroke = stroke });
}

pub fn emitTextFieldWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = textInputControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const clip_rect = widgetTextInputClipRect(widget, tokens, text_size, text_inset, layout_options);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const text_color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, text_color, layout_options);
    const selection_range = widgetTextSelectionRange(widget);
    const composition_range = widgetTextCompositionRange(widget);
    const has_text_affordances = selection_range != null or composition_range != null;
    const clips_text = widget.kind == .textarea;

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = textInputFill(widget, tokens, visual),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else textInputBorderFill(widget, visual, tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    if (clips_text) try builder.pushClip(.{ .id = widgetPartId(widget.id, 16), .rect = clip_rect, .radius = radius });
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectionRects(builder, widget, draw_text, layout_options, range, 3, 13, max_widget_text_range_rects, tokens);
        }
    }
    const placeholder = widgetPlaceholder(widget);
    const visible_text = if (widget.text.len > 0) widget.text else placeholder;
    if (visible_text.len > 0) {
        var command = draw_text;
        command.id = widgetPartId(widget.id, if (has_text_affordances) 4 else 3);
        command.text = visible_text;
        if (widget.text.len == 0) {
            command.color = widgetForegroundColor(widget, tokens, tokens.colors.text_muted);
        }
        try builder.drawText(command);
    }
    if (composition_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextCompositionLines(builder, widget, draw_text, layout_options, range, 5, 10, max_widget_text_range_rects, tokens);
        }
    }
    if (widget.state.focused) {
        if (selection_range) |range| {
            if (range.isCollapsed(widget.text.len)) {
                try emitWidgetTextCaret(builder, widget, draw_text, layout_options, range.start, 6, tokens);
            }
        }
    }
    if (clips_text) try builder.popClip();
}

pub fn emitSearchFieldWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = textInputControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetTextInputSize(widget, tokens);
    const icon_size = @max(8, text_size - 2);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, text_size, text_inset);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const selection_range = widgetTextSelectionRange(widget);
    const composition_range = widgetTextCompositionRange(widget);
    const text_color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    const draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, text_color, layout_options);

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = textInputFill(widget, tokens, visual),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else textInputBorderFill(widget, visual, tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    try emitSearchFieldIcon(builder, widget, tokens, icon_size);
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectionRects(builder, widget, draw_text, layout_options, range, 8, 0, 1, tokens);
        }
    }
    const placeholder = widgetPlaceholder(widget);
    const visible_text = if (widget.text.len > 0) widget.text else placeholder;
    if (visible_text.len > 0) {
        var command = draw_text;
        command.id = widgetPartId(widget.id, 9);
        command.text = visible_text;
        command.color = if (widget.text.len > 0) text_color else widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted);
        try builder.drawText(command);
    }
    if (composition_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextCompositionLines(builder, widget, draw_text, layout_options, range, 10, 0, 1, tokens);
        }
    }
    if (widget.state.focused) {
        if (selection_range) |range| {
            if (range.isCollapsed(widget.text.len)) {
                try emitWidgetTextCaret(builder, widget, draw_text, layout_options, range.start, 11, tokens);
            }
        }
    }
    if (widget.kind == .combobox) {
        try emitComboboxChevron(builder, widget, tokens, visual, text_size);
    }
}

fn emitComboboxChevron(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens, text_size: f32) Error!void {
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const chevron_size = @max(widgetSizedDensityValue(widget, tokens, 8), text_size - 4);
    const center = geometry.PointF.init(widget.frame.x + widget.frame.width - inset - chevron_size * 0.5, widget.frame.y + widget.frame.height * 0.5);
    const half = chevron_size * 0.36;
    const drop = chevron_size * 0.28;
    const left = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x - half, center.y - drop * 0.5));
    const mid = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x, center.y + drop * 0.5));
    const right = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center.x + half, center.y - drop * 0.5));
    const stroke = Stroke{
        .fill = colorFill(widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted)),
        .width = tokens.stroke.regular,
    };
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 12), .from = left, .to = mid, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 13), .from = mid, .to = right, .stroke = stroke });
}

fn emitSearchFieldIcon(builder: *Builder, widget: Widget, tokens: DesignTokens, icon_size: f32) Error!void {
    const left = widget.frame.x + widgetControlInset(widget, tokens, tokens.spacing.md);
    const top = widget.frame.y + @max(0, (widget.frame.height - icon_size) * 0.5);
    const box = icon_size * 0.58;
    const p0 = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left, top));
    const p1 = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left + box, top));
    const p2 = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left + box, top + box));
    const p3 = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left, top + box));
    const tail = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left + icon_size, top + icon_size));
    const visual = textInputControlVisualTokens(widget, tokens);
    const stroke = Stroke{ .fill = colorFill(widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted)), .width = tokens.stroke.regular };

    try builder.drawLine(.{ .id = widgetPartId(widget.id, 3), .from = p0, .to = p1, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 4), .from = p1, .to = p2, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 5), .from = p2, .to = p3, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 6), .from = p3, .to = p0, .stroke = stroke });
    try builder.drawLine(.{ .id = widgetPartId(widget.id, 7), .from = p2, .to = tail, .stroke = stroke });
}

pub fn emitTooltipWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = surfaceControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const shadow_token = tokens.shadow.sm;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = widgetAccentFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.accent)),
    });
    if (widget.text.len > 0) {
        const text_size = widgetLabelTextSize(widget, tokens);
        const text_inset = widgetControlInset(widget, tokens, tokens.spacing.sm);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
            .color = widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text),
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .start, .none),
        });
    }
}

pub fn emitMenuItemWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitListItemWidget(builder, widget, tokens);
}

pub fn emitListItemWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = listItemControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const fill = listItemFillColor(widget, tokens, widget.state);
    if (fill.a > 0) {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .fill = widgetBackgroundFill(widget, fill),
        });
    }
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 2);
    const text_size = widgetBodyTextSize(widget, tokens);
    const text_inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
        .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .text = widget.text,
        .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .start, .none),
    });
}

pub fn emitDataCellWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = listItemControlVisualTokens(widget, tokens);
    const state_fill = listItemFillColor(widget, tokens, widget.state);
    if (state_fill.a > 0) {
        try builder.fillRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .fill = widgetBackgroundFill(widget, state_fill),
        });
    }
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 3);
    if (widget.text.len > 0) {
        const text_size = widgetBodyTextSize(widget, tokens);
        const text_inset = widgetControlInset(widget, tokens, tokens.spacing.md);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 4),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
            .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .start, .none),
        });
    }
}

pub fn emitSegmentedControlWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const selected = widget.state.selected or widget.value >= 0.5;
    const visual = selectionControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetLabelTextSize(widget, tokens);
    const text_inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = if (selected)
            colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent))
        else
            colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
        .color = if (selected) widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text) else widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .text = widget.text,
        .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .center, .none),
    });
}

pub fn emitCheckboxWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = selectionControlVisualTokens(widget, tokens);
    const box = checkboxWidgetBoxRect(widget, tokens);
    const selected = booleanControlSelected(widget);
    const radius = controlRadius(widget, visual, tokens.radius.sm);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = box,
        .radius = radius,
        .fill = if (selected)
            colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent))
        else
            colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = box,
        .radius = radius,
        .stroke = .{
            .fill = if (selected) widgetAccentFill(widget, visual.border orelse visual.active_background orelse tokens.colors.accent) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 3, box, radius);
    if (selected) {
        const left = pixelSnapGeometryPoint(tokens, geometry.PointF.init(box.x + box.width * 0.26, box.y + box.height * 0.54));
        const mid = pixelSnapGeometryPoint(tokens, geometry.PointF.init(box.x + box.width * 0.43, box.y + box.height * 0.70));
        const right = pixelSnapGeometryPoint(tokens, geometry.PointF.init(box.x + box.width * 0.76, box.y + box.height * 0.32));
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, 4),
            .from = left,
            .to = mid,
            .stroke = .{ .fill = colorFill(widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text)), .width = 2 },
        });
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, 5),
            .from = mid,
            .to = right,
            .stroke = .{ .fill = colorFill(widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text)), .width = 2 },
        });
    }
    try emitControlLabelWithColor(builder, widget, tokens, box.x + box.width + widgetControlInset(widget, tokens, tokens.spacing.sm), 6, visual.foreground orelse tokens.colors.text);
}

pub fn emitRadioWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = selectionControlVisualTokens(widget, tokens);
    const circle = radioWidgetCircleRect(widget, tokens);
    const selected = booleanControlSelected(widget);
    const radius = controlRadius(widget, visual, circle.height * 0.5);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = circle,
        .radius = radius,
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = circle,
        .radius = radius,
        .stroke = .{
            .fill = if (selected) widgetAccentFill(widget, visual.border orelse visual.active_background orelse tokens.colors.accent) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 3, circle, radius);
    if (selected) {
        const dot_size = @max(0, circle.height * 0.48);
        const dot = pixelSnapGeometryRect(tokens, geometry.RectF.init(
            circle.x + (circle.width - dot_size) * 0.5,
            circle.y + (circle.height - dot_size) * 0.5,
            dot_size,
            dot_size,
        ));
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 4),
            .rect = dot,
            .radius = Radius.all(dot.height * 0.5),
            .fill = colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent)),
        });
    }
    try emitControlLabelWithColor(builder, widget, tokens, circle.x + circle.width + widgetControlInset(widget, tokens, tokens.spacing.sm), 5, visual.foreground orelse tokens.colors.text);
}

pub fn emitToggleWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const selected = booleanControlSelected(widget);
    const visual = selectionControlVisualTokens(widget, tokens);
    const knob_inset = widgetSizedDensityValue(widget, tokens, 2);
    const track = toggleWidgetTrackRect(widget, tokens);
    const track_radius = controlRadius(widget, visual, track.height * 0.5);
    const knob_size = @max(0, track.height - knob_inset * 2);
    const knob_x = if (selected)
        track.x + track.width - knob_size - knob_inset
    else
        track.x + knob_inset;
    const knob = pixelSnapGeometryRect(tokens, geometry.RectF.init(knob_x, track.y + knob_inset, knob_size, knob_size));

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = track,
        .radius = track_radius,
        .fill = if (selected)
            colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent))
        else
            colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface_pressed))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = track,
        .radius = track_radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = knob,
        .radius = controlRadius(widget, visual, knob.height * 0.5),
        .fill = colorFill(if (selected) widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text) else widgetBackgroundColor(widget, visual.foreground orelse tokens.colors.surface)),
    });
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 4, track, track_radius);
    try emitControlLabelWithColor(builder, widget, tokens, track.x + track.width + widgetControlInset(widget, tokens, tokens.spacing.sm), 5, visual.foreground orelse tokens.colors.text);
}

pub fn emitSliderWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const value = std.math.clamp(widget.value, 0, 1);
    const visual = selectionControlVisualTokens(widget, tokens);
    const track = sliderWidgetTrackRect(widget, tokens);
    const active = pixelSnapGeometryRect(tokens, geometry.RectF.init(track.x, track.y, track.width * value, track.height));
    const knob = sliderWidgetKnobRect(widget, tokens);
    const track_radius = controlRadius(widget, visual, track.height * 0.5);
    const knob_radius = controlRadius(widget, visual, knob.height * 0.5);

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = track,
        .radius = track_radius,
        .fill = colorFill(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_pressed)),
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = active,
        .radius = track_radius,
        .fill = colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent)),
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = knob,
        .radius = knob_radius,
        .fill = colorFill(if (widget.state.disabled) tokens.colors.disabled else widgetBackgroundColor(widget, visual.foreground orelse tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 4),
        .rect = knob,
        .radius = knob_radius,
        .stroke = .{
            .fill = if (widget.state.focused) widgetFocusRingFill(widget, tokens) else widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = if (widget.state.focused) tokens.stroke.focus else controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    });
}

pub fn checkboxWidgetBoxRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const box_size = @min(@max(widgetSizedDensityValue(widget, tokens, 14), widget.frame.height * 0.55), widgetSizedDensityValue(widget, tokens, 20));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - box_size) * 0.5,
        box_size,
        box_size,
    ));
}

pub fn radioWidgetCircleRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const circle_size = @min(@max(widgetSizedDensityValue(widget, tokens, 14), widget.frame.height * 0.55), widgetSizedDensityValue(widget, tokens, 20));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - circle_size) * 0.5,
        circle_size,
        circle_size,
    ));
}

pub fn toggleWidgetTrackRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const track_width = @min(widget.frame.width, @max(widgetSizedDensityValue(widget, tokens, 36), widget.frame.height * 1.75));
    const track_height = @min(widget.frame.height, widgetSizedDensityValue(widget, tokens, 24));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        track_width,
        track_height,
    ));
}

fn sliderWidgetTrackRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const track_height: f32 = widgetSizedDensityValue(widget, tokens, 4);
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        widget.frame.width,
        track_height,
    ));
}

pub fn sliderWidgetKnobRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const value = std.math.clamp(widget.value, 0, 1);
    const knob_size = @min(@max(widgetSizedDensityValue(widget, tokens, 14), widget.frame.height * 0.55), widgetSizedDensityValue(widget, tokens, 20));
    const knob_x = std.math.clamp(
        widget.frame.x + widget.frame.width * value - knob_size * 0.5,
        widget.frame.x,
        widget.frame.x + @max(0, widget.frame.width - knob_size),
    );
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        knob_x,
        widget.frame.y + (widget.frame.height - knob_size) * 0.5,
        knob_size,
        knob_size,
    ));
}

pub fn emitProgressWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const progress = std.math.clamp(widget.value, 0, 1);
    const visual = selectionControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, @min(tokens.radius.md, widget.frame.height * 0.5));
    if (progress < 1) {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .fill = colorFill(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_pressed)),
        });
    }
    if (progress > 0) {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 2),
            .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(widget.frame.x, widget.frame.y, widget.frame.width * progress, widget.frame.height)),
            .radius = radius,
            .fill = colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent)),
        });
    }
}

fn emitWidgetFocusRing(builder: *Builder, widget: Widget, tokens: DesignTokens, slot: ObjectId) Error!void {
    return emitWidgetFocusRingForRect(builder, widget, tokens, slot, widget.frame, widgetRadius(widget, tokens.radius.md));
}

fn emitWidgetFocusRingForRect(builder: *Builder, widget: Widget, tokens: DesignTokens, slot: ObjectId, rect: geometry.RectF, radius: Radius) Error!void {
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, slot),
        .rect = rect,
        .radius = radius,
        .stroke = .{
            .fill = widgetFocusRingFill(widget, tokens),
            .width = tokens.stroke.focus,
        },
    });
}

fn emitControlLabelWithColor(builder: *Builder, widget: Widget, tokens: DesignTokens, x: f32, slot: ObjectId, color: Color) Error!void {
    if (widget.text.len == 0) return;
    const text_size = widgetLabelTextSize(widget, tokens);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, slot),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(labelFrameForControl(widget.frame, x), text_size, 0)),
        .color = widgetForegroundColor(widget, tokens, color),
        .text = widget.text,
        .text_layout = boundedTextLayout(labelFrameForControl(widget.frame, x), text_size, 0, .start, .none),
    });
}

fn widgetPartId(id: ObjectId, slot: ObjectId) ObjectId {
    if (id == 0) return 0;
    const base = id *% 16;
    const part = base +% slot;
    return if (part == 0) id else part;
}

fn textOrigin(frame: geometry.RectF, size: f32, inset: f32) geometry.PointF {
    const line_height = size * 1.25;
    return geometry.PointF.init(
        frame.x + inset,
        frame.y + @max(size, (frame.height - line_height) * 0.5 + size),
    );
}

fn boundedTextOrigin(frame: geometry.RectF, size: f32, inset: f32) geometry.PointF {
    return geometry.PointF.init(frame.x + inset, textOrigin(frame, size, 0).y);
}

fn boundedTextLayout(frame: geometry.RectF, size: f32, inset: f32, alignment: TextAlign, wrap: TextWrap) TextLayoutOptions {
    return .{
        .max_width = @max(1, frame.width - inset * 2),
        .line_height = size * 1.25,
        .wrap = wrap,
        .alignment = alignment,
    };
}

fn labelFrameForControl(frame: geometry.RectF, x: f32) geometry.RectF {
    return geometry.RectF.init(x, frame.y, @max(1, frame.x + frame.width - x), frame.height);
}

fn centeredTextOrigin(frame: geometry.RectF, text: []const u8, size: f32) geometry.PointF {
    return alignedTextOrigin(frame, text, size, 0, .center);
}

fn alignedTextOrigin(frame: geometry.RectF, text: []const u8, size: f32, inset: f32, alignment: TextAlign) geometry.PointF {
    const width = estimateTextWidth(text, size);
    const available_width = @max(0, frame.width - inset * 2);
    const offset = switch (alignment) {
        .start => 0,
        .center => @max(0, (available_width - width) * 0.5),
        .end => @max(0, available_width - width),
    };
    const line_height = size * 1.25;
    return geometry.PointF.init(
        frame.x + inset + offset,
        frame.y + @max(size, (frame.height - line_height) * 0.5 + size),
    );
}

fn iconGlyphSize(widget: Widget, tokens: DesignTokens) f32 {
    const min_size = widgetSizedDensityValue(widget, tokens, 12);
    if (widget.frame.height > 0) return @min(@max(min_size, widget.frame.height * widgetIconGlyphScale(widget)), @max(min_size, widgetTypographySize(widget, tokens.typography.title_size)));
    return widgetButtonTextSize(widget, tokens);
}

fn widgetIconGlyphScale(widget: Widget) f32 {
    return switch (widget.size) {
        .sm => 0.44,
        .default, .icon => 0.48,
        .lg => 0.52,
    };
}

fn emitWidgetTextSelectionRects(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    first_part: ObjectId,
    overflow_first_part: ObjectId,
    max_parts: usize,
    tokens: DesignTokens,
) Error!void {
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    var rect_buffer: [max_widget_text_range_rects]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, range, &lines, rect_buffer[0..@min(max_parts, rect_buffer.len)]);
    for (rects, 0..) |selection, index| {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, widgetTextRangePart(first_part, overflow_first_part, index)),
            .rect = pixelSnapGeometryRect(tokens, selection.rect),
            .radius = Radius.all(tokens.radius.sm),
            .fill = .{ .color = textSelectionFillColor(widget, tokens) },
        });
    }
}

fn emitWidgetTextCompositionLines(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    first_part: ObjectId,
    overflow_first_part: ObjectId,
    max_parts: usize,
    tokens: DesignTokens,
) Error!void {
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    var rect_buffer: [max_widget_text_range_rects]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, range, &lines, rect_buffer[0..@min(max_parts, rect_buffer.len)]);
    for (rects, 0..) |selection, index| {
        const y = pixelSnapGeometryRect(tokens, selection.rect).maxY() - tokens.stroke.regular;
        try builder.drawLine(.{
            .id = widgetPartId(widget.id, widgetTextRangePart(first_part, overflow_first_part, index)),
            .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(selection.rect.x, y)),
            .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(selection.rect.x + selection.rect.width, y)),
            .stroke = .{ .fill = .{ .color = textInputAffordanceColor(widget, tokens) }, .width = 1 },
        });
    }
}

fn widgetTextRangePart(first_part: ObjectId, overflow_first_part: ObjectId, index: usize) ObjectId {
    if (index == 0 or overflow_first_part == 0) return first_part + @as(ObjectId, @intCast(index));
    return overflow_first_part + @as(ObjectId, @intCast(index - 1));
}

fn emitWidgetTextCaret(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    offset: usize,
    part: ObjectId,
    tokens: DesignTokens,
) Error!void {
    var lines: [max_widget_text_layout_lines]TextLine = undefined;
    const rect = (try layoutTextCaretRect(text, options, offset, &lines)) orelse return;
    const snapped = pixelSnapGeometryRect(tokens, rect);
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, part),
        .from = geometry.PointF.init(snapped.x, snapped.y),
        .to = geometry.PointF.init(snapped.x, snapped.y + snapped.height),
        .stroke = .{ .fill = .{ .color = textInputAffordanceColor(widget, tokens) }, .width = tokens.stroke.regular },
    });
}
