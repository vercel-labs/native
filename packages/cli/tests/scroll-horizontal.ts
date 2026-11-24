// Horizontal scrolling: a container's scrollLeft and the page's scrollX, a wheel or trackpad's
// horizontal delta on either, the clamp at the end of the content, scrolling a box whose inline
// content is wider than it, fixed boxes staying put, and the overlay scrollbar at the bottom edge.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=600"><style>
html, body { margin: 0; }
body { font: 16px/1 monospace; }
/* A 500px-wide box in a 200px scroll box: 300px of horizontal scrolling. */
#sc { width: 200px; height: 40px; overflow: auto; position: relative; }
#wide { width: 500px; height: 40px; background: #0000ff; }
#edge { position: absolute; left: 250px; top: 0; width: 20px; height: 40px; background: #00ff00; }
/* Inline content wider than its box: a nowrap line is the scrollable overflow. */
#nw { width: 100px; height: 20px; overflow: auto; white-space: nowrap; }
#page { width: 1500px; height: 30px; background: #ff0000; }
#mark { position: absolute; left: 1200px; top: 200px; width: 50px; height: 50px; background: #008000; }
#fixed { position: fixed; left: 0; top: 0; width: 100px; height: 20px; background: #ffff00; z-index: 1; }
#out { position: fixed; right: 0; top: 40px; }
#nwout { position: fixed; right: 0; top: 60px; }
</style></head>
<body>
<div id="fixed"></div>
<div id="sc"><div id="wide"></div><div id="edge"></div></div>
<div id="nw">the quick brown fox jumps over the lazy dog and keeps on running past the edge</div>
<div id="page"></div>
<div id="mark"></div>
<div id="out"></div>
<div id="nwout"></div>
<script>
const sc = document.getElementById("sc");
const nw = document.getElementById("nw");
const out = document.getElementById("out");
const nwout = document.getElementById("nwout");
// scrollLeft, window.scrollX, the container's scrollWidth and clientWidth, the document's scrollLeft
const show = (): void => {
  out.textContent = Math.round(sc.scrollLeft) + " " + Math.round(window.scrollX) + " " +
    Math.round(sc.scrollWidth) + " " + Math.round(sc.clientWidth) + " " +
    Math.round(document.scrollingElement.scrollLeft);
};
const shownw = (): void => {
  nwout.textContent = (nw.scrollWidth > nw.clientWidth ? "wide" : "narrow") + " " +
    (nw.scrollLeft === nw.scrollWidth - nw.clientWidth ? "end" : String(Math.round(nw.scrollLeft)));
};
// Every scroll puts the numbers on screen, so a step's effect is what the next print reads.
window.addEventListener("scroll", show);
sc.addEventListener("scroll", show);
nw.addEventListener("scroll", shownw);
document.getElementById("read").addEventListener("click", show);
document.getElementById("readnw").addEventListener("click", shownw);
document.getElementById("setc").addEventListener("click", () => { sc.scrollLeft = 50; show(); });
document.getElementById("setw").addEventListener("click", () => { window.scrollTo(100, 0); show(); });
document.getElementById("by").addEventListener("click", () => { window.scrollBy(200, 0); show(); });
</script>
<button id="setc">set</button>
<button id="setw">to</button>
<button id="by">by</button>
<button id="read">read</button>
<button id="readnw">nw</button>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-scroll-h-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

function run(steps: string[], png: string): string[] {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps.join(" | ") };
  delete env.NATIVE_SNAPSHOT;
  if (png !== "") env.NATIVE_SNAPSHOT = png;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

// The numbers, read after each step by the scroll listeners. A delta the container can't take
// chains to the page, as it does in a browser.
const got = run([
  "click #read", "print #out",
  // A wheel with only a horizontal delta scrolls the container under the pointer.
  "wheel #sc 0 300", "print #out",
  // It stops at the end of the content (500 - 200), and the rest of the delta rolls the page.
  "wheel #sc 0 1000", "print #out",
  // Inline content wider than its box scrolls too.
  "click #readnw", "print #nwout",
  "wheel #nw 0 1000", "print #nwout",
  // scrollLeft, scrollTo() and scrollBy() move the page.
  "click #setc", "print #out",
  "click #setw", "print #out",
  "click #by", "print #out",
  // The page's own horizontal scroll: 1500 - 800 = 700 at the end.
  "wheel #page 0 500", "print #out",
  "wheel #page 0 5000", "print #out",
  // A wheel with only a vertical delta leaves the page's horizontal scroll where it is.
  "wheel #page 300", "print #out",
], "");
const want = [
  "0 0 500 200 0",
  "300 0 500 200 0",
  "300 700 500 200 700",
  "wide 0",
  "wide end",
  "50 700 500 200 700",
  "50 100 500 200 100",
  "50 300 500 200 300",
  "50 700 500 200 700",
  "50 700 500 200 700",
  "50 700 500 200 700",
];
check(`print lines`, got.length === want.length, `got ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, want.length); i++) {
  check(`${want[i]}`, got[i] === want[i], `got ${JSON.stringify(got[i])}`);
}

// A snapshot of the container scrolled 200: its content moved under it, its overlay scrollbar
// runs along its bottom edge, and the page itself hasn't moved.
const png = join(dir, "out.png");
run(["wheel #sc 0 200"], png);
const img = decodePng(png);
const px = (x: number, y: number): number[] => {
  const o = (y * 2 * img.w + x * 2) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (p: number[], c: number[]): boolean =>
  Math.abs(p[0] - c[0]) < 8 && Math.abs(p[1] - c[1]) < 8 && Math.abs(p[2] - c[2]) < 8;
const RED = [0xff, 0x00, 0x00];
const GREEN = [0x00, 0xff, 0x00];
const YELLOW = [0xff, 0xff, 0x00];
const BLUE = [0x00, 0x00, 0xff];

check("a fixed box stays at the left of the viewport", near(px(10, 10), YELLOW), `got ${px(10, 10)}`);
// #edge sits at content x 250..270; scrolled 200, it's at viewport 50..70.
check("the container's content moved left with its scroll", near(px(60, 30), GREEN), `got ${px(60, 30)}`);
check("the box the content covers is blue", near(px(150, 30), BLUE), `got ${px(150, 30)}`);
// The container's own scrollbar: a dark thumb along its bottom edge, above the blue.
const thumb = px(100, 34);
check("the container's horizontal scrollbar shows while scrolling",
  thumb[0] < 120 && thumb[2] > 120, `got ${thumb}`);
// The page didn't scroll, so its content still reaches past the viewport.
check("the page itself stayed put", near(px(700, 75), RED), `got ${px(700, 75)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
