// Inline SVG filters: a <filter> element's primitives compiled into the compact definition the
// host applies to a bitmap. The panel is drawn without the filter first, then the host runs the
// chain over the filter region in device pixels: feGaussianBlur, feOffset, feColorMatrix,
// feBlend, feMerge, feFlood, feComposite and feDropShadow, with in/in2/result wiring, primitive
// subregions, and the filter's own units and region. Anything Chrome draws that is not here yet
// (feTile, feImage, feMorphology, feConvolveMatrix, feComponentTransfer, the lighting and
// displacement primitives) passes its input through, so a chain that names one still draws the
// rest.
//
// The host works in premultiplied RGBA with the alpha channel last. Lengths in the definition are
// device pixels measured from the filter region's top-left corner; colours are already in the
// filter's interpolation space (linear RGB unless color-interpolation-filters says sRGB).
//
// Definition grammar, one primitive per ';', fields by ',':
//   b,stdX,stdY,in,sub     gaussian blur
//   o,dx,dy,in,sub         offset
//   m,in,20 values,sub     colour matrix (rows R,G,B,A; last column an offset)
//   l,mode,in,in2,sub      blend
//   e,count,in...,sub      merge, painted in order
//   f,r,g,b,a,sub          flood
//   c,op,k1,k2,k3,k4,in,in2,sub   composite (op 0..4 over,in,out,atop,xor,5 arithmetic)
//   d,dx,dy,stdX,stdY,r,g,b,a,in,sub   drop shadow
//   t,in,sub               pass-through
// `in` is -1 SourceGraphic, -2 SourceAlpha, -3 transparent, or the index of an earlier output.

import * as P from "../shared/props.ts";
import { parseColor } from "../shared/css/colors.ts";
import type { Element } from "./dom.ts";

/** A compiled filter: the host definition, the device-pixel region it paints, and the rect the
 *  source is captured over (the region plus whatever the primitives can pull in from outside). */
export interface FilterRow {
  def: string;
  x: number;
  y: number;
  w: number;
  h: number;
  /** The source capture rect, in the same device pixels: it holds the region and the element's
   *  own box, grown by the room the primitives need to move or blur source into the region. */
  sx: number;
  sy: number;
  sw: number;
  sh: number;
  /** Whether the chain interpolates in linear RGB (Chrome's default for SVG filters). */
  linear: boolean;
}

const SOURCE = -1;
const SOURCE_ALPHA = -2;
const TRANSPARENT = -3;

/** An attribute the build parser may have lowercased, and that a script may have set in case. */
function attr(el: Element, name: string): string | null {
  return el.getAttribute(name) ?? el.getAttribute(name.toLowerCase());
}

function words(text: string): string[] {
  return text.trim().split(/[\s,]+/).filter((s) => s !== "");
}

/** A number in a filter attribute; a percentage comes back as `scale` of its value. */
function lengthOf(raw: string | null): { v: number; pct: boolean } | null {
  if (raw === null || raw.trim() === "") return null;
  const text = raw.trim();
  if (text.endsWith("%")) {
    const v = parseFloat(text.slice(0, -1));
    return Number.isFinite(v) ? { v: v / 100, pct: true } : null;
  }
  const v = parseFloat(text);
  return Number.isFinite(v) ? { v, pct: false } : null;
}

function numberAttr(el: Element, name: string, fallback: number): number {
  const raw = attr(el, name);
  if (raw === null) return fallback;
  const v = parseFloat(raw.trim());
  return Number.isFinite(v) ? v : fallback;
}

/** A primitive's flood colour: its attribute, else the computed property (whose initial is black). */
function floodColor(prim: Element, el: Element): number {
  const raw = attr(prim, "flood-color");
  if (raw !== null) {
    const parsed = parseColor(raw.trim());
    if (parsed !== null) return parsed;
    if (raw.trim().toLowerCase() === "currentcolor") return el.sv[P.P_COLOR];
  }
  return prim.sv[P.P_FLOOD_COLOR];
}

function floodOpacity(prim: Element): number {
  if (attr(prim, "flood-opacity") !== null) return opacityAttr(prim, "flood-opacity");
  return prim.sv[P.P_FLOOD_OPACITY];
}

/** A filter attribute holding an alpha: a bare number, or a percentage of one. */
function opacityAttr(el: Element, name: string): number {
  const raw = attr(el, name);
  if (raw === null) return 1;
  const v = lengthOf(raw);
  if (v === null) return 1;
  return Math.max(0, Math.min(1, v.v));
}

/** Where a filter's primitives read their lengths: the element's own user space or its bounds. */
type Units = "userspace" | "bbox";

/**
 * A length in the filter's own units, as a fraction of the bbox in each axis when the units are
 * objectBoundingBox: the pair is the x and y length in user units.
 */
function length(v: number, units: Units, axis: "x" | "y", bbox: number[]): number {
  return units === "bbox" ? v * (axis === "x" ? bbox[2] : bbox[3]) : v;
}

/** A colour as working-space r, g, b (0..255) and alpha (0..255). */
function colourParts(color: number, linear: boolean): string {
  const a = color & 255;
  const conv = (v: number): number => (linear ? linearChannel(v) : v);
  return `${round(conv((color >>> 24) & 255))},${round(conv((color >>> 16) & 255))},${round(conv((color >>> 8) & 255))},${round(a)}`;
}

/** sRGB 0..255 to linear 0..255, the transfer function a filter interpolates through. */
function linearChannel(v: number): number {
  const s = v / 255;
  const l = s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  return l * 255;
}

function round(v: number): number {
  return Math.round(v * 1000) / 1000;
}

/** A packed colour with its alpha multiplied by `opacity` (a flood's flood-opacity). */
function withOpacity(color: number, opacity: number): number {
  const a = (color & 255) * Math.max(0, Math.min(1, opacity));
  return (color & 0xffffff00) + Math.round(a);
}

/** A number as the host's definition takes it: a non-finite length (an overflowing attribute)
 *  becomes 0 and a huge one is clamped, so no field can drive the host's index arithmetic. */
function f(v: number): string {
  if (!Number.isFinite(v)) return "0";
  if (v > 1e9) v = 1e9;
  else if (v < -1e9) v = -1e9;
  return String(round(v));
}

/**
 * A user-space vector (a filter primitive's dx/dy) in device pixels: the element's transform turns
 * it, so a rotated shadow moves the way the element does. Percentages resolve against the viewport
 * in user units, and objectBoundingBox lengths against the element's own bounds.
 */
function deviceVector(dx: { v: number; pct: boolean }, dy: { v: number; pct: boolean },
  units: Units, bbox: number[], m: number[], vw: number, vh: number): [number, number] {
  let ux = dx.v, uy = dy.v;
  if (units === "bbox") {
    ux *= bbox[2];
    uy *= bbox[3];
  } else {
    if (dx.pct) ux *= vw;
    if (dy.pct) uy *= vh;
  }
  return [m[0] * ux + m[2] * uy, m[1] * ux + m[3] * uy];
}

/** A <filter> and the filters it inherits attributes and primitives from by href. */
function filterChain(el: Element, lookup: (id: string) => Element | undefined): Element[] {
  const chain: Element[] = [el];
  for (let d = 0; d < 8; d++) {
    const last = chain[chain.length - 1];
    const href = attr(last, "href") ?? attr(last, "xlink:href");
    if (href === null) break;
    const id = href.trim().replace(/^#/, "");
    const next = lookup(id);
    if (next === undefined || chain.indexOf(next) >= 0) break;
    chain.push(next);
  }
  return chain;
}

function chainAttr(chain: Element[], name: string): string | null {
  for (const e of chain) {
    const v = attr(e, name);
    if (v !== null && v.trim() !== "") return v;
  }
  return null;
}

/** The first element of the chain that holds the primitives. */
function primitivesOwner(chain: Element[]): Element {
  for (const e of chain) {
    if (e.kids.some((k) => k.isElementNode)) return e;
  }
  return chain[0];
}

/** The primitive children of a filter, in painting order. */
function primitiveChildren(el: Element): Element[] {
  const out: Element[] = [];
  for (const kid of el.kids) {
    if (!kid.isElementNode) continue;
    const name = (kid as Element).localName.toLowerCase().replace(/^.*:/, "");
    if (name.startsWith("fe")) out.push(kid as Element);
  }
  return out;
}

/** The matrix a feColorMatrix's type and values name, rows R, G, B, A with a fifth offset column. */
function colourMatrix(prim: Element): number[] {
  const type = (attr(prim, "type") ?? "matrix").trim().toLowerCase();
  if (type === "saturate") {
    const raw = attr(prim, "values");
    const parsed = lengthOf(raw);
    const s = parsed === null ? 1 : parsed.pct ? parsed.v : parsed.v;
    return [
      0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0,
      0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
      0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }
  if (type === "huerotate") {
    const raw = (attr(prim, "values") ?? "0").trim();
    let degrees = parseFloat(raw);
    if (!Number.isFinite(degrees)) degrees = 0;
    if (raw.endsWith("grad")) degrees *= 0.9;
    else if (raw.endsWith("rad")) degrees *= 180 / Math.PI;
    else if (raw.endsWith("turn")) degrees *= 360;
    const rad = degrees * Math.PI / 180;
    const c = Math.cos(rad), s = Math.sin(rad);
    return [
      0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0,
      0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
      0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }
  if (type === "luminancetoalpha") {
    return [
      0, 0, 0, 0, 0,
      0, 0, 0, 0, 0,
      0, 0, 0, 0, 0,
      0.2125, 0.7154, 0.0721, 0, 0,
    ];
  }
  const values = words(attr(prim, "values") ?? "").map(Number);
  if (values.length !== 20 || values.some((v) => !Number.isFinite(v))) {
    return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
  }
  return values;
}

const BLEND_MODES = [
  "normal", "multiply", "screen", "darken", "lighten", "overlay", "color-dodge", "color-burn",
  "hard-light", "soft-light", "difference", "exclusion",
];

const COMPOSITE_OPS = ["over", "in", "out", "atop", "xor"];

/**
 * Compiles the filter `target` for the element `el` into the host's definition. `bbox` is the
 * element's bounds in its own user space, `m` the transform from there to device pixels, and
 * `vw`/`vh` its viewport. Null when the filter covers nothing on the root bitmap.
 */
export function compileSvgFilter(target: Element, el: Element, bbox: number[], m: number[],
  vw: number, vh: number, pw: number, ph: number,
  lookup: (id: string) => Element | undefined): FilterRow | null {
  const chain = filterChain(target, lookup);
  const filterUnitsRaw = (chainAttr(chain, "filterunits") ?? "").trim().toLowerCase();
  const units: Units = filterUnitsRaw === "userspaceonuse" ? "userspace" : "bbox";
  const icf = chainAttr(chain, "color-interpolation-filters")?.trim().toLowerCase() ?? "";
  // The property is inherited to the filter element; auto and anything unrecognized interpolate
  // in linear RGB for an SVG filter, as Chrome does.
  const linear = icf !== "srgb" &&
    !(icf === "" && target.sv[P.P_COLOR_INTERPOLATION_FILTERS] === P.ICF_SRGB);
  const regionRaw = (name: string, def: number): { v: number; pct: boolean } => {
    const raw = chainAttr(chain, name);
    const parsed = lengthOf(raw);
    return parsed ?? { v: def, pct: true };
  };
  const rx = regionRaw("x", -0.1), ryl = regionRaw("y", -0.1);
  const rw = regionRaw("width", 1.2), rh = regionRaw("height", 1.2);
  let region: number[];
  if (units === "bbox") {
    region = [bbox[0] + rx.v * bbox[2], bbox[1] + ryl.v * bbox[3], rw.v * bbox[2], rh.v * bbox[3]];
  } else {
    region = [rx.pct ? rx.v * vw : rx.v, ryl.pct ? ryl.v * vh : ryl.v,
      rw.pct ? rw.v * vw : rw.v, rh.pct ? rh.v * vh : rh.v];
  }
  if (!(region[2] > 0) || !(region[3] > 0)) return null;
  const dev = deviceRect(region, m);
  const x0 = Math.max(0, Math.floor(dev[0])), y0 = Math.max(0, Math.floor(dev[1]));
  const x1 = Math.min(pw, Math.ceil(dev[0] + dev[2])), y1 = Math.min(ph, Math.ceil(dev[1] + dev[3]));
  if (!(x1 > x0) || !(y1 > y0)) return null;
  const regionW = x1 - x0, regionH = y1 - y0;
  // Device pixels per user unit along each axis, for primitive lengths.
  const scaleX = Math.hypot(m[0], m[1]), scaleY = Math.hypot(m[2], m[3]);

  const owner = primitivesOwner(chain);
  const prims = primitiveChildren(owner);
  const primUnitsRaw = (chainAttr(chain, "primitiveunits") ?? "").trim().toLowerCase();
  const primUnits: Units = primUnitsRaw === "objectboundingbox" ? "bbox" : "userspace";
  const results = new Map<string, number>();
  const ops: string[] = [];

  /** A primitive's subregion, in device pixels from the filter region's corner. */
  const subregion = (prim: Element): string => {
    const sx = lengthOf(attr(prim, "x")), sy = lengthOf(attr(prim, "y"));
    const sw = lengthOf(attr(prim, "width")), sh = lengthOf(attr(prim, "height"));
    if (sx === null && sy === null && sw === null && sh === null) {
      return `0,0,${regionW},${regionH}`;
    }
    // A position: objectBoundingBox fractions start at the bbox corner, user-space percentages at
    // the filter region's corner, and a bare user length is absolute.
    const pos = (v: { v: number; pct: boolean } | null, axis: "x" | "y", fallback: number): number => {
      if (v === null) return fallback;
      if (primUnits === "bbox") return (axis === "x" ? bbox[0] : bbox[1]) + v.v * (axis === "x" ? bbox[2] : bbox[3]);
      return v.pct ? (axis === "x" ? region[0] : region[1]) + v.v * (axis === "x" ? region[2] : region[3]) : v.v;
    };
    const size = (v: { v: number; pct: boolean } | null, axis: "x" | "y", fallback: number): number => {
      if (v === null) return fallback;
      if (primUnits === "bbox") return v.v * (axis === "x" ? bbox[2] : bbox[3]);
      return v.pct ? v.v * (axis === "x" ? region[2] : region[3]) : v.v;
    };
    const ux = pos(sx, "x", region[0]);
    const uy = pos(sy, "y", region[1]);
    const uw = size(sw, "x", region[2]);
    const uh = size(sh, "y", region[3]);
    const d = deviceRect([ux, uy, uw, uh], m);
    return `${f(d[0] - x0)},${f(d[1] - y0)},${f(d[2])},${f(d[3])}`;
  };

  const inputNames = (prim: Element, index: number): [number, number] => {
    const nameAttr = attr(prim, "in");
    const in2Attr = attr(prim, "in2");
    const ref = (text: string | null, fallback: number): number => {
      if (text === null || text.trim() === "") return fallback;
      const name = text.trim();
      if (name === "SourceGraphic") return SOURCE;
      if (name === "SourceAlpha") return SOURCE_ALPHA;
      const hit = results.get(name);
      return hit === undefined ? TRANSPARENT : hit;
    };
    const prev = index === 0 ? SOURCE : index - 1;
    return [ref(nameAttr, prev), ref(in2Attr, prev)];
  };

  // How much wider than the region the source has to be captured: a primitive reads its input a
  // little away from where it writes its output, so a chain that offsets or blurs can bring
  // content into the region from outside it. Each side grows by every primitive's reach along it.
  let mL = 0, mT = 0, mR = 0, mB = 0;
  const grow = (l: number, t: number, r: number, b: number): void => {
    if (Number.isFinite(l) && l > 0) mL += l;
    if (Number.isFinite(t) && t > 0) mT += t;
    if (Number.isFinite(r) && r > 0) mR += r;
    if (Number.isFinite(b) && b > 0) mB += b;
  };

  for (let i = 0; i < prims.length; i++) {
    const prim = prims[i];
    const name = prim.localName.toLowerCase().replace(/^.*:/, "");
    const sub = subregion(prim);
    const [in1] = inputNames(prim, i);
    const result = attr(prim, "result");
    if (name === "fegaussianblur") {
      const raw = attr(prim, "stddeviation");
      const parts = words(raw ?? "0").map(Number);
      const stdX = Number.isFinite(parts[0]) ? parts[0] : 0;
      const stdY = parts.length > 1 && Number.isFinite(parts[1]) ? parts[1] : stdX;
      const bl = length(Math.abs(stdX), primUnits, "x", bbox) * scaleX;
      const bt = length(Math.abs(stdY), primUnits, "y", bbox) * scaleY;
      ops.push(`b,${f(bl)},${f(bt)},${in1},${sub}`);
      // A Gaussian reaches about three standard deviations.
      grow(3 * bl, 3 * bt, 3 * bl, 3 * bt);
    } else if (name === "feoffset") {
      const dx = lengthOf(attr(prim, "dx")) ?? { v: 0, pct: false };
      const dy = lengthOf(attr(prim, "dy")) ?? { v: 0, pct: false };
      const [ox, oy] = deviceVector(dx, dy, primUnits, bbox, m, vw, vh);
      ops.push(`o,${f(ox)},${f(oy)},${in1},${sub}`);
      // The output at a point reads its input from the opposite side of the shift.
      grow(Math.max(0, ox), Math.max(0, oy), Math.max(0, -ox), Math.max(0, -oy));
    } else if (name === "fecolormatrix") {
      const matrix = colourMatrix(prim).map((v) => f(v));
      ops.push(`m,${in1},${matrix.join(",")},${sub}`);
    } else if (name === "feblend") {
      const [, in2] = inputNames(prim, i);
      const modeName = (attr(prim, "mode") ?? "normal").trim().toLowerCase();
      const mode = Math.max(0, BLEND_MODES.indexOf(modeName));
      ops.push(`l,${mode},${in1},${in2},${sub}`);
    } else if (name === "femerge") {
      const nodes: number[] = [];
      for (const kid of prim.kids) {
        if (!kid.isElementNode) continue;
        const node = kid as Element;
        if (node.localName.toLowerCase().replace(/^.*:/, "") !== "femergenode") continue;
        const text = attr(node, "in");
        const refText = text === null || text.trim() === "" ? null : text.trim();
        const hit = refText === null ? (i === 0 ? SOURCE : i - 1)
          : refText === "SourceGraphic" ? SOURCE
          : refText === "SourceAlpha" ? SOURCE_ALPHA
          : results.get(refText) ?? TRANSPARENT;
        nodes.push(hit);
      }
      ops.push(`e,${nodes.length},${nodes.join(",")},${sub}`);
    } else if (name === "feflood") {
      const mixed = withOpacity(floodColor(prim, el), floodOpacity(prim));
      ops.push(`f,${colourParts(mixed, linear)},${sub}`);
    } else if (name === "fecomposite") {
      const [, in2] = inputNames(prim, i);
      const opName = (attr(prim, "operator") ?? "over").trim().toLowerCase();
      const op = Math.max(0, COMPOSITE_OPS.indexOf(opName));
      const k = ["k1", "k2", "k3", "k4"].map((n) => f(numberAttr(prim, n, 0)));
      ops.push(`c,${op},${k.join(",")},${in1},${in2},${sub}`);
    } else if (name === "fedropshadow") {
      const dx = lengthOf(attr(prim, "dx")), dy = lengthOf(attr(prim, "dy"));
      const raw = attr(prim, "stddeviation");
      const parts = words(raw ?? "0").map(Number);
      const stdX = Number.isFinite(parts[0]) ? Math.abs(parts[0]) : 0;
      const stdY = parts.length > 1 && Number.isFinite(parts[1]) ? Math.abs(parts[1]) : stdX;
      const mixed = withOpacity(floodColor(prim, el), floodOpacity(prim));
      const [ox, oy] = deviceVector(dx ?? { v: 0, pct: false }, dy ?? { v: 0, pct: false },
        primUnits, bbox, m, vw, vh);
      const bl = length(stdX, primUnits, "x", bbox) * scaleX;
      const bt = length(stdY, primUnits, "y", bbox) * scaleY;
      ops.push(`d,${f(ox)},${f(oy)},${f(bl)},${f(bt)},` +
        `${colourParts(mixed, linear)},${in1},${sub}`);
      // The shadow is the source blurred and shifted, so it reaches the shift plus three sigma.
      grow(3 * bl + Math.max(0, ox), 3 * bt + Math.max(0, oy),
        3 * bl + Math.max(0, -ox), 3 * bt + Math.max(0, -oy));
    } else {
      // A primitive this build doesn't draw yet: its input passes through unchanged.
      ops.push(`t,${in1},${sub}`);
    }
    if (result !== null && result.trim() !== "") results.set(result.trim(), i);
  }
  // A filter with no primitives leaves the element as it is; still route it through the layer so
  // the region rules apply, with a single pass-through primitive.
  if (ops.length === 0) ops.push(`t,${SOURCE},0,0,${regionW},${regionH}`);
  // The surface the source is captured on holds the element's own box as well as the region, so
  // a primitive can move content in from outside the region; each side also grows by what the
  // chain reaches for. The definition stays region-relative: shiftFilterDef moves it into the
  // capture surface, and the result is clipped to the region when it is composited.
  const box = deviceRect(bbox, m);
  // The capture reaches past the region only by what the chain reaches for: content further out
  // can never move into it, and bounding it here keeps a shape drawn far off the page from making
  // the surface (and every buffer the host filters it with) grow with its distance.
  const sx0 = Math.max(Math.floor(Math.min(x0, box[0]) - mL), Math.floor(-mL));
  const sy0 = Math.max(Math.floor(Math.min(y0, box[1]) - mT), Math.floor(-mT));
  const sx1 = Math.min(Math.ceil(Math.max(x1, box[0] + box[2]) + mR), Math.ceil(pw + mR));
  const sy1 = Math.min(Math.ceil(Math.max(y1, box[1] + box[3]) + mB), Math.ceil(ph + mB));
  const sw = sx1 - sx0, sh = sy1 - sy0;
  // The host's canvas takes no side past 16384: a bigger capture would be truncated there, so the
  // element paints unfiltered instead of losing the part that didn't fit.
  if (sw > 16384 || sh > 16384) return null;
  if (!Number.isFinite(sw) || !Number.isFinite(sh) || !(sw > 0) || !(sh > 0)) {
    return { def: ops.join(";"), x: x0, y: y0, w: regionW, h: regionH,
      sx: x0, sy: y0, sw: regionW, sh: regionH, linear };
  }
  return { def: ops.join(";"), x: x0, y: y0, w: regionW, h: regionH, sx: sx0, sy: sy0, sw, sh, linear };
}

/** Moves a definition's subregions from the filter region's corner to the capture rect's: a
 *  primitive's subregion is measured from the region, and the host filters the whole capture. */
export function shiftFilterDef(def: string, dx: number, dy: number): string {
  if (!(dx !== 0 || dy !== 0)) return def;
  return def.split(";").map((op) => {
    const flds = op.split(",");
    const n = flds.length;
    if (n < 4) return op;
    flds[n - 4] = String(Number(flds[n - 4]) + dx);
    flds[n - 3] = String(Number(flds[n - 3]) + dy);
    return flds.join(",");
  }).join(";");
}

/** The device-pixel bounding box of a user-space rect under `m`. */
function deviceRect(rect: number[], m: number[]): number[] {
  const pts = [
    [rect[0], rect[1]], [rect[0] + rect[2], rect[1]],
    [rect[0] + rect[2], rect[1] + rect[3]], [rect[0], rect[1] + rect[3]],
  ];
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const [x, y] of pts) {
    const X = m[0] * x + m[2] * y + m[4];
    const Y = m[1] * x + m[3] * y + m[5];
    if (X < x0) x0 = X;
    if (Y < y0) y0 = Y;
    if (X > x1) x1 = X;
    if (Y > y1) y1 = Y;
  }
  return [x0, y0, x1 - x0, y1 - y0];
}
