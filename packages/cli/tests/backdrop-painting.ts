// A backdrop filter is part of the element's painting: it shows only where the element paints.
// Two boxes on one page check that.
//
//   - A rounded box: the filtered backdrop is cut by the border radius, so the box's square
//     corners keep the page's own backdrop instead of a hard-edged rectangle of filtered pixels.
//   - A box faded to nothing: it paints nothing, so its backdrop filter must leave the backdrop
//     alone; before, the filter ran and left its whole rectangle on the page.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-backdrop-painting-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=300, height=200">
<style>
html, body { margin: 0; width: 300px; height: 200px; background: #2f6df6; overflow: hidden; }
/* Bright squares the blur pulls towards each box's corner. */
#markA { position: absolute; left: 60px; top: 45px; width: 34px; height: 34px; background: #ffffff; }
#markB { position: absolute; left: 200px; top: 55px; width: 60px; height: 60px; background: #ffffff; }
/* A rounded glass box, barely tinted, so the backdrop shows through it. */
#glassA { position: absolute; left: 50px; top: 35px; width: 130px; height: 95px;
  border-radius: 34px; background: rgba(255, 255, 255, 0.05); backdrop-filter: blur(10px); }
/* A glass box faded to nothing: it paints nothing at all. */
#glassB { position: absolute; left: 180px; top: 40px; width: 100px; height: 90px;
  border-radius: 20px; background: rgba(255, 255, 255, 0.5); backdrop-filter: blur(10px); opacity: 0; }
</style></head><body>
<div id="markA"></div><div id="markB"></div>
<div id="glassA"></div><div id="glassB"></div>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `// A static page: the snapshot is its only frame.
`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

const shot = join(dir, "frame.png");
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 0", NATIVE_SNAPSHOT: shot } });
if (run.status !== 0) {
  console.error(run.stderr);
  process.exit(1);
}
if (!existsSync(shot)) {
  ok("the run wrote its picture", false);
  console.log("\n1 failed");
  process.exit(1);
}
const img = decodePng(shot);
const scale = img.w / 300;
function px(x: number, y: number): number[] {
  const i = (Math.round(y * scale) * img.w + Math.round(x * scale)) * 4;
  return [img.rgba[i], img.rgba[i + 1], img.rgba[i + 2]];
}
function near(a: number[], b: number[], tol: number): boolean {
  return Math.abs(a[0] - b[0]) <= tol && Math.abs(a[1] - b[1]) <= tol && Math.abs(a[2] - b[2]) <= tol;
}
const page = px(20, 180); // the page's own colour, away from both boxes
ok("the page paints its background", near(page, [47, 109, 246], 2), `rgb(${page.join(",")})`);

// The rounded box's square top-left corner: outside the rounded shape, so the element paints
// nothing here and the filter must not either.
const corner = px(54, 39);
ok("the rounded box's square corner keeps the backdrop", near(corner, page, 3), `rgb(${corner.join(",")})`);

// Inside the rounded shape the filter does show, pulling the bright square around.
const inside = px(64, 48);
ok("the filter shows inside the rounded box",
  Math.abs(inside[0] - page[0]) + Math.abs(inside[1] - page[1]) > 40, `rgb(${inside.join(",")})`);

// The faded box paints nothing, so the backdrop it covers is untouched: the bright square behind
// it stays the square's own white instead of the blurred glass.
const behind = px(206, 61);
ok("a box faded to nothing leaves its backdrop alone", near(behind, [255, 255, 255], 2),
  `rgb(${behind.join(",")})`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
