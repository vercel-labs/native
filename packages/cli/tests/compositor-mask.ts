// A masked layer is kept: a page that repaints every frame keeps the tiles of a subtree under a
// mask-image when nothing in it changed. The chunk that holds the mask holds a layer ref where the
// walk can't split, so its key has to follow the layer's commands; with no key it is rastered on
// every frame, and a frame that only updated the recorded transform inside it would draw the
// raster the last paint made.
//
// On macOS the run composites every frame the way the window does (NATIVE_COMPOSITOR_LIVE=1), so
// the stats come from the window's own tile cache: the animated counter is rastered, the masked
// layer is kept, and the presented frame still matches the flat replay.
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

const lines = 5;
const dir = mkdtempSync(join(tmpdir(), "native-compositor-mask-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=360, height=280">
<style>
body { margin: 0; background: #060607; color: #f4f2ee; font: 20px/1.2 sans-serif; }
#masked { position: absolute; left: 20px; top: 20px; width: 240px; height: 140px; overflow: hidden;
  -webkit-mask-image: linear-gradient(180deg, transparent 0, #000 30%, #000 70%, transparent 100%);
  mask-image: linear-gradient(180deg, transparent 0, #000 30%, #000 70%, transparent 100%); }
#layer { position: absolute; left: 0; top: 0; width: 240px; will-change: transform; }
#layer p { margin: 0; padding: 4px 0; }
#tick { position: absolute; left: 20px; top: 190px; font: 13px/18px monospace; }
</style></head><body>
<div id="masked"><div id="layer">${Array.from({ length: lines }, (_, i) => `<p>static line ${i + 1}</p>`).join("")}</div></div>
<div id="tick">0</div>
<script src="app.ts"></script>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `const tick = document.getElementById("tick")!;
let n = 0;
// The counter changes every frame, so every frame paints; the masked layer never changes.
function step(): void {
  tick.textContent = String(++n);
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
ok("the page drew something", inked > 5000, `${inked} pixels are not the background`);
ok("the presented frame holds every chunk of the paint", differing === 0,
  `${differing} pixels differ by more than one step, worst ${worst}`);

if (process.platform === "darwin") {
  const stats = stderr.split("\n").filter((l) => l.startsWith("native: composite chunks="));
  ok("the frames went through the window's compositor", stats.length >= steps.length, `${stats.length} frames`);
  const last = stats.length > 0 ? stats[stats.length - 1] : "";
  const m = /chunks=(\d+) .*kept=(\d+) rastered=(\d+)/.exec(last);
  ok("the last frame was chunked", m !== null && Number(m[1]) >= 2, last);
  if (m !== null) {
    // The counter's chunk is the one that changed; the masked layer's chunk is kept even though a
    // layer ref stands where the walk can't split it.
    ok("a masked layer keeps its tiles while the page repaints", Number(m[2]) >= 1 && Number(m[3]) <= 1, last);
  }
}

if (failed > 0) process.exit(1);
