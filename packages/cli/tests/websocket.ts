// WebSocket: the client against a server this process runs, so the handshake, the frames and the
// close handshake all go over a real socket. The server speaks RFC 6455 itself, which lets it send
// the awkward cases a browser has to survive: a bad accept, a masked frame, invalid UTF-8, a
// connection that never switches protocols, and a subprotocol nobody asked for.
//   npm test

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync } from "node:fs";
import http from "node:http";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { Socket } from "node:net";

const PAGE = `<!doctype html>
<html><head><style>body { margin: 0; }</style></head><body>
<script src="app.ts"></script>
</body></html>`;

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** A server frame, unmasked as a server's frames are. */
function frame(opcode: number, payload: Buffer, fin = true): Buffer {
  const len = payload.length;
  const head = len < 126 ? Buffer.alloc(2) : len < 65536 ? Buffer.alloc(4) : Buffer.alloc(10);
  head[0] = (fin ? 0x80 : 0) | opcode;
  if (len < 126) head[1] = len;
  else if (len < 65536) {
    head[1] = 126;
    head.writeUInt16BE(len, 2);
  } else {
    head[1] = 127;
    head.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([head, payload]);
}

/** One client frame the server read: its opcode and unmasked payload. */
interface ReadFrame { opcode: number; payload: Buffer; end: number }

/** A frame from the client at `start`, or null while the bytes don't hold a whole one. */
function readFrame(buf: Buffer, start: number): ReadFrame | null {
  if (buf.length - start < 2) return null;
  const b0 = buf[start];
  const b1 = buf[start + 1];
  const opcode = b0 & 0x0f;
  let len = b1 & 0x7f;
  let at = start + 2;
  if (len === 126) {
    if (buf.length - at < 2) return null;
    len = buf.readUInt16BE(at);
    at += 2;
  } else if (len === 127) {
    if (buf.length - at < 8) return null;
    len = Number(buf.readBigUInt64BE(at));
    at += 8;
  }
  if ((b1 & 0x80) === 0) return null; // a client's frames are masked
  if (buf.length - at < 4 + len) return null;
  const mask = buf.subarray(at, at + 4);
  at += 4;
  const payload = Buffer.alloc(len);
  for (let i = 0; i < len; i++) payload[i] = buf[at + i] ^ mask[i & 3];
  return { opcode, payload, end: at + len };
}

function accept(key: string): string {
  return createHash("sha1").update(key + GUID).digest("base64");
}

const server = http.createServer((req, res) => {
  res.writeHead(404);
  res.end();
});

server.on("upgrade", (req, socket: Socket) => {
  const path = (req.url ?? "/").split("?")[0];
  const key = String(req.headers["sec-websocket-key"] ?? "");
  if (path === "/refuse") {
    socket.end("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    return;
  }
  let lines = [
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
  ];
  if (path === "/bad") lines.push("Sec-WebSocket-Accept: not-the-right-one");
  else lines.push("Sec-WebSocket-Accept: " + accept(key));
  if (path === "/sub" || path === "/proto") {
    const asked = String(req.headers["sec-websocket-protocol"] ?? "");
    // /proto answers with a protocol nobody named, which the client must refuse.
    const pick = path === "/proto" ? "other" : asked.split(",").map((s) => s.trim()).includes("chat") ? "chat" : "";
    if (pick !== "") lines.push("Sec-WebSocket-Protocol: " + pick);
  }
  socket.write(lines.join("\r\n") + "\r\n\r\n");

  let buffer = Buffer.alloc(0);
  let sentPing = false;
  const send = (opcode: number, payload: Buffer, fin = true): void => { socket.write(frame(opcode, payload, fin)); };

  socket.on("data", (chunk: Buffer) => {
    buffer = Buffer.concat([buffer, chunk]);
    let start = 0;
    while (true) {
      const f = readFrame(buffer, start);
      if (f === null) break;
      start = f.end;
      if (f.opcode === 0x8) {
        socket.write(frame(0x8, f.payload));
        socket.end();
      } else if (f.opcode === 0x9) {
        socket.write(frame(0xA, f.payload));
      } else if (f.opcode === 0xA) {
        if (path === "/frag") send(0x1, Buffer.from("pong"));
      } else if (f.opcode === 0x1 || f.opcode === 0x2) {
        if (path === "/frag" && f.payload.toString() === "split") {
          send(0x1, Buffer.from("sp"), false);
          send(0x0, Buffer.from("lit"));
          if (!sentPing) {
            sentPing = true;
            send(0x9, Buffer.from("p"));
          }
          continue;
        }
        socket.write(frame(f.opcode, f.payload));
      }
    }
    buffer = buffer.subarray(start);
  });
  socket.on("error", () => {});

  if (path === "/frag") {
    send(0x1, Buffer.from("Hel"), false);
    send(0x0, Buffer.from("lo"));
  } else if (path === "/close") {
    send(0x8, Buffer.from([0x0f, 0xa0, 0x62, 0x79, 0x65])); // 4000 "bye"
  } else if (path === "/utf8") {
    send(0x1, Buffer.from([0xff, 0xfe]));
  } else if (path === "/masked") {
    // A server frame with the mask bit set; the client must fail the connection.
    const payload = Buffer.from("no");
    const mask = Buffer.from([1, 2, 3, 4]);
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
    socket.write(Buffer.concat([Buffer.from([0x81, 0x80 | payload.length]), mask, payload]));
  } else if (path === "/big") {
    send(0x1, Buffer.from("x".repeat(200)));
  }
});

await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
const address = server.address();
const port = address !== null && typeof address === "object" ? address.port : 0;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function once(ws: WebSocket, type: string): Promise<any> {
  return new Promise((resolve) => {
    const fn = (e: any): void => { ws.removeEventListener(type, fn); resolve(e); };
    ws.addEventListener(type, fn);
  });
}
const BASE = "ws://127.0.0.1:${port}";

async function main(): Promise<void> {
  // A connection that opens, echoes both kinds of message and closes with a code and reason.
  const a = new WebSocket(BASE + "/echo", ["chat", "superchat"]);
  log("a1 " + a.readyState + " " + a.url);
  try { a.send("early"); } catch (e: any) { log("a2 " + e.message.startsWith("InvalidStateError")); }
  await once(a, "open");
  log("a3 " + JSON.stringify(a.protocol) + " " + a.extensions.length + " " + a.bufferedAmount);
  const m1 = once(a, "message");
  a.send("hello");
  log("a4 " + (await m1).data);
  a.binaryType = "blob";
  const m2 = once(a, "message");
  a.send(new Uint8Array([0, 1, 2, 255]));
  const e2 = await m2;
  log("a5 " + (e2.data instanceof Blob) + " " + e2.data.size);
  a.binaryType = "arraybuffer";
  const m3 = once(a, "message");
  a.send(new Uint8Array([9, 8, 7]).buffer);
  const e3 = await m3;
  log("a6 " + (e3.data instanceof ArrayBuffer) + " " + new Uint8Array(e3.data).join(","));
  const m4 = once(a, "message");
  a.send(new Blob(["blobdata"]));
  const e4 = await m4;
  log("a7 " + new TextDecoder().decode(new Uint8Array(e4.data)));
  const c1p = once(a, "close");
  a.close(4001, "going");
  log("a8 " + a.readyState);
  const c1 = await c1p;
  log("a9 " + c1.code + " " + c1.reason + " " + c1.wasClean + " " + a.readyState);
  a.send("ignored");

  // A subprotocol the server chooses from the list.
  const b = new WebSocket(BASE + "/sub", "chat");
  await once(b, "open");
  log("b1 " + b.protocol);
  const bclose = once(b, "close");
  b.close(1000);
  await bclose;

  // A handshake with the wrong accept never opens.
  const c = new WebSocket(BASE + "/bad");
  let cError = false;
  c.addEventListener("error", () => { cError = true; });
  const cc = await once(c, "close");
  log("c1 " + cError + " " + cc.code + " " + cc.wasClean);

  // A message split into fragments, and a ping answered with a pong.
  const d = new WebSocket(BASE + "/frag");
  await once(d, "open");
  log("d1 " + (await once(d, "message")).data);
  const dm = once(d, "message");
  d.send("split");
  log("d2 " + (await dm).data);
  log("d3 " + (await once(d, "message")).data);
  const dclose = once(d, "close");
  d.close(1000);
  await dclose;

  // The server closes the connection.
  const e = new WebSocket(BASE + "/close");
  const ec = await once(e, "close");
  log("e1 " + ec.code + " " + ec.reason + " " + ec.wasClean);

  // Text that isn't UTF-8, and a masked server frame, both fail the connection.
  const f = new WebSocket(BASE + "/utf8");
  let fError = false;
  f.addEventListener("error", () => { fError = true; });
  const fc = await once(f, "close");
  log("f1 " + fError + " " + fc.code + " " + fc.wasClean);
  const g = new WebSocket(BASE + "/masked");
  const gc = await once(g, "close");
  log("g1 " + gc.code + " " + gc.wasClean);

  // A message longer than 125 bytes, so its frame's length is 16-bit.
  const h = new WebSocket(BASE + "/big");
  log("h1 " + (await once(h, "message")).data.length);
  h.close(1000);

  // A server that never switches protocols.
  const i = new WebSocket(BASE + "/refuse");
  let iError = false;
  i.addEventListener("error", () => { iError = true; });
  const ic = await once(i, "close");
  log("i1 " + iError + " " + ic.code + " " + ic.wasClean);

  // A server that picks a subprotocol the client didn't ask for.
  const j = new WebSocket(BASE + "/proto", "chat");
  const jc = await once(j, "close");
  log("j1 " + jc.code + " " + jc.wasClean);

  // The constructor's own checks.
  try { new WebSocket("http://127.0.0.1/"); } catch (e: any) { log("k1 " + e.message.startsWith("SyntaxError")); }
  try { new WebSocket("ws://127.0.0.1/#frag"); } catch (e: any) { log("k2 " + e.message.startsWith("SyntaxError")); }
  try { new WebSocket(BASE + "/echo", ["dup", "dup"]); } catch (e: any) { log("k3 " + e.message.startsWith("SyntaxError")); }
  const k = new WebSocket(BASE + "/echo");
  try { k.close(2000); } catch (e: any) { log("k4 " + e.message.startsWith("InvalidAccessError")); }
  const kp = once(k, "close");
  k.close();
  log("k5 " + (await kp).code);

  log("done");
}
main();
`;

const EXPECTED = [
  "a1 0 ws://127.0.0.1:" + port + "/echo",
  "a2 true",
  "a3 \"\" 0 0",
  "a4 hello",
  "a5 true 4",
  "a6 true 9,8,7",
  "a7 blobdata",
  "a8 2",
  "a9 4001 going true 3",
  "b1 chat",
  "c1 true 1006 false",
  "d1 Hello",
  "d2 split",
  "d3 pong",
  "e1 4000 bye true",
  "f1 true 1006 false",
  "g1 1006 false",
  "h1 200",
  "i1 true 1006 false",
  "j1 1006 false",
  "k1 true",
  "k2 true",
  "k3 true",
  "k4 true",
  "k5 1006",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-websocket-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = await new Promise<number>((resolve) => {
  const p = spawn("node", ["compiler/cli.ts", "build", dir, "-o", exe], { stdio: "inherit" });
  p.on("close", (code) => resolve(code ?? 1));
});
if (build !== 0) throw new Error("build failed");

let stdout = "";
let stderr = "";
const child = spawn(exe, [], { env: { ...process.env, NATIVE_STEPS: "wait 4000" } });
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
