// animate() with keyframes whose property names are computed at run time: the shape a WPT
// interpolation test builds, where the property under test is a variable. Each frame still names
// its offset and composite, and the animation shows the property's value halfway through.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
#d { width: 40px; height: 4px; background: #0f0; }
</style></head><body>
<div id="d"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
// One frame, with the property named by a variable rather than written out.
function frame(property: string, value: string, offset: number, composite: string): any {
  return { offset: offset, composite: composite, [property]: value };
}
const d = document.getElementById("d") as HTMLElement;
const a = d.animate([
  frame("width", "0px", 0, "replace"),
  frame("width", "10px", 1, "replace"),
], { fill: "forwards", duration: 100000, easing: "linear" });
a.pause();
a.currentTime = 50000;
log("width " + getComputedStyle(d).width);
// The same frames, added to the cascaded width instead of replacing it.
const b = d.animate([
  frame("width", "0px", 0, "add"),
  frame("width", "10px", 1, "add"),
], { fill: "forwards", duration: 100000, easing: "linear" });
b.pause();
b.currentTime = 50000;
log("add " + getComputedStyle(d).width);
// What the effect reads back names the property the variable held.
const frames = (a.effect as KeyframeEffect).getKeyframes();
log("frames " + String(frames.length) + " " + Object.keys(frames[1]).join(","));
log("done");
`;

const EXPECTED = [
  "width 5px",
  "add 45px",
  // getKeyframes() reads a frame's declarations back with the computed key in it.
  "frames 2 offset,computedOffset,composite,width",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-animate-computed-keys-"));
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
