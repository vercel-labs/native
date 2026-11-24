// Blob: parts of strings, buffers and other blobs copied into one run of bytes, its type, and
// text(), arrayBuffer(), bytes(), slice() and stream() as a browser reads it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"></head>
<body><script src="app.ts"></script></body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
async function main(): Promise<void> {
  const b = new Blob([
    "hi ",
    new Uint8Array([0x74, 0x68, 0x65, 0x72, 0x65]),
    new Blob(["!"], { type: "inner" }),
  ], { type: "Text/Plain" });
  log("size " + b.size + " type " + b.type);
  log("text " + (await b.text()));
  log("bytes " + (await b.bytes()).join(","));
  log("arraybuffer " + (await b.arrayBuffer()).byteLength);
  const outer = b.slice(3, 8);
  log("slice " + (await outer.text()) + " " + outer.size);
  log("slice type " + new Blob(["x"], { type: "A/B" }).slice(0, 1, "C/D").type);
  log("slice back " + (await b.slice(-6, -1).text()));
  log("slice clamp " + b.slice(-100, 100).size + " " + b.slice(5, 2).size + " " + b.slice(NaN).size);
  const del = new Blob([], { type: "a\u007fb" });
  log("type del " + del.type.length + " " + del.type.charCodeAt(1));
  const high = new Blob([], { type: "h\u00e9llo" });
  log("type high [" + high.type + "]");
  const empty = new Blob();
  log("empty " + empty.size + " [" + empty.type + "]");
  let bad = "none";
  try { new Blob([1 as any]); } catch (e) { bad = (e as Error).name; }
  log("bad part " + bad);
  const reader = b.stream().getReader();
  let total = 0;
  for (;;) {
    const step = await reader.read();
    if (step.done) break;
    total += step.value.length;
  }
  log("stream " + total);
  const response = new Response(b);
  const copy = await response.blob();
  log("response " + copy.size + " " + (await copy.text()));
  log("done");
}
main();
`;

const EXPECTED = [
  "size 9 type text/plain",
  "text hi there!",
  "bytes 104,105,32,116,104,101,114,101,33",
  "arraybuffer 9",
  "slice there 5",
  "slice type c/d",
  "slice back there",
  "slice clamp 9 0 9",
  "type del 3 127",
  "type high []",
  "empty 0 []",
  "bad part TypeError",
  "stream 9",
  "response 9 hi there!",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-blob-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

// A run with steps and no snapshot ends on its own; the wait lets the script's promise chain
// log every line first.
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "wait 300" };
delete env.NATIVE_SNAPSHOT;
const run = spawnSync(exe, [], { encoding: "utf8", env, timeout: 60000 });
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const lines = run.stdout.split("\n").slice(0, -1);
check("log lines", lines.length === EXPECTED.length, `got ${lines.length}`);
for (let i = 0; i < Math.min(lines.length, EXPECTED.length); i++) {
  check(EXPECTED[i], lines[i] === EXPECTED[i], `got ${JSON.stringify(lines[i])}`);
}

if (failed > 0) {
  console.error(`\n${failed} checks failed`);
  process.exit(1);
}
console.log("\nall passed");
