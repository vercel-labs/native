// Sticky positioning: a box that stays in the flow but shifts inside its nearest scrollport to
// hold its insets, for as long as its containing block is around it to hold it back.

import * as P from "../../shared/props.ts";
import { Node, document } from "../dom.ts";
import { setStickyShiftHook } from "../sticky-hook.ts";
import { display, len } from "./box-model.ts";
import { isScrollContainer } from "./flex.ts";

/**
 * The scroller a sticky box sticks to — its nearest scrolling ancestor, or the root element, whose
 * scroll moves the whole page — and whether the page's own scroll is kept out of the box because a
 * fixed ancestor anchors it to the viewport. Inside such an ancestor the viewport is still the
 * scrollport, but the box doesn't move when the page rolls, so its insets hold it where it is.
 */
function scrollerOf(el: Node): [Node | null, boolean] {
  for (let a = el.parentElement; a !== null; a = a.parentElement) {
    if (a === document.documentElement) return [a, false];
    if (isScrollContainer(a)) return [a, false];
    if (a.fixedViewport) return [document.documentElement, true];
  }
  return [null, false];
}

/** The box that constrains a sticky box: its nearest block container ancestor's content box. */
function containingBox(el: Node): Node | null {
  for (let a = el.parentElement; a !== null; a = a.parentElement) {
    const d = display(a);
    if (d !== P.D_INLINE && d !== P.D_NONE) return a;
  }
  return null;
}

/**
 * `from`'s border-box position in `stop`'s content coordinates — the coordinates the scroller's
 * children are laid out in, before its scroll — or null when `from` isn't inside `stop`.
 */
function offsetIn(from: Node, stop: Node, horizontal: boolean): number | null {
  let v = 0;
  let a: Node | null = from;
  while (a !== null) {
    if (a === stop) return v;
    v += horizontal ? a.x : a.y;
    a = a.parentElement;
  }
  return null;
}

/**
 * How far a sticky box shifts on one axis, given where its scroll container is scrolled to now.
 * The shift is worked out on every read rather than stored, since scrolling doesn't lay the page
 * out again.
 */
export function stickyShift(el: Node, horizontal: boolean): number {
  if (el.sv[P.P_POSITION] !== P.POS_STICKY) return 0;
  const startP = horizontal ? P.P_LEFT : P.P_TOP;
  const endP = horizontal ? P.P_RIGHT : P.P_BOTTOM;
  const startAuto = el.su[startP] === P.U_AUTO;
  const endAuto = el.su[endP] === P.U_AUTO;
  if (startAuto && endAuto) return 0;
  const [sc, anchored] = scrollerOf(el);
  if (sc === null) return 0;

  // The box's own place, and its containing block's content box, in the scroller's coordinates.
  const pos = offsetIn(el, sc, horizontal) ?? 0;
  let cb = containingBox(el);
  let cbPos = cb === null ? null : offsetIn(cb, sc, horizontal);
  if (cb === null || cbPos === null) {
    cb = sc;
    cbPos = 0;
  }
  // A viewport-anchored box ignores the page's own scroll; otherwise the scroller moves the box.
  const scroll = anchored ? 0 : horizontal ? sc.scrollX : sc.scrollY;
  const scroller = sc as unknown as { clientWidth: number; clientHeight: number };
  const portSize = horizontal ? scroller.clientWidth : scroller.clientHeight;
  const cbStart = cbPos + (horizontal ? cb.contentX : cb.contentY) + (cb === sc ? scroll : 0);
  const cbSize = horizontal ? cb.contentW : cb.contentH;
  const size = horizontal ? el.w : el.h;
  // Percentages of the insets resolve against the containing block, as they do for an offset.
  const start = startAuto ? NaN : len(el, startP, cbSize);
  const end = endAuto ? NaN : len(el, endP, cbSize);

  let d = 0;
  // The start inset pushes the box inward, and wins when both insets would push it.
  let pushed = false;
  if (!Number.isNaN(start)) {
    const want = scroll + start - pos;
    if (want > 0) {
      d = want;
      pushed = true;
    }
  }
  if (!Number.isNaN(end) && !pushed) {
    const want = scroll + portSize - end - size - pos;
    if (want < d) d = want;
  }
  // The box can't be pushed out of its containing block: a shift down stops at the block's end
  // edge, a shift up at its start edge. A box whose static position is already outside the block
  // stays where it is — its insets don't drag it in.
  if (d > 0) return Math.min(d, Math.max(0, cbStart + cbSize - (pos + size)));
  if (d < 0) return Math.max(d, Math.min(0, cbStart - pos));
  return 0;
}

// The DOM reports a box's viewport position itself, and can't import the layout for it.
setStickyShiftHook(stickyShift);
