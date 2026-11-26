// Copy, cut and paste: the clipboard events a page hears, and the commands document.execCommand
// runs. The events carry a DataTransfer, so a handler reads and writes exactly what goes on the
// clipboard, and the clipboard itself is the system's (see runtime/clipboard.ts).

import {
  ClipboardEvent, DataTransfer, Element, HTMLInputElement, HTMLTextAreaElement, InputEvent, Node, Range,
  dispatch, document, editingHostFor, focusState, trusted,
} from "./dom.ts";
import { clipboardData, writeClipboardData } from "./clipboard.ts";
import { insertTextInto } from "./editable.ts";
import { noteHostEdit, redoHostEdit, undoHostEdit } from "./editing-history.ts";

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

/** The last host a command ran in, for an undo whose restored markup has detached the selection. */
let lastHost: Element | null = null;

/** The editing host the selection is in, the one the window has focused, or the last one. */
function editHost(): Element | null {
  const sel = document.getSelection();
  if (sel !== null && sel.anchorNode !== null) {
    const host = editingHostFor(sel.anchorNode);
    if (host !== null) {
      lastHost = host;
      return host;
    }
  }
  const focused = focusState.el;
  const fromFocus = focused instanceof Element ? editingHostFor(focused) : null;
  if (fromFocus !== null) lastHost = fromFocus;
  if (lastHost !== null && lastHost.isConnected) return lastHost;
  return null;
}

/** The selection's range when it lies inside `host`. */
function rangeIn(host: Element): Range | null {
  const sel = document.getSelection();
  if (sel === null || sel.rangeCount === 0) return null;
  const range = sel.getRangeAt(0);
  return host.contains(range.commonAncestorContainer) ? range : null;
}

/** Whether the selection's anchor sits in an element of one of these tags, inside the host. */
function anchorIn(host: Element, tags: string[]): boolean {
  const sel = document.getSelection();
  let node: Node | null = sel === null ? null : sel.anchorNode;
  while (node !== null && node !== host) {
    if (node instanceof Element && tags.indexOf(node.tagName) >= 0) return true;
    node = node.parentNode;
  }
  return false;
}

/** The nearest element of one of these tags around the selection's anchor. */
function anchorElement(host: Element, tags: string[]): Element | null {
  const sel = document.getSelection();
  let node: Node | null = sel === null ? null : sel.anchorNode;
  while (node !== null && node !== host) {
    if (node instanceof Element && tags.indexOf(node.tagName) >= 0) return node;
    node = node.parentNode;
  }
  return null;
}

function fireInput(host: Element, inputType: string): void {
  dispatch(trusted(new InputEvent("input", { bubbles: true, inputType: inputType })), host);
}

function selectContents(element: Element): void {
  const sel = document.getSelection();
  if (sel === null) return;
  const range = document.createRange();
  range.selectNodeContents(element);
  sel.removeAllRanges();
  sel.addRange(range);
}

function unwrapElement(element: Element): void {
  const parent = element.parentNode;
  if (parent === null) return;
  while (element.firstChild !== null) parent.insertBefore(element.firstChild, element);
  parent.removeChild(element);
}

/** Wraps the selected range in a new element, keeping the selection on its contents. */
function wrapRange(host: Element, range: Range, tag: string, href: string | null): void {
  noteHostEdit(host);
  const wrapper = document.createElement(tag);
  if (href !== null) wrapper.setAttribute("href", href);
  const contents = range.extractContents();
  wrapper.appendChild(contents);
  range.insertNode(wrapper);
  selectContents(wrapper);
  fireInput(host, tag === "a" ? "createLink" : "format" + tag.toUpperCase());
}

/** Toggles an inline style on the selection, as a browser's execCommand does for it. */
function formatInline(host: Element, tag: string, tags: string[], inputType: string): boolean {
  const range = rangeIn(host);
  if (range === null) return false;
  if (anchorIn(host, tags)) {
    noteHostEdit(host);
    const nodes = host.querySelectorAll(tags.join(", ").toLowerCase());
    for (let index = nodes.length - 1; index >= 0; index--) {
      const element = nodes[index];
      if (element instanceof Element && range.intersectsNode(element)) unwrapElement(element);
    }
    fireInput(host, inputType);
    return true;
  }
  if (range.collapsed) return false;
  wrapRange(host, range, tag, null);
  return true;
}

/** Turns the blocks the selection touches into `tag`, keeping their contents. */
function formatBlock(value: string): boolean {
  const tag = value.replace(/[<>\s]/g, "").toUpperCase();
  if (["P", "H1", "H2", "H3", "H4", "H5", "H6", "BLOCKQUOTE", "PRE", "DIV"].indexOf(tag) < 0) return false;
  const host = editHost();
  if (host === null) return false;
  const range = rangeIn(host);
  if (range === null) return false;
  const blocks: Element[] = [];
  for (let index = 0; index < host.children.length; index++) {
    const child = host.children[index];
    if (child instanceof Element && range.intersectsNode(child)) blocks.push(child);
  }
  noteHostEdit(host);
  if (blocks.length === 0) {
    if (range.collapsed) return false;
    const wrapper = document.createElement(tag);
    wrapper.appendChild(range.extractContents());
    range.insertNode(wrapper);
    selectContents(wrapper);
  } else {
    for (const block of blocks) {
      if (block.tagName === tag) continue;
      const replacement = document.createElement(tag);
      while (block.firstChild !== null) replacement.appendChild(block.firstChild);
      const parent = block.parentNode;
      if (parent !== null) parent.replaceChild(replacement, block);
    }
  }
  fireInput(host, "formatBlock");
  return true;
}

/** Wraps the selection in a link, or gives the link around the caret a new address. */
function createLink(url: string): boolean {
  if (url === "") return false;
  const host = editHost();
  if (host === null) return false;
  const existing = anchorElement(host, ["A"]);
  if (existing !== null) {
    noteHostEdit(host);
    existing.setAttribute("href", url);
    fireInput(host, "createLink");
    return true;
  }
  const range = rangeIn(host);
  if (range === null || range.collapsed) return false;
  wrapRange(host, range, "a", url);
  return true;
}

/** Removes the inline formatting the selection touches. */
function removeFormat(): boolean {
  const host = editHost();
  if (host === null) return false;
  const range = rangeIn(host);
  if (range === null) return false;
  noteHostEdit(host);
  const nodes = host.querySelectorAll("strong, b, em, i, u, a, s, code");
  for (let index = nodes.length - 1; index >= 0; index--) {
    const element = nodes[index];
    if (element instanceof Element && range.intersectsNode(element)) unwrapElement(element);
  }
  fireInput(host, "format");
  return true;
}

/**
 * Whether the caret or selection is in the given state, as document.queryCommandState() asks:
 * bold, italic and underline through the tags they are written with, the two lists, and a link.
 */
export function queryEditCommandState(command: string): boolean {
  const name = command.toLowerCase();
  const host = editHost();
  if (host === null) return false;
  if (name === "bold") return anchorIn(host, ["STRONG", "B"]);
  if (name === "italic") return anchorIn(host, ["EM", "I"]);
  if (name === "underline") return anchorIn(host, ["U"]);
  if (name === "insertunorderedlist") return anchorIn(host, ["UL"]);
  if (name === "insertorderedlist") return anchorIn(host, ["OL"]);
  if (name === "createlink") return anchorIn(host, ["A"]);
  return false;
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
    if (field !== null) {
      field.replaceSelection(value);
      noteEdit(field);
      return true;
    }
    const host = editHost();
    return host !== null ? insertTextInto(host, value) : false;
  }
  // A contenteditable host takes the formatting commands a rich-text toolbar sends.
  if (name === "bold" || name === "italic" || name === "underline") {
    const host = editHost();
    if (host === null) return false;
    if (name === "bold") return formatInline(host, "strong", ["STRONG", "B"], "formatBold");
    if (name === "italic") return formatInline(host, "em", ["EM", "I"], "formatItalic");
    return formatInline(host, "u", ["U"], "formatUnderline");
  }
  if (name === "formatblock") return formatBlock(value);
  if (name === "createlink") return createLink(value);
  if (name === "removeformat") return removeFormat();
  if (name === "undo" || name === "redo") {
    const host = editHost();
    if (host === null) return false;
    const changed = name === "undo" ? undoHostEdit(host) : redoHostEdit(host);
    if (changed) fireInput(host, name);
    return changed;
  }
  return false;
}

/** The commands runEditCommand answers, for queryCommandSupported(). */
export function supportsEditCommand(command: string): boolean {
  const name = command.toLowerCase();
  return name === "copy" || name === "cut" || name === "paste" || name === "selectall" ||
    name === "inserttext" || name === "bold" || name === "italic" || name === "underline" ||
    name === "formatblock" || name === "createlink" || name === "removeformat" ||
    name === "undo" || name === "redo";
}
