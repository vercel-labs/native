import { Cmd, Sub, type Cmd as Command, type Sub as Subscription } from "@native-sdk/core";

export type CaptureState = "started" | "readable" | "stopped" | "failed" | "rejected";
export type CaptureReason =
  | "none" | "invalid_options" | "permission_missing" | "permission_required"
  | "already_recording" | "device_not_found" | "device_disconnected"
  | "capture_failed" | "no_audio" | "consumer_too_slow" | "discarded" | "unsupported";
export type CaptureMode = "none" | "combined" | "system_audio" | "microphone";
export type ReadState = "chunk" | "empty" | "ended" | "rejected";
export type ReadReason = "none" | "invalid_options" | "not_recording" | "read_in_progress";
export type AccessStatus = "authorized" | "not_authorized" | "not_determined" | "denied" | "restricted" | "unavailable";
export type AccessSource = "system_audio" | "microphone";
export type DeviceState = "device" | "completed" | "failed" | "rejected";
export type DeviceListState = "loading" | "device" | "completed" | "failed" | "rejected";

export interface MicrophoneDevice {
  readonly id: Uint8Array;
  readonly name: Uint8Array;
  readonly isDefault: boolean;
  readonly index: number;
}

export interface Model {
  readonly captureMode: CaptureMode;
  readonly captureState: CaptureState;
  readonly captureReason: CaptureReason;
  readonly sampleRate: number;
  readonly channels: number;
  readonly availableFrames: number;
  readonly capacityFrames: number;
  readonly framesConsumed: number;
  readonly systemGapFrames: number;
  readonly microphoneGapFrames: number;
  readonly systemPeak: number;
  readonly microphonePeak: number;
  readonly readPending: boolean;
  readonly terminalSeen: boolean;
  readonly microphones: readonly MicrophoneDevice[];
  readonly deviceListState: DeviceListState;
  readonly microphoneAccess: AccessStatus;
  readonly systemAccess: AccessStatus;
  readonly captureAccessPending: boolean;
  readonly restartRequired: boolean;
}

export type Msg =
  | { readonly kind: "start_combined" }
  | { readonly kind: "start_system_audio" }
  | { readonly kind: "start_microphone" }
  | { readonly kind: "stop_capture" }
  | { readonly kind: "discard_capture" }
  | { readonly kind: "list_microphones" }
  | { readonly kind: "request_microphone" }
  | { readonly kind: "request_system_audio" }
  | { readonly kind: "microphones_changed" }
  | { readonly kind: "capture_event"; readonly key: Uint8Array; readonly state: CaptureState; readonly reason: CaptureReason; readonly sampleRate: number; readonly channels: number; readonly availableFrames: number; readonly capacityFrames: number; readonly framesProduced: number }
  | { readonly kind: "capture_read"; readonly key: Uint8Array; readonly state: ReadState; readonly reason: ReadReason; readonly sequence: number; readonly frameOffset: number; readonly frames: number; readonly systemPcm: Uint8Array; readonly microphonePcm: Uint8Array; readonly systemGapFrames: number; readonly microphoneGapFrames: number; readonly remainingFrames: number; readonly endOfStream: boolean }
  | { readonly kind: "microphone_device"; readonly key: Uint8Array; readonly state: DeviceState; readonly id: Uint8Array; readonly name: Uint8Array; readonly isDefault: boolean; readonly index: number; readonly total: number }
  | { readonly kind: "capture_access_status"; readonly key: Uint8Array; readonly source: AccessSource; readonly status: AccessStatus; readonly restartRequired: boolean }
  | { readonly kind: "microphone_access_requested"; readonly key: Uint8Array; readonly source: AccessSource; readonly status: AccessStatus; readonly restartRequired: boolean };

export const viewUnbound = ["microphones_changed", "capture_event", "capture_read", "microphone_device", "capture_access_status", "microphone_access_requested", "readPending", "terminalSeen", "captureAccessPending"] as const;

function emptyModel(): Model {
  return {
    captureMode: "none",
    captureState: "stopped",
    captureReason: "none",
    sampleRate: 0,
    channels: 0,
    availableFrames: 0,
    capacityFrames: 0,
    framesConsumed: 0,
    systemGapFrames: 0,
    microphoneGapFrames: 0,
    systemPeak: 0,
    microphonePeak: 0,
    readPending: false,
    terminalSeen: false,
    microphones: [],
    deviceListState: "loading",
    microphoneAccess: "not_determined",
    systemAccess: "not_determined",
    captureAccessPending: true,
    restartRequired: false,
  };
}

function resetForStart(model: Model, captureMode: CaptureMode): Model {
  return {
    ...model,
    captureMode,
    captureState: "started",
    captureReason: "none",
    sampleRate: 0,
    channels: 0,
    availableFrames: 0,
    capacityFrames: 0,
    framesConsumed: 0,
    systemGapFrames: 0,
    microphoneGapFrames: 0,
    systemPeak: 0,
    microphonePeak: 0,
    readPending: false,
    terminalSeen: false,
  };
}

function pcmPeak(pcm: Uint8Array): number {
  let peak = 0;
  let index = 0;
  while (index + 1 < pcm.length) {
    const raw = pcm[index] | (pcm[index + 1] << 8);
    const sample = raw >= 32768 ? raw - 65536 : raw;
    const magnitude = sample < 0 ? -sample : sample;
    if (magnitude > peak) peak = magnitude;
    index += 2;
  }
  return peak;
}

export function combinedStartDisabled(model: Model): boolean {
  return model.captureMode !== "none" || model.systemAccess !== "authorized" || model.microphoneAccess !== "authorized";
}

export function systemStartDisabled(model: Model): boolean {
  return model.captureMode !== "none" || model.systemAccess !== "authorized";
}

export function microphoneStartDisabled(model: Model): boolean {
  return model.captureMode !== "none" || model.microphoneAccess !== "authorized";
}

export function captureAccessActionDisabled(model: Model): boolean {
  return model.captureAccessPending;
}

export function stopDisabled(model: Model): boolean {
  return model.captureMode === "none" || model.terminalSeen;
}

export function discardDisabled(model: Model): boolean {
  return model.captureMode === "none";
}

export function deviceCount(model: Model): number {
  return model.microphones.length;
}

export function systemLevel(model: Model): number {
  return model.systemPeak / 32768;
}

export function microphoneLevel(model: Model): number {
  return model.microphonePeak / 32768;
}

export function initialModel(): [Model, Command<Msg>] {
  return [
    emptyModel(),
    Cmd.batch([
      Cmd.captureAccess("mic-access", "microphone", "status", { event: "capture_access_status" }),
      Cmd.microphoneDevices("microphones", { event: "microphone_device" }),
    ]),
  ];
}

export function update(model: Model, msg: Msg): [Model, Command<Msg>] {
  switch (msg.kind) {
    case "start_combined":
      return [resetForStart(model, "combined"), Cmd.audioCaptureStart("meeting", {
        systemAudio: true,
        microphone: "default",
        sampleRate: 48000,
        channels: 2,
        excludeCurrentProcessAudio: true,
        bufferDurationMs: 5000,
      }, { event: "capture_event" })];
    case "start_system_audio":
      return [resetForStart(model, "system_audio"), Cmd.audioCaptureStart("meeting", {
        systemAudio: true,
        microphone: "none",
        sampleRate: 48000,
        channels: 2,
        excludeCurrentProcessAudio: true,
        bufferDurationMs: 5000,
      }, { event: "capture_event" })];
    case "start_microphone":
      return [resetForStart(model, "microphone"), Cmd.audioCaptureStart("meeting", {
        systemAudio: false,
        microphone: "default",
        sampleRate: 48000,
        channels: 2,
        excludeCurrentProcessAudio: true,
        bufferDurationMs: 5000,
      }, { event: "capture_event" })];
    case "stop_capture":
      return [model, Cmd.audioCaptureStop("meeting")];
    case "discard_capture":
      return [{
        ...model,
        captureMode: "none",
        captureState: "stopped",
        captureReason: "discarded",
        availableFrames: 0,
        readPending: false,
        terminalSeen: true,
      }, Cmd.audioCaptureDiscard("meeting")];
    case "list_microphones":
    case "microphones_changed":
      return [{ ...model, microphones: [], deviceListState: "loading" }, Cmd.microphoneDevices("microphones", { event: "microphone_device" })];
    case "request_microphone":
      return [{ ...model, captureAccessPending: true }, Cmd.captureAccess("mic-access", "microphone", "request", { event: "microphone_access_requested" })];
    case "request_system_audio":
      return [{ ...model, captureAccessPending: true }, Cmd.captureAccess("system-access", "system_audio", "request", { event: "capture_access_status" })];
    case "capture_event": {
      const terminal = msg.state === "stopped" || msg.state === "failed";
      const next: Model = {
        ...model,
        captureMode: msg.state === "rejected" ? "none" : model.captureMode,
        captureState: msg.state,
        captureReason: msg.reason,
        sampleRate: msg.sampleRate,
        channels: msg.channels,
        availableFrames: msg.availableFrames,
        capacityFrames: msg.capacityFrames,
        terminalSeen: model.terminalSeen || terminal,
      };
      if ((msg.state === "readable" || terminal) && !next.readPending) {
        return [{ ...next, readPending: true }, Cmd.audioCaptureRead("meeting", 4800, { event: "capture_read" })];
      }
      return [next, Cmd.none];
    }
    case "capture_read": {
      const chunk = msg.state === "chunk";
      const next: Model = {
        ...model,
        captureMode: msg.endOfStream ? "none" : model.captureMode,
        readPending: false,
        availableFrames: msg.remainingFrames,
        framesConsumed: model.framesConsumed + msg.frames,
        systemGapFrames: model.systemGapFrames + msg.systemGapFrames,
        microphoneGapFrames: model.microphoneGapFrames + msg.microphoneGapFrames,
        systemPeak: chunk ? pcmPeak(msg.systemPcm) : model.systemPeak,
        microphonePeak: chunk ? pcmPeak(msg.microphonePcm) : model.microphonePeak,
      };
      if (chunk && !msg.endOfStream && (msg.remainingFrames > 0 || next.terminalSeen)) {
        return [{ ...next, readPending: true }, Cmd.audioCaptureRead("meeting", 4800, { event: "capture_read" })];
      }
      return [next, Cmd.none];
    }
    case "microphone_device":
      if (msg.state === "device") {
        const device: MicrophoneDevice = { id: msg.id, name: msg.name, isDefault: msg.isDefault, index: msg.index };
        return [{
          ...model,
          microphones: [...model.microphones, device],
          deviceListState: "device",
        }, Cmd.none];
      }
      return [{ ...model, deviceListState: msg.state }, Cmd.none];
    case "capture_access_status":
      if (msg.source === "microphone") {
        return [{ ...model, microphoneAccess: msg.status }, Cmd.captureAccess("system-access", "system_audio", "status", { event: "capture_access_status" })];
      }
      return [{ ...model, systemAccess: msg.status, captureAccessPending: false, restartRequired: msg.restartRequired }, Cmd.none];
    case "microphone_access_requested":
      return [{ ...model, microphoneAccess: msg.status, captureAccessPending: false }, Cmd.none];
  }
}

export function subscriptions(_model: Model): Subscription<Msg> {
  return Sub.microphoneDevicesChanged("microphones_changed");
}
