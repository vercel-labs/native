// Geometry a framework reads once elements are on screen: offsets, client and scroll sizes,
// client rects, the window's scroll offset, and ResizeObserver callbacks.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; }
#box { position: relative; width: 200px; height: 100px; padding: 10px; border: 5px solid black; }
#inner { width: 50px; height: 20px; margin: 8px; }
#scroller { height: 40px; overflow: auto; }
#tall { height: 200px; }
#hider { width: 60px; }
#hidden { width: 40px; height: 10px; }
</style></head><body>
<div id="box"><div id="inner"></div></div>
<div id="scroller"><div id="tall"></div></div>
<div id="hider"><div id="hidden"></div></div>
<script src="app.ts"></script>
</body></html>`;

// The click changes #inner's width, which the ResizeObserver reports in the next frame.
const SCRIPT = `
const log = (s: string): void => { console.log(s); };

const box = document.getElementById("box") as HTMLElement;
const inner = document.getElementById("inner") as HTMLElement;
const scroller = document.getElementById("scroller") as HTMLElement;
const hider = document.getElementById("hider") as HTMLElement;
const hiddenEl = document.getElementById("hidden") as HTMLElement;

const seen: string[] = [];
const observer = new ResizeObserver((entries) => {
  for (const e of entries) {
    seen.push(e.target.id + " " + e.contentRect.width + "x" + e.contentRect.height +
      " box " + e.borderBoxSize[0].inlineSize + "x" + e.borderBoxSize[0].blockSize);
  }
  log("resize [" + seen.join("; ") + "]");
});
observer.observe(inner);

document.addEventListener("click", () => {
  inner.style.setProperty("width", "80px");
});

// The window's scroll offset: a native page doesn't scroll as a whole before layout runs.
log("window scroll " + window.scrollX + " " + window.scrollY);

requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    // sizes: #box has 200x100 of content, 10px of padding and 5px of border
    log("box offset " + box.offsetWidth + "x" + box.offsetHeight + " client " + box.clientWidth +
      "x" + box.clientHeight + " scrollWidth " + box.scrollWidth);
    log("box rect " + box.getBoundingClientRect().width + "x" + box.getBoundingClientRect().height +
      " rects " + box.getClientRects().length);

    // offsets measure from the padding edge of the nearest positioned ancestor
    log("inner offset " + inner.offsetLeft + " " + inner.offsetTop + " parent " +
      String(inner.offsetParent === (box as unknown as Element)));
    log("inner border " + inner.offsetWidth + "x" + inner.offsetHeight);

    // a scroll container reports the content it can scroll
    log("scroller " + scroller.clientHeight + " " + scroller.scrollHeight + " " + scroller.scrollTop);
    scroller.scrollTop = 30;
    log("scrolled " + scroller.scrollTop);

    // calling it on the page leaves the offsets at zero
    window.scrollTo(0, 40);
    log("window after " + window.scrollX + " " + window.scrollY);

    // a box that isn't generated has no size to report, whatever its last layout left behind
    log("before hide " + hiddenEl.offsetWidth + "x" + hiddenEl.offsetHeight);
    hider.style.display = "none";
    log("hidden " + hiddenEl.offsetWidth + "x" + hiddenEl.offsetHeight + " client " +
      hiddenEl.clientWidth + "x" + hiddenEl.clientHeight + " parent " +
      String(hiddenEl.offsetParent === null));
  });
});
`;

const EXPECTED_LOG = [
  "window scroll 0 0",
  "resize [inner 50x20 box 50x20]",
  "box offset 230x130 client 220x120 scrollWidth 220",
  "box rect 230x130 rects 1",
  "inner offset 18 18 parent true",
  "inner border 50x20",
  "scroller 40 200 0",
  "scrolled 30",
  "window after 0 0",
  "before hide 40x10",
  "hidden 0x0 client 0x0 parent true",
  "resize [inner 50x20 box 50x20; inner 80x20 box 80x20]",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-geometry-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame | click #box | frame" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = EXPECTED_LOG;
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
