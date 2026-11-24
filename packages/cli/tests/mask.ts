// mask-image: the alpha a gradient or image mask leaves on a box, the box it masks to, the
// mask-* longhands that place and clip it, and the way a masked box becomes a containing block.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng, encodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=360, height=560"><style>
body { margin: 0; }
.box { position: absolute; background: #ff0000; }
#lin { left: 0; top: 0; width: 100px; height: 100px; mask-image: linear-gradient(to right, black, transparent); }
#rad { left: 110px; top: 0; width: 100px; height: 100px; background: #00aa00;
  mask-image: radial-gradient(circle at center, black 0%, black 20%, transparent 65%); }
#clamp { left: 220px; top: 0; width: 100px; height: 100px; mask-image: linear-gradient(black, black); }
#wide { position: absolute; left: 0; top: 0; width: 200px; height: 20px; background: #00aa00; }
#cb { left: 0; top: 110px; width: 100px; height: 100px; background: #0000ff;
  mask-image: linear-gradient(black, black); }
#cbkid { position: absolute; left: 0; top: 0; width: 50px; height: 50px; background: #00aa00; }
#cbout { position: absolute; left: 120px; top: 0; width: 40px; height: 40px; background: #00aa00; }
#inline { left: 0; top: 230px; width: 100px; height: 100px; background: #0000ff; }
#plain { left: 110px; top: 230px; width: 100px; height: 100px; }
#url { left: 0; top: 340px; width: 100px; height: 100px; background: #ff0000;
  mask-image: url(mask.png); mask-size: 50px 50px; mask-repeat: no-repeat; mask-position: 0 0; }
#pos { left: 110px; top: 340px; width: 100px; height: 100px; background: #00aa00;
  mask-image: url(mask.png); mask-size: 50px 50px; mask-repeat: no-repeat; }
#clip { left: 220px; top: 340px; width: 100px; height: 100px; background: #0000ff; padding: 10px;
  mask-image: linear-gradient(black, black); mask-clip: content-box; }
#orig { left: 0; top: 450px; width: 100px; height: 100px; background: #ff0000; padding: 10px;
  mask-image: linear-gradient(to right, black 50%, transparent 50%);
  mask-origin: content-box; mask-size: 50px 50px; mask-repeat: no-repeat; mask-position: 0 0; }
</style></head><body>
<div class="box" id="lin"></div>
<div class="box" id="rad"></div>
<div class="box" id="clamp"><div id="wide"></div></div>
<div class="box" id="cb"><div id="cbkid"></div><div id="cbout"></div></div>
<div class="box" id="inline"></div>
<div class="box" id="plain"></div>
<div class="box" id="url"></div>
<div class="box" id="pos"></div>
<div class="box" id="clip"></div>
<div class="box" id="orig"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const css = (id: string) => getComputedStyle(document.getElementById(id)!);
console.log("plain=" + css("plain").maskImage);
console.log("gradient=" + css("lin").maskImage);
const el = document.getElementById("inline")!;
el.style.maskImage = "linear-gradient(to right, black, transparent)";
console.log("inline=" + (css("inline").maskImage === ""));
el.style.removeProperty("mask-image");
console.log("removed=" + css("inline").maskImage);
// The longhands set from script place the mask where the inline checks below expect it.
el.style.maskImage = "linear-gradient(to right, black 50%, transparent 50%)";
el.style.maskSize = "50px 50px";
el.style.maskRepeat = "no-repeat";
el.style.maskPosition = "0 0";
`;

const EXPECTED_LOG: [string, string][] = [
  ["no mask image computes as none", "plain=none"],
  ["a mask gradient has no computed text yet", "gradient="],
  ["an inline mask image parses", "inline=true"],
  ["removing the inline mask restores none", "removed=none"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-mask-"));
  // The mask fixture: opaque black in its left half, transparent in its right one.
  writeFileSync(join(dir, "mask.png"), encodePng(32, 32, (x) => [0, 0, 0, x < 16 ? 255 : 0]));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
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

// #lin: `linear-gradient(to right, black, transparent)` leaves the left of the box opaque and
// fades it away towards the right, so the red shows over white in the middle at half alpha.
check("a linear mask leaves the box opaque at its start", near(2, 50, RED), `got ${rgb(2, 50)}`);
check("a linear mask fades the box's middle", near(50, 50, [255, 128, 128], 6), `got ${rgb(50, 50)}`);
check("a linear mask hides the box at its end", white(99, 50), `got ${rgb(99, 50)}`);

// #rad: opaque in the middle, transparent at the corners.
check("a radial mask keeps the box's middle", near(160, 50, GREEN), `got ${rgb(160, 50)}`);
check("a radial mask hides the box's corner", white(113, 3), `got ${rgb(113, 3)}`);

// #clamp: the mask box is the border box, so content that overflows it is masked away.
check("a mask keeps content inside its box", near(240, 10, GREEN), `got ${rgb(240, 10)}`);
check("a mask cuts content past its box", white(330, 10), `got ${rgb(330, 10)}`);

// #cb: a masked box is a containing block for its absolute children, and the mask cuts the one
// that overflows it.
check("a masked box contains its absolute child", near(30, 130, GREEN), `got ${rgb(30, 130)}`);
check("a masked box cuts its overflowing absolute child", white(140, 130), `got ${rgb(140, 130)}`);

// #inline: a mask image set from script paints the same way.
check("an inline mask leaves its box opaque at the start", near(5, 235, [0, 0, 255]), `got ${rgb(5, 235)}`);
check("an inline mask hides the space it leaves", white(40, 235), `got ${rgb(40, 235)}`);
check("an inline mask hides its box past its tile", white(90, 235), `got ${rgb(90, 235)}`);
check("a box with no mask is untouched", near(150, 280, RED), `got ${rgb(150, 280)}`);

// #url: an image mask, 50px square at the box's top left, repeating nowhere. The fixture is
// opaque in its left half and transparent in its right one.
check("an image mask keeps the box where the image is opaque", near(10, 360, RED), `got ${rgb(10, 360)}`);
check("an image mask hides the box where the image is clear", white(40, 360), `got ${rgb(40, 360)}`);
check("a no-repeat mask leaves the rest of the box clear", white(80, 360), `got ${rgb(80, 360)}`);

// #pos: mask-position starts at the middle, so the 50px tile sits in the middle of the box.
check("a centered mask keeps the tile's opaque half", near(145, 390, GREEN), `got ${rgb(145, 390)}`);
check("a centered mask clears the tile's other half", white(175, 390), `got ${rgb(175, 390)}`);
check("a centered mask clears the box away from the tile", white(115, 390), `got ${rgb(115, 390)}`);

// #clip: mask-clip's content box leaves the padding clear even where the mask is solid.
check("mask-clip clears the padding", white(225, 350), `got ${rgb(225, 350)}`);
check("mask-clip keeps the content box", near(250, 390, [0, 0, 255]), `got ${rgb(250, 390)}`);

// #orig: the mask is laid out in the content box, so its 50px tile starts past the padding.
check("mask-origin starts the mask inside the padding", near(20, 480, RED), `got ${rgb(20, 480)}`);
check("mask-origin moves the gradient's end with it", white(40, 480), `got ${rgb(40, 480)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
