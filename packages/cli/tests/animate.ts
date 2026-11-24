// Element.animate(): keyframes and timing a script gives, run on the frame clock, read back through
// the Animation it returns and reported by getAnimations(); a cancelled animation puts the element
// back to its cascaded value. The frame steps drive the clock, so every value is exact.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
#d { width: 40px; height: 40px; background: #f00; opacity: 0.2; }
</style></head><body>
<div id="d"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const d = document.getElementById("d") as HTMLElement;
const a = d.animate([{ opacity: "0" }, { opacity: "1" }], { duration: 100, fill: "forwards" });
log("start " + a.playState + " " + String(d.getAnimations().length));
const e = a.effect as KeyframeEffect;
log("effect " + String(e !== null) + " " + String(e.target === d) + " " + String(d.getAnimations()[0].effect === e));
const kf = e.getKeyframes();
log("frames " + kf.length + " " + String(kf[0].offset) + " " + String(kf[1].offset) + " " + String(kf[1].opacity));
// Timing reads back, and updateTiming() stretches the run in place.
e.updateTiming({ duration: 200 });
const timing = e.getTiming();
const computed = e.getComputedTiming();
log("timing " + String(timing.duration) + " " + String(timing.iterations) + " " + String(timing.fill));
log("computed " + String(computed.duration) + " " + String(computed.endTime) + " " + String(computed.activeDuration));
let n = 0;
function tick(): void {
  n++;
  log("f" + n + " " + getComputedStyle(d).opacity + " " + a.playState);
  if (n === 5) {
    a.cancel();
    log("cancel " + a.playState);
  }
  if (n < 6) requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
`;

const EXPECTED = [
  // A script's animation is running at once and getAnimations() reports it.
  "start running 1",
  // Its effect names the element, is the one getAnimations() reports, and reads its keyframes.
  "effect true true true",
  "frames 2 0 1 1",
  // updateTiming() replaced the duration the run was made with; the timing reads back.
  "timing 200 1 forwards",
  "computed 200 200 200",
  // At the start of the active phase the first keyframe shows, whatever the style says.
  "f1 0 running",
  // The 200ms run updateTiming() set: a quarter of the way at 50ms.
  "f2 0.25 running",
  // Halfway at 100ms, three quarters at 150, and the end with fill forwards at 200: finished.
  "f3 0.5 running",
  "f4 0.75 running",
  // The end at 200ms: fill forwards keeps the last keyframe and the animation reads finished.
  "f5 1 finished",
  // Cancelling puts the element back to its cascaded opacity and the animation reads idle.
  "cancel idle",
  "f6 0.2 idle",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-animate-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0 | frame 50 | frame 100 | frame 150 | frame 200 | frame 250" };
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
