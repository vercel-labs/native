/** Complete synchronous registration result for a declared boot image.
 * `id` is canonical decimal ASCII for the native u64 identity. Failure keeps
 * dimensions zero and supplies the complete native error name. No pixels or
 * encoded image storage enter the core's model heap.
 */
export type BootImageResult = {
    readonly id: Uint8Array;
    readonly registered: boolean;
    readonly width: number;
    readonly height: number;
    readonly errorName: Uint8Array;
};
export type { TextCaretDirection, TextCaretMove, TextSelection, TextInputEvent } from "./text.js";
export interface WebViewPane {
    readonly label: Uint8Array;
    readonly anchor: Uint8Array | null;
    readonly x: number;
    readonly y: number;
    readonly width: number;
    readonly height: number;
    readonly url: Uint8Array;
    readonly reloadToken: number;
}
export interface ExactWebViewPane {
    readonly label: Uint8Array;
    readonly anchor: Uint8Array | null;
    readonly x: number;
    readonly y: number;
    readonly width: number;
    readonly height: number;
    readonly url: Uint8Array;
    readonly reloadToken: Uint8Array;
}
export interface TerminalState {
    readonly scrollback: number;
    readonly history: number;
    readonly cols: number;
    readonly rows: number;
}
export type ThemeStatePack = "house" | "geist";
export type ThemeStateColorScheme = "light" | "dark" | "system";
export type ThemeState = {
    readonly pack?: ThemeStatePack;
    readonly colorScheme?: ThemeStateColorScheme;
    readonly accent?: string;
    readonly highContrast?: boolean;
    readonly reduceMotion?: boolean;
};
export type StatusItemTone = "normal" | "warning" | "critical";
export type StatusItemFontWeight = "regular" | "medium" | "semibold" | "bold";
export type StatusItemMenuRole = "command" | "info" | "header" | "hero" | "agent" | "context" | "segmented" | "chart";
export interface StatusItemModifiers {
    readonly primary: boolean;
    readonly command: boolean;
    readonly control: boolean;
    readonly option: boolean;
    readonly shift: boolean;
}
export type StatusItemPresentation = {
    readonly title: Uint8Array;
    readonly width: number;
    readonly tone: StatusItemTone;
    readonly iconOpacity: number;
    readonly monospaced: boolean;
    readonly fontSize?: number;
    readonly fontWeight?: StatusItemFontWeight;
};
export interface StatusItemSegmentOption {
    readonly id: number;
    readonly label: Uint8Array;
    readonly command: Uint8Array;
    readonly selected: boolean;
    readonly enabled: boolean;
}
export interface StatusItemSegmentedRow {
    readonly options: readonly StatusItemSegmentOption[];
}
export interface StatusItemMetricRow {
    readonly primaryText: Uint8Array;
    readonly secondaryText: Uint8Array;
    readonly accessibilityLabel: Uint8Array;
}
export interface StatusItemChartRow {
    readonly values: readonly number[];
    readonly minValue: number;
    readonly maxValue: number;
    readonly leadingCaption: Uint8Array;
    readonly trailingSummary: Uint8Array;
    readonly accessibilityLabel: Uint8Array;
}
export type StatusItemMenuItem = {
    readonly id: number;
    readonly label: Uint8Array;
    readonly command: Uint8Array;
    readonly separator: boolean;
    readonly enabled: boolean;
    readonly detail: Uint8Array;
    readonly role: StatusItemMenuRole;
    readonly key: Uint8Array;
    readonly modifiers: StatusItemModifiers;
    readonly segmented?: StatusItemSegmentedRow;
    readonly metric?: StatusItemMetricRow;
    readonly chart?: StatusItemChartRow;
};
export interface StatusItemState {
    readonly iconPath: Uint8Array;
    readonly tooltip: Uint8Array;
    readonly activationCommand: Uint8Array;
    readonly alternateActivationCommand: Uint8Array;
    readonly openCommand: Uint8Array;
    readonly presentation: StatusItemPresentation;
    readonly items: readonly StatusItemMenuItem[];
}
export interface StatusItemDescriptor {
    readonly id: number;
    readonly visible: boolean;
    readonly iconPath: Uint8Array;
    readonly tooltip: Uint8Array;
    readonly activationCommand: Uint8Array;
    readonly alternateActivationCommand: Uint8Array;
    readonly openCommand: Uint8Array;
    readonly presentation: StatusItemPresentation;
    readonly items: readonly StatusItemMenuItem[];
}
export type WindowClosePolicy = "quit" | "hide";
export type WindowTitlebarStyle = "standard" | "hidden_inset" | "hidden_inset_tall" | "chromeless";
export type WindowRestorePolicy = "clamp_to_visible_screen" | "center_on_primary";
export interface WindowDescriptorSpec {
    readonly label: Uint8Array;
    readonly canvasLabel: Uint8Array;
    readonly title?: Uint8Array;
    readonly width?: number;
    readonly height?: number;
    readonly x?: number | null;
    readonly y?: number | null;
    readonly resizable?: boolean;
    readonly restorePolicy?: WindowRestorePolicy;
    readonly minWidth?: number;
    readonly minHeight?: number;
    readonly titlebar?: WindowTitlebarStyle;
    readonly transparent?: boolean;
    readonly alwaysOnTop?: boolean;
    readonly clickThrough?: boolean;
    readonly activateOnShow?: boolean;
    readonly allowsFullscreen?: boolean;
    readonly closePolicy?: WindowClosePolicy;
    readonly onCloseCommand?: Uint8Array;
}
export interface WindowDescriptor {
    readonly label: Uint8Array;
    readonly canvasLabel: Uint8Array;
    readonly title: Uint8Array;
    readonly width: number;
    readonly height: number;
    readonly x: number | null;
    readonly y: number | null;
    readonly resizable: boolean;
    readonly restorePolicy: WindowRestorePolicy;
    readonly minWidth: number;
    readonly minHeight: number;
    readonly titlebar: WindowTitlebarStyle;
    readonly transparent: boolean;
    readonly alwaysOnTop: boolean;
    readonly clickThrough: boolean;
    readonly activateOnShow: boolean;
    readonly allowsFullscreen: boolean;
    readonly closePolicy: WindowClosePolicy;
    readonly onCloseCommand: Uint8Array;
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
/** Retained main-canvas slider observation at the update/rebuild boundary.
 * Ids retain all native bits; values are the applied native f32 widened exactly. */
export interface SliderState {
    readonly id: Uint8Array;
    readonly label: Uint8Array;
    readonly value: number;
}
export interface FrameEvent {
    readonly width: number;
    readonly height: number;
    readonly timestampMs: number;
    readonly intervalMs: number;
    readonly timestampNs: Uint8Array;
    readonly intervalNs: Uint8Array;
}
export type CanvasFrameRisk = "idle" | "low" | "moderate" | "high";
export interface CanvasFrameEvent {
    readonly width: number;
    readonly height: number;
    readonly timestampNs: Uint8Array;
    readonly intervalNs: Uint8Array;
    readonly risk: CanvasFrameRisk;
    readonly workUnits: Uint8Array;
    readonly commands: Uint8Array;
    readonly batches: Uint8Array;
    readonly representable: boolean;
    readonly dirtyRatio: number;
}
export interface CanvasColor {
    readonly r: number;
    readonly g: number;
    readonly b: number;
    readonly a: number;
}
export interface CanvasRect {
    readonly x: number;
    readonly y: number;
    readonly width: number;
    readonly height: number;
}
export interface CanvasPoint {
    readonly x: number;
    readonly y: number;
}
export interface CanvasGradientStop {
    readonly offset: number;
    readonly color: CanvasColor;
}
export type CanvasFill = {
    readonly kind: "color";
    readonly color: CanvasColor;
} | {
    readonly kind: "linear_gradient";
    readonly start: CanvasPoint;
    readonly end: CanvasPoint;
    readonly stops: readonly CanvasGradientStop[];
};
export interface CanvasStroke {
    readonly fill: CanvasFill;
    readonly width: number;
}
export interface CanvasRadius {
    readonly topLeft: number;
    readonly topRight: number;
    readonly bottomRight: number;
    readonly bottomLeft: number;
}
export type CanvasPathVerb = "move_to" | "line_to" | "quad_to" | "cubic_to" | "close";
export type CanvasLineCap = "butt" | "round";
export interface CanvasPathElement {
    readonly verb: CanvasPathVerb;
    readonly first: CanvasPoint;
    readonly second: CanvasPoint;
    readonly third: CanvasPoint;
}
export type CanvasIconPaint = {
    readonly kind: "none";
} | {
    readonly kind: "current_color";
} | {
    readonly kind: "color";
    readonly color: CanvasColor;
};
export type CanvasIconLineJoin = "miter" | "round";
export interface CanvasIconShape {
    readonly start: number;
    readonly count: number;
    readonly fill: CanvasIconPaint;
    readonly stroke: CanvasIconPaint;
    readonly strokeWidth: number;
    readonly linecap: CanvasLineCap;
    readonly linejoin: CanvasIconLineJoin;
}
export interface CanvasIconDefinition {
    readonly name: Uint8Array;
    readonly viewBox: CanvasRect;
    readonly elements: readonly CanvasPathElement[];
    readonly shapes: readonly CanvasIconShape[];
}
export type CanvasChromeCommand = {
    readonly kind: "rect";
    readonly id: Uint8Array;
    readonly rect: CanvasRect;
    readonly fill: CanvasFill;
} | {
    readonly kind: "rounded_rect";
    readonly id: Uint8Array;
    readonly rect: CanvasRect;
    readonly radius: number;
    readonly fill: CanvasFill;
} | {
    readonly kind: "stroke_rect";
    readonly id: Uint8Array;
    readonly rect: CanvasRect;
    readonly radius: CanvasRadius;
    readonly stroke: CanvasStroke;
} | {
    readonly kind: "line";
    readonly id: Uint8Array;
    readonly from: CanvasPoint;
    readonly to: CanvasPoint;
    readonly stroke: CanvasStroke;
} | {
    readonly kind: "fill_path";
    readonly id: Uint8Array;
    readonly elements: readonly CanvasPathElement[];
    readonly fill: CanvasFill;
} | {
    readonly kind: "stroke_path";
    readonly id: Uint8Array;
    readonly elements: readonly CanvasPathElement[];
    readonly stroke: CanvasStroke;
    readonly cap: CanvasLineCap;
};
export interface CanvasChromeContext {
    readonly width: number;
    readonly height: number;
    readonly background: CanvasColor;
    readonly surface: CanvasColor;
    readonly border: CanvasColor;
    readonly text: CanvasColor;
}
export interface CanvasTransform {
    readonly a: number;
    readonly b: number;
    readonly c: number;
    readonly d: number;
    readonly tx: number;
    readonly ty: number;
}
export type CanvasAnimationPart = "fill" | "text";
export type CanvasAnimationLoop = "none" | "wrap" | "ping_pong";
export interface CanvasAnimation {
    readonly label: Uint8Array;
    readonly index: number;
    readonly part: CanvasAnimationPart;
    readonly durationMs: number;
    readonly easing: LayoutTweenEasing;
    readonly loop: CanvasAnimationLoop;
    readonly fromOpacity: number;
    readonly toOpacity: number;
    readonly fromTransform: CanvasTransform;
    readonly toTransform: CanvasTransform;
}
export type LayoutTweenEasing = "linear" | "standard" | "emphasized" | "spring";
export interface LayoutTween {
    readonly label: Uint8Array | null;
    readonly index: number;
    readonly to: number;
    readonly durationMs: number;
    readonly easing: LayoutTweenEasing;
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
/** Complete native audio report with exact canonical unsigned decimal bytes
 * for the caller's key and both millisecond counters. */
export interface ExactAudioEvent {
    readonly key: Uint8Array;
    readonly state: AudioState;
    readonly positionMs: Uint8Array;
    readonly durationMs: Uint8Array;
    readonly playing: boolean;
    readonly buffering: boolean;
    readonly bands: Uint8Array;
}
/** Commands for the single native player. Seek positions are canonical
 * unsigned decimal bytes; volume is remembered while the player is idle. */
export type AudioTransport = {
    readonly kind: "pause";
} | {
    readonly kind: "play";
} | {
    readonly kind: "stop";
} | {
    readonly kind: "seek";
    readonly positionMs: Uint8Array;
} | {
    readonly kind: "volume";
    readonly value: number;
};
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
/** Retained viewport facts supplied to a windowed-list row query. */
export interface VirtualListRange {
    readonly start_index: number;
    readonly end_index: number;
    readonly first_visible_index: number;
    readonly last_visible_index: number;
    readonly item_extent: number;
    readonly item_gap: number;
    readonly scroll_offset: number;
    readonly layout_offset: number;
    readonly content_extent: number;
    readonly before_extent: number;
    readonly after_extent: number;
    readonly anchor_extent: number;
}
