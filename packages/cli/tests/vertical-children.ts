// writing-mode: element children inside a vertical box. A vertical box lays its content out in a
// frame whose inline axis runs down the page and whose block axis runs across it, so its children
// are sized and placed in those axes: their width is the frame's block size and their height its
// inline size, and their margins, borders and padding swap sides accordingly. Each child is then
// drawn on the page at the rect the frame maps it to, with its own borders on their own sides.
//
// The numbers below were measured from the same page in headless Chrome at 2x.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=300, height=520"><style>
html, body { margin: 0; padding: 0; background: #fff; font: 16px monospace; }
.v { position: absolute; top: 10px; width: 120px; height: 240px; background: #eeeeee; }
#rl { writing-mode: vertical-rl; left: 10px; }
#lr { writing-mode: vertical-lr; left: 150px; }
.c { width: 40px; height: 100px; background: #888888;
  border-top: 6px solid #ff0000; border-right: 8px solid #0000ff;
  border-bottom: 10px solid #00ff00; border-left: 12px solid #ffff00; }
.t { height: 50px; background: #cc88cc; }
.m { width: 30px; height: 60px; margin-top: 10px; margin-left: 7px; background: #88cccc;
  padding: 4px; border: 3px solid #444444; }
#auto { writing-mode: vertical-rl; left: 10px; top: 260px; width: 120px; height: auto;
  padding: 5px; border: 3px solid #000000; background: #eeeeee; position: absolute; }
.k { width: 40px; height: 100px; background: #888888; }
#mixed { writing-mode: vertical-rl; left: 150px; top: 260px; width: 120px; height: 120px; }
.h { writing-mode: horizontal-tb; background: #ff99cc; }
#scroll { position: absolute; left: 150px; top: 390px; width: 200px; height: 120px; overflow: hidden;
  background: #dddddd; }
.v2 { writing-mode: vertical-rl; background: #eeeeee; }
</style></head><body>
<div class="v" id="rl"><div class="c"></div><div class="t">abc</div><div class="m"></div></div>
<div class="v" id="lr"><div class="c"></div><div class="t">abc</div><div class="m"></div></div>
<div id="auto"><div class="k"></div></div>
<div class="v" id="mixed"><div class="h">mixed</div></div>
<div id="scroll"><div class="v2">aaa bbb ccc ddd eee fff ggg</div></div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-vertical-children-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
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
function at(cx: number, cy: number): number[] {
  const o = (Math.round(cy * 2) * img.w + Math.round(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}
const same = (got: number[], want: number[]): boolean =>
  got.every((v, i) => Math.abs(v - want[i]) <= 6);
/** The box holding the colour in x0..x1 × y0..y1, or null when it holds none of it. */
function colourBox(want: number[], x0: number, x1: number, y0: number, y1: number): number[] | null {
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (let x = x0; x <= x1; x += 0.5) {
    for (let y = y0; y <= y1; y += 0.5) {
      if (!same(at(x, y), want)) continue;
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
const show = (got: number[] | null): string => (got === null ? "no colour" : JSON.stringify(got));

const GREY = [0x88, 0x88, 0x88];
const PINK = [0xcc, 0x88, 0xcc];
const TEAL = [0x88, 0xcc, 0xcc];
const RED = [0xff, 0, 0];
const BLUE = [0, 0, 0xff];
const GREEN = [0, 0xff, 0];
const YELLOW = [0xff, 0xff, 0];
const DARK = [0x44, 0x44, 0x44];

// The four-colour probe. Its child is 40 by 100 with four different borders, so the child's own
// box is 60 wide (40 + 12 + 8) and 116 tall (100 + 6 + 10). In a right-to-left frame its block
// start is the right edge, so it sits at x 70..130 against the right of a 120-wide box at x 10;
// in a left-to-right one the same box starts at the left edge, x 150..210.
const rlChild = colourBox(GREY, 10, 140, 0, 260);
check("a vertical-rl child is as wide and tall as its own width and height say", near(rlChild, [82, 121.5, 16, 115.5]),
  show(rlChild));
const lrChild = colourBox(GREY, 140, 290, 0, 260);
check("a vertical-lr child keeps its size and moves to the left edge", near(lrChild, [162, 201.5, 16, 115.5]),
  show(lrChild));
// Each border keeps its own side and colour: painting the ring inside the turn would put the
// 6px top border down the left of a column 116 tall instead.
const rlBoxes = [
  ["the top border is red and 6px tall", RED, [71, 129.5, 10, 15.5]],
  ["the bottom border is green and 10px tall", GREEN, [71, 129.5, 116, 125.5]],
  ["the left border is yellow and 12px wide", YELLOW, [70, 81.5, 10.5, 125.5]],
  ["the right border is blue and 8px wide", BLUE, [122, 129.5, 10.5, 125.5]],
] as const;
for (const [name, colour, want] of rlBoxes) {
  const got = colourBox(colour, 40, 140, 0, 130);
  check(`vertical-rl: ${name}`, near(got, [...want]), show(got));
}
const lrBoxes = [
  ["the top border is red", RED, [151, 209.5, 10, 15.5]],
  ["the bottom border is green", GREEN, [151, 209.5, 116, 125.5]],
  ["the left border is yellow", YELLOW, [150, 161.5, 10.5, 125.5]],
  ["the right border is blue", BLUE, [202, 209.5, 10.5, 125.5]],
] as const;
for (const [name, colour, want] of lrBoxes) {
  const got = colourBox(colour, 145, 290, 0, 130);
  check(`vertical-lr: ${name}`, near(got, [...want]), show(got));
}

// A child whose height is set and width is auto: its inline size is the 50 it asks for, at the
// top edge of the frame, and its block size shrinks to the column its text makes (19 wide).
const rlText = colourBox(PINK, 40, 140, 0, 130);
check("a vertical-rl child with height: 50px is 19 wide by 50 tall", near(rlText, [51, 69.5, 10, 59.5]),
  show(rlText));
const lrText = colourBox(PINK, 145, 290, 0, 130);
check("a vertical-lr child takes its 50px along the same axis", near(lrText, [210, 228.5, 10, 59.5]),
  show(lrText));

// Margins and padding turn with the box: margin-top pushes it down the page, margin-left moves
// its block end, and the 4px padding and 3px border follow the same sides.
const rlPad = colourBox(DARK, 0, 140, 0, 140);
check("a vertical-rl child's margin-top and padding offset it down the page", near(rlPad, [7, 50.5, 20, 93.5]),
  show(rlPad));
const rlContent = colourBox(TEAL, 0, 140, 0, 140);
check("the background covers the padding box the frame's axes give it",
  near(rlContent, [10, 47.5, 23, 90.5]), show(rlContent));
const lrPad = colourBox(DARK, 145, 290, 0, 140);
check("a vertical-lr child's margins and padding follow its own axes", near(lrPad, [236, 279.5, 20, 93.5]),
  show(lrPad));

// A box with no height of its own takes the inline size its content asks for — the 100px child's
// height — and its block size stays the 120px it was given, both grown by the padding and border.
// Its child is drawn at the content box's block-start corner, 8px in from each side.
const autoChild = colourBox(GREY, 0, 300, 250, 385);
check("an auto height is as tall as its content's inline size", near(autoChild, [98, 137.5, 268, 367.5]),
  show(autoChild));
const autoBox = colourBox([0xee, 0xee, 0xee], 0, 148, 250, 385);
check("the box with that auto height is 136 wide by 116 tall", near(autoBox, [13, 142.5, 263, 372.5]),
  show(autoBox));

// A horizontal box inside a vertical one lays its content out across the page: its width is its
// own inline size and its height its block size, and it starts at the frame's block start, the
// right edge here.
const MIXED = colourBox([0xff, 0x99, 0xcc], 148, 290, 250, 400);
check("a horizontal box in a vertical frame keeps its own axes", near(MIXED, [222, 269.5, 260, 278.5]),
  show(MIXED));
const aroundMixed = colourBox([0xee, 0xee, 0xee], 148, 290, 250, 385);
check("the vertical box around it keeps its height", near(aroundMixed, [150, 269.5, 260, 379.5]),
  show(aroundMixed));

// A box with no height of its own in a scroll container that has one wraps at the container's
// height, not at the longest line its text makes and not at the page's: 27 characters that would
// run to one 260-tall column are laid out in the 120 the container leaves.
const scrolled = colourBox([0xee, 0xee, 0xee], 148, 300, 385, 520);
check("a vertical box in a 120px scroller wraps at the scroller's height",
  scrolled !== null && scrolled[0] === 150 && Math.abs(scrolled[2] - 390) <= 1 && Math.abs(scrolled[3] - 509.5) <= 1,
  show(scrolled));

if (failed > 0) {
  console.error(`\n${failed} vertical children check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall vertical children checks passed");
