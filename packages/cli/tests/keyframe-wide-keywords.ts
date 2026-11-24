// A CSS-wide keyword in a keyframe resolves against the element that runs the animation:
// `inherit` takes the parent's computed value, `initial` the property's own starting value, and
// `unset` either depending on whether the property inherits (text-shadow does). An inline style
// set from script resolves the same way.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=500, height=300"><style>
body { margin: 0; }
.parent { text-shadow: 30px 10px 30px orange; font-size: 40px; color: green; }
.t { text-shadow: 10px 30px 10px orange; }
</style></head><body>
<div class="parent"><span id="a" class="t">A</span><span id="b" class="t">B</span><span id="c" class="t">C</span><span id="d" class="t">D</span></div>
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
// An inline keyword: inherit copies the parent's shadow, initial is the initial value (none).
const a = document.getElementById("a") as HTMLElement;
a.style.setProperty("text-shadow", "inherit");
log("inherit " + getComputedStyle(a).textShadow);
const b = document.getElementById("b") as HTMLElement;
b.style.setProperty("text-shadow", "initial");
log("initial " + getComputedStyle(b).textShadow);
const style = document.createElement("style");
document.body.appendChild(style);
style.textContent = "@keyframes k1 { from { text-shadow: inherit; } to { text-shadow: green 20px 20px 20px; } }" +
  "@keyframes k2 { from { text-shadow: unset; } to { text-shadow: green 20px 20px 20px; } }";
function run(el: HTMLElement, name: string, y: number): void {
  el.style.animationName = name;
  el.style.animationDuration = "100s";
  el.style.animationDelay = "-50s";
  el.style.animationTimingFunction = easing(y);
  log(name + " " + getComputedStyle(el).textShadow);
}
// text-shadow inherits, so unset in a frame is the parent's shadow too.
run(document.getElementById("c") as HTMLElement, "k1", -0.3);
run(document.getElementById("d") as HTMLElement, "k2", 0.6);
log("done");
`;

const EXPECTED = [
  "inherit rgb(255, 165, 0) 30px 10px 30px",
  "initial none",
  "k1 rgb(255, 176, 0) 33px 7px 33px",
  "k2 rgb(102, 143, 0) 24px 16px 24px",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-keyframe-wide-"));
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
