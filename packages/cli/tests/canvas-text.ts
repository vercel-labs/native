// The canvas 2D text metrics: measureText reports a run's advance and the box its ink covers, the
// font's own ascent and descent, and the baselines. The ink box is checked against where fillText
// actually put the pixels — the one thing that must agree whatever the font is — and a run of
// spaces, which covers no pixels, reports zeros the way a browser's does.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=160"><style>
body { margin: 0; background: #ffffff; }
canvas { position: absolute; left: 0; top: 0; }
</style></head><body>
<canvas id="c" width="240" height="160"></canvas>
<script src="app.ts"></script>
</body></html>`;

// The run is drawn at a known place, so the driver can compare the ink box against the pixels.
const SCRIPT = `
const ctx = (document.getElementById("c") as HTMLCanvasElement).getContext("2d")!;
ctx.fillStyle = "#ffffff";
ctx.fillRect(0, 0, 240, 160);
ctx.font = "20px sans-serif";
const run = ctx.measureText("Aj");
console.log("width " + run.width.toFixed(2));
console.log("ink " + run.actualBoundingBoxLeft.toFixed(2) + " " + run.actualBoundingBoxRight.toFixed(2)
  + " " + run.actualBoundingBoxAscent.toFixed(2) + " " + run.actualBoundingBoxDescent.toFixed(2));
console.log("font " + run.fontBoundingBoxAscent.toFixed(2) + " " + run.fontBoundingBoxDescent.toFixed(2));
console.log("baselines " + run.hangingBaseline.toFixed(2) + " " + run.alphabeticBaseline.toFixed(2)
  + " " + run.ideographicBaseline.toFixed(2));
const space = ctx.measureText(" ");
console.log("space " + space.width.toFixed(2) + " " + space.actualBoundingBoxAscent + " "
  + space.actualBoundingBoxRight.toFixed(2));
const empty = ctx.measureText("");
console.log("empty " + empty.width + " " + empty.actualBoundingBoxAscent + " " + empty.actualBoundingBoxDescent
  + " " + (empty.fontBoundingBoxAscent > 0 ? 1 : 0));
ctx.fillStyle = "#000000";
ctx.fillText("Aj", 40, 120);
`;

const dir = mkdtempSync(join(tmpdir(), "native-canvas-text-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const lines = r.stdout.split("\n").map((l) => l.trim()).filter((l) => l !== "");
const img: Image = decodePng(png);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function value(line: string): number[] {
  return line.split(" ").slice(1).map(Number);
}

const width = value(lines[0])[0];
const [left, right, ascent, descent] = value(lines[1]);
const [fontAscent, fontDescent] = value(lines[2]);
const [hanging, alphabetic, ideographic] = value(lines[3]);
const space = value(lines[4]);
const empty = value(lines[5]);

check("the run advances", width > 0, `width ${width}`);
check("the ink rises above the baseline", ascent > 0, `ascent ${ascent}`);
check("the ink of a descender falls below it", descent > 0, `descent ${descent}`);
check("the ink stays inside the advance, almost", left > -width / 2 && right > 0 && right < width + 1,
  `left ${left}, right ${right}, width ${width}`);
check("the font box holds the ink", fontAscent > ascent && fontDescent >= 0,
  `font ${fontAscent}/${fontDescent}, ink ${ascent}/${descent}`);
check("the baselines are the font's and the size's", hanging === 14 && alphabetic === 0 && ideographic === -fontDescent,
  `hanging ${hanging}, alphabetic ${alphabetic}, ideographic ${ideographic}`);

check("a space advances without ink", space[0] > 0 && space[1] === 0 && space[2] === 0,
  `space ${JSON.stringify(space)}`);
check("an empty run is nothing but the font box", empty[0] === 0 && empty[1] === 0 && empty[2] === 0 && empty[3] === 1,
  `empty ${JSON.stringify(empty)}`);

// The pixels the run put down, in CSS px: the snapshot is 2 device px per CSS px.
const dark: number[] = [];
for (let y = 0; y < img.h; y++) {
  for (let x = 0; x < img.w; x++) {
    const o = (y * img.w + x) * 4;
    if (img.rgba[o] < 128) dark.push(x, y);
  }
}
let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
for (let i = 0; i < dark.length; i += 2) {
  if (dark[i] < x0) x0 = dark[i];
  if (dark[i] > x1) x1 = dark[i];
  if (dark[i + 1] < y0) y0 = dark[i + 1];
  if (dark[i + 1] > y1) y1 = dark[i + 1];
}
// The ink box says where the glyphs are: the run starts at x 40 on baseline y 120, so the ink spans
// 40-left to 40+right and 120-ascent to 120+descent. Antialiasing's fringe is a pixel or so.
const near = (got: number, want: number): boolean => Math.abs(got - want) <= 2.5;
check("the ink box starts where measureText says", near(x0 / 2, 40 - left), `pixels ${x0 / 2}, box ${40 - left}`);
check("the ink box ends where measureText says", near(x1 / 2, 40 + right), `pixels ${x1 / 2}, box ${40 + right}`);
check("the ink box tops out where measureText says", near(y0 / 2, 120 - ascent), `pixels ${y0 / 2}, box ${120 - ascent}`);
check("the ink box bottoms out where measureText says", near(y1 / 2, 120 + descent), `pixels ${y1 / 2}, box ${120 + descent}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
