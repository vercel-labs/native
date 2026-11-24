// fetch(): the app's own files (page-relative, "/", file: and data: URLs read from the directory
// the page was built from) and the network over http:, through a local server these tests run.
// One line per assertion, awaited in order so the log reads in the order written.
//   npm test

import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import http from "node:http";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><style>body { margin: 0; }</style></head><body>
<script src="app.ts"></script>
</body></html>`;

/** The server the network assertions talk to: echo, redirects, chunks, a teapot and a slow reply. */
const server = http.createServer((req, res) => {
  const chunks: Buffer[] = [];
  req.on("data", (c: Buffer) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks).toString("latin1");
    const path = (req.url ?? "/").split("?")[0];
    if (path === "/json") {
      res.writeHead(200, { "Content-Type": "application/json", "X-Reply": "json" });
      res.end('{"items":[1,2,3],"name":"native"}');
    } else if (path === "/text") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("hello network\n");
    } else if (path === "/echo") {
      res.writeHead(200, { "Content-Type": "application/json", "Set-Cookie": "a=1; Path=/" });
      res.end(JSON.stringify({ method: req.method, body, headers: req.headers }));
    } else if (path === "/redirect") {
      res.writeHead(302, { Location: "/text" });
      res.end();
    } else if (path === "/chunks") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      let i = 0;
      const timer = setInterval(() => {
        res.write("chunk" + i + "\n");
        if (++i === 3) { clearInterval(timer); res.end(); }
      }, 20);
    } else if (path === "/slow") {
      setTimeout(() => { res.writeHead(200); res.end("late"); }, 3000);
    } else if (path === "/teapot") {
      res.writeHead(418, "I am a teapot");
      res.end("teapot");
    } else {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("nope");
    }
  });
});

await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
const address = server.address();
const port = address !== null && typeof address === "object" ? address.port : 0;
const BASE = `http://127.0.0.1:${port}`;

// The SRI digests the integrity checks use: one good SHA-256 and SHA-512 for /text's body, and a
// base64 value that matches nothing.
const TEXT_BODY = "hello network\n";
const GOOD256 = createHash("sha256").update(TEXT_BODY).digest("base64");
const GOOD512 = createHash("sha512").update(TEXT_BODY).digest("base64");
const BAD = "AAAA";

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const BASE = ${JSON.stringify(BASE)};
const GOOD256 = ${JSON.stringify(GOOD256)};
const GOOD512 = ${JSON.stringify(GOOD512)};
const BAD = ${JSON.stringify(BAD)};

async function main(): Promise<void> {
  // --- the app's own files -------------------------------------------------
  const note = await fetch("note.txt");
  const clone = note.clone();
  log("status " + note.status + " " + note.statusText + " ok " + note.ok);
  log("type " + note.headers.get("Content-Type"));
  log("length " + note.headers.get("content-length"));
  log("url " + note.url.endsWith("/note.txt"));
  log("text [" + (await note.text()).trim() + "]");
  log("bodyUsed " + note.bodyUsed + " clone " + (await clone.text()).trim());

  log("sub [" + (await (await fetch("./sub/deep.txt")).text()).trim() + "]");
  log("parent [" + (await (await fetch("../note.txt")).text()).trim() + "]");
  log("root [" + (await (await fetch("/note.txt")).text()).trim() + "]");
  log("query [" + (await (await fetch("note.txt?v=2#top")).text()).trim() + "]");

  const bin = await (await fetch("blob.bin")).arrayBuffer();
  log("binary " + bin.byteLength);

  const data = await fetch("data:text/plain;base64,aGVsbG8gZGF0YQ==");
  log("data [" + (await data.text()) + "] type " + data.headers.get("content-type"));
  log("data plain [" + (await (await fetch("data:text/plain,a%20b%2Bc")).text()) + "]");

  const file = await fetch("file:" + note.url.slice("file:".length));
  log("file [" + (await file.text()).trim() + "]");

  const json = await fetch("data:application/json,%7B%22a%22%3A%5B1%2C2%5D%7D");
  log("json " + json.headers.get("content-type") + " " + (await json.json()).a.length);

  const h = (await fetch("note.txt")).headers;
  log("headers " + h.has("Content-Length") + " " + h.get("CONTENT-TYPE") + " " + h.get("nope"));
  h.set("X-Test", "one");
  h.append("X-Test", "two");
  h.set("content-type", "text/custom");
  log("headers set " + h.get("x-test") + " " + h.get("content-type"));
  h.delete("X-Test");
  log("headers delete " + h.has("x-test") + " " + h.entries().length);

  // A request built the way a loader builds one for the network: options the app can't use are
  // still taken, a plain object of headers is read, and the fetch reads the URL it names.
  const req = new Request("note.txt", {
    headers: { "X-Thing": "v" }, cache: "no-store", credentials: "include", priority: "high",
  });
  log("request " + req.method + " " + req.url + " " + req.headers.get("x-thing") + " "
    + req.cache + " " + req.credentials + " " + req.priority);
  const viaRequest = await fetch(req);
  log("request fetched [" + (await viaRequest.text()).trim() + "] " + viaRequest.headers.get("content-length"));

  const ac0 = new AbortController();
  const signalled = new Request("note.txt", {
    signal: AbortSignal.any([ac0.signal]), headers: new Headers({ "X-Sig": "1" }),
  });
  log("request signal " + (signalled.signal !== null) + " " + signalled.headers.get("x-sig"));

  const objHeaders = new Headers({ "X-One": "1", "x-two": "2" });
  log("object headers " + objHeaders.get("x-one") + " " + objHeaders.entries().length);

  const pe = new ProgressEvent("progress", { lengthComputable: true, loaded: 3, total: 9 });
  log("progress " + pe.type + " " + pe.lengthComputable + " " + pe.loaded + "/" + pe.total);

  // The body as a stream: what a loader reads to report progress, a chunk at a time.
  const big = await fetch("big.bin");
  const bigBody = big.body;
  if (bigBody === null) throw new Error("no body");
  const reader = bigBody.getReader();
  let got = 0;
  let reads = 0;
  while (true) {
    const step = await reader.read();
    if (step.done) break;
    got += step.value.byteLength;
    reads++;
  }
  log("body stream " + got + " bytes in " + reads + " reads of " + big.headers.get("content-length"));

  try {
    await fetch("missing.txt");
    log("missing resolved");
  } catch (e) {
    log("missing rejected " + String(e));
  }

  // --- the network ---------------------------------------------------------
  const net = await fetch(BASE + "/json");
  log("net " + net.status + " " + net.statusText + " " + net.ok + " " + net.type + " " + net.redirected);
  log("net url " + net.url);
  log("net header " + net.headers.get("content-type") + " " + net.headers.get("x-reply"));
  const netJson = await net.json();
  log("net json " + netJson.items.length + " " + netJson.name + " bodyUsed " + net.bodyUsed);

  const text = await fetch(BASE + "/text");
  log("net text [" + (await text.text()).trim() + "]");

  const post = await fetch(BASE + "/echo", {
    method: "POST", headers: { "X-Test": "v", "Content-Type": "text/plain" }, body: "hello body",
  });
  const postJson = await post.json();
  log("net post " + postJson.method + " [" + postJson.body + "] " + postJson.headers["content-type"]
    + " " + postJson.headers["x-test"]);

  const blob = await fetch(BASE + "/echo", { method: "PUT", body: new Blob(["blob data"], { type: "text/x-blob" }) });
  const blobJson = await blob.json();
  log("net blob " + blobJson.method + " [" + blobJson.body + "] " + blobJson.headers["content-type"]);

  const u8 = await fetch(BASE + "/echo", { method: "POST", body: new Uint8Array([65, 66, 67]) });
  const u8Json = await u8.json();
  log("net bytes [" + u8Json.body + "]");

  const usp = await fetch(BASE + "/echo", { method: "POST", body: new URLSearchParams({ a: "1", b: "two words" }) });
  const uspJson = await usp.json();
  log("net form [" + uspJson.body + "] " + uspJson.headers["content-type"]);

  const form = new FormData();
  form.append("first", "1");
  form.append("second", "two");
  const formRes = await fetch(BASE + "/echo", { method: "POST", body: form });
  const formJson = await formRes.json();
  log("net multipart " + (String(formJson.headers["content-type"]).indexOf("multipart/form-data; boundary=") === 0)
    + " " + (String(formJson.body).indexOf('name="second"') >= 0));

  const redirect = await fetch(BASE + "/redirect");
  log("net redirect " + redirect.status + " " + redirect.redirected + " " + redirect.url.endsWith("/text"));
  const manual = await fetch(BASE + "/redirect", { redirect: "manual" });
  log("net manual " + manual.status + " " + manual.type + " " + (manual.headers.get("location") === null)
    + " " + (manual.body === null));
  const errorMode = fetch(BASE + "/redirect", { redirect: "error" });
  try { await errorMode; log("net redirect error no"); }
  catch (e) { log("net redirect error " + (e instanceof TypeError)); }

  const teapot = await fetch(BASE + "/teapot");
  log("net teapot " + teapot.status + " [" + teapot.statusText + "] " + teapot.ok);

  const missing = await fetch(BASE + "/nowhere");
  log("net missing " + missing.status + " " + missing.ok);

  const chunked = await fetch(BASE + "/chunks");
  const chunkedBody = chunked.body;
  if (chunkedBody === null) throw new Error("no body");
  const chunkReader = chunkedBody.getReader();
  let streamed = "";
  while (true) {
    const step = await chunkReader.read();
    if (step.done) break;
    streamed += new TextDecoder().decode(step.value);
  }
  log("net stream [" + streamed.trim().replace(/\\n/g, ",") + "]");

  const ac = new AbortController();
  const slow = fetch(BASE + "/slow", { signal: ac.signal });
  setTimeout(() => ac.abort(), 50);
  try { await slow; log("net abort no"); }
  catch (e) { log("net abort " + (e as any).name); }

  const pre = new AbortController();
  pre.abort();
  try { await fetch(BASE + "/text", { signal: pre.signal }); log("net preabort no"); }
  catch (e) { log("net preabort " + (e as any).name); }

  const sent = new Request(BASE + "/echo", { method: "POST", body: "via request" });
  const sentRes = await fetch(sent);
  const sentJson = await sentRes.json();
  log("net request " + sentJson.body + " used " + sent.bodyUsed);

  const raw = await fetch(BASE + "/echo", { method: "POST", body: "abc" });
  const copy = raw.clone();
  const copyText = await copy.text();
  const rawText = await raw.text();
  log("net clone " + (copyText === rawText) + " " + (copyText.length > 0));

  const bytes = await (await fetch(BASE + "/text")).blob();
  log("net blob type " + bytes.type + " size " + bytes.size);

  log("net setcookie " + post.headers.getSetCookie().length + " " + post.headers.get("set-cookie"));

  // Subresource Integrity: a matching digest resolves with the body unchanged; a wrong one, an
  // unsupported algorithm, or a redirect rejects, as Chrome does.
  const verified = await fetch(BASE + "/text", { integrity: "sha256-" + GOOD256 });
  log("integrity ok [" + (await verified.text()).trim() + "] " + verified.status);
  const strong = await fetch(BASE + "/text", { integrity: "sha256-" + BAD + " sha512-" + GOOD512 });
  log("integrity strong [" + (await strong.text()).trim() + "]");
  const viaIntegrity = await fetch(new Request(BASE + "/text", { integrity: "sha256-" + GOOD256 }));
  log("integrity request [" + (await viaIntegrity.text()).trim() + "]");
  try { await fetch(BASE + "/text", { integrity: "sha256-" + BAD }); log("integrity bad no"); }
  catch (e) { log("integrity bad " + (e instanceof TypeError)); }
  try { await fetch(BASE + "/redirect", { integrity: "sha256-" + GOOD256 }); log("integrity redirect no"); }
  catch (e) { log("integrity redirect " + (e instanceof TypeError)); }
  try { await fetch(BASE + "/text", { integrity: "md5-" + BAD }); log("integrity unknown no"); }
  catch (e) { log("integrity unknown " + (e instanceof TypeError)); }
  let noCors = false;
  try { new Request(BASE + "/text", { mode: "no-cors", integrity: "sha256-" + GOOD256 }); }
  catch (e) { noCors = String(e).indexOf("no-cors") >= 0; }
  log("integrity nocors " + noCors);

  // Responses and requests a script makes itself, as a loader builds one to hand on.
  const made = new Response("made body", { status: 201, statusText: "Made", headers: { "X-Made": "1" } });
  log("made " + made.status + " " + made.statusText + " " + made.headers.get("x-made") + " " + made.type
    + " [" + (await made.text()) + "] " + made.bodyUsed);
  const madeJson = Response.json({ a: 1 });
  log("made json " + madeJson.headers.get("content-type") + " " + (await madeJson.json()).a);
  const madeError = Response.error();
  log("made error " + madeError.status + " " + madeError.type + " " + (madeError.body === null));
  const noBody = new Response(null, { status: 204 });
  log("made 204 " + noBody.status + " " + (noBody.body === null));
  const madeRequest = new Request(BASE + "/echo", { method: "POST", body: "x" });
  const madeSignal = madeRequest.signal;
  log("made request " + madeRequest.method + " " + madeRequest.headers.get("content-type")
    + " " + (madeSignal !== null && madeSignal.aborted));

  log("done");
}
main();
`;

const EXPECTED = [
  "status 200 OK ok true",
  "type text/plain",
  "length 24",
  "url true",
  "text [hello from the page dir]",
  "bodyUsed true clone hello from the page dir",
  "sub [sub file]",
  "parent [hello from the page dir]",
  "root [hello from the page dir]",
  "query [hello from the page dir]",
  "binary 4",
  "data [hello data] type text/plain",
  "data plain [a b+c]",
  "file [hello from the page dir]",
  "json application/json 2",
  "headers true text/plain null",
  "headers set one, two text/custom",
  "headers delete false 2",
  "request GET note.txt v no-store include high",
  "request fetched [hello from the page dir] 24",
  "request signal true 1",
  "object headers 1 2",
  "progress progress true 3/9",
  "body stream 200000 bytes in 4 reads of 200000",
  "missing rejected TypeError: Failed to fetch",
  "net 200 OK true basic false",
  `net url ${BASE}/json`,
  "net header application/json json",
  "net json 3 native bodyUsed true",
  "net text [hello network]",
  "net post POST [hello body] text/plain v",
  "net blob PUT [blob data] text/x-blob",
  "net bytes [ABC]",
  "net form [a=1&b=two+words] application/x-www-form-urlencoded;charset=UTF-8",
  "net multipart true true",
  `net redirect 200 true true`,
  "net manual 0 opaqueredirect true true",
  "net redirect error true",
  "net teapot 418 [I am a teapot] false",
  "net missing 404 false",
  "net stream [chunk0,chunk1,chunk2]",
  "net abort AbortError",
  "net preabort AbortError",
  "net request via request used true",
  "net clone true true",
  "net blob type text/plain size 14",
  "net setcookie 1 a=1; Path=/",
  "integrity ok [hello network] 200",
  "integrity strong [hello network]",
  "integrity request [hello network]",
  "integrity bad true",
  "integrity redirect true",
  "integrity unknown true",
  "integrity nocors true",
  "made 201 Made 1 default [made body] true",
  "made json application/json 1",
  "made error 0 error true",
  "made 204 204 true",
  "made request POST text/plain;charset=UTF-8 false",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-fetch-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
writeFileSync(join(dir, "note.txt"), "hello from the page dir\n");
mkdirSync(join(dir, "sub"));
writeFileSync(join(dir, "sub", "deep.txt"), "sub file\n");
writeFileSync(join(dir, "blob.bin"), Buffer.from([1, 2, 3, 4]));
writeFileSync(join(dir, "big.bin"), Buffer.alloc(200000, 7));
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
// The server runs in this process, so the app has to run asynchronously: a spawnSync would block
// this process's event loop and every request would time out.
let stdout = "";
let stderr = "";
const child = spawn(exe, [], {
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "wait 2500" },
});
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
