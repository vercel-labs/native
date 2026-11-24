// Snapping, for the DOM's script scrolls: the choice depends on the laid-out snap areas, which
// live with the layout modules, and the DOM can't import those. It lives in a module of its own
// for that reason.

import type { Element } from "./dom.ts";

/**
 * The offsets a scroll of `box` to (x, y) lands on; the flags name the axes the scroll sets. A
 * page without a snap engine in it keeps the offsets as they are.
 */
export let snapScrollPositionHook: (box: Element, x: number, y: number, snapX: boolean, snapY: boolean) => number[] =
  (box, x, y) => [x, y];

export function setSnapScrollPositionHook(
  fn: (box: Element, x: number, y: number, snapX: boolean, snapY: boolean) => number[],
): void {
  snapScrollPositionHook = fn;
}
