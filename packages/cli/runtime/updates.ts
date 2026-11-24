// The update check, exposed the way a browser exposes a service worker's update: the app's
// navigator.serviceWorker has a registration whose update() fetches the update document and whose
// updatefound event names a newer version. An app opts in by naming `update_url` in its web app
// manifest; the build writes that URL and the app's own version into the bundle, and nothing is
// fetched without it.
//
// The registration's worker is the update document: `installing` while it is fetched, `installed`
// when a newer version was read, and `waiting` once it is. `scriptURL` is where the update's
// artifact lives. Downloading and swapping the app itself is the next stage; the document's
// version, URL and notes are what a page shows a person today.

import { readFileSync } from "node:fs";
import { Event, ListenerEntry, MessageEvent, type EventListenerObject, type EventListenerOrEventListenerObject, type ListenerOptions } from "./dom.ts";
import { fetch } from "./fetch.ts";
import { hostBundleDir } from "./host.ts";
import { PAGE_TABLES_DIR } from "../shared/page-tables.ts";
import { compareVersions, parseUpdateDocument, type UpdateConfig } from "../shared/updates.ts";

/** The file the build writes beside the page tables (see compiler/updates.ts). */
const UPDATE_CONFIG_FILE = "update.json";

/** How long after the page loads the first check runs, and how often it runs again. */
const FIRST_CHECK_MS = 2000;
const CHECK_EVERY_MS = 6 * 60 * 60 * 1000;

/** A target for the small number of events this API fires. The DOM's dispatch walks a node
 *  tree; a registration and a worker are not in one, so listeners are called in order. */
export class UpdateEventTarget {
  private listeners = new Map<string, ListenerEntry[]>();

  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    if (listener === null) return;
    const capture = typeof options === "boolean" ? options : options !== undefined && options.capture === true;
    const once = typeof options === "boolean" || options === undefined ? false : options.once === true;
    const passive = typeof options === "boolean" || options === undefined ? false : options.passive === true;
    const fn = typeof listener === "function" ? listener : null;
    const object: EventListenerObject | null = fn === null ? listener as EventListenerObject : null;
    let list = this.listeners.get(type);
    if (list === undefined) {
      list = [];
      this.listeners.set(type, list);
    }
    for (const entry of list) {
      if (entry.capture === capture && entry.fn === fn && entry.object === object) return;
    }
    list.push(new ListenerEntry(fn, object, capture, once, passive));
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    const list = this.listeners.get(type);
    if (list === undefined || listener === null) return;
    const capture = typeof options === "boolean" ? options : options !== undefined && options.capture === true;
    const fn = typeof listener === "function" ? listener : null;
    const object: EventListenerObject | null = fn === null ? listener as EventListenerObject : null;
    for (let i = 0; i < list.length; i++) {
      const entry = list[i];
      if (entry.capture === capture && entry.fn === fn && entry.object === object) {
        list.splice(i, 1);
        return;
      }
    }
  }

  dispatchEvent(event: Event): boolean {
    this.emit(event);
    return !event.defaultPrevented;
  }

  /** Runs the listeners for the event on this target. The DOM's Event names a Node it was
   *  dispatched at, which a registration isn't, so the event's target stays null and a listener
   *  reaches its registration through the closure that added it. */
  protected emit(event: Event): void {
    const list = this.listeners.get(event.type);
    if (list === undefined) return;
    for (const entry of list.slice()) {
      if (entry.once) {
        const i = list.indexOf(entry);
        if (i >= 0) list.splice(i, 1);
      }
      event.passiveListener = entry.passive;
      if (entry.fn !== null) entry.fn.call(this, event);
      else if (entry.object !== null) entry.object.handleEvent(event);
      event.passiveListener = false;
      if (event.immediateStopped) return;
    }
  }
}

/** A newer version the check found, as the registration's worker. */
export class ServiceWorker extends UpdateEventTarget {
  /** Where the update's artifact lives. */
  readonly scriptURL: string;
  private stateValue: ServiceWorkerState;

  constructor(scriptURL: string, state: ServiceWorkerState) {
    super();
    this.scriptURL = scriptURL;
    this.stateValue = state;
  }

  get state(): ServiceWorkerState { return this.stateValue; }

  /** Moves the worker's state and fires statechange, as a browser's worker does. */
  setState(state: ServiceWorkerState): void {
    if (this.stateValue === state) return;
    this.stateValue = state;
    this.dispatchEvent(new Event("statechange"));
  }

  /** Posts a message to the worker. The update's worker is the update document, which has no
   *  script of its own to receive one, so this fires the worker's message listeners and nothing
   *  else; a page can use it to hand the waiting version around. */
  postMessage(message: unknown): void {
    this.dispatchEvent(new MessageEvent("message", { data: message }));
  }
}

export type ServiceWorkerState = "installing" | "installed" | "activating" | "activated" | "redundant";

/** The registration: the app's update check, with the newer version as its waiting worker. */
export class ServiceWorkerRegistration extends UpdateEventTarget {
  readonly scope: string;
  installing: ServiceWorker | null = null;
  waiting: ServiceWorker | null = null;
  readonly active: ServiceWorker;
  private readonly config: UpdateConfig;
  private inFlight: Promise<void> | null = null;

  constructor(config: UpdateConfig, scope: string) {
    super();
    this.config = config;
    this.scope = scope;
    // The running app is the active version; a check that finds a newer one puts it in waiting.
    this.active = new ServiceWorker("file:///", "activated");
  }

  /** Checks for an update, resolving after the document is read. A newer version appears as
   *  `waiting`; a check that finds none changes nothing. */
  update(): Promise<void> {
    if (this.inFlight !== null) return this.inFlight;
    this.inFlight = this.check().then(
      () => { this.inFlight = null; },
      (err) => { this.inFlight = null; throw err; },
    );
    return this.inFlight;
  }

  private async check(): Promise<void> {
    const response = await fetch(this.config.url, { cache: "no-store" });
    if (!response.ok) throw new TypeError(`Failed to check for updates: ${response.status} ${response.statusText}`);
    let value: unknown;
    try {
      value = await response.json();
    } catch {
      throw new TypeError("The update document is not JSON");
    }
    const document = parseUpdateDocument(value);
    if (document === null) throw new TypeError("The update document names no version");
    if (compareVersions(document.version, this.config.version) <= 0) return;
    const worker = new ServiceWorker(document.url === "" ? this.config.url : document.url, "installing");
    this.installing = worker;
    this.dispatchEvent(new Event("updatefound"));
    worker.setState("installed");
    this.waiting = worker;
    this.installing = null;
  }
}

/** navigator.serviceWorker for an app that opted into updates: getRegistration(), ready,
 *  registration.update() and updatefound. `register()` has nothing to register — the app is its
 *  own worker — so it rejects with that explanation. */
export class ServiceWorkerContainer extends UpdateEventTarget {
  readonly ready: Promise<ServiceWorkerRegistration>;
  readonly controller: ServiceWorker | null = null;
  private readonly registration: ServiceWorkerRegistration | null;

  constructor() {
    super();
    const config = readUpdateConfig();
    if (config === null) {
      this.registration = null;
      // A page that awaits ready with no update URL waits forever, as it does in a browser with
      // no registration.
      this.ready = new Promise<ServiceWorkerRegistration>(() => {});
      return;
    }
    const registration = new ServiceWorkerRegistration(config, "file:///");
    this.registration = registration;
    this.ready = Promise.resolve(registration);
    // Check once the page has had a moment to attach its listeners, then every six hours. The
    // check is opt-in, so a failure is silent: the page hears nothing and the app runs as is.
    setTimeout(() => { void registration.update().catch(() => {}); }, FIRST_CHECK_MS);
    setInterval(() => { void registration.update().catch(() => {}); }, CHECK_EVERY_MS);
  }

  getRegistration(): Promise<ServiceWorkerRegistration | undefined> {
    return Promise.resolve(this.registration ?? undefined);
  }

  getRegistrations(): Promise<ServiceWorkerRegistration[]> {
    return Promise.resolve(this.registration === null ? [] : [this.registration]);
  }

  register(): Promise<ServiceWorkerRegistration> {
    return Promise.reject(new TypeError("this app is its own service worker; declare update_url in its web app manifest"));
  }
}

/** Reads the build's update config from the bundle, or null when the app didn't opt in. */
function readUpdateConfig(): UpdateConfig | null {
  let dir = "";
  try {
    hostBundleDir((d) => { dir = d; });
  } catch {
    return null;
  }
  if (dir === "") return null;
  let text = "";
  try {
    text = readFileSync(dir + "/" + PAGE_TABLES_DIR + "/" + UPDATE_CONFIG_FILE, "utf8");
  } catch {
    return null;
  }
  try {
    const value: unknown = JSON.parse(text);
    if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
    const record = value as Record<string, unknown>;
    if (typeof record["url"] !== "string" || !/^https?:\/\//i.test(record["url"])) return null;
    if (typeof record["version"] !== "string") return null;
    const name = typeof record["name"] === "string" ? record["name"] : "app";
    return { url: record["url"], version: record["version"], name };
  } catch {
    return null;
  }
}
