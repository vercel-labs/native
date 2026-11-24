// XMLHttpRequest and EventSource over the network, against a local server: requests, headers,
// response types, abort and timeout, a rejected synchronous request, server-sent events, and the
// clear failure a WebSocket construction gives while there is no WebSocket transport.
//   npm test

import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import http from "node:http";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><style>body { margin: 0; }</style></head><body>
<script src="app.ts"></script>
</body></html>`;

const server = http.createServer((req, res) => {
  const chunks: Buffer[] = [];
  req.on("data", (c: Buffer) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks).toString("utf8");
    const path = (req.url ?? "/").split("?")[0];
    if (path === "/json") {
      res.writeHead(200, { "Content-Type": "application/json", "X-Reply": "yes" });
      res.end('{"ok":true,"items":[1,2]}');
    } else if (path === "/echo") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ method: req.method, body, header: req.headers["x-test"] }));
    } else if (path === "/text") {
      res.writeHead(200, { "Content-Type": "text/plain;charset=UTF-8" });
      res.end("plain text");
    } else if (path === "/sse") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
      res.write(": comment\n\ndata: first\n\n");
      setTimeout(() => { res.write("event: custom\ndata: second\nid: 7\n\n"); }, 40);
      // The source closes the connection itself, so the stream stays open.
    } else if (path === "/slow") {
      setTimeout(() => { res.writeHead(200); res.end("late"); }, 5000);
    } else {
      res.writeHead(404);
      res.end();
    }
  });
});

await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
const address = server.address();
const port = address !== null && typeof address === "object" ? address.port : 0;
const BASE = `http://127.0.0.1:${port}`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const BASE = ${JSON.stringify(BASE)};

function request(method: string, path: string, body?: string, type: string = ""): Promise<XMLHttpRequest> {
  return new Promise<XMLHttpRequest>((resolve, reject) => {
    const x = new XMLHttpRequest();
    x.open(method, BASE + path);
    if (type !== "") x.responseType = type;
    x.onload = (): void => resolve(x);
    x.onerror = (): void => reject(new Error("xhr error " + x.status));
    x.onabort = (): void => resolve(x);
    x.ontimeout = (): void => resolve(x);
    if (body !== undefined) x.setRequestHeader("X-Test", "v");
    x.send(body === undefined ? null : body);
  });
}

async function main(): Promise<void> {
  // A GET whose body is text, and the response's status, URL and headers.
  const get = await request("GET", "/text");
  log("xhr get " + get.status + " " + get.statusText + " " + get.readyState + " [" + get.responseText + "]");
  log("xhr url " + get.responseURL.endsWith("/text") + " type " + get.getResponseHeader("content-type"));
  log("xhr headers " + (String(get.getAllResponseHeaders()).indexOf("content-type: text/plain") >= 0));

  const json = await request("GET", "/json", undefined, "json");
  log("xhr json " + json.response.ok + " " + json.response.items.length + " " + json.responseType);

  const bytes = await request("GET", "/text", undefined, "arraybuffer");
  log("xhr bytes " + bytes.response.byteLength);

  const blob = await request("GET", "/text", undefined, "blob");
  log("xhr blob " + blob.response.type + " " + blob.response.size);

  const post = await request("POST", "/echo", "posted body", "json");
  log("xhr post " + post.response.method + " [" + post.response.body + "] " + post.response.header);

  // Abort while the request is in flight, then a timeout on a reply that never comes.
  const aborted = new Promise<XMLHttpRequest>((resolve) => {
    const x = new XMLHttpRequest();
    x.open("GET", BASE + "/slow");
    x.onabort = (): void => resolve(x);
    x.onload = (): void => resolve(x);
    x.send();
    setTimeout(() => x.abort(), 40);
  });
  const ab = await aborted;
  log("xhr abort " + ab.status + " " + ab.readyState);

  const timed = new Promise<XMLHttpRequest>((resolve) => {
    const x = new XMLHttpRequest();
    x.open("GET", BASE + "/slow");
    x.timeout = 60;
    x.ontimeout = (): void => resolve(x);
    x.onload = (): void => resolve(x);
    x.send();
  });
  const to = await timed;
  log("xhr timeout " + to.status);

  let syncError = "";
  try { new XMLHttpRequest().open("GET", BASE + "/text", false); }
  catch (e) { syncError = String(e); }
  log("xhr sync [" + syncError + "]");

  const states: number[] = [];
  const watch = new XMLHttpRequest();
  watch.open("GET", BASE + "/text");
  watch.onreadystatechange = (): void => { states.push(watch.readyState); };
  await new Promise<void>((resolve) => {
    watch.onload = (): void => resolve();
    watch.send();
  });
  log("xhr states " + states.join(","));

  // Server-sent events: open, a default message, a named event, then close.
  const events: string[] = [];
  const source = new EventSource(BASE + "/sse");
  await new Promise<void>((resolve) => {
    source.onopen = (): void => { events.push("open"); };
    source.onmessage = (e: any): void => { events.push("message:" + e.data + ":" + e.lastEventId); };
    source.addEventListener("custom", (e: any): void => { events.push("custom:" + e.data + ":" + e.lastEventId); resolve(); });
  });
  source.close();
  log("sse ready " + source.readyState + " [" + events.join(" ") + "]");

  // A WebSocket that can't connect reports it on itself: an error, then a close with 1006.
  const wsState = await new Promise<string>((resolve) => {
    const ws = new WebSocket("ws://127.0.0.1:1/");
    ws.onerror = (): void => {};
    ws.onclose = (e: any): void => resolve(ws.readyState + " " + e.code + " " + e.wasClean);
  });
  log("ws " + wsState);

  log("done");
}
main();
`;

const EXPECTED = [
  "xhr get 200 OK 4 [plain text]",
  "xhr url true type text/plain;charset=UTF-8",
  "xhr headers true",
  "xhr json true 2 json",
  "xhr bytes 10",
  "xhr blob text/plain 10",
  "xhr post POST [posted body] v",
  "xhr abort 0 4",
  "xhr timeout 0",
  "xhr sync [Error: InvalidAccessError: synchronous XMLHttpRequest is not supported]",
  "xhr states 2,3,4",
  "sse ready 2 [open message:first: custom:second:7]",
  "ws 3 1006 false",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-xhr-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
let stdout = "";
let stderr = "";
const child = spawn(exe, [], { env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "wait 2500" } });
child.stdout.on("data", (d: Buffer) => { stdout += d.toString(); });
child.stderr.on("data", (d: Buffer) => { stderr += d.toString(); });
const status = await new Promise<number | null>((resolve) => child.on("close", (code) => resolve(code)));
server.close();
if (status !== 0) throw new Error(`render failed (exit ${status})\n${stderr}`);

const got = stdout.split("\n").slice(0, -1);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}: ${JSON.stringify(got.slice(EXPECTED.length))}`);
const n = Math.min(got.length, EXPECTED.length);
for (let i = 0; i < n; i++) check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
