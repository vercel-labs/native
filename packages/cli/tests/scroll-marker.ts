// Scroll markers: a scroll container with a marker group generates ::scroll-marker-group after
// itself, holding one ::scroll-marker box per child, styled by each child's own rule.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=160"><style>
body { margin: 0; font: 16px monospace; }
#scroller { width: 200px; height: 100px; overflow: scroll; scroll-marker-group: after; }
#scroller div { width: 200px; height: 100px; background: rgb(0, 128, 0); }
#scroller div::scroll-marker { content: ""; width: 10px; height: 10px; margin-right: 4px; background-color: rgb(0, 0, 255); }
#scroller::scroll-marker-group { border: 2px solid rgb(0, 0, 0); padding: 2px; display: block; }
</style></head><body>
<div id="scroller"><div></div><div></div><div></div></div>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-scroll-marker-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const shot = decodePng(png);
/** The colour at a point in CSS pixels. */
const at = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * shot.w + Math.round(x * 2)) * 4;
  return [shot.rgba[o], shot.rgba[o + 1], shot.rgba[o + 2]];
};
const near = (got: number[], want: number[], tol = 24): boolean =>
  Math.abs(got[0] - want[0]) <= tol && Math.abs(got[1] - want[1]) <= tol && Math.abs(got[2] - want[2]) <= tol;

const green = [0, 128, 0], blue = [0, 0, 255], black = [0, 0, 0], white = [255, 255, 255];

check("the scroll container paints its items", near(at(100, 50), green), `got ${at(100, 50)}`);

// The three markers are 10x10 inline-blocks in a row, so the blue is exactly their area, and it
// starts after the group's 2px border and 2px padding.
let blueCount = 0, minX = 1e9, maxX = -1, minY = 1e9, maxY = -1;
for (let y = 0; y < shot.h; y++) {
  for (let x = 0; x < shot.w; x++) {
    const o = (y * shot.w + x) * 4;
    if (!(shot.rgba[o + 2] > 200 && shot.rgba[o] < 60 && shot.rgba[o + 1] < 60)) continue;
    blueCount++;
    minX = Math.min(minX, x); maxX = Math.max(maxX, x);
    minY = Math.min(minY, y); maxY = Math.max(maxY, y);
  }
}
check("each child makes a 10x10 marker", blueCount === 3 * 10 * 10 * 4, `${blueCount} blue pixels`);
check("the markers start inside the group's border and padding", minX === 8 && maxX === 83,
  `x ${minX}..${maxX}`);
check("the markers sit below the scroll container", minY > 200, `y ${minY}..${maxY}`);
check("a marker is 10px tall", maxY - minY === 19, `y ${minY}..${maxY}`);
// The group's 2px border wraps the markers: a black run above them and another below.
let blackAbove = 0, blackBelow = 0;
for (let y = 0; y < shot.h; y++) {
  for (let x = minX; x <= maxX; x++) {
    const o = (y * shot.w + x) * 4;
    if (!(shot.rgba[o] < 40 && shot.rgba[o + 1] < 40 && shot.rgba[o + 2] < 40)) continue;
    if (y < minY) blackAbove++;
    else if (y > maxY) blackBelow++;
  }
}
check("the group's border encloses the markers", blackAbove > 0 && blackBelow > 0,
  `${blackAbove} black above, ${blackBelow} below`);

// :target-current names the marker whose item the scrollport starts at, and activating a marker
// scrolls its container to that item.
const CURRENT_PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=160"><style>
body { margin: 0; font: 16px monospace; }
#scroller { width: 200px; height: 100px; overflow: scroll; scroll-marker-group: after; }
#scroller div { width: 200px; height: 100px; background: rgb(0, 128, 0); }
#scroller div::scroll-marker { content: ""; width: 10px; height: 10px; margin-right: 4px; background-color: rgb(0, 0, 255); }
#scroller div::scroll-marker:target-current { background-color: rgb(255, 0, 0); }
#scroller::scroll-marker-group { border: 2px solid rgb(0, 0, 0); padding: 2px; display: block; }
</style></head><body>
<div id="scroller"><div></div><div></div><div></div></div>
</body></html>`;

const currentDir = mkdtempSync(join(tmpdir(), "native-scroll-marker-current-"));
writeFileSync(join(currentDir, "index.html"), CURRENT_PAGE);
const currentExe = join(currentDir, "app");
const cb = spawnSync("node", ["compiler/cli.ts", "build", currentDir, "-o", currentExe], { encoding: "utf8" });
if (cb.status !== 0) throw new Error(`build failed\n${cb.stderr}`);

let shots = 0;
/** Runs the page with `steps` and returns its snapshot and what it printed. */
function runCurrent(steps?: string): { img: ReturnType<typeof decodePng>; out: string } {
  const outPng = join(currentDir, `out-${shots++}.png`);
  const env = steps === undefined
    ? { ...process.env, NATIVE_SNAPSHOT: outPng }
    : { ...process.env, NATIVE_SNAPSHOT: outPng, NATIVE_STEPS: steps };
  const run = spawnSync(currentExe, [], { encoding: "utf8", env });
  if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);
  return { img: decodePng(outPng), out: `${run.stdout}${run.stderr}` };
}

/** Where the pixels `pick` names are, and how many, in the snapshot's own (2x) pixels. */
function bounds(img: ReturnType<typeof decodePng>,
  pick: (r: number, g: number, b: number) => boolean): { count: number; minX: number; maxX: number; minY: number; maxY: number } {
  let count = 0, minX = 1e9, maxX = -1, minY = 1e9, maxY = -1;
  for (let y = 0; y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (!pick(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2])) continue;
      count++;
      minX = Math.min(minX, x); maxX = Math.max(maxX, x);
      minY = Math.min(minY, y); maxY = Math.max(maxY, y);
    }
  }
  return { count, minX, maxX, minY, maxY };
}
const isRed = (r: number, g: number, b: number): boolean => r > 200 && g < 60 && b < 60;
const isBlue = (r: number, g: number, b: number): boolean => b > 200 && r < 60 && g < 60;
const marker = 10 * 10 * 4; // a 10px marker at 2x

const start = runCurrent();
const red0 = bounds(start.img, isRed);
const blue0 = bounds(start.img, isBlue);
check("one marker is current at the start", red0.count === marker, `${red0.count} red pixels`);
check("it is the first item's marker", red0.maxX < blue0.minX,
  `red x ${red0.minX}..${red0.maxX}, blue x ${blue0.minX}..${blue0.maxX}`);
check("the other two markers are not", blue0.count === 2 * marker, `${blue0.count} blue pixels`);

// A wheel scroll to the second item moves the current marker with the scrollport.
const wheeled = runCurrent("wheel #scroller 100 | scrolltop #scroller");
check("the wheel scrolled to the second item", wheeled.out.includes("100"), wheeled.out.trim());
const red1 = bounds(wheeled.img, isRed);
check("the current marker follows the scrollport", red1.count === marker && red1.minX > red0.maxX,
  `${red1.count} red pixels, x ${red1.minX}..${red1.maxX}`);

// Activating the third marker scrolls its item to the start of the scrollport.
const thirdX = (blue0.maxX - 9.5) / 2;
const markerY = (blue0.minY + blue0.maxY) / 4;
const clicked = runCurrent(`clickat ${thirdX} ${markerY} | scrolltop #scroller`);
check("clicking a marker scrolls its item to the start", clicked.out.includes("200"), clicked.out.trim());
const red2 = bounds(clicked.img, isRed);
check("the clicked item's marker is current", red2.count === marker && red2.minX > red1.maxX,
  `${red2.count} red pixels, x ${red2.minX}..${red2.maxX}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
