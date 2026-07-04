const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const text_spans_model = @import("text_spans.zig");

const Density = token_model.Density;
const DesignTokens = token_model.DesignTokens;
const Widget = widget_model.Widget;

const default_widget_row_extent: f32 = 28;

pub fn widgetButtonTextSize(widget: Widget, tokens: DesignTokens) f32 {
    return widgetTypographySize(widget, tokens.typography.button_size);
}

pub fn widgetBodyTextSize(widget: Widget, tokens: DesignTokens) f32 {
    return widgetTypographySize(widget, tokens.typography.body_size);
}

pub fn widgetLabelTextSize(widget: Widget, tokens: DesignTokens) f32 {
    return widgetTypographySize(widget, tokens.typography.label_size);
}

pub fn widgetTypographySize(widget: Widget, base: f32) f32 {
    return switch (widget.size) {
        .sm => @max(8, base - 1),
        .default, .icon => base,
        .lg => base + 1,
    };
}

pub fn widgetLineHeight(text_size: f32) f32 {
    return text_size * 1.25;
}

/// The single source of truth for how a span paragraph (`.text` widget
/// with `spans`) lays out: intrinsic sizing, wrapped-height reservation,
/// link hit-area frames, and command emission all build their options
/// here so they agree byte-for-byte. One deliberate exception: emission
/// widens `max_width` by the pixel-snap quantum (`textWrapMaxWidth`) so
/// a snapped paint frame never wraps a line the layout frame fit —
/// painted lines are therefore always <= the reserved line count.
pub fn widgetTextSpanLayoutOptions(widget: Widget, tokens: DesignTokens, max_width: f32) text_spans_model.TextSpanLayoutOptions {
    return .{
        .size = widgetBodyTextSize(widget, tokens),
        .max_width = max_width,
        .wrap = .word,
        .alignment = widget.text_alignment,
        .typography = tokens.typography,
        .measure = tokens.text_measure,
    };
}

/// 36px default control height — the h-9 metric house buttons,
/// inputs, and select triggers share (sm/lg step through the size scale).
pub fn widgetControlHeight(widget: Widget, tokens: DesignTokens) f32 {
    return widgetSizedDensityValue(widget, tokens, 36);
}

/// Vector icon extent inside icon-bearing controls (a button's
/// `widget.icon`): sized just above the label text so icon and label
/// read as one line. Shared by intrinsic layout and render so measured
/// widths and painted pixels agree.
pub fn widgetButtonIconExtent(widget: Widget, tokens: DesignTokens) f32 {
    return widgetButtonTextSize(widget, tokens) + 2;
}

/// Gap between a button's inline icon and its label.
pub fn widgetButtonIconGap(widget: Widget, tokens: DesignTokens) f32 {
    return widgetControlInset(widget, tokens, tokens.spacing.sm);
}

/// Extent of a vector icon inside a badge (`widget.icon`): sized just
/// above the badge's label text. Shared by intrinsic layout and render.
pub fn widgetBadgeIconExtent(widget: Widget, tokens: DesignTokens) f32 {
    return widgetLabelTextSize(widget, tokens) + 2;
}

/// Gap between a badge's inline icon and its label.
pub fn widgetBadgeIconGap(widget: Widget, tokens: DesignTokens) f32 {
    return widgetControlInset(widget, tokens, tokens.spacing.sm);
}

/// Extent of a leading vector icon in row-shaped controls (`list_item`,
/// `menu_item` via `widget.icon`): sized just above the body text so
/// icon and label read as one line. Shared by intrinsic layout and
/// render so measured widths and painted pixels agree.
pub fn widgetRowIconExtent(widget: Widget, tokens: DesignTokens) f32 {
    return widgetBodyTextSize(widget, tokens) + 2;
}

/// Gap between a row's leading icon and its label.
pub fn widgetRowIconGap(widget: Widget, tokens: DesignTokens) f32 {
    return widgetControlInset(widget, tokens, tokens.spacing.sm);
}

pub fn widgetDefaultRowHeight(widget: Widget, tokens: DesignTokens) f32 {
    return widgetSizedDensityValue(widget, tokens, default_widget_row_extent);
}

pub fn widgetButtonInset(widget: Widget, tokens: DesignTokens) f32 {
    return switch (widget.size) {
        .icon => 0,
        else => widgetControlInset(widget, tokens, tokens.spacing.md),
    };
}

pub fn widgetControlInset(widget: Widget, tokens: DesignTokens, base: f32) f32 {
    return densityValue(tokens, widgetSizedTokenValue(widget, base));
}

pub fn widgetSizedDensityValue(widget: Widget, tokens: DesignTokens, value: f32) f32 {
    return densityValue(tokens, value) * widgetSizeScale(widget);
}

pub fn widgetSizedTokenValue(widget: Widget, value: f32) f32 {
    return switch (widget.size) {
        .sm => @max(0, value - 2),
        .default, .icon => value,
        .lg => value + 2,
    };
}

pub fn widgetSizeScale(widget: Widget) f32 {
    return switch (widget.size) {
        .sm => 0.875,
        .default, .icon => 1,
        .lg => 1.125,
    };
}

pub fn densityValue(tokens: DesignTokens, value: f32) f32 {
    return value * densityScale(tokens.density);
}

pub fn densityScale(density: Density) f32 {
    return switch (density) {
        .compact => 0.875,
        .regular => 1,
        .spacious => 1.125,
    };
}
