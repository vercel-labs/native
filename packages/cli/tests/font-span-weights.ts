// Per-span variable-font weights: two spans of one variable font in a row, at wght 200 and 800,
// must paint with different stroke weights, whether the weight comes from font-variation-settings
// or from font-weight, exactly as Chrome paints them. The two ways must agree with each other: a
// host that drops the per-span run (or its axes) paints both spans at one weight and the ink
// counts collapse to the same value. The snapshot also exercises the headless split between
// layout at scale 1 and rasterization at scale 2, where a scale-dependent painting path shows up.
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const font = fileURLToPath(new URL("./fonts/Geist-Variable-Subset.ttf", import.meta.url));

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=900, height=500"><style>
body { margin: 0; background: #ffffff; color: #000000; }
@font-face { font-family: Var; src: url("var.ttf"); font-weight: 100 900; }
.row { position: absolute; left: 20px; font: 64px Var; line-height: 84px; white-space: pre; }
#v200 { top: 0px; font-variation-settings: "wght" 200; }
#v800 { top: 100px; font-variation-settings: "wght" 800; }
#w200 { top: 200px; font-weight: 200; }
#w800 { top: 300px; font-weight: 800; }
#pair { top: 400px; }
.v200 { font-variation-settings: "wght" 200; }
.v800 { font-variation-settings: "wght" 800; }
</style></head><body>
<div class="row" id="v200">Hamburg</div>
<div class="row" id="v800">Hamburg</div>
<div class="row" id="w200">Hamburg</div>
<div class="row" id="w800">Hamburg</div>
<div class="row" id="pair"><span id="p200" class="v200">Hamburg</span><span id="p800" class="v800">Hamburg</span></div>
<script src="app.ts"></script>
</body></html>`;

// Two spans in one line: the log gives each span's own box, so their ink is measured apart.
const SCRIPT = `
const rect = (id: string): string => {
  const r = document.getElementById(id)!.getBoundingClientRect();
  return r.left + "," + r.top + "," + r.width + "," + r.height;
};
console.log("p200=" + rect("p200"));
console.log("p800=" + rect("p800"));
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-span-weights-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
copyFileSync(font, join(dir, "var.ttf"));
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

/** The ink in a CSS-pixel rect: dark pixels in device pixels. */
function ink(x0: number, y0: number, x1: number, y1: number): number {
  let count = 0;
  for (let y = Math.floor(y0 * 2); y < Math.ceil(y1 * 2); y++) {
    for (let x = Math.floor(x0 * 2); x < Math.ceil(x1 * 2); x++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 128 && img.rgba[o + 1] < 128 && img.rgba[o + 2] < 128) count++;
    }
  }
  return count;
}

// One row per weight, so each count is that span's ink alone.
const v200 = ink(20, 0, 880, 84);
const v800 = ink(20, 100, 880, 184);
const w200 = ink(20, 200, 880, 284);
const w800 = ink(20, 300, 880, 384);

check("both variation spans paint", v200 > 200 && v800 > 200, `${v200} and ${v800} ink pixels`);
check("per-span font-variation-settings paint different weights",
  v800 > v200 * 1.3, `wght 200: ${v200}, wght 800: ${v800}`);
check("both font-weight spans paint", w200 > 200 && w800 > 200, `${w200} and ${w800} ink pixels`);
check("per-span font-weight paints different weights",
  w800 > w200 * 1.3, `200: ${w200}, 800: ${w800}`);
// The axes and the weight are the same instance, so the two ways agree.
const near = (a: number, b: number): boolean => Math.abs(a - b) <= Math.max(a, b) * 0.08;
check("font-variation-settings and font-weight paint the same 200 instance", near(v200, w200), `${v200} vs ${w200}`);
check("font-variation-settings and font-weight paint the same 800 instance", near(v800, w800), `${v800} vs ${w800}`);

// The same two weights in one line, each span's own box.
const boxes: Record<string, number[]> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^(p\d+)=([\d.,-]+)$/.exec(line.trim());
  if (m) boxes[m[1]] = m[2].split(",").map(Number);
}
const spanInk = (box: number[]): number => ink(box[0], box[1], box[0] + box[2], box[1] + box[3]);
if (boxes.p200 !== undefined && boxes.p800 !== undefined) {
  const a = spanInk(boxes.p200), b = spanInk(boxes.p800);
  check("two spans in one line paint their own weights", b > a * 1.3, `wght 200: ${a}, wght 800: ${b}`);
} else {
  check("two spans in one line report their boxes", false, "no rects logged");
}

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall per-span weight checks passed");
