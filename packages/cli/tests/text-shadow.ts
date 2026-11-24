// text-shadow: a shadow of the glyphs, offset and blurred, painted behind the text; it inherits,
// and `none` clears it.
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

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=200"><style>
body { margin: 0; font: 13px monospace; }
div { position: absolute; left: 10px; }
#plain { top: 0; }
#offset { top: 20px; text-shadow: 6px 0 0 red; }
#blur { top: 40px; text-shadow: 0 0 5px red; }
#inherit { top: 60px; text-shadow: 4px 0 0 blue; }
#none { top: 80px; text-shadow: 6px 0 0 red; }
</style></head><body>
<div id="plain">MM</div>
<div id="offset">MM</div>
<div id="blur">MM</div>
<div id="inherit"><span id="innerspan">MM</span></div>
<div id="none">MM</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const offset = document.getElementById("offset")!;
console.log("offset=" + getComputedStyle(offset).textShadow);
const plain = document.getElementById("plain")!;
console.log("plain=" + getComputedStyle(plain).textShadow);
const span = document.getElementById("innerspan")!;
console.log("span=" + getComputedStyle(span).textShadow);
const none = document.getElementById("none")!;
none.style.textShadow = "none";
console.log("removed=" + getComputedStyle(none).textShadow);
`;

const EXPECTED_LOG: [string, string][] = [
  ["text-shadow serializes its offsets and color", "offset=rgb(255, 0, 0) 6px 0px 0px"],
  ["the initial text-shadow is none", "plain=none"],
  ["text-shadow inherits", "span=rgb(0, 0, 255) 4px 0px 0px"],
  ["an inline none clears it", "removed=none"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-text-shadow-"));
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

function px(x: number, y: number): number[] {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

/** Counts the pixels of the band that are clearly red: the shadow, not the black glyphs. */
function redCount(y0: number, y1: number): number {
  let n = 0;
  for (let x = 0; x < 320; x += 0.5) {
    for (let y = y0; y <= y1; y += 0.5) {
      const [r, g, b] = px(x, y);
      if (r > 200 && r - g > 40 && r - b > 40) n++;
    }
  }
  return n;
}

function blueCount(y0: number, y1: number): number {
  let n = 0;
  for (let x = 0; x < 320; x += 0.5) {
    for (let y = y0; y <= y1; y += 0.5) {
      const [r, g, b] = px(x, y);
      if (b > 200 && b - r > 40 && b - g > 40) n++;
    }
  }
  return n;
}

/** The rightmost ink of any kind in the band. */
function lastInkX(y0: number, y1: number): number {
  for (let x = 320 * 2 - 1; x >= 0; x--) {
    for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 200 || img.rgba[o + 1] < 200 || img.rgba[o + 2] < 200) return x / 2;
    }
  }
  return -1;
}

check("plain text has no shadow", redCount(0, 16) === 0, `${redCount(0, 16)} red pixels`);
// A 6px offset puts the red copy 6px to the right of the black glyphs, so the band reaches
// further right than the plain one and the shadow color shows where the text isn't.
check("an offset shadow is painted in its color", redCount(20, 36) > 20, `${redCount(20, 36)} red pixels`);
check("an offset shadow reaches past the glyphs", lastInkX(20, 36) > lastInkX(0, 16) + 3,
  `ends ${lastInkX(20, 36)} and ${lastInkX(0, 16)}`);
// A blur spreads the same shadow past the glyph edges.
check("a blurred shadow is painted", redCount(40, 56) > 20, `${redCount(40, 56)} red pixels`);
// A span inside the shadowed box inherits the shadow.
check("text-shadow inherits into a span", blueCount(60, 76) > 20, `${blueCount(60, 76)} blue pixels`);
check("none removes the shadow", redCount(80, 96) === 0, `${redCount(80, 96)} red pixels`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
