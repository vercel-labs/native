// Font sizes that rest on `medium`, and a replaced element that can't be a table cell.
//
// The generic `monospace` family's medium size is 13px, not 16px, and a size still resting on
// `medium` (an em chain from the initial size) follows the family across that ratio, while a size
// from an explicit length does not. A replaced element has no content to be a cell, row or column
// of, so a table display on it is laid out as inline content, and an anonymous cell wraps it
// together with the white space around it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"><style>
body { margin: 0; font-size: medium; }
#mono { font-family: monospace; }
#chain { font-size: 1.5em; }
#explicit { font-size: 20px; }
#cross { font-family: monospace; font-size: 1.5em; }
#keyword { font-family: monospace; font-size: medium; }
#t { display: table; white-space: pre; border-spacing: 0; }
#row { display: table-row; }
.tc { display: table-cell; }
</style></head><body>
<div id="mono"><span id="chain">x</span></div>
<div id="explicit"><span id="cross">x</span></div>
<div id="keyword">x</div>
<div id="t"><div id="row">   <canvas class="tc" width="10" height="10"></canvas>   <div class="tc" id="blue" style="width: 10px; height: 10px; background: #0000ff"></div></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `const size = (id: string): string => getComputedStyle(document.getElementById(id) as HTMLElement).fontSize;
console.log("body=" + size("mono"));
console.log("chain=" + size("chain"));
console.log("explicit=" + size("explicit"));
console.log("cross=" + size("cross"));
console.log("keyword=" + size("keyword"));
const c = document.querySelector("canvas") as HTMLCanvasElement;
const ctx = c.getContext("2d")!;
ctx.fillStyle = "#ff0000";
ctx.fillRect(0, 0, 10, 10);
`;

const dir = mkdtempSync(join(tmpdir(), "native-table-anonymous-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const png = join(dir, "out.png");
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);
const out = `${run.stdout}${run.stderr}`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const lines = out.split("\n").map((l) => l.trim());
function logged(name: string, want: string): void {
  check(name, lines.includes(`${name}=${want}`), `wanted "${name}=${want}", got:\n${out.trim()}`);
}

// The monospace family's medium is 13px; the system font's is 16px.
logged("body", "13px");
// 1.5em of the monospace medium, so 19.5px, and not scaled again by the family it inherited.
logged("chain", "19.5px");
// No medium in this one's chain: 20px, and 1.5em of it stays 20px × 1.5 whatever the family.
logged("explicit", "20px");
logged("cross", "30px");
logged("keyword", "13px");

const img = decodePng(png);
const px = (x: number, y: number): number[] => {
  const o = (y * img.w + x) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const isBlue = (p: number[]): boolean => p[2] > 200 && p[0] < 60 && p[1] < 60;
const isRed = (p: number[]): boolean => p[0] > 200 && p[1] < 60 && p[2] < 60;

/** The leftmost CSS x where `match` draws at device row 2y, or -1. */
function firstX(y: number, match: (p: number[]) => boolean): number {
  for (let x = 0; x < img.w; x += 2) if (match(px(x, y))) return x / 2;
  return -1;
}

const blueY = firstRow(isBlue);
const redY = firstRow(isRed);
check("the canvas paints inside the row", redY >= 0 && firstX(redY, isRed) >= 0, `no red pixel (row ${redY})`);
check("the cell after it paints", blueY >= 0, "no blue pixel");
// The anonymous cell holds the preserved spaces on either side of the canvas, so the cell after
// it starts past the canvas's 10px plus those two spaces. A canvas taken as a cell would start
// its neighbour at 10px, with the spaces making anonymous cells of their own.
const blueX = blueY >= 0 ? firstX(blueY, isBlue) : -1;
check("the white space joins the anonymous cell around the canvas", blueX >= 22, `blue starts at x=${blueX}`);

/** The first device row that holds a pixel `match` draws. */
function firstRow(match: (p: number[]) => boolean): number {
  for (let y = 0; y < img.h; y += 2) {
    for (let x = 0; x < img.w; x += 2) if (match(px(x, y))) return y;
  }
  return -1;
}

if (failed > 0) process.exit(1);
console.log("\nall passed");
