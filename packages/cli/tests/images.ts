// Replaced content: object-fit and object-position place an image inside its content box,
// image-rendering chooses whether the host interpolates it when it scales, and image-orientation
// decides whether its EXIF orientation is applied. Each is checked by sampling the snapshot of a
// page that draws the same 16x8 quadrant image several ways.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng, encodePng } from "./png.ts";
import type { Image } from "./png.ts";

// The fixture image: 16x8 with four quadrants. Red top-left, green top-right, blue
// bottom-left, yellow bottom-right.
const QUADRANTS = (x: number, y: number): number[] => {
  if (y < 4) return x < 8 ? [255, 0, 0] : [0, 255, 0];
  return x < 8 ? [0, 0, 255] : [255, 255, 0];
};

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=330"><style>
body { margin: 0; background: #ffffff; }
img { position: absolute; }
#fill { left: 0; top: 0; width: 40px; height: 40px; object-fit: fill; }
#contain { left: 50px; top: 0; width: 40px; height: 40px; object-fit: contain; }
#cover { left: 100px; top: 0; width: 40px; height: 40px; object-fit: cover; }
#none { left: 150px; top: 0; width: 40px; height: 40px; object-fit: none; }
#down { left: 200px; top: 0; width: 40px; height: 40px; object-fit: scale-down; }
#small { left: 250px; top: 0; width: 8px; height: 4px; object-fit: scale-down; }
#tr { left: 0; top: 50px; width: 40px; height: 40px; object-fit: none;
      object-position: top right; }
#bl { left: 50px; top: 50px; width: 40px; height: 40px; object-fit: none;
      object-position: bottom left; }
#brlen { left: 100px; top: 50px; width: 40px; height: 40px; object-fit: none;
         object-position: bottom 1px right 2px; }
#pixelated { left: 0; top: 140px; width: 160px; height: 80px; object-fit: fill;
             image-rendering: pixelated; }
#smooth { left: 0; top: 240px; width: 160px; height: 80px; object-fit: fill; }
#spill { left: 0; top: 100px; width: 8px; height: 8px; object-fit: none;
         object-position: 0 0; overflow: visible; }
#clipped { left: 20px; top: 100px; width: 8px; height: 8px; object-fit: none;
           object-position: 0 0; }
#exif { left: 200px; top: 140px; }
#exif-none { left: 230px; top: 150px; image-orientation: none; }
</style></head><body>
<img id="fill" src="quadrants.png"><img id="contain" src="quadrants.png">
<img id="cover" src="quadrants.png"><img id="none" src="quadrants.png">
<img id="down" src="quadrants.png"><img id="small" src="quadrants.png">
<img id="tr" src="quadrants.png"><img id="bl" src="quadrants.png">
<img id="brlen" src="quadrants.png"><img id="pixelated" src="quadrants.png">
<img id="smooth" src="quadrants.png"><img id="spill" src="quadrants.png"><img id="clipped" src="quadrants.png">
<img id="exif" src="rotated.png">
<img id="exif-none" src="rotated.png">
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-images-"));
writeFileSync(join(dir, "quadrants.png"), encodePng(16, 8, QUADRANTS));
// Orientation 6: the stored landscape image (16x8) displays rotated 90° clockwise, 8x16.
writeFileSync(join(dir, "rotated.png"), encodePng(16, 8, QUADRANTS, 6));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

/** The pixel at CSS coordinates (cx, cy), as [r, g, b]. */
function at(cx: number, cy: number): number[] {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

function near(cx: number, cy: number, want: number[], tol = 6): string | null {
  const got = at(cx, cy);
  return got.every((g, i) => Math.abs(g - want[i]) <= tol) ? null : `got ${got.join(",")}, want about ${want.join(",")}`;
}

const RED = [255, 0, 0], GREEN = [0, 255, 0], BLUE = [0, 0, 255], YELLOW = [255, 255, 0], WHITE = [255, 255, 255];

let failed = 0;
function check(name: string, bad: string | null): void {
  if (bad !== null) failed++;
  console.log(`${bad === null ? "ok  " : "FAIL"} ${name}${bad === null ? "" : ` — ${bad}`}`);
}

// fill: the image is stretched over the whole 40x40 box, so each quadrant is 20x20.
check("fill paints the top-left quadrant", near(5, 5, RED));
check("fill paints the top-right quadrant", near(35, 5, GREEN));
check("fill paints the bottom-left quadrant", near(5, 35, BLUE));
check("fill paints the bottom-right quadrant", near(35, 35, YELLOW));

// contain: 16x8 scaled by 2.5 to 40x20, centered vertically in the 40x40 box at x=50.
check("contain leaves the free space above", near(55, 3, WHITE));
check("contain starts at its top", near(55, 12, RED));
check("contain ends at its bottom", near(55, 28, BLUE));
check("contain keeps the aspect on the right", near(85, 12, GREEN));

// cover: 16x8 scaled by 5 to 80x40, cropped 20px on each side horizontally, at x=100.
check("cover crops the left", near(105, 5, RED));
check("cover keeps the right half visible", near(135, 5, GREEN));
check("cover keeps the bottom row", near(135, 35, YELLOW));

// none: the intrinsic 16x8, centered in the 40x40 box at x=150, so (162, 16) to (178, 24).
check("none leaves a margin at the top", near(155, 5, WHITE));
check("none starts at its intrinsic size", near(163, 17, RED));
check("none keeps its intrinsic width", near(177, 17, GREEN));
check("none keeps its intrinsic height", near(163, 23, BLUE));

// An 8x8 box holding the intrinsic 16x8 image: the content box clips it, as replaced elements
// default to overflow: clip, but `overflow: visible` lets it spill out of the box.
check("the content box clips the overflow", near(24, 102, RED));
check("clipped overflow stays out of sight", near(30, 102, WHITE));
check("overflow: visible lets the image spill", near(12, 102, GREEN));
check("a spilled image keeps its bottom rows", near(3, 105, BLUE));

// scale-down: contain, but never scaling an image up past its intrinsic size.
check("scale-down leaves an image smaller than its box alone", near(205, 12, WHITE));
check("scale-down keeps that image's intrinsic position", near(213, 17, RED));
// The 8x4 box at x=250 scales by 0.5, so each quadrant is 4x2.
check("scale-down fits a small image", near(252, 1, RED));
check("scale-down fills a small box exactly", near(256, 1, GREEN));
check("scale-down keeps a small box's rounding", near(252, 3, BLUE));

// object-position with `none`, which leaves free space on both axes.
// top right at (0, 50): the image sits at (24, 50).
check("top right moves the image to the top", near(25, 52, RED));
check("top right moves the image to the right", near(35, 52, GREEN));
// bottom left at (50, 50): the image sits at (50, 82).
check("bottom left moves the image down", near(53, 84, RED));
check("bottom left reaches its bottom row", near(53, 87, BLUE));
// bottom 1px right 2px at (100, 50): the image sits at (122, 81).
check("a length from the right edge moves the image left", near(123, 82, RED));
check("a length from the bottom edge moves the image up", near(123, 87, BLUE));

// image-rendering: pixelated keeps the quadrant edge sharp, auto interpolates it.
check("pixelated keeps the source's last red column", near(79, 145, RED));
check("pixelated starts the green column sharply", near(80, 145, GREEN));
const seam = at(82, 245);
check("auto interpolates the edge", seam[0] > 20 && seam[1] < 235 ? null : `got ${seam.join(",")}, want a blend of red and green`);

// image-orientation: the EXIF 6 image displays 8 wide and 16 tall, rotated clockwise, so its
// top-left is the stored bottom-left (blue). With `none` it stays 16x8 and unrotated.
check("EXIF orientation swaps the intrinsic size", near(202, 145, BLUE));
check("EXIF orientation rotates the quadrants", near(205, 145, RED));
check("EXIF orientation keeps the far corner", near(202, 153, YELLOW));
check("image-orientation: none keeps the stored size", near(232, 152, RED));
check("image-orientation: none keeps the stored bottom-left", near(232, 156, BLUE));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
