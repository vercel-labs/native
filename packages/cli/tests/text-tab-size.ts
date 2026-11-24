// tab-size: a preserved tab advances to the next tab stop, which is tab-size spaces wide (8 by
// default), and the column count starts again after each line break.
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

// Each case is a tabbed run next to a run of the same text with the tab spelled out in spaces:
// the two must end at the same x, since spaces before the last glyph carry no ink.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=280"><style>
body { margin: 0; font: 13px monospace; }
div { position: absolute; left: 10px; white-space: pre; }
#tab8 { top: 0; }
#ref8 { top: 20px; }
#tab4 { top: 40px; tab-size: 4; }
#ref4 { top: 60px; }
#tab0 { top: 80px; tab-size: 0; }
#ref0 { top: 100px; }
#two { top: 120px; tab-size: 4; }
#ref8b { top: 140px; }
#reset { top: 160px; tab-size: 4; }
#prewrap { top: 200px; tab-size: 4; white-space: pre-wrap; }
</style></head><body>
<div id="tab8">AB\tC</div>
<div id="ref8">AB      C</div>
<div id="tab4">AB\tC</div>
<div id="ref4">AB  C</div>
<div id="tab0">AB\tC</div>
<div id="ref0">ABC</div>
<div id="two">AB\t\tC</div>
<div id="ref8b">AB      C</div>
<div id="reset">A
AB\tC</div>
<div id="prewrap">AB\tC</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const tab = document.getElementById("tab4")!;
console.log("tab=" + getComputedStyle(tab).tabSize);
const plain = document.getElementById("ref4")!;
console.log("plain=" + getComputedStyle(plain).tabSize);
const zero = document.getElementById("tab0")!;
console.log("zero=" + getComputedStyle(zero).tabSize);
const inline = document.getElementById("ref0")!;
inline.style.tabSize = "3";
console.log("inline=" + getComputedStyle(inline).tabSize);
inline.style.removeProperty("tab-size");
console.log("removed=" + getComputedStyle(inline).tabSize);
`;

const EXPECTED_LOG: [string, string][] = [
  ["tab-size serializes as a number", "tab=4"],
  ["the initial tab-size is 8", "plain=8"],
  ["a zero tab-size serializes", "zero=0"],
  ["an inline tab-size applies", "inline=3"],
  ["removing it restores 8", "removed=8"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-tab-size-"));
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

function endsLike(name: string, y0: number, refY0: number): void {
  const got = lastInkX(y0, y0 + 16);
  const want = lastInkX(refY0, refY0 + 16);
  check(name, got > 0 && Math.abs(got - want) <= 1, `end ${got}, want ${want}`);
}

// "AB\tC" with the default tab stop puts C at column 8, six spaces after AB; with tab-size: 4
// it lands at column 4; with
// tab-size: 0 the tab is zero-width, so C follows AB directly.
endsLike("a default tab advances to column 8", 0, 20);
endsLike("tab-size 4 advances to column 4", 40, 60);
endsLike("tab-size 0 makes the tab zero-width", 80, 100);
// "AB\t\tC" is not "AB  C": the second tab continues from column 4 to column 8.
endsLike("consecutive tabs each advance to the next stop", 120, 140);
// A line break starts the column count over, so the second line's tab is as wide as a first
// line's would be.
{
  const got = lastInkX(174, 192);
  const want = lastInkX(60, 76);
  check("the column count resets at a line break", got > 0 && Math.abs(got - want) <= 1, `end ${got}, want ${want}`);
}
// pre-wrap preserves the tab and expands it the same way.
endsLike("pre-wrap expands a tab the same way", 200, 60);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
