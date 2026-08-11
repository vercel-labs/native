import { Cmd } from "@native-sdk/core";
import { feedsFail, feedsHang, feedsParse, feedsStream, feedsStreamHang } from "@native-sdk/services";
import type { ParseResult } from "./shared.ts";

export type StreamState = "data" | "closed" | "rejected";

export interface Model {
  readonly bytes: Uint8Array;
  readonly failed: boolean;
  readonly successes: number;
  readonly failures: number;
  readonly chunks: number;
}

export type Msg =
  | { readonly kind: "parse" }
  | { readonly kind: "fail" }
  | { readonly kind: "hang" }
  | { readonly kind: "replace_hang" }
  | { readonly kind: "stream" }
  | { readonly kind: "stream_hang" }
  | { readonly kind: "cancel_stream" }
  | { readonly kind: "quit" }
  | { readonly kind: "boot_parsed"; readonly result: ParseResult }
  | { readonly kind: "parsed"; readonly result: ParseResult }
  | { readonly kind: "parse_failed"; readonly error: Uint8Array }
  | { readonly kind: "stream_event"; readonly key: number; readonly state: StreamState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number };

export function initialModel(): [Model, Cmd<Msg>] {
  const model = { bytes: new Uint8Array([102, 101, 101, 100]), failed: false, successes: 0, failures: 0, chunks: 0 };
  return [model, feedsParse({ source: model.bytes, caseSensitive: false }, { key: "boot", ok: "boot_parsed", err: "parse_failed" })];
}

export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "parse":
      return [model, feedsParse({ source: model.bytes, caseSensitive: false }, { key: "parse", ok: "parsed", err: "parse_failed" })];
    case "fail":
      return [model, feedsFail({ key: "fail", ok: "parsed", err: "parse_failed" })];
    case "hang":
      return [model, feedsHang({ key: "hang", ok: "parsed", err: "parse_failed" })];
    case "replace_hang":
      return [model, Cmd.batch([
        Cmd.cancel("hang"),
        feedsParse({ source: model.bytes, caseSensitive: false }, { key: "hang", ok: "parsed", err: "parse_failed" }),
      ])];
    case "stream":
      return [model, feedsStream({ source: model.bytes, caseSensitive: false }, { key: "stream", channelKey: 77, event: "stream_event", ok: "parsed", err: "parse_failed" })];
    case "stream_hang":
      return [model, feedsStreamHang({ source: model.bytes, caseSensitive: false }, { key: "stream-hang", channelKey: 78, event: "stream_event", ok: "parsed", err: "parse_failed" })];
    case "cancel_stream":
      return [model, Cmd.cancel("stream-hang")];
    case "quit":
      return [model, Cmd.quitApp()];
    case "boot_parsed":
      return [{ ...model, bytes: msg.result.bytes, failed: false, successes: model.successes < 9007199254740991 ? model.successes + 1 : 9007199254740991 }, Cmd.none];
    case "parsed":
      return [{ ...model, bytes: msg.result.bytes, failed: false, successes: model.successes < 9007199254740991 ? model.successes + 1 : 9007199254740991 }, Cmd.none];
    case "parse_failed":
      return [{ ...model, bytes: msg.error, failed: true, failures: model.failures < 9007199254740991 ? model.failures + 1 : 9007199254740991 }, Cmd.none];
    case "stream_event":
      return [{ ...model, chunks: msg.state === "data" && model.chunks < 9007199254740991 ? model.chunks + 1 : model.chunks }, Cmd.none];
  }
}

export function commandMsg(name: string): Msg | null {
  switch (name) {
    case "service.parse": return { kind: "parse" };
    case "service.fail": return { kind: "fail" };
    case "service.hang": return { kind: "hang" };
    case "service.replace-hang": return { kind: "replace_hang" };
    case "service.stream": return { kind: "stream" };
    case "service.stream-hang": return { kind: "stream_hang" };
    case "service.cancel-stream": return { kind: "cancel_stream" };
    default: return null;
  }
}

export const viewUnbound = ["boot_parsed", "hang", "replace_hang", "stream", "stream_hang", "cancel_stream", "stream_event", "successes", "failures", "chunks"] as const;
