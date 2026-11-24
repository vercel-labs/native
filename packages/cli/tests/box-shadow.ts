// box-shadow: offsets, blur, spread (including a negative one), inset shadows, several shadows in
// one list, currentColor, and the computed value's text.
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

// Each box sits at a known place, and the colours tell them apart.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=620"><style>
body { margin: 0; }
.box { position: absolute; background: #ff0000; }
#off { left: 40px; top: 0; width: 60px; height: 40px; box-shadow: 20px 0 #00aa00; }
#blur { left: 40px; top: 60px; width: 60px; height: 40px; box-shadow: 0 0 16px #0000ff; }
#spread { left: 40px; top: 160px; width: 60px; height: 40px; box-shadow: 0 0 0 10px #00aa00; }
#neg { left: 40px; top: 260px; width: 60px; height: 40px; box-shadow: 30px 0 0 -10px #0000ff; }
#inset { left: 40px; top: 360px; width: 80px; height: 60px; background: #ffffff; box-shadow: inset 0 0 0 10px #ff0000; }
#insetoff { left: 40px; top: 440px; width: 80px; height: 60px; background: #ffffff; box-shadow: inset 10px 0 0 0 #0000ff; }
#multi { left: 40px; top: 540px; width: 40px; height: 40px; box-shadow: 0 0 0 8px #00aa00, 0 0 0 16px #0000ff; }
#round { left: 160px; top: 20px; width: 60px; height: 60px; border-radius: 40px; box-shadow: 0 0 0 12px #00aa00; }
#cc { left: 160px; top: 120px; width: 60px; height: 40px; color: #0000ff; box-shadow: 0 0 0 10px; }
#em { left: 160px; top: 200px; width: 40px; height: 20px; font-size: 20px; box-shadow: 1em 0 #0000ff; }
#plain { left: 160px; top: 260px; width: 40px; height: 20px; }
#text { line-height: 18.84px; }
#frac { margin-left: 240px; width: 40px; height: 40px; background: #ff0000; box-shadow: inset 0 0 0 40px #0000ff; }
#circle { left: 240px; top: 300px; width: 4px; height: 4px; border-radius: 50%; box-shadow: 0 0 0 30px #00aa00; }
</style></head><body>
<div id="text">x</div>
<div id="frac"></div>
<div class="box" id="off"></div>
<div class="box" id="blur"></div>
<div class="box" id="spread"></div>
<div class="box" id="neg"></div>
<div class="box" id="inset"></div>
<div class="box" id="insetoff"></div>
<div class="box" id="multi"></div>
<div class="box" id="round"></div>
<div class="box" id="cc"></div>
<div class="box" id="em"></div>
<div class="box" id="plain"></div>
<div class="box" id="circle"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
for (const id of ["off", "blur", "spread", "neg", "inset", "insetoff", "multi", "cc", "em", "plain"]) {
  const el = document.getElementById(id)!;
  console.log(id + "=" + getComputedStyle(el).boxShadow);
}
const off = document.getElementById("off")!;
off.style.boxShadow = "1px 2px 3px 4px #000000";
console.log("inline=" + getComputedStyle(off).boxShadow);
off.style.boxShadow = "1px";
console.log("invalid=" + getComputedStyle(off).boxShadow);
off.style.removeProperty("box-shadow");
console.log("removed=" + getComputedStyle(off).boxShadow);
`;

const EXPECTED_LOG: [string, string][] = [
  ["an offset shadow serializes its color and four lengths", "off=rgb(0, 170, 0) 20px 0px 0px 0px"],
  ["a blur serializes", "blur=rgb(0, 0, 255) 0px 0px 16px 0px"],
  ["a spread serializes", "spread=rgb(0, 170, 0) 0px 0px 0px 10px"],
  ["a negative spread serializes", "neg=rgb(0, 0, 255) 30px 0px 0px -10px"],
  ["an inset shadow ends with inset", "inset=rgb(255, 0, 0) 0px 0px 0px 10px inset"],
  ["several shadows keep their written order", "multi=rgb(0, 170, 0) 0px 0px 0px 8px, rgb(0, 0, 255) 0px 0px 0px 16px"],
  ["currentColor resolves to the text color", "cc=rgb(0, 0, 255) 0px 0px 0px 10px"],
  ["an em length resolves against the font size", "em=rgb(0, 0, 255) 20px 0px 0px 0px"],
  ["no shadow computes as none", "plain=none"],
  ["an inline shadow applies", "inline=rgb(0, 0, 0) 1px 2px 3px 4px"],
  ["an invalid value leaves the old one", "invalid=rgb(0, 0, 0) 1px 2px 3px 4px"],
  ["removing the inline shadow restores the rule", "removed=rgb(0, 170, 0) 20px 0px 0px 0px"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-box-shadow-"));
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
const white = (x: number, y: number): boolean => near(x, y, [255, 255, 255]);
const RED = [255, 0, 0];
const BLUE = [0, 0, 255];
const GREEN = [0, 170, 0];

// #off at (40, 0), 60x40, shadow `20px 0`: the shadow is the box's own shape moved 20px right, so
// it shows in a 20px band to the right of the box and nowhere else.
check("an offset shadow shows past the box", near(110, 20, GREEN), `got ${rgb(110, 20)}`);
check("an offset shadow ends where its shape ends", white(125, 20), `got ${rgb(125, 20)}`);
check("an offset shadow leaves the other side clear", white(30, 20), `got ${rgb(30, 20)}`);
check("the box paints over the shadow it casts", near(70, 20, RED), `got ${rgb(70, 20)}`);

// #blur at (40, 60): a 16px blur fades the shadow out over a few pixels, so just outside the box
// it is a faint blue and further out nothing.
const blurNear = rgb(70, 55);
check("a blur softens the shadow's edge", blurNear[0] < 220 && blurNear[2] > 240, `got ${blurNear}`);
check("a blur fades out", white(70, 130), `got ${rgb(70, 130)}`);
check("a blur keeps the box itself", near(70, 80, RED), `got ${rgb(70, 80)}`);

// #spread at (40, 160), 60x40, `0 0 0 10px`: the shadow is the box grown 10px on every side, so a
// solid ring surrounds it.
check("spread grows the shadow on the left", near(35, 180, GREEN), `got ${rgb(35, 180)}`);
check("spread grows the shadow on top", near(70, 155, GREEN), `got ${rgb(70, 155)}`);
check("spread grows the shadow below", near(70, 205, GREEN), `got ${rgb(70, 205)}`);
check("a spread shadow stops at the ring's edge", white(25, 180), `got ${rgb(25, 180)}`);

// #neg at (40, 260), 60x40, `30px 0 0 -10px`: the shadow shrinks 10px in from every side before
// it moves, so it is only 20px tall and shows right of the box between those edges.
check("a negative spread shows past the box", near(110, 280, BLUE), `got ${rgb(110, 280)}`);
check("a negative spread shortens the shadow", white(110, 265), `got ${rgb(110, 265)}`);
check("a negative spread narrows the shadow", white(125, 280), `got ${rgb(125, 280)}`);

// #inset at (40, 360), 80x60 white, `inset 0 0 0 10px`: the shadow is painted inside the box, as
// a frame 10px wide.
check("an inset shadow frames the box on the left", near(44, 390, RED), `got ${rgb(44, 390)}`);
check("an inset shadow frames the box on top", near(80, 364, RED), `got ${rgb(80, 364)}`);
check("an inset shadow leaves the middle clear", white(80, 390), `got ${rgb(80, 390)}`);
check("an inset shadow stays inside the box", white(30, 390), `got ${rgb(30, 390)}`);

// #insetoff at (40, 440), 80x60 white, `inset 10px 0 0 0`: the inner shape moves right with the
// offset, so the shadow gathers on the left and the right edge stays clear.
check("an inset offset thickens the shadow's side", near(44, 470, BLUE), `got ${rgb(44, 470)}`);
check("an inset offset thins the opposite side", white(116, 470), `got ${rgb(116, 470)}`);

// #multi at (40, 540), 40x40, a green 8px shadow and then a blue 16px one: the first is painted
// on top, so green is the inner ring and blue the outer.
check("the first shadow in a list paints on top", near(34, 560, GREEN), `got ${rgb(34, 560)}`);
check("the second shadow surrounds the first", near(29, 560, BLUE), `got ${rgb(29, 560)}`);
check("a shadow list stops after its last shadow", white(22, 560), `got ${rgb(22, 560)}`);

// #round at (160, 20), 60x60 with a 40px radius (scaled to 30 by the height), `0 0 0 12px`: the
// spread follows the rounded corner, so the shadow's own corner is cut away.
check("a rounded box's shadow has the same curve", white(152, 12), `got ${rgb(152, 12)}`);
check("a rounded box's shadow follows the curve's side", near(152, 50, GREEN), `got ${rgb(152, 50)}`);
check("a rounded box's shadow covers the straight edge", near(190, 12, GREEN), `got ${rgb(190, 12)}`);

// #cc at (160, 120), `color: #0000ff` and no shadow color: the shadow takes the text color.
check("a shadow without a color is the text color", near(153, 140, BLUE), `got ${rgb(153, 140)}`);

// #frac follows a line of text with a fractional line-height, so it starts part-way down a pixel
// row (18.84px). Its background
// and its fully-covering inset shadow snap that edge the same way, so the row the edge falls in
// stays clear instead of showing the shadow blended over white.
check("a shadow's edges snap like the box's own", white(250, 18.5), `got ${rgb(250, 18.5)}`);
check("a snapped shadow still covers the box", near(250, 19.5, BLUE), `got ${rgb(250, 19.5)}`);

// #circle at (240, 300), 4x4 with `border-radius: 50%`, `0 0 0 30px`: the radius covers the whole
// edge, so the shadow keeps the box's roundness and spreads to a circle of radius 32 (CSS
// Backgrounds 3, the outset-adjusted border radius) rather than growing into a square.
check("a 50% radius spreads to a circle", near(242, 271, GREEN), `got ${rgb(242, 271)}`);
check("a 50% radius spreads as far as the circle", near(242, 333, GREEN), `got ${rgb(242, 333)}`);
check("a circle's shadow has no square corner", white(212, 272), `got ${rgb(212, 272)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
