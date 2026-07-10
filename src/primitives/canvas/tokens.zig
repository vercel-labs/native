const std = @import("std");
const canvas = @import("root.zig");
const text_metrics = @import("text_metrics.zig");
const geist_theme = @import("themes/geist.zig");

const ObjectId = canvas.ObjectId;
const FontId = canvas.FontId;
const Color = canvas.Color;
const Affine = canvas.Affine;
const CanvasRenderAnimation = canvas.CanvasRenderAnimation;
const default_sans_font_id = canvas.default_sans_font_id;
const default_mono_font_id = canvas.default_mono_font_id;
const default_sans_medium_font_id = canvas.default_sans_medium_font_id;
const default_sans_font_family = FontFamily.geist;
const default_mono_font_family = FontFamily.geist_mono;

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}

fn floorVirtualIndex(value: f32) usize {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@floor(value));
}

fn ceilVirtualIndex(value: f32) usize {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@ceil(value));
}

pub const Density = enum {
    compact,
    regular,
    spacious,
};

/// Minimum pointer hit-target extent in points at regular density and
/// default widget size. 18 is the smallest interactive register the house
/// controls ship (the checkbox/radio box), sitting inside the desktop
/// pointer convention band (macOS guidance asks for ~24pt around small
/// controls but AppKit's own small checkboxes are 14-18pt with row-level
/// slop; touch platforms want 44pt and get it from the 36pt control
/// height plus spacing). Consumers scale it through the same size/density
/// channel every control metric uses (`widgetSizedDensityValue`), so an
/// intentionally `sm` control at compact density keeps its floor while a
/// control squeezed below its own register is flagged. The layout audit's
/// `hit_target` rule is the enforcement point.
pub const min_pointer_hit_target: f32 = 18;

pub const Easing = enum {
    linear,
    standard,
    emphasized,
    spring,
};

pub const ColorScheme = enum {
    light,
    dark,
};

pub const ColorContrast = enum {
    standard,
    high,
};

/// Built-in theme packs: complete token registers selectable by name.
/// A pack is a whole design system — palette, control tables, metrics,
/// type scale — resolved per scheme/contrast exactly like the house
/// register, so packs flip light/dark (and honor high contrast) live.
/// Pack selection is manifest/API vocabulary (`app.zon`'s `theme`
/// field, `ThemeOptions.pack`), never markup vocabulary: a document
/// describes structure, the app owns its look.
pub const ThemePack = enum {
    /// The default register: the monochrome house neutral scale defined
    /// by the token defaults in this file.
    house,
    /// The Geist pack: the design register of the bundled Geist
    /// typeface family — a cool neutral scale, monochrome primaries,
    /// blue focus rings and identity hues, 6px control corners, and a
    /// taller 32/40/48 control ladder.
    geist,

    /// Resolve a manifest-facing pack name ("house", "geist"). Null for
    /// unknown names so callers can raise their own teaching error with
    /// the offending string and the valid list.
    pub fn fromName(name: []const u8) ?ThemePack {
        inline for (@typeInfo(ThemePack).@"enum".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) return @field(ThemePack, field.name);
        }
        return null;
    }
};

pub const ThemeOptions = struct {
    color_scheme: ColorScheme = .light,
    contrast: ColorContrast = .standard,
    density: Density = .regular,
    reduce_motion: bool = false,
    /// Which built-in pack resolves the register. The default keeps the
    /// house theme; packs compose with every other option (scheme,
    /// contrast, density, motion), so switching packs is exactly as
    /// live as the light/dark flip.
    pack: ThemePack = .house,
};

/// The default palette is the house neutral register, converted from
/// its published oklch values to sRGB hex (D65, standard oklch ->
/// linear sRGB -> gamma-encoded; conversions are exact to the nearest
/// 8-bit channel). Neutral gray scale for surfaces and text, a
/// MONOCHROME primary — near-black filled controls on light,
/// porcelain-white filled controls on dark — translucent-white
/// hairlines in dark mode, and card/popover surfaces one step lighter
/// than the dark background. Color is spent only where it means
/// something (destructive/success/warning/info and per-app accent
/// overrides); at rest the register reads black-and-white, which is
/// what makes it read premium. Rationale per token is on the field.
pub const ColorTokens = struct {
    /// oklch(1 0 0) = #ffffff — the page background.
    background: Color = Color.rgb8(255, 255, 255),
    /// Card/popover surface; oklch(1 0 0) = #ffffff (same as the
    /// background in light — elevation comes from the border + shadow).
    surface: Color = Color.rgb8(255, 255, 255),
    /// Muted/accent surface; oklch(0.97 0 0) = #f5f5f5 — hover washes,
    /// skeletons, secondary chrome.
    surface_subtle: Color = Color.rgb8(245, 245, 245),
    /// Pressed/selected wash and the "input" surface (switch tracks);
    /// oklch(0.922 0 0) = #e5e5e5 — the same step the border sits on.
    surface_pressed: Color = Color.rgb8(229, 229, 229),
    /// Foreground; oklch(0.145 0 0) = #0a0a0a.
    text: Color = Color.rgb8(10, 10, 10),
    /// Muted foreground; oklch(0.556 0 0) = #737373.
    text_muted: Color = Color.rgb8(115, 115, 115),
    /// Border/input hairline; oklch(0.922 0 0) = #e5e5e5.
    border: Color = Color.rgb8(229, 229, 229),
    /// Primary; oklch(0.205 0 0) = #171717 — the monochrome near-black
    /// that identifies checked, active, and filled-primary states. Apps
    /// that want a hue override this; the base register stays neutral.
    accent: Color = Color.rgb8(23, 23, 23),
    /// Primary foreground; oklch(0.985 0 0) = #fafafa.
    accent_text: Color = Color.rgb8(250, 250, 250),
    /// Destructive; oklch(0.577 0.245 27.325) = #e7000b.
    destructive: Color = Color.rgb8(231, 0, 11),
    destructive_text: Color = Color.rgb8(250, 250, 250),
    success: Color = Color.rgb8(22, 163, 74),
    success_text: Color = Color.rgb8(250, 250, 250),
    warning: Color = Color.rgb8(217, 119, 6),
    warning_text: Color = Color.rgb8(250, 250, 250),
    /// The fourth semantic hue: violet, for identity states that are not
    /// ok/warn/fail — a merged PR badge, a "new" chip, an informational
    /// callout. Named `info` because that is the slot every component
    /// vocabulary ships (Bootstrap/MUI/Ant all have one; GitHub's Primer
    /// calls the same role `done`); colored violet rather than blue
    /// because the violet identity hue is the one GitHub-shaped apps
    /// actually need, and nothing else in the palette competes with it.
    info: Color = Color.rgb8(124, 58, 237),
    info_text: Color = Color.rgb8(250, 250, 250),
    /// Ring; oklch(0.708 0 0) = #a1a1a1 — a mid gray so the focus ring
    /// reads as an outline, not a second border color.
    focus_ring: Color = Color.rgb8(161, 161, 161),
    shadow: Color = Color.rgba8(0, 0, 0, 26),
    /// Modal scrim: the wash drawn across the whole surface behind
    /// dialogs, drawers, and sheets. Black at 10% — deliberately light,
    /// because the backdrop blur (`BlurTokens.scrim`) carries the
    /// modality signal; the dim only settles the blurred content. Same
    /// value in both schemes. Alpha 0 disables the wash.
    scrim: Color = Color.rgba8(0, 0, 0, 26),
    /// Disabled wash; the muted surface step, oklch(0.97 0 0) = #f5f5f5.
    disabled: Color = Color.rgb8(245, 245, 245),

    pub fn theme(color_scheme: ColorScheme, contrast: ColorContrast) ColorTokens {
        return switch (color_scheme) {
            .light => switch (contrast) {
                .standard => light(),
                .high => highContrastLight(),
            },
            .dark => switch (contrast) {
                .standard => dark(),
                .high => highContrastDark(),
            },
        };
    }

    pub fn light() ColorTokens {
        return .{};
    }

    pub fn dark() ColorTokens {
        return .{
            // oklch(0.145 0 0) = #0a0a0a.
            .background = Color.rgb8(10, 10, 10),
            // Card/popover one step LIGHTER than the background:
            // oklch(0.205 0 0) = #171717 — elevation by lightness.
            .surface = Color.rgb8(23, 23, 23),
            // Muted/accent surface; oklch(0.269 0 0) = #262626.
            .surface_subtle = Color.rgb8(38, 38, 38),
            // "Input" surface and pressed wash: white at 15% alpha, so
            // pressed states and switch tracks tint whatever they sit on
            // (the dark-mode input treatment).
            .surface_pressed = Color.rgba8(255, 255, 255, 38),
            // oklch(0.985 0 0) = #fafafa.
            .text = Color.rgb8(250, 250, 250),
            // Muted foreground; oklch(0.708 0 0) = #a1a1a1.
            .text_muted = Color.rgb8(161, 161, 161),
            // Dark borders are translucent white (10%), not a gray fill:
            // hairlines brighten what they overlap instead of muddying it.
            .border = Color.rgba8(255, 255, 255, 26),
            // Primary; oklch(0.922 0 0) = #e5e5e5 — the monochrome
            // register flips in dark: porcelain filled controls with
            // near-black text on them.
            .accent = Color.rgb8(229, 229, 229),
            // Primary foreground; oklch(0.205 0 0) = #171717.
            .accent_text = Color.rgb8(23, 23, 23),
            // Destructive; oklch(0.704 0.191 22.216) = #ff6467.
            .destructive = Color.rgb8(255, 100, 103),
            .destructive_text = Color.rgb8(250, 250, 250),
            .success = Color.rgb8(34, 197, 94),
            .success_text = Color.rgb8(9, 9, 11),
            .warning = Color.rgb8(245, 158, 11),
            .warning_text = Color.rgb8(9, 9, 11),
            .info = Color.rgb8(167, 139, 250),
            .info_text = Color.rgb8(9, 9, 11),
            // Ring; oklch(0.556 0 0) = #737373.
            .focus_ring = Color.rgb8(115, 115, 115),
            .shadow = Color.rgba8(0, 0, 0, 150),
            // Same 10% wash as light: the scrim's job in dark is to
            // settle the blurred backdrop, not to blacken it.
            .scrim = Color.rgba8(0, 0, 0, 26),
            // Disabled wash; the muted step, oklch(0.269 0 0) = #262626.
            .disabled = Color.rgb8(38, 38, 38),
        };
    }

    pub fn highContrastLight() ColorTokens {
        return .{
            .background = Color.rgb8(255, 255, 255),
            .surface = Color.rgb8(255, 255, 255),
            // The standard theme's neutral steps, kept on the same scale.
            .surface_subtle = Color.rgb8(245, 245, 245),
            .surface_pressed = Color.rgb8(229, 229, 229),
            .text = Color.rgb8(0, 0, 0),
            .text_muted = Color.rgb8(64, 64, 64),
            .border = Color.rgba8(0, 0, 0, 180),
            // The monochrome primary at its contrast extreme: pure
            // black filled controls, 21:1 against the white accent
            // text.
            .accent = Color.rgb8(0, 0, 0),
            .accent_text = Color.rgb8(255, 255, 255),
            .destructive = Color.rgb8(127, 29, 29),
            .destructive_text = Color.rgb8(255, 255, 255),
            .success = Color.rgb8(20, 83, 45),
            .success_text = Color.rgb8(255, 255, 255),
            .warning = Color.rgb8(120, 53, 15),
            .warning_text = Color.rgb8(255, 255, 255),
            .info = Color.rgb8(76, 29, 149),
            .info_text = Color.rgb8(255, 255, 255),
            // High-contrast rings should shout: pure black on the
            // white surface, the same monochrome extreme the accent
            // sits on.
            .focus_ring = Color.rgb8(0, 0, 0),
            .shadow = Color.rgba8(0, 0, 0, 96),
            // High contrast trades the translucent glass treatment for
            // a decisive dim: 63% black keeps the modal unmistakably
            // separated even where blur is unavailable or unwanted.
            .scrim = Color.rgba8(0, 0, 0, 160),
            .disabled = Color.rgb8(163, 163, 163),
        };
    }

    pub fn highContrastDark() ColorTokens {
        return .{
            .background = Color.rgb8(0, 0, 0),
            .surface = Color.rgb8(10, 10, 10),
            .surface_subtle = Color.rgb8(23, 23, 23),
            .surface_pressed = Color.rgb8(38, 38, 38),
            .text = Color.rgb8(255, 255, 255),
            .text_muted = Color.rgb8(229, 229, 229),
            .border = Color.rgba8(255, 255, 255, 190),
            // The monochrome primary at its contrast extreme: pure
            // white filled controls, 21:1 against the black accent
            // text.
            .accent = Color.rgb8(255, 255, 255),
            .accent_text = Color.rgb8(0, 0, 0),
            .destructive = Color.rgb8(248, 113, 113),
            .destructive_text = Color.rgb8(0, 0, 0),
            .success = Color.rgb8(134, 239, 172),
            .success_text = Color.rgb8(0, 0, 0),
            .warning = Color.rgb8(252, 211, 77),
            .warning_text = Color.rgb8(0, 0, 0),
            .info = Color.rgb8(196, 181, 253),
            .info_text = Color.rgb8(0, 0, 0),
            // Pure white ring: the same monochrome extreme the accent
            // sits on.
            .focus_ring = Color.rgb8(255, 255, 255),
            .shadow = Color.rgba8(0, 0, 0, 180),
            // The decisive high-contrast dim (see highContrastLight):
            // heavier still, because black over near-black content
            // needs more alpha to read as a separation.
            .scrim = Color.rgba8(0, 0, 0, 200),
            .disabled = Color.rgb8(82, 82, 82),
        };
    }
};

pub const FontFamily = enum {
    geist,
    geist_mono,
    system_sans,
    system_mono,

    pub fn cssName(self: FontFamily) []const u8 {
        return switch (self) {
            .geist => "Geist",
            .geist_mono => "Geist Mono",
            .system_sans => "system-ui",
            .system_mono => "ui-monospace",
        };
    }
};

pub const TypographyTokens = struct {
    font_id: FontId = default_sans_font_id,
    mono_font_id: FontId = default_mono_font_id,
    font_family: FontFamily = default_sans_font_family,
    mono_font_family: FontFamily = default_mono_font_family,
    body_size: f32 = 14,
    label_size: f32 = 13,
    title_size: f32 = 20,
    button_size: f32 = 14,
    /// The face button labels draw with. Null (the default) resolves to
    /// the medium companion of the house sans — a button label carries
    /// slightly more ink than body text so the control reads as a
    /// command, not a caption. Themes that swap `font_id` for a custom
    /// face keep their face on buttons automatically (a stranger face
    /// has no known medium companion to reach for); set this explicitly
    /// to pick a registered weight.
    button_font_id: ?FontId = null,
    /// Section-heading rung above `title_size`: 28 continues the house
    /// step ratio (body 14 → title 20 ≈ x1.4; title 20 → heading 28 =
    /// x1.4) and doubles `body_size`, so a heading's 1.25 line height
    /// (35) still composes with body lines on the same 4pt-friendly
    /// rhythm.
    heading_size: f32 = 28,
    /// Display rung: hero stats, timer numerals, pricing figures. The
    /// jump from heading widens deliberately (28 → 48 ≈ x1.7) — display
    /// text is a focal numeral, not a bigger heading — and 48 keeps the
    /// even-number rhythm with a 1.25 line height of exactly 60, a
    /// whole-pixel line box at 1x and 2x scale factors.
    display_size: f32 = 48,

    pub fn bodyFamilyName(self: TypographyTokens) []const u8 {
        return self.font_family.cssName();
    }

    /// Resolve the button-label face: the explicit override when set;
    /// otherwise the medium companion while the house sans is in play,
    /// or the theme's own face when it swapped `font_id`. Hosts that
    /// have not mapped the medium id fall back to the regular outlines
    /// at the same estimator advances, so measured and painted widths
    /// always agree.
    pub fn buttonFontId(self: TypographyTokens) FontId {
        if (self.button_font_id) |font_id| return font_id;
        if (self.font_id == default_sans_font_id) return default_sans_medium_font_id;
        return self.font_id;
    }

    pub fn monoFamilyName(self: TypographyTokens) []const u8 {
        return self.mono_font_family.cssName();
    }
};

pub const SpacingTokens = struct {
    xs: f32 = 4,
    sm: f32 = 8,
    md: f32 = 12,
    lg: f32 = 16,
    xl: f32 = 24,
};

/// Derived from a 10px base radius, the derivation the house scale uses:
/// `--radius`: lg is the base, md steps down 2, sm steps down 4, and xl
/// steps up 4. Buttons and inputs sit on md; cards and surfaces on lg.
pub const RadiusTokens = struct {
    sm: f32 = 6,
    md: f32 = 8,
    lg: f32 = 10,
    xl: f32 = 14,
};

pub const StrokeTokens = struct {
    hairline: f32 = 1,
    regular: f32 = 1,
    /// Focus ring stroke width.
    focus: f32 = 2,
    /// How far the focus ring sits OUTSIDE the control's border — the
    /// ring-offset treatment: the control keeps its own border and the
    /// ring floats this gap outside it, so focus never restyles the
    /// control. Together with `focus` this is the whole ring geometry.
    focus_offset: f32 = 2,
};

/// The interaction-state formulas the emitters apply when a control's
/// themed table (`ControlTokens`) does not state an explicit color for
/// the state: multiplicative washes over the control's own base color.
/// Promoting the formulas to tokens lets a theme restate how the WHOLE
/// register responds to interaction without touching any emitter; the
/// defaults are the measured house recipe.
pub const StateTokens = struct {
    /// Filled controls hovered: the base fill at 90% of its own alpha —
    /// the wash lightens on light surfaces and deepens on dark ones
    /// without a second color per scheme.
    hover_fill_alpha: f32 = 0.9,
    /// Filled controls pressed: one step past hover, 80%.
    pressed_fill_alpha: f32 = 0.8,
    /// The disabled register: fill, border, and ink all fade to this
    /// fraction of their rest strength, so the control mutes as one
    /// piece and a checked-but-disabled control still reads as checked.
    disabled_alpha: f32 = 0.5,
    /// Selection wash over static (read-only) text: the accent as a
    /// translucent band under glyphs that keep their own ink. Editable
    /// fields invert instead (solid accent + accent_text) — no alpha.
    selection_wash_alpha: f32 = 0.3,
    /// The quiet destructive chip's wash ladder (rest, hover, pressed):
    /// feedback DEEPENS the wash — a translucent chip signals under the
    /// pointer by gaining ink, opposite of the filled variants' alpha
    /// cuts. These are the light-scheme fallbacks; the themed control
    /// tables restate per-scheme strengths where they differ.
    destructive_wash_alpha: f32 = 0.10,
    destructive_wash_hover_alpha: f32 = 0.15,
    destructive_wash_pressed_alpha: f32 = 0.20,
    /// The destructive badge chip's wash: badges are smaller than
    /// buttons, so the chip carries slightly more ink to stay legible.
    badge_destructive_wash_alpha: f32 = 0.12,
    /// Secondary buttons hovered: the muted fill at 80% of its own
    /// alpha — the filled-variant hover cut applied to the muted chip.
    secondary_hover_alpha: f32 = 0.8,
};

/// The spinner's structural register: which SHAPE the activity
/// indicator draws. Structure is a pack signature the same way thumb
/// shape is for sliders, so it rides the token surface — the emitter
/// reads the channel and never asks which pack is active.
pub const SpinnerStyleToken = enum {
    /// A single stroked arc that the runtime spins continuously — the
    /// house register.
    arc,
    /// A dial of radial pill segments at fixed angles whose opacities
    /// fade head-to-tail — the runtime staggers one opacity loop per
    /// segment so the bright head steps around the dial.
    segmented,
};

/// The control metric ladder: the measured size register every control
/// draws from, promoted to tokens so a theme pack can restate the whole
/// scale (heights, insets, icon metrics) without touching layout code.
/// Defaults are the house base register. All values are pre-density:
/// the density channel multiplies on top exactly as before.
pub const ControlMetricTokens = struct {
    /// The ONE control height register — buttons, inputs, and select
    /// triggers all sit on this whole-pixel ladder (sm/default/lg)
    /// instead of a multiplicative scale: heights on the 4px grid keep
    /// a mixed toolbar row at exactly one height and pixel-snap cleanly
    /// at every scale factor. Every kind on the register moves together.
    control_height_sm: f32 = 28,
    control_height: f32 = 32,
    control_height_lg: f32 = 36,
    /// A button's horizontal inset per size rung. The house register
    /// holds ONE 10px inset across the ladder (the sizes already speak
    /// through height, radius, and the sm label step); packs whose
    /// buttons breathe wider at lg state each rung explicitly.
    button_inset_sm: f32 = 10,
    button_inset: f32 = 10,
    button_inset_lg: f32 = 10,
    /// How far the sm button label steps DOWN from the button type size
    /// (14 -> 12.8 on the house scale): the compact rung is a genuinely
    /// smaller control, and a full-size label inside its box crowds the
    /// padding. Fractional on purpose — the measured compact size.
    button_label_sm_step: f32 = 1.2,
    /// How far the lg button label steps UP from the button type size.
    /// Zero in the house register — a bigger button earns more chrome,
    /// not bigger glyphs — but packs with a large-button type rung use
    /// this to reach it.
    button_label_lg_step: f32 = 0,
    /// Gap between a button's inline icon and its label: intra-content
    /// spacing (the glyph and the label are one phrase), so it never
    /// widens with the size ladder.
    button_icon_gap: f32 = 6,
    /// Inline icons size just above their companion text (extent = text
    /// size + this step) so icon and label read as one line. Shared by
    /// buttons, badges, and row-shaped controls.
    icon_text_step: f32 = 2,
    /// Default extent of row-shaped widgets (list rows and friends)
    /// before the size/density channel scales it.
    row_extent: f32 = 28,
    /// The whole-pixel step the sized control insets take around their
    /// base (sm = base - step, lg = base + step).
    size_inset_step: f32 = 2,
    /// The slider's geometry register, promoted to tokens because thumb
    /// SHAPE is a pack signature, not a color: the house slider is a
    /// quiet 4px rail under a 12px round thumb, while other registers
    /// pair a heavier rail with a narrow rectangular grab handle. All
    /// three values are pre-size/density, like the rest of the ladder.
    slider_track_height: f32 = 4,
    slider_thumb_width: f32 = 12,
    slider_thumb_height: f32 = 12,
    /// The selected-tab marker's weight in the `.underline` tab register
    /// (see `ControlTokens.tabs_indicator`): the bar drawn under the
    /// active trigger's label. Unused by the house `.pill` register —
    /// the default only matters once a theme opts into underlines.
    tabs_indicator_thickness: f32 = 2,
    /// The inter-trigger gap of the `.underline` tab register (see
    /// `ControlTokens.tabs_indicator`), applied only when the author
    /// left the strip's gap at 0. Unused by the house `.pill` register —
    /// its triggers sit flush inside the container wash on purpose, so
    /// the default stays 0 and no-pack layout never moves.
    tabs_gap: f32 = 0,
    /// The inter-chip gap of the `.detached` button-group register (see
    /// `ControlTokens.button_group_style`), applied only when the author
    /// left the group's gap at 0. Unused by the house `.segmented`
    /// register — a gap-0 segmented group attaches on purpose, so the
    /// default stays 0 and no-pack rendering never moves.
    button_group_gap: f32 = 0,
    /// The spinner's structural register, promoted to tokens because
    /// indicator SHAPE is a pack signature, not a color: the house
    /// spinner is one stroked arc spun continuously, while other
    /// registers draw a dial of fading pill segments. The segment
    /// fields are ratios of the spinner's box (so every size rung keeps
    /// the register's proportions) and are read only when the style is
    /// `.segmented`; the defaults leave `.arc` rendering untouched.
    spinner_style: SpinnerStyleToken = .arc,
    /// Segments around the dial. Clamped to the widget part-id space at
    /// emit time (15 slots), so counts stay honest per-command targets
    /// for the runtime's per-segment opacity loops.
    spinner_segment_count: u32 = 12,
    /// Radial pill length as a fraction of the box extent.
    spinner_segment_length_ratio: f32 = 0.25,
    /// Pill thickness as a fraction of the box extent.
    spinner_segment_thickness_ratio: f32 = 0.1,
    /// Distance from the dial center to each pill's own center, as a
    /// fraction of the box extent.
    spinner_segment_radius_ratio: f32 = 0.365,
    /// The opacity floor a segment fades to at the end of the trail;
    /// the head sits at full strength.
    spinner_tail_opacity: f32 = 0.15,
    /// One full cycle of the indicator, in milliseconds: a whole turn
    /// of the arc register, or one head-lap of the segmented dial. Kept
    /// with the structural fields (not the motion ladder) because the
    /// cycle is part of the register's identity, and reduced motion
    /// already gates the loop through `MotionTokens` upstream.
    spinner_period_ms: u32 = 1000,
};

pub const ShadowToken = struct {
    y: f32 = 8,
    blur: f32 = 24,
    spread: f32 = -10,
};

pub const ShadowTokens = struct {
    none: ShadowToken = .{ .y = 0, .blur = 0, .spread = 0 },
    /// The whisper step under filled buttons: a 1px drop with a 2px
    /// blur, drawn at half the house shadow ink (~5% black). It never
    /// reads as elevation — it settles a solid control onto the page
    /// the way a hairline settles a card. Zeroing it flattens buttons
    /// without touching surface shadows.
    xs: ShadowToken = .{ .y = 1, .blur = 2, .spread = 0 },
    sm: ShadowToken = .{ .y = 2, .blur = 8, .spread = -4 },
    md: ShadowToken = .{ .y = 8, .blur = 24, .spread = -12 },
};

pub const BlurTokens = struct {
    none: f32 = 0,
    sm: f32 = 8,
    md: f32 = 16,
    /// Backdrop-blur strength (Gaussian sigma, in points) applied to
    /// the already-painted content behind a modal surface's scrim —
    /// dialogs, drawers, and sheets. 4 is deliberately soft: with the
    /// 10% `ColorTokens.scrim` wash on top it reads as frosted glass,
    /// not fog. 0 disables the blur and leaves only the wash (themes
    /// that avoid transparency effects should zero this and raise the
    /// scrim alpha instead). Not part of `BlurTokenRef`: widgets opt
    /// into sm/md backdrops individually, while this one is applied by
    /// the modal chrome itself.
    scrim: f32 = 4,

    pub fn value(self: BlurTokens, token: BlurTokenRef) f32 {
        return switch (token) {
            .none => self.none,
            .sm => self.sm,
            .md => self.md,
        };
    }
};

pub const MotionDuration = enum {
    fast,
    normal,
    slow,
};

pub const MotionAnimationOptions = struct {
    id: ObjectId,
    start_ns: u64 = 0,
    duration: MotionDuration = .normal,
    easing: ?Easing = null,
    spring: ?SpringToken = null,
    from_opacity: ?f32 = null,
    to_opacity: ?f32 = null,
    from_transform: ?Affine = null,
    to_transform: ?Affine = null,
};

pub const MotionTokens = struct {
    fast_ms: u32 = 120,
    normal_ms: u32 = 180,
    slow_ms: u32 = 260,
    easing: Easing = .standard,
    spring: SpringToken = .{},

    pub fn reduced() MotionTokens {
        return .{
            .fast_ms = 0,
            .normal_ms = 0,
            .slow_ms = 0,
            .easing = .linear,
        };
    }

    pub fn durationMs(self: MotionTokens, duration: MotionDuration) u32 {
        return switch (duration) {
            .fast => self.fast_ms,
            .normal => self.normal_ms,
            .slow => self.slow_ms,
        };
    }

    pub fn animation(self: MotionTokens, options: MotionAnimationOptions) CanvasRenderAnimation {
        return .{
            .id = options.id,
            .start_ns = options.start_ns,
            .duration_ms = self.durationMs(options.duration),
            .easing = options.easing orelse self.easing,
            .spring = options.spring orelse self.spring,
            .from_opacity = options.from_opacity,
            .to_opacity = options.to_opacity,
            .from_transform = options.from_transform,
            .to_transform = options.to_transform,
        };
    }
};

pub const SpringToken = struct {
    mass: f32 = 1,
    stiffness: f32 = 220,
    damping: f32 = 28,
};

pub const BlurTokenRef = enum {
    none,
    sm,
    md,
};

/// Edge behavior of a scrollable region: `.none` pins the offset at the
/// content edges (wheel input clamps, kinetic motion stops cleanly at the
/// boundary), `.rubber_band` lets the offset travel past an edge under
/// resistance and spring back. `ScrollPhysics.overscroll` is the global
/// default; a scroll region overrides it per region through
/// `Widget.overscroll` (builder `overscroll:`, markup `overscroll=`).
pub const ScrollOverscroll = enum {
    none,
    rubber_band,
};

pub const ScrollPhysics = struct {
    wheel_multiplier: f32 = 1,
    wheel_velocity_scale: f32 = 60,
    deceleration_per_second: f32 = 0.86,
    stop_velocity: f32 = 5,
    /// Global default edge behavior for scroll regions. Off by default:
    /// scrolling stops at the content edges. Regions opt in individually
    /// (`Widget.overscroll = .rubber_band`), or a theme flips this token
    /// to make bouncing the app-wide default.
    overscroll: ScrollOverscroll = .none,
    /// Shape of the rubber-band excursion when overscroll is enabled.
    /// The extent ratio bounds how far past an edge the offset may
    /// travel (a fraction of the viewport); `rubberband_max_extent`
    /// caps it in points (0 = ratio only).
    rubberband_extent_ratio: f32 = 0.35,
    rubberband_max_extent: f32 = 0,
    rubberband_resistance: f32 = 0.38,
    rubberband_return_per_second: f32 = 18,
    rubberband_velocity_decay_per_second: f32 = 0,
    rubberband_snap_distance: f32 = 0.5,
};

pub const ScrollState = struct {
    offset: f32 = 0,
    velocity: f32 = 0,
    viewport_extent: f32 = 0,
    content_extent: f32 = 0,

    pub fn maxOffset(self: ScrollState) f32 {
        return @max(0, nonNegative(self.content_extent) - nonNegative(self.viewport_extent));
    }

    pub fn clamped(self: ScrollState) ScrollState {
        var next = self;
        const clamped_offset = std.math.clamp(nonNegative(next.offset), 0, next.maxOffset());
        if (clamped_offset != next.offset) next.velocity = 0;
        next.offset = clamped_offset;
        return next;
    }

    pub fn applyWheel(self: ScrollState, delta: f32, physics: ScrollPhysics) ScrollState {
        return self.applyWheelWithRubberband(delta, physics, physics.overscroll == .rubber_band);
    }

    pub fn applyWheelClamped(self: ScrollState, delta: f32, physics: ScrollPhysics) ScrollState {
        return self.applyWheelWithRubberband(delta, physics, false);
    }

    pub fn visualOffset(self: ScrollState) f32 {
        return std.math.clamp(self.offset, 0, self.maxOffset());
    }

    pub fn overscroll(self: ScrollState) f32 {
        return self.offset - self.visualOffset();
    }

    pub fn needsKineticStep(self: ScrollState, physics: ScrollPhysics) bool {
        return @abs(self.velocity) > nonNegative(physics.stop_velocity) or @abs(self.overscroll()) > @max(0.01, nonNegative(physics.rubberband_snap_distance));
    }

    fn applyWheelWithRubberband(self: ScrollState, delta: f32, physics: ScrollPhysics, rubberband: bool) ScrollState {
        var next = self;
        const scaled_delta = delta * physics.wheel_multiplier;
        var effective_delta = scaled_delta;
        if (rubberband and scaled_delta != 0) {
            const max_offset = next.maxOffset();
            const moving_outward =
                (next.offset <= 0 and scaled_delta < 0) or
                (next.offset >= max_offset and scaled_delta > 0);
            if (moving_outward) {
                effective_delta *= std.math.clamp(physics.rubberband_resistance, 0, 1);
            }
        }
        next.offset += effective_delta;
        next.velocity = scaled_delta * physics.wheel_velocity_scale;
        return if (rubberband) next.rubberbanded(physics) else next.clamped();
    }

    pub fn stepKinetic(self: ScrollState, dt_ms: f32, physics: ScrollPhysics) ScrollState {
        var next = self;
        const dt_seconds = nonNegative(dt_ms) / 1000.0;
        // With overscroll off there is never an excursion to recover
        // from: pin any out-of-range offset immediately (content shrank,
        // a stale state) and run the plain decay path — velocity zeroes
        // the moment the offset reaches an edge, the clean-stop feel.
        if (physics.overscroll == .none) next = next.clamped();
        if (@abs(next.overscroll()) > 0.01) {
            const bounded = next.visualOffset();
            const overscroll_delta = next.offset - bounded;
            const recovery = std.math.clamp(nonNegative(physics.rubberband_return_per_second) * dt_seconds, 0, 1);
            next.offset -= overscroll_delta * recovery;
            const velocity_decay = std.math.pow(f32, std.math.clamp(physics.rubberband_velocity_decay_per_second, 0, 1), dt_seconds);
            next.velocity *= velocity_decay;
            if (@abs(next.offset - bounded) <= nonNegative(physics.rubberband_snap_distance) and @abs(next.velocity) <= nonNegative(physics.stop_velocity) * 4) {
                next.offset = bounded;
                next.velocity = 0;
            }
            return next.rubberbanded(physics);
        }

        if (@abs(next.velocity) <= nonNegative(physics.stop_velocity)) {
            next.velocity = 0;
            return next;
        }

        next.offset += next.velocity * dt_seconds;
        const decay = std.math.pow(f32, std.math.clamp(physics.deceleration_per_second, 0, 1), dt_seconds);
        next.velocity *= decay;
        if (@abs(next.velocity) <= nonNegative(physics.stop_velocity)) next.velocity = 0;
        return next.rubberbanded(physics);
    }

    fn rubberbanded(self: ScrollState, physics: ScrollPhysics) ScrollState {
        if (physics.overscroll == .none) return self.clamped();
        const extent = self.rubberbandExtent(physics);
        if (extent <= 0) return self.clamped();
        var next = self;
        const min_offset = -extent;
        const max_offset = next.maxOffset() + extent;
        next.offset = std.math.clamp(next.offset, min_offset, max_offset);
        return next;
    }

    fn rubberbandExtent(self: ScrollState, physics: ScrollPhysics) f32 {
        const viewport_extent = nonNegative(self.viewport_extent);
        if (viewport_extent <= 0) return 0;
        const ratio_extent = viewport_extent * nonNegative(physics.rubberband_extent_ratio);
        const max_extent = nonNegative(physics.rubberband_max_extent);
        if (max_extent <= 0) return ratio_extent;
        return @min(ratio_extent, max_extent);
    }
};

pub const VirtualListOptions = struct {
    item_count: usize = 0,
    item_extent: f32 = 0,
    item_gap: f32 = 0,
    viewport_extent: f32 = 0,
    scroll_offset: f32 = 0,
    overscan: usize = 0,
};

pub const VirtualListRange = struct {
    start_index: usize = 0,
    end_index: usize = 0,
    first_visible_index: usize = 0,
    last_visible_index: usize = 0,
    item_extent: f32 = 0,
    item_gap: f32 = 0,
    scroll_offset: f32 = 0,
    layout_offset: f32 = 0,
    content_extent: f32 = 0,
    before_extent: f32 = 0,
    after_extent: f32 = 0,
    /// VARIABLE-extent windows only (`item_extent == 0`): the offset
    /// table's leading edge for `first_visible_index` — the row the
    /// layout pass anchors the built window on, so estimate error in
    /// freshly mounted rows surfaces off-screen (above the anchor),
    /// never under the user's eyes. Uniform windows leave it 0.
    anchor_extent: f32 = 0,

    pub fn itemCount(self: VirtualListRange) usize {
        return self.end_index - self.start_index;
    }

    pub fn isEmpty(self: VirtualListRange) bool {
        return self.start_index >= self.end_index;
    }
};

pub fn virtualListRange(options: VirtualListOptions) VirtualListRange {
    if (options.item_count == 0 or options.item_extent <= 0 or options.viewport_extent <= 0) return .{};

    const item_extent = nonNegative(options.item_extent);
    const item_gap = nonNegative(options.item_gap);
    const stride = item_extent + item_gap;
    const item_count_f = @as(f32, @floatFromInt(options.item_count));
    const content_extent = item_count_f * item_extent + @max(0, item_count_f - 1) * item_gap;
    const viewport_extent = nonNegative(options.viewport_extent);
    const max_offset = @max(0, content_extent - viewport_extent);
    const raw_offset = if (std.math.isFinite(options.scroll_offset)) options.scroll_offset else 0;
    const offset = std.math.clamp(nonNegative(raw_offset), 0, max_offset);
    const layout_offset = std.math.clamp(raw_offset, -viewport_extent, max_offset + viewport_extent);

    const first_visible = @min(options.item_count - 1, floorVirtualIndex(offset / stride));
    const visible_end = @min(options.item_count, ceilVirtualIndex((offset + viewport_extent + item_gap) / stride));
    const start_index = if (first_visible > options.overscan) first_visible - options.overscan else 0;
    const end_index = @min(options.item_count, visible_end + options.overscan);

    return .{
        .start_index = start_index,
        .end_index = end_index,
        .first_visible_index = first_visible,
        .last_visible_index = if (visible_end > 0) visible_end - 1 else first_visible,
        .item_extent = item_extent,
        .item_gap = item_gap,
        .scroll_offset = offset,
        .layout_offset = layout_offset,
        .content_extent = content_extent,
        .before_extent = @as(f32, @floatFromInt(start_index)) * stride,
        .after_extent = @as(f32, @floatFromInt(options.item_count - end_index)) * stride,
    };
}

pub const LayerTokens = struct {
    base: i32 = 0,
    floating: i32 = 100,
    overlay: i32 = 200,
    modal: i32 = 300,
};

pub const PixelSnapTokens = struct {
    geometry: bool = false,
    text: bool = false,
    scale: f32 = 1,
};

/// How a tab strip marks its selected trigger — a REGISTER choice, not
/// a color: the two kinds are different geometry, so it lives beside
/// the control tables rather than inside a `ControlVisualTokens` entry.
///
/// - `.pill`: the house treatment. The TabsList paints one muted
///   rounded container; the active trigger lifts to the page surface
///   as a bordered pill inside it.
/// - `.underline`: text tabs on a bare strip. The TabsList paints only
///   a bottom hairline (its `tabs` table's border channel), and the
///   active trigger draws a short bar under its label
///   (`ControlMetricTokens.tabs_indicator_thickness` weight, ink from
///   the `segmented_control` table's active_background channel, falling
///   back to the primary text color) that overlaps the strip hairline.
///   Triggers sit apart by the author's gap or, when the author left
///   the gap at 0, the pack's `ControlMetricTokens.tabs_gap`.
pub const TabsIndicatorKind = enum {
    pill,
    underline,
};

/// How a button group's segments relate — a REGISTER choice, not a
/// color, so it lives beside the control tables like `tabs_indicator`:
///
/// - `.segmented`: the house treatment. A gap-0 group renders as ONE
///   attached bar — the first segment keeps its leading corners, the
///   last its trailing pair, middles square off, and interior seams
///   collapse to a single shared stroke. A gap above 0 opts back into
///   ordinary separate buttons.
/// - `.detached`: chip triggers. Every group member renders as its own
///   fully-rounded chip from the `button_group` control table (rest
///   wash, ink-inverted selected fill, borderless), separated by the
///   author's gap or, when the author left the gap at 0, the pack's
///   `ControlMetricTokens.button_group_gap`.
pub const ButtonGroupKind = enum {
    segmented,
    detached,
};

pub const ControlVisualTokens = struct {
    background: ?Color = null,
    hover_background: ?Color = null,
    /// The pressed-or-selected fill (both feedback and on-state reach
    /// for it when the more specific channels below are unset).
    active_background: ?Color = null,
    /// The transient pointer-down fill alone. Null falls through to
    /// `active_background`, then to the state-formula washes — so a
    /// theme that wants press and on-state to differ states both.
    pressed_background: ?Color = null,
    /// Disabled fill and ink. Null keeps the half-strength wash
    /// register (`StateTokens.disabled_alpha` over the rest colors);
    /// themes whose disabled treatment is a color SWAP (a flat gray
    /// chip under gray text) state the pair here.
    disabled_background: ?Color = null,
    disabled_foreground: ?Color = null,
    foreground: ?Color = null,
    /// The selected/pressed state's ink, for controls whose active fill
    /// inverts against the rest ink (a detached button-group chip's
    /// knockout label). Null keeps each consumer's existing ink ladder.
    active_foreground: ?Color = null,
    border: ?Color = null,
    radius: ?f32 = null,
    stroke_width: ?f32 = null,
};

pub const ControlTokens = struct {
    button_default: ControlVisualTokens = .{},
    button_primary: ControlVisualTokens = .{},
    button_secondary: ControlVisualTokens = .{},
    button_outline: ControlVisualTokens = .{},
    button_ghost: ControlVisualTokens = .{},
    button_destructive: ControlVisualTokens = .{},
    toggle_button: ControlVisualTokens = .{},
    accordion: ControlVisualTokens = .{},
    alert: ControlVisualTokens = .{},
    bubble: ControlVisualTokens = .{},
    card: ControlVisualTokens = .{},
    dialog: ControlVisualTokens = .{},
    drawer: ControlVisualTokens = .{},
    sheet: ControlVisualTokens = .{},
    select: ControlVisualTokens = .{},
    input: ControlVisualTokens = .{},
    text_field: ControlVisualTokens = .{},
    search_field: ControlVisualTokens = .{},
    combobox: ControlVisualTokens = .{},
    textarea: ControlVisualTokens = .{},
    list_item: ControlVisualTokens = .{},
    menu_item: ControlVisualTokens = .{},
    data_cell: ControlVisualTokens = .{},
    /// The tabs LIST container (the house tab-strip treatment): the muted rounded
    /// wash the `segmented_control` triggers sit on.
    tabs: ControlVisualTokens = .{},
    segmented_control: ControlVisualTokens = .{},
    /// The tab strip's indicator register — pill (house) or underline.
    /// A geometry switch shared by the TabsList chrome and the trigger
    /// emitter, so both halves of the control change shape together.
    tabs_indicator: TabsIndicatorKind = .pill,
    /// The detached button-group chip treatment (read only when
    /// `button_group_style` is `.detached`): `background` is the rest
    /// wash every member wears, `active_background`/`active_foreground`
    /// the selected chip's ink-inverted fill and knockout label,
    /// `foreground` the rest ink. The house `.segmented` register never
    /// reads this table — its segments keep their variant chrome.
    button_group: ControlVisualTokens = .{},
    /// The button-group register — attached segments (house) or
    /// detached chips. A geometry-and-fill switch shared by the group
    /// walks (segment stamping, gap) and the button emitters.
    button_group_style: ButtonGroupKind = .segmented,
    checkbox: ControlVisualTokens = .{},
    radio: ControlVisualTokens = .{},
    switch_control: ControlVisualTokens = .{},
    slider: ControlVisualTokens = .{},
    progress: ControlVisualTokens = .{},
    scrollbar: ControlVisualTokens = .{},
    panel: ControlVisualTokens = .{},
    resizable: ControlVisualTokens = .{},
    popover: ControlVisualTokens = .{},
    menu_surface: ControlVisualTokens = .{},
    dropdown_menu: ControlVisualTokens = .{},
    tooltip: ControlVisualTokens = .{},
    avatar: ControlVisualTokens = .{},
    badge: ControlVisualTokens = .{},
    separator: ControlVisualTokens = .{},
    skeleton: ControlVisualTokens = .{},
    spinner: ControlVisualTokens = .{},

    /// The per-scheme control register. Most controls derive their whole
    /// appearance from `ColorTokens` and need no entry here; the tables
    /// exist for the treatments whose light/dark difference is MORE than
    /// a palette swap — different wash STRENGTHS per scheme — which must
    /// be stated per theme rather than sniffed from surface luminance at
    /// render time (a themed app with an unusual background must not
    /// flip register by accident):
    ///
    /// - Destructive buttons are the quiet red chip: the destructive hue
    ///   at 10% alpha in light and 20% in dark (a dark page swallows the
    ///   thinner wash), text in the destructive red itself, no border.
    ///   Hover/pressed deepen the wash one 5% step at a time — a
    ///   translucent chip signals by gaining ink, not losing it.
    /// - Dark outline buttons are glass: white at 4.5% for the body and
    ///   white at 15% for the border, so the control brightens whatever
    ///   it floats over. Light outline is the opaque register — the page
    ///   background as fill under the standard hairline border.
    pub fn theme(color_scheme: ColorScheme, contrast: ColorContrast) ControlTokens {
        const colors = ColorTokens.theme(color_scheme, contrast);
        const wash: f32 = switch (color_scheme) {
            .light => 0.10,
            .dark => 0.20,
        };
        return .{
            .button_outline = switch (color_scheme) {
                .light => .{
                    .background = colors.background,
                },
                // The glass BORDER is a standard-contrast treatment
                // only: high contrast keeps the palette's loud hairline
                // (`colors.border`, white at ~75%) — a 15% override
                // would quietly undo the contrast the user asked for.
                // The faint body wash survives both.
                .dark => switch (contrast) {
                    .standard => .{
                        .background = colorAlpha(Color.rgb8(255, 255, 255), 0.045),
                        .border = colorAlpha(Color.rgb8(255, 255, 255), 0.15),
                    },
                    .high => .{
                        .background = colorAlpha(Color.rgb8(255, 255, 255), 0.045),
                    },
                },
            },
            .button_destructive = .{
                .background = colorAlpha(colors.destructive, wash),
                .hover_background = colorAlpha(colors.destructive, wash + 0.05),
                .active_background = colorAlpha(colors.destructive, wash + 0.10),
                .foreground = colors.destructive,
                .stroke_width = 0,
            },
        };
    }
};

/// A palette color at an explicit wash strength — the themed control
/// tables' translucency channel.
fn colorAlpha(color: Color, alpha: f32) Color {
    return Color.rgba(color.r, color.g, color.b, std.math.clamp(alpha, 0, 1));
}

pub const ColorTokenOverrides = struct {
    background: ?Color = null,
    surface: ?Color = null,
    surface_subtle: ?Color = null,
    surface_pressed: ?Color = null,
    text: ?Color = null,
    text_muted: ?Color = null,
    border: ?Color = null,
    accent: ?Color = null,
    accent_text: ?Color = null,
    destructive: ?Color = null,
    destructive_text: ?Color = null,
    success: ?Color = null,
    success_text: ?Color = null,
    warning: ?Color = null,
    warning_text: ?Color = null,
    info: ?Color = null,
    info_text: ?Color = null,
    focus_ring: ?Color = null,
    shadow: ?Color = null,
    scrim: ?Color = null,
    disabled: ?Color = null,

    pub fn apply(self: ColorTokenOverrides, base: ColorTokens) ColorTokens {
        return applyFlatTokenOverrides(ColorTokens, base, self);
    }
};

pub const TypographyTokenOverrides = struct {
    font_id: ?FontId = null,
    mono_font_id: ?FontId = null,
    font_family: ?FontFamily = null,
    mono_font_family: ?FontFamily = null,
    body_size: ?f32 = null,
    label_size: ?f32 = null,
    title_size: ?f32 = null,
    button_size: ?f32 = null,
    button_font_id: ?FontId = null,
    heading_size: ?f32 = null,
    display_size: ?f32 = null,

    pub fn apply(self: TypographyTokenOverrides, base: TypographyTokens) TypographyTokens {
        return applyFlatTokenOverrides(TypographyTokens, base, self);
    }
};

pub const SpacingTokenOverrides = struct {
    xs: ?f32 = null,
    sm: ?f32 = null,
    md: ?f32 = null,
    lg: ?f32 = null,
    xl: ?f32 = null,

    pub fn apply(self: SpacingTokenOverrides, base: SpacingTokens) SpacingTokens {
        return applyFlatTokenOverrides(SpacingTokens, base, self);
    }
};

pub const RadiusTokenOverrides = struct {
    sm: ?f32 = null,
    md: ?f32 = null,
    lg: ?f32 = null,
    xl: ?f32 = null,

    pub fn apply(self: RadiusTokenOverrides, base: RadiusTokens) RadiusTokens {
        return applyFlatTokenOverrides(RadiusTokens, base, self);
    }
};

pub const StrokeTokenOverrides = struct {
    hairline: ?f32 = null,
    regular: ?f32 = null,
    focus: ?f32 = null,
    focus_offset: ?f32 = null,

    pub fn apply(self: StrokeTokenOverrides, base: StrokeTokens) StrokeTokens {
        return applyFlatTokenOverrides(StrokeTokens, base, self);
    }
};

pub const StateTokenOverrides = struct {
    hover_fill_alpha: ?f32 = null,
    pressed_fill_alpha: ?f32 = null,
    disabled_alpha: ?f32 = null,
    selection_wash_alpha: ?f32 = null,
    destructive_wash_alpha: ?f32 = null,
    destructive_wash_hover_alpha: ?f32 = null,
    destructive_wash_pressed_alpha: ?f32 = null,
    badge_destructive_wash_alpha: ?f32 = null,
    secondary_hover_alpha: ?f32 = null,

    pub fn apply(self: StateTokenOverrides, base: StateTokens) StateTokens {
        return applyFlatTokenOverrides(StateTokens, base, self);
    }
};

pub const ControlMetricTokenOverrides = struct {
    control_height_sm: ?f32 = null,
    control_height: ?f32 = null,
    control_height_lg: ?f32 = null,
    button_inset_sm: ?f32 = null,
    button_inset: ?f32 = null,
    button_inset_lg: ?f32 = null,
    button_label_sm_step: ?f32 = null,
    button_label_lg_step: ?f32 = null,
    button_icon_gap: ?f32 = null,
    icon_text_step: ?f32 = null,
    row_extent: ?f32 = null,
    size_inset_step: ?f32 = null,
    slider_track_height: ?f32 = null,
    slider_thumb_width: ?f32 = null,
    slider_thumb_height: ?f32 = null,
    tabs_indicator_thickness: ?f32 = null,
    tabs_gap: ?f32 = null,
    button_group_gap: ?f32 = null,
    spinner_style: ?SpinnerStyleToken = null,
    spinner_segment_count: ?u32 = null,
    spinner_segment_length_ratio: ?f32 = null,
    spinner_segment_thickness_ratio: ?f32 = null,
    spinner_segment_radius_ratio: ?f32 = null,
    spinner_tail_opacity: ?f32 = null,
    spinner_period_ms: ?u32 = null,

    pub fn apply(self: ControlMetricTokenOverrides, base: ControlMetricTokens) ControlMetricTokens {
        return applyFlatTokenOverrides(ControlMetricTokens, base, self);
    }
};

pub const ShadowTokenOverrides = struct {
    y: ?f32 = null,
    blur: ?f32 = null,
    spread: ?f32 = null,

    pub fn apply(self: ShadowTokenOverrides, base: ShadowToken) ShadowToken {
        return applyFlatTokenOverrides(ShadowToken, base, self);
    }
};

pub const ShadowTokensOverrides = struct {
    none: ShadowTokenOverrides = .{},
    xs: ShadowTokenOverrides = .{},
    sm: ShadowTokenOverrides = .{},
    md: ShadowTokenOverrides = .{},

    pub fn apply(self: ShadowTokensOverrides, base: ShadowTokens) ShadowTokens {
        var next = base;
        next.none = self.none.apply(next.none);
        next.xs = self.xs.apply(next.xs);
        next.sm = self.sm.apply(next.sm);
        next.md = self.md.apply(next.md);
        return next;
    }
};

pub const BlurTokenOverrides = struct {
    none: ?f32 = null,
    sm: ?f32 = null,
    md: ?f32 = null,
    scrim: ?f32 = null,

    pub fn apply(self: BlurTokenOverrides, base: BlurTokens) BlurTokens {
        return applyFlatTokenOverrides(BlurTokens, base, self);
    }
};

pub const SpringTokenOverrides = struct {
    mass: ?f32 = null,
    stiffness: ?f32 = null,
    damping: ?f32 = null,

    pub fn apply(self: SpringTokenOverrides, base: SpringToken) SpringToken {
        return applyFlatTokenOverrides(SpringToken, base, self);
    }
};

pub const MotionTokenOverrides = struct {
    fast_ms: ?u32 = null,
    normal_ms: ?u32 = null,
    slow_ms: ?u32 = null,
    easing: ?Easing = null,
    spring: SpringTokenOverrides = .{},

    pub fn apply(self: MotionTokenOverrides, base: MotionTokens) MotionTokens {
        var next = applyFlatTokenOverrides(MotionTokens, base, .{
            .fast_ms = self.fast_ms,
            .normal_ms = self.normal_ms,
            .slow_ms = self.slow_ms,
            .easing = self.easing,
        });
        next.spring = self.spring.apply(next.spring);
        return next;
    }
};

pub const ScrollPhysicsOverrides = struct {
    wheel_multiplier: ?f32 = null,
    wheel_velocity_scale: ?f32 = null,
    deceleration_per_second: ?f32 = null,
    stop_velocity: ?f32 = null,
    overscroll: ?ScrollOverscroll = null,
    rubberband_extent_ratio: ?f32 = null,
    rubberband_max_extent: ?f32 = null,
    rubberband_resistance: ?f32 = null,
    rubberband_return_per_second: ?f32 = null,
    rubberband_velocity_decay_per_second: ?f32 = null,
    rubberband_snap_distance: ?f32 = null,

    pub fn apply(self: ScrollPhysicsOverrides, base: ScrollPhysics) ScrollPhysics {
        return applyFlatTokenOverrides(ScrollPhysics, base, self);
    }
};

pub const LayerTokenOverrides = struct {
    base: ?i32 = null,
    floating: ?i32 = null,
    overlay: ?i32 = null,
    modal: ?i32 = null,

    pub fn apply(self: LayerTokenOverrides, base: LayerTokens) LayerTokens {
        return applyFlatTokenOverrides(LayerTokens, base, self);
    }
};

pub const PixelSnapTokenOverrides = struct {
    geometry: ?bool = null,
    text: ?bool = null,
    scale: ?f32 = null,

    pub fn apply(self: PixelSnapTokenOverrides, base: PixelSnapTokens) PixelSnapTokens {
        return applyFlatTokenOverrides(PixelSnapTokens, base, self);
    }
};

pub const ControlVisualTokenOverrides = struct {
    background: ?Color = null,
    hover_background: ?Color = null,
    active_background: ?Color = null,
    pressed_background: ?Color = null,
    disabled_background: ?Color = null,
    disabled_foreground: ?Color = null,
    foreground: ?Color = null,
    active_foreground: ?Color = null,
    border: ?Color = null,
    radius: ?f32 = null,
    stroke_width: ?f32 = null,

    pub fn apply(self: ControlVisualTokenOverrides, base: ControlVisualTokens) ControlVisualTokens {
        return applyFlatTokenOverrides(ControlVisualTokens, base, self);
    }
};

pub const ControlTokenOverrides = struct {
    button_default: ControlVisualTokenOverrides = .{},
    button_primary: ControlVisualTokenOverrides = .{},
    button_secondary: ControlVisualTokenOverrides = .{},
    button_outline: ControlVisualTokenOverrides = .{},
    button_ghost: ControlVisualTokenOverrides = .{},
    button_destructive: ControlVisualTokenOverrides = .{},
    toggle_button: ControlVisualTokenOverrides = .{},
    accordion: ControlVisualTokenOverrides = .{},
    alert: ControlVisualTokenOverrides = .{},
    bubble: ControlVisualTokenOverrides = .{},
    card: ControlVisualTokenOverrides = .{},
    dialog: ControlVisualTokenOverrides = .{},
    drawer: ControlVisualTokenOverrides = .{},
    sheet: ControlVisualTokenOverrides = .{},
    select: ControlVisualTokenOverrides = .{},
    input: ControlVisualTokenOverrides = .{},
    text_field: ControlVisualTokenOverrides = .{},
    search_field: ControlVisualTokenOverrides = .{},
    combobox: ControlVisualTokenOverrides = .{},
    textarea: ControlVisualTokenOverrides = .{},
    list_item: ControlVisualTokenOverrides = .{},
    menu_item: ControlVisualTokenOverrides = .{},
    data_cell: ControlVisualTokenOverrides = .{},
    tabs: ControlVisualTokenOverrides = .{},
    segmented_control: ControlVisualTokenOverrides = .{},
    tabs_indicator: ?TabsIndicatorKind = null,
    button_group: ControlVisualTokenOverrides = .{},
    button_group_style: ?ButtonGroupKind = null,
    checkbox: ControlVisualTokenOverrides = .{},
    radio: ControlVisualTokenOverrides = .{},
    switch_control: ControlVisualTokenOverrides = .{},
    slider: ControlVisualTokenOverrides = .{},
    progress: ControlVisualTokenOverrides = .{},
    scrollbar: ControlVisualTokenOverrides = .{},
    panel: ControlVisualTokenOverrides = .{},
    resizable: ControlVisualTokenOverrides = .{},
    popover: ControlVisualTokenOverrides = .{},
    menu_surface: ControlVisualTokenOverrides = .{},
    dropdown_menu: ControlVisualTokenOverrides = .{},
    tooltip: ControlVisualTokenOverrides = .{},
    avatar: ControlVisualTokenOverrides = .{},
    badge: ControlVisualTokenOverrides = .{},
    separator: ControlVisualTokenOverrides = .{},
    skeleton: ControlVisualTokenOverrides = .{},
    spinner: ControlVisualTokenOverrides = .{},

    pub fn apply(self: ControlTokenOverrides, base: ControlTokens) ControlTokens {
        var next = base;
        next.button_default = self.button_default.apply(next.button_default);
        next.button_primary = self.button_primary.apply(next.button_primary);
        next.button_secondary = self.button_secondary.apply(next.button_secondary);
        next.button_outline = self.button_outline.apply(next.button_outline);
        next.button_ghost = self.button_ghost.apply(next.button_ghost);
        next.button_destructive = self.button_destructive.apply(next.button_destructive);
        next.toggle_button = self.toggle_button.apply(next.toggle_button);
        next.accordion = self.accordion.apply(next.accordion);
        next.alert = self.alert.apply(next.alert);
        next.bubble = self.bubble.apply(next.bubble);
        next.card = self.card.apply(next.card);
        next.dialog = self.dialog.apply(next.dialog);
        next.drawer = self.drawer.apply(next.drawer);
        next.sheet = self.sheet.apply(next.sheet);
        next.select = self.select.apply(next.select);
        next.input = self.input.apply(next.input);
        next.text_field = self.text_field.apply(next.text_field);
        next.search_field = self.search_field.apply(next.search_field);
        next.combobox = self.combobox.apply(next.combobox);
        next.textarea = self.textarea.apply(next.textarea);
        next.list_item = self.list_item.apply(next.list_item);
        next.menu_item = self.menu_item.apply(next.menu_item);
        next.data_cell = self.data_cell.apply(next.data_cell);
        next.tabs = self.tabs.apply(next.tabs);
        next.segmented_control = self.segmented_control.apply(next.segmented_control);
        if (self.tabs_indicator) |tabs_indicator| next.tabs_indicator = tabs_indicator;
        next.button_group = self.button_group.apply(next.button_group);
        if (self.button_group_style) |button_group_style| next.button_group_style = button_group_style;
        next.checkbox = self.checkbox.apply(next.checkbox);
        next.radio = self.radio.apply(next.radio);
        next.switch_control = self.switch_control.apply(next.switch_control);
        next.slider = self.slider.apply(next.slider);
        next.progress = self.progress.apply(next.progress);
        next.scrollbar = self.scrollbar.apply(next.scrollbar);
        next.panel = self.panel.apply(next.panel);
        next.resizable = self.resizable.apply(next.resizable);
        next.popover = self.popover.apply(next.popover);
        next.menu_surface = self.menu_surface.apply(next.menu_surface);
        next.dropdown_menu = self.dropdown_menu.apply(next.dropdown_menu);
        next.tooltip = self.tooltip.apply(next.tooltip);
        next.avatar = self.avatar.apply(next.avatar);
        next.badge = self.badge.apply(next.badge);
        next.separator = self.separator.apply(next.separator);
        next.skeleton = self.skeleton.apply(next.skeleton);
        next.spinner = self.spinner.apply(next.spinner);
        return next;
    }
};

pub const DesignTokenOverrides = struct {
    colors: ColorTokenOverrides = .{},
    typography: TypographyTokenOverrides = .{},
    spacing: SpacingTokenOverrides = .{},
    radius: RadiusTokenOverrides = .{},
    stroke: StrokeTokenOverrides = .{},
    states: StateTokenOverrides = .{},
    metrics: ControlMetricTokenOverrides = .{},
    shadow: ShadowTokensOverrides = .{},
    blur: BlurTokenOverrides = .{},
    motion: MotionTokenOverrides = .{},
    scroll: ScrollPhysicsOverrides = .{},
    layer: LayerTokenOverrides = .{},
    pixel_snap: PixelSnapTokenOverrides = .{},
    controls: ControlTokenOverrides = .{},
    density: ?Density = null,

    pub fn apply(self: DesignTokenOverrides, base: DesignTokens) DesignTokens {
        return base.withOverrides(self);
    }
};

pub const DesignTokens = struct {
    colors: ColorTokens = .{},
    typography: TypographyTokens = .{},
    spacing: SpacingTokens = .{},
    radius: RadiusTokens = .{},
    stroke: StrokeTokens = .{},
    states: StateTokens = .{},
    metrics: ControlMetricTokens = .{},
    shadow: ShadowTokens = .{},
    blur: BlurTokens = .{},
    motion: MotionTokens = .{},
    scroll: ScrollPhysics = .{},
    layer: LayerTokens = .{},
    pixel_snap: PixelSnapTokens = .{},
    controls: ControlTokens = .{},
    density: Density = .regular,
    /// Optional platform text measurement. Null (the default) keeps every
    /// layout computation on the deterministic estimator; runtimes install
    /// a provider so widget layout agrees with the fonts the platform
    /// actually draws. Not themed and not part of overrides: the runtime
    /// stamps it after theme resolution.
    text_measure: ?*const text_metrics.TextMeasureProvider = null,

    pub fn theme(options: ThemeOptions) DesignTokens {
        // The pack resolves the register (palette, control tables, and
        // any metric/type restatements); scheme-independent options
        // (motion, density) apply uniformly on top, so every pack flips
        // light/dark and honors reduce-motion exactly like the house
        // register does.
        var tokens: DesignTokens = switch (options.pack) {
            .house => .{
                .colors = ColorTokens.theme(options.color_scheme, options.contrast),
                .controls = ControlTokens.theme(options.color_scheme, options.contrast),
                // Geometry pixel snapping is part of the house register:
                // hairline borders land on whole device columns (crisp
                // 1px lines) and intrinsic boxes round to the device
                // grid. The runtime stamps the live surface scale on
                // top; apps opt out through the token override
                // (`.pixel_snap = .{ .geometry = false }`).
                .pixel_snap = .{ .geometry = true },
            },
            .geist => geist_theme.designTokens(options.color_scheme, options.contrast),
        };
        if (options.reduce_motion) tokens.motion = MotionTokens.reduced();
        tokens.density = options.density;
        return tokens;
    }

    pub fn themeWithOverrides(options: ThemeOptions, overrides: DesignTokenOverrides) DesignTokens {
        return theme(options).withOverrides(overrides);
    }

    pub fn withOverrides(self: DesignTokens, overrides: DesignTokenOverrides) DesignTokens {
        var next = self;
        next.colors = overrides.colors.apply(next.colors);
        next.typography = overrides.typography.apply(next.typography);
        next.spacing = overrides.spacing.apply(next.spacing);
        next.radius = overrides.radius.apply(next.radius);
        next.stroke = overrides.stroke.apply(next.stroke);
        next.states = overrides.states.apply(next.states);
        next.metrics = overrides.metrics.apply(next.metrics);
        next.shadow = overrides.shadow.apply(next.shadow);
        next.blur = overrides.blur.apply(next.blur);
        next.motion = overrides.motion.apply(next.motion);
        next.scroll = overrides.scroll.apply(next.scroll);
        next.layer = overrides.layer.apply(next.layer);
        next.pixel_snap = overrides.pixel_snap.apply(next.pixel_snap);
        next.controls = overrides.controls.apply(next.controls);
        if (overrides.density) |density| next.density = density;
        return next;
    }
};

fn applyFlatTokenOverrides(comptime Token: type, base: Token, overrides: anytype) Token {
    var next = base;
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".fields) |field| {
        if (@field(overrides, field.name)) |value| {
            @field(next, field.name) = value;
        }
    }
    return next;
}
