// The PNG reader the Windows icon is built from. The icon is almost always a picture wider than
// one pixel, so the strides matter, and a PNG can name one transparent colour instead of carrying
// an alpha channel (a `tRNS` chunk on the grey and RGB types).
//   npm test

import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { deflateSync } from "node:zlib";
import { readPng } from "../compiler/png.ts";
import { chunk } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-png-decode-"));
const SIG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

/** A PNG from raw unfiltered rows: colour type, bit depth, and an optional tRNS chunk. */
function png(width: number, height: number, colorType: number, bitDepth: number, rows: Buffer[], trns?: Buffer): string {
  const raw = Buffer.concat(rows.map((row) => Buffer.concat([Buffer.from([0]), row])));
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = bitDepth;
  ihdr[9] = colorType;
  const parts = [SIG, chunk("IHDR", ihdr)];
  if (trns !== undefined) parts.push(chunk("tRNS", trns));
  parts.push(chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0)));
  const file = join(dir, `${width}x${height}-${colorType}-${bitDepth}-${Math.random().toString(36).slice(2)}.png`);
  writeFileSync(file, Buffer.concat(parts));
  return file;
}

/** A decoded picture's pixels, row by row. */
function pixels(file: string): number[] {
  const img = readPng(file);
  if (img === null) throw new Error(`${file} did not decode`);
  return Array.from(img.rgba);
}

// Three pixels wide: the second pixel's channels must land on the second pixel, not inside the
// first.
check("RGBA pixels keep their stride",
  pixels(png(3, 1, 6, 8, [Buffer.from([255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0])])).join() ===
    "255,0,0,255,0,255,0,128,0,0,255,0");
check("RGB pixels keep their stride",
  pixels(png(3, 1, 2, 8, [Buffer.from([255, 0, 0, 0, 255, 0, 0, 0, 255])])).join() ===
    "255,0,0,255,0,255,0,255,0,0,255,255");
check("grey+alpha pixels keep their stride",
  pixels(png(2, 1, 4, 8, [Buffer.from([10, 200, 50, 25])])).join() ===
    "10,10,10,200,50,50,50,25");

// A tRNS chunk names the transparent pixel for the types without an alpha channel.
check("a grey tRNS pixel is transparent",
  pixels(png(2, 1, 0, 8, [Buffer.from([0, 255])], Buffer.from([0, 0]))).join() ===
    "0,0,0,0,255,255,255,255");
check("an RGB tRNS pixel is transparent",
  pixels(png(2, 1, 2, 8, [Buffer.from([255, 0, 0, 0, 255, 0])], Buffer.from([0, 255, 0, 0, 0, 0]))).join() ===
    "255,0,0,0,0,255,0,255");
check("a tRNS pixel that isn't there leaves the image opaque",
  pixels(png(1, 1, 2, 8, [Buffer.from([0, 0, 255])], Buffer.from([0, 255, 0, 0, 0, 0]))).join() ===
    "0,0,255,255");

// A palette's entries and its tRNS alpha.
{
  const plte = Buffer.from([255, 0, 0, 0, 255, 0, 0, 0, 255]);
  const file = join(dir, "palette.png");
  const raw = Buffer.from([0, 0, 1, 2]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(3, 0);
  ihdr.writeUInt32BE(1, 4);
  ihdr[8] = 8;
  ihdr[9] = 3;
  writeFileSync(file, Buffer.concat([
    SIG, chunk("IHDR", ihdr), chunk("PLTE", plte), chunk("tRNS", Buffer.from([255, 128, 0])),
    chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0)),
  ]));
  check("palette entries and their alpha decode",
    pixels(file).join() === "255,0,0,255,0,255,0,128,0,0,255,0");
}

// A 16-bit sample keeps its high byte, which is what the icon uses.
check("16-bit samples use their high byte",
  pixels(png(1, 1, 2, 16, [Buffer.from([0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc])])).join() ===
    "18,86,154,255");

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
