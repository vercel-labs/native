// IntersectionObserver: a target inside a scrolling root, and one in the page, report the ratio
// they are seen at as a wheel scroll moves them, and the root's box comes with the entry.
// A rootMargin widens the root's box, and an observer that unobserves or disconnects stops.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"></head><body>
<div id="box" style="height: 60px; overflow: auto; border: 1px solid #000">
  <div id="pad" style="height: 200px"></div>
  <div id="item" style="height: 40px">item</div>
</div>
<div id="page-pad" style="height: 1200px"></div>
<p id="sentinel">sentinel</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const box = document.getElementById("box") as HTMLElement;
const item = document.getElementById("item") as HTMLElement;
const sentinel = document.getElementById("sentinel") as HTMLElement;

// --- a target in a scrolling root, reported at each threshold it crosses
const inside = new IntersectionObserver((list) => {
  for (const e of list) log("box " + String(e.target.id) + " " + String(e.isIntersecting) + " " + e.intersectionRatio.toFixed(2) + " " + String(e.rootBounds !== null));
}, { root: box, threshold: [0, 0.5, 1] });
inside.observe(item);

// --- a target in the page, whose root box is the viewport
const page = new IntersectionObserver((list) => {
  for (const e of list) {
    const b = e.rootBounds;
    log("page " + String(e.target.id) + " " + String(e.isIntersecting) + " " + e.intersectionRatio.toFixed(2) + " " +
      (b === null ? "no root" : Math.round(b.width) + "x" + Math.round(b.height)));
  }
});
page.observe(sentinel);

// --- rootMargin widens the root's box, so a target just outside it counts as seen
const near = document.getElementById("item") as HTMLElement;
const margin = new IntersectionObserver((list) => {
  for (const e of list) log("margin " + String(e.isIntersecting) + " " + e.intersectionRatio.toFixed(2));
}, { root: box, rootMargin: "0px 0px 200px 0px", threshold: [0, 0.5, 1] });
margin.observe(near);

// --- unobserve() from inside the callback stops the reports after the first
const once = new IntersectionObserver((list) => {
  for (const e of list) {
    log("once " + String(e.target.id) + " " + e.intersectionRatio.toFixed(2));
    once.unobserve(e.target);
  }
});
once.observe(sentinel);

// --- disconnect() drops the targets, so this observer never reports anything
const none = new IntersectionObserver(() => { log("none"); });
none.observe(item);
none.disconnect();
`;

const STEPS = [
  "frame 0",
  "wheel #box 5000",
  "wheel #box -5000",
  "wheel #page-pad 5000",
].join(" | ");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-intersection-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: STEPS } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);

// The item sits below the box's 60px of visible content at first, so it is unseen until the box
// scrolls; rootMargin's 200px of extra bottom makes it seen from the start. The sentinel is below
// the page until the page scrolls, and the once() observer unobserves it after that first report.
const EXPECTED = [
  "box item false 0.00 true",
  "page sentinel false 0.00 400x300",
  "margin true 1.00",
  "once sentinel 0.00",
  "box item true 1.00 true",
  "box item false 0.00 true",
  "page sentinel true 1.00 400x300",
];
for (let i = 0; i < EXPECTED.length; i++) check(`entry ${i}`, got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
check("no extra entries", got.length === EXPECTED.length, `got ${JSON.stringify(got)}`);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
