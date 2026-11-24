// A dev build reports when its first frame is painted, so `native dev` can print how long an edit
// took to reach the window. A release build never sets the hook, which costs one null test a
// frame; the dev command clears it by setting NATIVE_DEV_READY.

/** Called once, when the page's first frame is on the display list. */
let hook: (() => void) | null = null;

/** Sets what a dev build reports after its first frame. */
export function onFirstFrame(fn: () => void): void {
  hook = fn;
}

/** Runs the hook once, if one is set; frame() calls this after every frame. */
export function firstFramePainted(): void {
  const fn = hook;
  if (fn === null) return;
  hook = null;
  fn();
}
