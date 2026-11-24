// A keyframe's composite: an additive frame adds its value to the one the cascade gives the
// element, and an accumulating one adds it once per iteration. A replacing frame, and no
// composite at all, still replace the value. This is the `composite` a keyframe object carries
// and the one an options object names for every frame.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
#add, #acc, #rep, #opt { width: 40px; height: 4px; background: #0f0; }
@keyframes addW { from { width: 0px; animation-composition: add } to { width: 10px; animation-composition: add } }
#kw { width: 40px; height: 4px; background: #00f; animation: addW 100s linear -50s forwards; }
@keyframes plainW { from { width: 0px } to { width: 10px } }
#el { width: 40px; height: 4px; background: #f80; animation: plainW 100s linear -50s forwards;
  animation-composition: add; }
</style></head><body>
<div id="add"></div>
<div id="acc"></div>
<div id="rep"></div>
<div id="opt"></div>
<div id="kw"></div>
<div id="el"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function w(id: string): string { return getComputedStyle(document.getElementById(id) as HTMLElement).width; }
// Halfway from 0px to 10px, over a cascaded width of 40px.
const add = (document.getElementById("add") as HTMLElement).animate([
  { offset: 0, width: "0px", composite: "add" },
  { offset: 1, width: "10px", composite: "add" },
], { fill: "forwards", duration: 100000, easing: "linear" });
add.pause();
add.currentTime = 50000;
log("add " + w("add"));
// The second iteration accumulates the value again: 40 + 5 + 5.
const acc = (document.getElementById("acc") as HTMLElement).animate([
  { offset: 0, width: "0px", composite: "accumulate" },
  { offset: 1, width: "10px", composite: "accumulate" },
], { fill: "forwards", duration: 100000, iterations: 2, easing: "linear" });
acc.pause();
acc.currentTime = 150000;
log("acc " + w("acc"));
// The default composite replaces the cascaded value.
const rep = (document.getElementById("rep") as HTMLElement).animate([
  { offset: 0, width: "0px" },
  { offset: 1, width: "10px" },
], { fill: "forwards", duration: 100000, easing: "linear" });
rep.pause();
rep.currentTime = 50000;
log("rep " + w("rep"));
// An options object names the composite for every frame.
const opt = (document.getElementById("opt") as HTMLElement).animate([
  { offset: 0, width: "0px" },
  { offset: 1, width: "10px" },
], { fill: "forwards", duration: 100000, easing: "linear", composite: "add" });
opt.pause();
opt.currentTime = 50000;
log("opt " + w("opt"));
// A stylesheet keyframe names its composite inside the block, with animation-composition.
log("kw " + w("kw") + " " + getComputedStyle(document.getElementById("kw") as HTMLElement).getPropertyValue("animation-composition"));
// The element's own animation-composition composes every keyframe that doesn't name its own.
log("el " + w("el"));
log("done");
`;

const EXPECTED = [
  // 40px + half of 10px.
  "add 45px",
  // 40px + the second iteration's half, added twice.
  "acc 50px",
  "rep 5px",
  "opt 45px",
  // A keyframe's animation-composition composes that keyframe; it isn't the element's own value.
  "kw 45px replace",
  "el 45px",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-composite-keyframes-"));
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
