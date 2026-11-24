// XMLHttpRequest over the same transport as fetch: an async request to an http: or https: URL (or
// to the app's own files, by a page-relative, "/", file: or data: URL). Requests are async only:
// the spec allows a synchronous request in a worker, and this runtime has no worker to run one in,
// so open() with async false throws InvalidAccessError rather than blocking the app.
//
// Progress is reported as a single update carrying the response's size: the runtime's HTTP client
// hands the body over as one buffer, so there is no partial reply to count up. Upload progress is
// reported the same way, from the request body's size.

import { plainBytes } from "./bytes.ts";
import { Blob, Event } from "./dom.ts";
import { fetch, Headers, ProgressEvent, Response } from "./fetch.ts";

export class XMLHttpRequestUpload {
  get [Symbol.toStringTag](): string { return "XMLHttpRequestUpload"; }
  /** The listeners this object has, in order. */
  private listeners: { type: string; fn: (event: any) => void }[] = [];
  onloadstart: ((event: any) => void) | null = null;
  onprogress: ((event: any) => void) | null = null;
  onload: ((event: any) => void) | null = null;
  onerror: ((event: any) => void) | null = null;
  onabort: ((event: any) => void) | null = null;
  ontimeout: ((event: any) => void) | null = null;
  onloadend: ((event: any) => void) | null = null;

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
    const type = event.type;
    const handler = (this as any)["on" + type];
    if (typeof handler === "function") {
      try { handler.call(this, event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    for (const l of this.listeners.slice()) {
      if (l.type !== type) continue;
      try { l.fn.call(this, event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    return true;
  }

  _fire(type: string, loaded: number, total: number): void {
    this.dispatchEvent(new ProgressEvent(type, {
      lengthComputable: total > 0, loaded, total, target: this,
    }));
  }
}

/** The states a request is in, as the readyState property reports them. */
const UNSENT = 0;
const OPENED = 1;
const HEADERS_RECEIVED = 2;
const LOADING = 3;
const DONE = 4;

/** Decodes bytes as text: UTF-8 unless the response's MIME type names a charset it can decode. */
function decodeText(bytes: Uint8Array, mime: string): string {
  const charset = /charset=([^;]+)/i.exec(mime);
  const name = charset === null ? "utf-8" : charset[1].trim().toLowerCase();
  if (name === "iso-8859-1" || name === "latin1" || name === "us-ascii") {
    let out = "";
    for (let i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
    return out;
  }
  return new TextDecoder().decode(bytes);
}

/** Parses a byte range into a Blob whose type is the response's MIME type. */
function blobOf(bytes: Uint8Array, type: string): Blob {
  return new Blob([plainBytes(bytes)], { type: type.split(";")[0].trim() });
}

export class XMLHttpRequest {
  get [Symbol.toStringTag](): string { return "XMLHttpRequest"; }
  readonly UNSENT = UNSENT;
  readonly OPENED = OPENED;
  readonly HEADERS_RECEIVED = HEADERS_RECEIVED;
  readonly LOADING = LOADING;
  readonly DONE = DONE;

  readyState: number = UNSENT;
  status: number = 0;
  statusText: string = "";
  responseURL: string = "";
  responseType: string = "";
  timeout: number = 0;
  withCredentials: boolean = false;
  readonly upload: XMLHttpRequestUpload = new XMLHttpRequestUpload();

  onreadystatechange: ((event: any) => void) | null = null;
  onloadstart: ((event: any) => void) | null = null;
  onprogress: ((event: any) => void) | null = null;
  onload: ((event: any) => void) | null = null;
  onerror: ((event: any) => void) | null = null;
  onabort: ((event: any) => void) | null = null;
  ontimeout: ((event: any) => void) | null = null;
  onloadend: ((event: any) => void) | null = null;

  private listeners: { type: string; fn: (event: any) => void }[] = [];
  private method: string = "GET";
  private url: string = "";
  private isAsync: boolean = true;
  private requestHeaders: Headers = new Headers();
  private responseHeaders: Headers | null = null;
  private responseBytes: Uint8Array | null = null;
  private responseMime: string = "";
  private overrideMime: string = "";
  private controller: AbortController | null = null;
  private sending: boolean = false;
  private hasBody: boolean = false;
  private aborted: boolean = false;
  private timedOut: boolean = false;
  private timer: ReturnType<typeof setTimeout> | null = null;

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
    const type = event.type;
    const handler = (this as any)["on" + type];
    if (typeof handler === "function") {
      try { handler.call(this, event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    for (const l of this.listeners.slice()) {
      if (l.type !== type) continue;
      try { l.fn.call(this, event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    return true;
  }

  private fire(type: string, loaded: number = 0, total: number = 0): void {
    this.dispatchEvent(new ProgressEvent(type, {
      lengthComputable: total > 0, loaded, total, target: this,
    }));
  }

  private changeState(state: number): void {
    this.readyState = state;
    this.dispatchEvent(new Event("readystatechange"));
  }

  /** Starts a request. Only async requests are made: there is no worker to block. */
  open(method: string, url: string, isAsync: boolean = true, user?: string, password?: string): void {
    void user;
    void password;
    if (!isAsync) {
      throw new Error("InvalidAccessError: synchronous XMLHttpRequest is not supported");
    }
    if (this.sending) this.abort();
    this.method = String(method).toUpperCase();
    this.url = String(url);
    this.isAsync = true;
    this.requestHeaders = new Headers();
    this.responseHeaders = null;
    this.responseBytes = null;
    this.responseMime = "";
    this.overrideMime = "";
    this.status = 0;
    this.statusText = "";
    this.responseURL = "";
    this.aborted = false;
    this.timedOut = false;
    this.sending = false;
    this.changeState(OPENED);
  }

  setRequestHeader(name: string, value: string): void {
    if (this.readyState !== OPENED || this.sending) {
      throw new Error("InvalidStateError: setRequestHeader() must be called before send()");
    }
    this.requestHeaders.append(name, value);
  }

  /** The request's headers, as the one string getAllResponseHeaders() reports. */
  getAllResponseHeaders(): string {
    if (this.responseHeaders === null || this.readyState < HEADERS_RECEIVED) return "";
    let out = "";
    const entries = this.responseHeaders.entries();
    for (let i = 0; i < entries.length; i++) {
      const name = entries[i][0];
      if (name === "set-cookie" || name === "set-cookie2") continue;
      out += name + ": " + entries[i][1] + "\r\n";
    }
    return out;
  }

  getResponseHeader(name: string): string | null {
    if (this.responseHeaders === null || this.readyState < HEADERS_RECEIVED) return null;
    const key = String(name).toLowerCase();
    if (key === "set-cookie" || key === "set-cookie2") return null;
    return this.responseHeaders.get(key);
  }

  /** Names the type the response is decoded as; a charset it carries is honored for text. */
  overrideMimeType(mime: string): void {
    if (this.readyState === LOADING || this.readyState === DONE) {
      throw new Error("InvalidStateError: overrideMimeType() cannot be called while the request is loading");
    }
    this.overrideMime = String(mime);
  }

  get responseText(): string {
    if (this.responseType !== "" && this.responseType !== "text") {
      throw new Error("InvalidStateError: responseText is only available when responseType is '' or 'text'");
    }
    if (this.responseBytes === null) return "";
    return decodeText(this.responseBytes, this.mime());
  }

  get response(): any {
    const type = this.responseType === "" ? "text" : this.responseType;
    if (type === "json") {
      if (this.responseBytes === null) return null;
      try { return JSON.parse(decodeText(this.responseBytes, this.mime())); } catch (e) { return null; }
    }
    if (type === "arraybuffer") {
      if (this.responseBytes === null) return null;
      const copy = new ArrayBuffer(this.responseBytes.length);
      const view = new Uint8Array(copy);
      for (let i = 0; i < this.responseBytes.length; i++) view[i] = this.responseBytes[i];
      return copy;
    }
    if (type === "blob") {
      if (this.responseBytes === null) return null;
      return blobOf(this.responseBytes, this.mime());
    }
    if (type === "document") {
      throw new Error("InvalidAccessError: responseType 'document' is not supported");
    }
    return this.responseText;
  }

  private mime(): string {
    if (this.overrideMime !== "") return this.overrideMime;
    if (this.responseHeaders === null) return this.responseMime;
    const type = this.responseHeaders.get("content-type");
    return type === null ? this.responseMime : type;
  }

  /** Sends the request. The body may be a string, bytes, a Blob or a FormData. */
  send(body?: any): void {
    if (this.readyState !== OPENED || this.sending) {
      throw new Error("InvalidStateError: send() must be called once, after open()");
    }
    if (this.method === "GET" || this.method === "HEAD") body = null;
    this.sending = true;
    this.hasBody = body !== null && body !== undefined;
    this.aborted = false;
    this.timedOut = false;
    this.fire("loadstart");
    if (this.hasBody) {
      this.upload._fire("loadstart", 0, 0);
      const size = typeof body === "string" ? body.length : typeof body.size === "number" ? body.size : 0;
      this.upload._fire("progress", size, size);
    }
    const controller = new AbortController();
    this.controller = controller;
    if (this.timeout > 0) {
      this.timer = setTimeout(() => {
        this.timedOut = true;
        if (this.controller !== null) this.controller.abort();
      }, this.timeout);
    }
    this.request(body, controller).then((done) => {
      if (!done) return;
      this.clearTimer();
      this.sending = false;
      if (this.hasBody) {
        this.upload._fire("load", 0, 0);
        this.upload._fire("loadend", 0, 0);
      }
      const length = this.responseBytes === null ? 0 : this.responseBytes.length;
      this.fire("load", length, this.total());
      this.fire("loadend", length, this.total());
    }, (error: any) => {
      this.fail(error);
    });
  }

  private clearTimer(): void {
    if (this.timer !== null) { clearTimeout(this.timer); this.timer = null; }
  }

  private total(): number {
    if (this.responseHeaders === null) return 0;
    const len = this.responseHeaders.get("content-length");
    if (len === null) return this.responseBytes === null ? 0 : this.responseBytes.length;
    const n = Number(len);
    return isNaN(n) ? 0 : n;
  }

  /** The request's work: fetch, then read the body; false when the request was aborted. */
  private async request(body: any, controller: AbortController): Promise<boolean> {
    const response: Response = await fetch(this.url, {
      method: this.method, headers: this.requestHeaders, body: body === null ? undefined : body, signal: controller.signal,
    });
    if (this.aborted) return false;
    this.status = response.status;
    this.statusText = response.statusText;
    this.responseURL = response.url;
    this.responseHeaders = response.headers;
    const type = response.headers.get("content-type");
    this.responseMime = type === null ? "" : type;
    this.changeState(HEADERS_RECEIVED);
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (this.aborted) return false;
    this.responseBytes = bytes;
    this.changeState(LOADING);
    this.fire("progress", bytes.length, this.total());
    this.changeState(DONE);
    return true;
  }

  /** Ends the request after a failure, with the event the failure names. */
  private fail(error: any): void {
    this.clearTimer();
    if (this.aborted) return;
    const name = error === null || error === undefined ? "" : (error as { name?: string }).name;
    this.status = 0;
    this.statusText = "";
    this.responseBytes = null;
    this.changeState(DONE);
    const type = this.timedOut ? "timeout" : name === "AbortError" ? "abort" : "error";
    this.fire(type);
    this.fire("loadend");
    if (this.hasBody) {
      this.upload._fire(type === "abort" ? "abort" : type, 0, 0);
      this.upload._fire("loadend", 0, 0);
    }
    this.sending = false;
  }

  /** Stops the request: the events are abort then loadend, as the spec orders them. */
  abort(): void {
    if (this.readyState === UNSENT) return;
    if (this.readyState === DONE && !this.sending) return;
    this.aborted = true;
    this.clearTimer();
    if (this.controller !== null) this.controller.abort();
    this.status = 0;
    this.statusText = "";
    this.responseBytes = null;
    if (this.readyState !== DONE) this.changeState(DONE);
    this.fire("abort");
    this.fire("loadend");
    if (this.hasBody) {
      this.upload._fire("abort", 0, 0);
      this.upload._fire("loadend", 0, 0);
    }
    this.sending = false;
  }
}
