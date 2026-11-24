// Collapsed table borders: each segment of a grid line is resolved on its own, so a wider border
// on one cell widens only the stretch of the line that cell sits beside.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

// Three columns and three rows of fixed-size cells. The middle cell has red 3px left and right
// borders, both of them on interior grid lines; the last cell has a blue 3px top border.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; }
table { margin: 20px; border-collapse: collapse; border: 4px solid navy; }
td { width: 40px; height: 20px; border: 1px solid #94a3b8; padding: 0; }
#wide { border-left: 3px solid #ff0000; border-right: 3px solid #ff0000; }
#tall { border-top: 3px solid #0000ff; }
</style></head><body>
<table>
  <tr><td></td><td></td><td></td></tr>
  <tr><td></td><td id="wide"></td><td></td></tr>
  <tr><td></td><td></td><td id="tall"></td></tr>
</table>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `console.log("cells=" + document.querySelectorAll("td").length);`;

const dir = mkdtempSync(join(tmpdir(), "native-collapsed-borders-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
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
const px = (x: number, y: number): number[] => {
  const o = (y * img.w + x) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const isRed = (p: number[]): boolean => p[0] > 200 && p[1] < 60 && p[2] < 60;
const isBlue = (p: number[]): boolean => p[2] > 200 && p[0] < 60 && p[1] < 60;
const isGray = (p: number[]): boolean => Math.abs(p[0] - 0x94) < 40 && Math.abs(p[1] - 0xa3) < 40 && Math.abs(p[2] - 0xb8) < 40;

/** The contiguous horizontal runs of `match` in device row `y`, as [start, end] pairs. */
function rowRuns(y: number, match: (p: number[]) => boolean): number[][] {
  const runs: number[][] = [];
  let start = -1;
  for (let x = 0; x <= img.w; x++) {
    const hit = x < img.w && match(px(x, y));
    if (hit && start < 0) start = x;
    if (!hit && start >= 0) {
      runs.push([start, x - 1]);
      start = -1;
    }
  }
  return runs;
}

/** The contiguous vertical runs of `match` in device column `x`, as [start, end] pairs. */
function colRuns(x: number, match: (p: number[]) => boolean): number[][] {
  const runs: number[][] = [];
  let start = -1;
  for (let y = 0; y <= img.h; y++) {
    const hit = y < img.h && match(px(x, y));
    if (hit && start < 0) start = y;
    if (!hit && start >= 0) {
      runs.push([start, y - 1]);
      start = -1;
    }
  }
  return runs;
}

// The red cell is in the middle row. Its two 3px borders are the widest on those column edges, so
// they are the only red in the picture.
let redRows: number[] = [];
for (let y = 0; y < img.h; y++) if (rowRuns(y, isRed).length > 0) redRows.push(y);
check("the wide borders paint", redRows.length > 0, `${redRows.length} red rows`);
if (redRows.length > 0) {
  const mid = redRows[Math.floor(redRows.length / 2)];
  const runs = rowRuns(mid, isRed);
  check("both sides of the cell widened", runs.length === 2, `${runs.length} red runs`);
  const wide = runs.map((r) => r[1] - r[0] + 1);
  check("a 3px segment is 3 CSS px wide", wide.every((w) => w >= 5 && w <= 7), wide.join("/"));
  // Only its own row: 20px of content plus the shared lines, 21 CSS px.
  check("a wide segment spans only its own row", redRows.length >= 38 && redRows.length <= 46,
    `${redRows.length} device px tall`);

  // Above it, the same column edge is a 1px segment: the line is 2 device pixels wide and not red.
  const above = redRows[0] - 12;
  const boundary = runs[0][0] + 2;
  const grayRun = rowRuns(above, isGray).find((r) => r[0] <= boundary && r[1] >= boundary - 1);
  check("the narrow segment keeps its own width",
    grayRun !== undefined && grayRun[1] - grayRun[0] + 1 === 2,
    grayRun === undefined ? "no line above" : `${grayRun[1] - grayRun[0] + 1} device px`);
  check("the wide border stays out of the other rows", rowRuns(above, isRed).length === 0);
}

// The blue top border of the bottom-right cell widens the horizontal line only in its own column.
let blueCols: number[] = [];
for (let x = 0; x < img.w; x++) if (colRuns(x, isBlue).length > 0) blueCols.push(x);
check("a horizontal segment paints", blueCols.length > 0, `${blueCols.length} blue columns`);
if (blueCols.length > 0) {
  const mid = blueCols[Math.floor(blueCols.length / 2)];
  const runs = colRuns(mid, isBlue);
  check("a horizontal segment is 3 CSS px tall", runs.length === 1 && runs[0][1] - runs[0][0] + 1 >= 5 &&
    runs[0][1] - runs[0][0] + 1 <= 7, JSON.stringify(runs));
  // One column: 40px of content plus the shared lines around it.
  check("a wide horizontal segment spans its column", blueCols.length >= 78 && blueCols.length <= 90,
    `${blueCols.length} device px wide`);
  // The bottom row's top line is the one the middle row's borders end on.
  check("segments land on the same grid", Math.abs(runs[0][0] - redRows[redRows.length - 1]) <= 4,
    `blue ${runs[0][0]} red ends ${redRows[redRows.length - 1]}`);
}

const lines = `${run.stdout}${run.stderr}`.split("\n");
check("the page renders", lines.includes("cells=9"), run.stdout);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
