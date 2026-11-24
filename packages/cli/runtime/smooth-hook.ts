// Smooth scrolling, as the DOM asks for it: an element's script scroll travels when its computed
// scroll-behavior says so, and the animator that carries it lives with the event loop. It lives in
// a module of its own because the DOM can't import the loop, which imports the DOM.

import type { Element, Node } from "./dom.ts";

/** Scrolls `el` to (x, y) over animation frames, replacing any journey it was on. */
export let smoothScrollHook: (el: Element, x: number, y: number) => void = () => {};

export function setSmoothScrollHook(fn: (el: Element, x: number, y: number) => void): void {
  smoothScrollHook = fn;
}

/** Stops the journey `el` is on, if any: a jump, a wheel or a fresh scroll replaces it. */
export let cancelSmoothScrollHook: (el: Node) => void = () => {};

export function setCancelSmoothScrollHook(fn: (el: Node) => void): void {
  cancelSmoothScrollHook = fn;
}
