// !important against animations and transitions, and fractional iteration counts: an important
// declaration beats a running CSS animation (a transition still beats it), and an animation with a
// negative delay and a fractional iteration count sits where Chrome puts it. Both are the WPT
// cases animation-important-with-transition.html and animation-iteration-count-010.html.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; font: 13px monospace; }
@keyframes changeColor { from { color: rgb(0, 0, 255) } to { color: rgb(0, 0, 255) } }
#t1 { color: rgb(255, 0, 0) !important; transition: color 1000s linear; animation: changeColor 1000s forwards; }
#t2 { color: rgb(0, 128, 0) !important; transition: color 1000s linear; }
#t2.red { color: rgb(255, 0, 0) !important; }
@keyframes keyframes { from { background: green } to { background: red } }
.iter { animation: 1s -2s infinite paused keyframes; width: 20px; height: 20px; }
</style></head><body>
<div id="t1">Test</div>
<div id="t2">Test</div>
<div class="iter" id="i1" style="animation-iteration-count: 1"></div>
<div class="iter" id="i2" style="animation-iteration-count: 2"></div>
<div class="iter" id="i3" style="animation-iteration-count: 2.1"></div>
<div class="iter" id="i4" style="animation-iteration-count: 3"></div>
<div class="iter" id="i5" style="animation-iteration-count: infinite"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const color = (id: string): string => getComputedStyle(document.getElementById(id)!).getPropertyValue("color");
const bg = (id: string): string => getComputedStyle(document.getElementById(id)!).getPropertyValue("background-color");
log("t1 " + color("t1"));
log("iter " + bg("i1") + " " + bg("i2") + " " + bg("i3") + " " + bg("i4") + " " + bg("i5"));
const t2 = document.getElementById("t2")!;
t2.className = "red";
log("t2 " + color("t2"));
`;

const EXPECTED = [
  // The animation on color runs, but red !important wins.
  "t1 rgb(255, 0, 0)",
  // A 1s duration with a -2s delay is two iterations in: 1 and 2 are finished (transparent), and
  // 2.1 is at the very start of its third iteration, so the from keyframe's green shows.
  "iter rgba(0, 0, 0, 0) rgba(0, 0, 0, 0) rgb(0, 128, 0) rgb(0, 128, 0) rgb(0, 128, 0)",
  // The transition from green to red runs over the new !important value, so the read isn't red yet.
  "t2 rgb(0, 128, 0)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-important-animation-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1 | frame 2" };
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
