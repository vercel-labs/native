// Focusgroup: an element with a `focusgroup` attribute is one segment of a keyboard navigation
// group. A segment is a single tab stop — Tab enters at the item it last held and leaves past the
// whole segment — and the arrow keys move along the segment's axis, as Chrome ships them: a
// toolbar and a tablist move inline, a listbox block; a tablist wraps at its ends by default, and
// the `wrap` token makes any segment wrap while `nomemory` stops it remembering its item.

import { Element, Node } from "../dom.ts";

/** How one segment moves: which axis its arrows follow, whether it wraps, whether it remembers. */
export interface SegmentBehavior {
  axis: string;
  wrap: boolean;
  memory: boolean;
}

/** The behaviour tokens this build knows, with the axis each one moves along. */
export function focusgroupBehavior(el: Element): SegmentBehavior | null {
  const text = el.getAttribute("focusgroup");
  if (text === null) return null;
  const tokens = text.toLowerCase().split(/[\t\n\f\r ]+/);
  let axis = "";
  let wrap = false;
  let memory = true;
  for (const token of tokens) {
    if (token === "toolbar") axis = "inline";
    else if (token === "tablist") {
      // A tablist wraps at its ends without being asked, as Chrome's does.
      axis = "inline";
      wrap = true;
    } else if (token === "listbox") axis = "block";
    else if (token === "wrap") wrap = true;
    else if (token === "nomemory") memory = false;
  }
  return axis === "" ? null : { axis, wrap, memory };
}

/** The segment an element takes part in: the nearest ancestor, or the element itself. */
export function segmentFor(el: Element): Element | null {
  let n: Node | null = el;
  while (n !== null && n.nodeType === 1) {
    if (focusgroupBehavior(n as Element) !== null) return n as Element;
    n = n.parentNode;
  }
  return null;
}

/** The items of a segment, in tree order: its focusable descendants, minus a nested segment's. */
function collectItems(root: Element, out: Element[]): void {
  for (const kid of root.kids) {
    if (!(kid instanceof Element)) continue;
    // A nested segment is an item of its own segment, not of this one.
    if (focusgroupBehavior(kid) !== null) continue;
    if (kid.isFocusable) out.push(kid);
    collectItems(kid, out);
  }
}

export function segmentItems(segment: Element): Element[] {
  const out: Element[] = [];
  collectItems(segment, out);
  return out;
}

/** The item Tab enters the segment at: the one it last held when it remembers, else the first. */
export function segmentStop(segment: Element): Element | null {
  const behavior = focusgroupBehavior(segment);
  const items = segmentItems(segment);
  if (items.length === 0) return null;
  if (behavior !== null && behavior.memory && segment.fgMemory !== null && items.indexOf(segment.fgMemory) >= 0) {
    return segment.fgMemory;
  }
  return items[0];
}

/** Records the item focus leaves the segment from, or forgets it when the segment does not keep one. */
export function rememberSegmentItem(segment: Element, item: Element | null): void {
  const behavior = focusgroupBehavior(segment);
  segment.fgMemory = behavior !== null && behavior.memory && item !== null && item !== segment ? item : null;
}

/**
 * The item an arrow key moves focus to inside `segment`, or null when the key does not move along
 * the segment's axis or the segment ends and does not wrap. Home and End go to its ends.
 */
export function moveInSegment(segment: Element, from: Element, key: string): Element | null {
  const behavior = focusgroupBehavior(segment);
  if (behavior === null) return null;
  const items = segmentItems(segment);
  if (items.length === 0) return null;
  if (key === "home") return items[0];
  if (key === "end") return items[items.length - 1];
  const inline = key === "left" || key === "right";
  const want = behavior.axis === "inline";
  if (inline !== want) return null;
  const i = items.indexOf(from);
  if (i < 0) return null;
  const step = key === "right" || key === "down" ? 1 : -1;
  let j = i + step;
  if (j < 0 || j >= items.length) {
    if (!behavior.wrap) return null;
    j = (j + items.length) % items.length;
  }
  return items[j];
}
