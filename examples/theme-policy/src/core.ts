import { Cmd } from "@native-sdk/core";
import type { ThemeStatePack, ThemeStateColorScheme, ThemeState } from "@native-sdk/core/events";

export type Accent = "inherit" | "pink" | "teal";
export interface Model {
  readonly pack: ThemeStatePack;
  readonly scheme: ThemeStateColorScheme;
  readonly accent: Accent;
  readonly inheritPack: boolean;
  readonly count: number;
  readonly stampedMs: number;
}
export type Msg =
  | { readonly kind: "house" } | { readonly kind: "geist" }
  | { readonly kind: "light" } | { readonly kind: "dark" } | { readonly kind: "system" }
  | { readonly kind: "pink" } | { readonly kind: "teal" } | { readonly kind: "inherit_accent" }
  | { readonly kind: "inherit_pack" } | { readonly kind: "increment" }
  | { readonly kind: "stamp" } | { readonly kind: "stamped"; readonly at: number };
export const viewUnbound = ["themeState", "stamped"] as const;
export function initialModel(): Model {
  return { pack: "house", scheme: "system", accent: "inherit", inheritPack: true, count: 0, stampedMs: -1 };
}
export function themeState(model: Model): ThemeState {
  if (model.accent === "pink") {
    if (model.inheritPack) return { colorScheme: model.scheme, accent: "#dF2670" };
    return { pack: model.pack, colorScheme: model.scheme, accent: "#dF2670" };
  }
  if (model.accent === "teal") {
    if (model.inheritPack) return { colorScheme: model.scheme, accent: "#00786F" };
    return { pack: model.pack, colorScheme: model.scheme, accent: "#00786F" };
  }
  if (model.inheritPack) return { colorScheme: model.scheme };
  return { pack: model.pack, colorScheme: model.scheme };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "house": return { ...model, pack: "house", inheritPack: false };
    case "geist": return { ...model, pack: "geist", inheritPack: false };
    case "light": return { ...model, scheme: "light" };
    case "dark": return { ...model, scheme: "dark" };
    case "system": return { ...model, scheme: "system" };
    case "pink": return { ...model, accent: "pink" };
    case "teal": return { ...model, accent: "teal" };
    case "inherit_accent": return { ...model, accent: "inherit" };
    case "inherit_pack": return { ...model, inheritPack: !model.inheritPack };
    case "increment": return { ...model, count: model.count < 1000000 ? model.count + 1 : model.count };
    case "stamp": return [model, Cmd.now("stamped")];
    case "stamped": return { ...model, stampedMs: msg.at };
  }
}
