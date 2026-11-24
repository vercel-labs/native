// A @keyframes a script adds at runtime: a style element's text names keyframes, and an element
// whose animation-name names them animates with them, at a negative delay that puts it partway
// through. This is the path css/support/interpolation-testcommon.js uses.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
</style></head><body>
<div id="quarter"></div>
<div id="half"></div>
<div id="plain"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const style = document.createElement("style") as HTMLStyleElement;
style.textContent = "@keyframes fadeIn { from { opacity: 0 } 50% { opacity: 0.4 } to { opacity: 1 } }";
document.body.appendChild(style);
function run(id: string, delay: string): HTMLElement {
  const el = document.getElementById(id) as HTMLElement;
  el.style.animationName = "fadeIn";
  el.style.animationDuration = "100s";
  el.style.animationDelay = delay;
  el.style.animationTimingFunction = "linear";
  return el;
}
const quarter = run("quarter", "-25s");
const half = run("half", "-50s");
log("quarter " + getComputedStyle(quarter).opacity);
log("half " + getComputedStyle(half).opacity);
// The animation is reported, with the name the runtime sheet gave it.
const runs = quarter.getAnimations();
log("runs " + String(runs.length) + " " + (runs.length > 0 ? runs[0].animationName : "none"));
log("done");
`;

const EXPECTED = [
  // A quarter of the way through, between opacity 0 at 0% and 0.4 at 50%.
  "quarter 0.2",
  // Halfway is exactly the 50% keyframe.
  "half 0.4",
  "runs 1 fadeIn",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-runtime-keyframes-"));
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
