// overflow-clip-margin: the clip a box's content lives inside is its padding box by default,
// grown by a margin on the axes that clip with `overflow: clip`, and measured from whichever
// visual box the declaration names. Hit testing follows the grown clip, and the value answers
// getComputedStyle as a browser writes it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=800"><style>
body { margin: 0; font: 0/0 monospace; background: #fff; }
.box { position: absolute; left: 20px; width: 100px; height: 100px; overflow: clip; }
.kid { position: absolute; left: 0; top: 0; background: #ff0000; }
/* A margin grows the clip past the box: the child shows 50px beyond the right edge. */
#a { top: 20px; overflow-clip-margin: 50px; }
#a .kid { width: 260px; height: 50px; }
/* A named visual box: content-box 0 clips at the content box, over no padding or border. */
#b { top: 160px; width: 80px; height: 80px; padding: 10px; border: 5px solid #000;
     overflow-clip-margin: content-box 0px; }
#b .kid { left: -15px; top: -15px; width: 130px; height: 130px; }
/* A negative margin shrinks the clip inside the box. */
#c { top: 300px; overflow-clip-margin: -20px; }
#c .kid { width: 100px; height: 100px; }
/* The clip edge's corners grow with the margin, as an outer shadow's spread grows them. */
#d { top: 440px; border-radius: 20px; overflow-clip-margin: content-box 10px; }
#d .kid { position: static; margin: -50px 0 0 -50px; width: 200px; height: 200px; background: #0000ff; }
/* A scroller clips at its padding box, so the named box leaves it alone. */
#e { top: 600px; width: 80px; height: 80px; padding: 10px; border: 5px solid #000; overflow: hidden;
     overflow-clip-margin: content-box 0px; }
#e .kid { left: -15px; top: -15px; width: 130px; height: 130px; }
#out { position: fixed; left: 200px; top: 760px; white-space: pre; }
</style></head>
<body>
<div class="box" id="a"><div class="kid" id="k1"></div></div>
<div class="box" id="b"><div class="kid" id="k2"></div></div>
<div class="box" id="c"><div class="kid" id="k3"></div></div>
<div class="box" id="d"><div class="kid" id="k4"></div></div>
<div class="box" id="e"><div class="kid" id="k5"></div></div>
<div id="out"></div>
<script>
const out = document.getElementById("out");
document.addEventListener("click", (e) => {
  const t = e.target as HTMLElement;
  out.textContent = "hit " + (t.id || t.tagName.toLowerCase());
});
const a = document.getElementById("a")!;
const b = document.getElementById("b")!;
const c = document.getElementById("c")!;
const d = document.getElementById("d")!;
console.log("css=" + JSON.stringify([a, b, c, d].map((el) =>
  getComputedStyle(el).getPropertyValue("overflow-clip-margin"))));
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-overflow-clip-margin-"));
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

const lines = run([]);
const css = JSON.parse(lines[0].slice(4)) as string[];
check("a computed margin reads as its length", css[0] === "50px", `got ${JSON.stringify(css[0])}`);
check("a named visual box reads before the length", css[1] === "content-box", `got ${JSON.stringify(css[1])}`);
check("a negative margin keeps its sign", css[2] === "-20px", `got ${JSON.stringify(css[2])}`);
check("box and length read together", css[3] === "content-box 10px", `got ${JSON.stringify(css[3])}`);

// A click beyond the box but inside the grown clip reaches the child, where the box alone would
// have made it unreachable.
const hits = run(["click #k1", "print #out"]);
check("a click inside the clip margin reaches the child", hits[1] === "hit k1", `got ${JSON.stringify(hits[1])}`);

const png = join(dir, "out.png");
run([], png);
const img = decodePng(png);
const px = (x: number, y: number): number[] => {
  const o = (y * 2 * img.w + x * 2) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (p: number[], c: number[]): boolean =>
  Math.abs(p[0] - c[0]) < 20 && Math.abs(p[1] - c[1]) < 20 && Math.abs(p[2] - c[2]) < 20;
const RED = [255, 0, 0];
const BLUE = [0, 0, 255];
const WHITE = [255, 255, 255];

// The child paints 50px beyond the box before the clip cuts it off.
check("the margin lets content paint beyond the box", near(px(150, 45), RED), `got ${px(150, 45)}`);
check("the clip still ends at the margin", near(px(180, 45), WHITE), `got ${px(180, 45)}`);
// content-box 0 clips at the content box: the padding inside the border is untouched.
check("a content-box clip starts at the content box", near(px(30, 200), WHITE), `got ${px(30, 200)}`);
check("its content paints inside the content box", near(px(60, 200), RED), `got ${px(60, 200)}`);
// A negative margin pulls the clip in from the padding box.
check("a negative margin clips inside the box", near(px(30, 370), WHITE), `got ${px(30, 370)}`);
check("the middle of a shrunken clip still paints", near(px(70, 370), RED), `got ${px(70, 370)}`);
// The rounded clip edge grew with the margin: a point in the grown band outside the arc is
// clipped, and one inside the arc there is painted.
check("the grown clip edge keeps a rounded corner", near(px(12, 432), WHITE), `got ${px(12, 432)}`);
check("and lets content through inside the arc", near(px(12, 460), BLUE), `got ${px(12, 460)}`);
// overflow: hidden ignores the named box and the margin: the child paints over the padding.
check("a scroller clips at its padding box, not the named one", near(px(30, 660), RED), `got ${px(30, 660)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
