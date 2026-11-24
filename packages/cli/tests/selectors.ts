// Regression tests for the selector forms that need the tree or an element's attributes:
// sibling combinators (`+`, `~`), attribute selectors and :not()/:is(). Each element in the
// test page gets a background color from one of the rules below, and one build checks them all.
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
<html><head><meta name="native-window" content="width=200, height=320"><style>
body { margin: 0; }
div { height: 20px; background: #000000; }
#a + div { background: #ff0000; }
#c + div[data-x="on"] { background: #00ff00; }
#e ~ #f { background: #0000ff; }
#g:not(.skip) { background: #ffff00; }
:is(#h, .two) { background: #ff00ff; }
#i { background: #000000; }
#j:not(.other) { background: #008888; }
#j:not(.skip) { background: #ff8800; }
[data-list~="b"] { border-top: 4px solid #0000ff; }
/* Combinators inside :where() and :is(): the argument names ancestors of the subject. */
section { background: #ffffff; }
.kid, .kid2 { display: block; height: 20px; }
:where(.wrap > :not(:last-child)) { background: #aa0000; }
:is(.wrap2 > .kid2) { background: #00aa00; }
</style></head><body>
<div id="a"></div>
<div id="b"></div>
<div id="c"></div>
<div id="d" data-x="on"></div>
<div id="e"></div>
<div id="f"></div>
<div id="g"></div>
<div id="h" class="one"></div>
<div id="i" class="two"></div>
<div id="j" class="skip"></div>
<div id="k" data-list="a b c"></div>
<section class="wrap"><span class="kid"></span><span class="kid"></span><span class="kid"></span></section>
<section class="wrap2"><span class="kid2"></span></section>
</body></html>`;

// Expected background of each div, in document order.
const EXPECTED: [string, string][] = [
  ["a: base rule", "0,0,0"],
  ["b: #a + div (adjacent sibling)", "255,0,0"],
  ["c: the adjacent rule only matches d", "0,0,0"],
  ["d: #c + div[data-x=on] (adjacent sibling + attribute)", "0,255,0"],
  ["e: base rule", "0,0,0"],
  ["f: #e ~ #f (general sibling)", "0,0,255"],
  ["g: #g:not(.skip)", "255,255,0"],
  ["h: :is(#h, .two)", "255,0,255"],
  ["i: #i wins the cascade over :is()", "0,0,0"],
  ["j: :not(.other) applies, :not(.skip) doesn't", "0,136,136"],
  ["k: [data-list~=b] leaves the background black", "0,0,0"],
];

function buildAndShoot(html: string): Image {
  const dir = mkdtempSync(join(tmpdir(), "native-selectors-"));
  writeFileSync(join(dir, "index.html"), html);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return decodePng(png);
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const img = buildAndShoot(PAGE);
const colorAt = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
EXPECTED.forEach(([name, want], i) => {
  const got = colorAt(100, 40 * i + 20);
  check(name, got === want, `got ${got}, want ${want}`);
});

// The border from [data-list~="b"] must sit on top of #k, in place of the first half of it.
check("[data-list~=b] draws the border", colorAt(100, 40 * 10 + 4) === "0,0,255",
  `got ${colorAt(100, 40 * 10 + 4)}`);

// :where(.wrap > :not(:last-child)) names the children of .wrap, less the last one.
check(":where(.a > :not(:last-child)) matches the first child", colorAt(100, 460) === "170,0,0",
  `got ${colorAt(100, 460)}`);
check(":where(.a > :not(:last-child)) matches the second child", colorAt(100, 500) === "170,0,0",
  `got ${colorAt(100, 500)}`);
check(":where(.a > :not(:last-child)) leaves the last child alone", colorAt(100, 540) === "255,255,255",
  `got ${colorAt(100, 540)}`);
check(":is(.a > .b) matches the child", colorAt(100, 580) === "0,170,0",
  `got ${colorAt(100, 580)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
