// Regression tests for inline vertical metrics: vertical-align (keywords, lengths, percentages)
// and line-height: normal taken from the font's own metrics. The page's script sets styles and
// the build checks the pixels they paint, plus the strings the API hands back.
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
<html><head><meta name="native-window" content="width=200, height=420"><style>
body { margin: 0; font-family: monospace; font-size: 16px; }
.t { position: absolute; left: 0; }
.box { display: inline-block; width: 10px; height: 10px; }
.red { background: #ff0000; }
.green { background: #00ff00; }
.blue { background: #0000ff; }
.wide { position: absolute; left: 0; width: 200px; background: #000000; }
.white { position: absolute; left: 0; width: 200px; background: #ffffff; }
#after { height: 20px; background: #ff0000; }
</style></head><body>
<div class="t" style="top: 0px"><span class="box red"></span><span class="box green" style="vertical-align: 20px"></span></div>
<div class="t" style="top: 60px"><span class="box green" style="vertical-align: top"></span><span class="box blue" style="vertical-align: bottom"></span></div>
<div class="wide" id="lh" style="top: 120px">
a<br>b<br>c<br>d<br>e<br>f<br>g<br>h<br>i<br>j<br><div id="after"></div>
</div>
<div class="white" style="top: 360px; height: 40px">H<sup id="sup">2</sup>O H<sub id="sub">2</sub>O</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const byId = (id: string): HTMLElement => document.getElementById(id) as HTMLElement;

// A length moves the baseline up by that much.
const raised = document.querySelectorAll(".green")[0] as HTMLElement;
console.log("raised=" + getComputedStyle(raised).verticalAlign);

// The keywords are serialized as written.
const sup = document.createElement("span");
sup.setAttribute("style", "vertical-align: super");
console.log("keyword=" + sup.style.verticalAlign);
console.log("cssText=" + sup.style.cssText);

// A percentage of the element's own line height, and a length in em.
const pct = document.createElement("span");
pct.style.verticalAlign = "10%";
console.log("pct=" + getComputedStyle(pct).verticalAlign);
pct.style.verticalAlign = "2em";
console.log("em=" + getComputedStyle(pct).verticalAlign);

// line-height: normal is a keyword, and the UA default.
console.log("lh=" + getComputedStyle(document.body).lineHeight);
const el = document.createElement("span");
el.style.lineHeight = "normal";
console.log("lh set=" + getComputedStyle(el).lineHeight);

// The UA sheet raises <sup> and lowers <sub>, both in a smaller font size.
const uaSup = byId("sup");
const uaSub = byId("sub");
console.log("ua sup=" + getComputedStyle(uaSup).verticalAlign + " " + getComputedStyle(uaSup).fontSize);
console.log("ua sub=" + getComputedStyle(uaSub).verticalAlign + " " + getComputedStyle(uaSub).fontSize);

// larger is the sibling of smaller.
const bigger = document.createElement("span");
bigger.style.fontSize = "larger";
console.log("larger=" + getComputedStyle(bigger).fontSize);
`;

// A baseline-aligned 10x10 box with a sibling raised 20px: the raised box spans the top of the
// line box, the baseline one starts 20px lower.
const EXPECTED: [string, number, number, string][] = [
  ["raised box at the top of the line", 15, 5, "0,255,0"],
  ["baseline box 20px lower", 5, 25, "255,0,0"],
  // A top-aligned box spans the top of the 18px line box; a bottom-aligned one ends at its
  // bottom. Both are 10px tall, so they overlap between 8px and 10px.
  ["top-aligned box at the line top", 5, 62, "0,255,0"],
  ["bottom-aligned box at the line bottom", 15, 76, "0,0,255"],
  // Ten lines at the font's own line height (18px for the 16px monospace font, its ascent and
  // descent each rounded to a whole device pixel) put #after at 300px, not the 192px a 1.2em
  // line height would give.
  ["line-height: normal puts the next box at 300px", 190, 310, "255,0,0"],
  ["line-height: normal leaves the line above black", 190, 298, "0,0,0"],
];

const EXPECTED_LOG: [string, string][] = [
  ["a length serializes as a length", "raised=20px"],
  ["a keyword from a style attribute", "keyword=super"],
  ["the declaration block keeps the keyword", "cssText=vertical-align: super;"],
  ["a percentage stays a percentage", "pct=10%"],
  ["em resolves against the font size", "em=32px"],
  ["the UA default line height is normal", "lh=normal"],
  ["line-height: normal round-trips", "lh set=normal"],
  ["the UA sheet raises sup and shrinks it", "ua sup=super 13.333px"],
  ["the UA sheet lowers sub and shrinks it", "ua sub=sub 13.333px"],
  ["larger scales the parent's size up by 1.2", "larger=19.2px"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-vertical-align-"));
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
const colorAt = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
for (const [name, x, y, want] of EXPECTED) {
  // The snapshot is 2 device px per CSS px.
  const got = colorAt(x * 2, y * 2);
  check(name, got === want, `got ${got}, want ${want}`);
}

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
