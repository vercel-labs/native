// Logical properties in a horizontal, left-to-right writing mode: inline maps to the horizontal
// sides and block to the vertical ones, with -start and -end picking one of the pair.
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

// The boxes are placed at fixed CSS positions, so each sample below names a point in CSS px.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; background: #ffffff; }
#a { position: absolute; inset-inline-start: 20px; top: 0; width: 40px; height: 20px; background: #ff0000; }
#b { position: absolute; inset-inline-end: 20px; top: 0; width: 40px; height: 20px; background: #0000ff; }
#c { position: absolute; inset-block-start: 30px; left: 0; width: 40px; height: 20px; background: #00ff00; }
#d { position: absolute; inset-block-end: 20px; left: 0; width: 40px; height: 20px; background: #ffff00; }
#flow { position: absolute; top: 60px; left: 0; width: 200px; }
#f { height: 10px; margin-inline: 30px 10px; background: #ff00ff; }
#e { box-sizing: border-box; width: 100px; padding-inline: 30px 10px; }
#e > div { height: 10px; background: #00ffff; }
#g { height: 10px; border-inline: 6px solid #ff8800; background: #eeeeee; }
#h { height: 10px; border-block-start: 6px solid #008800; background: #eeeeee; }
#i { position: absolute; direction: rtl; inset-inline-start: 20px; top: 110px; width: 40px; height: 20px; background: #000080; }
#j { position: absolute; direction: rtl; top: 140px; left: 100px; width: 40px; height: 10px; margin-block-start: 30px; background: #800000; }
#k { position: absolute; top: 135px; left: 100px; --m: 30px; margin-inline-start: var(--m); width: 40px; height: 10px; background: #004000; }
#l { position: absolute; top: 155px; left: 100px; --a: 20px; --b: 50px; margin-inline: var(--a) var(--b); width: 20px; height: 10px; background: #400040; }
#p { position: absolute; top: 110px; left: 0; width: 20px; height: 20px; border-start-start-radius: 10px; background: #abcdef; }
#n { position: absolute; top: 185px; left: 60px; inline-size: 30px; block-size: 12px; background: #008080; }
#v { position: absolute; top: 0; left: 60px; width: 40px; height: 100px; writing-mode: vertical-rl; }
#v > div { inline-size: 30px; block-size: 12px; background: #123456; }
#m { position: absolute; top: 160px; left: 150px; width: 20px; height: 20px; border-inline-end: 4px solid #000040; border-block-end: 4px solid #400000; background: #dddddd; }
</style></head><body>
<div id="a"></div><div id="b"></div><div id="c"></div><div id="d"></div>
<div id="flow"><div id="f"></div><div id="e"><div></div></div><div id="g"></div><div id="h"></div></div>
<div id="i"></div><div id="j"></div><div id="k"></div><div id="l"></div><div id="m"></div><div id="n"></div><div id="p"></div><div id="v"><div></div></div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-logical-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const log = `${b.stdout}${b.stderr}`;
check("the build doesn't call the logical properties unsupported", !/'(padding|margin|inset|border)-(inline|block)/.test(log));

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const scale = img.w / 200;
const at = (x: number, y: number): string => {
  const o = (Math.round(y * scale) * img.w + Math.round(x * scale)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
const WHITE = "255,255,255";

// inset-inline-start / inset-inline-end
check("inset-inline-start puts the box at left: 20px", at(30, 10) === "255,0,0", `got ${at(30, 10)}`);
check("nothing is drawn before it", at(10, 10) === WHITE, `got ${at(10, 10)}`);
check("inset-inline-end puts the box 20px from the right", at(150, 10) === "0,0,255", `got ${at(150, 10)}`);
check("nothing is drawn after it", at(190, 10) === WHITE, `got ${at(190, 10)}`);
// inset-block-start / inset-block-end
check("inset-block-start puts the box at top: 30px", at(10, 40) === "0,255,0", `got ${at(10, 40)}`);
check("nothing is drawn above it", at(10, 20) === WHITE, `got ${at(10, 20)}`);
check("inset-block-end puts the box 20px from the bottom", at(10, 170) === "255,255,0", `got ${at(10, 170)}`);
check("nothing is drawn below it", at(10, 190) === WHITE, `got ${at(10, 190)}`);
// margin-inline: start 30px, end 10px of a 200px line
check("margin-inline starts the bar at 30px", at(100, 65) === "255,0,255", `got ${at(100, 65)}`);
check("the end margin shows through on the left", at(10, 65) === WHITE, `got ${at(10, 65)}`);
check("the end margin shows through on the right", at(195, 65) === WHITE, `got ${at(195, 65)}`);
// padding-inline on a 100px border-box: content runs from 30px to 90px
check("padding-inline-start indents the child", at(40, 75) === "0,255,255", `got ${at(40, 75)}`);
check("the child reaches the end padding", at(85, 75) === "0,255,255", `got ${at(85, 75)}`);
check("padding-inline-end leaves the end padding empty", at(95, 75) === WHITE, `got ${at(95, 75)}`);
check("padding-inline-start leaves the start padding empty", at(10, 75) === WHITE, `got ${at(10, 75)}`);
// border-inline on both sides, and border-block-start on the top only
check("border-inline draws the left border", at(2, 85) === "255,136,0", `got ${at(2, 85)}`);
check("border-inline draws the right border", at(197, 85) === "255,136,0", `got ${at(197, 85)}`);
check("border-inline leaves the middle empty", at(100, 85) === "238,238,238", `got ${at(100, 85)}`);
check("border-block-start draws the top border", at(100, 92) === "0,136,0", `got ${at(100, 92)}`);
check("border-block-start leaves the middle empty", at(100, 100) === "238,238,238", `got ${at(100, 100)}`);
// direction: rtl turns the inline axis around, but the block axis still runs down the page
check("inset-inline-start in rtl sits 20px from the right", at(150, 120) === "0,0,128", `got ${at(150, 120)}`);
check("inset-inline-start in rtl leaves the left empty", at(30, 120) === WHITE, `got ${at(30, 120)}`);
check("margin-block-start in rtl still moves the box down", at(110, 175) === "128,0,0", `got ${at(110, 175)}`);
check("margin-block-start in rtl leaves no room above", at(110, 145) === WHITE, `got ${at(110, 145)}`);
// a logical side whose value comes from a var() settles the same way
check("a var() margin-inline-start indents the box", at(140, 140) === "0,64,0", `got ${at(140, 140)}`);
check("a var() margin-inline leaves no room at the start", at(110, 140) === WHITE, `got ${at(110, 140)}`);
check("a var() margin-inline shorthand sets the start side", at(130, 160) === "64,0,64", `got ${at(130, 160)}`);
check("a var() margin-inline shorthand leaves the start margin empty", at(110, 160) === WHITE, `got ${at(110, 160)}`);
// a logical border side lands on the side its axes name
check("border-inline-end paints the right border", at(172, 170) === "0,0,64", `got ${at(172, 170)}`);
check("border-block-end paints the bottom border", at(160, 182) === "64,0,0", `got ${at(160, 182)}`);
check("the logical borders leave the content alone", at(160, 170) === "221,221,221", `got ${at(160, 170)}`);
// inline-size and block-size are the width and height the box's own axes name
check("inline-size is the width in a horizontal box", at(75, 190) === "0,128,128", `got ${at(75, 190)}`);
check("block-size is its height", at(45, 190) === WHITE, `got ${at(45, 190)}`);
check("inline-size is the height in a vertical box", at(94, 15) === "18,52,86", `got ${at(94, 15)}`);
check("block-size is its width there", at(70, 15) === WHITE, `got ${at(70, 15)}`);
// a logical corner rounds the physical corner its axes name
check("border-start-start-radius rounds the top-left corner", at(1, 111) === WHITE, `got ${at(1, 111)}`);
check("the corner leaves the rest of the box painted", at(10, 125) === "171,205,239", `got ${at(10, 125)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
