// The canvas 2D filter: the CSS filter functions a drawing operation goes through, one at a time
// and in a chain, what the property does across save and restore, and what an unusable string
// leaves behind. The colour results are Chrome's, to within a step of rounding; a blur is checked
// by its shape — the middle of a big rect stays its colour, the edge comes out half covered, and
// the ramp dies away — since no two implementations cut a Gaussian kernel the same way.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=120, height=80"><style>
body { margin: 0; background: #ffffff; }
canvas { position: absolute; left: 0; top: 0; }
</style></head><body>
<canvas id="c" width="120" height="80"></canvas>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const ctx = (document.getElementById("c") as HTMLCanvasElement).getContext("2d")!;
const at = (data: ImageData, x: number, y: number): string => {
  const i = (y * data.width + x) * 4;
  return data.data[i] + " " + data.data[i + 1] + " " + data.data[i + 2] + " " + data.data[i + 3];
};

// One rect drawn under one filter, read back from the middle of it.
const probe = (filter: string, fill: string): string => {
  ctx.clearRect(0, 0, 120, 80);
  ctx.filter = filter;
  ctx.fillStyle = fill;
  ctx.fillRect(20, 20, 40, 40);
  ctx.filter = "none";
  return at(ctx.getImageData(40, 40, 1, 1), 0, 0);
};

console.log("invert " + probe("invert(1)", "#ff0000"));
console.log("invert half " + probe("invert(0.5)", "#ff0000"));
console.log("brightness " + probe("brightness(0.5)", "#ff8000"));
console.log("grayscale " + probe("grayscale(1)", "#ff0000"));
console.log("saturate " + probe("saturate(0)", "#ff0000"));
console.log("sepia " + probe("sepia(1)", "#ff0000"));
console.log("contrast " + probe("contrast(2)", "#ff0000"));
console.log("hue " + probe("hue-rotate(90deg)", "#ff0000"));
console.log("hue turn " + probe("hue-rotate(0.5turn)", "#ff0000"));
console.log("chain " + probe("invert(1) grayscale(1)", "#ff0000"));
console.log("percent " + probe("brightness(50%)", "#ff0000"));
console.log("opacity " + probe("opacity(0.5)", "#ff0000"));

// A filter covers paths and strokes as well as rects.
ctx.clearRect(0, 0, 120, 80);
ctx.filter = "invert(1)";
ctx.fillStyle = "#ff0000";
ctx.beginPath();
ctx.rect(20, 20, 40, 40);
ctx.fill();
ctx.filter = "none";
console.log("path " + at(ctx.getImageData(40, 40, 1, 1), 0, 0));

// The property reads back what was set, keeps what it had when given something unusable, and a
// save and restore put it back.
ctx.filter = "blur(2px)";
console.log("get " + ctx.filter);
ctx.filter = "bogus";
console.log("invalid " + ctx.filter);
ctx.filter = "invert(1)";
ctx.save();
ctx.filter = "grayscale(1)";
ctx.restore();
console.log("restored " + ctx.filter);
ctx.clearRect(0, 0, 120, 80);
ctx.fillStyle = "#ff0000";
ctx.fillRect(20, 20, 40, 40);
console.log("restored draw " + at(ctx.getImageData(40, 40, 1, 1), 0, 0));
ctx.filter = "none";
console.log("cleared " + ctx.filter);

// A blur is a Gaussian of the given standard deviation: an edge goes to half coverage, and the
// ramp reaches a few sigma out and no further.
ctx.clearRect(0, 0, 120, 80);
ctx.filter = "blur(3px)";
ctx.fillStyle = "#ff0000";
ctx.fillRect(40, 20, 40, 40);
ctx.filter = "none";
const blurred = ctx.getImageData(0, 0, 120, 80);
console.log("blur middle " + at(blurred, 60, 40));
console.log("blur edge " + at(blurred, 40, 40));
console.log("blur ramp " + at(blurred, 36, 40));
console.log("blur far " + at(blurred, 20, 40));

// The snapshot was taken before the script cleared anything: the red rect above is what it shows,
// drawn with no filter.
`;

// What each probe's line should say: the filter, then the colour Chrome's canvas reads back.
const COLOURS: string[][] = [
  ["invert", "0 255 255 255"],
  ["invert half", "127 127 127 255"],
  ["brightness", "127 64 0 255"],
  ["grayscale", "54 54 54 255"],
  ["saturate", "54 54 54 255"],
  ["sepia", "100 89 69 255"],
  ["contrast", "255 0 0 255"],
  ["hue", "0 91 0 255"],
  ["hue turn", "0 109 109 255"],
  ["chain", "201 201 201 255"],
  ["percent", "127 0 0 255"],
  ["opacity", "255 0 0 128"],
  ["path", "0 255 255 255"],
];

const dir = mkdtempSync(join(tmpdir(), "native-canvas-filter-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const staged = join(dir, "staged.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: staged } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
const img: Image = decodePng(staged);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

/** The numbers at the end of a log line: its colour, as "r g b a". */
function parts(line: string, count = 4): number[] {
  const tokens = line.split(" ");
  return tokens.slice(Math.max(0, tokens.length - count)).map(Number);
}

/** The colour a line reports, every channel within `tol` of the one wanted. */
function colour(name: string, line: string | undefined, want: number[], tol = 2): void {
  if (line === undefined) {
    check(name, false, "no line");
    return;
  }
  const have = parts(line, want.length);
  const ok = have.length === want.length && want.every((v, i) => Math.abs(have[i] - v) <= tol);
  check(name, ok, `got ${JSON.stringify(line)}`);
}

check(`log lines (${COLOURS.length + 9})`, got.length === COLOURS.length + 9, `got ${JSON.stringify(got)}`);
for (let i = 0; i < COLOURS.length && i < got.length; i++) {
  colour(COLOURS[i][0], got[i], parts(COLOURS[i][1]));
  check(`  ${COLOURS[i][0]} is the function that was set`,
    (got[i] ?? "").startsWith(COLOURS[i][0] + " "), `got ${JSON.stringify(got[i])}`);
}

const rest = got.slice(COLOURS.length);

// Every remaining log line, in order: the filter string checks, then the blur's shape.
check("the getter reads back a set filter", rest[0] === "get blur(2px)", `got ${JSON.stringify(rest[0])}`);
check("an unusable string leaves the filter as it was", rest[1] === "invalid blur(2px)", `got ${JSON.stringify(rest[1])}`);
check("restore puts the filter back", rest[2] === "restored invert(1)", `got ${JSON.stringify(rest[2])}`);
colour("the restored filter filters what it draws", rest[3], [0, 255, 255, 255]);
check("none clears the filter", rest[4] === "cleared none", `got ${JSON.stringify(rest[4])}`);

colour("a blurred middle keeps its colour", rest[5], [255, 0, 0, 255]);
{
  const edge = parts(rest[6] ?? "");
  check("a blurred edge is half covered, still red", edge[0] === 255 && edge[1] === 0 && edge[2] === 0
    && edge[3] >= 110 && edge[3] <= 145, `got ${JSON.stringify(rest[6])}`);
}
{
  const ramp = parts(rest[7] ?? "");
  check("the ramp is faint four pixels out", ramp[0] === 255 && ramp[3] >= 10 && ramp[3] <= 40,
    `got ${JSON.stringify(rest[7])}`);
}
check("the ramp ends well short of a dozen pixels", (rest[8] ?? "") === "blur far 0 0 0 0", `got ${JSON.stringify(rest[8])}`);

/** The pixel at CSS coordinates (cx, cy), as "r,g,b"; the snapshot is 2 device px per CSS px. */
function at(cx: number, cy: number): string {
  const o = (cy * 2 * img.w + cx * 2) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
}

check("the last draw is on the page unfiltered", at(60, 40) === "255,0,0" && at(10, 10) === "255,255,255",
  `got ${at(60, 40)} and ${at(10, 10)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
