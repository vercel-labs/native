// Rects of text in a box that lays its content out down the page: a range over an element's own
// text gives one rect per line, as wide as the characters it holds, and an inline box gives one
// per run of its content, each turned back onto the page the way the line was turned. Every
// expected line was taken from Chrome, to one decimal place.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=300"><style>
html, body { margin: 0; padding: 0; font: 16px/20px system-ui; }
.v { position: absolute; top: 10px; width: 100px; height: 200px; background: #eeeeee; }
#rl { left: 10px; writing-mode: vertical-rl; }
#lr { left: 130px; writing-mode: vertical-lr; }
#s { background: #888888; }
</style></head><body>
<div class="v" id="rl">abcdefghij klmnopqrst uvwxyz</div>
<div class="v" id="lr">abcdefghij klmnopqrst uvwxyz</div>
<div class="v" id="sa" style="top: 220px"><span id="s">abc def</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const one = (v: number): number => Math.round(v * 10) / 10;
const fmt = (r: DOMRect): string => [r.left, r.top, r.width, r.height].map(one).join(",");
function log(id: string, from: number, to: number): void {
  const el = document.getElementById(id) as Element;
  const node = el.firstChild as Node;
  const r = document.createRange();
  r.setStart(node, from);
  r.setEnd(node, to);
  const rects: string[] = [];
  const list = r.getClientRects();
  for (let i = 0; i < list.length; i++) rects.push(fmt(list[i]));
  console.log(id + " " + from + ".." + to + " rects " + rects.join(" | ") + " box " + fmt(r.getBoundingClientRect()));
}
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    for (const id of ["rl", "lr"]) {
      log(id, 2, 7);
      log(id, 0, 28);
      log(id, 15, 20);
    }
    const s = document.getElementById("s") as Element;
    const list = s.getClientRects();
    const parts: string[] = [];
    for (let i = 0; i < list.length; i++) parts.push(fmt(list[i]));
    console.log("span rects " + parts.join(" | "));
  });
});
`;

const EXPECTED_LOG = [
  // The first line's column is the rightmost of the box, its font box inset from the content edge
  // by the upper leading; five characters of it are 41.5 of the line's 162 long (Chrome measures
  // the run a hundredth longer, which the rounding to a tenth would otherwise split on).
  "rl 2..7 rects 91,28,18,41.5 box 91,28,18,41.5",
  // The whole text makes two columns: the first 162 long, the second 54.2, one line height apart.
  "rl 0..28 rects 91,10,18,162 | 71,10,18,54.2 box 71,10,38,162",
  // A run that starts partway down the first column.
  "rl 15..20 rects 91,124.9,18,41.7 box 91,124.9,18,41.7",
  // vertical-lr stacks the other way, from the left edge.
  "lr 2..7 rects 131,28,18,41.5 box 131,28,18,41.5",
  "lr 0..28 rects 131,10,18,162 | 151,10,18,54.2 box 131,10,38,162",
  "lr 15..20 rects 131,124.9,18,41.7 box 131,124.9,18,41.7",
  // An inline box's background is one rect for the run, turned onto the page with the line.
  "span rects 0,221,54.7,18",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-vertical-rects-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").filter((l) => l !== "");
const want = EXPECTED_LOG;
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, want.length); i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

if (failed > 0) {
  console.error(`\n${failed} vertical rect check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall vertical rect checks passed");
