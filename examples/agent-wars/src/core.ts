import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";

const MAX_TASK_BYTES = 4096;
const MAX_MODEL_BYTES = 128;

function concatBytes(parts: readonly Uint8Array[]): Uint8Array {
  let total = 0;
  for (const part of parts) total += part.length;
  const out = new Uint8Array(total);
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

function compareUrl(runId: number, modelA: Uint8Array, modelB: Uint8Array): Uint8Array {
  return concatBytes([
    asciiBytes(`http://127.0.0.1:43110/compare?runId=${runId}&modelA=`),
    modelA,
    asciiBytes("&modelB="),
    modelB,
  ]);
}

function stopUrl(runId: number): Uint8Array {
  return asciiBytes(`http://127.0.0.1:43110/stop?runId=${runId}`);
}

function previewViewerUrl(slot: "A" | "B"): Uint8Array {
  return asciiBytes(`http://127.0.0.1:43110/preview/${slot}/viewer?slot=${slot}`);
}

export interface Editor {
  readonly bytes: Uint8Array;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number;
  readonly compEnd: number;
}

function editorWithText(bytes: Uint8Array): Editor {
  return {
    bytes,
    anchor: 0,
    focus: 0,
    compStart: -1,
    compEnd: -1,
  };
}

function editorState(editor: Editor): TextEditState {
  return {
    text: editor.bytes,
    selection: { anchor: editor.anchor, focus: editor.focus },
    composition:
      editor.compStart >= 0
        ? { start: editor.compStart, end: editor.compEnd }
        : null,
  };
}

function editorFromState(state: TextEditState): Editor {
  const start = state.composition !== null ? state.composition.start : -1;
  const end = state.composition !== null ? state.composition.end : -1;
  return {
    bytes: state.text,
    anchor: state.selection.anchor,
    focus: state.selection.focus,
    compStart:
      start >= -1 && start <= 9007199254740991 ? Math.trunc(start) : -1,
    compEnd: end >= -1 && end <= 9007199254740991 ? Math.trunc(end) : -1,
  };
}

function editorApply(editor: Editor, event: TextInputEvent, capacity: number): Editor {
  const state = editorState(editor);
  const next = applyTextInputEvent(state, event, capacity);
  if (next !== null) return editorFromState(next);
  const clamped = clampedInsertEvent(state, event, capacity);
  if (clamped === null) return editor;
  const nextClamped = applyTextInputEvent(state, clamped, capacity);
  return nextClamped === null ? editor : editorFromState(nextClamped);
}

export type SlotPhase = "idle" | "running" | "ready" | "failed";
export type CoordinatorPhase = "starting" | "ready" | "failed";

export interface SlotStatus {
  readonly phase: SlotPhase;
  readonly message: Uint8Array;
}

export interface ModelOption {
  readonly id: Uint8Array;
  readonly label: Uint8Array;
}

// Two compact rows keep the canvas-owned picker clear of the platform WebViews.
// Add another option by placing it in either row; keep the labels short enough
// for four equal columns. The combobox text remains editable for every other
// Vercel AI Gateway model id.
const MODEL_OPTIONS_TOP: readonly ModelOption[] = [
  { id: asciiBytes("deepseek/deepseek-v4-flash-0731"), label: asciiBytes("DeepSeek V4 Flash") },
  { id: asciiBytes("openai/gpt-5.6-luna"), label: asciiBytes("GPT-5.6 Luna") },
  { id: asciiBytes("openai/gpt-5.6-sol"), label: asciiBytes("GPT-5.6 Sol") },
  { id: asciiBytes("anthropic/claude-opus-5"), label: asciiBytes("Claude Opus 5") },
];

const MODEL_OPTIONS_BOTTOM: readonly ModelOption[] = [
  { id: asciiBytes("anthropic/claude-fable-5"), label: asciiBytes("Claude Fable 5") },
  { id: asciiBytes("anthropic/claude-opus-4.8"), label: asciiBytes("Claude Opus 4.8") },
  { id: asciiBytes("moonshotai/kimi-k3"), label: asciiBytes("Kimi K3") },
  { id: asciiBytes("xai/grok-4.5"), label: asciiBytes("Grok 4.5") },
];

export interface Model {
  readonly task: Editor;
  readonly modelA: Editor;
  readonly modelB: Editor;
  readonly aPickerOpen: boolean;
  readonly bPickerOpen: boolean;
  readonly coordinatorPhase: CoordinatorPhase;
  readonly runId: number;
  readonly runActive: boolean;
  readonly stopRequested: boolean;
  readonly slotA: SlotStatus;
  readonly slotB: SlotStatus;
}

export type Msg =
  | { readonly kind: "task_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "model_a_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "model_b_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "open_a_picker" }
  | { readonly kind: "open_b_picker" }
  | { readonly kind: "close_a_picker" }
  | { readonly kind: "close_b_picker" }
  | { readonly kind: "pick_a"; readonly modelId: Uint8Array }
  | { readonly kind: "pick_b"; readonly modelId: Uint8Array }
  | { readonly kind: "compare_or_stop" }
  | { readonly kind: "sidecar_line"; readonly line: Uint8Array }
  | { readonly kind: "sidecar_exit"; readonly code: number }
  | { readonly kind: "sidecar_err"; readonly reason: Uint8Array }
  | { readonly kind: "compare_response"; readonly status: number; readonly body: Uint8Array }
  | { readonly kind: "compare_failed"; readonly reason: Uint8Array }
  | { readonly kind: "stop_response"; readonly status: number; readonly body: Uint8Array }
  | { readonly kind: "stop_failed"; readonly reason: Uint8Array };

export const viewUnbound = [
  "sidecar_line",
  "sidecar_exit",
  "sidecar_err",
  "compare_response",
  "compare_failed",
  "stop_response",
  "stop_failed",
  "task",
  "modelA",
  "modelB",
  "coordinatorPhase",
  "runId",
  "stopRequested",
  "slotA",
  "slotB",
] as const;

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    {
      task: editorWithText(
        asciiBytes(
          "Create a photorealistic, interactive Three.js hamburger with procedurally modeled buns, sesame seeds, lettuce, tomato, cheese, beef patty, onion, pickles, and sauce.",
        ),
      ),
      modelA: editorWithText(asciiBytes("deepseek/deepseek-v4-flash-0731")),
      modelB: editorWithText(asciiBytes("openai/gpt-5.6-luna")),
      aPickerOpen: false,
      bPickerOpen: false,
      coordinatorPhase: "starting",
      runId: 0,
      runActive: false,
      stopRequested: false,
      slotA: { phase: "running", message: utf8Bytes("Starting coordinator…") },
      slotB: { phase: "running", message: utf8Bytes("Starting coordinator…") },
    },
    Cmd.spawn(
      [
        asciiBytes("/usr/bin/env"),
        asciiBytes("node"),
        asciiBytes("--import"),
        asciiBytes("tsx"),
        asciiBytes("sidecar/coordinator.ts"),
      ],
      {
        key: "coordinator",
        line: "sidecar_line",
        exit: "sidecar_exit",
        err: "sidecar_err",
      },
    ),
  ];
}

export function taskText(model: Model): Uint8Array {
  return model.task.bytes;
}

export function modelAText(model: Model): Uint8Array {
  return model.modelA.bytes;
}

export function modelBText(model: Model): Uint8Array {
  return model.modelB.bytes;
}

export function modelOptionsTop(_model: Model): readonly ModelOption[] {
  return MODEL_OPTIONS_TOP;
}

export function modelOptionsBottom(_model: Model): readonly ModelOption[] {
  return MODEL_OPTIONS_BOTTOM;
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function isInputWhitespace(byte: number): boolean {
  return byte === 0x20 || byte === 0x09 || byte === 0x0a || byte === 0x0d;
}

function trimInput(bytes: Uint8Array): Uint8Array {
  let start = 0;
  let end = bytes.length;
  while (start < end && isInputWhitespace(bytes[start])) start++;
  while (end > start && isInputWhitespace(bytes[end - 1])) end--;
  return bytes.subarray(start, end);
}

function validModelId(model: Uint8Array): boolean {
  if (model.length === 0 || model.length > MAX_MODEL_BYTES) return false;
  for (const byte of model) {
    const alphaNumeric =
      (byte >= 0x30 && byte <= 0x39) ||
      (byte >= 0x41 && byte <= 0x5a) ||
      (byte >= 0x61 && byte <= 0x7a);
    if (
      !alphaNumeric &&
      byte !== 0x2e &&
      byte !== 0x5f &&
      byte !== 0x3a &&
      byte !== 0x2f &&
      byte !== 0x2d
    ) return false;
  }
  return true;
}

export function actionDisabled(model: Model): boolean {
  if (model.runActive) return model.stopRequested;
  const task = trimInput(model.task.bytes);
  const modelA = trimInput(model.modelA.bytes);
  const modelB = trimInput(model.modelB.bytes);
  return (
    model.coordinatorPhase !== "ready" ||
    task.length === 0 ||
    !validModelId(modelA) ||
    !validModelId(modelB) ||
    bytesEqual(modelA, modelB)
  );
}

export function aRunning(model: Model): boolean {
  return model.slotA.phase === "running";
}

export function aReady(model: Model): boolean {
  return model.slotA.phase === "ready";
}

export function aFailed(model: Model): boolean {
  return model.slotA.phase === "failed";
}

export function aIdle(model: Model): boolean {
  return model.slotA.phase === "idle";
}

export function aStatus(model: Model): Uint8Array {
  return model.slotA.message;
}

export function bRunning(model: Model): boolean {
  return model.slotB.phase === "running";
}

export function bReady(model: Model): boolean {
  return model.slotB.phase === "ready";
}

export function bFailed(model: Model): boolean {
  return model.slotB.phase === "failed";
}

export function bIdle(model: Model): boolean {
  return model.slotB.phase === "idle";
}

export function bStatus(model: Model): Uint8Array {
  return model.slotB.message;
}

function terminal(status: SlotStatus): boolean {
  return status.phase === "ready" || status.phase === "failed";
}

function parseRunId(bytes: Uint8Array): number {
  if (bytes.length === 0 || bytes.length > 12) return -1;
  let value = 0;
  for (let i = 0; i < bytes.length; i++) {
    const digit = bytes[i];
    if (digit < 0x30 || digit > 0x39) return -1;
    value = value * 10 + digit - 0x30;
    if (value > 9007199254740991) return -1;
  }
  return value;
}

function slotStatus(phase: Uint8Array, message: Uint8Array): SlotStatus | null {
  if (bytesEqual(phase, asciiBytes("ready"))) return { phase: "ready", message };
  if (bytesEqual(phase, asciiBytes("failed")) || bytesEqual(phase, asciiBytes("stopped"))) {
    return { phase: "failed", message };
  }
  if (
    bytesEqual(phase, asciiBytes("starting")) ||
    bytesEqual(phase, asciiBytes("working"))
  ) {
    return { phase: "running", message };
  }
  return null;
}

function finishIfTerminal(model: Model, slotA: SlotStatus, slotB: SlotStatus): Model {
  const done = terminal(slotA) && terminal(slotB);
  return {
    ...model,
    slotA,
    slotB,
    runActive: done ? false : model.runActive,
    stopRequested: done ? false : model.stopRequested,
  };
}

interface StatusParts {
  readonly kind: Uint8Array;
  readonly runId: Uint8Array;
  readonly slot: Uint8Array;
  readonly phase: Uint8Array;
  readonly message: Uint8Array;
}

function indexOfByte(bytes: Uint8Array, byte: number, start: number): number {
  for (let i = start; i < bytes.length; i++) {
    if (bytes[i] === byte) return i;
  }
  return -1;
}

function parseStatusParts(line: Uint8Array): StatusParts | null {
  const first = indexOfByte(line, 0x09, 0);
  if (first < 0) return null;
  const second = indexOfByte(line, 0x09, first + 1);
  if (second < 0) return null;
  const third = indexOfByte(line, 0x09, second + 1);
  if (third < 0) return null;
  const fourth = indexOfByte(line, 0x09, third + 1);
  if (fourth < 0 || indexOfByte(line, 0x09, fourth + 1) >= 0) return null;
  return {
    kind: line.subarray(0, first),
    runId: line.subarray(first + 1, second),
    slot: line.subarray(second + 1, third),
    phase: line.subarray(third + 1, fourth),
    message: line.subarray(fourth + 1),
  };
}

function applySidecarLine(model: Model, line: Uint8Array): Model {
  const parts = parseStatusParts(line);
  if (parts === null || !bytesEqual(parts.kind, asciiBytes("status"))) return model;
  const eventRunId = parseRunId(parts.runId);
  const slot = parts.slot;
  const phase = parts.phase;
  const message = parts.message.slice(0, 512);

  if (bytesEqual(slot, asciiBytes("server"))) {
    if (bytesEqual(phase, asciiBytes("ready"))) {
      if (model.runId !== 0) return { ...model, coordinatorPhase: "ready" };
      return {
        ...model,
        coordinatorPhase: "ready",
        slotA: { phase: "idle", message: asciiBytes("Ready to compare") },
        slotB: { phase: "idle", message: asciiBytes("Ready to compare") },
      };
    }
    return {
      ...model,
      coordinatorPhase: "failed",
      runActive: false,
      stopRequested: false,
      slotA: { phase: "failed", message },
      slotB: { phase: "failed", message },
    };
  }

  if (eventRunId !== model.runId) return model;
  const next = slotStatus(phase, message);
  if (next === null) return model;
  if (bytesEqual(slot, asciiBytes("A"))) {
    return finishIfTerminal(model, next, model.slotB);
  }
  if (bytesEqual(slot, asciiBytes("B"))) {
    return finishIfTerminal(model, model.slotA, next);
  }
  return model;
}

function failRun(model: Model, message: Uint8Array): Model {
  const clipped = message.slice(0, 512);
  return {
    ...model,
    runActive: false,
    stopRequested: false,
    slotA: terminal(model.slotA) ? model.slotA : { phase: "failed", message: clipped },
    slotB: terminal(model.slotB) ? model.slotB : { phase: "failed", message: clipped },
  };
}

export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "task_edit":
      if (model.runActive) return [model, Cmd.none];
      return [{ ...model, task: editorApply(model.task, msg.edit, MAX_TASK_BYTES) }, Cmd.none];
    case "model_a_edit":
      if (model.runActive) return [model, Cmd.none];
      return [{ ...model, modelA: editorApply(model.modelA, msg.edit, MAX_MODEL_BYTES), aPickerOpen: true }, Cmd.none];
    case "model_b_edit":
      if (model.runActive) return [model, Cmd.none];
      return [{ ...model, modelB: editorApply(model.modelB, msg.edit, MAX_MODEL_BYTES), bPickerOpen: true }, Cmd.none];
    case "open_a_picker":
      if (model.runActive) return [model, Cmd.none];
      return [{ ...model, aPickerOpen: true, bPickerOpen: false }, Cmd.none];
    case "open_b_picker":
      if (model.runActive) return [model, Cmd.none];
      return [{ ...model, bPickerOpen: true, aPickerOpen: false }, Cmd.none];
    case "close_a_picker":
      return [{ ...model, aPickerOpen: false }, Cmd.none];
    case "close_b_picker":
      return [{ ...model, bPickerOpen: false }, Cmd.none];
    case "pick_a":
      if (model.runActive) return [model, Cmd.none];
      return [{ ...model, modelA: editorWithText(msg.modelId), aPickerOpen: false }, Cmd.none];
    case "pick_b":
      if (model.runActive) return [model, Cmd.none];
      return [{ ...model, modelB: editorWithText(msg.modelId), bPickerOpen: false }, Cmd.none];
    case "compare_or_stop": {
      if (model.runActive) {
        if (model.stopRequested) return [model, Cmd.none];
        return [
          { ...model, stopRequested: true },
          Cmd.fetch(
            {
              url: stopUrl(model.runId),
              method: "POST",
              timeoutMs: 5000,
            },
            { key: "stop-control", ok: "stop_response", err: "stop_failed" },
          ),
        ];
      }
      if (actionDisabled(model)) return [model, Cmd.none];
      const nextRunId =
        model.runId >= 0 && model.runId < 9007199254740991
          ? Math.trunc(model.runId + 1)
          : 1;
      const task = trimInput(model.task.bytes);
      const modelA = trimInput(model.modelA.bytes);
      const modelB = trimInput(model.modelB.bytes);
      return [
        {
          ...model,
          task: editorWithText(task),
          modelA: editorWithText(modelA),
          modelB: editorWithText(modelB),
          aPickerOpen: false,
          bPickerOpen: false,
          runId: nextRunId,
          runActive: true,
          stopRequested: false,
          slotA: { phase: "running", message: utf8Bytes("Starting…") },
          slotB: { phase: "running", message: utf8Bytes("Starting…") },
        },
        Cmd.fetch(
          {
            url: compareUrl(nextRunId, modelA, modelB),
            method: "POST",
            headers: { "content-type": "text/plain; charset=utf-8" },
            body: task,
            timeoutMs: 5000,
          },
          { key: "compare-control", ok: "compare_response", err: "compare_failed" },
        ),
      ];
    }
    case "sidecar_line": {
      const next = applySidecarLine(model, msg.line);
      if (model.coordinatorPhase !== "ready" && next.coordinatorPhase === "ready") {
        return [
          next,
            Cmd.batch([
            Cmd.navigateWebView("preview-a", previewViewerUrl("A")),
            Cmd.navigateWebView("preview-b", previewViewerUrl("B")),
          ]),
        ];
      }
      return [next, Cmd.none];
    }
    case "sidecar_exit":
      return [
        failRun(
          { ...model, coordinatorPhase: "failed" },
          asciiBytes(`Coordinator exited (code ${msg.code})`),
        ),
        Cmd.none,
      ];
    case "sidecar_err":
      return [
        failRun(
          { ...model, coordinatorPhase: "failed" },
          msg.reason.length > 0 ? msg.reason : asciiBytes("Coordinator failed"),
        ),
        Cmd.none,
      ];
    case "compare_response":
      if (msg.status >= 200 && msg.status < 300) return [model, Cmd.none];
      return [failRun(model, asciiBytes(`Compare request failed (HTTP ${msg.status})`)), Cmd.none];
    case "compare_failed":
      return [failRun(model, msg.reason), Cmd.none];
    case "stop_response":
      if (msg.status >= 200 && msg.status < 300) return [model, Cmd.none];
      return [failRun(model, asciiBytes(`Stop request failed (HTTP ${msg.status})`)), Cmd.none];
    case "stop_failed":
      return [failRun(model, msg.reason), Cmd.none];
  }
}
