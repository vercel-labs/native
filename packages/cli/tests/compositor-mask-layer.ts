// A mask the compositor groups into one chunk still draws every command of the layers inside it.
// The walk makes a mask and everything it holds one chunk; the chunk is replayed as the range of
// its list between two indices, and a layer reference in that range replays the layer's own list.
// The range's end belongs to the list the mask sits in, so it must not cut the layer short.
//   npm test
// On macOS the frame is the window's own (NATIVE_COMPOSITOR_LIVE=1: the tile cache, the raster
// pool and the Metal backend, into a texture). The same page is snapshotted flat, and every box
// drawn inside the masked layer is required to be in the composite.

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

const dir = mkdtempSync(join(tmpdir(), "native-compositor-mask-layer-"));

// The boxes sit in the opaque part of the mask, so each one keeps its own colour there.
const COLUMNS = 5, ROWS = 5, BOX_W = 24, BOX_H = 16, GAP = 8;
const boxes: { x: number; y: number; r: number; g: number; b: number }[] = [];
let markup = "";
for (let row = 0; row < ROWS; row++) {
  for (let col = 0; col < COLUMNS; col++) {
    const i = row * COLUMNS + col;
    const r = (37 * i + 40) % 256, g = (59 * i + 30) % 256, b = (101 * i + 20) % 256;
    const x = GAP + col * (BOX_W + GAP), y = GAP + row * (BOX_H + GAP);
    boxes.push({ x, y, r, g, b });
    markup += `<div class="box" style="left: ${x}px; top: ${y}px; background: rgb(${r}, ${g}, ${b})"></div>`;
  }
}

writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="native-window" content="width=320, height=200">
<title>Mask layer</title>
<style>
html, body { margin: 0; width: 320px; height: 200px; background: #ffffff; }
#masked { position: absolute; left: 0; top: 0; width: 320px; height: 200px;
          mask-image: linear-gradient(to right, #000000 60%, transparent 100%); }
#layer { position: absolute; left: 0; top: 0; width: 320px; height: 200px; will-change: transform; }
.box { position: absolute; width: 24px; height: 16px; border: 2px solid #000000; }
</style></head><body>
<div id="masked"><div id="layer">${markup}</div></div>
</body></html>`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  console.log("FAIL the app builds");
  console.log("\n1 failed");
  process.exit(1);
}

const steps = "frame 50 | frame 100";
const flat = join(dir, "flat.png");
const composited = join(dir, "composited.png");
// The frame the last step presented, as the window draws it.
const live = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_COMPOSITOR_LIVE: "1",
    NATIVE_COMPOSITOR_STATS: "1",
    NATIVE_STEPS: `${steps} | snapshotcomposited ${composited}`,
  },
});
if (live.status !== 0) {
  console.error(live.stderr);
  console.log("FAIL the app runs");
  console.log("\n1 failed");
  process.exit(1);
}
// The flat replay of the page those steps left.
const replay = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: flat },
});
if (replay.status !== 0) {
  console.error(replay.stderr);
  console.log("FAIL the app runs");
  console.log("\n1 failed");
  process.exit(1);
}

const a = decodePng(flat);
const b = decodePng(composited);
ok("both snapshots have the same size", a.w === b.w && a.h === b.h, `${a.w}x${a.h} vs ${b.w}x${b.h}`);

let differing = 0;
let worst = 0;
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
}
ok("the composited frame matches the flat one to one step", worst <= 1, `${differing} pixels differ, worst ${worst}`);

// Every box is in the composite at its full colour: a layer the mask's chunk cut short loses its
// later commands, which shows as the page's white behind the boxes that went missing.
let missing = 0;
let first = "";
for (const box of boxes) {
  const px = 2 * (box.x + BOX_W / 2), py = 2 * (box.y + BOX_H / 2);
  const at = (py * b.w + px) * 4;
  const got = [b.rgba[at], b.rgba[at + 1], b.rgba[at + 2]];
  const want = [box.r, box.g, box.b];
  const off = Math.max(Math.abs(got[0] - want[0]), Math.abs(got[1] - want[1]), Math.abs(got[2] - want[2]));
  if (off > 2) {
    missing++;
    if (first === "") first = `at ${box.x},${box.y}: got rgb(${got.join(", ")}), want rgb(${want.join(", ")})`;
  }
}
ok("every box inside the masked layer is in the composite", missing === 0, `${missing} of ${boxes.length} missing; ${first}`);

if (process.platform === "darwin") {
  // The picture above is the window's own compositor's, not a fresh flat replay of the same paint.
  const lines = live.stderr.split("\n").filter((l) => l.startsWith("native: composite chunks="));
  const last = lines.length > 0 ? lines[lines.length - 1] : "";
  const m = /chunks=(\d+) .*flat=(\d+)/.exec(last);
  ok("the frame went through the window's compositor", m !== null && Number(m[1]) > 0 && Number(m[2]) === 0,
    last === "" ? "no composite stats" : last);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
