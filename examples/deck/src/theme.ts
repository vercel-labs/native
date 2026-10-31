// Deck's one fixed hardware finish. Accessibility selects the stock light
// high-contrast register; the pixel face and machined controls belong to
// the ordinary finish alone.
import type { ThemeColor, ThemeDesignTokenOverrides } from "@native-sdk/core/theme";
import type { ThemeState } from "@native-sdk/core/events";

function rgba(r: number, g: number, b: number, a: number): ThemeColor {
  return { r: Math.fround(r / 255), g: Math.fround(g / 255), b: Math.fround(b / 255), a: Math.fround(a / 255) };
}
function rgb(r: number, g: number, b: number): ThemeColor { return rgba(r, g, b, 255); }
const enamel = rgb(231, 225, 209);
const key_face = rgb(238, 232, 217), key_hover = rgb(245, 240, 227);
const key_pressed = rgb(212, 204, 184), key_latched = rgb(205, 197, 176), key_edge = rgb(158, 150, 128);
const groove = rgb(186, 178, 155), ink = rgb(44, 40, 32), engraving = rgb(110, 102, 82);
const putty_line = rgb(169, 161, 138), disabled_wash = rgb(222, 215, 198);
export const glass = rgb(12, 16, 13), phosphor = rgb(62, 224, 138);
const glass_lifted = rgb(24, 40, 30), phosphor_pale = rgb(168, 216, 180), phosphor_dim = rgb(96, 128, 106);
const hairline = rgb(56, 68, 58), transparent = rgba(0, 0, 0, 0);
export const primary_font_id = 64;
export const pixel_grid_em = Math.fround(1000 / 38);
export const pixel_grid_half_em = Math.fround(pixel_grid_em / 2);
export const body_size = pixel_grid_half_em;

export function state(high_contrast: boolean, reduce_motion: boolean): ThemeState {
  return { pack: "house", colorScheme: "light", highContrast: high_contrast, reduceMotion: reduce_motion };
}
export function overrides(high_contrast: boolean): ThemeDesignTokenOverrides {
  if (high_contrast) return { density: "compact", pixel_snap: { geometry: true, text: true, scale: 1 } };
  return {
    density: "compact",
    pixel_snap: { geometry: true, text: true, scale: 1 },
    colors: {
      background: glass, surface: enamel, surface_subtle: glass_lifted, surface_pressed: key_pressed,
      text: ink, text_muted: engraving, syntax_plain: phosphor_pale, syntax_comment: phosphor_dim,
      syntax_keyword: rgb(247, 95, 143), syntax_literal: rgb(98, 192, 115), syntax_function: rgb(191, 122, 240),
      syntax_property: rgb(255, 97, 102), syntax_constant: rgb(82, 168, 255), border: putty_line,
      accent: phosphor, accent_text: rgb(7, 21, 13), destructive: rgb(196, 60, 46), destructive_text: rgb(250, 246, 236),
      success: phosphor_pale, success_text: rgb(7, 21, 13), warning: rgb(236, 178, 74), warning_text: rgb(43, 30, 7),
      info: phosphor_dim, info_text: rgb(7, 21, 13), focus_ring: phosphor, shadow: transparent,
      scrim: rgba(0, 0, 0, 26), disabled: disabled_wash,
    },
    radius: { sm: 2, md: 3, lg: 4, xl: 5 },
    typography: {
      font_id: primary_font_id, mono_font_id: primary_font_id,
      body_size, label_size: pixel_grid_half_em, title_size: pixel_grid_em, button_size: pixel_grid_half_em,
    },
    metrics: { slider_track_height: 4, slider_thumb_width: 10, slider_thumb_height: 16 },
    controls: {
      button_outline: { background: key_face, hover_background: key_hover, active_background: key_pressed, foreground: ink, border: key_edge },
      button_ghost: { hover_background: key_hover, active_background: key_pressed, foreground: ink },
      button_primary: { background: key_face, hover_background: key_hover, active_background: key_pressed, foreground: ink, border: key_edge },
      toggle_button: { background: key_face, hover_background: key_hover, active_background: key_latched, foreground: ink, border: key_edge },
      search_field: { background: glass, foreground: phosphor_pale, border: hairline },
      slider: { background: groove, active_background: phosphor, foreground: key_face, border: ink, radius: 1 },
      scrollbar: { background: transparent, foreground: rgba(94, 125, 104, 110) },
      panel: { background: transparent, border: transparent },
    },
  };
}
