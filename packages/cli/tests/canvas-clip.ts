// CanvasRenderingContext2D.clip(): the current path, a save/restore that takes the clip back off,
// nested clips intersecting, and the even-odd rule. Each region the page paints is checked where
// it must show and where the clip must have kept it out, and the same frame is drawn with the
// canvas texture on and off and must agree.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=160"><style>
body { margin: 0; background: #ffffff; }
#c { position: absolute; left: 10px; top: 10px; width: 200px; height: 120px; }
</style></head><body>
<canvas id="c" width="200" height="120"></canvas>
<script>
const ctx = document.getElementById("c").getContext("2d");
ctx.fillStyle = "#0000ff";
ctx.fillRect(0, 0, 200, 120);

// A rect clip: red shows inside it, the blue field stays outside.
ctx.save();
ctx.beginPath();
ctx.rect(20, 20, 60, 40);
ctx.clip();
ctx.fillStyle = "#ff0000";
ctx.fillRect(0, 0, 200, 120);
ctx.restore();

// Nested clips intersect: only the overlap of the two rects takes green.
ctx.save();
ctx.beginPath();
ctx.rect(100, 20, 80, 60);
ctx.clip();
ctx.beginPath();
ctx.rect(140, 40, 80, 60);
ctx.clip();
ctx.fillStyle = "#00ff00";
ctx.fillRect(0, 0, 200, 120);
ctx.restore();

// The even-odd rule clips the ring and leaves the hole inside it open.
ctx.save();
ctx.beginPath();
ctx.rect(10, 70, 60, 30);
ctx.rect(25, 78, 30, 14);
ctx.clip("evenodd");
ctx.fillStyle = "#ffff00";
ctx.fillRect(0, 60, 100, 44);
ctx.restore();

// The restore took the clips back off: this bar crosses the whole canvas.
ctx.fillStyle = "#000000";
ctx.fillRect(0, 104, 200, 6);
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-canvas-clip-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

/** Renders the page once with the canvas texture either on or off, and decodes the snapshot. */
function render(texture: boolean): { w: number; at: (x: number, y: number) => number[] } {
  const png = join(dir, texture ? "out-texture.png" : "out-cpu.png");
  const env: Record<string, string> = { ...process.env, NATIVE_SNAPSHOT: png };
  env.NATIVE_CANVAS_TEXTURE = texture ? "1" : "0";
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  const img = decodePng(png);
  return {
    w: img.w,
    at: (cx: number, cy: number): number[] => {
      const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
      return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
    },
  };
}

const near = (got: number[], want: number[]): boolean =>
  got.every((v, i) => Math.abs(v - want[i]) <= 12);

const RED = [255, 0, 0], GREEN = [0, 255, 0], BLUE = [0, 0, 255], YELLOW = [255, 255, 0];
const BLACK = [0, 0, 0];

for (const texture of [true, false]) {
  const label = texture ? "" : " (canvas texture off)";
  const img = render(texture);
  // The canvas sits at CSS (10, 10), so canvas (x, y) is page (x + 10, y + 10).
  const at = (x: number, y: number): number[] => img.at(x + 10, y + 10);

  check(`a rect clip keeps the fill inside it${label}`, near(at(30, 30), RED), `got ${at(30, 30).join(",")}`);
  check(`a rect clip leaves the rest of the canvas alone${label}`, near(at(90, 30), BLUE), `got ${at(90, 30).join(",")}`);
  check(`nested clips intersect${label}`, near(at(150, 50), GREEN), `got ${at(150, 50).join(",")}`);
  check(`the first nested clip alone shows nothing${label}`, near(at(130, 50), BLUE), `got ${at(130, 50).join(",")}`);
  check(`the second nested clip alone shows nothing${label}`, near(at(160, 90), BLUE), `got ${at(160, 90).join(",")}`);
  check(`evenodd clips the ring${label}`, near(at(15, 80), YELLOW), `got ${at(15, 80).join(",")}`);
  check(`evenodd leaves the hole open${label}`, near(at(40, 85), BLUE), `got ${at(40, 85).join(",")}`);
  check(`restore takes the clip back off${label}`, near(at(100, 107), BLACK), `got ${at(100, 107).join(",")}`);
}

// Both paths must draw the same frame.
const a = render(true), z = render(false);
let differ = 0;
for (let y = 0; y < 160; y += 0.5) {
  for (let x = 0; x < 240; x += 0.5) {
    if (!near(a.at(x, y), z.at(x, y))) differ++;
  }
}
check("the canvas texture path and the CPU path agree", differ === 0, `${differ} samples differ`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall canvas clip checks passed");
