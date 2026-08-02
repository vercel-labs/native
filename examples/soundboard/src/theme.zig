//! soundboard theme: the Geist pack with the accent moved to the pack's
//! pink scale. The pack resolves the whole register (palette, control
//! tables, type scale, metrics) per scheme and contrast; the app layers
//! ONE brand decision on top through `DesignTokenOverrides` — it never
//! forks the pack. High-contrast requests skip the override and take the
//! pack's high-contrast register untouched (accessibility beats brand),
//! and reduce-motion zeroes the motion tokens through the theme options.

const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

/// Pink 800, the pink scale's solid-fill step. The scale is stated per
/// appearance, but the solid 700/800 steps cross at the same sRGB value
/// in both — only the quiet low steps flip — so one constant serves
/// light and dark alike: hsl(336, 74%, 51%) = #df2670.
const pink_800 = Color.rgb8(223, 38, 112);

/// The ink on the pink fill: the pack pairs every solid 700/800 fill
/// with white knockout text, and white clears the 4.5:1 text bar on
/// this pink (~4.5:1) — the honest readable ink in both schemes, since
/// the fill itself is the same hex under both.
const pink_ink = Color.rgb8(255, 255, 255);

/// The app's one brand statement, layered over whichever scheme/contrast
/// register the pack resolves. Three slots carry the accent identity:
///
/// - `colors.accent`/`accent_text`: the filled-primary pair — the
///   selected track row's inverted fill, the header switcher's active
///   segment, "Playing" badges, the loaded row's title ink, and every
///   control fill that derives from the accent channel (checkbox,
///   switch, progress).
/// - `colors.focus_ring`: the pack spends its identity hue on focus;
///   with the identity moved to pink, the ring follows so focus and
///   accent chrome read as one system (pink on the page clears the 3:1
///   non-text bar in both schemes). The ring is stated PER SCHEME: the
///   accent itself in light, `canvas.accentFocusRing`'s desaturated,
///   contrast-floored step in dark — full-chroma pink glares neon
///   against the dark palette, and the derivation is the same one the
///   manifest `theme_accent` channel applies, so both authoring tiers
///   land the identical ring.
/// - `controls.slider.active_background`: the pack's slider table states
///   its own hue for the filled range rather than deriving from the
///   accent channel, so the seek scrubber needs the same move stated
///   once more or it would keep the pack's stock hue.
fn accentOverridesFor(color_scheme: canvas.ColorScheme) canvas.DesignTokenOverrides {
    return .{
        .colors = .{
            .accent = pink_800,
            .accent_text = pink_ink,
            .focus_ring = canvas.accentFocusRing(pink_800, color_scheme),
        },
        .controls = .{
            .slider = .{ .active_background = pink_800 },
        },
    };
}

pub fn tokens(scheme: native_sdk.ColorScheme, high_contrast: bool, reduce_motion: bool) canvas.DesignTokens {
    const options = canvas.ThemeOptions{
        .pack = .geist,
        .color_scheme = switch (scheme) {
            .light => .light,
            .dark => .dark,
        },
        .contrast = if (high_contrast) .high else .standard,
        .reduce_motion = reduce_motion,
    };
    // High contrast takes the pack's own loud register with no brand
    // layer: white on the pink fill sits at ~4.5:1, well under the
    // loud-contrast bar, so the accent honestly bows out.
    if (high_contrast) return canvas.DesignTokens.theme(options);
    return canvas.DesignTokens.themeWithOverrides(options, accentOverridesFor(options.color_scheme));
}

/// The resolved standard-contrast palettes, exported for the suite's
/// theme assertions: the pack's scheme register with the accent
/// override already applied — exactly what `tokens` hands the runtime.
pub const light_colors = tokens(.light, false, false).colors;
pub const dark_colors = tokens(.dark, false, false).colors;
