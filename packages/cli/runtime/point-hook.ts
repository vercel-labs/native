// The hit test, for the DOM to answer elementFromPoint() and elementsFromPoint() with. It lives in
// a module of its own because the DOM can't import paint, which imports the DOM.

import type { Element } from "./dom.ts";

/** Every element the pointer could reach at a viewport point, topmost first. */
export let pointHitsHook: (x: number, y: number) => Element[] = () => [];

export function setPointHitsHook(fn: (x: number, y: number) => Element[]): void {
  pointHitsHook = fn;
}
