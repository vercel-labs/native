// EventSource: the server-sent events client, over the same transport as fetch. The response is
// read as it arrives, so a message is dispatched as soon as its blank-line terminator lands. When
// the stream ends the source reconnects after the server's retry interval, or three seconds.
//
// A message is the runtime's MessageEvent, with the event's data, the source's origin and its
// last event id; an open or an error is a plain Event. A response that isn't an event stream fails
// the source for good, while a network failure or a stream that ends reconnects after the retry
// interval the server named.

import { plainBytes } from "./bytes.ts";
import { fetch, Headers, Response } from "./fetch.ts";
import { Event, MessageEvent } from "./dom.ts";

const CONNECTING = 0;
const OPEN = 1;
const CLOSED = 2;

/** The origin of a URL: scheme://host[:port], or "" when it has none. */
function originOf(url: string): string {
  const m = /^([a-z][a-z0-9+.-]*:)\/\/([^/?#]+)/i.exec(url);
  return m === null ? "" : m[1] + "//" + m[2];
}

export class EventSource {
  get [Symbol.toStringTag](): string { return "EventSource"; }
  static readonly CONNECTING = CONNECTING;
  static readonly OPEN = OPEN;
  static readonly CLOSED = CLOSED;

  readonly CONNECTING = CONNECTING;
  readonly OPEN = OPEN;
  readonly CLOSED = CLOSED;

  readonly url: string;
  readonly withCredentials: boolean;
  readyState: number = CONNECTING;

  onopen: ((event: any) => void) | null = null;
  onmessage: ((event: any) => void) | null = null;
  onerror: ((event: any) => void) | null = null;

  private listeners: { type: string; fn: (event: any) => void }[] = [];
  private controller: AbortController | null = null;
  private closed: boolean = false;
  private retry: number = 3000;
  private lastEventId: string = "";
  private origin: string;

  constructor(url: string, init?: { withCredentials?: boolean }) {
    this.url = String(url);
    this.withCredentials = init !== undefined && init.withCredentials === true;
    this.origin = originOf(this.url);
    this.connect();
  }

  addEventListener(type: string, listener: any): void {
    if (listener === null || listener === undefined) return;
    if (typeof listener === "function") this.listeners.push({ type, fn: listener });
    else if (typeof listener.handleEvent === "function") this.listeners.push({ type, fn: (e: any) => listener.handleEvent(e) });
  }

  removeEventListener(type: string, listener: any): void {
    for (let i = this.listeners.length - 1; i >= 0; i--) {
      if (this.listeners[i].type === type && this.listeners[i].fn === listener) this.listeners.splice(i, 1);
    }
  }

  dispatchEvent(event: any): boolean {
    const handler = (this as any)["on" + event.type];
    if (typeof handler === "function") {
      try { handler.call(this, event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    for (const l of this.listeners.slice()) {
      if (l.type !== event.type) continue;
      try { l.fn.call(this, event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    return true;
  }

  close(): void {
    this.closed = true;
    this.readyState = CLOSED;
    if (this.controller !== null) this.controller.abort();
  }

  private async connect(): Promise<void> {
    while (!this.closed) {
      const controller = new AbortController();
      this.controller = controller;
      let response: Response | null = null;
      try {
        const headers = new Headers({ "Accept": "text/event-stream", "Cache-Control": "no-cache" });
        // A reconnection resumes where the stream left off, by the last event's id.
        if (this.lastEventId !== "") headers.set("Last-Event-ID", this.lastEventId);
        response = await fetch(this.url, { headers, signal: controller.signal });
      } catch (e) {
        // A network failure is retried after the server's interval.
        response = null;
      }
      if (this.closed) return;
      if (response === null) {
        this.dispatchEvent(new Event("error"));
        await this.waitRetry();
        continue;
      }
      // A response that isn't an event stream fails the source for good: no reconnection follows
      // a status other than 200 (204 says so explicitly) or a different content type.
      const type = response.headers.get("content-type");
      if (response.status !== 200 || type === null || type.split(";")[0].trim().toLowerCase() !== "text/event-stream") {
        this.fail();
        return;
      }
      this.readyState = OPEN;
      this.dispatchEvent(new Event("open"));
      try {
        await this.read(response);
      } catch (e) {
        // close() aborted the stream; the loop's next check ends the source.
      }
      if (this.closed) return;
      // A stream that ended is reconnected after the server's interval.
      this.readyState = CONNECTING;
      this.dispatchEvent(new Event("error"));
      await this.waitRetry();
    }
  }

  /** Fails the source for good: the error event, then CLOSED with no reconnection. */
  private fail(): void {
    this.closed = true;
    this.readyState = CLOSED;
    this.dispatchEvent(new Event("error"));
  }

  /** Waits the server's retry interval, or three seconds, before reconnecting. */
  private waitRetry(): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(() => resolve(), this.retry));
  }

  /** Reads the stream, dispatching each event at its blank-line terminator. */
  private async read(response: Response): Promise<void> {
    const body = response.body;
    if (body === null) return;
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let eventType = "";
    let eventId = this.lastEventId;
    let data: string[] = [];
    while (true) {
      const step = await reader.read();
      if (step.done) break;
      buffer += decoder.decode(plainBytes(step.value as Uint8Array), { stream: true });
      while (true) {
        const nl = buffer.indexOf("\n");
        if (nl < 0) break;
        let line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        if (line.endsWith("\r")) line = line.slice(0, line.length - 1);
        if (line === "") {
          if (data.length > 0) {
            this.dispatch(data.join("\n"), eventType === "" ? "message" : eventType, eventId);
            data = [];
            eventType = "";
          }
          continue;
        }
        if (line.startsWith(":")) continue;
        const colon = line.indexOf(":");
        const field = colon < 0 ? line : line.slice(0, colon);
        let value = colon < 0 ? "" : line.slice(colon + 1);
        if (value.startsWith(" ")) value = value.slice(1);
        if (field === "data") data.push(value);
        else if (field === "event") eventType = value;
        else if (field === "id") {
          if (value.indexOf("\0") < 0) eventId = value;
        } else if (field === "retry") {
          const n = Number(value);
          if (!isNaN(n) && n >= 0) this.retry = n;
        }
      }
    }
    // A stream that ends drops a partial event, as a browser does.
  }

  private dispatch(data: string, type: string, id: string): void {
    this.lastEventId = id;
    this.dispatchEvent(new MessageEvent(type, { data, origin: this.origin, lastEventId: id }));
  }
}
