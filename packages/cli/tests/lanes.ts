// Grid lanes (masonry): items flow into the least-filled lane, a spanner takes the highest lane
// it covers, the grid axis keeps normal tracks, and row lanes run items along the row tracks.
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
/* A: two 100px columns with a 10px gap; items take the shorter column in order. */
#a { display: grid-lanes; grid-template-columns: 100px 100px; gap: 10px; width: 210px; }
#a > div { font-size: 0; }
#a1 { height: 50px; background: #ff0000; }
#a2 { height: 30px; background: #00ff00; }
#a3 { height: 40px; background: #0000ff; }
#a4 { height: 20px; background: #ffff00; }
/* C: a spanner sits below both lanes it covers, and then both lanes are level again. */
#c { display: grid-lanes; grid-template-columns: 60px 60px; width: 120px; margin-top: 20px; }
#c > div { font-size: 0; }
#c1 { height: 50px; background: #ff00ff; }
#c2 { height: 50px; background: #00ffff; }
#c3 { grid-column: span 2; height: 20px; background: #880000; }
#c4 { height: 10px; background: #008800; }
/* B: row lanes run items along the rows. */
#b { display: grid-lanes; grid-lanes-direction: row; grid-template-rows: 40px 40px; gap: 10px;
     width: 200px; height: 90px; margin-top: 20px; }
#b > div { width: 40px; height: 40px; font-size: 0; }
#b1 { background: #ff0000; }
#b2 { background: #00ff00; }
#b3 { background: #0000ff; }
#b4 { background: #ffff00; }
/* D: fill-reverse stacks each column from the container's bottom edge. The cases sit to the
   right of the in-flow ones so their boxes don't cover it. */
#d { display: grid-lanes; grid-lanes-direction: column fill-reverse; grid-template-columns: 50px 50px;
     gap: 10px; width: 110px; height: 120px; position: absolute; top: 0; left: 400px; }
#d > div { font-size: 0; }
#d1 { height: 30px; background: #ff0000; }
#d2 { height: 50px; background: #00ff00; }
#d3 { height: 20px; background: #0000ff; }
#d4 { height: 60px; background: #ffff00; }
/* E: the same with an automatic height, which ends where the tallest lane does. */
#e { display: grid-lanes; grid-lanes-direction: column fill-reverse; grid-template-columns: 50px 50px;
     gap: 10px; width: 110px; position: absolute; top: 200px; left: 400px; }
#e > div { font-size: 0; }
#e1 { height: 30px; background: #ff0000; }
#e2 { height: 50px; background: #00ff00; }
#e3 { height: 20px; background: #0000ff; }
/* F: track-reverse numbers the lanes from the end, so auto placement fills the last one first. */
#f { display: grid-lanes; grid-lanes-direction: column track-reverse; grid-template-columns: 40px 40px 40px;
     gap: 10px; width: 140px; position: absolute; top: 350px; left: 400px; }
#f > div { font-size: 0; height: 20px; }
#f1 { background: #ff0000; }
#f2 { background: #00ff00; }
#f3 { background: #0000ff; }
#f4 { background: #ffff00; grid-column: span 2; }
/* G: an item with no block size of its own fills the row lane it sits in. */
#g { display: grid-lanes; grid-lanes-direction: row; grid-template-rows: 40px; width: 40px;
     position: absolute; top: 450px; left: 400px; }
#g > div { width: 20px; }
#g1 { background: #ff0000; }
#g2 { background: #0000ff; }
</style></head><body>
<div id="d"><div id="d1"></div><div id="d2"></div><div id="d3"></div><div id="d4"></div></div>
<div id="e"><div id="e1"></div><div id="e2"></div><div id="e3"></div></div>
<div id="f"><div id="f1"></div><div id="f2"></div><div id="f3"></div><div id="f4"></div></div>
<div id="g"><div id="g1"></div><div id="g2"></div></div>
<div id="a"><div id="a1"></div><div id="a2"></div><div id="a3"></div><div id="a4"></div></div>
<div id="c"><div id="c1"></div><div id="c2"></div><div id="c3"></div><div id="c4"></div></div>
<div id="b"><div id="b1"></div><div id="b2"></div><div id="b3"></div><div id="b4"></div></div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-lanes-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("grid-lanes compiles without a warning", !/grid-lanes|fit-tolerance/.test(b.stdout + b.stderr), b.stderr);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

/** The colour at a CSS position, as "r,g,b". */
const colorAt = (x: number, y: number): string => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
const WHITE = "255,255,255";

// A: the first two items fill the two columns, then the next ones take the shorter column.
check("A: items fill the lanes in order", colorAt(50, 25) === "255,0,0" && colorAt(150, 10) === "0,255,0",
  `got ${colorAt(50, 25)} / ${colorAt(150, 10)}`);
check("A: the third item takes the shorter lane", colorAt(150, 50) === "0,0,255", `got ${colorAt(150, 50)}`);
check("A: the fourth returns to the first lane", colorAt(50, 70) === "255,255,0", `got ${colorAt(50, 70)}`);
check("A: the gap stays clear", colorAt(105, 10) === WHITE, `got ${colorAt(105, 10)}`);

// C: the spanner spans both columns below them, and the next item starts level again.
check("C: the lanes fill in order", colorAt(20, 120) === "255,0,255" && colorAt(90, 120) === "0,255,255",
  `got ${colorAt(20, 120)} / ${colorAt(90, 120)}`);
check("C: a spanner spans the lanes below both of them", colorAt(50, 160) === "136,0,0", `got ${colorAt(50, 160)}`);
check("C: the next item goes in the first lane after the spanner",
  colorAt(20, 175) === "0,136,0" && colorAt(90, 175) === WHITE,
  `got ${colorAt(20, 175)} / ${colorAt(90, 175)}`);

// B: row lanes lay items out along the rows, filling each row in turn.
check("B: row lanes fill the first row then the second", colorAt(20, 220) === "255,0,0" && colorAt(20, 270) === "0,255,0",
  `got ${colorAt(20, 220)} / ${colorAt(20, 270)}`);
check("B: the next items carry on along each row", colorAt(70, 220) === "0,0,255" && colorAt(70, 270) === "255,255,0",
  `got ${colorAt(70, 220)} / ${colorAt(70, 270)}`);

// D: a reversed column lane stacks from the bottom, and the lanes' content hangs off that edge.
check("D: the first items sit at the bottom of their lanes", colorAt(425, 100) === "255,0,0" && colorAt(485, 100) === "0,255,0",
  `got ${colorAt(425, 100)} / ${colorAt(485, 100)}`);
check("D: the next item stacks upward above the first", colorAt(425, 70) === "0,0,255", `got ${colorAt(425, 70)}`);
check("D: a lane that outgrows the box starts at its top", colorAt(485, 30) === "255,255,0", `got ${colorAt(485, 30)}`);
check("D: the gap stays clear", colorAt(455, 100) === WHITE, `got ${colorAt(455, 100)}`);

// E: without a height the box ends where its tallest lane does, and both lanes hang off that end.
check("E: the box is as tall as the tallest lane",
  colorAt(425, 210) === "0,0,255" && colorAt(425, 250) === "255,0,0" && colorAt(485, 220) === "0,255,0",
  `got ${colorAt(425, 210)} / ${colorAt(425, 250)} / ${colorAt(485, 220)}`);

// F: track-reverse fills the lanes from the end, and a tie breaks toward it too.
check("F: auto placement starts in the last lane",
  colorAt(520, 360) === "255,0,0" && colorAt(470, 360) === "0,255,0" && colorAt(420, 360) === "0,0,255",
  `got ${colorAt(520, 360)} / ${colorAt(470, 360)} / ${colorAt(420, 360)}`);
check("F: a tie breaks toward the end, so the spanner takes the last two lanes",
  colorAt(520, 390) === "255,255,0" && colorAt(470, 390) === "255,255,0" && colorAt(420, 390) === WHITE,
  `got ${colorAt(520, 390)} / ${colorAt(470, 390)} / ${colorAt(420, 390)}`);

// G: an item with no height of its own stretches over the row lane, as a grid item fills its area.
check("G: an auto block size fills the lane", colorAt(410, 485) === "255,0,0" && colorAt(430, 485) === "0,0,255",
  `got ${colorAt(410, 485)} / ${colorAt(430, 485)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
