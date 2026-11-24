// The globals of a worker's own module script: `self`, `postMessage` and the event-target methods
// a DedicatedWorkerGlobalScope has. The page's DOM stays on the main thread, so a worker's module
// imports these instead of the window's globals (the compiler binds them in the files a
// `new Worker(...)` names).
//
// scriptc runs the entry module on a worker thread with `parentPort` for the page. The page's
// messages arrive on that port; this module makes them MessageEvents on `self`, so a worker writes
// what a browser's worker writes: `self.onmessage = (event) => …` and `postMessage(…)`.

import { isMainThread, parentPort, threadName } from "node:worker_threads";
import { MessageEvent } from "./events.ts";

type Listener = ((this: any, event: any) => any) | { handleEvent(event: any): void };

interface Registration {
  fn: Listener;
  once: boolean;
}

/** The transfer list a web postMessage's second argument names: an array, or `{ transfer }`.
 *  scriptc transfers MessagePorts only and refuses an ArrayBuffer in the list, so the bytes
 *  travel as the structured clone it already makes (see runtime/worker.ts). */
function transferList(options: any): any {
  if (options === undefined || options === null) return undefined;
  return undefined;
}

/** The event target a worker's global object is: its listeners and its `onmessage`/`onerror`
 *  handler properties, called in the order the web calls them. */
export class WorkerGlobalScope {
  get [Symbol.toStringTag](): string { return "WorkerGlobalScope"; }
  private readonly registrations: Map<string, Registration[]> = new Map();
  onmessage: ((this: DedicatedWorkerGlobalScope, event: any) => any) | null = null;
  onerror: ((this: DedicatedWorkerGlobalScope, event: any) => any) | null = null;
  onmessageerror: ((this: DedicatedWorkerGlobalScope, event: any) => any) | null = null;

  addEventListener(type: string, listener: Listener | null, options?: any): void {
    if (listener === null || listener === undefined) return;
    const once = options !== null && options !== undefined && typeof options === "object" && options.once === true;
    const list = this.registrations.get(type) ?? [];
    list.push({ fn: listener, once });
    this.registrations.set(type, list);
  }

  removeEventListener(type: string, listener: Listener | null): void {
    const list = this.registrations.get(type);
    if (list === undefined) return;
    this.registrations.set(type, list.filter((r) => r.fn !== listener));
  }

  dispatchEvent(event: any): boolean {
    const list = this.registrations.get(event.type);
    if (list !== undefined) {
      const remaining: Registration[] = [];
      for (const registration of list) {
        if (typeof registration.fn === "function") registration.fn.call(this, event);
        if (!registration.once) remaining.push(registration);
      }
      this.registrations.set(event.type, remaining);
    }
    const handler = event.type === "message" ? this.onmessage
      : event.type === "error" ? this.onerror
      : event.type === "messageerror" ? this.onmessageerror : null;
    if (handler !== null) (handler as any).call(this, event);
    return event.defaultPrevented !== true;
  }
}

/** The global object a dedicated worker's script sees as `self`. */
export class DedicatedWorkerGlobalScope extends WorkerGlobalScope {
  get [Symbol.toStringTag](): string { return "DedicatedWorkerGlobalScope"; }
  /** The name the page gave the worker, as `worker_threads` reports it. */
  readonly name: string = isMainThread ? "" : (threadName ?? "");

  postMessage(message: any, options?: any): void {
    if (parentPort === null) return;
    parentPort.postMessage(message, transferList(options));
  }

  close(): void {
    if (parentPort !== null) parentPort.close();
  }
}

export const self: DedicatedWorkerGlobalScope = new DedicatedWorkerGlobalScope();

export function postMessage(message: any, options?: any): void {
  self.postMessage(message, options);
}

export function addEventListener(type: string, listener: Listener | null, options?: any): void {
  self.addEventListener(type, listener, options);
}

export function removeEventListener(type: string, listener: Listener | null): void {
  self.removeEventListener(type, listener);
}

export function close(): void {
  self.close();
}

if (!isMainThread && parentPort !== null) {
  parentPort.on("message", (data: any) => {
    self.dispatchEvent(new MessageEvent("message", { data }));
  });
}
