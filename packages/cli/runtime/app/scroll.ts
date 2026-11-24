// Wheel scrolling and overlay scrollbar fading.

import * as P from "../../shared/props.ts";
import { Node, Element, Event, document, dispatch, trusted, invalidatePaint } from "../dom.ts";
import { markPaintRects } from "../invalidation.ts";
import { viewportScrollsX, viewportScrollsY, wheelScrollsX, wheelScrollsY } from "../layout/box-model.ts";
import { hitTest } from "../paint.ts";
import { SCROLLBAR_VISIBLE_MS } from "../../shared/props.ts";
import { dispatchWindow } from "../window.ts";
import { pointer, updateHover } from "./pointer.ts";
import { noteScroll, scrolling } from "./scrollbar.ts";
import { cancelSmoothScroll } from "./smooth.ts";
import { selectPopupWheel } from "../select-popup.ts";

// ---------------------------------------------------------------------------
// Scrolling

/** How long after the last scroll step the hover is tested again, as Chrome settles it. */
const HOVER_SETTLE_MS = 100;
let hoverSettle: ReturnType<typeof setTimeout> | null = null;
let settleX = 0;
let settleY = 0;

/**
 * A scroll step moves the content under a pointer that didn't move. Chrome doesn't re-test the
 * hover on every step (each test restyles whatever is under the pointer); it tests once, shortly
 * after the scrolling stops, and that is what this does.
 */
function settleHover(x: number, y: number): void {
  settleX = x;
  settleY = y;
  if (hoverSettle !== null) clearTimeout(hoverSettle);
  hoverSettle = setTimeout(() => {
    hoverSettle = null;
    updateHover(hitTest(document.documentElement, settleX, settleY, 0, 0));
  }, HOVER_SETTLE_MS);
}

/** Tests the hover now: a gesture's last event knows the scrolling is over, so the timer is not
 *  needed and the page restyles once, at the end, rather than after an extra wait. */
function settleHoverNow(x: number, y: number): void {
  if (hoverSettle !== null) {
    clearTimeout(hoverSettle);
    hoverSettle = null;
  }
  settleX = x;
  settleY = y;
  updateHover(hitTest(document.documentElement, x, y, 0, 0));
}

/** Where in a wheel gesture the event is (hostEventPhase): 3 ends a finger gesture, 7 the momentum
 *  that follows it. */
function wheelGestureOver(phase: number): boolean {
  return phase === 3 || phase === 7 || phase === 4 || phase === 8;
}

/** Scrolls the innermost scroll container under (x, y) that can move in that direction. */
export function wheel(x: number, y: number, dy: number, dx: number = 0, phase: number = 0): void {
  // A wheel over the open select picker scrolls its rows, not the page behind them.
  if (selectPopupWheel(x, y, dy)) return;
  let el = hitTest(document.documentElement, x, y, 0, 0);
  const root = document.documentElement;
  while (el !== null && el !== root) {
    // Each axis scrolls only when its own overflow asks for it: `overflow-x: auto` with
    // `overflow-y: hidden` takes a sideways swipe and passes a vertical one on.
    const sx = wheelScrollsX(el);
    const sy = wheelScrollsY(el);
    // A body whose overflow propagated to the viewport doesn't scroll itself.
    if (el instanceof Element && el !== document.body && (sx || sy)) {
      const before = el.scrollTop;
      const beforeX = el.scrollLeft;
      // A wheel jumps the box there, whatever its scroll-behavior says, and stops any journey a
      // script's scroll had it on.
      if (dy !== 0 && sy) el.scrollInstant(el.scrollX, before - dy);
      if (dx !== 0 && sx) el.scrollInstant(beforeX - dx, el.scrollY);
      cancelSmoothScroll(el);
      if (el.scrollTop !== before || el.scrollLeft !== beforeX) {
        noteScroll(el);
        dispatch(trusted(new Event("scroll")), el);
        // The hover is tested once the scrolling settles, not on this step — and at once when the
        // event says the gesture has ended.
        if (wheelGestureOver(phase)) settleHoverNow(x, y);
        else settleHover(x, y);
        return;
      }
    }
    el = el.parentElement;
  }
  // Nothing inside the page could scroll: the page itself moves, as it does in a browser. The
  // viewport is scrolled by the root element, whatever its own overflow, and the scroll event
  // reaches the document and the window rather than the element under the pointer.
  if (!viewportScrollsX() && !viewportScrollsY()) return;
  const before = root.scrollTop;
  const beforeX = root.scrollLeft;
  if (dy !== 0 && viewportScrollsY()) root.scrollInstant(root.scrollX, before - dy);
  if (dx !== 0 && viewportScrollsX()) root.scrollInstant(beforeX - dx, root.scrollY);
  // A wheel over the page stops a smooth scroll of it, as it does over any other box.
  cancelSmoothScroll(root);
  if (root.scrollTop !== before || root.scrollLeft !== beforeX) {
    noteScroll(root);
    const ev = trusted(new Event("scroll"));
    dispatch(ev, document);
    dispatchWindow(ev);
    // As above: tested once the scrolling settles, not on every step.
    if (wheelGestureOver(phase)) settleHoverNow(x, y);
    else settleHover(x, y);
  }
}

/** Repaints once more when an overlay scrollbar should fade out. */
export function fadeScrollbars(): void {
  const now = Date.now();
  const root = document.documentElement;
  // The viewport's scrollbar is not an element's, but it fades on the same clock.
  const active = scrolling.active.indexOf(root) < 0 ? [root, ...scrolling.active] : scrolling.active;
  const still: Node[] = [];
  for (const el of active) {
    if (el.lastScroll < -1e8) continue;
    if (now - el.lastScroll > SCROLLBAR_VISIBLE_MS) {
      el.lastScroll = -1e9;
      // The bar is drawn inside its own box: repaint that box, not the page around it.
      if (el instanceof Element) {
        const box = el.getBoundingClientRect();
        markPaintRects([[box.left, box.top, box.width, box.height]]);
      } else invalidatePaint();
    } else still.push(el);
  }
  scrolling.active = still;
}
