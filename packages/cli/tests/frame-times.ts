// The per-stage frame timings NATIVE_FRAME_TIMES asks for: one line per frame on stderr, with the
// stages a frame runs, and nothing at all when the flag is off.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-frame-times-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>frame times</title>
<style>
@keyframes slide { from { transform: translateX(0); } to { transform: translateX(40px); } }
#box { width: 40px; height: 40px; background: #4f46e5; animation: slide 1s linear infinite alternate; }
</style>
</head><body><div id="box"></div><div id="other">text</div></body></html>`);

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) {
  console.error(b.stderr);
  process.exit(1);
}

// Incremental layout appends its own counters (laidOut=, cached=, mismatches=) when it is on, and
// a line may also carry t= (the time into the run) and shape= (the host's text shaping time).
const LINE = /^native: frame (\d+)(?: t=[\d.]+)? style=([\d.]+) anim=([\d.]+) layout=([\d.]+)(?: shape=[\d.]+)? paint=([\d.]+) layers=(\d+) total=([\d.]+)( [a-zA-Z]+=\d+)*$/;

function run(steps: string, times: boolean): { lines: string[]; stderr: string[] } {
  const env: Record<string, string> = { ...process.env, NATIVE_STEPS: steps };
  if (times) env.NATIVE_FRAME_TIMES = "1";
  else delete env.NATIVE_FRAME_TIMES;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  return {
    lines: r.stdout.split("\n").slice(0, -1),
    stderr: r.stderr.split("\n").filter((l) => l.startsWith("native:")),
  };
}

const one = run("frame 16", true);
const timed = one.stderr.filter((l) => l.startsWith("native: frame "));
ok("a timed run reports every frame", timed.length > 0, one.stderr.join("\n"));

let numbered = true;
let stages = true;
let consistent = true;
for (let i = 0; i < timed.length; i++) {
  const m = LINE.exec(timed[i]);
  if (m === null || Number(m[1]) !== i + 1) {
    numbered = false;
    continue;
  }
  const [, , style, anim, layout, paint, layers, total] = m.map(Number);
  // A frame's total covers its stages, which are never negative.
  if (!(style >= 0 && anim >= 0 && layout >= 0 && paint >= 0 && layers >= 0 && total >= 0)) stages = false;
  const sum = style + anim + layout + paint;
  if (total + 0.02 < sum) consistent = false;
}
ok("each line has a frame number, four stages and a layer count", numbered && stages, timed.slice(0, 3).join("\n"));
ok("each line reports the host's text shaping time", timed.every((l) => / shape=[\d.]+ /.test(l)), timed.slice(0, 2).join("\n"));
ok("a frame's total covers the stages it reports", consistent, timed.slice(0, 3).join("\n"));

// The pin flag off: the same run prints no frame lines at all.
const quiet = run("frame 16", false);
ok("no timings without NATIVE_FRAME_TIMES", quiet.stderr.filter((l) => l.includes("frame ")).length === 0, quiet.stderr.join("\n"));

// One more frame step is one more frame for each of the step's own frame calls.
const more = run("frame 16 | frame 32", true).stderr.filter((l) => l.startsWith("native: frame "));
ok("each frame a step runs is timed", more.length === timed.length + 3, `one step: ${timed.length} frames, two steps: ${more.length}`);

// The flag's "0" means off, as the other NATIVE_* pins' does.
const env: Record<string, string> = { ...process.env, NATIVE_STEPS: "frame 16", NATIVE_FRAME_TIMES: "0" };
const off = spawnSync(exe, [], { encoding: "utf8", env });
ok("NATIVE_FRAME_TIMES=0 turns the timings off", off.status === 0 &&
  off.stderr.split("\n").filter((l) => l.startsWith("native: frame ")).length === 0);

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
