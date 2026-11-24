// clip-path: the basic shapes and path(), their reference boxes, url(#id) clip paths, and the
// computed value's text.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=360, height=520"><style>
body { margin: 0; }
.box { position: absolute; background: #ff0000; }
#inset { left: 0; top: 0; width: 100px; height: 100px; clip-path: inset(20px 0 0 40px); }
#round { left: 110px; top: 0; width: 100px; height: 100px; background: #00aa00; clip-path: inset(0 round 50%); }
#circle { left: 220px; top: 0; width: 100px; height: 100px; background: #0000ff; clip-path: circle(30px at 50% 50%); }
#ellipse { left: 0; top: 110px; width: 100px; height: 100px; clip-path: ellipse(40px 20px at 50% 20px); }
#poly { left: 110px; top: 110px; width: 100px; height: 100px; background: #00aa00; clip-path: polygon(0 0, 100% 0, 50% 100%); }
#path { left: 220px; top: 110px; width: 100px; height: 100px; background: #0000ff; clip-path: path("M 0 0 L 100 0 L 100 50 L 0 50 Z"); }
#out { left: 0; top: 220px; width: 100px; height: 100px; clip-path: circle(40px at 50px 50px); }
#outkid { position: absolute; left: 0; top: 0; width: 200px; height: 20px; background: #ff0000; }
#hole { left: 110px; top: 220px; width: 100px; height: 100px; background: #00aa00; clip-path: path(evenodd, "M0 0 H100 V100 H0 Z M25 25 H75 V75 H25 Z"); }
#cb { left: 220px; top: 220px; width: 100px; height: 100px; clip-path: inset(0); }
#cbkid { position: absolute; left: 0; top: 0; width: 50px; height: 50px; background: #00aa00; }
#cbout { position: absolute; left: 120px; top: 0; width: 40px; height: 40px; background: #0000ff; }
#ri { left: 0; top: 310px; width: 100px; height: 60px; clip-path: inset(0 round 30px); }
#pb { left: 110px; top: 310px; width: 60px; height: 40px; border: 10px solid #0000ff; clip-path: inset(0) padding-box; }
#em { left: 230px; top: 310px; width: 100px; height: 60px; font-size: 20px; clip-path: inset(1em 0 0 0); }
#plain { left: 0px; top: 380px; width: 10px; height: 10px; }
#ref { left: 0px; top: 400px; width: 100px; height: 100px; background: #00aa00; clip-path: url(#clipbox); }
#refbb { left: 110px; top: 400px; width: 100px; height: 100px; background: #0000ff; clip-path: url(#clipbb); }
</style></head><body>
<div class="box" id="inset"></div>
<div class="box" id="round"></div>
<div class="box" id="circle"></div>
<div class="box" id="ellipse"></div>
<div class="box" id="poly"></div>
<div class="box" id="path"></div>
<div class="box" id="out"><div id="outkid"></div></div>
<div class="box" id="hole"></div>
<div class="box" id="cb"><div id="cbkid"></div><div id="cbout"></div></div>
<div class="box" id="ri"></div>
<div class="box" id="pb"></div>
<div class="box" id="em"></div>
<div class="box" id="plain"></div>
<div class="box" id="ref"></div>
<div class="box" id="refbb"></div>
<svg width="0" height="0"><clipPath id="clipbox"><rect x="0" y="0" width="50" height="100"/></clipPath>
<clipPath id="clipbb" clipPathUnits="objectBoundingBox"><rect x="0.5" y="0" width="0.5" height="1"/></clipPath></svg>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const css = (id: string) => getComputedStyle(document.getElementById(id)!);
for (const id of ["inset", "round", "circle", "ellipse", "poly", "path", "hole", "plain"]) {
  console.log(id + "=" + css(id).clipPath);
}
const plain = document.getElementById("plain")!;
plain.style.clipPath = "circle(10px)";
console.log("inline=" + css("plain").clipPath);
plain.style.clipPath = "inset(1px 2px 3px 4px round 5px)";
console.log("inline2=" + css("plain").clipPath);
plain.style.clipPath = "url(#clipbox)";
plain.style.removeProperty("clip-path");
console.log("removed=" + css("plain").clipPath);
`;

const EXPECTED_LOG: [string, string][] = [
  ["inset serializes its sides", "inset=inset(20px 0px 0px 40px)"],
  ["an inset's corner radius serializes", "round=inset(0px 0px 0px 0px round 50% 50% 50% 50% 50% 50% 50% 50%)"],
  ["circle serializes with its centre", "circle=circle(30px at center center)"],
  ["ellipse serializes both radii", "ellipse=ellipse(40px 20px at center 20px)"],
  ["polygon serializes its points", "poly=polygon(0px 0px, 100% 0px, 50% 100%)"],
  ["path serializes its data", 'path=path("M0 0 L100 0 L100 50 L0 50 Z")'],
  ["an even-odd path keeps its fill rule", 'hole=path(evenodd, "M0 0 L100 0 L100 100 L0 100 Z M25 25 L75 25 L75 75 L25 75 Z")'],
  ["no clip-path computes as none", "plain=none"],
  ["an inline shape parses", "inline=circle(10px at center center)"],
  ["an inline inset keeps its radius", "inline2=inset(1px 2px 3px 4px round 5px 5px 5px 5px 5px 5px 5px 5px)"],
  ["removing the inline shape restores none", "removed=none"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-clip-path-"));
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
const BLUE = [0, 0, 255];

// #inset: `inset(20px 0 0 40px)` on a red 100x100 box keeps everything but a 20px strip along the
// top and a 40px one down the left.
check("an inset keeps the box inside its sides", near(60, 60, RED), `got ${rgb(60, 60)}`);
check("an inset cuts the left side", white(20, 60), `got ${rgb(20, 60)}`);
check("an inset cuts the top", white(60, 10), `got ${rgb(60, 10)}`);
check("an inset leaves the right side at the edge", near(97, 60, RED), `got ${rgb(97, 60)}`);

// #round: `inset(0 round 50%)` rounds a 100x100 box into a circle.
check("a rounded inset keeps the box's middle", near(160, 50, GREEN), `got ${rgb(160, 50)}`);
check("a rounded inset cuts the corner", white(114, 4), `got ${rgb(114, 4)}`);
check("a rounded inset keeps the box's edge centres", near(160, 3, GREEN), `got ${rgb(160, 3)}`);

// #circle: radius 30px about the box's centre.
check("a circle keeps its centre", near(270, 50, BLUE), `got ${rgb(270, 50)}`);
check("a circle cuts the box's corners", white(225, 5), `got ${rgb(225, 5)}`);
check("a circle reaches its radius", near(298, 50, BLUE), `got ${rgb(298, 50)}`);
check("a circle stops at its radius", white(305, 50), `got ${rgb(305, 50)}`);

// #ellipse: 40px by 20px about (50%, 20px) of the box.
check("an ellipse keeps its centre", near(50, 130, RED), `got ${rgb(50, 130)}`);
check("an ellipse is wider than it is tall", near(85, 130, RED) && white(85, 170), `got ${rgb(85, 130)} / ${rgb(85, 170)}`);
check("an ellipse stops above its bottom edge", white(50, 175), `got ${rgb(50, 175)}`);

// #poly: a triangle — the top edge and the middle, not the bottom corners.
check("a polygon keeps its inside", near(160, 130, GREEN), `got ${rgb(160, 130)}`);
check("a polygon cuts the bottom-left corner", white(115, 200), `got ${rgb(115, 200)}`);
check("a polygon cuts the bottom-right corner", white(205, 200), `got ${rgb(205, 200)}`);

// #path: a rectangle over the box's top half.
check("a path keeps its interior", near(270, 130, BLUE), `got ${rgb(270, 130)}`);
check("a path cuts what is past its edge", white(270, 175), `got ${rgb(270, 175)}`);

// #out: the clip covers the element's own painting and its descendants' paint that overflows it.
check("a clip covers overflowing content", near(50, 240, RED), `got ${rgb(50, 240)}`);
check("a clip cuts content past its edge", white(140, 250), `got ${rgb(140, 250)}`);

// #hole: an even-odd path with an inner square punched out.
check("an even-odd path keeps its outer ring", near(115, 225, GREEN), `got ${rgb(115, 225)}`);
check("an even-odd path cuts its hole", white(160, 270), `got ${rgb(160, 270)}`);

// #cb: clip-path makes the box a containing block for its absolute children (the green child sits
// at its padding box's origin) and clips one that overflows it (the blue child, 120px to the right).
check("a clipped box contains its absolute child", near(240, 240, GREEN), `got ${rgb(240, 240)}`);
check("a clipped box cuts its overflowing absolute child", white(350, 240), `got ${rgb(350, 240)}`);

// #ri: inset with a 30px corner radius.
check("an inset radius keeps the box's middle", near(50, 340, RED), `got ${rgb(50, 340)}`);
check("an inset radius cuts the corner", white(3, 313), `got ${rgb(3, 313)}`);

// #pb: `inset(0) padding-box` clips the 10px border away and keeps the background inside it.
check("padding-box leaves the border out", white(115, 340), `got ${rgb(115, 340)}`);
check("padding-box keeps the content's inside", near(140, 340, RED), `got ${rgb(140, 340)}`);

// #em: `inset(1em 0 0 0)` with a 20px font cuts 20px from the top.
check("an em inset resolves against the font size", white(250, 320), `got ${rgb(250, 320)}`);
check("an em inset keeps what is below it", near(250, 340, RED), `got ${rgb(250, 340)}`);

// #plain: an unclipped box paints as it always did.
check("a box without a shape is untouched", near(5, 385, RED), `got ${rgb(5, 385)}`);

// #ref: `url(#clipbox)` names a `<clipPath>` in the page; its rect keeps the box's left half.
check("a url() clip keeps the shape's inside", near(20, 450, GREEN), `got ${rgb(20, 450)}`);
check("a url() clip cuts what is past its edge", white(80, 450), `got ${rgb(80, 450)}`);

// #refbb: clipPathUnits="objectBoundingBox" maps the unit square onto the box's border box, so
// the right half of the rect shows.
check("an objectBoundingBox clip keeps its inside", near(180, 450, BLUE), `got ${rgb(180, 450)}`);
check("an objectBoundingBox clip cuts outside it", white(120, 450), `got ${rgb(120, 450)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
