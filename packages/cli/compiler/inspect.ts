// The dev inspector's server: a page and a Chrome DevTools Protocol subset served on a local
// port, over data the running app answers for. `native dev --inspect` starts it; the app and the
// server share the build's `.native/inspect` directory (see runtime/app/inspect.ts).

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { IncomingMessage, Server, ServerResponse } from "node:http";
import type { Socket } from "node:net";
import { join } from "node:path";
import { constants as vmConstants, createContext, runInContext } from "node:vm";
import { INSPECT_HTML } from "./inspect-ui.ts";

/** One console line the app printed, or an exception the runtime reported. */
interface ConsoleLine {
  level: string;
  text: string;
  at: number;
}

/** What the app's snapshot puts on the wire. */
interface Snapshot {
  title: string;
  width: number;
  height: number;
  time: number;
  root: number;
  nodes: SnapshotNode[];
  layers: { id: number; depth: number; reason: string; zIndex: number; name: string; rect: number[] }[];
  frames: { frame: number; style: number; anim: number; layout: number; paint: number; total: number }[];
}

interface SnapshotNode {
  id: number;
  parent: number;
  type: number;
  name: string;
  attrs: string[][];
  text: string;
  pseudo: string | null;
  rect: number[] | null;
  box: { margin: number[]; border: number[]; padding: number[] } | null;
  scroll: { top: number; left: number; width: number; height: number; clientWidth: number; clientHeight: number } | null;
  styles: { [name: string]: string };
  pseudos: string[];
  children: number[];
}

/** A WebSocket client, with just the framing the inspector needs. */
class Client {
  readonly socket: Socket;
  private buffer = Buffer.alloc(0);
  private fragment: Buffer | null = null;
  private fragmentOpcode = 0;
  open = true;

  constructor(socket: Socket) {
    this.socket = socket;
    socket.on("data", (chunk: Buffer) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.read();
    });
    socket.on("close", () => {
      this.open = false;
    });
    socket.on("error", () => {
      this.open = false;
    });
  }

  private read(): void {
    for (;;) {
      if (this.buffer.length < 2) return;
      const b0 = this.buffer[0];
      const b1 = this.buffer[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let length = b1 & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        length = Number(this.buffer.readBigUInt64BE(2));
        offset = 10;
      }
      const maskOffset = offset;
      if (masked) offset += 4;
      if (this.buffer.length < offset + length) return;
      const payload = Buffer.from(this.buffer.subarray(offset, offset + length));
      if (masked) {
        for (let i = 0; i < payload.length; i++) payload[i] ^= this.buffer[maskOffset + (i % 4)];
      }
      this.buffer = this.buffer.subarray(offset + length);
      if (opcode === 0x8) {
        this.open = false;
        this.socket.end();
        return;
      }
      if (opcode === 0x9) {
        this.frame(0xa, payload);
        continue;
      }
      if (opcode === 0xa) continue;
      if (opcode === 0x0 && this.fragment !== null) {
        this.fragment = Buffer.concat([this.fragment, payload]);
        if (!fin) continue;
        const whole = this.fragment;
        this.fragment = null;
        if (this.fragmentOpcode === 0x1) this.onText(whole.toString("utf8"));
        continue;
      }
      if (!fin) {
        this.fragment = payload;
        this.fragmentOpcode = opcode;
        continue;
      }
      if (opcode === 0x1) this.onText(payload.toString("utf8"));
    }
  }

  frame(opcode: number, payload: Buffer): void {
    if (!this.open) return;
    const length = payload.length;
    let header: Buffer;
    if (length < 126) {
      header = Buffer.alloc(2);
      header[1] = length;
    } else if (length < 65536) {
      header = Buffer.alloc(4);
      header[1] = 126;
      header.writeUInt16BE(length, 2);
    } else {
      header = Buffer.alloc(10);
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(length), 2);
    }
    header[0] = 0x80 | opcode;
    this.socket.write(Buffer.concat([header, payload]));
  }

  send(message: unknown): void {
    this.frame(0x1, Buffer.from(JSON.stringify(message)));
  }

  /** What the server does with a client's message; the inspector sets it. */
  onText: (text: string) => void = () => {};
}

export interface InspectorOptions {
  appDir: string;
  buildDir: string;
  port: number;
}

export interface Inspector {
  url: string;
  /** Adds a line the app printed, for the console panel and the CDP events. */
  log(stream: "stdout" | "stderr", line: string): void;
  close(): void;
}

/** A request to the app, answered when its response file appears. */
class RuntimeChannel {
  private readonly dir: string;
  private next = 1;

  constructor(dir: string) {
    this.dir = dir;
    mkdirSync(dir, { recursive: true });
  }

  request(op: string, params: { [key: string]: unknown } = {}, timeoutMs = 3000): Promise<unknown> {
    const id = this.next++;
    const file = join(this.dir, `req-${id}.json`);
    const tmp = file + ".tmp";
    writeFileSync(tmp, JSON.stringify({ id, op, ...params }));
    renameSync(tmp, file);
    return new Promise((resolve, reject) => {
      const started = Date.now();
      const poll = (): void => {
        const answer = join(this.dir, `res-${id}.json`);
        if (existsSync(answer)) {
          try {
            const body = JSON.parse(readFileSync(answer, "utf8")) as { ok: boolean; result: unknown };
            rmSync(answer, { force: true });
            if (body.ok) resolve(body.result);
            else reject(new Error(String(body.result)));
          } catch (err) {
            reject(err instanceof Error ? err : new Error(String(err)));
          }
          return;
        }
        if (Date.now() - started > timeoutMs) {
          rmSync(file, { force: true });
          reject(new Error(`the app did not answer '${op}'`));
          return;
        }
        setTimeout(poll, 10);
      };
      poll();
    });
  }
}

/** The node a snapshot id names, for the CDP commands that take one. */
function nodeById(snapshot: Snapshot, nodeId: number): SnapshotNode | null {
  for (const node of snapshot.nodes) if (node.id === nodeId) return node;
  return null;
}

/** A snapshot node as the DevTools Protocol's DOM.Node. */
function cdpNode(snapshot: Snapshot, node: SnapshotNode, depth: number): { [key: string]: unknown } {
  const children = node.children
    .map((id) => nodeById(snapshot, id))
    .filter((child): child is SnapshotNode => child !== null);
  const out: { [key: string]: unknown } = {
    nodeId: node.id,
    backendNodeId: node.id,
    nodeType: node.type,
    nodeName: node.type === 1 ? node.name.toUpperCase() : node.name,
    localName: node.type === 1 ? node.name : "",
    nodeValue: node.text,
    childNodeCount: children.length,
    attributes: node.attrs.flat(),
  };
  if (depth !== 0 && children.length > 0) out.children = children.map((child) => cdpNode(snapshot, child, depth - 1));
  return out;
}

/** A quad of the four corners the protocol's box model uses. */
function quad(x: number, y: number, w: number, h: number): number[] {
  return [x, y, x + w, y, x + w, y + h, x, y + h];
}

/** The protocol's box model for a node: content, padding, border and margin quads. */
function boxModel(node: SnapshotNode): { [key: string]: unknown } | null {
  if (node.rect === null || node.box === null) return null;
  const [x, y, w, h] = node.rect;
  const border = node.box.border;
  const padding = node.box.padding;
  const margin = node.box.margin;
  const bx = x;
  const by = y;
  const bw = w;
  const bh = h;
  const px0 = bx + border[3];
  const py0 = by + border[0];
  const pw = Math.max(0, bw - border[1] - border[3]);
  const ph = Math.max(0, bh - border[0] - border[2]);
  const cx0 = px0 + padding[3];
  const cy0 = py0 + padding[0];
  const cw = Math.max(0, pw - padding[1] - padding[3]);
  const ch = Math.max(0, ph - padding[0] - padding[2]);
  return {
    content: quad(cx0, cy0, cw, ch),
    padding: quad(px0, py0, pw, ph),
    border: quad(bx, by, bw, bh),
    margin: quad(bx - margin[3], by - margin[0], bw + margin[1] + margin[3], bh + margin[0] + margin[2]),
    width: cw,
    height: ch,
  };
}

/**
 * The console's globals, built inside the evaluated context from the snapshot's JSON.
 *
 * Nothing from the host's realm is handed to the context: the snapshot arrives as a JSON string
 * that is parsed inside the context, and every function the expression can reach (the DOM views,
 * `getComputedStyle`, `console`, the result formatter) is created inside the context. Expressions
 * therefore run with the context's own intrinsics, so `this.constructor.constructor('return
 * process')()` builds a function in that empty realm and reaches nothing of the host's.
 */
const INSPECT_CONSOLE = String.raw`
function (jsonText) {
  "use strict";
  var stringify = JSON.stringify;
  var evaluateIndirectly = eval;
  var data = JSON.parse(jsonText);
  var byId = new Map();
  for (var i = 0; i < data.nodes.length; i++) byId.set(data.nodes[i].id, data.nodes[i]);
  var mirror = new Map();
  var logs = [];
  function attr(node, name) {
    for (var i = 0; i < node.attrs.length; i++) if (node.attrs[i][0] === name) return node.attrs[i][1];
    return null;
  }
  function textOf(node) {
    if (node.type === 3 || node.type === 8) return node.text;
    var text = "";
    for (var i = 0; i < node.children.length; i++) {
      var child = byId.get(node.children[i]);
      if (child !== undefined) text += textOf(child);
    }
    return text;
  }
  function matches(node, selector) {
    var s = selector.trim();
    if (s.charAt(0) === "#") return attr(node, "id") === s.slice(1);
    if (s.charAt(0) === ".") {
      var cls = attr(node, "class");
      return cls !== null && cls.split(/\s+/).indexOf(s.slice(1)) >= 0;
    }
    return node.name === s.toLowerCase() || (s === "*" && node.type === 1);
  }
  function collect(node, type) {
    var out = [];
    for (var i = 0; i < node.children.length; i++) {
      var child = byId.get(node.children[i]);
      if (child !== undefined && (type === undefined || child.type === type)) out.push(view(child));
    }
    return out;
  }
  function queryAll(node, selector) {
    var out = [];
    function walk(current) {
      for (var i = 0; i < current.children.length; i++) {
        var child = byId.get(current.children[i]);
        if (child === undefined) continue;
        if (child.type === 1 && matches(child, selector)) out.push(view(child));
        walk(child);
      }
    }
    walk(node);
    return out;
  }
  function view(node) {
    var known = mirror.get(node.id);
    if (known !== undefined) return known;
    var el = {
      nodeId: node.id,
      nodeType: node.type,
      nodeName: node.type === 1 ? node.name.toUpperCase() : node.name,
      localName: node.name,
      id: attr(node, "id") === null ? "" : attr(node, "id"),
      className: attr(node, "class") === null ? "" : attr(node, "class"),
      getAttribute: function (name) { return attr(node, name); },
      getBoundingClientRect: function () {
        var r = node.rect === null ? [0, 0, 0, 0] : node.rect;
        return { x: r[0], y: r[1], left: r[0], top: r[1], width: r[2], height: r[3],
          right: r[0] + r[2], bottom: r[1] + r[3] };
      },
      querySelector: function (selector) { var found = queryAll(node, selector); return found.length === 0 ? null : found[0]; },
      querySelectorAll: function (selector) { return queryAll(node, selector); },
      matches: function (selector) { return matches(node, selector); }
    };
    Object.defineProperty(el, "textContent", { get: function () { return textOf(node); } });
    Object.defineProperty(el, "childNodes", { get: function () { return collect(node); } });
    Object.defineProperty(el, "children", { get: function () { return collect(node, 1); } });
    Object.defineProperty(el, "parentNode", { get: function () {
      var p = byId.get(node.parent);
      return p === undefined ? null : view(p);
    } });
    Object.defineProperty(el, "parentElement", { get: function () {
      var p = byId.get(node.parent);
      return p !== undefined && p.type === 1 ? view(p) : null;
    } });
    mirror.set(node.id, el);
    return el;
  }
  var root = byId.get(data.root);
  var documentView = root === undefined ? {} : view(root);
  var html = undefined;
  var body = undefined;
  for (var i = 0; i < data.nodes.length; i++) {
    if (root !== undefined && html === undefined && data.nodes[i].parent === root.id && data.nodes[i].type === 1) html = data.nodes[i];
    if (body === undefined && data.nodes[i].name === "body") body = data.nodes[i];
  }
  documentView.title = data.title;
  documentView.documentElement = html === undefined ? null : view(html);
  documentView.body = body === undefined ? null : view(body);
  documentView.getElementById = function (id) {
    for (var i = 0; i < data.nodes.length; i++)
      if (data.nodes[i].type === 1 && attr(data.nodes[i], "id") === id) return view(data.nodes[i]);
    return null;
  };
  documentView.querySelector = function (selector) {
    for (var i = 0; i < data.nodes.length; i++)
      if (data.nodes[i].type === 1 && matches(data.nodes[i], selector)) return view(data.nodes[i]);
    return null;
  };
  documentView.querySelectorAll = function (selector) {
    var out = [];
    for (var i = 0; i < data.nodes.length; i++)
      if (data.nodes[i].type === 1 && matches(data.nodes[i], selector)) out.push(view(data.nodes[i]));
    return out;
  };
  globalThis.document = documentView;
  globalThis.getComputedStyle = function (el) {
    var id = typeof el === "object" && el !== null && "nodeId" in el ? Number(el.nodeId) : -1;
    var node = byId.get(id);
    return { getPropertyValue: function (name) { return node === undefined ? "" : node.styles[name] ?? ""; } };
  };
  globalThis.console = {
    log: function () { logs.push({ level: "log", text: Array.prototype.map.call(arguments, String).join(" ") }); },
    warn: function () { logs.push({ level: "warn", text: Array.prototype.map.call(arguments, String).join(" ") }); },
    error: function () { logs.push({ level: "error", text: Array.prototype.map.call(arguments, String).join(" ") }); }
  };
  function describe(value) {
    if (value === null) return { type: "object", subtype: "null", value: null };
    if (value === undefined) return { type: "undefined" };
    var type = typeof value;
    if (type === "string" || type === "number" || type === "boolean") return { type: type, value: value };
    if (type === "function") return { type: "function", description: String(value) };
    try {
      var json = stringify(value);
      return { type: "object", value: json === undefined ? String(value) : JSON.parse(json) };
    } catch (e) {
      return { type: "object", description: String(value) };
    }
  }
  var lastThenable = null;
  function errorText(reason) {
    if (typeof reason === "object" && reason !== null) {
      try {
        if (reason.code === "ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING" || reason.code === "ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING_FLAG") {
          return "import() is not available in the inspector console";
        }
        if (typeof reason.message === "string") return reason.message;
      } catch (e) {
        // A reason whose getters throw falls through to String().
      }
    }
    return String(reason);
  }
  globalThis.__inspectRun = function (source) {
    var value;
    lastThenable = null;
    try {
      value = (0, evaluateIndirectly)(source);
    } catch (err) {
      return stringify({ exception: errorText(err) });
    }
    if (value !== null && (typeof value === "object" || typeof value === "function")) {
      var then = null;
      try { then = value.then; } catch (e) { then = null; }
      if (typeof then === "function") {
        // A promise the expression leaves behind must not become an unhandled rejection: a
        // handler keeps it off the dev process, and the console reports its rejection instead.
        var state = { settled: false, error: null };
        lastThenable = state;
        try {
          then.call(value, undefined, function (reason) {
            state.settled = true;
            state.error = errorText(reason);
          });
        } catch (e) {
          state.settled = true;
          state.error = errorText(e);
        }
      }
    }
    return stringify({ value: describe(value) });
  };
  globalThis.__inspectThenable = function () {
    return lastThenable === null ? "null" : stringify(lastThenable);
  };
  globalThis.__inspectLogs = function () { return stringify(logs); };
}`;

/** Whether a Host header names the loopback interface the inspector listens on. */
function isInspectorHost(host: string, port: number): boolean {
  return host === `127.0.0.1:${port}` || host === `localhost:${port}` || host === `[::1]:${port}`;
}

/** Whether an Origin header is the inspector's own; a page it serves has one of these. */
function isInspectorOrigin(origin: string, port: number): boolean {
  return origin === `http://127.0.0.1:${port}` || origin === `http://localhost:${port}` ||
    origin === `http://[::1]:${port}`;
}

/** Compares the token a request carries with the session's, without an early exit on a mismatch. */
function isSameToken(given: string | undefined, token: string): boolean {
  if (given === undefined || given.length === 0) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** A rejection reason as text; a dynamic import is named for what it is. */
function rejectionMessage(reason: unknown): string {
  if (typeof reason === "object" && reason !== null) {
    try {
      const code = (reason as { code?: unknown }).code;
      if (code === "ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING" || code === "ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING_FLAG") {
        return "import() is not available in the inspector console";
      }
      const message = (reason as { message?: unknown }).message;
      if (typeof message === "string") return message;
    } catch {
      // A reason whose getters throw falls back to String().
    }
  }
  return String(reason);
}

/** The token segment of a request target and the path after it. */
function splitRequestPath(target: string | undefined): { token: string; path: string } {
  const pathname = new URL(target ?? "/", "http://127.0.0.1").pathname;
  const parts = pathname.split("/");
  return { token: parts[1] ?? "", path: "/" + parts.slice(2).join("/") };
}

/** Starts the inspector's server and the channel to the app. */
export async function startInspector(options: InspectorOptions): Promise<Inspector> {
  const channel = new RuntimeChannel(join(options.buildDir, ".inspect"));
  const clients = new Set<Client>();
  const logs: ConsoleLine[] = [];
  let cache: { at: number; data: Snapshot } | null = null;
  let listenPort = options.port;
  // A random per-session path segment, as Node's own inspector does: a page that was not handed
  // the full URL cannot talk to the inspector, even though it can reach loopback.
  const token = randomBytes(32).toString("base64url");

  const snapshot = async (force: boolean): Promise<Snapshot> => {
    if (!force && cache !== null && Date.now() - cache.at < 400) return cache.data;
    const data = (await channel.request("snapshot")) as Snapshot;
    cache = { at: Date.now(), data };
    return data;
  };

  const broadcast = (message: unknown): void => {
    for (const client of clients) if (client.open) client.send(message);
  };

  const addLog = (level: string, text: string): void => {
    const entry: ConsoleLine = { level, text, at: Date.now() };
    logs.push(entry);
    if (logs.length > 2000) logs.shift();
    broadcast({ method: "Runtime.consoleAPICalled", params: {
      type: level === "error" ? "error" : level === "warn" ? "warning" : "log",
      args: [{ type: "string", value: text }],
      executionContextId: 1,
      timestamp: entry.at,
    } });
  };

  const evaluateOnce = async (expression: string): Promise<{ [key: string]: unknown }> => {
    const snap = await snapshot(false);
    // `DONT_CONTEXTIFY` gives the context its own intrinsics instead of folding a host object into
    // it; the console's globals are then built inside the context from JSON, so the expression
    // never sees a host object or function to walk back through.
    const context = createContext(vmConstants.DONT_CONTEXTIFY);
    runInContext(`(${INSPECT_CONSOLE})(${JSON.stringify(JSON.stringify(snap))})`, context);
    // A rejection the expression leaves unhandled is raised on the dev process, which would end
    // `native dev`. Node reports rejections per process, so watch the one turn in which they
    // surface and keep those whose promise belongs to the context's realm; the rest are the dev
    // command's own and keep Node's default when nothing else was listening.
    const rejections: string[] = [];
    let foreign: unknown;
    const hadListeners = process.listenerCount("unhandledRejection") > 0;
    const watch = (reason: unknown, promise: Promise<unknown>): void => {
      if (promise instanceof Promise) {
        if (foreign === undefined) foreign = reason;
        return;
      }
      rejections.push(rejectionMessage(reason));
    };
    process.on("unhandledRejection", watch);
    let raw: string;
    try {
      try {
        raw = String(runInContext(`__inspectRun(${JSON.stringify(expression)})`, context, { timeout: 1000, displayErrors: false }));
      } catch (err) {
        raw = JSON.stringify({ exception: err instanceof Error ? err.message : String(err) });
      }
      // Context microtasks drain before the turn ends; this lets a rejected promise surface.
      await new Promise<void>((resolve) => { setImmediate(resolve); });
    } finally {
      process.off("unhandledRejection", watch);
    }
    if (foreign !== undefined && !hadListeners) {
      process.nextTick(() => { throw foreign; });
    }
    // A rejected promise the expression returned was handled inside the context; report it.
    let returned: { error?: unknown } | null = null;
    try {
      returned = JSON.parse(String(runInContext("__inspectThenable()", context, { timeout: 1000 }))) as { error?: unknown } | null;
    } catch {
      returned = null;
    }
    let collected: unknown = [];
    try {
      collected = JSON.parse(String(runInContext("__inspectLogs()", context, { timeout: 1000 })));
    } catch {
      // A console that could not be read leaves the evaluation's result alone.
    }
    if (Array.isArray(collected)) {
      for (const entry of collected) {
        if (entry !== null && typeof entry === "object") {
          const record = entry as { level?: unknown; text?: unknown };
          if (typeof record.text === "string") {
            addLog(typeof record.level === "string" ? record.level : "log", record.text);
          }
        }
      }
    }
    let answer: { exception?: unknown; value?: unknown };
    try {
      answer = JSON.parse(raw) as { exception?: unknown; value?: unknown };
    } catch {
      answer = { exception: "the expression produced no result" };
    }
    const exception = answer.exception;
    const rejectedPromise = returned !== null && typeof returned.error === "string" ? returned.error : undefined;
    const text = typeof exception === "string" ? exception : rejectedPromise ?? rejections[0];
    if (typeof text === "string") {
      return { exceptionDetails: {
        exceptionId: 1,
        text,
        lineNumber: 0,
        columnNumber: 0,
        scriptId: "0",
        url: "",
        stackTrace: { callFrames: [] },
      } };
    }
    return { result: answer.value };
  };

  // One console evaluation at a time, so the rejection window above sees only its own promises.
  let evaluateQueue: Promise<void> = Promise.resolve();
  const evaluate = (expression: string): Promise<{ [key: string]: unknown }> => {
    const run = evaluateQueue.then(() => evaluateOnce(expression));
    evaluateQueue = run.then(() => undefined, () => undefined);
    return run;
  };

  const handle = async (client: Client, message: { id?: number; method?: string; params?: { [key: string]: unknown } }): Promise<void> => {
    const id = message.id ?? 0;
    const method = message.method ?? "";
    const params = message.params ?? {};
    const reply = (result: unknown): void => client.send({ id, result });
    const fail = (code: number, text: string): void => client.send({ id, error: { code, message: text } });
    try {
      if (method === "Runtime.enable") {
        reply({});
        client.send({ method: "Runtime.executionContextCreated", params: { context: { id: 1, origin: "native://app", name: "", uniqueId: "1", auxData: { isDefault: true, frameId: "root" } } } });
        for (const entry of logs.slice(-200)) {
          client.send({ method: "Runtime.consoleAPICalled", params: {
            type: entry.level === "error" ? "error" : "log",
            args: [{ type: "string", value: entry.text }],
            executionContextId: 1,
            timestamp: entry.at,
          } });
        }
      } else if (method === "DOM.enable" || method === "CSS.enable" || method === "Overlay.enable" || method === "Page.enable" || method === "Log.enable") {
        reply({});
      } else if (method === "DOM.getDocument") {
        const snap = await snapshot(true);
        const root = nodeById(snap, snap.root);
        const depth = typeof params.depth === "number" ? params.depth : -1;
        reply({ root: root === null ? { nodeId: 0, nodeType: 9, nodeName: "#document" } : cdpNode(snap, root, depth) });
      } else if (method === "DOM.querySelector") {
        const snap = await snapshot(false);
        const nodeId = Number(params.nodeId ?? 0);
        const node = nodeById(snap, nodeId);
        if (node === null) throw new Error("unknown node");
        const serial = Number(await channel.request("query", { selector: String(params.selector ?? "") }));
        reply({ nodeId: serial });
      } else if (method === "DOM.describeNode") {
        const snap = await snapshot(false);
        const node = nodeById(snap, Number(params.nodeId ?? 0));
        if (node === null) throw new Error("unknown node");
        reply({ node: cdpNode(snap, node, 0) });
      } else if (method === "DOM.getBoxModel" || method === "Overlay.getBoxModel") {
        const snap = await snapshot(false);
        const node = nodeById(snap, Number(params.nodeId ?? 0));
        if (node === null) throw new Error("unknown node");
        const model = boxModel(node);
        if (model === null) throw new Error("the node has no box");
        reply({ model });
      } else if (method === "CSS.getComputedStyleForNode") {
        const snap = await snapshot(false);
        const node = nodeById(snap, Number(params.nodeId ?? 0));
        if (node === null) throw new Error("unknown node");
        reply({ computedStyle: Object.entries(node.styles).filter(([, value]) => value !== "").map(([name, value]) => ({ name, value })) });
      } else if (method === "CSS.getMatchedStylesForNode") {
        reply({ matchedCSSRules: [], inherited: [], pseudoElements: [] });
      } else if (method === "Overlay.highlightNode") {
        await channel.request("highlight", { nodeId: Number(params.nodeId ?? 0) });
        reply({});
      } else if (method === "Overlay.hideHighlight") {
        await channel.request("clear");
        reply({});
      } else if (method === "Page.getFrameTree") {
        reply({ frameTree: { frame: {
          id: "root", loaderId: "1", url: "native://app/", domainAndRegistry: "",
          securityOrigin: "native://app", mimeType: "text/html",
          secureContextType: "Secure", crossOriginIsolatedContextType: "NotIsolated",
          gatedAPIFeatures: [],
        } } });
      } else if (method === "Page.captureScreenshot") {
        const path = join(options.buildDir, ".inspect", "screenshot.png");
        await channel.request("screenshot", { path }, 5000);
        const data = existsSync(path) ? readFileSync(path).toString("base64") : "";
        reply(data === "" ? { data: "" } : { data, format: "png" });
      } else if (method === "Page.reload") {
        reply({});
      } else if (method === "Runtime.evaluate") {
        reply(await evaluate(String(params.expression ?? "")));
      } else if (method === "Native.getSnapshot") {
        reply(await snapshot(true));
      } else if (method === "Native.getLayers") {
        const snap = await snapshot(false);
        reply({ layers: snap.layers });
      } else if (method === "Native.getFrameTimes") {
        const snap = await snapshot(false);
        reply({ frames: snap.frames });
      } else if (method === "Log.clear") {
        logs.length = 0;
        reply({});
      } else {
        fail(-32601, `'${method}' is not part of the inspector's protocol`);
      }
    } catch (err) {
      fail(-32000, err instanceof Error ? err.message : String(err));
    }
  };

  const debuggerUrl = (): string => `ws://127.0.0.1:${listenPort}/${token}/devtools/page/native`;

  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const host = typeof req.headers.host === "string" ? req.headers.host.toLowerCase() : "";
    const origin = req.headers.origin;
    const deny = (status: number, text: string): void => {
      res.writeHead(status, { "Content-Type": "text/plain", "Cache-Control": "no-store" });
      res.end(text);
    };
    // DNS rebinding points a hostile name at 127.0.0.1; the Host header still carries that name.
    if (!isInspectorHost(host, listenPort)) {
      deny(403, "forbidden");
      return;
    }
    // A page another origin serves may not drive the inspector, even if it reaches the address.
    if (origin !== undefined && (typeof origin !== "string" || !isInspectorOrigin(origin, listenPort))) {
      deny(403, "forbidden");
      return;
    }
    let request: { token: string; path: string };
    try {
      request = splitRequestPath(req.url);
    } catch {
      deny(400, "bad request");
      return;
    }
    if (!isSameToken(request.token, token)) {
      deny(404, "not found");
      return;
    }
    const path = request.path;
    if (path === "/" || path === "/index.html") {
      res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Frame-Options": "DENY",
        "Content-Security-Policy": "frame-ancestors 'none'",
      });
      res.end(INSPECT_HTML);
      return;
    }
    if (path === "/json" || path === "/json/list") {
      res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      res.end(JSON.stringify([{
        description: "Native SDK app",
        devtoolsFrontendUrl: "",
        id: "native",
        title: "Native SDK inspector",
        type: "page",
        url: "native://app/",
        webSocketDebuggerUrl: debuggerUrl(),
      }]));
      return;
    }
    if (path === "/json/version") {
      res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      res.end(JSON.stringify({
        Browser: "Native SDK inspector",
        "Protocol-Version": "1.3",
        "User-Agent": "native",
        "V8-Version": "",
        "WebKit-Version": "",
        webSocketDebuggerUrl: debuggerUrl(),
      }));
      return;
    }
    if (path === "/json/protocol") {
      res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      res.end(JSON.stringify({ version: { major: "1", minor: "3" }, domains: [] }));
      return;
    }
    if (path === "/snapshot.json") {
      snapshot(true).then((data) => {
        res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
        res.end(JSON.stringify(data));
      }).catch((err: unknown) => {
        res.writeHead(500, { "Content-Type": "text/plain" });
        res.end(err instanceof Error ? err.message : String(err));
      });
      return;
    }
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("not found");
  });

  server.on("upgrade", (req: IncomingMessage, socket: Socket) => {
    // A client can reset the connection while a handshake reply is still being written. Without a
    // listener Node raises that write error on the process, which would end `native dev`.
    socket.on("error", () => {
      try {
        socket.destroy();
      } catch {
        // A socket that already closed needs nothing.
      }
    });
    const refuse = (status: string): void => {
      try {
        socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`);
      } catch {
        socket.destroy();
      }
    };
    const host = typeof req.headers.host === "string" ? req.headers.host.toLowerCase() : "";
    const origin = req.headers.origin;
    if (!isInspectorHost(host, listenPort)) {
      refuse("403 Forbidden");
      return;
    }
    if (origin !== undefined && (typeof origin !== "string" || !isInspectorOrigin(origin, listenPort))) {
      refuse("403 Forbidden");
      return;
    }
    let request: { token: string; path: string };
    try {
      request = splitRequestPath(req.url);
    } catch {
      refuse("400 Bad Request");
      return;
    }
    if (!isSameToken(request.token, token)) {
      refuse("403 Forbidden");
      return;
    }
    if (request.path !== "/devtools/page/native") {
      refuse("404 Not Found");
      return;
    }
    const key = req.headers["sec-websocket-key"];
    if (typeof key !== "string") {
      refuse("400 Bad Request");
      return;
    }
    const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    try {
      socket.write(
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
      );
    } catch {
      socket.destroy();
      return;
    }
    const client = new Client(socket);
    clients.add(client);
    client.onText = (text: string) => {
      let message: { id?: number; method?: string; params?: { [key: string]: unknown } };
      try {
        message = JSON.parse(text) as typeof message;
      } catch {
        return;
      }
      void handle(client, message);
    };
    socket.on("close", () => clients.delete(client));
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, "127.0.0.1", () => {
      server.off("error", reject);
      const address = server.address();
      if (typeof address === "object" && address !== null) listenPort = address.port;
      resolve();
    });
  });

  // Only the terminal the developer runs `native dev` in sees the token; anything that was not
  // handed this URL (a page in the developer's browser, say) cannot use the inspector.
  const url = `http://127.0.0.1:${listenPort}/${token}/`;
  // The port the server was asked for may be taken; the caller asked for a specific one, so a
  // failure to listen is the caller's to report.
  const close = (): void => {
    for (const client of clients) {
      try {
        client.socket.end();
      } catch {
        // A socket that already closed needs nothing.
      }
    }
    server.close();
  };

  return {
    url,
    log(stream: "stdout" | "stderr", line: string): void {
      if (stream === "stderr" && line.startsWith("Uncaught")) {
        logs.push({ level: "exception", text: line, at: Date.now() });
        broadcast({ method: "Runtime.exceptionThrown", params: {
          timestamp: Date.now(),
          exceptionDetails: { exceptionId: 1, text: line, lineNumber: 0, columnNumber: 0, scriptId: "0", url: "", stackTrace: { callFrames: [] } },
        } });
        broadcast({ method: "Log.entryAdded", params: { entry: {
          source: "javascript", level: "error", text: line, timestamp: Date.now(),
        } } });
        return;
      }
      addLog(stream === "stderr" ? "warn" : "log", line);
    },
    close,
  };
}
