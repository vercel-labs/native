import test from "node:test";
import assert from "node:assert/strict";
import {
  applyTextInputEvent,
  textWordSelectionAtOffset,
  textLineSelectionAtOffset,
  sanitizedSingleLineTextInputEvent,
  type TextEditState,
  type TextInputEvent,
} from "../sdk/text.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

test("single-line new input strips breaks, preserves empty previews and adjusts only rewritten cursors", () => {
  const insert = (text: string): TextInputEvent => ({ kind: "insert_text", text: encoder.encode(text) });
  const clean = insert("café 🙂");
  assert.equal(sanitizedSingleLineTextInputEvent(clean), clean);
  assert.equal(sanitizedSingleLineTextInputEvent(insert("\r\n\n")), null);
  assert.deepEqual(sanitizedSingleLineTextInputEvent(insert("")), insert(""));
  assert.deepEqual(sanitizedSingleLineTextInputEvent(insert("a\r\né\n🙂")), insert("aé🙂"));
  for (const [cursor, expected] of [[null, null], [0, 0], [2, 1], [3, 1], [999, 3]] as const) {
    assert.deepEqual(sanitizedSingleLineTextInputEvent({ kind: "set_composition", text: encoder.encode("a\r\né"), cursor }),
      { kind: "set_composition", text: encoder.encode("aé"), cursor: expected });
  }
  assert.deepEqual(sanitizedSingleLineTextInputEvent({ kind: "set_composition", text: encoder.encode("\r\n"), cursor: null }),
    { kind: "set_composition", text: new Uint8Array(0), cursor: null });
  const preview: TextInputEvent = { kind: "set_composition", text: encoder.encode("é"), cursor: 999 };
  assert.equal(sanitizedSingleLineTextInputEvent(preview), preview);
  const deletion: TextInputEvent = { kind: "delete_backward" };
  assert.equal(sanitizedSingleLineTextInputEvent(deletion), deletion);
  const oversized = { kind: "insert_text", text: new Uint8Array(512 * 1024 + 1).fill(10) } as const;
  assert.equal(sanitizedSingleLineTextInputEvent(oversized), oversized);
});

test("pointer selection shares UTF-8 word classes and excludes hard line terminators", () => {
  const words = encoder.encode("café  snake_case!!! 日本");
  for (const at of [0, 3, 4]) assert.deepEqual(textWordSelectionAtOffset(words, at), { anchor: 0, focus: 5 });
  assert.deepEqual(textWordSelectionAtOffset(words, 6), { anchor: 5, focus: 7 });
  assert.deepEqual(textWordSelectionAtOffset(words, 15), { anchor: 7, focus: 17 });
  assert.deepEqual(textWordSelectionAtOffset(words, 18), { anchor: 17, focus: 20 });
  assert.deepEqual(textWordSelectionAtOffset(words, 999), { anchor: 21, focus: 27 });
  const lines = encoder.encode("one\r\ncafé\n\nlast\r");
  assert.deepEqual(textLineSelectionAtOffset(lines, 1), { anchor: 0, focus: 3 });
  assert.deepEqual(textLineSelectionAtOffset(lines, 8), { anchor: 5, focus: 10 });
  assert.deepEqual(textLineSelectionAtOffset(lines, 11), { anchor: 11, focus: 11 });
  assert.deepEqual(textLineSelectionAtOffset(lines, 999), { anchor: 12, focus: 17 });
  assert.deepEqual(textWordSelectionAtOffset(new Uint8Array(), 0), { anchor: 0, focus: 0 });
});

function state(text: string, anchor: number, focus = anchor): TextEditState {
  return {
    text: encoder.encode(text),
    selection: { anchor: anchor, focus: focus },
    composition: null,
  };
}

function apply(input: TextEditState, event: TextInputEvent): TextEditState {
  const next = applyTextInputEvent(input, event, 64);
  assert.notEqual(next, null);
  return next as TextEditState;
}

test("text reducer deletes CRLF as one caret boundary", () => {
  const deletedForward = apply(state("one\r\ntwo", 3), { kind: "delete_forward" });
  assert.equal(decoder.decode(deletedForward.text), "onetwo");
  assert.deepEqual(deletedForward.selection, { anchor: 3, focus: 3 });

  const deletedBackward = apply(state("one\r\ntwo", 5), { kind: "delete_backward" });
  assert.equal(decoder.decode(deletedBackward.text), "onetwo");
  assert.deepEqual(deletedBackward.selection, { anchor: 3, focus: 3 });
});

test("text reducer moves across CRLF as one caret boundary", () => {
  const movedNext = apply(state("one\r\ntwo", 3), {
    kind: "move_caret",
    move: { direction: "next", extend: false },
  });
  assert.deepEqual(movedNext.selection, { anchor: 5, focus: 5 });

  const movedPrevious = apply(state("one\r\ntwo", 5), {
    kind: "move_caret",
    move: { direction: "previous", extend: false },
  });
  assert.deepEqual(movedPrevious.selection, { anchor: 3, focus: 3 });
});

test("text reducer snaps editable endpoints out of CRLF", () => {
  const selected = apply(state("one\r\ntwo", 0), {
    kind: "set_selection",
    selection: { anchor: 4, focus: 5 },
  });
  assert.deepEqual(selected.selection, { anchor: 3, focus: 5 });

  const inserted = apply(state("one\r\ntwo", 4), {
    kind: "insert_text",
    text: encoder.encode("X"),
  });
  assert.equal(decoder.decode(inserted.text), "oneX\r\ntwo");
  assert.deepEqual(inserted.selection, { anchor: 4, focus: 4 });
});

test("text reducer deletes to hard line start", () => {
  const midLine = apply(state("first\nsecond line", 12), { kind: "delete_to_line_start" });
  assert.equal(decoder.decode(midLine.text), "first\n line");
  assert.deepEqual(midLine.selection, { anchor: 6, focus: 6 });

  const atStart = apply(state("first\nsecond", 6), { kind: "delete_to_line_start" });
  assert.equal(decoder.decode(atStart.text), "first\nsecond");
  assert.deepEqual(atStart.selection, { anchor: 6, focus: 6 });

  const selection = apply(state("first\nsecond", 7, 10), { kind: "delete_to_line_start" });
  assert.equal(decoder.decode(selection.text), "first\nsnd");
  assert.deepEqual(selection.selection, { anchor: 7, focus: 7 });

  const crlf = apply(state("one\r\ntwo", 8), { kind: "delete_to_line_start" });
  assert.equal(decoder.decode(crlf.text), "one\r\n");
  assert.deepEqual(crlf.selection, { anchor: 5, focus: 5 });
});

test("text reducer deletes to field start across raw line breaks", () => {
  const collapsed = apply(state("first\nsecond line", 12), { kind: "delete_to_start" });
  assert.equal(decoder.decode(collapsed.text), " line");
  assert.deepEqual(collapsed.selection, { anchor: 0, focus: 0 });

  const selection = apply(state("first\nsecond", 7, 10), { kind: "delete_to_start" });
  assert.equal(decoder.decode(selection.text), "first\nsnd");
  assert.deepEqual(selection.selection, { anchor: 7, focus: 7 });
});

test("text reducer retains exact composition ownership across CRLF", () => {
  const initial = state("a\nb", 1);
  const preview = apply(initial, {
    kind: "set_composition",
    text: encoder.encode("\r"),
    cursor: 1,
  });
  assert.equal(decoder.decode(preview.text), "a\r\nb");
  assert.deepEqual(preview.composition, { start: 1, end: 2 });

  const updated = apply(preview, {
    kind: "set_composition",
    text: encoder.encode("X"),
    cursor: 1,
  });
  assert.equal(decoder.decode(updated.text), "aX\nb");
  assert.deepEqual(updated.composition, { start: 1, end: 2 });

  const cancelled = apply(preview, { kind: "cancel_composition" });
  assert.equal(decoder.decode(cancelled.text), "a\nb");
  assert.deepEqual(cancelled.selection, { anchor: 1, focus: 1 });
  assert.equal(cancelled.composition, null);
});
