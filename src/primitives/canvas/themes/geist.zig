//! The Geist theme pack: the design register of the bundled Geist
//! typeface family, expressed entirely through the token surface — no
//! emitter knows this file exists. The register in one breath: a cool
//! neutral gray scale over pure white/black pages, monochrome primaries
//! (pure-black filled controls in light, porcelain in dark), blue spent
//! on focus rings and identity states, translucent hairline borders in
//! BOTH schemes, uniform 6px control corners with 12px surfaces, and a
//! taller 32/40/48 control ladder whose insets breathe with the rung
//! (6/10/14) while the large rung also steps its label up to 16.
//!
//! Every color below is a named step of the pack's published scales,
//! quoted as sRGB hex in the comments so the file is self-contained.
//! The scale's state semantics, used throughout: step 100 is a resting
//! wash, 200 hover, 300 active; 400-600 are borders; 700-800 solid
//! fills; 900 secondary ink; 1000 primary ink.

const std = @import("std");
const token_model = @import("../tokens.zig");
const drawing_model = @import("../drawing.zig");

const Color = drawing_model.Color;
const ColorScheme = token_model.ColorScheme;
const ColorContrast = token_model.ColorContrast;
const DesignTokens = token_model.DesignTokens;
const ColorTokens = token_model.ColorTokens;
const ControlTokens = token_model.ControlTokens;

/// The full Geist register for one scheme/contrast pair. Motion and
/// density arrive from `ThemeOptions` on top (see `DesignTokens.theme`),
/// so this function owns everything scheme-shaped: palette, control
/// tables, type scale, radii, metrics, and shadows.
pub fn designTokens(color_scheme: ColorScheme, contrast: ColorContrast) DesignTokens {
    return .{
        .colors = colorTokens(color_scheme, contrast),
        .controls = controlTokens(color_scheme, contrast),
        .typography = .{
            // The pack's type rungs: copy-14 body, label-13 labels,
            // heading-20 titles, heading-24 section headings, and the
            // 48px display numeral. Button labels are the medium face
            // at 14 (the default resolution already picks the bundled
            // medium companion).
            .body_size = 14,
            .label_size = 13,
            .title_size = 20,
            .button_size = 14,
            .heading_size = 24,
            .display_size = 48,
        },
        // One 6px corner across the control register (buttons, inputs,
        // triggers — sm and lg rungs included, stated per control table
        // below); floating surfaces sit on 12.
        .radius = .{ .sm = 6, .md = 6, .lg = 6, .xl = 12 },
        // Focus is a two-layer ring: a 2px gap in the surface color,
        // then a 2px blue ring — the stroke defaults already carry that
        // geometry, restated here so the pack is explicit about it.
        .stroke = .{ .hairline = 1, .regular = 1, .focus = 2, .focus_offset = 2 },
        // Shadows are quiet: a 2px settle under raised cards, one
        // dominant 16/24 layer under overlays. Buttons stay flat.
        .shadow = .{
            .xs = .{ .y = 1, .blur = 2, .spread = 0 },
            .sm = .{ .y = 2, .blur = 2, .spread = 0 },
            .md = .{ .y = 16, .blur = 24, .spread = -8 },
        },
        // The pack's motion register: ~150ms state changes, 200ms
        // popovers, 300ms overlays, on the standard curve.
        .motion = .{ .fast_ms = 150, .normal_ms = 200, .slow_ms = 300 },
        // The taller control ladder: 32/40/48 heights with insets that
        // breathe per rung (6/10/14). The compact rung keeps the full
        // 14px label (a genuinely roomier register than the house 28px
        // box), and the large rung steps its label up to 16.
        .metrics = .{
            .control_height_sm = 32,
            .control_height = 40,
            .control_height_lg = 48,
            .button_inset_sm = 6,
            .button_inset = 10,
            .button_inset_lg = 14,
            .button_label_sm_step = 0,
            .button_label_lg_step = 2,
            // The pack's slider geometry: an 8px rail under a narrow
            // 6x14 rectangular grab handle — the handle stands proud of
            // the rail instead of dwarfing it, the opposite proportion
            // of the house dot-on-a-line.
            .slider_track_height = 8,
            .slider_thumb_width = 6,
            .slider_thumb_height = 14,
            // The underline tab register's selected bar: a 2px rule in
            // the primary ink under the active label (see the tabs
            // entries in `controlTokens` below).
            .tabs_indicator_thickness = 2,
            // The underline register's inter-trigger gap: measured at a
            // 24px flex gap between triggers on the reference strip
            // (28px optical once each trigger's 2px horizontal padding
            // is counted). Applied only when the author leaves the
            // strip's gap at 0.
            .tabs_gap = 24,
            // The detached button-group register's inter-chip gap (see
            // the `button_group` entries in `controlTokens` below):
            // measured at 8px between chips on the reference strip.
            .button_group_gap = 8,
            // The pack's activity indicator is the segmented dial, not
            // the house arc: twelve radial pills (measured at the 20px
            // default — pill length a quarter of the box, thickness a
            // tenth, pill centers orbiting at 0.365 of the box), the
            // trail fading linearly to a 15% floor, one head-lap every
            // 1.2s. The runtime staggers one opacity loop per pill, so
            // the bright head steps around the dial while every pill
            // holds its angle — stepped occupancy, never rotation.
            .spinner_style = .segmented,
            .spinner_segment_count = 12,
            .spinner_segment_length_ratio = 0.25,
            .spinner_segment_thickness_ratio = 0.1,
            .spinner_segment_radius_ratio = 0.365,
            .spinner_tail_opacity = 0.15,
            .spinner_period_ms = 1200,
        },
    };
}

fn colorTokens(color_scheme: ColorScheme, contrast: ColorContrast) ColorTokens {
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

/// Light palette. Neutrals are the pack's gray scale; the border is a
/// translucent black hairline (8%) so dividers tint whatever they
/// cross; blue is spent only on focus and the info identity hue.
fn light() ColorTokens {
    return .{
        // Pure white page and card — elevation comes from the border
        // and shadow, never a tinted surface.
        .background = Color.rgb8(255, 255, 255),
        .surface = Color.rgb8(255, 255, 255),
        // Hover wash: gray-100 #f2f2f2.
        .surface_subtle = Color.rgb8(242, 242, 242),
        // Pressed/selected wash and input tracks: gray-200 #ebebeb.
        .surface_pressed = Color.rgb8(235, 235, 235),
        // Primary ink: gray-1000 #171717.
        .text = Color.rgb8(23, 23, 23),
        // Secondary ink: gray-900 #4d4d4d.
        .text_muted = Color.rgb8(77, 77, 77),
        // Hairline: black at 8% — the translucent border register.
        .border = Color.rgba8(0, 0, 0, 20),
        // The monochrome primary FILL: pure black #000000 filled
        // controls (button, checked toggle/checkbox, selected states)
        // with white knockout text — the register's true-black control
        // step, deliberately one step past the gray-1000 #171717 primary
        // INK above. The two blacks are distinct roles, not a mismatch:
        // ink tops out at gray-1000, fills go to the scale's extreme.
        .accent = Color.rgb8(0, 0, 0),
        .accent_text = Color.rgb8(255, 255, 255),
        // Error solid: red-800 #ea001d under white text.
        .destructive = Color.rgb8(234, 0, 29),
        .destructive_text = Color.rgb8(255, 255, 255),
        // Success solid: green-700 #28a948.
        .success = Color.rgb8(40, 169, 72),
        .success_text = Color.rgb8(255, 255, 255),
        // Warning solid: amber-800 #ff9300 — bright enough to demand
        // dark ink on top.
        .warning = Color.rgb8(255, 147, 0),
        .warning_text = Color.rgb8(10, 10, 10),
        // Info identity: blue-700 #006bff, the pack's one loud hue.
        .info = Color.rgb8(0, 107, 255),
        .info_text = Color.rgb8(255, 255, 255),
        // Focus ring: blue-700 #006bff — focus is BLUE in this pack,
        // never a neutral outline.
        .focus_ring = Color.rgb8(0, 107, 255),
        // Quiet shadows: 4% black.
        .shadow = Color.rgba8(0, 0, 0, 10),
        .scrim = Color.rgba8(0, 0, 0, 26),
        // Disabled fill: gray-100 #f2f2f2 (paired with gray-700 ink in
        // the control tables).
        .disabled = Color.rgb8(242, 242, 242),
    };
}

/// Dark palette. The page is pure black; cards stay black and separate
/// by translucent white hairlines (14%); the monochrome primary flips
/// to porcelain; the semantic hues take their bright ink steps so they
/// read on black, with near-black knockout text on the bright fills.
fn dark() ColorTokens {
    return .{
        .background = Color.rgb8(0, 0, 0),
        .surface = Color.rgb8(0, 0, 0),
        // Hover wash: gray-100 #1a1a1a.
        .surface_subtle = Color.rgb8(26, 26, 26),
        // Pressed/selected wash: gray-300 #292929 — one visible step
        // past hover on a black page.
        .surface_pressed = Color.rgb8(41, 41, 41),
        // Primary ink: gray-1000 #ededed.
        .text = Color.rgb8(237, 237, 237),
        // Secondary ink: gray-900 #a0a0a0.
        .text_muted = Color.rgb8(160, 160, 160),
        // Hairline: white at 14% — hairlines brighten what they overlap.
        .border = Color.rgba8(255, 255, 255, 36),
        // Porcelain primary with black knockout text.
        .accent = Color.rgb8(237, 237, 237),
        .accent_text = Color.rgb8(0, 0, 0),
        // Error ink: red-900 #ff565f (the filled error button states
        // its own darker fill in the control tables).
        .destructive = Color.rgb8(255, 86, 95),
        .destructive_text = Color.rgb8(255, 255, 255),
        // Success ink: green-900 #00ca50.
        .success = Color.rgb8(0, 202, 80),
        .success_text = Color.rgb8(10, 10, 10),
        // Warning: amber-800 #ff9300 in both schemes.
        .warning = Color.rgb8(255, 147, 0),
        .warning_text = Color.rgb8(10, 10, 10),
        // Info identity: blue-900 #47a8ff, the dark-scheme link/focus
        // blue.
        .info = Color.rgb8(71, 168, 255),
        .info_text = Color.rgb8(10, 10, 10),
        // Focus ring: blue-900 #47a8ff.
        .focus_ring = Color.rgb8(71, 168, 255),
        // 16% black shadow — visible against near-black surfaces only
        // as a settle, matching the quiet light register.
        .shadow = Color.rgba8(0, 0, 0, 41),
        .scrim = Color.rgba8(0, 0, 0, 26),
        // Disabled fill: gray-100 #1a1a1a.
        .disabled = Color.rgb8(26, 26, 26),
    };
}

/// High-contrast light: the standard register pushed to its extremes —
/// pure black ink, near-opaque borders, the deeper blue-800 focus ring
/// and darker solid hues so every pairing clears the loud-contrast bar.
fn highContrastLight() ColorTokens {
    return .{
        .background = Color.rgb8(255, 255, 255),
        .surface = Color.rgb8(255, 255, 255),
        .surface_subtle = Color.rgb8(242, 242, 242),
        .surface_pressed = Color.rgb8(235, 235, 235),
        .text = Color.rgb8(0, 0, 0),
        // Secondary ink darkens to gray-1000.
        .text_muted = Color.rgb8(23, 23, 23),
        .border = Color.rgba8(0, 0, 0, 180),
        .accent = Color.rgb8(0, 0, 0),
        .accent_text = Color.rgb8(255, 255, 255),
        // Deeper solid steps: red-900 #d8001b, green-900 #107d32,
        // amber-900 #aa4d00, blue-800 #0059ec — all under white text.
        .destructive = Color.rgb8(216, 0, 27),
        .destructive_text = Color.rgb8(255, 255, 255),
        .success = Color.rgb8(16, 125, 50),
        .success_text = Color.rgb8(255, 255, 255),
        .warning = Color.rgb8(170, 77, 0),
        .warning_text = Color.rgb8(255, 255, 255),
        .info = Color.rgb8(0, 89, 236),
        .info_text = Color.rgb8(255, 255, 255),
        // The ring keeps the pack's blue identity at its deep step.
        .focus_ring = Color.rgb8(0, 89, 236),
        .shadow = Color.rgba8(0, 0, 0, 96),
        // High contrast trades the glass treatment for a decisive dim.
        .scrim = Color.rgba8(0, 0, 0, 160),
        // Disabled darkens to gray-500 #c9c9c9 so the mute itself stays
        // visible.
        .disabled = Color.rgb8(201, 201, 201),
    };
}

/// High-contrast dark: pure white ink on black, near-opaque hairlines,
/// and the pale blue-500 ring so focus shouts on any dark surface.
fn highContrastDark() ColorTokens {
    return .{
        .background = Color.rgb8(0, 0, 0),
        .surface = Color.rgb8(0, 0, 0),
        .surface_subtle = Color.rgb8(26, 26, 26),
        .surface_pressed = Color.rgb8(41, 41, 41),
        .text = Color.rgb8(255, 255, 255),
        .text_muted = Color.rgb8(237, 237, 237),
        .border = Color.rgba8(255, 255, 255, 190),
        .accent = Color.rgb8(255, 255, 255),
        .accent_text = Color.rgb8(0, 0, 0),
        // The bright ink steps under black knockout text: red-500
        // #ffb1b3-class pairings, kept at the scheme's 900 inks where
        // those already clear the bar.
        .destructive = Color.rgb8(255, 86, 95),
        .destructive_text = Color.rgb8(0, 0, 0),
        .success = Color.rgb8(0, 202, 80),
        .success_text = Color.rgb8(0, 0, 0),
        .warning = Color.rgb8(255, 197, 67),
        .warning_text = Color.rgb8(0, 0, 0),
        .info = Color.rgb8(148, 204, 255),
        .info_text = Color.rgb8(0, 0, 0),
        // Pale blue-500 #94ccff ring.
        .focus_ring = Color.rgb8(148, 204, 255),
        .shadow = Color.rgba8(0, 0, 0, 180),
        .scrim = Color.rgba8(0, 0, 0, 200),
        .disabled = Color.rgb8(69, 69, 69),
    };
}

/// The pack's control tables: the treatments that are MORE than a
/// palette swap. Geist's disabled register is a color SWAP (gray-100
/// chip under gray-700 ink — the new disabled channels exist for
/// exactly this), its destructive button is a FILLED error block
/// rather than the house quiet chip, and its floating surfaces sit on
/// the 12px corner while controls hold 6.
fn controlTokens(color_scheme: ColorScheme, contrast: ColorContrast) ControlTokens {
    const colors = colorTokens(color_scheme, contrast);
    // Disabled pair: gray-100 fill under gray-700 #8f8f8f ink, the same
    // hex in both schemes (the scales cross at their quiet middle).
    const disabled_background = colors.disabled;
    const disabled_foreground = Color.rgb8(143, 143, 143);
    // The filled error button: solid red under white text, hover one
    // step deeper in light (red-900 #d8001b) and one step brighter in
    // dark (red-700 #f13242) — feedback moves TOWARD the scheme's ink.
    const destructive_rest: Color = switch (color_scheme) {
        .light => switch (contrast) {
            .standard => Color.rgb8(234, 0, 29),
            .high => Color.rgb8(216, 0, 27),
        },
        .dark => Color.rgb8(226, 22, 42),
    };
    const destructive_hover: Color = switch (color_scheme) {
        .light => Color.rgb8(216, 0, 27),
        .dark => Color.rgb8(241, 50, 66),
    };
    const surface_radius: f32 = 12;
    return .{
        .button_default = .{
            .disabled_background = disabled_background,
            .disabled_foreground = disabled_foreground,
        },
        .button_primary = .{
            .disabled_background = disabled_background,
            .disabled_foreground = disabled_foreground,
        },
        .button_secondary = .{
            .disabled_background = disabled_background,
            .disabled_foreground = disabled_foreground,
        },
        .button_outline = .{
            // The outline body is the page itself in both schemes (the
            // pack's dark register keeps opaque black bodies under its
            // translucent hairlines — no glass treatment).
            .background = colors.background,
            .disabled_background = disabled_background,
            .disabled_foreground = disabled_foreground,
        },
        .button_destructive = .{
            .background = destructive_rest,
            .hover_background = destructive_hover,
            .foreground = colors.destructive_text,
            .disabled_background = disabled_background,
            .disabled_foreground = disabled_foreground,
            .stroke_width = 0,
        },
        // The slider is the one control whose fill keeps a hue in the
        // monochrome register: rail on gray-200, range in blue-700 (the
        // same #0072f5 step in both schemes), and a paper-white
        // rectangular handle with a black hairline — translucent over
        // light pages, solid on dark ones so the white chip keeps a
        // crisp edge. The corner radius shapes the handle (the rail is
        // always a pill). Disabled is the pack's swap register: the
        // range drops to gray-500 while rail and handle keep full
        // strength.
        .slider = .{
            .background = switch (color_scheme) {
                .light => Color.rgb8(235, 235, 235),
                .dark => Color.rgb8(31, 31, 31),
            },
            .active_background = Color.rgb8(0, 114, 245),
            .foreground = Color.rgb8(255, 255, 255),
            .border = switch (color_scheme) {
                .light => Color.rgba8(0, 0, 0, 54),
                .dark => Color.rgb8(0, 0, 0),
            },
            .disabled_background = switch (color_scheme) {
                .light => Color.rgb8(201, 201, 201),
                .dark => Color.rgb8(69, 69, 69),
            },
            .radius = 1,
        },
        // The pack's button group is the DETACHED chip register — the
        // register has no attached segmented bar; its secondary tab
        // strip is the same exclusive-choice affordance, so the group
        // renders as that strip: fully-rounded chips on the control
        // corner, 8px apart (the metric above), no container chrome at
        // all. Every member rests on a translucent gray wash (light:
        // black at 8%, the same strength as the hairline; dark: white
        // at 9%) under the primary ink, and the SELECTED chip inverts —
        // its fill is the primary ink itself (gray-1000: light #171717,
        // dark #ededed) under page-color knockout text. Deliberately
        // NOT the accent: in light the register's filled-control black
        // is the scale's extreme #000000, while the selected chip stops
        // one step short at gray-1000 — the measured treatment, and the
        // reason this table states its own fills instead of falling
        // through to the primary. Hover states the rest wash explicitly
        // because the reference strip does not move on hover; selection
        // is the one signal it speaks. Disabled is the pack's swap
        // register one step darker than the button chip: gray-200 under
        // gray-900 ink.
        .button_group_style = .detached,
        .button_group = .{
            .background = switch (color_scheme) {
                .light => Color.rgba8(0, 0, 0, 20),
                .dark => Color.rgba8(255, 255, 255, 23),
            },
            .hover_background = switch (color_scheme) {
                .light => Color.rgba8(0, 0, 0, 20),
                .dark => Color.rgba8(255, 255, 255, 23),
            },
            .active_background = colors.text,
            .foreground = colors.text,
            .active_foreground = colors.background,
            .disabled_background = switch (contrast) {
                .standard => switch (color_scheme) {
                    .light => Color.rgb8(235, 235, 235),
                    .dark => Color.rgb8(31, 31, 31),
                },
                .high => colors.disabled,
            },
            .disabled_foreground = colors.text_muted,
            .stroke_width = 0,
        },
        // The pack's tabs are the UNDERLINE register, a different shape
        // from the house pill-on-muted-track: bare 14px text triggers on
        // a transparent strip, a 1px hairline closing the strip's bottom
        // edge, and a 2px bar in the primary ink under the active label,
        // overlapping the hairline where they meet. Inactive labels sit
        // in the secondary ink and preview the primary ink on hover; the
        // bar's ink itself falls back to `colors.text`, so no
        // segmented_control entry is needed. Triggers sit 24px apart
        // through the `tabs_gap` metric above.
        .tabs_indicator = .underline,
        .tabs = .{
            // The strip hairline is a SOLID quiet-border step (gray-400:
            // light #eaeaea, dark #333333), not the pack's translucent
            // hairline — a strip divider underlines content rather than
            // outlining a control, so it must stay whisper-quiet on the
            // page. High contrast keeps the palette's loud hairline
            // instead: the mute would undo the contrast the user asked
            // for.
            .border = switch (contrast) {
                .standard => switch (color_scheme) {
                    .light => Color.rgb8(234, 234, 234),
                    .dark => Color.rgb8(51, 51, 51),
                },
                .high => null,
            },
        },
        // The segmented dial draws in gray-700 #8f8f8f — the scales'
        // quiet middle, the same hex in both schemes — a deliberately
        // muted ink (activity is ambient, not a call to action). The
        // dial's SHAPE lives in the spinner metric tokens above.
        .spinner = .{
            .foreground = Color.rgb8(143, 143, 143),
        },
        // Floating and raised surfaces take the 12px corner; the
        // tooltip stays on the control corner (it is a label, not a
        // surface).
        .card = .{ .radius = surface_radius },
        .dialog = .{ .radius = surface_radius },
        .drawer = .{ .radius = surface_radius },
        .sheet = .{ .radius = surface_radius },
        .popover = .{ .radius = surface_radius },
        .menu_surface = .{ .radius = surface_radius },
        .dropdown_menu = .{ .radius = surface_radius },
        .alert = .{ .radius = surface_radius },
        .panel = .{ .radius = surface_radius },
    };
}
