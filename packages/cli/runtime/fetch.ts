// fetch() and the Fetch API: a page-relative URL, a "/" URL (the site root: a public directory,
// or the bundle, which holds its files at the root) or a file: URL names a file the build copied,
// and the host reads its bytes; a data: URL is decoded here. An http: or https: URL
// goes to the network through the native runtime's HTTP client (the same one Node's fetch uses),
// which keeps the platform's TLS and certificate store.
//
// The API follows Chrome: Request and Response wrap a body that may be a string, an ArrayBuffer
// or typed array, a Blob, a FormData, a URLSearchParams or a ReadableStream, and text(), json(),
// arrayBuffer(), blob() and formData() read it once. A response read from the network keeps its
// body as a stream, so a loader reads it in the chunks the server sends and reports progress; a
// response read from a file is a stream over the file's bytes in 64 KiB chunks.
//
// The app is a desktop program, not a web page: it has no origin, so CORS doesn't apply (a
// request is sent without an Origin header, as a native HTTP client's is) and cookies are not
// stored or sent, as Node's fetch doesn't either. credentials is accepted and ignored, and a
// Set-Cookie header is readable through the response's headers.

import { plainBytes } from "./bytes.ts";
import { hostFileRead, hostFileSize } from "./host.ts";
import { Blob, File, FormData, dictBool, dictUnsignedLong, eventInitArg, eventTypeArg } from "./dom.ts";

/** The directory the page was built from: what a page-relative URL resolves against. */
let appDir = "";

/** A dev build's public directory: what a site-root URL ("/cover.png") resolves against. A
 *  bundled build leaves it empty, since the public files are in the bundle's own root. */
let siteDir = "";

/** Records the directory page-relative URLs resolve against, and a dev build's public one. */
export function setFetchBase(dir: string, site: string = ""): void {
  appDir = dir;
  siteDir = site;
}

// ---------------------------------------------------------------------------
// Small helpers

/** The bytes of a string in UTF-8. */
function utf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/** One buffer holding the given parts, in order. */
function concat(parts: Uint8Array[]): Uint8Array {
  let size = 0;
  for (let i = 0; i < parts.length; i++) size += parts[i].length;
  const out = new Uint8Array(size);
  let at = 0;
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    for (let j = 0; j < part.length; j++) out[at++] = part[j];
  }
  return out;
}

function isStreamLike(v: any): boolean {
  return v !== null && typeof v === "object" && typeof v.getReader === "function";
}

function isBlobLike(v: any): boolean {
  return v !== null && typeof v === "object" && typeof v.size === "number"
    && typeof v.type === "string" && typeof v.arrayBuffer === "function";
}

function isFileLike(v: any): boolean {
  return isBlobLike(v) || (v !== null && typeof v === "object" && typeof v.name === "string"
    && typeof v.size === "number" && typeof v.type === "string");
}

function isURLSearchParamsLike(v: any): boolean {
  return v !== null && typeof v === "object" && typeof v.append === "function"
    && typeof v.toString === "function" && typeof v.getAll === "function";
}

/** The bytes of a request or response body, or null for no body. */
async function bodyBytes(source: any): Promise<Uint8Array | null> {
  if (source === null || source === undefined) return null;
  if (typeof source === "string") return utf8(source);
  if (isStreamLike(source)) {
    const chunks: Uint8Array[] = [];
    const reader = source.getReader();
    while (true) {
      const step = await reader.read();
      if (step.done) break;
      chunks.push(new Uint8Array(step.value));
    }
    return concat(chunks);
  }
  if (source instanceof FormData) return formDataBytes(source).bytes;
  if (isBlobLike(source)) return new Uint8Array(await source.arrayBuffer());
  if (isURLSearchParamsLike(source)) return utf8(source.toString());
  if (source instanceof ArrayBuffer) return new Uint8Array(source);
  // An ArrayBufferView (a typed array or a DataView) keeps its own window into its buffer.
  if (typeof source === "object" && typeof source.byteLength === "number" && source.buffer !== undefined) {
    const view = new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    return new Uint8Array(view);
  }
  throw new TypeError("Failed to execute 'fetch': the body is not a supported type");
}

/** How many bytes one read of a body stream hands over. */
const CHUNK = 65536;

/** The bytes as a stream, in chunks: a reader sees a file arrive in pieces, as it would over the
 *  network, which is what a loader counts up to report progress. */
function byteStream(bytes: Uint8Array): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    start(controller: ReadableStreamDefaultController<Uint8Array>) {
      let at = 0;
      while (at < bytes.length) {
        const end = at + CHUNK < bytes.length ? at + CHUNK : bytes.length;
        const chunk = new Uint8Array(end - at);
        for (let i = at; i < end; i++) chunk[i - at] = bytes[i];
        controller.enqueue(chunk);
        at = end;
      }
      controller.close();
    },
  });
}

/** A body stream over a source that has to be read first (a Blob, a FormData, text). */
function sourceStream(source: any): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    async start(controller: ReadableStreamDefaultController<Uint8Array>) {
      const bytes = await bodyBytes(source);
      const parts = bytes === null ? new Uint8Array(0) : bytes;
      let at = 0;
      while (at < parts.length) {
        const end = at + CHUNK < parts.length ? at + CHUNK : parts.length;
        const chunk = new Uint8Array(end - at);
        for (let i = at; i < end; i++) chunk[i - at] = parts[i];
        controller.enqueue(chunk);
        at = end;
      }
      controller.close();
    },
  });
}

/** The digest size an integrity algorithm names, or 0 for one SRI doesn't know. */
function integrityBits(algorithm: string): number {
  if (algorithm === "sha256") return 256;
  if (algorithm === "sha384") return 384;
  if (algorithm === "sha512") return 512;
  return 0;
}

/** The bytes a base64 SRI value names, or null when it isn't base64. URL-safe letters are taken
 *  too, and padding may be missing. */
function base64Bytes(value: string): Uint8Array | null {
  let text = value.replace(/-/g, "+").replace(/_/g, "/");
  while (text.length % 4 !== 0) text += "=";
  try {
    const binary = atob(text);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i) & 0xff;
    return out;
  } catch (e) {
    return null;
  }
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** Whether the bytes match the digests an integrity attribute lists, as Subresource Integrity
 *  checks them: the strongest supported algorithm present decides, every digest of that strength
 *  is tried, and metadata naming no supported algorithm matches nothing. */
async function integrityMatches(bytes: Uint8Array, metadata: string): Promise<boolean> {
  const tokens = metadata.trim().split(/\s+/);
  let best = 0;
  let wanted: Uint8Array[] = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    const dash = token.indexOf("-");
    if (dash <= 0) continue;
    const bits = integrityBits(token.slice(0, dash).toLowerCase());
    if (bits === 0) continue;
    let value = token.slice(dash + 1);
    const question = value.indexOf("?");
    if (question >= 0) value = value.slice(0, question);
    const digest = base64Bytes(value);
    if (digest === null) continue;
    if (bits > best) { best = bits; wanted = []; }
    if (bits === best) wanted.push(digest);
  }
  if (best === 0) return false;
  const buffer = await crypto.subtle.digest("SHA-" + best, plainBytes(bytes));
  const actual = new Uint8Array(buffer);
  for (let i = 0; i < wanted.length; i++) if (sameBytes(actual, wanted[i])) return true;
  return false;
}

/** The error a request that its signal aborted rejects with, named as Chrome names it. */
function abortError(message: string = "The operation was aborted."): Error {
  const e = new Error("AbortError: " + message);
  (e as { name?: string }).name = "AbortError";
  return e;
}

/** The TypeError a request that never reached a server rejects with. */
function networkError(): Error {
  return new TypeError("Failed to fetch");
}

// ---------------------------------------------------------------------------
// Headers

/** A header name is an HTTP token. */
const HEADER_NAME = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

/** A header list: names are lowercased, as a browser's are, and repeated names combine with ", ". */
export class Headers {
  get [Symbol.toStringTag](): string { return "Headers"; }
  private names: string[] = [];
  private vals: string[] = [];
  /** The Set-Cookie headers, kept apart: they never combine, as their Expires dates carry commas. */
  private cookies: string[] = [];

  /** What a Headers, a Request or a plain object of names to values carries: [name, value] pairs,
   *  another Headers, or an object (which is what a loader's requestHeader is). None when omitted. */
  constructor(init?: any) {
    if (init === undefined || init === null) return;
    if (Array.isArray(init)) {
      for (let i = 0; i < init.length; i++) this.append(String(init[i][0]), String(init[i][1]));
      return;
    }
    // A Headers (ours or the runtime's) and a Map both hand their entries to forEach as
    // (value, name).
    if (typeof init.forEach === "function") {
      init.forEach((value: any, name: any) => { this.append(String(name), String(value)); });
      if (typeof init.getSetCookie === "function") this._setCookieList(init.getSetCookie());
      return;
    }
    if (typeof init.entries === "function") {
      const pairs = init.entries();
      for (let i = 0; i < pairs.length; i++) this.append(String(pairs[i][0]), String(pairs[i][1]));
      return;
    }
    const keys = Object.keys(init);
    for (let i = 0; i < keys.length; i++) this.append(keys[i], String(init[keys[i]]));
  }

  /** The header's value in the form the list keeps it: surrounding HTTP whitespace dropped. */
  private static clean(name: string, value: string): string {
    if (name === "" || !HEADER_NAME.test(name)) throw new TypeError("Invalid header name: " + name);
    if (/[\0\r\n]/.test(value)) throw new TypeError("Invalid header value for '" + name + "'");
    return value.replace(/^[ \t]+|[ \t]+$/g, "");
  }

  append(name: string, value: string): void {
    const key = String(name).toLowerCase();
    const v = Headers.clean(key, String(value));
    if (key === "set-cookie") {
      this.cookies.push(v);
      return;
    }
    const at = this.names.indexOf(key);
    if (at < 0) { this.names.push(key); this.vals.push(v); return; }
    this.vals[at] = this.vals[at] + ", " + v;
  }

  set(name: string, value: string): void {
    const key = String(name).toLowerCase();
    const v = Headers.clean(key, String(value));
    if (key === "set-cookie") { this.cookies.length = 0; this.cookies.push(v); return; }
    const at = this.names.indexOf(key);
    if (at < 0) { this.names.push(key); this.vals.push(v); return; }
    this.vals[at] = v;
  }

  get(name: string): string | null {
    const key = String(name).toLowerCase();
    if (key === "set-cookie") return this.cookies.length === 0 ? null : this.cookies.join(", ");
    const at = this.names.indexOf(key);
    return at < 0 ? null : this.vals[at];
  }

  has(name: string): boolean {
    const key = String(name).toLowerCase();
    if (key === "set-cookie") return this.cookies.length > 0;
    return this.names.indexOf(key) >= 0;
  }

  delete(name: string): void {
    const key = String(name).toLowerCase();
    if (key === "set-cookie") { this.cookies.length = 0; return; }
    const at = this.names.indexOf(key);
    if (at < 0) return;
    this.names.splice(at, 1);
    this.vals.splice(at, 1);
  }

  /** The Set-Cookie headers as separate values, as Chrome's Headers.getSetCookie reports them. */
  getSetCookie(): string[] { return this.cookies.slice(); }

  /** Replaces the Set-Cookie list, for a response whose headers came from the network. */
  _setCookieList(list: string[]): void {
    this.cookies = [];
    for (let i = 0; i < list.length; i++) {
      const v = String(list[i]).replace(/^[ \t]+|[ \t]+$/g, "");
      if (v !== "") this.cookies.push(v);
    }
  }

  forEach(fn: (value: string, name: string, headers: Headers) => void): void {
    for (let i = 0; i < this.names.length; i++) fn(this.vals[i], this.names[i], this);
    for (let i = 0; i < this.cookies.length; i++) fn(this.cookies[i], "set-cookie", this);
  }

  /** The entries in order, each a [name, value] pair; a browser gives an iterator here. */
  entries(): string[][] {
    const out: string[][] = [];
    for (let i = 0; i < this.names.length; i++) out.push([this.names[i], this.vals[i]]);
    for (let i = 0; i < this.cookies.length; i++) out.push(["set-cookie", this.cookies[i]]);
    return out;
  }

  keys(): string[] {
    const out: string[] = this.names.slice();
    for (let i = 0; i < this.cookies.length; i++) out.push("set-cookie");
    return out;
  }

  values(): string[] {
    const out: string[] = this.vals.slice();
    for (let i = 0; i < this.cookies.length; i++) out.push(this.cookies[i]);
    return out;
  }

  [Symbol.iterator](): Iterator<string[]> { return this.entries()[Symbol.iterator](); }
}

// ---------------------------------------------------------------------------
// Multipart and URL-encoded bodies

/** A boundary for a FormData body, unique enough for one request. */
function boundary(): string {
  let b = "----nativeFormBoundary";
  for (let i = 0; i < 16; i++) b += "0123456789abcdef"[Math.floor(Math.random() * 16)];
  return b;
}

/** A name or filename in a multipart part, with the characters a quoted-string escapes. */
function quoted(text: string): string {
  return text.replace(/[\r\n]/g, "").replace(/"/g, "%22").replace(/\\/g, "\\\\");
}

/** The bytes of a FormData as multipart/form-data, and the Content-Type that names them. */
function formDataBytes(form: FormData): { bytes: Uint8Array; type: string } {
  const b = boundary();
  const parts: Uint8Array[] = [];
  const entries = form.entries();
  for (let i = 0; i < entries.length; i++) {
    const name = String(entries[i][0]);
    const value: any = entries[i][1];
    let head = "--" + b + "\r\nContent-Disposition: form-data; name=\"" + quoted(name) + "\"";
    let body: Uint8Array;
    if (isFileLike(value)) {
      const file = value as { name: string; type: string };
      const type = file.type !== "" ? file.type : "application/octet-stream";
      head += "; filename=\"" + quoted(file.name) + "\"\r\nContent-Type: " + type + "\r\n\r\n";
      // A File here holds a name and a size but not its bytes yet, so its part is empty.
      body = new Uint8Array(0);
    } else {
      head += "\r\n\r\n";
      body = utf8(String(value));
    }
    parts.push(utf8(head));
    parts.push(body);
    parts.push(utf8("\r\n"));
  }
  parts.push(utf8("--" + b + "--\r\n"));
  return { bytes: concat(parts), type: "multipart/form-data; boundary=" + b };
}

/** The media type a string names, lowercased, and its parameters. */
function mediaType(value: string | null): string {
  if (value === null || value === "") return "";
  const semi = value.indexOf(";");
  const base = semi < 0 ? value : value.slice(0, semi);
  return base.trim().toLowerCase();
}

/** The `boundary` parameter of a multipart media type, or "" when it gives none. */
function boundaryParam(value: string | null): string {
  if (value === null) return "";
  const m = /boundary=(?:"([^"]*)"|([^;]*))/i.exec(value);
  if (m === null) return "";
  return (m[1] !== undefined ? m[1] : m[2]).trim();
}

/** Parses an application/x-www-form-urlencoded body into FormData. */
function formDataFromUrlEncoded(text: string): FormData {
  const form = new FormData();
  const params = new URLSearchParams(text);
  params.forEach((value: string, name: string) => { form.append(name, value); });
  return form;
}

/** Parses a multipart/form-data body into FormData. Text parts become strings; a part with a
 *  filename becomes a File, whose name, type and size are kept but whose bytes aren't held. */
function formDataFromMultipart(bytes: Uint8Array, bound: string): FormData {
  const form = new FormData();
  const text = new TextDecoder().decode(bytes);
  const marker = "--" + bound;
  let at = text.indexOf(marker);
  while (at >= 0) {
    at += marker.length;
    if (text.slice(at, at + 2) === "--") break;
    if (text.slice(at, at + 2) === "\r\n") at += 2;
    const next = text.indexOf(marker, at);
    if (next < 0) break;
    let part = text.slice(at, next);
    if (part.endsWith("\r\n")) part = part.slice(0, part.length - 2);
    const split = part.indexOf("\r\n\r\n");
    const head = split < 0 ? part : part.slice(0, split);
    const body = split < 0 ? "" : part.slice(split + 4);
    const nameM = /name="([^"]*)"/i.exec(head);
    const fileM = /filename="([^"]*)"/i.exec(head);
    const typeM = /Content-Type:\s*([^\r\n]*)/i.exec(head);
    if (nameM !== null) {
      const name = nameM[1];
      if (fileM !== null) {
        const type = typeM === null ? "" : typeM[1].trim();
        form.append(name, new File(fileM[1], body.length, type));
      } else {
        form.append(name, body);
      }
    }
    at = next;
  }
  return form;
}

// ---------------------------------------------------------------------------
// Response

/** What a constructed Response takes besides its body. */
export interface ResponseInit {
  status?: number;
  statusText?: string;
  headers?: any;
}

/** The fields a Response built from the network or from a status alone carries. */
interface ResponseState {
  native?: any;
  status?: number;
  statusText?: string;
  url?: string;
  redirected?: boolean;
  type?: string;
  headers?: Headers;
  source?: any;
  empty?: boolean;
}

/** A response: a status and headers, and a body that is read once unless it is cloned first. */
export class Response {
  get [Symbol.toStringTag](): string { return "Response"; }
  readonly status: number;
  readonly statusText: string;
  readonly ok: boolean;
  readonly url: string;
  readonly redirected: boolean;
  readonly type: string;
  readonly headers: Headers;

  /** The runtime's own response, when this one came from the network; null otherwise. */
  private native: any;
  /** The body's value for a response made here or read from a file. */
  private source: any;
  private hasBody: boolean;
  private stream: ReadableStream<Uint8Array> | null;
  private built: boolean;
  private used: boolean;

  constructor(body?: any, init?: ResponseInit, state?: ResponseState) {
    if (state !== undefined) {
      this.native = state.native === undefined ? null : state.native;
      this.status = state.status === undefined ? 200 : state.status;
      this.statusText = state.statusText === undefined ? "" : state.statusText;
      this.url = state.url === undefined ? "" : state.url;
      this.redirected = state.redirected === true;
      this.type = state.type === undefined ? "basic" : state.type;
      this.headers = state.headers === undefined ? new Headers() : state.headers;
      this.source = state.source === undefined ? null : state.source;
      this.hasBody = state.empty !== true && this.source !== null;
      this.stream = null;
      this.built = false;
      this.used = false;
      this.ok = this.status >= 200 && this.status < 300;
      return;
    }
    const status = init !== undefined && init.status !== undefined ? init.status : 200;
    if (status < 200 || status > 599) throw new RangeError("Response status must be between 200 and 599");
    const statusText = init !== undefined && init.statusText !== undefined ? String(init.statusText) : "";
    if (/[\r\n]/.test(statusText)) throw new TypeError("Invalid statusText");
    if (body !== undefined && body !== null && (status === 204 || status === 205 || status === 304)) {
      throw new TypeError("A response with status " + status + " cannot have a body");
    }
    this.native = null;
    this.status = status;
    this.statusText = statusText;
    this.url = "";
    this.redirected = false;
    this.type = "default";
    this.headers = new Headers(init === undefined ? undefined : init.headers);
    this.hasBody = body !== undefined && body !== null;
    this.used = false;
    this.stream = null;
    this.built = false;
    this.ok = status >= 200 && status < 300;
    if (body === undefined || body === null) { this.source = null; return; }
    let source: any = body;
    if (source instanceof FormData) {
      // FormData's multipart body and its Content-Type are made together, so the boundary the
      // header names is the one the bytes use.
      const encoded = formDataBytes(source);
      if (!this.headers.has("content-type")) this.headers.set("content-type", encoded.type);
      source = encoded.bytes;
    } else if (typeof source === "string") {
      if (!this.headers.has("content-type")) this.headers.set("content-type", "text/plain;charset=UTF-8");
    } else if (isBlobLike(source)) {
      const type = typeof source.type === "string" ? source.type : "";
      if (type !== "" && !this.headers.has("content-type")) this.headers.set("content-type", type);
    } else if (isURLSearchParamsLike(source)) {
      if (!this.headers.has("content-type")) {
        this.headers.set("content-type", "application/x-www-form-urlencoded;charset=UTF-8");
      }
    }
    this.source = source;
  }

  /** A response over bytes already read: a file or a data: URL. */
  static _bytes(bytes: Uint8Array, url: string, headers: Headers): Response {
    return new Response(undefined, undefined, {
      status: 200, statusText: "OK", source: bytes, url, headers, type: "basic",
    });
  }

  /** The response for what the runtime's HTTP client returned. */
  static _fromNative(native: any, redirect: string, bytes?: Uint8Array): Response {
    const status = native.status;
    if (redirect === "manual" && (status === 301 || status === 302 || status === 303 || status === 307 || status === 308)) {
      // A manual redirect hands the page an opaque-redirect response: no status, no headers, no
      // body, and the Location header isn't readable.
      return new Response(undefined, undefined, { status: 0, type: "opaqueredirect", empty: true });
    }
    const headers = new Headers(native.headers);
    if (native.headers !== null && typeof native.headers.getSetCookie === "function") {
      headers._setCookieList(native.headers.getSetCookie());
    }
    if (bytes !== undefined) {
      // The integrity check has already read the body, so the response carries those bytes rather
      // than the client handle the body came from.
      return new Response(undefined, undefined, {
        status,
        statusText: native.statusText === undefined ? "" : native.statusText,
        url: native.url === undefined ? "" : native.url,
        redirected: native.redirected === true,
        headers,
        type: "basic",
        source: bytes,
      });
    }
    return new Response(undefined, undefined, {
      native,
      status,
      statusText: native.statusText === undefined ? "" : native.statusText,
      url: native.url === undefined ? "" : native.url,
      redirected: native.redirected === true,
      headers,
      type: "basic",
    });
  }

  /** The response a script makes with `Response.error()`. */
  static error(): Response {
    return new Response(undefined, undefined, { status: 0, type: "error", empty: true });
  }

  /** The response a script makes with `Response.json(value, init)`. */
  static json(value: any, init?: ResponseInit): Response {
    const text = JSON.stringify(value);
    // The constructor would call a string body text/plain, so the JSON type goes in first.
    const headers = new Headers(init === undefined ? undefined : init.headers);
    if (!headers.has("content-type")) headers.set("content-type", "application/json");
    const status = init === undefined || init.status === undefined ? 200 : init.status;
    const statusText = init === undefined || init.statusText === undefined ? "" : init.statusText;
    return new Response(text === undefined ? "" : text, { status, statusText, headers });
  }

  /** The response a script makes with `Response.redirect(url, status)`. */
  static redirect(url: string, status: number = 302): Response {
    if (status !== 301 && status !== 302 && status !== 303 && status !== 307 && status !== 308) {
      throw new RangeError("Invalid redirect status " + status);
    }
    const r = new Response(undefined, { status });
    r.headers.set("location", String(url));
    return r;
  }

  /** The body as a stream, or null for a response that has none. */
  get body(): ReadableStream<Uint8Array> | null {
    if (this.native !== null) return this.native.body;
    if (!this.hasBody) return null;
    if (!this.built) { this.stream = sourceStream(this.source); this.built = true; }
    return this.stream;
  }

  get bodyUsed(): boolean {
    if (this.native !== null) return this.native.bodyUsed === true;
    return this.used;
  }

  /** The body's bytes, marking the body used. */
  private async take(): Promise<Uint8Array> {
    if (this.native !== null) return new Uint8Array(await this.native.arrayBuffer());
    if (this.used) throw new TypeError("Body is unusable: Body has already been read");
    this.used = true;
    const bytes = await bodyBytes(this.source);
    return bytes === null ? new Uint8Array(0) : bytes;
  }

  text(): Promise<string> { return this.take().then((bytes) => new TextDecoder().decode(bytes)); }

  json(): Promise<any> { return this.text().then((text) => JSON.parse(text)); }

  /** The body's bytes, as a Uint8Array the page owns. */
  async bytes(): Promise<Uint8Array> { return this.take(); }

  arrayBuffer(): Promise<ArrayBuffer> {
    return this.take().then((bytes) => {
      const copy = new ArrayBuffer(bytes.length);
      const view = new Uint8Array(copy);
      for (let i = 0; i < bytes.length; i++) view[i] = bytes[i];
      return copy;
    });
  }

  blob(): Promise<Blob> {
    const type = this.headers.get("content-type") === null ? "" : this.headers.get("content-type") as string;
    return this.take().then((bytes) => new Blob([plainBytes(bytes)], { type }));
  }

  /** The body as FormData: a form-urlencoded or multipart body parses; another doesn't. */
  async formData(): Promise<FormData> {
    const type = mediaType(this.headers.get("content-type"));
    const bytes = await this.take();
    if (type === "application/x-www-form-urlencoded") {
      return formDataFromUrlEncoded(new TextDecoder().decode(bytes));
    }
    if (type === "multipart/form-data") {
      const bound = boundaryParam(this.headers.get("content-type"));
      if (bound !== "") return formDataFromMultipart(bytes, bound);
    }
    throw new TypeError("Could not parse content as FormData");
  }

  clone(): Response {
    if (this.bodyUsed) throw new TypeError("Failed to execute 'clone' on 'Response': Response body is already used");
    if (this.native !== null) return Response._fromNative(this.native.clone(), "follow");
    const copy = this.headers === null ? new Headers() : new Headers(this.headers);
    return new Response(undefined, undefined, {
      source: this.source, url: this.url, redirected: this.redirected, type: this.type,
      headers: copy, status: this.status, statusText: this.statusText, empty: !this.hasBody,
    });
  }
}

/** The response for a URL that names the app's own bytes, or null when it names none. */
export function responseForBytes(bytes: Uint8Array, url: string, status: number, statusText: string, headers: Headers): Response {
  return new Response(undefined, undefined, {
    status, statusText, url, headers, source: bytes, type: "basic",
  });
}

// ---------------------------------------------------------------------------
// ProgressEvent

/** The progress a body stream reports as it is read: what a loader hands on while a file loads. */
export class ProgressEvent {
  get [Symbol.toStringTag](): string { return "ProgressEvent"; }
  readonly type: string;
  readonly lengthComputable: boolean;
  readonly loaded: number;
  readonly total: number;
  readonly target: any;

  constructor(...args: any[]) {
    const init = eventInitArg(args);
    this.type = eventTypeArg(args);
    this.lengthComputable = dictBool(init, "lengthComputable", false);
    this.loaded = dictUnsignedLong(init, "loaded", 0);
    this.total = dictUnsignedLong(init, "total", 0);
    this.target = init.target === undefined ? null : init.target;
  }
}

// ---------------------------------------------------------------------------
// URLs

/** The bytes a `%41`-style escape names, or -1 when the escape is malformed. */
function hexPair(a: number, b: number): number {
  const hi = a >= 48 && a <= 57 ? a - 48 : a >= 65 && a <= 70 ? a - 55 : a >= 97 && a <= 102 ? a - 87 : -1;
  const lo = b >= 48 && b <= 57 ? b - 48 : b >= 65 && b <= 70 ? b - 55 : b >= 97 && b <= 102 ? b - 87 : -1;
  return hi < 0 || lo < 0 ? -1 : hi * 16 + lo;
}

/** Percent-decodes a URL path into its bytes: a path is UTF-8, so decoding waits for the end. */
function percentBytes(path: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < path.length; i++) {
    const c = path.charCodeAt(i);
    if (c === 37 && i + 2 < path.length) {
      const b = hexPair(path.charCodeAt(i + 1), path.charCodeAt(i + 2));
      if (b >= 0) { out.push(b); i += 2; continue; }
    }
    // A code unit above 127 is a UTF-8 lead or continuation byte already, as the string is one
    // UTF-16 unit per byte for URLs written in ASCII; anything else goes through as itself.
    out.push(c & 0xff);
  }
  const bytes = new Uint8Array(out.length);
  for (let i = 0; i < out.length; i++) bytes[i] = out[i];
  return bytes;
}

function percentDecode(path: string): string { return new TextDecoder().decode(percentBytes(path)); }

/** Collapses "." and ".." segments the way URL resolution does, clamped at the root: a path that
 *  climbs above the page's directory stays in it, as a browser's does at its site root. */
function normalizePath(path: string): string {
  const out: string[] = [];
  const parts = path.split("/");
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part === "" || part === ".") continue;
    if (part === "..") { if (out.length > 0) out.pop(); continue; }
    out.push(part);
  }
  return "/" + out.join("/");
}

/** The file a URL names, or "" for one that names no app file (a network URL, or a scheme that
 *  isn't understood). */
function fileFor(url: string): string {
  let clean = url.trim();
  const hash = clean.indexOf("#");
  if (hash >= 0) clean = clean.slice(0, hash);
  const query = clean.indexOf("?");
  if (query >= 0) clean = clean.slice(0, query);
  if (clean === "") return "";
  if (clean.startsWith("//")) return "";
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(clean);
  if (scheme !== null) {
    if (scheme[1].toLowerCase() !== "file") return "";
    // file: URL: file:/p, file:///p and file://localhost/p all name /p.
    let path = clean.slice(5);
    if (path.startsWith("//")) {
      const slash = path.indexOf("/", 2);
      path = slash < 0 ? "/" : path.slice(slash);
    }
    return percentDecode(path);
  }
  if (appDir === "") return "";
  // A "/" URL names the site root: the public directory in a dev build, and the bundle in a
  // bundled one. A page-relative URL resolves against the page's own directory. ".." stops at
  // that root rather than climbing into the directory above.
  const base = clean.startsWith("/") && siteDir !== "" ? siteDir : appDir;
  const path = normalizePath(percentDecode(clean));
  return base.replace(/\/+$/, "") + path;
}

/** The Content-Type a file extension names, as a browser serving the file would send. */
function contentType(path: string): string {
  const dot = path.lastIndexOf(".");
  const ext = dot < 0 ? "" : path.slice(dot + 1).toLowerCase();
  if (ext === "json") return "application/json";
  if (ext === "txt") return "text/plain";
  if (ext === "html" || ext === "htm") return "text/html";
  if (ext === "css") return "text/css";
  if (ext === "js" || ext === "mjs") return "text/javascript";
  if (ext === "svg") return "image/svg+xml";
  if (ext === "png") return "image/png";
  if (ext === "jpg" || ext === "jpeg") return "image/jpeg";
  if (ext === "gif") return "image/gif";
  if (ext === "webp") return "image/webp";
  if (ext === "glb") return "model/gltf-binary";
  if (ext === "gltf") return "model/gltf+json";
  if (ext === "bin") return "application/octet-stream";
  if (ext === "wasm") return "application/wasm";
  return "application/octet-stream";
}

/** The file a page-relative, "/" or file: URL names, as a host would open it; "" for any other. */
export function resolveAssetPath(url: string): string {
  return fileFor(url);
}

/** The bytes a data: URL carries, or null when it is malformed. */
function dataBytes(url: string): Uint8Array | null {
  const comma = url.indexOf(",");
  if (comma < 0) return null;
  const meta = url.slice(5, comma);
  const body = url.slice(comma + 1);
  if (/;base64$/i.test(meta)) {
    const text = atob(body);
    const bytes = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
    return bytes;
  }
  return percentBytes(body);
}

/** The media type a data: URL names; "" when it gives none (which a browser defaults to text). */
function dataType(url: string): string {
  const comma = url.indexOf(",");
  if (comma < 0) return "";
  const meta = url.slice(5, comma);
  const semi = meta.indexOf(";");
  return semi < 0 ? meta : meta.slice(0, semi);
}

// ---------------------------------------------------------------------------
// Request

/** A request method is an HTTP token; these four methods are forbidden to fetch. */
const FORBIDDEN_METHODS = ["CONNECT", "TRACE", "TRACK"];

/** The methods the spec uppercases; any other method keeps the case it was given. */
const NORMALIZED_METHODS = ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"];

function normalizeMethod(method: string): string {
  const upper = method.toUpperCase();
  if (NORMALIZED_METHODS.indexOf(upper) >= 0) return upper;
  return method;
}

/** What a Request takes besides its URL. */
export interface RequestInit {
  method?: string;
  headers?: any;
  body?: any;
  cache?: string;
  credentials?: string;
  priority?: string;
  signal?: any;
  mode?: string;
  redirect?: string;
  referrer?: string;
  referrerPolicy?: string;
  integrity?: string;
  keepalive?: boolean;
  duplex?: string;
}

/** A request: the URL it names and the options it carries. The URL is not resolved here: fetch
 *  resolves a page-relative one against the directory the page was built from. */
export class Request {
  get [Symbol.toStringTag](): string { return "Request"; }
  readonly url: string;
  readonly method: string;
  readonly headers: Headers;
  readonly cache: string;
  readonly credentials: string;
  readonly priority: string;
  readonly signal: AbortSignal | null;
  readonly mode: string;
  readonly redirect: string;
  readonly referrer: string;
  readonly referrerPolicy: string;
  readonly integrity: string;
  readonly keepalive: boolean;
  readonly duplex: string;
  readonly destination: string = "";

  /** The body's value, as it was given: a string, bytes, a Blob, a FormData or a stream. */
  private rawBody: any;
  private stream: ReadableStream<Uint8Array> | null;
  private built: boolean;
  private used: boolean;

  constructor(input: string | Request, init?: RequestInit) {
    const source = typeof input === "string" ? null : input;
    this.url = source === null ? String(input) : source.url;
    const method = init !== undefined && init.method !== undefined ? String(init.method)
      : source !== null ? source.method : "GET";
    const upper = method.toUpperCase();
    if (!HEADER_NAME.test(method)) throw new TypeError("Invalid method '" + method + "'");
    if (FORBIDDEN_METHODS.indexOf(upper) >= 0) throw new TypeError("Forbidden method '" + method + "'");
    this.method = normalizeMethod(method);
    this.headers = new Headers(init !== undefined && init.headers !== undefined ? init.headers
      : source !== null ? source.headers : undefined);
    this.cache = init !== undefined && init.cache !== undefined ? String(init.cache)
      : source !== null ? source.cache : "default";
    this.credentials = init !== undefined && init.credentials !== undefined ? String(init.credentials)
      : source !== null ? source.credentials : "same-origin";
    this.priority = init !== undefined && init.priority !== undefined ? String(init.priority)
      : source !== null ? source.priority : "auto";
    this.signal = init !== undefined && init.signal !== undefined ? init.signal
      : source !== null ? source.signal : new AbortController().signal;
    this.mode = init !== undefined && init.mode !== undefined ? String(init.mode)
      : source !== null ? source.mode : "cors";
    this.redirect = init !== undefined && init.redirect !== undefined ? String(init.redirect)
      : source !== null ? source.redirect : "follow";
    this.referrer = init !== undefined && init.referrer !== undefined ? String(init.referrer)
      : source !== null ? source.referrer : "about:client";
    this.referrerPolicy = init !== undefined && init.referrerPolicy !== undefined ? String(init.referrerPolicy)
      : source !== null ? source.referrerPolicy : "";
    this.integrity = init !== undefined && init.integrity !== undefined ? String(init.integrity)
      : source !== null ? source.integrity : "";
    // A no-cors request can't be checked against a digest, so Chrome refuses to make one.
    if (this.mode === "no-cors" && this.integrity !== "") {
      throw new TypeError("Request mode is 'no-cors' but the integrity attribute is set");
    }
    this.keepalive = init !== undefined && init.keepalive !== undefined ? init.keepalive === true
      : source !== null ? source.keepalive : false;
    this.duplex = init !== undefined && init.duplex !== undefined ? String(init.duplex)
      : source !== null ? source.duplex : "half";

    if (source !== null && source.used) {
      throw new TypeError("Cannot construct a Request with a Request object that has already been used.");
    }
    let body: any = init !== undefined && init.body !== undefined ? init.body
      : source !== null ? source.rawBody : null;
    if (body === undefined) body = null;
    if ((this.method === "GET" || this.method === "HEAD") && body !== null) {
      throw new TypeError("Request with GET/HEAD method cannot have body.");
    }
    if (body instanceof FormData) {
      const encoded = formDataBytes(body);
      if (!this.headers.has("content-type")) this.headers.set("content-type", encoded.type);
      body = encoded.bytes;
    } else if (typeof body === "string") {
      if (!this.headers.has("content-type")) this.headers.set("content-type", "text/plain;charset=UTF-8");
    } else if (isBlobLike(body)) {
      const type = typeof body.type === "string" ? body.type : "";
      if (type !== "" && !this.headers.has("content-type")) this.headers.set("content-type", type);
    } else if (isURLSearchParamsLike(body)) {
      if (!this.headers.has("content-type")) {
        this.headers.set("content-type", "application/x-www-form-urlencoded;charset=UTF-8");
      }
    }
    this.rawBody = body;
    this.stream = null;
    this.built = false;
    this.used = false;
  }

  /** The body as a stream, or null when the request has none. */
  get body(): ReadableStream<Uint8Array> | null {
    if (this.rawBody === null) return null;
    if (isStreamLike(this.rawBody)) return this.rawBody;
    if (!this.built) { this.stream = sourceStream(this.rawBody); this.built = true; }
    return this.stream;
  }

  get bodyUsed(): boolean { return this.used; }

  /** The body's bytes, marking the body used. */
  private async take(): Promise<Uint8Array> {
    if (this.used) throw new TypeError("Body is unusable: Body has already been read");
    this.used = true;
    const bytes = await bodyBytes(this.rawBody);
    return bytes === null ? new Uint8Array(0) : bytes;
  }

  text(): Promise<string> { return this.take().then((bytes) => new TextDecoder().decode(bytes)); }

  json(): Promise<any> { return this.text().then((text) => JSON.parse(text)); }

  /** The body's bytes, as a Uint8Array the page owns. */
  async bytes(): Promise<Uint8Array> { return this.take(); }

  arrayBuffer(): Promise<ArrayBuffer> {
    return this.take().then((bytes) => {
      const copy = new ArrayBuffer(bytes.length);
      const view = new Uint8Array(copy);
      for (let i = 0; i < bytes.length; i++) view[i] = bytes[i];
      return copy;
    });
  }

  blob(): Promise<Blob> {
    const type = this.headers.get("content-type") === null ? "" : this.headers.get("content-type") as string;
    return this.take().then((bytes) => new Blob([plainBytes(bytes)], { type }));
  }

  async formData(): Promise<FormData> {
    const type = mediaType(this.headers.get("content-type"));
    const bytes = await this.take();
    if (type === "application/x-www-form-urlencoded") {
      return formDataFromUrlEncoded(new TextDecoder().decode(bytes));
    }
    if (type === "multipart/form-data") {
      const bound = boundaryParam(this.headers.get("content-type"));
      if (bound !== "") return formDataFromMultipart(bytes, bound);
    }
    throw new TypeError("Could not parse content as FormData");
  }

  clone(): Request {
    if (this.used) throw new TypeError("Cannot clone a Request object that has already been used.");
    return new Request(this);
  }

  /** The body for the runtime's HTTP client, marking it used as fetch hands it over. */
  _takeForSend(): any {
    if (this.rawBody === null) return null;
    this.used = true;
    return this.rawBody;
  }

  _isBodyUsed(): boolean { return this.used; }
}

// ---------------------------------------------------------------------------
// fetch

/** Whether a URL goes to the network: an http: or https: URL, wherever it was written. */
function isNetworkUrl(url: string): boolean {
  return /^https?:/i.test(url.trim());
}

/** Reads a URL the way a browser's fetch does: a page-relative, "/" or file: URL comes from the
 *  directory the page was built from, a data: URL decodes in place, and an http(s) URL goes over
 *  the network. A URL that names nothing readable rejects. */
export function fetch(input: string | Request, init?: RequestInit): Promise<Response> {
  let request: Request;
  try {
    request = input instanceof Request ? (init === undefined ? input : new Request(input, init)) : new Request(input, init);
  } catch (e) {
    return Promise.reject(e);
  }
  if (isNetworkUrl(request.url)) return networkFetch(request);
  return Promise.resolve().then(() => localFetch(request));
}

/** The response for a file: or data: URL, or for a page-relative one. */
function localFetch(request: Request): Response {
  const signal = request.signal;
  if (signal !== null && signal.aborted === true) throw abortError();
  const url = request.url;
  if (/^data:/i.test(url)) {
    const bytes = dataBytes(url);
    if (bytes === null) throw networkError();
    const headers = new Headers();
    const type = dataType(url);
    if (!headers.has("content-type")) headers.set("content-type", type === "" ? "text/plain;charset=US-ASCII" : type);
    headers.set("content-length", String(bytes.length));
    return Response._bytes(bytes, url, headers);
  }
  const path = fileFor(url);
  if (path === "") throw networkError();
  const size = hostFileSize(path);
  if (size < 0) throw networkError();
  const bytes = new Uint8Array(size);
  hostFileRead(path, (chunk) => {
    // The host hands over the whole file in one call, inside the call.
    for (let i = 0; i < chunk.length && i < bytes.length; i++) bytes[i] = chunk[i];
  });
  const headers = new Headers();
  headers.set("content-type", contentType(path));
  headers.set("content-length", String(size));
  return Response._bytes(bytes, "file://" + path, headers);
}

/** A request over the network, through the runtime's HTTP client. */
async function networkFetch(request: Request): Promise<Response> {
  const signal = request.signal;
  if (signal !== null && signal.aborted === true) throw abortError();
  let body = request._takeForSend();
  // An upload stream is read into one buffer for the client: it has no way to pull from a stream
  // while it sends, and the response body is the half that streams here.
  if (body !== null && (isStreamLike(body) || isBlobLike(body))) body = await bodyBytes(body);
  const init: any = {
    method: request.method,
    headers: request.headers.entries(),
    redirect: request.redirect,
    signal: signal === null ? undefined : signal,
    body: body === null ? undefined : body,
  };
  let native: any;
  try {
    native = await globalThis.fetch(request.url.trim(), init);
  } catch (e) {
    const name = e === null || e === undefined ? "" : (e as { name?: string }).name;
    if (name === "AbortError") throw abortError();
    throw networkError();
  }
  // Subresource Integrity: a non-empty integrity attribute makes the response's bytes part of the
  // contract. The bytes are read here, checked, and then handed to the page unchanged.
  let verified: Uint8Array | undefined = undefined;
  if (request.integrity !== "") {
    // The digest names the resource the request named; a redirect means these bytes came from
    // somewhere else, so the check fails rather than being made against the wrong resource.
    if (native.redirected === true) throw networkError();
    if (native.status >= 200 && native.status < 300) {
      const bytes = new Uint8Array(await native.arrayBuffer());
      if (!(await integrityMatches(bytes, request.integrity))) throw networkError();
      verified = bytes;
    }
  }
  return Response._fromNative(native, request.redirect, verified);
}
