// @native-sdk/core/text — the blessed byte-splice text engine, an SDK
// LIBRARY module: ordinary app-core subset TypeScript (unlike sdk/core.ts,
// which is intrinsic and never emits), transpiled into your core when
// imported and absent from the binary when not. Under node the same file
// runs as-is — byte for byte the same results.
//
// This is the TS counterpart of the runtime's TextBuffer, extracted from
// the soundboard-ts and system-monitor-ts ports (which carried identical
// private copies): UTF-8 byte splicing, caret and word movement, selection,
// IME composition, capacity-refusal with a clamped-insert recovery, ASCII
// trimming, and ASCII case-insensitive comparison. A core that binds a
// markup text control reduces the control's TextInputEvent stream over its
// draft bytes with `applyTextInputEvent`; everything is immutable — each
// call returns a new state and never touches its inputs.
//
// Offsets are BYTE offsets, always snapped to UTF-8 sequence boundaries
// before use, so a caret can never land inside a multi-byte character.
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

function snapTextSelection(text: Uint8Array, selection: TextSelection): TextSelection {
  return {
    anchor: snapTextOffset(text, selection.anchor),
    focus: snapTextOffset(text, selection.focus),
  };
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
    selection: snapTextSelection(state.text, state.selection),
    composition: state.composition !== null ? snapTextRange(state.text, state.composition) : null,
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
  text: Uint8Array,
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

function deleteWordBackwardTextEdit(state: TextEditState, capacity: number): TextEditState | null {
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

function deleteWordForwardTextEdit(state: TextEditState, capacity: number): TextEditState | null {
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
    target = !move.extend && !collapsed ? range.start : previousTextWordOffset(state.text, focus);
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
