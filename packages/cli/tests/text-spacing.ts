// letter-spacing and word-spacing: the extra room is measured into the line (so wrapping sees it)
// and drawn between the glyphs.
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
<html><head><meta name="native-window" content="width=320, height=320"><style>
body { margin: 0; font: 13px monospace; }
div { position: absolute; left: 10px; height: 20px; }
#plain { top: 0; }
#letter { top: 24px; letter-spacing: 30px; }
#word { top: 48px; word-spacing: 30px; }
#wordplain { top: 72px; }
#em { top: 96px; font-size: 20px; letter-spacing: 1em; }
#emplain { top: 120px; font-size: 20px; }
#wrap { top: 150px; width: 100px; letter-spacing: 10px; }
#nested { top: 190px; letter-spacing: 5px; }
#inline { top: 214px; }
#tightrow { display: flex; position: absolute; left: 10px; top: 288px; }
#tight { letter-spacing: -3px; }
#zero { top: 240px; font-size: 0; letter-spacing: 10px; background: red; color: transparent; }
#zeroword { top: 264px; font-size: 0; word-spacing: 10px; background: red; color: transparent; }
</style></head><body>
<div id="plain">AB</div>
<div id="letter">AB</div>
<div id="word">A B</div>
<div id="wordplain">A B</div>
<div id="em">AB</div>
<div id="emplain">AB</div>
<div id="wrap">AAA AAA</div>
<div id="nested"><span id="inner">AB</span></div>
<div id="inline">AB</div>
<div id="tightrow"><span id="tight">AAA AAA</span></div>
<div id="zero">abc</div>
<div id="zeroword">a b</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const letter = document.getElementById("letter")!;
console.log("letter=" + getComputedStyle(letter).letterSpacing);
const plain = document.getElementById("plain")!;
console.log("plain=" + getComputedStyle(plain).letterSpacing + " word=" + getComputedStyle(plain).wordSpacing);
const word = document.getElementById("word")!;
console.log("word=" + getComputedStyle(word).wordSpacing);
const em = document.getElementById("em")!;
console.log("em=" + getComputedStyle(em).letterSpacing);
const inner = document.getElementById("inner")!;
console.log("inherited=" + getComputedStyle(inner).letterSpacing);
const inline = document.getElementById("inline")!;
inline.style.letterSpacing = "-2px";
console.log("inline=" + getComputedStyle(inline).letterSpacing);
inline.style.removeProperty("letter-spacing");
console.log("removed=" + getComputedStyle(inline).letterSpacing);
`;

const EXPECTED_LOG: [string, string][] = [
  ["letter-spacing serializes in px", "letter=30px"],
  ["the initial spacing is normal", "plain=normal word=normal"],
  ["word-spacing serializes in px", "word=30px"],
  ["an em spacing is computed in px", "em=20px"],
  ["letter-spacing inherits", "inherited=5px"],
  ["an inline letter-spacing applies", "inline=-2px"],
  ["removing it restores normal", "removed=normal"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-text-spacing-"));
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

/** The rightmost CSS x with ink on the line band y0..y1, or -1 when the band is blank. */
function lastInkX(y0: number, y1: number): number {
  for (let x = 320 * 2 - 1; x >= 0; x--) {
    for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 160 && img.rgba[o + 1] < 160 && img.rgba[o + 2] < 160) return x / 2;
    }
  }
  return -1;
}

/** The rightmost CSS x of a red box on the line band y0..y1, or -1 when the band has none. The
 *  text is transparent, so what is measured is the box the line's width gave it. */
function lastRedX(y0: number, y1: number): number {
  for (let x = 320 * 2 - 1; x >= 0; x--) {
    for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] > 200 && img.rgba[o + 1] < 100 && img.rgba[o + 2] < 100) return x / 2;
    }
  }
  return -1;
}

const plainEnd = lastInkX(0, 20);
const letterEnd = lastInkX(24, 44);
const wordEnd = lastInkX(48, 68);
const wordPlainEnd = lastInkX(72, 92);

check("plain text is drawn", plainEnd > 0, `rightmost ink at ${plainEnd}`);
// "AB" with 30px letter-spacing: the B starts 30px further right, and the run gets a trailing
// 30px as well, so its ink ends about 30px past the plain run's.
check("letter-spacing widens the run", Math.abs(letterEnd - plainEnd - 30) <= 2,
  `spaced ${letterEnd}, plain ${plainEnd}`);
// The space is what word-spacing widens, so a two-letter run ends 30px further right.
check("word-spacing widens the space", Math.abs(wordEnd - wordPlainEnd - 30) <= 2,
  `spaced ${wordEnd}, plain ${wordPlainEnd}`);
// 1em at a 20px font is 20px: the spaced run ends 20px past the plain one at the same size.
const emEnd = lastInkX(96, 116);
const emPlainEnd = lastInkX(120, 140);
check("an em spacing uses the font size", Math.abs(emEnd - emPlainEnd - 20) <= 2,
  `spaced ${emEnd}, plain ${emPlainEnd}`);

// #wrap is 100px wide with 10px letter-spacing: "AAA" measures 53.4px, and "AAA AAA" is 124.6px
// with its space, so the second word wraps to a second line.
const line1 = lastInkX(150, 166);
const line2 = lastInkX(166, 182);
check("a spaced run wraps where its measured width runs out", line1 > 0 && line2 > 0,
  `first line ends at ${line1}, second at ${line2}`);

// At a zero font size the glyphs have no advance of their own, so the box's width is only the
// spacing: "abc" with 10px letter-spacing is 30px, "a b" with 10px word-spacing is 10px. A
// clamped host font would have widened both by its glyphs.
const zeroEnd = lastRedX(240, 260);
const zeroWordEnd = lastRedX(264, 284);
check("at a zero font size letter-spacing alone widens the box", Math.abs(zeroEnd - 39.5) <= 1,
  `box ends at ${zeroEnd}, expected 39.5`);
check("at a zero font size word-spacing alone widens the box", Math.abs(zeroWordEnd - 19.5) <= 1,
  `box ends at ${zeroWordEnd}, expected 19.5`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

// A flex item's base size is its max-content width, and the run measures that wide with its
// tracking: the last word has to stay on the line. A trailing letter-spacing only hangs past the
// line's end when it is positive; a negative one takes room away and must still fit.
const tightFirst = lastInkX(288, 301);
const tightSecond = lastInkX(301, 318);
check("negative letter-spacing fits inside the max-content width", tightFirst > 0 && tightSecond === -1,
  `first line ends ${tightFirst}, second ${tightSecond}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
