import type { AudioState, ColorScheme, BootImageResult, SliderState } from "@native-sdk/core/events";
import type { TextInputEvent } from "@native-sdk/core/text";
import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";
import { initialState, stepState, setUrlBase, setCacheDir, type DeckState, type DeckExitReason, type WindowRef, type DeckTransition, type DeckMsg } from "./state.ts";
import { registerCover } from "./startup.ts";
import { stepControl } from "./controls.ts";
export interface Model { readonly deck: DeckState; }
export type Msg =
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
  | { readonly kind: "copied"; readonly key: Uint8Array; readonly code: number; readonly reason: DeckExitReason; readonly droppedLines: number; readonly output: Uint8Array; readonly outputTruncated: boolean; readonly stderrTail: Uint8Array; readonly stderrTruncated: boolean }
  | { readonly kind: "cover_registered"; readonly id: Uint8Array }
  | { readonly kind: "cover_ignored" }
  | { readonly kind: "configure_url"; readonly value: Uint8Array }
  | { readonly kind: "configure_cache"; readonly value: Uint8Array }
  | { readonly kind: "seek_changed"; readonly fraction: number }
  | { readonly kind: "volume_adjusted"; readonly fraction: number }
  | { readonly kind: "controls_sampled"; readonly seek: number; readonly volume: number };
export function initialModel(): Model { return { deck: initialState() }; }
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  if (msg.kind === "controls_sampled") return [{ deck: { ...model.deck, playback: { ...model.deck.playback, seek_fraction: msg.seek, volume_fraction: msg.volume } } }, Cmd.none];
  if (msg.kind === "cover_registered") return [{ deck: registerCover(model.deck, msg.id, true) }, Cmd.none];
  if (msg.kind === "cover_ignored") return [model, Cmd.none];
  if (msg.kind === "configure_url") return [{ deck: setUrlBase(model.deck, msg.value) }, Cmd.none];
  if (msg.kind === "configure_cache") return [{ deck: setCacheDir(model.deck, msg.value) }, Cmd.none];
  const next = msg.kind === "seek_changed" ? stepControl(model.deck, "seek", msg.fraction)
    : msg.kind === "volume_adjusted" ? stepControl(model.deck, "volume", msg.fraction)
    : stepState(model.deck, msg);
  return [{ deck: next.model }, Cmd.batch([
    Cmd.batch(next.playback_commands.map(command => command.kind === "play"
      ? Cmd.audioPlayExact(command.key, { path: command.path, url: command.url, cacheDir: command.cache_dir, expectedBytes: command.expected_bytes }, { event: "audio_event" })
      : command.kind === "pause" ? Cmd.audioTransport({ kind: "pause" })
      : command.kind === "audio_resume" ? Cmd.audioTransport({ kind: "play" })
      : command.kind === "seek" ? Cmd.audioTransport({ kind: "seek", positionMs: asciiBytes(`${command.position_ms}`) })
      : Cmd.audioTransport({ kind: "volume", value: command.value }))),
    next.window_command === null ? Cmd.none : next.window_command.kind === "close" ? Cmd.closeWindow("main") : Cmd.minimizeWindow(next.window_command.label[0] === 109 ? "main" : "playlist"),
    next.copy_command === null ? Cmd.none : Cmd.spawnEventsExact(next.copy_command.key, [asciiBytes("/usr/bin/pbcopy")], { stdin: next.copy_command.title, exit: "copied" }),
  ])];
}
export function configureUrl(model: Model, value: Uint8Array): DeckState { return setUrlBase(model.deck, value); }
export function configureCache(model: Model, value: Uint8Array): DeckState { return setCacheDir(model.deck, value); }
export function step(model: Model, msg: DeckMsg): DeckTransition { return stepState(model.deck, msg); }

export type CoverMsg =
  | { readonly kind: "cover_registered"; readonly id: Uint8Array }
  | { readonly kind: "cover_ignored" };
export function bootImageMsg(model: Model, result: BootImageResult): CoverMsg | null {
  if (!result.registered) return null;
  return { kind: "cover_registered", id: result.id };
}

export const envMsgs = [
  { env: "NATIVE_SDK_MUSIC_URL_BASE", msg: "configure_url" },
  { env: "NATIVE_SDK_APP_CACHE_DIR", msg: "configure_cache" },
] as const;

export function seekFraction(model: Model): number { return model.deck.playback.seek_fraction; }
export function volumeFraction(model: Model): number { return model.deck.playback.volume_fraction; }

export type SliderMsg =
  | { readonly kind: "controls_sampled"; readonly seek: number; readonly volume: number }
  | { readonly kind: "volume_changed" };
export function sliderStateMsg(model: Model, sliders: readonly SliderState[]): SliderMsg | null {
  let seek = model.deck.playback.seek_fraction;
  let volume = model.deck.playback.volume_fraction;
  for (const slider of sliders) {
    const label = slider.label;
    if (label.length === 4 && label[0] === 83 && label[1] === 101 && label[2] === 101 && label[3] === 107) seek = slider.value;
    if (label.length === 6 && label[0] === 86 && label[1] === 111 && label[2] === 108 && label[3] === 117 && label[4] === 109 && label[5] === 101) volume = slider.value;
  }
  return seek === model.deck.playback.seek_fraction && volume === model.deck.playback.volume_fraction ? null : { kind: "controls_sampled", seek, volume };
}

import * as queries from "./queries.ts";
import * as presentation from "./presentation.ts";
import * as chrome from "./chrome.ts";
import * as theme from "./theme.ts";
import * as dimensions from "./layout.ts";
import { windowDescriptor } from "@native-sdk/core";
import type { CanvasChromeContext, CanvasChromeCommand, ThemeState, WindowDescriptor, FrameEvent, KeyEvent } from "@native-sdk/core/events";
import type { ThemeDesignTokenOverrides } from "@native-sdk/core/theme";
export type PowerColor = "accent" | "text_muted";
export type ChannelColor = "warning" | "success";
export type LampColor = "accent" | "info";
export const appearanceMsg = "set_appearance";
export function commandMsg(name: string): Msg | null {
  if (name === "deck.play-pause") return { kind: "toggle_play" };
  if (name === "deck.next") return { kind: "next_track" };
  if (name === "deck.prev") return { kind: "prev_track" };
  if (name === "deck.playlist") return { kind: "toggle_playlist" };
  if (name === "deck.dismiss") return { kind: "clear_search" };
  if (name === "deck.playlist-closed") return { kind: "playlist_closed" };
  return null;
}
export function keyMsg(key: KeyEvent): Msg | null {
  if (key.shift || key.control || key.alt || key.super) return null;
  const bytes = utf8Bytes(key.key);
  return bytes.length === 5 && (bytes[0] === 115 || bytes[0] === 83) && (bytes[1] === 112 || bytes[1] === 80) && (bytes[2] === 97 || bytes[2] === 65) && (bytes[3] === 99 || bytes[3] === 67) && (bytes[4] === 101 || bytes[4] === 69) ? { kind: "toggle_play" } : null;
}
export function frameMsg(model: Model, frame: FrameEvent): Msg | null {
  if (!model.deck.playback.playing || model.deck.playback.now === null || model.deck.playback.buffering) return null;
  return { kind: "frame_clock", timestamp_ns: frame.timestampNs, interval_ns: frame.intervalNs };
}
export function windows(model: Model): readonly WindowDescriptor[] {
  if (!model.deck.playlist_open) return [];
  return [windowDescriptor({ label: asciiBytes("playlist"), canvasLabel: asciiBytes("playlist-canvas"), title: asciiBytes("Deck Playlist"),
    width: dimensions.playlist_width, height: dimensions.playlist_height, resizable: false, titlebar: "chromeless", onCloseCommand: asciiBytes("deck.playlist-closed") })];
}
export function themeState(model: Model): ThemeState { return theme.state(model.deck.appearance.high_contrast, model.deck.appearance.reduce_motion); }
export function tokenOverrides(model: Model): ThemeDesignTokenOverrides { return theme.overrides(model.deck.appearance.high_contrast); }
export function canvasChrome(model: Model, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  return chrome.prefix({ high_contrast: model.deck.appearance.high_contrast, now: model.deck.playback.now, elapsed_ms: model.deck.playback.elapsed_ms, volume_fraction: model.deck.playback.volume_fraction }, context);
}
export function canvasChromeSuffix(model: Model, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  return chrome.suffix({ high_contrast: model.deck.appearance.high_contrast, now: model.deck.playback.now, elapsed_ms: model.deck.playback.elapsed_ms, volume_fraction: model.deck.playback.volume_fraction }, context);
}
export function playerWindow(model: Model): WindowRef { return "player"; }
export function playlistWindow(model: Model): WindowRef { return "playlist"; }
export function playlistOpen(model: Model): boolean { return model.deck.playlist_open; }
export function playing(model: Model): boolean { return model.deck.playback.playing; }
export function idle(model: Model): boolean { return model.deck.playback.now === null; }
export function seekKey(model: Model): number { return model.deck.playback.now === null ? 0 : model.deck.playback.now; }
export function powerColor(model: Model): PowerColor { return model.deck.playback.playing ? "accent" : "text_muted"; }
export function powerState(model: Model): Uint8Array { return asciiBytes(model.deck.playback.playing ? "RUN" : "STBY"); }
export function deckMarqueeColor(model: Model): presentation.GlassColor { return presentation.marqueeColor(model.deck); }
export function channelColor(model: Model): ChannelColor { return presentation.failure(model.deck) ? "warning" : "success"; }
export function deckChannelText(model: Model): Uint8Array { return presentation.channelText(model.deck); }
export function lampColor(model: Model): LampColor { return model.deck.playback.playing ? "accent" : "info"; }
export function lampText(model: Model): Uint8Array { return asciiBytes(model.deck.playback.playing ? "LIVE" : "HOLD"); }
export function deckMarqueeText(model: Model): Uint8Array { return queries.marqueeText(presentation.queryState(model.deck)); }
export function deckSourceLabel(model: Model): Uint8Array { return queries.sourceLabel(presentation.queryState(model.deck)); }
export function deckNowCover(model: Model): Uint8Array { return queries.nowCover(presentation.queryState(model.deck)); }
export function deckHasCover(model: Model): boolean { return presentation.hasCover(model.deck); }
export function artCaption(model: Model): Uint8Array { return asciiBytes(model.deck.playback.now === null ? "--" : "NO ART"); }
export function deckLoadedTitle(model: Model): Uint8Array { return presentation.loadedTitle(model.deck); }
export function deckProgressFraction(model: Model): number { return queries.progressFraction(presentation.queryState(model.deck)); }
export function deckSpectrumLevels(model: Model): readonly number[] { return queries.spectrumLevels(presentation.queryState(model.deck)); }
export function deckVisibleTracks(model: Model): readonly queries.TrackRow[] { return queries.visibleTracks(presentation.queryState(model.deck)); }
export function trackCount(model: Model): Uint8Array { return asciiBytes(`${queries.visibleTracks(presentation.queryState(model.deck)).length} TRK`); }
export function hasTracks(model: Model): boolean { return queries.visibleTracks(presentation.queryState(model.deck)).length > 0; }
export function search(model: Model): Uint8Array { return model.deck.search_buffer.storage.subarray(0, model.deck.search_buffer.len); }
export function searching(model: Model): boolean { return model.deck.search_buffer.len > 0; }
export function deckStatusLabel(model: Model): Uint8Array { return queries.statusLabel(presentation.queryState(model.deck)); }

import { albums, tracks, type Album, type Track } from "./catalog.ts";
export function catalogAlbums(model: Model): readonly Album[] { return albums; }
export function catalogTracks(model: Model): readonly Track[] { return tracks; }

import { deckIcons } from "./icons.ts";
import type { CanvasIconDefinition } from "@native-sdk/core/events";
export function canvasIcons(model: Model): readonly CanvasIconDefinition[] { return deckIcons(); }
