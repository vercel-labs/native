const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const widget_access = @import("widget_access.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_render_style = @import("widget_render_style.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Builder = canvas.Builder;
const Color = drawing_model.Color;
const Radius = drawing_model.Radius;
const Stroke = drawing_model.Stroke;
const DesignTokens = token_model.DesignTokens;
const ControlVisualTokens = token_model.ControlVisualTokens;
const Widget = widget_model.Widget;

const booleanControlSelected = widget_access.booleanControlSelected;
const widgetBodyTextSize = widget_metrics.widgetBodyTextSize;
const widgetLineHeight = widget_metrics.widgetLineHeight;
const widgetTypographySize = widget_metrics.widgetTypographySize;
const widgetControlInset = widget_metrics.widgetControlInset;
const widgetSizedDensityValue = widget_metrics.widgetSizedDensityValue;

const colorFill = widget_render_style.colorFill;
const widgetBackgroundFill = widget_render_style.widgetBackgroundFill;
const widgetBorderFill = widget_render_style.widgetBorderFill;
const widgetFocusRingFill = widget_render_style.widgetFocusRingFill;
const widgetBackgroundColor = widget_render_style.widgetBackgroundColor;
const widgetForegroundColor = widget_render_style.widgetForegroundColor;
const widgetRadius = widget_render_style.widgetRadius;
const controlRadius = widget_render_style.controlRadius;
const controlStrokeWidth = widget_render_style.controlStrokeWidth;
const buttonStateBackground = widget_render_style.buttonStateBackground;
const alertControlVisualTokens = widget_render_style.alertControlVisualTokens;
const cardControlVisualTokens = widget_render_style.cardControlVisualTokens;
const dialogControlVisualTokens = widget_render_style.dialogControlVisualTokens;
const drawerControlVisualTokens = widget_render_style.drawerControlVisualTokens;
const sheetControlVisualTokens = widget_render_style.sheetControlVisualTokens;
const surfaceControlVisualTokens = widget_render_style.surfaceControlVisualTokens;

pub fn emitAlertWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = alertControlVisualTokens(tokens);
    const radius = controlRadius(widget, visual, tokens.radius.lg);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.text.len == 0) return;

    const text_size = widgetBodyTextSize(widget, tokens);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    const icon_size = @max(widgetSizedDensityValue(widget, tokens, 12), text_size - 1);
    const icon_frame = geometry.RectF.init(widget.frame.x + inset, widget.frame.y + inset, icon_size, icon_size);
    const text_gap = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text_frame = geometry.RectF.init(
        icon_frame.x + icon_size + text_gap,
        widget.frame.y,
        @max(1, widget.frame.width - inset * 2 - icon_size - text_gap),
        widget.frame.height,
    );
    const foreground = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    try emitAlertMark(builder, widget, tokens, icon_frame, foreground);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 6),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(text_frame.x, widget.frame.y + inset + text_size)),
        .color = foreground,
        .text = widget.text,
        .text_layout = .{
            .max_width = text_frame.width,
            .line_height = widgetLineHeight(text_size),
            .wrap = .word,
            .alignment = widget.text_alignment,
            .measure = tokens.text_measure,
        },
    });
}

pub fn emitAlertMark(builder: *Builder, widget: Widget, tokens: DesignTokens, frame: geometry.RectF, color_value: Color) Error!void {
    const normalized = pixelSnapGeometryRect(tokens, frame.normalized());
    if (normalized.isEmpty()) return;
    const stroke = Stroke{ .fill = colorFill(color_value), .width = tokens.stroke.regular };
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = normalized,
        .radius = Radius.all(normalized.height * 0.5),
        .stroke = stroke,
    });
    const center_x = normalized.x + normalized.width * 0.5;
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 4),
        .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center_x, normalized.y + normalized.height * 0.28)),
        .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(center_x, normalized.y + normalized.height * 0.58)),
        .stroke = stroke,
    });
    const dot_size = @max(1, normalized.height * 0.14);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 5),
        .rect = pixelSnapGeometryRect(tokens, geometry.RectF.init(center_x - dot_size * 0.5, normalized.y + normalized.height * 0.70, dot_size, dot_size)),
        .radius = Radius.all(dot_size * 0.5),
        .fill = colorFill(color_value),
    });
}

pub fn emitCardWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = cardControlVisualTokens(tokens);
    const radius = controlRadius(widget, visual, tokens.radius.lg);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface))),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.text.len == 0) return;

    const title_size = widgetTypographySize(widget, tokens.typography.body_size + 1);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 3),
        .font_id = tokens.typography.font_id,
        .size = title_size,
        .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(widget.frame.x + inset, widget.frame.y + inset + title_size)),
        .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .text = widget.text,
        .text_layout = .{
            .max_width = @max(1, widget.frame.width - inset * 2),
            .line_height = widgetLineHeight(title_size),
            .wrap = .word,
            .alignment = widget.text_alignment,
            .measure = tokens.text_measure,
        },
    });
}

pub fn emitDialogSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitModalSurfaceWidgetChrome(builder, widget, tokens, dialogControlVisualTokens(tokens), tokens.radius.xl);
}

pub fn emitDrawerSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitModalSurfaceWidgetChrome(builder, widget, tokens, drawerControlVisualTokens(tokens), tokens.radius.xl);
}

pub fn emitSheetSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitModalSurfaceWidgetChrome(builder, widget, tokens, sheetControlVisualTokens(tokens), tokens.radius.lg);
}

pub fn emitModalSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens, fallback_radius: f32) Error!void {
    const radius = controlRadius(widget, visual, fallback_radius);
    const shadow_token = tokens.shadow.md;
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
        .fill = widgetBackgroundFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.text.len == 0) return;

    const title_size = widgetTypographySize(widget, tokens.typography.title_size);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.xl);
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 4),
        .font_id = tokens.typography.font_id,
        .size = title_size,
        .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(widget.frame.x + inset, widget.frame.y + inset + title_size)),
        .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .text = widget.text,
        .text_layout = .{
            .max_width = @max(1, widget.frame.width - inset * 2),
            .line_height = widgetLineHeight(title_size),
            .wrap = .word,
            .alignment = widget.text_alignment,
            .measure = tokens.text_measure,
        },
    });
}

pub fn emitPanelWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = surfaceControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.lg);
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
        .fill = widgetBackgroundFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
    if (widget.kind == .accordion) {
        try emitAccordionWidgetHeader(builder, widget, tokens, visual);
        if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 7);
    }
    if (widget.kind == .resizable) try emitResizableWidgetHandle(builder, widget, tokens, visual);
}

pub fn emitAccordionWidgetHeader(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Error!void {
    const frame = widget.frame.normalized();
    if (frame.isEmpty()) return;

    const inset = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text_size = widgetBodyTextSize(widget, tokens);
    const chevron_size = @max(widgetSizedDensityValue(widget, tokens, 10), text_size - 2);
    const chevron_center = geometry.PointF.init(frame.maxX() - inset - chevron_size * 0.5, frame.y + @min(frame.height * 0.5, inset + text_size * 0.45));
    const color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    if (widget.text.len > 0) {
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 6),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(frame.x + inset, frame.y + inset + text_size)),
            .color = color,
            .text = widget.text,
            .text_layout = .{
                .max_width = @max(1, frame.width - inset * 3 - chevron_size),
                .line_height = widgetLineHeight(text_size),
                .wrap = .none,
                .alignment = widget.text_alignment,
                .measure = tokens.text_measure,
            },
        });
    }
    try emitAccordionChevron(builder, widget, tokens, chevron_center, chevron_size, color);
}

pub fn emitAccordionChevron(builder: *Builder, widget: Widget, tokens: DesignTokens, center: geometry.PointF, size: f32, color: Color) Error!void {
    const half = size * 0.28;
    const rise = size * 0.24;
    const stroke = Stroke{ .fill = colorFill(color), .width = tokens.stroke.regular };
    const selected = booleanControlSelected(widget);
    const first_from = if (selected)
        geometry.PointF.init(center.x - half, center.y - rise)
    else
        geometry.PointF.init(center.x - rise, center.y - half);
    const first_to = if (selected)
        geometry.PointF.init(center.x, center.y + rise)
    else
        geometry.PointF.init(center.x + rise, center.y);
    const second_to = if (selected)
        geometry.PointF.init(center.x + half, center.y - rise)
    else
        geometry.PointF.init(center.x - rise, center.y + half);
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 4),
        .from = pixelSnapGeometryPoint(tokens, first_from),
        .to = pixelSnapGeometryPoint(tokens, first_to),
        .stroke = stroke,
    });
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 5),
        .from = pixelSnapGeometryPoint(tokens, first_to),
        .to = pixelSnapGeometryPoint(tokens, second_to),
        .stroke = stroke,
    });
}

pub fn emitResizableWidgetHandle(builder: *Builder, widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Error!void {
    const frame = widget.frame.normalized();
    if (frame.isEmpty()) return;

    const inset = widgetSizedDensityValue(widget, tokens, 6);
    const gap = widgetSizedDensityValue(widget, tokens, 4);
    const handle_height = @min(@max(widgetSizedDensityValue(widget, tokens, 10), frame.height * 0.48), @max(0, frame.height - inset * 2));
    if (handle_height <= 0) return;

    const right_x = @max(frame.x + inset, frame.maxX() - inset);
    const left_x = @max(frame.x + inset, right_x - gap);
    const y0 = frame.y + (frame.height - handle_height) * 0.5;
    const y1 = y0 + handle_height;
    const stroke = Stroke{
        .fill = colorFill(widgetForegroundColor(widget, tokens, visual.foreground orelse visual.border orelse tokens.colors.text_muted)),
        .width = controlStrokeWidth(widget, visual, tokens.stroke.regular),
    };

    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 4),
        .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left_x, y0)),
        .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(left_x, y1)),
        .stroke = stroke,
    });
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 5),
        .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(right_x, y0)),
        .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(right_x, y1)),
        .stroke = stroke,
    });
}

pub fn emitPopoverWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = surfaceControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.xl);
    const shadow_token = tokens.shadow.md;
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
        .fill = widgetBackgroundFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
}

pub fn emitMenuSurfaceWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const visual = surfaceControlVisualTokens(widget, tokens);
    const radius = controlRadius(widget, visual, tokens.radius.lg);
    const shadow_token = tokens.shadow.md;
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
        .fill = widgetBackgroundFill(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface)),
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });
}

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

fn widgetPartId(id: ObjectId, slot: ObjectId) ObjectId {
    return widget_model.widgetCommandPartId(.{ .widget_id = id, .slot = slot });
}

fn emitWidgetFocusRing(builder: *Builder, widget: Widget, tokens: DesignTokens, slot: ObjectId) Error!void {
    // The shared ring-offset treatment: a concentric ring 2px outside
    // the widget's own border (see widget_render_style).
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, slot),
        .rect = widget_render_style.focusRingRect(widget.frame),
        .radius = widget_render_style.focusRingRadius(widgetRadius(widget, tokens.radius.md)),
        .stroke = .{
            .fill = widgetFocusRingFill(widget, tokens),
            .width = tokens.stroke.focus,
        },
    });
}
