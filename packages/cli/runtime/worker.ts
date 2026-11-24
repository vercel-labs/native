// The page's Worker: `new Worker(new URL("./worker.ts", import.meta.url))` starts a native thread
// on scriptc's worker_threads, and this module gives the thread's handle the web Worker surface:
// `onmessage` and the event-target methods, with each message delivered as a MessageEvent, and a
// postMessage that takes the web's transfer list (an array, or `{ transfer }`).
//
// The constructor itself stays scriptc's: a worker entry is compiled from the `new Worker(...)`
// the app writes, so the compiler wraps that construction in createWorker rather than replacing
// it. The wrapper forwards the Node methods (`on`, `off`, `terminate`, …). `instanceof Worker`
// cannot answer for the wrapper: scriptc has no prototype reflection, so the web object is a
// different class from the native one; code uses the methods, which is what the web API is.

import { Worker as NodeWorker } from "node:worker_threads";
import { MessageEvent, WorkerErrorEvent } from "./events.ts";

export { NodeWorker as Worker };

interface Listener {
  fn: (event: any) => any;
  once: boolean;
}

/** The transfer list a web postMessage's second argument names: an array, or `{ transfer }`.
 *  scriptc's postMessage transfers MessagePorts only and refuses an ArrayBuffer in the list
 *  (SC2020 "Transfer lists with values other than MessagePorts"), so the bytes travel as the
 *  structured clone scriptc already makes and the sender's buffer stays attached. The message
 *  arrives whole; only the detach the web promises is missing, until scriptc can move an
 *  ArrayBuffer between threads. */
function transferList(options: any): any {
  if (options === undefined || options === null) return undefined;
  if (Array.isArray(options)) return undefined;
  return undefined;
}

/** The web Worker the page sees. A class, not per-object properties: the compiler keeps every
 *  instance's shape static, and this is the object handed out by createWorker. */
class WebWorker {
  private readonly native: NodeWorker;
  private readonly listeners: Map<string, Listener[]> = new Map();
  onmessage: ((this: any, event: any) => any) | null = null;
  onerror: ((this: any, event: any) => any) | null = null;
  onmessageerror: ((this: any, event: any) => any) | null = null;

  constructor(native: NodeWorker) {
    this.native = native;
    native.on("message", (data: any) => {
      this.dispatch("message", new MessageEvent("message", { data }));
    });
    native.on("error", (error: any) => this.dispatch("error", new WorkerErrorEvent(error)));
    native.on("messageerror", (error: any) => this.dispatch("messageerror", new WorkerErrorEvent(error)));
  }

  postMessage(message: any, options?: any): void {
    this.native.postMessage(message, transferList(options));
  }

  terminate(): void {
    this.native.terminate();
  }

  addEventListener(type: string, listener: any, options?: any): void {
    if (typeof listener !== "function") return;
    const once = options !== null && options !== undefined && typeof options === "object" && options.once === true;
    const list = this.listeners.get(type) ?? [];
    list.push({ fn: listener, once });
    this.listeners.set(type, list);
  }

  removeEventListener(type: string, listener: any): void {
    const list = this.listeners.get(type);
    if (list === undefined) return;
    this.listeners.set(type, list.filter((entry) => entry.fn !== listener));
  }

  dispatchEvent(event: any): boolean {
    this.dispatch(event.type, event);
    return event.defaultPrevented !== true;
  }

  /** The Node surface, forwarded: code that used the thread's own methods keeps working. */
  on(type: string, listener: (...args: any[]) => void): this {
    this.native.on(type, listener);
    return this;
  }
  once(type: string, listener: (...args: any[]) => void): this {
    this.native.once(type, listener);
    return this;
  }
  off(type: string, listener: (...args: any[]) => void): this {
    this.native.off(type, listener);
    return this;
  }
  addListener(type: string, listener: (...args: any[]) => void): this {
    this.native.addListener(type, listener);
    return this;
  }
  removeListener(type: string, listener: (...args: any[]) => void): this {
    this.native.removeListener(type, listener);
    return this;
  }
  removeAllListeners(type?: string): this {
    this.native.removeAllListeners(type);
    return this;
  }
  ref(): this {
    this.native.ref();
    return this;
  }
  unref(): this {
    this.native.unref();
    return this;
  }
  get threadId(): number {
    return this.native.threadId;
  }
  get threadName(): string | null {
    return this.native.threadName;
  }

  private dispatch(type: string, event: any): void {
    const list = this.listeners.get(type);
    if (list !== undefined) {
      const remaining: Listener[] = [];
      for (const entry of list) {
        entry.fn.call(this, event);
        if (!entry.once) remaining.push(entry);
      }
      this.listeners.set(type, remaining);
    }
    const handler = type === "message" ? this.onmessage
      : type === "error" ? this.onerror
      : type === "messageerror" ? this.onmessageerror : null;
    if (handler !== null) handler.call(this, event);
  }
}

// The page's `worker instanceof Worker` has to answer for the class it imported, so the web
/** Gives a worker thread the web Worker API. Called by the construction the compiler rewrites.
 *  The wrapper is its own class: the compiler keeps class shapes static, so the web members are
 *  fields and methods rather than properties added to the native instance. */
export function createWorker(worker: NodeWorker): any {
  return new WebWorker(worker);
}
