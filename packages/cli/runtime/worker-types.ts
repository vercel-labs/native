// The web Worker surface the runtime adds to scriptc's worker_threads Worker, declared where the
// page's type checker can see it. It is a module augmentation, not a replacement: the class stays
// node:worker_threads' (scriptc compiles its constructor), and the page's `worker.onmessage` and
// friends type-check against the members the runtime adds at construction.

import "node:worker_threads";

declare module "worker_threads" {
  interface Worker {
    onmessage: ((this: Worker, event: MessageEvent) => any) | null;
    onerror: ((this: Worker, event: any) => any) | null;
    onmessageerror: ((this: Worker, event: MessageEvent) => any) | null;
    addEventListener(type: "message", listener: (this: Worker, event: MessageEvent) => any, options?: any): void;
    addEventListener(type: "messageerror", listener: (this: Worker, event: MessageEvent) => any, options?: any): void;
    addEventListener(type: "error", listener: (this: Worker, event: any) => any, options?: any): void;
    addEventListener(type: string, listener: any, options?: any): void;
    removeEventListener(type: string, listener: any, options?: any): void;
    dispatchEvent(event: any): boolean;
    /** The web's form: a transfer list, which may also be named as `{ transfer }`. */
    postMessage(value: any, options?: any): void;
  }

  interface WorkerOptions {
    /** A module script, which is the only kind a Native SDK build compiles. */
    type?: "classic" | "module";
    credentials?: "omit" | "same-origin" | "include";
  }
}

export {};
