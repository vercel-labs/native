export type { TextCaretDirection, TextCaretMove, TextSelection, TextInputEvent } from "./text.js";
export type StatusItemTone = "normal" | "warning" | "critical";
export type StatusItemMenuRole = "command" | "info" | "header" | "hero" | "agent" | "context";
export interface StatusItemModifiers {
    readonly primary: boolean;
    readonly command: boolean;
    readonly control: boolean;
    readonly option: boolean;
    readonly shift: boolean;
}
export interface StatusItemPresentation {
    readonly title: Uint8Array;
    readonly width: number;
    readonly tone: StatusItemTone;
    readonly iconOpacity: number;
    readonly monospaced: boolean;
}
export interface StatusItemMenuItem {
    readonly id: number;
    readonly label: Uint8Array;
    readonly command: Uint8Array;
    readonly separator: boolean;
    readonly enabled: boolean;
    readonly detail: Uint8Array;
    readonly role: StatusItemMenuRole;
    readonly key: Uint8Array;
    readonly modifiers: StatusItemModifiers;
}
export interface StatusItemState {
    readonly iconPath: Uint8Array;
    readonly tooltip: Uint8Array;
    readonly activationCommand: Uint8Array;
    readonly alternateActivationCommand: Uint8Array;
    readonly openCommand: Uint8Array;
    readonly presentation: StatusItemPresentation;
    readonly items: readonly StatusItemMenuItem[];
}
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
export interface FileDropPoint {
    readonly x: number;
    readonly y: number;
}
export interface FileDropEvent {
    readonly windowId: number;
    readonly viewLabel: string;
    readonly point: FileDropPoint | null;
    readonly paths: readonly Uint8Array[];
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
export type AudioCaptureSource = "microphone" | "system";
export type AudioCaptureState = "started" | "data" | "failed" | "stopped" | "rejected";
export interface AudioCaptureEvent {
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
