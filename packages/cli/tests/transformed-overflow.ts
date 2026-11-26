// Transformed boxes grow their ancestors' scroll extents through every transform above them, and
// the pass that does it walks the tree once: a chain of nested translations composes to the sum of
// its parts, and laying it out stays linear in the depth of the nesting.
//   node tests/transformed-overflow.ts

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const DEPTH = 1500;

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
#s, #own, #shrink { width: 100px; height: 100px; overflow: auto; }
#own { transform: translateX(50px); }
#escS { width: 100px; height: 100px; overflow: auto; }
#esc { position: relative; width: 100px; height: 100px; }
#escClip { overflow: hidden; width: 50px; height: 50px; }
</style></head><body>
<div id="own"><div style="width:50px;height:50px;transform:translateX(300px)"></div></div>
<div id="shrink"><div id="shrunk" style="width:50px;height:50px;transform:translateX(300px)"></div></div>
<div id="escS"><div id="esc"><div id="escClip"><div style="position:absolute;transform:translateX(2000px);width:50px;height:50px"></div></div></div></div>
<div id="tAwrap" style="transform:translateX(200px)"><div id="tA" style="width:100px;height:100px;overflow:auto"><div style="transform:translateX(120px);width:50px;height:50px"></div></div></div>
<div id="tB" style="position:relative;width:100px;height:100px"><div style="overflow:hidden;width:50px;height:50px"><div style="position:absolute;transform:translateX(300px);width:50px;height:50px"></div></div><div style="overflow:hidden;width:50px;height:50px"><div style="position:absolute;transform:translateX(2000px);width:50px;height:50px"></div></div></div>
<div id="fxwrap" style="transform:translateX(100px)"><div id="fx" style="position:fixed;left:2000px;top:0;width:50px;height:50px"></div></div>
<div id="bodycase" style="transform:translateY(900px);width:50px;height:50px"></div>
<div id="s"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const s = document.getElementById("s")!;
// A chain of ${DEPTH} one-pixel translations: the deepest box paints at x = ${DEPTH}, and its
// width is the scroller\'s content width, so the scroll extent is ${DEPTH} + 100.
let parent = s;
for (let i = 0; i < ${DEPTH}; i++) {
  const d = document.createElement("div");
  d.style.transform = "translateX(1px)";
  parent.append(d);
  parent = d;
}
requestAnimationFrame(() => {
  // Settle a layout, then force a fresh one and time just that: the width change dirties the
  // scroller and everything under it.
  s.style.width = "101px";
  void s.scrollWidth;
  s.style.width = "100px";
  const t0 = performance.now();
  const w = s.scrollWidth;
  const ms = performance.now() - t0;
  console.log("width=" + Math.round(w) + "\\nms=" + Math.round(ms));
  // A scroll container's own transform is not part of its own scroll range.
  console.log("own=" + Math.round(document.getElementById("own")!.scrollWidth));
  // A translation that shrinks must not leave the old, larger extent behind.
  const shrunk = document.getElementById("shrunk")!;
  shrunk.style.transform = "translateX(100px)";
  const small = document.getElementById("shrink")!.scrollWidth;
  shrunk.style.transform = "translateX(300px)";
  const back = document.getElementById("shrink")!.scrollWidth;
  console.log("shrunk=" + Math.round(small) + "\\nback=" + Math.round(back));
  // An absolute box whose containing block sits above an overflow box is not clipped by it.
  console.log("escape=" + Math.round(document.getElementById("escS")!.scrollWidth));
  // A fixed box inside a transformed box moves with the page.
  console.log("fixed=" + Math.round(document.documentElement.scrollWidth));
  // A scroll container inside a transformed ancestor measures itself, not the ancestor.
  console.log("ancestor=" + Math.round(document.getElementById("tA")!.scrollWidth));
  // Two out-of-flow boxes routed to one containing block: the farther one still counts.
  console.log("routed=" + Math.round(document.getElementById("tB")!.scrollWidth));
  // The body's overflow is the viewport's: the page's scroll range still takes in what it holds.
  document.body.style.overflow = "hidden";
  console.log("body=" + Math.round(document.documentElement.scrollHeight));
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-transformed-overflow-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8", cwd: process.cwd() });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const values: Record<string, string> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^(\w+)=(.*)$/.exec(line.trim());
  if (m) values[m[1]] = m[2];
}

check(`${DEPTH} nested translations compose into the scroll extents`,
  values.width === String(DEPTH + 100), values.width);
check("and the pass that measures them stays linear in the depth",
  Number(values.ms) < 1500, `${values.ms}ms for depth ${DEPTH}`);
check("a scroll container's own transform is not in its own scroll range",
  values.own === "350", values.own);
check("a smaller translation shrinks the scroll range again",
  values.shrunk === "150", `${values.shrunk} after shrinking, ${values.back} back`);
check("and growing it again reaches the old edge",
  values.back === "350", values.back);
check("a scroll container inside a transformed ancestor keeps its own scroll range",
  values.ancestor === "170", values.ancestor);
check("two out-of-flow boxes routed to one containing block both count",
  values.routed === "2050", values.routed);
check("a fixed box inside a transformed box moves with the page",
  values.fixed === "2150", values.fixed);
check("an absolute box whose containing block sits above a clipping box is not clipped by it",
  values.escape === "2050", values.escape);
check("the body's overflow propagates to the viewport instead of clipping the page",
  values.body === "1450", values.body);
console.log(`     layout of depth ${DEPTH}: ${values.ms}ms`);

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nall passed");
