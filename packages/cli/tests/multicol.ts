// Multi-column layout: a set count splits the content into that many columns, columns balance
// when the height is auto, fill in order when it is not, and a spanning child takes the width.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><style>
body { margin: 0; background: #ffffff; font: 10px/1 sans-serif; }
#m0 { columns: 2; column-gap: 0; width: 200px; height: 100px; column-fill: auto; }
#m0 > div { font-size: 0; }
#m0 #g1 { background: #0000ff; border: 5px solid #ff0000; }
#m0 #g1 > div { height: 50px; }
#m1 { columns: 3; column-gap: 10px; width: 320px; }
#m1 > div { height: 40px; font-size: 0; }
#m2 { columns: 2; column-gap: 10px; width: 200px; height: 100px; column-fill: auto;
      column-rule: 2px solid #ff0000; margin-top: 20px; }
#m2 > div { height: 60px; font-size: 0; }
#m3 { columns: 2; column-gap: 10px; width: 200px; margin-top: 20px; }
#m3 > div { height: 60px; font-size: 0; }
#m3 #s3 { column-span: all; height: 10px; background: #000000; }
#m4 { columns: 2; column-gap: 0; width: 200px; height: 150px; column-fill: auto; margin-top: 20px; }
#m4 > div { height: 50px; font-size: 0; }
#m4 #d3 { break-before: column; }
#m5 { columns: 2; column-gap: 0; width: 200px; height: 150px; column-fill: auto; margin-top: 20px; }
#m5 > div { height: 50px; font-size: 0; }
#m5 #e4 { break-before: avoid; }
#m6 { columns: 2; column-gap: 0; width: 200px; height: 100px; column-fill: auto; margin-top: 20px; }
#m6 > div { height: 50px; margin-bottom: 20px; font-size: 0; }
#m6 #f2 { margin-top: 20px; }
#m7 { columns: 2; column-height: 25px; column-wrap: wrap; column-gap: 0; width: 200px; margin-top: 20px; }
#m7 > div { height: 60px; font-size: 0; background: #0000ff; }
.c1 { background: #ff0000; } .c2 { background: #00ff00; } .c3 { background: #0000ff; } .c4 { background: #ffff00; }
</style></head><body>
<div id="m0"><div id="g1"><div id="g1a"></div><div id="g1b"></div></div></div>
<div id="m7"><div id="n7"></div></div>
<div id="m1"><div id="a1" class="c1"></div><div id="a2" class="c2"></div><div id="a3" class="c3"></div><div id="a4" class="c4"></div></div>
<div id="m2"><div id="b1" class="c1"></div><div id="b2" class="c2"></div></div>
<div id="m3"><div id="c1" class="c1"></div><div id="s3"></div><div id="c2" class="c2"></div></div>
<div id="m4"><div id="d1"></div><div id="d2"></div><div id="d3"></div><div id="d4"></div></div>
<div id="m5"><div id="e1"></div><div id="e2"></div><div id="e3"></div><div id="e4"></div></div>
<div id="m6"><div id="f1"></div><div id="f2"></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
window.addEventListener("load", () => {
  const rects = [];
  for (const id of ["m0", "g1", "g1a", "g1b",
                    "m1", "a1", "a2", "a3", "a4", "m2", "b1", "b2", "m3", "c1", "s3", "c2",
                    "m4", "d1", "d2", "d3", "d4", "m5", "e1", "e2", "e3", "e4", "m6", "f1", "f2",
                    "m7", "n7"]) {
    const r = document.getElementById(id)!.getBoundingClientRect();
    rects.push([id, Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]);
  }
  console.log("rects=" + JSON.stringify(rects));
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-multicol-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("multicol compiles without a warning", !/column-count|column-width|columns|column-fill|column-span|column-rule/.test(b.stdout + b.stderr), b.stderr);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const out = `${r.stdout}${r.stderr}`;
const line = out.split("\n").find((l) => l.startsWith("rects="));
const rects: Record<string, number[]> = {};
if (line !== undefined) for (const e of JSON.parse(line.slice(6)) as [string, number, number, number, number][]) {
  rects[e[0]] = [e[1], e[2], e[3], e[4]];
}
const colorAt = (x: number, y: number): string => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};

const near = (a: number | undefined, b: number): boolean => a !== undefined && Math.abs(a - b) <= 1;
// A box taller than its column keeps its content in order across the columns it reaches, and the
// pieces that hold its top and bottom edges are the ones that draw its top and bottom borders.
check("a split box paints its background in every column it reaches",
  colorAt(50, 20) === "0,0,255" && colorAt(150, 20) === "0,0,255",
  `${colorAt(50, 20)} / ${colorAt(150, 20)}`);
check("a split box draws its top border in the first column only",
  colorAt(50, 3) === "255,0,0" && colorAt(150, 3) === "0,0,255",
  `${colorAt(50, 3)} / ${colorAt(150, 3)}`);
check("a split box draws its bottom border in the last column only",
  colorAt(150, 52) === "255,0,0" && colorAt(50, 52) === "0,0,255",
  `${colorAt(150, 52)} / ${colorAt(50, 52)}`);
check("the boxes past a split carry on at the top of the next column",
  near(rects.g1a?.[0], 5) && near(rects.g1a?.[1], 5) && near(rects.g1b?.[0], 105) && near(rects.g1b?.[1], 0),
  JSON.stringify([rects.g1, rects.g1a, rects.g1b]));
const m1t = rects.m1?.[1];
check("three columns of a 320px box are 100px wide", near(rects.a1?.[2], 100), JSON.stringify(rects.a1));
check("the columns balance: two items each",
  m1t !== undefined && near(rects.a2?.[1], m1t + 40) && near(rects.a3?.[0], 110) && near(rects.a3?.[1], m1t),
  JSON.stringify([rects.m1, rects.a1, rects.a2, rects.a3]));
check("the box is as tall as its balanced columns", near(rects.m1?.[3], 80), JSON.stringify(rects.m1));
check("a definite height fills the columns in order", near(rects.b1?.[0], 0) && near(rects.b2?.[0], 105),
  JSON.stringify([rects.b1, rects.b2]));
const m2t = rects.m2?.[1];
check("the column rule sits in the gutter",
  colorAt(99, (m2t ?? 0) + 30) === "255,0,0" && colorAt(96, (m2t ?? 0) + 30) === "255,255,255",
  `${colorAt(96, (m2t ?? 0) + 30)} / ${colorAt(99, (m2t ?? 0) + 30)}`);
const m3t = rects.m3?.[1];
check("a spanning child takes the whole width",
  m3t !== undefined && near(rects.s3?.[2], 200) && near(rects.s3?.[1], m3t + 30),
  JSON.stringify([rects.s3, rects.m3]));
check("content after a spanner starts below it", m3t !== undefined && near(rects.c2?.[1], m3t + 40),
  JSON.stringify(rects.c2));
const mt4 = rects.m4?.[1];
check("break-before: column starts the next column",
  mt4 !== undefined && near(rects.d3?.[0], (rects.m4?.[0] ?? 0) + 100) && near(rects.d3?.[1], mt4) &&
  near(rects.d1?.[1], mt4) && near(rects.d4?.[1], mt4 + 50),
  JSON.stringify([rects.m4, rects.d1, rects.d2, rects.d3, rects.d4]));
const mt5 = rects.m5?.[1];
check("an avoided break moves the boxes above it to the next column",
  mt5 !== undefined && near(rects.e3?.[0], (rects.m5?.[0] ?? 0) + 100) && near(rects.e3?.[1], mt5) &&
  near(rects.e1?.[1], mt5) && near(rects.e4?.[1], mt5 + 50),
  JSON.stringify([rects.m5, rects.e1, rects.e2, rects.e3, rects.e4]));
const mt6 = rects.m6?.[1];
check("margins at a column break are truncated",
  mt6 !== undefined && near(rects.f2?.[0], (rects.m6?.[0] ?? 0) + 100) && near(rects.f2?.[1], mt6),
  JSON.stringify([rects.m6, rects.f1, rects.f2]));

const mt7 = rects.m7?.[1];
const c7 = mt7 === undefined ? ["-", "-", "-", "-"]
  : [colorAt(5, mt7 + 5), colorAt(150, mt7 + 5), colorAt(5, mt7 + 30), colorAt(150, mt7 + 37)];
// A column height of 25 with a row gap of one em (10px): the content fills the first row of two
// columns, the 10px left over balances across the second row, which starts a row gap lower.
check("columns of a column height wrap into rows a row gap apart",
  mt7 !== undefined && near(rects.m7?.[3], 60) &&
  c7[0] === "0,0,255" && c7[1] === "0,0,255" && c7[2] === "255,255,255" && c7[3] === "0,0,255",
  `${c7.join(" / ")} ${JSON.stringify([rects.m7, rects.n7])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
