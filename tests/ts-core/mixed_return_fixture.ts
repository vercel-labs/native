// A compiled boot fetch exercises command encoding during module init.
// Updates also cover Model | [Model, Cmd<Msg>] normalization: a negative tick
// returns the bare model; an effect-bearing tick returns a spawn tuple.

import { Cmd, asciiBytes } from "@native-sdk/core";

export interface Model {
  readonly n: number;
}

export type Msg =
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "line"; readonly text: Uint8Array }
  | { readonly kind: "exited"; readonly code: number }
  | { readonly kind: "failed"; readonly reason: Uint8Array }
  | { readonly kind: "fetched"; readonly status: number; readonly body: Uint8Array };

export function initialModel(): Model | [Model, Cmd<Msg>] {
  return [
    { n: 0 },
    Cmd.fetch(
      { url: asciiBytes("https://example.test/boot"), headers: { accept: "text/plain" }, timeoutMs: 500 },
      { ok: "fetched", err: "failed" },
    ),
  ];
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
    case "fetched":
      return model;
  }
}
