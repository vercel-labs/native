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
  // A tRNS chunk names one transparent colour for the grey and RGB types; the value is a 16-bit
  // sample per channel (an 8-bit image's value is its low byte). A 16-bit image's key is compared
  // at its full width: two samples that share a high byte are not the same colour. Palette alpha
  // is handled above.
  const transparentGray = color === 0 && alpha !== null && alpha.length >= 2
    ? (depth === 16 ? (alpha[0] << 8) | alpha[1] : alpha[1]) : -1;
  const transparentRgb = color === 2 && alpha !== null && alpha.length >= 6
    ? depth === 16
      ? [(alpha[0] << 8) | alpha[1], (alpha[2] << 8) | alpha[3], (alpha[4] << 8) | alpha[5]]
      : [alpha[1], alpha[3], alpha[5]]
    : null;
  const out = new Uint8Array(width * height * 4);
  const pixelBytes = channels * bytes;
  for (let y = 0; y < height; y++) {
    const row = y * stride;
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      const p = row + x * pixelBytes;
      if (color === 3) {
        const index = pixels[p];
        out[o] = palette![index * 3];
        out[o + 1] = palette![index * 3 + 1];
        out[o + 2] = palette![index * 3 + 2];
        out[o + 3] = alpha !== null && index < alpha.length ? alpha[index] : 255;
      } else if (color === 0) {
        const g = pixels[p];
        out[o] = out[o + 1] = out[o + 2] = g;
        const sample = depth === 16 ? (pixels[p] << 8) | pixels[p + 1] : g;
        out[o + 3] = sample === transparentGray ? 0 : 255;
      } else if (color === 4) {
        const g = pixels[p];
        out[o] = out[o + 1] = out[o + 2] = g;
        out[o + 3] = pixels[p + bytes];
      } else if (color === 2) {
        out[o] = pixels[p];
        out[o + 1] = pixels[p + bytes];
        out[o + 2] = pixels[p + 2 * bytes];
        if (transparentRgb === null) {
          out[o + 3] = 255;
        } else if (depth === 16) {
          const r = (pixels[p] << 8) | pixels[p + 1];
          const g = (pixels[p + bytes] << 8) | pixels[p + bytes + 1];
          const b = (pixels[p + 2 * bytes] << 8) | pixels[p + 2 * bytes + 1];
          out[o + 3] = r === transparentRgb[0] && g === transparentRgb[1] &&
            b === transparentRgb[2] ? 0 : 255;
        } else {
          out[o + 3] = out[o] === transparentRgb[0] && out[o + 1] === transparentRgb[1] &&
            out[o + 2] === transparentRgb[2] ? 0 : 255;
        }
      } else {
        out[o] = pixels[p];
        out[o + 1] = pixels[p + bytes];
        out[o + 2] = pixels[p + 2 * bytes];
        out[o + 3] = pixels[p + 3 * bytes];
      }
    }
  }
  return { width, height, rgba: out };
}

/** The picture scaled to exactly this size, sampling bilinearly. */
export function resizeTo(src: Raster, width: number, height: number): Raster {
  const out = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    const sy = Math.min(src.height - 1, Math.max(0, ((y + 0.5) * src.height) / height - 0.5));
    const y0 = Math.floor(sy), y1 = Math.min(src.height - 1, y0 + 1), fy = sy - y0;
    for (let x = 0; x < width; x++) {
      const sx = Math.min(src.width - 1, Math.max(0, ((x + 0.5) * src.width) / width - 0.5));
      const x0 = Math.floor(sx), x1 = Math.min(src.width - 1, x0 + 1), fx = sx - x0;
      const o = (y * width + x) * 4;
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
  return { width, height, rgba: out };
}

/** The picture at another size, sampled bilinearly. */
export function resizePng(src: Raster, size: number): Raster {
  return resizeTo(src, size, size);
}

/** A box of the picture, as a picture of its own. */
export function cropPng(src: Raster, x: number, y: number, width: number, height: number): Raster {
  const out = new Uint8Array(width * height * 4);
  for (let row = 0; row < height; row++) {
    const from = ((y + row) * src.width + x) * 4;
    out.set(src.rgba.subarray(from, from + width * 4), row * width * 4);
  }
  return { width, height, rgba: out };
}

/** The picture scaled to fit a square canvas, centred, with its aspect ratio kept. */
export function containPng(src: Raster, size: number): Raster {
  const scale = Math.min(size / src.width, size / src.height);
  const width = Math.max(1, Math.round(src.width * scale));
  const height = Math.max(1, Math.round(src.height * scale));
  const scaled = resizeTo(src, width, height);
  const out = new Uint8Array(size * size * 4);
  const left = Math.floor((size - width) / 2), top = Math.floor((size - height) / 2);
  for (let row = 0; row < height; row++) {
    out.set(scaled.rgba.subarray(row * width * 4, (row + 1) * width * 4), ((top + row) * size + left) * 4);
  }
  return { width: size, height: size, rgba: out };
}

/** The picture scaled to cover a square box, centred, and cropped to it. */
export function coverPng(src: Raster, size: number): Raster {
  const scale = Math.max(size / src.width, size / src.height);
  const width = Math.max(1, Math.round(src.width * scale));
  const height = Math.max(1, Math.round(src.height * scale));
  const scaled = resizeTo(src, width, height);
  return cropPng(scaled, Math.floor((width - size) / 2), Math.floor((height - size) / 2), size, size);
}

/**
 * The box the picture's visible pixels occupy: left and top inclusive, right and bottom exclusive.
 * A pixel counts when its alpha is more than a faint edge (8 of 255), so a one-pixel anti-aliased
 * border around an otherwise full-bleed picture doesn't read as padding.
 */
export function alphaBounds(img: Raster): { left: number; top: number; right: number; bottom: number } {
  let left = img.width, top = img.height, right = 0, bottom = 0;
  for (let y = 0; y < img.height; y++) {
    for (let x = 0; x < img.width; x++) {
      if (img.rgba[(y * img.width + x) * 4 + 3] <= 8) continue;
      if (x < left) left = x;
      if (x >= right) right = x + 1;
      if (y < top) top = y;
      if (y >= bottom) bottom = y + 1;
    }
  }
  return right > left && bottom > top ? { left, top, right, bottom } : { left: 0, top: 0, right: img.width, bottom: img.height };
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
