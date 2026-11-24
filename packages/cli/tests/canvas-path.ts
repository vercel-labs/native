// The canvas 2D path API's rounded rectangles: roundRect(x, y, w, h, radii) with one radius, a
// point, or a list of one to four, spread over the corners as border-radius spreads them, shrunk
// when they would overlap, and flipped by a negative width or height. Each shape is filled at a
// known place and the snapshot is sampled inside and outside its corners.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=260, height=180"><style>
body { margin: 0; background: #ffffff; }
canvas { position: absolute; left: 0; top: 0; }
</style></head><body>
<canvas id="c" width="260" height="180"></canvas>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `const ctx = (document.getElementById("c") as HTMLCanvasElement).getContext("2d")!;
function shape(fill: string, draw: () => void): void {
  ctx.beginPath();
  draw();
  ctx.fillStyle = fill;
  ctx.fill();
}
// One radius rounds all four corners.
shape("#ff0000", () => ctx.roundRect(10, 10, 40, 40, 10));
// Zero is a plain rectangle.
shape("#0000ff", () => ctx.roundRect(60, 10, 40, 40, 0));
// A point sets the x and y radius apart: half the box each way is a stadium.
shape("#00ff00", () => ctx.roundRect(110, 10, 60, 40, { x: 30, y: 20 }));
// Four radii: top-left, top-right, bottom-right, bottom-left.
shape("#ff8800", () => ctx.roundRect(10, 60, 40, 40, [0, 0, 20, 20]));
// Two radii: top-left and bottom-right, then top-right and bottom-left.
shape("#000000", () => ctx.roundRect(190, 60, 30, 30, [15, 0]));
// Radii too big for the box shrink until they meet: 50 in a 40 box becomes 20 a side.
shape("#00aaaa", () => ctx.roundRect(180, 10, 40, 40, 50));
// A negative width draws the same rounded rectangle to the left of x.
shape("#880088", () => ctx.roundRect(110, 60, -40, 40, 10));
let negative = "none";
try {
  ctx.beginPath();
  ctx.roundRect(0, 0, 10, 10, -1);
} catch (e) {
  negative = "threw";
}
console.log("negative=" + negative);
`;

const dir = mkdtempSync(join(tmpdir(), "native-canvas-path-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img: Image = decodePng(png);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

/** The pixel at CSS coordinates (cx, cy), as "r,g,b". */
function at(cx: number, cy: number): string {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
}

/** Whether the pixel at (cx, cy) is `want`; both are CSS px and "r,g,b". */
function is(cx: number, cy: number, want: string): boolean {
  return at(cx, cy) === want;
}

function pixel(name: string, cx: number, cy: number, want: string): void {
  const got = at(cx, cy);
  check(name, got === want, `got ${got}, want ${want}`);
}

const RED = "255,0,0", BLUE = "0,0,255", GREEN = "0,255,0", ORANGE = "255,136,0",
  BLACK = "0,0,0", TEAL = "0,170,170", PURPLE = "136,0,136", WHITE = "255,255,255";

// A radius of 10 in a 40 square: the corners are cut, the middle and the edges' middles are not.
pixel("a rounded corner is clear", 11, 11, WHITE);
pixel("the corner arc clears the box corner", 11.5, 11.5, WHITE);
pixel("the arc starts inside the corner", 15, 15, RED);
pixel("the middle of a rounded rect fills", 30, 30, RED);
pixel("the top edge's middle fills", 30, 11, RED);
pixel("the left edge's middle fills", 11, 30, RED);
pixel("a rounded rect stops at its right edge", 52, 30, WHITE);

// Zero radii: square corners.
pixel("zero radii keep the top-left corner", 61, 11, BLUE);
pixel("zero radii keep the bottom-right corner", 98, 48, BLUE);
pixel("zero radii still stop at the edge", 102, 30, WHITE);

// A point: half the width and height as radii makes the ends semicircular.
pixel("an elliptical radius clears its corner", 112, 12, WHITE);
pixel("a stadium fills its middle", 140, 30, GREEN);
pixel("a stadium fills to its top edge", 140, 11, GREEN);
pixel("a stadium fills its centre row", 115, 30, GREEN);

// Four radii, only the bottom two rounded.
pixel("a square corner is filled", 11, 61, ORANGE);
pixel("the second corner is square too", 49, 61, ORANGE);
pixel("the rounded bottom-right corner is clear", 49, 99, WHITE);
pixel("the rounded bottom-left corner is clear", 11, 99, WHITE);
pixel("the middle of the shape fills", 30, 80, ORANGE);

// Two radii: top-left rounded, top-right square.
pixel("the first of two radii rounds its corner", 191, 61, WHITE);
pixel("the second of two radii is square", 219, 61, BLACK);
pixel("two radii fill the middle", 205, 75, BLACK);

// 50 in a 40 box shrinks to 20 a side, so the corners are still cut.
pixel("an oversized radius is shrunk", 181, 11, WHITE);
pixel("a shrunk radius still fills the top edge", 200, 12, TEAL);
pixel("a shrunk radius fills the middle", 200, 30, TEAL);

// A negative width flips the box to the left of x: it covers 70..110, with the same corners.
pixel("a negative width starts at x plus w", 72, 80, PURPLE);
pixel("a negative width reaches back to x", 108, 80, PURPLE);
pixel("a negative width rounds its corner", 71, 61, WHITE);
pixel("a negative width stops at x", 112, 80, WHITE);

check("a negative radius throws", r.stdout.includes("negative=threw"), `log: ${r.stdout.trim()}`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall canvas path checks passed");
