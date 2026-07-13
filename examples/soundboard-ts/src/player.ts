// soundboard-ts player module: the pure playback state machine — track
// starts, queue advance, and the launch-override stream URL rule. Everything here takes the committed Model in and returns the
// next value out; the audioPlay/pause/seek COMMANDS themselves are built
// inline in core.ts's update returns (commands live in update's return
// path only, NS1017), so this module never touches Cmd.

import type { Model } from "./core.ts";
import { TRACKS, albumById, trackById, type Bytes, type TrackInfo } from "./library.ts";

/// The loaded track's table record; undefined when idle.
export function nowTrack(model: Model): TrackInfo | undefined {
  if (model.now === null) return undefined;
  return trackById(model.now);
}

/// The next model after a track starts: playback state restarts, the
/// manifest's measured duration is the displayed total (the duration
/// rule), a fresh attempt clears the degraded notices, and the stale-event
/// guard goes up until the new playback's `loaded` lands.
export function startedModel(model: Model, trackId: number, durationMs: number): Model {
  return {
    ...model,
    now: trackId,
    playing: true,
    elapsedMs: 0,
    nowDurationMs: durationMs,
    platformDurationMs: 0,
    loadPending: true,
    buffering: false,
    assetsMissing: false,
    streamFailed: false,
  };
}

/// The play-next queue wins; otherwise the next track in the same album,
/// wrapping at the end of the record. 0 = nothing to advance to.
export function nextTrackId(model: Model): number {
  if (model.queue.length > 0) return model.queue[0].id;
  const track = nowTrack(model);
  if (track === undefined) return 0;
  const album = albumById(track.album);
  if (album === undefined) return 0;
  const nextNumber = track.number === album.trackCount ? 1 : track.number + 1;
  const next = TRACKS.find((t) => t.album === track.album && t.number === nextNumber);
  if (next === undefined) return 0;
  return next.id;
}

/// The previous track in the album, wrapping backwards.
export function previousTrackId(model: Model): number {
  const track = nowTrack(model);
  if (track === undefined) return 0;
  const album = albumById(track.album);
  if (album === undefined) return 0;
  const previousNumber = track.number === 1 ? album.trackCount : track.number - 1;
  const previous = TRACKS.find((t) => t.album === track.album && t.number === previousNumber);
  if (previous === undefined) return 0;
  return previous.id;
}

/// Drop `id` from the head of the queue when the advance consumed it.
export function dequeued(model: Model, id: number): Model {
  if (model.queue.length > 0 && model.queue[0].id === id) {
    return { ...model, queue: model.queue.slice(1) };
  }
  return model;
}

/// The playback stream URL under the launch override: a null base keeps
/// the catalog's hosted mirror, a non-empty base replaces the host
/// wholesale (trailing slashes trimmed; the track path's "assets" prefix
/// drops so "/music/..." rides the base), and an empty override means
/// LOCAL-ONLY — no stream at all.
export function streamUrl(model: Model, track: TrackInfo): Bytes {
  const base = model.urlBase;
  if (base === null) return track.url;
  let end = base.length;
  while (end > 0 && base[end - 1] === 0x2f) end -= 1;
  if (end === 0) return new Uint8Array(0);
  const suffix = track.path.subarray(6);
  const out = new Uint8Array(end + suffix.length);
  out.set(base.subarray(0, end), 0);
  out.set(suffix, end);
  return out;
}

/// Whether the launch override turned streaming OFF (an empty base): a
/// failed play is then the assets notice, never the stream notice.
export function localOnly(model: Model): boolean {
  return model.urlBase !== null && model.urlBase.length === 0;
}

/// Mirror the platform's duration report, and adopt it as the displayed
/// total ONLY when the manifest gave none (the duration rule).
export function adoptPlatformDuration(model: Model, reportedMs: number): Model {
  if (reportedMs === 0) return model;
  if (model.nowDurationMs === 0) {
    return { ...model, platformDurationMs: reportedMs, nowDurationMs: reportedMs };
  }
  return { ...model, platformDurationMs: reportedMs };
}
