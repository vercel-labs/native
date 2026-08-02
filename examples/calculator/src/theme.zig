//! calculator theme: the house register — pure neutrals, hairline
//! borders, and exactly one accent (action blue) that only appears when
//! something is live: the pending operator and the press flash on any
//! key. The focus ring stays the register's neutral mid-gray. The
//! operator column and equals are the inverted monochrome keys
//! (near-black faces on light, near-white faces on dark) — the same
//! treatment as the register's monochrome primary — so the board reads
//! black-and-white at rest.
//!
//! High-contrast requests fall back to the framework's high-contrast
//! palettes (accessibility beats brand) and reduce-motion zeroes the
//! motion tokens through the theme options. Keypad glyphs render at 18px
//! through `typography.button_size`; the pending operator fills with the
//! accent through `controls.button_primary.active_background`.

const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

/// The app-registered face behind every mono run (the display-rung
/// result line, the memory readout): the bundled Geist Mono bytes registered
/// through `Options.fonts` under an app-owned id, exercising the
/// registered-font seam end to end — this id flows from the token
/// through layout, both renderers, and (on macOS) the host's font
/// resolution, so the display inks the exact registered face even where
/// the family is not installed system-wide.
pub const display_font_id: canvas.FontId = canvas.min_registered_font_id;

/// The display rung tuned to the keypad column: 36px mono digits (0.6 em
/// pitch) keep the 12-digit entry window inside the 288pt content width.
pub const display_size: f32 = 36;

pub fn tokens(scheme: native_sdk.ColorScheme, high_contrast: bool, reduce_motion: bool) canvas.DesignTokens {
    var out = canvas.DesignTokens.theme(.{
        .color_scheme = switch (scheme) {
            .light => .light,
            .dark => .dark,
        },
        .contrast = if (high_contrast) .high else .standard,
        .reduce_motion = reduce_motion,
    });
    if (!high_contrast) {
        out.colors = switch (scheme) {
            .light => light_colors,
            .dark => dark_colors,
        };
        // The strong column: operator keys and equals invert to the
        // monochrome extreme of each scheme; the pending operator (and
        // any press) fills with the one accent.
        out.controls.button_primary = switch (scheme) {
            .light => .{
                .background = Color.rgb8(23, 23, 23),
                .hover_background = Color.rgb8(38, 38, 38),
                .active_background = light_colors.accent,
                .foreground = Color.rgb8(250, 250, 250),
                .border = Color.rgb8(23, 23, 23),
            },
            .dark => .{
                .background = Color.rgb8(229, 229, 229),
                .hover_background = Color.rgb8(250, 250, 250),
                .active_background = dark_colors.accent,
                .foreground = Color.rgb8(23, 23, 23),
                .border = Color.rgb8(229, 229, 229),
            },
        };
    }
    // Calculator keys carry 18px glyphs at every key size (button
    // labels hold one size across the control ladder).
    out.typography.button_size = 18;
    // The result line sits on the display typography rung, themed to
    // 36px: at the mono pitch (0.6 em) the 12-digit entry window needs
    // 12 x 21.6 = 259pt of the 288pt column, which the 48px default
    // would overrun. One token move recolors the whole rung.
    out.typography.display_size = display_size;
    // Mono runs resolve through the app-registered face (see
    // `display_font_id`).
    out.typography.mono_font_id = display_font_id;
    out.radius = .{ .sm = 7, .md = 10, .lg = 14, .xl = 18 };
    out.pixel_snap = .{ .geometry = true, .text = true, .scale = 1 };
    return out;
}

/// Paper white on the register's neutral scale: white keys lifted off a
/// near-white window by hairlines; action blue (the register's blue
/// primary, oklch(0.488 0.243 264.376) = #1447e6) as the only color.
/// Every neutral is a scale anchor, so the board sits on exactly the
/// same gray foundation as the default theme — only the accent differs.
pub const light_colors = canvas.ColorTokens{
    .background = Color.rgb8(250, 250, 250),
    .surface = Color.rgb8(255, 255, 255),
    .surface_subtle = Color.rgb8(245, 245, 245),
    .surface_pressed = Color.rgb8(229, 229, 229),
    .text = Color.rgb8(10, 10, 10),
    .text_muted = Color.rgb8(115, 115, 115),
    .syntax_plain = Color.rgb8(23, 23, 23),
    .syntax_comment = Color.rgb8(77, 77, 77),
    .syntax_keyword = Color.rgb8(189, 40, 100),
    .syntax_literal = Color.rgb8(41, 122, 58),
    .syntax_function = Color.rgb8(120, 32, 188),
    .syntax_property = Color.rgb8(203, 42, 47),
    .syntax_constant = Color.rgb8(0, 104, 214),
    .border = Color.rgb8(229, 229, 229),
    .accent = Color.rgb8(20, 71, 230),
    .accent_text = Color.rgb8(239, 246, 255),
    .destructive = Color.rgb8(231, 0, 11),
    .destructive_text = Color.rgb8(250, 250, 250),
    .success = Color.rgb8(22, 163, 74),
    .success_text = Color.rgb8(250, 250, 250),
    .warning = Color.rgb8(217, 119, 6),
    .warning_text = Color.rgb8(250, 250, 250),
    .focus_ring = Color.rgb8(161, 161, 161),
    .shadow = Color.rgba8(0, 0, 0, 26),
    .disabled = Color.rgb8(245, 245, 245),
};

/// True graphite on the register's dark neutrals: translucent-white
/// hairlines and pressed washes (they brighten what they overlap instead
/// of muddying it); the accent lifts to the scale's bright-blue step
/// (oklch(0.623 0.214 259.815) = #2b7fff) so the pending-operator flash
/// is unmistakable on graphite keys.
pub const dark_colors = canvas.ColorTokens{
    .background = Color.rgb8(10, 10, 10),
    .surface = Color.rgb8(23, 23, 23),
    .surface_subtle = Color.rgb8(38, 38, 38),
    .surface_pressed = Color.rgba8(255, 255, 255, 38),
    .text = Color.rgb8(250, 250, 250),
    .text_muted = Color.rgb8(161, 161, 161),
    .syntax_plain = Color.rgb8(237, 237, 237),
    .syntax_comment = Color.rgb8(161, 161, 161),
    .syntax_keyword = Color.rgb8(247, 95, 143),
    .syntax_literal = Color.rgb8(98, 192, 115),
    .syntax_function = Color.rgb8(191, 122, 240),
    .syntax_property = Color.rgb8(255, 97, 102),
    .syntax_constant = Color.rgb8(82, 168, 255),
    .border = Color.rgba8(255, 255, 255, 26),
    .accent = Color.rgb8(43, 127, 255),
    // Near-black on the bright accent (6.0:1) — the light near-white
    // pairing only reaches 3.5:1 on this step.
    .accent_text = Color.rgb8(10, 10, 10),
    .destructive = Color.rgb8(255, 100, 103),
    .destructive_text = Color.rgb8(250, 250, 250),
    .success = Color.rgb8(34, 197, 94),
    .success_text = Color.rgb8(9, 9, 11),
    .warning = Color.rgb8(245, 158, 11),
    .warning_text = Color.rgb8(9, 9, 11),
    .info = Color.rgb8(167, 139, 250),
    .info_text = Color.rgb8(9, 9, 11),
    .focus_ring = Color.rgb8(115, 115, 115),
    .shadow = Color.rgba8(0, 0, 0, 150),
    .disabled = Color.rgb8(38, 38, 38),
};
