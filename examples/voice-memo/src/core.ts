import { Cmd, asciiBytes, type EnvMsg } from "@native-sdk/core";
import {
  type AudioCaptureSource,
  type AudioCaptureState,
  type AudioState,
} from "@native-sdk/core/events";

const CAPTURE_KEY = 41;
const PLAYER_KEY = "voice-memo-player";
const SAMPLE_RATE = 48000;
const CHANNELS = 1;
const MAX_FRAMES = 480000;
const MAX_PCM_BYTES = 960000;
const LEVEL_POINTS = 64;

export interface Memo {
  readonly id: number;
  readonly title: Uint8Array;
  readonly path: Uint8Array;
  readonly duration: Uint8Array;
  readonly size: Uint8Array;
}

export interface PcmChunk {
  readonly pcm: Uint8Array;
}

export interface Model {
  readonly dataDir: Uint8Array;
  readonly captureSource: AudioCaptureSource;
  readonly starting: boolean;
  readonly recording: boolean;
  readonly stopping: boolean;
  readonly saving: boolean;
  readonly saved: boolean;
  readonly failed: boolean;
  readonly chunks: readonly PcmChunk[];
  readonly dataBytes: number;
  readonly totalFrames: number;
  readonly levels: readonly number[];
  readonly droppedTotal: number;
  readonly memos: readonly Memo[];
  readonly nextMemoId: number;
  readonly pendingSave: Memo | null;
  readonly activeMemoId: number;
  readonly playing: boolean;
  readonly playbackPositionMs: number;
  readonly playbackDurationMs: number;
}

export type Msg =
  | { readonly kind: "data_dir_set"; readonly value: Uint8Array }
  | { readonly kind: "select_microphone" }
  | { readonly kind: "select_system" }
  | { readonly kind: "start_recording" }
  | { readonly kind: "stop_recording" }
  | { readonly kind: "retry_save" }
  | { readonly kind: "save_stamp"; readonly savedAtMs: number }
  | { readonly kind: "saved" }
  | { readonly kind: "save_failed"; readonly reason: Uint8Array }
  | { readonly kind: "play_memo"; readonly memoId: number }
  | { readonly kind: "stop_playback" }
  | {
      readonly kind: "capture_event";
      readonly key: number;
      readonly state: AudioCaptureState;
      readonly source: AudioCaptureSource;
      readonly sampleRate: number;
      readonly channels: number;
      readonly timestampMs: number;
      readonly frames: number;
      readonly pcm: Uint8Array;
      readonly droppedPending: number;
      readonly droppedTotal: number;
    }
  | {
      readonly kind: "audio_event";
      readonly state: AudioState;
      readonly positionMs: number;
      readonly durationMs: number;
      readonly playing: boolean;
      readonly buffering: boolean;
      readonly bands: Uint8Array;
    };

// Host-fired messages and state consumed only by update/derived bindings.
export const viewUnbound = [
  "data_dir_set",
  "capture_event",
  "audio_event",
  "save_stamp",
  "saved",
  "save_failed",
  "chunks",
  "starting",
  "recording",
  "stopping",
  "saving",
  "saved",
  "failed",
  "dataDir",
  "captureSource",
  "dataBytes",
  "totalFrames",
  "nextMemoId",
  "pendingSave",
  "playbackPositionMs",
  "playbackDurationMs",
] as const;

// The generated runner synthesizes this value from native_sdk.app_dirs.
// Delivery through envMsgs keeps the path outside deterministic update
// while still recording it in session journals like every host input.
export const envMsgs: readonly EnvMsg<Msg>[] = [
  { env: "NATIVE_SDK_APP_DATA_DIR", msg: "data_dir_set" },
];

export function initialModel(): Model {
  return {
    dataDir: new Uint8Array(0),
    captureSource: "microphone",
    starting: false,
    recording: false,
    stopping: false,
    saving: false,
    saved: false,
    failed: false,
    chunks: [],
    dataBytes: 0,
    totalFrames: 0,
    levels: [],
    droppedTotal: 0,
    memos: [],
    nextMemoId: 1,
    pendingSave: null,
    activeMemoId: -1,
    playing: false,
    playbackPositionMs: 0,
    playbackDurationMs: 0,
  };
}

function memoPath(dataDir: Uint8Array, savedAtMs: number, id: number): Uint8Array {
  const suffix = asciiBytes(`/recordings/voice-memo-${savedAtMs}-${id}.wav`);
  const out = new Uint8Array(dataDir.length + suffix.length);
  out.set(dataDir, 0);
  out.set(suffix, dataDir.length);
  return out;
}

function formatFrames(frames: number): Uint8Array {
  let seconds = 0;
  let rest = frames;
  while (rest >= SAMPLE_RATE) {
    rest -= SAMPLE_RATE;
    seconds += 1;
  }
  let tenths = 0;
  while (rest >= 4800) {
    rest -= 4800;
    tenths += 1;
  }
  return seconds < 10
    ? asciiBytes(`0:0${seconds}.${tenths}`)
    : asciiBytes(`0:${seconds}.${tenths}`);
}

function formatSize(bytes: number): Uint8Array {
  let kilobytes = 0;
  let rest = bytes;
  while (rest >= 1000) {
    rest -= 1000;
    kilobytes += 1;
  }
  return asciiBytes(`${kilobytes} KB`);
}

function peakLevel(pcm: Uint8Array): number {
  let peak = 0;
  for (let i = 0; i + 1 < pcm.length; i += 2) {
    let sample = pcm[i] + pcm[i + 1] * 256;
    if (sample > 32767) sample = 65536 - sample;
    if (sample > peak) peak = sample;
  }
  return peak / 32768;
}

function pushedLevel(levels: readonly number[], level: number): readonly number[] {
  if (levels.length < LEVEL_POINTS) return [...levels, level];
  return [...levels.slice(1), level];
}

// PCM16 mono -> a canonical little-endian RIFF/WAVE file. The recording
// This sample still buffers one bounded memo in Model for immediate playback;
// longer recordings should stream chunks directly to an atomic file sink.
function buildWav(chunks: readonly PcmChunk[], dataBytes: number): Uint8Array {
  const out = new Uint8Array(44 + dataBytes);
  const riffSize = 36 + dataBytes;
  const byteRate = SAMPLE_RATE * CHANNELS * 2;
  const blockAlign = CHANNELS * 2;

  out[0] = 0x52;
  out[1] = 0x49;
  out[2] = 0x46;
  out[3] = 0x46;
  out[4] = riffSize & 0xff;
  out[5] = (riffSize >>> 8) & 0xff;
  out[6] = (riffSize >>> 16) & 0xff;
  out[7] = (riffSize >>> 24) & 0xff;
  out[8] = 0x57;
  out[9] = 0x41;
  out[10] = 0x56;
  out[11] = 0x45;
  out[12] = 0x66;
  out[13] = 0x6d;
  out[14] = 0x74;
  out[15] = 0x20;
  out[16] = 16;
  out[20] = 1;
  out[22] = CHANNELS;
  out[24] = SAMPLE_RATE & 0xff;
  out[25] = (SAMPLE_RATE >>> 8) & 0xff;
  out[26] = (SAMPLE_RATE >>> 16) & 0xff;
  out[27] = (SAMPLE_RATE >>> 24) & 0xff;
  out[28] = byteRate & 0xff;
  out[29] = (byteRate >>> 8) & 0xff;
  out[30] = (byteRate >>> 16) & 0xff;
  out[31] = (byteRate >>> 24) & 0xff;
  out[32] = blockAlign;
  out[34] = 16;
  out[36] = 0x64;
  out[37] = 0x61;
  out[38] = 0x74;
  out[39] = 0x61;
  out[40] = dataBytes & 0xff;
  out[41] = (dataBytes >>> 8) & 0xff;
  out[42] = (dataBytes >>> 16) & 0xff;
  out[43] = (dataBytes >>> 24) & 0xff;

  let offset = 44;
  for (const chunk of chunks) {
    out.set(chunk.pcm, offset);
    offset += chunk.pcm.length;
  }
  return out;
}

export function elapsedLabel(model: Model): Uint8Array {
  return formatFrames(model.totalFrames);
}

export function phaseLabel(model: Model): Uint8Array {
  if (model.starting && model.captureSource === "system") return asciiBytes("Opening system audio...");
  if (model.starting) return asciiBytes("Opening microphone...");
  if (model.recording) return asciiBytes("Recording");
  if (model.stopping) return asciiBytes("Finishing audio...");
  if (model.saving) return asciiBytes("Writing WAV...");
  if (model.saved) return asciiBytes("Saved");
  if (model.failed) return asciiBytes("Needs attention");
  return asciiBytes("Ready to record");
}

export function sourceLabel(model: Model): Uint8Array {
  return model.captureSource === "system"
    ? asciiBytes("System audio")
    : asciiBytes("Microphone");
}

export function microphoneSelected(model: Model): boolean {
  return model.captureSource === "microphone";
}

export function systemSelected(model: Model): boolean {
  return model.captureSource === "system";
}

export function sourceDisabled(model: Model): boolean {
  return model.starting || model.recording || model.stopping || model.saving;
}

export function recordingProgress(model: Model): number {
  const scaled = model.totalFrames * 100;
  let threshold = MAX_FRAMES;
  let fraction = 0;
  for (let i = 0; i < 100; i++) {
    if (threshold > scaled) break;
    threshold += MAX_FRAMES;
    fraction += 0.01;
  }
  return fraction;
}

export function canStop(model: Model): boolean {
  return model.starting || model.recording;
}

export function startDisabled(model: Model): boolean {
  return model.dataDir.length === 0 || sourceDisabled(model);
}

export function retryVisible(model: Model): boolean {
  return model.failed && model.pendingSave !== null;
}

export function playbackDisabled(model: Model): boolean {
  return model.starting || model.recording || model.stopping || model.saving;
}

export function memoCount(model: Model): number {
  return model.memos.length;
}

export function statusLine(model: Model): Uint8Array {
  if (model.dataDir.length === 0) return asciiBytes("Preparing secure app storage...");
  if (model.droppedTotal > 0) return asciiBytes(`${model.droppedTotal} capture chunks dropped`);
  if (model.starting && model.captureSource === "system") return asciiBytes("Waiting for system audio access and the first audio frame.");
  if (model.starting) return asciiBytes("Waiting for microphone permission and the first audio frame.");
  if (model.recording && model.captureSource === "system") return asciiBytes("Capturing computer playback. Recording stops automatically at 10 seconds.");
  if (model.recording) return asciiBytes("Speak naturally. Recording stops automatically at 10 seconds.");
  if (model.stopping) return asciiBytes("Draining accepted audio before the file is finalized.");
  if (model.saving) return asciiBytes("Writing a 48 kHz mono PCM WAV.");
  if (model.saved) return asciiBytes("Your memo is ready to play.");
  if (model.failed) return asciiBytes("Recording or saving failed.");
  return asciiBytes("Recordings stay in this app's private data folder.");
}

export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "data_dir_set":
      if (msg.value.length === 0) return [model, Cmd.none];
      return [{ ...model, dataDir: msg.value }, Cmd.none];

    case "select_microphone":
      if (sourceDisabled(model)) return [model, Cmd.none];
      return [{ ...model, captureSource: "microphone", saved: false, failed: false }, Cmd.none];

    case "select_system":
      if (sourceDisabled(model)) return [model, Cmd.none];
      return [{ ...model, captureSource: "system", saved: false, failed: false }, Cmd.none];

    case "start_recording": {
      if (startDisabled(model)) return [model, Cmd.none];
      const startingModel: Model = {
        dataDir: model.dataDir,
        captureSource: model.captureSource,
        starting: true,
        recording: false,
        stopping: false,
        saving: false,
        saved: false,
        failed: false,
        chunks: [],
        dataBytes: 0,
        totalFrames: 0,
        levels: [],
        droppedTotal: 0,
        memos: model.memos,
        nextMemoId: model.nextMemoId,
        pendingSave: null,
        activeMemoId: -1,
        playing: false,
        playbackPositionMs: 0,
        playbackDurationMs: 0,
      };
      return [
        startingModel,
        Cmd.batch([
          // One native player is shared by the app. Stop it even when the
          // model believes it is idle so capture can never record a stale
          // playback stream or leave playback running without a Stop row.
          Cmd.audioStop(PLAYER_KEY),
          Cmd.audioCaptureStart(
            CAPTURE_KEY,
            { source: model.captureSource, sampleRate: SAMPLE_RATE, channels: CHANNELS },
            { event: "capture_event" },
          ),
        ]),
      ];
    }

    case "stop_recording":
      if (!canStop(model)) return [model, Cmd.none];
      return [
        { ...model, starting: false, recording: false, stopping: true },
        Cmd.audioCaptureStop(CAPTURE_KEY),
      ];

    case "capture_event": {
      if (msg.key !== CAPTURE_KEY) return [model, Cmd.none];
      if (msg.state === "started") {
        if (!model.starting) return [model, Cmd.none];
        return [{ ...model, starting: false, recording: true }, Cmd.none];
      }
      if (msg.state === "data") {
        if (!model.recording && !model.stopping) return [model, Cmd.none];
        if (msg.pcm.length < 1 || msg.pcm.length > MAX_PCM_BYTES) return [model, Cmd.none];
        const chunkBytes = Math.trunc(msg.pcm.length);
        const baseDataBytes = model.dataBytes >= 0 && model.dataBytes <= MAX_PCM_BYTES
          ? Math.trunc(model.dataBytes)
          : 0;
        if (baseDataBytes > MAX_PCM_BYTES - chunkBytes) {
          if (model.stopping) return [model, Cmd.none];
          return [
            { ...model, recording: false, stopping: true },
            Cmd.audioCaptureStop(CAPTURE_KEY),
          ];
        }
        const grownBytes = baseDataBytes + chunkBytes;
        const nextBytes = grownBytes >= 0
          ? (grownBytes <= 9007199254740991 ? Math.trunc(grownBytes) : 9007199254740991)
          : 0;
        const capturedFrames = msg.frames >= 0 && msg.frames <= MAX_FRAMES
          ? Math.trunc(msg.frames)
          : 0;
        const baseFrames = model.totalFrames >= 0 && model.totalFrames <= MAX_FRAMES
          ? Math.trunc(model.totalFrames)
          : 0;
        const grownFrames = baseFrames + capturedFrames;
        const nextFrames = grownFrames >= 0
          ? (grownFrames <= 9007199254740991 ? Math.trunc(grownFrames) : 9007199254740991)
          : 0;
        const nextDroppedTotal = msg.droppedTotal >= 0 && msg.droppedTotal <= 9007199254740991
          ? Math.trunc(msg.droppedTotal)
          : model.droppedTotal;
        const next: Model = {
          ...model,
          chunks: [...model.chunks, { pcm: msg.pcm }],
          dataBytes: nextBytes,
          totalFrames: nextFrames,
          levels: pushedLevel(model.levels, peakLevel(msg.pcm)),
          droppedTotal: nextDroppedTotal,
        };
        if (model.recording && nextBytes >= MAX_PCM_BYTES) {
          return [
            { ...next, recording: false, stopping: true },
            Cmd.audioCaptureStop(CAPTURE_KEY),
          ];
        }
        return [next, Cmd.none];
      }
      if (msg.state === "failed") {
        return [
          {
            ...model,
            starting: false,
            recording: false,
            stopping: false,
            failed: true,
          },
          Cmd.audioCaptureStop(CAPTURE_KEY),
        ];
      }
      if (msg.state === "rejected") {
        return [{
          ...model,
          starting: false,
          recording: false,
          stopping: false,
          failed: true,
        }, Cmd.none];
      }

      if (model.failed) return [model, Cmd.none];
      if (model.dataBytes === 0) {
        return [{
          ...model,
          starting: false,
          recording: false,
          stopping: false,
          failed: true,
        }, Cmd.none];
      }
      if (model.dataDir.length === 0) {
        return [{ ...model, stopping: false, failed: true }, Cmd.none];
      }
      return [
        {
          ...model,
          starting: false,
          recording: false,
          stopping: false,
          saving: true,
          saved: false,
          failed: false,
          pendingSave: null,
        },
        // A journaled wall-clock stamp makes the durable filename unique
        // across launches even though the in-memory display counter resets.
        Cmd.now("save_stamp"),
      ];
    }

    case "save_stamp": {
      if (!model.saving || model.pendingSave !== null || model.dataBytes === 0) {
        return [model, Cmd.none];
      }
      const id = model.nextMemoId;
      if (!(msg.savedAtMs >= 0 && msg.savedAtMs <= 9007199254740991)) {
        return [{ ...model, saving: false, failed: true }, Cmd.none];
      }
      const savedAtMs = Math.trunc(msg.savedAtMs);
      const path = memoPath(model.dataDir, savedAtMs, id);
      const pending: Memo = {
        id,
        title: model.captureSource === "system"
          ? asciiBytes(`System recording ${id}`)
          : asciiBytes(`Voice memo ${id}`),
        path,
        duration: formatFrames(model.totalFrames),
        size: formatSize(model.dataBytes + 44),
      };
      const saving: Model = {
        ...model,
        pendingSave: pending,
      };
      return [
        saving,
        Cmd.writeFile(path, buildWav(model.chunks, model.dataBytes), {
          ok: "saved",
          err: "save_failed",
        }),
      ];
    }

    case "saved": {
      if (model.pendingSave === null) return [model, Cmd.none];
      const nextId = model.nextMemoId < 1000000 ? model.nextMemoId + 1 : model.nextMemoId;
      const savedModel: Model = {
        ...model,
        saving: false,
        saved: true,
        failed: false,
        memos: [...model.memos, model.pendingSave],
        nextMemoId: nextId,
        pendingSave: null,
      };
      return [savedModel, Cmd.none];
    }

    case "save_failed":
      return [{ ...model, saving: false, saved: false, failed: true }, Cmd.none];

    case "retry_save":
      if (model.pendingSave === null || model.dataBytes === 0) return [model, Cmd.none];
      return [
        { ...model, saving: true, saved: false, failed: false },
        Cmd.writeFile(model.pendingSave.path, buildWav(model.chunks, model.dataBytes), {
          ok: "saved",
          err: "save_failed",
        }),
      ];

    case "play_memo": {
      if (playbackDisabled(model)) return [model, Cmd.none];
      if (msg.memoId < 0 || msg.memoId > 1000000) return [model, Cmd.none];
      const memoId = Math.trunc(msg.memoId);
      const memo = model.memos.find((item) => item.id === memoId);
      if (memo === undefined) return [model, Cmd.none];
      return [
        {
          ...model,
          activeMemoId: memo.id,
          playing: true,
          playbackPositionMs: 0,
          playbackDurationMs: 0,
        },
        Cmd.audioPlay(PLAYER_KEY, { path: memo.path }, { event: "audio_event" }),
      ];
    }

    case "stop_playback":
      return [
        { ...model, activeMemoId: -1, playing: false, playbackPositionMs: 0 },
        Cmd.audioStop(PLAYER_KEY),
      ];

    case "audio_event": {
      const nextPositionMs = msg.positionMs >= 0 && msg.positionMs <= 9007199254740991
        ? Math.trunc(msg.positionMs)
        : 0;
      const nextDurationMs = msg.durationMs >= 0 && msg.durationMs <= 9007199254740991
        ? Math.trunc(msg.durationMs)
        : 0;
      if (msg.state === "failed" || msg.state === "rejected") {
        return [{
          ...model,
          activeMemoId: -1,
          playing: false,
        }, Cmd.none];
      }
      if (msg.state === "completed") {
        return [{ ...model, activeMemoId: -1, playing: false, playbackPositionMs: nextPositionMs }, Cmd.none];
      }
      return [{
        ...model,
        playing: msg.playing,
        playbackPositionMs: nextPositionMs,
        playbackDurationMs: nextDurationMs,
      }, Cmd.none];
    }
  }
}
