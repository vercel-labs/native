// localStorage: a persistent map of strings, one file per app under Application Support.
// The host owns the map and the file; this is the web-facing API over it.

import { document } from "./dom.ts";
import {
  hostStorageOpen, hostStorageHas, hostStorageGet, hostStorageSet, hostStorageRemove,
  hostStorageClear, hostStorageLength, hostStorageKey,
} from "./host.ts";

let lastValue = "";
let opened = false;

/** Opens the app's store. Its name picks the file; tests can point NATIVE_STORAGE at one. */
function ensureOpen(): void {
  if (opened) return;
  opened = true;
  hostStorageOpen(document.title === "" ? "app" : document.title);
}

export class Storage {
  get [Symbol.toStringTag](): string { return "Storage"; }
  get length(): number {
    ensureOpen();
    return hostStorageLength();
  }

  getItem(key: string): string | null {
    ensureOpen();
    if (hostStorageHas(key) === 0) return null;
    lastValue = "";
    hostStorageGet(key, (value) => {
      lastValue = value;
    });
    return lastValue;
  }

  setItem(key: string, value: string): void {
    ensureOpen();
    hostStorageSet(key, value);
  }

  removeItem(key: string): void {
    ensureOpen();
    hostStorageRemove(key);
  }

  clear(): void {
    ensureOpen();
    hostStorageClear();
  }

  key(index: number): string | null {
    ensureOpen();
    if (index < 0 || index >= hostStorageLength()) return null;
    lastValue = "";
    hostStorageKey(index, (value) => {
      lastValue = value;
    });
    return lastValue;
  }
}

export const localStorage: Storage = new Storage();

/**
 * The store that lasts as long as the app runs: nothing is written to a file, so a relaunch starts
 * with it empty, as a browser's session store does when its tab closes.
 */
export class SessionStorage {
  get [Symbol.toStringTag](): string { return "Storage"; }
  private keys: string[] = [];
  private values: string[] = [];

  get length(): number {
    return this.keys.length;
  }

  getItem(key: string): string | null {
    const i = this.keys.indexOf(key);
    return i < 0 ? null : this.values[i];
  }

  setItem(key: string, value: string): void {
    const i = this.keys.indexOf(key);
    if (i < 0) {
      this.keys.push(key);
      this.values.push(value);
    } else {
      this.values[i] = value;
    }
  }

  removeItem(key: string): void {
    const i = this.keys.indexOf(key);
    if (i < 0) return;
    this.keys.splice(i, 1);
    this.values.splice(i, 1);
  }

  clear(): void {
    this.keys = [];
    this.values = [];
  }

  key(index: number): string | null {
    if (index < 0 || index >= this.keys.length) return null;
    return this.keys[index];
  }
}

export const sessionStorage: SessionStorage = new SessionStorage();
