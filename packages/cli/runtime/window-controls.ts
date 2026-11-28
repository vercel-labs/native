// navigator.windowControlsOverlay: the Window Controls Overlay API's view of the titlebar area.
// A window whose page draws under the titlebar (titlebar=hidden, hidden-inset or transparent)
// reports the region the page can lay out into beside the traffic lights: `visible` says whether
// the page draws there, and getTitlebarAreaRect() gives that region in CSS pixels, in the same
// units as env(titlebar-area-x/-y/-width/-height). The runtime publishes both from the host's
// window (see app/titlebar.ts); geometrychange fires when a resize moves the region.

import { DOMRect, Event, EventTarget } from "./dom.ts";
import type { EventInit } from "./events.ts";

export interface WindowControlsOverlayGeometryChangeEventInit extends EventInit {
  visible: boolean;
  titlebarAreaRect: DOMRect;
}

/** The event geometrychange delivers: the region and whether the page draws there, as the spec's
 *  WindowControlsOverlayGeometryChangeEvent has them. */
export class WindowControlsOverlayGeometryChangeEvent extends Event {
  get [Symbol.toStringTag](): string { return "WindowControlsOverlayGeometryChangeEvent"; }
  readonly visible: boolean;
  readonly titlebarAreaRect: DOMRect;

  constructor(type: string, init: WindowControlsOverlayGeometryChangeEventInit) {
    super(type);
    this.visible = init.visible;
    this.titlebarAreaRect = init.titlebarAreaRect;
  }
}

export class WindowControlsOverlay extends EventTarget {
  get [Symbol.toStringTag](): string { return "WindowControlsOverlay"; }
  private visibleValue = false;
  private area: number[] = [0, 0, 0, 0];

  /** Whether the page draws under the titlebar, i.e. the window hides the system titlebar. */
  get visible(): boolean {
    return this.visibleValue;
  }

  /** The titlebar region left to the page, in CSS pixels, with y down from the window's top. */
  getTitlebarAreaRect(): DOMRect {
    return new DOMRect(this.area[0], this.area[1], this.area[2], this.area[3]);
  }

  /** Publishes the area the page can use; fires geometrychange when it moved or appeared. */
  set(visible: boolean, area: number[]): void {
    const changed = visible !== this.visibleValue ||
      area[0] !== this.area[0] || area[1] !== this.area[1] ||
      area[2] !== this.area[2] || area[3] !== this.area[3];
    this.visibleValue = visible;
    this.area = [area[0], area[1], area[2], area[3]];
    if (!changed) return;
    // A real event target: the event carries target and currentTarget, and a listener registered
    // with `once` runs once, as every other event on this runtime does.
    this.dispatchEvent(new WindowControlsOverlayGeometryChangeEvent("geometrychange", {
      visible: this.visibleValue,
      titlebarAreaRect: this.getTitlebarAreaRect(),
    }));
  }
}

export const windowControlsOverlay = new WindowControlsOverlay();
