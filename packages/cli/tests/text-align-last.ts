// text-align-last: the last line of a block, and every line a forced break ends, take the
// property's alignment instead of the block's. The expectations below are the same page measured
// in headless Chrome at 2x.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 16px monospace; }
.p { position: absolute; left: 10px; width: 200px; background: #eeeeee; white-space: pre-wrap; }
#a { top: 10px; text-align-last: center; }
#b { top: 70px; text-align-last: right; }
#c { top: 130px; text-align: center; }
</style></head><body>
<div class="p" id="a">short line
second short</div>
<div class="p" id="b">short line
second short</div>
<div class="p" id="c">short line
second short</div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-text-align-last-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const log = `${build.stdout}${build.stderr}`;
for (const value of ["text-align-last: center", "text-align-last: right"]) {
  const line = log.split("\n").find((l) => l.includes(`'${value}'`));
  if (line !== undefined) throw new Error(`the build rejects ${value}: ${line}`);
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
const ink = (cx: number, cy: number): boolean => {
  const o = (Math.round(cy * 2) * img.w + Math.round(cx * 2)) * 4;
  return img.rgba[o] < 140 && img.rgba[o + 1] < 140 && img.rgba[o + 2] < 140;
};
/** The ink's extent in one line band of a block, in CSS px ([left, right]). */
function span(top: number, y0: number, y1: number): number[] | null {
  let minX = Infinity, maxX = -Infinity;
  for (let x = 0; x <= 300; x += 0.5) {
    for (let y = top + y0; y <= top + y1; y += 0.5) {
      if (!ink(x, y)) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
    }
  }
  return minX === Infinity ? null : [minX, maxX];
}
const near = (got: number[] | null, want: number[]): boolean => got !== null &&
  got.every((v, i) => Math.abs(v - want[i]) <= 1);

// `center` puts both lines in the middle of the 200px block; the block starts at x=10.
const a1 = span(10, 1, 15), a2 = span(10, 17, 31);
check("text-align-last: center centres the last line", near(a2, [54, 166]), JSON.stringify(a2));
check("and the line a forced break ended", near(a1, [63.5, 157]), JSON.stringify(a1));
// `right` lines both up against the block's right edge.
const b1 = span(70, 1, 15), b2 = span(70, 17, 31);
check("text-align-last: right lines the last line up at the edge", near(b2, [96, 208.5]),
  JSON.stringify(b2));
check("and the line a forced break ended", near(b1, [115, 208.5]), JSON.stringify(b1));
// `auto` follows text-align, which centres every line.
const c2 = span(130, 17, 31);
check("text-align-last: auto follows text-align", near(c2, [54, 166]), JSON.stringify(c2));

if (failed > 0) {
  console.error(`\n${failed} text-align-last check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall text-align-last checks passed");
