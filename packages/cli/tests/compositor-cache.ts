// A filtered layer's image is kept by what it shows: a mask cannot be split, so a page whose
// counter changes inside a mask-image repaints the whole masked chunk every frame, and the static
// blurred line next to it must come back from the cache instead of being filtered again.
//
// On macOS the run composites every frame the window does (NATIVE_COMPOSITOR_LIVE=1) and its
// stats report the filter cache's hits and misses; the presented frame must still match the flat
// replay pixel for pixel.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-compositor-cache-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=360, height=280">
<style>
body { margin: 0; background: #060607; color: #f4f2ee; font: 18px/1.3 sans-serif; }
#masked { position: absolute; left: 16px; top: 16px; width: 300px; height: 180px; overflow: hidden;
  -webkit-mask-image: linear-gradient(180deg, transparent 0, #000 25%, #000 75%, transparent 100%);
  mask-image: linear-gradient(180deg, transparent 0, #000 25%, #000 75%, transparent 100%); }
#still { position: absolute; left: 10px; top: 14px; width: 260px; filter: blur(1.5px); }
#tick { position: absolute; left: 10px; top: 110px; font: 15px/20px monospace; }
</style></head><body>
<div id="masked"><div id="still">a still, filtered line</div><div id="tick">0</div></div>
<script src="app.ts"></script>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `const tick = document.getElementById("tick")!;
let n = 0;
function step(): void {
  tick.textContent = "frame " + ++n;
  requestAnimationFrame(step);
}
requestAnimationFrame(step);
`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

const steps: string[] = [];
for (let i = 1; i <= 24; i++) steps.push(`frame ${i * 16}`);
const flat = join(dir, "flat.png");
const live = join(dir, "live.png");
function runApp(extra: Record<string, string>): string {
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_COMPOSITOR_LIVE: "1", NATIVE_COMPOSITOR_STATS: "1", ...extra },
  });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  return r.stderr;
}
const stderr = runApp({ NATIVE_STEPS: [...steps, `snapshotcomposited ${live}`].join(" | ") });
runApp({ NATIVE_STEPS: steps.join(" | "), NATIVE_SNAPSHOT: flat });

const a = decodePng(flat);
const b = decodePng(live);
ok("both snapshots have the same size", a.w === b.w && a.h === b.h, `${a.w}x${a.h} vs ${b.w}x${b.h}`);
let differing = 0;
let worst = 0;
let inked = 0;
const n = Math.min(a.rgba.length, b.rgba.length);
for (let i = 0; i < n; i += 4) {
  const d = Math.max(
    Math.abs(a.rgba[i] - b.rgba[i]),
    Math.abs(a.rgba[i + 1] - b.rgba[i + 1]),
    Math.abs(a.rgba[i + 2] - b.rgba[i + 2]),
    Math.abs(a.rgba[i + 3] - b.rgba[i + 3]),
  );
  if (d > 1) differing++;
  if (d > worst) worst = d;
  if (a.rgba[i] !== 6 || a.rgba[i + 1] !== 6 || a.rgba[i + 2] !== 7) inked++;
}
ok("the page drew something", inked > 3000, `${inked} pixels are not the background`);
ok("the presented frame holds the filtered layer", differing === 0,
  `${differing} pixels differ by more than one step, worst ${worst}`);

if (process.platform === "darwin") {
  const lines = stderr.split("\n").filter((l) => l.includes("effectcache="));
  const last = lines.length > 0 ? lines[lines.length - 1] : "";
  const m = /effectcache=(\d+)\/(\d+)/.exec(last);
  ok("the stats report the filter cache", m !== null, last);
  if (m !== null) {
    // The counter inside the mask repaints the chunk every frame; the still blurred line is the
    // same picture each time, so the cache answers for it.
    ok("a filtered layer that did not change comes from the cache", Number(m[1]) > 0, last);
  }
}

if (failed > 0) process.exit(1);
