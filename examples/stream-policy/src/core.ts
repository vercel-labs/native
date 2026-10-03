import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model {
  readonly lines: number;
  readonly exits: number;
  readonly status: Uint8Array;
  readonly lastLine: Uint8Array;
  readonly output: Uint8Array;
  readonly exitCode: number;
  readonly httpStatus: number;
  readonly stampedMs: number;
}
export type Msg =
  | { readonly kind: "start" }
  | { readonly kind: "collect" }
  | { readonly kind: "quiet" }
  | { readonly kind: "pair" }
  | { readonly kind: "fetch" }
  | { readonly kind: "cancel" }
  | { readonly kind: "reset" }
  | { readonly kind: "stamp" }
  | { readonly kind: "line"; readonly bytes: Uint8Array }
  | { readonly kind: "exit"; readonly code: number }
  | { readonly kind: "collected"; readonly collectedCode: number; readonly output: Uint8Array }
  | { readonly kind: "fetched"; readonly status: number }
  | { readonly kind: "failed"; readonly bytes: Uint8Array }
  | { readonly kind: "stamped"; readonly at: number };
export const viewUnbound = ["line", "exit", "collected", "fetched", "failed", "stamped"] as const;
export function initialModel(): Model {
  return { lines: 0, exits: 0, status: asciiBytes("Ready to stream."), lastLine: asciiBytes("No lines yet."), output: asciiBytes("No collected output."), exitCode: -1, httpStatus: -1, stampedMs: -1 };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "start": return [{ ...model, status: asciiBytes("Process running.") }, Cmd.spawn([asciiBytes("/bin/sh"), asciiBytes("-c"), asciiBytes("printf 'First line\\n'; sleep 2; printf 'Second line\\n'")], { key: "source", line: "line", exit: "exit", err: "failed" })];
    case "collect": return [{ ...model, status: asciiBytes("Collecting output.") }, Cmd.spawn([asciiBytes("/bin/sh"), asciiBytes("-c"), asciiBytes("printf 'Collected output\\n'; exit 7")], { key: "source", collect: true, exit: "collected", err: "failed" })];
    case "quiet": return [{ ...model, status: asciiBytes("Waiting for exit.") }, Cmd.spawn([asciiBytes("/bin/sh"), asciiBytes("-c"), asciiBytes("exit 3")], { key: "source", exit: "exit", err: "failed" })];
    case "pair": return [{ ...model, status: asciiBytes("Independent processes running.") }, Cmd.batch([
      Cmd.spawn([asciiBytes("/bin/sh"), asciiBytes("-c"), asciiBytes("printf 'Independent line\\n'")], { line: "line", exit: "exit", err: "failed" }),
      Cmd.spawn([asciiBytes("/bin/sh"), asciiBytes("-c"), asciiBytes("printf 'Independent line\\n'")], { line: "line", exit: "exit", err: "failed" }),
    ])];
    case "fetch": return [{ ...model, status: asciiBytes("Response streaming.") }, Cmd.fetch({ url: asciiBytes("http://127.0.0.1:18437/lines"), timeoutMs: 10000, maxLineBytes: 8192 }, { key: "source", line: "line", ok: "fetched", err: "failed" })];
    case "cancel": return [model, Cmd.cancel("source")];
    case "reset": return initialModel();
    case "stamp": return [model, Cmd.now("stamped")];
    case "line": return { ...model, lines: model.lines < 1000000 ? model.lines + 1 : model.lines, lastLine: msg.bytes };
    case "exit": return { ...model, exits: model.exits < 1000000 ? model.exits + 1 : model.exits, exitCode: msg.code, status: asciiBytes("Process finished.") };
    case "collected": return { ...model, exits: model.exits < 1000000 ? model.exits + 1 : model.exits, exitCode: msg.collectedCode, output: msg.output, status: asciiBytes("Output collected.") };
    case "fetched": return { ...model, httpStatus: msg.status, status: asciiBytes("Response complete.") };
    case "failed": return { ...model, status: msg.bytes };
    case "stamped": return { ...model, stampedMs: msg.at };
  }
}
