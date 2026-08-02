import test from "node:test";
import assert from "node:assert/strict";
import {
  applyTextInputEvent,
  type TextEditState,
  type TextInputEvent,
} from "../sdk/text.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

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
