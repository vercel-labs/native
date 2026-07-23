// The markup-view fixture core: a small task board whose entire view is
// tests/ts-core/markup_view.native binding this model — a record-array
// list (for each + key), an optional scalar gate (<if>), an enum filter
// (string-literal union), bytes text, and camelCase fields that markup
// binds by their own names (the emitted struct keeps the TS spellings,
// so `{nextId}` binds `nextId`). Effects stay minimal (one
// Cmd.now) so the markup e2e suite pins the view/automation/pixel
// guarantees, not the effect vocabulary (host_e2e covers that).
// Transpiled at build time by the repo's own transpiler and driven by
// tests/ts-core/markup_e2e_tests.zig.

import { Cmd, Sub, asciiBytes } from "@native-sdk/core";
// The SDK-provided event records: the same structural shapes a core may
// declare in-file, imported instead (markup's on-input and the wiring
// channels match structurally either way — this fixture pins the import
// path end-to-end through the real markup suite).
import {
  type TextInputEvent,
  type FrameEvent,
  type KeyEvent,
  type PinchEvent,
  type ColorScheme,
  type ChromeInsets,
  type ChromeButtons,
} from "@native-sdk/core/events";

export type Filter = "all" | "open" | "done";

export interface Task {
  readonly id: number;
  readonly title: Uint8Array;
  readonly done: boolean;
}

export interface Model {
  readonly filter: Filter;
  readonly nextId: number;
  readonly doneCount: number;
  readonly banner: Uint8Array;
  readonly selected: number | null;
  readonly tasks: readonly Task[];
  readonly stampMs: number;
  readonly draft: Uint8Array;
  /// The frame channel's width mirror (the album-grid derivation shape).
  readonly canvasWidth: number;
  /// The pinch channel's cumulative zoom: the product of (1 + delta)
  /// across change events — the timeline-zoom derivation shape.
  readonly zoom: number;
  /// The pinch channel's source-identity mirrors: the windowId of the
  /// last zoom and whether its label named this fixture's canvas view
  /// (x/y are view-local, so a coordinate without its view is not a
  /// position — multi-window cores tell pinches apart by these).
  readonly zoomWindowId: number;
  readonly zoomFromBoard: boolean;
  /// The appearance channel's scheme mirror.
  readonly dark: boolean;
  /// The chrome channel's titlebar band mirror.
  readonly chromeTop: number;
  /// The media surface's producer rendezvous: the u64 surface id a
  /// Zig-tier producer targets (model data, bound by the markup).
  readonly previewSurface: number;
  /// The hover pair's containment mirror: the id of the task row the
  /// pointer stands in (0 = none) — enter sets it, the paired leave
  /// clears it, so previews/prefetch can key off it.
  readonly hoveredId: number;
}

export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number }
  | { readonly kind: "pick"; readonly id: number }
  | { readonly kind: "cycle" }
  | { readonly kind: "clear" }
  | { readonly kind: "stamp" }
  | { readonly kind: "stamped"; readonly at: number }
  | { readonly kind: "hover_row"; readonly id: number }
  | { readonly kind: "hover_off"; readonly id: number }
  | { readonly kind: "draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "canvas_resized"; readonly width: number }
  | { readonly kind: "zoomed"; readonly factor: number; readonly windowId: number; readonly fromBoard: boolean }
  | { readonly kind: "appearance_changed"; readonly colorScheme: ColorScheme; readonly reduceMotion: boolean; readonly highContrast: boolean }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean }
  | { readonly kind: "banner_set"; readonly value: Uint8Array };

/// Presented frames dispatch ONLY on a width change (the idle law: a
/// frame that changes nothing dispatches nothing, so the channel starves
/// when the app is idle).
export function frameMsg(model: Model, frame: FrameEvent): Msg | null {
  if (frame.width !== model.canvasWidth) return { kind: "canvas_resized", width: frame.width };
  return null;
}

/// The desktop key conventions on the app-level fallback: space cycles
/// the filter, plain "c" clears — modifier chords stay the chrome's.
export function keyMsg(key: KeyEvent): Msg | null {
  if (key.control || key.alt || key.super || key.shift) return null;
  if (key.key === "space") return { kind: "cycle" };
  if (key.key === "c") return { kind: "clear" };
  return null;
}

/// The pinch channel gates on the change phase (begin/end carry no
/// delta): the model compounds the cumulative zoom as the product of
/// (1 + delta), the documented gesture-scale semantics. The source
/// identity rides into the Msg so the model can pin which window and
/// view the gesture happened on.
///
/// Exported by LIST on purpose: the un-renamed entry exports the
/// declaration itself, so the wiring and the boundary-float classing
/// must treat this spelling exactly like the inline modifier — the
/// fractional deltas below (0.25 per change) must survive as f64 for
/// the zoom product to land on 1.5625.
function pinchMsg(pinch: PinchEvent): Msg | null {
  if (pinch.phase !== "change" || pinch.scale === 0) return null;
  return { kind: "zoomed", factor: 1 + pinch.scale, windowId: pinch.windowId, fromBoard: pinch.label === "ts-markup-canvas" };
}
export { pinchMsg };

export const appearanceMsg = "appearance_changed";
export const chromeMsg = "chrome_changed";
export const envMsgs = [{ env: "TS_BOARD_BANNER", msg: "banner_set" }] as const;

export function initialModel(): Model {
  return {
    filter: "all",
    nextId: 1,
    doneCount: 0,
    banner: asciiBytes("ready"),
    selected: null,
    tasks: [],
    stampMs: -1,
    draft: new Uint8Array(0),
    canvasWidth: 0,
    zoom: 1,
    zoomWindowId: 0,
    zoomFromBoard: false,
    dark: false,
    chromeTop: 0,
    previewSurface: 5,
    hoveredId: 0,
  };
}

// A deliberately small draft reducer: append, backspace, clear — enough to
// prove the markup -> core -> re-render loop; caret/selection fidelity is
// the full text engine's job (see the inbox gate fixture).
function applyDraftEdit(draft: Uint8Array, edit: TextInputEvent): Uint8Array {
  switch (edit.kind) {
    case "insert_text": {
      const out = new Uint8Array(draft.length + edit.text.length);
      out.set(draft, 0);
      out.set(edit.text, draft.length);
      return out;
    }
    case "delete_backward":
      return draft.length === 0 ? draft : draft.subarray(0, draft.length - 1);
    case "clear":
      return new Uint8Array(0);
    case "delete_forward":
    case "delete_word_backward":
    case "delete_word_forward":
    case "move_caret":
    case "set_selection":
    case "set_composition":
    case "commit_composition":
    case "cancel_composition":
      return draft;
  }
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": {
      const slot = model.nextId % 3;
      const title = slot === 0 ? asciiBytes("alpha") : slot === 1 ? asciiBytes("beta") : asciiBytes("gamma");
      const added: Task = { id: model.nextId, title: title, done: false };
      return { ...model, tasks: [...model.tasks, added], nextId: model.nextId + 1 };
    }
    case "toggle": {
      const next = model.tasks.map((t) => (t.id === msg.id ? { ...t, done: !t.done } : t));
      let done = 0;
      for (let i = 0; i < next.length; i++) {
        if (next[i].done) {
          done = done + 1;
        }
      }
      return { ...model, tasks: next, doneCount: done };
    }
    case "pick":
      return { ...model, selected: msg.id };
    case "hover_row":
      return { ...model, hoveredId: msg.id };
    case "hover_off":
      return model.hoveredId === msg.id ? { ...model, hoveredId: 0 } : model;
    case "cycle":
      return { ...model, filter: model.filter === "all" ? "open" : model.filter === "open" ? "done" : "all" };
    case "clear":
      return { ...model, tasks: [], doneCount: 0, selected: null, banner: asciiBytes("cleared") };
    case "stamp":
      return [model, Cmd.now("stamped")];
    case "stamped":
      return { ...model, stampMs: msg.at };
    case "draft_edit":
      return { ...model, draft: applyDraftEdit(model.draft, msg.edit) };
    case "canvas_resized":
      return { ...model, canvasWidth: msg.width };
    case "zoomed":
      return { ...model, zoom: model.zoom * msg.factor, zoomWindowId: msg.windowId, zoomFromBoard: msg.fromBoard };
    case "appearance_changed":
      return { ...model, dark: msg.colorScheme === "dark" };
    case "chrome_changed":
      return { ...model, chromeTop: msg.insets.top };
    case "banner_set":
      return { ...model, banner: msg.value };
  }
}
