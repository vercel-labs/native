// `clip: rect()`: its sides as border box edges, negative and crossing sides, the space-separated
// form, a mixed-separator value dropped as browsers drop it, and a clip that runs after a filter.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=360, height=400"><style>
body { margin: 0; }
.box { position: absolute; width: 100px; height: 100px; }
#inset { left: 0; top: 0; background: #ff0000; clip: rect(10px, 60px, 60px, 20px); }
#cross { left: 110px; top: 0; background: #ff0000; clip: rect(0, -50px, 200px, 50px); }
#auto { left: 220px; top: 0; background: #0000ff; clip: rect(0, auto, auto, 0); }
#space { left: 0; top: 110px; background: #00aa00; clip: rect(10px 100px 60px 40px); }
#mixed { left: 110px; top: 110px; background: #ff0000; clip: rect(10px, 100px 60px, 40px); }
#filter { left: 220px; top: 110px; background: #00aa00;
  filter: drop-shadow(16px 16px 20px #ff0000); clip: rect(0, 50px, 50px, 0); }
#plain { left: 0; top: 220px; background: #ff0000; }
</style></head><body>
<div class="box" id="inset"></div>
<div class="box" id="cross"></div>
<div class="box" id="auto"></div>
<div class="box" id="space"></div>
<div class="box" id="mixed"></div>
<div class="box" id="filter"></div>
<div class="box" id="plain"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const css = (id: string) => getComputedStyle(document.getElementById(id)!);
console.log("inset=" + css("inset").getPropertyValue("clip"));
console.log("auto=" + css("auto").getPropertyValue("clip"));
console.log("plain=" + css("plain").getPropertyValue("clip"));
`;

const EXPECTED_LOG: [string, string][] = [
  ["comma-separated sides serialize in px", "inset=rect(10px, 60px, 60px, 20px)"],
  ["an auto side stays auto", "auto=rect(0px, auto, auto, 0px)"],
  ["no clip computes as auto", "plain=auto"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-clip-rect-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  if (/warning|unsupported/i.test(`${b.stdout}${b.stderr}`)) throw new Error(`build warned\n${b.stdout}${b.stderr}`);
  return { img: decodePng(png), out: `${r.stdout}${r.stderr}` };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { img, out } = buildAndRun();
// The snapshot is 2 device px per CSS px; the helpers take CSS coordinates.
const rgb = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (x: number, y: number, c: number[], tol = 24): boolean => {
  const p = rgb(x, y);
  return Math.abs(p[0] - c[0]) <= tol && Math.abs(p[1] - c[1]) <= tol && Math.abs(p[2] - c[2]) <= tol;
};
const white = (x: number, y: number): boolean => near(x, y, [255, 255, 255], 6);
const RED = [255, 0, 0];
const GREEN = [0, 170, 0];
const BLUE = [0, 0, 255];

// #inset: rect(10px, 60px, 60px, 20px) keeps x 20..60 and y 10..60 of the box.
check("a rect keeps its inside", near(30, 30, RED), `got ${rgb(30, 30)}`);
check("a rect cuts its left", white(10, 30), `got ${rgb(10, 30)}`);
check("a rect cuts its right", white(70, 30), `got ${rgb(70, 30)}`);
check("a rect cuts its bottom", white(30, 70), `got ${rgb(30, 70)}`);

// #cross: right -50px is left of the rect's left edge of 50px, so nothing is left.
check("a rect whose sides cross clips everything", white(150, 50), `got ${rgb(150, 50)}`);

// #auto: an auto side stays at the border box edge, so the whole box shows.
check("an auto side keeps the border box edge", near(240, 50, BLUE), `got ${rgb(240, 50)}`);
check("an auto side ends at the border box", white(330, 50), `got ${rgb(330, 50)}`);

// #space: the sides may be separated by whitespace instead of commas.
check("a space-separated rect keeps its inside", near(60, 140, GREEN), `got ${rgb(60, 140)}`);
check("a space-separated rect cuts its left", white(20, 140), `got ${rgb(20, 140)}`);
check("a space-separated rect cuts its top", white(60, 115), `got ${rgb(60, 115)}`);
check("a space-separated rect cuts its bottom", white(60, 180), `got ${rgb(60, 180)}`);

// #mixed: commas and whitespace together are a parse error, and the value is dropped, so the
// box is not clipped at all.
check("a mixed-separator rect is dropped", near(115, 115, RED), `got ${rgb(115, 115)}`);

// #filter: the clip runs after the filter, so the drop shadow outside the rect is cut too.
check("a clip keeps the box inside the rect", near(240, 130, GREEN), `got ${rgb(240, 130)}`);
check("a clip cuts a filter's shadow", white(300, 200), `got ${rgb(300, 200)}`);

check("a box with no clip is untouched", near(50, 270, RED), `got ${rgb(50, 270)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
