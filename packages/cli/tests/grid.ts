// Grid layout: explicit and implicit tracks, repeat(), minmax() and fr, auto-placement with
// spans and definite lines, gaps, and the alignment of the items inside their areas.
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

// The page stacks one grid per case. Each grid is 20 CSS px tall unless it names rows of its own,
// and the snapshot is 2 device px per CSS px, so a CSS position x is device column 2x.
const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><style>
body { margin: 0; font: 16px/1 sans-serif; }
.grid { display: grid; height: 20px; }
.cell { height: 20px; }

/* A: 100px + 1fr + 2fr over 300px, with 10px gaps */
.a { grid-template-columns: 100px 1fr 2fr; gap: 10px; width: 300px; }

/* B: three equal fractions of the space left by the gaps */
.b { grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; width: 308px; }

/* C: placement in both axes, and auto-placement filling the free cells */
.c { grid-template-columns: repeat(4, 1fr); grid-auto-rows: 20px; width: 400px; height: auto; }
.c > .wide { grid-column: 1 / span 2; background: #ff0000; }
.c > .last { grid-column: 4; grid-row: 1; background: #00ff00; }
.c > .third { background: #0000ff; }
.c > .fourth { background: #ffff00; }
.c > .fifth { background: #ff00ff; }

/* D: an item centered in the inline axis and sitting at the end of a 40px row */
.d { grid-template-columns: 100px; grid-template-rows: 40px 20px; justify-items: center;
     align-items: end; width: 100px; height: 60px; }
.d > div { width: 20px; height: 10px; background: #008000; }

/* E: the second row takes the rest of a definite height */
.e { grid-template-columns: 20px; grid-template-rows: 30px 1fr; width: 20px; height: 100px; }
.e > div { background: #800000; }
.e > :last-child { background: #000080; }

/* F: a column flow fills each column before moving to the next */
.f { grid-auto-flow: column; grid-auto-columns: 40px; grid-template-rows: 20px; width: 200px; }
.f > div { background: #808000; }
.f > :nth-child(2) { background: #800080; }

/* I: the self-position keywords, which keep the keyword they were written with */
.i { grid-template-columns: 200px; grid-auto-rows: 20px; width: 300px; height: auto; justify-items: right; }
.i > div { width: 20px; height: 20px; background: #123456; }

/* J: a safe packing of two tracks that overflow a narrower container, which packs from the start */
.j { grid-template-columns: 200px 200px; grid-auto-rows: 20px; width: 300px; height: auto;
     justify-content: safe center; }
.j > div { height: 20px; }
.j > :nth-child(1) { background: #112233; }
.j > :nth-child(2) { background: #445566; }

/* K and L: an item wider than its area; unsafe keeps its offset and overflows the start edge,
   while safe clamps it to that edge */
.k { grid-template-columns: 50px; grid-auto-rows: 50px; width: 50px; height: 50px; }
.k > div { width: 100px; height: 50px; background: #cc0000; }
.l { grid-template-columns: 50px; grid-auto-rows: 50px; width: 50px; height: 50px; }
.l > div { width: 100px; height: 50px; background: #00cc00; }

/* H: a percentage track resolves against the grid's content box */
.h { grid-template-columns: 50% 50px; width: 200px; }
.h > div { background: #404040; }

/* M: a fixed maximum caps the automatic minimum size of an item whose size comes from its
   content, while an item that states its own size keeps it */
.m { grid-template-columns: 100px; grid-template-rows: minmax(auto, 0px); width: 100px; height: auto; }
.m > div { height: 50px; background: #123456; }
.p { grid-template-columns: minmax(auto, 0px) 40px; width: 200px; height: 20px; }
.p > div { height: 20px; }
.p > :first-child { width: 50px; background: #ff0000; }
.p > :last-child { background: #00ff00; }
.q { grid-template-columns: minmax(auto, 0px) 40px; width: 200px; height: 20px; }
.q > div { height: 20px; }
.q > :first-child { background: #0000ff; }
.q > :last-child { background: #ffff00; }

/* R and S: an item that scrolls takes no automatic minimum size in the axis it scrolls, so the
   auto track it alone occupies collapses and the next track starts at the container's edge */
.r { grid-template-columns: auto auto; grid-auto-rows: 20px; width: 0; height: 20px; }
.r > div { height: 20px; }
.r > :first-child { overflow-x: hidden; overflow-y: clip; background: #ff00ff; }
.r > :first-child > div { width: 100px; height: 20px; }
.r > :last-child { width: 20px; background: #00ffff; }
.s { grid-template-rows: auto auto; grid-template-columns: 20px; width: 20px; height: 0; }
.s > div { width: 20px; }
.s > :first-child { overflow-x: clip; overflow-y: hidden; background: #ff8800; }
.s > :first-child > div { height: 20px; }
.s > :last-child { height: 10px; background: #0088ff; }

/* T: the two baseline items of a \`minmax(auto, 0)\` row take the shim into their minimum size,
   so the row keeps the room down to the items' baselines but not the room below them */
.t { display: grid; grid-template-columns: 20px 20px; grid-template-rows: minmax(auto, 0px) 20px;
     width: 40px; height: 0; align-items: baseline; font-size: 0; }
.t > .one { padding-top: 10px; }
.t > .two { padding-bottom: 10px; }
.t > div::before { content: ''; display: inline-block; width: 10px; height: 10px; vertical-align: bottom; }
.t > .two::before { vertical-align: top; }
.t > .marker { grid-row: 2; grid-column: 1 / 3; height: 20px; background: #0057ff; padding: 0; }

/* U: an out-of-flow descendant of the grid (not its child) takes the area its placement names
   as its containing block, so its percentages resolve against the area, not the padding box */
.u { position: relative; display: grid; grid-template-columns: 60px; grid-template-rows: 60px;
     width: 60px; height: 60px; padding: 10px; margin-left: 200px; }
.u .abs { position: absolute; grid-column: 1 / 2; grid-row: 1 / 2; width: 50%; height: 50%;
          background: #00b0f0; }
</style></head><body>
<div class="grid a"><div class="cell" style="background: #ff0000"></div><div class="cell" style="background: #00ff00"></div><div class="cell" style="background: #0000ff"></div></div>
<div class="grid b"><div class="cell" style="background: #ff0000"></div><div class="cell" style="background: #00ff00"></div><div class="cell" style="background: #0000ff"></div></div>
<div class="grid c"><div class="wide"></div><div class="last"></div><div class="third"></div><div class="fourth"></div><div class="fifth"></div></div>
<div class="grid d"><div></div><div></div></div>
<div class="grid e"><div></div><div></div></div>
<div class="grid f"><div></div><div></div><div></div></div>
<div class="grid h"><div></div><div></div></div>
<div class="grid i" id="i"><div></div></div>
<div class="grid j" id="j"><div></div><div></div></div>
<div class="grid k"><div style="justify-self: unsafe end"></div></div>
<div class="grid l"><div style="justify-self: safe end"></div></div>
<div class="grid m"><div></div></div>
<div class="grid p"><div></div><div></div></div>
<div class="grid q"><div></div><div></div></div>
<div class="grid r"><div><div></div></div><div></div></div>
<div class="grid s"><div><div></div></div><div></div></div>
<div class="t"><div class="one"></div><div class="two"></div><div class="marker"></div></div>
<div class="u"><div><div class="abs"></div></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `const a = document.getElementById("a")!;
console.log("tracks=" + getComputedStyle(a).gridTemplateColumns);
const i = document.getElementById("i")!;
const j = document.getElementById("j")!;
console.log("align=" + getComputedStyle(i).justifyItems + "|" + getComputedStyle(j).justifyContent);
`;

const dir = mkdtempSync(join(tmpdir(), "native-grid-"));
writeFileSync(join(dir, "index.html"), PAGE.replace('<div class="grid a">', '<div class="grid a" id="a">'));
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("grid properties compile without a warning",
  !/grid-template|grid-auto|grid-column|grid-row|justify-items/.test(`${b.stdout}${b.stderr}`));

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
  for (let x = 0; x < 420; x += 1) {
    const c = colorAt(x, y);
    if (c !== prev) {
      out.push(`${x}:${c === "255,255,255" ? "-" : c}`);
      prev = c;
    }
  }
  return out.join(" ");
}

// Each grid's block takes the height its tracks name: A and B 20, C 40 (two auto rows), D 60,
// E 100, and F and H 20 each. The grids stack from the top of the page.
const A = 10, B = 30, C1 = 50, C2 = 70, D1 = 115, D2 = 135, E1 = 150, E2 = 200, F = 250, H = 270, I = 280, J = 300,
  K = 340, L = 390, M = 460, P = 480, Q = 500, R = 520, S = 530, T = 530, U = 530;

check("A: a fixed track and two fractions share the width left by the gaps", runs(A) ===
  "0:255,0,0 100:- 110:0,255,0 170:- 180:0,0,255 300:-", `got ${runs(A)}`);
check("B: repeat() with minmax(0, 1fr) gives three equal tracks", runs(B) ===
  "0:255,0,0 97:- 105:0,255,0 203:- 211:0,0,255 308:-", `got ${runs(B)}`);
check("C: an item spanning two columns covers both and the gap", colorAt(50, C1) === "255,0,0" &&
  colorAt(199, C1) === "255,0,0", `got ${colorAt(50, C1)} and ${colorAt(199, C1)}`);
check("C: a definite row and column keeps its cell", colorAt(350, C1) === "0,255,0" && colorAt(350, C2) === "255,255,255",
  `got ${colorAt(350, C1)} and ${colorAt(350, C2)}`);
check("C: auto-placement fills the free cell before the next row", colorAt(250, C1) === "0,0,255" && colorAt(50, C2) === "255,255,0",
  `got ${colorAt(250, C1)} and ${colorAt(50, C2)}`);
check("C: the next auto item takes the column after it", colorAt(150, C2) === "255,0,255", `got ${colorAt(150, C2)}`);
check("D: justify-items centers the item in its column", colorAt(45, D1) === "0,128,0" &&
  colorAt(10, D1) === "255,255,255" && colorAt(45, D2) === "0,128,0", `got ${runs(D1)} / ${runs(D2)}`);
check("D: align-items ends the item in its row", colorAt(45, 85) === "255,255,255" &&
  colorAt(45, 115) === "0,128,0" && colorAt(45, 125) === "255,255,255", `got ${runs(85)} / ${runs(125)}`);
check("E: a 1fr row takes the rest of a definite height", colorAt(10, E1) === "128,0,0" &&
  colorAt(10, 165) === "128,0,0" && colorAt(10, E2) === "0,0,128", `got ${colorAt(10, E1)} ${colorAt(10, 165)} ${colorAt(10, E2)}`);
check("F: a column flow gives each item its own column", runs(F) ===
  "0:128,128,0 40:128,0,128 80:128,128,0 120:-", `got ${runs(F)}`);
check("H: a percentage track resolves against the content box", colorAt(50, H) === "64,64,64" &&
  colorAt(120, H) === "64,64,64" && colorAt(180, H) === "255,255,255", `got ${runs(H)}`);
check("I: justify-items right ends the item at the column's end edge", colorAt(190, I) === "18,52,86" &&
  colorAt(170, I) === "255,255,255", `got ${runs(I)}`);
check("J: a safe packing of an overflowing track set starts at the container's start edge",
  colorAt(100, J) === "17,34,51" && colorAt(250, J) === "68,85,102", `got ${runs(J)}`);
check("K: an unsafe end position lets the item overflow past the start edge", colorAt(10, K) === "204,0,0" &&
  colorAt(70, K) === "255,255,255", `got ${runs(K)}`);
check("L: a safe end position clamps the overflowing item to the start edge", colorAt(10, L) === "0,204,0" &&
  colorAt(70, L) === "0,204,0", `got ${runs(L)}`);
check("M: a definite height ignores a fixed maximum's cap on the automatic minimum", colorAt(10, M) === "18,52,86" &&
  colorAt(10, 445) === "18,52,86", `got ${colorAt(10, M)} / ${colorAt(10, 445)}`);
check("P: a definite width keeps its column's base size", colorAt(10, P) === "255,0,0" &&
  colorAt(55, P) === "0,255,0" && colorAt(45, P) === "255,0,0", `got ${runs(P)}`);
check("Q: an automatic width is capped by the column's fixed maximum", colorAt(10, Q) === "255,255,0",
  `got ${runs(Q)}`);
check("R: a scrolling item takes no automatic minimum size, so its column collapses",
  colorAt(10, R) === "0,255,255", `got ${runs(R)}`);
check("S: a scrolling item takes no automatic minimum size in the block axis",
  colorAt(10, S + 5) === "0,136,255", `got ${colorAt(10, S + 5)}`);
check("T: a baseline shim keeps the room down to the shared baseline in a \`minmax(auto, 0)\` row",
  colorAt(10, T + 25) === "255,255,255" && colorAt(10, T + 35) === "0,87,255",
  `got ${colorAt(10, T + 25)} / ${colorAt(10, T + 35)}`);
check("U: an out-of-flow descendant resolves its percentages against the grid area it names",
  colorAt(220, U + 20) === "0,176,240" && colorAt(250, U + 20) === "255,255,255" &&
  colorAt(220, U + 45) === "255,255,255" && colorAt(205, U + 20) === "255,255,255",
  `got ${colorAt(220, U + 20)} / ${colorAt(250, U + 20)} / ${colorAt(220, U + 45)} / ${colorAt(205, U + 20)}`);
check("the track list reads back as CSS text", out.includes("tracks=100px 1fr 2fr"), out.trim());
check("the alignment keywords read back with their overflow position", out.includes("align=right|safe center"), out.trim());

// A subgrid's own line names: each bracket group names the next line, so `subgrid [a] [b]` makes
// line 2 of the subgrid `b` and an item at `grid-row: b` lands in its second row. A subgrid with
// no gap hands the spacing between its rows to its parent's gutters; an explicit `0` is its own.
const SUB_PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=400, height=200"><style>
.p { display: grid; grid-template-rows: 50px 50px; width: 200px; }
.s { display: grid; grid-template-rows: subgrid [a] [b]; grid-row: 1 / span 2; }
#i { grid-row: b; height: 10px; }
.p2 { display: grid; grid-template-rows: 100px 100px; row-gap: 20px; width: 200px; }
.s2 { display: grid; grid-template-rows: subgrid; grid-row: 1 / span 2; align-content: start; }
.z2 { gap: 0; }
.n2 { height: 10px; }
.p3 { display: grid; grid-template-rows: auto auto; width: 200px; }
.s3 { display: grid; grid-template-rows: subgrid; grid-row: 1 / span 2; }
.n3 { height: 30px; }
.h3 { height: 50px; }
.p4 { display: grid; grid-template-rows: auto auto; row-gap: 20px; width: 200px; }
.s4 { display: grid; grid-template-rows: subgrid; grid-row: 1 / span 2; gap: 0; }
.m4 { height: 40px; }
.p5 { display: grid; grid-template-rows: auto auto; width: 200px; }
.s5 { display: grid; grid-template-rows: subgrid; grid-row: 1 / span 2; padding-bottom: 10px; }
.c6 { display: inline-grid; grid-template-columns: repeat(3, auto); column-gap: 20px; }
.c7 { display: inline-grid; grid-template-columns: repeat(3, auto); column-gap: 20px; }
.c8 { display: inline-grid; grid-template-columns: repeat(3, auto); column-gap: 10px; }
.s6 { display: grid; grid-template-columns: subgrid; grid-column: 1 / span 3; column-gap: 0; }
.s7 { display: grid; grid-template-columns: subgrid; grid-column: 1 / span 3; column-gap: 0; padding: 0 7px 0 13px; }
.s8 { display: grid; grid-template-columns: subgrid; grid-column: 1 / span 3; column-gap: 20px; }
.a6 { width: 50px; } .b6 { width: 60px; } .c66 { width: 70px; }
</style><script src="app.ts"></script></head>
<body><div class="p"><div class="s" id="s"><div id="i"></div></div></div>
<div class="p2"><div class="s2" id="g1"><div class="n2" style="grid-row: 1"></div><div class="n2" id="i1" style="grid-row: 2"></div></div></div>
<div class="p2"><div class="s2 z2" id="g2"><div class="n2" style="grid-row: 1"></div><div class="n2" id="i2" style="grid-row: 2"></div></div></div>
<div class="p3"><div class="s3" id="g3"><div class="n3" style="grid-row: 1"></div><div class="h3" id="i3" style="grid-row: 2"></div></div></div>
<div class="p4"><div class="s4" id="g4"><div class="m4" style="grid-row: 1"></div><div class="m4" id="i4" style="grid-row: 2"></div></div></div>
<div class="p5"><div class="s5" id="g5"><div class="n3" style="grid-row: 1"></div><div class="h3" id="i5" style="grid-row: 2"></div></div></div>
<div class="c6" id="c6"><div class="s6" id="d6"><div class="a6" id="e6" style="grid-column: 1"></div><div class="b6" id="f6" style="grid-column: 2"></div><div class="c66" id="g6" style="grid-column: 3"></div></div></div>
<div class="c7" id="c7"><div class="s7" id="d7"><div class="a6" id="e7" style="grid-column: 1"></div><div class="b6" id="f7" style="grid-column: 2"></div><div class="c66" id="g7" style="grid-column: 3"></div></div></div>
<div class="c8" id="c8"><div class="s8" id="d8"><div class="a6" id="e8" style="grid-column: 1"></div><div class="b6" id="f8" style="grid-column: 2"></div><div class="c66" id="g8" style="grid-column: 3"></div></div></div>
</body></html>`;

const SUB_SCRIPT = `
window.addEventListener("load", () => {
  const s = document.getElementById("s")!.getBoundingClientRect();
  const i = document.getElementById("i")!.getBoundingClientRect();
  console.log("sub '" + getComputedStyle(document.getElementById("s")!).gridTemplateRows +
    "' top " + Math.round(i.top - s.top));
  const r = (id: string): number => document.getElementById(id)!.getBoundingClientRect().top;
  console.log("gutter inherit " + Math.round(r("i1") - r("g1")) +
    " own " + Math.round(r("i2") - r("g2")));
  // A row-subgrid contributes its own rows to the rows it spans, so the second row's item sits
  // below the first row's size, not midway down the subgrid's box.
  const box = (id: string) => document.getElementById(id)!.getBoundingClientRect();
  const span = (g: string, i: string): string => Math.round(box(g).height) + "/" +
    Math.round(box(i).top - box(g).top) + "/" + Math.round(box(i).height);
  console.log("rows map " + span("g3", "i3") + " spread " + span("g4", "i4") +
    " inset " + span("g5", "i5"));
  // A column-subgrid asks each of the columns it spans for its own column's room, so the parent
  // is as wide as its contents need and the items sit at the offsets those columns make.
  const width = (id: string): number => Math.round(box(id).width);
  const at = (p: string, i: string): number => Math.round(box(i).left - box(p).left);
  console.log("cols base " + width("c6") + ":" + at("c6", "e6") + "," + at("c6", "f6") + "," +
    at("c6", "g6") + " pad " + width("c7") + ":" + at("c7", "e7") + "," + at("c7", "f7") + "," +
    at("c7", "g7") + " wide " + width("c8") + ":" + at("c8", "e8") + "," + at("c8", "f8") + "," +
    at("c8", "g8"));
});
`;
const subDir = mkdtempSync(join(tmpdir(), "native-grid-sub-"));
writeFileSync(join(subDir, "index.html"), SUB_PAGE);
writeFileSync(join(subDir, "app.ts"), SUB_SCRIPT);
const subExe = join(subDir, "app");
const sb = spawnSync("node", ["compiler/cli.ts", "build", subDir, "-o", subExe], { encoding: "utf8" });
if (sb.status !== 0) throw new Error(`subgrid build failed\n${sb.stderr}`);
const sr = spawnSync(subExe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(subDir, "out.png") } });
const subOut = `${sr.stdout}${sr.stderr}`;
check("a subgrid keeps its line names, one bracket per line",
  subOut.includes("sub 'subgrid [a] [b]'"), subOut.trim());
check("and grid-row: b inside it lands on the second line", subOut.includes("top 50"), subOut.trim());
check("a subgrid with no gap keeps its parent's gutter between rows",
  subOut.includes("gutter inherit 120"), subOut.trim());
check("and a subgrid's explicit gap: 0 is a gutter of its own",
  subOut.includes("own 110"), subOut.trim());
check("a row-subgrid asks its parent's rows for its own rows, not its box's height",
  subOut.includes("rows map 80/30/50"), subOut.trim());
check("and the gutter difference between it and its parent is shared out over the rows it spans",
  subOut.includes("spread 80/40/40"), subOut.trim());
check("while its padding lands on the last row it spans",
  subOut.includes("inset 90/30/50"), subOut.trim());
check("a column-subgrid asks its parent's columns for its own columns' room",
  subOut.includes("cols base 180:0,50,110"), subOut.trim());
check("with its padding on the outer columns it spans",
  subOut.includes("pad 200:13,63,123"), subOut.trim());
check("and the gutter difference shared out over them",
  subOut.includes("wide 220:0,70,150"), subOut.trim());

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
