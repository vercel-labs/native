// border-image: a picture cut into nine slices and fitted round the border area. A 30x30 fixture
// image is a 3x3 grid of distinct 10px cells, so every slice has a colour of its own; the top
// middle cell is split in two down the middle so stretching and tiling read differently.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng, encodePng } from "./png.ts";

// The fixture image, in 10px cells: red, two halves (magenta then cyan), green across the top;
// orange, white, purple across the middle; blue, cyan, yellow across the bottom.
const CELLS = (x: number, y: number): number[] => {
  if (y < 10) return x < 10 ? [255, 0, 0] : x < 15 ? [255, 0, 255] : x < 20 ? [0, 255, 255] : [0, 255, 0];
  if (y < 20) return x < 10 ? [255, 128, 0] : x < 20 ? [255, 255, 255] : [128, 0, 128];
  return x < 10 ? [0, 0, 255] : x < 20 ? [0, 255, 255] : [255, 255, 0];
};

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=460, height=320"><style>
html, body { margin: 0; background: #ffffff; }
.box { position: absolute; width: 60px; height: 60px; border: 10px solid transparent;
       border-image: url(cells.png) 10 fill / 10px stretch; }
#stretch { left: 0; top: 0; }
#repeat { left: 120px; top: 0; border-image-repeat: repeat; }
#nofill { left: 240px; top: 0; border-image-slice: 10; background: #eeeeee; }
#outset { left: 120px; top: 120px; border-image-outset: 10px; }
#wide { left: 260px; top: 120px; border: 5px solid transparent; border-image-width: 3; }
#shorthand { left: 380px; top: 120px; border: 5px solid transparent; border-image: url(cells.png) 10 fill; }
</style></head><body>
<div class="box" id="stretch"></div>
<div class="box" id="repeat"></div>
<div class="box" id="nofill"></div>
<div class="box" id="outset"></div>
<div class="box" id="wide"></div>
<div class="box" id="shorthand"></div>
</body></html>`;

let failed = 0;
function check(name: string, got: string, want: string): void {
  if (got !== want) failed++;
  console.log(`${got === want ? "ok  " : "FAIL"} ${name}${got === want ? "" : ` — got ${got}, want ${want}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-border-image-"));
writeFileSync(join(dir, "cells.png"), encodePng(30, 30, CELLS));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
// The snapshot is taken at the display's backing scale: two image pixels per CSS pixel here.
const k = img.w / 460;
const COLOURS: Record<string, number[]> = {
  red: [255, 0, 0], magenta: [255, 0, 255], cyan: [0, 255, 255], green: [0, 255, 0],
  orange: [255, 128, 0], white: [255, 255, 255], purple: [128, 0, 128],
  blue: [0, 0, 255], yellow: [255, 255, 0],
};


// The colour at a CSS point, as the nearest cell colour name: an image drawn edge to edge may
// round a channel, so each sample is matched to the plain colour within a tolerance.
function at(x: number, y: number): string {
  const o = (Math.round(y * k) * img.w + Math.round(x * k)) * 4;
  const got = [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
  let best = "", dist = Infinity;
  for (const [name, c] of Object.entries(COLOURS)) {
    const d = Math.abs(got[0] - c[0]) + Math.abs(got[1] - c[1]) + Math.abs(got[2] - c[2]);
    if (d < dist) { dist = d; best = name; }
  }
  return dist <= 12 ? best : `rgb(${got.join(",")})`;
}


// The stretched picture: each source cell lands in its own band.
check("the top-left cell is the top-left corner", at(5, 5), "red");
check("the top-right cell is the top-right corner", at(75, 5), "green");
check("the bottom-left cell is the bottom-left corner", at(5, 75), "blue");
check("the bottom-right cell is the bottom-right corner", at(75, 75), "yellow");
check("the left cell is the left edge", at(5, 40), "orange");
check("the right cell is the right edge", at(75, 40), "purple");
// The top middle cell is split down its middle: stretched across 60px, the change is at x = 40.
check("the top edge stretches its slice's first half", at(30, 5), "magenta");
check("the top edge stretches its slice's second half", at(50, 5), "cyan");
check("the middle cell fills the centre", at(40, 40), "white");

// The same picture with repeat: the top edge is tiled in 10px slices, so the two halves swap
// every 5px. The run of tiles is centred on the edge, which spans x = 130 to 190, so a tile
// starts at 135, then 145 and so on; the tile before it began at 125 and the corner clips it,
// leaving only its second half under x = 130 to 135.
check("a repeated top edge centres its tiles, clipping the first", at(132, 5), "cyan");
check("a repeated top edge starts a tile at 135", at(137, 5), "magenta");
check("a repeated top edge swaps halves", at(142, 5), "cyan");
check("a repeated top edge keeps tiling", at(157, 5), "magenta");
check("a repeated top edge stops at the right corner", at(186, 5), "magenta");

// Without `fill` the middle is left alone, and the box's own background shows there.
check("a slice without fill leaves the middle", at(280, 40), "rgb(238,238,238)");

// The outset moves the picture 10px out past the border box: the left top corner starts at -10.
check("an outset picture reaches outside the border box", at(114, 114), "red");
check("an outset picture starts no further out", at(104, 114), "white");

// `border-image-width: 3` is three border widths: 15px bands in a 70px border box.
// The shorthand leaves border-image-width out, so it is the initial 1: five border widths for
// this box, not the slice's own 10px. The corner is 5px square and the top edge starts after it.
check("an omitted width counts border widths", at(383, 123), "red");
check("an omitted width ends the corner at the border width", at(387, 122), "magenta");

check("a width of 3 counts border widths", at(262, 122), "red");
check("a count width keeps the corner square", at(272, 132), "red");
check("a count width starts the edge after the corner", at(280, 122), "magenta");
check("a count width stretches the edge over its band", at(310, 122), "cyan");

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
