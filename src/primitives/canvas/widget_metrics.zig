const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");

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

pub fn widgetControlHeight(widget: Widget, tokens: DesignTokens) f32 {
    return widgetSizedDensityValue(widget, tokens, 34);
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
