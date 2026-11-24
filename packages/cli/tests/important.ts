// Regression tests for "!important": an important declaration outranks every normal one
// regardless of specificity or source order, and importance reverses the origin order (an
// important inline style beats an important author rule). Each div in the test page gets its
// background from one of the rules below, and one build checks them all.
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

// Each div is 20 CSS px tall and the snapshot is 2 device px per CSS px, so div i covers
// device rows [40i, 40i + 40).
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; }
div { height: 20px; background: #000000; }
div.imp1 { background: #ff0000 !important; }
#one { background: #00ff00; }
.imp2 { background: #0000ff !important; }
.imp3 { background: #00ff00 !important; }
.imp4 { background: #ff8800 ! important; }
.imp5 { background: #008888 !IMPORTANT; }
.imp6 { background: #00ffff; color: #000000; }
.imp6 { background: #ff00ff !important; }
#seven.imp7 { background: #ffff00 !important; }
.imp7 { background: #0000ff !important; }
</style></head><body>
<div class="imp1" id="one"></div>
<div class="imp2" style="background: #ff0000"></div>
<div class="imp3" style="background: #ff0000 !important"></div>
<div class="imp4"></div>
<div class="imp5"></div>
<div class="imp6"></div>
<div class="imp7" id="seven"></div>
</body></html>`;

// Expected background of each div, in document order.
const EXPECTED: [string, string][] = [
  ["1: div.imp1 important beats the later #one", "255,0,0"],
  ["2: important author rule beats a normal inline style", "0,0,255"],
  ["3: important inline style beats an important author rule", "255,0,0"],
  ["4: \"! important\" with a space", "255,136,0"],
  ["5: \"!IMPORTANT\" in upper case", "0,136,136"],
  ["6: the important declaration of a rule wins over its own normal one", "255,0,255"],
  ["7: among important declarations specificity still decides", "255,255,0"],
];

function build(html: string): { dir: string; exe: string; log: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-important-"));
  writeFileSync(join(dir, "index.html"), html);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  return { dir, exe, log: `${b.stdout}${b.stderr}` };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { dir, exe, log } = build(PAGE);
// The build used to report that "!important" was ignored; it is honoured now.
check("no \"!important is ignored\" note", !/!important is ignored/i.test(log));

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const colorAt = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
EXPECTED.forEach(([name, want], i) => {
  const got = colorAt(100, 40 * i + 20);
  check(name, got === want, `got ${got}, want ${want}`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
