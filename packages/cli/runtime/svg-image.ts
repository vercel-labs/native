// SVG images: a file referenced by <img src> or a CSS url() is compiled into a draw program at
// build time (see compiler/svg-image.ts) and replayed here into a bitmap of its own, sized in
// device pixels the way an inline <svg> rasterizes. A paint draws that bitmap where the image
// goes, so an SVG is the same picture whether it is inline or a file.
//
// Program layout:
//   0 width, 1 height        the image's default object size in CSS px
//   2 has, 3 hasViewBox, 4..7 viewBox, 8 align, 9 slice
// `has` says which of the two dimensions the file gives itself: 1 height, 2 width, 3 both, 0
// neither (a percentage attribute, or none at all).
//   10 record count, 11 gradient count
// then each gradient: kind, user-space flag, five coordinates, six matrix numbers, stop count and
// its stops,
// then each record, whose first number is its kind:
//   0 shape: matrix a b c d e f, fill, stroke, stroke width, cap, join, dash count, dash offset,
//     the dash lengths, fill rule, alpha, clip count, one record per clip (its rule, operation
//     count and operations), path operation count, and the path operations (see shared/svg.ts).
//   1 text: matrix a b c d e f, alpha, anchor, clip count, the clip records, the number of pieces
//     of text, and for each piece: a flag and its x, a flag and its y, dx, dy, font size, font
//     key, fill, stroke, stroke width, alpha, the number of characters and their code points.
//     The runtime lays the pieces out along the baseline itself, since only it can measure
//     glyphs (see shared/svg-text.ts).
// A fill/stroke that is PAINT_GRADIENT - i paints with gradient i; the stops carry the fill's
// own opacity, and the record's alpha is applied when it is drawn. Clip operations are already
// in the record's own user space, so the runtime clips and draws under one transform.

import { rasterScale } from "./device.ts";
import {
  hostCanvasCreate, hostCanvasResize, hostCanvasSetTransform, hostCanvasBeginPath,
  hostCanvasMoveTo, hostCanvasLineTo, hostCanvasQuadraticTo, hostCanvasBezierTo, hostCanvasClosePath,
  hostCanvasFill, hostCanvasStroke, hostCanvasSetFillColor, hostCanvasSetStrokeColor,
  hostCanvasSetLineWidth, hostCanvasSetLineCap, hostCanvasSetLineJoin, hostCanvasSetLineDash,
  hostCanvasSave, hostCanvasRestore, hostCanvasClip, hostCanvasClearRect, hostCanvasDraw,
  hostMeasureText, hostCanvasSetFont, hostCanvasFillText, hostCanvasStrokeText,
  hostCanvasDrawPart,
} from "./host.ts";
import * as P from "../shared/props.ts";
import { emitPath, viewMatrix, mul, IDENTITY, type PathSink } from "../shared/svg.ts";
import { layoutText, type TextPiece } from "../shared/svg-text.ts";
import { bboxOf, PAINT_GRADIENT, type SvgGradient } from "../shared/svg-paint.ts";
import { drawGradient } from "./svg-paint.ts";

/** One compiled SVG image, parsed and given a bitmap the first time it is drawn. */
export interface SvgProgram {
  w: number;
  h: number;
  /** Which of w and h the file gives itself: 0 neither, 1 height, 2 width, 3 both. */
  has: number;
  view: number[] | null;
  align: number;
  slice: boolean;
  records: number;
  /** The gradients the picture paints with (see shared/svg-paint.ts). */
  gradients: SvgGradient[];
  /** Where the shape records start in `data`, after the header and the gradient table. */
  recordsAt: number;
  data: number[];
  /** The host bitmap the program was last rasterized into, and its size in pixels. */
  canvas: number;
  pixelsW: number;
  pixelsH: number;
}

/** Parses a compiled program; null for the empty string (an image that isn't an SVG). */
export function parseSvgProgram(program: string): SvgProgram | null {
  if (program === "") return null;
  const data = program.split(",").map(Number);
  if (data.length < 12) return null;
  const hasView = data[3] !== 0;
  const gradients: SvgGradient[] = [];
  let i = 12;
  for (let n = 0; n < data[11] && i + 14 <= data.length; n++) {
    const kind = data[i];
    const userSpace = data[i + 1];
    const c = data.slice(i + 2, i + 7);
    const transform = data.slice(i + 7, i + 13);
    const stops = data[i + 13] * 2;
    gradients.push({ kind, userSpace, c, transform, stops: data.slice(i + 14, i + 14 + stops) });
    i += 14 + stops;
  }
  return {
    w: data[0], h: data[1], has: data[2],
    view: hasView ? [data[4], data[5], data[6], data[7]] : null,
    align: data[8], slice: data[9] !== 0, records: data[10], gradients, recordsAt: i,
    data, canvas: -1, pixelsW: 0, pixelsH: 0,
  };
}

// The host path calls are the sink a record's path operations replay into; the id is the bitmap
// being drawn into at the time.
let sinkId = -1;
const sink: PathSink = {
  moveTo: (x, y) => hostCanvasMoveTo(sinkId, x, y),
  lineTo: (x, y) => hostCanvasLineTo(sinkId, x, y),
  quadraticTo: (cx, cy, x, y) => hostCanvasQuadraticTo(sinkId, cx, cy, x, y),
  bezierTo: (c1x, c1y, c2x, c2y, x, y) => hostCanvasBezierTo(sinkId, c1x, c1y, c2x, c2y, x, y),
  close: () => hostCanvasClosePath(sinkId),
};

/** A colour with its alpha multiplied by `alpha`, as the paint properties hold it. */
function withAlpha(color: number, alpha: number): number {
  const a = color & 255;
  return (color & 0xffffff00) + Math.max(0, Math.min(255, Math.round(a * Math.max(0, Math.min(1, alpha)))));
}

/**
 * Draws the text record starting at `i` and returns the index just past it. Its pieces are laid
 * out along the baseline here rather than in the program, because only the host can measure
 * glyphs; the record's matrix carries the image's view and device scale, so a font size in user
 * units scales with the picture as it should.
 */
function drawTextRecord(p: SvgProgram, i: number, m: number[], alpha: number): number {
  const t = mul(m, [p.data[i], p.data[i + 1], p.data[i + 2], p.data[i + 3], p.data[i + 4], p.data[i + 5]]);
  const a = p.data[i + 6], anchor = p.data[i + 7], clipCount = p.data[i + 8];
  let at = i + 9;
  const clips: { rule: number; ops: number[] }[] = [];
  for (let k = 0; k < clipCount; k++) {
    const rule = p.data[at], n = p.data[at + 1];
    clips.push({ rule, ops: p.data.slice(at + 2, at + 2 + n) });
    at += 2 + n;
  }
  const count = p.data[at];
  at++;
  const pieces: TextPiece[] = [];
  for (let k = 0; k < count; k++) {
    const x = p.data[at + 1], y = p.data[at + 3];
    const chars = p.data[at + 12];
    let text = "";
    for (let c = 0; c < chars; c++) text += String.fromCodePoint(p.data[at + 13 + c]);
    pieces.push({
      text, x: p.data[at] !== 0 ? x : null, y: p.data[at + 2] !== 0 ? y : null,
      dx: p.data[at + 4], dy: p.data[at + 5], size: p.data[at + 6], font: p.data[at + 7],
      fill: p.data[at + 8], stroke: p.data[at + 9], width: p.data[at + 10],
      fillAlpha: p.data[at + 11], strokeAlpha: p.data[at + 11],
    });
    at += 13 + chars;
  }
  const runs = layoutText(pieces, anchor, (text, size, font) => hostMeasureText(text, size, font, 0, 0));
  if (runs.length === 0) return at;
  const id = p.canvas;
  if (clipCount > 0) hostCanvasSave(id);
  hostCanvasSetTransform(id, t[0], t[1], t[2], t[3], t[4], t[5]);
  if (clipCount > 0) {
    sinkId = id;
    for (const clip of clips) {
      hostCanvasBeginPath(id);
      emitPath(clip.ops, sink);
      hostCanvasClip(id, clip.rule);
    }
  }
  for (const run of runs) {
    hostCanvasSetFont(id, run.size, run.font);
    if (run.fill >= 0 && run.fillAlpha > 0) {
      hostCanvasSetFillColor(id, withAlpha(run.fill, alpha * a * run.fillAlpha));
      hostCanvasFillText(run.text, id, run.x, run.y, 0);
    }
    if (run.stroke >= 0 && run.width > 0 && run.strokeAlpha > 0) {
      hostCanvasSetStrokeColor(id, withAlpha(run.stroke, alpha * a * run.strokeAlpha));
      hostCanvasSetLineWidth(id, run.width);
      hostCanvasSetLineCap(id, P.SLC_BUTT);
      hostCanvasSetLineJoin(id, P.SLJ_MITER);
      hostCanvasSetLineDash(id, "");
      hostCanvasStrokeText(run.text, id, run.x, run.y, 0);
    }
  }
  if (clipCount > 0) hostCanvasRestore(id);
  return at;
}

/**
 * Draws the image as the content of the box (x, y, w, h) in CSS px. The picture is rasterized at
 * the box's size in device pixels, so it stays sharp at any used size; one bitmap per image is
 * kept and resized when that size changes.
 */
export function drawSvgProgram(p: SvgProgram, x: number, y: number, w: number, h: number,
  alpha: number, smooth: number): void {
  const id = rasterizeSvg(p, w, h, alpha);
  if (id < 0) return;
  hostCanvasDraw(id, x, y, w, h, alpha, smooth);
}

/**
 * Draws the part of the picture within the source rect, in CSS px of an image w × h, into the
 * destination rect — one slice of a border image. The picture is rasterized once at the image's
 * own size and the region is cut from that bitmap, so the slice's own axes may scale it by
 * different amounts, as cutting a raster image does.
 */
export function drawSvgPart(p: SvgProgram, w: number, h: number, sx: number, sy: number,
  sw: number, sh: number, x: number, y: number, dw: number, dh: number,
  alpha: number, smooth: number): void {
  const id = rasterizeSvg(p, w, h, alpha);
  if (id < 0 || !(dw > 0) || !(dh > 0)) return;
  // The bitmap is the image at the backing scale, so a region in CSS px scales by the same.
  const k = w > 0 ? p.pixelsW / w : 1;
  hostCanvasDrawPart(id, x, y, dw, dh, sx * k, sy * k, sw * k, sh * k, alpha, smooth);
}

/** Whether the picture renders at all: a viewBox with a zero width or height disables rendering
 *  of the element (SVG 1.1 §7.7), so it paints nothing whatever size it is given. */
function renderable(p: SvgProgram): boolean {
  return p.view === null || (p.view[2] > 0 && p.view[3] > 0);
}

/** The matrix taking the picture's user units to a box w × h CSS px. A viewBox takes the picture's
 *  user units to the box; without one the user units are the file's own viewport — the size it
 *  gives itself, or the 300 by 150 default — and drawing it at another size scales each axis by
 *  the box's share of it, as a browser does: a `width="8px"` rectangle in an 8 by 32 file paints
 *  192 px wide in a 192 by 768 box. */
function fitMatrix(p: SvgProgram, w: number, h: number): number[] {
  const kx = p.w > 0 ? w / p.w : 1, ky = p.h > 0 ? h / p.h : 1;
  return p.view !== null ? viewMatrix(p.view, w, h, p.align, p.slice) : [kx, 0, 0, ky, 0, 0];
}

/** Rasterizes the picture as an image w × h CSS px, returning its canvas id (-1 if empty). */
function rasterizeSvg(p: SvgProgram, w: number, h: number, alpha: number): number {
  if (!(w > 0) || !(h > 0) || !renderable(p)) return -1;
  return rasterizeFitted(p, fitMatrix(p, w, h), w, h, alpha);
}

/**
 * Draws the part of the picture inside the window (wx, wy, ww, wh) of the size w × h it is drawn
 * at — a window in the image's own space, from its top-left corner — into the rect (x, y, ww, wh)
 * of the page: the part of a tile far larger than the page that can be seen. Only the window is
 * rasterized, so the picture is as sharp there as at any other size.
 */
export function drawSvgWindow(p: SvgProgram, w: number, h: number, wx: number, wy: number,
  ww: number, wh: number, x: number, y: number, alpha: number, smooth: number): void {
  if (!(ww > 0) || !(wh > 0) || !renderable(p)) return;
  const base = fitMatrix(p, w, h);
  // The window is a shift of the picture's own space: its corner becomes the bitmap's.
  const fit = [base[0], base[1], base[2], base[3], base[4] - wx, base[5] - wy];
  const id = rasterizeFitted(p, fit, ww, wh, alpha);
  if (id < 0) return;
  hostCanvasDraw(id, x, y, ww, wh, alpha, smooth);
}

// The largest bitmap one picture is rasterized into. An image can be drawn far larger than any
// screen — a `cover` fit of a picture whose ratio is extreme is millions of pixels tall — and the
// bitmap only has to hold the picture at a resolution the screen can show, so it is rendered
// smaller and scaled up as it is drawn, which keeps the picture's own mapping.
const MAX_BITMAP_SIDE = 8192;
const MAX_BITMAP_PIXELS = 8192 * 4096;

/** Rasterizes the picture with `fit` taking its user units to the box's CSS px. */
function rasterizeFitted(p: SvgProgram, fit: number[], w: number, h: number, alpha: number): number {
  const scale = rasterScale();
  let pw = Math.max(1, Math.ceil(w * scale));
  let ph = Math.max(1, Math.ceil(h * scale));
  // A picture bigger than the largest bitmap is rasterized at a fraction of its box, with the fit
  // matrix scaled by the same fraction so the bitmap still holds the whole picture.
  const shrink = Math.min(1, MAX_BITMAP_SIDE / pw, MAX_BITMAP_SIDE / ph, Math.sqrt(MAX_BITMAP_PIXELS / (pw * ph)));
  if (shrink < 1) {
    pw = Math.max(1, Math.ceil(pw * shrink));
    ph = Math.max(1, Math.ceil(ph * shrink));
    fit = [fit[0] * shrink, fit[1] * shrink, fit[2] * shrink, fit[3] * shrink, fit[4] * shrink, fit[5] * shrink];
  }
  if (p.canvas < 0) {
    p.canvas = hostCanvasCreate(pw, ph);
  } else if (pw !== p.pixelsW || ph !== p.pixelsH) {
    hostCanvasResize(p.canvas, pw, ph);
  }
  p.pixelsW = pw;
  p.pixelsH = ph;
  const id = p.canvas;
  // The clear is in canvas space, so the identity transform restores it after the last pass's
  // per-shape transforms.
  hostCanvasSetTransform(id, 1, 0, 0, 1, 0, 0);
  hostCanvasClearRect(id, 0, 0, pw, ph);
  // The picture's user units map into the box's CSS px; the device scale then makes them pixels.
  const m: number[] = mul([scale, 0, 0, scale, 0, 0], fit);
  sinkId = id;
  let i = p.recordsAt;
  for (let r = 0; r < p.records && i + 1 < p.data.length; r++) {
    const kind = p.data[i];
    i++;
    if (kind === 1) {
      i = drawTextRecord(p, i, m, alpha);
      continue;
    }
    const fill = p.data[i + 6], stroke = p.data[i + 7], width = p.data[i + 8];
    const cap = p.data[i + 9], join = p.data[i + 10];
    const dashCount = p.data[i + 11], dashOffset = p.data[i + 12];
    const at = i + 13 + dashCount;
    const rule = p.data[at], a = p.data[at + 1];
    const clipCount = p.data[at + 2];
    // Each clip path is one path in this shape's own user space, and the nested clips are
    // intersected in the order they are written.
    let clipAt = at + 3;
    const clips: { rule: number; ops: number[] }[] = [];
    for (let k = 0; k < clipCount; k++) {
      const rule = p.data[clipAt], n = p.data[clipAt + 1];
      clips.push({ rule, ops: p.data.slice(clipAt + 2, clipAt + 2 + n) });
      clipAt += 2 + n;
    }
    const count = p.data[clipAt];
    // The record carries its dash lengths in user units, so the host scales them with the pen.
    let dash = "";
    if (dashCount > 0) {
      dash = String(dashOffset);
      for (let k = 0; k < dashCount; k++) dash += " " + p.data[i + 13 + k];
    }
    const t = mul(m, [p.data[i], p.data[i + 1], p.data[i + 2], p.data[i + 3], p.data[i + 4], p.data[i + 5]]);
    i = clipAt + 1;
    const ops = p.data.slice(i, i + count);
    i += count;
    if (ops.length === 0) continue;
    const evenOdd = rule === P.FR_EVENODD ? 1 : 0;
    const gradient = (paint: number): SvgGradient | null =>
      paint <= PAINT_GRADIENT ? p.gradients[PAINT_GRADIENT - paint] ?? null : null;
    const gFill = gradient(fill), gStroke = gradient(stroke);
    if (clipCount > 0) hostCanvasSave(id);
    hostCanvasSetTransform(id, t[0], t[1], t[2], t[3], t[4], t[5]);
    if (clipCount > 0) {
      sinkId = id;
      for (const clip of clips) {
        hostCanvasBeginPath(id);
        emitPath(clip.ops, sink);
        hostCanvasClip(id, clip.rule);
      }
    }
    hostCanvasBeginPath(id);
    emitPath(ops, sink);
    if (gFill !== null) {
      drawGradient(id, gFill, bboxOf(ops), t, alpha * a, false, evenOdd);
    } else if (fill >= 0) {
      hostCanvasSetFillColor(id, withAlpha(fill, alpha * a));
      hostCanvasFill(id, evenOdd);
    }
    if (gStroke !== null && width > 0) {
      if (drawGradient(id, gStroke, bboxOf(ops), t, alpha * a, true, evenOdd)) {
        hostCanvasSetLineWidth(id, width);
        hostCanvasSetLineCap(id, cap);
        hostCanvasSetLineJoin(id, join);
        hostCanvasSetLineDash(id, dash);
        hostCanvasStroke(id);
      }
    } else if (stroke >= 0 && width > 0) {
      hostCanvasSetStrokeColor(id, withAlpha(stroke, alpha * a));
      hostCanvasSetLineWidth(id, width);
      hostCanvasSetLineCap(id, cap);
      hostCanvasSetLineJoin(id, join);
      hostCanvasSetLineDash(id, dash);
      hostCanvasStroke(id);
    }
    if (clipCount > 0) hostCanvasRestore(id);
  }
  return id;
}
