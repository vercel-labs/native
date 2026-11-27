// Reading and writing a PNG. A Windows build makes the app's icon from the page's PNG, at the
// several sizes the shell asks for, so it needs the pixels; macOS hands the file to `sips` and
// Linux copies it as it is, and neither reads it here.

import { readFileSync } from "node:fs";
import { deflateSync, inflateSync } from "node:zlib";

/** A decoded picture: width and height in pixels, and RGBA bytes row by row. */
export interface Raster {
  width: number;
  height: number;
  rgba: Uint8Array;
}

const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** A chunk's CRC, as PNG defines it: the CRC-32 polynomial, reflected, from all ones. */
function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    c ^= bytes[i];
    for (let k = 0; k < 8; k++) c = (c & 1) !== 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
  }
  return (c ^ 0xffffffff) >>> 0;
}

/** A PNG chunk: its length, type, data and CRC. */
function chunk(type: string, data: Uint8Array): Buffer {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "ascii");
  out.set(data, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

/**
 * The picture a PNG file holds, as RGBA, or null when it isn't a PNG this build can read: an
 * interlaced one, a bit depth other than 8 or 16, or a colour type it doesn't handle.
 */
export function readPng(file: string): Raster | null {
  let b: Buffer;
  try {
    b = readFileSync(file);
  } catch {
    return null;
  }
  if (b.length < 8 || SIGNATURE.some((v, i) => b[i] !== v)) return null;
  let at = 8;
  let width = 0, height = 0, depth = 0, color = -1, interlace = 0;
  let palette: Uint8Array | null = null;
  let alpha: Uint8Array | null = null;
  const idat: Buffer[] = [];
  while (at + 12 <= b.length) {
    const len = b.readUInt32BE(at);
    const type = b.toString("ascii", at + 4, at + 8);
    const data = b.subarray(at + 8, at + 8 + len);
    if (type === "IHDR") {
      if (data.length < 13) return null;
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      depth = data[8];
      color = data[9];
      interlace = data[12];
    } else if (type === "PLTE") {
      palette = new Uint8Array(data);
    } else if (type === "tRNS") {
      alpha = new Uint8Array(data);
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") {
      break;
    }
    at += 12 + len;
  }
  if (width === 0 || height === 0 || interlace !== 0 || (depth !== 8 && depth !== 16)) return null;
  const bytes = depth === 16 ? 2 : 1;
  const channels = color === 0 ? 1 : color === 2 ? 3 : color === 3 ? 1 : color === 4 ? 2 : color === 6 ? 4 : 0;
  if (channels === 0 || (color === 3 && palette === null)) return null;
  let raw: Buffer;
  try {
    raw = inflateSync(Buffer.concat(idat));
  } catch {
    return null;
  }
  const stride = width * channels * bytes;
  if (raw.length < height * (stride + 1)) return null;
  const pixels = new Uint8Array(stride * height);
  const bpp = channels * bytes;
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const row = y * stride, prev = row - stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? pixels[row + x - bpp] : 0;
      const up = y > 0 ? pixels[prev + x] : 0;
      const c = y > 0 && x >= bpp ? pixels[prev + x - bpp] : 0;
      let v = line[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += up;
      else if (filter === 3) v += (a + up) >> 1;
      else if (filter === 4) {
        const p = a + up - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - up), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c;
      }
      pixels[row + x] = v & 255;
    }
  }
  const out = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    const row = y * stride;
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      if (color === 3) {
        const index = pixels[row + x];
        out[o] = palette![index * 3];
        out[o + 1] = palette![index * 3 + 1];
        out[o + 2] = palette![index * 3 + 2];
        out[o + 3] = alpha !== null && index < alpha.length ? alpha[index] : 255;
      } else if (color === 0) {
        const g = pixels[row + x * bytes];
        out[o] = out[o + 1] = out[o + 2] = g;
        out[o + 3] = 255;
      } else if (color === 4) {
        const g = pixels[row + x * bytes];
        out[o] = out[o + 1] = out[o + 2] = g;
        out[o + 3] = pixels[row + x * bytes + bytes];
      } else if (color === 2) {
        out[o] = pixels[row + x * bytes];
        out[o + 1] = pixels[row + x * bytes + bytes];
        out[o + 2] = pixels[row + x * bytes + 2 * bytes];
        out[o + 3] = 255;
      } else {
        out[o] = pixels[row + x * bytes];
        out[o + 1] = pixels[row + x * bytes + bytes];
        out[o + 2] = pixels[row + x * bytes + 2 * bytes];
        out[o + 3] = pixels[row + x * bytes + 3 * bytes];
      }
    }
  }
  return { width, height, rgba: out };
}

/** The picture at another size, sampled bilinearly. */
export function resizePng(src: Raster, size: number): Raster {
  const out = new Uint8Array(size * size * 4);
  for (let y = 0; y < size; y++) {
    const sy = Math.min(src.height - 1, Math.max(0, ((y + 0.5) * src.height) / size - 0.5));
    const y0 = Math.floor(sy), y1 = Math.min(src.height - 1, y0 + 1), fy = sy - y0;
    for (let x = 0; x < size; x++) {
      const sx = Math.min(src.width - 1, Math.max(0, ((x + 0.5) * src.width) / size - 0.5));
      const x0 = Math.floor(sx), x1 = Math.min(src.width - 1, x0 + 1), fx = sx - x0;
      const o = (y * size + x) * 4;
      for (let k = 0; k < 4; k++) {
        const p00 = src.rgba[(y0 * src.width + x0) * 4 + k];
        const p10 = src.rgba[(y0 * src.width + x1) * 4 + k];
        const p01 = src.rgba[(y1 * src.width + x0) * 4 + k];
        const p11 = src.rgba[(y1 * src.width + x1) * 4 + k];
        out[o + k] = Math.round(p00 * (1 - fx) * (1 - fy) + p10 * fx * (1 - fy) +
          p01 * (1 - fx) * fy + p11 * fx * fy);
      }
    }
  }
  return { width: size, height: size, rgba: out };
}

/** A PNG holding the picture, 8-bit RGBA with no row filters. */
export function writePng(img: Raster): Buffer {
  const stride = img.width * 4;
  const raw = Buffer.alloc((stride + 1) * img.height);
  for (let y = 0; y < img.height; y++) {
    raw[y * (stride + 1)] = 0;
    raw.set(img.rgba.subarray(y * stride, (y + 1) * stride), y * (stride + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(img.width, 0);
  ihdr.writeUInt32BE(img.height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from(SIGNATURE),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", new Uint8Array(0)),
  ]);
}
