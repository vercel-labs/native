// Sticky positioning: a box stays in the flow but shifts inside its scroll container's scrollport
// to keep its insets, until its containing block stops it, and the shift shows in the box's
// measured position. Matches css/css-position/sticky.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=600"><style>
html, body { margin: 0; }
body { font: 16px/1 monospace; }
#sc { overflow: auto; width: 200px; height: 200px; }
/* The block the sticky box can't leave: 300px tall from the top of the scroller. */
#cb { height: 300px; }
#s { position: sticky; top: 10px; left: 15px; width: 60px; height: 40px; background: #ff0000; }
#tail { height: 700px; }
/* A sticky box whose static position is at the bottom of its containing block, which is the whole
   scrollport: there is nothing to shift, and the box isn't dragged into the block either. */
#sc2 { overflow: hidden; width: 100px; height: 100px; }
#cb2 { height: 100px; margin-top: -100px; }
#a2 { height: 100px; }
#s2 { position: sticky; bottom: 0; height: 100px; background: #0000ff; }
/* A sticky box below its containing block: a top inset doesn't pull it up into the block. */
#sc3 { overflow: hidden; width: 100px; height: 100px; }
#cb3 { height: 100px; }
#s3 { position: sticky; top: 0; height: 100px; background: #0000ff; }
/* A sticky box in the page, where the viewport is the scrollport. It starts below its inset. */
#pageSticky { position: sticky; top: 20px; height: 30px; background: #00ff00; }
#spacer { height: 2000px; }
/* A sticky box inside a fixed header: the page rolling past it must not move it. */
#fixed { position: fixed; left: 400px; top: 0; width: 100px; height: 50px; background: #eeeeee; }
#fs { position: sticky; top: 5px; height: 10px; background: #000000; }
#out { position: fixed; right: 0; bottom: 0; background: #ffffff; white-space: pre; }
#down { position: fixed; right: 0; top: 0; }
#pgdown { position: fixed; right: 0; top: 40px; }
</style></head><body>
<div id="sc"><div id="cb"><div id="s"></div></div><div id="tail"></div></div>
<div id="pageSticky"></div>
<div id="sc2"><div id="cb2"><div id="a2"></div><div id="s2"></div></div></div>
<div id="sc3"><div id="cb3"><div id="a2"></div><div id="s3"></div></div></div>
<div id="spacer"></div>
<div id="fixed"><div id="fs"></div></div>
<div id="out">x</div>
<button id="down">down</button>
<button id="pgdown">page</button>
<script>
const sc = document.getElementById("sc");
const s = document.getElementById("s");
const ps = document.getElementById("pageSticky");
const fs = document.getElementById("fs");
const sc2 = document.getElementById("sc2");
const s2 = document.getElementById("s2");
const sc3 = document.getElementById("sc3");
const s3 = document.getElementById("s3");
const out = document.getElementById("out");
const show = (): void => {
  const sr = sc.getBoundingClientRect();
  const r = s.getBoundingClientRect();
  out.textContent = Math.round(r.top - sr.top) + " " + Math.round(sc.scrollTop) + " " +
    Math.round(r.left) + " " + Math.round(ps.getBoundingClientRect().top) + " " +
    Math.round(window.scrollY) + " " + Math.round(fs.getBoundingClientRect().top) + " " +
    Math.round(s2.getBoundingClientRect().top - sc2.getBoundingClientRect().top) + " " +
    Math.round(s3.getBoundingClientRect().top - sc3.getBoundingClientRect().top);
};
document.getElementById("down").addEventListener("click", () => { sc.scrollTop += 100; });
document.getElementById("pgdown").addEventListener("click", () => { window.scrollTo(0, window.scrollY + 300); });
document.getElementById("out").addEventListener("click", show);
show();
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-sticky-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
// A click on #out takes the measurements, and the print step reads what it left.
const steps = [
  "click #out", "print #out",
  "click #down", "click #out", "print #out",
  "click #down", "click #out", "print #out",
  "click #down", "click #out", "print #out",
  "click #pgdown", "click #out", "print #out",
  "click #pgdown", "click #out", "print #out",
].join(" | ");
const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: join(dir, "out.png") },
});
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);
const got = run.stdout.split("\n").slice(0, -1);
// The sticky box's viewport top inside its scroller, the scroller's scroll, its left edge, the
// page sticky's viewport top, the page's scroll, the sticky box in the fixed header's top, and the
// two boxes whose static position is outside their containing block.
const want = [
  // At the top of the scroller the box is already pushed in by its insets, and so is its left;
  // the page sticky starts below its inset, so it hasn't moved.
  "10 0 15 200 0 5 0 100",
  // Scrolling moves the content under the box, and the box stays where it is.
  "10 100 15 200 0 5 0 100",
  "10 200 15 200 0 5 0 100",
  // The block ends at 300: the box can't stay, so it leaves with the block's last 40px.
  "-40 300 15 200 0 5 0 100",
  // The page itself scrolls: the page sticky sticks 20px down, and the fixed header's box stays.
  "-40 300 15 20 300 5 0 100",
  "-40 300 15 20 600 5 0 100",
];
check(`print lines`, got.length === want.length, `got ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, want.length); i++) {
  check(`step ${i}: ${want[i]}`, got[i] === want[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
