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
const widget_render = @import("widget_render.zig");
const icon_model = @import("icons.zig");
const svg_icon_model = @import("svg_icon.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Builder = canvas.Builder;
const Affine = drawing_model.Affine;
const Color = drawing_model.Color;
const Radius = drawing_model.Radius;
const Stroke = drawing_model.Stroke;
const DrawText = text_model.DrawText;
const TextWrap = text_model.TextWrap;
const TextOverflow = text_model.TextOverflow;
const TextAlign = text_model.TextAlign;
const TextLayoutOptions = text_model.TextLayoutOptions;
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
const widgetTextInputClipsText = widget_text_input.widgetTextInputClipsText;
const textInputClearButtonRect = widget_text_input.textInputClearButtonRect;
const widgetButtonTextSize = widget_metrics.widgetButtonTextSize;
const widgetBodyTextSize = widget_metrics.widgetBodyTextSize;
const widgetLabelTextSize = widget_metrics.widgetLabelTextSize;
const widgetTypographySize = widget_metrics.widgetTypographySize;
const widgetButtonInset = widget_metrics.widgetButtonInset;
const widgetControlInset = widget_metrics.widgetControlInset;
const widgetSizedDensityValue = widget_metrics.widgetSizedDensityValue;
const widgetButtonIconExtent = widget_metrics.widgetButtonIconExtent;
const widgetRowIconExtent = widget_metrics.widgetRowIconExtent;
const widgetRowIconGap = widget_metrics.widgetRowIconGap;
const widgetButtonIconGap = widget_metrics.widgetButtonIconGap;
const estimateTextWidth = text_model.estimateTextWidth;
const measureTextWidthForFont = text_model.measureTextWidthForFont;
const layoutTextCaretRect = text_model.layoutTextCaretRect;
const layoutTextSelectionRects = text_model.layoutTextSelectionRects;
const textEditingInkColor = widget_render_style.textEditingInkColor;
const textSelectionFillColor = widget_render_style.textSelectionFillColor;
const textSelectionTextColor = widget_render_style.textSelectionTextColor;
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
const buttonControlRadius = widget_render_style.buttonControlRadius;
const widgetSizedRadiusValue = widget_render_style.widgetSizedRadiusValue;
const controlStrokeWidth = widget_render_style.controlStrokeWidth;
const snapHairlineStrokeRect = widget_render_style.snapHairlineStrokeRect;
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
const disabledWash = widget_render_style.disabledWash;
const washHovered = widget_render_style.washHovered;

const max_widget_text_range_rects: usize = 4;

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
    const radius = buttonGroupSegmentRadius(widget, visual, tokens);
    const text_size = widgetButtonTextSize(widget, tokens);
    const text_inset = widgetButtonInset(widget, tokens);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = buttonFill(widget, tokens),
    });
    try emitButtonBorder(builder, widget, tokens, radius);
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 3, widget.frame, radius);
    const content_color = buttonTextColorForWidget(widget, tokens);
    const icon = icon_model.resolveOrMissing(widget.icon);
    if (icon) |resolved| {
        // Icon-in-button: icon (and optional label) are the button's own
        // commands — one hit target, one tint that follows the button's
        // enabled/disabled/variant state. A name that resolves nowhere
        // draws the missing-icon fallback (never a silent gap).
        const icon_extent = widgetButtonIconExtent(widget, tokens);
        const icon_y = widget.frame.y + (widget.frame.height - icon_extent) * 0.5;
        if (widget.text.len == 0) {
            const icon_frame = geometry.RectF.init(
                widget.frame.x + (widget.frame.width - icon_extent) * 0.5,
                icon_y,
                icon_extent,
                icon_extent,
            );
            try emitVectorIcon(builder, widget.id, 5, icon_frame, content_color, resolved);
            return;
        }
        const gap = widgetButtonIconGap(widget, tokens);
        const text_width = measureTextWidthForFont(tokens.text_measure, tokens.typography.buttonFontId(), widget.text, text_size);
        const available = @max(0, widget.frame.width - text_inset * 2);
        const content_width = @min(available, icon_extent + gap + text_width);
        const start_x = widget.frame.x + text_inset + @max(0, (available - content_width) * 0.5);
        // Icon slot side: leading puts the glyph before the label,
        // trailing after it (the next-page chevron) — same centered
        // icon+label block either way.
        const icon_x = if (widget.icon_placement == .trailing)
            start_x + (content_width - icon_extent)
        else
            start_x;
        const text_x = if (widget.icon_placement == .trailing)
            start_x
        else
            start_x + icon_extent + gap;
        const text_max_x = if (widget.icon_placement == .trailing)
            icon_x - gap
        else
            widget.frame.maxX() - text_inset;
        const icon_frame = geometry.RectF.init(icon_x, icon_y, icon_extent, icon_extent);
        try emitVectorIcon(builder, widget.id, 5, icon_frame, content_color, resolved);
        const text_frame = geometry.RectF.init(
            text_x,
            widget.frame.y,
            @max(1, text_max_x - text_x),
            widget.frame.height,
        );
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 4),
            // The button-label face: medium ink so the label reads as a
            // command, not a caption (layout measured with the same id).
            .font_id = tokens.typography.buttonFontId(),
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(text_frame, text_size, 0)),
            .color = content_color,
            .text = widget.text,
            .text_layout = boundedTextLayout(text_frame, text_size, 0, .start, .none, widget.text_overflow, tokens),
        });
        return;
    }
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 4),
        // The button-label face: medium ink so the label reads as a
        // command, not a caption (layout measured with the same id).
        .font_id = tokens.typography.buttonFontId(),
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
        .color = content_color,
        .text = widget.text,
        .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .center, .none, widget.text_overflow, tokens),
    });
}

pub fn emitIconButtonWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = buttonControlVisualTokens(widget, tokens);
    const radius = buttonGroupSegmentRadius(widget, visual, tokens);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = buttonFill(widget, tokens),
    });
    try emitButtonBorder(builder, widget, tokens, radius);
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 15, widget.frame, radius);
    // Real vector icons: `widget.icon` first (the explicit channel,
    // falling back to the missing-icon glyph so a broken name shows),
    // then an icon-name `text` (so `el(.icon_button, .{ .text = "play" })`
    // upgrades from glyph to vector); any other text keeps the historical
    // glyph rendering.
    const icon = if (widget.icon.len > 0)
        icon_model.resolveOrMissing(widget.icon)
    else if (widget.text.len > 0)
        icon_model.resolve(widget.text)
    else
        null;
    if (icon) |resolved| {
        const size = iconGlyphSize(widget, tokens);
        const icon_frame = geometry.RectF.init(
            widget.frame.x + (widget.frame.width - size) * 0.5,
            widget.frame.y + (widget.frame.height - size) * 0.5,
            size,
            size,
        );
        try emitVectorIcon(builder, widget.id, 3, icon_frame, buttonTextColorForWidget(widget, tokens), resolved);
        return;
    }
    if (widget.text.len > 0) {
        const size = iconGlyphSize(widget, tokens);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 3),
            .font_id = tokens.typography.font_id,
            .size = size,
            .origin = pixelSnapTextPoint(tokens, centeredTextOrigin(widget.frame, widget.text, size, tokens)),
            .color = buttonTextColorForWidget(widget, tokens),
            .text = widget.text,
        });
    }
}

/// The button's corner radius shaped by its group register. Segmented
/// (house) members collapse by position: the first segment keeps only
/// its leading pair, the last only its trailing pair, middles square
/// off, and an ungrouped button keeps all four — what makes a flush
/// group read as ONE bar with one corner language instead of three
/// chips pressed together. Detached members are exactly those chips:
/// each keeps all four corners.
fn buttonGroupSegmentRadius(widget: Widget, visual: ControlVisualTokens, tokens: DesignTokens) Radius {
    const radius = buttonControlRadius(widget, visual, tokens);
    if (widget_render_style.buttonInDetachedGroup(widget, tokens)) return radius;
    return switch (widget.group_segment) {
        .none => radius,
        .first => .{ .top_left = radius.top_left, .bottom_left = radius.bottom_left },
        .middle => .{},
        .last => .{ .top_right = radius.top_right, .bottom_right = radius.bottom_right },
    };
}

/// A button's border stroke, honoring the flush-group seam rule: every
/// non-first segment CLIPS AWAY its left border band so each interior
/// boundary is painted by exactly one stroke (the left neighbor's right
/// edge). Overlapping the two would double-composite the translucent
/// dark-scheme hairline into a brighter seam. The clip starts half a
/// stroke inside the frame — the stroke straddles the edge — and
/// extends a full stroke beyond the other three sides so their outer
/// halves survive; the clipped top-left/bottom-left stubs sit exactly
/// under the neighbor's stroke band, so no gap can open. Slot 0 was
/// freed by the retired button shadow.
fn emitButtonBorder(builder: *Builder, widget: Widget, tokens: DesignTokens, radius: Radius) Error!void {
    const stroke_width = buttonStrokeWidth(widget, tokens);
    const border = snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = buttonBorderFill(widget, tokens),
            .width = stroke_width,
        },
    });
    // Seams exist only in the segmented register — a detached chip has
    // no shared boundary to collapse.
    const drop_left_border = !widget_render_style.buttonInDetachedGroup(widget, tokens) and
        (widget.group_segment == .middle or widget.group_segment == .last);
    if (drop_left_border) {
        // The clip's left edge sits on the border band's INNER edge —
        // computed from the (possibly snapped) emitted stroke, so the
        // whole left band drops whether or not snapping moved it.
        const band_inner_x = border.rect.x + border.stroke.width * 0.5;
        try builder.pushClip(.{
            .id = widgetPartId(widget.id, 0),
            .rect = geometry.RectF.init(
                band_inner_x,
                widget.frame.y - stroke_width,
                @max(0, widget.frame.maxX() + stroke_width - band_inner_x),
                widget.frame.height + stroke_width * 2,
            ),
        });
    }
    try builder.strokeRect(border);
    if (drop_left_border) try builder.popClip();
}

/// Draw a parsed vector icon fitted (contain, centered) into `rect`: a
/// transform pair maps viewBox units to device space so the parsed
/// elements are emitted as-is (static lifetime, packet-representable),
/// stroke widths scale with the icon size, and `currentColor` resolves
/// to `color`. Command ids are widget part slots from `first_slot` (two
/// per shape), so callers pick a slot range clear of their own parts.
pub fn emitVectorIcon(builder: *Builder, widget_id: ObjectId, first_slot: ObjectId, rect: geometry.RectF, color: Color, icon: *const svg_icon_model.Icon) Error!void {
    const frame = rect.normalized();
    if (frame.isEmpty()) return;
    const box = icon.view_box;
    const scale = @min(frame.width / box.width, frame.height / box.height);
    if (!(scale > 0)) return;
    const transform = Affine{
        .a = scale,
        .b = 0,
        .c = 0,
        .d = scale,
        .tx = frame.x + (frame.width - box.width * scale) * 0.5 - box.x * scale,
        .ty = frame.y + (frame.height - box.height * scale) * 0.5 - box.y * scale,
    };
    const inverse = transform.inverse() orelse return;

    try builder.transform(transform);
    for (icon.shapes, 0..) |shape, index| {
        const elements = icon.elements[shape.start .. shape.start + shape.len];
        if (iconPaintColor(shape.style.fill, color)) |fill_color| {
            try builder.fillPath(.{
                .id = widgetPartId(widget_id, first_slot + index * 2),
                .elements = elements,
                .fill = colorFill(fill_color),
            });
        }
        if (shape.style.stroke_width > 0) {
            if (iconPaintColor(shape.style.stroke, color)) |stroke_color| {
                try builder.strokePath(.{
                    .id = widgetPartId(widget_id, first_slot + 1 + index * 2),
                    .elements = elements,
                    .stroke = .{ .fill = colorFill(stroke_color), .width = shape.style.stroke_width },
                    // The authored cap, not a fixed choice: the stroke
                    // icon dialect declares round caps per shape, and
                    // honoring the source keeps a butt-cap icon honest.
                    .cap = shape.style.linecap,
                });
            }
        }
    }
    try builder.transform(inverse);
}

fn iconPaintColor(paint: svg_icon_model.Paint, current: Color) ?Color {
    return switch (paint) {
        .none => null,
        .current_color => current,
        .color => |value| value,
    };
}

pub fn emitSelectWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = selectControlVisualTokens(tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    // The registry chevron at the shared row-icon extent: the trigger's
    // open-below affordance matches every other icon in the control
    // family instead of a hand-drawn two-line glyph.
    const chevron_size = widgetRowIconExtent(widget, tokens);
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
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed, washHovered(widget), tokens.colors.surface))),
    });
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    }));
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 6, widget.frame, radius);
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
            .text_layout = boundedTextLayout(text_frame, text_size, 0, .start, .none, widget.text_overflow, tokens),
        });
    }
    try emitSelectChevron(builder, widget, tokens, visual, inset, chevron_size);
}

fn emitSelectChevron(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens, inset: f32, chevron_size: f32) Error!void {
    const icon = icon_model.resolve("chevron-down") orelse return;
    const icon_frame = geometry.RectF.init(
        widget.frame.x + widget.frame.width - inset - chevron_size,
        widget.frame.y + (widget.frame.height - chevron_size) * 0.5,
        chevron_size,
        chevron_size,
    );
    // Muted, like the trigger's placeholder register: the chevron is an
    // affordance, not content, so it never outweighs the chosen label.
    const color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted);
    try emitVectorIcon(builder, widget.id, 4, icon_frame, color, icon);
}

pub fn emitTextFieldWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = textInputControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetTextInputSize(widget, tokens);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, tokens, text_size, text_inset);
    const clip_rect = widgetTextInputClipRect(widget, tokens, text_size, text_inset, layout_options);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const text_color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    var draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, text_color, layout_options);
    // A presented value (single-line kind holding a line break) lives in
    // shared scratch; persist it into the builder so this widget's
    // emitted commands survive the rest of the walk AND any later emit
    // while this display list is held. No-op for the ordinary raw value.
    draw_text.text = widget_text_input.persistWidgetTextInputPresentedText(builder, widget.text, draw_text.text);
    const selection_range = widgetTextSelectionRange(widget);
    const composition_range = widgetTextCompositionRange(widget);
    const has_text_affordances = selection_range != null or composition_range != null;
    // Textareas always clip (their overflow scrolls vertically); a
    // single-line field clips once its value overflows the content rect,
    // so the horizontally scrolled text, selection rects, composition
    // underline, and caret all cut at the field's border instead of
    // painting past it. Short values emit no clip — unchanged emission.
    const clips_text = widgetTextInputClipsText(widget, tokens, text_size, text_inset, layout_options);

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = textInputFill(widget, tokens, visual),
    });
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = textInputBorderFill(widget, visual, tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    }));
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 7, widget.frame, radius);
    if (clips_text) try builder.pushClip(.{ .id = widgetPartId(widget.id, 16), .rect = clip_rect, .radius = radius });
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectionRects(builder, widget, draw_text, layout_options, range, 3, 13, max_widget_text_range_rects, tokens);
        }
    }
    const placeholder = widgetPlaceholder(widget);
    // A non-empty value paints the presented bytes the draw text already
    // carries; only an empty field swaps in the placeholder.
    const visible_text = if (widget.text.len > 0) draw_text.text else placeholder;
    if (visible_text.len > 0) {
        var command = draw_text;
        command.id = widgetPartId(widget.id, if (has_text_affordances) 4 else 3);
        command.text = visible_text;
        if (widget.text.len == 0) {
            command.color = widgetForegroundColor(widget, tokens, tokens.colors.text_muted);
        }
        try builder.drawText(command);
    }
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectedGlyphs(builder, widget, draw_text, layout_options, range, max_widget_text_range_rects, tokens);
        }
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

/// The grouped input's field chrome: text-input fill and border on the
/// GROUP's own frame, plus the focus ring while `state.focused` — for
/// this kind that flag is FOCUS-WITHIN, derived by the render walk from
/// the focused descendant, so keyboard focus anywhere inside the group
/// rings the whole field. Children (the chrome-dissolved entry and the
/// accessory row) flow on top through the ordinary child pass.
pub fn emitInputGroupWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = textInputControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = textInputFill(widget, tokens, visual),
    });
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = textInputBorderFill(widget, visual, tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    }));
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 3, widget.frame, radius);
}

pub fn emitSearchFieldWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = textInputControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.md);
    const text_size = widgetTextInputSize(widget, tokens);
    const icon_size = @max(8, text_size - 2);
    const text_inset = widgetTextInputInset(widget, tokens);
    const layout_options = widgetTextInputLayoutOptions(widget, tokens, text_size, text_inset);
    const clip_rect = widgetTextInputClipRect(widget, tokens, text_size, text_inset, layout_options);
    const origin = widgetTextInputOrigin(widget, tokens, text_size, text_inset, layout_options);
    const selection_range = widgetTextSelectionRange(widget);
    const composition_range = widgetTextCompositionRange(widget);
    const text_color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    var draw_text = widgetTextInputDrawText(widget, tokens, text_size, origin, text_color, layout_options);
    // Presented values persist out of the shared scratch into the
    // builder — the text-field emitter's rule (no-op for ordinary raw
    // values).
    draw_text.text = widget_text_input.persistWidgetTextInputPresentedText(builder, widget.text, draw_text.text);
    // Same overflow contract as the text-field emitter: clip only once
    // the value (or placeholder) overflows the content rect, so the
    // horizontally scrolled text and its affordances cut at the border.
    // The leading glass, trailing chevron, and clear affordance draw
    // outside the clip — they are chrome, not scrolling content. Slot 7
    // is clear of the field chrome (1..6, 8..13), the focus ring (14),
    // and the clear affordance's shape range (15..).
    const clips_text = widgetTextInputClipsText(widget, tokens, text_size, text_inset, layout_options);

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = textInputFill(widget, tokens, visual),
    });
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = textInputBorderFill(widget, visual, tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    }));
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 14, widget.frame, radius);
    try emitSearchFieldIcon(builder, widget, tokens, icon_size);
    if (clips_text) try builder.pushClip(.{ .id = widgetPartId(widget.id, 7), .rect = clip_rect, .radius = radius });
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectionRects(builder, widget, draw_text, layout_options, range, 8, 0, 1, tokens);
        }
    }
    const placeholder = widgetPlaceholder(widget);
    const visible_text = if (widget.text.len > 0) draw_text.text else placeholder;
    if (visible_text.len > 0) {
        var command = draw_text;
        command.id = widgetPartId(widget.id, 9);
        command.text = visible_text;
        command.color = if (widget.text.len > 0) text_color else widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted);
        try builder.drawText(command);
    }
    if (selection_range) |range| {
        if (!range.isCollapsed(widget.text.len)) {
            try emitWidgetTextSelectedGlyphs(builder, widget, draw_text, layout_options, range, 1, tokens);
        }
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
    if (clips_text) try builder.popClip();
    if (widget.kind == .combobox) {
        try emitComboboxChevron(builder, widget, tokens, visual);
    }
    try emitSearchFieldClearButton(builder, widget, tokens, visual);
}

/// The built-in trailing clear affordance: a small x over the trailing
/// inset whenever a search field holds text. Geometry comes from
/// `textInputClearButtonRect`, the same rect the runtime hit-tests, so
/// the drawn glyph and the press target can never drift apart.
fn emitSearchFieldClearButton(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Error!void {
    const icon_frame = textInputClearButtonRect(widget, tokens) orelse return;
    const icon = icon_model.resolve("x") orelse return;
    const color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted);
    try emitVectorIcon(builder, widget.id, 15, icon_frame, color, icon);
}

/// The combobox trigger's open-below affordance: the registry
/// `chevron-down` icon at the shared row-icon extent, the same
/// treatment the select trigger draws — one icon register across the
/// control family instead of a hand-drawn two-line glyph. Muted, like
/// the placeholder register: the chevron is an affordance, not
/// content, so it never outweighs the entered text. Slot 12 starts the
/// icon's shape range (fill/stroke pair), clear of the field chrome
/// (1..11), the focus ring (14), and the clear affordance (15).
fn emitComboboxChevron(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Error!void {
    const icon = icon_model.resolve("chevron-down") orelse return;
    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const chevron_size = widgetRowIconExtent(widget, tokens);
    const icon_frame = geometry.RectF.init(
        widget.frame.x + widget.frame.width - inset - chevron_size,
        widget.frame.y + (widget.frame.height - chevron_size) * 0.5,
        chevron_size,
        chevron_size,
    );
    const color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted);
    try emitVectorIcon(builder, widget.id, 12, icon_frame, color, icon);
}

fn emitSearchFieldIcon(builder: *Builder, widget: Widget, tokens: DesignTokens, icon_size: f32) Error!void {
    // The registry `search` icon (a true circle lowered to kappa cubics
    // plus a handle), not a hand-drawn line box: the glass stays round at
    // every size because the circle flattens in viewBox units before the
    // icon transform scales it down, so 12-14px fields keep real arcs.
    const icon = icon_model.resolve("search") orelse return;
    const left = widget.frame.x + widgetControlInset(widget, tokens, tokens.spacing.md);
    const top = widget.frame.y + @max(0, (widget.frame.height - icon_size) * 0.5);
    const icon_frame = geometry.RectF.init(left, top, icon_size, icon_size);
    const visual = textInputControlVisualTokens(widget, tokens);
    const color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted);
    try emitVectorIcon(builder, widget.id, 3, icon_frame, color, icon);
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
        .fill = widgetAccentFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, washHovered(widget), tokens.colors.accent)),
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
            .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .start, .none, widget.text_overflow, tokens),
        });
    }
}

/// The open menu's option row. Deliberately NOT the list-item emitter:
/// a menu row never draws a focus outline — while the menu is open, the
/// keyboard's position paints the same full-row wash hover does, and
/// the row the app has committed carries a trailing checkmark instead
/// of a wash. Highlight (where the keyboard is) and checkmark (what is
/// committed) stay independent: arrowing away from the committed row
/// moves the wash while its checkmark stays put.
pub fn emitMenuItemWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = listItemControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.sm);
    const wash = menuItemWashColor(widget, tokens, visual);
    if (wash.a > 0) {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .fill = widgetBackgroundFill(widget, wash),
        });
    }
    const text_size = widgetBodyTextSize(widget, tokens);
    const text_inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const content_color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    // EVERY row reserves the trailing checkmark slot, committed or not,
    // so labels measure and elide identically and moving the commit
    // never reflows a row's text.
    const check_extent = widgetRowIconExtent(widget, tokens);
    const check_gap = widgetRowIconGap(widget, tokens);
    var text_frame = geometry.RectF.init(
        widget.frame.x,
        widget.frame.y,
        @max(1, widget.frame.width - check_extent - check_gap),
        widget.frame.height,
    );
    const icon = icon_model.resolveOrMissing(widget.icon);
    if (icon) |resolved| {
        // Leading icon slot: shared row metrics, one tint with the
        // label — the same contract list rows draw with.
        const icon_extent = widgetRowIconExtent(widget, tokens);
        const icon_frame = geometry.RectF.init(
            widget.frame.x + text_inset,
            widget.frame.y + (widget.frame.height - icon_extent) * 0.5,
            icon_extent,
            icon_extent,
        );
        try emitVectorIcon(builder, widget.id, 4, icon_frame, content_color, resolved);
        const shift = icon_extent + widgetRowIconGap(widget, tokens);
        text_frame = geometry.RectF.init(
            text_frame.x + shift,
            text_frame.y,
            @max(1, text_frame.width - shift),
            text_frame.height,
        );
    }
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(text_frame, text_size, text_inset)),
        .color = content_color,
        .text = widget.text,
        .text_layout = boundedTextLayout(text_frame, text_size, text_inset, .start, .none, widget.text_overflow, tokens),
    });
    if (widget.state.selected) {
        if (icon_model.resolve("check")) |check_icon| {
            // The commit marker: right-aligned inside the reserved slot,
            // in the row's own content tint. Slots 12/13 sit clear of
            // the leading icon's shape range (4..11).
            const check_frame = geometry.RectF.init(
                widget.frame.maxX() - text_inset - check_extent,
                widget.frame.y + (widget.frame.height - check_extent) * 0.5,
                check_extent,
                check_extent,
            );
            try emitVectorIcon(builder, widget.id, 12, check_frame, content_color, check_icon);
        }
    }
}

/// Menu rows tint by ATTENTION, never by commit: the keyboard's active
/// row and the hovered row share the hover wash, a press deepens it,
/// and the committed row stays untinted (its marker is the trailing
/// checkmark). `selected` deliberately does not reach the fill, and no
/// state draws a focus ring. The quiet-surface knob silences only the
/// pointer half of the attention wash — the keyboard's active row still
/// washes, because inside a menu that wash IS the keyboard affordance.
fn menuItemWashColor(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Color {
    if (widget.state.pressed) return widget_render_style.controlStateBackground(visual, true, true, false, tokens.colors.surface_pressed);
    if (widget.state.focused or washHovered(widget)) return buttonStateBackground(visual, false, true, tokens.colors.surface_subtle);
    return widget_render_style.transparentColor();
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
    const content_color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    // Leading icon slot: drawn as part of the row's own rendering
    // so icon + label are one hit target with one tint, mirroring the
    // button's inline icon. The label shifts right by the shared metric
    // the intrinsic size also accounts for.
    var text_frame = widget.frame;
    const icon = icon_model.resolveOrMissing(widget.icon);
    if (icon) |resolved| {
        const icon_extent = widgetRowIconExtent(widget, tokens);
        const icon_frame = geometry.RectF.init(
            widget.frame.x + text_inset,
            widget.frame.y + (widget.frame.height - icon_extent) * 0.5,
            icon_extent,
            icon_extent,
        );
        try emitVectorIcon(builder, widget.id, 4, icon_frame, content_color, resolved);
        const shift = icon_extent + widgetRowIconGap(widget, tokens);
        text_frame = geometry.RectF.init(
            widget.frame.x + shift,
            widget.frame.y,
            @max(1, widget.frame.width - shift),
            widget.frame.height,
        );
    }
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(text_frame, text_size, text_inset)),
        .color = content_color,
        .text = widget.text,
        .text_layout = boundedTextLayout(text_frame, text_size, text_inset, .start, .none, widget.text_overflow, tokens),
    });
}

pub fn emitDataCellWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = try emitDataCellWidgetChrome(builder, widget, tokens);
    if (widget.text.len > 0) {
        const text_size = widgetBodyTextSize(widget, tokens);
        // Tight cell padding on the comfortable row band — the table
        // register — and the cell honors its authored alignment, so
        // numeric columns right-align with `text-alignment="end"`.
        const text_inset = widgetControlInset(widget, tokens, tokens.spacing.sm);
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 4),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
            .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
            .text = widget.text,
            .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, widget.text_alignment, .none, widget.text_overflow, tokens),
        });
    }
}

/// The cell's fill, border, and focus ring — shared between the classic
/// single-line cell and span-carrying cells (whose runs the span
/// paragraph emitter draws). Returns the visual tokens so callers can
/// reuse the resolved foreground.
pub fn emitDataCellWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!ControlVisualTokens {
    const visual = listItemControlVisualTokens(widget, tokens);
    const state_fill = listItemFillColor(widget, tokens, widget.state);
    if (state_fill.a > 0) {
        try builder.fillRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .fill = widgetBackgroundFill(widget, state_fill),
        });
    }
    // Borderless by default: the table's chrome is its hairline ROW
    // separators, never a grid of cell boxes. A theme or per-widget
    // border/stroke opts a cell back into an edge.
    const wants_stroke = widget.style.border != null or visual.border != null or widget.style.stroke_width != null or visual.stroke_width != null;
    if (wants_stroke) {
        try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
            .id = widgetPartId(widget.id, 2),
            .rect = widget.frame,
            .stroke = .{
                .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
                .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
            },
        }));
    }
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 3);
    return visual;
}

/// The radius for a segmented trigger. Triggers sit `tabs_list_inset`
/// inside the TabsList container, so a corner that hugs the container's
/// curve needs radius = container radius − inset; reusing a full-size
/// control radius makes the selected segment's corners bulge past the
/// container's rounding. An explicit style or themed trigger radius
/// still wins over the concentric default.
fn segmentedTriggerRadius(widget: Widget, visual: ControlVisualTokens, tokens: DesignTokens) Radius {
    if (widget.style.radius) |radius| return Radius.all(@max(0, radius));
    if (visual.radius) |radius| return Radius.all(@max(0, widgetSizedRadiusValue(widget, radius)));
    const container = tokens.controls.tabs.radius orelse tokens.radius.lg;
    return Radius.all(@max(0, widgetSizedRadiusValue(widget, container) - widget_model.tabs_list_inset));
}

/// The selected-tab bar for the `.underline` tab register: a short
/// filled rect hugging the trigger's label (measured width plus a 2px
/// shoulder each side — the label's own breathing room, mirroring the
/// house reference's tab padding), sunk to the BOTTOM of the TabsList
/// container. The trigger sits `tabs_list_inset` above the container's
/// edge, so the bar extends past the trigger frame by exactly that
/// inset and covers the strip hairline — the underline and the track
/// line meet, which is the register's signature. Null in the `.pill`
/// register; shared with invalidation so damage covers the overhang.
pub fn segmentedControlUnderlineRect(widget: Widget, tokens: DesignTokens) ?geometry.RectF {
    if (tokens.controls.tabs_indicator != .underline) return null;
    const frame = widget.frame.normalized();
    if (frame.isEmpty()) return null;
    const thickness = @min(frame.height, widgetSizedDensityValue(widget, tokens, tokens.metrics.tabs_indicator_thickness));
    const text_size = widgetLabelTextSize(widget, tokens);
    const text_width = measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, widget.text, text_size);
    // An icon-only or empty trigger underlines its full width — there
    // is no label to hug.
    const bar_width = if (text_width > 0) @min(frame.width, text_width + 4) else frame.width;
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        frame.x + (frame.width - bar_width) * 0.5,
        frame.maxY() + widget_model.tabs_list_inset - thickness,
        bar_width,
        thickness,
    ));
}

pub fn emitSegmentedControlWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const selected = widget.state.selected or widget.value >= 0.5;
    const visual = selectionControlVisualTokens(widget, tokens);
    const radius = segmentedTriggerRadius(widget, visual, tokens);
    const text_size = widgetLabelTextSize(widget, tokens);
    const text_inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    switch (tokens.controls.tabs_indicator) {
        // The house tab-trigger treatment: the active segment lifts to
        // the page surface with a hairline border; inactive segments
        // stay TRANSPARENT with muted text, so the muted TabsList
        // container behind them (`emitTabsListWidgetChrome`) provides
        // the wash — selection reads by elevation, not by an accent
        // fill.
        .pill => {
            if (selected) {
                try builder.fillRoundedRect(.{
                    .id = widgetPartId(widget.id, 1),
                    .rect = widget.frame,
                    .radius = radius,
                    .fill = colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.surface)),
                });
            } else if (widget.style.background orelse visual.background) |background| {
                try builder.fillRoundedRect(.{
                    .id = widgetPartId(widget.id, 1),
                    .rect = widget.frame,
                    .radius = radius,
                    .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, washHovered(widget), background))),
                });
            }
            if (selected) {
                try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
                    .id = widgetPartId(widget.id, 2),
                    .rect = widget.frame,
                    .radius = radius,
                    .stroke = .{
                        .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
                        .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
                    },
                }));
            }
        },
        // The underline treatment: triggers are bare text — no pill, no
        // border — and the active one carries a short bar under its
        // label in the primary ink. State speaks through TYPE (active
        // ink vs muted) plus the bar, never through a fill.
        .underline => {
            if (widget.style.background orelse visual.background) |background| {
                try builder.fillRoundedRect(.{
                    .id = widgetPartId(widget.id, 1),
                    .rect = widget.frame,
                    .radius = radius,
                    .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, washHovered(widget), background))),
                });
            }
            if (selected) {
                if (segmentedControlUnderlineRect(widget, tokens)) |bar| {
                    try builder.fillRect(.{
                        .id = widgetPartId(widget.id, 2),
                        .rect = bar,
                        .fill = colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.text)),
                    });
                }
            }
        },
    }
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 4, widget.frame, radius);
    // Inactive labels sit in the muted ink; in the underline register a
    // hovered (enabled) trigger previews the active ink — the register
    // has no hover WASH, so the type itself is the hover feedback.
    const active_ink = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    const hover_preview = tokens.controls.tabs_indicator == .underline and widget.state.hovered and !widget.state.disabled;
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, boundedTextOrigin(widget.frame, text_size, text_inset)),
        .color = if (selected or hover_preview) active_ink else widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text_muted),
        .text = widget.text,
        .text_layout = boundedTextLayout(widget.frame, text_size, text_inset, .center, .none, widget.text_overflow, tokens),
    });
}

pub fn emitCheckboxWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = selectionControlVisualTokens(widget, tokens);
    const box = checkboxWidgetBoxRect(widget, tokens);
    const selected = booleanControlSelected(widget);
    // A literal 4px default, not the sm radius token: on a 16px box the
    // 6px token reads nearly round; 4px keeps the square-with-softened-
    // corners shape the checkbox is known by.
    const radius = controlRadius(widget, visual, 4);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = box,
        .radius = radius,
        .fill = if (selected)
            colorFill(disabledWash(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent), widget.state.disabled, tokens.states.disabled_alpha))
        else
            colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, washHovered(widget), tokens.colors.surface))),
    });
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 2),
        .rect = box,
        .radius = radius,
        .stroke = .{
            .fill = colorFill(disabledWash(if (selected) widgetAccentColor(widget, visual.border orelse visual.active_background orelse tokens.colors.accent) else widgetBorderColor(widget, visual.border orelse tokens.colors.border), widget.state.disabled, tokens.states.disabled_alpha)),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    }));
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 3, box, radius);
    if (selected) {
        // The check keeps the accent-foreground tint even when disabled
        // (washed to half strength with the box) — swapping it to the
        // muted text gray would read muddy on the washed accent fill.
        const check_color = disabledWash(widget.style.accent_foreground orelse visual.foreground orelse tokens.colors.accent_text, widget.state.disabled, tokens.states.disabled_alpha);
        const left = pixelSnapGeometryPoint(tokens, geometry.PointF.init(box.x + box.width * 0.26, box.y + box.height * 0.54));
        const mid = pixelSnapGeometryPoint(tokens, geometry.PointF.init(box.x + box.width * 0.43, box.y + box.height * 0.70));
        const right = pixelSnapGeometryPoint(tokens, geometry.PointF.init(box.x + box.width * 0.76, box.y + box.height * 0.32));
        // ONE stroked polyline through the vector core, not a pair of
        // line commands: `draw_line` rasterizes as a hard-edged capsule
        // (exact for the axis-aligned hairlines it serves), which turns
        // this diagonal into staircase chunks at control sizes. The
        // stroke path gets the same anti-aliased coverage and round
        // caps/joins the built-in stroke icons get, so the mark reads
        // crisp and even at 1x — same three snapped vertices, so the
        // drawn shape is unchanged.
        const elements = try builder.allocPathElements(3);
        elements[0] = .{ .verb = .move_to, .points = .{ left, geometry.PointF.zero(), geometry.PointF.zero() } };
        elements[1] = .{ .verb = .line_to, .points = .{ mid, geometry.PointF.zero(), geometry.PointF.zero() } };
        elements[2] = .{ .verb = .line_to, .points = .{ right, geometry.PointF.zero(), geometry.PointF.zero() } };
        try builder.strokePath(.{
            .id = widgetPartId(widget.id, 4),
            .elements = elements,
            .stroke = .{ .fill = colorFill(check_color), .width = 2 },
            .cap = .round,
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
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, washHovered(widget), tokens.colors.surface))),
    });
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 2),
        .rect = circle,
        .radius = radius,
        // The border stays on the input hairline even when selected —
        // the primary-colored dot alone carries the checked state.
        .stroke = .{
            .fill = colorFill(disabledWash(widgetBorderColor(widget, visual.border orelse tokens.colors.border), widget.state.disabled, tokens.states.disabled_alpha)),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    }));
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 3, circle, radius);
    if (selected) {
        const dot_size = @max(0, circle.height * 0.5);
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
            .fill = colorFill(disabledWash(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent), widget.state.disabled, tokens.states.disabled_alpha)),
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
            colorFill(disabledWash(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent), widget.state.disabled, tokens.states.disabled_alpha))
        else
            colorFill(disabledWash(widgetBackgroundColor(widget, buttonStateBackground(visual, false, washHovered(widget), tokens.colors.surface_pressed)), widget.state.disabled, tokens.states.disabled_alpha)),
    });
    // Borderless by default: the switch is a filled pill (primary when
    // on, the input wash when off) whose near-white thumb provides the
    // edge — a track hairline reads as chrome the control doesn't have.
    // Themes that opt into a border (a color or an explicit width on
    // the toggle control tokens) still get the stroked track.
    const wants_track_stroke = widget.style.border != null or visual.border != null;
    const track_stroke_width = controlStrokeWidth(widget, visual, if (wants_track_stroke) tokens.stroke.regular else 0);
    if (track_stroke_width > 0) {
        try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
            .id = widgetPartId(widget.id, 2),
            .rect = track,
            .radius = track_radius,
            .stroke = .{
                .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
                .width = track_stroke_width,
            },
        }));
    }
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = knob,
        .radius = controlRadius(widget, visual, knob.height * 0.5),
        // The thumb is near-white in both states and schemes (the
        // primary-foreground tint), so it stays legible on the primary
        // track and on the dark input wash alike. Disabled washes it to
        // half strength with the track instead of swapping to gray.
        .fill = colorFill(disabledWash(
            if (selected) widget.style.accent_foreground orelse visual.foreground orelse tokens.colors.accent_text else widget.style.background orelse visual.foreground orelse tokens.colors.accent_text,
            widget.state.disabled,
            tokens.states.disabled_alpha,
        )),
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
    // The rail is a pill in every register; the RADIUS channel (widget
    // style or the themed slider table) shapes only the thumb, because
    // thumb shape is where slider registers actually differ — a round
    // dot versus a barely-rounded grab handle — while a squared-off rail
    // is no register at all.
    const track_radius = Radius.all(track.height * 0.5);
    const knob_radius = controlRadius(widget, visual, @min(knob.width, knob.height) * 0.5);

    // Disabled register: with no themed statement the whole slider mutes
    // to the half-strength wash as one piece — rail, range, and thumb
    // together. A themed table that states a disabled color is the SWAP
    // register: the stated color replaces the range fill and everything
    // it does not restate keeps full strength (the swap is the pack's
    // entire disabled statement).
    const swap_disabled = visual.disabled_background != null or visual.disabled_foreground != null;
    const washed = widget.state.disabled and !swap_disabled;

    // Track on the muted wash, filled range on the primary, and a
    // paper-white thumb under a neutral hairline — the range carries the
    // color; the thumb reads as a quiet handle on top of it.
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = track,
        .radius = track_radius,
        .fill = colorFill(disabledWash(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_subtle), washed, tokens.states.disabled_alpha)),
    });
    const active_rest = widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent);
    // Zero range paints NOTHING — same guard the progress bar wears. A
    // width-zero pill still owns anti-aliased edge coverage, so an idle
    // transport slider (value 0, disabled) showed a one-pixel filled
    // sliver at the rail's start.
    if (value > 0) {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 2),
            .rect = active,
            .radius = track_radius,
            .fill = colorFill(if (widget.state.disabled)
                visual.disabled_background orelse disabledWash(active_rest, true, tokens.states.disabled_alpha)
            else
                active_rest),
        });
    }
    // Paper-white in BOTH schemes: the thumb must read against the
    // filled range and the muted rail alike, and the palette carries no
    // scheme-invariant white token — so the emitter states it, and a
    // theme restates it through the slider table's foreground channel.
    const knob_rest = widgetBackgroundColor(widget, visual.foreground orelse Color.rgb8(255, 255, 255));
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = knob,
        .radius = knob_radius,
        .fill = colorFill(if (widget.state.disabled)
            visual.disabled_foreground orelse disabledWash(knob_rest, washed, tokens.states.disabled_alpha)
        else
            knob_rest),
    });
    // The thumb's resting hairline wears the focus-ring neutral (a mid
    // gray in both schemes), so the ring on focus reads as a brighter
    // echo of an edge the control already owns — not a recolor.
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, 4),
        .rect = knob,
        .radius = knob_radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, disabledWash(visual.border orelse tokens.colors.focus_ring, washed, tokens.states.disabled_alpha)),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
        },
    }));
    if (widget.state.focused) try emitWidgetFocusRingForRect(builder, widget, tokens, 5, knob, knob_radius);
}

pub fn checkboxWidgetBoxRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    // 16px box at default size/density — the size-4 checkbox metric.
    const box_size = @min(@max(widgetSizedDensityValue(widget, tokens, 16), widget.frame.height * 0.55), widgetSizedDensityValue(widget, tokens, 20));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - box_size) * 0.5,
        box_size,
        box_size,
    ));
}

pub fn radioWidgetCircleRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    // 16px circle at default size/density — the size-4 radio metric.
    const circle_size = @min(@max(widgetSizedDensityValue(widget, tokens, 16), widget.frame.height * 0.55), widgetSizedDensityValue(widget, tokens, 20));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - circle_size) * 0.5,
        circle_size,
        circle_size,
    ));
}

pub fn toggleWidgetTrackRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    // 44x24 track at default size/density, giving the 20px thumb (track
    // height minus the 2px inset per side) 20px of travel — the classic
    // switch proportion, and wide enough that on/off read at a glance.
    const track_width = @min(widget.frame.width, @max(widgetSizedDensityValue(widget, tokens, 44), widget.frame.height * 1.75));
    const track_height = @min(widget.frame.height, widgetSizedDensityValue(widget, tokens, 24));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        track_width,
        track_height,
    ));
}

fn sliderWidgetTrackRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    // The rail thickness comes off the metric ladder (house register:
    // a quiet 4px line — the thumb, not the rail, gives the control its
    // weight); packs with a heavier rail restate the token.
    const track_height: f32 = @min(widget.frame.height, widgetSizedDensityValue(widget, tokens, tokens.metrics.slider_track_height));
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        widget.frame.x,
        widget.frame.y + (widget.frame.height - track_height) * 0.5,
        widget.frame.width,
        track_height,
    ));
}

pub fn sliderWidgetKnobRect(widget: Widget, tokens: DesignTokens) geometry.RectF {
    const value = std.math.clamp(widget.value, 0, 1);
    // Thumb geometry off the metric ladder (house register: a 12px dot;
    // width and height are separate tokens because some registers use a
    // narrow rectangular handle). Fixed-size on purpose — the thumb is
    // a grab target, so it must not swell with the row it sits in —
    // clamped only so a shallow row never overflows.
    const knob_width = @min(widget.frame.width, widgetSizedDensityValue(widget, tokens, tokens.metrics.slider_thumb_width));
    const knob_height = @min(widget.frame.height, widgetSizedDensityValue(widget, tokens, tokens.metrics.slider_thumb_height));
    const knob_x = std.math.clamp(
        widget.frame.x + widget.frame.width * value - knob_width * 0.5,
        widget.frame.x,
        widget.frame.x + @max(0, widget.frame.width - knob_width),
    );
    return pixelSnapGeometryRect(tokens, geometry.RectF.init(
        knob_x,
        widget.frame.y + (widget.frame.height - knob_height) * 0.5,
        knob_width,
        knob_height,
    ));
}

pub fn emitProgressWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const progress = std.math.clamp(widget.value, 0, 1);
    const visual = selectionControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, @min(tokens.radius.md, widget.frame.height * 0.5));
    if (progress < 1) {
        // The unfilled track sits on the muted wash (the same rail the
        // slider uses), so the primary indicator reads against a quiet
        // gray rather than against a tint of itself.
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .fill = colorFill(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_subtle)),
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

/// The ring-offset focus treatment: the control keeps its own border
/// and the ring strokes a concentric rounded rect the token-stated gap
/// (`stroke.focus_offset`) outside it, so focus adds an outline instead
/// of recoloring the control's edge.
fn emitWidgetFocusRingForRect(builder: *Builder, widget: Widget, tokens: DesignTokens, slot: ObjectId, rect: geometry.RectF, radius: Radius) Error!void {
    try builder.strokeRect(snapHairlineStrokeRect(tokens, .{
        .id = widgetPartId(widget.id, slot),
        .rect = widget_render_style.focusRingRect(rect, tokens),
        .radius = widget_render_style.focusRingRadius(radius, tokens),
        .stroke = .{
            .fill = widgetFocusRingFill(widget, tokens),
            .width = tokens.stroke.focus,
        },
    }));
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
        .text_layout = boundedTextLayout(labelFrameForControl(widget.frame, x), text_size, 0, .start, .none, widget.text_overflow, tokens),
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

fn boundedTextLayout(frame: geometry.RectF, size: f32, inset: f32, alignment: TextAlign, wrap: TextWrap, overflow: TextOverflow, tokens: DesignTokens) TextLayoutOptions {
    return .{
        .max_width = @max(1, frame.width - inset * 2),
        .line_height = size * 1.25,
        .wrap = wrap,
        .alignment = alignment,
        // Single-line labels follow the widget's overflow policy:
        // trailing ellipsis by default, so a control narrower than its
        // label elides instead of bleeding into its neighbors.
        .overflow = overflow,
        .measure = tokens.text_measure,
    };
}

fn labelFrameForControl(frame: geometry.RectF, x: f32) geometry.RectF {
    return geometry.RectF.init(x, frame.y, @max(1, frame.x + frame.width - x), frame.height);
}

fn centeredTextOrigin(frame: geometry.RectF, text: []const u8, size: f32, tokens: DesignTokens) geometry.PointF {
    return alignedTextOrigin(frame, text, size, 0, .center, tokens);
}

fn alignedTextOrigin(frame: geometry.RectF, text: []const u8, size: f32, inset: f32, alignment: TextAlign, tokens: DesignTokens) geometry.PointF {
    const width = if (tokens.text_measure) |measure|
        measure.measureWidth(tokens.typography.font_id, size, text)
    else
        estimateTextWidth(text, size);
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
        // heading/display are text-leaf typography rungs; icon glyphs
        // keep the default control proportion.
        .default, .icon, .heading, .display => 0.48,
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
    var rect_buffer: [max_widget_text_range_rects]TextSelectionRect = undefined;
    const rects = layoutTextSelectionRects(text, options, range, rect_buffer[0..@min(max_parts, rect_buffer.len)]);
    for (rects, 0..) |selection, index| {
        // Square corners: the highlight is a solid accent block that the
        // selected-glyph repaint is clipped to, so fill and clip must
        // share one edge — and abutting per-line rects of a multi-line
        // selection meet without corner notches.
        try builder.fillRect(.{
            .id = widgetPartId(widget.id, widgetTextRangePart(first_part, overflow_first_part, index)),
            .rect = pixelSnapGeometryRect(tokens, selection.rect),
            .fill = .{ .color = textSelectionFillColor(widget, tokens) },
        });
    }
}

/// The inverted-selection glyph pass: the SAME text command the base
/// pass drew, re-emitted once per highlight rect under that rect's clip
/// with the selection foreground. Re-emitting the identical command is
/// what makes the recolor drift-free — every glyph lands exactly where
/// the base pass put it and only swaps ink where the highlight covers it
/// (re-shaping the selected substring instead would re-kern at the
/// segment boundary and shift the halves apart). Runs after the base
/// text so the recolored glyphs paint over their normal-ink twins.
fn emitWidgetTextSelectedGlyphs(
    builder: *Builder,
    widget: Widget,
    text: DrawText,
    options: TextLayoutOptions,
    range: TextRange,
    max_parts: usize,
    tokens: DesignTokens,
) Error!void {
    var rect_buffer: [max_widget_text_range_rects]TextSelectionRect = undefined;
    const rects = layoutTextSelectionRects(text, options, range, rect_buffer[0..@min(max_parts, rect_buffer.len)]);
    for (rects, 0..) |selection, ordinal| {
        try builder.pushClip(.{
            .id = textSelectionOverlayCommandId(0x5eed_59a2_0000_0005, widget.id, ordinal),
            .rect = pixelSnapGeometryRect(tokens, selection.rect),
        });
        var command = text;
        command.id = textSelectionOverlayCommandId(0x5eed_59a2_0000_0006, widget.id, ordinal);
        command.color = textSelectionTextColor(widget, tokens);
        try builder.drawText(command);
        try builder.popClip();
    }
}

/// Stable command ids for the selected-glyph repaint (one clip + one
/// text per highlight rect). Hashed from the widget id and rect ordinal
/// — the same scheme static-text selection rects use — because the
/// arithmetic part-id space (16 slots per widget id) has no room left
/// on text fields for four more rect-indexed parts.
fn textSelectionOverlayCommandId(seed: u64, widget_id: ObjectId, ordinal: usize) ObjectId {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(std.mem.asBytes(&widget_id));
    hasher.update(std.mem.asBytes(&@as(u64, ordinal)));
    const value = hasher.final();
    return if (value == 0) 1 else value;
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
    var rect_buffer: [max_widget_text_range_rects]TextSelectionRect = undefined;
    const rects = layoutTextSelectionRects(text, options, range, rect_buffer[0..@min(max_parts, rect_buffer.len)]);
    for (rects, 0..) |selection, index| {
        // A filled bar, not a stroked line: a centered 1pt stroke on a
        // snapped coordinate covers half of each neighboring pixel row
        // at 1x and antialiases to a 50% ghost, while a snapped rect
        // covers whole device pixels and stays crisp at every scale.
        const snapped = pixelSnapGeometryRect(tokens, selection.rect);
        try builder.fillRect(.{
            .id = widgetPartId(widget.id, widgetTextRangePart(first_part, overflow_first_part, index)),
            .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(
                snapped.x,
                snapped.maxY() - tokens.stroke.regular,
                snapped.width,
                tokens.stroke.regular,
            )),
            .fill = .{ .color = textEditingInkColor(widget, tokens) },
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
    const rect = layoutTextCaretRect(text, options, offset) orelse return;
    // A filled one-point bar in the field's text ink. A fill, not a
    // stroked line: a centered 1pt stroke on a snapped x covers half of
    // each neighboring pixel column at 1x and antialiases to a 50%
    // ghost, while the snapped rect covers whole device pixels — the
    // caret stays crisp and full-contrast at every scale.
    try builder.fillRect(.{
        .id = widgetPartId(widget.id, part),
        .rect = pixelSnapGeometryRect(tokens, rect),
        .fill = .{ .color = textEditingInkColor(widget, tokens) },
    });
}
