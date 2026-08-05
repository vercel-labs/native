export type { TextCaretDirection, TextCaretMove, TextSelection, TextInputEvent } from "./text.js";
export interface ScrollState {
    readonly offsetX: number;
    readonly offsetY: number;
    readonly velocityX: number;
    readonly velocityY: number;
    readonly viewportExtentX: number;
    readonly viewportExtentY: number;
    readonly contentExtentX: number;
    readonly contentExtentY: number;
}
export interface FrameEvent {
    readonly width: number;
    readonly height: number;
    readonly timestampMs: number;
    readonly intervalMs: number;
}
export interface KeyEvent {
    readonly key: string;
    readonly shift: boolean;
    readonly control: boolean;
    readonly alt: boolean;
    readonly super: boolean;
}
export type PinchPhase = "begin" | "change" | "end";
export interface PinchEvent {
    readonly windowId: number;
    readonly label: string;
    readonly phase: PinchPhase;
    readonly scale: number;
    readonly x: number;
    readonly y: number;
}
export type ColorScheme = "light" | "dark";
export interface AppearanceEvent {
    readonly colorScheme: ColorScheme;
    readonly reduceMotion: boolean;
    readonly highContrast: boolean;
}
export interface ChromeInsets {
    readonly top: number;
    readonly right: number;
    readonly bottom: number;
    readonly left: number;
}
export interface ChromeButtons {
    readonly x: number;
    readonly y: number;
    readonly width: number;
    readonly height: number;
}
export interface ChromeEvent {
    readonly insets: ChromeInsets;
    readonly buttons: ChromeButtons;
    readonly tabsProjected: boolean;
}
export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum";
export interface AudioEvent {
    readonly state: AudioState;
    readonly positionMs: number;
    readonly durationMs: number;
    readonly playing: boolean;
    readonly buffering: boolean;
    readonly bands: Uint8Array;
}
export type AudioCaptureState = "started" | "readable" | "stopped" | "failed" | "rejected";
export type AudioCaptureReason = "none" | "invalid_options" | "permission_missing" | "permission_required" | "already_recording" | "device_not_found" | "device_disconnected" | "capture_failed" | "no_audio" | "consumer_too_slow" | "discarded" | "unsupported";
export interface AudioCaptureEvent {
    readonly key: Uint8Array;
    readonly state: AudioCaptureState;
    readonly reason: AudioCaptureReason;
    readonly sampleRate: number;
    readonly channels: number;
    readonly availableFrames: number;
    readonly capacityFrames: number;
    readonly framesProduced: number;
}
export type AudioCaptureReadState = "chunk" | "empty" | "ended" | "rejected";
export type AudioCaptureReadReason = "none" | "invalid_options" | "not_recording" | "read_in_progress";
export interface AudioCaptureReadEvent {
    readonly key: Uint8Array;
    readonly state: AudioCaptureReadState;
    readonly reason: AudioCaptureReadReason;
    readonly sequence: number;
    readonly frameOffset: number;
    readonly frames: number;
    /** Borrowed interleaved signed 16-bit little-endian bytes. Consume or
     * copy them before update returns. Empty when the source is disabled. */
    readonly systemPcm: Uint8Array;
    /** Same frame interval and lifetime as `systemPcm`. */
    readonly microphonePcm: Uint8Array;
    readonly systemGapFrames: number;
    readonly microphoneGapFrames: number;
    readonly remainingFrames: number;
    readonly endOfStream: boolean;
}
export type MicrophoneDeviceState = "device" | "completed" | "failed" | "rejected";
export interface MicrophoneDeviceEvent {
    readonly key: Uint8Array;
    readonly state: MicrophoneDeviceState;
    readonly id: Uint8Array;
    readonly name: Uint8Array;
    readonly isDefault: boolean;
    readonly index: number;
    readonly total: number;
}
export type CaptureAccessSource = "system_audio" | "microphone";
export type CaptureAccessStatus = "authorized" | "not_authorized" | "not_determined" | "denied" | "restricted" | "unavailable";
export interface CaptureAccessEvent {
    readonly key: Uint8Array;
    readonly source: CaptureAccessSource;
    readonly status: CaptureAccessStatus;
    readonly restartRequired: boolean;
}
