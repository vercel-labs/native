// A frame with a backdrop filter has pixels only the replay can draw: the filter reads what is
// painted behind its box. The window's compositor must still put that frame on screen — it rasters
// the page whole and draws it as one picture — instead of leaving the window blank, and the
// picture it draws must be the same one the flat replay makes.
//
// This mirrors the window: on macOS a NATIVE_COMPOSITOR_LIVE run composites every frame through
// the window's own gate and keeps the picture it presented, and the snapshot is that picture.
// Damage-limited frames are painted whole (`NATIVE_DAMAGE=0`): a damaged paint records only the
// regions it repaints, and the window patches those over its last picture, which a headless run
// has no window to do.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-backdrop-compositor-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=320, height=220">
<style>
html, body { margin: 0; width: 320px; height: 220px; background: #f7f6f3; overflow: hidden;
  font: 600 13px/16px sans-serif; color: #121214; }
#under { position: absolute; left: 40px; top: 40px; width: 200px; height: 120px;
  background: linear-gradient(90deg, #3d3bf3 0 50%, #ff6a3d 50% 100%); }
/* The glass reads the backdrop around its box: the blur pulls both halves into one another. */
#glass { position: absolute; left: 40px; top: 40px; width: 200px; height: 120px;
  background: rgba(255, 255, 255, 0.5); backdrop-filter: blur(14px); }
#n { position: absolute; left: 48px; top: 48px; }
</style></head><body>
<div id="under"></div>
<div id="glass"></div>
<div id="n">0</div>
<script type="module" src="app.ts"></script>
</body></html>`);
// The counter inside the box changes every frame: each frame paints through the backdrop filter.
writeFileSync(join(dir, "app.ts"), `const n = document.getElementById("n")!;
let k = 0;
function tick(): void {
  n.textContent = String(k++);
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

const steps = "frame 0 | frame 16 | frame 32 | frame 48";
const flat = join(dir, "flat.png");
const live = join(dir, "live.png");
function runApp(extra: Record<string, string>): string {
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, ...extra } });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  return String(r.stderr);
}
// The frame the live run presented last: the window's own picture, through the window's gate.
const liveErr = runApp({
  NATIVE_COMPOSITOR_LIVE: "1",
  NATIVE_FRAME_TIMES: "1",
  NATIVE_COMPOSITOR_STATS: "1",
  NATIVE_DAMAGE: "0",
  NATIVE_STEPS: `${steps} | snapshotcomposited ${live}`,
});
// The same page after the same steps, drawn by the flat replay: the reference.
runApp({ NATIVE_DAMAGE: "0", NATIVE_STEPS: steps, NATIVE_SNAPSHOT: flat });

// On macOS the live run takes the window's own gate; elsewhere the host's composited snapshot
// draws the same paint, and there is no window gate to turn a frame away.
if (process.platform === "darwin") {
  ok("the compositor presented the backdrop frame",
    /native: composite \d/.test(liveErr), liveErr.trim().split("\n").slice(-3).join(" | "));
} else {
  ok("skipped: the window's compositor gate is macOS's", true);
}

if (!existsSync(flat) || !existsSync(live)) {
  ok("both runs wrote their picture", false, `flat=${existsSync(flat)} live=${existsSync(live)}`);
  console.log("\n1 failed");
  process.exit(1);
}
const a = decodePng(flat);
const b = decodePng(live);
ok("both pictures have the same size", a.w === b.w && a.h === b.h, `${a.w}x${a.h} vs ${b.w}x${b.h}`);
let differing = 0;
let firstAt = "";
const n = Math.min(a.rgba.length, b.rgba.length);
for (let i = 0; i < n; i += 4) {
  const d = Math.max(
    Math.abs(a.rgba[i] - b.rgba[i]),
    Math.abs(a.rgba[i + 1] - b.rgba[i + 1]),
    Math.abs(a.rgba[i + 2] - b.rgba[i + 2]),
    Math.abs(a.rgba[i + 3] - b.rgba[i + 3]),
  );
  if (d > 1) {
    differing++;
    if (firstAt === "") firstAt = `${(i / 4) % a.w},${Math.floor(i / 4 / a.w)}`;
  }
}
ok("the compositor's picture is the flat replay's", differing === 0,
  differing === 0 ? "" : `${differing} pixels differ, first at ${firstAt}`);

// And the picture is the page, not a blank window: through the one glass box both halves of the
// backdrop show, blue on its left and orange on its right, and the glass is not the page
// background.
function px(img: { w: number; h: number; rgba: Uint8Array }, x: number, y: number): number[] {
  const i = (y * img.w + x) * 4;
  return [img.rgba[i], img.rgba[i + 1], img.rgba[i + 2]];
}
const scale = a.w / 320;
const left = px(a, Math.round(50 * scale), Math.round(100 * scale));
const middle = px(a, Math.round(160 * scale), Math.round(100 * scale));
const right = px(a, Math.round(220 * scale), Math.round(100 * scale));
const page = px(a, Math.round(20 * scale), Math.round(100 * scale));
ok("the glass box shows the backdrop through its blur",
  left[2] > left[0] + 20 && right[0] > right[2] + 20 &&
  Math.abs(middle[0] - page[0]) + Math.abs(middle[2] - page[2]) > 30,
  `left rgb(${left.join(",")}), middle rgb(${middle.join(",")}), right rgb(${right.join(",")}), page rgb(${page.join(",")})`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
