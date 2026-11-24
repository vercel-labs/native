// The event base and the custom event a script dispatches, kept out of the DOM module: its
// import graph has cycles, and a worker build compiles the program eagerly, where a generic class
// reached through a cycle is refused (scriptc SC1016). This module imports only types, so it sits
// outside every cycle.

import type { Node, EventTarget } from "./dom.ts";
import type { Window } from "./window.ts";

/** The dictionary Event() and the event classes below take. */
export interface EventInit {
  bubbles?: boolean;
  cancelable?: boolean;
  composed?: boolean;
}

/**
 * One item of an event's path (the DOM's event path item): the node whose listeners it reaches,
 * the target a listener there sees (null keeps the item below it), the related target retargeted
 * for it, and the closed-tree flags composedPath() needs.
 */
export interface PathItem {
  target: Node;
  adjusted: Node | null;
  related: Node | null;
  rootClosed: boolean;
  slotClosed: boolean;
}

export class Event {
  get [Symbol.toStringTag](): string { return "Event"; }
  static readonly NONE = 0;
  static readonly CAPTURING_PHASE = 1;
  static readonly AT_TARGET = 2;
  static readonly BUBBLING_PHASE = 3;

  // WebIDL puts an interface's constants on its prototype as well as its interface object.
  get NONE(): number { return Event.NONE; }
  get CAPTURING_PHASE(): number { return Event.CAPTURING_PHASE; }
  get AT_TARGET(): number { return Event.AT_TARGET; }
  get BUBBLING_PHASE(): number { return Event.BUBBLING_PHASE; }

  type: string;
  bubbles: boolean;
  cancelable: boolean;
  readonly composed: boolean;
  /** Whether the host generated the event: real input is trusted, script-made events are not. */
  isTrusted = false;
  readonly timeStamp: number;
  /** The node the event is being dispatched to; null before dispatch. */
  target: Node | EventTarget | null = null;
  /** The node, window or plain event target whose listeners are running; null outside one. */
  currentTarget: Node | Window | EventTarget | null = null;
  /** The legacy `srcElement`: the target, null before dispatch. */
  get srcElement(): any {
    return this.target;
  }
  eventPhase = 0;
  defaultPrevented = false;
  propagationStopped = false;
  immediateStopped = false;
  /** True while a passive listener runs, where preventDefault() does nothing. */
  passiveListener = false;
  /** The items dispatch() builds, target first; composedPath() answers from them (see PathItem). */
  pathItems: PathItem[] = [];
  /** The related target the running listener sees, retargeted for its path item. */
  relatedNow: Node | null = null;
  /** True once the event has been dispatched: initEvent() refuses from then on. */
  dispatchFlag = false;
  /** Whether dispatch() has already run the window's capture listeners for this dispatch. A
   *  caller that sends the event on to the window afterwards must not run them a second time. */
  windowCaptureRan = false;
  /** Whether dispatch() has already run the window's bubble listeners for this dispatch. */
  windowBubbleRan = false;
  /** The related target a mouse or focus event was made with, before any retargeting. */
  relatedSource: Node | null = null;

  constructor(...args: any[]) {
    this.type = eventTypeArg(args);
    const init = eventInitArg(args);
    this.bubbles = dictBool(init, "bubbles", false);
    this.cancelable = dictBool(init, "cancelable", false);
    this.composed = dictBool(init, "composed", false);
    this.timeStamp = Date.now();
  }
  stopPropagation(): void {
    this.propagationStopped = true;
  }
  stopImmediatePropagation(): void {
    this.propagationStopped = true;
    this.immediateStopped = true;
  }
  preventDefault(): void {
    if (this.cancelable && !this.passiveListener) this.defaultPrevented = true;
  }
  /**
   * The legacy initializer: sets the type and flags of an event createEvent() made and clears the
   * state a previous dispatch left; an event that has been dispatched may not be initialized again.
   */
  initEvent(type: string, bubbles: boolean = false, cancelable: boolean = false): void {
    if (this.dispatchFlag) {
      throw new Error("InvalidStateError: Failed to execute 'initEvent' on 'Event': The event has already been dispatched.");
    }
    this.type = String(type);
    this.bubbles = bubbles === true;
    this.cancelable = cancelable === true;
    this.defaultPrevented = false;
    this.propagationStopped = false;
    this.immediateStopped = false;
  }
  get cancelBubble(): boolean {
    return this.propagationStopped;
  }
  set cancelBubble(value: boolean) {
    if (value) this.propagationStopped = true;
  }
  get returnValue(): boolean {
    return !this.defaultPrevented;
  }
  set returnValue(value: boolean) {
    if (!value) this.preventDefault();
  }
  /** The runtime's dispatch sets the target and the listener's current target as it goes. The
   *  event target may be a plain EventTarget as well as a node or the window. */
  setDispatchTargets(target: any, current: any): void {
    this.target = target;
    this.currentTarget = current;
  }

  /** The DOM's cleanup after dispatch: a target the event never escaped is dropped. */
  clearTargets(): void {
    this.target = null;
    this.relatedSource = null;
  }
  composedPath(): (Node | EventTarget)[] {
    // The DOM's algorithm: walk the path for the listener's own item, counting the closed subtrees
    // it passes, then take the items above and below it that are no deeper in a closed tree.
    const path = this.pathItems;
    const current = this.currentTarget;
    if (path.length === 0 || current === null) return [];
    let currentIndex = 0;
    let level = 0;
    for (let i = path.length - 1; i >= 0; i--) {
      const item = path[i];
      if (item.rootClosed) level++;
      if (item.target === current) {
        currentIndex = i;
        break;
      }
      if (item.slotClosed) level--;
    }
    const before: Node[] = [];
    let hidden = level;
    let max = level;
    for (let i = currentIndex - 1; i >= 0; i--) {
      const item = path[i];
      if (item.rootClosed) hidden++;
      if (hidden <= max) before.push(item.target);
      if (item.slotClosed) {
        hidden--;
        if (hidden < max) max = hidden;
      }
    }
    const out: (Node | EventTarget)[] = [];
    for (let i = before.length - 1; i >= 0; i--) out.push(before[i]);
    out.push(current as any);
    hidden = level;
    max = level;
    for (let i = currentIndex + 1; i < path.length; i++) {
      const item = path[i];
      if (item.slotClosed) hidden++;
      if (hidden <= max) out.push(item.target);
      if (item.rootClosed) {
        hidden--;
        if (hidden < max) max = hidden;
      }
    }
    return out;
  }
}

/** Marks an event the host generated from real input: a browser's isTrusted is true for those. */
export function trusted<T extends Event>(event: T): T {
  event.isTrusted = true;
  return event;
}

export interface CustomEventInit<T = unknown> extends EventInit {
  detail?: T;
}

/** An event a script dispatches with its own data on it, as custom elements use. */
export class CustomEvent<T = unknown> extends Event {
  get [Symbol.toStringTag](): string { return "CustomEvent"; }
  detail: T;
  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.detail = init.detail === undefined ? (null as T) : (init.detail as T);
  }
  /** The legacy initializer for a custom event: type, flags and detail. */
  initCustomEvent(type: string, bubbles: boolean = false, cancelable: boolean = false, detail: T = null as T): void {
    this.initEvent(type, bubbles, cancelable);
    this.detail = detail;
  }
}

/**
 * The DOMString an event constructor's first argument stands for. The argument is required, so a
 * call with none is a TypeError, while null and undefined are the strings "null" and "undefined"
 * (WebIDL converts rather than refuses them).
 */
export function eventTypeArg(args: readonly any[]): string {
  if (args.length === 0) throw new TypeError("1 argument required, but only 0 present.");
  const type = args[0];
  return type === undefined ? "undefined" : type === null ? "null" : String(type);
}

/**
 * The init dictionary an event constructor's second argument names. A missing argument is the
 * empty dictionary, and so is null; anything that isn't an object is a TypeError, as WebIDL says
 * of a dictionary argument.
 */
export function eventInitArg(args: readonly any[]): any {
  const init = args.length > 1 ? args[1] : undefined;
  if (init === undefined || init === null) return {};
  const kind = typeof init;
  if (kind !== "object" && kind !== "function") {
    throw new TypeError("The provided value is not of a dictionary type.");
  }
  return init;
}

/** One boolean member: absent is the default, and any other value converts by its truthiness. */
export function dictBool(init: any, name: string, fallback: boolean): boolean {
  const v = init[name];
  if (v === undefined) return fallback;
  if (v === null) return false;
  if (typeof v === "boolean") return v;
  if (typeof v === "number") return v !== 0 && !Number.isNaN(v);
  if (typeof v === "string") return v !== "";
  return true;
}

/** One DOMString member of an event init dictionary. An absent or undefined member is its
 *  default; null and everything else convert to a string. */
export function dictString(init: any, name: string, fallback: string): string {
  const v = init[name];
  return v === undefined ? fallback : v === null ? "null" : String(v);
}

/** A message delivered to the window, with the data it carries. */
export class MessageEvent extends Event {
  get [Symbol.toStringTag](): string { return "MessageEvent"; }
  readonly data: any;
  readonly origin: string;
  readonly lastEventId: string;
  /** The window that sent the message, as a WindowProxy, or null when this page sent it itself. */
  readonly source: any;
  constructor(...args: any[]) {
    super(eventTypeArg(args), eventInitArg(args));
    const init = eventInitArg(args);
    this.data = init.data === undefined ? null : init.data;
    this.origin = dictString(init, "origin", "");
    this.lastEventId = dictString(init, "lastEventId", "");
    this.source = init.source === undefined ? null : init.source;
  }
}

/** The event a worker's script and its page exchange. It is not a DOM Event: its target is the
 *  worker's global object or the worker handle rather than a Node, and scriptc keeps an event
 *  class's field types static, so the worker's event is a class of its own with the web's fields. */
export class WorkerEvent {
  get [Symbol.toStringTag](): string { return "Event"; }
  type: string;
  target: any = null;
  currentTarget: any = null;
  defaultPrevented = false;
  constructor(type: string) {
    this.type = type;
  }
  preventDefault(): void {
    this.defaultPrevented = true;
  }
  stopPropagation(): void {}
  stopImmediatePropagation(): void {}
  composedPath(): any[] {
    return [];
  }
}

/** A worker's uncaught error, as the web's ErrorEvent reports it. */
export class WorkerErrorEvent extends WorkerEvent {
  get [Symbol.toStringTag](): string { return "ErrorEvent"; }
  readonly message: string;
  readonly filename: string = "";
  readonly lineno: number = 0;
  readonly colno: number = 0;
  readonly error: any;
  constructor(error: any) {
    super("error");
    this.error = error;
    this.message = error !== null && error !== undefined && typeof error.message === "string"
      ? error.message : String(error);
  }
}
