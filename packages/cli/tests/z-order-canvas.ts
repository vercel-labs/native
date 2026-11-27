// Paint order across a canvas: a canvas that comes first in the DOM paints under the text that
// comes after it, even when the later text sits in a transformed (composited) span. Tempo's grain
// canvas precedes its `.stage` labels, and Chrome keeps the labels on top; a host that promotes
// the canvas to a texture and draws it after the page would paint the grains over them.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=640, height=360"><style>
body { margin: 0; background: #ffffff; }
#c { position: absolute; left: 0; top: 0; width: 640px; height: 360px; }
.stage { position: absolute; left: 0; top: 0; width: 640px; height: 360px; pointer-events: none; }
.time { position: absolute; left: 40px; top: 40px; display: inline-block; transform: translateY(0px);
        font: 48px monospace; color: #ffffff; }
.side { position: absolute; left: 380px; top: 30px; font: 20px monospace; color: #000000; }
.side2 { position: absolute; left: 380px; top: 170px; font: 20px monospace; color: rgba(0,0,0,.45); }
</style></head><body>
<canvas id="c" width="640" height="360"></canvas>
<div class="stage"><span class="time" id="time">18:23</span><div class="side" id="side">THIS SESSION<br>LENGTH 25:00<br>DRIFT NONE</div><div class="side2" id="side2">THIS SESSION<br>LENGTH 25:00<br>DRIFT NONE</div></div>
<script>
const g = document.getElementById("c").getContext("2d");
g.fillStyle = "#ff0000";
g.fillRect(0, 0, 640, 360);
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-zorder-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

/** Runs the app once and returns the snapshot the pass asked for: the flat page, or the frame the
 *  presenter composites from its layers. A composited pass asks for no flat snapshot at all, so
 *  the only image it can read is the one the compositor drew. */
function render(composited: boolean): { at: (x: number, y: number) => number[] } {
  const flat = join(dir, "out.png");
  const merged = join(dir, "out-composited.png");
  // A stale file from the previous pass must not stand in for this pass's snapshot.
  rmSync(flat, { force: true });
  rmSync(merged, { force: true });
  const env: Record<string, string> = { ...process.env };
  delete env.NATIVE_SNAPSHOT;
  delete env.NATIVE_SNAPSHOT_COMPOSITED;
  if (composited) env.NATIVE_SNAPSHOT_COMPOSITED = merged;
  else env.NATIVE_SNAPSHOT = flat;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  const img = decodePng(composited ? merged : flat);
  return {
    at: (cx: number, cy: number): number[] => {
      const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
      return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
    },
  };
}

/** How many pixels in a CSS rect are darker than a red canvas would leave them. */
function darkIn(img: ReturnType<typeof render>, x0: number, y0: number, x1: number, y1: number): number {
  let n = 0;
  for (let y = y0; y < y1; y += 0.5) {
    for (let x = x0; x < x1; x += 0.5) {
      const p = img.at(x, y);
      // Text over red is dark or dark red; a canvas over the text leaves pure red.
      if (p[1] < 60 && p[2] < 60 && p[0] < 230) n++;
    }
  }
  return n;
}

for (const composited of [false, true]) {
  const label = composited ? " (composited)" : "";
  const img = render(composited);
  // The opaque labels after the canvas must paint above it: black glyphs over the red fill.
  const opaque = darkIn(img, 380, 30, 620, 90);
  check(`opaque labels after a canvas paint above it${label}`, opaque > 100, `${opaque} dark samples`);
  // The transformed span is a layer of its own; its white glyphs still show.
  let white = 0;
  for (let y = 36; y < 76; y += 0.5) {
    for (let x = 44; x < 180; x += 0.5) {
      const p = img.at(x, y);
      if (p[0] > 220 && p[1] > 220 && p[2] > 220) white++;
    }
  }
  check(`a transformed span before the labels still paints${label}`, white > 20, `${white} white samples`);
  // A translucent label is 45% black over the red: dark red, not the canvas's pure red.
  const blended = darkIn(img, 380, 170, 620, 236);
  check(`a translucent label blends over the canvas, not under it${label}`, blended > 100, `${blended} dark samples`);
}

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall canvas z-order checks passed");
