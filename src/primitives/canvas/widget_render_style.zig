const std = @import("std");
const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");

const Color = drawing_model.Color;
const Fill = drawing_model.Fill;
const Radius = drawing_model.Radius;
const StrokeRect = drawing_model.StrokeRect;
const DesignTokens = token_model.DesignTokens;
const ControlVisualTokens = token_model.ControlVisualTokens;
const Widget = widget_model.Widget;
const WidgetState = widget_model.WidgetState;

/// Snap a hairline border to the device-pixel grid at emit time. A
/// stroke centered on its rect straddles the boundary by half its
/// width, so a 1-device-pixel border rasterizes as two half-covered
/// columns — geometrically faithful but visually soft. Eligibility is
/// judged on the ROUNDED device width: strokes rounding to one or two
/// device pixels snap, wider borders keep true geometry, and a width
/// that rounds to zero stays unsnapped rather than darkening a
/// sub-half-pixel stroke to a full column. An eligible stroke takes the
/// FLOOR of its exact device width, never below one pixel, so a
/// fractional width lands on the lighter whole-pixel neighbor — a 1px
/// logical border at a 1.5x scale covers one device column, not two.
/// A hairline is a boundary, not content: when the grid forces a
/// choice, crisp-and-light reads better than crisp-and-heavy. The snap
/// moves each frame edge to the grid and pulls the centerline INWARD
/// by half the snapped width, so the band covers exactly that many
/// whole device columns and rows with its outer silhouette on the
/// widget frame (never bleeding past layout bounds). Corner radii
/// shrink by the same inset so the outer arc keeps the frame's radius,
/// and the arcs stay smooth: the snapped geometry is still one rounded
/// rect, rasterized by one continuous coverage field. Inactive without
/// the pixel-snap geometry token or a usable scale, so fractional
/// device scales snap in DEVICE space and unsnapped surfaces render
/// untouched.
pub fn snapHairlineStrokeRect(tokens: DesignTokens, value: StrokeRect) StrokeRect {
    if (!tokens.pixel_snap.geometry) return value;
    const scale = tokens.pixel_snap.scale;
    if (!std.math.isFinite(scale) or scale <= 0) return value;
    const exact_device_width = nonNegative(value.stroke.width) * scale;
    const rounded_device_width = @round(exact_device_width);
    if (rounded_device_width < 1 or rounded_device_width > 2) return value;
    const device_width = @max(1, @floor(exact_device_width));
    const rect = value.rect.normalized();
    if (rect.isEmpty()) return value;
    const half_device = device_width * 0.5;
    const x0 = (@round(rect.x * scale) + half_device) / scale;
    const y0 = (@round(rect.y * scale) + half_device) / scale;
    const x1 = (@round(rect.maxX() * scale) - half_device) / scale;
    const y1 = (@round(rect.maxY() * scale) - half_device) / scale;
    if (x1 <= x0 or y1 <= y0) return value;
    const inset = half_device / scale;
    var snapped = value;
    snapped.rect = geometry.RectF.init(x0, y0, x1 - x0, y1 - y0);
    snapped.radius = .{
        .top_left = @max(0, value.radius.top_left - inset),
        .top_right = @max(0, value.radius.top_right - inset),
        .bottom_right = @max(0, value.radius.bottom_right - inset),
        .bottom_left = @max(0, value.radius.bottom_left - inset),
    };
    snapped.stroke.width = device_width / scale;
    return snapped;
}

/// The frame the focus ring strokes: the control rect pushed out by the
/// ring-offset token (`stroke.focus_offset`) — the control keeps its
/// own border and the ring floats that gap outside it, so focus never
/// restyles the control.
pub fn focusRingRect(rect: geometry.RectF, tokens: DesignTokens) geometry.RectF {
    return rect.normalized().inflate(geometry.InsetsF.all(nonNegative(tokens.stroke.focus_offset)));
}

/// The ring's corner radius: the control's own radius grown by the
/// offset so the ring stays concentric with the border it wraps.
pub fn focusRingRadius(radius: Radius, tokens: DesignTokens) Radius {
    const offset = nonNegative(tokens.stroke.focus_offset);
    return .{
        .top_left = radius.top_left + offset,
        .top_right = radius.top_right + offset,
        .bottom_right = radius.bottom_right + offset,
        .bottom_left = radius.bottom_left + offset,
    };
}

/// The caret and composition-underline ink of an editable field: the
/// field's own text color. The caret is the primary "you are typing
/// HERE" signal, so it must read at the same contrast as the glyphs
/// beside it — the soft focus-ring gray that used to fill this role
/// hints at focus but disappears as an insertion point.
pub fn textEditingInkColor(widget: Widget, tokens: DesignTokens) Color {
    const visual = textInputControlVisualTokens(widget, tokens);
    return widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
}

/// The selection highlight of an editable field: the solid accent. The
/// emitters repaint the selected glyphs in `textSelectionTextColor`
/// (the inverted-selection treatment), so the fill takes the full
/// accent block instead of a see-through wash — unmissable in both
/// schemes, including the monochrome register where the accent is
/// near-black on light surfaces.
pub fn textSelectionFillColor(widget: Widget, tokens: DesignTokens) Color {
    return widget.style.accent orelse tokens.colors.accent;
}

/// The glyph ink inside an editable field's selection: the accent's own
/// foreground, so the selected run inverts against the solid fill the
/// way filled-primary controls pair accent with accent_text.
pub fn textSelectionTextColor(widget: Widget, tokens: DesignTokens) Color {
    return widget.style.accent_foreground orelse tokens.colors.accent_text;
}

/// The selection wash of static (read-only) text: the accent at a
/// strength that reads as selection at a glance while the glyphs above
/// it stay in their own ink. Static paragraphs keep per-span colors
/// (links, emphasis, code), so the highlight sits under them as a
/// translucent band instead of inverting them like editable fields do.
pub fn staticTextSelectionFillColor(widget: Widget, tokens: DesignTokens) Color {
    return colorWithAlpha(widget.style.accent orelse tokens.colors.accent, tokens.states.selection_wash_alpha);
}

/// The hover half of a widget's wash state: hovered, unless the widget
/// opted out of hover washes (`WidgetStyle.quiet_hover`, the
/// quiet-surface knob for image-forward content tiles). Every
/// background-fill resolver that steps on hover reads it through this,
/// so a quiet surface silences ONLY the hover fill: pressed and
/// selected fills keep their own ladder rungs, and the focus ring,
/// cursor intent, and hit testing never resolve through here at all.
pub fn washHovered(widget: Widget) bool {
    return widget.state.hovered and !widget.style.quiet_hover;
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

/// Button corners: 10 (the lg radius token) at the default and lg
/// rungs, 8 (the md token) at sm — one deliberate step down for the
/// compact rung so its corner arc stays proportional to the 28px box,
/// never the full size-stepped scale of `controlRadius` (a lg button
/// with a 12px corner starts reading as a card).
pub fn buttonControlRadius(widget: Widget, visual: ControlVisualTokens, tokens: DesignTokens) Radius {
    if (widget.style.radius) |radius| return Radius.all(nonNegative(radius));
    const fallback = switch (widget.size) {
        .sm => tokens.radius.md,
        .default, .icon, .heading, .display, .lg => tokens.radius.lg,
    };
    return Radius.all(nonNegative(visual.radius orelse fallback));
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
    return colorFill(buttonFillColor(widget, tokens));
}

pub fn buttonFillColor(widget: Widget, tokens: DesignTokens) Color {
    // Disabled keeps the variant's identity at the disabled-wash
    // strength (`states.disabled_alpha`) — the same wash the selection
    // controls wear — instead of collapsing every variant to one gray
    // block (which used to hand a disabled GHOST a filled box it never
    // had). A quiet variant's transparent body stays transparent; the
    // label and border carry the muted read. Themes whose disabled
    // treatment is a color SWAP state it per control table
    // (`disabled_background`), which wins over the wash.
    if (widget.state.disabled) {
        const visual = buttonControlVisualTokens(widget, tokens);
        if (visual.disabled_background) |color| return color;
        return disabledWash(buttonFillColor(restStateWidget(widget), tokens), true, tokens.states.disabled_alpha);
    }
    const pressed = widget.state.pressed;
    const selected = widget.state.selected;
    const hovered = washHovered(widget);
    // On the quiet variants `selected` means two different things by
    // kind: a toggle's on-state earns the muted wash, while a nav
    // button's currency (the current page, the open trigger) shows
    // through its variant chrome alone — a permanently washed page
    // number would read as stuck hover.
    const toggle_kind = widget.kind == .toggle_button or widget.kind == .toggle;
    const selected_toggle = selected and toggle_kind;
    const visual = buttonControlVisualTokens(widget, tokens);
    // The detached group chip's own ladder, ahead of the variant switch:
    // every member rests on the group table's wash, the selected (or
    // pressed) chip takes the ink-inverted active fill, and hover moves
    // only if the theme states a hover channel — selection is the one
    // signal the strip speaks.
    if (buttonInDetachedGroup(widget, tokens)) {
        if (pressed) return widgetAccentColor(widget, visual.pressed_background orelse visual.active_background orelse tokens.colors.surface_pressed);
        if (selected) return widgetAccentColor(widget, visual.active_background orelse tokens.colors.surface_pressed);
        if (hovered) return widgetBackgroundColor(widget, visual.hover_background orelse visual.background orelse tokens.colors.surface_subtle);
        return widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface_subtle);
    }
    return switch (widget.variant) {
        .default => if (pressed or selected)
            widgetAccentColor(widget, visual.active_background orelse tokens.colors.accent)
        else if (hovered)
            widgetBackgroundColor(widget, visual.hover_background orelse tokens.colors.surface_subtle)
        else
            widgetBackgroundColor(widget, visual.background orelse tokens.colors.surface),
        // The filled variant speaks one wash channel: rest at full
        // strength, hover and pressed at the token-stated alpha cuts
        // (`states.hover_fill_alpha`/`pressed_fill_alpha`, 90%/80% by
        // default) — the wash lightens on light surfaces and deepens on
        // dark ones without a second color per scheme. A persistent
        // `selected` keeps the rest fill: an on-state is identity, not
        // feedback.
        .primary => widgetAccentColor(widget, filledStateBackground(visual, tokens, tokens.colors.accent, pressed, selected, hovered)),
        // Destructive is the QUIET red chip, not a filled alarm block:
        // a translucent destructive wash under destructive-red text.
        // The per-scheme wash strengths live in the themed control
        // tables (`ControlTokens.theme`); the fallback ladder here IS
        // the light recipe, so a bare untheme'd `DesignTokens{}` (whose
        // color defaults are the light palette) renders identically.
        .destructive => widgetAccentColor(widget, destructiveChipBackground(visual, tokens, pressed, selected, hovered)),
        .secondary => widgetBackgroundColor(widget, buttonStateBackground(visual, pressed or selected, hovered, if (pressed or selected) tokens.colors.surface_pressed else hoverWash(tokens.colors.surface_subtle, false, hovered, tokens.states.secondary_hover_alpha))),
        // The quiet variants step through the neutral washes: hover and
        // a toggle's on-state sit on the muted wash, a press deepens one
        // step further so the moment of commitment is visible under the
        // pointer, and rest is bare.
        .outline, .ghost => widgetBackgroundColor(widget, quietStateBackground(visual, tokens, pressed, selected_toggle, hovered)),
    };
}

/// The filled variants' state ladder over one base color, honoring any
/// themed control tokens first: pressed prefers `pressed_background`
/// then `active_background`, hover prefers `hover_background`, both
/// fall back to the base at the token-stated alpha cuts
/// (`states.hover_fill_alpha`/`pressed_fill_alpha`). Selected-at-rest
/// keeps the full-strength fill.
fn filledStateBackground(visual: ControlVisualTokens, tokens: DesignTokens, base: Color, pressed: bool, selected: bool, hovered: bool) Color {
    if (pressed) return visual.pressed_background orelse visual.active_background orelse visual.hover_background orelse visual.background orelse colorWithAlpha(base, tokens.states.pressed_fill_alpha * base.a);
    if (selected) return visual.active_background orelse visual.hover_background orelse visual.background orelse base;
    if (hovered) return visual.hover_background orelse visual.background orelse colorWithAlpha(base, tokens.states.hover_fill_alpha * base.a);
    return visual.background orelse base;
}

/// The destructive chip's state ladder over the translucent red wash,
/// honoring themed control tokens first. The fallbacks are the
/// token-stated wash strengths (`states.destructive_wash_*`; the
/// defaults are the light recipe — rest 10%, hover 15%, pressed one
/// step past hover at 20%. Feedback DEEPENS the wash, opposite of the
/// filled variant's alpha cuts, because a translucent chip signals
/// under the pointer by gaining ink). A persistent `selected` keeps the
/// rest wash: identity, not feedback.
fn destructiveChipBackground(visual: ControlVisualTokens, tokens: DesignTokens, pressed: bool, selected: bool, hovered: bool) Color {
    if (pressed) return visual.pressed_background orelse visual.active_background orelse visual.hover_background orelse colorWithAlpha(tokens.colors.destructive, tokens.states.destructive_wash_pressed_alpha);
    if (selected) return visual.background orelse colorWithAlpha(tokens.colors.destructive, tokens.states.destructive_wash_alpha);
    if (hovered) return visual.hover_background orelse colorWithAlpha(tokens.colors.destructive, tokens.states.destructive_wash_hover_alpha);
    return visual.background orelse colorWithAlpha(tokens.colors.destructive, tokens.states.destructive_wash_alpha);
}

/// The quiet (outline/ghost) state ladder: transparent at rest, the
/// muted wash on hover and on a toggle's on-state, the pressed wash —
/// one neutral step deeper — while the pointer is down.
fn quietStateBackground(visual: ControlVisualTokens, tokens: DesignTokens, pressed: bool, selected_toggle: bool, hovered: bool) Color {
    if (pressed) return visual.pressed_background orelse visual.active_background orelse visual.hover_background orelse tokens.colors.surface_pressed;
    if (selected_toggle) return visual.active_background orelse visual.hover_background orelse tokens.colors.surface_subtle;
    if (hovered) return visual.hover_background orelse tokens.colors.surface_subtle;
    return visual.background orelse transparentColor();
}

/// The same widget with interaction FEEDBACK cleared: the appearance
/// the disabled wash mutes. `selected` survives — it is identity, not
/// feedback — so a disabled toggle that is ON still reads as on (the
/// same rule the selection controls' disabled register follows).
fn restStateWidget(widget: Widget) Widget {
    var rest = widget;
    rest.state.disabled = false;
    rest.state.pressed = false;
    rest.state.hovered = false;
    rest.state.focused = false;
    return rest;
}

/// The hover state of a filled control: the base color at reduced
/// alpha while hovered (and not pressed), the base color otherwise.
fn hoverWash(base: Color, active: bool, hovered: bool, alpha: f32) Color {
    if (hovered and !active) return colorWithAlpha(base, alpha * base.a);
    return base;
}

/// The disabled state of a selection control's chrome (checkbox box,
/// radio dot, switch track): the same color at the disabled-wash alpha
/// (`states.disabled_alpha`, half strength by default) — the house
/// disabled register keeps the control's shape and checked hue muted
/// instead of swapping to a different color, so a checked-but-disabled
/// control still reads as checked.
pub fn disabledWash(color: Color, disabled: bool, alpha: f32) Color {
    if (!disabled) return color;
    return colorWithAlpha(color, alpha * color.a);
}

pub fn buttonTextColorForWidget(widget: Widget, tokens: DesignTokens) Color {
    // Disabled ink is the variant's own ink at the disabled-wash
    // strength, matching the washed fill — the whole control fades as
    // one piece (primary keeps knockout text on its washed fill; the
    // quiet variants keep their body ink) instead of swapping to the
    // shared muted gray, which read as a live-but-secondary label.
    // Themes with a stated disabled ink (`disabled_foreground`) take it
    // instead.
    if (widget.state.disabled) {
        const visual = buttonControlVisualTokens(widget, tokens);
        if (visual.disabled_foreground) |color| return color;
        return disabledWash(buttonTextColorForWidget(restStateWidget(widget), tokens), true, tokens.states.disabled_alpha);
    }
    const active = widget.state.pressed or widget.state.selected;
    const visual = buttonControlVisualTokens(widget, tokens);
    // The detached group chip's ink pair: knockout on the ink-inverted
    // active fill, the stated rest ink (falling back to the body ink)
    // everywhere else.
    if (buttonInDetachedGroup(widget, tokens)) {
        if (active) return widgetAccentForegroundColor(widget, tokens, visual.active_foreground orelse tokens.colors.accent_text);
        return widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text);
    }
    return switch (widget.variant) {
        .default => if (active)
            widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text)
        else
            widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        .primary => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text),
        .secondary, .outline, .ghost => widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
        // Ink IN the destructive red on the quiet wash — the chip's
        // whole identity — never knockout text (that is the filled
        // block's pairing, and the chip has no filled block).
        .destructive => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.destructive),
    };
}

pub fn buttonBorderFill(widget: Widget, tokens: DesignTokens) Fill {
    // The disabled edge is the variant's own edge at half strength, so
    // it fades in lockstep with the half-strength fill and ink — a
    // full-strength edge around a washed body would read as a live
    // control wearing a ring. Ghost keeps its no-border shape.
    const border = widget.style.border orelse blk: {
        const visual = buttonControlVisualTokens(widget, tokens);
        // The detached group chip is a borderless shape (its edge is
        // where the wash ends), unless the theme states an edge.
        if (buttonInDetachedGroup(widget, tokens)) {
            break :blk widgetBorderColor(widget, visual.border orelse transparentColor());
        }
        break :blk switch (widget.variant) {
            .primary => widgetAccentColor(widget, visual.border orelse tokens.colors.accent),
            // The destructive chip and ghost are borderless shapes: the
            // chip's edge is where its wash ends, nothing more.
            .destructive => widgetAccentColor(widget, visual.border orelse transparentColor()),
            .ghost => widgetBorderColor(widget, visual.border orelse transparentColor()),
            else => widgetBorderColor(widget, visual.border orelse tokens.colors.border),
        };
    };
    return colorFill(disabledWash(border, widget.state.disabled, tokens.states.disabled_alpha));
}

/// Whether this widget is a button-group member rendering in the
/// `.detached` chip register: the group walks stamp `group_segment`
/// onto every member on the way down, and the register switch decides
/// what the stamp means — `.segmented` collapses corners and seams,
/// `.detached` swaps the member's whole visual class to the
/// `button_group` control table (fills, inks, borderless chrome) while
/// keeping full corners. Never true under the house register's default
/// tokens, so no-pack rendering cannot take this path.
pub fn buttonInDetachedGroup(widget: Widget, tokens: DesignTokens) bool {
    return widget.group_segment != .none and tokens.controls.button_group_style == .detached;
}

pub fn buttonControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    // A detached-register group member wears the group's own control
    // table — the chip treatment replaces variant chrome, so the strip
    // reads as ONE exclusive-choice affordance rather than a row of
    // mismatched buttons.
    if (buttonInDetachedGroup(widget, tokens)) return tokens.controls.button_group;
    const variant = switch (widget.variant) {
        .default => tokens.controls.button_default,
        .primary => tokens.controls.button_primary,
        .secondary => tokens.controls.button_secondary,
        .outline => tokens.controls.button_outline,
        .ghost => tokens.controls.button_ghost,
        .destructive => tokens.controls.button_destructive,
    };
    if (widget.kind == .toggle_button or widget.kind == .toggle) return controlVisualTokensWithFallback(tokens.controls.toggle_button, variant);
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
        .pressed_background = primary.pressed_background orelse fallback.pressed_background,
        .disabled_background = primary.disabled_background orelse fallback.disabled_background,
        .disabled_foreground = primary.disabled_foreground orelse fallback.disabled_foreground,
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

/// `buttonStateBackground` with the transient pointer-down channel in
/// front: a theme that states `pressed_background` gets it the moment
/// the pointer is down, everything else falls through to the merged
/// active/hover/background ladder unchanged.
pub fn controlStateBackground(visual: ControlVisualTokens, pressed: bool, active: bool, hovered: bool, fallback: Color) Color {
    if (pressed) {
        if (visual.pressed_background) |color| return color;
    }
    return buttonStateBackground(visual, active, hovered, fallback);
}

pub fn textInputControlVisualTokens(widget: Widget, tokens: DesignTokens) ControlVisualTokens {
    return switch (widget.kind) {
        .input => controlVisualTokensWithFallback(tokens.controls.input, tokens.controls.text_field),
        .search_field => tokens.controls.search_field,
        .combobox => controlVisualTokensWithFallback(tokens.controls.combobox, tokens.controls.search_field),
        // The grouped input wears the textarea's visual class: the group
        // IS the field (its entry's own chrome dissolves), so both draw
        // from one control register.
        .textarea, .input_group => tokens.controls.textarea,
        else => tokens.controls.text_field,
    };
}

pub fn textInputFill(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) Fill {
    if (widget.state.disabled) return colorFill(visual.disabled_background orelse tokens.colors.disabled);
    return colorFill(widgetBackgroundColor(widget, buttonStateBackground(visual, false, washHovered(widget), tokens.colors.surface)));
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
        .switch_control => tokens.controls.switch_control,
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
    if (widget.state.disabled) return visual.disabled_background orelse tokens.colors.disabled;
    const hovered = washHovered(widget);
    return switch (widget.variant) {
        .default, .primary => widgetAccentColor(widget, controlStateBackground(visual, widget.state.pressed, widget.state.pressed or widget.state.selected, hovered, tokens.colors.accent)),
        .secondary => widgetBackgroundColor(widget, controlStateBackground(visual, widget.state.pressed, widget.state.pressed or widget.state.selected, hovered, tokens.colors.surface_subtle)),
        .outline, .ghost => widgetBackgroundColor(widget, controlStateBackground(visual, widget.state.pressed, widget.state.pressed or widget.state.selected, hovered, if (hovered or widget.state.pressed) tokens.colors.surface_subtle else transparentColor())),
        // The QUIET destructive chip: a translucent destructive wash
        // (`states.badge_destructive_wash_alpha`) under destructive
        // text (the composite tracks the scheme — pale pink on light
        // pages, a dark red tint on dark ones) instead of a filled
        // alarm block.
        .destructive => widgetAccentColor(widget, controlStateBackground(visual, widget.state.pressed, widget.state.pressed or widget.state.selected, hovered, colorWithAlpha(tokens.colors.destructive, tokens.states.badge_destructive_wash_alpha))),
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
    if (widget.state.disabled) return visual.disabled_foreground orelse tokens.colors.text_muted;
    return switch (widget.variant) {
        .default, .primary => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.accent_text),
        // Ink on the quiet wash, not knockout text on a filled block.
        .destructive => widgetAccentForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.destructive),
        else => widgetForegroundColor(widget, tokens, visual.foreground orelse tokens.colors.text),
    };
}

pub fn badgeStrokeWidth(widget: Widget, tokens: DesignTokens, visual: ControlVisualTokens) f32 {
    if (widget.style.stroke_width) |width| return nonNegative(width);
    if (visual.stroke_width) |width| return nonNegative(width);
    // Only the outline variant wears a border; the filled and quiet
    // chips are borderless (the reference badge's transparent border).
    return switch (widget.variant) {
        .outline => tokens.stroke.hairline,
        else => 0,
    };
}

pub fn buttonStrokeWidth(widget: Widget, tokens: DesignTokens) f32 {
    if (widget.style.stroke_width) |width| return nonNegative(width);
    const visual = buttonControlVisualTokens(widget, tokens);
    if (visual.stroke_width) |width| return nonNegative(width);
    // The detached group chip defaults borderless like the other
    // wash-edged shapes below.
    if (buttonInDetachedGroup(widget, tokens)) return 0;
    return switch (widget.variant) {
        // Ghost has no box; the destructive chip's edge is its wash.
        .ghost, .destructive => 0,
        else => tokens.stroke.regular,
    };
}

pub fn listItemFillColor(widget: Widget, tokens: DesignTokens, state: WidgetState) Color {
    const visual = listItemControlVisualTokens(widget, tokens);
    // The quiet-surface knob reads through the widget, not the caller's
    // state copy, so every row/cell path honors it identically.
    const hovered = state.hovered and !widget.style.quiet_hover;
    const fallback = if (state.selected or state.pressed)
        tokens.colors.surface_pressed
    else if (hovered)
        tokens.colors.surface_subtle
    else
        transparentColor();
    return controlStateBackground(visual, state.pressed, state.selected or state.pressed, hovered, fallback);
}

pub fn transparentColor() Color {
    return Color.rgba(0, 0, 0, 0);
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
