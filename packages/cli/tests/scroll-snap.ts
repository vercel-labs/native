// scroll-snap: a scroll container with a scroll-snap-type lands on a snap position. A script
// scroll snaps on the axes it sets, a proximity container only reaches a third of its snapport,
// scroll-padding shrinks the snapport, scroll-margin grows the area, and a container snapping
// both axes keeps the two chosen areas visible together. A layout moves the scroll along with the
// areas it is snapped to, and the first layout snaps a container that has never scrolled.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=600"><style>
html, body { margin: 0; }
body { font: 16px/1 monospace; }
/* The scroller and the boxes that make its content taller and wider than it. */
.scroller { width: 200px; height: 200px; overflow: auto; position: relative; }
.wide { width: 600px; height: 600px; overflow: scroll; position: relative; }
.space { position: absolute; left: 0; top: 0; width: 1000px; height: 1000px; }
.big { position: absolute; left: 0; top: 0; width: 2000px; height: 2000px; }
.area { position: absolute; width: 100px; height: 100px; }
.snap { scroll-snap-align: start; }
</style></head>
<body>
<div id="snap" class="scroller" style="scroll-snap-type: y mandatory">
  <div class="space"></div>
  <div class="area snap" style="left: 0; top: 0"></div>
  <div class="area snap" style="left: 0; top: 200px"></div>
  <div class="area snap" style="left: 0; top: 400px"></div>
  <div class="area snap" style="left: 0; top: 600px"></div>
</div>
<div id="prox" class="scroller" style="scroll-snap-type: y proximity">
  <div class="space"></div>
  <div class="area snap" style="left: 0; top: 0"></div>
  <div class="area snap" style="left: 0; top: 200px"></div>
  <div class="area snap" style="left: 0; top: 400px"></div>
  <div class="area snap" style="left: 0; top: 600px"></div>
</div>
<div id="pad" class="scroller" style="scroll-snap-type: y mandatory; scroll-padding-top: 20px">
  <div class="space"></div>
  <div class="area snap" style="left: 0; top: 0"></div>
  <div class="area snap" style="left: 0; top: 200px"></div>
  <div class="area snap" style="left: 0; top: 400px"></div>
  <div class="area snap" style="left: 0; top: 600px"></div>
</div>
<div id="margin" class="scroller" style="scroll-snap-type: y mandatory">
  <div class="space"></div>
  <div class="area snap" style="left: 0; top: 0"></div>
  <div class="area snap" style="left: 0; top: 200px; scroll-margin-top: 50px"></div>
</div>
<div id="align" class="scroller" style="scroll-snap-type: y mandatory">
  <div class="space"></div>
  <div class="area" style="left: 0; top: 300px; scroll-snap-align: center"></div>
  <div class="area" style="left: 0; top: 700px; scroll-snap-align: end"></div>
</div>
<div id="both" class="wide" style="scroll-snap-type: both mandatory">
  <div class="big"></div>
  <div class="area snap" style="left: 0; top: 0; width: 200px; height: 200px"></div>
  <div class="area snap" style="left: 0; top: 800px; width: 200px; height: 200px"></div>
  <div class="area snap" style="left: 800px; top: 0; width: 200px; height: 200px"></div>
</div>
<div id="diag" class="scroller" style="scroll-snap-type: both mandatory">
  <div class="space"></div>
  <div class="area" style="left: 0; top: 0; scroll-snap-align: start start"></div>
  <div class="area" style="left: 200px; top: 200px; scroll-snap-align: start start"></div>
  <div class="area" style="left: 400px; top: 400px; scroll-snap-align: start start"></div>
  <div class="area" style="left: 600px; top: 600px; scroll-snap-align: start start"></div>
</div>
<div id="pair" class="scroller" style="scroll-snap-type: pair mandatory">
  <div class="space"></div>
  <div class="area" style="left: 200px; top: 200px; scroll-snap-align: start none"></div>
  <div class="area" style="left: 300px; top: 300px; scroll-snap-align: none start"></div>
  <div class="area" style="left: 400px; top: 400px; scroll-snap-align: start start"></div>
</div>
<div id="movable" class="scroller" style="scroll-snap-type: y mandatory">
  <div class="space"></div>
  <div id="wander" class="area snap" style="left: 0; top: 200px"></div>
</div>
<div id="unsnap" class="scroller" style="scroll-snap-type: y proximity">
  <div class="space"></div>
  <div id="leaving" class="area snap" style="left: 0; top: 0"></div>
  <div class="area snap" style="left: 0; top: 500px"></div>
</div>
<button id="move" style="position: fixed; left: 600px; top: 0">move</button>
<script>
const byId = (id) => document.getElementById(id);
const read = (el) => [el.scrollLeft, el.scrollTop];
const log = [];
const snap = byId("snap");
snap.scrollTop = 250; log.push(read(snap));
snap.scrollTop = 610; log.push(read(snap));
const prox = byId("prox");
prox.scrollTop = 250; log.push(read(prox));
prox.scrollTop = 310; log.push(read(prox));
const pad = byId("pad");
pad.scrollTop = 190; log.push(read(pad));
const margin = byId("margin");
margin.scrollTop = 140; log.push(read(margin));
const align = byId("align");
align.scrollTop = 240; log.push(read(align));
align.scrollTop = 560; log.push(read(align));
const both = byId("both");
both.scrollTo(0, 0);
both.scrollTo(500, 600); log.push(read(both));
both.scrollTo(600, 500); log.push(read(both));
const diag = byId("diag");
diag.scrollTo(200, 200);
diag.scrollLeft = 450; log.push(read(diag));
const movable = byId("movable");
movable.scrollTop = 250; log.push(read(movable));
const unsnap = byId("unsnap");
unsnap.scrollTop = 200; log.push(read(unsnap));
byId("move").addEventListener("click", () => {
  const wander = byId("wander");
  wander.setAttribute("style", "left: 0; top: 350px; scroll-snap-align: start");
  // An area that moves after a scroll ended without snapping leaves the scroll where it is.
  const leaving = byId("leaving");
  leaving.setAttribute("style", "left: 0; top: 10px; scroll-snap-align: start");
});
console.log("script=" + JSON.stringify(log));
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-scroll-snap-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

function run(steps: string[]): string[] {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps.join(" | ") };
  delete env.NATIVE_SNAPSHOT;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

const steps: string[] = [];
const want: string[] = [];
const labels: string[] = [];
function step(name: string, ...prints: string[]): void {
  steps.push(name);
  for (const p of prints) {
    want.push(p);
    labels.push(name);
  }
}

// A layout leaves a container on the area it is snapped to: the pair type finds its area in the
// first layout, and the others keep the positions the script left them on.
step("frame 0");
step("scrollleft #pair", "400");
step("scrolltop #pair", "400");
step("scrolltop #snap", "600");
step("scrolltop #diag", "200");
// An area that moves takes the scroll with it, to the position its new place gives.
step("click #move");
step("frame 100");
step("scrolltop #movable", "350");
// The scroll ended outside the proximity threshold, so the area that moved does not drag it.
step("scrolltop #unsnap", "200");

const lines = run(steps);
const script = lines[0].startsWith("script=") ? (JSON.parse(lines[0].slice(7)) as number[][]) : null;
const got = lines.slice(1);
check(`print lines`, got.length === want.length, `got ${got.length}, want ${want.length}: ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, want.length); i++) {
  check(labels[i], got[i] === want[i], `got ${JSON.stringify(got[i])}, want ${JSON.stringify(want[i])}`);
}

// The page script scrolled each box and read the position back.
const rows = [
  ["mandatory x", "250 lands on 200", [0, 200]],
  ["mandatory past the last area", "610 lands on 600", [0, 600]],
  ["proximity within a third", "250 lands on 200", [0, 200]],
  ["proximity beyond a third", "310 stays", [0, 310]],
  ["scroll-padding", "190 lands on 180", [0, 180]],
  ["scroll-margin", "140 lands on 150", [0, 150]],
  ["center alignment", "240 lands on 250", [0, 250]],
  ["end alignment", "560 lands on 600", [0, 600]],
  ["both axes", "(500, 600) lands on (0, 800)", [0, 800]],
  ["both axes, other way", "(600, 500) lands on (800, 0)", [800, 0]],
  ["scrollLeft alone", "450 lands on 400, top stays", [400, 200]],
  ["stored target", "250 lands on 200", [0, 200]],
  ["outside the proximity threshold", "200 stays", [0, 200]],
] as [string, string, number[]][];
check(`script line`, script !== null, script === null ? JSON.stringify(lines[0]) : "");
for (let i = 0; i < rows.length; i++) {
  const gotRow = script === null ? null : script[i];
  check(`${rows[i][0]}: ${rows[i][1]}`,
    gotRow !== null && gotRow !== undefined && gotRow[0] === rows[i][2][0] && gotRow[1] === rows[i][2][1],
    `got ${JSON.stringify(gotRow)}, want ${JSON.stringify(rows[i][2])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
