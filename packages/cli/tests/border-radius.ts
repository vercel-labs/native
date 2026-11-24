// Border radius: a radius for each corner, elliptical radii with the slash syntax, percentages,
// and the radius on a border's own ring and on a background behind it.
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
<html><head><meta name="native-window" content="width=240, height=640"><style>
body { margin: 0; }
.box { position: absolute; left: 40px; }
#tl { top: 0; width: 100px; height: 60px; background: #ff0000; border-top-left-radius: 30px; }
#ell { top: 80px; width: 100px; height: 60px; background: #00aa00; border-radius: 40px / 20px; }
#pct { top: 180px; width: 100px; height: 60px; background: #0000ff; border-radius: 50%; }
#sh { top: 260px; width: 120px; height: 80px; background: #ff0000; border-radius: 0 40px 0 0; }
#ring { top: 360px; width: 100px; height: 60px; background: #ff0000; border: 6px solid #0000ff; border-top-left-radius: 40px; }
#inline { top: 470px; width: 40px; height: 20px; background: #ff0000; }
#zero { top: 510px; width: 80px; height: 40px; background: #aa00aa; border-top-left-radius: 25px 0; border-bottom-right-radius: 0 25px; }
#huge { top: 560px; width: 80px; height: 40px; background: #008080; border-radius: 3.40282e38px; }
</style></head><body>
<div class="box" id="tl"></div>
<div class="box" id="ell"></div>
<div class="box" id="pct"></div>
<div class="box" id="sh"></div>
<div class="box" id="ring"></div>
<div class="box" id="inline"></div>
<div class="box" id="zero"></div>
<div class="box" id="huge"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const tl = document.getElementById("tl")!;
console.log("tl corner=" + getComputedStyle(tl).borderTopLeftRadius);
const ell = document.getElementById("ell")!;
console.log("ell corner=" + getComputedStyle(ell).borderTopLeftRadius + " shorthand=" + getComputedStyle(ell).borderRadius);
const sh = document.getElementById("sh")!;
console.log("shorthand=" + getComputedStyle(sh).borderRadius);
const pct = document.getElementById("pct")!;
console.log("percent=" + getComputedStyle(pct).borderRadius);
const inline = document.getElementById("inline")!;
inline.style.borderRadius = "5px 15px";
console.log("inline=" + getComputedStyle(inline).borderRadius);
inline.style.borderTopLeftRadius = "7px 9px";
console.log("inline corner=" + getComputedStyle(inline).borderTopLeftRadius);
inline.style.removeProperty("border-top-left-radius");
console.log("removed corner=" + getComputedStyle(inline).borderTopLeftRadius);
`;

const EXPECTED_LOG: [string, string][] = [
  ["a corner serializes its radius", "tl corner=30px"],
  ["an elliptical radius serializes with a slash", "ell corner=40px 20px shorthand=40px / 20px"],
  ["the shorthand keeps each corner in place", "shorthand=0px 40px 0px 0px"],
  ["a percentage radius stays a percentage", "percent=50%"],
  ["an inline shorthand applies", "inline=5px 15px"],
  ["an inline corner keeps both radii", "inline corner=7px 9px"],
  ["removing a corner resets both radii", "removed corner=0px"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-border-styles-"));
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
const MAGENTA = [170, 0, 170];

// #tl at (40, 0), 100x60, with only its top-left corner (30px) rounded: the corner is cut away
// and the other three stay square.
check("a rounded corner is cut away", white(41, 1), `got ${rgb(41, 1)}`);
check("the curve is filled inside the arc", near(52, 12, RED), `got ${rgb(52, 12)}`);
check("an unrounded corner stays square", near(138, 58, RED), `got ${rgb(138, 58)}`);

// #ell at (40, 80): 40px across and 20px down, so its corner is flatter than a circular 40px one
// and a point near the top edge is painted.
check("an elliptical corner is flatter than a round one", near(70, 81, GREEN), `got ${rgb(70, 81)}`);
check("the left side of the ellipse stays wide", near(44, 95, GREEN), `got ${rgb(44, 95)}`);

// #pct at (40, 180): 50% is half the width across and half the height down, so the top edge is
// painted only near its middle and the left edge only near its middle.
check("a percentage radius narrows the top edge", white(60, 181), `got ${rgb(60, 181)}`);
check("a percentage radius keeps the middle", near(90, 181, BLUE), `got ${rgb(90, 181)}`);
check("a percentage radius uses the height on the left", near(41, 210, BLUE), `got ${rgb(41, 210)}`);

// #sh at (40, 260), 120x80, `border-radius: 0 40px 0 0`: the top-left corner stays square and
// the top-right one is rounded.
check("the shorthand leaves an unset corner square", near(41, 261, RED), `got ${rgb(41, 261)}`);
check("the shorthand rounds the corner it names", white(158, 261), `got ${rgb(158, 261)}`);
check("the named corner's curve is filled", near(150, 280, RED), `got ${rgb(150, 280)}`);

// #ring at (40, 360): a 6px blue border around a red box whose top-left corner is 40px. The
// ring follows the corner at its full width, and the background follows it inside.
check("the border ring follows the corner", white(42, 380), `got ${rgb(42, 380)}`);
check("the ring is drawn where it curves", near(44, 390, BLUE), `got ${rgb(44, 390)}`);
check("the background curve nests inside the ring", near(70, 390, RED), `got ${rgb(70, 390)}`);

// #zero at (40, 510), `border-top-left-radius: 25px 0` and `border-bottom-right-radius: 0 25px`:
// a radius that is zero in either direction is no radius at all, so both corners stay square
// rather than each being a flattened curve that paints the corner away.
check("a radius of zero across leaves the corner square", near(41, 511, MAGENTA), `got ${rgb(41, 511)}`);
check("a radius of zero down leaves the corner square", near(118, 548, MAGENTA), `got ${rgb(118, 548)}`);

// #huge at (40, 560), `border-radius: 3.40282e38px`: the exponent form is a plain number, and a
// radius larger than the box is scaled down until opposite corners meet, as Tailwind's
// `rounded-full` relies on. The corners are cut away and the middle is painted.
check("an exponent radius parses and rounds the corner", white(41, 561), `got ${rgb(41, 561)}`);
check("an oversized radius keeps the middle", near(80, 580, [0, 128, 128]), `got ${rgb(80, 580)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
