// WebSocket: the client side of RFC 6455, over the runtime's HTTP client. A ws: URL is a request
// over http: and a wss: one over https:, each asking the server to switch protocols; from the 101
// response's socket on, the two sides speak WebSocket frames. TLS is the platform's, through the
// same client fetch() uses, so a wss: connection checks the server's certificate as a browser's
// does.
//
// The connection runs on the app's own event loop: the socket's data events feed a frame parser,
// and a message, a ping or a close reaches the page as it arrives. The API follows the WebSocket
// standard: opening, open, message, error and close events; text and binary frames, split into
// fragments by the sender or not; ping answered with pong; close codes and reasons; subprotocols;
// bufferedAmount; and binaryType choosing a Blob or an ArrayBuffer for binary messages.

import { createHash, randomBytes } from "node:crypto";
import { request as httpRequest } from "node:http";
import type { ClientRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { Event, MessageEvent } from "./dom.ts";
import { plainBytes } from "./bytes.ts";

const CONNECTING = 0;
const OPEN = 1;
const CLOSING = 2;
const CLOSED = 3;

/** The GUID the handshake's Sec-WebSocket-Accept hashes the key with (RFC 6455 §1.3). */
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** How long a close handshake waits for the server before the socket is dropped, in ms. */
const CLOSE_TIMEOUT = 10000;

/** A URL the page gave the constructor, split into the pieces the request needs. */
interface Endpoint {
  secure: boolean;
  host: string;
  port: number;
  /** The path and query the request asks for, starting with "/". */
  path: string;
  /** The URL as the WebSocket object reports it. */
  url: string;
  /** scheme://host[:port], the message events' origin. */
  origin: string;
}

/** Parses a ws: or wss: URL; null when it isn't one WebSocket can open. */
function parseEndpoint(input: string): Endpoint | null {
  let text = input.trim();
  const hash = text.indexOf("#");
  // A URL with a fragment is refused, as the WebSocket standard says.
  if (hash >= 0) return null;
  const m = /^(wss?):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?$/i.exec(text);
  if (m === null) return null;
  const secure = m[1].toLowerCase() === "wss";
  const authority = m[2];
  if (authority === "") return null;
  // A user name or password in the URL isn't part of a WebSocket connection.
  if (authority.indexOf("@") >= 0) return null;
  let host = authority;
  let port = secure ? 443 : 80;
  if (authority.startsWith("[")) {
    // An IPv6 literal: [addr] or [addr]:port.
    const close = authority.indexOf("]");
    if (close < 0) return null;
    host = authority.slice(0, close + 1);
    const rest = authority.slice(close + 1);
    if (rest !== "") {
      if (!rest.startsWith(":")) return null;
      const n = Number(rest.slice(1));
      if (rest.length < 2 || !isFinite(n) || n <= 0 || n > 65535) return null;
      port = n;
    }
  } else {
    const colon = authority.lastIndexOf(":");
    if (colon >= 0) {
      const n = Number(authority.slice(colon + 1));
      if (colon === authority.length - 1 || !isFinite(n) || n <= 0 || n > 65535) return null;
      host = authority.slice(0, colon);
      port = n;
    }
    if (host === "") return null;
  }
  const path = (m[3] === "" ? "/" : m[3]) + (m[4] === undefined ? "" : m[4]);
  const shownHost = host.indexOf(":") >= 0 && !host.startsWith("[") ? "[" + host + "]" : host;
  const defaultPort = secure ? 443 : 80;
  const shownPort = port === defaultPort ? "" : ":" + port;
  const origin = (secure ? "wss://" : "ws://") + shownHost + shownPort;
  return { secure, host: host.startsWith("[") ? host.slice(1, host.length - 1) : host, port, path, url: origin + path, origin };
}

/** A subprotocol must be an HTTP token, as the standard's grammar has it. */
const TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

/** The bytes of a string in UTF-8. */
function utf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/** Bytes as base64. */
function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

/** Four bytes of mask for a client frame. */
function maskBytes(): Uint8Array {
  const buf = randomBytes(4);
  const out = new Uint8Array(4);
  for (let i = 0; i < 4; i++) out[i] = buf[i];
  return out;
}

/** One frame: its header and payload, masked as a client's frames must be. */
function encodeFrame(opcode: number, payload: Uint8Array, fin: boolean): Uint8Array {
  const len = payload.length;
  const headLen = len < 126 ? 2 : len < 65536 ? 4 : 10;
  const frame = new Uint8Array(headLen + 4 + len);
  frame[0] = (fin ? 0x80 : 0x00) | opcode;
  if (len < 126) {
    frame[1] = 0x80 | len;
  } else if (len < 65536) {
    frame[1] = 0x80 | 126;
    frame[2] = (len >>> 8) & 0xff;
    frame[3] = len & 0xff;
  } else {
    frame[1] = 0x80 | 127;
    let n = len;
    for (let i = 0; i < 8; i++) {
      frame[9 - i] = n % 256;
      n = Math.floor(n / 256);
    }
  }
  const mask = maskBytes();
  for (let i = 0; i < 4; i++) frame[headLen + i] = mask[i];
  for (let i = 0; i < len; i++) frame[headLen + 4 + i] = payload[i] ^ mask[i & 3];
  return frame;
}

/** Finishes a fragmented message's payload from its pieces. */
function concat(parts: Uint8Array[], size: number): Uint8Array {
  const out = new Uint8Array(size);
  let at = 0;
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    for (let j = 0; j < part.length; j++) out[at++] = part[j];
  }
  return out;
}

/** The close event a connection dispatches. */
export class CloseEvent extends Event {
  get [Symbol.toStringTag](): string { return "CloseEvent"; }
  readonly code: number;
  readonly reason: string;
  readonly wasClean: boolean;
  constructor(...args: any[]) {
    super(args[0] === undefined ? "" : args[0]);
    const init = (args[1] === undefined ? {} : args[1]) as { code?: number; reason?: string; wasClean?: boolean };
    this.code = init.code === undefined ? 0 : init.code;
    this.reason = init.reason === undefined ? "" : init.reason;
    this.wasClean = init.wasClean === true;
  }
}

/** One piece of work a send queued: bytes ready to write, or a Blob still being read. */
interface SendTask {
  bytes: Uint8Array | null;
  blob: any;
  size: number;
  opcode: number;
}

/** Whether a close code may be sent by an application (RFC 6455 §7.4.1 and the WebSocket API). */
function validCloseCode(code: number): boolean {
  if (code === 1000 || (code >= 3000 && code <= 4999)) return true;
  return false;
}

/**
 * Whether a close code is one a peer may send on the wire. 1004, 1005, 1006 and 1015 are reserved
 * for the protocol itself and may not appear in a close frame.
 */
function sendableCloseCode(code: number): boolean {
  if (code >= 1000 && code <= 1003) return true;
  if (code >= 1007 && code <= 1014) return true;
  if (code >= 3000 && code <= 4999) return true;
  return false;
}

/** The UTF-8 text of bytes, or null when they aren't valid UTF-8. */
function decodeText(bytes: Uint8Array): string | null {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch (e) {
    return null;
  }
}

export class WebSocket {
  get [Symbol.toStringTag](): string { return "WebSocket"; }
  static readonly CONNECTING = CONNECTING;
  static readonly OPEN = OPEN;
  static readonly CLOSING = CLOSING;
  static readonly CLOSED = CLOSED;

  readonly CONNECTING = CONNECTING;
  readonly OPEN = OPEN;
  readonly CLOSING = CLOSING;
  readonly CLOSED = CLOSED;

  readonly url: string;
  protocol: string = "";
  readonly extensions: string = "";

  readyState: number = CONNECTING;

  onopen: ((event: any) => void) | null = null;
  onmessage: ((event: any) => void) | null = null;
  onerror: ((event: any) => void) | null = null;
  onclose: ((event: any) => void) | null = null;

  private listeners: { type: string; fn: (event: any) => void }[] = [];
  /** The key the client sent, checked against the accept the server answers with. */
  private key: string = "";
  private endpoint: Endpoint | null;
  private protocols: string[] = [];
  private socket: any = null;

  /** Bytes received that don't yet make a whole frame. */
  private buffer: Uint8Array = new Uint8Array(0);
  /** The fragmented message being assembled, and its pieces. */
  private fragmentOpcode: number = -1;
  private fragments: Uint8Array[] = [];
  private fragmentSize: number = 0;
  private closeTimer: ReturnType<typeof setTimeout> | null = null;
  /** Whether the connection has already reported its close. */
  private done: boolean = false;
  /** Sends waiting for their turn, so a Blob read doesn't reorder the frames after it. */
  private tasks: SendTask[] = [];
  private flushing: boolean = false;
  /** Payload bytes queued but not yet written. */
  private queued: number = 0;
  private binary: string = "blob";

  constructor(url: string, protocols?: any) {
    const source = String(url);
    this.url = source;
    this.endpoint = parseEndpoint(source);
    if (this.endpoint === null) {
      throw new Error("SyntaxError: Failed to construct 'WebSocket': The URL '" + source + "' is invalid.");
    }
    this.url = this.endpoint.url;
    if (protocols !== undefined && protocols !== null) {
      if (typeof protocols === "string") {
        this.protocols.push(protocols);
      } else if (typeof protocols === "object" && typeof (protocols as any).length === "number") {
        const list = protocols as any[];
        for (let i = 0; i < list.length; i++) this.protocols.push(String(list[i]));
      }
    }
    for (let i = 0; i < this.protocols.length; i++) {
      const p = this.protocols[i];
      if (!TOKEN.test(p)) {
        throw new Error("SyntaxError: Failed to construct 'WebSocket': The subprotocol '" + p + "' is invalid.");
      }
      for (let j = 0; j < i; j++) {
        if (this.protocols[j] === p) {
          throw new Error("SyntaxError: Failed to construct 'WebSocket': The subprotocol '" + p + "' is duplicated.");
        }
      }
    }
    this.connect();
  }

  get bufferedAmount(): number {
    return this.queued;
  }

  get binaryType(): string {
    return this.binary;
  }

  set binaryType(value: string) {
    if (value === "blob" || value === "arraybuffer") this.binary = value;
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

  send(data: any): void {
    if (this.readyState === CONNECTING) {
      throw new Error("InvalidStateError: Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.");
    }
    if (this.readyState !== OPEN) return;
    if (typeof data === "string") {
      const bytes = utf8(data);
      this.enqueue(0x1, bytes, null, bytes.length);
    } else if (data instanceof Blob) {
      this.enqueue(0x2, null, data, data.size);
    } else if (data instanceof ArrayBuffer) {
      const bytes = new Uint8Array(data);
      this.enqueue(0x2, bytes, null, bytes.length);
    } else if (data !== null && data !== undefined && typeof (data as any).byteLength === "number"
      && typeof (data as any).buffer === "object") {
      // A typed array or DataView: its bytes, without the rest of the buffer it sits in.
      const view = data as ArrayBufferView;
      const bytes = new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
      const copy = new Uint8Array(bytes.length);
      for (let i = 0; i < bytes.length; i++) copy[i] = bytes[i];
      this.enqueue(0x2, copy, null, copy.length);
    } else {
      // Anything else is sent as its text, as a browser's send() does.
      const bytes = utf8(String(data));
      this.enqueue(0x1, bytes, null, bytes.length);
    }
  }

  close(code?: number, reason?: string): void {
    if (code !== undefined && !validCloseCode(code)) {
      throw new Error("InvalidAccessError: Failed to execute 'close' on 'WebSocket': The close code must be "
        + "1000 or in the range 3000 to 4999.");
    }
    const why = reason === undefined ? "" : String(reason);
    if (utf8(why).length > 123) {
      throw new Error("SyntaxError: Failed to execute 'close' on 'WebSocket': The close reason must not be "
        + "longer than 123 bytes of UTF-8.");
    }
    if (this.readyState === CLOSING || this.readyState === CLOSED) return;
    if (this.readyState === CONNECTING) {
      // A connection that never opened has no close handshake to run: it fails, as a browser's does.
      this.fail("", 1006);
      return;
    }
    this.sendCloseFrame(code === undefined ? 1005 : code, why);
    this.readyState = CLOSING;
    this.armCloseTimer();
  }

  // -------------------------------------------------------------------------
  // Connecting

  private connect(): void {
    const ep = this.endpoint;
    if (ep === null) return;
    this.key = base64(new Uint8Array(randomBytes(16)));
    const headers: { [name: string]: string } = {
      "Connection": "Upgrade",
      "Upgrade": "websocket",
      "Sec-WebSocket-Version": "13",
      "Sec-WebSocket-Key": this.key,
    };
    if (this.protocols.length > 0) headers["Sec-WebSocket-Protocol"] = this.protocols.join(", ");
    const options = { host: ep.host, port: ep.port, path: ep.path, headers };
    let req: ClientRequest;
    try {
      req = ep.secure ? httpsRequest(options) : httpRequest(options);
    } catch (e) {
      this.fail("", 1006);
      return;
    }
    req.on("upgrade", (res: any, socket: any, head: any) => this.upgraded(res, socket, head));
    req.on("response", (res: any) => {
      // A server that doesn't switch protocols answers with an ordinary response.
      void res;
      this.fail("", 1006);
    });
    req.on("error", (e: any) => {
      void e;
      if (!this.done) this.fail("", 1006);
    });
    req.end();
  }

  private upgraded(res: any, socket: any, head: any): void {
    if (this.done) return;
    const headers = res !== null && res.headers !== null && res.headers !== undefined ? res.headers : {};
    const accept = headers["sec-websocket-accept"];
    const expected = createHash("sha1").update(this.key + GUID).digest("base64");
    const upgrade = String(headers["upgrade"] === undefined ? "" : headers["upgrade"]).toLowerCase();
    const connection = String(headers["connection"] === undefined ? "" : headers["connection"]).toLowerCase();
    const picked = headers["sec-websocket-protocol"];
    let protocolOk = true;
    if (picked !== undefined) {
      protocolOk = this.protocols.indexOf(String(picked)) >= 0;
    }
    if (res.statusCode !== 101 || upgrade !== "websocket" || connection.indexOf("upgrade") < 0
      || accept !== expected || !protocolOk) {
      try { socket.destroy(); } catch (e) { void e; }
      this.fail("", 1006);
      return;
    }
    if (picked !== undefined) this.protocol = String(picked);
    this.socket = socket;
    this.readyState = OPEN;
    socket.on("data", (chunk: Uint8Array) => this.received(chunk));
    socket.on("error", (e: any) => {
      void e;
      if (!this.done) this.abnormal("", 1006);
    });
    socket.on("close", () => {
      if (!this.done) this.abnormal("", 1006);
    });
    this.dispatchEvent(new Event("open"));
    // Bytes that arrived with the 101 are the first frames.
    if (head !== null && head !== undefined && head.length > 0) this.received(head);
    this.flush();
  }

  // -------------------------------------------------------------------------
  // Sending

  private enqueue(opcode: number, bytes: Uint8Array | null, blob: any, size: number): void {
    this.tasks.push({ bytes, blob, size, opcode });
    this.queued += size;
    this.flush();
  }

  private flush(): void {
    if (this.flushing) return;
    this.flushing = true;
    while (this.tasks.length > 0) {
      const task = this.tasks[0];
      if (task.bytes === null) {
        // A Blob is read first, and the frames behind it wait so the order is the page's.
        const blob = task.blob;
        task.blob = null;
        this.flushing = false;
        blob.arrayBuffer().then((ab: ArrayBuffer) => {
          const bytes = new Uint8Array(ab);
          task.bytes = bytes;
          this.flush();
        }).catch((e: any) => {
          void e;
          this.tasks.shift();
          this.flushing = false;
          this.flush();
        });
        return;
      }
      this.tasks.shift();
      this.writeFrame(task.opcode, task.bytes);
      this.queued -= task.size;
      if (this.queued < 0) this.queued = 0;
    }
    this.flushing = false;
  }

  private writeFrame(opcode: number, payload: Uint8Array): void {
    const socket = this.socket;
    if (socket === null || this.readyState === CLOSED) return;
    try {
      socket.write(encodeFrame(opcode, payload, true));
    } catch (e) {
      void e;
    }
  }

  private sendCloseFrame(code: number, reason: string): void {
    if (code === 1005) {
      this.writeFrame(0x8, new Uint8Array(0));
      return;
    }
    const why = utf8(reason);
    const payload = new Uint8Array(2 + why.length);
    payload[0] = (code >>> 8) & 0xff;
    payload[1] = code & 0xff;
    for (let i = 0; i < why.length; i++) payload[2 + i] = why[i];
    this.writeFrame(0x8, payload);
  }

  // -------------------------------------------------------------------------
  // Receiving

  private received(chunk: Uint8Array): void {
    if (this.done) return;
    const joined = new Uint8Array(this.buffer.length + chunk.length);
    for (let i = 0; i < this.buffer.length; i++) joined[i] = this.buffer[i];
    for (let i = 0; i < chunk.length; i++) joined[this.buffer.length + i] = chunk[i];
    let start = 0;
    while (true) {
      const frame = this.parseFrame(joined, start);
      if (frame === null) break;
      start = frame.end;
      if (!this.frame(frame.opcode, frame.payload, frame.fin)) {
        // The frame failed the connection; nothing after it is read.
        start = joined.length;
        break;
      }
    }
    const rest = joined.length - start;
    this.buffer = new Uint8Array(rest);
    for (let i = 0; i < rest; i++) this.buffer[i] = joined[start + i];
  }

  /** One frame at `start`, or null when the bytes don't hold a whole one yet. */
  private parseFrame(bytes: Uint8Array, start: number): { fin: boolean; opcode: number; payload: Uint8Array; end: number } | null {
    if (bytes.length - start < 2) return null;
    const b0 = bytes[start];
    const b1 = bytes[start + 1];
    const fin = (b0 & 0x80) !== 0;
    const rsv = b0 & 0x70;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let len = b1 & 0x7f;
    let at = start + 2;
    if (len === 126) {
      if (bytes.length - at < 2) return null;
      len = (bytes[at] << 8) | bytes[at + 1];
      at += 2;
    } else if (len === 127) {
      if (bytes.length - at < 8) return null;
      // A length above 2^53 can't be buffered here, and no server sends one.
      let big = 0;
      for (let i = 0; i < 8; i++) big = big * 256 + bytes[at + i];
      if (big > 9007199254740991) {
        this.fail("", 1009);
        return null;
      }
      len = big;
      at += 8;
    }
    if (masked) {
      // A server's frames must not be masked.
      this.fail("", 1002);
      return null;
    }
    if (rsv !== 0) {
      // No extension was negotiated, so no reserved bit may be set.
      this.fail("", 1002);
      return null;
    }
    if (opcode >= 0x8) {
      if (!fin || len > 125) {
        this.fail("", 1002);
        return null;
      }
    }
    if (bytes.length - at < len) return null;
    const payload = new Uint8Array(len);
    for (let i = 0; i < len; i++) payload[i] = bytes[at + i];
    return { fin, opcode, payload, end: at + len };
  }

  /** Handles one frame; false when it failed the connection. */
  private frame(opcode: number, payload: Uint8Array, fin: boolean): boolean {
    if (opcode === 0x8) {
      this.closeFromServer(payload);
      return false;
    }
    if (opcode === 0x9) {
      if (this.readyState === OPEN) this.writeFrame(0xA, payload);
      return true;
    }
    if (opcode === 0xA) return true;
    if (opcode === 0x1 || opcode === 0x2) {
      if (this.fragmentOpcode !== -1) {
        this.fail("", 1002);
        return false;
      }
      if (fin) {
        this.message(opcode, payload);
        return true;
      }
      this.fragmentOpcode = opcode;
      this.fragments = [payload];
      this.fragmentSize = payload.length;
      return true;
    }
    if (opcode === 0x0) {
      if (this.fragmentOpcode === -1) {
        this.fail("", 1002);
        return false;
      }
      this.fragments.push(payload);
      this.fragmentSize += payload.length;
      if (!fin) return true;
      const whole = concat(this.fragments, this.fragmentSize);
      const kind = this.fragmentOpcode;
      this.fragmentOpcode = -1;
      this.fragments = [];
      this.fragmentSize = 0;
      this.message(kind, whole);
      return true;
    }
    this.fail("", 1002);
    return false;
  }

  /** Delivers a whole message of the given opcode. */
  private message(opcode: number, bytes: Uint8Array): void {
    if (opcode === 0x1) {
      const text = decodeText(bytes);
      if (text === null) {
        this.fail("", 1007);
        return;
      }
      this.dispatchEvent(new MessageEvent("message", { data: text, origin: this.endpoint === null ? "" : this.endpoint.origin }));
      return;
    }
    const data = this.binary === "arraybuffer" ? plainArrayBuffer(bytes) : new Blob([plainBytes(bytes)], { type: "" });
    this.dispatchEvent(new MessageEvent("message", { data, origin: this.endpoint === null ? "" : this.endpoint.origin }));
  }

  // -------------------------------------------------------------------------
  // Closing

  /** The server sent a close frame: finish the handshake and report it. */
  private closeFromServer(payload: Uint8Array): void {
    let code = 1005;
    let reason = "";
    if (payload.length === 1) {
      this.fail("", 1002);
      return;
    }
    if (payload.length >= 2) {
      code = (payload[0] << 8) | payload[1];
      const whyText = new Uint8Array(payload.length - 2);
      for (let i = 2; i < payload.length; i++) whyText[i - 2] = payload[i];
      const why = decodeText(whyText);
      if (why === null) {
        this.fail("", 1007);
        return;
      }
      reason = why;
      if (!sendableCloseCode(code)) {
        this.fail("", 1002);
        return;
      }
    }
    if (this.readyState !== CLOSING) this.sendCloseFrame(code === 1005 ? 1005 : code, "");
    this.finish(code, reason, true);
  }

  private armCloseTimer(): void {
    if (this.closeTimer !== null) return;
    this.closeTimer = setTimeout(() => {
      this.closeTimer = null;
      // A server that never answers the close handshake leaves an abnormal closure.
      this.abnormal("", 1006);
    }, CLOSE_TIMEOUT);
  }

  /** Reports an event with no close handshake: an error, then a 1006 close. */
  private abnormal(message: string, code: number): void {
    if (this.done) return;
    this.dispatchEvent(new Event("error"));
    this.finish(code, message, false);
  }

  /** Fails the connection now: a close frame naming the protocol problem for the server, then an
   *  error and a 1006 close, as a browser reports a connection it failed itself. */
  private fail(message: string, code: number): void {
    if (this.done) return;
    if (this.socket !== null && this.readyState === OPEN && code !== 1006) this.sendCloseFrame(code, "");
    if (this.socket !== null) {
      try { this.socket.destroy(); } catch (e) { void e; }
    }
    this.abnormal(message, 1006);
  }

  /**
   * Reports the close once. A connection that never opened reports it a turn later, as a browser
   * does, so a listener added just after the constructor still hears it.
   */
  private finish(code: number, reason: string, wasClean: boolean): void {
    if (this.done) return;
    this.done = true;
    this.readyState = CLOSED;
    if (this.closeTimer !== null) {
      clearTimeout(this.closeTimer);
      this.closeTimer = null;
    }
    const socket = this.socket;
    this.socket = null;
    if (socket !== null) {
      try { socket.destroy(); } catch (e) { void e; }
    }
    this.queued = 0;
    this.tasks = [];
    this.dispatchEvent(new CloseEvent("close", { code, reason, wasClean }));
  }
}

/** The bytes of a typed array as an ArrayBuffer of their own. */
function plainArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new ArrayBuffer(bytes.length);
  const out = new Uint8Array(copy);
  for (let i = 0; i < bytes.length; i++) out[i] = bytes[i];
  return copy;
}
