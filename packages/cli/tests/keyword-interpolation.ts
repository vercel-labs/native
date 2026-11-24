// vertical-align's `baseline` interpolates as the length 0, and a length mixes with a percentage
// through a calc() written the way browsers write it. A discrete change that has nothing to
// interpolate — display, or a size whose other end is auto — transitions only under
// transition-behavior: allow-discrete, while z-index's `auto` transitions with a halfway flip.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=500, height=300"><style>
body { margin: 0; }
.t { display: inline-block; width: 50px; height: 20px; }
</style></head><body>
<span id="v1" class="t">a</span><span id="v2" class="t">b</span><span id="v3" class="t">c</span>
<span id="z1" class="t">d</span><span id="z2" class="t">e</span>
<div id="w1" style="width:auto">f</div><div id="w2" style="width:auto">g</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
// The WPT harness's overshoot easing: cubic-bezier(0, b, 1, b) with b = (8y - 1) / 6.
function easing(y: number): string {
  if (y === 0) return "steps(1, end)";
  if (y === 1) return "steps(1, start)";
  if (y === 0.5) return "linear";
  const b = (8 * y - 1) / 6;
  return "cubic-bezier(0, " + b + ", 1, " + b + ")";
}
function anim(el: HTMLElement, prop: string, from: string, to: string, y: number): void {
  const a = el.animate([{ [prop]: from }, { [prop]: to }], { duration: 100000, fill: "forwards", easing: easing(y) });
  a.pause();
  a.currentTime = 50000;
}
function trans(el: HTMLElement, prop: string, from: string, to: string, y: number, allow: boolean): string {
  const name = prop.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
  (el.style as any)[prop] = from;
  getComputedStyle(el).getPropertyValue(name);
  el.style.transitionDuration = "100s";
  el.style.transitionDelay = "-50s";
  el.style.transitionTimingFunction = easing(y);
  el.style.transitionProperty = name;
  if (allow) el.style.transitionBehavior = "allow-discrete";
  (el.style as any)[prop] = to;
  return getComputedStyle(el).getPropertyValue(name) + " anims " + el.getAnimations().length;
}
const v1 = document.getElementById("v1") as HTMLElement;
anim(v1, "verticalAlign", "baseline", "100px", -0.5);
log("va-initial " + getComputedStyle(v1).verticalAlign);
const v2 = document.getElementById("v2") as HTMLElement;
anim(v2, "verticalAlign", "40px", "40%", -0.5);
log("va-pct-neg " + getComputedStyle(v2).verticalAlign);
const v3 = document.getElementById("v3") as HTMLElement;
anim(v3, "verticalAlign", "40px", "40%", 1);
log("va-pct-end " + getComputedStyle(v3).verticalAlign);
// z-index's auto transitions with a flip at the halfway point, so the from value shows before it.
log("zi-plain " + trans(document.getElementById("z1") as HTMLElement, "zIndex", "auto", "5", -0.3, false));
log("zi-allow " + trans(document.getElementById("z2") as HTMLElement, "zIndex", "auto", "5", -0.3, true));
// A width whose old end is auto has nothing to interpolate: only allow-discrete transitions it.
log("w-plain " + trans(document.getElementById("w1") as HTMLElement, "width", "auto", "100px", 0.5, false));
log("w-allow " + trans(document.getElementById("w2") as HTMLElement, "width", "auto", "100px", -0.3, true));
log("done");
`;

const EXPECTED = [
  "va-initial -50px",
  "va-pct-neg calc(60px - 20%)",
  "va-pct-end 40%",
  "zi-plain auto anims 1",
  "zi-allow auto anims 1",
  "w-plain 100px anims 0",
  "w-allow auto anims 1",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-keyword-interp-"));
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
