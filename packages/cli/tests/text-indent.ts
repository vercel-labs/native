// text-indent: the first line of a block starts further in (or hangs out), takes less room to
// wrap in, and the later lines start at the content edge.
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
<html><head><meta name="native-window" content="width=320, height=280"><style>
body { margin: 0; font: 13px monospace; }
div { position: absolute; left: 10px; width: 100px; }
#plain { top: 0; }
#indent { top: 40px; text-indent: 40px; }
#pct { top: 100px; text-indent: 25%; }
#neg { top: 160px; text-indent: -10px; }
#inline { top: 200px; }
#spans { top: 230px; text-indent: 30px; }
</style></head><body>
<div id="plain">AAAA AAAA</div>
<div id="indent">AAAA AAAA</div>
<div id="pct">AAAA AAAA</div>
<div id="neg">AA</div>
<div id="inline">AA</div>
<div id="spans"><span>AA</span> AA</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const indent = document.getElementById("indent")!;
console.log("indent=" + getComputedStyle(indent).textIndent);
const plain = document.getElementById("plain")!;
console.log("plain=" + getComputedStyle(plain).textIndent);
const pct = document.getElementById("pct")!;
console.log("percent=" + getComputedStyle(pct).textIndent);
const neg = document.getElementById("neg")!;
console.log("negative=" + getComputedStyle(neg).textIndent);
const inline = document.getElementById("inline")!;
inline.style.textIndent = "12px";
console.log("inline=" + getComputedStyle(inline).textIndent);
inline.style.removeProperty("text-indent");
console.log("removed=" + getComputedStyle(inline).textIndent);
`;

const EXPECTED_LOG: [string, string][] = [
  ["text-indent serializes in px", "indent=40px"],
  ["the initial indent is zero", "plain=0px"],
  ["a percentage indent stays a percentage", "percent=25%"],
  ["a negative indent serializes", "negative=-10px"],
  ["an inline indent applies", "inline=12px"],
  ["removing it restores zero", "removed=0px"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-text-indent-"));
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

/** The leftmost CSS x with ink on the line band y0..y1, or -1 when the band is blank. */
function firstInkX(y0: number, y1: number): number {
  for (let x = 0; x < 320 * 2; x++) {
    for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 160 && img.rgba[o + 1] < 160 && img.rgba[o + 2] < 160) return x / 2;
    }
  }
  return -1;
}

// 13px monospace: each A is a little under 8px wide, so "AAAA AAAA" (about 70px) fits on one line
// in a 100px box until the indent takes room away.
const plainStart = firstInkX(0, 20);
check("plain text starts at the content edge", plainStart >= 10 && plainStart <= 11.5, `start ${plainStart}`);
// A 40px indent shifts the first line right by 40px and leaves 60px to wrap in: the second word
// goes to the next line, which starts back at the content edge.
const indentStart = firstInkX(44, 53);
const indentSecond = firstInkX(60, 69);
check("the first line is indented", Math.abs(indentStart - (plainStart + 40)) <= 1.5, `start ${indentStart}`);
check("the indented line wraps earlier", indentSecond >= 10 && indentSecond <= 11.5, `second line ${indentSecond}`);
// 25% of 100px is 25px.
check("a percentage indent is measured against the content width", Math.abs(firstInkX(100, 120) - (plainStart + 25)) <= 1.5,
  `start ${firstInkX(100, 120)}`);
// A negative indent hangs the first line out to the left of the content edge, and it is clipped by
// the window edge rather than by the box.
check("a negative indent hangs the first line out", firstInkX(160, 180) <= plainStart - 9, `start ${firstInkX(160, 180)}`);

// Inline content in a block gets the indent on its first line too.
check("an inline run's first line is indented", Math.abs(firstInkX(234, 243) - (plainStart + 30)) <= 1.5,
  `start ${firstInkX(234, 243)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
