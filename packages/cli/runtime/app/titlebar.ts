// The titlebar a page can draw into (<meta name="native-window" content="titlebar=hidden">): the
// area beside the window's own controls is published as env(titlebar-area-x/-y/-width/-height),
// as Window Controls Overlay names it, and env(safe-area-inset-top) is the bar's height, so a
// page can lay its toolbar out around the traffic lights. app-region: drag areas move the window.

import * as P from "../../shared/props.ts";
import { setEnvironmentVariable } from "../../shared/css/vars.ts";
import { Element, Node } from "../dom.ts";
import { hostTitlebarArea, hostWindowDrag } from "../host.ts";

/** What the macOS titlebar leaves for the page with no window to ask (a headless run): the
 *  traffic lights take the first 78px of a 28px bar, or 86px of a 52px one with hidden-inset. */
function headlessArea(options: string, width: number): number[] {
  if (/(^|;)titlebar=hidden-inset(;|$)/.test(options)) return [86, 0, width - 86, 52];
  if (/(^|;)titlebar=(hidden|transparent)(;|$)/.test(options)) return [78, 0, width - 78, 28];
  return [0, 0, 0, 0];
}

/** Publishes the titlebar area for env(); call after the window opens and when it resizes. */
export function publishTitlebarArea(options: string, width: number, windowed: boolean): void {
  const area = windowed ? [hostTitlebarArea(0), hostTitlebarArea(1), hostTitlebarArea(2), hostTitlebarArea(3)] : headlessArea(options, width);
  if (area[2] <= 0 && area[3] <= 0) return; // a default titlebar: env() takes its fallbacks
  setEnvironmentVariable("titlebar-area-x", `${area[0]}px`);
  setEnvironmentVariable("titlebar-area-y", `${area[1]}px`);
  setEnvironmentVariable("titlebar-area-width", `${area[2]}px`);
  setEnvironmentVariable("titlebar-area-height", `${area[3]}px`);
  setEnvironmentVariable("safe-area-inset-top", `${area[1] + area[3]}px`);
}

/** The app-region of the nearest element at or above `target` that sets one. */
export function appRegionAt(target: Node | null): number {
  for (let n: Node | null = target; n !== null; n = n.parentNode) {
    if (n instanceof Element && n.sv[P.P_APP_REGION] !== P.AR_NONE) return n.sv[P.P_APP_REGION];
  }
  return P.AR_NONE;
}

/** Hands a press in a drag region to the window, which follows the pointer until release. */
export function dragWindow(): void {
  hostWindowDrag();
}
