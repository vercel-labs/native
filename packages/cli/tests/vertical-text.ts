// writing-mode: vertical text. A vertical box's lines run down the page and stack across it, right
// to left for vertical-rl and left to right for vertical-lr, with each line turned a quarter
// clockwise. The numbers below were measured from the same page in headless Chrome at 2x.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=240"><style>
body { margin: 0; font: 16px monospace; }
.v { position: absolute; top: 10px; width: 100px; height: 200px; background: #eeeeee; }
#rl { writing-mode: vertical-rl; left: 10px; }
#lr { writing-mode: vertical-lr; left: 130px; }
.pad { padding: 20px; border: 4px solid #0088ff; }
</style></head><body>
<div class="v" id="rl">abcdefghij klmnopqrst uvwxyz</div>
<div class="v" id="lr">abcdefghij klmnopqrst uvwxyz</div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-vertical-text-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
if (/unsupported writing-mode/.test(`${build.stdout}${build.stderr}`)) {
  throw new Error("the build still rejects vertical writing-mode");
}
const png = join(dir, "out.png");
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const img = decodePng(png);
// The snapshot is two device pixels per CSS pixel.
const ink = (cx: number, cy: number): boolean => {
  const o = (Math.round(cy * 2) * img.w + Math.round(cx * 2)) * 4;
  return img.rgba[o] < 140 && img.rgba[o + 1] < 140 && img.rgba[o + 2] < 140;
};
/** The ink's bounding box in the CSS rect x0..x1, y0..y1, or null when it holds none. */
function box(x0: number, x1: number, y0: number, y1: number): number[] | null {
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (let x = x0; x <= x1; x += 0.5) {
    for (let y = y0; y <= y1; y += 0.5) {
      if (!ink(x, y)) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  return minX === Infinity ? null : [minX, maxX, minY, maxY];
}
const near = (got: number[] | null, want: number[]): boolean => got !== null &&
  got.every((v, i) => Math.abs(v - want[i]) <= 1);

// Both boxes are 100x200 at y=10, with their text wrapped to columns 19px wide: two columns in
// each, running down the page. Chrome: rl ink 72.5..107 x 11..172 and lr 130.5..165 in the same
// rows, which is two columns against the right and left edges.
const rl = box(10, 120, 0, 220);
check("vertical-rl draws its text in columns at the right edge", near(rl, [72.5, 107, 11, 172]),
  `${JSON.stringify(rl)}`);
const lr = box(125, 240, 0, 220);
check("vertical-lr draws its text in columns at the left edge", near(lr, [130.5, 165, 11, 172]),
  `${JSON.stringify(lr)}`);
// A line twice as tall as it is wide: the glyphs were turned, not stacked upright.
check("the text is turned down the page", rl !== null && rl[3] - rl[2] > 4 * (rl[1] - rl[0]) / 2,
  rl === null ? "no ink" : `box ${rl[1] - rl[0]} wide, ${rl[3] - rl[2]} tall`);
// The box's own frame is physical: its background covers 100x200 whether the text is turned or not.
check("the box keeps its own height", !ink(20, 9) && !ink(20, 11) && !ink(20, 210),
  "background outside the 200px box");

// A page's writing mode comes from the body when the root's own is the initial one: the page then
// lays out down the page, as the browser does, with the page's box as wide as the column it holds.
const BODY_PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=240"><style>
body { margin: 0; writing-mode: vertical-rl; font: 16px/20px monospace; }
</style></head><body><div>abcdefghij klmnop</div></body></html>`;
const dir2 = mkdtempSync(join(tmpdir(), "native-vertical-body-"));
writeFileSync(join(dir2, "index.html"), BODY_PAGE);
const exe2 = join(dir2, "app");
const build2 = spawnSync("node", ["compiler/cli.ts", "build", dir2, "-o", exe2], { encoding: "utf8" });
if (build2.status !== 0) throw new Error(`body build failed\n${build2.stderr}`);
const png2 = join(dir2, "out.png");
const run2 = spawnSync(exe2, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png2 } });
if (run2.status !== 0) throw new Error(`body render failed\n${run2.stderr}`);
const page = decodePng(png2);
const pageInk = (cx: number, cy: number): boolean => {
  const o = (Math.round(cy * 2) * page.w + Math.round(cx * 2)) * 4;
  return page.rgba[o] < 140 && page.rgba[o + 1] < 140 && page.rgba[o + 2] < 140;
};
let px0 = Infinity, px1 = -Infinity, py0 = Infinity, py1 = -Infinity;
for (let x = 0; x <= 300; x += 0.5) {
  for (let y = 0; y <= 240; y += 0.5) {
    if (!pageInk(x, y)) continue;
    if (x < px0) px0 = x;
    if (x > px1) px1 = x;
    if (y < py0) py0 = y;
    if (y > py1) py1 = y;
  }
}
// One column of text against the page's left edge (the page is as wide as its one column), taller
// than the column is wide, where a horizontal page would have run it across the top.
check("a body's writing mode makes the page vertical",
  px0 <= 4 && px1 < 25 && py1 - py0 > 5 * (px1 - px0),
  `ink ${px0}..${px1} x ${py0}..${py1}`);

if (failed > 0) {
  console.error(`\n${failed} vertical text check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall vertical text checks passed");
