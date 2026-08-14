// Exact regression for a generated facade normalizing
// Model | [Model, Cmd<Msg>] with Array.isArray. A negative tick returns the
// bare model; an effect-bearing tick returns a spawn tuple. The ABI battery
// commits and snapshots after both dispatches.

import { Cmd, asciiBytes } from "@native-sdk/core";

export interface Model {
  readonly n: number;
}

export type Msg =
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "line"; readonly text: Uint8Array }
  | { readonly kind: "exited"; readonly code: number }
  | { readonly kind: "failed"; readonly reason: Uint8Array };

export function initialModel(): Model {
  return { n: 0 };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "tick":
      if (msg.at < 0) return model;
      return [model, Cmd.spawn([asciiBytes("/bin/echo"), asciiBytes("hello")], {
        key: "p",
        line: "line",
        exit: "exited",
        err: "failed",
      })];
    case "exited":
      if (msg.code < 0) return model;
      return { ...model, n: model.n < 9007199254740991 ? model.n + 1 : model.n };
    case "line":
    case "failed":
      return model;
  }
}
