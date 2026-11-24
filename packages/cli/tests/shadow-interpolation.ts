// text-shadow interpolates per shadow: colour per channel (premultiplied by alpha, so a shadow
// fading in from transparent keeps its hue), offsets and blur arithmetically, with a negative blur
// held at zero. A list that starts as `none` is padded with a transparent shadow of zero length.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=500, height=300"><style>
body { margin: 0; }
.t { display: block; font-size: 40px; color: green; }
#a { text-shadow: black 15px 10px 5px; }
#c { text-shadow: black 10px 10px 10px; }
#d { text-shadow: none; }
</style></head><body>
<div id="a" class="t">A</div><div id="b" class="t">B</div>
<div id="c" class="t">C</div><div id="d" class="t">D</div>
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
function anim(el: HTMLElement, from: string, to: string, y: number): void {
  const a = el.animate([{ textShadow: from }, { textShadow: to }], { duration: 100000, fill: "forwards", easing: easing(y) });
  a.pause();
  a.currentTime = 50000;
}
const a = document.getElementById("a") as HTMLElement;
// Colour and lengths both overshoot; a blur interpolated below zero stays at 0px.
anim(a, "black 15px 10px 5px", "orange -15px -10px 25px", -0.3);
log("a " + getComputedStyle(a).textShadow);
const c = document.getElementById("c") as HTMLElement;
// currentColor is the element's own green, so black to currentColor mixes toward green.
anim(c, "black 10px 10px 10px", "currentColor 10px 10px 10px", 0.6);
log("c " + getComputedStyle(c).textShadow);
const d = document.getElementById("d") as HTMLElement;
anim(d, "green 0px 0px 0px", "green 10px 10px 10px", 0.3);
log("d " + getComputedStyle(d).textShadow);
const b = document.getElementById("b") as HTMLElement;
// A transition out of text-shadow: none: the empty list pads with a transparent shadow, and
// the colour is interpolated premultiplied, so the green comes through at full strength.
getComputedStyle(b).getPropertyValue("text-shadow");
b.style.transitionDuration = "100s";
b.style.transitionDelay = "-50s";
b.style.transitionTimingFunction = easing(0.3);
b.style.transitionProperty = "text-shadow";
b.style.setProperty("text-shadow", "green 20px 20px 20px");
log("b " + getComputedStyle(b).textShadow);
log("done");
`;

// Chrome computes these values; the WPT harness rounds the alpha to two decimals (0.302 to 0.3).
const EXPECTED = [
  "a rgb(0, 0, 0) 24px 16px 0px",
  "c rgb(0, 77, 0) 10px 10px 10px",
  "d rgb(0, 128, 0) 3px 3px 3px",
  "b rgba(0, 128, 0, 0.302) 6px 6px 6px",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-shadow-interp-"));
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
