// The window's timers as bare globals, the way a classic script names them: `setTimeout(fn, 0)`
// in a page is window.setTimeout, with the numeric id clearTimeout takes back.

import { window } from "../window.ts";

export function setTimeout(handler: () => void, timeout?: number): number {
  return window.setTimeout(handler, timeout);
}

export function clearTimeout(id?: number): void {
  window.clearTimeout(id);
}

export function setInterval(handler: () => void, timeout?: number): number {
  return window.setInterval(handler, timeout);
}

export function clearInterval(id?: number): void {
  window.clearInterval(id);
}
