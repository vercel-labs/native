// App icons for the platforms, from the web's own vocabulary.
//
// A page names its icon the way a browser reads it: a manifest icon with a `purpose` (`any`,
// `maskable`, `monochrome`) or a `<link rel="icon">`. An icon drawn for the web is rarely drawn
// for a platform's icon grid, so a maskable icon gets the platform's template: on macOS the
// picture is inset to the 1024-pixel icon grid and masked to its shape with the standard shadow;
// Windows and Linux keep their own sizes with a small margin. An `any` icon that already has
// transparent padding is used as it is; a full-bleed `any` icon gets the template too, because
// that is almost never what its author meant. Stating a purpose is the explicit opt-out: an icon
// whose manifest entry says `purpose: "any"` is used as the author laid it out.

import type { AppIcon, AppInfo } from "./app-info.ts";
import {
  alphaBounds, containPng, coverPng, readPng, resizePng, writePng,
  type Raster,
} from "./png.ts";

/** The icon grids a build draws for. */
export type IconPlatform = "macos" | "windows" | "linux";

/** The platform a build runs for: a cross-build's target when one is named. */
export function iconPlatform(platform: NodeJS.Platform = process.platform,
  target: string | undefined = process.env["SCRIPTC_TARGET"]): IconPlatform {
  if (platform === "win32" || /windows/.test(target ?? "")) return "windows";
  return platform === "darwin" ? "macos" : "linux";
}

/** The icon a platform uses, and whether it gets the platform's template. */
export interface IconChoice {
  icon: AppIcon;
  /** True for the platform template (inset; on macOS the mask and shadow too). */
  template: boolean;
  /** The source pixels, or null when the PNG isn't one this build can read. */
  raster: Raster | null;
}

/** macOS's icon grid: a 1024-pixel canvas with the shape inset to 824 pixels. */
export const MACOS_CANVAS = 1024;
export const MACOS_CONTENT = 824;
/** The margin Windows and Linux leave around a templated picture: 5% on each side. */
const PLATFORM_INSET = 0.9;

/**
 * The icon a platform uses when the page names several: a maskable icon is drawn to be masked,
 * which suits macOS's grid; Windows and Linux show the picture whole, so an `any` icon with its
 * own layout suits them. The largest of the fitting ones wins.
 */
export function iconChoice(info: AppInfo, platform: IconPlatform): IconChoice | null {
  const pngs = info.icons.filter((icon) => icon.type === "image/png");
  if (pngs.length === 0) return null;
  // A letterboxed 16-pixel icon fits no platform at the sizes an app is shown; when there is a
  // reasonably sized one, the purpose picks among those.
  const sized = pngs.filter((icon) => Math.min(icon.width, icon.height) >= 128);
  const pool = sized.length > 0 ? sized : pngs;
  const fit = (icon: AppIcon): number => {
    const maskable = icon.purposes.includes("maskable");
    const any = icon.purposes.includes("any");
    if (platform === "macos") return maskable ? 2 : any ? 1 : 0;
    return any ? (maskable ? 1 : 2) : 0;
  };
  const sorted = pool.sort((a, b) => fit(b) - fit(a) || b.width * b.height - a.width * a.height);
  const icon = sorted[0];
  const raster = readPng(icon.source);
  return { icon, raster, template: usesTemplate(icon, raster) };
}

/**
 * Whether the icon gets the platform template. A maskable icon is drawn full-bleed for a mask, so
 * it always does. An `any` icon does when its author left the purpose unstated and the picture is
 * full-bleed (its visible pixels reach within 2% of every edge); otherwise the author's own
 * padding is the layout, and the picture is used as it is.
 */
export function usesTemplate(icon: AppIcon, raster: Raster | null): boolean {
  if (icon.purposes.includes("maskable")) return true;
  if (icon.purposeStated) return false;
  if (raster === null) return false;
  const bounds = alphaBounds(raster);
  const margin = Math.min(
    bounds.left, bounds.top, raster.width - bounds.right, raster.height - bounds.bottom,
  ) / Math.min(raster.width, raster.height);
  return margin < 0.02;
}

/** The picture macOS reads: inset to the grid, masked to the squircle, with the standard shadow;
 *  or the author's own layout, scaled whole, when no template applies. */
export function macIcon(raster: Raster, template: boolean): Raster {
  if (!template) return containPng(raster, MACOS_CANVAS);
  const art = coverPng(raster, MACOS_CONTENT);
  const mask = squircleMask(MACOS_CONTENT);
  const left = (MACOS_CANVAS - MACOS_CONTENT) / 2;
  const down = 12;
  // The shape on the full canvas, then blurred there: the shadow falls outside the shape but
  // inside the canvas.
  const silhouette = new Uint8Array(MACOS_CANVAS * MACOS_CANVAS);
  for (let y = 0; y < MACOS_CONTENT; y++) {
    silhouette.set(mask.subarray(y * MACOS_CONTENT, (y + 1) * MACOS_CONTENT), (y + left) * MACOS_CANVAS + left);
  }
  let shadow: Uint8Array = silhouette;
  for (let pass = 0; pass < 3; pass++) shadow = boxBlur(shadow, MACOS_CANVAS, 5);
  const out = new Uint8Array(MACOS_CANVAS * MACOS_CANVAS * 4);
  // Black at 34%, offset down by 12 pixels of the 1024 grid.
  for (let y = 0; y < MACOS_CANVAS; y++) {
    const source = y - down;
    if (source < 0) continue;
    for (let x = 0; x < MACOS_CANVAS; x++) {
      out[(y * MACOS_CANVAS + x) * 4 + 3] = Math.round(shadow[source * MACOS_CANVAS + x] * 0.34);
    }
  }
  // The picture, masked, over it.
  for (let y = 0; y < MACOS_CONTENT; y++) {
    for (let x = 0; x < MACOS_CONTENT; x++) {
      const cover = mask[y * MACOS_CONTENT + x];
      if (cover === 0) continue;
      const s = (y * MACOS_CONTENT + x) * 4;
      const d = ((y + left) * MACOS_CANVAS + x + left) * 4;
      const a = art.rgba[s + 3] * cover / 255;
      if (a === 0) continue;
      const under = out[d + 3] * (1 - a / 255);
      const alpha = a + under;
      out[d] = Math.round(art.rgba[s] * a / alpha);
      out[d + 1] = Math.round(art.rgba[s + 1] * a / alpha);
      out[d + 2] = Math.round(art.rgba[s + 2] * a / alpha);
      out[d + 3] = Math.round(alpha);
    }
  }
  return { width: MACOS_CANVAS, height: MACOS_CANVAS, rgba: out };
}

/**
 * The squircle macOS masks an app icon with, as 0–255 coverage for each pixel of a square. The
 * shape is a superellipse, which is the rounded square with continuous corners the grid draws;
 * the boundary is antialiased from its distance to the curve.
 */
export function squircleMask(size: number): Uint8Array {
  const mask = new Uint8Array(size * size);
  const r = size / 2, n = 5;
  for (let y = 0; y < size; y++) {
    const ay = Math.abs((y + 0.5 - r) / r);
    for (let x = 0; x < size; x++) {
      const ax = Math.abs((x + 0.5 - r) / r);
      const f = Math.pow(ax, n) + Math.pow(ay, n);
      const gx = n * Math.pow(ax, n - 1) / r, gy = n * Math.pow(ay, n - 1) / r;
      const g = Math.sqrt(gx * gx + gy * gy);
      const distance = g === 0 ? 1 : (1 - f) / g;
      mask[y * size + x] = Math.max(0, Math.min(255, Math.round((distance + 0.5) * 255)));
    }
  }
  return mask;
}

/** A separable box blur of an 8-bit channel, with edge pixels repeated. */
function boxBlur(src: Uint8Array, size: number, radius: number): Uint8Array {
  const span = radius * 2 + 1;
  const clamped = (v: number): number => (v < 0 ? 0 : v >= size ? size - 1 : v);
  const horizontal = new Uint8Array(size * size);
  for (let y = 0; y < size; y++) {
    const row = y * size;
    let sum = 0;
    for (let x = -radius; x <= radius; x++) sum += src[row + clamped(x)];
    for (let x = 0; x < size; x++) {
      horizontal[row + x] = Math.round(sum / span);
      sum += src[row + clamped(x + radius + 1)] - src[row + clamped(x - radius)];
    }
  }
  const out = new Uint8Array(size * size);
  for (let x = 0; x < size; x++) {
    let sum = 0;
    for (let y = -radius; y <= radius; y++) sum += horizontal[clamped(y) * size + x];
    for (let y = 0; y < size; y++) {
      out[y * size + x] = Math.round(sum / span);
      sum += horizontal[clamped(y + radius + 1) * size + x] - horizontal[clamped(y - radius) * size + x];
    }
  }
  return out;
}

/** The picture at a platform's size: a templated one is inset, an author's layout is scaled
 *  whole. Windows and Linux draw no mask, so the inset is the template there. */
export function platformIcon(raster: Raster, size: number, template: boolean): Raster {
  if (!template) return containPng(raster, size);
  const content = Math.max(1, Math.round(size * PLATFORM_INSET));
  const art = coverPng(raster, content);
  const out = new Uint8Array(size * size * 4);
  const left = Math.floor((size - content) / 2);
  for (let y = 0; y < content; y++) {
    out.set(art.rgba.subarray(y * content * 4, (y + 1) * content * 4), ((left + y) * size + left) * 4);
  }
  return { width: size, height: size, rgba: out };
}

/** The chunks an .icns holds, in the order macOS reads them: the sizes from 16 to 1024. */
const ICNS_CHUNKS: readonly (readonly [string, number])[] = [
  ["icp4", 16], ["icp5", 32], ["icp6", 64], ["ic07", 128], ["ic08", 256], ["ic09", 512], ["ic10", 1024],
];

/** An .icns holding the 1024-pixel canvas at every size, each a PNG chunk. */
export function writeIcns(canvas: Raster): Buffer {
  const parts: Buffer[] = [];
  for (const [type, size] of ICNS_CHUNKS) {
    const png = size === canvas.width ? writePng(canvas) : writePng(resizePng(canvas, size));
    const head = Buffer.alloc(8);
    head.write(type, 0, "ascii");
    head.writeUInt32BE(8 + png.length, 4);
    parts.push(head, png);
  }
  const body = Buffer.concat(parts);
  const head = Buffer.alloc(8);
  head.write("icns", 0, "ascii");
  head.writeUInt32BE(8 + body.length, 4);
  return Buffer.concat([head, body]);
}
