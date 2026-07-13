// soundboard-ts core: the soundboard's whole logic tier in the TypeScript
// app-core subset — playback through the audio Cmd stream, search, the
// play-next queue, and the clipboard copy. Zero Zig in this tree: the build
// transpiles this module and its imports, src/app.native is the whole view,
// app.zon the manifest.
//
// The core is three modules plus one SDK library, all under src/:
//
//   core.ts     (this file) Model, Msg, update, subscriptions, the wiring
//               channels, and every exported binding helper — the entry
//               module is the app's public face (markup and node both see
//               exactly its exports)
//   library.ts  the committed music catalog tables and the pure catalog/
//               presentation helpers over them
//   player.ts   the pure playback state machine (track starts, queue
//               advance, the launch-override stream rule)
//   @native-sdk/core/text  the SDK's byte-splice text engine, transpiled
//               in for the search field's caret/selection/IME fidelity
//
// Playback is REAL audio through `Cmd.audioPlay`: one player is the whole
// surface (the "player" key), every report arrives on the `audio_event`
// arm, and the source cascade rides one command — the prepared local file
// first, then the catalog's hosted URL (the engine caches the stream under
// the wiring-configured caches directory; `cachePath` is deliberately
// omitted so the host derives the conventional content-addressed path).
//
// One audio channel means one identity gap the Zig original does not have:
// its audio keys were the track ids, so a straggler event from a replaced
// track dropped by key. Here every event arrives on the same stream, so a
// report from the replaced playback could land between a track switch and
// its `loaded` acknowledgment. `loadPending` is the pure-model mitigation:
// set when a track starts, cleared by `loaded`, and position/completed
// events are ignored while it is up — a stale position can never scrub the
// new track, a stale completion can never double-advance. Failure events
// stay live through the window on purpose (a failed load must surface).
//
// The rendered playback clock advances between the player's ~500ms
// position ticks through a declarative `Sub.timer` that exists exactly
// while audio moves (the TS analogue of the Zig original's gated
// `on_frame` clock — pause, and the subscription reconciles away).
// Position ticks correct it under the original's never-rewind rule: in
// motion, forward corrections apply and small backward ones hold flat;
// only a past-slack (600ms) disagreement snaps.

import { Cmd, Sub, asciiBytes, type EnvMsg } from "@native-sdk/core";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";
// The SDK-provided event records (the shapes markup and the wiring
// channels match structurally — imported, so no in-file mirror can drift).
import {
  type AudioState,
  type ChromeButtons,
  type ChromeInsets,
  type FrameEvent,
  type KeyEvent,
  type ScrollState,
} from "@native-sdk/core/events";
import {
  ALBUMS,
  TRACKS,
  albumById,
  trackById,
  albumMatches,
  trackMatches,
  albumIsPlaying,
  trackRow,
  formatMs,
  dotJoin,
  concat3,
  type AlbumCell,
  type Bytes,
  type TrackRow,
} from "./library.ts";
import {
  adoptPlatformDuration,
  dequeued,
  localOnly,
  nextTrackId,
  nowTrack,
  previousTrackId,
  startedModel,
  streamUrl,
} from "./player.ts";

// The one audio channel is the literal "player" key at every audio Cmd
// site: a new audioPlay on it replaces whatever played before — one
// player is the whole surface. (Effect keys are string literals by rule,
// so the name cannot be a shared const.)

/// How far the rendered clock may run AHEAD of a position tick before the
/// disagreement stops being interpolation drift and snaps (the Zig
/// original's position_snap_slack_ms).
const POSITION_SNAP_SLACK_MS = 600;

/// The rendered-clock cadence while playing: each subscription fire
/// advances the rendered clock exactly one interval.
const CLOCK_TICK_MS = 250;

const MAX_QUEUE = 16;
const MAX_SEARCH = 48;

/// The header bar's natural height, and the floor `headerHeight` falls
/// back to when no titlebar band overlays the content (fullscreen,
/// standard chrome, tests). Matches the tall hidden-inset band the system
/// reports through the chromeMsg channel — the Zig original's
/// `header_natural_height`.
const HEADER_NATURAL_HEIGHT = 52;

// ------------------------------------------------------------ search draft
// The fixed-capacity editor state for the search field, mirroring the
// runtime's TextBuffer(48): the SDK text engine (@native-sdk/core/text)
// does the byte splicing; this wrapper is the app's flat committed shape
// for it (compStart -1 = no composition). Immutable: searchApply returns a
// new value.

export interface SearchDraft {
  readonly bytes: Bytes;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number; // -1 when no composition
  readonly compEnd: number;
}

function searchInit(): SearchDraft {
  return { bytes: new Uint8Array(0), anchor: 0, focus: 0, compStart: -1, compEnd: -1 };
}

function searchState(d: SearchDraft): TextEditState {
  return {
    text: d.bytes,
    selection: { anchor: d.anchor, focus: d.focus },
    composition: d.compStart >= 0 ? { start: d.compStart, end: d.compEnd } : null,
  };
}

function searchApply(d: SearchDraft, event: TextInputEvent): SearchDraft {
  const state = searchState(d);
  const next = applyTextInputEvent(state, event, MAX_SEARCH);
  if (next === null) {
    // Over-capacity: clamp an insert to the bytes that fit (refuse-whole
    // for everything else) — the runtime TextBuffer's contract.
    const clamped = clampedInsertEvent(state, event, MAX_SEARCH);
    if (clamped === null) return d;
    const nextClamped = applyTextInputEvent(state, clamped, MAX_SEARCH);
    if (nextClamped === null) return d;
    return {
      bytes: nextClamped.text,
      anchor: nextClamped.selection.anchor,
      focus: nextClamped.selection.focus,
      compStart: nextClamped.composition !== null ? nextClamped.composition.start : -1,
      compEnd: nextClamped.composition !== null ? nextClamped.composition.end : -1,
    };
  }
  return {
    bytes: next.text,
    anchor: next.selection.anchor,
    focus: next.selection.focus,
    compStart: next.composition !== null ? next.composition.start : -1,
    compEnd: next.composition !== null ? next.composition.end : -1,
  };
}

// ------------------------------------------------------------------- model

export type Tab = "albums" | "songs";

/// One play-next queue entry (see `Model.queue` for why this is a record).
export interface QueueEntry {
  readonly id: number;
}

export interface Model {
  readonly tab: Tab;
  readonly openAlbum: number | null;
  /// The loaded track id (playing OR paused); null when idle.
  readonly now: number | null;
  readonly playing: boolean;
  /// The rendered playback clock: advanced by the clock-tick subscription
  /// while audio moves, corrected by position events (never-rewind rule).
  readonly elapsedMs: number;
  /// The displayed total: the manifest's measured duration — the platform
  /// player's own report is an estimate for this catalog and never
  /// replaces a nonzero manifest value (the Zig original's duration rule).
  readonly nowDurationMs: number;
  /// The platform's own duration report, mirrored for observability and
  /// adopted as the total only when the manifest carried none.
  readonly platformDurationMs: number;
  /// Stale-event window guard: set when a track starts, cleared by the
  /// new playback's `loaded` acknowledgment. One audio channel serves
  /// every track, so position/completed events are ignored while this is
  /// up — they can only belong to the replaced playback.
  readonly loadPending: boolean;
  readonly buffering: boolean;
  /// A play failed with no stream to fall back on: the local assets are
  /// not prepared (or the host has no audio playback).
  readonly assetsMissing: boolean;
  /// A play failed with the stream configured: the network let it down.
  readonly streamFailed: boolean;
  /// Play-next queue, capped at MAX_QUEUE; a full queue drops the request
  /// and counts it. Entries are single-field records rather than a bare
  /// number array: primitive-array elements are always f64 in the number
  /// tier, and these ids must stay integer-classed for the table lookups.
  readonly queue: readonly QueueEntry[];
  readonly queueDropped: number;
  readonly search: SearchDraft;
  /// Clipboard copies requested (Cmd.clipboardWrite is fire-and-forget:
  /// requests are countable, outcomes are not — see the README).
  readonly copiesRequested: number;
  /// The library page's scroll offset, echoed from markup's `on-scroll`
  /// and reset to 0 on every page change (album open/close, tab switch)
  /// — the controlled-scroll shape: the model owns the offset, markup's
  /// `value` binding applies it back.
  readonly libraryScrollTop: number;
  /// The canvas width in whole points, delivered through the `frameMsg`
  /// channel; `gridColumns` derives the album rack from it (the Zig
  /// original's width rule). 0 until the first presented frame.
  readonly canvasWidth: number;
  /// The launch-time streaming-base override (NATIVE_SDK_MUSIC_URL_BASE
  /// through the `envMsgs` channel): null keeps the catalog's hosted
  /// mirror, a non-empty base replaces the host wholesale, and an empty
  /// override means LOCAL-ONLY — a failed play then reports the assets
  /// notice, not the stream notice (the Zig original's launch split).
  readonly urlBase: Bytes | null;
  /// Chrome overlay geometry (tall hidden-inset titlebar) from the
  /// chromeMsg channel: the header leads with a spacer this wide so its
  /// controls clear the traffic lights (macOS puts them leading; Windows
  /// pads the trailing twin instead), and matches its height to the
  /// titlebar band — the Zig original's chrome fields.
  readonly chromeLeading: number;
  readonly chromeTrailing: number;
  readonly headerHeight: number;
}

export function initialModel(): Model {
  return {
    tab: "albums",
    openAlbum: null,
    now: null,
    playing: false,
    elapsedMs: 0,
    nowDurationMs: 0,
    platformDurationMs: 0,
    loadPending: false,
    buffering: false,
    assetsMissing: false,
    streamFailed: false,
    queue: [],
    queueDropped: 0,
    search: searchInit(),
    copiesRequested: 0,
    libraryScrollTop: 0,
    canvasWidth: 0,
    urlBase: null,
    chromeLeading: 0,
    chromeTrailing: 0,
    headerHeight: HEADER_NATURAL_HEIGHT,
  };
}

// --------------------------------------------------------------------- msg

export type Msg =
  | { readonly kind: "show_albums" }
  | { readonly kind: "show_songs" }
  | { readonly kind: "open_album"; readonly id: number }
  | { readonly kind: "close_album" }
  | { readonly kind: "play_album"; readonly id: number }
  /// The play gesture on a track row: a different track starts fresh, the
  /// loaded one toggles play/pause in place.
  | { readonly kind: "play_track"; readonly id: number }
  | { readonly kind: "toggle_play" }
  | { readonly kind: "next_track" }
  | { readonly kind: "prev_track" }
  | { readonly kind: "queue_track"; readonly id: number }
  | { readonly kind: "copy_title"; readonly id: number }
  | { readonly kind: "search_edit"; readonly edit: TextInputEvent }
  /// Every audio playback report: the load acknowledgment, position
  /// ticks, the one completion, failures, spectrum frames.
  | {
      readonly kind: "audio_event";
      readonly state: AudioState;
      readonly positionMs: number;
      readonly durationMs: number;
      readonly playing: boolean;
      readonly buffering: boolean;
      readonly bands: Bytes;
    }
  /// The rendered-clock subscription's fire (Sub.timer while playing).
  | { readonly kind: "clock_tick"; readonly at: number }
  /// The seek slider's applied 0..1 fraction (markup's value-payload
  /// change event — the transport's scrub-to-seek).
  | { readonly kind: "scrubbed"; readonly fraction: number }
  /// The library scroll offset echo (markup's on-scroll over the
  /// declared ScrollState mirror).
  | { readonly kind: "library_scrolled"; readonly scroll: ScrollState }
  /// The presented-frame width channel (`frameMsg` below).
  | { readonly kind: "canvas_resized"; readonly width: number }
  /// The launch streaming-base override (`envMsgs` below).
  | { readonly kind: "url_base_set"; readonly value: Bytes }
  /// Chrome overlay geometry (the chromeMsg channel's arm): delivered
  /// before the first view build and again whenever it changes
  /// (fullscreen zeroes it).
  | {
      readonly kind: "chrome_changed";
      readonly insets: ChromeInsets;
      readonly buttons: ChromeButtons;
      readonly tabsProjected: boolean;
    };

// ------------------------------------------------- host-event channels

/// Presented frames dispatch ONLY on a width change: the grid column
/// derivation re-runs on the next rebuild, and an unchanged frame
/// dispatches nothing (the idle law — this port's rendered clock stays
/// the declarative Sub.timer, so no per-frame arm exists to sustain).
export function frameMsg(model: Model, frame: FrameEvent): Msg | null {
  if (frame.width !== model.canvasWidth) return { kind: "canvas_resized", width: frame.width };
  return null;
}

/// The media-app keys on the app-level FALLBACK (the runtime's precedence
/// rule applies first: the search field keeps typing, a focused slider
/// takes the arrows): SPACE toggles the transport, and the left/right
/// arrows are previous/next track. The Zig original's selection register
/// (up/down + Enter) needs the per-row accent styling this port has not
/// adopted, so its selection keys stay unmapped here (see the README).
export function keyMsg(key: KeyEvent): Msg | null {
  if (key.control || key.alt || key.super || key.shift) return null;
  if (key.key === "space") return { kind: "toggle_play" };
  if (key.key === "arrowright") return { kind: "next_track" };
  if (key.key === "arrowleft") return { kind: "prev_track" };
  return null;
}

/// The launch environment channel: the streaming base override arrives as
/// one journaled Msg at install (the wiring reads the variable once; the
/// core never touches the environment — NS1005).
export const envMsgs: readonly EnvMsg<Msg>[] = [
  { env: "NATIVE_SDK_MUSIC_URL_BASE", msg: "url_base_set" },
];

/// Window-chrome geometry dispatches the named arm — delivered before the
/// first view build and again when it changes (the tall hidden-inset
/// titlebar app.zon declares; the header IS the titlebar, exactly like
/// the Zig original's `on_chrome`).
export const chromeMsg = "chrome_changed";

/// Update-only state: host-fired Msg arms and the model fields markup
/// reads through the exported derived helpers instead of directly.
export const viewUnbound = [
  "audio_event",
  "clock_tick",
  "canvas_resized",
  "url_base_set",
  "chrome_changed",
  "canvasWidth",
  "urlBase",
  "tab",
  "openAlbum",
  "now",
  "playing",
  "elapsedMs",
  "nowDurationMs",
  "platformDurationMs",
  "loadPending",
  "buffering",
  "assetsMissing",
  "streamFailed",
  "queue",
  "queueDropped",
  "search",
  "copiesRequested",
] as const;

// ---------------------------------------------------------- derived: pages

export function albumsShowing(model: Model): boolean {
  return model.tab === "albums";
}

export function songsShowing(model: Model): boolean {
  return model.tab === "songs";
}

export function detailPage(model: Model): boolean {
  return model.tab === "albums" && model.openAlbum !== null;
}

export function searchText(model: Model): Bytes {
  return model.search.bytes;
}

/// Albums matching the search query — the grid's rows.
export function visibleAlbums(model: Model): readonly AlbumCell[] {
  const query = model.search.bytes;
  const out: AlbumCell[] = [];
  for (const album of ALBUMS) {
    if (!albumMatches(query, album)) continue;
    out.push({
      id: album.id,
      title: album.title,
      artist: album.artist,
      initials: album.initials,
      cover: album.id,
      playing: albumIsPlaying(model, album.id),
    });
  }
  return out;
}

/// The album rack's column count from the delivered canvas width — the
/// Zig original's width rule (232pt tile floor, 24pt padding, 12pt gap:
/// columns = how many minimum tiles plus gaps fit the padded row) in the
/// integer domain: the whole-unit loop stands in for float division, and
/// the pre-first-frame width falls back to the original's 1056 min-width
/// floor (underfill a wider surface for one frame, never overflow a
/// narrow one — the Zig `min_canvas_width` default).
export function gridColumns(model: Model): number {
  const width = model.canvasWidth > 0 ? model.canvasWidth : 1056;
  let available = width - 48;
  if (available < 232) available = 232;
  let rest = available + 12;
  let columns = 0;
  while (rest >= 244) {
    rest -= 244;
    columns += 1;
  }
  return columns < 1 ? 1 : columns;
}

/// The grid node's SHOWN column count: never more columns than visible
/// cells, so a short result set (a narrow search) keeps tile-sized
/// covers left-aligned instead of ballooning across the row — the Zig
/// original's `@min(fit.columns, cells.len)`. Kept in the integer
/// domain: this is the markup `columns` binding, which must stay whole.
export function gridShownColumns(model: Model): number {
  const fit = gridColumns(model);
  const cells = visibleAlbums(model).length;
  if (cells > 0 && cells < fit) return cells;
  return fit;
}

/// The evenly-grown tile width at the fit's column count: the padded row
/// split evenly, the Zig original's `GridFit.tile_width`. This is the
/// float domain's copy of the width rule (division is float-classed in
/// the number tier), restated rather than shared with `gridColumns` so
/// the markup `columns` binding above keeps its demanded integer class.
export function gridTileWidth(model: Model): number {
  const width = model.canvasWidth > 0 ? model.canvasWidth : 1056;
  let available = width - 48;
  if (available < 232) available = 232;
  let rest = available + 12;
  let columns = 0;
  while (rest >= 244) {
    rest -= 244;
    columns += 1;
  }
  if (columns < 1) columns = 1;
  const gaps = 12 * (columns - 1);
  return (available - gaps) / columns;
}

/// The grid node's exact width: the shown columns of evenly-grown tiles
/// plus gaps. The grid is EXPLICITLY sized to its shown columns rather
/// than stretched to the row, because the engine divides the grid's
/// width evenly among its columns — an exact width makes each cell
/// exactly one tile wide (the Zig original's `row_width`).
export function gridRowWidth(model: Model): number {
  const tile = gridTileWidth(model);
  const width = model.canvasWidth > 0 ? model.canvasWidth : 1056;
  let available = width - 48;
  if (available < 232) available = 232;
  let rest = available + 12;
  let columns = 0;
  while (rest >= 244) {
    rest -= 244;
    columns += 1;
  }
  if (columns < 1) columns = 1;
  const cells = visibleAlbums(model).length;
  if (cells > 0 && cells < columns) columns = cells;
  return columns * (tile + 12) - 12;
}

/// One bare tile's square cover: the tile width minus the hover/press
/// wash inset on both sides (the original's `tile_padding * 2`).
export function gridCoverSize(model: Model): number {
  return gridTileWidth(model) - 16;
}

/// One tile's total height, derived from its width: paddings, the square
/// cover, the cover-text gap, and the two-line text block (the Zig
/// original's `tile_padding * 2 + cover + cover_text_gap +
/// tile_text_height` = tile width + 44).
export function gridTileHeight(model: Model): number {
  return gridTileWidth(model) + 44;
}

/// Library tracks matching the search query — the Songs tab's rows.
export function visibleTracks(model: Model): readonly TrackRow[] {
  const query = model.search.bytes;
  const out: TrackRow[] = [];
  for (const track of TRACKS) {
    if (!trackMatches(query, track)) continue;
    out.push(trackRow(model, track, true));
  }
  return out;
}

/// The open album's tracks (never search-filtered: the detail page is the
/// whole record).
export function openAlbumRows(model: Model): readonly TrackRow[] {
  if (model.openAlbum === null) return [];
  const id = model.openAlbum;
  const out: TrackRow[] = [];
  for (const track of TRACKS) {
    if (track.album !== id) continue;
    out.push(trackRow(model, track, false));
  }
  return out;
}

export function visibleAlbumCount(model: Model): number {
  return visibleAlbums(model).length;
}

export function albumCount(model: Model): number {
  return ALBUMS.length;
}

export function visibleTrackCount(model: Model): number {
  return visibleTracks(model).length;
}

export function trackCount(model: Model): number {
  return TRACKS.length;
}

export function noAlbumMatches(model: Model): boolean {
  return visibleAlbums(model).length === 0;
}

export function noTrackMatches(model: Model): boolean {
  return visibleTracks(model).length === 0;
}

export function noMatchesLabel(model: Model): Bytes {
  return concat3(asciiBytes('No matches for "'), model.search.bytes, asciiBytes('"'));
}

// --------------------------------------------------------- derived: detail

/// The open album's id for the detail page's Play-album payload binding
/// (0 when no album is open — the page is not composed then).
export function openAlbumId(model: Model): number {
  return model.openAlbum ?? 0;
}

export function openAlbumTitle(model: Model): Bytes {
  if (model.openAlbum === null) return new Uint8Array(0);
  const album = albumById(model.openAlbum);
  if (album === undefined) return new Uint8Array(0);
  return album.title;
}

export function openAlbumInitials(model: Model): Bytes {
  if (model.openAlbum === null) return new Uint8Array(0);
  const album = albumById(model.openAlbum);
  if (album === undefined) return new Uint8Array(0);
  return album.initials;
}

/// The open album's registered cover id (0 = fallback initials).
export function openAlbumCover(model: Model): number {
  return model.openAlbum ?? 0;
}

/// "Artist · year · N tracks", the detail heading's meta line (the Zig
/// original's "{s} · {d} · {d} tracks" format, middle dots and all).
export function openAlbumMeta(model: Model): Bytes {
  if (model.openAlbum === null) return new Uint8Array(0);
  const album = albumById(model.openAlbum);
  if (album === undefined) return new Uint8Array(0);
  return dotJoin(dotJoin(album.artist, asciiBytes(`${album.year}`)), asciiBytes(`${album.trackCount} tracks`));
}

// ---------------------------------------------------- derived: now playing

export function idle(model: Model): boolean {
  return model.now === null;
}

/// The bar's first line doubles as the status line: the honest degraded
/// notices replace the track title after a failed play.
export function nowPlayingTitle(model: Model): Bytes {
  if (model.streamFailed) return asciiBytes("stream unavailable");
  if (model.assetsMissing) return asciiBytes("music assets not prepared");
  const track = nowTrack(model);
  if (track === undefined) return asciiBytes("Nothing playing");
  return track.title;
}

export function nowPlayingArtist(model: Model): Bytes {
  if (model.streamFailed) return asciiBytes("check the connection and try again");
  if (model.assetsMissing) return asciiBytes("run tools/prepare-example-music.sh");
  const track = nowTrack(model);
  if (track === undefined) return asciiBytes("Pick an album or a song to start");
  // The honest third state: a stalled stream is not paused, but nothing
  // is coming out of the speakers either.
  if (model.buffering) return asciiBytes("buffering...");
  const album = albumById(track.album);
  if (album === undefined) return new Uint8Array(0);
  return album.artist;
}

export function nowPlayingInitials(model: Model): Bytes {
  const track = nowTrack(model);
  if (track === undefined) return asciiBytes("--");
  const album = albumById(track.album);
  if (album === undefined) return asciiBytes("--");
  return album.initials;
}

/// The loaded track's album cover id for the bar's thumb (0 = initials).
export function nowPlayingCover(model: Model): number {
  const track = nowTrack(model);
  if (track === undefined) return 0;
  return track.album;
}

/// Data-driven icon for the transport's primary button: one button swaps
/// its glyph with playback state.
export function playPauseIcon(model: Model): Bytes {
  return model.playing ? asciiBytes("pause") : asciiBytes("play");
}

/// The played fraction (0..1) in whole-percent steps. Division is
/// float-classed in the v1 number tier and the ms fields are demanded
/// integers (they format and compare as integers), so the two classes may
/// never meet in one expression: the percent counts up in the integer
/// domain and the fraction accumulates in the float domain, one 0.01 step
/// per percent.
export function progressFraction(model: Model): number {
  if (model.now === null || model.nowDurationMs < 1) return 0;
  const scaled = model.elapsedMs * 100;
  let acc = model.nowDurationMs;
  let fraction = 0;
  for (let i = 0; i < 100; i++) {
    if (acc > scaled) break;
    acc += model.nowDurationMs;
    fraction += 0.01;
  }
  return fraction;
}

export function elapsedLabel(model: Model): Bytes {
  if (model.now === null) return asciiBytes("-:--");
  return formatMs(model.elapsedMs);
}

export function durationLabel(model: Model): Bytes {
  if (model.now === null) return asciiBytes("-:--");
  return formatMs(model.nowDurationMs);
}

export function queueLen(model: Model): number {
  return model.queue.length;
}


// ------------------------------------------------------------------ update

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "show_albums":
      return { ...model, tab: "albums", libraryScrollTop: 0 };
    case "show_songs":
      return { ...model, tab: "songs", libraryScrollTop: 0 };
    case "open_album": {
      // Resolve the payload id against the table and store the TABLE's
      // id: markup payloads arrive as wire f64s, and keeping every id in
      // the model integer-classed starts here.
      const album = ALBUMS.find((a) => a.id === msg.id);
      if (album === undefined) return model;
      // Every page change resets the controlled scroll: the offset is
      // model state, so the fresh page opens at its top.
      return { ...model, openAlbum: album.id, tab: "albums", libraryScrollTop: 0 };
    }
    case "close_album":
      return { ...model, openAlbum: null, libraryScrollTop: 0 };
    case "play_album": {
      const album = ALBUMS.find((a) => a.id === msg.id);
      if (album === undefined) return model;
      const albumId = album.id;
      const first = TRACKS.find((t) => t.album === albumId && t.number === 1);
      if (first === undefined) return model;
      return [
        startedModel(model, first.id, first.durationMs),
        Cmd.audioPlay(
          "player",
          { path: first.path, url: streamUrl(model, first), expectedBytes: first.bytes },
          { event: "audio_event" },
        ),
      ];
    }
    case "play_track": {
      // The loaded track toggles play/pause in place; a different track
      // starts fresh.
      if (model.now === msg.id) {
        if (model.playing) return [{ ...model, playing: false }, Cmd.audioPause("player")];
        return [{ ...model, playing: true }, Cmd.audioResume("player")];
      }
      const track = TRACKS.find((t) => t.id === msg.id);
      if (track === undefined) return model;
      return [
        startedModel(model, track.id, track.durationMs),
        Cmd.audioPlay(
          "player",
          { path: track.path, url: streamUrl(model, track), expectedBytes: track.bytes },
          { event: "audio_event" },
        ),
      ];
    }
    case "toggle_play": {
      if (model.now === null) {
        const first = TRACKS[0];
        return [
          startedModel(model, first.id, first.durationMs),
          Cmd.audioPlay(
            "player",
            { path: first.path, url: streamUrl(model, first), expectedBytes: first.bytes },
            { event: "audio_event" },
          ),
        ];
      }
      if (model.playing) return [{ ...model, playing: false }, Cmd.audioPause("player")];
      return [{ ...model, playing: true }, Cmd.audioResume("player")];
    }
    case "next_track": {
      const target = nextTrackId(model);
      if (target === 0) return model;
      const track = trackById(target);
      if (track === undefined) return model;
      return [
        startedModel(dequeued(model, target), track.id, track.durationMs),
        Cmd.audioPlay(
          "player",
          { path: track.path, url: streamUrl(model, track), expectedBytes: track.bytes },
          { event: "audio_event" },
        ),
      ];
    }
    case "prev_track": {
      if (model.now === null) return model;
      // Restart the current track when it is a few seconds in — the same
      // 3s rule as the original (this is the seek verb's home here).
      if (model.elapsedMs > 3000) {
        return [{ ...model, elapsedMs: 0 }, Cmd.audioSeek("player", 0)];
      }
      const target = previousTrackId(model);
      if (target === 0) return model;
      const track = trackById(target);
      if (track === undefined) return model;
      return [
        startedModel(model, track.id, track.durationMs),
        Cmd.audioPlay(
          "player",
          { path: track.path, url: streamUrl(model, track), expectedBytes: track.bytes },
          { event: "audio_event" },
        ),
      ];
    }
    case "queue_track": {
      const track = TRACKS.find((t) => t.id === msg.id);
      if (track === undefined) return model;
      if (model.queue.some((q) => q.id === track.id)) return model;
      if (model.queue.length >= MAX_QUEUE) {
        return { ...model, queueDropped: model.queueDropped + 1 };
      }
      return { ...model, queue: [...model.queue, { id: track.id }] };
    }
    case "copy_title": {
      const track = TRACKS.find((t) => t.id === msg.id);
      if (track === undefined) return model;
      return [
        { ...model, copiesRequested: model.copiesRequested + 1 },
        Cmd.clipboardWrite(track.title),
      ];
    }
    case "search_edit":
      return { ...model, search: searchApply(model.search, msg.edit) };
    case "audio_event": {
      switch (msg.state) {
        case "loaded": {
          const next = adoptPlatformDuration(model, msg.durationMs);
          return {
            ...next,
            loadPending: false,
            elapsedMs: msg.positionMs,
            playing: msg.playing,
            buffering: msg.buffering,
          };
        }
        case "position": {
          // One audio channel: a position from the replaced playback can
          // land before the new track's `loaded` — drop it by the guard.
          if (model.loadPending || model.now === null) return model;
          const next = adoptPlatformDuration(model, msg.durationMs);
          // The coarse tick corrects the rendered clock. In motion,
          // forward corrections apply and small backward ones hold flat
          // (the bar never visibly rewinds); a past-slack disagreement
          // snaps. With no motion the tick is simply the truth.
          if (next.playing && !msg.buffering) {
            if (
              msg.positionMs > next.elapsedMs ||
              next.elapsedMs - msg.positionMs > POSITION_SNAP_SLACK_MS
            ) {
              return { ...next, elapsedMs: msg.positionMs, buffering: msg.buffering };
            }
            return { ...next, buffering: msg.buffering };
          }
          return { ...next, elapsedMs: msg.positionMs, buffering: msg.buffering };
        }
        // Band-magnitude analysis frames are consciously ignored — the
        // soundboard's identity is the clean catalog (parity with the
        // original, which drops them the same way).
        case "spectrum":
          return model;
        case "completed": {
          // A stale completion (from the replaced playback) must never
          // double-advance.
          if (model.loadPending || model.now === null) return model;
          const target = nextTrackId(model);
          if (target === 0) return model;
          const track = trackById(target);
          if (track === undefined) return model;
          return [
            startedModel(dequeued(model, target), track.id, track.durationMs),
            Cmd.audioPlay(
              "player",
              { path: track.path, url: streamUrl(model, track), expectedBytes: track.bytes },
              { event: "audio_event" },
            ),
          ];
        }
        case "failed":
        case "rejected":
          // Playback could not run. With a stream configured (the
          // catalog's hosted mirror, or a non-empty launch override) the
          // stream let the playback down; with streaming turned OFF (an
          // empty NATIVE_SDK_MUSIC_URL_BASE — the envMsgs channel) the
          // local assets are simply not prepared — the Zig original's
          // launch split, now expressible because the wiring delivers
          // the override as a Msg.
          return {
            ...model,
            now: null,
            playing: false,
            loadPending: false,
            buffering: false,
            streamFailed: !localOnly(model),
            assetsMissing: localOnly(model),
            elapsedMs: 0,
            nowDurationMs: 0,
            platformDurationMs: 0,
          };
      }
    }
    case "scrubbed": {
      if (model.now === null || model.loadPending || model.nowDurationMs < 1) return model;
      // The slider's applied 0..1 fraction into whole milliseconds at
      // per-mille granularity: the permille counts in the integer domain
      // while the fraction accumulates in the float domain (the NS1016
      // parallel-accumulation idiom), and the duration's thousandth
      // comes from a whole-unit loop — no float-to-integer conversion
      // exists in the tier.
      let permille = 0;
      let acc = 0.001;
      while (permille < 1000 && acc <= msg.fraction) {
        acc += 0.001;
        permille += 1;
      }
      let thousandth = 0;
      let rest = model.nowDurationMs;
      while (rest >= 1000) {
        rest -= 1000;
        thousandth += 1;
      }
      const target = thousandth * permille;
      // The rendered clock jumps to the scrub target directly (a seek is
      // the one sanctioned rewind) and the engine seeks the real player.
      return [{ ...model, elapsedMs: target }, Cmd.audioSeek("player", target)];
    }
    case "library_scrolled":
      // The controlled-scroll echo: the applied offset lands in the
      // model, so the next rebuild's `value` binding never fights the
      // runtime (and page changes reset it to 0 above).
      return { ...model, libraryScrollTop: msg.scroll.offset };
    case "canvas_resized":
      return { ...model, canvasWidth: msg.width };
    case "url_base_set":
      return { ...model, urlBase: msg.value };
    case "chrome_changed":
      // Pad whichever edge the platform puts its window controls on
      // (macOS: traffic lights leading; Windows: min/max/close trailing
      // — the unused edge arrives as an honest zero), and match the
      // header to the titlebar band so its centered controls share the
      // traffic lights' centerline; the natural height is the floor when
      // no band overlays the content (the Zig original's rule).
      return {
        ...model,
        chromeLeading: msg.insets.left,
        chromeTrailing: msg.insets.right,
        headerHeight: Math.max(HEADER_NATURAL_HEIGHT, msg.insets.top),
      };
    case "clock_tick": {
      if (!model.playing || model.now === null || model.buffering) return model;
      // Fixed per-fire advance: the subscription fires on its own
      // cadence, so each tick steps exactly one interval — a burst of
      // queued fires is bounded by construction — and the position
      // events correct any drift. The clock never passes the total.
      const advanced = model.elapsedMs + CLOCK_TICK_MS;
      const cap = model.nowDurationMs > 0 ? model.nowDurationMs : advanced;
      return { ...model, elapsedMs: Math.min(advanced, cap) };
    }
  }
}

// --------------------------------------------------------------------- sub

/// The rendered-clock subscription: exists exactly while audio moves —
/// pause, buffer, or stop, and reconciliation cancels it (the declarative
/// analogue of the Zig original's motion-gated on_frame clock).
export function subscriptions(model: Model): Sub<Msg> {
  if (!model.playing || model.buffering || model.now === null) return Sub.none;
  return Sub.timer("playclock", CLOCK_TICK_MS, "clock_tick");
}
