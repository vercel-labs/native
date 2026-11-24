// border-image: a picture cut into nine slices and fitted round the border area.
//
// The four slice edges are fractions of the source image, the four widths the bands they fill
// (both counting from the same sides), and the four outsets move the whole picture out past the
// border box. Corners land in the corners; edges and, with `fill`, the middle are stretched or
// tiled according to the repeat keywords. A slice is drawn by scaling the whole image so that
// the slice's rectangle lands on its destination and clipping to the destination, which needs no
// host call of its own and works for a raster file, an SVG program and a gradient alike.

import * as P from "../shared/props.ts";
import { Node } from "./dom.ts";
import { hostClipPush, hostClipPop } from "./host.ts";
import { paintGradientTile } from "./gradient.ts";
import { gradientOf } from "./background.ts";
import { containerBasis } from "./style.ts";
import { drawImageFilePart, drawSvgImageSlice, imageFileSize, orientedImage, svgProgramFor } from "./images.ts";
import { smoothImage } from "./image-fit.ts";
import { borderBottom, borderLeft, borderPx, borderRight, borderTop } from "./layout/box-model.ts";

/** Rows of a border-image longhand: slice (9 numbers), width or outset (8), repeat (2). */
let rows: number[][] = [];
const runtimeRows = new Map<number, number[]>();
const runtimeKeys = new Map<string, number>();

/** Rows an inline style registers at runtime start above every compiled row id. */
const RUNTIME_BASE = 1000000;

export function setBorderImageRows(list: number[][]): void {
  rows = list;
}

/** Registers one row an inline style declared and returns its id; identical rows share one. */
export function registerBorderImageRow(row: number[]): number {
  const key = row.join(",");
  const hit = runtimeKeys.get(key);
  if (hit !== undefined) return hit;
  const id = RUNTIME_BASE + runtimeRows.size;
  runtimeRows.set(id, row);
  runtimeKeys.set(key, id);
  return id;
}

/** The row an element's longhand points at, or null when it has none (the initial value). */
function rowOf(el: Node, p: number): readonly number[] | null {
  if (el.su[p] !== P.U_LIST) return null;
  const id = el.sv[p];
  if (id >= RUNTIME_BASE) {
    const row = runtimeRows.get(id);
    return row === undefined ? null : row;
  }
  return id >= 0 && id < rows.length ? rows[id] : null;
}

/** Whether an element's border is drawn from an image rather than from its border styles. */
export function hasBorderImage(el: Node): boolean {
  return el.sv[P.P_BORDER_IMAGE_SOURCE] !== -1 && el.su[P.P_BORDER_IMAGE_SOURCE] === P.U_NONE;
}

/**
 * The four sides of a border-image longhand as (value, unit) pairs, sides in top, right, bottom,
 * left order, read from a row laid out as four values then four units. `dflt` fills in each side
 * the declaration left out (CSS repeats the shorter lists).
 */
function sidesOf(row: readonly number[] | null, dflt: number[]): number[][] {
  const out: number[][] = [];
  for (let i = 0; i < 4; i++) {
    out.push(row === null ? [dflt[2 * i], dflt[2 * i + 1]] : [row[i], row[4 + i]]);
  }
  return out;
}

/** A slice length as a fraction of the image, with numbers meaning image pixels. */
function fractionOf(v: number, u: number, size: number): number {
  if (u === P.U_PCT) return v / 100;
  return size > 0 ? v / size : 0;
}

/**
 * The source's four slice edges as fractions, scaled down together when opposite slices overlap
 * the middle away, as CSS's slice fixup does.
 */
function sliceFractions(el: Node, iw: number, ih: number): number[] {
  const row = rowOf(el, P.P_BORDER_IMAGE_SLICE);
  const fill = row !== null && row[8] !== 0;
  const sides = sidesOf(row, [100, P.U_PCT, 100, P.U_PCT, 100, P.U_PCT, 100, P.U_PCT]);
  const f = [
    fractionOf(sides[0][0], sides[0][1], ih),
    fractionOf(sides[1][0], sides[1][1], iw),
    fractionOf(sides[2][0], sides[2][1], ih),
    fractionOf(sides[3][0], sides[3][1], iw),
  ];
  const sumX = f[1] + f[3], sumY = f[0] + f[2];
  const k = Math.min(1, sumX > 1 ? 1 / sumX : 1, sumY > 1 ? 1 / sumY : 1);
  if (k < 1) for (let i = 0; i < 4; i++) f[i] *= k;
  return [f[0], f[1], f[2], f[3], fill ? 1 : 0];
}

/**
 * The four band widths in px. The initial value is 1, so a bare number counts border widths;
 * `auto` is the natural size of that side's slice, its extent in the image (`sl` holds the four
 * slice fractions and `iw`/`ih` the image's size); a percentage measures the border image area
 * across (left and right) or down (top and bottom).
 */
function bandWidths(el: Node, iw: number, ih: number, bw: number, bh: number, sl: number[]): number[] {
  const sides = sidesOf(rowOf(el, P.P_BORDER_IMAGE_WIDTH), [1, P.U_NONE, 1, P.U_NONE, 1, P.U_NONE, 1, P.U_NONE]);
  const borders = [borderTop(el), borderRight(el), borderBottom(el), borderLeft(el)];
  return sides.map((s, i) => {
    const vertical = i === 0 || i === 2;
    if (s[1] === P.U_AUTO) return sl[i] * (vertical ? ih : iw);
    if (s[1] === P.U_NONE) return s[0] * borderPx(borders[i]);
    if (s[1] === P.U_PCT) return (s[0] / 100) * (vertical ? bh : bw);
    return s[0];
  });
}

/** The four outsets in px: a bare number counts border widths, a percentage the area's size. */
function outsets(el: Node, bw: number, bh: number): number[] {
  const sides = sidesOf(rowOf(el, P.P_BORDER_IMAGE_OUTSET), [0, P.U_NONE, 0, P.U_NONE, 0, P.U_NONE, 0, P.U_NONE]);
  const borders = [borderTop(el), borderRight(el), borderBottom(el), borderLeft(el)];
  return sides.map((s, i) => {
    if (s[1] === P.U_PCT) return (s[0] / 100) * (i === 0 || i === 2 ? bh : bw);
    if (s[1] === P.U_NONE) return s[0] * borderPx(borders[i]);
    return s[0];
  });
}

/** A horizontal and vertical border-image-repeat keyword, from its row. */
function repeatOf(el: Node): number[] {
  const row = rowOf(el, P.P_BORDER_IMAGE_REPEAT);
  return row === null ? [P.BI_STRETCH, P.BI_STRETCH] : [row[0], row[1]];
}

/**
 * Draws one slice: the source rectangle (sx, sy, sw, sh) as the destination rectangle (dx, dy,
 * dw, dh). A raster image is cut in its pixels, so a slice scaled up can't sample the colour of
 * the slices beside it; an SVG is cut the same way out of its raster. A gradient has no pixels
 * to cut: it is placed whole so its source rectangle lands on the destination, then clipped.
 * `iw` and `ih` are the image's size in its own units.
 */
function drawSlice(el: Node, source: number, gradient: string | null, iw: number, ih: number,
  sx: number, sy: number, sw: number, sh: number, dx: number, dy: number, dw: number, dh: number,
  opacity: number): void {
  if (!(sw > 0) || !(sh > 0) || !(dw > 0) || !(dh > 0)) return;
  if (gradient !== null) {
    const kx = dw / sw, ky = dh / sh;
    hostClipPush(el.serial, P.PK_CLIP_RECT, dx, dy, dw, dh, 0);
    paintGradientTile(gradient, dx - sx * kx, dy - sy * ky, iw * kx, ih * ky, el.sv[P.P_FONT_SIZE],
      { w: containerBasis(el, false), h: containerBasis(el, true) }, opacity, el.sv[P.P_COLOR]);
    hostClipPop();
    return;
  }
  // Both cut the picture: a raster in its own pixels, an SVG region out of the bitmap it is
  // rasterized into.
  if (drawImageFilePart(source, orientedImage(el), sx, sy, sw, sh, dx, dy, dw, dh,
    opacity, smoothImage(el))) return;
  drawSvgImageSlice(source, iw, ih, sx, sy, sw, sh, dx, dy, dw, dh, opacity, smoothImage(el));
}

/**
 * One axis of a piece with a repeat keyword, as where its first tile starts, the distance to the
 * next and the tile's size. `repeat` tiles the slice at its own scale with the picture centred
 * on the band, so tiles reach past both ends and the band clips them; `round` rescales them so a
 * whole number fills the band exactly; `space` keeps them at their own scale and spreads the
 * spare room into an equal gap before the first tile, between them and after the last, painting
 * nothing at all when not one tile fits; `stretch` fits the band with a single tile. `src` is the
 * slice's size along the axis, already scaled the way the pieces around it are drawn.
 */
function tileAxis(rule: number, dst: number, src: number): number[] | null {
  if (!(src > 0) || !(dst > 0)) return null;
  if (rule === P.BI_ROUND) {
    const count = Math.max(1, Math.round(dst / src));
    return [0, dst / count, dst / count];
  }
  if (rule === P.BI_REPEAT) return [(dst - src) / 2, src, src];
  if (rule === P.BI_SPACE) {
    const count = Math.floor(dst / src);
    if (count < 1) return null;
    const gap = (dst - src * count) / (count + 1);
    return [gap, src + gap, src];
  }
  return [0, dst, dst];
}

/**
 * Paints an edge or the middle slice, tiled to fill its destination rectangle. Each axis follows
 * its own repeat keyword; `scale` gives how the slice is scaled by the corners beside it, which
 * sets a tile's size, and the destination clips whatever spills past it.
 */
function drawPiece(el: Node, source: number, gradient: string | null, iw: number, ih: number,
  sx: number, sy: number, sw: number, sh: number, dx: number, dy: number, dw: number, dh: number,
  rules: number[], scaleX: number, scaleY: number, opacity: number): void {
  if (rules[0] === P.BI_STRETCH && rules[1] === P.BI_STRETCH) {
    drawSlice(el, source, gradient, iw, ih, sx, sy, sw, sh, dx, dy, dw, dh, opacity);
    return;
  }
  const h = tileAxis(rules[0], dw, sw * scaleX);
  const v = h === null ? null : tileAxis(rules[1], dh, sh * scaleY);
  if (h === null || v === null) return;
  const hx = h[0], hs = h[1], hw = h[2];
  const vy = v[0], vs = v[1], vh = v[2];
  const x0 = dx + hx, y0 = dy + vy;
  const i0 = Math.floor((-hx - hw) / hs) + 1, i1 = Math.ceil((dw - hx) / hs) - 1;
  const j0 = Math.floor((-vy - vh) / vs) + 1, j1 = Math.ceil((dh - vy) / vs) - 1;
  hostClipPush(el.serial, P.PK_CLIP_RECT, dx, dy, dw, dh, 0);
  for (let j = j0; j <= j1; j++) {
    for (let i = i0; i <= i1; i++) {
      drawSlice(el, source, gradient, iw, ih, sx, sy, sw, sh, x0 + i * hs, y0 + j * vs, hw, vh,
        opacity);
    }
  }
  hostClipPop();
}

/**
 * Paints an element's border image over its border box (x, y, w, h), out to the outsets.
 * `first`/`last` say whether a broken inline box draws its left/right sides here.
 */
export function paintBorderImage(el: Node, x: number, y: number, w: number, h: number,
  opacity: number, first: boolean, last: boolean): void {
  const source = el.sv[P.P_BORDER_IMAGE_SOURCE];
  if (source === -1) return;
  const gradient = gradientOf(source);
  let iw = 0, ih = 0;
  if (gradient === null) {
    // An SVG without a size of its own — one that only has a viewBox, or that gives its width or
    // height as a percentage — measures against the border image area like a gradient does; a
    // slice number then counts pixels of that area.
    const svg = svgProgramFor(source);
    if (svg === null || svg.has === 3) {
      const size = imageFileSize(source, orientedImage(el));
      iw = size[0];
      ih = size[1];
    }
  }
  const o = outsets(el, w, h);
  const bx = x - (first ? o[3] : 0), by = y - o[0];
  const bw = w + (first ? o[3] : 0) + (last ? o[1] : 0), bh = h + o[0] + o[2];
  if (!(bw > 0) || !(bh > 0)) return;
  // An image with no size of its own — a gradient, or an SVG that only has a viewBox — is
  // measured against the border image area, as CSS Images' default object size says.
  if (!(iw > 0) || !(ih > 0)) { iw = bw; ih = bh; }
  const sl = sliceFractions(el, iw, ih);
  let widths = bandWidths(el, iw, ih, bw, bh, sl);
  // Opposite bands that would overlap are scaled down together, keeping the picture's shape.
  const kx = widths[1] + widths[3] > bw ? bw / (widths[1] + widths[3]) : 1;
  const ky = widths[0] + widths[2] > bh ? bh / (widths[0] + widths[2]) : 1;
  const k = Math.min(kx, ky);
  if (k < 1) widths = widths.map((v) => v * k);
  const [wt, wr, wb, wl] = widths;
  const sx = [0, sl[3] * iw, iw - sl[1] * iw];
  const sy = [0, sl[0] * ih, ih - sl[2] * ih];
  const sw = [sl[3] * iw, iw - (sl[1] + sl[3]) * iw, sl[1] * iw];
  const sh = [sl[0] * ih, ih - (sl[0] + sl[2]) * ih, sl[2] * ih];
  const dx = [bx, bx + wl, bx + bw - wr];
  const dy = [by, by + wt, by + bh - wb];
  const dw = [wl, bw - wl - wr, wr];
  const dh = [wt, bh - wt - wb, wb];
  const rep = repeatOf(el);
  // How far each band scales its slice. A band with nothing to show — a slice of zero, or a
  // width of zero — has no scale of its own, and 1 stands in for it.
  const scaleOf = (slice: number, band: number): number => (slice > 0 && band > 0 ? band / slice : 1);
  const topScale = scaleOf(sl[0] * ih, wt);
  const bottomScale = scaleOf(sl[2] * ih, wb);
  const leftScale = scaleOf(sl[3] * iw, wl);
  const rightScale = scaleOf(sl[1] * iw, wr);
  // The middle first, so the edges and corners paint over its stray ends. Its tiling scale comes
  // from the bands beside it rather than its own: across from the top band (or the bottom), and
  // down from the left band (or the right), which is what keeps a repeated middle lined up with
  // the corners.
  if (sl[4] !== 0) {
    const top = sl[0] > 0 && wt > 0, bottom = sl[2] > 0 && wb > 0;
    const left = sl[3] > 0 && wl > 0, right = sl[1] > 0 && wr > 0;
    const mx = rep[0] === P.BI_STRETCH ? 1 : top ? topScale : bottom ? bottomScale : 1;
    const my = rep[1] === P.BI_STRETCH ? 1 : left ? leftScale : right ? rightScale : 1;
    drawPiece(el, source, gradient, iw, ih, sx[1], sy[1], sw[1], sh[1], dx[1], dy[1], dw[1], dh[1],
      rep, mx, my, opacity);
  }
  for (let c = 0; c < 3; c++) {
    for (let r = 0; r < 3; r++) {
      if (c === 1 && r === 1) continue;
      const horizontal = c === 1;
      const vertical = r === 1;
      if (horizontal || vertical) {
        // An edge: tiled along its length, stretched across the band.
        const scale = horizontal ? (r === 0 ? topScale : bottomScale) : (c === 0 ? leftScale : rightScale);
        const rules = horizontal ? [rep[0], P.BI_STRETCH] : [P.BI_STRETCH, rep[1]];
        drawPiece(el, source, gradient, iw, ih, sx[c], sy[r], sw[c], sh[r], dx[c], dy[r], dw[c], dh[r],
          rules, scale, scale, opacity);
      } else {
        drawSlice(el, source, gradient, iw, ih, sx[c], sy[r], sw[c], sh[r], dx[c], dy[r], dw[c], dh[r], opacity);
      }
    }
  }
}
