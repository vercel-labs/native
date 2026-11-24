// Document modes and the layout quirks they turn on. The doctype decides the mode (HTML's
// "quirks mode" algorithm); the runtime reads it once at mount and the layout asks as it goes.

import * as P from "../shared/props.ts";
import type { Node } from "./dom.ts";
import { viewport } from "./viewport.ts";

/** 0 no-quirks, 1 quirks, 2 limited-quirks. */
let mode = 0;

export function setDocumentMode(m: number): void {
  mode = m;
}

export function isQuirks(): boolean {
  return mode === 1;
}

export function isLimitedQuirks(): boolean {
  return mode === 2;
}

/**
 * The height a percentage height resolves against. In standards and limited-quirks modes that is
 * exactly the containing block's height — NaN when it has none — but quirks mode resolves it
 * against the nearest ancestor whose own height is a length, and against the viewport when there
 * is none, so a `height: 100%` deep inside auto-height boxes still fills the window.
 */
export function quirkHeight(el: Node, cbH: number): number {
  if (!Number.isNaN(cbH) || mode !== 1) return cbH;
  for (let a = el.parentElement; a !== null; a = a.parentElement) {
    // The quirk doesn't reach into a flex container: a percentage height inside one resolves
    // against the container's own height, and an auto one there behaves as auto (css-flexbox's
    // "the percentage height resolution quirk isn't applied to flexboxes").
    const d = a.sv[P.P_DISPLAY];
    if (d === P.D_FLEX || d === P.D_INLINE_FLEX) return NaN;
    // Nor does it look past a table cell: a percentage height in a cell's content resolves
    // against the cell's height (when that is definite) and is auto otherwise, never against an
    // ancestor outside the cell (css-tables-3 §table-cell-content).
    if (d === P.D_TABLE_CELL) return NaN;
    const u = a.su[P.P_HEIGHT];
    if (u === P.U_AUTO || u === P.U_PCT || Number.isNaN(a.h)) continue;
    return Math.max(0, a.h - a.sv[P.P_PADDING_TOP] - a.sv[P.P_PADDING_BOTTOM]);
  }
  return viewport.h;
}
