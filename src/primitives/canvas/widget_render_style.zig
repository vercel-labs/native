const std = @import("std");
const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");

const Color = drawing_model.Color;
const Fill = drawing_model.Fill;
const Radius = drawing_model.Radius;
const DesignTokens = token_model.DesignTokens;
const ControlVisualTokens = token_model.ControlVisualTokens;
const Widget = widget_model.Widget;
const WidgetState = widget_model.WidgetState;

/// How far the focus ring sits outside the control's border — the
/// ring-offset treatment: the control keeps its own border and the ring
/// floats a hairline gap outside it, so focus never restyles the control.
pub const focus_ring_offset: f32 = 2;

/// The frame the focus ring strokes: the control rect pushed out by the
/// ring offset.
pub fn focusRingRect(rect: geometry.RectF) geometry.RectF {
    return rect.normalized().inflate(geometry.InsetsF.all(focus_ring_offset));
}

/// The ring's corner radius: the control's own radius grown by the
/// offset so the ring stays concentric with the border it wraps.
pub fn focusRingRadius(radius: Radius) Radius {
    return .{
        .top_left = radius.top_left + focus_ring_offset,
        .top_right = radius.top_right + focus_ring_offset,
        .bottom_right = radius.bottom_right + focus_ring_offset,
        .bottom_left = radius.bottom_left + focus_ring_offset,
    };
}

pub fn textInputAffordanceColor(widget: Widget, tokens: DesignTokens) Color {
    const visual = textInputControlVisualTokens(widget, tokens);
    return widget.style.focus_ring orelse widget.style.accent orelse visual.active_background orelse tokens.colors.focus_ring;
}

pub fn textSelectionFillColor(widget: Widget, tokens: DesignTokens) Color {
    return colorWithAlpha(textInputAffordanceColor(widget, tokens), 0.18);
}

pub fn colorWithAlpha(color: Color, alpha: f32) Color {
    return Color.rgba(color.r, color.g, color.b, std.math.clamp(alpha, 0, 1));
}

pub fn colorFill(color: Color) Fill {
    return .{ .color = color };
}

pub fn widgetBackgroundFill(widget: Widget, fallback: Color) Fill {
    return colorFill(widget.style.background orelse fallback);
}

pub fn widgetAccentFill(widget: Widget, fallback: Color) Fill {
    return colorFill(widget.style.accent orelse fallback);
}

pub fn widgetBorderFill(widget: Widget, fallback: Color) Fill {
    return colorFill(widget.style.border orelse fallback);
}

pub fn widgetFocusRingFill(widget: Widget, tokens: DesignTokens) Fill {
    return colorFill(widget.style.focus_ring orelse tokens.colors.focus_ring);
}

pub fn widgetBackgroundColor(widget: Widget, fallback: Color) Color {
    return widget.style.background orelse fallback;
}

pub fn widgetAccentColor(widget: Widget, fallback: Color) Color {
    return widget.style.accent orelse fallback;
}

pub fn widgetBorderColor(widget: Widget, fallback: Color) Color {
    return widget.style.border orelse fallback;
}

pub fn widgetForegroundColor(widget: Widget, tokens: DesignTokens, fallback: Color) Color {
    if (widget.state.disabled) return tokens.colors.text_muted;
    return widget.style.foreground orelse fallback;
}

pub fn widgetAccentForegroundColor(widget: Widget, tokens: DesignTokens, fallback: Color) Color {
    if (widget.state.disabled) return tokens.colors.text_muted;
    return widget.style.accent_foreground orelse fallback;
}

pub fn widgetRadius(widget: Widget, fallback: f32) Radius {
    if (widget.style.radius) |radius| return Radius.all(nonNegative(radius));
    return Radius.all(nonNegative(widgetSizedRadiusValue(widget, fallback)));
}

pub fn controlRadius(widget: Widget, visual: ControlVisualTokens, fallback: f32) Radius {
    if (widget.style.radius) |radius| return Radius.all(nonNegative(radius));
    return Radius.all(nonNegative(widgetSizedRadiusValue(widget, visual.radius orelse fallback)));
}

pub fn widgetSizedRadiusValue(widget: Widget, fallback: f32) f32 {
    return switch (widget.size) {
        .sm => @max(0, fallback - 2),
        // heading/display are text-leaf typography rungs; radii are
        // control chrome, so they sit at the default step.
        .default, .icon, .heading, .display => fallback,
        .lg => fallback + 2,
    };
}

pub fn widgetStrokeWidth(widget: Widget, fallback: f32) f32 {
    return nonNegative(widget.style.stroke_width orelse fallback);
}

pub fn controlStrokeWidth(widget: Widget, visual: ControlVisualTokens, fallback: f32) f32 {
    return nonNegative(widget.style.stroke_width orelse visual.stroke_width orelse fallback);
}

pub fn buttonFill(widget: Widget, tokens: DesignTokens) Fill {
    if (widget.state.disabled) return colorFill(tokens.colors.disabled);
    const active = widget.state.pressed or widget.state.selected;
    const visual = buttonControlVisualTokens(widget, tokens);
    return switch (widget.variant) {
        .default => if (active)
            colorFill(widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent))
        else if (widget.state.hovered)
            colorFill(widgetBackgroundColor(widget, visual.hover_background orelse tokens.colors.surface_subtle))
        else
            colorFill(widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface)),
        // Filled variants hover by dropping their fill to 90% alpha (80%
        // for secondary) — the wash lightens on light surfaces and
        // deepens on dark ones without a second color per scheme.
        .primary => colorFill(widgetAccentColor(widget, buttonStateBackground(visual, active, widget.state.hovered, hoverWash(tokens.colors.accent, active, widget.state.hovered, 0.9)))),
        .secondary => colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, active, widget.state.hovered, if (active) tokens.colors.surface_pressed else hoverWash(tokens.colors.surface_subtle, false, widget.state.hovered, 0.8)))),
        .outline => colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, active, widget.state.hovered, if (active or widget.state.hovered) tokens.colors.surface_subtle else transparentColor()))),
        .ghost => colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, active, widget.state.hovered, if (active or widget.state.hovered) tokens.colors.surface_subtle else transparentColor()))),
        .destructive => colorFill(widgetAccentColor(widget, buttonStateBackground(visual, active, widget.state.hovered, hoverWash(tokens.colors.destructive, active, widget.state.hovered, 0.9)))),
    };
}

/// The hover state of a filled control: the base color at reduced
/// alpha while hovered (and not pressed), the base color otherwise.
fn hoverWash(base: Color, active: bool, hovered: bool, alpha: f32) Color {
    if (hovered and !active) return colorWithAlpha(base, alpha * base.a);
    return base;
}

pub fn buttonTextColorForWidget(widget: Widget, tokens: DesignTokens) Color {
    if (widget.state.disabled) return tokens.colors.text_muted;
    const active = widget.state.pressed or widget.state.selected;
    const visual = buttonControlVisualTokens(widget, tokens);
    return switch (widget.variant) {
        .default => if (active)
            widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text)
        else
            widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .primary => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text),
        .secondary, .outline, .ghost => widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .destructive => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.destructive_text),
    };
}

pub fn buttonBorderFill(widget: Widget, tokens: DesignTokens) Fill {
    if (widget.style.border) |border| return colorFill(border);
    const visual = buttonControlVisualTokens(widget, tokens);
    // A disabled button drops to the muted disabled fill, so the border
    // mutes with it: the filled variants' accent edge would otherwise
    // outline the gray fill in full-strength accent (the "idle button
    // wearing a blue ring" read). Ghost keeps its no-border shape.
    if (widget.state.disabled) {
        return switch (widget.variant) {
            .ghost => colorFill(widgetBorderColor(widget, visual.border orelse transparentColor())),
            else => colorFill(widgetBorderColor(widget, visual.border orelse tokens.colors.border)),
        };
    }
    return switch (widget.variant) {
        .primary => colorFill(widgetAccentColor(widget, visual.border orelse tokens.colors.accent)),
        .destructive => colorFill(widgetAccentColor(widget, visual.border orelse tokens.colors.destructive)),
        .ghost => colorFill(widgetBorderColor(widget, visual.border orelse transparentColor())),
        else => colorFill(widgetBorderColor(widget, visual.border orelse tokens.colors.border)),
    };
}

pub fn buttonControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    const variant = switch (widget.variant) {
        .default => tokens.controls.button_default,
        .primary => tokens.controls.button_primary,
        .secondary => tokens.controls.button_secondary,
        .outline => tokens.controls.button_outline,
        .ghost => tokens.controls.button_ghost,
        .destructive => tokens.controls.button_destructive,
    };
    if (widget.kind == .toggle_button) return controlVisualTokensWithFallback(tokens.controls.toggle_button, variant);
    return variant;
}

pub fn selectControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.select, tokens.controls.button_outline);
}

pub fn controlVisualTokensWithFallback(primary: ControlVisualTokens, fallback: ControlVisualTokens) ControlVisualTokens {
    return .{
        .background = primary.background orelse fallback.background,
        .hover_background = primary.hover_background orelse fallback.hover_background,
        .active_background = primary.active_background orelse fallback.active_background,
        .foreground = primary.foreground orelse fallback.foreground,
        .border = primary.border orelse fallback.border,
        .radius = primary.radius orelse fallback.radius,
        .stroke_width = primary.stroke_width orelse fallback.stroke_width,
    };
}

pub fn buttonStateBackground(visual: ControlVisualTokens, active: bool, hovered: bool, fallback: Color) Color {
    if (active) return visual.active_background orelse visual.hover_background orelse visual.background orelse fallback;
    if (hovered) return visual.hover_background orelse visual.background orelse fallback;
    return visual.background orelse fallback;
}

pub fn textInputControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .input => controlVisualTokensWithFallback(tokens.controls.input, tokens.controls.text_field),
        .search_field => tokens.controls.search_field,
        .combobox => controlVisualTokensWithFallback(tokens.controls.combobox, tokens.controls.search_field),
        .textarea => tokens.controls.textarea,
        else => tokens.controls.text_field,
    };
}

pub fn textInputFill(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Fill {
    if (widget.state.disabled) return colorFill(tokens.colors.disabled);
    return colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, widget.state.hovered, tokens.colors.surface)));
}

pub fn textInputBorderFill(widget: Widget, visual: ControlVisualTokens, fallback: Color) Fill {
    return colorFill(widgetBorderColor(widget, visual.border orelse fallback));
}

pub fn accordionControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.accordion, tokens.controls.panel);
}

pub fn alertControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.alert, tokens.controls.panel);
}

pub fn bubbleControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.bubble, tokens.controls.panel);
}

pub fn cardControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.card, tokens.controls.panel);
}

pub fn dialogControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.dialog, tokens.controls.popover);
}

pub fn drawerControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.drawer, tokens.controls.popover);
}

pub fn sheetControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.sheet, tokens.controls.popover);
}

pub fn listItemControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .data_cell => controlVisualTokensWithFallback(tokens.controls.data_cell, tokens.controls.list_item),
        .menu_item => controlVisualTokensWithFallback(tokens.controls.menu_item, tokens.controls.list_item),
        .list_item => tokens.controls.list_item,
        else => .{},
    };
}

pub fn selectionControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .segmented_control => tokens.controls.segmented_control,
        .checkbox => tokens.controls.checkbox,
        .radio => tokens.controls.radio,
        .switch_control, .toggle => tokens.controls.toggle,
        .slider => tokens.controls.slider,
        .progress => tokens.controls.progress,
        else => .{},
    };
}

pub fn surfaceControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .accordion => accordionControlVisualTokens(tokens),
        .alert => alertControlVisualTokens(tokens),
        .bubble => bubbleControlVisualTokens(tokens),
        .card => cardControlVisualTokens(tokens),
        .dialog => dialogControlVisualTokens(tokens),
        .drawer => drawerControlVisualTokens(tokens),
        .sheet => sheetControlVisualTokens(tokens),
        .panel => tokens.controls.panel,
        .resizable => resizableControlVisualTokens(tokens),
        .popover => tokens.controls.popover,
        .menu_surface => tokens.controls.menu_surface,
        .dropdown_menu => controlVisualTokensWithFallback(tokens.controls.dropdown_menu, tokens.controls.menu_surface),
        .tooltip => tokens.controls.tooltip,
        else => .{},
    };
}

pub fn resizableControlVisualTokens(tokens: DesignTokens) ControlVisualTokens {
    return controlVisualTokensWithFallback(tokens.controls.resizable, tokens.controls.panel);
}

pub fn componentControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .avatar => tokens.controls.avatar,
        .badge => tokens.controls.badge,
        .separator => tokens.controls.separator,
        .skeleton => tokens.controls.skeleton,
        .spinner => tokens.controls.spinner,
        else => .{},
    };
}

pub fn componentPillRadius(widget: Widget, visual: ControlVisualTokens, fallback: f32) Radius {
    if (widget.style.radius) |radius| return Radius.all(nonNegative(radius));
    if (visual.radius) |radius| return Radius.all(nonNegative(radius));
    return Radius.all(nonNegative(fallback));
}

pub fn badgeBackgroundColor(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Color {
    if (widget.state.disabled) return tokens.colors.disabled;
    return switch (widget.variant) {
        .default, .primary => widgetAccentColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.accent)),
        .secondary => widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.surface_subtle)),
        .outline, .ghost => widgetBackgroundColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, if (widget.state.hovered or widget.state.pressed) tokens.colors.surface_subtle else transparentColor())),
        .destructive => widgetAccentColor(widget, buttonStateBackground(visual, widget.state.pressed or widget.state.selected, widget.state.hovered, tokens.colors.destructive)),
    };
}

pub fn badgeBorderColor(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Color {
    return switch (widget.variant) {
        .default, .primary => widgetAccentColor(widget, visual.border orelse tokens.colors.accent),
        .destructive => widgetAccentColor(widget, visual.border orelse tokens.colors.destructive),
        else => widgetBorderColor(widget, visual.border orelse tokens.colors.border),
    };
}

pub fn badgeTextColor(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Color {
    if (widget.state.disabled) return tokens.colors.text_muted;
    return switch (widget.variant) {
        .default, .primary => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text),
        .destructive => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.destructive_text),
        else => widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
    };
}

pub fn badgeStrokeWidth(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) f32 {
    if (widget.style.stroke_width) |width| return nonNegative(width);
    if (visual.stroke_width) |width| return nonNegative(width);
    return switch (widget.variant) {
        .ghost => 0,
        else => tokens.stroke.hairline,
    };
}

pub fn buttonStrokeWidth(widget: Widget, tokens: DesignTokens) f32 {
    if (widget.style.stroke_width) |width| return nonNegative(width);
    const visual = buttonControlVisualTokens(widget, tokens);
    if (visual.stroke_width) |width| return nonNegative(width);
    return switch (widget.variant) {
        .ghost => 0,
        else => tokens.stroke.regular,
    };
}

pub fn listItemFillColor(widget: Widget, tokens: DesignTokens, state: WidgetState) Color {
    const visual = listItemControlVisualTokens(widget, tokens);
    const fallback = if (state.selected or state.pressed)
        tokens.colors.surface_pressed
    else if (state.hovered)
        tokens.colors.surface_subtle
    else
        transparentColor();
    return buttonStateBackground(visual, state.selected or state.pressed, state.hovered, fallback);
}

pub fn transparentColor() Color {
    return Color.rgba(0, 0, 0, 0);
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
