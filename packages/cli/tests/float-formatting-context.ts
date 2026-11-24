// A block formatting context that its own margins keep from fitting beside a float goes below it,
// rather than staying beside it at zero width: a flow-root with margin-left 51 in a 100px box,
// next to a 50px right float, starts under the float and is 49px wide there (CSS 2.1 9.5, 10.3.3).
// css/CSS2/floats/floats-wrap-bfc-with-margin-004 is the same shape as a reftest.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=300"><style>
body { margin: 0; }
</style></head><body>
<div id="outer" style="width: 100px; height: 100px; background: red">
  <div id="a" style="display: flow-root; background: green">
    <div id="f" style="float: right; width: 50px; height: 40px"></div>
    <div id="b" style="display: flow-root; height: 60px; margin-left: 51px"></div>
  </div>
</div>
<div id="outer2" style="width: 100px; height: 100px; background: red">
  <div id="a2" style="display: flow-root; background: green">
    <div id="f2" style="float: right; width: 50px; height: 40px"></div>
    <div id="b2" style="display: flow-root; height: 60px; margin-left: 20px"></div>
  </div>
</div>
<div id="mc1" style="width: max-content">
  <div style="float: left; width: 50px; height: 20px"></div>
  <div style="float: left; width: 30px; height: 20px"></div>
</div>
<div id="mc2" style="width: max-content">
  <div style="float: left; width: 50px; height: 20px"></div>
  <div style="float: left; clear: left; width: 30px; height: 20px"></div>
</div>
<div id="mc3" style="width: max-content">
  <div style="float: left; width: 50px; height: 20px"></div>
  <div style="float: left; clear: left; width: 30px; height: 20px"></div><span
  style="display: inline-block; width: 40px; height: 20px"></span>
</div>
<div id="mc4" style="width: max-content">
  <div style="float: left; width: 50px; height: 20px"></div>
  <div style="float: left; width: 30px; height: 20px"></div><span
  style="display: inline-block; width: 40px; height: 20px"></span>
</div>
<div id="outer3" style="width: 100px; height: 40px">
  <div id="f3" style="float: left; width: 20px; height: 20px"></div>
  <div id="f4" style="float: right; width: 20px; height: 20px"></div>
  <div id="c3" style="display: flow-root; width: 30px; height: 20px; margin-left: 40px"></div>
</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function at(id: string): string {
  const el = document.getElementById(id) as HTMLElement;
  const r = el.getBoundingClientRect();
  return r.left + "," + r.top + " " + r.width + "x" + r.height;
}
// Its margin does not leave room beside the float, so it goes below it and spans 49px there.
log("below " + at("b"));
// The flow-root that holds both grows to hold the float and the box under it.
log("a " + at("a"));
log("outer " + at("outer"));
// A margin that leaves room keeps the box beside the float, narrowed to that room.
log("beside " + at("b2"));
log("a2 " + at("a2"));
// Floats side by side make a max-content width of both; one that clears starts a new row, so the
// width is the wider row.
function wide(id: string): string {
  return String((document.getElementById(id) as HTMLElement).getBoundingClientRect().width);
}
log("side by side " + wide("mc1"));
log("cleared " + wide("mc2"));
// Inline content sits on the row of the floats before it, so a cleared float starts a row the
// content does not join.
log("content beside " + wide("mc3"));
log("content after both " + wide("mc4"));
// A float absorbs as much of the start margin as it covers, so the box keeps the rest of it
// between the floats rather than being pushed below them.
function leftWidth(id: string): string {
  const r = (document.getElementById(id) as HTMLElement).getBoundingClientRect();
  return r.left + " " + r.width;
}
log("margins " + leftWidth("c3"));
log("done");
`;

const EXPECTED = [
  "below 51,40 49x60",
  "a 0,0 100x100",
  "outer 0,0 100x100",
  "beside 20,100 30x60",
  "a2 0,100 100x60",
  "side by side 80",
  "cleared 50",
  "content beside 90",
  "content after both 120",
  "margins 40 30",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-float-formatting-context-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
