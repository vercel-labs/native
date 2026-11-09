import { asciiBytes } from "@native-sdk/core";
import type { AudioState } from "@native-sdk/core/events";
import { tracks, trackById, url_base } from "./catalog.ts";
import * as clock from "./clock.ts";

export interface PlaybackState {
  readonly now: number | null;
  readonly playing: boolean;
  readonly elapsed_ms: number;
  readonly frame_ns: Uint8Array;
  readonly now_duration_ms: number;
  readonly platform_duration_ms: number;
  readonly media_failed: boolean;
  readonly stream_failed: boolean;
  readonly buffering: boolean;
  readonly seek_fraction: number;
  readonly volume_fraction: number;
  readonly url_base: Uint8Array;
  readonly cache_dir: Uint8Array;
  readonly spectrum_live: boolean;
  readonly band_targets: readonly number[];
  readonly band_levels: readonly number[];
}
export type PlaybackMsg =
  | { readonly kind: "play_track"; readonly id: number }
  | { readonly kind: "toggle_play" }
  | { readonly kind: "transport_play" }
  | { readonly kind: "transport_pause" }
  | { readonly kind: "stop" }
  | { readonly kind: "next_track" }
  | { readonly kind: "prev_track" }
  | { readonly kind: "seeked" }
  | { readonly kind: "volume_changed" }
  | { readonly kind: "frame_clock"; readonly timestamp_ns: Uint8Array; readonly interval_ns: Uint8Array }
  | { readonly kind: "audio_event"; readonly key: Uint8Array; readonly state: AudioState; readonly position_ms: Uint8Array; readonly duration_ms: Uint8Array; readonly playing: boolean; readonly buffering: boolean; readonly bands: Uint8Array };
export type PlaybackCommand =
  | { readonly kind: "play"; readonly key: Uint8Array; readonly path: Uint8Array; readonly url: Uint8Array; readonly cache_dir: Uint8Array; readonly expected_bytes: number }
  | { readonly kind: "pause" }
  | { readonly kind: "audio_resume" }
  | { readonly kind: "seek"; readonly position_ms: number }
  | { readonly kind: "volume"; readonly value: number };
export interface PlaybackTransition { readonly model: PlaybackState; readonly commands: readonly PlaybackCommand[]; }

function zeros(): readonly number[] { const out: number[] = []; for (let i = 0; i < 32; i++) out.push(0); return out; }
export function initial(): PlaybackState {
  return { now: null, playing: false, elapsed_ms: 0, frame_ns: clock.zero(), now_duration_ms: 0, platform_duration_ms: 0,
    media_failed: false, stream_failed: false, buffering: false, seek_fraction: 0, volume_fraction: Math.fround(0.8),
    url_base, cache_dir: asciiBytes(""), spectrum_live: false, band_targets: zeros(), band_levels: zeros() };
}
function resetSpectrum(model: PlaybackState): PlaybackState { return { ...model, spectrum_live: false, band_targets: zeros(), band_levels: zeros() }; }
function plain(model: PlaybackState): PlaybackTransition { return { model, commands: [] }; }
function join(parts: readonly Uint8Array[]): Uint8Array {
  let size = 0; for (const part of parts) size += part.length;
  const out = new Uint8Array(size); let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}
function start(model: PlaybackState, id: number): PlaybackTransition {
  const track_id = id > 0 && id <= 255 ? Math.trunc(id) : 0;
  const track = trackById(track_id);
  if (track === undefined) return plain(model);
  const next: PlaybackState = { ...resetSpectrum(model), now: track_id, playing: true, elapsed_ms: 0, now_duration_ms: track.duration_ms,
    platform_duration_ms: 0, media_failed: false, stream_failed: false, buffering: false };
  const url = model.url_base.length === 0 ? asciiBytes("") : join([model.url_base, asciiBytes("/"), track.file]);
  const size = track.bytes;
  const expected_bytes = size > 0 && size <= 9007199254740991 ? Math.trunc(size) : 0;
  return { model: next, commands: [
    { kind: "play", key: asciiBytes(`${track_id}`), path: track.path, url, cache_dir: url.length === 0 ? asciiBytes("") : model.cache_dir, expected_bytes },
    { kind: "volume", value: Math.max(0, Math.min(1, model.volume_fraction)) },
  ] };
}
function setPlaying(model: PlaybackState, playing: boolean): PlaybackTransition {
  return { model: { ...model, playing }, commands: playing ? [{ kind: "audio_resume" }] : [{ kind: "pause" }] };
}
function advance(model: PlaybackState): PlaybackTransition { return model.now === null ? plain(model) : start(model, model.now % tracks.length + 1); }
function clampMs(value: Uint8Array): number {
  const raw = clock.number(clock.parse(value));
  return raw > 0 && raw <= 4294967295 ? Math.trunc(raw) : raw > 4294967295 ? 4294967295 : 0;
}
function duration(model: PlaybackState, value: Uint8Array): PlaybackState {
  const raw = clampMs(value);
  const reported = raw > 0 && raw <= 4294967295 ? Math.trunc(raw) : 0;
  return reported === 0 ? model : { ...model, platform_duration_ms: reported, now_duration_ms: model.now_duration_ms === 0 ? reported : model.now_duration_ms };
}
interface PositionOverflow { readonly kind: "position_overflow"; }
function frame(model: PlaybackState, timestamp: Uint8Array, period: Uint8Array): PlaybackTransition {
  const timestamp_ns = clock.parse(timestamp), interval_ns = clock.parse(period);
  const next = { ...model, frame_ns: timestamp_ns };
  if (!model.playing || model.now === null || model.buffering) return plain(next);
  const interval = clock.isZero(interval_ns) ? clock.parse(asciiBytes("16666666")) : interval_ns;
  let delta = interval;
  if (!clock.isZero(model.frame_ns) && clock.before(model.frame_ns, timestamp_ns)) {
    const gap = clock.subtract(timestamp_ns, model.frame_ns), cap = clock.fourTimes(interval);
    delta = clock.before(gap, cap) ? gap : cap;
  }
  const advanced = model.elapsed_ms + clock.milliseconds(delta);
  const elapsed_ms = model.now_duration_ms > 0 ? Math.min(advanced, model.now_duration_ms) : advanced;
  if (elapsed_ms > 4294967295) throw { kind: "position_overflow" } as PositionOverflow;
  if (!model.spectrum_live) return plain({ ...next, elapsed_ms });
  const fall = Math.fround(Math.fround(3) * Math.fround(clock.f32(delta) / Math.fround(1000000000)));
  const levels: number[] = [];
  for (let i = 0; i < 32; i++) {
    const level = model.band_levels[i] ?? 0, target = model.band_targets[i] ?? 0;
    levels.push(level > target ? Math.max(target, Math.fround(level - fall)) : level);
  }
  return plain({ ...next, elapsed_ms, band_levels: levels });
}
export function transition(model: PlaybackState, msg: PlaybackMsg): PlaybackTransition {
  switch (msg.kind) {
    case "play_track": return model.now === msg.id ? setPlaying(model, !model.playing) : start(model, msg.id);
    case "toggle_play": return model.now === null ? start(model, 1) : setPlaying(model, !model.playing);
    case "transport_play": return model.now === null ? start(model, 1) : !model.playing ? setPlaying(model, true) : plain(model);
    case "transport_pause": return model.now !== null && model.playing ? setPlaying(model, false) : plain(model);
    case "stop": return model.now === null ? plain(model) : { model: { ...resetSpectrum(model), playing: false, elapsed_ms: 0 }, commands: [{ kind: "pause" }, { kind: "seek", position_ms: 0 }] };
    case "next_track": return advance(model);
    case "prev_track": return model.now === null ? plain(model) : model.elapsed_ms > 3000 ? { model: { ...model, elapsed_ms: 0 }, commands: [{ kind: "seek", position_ms: 0 }] } : start(model, (model.now + tracks.length - 2) % tracks.length + 1);
    case "seeked": {
      if (model.now === null) return plain(model);
      const position_ms = Math.floor(Math.fround(Math.max(0, Math.min(1, model.seek_fraction)) * Math.fround(model.now_duration_ms)));
      if (position_ms > 4294967295) throw { kind: "position_overflow" } as PositionOverflow;
      return { model: { ...model, elapsed_ms: position_ms }, commands: [{ kind: "seek", position_ms }] };
    }
    case "volume_changed": {
      const value = Math.max(0, Math.min(1, model.volume_fraction));
      return { model: { ...model, volume_fraction: value }, commands: [{ kind: "volume", value }] };
    }
    case "frame_clock": return frame(model, msg.timestamp_ns, msg.interval_ns);
    case "audio_event": {
      if (model.now === null || clock.number(clock.parse(msg.key)) !== model.now) return plain(model);
      switch (msg.state) {
        case "loaded": return plain({ ...duration(model, msg.duration_ms), buffering: msg.buffering });
        case "position": {
          const position = clampMs(msg.position_ms);
          const hold = model.playing && !msg.buffering && position <= model.elapsed_ms && model.elapsed_ms - position <= 600;
          return plain({ ...duration(model, msg.duration_ms), buffering: msg.buffering, elapsed_ms: hold ? model.elapsed_ms : position });
        }
        case "spectrum": {
          const targets: number[] = [], levels: number[] = [];
          for (let i = 0; i < 32; i++) {
            const target = Math.fround(Math.fround(msg.bands[i] ?? 0) / Math.fround(255));
            targets.push(target); levels.push(Math.max(target, model.band_levels[i] ?? 0));
          }
          return plain({ ...model, spectrum_live: true, band_targets: targets, band_levels: levels });
        }
        case "completed": return advance(model);
        case "failed": case "rejected": return plain({ ...resetSpectrum(model), now: null, playing: false, buffering: false, elapsed_ms: 0,
          now_duration_ms: 0, platform_duration_ms: 0, media_failed: model.url_base.length === 0 ? true : model.media_failed,
          stream_failed: model.url_base.length > 0 ? true : model.stream_failed });
      }
    }
  }
}
