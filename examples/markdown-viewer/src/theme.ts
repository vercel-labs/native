import type { ThemeColorTokenOverrides, ThemeDesignTokenOverrides } from "@native-sdk/core/theme";
import type { ColorScheme } from "@native-sdk/core/events";
export function viewerColors(scheme: ColorScheme): ThemeColorTokenOverrides {
  if (scheme === "light") return {
    background: { r: Math.fround(250 / 255), g: Math.fround(250 / 255), b: Math.fround(249 / 255), a: Math.fround(255 / 255) },
    surface: { r: Math.fround(255 / 255), g: Math.fround(255 / 255), b: Math.fround(255 / 255), a: Math.fround(255 / 255) },
    surface_subtle: { r: Math.fround(245 / 255), g: Math.fround(245 / 255), b: Math.fround(244 / 255), a: Math.fround(255 / 255) },
    surface_pressed: { r: Math.fround(231 / 255), g: Math.fround(229 / 255), b: Math.fround(228 / 255), a: Math.fround(255 / 255) },
    text: { r: Math.fround(12 / 255), g: Math.fround(10 / 255), b: Math.fround(9 / 255), a: Math.fround(255 / 255) },
    text_muted: { r: Math.fround(121 / 255), g: Math.fround(113 / 255), b: Math.fround(107 / 255), a: Math.fround(255 / 255) },
    syntax_plain: { r: Math.fround(23 / 255), g: Math.fround(23 / 255), b: Math.fround(23 / 255), a: Math.fround(255 / 255) },
    syntax_comment: { r: Math.fround(77 / 255), g: Math.fround(77 / 255), b: Math.fround(77 / 255), a: Math.fround(255 / 255) },
    syntax_keyword: { r: Math.fround(189 / 255), g: Math.fround(40 / 255), b: Math.fround(100 / 255), a: Math.fround(255 / 255) },
    syntax_literal: { r: Math.fround(41 / 255), g: Math.fround(122 / 255), b: Math.fround(58 / 255), a: Math.fround(255 / 255) },
    syntax_function: { r: Math.fround(120 / 255), g: Math.fround(32 / 255), b: Math.fround(188 / 255), a: Math.fround(255 / 255) },
    syntax_property: { r: Math.fround(203 / 255), g: Math.fround(42 / 255), b: Math.fround(47 / 255), a: Math.fround(255 / 255) },
    syntax_constant: { r: Math.fround(0 / 255), g: Math.fround(104 / 255), b: Math.fround(214 / 255), a: Math.fround(255 / 255) },
    border: { r: Math.fround(231 / 255), g: Math.fround(229 / 255), b: Math.fround(228 / 255), a: Math.fround(255 / 255) },
    accent: { r: Math.fround(67 / 255), g: Math.fround(45 / 255), b: Math.fround(215 / 255), a: Math.fround(255 / 255) },
    accent_text: { r: Math.fround(238 / 255), g: Math.fround(242 / 255), b: Math.fround(255 / 255), a: Math.fround(255 / 255) },
    destructive: { r: Math.fround(231 / 255), g: Math.fround(0 / 255), b: Math.fround(11 / 255), a: Math.fround(255 / 255) },
    destructive_text: { r: Math.fround(250 / 255), g: Math.fround(250 / 255), b: Math.fround(250 / 255), a: Math.fround(255 / 255) },
    success: { r: Math.fround(22 / 255), g: Math.fround(163 / 255), b: Math.fround(74 / 255), a: Math.fround(255 / 255) },
    success_text: { r: Math.fround(250 / 255), g: Math.fround(250 / 255), b: Math.fround(250 / 255), a: Math.fround(255 / 255) },
    warning: { r: Math.fround(217 / 255), g: Math.fround(119 / 255), b: Math.fround(6 / 255), a: Math.fround(255 / 255) },
    warning_text: { r: Math.fround(250 / 255), g: Math.fround(250 / 255), b: Math.fround(250 / 255), a: Math.fround(255 / 255) },
    info: { r: Math.fround(124 / 255), g: Math.fround(58 / 255), b: Math.fround(237 / 255), a: 1 },
    info_text: { r: Math.fround(250 / 255), g: Math.fround(250 / 255), b: Math.fround(250 / 255), a: 1 },
    scrim: { r: 0, g: 0, b: 0, a: Math.fround(26 / 255) },
    focus_ring: { r: Math.fround(166 / 255), g: Math.fround(160 / 255), b: Math.fround(155 / 255), a: Math.fround(255 / 255) },
    shadow: { r: Math.fround(0 / 255), g: Math.fround(0 / 255), b: Math.fround(0 / 255), a: Math.fround(26 / 255) },
    disabled: { r: Math.fround(245 / 255), g: Math.fround(245 / 255), b: Math.fround(244 / 255), a: Math.fround(255 / 255) },
  };
  return {
    background: { r: Math.fround(12 / 255), g: Math.fround(10 / 255), b: Math.fround(9 / 255), a: Math.fround(255 / 255) },
    surface: { r: Math.fround(28 / 255), g: Math.fround(25 / 255), b: Math.fround(23 / 255), a: Math.fround(255 / 255) },
    surface_subtle: { r: Math.fround(41 / 255), g: Math.fround(37 / 255), b: Math.fround(36 / 255), a: Math.fround(255 / 255) },
    surface_pressed: { r: Math.fround(255 / 255), g: Math.fround(255 / 255), b: Math.fround(255 / 255), a: Math.fround(38 / 255) },
    text: { r: Math.fround(250 / 255), g: Math.fround(250 / 255), b: Math.fround(249 / 255), a: Math.fround(255 / 255) },
    text_muted: { r: Math.fround(166 / 255), g: Math.fround(160 / 255), b: Math.fround(155 / 255), a: Math.fround(255 / 255) },
    syntax_plain: { r: Math.fround(237 / 255), g: Math.fround(237 / 255), b: Math.fround(237 / 255), a: Math.fround(255 / 255) },
    syntax_comment: { r: Math.fround(161 / 255), g: Math.fround(161 / 255), b: Math.fround(161 / 255), a: Math.fround(255 / 255) },
    syntax_keyword: { r: Math.fround(247 / 255), g: Math.fround(95 / 255), b: Math.fround(143 / 255), a: Math.fround(255 / 255) },
    syntax_literal: { r: Math.fround(98 / 255), g: Math.fround(192 / 255), b: Math.fround(115 / 255), a: Math.fround(255 / 255) },
    syntax_function: { r: Math.fround(191 / 255), g: Math.fround(122 / 255), b: Math.fround(240 / 255), a: Math.fround(255 / 255) },
    syntax_property: { r: Math.fround(255 / 255), g: Math.fround(97 / 255), b: Math.fround(102 / 255), a: Math.fround(255 / 255) },
    syntax_constant: { r: Math.fround(82 / 255), g: Math.fround(168 / 255), b: Math.fround(255 / 255), a: Math.fround(255 / 255) },
    border: { r: Math.fround(255 / 255), g: Math.fround(255 / 255), b: Math.fround(255 / 255), a: Math.fround(26 / 255) },
    accent: { r: Math.fround(124 / 255), g: Math.fround(134 / 255), b: Math.fround(255 / 255), a: Math.fround(255 / 255) },
    accent_text: { r: Math.fround(12 / 255), g: Math.fround(10 / 255), b: Math.fround(9 / 255), a: Math.fround(255 / 255) },
    destructive: { r: Math.fround(255 / 255), g: Math.fround(100 / 255), b: Math.fround(103 / 255), a: Math.fround(255 / 255) },
    destructive_text: { r: Math.fround(250 / 255), g: Math.fround(250 / 255), b: Math.fround(250 / 255), a: Math.fround(255 / 255) },
    success: { r: Math.fround(34 / 255), g: Math.fround(197 / 255), b: Math.fround(94 / 255), a: Math.fround(255 / 255) },
    success_text: { r: Math.fround(9 / 255), g: Math.fround(9 / 255), b: Math.fround(11 / 255), a: Math.fround(255 / 255) },
    warning: { r: Math.fround(245 / 255), g: Math.fround(158 / 255), b: Math.fround(11 / 255), a: Math.fround(255 / 255) },
    warning_text: { r: Math.fround(9 / 255), g: Math.fround(9 / 255), b: Math.fround(11 / 255), a: Math.fround(255 / 255) },
    info: { r: Math.fround(167 / 255), g: Math.fround(139 / 255), b: Math.fround(250 / 255), a: Math.fround(255 / 255) },
    info_text: { r: Math.fround(9 / 255), g: Math.fround(9 / 255), b: Math.fround(11 / 255), a: Math.fround(255 / 255) },
    scrim: { r: 0, g: 0, b: 0, a: Math.fround(26 / 255) },
    focus_ring: { r: Math.fround(121 / 255), g: Math.fround(113 / 255), b: Math.fround(107 / 255), a: Math.fround(255 / 255) },
    shadow: { r: Math.fround(0 / 255), g: Math.fround(0 / 255), b: Math.fround(0 / 255), a: Math.fround(150 / 255) },
    disabled: { r: Math.fround(41 / 255), g: Math.fround(37 / 255), b: Math.fround(36 / 255), a: Math.fround(255 / 255) },
  };
}

// The original custom theme fixes its complete register per scheme. Keep
// its motion and control tables explicit alongside the custom palette.
export function viewerTheme(scheme: ColorScheme): ThemeDesignTokenOverrides {
  const dark = scheme === "dark", wash = Math.fround(dark ? 0.20 : 0.10);
  const r = Math.fround((dark ? 255 : 231) / 255);
  const g = Math.fround((dark ? 100 : 0) / 255);
  const b = Math.fround((dark ? 103 : 11) / 255);
  return {
    colors: viewerColors(scheme),
    motion: { fast_ms: 120, normal_ms: 180, slow_ms: 260, easing: "standard" },
    controls: {
      button_outline: dark ? { background: { r: 1, g: 1, b: 1, a: Math.fround(0.045) }, border: { r: 1, g: 1, b: 1, a: Math.fround(0.15) } } : { background: { r: 1, g: 1, b: 1, a: 1 } },
      button_destructive: {
        background: { r, g, b, a: wash },
        hover_background: { r, g, b, a: Math.fround(wash + Math.fround(0.05)) },
        active_background: { r, g, b, a: Math.fround(wash + Math.fround(0.10)) },
        foreground: { r, g, b, a: 1 }, stroke_width: 0,
      },
    },
  };
}
