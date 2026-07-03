//! soundboard theme: a custom "studio" token set layered over the built-in
//! light/dark themes — warm neutral surfaces, an electric violet accent,
//! and slightly softer radii. High-contrast requests fall back to the
//! framework's high-contrast palettes (accessibility beats brand), and
//! reduce-motion zeroes the motion tokens through the theme options.

const zero_native = @import("zero-native");

const canvas = zero_native.canvas;
const Color = canvas.Color;

pub fn tokens(scheme: zero_native.ColorScheme, high_contrast: bool, reduce_motion: bool) canvas.DesignTokens {
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
    out.radius = .{ .sm = 6, .md = 9, .lg = 12, .xl = 16 };
    out.pixel_snap = .{ .geometry = true, .text = true, .scale = 1 };
    return out;
}

/// Warm paper neutrals; violet accent tuned for white accent text.
pub const light_colors = canvas.ColorTokens{
    .background = Color.rgb8(247, 245, 242),
    .surface = Color.rgb8(255, 255, 255),
    .surface_subtle = Color.rgb8(238, 235, 230),
    .surface_pressed = Color.rgb8(226, 222, 214),
    .text = Color.rgb8(33, 30, 27),
    .text_muted = Color.rgb8(135, 128, 119),
    .border = Color.rgb8(228, 224, 216),
    .accent = Color.rgb8(105, 86, 224),
    .accent_text = Color.rgb8(252, 251, 255),
    .destructive = Color.rgb8(206, 44, 49),
    .destructive_text = Color.rgb8(255, 251, 251),
    .success = Color.rgb8(22, 137, 80),
    .success_text = Color.rgb8(247, 253, 250),
    .warning = Color.rgb8(184, 119, 8),
    .warning_text = Color.rgb8(255, 252, 245),
    .focus_ring = Color.rgb8(105, 86, 224),
    .shadow = Color.rgba8(41, 32, 24, 26),
    .disabled = Color.rgb8(236, 233, 228),
};

/// Deep charcoal with a violet cast; the accent brightens and flips to
/// near-black accent text for contrast.
pub const dark_colors = canvas.ColorTokens{
    .background = Color.rgb8(20, 19, 23),
    .surface = Color.rgb8(29, 28, 34),
    .surface_subtle = Color.rgb8(39, 37, 46),
    .surface_pressed = Color.rgb8(54, 51, 63),
    .text = Color.rgb8(242, 240, 246),
    .text_muted = Color.rgb8(157, 152, 168),
    .border = Color.rgb8(45, 43, 53),
    .accent = Color.rgb8(148, 132, 245),
    .accent_text = Color.rgb8(22, 18, 34),
    .destructive = Color.rgb8(244, 106, 106),
    .destructive_text = Color.rgb8(31, 14, 14),
    .success = Color.rgb8(94, 210, 141),
    .success_text = Color.rgb8(10, 28, 18),
    .warning = Color.rgb8(240, 177, 62),
    .warning_text = Color.rgb8(33, 23, 5),
    .focus_ring = Color.rgb8(171, 158, 248),
    .shadow = Color.rgba8(0, 0, 0, 140),
    .disabled = Color.rgb8(41, 39, 48),
};
