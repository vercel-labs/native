// A keyframe's currentColor is the -1 sentinel until the frame is applied, so it reaches for the
// element's own colour at sample time instead of being mixed as a number; `inherit` in a frame
// copies the parent's computed colour the same way. Every value here is what Chrome computes.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=500, height=300"><style>
body { margin: 0; }
.paused { animation-duration: 4s; animation-timing-function: linear; animation-delay: -2s; animation-play-state: paused; }
#container { color: rgb(80, 0, 0); }
#first { animation-name: first-anim; color: rgb(60, 0, 0); }
#second { animation-name: second-anim; }
@keyframes first-anim { from { column-rule-color: currentColor; } to { column-rule-color: rgb(0, 60, 0); } }
@keyframes second-anim { from { column-rule-color: inherit; } to { column-rule-color: rgb(0, 0, 80); } }
</style></head><body>
<div id="container"><div id="first" class="paused"></div><div id="second" class="paused"></div></div>
<div id="v1" style="vertical-align: baseline">x</div><div id="v2" style="vertical-align: baseline">x</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const first = document.getElementById("first") as HTMLElement;
// Half way from currentColor (the element's rgb(60, 0, 0)) to rgb(0, 60, 0).
log("first " + getComputedStyle(first).columnRuleColor);
first.style.color = "rgb(0, 0, 60)";
log("first-changed " + getComputedStyle(first).columnRuleColor);
const container = document.getElementById("container") as HTMLElement;
const second = document.getElementById("second") as HTMLElement;
// Half way from the parent's computed colour (rgb(80, 0, 0)) to rgb(0, 0, 80).
log("second " + getComputedStyle(second).columnRuleColor);
container.style.columnRuleColor = "rgb(0, 80, 0)";
log("second-changed " + getComputedStyle(second).columnRuleColor);
// A pair that can't be interpolated (baseline to a length) transitions only where
// transition-behavior allows a discrete change.
function discrete(el: HTMLElement, allow: boolean): string {
  getComputedStyle(el).verticalAlign;
  el.style.transitionDuration = "1s";
  el.style.transitionDelay = "0s";
  el.style.transitionTimingFunction = "linear";
  el.style.transitionProperty = "vertical-align";
  if (allow) el.style.transitionBehavior = "allow-discrete";
  el.style.verticalAlign = "10px";
  return "anims " + el.getAnimations().length;
}
log("normal " + discrete(document.getElementById("v1") as HTMLElement, false));
log("allow " + discrete(document.getElementById("v2") as HTMLElement, true));
log("done");
`;

const EXPECTED = [
  "first rgb(30, 30, 0)",
  "first-changed rgb(0, 30, 30)",
  "second rgb(40, 0, 40)",
  "second-changed rgb(0, 40, 40)",
  "normal anims 0",
  "allow anims 1",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-keyframe-currentcolor-"));
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
