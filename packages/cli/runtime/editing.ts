// Copy, cut and paste: the clipboard events a page hears, and the commands document.execCommand
// runs. The events carry a DataTransfer, so a handler reads and writes exactly what goes on the
// clipboard, and the clipboard itself is the system's (see runtime/clipboard.ts).

import {
  ClipboardEvent, DataTransfer, HTMLInputElement, HTMLTextAreaElement, InputEvent, Node,
  dispatch, document, focusState, trusted,
} from "./dom.ts";
import { clipboardData, writeClipboardData } from "./clipboard.ts";

/**
 * Fires `copy` or `cut` at `target` with a payload that starts out holding `text`, the selection
 * the default action would put on the clipboard, and puts the result on the clipboard: what the
 * handler wrote, or the `text` itself when the handler left it alone. A handler that cancels the
 * event with nothing written copies nothing. Returns whether the clipboard changed.
 */
export function copyPayloadAt(type: string, target: Node, text: string): boolean {
  const dt = new DataTransfer();
  if (text !== "") dt.setData("text/plain", text);
  const ev = trusted(new ClipboardEvent(type, { bubbles: true, cancelable: true, clipboardData: dt }));
  dispatch(ev, target);
  if (ev.defaultPrevented && dt.types.length === 0) return false;
  writeClipboardData(dt, text);
  return ev.defaultPrevented || text !== "";
}

/** The text the document's selection holds, or "" when nothing is selected. */
function selectedText(): string {
  const sel = document.getSelection();
  return sel === null ? "" : sel.toString();
}

/**
 * Copies the document's selection, as Cmd+C does outside a field: a handler's `copy` sees the
 * text and may replace it, and the clipboard is written either way. The event fires even with
 * nothing selected, as it does in a browser. Returns whether anything was copied.
 */
export function copySelection(): boolean {
  if (document.body === null) return false;
  return copyPayloadAt("copy", document.body, selectedText());
}

/**
 * Cuts the document's selection, as Cmd+X does outside a field. A page that isn't editable keeps
 * its text — a browser deletes nothing there either — so this puts the selection on the clipboard,
 * which is what the default action of the `cut` event leaves it doing.
 */
export function cutSelection(): boolean {
  if (document.body === null) return false;
  return copyPayloadAt("cut", document.body, selectedText());
}

/** A field's own selected text. */
function fieldSelection(el: HTMLInputElement | HTMLTextAreaElement): string {
  if (el instanceof HTMLInputElement) return el.value.slice(el.selectionStart, el.selectionEnd);
  return el.value.slice(el.selectionStart, el.selectionEnd);
}

function noteEdit(el: HTMLInputElement | HTMLTextAreaElement): void {
  dispatch(trusted(new InputEvent("input", { bubbles: true })), el);
}

/**
 * Copies a field's own selected text, as Cmd+C does in a field. The copy event goes to the field,
 * as a browser sends it there. Returns whether anything was copied.
 */
export function copyFieldText(el: HTMLInputElement | HTMLTextAreaElement): boolean {
  const text = fieldSelection(el);
  if (text === "") return false;
  return copyPayloadAt("copy", el, text);
}

/**
 * Cuts a field's own selected text: the cut event goes to the field, and the text leaves it and
 * goes on the clipboard. Returns whether the field changed.
 */
export function cutFieldText(el: HTMLInputElement | HTMLTextAreaElement): boolean {
  const text = fieldSelection(el);
  if (text === "") return false;
  if (!copyPayloadAt("cut", el, text)) return false;
  el.replaceSelection("");
  noteEdit(el);
  return true;
}

/**
 * Pastes onto `target`, as Cmd+V does: the payload holds what the clipboard has, the `paste`
 * event goes to the target, and a field inserts the payload's text unless a handler replaced that.
 * An input takes the text the way typing it would — on one line — and a textarea keeps its
 * newlines. Returns whether the page changed.
 */
export function pasteAt(target: Node): boolean {
  const dt = clipboardData();
  const ev = trusted(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: dt }));
  dispatch(ev, target);
  // A handler that cancels the event has done the pasting itself.
  if (ev.defaultPrevented) return true;
  const text = dt.getData("text/plain");
  if (text === "") return false;
  if (target instanceof HTMLInputElement) {
    // Inputs are single-line: newlines become spaces.
    target.replaceSelection(text.replace(/\r\n|\r|\n/g, " "));
    noteEdit(target);
    return true;
  }
  if (target instanceof HTMLTextAreaElement) {
    target.replaceSelection(text.replace(/\r\n/g, "\n"));
    noteEdit(target);
    return true;
  }
  return false;
}

/** The field the page has focused, or null when the focus is elsewhere. */
function focusedField(): HTMLInputElement | HTMLTextAreaElement | null {
  const focused = focusState.el;
  return focused instanceof HTMLInputElement || focused instanceof HTMLTextAreaElement ? focused : null;
}

/**
 * Where a copy or a cut takes its text from: the focused field when it has a selection, and
 * otherwise the page's own selection.
 */
function selectionTarget(): Node | null {
  const field = focusedField();
  if (field instanceof HTMLInputElement && field.selectionStart !== field.selectionEnd) return field;
  if (field instanceof HTMLTextAreaElement && field.selectionStart !== field.selectionEnd) return field;
  return document.body;
}

/**
 * document.execCommand() for the editing commands a native app needs: "copy", "cut" and "paste",
 * which no user gesture or permission has to allow here. Returns whether the command did
 * something; a command this doesn't know answers false, as does one with nothing to act on.
 */
export function runEditCommand(command: string, value: string): boolean {
  const name = command.toLowerCase();
  const field = focusedField();
  if (name === "copy" || name === "cut") {
    const target = selectionTarget();
    if (target === null) return false;
    if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
      return name === "copy" ? copyFieldText(target) : cutFieldText(target);
    }
    return name === "copy" ? copySelection() : cutSelection();
  }
  // A paste lands in the focused field wherever its caret is, and nowhere on a page that isn't
  // editable; so do select-all and insert-text.
  if (name === "paste") return field !== null ? pasteAt(field) : false;
  if (name === "selectall") {
    // A field selects its own value, as a browser's select-all does there.
    if (field !== null) {
      field.select();
      return true;
    }
    const sel = document.getSelection();
    const body = document.body;
    if (sel === null || body === null) return false;
    sel.selectAllChildren(body);
    return true;
  }
  if (name === "inserttext") {
    if (field === null) return false;
    field.replaceSelection(value);
    noteEdit(field);
    return true;
  }
  return false;
}

/** The commands runEditCommand answers, for queryCommandSupported(). */
export function supportsEditCommand(command: string): boolean {
  const name = command.toLowerCase();
  return name === "copy" || name === "cut" || name === "paste" || name === "selectall" || name === "inserttext";
}
