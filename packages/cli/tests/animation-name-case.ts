// An animation name is case-sensitive, as CSS identifiers are: @keyframes fooBar and
// animation-name: fooBar find each other, and lookups differ from FooBar. The computed
// animation-name reads back as written.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
@keyframes fooBar { from { opacity: 0 } to { opacity: 1 } }
@keyframes plain { from { opacity: 1 } to { opacity: 0 } }
#d { width: 40px; height: 40px; background: #f00; animation: fooBar 1000ms linear; }
#e { width: 40px; height: 40px; background: #00f; animation-name: plain; animation-duration: 1000ms; }
</style></head><body>
<div id="d"></div>
<div id="e"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const d = document.getElementById("d") as HTMLElement;
const e = document.getElementById("e") as HTMLElement;
const runs = d.getAnimations();
// Read by property name: the camelCase accessors arrive with the accessor sweep.
log("name " + getComputedStyle(d).getPropertyValue("animation-name") + " " + getComputedStyle(e).getPropertyValue("animation-name"));
log("runs " + String(runs.length) + " " + (runs.length > 0 ? runs[0].animationName : "none"));
log("other " + String(e.getAnimations().length));
log("done");
`;

const EXPECTED = [
  // The case is kept through the cascade and the script's read.
  "name fooBar plain",
  "runs 1 fooBar",
  "other 1",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-animation-name-case-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
