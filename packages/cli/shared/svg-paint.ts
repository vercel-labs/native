// SVG paint servers: a `fill` or `stroke` may be `url(#id)`, naming a linear or radial gradient
// instead of a colour. The runtime (for an inline <svg>) and the compiler (for an SVG file used
// as an image) both read a gradient's attributes through this module, so the two paint the same
// picture.
//
// A gradient is read into its own coordinate space: the coordinates the attributes give, after
// percentages are resolved, and the `gradientTransform` that maps that space into the element's.
// Where the space sits in the element is `gradientUnits`: objectBoundingBox puts the unit square
// over the shape's bounding box, userSpaceOnUse puts it in the element's user space.
//
// Not read yet: `spreadMethod` other than the default `pad`, and `fx`/`fy` on a focal circle that
// lies outside the end circle.

import * as P from "./props.ts";
import { parseColor } from "./css/colors.ts";
import { type AttrGet, num, parseTransform, IDENTITY } from "./svg.ts";

/** A paint value that names a paint server: PAINT_URL - index into the app's paint URL table. */
export function paintUrlValue(index: number): number {
  return P.PAINT_URL - index;
}

/** The paint URL table index a fill/stroke value refers to (call only when isPaintUrl). */
export function paintUrlIndex(value: number): number {
  return P.PAINT_URL - value;
}

/** Whether a fill/stroke value names a paint server rather than a colour. */
export function isPaintUrl(value: number): boolean {
  return value <= P.PAINT_URL;
}

/** A paint in an image's draw program that names a gradient: PAINT_GRADIENT - its index. */
export const PAINT_GRADIENT = -1000;

/** One parsed gradient, in its own space. */
export interface SvgGradient {
  /** 0 linear, 1 radial. */
  kind: number;
  /** 1 when the coordinates are the element's user units, 0 when they are bbox fractions. */
  userSpace: number;
  /** Linear: x1, y1, x2, y2. Radial: cx, cy, r, fx, fy. In the gradient's own space. */
  c: number[];
  /** gradientTransform: the gradient's space into the element's user space. */
  transform: number[];
  /** stop colours (packed 0xRRGGBBAA, stop-opacity baked in) and offsets, as pairs. */
  stops: number[];
}

/** How a caller finds a gradient by id in its document. */
export interface GradientLookup {
  /** The kind (0 linear, 1 radial) of the element with this id, or null when it has none. */
  kind(id: string): number | null;
  /** The attributes of the element with this id, or null. */
  attrs(id: string): AttrGet | null;
  /** The <stop> children of the element with this id. */
  stops(id: string): AttrGet[];
}

/** One attribute of a style="" attribute's declarations, or null. */
function styleProp(get: AttrGet, name: string): string | null {
  const style = get("style");
  if (style === null) return null;
  for (const decl of style.split(";")) {
    const cut = decl.indexOf(":");
    if (cut < 0) continue;
    if (decl.slice(0, cut).trim().toLowerCase() === name) return decl.slice(cut + 1).trim();
  }
  return null;
}

/** An attribute, falling back to the same property in style="". */
function prop(get: AttrGet, name: string): string | null {
  const v = get(name);
  return v !== null && v.trim() !== "" ? v : styleProp(get, name);
}

/** A length in a gradient's own space: a percentage against `base` (1 for bbox units). */
function coord(raw: string | null, base: number): number {
  if (raw === null) return 0;
  const s = raw.trim();
  if (s.endsWith("%")) return num(s.slice(0, -1)) / 100 * base;
  return num(s);
}

/**
 * Reads the gradient with this id, whose kind is `kind` (0 linear, 1 radial). `href` references
 * inherit whatever the element itself doesn't set, including the stops. `vw`/`vh` are the SVG
 * viewport's size, which userSpaceOnUse percentages resolve against.
 */
export function parseGradient(kind: number, id: string, lookup: GradientLookup,
  vw: number, vh: number): SvgGradient | null {
  const first = lookup.attrs(id);
  if (first === null) return null;
  // The element first, then whatever each href names in turn.
  const chain: string[] = [id];
  let attrs = first;
  for (let depth = 0; depth < 16; depth++) {
    const href = attrs("href") ?? attrs("xlink:href");
    if (href === null) break;
    const nextId = href.trim().replace(/^#/, "");
    if (nextId === "") break;
    const next = lookup.attrs(nextId);
    if (next === null) break;
    chain.push(nextId);
    attrs = next;
  }
  const attr = (name: string): string | null => {
    for (const at of chain) {
      const a = lookup.attrs(at);
      if (a === null) continue;
      const v = prop(a, name);
      if (v !== null && v.trim() !== "") return v;
    }
    return null;
  };
  const userSpace = (attr("gradientunits") ?? "").trim().toLowerCase() === "userspaceonuse" ? 1 : 0;
  const diag = Math.sqrt((vw * vw + vh * vh) / 2);
  const c: number[] = [];
  if (kind === 0) {
    c.push(coord(attr("x1") ?? "0%", userSpace ? vw : 1), coord(attr("y1") ?? "0%", userSpace ? vh : 1),
      coord(attr("x2") ?? "100%", userSpace ? vw : 1), coord(attr("y2") ?? "0%", userSpace ? vh : 1));
  } else {
    const cx = coord(attr("cx") ?? "50%", userSpace ? vw : 1);
    const cy = coord(attr("cy") ?? "50%", userSpace ? vh : 1);
    const r = coord(attr("r") ?? "50%", userSpace ? diag : 1);
    const fx = attr("fx") === null ? cx : coord(attr("fx"), userSpace ? vw : 1);
    const fy = attr("fy") === null ? cy : coord(attr("fy"), userSpace ? vh : 1);
    c.push(cx, cy, r, fx, fy);
  }
  const transform = attr("gradienttransform");
  // The first element in the chain with stops gives the gradient its stops.
  let stopEls: AttrGet[] = [];
  for (const at of chain) {
    const list = lookup.stops(at);
    if (list.length > 0) { stopEls = list; break; }
  }
  const stops: number[] = [];
  let last = 0;
  for (const stop of stopEls) {
    const raw = prop(stop, "offset");
    let off = raw === null ? 0 : raw.trim().endsWith("%") ? num(raw) / 100 : num(raw);
    off = Math.max(0, Math.min(1, off));
    if (off < last) off = last;
    last = off;
    const rawColor = prop(stop, "stop-color");
    let color = rawColor === null ? 0x000000ff : parseColor(rawColor.trim());
    if (color === null) color = 0x000000ff;
    const op = prop(stop, "stop-opacity");
    const o = op === null ? 1 : Math.max(0, Math.min(1, num(op)));
    const a = color & 255;
    const alpha = Math.round(a * o);
    stops.push(((color & 0xffffff00) + alpha) >>> 0, off);
  }
  if (stops.length === 0) return null;
  return { kind, userSpace, c, transform: transform === null ? IDENTITY : parseTransform(transform), stops };
}

/** The matrix a gradient's own space maps through into the element's user space. */
export function gradientMatrix(g: SvgGradient, bbox: number[]): number[] {
  const t = g.transform;
  if (g.userSpace !== 0) return t;
  // objectBoundingBox: the unit square over the bounding box, then gradientTransform.
  const b = [bbox[2], 0, 0, bbox[3], bbox[0], bbox[1]];
  return [
    b[0] * t[0] + b[2] * t[1],
    b[1] * t[0] + b[3] * t[1],
    b[0] * t[2] + b[2] * t[3],
    b[1] * t[2] + b[3] * t[3],
    b[0] * t[4] + b[2] * t[5] + b[4],
    b[1] * t[4] + b[3] * t[5] + b[5],
  ];
}

/** The bounding box [x, y, w, h] of a path's points, control points included. */
export function bboxOf(ops: number[]): number[] {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  let i = 0;
  while (i < ops.length) {
    const op = ops[i];
    if (op === 1 || op === 2) {
      if (ops[i + 1] < x0) x0 = ops[i + 1];
      if (ops[i + 1] > x1) x1 = ops[i + 1];
      if (ops[i + 2] < y0) y0 = ops[i + 2];
      if (ops[i + 2] > y1) y1 = ops[i + 2];
      i += 3;
    } else if (op === 3) {
      for (let k = 1; k < 5; k += 2) {
        if (ops[i + k] < x0) x0 = ops[i + k];
        if (ops[i + k] > x1) x1 = ops[i + k];
        if (ops[i + k + 1] < y0) y0 = ops[i + k + 1];
        if (ops[i + k + 1] > y1) y1 = ops[i + k + 1];
      }
      i += 5;
    } else if (op === 4) {
      for (let k = 1; k < 7; k += 2) {
        if (ops[i + k] < x0) x0 = ops[i + k];
        if (ops[i + k] > x1) x1 = ops[i + k];
        if (ops[i + k + 1] < y0) y0 = ops[i + k + 1];
        if (ops[i + k + 1] > y1) y1 = ops[i + k + 1];
      }
      i += 7;
    } else {
      i++;
    }
  }
  if (!(x1 >= x0) || !(y1 >= y0)) return [0, 0, 0, 0];
  return [x0, y0, x1 - x0, y1 - y0];
}
