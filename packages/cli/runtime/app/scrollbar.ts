// The scroll containers whose overlay scrollbar is showing, and when each last moved, so the
// loop can fade the bars out. It lives in a module of its own because both the wheel's scrolling
// and a script's smooth scroll note the same containers.

import type { Node } from "../dom.ts";

export const scrolling = { active: [] as Node[] };

/** Notes that `el` just scrolled: its bar shows now, and fades a while after it stops. */
export function noteScroll(el: Node): void {
  el.lastScroll = Date.now();
  if (scrolling.active.indexOf(el) < 0) scrolling.active.push(el);
}
