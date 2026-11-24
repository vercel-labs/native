// Web Workers: a module worker started from a source-relative URL, its message delivered as a
// MessageEvent to `onmessage` and to an addEventListener listener, structured clone of a nested
// object, an ArrayBuffer in the transfer list (scriptc copies it for now: the bytes arrive,
// the sender is not detached), a buffer sent back, and terminate().
//   npm test

import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><style>body { margin: 0; }</style></head><body>
<div id="out">idle</div>
<script type="module" src="app.ts"></script>
</body></html>`;

const APP = `
const out = document.getElementById("out")!;
const w = new Worker(new URL("./worker.ts", import.meta.url), { type: "module" });
let first = true;
w.onmessage = (event: MessageEvent): void => {
  if (!first) return;
  first = false;
  const d: any = event.data;
  console.log(\`one \${d.n} \${d.size} \${d.nested} \${event.type} \${d.buf.byteLength}\`);
  w.postMessage({ hi: 41 });
};
w.addEventListener("message", (event: MessageEvent): void => {
  const d: any = event.data;
  if (d.done !== true) return;
  console.log("two " + d.n);
  out.textContent = "done";
  w.terminate();
});
const buffer = new ArrayBuffer(8);
new Uint8Array(buffer)[0] = 42;
w.postMessage({ hi: 1, buffer, nested: { a: [1, 2, 3] } }, [buffer]);
// scriptc cannot move an ArrayBuffer between threads yet, so the sender keeps it.
console.log("after transfer " + buffer.byteLength);
`;

const WORKER = `
let count = 0;
addEventListener("message", (event: MessageEvent): void => {
  const d: any = event.data;
  count++;
  if (count === 1) {
    const out = new ArrayBuffer(4);
    new Uint8Array(out)[0] = 3;
    self.postMessage({ n: d.hi, size: d.buffer.byteLength, nested: d.nested.a.length, type: event.type, buf: out }, [out]);
  } else {
    self.postMessage({ n: d.hi, done: true });
  }
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-worker-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
writeFileSync(join(dir, "worker.ts"), WORKER);
const exe = join(dir, "app");
const build = await new Promise<number>((resolve) => {
  const p = spawn("node", ["compiler/cli.ts", "build", dir, "-o", exe], { stdio: "inherit" });
  p.on("close", (code) => resolve(code ?? 1));
});
if (build !== 0) throw new Error("build failed");

let stdout = "";
let stderr = "";
const child = spawn(exe, [], { env: { ...process.env, NATIVE_STEPS: "wait 500" } });
child.stdout.on("data", (d: Buffer) => { stdout += d.toString(); });
child.stderr.on("data", (d: Buffer) => { stderr += d.toString(); });
const status = await new Promise<number | null>((resolve) => child.on("close", (code) => resolve(code)));
if (status !== 0) throw new Error(`run failed (exit ${status})\n${stderr}`);

const got = stdout.split("\n").filter((line) => line !== "");
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
const expected = [
  "after transfer 8",
  "one 1 8 3 message 4",
  "two 41",
];
check(`log lines (${expected.length})`, got.length === expected.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, expected.length); i++) {
  check(expected[i], got[i] === expected[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
