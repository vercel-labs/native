// The transpiler gate fixture: an idiomatic app core written in the
// TypeScript subset — pure `update(model, msg): Model`, immutable model built
// with spreads/map/filter, discriminated unions, Uint8Array for text bytes.
// Its native run1k digest must match the hand-written oracle's byte for byte.
//
// Subset rules exercised here:
//   - interfaces with readonly fields; no classes
//   - discriminated unions with a `kind` tag
//   - spread updates `{ ...model, field: v }`, array spread, map/filter
//   - Uint8Array as the byte-string type (subarray = view, slice = copy)
//   - locals may be reassigned; update inputs are never mutated
//   - fresh Uint8Array may be written to until it escapes (builder rule)
//   - the SDK asciiBytes intrinsic folds literals/templates into bytes

import { asciiBytes } from "@native-sdk/core";

// ------------------------------------------------------------------ tuning

export const MAX_TASKS = 64;
export const MAX_TASK_TITLE = 32;
export const HEADER_NATURAL_HEIGHT = 52;

export type Bytes = Uint8Array;

// ------------------------------------------------------------- text engine

export interface TextRange {
  readonly start: number;
  readonly end: number;
}

export interface TextSelection {
  readonly anchor: number;
  readonly focus: number;
}

export type TextCaretDirection =
  | "previous"
  | "next"
  | "previous_word"
  | "next_word"
  | "start"
  | "end";

export interface TextCaretMove {
  readonly direction: TextCaretDirection;
  readonly extend: boolean;
}

export type TextInputEvent =
  | { readonly kind: "insert_text"; readonly text: Bytes }
  | { readonly kind: "delete_backward" }
  | { readonly kind: "delete_forward" }
  | { readonly kind: "delete_word_backward" }
  | { readonly kind: "delete_word_forward" }
  | { readonly kind: "clear" }
  | { readonly kind: "move_caret"; readonly move: TextCaretMove }
  | { readonly kind: "set_selection"; readonly selection: TextSelection }
  | { readonly kind: "set_composition"; readonly text: Bytes; readonly cursor: number | null }
  | { readonly kind: "commit_composition" }
  | { readonly kind: "cancel_composition" };

interface TextEditState {
  readonly text: Bytes;
  readonly selection: TextSelection;
  readonly composition: TextRange | null;
}

function rangeNormalized(r: TextRange, textLen: number): TextRange {
  const start = Math.min(r.start, textLen);
  const end = Math.min(r.end, textLen);
  return start <= end ? { start: start, end: end } : { start: end, end: start };
}

function rangeByteLen(r: TextRange, textLen: number): number {
  const n = rangeNormalized(r, textLen);
  return n.end - n.start;
}

function rangeIsCollapsed(r: TextRange, textLen: number): boolean {
  const n = rangeNormalized(r, textLen);
  return n.start === n.end;
}

function selectionRange(s: TextSelection, textLen: number): TextRange {
  return rangeNormalized({ start: s.anchor, end: s.focus }, textLen);
}

export function isUtf8ContinuationByte(byte: number): boolean {
  return (byte & 0xc0) === 0x80;
}

export function utf8SequenceLength(lead: number): number {
  if ((lead & 0x80) === 0) return 1;
  if ((lead & 0xe0) === 0xc0) return 2;
  if ((lead & 0xf0) === 0xe0) return 3;
  if ((lead & 0xf8) === 0xf0) return 4;
  return 1;
}

export function snapTextOffset(text: Bytes, offset: number): number {
  let cursor = Math.min(offset, text.length);
  while (cursor > 0 && cursor < text.length && isUtf8ContinuationByte(text[cursor])) {
    cursor -= 1;
  }
  return cursor;
}

export function previousTextOffset(text: Bytes, offset: number): number {
  let cursor = snapTextOffset(text, offset);
  if (cursor === 0) return 0;
  cursor -= 1;
  while (cursor > 0 && isUtf8ContinuationByte(text[cursor])) {
    cursor -= 1;
  }
  return cursor;
}

export function nextTextOffset(text: Bytes, offset: number): number {
  const cursor = snapTextOffset(text, offset);
  if (cursor >= text.length) return text.length;
  const next = Math.min(text.length, cursor + utf8SequenceLength(text[cursor]));
  // Fallback-scalar rule for invalid UTF-8: never stall or reverse the walk
  // on an orphan continuation byte.
  if (next <= offset) return Math.min(text.length, offset + 1);
  return next;
}

function isAsciiAlphanumeric(b: number): boolean {
  return (
    (b >= 0x30 && b <= 0x39) ||
    (b >= 0x41 && b <= 0x5a) ||
    (b >= 0x61 && b <= 0x7a)
  );
}

function isAsciiWhitespace(b: number): boolean {
  return b === 0x20 || b === 0x09 || b === 0x0a || b === 0x0d || b === 0x0b || b === 0x0c;
}

type TextRunClass = 0 | 1 | 2; // word, space, other

function textRunClassAt(text: Bytes, offset: number): TextRunClass | null {
  const cursor = snapTextOffset(text, offset);
  if (cursor >= text.length) return null;
  const lead = text[cursor];
  if ((lead & 0x80) !== 0) return 0;
  if (isAsciiAlphanumeric(lead) || lead === 0x5f) return 0;
  if (isAsciiWhitespace(lead)) return 1;
  return 2;
}

function textOffsetStartsWord(text: Bytes, offset: number): boolean {
  const cls = textRunClassAt(text, offset);
  return cls !== null && cls === 0;
}

export function previousTextWordOffset(text: Bytes, offset: number): number {
  let cursor = snapTextOffset(text, offset);
  while (cursor > 0) {
    const previous = previousTextOffset(text, cursor);
    if (textOffsetStartsWord(text, previous)) break;
    cursor = previous;
  }
  while (cursor > 0) {
    const previous = previousTextOffset(text, cursor);
    if (!textOffsetStartsWord(text, previous)) break;
    cursor = previous;
  }
  return cursor;
}

export function nextTextWordOffset(text: Bytes, offset: number): number {
  let cursor = snapTextOffset(text, offset);
  while (cursor < text.length && !textOffsetStartsWord(text, cursor)) {
    cursor = nextTextOffset(text, cursor);
  }
  while (cursor < text.length && textOffsetStartsWord(text, cursor)) {
    cursor = nextTextOffset(text, cursor);
  }
  return cursor;
}

function snapTextSelection(text: Bytes, selection: TextSelection): TextSelection {
  return {
    anchor: snapTextOffset(text, selection.anchor),
    focus: snapTextOffset(text, selection.focus),
  };
}

function snapTextRange(text: Bytes, range: TextRange): TextRange {
  const normalized = rangeNormalized(range, text.length);
  return rangeNormalized(
    {
      start: snapTextOffset(text, normalized.start),
      end: snapTextOffset(text, normalized.end),
    },
    text.length,
  );
}

interface TextReplaceResult {
  readonly text: Bytes;
  readonly insertedStart: number;
  readonly insertedEnd: number;
}

// Returns null when the result would exceed `capacity` (the oracle's
// error.TextEditBufferTooSmall seam).
function replaceTextRange(
  source: Bytes,
  range: TextRange,
  replacement: Bytes,
  capacity: number,
): TextReplaceResult | null {
  const snapped = snapTextRange(source, range);
  const prefixLen = snapped.start;
  const suffixStart = prefixLen + replacement.length;
  const nextLen = prefixLen + replacement.length + (source.length - snapped.end);
  if (nextLen > capacity) return null;
  const out = new Uint8Array(nextLen);
  out.set(source.subarray(0, prefixLen), 0);
  out.set(replacement, prefixLen);
  out.set(source.subarray(snapped.end), suffixStart);
  return { text: out, insertedStart: prefixLen, insertedEnd: suffixStart };
}

function normalizeTextEditState(state: TextEditState): TextEditState {
  return {
    text: state.text,
    selection: snapTextSelection(state.text, state.selection),
    composition:
      state.composition !== null ? snapTextRange(state.text, state.composition) : null,
  };
}

function activeTextReplaceRange(state: TextEditState): TextRange {
  if (state.composition !== null) return snapTextRange(state.text, state.composition);
  return selectionRange(state.selection, state.text.length);
}

function replaceTextEditRange(
  state: TextEditState,
  range: TextRange,
  replacement: Bytes,
  capacity: number,
  composition: TextRange | null,
  cursorOffset: number,
): TextEditState | null {
  const result = replaceTextRange(state.text, range, replacement, capacity);
  if (result === null) return null;
  const cursor = snapTextOffset(
    result.text,
    result.insertedStart + Math.min(cursorOffset, replacement.length),
  );
  return {
    text: result.text,
    selection: { anchor: cursor, focus: cursor },
    composition: composition,
  };
}

function setTextComposition(
  state: TextEditState,
  text: Bytes,
  cursorIn: number | null,
  capacity: number,
): TextEditState | null {
  const range = activeTextReplaceRange(state);
  const cursor = snapTextOffset(text, cursorIn === null ? text.length : cursorIn);
  const result = replaceTextRange(state.text, range, text, capacity);
  if (result === null) return null;
  const absoluteCursor = snapTextOffset(result.text, result.insertedStart + cursor);
  return {
    text: result.text,
    selection: { anchor: absoluteCursor, focus: absoluteCursor },
    composition: { start: result.insertedStart, end: result.insertedEnd },
  };
}

function cancelTextComposition(state: TextEditState, capacity: number): TextEditState | null {
  if (state.composition === null) return state;
  const range = snapTextRange(state.text, state.composition);
  const result = replaceTextRange(state.text, range, new Uint8Array(0), capacity);
  if (result === null) return null;
  return {
    text: result.text,
    selection: { anchor: result.insertedStart, focus: result.insertedStart },
    composition: null,
  };
}

function deleteBackwardTextEdit(state: TextEditState, capacity: number): TextEditState | null {
  const range = activeTextReplaceRange(state);
  if (!rangeIsCollapsed(range, state.text.length)) {
    return replaceTextEditRange(state, range, new Uint8Array(0), capacity, null, 0);
  }
  const caret = snapTextOffset(state.text, state.selection.focus);
  if (caret === 0) {
    return { text: state.text, selection: { anchor: 0, focus: 0 }, composition: null };
  }
  return replaceTextEditRange(
    state,
    { start: previousTextOffset(state.text, caret), end: caret },
    new Uint8Array(0),
    capacity,
    null,
    0,
  );
}

function deleteForwardTextEdit(state: TextEditState, capacity: number): TextEditState | null {
  const range = activeTextReplaceRange(state);
  if (!rangeIsCollapsed(range, state.text.length)) {
    return replaceTextEditRange(state, range, new Uint8Array(0), capacity, null, 0);
  }
  const caret = snapTextOffset(state.text, state.selection.focus);
  if (caret >= state.text.length) {
    const len = state.text.length;
    return { text: state.text, selection: { anchor: len, focus: len }, composition: null };
  }
  return replaceTextEditRange(
    state,
    { start: caret, end: nextTextOffset(state.text, caret) },
    new Uint8Array(0),
    capacity,
    null,
    0,
  );
}

function deleteWordBackwardTextEdit(
  state: TextEditState,
  capacity: number,
): TextEditState | null {
  const range = activeTextReplaceRange(state);
  if (!rangeIsCollapsed(range, state.text.length)) {
    return replaceTextEditRange(state, range, new Uint8Array(0), capacity, null, 0);
  }
  const caret = snapTextOffset(state.text, state.selection.focus);
  if (caret === 0) {
    return { text: state.text, selection: { anchor: 0, focus: 0 }, composition: null };
  }
  return replaceTextEditRange(
    state,
    { start: previousTextWordOffset(state.text, caret), end: caret },
    new Uint8Array(0),
    capacity,
    null,
    0,
  );
}

function deleteWordForwardTextEdit(
  state: TextEditState,
  capacity: number,
): TextEditState | null {
  const range = activeTextReplaceRange(state);
  if (!rangeIsCollapsed(range, state.text.length)) {
    return replaceTextEditRange(state, range, new Uint8Array(0), capacity, null, 0);
  }
  const caret = snapTextOffset(state.text, state.selection.focus);
  if (caret >= state.text.length) {
    const len = state.text.length;
    return { text: state.text, selection: { anchor: len, focus: len }, composition: null };
  }
  return replaceTextEditRange(
    state,
    { start: caret, end: nextTextWordOffset(state.text, caret) },
    new Uint8Array(0),
    capacity,
    null,
    0,
  );
}

function moveTextCaret(state: TextEditState, move: TextCaretMove): TextEditState {
  const range = selectionRange(state.selection, state.text.length);
  const focus = snapTextOffset(state.text, state.selection.focus);
  const collapsed = rangeIsCollapsed(range, state.text.length);
  let target: number;
  if (move.direction === "previous") {
    target = !move.extend && !collapsed ? range.start : previousTextOffset(state.text, focus);
  } else if (move.direction === "next") {
    target = !move.extend && !collapsed ? range.end : nextTextOffset(state.text, focus);
  } else if (move.direction === "previous_word") {
    target =
      !move.extend && !collapsed ? range.start : previousTextWordOffset(state.text, focus);
  } else if (move.direction === "next_word") {
    target = !move.extend && !collapsed ? range.end : nextTextWordOffset(state.text, focus);
  } else if (move.direction === "start") {
    target = 0;
  } else {
    target = state.text.length;
  }
  const selection: TextSelection = move.extend
    ? { anchor: state.selection.anchor, focus: target }
    : { anchor: target, focus: target };
  return {
    text: state.text,
    selection: snapTextSelection(state.text, selection),
    composition: null,
  };
}

function applyTextInputEvent(
  state: TextEditState,
  event: TextInputEvent,
  capacity: number,
): TextEditState | null {
  const normalized = normalizeTextEditState(state);
  switch (event.kind) {
    case "insert_text":
      return replaceTextEditRange(
        normalized,
        activeTextReplaceRange(normalized),
        event.text,
        capacity,
        null,
        event.text.length,
      );
    case "delete_backward":
      return deleteBackwardTextEdit(normalized, capacity);
    case "delete_forward":
      return deleteForwardTextEdit(normalized, capacity);
    case "delete_word_backward":
      return deleteWordBackwardTextEdit(normalized, capacity);
    case "delete_word_forward":
      return deleteWordForwardTextEdit(normalized, capacity);
    case "clear":
      return { text: new Uint8Array(0), selection: { anchor: 0, focus: 0 }, composition: null };
    case "move_caret":
      return moveTextCaret(normalized, event.move);
    case "set_selection":
      return {
        text: normalized.text,
        selection: snapTextSelection(normalized.text, event.selection),
        composition: null,
      };
    case "set_composition":
      return setTextComposition(normalized, event.text, event.cursor, capacity);
    case "commit_composition":
      return {
        text: normalized.text,
        selection: normalized.selection,
        composition: null,
      };
    case "cancel_composition":
      return cancelTextComposition(normalized, capacity);
  }
}

// For an over-capacity insert_text, the same event with its payload clamped
// (at a UTF-8 boundary) to the bytes that fit. Null when not an insertion or
// nothing fits.
function clampedInsertEvent(
  state: TextEditState,
  event: TextInputEvent,
  capacity: number,
): TextInputEvent | null {
  if (event.kind !== "insert_text") return null;
  const insertion = event.text;
  const normalized = normalizeTextEditState(state);
  const replaced = rangeByteLen(activeTextReplaceRange(normalized), normalized.text.length);
  const kept = normalized.text.length - replaced;
  if (kept >= capacity) return null;
  const available = capacity - kept;
  if (available >= insertion.length) return null;
  const clampedLen = snapTextOffset(insertion, available);
  if (clampedLen === 0) return null;
  return { kind: "insert_text", text: insertion.subarray(0, clampedLen) };
}

// ------------------------------------------------------------------- draft

// Fixed-capacity editor state, mirroring the runtime's TextBuffer. Immutable:
// draftApply returns a new Draft.
export interface Draft {
  readonly bytes: Bytes;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number; // -1 when no composition
  readonly compEnd: number;
  readonly truncated: boolean;
}

export function draftInit(): Draft {
  return {
    bytes: new Uint8Array(0),
    anchor: 0,
    focus: 0,
    compStart: -1,
    compEnd: -1,
    truncated: false,
  };
}

function draftState(d: Draft): TextEditState {
  return {
    text: d.bytes,
    selection: { anchor: d.anchor, focus: d.focus },
    composition: d.compStart >= 0 ? { start: d.compStart, end: d.compEnd } : null,
  };
}

function draftCommit(next: TextEditState, truncated: boolean): Draft {
  const nextLen = Math.min(next.text.length, MAX_TASK_TITLE);
  return {
    bytes: next.text.slice(0, nextLen),
    anchor: next.selection.anchor,
    focus: next.selection.focus,
    compStart: next.composition !== null ? next.composition.start : -1,
    compEnd: next.composition !== null ? next.composition.end : -1,
    truncated: truncated,
  };
}

export function draftApply(d: Draft, event: TextInputEvent): Draft {
  const state = draftState(d);
  const next = applyTextInputEvent(state, event, MAX_TASK_TITLE);
  if (next === null) {
    const clamped = clampedInsertEvent(state, event, MAX_TASK_TITLE);
    if (clamped === null) return { ...d, truncated: true };
    const nextClamped = applyTextInputEvent(state, clamped, MAX_TASK_TITLE);
    if (nextClamped === null) return { ...d, truncated: true };
    return draftCommit(nextClamped, true);
  }
  return draftCommit(next, false);
}

// Clearing preserves `truncated` — it reports the most recent apply, matching
// the oracle.
export function draftClear(d: Draft): Draft {
  return { ...d, bytes: new Uint8Array(0), anchor: 0, focus: 0, compStart: -1, compEnd: -1 };
}

export function draftIsEmpty(d: Draft): boolean {
  // std.mem.trim(u8, text, " \t").len == 0
  let start = 0;
  let end = d.bytes.length;
  while (start < end && (d.bytes[start] === 0x20 || d.bytes[start] === 0x09)) start += 1;
  while (end > start && (d.bytes[end - 1] === 0x20 || d.bytes[end - 1] === 0x09)) end -= 1;
  return end - start === 0;
}

// ------------------------------------------------------------------- model

export type Filter = "all" | "active" | "done";

export interface Task {
  readonly id: number;
  readonly title: Bytes; // UTF-8, max MAX_TASK_TITLE bytes
  readonly done: boolean;
}

export interface Model {
  readonly tasks: readonly Task[];
  readonly nextId: number;
  readonly filter: Filter;
  readonly chromeLeading: number;
  readonly headerHeight: number;
  readonly draft: Draft;
}

function addTask(model: Model, text: Bytes): Model {
  if (model.tasks.length >= MAX_TASKS) return model;
  const task: Task = {
    id: model.nextId,
    title: text.slice(0, Math.min(text.length, MAX_TASK_TITLE)),
    done: false,
  };
  return { ...model, tasks: [...model.tasks, task], nextId: model.nextId + 1 };
}

function addGeneratedTask(model: Model): Model {
  return addTask(model, asciiBytes(`Task ${model.nextId}`));
}

export function openCount(model: Model): number {
  return model.tasks.filter((t) => !t.done).length;
}

export function doneCount(model: Model): number {
  return model.tasks.length - openCount(model);
}

// --------------------------------------------------------------------- msg

export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number }
  | { readonly kind: "set_filter"; readonly filter: Filter }
  | { readonly kind: "clear_done" }
  | { readonly kind: "draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "chrome_changed"; readonly insetLeft: number; readonly insetTop: number };

// ------------------------------------------------------------------ update

function trimSpaces(bytes: Bytes): Bytes {
  // std.mem.trim(u8, draft, " ") — spaces only.
  let start = 0;
  let end = bytes.length;
  while (start < end && bytes[start] === 0x20) start += 1;
  while (end > start && bytes[end - 1] === 0x20) end -= 1;
  return bytes.subarray(start, end);
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": {
      if (draftIsEmpty(model.draft)) return addGeneratedTask(model);
      const added = addTask(model, trimSpaces(model.draft.bytes));
      return { ...added, draft: draftClear(added.draft) };
    }
    case "toggle":
      return {
        ...model,
        tasks: model.tasks.map((t) => (t.id === msg.id ? { ...t, done: !t.done } : t)),
      };
    case "set_filter":
      return { ...model, filter: msg.filter };
    case "clear_done":
      return { ...model, tasks: model.tasks.filter((t) => !t.done) };
    case "draft_edit":
      return { ...model, draft: draftApply(model.draft, msg.edit) };
    case "chrome_changed":
      return {
        ...model,
        chromeLeading: msg.insetLeft,
        headerHeight: Math.max(HEADER_NATURAL_HEIGHT, msg.insetTop),
      };
  }
}

// ------------------------------------------------------------ initial model

export function initialModel(): Model {
  let model: Model = {
    tasks: [],
    nextId: 1,
    filter: "all",
    chromeLeading: 0,
    headerHeight: HEADER_NATURAL_HEIGHT,
    draft: draftInit(),
  };
  model = addTask(model, asciiBytes("Prove the ui builder end to end"));
  model = addTask(model, asciiBytes("Rewrite gpu-dashboard with it"));
  model = addTask(model, asciiBytes("Record the authoring decisions"));
  return model;
}
