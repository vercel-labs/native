// SVG paint servers at runtime: a fill/stroke that is `url(#id)` names a gradient in the document,
// which is read here and drawn into the host canvas. The inline <svg> painter and the SVG-image
// painter both come through drawGradient, so a gradient looks the same in a file as on the page.
//
// The host draws a gradient in the user space of the transform in effect when it paints, so the
// gradient's coordinates are carried from its own space into that one first (see gradientMatrix
// in shared/svg-paint.ts). A radial gradient's circles can only be circular in that space, so a
// non-uniform transform is drawn with the average scale for a stroke, and through its own
// transform for a fill (which clips to the shape and fills under it, keeping the ellipse).

import {
  hostCanvasClip, hostCanvasFill, hostCanvasFillRect, hostCanvasRestore, hostCanvasSave,
  hostCanvasSetFillGradient, hostCanvasSetStrokeGradient, hostCanvasSetTransform,
} from "./host.ts";
import { applyPoint, invert, mul } from "../shared/svg.ts";
import {
  gradientMatrix, paintUrlIndex, parseGradient, type GradientLookup, type SvgGradient,
} from "../shared/svg-paint.ts";

// The paint URL table (SVG_PAINT_URLS): a paint value names a server by its index. The runtime
// appends the URLs a style="" attribute names, which a script can write at any time.
let urls: string[] = [];
const extra: string[] = [];

/** Installs the compiled paint URL table. */
export function setPaintUrls(list: string[]): void {
  urls = list.slice();
  extra.length = 0;
}

/** The id a paint value names, or null when the index isn't in the table. */
export function paintUrlAt(index: number): string | null {
  if (index < urls.length) return urls[index];
  const at = index - urls.length;
  return at < extra.length ? extra[at] : null;
}

/** The paint URL table index for an id, adding it when it isn't there yet. */
export function registerPaintUrl(id: string): number {
  const hit = urls.indexOf(id);
  if (hit >= 0) return hit;
  const at = extra.indexOf(id);
  if (at >= 0) return urls.length + at;
  extra.push(id);
  return urls.length + extra.length - 1;
}

/** Reads the gradient a fill/stroke value names; null when the server is missing or isn't one. */
export function resolveGradient(value: number, lookup: GradientLookup, vw: number, vh: number): SvgGradient | null {
  const id = paintUrlAt(paintUrlIndex(value));
  if (id === null) return null;
  const kind = lookup.kind(id);
  if (kind === null) return null;
  return parseGradient(kind, id, lookup, vw, vh);
}

/** A colour with its alpha multiplied by `alpha`. */
function withAlpha(color: number, alpha: number): number {
  const a = color & 255;
  return (color & 0xffffff00) + Math.max(0, Math.min(255, Math.round(a * Math.max(0, Math.min(1, alpha)))));
}

/** The stops of a host gradient definition, each colour's alpha scaled by `alpha`. */
function stopText(stops: number[], alpha: number): string {
  let out = "";
  for (let i = 0; i + 1 < stops.length; i += 2) out += ";" + withAlpha(stops[i], alpha) + "," + stops[i + 1];
  return out;
}

function num(v: number): string {
  return String(Math.round(v * 1e6) / 1e6);
}

/**
 * Draws a gradient into `canvas` for the path it holds, which is in the current transform's user
 * space. `bbox` is the path's bounding box in that space (objectBoundingBox gradients use it),
 * `m` the transform, and `alpha` the opacity to paint with. Returns false when the gradient has
 * nothing to paint, so the caller can fall back to no paint at all.
 */
export function drawGradient(canvas: number, g: SvgGradient, bbox: number[], m: number[],
  alpha: number, stroke: boolean, rule: number): boolean {
  if (g.stops.length === 0 || !(alpha > 0)) return false;
  const space = gradientMatrix(g, bbox);
  if (g.kind === 0) {
    const p1 = applyPoint(space, g.c[0], g.c[1]);
    const p2 = applyPoint(space, g.c[2], g.c[3]);
    const def = "l;" + num(p1[0]) + "," + num(p1[1]) + "," + num(p2[0]) + "," + num(p2[1]) + stopText(g.stops, alpha);
    if (stroke) {
      hostCanvasSetStrokeGradient(canvas, def);
    } else {
      hostCanvasSetFillGradient(canvas, def);
      hostCanvasFill(canvas, rule);
    }
    return true;
  }
  const r = g.c[2];
  if (!(r > 0)) {
    // A zero radius paints the last stop's colour over the whole shape.
    const last = g.stops[g.stops.length - 2];
    const def = "l;0,0,0,1;" + withAlpha(last, alpha) + ",0;" + withAlpha(last, alpha) + ",1";
    if (stroke) {
      hostCanvasSetStrokeGradient(canvas, def);
    } else {
      hostCanvasSetFillGradient(canvas, def);
      hostCanvasFill(canvas, rule);
    }
    return true;
  }
  if (!stroke) {
    // Clip to the shape, then fill across its bounding box with the gradient's own space in the
    // transform, so a scaled circle stays the ellipse the gradient asks for.
    hostCanvasSave(canvas);
    hostCanvasClip(canvas, rule);
    const t = mul(m, space);
    hostCanvasSetTransform(canvas, t[0], t[1], t[2], t[3], t[4], t[5]);
    // The host's radial definition runs from the focus circle out to the edge circle.
    hostCanvasSetFillGradient(canvas, "r;" + num(g.c[3]) + "," + num(g.c[4]) + ",0," +
      num(g.c[0]) + "," + num(g.c[1]) + "," + num(r) + stopText(g.stops, alpha));
    const back = invert(space);
    const a = applyPoint(back, bbox[0], bbox[1]);
    const b = applyPoint(back, bbox[0] + bbox[2], bbox[1] + bbox[3]);
    const x = Math.min(a[0], b[0]), y = Math.min(a[1], b[1]);
    hostCanvasFillRect(canvas, x, y, Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]));
    hostCanvasRestore(canvas);
    return true;
  }
  // A stroke's gradient is drawn in user space, where the outermost circle has to be drawn round.
  const center = applyPoint(space, g.c[0], g.c[1]);
  const focus = applyPoint(space, g.c[3], g.c[4]);
  const scale = Math.sqrt(Math.abs(space[0] * space[3] - space[1] * space[2]));
  hostCanvasSetStrokeGradient(canvas, "r;" + num(focus[0]) + "," + num(focus[1]) + ",0," +
    num(center[0]) + "," + num(center[1]) + "," + num(r * scale) + stopText(g.stops, alpha));
  return true;
}
