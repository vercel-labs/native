// Layout on demand, for a DOM read that needs the boxes as they are: elementFromPoint() forces
// layout in a browser, and this build lays the page out on the frame. It lives in a module of its
// own because the DOM can't import the loop, which imports the DOM.

/** Computes styles and lays the page out if either is out of date, as a frame would. */
export let flushLayoutHook: () => void = () => {};

export function setFlushLayoutHook(fn: () => void): void {
  flushLayoutHook = fn;
}
