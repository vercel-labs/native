import { Cmd } from "@native-sdk/core";
import { feedsExitClean, feedsFail, feedsHang, feedsParse, feedsQueuedBlocker, feedsQueuedProbe, feedsStream, feedsStreamHang, feedsStreamPark } from "@native-sdk/services";
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
  | { readonly kind: "queued_deadline" }
  | { readonly kind: "replace_hang" }
  | { readonly kind: "stream" }
  | { readonly kind: "stream_hang" }
  | { readonly kind: "stream_park" }
  | { readonly kind: "cancel_stream_park" }
  | { readonly kind: "cancel_stream" }
  | { readonly kind: "duplicate_parse" }
  | { readonly kind: "unkeyed_parse" }
  | { readonly kind: "duplicate_stream" }
  | { readonly kind: "exit_clean" }
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
    case "queued_deadline":
      return [model, Cmd.batch([
        feedsQueuedBlocker({ key: "queued-blocker", ok: "parsed", err: "parse_failed" }),
        feedsQueuedProbe({ key: "queued-probe", ok: "parsed", err: "parse_failed" }),
      ])];
    case "replace_hang":
      return [model, Cmd.batch([
        Cmd.cancel("hang"),
        feedsParse({ source: model.bytes, caseSensitive: false }, { key: "hang", ok: "parsed", err: "parse_failed" }),
      ])];
    case "stream":
      return [model, feedsStream({ source: model.bytes, caseSensitive: false }, { key: "stream", channelKey: 77, event: "stream_event", ok: "parsed", err: "parse_failed" })];
    case "stream_hang":
      return [model, feedsStreamHang({ source: model.bytes, caseSensitive: false }, { key: "stream-hang", channelKey: 78, event: "stream_event", ok: "parsed", err: "parse_failed" })];
    case "stream_park":
      return [model, feedsStreamPark({ source: model.bytes, caseSensitive: false }, { key: "stream-park", channelKey: 80, event: "stream_event", ok: "parsed", err: "parse_failed" })];
    case "cancel_stream_park":
      return [model, Cmd.cancel("stream-park")];
    case "cancel_stream":
      return [model, Cmd.cancel("stream-hang")];
    case "duplicate_parse":
      return [model, Cmd.batch([
        feedsParse({ source: model.bytes, caseSensitive: false }, { key: "duplicate", ok: "parsed", err: "parse_failed" }),
        feedsParse({ source: model.bytes, caseSensitive: false }, { key: "duplicate", ok: "parsed", err: "parse_failed" }),
      ])];
    case "unkeyed_parse":
      return [model, Cmd.batch([
        feedsParse({ source: model.bytes, caseSensitive: false }, { ok: "parsed", err: "parse_failed" }),
        feedsParse({ source: model.bytes, caseSensitive: false }, { ok: "parsed", err: "parse_failed" }),
      ])];
    case "duplicate_stream":
      return [model, Cmd.batch([
        feedsStream({ source: model.bytes, caseSensitive: false }, { key: "stream-a", channelKey: 79, event: "stream_event", ok: "parsed", err: "parse_failed" }),
        feedsStream({ source: model.bytes, caseSensitive: false }, { key: "stream-b", channelKey: 79, event: "stream_event", ok: "parsed", err: "parse_failed" }),
      ])];
    case "exit_clean":
      return [model, feedsExitClean({ key: "exit-clean", ok: "parsed", err: "parse_failed" })];
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
    case "service.queued-deadline": return { kind: "queued_deadline" };
    case "service.replace-hang": return { kind: "replace_hang" };
    case "service.stream": return { kind: "stream" };
    case "service.stream-hang": return { kind: "stream_hang" };
    case "service.stream-park": return { kind: "stream_park" };
    case "service.cancel-stream-park": return { kind: "cancel_stream_park" };
    case "service.cancel-stream": return { kind: "cancel_stream" };
    case "service.duplicate-parse": return { kind: "duplicate_parse" };
    case "service.unkeyed-parse": return { kind: "unkeyed_parse" };
    case "service.duplicate-stream": return { kind: "duplicate_stream" };
    case "service.exit-clean": return { kind: "exit_clean" };
    default: return null;
  }
}

export const viewUnbound = ["boot_parsed", "hang", "queued_deadline", "replace_hang", "stream", "stream_hang", "stream_park", "cancel_stream_park", "cancel_stream", "duplicate_parse", "unkeyed_parse", "duplicate_stream", "exit_clean", "stream_event", "successes", "failures", "chunks"] as const;
