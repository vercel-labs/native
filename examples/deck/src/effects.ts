import type { AudioState } from "@native-sdk/core/events";
import type { PlaybackMsg } from "./playback.ts";

export type PlaybackEffectMsg = {
  readonly kind: "audio_event";
  readonly key: Uint8Array;
  readonly state: AudioState;
  readonly positionMs: Uint8Array;
  readonly durationMs: Uint8Array;
  readonly playing: boolean;
  readonly buffering: boolean;
  readonly bands: Uint8Array;
};

export function playbackMessage(msg: PlaybackEffectMsg): PlaybackMsg {
  return { kind: "audio_event", key: msg.key, state: msg.state, position_ms: msg.positionMs, duration_ms: msg.durationMs,
    playing: msg.playing, buffering: msg.buffering, bands: msg.bands };
}
