// What an accessibility client does to the page: a press, a focus, a value written into a field,
// a step on a range. Each runs on the element itself, as a browser runs an assistive technology's
// action, so the page hears the events a user's own input would send.

import { Element, Event, HTMLInputElement, HTMLTextAreaElement, InputEvent, dispatch, invalidatePaint, setFocus, setRangeValue, trusted, inDisabledFormControl, controlKind, CONTROL_RANGE } from "../dom.ts";
import { AX_DECREMENT, AX_FOCUS, AX_INCREMENT, AX_INSERT_TEXT, AX_PRESS, AX_SCROLL_INTO_VIEW, AX_SELECT_RANGE, AX_SET_VALUE, AX_SHOW_MENU, hostAxAction, hostAxActionTarget, hostAxActionText, hostEventX, hostEventY } from "../host.ts";
import { axDirty, axElement } from "../ax-tree.ts";
import { contextMenuFor, pressElement } from "./pointer.ts";

/** The text a set-value or insert-text action carries. */
function actionText(): string {
  let text = "";
  hostAxActionText((t: string) => {
    text = t;
  });
  return text;
}

type Field = HTMLInputElement | HTMLTextAreaElement;

function isField(el: Element): el is Field {
  return el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement;
}

/** Whether a field takes text from a client: enabled, writable, and a kind that holds text. */
function writable(field: Field): boolean {
  if (inDisabledFormControl(field) || field.readOnly) return false;
  return field instanceof HTMLTextAreaElement || controlKind(field.type) !== CONTROL_RANGE;
}

/**
 * Replaces the field's selection with `text` as typing or a paste does: beforeinput, which the
 * page may cancel, the edit, then input. `kind` is the InputEvent inputType.
 */
function editField(field: Field, text: string, kind: string): void {
  const before = trusted(new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: kind, data: text }));
  dispatch(before, field);
  if (before.defaultPrevented) return;
  field.replaceSelection(text);
  dispatch(trusted(new InputEvent("input", { bubbles: true, inputType: kind, data: text })), field);
}

/** Writes a field's whole value, as a client's set-value does: the old text is replaced, and
 *  input and change follow, the change a field sends when an edit is committed. Focus stays where
 *  it was. */
function setFieldValue(field: Field, text: string): void {
  if (field instanceof HTMLInputElement && controlKind(field.type) === CONTROL_RANGE) {
    const n = Number(text);
    if (!Number.isNaN(n)) setRangeValue(field, n, true);
    return;
  }
  if (!writable(field)) return;
  // The whole value is replaced; a number or email field has no selection API to do it through.
  const kind = "insertReplacementText";
  const before = trusted(new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: kind, data: text }));
  dispatch(before, field);
  if (before.defaultPrevented) return;
  // Each kind of field is written through its own class: scriptc assigns to one class's property.
  // A client's set-value is the user's edit, so a text field's change fires on the commit below.
  if (field instanceof HTMLInputElement) {
    field.value = text;
    field.userEdited = true;
  } else {
    field.value = text;
  }
  dispatch(trusted(new InputEvent("input", { bubbles: true, inputType: kind, data: text })), field);
  field.commit();
}

/** One step up or down: a range field moves by its step, anything else by its stepUp(). */
function step(el: Element, up: boolean): void {
  if (!(el instanceof HTMLInputElement) || inDisabledFormControl(el) || el.readOnly) return;
  const was = el.value;
  try {
    if (up) el.stepUp();
    else el.stepDown();
  } catch (e) {
    return;
  }
  if (el.value === was) return;
  dispatch(trusted(new Event("input", { bubbles: true })), el);
  dispatch(trusted(new Event("change", { bubbles: true })), el);
}

/** Runs the action EV_AXACTION carries. */
export function performAxAction(): void {
  const kind = hostAxAction();
  const el = axElement(hostAxActionTarget());
  if (el === null) return;
  if (kind === AX_PRESS) pressElement(el);
  else if (kind === AX_FOCUS) {
    if ((el as any).isFocusable === true) setFocus(el);
  } else if (kind === AX_SET_VALUE) {
    if (isField(el)) setFieldValue(el, actionText());
  } else if (kind === AX_INSERT_TEXT) {
    if (isField(el) && writable(el)) {
      setFocus(el);
      editField(el, actionText(), "insertText");
    }
  } else if (kind === AX_SELECT_RANGE) {
    if (isField(el)) {
      setFocus(el);
      const len = el.value.length;
      const s = Math.max(0, Math.min(Math.round(hostEventX()), len));
      const e = Math.max(s, Math.min(s + Math.max(0, Math.round(hostEventY())), len));
      el.setSelectionRange(s, e);
      invalidatePaint();
    }
  } else if (kind === AX_INCREMENT || kind === AX_DECREMENT) step(el, kind === AX_INCREMENT);
  else if (kind === AX_SHOW_MENU) contextMenuFor(el);
  else if (kind === AX_SCROLL_INTO_VIEW) el.scrollIntoView({ block: "nearest", inline: "nearest" });
  // The tree carries the value, the focus and the boxes the action moved.
  axDirty();
}
