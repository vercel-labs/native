// A layer name may carry any number of dotted parts; the order the tree gives is worked out
// iteratively, so a very deep name can't overflow the stack.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const SEGMENTS = 5000;
const deep = new Array(SEGMENTS).fill("a").join(".");

const PAGE = `<!doctype html>
<html><head><title>layer-depth</title><style>
@layer ${deep} { #t { color: rgb(0, 128, 0); } }
</style></head><body>
<div id="t">x</div>
<div id="u">y</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const colour = (id: string): string => getComputedStyle(document.getElementById(id) as HTMLElement).color;
log("colour " + colour("t"));
// A sheet a script adds gets the same walk at runtime.
const seg = new Array(5000).fill("b").join(".");
const style = document.createElement("style");
style.textContent = "@layer " + seg + " { #u { color: rgb(0, 0, 255); } }";
document.head.appendChild(style);
log("runtime " + colour("u"));
`;

const EXPECTED_LOG = ["colour rgb(0, 128, 0)", "runtime rgb(0, 0, 255)"];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-layer-depth-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed (exit ${r.status})\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
if (got.length === EXPECTED_LOG.length) {
  for (let i = 0; i < got.length; i++) check(EXPECTED_LOG[i], got[i] === EXPECTED_LOG[i], `got ${JSON.stringify(got[i])}`);
} else {
  check(`log lines (${EXPECTED_LOG.length})`, false, `got ${got.length}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
