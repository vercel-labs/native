import { Cmd } from "@native-sdk/core";
import type { AudioState, AudioTransport } from "@native-sdk/core/events";

export interface Source {
  readonly key: Uint8Array;
  readonly path: Uint8Array;
  readonly url: Uint8Array;
  readonly cachePath: Uint8Array;
  readonly cacheDir: Uint8Array;
  readonly expectedBytes: number;
}
export type RouteName = "first" | "second";
export interface Report {
  readonly route: RouteName;
  readonly key: Uint8Array;
  readonly state: AudioState;
  readonly positionMs: Uint8Array;
  readonly durationMs: Uint8Array;
  readonly playing: boolean;
  readonly buffering: boolean;
  readonly bands: Uint8Array;
}
export interface Model { readonly reports: readonly Report[]; }
export type Msg =
  | { readonly kind: "close_windows" }
  | { readonly kind: "minimize_windows" }
  | { readonly kind: "play_first"; readonly source: Source }
  | { readonly kind: "play_second"; readonly source: Source }
  | { readonly kind: "transport"; readonly control: AudioTransport }
  | { readonly kind: "first"; readonly key: Uint8Array; readonly state: AudioState; readonly positionMs: Uint8Array; readonly durationMs: Uint8Array; readonly playing: boolean; readonly buffering: boolean; readonly bands: Uint8Array }
  | { readonly kind: "second"; readonly key: Uint8Array; readonly state: AudioState; readonly positionMs: Uint8Array; readonly durationMs: Uint8Array; readonly playing: boolean; readonly buffering: boolean; readonly bands: Uint8Array };
export function initialModel(): Model { return { reports: [] }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "close_windows": return [model, Cmd.batch([
      Cmd.closeWindow("main"), Cmd.closeWindow("playlist"), Cmd.closeWindow("unknown"),
      Cmd.closeWindow(""), Cmd.closeWindow("音楽"),
    ])];
    case "minimize_windows": return [model, Cmd.batch([
      Cmd.minimizeWindow("main"), Cmd.minimizeWindow("playlist"), Cmd.minimizeWindow("unknown"),
      Cmd.minimizeWindow(""), Cmd.minimizeWindow("音楽"),
    ])];
    case "play_first": return [model, Cmd.audioPlayExact(msg.source.key, msg.source, { event: "first" })];
    case "play_second": return [model, Cmd.audioPlayExact(msg.source.key, msg.source, { event: "second" })];
    case "transport": return [model, Cmd.audioTransport(msg.control)];
    case "first": case "second": return { reports: [...model.reports, {
      route: msg.kind, key: msg.key, state: msg.state, positionMs: msg.positionMs, durationMs: msg.durationMs,
      playing: msg.playing, buffering: msg.buffering, bands: msg.bands,
    }] };
  }
}
