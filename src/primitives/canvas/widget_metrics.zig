const std = @import("std");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const text_spans_model = @import("text_spans.zig");

const Density = token_model.Density;
const DesignTokens = token_model.DesignTokens;
const Widget = widget_model.Widget;

/// Button labels step by the token-stated ladder
/// (`metrics.button_label_sm_step`/`button_label_lg_step`): the house
/// register holds the base size at default and lg — a bigger button
/// earns more chrome (height, inset), not bigger glyphs — while sm
/// steps the label down 1.2px (14 -> 12.8 on the default scale): the
/// compact rung is a genuinely smaller control, and a full-size label
/// inside a 28px box crowds its own padding. The fractional step is
/// deliberate — the measured compact label size, not a rounded
/// approximation. Packs with a large-button type rung state a positive
/// lg step.
pub fn widgetButtonTextSize(widget: Widget, tokens: DesignTokens) f32 {
    return switch (widget.size) {
        .sm => @max(8, tokens.typography.button_size - tokens.metrics.button_label_sm_step),
        .lg => @max(8, tokens.typography.button_size + tokens.metrics.button_label_lg_step),
        .default, .icon, .heading, .display => tokens.typography.button_size,
    };
}

pub fn widgetBodyTextSize(widget: Widget, tokens: DesignTokens) f32 {
    // heading/display are typography-token rungs, honored on text leaves
    // only: they REPLACE the body base with the named token instead of
    // stepping it, so the whole type scale stays themable through
    // `TypographyTokenOverrides`. Like the other typography sizes they do
    // not density-scale (density scales chrome — insets, heights — never
    // glyph sizes). On any other widget kind they fall through to the
    // default control step (the markup layer rejects them there; Zig
    // views get a Debug warning from `Ui.el`).
    if (widget.kind == .text) {
        switch (widget.size) {
            .heading => return tokens.typography.heading_size,
            .display => return tokens.typography.display_size,
            else => {},
        }
    }
    return widgetTypographySize(widget, tokens.typography.body_size);
}

pub fn widgetLabelTextSize(widget: Widget, tokens: DesignTokens) f32 {
    return widgetTypographySize(widget, tokens.typography.label_size);
}

/// Badge text sits one rung below the label size (12 on the default
/// scale) — the compact chip register.
pub fn widgetBadgeTextSize(widget: Widget, tokens: DesignTokens) f32 {
    return widgetTypographySize(widget, @max(8, tokens.typography.label_size - 1));
}

pub fn widgetTypographySize(widget: Widget, base: f32) f32 {
    return switch (widget.size) {
        .sm => @max(8, base - 1),
        // heading/display are text-leaf typography rungs (resolved in
        // `widgetBodyTextSize`); on the control scale they sit at the
        // default step.
        .default, .icon, .heading, .display => base,
        .lg => base + 1,
    };
}

pub fn widgetLineHeight(text_size: f32) f32 {
    return text_size * 1.25;
}

/// Wrap budget for text painted inside a pixel-snapped frame. Geometry
/// snapping rounds each frame EDGE to the device grid independently
/// (`pixelSnapGeometryRect`), so a frame at a fractional position can
/// lose up to a FULL device pixel of width — the left edge rounds up by
/// as much as half a pixel while the right edge rounds down by as much
/// as half — off the layout frame that intrinsic sizing measured with
/// the exact same metrics. That shave is enough to word-wrap an
/// exact-fit line mid-word ("Sort" painting as "Sor"/"t") or to elide a
/// hug-sized digit into "…" (the TS scaffold's centered counter on
/// Windows at scale 1, where the shave is coarsest). Hand the whole
/// snap quantum back to the budget so snapping never changes line
/// breaks or elision; glyph origins still snap independently. Epsilon
/// policy: a run's painted width may exceed its snapped frame by less
/// than `1/scale + text_elision_slack` before eliding — always below
/// the smallest real overflow (a glyph), so genuinely overflowing text
/// still elides and any admitted overhang stays sub-pixel-scale.
pub fn textWrapMaxWidth(tokens: DesignTokens, width: f32) f32 {
    if (!tokens.pixel_snap.geometry) return width;
    const scale = tokens.pixel_snap.scale;
    if (!std.math.isFinite(scale) or scale <= 0) return width;
    return width + 1.0 / scale;
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

/// The ONE control height register — buttons, inputs, and select
/// triggers all sit on the whole-pixel token ladder
/// (`metrics.control_height_sm`/`control_height`/`control_height_lg`,
/// 28/32/36 in the house register) instead of the multiplicative size
/// scale (which lands on fractional heights): heights on the 4px grid
/// keep a mixed toolbar row at exactly one height and pixel-snap
/// cleanly at every scale factor. Every kind on the register moves
/// together — a 32px button beside a 36px input would break the
/// one-toolbar-row invariant this ladder exists for. The `icon` size is
/// the default square.
pub fn widgetControlHeight(widget: Widget, tokens: DesignTokens) f32 {
    const base: f32 = switch (widget.size) {
        .sm => tokens.metrics.control_height_sm,
        .default, .icon, .heading, .display => tokens.metrics.control_height,
        .lg => tokens.metrics.control_height_lg,
    };
    return densityValue(tokens, base);
}

/// Vector icon extent inside icon-bearing controls (a button's
/// `widget.icon`): sized just above the label text
/// (`metrics.icon_text_step`) so icon and label read as one line.
/// Shared by intrinsic layout and render so measured widths and painted
/// pixels agree.
pub fn widgetButtonIconExtent(widget: Widget, tokens: DesignTokens) f32 {
    return widgetButtonTextSize(widget, tokens) + tokens.metrics.icon_text_step;
}

/// Gap between a button's inline icon and its label: ONE register
/// (`metrics.button_icon_gap`) at every step. The gap is intra-content
/// spacing — the glyph and the label are one phrase — so it never
/// widens with the size ladder; a bigger button earns more air at its
/// edges (the inset), not inside its own label.
pub fn widgetButtonIconGap(widget: Widget, tokens: DesignTokens) f32 {
    _ = widget;
    return densityValue(tokens, tokens.metrics.button_icon_gap);
}

/// Extent of a vector icon inside a badge (`widget.icon`): sized just
/// above the badge's label text. Shared by intrinsic layout and render.
pub fn widgetBadgeIconExtent(widget: Widget, tokens: DesignTokens) f32 {
    return widgetLabelTextSize(widget, tokens) + tokens.metrics.icon_text_step;
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
    return widgetBodyTextSize(widget, tokens) + tokens.metrics.icon_text_step;
}

/// Gap between a row's leading icon and its label.
pub fn widgetRowIconGap(widget: Widget, tokens: DesignTokens) f32 {
    return widgetControlInset(widget, tokens, tokens.spacing.sm);
}

pub fn widgetDefaultRowHeight(widget: Widget, tokens: DesignTokens) f32 {
    return widgetSizedDensityValue(widget, tokens, tokens.metrics.row_extent);
}

/// A button's horizontal inset per size rung
/// (`metrics.button_inset_sm`/`button_inset`/`button_inset_lg`). The
/// house register holds ONE 10px inset across the ladder — the sizes
/// already speak through height, radius, and (at sm) the label step, so
/// the padding stays put; a wider inset ladder made buttons read as
/// differently PROPORTIONED controls instead of the same control at
/// three rungs, and 10px is what the compact control heights (28/32/36)
/// can honestly afford. Packs on a taller ladder state each rung.
/// `icon`-sized buttons center their glyph in the square and need no
/// inset.
pub fn widgetButtonInset(widget: Widget, tokens: DesignTokens) f32 {
    if (widget.size == .icon) return 0;
    const base: f32 = switch (widget.size) {
        .sm => tokens.metrics.button_inset_sm,
        .default, .icon, .heading, .display => tokens.metrics.button_inset,
        .lg => tokens.metrics.button_inset_lg,
    };
    return densityValue(tokens, base);
}

pub fn widgetControlInset(widget: Widget, tokens: DesignTokens, base: f32) f32 {
    return densityValue(tokens, widgetSizedTokenValue(widget, tokens, base));
}

pub fn widgetSizedDensityValue(widget: Widget, tokens: DesignTokens, value: f32) f32 {
    return densityValue(tokens, value) * widgetSizeScale(widget);
}

pub fn widgetSizedTokenValue(widget: Widget, tokens: DesignTokens, value: f32) f32 {
    const step = tokens.metrics.size_inset_step;
    return switch (widget.size) {
        .sm => @max(0, value - step),
        // heading/display step type, not chrome: control metrics stay at
        // the default step.
        .default, .icon, .heading, .display => value,
        .lg => value + step,
    };
}

pub fn widgetSizeScale(widget: Widget) f32 {
    return switch (widget.size) {
        .sm => 0.875,
        .default, .icon, .heading, .display => 1,
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
