import { Cmd } from "@native-sdk/core";

export interface Model {
  readonly bytes: Uint8Array;
  readonly failed: boolean;
  readonly successes: number;
  readonly failures: number;
}

export type Msg =
  | { readonly kind: "parse" }
  | { readonly kind: "fail" }
  | { readonly kind: "hang" }
  | { readonly kind: "replace_hang" }
  | { readonly kind: "quit" }
  | { readonly kind: "boot_parsed"; readonly bytes: Uint8Array }
  | { readonly kind: "parsed"; readonly bytes: Uint8Array }
  | { readonly kind: "parse_failed"; readonly error: Uint8Array };

export function initialModel(): [Model, Cmd<Msg>] {
  const model = { bytes: new Uint8Array([102, 101, 101, 100]), failed: false, successes: 0, failures: 0 };
  return [model, Cmd.request("feeds.parse", model.bytes, { key: "boot", ok: "boot_parsed", err: "parse_failed" })];
}

export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "parse":
      return [model, Cmd.request("feeds.parse", model.bytes, { key: "parse", ok: "parsed", err: "parse_failed" })];
    case "fail":
      return [model, Cmd.request("feeds.fail", new Uint8Array(0), { key: "fail", ok: "parsed", err: "parse_failed" })];
    case "hang":
      return [model, Cmd.request("feeds.hang", new Uint8Array(0), { key: "hang", ok: "parsed", err: "parse_failed" })];
    case "replace_hang":
      return [model, Cmd.batch([
        Cmd.cancel("hang"),
        Cmd.request("feeds.parse", model.bytes, { key: "hang", ok: "parsed", err: "parse_failed" }),
      ])];
    case "quit":
      return [model, Cmd.quitApp()];
    case "boot_parsed":
      return [{ ...model, bytes: msg.bytes, failed: false, successes: model.successes < 9007199254740991 ? model.successes + 1 : 9007199254740991 }, Cmd.none];
    case "parsed":
      return [{ ...model, bytes: msg.bytes, failed: false, successes: model.successes < 9007199254740991 ? model.successes + 1 : 9007199254740991 }, Cmd.none];
    case "parse_failed":
      return [{ ...model, bytes: msg.error, failed: true, failures: model.failures < 9007199254740991 ? model.failures + 1 : 9007199254740991 }, Cmd.none];
  }
}

export const viewUnbound = ["boot_parsed", "hang", "replace_hang", "successes", "failures"] as const;
