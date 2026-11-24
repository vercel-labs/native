// Timing functions overshoot: the WPT interpolation harness samples an animation at half way with
// a cubic-bezier whose control points leave [0, 1], so the eased progress can be negative or past
// 1 and the property interpolates past its endpoints. A keyframe list may also name only one
// endpoint, leaving the other to the element's own value (a neutral keyframe), and an integer
// property like z-index rounds the mixed value at each sample, as a browser computes it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=200"><style>
body { margin: 0; }
#v { position: absolute; top: 50px; width: 100px; height: 100px; background: #000; vertical-align: 10px; }
#z { position: relative; z-index: -2; }
#e { position: absolute; top: 50px; left: 200px; width: 100px; height: 100px; background: #000; vertical-align: 10px; }
#f { position: absolute; top: 50px; left: 300px; width: 100px; height: 100px; background: #000; vertical-align: 10px; }
#d { display: block; }
</style></head><body>
<div id="v"></div><div id="z"></div><div id="e"></div><div id="f"></div><div id="d"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const v = document.getElementById("v") as HTMLElement;
const z = document.getElementById("z") as HTMLElement;
const e = document.getElementById("e") as HTMLElement;
const f = document.getElementById("f") as HTMLElement;
const d = document.getElementById("d") as HTMLElement;
// The harness's overshoot easing: cubic-bezier(0, b, 1, b) with b = (8y - 1) / 6.
function easing(y: number): string {
  if (y === 0) return "steps(1, end)";
  if (y === 1) return "steps(1, start)";
  if (y === 0.5) return "linear";
  const b = (8 * y - 1) / 6;
  return "cubic-bezier(0, " + b + ", 1, " + b + ")";
}
function sample(el: HTMLElement, keyframes: any[], y: number): string {
  const a = el.animate(keyframes, { duration: 100000, fill: "forwards", easing: easing(y) });
  a.pause();
  a.currentTime = 50000;
  return "";
}
sample(v, [{ offset: 0, verticalAlign: "10px" }, { offset: 1, verticalAlign: "40px" }], -0.5);
log("va " + getComputedStyle(v).verticalAlign);
sample(z, [{ offset: 0, zIndex: -2 }, { offset: 1, zIndex: 5 }], -0.3);
log("z " + getComputedStyle(z).zIndex);
sample(z, [{ offset: 0, zIndex: -5 }, { offset: 1, zIndex: 5 }], 1.5);
log("z-far " + getComputedStyle(z).zIndex);
// A keyframe list that names only one endpoint leaves the other to the element's own value: the
// browser's neutral 0% and 100% frames.
sample(e, [{ verticalAlign: "40px" }], -0.5);
log("va-neutral " + getComputedStyle(e).verticalAlign);
sample(f, [{ offset: 0, verticalAlign: "40px" }], 0.5);
log("va-to " + getComputedStyle(f).verticalAlign);
sample(d, [{ offset: 0, display: "none" }, { offset: 1, display: "block" }], 0);
log("d " + getComputedStyle(d).display);
log("done");
`;

// At half way the overshoot easing for -0.5 is -0.5, so 10px to 40px extrapolates to -5px. For
// z-index, -2 to 5 at -0.3 is -4.1, which rounds to -4; -5 to 5 at 1.5 is 10. A keyframe list that
// names only 40px runs from the element's own 10px, which at -0.5 is -5px; naming only the 0%
// frame runs to the element's value, which from 40px to 10px at half way is 25px. A discrete
// value crossed at eased progress 0 stays at its from value.
const EXPECTED = [
  "va -5px",
  "z -4",
  "z-far 10",
  "va-neutral -5px",
  "va-to 25px",
  "d none",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-interp-overshoot-"));
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
