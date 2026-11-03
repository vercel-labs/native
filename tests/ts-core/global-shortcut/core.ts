import { asciiBytes, Sub } from "@native-sdk/core";
import type { GlobalShortcutState } from "@native-sdk/core/events";

export type Arm = "a" | "b" | "bad";
export interface Entry { readonly id: Uint8Array; readonly state: GlobalShortcutState; readonly arm: Arm }
export interface Model { readonly swapped: boolean; readonly invalid: boolean; readonly log: readonly Entry[] }
export type Msg =
  | { readonly kind: "swap" }
  | { readonly kind: "invalidate" }
  | { readonly kind: "noop" }
  | { readonly kind: "a"; readonly id: Uint8Array; readonly state: GlobalShortcutState }
  | { readonly kind: "b"; readonly id: Uint8Array; readonly state: GlobalShortcutState }
  | { readonly kind: "bad"; readonly id: Uint8Array; readonly state: GlobalShortcutState };
export function initialModel(): Model { return { swapped: false, invalid: false, log: [] }; }
export function update(model: Model, msg: Msg): Model {
  if (msg.kind === "swap") return { ...model, swapped: true };
  if (msg.kind === "invalidate") return { ...model, invalid: true };
  if (msg.kind === "noop") return { ...model };
  return { ...model, log: [...model.log, { id: msg.id, state: msg.state, arm: msg.kind }] };
}
export function subscriptions(model: Model): Sub<Msg> {
  return Sub.batch([
    model.swapped ? Sub.globalShortcut("b", { key: asciiBytes("f6") }, "b") : Sub.globalShortcut("a", { key: asciiBytes("space"), option: true }, "a"),
    model.invalid ? Sub.globalShortcut("", { key: asciiBytes("f7") }, "bad") : Sub.none,
  ]);
}
