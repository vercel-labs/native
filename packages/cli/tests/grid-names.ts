// Named grid lines and named areas: a placement naming a line, a line named on more than one
// line with an occurrence count, names counted from the end, `span <name>`, and grid-area placing
// an item in the named area whose name it gives.
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

// The page stacks one grid per case, each with explicit rows so its height is known, and the
// snapshot is 2 device px per CSS px, so a CSS position x is device column 2x.
const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><style>
body { margin: 0; font: 16px/1 sans-serif; }

/* A: a column line named mid, and a pair of names spanning the first two columns */
.a { display: grid; width: 200px; grid-template-rows: 20px;
     grid-template-columns: [left] 50px [mid] 100px [right] 50px [end]; }
.a > div { background: #ff0000; grid-column: mid; }
.b { display: grid; width: 200px; grid-template-rows: 20px;
     grid-template-columns: [left] 50px [mid] 100px [right] 50px [end]; }
.b > div { background: #00ff00; grid-column: left / right; }

/* C: named rows, one side named and both sides named */
.c { display: grid; width: 60px; grid-template-columns: 30px 30px;
     grid-template-rows: [top] 20px [middle] 20px [bottom]; }
.c > .one { grid-column: 1; grid-row: middle; background: #0000ff; }
.c > .two { grid-column: 2; grid-row: top / bottom; background: #ff00ff; }

/* D: a template of named areas, placed by area name and by the area's implicit line names */
.d { display: grid; width: 150px; grid-template-columns: 50px 50px 50px;
     grid-template-rows: 20px 20px;
     grid-template-areas: "head head side"
                          "main foot side"; }
.d > .head { grid-area: head; background: #ff00ff; }
.d > .main { grid-area: main; background: #ffa500; }
.d > .foot { grid-column: foot-start / foot-end; grid-row: 2; background: #808000; }

/* E: a name on several lines, counted from the start and from the end */
.e { display: grid; width: 240px; grid-auto-rows: 20px;
     grid-template-columns: [a] 60px [b] 60px [a] 60px [b] 60px [a]; }
.e > .one { grid-column: a 2 / a 3; background: #000000; }
.e > .two { grid-column: b -1 / span a 1; grid-row: 2; background: #c8c800; }

/* F: a name no line carries reaches into the implicit grid one track past the explicit one */
.f { display: grid; width: 300px; grid-auto-rows: 20px;
     grid-template-columns: 60px 60px 60px 60px; }
.f > div { grid-column: 1 / span foot; background: #008000; }

/* G: a name no line carries has its first line one past the end of the explicit grid */
.g { display: grid; width: 300px; grid-auto-rows: 20px; grid-auto-columns: 20px;
     grid-template-columns: 60px 60px 60px 60px; }
.g > div { grid-column: nowhere; background: #000080; }
</style></head><body>
<div class="a" id="a"><div></div></div>
<div class="b" id="b"><div></div></div>
<div class="c"><div class="one"></div><div class="two"></div></div>
<div class="d"><div class="head"></div><div class="main"></div><div class="foot"></div></div>
<div class="e"><div class="one" id="e1"></div><div class="two" id="e2"></div></div>
<div class="f"><div></div></div>
<div class="g"><div></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `const css = (s: string): CSSStyleDeclaration => getComputedStyle(document.querySelector(s)!, "");
console.log("areas=" + css(".d").gridTemplateAreas);
console.log("head-start=" + css(".d .head").gridColumnStart);
console.log("head-end=" + css(".d .head").gridColumnEnd);
console.log("two-start=" + css("#e2").gridColumnStart);
console.log("two-end=" + css("#e2").gridColumnEnd);
console.log("middle-end=" + css(".c .one").gridRowEnd);
console.log("nowhere=" + css(".g > div").gridColumnStart);
`;

const dir = mkdtempSync(join(tmpdir(), "native-grid-names-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("named lines and areas compile without a warning",
  !/grid-(template|column|row|area)/.test(`${b.stdout}${b.stderr}`), `${b.stdout}${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const out = `${r.stdout}${r.stderr}`;
const img = decodePng(png);

/** The colour at a CSS position, as "r,g,b". */
const colorAt = (x: number, y: number): string => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};

/** Where the boxes of one row of colours start, in CSS px, left to right; white is a gap. */
function runs(y: number): string {
  const out: string[] = [];
  let prev = "";
  for (let x = 0; x < 320; x += 1) {
    const c = colorAt(x, y);
    if (c !== prev) {
      out.push(`${x}:${c === "255,255,255" ? "-" : c}`);
      prev = c;
    }
  }
  return out.join(" ");
}

// The blocks stack from the top of the page: A and B 20 each, C 40, D 40, E 40, F 20, G 20.
const A = 10, B = 30, C1 = 50, C2 = 70, D1 = 90, D2 = 110, E1 = 130, E2 = 150, F = 170, G = 190;

check("A: a placement naming one line reaches that column", runs(A) ===
  "0:- 50:255,0,0 150:-", `got ${runs(A)}`);
check("B: naming both sides spans the lines between them", runs(B) ===
  "0:0,255,0 150:-", `got ${runs(B)}`);
check("C: a named row places the item on that row", colorAt(10, C2) === "0,0,255" &&
  colorAt(10, C1) === "255,255,255", `got ${colorAt(10, C1)} / ${colorAt(10, C2)}`);
check("C: two named sides span the lines between them", colorAt(40, C1) === "255,0,255" &&
  colorAt(40, C2) === "255,0,255", `got ${runs(C1)} / ${runs(C2)}`);
check("D: grid-area fills the named area across its two columns", runs(D1) ===
  "0:255,0,255 100:-", `got ${runs(D1)}`);
check("D: the area names its own start and end lines", colorAt(60, D2) === "128,128,0" &&
  colorAt(10, D2) === "255,165,0", `got ${runs(D2)}`);
check("D: a one-cell area takes one cell", colorAt(110, D1) === "255,255,255" &&
  colorAt(110, D2) === "255,255,255", `got ${colorAt(110, D1)} / ${colorAt(110, D2)}`);
check("E: a counted name takes the second line of that name", colorAt(130, E1) === "0,0,0" &&
  colorAt(10, E1) === "255,255,255", `got ${runs(E1)}`);
check("E: a negative count reaches back from the last line, and span reaches forward", colorAt(200, E2) === "200,200,0" &&
  colorAt(130, E2) === "255,255,255", `got ${runs(E2)}`);
check("F: a name with no line spans one implicit track past the grid", colorAt(10, F) === "0,128,0" &&
  colorAt(260, F) === "0,128,0" && colorAt(305, F) === "255,255,255", `got ${runs(F)}`);
check("G: a bare name with no line starts on the first implicit line past the grid",
  runs(G) === "0:- 260:0,0,128 280:-", `got ${runs(G)}`);
check("the area list reads back as CSS text",
  out.includes('areas="head head side" "main foot side"'), out.trim());
check("a placement by area name reads back as its name",
  out.includes("head-start=head") && out.includes("head-end=head"), out.trim());
check("a counted placement reads back with its count",
  out.includes("two-start=-1 b") && out.includes("two-end=span a"), out.trim());
check("an omitted end takes the start's name",
  out.includes("middle-end=middle"), out.trim());
check("a placement by a name with no line reads back as its name",
  out.includes("nowhere=nowhere"), out.trim());

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
