// Regression tests for borders on an inline box broken by a block: the piece before the break
// keeps its left border and loses its right one, the piece after the break keeps its right border
// and loses its left one, and only the border-free sides are left open at the break.
//   npm test
//
// Each case builds a tiny page, renders a snapshot, and checks the painted border pixels.

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

function colorAt(img: Image, x: number, y: number): number[] {
  const o = (y * img.w + x) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

function isColor(img: Image, x: number, y: number, rgb: number[]): boolean {
  const c = colorAt(img, x, y);
  return c[0] === rgb[0] && c[1] === rgb[1] && c[2] === rgb[2];
}

/** Rows that contain the given color, with the columns it covers on that row. */
function colorRows(img: Image, rgb: number[]): { y: number; minX: number; maxX: number }[] {
  const rows: { y: number; minX: number; maxX: number }[] = [];
  for (let y = 0; y < img.h; y++) {
    let minX = -1;
    let maxX = -1;
    for (let x = 0; x < img.w; x++) {
      if (!isColor(img, x, y, rgb)) continue;
      if (minX < 0) minX = x;
      maxX = x;
    }
    if (minX >= 0) rows.push({ y, minX, maxX });
  }
  return rows;
}

/** Length of the run of `rgb` pixels starting at column `x` on row `y`, or 0. */
function runLength(img: Image, y: number, x: number, rgb: number[]): number {
  let n = 0;
  while (x + n < img.w && isColor(img, x + n, y, rgb)) n++;
  return n;
}

function buildAndShoot(name: string, html: string): Image {
  const dir = mkdtempSync(join(tmpdir(), `native-border-${name}-`));
  writeFileSync(join(dir, "index.html"), html);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build of ${name} failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render of ${name} failed\n${r.stderr}`);
  return decodePng(png);
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// The block in the middle of the span splits it in two. Both cases use the same geometry:
// line 1 holds the span's first piece ("a"), then a block, then the continuation piece ("b").
const PAGE = (hl: string, block: string) => `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; font-family: monospace; font-size: 16px; line-height: 3; color: #ff00ff; }
.hl { padding: 0 10px; ${hl} }
.blk { height: 20px; background: ${block}; }
</style></head><body><div><span class="hl">a<div class="blk"></div>b</span></div></body></html>`;

// Uniform border, the common case: the continuation piece must look like top-right-bottom.
{
  const green = [0, 255, 0];
  const block = [0, 0, 255];
  const img = buildAndShoot("uniform", PAGE("border: 2px solid #00ff00;", "#0000ff"));
  const blockRows = colorRows(img, block);
  check("uniform: the block paints", blockRows.length > 0);
  const blockBottom = blockRows.length > 0 ? blockRows[blockRows.length - 1].y : 0;
  let leftBorder = -1;
  let rightBorder = -1;
  for (const row of colorRows(img, green)) {
    if (row.y <= blockBottom) continue; // the first piece, above the block
    // A horizontal border bar starts at the box's left edge and runs its whole width; the left
    // border would instead be a short run at the same edge on rows that are otherwise interior.
    const atLeft = runLength(img, row.y, 0, green);
    if (atLeft > 0 && atLeft <= 8) leftBorder = row.y;
    if (row.minX >= 40) rightBorder = row.y;
  }
  check("uniform: continuation keeps its right border", rightBorder >= 0);
  check("uniform: continuation draws no left border", leftBorder < 0, `row ${leftBorder}`);
}

// Different colors per side so each edge can be identified: left red, right cyan.
{
  const red = [255, 0, 0];
  const cyan = [0, 255, 255];
  const yellow = [255, 255, 0];
  const img = buildAndShoot("sides",
    PAGE("border-top: 2px solid #00ff00; border-right: 2px solid #00ffff; border-bottom: 2px solid #0000ff; border-left: 2px solid #ff0000;",
      "#ffff00"));
  const blockRows = colorRows(img, yellow);
  check("sides: the block paints", blockRows.length > 0);
  const top = blockRows.length > 0 ? blockRows[0].y : 0;
  const bottom = blockRows.length > 0 ? blockRows[blockRows.length - 1].y : 0;
  const above = colorRows(img, red).some((r) => r.y < top);
  const redBelow = colorRows(img, red).filter((r) => r.y > bottom);
  const cyanBelow = colorRows(img, cyan).filter((r) => r.y > bottom);
  const cyanAbove = colorRows(img, cyan).filter((r) => r.y < top);
  check("sides: first piece keeps its left border", above);
  check("sides: first piece draws no right border", cyanAbove.length === 0, `rows ${cyanAbove.map((r) => r.y).join(",")}`);
  check("sides: continuation draws no left border", redBelow.length === 0, `rows ${redBelow.map((r) => r.y).join(",")}`);
  check("sides: continuation keeps its right border", cyanBelow.length > 0);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
