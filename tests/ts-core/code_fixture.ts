import { Cmd, asciiBytes } from "@native-sdk/core";
import type { TextInputEvent } from "@native-sdk/core/text";

export interface Model {
  readonly sourceBytes: Uint8Array;
  readonly addedSpec: Uint8Array;
  readonly removedSpec: Uint8Array;
  readonly numbered: boolean;
}
export type Msg = { readonly kind: "edit"; readonly event: TextInputEvent } | { readonly kind: "reset" };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ sourceBytes: asciiBytes("const x = 1;\n"), addedSpec: asciiBytes("1"), removedSpec: asciiBytes("2"), numbered: true }, Cmd.none];
}
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  if (msg.kind === "reset") return initialModel();
  return [msg.event.kind === "insert_text" ? { ...model, sourceBytes: msg.event.text } : model, Cmd.persist()];
}
export const viewUnbound = ["reset"] as const;
