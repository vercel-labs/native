import { asciiBytes } from "@native-sdk/core";
import { applyTextInputEvent, clampedInsertEvent, type TextEditState, type TextInputEvent, type TextSelection, type TextRange } from "@native-sdk/core/text";
import type { ColorScheme, AudioState } from "@native-sdk/core/events";
import { tracks, url_base } from "./catalog.ts";
import { initial, transition, type PlaybackState, type PlaybackCommand } from "./playback.ts";
import { playbackMessage } from "./effects.ts";

export interface SearchBuffer {
  readonly storage: Uint8Array;
  readonly len: number;
  readonly selection: TextSelection;
  readonly composition: TextRange | null;
  readonly truncated: boolean;
}
export interface DeckAppearance {
  readonly color_scheme: ColorScheme;
  readonly reduce_motion: boolean;
  readonly high_contrast: boolean;
}
// Keep complete backing buffers: shorter launch values and text edits retain
// the native buffer's unused tail as well as its active byte range.
export interface DeckState {
  readonly playlist_open: boolean;
  readonly appearance: DeckAppearance;
  readonly playback: PlaybackState;
  readonly url_base_buffer: Uint8Array;
  readonly url_base_len: number;
  readonly cache_dir_buffer: Uint8Array;
  readonly cache_dir_len: number;
  readonly search_buffer: SearchBuffer;
  readonly copies_done: number;
  readonly copy_failed: boolean;
  readonly covers: readonly Uint8Array[];
}
export type DeckExitReason = "exited" | "signaled" | "cancelled" | "rejected" | "spawn_failed";
export type WindowRef = "player" | "playlist";
export type DeckMsg =
  | { readonly kind: "toggle_playlist" }
  | { readonly kind: "playlist_closed" }
  | { readonly kind: "close_window"; readonly window: WindowRef }
  | { readonly kind: "minimize_window"; readonly window: WindowRef }
  | { readonly kind: "frame_clock"; readonly timestamp_ns: Uint8Array; readonly interval_ns: Uint8Array }
  | { readonly kind: "set_appearance"; readonly colorScheme: ColorScheme; readonly reduceMotion: boolean; readonly highContrast: boolean }
  | { readonly kind: "search_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "clear_search" }
  | { readonly kind: "play_track"; readonly id: number }
  | { readonly kind: "toggle_play" }
  | { readonly kind: "transport_play" }
  | { readonly kind: "transport_pause" }
  | { readonly kind: "stop" }
  | { readonly kind: "next_track" }
  | { readonly kind: "prev_track" }
  | { readonly kind: "seeked" }
  | { readonly kind: "volume_changed" }
  | { readonly kind: "audio_event"; readonly key: Uint8Array; readonly state: AudioState; readonly positionMs: Uint8Array; readonly durationMs: Uint8Array; readonly playing: boolean; readonly buffering: boolean; readonly bands: Uint8Array }
  | { readonly kind: "copy_title"; readonly id: number }
  | { readonly kind: "copied"; readonly key: Uint8Array; readonly code: number; readonly reason: DeckExitReason; readonly droppedLines: number; readonly output: Uint8Array; readonly outputTruncated: boolean; readonly stderrTail: Uint8Array; readonly stderrTruncated: boolean };
export type DeckWindowCommand =
  | { readonly kind: "close"; readonly label: Uint8Array }
  | { readonly kind: "minimize"; readonly label: Uint8Array };
export interface DeckCopyCommand { readonly key: Uint8Array; readonly title: Uint8Array; }
export interface DeckTransition {
  readonly model: DeckState;
  readonly playback_commands: readonly PlaybackCommand[];
  readonly window_command: DeckWindowCommand | null;
  readonly copy_command: DeckCopyCommand | null;
}
type DeckFailure = { readonly kind: "track_out_of_bounds" } | { readonly kind: "counter_overflow" };

export function initialState(): DeckState {
  const playback = initial();
  const buffer = new Uint8Array(256); buffer.set(url_base);
  const raw_length = url_base.length;
  const url_base_len = raw_length >= 0 && raw_length <= 256 ? Math.trunc(raw_length) : 0;
  const covers: Uint8Array[] = [];
  for (let i = 0; i < 8; i++) covers.push(asciiBytes("0"));
  return { playlist_open: false, appearance: { color_scheme: "light", reduce_motion: false, high_contrast: false },
    playback,
    url_base_buffer: buffer, url_base_len, cache_dir_buffer: new Uint8Array(512), cache_dir_len: 0,
    search_buffer: { storage: new Uint8Array(48), len: 0, selection: { anchor: 0, focus: 0 }, composition: null, truncated: false },
    copies_done: 0, copy_failed: false, covers };
}
export function playbackState(model: DeckState): PlaybackState {
  return { ...model.playback, url_base: model.url_base_buffer.subarray(0, model.url_base_len),
    cache_dir: model.cache_dir_buffer.subarray(0, model.cache_dir_len) };
}
function withPlayback(model: DeckState, playback: PlaybackState): DeckState { return { ...model, playback }; }
function plain(model: DeckState): DeckTransition { return { model, playback_commands: [], window_command: null, copy_command: null }; }
function commitSearch(buffer: SearchBuffer, next: TextEditState, truncated: boolean): SearchBuffer {
  const storage = buffer.storage.slice(); storage.set(next.text);
  const raw = next.text.length;
  const len = raw >= 0 && raw <= 48 ? Math.trunc(raw) : 0;
  return { storage, len, selection: next.selection, composition: next.composition, truncated };
}
export function applySearch(buffer: SearchBuffer, edit: TextInputEvent): SearchBuffer {
  const state: TextEditState = { text: buffer.storage.subarray(0, buffer.len), selection: buffer.selection, composition: buffer.composition };
  const next = applyTextInputEvent(state, edit, 48);
  if (next !== null) return commitSearch(buffer, next, false);
  const clamped = clampedInsertEvent(state, edit, 48);
  if (clamped === null) return { ...buffer, truncated: true };
  const recovered = applyTextInputEvent(state, clamped, 48);
  return recovered === null ? { ...buffer, truncated: true } : commitSearch(buffer, recovered, true);
}
export function setUrlBase(model: DeckState, value: Uint8Array): DeckState {
  let length = value.length;
  while (length > 0 && value[length - 1] === 47) length -= 1;
  if (length > 256) return model;
  const storage = model.url_base_buffer.slice(); storage.set(value.subarray(0, length));
  const installed_length = length >= 0 && length <= 256 ? Math.trunc(length) : 0;
  return { ...model, url_base_buffer: storage, url_base_len: installed_length, playback: { ...model.playback, url_base: storage.subarray(0, installed_length) } };
}
export function setCacheDir(model: DeckState, value: Uint8Array): DeckState {
  if (value.length > 512) return model;
  const storage = model.cache_dir_buffer.slice(); storage.set(value);
  const raw = value.length, length = raw >= 0 && raw <= 512 ? Math.trunc(raw) : 0;
  return { ...model, cache_dir_buffer: storage, cache_dir_len: length, playback: { ...model.playback, cache_dir: storage.subarray(0, length) } };
}
export function stepState(model: DeckState, msg: DeckMsg): DeckTransition {
  switch (msg.kind) {
    case "toggle_playlist": return plain({ ...model, playlist_open: !model.playlist_open });
    case "playlist_closed": return plain({ ...model, playlist_open: false });
    case "close_window": return msg.window === "playlist" ? plain({ ...model, playlist_open: false }) : { ...plain(model), window_command: { kind: "close", label: asciiBytes("main") } };
    case "minimize_window": return { ...plain(model), window_command: { kind: "minimize", label: asciiBytes(msg.window === "player" ? "main" : "playlist") } };
    case "set_appearance": return plain({ ...model, appearance: { color_scheme: msg.colorScheme, reduce_motion: msg.reduceMotion, high_contrast: msg.highContrast } });
    case "search_edit": return plain({ ...model, search_buffer: applySearch(model.search_buffer, msg.edit) });
    case "clear_search": return plain({ ...model, search_buffer: applySearch(model.search_buffer, { kind: "clear" }) });
    case "copy_title": {
      const track = tracks[msg.id - 1];
      if (track === undefined) throw { kind: "track_out_of_bounds" } as DeckFailure;
      return { ...plain(model), copy_command: { key: asciiBytes("2"), title: track.title } };
    }
    case "copied": {
      if (msg.reason !== "exited" || msg.code !== 0) return plain({ ...model, copy_failed: true });
      if (!(model.copies_done >= 0 && model.copies_done < 4294967295)) throw { kind: "counter_overflow" } as DeckFailure;
      const copies_done = model.copies_done >= 0 && model.copies_done < 4294967295 ? Math.trunc(model.copies_done) + 1 : 0;
      return plain({ ...model, copies_done, copy_failed: false });
    }
    case "play_track": {
      // Native trackById indexes the 1-based catalog. Do not silently accept
      // an out-of-catalog request, or turn a fractional identity into a track.
      if (model.playback.now !== msg.id && tracks[msg.id - 1] === undefined) throw { kind: "track_out_of_bounds" } as DeckFailure;
      const next = transition(playbackState(model), msg);
      return { ...plain(withPlayback(model, next.model)), playback_commands: next.commands };
    }
    case "audio_event": {
      const next = transition(playbackState(model), playbackMessage(msg));
      return { ...plain(withPlayback(model, next.model)), playback_commands: next.commands };
    }
    case "toggle_play": case "transport_play": case "transport_pause": case "stop": case "next_track": case "prev_track":
    case "seeked": case "volume_changed": case "frame_clock": {
      const next = transition(playbackState(model), msg);
      return { ...plain(withPlayback(model, next.model)), playback_commands: next.commands };
    }
  }
}
