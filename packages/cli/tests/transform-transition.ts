// Transitions of `transform`: a list interpolates function by function, `none` stands for the
// identity of the other list, and two lists that name different functions mix through the
// matrices they resolve to.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=200"><style>
body { margin: 0; }
.box { position: absolute; width: 40px; height: 40px; transition: transform 1s linear; }
#a { left: 0; top: 0; background: rgb(255, 0, 0); transform: translateY(0px); }
#a:hover { transform: translateY(40px); }
#b { left: 60px; top: 0; background: rgb(0, 128, 0); transform: scale(1); }
#b:hover { transform: scale(2); }
#c { left: 0; top: 100px; background: rgb(0, 0, 255); transform: translateX(0px); }
#c:hover { transform: translateY(40px); }
#d { left: 60px; top: 100px; background: rgb(200, 0, 200); transform: none; }
#d:hover { transform: translateY(40px); }
</style></head><body>
<div class="box" id="a"></div>
<div class="box" id="b"></div>
<div class="box" id="c"></div>
<div class="box" id="d"></div>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-transform-transition-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
if (/warning|unsupported/i.test(`${b.stdout}${b.stderr}`)) throw new Error(`build warned\n${b.stdout}${b.stderr}`);

let shots = 0;
/** Hovers `sel`, advances the clock to `ms` and snapshots the page. */
function shot(sel: string, ms: number): { img: ReturnType<typeof decodePng>; out: string } {
  const png = join(dir, `out-${shots++}.png`);
  const steps = `hover ${sel} | frame 0 | frame ${ms}`;
  const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: steps } });
  if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);
  return { img: decodePng(png), out: `${run.stdout}${run.stderr}` };
}

/** The colour at a point in CSS pixels. */
const at = (img: ReturnType<typeof decodePng>, x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (got: number[], want: number[], tol = 24): boolean =>
  Math.abs(got[0] - want[0]) <= tol && Math.abs(got[1] - want[1]) <= tol && Math.abs(got[2] - want[2]) <= tol;

const red = [255, 0, 0], green = [0, 128, 0], blue = [0, 0, 255], magenta = [200, 0, 200], white = [255, 255, 255];

// A list with the same function at both ends moves its parameter halfway.
const a = shot("#a", 500).img;
check("a translate list moves halfway down", near(at(a, 20, 50), red) && near(at(a, 20, 10), white),
  `(20,50) ${at(a, 20, 50)}, (20,10) ${at(a, 20, 10)}`);

// scale(1) to scale(2) is 1.5 halfway, about the box's centre.
const s = shot("#b", 500).img;
check("a scale list grows halfway about the centre", near(at(s, 53, 20), green) && near(at(s, 47, 20), white),
  `(53,20) ${at(s, 53, 20)}, (47,20) ${at(s, 47, 20)}`);

// Two different functions mix through their matrices: the x-only start turns into the y-only end.
const c = shot("#c", 500).img;
check("mismatched lists move through their matrices", near(at(c, 20, 130), blue) &&
  near(at(c, 20, 105), white) && near(at(c, 44, 130), white),
  `(20,130) ${at(c, 20, 130)}, (20,105) ${at(c, 20, 105)}, (44,130) ${at(c, 44, 130)}`);

// `none` is the identity of the other list: it interpolates like translateY(0) would.
const d = shot("#d", 500).img;
check("none mixes as the other list's identity", near(at(d, 80, 130), magenta) && near(at(d, 80, 105), white),
  `(80,130) ${at(d, 80, 130)}, (80,105) ${at(d, 80, 105)}`);

// At the end of the transition each box is where its rule says.
const done = shot("#a", 1000).img;
check("the end of the transition is the rule's value", near(at(done, 20, 50), red) && near(at(done, 20, 30), white),
  `(20,50) ${at(done, 20, 50)}, (20,30) ${at(done, 20, 30)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
