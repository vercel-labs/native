// An editing host's undo history: a snapshot of its markup before each change the editing
// commands and the key path make, so document.execCommand("undo") and "redo" can walk it.

import type { Element } from "./dom.ts";

interface HostHistory {
  undo: string[];
  redo: string[];
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

/** Records the host's markup before a change, and drops any redo branch. */
export function noteHostEdit(host: Element): void {
  const history = historyOf(host);
  history.undo.push(host.innerHTML);
  if (history.undo.length > LIMIT) history.undo.shift();
  history.redo.length = 0;
}

/** Puts the host back one snapshot; false when there is nothing to undo. */
export function undoHostEdit(host: Element): boolean {
  const history = historyOf(host);
  const previous = history.undo.pop();
  if (previous === undefined) return false;
  history.redo.push(host.innerHTML);
  host.innerHTML = previous;
  return true;
}

/** Replays the snapshot an undo left behind; false when there is nothing to redo. */
export function redoHostEdit(host: Element): boolean {
  const history = historyOf(host);
  const next = history.redo.pop();
  if (next === undefined) return false;
  history.undo.push(host.innerHTML);
  host.innerHTML = next;
  return true;
}
