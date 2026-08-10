// menu-bar: the hide-to-tray lifecycle in the default TypeScript + Native
// markup app tier. The model owns playback, commandMsg closes native tray
// actions back into ordinary Msgs, and statusItem derives the live shell.

import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";
import { type StatusItemState } from "@native-sdk/core/events";

const TRACKS: readonly Uint8Array[] = [
  utf8Bytes("Ambient Coast"),
  utf8Bytes("Night Drive"),
  utf8Bytes("Paper Planes"),
];

export interface Model {
  readonly playing: boolean;
  readonly track: number;
}

export type Msg =
  | { readonly kind: "toggle_play" }
  | { readonly kind: "next_track" }
  | { readonly kind: "open_player" }
  | { readonly kind: "quit" };

export function initialModel(): Model {
  return { playing: false, track: 0 };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "toggle_play":
      return { ...model, playing: !model.playing };
    case "next_track":
      if (model.track === 0) return { ...model, track: 1 };
      if (model.track === 1) return { ...model, track: 2 };
      return { ...model, track: 0 };
    case "open_player":
      // The counterpart to app.zon's close_policy = "hide".
      return [model, Cmd.showWindow("main")];
    case "quit":
      // The real graceful terminate, not merely another window close.
      return [model, Cmd.quitApp()];
  }
}

// ----------------------------------------------------------- view helpers

export function trackTitle(model: Model): Uint8Array {
  return TRACKS[model.track];
}

export function playbackState(model: Model): Uint8Array {
  return model.playing ? utf8Bytes("Playing") : utf8Bytes("Paused");
}

export function playButtonLabel(model: Model): Uint8Array {
  return model.playing ? utf8Bytes("Pause") : utf8Bytes("Play");
}

// ------------------------------------------------------------- app shell

/// Tray rows, app menus, and shortcuts share command names. The generated
/// runner calls this mapper for a selected status-item row.
export function commandMsg(name: string): Msg | null {
  if (name === "app.open") return { kind: "open_player" };
  if (name === "app.quit") return { kind: "quit" };
  if (name === "player.toggle") return { kind: "toggle_play" };
  if (name === "player.next") return { kind: "next_track" };
  return null;
}

/// The generated TypeScript launcher installs this on the first frame and
/// re-derives it after each committed update. No app-owned Zig wiring is
/// needed; title, labels, enabled state, and even row membership may vary.
export function statusItem(model: Model): StatusItemState {
  return {
    iconPath: asciiBytes(""),
    tooltip: utf8Bytes("Menu Bar player"),
    activationCommand: asciiBytes(""),
    alternateActivationCommand: asciiBytes(""),
    openCommand: asciiBytes(""),
    presentation: {
      title: model.playing ? utf8Bytes("MB PLAY") : utf8Bytes("MB"),
      width: model.playing ? 72 : 48,
      tone: "normal",
      iconOpacity: 1,
      monospaced: true,
    },
    items: [
      { id: 1, label: utf8Bytes("Open Player"), command: asciiBytes("app.open"), separator: false, enabled: true, detail: asciiBytes(""), role: "command", key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } },
      { id: 0, label: asciiBytes(""), command: asciiBytes(""), separator: true, enabled: false, detail: asciiBytes(""), role: "command", key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } },
      { id: 2, label: model.playing ? utf8Bytes("Pause") : utf8Bytes("Play"), command: asciiBytes("player.toggle"), separator: false, enabled: true, detail: asciiBytes(""), role: "command", key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } },
      { id: 3, label: utf8Bytes("Next Track…"), command: asciiBytes("player.next"), separator: false, enabled: true, detail: asciiBytes(""), role: "command", key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } },
      { id: 0, label: asciiBytes(""), command: asciiBytes(""), separator: true, enabled: false, detail: asciiBytes(""), role: "command", key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } },
      { id: 4, label: utf8Bytes("Quit"), command: asciiBytes("app.quit"), separator: false, enabled: true, detail: asciiBytes(""), role: "command", key: asciiBytes("q"), modifiers: { primary: false, command: true, control: false, option: false, shift: false } },
    ],
  };
}

/// These two Msgs are shell-bound rather than markup-bound. `statusItem`
/// itself is marked shell-bound automatically by the compiler contract.
export const viewUnbound = ["open_player", "quit"] as const;
