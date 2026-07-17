// @native-sdk/core/events — the canonical event record types the host and
// markup deliver into an app core, an SDK LIBRARY module: pure type
// declarations in the app-core subset, emitted into your core when imported
// and absent when not. Under node the same file resolves as-is.
//
// Every record here matches, field for field, the structural shape a
// runtime matcher expects — markup's `on-input`/`on-scroll` mirrors
// (`declaredTextInputUnion`/`declaredScrollStateRecord`), the generated
// wiring's channel builders (`frameMsg`/`keyMsg`/`appearanceMsg`/
// `chromeMsg`), and the audio event arm validator. Matching stays
// STRUCTURAL either way (type identity cannot cross the emission
// boundary), so declaring the same shape in your own core remains legal;
// these exports exist so no core has to re-type the vocabulary and no
// hand-rolled mirror can drift. One home per type: the text-input family
// lives with the byte-splice engine in `@native-sdk/core/text` and is
// re-exported here, so `@native-sdk/core/events` resolves every event
// record an app binds. (Importing this module pulls `./text.ts` into the
// emitted core with it; unused engine functions cost source lines, never
// binary — Zig compiles only what the core references.)
//
// Names are unique across a core's whole module graph (NS1038): a core
// that imports one of these types cannot also declare its own record
// under the same name — delete the in-file mirror and import it instead.
//
// How each type is bound:
//   - `TextInputEvent`, `ScrollState`: Msg-arm PAYLOAD fields —
//     `{ kind: "draft_edit"; edit: TextInputEvent }`,
//     `{ kind: "scrolled"; scroll: ScrollState }`.
//   - `FrameEvent`, `KeyEvent`, `PinchEvent`: the wiring channels'
//     parameter records — `frameMsg(model, frame: FrameEvent)`,
//     `keyMsg(key: KeyEvent)`, `pinchMsg(pinch: PinchEvent)`.
//   - `ColorScheme`, `ChromeInsets`, `ChromeButtons`, `AudioState`: field
//     types INSIDE the arm records the `appearanceMsg`/`chromeMsg`/audio
//     routes name (the arms themselves stay inline unions of `kind` plus
//     the event's fields — the subset has no intersection arms).
//   - `AppearanceEvent`, `ChromeEvent`, `AudioEvent`: the full arm
//     payload shapes, canonical and importable for helper signatures
//     (an arm value is structurally assignable to its event record).

export type { TextCaretDirection, TextCaretMove, TextSelection, TextInputEvent } from "./text.ts";

/// The scroll-state mirror markup's `on-scroll` matches structurally: a
/// record of exactly these four numeric fields. Offsets and extents are
/// canvas points; `velocity` is points per second while a fling decays.
/// Echo `offset` into the model field bound as the scroll's `value` to
/// keep the region model-driven (setting that field in update scrolls it).
export interface ScrollState {
  readonly offset: number;
  readonly velocity: number;
  readonly viewportExtent: number;
  readonly contentExtent: number;
}

/// The presented-frame channel's record (`frameMsg(model, frame)`): the
/// canvas size in points plus the frame clock in fractional milliseconds.
/// Return null from `frameMsg` for frames that change nothing — the idle
/// law holds exactly when an idle app dispatches nothing.
export interface FrameEvent {
  readonly width: number;
  readonly height: number;
  readonly timestampMs: number;
  readonly intervalMs: number;
}

/// The key-fallback channel's record (`keyMsg(key)`): the key NAME arrives
/// lowercased ("space", "arrowleft"), plus the four modifier booleans. A
/// focused widget's own keys and editable text always win first.
export interface KeyEvent {
  readonly key: string;
  readonly shift: boolean;
  readonly control: boolean;
  readonly alt: boolean;
  readonly super: boolean;
}

/// The pinch phase vocabulary — a NAMED begin/change/end alias (the host
/// matches enum members by name, so this is the `phase` field's type in
/// `pinchMsg`'s parameter record). A host-cancelled gesture folds into
/// "end": pinch delivers incremental deltas the app applies as they
/// arrive, so there is no transient state to roll back. A terminal host
/// event that still measured a nonzero delta delivers it as a final
/// "change" before the "end", so the cumulative product always matches
/// what the OS reported.
export type PinchPhase = "begin" | "change" | "end";

/// The pinch channel's record (`pinchMsg(pinch)`): the trackpad pinch
/// gesture, phase-explicit. `windowId`/`label` name the source window and
/// gpu-surface view — `x`/`y` are view-local, so a coordinate without its
/// view is not a position, and multi-window apps tell pinches apart by
/// these. `scale` is the magnification DELTA for this event (nonzero
/// only on "change"), and the delta is MULTIPLICATIVE: the cumulative
/// gesture scale is the running product of `1 + scale` — apply it
/// memorylessly, `zoom *= 1 + scale`, no gesture-start bookkeeping. On
/// macOS this is AppKit's raw per-event `NSEvent.magnification`, which
/// IS that multiplicative delta per the browser-engine convention, so
/// the product matches the zoom the same gesture performs in Safari and
/// Chrome. `x`/`y` is the pointer anchor in view-local canvas
/// points — the pointer location during the gesture (hosts report gesture
/// events at the pointer, not at a midpoint between the fingers), so a
/// zoom can anchor under the cursor. Pinch is a view-global gesture — it
/// never routes through widgets — so this is the honest home for timeline
/// and canvas zoom. Only hosts with a pinch source emit it (macOS today).
export interface PinchEvent {
  readonly windowId: number;
  readonly label: string;
  readonly phase: PinchPhase;
  readonly scale: number;
  readonly x: number;
  readonly y: number;
}

/// The appearance vocabulary — a NAMED light/dark alias (the host matches
/// enum members by name, so this is the `colorScheme` field's type in the
/// arm `appearanceMsg` names).
export type ColorScheme = "light" | "dark";

/// The appearance arm's payload shape, whole: what the system appearance
/// channel delivers into the arm `appearanceMsg` names. The arm itself
/// stays an inline union member carrying exactly these fields plus `kind`.
export interface AppearanceEvent {
  readonly colorScheme: ColorScheme;
  readonly reduceMotion: boolean;
  readonly highContrast: boolean;
}

/// The chrome arm's insets record: the window-chrome band (hidden-titlebar
/// geometry) in canvas points.
export interface ChromeInsets {
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
  readonly left: number;
}

/// The chrome arm's traffic-light record: the window buttons' frame in
/// canvas points.
export interface ChromeButtons {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/// The chrome arm's payload shape, whole: what the window-chrome channel
/// delivers into the arm `chromeMsg` names — delivered before the first
/// view build and again whenever the geometry changes.
export interface ChromeEvent {
  readonly insets: ChromeInsets;
  readonly buttons: ChromeButtons;
  readonly tabsProjected: boolean;
}

/// The audio event states, mirroring the engine's event vocabulary:
/// `loaded` acknowledges a successful load with the player's duration
/// estimate; `position` ticks at the platform's honest cadence (~500ms)
/// while playing; `completed` fires exactly once at the natural end;
/// `failed` reports a load/decode/device failure; `rejected` a command the
/// effects layer refused; `spectrum` carries a band-magnitude analysis
/// frame from hosts that analyze their playback.
export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum";

/// The audio event arm's payload shape, whole — the one SDK-fixed record,
/// six fields matched by NAME: `positionMs`/`durationMs` are milliseconds,
/// `playing` is the transport state, `buffering` is true while a streamed
/// source stalls waiting for bytes, and `bands` is the 32 spectrum band
/// magnitudes (0..255 each, all zeros outside "spectrum" events).
export interface AudioEvent {
  readonly state: AudioState;
  readonly positionMs: number;
  readonly durationMs: number;
  readonly playing: boolean;
  readonly buffering: boolean;
  readonly bands: Uint8Array;
}
