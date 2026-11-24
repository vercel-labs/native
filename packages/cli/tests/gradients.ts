// Regression tests for gradient backgrounds: `linear-gradient()`, `radial-gradient()` and
// `conic-gradient()` as background-image layers, through the shorthand and as an inline style,
// sized and repeated like any other image layer, with colour hints and currentColor. The host draws them with CoreGraphics, so this checks the CSS geometry
// the runtime computes (the gradient line, stop positions, the radius of a circle) by sampling.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

interface Image {
  w: number;
  h: number;
  rgba: Uint8Array;
}

function decodePng(path: string): Image {
  const b = readFileSync(path);
  let i = 8;
  let w = 0;
  let h = 0;
  const idat: Buffer[] = [];
  while (i < b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString("ascii", i + 4, i + 8);
    const data = b.subarray(i + 8, i + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
    }
    if (type === "IDAT") idat.push(data);
    i += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const bpp = 4;
  const stride = w * bpp + 1;
  const out = new Uint8Array(w * h * bpp);
  let prev = new Uint8Array(w * bpp);
  for (let y = 0; y < h; y++) {
    const filter = raw[y * stride];
    const line = raw.subarray(y * stride + 1, y * stride + 1 + w * bpp);
    const cur = new Uint8Array(w * bpp);
    for (let x = 0; x < w * bpp; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const up = prev[x];
      const c = x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += up;
      else if (filter === 3) v += (a + up) >> 1;
      else if (filter === 4) {
        const p = a + up - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c;
      }
      cur[x] = v & 255;
    }
    out.set(cur, y * w * bpp);
    prev = cur;
  }
  return { w, h, rgba: out };
}

// #a: to right, red to blue. #b: 180deg (to bottom), white to black. #c: three stops.
// #d: a circle centred in its box. #e: an inline style's gradient. #f: a 50%x50% gradient
// tile, no-repeat, so the right half of the box shows the background colour instead.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=520"><style>
body { margin: 0; background: #ffffff; }
div { position: absolute; left: 0; }
#a { top: 0; width: 100px; height: 20px; background-image: linear-gradient(to right, #ff0000, #0000ff); }
#b { top: 30px; width: 100px; height: 20px; background: linear-gradient(180deg, #ffffff, #000000); }
#c { top: 60px; width: 100px; height: 20px;
     background-image: linear-gradient(to right, #ff0000 0%, #00ff00 50%, #0000ff 100%); }
#d { top: 90px; left: 0; width: 100px; height: 100px;
     background-image: radial-gradient(circle at 50px 50px, #ff0000, #0000ff); }
#e { top: 0; left: 150px; width: 100px; height: 20px; }
#f { top: 30px; left: 150px; width: 100px; height: 20px; background-color: #ffffff;
     background-image: linear-gradient(to right, #ff0000, #0000ff);
     background-size: 50% 100%; background-repeat: no-repeat; }
#g { top: 60px; left: 150px; width: 100px; height: 40px;
     background-image: repeating-linear-gradient(to right, #ff0000, #0000ff 20px); }
#h { top: 120px; left: 150px; width: 60px; height: 60px;
     background-image: repeating-radial-gradient(#ff0000, #0000ff 20px); }
#i { top: 160px; left: 220px; width: 100px; height: 50px;
     background-image: linear-gradient(to right bottom, #000000 50%, #d3d3d3 50%); }
#j { top: 210px; left: 0; width: 100px; height: 100px;
     background-image: conic-gradient(#ff0000, #00ff00, #0000ff); }
#k { top: 210px; left: 150px; width: 60px; height: 60px;
     background-image: conic-gradient(from 90deg, #ff0000, #00ff00, #0000ff); }
#l { top: 280px; left: 150px; width: 100px; height: 100px;
     background-image: repeating-conic-gradient(#ff0000 0deg, #0000ff 60deg); }
#m { top: 320px; left: 0; width: 100px; height: 20px;
     background-image: linear-gradient(to right, #ff0000, 25%, #0000ff); }
#n { top: 350px; left: 0; width: 100px; height: 20px; color: #00ff00;
     background-image: linear-gradient(to right, currentColor, #000000); }
#o { top: 210px; left: 220px; width: 100px; height: 40px; background-color: #ffffff;
     background-image: linear-gradient(#ff0000 50%, #0000ff 50%);
     background-size: 50px auto; background-repeat: no-repeat; }
#p { top: 400px; left: 0; width: 100px; height: 100px; border-radius: 50%;
     background: repeating-radial-gradient(circle, rgba(0,0,0,0.85) 0 2px, rgba(30,30,40,0.9) 2px 4px); }
#q { top: 400px; left: 150px; width: 100px; height: 40px;
     background-image: repeating-linear-gradient(to bottom, #ff0000 0px, #ff0000 10px, #0000ff 10px, #0000ff 20px); }
#r { top: 470px; left: 0; width: 100px; height: 40px;
     background-image: conic-gradient(#008000 0 0); }
</style></head><body>
<div id="a"></div><div id="b"></div><div id="c"></div><div id="d"></div>
<div id="e" style="background-image: linear-gradient(to right, #0000ff, #00ff00)"></div>
<div id="f"></div><div id="g"></div><div id="h"></div><div id="i"></div>
<div id="j"></div><div id="k"></div><div id="l"></div><div id="m"></div><div id="n"></div>
<div id="o"></div><div id="p"></div><div id="q"></div><div id="r"></div>
</body></html>`;

const SCRIPT = `
const byId = (id: string): HTMLElement => document.getElementById(id)!;
byId("e").style.backgroundImage = "linear-gradient(to right, #0000ff, #00ff00)";
`;

// A pixel is close enough when each channel is within `tol`: CoreGraphics may round an
// interpolated stop.
function near(img: Image, cx: number, cy: number, want: number[], tol = 3): string | null {
  const o = (cy * 2 * img.w + cx * 2) * 4;
  const got = [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
  const ok = got.every((g, i) => Math.abs(g - want[i]) <= tol);
  return ok ? null : `got ${got.join(",")}, want about ${want.join(",")}`;
}

const dir = mkdtempSync(join(tmpdir(), "native-gradients-"));
writeFileSync(join(dir, "index.html"), PAGE.replace("</body>", `<script src="app.ts"></script></body>`));
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

let failed = 0;
function check(name: string, bad: string | null): void {
  if (bad !== null) failed++;
  console.log(`${bad === null ? "ok  " : "FAIL"} ${name}${bad === null ? "" : ` — ${bad}`}`);
}

check("to right starts with the first stop", near(img, 1, 10, [255, 0, 0]));
check("to right interpolates across the middle", near(img, 50, 10, [128, 0, 128]));
check("to right reaches the second stop at its end", near(img, 99, 10, [2, 0, 252], 6));
check("180deg starts white at the top", near(img, 50, 30, [249, 249, 249], 8));
check("180deg is black at the bottom", near(img, 50, 49, [6, 6, 6], 8));
check("a three-stop gradient interpolates the first pair", near(img, 25, 70, [128, 128, 0]));
check("a three-stop gradient hits the middle stop", near(img, 50, 70, [0, 255, 0]));
check("a circle is red at its centre", near(img, 50, 140, [255, 0, 0]));
check("a circle interpolates halfway out", near(img, 85, 140, [128, 0, 128], 4));
// The default circle reaches the farthest corner, 70.7px from the centre.
check("a circle is blue towards its edge", near(img, 95, 140, [92, 0, 162], 4));
check("an inline gradient paints", near(img, 151, 10, [0, 0, 255]));
check("a 50% tile ends the gradient early", near(img, 198, 40, [8, 0, 247], 6));
check("no-repeat leaves the rest of the box to the colour", near(img, 220, 40, [255, 255, 255]));
check("a repeating gradient starts its pattern again", near(img, 160, 70, [128, 0, 128], 6));
check("a repeating gradient repeats every 20px", near(img, 180, 70, [128, 0, 128], 6));
check("a repeating gradient keeps repeating", near(img, 240, 70, [128, 0, 128], 6));
// The pixel at the centre reaches a shade into the first fade, by as much as a rasterizer samples
// off centre.
check("a repeating radial gradient is red at its centre", near(img, 180, 150, [255, 0, 0], 6));
check("a repeating radial gradient repeats at 20px", near(img, 190, 150, [128, 0, 128], 6));
check("a corner direction keeps the box's aspect", near(img, 230, 165, [0, 0, 0]));
check("a corner direction reaches the far half", near(img, 310, 205, [211, 211, 211]));
// A conic gradient with no `from` starts at the top and turns clockwise: red up, red-to-green at
// the right, green down, green-to-blue at the left.
check("a conic gradient starts red at the top", near(img, 50, 220, [255, 0, 0], 6));
check("a conic gradient turns clockwise", near(img, 90, 260, [128, 128, 0], 6));
check("a conic gradient reaches its middle stop going down", near(img, 50, 305, [0, 255, 0], 6));
check("a conic gradient keeps turning", near(img, 10, 260, [0, 128, 128], 6));
check("from 90deg starts the turn at the right", near(img, 209, 240, [255, 0, 0], 6));
check("from 90deg turns into the red-green mix below", near(img, 180, 269, [128, 128, 0], 6));
check("a repeating conic gradient restarts each period", near(img, 200, 285, [255, 0, 0], 6));
check("a repeating conic gradient reaches mid-period", near(img, 240, 330, [128, 0, 128], 8));
// The hint at 25% puts the half mix there, and skews the mix towards the nearer stop after it.
check("a colour hint puts the half mix at its position", near(img, 25, 330, [128, 0, 128], 6));
check("a colour hint bends the mix", near(img, 75, 330, [34, 0, 221], 8));
check("currentColor is the element's colour", near(img, 2, 355, [0, 255, 0], 6));
check("currentColor mixes with the other stop", near(img, 98, 355, [2, 2, 2], 8));
// `50px auto` on a 100x40 box: a gradient has no intrinsic ratio, so the auto height is the whole
// 40px positioning area, not the 20px the width's ratio would give. The bottom half of the tile
// (its hard stop at 50%) is blue, and the 50px-wide tile leaves the rest white.
check("a gradient's auto axis fills the positioning area", near(img, 240, 245, [0, 0, 255], 6));
check("the tile is only as wide as its specified axis", near(img, 280, 210, [255, 255, 255]));
// #p is a 100px disc of 2px rings over white: rgba(0,0,0,.85) reads 38 and rgba(30,30,40,.9)
// reads 52,52,61. The pattern is a whole disc's worth of stops, far more than one copy has.
// The coordinates are a pixel inside each ring, as Chrome draws them.
check("a fine repeating radial gradient draws its rings", near(img, 51, 450, [38, 38, 38]));
check("the next ring is the second colour", near(img, 53, 450, [52, 52, 61]));
check("the ring after it is back to the first", near(img, 55, 450, [38, 38, 38]));
check("the rings keep their period across the disc", near(img, 87, 450, [38, 38, 38]));
check("and 4px on from there it is the second colour again", near(img, 89, 450, [52, 52, 61]));
// #q repeats a hard-stopped pattern down a 40px box, so the last copy's stop lands a hair short of
// the line's end: the pair at that stop has to stay inside the line, or the host draws nothing.
check("a repeating gradient runs downwards", near(img, 190, 405, [255, 0, 0]));
check("a vertical repeating gradient reaches its second stripe", near(img, 190, 415, [0, 0, 255]));
check("a vertical repeating gradient starts over", near(img, 190, 425, [255, 0, 0]));
check("a vertical repeating gradient ends on its second stripe", near(img, 190, 435, [0, 0, 255]));
// A conic gradient whose stops are all one colour is that colour everywhere, exactly: CoreGraphics
// dithers a conic ramp, so drawing the turn instead of filling read a channel off in every pixel.
check("a flat conic gradient is its colour", near(img, 2, 472, [0, 128, 0], 0));
check("a flat conic gradient is exactly its colour at the centre", near(img, 50, 490, [0, 128, 0], 0));
check("a flat conic gradient is exactly its colour at the far corner", near(img, 98, 508, [0, 128, 0], 0));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
