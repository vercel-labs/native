import { Cmd, asciiBytes } from "@native-sdk/core";
import type { TextInputEvent } from "@native-sdk/core/text";

export interface Model {
  readonly active: number;
  readonly label: Uint8Array;
  readonly description: Uint8Array;
  readonly meta: Uint8Array;
  readonly indicator: Uint8Array;
  readonly selected: boolean;
}
export type Msg = { readonly kind: "next" } | { readonly kind: "edit"; readonly event: TextInputEvent };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ active: 0, label: asciiBytes("Draft"), description: asciiBytes("Preview"),
    meta: asciiBytes("Today"), indicator: asciiBytes("1"), selected: false }, Cmd.none];
}
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "next": return [{ ...model, active: model.active < 9007199254740991 ? model.active + 1 : model.active,
      selected: !model.selected }, Cmd.persist()];
    case "edit": return [msg.event.kind === "insert_text" ? { ...model, label: msg.event.text } : model, Cmd.none];
  }
}
