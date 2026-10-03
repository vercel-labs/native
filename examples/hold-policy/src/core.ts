import { asciiBytes, Cmd } from "@native-sdk/core";

export interface Model {
  readonly presses: number;
  readonly holds: number;
  readonly visible: boolean;
  readonly disabled: boolean;
  readonly message: Uint8Array;
  readonly last: Uint8Array;
  readonly stampedMs: number;
}
export type Msg =
  | { readonly kind: "pressed" }
  | { readonly kind: "held"; readonly text: Uint8Array }
  | { readonly kind: "change_message" }
  | { readonly kind: "toggle_disabled" }
  | { readonly kind: "toggle_visible" }
  | { readonly kind: "stamp" }
  | { readonly kind: "stamped"; readonly at: number };
export const viewUnbound = ["stamped"] as const;
export function initialModel(): Model {
  return { presses: 0, holds: 0, visible: true, disabled: false,
    message: asciiBytes("First note"), last: asciiBytes("No hold yet"), stampedMs: -1 };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "pressed": return { ...model, presses: model.presses < 1000000 ? model.presses + 1 : model.presses };
    case "held": return { ...model, holds: model.holds < 1000000 ? model.holds + 1 : model.holds, last: msg.text };
    case "change_message": return { ...model, message: asciiBytes("Updated note") };
    case "toggle_disabled": return { ...model, disabled: !model.disabled };
    case "toggle_visible": return { ...model, visible: !model.visible };
    case "stamp": return [model, Cmd.now("stamped")];
    case "stamped": return { ...model, stampedMs: msg.at };
  }
}
