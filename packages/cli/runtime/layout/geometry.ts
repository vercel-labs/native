// Geometry queries: offset parents, offsets, viewport positions, scrolling into view, caret hit testing.

import * as P from "../../shared/props.ts";
import { Node, Element, HTMLInputElement, document, geometry, boxKids, rtlScrollsX, rtlScrollsY } from "../dom.ts";
import { fontKey } from "../style.ts";
import { len, measure, viewport, display, zeroIfNaN } from "./box-model.ts";
import { isScrollContainer } from "./flex.ts";
import { stickyShift } from "./sticky.ts";

/** The nearest positioned ancestor, or null when offsets are measured from the initial containing block. */
export function offsetParent(el: Node): Node | null {
  if (el.sv[P.P_POSITION] === P.POS_FIXED) return null;
  let a = el.parentElement;
  while (a !== null) {
    if (a.sv[P.P_POSITION] !== P.POS_STATIC) return a;
    // As in CSSOM View, a table (or inline-table) and a table cell are offset parents of their
    // own, so content inside a cell is measured from the cell.
    const d = display(a);
    if (d === P.D_TABLE || d === P.D_INLINE_TABLE || d === P.D_TABLE_CELL) return a;
    a = a.parentElement;
  }
  return null;
}

/** offsetLeft/offsetTop: the border-box edge relative to the offsetParent's padding edge. */
function offsetFrom(el: Node, horizontal: boolean): number {
  const op = offsetParent(el);
  let v = 0;
  let e: Node | null = el;
  while (e !== null && e !== op) {
    v += horizontal ? e.x + stickyShift(e, true) : e.y + stickyShift(e, false);
    e = e.parentElement;
  }
  return op instanceof Element ? v - op.borderWidth : v;
}

export function offsetLeft(el: Node): number {
  return offsetFrom(el, true);
}

export function offsetTop(el: Node): number {
  return offsetFrom(el, false);
}

/**
 * The element accessors read the offset queries through the dom module, which can't import this
 * one. This module may run while dom.ts is still initializing, since the two import each other
 * through the layout modules, so the app calls this once every module is up, before its first
 * frame; until then the dom module answers with the static walk and zero offsets.
 */
export function installGeometryQueries(): void {
  geometry.offsetParent = offsetParent;
  geometry.offsetLeft = offsetLeft;
  geometry.offsetTop = offsetTop;
}

/** The element's border-box origin in viewport coordinates (after scrolling). */
export function absolutePosition(el: Node): number[] {
  let x = 0;
  let y = 0;
  let e: Node | null = el;
  // The page scrolling moves the box unless it sits in a viewport-anchored fixed box, so the
  // scrolls at and above that box are left out (see fixedViewport).
  let anchored = false;
  while (e !== null) {
    x += e.x + stickyShift(e, true);
    y += e.y + stickyShift(e, false);
    if (e.fixedViewport) anchored = true;
    const p: Node | null = e.parentElement;
    if (p !== null && !anchored) {
      y -= p.scrollY;
      x -= p.scrollX;
    }
    e = p;
  }
  return [x, y];
}

/**
 * Scrolls every scroll container between `el` and the viewport so the box shows, starting with
 * the nearest. `block` and `inline` name the edge to line up with the scrollport — `start`,
 * `center` or `end` — or `nearest`, which moves only as far as the box has to. `behavior` is the
 * DOM's word for a jump or a journey, and `auto` follows each container's scroll-behavior.
 */
export function scrollIntoView(el: Node, block: string, inline: string, behavior: string): void {
  let inner: Node = el;
  for (;;) {
    let box: Element | null = inner.parentElement;
    while (box !== null && box !== document.documentElement && !isScrollContainer(box)) box = box.parentElement;
    // With no scroll container around it, the page's own scrolling brings the box into view.
    if (box === null) box = document.documentElement;
    // The box's edges relative to the container's padding-box top and left, in unscrolled
    // content coordinates.
    let top = 0;
    let left = 0;
    let e: Node | null = inner;
    while (e !== null && e !== box) {
      top += e.y;
      left += e.x;
      const p: Node | null = e.parentElement;
      if (p !== null && p !== box) {
        top -= p.scrollY;
        left -= p.scrollX;
      }
      e = p;
    }
    top -= box.borderWidth;
    left -= box.clientLeft;
    // The box's scroll margin and the container's scroll padding both keep the box that far from
    // the scrollport's edge, so they widen the box the alignment sees (CSS Scroll Snap 4, 5.1).
    const vt = box.clientHeight;
    const vl = box.clientWidth;
    const mt = insetPx(inner, P.P_SCROLL_MARGIN_TOP, vt);
    const mb = insetPx(inner, P.P_SCROLL_MARGIN_BOTTOM, vt);
    const ml = insetPx(inner, P.P_SCROLL_MARGIN_LEFT, vl);
    const mr = insetPx(inner, P.P_SCROLL_MARGIN_RIGHT, vl);
    const padT = insetPx(box, P.P_SCROLL_PADDING_TOP, vt);
    const padB = insetPx(box, P.P_SCROLL_PADDING_BOTTOM, vt);
    const padL = insetPx(box, P.P_SCROLL_PADDING_LEFT, vl);
    const padR = insetPx(box, P.P_SCROLL_PADDING_RIGHT, vl);
    // In a right-to-left box the inline axis runs leftward: its start edge is the right one, so
    // the physical alignment is the mirror of what the edge names.
    const rtl = box.sv[P.P_DIRECTION] === P.DIR_RTL && box.sv[P.P_WRITING_MODE] === P.WM_HORIZONTAL_TB;
    const inlineEdge = rtl ? (inline === "start" ? "end" : inline === "end" ? "start" : inline) : inline;
    const x = alignTarget(inlineEdge, left - ml - padL, inner.w + ml + mr + padL + padR, vl, box.scrollX);
    const y = alignTarget(block, top - mt - padT, inner.h + mt + mb + padT + padB, vt, box.scrollY);
    // The runtime scrolls a script's scroll, so a container whose scroll-behavior travels carries
    // this one with it, and a test's animation frames drive it.
    box.scriptScrollTo(x, y, behavior);
    if (box === document.documentElement) return;
    inner = box;
  }
}

/** A scroll inset on one axis in px: a percentage resolves against the scrollport it applies to. */
function insetPx(el: Node, p: number, base: number): number {
  return zeroIfNaN(len(el, p, base));
}

/** The offset that lines a box of `size` at `start` up with a scrollport of `view` as `edge` asks. */
function alignTarget(edge: string, start: number, size: number, view: number, current: number): number {
  if (edge === "center") return start - (view - size) / 2;
  if (edge === "end") return start + size - view;
  if (edge === "start") return start;
  // `nearest`: a box already in the scrollport stays put, and one outside it lines up with the
  // edge it went past.
  if (start < current) return start;
  if (start + size > current + view) return start + size - view;
  return current;
}

/** The caret index in an input nearest to viewport x. */
export function inputIndexAt(input: HTMLInputElement, viewportX: number): number {
  const local = viewportX - absolutePosition(input)[0] - input.contentX + input.scrollX;
  const text = input.displayText;
  const size = input.sv[P.P_FONT_SIZE];
  const weight = fontKey(input);
  let best = 0;
  let bestDist = Math.abs(local);
  for (let i = 1; i <= text.length; i++) {
    const d = Math.abs(measure(text.slice(0, i), size, weight) - local);
    if (d < bestDist) {
      best = i;
      bestDist = d;
    }
  }
  return best;
}

/** Clamps scroll offsets once final sizes are known (intermediate flex passes would reset them). */
export function clampScroll(el: Node): void {
  clampScrollOf(el);
  for (const c of boxKids(el)) clampScroll(c);
}

/** Clamps one box's scroll offsets to what its layout lets it scroll (see clampScroll). */
export function clampScrollOf(el: Node): void {
  // The root scrolls the viewport, which is the viewport's size however tall or wide the page is.
  if (el === (document.documentElement as Node)) {
    const e = el as Element;
    el.scrollY = Math.max(0, Math.min(el.scrollY, e.scrollHeight - e.clientHeight));
    el.scrollX = Math.max(0, Math.min(el.scrollX, e.scrollWidth - e.clientWidth));
  } else if (isScrollContainer(el)) {
    el.scrollY = Math.max(0, Math.min(el.scrollY, el.naturalH - el.h));
    // The same reach scrollWidth reports: content past the content box, not past the box itself.
    const over = el.naturalW - el.contentX - el.contentW;
    // A right-to-left box starts at its right edge, which is its start edge: an unscrolled one
    // shows the end of its contents, as a browser's does. A vertical box with an rtl inline axis
    // starts at its bottom edge the same way.
    if (!el.scrollStarted && over > 0) {
      el.scrollStarted = true;
      if (rtlScrollsX(el as Element)) el.scrollX = over;
    }
    const down = el.naturalH - el.h;
    if (!el.scrollStartedY && down > 0) {
      el.scrollStartedY = true;
      if (rtlScrollsY(el as Element)) el.scrollY = down;
    }
    el.scrollX = Math.max(0, Math.min(el.scrollX, over > 0 ? over : 0));
  } else {
    el.scrollY = 0;
    // An input's scrollX is the text scrolled inside the field, which the caret keeps in view.
    if (!(el instanceof HTMLInputElement)) el.scrollX = 0;
  }
}
