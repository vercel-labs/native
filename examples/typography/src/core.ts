import { asciiBytes } from "@native-sdk/core";
import type { ThemeDesignTokenOverrides, ThemeColor } from "@native-sdk/core/theme";

export interface Model { readonly large: boolean; readonly accent: boolean; }
export type Msg = { readonly kind: "size" } | { readonly kind: "accent" };
export function initialModel(): Model { return { large: false, accent: false }; }
export function update(model: Model, msg: Msg): Model {
  return msg.kind === "size" ? { ...model, large: !model.large } : { ...model, accent: !model.accent };
}
export function status(model: Model): Uint8Array { return asciiBytes(model.large ? "Large type" : "Regular type"); }
export function tokenOverrides(model: Model): ThemeDesignTokenOverrides {
  const accent: ThemeColor = { r: model.accent ? 0.125 : 0.3, g: 0.25, b: 0.9, a: 1 };
  return { typography: { mono_font_id: 64, display_size: model.large ? 42 : 32 },
    radius: { sm: 7, md: 10 }, colors: { accent },
    controls: { button_primary: { active_background: accent } } };
}
