// Images: decoding lives in the host; this caches per path and asks for the intrinsic size.
// Every entry is cached twice, oriented by its EXIF data and not, because image-orientation
// decides which one an element uses (and a rotated image's intrinsic size is swapped).

import * as P from "../shared/props.ts";
import { assetPath } from "./assets.ts";
import { invalidatePaint } from "./invalidation.ts";
import { hostImageDraw, hostImageDrawPart, hostImageFailed, hostImageLoad, hostImageReady, hostImageWidth, hostImageHeight } from "./host.ts";
import { drawSvgPart, drawSvgProgram, drawSvgWindow, parseSvgProgram, type SvgProgram } from "./svg-image.ts";
import type { Node } from "./dom.ts";

/** Whether the element applies its images' EXIF orientation (image-orientation: from-image). */
export function orientedImage(el: Node): boolean {
  return el.sv[P.P_IMAGE_ORIENTATION] !== P.IO_NONE;
}

/** The file an IMAGE_FILES entry names, for CSSOM's text of an image. */
export function imageFilePath(index: number): string {
  return index >= 0 && index < files.length ? files[index] : "";
}

/** The cache key for a path: the unoriented form is a separate host image. */
function cacheKey(path: string, oriented: boolean): string {
  return oriented ? path : "none:" + path;
}

const ids: Map<string, number> = new Map();
const sizes: Map<string, number[]> = new Map();
const byId: Map<number, number[]> = new Map();

// The compiled IMAGE_FILES table: build-time resolved paths, indexed by the numbers a
// background-image layer holds. The host ids are filled in on first use.
let files: string[] = [];
const fileHostIds: Map<string, number> = new Map();

// The image URLs a style="" attribute names (IMAGE_URLS) and the IMAGE_FILES entry each one
// resolved to at build time. The tables are short, so a lookup is a linear scan.
let inlineUrls: string[] = [];
let inlineUrlFiles: number[] = [];

// SVG files the build compiled into draw programs (SVG_IMAGE_FILES and SVG_IMAGE_PROGRAMS, same
// order): an entry names its IMAGE_FILES index. The programs are parsed on first use.
let svgFileIndices: number[] = [];
let svgPrograms: string[] = [];
const parsedPrograms: Map<number, SvgProgram | null> = new Map();

// The page's own directory (IMAGE_BASE): a URL a script sets at runtime (an Image's src) is a
// page-relative file the compiler never saw, so it resolves here the way the build resolves a
// markup <img src> — against the page, which is a directory of unwrapped files. A bundled app
// leaves the base empty, so a URL resolves to the bundle-relative path the build would have
// written into its tables, and the bundle root a host call reports supplies the directory. A
// page-root URL ("/cover.png") names the public directory in a dev build (SITE_BASE), whose files
// a bundled app has in the bundle's root.
let baseDir = "";
/** True when a page-root URL ("/logo.png") names a file in the bundle. */
let rootUrls = false;
/** A dev build's public directory, which a page-root URL resolves against there. */
let siteDir = "";

/** Records the page directory runtime image URLs resolve against, and a dev build's public one. */
export function setImageBase(dir: string, bundled: boolean = false, site: string = ""): void {
  baseDir = dir;
  rootUrls = bundled;
  siteDir = site;
}

/**
 * The file a runtime image URL names, relative to the build's working directory like every
 * IMAGE_FILES entry; "" for an empty URL, a data: URL, or any other scheme (nothing fetches).
 */
export function resolveImageSource(url: string): string {
  const raw = url.trim();
  // A URL the build already resolved — a data: image written out to a file, or a url() an inline
  // style names — is found by the text the page wrote.
  const at = inlineUrls.indexOf(raw);
  if (at >= 0) {
    const file = inlineUrlFiles[at];
    if (file >= 0 && file < files.length) return files[file];
  }
  let clean = raw;
  const query = clean.indexOf("?");
  if (query >= 0) clean = clean.slice(0, query);
  const hash = clean.indexOf("#");
  if (hash >= 0) clean = clean.slice(0, hash);
  if (clean === "" || clean.startsWith("//") || /^[a-z][a-z0-9+.-]*:/i.test(clean)) return "";
  // A "/" URL names the site root: the public directory in a dev build, and the bundle itself in
  // a bundled one, where "/x" is the bundle-relative "x".
  if (clean.startsWith("/")) {
    if (rootUrls) return normalizePath(clean).replace(/^\/+/, "");
    return siteDir === "" ? "" : normalizePath(siteDir + clean);
  }
  return normalizePath(baseDir === "" ? clean : baseDir + "/" + clean);
}

/** Collapses "." and ".." segments, the way a URL's path resolution does. */
function normalizePath(path: string): string {
  const out: string[] = [];
  const parts = path.split("/");
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (out.length > 0) out.pop();
      continue;
    }
    out.push(part);
  }
  return (path.startsWith("/") ? "/" : "") + out.join("/");
}

/** The host's id for an image file, or -1 if it can't be decoded (or there is no path). */
export function imageId(path: string, oriented: boolean): number {
  if (path === "") return -1;
  const key = cacheKey(path, oriented);
  const hit = ids.get(key);
  if (hit !== undefined) return hit;
  const id = hostImageLoad(assetPath(path), oriented ? 1 : 0);
  ids.set(key, id);
  return id;
}

/** The id of an image whose pixels the host already has, or -1: no decode left to wait for. A host
 *  that decodes on the thread that asks answers a file it has opened complete at once, so a
 *  texture uploaded in the same turn as a markup <img> sees the picture; a host that decodes on a
 *  thread of its own answers -1 here until its decode lands. */
export function decodedImageNow(path: string): number {
  const id = imageId(path, true);
  return id >= 0 && hostImageReady(id) !== 0 && hostImageFailed(id) === 0 ? id : -1;
}

// The host makes an image's pixels on a thread of its own, so an id exists a turn or more before
// the picture does. A load, and decode(), wait here for it; when a decode lands the page repaints
// the pictures it makes drawable. A file the host can't open at all has no id, and settles now.

const waiting: Map<number, Array<(ok: boolean) => void>> = new Map();

/**
 * Calls `done` once the image's pixels are ready (true) or its decode failed (false). An image
 * whose decode is already over answers on a later turn of the loop, as a load does.
 */
export function whenImageReady(id: number, done: (ok: boolean) => void): void {
  if (id < 0 || hostImageReady(id) !== 0) {
    const ok = id >= 0 && hostImageFailed(id) === 0;
    setTimeout(() => done(ok), 0);
    return;
  }
  const list = waiting.get(id);
  if (list === undefined) waiting.set(id, [done]);
  else list.push(done);
}

/** Delivers the decodes that landed since the last call, and repaints for them. */
export function pumpImages(): void {
  if (waiting.size === 0) return;
  let landed = false;
  for (const [id, list] of waiting) {
    if (hostImageReady(id) === 0) continue;
    waiting.delete(id);
    landed = true;
    const ok = hostImageFailed(id) === 0;
    for (const done of list) done(ok);
  }
  // A background or mask image is drawn straight from its file, with no element to mark: the
  // whole page is painted once more so the picture it now has appears.
  if (landed) invalidatePaint();
}

/** Whether an image is still decoding: a headless run paints only once none is. */
export function imagesDecoding(): boolean {
  return waiting.size > 0;
}

/** Intrinsic [width, height] in px; [0, 0] for a missing or broken image, or one with no size. */
export function imageSize(path: string, oriented: boolean): number[] {
  const svg = svgProgramForPath(path);
  // A file that only has a viewBox has a ratio and no size of its own: its auto width fills the
  // space it is given (see imageNaturalRatio for the ratio that gives it a height).
  if (svg !== null) return svg.has === 3 ? [svg.w, svg.h] : [0, 0];
  const key = cacheKey(path, oriented);
  const hit = sizes.get(key);
  if (hit !== undefined) return hit;
  const id = imageId(path, oriented);
  const size = id < 0 ? [0, 0] : [hostImageWidth(id), hostImageHeight(id)];
  sizes.set(key, size);
  return size;
}

/** Whether an image has a size of its own: a viewBox-only SVG file has a ratio and no size. */
export function imageHasSize(path: string): boolean {
  const svg = svgProgramForPath(path);
  return svg === null || svg.has === 3;
}

/** What an image's file says about its own size: the px it defaults to, which axes are the file's
 *  own (1 height, 2 width, 3 both, 0 neither) and its intrinsic ratio, or 0 for none. */
export interface ImageAxes { w: number; h: number; has: number; ratio: number }

/** The sizing axes of IMAGE_FILES[index], as a background layer needs them. */
export function imageFileAxes(index: number, oriented: boolean): ImageAxes {
  const svg = svgProgramFor(index);
  if (svg !== null) {
    // Only a viewBox (or both attributes) gives a ratio; the 300 by 150 default is no ratio.
    const ratio = svg.has === 3 || svg.view !== null ? (svg.h > 0 ? svg.w / svg.h : 0) : 0;
    return { w: svg.w, h: svg.h, has: svg.has, ratio };
  }
  const size = imageFileSize(index, oriented);
  return { w: size[0], h: size[1], has: 3, ratio: size[1] > 0 ? size[0] / size[1] : 0 };
}

/** The size an image is fitted into a box at: its default object size, which is its own size, or
 *  300 by 150 fitted to its ratio when that is all it has (CSS Images 3 §5.3.2). */
export function imageObjectSize(path: string, oriented: boolean): number[] {
  const svg = svgProgramForPath(path);
  return svg !== null ? [svg.w, svg.h] : imageSize(path, oriented);
}

/** An image's own width / height ratio, or 0 when it has none. An SVG has one from its viewBox, or
 *  from both of its attributes; a percentage attribute gives no ratio, only the 300 by 150
 *  default to fill in for what the file leaves out. */
export function imageRatio(path: string): number {
  const svg = svgProgramForPath(path);
  if (svg === null) return 0;
  return svg.has === 3 || svg.view !== null ? (svg.h > 0 ? svg.w / svg.h : 0) : 0;
}

/** Records the SVG images the build compiled: IMAGE_FILES indices and their programs. */
export function setSvgImages(indices: number[], programs: string[]): void {
  svgFileIndices = indices;
  svgPrograms = programs;
  parsedPrograms.clear();
}

/** The compiled program for IMAGE_FILES[index], or null when that file isn't an SVG. */
export function svgProgramFor(index: number): SvgProgram | null {
  let at = -1;
  for (let i = 0; i < svgFileIndices.length; i++) {
    if (svgFileIndices[i] === index) { at = i; break; }
  }
  if (at < 0) return null;
  const hit = parsedPrograms.get(index);
  if (hit !== undefined) return hit;
  const p = parseSvgProgram(svgPrograms[at]);
  parsedPrograms.set(index, p);
  return p;
}

/** The compiled program for a build-time image path, or null when that file isn't an SVG. */
export function svgProgramForPath(path: string): SvgProgram | null {
  const i = files.indexOf(path);
  return i < 0 ? null : svgProgramFor(i);
}

/** Draws IMAGE_FILES[index] into the rect; false when it can't be decoded. */
export function drawImageFile(index: number, oriented: boolean, x: number, y: number, w: number, h: number,
  alpha: number, smooth: number): boolean {
  const svg = svgProgramFor(index);
  if (svg !== null) {
    drawSvgProgram(svg, x, y, w, h, alpha, smooth);
    return true;
  }
  const id = imageFileId(index, oriented);
  if (id < 0) return false;
  hostImageDraw(id, x, y, w, h, alpha, smooth);
  return true;
}

/**
 * Draws the part of IMAGE_FILES[index] inside a source rect, in image pixels, into the rect: one
 * slice of a picture fitted round a border. False for an image with no pixels to cut (an SVG
 * program, which the caller draws whole under a clip) or one that can't be decoded.
 */
export function drawImageFilePart(index: number, oriented: boolean, sx: number, sy: number,
  sw: number, sh: number, x: number, y: number, w: number, h: number,
  alpha: number, smooth: number): boolean {
  if (svgProgramFor(index) !== null) return false;
  const id = imageFileId(index, oriented);
  if (id < 0) return false;
  hostImageDrawPart(id, x, y, w, h, sx, sy, sw, sh, alpha, smooth);
  return true;
}

/**
 * Draws one slice of an SVG border image: the part of the picture of an imageW × imageH image
 * within the source rect (sx, sy, sw, sh) as the destination. False when IMAGE_FILES[index] isn't
 * an SVG.
 */
export function drawSvgImageSlice(index: number, imageW: number, imageH: number,
  sx: number, sy: number, sw: number, sh: number, dx: number, dy: number, dw: number, dh: number,
  alpha: number, smooth: number): boolean {
  const p = svgProgramFor(index);
  if (p === null) return false;
  drawSvgPart(p, imageW, imageH, sx, sy, sw, sh, dx, dy, dw, dh, alpha, smooth);
  return true;
}

/**
 * Draws the part of IMAGE_FILES[index] inside a window of the size w × h it is drawn at, into that
 * same rect on the page; false when IMAGE_FILES[index] isn't an SVG.
 */
export function drawSvgImageWindow(index: number, w: number, h: number, wx: number, wy: number,
  ww: number, wh: number, x: number, y: number, alpha: number, smooth: number): boolean {
  const p = svgProgramFor(index);
  if (p === null) return false;
  drawSvgWindow(p, w, h, wx, wy, ww, wh, x, y, alpha, smooth);
  return true;
}

/** Draws the image a build-time path names into the rect; false when it can't be decoded. */
export function drawImagePath(path: string, oriented: boolean, x: number, y: number, w: number, h: number,
  alpha: number, smooth: number): boolean {
  const svg = svgProgramForPath(path);
  if (svg !== null) {
    drawSvgProgram(svg, x, y, w, h, alpha, smooth);
    return true;
  }
  const id = imageId(path, oriented);
  if (id < 0) return false;
  hostImageDraw(id, x, y, w, h, alpha, smooth);
  return true;
}

/** Records the compiled image file table; host ids are loaded lazily, one per file. */
export function setImageFiles(list: string[]): void {
  files = list;
  fileHostIds.clear();
}

/** Records the URLs style="" attributes name, which the runtime resolves at mount. */
export function setInlineImages(urls: string[], urlFiles: number[]): void {
  inlineUrls = urls;
  inlineUrlFiles = urlFiles;
}

/** IMAGE_FILES index for an image URL a style="" attribute names, or -1 if it has none. */
export function inlineImageId(url: string): number {
  for (let i = 0; i < inlineUrls.length; i++) if (inlineUrls[i] === url) return inlineUrlFiles[i];
  return -1;
}

/** The host's id for IMAGE_FILES[index], or -1 if that file can't be decoded. */
export function imageFileId(index: number, oriented: boolean): number {
  if (index < 0 || index >= files.length) return -1;
  const key = cacheKey(String(index), oriented);
  const hit = fileHostIds.get(key);
  if (hit !== undefined) return hit;
  const id = hostImageLoad(assetPath(files[index]), oriented ? 1 : 0);
  fileHostIds.set(key, id);
  return id;
}

/** Default object size [width, height] of IMAGE_FILES[index] in px, which a background-image
 *  sizes from; [0, 0] for a missing or broken image. */
export function imageFileSize(index: number, oriented: boolean): number[] {
  const svg = svgProgramFor(index);
  if (svg !== null) return [svg.w, svg.h];
  const id = imageFileId(index, oriented);
  const hit = byId.get(id);
  if (hit !== undefined) return hit;
  const size = id < 0 ? [0, 0] : [hostImageWidth(id), hostImageHeight(id)];
  byId.set(id, size);
  return size;
}

/** Intrinsic [width, height] of an image the host already loaded, by its id. */
export function imageSizeById(id: number): number[] {
  const hit = byId.get(id);
  if (hit !== undefined) return hit;
  const size = id < 0 ? [0, 0] : [hostImageWidth(id), hostImageHeight(id)];
  byId.set(id, size);
  return size;
}
