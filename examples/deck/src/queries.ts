// Portable readouts and playlist projection. Text stays byte-oriented,
// including the ASCII-only marquee's rotation across a wrap seam.
import { asciiBytes } from "@native-sdk/core";
import { containsIgnoreCase } from "@native-sdk/core/text";
import { albums, tracks, albumById, trackById } from "./catalog.ts";

export interface PresentationState {
  readonly now: number | null;
  readonly playing: boolean;
  readonly elapsed_ms: number;
  readonly now_duration_ms: number;
  readonly stream_failed: boolean;
  readonly media_failed: boolean;
  readonly buffering: boolean;
  readonly search_text: Uint8Array;
  readonly covers: readonly Uint8Array[];
  readonly spectrum_live: boolean;
  readonly band_levels: readonly number[];
}
export interface TrackRow {
  readonly id: number;
  readonly number: Uint8Array;
  readonly title: Uint8Array;
  readonly artist: Uint8Array;
  readonly duration: Uint8Array;
  readonly now: boolean;
  readonly playing: boolean;
  readonly first: boolean;
}
export function formatMs(ms: number): Uint8Array {
  const seconds = Math.floor(ms / 1000), minutes = Math.floor(seconds / 60), remainder = seconds % 60;
  return asciiBytes(`${minutes}:${remainder < 10 ? "0" : ""}${remainder}`);
}
function paddedId(id: number): Uint8Array { return asciiBytes(`${id < 10 ? "0" : ""}${id}`); }
export function visibleTracks(model: PresentationState): readonly TrackRow[] {
  const out: TrackRow[] = [];
  for (const track of tracks) {
    const album = albumById(track.album);
    if (album === undefined) continue;
    const query = model.search_text;
    if (query.length > 0 && !containsIgnoreCase(track.title, query) && !containsIgnoreCase(album.artist, query) && !containsIgnoreCase(album.title, query)) continue;
    out.push({ id: track.id, number: paddedId(track.id), title: track.title, artist: album.artist,
      duration: formatMs(track.duration_ms), now: model.now === track.id,
      playing: model.now === track.id && model.playing, first: out.length === 0 });
  }
  return out;
}
export function statusLabel(model: PresentationState): Uint8Array { return asciiBytes(`${visibleTracks(model).length}/${tracks.length} TRK`); }
export function channelLabel(model: PresentationState): Uint8Array { return model.now === null ? asciiBytes("TRK --") : asciiBytes(`TRK ${model.now < 10 ? "0" : ""}${model.now}`); }
export function sourceLabel(model: PresentationState): Uint8Array {
  const track = model.now === null ? undefined : trackById(model.now);
  if (track === undefined || model.now_duration_ms === 0 || track.bytes === 0) return asciiBytes("--- KBPS  --.- MB");
  const kbps = Math.floor(track.bytes * 8 / model.now_duration_ms), mb_tenths = Math.floor(track.bytes * 10 / (1024 * 1024));
  return asciiBytes(`${kbps} KBPS  ${Math.floor(mb_tenths / 10)}.${mb_tenths % 10} MB`);
}
export function marqueeText(model: PresentationState): Uint8Array {
  if (model.stream_failed) return asciiBytes("STREAM LOST");
  if (model.media_failed) return asciiBytes("NO MEDIA");
  if (model.buffering) return asciiBytes("BUFFERING");
  const track = model.now === null ? undefined : trackById(model.now);
  if (track === undefined) return asciiBytes("NO SIGNAL");
  const album = albumById(track.album);
  if (album === undefined) return track.title;
  const separator = asciiBytes(" /// "), tail = asciiBytes("  ");
  const size = track.title.length + album.artist.length + album.title.length + separator.length * 2 + tail.length;
  if (size > 192) return track.title;
  const full = new Uint8Array(size);
  let at = 0;
  const pieces: readonly Uint8Array[] = [track.title, separator, album.artist, separator, album.title, tail];
  for (const piece of pieces) for (const byte of piece) {
    full[at] = byte >= 97 && byte <= 122 ? byte - 32 : byte;
    at += 1;
  }
  if (size <= 16) {
    let end = size;
    while (end > 0 && (full[end - 1] === 32 || full[end - 1] === 47)) end -= 1;
    return full.slice(0, end);
  }
  const raw_step = Math.floor(model.elapsed_ms / 500);
  const step = raw_step > 0 && raw_step <= 4294967295 ? Math.trunc(raw_step) : 0;
  const offset = step % size;
  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) out[i] = full[(offset + i) % size] ?? 0;
  return out;
}
export function progressFraction(model: PresentationState): number {
  return model.now === null || model.now_duration_ms === 0 ? 0 : Math.max(0, Math.min(1, Math.fround(Math.fround(model.elapsed_ms) / Math.fround(model.now_duration_ms))));
}
export function elapsedLabel(model: PresentationState): Uint8Array { return model.now === null ? asciiBytes("--:--") : formatMs(model.elapsed_ms); }
export function durationLabel(model: PresentationState): Uint8Array { return model.now === null ? asciiBytes("--:--") : formatMs(model.now_duration_ms); }
export function nowCover(model: PresentationState): Uint8Array {
  const track = model.now === null ? undefined : trackById(model.now);
  return track === undefined ? asciiBytes("0") : (model.covers[track.album - 1] ?? asciiBytes("0"));
}
export function spectrumLevels(model: PresentationState): readonly number[] {
  const out: number[] = [];
  for (let band = 0; band < 32; band++) out.push(model.now === null || !model.spectrum_live ? Math.fround(band % 4 === 0 ? 0.05 : 0.02) : Math.max(0, Math.min(1, Math.fround(model.band_levels[band] ?? 0))));
  return out;
}
export function albumCount(): number { return albums.length; }
