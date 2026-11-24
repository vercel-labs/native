// Paint order within a stacking context (CSS 2.1 Appendix E): a box that creates a context without
// being positioned — `opacity` below 1, a transform — paints in the z-index: 0 layer, above the
// in-flow content of its context, not in tree order. Its negative z-index descendants stay inside
// it, and its group opacity covers them; a positive z-index box still paints above it, and clicks
// are routed in the same order.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=600"><style>
body { margin: 0; font: 0/0 monospace; }
#r1, #r2, #r3, #r4, #r5, #r6 { position: absolute; left: 0; width: 400px; height: 100px; }
#r1 { top: 0; } #r2 { top: 100px; } #r3 { top: 200px; } #r4 { top: 300px; } #r5 { top: 400px; }
#r6 { top: 500px; }
/* A later in-flow sibling of the box each row tests, drawn blue so an overlap shows who won. */
.cover { width: 200px; height: 100px; margin-left: 50px; margin-top: -100px; background: #0000ff; }
/* An opacity box under a later sibling: it must paint above it, as a transparent group. */
#o1 { width: 100px; height: 100px; background: #ff0000; opacity: 0.5; }
/* A transformed box is a stacking context too, painted in the same layer. */
#t1 { width: 100px; height: 100px; background: #ff0000; transform: translateX(0); }
#o4 { width: 100px; height: 100px; background: #ff0000; opacity: 0.5; }
/* A negative z-index child belongs inside its opacity context's group, above its background. */
#o4 .neg { position: absolute; left: 0; top: 0; width: 50px; height: 50px; background: #00ff00; z-index: -1; }
#o5 { width: 100px; height: 100px; background: #ff0000; opacity: 0.5; }
#o5 .in { width: 50px; height: 50px; background: #00ff00; }
/* A positive z-index box paints above the z-index: 0 layer the opacity box sits in. */
#p1 { position: absolute; left: 75px; top: 25px; width: 50px; height: 50px; background: #ffff00; z-index: 1; }
/* A float is a stacking context too when it is translucent, and lifts the same way. */
#f1 { float: left; width: 100px; height: 100px; background: #ff0000; opacity: 0.5; }
#c2 { width: 200px; height: 100px; background: #0000ff; }
#out { position: fixed; left: 200px; top: 540px; white-space: pre; }
</style></head>
<body>
<div id="r1"><div id="o1"></div><div class="cover"></div><div id="p1"></div></div>
<div id="r2"><div id="t1"></div><div class="cover"></div></div>
<div id="r3"><div id="t2" style="width:100px;height:100px;background:#ff0000;opacity:0.5"></div><div class="cover" style="margin-left:50px"></div></div>
<div id="r4"><div id="o4"><div class="neg"></div></div></div>
<div id="r5"><div id="o5"><div class="in"></div></div></div>
<div id="r6"><div id="f1"></div><div id="c2"></div></div>
<div id="out"></div>
<script>
const out = document.getElementById("out");
document.addEventListener("click", (e) => {
  const t = e.target as HTMLElement;
  out.textContent = "hit " + t.id;
});
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-stacking-"));
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

// Clicks follow paint order: the opacity box is above the blue sibling under it, and the yellow
// box above that again where they overlap.
const hits = run(["click #o1", "print #out", "click #p1", "print #out", "click #t1", "print #out"]);
const wantHits = ["hit o1", "hit p1", "hit t1"];
check(`click lines`, hits.length === wantHits.length, `got ${JSON.stringify(hits)}`);
for (let i = 0; i < Math.min(hits.length, wantHits.length); i++) {
  check(wantHits[i], hits[i] === wantHits[i], `got ${JSON.stringify(hits[i])}`);
}

const png = join(dir, "out.png");
run([], png);
const img = decodePng(png);
const px = (x: number, y: number): number[] => {
  const o = (y * 2 * img.w + x * 2) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (p: number[], c: number[]): boolean =>
  Math.abs(p[0] - c[0]) < 20 && Math.abs(p[1] - c[1]) < 20 && Math.abs(p[2] - c[2]) < 20;
const PURPLE = [128, 0, 127];
const RED = [255, 0, 0];
const YELLOW = [255, 255, 0];
const BLUE = [0, 0, 255];
const PINK = [255, 126, 126];

// Chrome's pixels for this page. The opacity box covers the blue sibling where they overlap,
// fading red over it to purple.
check("an opacity box paints above a later sibling", near(px(50, 50), PURPLE), `got ${px(50, 50)}`);
check("the sibling shows where the opacity box ends", near(px(125, 50), BLUE), `got ${px(125, 50)}`);
// A positive z-index box is a later layer still.
check("a positive z-index paints above the opacity box", near(px(87, 37), YELLOW), `got ${px(87, 37)}`);
// A transformed box is a stacking context and lifts to the same layer.
check("a transformed box paints above a later sibling", near(px(50, 150), RED), `got ${px(50, 150)}`);
check("an inline-styled opacity box lifts too", near(px(75, 250), PURPLE), `got ${px(75, 250)}`);
// The negative z-index child stays in its opacity context: it paints above the context's red
// background, so the pixel reads green-dominant (over pink it would read red-dominant).
const neg = px(25, 325);
check("a negative z-index child stays inside its opacity context", neg[1] > neg[0] + 30, `got ${neg}`);
check("the context's own background shows beside it", near(px(75, 325), PINK), `got ${px(75, 325)}`);
// In-flow content of an opacity box paints above its background, inside the same box.
const inner = px(25, 425);
check("in-flow content paints above the opacity box's background", inner[1] > inner[0] + 30, `got ${inner}`);
check("and the box's background is faded", near(px(75, 425), PINK), `got ${px(75, 425)}`);
// A translucent float paints above the block that follows it, as Chrome paints it.
check("a float with opacity paints above a later block", near(px(25, 550), PURPLE), `got ${px(25, 550)}`);
check("the block shows where the float is not", near(px(150, 550), BLUE), `got ${px(150, 550)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
