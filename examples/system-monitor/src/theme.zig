//! system-monitor theme: a cool "ops room" token set layered over the
//! built-in light/dark themes — the register's cool (zinc) neutral
//! scale, a deep teal accent for the live data (sparklines, sort
//! selection, the resume state), and squarer radii than the consumer
//! apps (soundboard's violet studio, markdown's indigo stone) so the
//! whole thing feels like an instrument. High-contrast requests fall back to the
//! framework's high-contrast palettes (accessibility beats brand), and
//! reduce-motion zeroes the motion tokens through the theme options.

const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

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
    }
    out.radius = .{ .sm = 4, .md = 6, .lg = 9, .xl = 12 };
    out.pixel_snap = .{ .geometry = true, .text = true, .scale = 1 };
    return out;
}

/// Instrument light on the register's cool (zinc) scale — every neutral
/// a scale anchor converted from its published oklch value — with the
/// deep teal identity carried by the accent alone
/// (oklch(0.511 0.096 186.391) = #00786f).
pub const light_colors = canvas.ColorTokens{
    .background = Color.rgb8(250, 250, 250),
    .surface = Color.rgb8(255, 255, 255),
    .surface_subtle = Color.rgb8(244, 244, 245),
    .surface_pressed = Color.rgb8(228, 228, 231),
    .text = Color.rgb8(9, 9, 11),
    .text_muted = Color.rgb8(113, 113, 123),
    .syntax_plain = Color.rgb8(23, 23, 23),
    .syntax_comment = Color.rgb8(77, 77, 77),
    .syntax_keyword = Color.rgb8(189, 40, 100),
    .syntax_literal = Color.rgb8(41, 122, 58),
    .syntax_function = Color.rgb8(120, 32, 188),
    .syntax_property = Color.rgb8(203, 42, 47),
    .syntax_constant = Color.rgb8(0, 104, 214),
    .border = Color.rgb8(228, 228, 231),
    .accent = Color.rgb8(0, 120, 111),
    .accent_text = Color.rgb8(240, 253, 250),
    .destructive = Color.rgb8(231, 0, 11),
    .destructive_text = Color.rgb8(250, 250, 250),
    .success = Color.rgb8(22, 163, 74),
    .success_text = Color.rgb8(250, 250, 250),
    .warning = Color.rgb8(217, 119, 6),
    .warning_text = Color.rgb8(250, 250, 250),
    .focus_ring = Color.rgb8(159, 159, 169),
    .shadow = Color.rgba8(0, 0, 0, 26),
    .disabled = Color.rgb8(244, 244, 245),
};

/// Console dark on the register's cool (zinc) scale: translucent-white
/// hairlines and pressed washes, with the accent lifted to signal-teal
/// (oklch(0.777 0.152 181.912) = #00d5be) and flipped to near-black
/// accent text for contrast.
pub const dark_colors = canvas.ColorTokens{
    .background = Color.rgb8(9, 9, 11),
    .surface = Color.rgb8(24, 24, 27),
    .surface_subtle = Color.rgb8(39, 39, 42),
    .surface_pressed = Color.rgba8(255, 255, 255, 38),
    .text = Color.rgb8(250, 250, 250),
    .text_muted = Color.rgb8(159, 159, 169),
    .syntax_plain = Color.rgb8(237, 237, 237),
    .syntax_comment = Color.rgb8(161, 161, 161),
    .syntax_keyword = Color.rgb8(247, 95, 143),
    .syntax_literal = Color.rgb8(98, 192, 115),
    .syntax_function = Color.rgb8(191, 122, 240),
    .syntax_property = Color.rgb8(255, 97, 102),
    .syntax_constant = Color.rgb8(82, 168, 255),
    .border = Color.rgba8(255, 255, 255, 26),
    .accent = Color.rgb8(0, 213, 190),
    .accent_text = Color.rgb8(9, 9, 11),
    .destructive = Color.rgb8(255, 100, 103),
    .destructive_text = Color.rgb8(250, 250, 250),
    .success = Color.rgb8(34, 197, 94),
    .success_text = Color.rgb8(9, 9, 11),
    .warning = Color.rgb8(245, 158, 11),
    .warning_text = Color.rgb8(9, 9, 11),
    .info = Color.rgb8(167, 139, 250),
    .info_text = Color.rgb8(9, 9, 11),
    .focus_ring = Color.rgb8(113, 113, 123),
    .shadow = Color.rgba8(0, 0, 0, 150),
    .disabled = Color.rgb8(39, 39, 42),
};
