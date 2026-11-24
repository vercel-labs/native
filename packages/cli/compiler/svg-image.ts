// An SVG file used as an image (<img src>, a CSS url()) compiled into a draw program the runtime
// replays into a bitmap, the way an inline <svg> is drawn from its own subtree.
//
// The program is a flat list of numbers, joined with commas, that the runtime parses once:
//   width, height, has, hasViewBox, viewBox minX, minY, width, height, align, slice, count,
//   gradients,
//   then one record per gradient: kind, user-space flag, five coordinates, six matrix numbers,
//   stop count, and one colour/offset pair per stop,
//   then one record per shape: matrix a b c d e f, fill, stroke, stroke width, cap, join,
//   dash count, dash offset, the dash lengths, fill rule, alpha, clip count, one record per clip
//   (its rule, operation count and operations), path operation count, and the path operations
//   themselves. Clip operations are already in the shape's own user space, so the runtime clips
//   and draws under one transform, intersecting the nested clips in order.
// width and height are the image's default object size in CSS px: its intrinsic size, or 300 by
// 150 when it has no size of its own (fitted to the ratio when it has one). `has` says which
// dimensions those are the file's own: 1 for height, 2 for width, 3 for both, and 0 for neither,
// which is what a percentage attribute gives — it resolves against the box the image is drawn in,
// so the file has no size of its own in that direction. Paint is a packed colour or -1 for none;
// currentColor is resolved here, against the `color` the file gives the element or inherits. A
// paint that names a gradient is PAINT_GRADIENT - its index in the gradient table.
//
// The cascade inside the file is the presentation attributes and then the element's style=""
// attribute, over the initial values. A <style> element in the file isn't read yet, so a rule
// there doesn't reach the picture.

import { readFileSync } from "node:fs";
import type { Diagnostics } from "./diagnostics.ts";
import { parseHtml, type HElement } from "./html.ts";
import { compileDeclarations, type Decl } from "./css.ts";
import * as P from "../shared/props.ts";
import { mul, invert, transformOps, parseTransform, parseViewBox, parseAspectRatio, shapePath, viewMatrix,
  localName, numList, svgLengths, type AttrGet } from "../shared/svg.ts";
import { bboxOf, PAINT_GRADIENT, parseGradient, paintUrlIndex, type GradientLookup, type SvgGradient } from "../shared/svg-paint.ts";
import { GENERIC_FAMILIES, genericFamily, type FontContext } from "../shared/css/types.ts";
import { dashRows } from "../shared/css/dasharray.ts";
import { anchorOf } from "../shared/svg-text.ts";

/** Attributes that paint an SVG element, as a zero-specificity declaration before style="". */
export const SVG_PRESENTATION_ATTRS = ["fill", "stroke", "color", "fill-opacity", "stroke-opacity", "opacity",
  "stroke-linecap", "stroke-linejoin", "fill-rule", "stroke-dasharray", "stroke-dashoffset",
  "font-family", "font-weight", "font-style"];

/** Elements whose subtree isn't drawn: definitions and non-rendered content. */
const SKIPS = new Set(["defs", "title", "desc", "metadata", "clippath", "mask", "symbol", "marker",
  "pattern", "lineargradient", "radialgradient", "filter", "style", "script"]);

/** One compiled file's paint servers and the ids its href references resolve through. */
interface Ctx {
  file: string;
  diags: Diagnostics;
  vw: number;
  vh: number;
  /** The paint server ids a fill/stroke names, in first-use order (a paint value indexes this). */
  paintIds: string[];
  lookup: GradientLookup;
  /** The program's gradient table, flat, the number of gradients in it, and a lookup by row. */
  grads: number[];
  gradCount: number;
  gradAt: Map<string, number>;
  fonts: FontContext;
  /** Every element with an id, which a <use> names. */
  byId: Map<string, HElement>;
  /** How deep a chain of <use> elements is, so a cycle stops instead of recursing forever. */
  useDepth: number;
}

/** The paint state that inherits down the tree, plus the element's own opacity. */
interface State {
  fill: number;
  stroke: number;
  fillOpacity: number;
  strokeOpacity: number;
  strokeWidth: number;
  cap: number;
  join: number;
  /** The dash pattern in user units, already resolved; empty for a solid line. */
  dash: number[];
  dashOffset: number;
  /** The clip paths in effect, each a union of shapes in its own user space. */
  clips: ClipShape[];
  rule: number;
  color: number;
  /** The font text in this element is drawn with: its size in user units, and its packed key. */
  fontSize: number;
  fontFamily: number;
  fontWeight: number;
  fontItalic: number;
}

const INITIAL: State = {
  fill: 0x000000ff, stroke: P.PAINT_NONE, fillOpacity: 1, strokeOpacity: 1,
  strokeWidth: 1, cap: P.SLC_BUTT, join: P.SLJ_MITER, dash: [], dashOffset: 0, clips: [],
  rule: P.FR_NONZERO, color: 0x000000ff,
  fontSize: 16, fontFamily: P.FF_SYSTEM, fontWeight: 400, fontItalic: 0,
};

export interface SvgImage {
  /** Default object size in CSS px, as an image uses it. */
  width: number;
  height: number;
  /** Which of those dimensions the file's own attributes give: 0 neither, 1 height, 2 width,
   *  3 both. A viewBox alone gives a ratio and neither dimension. */
  has: number;
  /** The draw program (see the header comment). */
  program: string;
}

/** One shape of a clip path: its operations and the matrix they are in. */
interface ClipPart {
  m: number[];
  ops: number[];
}

/** A clip path as the shapes it is the union of, and the rule that fills them. */
interface ClipShape {
  parts: ClipPart[];
  rule: number;
}

/** The id a clip-path property names, from the attribute or a style="" declaration. */
function clipRef(el: HElement): string {
  let value = el.attrs.get("clip-path");
  if (value === undefined) {
    const style = el.attrs.get("style");
    if (style !== undefined) {
      const at = style.indexOf("clip-path");
      if (at >= 0) value = style.slice(at + "clip-path".length).trimStart();
    }
  }
  if (value === undefined) return "";
  const text = value.trim();
  if (!text.startsWith("url(")) return "";
  const close = text.indexOf(")");
  if (close < 0) return "";
  const ref = text.slice(4, close).trim();
  return ref.startsWith("#") ? ref.slice(1) : "";
}

/** The bounds a group's contents cover in its own user space, in [x, y, w, h]. */
function contentBBox(el: HElement, ctx: Ctx): number[] {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  const walk = (node: HElement, m: number[]): void => {
    const name = localName(node.tag);
    const t = node.attrs.get("transform");
    const m2 = t !== undefined && t.trim() !== "" ? mul(m, parseTransform(t)) : m;
    if (name === "g" || name === "a" || name === "svg") {
      for (const kid of node.children) if (kid.kind === "element") walk(kid, m2);
      return;
    }
    const ops = shapePath(name, (attr) => node.attrs.get(attr) ?? null, ctx.vw, ctx.vh);
    if (ops.length === 0) return;
    const box = bboxOf(transformOps(ops, m2));
    if (box[0] < x0) x0 = box[0];
    if (box[1] < y0) y0 = box[1];
    if (box[0] + box[2] > x1) x1 = box[0] + box[2];
    if (box[1] + box[3] > y1) y1 = box[1] + box[3];
  };
  walk(el, [1, 0, 0, 1, 0, 0]);
  if (!(x1 >= x0) || !(y1 >= y0)) return [0, 0, 0, 0];
  return [x0, y0, x1 - x0, y1 - y0];
}

/** The clip paths in effect for an element: the ones it inherits plus its own. */
function withClips(el: HElement, m: number[], clips: ClipShape[], ctx: Ctx,
  bbox: number[] | null): ClipShape[] {
  const ref = clipRef(el);
  if (ref === "") return clips;
  const target = ctx.byId.get(ref);
  if (target === undefined || localName(target.tag) !== "clippath") return clips;
  // objectBoundingBox maps the unit box onto the element's bounds; the clip's shapes then come
  // in that box's space.
  let root = m;
  const units = (target.attrs.get("clippathunits") ?? "").trim().toLowerCase();
  if (units === "objectboundingbox" && bbox !== null) {
    root = mul(m, [bbox[2], 0, 0, bbox[3], bbox[0], bbox[1]]);
  }
  const out = clips.slice();
  const rule = (target.attrs.get("clip-rule") ?? "").trim().toLowerCase() === "evenodd" ? 1 : 0;
  const parts: ClipPart[] = [];
  const walk = (node: HElement, mm: number[]): void => {
    const name = localName(node.tag);
    const t = node.attrs.get("transform");
    const m2 = t !== undefined && t.trim() !== "" ? mul(mm, parseTransform(t)) : mm;
    if (name === "g" || name === "a") {
      for (const kid of node.children) if (kid.kind === "element") walk(kid, m2);
      return;
    }
    const ops = shapePath(name, (attr) => node.attrs.get(attr) ?? null, ctx.vw, ctx.vh);
    if (ops.length > 0) parts.push({ m: m2, ops });
  };
  for (const kid of target.children) if (kid.kind === "element") walk(kid, root);
  if (parts.length > 0) out.push({ parts, rule });
  return out;
}

/** An absolute length attribute in px, or null: a percentage depends on the used size. */
function absLen(raw: string | undefined): number | null {
  if (raw === undefined) return null;
  const m = /^\s*([-+]?(?:\d+\.?\d*|\.\d+))(?:px)?\s*$/i.exec(raw);
  return m === null ? null : parseFloat(m[1]);
}

function number(v: number): number {
  return Number.isFinite(v) ? v : 0;
}

/** A viewBox the file declares with a zero width or height, as the numbers it gives: zero area
 *  disables rendering of the element (SVG 1.1 §7.7), so the picture paints nothing. */
function zeroViewBox(get: AttrGet): number[] | null {
  const raw = get("viewbox");
  if (raw === null) return null;
  const v = numList(raw);
  if (v.length < 4 || (v[2] > 0 && v[3] > 0)) return null;
  return [v[0], v[1], v[2], v[3]];
}

/** Compiles one SVG file into its draw program; null when the file isn't an SVG document. */
export function compileSvgImage(file: string, diags: Diagnostics): SvgImage | null {
  const src = readFileSync(file, "utf8");
  // An SVG file is its own document: it never gets the implied html/body an HTML page has.
  const root = parseHtml(src, file, diags, "svg");
  const svg = root.children.find((c): c is HElement => c.kind === "element" && localName(c.tag) === "svg");
  if (svg === undefined) {
    diags.warn(file, 1, 1, "an SVG image must have an <svg> root");
    return null;
  }
  const get: AttrGet = (name) => svg.attrs.get(name) ?? null;
  const view = parseViewBox(get);
  // A viewBox with a zero width or height disables rendering of the element (SVG 1.1 §7.7), which
  // parseViewBox reports as no usable viewBox. Its numbers still go in the program, where the
  // runtime draws nothing for the picture whatever size it is given; the size itself is the
  // default 300 by 150 the file doesn't give.
  const zero = view === null ? zeroViewBox(get) : null;
  const program = view !== null ? view : zero;
  const wAttr = absLen(svg.attrs.get("width"));
  const hAttr = absLen(svg.attrs.get("height"));
  const ratio = view !== null ? view[2] / view[3] : wAttr !== null && hAttr !== null && hAttr > 0 ? wAttr / hAttr : 0;
  // An image takes the default object size of 300 by 150 for whatever it doesn't give itself. Only
  // an absolute attribute gives a dimension: a percentage resolves against the box the image is
  // drawn in, and an omitted one leaves the default. A viewBox's ratio can give a dimension from
  // the other one, since an image with a ratio and one side has its size.
  let iw = 300, ih = 150;
  let has = 0;
  if (wAttr !== null && hAttr !== null) {
    iw = wAttr; ih = hAttr; has = 3;
  } else if (wAttr !== null) {
    iw = wAttr;
    if (ratio > 0) { ih = wAttr / ratio; has = 3; } else has = 2;
  } else if (hAttr !== null) {
    ih = hAttr;
    if (ratio > 0) { iw = hAttr * ratio; has = 3; } else has = 1;
  } else if (view !== null) {
    const s = Math.min(300 / view[2], 150 / view[3]);
    iw = view[2] * s; ih = view[3] * s;
  }
  const [align, slice] = parseAspectRatio(get("preserveaspectratio"));
  // Percentages in geometry resolve against the viewBox, or the image's own size without one.
  const vw = view !== null ? view[2] : iw;
  const vh = view !== null ? view[3] : ih;

  // Every id in the file, which a paint server's href may name.
  const byId = new Map<string, HElement>();
  const collect = (el: HElement): void => {
    const id = el.attrs.get("id");
    if (id !== undefined && id !== "" && !byId.has(id)) byId.set(id, el);
    for (const kid of el.children) if (kid.kind === "element") collect(kid);
  };
  collect(svg);
  const lookup: GradientLookup = {
    kind: (id) => {
      const el = byId.get(id);
      if (el === undefined) return null;
      const name = localName(el.tag);
      return name === "lineargradient" ? 0 : name === "radialgradient" ? 1 : null;
    },
    attrs: (id) => {
      const el = byId.get(id);
      return el === undefined ? null : (name: string) => el.attrs.get(name) ?? null;
    },
    stops: (id) => {
      const el = byId.get(id);
      const out: ((name: string) => string | null)[] = [];
      if (el === undefined) return out;
      for (const kid of el.children) {
        if (kid.kind === "element" && localName(kid.tag) === "stop") {
          out.push((name: string) => kid.attrs.get(name) ?? null);
        }
      }
      return out;
    },
  };
  const paintIds: string[] = [];
  const ctx: Ctx = {
    file, diags, vw, vh, paintIds, lookup, grads: [], gradCount: 0, gradAt: new Map(), byId, useDepth: 0,
    // The file's declarations name no app resources: a paint server is the only one it has.
    fonts: {
      family: (name) => genericFamily(name) ?? P.FF_SYSTEM,
      available: (name) => genericFamily(name) !== undefined,
      image: () => -1,
      background: () => -1,
      gradient: () => -1,
      shadow: () => -1,
      tracks: () => -1,
      trackName: () => -1,
      placement: () => -1,
      areaList: () => -1,
      filter: () => -1,
      paint: (id) => {
        const at = paintIds.indexOf(id);
        if (at >= 0) return at;
        paintIds.push(id);
        return paintIds.length - 1;
      },
    },
  };
  const body: number[] = [];
  const records = draw(svg, INITIAL, [1, 0, 0, 1, 0, 0], 1, body, ctx);
  const out: number[] = [number(iw), number(ih), has, program === null ? 0 : 1,
    ...(program === null ? [0, 0, 0, 0] : program), align, slice ? 1 : 0, records, ctx.gradCount,
    ...ctx.grads, ...body];
  return { width: iw, height: ih, has, program: out.join(",") };
}

/** The declarations an element's presentation attributes and style="" attribute give it. */
function declsOf(el: HElement, ctx: Ctx): Decl[] {
  const loc = (): [number, number] => [el.line, el.col];
  let css = "";
  for (const name of SVG_PRESENTATION_ATTRS) {
    const v = el.attrs.get(name);
    if (v !== undefined && v.trim() !== "") css += `${name}: ${v};`;
  }
  // A bare number is a length in the attribute grammar, as CSS's own parser won't take it.
  for (const name of ["stroke-width", "stroke-dasharray", "stroke-dashoffset"]) {
    const v = el.attrs.get(name);
    if (v !== undefined && v.trim() !== "") css += `${name}: ${svgLengths(v) ?? v};`;
  }
  const display = el.attrs.get("display");
  if (display !== undefined && display.trim() !== "") css += `display: ${display};`;
  const style = el.attrs.get("style");
  if (style !== undefined && style.trim() !== "") css += style;
  return css === "" ? [] : compileDeclarations(css, loc, ctx.file, ctx.diags, ctx.fonts);
}

/** A stroke width in user units: a percentage against the viewport's normalized diagonal. */
function widthOf(v: number, u: number, vw: number, vh: number): number {
  if (u === P.U_PCT) return v / 100 * Math.sqrt((vw * vw + vh * vh) / 2);
  if (u === P.U_VW) return v / 100 * vw;
  if (u === P.U_VH) return v / 100 * vh;
  if (u === P.U_EM) return v * 16;
  return v;
}

/**
 * Walks the file's tree, appending one record per drawn shape to `out`; returns how many there
 * were. `alpha` is the opacity of everything above the element, which each element's own opacity
 * multiplies, as a browser composites a group's shapes one at a time in this renderer. A fill or
 * stroke that names a gradient is compiled into the program's gradient table first.
 */
/** The style an element itself gives, over what it inherits, and its own opacity. */
interface Styled {
  s: State;
  opacity: number;
  hidden: boolean;
}

function styleAt(el: HElement, inherited: State, ctx: Ctx): Styled {
  const s: State = { ...inherited };
  let opacity = 1;
  let hidden = false;
  for (const d of declsOf(el, ctx)) {
    if (d.p === P.P_FILL || d.p === P.P_STROKE) {
      if (d.p === P.P_FILL) s.fill = d.v; else s.stroke = d.v;
    } else if (d.p === P.P_COLOR) s.color = d.v;
    else if (d.p === P.P_FILL_OPACITY) s.fillOpacity = d.v;
    else if (d.p === P.P_STROKE_OPACITY) s.strokeOpacity = d.v;
    else if (d.p === P.P_STROKE_WIDTH) s.strokeWidth = widthOf(d.v, d.u, ctx.vw, ctx.vh);
    else if (d.p === P.P_STROKE_LINECAP) s.cap = d.v;
    else if (d.p === P.P_STROKE_LINEJOIN) s.join = d.v;
    else if (d.p === P.P_STROKE_DASHARRAY) {
      // The dash lengths are resolved here, so the program carries them itself: a percentage
      // of the file's viewport has no meaning to the runtime, which only sees the program.
      const row = d.v < 0 ? null : dashRows.row(d.v);
      s.dash = [];
      if (row !== null) {
        for (let i = 0; i + 1 < row.length; i += 2) s.dash.push(widthOf(row[i], row[i + 1], ctx.vw, ctx.vh));
      }
    } else if (d.p === P.P_STROKE_DASHOFFSET) s.dashOffset = widthOf(d.v, d.u, ctx.vw, ctx.vh);
    else if (d.p === P.P_FILL_RULE) s.rule = d.v;
    else if (d.p === P.P_FONT_SIZE) {
      // A relative size is a share of the size the element inherits.
      if (d.u === P.U_EM) s.fontSize = d.v * s.fontSize;
      else if (d.u === P.U_PCT) s.fontSize = d.v / 100 * s.fontSize;
      else s.fontSize = widthOf(d.v, d.u, ctx.vw, ctx.vh);
    } else if (d.p === P.P_FONT_FAMILY) s.fontFamily = d.v;
    else if (d.p === P.P_FONT_WEIGHT) s.fontWeight = d.v;
    else if (d.p === P.P_FONT_STYLE) s.fontItalic = d.v === P.FS_ITALIC ? 1 : 0;
    else if (d.p === P.P_OPACITY) opacity = d.v;
    else if (d.p === P.P_DISPLAY && d.v === P.D_NONE) hidden = true;
  }
  if (s.fill === P.PAINT_CURRENT) s.fill = s.color;
  if (s.stroke === P.PAINT_CURRENT) s.stroke = s.color;
  return { s, opacity, hidden };
}

function draw(el: HElement, inherited: State, m: number[], alpha: number, out: number[], ctx: Ctx): number {
  const name = localName(el.tag);
  if (SKIPS.has(name)) return 0;
  const get: AttrGet = (n) => el.attrs.get(n) ?? null;
  const style = styleAt(el, inherited, ctx);
  if (style.hidden) return 0;
  const s = style.s;
  const a = alpha * style.opacity;
  if (!(a > 0)) return 0;

  const t = el.attrs.get("transform");
  const m2 = t !== undefined && t.trim() !== "" ? mul(m, parseTransform(t)) : m;
  // A clip path is resolved where it is named, in that element's own user space.
  if (clipRef(el) !== "") {
    const bbox = name === "g" || name === "svg" || name === "a" || name === "use"
      ? contentBBox(el, ctx)
      : bboxOf(shapePath(name, get, ctx.vw, ctx.vh));
    s.clips = withClips(el, m2, s.clips, ctx, bbox);
  }
  if (name === "use") return drawUse(el, s, m, a, out, ctx);
  if (name === "g" || name === "svg" || name === "a") {
    let count = 0;
    for (const kid of el.children) {
      if (kid.kind === "element") count += draw(kid, s, m2, a, out, ctx);
    }
    return count;
  }
  if (name === "text") {
    const pieces = collectPieces(el, s, ctx);
    if (pieces.length === 0) return 0;
    out.push(1, ...m2.map(number), number(a), anchorOf(attrOrStyle(el, "text-anchor")),
      s.clips.length, ...clipNumbers(s.clips, m2), pieces.length);
    for (const p of pieces) {
      const chars = Array.from(p.text, (c) => c.codePointAt(0) ?? 0);
      out.push(p.x === null ? 0 : 1, number(p.x ?? 0), p.y === null ? 0 : 1, number(p.y ?? 0),
        number(p.dx), number(p.dy), number(p.size), p.font, p.fill, p.stroke, number(p.width),
        number(p.alpha), chars.length, ...chars);
    }
    return 1;
  }
  const ops = shapePath(name, get, ctx.vw, ctx.vh);
  if (ops.length === 0) return 0;
  const width = s.strokeWidth;
  // fill-opacity and stroke-opacity multiply the paint's own alpha here, leaving the element's
  // opacity to the runtime, which also has the box's own paint opacity.
  const fill = paintRecord(ctx, s.fill, s.fillOpacity);
  const stroke = paintRecord(ctx, s.stroke, s.strokeOpacity);
  if (!paintedRecord(fill) && !(paintedRecord(stroke) && width > 0)) return 0;
  // The clip paths' operations go into the record in this shape's own user space, so the
  // runtime clips and draws under one transform. Each clip is one path, and the runtime
  // intersects them in the order they are nested in.
  out.push(0, ...m2.map(number), fill, stroke,
    number(width), s.cap, s.join, s.dash.length, number(s.dashOffset), ...s.dash.map(number),
    s.rule, number(a), s.clips.length, ...clipNumbers(s.clips, m2), ops.length, ...ops.map(number));
  return 1;
}

/** A record's clip paths: each one's rule and its operations, in the record's own user space. */
function clipNumbers(clips: ClipShape[], m2: number[]): number[] {
  const out: number[] = [];
  for (const c of clips) {
    const clipOps: number[] = [];
    for (const part of c.parts) clipOps.push(...transformOps(part.ops, mul(invert(m2), part.m)));
    out.push(c.rule, clipOps.length, ...clipOps.map(number));
  }
  return out;
}

/** One stretch of text in a record: where the pen starts for it, and how it is drawn. */
interface Piece {
  x: number | null;
  y: number | null;
  dx: number;
  dy: number;
  size: number;
  font: number;
  fill: number;
  stroke: number;
  width: number;
  alpha: number;
  text: string;
}

/** The first length an attribute lists ("10 20 30" starts at 10); null without one. */
function firstLenAttr(el: HElement, name: string, base: number): number | null {
  const raw = el.attrs.get(name);
  if (raw === undefined || raw.trim() === "") return null;
  const text = raw.trim().split(/[\s,]+/)[0];
  const v = text.endsWith("%") ? parseFloat(text) / 100 * base : parseFloat(text);
  return Number.isFinite(v) ? v : null;
}

/** A value an element writes as an attribute or in its style=""; "" when it writes neither. */
function attrOrStyle(el: HElement, name: string): string {
  const attr = el.attrs.get(name);
  if (attr !== undefined && attr.trim() !== "") return attr.trim();
  const style = el.attrs.get("style");
  if (style === undefined) return "";
  let from = 0;
  for (;;) {
    const at = style.indexOf(name, from);
    if (at < 0) return "";
    if (at === 0 || style.charAt(at - 1) === ";" || style.charAt(at - 1) === " ") {
      const rest = style.slice(at + name.length).trimStart();
      if (rest.charAt(0) === ":") {
        const end = rest.indexOf(";");
        return (end < 0 ? rest.slice(1) : rest.slice(1, end)).trim();
      }
    }
    from = at + name.length;
  }
}

/**
 * The pieces of text a <text> holds, in the order the pen meets them, with the font, paint and
 * position of the element that holds each. A piece's alpha is the opacity of everything above
 * it, which the runtime multiplies into the paint.
 */
function collectPieces(el: HElement, s: State, ctx: Ctx): Piece[] {
  const pieces: Piece[] = [];
  const visit = (node: HElement, st: State, alpha: number): void => {
    // The position belongs to the element's first text; the rest of its text continues the pen.
    let posX = firstLenAttr(node, "x", ctx.vw);
    let posY = firstLenAttr(node, "y", ctx.vh);
    let dx = firstLenAttr(node, "dx", ctx.vw) ?? 0;
    let dy = firstLenAttr(node, "dy", ctx.vh) ?? 0;
    const font = st.fontFamily * 10000 + st.fontItalic * 1000 + st.fontWeight;
    const fill = paintRecord(ctx, st.fill, st.fillOpacity);
    const stroke = paintRecord(ctx, st.stroke, st.strokeOpacity);
    const take = (text: string): void => {
      if (text === "") return;
      pieces.push({
        x: posX, y: posY, dx, dy, size: st.fontSize, font, fill, stroke, width: st.strokeWidth,
        alpha, text,
      });
      posX = null;
      posY = null;
      dx = 0;
      dy = 0;
    };
    for (const kid of node.children) {
      if (kid.kind === "text") {
        take(kid.text);
        continue;
      }
      if (kid.kind === "pi") continue;
      const name = localName(kid.tag);
      if (name !== "tspan" && name !== "a" && name !== "text") continue;
      const inner = styleAt(kid, st, ctx);
      if (inner.hidden) continue;
      visit(kid, inner.s, alpha * inner.opacity);
    }
  };
  visit(el, s, 1);
  return pieces;
}

/**
 * Draws what a <use> references, moved by its x and y: the referenced element itself, or for a
 * <symbol> (or <svg>) a viewport of the use's width and height over that element's viewBox. The
 * referenced content sees the use element's style as its inherited style, so an icon's own fill,
 * stroke and color take over wherever the content doesn't set them.
 */
function drawUse(el: HElement, s: State, m: number[], alpha: number, out: number[], ctx: Ctx): number {
  let href = el.attrs.get("href") ?? el.attrs.get("xlink:href") ?? "";
  href = href.trim();
  if (!href.startsWith("#") || ctx.useDepth >= 16) return 0;
  const target = ctx.byId.get(href.slice(1));
  if (target === undefined || target === el) return 0;
  const x = absLen(el.attrs.get("x")) ?? 0;
  const y = absLen(el.attrs.get("y")) ?? 0;
  const mu = mul(m, [1, 0, 0, 1, x, y]);
  const name = localName(target.tag);
  let count = 0;
  ctx.useDepth++;
  if (name === "symbol" || name === "svg") {
    const w = absLen(el.attrs.get("width")) ?? absLen(target.attrs.get("width")) ?? ctx.vw;
    const h = absLen(el.attrs.get("height")) ?? absLen(target.attrs.get("height")) ?? ctx.vh;
    if (w > 0 && h > 0) {
      const view = parseViewBox((n) => target.attrs.get(n) ?? null);
      const [align, slice] = parseAspectRatio(target.attrs.get("preserveaspectratio") ?? null);
      const mm = view !== null ? mul(mu, viewMatrix(view, w, h, align, slice)) : mu;
      const inner = styleAt(target, s, ctx);
      if (!inner.hidden && inner.opacity > 0) {
        for (const kid of target.children) {
          if (kid.kind === "element") count += draw(kid, inner.s, mm, alpha * inner.opacity, out, ctx);
        }
      }
    }
  } else {
    count = draw(target, s, mu, alpha, out, ctx);
  }
  ctx.useDepth--;
  return count;
}

/** Whether a compiled paint draws anything: a colour or a gradient, but not `none`. */
function paintedRecord(paint: number): boolean {
  return paint >= 0 || paint <= PAINT_GRADIENT;
}

/** A paint for a record: a colour with its opacity applied, or a gradient table index. */
function paintRecord(ctx: Ctx, value: number, opacity: number): number {
  if (value > P.PAINT_URL) return painted(value, opacity);
  const id = ctx.paintIds[paintUrlIndex(value)];
  if (id === undefined) return P.PAINT_NONE;
  const kind = ctx.lookup.kind(id);
  if (kind === null) return P.PAINT_NONE;
  const g = parseGradient(kind, id, ctx.lookup, ctx.vw, ctx.vh);
  if (g === null) return P.PAINT_NONE;
  return PAINT_GRADIENT - gradientIndex(ctx, g, opacity);
}

/** The index of a gradient in the program's table, adding it when it isn't there yet. */
function gradientIndex(ctx: Ctx, g: SvgGradient, opacity: number): number {
  const stops: number[] = [];
  for (let i = 0; i + 1 < g.stops.length; i += 2) stops.push(painted(g.stops[i], opacity), g.stops[i + 1]);
  // Every row carries five coordinates whatever its kind, so the runtime can read one row the
  // same way for both: a linear gradient uses the first four and leaves the fifth at zero.
  const c = g.c.length >= 5 ? g.c : [...g.c, 0];
  const row = [g.kind, g.userSpace, ...c.map(number), ...g.transform.map(number), stops.length / 2,
    ...stops.map(number)];
  const key = row.join(",");
  const hit = ctx.gradAt.get(key);
  if (hit !== undefined) return hit;
  ctx.gradAt.set(key, ctx.gradCount);
  ctx.grads.push(...row);
  return ctx.gradCount++;
}

/** A paint with its alpha multiplied by an opacity; `none` passes through. */
function painted(color: number, opacity: number): number {
  if (color < 0) return color;
  const a = color & 255;
  return ((color & 0xffffff00) + Math.max(0, Math.min(255, Math.round(a * Math.max(0, Math.min(1, opacity)))))) >>> 0;
}
