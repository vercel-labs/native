//! calculator theme: the house register — pure neutrals, hairline
//! borders, and exactly one accent (action blue) that only appears when
//! something is live: the pending operator, the press flash on any key,
//! the focus ring. The operator column and equals are the inverted
//! monochrome keys (near-black faces on light, near-white faces on
//! dark), so the board reads black-and-white at rest.
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
                .hover_background = Color.rgb8(56, 56, 56),
                .active_background = light_colors.accent,
                .foreground = Color.rgb8(255, 255, 255),
                .border = Color.rgb8(23, 23, 23),
            },
            .dark => .{
                .background = Color.rgb8(237, 237, 237),
                .hover_background = Color.rgb8(255, 255, 255),
                .active_background = dark_colors.accent,
                .foreground = Color.rgb8(10, 10, 10),
                .border = Color.rgb8(237, 237, 237),
            },
        };
    }
    // Calculator keys carry 18px glyphs; the sm theme button derives 17.
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

/// Paper white: white keys lifted off a near-white window by hairlines;
/// action blue as the only color.
pub const light_colors = canvas.ColorTokens{
    .background = Color.rgb8(250, 250, 250),
    .surface = Color.rgb8(255, 255, 255),
    .surface_subtle = Color.rgb8(240, 240, 240),
    .surface_pressed = Color.rgb8(229, 229, 229),
    .text = Color.rgb8(23, 23, 23),
    .text_muted = Color.rgb8(102, 102, 102),
    .border = Color.rgb8(232, 232, 232),
    .accent = Color.rgb8(0, 112, 243),
    .accent_text = Color.rgb8(255, 255, 255),
    .destructive = Color.rgb8(217, 48, 55),
    .destructive_text = Color.rgb8(255, 255, 255),
    .success = Color.rgb8(23, 125, 66),
    .success_text = Color.rgb8(255, 255, 255),
    .warning = Color.rgb8(170, 90, 0),
    .warning_text = Color.rgb8(255, 255, 255),
    .focus_ring = Color.rgb8(0, 112, 243),
    .shadow = Color.rgba8(0, 0, 0, 24),
    .disabled = Color.rgb8(244, 244, 244),
};

/// True graphite: near-black window, graphite keys; the accent lightens
/// one step so dark glyphs sit on it.
pub const dark_colors = canvas.ColorTokens{
    .background = Color.rgb8(10, 10, 10),
    .surface = Color.rgb8(23, 23, 23),
    .surface_subtle = Color.rgb8(38, 38, 38),
    .surface_pressed = Color.rgb8(51, 51, 51),
    .text = Color.rgb8(237, 237, 237),
    .text_muted = Color.rgb8(161, 161, 161),
    .border = Color.rgb8(46, 46, 46),
    .accent = Color.rgb8(50, 145, 255),
    .accent_text = Color.rgb8(10, 10, 10),
    .destructive = Color.rgb8(255, 97, 102),
    .destructive_text = Color.rgb8(10, 10, 10),
    .success = Color.rgb8(69, 222, 143),
    .success_text = Color.rgb8(10, 10, 10),
    .warning = Color.rgb8(255, 176, 32),
    .warning_text = Color.rgb8(10, 10, 10),
    .focus_ring = Color.rgb8(50, 145, 255),
    .shadow = Color.rgba8(0, 0, 0, 150),
    .disabled = Color.rgb8(32, 32, 32),
};
