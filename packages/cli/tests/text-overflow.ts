// text-overflow: ellipsis puts an ellipsis where a clipped line runs past the content edge, in
// place of the glyph it cut off; without it the line is simply clipped.
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

const LONG = "WWWWWWWWWWWWWWWWWWWWWWW";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=200"><style>
body { margin: 0; font: 13px monospace; }
.line { position: absolute; left: 10px; top: 0; width: 100px; overflow: hidden; white-space: nowrap; }
#ell { top: 0; text-overflow: ellipsis; }
#clip { top: 20px; }
#short { top: 40px; text-overflow: ellipsis; }
#visible { top: 60px; overflow: visible; text-overflow: ellipsis; }
#toggled { top: 80px; }
#flexcol { position: absolute; left: 180px; top: 0; width: 100px; display: flex; flex-direction: column; }
#dsnip { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
</style></head><body>
<div class="line" id="ell">${LONG}</div>
<div class="line" id="clip">${LONG}</div>
<div class="line" id="short">WWW</div>
<div class="line" id="visible">${LONG}</div>
<div class="line" id="toggled">${LONG}</div>
<div id="flexcol"><div id="dyn"></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const ell = document.getElementById("ell")!;
console.log("ellipsis=" + getComputedStyle(ell).textOverflow);
const clip = document.getElementById("clip")!;
console.log("plain=" + getComputedStyle(clip).textOverflow);
const toggled = document.getElementById("toggled")!;
toggled.style.textOverflow = "ellipsis";
console.log("inline=" + getComputedStyle(toggled).textOverflow);
toggled.style.removeProperty("text-overflow");
console.log("removed=" + getComputedStyle(toggled).textOverflow);
// The same line again, but as inline content a script inserts into a flex column child: the
// text-overflow rule comes from the CSS, the text from innerHTML.
const dyn = document.getElementById("dyn")!;
dyn.innerHTML = '<div id="dsnip">' + ${JSON.stringify(LONG)} + '</div>';
window.addEventListener("load", () => {
  const s = document.getElementById("dsnip")!;
  const r = s.getBoundingClientRect();
  console.log("dyn=" + JSON.stringify([r.left, r.top, r.width, r.height, s.scrollWidth]));
});
`;

const EXPECTED_LOG: [string, string][] = [
  ["text-overflow serializes its keyword", "ellipsis=ellipsis"],
  ["the initial text-overflow is clip", "plain=clip"],
  ["an inline text-overflow applies", "inline=ellipsis"],
  ["removing it restores clip", "removed=clip"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-text-overflow-"));
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

// 13px monospace in a box from x=10 to x=110, so each glyph is under 8px wide and the content
// edge is at 110. The ellipsis line's last glyph is cut and an ellipsis drawn in its place: the
// dots sit at the baseline and stop short of the edge.
check("the elided line stops short of the content edge", !inkIn(106, 109.5, 2, 18));
check("the clipped line runs to the content edge", inkIn(106, 109.5, 22, 38));
check("an ellipsis sits at the baseline where the glyph was cut", inkIn(99, 106, 9.5, 15) && !inkIn(99, 106, 2, 9),
  "expected dots at the baseline and no glyph body above them");
check("the clipped line keeps the glyph body there", inkIn(99, 106, 22, 30));
// A line that fits is left alone.
check("a line that fits gets no ellipsis", inkIn(10, 40, 42, 58) && !inkIn(60, 130, 42, 58));
// With overflow: visible nothing is clipped, so no ellipsis is drawn and the line runs on.
check("overflow: visible draws the whole line and no ellipsis", inkIn(112, 130, 62, 78));

// The line a script inserts through innerHTML, inside a flex column child of a fixed-width
// parent: it is the column's width, at the column's left edge, one line tall, and its scroll
// width still covers the whole text (Chrome: a 100x15 box at (180, 0) with scrollWidth 180).
// Its ellipsis sits where the text at the content edge was cut.
const dynLine = out.split("\n").find((l) => l.startsWith("dyn="));
const dyn: number[] = dynLine === undefined ? [NaN, NaN, NaN, NaN, NaN] : JSON.parse(dynLine.slice(4));
check("an inserted line fills the flex column", Math.abs(dyn[2] - 100) <= 0.5, `width ${dyn[2]}`);
check("at the column's left edge", Math.abs(dyn[0] - 180) <= 0.5 && Math.abs(dyn[1]) <= 0.5,
  `at (${dyn[0]}, ${dyn[1]})`);
check("one line tall", dyn[3] > 14 && dyn[3] < 17, `height ${dyn[3]}`);
check("its scroll width still covers the whole text", dyn[4] > dyn[2] + 50, `scrollWidth ${dyn[4]}`);
// The dots sit on the baseline (Chrome's are at y 10..11 here), so the "no glyph body above
// them" band stops short of y=10: the static line above is checked the same way.
check("an inserted line ends in an ellipsis at the content edge",
  !inkIn(276, 279.5, 2, 18) && inkIn(269, 275, 11, 13.5) && !inkIn(269, 276, 2, 9.5),
  "expected dots at the baseline and no glyph above them or past them");

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
