// CSS transforms: rotation, translation, scaling, transform-origin, the individual
// translate/rotate/scale properties, matrix(), inline style changes, `will-change`, and hit
// testing through a transform.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=420, height=620"><style>
body { margin: 0; overflow: hidden; }
.box { position: absolute; background: #ff0000; }
#rot { left: 40px; top: 20px; width: 60px; height: 60px; transform: rotate(45deg); }
#tr { left: 160px; top: 20px; width: 40px; height: 40px; transform: translate(30px, 10px); }
#sc { left: 40px; top: 140px; width: 40px; height: 40px; transform: scale(2); }
#orig { left: 160px; top: 140px; width: 40px; height: 40px; transform: rotate(90deg); transform-origin: 0 0; }
#indiv { left: 40px; top: 260px; width: 30px; height: 30px; translate: 60px; }
#indiv2 { left: 160px; top: 260px; width: 30px; height: 30px; scale: 2; }
#ord { left: 40px; top: 320px; width: 20px; height: 20px; transform: translate(20px, 0); scale: 2; translate: 10px; }
#mat { left: 160px; top: 360px; width: 40px; height: 40px; transform: matrix(1, 0, 0, 1, 10, 20); will-change: transform, opacity; }
#hitB { left: 100px; top: 460px; width: 40px; height: 40px; background: #0000ff; }
#hitA { left: 40px; top: 460px; width: 40px; height: 40px; transform: translate(50px, 0); }
#ibwrap { position: absolute; left: 0; top: 560px; width: 200px; }
#ib { display: inline-block; transform: translate(20px, 0); color: #000; }
#tb { left: 200px; top: 420px; width: 60px; height: 20px; background: #0000ff;
  padding-left: 20px; border-left: 5px solid #ff0000; transform-box: content-box;
  transform: translate(50%, 0); }
#bfh, #bfv, #bf3, #bf4 { position: absolute; width: 40px; height: 40px; }
#bfh { left: 300px; top: 20px; background: #ff0000; transform: rotateY(180deg); backface-visibility: hidden; }
#bfv { left: 300px; top: 100px; background: #0000ff; transform: rotateY(180deg); }
#bf3 { left: 300px; top: 180px; transform-style: preserve-3d; transform: rotateY(180deg); }
#bf3c { width: 40px; height: 40px; background: #00ff00; transform: rotateY(180deg); backface-visibility: hidden; }
#bf4 { left: 300px; top: 260px; transform-style: preserve-3d; transform: rotateY(180deg); }
#bf4c { width: 40px; height: 40px; background: #ff00ff; backface-visibility: hidden; }
#wc { position: absolute; left: 240px; top: 440px; width: 80px; height: 80px; background: #eeeeee; will-change: transform; }
#wckid { position: absolute; left: 0; top: 0; width: 60px; height: 60px; background: #0000ff; z-index: 2; }
#wcsib { position: absolute; left: 260px; top: 460px; width: 80px; height: 80px; background: #ff0000; z-index: 1; }
</style></head><body>
<div class="box" id="rot"></div>
<div class="box" id="tr"></div>
<div class="box" id="sc"></div>
<div class="box" id="orig"></div>
<div class="box" id="indiv"></div>
<div class="box" id="indiv2"></div>
<div class="box" id="ord"></div>
<div class="box" id="mat"></div>
<div class="box" id="hitB"></div>
<div class="box" id="hitA"></div>
<div class="box" id="tb"></div>
<div id="bfh"></div><div id="bfv"></div>
<div id="bf3"><div id="bf3c"></div></div>
<div id="bf4"><div id="bf4c"></div></div>
<div id="ibwrap"><span id="ib">shifted</span></div>
<div id="wc"><span id="wckid"></span></div>
<div id="wcsib"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
for (const id of ["rot", "tr", "sc", "orig", "indiv", "indiv2", "ord", "mat"]) {
  const el = document.getElementById(id)!;
  console.log(id + "=" + getComputedStyle(el).transform);
}
const mat = document.getElementById("mat")!;
mat.style.transform = "translateX(10px)";
console.log("inline=" + getComputedStyle(mat).transform);
mat.style.transform = "translateX(10px";
console.log("invalid=" + getComputedStyle(mat).transform);
// The specified value is the function list as written; the computed one is its matrix.
mat.style.transform = "rotate(30deg)";
console.log("specified=" + mat.style.transform);
console.log("computed=" + getComputedStyle(mat).transform);
mat.style.transform = "matrix(1, 0, 0, 1, 2, 3)";
console.log("specified-matrix=" + mat.style.transform);
mat.style.transform = "perspective(200px)";
console.log("perspective=" + mat.style.transform);
mat.style.transform = "perspective(0)";
console.log("perspective-invalid=" + mat.style.transform);
mat.style.removeProperty("transform");
console.log("removed=" + getComputedStyle(mat).transform);

document.addEventListener("click", (e) => {
  const t = e.target as HTMLElement;
  console.log("click=" + (t.id !== "" ? t.id : t.tagName.toLowerCase()));
  // A percentage origin resolves against the border box, which needs a laid out box: read it
  // once the first step has run a frame.
  if (e.target === document.getElementById("hitA")) {
    console.log("rot-origin=" + getComputedStyle(document.getElementById("rot")!).transformOrigin);
    console.log("orig-origin=" + getComputedStyle(document.getElementById("orig")!).transformOrigin);
    console.log("tb-origin=" + getComputedStyle(document.getElementById("tb")!).transformOrigin);
  }
});
`;

const EXPECTED_LOG: [string, string][] = [
  ["a rotation computes as its matrix", "rot=matrix(0.707107, 0.707107, -0.707107, 0.707107, 0, 0)"],
  ["a translation computes as its matrix", "tr=matrix(1, 0, 0, 1, 30, 10)"],
  ["a scale computes as its matrix", "sc=matrix(2, 0, 0, 2, 0, 0)"],
  ["a quarter turn computes as its matrix", "orig=matrix(0, 1, -1, 0, 0, 0)"],
  ["the individual translate computes as a matrix", "indiv=matrix(1, 0, 0, 1, 60, 0)"],
  ["the individual scale computes as a matrix", "indiv2=matrix(2, 0, 0, 2, 0, 0)"],
  ["individual properties compose outside transform as scale, rotate, translate",
    "ord=matrix(2, 0, 0, 2, 50, 0)"],
  ["matrix() computes unchanged", "mat=matrix(1, 0, 0, 1, 10, 20)"],
  ["an inline transform computes", "inline=matrix(1, 0, 0, 1, 10, 0)"],
  ["an invalid inline transform leaves the old one", "invalid=matrix(1, 0, 0, 1, 10, 0)"],
  ["the specified inline transform keeps its function list", "specified=rotate(30deg)"],
  ["and still computes as its matrix", "computed=matrix(0.866025, 0.5, -0.5, 0.866025, 0, 0)"],
  ["a specified matrix serializes as matrix()", "specified-matrix=matrix(1, 0, 0, 1, 2, 3)"],
  ["the perspective() function is a transform", "perspective=perspective(200px)"],
  ["a zero perspective() is invalid and leaves the old value", "perspective-invalid=perspective(200px)"],
  ["removing the inline transform restores the rule", "removed=matrix(1, 0, 0, 1, 10, 20)"],
  ["a click where a moved box used to be misses it", "click=html"],
  ["a click where it moved to hits it", "click=hitA"],
  ["transform-origin defaults to the border box centre", "rot-origin=30px 30px"],
  ["transform-origin keeps what it was given", "orig-origin=0px 0px"],
  ["transform-box moves the default origin to the content box", "tb-origin=55px 10px"],
];

function buildAndRun(): { png: string; out: string; err: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-transforms-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const steps = "click #hitA | click #hitB";
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: steps } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { png, out: `${r.stdout}${r.stderr}`, err: b.stderr };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { png, out, err } = buildAndRun();
const img = decodePng(png);
const rgb = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (x: number, y: number, c: number[], tol = 24): boolean => {
  const p = rgb(x, y);
  return Math.abs(p[0] - c[0]) <= tol && Math.abs(p[1] - c[1]) <= tol && Math.abs(p[2] - c[2]) <= tol;
};
const white = (x: number, y: number): boolean => near(x, y, [255, 255, 255]);
/** How many pixels of the CSS rect (x0, y0)-(x1, y1) are darker than near-white. */
const ink = (x0: number, y0: number, x1: number, y1: number): number => {
  let n = 0;
  for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
    for (let x = Math.round(x0 * 2); x < Math.round(x1 * 2); x++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 200 && img.rgba[o + 1] < 200 && img.rgba[o + 2] < 200) n++;
    }
  }
  return n;
};
const RED = [255, 0, 0];
const BLUE = [0, 0, 255];

// Logged values first: one line per assertion, in the order the page prints them.
const lines = out.split("\n");
for (const [name, want] of EXPECTED_LOG) {
  if (!want.startsWith("click=")) check(name, lines.includes(want), `wanted '${want}', got ${JSON.stringify(lines.filter((l) => l.startsWith(want.split("=")[0] + "=")))}`);
}
check("will-change doesn't warn", !/will-change/.test(err), err.trim());

// will-change: transform makes #wc a stacking context, so its z-index: 2 child paints inside it
// and #wcsib's z-index: 1, later in tree order, covers it: the overlap is red. Without the
// context the child would sit in the root's stack above the sibling and paint blue.
check("will-change: transform makes a stacking context", near(270, 470, RED), `got ${rgb(270, 470)}`);

// #rot at (40, 20), 60x60, turned 45 degrees: a diamond centred on (70, 50) whose points reach
// 42.4px along each axis.
check("a rotated box keeps its centre", near(70, 50, RED), `got ${rgb(70, 50)}`);
check("a rotated box reaches its top point", near(70, 15, RED), `got ${rgb(70, 15)}`);
check("a rotated box leaves the corner of its box clear", white(45, 25), `got ${rgb(45, 25)}`);
check("a rotated box doesn't spill past its points", white(100, 20), `got ${rgb(100, 20)}`);

// #tr at (160, 20), 40x40, moved 30 right and 10 down.
check("a translation moves the box", near(200, 40, RED), `got ${rgb(200, 40)}`);
check("a translation leaves the old place clear", white(170, 40), `got ${rgb(170, 40)}`);
check("a translation doesn't stretch the box", white(240, 40), `got ${rgb(240, 40)}`);

// #sc at (40, 140), 40x40, doubled about its centre (60, 160): 80x80 from (20, 120).
check("a scale grows the box about its centre", near(30, 130, RED), `got ${rgb(30, 130)}`);
check("a scale stops where the doubled box ends", white(110, 160), `got ${rgb(110, 160)}`);
check("a scale keeps the box's middle", near(60, 160, RED), `got ${rgb(60, 160)}`);

// #orig at (160, 140), 40x40, a quarter turn about its top-left corner: it swings left of the
// corner, into (120, 140)-(160, 180).
check("a rotation about the corner swings the box left", near(130, 150, RED), `got ${rgb(130, 150)}`);
check("a rotation about the corner keeps its far edge", near(150, 175, RED), `got ${rgb(150, 175)}`);
check("a rotation about the corner leaves its old box clear", white(170, 150), `got ${rgb(170, 150)}`);

// #indiv at (40, 260), 30x30, moved 60 right by the individual property.
check("the individual translate moves the box", near(110, 270, RED), `got ${rgb(110, 270)}`);
check("the individual translate leaves the old place clear", white(50, 270), `got ${rgb(50, 270)}`);

// #indiv2 at (160, 260), 30x30, doubled about its centre (175, 275): 60x60 from (145, 245).
check("the individual scale grows the box", near(195, 295, RED), `got ${rgb(195, 295)}`);
check("the individual scale stops at its edge", white(140, 250), `got ${rgb(140, 250)}`);

// #mat at (160, 360), 40x40, matrix(1, 0, 0, 1, 10, 20) is a translation of (10, 20).
check("matrix() moves the box", near(180, 390, RED), `got ${rgb(180, 390)}`);
check("matrix() leaves the old place clear", white(165, 390), `got ${rgb(165, 390)}`);

// #hitA at (40, 460) moved 50 right partly covers #hitB at (100, 460): it paints over it, and a
// click on the covered part belongs to #hitA. The clicks themselves are asserted through the log.
check("the moved box paints over its neighbour", near(110, 480, RED), `got ${rgb(110, 480)}`);
check("the moved box leaves its old place clear", white(60, 480), `got ${rgb(60, 480)}`);
check("the neighbour shows where it isn't covered", near(135, 480, BLUE), `got ${rgb(135, 480)}`);

// #tb: transform-box: content-box, with a 60px content box beside a 5px border and 20px padding.
// `translate(50%)` is half the content width, 30px, so the box moves to 230 and its content
// starts at 255.
check("transform-box sizes a percentage by the content box", near(260, 430, BLUE), `got ${rgb(260, 430)}`);
check("transform-box moves the box off its old place", white(225, 430), `got ${rgb(225, 430)}`);

// Backface culling: a half turn hides a box whose back faces the viewer, a box with the default
// visible backface still paints, and inside a preserve-3d context the ancestor's turn composes
// with the element's.
check("a back-facing box with backface-visibility: hidden is not painted", white(320, 40), `got ${rgb(320, 40)}`);
check("a back-facing box with a visible backface still paints", near(320, 120, BLUE), `got ${rgb(320, 120)}`);
check("two half turns inside preserve-3d face the viewer again", near(320, 200, [0, 255, 0]), `got ${rgb(320, 200)}`);
check("an ancestor's turn hides a back-facing child", white(320, 280), `got ${rgb(320, 280)}`);

// #ib is a transformed inline-block in a body whose overflow: hidden belongs to the viewport: the
// shift has to move its text out of the box the body's own height would have clipped to nothing.
const shifted = ink(20, 560, 80, 578);
check("a transformed inline-block paints its text", shifted > 40, `${shifted} ink pixels`);
check("the inline-block's text moves with it", ink(0, 560, 18, 578) === 0, `${ink(0, 560, 18, 578)} ink pixels left behind`);

if (failed > 0) {
  console.log(`${failed} failed`);
  process.exit(1);
}
console.log("all passed");
