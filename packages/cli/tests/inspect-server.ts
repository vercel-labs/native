// The inspector's server: the per-session token, the loopback-only bind, the Host and Origin
// checks on HTTP and WebSocket upgrades, and evaluation inside an isolated context. It starts the
// real server and the app side that answers its snapshot requests, then attacks both.
//
//   node tests/inspect-server.ts

import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { connect } from "node:net";
import type { Socket } from "node:net";
import { networkInterfaces, tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

/** The host module's functions, as no-ops: a snapshot needs none of them to do work. */
function stubHost(dir: string): string {
  const source = readFileSync(new URL("../runtime/host.ts", import.meta.url), "utf8");
  const names = [...source.matchAll(/export declare function (\w+)/g)].map((m) => m[1]);
  const file = join(dir, "host-stub.mjs");
  const consts = [...source.matchAll(/^export const (\w+) = ([^;\n]+);/gm)].map((m) => `export const ${m[1]} = ${m[2]};`);
  writeFileSync(file, [...names.map((name) => `export function ${name}() { return 0; }`), ...consts].join("\n"));
  return pathToFileURL(file).href;
}

const dir = mkdtempSync(join(tmpdir(), "native-inspect-server-"));
const hostStub = stubHost(dir);
registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context) as { url: string };
    if (resolved.url.endsWith("/runtime/host.ts")) return { url: hostStub, shortCircuit: true };
    return resolved;
  },
});

const { compileApp } = await import("../compiler/compile.ts");
const { Diagnostics } = await import("../compiler/diagnostics.ts");
const { mount } = await import("../runtime/app/mount.ts");
const { startInspector: startAppInspector } = await import("../runtime/app/inspect.ts");
const { startInspector: startServer } = await import("../compiler/inspect.ts");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// --- A real app for the inspector to read -------------------------------------------------

const appDir = join(dir, "app");
mkdirSync(appDir, { recursive: true });
writeFileSync(join(appDir, "index.html"), [
  "<!doctype html>",
  "<html>",
  "  <head><title>Server</title></head>",
  "  <body><div id=\"box\">hello</div></body>",
  "</html>",
].join("\n"));
const diagnostics = new Diagnostics();
const app = compileApp(join(appDir, "index.html"), diagnostics);
check("the page compiles", diagnostics.errorCount === 0, diagnostics.format(false));
mount(app.tables);

const buildDir = join(dir, "native");
const inspectDir = join(buildDir, ".inspect");
mkdirSync(inspectDir, { recursive: true });
startAppInspector(inspectDir);

const inspector = await startServer({ appDir, buildDir, port: 0 });
const base = new URL(inspector.url);
const port = Number(base.port);
const token = base.pathname.split("/")[1] ?? "";
const wsPath = `/${token}/devtools/page/native`;
const ownOrigin = `http://127.0.0.1:${port}`;

check("the printed URL carries a token in its path", /^[A-Za-z0-9_-]{32,}$/.test(token), inspector.url);
check("the URL names loopback", base.hostname === "127.0.0.1", inspector.url);

// --- Raw HTTP and WebSocket clients, so the headers can be chosen -------------------------

function rawRequest(lines: string[]): Promise<{ status: string; body: string; socket: Socket }> {
  return new Promise((resolve) => {
    const socket = connect(port, "127.0.0.1");
    let data = "";
    const done = (status: string): void => {
      socket.pause();
      resolve({ status, body: data.split("\r\n\r\n").slice(1).join("\r\n\r\n"), socket });
    };
    socket.on("connect", () => { socket.write(lines.join("\r\n") + "\r\n\r\n"); });
    socket.on("data", (chunk) => {
      data += chunk.toString("latin1");
      if (data.indexOf("\r\n") >= 0 && (data.indexOf("\r\n\r\n") >= 0 || data.startsWith("HTTP/1.1 1"))) {
        done(data.slice(0, data.indexOf("\r\n")));
      }
    });
    socket.on("error", () => { if (data === "") done("connection error"); });
    setTimeout(() => { if (data === "") { socket.destroy(); done("timed out"); } }, 3000).unref();
  });
}

function upgradeHeaders(path: string, host: string | undefined, origin: string | undefined): string[] {
  const lines = [
    `GET ${path} HTTP/1.1`,
    `Host: ${host ?? `127.0.0.1:${port}`}`,
    "Connection: Upgrade",
    "Upgrade: websocket",
    `Sec-WebSocket-Key: ${randomBytes(16).toString("base64")}`,
    "Sec-WebSocket-Version: 13",
  ];
  if (origin !== undefined) lines.push(`Origin: ${origin}`);
  return lines;
}

function upgrade(path: string, host?: string, origin?: string): Promise<string> {
  return rawRequest(upgradeHeaders(path, host, origin)).then((answer) => {
    answer.socket.destroy();
    return answer.status;
  });
}

async function http(path: string): Promise<{ status: number; headers: Headers; body: string }> {
  const response = await fetch(`http://127.0.0.1:${port}${path}`);
  return { status: response.status, headers: response.headers, body: await response.text() };
}

/** A minimal Chrome DevTools Protocol client over Node's WebSocket. */
async function rpc(ws: WebSocket, id: number, method: string, params: unknown = {}): Promise<Record<string, any>> {
  return new Promise((resolve, reject) => {
    const onMessage = (event: MessageEvent): void => {
      const message = JSON.parse(String(event.data)) as Record<string, any>;
      if (message.id === id) {
        ws.removeEventListener("message", onMessage);
        resolve(message);
      }
    };
    ws.addEventListener("message", onMessage);
    ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => { ws.removeEventListener("message", onMessage); reject(new Error(`no answer to ${method}`)); }, 5000).unref();
  });
}

function opened(url: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const timer = setTimeout(() => { ws.close(); reject(new Error(`timed out connecting to ${url}`)); }, 5000);
    ws.addEventListener("open", () => { clearTimeout(timer); resolve(ws); }, { once: true });
    ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error(`could not connect to ${url}`)); }, { once: true });
  });
}

// --- The token gate -----------------------------------------------------------------------

const noToken = await http("/");
check("a page request without the token is refused", noToken.status === 404, String(noToken.status));
const wrongToken = await http("/not-the-token/");
check("a page request with a wrong token is refused", wrongToken.status === 404, String(wrongToken.status));
const page = await http(`/${token}/`);
check("the page is served with the token", page.status === 200 && page.body.includes("Native SDK inspector"), String(page.status));
check("the page refuses to be framed", page.headers.get("x-frame-options") === "DENY", String(page.headers.get("x-frame-options")));
const listing = await http(`/${token}/json`);
check("the discovery listing carries the tokenized WebSocket URL",
  listing.status === 200 && listing.body.includes(`/${token}/devtools/page/native`), listing.body.slice(0, 120));
const hiddenListing = await http("/json");
check("the discovery listing without the token is refused", hiddenListing.status === 404, String(hiddenListing.status));

// --- Host and Origin checks on the upgrade -------------------------------------------------

const noTokenUpgrade = await upgrade("/devtools/page/native");
check("a WebSocket upgrade without the token is refused", !noTokenUpgrade.includes("101"), noTokenUpgrade);
const wrongTokenUpgrade = await upgrade(`/wrong/${wsPath.split("/").slice(2).join("/")}`);
check("a WebSocket upgrade with a wrong token is refused", !wrongTokenUpgrade.includes("101"), wrongTokenUpgrade);
const crossOrigin = await upgrade(wsPath, undefined, "https://evil.example");
check("a WebSocket upgrade from another origin is refused", !crossOrigin.includes("101"), crossOrigin);
const rebinding = await upgrade(wsPath, `evil.example:${port}`);
check("a WebSocket upgrade with a foreign Host is refused (DNS rebinding)", !rebinding.includes("101"), rebinding);
const nullOrigin = await upgrade(wsPath, undefined, "null");
check("a WebSocket upgrade from a null origin is refused", !nullOrigin.includes("101"), nullOrigin);
const sameOrigin = await upgrade(wsPath, undefined, ownOrigin);
check("a WebSocket upgrade from the inspector's own origin is accepted", sameOrigin.includes("101"), sameOrigin);

const reboundHttp = await rawRequest([`GET /${token}/json HTTP/1.1`, `Host: evil.example:${port}`, "Connection: close"]);
reboundHttp.socket.destroy();
check("an HTTP request with a foreign Host is refused (DNS rebinding)", reboundHttp.status.includes("403"), reboundHttp.status);
const crossOriginHttp = await rawRequest([`GET /${token}/json HTTP/1.1`, `Host: 127.0.0.1:${port}`, "Origin: https://evil.example", "Connection: close"]);
crossOriginHttp.socket.destroy();
check("an HTTP request from another origin is refused", crossOriginHttp.status.includes("403"), crossOriginHttp.status);

// --- The legitimate local client still works, and expressions are isolated ----------------

const ws = await opened(`ws://127.0.0.1:${port}${wsPath}`);
const enabled = await rpc(ws, 1, "Runtime.enable");
check("the local client connects with the token and enables the runtime", enabled.result !== undefined, JSON.stringify(enabled));
const snapshot = await rpc(ws, 2, "Native.getSnapshot");
check("the local client reads a snapshot", Array.isArray(snapshot.result?.nodes) && snapshot.result.nodes.length > 0,
  JSON.stringify(snapshot).slice(0, 160));

const domRead = await rpc(ws, 3, "Runtime.evaluate", { expression: "document.querySelector('#box').getAttribute('id')", returnByValue: true });
check("the console reads the snapshot's DOM", domRead.result?.result?.value === "box", JSON.stringify(domRead).slice(0, 160));
const arithmetic = await rpc(ws, 4, "Runtime.evaluate", { expression: "1 + 2", returnByValue: true });
check("the console evaluates an expression", arithmetic.result?.result?.value === 3, JSON.stringify(arithmetic).slice(0, 160));

const processType = await rpc(ws, 5, "Runtime.evaluate", { expression: "this.constructor.constructor('return typeof process')()", returnByValue: true });
check("the outer-realm constructor chain does not reach process", processType.result?.result?.value === "undefined", JSON.stringify(processType).slice(0, 160));
const requireType = await rpc(ws, 6, "Runtime.evaluate", { expression: "Object.constructor('return typeof require')()", returnByValue: true });
check("the outer-realm constructor chain does not reach require", requireType.result?.result?.value === "undefined", JSON.stringify(requireType).slice(0, 160));
const globalType = await rpc(ws, 7, "Runtime.evaluate", { expression: "globalThis.constructor.constructor('return typeof process')()", returnByValue: true });
check("the global object's constructor chain does not reach process", globalType.result?.result?.value === "undefined", JSON.stringify(globalType).slice(0, 160));
const functionType = await rpc(ws, 8, "Runtime.evaluate", { expression: "Function('return typeof process')()", returnByValue: true });
check("the context's own Function cannot reach process", functionType.result?.result?.value === "undefined", JSON.stringify(functionType).slice(0, 160));
const realm = await rpc(ws, 9, "Runtime.evaluate", { expression: "document.constructor === Object", returnByValue: true });
check("the document belongs to the context's own realm", realm.result?.result?.value === true, JSON.stringify(realm).slice(0, 160));

const sentinel = join(dir, "escaped.txt");
const target = JSON.stringify(sentinel);
const escapes = [
  `this.constructor.constructor('return process')().getBuiltinModule('fs').writeFileSync(${target}, 'owned')`,
  `Object.constructor('return process')().getBuiltinModule('fs').writeFileSync(${target}, 'owned')`,
  `document.constructor.constructor('return process')().getBuiltinModule('fs').writeFileSync(${target}, 'owned')`,
  `getComputedStyle.constructor.constructor('return process')().getBuiltinModule('fs').writeFileSync(${target}, 'owned')`,
  `console.log.constructor.constructor('return process')().getBuiltinModule('fs').writeFileSync(${target}, 'owned')`,
  `this.constructor.constructor('return require')().writeFileSync(${target}, 'owned')`,
];
let escapeErrors = 0;
for (const [index, payload] of escapes.entries()) {
  const answer = await rpc(ws, 10 + index, "Runtime.evaluate", { expression: payload, returnByValue: true });
  if (answer.result?.exceptionDetails !== undefined) escapeErrors++;
}
check("every escape attempt fails", escapeErrors === escapes.length, `${escapeErrors}/${escapes.length} failed as expected`);
check("no escape attempt wrote a file as the developer", !existsSync(sentinel), sentinel);

const loop = await rpc(ws, 20, "Runtime.evaluate", { expression: "while (true) {}", returnByValue: true });
check("a runaway expression times out", loop.result?.exceptionDetails !== undefined, JSON.stringify(loop).slice(0, 160));

// --- The server listens on loopback only ---------------------------------------------------

const external = Object.values(networkInterfaces()).flat()
  .find((entry) => entry !== undefined && entry.family === "IPv4" && !entry.internal);
if (external === undefined) {
  console.log("skip  no non-loopback interface to probe");
} else {
  const reachable = await new Promise<boolean>((resolve) => {
    const probe = connect(port, external.address);
    probe.on("connect", () => { probe.destroy(); resolve(true); });
    probe.on("error", () => resolve(false));
    setTimeout(() => { probe.destroy(); resolve(false); }, 1500).unref();
  });
  check("the server is not reachable on a non-loopback address", !reachable, external.address);
}

// --- Fuzz the request and frame parsers, then check the server still answers ----------------

const fuzz = await rawRequest(upgradeHeaders(wsPath, undefined, ownOrigin));
check("the fuzzing client upgrades", fuzz.status.includes("101"), fuzz.status);
fuzz.socket.resume();
for (let i = 0; i < 500; i++) {
  const length = 1 + Math.floor(Math.random() * 64);
  fuzz.socket.write(randomBytes(length));
}
for (let i = 0; i < 50; i++) {
  await new Promise<void>((resolve) => setTimeout(resolve, 2));
}
fuzz.socket.destroy();
const garbage = await rawRequest(["GET /%zz%% HTTP/9.9", "Host: 127.0.0.1:" + port]);
garbage.socket.destroy();
const afterFuzz = await opened(`ws://127.0.0.1:${port}${wsPath}`);
const alive = await rpc(afterFuzz, 30, "Runtime.enable");
check("the server still answers after fuzzed input", alive.result !== undefined, JSON.stringify(alive).slice(0, 160));
afterFuzz.close();
ws.close();

inspector.close();
console.log(failed === 0 ? "all passed" : `${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
