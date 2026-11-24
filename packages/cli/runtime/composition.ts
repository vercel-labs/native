// IME composition: the marked text a text field shows while an input method is composing, and the
// events a page sees around it. The host's input method drives this: it reports when composition
// starts, the text it has composed so far and the text it commits, and this module keeps the
// field's value and selection in step and fires compositionstart, compositionupdate and
// compositionend, with an input event for each change (insertCompositionText while composing,
// insertFromComposition when the text is committed, deleteCompositionText when it is cancelled).
//
// A field's value holds the marked text as it is composed, as a browser's does, so a script that
// reads `value` during a composition sees it; the text is underlined where it sits (paint.ts draws
// the range the fields' composeStart/composeEnd name). A selection the composition began over is
// replaced by it.

import {
  CompositionEvent, HTMLInputElement, HTMLTextAreaElement, InputEvent, dispatch, focusState,
  invalidatePaint, setFocusLostHook, trusted,
} from "./dom.ts";
import type { Element, Node } from "./dom.ts";
import { hostCompositionRect } from "./host.ts";
import { textAreaLineStarts } from "./paint.ts";
import { textWidth } from "./layout.ts";
import { lineHeightPx } from "./style.ts";
import { dispatchWindow } from "./window.ts";

/** The field a composition is running in: one of these is set while it runs. */
let fieldInput: HTMLInputElement | null = null;
let fieldArea: HTMLTextAreaElement | null = null;
/** The value before the composition, and the text after it: the marked text goes between them. */
let prefix: string = "";
let suffix: string = "";
/** The marked text as it last stood. */
let marked: string = "";

/** Whether an input method is composing into a field right now. */
export function isComposing(): boolean {
  return fieldInput !== null || fieldArea !== null;
}

/** The composition event a field dispatches, bubbling to the document and the window. */
function compositionEvent(type: string, data: string, el: Node): void {
  const ev = trusted(new CompositionEvent(type, { bubbles: true, data }));
  dispatch(ev, el);
  if (!ev.propagationStopped) dispatchWindow(ev);
}

/** The input event a change to the value during composition dispatches. */
function inputEvent(el: Node, inputType: string, composing: boolean): void {
  dispatch(trusted(new InputEvent("input", { bubbles: true, inputType, isComposing: composing })), el);
}

/** Where the caret is, in CSS pixels from the viewport's top left, for the host's candidate
 *  window: an input's line, or the line of a textarea's wrapped lines the caret falls on. */
function reportInput(el: HTMLInputElement): void {
  const rect = el.getBoundingClientRect();
  const lh = lineHeightPx(el);
  const caret = el.caretEnd;
  hostCompositionRect(rect.left + el.contentX + textWidth(el, el.value.slice(0, caret)) - el.scrollX,
    rect.top + el.contentY, 1, lh);
}

function reportArea(el: HTMLTextAreaElement): void {
  const rect = el.getBoundingClientRect();
  const lh = lineHeightPx(el);
  const caret = el.caretEnd;
  const starts = textAreaLineStarts(el);
  let line = 0;
  for (let i = 0; i < starts.length; i++) if (starts[i] <= caret) line = i;
  const from = starts.length > 0 ? starts[line] : 0;
  hostCompositionRect(rect.left + el.contentX + textWidth(el, el.value.slice(from, caret)),
    rect.top + el.contentY + line * lh, 1, lh);
}

/** Puts `text` in place of the selection the composition began over, and the caret after it. */
function show(text: string): void {
  marked = text;
  const value = prefix + text + suffix;
  const caret = prefix.length + text.length;
  if (fieldInput !== null) {
    const el = fieldInput;
    if (el.value !== value) el.value = value;
    el.setSelectionRange(caret, caret);
    el.caretEnd = caret;
    el.composeStart = text === "" ? -1 : prefix.length;
    el.composeEnd = text === "" ? -1 : caret;
    reportInput(el);
  } else if (fieldArea !== null) {
    const el = fieldArea;
    if (el.value !== value) el.value = value;
    el.setSelectionRange(caret, caret);
    el.caretEnd = caret;
    el.composeStart = text === "" ? -1 : prefix.length;
    el.composeEnd = text === "" ? -1 : caret;
    reportArea(el);
  }
  invalidatePaint();
}

/** Begins a composition in the focused field, replacing whatever it had selected. */
export function compositionStart(text: string): void {
  const el = focusState.el;
  if (el instanceof HTMLTextAreaElement) {
    if (el.readOnly) return;
    fieldArea = el;
    fieldInput = null;
    prefix = el.value.slice(0, el.selectionStart);
    suffix = el.value.slice(el.selectionEnd);
  } else if (el instanceof HTMLInputElement) {
    const kind = el.type.toLowerCase();
    const takesText = kind === "text" || kind === "search" || kind === "url" || kind === "tel"
      || kind === "email" || kind === "password";
    if (!takesText || el.readOnly) return;
    fieldInput = el;
    fieldArea = null;
    const start = el.selectionStart === null ? 0 : Number(el.selectionStart);
    const end = el.selectionEnd === null ? start : Number(el.selectionEnd);
    prefix = el.value.slice(0, start);
    suffix = el.value.slice(end);
  } else {
    return;
  }
  show(text);
  const node = fieldArea !== null ? fieldArea : fieldInput;
  if (node === null) return;
  compositionEvent("compositionstart", text, node);
  compositionEvent("compositionupdate", text, node);
  inputEvent(node, "insertCompositionText", true);
}

/** Replaces the marked text with the text the input method has composed so far. */
export function compositionUpdate(text: string): void {
  if (!isComposing()) {
    compositionStart(text);
    return;
  }
  show(text);
  const node = fieldArea !== null ? fieldArea : fieldInput;
  if (node === null) return;
  compositionEvent("compositionupdate", text, node);
  inputEvent(node, "insertCompositionText", true);
}

/**
 * Ends the composition, keeping `text` (the text the input method committed, or the marked text
 * when none is given) in the field, and fires compositionend then the input event for the commit.
 */
export function compositionEnd(text?: string): void {
  const node = fieldArea !== null ? fieldArea : fieldInput;
  if (node === null) return;
  const final = text === undefined ? marked : text;
  if (final !== marked) show(final);
  clear();
  compositionEvent("compositionend", final, node);
  inputEvent(node, "insertFromComposition", false);
  invalidatePaint();
}

/** Cancels the composition: the marked text goes away and the value returns to what it was. */
export function compositionCancel(): void {
  const node = fieldArea !== null ? fieldArea : fieldInput;
  if (node === null) return;
  const value = prefix + suffix;
  if (fieldInput !== null) {
    const el = fieldInput;
    if (el.value !== value) el.value = value;
    el.setSelectionRange(prefix.length, prefix.length);
    el.caretEnd = prefix.length;
  } else if (fieldArea !== null) {
    const el = fieldArea;
    if (el.value !== value) el.value = value;
    el.setSelectionRange(prefix.length, prefix.length);
    el.caretEnd = prefix.length;
  }
  clear();
  compositionEvent("compositionend", "", node);
  inputEvent(node, "deleteCompositionText", false);
  invalidatePaint();
}

/** Forgets the composition range a field was showing and the field itself. */
function clear(): void {
  if (fieldInput !== null) {
    fieldInput.composeStart = -1;
    fieldInput.composeEnd = -1;
  }
  if (fieldArea !== null) {
    fieldArea.composeStart = -1;
    fieldArea.composeEnd = -1;
  }
  fieldInput = null;
  fieldArea = null;
  marked = "";
}

/** A focused field that loses focus commits the composition it was showing, as a browser does. */
setFocusLostHook((el: Element) => {
  const target: Element | null = fieldArea !== null ? fieldArea : fieldInput;
  if (target !== null && el === target) compositionEnd();
});
