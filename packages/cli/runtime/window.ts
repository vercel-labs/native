// The window globals: the viewport size, animation frames, timers, media queries, and
// window-level events. Kept apart from the DOM so the event loop, layout and the style engine
// can share them; the DOM reaches the window object through document.defaultView.

import type { Element, EventListener, EventListenerOrEventListenerObject, ListenerOptions, ScrollToOptions, Selection, WindowEventMap } from "./dom.ts";
import { Event, MediaQueryListEvent, MutationObserver, ResizeObserver, currentEvent, customElements, dispatch, document, dirty, getComputedStyle, setCurrentEvent, setDefaultView, setWindowEventHost, trusted } from "./dom.ts";
import { CSS } from "./cssom.ts";
import * as domIface from "./dom.ts";
import * as highlightIface from "./highlights.ts";
import * as intersectIface from "./intersection.ts";
import * as canvasIface from "./canvas.ts";
import * as fetchIface from "./fetch.ts";
import * as xhrIface from "./xhr.ts";
import * as eventSourceIface from "./eventsource.ts";
import * as webSocketIface from "./websocket.ts";
import * as mediaElementIface from "./media-element.ts";
import * as idbIface from "./indexeddb.ts";
import { IntersectionObserver } from "./intersection.ts";
import { localStorage, sessionStorage } from "./storage.ts";
import { ServiceWorkerContainer } from "./updates.ts";
import { invalidatePaint, invalidateStyle, layoutEpoch, markFullPaint } from "./invalidation.ts";
import { viewport } from "./viewport.ts";
import { hostBackingScale, hostQuit, hostPostMessage, hostWindowBlur, hostWindowClose, hostWindowFocus, hostWindowFrame, hostWindowId, hostWindowOpen, hostWindowSetFrame } from "./host.ts";
import { mediaMatches, refreshSystemSettings } from "./media.ts";
import { setTargetText } from "./target-text.ts";
import { Clipboard } from "./clipboard.ts";
import { setFollowLinkHook } from "./link-hook.ts";

// The audio element's engine registers here as the window loads, before any page markup is built.
mediaElementIface.installMediaElement();

export class MediaQueryList {
  get [Symbol.toStringTag](): string { return "MediaQueryList"; }
  readonly media: string;
  matches: boolean;
  private listeners: EventListener[] = [];

  constructor(media: string) {
    this.media = media;
    this.matches = mediaMatches(media);
  }

  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null): void {
    if (type === "change" && listener !== null) {
      if (typeof listener === "function") this.listeners.push(listener);
      else this.listeners.push((event: Event) => listener.handleEvent(event));
    }
  }
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null): void {
    if (type !== "change" || listener === null) return;
    const i = this.listeners.indexOf(listener as EventListener);
    if (i >= 0) this.listeners.splice(i, 1);
  }
  /** The legacy aliases older libraries use. */
  addListener(listener: EventListener): void {
    this.addEventListener("change", listener);
  }
  removeListener(listener: EventListener): void {
    this.removeEventListener("change", listener);
  }

  /** Re-evaluates after the viewport changed, firing change when the result differs. */
  update(): void {
    const now = mediaMatches(this.media);
    if (now === this.matches) return;
    this.matches = now;
    if (this.listeners.length === 0) return;
    const event = trusted(new MediaQueryListEvent("change", { matches: now, media: this.media }));
    event.target = document.body;
    // Through .call, as the DOM's own dispatch does: a listener typed for the narrower
    // MediaQueryListEvent is called with the event as it is, not converted.
    for (const fn of this.listeners.slice()) fn.call(this, event);
  }
}

// ---------------------------------------------------------------------------
// Animation frames

type FrameCallback = (time: number) => void;

const frameIds: number[] = [];
const frameCallbacks: FrameCallback[] = [];
let nextFrameId = 1;

export function requestAnimationFrame(callback: FrameCallback): number {
  const id = nextFrameId++;
  frameIds.push(id);
  frameCallbacks.push(callback);
  return id;
}

export function cancelAnimationFrame(id: number): void {
  const i = frameIds.indexOf(id);
  if (i < 0) return;
  frameIds.splice(i, 1);
  frameCallbacks.splice(i, 1);
}

/** Runs the callbacks due this frame with the frame's timestamp, in ms. */
export function runFrameCallbacks(time: number): void {
  if (frameCallbacks.length === 0) return;
  const due = frameCallbacks.slice();
  frameIds.length = 0;
  frameCallbacks.length = 0;
  // A callback that asks for another frame goes into the next batch, not this one.
  for (const cb of due) cb(time);
  // What a callback changed is what invalidated the frame: a DOM write, a canvas draw and a
  // style change of their own ask for the paint they need. A callback that only read the page,
  // or only advanced an animation's state, leaves the frame as it stands.
}

// ---------------------------------------------------------------------------
// window

/** The handle a timer returns, as the host's setTimeout declares it. */
type TimerHandle = ReturnType<typeof setTimeout>;

/** The window's timers by the number a script gets back, so clearTimeout can find the handle. */
const TIMERS = new Map<number, TimerHandle>();
/** The window's intervals, kept apart so clearing everything can tell them from timers. */
const INTERVALS = new Map<number, TimerHandle>();
let nextTimerId = 1;

/** The visual viewport: the app's window always shows the whole layout viewport at 1:1. */
export class VisualViewport {
  get [Symbol.toStringTag](): string { return "VisualViewport"; }
  get width(): number {
    return viewport.w;
  }
  get height(): number {
    return viewport.h;
  }
  get scale(): number {
    return 1;
  }
  get offsetLeft(): number {
    return 0;
  }
  get offsetTop(): number {
    return 0;
  }
  /** Nothing zooms or offsets the visual viewport here, so these never fire. */
  addEventListener(_type: string, _listener: EventListenerOrEventListenerObject | null): void {}
  removeEventListener(_type: string, _listener: EventListenerOrEventListenerObject | null): void {}
}

/**
 * The browser-facing identity of the app. A native window isn't a browser, so the user agent
 * names this runtime while keeping the Macintosh tokens libraries sniff for; the language comes
 * from the system, which the host doesn't report yet, so it is the default en-US.
 */
export class Navigator {
  get [Symbol.toStringTag](): string { return "Navigator"; }
  readonly userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) NativeSDK/0.1";
  readonly platform = "MacIntel";
  readonly language = "en-US";
  readonly languages: string[] = ["en-US"];
  readonly maxTouchPoints = 0;
  /** There are no cookies to keep: localStorage is the storage a page has here. */
  readonly cookieEnabled = false;
  readonly onLine = true;
  readonly webdriver = false;
  /** The system pasteboard. A native app needs no permission or user gesture to use it. */
  readonly clipboard: Clipboard = new Clipboard();
  /** The app's update check: an app whose web app manifest names `update_url` gets a
   *  registration here, with the browser's update()/updatefound shape. */
  readonly serviceWorker: ServiceWorkerContainer = new ServiceWorkerContainer();
}

export const navigator: Navigator = new Navigator();

/**
 * The page's address. An app is built from files rather than served, so it has a file: URL with no
 * host: an opaque origin, no query and no fragment. Navigation members exist so code that reads or
 * calls them doesn't throw, but the app can't go anywhere.
 */
export class Location {
  get [Symbol.toStringTag](): string { return "Location"; }
  private hrefValue: string;
  /** The address the app was opened at, which `reset()` goes back to for the next page. */
  private initialHref: string;
  constructor(href: string = "file:///index.html") {
    this.hrefValue = href;
    this.initialHref = href;
  }
  /** Forgets the fragment a page set: a runner's next page starts at the app's own address. */
  reset(): void {
    this.hrefValue = this.initialHref;
  }
  /** Starts the page at this address, before its scripts run: a window opened at a route. */
  startAt(href: string): void {
    this.hrefValue = href;
    this.initialHref = href;
  }
  get href(): string { return this.hrefValue; }
  set href(value: string) {
    const raw = String(value === null || value === undefined ? "" : value);
    // A relative address — "#frag" above all — resolves against the current one, as in a browser.
    const next = raw.startsWith("#") ? this.hrefValue.split("#")[0] + raw : raw;
    if (next === this.hrefValue) return;
    // A fragment-only change is a hash change: the text fragment takes effect and the page hears
    // hashchange, as it would in a browser. Anything else only changes the address we can't visit.
    const base = this.hrefValue.split("#")[0];
    if (next.split("#")[0] === base && next.indexOf("#") >= 0) {
      const oldURL = this.hrefValue;
      this.hrefValue = next;
      applyFragment(next.slice(next.indexOf("#") + 1), oldURL, next);
      return;
    }
    this.hrefValue = next;
  }
  get origin(): string { return "null"; }
  get protocol(): string { return "file:"; }
  get host(): string { return ""; }
  get hostname(): string { return ""; }
  get port(): string { return ""; }
  get pathname(): string { const i = this.href.indexOf("file://"); return i < 0 ? this.href : this.href.slice(i + 7).split(/[?#]/)[0]; }
  get search(): string { const i = this.href.indexOf("?"); return i < 0 ? "" : this.href.slice(i).split("#")[0]; }
  get hash(): string { const i = this.href.indexOf("#"); return i < 0 ? "" : this.href.slice(i); }
  set hash(value: string) {
    const frag = String(value === null || value === undefined ? "" : value).replace(/^#/, "");
    const oldURL = this.href;
    const base = oldURL.split("#")[0];
    const next = frag === "" ? base : base + "#" + frag;
    if (next === oldURL) return;
    this.hrefValue = next;
    applyFragment(frag, oldURL, next);
  }
  toString(): string { return this.href; }
  assign(url: string): void { this.href = url; }
  replace(url: string): void { this.href = url; }
  reload(): void {}
}

/**
 * A new fragment took effect: a `:~:text=` directive marks the stretch it names, and the page's
 * hashchange listeners hear the new address. The directive's value is what follows `text=`, up to
 * the next directive.
 */
function applyFragment(frag: string, oldURL: string, newURL: string): void {
  const at = frag.indexOf(":~:text=");
  setTargetText(at >= 0 ? frag.slice(at + 8).split("&")[0] : "");
  invalidatePaint();
  const event = trusted(new domIface.HashChangeEvent("hashchange", { oldURL: oldURL, newURL: newURL }));
  event.target = document.body;
  dispatchWindow(event);
}

/** The address a route names: a fragment or a query goes on the app's own address, and anything
 *  else is taken as the address itself. */
function addressWith(route: string): string {
  if (route === "") return "file:///index.html";
  if (route.startsWith("#") || route.startsWith("?")) return "file:///index.html" + route;
  return route;
}

/** Starts this page at `route`: a window opened at a fragment reads it as its address. */
export function setStartAddress(route: string): void {
  if (route === "") return;
  window.location.startAt(addressWith(route));
}

/** The id of the window that opened this one, or 0 for the app's first window. */
let openerWindowId = 0;

/** Reads what this window was opened with, before the page's scripts run: its route, the
 *  browsing context's name and the window that opened it. */
export function applyWindowEnvironment(): void {
  const route = process.env.NATIVE_WINDOW_URL;
  if (route !== undefined) setStartAddress(route);
  const name = process.env.NATIVE_WINDOW_NAME;
  if (name !== undefined) window.name = name;
  const opener = process.env.NATIVE_WINDOW_OPENER;
  if (opener !== undefined && opener !== "") openerWindowId = Number(opener);
}

/** One listener the window holds, with the flags a dispatch needs. */
export interface WindowListenerEntry {
  fn: EventListener | null;
  object: EventListenerOrEventListenerObject | null;
  capture: boolean;
  once: boolean;
  passive: boolean;
}

export class Window {
  get [Symbol.toStringTag](): string { return "Window"; }
  /** The event being dispatched, as the legacy global `window.event` reports it. */
  get event(): any {
    return currentEvent === null ? undefined : currentEvent;
  }
  readonly document = document;
  readonly location = new Location();
  /** The window's origin: a built app's page is a file, whose origin is opaque. */
  readonly origin = "null";
  readonly navigator = navigator;
  /** The visual viewport. It never scrolls or zooms away from the layout viewport here. */
  readonly visualViewport = new VisualViewport();
  /** A window has no frame element: the app isn't embedded in another document. */
  readonly frameElement = null;
  // The constructors and stores a page reaches through `window`, as in a browser. Each one is the
  // same object the bare global name is.
  readonly MutationObserver = MutationObserver;
  readonly ResizeObserver = ResizeObserver;
  readonly IntersectionObserver = IntersectionObserver;
  readonly CSS = CSS;
  readonly customElements = customElements;
  readonly localStorage = localStorage;
  readonly sessionStorage = sessionStorage;
  // Every name a page can reach through `window` as the global object: the DOM interfaces it
  // can test with `name in window` or `window[name]`, and the other module's classes.
  // CustomEvent is left out: scriptc can't take a generic class as a value (issue 48).
  readonly AnimationEvent = domIface.AnimationEvent;
  readonly BeforeUnloadEvent = domIface.BeforeUnloadEvent;
  readonly CDATASection = domIface.CDATASection;
  readonly CommandEvent = domIface.CommandEvent;
  readonly CSSRule = domIface.CSSRule;
  readonly CSSCounterStyleRule = domIface.CSSCounterStyleRule;
  readonly CSSStyleSheet = domIface.CSSStyleSheet;
  readonly CharacterData = domIface.CharacterData;
  readonly ClipboardEvent = domIface.ClipboardEvent;
  readonly Comment = domIface.Comment;
  readonly CompositionEvent = domIface.CompositionEvent;
  readonly CustomElementRegistry = domIface.CustomElementRegistry;
  readonly DOMImplementation = domIface.DOMImplementation;
  readonly DOMStringMap = domIface.DOMStringMap;
  readonly DOMParser = domIface.DOMParser;
  readonly XMLSerializer = domIface.XMLSerializer;
  readonly DataTransfer = domIface.DataTransfer;
  readonly DataTransferItem = domIface.DataTransferItem;
  readonly DeviceMotionEvent = domIface.DeviceMotionEvent;
  readonly DeviceOrientationEvent = domIface.DeviceOrientationEvent;
  readonly Document = domIface.Document;
  readonly DocumentFragment = domIface.DocumentFragment;
  readonly DocumentType = domIface.DocumentType;
  readonly DragEvent = domIface.DragEvent;
  readonly Element = domIface.Element;
  readonly Event = domIface.Event;
  readonly EventTarget = domIface.EventTarget;
  readonly File = domIface.File;
  readonly FocusEvent = domIface.FocusEvent;
  readonly FormData = domIface.FormData;
  readonly HTMLAnchorElement = domIface.HTMLAnchorElement;
  readonly HTMLAreaElement = domIface.HTMLAreaElement;
  readonly Attr = domIface.Attr;
  readonly HTMLAudioElement = domIface.HTMLAudioElement;
  readonly ProcessingInstruction = domIface.ProcessingInstruction;
  readonly StaticRange = domIface.StaticRange;
  readonly AbstractRange = domIface.AbstractRange;
  readonly OpaqueRange = domIface.OpaqueRange;
  readonly HTMLBRElement = domIface.HTMLBRElement;
  readonly HTMLBaseElement = domIface.HTMLBaseElement;
  readonly HTMLBodyElement = domIface.HTMLBodyElement;
  readonly HTMLButtonElement = domIface.HTMLButtonElement;
  readonly HTMLCanvasElement = domIface.HTMLCanvasElement;
  readonly HTMLCollection = domIface.HTMLCollection;
  readonly HTMLDListElement = domIface.HTMLDListElement;
  readonly HTMLDataElement = domIface.HTMLDataElement;
  readonly HTMLDataListElement = domIface.HTMLDataListElement;
  readonly HTMLDetailsElement = domIface.HTMLDetailsElement;
  readonly HTMLDialogElement = domIface.HTMLDialogElement;
  readonly HTMLDirectoryElement = domIface.HTMLDirectoryElement;
  readonly HTMLDivElement = domIface.HTMLDivElement;
  readonly HTMLDocument = domIface.HTMLDocument;
  readonly HTMLElement = domIface.HTMLElement;
  readonly HTMLEmbedElement = domIface.HTMLEmbedElement;
  readonly HTMLFieldSetElement = domIface.HTMLFieldSetElement;
  readonly HTMLFontElement = domIface.HTMLFontElement;
  readonly HTMLFormElement = domIface.HTMLFormElement;
  readonly HTMLFrameElement = domIface.HTMLFrameElement;
  readonly HTMLFrameSetElement = domIface.HTMLFrameSetElement;
  readonly HTMLHRElement = domIface.HTMLHRElement;
  readonly HTMLHeadElement = domIface.HTMLHeadElement;
  readonly HTMLHeadingElement = domIface.HTMLHeadingElement;
  readonly HTMLHtmlElement = domIface.HTMLHtmlElement;
  readonly HTMLIFrameElement = domIface.HTMLIFrameElement;
  readonly HTMLImageElement = domIface.HTMLImageElement;
  readonly HTMLInputElement = domIface.HTMLInputElement;
  readonly HTMLLIElement = domIface.HTMLLIElement;
  readonly HTMLLabelElement = domIface.HTMLLabelElement;
  readonly HTMLLegendElement = domIface.HTMLLegendElement;
  readonly HTMLLinkElement = domIface.HTMLLinkElement;
  readonly HTMLMapElement = domIface.HTMLMapElement;
  readonly HTMLMediaElement = domIface.HTMLMediaElement;
  readonly HTMLMenuElement = domIface.HTMLMenuElement;
  readonly HTMLMetaElement = domIface.HTMLMetaElement;
  readonly HTMLMeterElement = domIface.HTMLMeterElement;
  readonly HTMLModElement = domIface.HTMLModElement;
  readonly HTMLOListElement = domIface.HTMLOListElement;
  readonly HTMLObjectElement = domIface.HTMLObjectElement;
  readonly HTMLOptGroupElement = domIface.HTMLOptGroupElement;
  readonly HTMLOptionElement = domIface.HTMLOptionElement;
  readonly HTMLOutputElement = domIface.HTMLOutputElement;
  readonly HTMLParagraphElement = domIface.HTMLParagraphElement;
  readonly HTMLParamElement = domIface.HTMLParamElement;
  readonly HTMLPreElement = domIface.HTMLPreElement;
  readonly HTMLProgressElement = domIface.HTMLProgressElement;
  readonly HTMLQuoteElement = domIface.HTMLQuoteElement;
  readonly HTMLScriptElement = domIface.HTMLScriptElement;
  readonly HTMLSelectElement = domIface.HTMLSelectElement;
  readonly HTMLSlotElement = domIface.HTMLSlotElement;
  readonly HTMLSourceElement = domIface.HTMLSourceElement;
  readonly HTMLSpanElement = domIface.HTMLSpanElement;
  readonly HTMLStyleElement = domIface.HTMLStyleElement;
  readonly MediaList = domIface.MediaList;
  readonly CSSMediaRule = domIface.CSSMediaRule;
  readonly HTMLSummaryElement = domIface.HTMLSummaryElement;
  readonly HTMLTableCaptionElement = domIface.HTMLTableCaptionElement;
  readonly HTMLTableCellElement = domIface.HTMLTableCellElement;
  readonly HTMLTableColElement = domIface.HTMLTableColElement;
  readonly HTMLTableElement = domIface.HTMLTableElement;
  readonly HTMLTableRowElement = domIface.HTMLTableRowElement;
  readonly HTMLTableSectionElement = domIface.HTMLTableSectionElement;
  readonly HTMLTemplateElement = domIface.HTMLTemplateElement;
  readonly HTMLTextAreaElement = domIface.HTMLTextAreaElement;
  readonly HTMLTimeElement = domIface.HTMLTimeElement;
  readonly HTMLTitleElement = domIface.HTMLTitleElement;
  readonly HTMLTrackElement = domIface.HTMLTrackElement;
  readonly HTMLUListElement = domIface.HTMLUListElement;
  readonly HTMLUnknownElement = domIface.HTMLUnknownElement;
  readonly HTMLVideoElement = domIface.HTMLVideoElement;
  readonly HashChangeEvent = domIface.HashChangeEvent;
  readonly Image = domIface.Image;
  readonly InputEvent = domIface.InputEvent;
  readonly KeyboardEvent = domIface.KeyboardEvent;
  readonly MessageEvent = domIface.MessageEvent;
  readonly MouseEvent = domIface.MouseEvent;
  readonly Node = domIface.Node;
  readonly NodeFilter = domIface.NodeFilter;
  readonly NodeIterator = domIface.NodeIterator;
  readonly NodeList = domIface.NodeList;
  readonly PointerEvent = domIface.PointerEvent;
  readonly Range = domIface.Range;
  readonly ResizeObserverEntry = domIface.ResizeObserverEntry;
  readonly ResizeObserverSize = domIface.ResizeObserverSize;
  readonly ShadowRoot = domIface.ShadowRoot;
  readonly StorageEvent = domIface.StorageEvent;
  readonly SubmitEvent = domIface.SubmitEvent;
  readonly Text = domIface.Text;
  readonly TextEvent = domIface.TextEvent;
  readonly ToggleEvent = domIface.ToggleEvent;
  readonly Touch = domIface.Touch;
  readonly TouchEvent = domIface.TouchEvent;
  readonly TransitionEvent = domIface.TransitionEvent;
  readonly TreeWalker = domIface.TreeWalker;
  readonly UIEvent = domIface.UIEvent;
  readonly ValidityState = domIface.ValidityState;
  readonly WebGL2RenderingContext = domIface.WebGL2RenderingContext;
  readonly WheelEvent = domIface.WheelEvent;
  readonly XMLDocument = domIface.XMLDocument;
  readonly implementation = domIface.implementation;
  readonly Highlight = highlightIface.Highlight;
  readonly HighlightRegistry = highlightIface.HighlightRegistry;
  readonly IntersectionObserverEntry = intersectIface.IntersectionObserverEntry;
  readonly ImageData = canvasIface.ImageData;
  readonly Navigator = Navigator;
  /** The window is the global object: `self` is the window itself. */
  get self(): Window {
    return this;
  }
  /** The window under the global's own name: `window.window` is the window. */
  get window(): Window {
    return this;
  }
  readonly fetch = fetchIface.fetch;
  readonly Headers = fetchIface.Headers;
  readonly ProgressEvent = fetchIface.ProgressEvent;
  readonly Request = fetchIface.Request;
  readonly XMLHttpRequest = xhrIface.XMLHttpRequest;
  readonly XMLHttpRequestUpload = xhrIface.XMLHttpRequestUpload;
  readonly EventSource = eventSourceIface.EventSource;
  readonly WebSocket = webSocketIface.WebSocket;
  readonly indexedDB = idbIface.indexedDB;
  readonly IDBKeyRange = idbIface.IDBKeyRange;
  queries: MediaQueryList[] = [];
  listeners: Map<string, WindowListenerEntry[]> = new Map();

  get innerWidth(): number {
    return viewport.w;
  }
  get innerHeight(): number {
    return viewport.h;
  }
  get devicePixelRatio(): number {
    const scale = hostBackingScale();
    return scale >= 1 ? scale : 1;
  }

  /** The page scroll position, which is the root element's. */
  get scrollX(): number {
    return document.documentElement.scrollLeft;
  }
  get scrollY(): number {
    return document.documentElement.scrollTop;
  }

  getComputedStyle(element: Element, pseudoElement: any = ""): any {
    return getComputedStyle(element, pseudoElement);
  }
  requestAnimationFrame(callback: FrameCallback): number {
    return requestAnimationFrame(callback);
  }
  cancelAnimationFrame(id: number): void {
    cancelAnimationFrame(id);
  }
  /**
   * A window timer, with the browser's surface: the id is a number, and clearTimeout takes the
   * id back. The host's own handle is kept beside it.
   */
  setTimeout(handler: () => void, timeout?: number): number {
    const id = nextTimerId++;
    TIMERS.set(id, setTimeout(handler, timeout));
    return id;
  }
  clearTimeout(id: number | undefined): void {
    if (id === undefined) return;
    const handle = TIMERS.get(id);
    if (handle === undefined) return;
    TIMERS.delete(id);
    clearTimeout(handle);
  }
  /** An interval repeats until clearInterval takes its id back. */
  setInterval(handler: () => void, timeout?: number): number {
    const id = nextTimerId++;
    INTERVALS.set(id, setInterval(handler, timeout));
    return id;
  }
  clearInterval(id: number | undefined): void {
    if (id === undefined) return;
    const handle = INTERVALS.get(id);
    if (handle === undefined) return;
    INTERVALS.delete(id);
    clearInterval(handle);
  }
  getSelection(): Selection | null {
    return document.getSelection();
  }

  // --- The window itself: opening another, closing it, and its frame ------------------------
  // Every window is another run of this page at an address of its own. A page reaches the windows
  // it opened, and the one that opened it, through WindowProxy handles; a message between them
  // crosses the app's processes, so only the proxy's own members and its messages are shared.

  /** The browsing context's name: what a link's target, or window.open()'s name, gave it. */
  name = "";

  /** The window that opened this one, or null for the app's first window. */
  get opener(): WindowProxy | null {
    return openerWindowId <= 0 ? null : proxyFor(openerWindowId, "");
  }

  /**
   * Opens the window `url` names, as a browser's window.open() does. `url` is an address for this
   * app — "#/settings" or "?doc=2" added to the page's own — and `name` the browsing context's
   * name: a window this page already opened under that name is focused and returned again;
   * "_blank" or no name always opens a new one. `features` is the features string a browser takes
   * (`"width=420,height=300,left=100,top=100"`), here for the window's size and position.
   * Returns a handle to the window, or null when no window could be opened.
   */
  open(url?: string, name?: string, features?: string): WindowProxy | null {
    const route = url === undefined ? "" : url;
    const target = name === undefined ? "" : name;
    if (target === "_self" || target === "_parent" || target === "_top") {
      // The app has no frames: these all name the window doing the navigation.
      const href = addressWith(route);
      if (href !== "") this.location.href = href;
      return proxyFor(hostWindowId(), this.name);
    }
    const id = hostWindowOpen(route, target === "_blank" ? "" : target, features === undefined ? "" : features);
    if (id < 0) return null;
    return proxyFor(id, target === "_blank" ? "" : target);
  }

  /**
   * Posts a message to this page's own window, which hears it as a `message` event with the data
   * as it was. A window posts to another through its WindowProxy's postMessage().
   */
  postMessage(data: unknown, targetOrigin?: string): void {
    if (targetOrigin !== undefined && targetOrigin !== "*" && targetOrigin !== "null") return;
    const text = JSON.stringify(data) ?? "null";
    setTimeout(() => {
      messageDelivered(0, text);
    }, 0);
  }

  /**
   * Closes this window, as the red button does. `beforeunload` listeners run first, and one that
   * cancels the event keeps the window open. The app quits when its last window closes.
   */
  close(): void {
    requestCloseWindow();
  }

  /** True once this window has closed; a page whose window is gone can't tell, as in a browser. */
  readonly closed = false;

  /** Brings this window to the front. */
  focus(): void {
    hostWindowFocus(0);
  }

  /** Asks the system to move focus off this window, as a browser's window.blur() does. */
  blur(): void {
    hostWindowBlur();
  }

  /** Resizes this window, as dragging its corner does. */
  resizeTo(width: number, height: number): void {
    hostWindowSetFrame(-1, -1, Math.max(0, Math.round(width)), Math.max(0, Math.round(height)));
  }

  /** Moves this window so its top-left corner is at a point on the screen. */
  moveTo(x: number, y: number): void {
    hostWindowSetFrame(Math.round(x), Math.round(y), -1, -1);
  }

  /** The window's left edge on screen, in CSS px. */
  get screenX(): number {
    return hostWindowFrame(0);
  }
  /** The window's top edge on screen, in CSS px. */
  get screenY(): number {
    return hostWindowFrame(1);
  }
  /** The window's width, chrome and all. */
  get outerWidth(): number {
    return hostWindowFrame(2);
  }
  /** The window's height, chrome and all. */
  get outerHeight(): number {
    return hostWindowFrame(3);
  }

  /**
   * Scrolls the page. The offsets clamp to what it can scroll, and `behavior` picks a jump or a
   * journey — `auto`, or none, follows the root element's computed scroll-behavior, which is the
   * one the viewport uses (a body's does not reach it).
   */
  scroll(x: number | ScrollToOptions, y?: number): void {
    this.scrollTo(x, y);
  }
  scrollTo(x: number | ScrollToOptions, y?: number): void {
    this.scrollPageTo(x, y, false);
  }
  scrollBy(x: number | ScrollToOptions, y?: number): void {
    this.scrollPageTo(x, y, true);
  }
  private scrollPageTo(x: number | ScrollToOptions, y: number | undefined, relative: boolean): void {
    const root = document.documentElement;
    let left: number;
    let top: number;
    let behavior: string;
    if (typeof x === "number") {
      const dy = y === undefined ? 0 : y;
      left = relative ? root.scrollX + x : x;
      top = relative ? root.scrollY + dy : dy;
      behavior = "";
    } else {
      const dx = x.left === undefined ? 0 : x.left;
      const dy = x.top === undefined ? 0 : x.top;
      left = relative ? root.scrollX + dx : x.left === undefined ? root.scrollX : x.left;
      top = relative ? root.scrollY + dy : x.top === undefined ? root.scrollY : x.top;
      behavior = x.behavior === undefined ? "" : x.behavior;
    }
    const beforeX = root.scrollX;
    const before = root.scrollY;
    root.scriptScrollTo(left, top, behavior);
    announceScroll(beforeX, before);
  }

  /** The window's listeners are typed by WindowEventMap, as the DOM lib types them. */
  addEventListener<K extends keyof WindowEventMap>(type: K,
    listener: (event: WindowEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    if (listener === null) return;
    const capture = typeof options === "boolean" ? options : options !== undefined && options.capture === true;
    const once = typeof options === "object" && options !== null && options.once === true;
    // A wheel or touch listener on the window is passive unless the options say otherwise.
    const passive = typeof options === "object" && options !== null && options.passive !== undefined
      ? options.passive === true
      : type === "touchstart" || type === "touchmove" || type === "wheel" || type === "mousewheel";
    let list = this.listeners.get(type);
    if (list === undefined) {
      list = [];
      this.listeners.set(type, list);
    }
    // The same listener twice with the same capture flag is kept once, as the DOM has it.
    for (const entry of list) {
      if (entry.capture === capture &&
        ((entry.fn !== null && entry.fn === listener) || (entry.object !== null && entry.object === listener))) return;
    }
    if (typeof listener === "function") list.push({ fn: listener, object: null, capture: capture, once: once, passive: passive });
    else list.push({ fn: null, object: listener, capture: capture, once: once, passive: passive });
  }
  removeEventListener<K extends keyof WindowEventMap>(type: K,
    listener: (event: WindowEventMap[K]) => void, options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions | boolean): void {
    const list = this.listeners.get(type);
    if (list === undefined || listener === null) return;
    const capture = typeof options === "boolean" ? options : options !== undefined && options.capture === true;
    for (let i = 0; i < list.length; i++) {
      const entry = list[i];
      const same = entry.fn !== null ? entry.fn === listener : entry.object === listener;
      if (same && entry.capture === capture) {
        list.splice(i, 1);
        return;
      }
    }
  }

  /**
   * Runs the window's listeners for one phase of an event travelling through the page: the
   * capture phase before the document's listeners, the bubble phase after them. The window is
   * the listener's currentTarget while it runs.
   */
  invokeWindowListeners(type: string, event: Event, capture: boolean): void {
    const list = this.listeners.get(type);
    if (list === undefined) return;
    event.eventPhase = capture ? Event.CAPTURING_PHASE : Event.BUBBLING_PHASE;
    const snapshot = list.slice();
    for (const entry of snapshot) {
      if (entry.capture !== capture) continue;
      if (entry.once) {
        const at = list.indexOf(entry);
        if (at >= 0) list.splice(at, 1);
      }
      event.currentTarget = this as any;
      event.passiveListener = entry.passive;
      if (entry.fn !== null) entry.fn.call(this as any, event);
      else if (entry.object !== null) (entry.object as { handleEvent(event: Event): void }).handleEvent(event);
      event.passiveListener = false;
      if (event.immediateStopped) return;
    }
  }

  /** The object listeners see as their currentTarget when the window is on the path. */
  windowObject(): Window {
    return this;
  }

  /** Dispatches an event at the window's listeners, without the document hearing it. */
  dispatchEvent(event: Event): boolean {
    if (!(event instanceof Event)) throw new TypeError("Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'.");
    // This is a dispatch of its own, even for an event that travelled through the page before:
    // its listeners hear it again, as EventTarget.dispatchEvent has it.
    event.dispatchFlag = true;
    event.windowCaptureRan = false;
    event.windowBubbleRan = false;
    event.propagationStopped = false;
    event.immediateStopped = false;
    event.target = this as any;
    event.currentTarget = this as any;
    event.eventPhase = Event.AT_TARGET;
    const outer = setCurrentEvent(event);
    dispatchWindow(event);
    setCurrentEvent(outer);
    event.eventPhase = Event.NONE;
    event.currentTarget = null;
    event.dispatchFlag = false;
    // Dispatch ends with the propagation flags clear, as the DOM's dispatch step has it.
    event.propagationStopped = false;
    event.immediateStopped = false;
    return !event.defaultPrevented;
  }

  matchMedia(query: string): MediaQueryList {
    const list = new MediaQueryList(query);
    this.queries.push(list);
    return list;
  }

  // --- Event handler properties --------------------------------------------
  // The window's own handler properties (load, resize, error, the page's lifecycle): each one
  // below registers a listener when set, as the browser's does.

  /** Handlers assigned as properties, keyed by event type; they are in `listeners` too. */
  private propertyHandlers: Map<string, EventListener> | null = null;

  private handlerFor(type: string): EventListener | null {
    const map = this.propertyHandlers;
    if (map === null) return null;
    const fn = map.get(type);
    return fn === undefined ? null : fn;
  }

  /** Forgets every listener and handler property: the next page gets a window of its own. */
  reset(): void {
    this.listeners.clear();
    this.propertyHandlers = null;
    this.queries.length = 0;
    // The next page hasn't loaded yet, and it starts at the app's own address: a page that set a
    // text fragment would otherwise leave the next page's identical set looking unchanged.
    loadFired = false;
    this.location.reset();
  }

  private setHandler(type: string, fn: EventListener | null): void {
    const old = this.handlerFor(type);
    if (old !== null) this.removeEventListener(type, old);
    if (fn === null) {
      if (this.propertyHandlers !== null) this.propertyHandlers.delete(type);
      return;
    }
    if (this.propertyHandlers === null) this.propertyHandlers = new Map();
    this.propertyHandlers.set(type, fn);
    this.addEventListener(type, fn);
  }

  get onload(): EventListener | null { return this.handlerFor("load"); }
  set onload(fn: EventListener | null) { this.setHandler("load", fn); }
  get onresize(): EventListener | null { return this.handlerFor("resize"); }
  set onresize(fn: EventListener | null) { this.setHandler("resize", fn); }
  get onscroll(): EventListener | null { return this.handlerFor("scroll"); }
  set onscroll(fn: EventListener | null) { this.setHandler("scroll", fn); }
  get onerror(): EventListener | null { return this.handlerFor("error"); }
  set onerror(fn: EventListener | null) { this.setHandler("error", fn); }
  get onunload(): EventListener | null { return this.handlerFor("unload"); }
  set onunload(fn: EventListener | null) { this.setHandler("unload", fn); }
  get onbeforeunload(): EventListener | null { return this.handlerFor("beforeunload"); }
  set onbeforeunload(fn: EventListener | null) { this.setHandler("beforeunload", fn); }
  get onhashchange(): EventListener | null { return this.handlerFor("hashchange"); }
  set onhashchange(fn: EventListener | null) { this.setHandler("hashchange", fn); }
  get onpopstate(): EventListener | null { return this.handlerFor("popstate"); }
  set onpopstate(fn: EventListener | null) { this.setHandler("popstate", fn); }
  get onmessage(): EventListener | null { return this.handlerFor("message"); }
  set onmessage(fn: EventListener | null) { this.setHandler("message", fn); }
  get onpagehide(): EventListener | null { return this.handlerFor("pagehide"); }
  set onpagehide(fn: EventListener | null) { this.setHandler("pagehide", fn); }
  get onpageshow(): EventListener | null { return this.handlerFor("pageshow"); }
  set onpageshow(fn: EventListener | null) { this.setHandler("pageshow", fn); }
  get onfocus(): EventListener | null { return this.handlerFor("focus"); }
  set onfocus(fn: EventListener | null) { this.setHandler("focus", fn); }
  get onblur(): EventListener | null { return this.handlerFor("blur"); }
  set onblur(fn: EventListener | null) { this.setHandler("blur", fn); }
  get onstorage(): EventListener | null { return this.handlerFor("storage"); }
  set onstorage(fn: EventListener | null) { this.setHandler("storage", fn); }
  get onrejectionhandled(): EventListener | null { return this.handlerFor("rejectionhandled"); }
  set onrejectionhandled(fn: EventListener | null) { this.setHandler("rejectionhandled", fn); }
  get onunhandledrejection(): EventListener | null { return this.handlerFor("unhandledrejection"); }
  set onunhandledrejection(fn: EventListener | null) { this.setHandler("unhandledrejection", fn); }
  get onbeforeprint(): EventListener | null { return this.handlerFor("beforeprint"); }
  set onbeforeprint(fn: EventListener | null) { this.setHandler("beforeprint", fn); }
  get onafterprint(): EventListener | null { return this.handlerFor("afterprint"); }
  set onafterprint(fn: EventListener | null) { this.setHandler("afterprint", fn); }
  get onlanguagechange(): EventListener | null { return this.handlerFor("languagechange"); }
  set onlanguagechange(fn: EventListener | null) { this.setHandler("languagechange", fn); }
  get onoffline(): EventListener | null { return this.handlerFor("offline"); }
  set onoffline(fn: EventListener | null) { this.setHandler("offline", fn); }
  get ononline(): EventListener | null { return this.handlerFor("online"); }
  set ononline(fn: EventListener | null) { this.setHandler("online", fn); }
}

export const window: Window = new Window();
setWindowEventHost(window);

/** The handles this page has on other windows, by id: the ones it opened, and its opener. */
const proxies: Map<number, WindowProxy> = new Map();

/** The handle for a window id, made once and shared: two handles on one window are the same. */
function proxyFor(id: number, name: string): WindowProxy {
  let proxy = proxies.get(id);
  if (proxy === undefined) {
    proxy = new WindowProxy(id, name);
    proxies.set(id, proxy);
  } else if (name !== "") {
    proxy.name = name;
  }
  return proxy;
}

/**
 * Another window of the app, as this page reaches it: one it opened, or the one that opened it
 * (window.opener, and a message's `source`). A browser's WindowProxy would also stand for the
 * other window's document; this one is a handle to the window itself — its name, whether it is
 * closed, closing it and focusing it, and posting it messages — because each window is its own
 * run of the app with a heap of its own.
 */
export class WindowProxy {
  get [Symbol.toStringTag](): string { return "Window"; }
  /** The window's id, the number the host and this page know it by. */
  readonly id: number;
  /** The browsing context's name, as `window.name` reports it in that window. */
  name: string;
  private done = false;

  constructor(id: number, name: string) {
    this.id = id;
    this.name = name;
  }

  /** True once the window has closed, as a browser's `closed` reports. */
  get closed(): boolean {
    return this.done;
  }

  /** Closes the window; it runs its own beforeunload first. */
  close(): void {
    if (this.done) return;
    // A handle on this page's own window (window.open(…, "_self")) closes it as window.close().
    if (this.id === hostWindowId()) {
      requestCloseWindow();
      return;
    }
    hostWindowClose(this.id);
  }

  /** Brings the window to the front. */
  focus(): void {
    if (this.done) return;
    hostWindowFocus(this.id === hostWindowId() ? 0 : this.id);
  }

  /** Asks the system to move focus off the window, as `window.blur()` does. */
  blur(): void {
    if (this.done || this.id !== hostWindowId()) return;
    hostWindowBlur();
  }

  /**
   * Posts `data` to the window, which hears it as a `message` event on its next turn. The data
   * crosses as JSON — objects, arrays, strings, numbers, booleans and null — and a target origin
   * other than "*" or "null" (the app's opaque origin) sends nothing, as a browser's postMessage
   * to an origin it doesn't match does.
   */
  postMessage(data: unknown, targetOrigin?: string): void {
    if (this.done) return;
    if (targetOrigin !== undefined && targetOrigin !== "*" && targetOrigin !== "null") return;
    const text = JSON.stringify(data);
    hostPostMessage(this.id, text === undefined ? "null" : text);
  }

  /** The window closed: nothing is left to reach through this handle. */
  markClosed(): void {
    this.done = true;
  }
}

/** A window this page opened closed (EV_WINDOWCLOSED): its handle reports `closed` from then on. */
export function openedWindowClosed(id: number): void {
  const proxy = proxies.get(id);
  if (proxy !== undefined) proxy.markClosed();
}

/**
 * A message for this window arrived from another one of the app (EV_MESSAGE): the window hears a
 * `message` event with the data it carried and a handle on the window that sent it.
 */
export function messageDelivered(sourceId: number, text: string): void {
  let data: any = null;
  try {
    data = JSON.parse(text);
  } catch (e) {
    data = null;
  }
  const source = sourceId <= 0 ? null : proxyFor(sourceId, "");
  dispatchWindow(trusted(new domIface.MessageEvent("message", { data: data, origin: "null", source: source })));
}

/** The window moved (EV_WINDOWMOVE): `move` listeners hear the new frame from screenX/screenY. */
export function windowMoved(): void {
  dispatchWindow(trusted(new Event("move")));
}

/** The window became the key window (EV_FOCUS): the page hears `focus`. */
export function windowFocused(): void {
  dispatchWindow(trusted(new Event("focus")));
}

/** The window stopped being the key window (EV_BLUR): the page hears `blur`. */
export function windowBlurred(): void {
  dispatchWindow(trusted(new Event("blur")));
}

/** Closes this page's window: beforeunload may keep it, then pagehide, then the window goes. */
function requestCloseWindow(): void {
  if (!requestClose()) return;
  dispatchWindow(trusted(new Event("pagehide")));
  hostWindowClose(0);
}

/** Runs the page's `beforeunload` listeners: false when one of them cancelled the close. */
function requestClose(): boolean {
  const ev = trusted(new Event("beforeunload", { cancelable: true }));
  dispatchWindow(ev);
  return !ev.defaultPrevented;
}

/**
 * The app was asked to quit (EV_APPQUIT: Cmd+Q, or the system). The same lifecycle a browser
 * runs when a page goes away: `beforeunload` (cancelable, which keeps the app up) and then
 * `pagehide`, before the app ends.
 */
export function requestQuit(): void {
  if (!requestClose()) return;
  dispatchWindow(trusted(new Event("pagehide")));
  hostQuit();
}

// The window's event methods, bare: a classic script calls `addEventListener` on the global
// object without naming it, as it would in a browser.
export function addEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
  options?: ListenerOptions | boolean): void {
  window.addEventListener(type, listener, options);
}

export function removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null,
  options?: ListenerOptions | boolean): void {
  window.removeEventListener(type, listener, options);
}

export function dispatchEvent(event: Event): boolean {
  return window.dispatchEvent(event);
}

/** The page's address, bare as a classic script names it. */
export const location: Location = window.location;

/**
 * Formats an exception for the console. A dev build sets it to a report that names the app's own
 * files and lines (see runtime/app/source-map.ts); a release build leaves it unset, and the
 * message is all it prints.
 */
export let exceptionText: ((e: unknown, heading: string) => string) | null = null;

/** Sets the formatting a dev build's error reports use. */
export function setExceptionText(format: ((e: unknown, heading: string) => string) | null): void {
  exceptionText = format;
}

/** The last report printed, and when: a frame that throws every time prints once a second. */
let lastReport = "";
let lastReportAt = 0;

function printReport(text: string): void {
  const now = Date.now();
  if (text === lastReport && now - lastReportAt < 1000) {
    lastReportAt = now;
    return;
  }
  lastReport = text;
  lastReportAt = now;
  console.error(text);
}

/**
 * Reports a promise rejection nothing handled the way a browser does: an error in the console and
 * an `unhandledrejection` event at the window, with the page left running. scriptc ends the
 * program on an unhandled rejection unless the process listens for it, and this is that listener
 * (registered once by mount).
 */
export function reportUnhandledRejection(reason: unknown): void {
  const heading = "Uncaught (in promise)";
  const text = exceptionText !== null ? exceptionText(reason, heading) : heading + " " + (reason instanceof Error ? reason.message : String(reason));
  printReport(text);
  const event = new Event("unhandledrejection");
  (event as { reason?: unknown }).reason = reason;
  window.dispatchEvent(event);
}

/**
 * Reports a script's uncaught exception the way a browser does: the console prints it and the
 * window gets an error event, which is what window.onerror listens for. A page's classic scripts
 * each run on their own (see compiler/scripts.ts), so a throw in one doesn't stop the next.
 */
export function reportUncaughtError(e: unknown): void {
  const heading = "Uncaught";
  const text = exceptionText !== null ? exceptionText(e, heading) : heading + " " + (e instanceof Error ? e.message : String(e));
  printReport(text);
  window.dispatchEvent(new Event("error"));
}
setDefaultView(window);

// A link follows its href: a target name opens or reuses that window, and everything else — no
// target, or _self, _parent and _top, which name this window as the app has no frames — changes
// this page's address, which for an app is its fragment or query.
setFollowLinkHook((href: string, target: string | null) => {
  if (target !== null && target !== "" && target !== "_self" && target !== "_parent" && target !== "_top") {
    window.open(href, target);
    return;
  }
  window.location.href = href;
});

/** The window under another name: `self` is the global object, as `window` is. */
export const self: Window = window;

/** The global matchMedia: the same thing, without writing `window.` first. */
export function matchMedia(query: string): MediaQueryList {
  return window.matchMedia(query);
}

/** The global getSelection: the document's selection, without writing `window.` first. */
export function getSelection(): Selection | null {
  return window.getSelection();
}

/**
 * Tells the page its scroll position changed, as rolling it does in a browser: the scroll event
 * goes to the document, and from there to the window's own listeners.
 */
function announceScroll(beforeX: number, before: number): void {
  const root = document.documentElement;
  if (root.scrollTop === before && root.scrollLeft === beforeX) return;
  root.lastScroll = Date.now();
  const ev = trusted(new Event("scroll"));
  dispatch(ev, document);
  dispatchWindow(ev);
}

/** Sends an event to the window's listeners, after it has bubbled through the document. */
export function dispatchWindow(event: Event): void {
  const list = window.listeners.get(event.type);
  // Through .call, as the DOM's own dispatch does: a listener typed for the narrower event
  // class its type name maps to is called with the event as it is, not converted.
  if (list !== undefined) {
    for (const entry of list.slice()) {
      // dispatch() runs the window's listeners for an event that travelled through the page;
      // a caller that sends that event on afterwards reaches only the phase dispatch left.
      if (entry.capture ? event.windowCaptureRan : event.windowBubbleRan) continue;
      event.passiveListener = entry.passive;
      if (entry.fn !== null) entry.fn.call(window, event);
      else if (entry.object !== null) (entry.object as { handleEvent(event: Event): void }).handleEvent(event);
      event.passiveListener = false;
      if (event.immediateStopped) return;
    }
  }
}

let loadFired = false;

/**
 * A page's load events, once its scripts have run and with its first layout behind it: the
 * document's readyState goes "loading" → "interactive" for DOMContentLoaded → "complete" for
 * load, and the window's load listeners hear the load event with the document as its target, as
 * a browser's do once the page is complete. This is what a `<body onload>` attribute waits for.
 * The load fires once: a run that also takes a snapshot doesn't fire it twice.
 */
/**
 * WPT's runner tells a page it is about to take the screenshot. A reftest that listens for
 * `TestRendered` makes its change there, so the snapshot shows the state the reference does.
 */
export function dispatchTestRendered(): void {
  const event = trusted(new Event("TestRendered"));
  event.target = document;
  document.dispatchEvent(event);
}

export function dispatchLoad(): void {
  if (loadFired) return;
  loadFired = true;
  document.readyState = "interactive";
  const ready = trusted(new Event("DOMContentLoaded"));
  ready.target = document;
  document.dispatchEvent(ready);
  document.readyState = "complete";
  const load = trusted(new Event("load"));
  load.target = document;
  dispatchWindow(load);
}

/** Drops every timer, interval and animation frame: a new page starts with an empty event loop. */
export function clearAllTimers(): void {
  for (const h of TIMERS.values()) clearTimeout(h);
  TIMERS.clear();
  for (const h of INTERVALS.values()) clearInterval(h);
  INTERVALS.clear();
  frameIds.length = 0;
  frameCallbacks.length = 0;
}

/**
 * The system settings (appearance, contrast, transparency, reduce motion) are read again each
 * frame; a change restyles the page and updates every matchMedia list.
 */
export function pollSystemSettings(): void {
  if (!refreshSystemSettings()) return;
  dirty.layout = true;
  layoutEpoch.n++;
  markFullPaint();
  invalidateStyle();
  for (const q of window.queries) q.update();
}

/** The viewport changed: media queries re-evaluate, then resize listeners hear about it. */
export function windowResized(): void {
  invalidateStyle();
  for (const q of window.queries) q.update();
  const event = trusted(new Event("resize"));
  event.target = document.body;
  dispatchWindow(event);
}
