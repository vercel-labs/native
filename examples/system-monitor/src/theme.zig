//! system-monitor theme: a cool teal/slate "ops room" token set layered
//! over the built-in light/dark themes — blue-grey neutrals that read like
//! brushed metal, a deep teal accent for the live data (sparklines, sort
//! selection, the resume state), and squarer radii than the consumer apps
//! (soundboard's violet studio, markdown's indigo stone) so the whole
//! thing feels like an instrument. High-contrast requests fall back to the
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

/// Cool slate paper; the teal accent is dark enough for white accent text.
pub const light_colors = canvas.ColorTokens{
    .background = Color.rgb8(241, 245, 246),
    .surface = Color.rgb8(252, 254, 254),
    .surface_subtle = Color.rgb8(229, 236, 238),
    .surface_pressed = Color.rgb8(213, 224, 227),
    .text = Color.rgb8(21, 32, 36),
    .text_muted = Color.rgb8(101, 120, 126),
    .border = Color.rgb8(215, 226, 229),
    .accent = Color.rgb8(13, 116, 121),
    .accent_text = Color.rgb8(245, 253, 253),
    .destructive = Color.rgb8(190, 48, 48),
    .destructive_text = Color.rgb8(255, 250, 250),
    .success = Color.rgb8(21, 128, 91),
    .success_text = Color.rgb8(246, 253, 250),
    .warning = Color.rgb8(174, 110, 12),
    .warning_text = Color.rgb8(255, 252, 244),
    .focus_ring = Color.rgb8(13, 116, 121),
    .shadow = Color.rgba8(23, 42, 48, 28),
    .disabled = Color.rgb8(228, 235, 237),
};

/// Deep blue-slate console; the accent brightens to signal-teal and flips
/// to near-black accent text for contrast.
pub const dark_colors = canvas.ColorTokens{
    .background = Color.rgb8(13, 18, 21),
    .surface = Color.rgb8(20, 27, 31),
    .surface_subtle = Color.rgb8(28, 38, 43),
    .surface_pressed = Color.rgb8(38, 52, 58),
    .text = Color.rgb8(226, 238, 240),
    .text_muted = Color.rgb8(128, 150, 156),
    .border = Color.rgb8(35, 48, 54),
    .accent = Color.rgb8(58, 214, 201),
    .accent_text = Color.rgb8(6, 28, 30),
    .destructive = Color.rgb8(240, 108, 108),
    .destructive_text = Color.rgb8(33, 12, 12),
    .success = Color.rgb8(92, 211, 156),
    .success_text = Color.rgb8(8, 30, 20),
    .warning = Color.rgb8(235, 178, 82),
    .warning_text = Color.rgb8(35, 24, 6),
    .focus_ring = Color.rgb8(58, 214, 201),
    .shadow = Color.rgba8(0, 0, 0, 150),
    .disabled = Color.rgb8(30, 40, 45),
};
