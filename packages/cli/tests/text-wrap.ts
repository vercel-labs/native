// overflow-wrap and word-break: a word too wide for a line breaks inside itself when the style
// allows it (`break-word`, `anywhere`, `break-all`), and not otherwise.
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

const WORD = "WWWWWWWWWWWWWWWW";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=240"><style>
body { margin: 0; font: 13px monospace; }
div { position: absolute; left: 10px; width: 100px; }
#normal { top: 0; }
#breakword { top: 20px; overflow-wrap: break-word; }
#anywhere { top: 60px; overflow-wrap: anywhere; }
#breakall { top: 100px; word-break: break-all; }
#control { top: 140px; }
#toggled { top: 180px; }
</style></head><body>
<div id="normal">${WORD}</div>
<div id="breakword">${WORD}</div>
<div id="anywhere">${WORD}</div>
<div id="breakall">AAAAA BBBBBBBBBBBBBB</div>
<div id="control">AAAAA BBBBBBBBBBBBBB</div>
<div id="toggled">${WORD}</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const bw = document.getElementById("breakword")!;
console.log("breakword=" + getComputedStyle(bw).overflowWrap);
const ba = document.getElementById("breakall")!;
console.log("breakall=" + getComputedStyle(ba).wordBreak);
const plain = document.getElementById("normal")!;
console.log("plain=" + getComputedStyle(plain).overflowWrap + "/" + getComputedStyle(plain).wordBreak);
const toggled = document.getElementById("toggled")!;
toggled.style.wordBreak = "break-all";
console.log("inline=" + getComputedStyle(toggled).wordBreak);
toggled.style.removeProperty("word-break");
console.log("removed=" + getComputedStyle(toggled).wordBreak);
`;

const EXPECTED_LOG: [string, string][] = [
  ["overflow-wrap serializes its keyword", "breakword=break-word"],
  ["word-break serializes its keyword", "breakall=break-all"],
  ["both initial values are normal", "plain=normal/normal"],
  ["an inline word-break applies", "inline=break-all"],
  ["removing it restores normal", "removed=normal"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-wrap-"));
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

function ink(x: number, y: number): boolean {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return img.rgba[o] < 160 && img.rgba[o + 1] < 160 && img.rgba[o + 2] < 160;
}

/** Whether any pixel in the CSS rect x0..x1, y0..y1 has ink. */
function inkIn(x0: number, x1: number, y0: number, y1: number): boolean {
  for (let x = x0; x <= x1; x += 0.5) for (let y = y0; y <= y1; y += 0.5) if (ink(x, y)) return true;
  return false;
}

/** The rightmost CSS x with ink in the band y0..y1, or -1 when the band is blank. */
function lastInkX(y0: number, y1: number): number {
  for (let x = 320 * 2 - 1; x >= 0; x--) {
    for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 160 && img.rgba[o + 1] < 160 && img.rgba[o + 2] < 160) return x / 2;
    }
  }
  return -1;
}

// The box runs from x=10 to x=110, and the word is about 125px wide, so it can't fit a line.
check("a word with overflow-wrap: normal runs past the box", inkIn(112, 140, 0, 16));
check("break-word breaks the word inside the box",
  !inkIn(111, 140, 20, 36) && inkIn(10, 100, 20, 36) && inkIn(10, 100, 36, 52), "expected two lines inside the box");
check("anywhere breaks the word inside the box", !inkIn(111, 140, 60, 76) && inkIn(10, 100, 76, 92));

// break-all fills the first line before breaking, where plain wrapping moves the whole second
// word down and lets it run past the box.
const breakallFirst = lastInkX(100, 116);
const controlFirst = lastInkX(140, 156);
check("break-all fills the line with part of the next word", breakallFirst > 60, `end ${breakallFirst}`);
check("plain wrapping moves the whole word down", controlFirst < 50, `end ${controlFirst}`);
check("break-all keeps every line inside the box", !inkIn(111, 140, 100, 132), "ink past the content edge");

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
