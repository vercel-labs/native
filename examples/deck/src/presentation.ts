import { asciiBytes } from "@native-sdk/core";
import type { DeckState } from "./state.ts";
import { trackById } from "./catalog.ts";
import * as queries from "./queries.ts";

export type GlassColor = "warning" | "info" | "accent";
export function queryState(model: DeckState): queries.PresentationState {
  return { now: model.playback.now, playing: model.playback.playing,
    elapsed_ms: model.playback.elapsed_ms, now_duration_ms: model.playback.now_duration_ms,
    stream_failed: model.playback.stream_failed, media_failed: model.playback.media_failed,
    buffering: model.playback.buffering, search_text: model.search_buffer.storage.subarray(0, model.search_buffer.len),
    covers: model.covers, spectrum_live: model.playback.spectrum_live, band_levels: model.playback.band_levels };
}
export function failure(model: DeckState): boolean { return model.playback.media_failed || model.playback.stream_failed; }
export function marqueeColor(model: DeckState): GlassColor { return failure(model) ? "warning" : model.playback.now === null ? "info" : "accent"; }
export function channelText(model: DeckState): Uint8Array {
  if (failure(model)) return asciiBytes(model.playback.stream_failed ? "CHECK THE CONNECTION AND RETRY" : "RUN TOOLS/PREPARE-EXAMPLE-MUSIC.SH");
  const state = queryState(model);
  const parts = [queries.channelLabel(state), asciiBytes("  "), queries.elapsedLabel(state), asciiBytes(" / "), queries.durationLabel(state)];
  let size = 0; for (const part of parts) size += part.length;
  const out = new Uint8Array(size); let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}
export function hasCover(model: DeckState): boolean {
  const id = queries.nowCover(queryState(model)); return id.length !== 1 || id[0] !== 48;
}
export function loadedTitle(model: DeckState): Uint8Array {
  const track = model.playback.now === null ? undefined : trackById(model.playback.now);
  if (track === undefined) return asciiBytes("--");
  const out = track.title.slice();
  for (let i = 0; i < out.length; i++) { const byte = out[i] ?? 0; if (byte >= 97 && byte <= 122) out[i] = byte - 32; }
  return out;
}
