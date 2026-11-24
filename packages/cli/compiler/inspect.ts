// The dev inspector's server: a page and a Chrome DevTools Protocol subset served on a local
// port, over data the running app answers for. `native dev --inspect` starts it; the app and the
// server share the build's `.native/inspect` directory (see runtime/app/inspect.ts).

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { IncomingMessage, Server, ServerResponse } from "node:http";
import type { Socket } from "node:net";
import { join } from "node:path";
import { INSPECT_HTML } from "./inspect-ui.ts";
import { evaluateExpression } from "./console-eval.ts";

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

/** Builds the read-only DOM a console expression runs against, from the snapshot's data. */
function consoleDom(snapshot: Snapshot): { document: unknown; getComputedStyle: (el: unknown) => unknown; addLog: (level: string, text: string) => void } {
  const byId = new Map<number, SnapshotNode>();
  for (const node of snapshot.nodes) byId.set(node.id, node);
  const mirror = new Map<number, Record<string, unknown>>();
  const logs: { level: string; text: string }[] = [];
  const textOf = (node: SnapshotNode): string => {
    if (node.type === 3 || node.type === 8) return node.text;
    let text = "";
    for (const id of node.children) {
      const child = byId.get(id);
      if (child !== undefined) text += textOf(child);
    }
    return text;
  };
  const matches = (node: SnapshotNode, selector: string): boolean => {
    const s = selector.trim();
    if (s.startsWith("#")) return node.attrs.some(([name, value]) => name === "id" && value === s.slice(1));
    if (s.startsWith(".")) return node.attrs.some(([name, value]) => name === "class" && value.split(/\s+/).includes(s.slice(1)));
    return node.name === s.toLowerCase() || (s === "*" && node.type === 1);
  };
  const queryAll = (node: SnapshotNode, selector: string): Record<string, unknown>[] => {
    const out: Record<string, unknown>[] = [];
    const walk = (current: SnapshotNode): void => {
      for (const id of current.children) {
        const child = byId.get(id);
        if (child === undefined) continue;
        if (child.type === 1 && matches(child, selector)) out.push(view(child));
        walk(child);
      }
    };
    walk(node);
    return out;
  };
  const view = (node: SnapshotNode): Record<string, unknown> => {
    const known = mirror.get(node.id);
    if (known !== undefined) return known;
    const el: Record<string, unknown> = {
      nodeId: node.id,
      nodeType: node.type,
      nodeName: node.type === 1 ? node.name.toUpperCase() : node.name,
      localName: node.name,
      id: (node.attrs.find(([name]) => name === "id") ?? ["", ""])[1],
      className: (node.attrs.find(([name]) => name === "class") ?? ["", ""])[1],
      children: node.children.map((id) => byId.get(id)).filter((n): n is SnapshotNode => n !== undefined).map(view),
      getAttribute: (name: string): string | null => {
        const found = node.attrs.find(([key]) => key === name);
        return found === undefined ? null : found[1];
      },
      getBoundingClientRect: () => {
        const r = node.rect ?? [0, 0, 0, 0];
        return { x: r[0], y: r[1], left: r[0], top: r[1], width: r[2], height: r[3], right: r[0] + r[2], bottom: r[1] + r[3] };
      },
      querySelector: (selector: string): unknown => queryAll(node, selector)[0] ?? null,
      querySelectorAll: (selector: string): unknown[] => queryAll(node, selector),
      matches: (selector: string): boolean => matches(node, selector),
    };
    Object.defineProperty(el, "textContent", { get: () => textOf(node) });
    Object.defineProperty(el, "childNodes", { get: () => node.children.map((id) => byId.get(id)).filter((n): n is SnapshotNode => n !== undefined).map(view) });
    Object.defineProperty(el, "parentNode", { get: () => byId.get(node.parent) === undefined ? null : view(byId.get(node.parent)!) });
    Object.defineProperty(el, "parentElement", { get: () => { const p = byId.get(node.parent); return p !== undefined && p.type === 1 ? view(p) : null; } });
    Object.defineProperty(el, "children", { get: () => node.children.map((id) => byId.get(id)).filter((n): n is SnapshotNode => n !== undefined && n.type === 1).map(view) });
    mirror.set(node.id, el);
    return el;
  };
  const root = byId.get(snapshot.root);
  const documentView = root === undefined ? {} : view(root);
  const html = root === undefined ? undefined : snapshot.nodes.find((n) => n.parent === root.id && n.type === 1);
  const body = snapshot.nodes.find((n) => n.name === "body");
  Object.assign(documentView, {
    title: snapshot.title,
    documentElement: html === undefined ? null : view(html),
    body: body === undefined ? null : view(body),
    getElementById: (id: string): unknown => {
      const found = snapshot.nodes.find((n) => n.type === 1 && n.attrs.some(([name, value]) => name === "id" && value === id));
      return found === undefined ? null : view(found);
    },
    querySelector: (selector: string): unknown => {
      const found = snapshot.nodes.find((n) => n.type === 1 && matches(n, selector));
      return found === undefined ? null : view(found);
    },
    querySelectorAll: (selector: string): unknown[] => snapshot.nodes.filter((n) => n.type === 1 && matches(n, selector)).map(view),
  });
  return {
    document: documentView,
    getComputedStyle: (el: unknown): { getPropertyValue: (name: string) => string } => {
      const id = typeof el === "object" && el !== null && "nodeId" in el ? Number((el as { nodeId: number }).nodeId) : -1;
      const node = byId.get(id);
      return { getPropertyValue: (name: string): string => node === undefined ? "" : node.styles[name] ?? "" };
    },
    addLog: (level: string, text: string): void => {
      logs.push({ level, text });
    },
  };
}

/** Starts the inspector's server and the channel to the app. */
export async function startInspector(options: InspectorOptions): Promise<Inspector> {
  const channel = new RuntimeChannel(join(options.buildDir, ".inspect"));
  const clients = new Set<Client>();
  const logs: ConsoleLine[] = [];
  let cache: { at: number; data: Snapshot } | null = null;
  let listenPort = options.port;

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

  const evaluate = async (expression: string, returnByValue: boolean): Promise<{ [key: string]: unknown }> => {
    const snap = await snapshot(false);
    const dom = consoleDom(snap);
    const sandbox: { [key: string]: unknown } = {
      document: dom.document,
      getComputedStyle: dom.getComputedStyle,
      console: {
        log: (...args: unknown[]) => { const t = args.map(String).join(" "); dom.addLog("log", t); addLog("log", t); return undefined; },
        warn: (...args: unknown[]) => { const t = args.map(String).join(" "); dom.addLog("warn", t); addLog("warn", t); return undefined; },
        error: (...args: unknown[]) => { const t = args.map(String).join(" "); dom.addLog("error", t); addLog("error", t); return undefined; },
      },
      JSON: {
        stringify: (value: unknown) => JSON.stringify(value),
        parse: (text: unknown) => JSON.parse(String(text)) as unknown,
      },
      Math: {
        PI: Math.PI, E: Math.E,
        abs: (x: unknown) => Math.abs(Number(x)), floor: (x: unknown) => Math.floor(Number(x)),
        ceil: (x: unknown) => Math.ceil(Number(x)), round: (x: unknown) => Math.round(Number(x)),
        sqrt: (x: unknown) => Math.sqrt(Number(x)), random: () => Math.random(),
        min: (...xs: unknown[]) => Math.min(...xs.map(Number)), max: (...xs: unknown[]) => Math.max(...xs.map(Number)),
      },
    };
    try {
      const value = evaluateExpression(expression, sandbox);
      const described = describe(value);
      if (returnByValue) return { result: described };
      return { result: described };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { exceptionDetails: {
        exceptionId: 1,
        text: message,
        lineNumber: 0,
        columnNumber: 0,
        scriptId: "0",
        url: "",
        stackTrace: { callFrames: [] },
      } };
    }
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
        reply(await evaluate(String(params.expression ?? ""), params.returnByValue === true));
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

  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (url.pathname === "/" || url.pathname === "/index.html") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      res.end(INSPECT_HTML);
      return;
    }
    if (url.pathname === "/json" || url.pathname === "/json/list") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify([{
        description: "Native SDK app",
        devtoolsFrontendUrl: "",
        id: "native",
        title: "Native SDK inspector",
        type: "page",
        url: "native://app/",
        webSocketDebuggerUrl: `ws://127.0.0.1:${listenPort}/devtools/page/native`,
      }]));
      return;
    }
    if (url.pathname === "/json/version") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        Browser: "Native SDK inspector",
        "Protocol-Version": "1.3",
        "User-Agent": "native",
        "V8-Version": "",
        "WebKit-Version": "",
        webSocketDebuggerUrl: `ws://127.0.0.1:${listenPort}/devtools/page/native`,
      }));
      return;
    }
    if (url.pathname === "/json/protocol") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ version: { major: "1", minor: "3" }, domains: [] }));
      return;
    }
    if (url.pathname === "/snapshot.json") {
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
    const key = req.headers["sec-websocket-key"];
    if (typeof key !== "string") {
      socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
      return;
    }
    const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
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

  const url = `http://127.0.0.1:${listenPort}/`;
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

/** A console value as the protocol reports it. */
function describe(value: unknown): { [key: string]: unknown } {
  if (value === null) return { type: "object", subtype: "null", value: null };
  if (value === undefined) return { type: "undefined" };
  const type = typeof value;
  if (type === "string" || type === "number" || type === "boolean") return { type, value };
  if (type === "function") return { type: "function", description: String(value) };
  try {
    const json = JSON.stringify(value);
    return { type: "object", value: json === undefined ? String(value) : JSON.parse(json) };
  } catch {
    return { type: "object", description: String(value) };
  }
}
