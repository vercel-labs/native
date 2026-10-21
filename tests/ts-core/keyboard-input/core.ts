import { Cmd } from "@native-sdk/core";

export interface Model { readonly last: Uint8Array; readonly results: number; readonly failures: number; }
export type Msg =
  | { readonly kind: "paste" }
  | { readonly kind: "access" }
  | { readonly kind: "done"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly bytes: Uint8Array };
export function initialModel(): Model { return { last: new Uint8Array(0), results: 0, failures: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "paste": return [model, Cmd.keyboard.sendChord({ key: "v", modifiers: ["primary"] }, { ok: "done", err: "failed" })];
    case "access": return [model, Cmd.keyboard.accessStatus({ prompt: true }, { ok: "done", err: "failed" })];
    case "done": return { last: msg.bytes, results: model.results < 9007199254740991 ? model.results + 1 : 9007199254740991, failures: model.failures };
    case "failed": return { last: msg.bytes, results: model.results, failures: model.failures < 9007199254740991 ? model.failures + 1 : 9007199254740991 };
  }
}
export const viewUnbound = ["last", "results", "failures", "paste", "access", "done", "failed"] as const;
