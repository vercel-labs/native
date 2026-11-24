// Values Tailwind's output leans on: a unitless calc() line height, the lh unit, an opacity
// percentage, calc(infinity * 1px) as a radius, and the relative font weights.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// Every expectation below was read off a headless Chrome render of the same page.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=300"><style>
body { margin: 0; background: #ffffff; }
/* line-height: calc(1.75 / 1.25) is the 1.4 multiplier; 1lh below it is 28px. */
#lh { position: absolute; top: 0; left: 0; width: 100px; font-size: 20px; line-height: calc(1.75 / 1.25); }
#lh > div { height: 1lh; background: #ff0000; }
/* min-height: 1lh of a 10px font at line-height 2 is 20px. */
#mh { position: absolute; top: 50px; left: 0; width: 60px; font-size: 10px; line-height: 2; min-height: 1lh; background: #0000ff; }
#op { position: absolute; top: 90px; left: 0; width: 40px; height: 40px; background: #000000; opacity: 75%; }
/* An infinite radius is as round as the box allows: a circle, then a pill. */
#c { position: absolute; top: 150px; left: 0; width: 40px; height: 40px; background: #00aa00; border-radius: calc(infinity * 1px); }
#p { position: absolute; top: 150px; left: 60px; width: 60px; height: 30px; background: #aa00aa; border-radius: calc(infinity * 1px); }
#w { position: absolute; top: 200px; left: 0; }
/* ch is the advance of "0" and ex the font's x-height: 4ch of 13px monospace is 31.5px wide and
   2ex is 14px tall, as Chrome measures the same page. */
#ch4 { position: absolute; top: 230px; left: 0; font: 13px monospace; width: 4ch; height: 6px; background: #ff0000; }
#ex2 { position: absolute; top: 240px; left: 0; font: 13px monospace; width: 6px; height: 2ex; background: #00aa00; }
#w300 { font-weight: 300; }
#w700 { font-weight: 700; }
#w900 { font-weight: 900; }
#w100 { font-weight: 100; }
</style></head><body>
<div id="lh"><div></div></div>
<div id="mh"></div>
<div id="op"></div>
<div id="c"></div>
<div id="p"></div>
<div id="ch4"></div>
<div id="ex2"></div>
<div id="w">
  <span id="a1">x</span>
  <span id="w300"><span id="a2">x</span></span>
  <span id="w700"><span id="a3">x</span></span>
  <span id="w900"><span id="a4">x</span></span>
  <span id="b1">x</span>
  <span id="w100"><span id="b2">x</span></span>
  <span id="w700"><span id="b3">x</span></span>
  <span id="w900"><span id="b4">x</span></span>
</div>
<script>

for (const [id, prop] of [["a1", "bolder"], ["a2", "bolder"], ["a3", "bolder"], ["a4", "bolder"],
  ["b1", "lighter"], ["b2", "lighter"], ["b3", "lighter"], ["b4", "lighter"]]) {
  const el = document.getElementById(id);
  el.style.fontWeight = prop;
  console.log(prop + " " + getComputedStyle(el.parentElement).fontWeight + " -> " + getComputedStyle(el).fontWeight);
}
</script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-units-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const buildLog = `${b.stdout}${b.stderr}`;
for (const value of ["line-height: calc(1.75 / 1.25)", "min-height: 1lh", "opacity: 75%",
  "border-radius: calc(infinity * 1px)"]) {
  const line = buildLog.split("\n").find((l) => l.includes(`'${value}'`));
  check(`the build accepts '${value}'`, line === undefined, line ?? "");
}

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const S = img.w / 200;
const at = (x: number, y: number): string => {
  const o = (Math.round(y * S) * img.w + Math.round(x * S)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
const WHITE = "255,255,255";

// A unitless calc() line height of 1.4 on a 20px font is 28px, which 1lh then measures.
check("1lh is the calc() line height", at(50, 27) === "255,0,0", `got ${at(50, 27)}`);
check("and not a pixel more", at(50, 29) === WHITE, `got ${at(50, 29)}`);
check("min-height: 1lh takes the line height", at(30, 69) === "0,0,255", `got ${at(30, 69)}`);
check("and stops there", at(30, 71) === WHITE, `got ${at(30, 71)}`);
// 75% of black over white is 64,64,64.
check("opacity takes a percentage", at(20, 110) === "64,64,64", `got ${at(20, 110)}`);
// A 40x40 box with an infinite radius is a circle of radius 20.
check("an infinite radius rounds a square to a circle", at(20, 151) === "0,170,0", `got ${at(20, 151)}`);
check("the corner is outside it", at(1, 151) === WHITE, `got ${at(1, 151)}`);
// A 60x30 box becomes a pill: its top edge runs from 15px to 45px, so 12px in is painted and
// 5px in is not.
check("a wide box takes the largest radius that fits", at(72, 152) === "170,0,170", `got ${at(72, 152)}`);
check("and its end stays cut away", at(65, 152) === WHITE, `got ${at(65, 152)}`);

// Font-relative units, read off the painted boxes: Chrome's 4ch is 31.5px and its 2ex 14px, so
// the fill reaches the 31st pixel but not the 33rd, and the 14th row but not the 15th.
check("4ch is four zero-glyph advances", at(30, 232) === "255,0,0" && at(33, 232) === WHITE,
  `at 30 ${at(30, 232)}, at 33 ${at(33, 232)}`);
check("2ex is twice the font's x-height", at(3, 253) === "0,170,0" && at(3, 255) === WHITE,
  `at 253 ${at(3, 253)}, at 255 ${at(3, 255)}`);

// The relative weights, as Chrome resolves them (CSS Fonts 4).
const out = `${r.stdout}${r.stderr}`;
for (const line of ["bolder 400 -> 700", "bolder 300 -> 400", "bolder 700 -> 900", "bolder 900 -> 900",
  "lighter 400 -> 100", "lighter 100 -> 100", "lighter 700 -> 400", "lighter 900 -> 700"]) {
  check(`font-weight: ${line}`, out.includes(line), out.trim().split("\n").slice(-8).join(" | "));
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
