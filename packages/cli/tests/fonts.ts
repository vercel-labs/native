// @font-face faces: a family may define several faces, each with its own weight range and style,
// and the host picks the face the text asks for. The text is measured through the DOM's boxes, so
// the check sees which file the face came from.
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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

// Four faces of Arial, the bold one covering the heavy half of the weight range, and Times New
// Roman in two styles. The files are the system's, copied next to the page so the build can read
// them; a machine without them skips the test.
const FONTS: Record<string, string> = {
  "regular.ttf": "/System/Library/Fonts/Supplemental/Arial.ttf",
  "bold.ttf": "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
  "roman.ttf": "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
  "italic.ttf": "/System/Library/Fonts/Supplemental/Times New Roman Italic.ttf",
  "narrow.ttf": "/System/Library/Fonts/Supplemental/Arial Narrow.ttf",
};

// Two faces share TestSans, one per half of the weight range. TestMixed's src list names a format
// that isn't there first, so the face comes from the second source. TestItalic has a face for
// each style.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; font-size: 20px; }
span { white-space: pre; }
@font-face {
  font-family: TestSans; font-weight: 100 500; font-display: swap;
  src: url("regular.ttf") format("truetype");
}
@font-face { font-family: TestSans; font-weight: 600 900; src: url("bold.ttf") format("truetype"); }
@font-face {
  font-family: TestMixed;
  src: url("missing.woff2") format("woff2"), url("roman.ttf") format("truetype");
}
@font-face { font-family: TestItalic; font-style: normal; src: url("roman.ttf"); }
@font-face { font-family: TestItalic; font-style: italic; src: url("italic.ttf"); }
@font-face { font-family: TestRange; unicode-range: U+0041-005A; src: url("roman.ttf"); }
@font-face { font-family: TestNarrowFile; src: url("narrow.ttf"); }
@font-face { font-family: TestLocal; src: local("Arial Narrow"); }
@font-face { font-family: TestLocalMissing; src: local("No Such Font 12345"), url("roman.ttf"); }
</style></head><body>
<span id="regular" style="font-family: TestSans; font-weight: 400">Hamburgefonstiv</span>
<span id="medium" style="font-family: TestSans; font-weight: 500">Hamburgefonstiv</span>
<span id="bold" style="font-family: TestSans; font-weight: 600">Hamburgefonstiv</span>
<span id="heavy" style="font-family: TestSans; font-weight: 900">Hamburgefonstiv</span>
<span id="mixed" style="font-family: TestMixed">Hamburgefonstiv</span>
<span id="upright" style="font-family: TestItalic">Hamburgefonstiv</span>
<span id="italic" style="font-family: TestItalic; font-style: italic">Hamburgefonstiv</span>
<span id="fakeItalic" style="font-family: TestSans; font-style: italic">Hamburgefonstiv</span>
<span id="range" style="font-family: TestRange">Hamburgefonstiv</span>
<span id="narrowFile" style="font-family: TestNarrowFile">Hamburgefonstiv</span>
<span id="local" style="font-family: TestLocal">Hamburgefonstiv</span>
<span id="localMissing" style="font-family: TestLocalMissing">Hamburgefonstiv</span>
<span id="named" style="font-family: Georgia">Hamburgefonstiv</span>
<span id="namedGeneric" style="font-family: serif">Hamburgefonstiv</span>
<span id="namedMono" style="font-family: Menlo">Hamburgefonstiv</span>
<span id="genericMono" style="font-family: monospace">Hamburgefonstiv</span>
<span id="namedOnce" style="font-family: Georgia">Hamburgefonstiv</span>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const byId = (id: string): HTMLElement => document.getElementById(id)!;
const width = (id: string): number => Math.round(byId(id).getBoundingClientRect().width * 100) / 100;
// The rects are laid out by the first frame, so the reads happen in a later one.
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    for (const id of ["regular", "medium", "bold", "heavy", "mixed", "upright", "italic", "fakeItalic", "range",
      "narrowFile", "local", "localMissing", "named", "namedGeneric", "namedMono", "genericMono",
      "namedOnce"]) {
      console.log(id + "=" + width(id));
    }
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

for (const [name, from] of Object.entries(FONTS)) {
  if (!existsSync(from)) {
    console.log(`ok   @font-face faces need the system fonts (${from} isn't here; skipped)`);
    console.log("\nall passed");
    process.exit(0);
  }
}

const dir = mkdtempSync(join(tmpdir(), "native-fonts-"));
for (const [name, from] of Object.entries(FONTS)) copyFileSync(from, join(dir, name));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

const widths: Record<string, number> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^(\w+)=([\d.]+)$/.exec(line.trim());
  if (m) widths[m[1]] = Number(m[2]);
}

check("a weight in the first range takes the regular face", widths.medium === widths.regular,
  `500 measures ${widths.medium}, 400 ${widths.regular}`);
check("a weight in the second range takes the bold face", widths.heavy === widths.bold,
  `900 measures ${widths.heavy}, 600 ${widths.bold}`);
check("the two files measure differently", widths.bold > widths.regular,
  `bold ${widths.bold}, regular ${widths.regular}`);
check("a src list falls back to its next source", widths.mixed === widths.upright,
  `mixed measures ${widths.mixed}, the second source ${widths.upright}`);
check("a unicode-range face keeps working", widths.range === widths.upright,
  `range measures ${widths.range}, the same file upright ${widths.upright}`);
check("the narrow file measures narrower than the regular one", widths.narrowFile < widths.regular,
  `narrow ${widths.narrowFile}, regular ${widths.regular}`);
check("a local() source takes the font the system has", widths.local === widths.narrowFile,
  `local measures ${widths.local}, the same font as a file ${widths.narrowFile}`);
// A named family is the system's face of that name, not a category: Georgia measures differently
// from the serif default, and Menlo is the same face monospace resolves to on this platform.
check("a named installed family takes its own face", widths.named !== widths.namedGeneric,
  `georgia ${widths.named}, serif ${widths.namedGeneric}`);
check("naming the same family twice measures the same", widths.named === widths.namedOnce,
  `${widths.named} vs ${widths.namedOnce}`);
check("Menlo is the face monospace resolves to", widths.namedMono === widths.genericMono,
  `menlo ${widths.namedMono}, monospace ${widths.genericMono}`);
check("a local() font the system lacks falls back to the next source", widths.localMissing === widths.upright,
  `local(), url() measures ${widths.localMissing}, the second source ${widths.upright}`);
check("an italic face is a face of its own", widths.italic !== widths.upright,
  `italic ${widths.italic}, upright ${widths.upright}`);
// TestSans has no italic face: the regular one is used, and the host slants it, which leaves the
// advances alone.
check("a family with one face uses it for any style", widths.fakeItalic === widths.regular,
  `slanted ${widths.fakeItalic}, upright ${widths.regular}`);

// Ink on the first line, drawn in the regular face.
function inkInBand(y0: number, y1: number): number {
  let n = 0;
  for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 160 && img.rgba[o + 1] < 160 && img.rgba[o + 2] < 160) n++;
    }
  }
  return n;
}
check("the face's glyphs are drawn", inkInBand(0, 24) > 50, `${inkInBand(0, 24)} dark pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
