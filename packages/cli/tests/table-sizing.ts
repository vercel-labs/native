// Table sizing from the inside out: a column's `width` attribute, a cell height that is only a
// minimum, the table's extra height going to the rows that have none of their own, and the
// baseline an inline-table gives the line when its first row holds no line of its own.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=600"><style>
body { margin: 0; font: 16px/1 monospace; }
table { border-spacing: 0; }
td { padding: 0; }
/* A <col> attribute width is the column's width. */
#case1 { position: absolute; left: 0; top: 0; }
#case1 table { table-layout: fixed; }
#case1 .a { background-color: #008000; }
#case1 .b { background-color: #0000ff; }
#case1 td { height: 20px; }
/* A cell's height is a minimum: the 40px box inside the 10px-tall cell makes the row 40px. */
#case2 { position: absolute; left: 0; top: 100px; }
#case2 td { height: 10px; background-color: #ff0000; }
#case2 div { width: 50px; height: 40px; }
/* The table's extra 60px goes to the row with no height of its own, not to all three. */
#case3 { position: absolute; left: 0; top: 200px; }
#case3 table { width: 100px; height: 100px; }
#case3 .a { height: 20px; background-color: #ff0000; }
#case3 .b { background-color: #008000; }
#case3 .c { height: 20px; background-color: #0000ff; }
/* An inline-table whose first row has no line of its own sits on the line by that row's bottom. */
#case4 { position: absolute; left: 0; top: 400px; font-size: 0; }
#case4 .tall { display: inline-block; vertical-align: baseline; width: 20px; height: 100px;
  background-color: #ffa500; }
#case4 table { display: inline-table; width: 40px; }
#case4 .r1 { height: 10px; background-color: #ff0000; }
#case4 .r2 { height: 30px; background-color: #008000; }
</style></head><body>
<div id="case1"><table><col width="40"><col width="60"><tr><td class="a"></td><td class="b"></td></tr></table></div>
<div id="case2"><table><tr><td><div></div></td></tr></table></div>
<div id="case3"><table><tr><td class="a"></td></tr><tr><td class="b"></td></tr>
  <tr><td class="c"></td></tr></table></div>
<div id="case4"><span class="tall"></span><table><tr><td class="r1"></td></tr>
  <tr><td class="r2"></td></tr></table></div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-table-sizing-"));
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
const px = (x: number, y: number): number[] => {
  const o = (y * img.w + x) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (p: number[], c: number[]): boolean =>
  Math.abs(p[0] - c[0]) < 8 && Math.abs(p[1] - c[1]) < 8 && Math.abs(p[2] - c[2]) < 8;
const GREEN = [0x00, 0x80, 0x00];
const BLUE = [0x00, 0x00, 0xff];
const RED = [0xff, 0x00, 0x00];

/** The contiguous runs of `c` in device row `y`, as [start, end] pairs. */
function rowRuns(y: number, c: number[], x0 = 0, x1 = img.w): number[][] {
  const runs: number[][] = [];
  let start = -1;
  for (let x = x0; x <= x1; x++) {
    const hit = x < x1 && near(px(x, y), c);
    if (hit && start < 0) start = x;
    if (!hit && start >= 0) {
      runs.push([start, x - 1]);
      start = -1;
    }
  }
  return runs;
}

/** The contiguous runs of `c` in device column `x`, as [start, end] pairs. */
function colRuns(x: number, c: number[], y0 = 0, y1 = img.h): number[][] {
  const runs: number[][] = [];
  let start = -1;
  for (let y = y0; y <= y1; y++) {
    const hit = y < y1 && near(px(x, y), c);
    if (hit && start < 0) start = y;
    if (!hit && start >= 0) {
      runs.push([start, y - 1]);
      start = -1;
    }
  }
  return runs;
}

const width = (r: number[][]): number => (r.length === 0 ? -1 : r[0][1] - r[0][0] + 1);
const height = (r: number[][]): number => (r.length === 0 ? -1 : r[0][1] - r[0][0] + 1);
const start = (r: number[][]): number => (r.length === 0 ? -1 : r[0][0]);

{
  // 40 and 60 CSS px, in the columns the <col> widths name.
  const g = rowRuns(20, GREEN);
  const b = rowRuns(20, BLUE);
  check("a <col width> sets its column's width", width(g) === 80 && width(b) === 120,
    `green ${width(g)} blue ${width(b)}`);
  check("the second column starts after the first", start(b) === 80, `starts at ${start(b)}`);
}

{
  // The 40px box sets the row, and the red cell's background fills it. The case sits from
  // 100 to 140 CSS px, so look only there.
  const r = colRuns(20, RED, 200, 400);
  check("a cell's height is a minimum its content grows", height(r) === 80, `height ${height(r)}`);
}

{
  // 20 + 60 + 20 CSS px, the middle row taking the extra height.
  const red = colRuns(20, RED, 400, 600);
  const green = colRuns(20, GREEN, 400, 600);
  check("the table's extra height goes to the rows without one",
    height(red) === 40 && height(green) === 120, `red ${height(red)} green ${height(green)}`);
}

{
  // The orange block is 100 CSS px tall and the table's first row 10, so the table's baseline
  // puts its top at 90 and its green second row runs from 100 to 130.
  const orange = colRuns(20, [0xff, 0xa5, 0x00], 800, 1200);
  const green = colRuns(60, GREEN, 800, 1300);
  check("the tall block is 100px", height(orange) === 200, `height ${height(orange)}`);
  check("an inline-table sits on the line by its first row's bottom",
    start(green) === 1000 && height(green) === 60,
    `green starts ${start(green)} high ${height(green)}`);
}

if (failed > 0) {
  console.error(`\n${failed} table sizing check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall table sizing checks passed");
