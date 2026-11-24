// Background images: the layer lists compiled at build time, and painting them into a box.
//
// A background-image declaration is a comma-separated list of layers, painted bottom layer first.
// The other layer longhands (repeat, position, size, origin, clip) are their own lists; a shorter
// list repeats, as the CSS background layer algorithm says.

import * as P from "../shared/props.ts";
import { Element, Node } from "./dom.ts";
import { hostClipPush, hostClipPushRound, hostClipPop } from "./host.ts";
import { paintGradientTile } from "./gradient.ts";
import { containerBasis } from "./style.ts";
import { drawImageFile, drawImageFilePart, drawSvgImageWindow, imageFileAxes, imageFilePath, imageFileSize, orientedImage } from "./images.ts";
import { smoothImage } from "./image-fit.ts";
import { borderBottom, borderLeft, borderPx, borderRight, borderTop, isScroller, len, viewport, zeroIfNaN } from "./layout/box-model.ts";
import { fontMetrics, textWidth } from "./layout/text.ts";
import { innerRadii, rounded } from "./radius.ts";
import type { Radii } from "./radius.ts";
import { hasTransform } from "./transform.ts";
import { evalExpr } from "../shared/css/length-exprs.ts";
import { rootFontSize } from "./root-size.ts";
import { axisText } from "../shared/css/position.ts";
import { gradientCss } from "../shared/css/gradients.ts";

export class BackgroundTables {
  images: number[][] = [];
  repeats: number[][] = [];
  positions: number[][] = [];
  sizes: number[][] = [];
  origins: number[][] = [];
  clips: number[][] = [];
  attachments: number[][] = [];
  /** The gradient images a BG_IMAGES value can name, encoded by shared/css/gradients.ts. */
  gradients: string[] = [];
  /** The CSS text of each of those gradients, for CSSOM's reading of the image. */
  gradientTexts: string[] = [];
  /** Rows an inline style registers at runtime, by synthetic id; one map per BG_* kind. */
  extras: Map<number, number[]>[] = [];
  extraKeys: Map<string, number>[] = [];
  /** Gradients an inline style registers at runtime, after the compiled ones. */
  extraGradients: string[] = [];
  extraGradientTexts: string[] = [];
  extraGradientKeys: Map<string, number> = new Map();
}

export const bg: BackgroundTables = new BackgroundTables();

/** Rows registered at runtime start above every compiled row id. */
const RUNTIME_BASE = 1000000;

/** Square corners. */
const SQUARE: Radii = [0, 0, 0, 0, 0, 0, 0, 0];

const NO_ROWS: Map<number, number[]> = new Map();

function extraOf(kind: number): Map<number, number[]> {
  return kind < bg.extras.length ? bg.extras[kind] : NO_ROWS;
}

/**
 * Registers one layer list an inline style declared, and returns the id to store as its value.
 * Identical lists share an id, like the build-time tables.
 */
export function registerRow(kind: number, row: number[]): number {
  while (bg.extras.length <= kind) {
    bg.extras.push(new Map());
    bg.extraKeys.push(new Map());
  }
  const key = row.join(",");
  const hit = bg.extraKeys[kind].get(key);
  if (hit !== undefined) return hit;
  const id = RUNTIME_BASE + bg.extras[kind].size;
  bg.extras[kind].set(id, row);
  bg.extraKeys[kind].set(key, id);
  return id;
}

/**
 * Registers a gradient an inline style declared and returns its id, which an image layer stores
 * as -(id + 2). Identical gradients share an id, like the build-time table.
 */
export function registerGradient(encoded: string, source: string = ""): number {
  const hit = bg.extraGradientKeys.get(encoded);
  if (hit !== undefined) return hit;
  const id = bg.gradients.length + bg.extraGradients.length;
  bg.extraGradients.push(encoded);
  bg.extraGradientTexts.push(source);
  bg.extraGradientKeys.set(encoded, id);
  return id;
}

/** The encoded gradient an image layer's value names, or null for a raster image or `none`. */
export function gradientOf(value: number): string | null {
  if (value >= -1) return null;
  const id = -value - 2;
  if (id < bg.gradients.length) return bg.gradients[id];
  const extra = bg.extraGradients[id - bg.gradients.length];
  return extra === undefined ? null : extra;
}

/** A gradient image's CSS text, or "" when this build kept none for it. */
export function gradientTextOf(value: number): string {
  if (value >= -1) return "";
  const id = -value - 2;
  if (id < bg.gradientTexts.length) return bg.gradientTexts[id] ?? "";
  return bg.extraGradientTexts[id - bg.gradientTexts.length] ?? "";
}

/** The row an element's list-valued property points at, or null for the initial value. */
export function rowOf(el: Node, p: number, rows: number[][], kind: number): readonly number[] | null {
  if (el.su[p] !== P.U_LIST) return null;
  const id = el.sv[p];
  if (id >= RUNTIME_BASE) {
    const row = extraOf(kind).get(id);
    return row === undefined ? null : row;
  }
  return id >= 0 && id < rows.length ? rows[id] : null;
}

/**
 * Drops the rows and gradients inline styles registered for the last page. Their ids are offsets
 * into the page's own compiled tables (see registerRow and registerGradient), so a new page's
 * table makes them wrong: a batch that renders several pages in one process has to start each
 * with only its own, as a browser starts each document.
 */
export function resetRuntimeRows(): void {
  for (const m of bg.extras) m.clear();
  for (const m of bg.extraKeys) m.clear();
  bg.extraGradients.length = 0;
  bg.extraGradientKeys.clear();
}

/** One axis of a background-position row list as CSS text, one entry per layer. */
export function backgroundAxisText(id: number, vertical: boolean): string {
  const row = id >= RUNTIME_BASE ? extraOf(P.BG_POSITION).get(id) : (id >= 0 && id < bg.positions.length ? bg.positions[id] : undefined);
  if (row === undefined || row.length < 6) return "";
  const parts: string[] = [];
  for (let i = 0; i + 5 < row.length; i += 6) {
    parts.push(vertical ? axisText(row[i + 3], row[i + 4], row[i + 5], "top", "bottom")
      : axisText(row[i], row[i + 1], row[i + 2], "left", "right"));
  }
  return parts.join(", ");
}

/** A layer's field i of a row whose layers are `stride` numbers wide. */
export function field(row: readonly number[] | null, layer: number, i: number, stride: number): number {
  if (row === null || row.length === 0) return NaN;
  const at = (layer % (row.length / stride)) * stride + i;
  return row[at];
}

/** A background length in px against a percentage base; NaN for auto. */
export function pxOf(el: Node, v: number, u: number, base: number, fontSize: number, cqw: number, cqh: number): number {
  if (u === P.U_LH) return v * el.sv[P.P_LINE_HEIGHT];
  if (u === P.U_EX) return v * fontMetrics(el)[2];
  if (u === P.U_CH) return v * textWidth(el, "0");
  if (u >= P.U_CQW && u <= P.U_CQMAX) {
    if (u === P.U_CQH || u === P.U_CQB) return (v / 100) * cqh;
    if (u === P.U_CQMIN) return (v / 100) * Math.min(cqw, cqh);
    if (u === P.U_CQMAX) return (v / 100) * Math.max(cqw, cqh);
    return (v / 100) * cqw;
  }
  if (u === P.U_EXPR) return evalExpr(v, base, viewport.w, viewport.h, fontSize, cqw, cqh, rootFontSize(), el.sv[P.P_LINE_HEIGHT]);
  if (u === P.U_PCT) return (base * v) / 100;
  if (u === P.U_VW) return (viewport.w * v) / 100;
  if (u === P.U_VH) return (viewport.h * v) / 100;
  if (u === P.U_AUTO) return NaN;
  return v;
}

/** The [x, y, w, h] of one background box inside a border-box rect. */
export function boxRect(el: Node, x: number, y: number, w: number, h: number, which: number): number[] {
  // The widths a box actually has: a cell of a collapsing table keeps only its share of the grid
  // lines, which is what its padding and content boxes sit inside.
  const bl = borderPx(borderLeft(el)), br = borderPx(borderRight(el));
  const bt = borderPx(borderTop(el)), bb = borderPx(borderBottom(el));
  if (which === P.BX_BORDER) return [x, y, w, h];
  const px = x + bl, py = y + bt, pw = w - bl - br, ph = h - bt - bb;
  if (which === P.BX_PADDING) return [px, py, pw, ph];
  const pl = el.sv[P.P_PADDING_LEFT], pr = el.sv[P.P_PADDING_RIGHT];
  const pt = el.sv[P.P_PADDING_TOP], pb = el.sv[P.P_PADDING_BOTTOM];
  return [px + pl, py + pt, pw - pl - pr, ph - pt - pb];
}

/**
 * The corner radii of a background box inside a border box whose corners are rounded by `radii`:
 * the outer curve less the border (and, for the content box, the padding) between them, as
 * CSS's corner shaping puts the inner curve inside the outer one.
 */
export function boxRadii(el: Node, which: number, radii: Radii): Radii {
  if (!rounded(radii) || which === P.BX_BORDER) return radii;
  return innerRadii(el, radii, which === P.BX_CONTENT);
}

/** Does the element have at least one background image layer (a raster image or a gradient)? */
export function hasBackgroundImage(el: Node): boolean {
  const images = rowOf(el, P.P_BACKGROUND_IMAGE, bg.images, P.BG_IMAGE);
  if (images === null) return false;
  for (let i = 0; i < images.length; i++) if (images[i] !== -1) return true;
  return false;
}

/** The painting area of the bottom-most image layer, which is also the colour's clip box. */
function colourClip(el: Node): number {
  const images = rowOf(el, P.P_BACKGROUND_IMAGE, bg.images, P.BG_IMAGE);
  const layers = images === null || images.length === 0 ? 1 : images.length;
  const clips = rowOf(el, P.P_BACKGROUND_CLIP, bg.clips, P.BG_CLIP);
  return clips !== null && clips.length > 0 ? clips[(layers - 1) % clips.length] : P.BX_BORDER;
}

/**
 * Whether the bottom-most layer travels with a scrolling element's contents: such a layer is
 * painted inside the scrollport, which confines the background colour and the images to the
 * padding box whatever the clip box says.
 */
export function scrollsWithContents(el: Node): boolean {
  if (!isScroller(el)) return false;
  const images = rowOf(el, P.P_BACKGROUND_IMAGE, bg.images, P.BG_IMAGE);
  const layers = images === null || images.length === 0 ? 1 : images.length;
  const attachments = rowOf(el, P.P_BACKGROUND_ATTACHMENT, bg.attachments, P.BG_ATTACHMENT);
  return attachments !== null && attachments.length > 0
    && attachments[(layers - 1) % attachments.length] === P.BA_LOCAL;
}

/**
 * The box the background colour fills: the painting area of the bottom-most image layer, since
 * the colour is painted as the layer below every image and clipped like that layer. The layer
 * lists are truncated to the number of image layers, so the clip list cycles to find that one.
 */
export function backgroundClipBox(el: Node, x: number, y: number, w: number, h: number): number[] {
  // A colour that travels with a scrolling element's contents fills the same scrolled area its
  // images do, so a content-box colour shows the strip above its content box too.
  if (scrollsWithContents(el) && el instanceof Element) {
    return localPaintArea(el, x, y, w, h, colourClip(el), el.scrollX, el.scrollY);
  }
  return boxRect(el, x, y, w, h, colourClip(el));
}

/**
 * A layer that scrolls with its element's contents is painted over its clip box moved with the
 * contents and reaching across the scrollable overflow, cut to the scrollport: its colour starts
 * where the scrolled clip box starts and runs to the padding box's far edges. A content-box layer
 * scrolled up therefore shows a strip above its content box, and a border-box one fills the
 * padding box, which is what the attachment-local reftests compare.
 */
function localPaintArea(el: Element, x: number, y: number, w: number, h: number, clip: number, sx: number, sy: number): number[] {
  const box = boxRect(el, x, y, w, h, Number.isNaN(clip) ? P.BX_BORDER : clip);
  const pad = boxRect(el, x, y, w, h, P.BX_PADDING);
  const padRight = pad[0] + pad[2], padBottom = pad[1] + pad[3];
  // An axis the contents overflow reaches to the scrollport's far edge; one they don't keeps the
  // clip box's own edge, moved with them.
  const overflowsY = el.scrollHeight > el.clientHeight;
  const overflowsX = el.scrollWidth > el.clientWidth;
  const left = Math.max(box[0] - sx, pad[0]);
  const top = Math.max(box[1] - sy, pad[1]);
  const right = overflowsX ? padRight : Math.max(left, Math.min(box[0] + box[2] - sx, padRight));
  const bottom = overflowsY ? padBottom : Math.max(top, Math.min(box[1] + box[3] - sy, padBottom));
  return [left, top, Math.max(0, right - left), Math.max(0, bottom - top)];
}

/** The corner radii that box's curve has, inside a border box rounded by `radii`. */
export function backgroundClipRadii(el: Node, radii: Radii): Radii {
  return boxRadii(el, scrollsWithContents(el) ? P.BX_PADDING : colourClip(el), radii);
}

/**
 * Whether the element or one of its ancestors carries a transform, which turns a fixed
 * background layer into a scrolling one.
 */
function inTransform(el: Node): boolean {
  for (let e: Node | null = el; e !== null; e = e.parentElement) {
    if (hasTransform(e)) return true;
  }
  return false;
}

/**
 * Paints an element's background images. (x, y, w, h) is its border box; `radius` clips a
 * border-box background to the rounded corner.
 */
export function paintBackgroundImages(el: Node, x: number, y: number, w: number, h: number, radii: Radii, opacity: number): void {
  paintLayers(el, el, x, y, w, h, radii, opacity, false);
}

/**
 * The canvas's background images: those the root (or the body, when the root has none) propagates
 * to it. They are sized and positioned against the root's box, as if the background were the
 * root's own, but painted over the whole canvas rather than clipped to that box.
 */
export function paintCanvasImages(el: Node, root: Node, opacity: number): void {
  paintLayers(el, root, root.x, root.y, root.w, root.h, SQUARE, opacity, true);
}

// A tile bigger than this in either direction is drawn only where it shows. A cover fit of a
// picture whose ratio is extreme is millions of pixels tall — beyond one bitmap, and a rect that
// size loses its precision in CoreGraphics — while only the part inside the painting area is
// ever seen.
const HUGE_TILE = 16384;

/**
 * One axis of a repeat: the tile's size (which `round` may already have rescaled), the distance
 * from one tile to the next, where the first tile goes, whether there is only the one, and how far
 * the repeat reaches. `round` and `repeat` tile on from the position in both directions; `space`
 * spreads the positioning area's left-over room between its tiles, a lone one staying where it
 * was positioned.
 */
function repeatSpan(kind: number, start: number, size: number, areaStart: number, areaSize: number,
  paintStart: number): number[] {
  // [size, step, first, single, end]
  if (kind === P.BR_ROUND) return [size, size, start - Math.ceil((start - paintStart) / size) * size, 0, Infinity];
  if (kind === P.BR_SPACE) {
    // The spacing comes from the positioning area; the tiles it makes go on past its edges at
    // that same interval, so a layer clipped to a bigger box is still covered.
    const n = Math.floor(areaSize / size);
    if (n > 1) {
      const step = (areaSize - n * size) / (n - 1) + size;
      return [size, step, areaStart - Math.ceil((areaStart - paintStart) / step) * step, 0, Infinity];
    }
    // Fewer than two tiles fit, so there is no room to spread them: the image stays where its
    // position put it, overhanging the positioning area into the painting one.
    return [size, size, start, 1, Infinity];
  }
  if (kind === P.BR_REPEAT) return [size, size, start - Math.ceil((start - paintStart) / size) * size, 0, Infinity];
  return [size, size, start, 1, Infinity];
}

/**
 * Draws one tile of a background layer that is far larger than the painting area: only the part
 * of it inside `clip`, cut from the picture at the tile's size.
 */
function drawLargeTile(el: Node, id: number, x: number, y: number, w: number, h: number,
  clip: number[], alpha: number, smooth: number): void {
  const cx = Math.max(x, clip[0]), cy = Math.max(y, clip[1]);
  const cw = Math.min(x + w, clip[0] + clip[2]) - cx;
  const ch = Math.min(y + h, clip[1] + clip[3]) - cy;
  if (!(cw > 0) || !(ch > 0)) return;
  const oriented = orientedImage(el);
  if (drawSvgImageWindow(id, w, h, cx - x, cy - y, cw, ch, cx, cy, alpha, smooth)) return;
  // A raster image's source rect is in its own pixels, not the size it is drawn at.
  const size = imageFileSize(id, oriented);
  const kx = w > 0 ? size[0] / w : 0, ky = h > 0 ? size[1] / h : 0;
  drawImageFilePart(id, oriented, (cx - x) * kx, (cy - y) * ky, cw * kx, ch * ky,
    cx, cy, cw, ch, alpha, smooth);
}

function paintLayers(el: Node, geom: Node, x: number, y: number, w: number, h: number, radii: Radii,
  opacity: number, canvas: boolean): void {
  const images = rowOf(el, P.P_BACKGROUND_IMAGE, bg.images, P.BG_IMAGE);
  if (images === null || images.length === 0) return;
  const repeats = rowOf(el, P.P_BACKGROUND_REPEAT, bg.repeats, P.BG_REPEAT);
  const positions = rowOf(el, P.P_BACKGROUND_POSITION, bg.positions, P.BG_POSITION);
  // A background-position-x or -y longhand moves one axis of the position, so a layer takes that
  // axis from its own row and the other from background-position.
  const axisX = rowOf(el, P.P_BACKGROUND_POSITION_X, bg.positions, P.BG_POSITION);
  const axisY = rowOf(el, P.P_BACKGROUND_POSITION_Y, bg.positions, P.BG_POSITION);
  const sizes = rowOf(el, P.P_BACKGROUND_SIZE, bg.sizes, P.BG_SIZE);
  const origins = rowOf(el, P.P_BACKGROUND_ORIGIN, bg.origins, P.BG_ORIGIN);
  const clips = rowOf(el, P.P_BACKGROUND_CLIP, bg.clips, P.BG_CLIP);
  const attachments = rowOf(el, P.P_BACKGROUND_ATTACHMENT, bg.attachments, P.BG_ATTACHMENT);
  // The last layer is painted first, so the first one ends up on top.
  const fontSize = el.sv[P.P_FONT_SIZE];
  for (let layer = images.length - 1; layer >= 0; layer--) {
    const id = images[layer];
    if (id === -1) continue;
    // A gradient is an image with the positioning area's own size; a file has its own, which an
    // SVG may give on one axis only, or as a ratio without a size.
    const gradient = gradientOf(id);
    let iw = 0, ih = 0;
    const axes = gradient === null ? imageFileAxes(id, orientedImage(el)) : null;
    if (axes !== null) {
      iw = axes.w;
      ih = axes.h;
    }

    const origin = field(origins, layer, 0, 1);
    const clip = field(clips, layer, 0, 1);
    // A fixed layer is positioned and sized against the viewport and stays there while the
    // page scrolls, though it is still only visible inside the element's own painting area. An
    // ancestor with a transform gives the layer a new containing block, which a fixed layer
    // hangs on to: it is then placed like a scrolling one (CSS Transforms 1, transform
    // rendering).
    const attachment = field(attachments, layer, 0, 1);
    const fixed = attachment === P.BA_FIXED && !inTransform(el);
    const area = fixed
      ? [0, 0, viewport.w, viewport.h]
      : boxRect(geom, x, y, w, h, Number.isNaN(origin) ? P.BX_PADDING : origin);
    // A cq unit in a size, a position or a gradient stop measures the element's query container,
    // whose size the style pass left the unit unresolved against.
    const basis = { w: containerBasis(el, false), h: containerBasis(el, true) };
    // A local layer is positioned against the element's contents, so it travels with them as the
    // element scrolls, on either axis, while its painting area stays the box: its positioning area
    // is the whole scrollable area, which the contents may reach past the visible one. A scrolling
    // element paints its contents — the layer among them — only as far as its scrollport
    // reaches, so the layer is then clipped to the box even where a wider clip box would show it.
    const scrollBox = !fixed && !canvas && attachment === P.BA_LOCAL && geom instanceof Element
      && isScroller(geom) ? geom : null;
    if (scrollBox !== null) {
      area[2] = Math.max(area[2], scrollBox.scrollWidth);
      area[3] = Math.max(area[3], scrollBox.scrollHeight);
      area[0] -= scrollBox.scrollX;
      area[1] -= scrollBox.scrollY;
    }
    const painted = canvas
      ? [0, 0, viewport.w, viewport.h]
      : scrollBox !== null
        ? localPaintArea(scrollBox, x, y, w, h, clip, scrollBox.scrollX, scrollBox.scrollY)
        : boxRect(geom, x, y, w, h, Number.isNaN(clip) ? P.BX_BORDER : clip);
    if (gradient !== null) { iw = area[2]; ih = area[3]; }
    // A file with no size at all has nothing to lay out; a gradient has no size of its own, so
    // its zero-area sizing is caught by the used size below, which a definite one may still fix.
    if (gradient === null && (!(iw > 0) || !(ih > 0))) continue;

    // Used size: a definite length or percentage per axis, auto following the intrinsic ratio,
    // and cover/contain fitting (or filling) the positioning area.
    const sw = field(sizes, layer, 0, 4), swu = field(sizes, layer, 1, 4);
    const sh = field(sizes, layer, 2, 4), shu = field(sizes, layer, 3, 4);
    let tw = NaN, th = NaN;
    // Whether an axis's size is still auto, which lets `round` rescale it (below).
    let autoW = false, autoH = false;
    // An image with neither a size nor a ratio has nothing to fit: cover and contain are then the
    // positioning area's size (CSS Images 3, the default sizing algorithm).
    const ratio = axes === null || axes.ratio <= 0 ? 0 : axes.ratio;
    if (swu === P.U_COVER || swu === P.U_CONTAIN) {
      if (ratio > 0) {
        const sx = area[2] / iw, sy = area[3] / ih;
        const s = swu === P.U_COVER ? Math.max(sx, sy) : Math.min(sx, sy);
        tw = iw * s;
        th = ih * s;
      } else {
        tw = area[2];
        th = area[3];
      }
    } else {
      tw = pxOf(el, sw, swu, area[2], fontSize, basis.w, basis.h);
      th = pxOf(el, sh, shu, area[3], fontSize, basis.w, basis.h);
      autoW = Number.isNaN(tw);
      autoH = Number.isNaN(th);
      if (Number.isNaN(tw) && Number.isNaN(th)) {
        // Both auto: the image's own size, the ratio fitted into the positioning area, or the
        // whole area for an image with neither — and an image with only one side keeps it.
        if (axes !== null && axes.has === 3) { tw = iw; th = ih; }
        else if (axes !== null && (axes.has & 2) !== 0) { tw = iw; th = area[3]; }
        else if (axes !== null && (axes.has & 1) !== 0) { th = ih; tw = area[2]; }
        else if (gradient === null && ratio > 0) {
          const s = Math.min(area[2] / iw, area[3] / ih);
          tw = iw * s;
          th = ih * s;
        } else { tw = area[2]; th = area[3]; }
      } else if (Number.isNaN(tw)) {
        // One auto axis: the ratio gives it from the other, else the image's own width, else the
        // positioning area — a gradient has neither, so an auto axis is the whole area.
        tw = ratio > 0 ? th * ratio
          : axes !== null && (axes.has & 2) !== 0 ? iw : area[2];
      } else if (Number.isNaN(th)) {
        th = ratio > 0 ? tw / ratio
          : axes !== null && (axes.has & 1) !== 0 ? ih : area[3];
      }
    }
    if (!(tw > 0) || !(th > 0)) continue;

    // With no repeat list every layer repeats, which is the initial value.
    const kindX = repeats === null ? P.BR_REPEAT : field(repeats, layer, 0, 2);
    const kindY = repeats === null ? P.BR_REPEAT : field(repeats, layer, 1, 2);
    // `round` divides the positioning area into a whole number of tiles and rescales the image to
    // fit that count. An axis left auto follows the other's scale factor, so the image keeps its
    // shape; a definite size on an axis that doesn't round stays as it is.
    const roundX = kindX === P.BR_ROUND && area[2] > 0 ? area[2] / Math.max(1, Math.round(area[2] / tw)) : NaN;
    const roundY = kindY === P.BR_ROUND && area[3] > 0 ? area[3] / Math.max(1, Math.round(area[3] / th)) : NaN;
    const scaleX = Number.isNaN(roundX) ? 1 : roundX / tw;
    const scaleY = Number.isNaN(roundY) ? 1 : roundY / th;
    if (!Number.isNaN(roundX)) tw = roundX;
    else if (autoW && !Number.isNaN(roundY)) tw *= scaleY;
    if (!Number.isNaN(roundY)) th = roundY;
    else if (autoH && !Number.isNaN(roundX)) th *= scaleX;

    // Position: a percentage moves the image across the space left over; a length is an offset
    // from the left/top edge (or from the right/bottom one when the keyword said so).
    const xRow = axisX !== null ? axisX : positions, yRow = axisY !== null ? axisY : positions;
    const xv = field(xRow, layer, 0, 6), xu = field(xRow, layer, 1, 6), xEdge = field(xRow, layer, 2, 6);
    const yv = field(yRow, layer, 3, 6), yu = field(yRow, layer, 4, 6), yEdge = field(yRow, layer, 5, 6);
    const freeX = area[2] - tw, freeY = area[3] - th;
    const offX = xRow === null ? 0 : pxOf(el, xv, xu, freeX, fontSize, basis.w, basis.h);
    const offY = yRow === null ? 0 : pxOf(el, yv, yu, freeY, fontSize, basis.w, basis.h);
    const tx = xEdge === 1 ? area[0] + area[2] - tw - offX : area[0] + offX;
    const ty = yEdge === 1 ? area[1] + area[3] - th - offY : area[1] + offY;

    const spanX = repeatSpan(kindX, tx, tw, area[0], area[2], painted[0]);
    const spanY = repeatSpan(kindY, ty, th, area[1], area[3], painted[1]);
    const tileW = spanX[0], tileH = spanY[0];

    // Tiles are clipped to the painting area, which clips the overflow of a single one too. A
    // layer that scrolls with its contents fills a strip, and the scrollport's rounded shape clips
    // the tiles inside it rather than the strip taking that curve at its own corners.
    const clipRadii = boxRadii(geom, scrollBox !== null ? P.BX_PADDING : Number.isNaN(clip) ? P.BX_BORDER : clip, radii);
    const stacked = scrollBox !== null && rounded(clipRadii);
    hostClipPush(el.serial, P.PK_CLIP_RECT, painted[0], painted[1], painted[2], painted[3], 0);
    if (stacked) {
      const pad = boxRect(geom, x, y, w, h, P.BX_PADDING);
      hostClipPushRound(el.serial, P.PK_CLIP_RECT, pad[0], pad[1], pad[2], pad[3],
        clipRadii[0], clipRadii[1], clipRadii[2], clipRadii[3], clipRadii[4], clipRadii[5], clipRadii[6], clipRadii[7]);
    } else if (rounded(clipRadii)) {
      hostClipPop();
      hostClipPushRound(el.serial, P.PK_CLIP_RECT, painted[0], painted[1], painted[2], painted[3],
        clipRadii[0], clipRadii[1], clipRadii[2], clipRadii[3], clipRadii[4], clipRadii[5], clipRadii[6], clipRadii[7]);
    }
    for (let sy = spanY[2]; sy < Math.min(painted[1] + painted[3], spanY[4]); sy += spanY[1]) {
      for (let sx = spanX[2]; sx < Math.min(painted[0] + painted[2], spanX[4]); sx += spanX[1]) {
        if (gradient !== null) paintGradientTile(gradient, sx, sy, tileW, tileH, fontSize, basis, opacity, el.sv[P.P_COLOR]);
        else if (tileW > HUGE_TILE || tileH > HUGE_TILE) drawLargeTile(el, id, sx, sy, tileW, tileH, painted, opacity, smoothImage(el));
        else drawImageFile(id, orientedImage(el), sx, sy, tileW, tileH, opacity, smoothImage(el));
        if (spanX[3] !== 0 || !(spanX[1] > 0)) break;
      }
      if (spanY[3] !== 0 || !(spanY[1] > 0)) break;
    }
    hostClipPop();
    if (stacked) hostClipPop();
  }
}


// ---------------------------------------------------------------------------
// The computed text of a background layer list

const REPEAT_TEXT = ["repeat", "no-repeat", "space", "round"];
const ATTACHMENT_TEXT = ["scroll", "fixed", "local"];
const BOX_TEXT = ["border-box", "padding-box", "content-box"];

/** One layer of a background longhand as CSS reads it back, or null when it can't be rebuilt. */
function layerText(kind: number, row: readonly number[], layer: number): string | null {
  const f = (i: number, stride: number): number => field(row, layer, i, stride);
  switch (kind) {
    case P.BG_IMAGE: {
      const id = f(0, 1);
      // A gradient is a negative id too: it reads back as the text the build kept for it, its
      // colours resolved, and only what is neither a gradient nor an image is `none`.
      if (gradientOf(id) !== null) {
        const text = gradientTextOf(id);
        return text === "" ? null : gradientCss(text);
      }
      if (id < 0) return "none";
      return "url(" + JSON.stringify(imageFilePath(id)) + ")";
    }
    case P.BG_REPEAT: {
      const x = f(0, 2), y = f(1, 2);
      if (x === y) return REPEAT_TEXT[x] ?? "repeat";
      if (x === P.BR_REPEAT && y === P.BR_NO_REPEAT) return "repeat-x";
      if (x === P.BR_NO_REPEAT && y === P.BR_REPEAT) return "repeat-y";
      return (REPEAT_TEXT[x] ?? "repeat") + " " + (REPEAT_TEXT[y] ?? "repeat");
    }
    case P.BG_POSITION:
      return axisText(f(0, 6), f(1, 6), f(2, 6), "left", "right") + " " +
        axisText(f(3, 6), f(4, 6), f(5, 6), "top", "bottom");
    case P.BG_SIZE: {
      const sizeText = (v: number, u: number): string | null => {
        if (u === P.U_AUTO) return "auto";
        if (u === P.U_COVER) return "cover";
        if (u === P.U_CONTAIN) return "contain";
        if (u !== P.U_PX && u !== P.U_PCT) return null;
        return String(Math.round(v * 1000) / 1000) + (u === P.U_PX ? "px" : "%");
      };
      const w = sizeText(f(0, 4), f(1, 4));
      const h = sizeText(f(2, 4), f(3, 4));
      if (w === null || h === null) return null;
      // `cover` and `contain` are the whole value, not one axis of a pair; an auto axis beside a
      // set one is still written, as CSS reads it back ("50% auto"), and only `auto auto` is
      // just "auto".
      if (w === "cover" || w === "contain") return w;
      if (w === "auto" && h === "auto") return "auto";
      return w + " " + h;
    }
    case P.BG_ORIGIN:
    case P.BG_CLIP:
      return BOX_TEXT[f(0, 1)] ?? null;
    case P.BG_ATTACHMENT:
      return ATTACHMENT_TEXT[f(0, 1)] ?? null;
  }
  return null;
}

/** The computed text of a background longhand an element set, or null for an unset one (CSSOM
 *  names its initial value) or a list with a gradient in it. */
export function backgroundLonghandText(el: Node, p: number): string | null {
  const kind = p === P.P_BACKGROUND_IMAGE ? P.BG_IMAGE
    : p === P.P_BACKGROUND_REPEAT ? P.BG_REPEAT
      : p === P.P_BACKGROUND_POSITION ? P.BG_POSITION
        : p === P.P_BACKGROUND_SIZE ? P.BG_SIZE
          : p === P.P_BACKGROUND_ORIGIN ? P.BG_ORIGIN
            : p === P.P_BACKGROUND_CLIP ? P.BG_CLIP
              : p === P.P_BACKGROUND_ATTACHMENT ? P.BG_ATTACHMENT : -1;
  if (kind < 0) return null;
  const table = kind === P.BG_IMAGE ? bg.images
    : kind === P.BG_REPEAT ? bg.repeats
      : kind === P.BG_POSITION ? bg.positions
        : kind === P.BG_SIZE ? bg.sizes
          : kind === P.BG_ORIGIN ? bg.origins
            : kind === P.BG_CLIP ? bg.clips : bg.attachments;
  const row = rowOf(el, p, table, kind);
  if (row === null) return null;
  const stride = kind === P.BG_REPEAT ? 2 : kind === P.BG_SIZE ? 4 : kind === P.BG_POSITION ? 6 : 1;
  const layers = Math.max(1, Math.floor(row.length / stride));
  const parts: string[] = [];
  for (let i = 0; i < layers; i++) {
    const text = layerText(kind, row, i);
    if (text === null) return null;
    parts.push(text);
  }
  return parts.join(", ");
}

