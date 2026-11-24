// The compiler's frontend is a JavaScript program, and a large app — a React component library's
// page — needs more heap than the default. The build gives scriptc most of the machine's memory,
// up to 8 GB, unless the environment already names a heap. A stub compiler records what it got.
//   npm test

import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { build, scriptcHeapMb } from "../compiler/build.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const GB = 1024 * 1024 * 1024;
check("a 16 GB machine gets the 8 GB cap", scriptcHeapMb(16 * GB) === 8192, String(scriptcHeapMb(16 * GB)));
check("an 8 GB machine gets most of it", scriptcHeapMb(8 * GB) === 6144, String(scriptcHeapMb(8 * GB)));
check("a small machine still gets a floor of 2 GB", scriptcHeapMb(2 * GB) === 2048, String(scriptcHeapMb(2 * GB)));

const dir = mkdtempSync(join(tmpdir(), "native-compiler-heap-"));
writeFileSync(join(dir, "index.html"),
  `<!doctype html><html><head><title>Heap</title></head><body><script src="app.ts"></script></body></html>`);
writeFileSync(join(dir, "app.ts"), `console.log("hi");\n`);
mkdirSync(join(dir, "out"));
const record = join(dir, "node-options.txt");
const stub = join(dir, "stub-scriptc");
writeFileSync(stub, `#!/bin/sh\nprintf '%s' "$NODE_OPTIONS" > ${JSON.stringify(record)}\nexit 1\n`);
chmodSync(stub, 0o755);

/** Builds the app with the stub compiler and returns the NODE_OPTIONS it was given. */
function recordHeap(preset: string | undefined): string {
  const previousScriptc = process.env["NATIVE_SCRIPTC"];
  const previousOptions = process.env["NODE_OPTIONS"];
  process.env["NATIVE_SCRIPTC"] = stub;
  if (preset === undefined) delete process.env["NODE_OPTIONS"];
  else process.env["NODE_OPTIONS"] = preset;
  try {
    build(dir, join(dir, "out", "heap"));
  } catch {
    // The stub refuses; what it recorded is the point of the run.
  } finally {
    if (previousScriptc === undefined) delete process.env["NATIVE_SCRIPTC"];
    else process.env["NATIVE_SCRIPTC"] = previousScriptc;
    if (previousOptions === undefined) delete process.env["NODE_OPTIONS"];
    else process.env["NODE_OPTIONS"] = previousOptions;
  }
  try {
    return readFileSync(record, "utf8");
  } catch {
    return "";
  }
}

const chosen = recordHeap(undefined);
const m = /--max-old-space-size=(\d+)/.exec(chosen);
check("the compiler is given a heap", m !== null, JSON.stringify(chosen));
check("the heap is a large one", m !== null && Number(m[1]) >= 2048 && Number(m[1]) <= 8192, chosen);

const preset = recordHeap("--max-old-space-size=1234");
check("a heap the environment chose is kept", /--max-old-space-size=1234/.test(preset), JSON.stringify(preset));
check("no second heap is added to it", (preset.match(/--max-old-space-size/g) ?? []).length === 1, JSON.stringify(preset));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
