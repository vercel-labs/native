// EventSource over the network, against a local server: a message is a MessageEvent, a named
// event, lastEventId, a stream that ends reconnecting with Last-Event-ID, a network failure
// reconnecting, and a 204 or a wrong content type failing the source for good. Also Response and
// Request bytes().
//   npm test

import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import http from "node:http";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><style>body { margin: 0; }</style></head><body>
<script src="app.ts"></script>
</body></html>`;

const NOTE = "hello from the page dir\n";
const hits: Record<string, number> = {};
let lastEventId = "";

const server = http.createServer((req, res) => {
  const path = (req.url ?? "/").split("?")[0];
  hits[path] = (hits[path] ?? 0) + 1;
  if (path === "/sse") {
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
    res.write("retry: 50\n\n");
    res.write("id: 1\ndata: first\n\n");
    res.write("event: custom\nid: 2\ndata: second\n\n");
    return;
  }
  if (path === "/sse-204") {
    res.writeHead(204);
    res.end();
    return;
  }
  if (path === "/sse-mime") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("not an event stream");
    return;
  }
  if (path === "/sse-end") {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    if (hits[path] === 1) {
      res.end("retry: 50\n\nid: 1\ndata: one\n\n");
    } else {
      lastEventId = String(req.headers["last-event-id"] ?? "");
      res.write("id: 2\ndata: two\n\n");
    }
    return;
  }
  if (path === "/sse-fail") {
    if (hits[path] === 1) {
      req.socket.destroy();
      return;
    }
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    res.write("data: back\n\n");
    return;
  }
  res.writeHead(404);
  res.end();
});

await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
const address = server.address();
const port = address !== null && typeof address === "object" ? address.port : 0;
const BASE = `http://127.0.0.1:${port}`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const BASE = ${JSON.stringify(BASE)};
const NOTE_LENGTH = ${NOTE.length};
function once(es: EventSource, type: string): Promise<any> {
  return new Promise((resolve) => {
    const fn = (e: any): void => { es.removeEventListener(type, fn); resolve(e); };
    es.addEventListener(type, fn);
  });
}

async function main(): Promise<void> {
  const a = new EventSource(BASE + "/sse");
  const opened = once(a, "open");
  const first = once(a, "message");
  const custom = once(a, "custom");
  await opened;
  log("a open " + a.readyState);
  const e1 = await first;
  log("a msg " + (e1 instanceof MessageEvent) + " " + e1.data + " " + e1.lastEventId + " " + e1.origin);
  const e2 = await custom;
  log("a custom " + e2.data + " " + e2.lastEventId);
  a.close();
  log("a ready " + a.readyState);

  const b = new EventSource(BASE + "/sse-204");
  let bErrors = 0;
  b.addEventListener("error", () => { bErrors++; });
  await new Promise<void>((resolve) => setTimeout(() => resolve(), 200));
  log("b " + bErrors + " " + b.readyState);

  const c = new EventSource(BASE + "/sse-mime");
  let cErrors = 0;
  c.addEventListener("error", () => { cErrors++; });
  await new Promise<void>((resolve) => setTimeout(() => resolve(), 200));
  log("c " + cErrors + " " + c.readyState);

  const d = new EventSource(BASE + "/sse-end");
  log("d one " + (await once(d, "message")).data);
  const d2 = await once(d, "message");
  log("d two " + d2.data + " " + d2.lastEventId);
  d.close();

  const e = new EventSource(BASE + "/sse-fail");
  let eErrors = 0;
  e.addEventListener("error", () => { eErrors++; });
  log("e back " + (await once(e, "message")).data);
  log("e err " + eErrors);
  e.close();

  const note = await fetch("note.txt");
  const bytes = await note.bytes();
  log("bytes " + (bytes instanceof Uint8Array) + " " + bytes.length + " " + new TextDecoder().decode(bytes).trim());
  const req = new Request(BASE + "/echo", { method: "POST", body: "abc" });
  const rbytes = await req.bytes();
  log("reqbytes " + (rbytes instanceof Uint8Array) + " " + rbytes.length);

  log("done");
}
main();
`;

const EXPECTED = [
  "a open 1",
  `a msg true first 1 ${BASE}`,
  "a custom second 2",
  "a ready 2",
  "b 1 2",
  "c 1 2",
  "d one one",
  "d two two 2",
  "e back back",
  "e err 1",
  `bytes true ${NOTE.length} hello from the page dir`,
  "reqbytes true 3",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-eventsource-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
writeFileSync(join(dir, "note.txt"), NOTE);
const exe = join(dir, "app");
const build = await new Promise<number>((resolve) => {
  const p = spawn("node", ["compiler/cli.ts", "build", dir, "-o", exe], { stdio: "inherit" });
  p.on("close", (code) => resolve(code ?? 1));
});
if (build !== 0) throw new Error("build failed");

let stdout = "";
let stderr = "";
const child = spawn(exe, [], { env: { ...process.env, NATIVE_STEPS: "wait 4500" } });
child.stdout.on("data", (d: Buffer) => { stdout += d.toString(); });
child.stderr.on("data", (d: Buffer) => { stderr += d.toString(); });
const status = await new Promise<number | null>((resolve) => child.on("close", (code) => resolve(code)));
server.closeAllConnections();
server.close();
if (status !== 0) throw new Error(`render failed (exit ${status})\n${stderr}`);

const got = stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}
check("a non-stream response isn't retried (204)", hits["/sse-204"] === 1, String(hits["/sse-204"]));
check("a non-stream response isn't retried (content type)", hits["/sse-mime"] === 1, String(hits["/sse-mime"]));
check("a stream that ends reconnects", hits["/sse-end"] === 2, String(hits["/sse-end"]));
check("the reconnection carries Last-Event-ID", lastEventId === "1", lastEventId);
check("a network failure reconnects", hits["/sse-fail"] === 2, String(hits["/sse-fail"]));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
