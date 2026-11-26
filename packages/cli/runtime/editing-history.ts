// An editing host's undo history: a snapshot of its markup, and the selection in it, before each
// change the editing commands and the key path make, so document.execCommand("undo") and "redo"
// can walk it and put the caret back where the change was made.

import type { Element } from "./dom.ts";

/** The markup before a change, and the selection's character offsets in the host at that time. */
export interface EditSnapshot {
  html: string;
  from: number;
  to: number;
}

interface HostHistory {
  undo: EditSnapshot[];
  redo: EditSnapshot[];
}

const histories = new WeakMap<Element, HostHistory>();
const LIMIT = 100;

function historyOf(host: Element): HostHistory {
  let history = histories.get(host);
  if (history === undefined) {
    history = { undo: [], redo: [] };
    histories.set(host, history);
  }
  return history;
}

/**
 * Records the host's markup before a change, and drops any redo branch. `from`/`to` are the
 * selection's offsets when the change was made; -1 when there was no selection in the host.
 */
export function noteHostEdit(host: Element, from = -1, to = -1): void {
  const history = historyOf(host);
  history.undo.push({ html: host.innerHTML, from: from, to: to });
  if (history.undo.length > LIMIT) history.undo.shift();
  history.redo.length = 0;
}

/**
 * Puts the host back one snapshot and returns it, so the caller can put the caret back too.
 * `from`/`to` are the selection now, recorded for redo. Null when there is nothing to undo.
 */
export function undoHostEdit(host: Element, from = -1, to = -1): EditSnapshot | null {
  const history = historyOf(host);
  const previous = history.undo.pop();
  if (previous === undefined) return null;
  history.redo.push({ html: host.innerHTML, from: from, to: to });
  host.innerHTML = previous.html;
  return previous;
}

/**
 * Replays the snapshot an undo left behind and returns it, for the caret. Null when there is
 * nothing to redo.
 */
export function redoHostEdit(host: Element, from = -1, to = -1): EditSnapshot | null {
  const history = historyOf(host);
  const next = history.redo.pop();
  if (next === undefined) return null;
  history.undo.push({ html: host.innerHTML, from: from, to: to });
  host.innerHTML = next.html;
  return next;
}
