// The event target AudioContext and AudioNode are: their events don't bubble and have no tree, so
// they only need the listener list and dispatch the DOM gives them. An audio listener is a
// function or an object with handleEvent, as on any other event target.

import { Event } from "../dom.ts";

export type AudioEventListener = ((event: Event) => void) | { handleEvent(event: Event): void };

interface ListenerEntry {
  listener: AudioEventListener;
  once: boolean;
}

export class AudioEventTarget {
  private audioListeners: Map<string, ListenerEntry[]> = new Map();

  addEventListener(type: string, listener: AudioEventListener | null,
    options?: boolean | { once?: boolean }): void {
    if (listener === null) return;
    const once = typeof options === "object" && options !== null && options.once === true;
    let list = this.audioListeners.get(type);
    if (list === undefined) {
      list = [];
      this.audioListeners.set(type, list);
    }
    for (const entry of list) if (entry.listener === listener) return;
    list.push({ listener, once });
  }

  removeEventListener(type: string, listener: AudioEventListener | null): void {
    const list = this.audioListeners.get(type);
    if (list === undefined || listener === null) return;
    for (let i = 0; i < list.length; i++) {
      if (list[i].listener === listener) {
        list.splice(i, 1);
        return;
      }
    }
  }

  dispatchEvent(event: Event): boolean {
    // An audio event has no node tree, so there is nowhere for target to point in the DOM's
    // types; the event carries its own type and flags and listeners know their context.
    const list = this.audioListeners.get(event.type);
    if (list !== undefined) {
      const snapshot = list.slice();
      for (const entry of snapshot) {
        if (entry.once) {
          const i = list.indexOf(entry);
          if (i >= 0) list.splice(i, 1);
        }
        if (typeof entry.listener === "function") entry.listener.call(this, event);
        else entry.listener.handleEvent(event);
        if ((event as any).immediateStopped === true) break;
      }
    }
    return !event.defaultPrevented;
  }
}
