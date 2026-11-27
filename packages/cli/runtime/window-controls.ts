// navigator.windowControlsOverlay: the Window Controls Overlay API's view of the titlebar area.
// A window whose page draws under the titlebar (titlebar=hidden, hidden-inset or transparent)
// reports the region the page can lay out into beside the traffic lights: `visible` says whether
// the page draws there, and getTitlebarAreaRect() gives that region in CSS pixels, in the same
// units as env(titlebar-area-x/-y/-width/-height). The runtime publishes both from the host's
// window (see app/titlebar.ts); geometrychange fires when a resize moves the region.

import type { EventListenerOrEventListenerObject } from "./dom.ts";
import { DOMRect, Event } from "./dom.ts";

export class WindowControlsOverlay {
  get [Symbol.toStringTag](): string { return "WindowControlsOverlay"; }
  private visibleValue = false;
  private area: number[] = [0, 0, 0, 0];
  private listeners: EventListenerOrEventListenerObject[] = [];

  /** Whether the page draws under the titlebar, i.e. the window hides the system titlebar. */
  get visible(): boolean {
    return this.visibleValue;
  }

  /** The titlebar region left to the page, in CSS pixels, with y down from the window's top. */
  getTitlebarAreaRect(): DOMRect {
    return new DOMRect(this.area[0], this.area[1], this.area[2], this.area[3]);
  }

  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null): void {
    if (type !== "geometrychange" || listener === null) return;
    for (const held of this.listeners) if (held === listener) return;
    this.listeners.push(listener);
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null): void {
    if (type !== "geometrychange" || listener === null) return;
    for (let i = this.listeners.length - 1; i >= 0; i--) {
      if (this.listeners[i] === listener) { this.listeners.splice(i, 1); return; }
    }
  }

  /** Runs the geometrychange listeners the way an event target does. */
  dispatchEvent(event: Event): boolean {
    const snapshot = this.listeners.slice();
    for (const listener of snapshot) {
      if (typeof listener === "function") listener(event);
      else listener.handleEvent(event);
    }
    return true;
  }

  /** Publishes the area the page can use; fires geometrychange when it moved or appeared. */
  set(visible: boolean, area: number[]): void {
    const changed = visible !== this.visibleValue ||
      area[0] !== this.area[0] || area[1] !== this.area[1] ||
      area[2] !== this.area[2] || area[3] !== this.area[3];
    this.visibleValue = visible;
    this.area = [area[0], area[1], area[2], area[3]];
    if (!changed) return;
    this.dispatchEvent(new Event("geometrychange"));
  }
}

export const windowControlsOverlay = new WindowControlsOverlay();
