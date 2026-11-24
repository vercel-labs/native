// The page's own scrolling: the root element scrolls the viewport when its content overflows,
// a wheel scrolls it, the scroll event reaches the document and the window, a fixed box stays
// put, and the viewport's overlay scrollbar shows while it rolls.
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
#top { height: 100px; background: #ffa500; }
#tall { height: 2000px; background: #eeeeee; }
/* An absolutely positioned box 1500px down the page: the page scroll has to move it too. */
#marker { position: absolute; left: 300px; top: 1500px; width: 100px; height: 100px; background: #008000; }
/* A fixed box is anchored to the viewport: scrolling must leave it where it is. */
#fixed { position: fixed; left: 0; top: 0; width: 200px; height: 20px; background: #ff0000; }
#out { position: fixed; right: 0; bottom: 0; background: #0000ff; color: #ffffff; }
#down { position: fixed; left: 600px; top: 0; }
#into { position: fixed; left: 600px; top: 40px; }
#show { position: fixed; left: 600px; top: 80px; }
</style></head>
<body>
<div id="fixed"></div>
<div id="top"></div>
<div id="tall"><div id="marker"></div></div>
<div id="out">x</div>
<button id="down">down</button>
<button id="into">into</button>
<button id="show">show</button>
<script>
let win = 0;
let doc = 0;
const out = document.getElementById("out");
const show = (): void => {
  out.textContent = Math.round(window.scrollY) + " " + win + " " + doc + " " +
    Math.round(document.scrollingElement.scrollTop);
};
window.addEventListener("scroll", () => { win++; show(); });
document.addEventListener("scroll", () => { doc++; });
document.getElementById("down").addEventListener("click", () => { window.scrollBy(0, -1000); });
document.getElementById("into").addEventListener("click", () => {
  document.getElementById("marker").scrollIntoView();
});
document.getElementById("show").addEventListener("click", show);
show();
</script>
</body></html>`;

/** A page with the same overflowing content, but whose viewport can't be scrolled by a wheel. */
function blocked(css: string): string {
  return `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=600"><style>
html, body { margin: 0; }
${css}
#tall { height: 2000px; background: #eeeeee; }
#out { position: fixed; left: 0; top: 0; }
#show { position: fixed; left: 600px; top: 0; }
</style></head>
<body><div id="tall"></div><div id="out">x</div><button id="show">show</button>
<script>
const out = document.getElementById("out");
let win = 0;
window.addEventListener("scroll", () => { win++; });
// Read after a step has laid the page out: module-level code runs before the first frame.
document.getElementById("show").addEventListener("click", () => {
  out.textContent = Math.round(window.scrollY) + " " + win + " " + Math.round(document.documentElement.scrollHeight);
});
</script>
</body></html>`;
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function build(name: string, html: string): string {
  const dir = mkdtempSync(join(tmpdir(), `native-scroll-${name}-`));
  writeFileSync(join(dir, "index.html"), html);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build of ${name} failed\n${b.stderr}`);
  return exe;
}

function run(exe: string, steps: string, png: string): string[] {
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

// The page scrolls: a wheel over it moves the root element, the clamp stops at the end of the
// content, window.scrollBy rolls it back, and scrollIntoView brings the marker into view.
const dir = mkdtempSync(join(tmpdir(), "native-scroll-"));
const exe = build("page", PAGE);
const png = join(dir, "out.png");
const steps = [
  "print #out",
  "wheel #tall 500", "print #out",
  "wheel #tall 5000", "print #out",
  "click #down", "print #out",
  // scrollIntoView moves the page on the frame after the click, so the show button reads the
  // scroll position it left behind. It lines the marker's top up with the top of the viewport —
  // the default block is `start` — and fires no scroll event of its own.
  "click #into", "click #show", "print #out",
].join(" | ");
const got = run(exe, steps, png);
const want = [
  // scrollY, window scroll events, document scroll events, scrollingElement.scrollTop
  "0 0 0 0",
  "500 1 1 500",
  "1500 2 2 1500",
  "500 3 3 500",
  "1500 3 3 1500",
];
check(`print lines`, got.length === want.length, `got ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, want.length); i++) {
  check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);
}

// The snapshot is taken at scroll 1500, two device pixels per CSS pixel.
const img = decodePng(png);
const px = (x: number, y: number): number[] => {
  const o = (y * 2 * img.w + x * 2) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (p: number[], c: number[]): boolean =>
  Math.abs(p[0] - c[0]) < 8 && Math.abs(p[1] - c[1]) < 8 && Math.abs(p[2] - c[2]) < 8;
const RED = [0xff, 0x00, 0x00];
const GREEN = [0x00, 0x80, 0x00];
const GRAY = [0xee, 0xee, 0xee];
const ORANGE = [0xff, 0xa5, 0x00];

check("a fixed box stays at the top of the viewport", near(px(10, 10), RED), `got ${px(10, 10)}`);
check("the marker's top lines up with the viewport", near(px(350, 50), GREEN), `got ${px(350, 50)}`);
check("the page content has scrolled under it", near(px(350, 550), GRAY), `got ${px(350, 550)}`);
check("the top of the page is out of the viewport", !near(px(400, 300), ORANGE), `got ${px(400, 300)}`);
// The viewport's overlay scrollbar sits down the right edge, at the page's scroll position.
const thumb = px(794, 500);
check("the viewport scrollbar shows while scrolling", thumb[0] < 200 && near(thumb, [thumb[0], thumb[0], thumb[0]]),
  `got ${thumb}`);

// The same scroll, driven by the wheel with no script call: the root composites a scroll by
// editing a recorded transform, and a box painted outside that transform (the absolutely
// positioned marker) would stay where the last paint put it unless the container repaints.
const wheelPng = join(dir, "wheel.png");
run(exe, "wheel #tall 500 | wheel #tall 5000 | frame 16 | frame 16", wheelPng);
const wimg = decodePng(wheelPng);
const wpx = (x: number, y: number): number[] => {
  const o = (y * 2 * wimg.w + x * 2) * 4;
  return [wimg.rgba[o], wimg.rgba[o + 1], wimg.rgba[o + 2]];
};
check("a wheel scroll moves positioned content with the page", near(wpx(350, 50), GREEN), `got ${wpx(350, 50)}`);
check("a wheel scroll moves the page under it", near(wpx(350, 550), GRAY), `got ${wpx(350, 550)}`);

// The viewport's overflow is the root's, or the body's when the root's is visible: hidden in
// either place means a wheel can't move the page, even though it still has more content.
const rootHidden = build("root-hidden", blocked("html { overflow: hidden; }"));
const rootOut = run(rootHidden, "wheel #tall 500 | click #show | print #out", join(dir, "a.png"));
check("overflow: hidden on the root stops the page scrolling",
  JSON.stringify(rootOut) === JSON.stringify(["0 0 2000"]), `got ${JSON.stringify(rootOut)}`);
const bodyHidden = build("body-hidden", blocked("body { overflow: hidden; }"));
const bodyOut = run(bodyHidden, "wheel #tall 500 | click #show | print #out", join(dir, "b.png"));
check("body's overflow reaches the viewport",
  JSON.stringify(bodyOut) === JSON.stringify(["0 0 2000"]), `got ${JSON.stringify(bodyOut)}`);
// The root is the viewport's scroller, so `auto` on it rolls the page as a browser does, with
// the scroll event on the window rather than on the html element itself.
const rootAuto = build("root-auto", blocked("html { overflow: auto; }"));
const rootAutoOut = run(rootAuto, "wheel #tall 500 | click #show | print #out", join(dir, "c.png"));
check("overflow: auto on the root scrolls the page",
  JSON.stringify(rootAutoOut) === JSON.stringify(["500 1 2000"]), `got ${JSON.stringify(rootAutoOut)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
