// @native-sdk/core/text-attr — attributed style runs over TextBuffer bytes.
// Zig counterpart: src/primitives/canvas/text_attr.zig. Byte-identical
// contracts: offsets are UTF-8 bytes; max 32 runs; IME composition does
// not stamp persistent styles until commit/insert.

import type { TextEditState, TextInputEvent, TextSelection } from "./text.ts";
import { applyTextInputEvent } from "./text.ts";

export const MAX_STYLE_RUNS = 32;

export type StyleFlag =
  | "bold"
  | "italic"
  | "underline"
  | "monospace"
  | "strikethrough";

export interface StyleFlags {
  readonly bold: boolean;
  readonly italic: boolean;
  readonly underline: boolean;
  readonly monospace: boolean;
  readonly strikethrough: boolean;
}

export interface StyleRun {
  readonly start: number;
  readonly end: number;
  readonly flags: StyleFlags;
}

export interface AttributedEditState {
  readonly text: Uint8Array;
  readonly selection: TextSelection;
  readonly composition: { readonly start: number; readonly end: number } | null;
  readonly runs: readonly StyleRun[];
}

export const EMPTY_STYLE_FLAGS: StyleFlags = {
  bold: false,
  italic: false,
  underline: false,
  monospace: false,
  strikethrough: false,
};

function flagsByte(f: StyleFlags): number {
  return (
    (f.bold ? 1 : 0) |
    (f.italic ? 2 : 0) |
    (f.underline ? 4 : 0) |
    (f.monospace ? 8 : 0) |
    (f.strikethrough ? 16 : 0)
  );
}

function flagsFromByte(b: number): StyleFlags {
  return {
    bold: (b & 1) !== 0,
    italic: (b & 2) !== 0,
    underline: (b & 4) !== 0,
    monospace: (b & 8) !== 0,
    strikethrough: (b & 16) !== 0,
  };
}

function flagsEql(a: StyleFlags, b: StyleFlags): boolean {
  return flagsByte(a) === flagsByte(b);
}

function flagsEmpty(f: StyleFlags): boolean {
  return flagsByte(f) === 0;
}

function flagsWith(f: StyleFlags, flag: StyleFlag, on: boolean): StyleFlags {
  return {
    bold: flag === "bold" ? on : f.bold,
    italic: flag === "italic" ? on : f.italic,
    underline: flag === "underline" ? on : f.underline,
    monospace: flag === "monospace" ? on : f.monospace,
    strikethrough: flag === "strikethrough" ? on : f.strikethrough,
  };
}

function flagOn(f: StyleFlags, flag: StyleFlag): boolean {
  switch (flag) {
    case "bold":
      return f.bold;
    case "italic":
      return f.italic;
    case "underline":
      return f.underline;
    case "monospace":
      return f.monospace;
    case "strikethrough":
      return f.strikethrough;
  }
}

function normRange(start: number, end: number, textLen: number): { start: number; end: number } {
  const s = Math.min(start, textLen);
  const e = Math.min(end, textLen);
  return s <= e ? { start: s, end: e } : { start: e, end: s };
}

function selectionRange(sel: TextSelection, textLen: number): { start: number; end: number } {
  return normRange(sel.anchor, sel.focus, textLen);
}

export function normalizeStyleRuns(runs: readonly StyleRun[]): StyleRun[] {
  const out: StyleRun[] = [];
  for (const run of runs) {
    if (run.end <= run.start) continue;
    const last = out.length > 0 ? out[out.length - 1] : null;
    if (last && flagsEql(last.flags, run.flags) && last.end === run.start) {
      out[out.length - 1] = { start: last.start, end: run.end, flags: last.flags };
      continue;
    }
    if (out.length >= MAX_STYLE_RUNS) break;
    out.push(run);
  }
  return out;
}

function styleAt(runs: readonly StyleRun[], offset: number): StyleFlags {
  for (const run of runs) {
    if (offset >= run.start && offset < run.end) return run.flags;
    if (offset === run.end && run.end > run.start) return run.flags;
  }
  let best: StyleRun | null = null;
  for (const run of runs) {
    if (run.end <= offset && run.end > run.start) {
      if (!best || run.end > best.end) best = run;
    }
  }
  return best ? best.flags : EMPTY_STYLE_FLAGS;
}

export function mapStyleRunsThroughReplace(
  runs: readonly StyleRun[],
  rangeStart: number,
  rangeEnd: number,
  insertedLen: number,
  inherit: StyleFlags,
): StyleRun[] {
  const delStart = rangeStart;
  const delEnd = rangeEnd;
  const delLen = delEnd > delStart ? delEnd - delStart : 0;
  const out: StyleRun[] = [];

  for (const run of runs) {
    let start = run.start;
    let end = run.end;
    if (end <= delStart) {
      // before
    } else if (start >= delEnd) {
      start = start - delLen + insertedLen;
      end = end - delLen + insertedLen;
    } else if (start < delStart) {
      end = delStart;
    } else if (end > delEnd) {
      start = delStart + insertedLen;
      end = end - delLen + insertedLen;
    } else {
      continue;
    }
    if (end <= start) continue;
    if (out.length >= MAX_STYLE_RUNS) break;
    out.push({ start, end, flags: run.flags });
  }

  if (insertedLen > 0 && !flagsEmpty(inherit) && out.length < MAX_STYLE_RUNS) {
    out.push({
      start: delStart,
      end: delStart + insertedLen,
      flags: inherit,
    });
  }
  return normalizeStyleRuns(out);
}

export function toggleStyleOnSelection(
  runs: readonly StyleRun[],
  selection: TextSelection,
  textLen: number,
  flag: StyleFlag,
): StyleRun[] {
  const range = selectionRange(selection, textLen);
  if (range.start === range.end || range.start >= textLen) {
    return runs.slice(0, MAX_STYLE_RUNS);
  }
  const selStart = range.start;
  const selEnd = Math.min(range.end, textLen);
  const sample = styleAt(runs, selStart);
  const turnOn = !flagOn(sample, flag);
  const scratch: StyleRun[] = [];

  for (const run of runs) {
    if (run.end <= selStart) scratch.push(run);
  }
  let covered = false;
  for (const run of runs) {
    if (run.end <= selStart || run.start >= selEnd) continue;
    covered = true;
    if (run.start < selStart) {
      scratch.push({ start: run.start, end: selStart, flags: run.flags });
    }
    const midStart = Math.max(run.start, selStart);
    const midEnd = Math.min(run.end, selEnd);
    if (midEnd > midStart) {
      scratch.push({
        start: midStart,
        end: midEnd,
        flags: flagsWith(run.flags, flag, turnOn),
      });
    }
    if (run.end > selEnd) {
      scratch.push({ start: selEnd, end: run.end, flags: run.flags });
    }
  }
  if (!covered) {
    scratch.push({
      start: selStart,
      end: selEnd,
      flags: flagsWith(EMPTY_STYLE_FLAGS, flag, turnOn),
    });
  }
  for (const run of runs) {
    if (run.start >= selEnd) scratch.push(run);
  }
  return normalizeStyleRuns(scratch);
}

function activeReplaceRange(state: AttributedEditState): { start: number; end: number } {
  if (state.composition) return state.composition;
  return selectionRange(state.selection, state.text.length);
}

export function applyAttributedTextInputEvent(
  state: AttributedEditState,
  event: TextInputEvent,
  capacity: number,
): AttributedEditState | null {
  const plain: TextEditState = {
    text: state.text,
    selection: state.selection,
    composition: state.composition,
  };
  const next = applyTextInputEvent(plain, event, capacity);
  if (!next) return null;

  if (
    event.kind === "move_caret" ||
    event.kind === "set_selection" ||
    event.kind === "commit_composition"
  ) {
    return {
      text: next.text,
      selection: next.selection,
      composition: next.composition,
      runs: state.runs,
    };
  }

  const beforeLen = state.text.length;
  const replace = activeReplaceRange(state);
  const deleted = replace.end - replace.start;
  const insertedLen = next.text.length + deleted - beforeLen;
  const inherit =
    event.kind === "set_composition"
      ? EMPTY_STYLE_FLAGS
      : styleAt(state.runs, selectionRange(state.selection, beforeLen).start);

  const runs = mapStyleRunsThroughReplace(
    state.runs,
    replace.start,
    replace.end,
    Math.max(0, insertedLen),
    inherit,
  );

  return {
    text: next.text,
    selection: next.selection,
    composition: next.composition,
    runs,
  };
}

export function serializeStyleRuns(runs: readonly StyleRun[]): Uint8Array {
  const out = new Uint8Array(Math.min(runs.length, MAX_STYLE_RUNS) * 9);
  let o = 0;
  for (const run of runs) {
    if (o + 9 > out.length) break;
    const view = new DataView(out.buffer, out.byteOffset + o, 9);
    view.setUint32(0, run.start >>> 0, true);
    view.setUint32(4, run.end >>> 0, true);
    out[o + 8] = flagsByte(run.flags);
    o += 9;
  }
  return out.subarray(0, o);
}

export function deserializeStyleRuns(bytes: Uint8Array): StyleRun[] {
  const out: StyleRun[] = [];
  for (let i = 0; i + 9 <= bytes.length && out.length < MAX_STYLE_RUNS; i += 9) {
    const view = new DataView(bytes.buffer, bytes.byteOffset + i, 9);
    out.push({
      start: view.getUint32(0, true),
      end: view.getUint32(4, true),
      flags: flagsFromByte(bytes[i + 8]!),
    });
  }
  return normalizeStyleRuns(out);
}

/** Convert runs to span descriptors for preview / host bridges. */
export function attributedToSpanDescriptors(
  text: Uint8Array,
  runs: readonly StyleRun[],
): Array<{ start: number; end: number; flags: StyleFlags }> {
  const out: Array<{ start: number; end: number; flags: StyleFlags }> = [];
  let cursor = 0;
  const sorted = runs.slice().sort((a, b) => a.start - b.start);
  for (const run of sorted) {
    if (run.start > cursor) {
      out.push({ start: cursor, end: run.start, flags: EMPTY_STYLE_FLAGS });
    }
    const end = Math.min(run.end, text.length);
    if (end > run.start) {
      out.push({ start: Math.max(run.start, cursor), end, flags: run.flags });
      cursor = end;
    }
  }
  if (cursor < text.length) {
    out.push({ start: cursor, end: text.length, flags: EMPTY_STYLE_FLAGS });
  }
  return out;
}

/** Export attributed plain text + runs as GFM with ** / * / ` / ~~ markers. */
export function attributedToMarkdown(
  text: Uint8Array,
  runs: readonly StyleRun[],
): Uint8Array {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const sorted = runs.slice().sort((a, b) => a.start - b.start);
  let out = "";
  let cursor = 0;
  for (const run of sorted) {
    if (run.start > cursor) {
      out += decoder.decode(text.subarray(cursor, run.start));
    }
    const slice = decoder.decode(
      text.subarray(Math.max(run.start, cursor), Math.min(run.end, text.length)),
    );
    if (slice.length === 0) continue;
    let wrapped = slice;
    if (run.flags.monospace) wrapped = "`" + wrapped + "`";
    if (run.flags.bold) wrapped = "**" + wrapped + "**";
    else if (run.flags.italic) wrapped = "*" + wrapped + "*";
    if (run.flags.strikethrough) wrapped = "~~" + wrapped + "~~";
    out += wrapped;
    cursor = Math.min(run.end, text.length);
  }
  if (cursor < text.length) {
    out += decoder.decode(text.subarray(cursor));
  }
  return encoder.encode(out);
}

/**
 * Proportional hit-test fallback (byte offset). Prefer Zig hitTestAttributed
 * once spans are laid out in the host.
 */
export function hitTestAttributed(
  text: Uint8Array,
  _runs: readonly StyleRun[],
  originX: number,
  pointX: number,
  maxWidth: number,
): number {
  if (text.length === 0) return 0;
  const local = pointX - originX;
  if (!(local > 0)) return 0;
  if (!(maxWidth > 0)) return text.length;
  const ratio = Math.min(1, Math.max(0, local / maxWidth));
  return Math.min(text.length, Math.floor(ratio * text.length));
}

/** Snapshot style runs for a parallel undo stack (text undo stays on TextBuffer). */
export function pushStyleUndo(
  stack: readonly Uint8Array[],
  runs: readonly StyleRun[],
  maxDepth = 64,
): Uint8Array[] {
  const next = [...stack, serializeStyleRuns(runs)];
  if (next.length <= maxDepth) return next;
  return next.slice(next.length - maxDepth);
}

export function popStyleUndo(
  stack: readonly Uint8Array[],
): { stack: Uint8Array[]; runs: StyleRun[] } | null {
  if (stack.length === 0) return null;
  const top = stack[stack.length - 1]!;
  return {
    stack: stack.slice(0, stack.length - 1),
    runs: deserializeStyleRuns(top),
  };
}
