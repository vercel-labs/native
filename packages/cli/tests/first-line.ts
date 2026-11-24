// ::first-line and ::first-letter: the first formatted line's colour, its background, and the
// first letter's own colour; a later line keeps the element's.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; background: #ffffff; }
#a { position: absolute; left: 0; top: 0; font: 40px monospace; color: #000000; white-space: pre; }
#a::first-line { color: rgb(0, 0, 255); background-color: rgb(255, 0, 0); }
#a::first-letter { color: rgb(0, 255, 0); }
#b { position: absolute; left: 0; top: 120px; font: 40px monospace; color: #000000; }
#b::first-line { color: rgb(0, 0, 255); }
</style></head><body>
<div id="a">WW
WW</div>
<div id="b">WW WW</div>
</body></html>`;

function buildAndRun(): Image {
  const dir = mkdtempSync(join(tmpdir(), "native-first-line-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return decodePng(png);
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const img = buildAndRun();
const px = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
/** How many pixels of the CSS rect come within `tol` of `want`. */
function ink(x0: number, y0: number, x1: number, y1: number, want: number[], tol = 40): number {
  let n = 0;
  for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
    for (let x = Math.round(x0 * 2); x < Math.round(x1 * 2); x++) {
      const o = (y * img.w + x) * 4;
      if (Math.abs(img.rgba[o] - want[0]) <= tol && Math.abs(img.rgba[o + 1] - want[1]) <= tol &&
        Math.abs(img.rgba[o + 2] - want[2]) <= tol) n++;
    }
  }
  return n;
}
const GREEN = [0, 255, 0];
const BLUE = [0, 0, 255];
const RED = [255, 0, 0];
const BLACK = [0, 0, 0];

// The first letter of #a is green, the rest of the first line blue, over a red line background.
check("::first-letter colours the first glyph", ink(0, 0, 24, 46, GREEN) >= 4,
  `${ink(0, 0, 24, 46, GREEN)} green pixels`);
check("::first-line colours the rest of the line", ink(24, 0, 96, 46, BLUE) >= 8,
  `${ink(24, 0, 96, 46, BLUE)} blue pixels`);
check("::first-line paints its background", ink(0, 0, 96, 4, RED, 12) >= 8,
  `${ink(0, 0, 96, 4, RED, 12)} red pixels`);
// The second line of #a is not the first line: it keeps the element's own colour.
check("a later line keeps the element's colour", ink(0, 48, 96, 94, BLACK, 60) >= 8,
  `${ink(0, 48, 96, 94, BLACK, 60)} black pixels`);

// #b wraps "WW WW" onto one line, and the whole first line takes ::first-line's colour.
check("::first-line colours a line whose text follows the first word", ink(24, 120, 120, 166, BLUE) >= 8,
  `${ink(24, 120, 120, 166, BLUE)} blue pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
