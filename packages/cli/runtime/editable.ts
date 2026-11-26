// Plain-text editing for contenteditable hosts: typing inserts at the document selection, and
// Backspace/Delete removes a character, each through a cancelable `beforeinput` and an `input`
// event the way a browser sends them. Structural keys (Enter, Tab, the arrows) and IME composition
// are separate steps; this module is the text path shared by them.

import { Element, Event, InputEvent, Node, Range, Text, document, dispatch, trusted } from "./dom.ts";
import { invalidatePaint } from "./invalidation.ts";

/** Whether a point is inside the host (at any depth). */
export function pointInside(host: Element, node: Node | null | undefined): boolean {
  return node !== null && node !== undefined && (host === node || host.contains(node));
}

/** The node's characters before a point, as an offset in the host's text stream. */
export function offsetOfPoint(host: Element, node: Node, offset: number): number {
  let total = 0;
  let found = false;
  const walk = (n: Node): boolean => {
    if (n === node) {
      if (n.nodeType === 3) total += Math.max(0, Math.min(offset, (n as Text).data.length));
      else {
        const kids = n.childNodes;
        for (let i = 0; i < Math.min(offset, kids.length); i++) total += nodeLength(kids[i]);
      }
      found = true;
      return true;
    }
    if (n.nodeType === 3) {
      total += (n as Text).data.length;
      return false;
    }
    if (n.nodeType !== 1) return false;
    const kids = n.childNodes;
    for (let i = 0; i < kids.length; i++) if (walk(kids[i])) return true;
    return false;
  };
  walk(host);
  return found ? total : 0;
}

function nodeLength(n: Node): number {
  if (n.nodeType === 3) return (n as Text).data.length;
  if (n.nodeType !== 1) return 0;
  let total = 0;
  const kids = n.childNodes;
  for (let i = 0; i < kids.length; i++) total += nodeLength(kids[i]);
  return total;
}

export interface TextPoint {
  node: Text;
  offset: number;
}

/** The text node and offset where a character offset in the host falls. */
export function pointAtOffset(host: Element, target: number): TextPoint | null {
  const nodes = textNodes(host);
  if (nodes.length === 0) return null;
  let at = 0;
  for (const node of nodes) {
    const len = node.data.length;
    if (target < at + len) return { node: node, offset: Math.max(0, target - at) };
    if (target === at + len) return { node: node, offset: len };
    at += len;
  }
  const last = nodes[nodes.length - 1];
  return { node: last, offset: last.data.length };
}

/** Every text node under the host, in document order. */
export function textNodes(host: Element): Text[] {
  const out: Text[] = [];
  const walk = (n: Node): void => {
    if (n.nodeType === 3) {
      out.push(n as Text);
      return;
    }
    if (n.nodeType !== 1) return;
    const kids = n.childNodes;
    for (let i = 0; i < kids.length; i++) walk(kids[i]);
  };
  walk(host);
  return out;
}

/** The selection's range when both ends are inside the host, or null. */
export function selectionIn(host: Element): Range | null {
  const sel = document.getSelection();
  if (sel === null || sel.anchorNode === null || sel.anchorNode === undefined ||
    sel.focusNode === null || sel.focusNode === undefined) return null;
  if (!pointInside(host, sel.anchorNode) || !pointInside(host, sel.focusNode)) return null;
  const a = sel.anchorNode;
  const ao = sel.anchorOffset;
  const f = sel.focusNode;
  const fo = sel.focusOffset;
  const backwards = a === f ? ao > fo : ((a.compareDocumentPosition(f) & 2) !== 0);
  return backwards ? new Range(f, fo, a, ao) : new Range(a, ao, f, fo);
}

/** Whether the selection is a non-empty range inside the host. */
export function hasSelectionIn(host: Element): boolean {
  const range = selectionIn(host);
  return range !== null && !range.collapsed;
}

/**
 * How many text edits are in flight between moving the selection and sending their input event. A
 * browser sends selectionchange after input, so a change the edit makes is held until then; a
 * listener that reads editor state on selectionchange must see the state input updated.
 */
let editDepth = 0;
let selectionChangePending = false;

function noteSelectionChange(): void {
  if (editDepth > 0) {
    selectionChangePending = true;
    return;
  }
  dispatch(trusted(new Event("selectionchange")), document);
}

function selectPoint(point: TextPoint): void {
  const sel = document.getSelection();
  if (sel === null) return;
  sel.collapse(point.node, point.offset);
  // A caret move in an editing host sends selectionchange, as a browser's does.
  noteSelectionChange();
}

function selectOffsets(host: Element, from: number, to: number): void {
  const a = pointAtOffset(host, from);
  const b = pointAtOffset(host, to);
  const sel = document.getSelection();
  if (sel === null) return;
  if (a === null || b === null) {
    sel.collapse(host, 0);
    noteSelectionChange();
    return;
  }
  sel.setBaseAndExtent(a.node, a.offset, b.node, b.offset);
  noteSelectionChange();
}

function beforeInput(host: Element, inputType: string, data: string | null): boolean {
  const ev = trusted(new InputEvent("beforeinput", {
    bubbles: true,
    cancelable: true,
    inputType: inputType,
    data: data,
  }));
  return dispatch(ev, host);
}

function afterInput(host: Element, inputType: string, data: string | null): void {
  dispatch(trusted(new InputEvent("input", {
    bubbles: true,
    inputType: inputType,
    data: data,
  })), host);
  // The selection moved while the text changed; its change event follows input, as in a browser.
  if (selectionChangePending) {
    selectionChangePending = false;
    dispatch(trusted(new Event("selectionchange")), document);
  }
  invalidatePaint();
}

/**
 * Inserts typed text at the selection, replacing a selected range. Returns false when a
 * `beforeinput` handler cancelled the edit.
 */
export function insertTextInto(host: Element, text: string): boolean {
  if (!beforeInput(host, "insertText", text)) return false;
  const sel = document.getSelection();
  if (sel === null) return false;
  let range = selectionIn(host);
  if (range === null) {
    sel.collapse(host, 0);
    range = new Range(host, 0, host, 0);
  }
  editDepth++;
  try {
    if (!range.collapsed) range.deleteContents();
    const node = document.createTextNode(text);
    range.insertNode(node);
    selectPoint({ node: node, offset: node.data.length });
    afterInput(host, "insertText", text);
  } finally {
    editDepth--;
  }
  return true;
}

/**
 * Removes the selected range, or one character before (Backspace) or after (Delete) the caret.
 * Returns false when there is nothing to delete or a `beforeinput` handler cancelled the edit.
 */
export function deleteTextIn(host: Element, forward: boolean): boolean {
  const sel = document.getSelection();
  if (sel === null) return false;
  const range = selectionIn(host);
  const inputType = forward ? "deleteContentForward" : "deleteContentBackward";
  if (range !== null && !range.collapsed) {
    if (!beforeInput(host, inputType, null)) return false;
    const at = offsetOfPoint(host, range.startContainer, range.startOffset);
    editDepth++;
    try {
      range.deleteContents();
      const point = pointAtOffset(host, at);
      if (point !== null) selectPoint(point); else sel.collapse(host, 0);
      afterInput(host, inputType, null);
    } finally {
      editDepth--;
    }
    return true;
  }
  // A collapsed caret: find the character on that side, if the host has one.
  let at: number;
  if (range !== null) {
    at = offsetOfPoint(host, range.startContainer, range.startOffset);
  } else {
    at = 0;
    sel.collapse(host, 0);
  }
  const total = textNodes(host).reduce((n: number, t: Text) => n + t.data.length, 0);
  let from: number;
  let to: number;
  if (forward) {
    if (at >= total) return false;
    from = at;
    to = at + 1;
  } else {
    if (at <= 0) return false;
    from = at - 1;
    to = at;
  }
  if (!beforeInput(host, inputType, null)) return false;
  const a = pointAtOffset(host, from);
  const b = pointAtOffset(host, to);
  if (a === null || b === null) return false;
  const cut = new Range(a.node, a.offset, b.node, b.offset);
  editDepth++;
  try {
    cut.deleteContents();
    const point = pointAtOffset(host, from);
    if (point !== null) selectPoint(point); else sel.collapse(host, 0);
    afterInput(host, inputType, null);
  } finally {
    editDepth--;
  }
  return true;
}

/** Selects the whole host, as Cmd+A does in a focused editing host. */
export function selectHost(host: Element): void {
  const total = textNodes(host).reduce((n: number, t: Text) => n + t.data.length, 0);
  selectOffsets(host, 0, total);
  invalidatePaint();
}
