// The composited snapshot against the flat one: the same frame built from its layers must land on
// the same pixels. Layers that don't move composite one pixel for one, and an integer translation
// moves a raster without resampling it, so the diff can only be the last bit of an antialiased edge.
// Linux draws it with the software compositor; macOS with the window path's cached rasters.
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

const dir = mkdtempSync(join(tmpdir(), "native-compositor-exact-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>composited</title>
<style>
body { margin: 0; background: #ffffff; font: 14px/1.4 system-ui; }
.wc { width: 120px; height: 60px; margin: 10px; background: #eef2ff; border: 1px solid #c7d2fe; border-radius: 8px; }
@keyframes move { from { transform: translateX(0); } to { transform: translateX(40px); } }
.mover { width: 100px; height: 50px; margin: 10px; background: #dcfce7; animation: move 1s linear infinite alternate; }
.fixed { position: fixed; right: 10px; bottom: 10px; width: 40px; height: 40px; background: #fef3c7; }
</style>
</head><body>
<div class="wc" style="will-change: transform">transform layer</div>
<div class="wc" style="will-change: opacity">opacity layer</div>
<div class="mover">moving layer</div>
<div class="wc"><span style="will-change: transform">nested layer</span></div>
<div class="wc" style="overflow: hidden"><span style="will-change: opacity">clipped layer</span></div>
<div class="fixed">fixed</div>
<div style="margin: 10px">a run of text with no box of its own to hold it</div>
</body></html>`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

// 500 ms into a 1s animation is 20px of travel: a whole number of device pixels at the 2x
// snapshot scale, which a raster moves without resampling.
const flat = join(dir, "flat.png");
const composited = join(dir, "composited.png");
const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_STEPS: "frame 250 | frame 500",
    NATIVE_SNAPSHOT: flat,
    NATIVE_SNAPSHOT_COMPOSITED: composited,
  },
});
if (run.status !== 0) {
  console.error(run.stderr);
  process.exit(1);
}

const a = decodePng(flat);
const b = decodePng(composited);
ok("both snapshots have the same size", a.w === b.w && a.h === b.h, `${a.w}x${a.h} vs ${b.w}x${b.h}`);

// Drawing a raster into the page rounds antialiased edges once more than drawing the commands
// there did, which is within the one least-significant-bit tolerance a composited layer gets. A
// structural mistake — a layer in the wrong place, order or layer — moves whole pixels much further.
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
  if (d > 0) differing++;
  if (d > worst) worst = d;
  if (a.rgba[i] !== 255 || a.rgba[i + 1] !== 255 || a.rgba[i + 2] !== 255) inked++;
}
ok("the fixture drew something", inked > 10000, `${inked} pixels are not white`);
ok("the composited frame matches the flat one to one step", worst <= 1, `${differing} pixels differ, worst ${worst}`);

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
