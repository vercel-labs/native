const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const icon_model = @import("icons.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const widget_access = @import("widget_access.zig");
const widget_layout = @import("widget_layout.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_render_controls = @import("widget_render_controls.zig");
const widget_render_style = @import("widget_render_style.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Builder = canvas.Builder;
const Affine = drawing_model.Affine;
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

    // The house style alert geometry: a FIXED 16px icon centered on the first
    // text line's box, a spacing.md gap, and wrapped text hanging past
    // the icon column (`alertContentFrame` indents children the same
    // way, so a description column lines up under the title).
    const text_size = widgetBodyTextSize(widget, tokens);
    const line_height = widgetLineHeight(text_size);
    const inset = widgetControlInset(widget, tokens, tokens.spacing.lg);
    const icon_size = widgetSizedDensityValue(widget, tokens, 16);
    const icon_frame = geometry.RectF.init(
        widget.frame.x + inset,
        widget.frame.y + inset + (line_height - icon_size) * 0.5,
        icon_size,
        icon_size,
    );
    const text_gap = widgetControlInset(widget, tokens, tokens.spacing.md);
    const text_frame = geometry.RectF.init(
        icon_frame.x + icon_size + text_gap,
        widget.frame.y,
        @max(1, widget.frame.width - inset * 2 - icon_size - text_gap),
        widget.frame.height,
    );
    const foreground = widgetForegroundColor(widget, tokens, visual.foreground orelse alertVariantForeground(widget, tokens));
    try emitAlertMark(builder, widget, tokens, icon_frame, foreground);
    // Baseline centered within the first line box, so icon and first
    // line share one optical center.
    const baseline = widget.frame.y + inset + (line_height + text_size * 0.7) * 0.5;
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 10),
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(text_frame.x, baseline)),
        .color = foreground,
        .text = widget.text,
        .text_layout = .{
            .max_width = text_frame.width,
            .line_height = line_height,
            .wrap = .word,
            .alignment = widget.text_alignment,
            .measure = tokens.text_measure,
        },
    });
}

/// The alert's identity color: destructive alerts read in the
/// destructive hue (the house style `text-destructive` treatment on a plain
/// card surface); every other variant keeps the plain foreground.
fn alertVariantForeground(widget: Widget, tokens: DesignTokens) Color {
    return switch (widget.variant) {
        .destructive => tokens.colors.destructive,
        else => tokens.colors.text,
    };
}

pub fn emitAlertMark(builder: *Builder, widget: Widget, tokens: DesignTokens, frame: geometry.RectF, color_value: Color) Error!void {
    const normalized = pixelSnapGeometryRect(tokens, frame.normalized());
    if (normalized.isEmpty()) return;
    // The registry icons the house alerts wear: `info` for the plain
    // variants, the warning triangle for destructive. Icon slots start
    // at 3 (the registry marks are stroke-only, so shapes land on 4/6/8),
    // clear of the chrome slots: fill 1, border 2, clip 9, text 10,
    // blur 12. Slots are 4-bit (`widgetPartId` packs id*16+slot), so
    // they must stay below 16.
    const icon = icon_model.resolve(if (widget.variant == .destructive) "alert" else "info") orelse return;
    try widget_render_controls.emitVectorIcon(builder, widget.id, 3, normalized, color_value, icon);
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
    if (widget.kind == .resizable) try emitResizableWidgetHandle(builder, widget, tokens, visual);
}

/// The house style accordion item: a BORDERLESS row — no fill, no outline,
/// no shadow — with a hairline separator under it, the trigger label on
/// the leading edge of a py-4 header band, and the registry
/// chevron-down on the trailing edge, rotated 180° when expanded. An
/// explicit background (author style or themed control tokens) still
/// paints.
pub fn emitAccordionWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const frame = widget.frame.normalized();
    if (frame.isEmpty()) return;

    const visual = widget_render_style.accordionControlVisualTokens(tokens);
    if (widget.style.background orelse visual.background) |background| {
        try builder.fillRoundedRect(.{
            .id = widgetPartId(widget.id, 1),
            .rect = frame,
            .radius = controlRadius(widget, visual, 0),
            .fill = colorFill(background),
        });
    }
    // The hairline separator between items sits on the item's own
    // bottom edge, so a stack of accordions reads as one divided list.
    try builder.drawLine(.{
        .id = widgetPartId(widget.id, 2),
        .from = pixelSnapGeometryPoint(tokens, geometry.PointF.init(frame.x, frame.maxY())),
        .to = pixelSnapGeometryPoint(tokens, geometry.PointF.init(frame.maxX(), frame.maxY())),
        .stroke = .{
            .fill = widgetBorderFill(widget, visual.border orelse tokens.colors.border),
            .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
        },
    });

    const content = frame.inset(widget.layout.padding);
    if (content.normalized().isEmpty()) return;
    const text_size = widgetBodyTextSize(widget, tokens);
    const header_height = @min(content.height, widget_layout.accordionHeaderHeight(widget, tokens));
    const chevron_size = widgetSizedDensityValue(widget, tokens, 16);
    const chevron_gap = widgetControlInset(widget, tokens, tokens.spacing.md);
    if (widget.text.len > 0) {
        try builder.drawText(.{
            .id = widgetPartId(widget.id, 6),
            .font_id = tokens.typography.font_id,
            .size = text_size,
            .origin = pixelSnapTextPoint(tokens, geometry.PointF.init(content.x, content.y + (header_height + text_size * 0.7) * 0.5)),
            .color = widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
            .text = widget.text,
            .text_layout = .{
                .max_width = @max(1, content.width - chevron_size - chevron_gap),
                .line_height = widgetLineHeight(text_size),
                .wrap = .none,
                .alignment = widget.text_alignment,
                .measure = tokens.text_measure,
            },
        });
    }
    const chevron_frame = geometry.RectF.init(
        content.maxX() - chevron_size,
        content.y + (header_height - chevron_size) * 0.5,
        chevron_size,
        chevron_size,
    );
    try emitAccordionChevron(builder, widget, tokens, chevron_frame);
    if (widget.state.focused) try emitWidgetFocusRing(builder, widget, tokens, 7);
}

/// The disclosure affordance: the registry `chevron-down` icon on the
/// trigger's trailing edge, muted like the house style, rotated 180° about its
/// own center while the item is expanded (the trigger-rotation sampled
/// at its endpoints). The icon takes slots 4/5 (single stroke shape),
/// clear of the chrome slots — slots are 4-bit, never 16 or above.
pub fn emitAccordionChevron(builder: *Builder, widget: Widget, tokens: DesignTokens, frame: geometry.RectF) Error!void {
    const icon = icon_model.resolve("chevron-down") orelse return;
    const normalized = pixelSnapGeometryRect(tokens, frame.normalized());
    if (normalized.isEmpty()) return;
    const color = widgetForegroundColor(widget, tokens, tokens.colors.text_muted);
    if (booleanControlSelected(widget)) {
        // 180° rotation about the icon center — its own inverse, so the
        // same transform closes the pair.
        const flip = Affine{
            .a = -1,
            .b = 0,
            .c = 0,
            .d = -1,
            .tx = normalized.x * 2 + normalized.width,
            .ty = normalized.y * 2 + normalized.height,
        };
        try builder.transform(flip);
        try widget_render_controls.emitVectorIcon(builder, widget.id, 4, normalized, color, icon);
        try builder.transform(flip);
    } else {
        try widget_render_controls.emitVectorIcon(builder, widget.id, 4, normalized, color, icon);
    }
}

/// The house style TabsList: ONE muted rounded container the
/// `segmented_control` triggers sit inside — the container provides the
/// wash, the active trigger lifts to the surface, inactive triggers
/// stay transparent. Borderless by default; themed control tokens or an
/// explicit style can add one.
pub fn emitTabsListWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    // No children guard: the retained layout copy flattens children into
    // sibling nodes, so the container paints purely from its own frame
    // (an empty tabs list lays out to a sliver nothing meaningful paints
    // into).
    const frame = widget.frame.normalized();
    if (frame.isEmpty()) return;
    const visual = tokens.controls.tabs;
    const radius = controlRadius(widget, visual, tokens.radius.lg);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = frame,
        .radius = radius,
        .fill = colorFill(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_subtle)),
    });
    if (widget.style.border orelse visual.border) |border| {
        try builder.strokeRect(.{
            .id = widgetPartId(widget.id, 2),
            .rect = frame,
            .radius = radius,
            .stroke = .{
                .fill = colorFill(border),
                .width = controlStrokeWidth(widget, visual, tokens.stroke.hairline),
            },
        });
    }
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
