// The two axes of `overflow`: the longhands and the shorthand's one- or two-keyword form, the
// computed-value rule that turns a lone `visible` into `auto`, a wheel that scrolls only the axis
// that asks for it, `overflow: clip` as a clipper that never scrolls, and a single clipped axis.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=600"><style>
html, body { margin: 0; }
body { font: 16px/1 monospace; height: 2000px; }
/* Sideways only: the wide, tall content scrolls across, and is clipped below. */
#a { overflow-x: auto; overflow-y: hidden; width: 200px; height: 100px; }
/* Down only, from the two-keyword shorthand. */
#b { overflow: hidden auto; width: 200px; height: 100px; }
/* clip: a clipper that never scrolls. */
#c { overflow: clip; width: 200px; height: 40px; }
/* One clipped axis: cut off at the right edge, still showing below. */
#d { overflow-x: clip; overflow-y: visible; width: 200px; height: 40px; }
.o { width: 600px; height: 400px; background: linear-gradient(90deg, #ff0000, #0000ff); }
#out { position: fixed; left: 300px; top: 0; white-space: pre; }
#ui { position: fixed; left: 300px; top: 560px; }
</style></head>
<body>
<div id="a"><div class="o"></div></div>
<div id="b"><div class="o"></div></div>
<div id="c"><div class="o"></div></div>
<div id="d"><div class="o"></div></div>
<div id="out"></div>
<div id="ui"><button id="read">read</button><button id="set">set</button><button id="comp">comp</button></div>
<script>
const a = document.getElementById("a");
const b = document.getElementById("b");
const c = document.getElementById("c");
const d = document.getElementById("d");
const out = document.getElementById("out");
const show = (): void => {
  const lines: string[] = [];
  lines.push("a " + Math.round(a.scrollTop) + " " + Math.round(a.scrollLeft));
  lines.push("b " + Math.round(b.scrollTop) + " " + Math.round(b.scrollLeft));
  lines.push("c " + Math.round(c.scrollTop) + " " + Math.round(c.scrollLeft));
  lines.push("page " + Math.round(window.scrollY) + " " + Math.round(window.scrollX));
  out.textContent = lines.join("\\n");
};
// The computed overflow of each box: the longhands, and the shorthand that joins them.
const computed = (): void => {
  const lines: string[] = [];
  for (const el of [a, b, c, d]) {
    const cs = getComputedStyle(el);
    lines.push(cs.overflowX + " " + cs.overflowY + " | " + cs.overflow);
  }
  out.textContent = lines.join("\\n");
};
document.getElementById("read").addEventListener("click", show);
document.getElementById("comp").addEventListener("click", computed);
document.getElementById("set").addEventListener("click", () => {
  a.scrollTop = 100;
  a.scrollLeft = 50;
  c.scrollTop = 100;
  c.scrollLeft = 100;
  show();
});
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-overflow-axes-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

function run(steps: string[], png = ""): string[] {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps.join(" | ") };
  delete env.NATIVE_SNAPSHOT;
  if (png !== "") env.NATIVE_SNAPSHOT = png;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

// Each box computes the axis values its declarations name, with a lone `visible` beside a
// scrolling axis becoming `auto`; the shorthand joins them with a space only when they differ.
// These are Chrome's values for the same page.
const computed = run(["click #comp", "print #out"]);
const wantComputed = [
  "auto hidden | auto hidden",
  "hidden auto | hidden auto",
  "clip clip | clip",
  "clip visible | clip visible",
];
check(`computed lines`, computed.length === wantComputed.length, `got ${JSON.stringify(computed)}`);
for (let i = 0; i < Math.min(computed.length, wantComputed.length); i++) {
  check(`${wantComputed[i]}`, computed[i] === wantComputed[i], `got ${JSON.stringify(computed[i])}`);
}

// `set` writes the same offsets into every box; only the scroll containers take them, and
// `overflow: clip` is not one. Chrome: hidden is scrollable by script, clip is not.
const set = run(["click #set", "print #out"]);
const wantSet = ["a 100 50", "b 0 0", "c 0 0", "page 0 0"];
check(`print lines`, set.length === wantSet.length, `got ${JSON.stringify(set)}`);
for (let i = 0; i < Math.min(set.length, wantSet.length); i++) {
  check(`${wantSet[i]}`, set[i] === wantSet[i], `got ${JSON.stringify(set[i])}`);
}

// A vertical wheel over the sideways-only box leaves it where it is and rolls the page; a
// horizontal one moves it. Over the vertical box it is the other way round.
const wheeled = run([
  "click #set", "print #out",
  "wheel #a 120", "click #read", "print #out",
  "wheel #a 0 150", "click #read", "print #out",
  "wheel #b 0 150", "click #read", "print #out",
  "wheel #b 80", "click #read", "print #out",
]);
const wantWheel = [
  // set: a at 100/50, the page still at the top
  "a 100 50", "b 0 0", "c 0 0", "page 0 0",
  // a vertical wheel over #a: its own scrollTop doesn't move, the page takes the delta
  "a 100 50", "b 0 0", "c 0 0", "page 120 0",
  // a horizontal wheel moves #a sideways and the page stays put
  "a 100 200", "b 0 0", "c 0 0", "page 120 0",
  // a horizontal wheel over #b (overflow-x: hidden) moves nothing
  "a 100 200", "b 0 0", "c 0 0", "page 120 0",
  // a vertical wheel scrolls #b down
  "a 100 200", "b 80 0", "c 0 0", "page 120 0",
];
check(`wheel lines`, wheeled.length === wantWheel.length, `got ${JSON.stringify(wheeled)}`);
for (let i = 0; i < Math.min(wheeled.length, wantWheel.length); i++) {
  check(`${wantWheel[i]}`, wheeled[i] === wantWheel[i], `got ${JSON.stringify(wheeled[i])}`);
}

// A snapshot after a sideways scroll: #a's content has moved under it, it shows no vertical bar
// (its overflow-y is hidden), and #d's one clipped axis lets its content show below the box.
const png = join(dir, "out.png");
run(["wheel #a 0 200"], png);
const img = decodePng(png);
const px = (x: number, y: number): number[] => {
  const o = (y * 2 * img.w + x * 2) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (p: number[], c: number[]): boolean =>
  Math.abs(p[0] - c[0]) < 20 && Math.abs(p[1] - c[1]) < 20 && Math.abs(p[2] - c[2]) < 20;
const WHITE = [0xff, 0xff, 0xff];

// #a scrolled 200: its content starts at content x 200, so the box shows the gradient's middle.
const mid = px(100, 40);
check("the sideways scroll moved the box's content", mid[0] > 120 && mid[2] > 100, `got ${mid}`);
// No vertical scrollbar: the right edge inside the box is still content, not a dark thumb.
const edge = px(194, 40);
check("overflow-y: hidden draws no vertical bar", edge[0] > 100 || edge[2] > 100, `got ${edge}`);
// One clipped axis: below #d's 40px box its content still shows (y is visible)...
const below = px(100, 300);
check("a visible axis lets the content show past the box", below[0] > 100 || below[2] > 100, `got ${below}`);
// ...but to the right of the box it is clipped (x is clip), so the page shows through.
check("a clipped axis cuts the content at the box", near(px(300, 250), WHITE), `got ${px(300, 250)}`);
// #c clips both axes, so nothing of it shows past its box either.
check("overflow: clip clips both axes", near(px(300, 220), WHITE), `got ${px(300, 220)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
