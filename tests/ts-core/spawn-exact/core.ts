import { Cmd } from "@native-sdk/core";

export type SpawnReason = "exited" | "signaled" | "cancelled" | "rejected" | "spawn_failed";
export type Route = "first" | "second";
export type ReportEvent = "line" | "exit";
export interface Request {
  readonly key: Uint8Array;
  readonly argv: readonly Uint8Array[];
  readonly stdin: Uint8Array;
  readonly collect: boolean;
  readonly listen: boolean;
}
export interface Report {
  readonly event: ReportEvent;
  readonly route: Route;
  readonly key: Uint8Array;
  readonly line: Uint8Array;
  readonly truncated: boolean;
  readonly droppedBefore: number;
  readonly code: number;
  readonly reason: SpawnReason;
  readonly droppedLines: number;
  readonly output: Uint8Array;
  readonly outputTruncated: boolean;
  readonly stderrTail: Uint8Array;
  readonly stderrTruncated: boolean;
}
export interface Model { readonly reports: readonly Report[]; }
export type Msg =
  | { readonly kind: "spawn_first"; readonly request: Request }
  | { readonly kind: "spawn_second"; readonly request: Request }
  | { readonly kind: "cancel"; readonly key: Uint8Array }
  | { readonly kind: "first_line"; readonly key: Uint8Array; readonly line: Uint8Array; readonly truncated: boolean; readonly droppedBefore: number }
  | { readonly kind: "second_line"; readonly key: Uint8Array; readonly line: Uint8Array; readonly truncated: boolean; readonly droppedBefore: number }
  | { readonly kind: "first_exit"; readonly key: Uint8Array; readonly code: number; readonly reason: SpawnReason; readonly droppedLines: number; readonly output: Uint8Array; readonly outputTruncated: boolean; readonly stderrTail: Uint8Array; readonly stderrTruncated: boolean }
  | { readonly kind: "second_exit"; readonly key: Uint8Array; readonly code: number; readonly reason: SpawnReason; readonly droppedLines: number; readonly output: Uint8Array; readonly outputTruncated: boolean; readonly stderrTail: Uint8Array; readonly stderrTruncated: boolean };
export function initialModel(): Model { return { reports: [] }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "spawn_first":
      if (msg.request.listen) return [model, Cmd.spawnEventsExact(msg.request.key, msg.request.argv, { stdin: msg.request.stdin, collect: msg.request.collect, line: "first_line", exit: "first_exit" })];
      return [model, Cmd.spawnEventsExact(msg.request.key, msg.request.argv, { stdin: msg.request.stdin, collect: msg.request.collect, exit: "first_exit" })];
    case "spawn_second":
      if (msg.request.listen) return [model, Cmd.spawnEventsExact(msg.request.key, msg.request.argv, { stdin: msg.request.stdin, collect: msg.request.collect, line: "second_line", exit: "second_exit" })];
      return [model, Cmd.spawnEventsExact(msg.request.key, msg.request.argv, { stdin: msg.request.stdin, collect: msg.request.collect, exit: "second_exit" })];
    case "cancel": return [model, Cmd.cancelExact(msg.key)];
    case "first_line": case "second_line": return { reports: [...model.reports, {
      event: "line", route: msg.kind === "first_line" ? "first" : "second", key: msg.key,
      line: msg.line, truncated: msg.truncated, droppedBefore: msg.droppedBefore,
      code: 0, reason: "exited", droppedLines: 0, output: new Uint8Array(0),
      outputTruncated: false, stderrTail: new Uint8Array(0), stderrTruncated: false,
    }] };
    case "first_exit": case "second_exit": return { reports: [...model.reports, {
      event: "exit", route: msg.kind === "first_exit" ? "first" : "second", key: msg.key,
      line: new Uint8Array(0), truncated: false, droppedBefore: 0,
      code: msg.code, reason: msg.reason, droppedLines: msg.droppedLines, output: msg.output,
      outputTruncated: msg.outputTruncated, stderrTail: msg.stderrTail, stderrTruncated: msg.stderrTruncated,
    }] };
  }
}
