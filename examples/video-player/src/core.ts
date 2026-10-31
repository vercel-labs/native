import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";
import { applyTextInputEvent, clampedInsertEvent, caretSelectionAt, type TextEditState, type TextInputEvent } from "@native-sdk/core/text";

export type Screen = "player" | "custom";
export type VideoState = "loaded" | "position" | "completed" | "failed" | "rejected";
export type PlayIcon = "pause" | "play";
export type SourceKind = "local" | "stream";
export interface Model {
  readonly screen: Screen;
  readonly source_field: TextEditState;
  readonly source_truncated: boolean;
  readonly opened: Uint8Array;
  readonly status: VideoState | null;
  readonly playing: boolean;
  readonly buffering: boolean;
  readonly position_ms: number;
  readonly duration_ms: number;
  readonly width: number;
  readonly height: number;
  readonly muted: boolean;
  readonly looping: boolean;
  readonly volume: number;
  readonly surface: number;
}
export type Msg =
  | { readonly kind: "show_player" } | { readonly kind: "show_custom" }
  | { readonly kind: "source_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "launch_source"; readonly source: Uint8Array }
  | { readonly kind: "open" } | { readonly kind: "toggle_play" }
  | { readonly kind: "back" } | { readonly kind: "forward" }
  | { readonly kind: "scrubbed"; readonly fraction: number }
  | { readonly kind: "set_volume"; readonly volume: number }
  | { readonly kind: "toggle_mute" } | { readonly kind: "toggle_loop" }
  | { readonly kind: "video_event"; readonly state: VideoState; readonly positionMs: number; readonly durationMs: number; readonly playing: boolean; readonly buffering: boolean; readonly width: number; readonly height: number }
  | { readonly kind: "video_snapshot"; readonly key: Uint8Array; readonly active: boolean; readonly surface: number; readonly playing: boolean; readonly buffering: boolean; readonly completed: boolean; readonly looping: boolean; readonly muted: boolean; readonly source: SourceKind; readonly positionMs: number; readonly durationMs: number; readonly width: number; readonly height: number; readonly volume: number };
export const envMsgs = [{ env: "NATIVE_SDK_ARG_1", msg: "launch_source" }] as const;
export const viewUnbound = ["source_field", "source_truncated", "status", "playing", "buffering", "position_ms", "duration_ms", "width", "height"] as const;
export function initialModel(): Model {
  return { screen: "player", source_field: { text: asciiBytes(""), selection: { anchor: 0, focus: 0 }, composition: null }, source_truncated: false,
    opened: asciiBytes(""), status: null, playing: false, buffering: false, position_ms: 0, duration_ms: 0, width: 0, height: 0, muted: false, looping: false, volume: 1, surface: 0x7601 };
}
function unit(value: number): number { return value >= 0 ? Math.min(value, 1) : 0; }
function customModel(model: Model): Model {
  return model.opened.length === 0 ? { ...model, status: null, playing: false, buffering: false, position_ms: 0, duration_ms: 0 } : { ...model, status: null, position_ms: 0, duration_ms: 0 };
}
export function isUrl(model: Model): boolean {
  const prefix = new Uint8Array(Math.min(model.opened.length, 8));
  for (let i = 0; i < prefix.length; i++) { const byte = model.opened[i] ?? 0; prefix[i] = byte >= 65 && byte <= 90 ? byte + 32 : byte; }
  return prefix.length >= 7 && prefix[0] === 104 && prefix[1] === 116 && prefix[2] === 116 && prefix[3] === 112 && ((prefix[4] === 58 && prefix[5] === 47 && prefix[6] === 47) || (prefix.length >= 8 && prefix[4] === 115 && prefix[5] === 58 && prefix[6] === 47 && prefix[7] === 47));
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "show_player": {
      if (model.screen === "player") return model;
      return [{ ...model, screen: "player" }, Cmd.videoStop("1")];
    }
    case "show_custom": {
      if (model.screen === "custom") return model;
      const next = customModel({ ...model, screen: "custom" });
      if (next.opened.length === 0) return [next, Cmd.videoStop("1")];
      return [next, Cmd.videoLoad("1", { surface: 0x7601, path: isUrl(next) ? asciiBytes("") : next.opened, url: isUrl(next) ? next.opened : asciiBytes(""), loop: next.looping, muted: next.muted }, { event: "video_event" })];
    }
    case "launch_source": { const source = msg.source.subarray(0, 1024); return { ...model, opened: source, source_field: { text: source, selection: caretSelectionAt(source.length, source.length), composition: null }, source_truncated: model.source_truncated }; }
    case "source_edit": {
      const next = applyTextInputEvent(model.source_field, msg.edit, 1024);
      if (next !== null) return { ...model, source_field: next, source_truncated: false };
      const clamped = clampedInsertEvent(model.source_field, msg.edit, 1024);
      const cut = clamped === null ? null : applyTextInputEvent(model.source_field, clamped, 1024);
      return { ...model, source_field: cut === null ? model.source_field : cut, source_truncated: true };
    }
    case "open": {
      const opened = { ...model, opened: model.source_field.text };
      if (opened.screen === "player") return opened;
      const next = customModel(opened);
      if (next.opened.length === 0) return [next, Cmd.videoStop("1")];
      return [next, Cmd.videoLoad("1", { surface: 0x7601, path: isUrl(next) ? asciiBytes("") : next.opened, url: isUrl(next) ? next.opened : asciiBytes(""), loop: next.looping, muted: next.muted }, { event: "video_event" })];
    }
    case "toggle_play": return [model, Cmd.videoSnapshot({ snapshot: "video_snapshot" })];
    case "video_snapshot": {
      if (msg.playing) return [{ ...model, playing: false }, Cmd.videoPause("1")];
      if (msg.completed) return [{ ...model, playing: true }, Cmd.videoRestart("1")];
      return [{ ...model, playing: true }, Cmd.videoPlay("1")];
    }
    case "back": return [model, Cmd.videoSeek("1", Math.max(0, model.position_ms - 10000))];
    case "forward": return [model, Cmd.videoSeek("1", model.position_ms + 10000)];
    case "scrubbed": {
      if (model.duration_ms <= 0) return model;
      const position = Math.trunc(unit(Math.fround(msg.fraction)) * model.duration_ms);
      return [{ ...model, position_ms: position }, Cmd.videoSeek("1", position)];
    }
    case "set_volume": { const volume = Math.fround(unit(Math.fround(msg.volume))); return [{ ...model, volume }, Cmd.videoSetVolume("1", volume)]; }
    case "toggle_mute": return [{ ...model, muted: !model.muted }, Cmd.videoSetMuted("1", !model.muted)];
    case "toggle_loop": return [{ ...model, looping: !model.looping }, Cmd.videoSetLoop("1", !model.looping)];
    case "video_event": return { ...model, status: msg.state, playing: msg.playing, buffering: msg.buffering, position_ms: msg.positionMs, duration_ms: msg.durationMs, width: msg.width > 0 ? msg.width : model.width, height: msg.height > 0 ? msg.height : model.height };
  }
}
export function source(model: Model): Uint8Array { return model.source_field.text; }
export function sourceEmpty(model: Model): boolean { return model.source_field.text.length === 0; }
export function active(model: Model): boolean { return model.status !== null && model.status !== "failed" && model.status !== "rejected"; }
export function seekable(model: Model): boolean { return active(model) && model.status !== "completed"; }
export function fraction(model: Model): number { return model.duration_ms > 0 ? Math.fround(model.position_ms / model.duration_ms) : 0; }
export function playIcon(model: Model): PlayIcon { return model.playing ? "pause" : "play"; }
export function playLabel(model: Model): Uint8Array { return asciiBytes(model.playing ? "Pause" : "Play"); }
function clock(ms: number): Uint8Array {
  const seconds = Math.floor(ms / 1000); const hours = Math.floor(seconds / 3600); const minutes = Math.floor(seconds / 60) % 60; const secs = seconds % 60;
  return utf8Bytes(hours > 0 ? `${hours}:${minutes < 10 ? "0" : ""}${minutes}:${secs < 10 ? "0" : ""}${secs}` : `${minutes}:${secs < 10 ? "0" : ""}${secs}`);
}
export function positionClock(model: Model): Uint8Array { return clock(model.position_ms); }
export function durationClock(model: Model): Uint8Array { return clock(model.duration_ms); }
export function statusText(model: Model): Uint8Array {
  if (model.opened.length === 0) return asciiBytes("no source - pass a file path or http(s) url, or type one above");
  if (model.screen === "player") return asciiBytes("house chrome drives the playback - transport state lives in the runtime, not the model");
  switch (model.status) {
    case null: return asciiBytes("loading");
    case "loaded": case "position": return utf8Bytes(`${model.width}x${model.height}${model.buffering ? " · buffering" : model.playing ? " · playing" : " · paused"}${model.looping ? " · loop" : ""}`);
    case "completed": return asciiBytes("finished");
    case "failed": return asciiBytes("playback failed - is the source a video AVFoundation can decode?");
    case "rejected": return asciiBytes("source rejected - use a file path or an http(s) url");
  }
}

export function inactive(model: Model): boolean { return !active(model); }
export function unseekable(model: Model): boolean { return !seekable(model); }
