// Which elements paint through a layer of their own, so a change to their transform or opacity can
// be composited without recording or rastering the page again.
//
// A layer never changes stacking by itself: an element that would not otherwise be a stacking
// context becomes one only when `will-change` asks for it, which the spec makes a stacking
// context of its own. The layer's commands sit exactly where its box painted them, so the flat
// replay is unchanged.

import * as P from "../shared/props.ts";
import { willChangeRows } from "../shared/css/willchange.ts";
import type { Node } from "./dom.ts";

/** The compositable properties an element's layer can move without repainting: a bit each. */
export const LAYER_TRANSFORM = 1;
export const LAYER_OPACITY = 2;
export const LAYER_FILTER = 4;

/**
 * The compositable properties `will-change` names: transform (in any of its forms), opacity, or
 * filter. Those make the box a stacking context and are worth a layer even before anything moves;
 * `scroll-position` and `contents` are not properties a layer can animate here.
 */
export function willChangeBits(el: Node): number {
  const row = willChangeRows.row(el.sv[P.P_WILL_CHANGE]);
  if (row === null) return 0;
  let bits = 0;
  for (const entry of row) {
    if (entry === P.P_TRANSFORM || entry === P.P_TRANSLATE || entry === P.P_ROTATE || entry === P.P_SCALE) {
      bits |= LAYER_TRANSFORM;
    } else if (entry === P.P_OPACITY) {
      bits |= LAYER_OPACITY;
    } else if (entry === P.P_FILTER) {
      bits |= LAYER_FILTER;
    }
  }
  return bits;
}
