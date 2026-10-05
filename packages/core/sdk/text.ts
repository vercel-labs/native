// @native-sdk/core/text — the blessed byte-splice text engine, an SDK
// LIBRARY module: ordinary app-core subset TypeScript (unlike sdk/core.ts,
// which is intrinsic and never emits), transpiled into your core when
// imported and absent from the binary when not. Under node the same file
// runs as-is — byte for byte the same results.
//
// This is the TS counterpart of the runtime's TextBuffer, extracted from
// the soundboard and system-monitor ports (which carried identical
// private copies): UTF-8 byte splicing, caret and word movement, selection,
// IME composition, capacity-refusal with a clamped-insert recovery, ASCII
// trimming, and ASCII case-insensitive comparison. A core that binds a
// markup text control reduces the control's TextInputEvent stream over its
// draft bytes with `applyTextInputEvent`; everything is immutable — each
// call returns a new state and never touches its inputs.
//
// Offsets are BYTE offsets, always snapped to UTF-8 sequence boundaries
// before use, so a caret can never land inside a multi-byte character or
// between the two bytes of a CRLF hard-line boundary.
// Capacity is the caller's fixed byte budget (mirror your runtime
// TextBuffer's): an edit whose result would not fit returns null — the
// refuse-whole contract — and `clampedInsertEvent` recovers the one case
// with a partial meaning, an insert cut at a UTF-8 boundary to the bytes
// that fit.

/// A byte range over the text, start <= end after normalization.
export interface TextRange {
  readonly start: number;
  readonly end: number;
}

/// A selection as anchor/focus byte offsets (focus is the caret; anchor
/// stays put while shift-extending). anchor === focus is a bare caret.
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

/// The runtime text-control event vocabulary, mirrored structurally —
/// markup's `on-input` translates each control event into this union.
export type TextInputEvent =
  | { readonly kind: "insert_text"; readonly text: Uint8Array }
  | { readonly kind: "delete_backward" }
  | { readonly kind: "delete_forward" }
  | { readonly kind: "delete_word_backward" }
  | { readonly kind: "delete_word_forward" }
  | { readonly kind: "delete_to_start" }
  | { readonly kind: "delete_to_line_start" }
  | { readonly kind: "clear" }
  | { readonly kind: "move_caret"; readonly move: TextCaretMove }
  | { readonly kind: "set_selection"; readonly selection: TextSelection }
  | { readonly kind: "set_composition"; readonly text: Uint8Array; readonly cursor: number | null }
  | { readonly kind: "commit_composition" }
  | { readonly kind: "cancel_composition" };

/// One editor state: the text bytes, the selection, and the active IME
/// composition range (null when none).
export interface TextEditState {
  readonly text: Uint8Array;
  readonly selection: TextSelection;
  readonly composition: TextRange | null;
}

/** Indentation inserted by a code editor's plain Tab. Nonempty indented
 * lines vote for tabs or spaces; space widths 2–8 compete by divisibility,
 * with wider widths winning ties. A tied tab vote follows the caret's
 * current line. Unindented and ambiguous files use two spaces.
 */
export function codeIndentationInsertion(text: Uint8Array, caret: number): Uint8Array {
  let tabLines = 0, spaceLines = 0, onlySpaceIndent = 0;
  const scores = [0, 0, 0, 0, 0, 0, 0, 0, 0];
  let lineStart = 0;
  while (lineStart <= text.length) {
    let end = lineStart;
    while (end < text.length && text[end] !== 10) end += 1;
    let cursor = lineStart, spaces = 0, tabs = 0;
    while (cursor < end) {
      if (text[cursor] === 32) spaces += 1;
      else if (text[cursor] === 9) tabs += 1;
      else break;
      cursor += 1;
    }
    if (cursor < end && cursor > lineStart) {
      if (tabs > 0) tabLines += 1;
      else {
        spaceLines += 1;
        onlySpaceIndent = spaceLines === 1 ? spaces : 0;
        for (let width = 2; width <= 8; width += 1) {
          if (spaces % width === 0) scores[width] = scores[width]! + 1;
        }
      }
    }
    if (end === text.length) break;
    lineStart = end + 1;
  }
  const offset = Math.min(Math.max(caret, 0), text.length);
  let localStart = 0;
  for (let i = 0; i < offset; i += 1) if (text[i] === 10) localStart = i + 1;
  if (tabLines > spaceLines || tabLines === spaceLines && tabLines > 0 && localStart < text.length && text[localStart] === 9) {
    const result = new Uint8Array(1); result[0] = 9; return result;
  }
  let inferred = 2;
  if (spaceLines === 1) {
    if (onlySpaceIndent >= 2 && onlySpaceIndent <= 8) inferred = onlySpaceIndent;
  } else if (spaceLines > 1) {
    let bestWidth = 2, bestScore = 0;
    for (let width = 2; width <= 8; width += 1) {
      const score = scores[width]!;
      if (score > bestScore || score === bestScore && score > 0 && width > bestWidth) {
        bestWidth = width; bestScore = score;
      }
    }
    if (bestScore * 2 >= spaceLines) inferred = bestWidth;
  }
  const result = new Uint8Array(inferred);
  for (let i = 0; i < inferred; i += 1) result[i] = 32;
  return result;
}

/** Parse one-based code diff lines, such as `2-4, 7`. Lines are unique,
 * retain author order, and range from 1 through 128. Empty ASCII-whitespace
 * text produces no lines; malformed pieces or descending ranges return null.
 * Decimal names accept a leading + and interior underscores, matching the
 * native markup parser. Returns a fresh array; source bytes are never changed.
 */
export function parseCodeLineNumberSpec(spec: Uint8Array): number[] | null {
  let start = 0, end = spec.length;
  while (start < end && codeSpecWhitespace(spec[start], true)) start += 1;
  while (end > start && codeSpecWhitespace(spec[end - 1], true)) end -= 1;
  const result: number[] = [];
  const seen = new Uint8Array(129);
  while (start < end) {
    let after = start;
    while (after < end && spec[after] !== 44) after += 1;
    let firstByte = start, lastByte = after;
    while (firstByte < lastByte && codeSpecWhitespace(spec[firstByte], true)) firstByte += 1;
    while (lastByte > firstByte && codeSpecWhitespace(spec[lastByte - 1], true)) lastByte -= 1;
    if (firstByte === lastByte) return null;
    let dash = -1;
    for (let i = firstByte; i < lastByte; i += 1) {
      if (spec[i] === 45) {
        if (dash !== -1) return null;
        dash = i;
      }
    }
    const first = codeSpecNumber(spec, firstByte, dash === -1 ? lastByte : dash);
    const last = dash === -1 ? first : codeSpecNumber(spec, dash + 1, lastByte);
    if (first === 0 || last < first) return null;
    for (let line = first; line <= last; line += 1) {
      if (seen[line] === 0) { seen[line] = 1; result.push(line); }
    }
    if (after === end) break;
    start = after + 1;
    if (start === end) return null;
  }
  return result;
}

function codeSpecWhitespace(byte: number, breaks: boolean): boolean {
  return byte === 32 || byte === 9 || breaks && (byte === 10 || byte === 13);
}

function codeSpecNumber(spec: Uint8Array, from: number, to: number): number {
  let start = from, end = to;
  while (start < end && codeSpecWhitespace(spec[start], false)) start += 1;
  while (end > start && codeSpecWhitespace(spec[end - 1], false)) end -= 1;
  if (start < end && spec[start] === 43) start += 1;
  if (start === end || spec[start] === 95 || spec[end - 1] === 95) return 0;
  let value = 0;
  for (let i = start; i < end; i += 1) {
    const byte = spec[i];
    if (byte === 95) continue;
    if (byte < 48 || byte > 57) return 0;
    value = value * 10 + byte - 48;
    if (value > 128) return 0;
  }
  return value;
}

/// Prepare new single-line input by removing CR/LF bytes. An insertion
/// containing only line breaks is suppressed; an empty composition stays
/// meaningful and its explicit cursor moves past the removed bytes.
/// Clean and over-budget events retain their original borrowed payload.
/// Retained history is state, so replay it without this new-input step.
export function sanitizedSingleLineTextInputEvent(event: TextInputEvent): TextInputEvent | null {
  if (event.kind !== "insert_text" && event.kind !== "set_composition") return event;
  const text = event.text;
  if (text.length > 512 * 1024) return event;
  let length = 0;
  for (const byte of text) if (byte !== 10 && byte !== 13) length += 1;
  if (length === text.length) return event;
  if (event.kind === "insert_text" && length === 0) return null;
  const stripped = new Uint8Array(length);
  const cursor = event.kind === "set_composition" ? Math.min(event.cursor === null ? text.length : event.cursor, text.length) : 0;
  let written = 0, removedBeforeCursor = 0;
  for (let i = 0; i < text.length; i++) {
    const byte = text[i];
    if (byte === 10 || byte === 13) {
      if (i < cursor) removedBeforeCursor += 1;
    } else {
      stripped[written] = byte;
      written += 1;
    }
  }
  if (event.kind === "insert_text") return { kind: "insert_text", text: stripped };
  const shifted = cursor - removedBeforeCursor;
  if (!(shifted >= 0 && shifted <= 512 * 1024)) return null;
  return { kind: "set_composition", text: stripped,
    cursor: event.cursor === null && shifted === stripped.length ? null : Math.trunc(shifted) };
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

/** Source-byte range for Copy/Cut. Clamp and order the selection, then snap
 * its endpoints to UTF-8 boundaries. Missing or collapsed selections return
 * null. The current selection supplies the range; line numbers and diff
 * markers never enter the source bytes.
 */
export function textClipboardRange(text: Uint8Array, selection: TextSelection | null): TextRange | null {
  if (selection === null) return null;
  const range = snapTextRange(text, selectionRange(selection, text.length));
  return range.start === range.end ? null : range;
}

function isUtf8ContinuationByte(byte: number): boolean {
  return (byte & 0xc0) === 0x80;
}

function utf8SequenceLength(lead: number): number {
  if ((lead & 0x80) === 0) return 1;
  if ((lead & 0xe0) === 0xc0) return 2;
  if ((lead & 0xf0) === 0xe0) return 3;
  if ((lead & 0xf8) === 0xf0) return 4;
  return 1;
}

function snapTextOffset(text: Uint8Array, offset: number): number {
  let cursor = Math.min(offset, text.length);
  while (cursor > 0 && cursor < text.length && isUtf8ContinuationByte(text[cursor])) {
    cursor -= 1;
  }
  return cursor;
}

function previousTextOffset(text: Uint8Array, offset: number): number {
  let cursor = snapTextOffset(text, offset);
  if (cursor === 0) return 0;
  cursor -= 1;
  while (cursor > 0 && isUtf8ContinuationByte(text[cursor])) {
    cursor -= 1;
  }
  return cursor;
}

function nextTextOffset(text: Uint8Array, offset: number): number {
  const cursor = snapTextOffset(text, offset);
  if (cursor >= text.length) return text.length;
  const next = Math.min(text.length, cursor + utf8SequenceLength(text[cursor]));
  if (next <= offset) return Math.min(text.length, offset + 1);
  return next;
}

// Caret editing treats CRLF as one hard-line boundary. Raw text ranges
// continue to use snapTextOffset so they may address either delimiter byte.
function snapTextCaretOffset(text: Uint8Array, offset: number): number {
  const cursor = snapTextOffset(text, offset);
  if (
    cursor > 0 &&
    cursor < text.length &&
    text[cursor] === 0x0a &&
    text[cursor - 1] === 0x0d
  ) {
    return cursor - 1;
  }
  return cursor;
}

function previousTextCaretOffset(text: Uint8Array, offset: number): number {
  const previous = previousTextOffset(text, offset);
  if (previous > 0 && text[previous] === 0x0a && text[previous - 1] === 0x0d) {
    return previous - 1;
  }
  return previous;
}

function nextTextCaretOffset(text: Uint8Array, offset: number): number {
  const cursor = snapTextOffset(text, offset);
  if (
    cursor < text.length &&
    text[cursor] === 0x0d &&
    cursor + 1 < text.length &&
    text[cursor + 1] === 0x0a
  ) {
    return cursor + 2;
  }
  return nextTextOffset(text, cursor);
}

function isAsciiAlphanumeric(b: number): boolean {
  return (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a);
}

function isAsciiWhitespace(b: number): boolean {
  return b === 0x20 || b === 0x09 || b === 0x0a || b === 0x0d || b === 0x0b || b === 0x0c;
}

type TextRunClass = 0 | 1 | 2; // word, space, other

function textRunClassAt(text: Uint8Array, offset: number): TextRunClass | null {
  const cursor = snapTextOffset(text, offset);
  if (cursor >= text.length) return null;
  const lead = text[cursor];
  if ((lead & 0x80) !== 0) return 0;
  if (isAsciiAlphanumeric(lead) || lead === 0x5f) return 0;
  if (isAsciiWhitespace(lead)) return 1;
  return 2;
}

function textOffsetStartsWord(text: Uint8Array, offset: number): boolean {
  const cls = textRunClassAt(text, offset);
  return cls !== null && cls === 0;
}

/** Select the word, whitespace run or punctuation cluster at a UTF-8 byte
 * offset. An offset at or beyond the end selects the trailing run.
 */
export function textWordSelectionAtOffset(text: Uint8Array, offset: number): TextSelection {
  if (text.length === 0) return caretSelectionAt(0, 0);
  let cursor = snapTextOffset(text, offset);
  if (cursor >= text.length) cursor = previousTextOffset(text, text.length);
  const kind = textRunClassAt(text, cursor);
  let start = cursor;
  while (start > 0) {
    const previous = previousTextOffset(text, start);
    if (textRunClassAt(text, previous) !== kind) break;
    start = previous;
  }
  let end = nextTextOffset(text, cursor);
  while (end < text.length && textRunClassAt(text, end) === kind) end = nextTextOffset(text, end);
  return caretSelectionAt(start, end);
}

/** Select a hard-newline line without its LF or CRLF terminator. */
export function textLineSelectionAtOffset(text: Uint8Array, offset: number): TextSelection {
  let end = snapTextOffset(text, offset);
  while (end < text.length && text[end] !== 0x0a) end += 1;
  if (end > 0 && end < text.length && text[end - 1] === 0x0d) end -= 1;
  return caretSelectionAt(textLineStartOffset(text, offset), end);
}

function previousTextWordOffset(text: Uint8Array, offset: number): number {
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

function nextTextWordOffset(text: Uint8Array, offset: number): number {
  let cursor = snapTextOffset(text, offset);
  while (cursor < text.length && !textOffsetStartsWord(text, cursor)) {
    cursor = nextTextOffset(text, cursor);
  }
  while (cursor < text.length && textOffsetStartsWord(text, cursor)) {
    cursor = nextTextOffset(text, cursor);
  }
  return cursor;
}

/// The selection constructor: offsets are whole byte offsets by
/// contract, proven in place — range-guarded (an ordered comparison
/// excludes NaN) and stated whole with Math.trunc. A value outside the
/// provable ±(2^53 − 1) window clamps to 0, the same floor every
/// caller's snap already applies.
export function caretSelectionAt(anchor: number, focus: number): TextSelection {
  const wholeAnchor = anchor >= 0 && anchor <= 9007199254740991 ? Math.trunc(anchor) : 0;
  const wholeFocus = focus >= 0 && focus <= 9007199254740991 ? Math.trunc(focus) : 0;
  return { anchor: wholeAnchor, focus: wholeFocus };
}

function snapTextCaretSelection(text: Uint8Array, selection: TextSelection): TextSelection {
  return caretSelectionAt(
    snapTextCaretOffset(text, selection.anchor),
    snapTextCaretOffset(text, selection.focus),
  );
}

function snapTextRange(text: Uint8Array, range: TextRange): TextRange {
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
  readonly text: Uint8Array;
  readonly insertedStart: number;
  readonly insertedEnd: number;
}

// Null when the result would exceed `capacity` — the over-full outcome the
// caller clamps or drops, never a truncated write.
function replaceTextRange(
  source: Uint8Array,
  range: TextRange,
  replacement: Uint8Array,
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
    selection: snapTextCaretSelection(state.text, state.selection),
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
  replacement: Uint8Array,
  capacity: number,
  composition: TextRange | null,
  cursorOffset: number,
): TextEditState | null {
  const result = replaceTextRange(state.text, range, replacement, capacity);
  if (result === null) return null;
  const cursor = snapTextCaretOffset(
    result.text,
    result.insertedStart + Math.min(cursorOffset, replacement.length),
  );
  return {
    text: result.text,
    selection: caretSelectionAt(cursor, cursor),
    composition: composition,
  };
}

function setTextComposition(
  state: TextEditState,
  text: Uint8Array,
  cursorIn: number | null,
  capacity: number,
): TextEditState | null {
  const range = activeTextReplaceRange(state);
  const cursor = snapTextCaretOffset(text, cursorIn === null ? text.length : cursorIn);
  const result = replaceTextRange(state.text, range, text, capacity);
  if (result === null) return null;
  const absoluteCursor = snapTextCaretOffset(result.text, result.insertedStart + cursor);
  return {
    text: result.text,
    selection: caretSelectionAt(absoluteCursor, absoluteCursor),
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
    selection: snapTextCaretSelection(
      result.text,
      caretSelectionAt(result.insertedStart, result.insertedStart),
    ),
    composition: null,
  };
}

function deleteBackwardTextEdit(state: TextEditState, capacity: number): TextEditState | null {
  const range = activeTextReplaceRange(state);
  if (!rangeIsCollapsed(range, state.text.length)) {
    return replaceTextEditRange(state, range, new Uint8Array(0), capacity, null, 0);
  }
  const caret = snapTextCaretOffset(state.text, state.selection.focus);
  if (caret === 0) {
    return { text: state.text, selection: { anchor: 0, focus: 0 }, composition: null };
  }
  return replaceTextEditRange(
    state,
    { start: previousTextCaretOffset(state.text, caret), end: caret },
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
  const caret = snapTextCaretOffset(state.text, state.selection.focus);
  if (caret >= state.text.length) {
    const len = state.text.length;
    return { text: state.text, selection: caretSelectionAt(len, len), composition: null };
  }
  return replaceTextEditRange(
    state,
    { start: caret, end: nextTextCaretOffset(state.text, caret) },
    new Uint8Array(0),
    capacity,
    null,
    0,
  );
}

function deleteWordBackwardTextEdit(state: TextEditState, capacity: number): TextEditState | null {
  const range = activeTextReplaceRange(state);
  if (!rangeIsCollapsed(range, state.text.length)) {
    return replaceTextEditRange(state, range, new Uint8Array(0), capacity, null, 0);
  }
  const caret = snapTextCaretOffset(state.text, state.selection.focus);
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

function deleteWordForwardTextEdit(state: TextEditState, capacity: number): TextEditState | null {
  const range = activeTextReplaceRange(state);
  if (!rangeIsCollapsed(range, state.text.length)) {
    return replaceTextEditRange(state, range, new Uint8Array(0), capacity, null, 0);
  }
  const caret = snapTextCaretOffset(state.text, state.selection.focus);
  if (caret >= state.text.length) {
    const len = state.text.length;
    return { text: state.text, selection: caretSelectionAt(len, len), composition: null };
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

function textLineStartOffset(text: Uint8Array, offset: number): number {
  let cursor = snapTextOffset(text, offset);
  while (cursor > 0 && text[cursor - 1] !== 0x0a) cursor -= 1;
  return cursor;
}

function deleteToStartTextEdit(state: TextEditState, capacity: number): TextEditState | null {
  const range = activeTextReplaceRange(state);
  if (!rangeIsCollapsed(range, state.text.length)) {
    return replaceTextEditRange(state, range, new Uint8Array(0), capacity, null, 0);
  }
  const caret = snapTextCaretOffset(state.text, state.selection.focus);
  if (caret === 0) {
    return { text: state.text, selection: caretSelectionAt(0, 0), composition: null };
  }
  return replaceTextEditRange(
    state,
    { start: 0, end: caret },
    new Uint8Array(0),
    capacity,
    null,
    0,
  );
}

function deleteToLineStartTextEdit(state: TextEditState, capacity: number): TextEditState | null {
  const range = activeTextReplaceRange(state);
  if (!rangeIsCollapsed(range, state.text.length)) {
    return replaceTextEditRange(state, range, new Uint8Array(0), capacity, null, 0);
  }
  const caret = snapTextCaretOffset(state.text, state.selection.focus);
  const lineStart = textLineStartOffset(state.text, caret);
  if (lineStart === caret) {
    return { text: state.text, selection: caretSelectionAt(caret, caret), composition: null };
  }
  return replaceTextEditRange(
    state,
    { start: lineStart, end: caret },
    new Uint8Array(0),
    capacity,
    null,
    0,
  );
}

function moveTextCaret(state: TextEditState, move: TextCaretMove): TextEditState {
  const range = selectionRange(state.selection, state.text.length);
  const focus = snapTextCaretOffset(state.text, state.selection.focus);
  const collapsed = rangeIsCollapsed(range, state.text.length);
  let target: number;
  if (move.direction === "previous") {
    target = !move.extend && !collapsed ? range.start : previousTextCaretOffset(state.text, focus);
  } else if (move.direction === "next") {
    target = !move.extend && !collapsed ? range.end : nextTextCaretOffset(state.text, focus);
  } else if (move.direction === "previous_word") {
    target = !move.extend && !collapsed ? range.start : previousTextWordOffset(state.text, focus);
  } else if (move.direction === "next_word") {
    target = !move.extend && !collapsed ? range.end : nextTextWordOffset(state.text, focus);
  } else if (move.direction === "start") {
    target = 0;
  } else {
    target = state.text.length;
  }
  const selection: TextSelection = move.extend
    ? caretSelectionAt(state.selection.anchor, target)
    : caretSelectionAt(target, target);
  return {
    text: state.text,
    selection: snapTextCaretSelection(state.text, selection),
    composition: null,
  };
}

/// Reduce one runtime text-input event over an editor state within a fixed
/// byte capacity. Null means the edit would not fit (the refuse-whole
/// contract) — recover inserts with `clampedInsertEvent`, drop the rest.
export function applyTextInputEvent(
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
    case "delete_to_start":
      return deleteToStartTextEdit(normalized, capacity);
    case "delete_to_line_start":
      return deleteToLineStartTextEdit(normalized, capacity);
    case "clear":
      return { text: new Uint8Array(0), selection: { anchor: 0, focus: 0 }, composition: null };
    case "move_caret":
      return moveTextCaret(normalized, event.move);
    case "set_selection":
      return {
        text: normalized.text,
        selection: snapTextCaretSelection(normalized.text, event.selection),
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

/// For an over-capacity insert, the same event with its payload clamped (at
/// a UTF-8 boundary) to the bytes that fit; null when nothing fits — the
/// runtime TextBuffer's clamp-insert / refuse-everything-else contract.
export function clampedInsertEvent(
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

// --------------------------------------------------------- byte text utils
// The text comparisons every text-bearing app grows: ASCII-only case rules
// (byte-exact, locale-free — identical under node and native by
// construction; non-ASCII bytes compare verbatim).

function lowerAsciiByte(b: number): number {
  return b >= 0x41 && b <= 0x5a ? b + 32 : b;
}

/// Whether `haystack` contains `needle`, ASCII case-insensitively. An empty
/// needle matches everything (the search-filter convention).
export function containsIgnoreCase(haystack: Uint8Array, needle: Uint8Array): boolean {
  if (needle.length === 0) return true;
  if (needle.length > haystack.length) return false;
  for (let start = 0; start + needle.length <= haystack.length; start++) {
    let hit = true;
    for (let i = 0; i < needle.length; i++) {
      if (lowerAsciiByte(haystack[start + i]) !== lowerAsciiByte(needle[i])) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// ASCII case-insensitive lexicographic order as a sign (-1/0/1) — a
/// ready-made `.toSorted` comparator for name columns.
export function orderIgnoreCase(a: Uint8Array, b: Uint8Array): number {
  const shorter = Math.min(a.length, b.length);
  for (let i = 0; i < shorter; i++) {
    const av = lowerAsciiByte(a[i]);
    const bv = lowerAsciiByte(b[i]);
    if (av !== bv) return av < bv ? -1 : 1;
  }
  if (a.length === b.length) return 0;
  return a.length < b.length ? -1 : 1;
}

/// The view of `text` with ASCII spaces, tabs, and carriage returns trimmed
/// from both ends (a subarray — no copy). DISTINCT from the built-in
/// `.trim()` on bytes: `.trim()` strips the full JS whitespace set (LF and
/// the Unicode spaces included) and is the everyday form; this helper stays
/// for line-oriented parsing where the newline is the record separator and
/// must survive the trim (system-monitor's ps parser is the canonical use).
export function trimAsciiSpaces(text: Uint8Array): Uint8Array {
  let start = 0;
  let end = text.length;
  while (start < end && (text[start] === 0x20 || text[start] === 0x09 || text[start] === 0x0d)) start += 1;
  while (end > start && (text[end - 1] === 0x20 || text[end - 1] === 0x09 || text[end - 1] === 0x0d)) end -= 1;
  return text.subarray(start, end);
}
