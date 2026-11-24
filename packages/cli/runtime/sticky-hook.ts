// The layout's sticky-positioning shift, for the DOM to report a box's viewport position with.
// It lives in a module of its own because the DOM can't import the layout, which imports the DOM.

import type { Node } from "./dom.ts";

/** How far a sticky box is drawn from where it sits in the flow, on one axis; 0 for any other box. */
export let stickyShiftHook: (el: Node, horizontal: boolean) => number = () => 0;

export function setStickyShiftHook(fn: (el: Node, horizontal: boolean) => number): void {
  stickyShiftHook = fn;
}
