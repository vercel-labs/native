// The root element's font size, which a rem length is a multiple of. A module of its own so the
// places that resolve a rem don't have to reach into the style engine for it.

import * as P from "../shared/props.ts";
import { document } from "./dom.ts";

/**
 * The root element's font size in pixels. The initial 16px stands in for the moment before the
 * root has been computed, and for a document with no root at all.
 */
export function rootFontSize(): number {
  const root = document.documentElement;
  return root === null || root.sv[P.P_FONT_SIZE] <= 0 ? 16 : root.sv[P.P_FONT_SIZE];
}
