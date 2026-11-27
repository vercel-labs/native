// Inline SVG: an <svg> element is a replaced box whose picture comes from its own subtree. The
// picture is drawn through the host's canvas paths: the element rasterizes into a bitmap of its
// own, sized in device pixels so it stays sharp on a 2x display, and paint draws that bitmap
// where the box sits (see the replaced branch of paintBox).
//
// What is drawn: rect, circle, ellipse, line, polyline, polygon and path (the full path grammar,
// arcs included), with `g` and shapes carrying transforms, the root's viewBox and
// preserveAspectRatio, and fill/stroke/stroke-width/stroke-linecap/stroke-linejoin/fill-rule/the
// opacities from each element's computed style. CSS and the presentation attributes both reach
// that style, so `fill="red"` and `rect { fill: red }` draw the same. The geometry itself lives in
// shared/svg.ts, which the compiler's SVG-image compiler uses too.
//
// A <use> draws the element its href names, moved by x and y, with the referenced content taking
// the use element's fill, stroke, color, stroke-width, cap, join, rule and opacities wherever the
// content doesn't declare them itself — the style inheritance that makes an icon sprite take the
// colour of the icon using it. A referenced <symbol> (or <svg>) is a viewport of the use element's
// width and height over the target's own viewBox.
//
// A <text> is drawn with the host's line layout: the pen runs along the baseline, <tspan> and <a>
// inside it taking their own x/y/dx/dy, font and paint, and `text-anchor` moving a run of text to
// its anchor point. Its glyphs are filled and stroked with the same paint properties a shape is.
//
// An element naming a `filter` paints as a group: it is drawn into a layer the size of the root
// bitmap, the filter runs over the region in device pixels, and the result is composited once
// (see runtime/svg-filters.ts for the primitives).
//
// Not drawn yet: masks, markers, `textPath`, glyph positioning (`textLength`, `letter-spacing`),
// and the filter primitives runtime/svg-filters.ts names as pass-throughs (feTile, feImage,
// feMorphology, feConvolveMatrix, feComponentTransfer, the lighting and displacement ones).

import * as P from "../shared/props.ts";
import { rasterScale } from "./device.ts";
import { fontMetrics, textWidth } from "./layout/text.ts";
import { rootFontSize } from "./root-size.ts";
import {
  hostCanvasCreate, hostCanvasResize, hostCanvasSetTransform,
  hostCanvasBeginPath, hostCanvasMoveTo, hostCanvasLineTo, hostCanvasQuadraticTo,
  hostCanvasBezierTo, hostCanvasClosePath, hostCanvasFill, hostCanvasStroke, hostCanvasClearRect,
  hostCanvasSetFillColor, hostCanvasSetStrokeColor, hostCanvasSetLineWidth, hostCanvasSetLineCap,
  hostCanvasSetLineJoin, hostCanvasSetLineDash, hostCanvasSave, hostCanvasRestore, hostCanvasClip,
  hostCanvasDraw, hostMeasureText, hostCanvasSetFont, hostCanvasFillText, hostCanvasStrokeText,
  hostCanvasSetAlpha, hostCanvasSetComposite, hostCanvasDrawCanvas, hostCanvasSvgFilter,
} from "./host.ts";
import type { Element, Node } from "./dom.ts";
import {
  applyPoint, emitPath, IDENTITY, invert, localName, mul, num, parseAspectRatio, parseSvgOrigin, parseTransform,
  parseViewBox, rectPath, shapePath, transformOps, viewMatrix, type PathSink,
} from "../shared/svg.ts";
import {
  listMatrix4, mulMatrix4, originDepth, originPoint, originRows, projectMatrix4, transformRows, translation4,
} from "../shared/css/transforms.ts";
import type { Matrix4, TransformContext } from "../shared/css/transforms.ts";
import { bboxOf, isPaintUrl, paintUrlIndex, type GradientLookup } from "../shared/svg-paint.ts";
import { anchorOf, layoutText, ANCHOR_START, type TextPiece } from "../shared/svg-text.ts";
import { dashRows } from "../shared/css/dasharray.ts";
import {
  clipPathRows, REF_BORDER_BOX, REF_STROKE_BOX, REF_VIEW_BOX, SH_CIRCLE, SH_ELLIPSE, SH_INSET,
  SH_PATH, SH_POLYGON,
} from "../shared/css/clip-path.ts";
import { positionRows } from "../shared/css/position.ts";
import { evalExpr } from "../shared/css/length-exprs.ts";
import { compileValue } from "../shared/css/declarations.ts";
import type { Decl } from "../shared/css/types.ts";
import { drawGradient, paintUrlAt, resolveGradient } from "./svg-paint.ts";
import { compileSvgFilter } from "./svg-filters.ts";
import { elementFilter } from "./filters.ts";
import { containerBasis, declaresProperty, fontKey } from "./style.ts";
import { viewport } from "./viewport.ts";

// ---------------------------------------------------------------------------
// Names, style and paint

/** The element's tag without a namespace prefix: "svg:path" is a path. */
function svgName(el: Node): string {
  return localName(el.localName);
}

/** The root's viewBox as [minX, minY, width, height], or null when it has none. */
export function svgViewBox(el: Element): number[] | null {
  return parseViewBox((name) => el.getAttribute(name));
}

/** A paint value resolved against the element: a packed colour, or -1 for none. */
function paintOf(el: Element, prop: number): number {
  return resolveColor(el.sv[prop], el.sv[P.P_COLOR]);
}

/** `currentColor` as the colour in effect. */
function resolveColor(v: number, color: number): number {
  return v === P.PAINT_CURRENT ? color : v;
}

/** A colour with its alpha multiplied by `alpha`. */
function withAlpha(color: number, alpha: number): number {
  const a = color & 255;
  return (color & 0xffffff00) + Math.max(0, Math.min(255, Math.round(a * Math.max(0, Math.min(1, alpha)))));
}

/** The stroke's pen width in user units, resolving a percentage against the viewport's diagonal. */
function strokeWidth(value: number, u: number, vw: number, vh: number): number {
  const v = value;
  if (u === P.U_PCT) return v / 100 * Math.sqrt((vw * vw + vh * vh) / 2);
  if (u === P.U_VW) return v / 100 * vw;
  if (u === P.U_VH) return v / 100 * vh;
  return v;
}

/**
 * A dash pattern as the host takes it: "<offset> <d0> <d1> …" in user units, or "" for a solid
 * line. A percentage in either resolves against the viewport's normalized diagonal.
 */
function dashOf(pattern: number, patternUnit: number, offset: number, offsetUnit: number,
  vw: number, vh: number): string {
  const row = pattern < 0 ? null : dashRows.row(pattern);
  if (row === null) return "";
  let text = String(strokeWidth(offset, offsetUnit, vw, vh));
  for (let i = 0; i + 1 < row.length; i += 2) {
    text += " " + strokeWidth(row[i], row[i + 1], vw, vh);
  }
  return text;
}

/** Elements whose subtree the painter doesn't draw: definitions and non-rendered content. */
function skips(name: string): boolean {
  return name === "defs" || name === "title" || name === "desc" || name === "metadata" ||
    name === "clippath" || name === "mask" || name === "symbol" || name === "marker" ||
    name === "pattern" || name === "lineargradient" || name === "radialgradient" ||
    name === "filter" || name === "style" || name === "script";
}

// ---------------------------------------------------------------------------
// <use>

/**
 * The style a <use> passes to the content it references: a referenced shape that declares none of
 * these takes the use element's value, as if it were a child of it (SVG 2 §5.6).
 */
interface UseStyle {
  fill: number;
  stroke: number;
  color: number;
  fillOpacity: number;
  strokeOpacity: number;
  strokeWidth: number;
  strokeWidthUnit: number;
  cap: number;
  join: number;
  rule: number;
  dash: number;
  dashUnit: number;
  dashOffset: number;
  dashOffsetUnit: number;
}

/** The presentation attribute a property is written as, or "" when it isn't one. */
function attrName(prop: number): string {
  if (prop === P.P_FILL) return "fill";
  if (prop === P.P_STROKE) return "stroke";
  if (prop === P.P_COLOR) return "color";
  if (prop === P.P_FILL_OPACITY) return "fill-opacity";
  if (prop === P.P_STROKE_OPACITY) return "stroke-opacity";
  if (prop === P.P_STROKE_WIDTH) return "stroke-width";
  if (prop === P.P_STROKE_LINECAP) return "stroke-linecap";
  if (prop === P.P_STROKE_LINEJOIN) return "stroke-linejoin";
  if (prop === P.P_FILL_RULE) return "fill-rule";
  if (prop === P.P_STROKE_DASHARRAY) return "stroke-dasharray";
  if (prop === P.P_STROKE_DASHOFFSET) return "stroke-dashoffset";
  return "";
}

/** Whether a style="" attribute names the property in a declaration of its own. */
function declaredInStyle(style: string, name: string): boolean {
  let from = 0;
  for (;;) {
    const at = style.indexOf(name, from);
    if (at < 0) return false;
    if (at === 0 || style.charAt(at - 1) === ";" || style.charAt(at - 1) === " ") {
      const rest = style.slice(at + name.length).trimStart();
      if (rest.charAt(0) === ":") return true;
    }
    from = at + name.length;
  }
}

/**
 * Whether the element sets the property itself, so that it wins over the use element's value:
 * a presentation attribute, a style="" declaration, or a rule of the sheet that matches it. A
 * copy in a use instance gets those styles from the referenced element's own rules, as Chrome's
 * does, and inherits only what the element doesn't declare.
 */
function declares(el: Element, prop: number): boolean {
  const name = attrName(prop);
  if (name === "") return true;
  const attr = el.getAttribute(name);
  if (attr !== null && attr.trim() !== "") return true;
  const style = el.getAttribute("style");
  if (style !== null && declaredInStyle(style, name)) return true;
  return declaresProperty(el, prop, name);
}

/** The use element's own computed style, the base for the content it references. */
function useStyleOf(el: Element): UseStyle {
  return {
    fill: el.sv[P.P_FILL], stroke: el.sv[P.P_STROKE], color: el.sv[P.P_COLOR],
    fillOpacity: el.sv[P.P_FILL_OPACITY], strokeOpacity: el.sv[P.P_STROKE_OPACITY],
    strokeWidth: el.sv[P.P_STROKE_WIDTH], strokeWidthUnit: el.su[P.P_STROKE_WIDTH],
    cap: el.sv[P.P_STROKE_LINECAP], join: el.sv[P.P_STROKE_LINEJOIN],
    rule: el.sv[P.P_FILL_RULE],
    dash: el.sv[P.P_STROKE_DASHARRAY], dashUnit: el.su[P.P_STROKE_DASHARRAY],
    dashOffset: el.sv[P.P_STROKE_DASHOFFSET], dashOffsetUnit: el.su[P.P_STROKE_DASHOFFSET],
  };
}

/** A style value of the element inside referenced content: its own, or the inherited one. */
function styleOf(el: Element, prop: number, inh: UseStyle): number {
  return declares(el, prop) ? el.sv[prop] : inheritedValue(inh, prop);
}

function inheritedValue(inh: UseStyle, prop: number): number {
  if (prop === P.P_FILL) return inh.fill;
  if (prop === P.P_STROKE) return inh.stroke;
  if (prop === P.P_COLOR) return inh.color;
  if (prop === P.P_FILL_OPACITY) return inh.fillOpacity;
  if (prop === P.P_STROKE_OPACITY) return inh.strokeOpacity;
  if (prop === P.P_STROKE_WIDTH) return inh.strokeWidth;
  if (prop === P.P_STROKE_LINECAP) return inh.cap;
  if (prop === P.P_STROKE_LINEJOIN) return inh.join;
  if (prop === P.P_FILL_RULE) return inh.rule;
  if (prop === P.P_STROKE_DASHARRAY) return inh.dash;
  if (prop === P.P_STROKE_DASHOFFSET) return inh.dashOffset;
  return 0;
}

/** The value a group passes on: the properties it sets take over, the rest carry down. */
function childStyle(el: Element, inh: UseStyle): UseStyle {
  return {
    fill: styleOf(el, P.P_FILL, inh), stroke: styleOf(el, P.P_STROKE, inh),
    color: styleOf(el, P.P_COLOR, inh), fillOpacity: styleOf(el, P.P_FILL_OPACITY, inh),
    strokeOpacity: styleOf(el, P.P_STROKE_OPACITY, inh),
    strokeWidth: styleOf(el, P.P_STROKE_WIDTH, inh),
    strokeWidthUnit: declares(el, P.P_STROKE_WIDTH) ? el.su[P.P_STROKE_WIDTH] : inh.strokeWidthUnit,
    cap: styleOf(el, P.P_STROKE_LINECAP, inh), join: styleOf(el, P.P_STROKE_LINEJOIN, inh),
    rule: styleOf(el, P.P_FILL_RULE, inh),
    dash: styleOf(el, P.P_STROKE_DASHARRAY, inh),
    dashUnit: declares(el, P.P_STROKE_DASHARRAY) ? el.su[P.P_STROKE_DASHARRAY] : inh.dashUnit,
    dashOffset: styleOf(el, P.P_STROKE_DASHOFFSET, inh),
    dashOffsetUnit: declares(el, P.P_STROKE_DASHOFFSET) ? el.su[P.P_STROKE_DASHOFFSET] : inh.dashOffsetUnit,
  };
}

/** The id a use element references, from href or the older xlink:href; "" when it has none. */
function useHref(el: Element): string {
  let href = el.getAttribute("href");
  if (href === null) href = el.getAttribute("xlink:href");
  if (href === null) return "";
  href = href.trim();
  return href.startsWith("#") ? href.slice(1) : "";
}

/** A length attribute in user units; a percentage resolves against `base`. */
function lengthOf(el: Element, name: string, base: number): number | null {
  const raw = el.getAttribute(name);
  if (raw === null || raw.trim() === "") return null;
  const text = raw.trim();
  if (text.endsWith("%")) {
    const v = parseFloat(text);
    return Number.isFinite(v) ? v / 100 * base : null;
  }
  const v = parseFloat(text);
  return Number.isFinite(v) ? v : null;
}

// ---------------------------------------------------------------------------
// Painting

// The host path calls are the sink a shape's operations replay into; the id is the bitmap being
// drawn into at the time.
let sinkId = -1;
const sink: PathSink = {
  moveTo: (x, y) => hostCanvasMoveTo(sinkId, x, y),
  lineTo: (x, y) => hostCanvasLineTo(sinkId, x, y),
  quadraticTo: (cx, cy, x, y) => hostCanvasQuadraticTo(sinkId, cx, cy, x, y),
  bezierTo: (c1x, c1y, c2x, c2y, x, y) => hostCanvasBezierTo(sinkId, c1x, c1y, c2x, c2y, x, y),
  close: () => hostCanvasClosePath(sinkId),
};

// The ids a paint server can name, gathered from the <svg> being painted: gradients live in
// <defs> or anywhere else in the same subtree.
let ids: Map<string, Element> | null = null;

function collectIds(el: Node): void {
  if (!el.isElementNode) return;
  const node = el as Element;
  const id = node.getAttribute("id");
  if (id !== null && id !== "" && ids !== null && !ids.has(id)) ids.set(id, node);
  for (const kid of el.kids) collectIds(kid);
}

const paintLookup: GradientLookup = {
  kind(id: string): number | null {
    const el = ids === null ? undefined : ids.get(id);
    if (el === undefined) return null;
    const name = svgName(el);
    return name === "lineargradient" ? 0 : name === "radialgradient" ? 1 : name === "pattern" ? 2 : null;
  },
  attrs(id: string) {
    const el = ids === null ? undefined : ids.get(id);
    return el === undefined ? null : (name: string) => el.getAttribute(name);
  },
  stops(id: string) {
    const el = ids === null ? undefined : ids.get(id);
    const out: ((name: string) => string | null)[] = [];
    if (el === undefined) return out;
    for (const kid of el.kids) {
      // The guard comes first: a text node is not an Element, and a downcast is checked.
      if (!kid.isElementNode) continue;
      const stop = kid as Element;
      if (svgName(stop) === "stop") out.push((name: string) => stop.getAttribute(name));
    }
    return out;
  },
};


/** One <pattern> as the tile it repeats. */
interface SvgPatternTile {
  x: number;
  y: number;
  w: number;
  h: number;
  /** patternUnits: userSpaceOnUse, rather than the unit square over the shape's bounding box. */
  userSpace: boolean;
  contentUserSpace: boolean;
  /** patternTransform, in pattern space. */
  transform: number[];
  viewBox: number[] | null;
  par: [number, boolean];
  /** The element whose children draw the tile: the pattern, or one it inherits content from. */
  content: Element;
}

/**
 * Reads the <pattern> with this id, following `href` for whatever the element doesn't set and for
 * its content. Null when the tile has no size, which paints nothing, as a browser's empty tile does.
 */
function patternFor(el: Element, vw: number, vh: number): SvgPatternTile | null {
  const chain: Element[] = [el];
  for (let d = 0; d < 16; d++) {
    const last = chain[chain.length - 1];
    const href = last.getAttribute("href") ?? last.getAttribute("xlink:href");
    if (href === null) break;
    const ref = href.trim().replace(/^#/, "");
    const next = ids === null ? undefined : ids.get(ref);
    if (next === undefined || chain.indexOf(next) >= 0) break;
    chain.push(next);
  }
  const attr = (name: string): string | null => {
    for (const e of chain) {
      const v = e.getAttribute(name);
      if (v !== null && v.trim() !== "") return v;
    }
    return null;
  };
  const userSpace = (attr("patternunits") ?? "").trim().toLowerCase() === "userspaceonuse";
  const contentUserSpace = (attr("patterncontentunits") ?? "").trim().toLowerCase() !== "objectboundingbox";
  const bw = userSpace ? vw : 1;
  const bh = userSpace ? vh : 1;
  const coord = (raw: string | null, base: number): number => {
    if (raw === null) return 0;
    const s = raw.trim();
    return s.endsWith("%") ? (num(s.slice(0, -1)) / 100) * base : num(s);
  };
  const x = coord(attr("x"), bw), y = coord(attr("y"), bh);
  const w = coord(attr("width"), bw), h = coord(attr("height"), bh);
  if (!(w > 0) || !(h > 0)) return null;
  let content: Element | null = null;
  for (const e of chain) {
    if (e.kids.some((k) => k.isElementNode)) {
      content = e;
      break;
    }
  }
  if (content === null) return null;
  const pt = attr("patterntransform");
  return {
    x, y, w, h, userSpace, contentUserSpace,
    transform: pt === null ? IDENTITY : parseTransform(pt),
    viewBox: parseViewBox(attr),
    par: parseAspectRatio(attr("preserveaspectratio")),
    content,
  };
}

/**
 * Fills the path in `canvas` with a pattern: the tile drawn again at every repeat across the
 * shape, each copy of the content clipped to its tile. `bbox` is the shape's bounding box in user
 * space and `m` the transform from there into the canvas.
 */
function drawPatternFill(canvas: number, pat: SvgPatternTile, bbox: number[], m: number[],
  alpha: number, rule: number, vw: number, vh: number, depth: number): void {
  if (!(alpha > 0) || depth > MAX_USE_DEPTH) return;
  // Pattern space into user space: patternUnits first, then the patternTransform.
  const units = pat.userSpace ? IDENTITY : [bbox[2], 0, 0, bbox[3], bbox[0], bbox[1]];
  const toUser = mul(units, pat.transform);
  const back = invert(toUser);
  if (back === null) return;
  // The shape's bounds in pattern space, where the tiles repeat.
  const c0 = applyPoint(back, bbox[0], bbox[1]);
  const c1 = applyPoint(back, bbox[0] + bbox[2], bbox[1]);
  const c2 = applyPoint(back, bbox[0] + bbox[2], bbox[1] + bbox[3]);
  const c3 = applyPoint(back, bbox[0], bbox[1] + bbox[3]);
  const x0 = Math.min(c0[0], c1[0], c2[0], c3[0]), x1 = Math.max(c0[0], c1[0], c2[0], c3[0]);
  const y0 = Math.min(c0[1], c1[1], c2[1], c3[1]), y1 = Math.max(c0[1], c1[1], c2[1], c3[1]);
  const i0 = Math.floor((x0 - pat.x) / pat.w), i1 = Math.ceil((x1 - pat.x) / pat.w);
  const j0 = Math.floor((y0 - pat.y) / pat.h), j1 = Math.ceil((y1 - pat.y) / pat.h);
  if (!Number.isFinite(i0) || !Number.isFinite(i1) || !Number.isFinite(j0) || !Number.isFinite(j1)) return;
  // A tile repeating this many times can't be drawn one copy at a time.
  if ((i1 - i0) * (j1 - j0) > 4096) return;
  // The content maps into the tile: objectBoundingBox content units put the unit square over it,
  // and a viewBox maps the content's own box onto the tile.
  const content = !pat.contentUserSpace ? [pat.w, 0, 0, pat.h, 0, 0]
    : pat.viewBox === null ? IDENTITY : viewMatrix(pat.viewBox, pat.w, pat.h, pat.par[0], pat.par[1]);
  const base = mul(m, toUser);
  const tilePath = rectPath(0, 0, pat.w, pat.h, 0, 0);
  for (let j = j0; j < j1; j++) {
    for (let i = i0; i < i1; i++) {
      const tile = mul(base, [1, 0, 0, 1, pat.x + i * pat.w, pat.y + j * pat.h]);
      hostCanvasSave(canvas);
      hostCanvasSetTransform(canvas, tile[0], tile[1], tile[2], tile[3], tile[4], tile[5]);
      hostCanvasBeginPath(canvas);
      sinkId = canvas;
      emitPath(tilePath, sink);
      hostCanvasClip(canvas, 0);
      drawChildren(pat.content, canvas, mul(tile, content), vw, vh, alpha, null, depth + 1, []);
      hostCanvasRestore(canvas);
    }
  }
}

/** How deep a chain of use elements may go before the painter treats it as a cycle. */
const MAX_USE_DEPTH = 16;

// ---------------------------------------------------------------------------
// clip-path

/** One shape of a clip path: its operations, and the matrix they are in. */
interface ClipPart {
  m: number[];
  ops: number[];
}

/** A clip path resolved into the shapes it is the union of, and the rule that fills them. */
interface Clip {
  parts: ClipPart[];
  rule: number;
}

/** The id a clip-path property names, from the attribute or a style="" declaration. */
function clipRef(el: Element): string {
  let value = el.getAttribute("clip-path");
  if (value === null) {
    const style = el.getAttribute("style");
    if (style !== null) {
      const at = style.indexOf("clip-path");
      if (at >= 0) value = style.slice(at + "clip-path".length).trimStart();
    }
  }
  if (value === null) return "";
  const text = value.trim();
  if (!text.startsWith("url(")) return "";
  const close = text.indexOf(")");
  if (close < 0) return "";
  const ref = text.slice(4, close).trim();
  return ref.startsWith("#") ? ref.slice(1) : "";
}


/** The <filter> named by a url(#id) reference, or null when the id isn't a filter. */
function filterById(ref: string): Element | null {
  const id = ref.trim().replace(/^#/, "");
  if (id === "" || ids === null) return null;
  const target = ids.get(id);
  return target !== undefined && svgName(target) === "filter" ? target : null;
}

/**
 * The <filter> an element's filter names, or null. The cascade's filter list holds the reference
 * when a rule (or a style="" read at runtime) set one — `filter: url(#f)` — and the presentation
 * attribute is read when no declaration did, as it stands in for a zero-specificity one.
 */
function filterTarget(el: Element): Element | null {
  if (el.sv[P.P_FILTER] >= 0) {
    for (const op of elementFilter(el)) {
      if (op.kind !== P.FK_URL) continue;
      const ref = paintUrlAt(op.a);
      const target = ref === null ? null : filterById(ref);
      if (target !== null) return target;
    }
    return null;
  }
  const value = attrOrStyle(el, "filter");
  if (value === "") return null;
  const text = value.trim();
  if (!/^url\(/i.test(text)) return null;
  const close = text.indexOf(")");
  if (close < 0) return null;
  const ref = text.slice(4, close).trim();
  return ref.startsWith("#") ? filterById(ref) : null;
}

/** An element's bounds in its own user space, the box a filter region measures in. */
function filterBBox(node: Element, name: string, vw: number, vh: number): number[] {
  if (name === "text") return textBBox(node, vw, vh);
  if (name === "g" || name === "a" || name === "svg" || name === "use") {
    const box = contentPaintBBox(node, vw, vh);
    // A group whose drawn bounds the walk can't see (a <use> naming an icon, say) still has a
    // region: the viewport stands in, so the filter paints something rather than nothing.
    return box[2] > 0 && box[3] > 0 ? box : [0, 0, vw, vh];
  }
  return bboxOf(shapePath(name, (attr) => node.getAttribute(attr), vw, vh));
}

/** A user-space rect after a transform, as the box that holds every corner. */
function transformBoxRect(box: number[], m: number[]): number[] {
  const xs = [box[0], box[0] + box[2]], ys = [box[1], box[1] + box[3]];
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const x of xs) {
    for (const y of ys) {
      const X = m[0] * x + m[2] * y + m[4];
      const Y = m[1] * x + m[3] * y + m[5];
      if (X < x0) x0 = X;
      if (Y < y0) y0 = Y;
      if (X > x1) x1 = X;
      if (Y > y1) y1 = Y;
    }
  }
  return [x0, y0, x1 - x0, y1 - y0];
}

/**
 * The bounds a group's contents paint in its own user space: the shapes contentBBox walks, and
 * the text it leaves out. A filter region on a group of text needs the runs' boxes.
 */
function contentPaintBBox(el: Node, vw: number, vh: number): number[] {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  const add = (box: number[]): void => {
    if (box[0] < x0) x0 = box[0];
    if (box[1] < y0) y0 = box[1];
    if (box[0] + box[2] > x1) x1 = box[0] + box[2];
    if (box[1] + box[3] > y1) y1 = box[1] + box[3];
  };
  const walk = (node: Node, m: number[]): void => {
    if (!node.isElementNode) return;
    const e = node as Element;
    if (e.sv[P.P_DISPLAY] === P.D_NONE) return;
    const name = svgName(e);
    if (skips(name)) return;
    const m2 = mul(m, svgMatrix(e, vw, vh));
    if (name === "g" || name === "a" || name === "svg") {
      for (const kid of e.kids) walk(kid, m2);
      return;
    }
    if (name === "text") {
      add(transformBoxRect(textBBox(e, vw, vh), m2));
      return;
    }
    const ops = shapePath(name, (attr) => e.getAttribute(attr), vw, vh);
    if (ops.length > 0) add(bboxOf(transformOps(ops, m2)));
  };
  for (const kid of el.kids) walk(kid, [1, 0, 0, 1, 0, 0]);
  if (!(x1 >= x0) || !(y1 >= y0)) return [0, 0, 0, 0];
  return [x0, y0, x1 - x0, y1 - y0];
}

/** The bounds of a text's runs, with the font's ascent and descent around each baseline. */
function textBBox(node: Element, vw: number, vh: number): number[] {
  const runs = layoutText(textPieces(node, vw, vh, null), ANCHOR_START,
    (text, size, font) => hostMeasureText(text, size, font, 0, 0));
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const r of runs) {
    const w = hostMeasureText(r.text, r.size, r.font, 0, 0);
    if (r.x < x0) x0 = r.x;
    if (r.x + w > x1) x1 = r.x + w;
    if (r.y - r.size * 0.8 < y0) y0 = r.y - r.size * 0.8;
    if (r.y + r.size * 0.2 > y1) y1 = r.y + r.size * 0.2;
  }
  if (!(x1 >= x0) || !(y1 >= y0)) return [0, 0, 0, 0];
  return [x0, y0, x1 - x0, y1 - y0];
}

/**
 * The user-space matrix a node draws with: its CSS `transform` and individual `translate`,
 * `rotate` and `scale` properties, or its `transform` attribute when the property is empty (the
 * attribute is a presentation hint for the property, so the property replaces it). An SVG
 * element's reference box is the viewport and its default transform-origin is its own 0 0.
 */
function svgMatrix(el: Element, vw: number, vh: number): number[] {
  // transform-box names the reference box: its percentages and its origin measure that box, so
  // the transform context is the box's size rather than the viewport's.
  const box = transformOriginBox(el, vw, vh);
  const ctx: TransformContext = {
    w: box[2], h: box[3], fontSize: el.sv[P.P_FONT_SIZE], lh: el.sv[P.P_LINE_HEIGHT],
    rem: rootFontSize(), ex: fontMetrics(el)[2], ch: textWidth(el, "0"),
    viewportW: viewport.w, viewportH: viewport.h,
    cqw: containerBasis(el, false), cqh: containerBasis(el, true),
  };
  let m: Matrix4 | null = null;
  let origin = [0, 0, 0];
  const css = el.su[P.P_TRANSFORM] === P.U_LIST || el.su[P.P_SCALE] === P.U_LIST ||
    el.su[P.P_ROTATE] === P.U_LIST || el.su[P.P_TRANSLATE] === P.U_LIST;
  if (el.su[P.P_TRANSFORM] === P.U_LIST) {
    const row = transformRows.row(el.sv[P.P_TRANSFORM]);
    if (row !== null) m = listMatrix4(row, ctx);
  } else {
    const a = attributeMatrix(el, vw, vh);
    m = new Float64Array([a[0], a[1], 0, 0, a[2], a[3], 0, 0, 0, 0, 1, 0, a[4], a[5], 0, 1]);
  }
  if (css) {
    // The origin is a point in the reference box, whose unset 0 0 is its corner. The attribute is
    // a presentation hint, so it stands in when the declaration didn't compile — SVG writes a bare
    // number for a length, which CSS's transform-origin grammar doesn't take.
    let p: number[] | null = null;
    let z = 0;
    if (el.su[P.P_TRANSFORM_ORIGIN] === P.U_LIST) {
      const orow = originRows.row(el.sv[P.P_TRANSFORM_ORIGIN]);
      if (orow !== null) {
        p = originPoint(orow, ctx);
        z = originDepth(orow, ctx);
      }
    } else {
      const attr = el.getAttribute("transform-origin");
      if (attr !== null && attr.trim() !== "") {
        const q = parseSvgOrigin(attr, box);
        if (q !== null) p = [q[0] - box[0], q[1] - box[1]];
      }
    }
    if (p === null) p = [0, 0];
    origin = [box[0] + p[0], box[1] + p[1], z];
  }
  // Each individual property lands outside the one before it: scale, then rotate, then translate.
  for (const p of [P.P_SCALE, P.P_ROTATE, P.P_TRANSLATE]) {
    if (el.su[p] !== P.U_LIST) continue;
    const row = transformRows.row(el.sv[p]);
    if (row === null) continue;
    const mm = listMatrix4(row, ctx);
    if (mm !== null) m = m === null ? mm : mulMatrix4(m, mm);
  }
  if (m === null) return IDENTITY;
  if (origin[0] !== 0 || origin[1] !== 0 || origin[2] !== 0) {
    m = mulMatrix4(mulMatrix4(translation4(-origin[0], -origin[1], -origin[2]), m), translation4(origin[0], origin[1], origin[2]));
  }
  const out = projectMatrix4(m);
  return [out.a, out.b, out.c, out.d, out.e, out.f];
}

/**
 * The `transform` attribute's matrix, turned about its `transform-origin` attribute: an SVG
 * element's default origin is 0 0 in its own user space, and the attribute may name another point
 * in lengths (any CSS unit) or percentages of the viewport.
 */
function attributeMatrix(el: Element, vw: number, vh: number): number[] {
  const t = el.getAttribute("transform");
  if (t === null || t.trim() === "") return IDENTITY;
  const m = parseTransform(t);
  const o = el.getAttribute("transform-origin");
  if (o === null || o.trim() === "") return m;
  const origin = parseSvgOrigin(o, transformOriginBox(el, vw, vh));
  if (origin === null) return m;
  return mul(mul([1, 0, 0, 1, origin[0], origin[1]], m), [1, 0, 0, 1, -origin[0], -origin[1]]);
}

/**
 * The box a transform's percentages and its origin resolve against: transform-box's box. An SVG
 * element's view-box is the viewport its own user space is measured in; its fill box is the
 * object's bounds. It has no border box, so border-box means its stroke box (the bounds grown by
 * half the stroke) and content-box means its fill box.
 */
function transformOriginBox(el: Element, vw: number, vh: number): number[] {
  const tb = el.sv[P.P_TRANSFORM_BOX];
  if (tb === P.TB_VIEW_BOX) return [0, 0, vw, vh];
  const name = svgName(el);
  let box: number[];
  if (name === "foreignobject") {
    box = [lengthOf(el, "x", vw) ?? 0, lengthOf(el, "y", vh) ?? 0,
      lengthOf(el, "width", vw) ?? 0, lengthOf(el, "height", vh) ?? 0];
  } else if (name === "g" || name === "a" || name === "svg" || name === "use") {
    box = contentBBox(el, vw, vh);
  } else {
    box = bboxOf(shapePath(name, (attr) => el.getAttribute(attr), vw, vh));
  }
  if (tb === P.TB_STROKE_BOX || tb === P.TB_BORDER_BOX) {
    const w = strokeWidth(el.sv[P.P_STROKE_WIDTH], el.su[P.P_STROKE_WIDTH], vw, vh);
    if (w > 0) box = [box[0] - w / 2, box[1] - w / 2, box[2] + w, box[3] + w];
  }
  return box;
}

/**
 * A clip path as the shapes its subtree draws, in the space `base` maps them into. A
 * `clipPathUnits` of `objectBoundingBox` maps the unit box onto `bbox` first; without a box the
 * clip is left as it is, which is what a group with no bounds of its own gets.
 */
function resolveClip(target: Element, base: number[], bbox: number[] | null, vw: number, vh: number): Clip {
  // The build's parser lowercases every attribute name, so the mixed-case spelling is the
  // one only a script sets; take either.
  const units = (target.getAttribute("clippathunits") ?? target.getAttribute("clipPathUnits") ?? "")
    .trim().toLowerCase();
  let root = base;
  if (units === "objectboundingbox" && bbox !== null) {
    root = mul(base, [bbox[2], 0, 0, bbox[3], bbox[0], bbox[1]]);
  }
  const parts: ClipPart[] = [];
  const walk = (node: Node, m: number[]): void => {
    if (!node.isElementNode) return;
    const el = node as Element;
    if (el.sv[P.P_DISPLAY] === P.D_NONE) return;
    const name = svgName(el);
    const m2 = mul(m, svgMatrix(el, vw, vh));
    if (name === "g" || name === "a") {
      for (const kid of el.kids) walk(kid, m2);
      return;
    }
    const ops = shapePath(name, (attr) => el.getAttribute(attr), vw, vh);
    if (ops.length > 0) parts.push({ m: m2, ops });
  };
  for (const kid of target.kids) walk(kid, root);
  const rule = (target.getAttribute("clip-rule") ?? "").trim().toLowerCase() === "evenodd" ? 1 : 0;
  return { parts, rule };
}

/** The bounds a group's contents cover in its own user space, in [x, y, w, h]. */
function contentBBox(el: Node, vw: number, vh: number): number[] {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  const walk = (node: Node, m: number[]): void => {
    if (!node.isElementNode) return;
    const e = node as Element;
    if (e.sv[P.P_DISPLAY] === P.D_NONE) return;
    const name = svgName(e);
    const m2 = mul(m, svgMatrix(e, vw, vh));
    if (name === "g" || name === "a" || name === "svg") {
      for (const kid of e.kids) walk(kid, m2);
      return;
    }
    const ops = shapePath(name, (attr) => e.getAttribute(attr), vw, vh);
    if (ops.length === 0) return;
    const box = bboxOf(transformOps(ops, m2));
    if (box[0] < x0) x0 = box[0];
    if (box[1] < y0) y0 = box[1];
    if (box[0] + box[2] > x1) x1 = box[0] + box[2];
    if (box[1] + box[3] > y1) y1 = box[1] + box[3];
  };
  // The bounds are in the element's own user space, so its own transform isn't part of them:
  // walk the children, not the group itself.
  for (const kid of el.kids) walk(kid, [1, 0, 0, 1, 0, 0]);
  if (!(x1 >= x0) || !(y1 >= y0)) return [0, 0, 0, 0];
  return [x0, y0, x1 - x0, y1 - y0];
}

/** The clip paths an element is inside, plus its own when it names one. */
function withClips(node: Element, m: number[], vw: number, vh: number, clips: Clip[]): Clip[] {
  let list = clips;
  // A url(#id) the attribute or style names.
  const ref = clipRef(node);
  if (ref !== "" && ids !== null) {
    const target = ids.get(ref);
    if (target !== undefined && svgName(target) === "clippath") {
      const name = svgName(node);
      const bbox = name === "g" || name === "a" || name === "svg" || name === "use"
        ? contentBBox(node, vw, vh)
        : bboxOf(shapePath(name, (attr) => node.getAttribute(attr), vw, vh));
      list = clips.slice();
      list.push(resolveClip(target, m, bbox, vw, vh));
    }
  }
  // A basic shape from the property or from the presentation attribute, resolved in the
  // element's own user space against the box the shape names. The build leaves an SVG element's
  // presentation attributes to the runtime, so a `clip-path="circle(…) border-box"` attribute is
  // compiled here, once per distinct text.
  let row: readonly number[] | null = null;
  if (node.sv[P.P_CLIP_PATH] >= 0 && node.su[P.P_CLIP_PATH] === P.U_LIST) {
    row = clipPathRows.row(node.sv[P.P_CLIP_PATH]);
  }
  if (row === null) {
    const text = node.getAttribute("clip-path");
    if (text !== null && text.trim() !== "" && !/^url\(/i.test(text.trim())) {
      const id = clipRowOfText(text.trim());
      if (id >= 0) row = clipPathRows.row(id);
    }
  }
  if (row !== null) {
    const shape = basicShapeClip(node, row, m, vw, vh);
    if (shape !== null) {
      if (list === clips) list = clips.slice();
      list.push(shape);
    }
  }
  return list;
}

/** Clip-path rows parsed from presentation attributes, by their text; -1 when unsupported. */
const attrClipRows: Map<string, number> = new Map();

/** The row a raw clip-path value compiles to, or -1 when this build doesn't take it. */
function clipRowOfText(text: string): number {
  const hit = attrClipRows.get(text);
  if (hit !== undefined) return hit;
  const out: Decl[] = [];
  compileValue("clip-path", text, out);
  let id = -1;
  for (const d of out) if (d.p === P.P_CLIP_PATH && d.u === P.U_LIST) id = d.v;
  attrClipRows.set(text, id);
  return id;
}

/** How far a cubic's control points sit along the sides of a quarter-circle. */
const KAPPA = 0.5522847498307936;

function moveOp(ops: number[], x: number, y: number): void { ops.push(1, x, y); }
function lineOp(ops: number[], x: number, y: number): void { ops.push(2, x, y); }
function cubicOp(ops: number[], c1x: number, c1y: number, c2x: number, c2y: number, x: number, y: number): void {
  ops.push(4, c1x, c1y, c2x, c2y, x, y);
}

/** A basic-shape length in user units: a percentage against `ref`, the rest as CSS lengths. */
function clipLen(v: number, u: number, el: Element, ref: number): number {
  switch (u) {
    case P.U_PCT: return (v / 100) * ref;
    case P.U_EM: return v * el.sv[P.P_FONT_SIZE];
    case P.U_REM: return v * rootFontSize();
    case P.U_VW: return (v / 100) * viewport.w;
    case P.U_VH: return (v / 100) * viewport.h;
    case P.U_EXPR:
      return evalExpr(v, ref, viewport.w, viewport.h, el.sv[P.P_FONT_SIZE], viewport.w, viewport.h,
        rootFontSize(), el.sv[P.P_LINE_HEIGHT]);
    default: return v;
  }
}

/** An ellipse's outline as four cubics. */
function ellipsePath(cx: number, cy: number, rx: number, ry: number, ops: number[]): void {
  moveOp(ops, cx + rx, cy);
  cubicOp(ops, cx + rx, cy + ry * KAPPA, cx + rx * KAPPA, cy + ry, cx, cy + ry);
  cubicOp(ops, cx - rx * KAPPA, cy + ry, cx - rx, cy + ry * KAPPA, cx - rx, cy);
  cubicOp(ops, cx - rx, cy - ry * KAPPA, cx - rx * KAPPA, cy - ry, cx, cy - ry);
  cubicOp(ops, cx + rx * KAPPA, cy - ry, cx + rx, cy - ry * KAPPA, cx + rx, cy);
  ops.push(5);
}

/**
 * A rounded rectangle's outline. Its corner radii are [x,y] pairs for the top-left, top-right,
 * bottom-right and bottom-left corners, reduced by one factor as CSS reduces them so opposite
 * corners still fit on their side.
 */
function roundedRectPath(x: number, y: number, w: number, h: number, radii: number[], ops: number[]): void {
  let f = 1;
  const pair = (i: number) => [radii[i * 2] ?? 0, radii[i * 2 + 1] ?? 0];
  const [tlx, tly] = pair(0), [trx, try_] = pair(1), [brx, bry] = pair(2), [blx, bly] = pair(3);
  if (tlx + trx > 0) f = Math.min(f, w / (tlx + trx));
  if (blx + brx > 0) f = Math.min(f, w / (blx + brx));
  if (tly + bly > 0) f = Math.min(f, h / (tly + bly));
  if (try_ + bry > 0) f = Math.min(f, h / (try_ + bry));
  const tlh = tlx * f, tlv = tly * f, trh = trx * f, trv = try_ * f;
  const brh = brx * f, brv = bry * f, blh = blx * f, blv = bly * f;
  moveOp(ops, x + tlh, y);
  lineOp(ops, x + w - trh, y);
  if (trh > 0 || trv > 0) {
    cubicOp(ops, x + w - trh + KAPPA * trh, y, x + w, y + trv - KAPPA * trv, x + w, y + trv);
  }
  lineOp(ops, x + w, y + h - brv);
  if (brh > 0 || brv > 0) {
    cubicOp(ops, x + w, y + h - brv + KAPPA * brv, x + w - brh + KAPPA * brh, y + h, x + w - brh, y + h);
  }
  lineOp(ops, x + blh, y + h);
  if (blh > 0 || blv > 0) {
    cubicOp(ops, x + blh - KAPPA * blh, y + h, x, y + h - blv + KAPPA * blv, x, y + h - blv);
  }
  lineOp(ops, x, y + tlv);
  if (tlh > 0 || tlv > 0) {
    cubicOp(ops, x, y + tlv - KAPPA * tlv, x + tlh - KAPPA * tlh, y, x + tlh, y);
  }
  ops.push(5);
}

/** A paragraph's outline, moved by the box's origin. */
function offsetOps(row: readonly number[], from: number, ox: number, oy: number, ops: number[]): void {
  for (let i = from; i < row.length;) {
    const kind = row[i];
    if (kind === 1 || kind === 2) {
      ops.push(kind, ox + row[i + 1], oy + row[i + 2]);
      i += 3;
    } else if (kind === 3) {
      ops.push(kind, ox + row[i + 1], oy + row[i + 2], ox + row[i + 3], oy + row[i + 4]);
      i += 5;
    } else if (kind === 4) {
      ops.push(kind, ox + row[i + 1], oy + row[i + 2], ox + row[i + 3], oy + row[i + 4],
        ox + row[i + 5], oy + row[i + 6]);
      i += 7;
    } else {
      ops.push(kind);
      i += 1;
    }
  }
}

/** An <svg> element's viewport attribute as a length: a percentage against `base`. */
function viewportAttr(el: Element, name: string, base: number): number {
  const raw = el.getAttribute(name);
  if (raw === null) return 0;
  const t = raw.trim();
  const v = parseFloat(t);
  if (!Number.isFinite(v)) return 0;
  return t.endsWith("%") ? (v / 100) * base : v;
}

/** The box a basic shape on an SVG element resolves against, in the element's own user space. */
function svgShapeBox(el: Element, ref: number, vw: number, vh: number): number[] | null {
  if (ref === REF_VIEW_BOX) return vw > 0 && vh > 0 ? [0, 0, vw, vh] : null;
  const name = svgName(el);
  let box: number[];
  if (name === "foreignobject") {
    box = [viewportAttr(el, "x", vw), viewportAttr(el, "y", vh),
      viewportAttr(el, "width", vw), viewportAttr(el, "height", vh)];
  } else if (name === "g" || name === "a" || name === "svg" || name === "use") {
    box = contentBBox(el, vw, vh);
  } else {
    box = bboxOf(shapePath(name, (attr) => el.getAttribute(attr), vw, vh));
  }
  // An SVG element has no border box: its used value is the stroke box, the object bounding box
  // grown by half the stroke. Every other box a shape names is the object bounding box.
  if (ref === REF_BORDER_BOX || ref === REF_STROKE_BOX) {
    const w = strokeWidth(el.sv[P.P_STROKE_WIDTH], el.su[P.P_STROKE_WIDTH], vw, vh);
    if (w > 0) box = [box[0] - w / 2, box[1] - w / 2, box[2] + w, box[3] + w];
  }
  if (!(box[2] > 0) || !(box[3] > 0)) return null;
  return box;
}

/** A basic-shape `clip-path` on an SVG element, as the shapes its outline draws. */
function basicShapeClip(el: Element, row: readonly number[], m: number[], vw: number, vh: number): Clip | null {
  if (row.length < 3) return null;
  const kind = row[0];
  const box = svgShapeBox(el, row[1], vw, vh);
  if (box === null) return null;
  const bx = box[0], by = box[1], bw = box[2], bh = box[3];
  const ops: number[] = [];
  let evenOdd = row[2] === P.FR_EVENODD;
  if (kind === SH_INSET) {
    const top = clipLen(row[3], row[4], el, bh);
    const right = clipLen(row[5], row[6], el, bw);
    const bottom = clipLen(row[7], row[8], el, bh);
    const left = clipLen(row[9], row[10], el, bw);
    const x = bx + left, y = by + top;
    const w = Math.max(0, bw - left - right), h = Math.max(0, bh - top - bottom);
    const radii = [0, 0, 0, 0, 0, 0, 0, 0];
    if (row.length >= 27) {
      for (let c = 0; c < 4; c++) {
        radii[c * 2] = Math.max(0, clipLen(row[11 + c * 4], row[12 + c * 4], el, w));
        radii[c * 2 + 1] = Math.max(0, clipLen(row[13 + c * 4], row[14 + c * 4], el, h));
      }
    }
    if (w > 0 && h > 0) roundedRectPath(x, y, w, h, radii, ops);
  } else if (kind === SH_CIRCLE || kind === SH_ELLIPSE) {
    const pos = kind === SH_CIRCLE ? row[5] : row[7];
    const prow = positionRows.row(pos);
    let px = bw / 2, py = bh / 2;
    if (prow !== null && prow.length >= 6) {
      const xv = clipLen(prow[0], prow[1], el, bw);
      const yv = clipLen(prow[3], prow[4], el, bh);
      px = prow[2] === 1 ? bw - xv : xv;
      py = prow[5] === 1 ? bh - yv : yv;
    }
    if (kind === SH_CIRCLE) {
      let r: number;
      if (row[4] === P.U_CLOSEST_SIDE) r = Math.max(0, Math.min(px, bw - px, py, bh - py));
      else if (row[4] === P.U_FARTHEST_SIDE) r = Math.max(px, bw - px, py, bh - py);
      else r = Math.max(0, clipLen(row[3], row[4], el, Math.sqrt((bw * bw + bh * bh) / 2)));
      if (r > 0) ellipsePath(bx + px, by + py, r, r, ops);
    } else {
      let rx: number, ry: number;
      if (row[4] === P.U_CLOSEST_SIDE) rx = Math.max(0, Math.min(px, bw - px));
      else if (row[4] === P.U_FARTHEST_SIDE) rx = Math.max(px, bw - px);
      else rx = Math.max(0, clipLen(row[3], row[4], el, bw));
      if (row[6] === P.U_CLOSEST_SIDE) ry = Math.max(0, Math.min(py, bh - py));
      else if (row[6] === P.U_FARTHEST_SIDE) ry = Math.max(py, bh - py);
      else ry = Math.max(0, clipLen(row[5], row[6], el, bh));
      if (rx > 0 && ry > 0) ellipsePath(bx + px, by + py, rx, ry, ops);
    }
  } else if (kind === SH_POLYGON) {
    let first = true;
    for (let k = 3; k + 3 < row.length; k += 4) {
      const px = bx + clipLen(row[k], row[k + 1], el, bw);
      const py = by + clipLen(row[k + 2], row[k + 3], el, bh);
      if (first) moveOp(ops, px, py);
      else lineOp(ops, px, py);
      first = false;
    }
    if (!first) ops.push(5);
    evenOdd = row[2] === P.FR_EVENODD;
  } else if (kind === SH_PATH) {
    offsetOps(row, 3, bx, by, ops);
    evenOdd = row[2] === P.FR_EVENODD;
  } else {
    return null;
  }
  if (ops.length === 0) return null;
  return { parts: [{ m, ops }], rule: evenOdd ? 1 : 0 };
}

/** Clips the host canvas to a clip path, in the space each of its parts is in. */
function clipTo(id: number, clip: Clip): void {
  // Its own path: a second clip intersects the first, so it must not carry the first's shapes.
  hostCanvasBeginPath(id);
  for (const part of clip.parts) {
    hostCanvasSetTransform(id, part.m[0], part.m[1], part.m[2], part.m[3], part.m[4], part.m[5]);
    sinkId = id;
    emitPath(part.ops, sink);
  }
  hostCanvasClip(id, clip.rule);
}

// ---------------------------------------------------------------------------
// text

/** The first length an attribute lists ("10 20 30" starts at 10); null without one. */
function firstLength(el: Element, name: string, base: number): number | null {
  const raw = el.getAttribute(name);
  if (raw === null || raw.trim() === "") return null;
  const text = raw.trim().split(/[\s,]+/)[0];
  const v = text.endsWith("%") ? parseFloat(text) / 100 * base : parseFloat(text);
  return Number.isFinite(v) ? v : null;
}

/**
 * A value the element writes as an attribute or in its style="", for the properties the SVG
 * painter reads itself because CSS doesn't compute them: "" when it writes neither.
 */
function attrOrStyle(el: Element, name: string): string {
  const attr = el.getAttribute(name);
  if (attr !== null && attr.trim() !== "") return attr.trim();
  const style = el.getAttribute("style");
  if (style === null) return "";
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

/** What the text an element holds is painted with. */
function textPaint(el: Element, inh: UseStyle | null, vw: number, vh: number): {
  fill: number; stroke: number; width: number; fillOpacity: number; strokeOpacity: number;
} {
  if (inh === null) {
    return {
      fill: paintOf(el, P.P_FILL),
      stroke: paintOf(el, P.P_STROKE),
      width: strokeWidth(el.sv[P.P_STROKE_WIDTH], el.su[P.P_STROKE_WIDTH], vw, vh),
      fillOpacity: el.sv[P.P_FILL_OPACITY],
      strokeOpacity: el.sv[P.P_STROKE_OPACITY],
    };
  }
  const color = styleOf(el, P.P_COLOR, inh);
  return {
    fill: resolveColor(styleOf(el, P.P_FILL, inh), color),
    stroke: resolveColor(styleOf(el, P.P_STROKE, inh), color),
    width: strokeWidth(styleOf(el, P.P_STROKE_WIDTH, inh),
      declares(el, P.P_STROKE_WIDTH) ? el.su[P.P_STROKE_WIDTH] : inh.strokeWidthUnit, vw, vh),
    fillOpacity: styleOf(el, P.P_FILL_OPACITY, inh),
    strokeOpacity: styleOf(el, P.P_STROKE_OPACITY, inh),
  };
}

/**
 * The pieces of text a <text> holds, in the order the pen meets them: each text node with the
 * font, paint and position of the element that holds it. A <tspan> or <a> inside starts a
 * position of its own when it names x or y, and shifts the pen with dx/dy.
 */
function textPieces(el: Element, vw: number, vh: number, inh: UseStyle | null): TextPiece[] {
  const pieces: TextPiece[] = [];
  const collect = (node: Element, style: UseStyle | null): void => {
    const paint = textPaint(node, style, vw, vh);
    const size = node.sv[P.P_FONT_SIZE];
    const font = fontKey(node);
    // The position belongs to the element's first text; the rest of its text continues the pen.
    let posX = firstLength(node, "x", vw);
    let posY = firstLength(node, "y", vh);
    let dx = firstLength(node, "dx", vw) ?? 0;
    let dy = firstLength(node, "dy", vh) ?? 0;
    const take = (text: string): void => {
      if (text === "") return;
      pieces.push({
        text, x: posX, y: posY, dx, dy, size, font,
        fill: paint.fill, stroke: paint.stroke, width: paint.width,
        fillAlpha: paint.fillOpacity, strokeAlpha: paint.strokeOpacity,
      });
      posX = null;
      posY = null;
      dx = 0;
      dy = 0;
    };
    // An element whose only content is text keeps it as its own text, with no child node.
    if (node.kids.length === 0 && node.ownText !== "") take(node.ownText);
    for (const kid of node.kids) {
      if (!kid.isElementNode) {
        take(kid.ownText ?? "");
        continue;
      }
      const kidEl = kid as Element;
      if (kidEl.sv[P.P_DISPLAY] === P.D_NONE) continue;
      const name = svgName(kidEl);
      // A <title> or <desc> inside text doesn't draw; a nested <text> lays out like a tspan.
      if (name === "tspan" || name === "a" || name === "text") {
        collect(kidEl, style === null ? null : childStyle(kidEl, style));
      }
    }
  };
  collect(el, inh);
  return pieces;
}

/**
 * Draws a <text>: its runs along the baseline, each in its own font and paint, inside the clips
 * the element is under and with its transform. The font size is in user units, so the transform
 * scales the glyphs along with everything else.
 */
function drawText(node: Element, id: number, m: number[], vw: number, vh: number, alpha: number,
  inh: UseStyle | null, clips: Clip[]): void {
  const runs = layoutText(textPieces(node, vw, vh, inh), anchorOf(attrOrStyle(node, "text-anchor")),
    (text, size, font) => hostMeasureText(text, size, font, 0, 0));
  if (runs.length === 0) return;
  if (clips.length > 0) hostCanvasSave(id);
  for (const clip of clips) clipTo(id, clip);
  hostCanvasSetTransform(id, m[0], m[1], m[2], m[3], m[4], m[5]);
  for (const r of runs) {
    hostCanvasSetFont(id, r.size, r.font);
    if (r.fill >= 0 && r.fillAlpha > 0) {
      hostCanvasSetFillColor(id, withAlpha(r.fill, alpha * r.fillAlpha));
      hostCanvasFillText(r.text, id, r.x, r.y, 0);
    }
    if (r.stroke >= 0 && r.width > 0 && r.strokeAlpha > 0) {
      hostCanvasSetStrokeColor(id, withAlpha(r.stroke, alpha * r.strokeAlpha));
      hostCanvasSetLineWidth(id, r.width);
      hostCanvasSetLineCap(id, P.SLC_BUTT);
      hostCanvasSetLineJoin(id, P.SLJ_MITER);
      hostCanvasSetLineDash(id, "");
      hostCanvasStrokeText(r.text, id, r.x, r.y, 0);
    }
  }
  if (clips.length > 0) hostCanvasRestore(id);
}

function drawChildren(el: Node, id: number, m: number[], vw: number, vh: number, alpha: number,
  inh: UseStyle | null, depth: number, clips: Clip[]): void {
  for (const kid of el.kids) drawNode(kid, id, m, vw, vh, alpha, inh, depth, clips);
}

// ---------------------------------------------------------------------------
// Layers

// A filtered element is drawn into a bitmap of its own the size of the root SVG's bitmap, then
// composited over its parent. The bitmaps are kept between paints and reused by nesting depth,
// so an animating filter allocates nothing after its first frame.
let layerCanvases: number[] = [];
/** Each layer bitmap's size as of its last use, so only a resized root costs a resize. */
let layerSizes: number[] = [];
let layerDepth = 0;
/** The root bitmap's size in device pixels, set by paintSvg for the layers drawn into it. */
let svgPixelW = 0, svgPixelH = 0;

/** A bitmap's size as one key: the host clamps a canvas to 16384 pixels on a side. */
function layerSizeKey(): number {
  return svgPixelW * 16384 + svgPixelH;
}

function layerCanvas(at: number): number {
  let id = layerCanvases[at];
  if (id === undefined) {
    id = hostCanvasCreate(svgPixelW, svgPixelH);
    layerCanvases[at] = id;
    layerSizes[at] = layerSizeKey();
  } else if (layerSizes[at] !== layerSizeKey()) {
    hostCanvasResize(id, svgPixelW, svgPixelH);
    layerSizes[at] = layerSizeKey();
  }
  return id;
}

function acquireLayer(): number {
  const id = layerCanvas(layerDepth++);
  hostCanvasSetTransform(id, 1, 0, 0, 1, 0, 0);
  hostCanvasSetAlpha(id, 1);
  hostCanvasSetComposite(id, 0);
  hostCanvasClearRect(id, 0, 0, svgPixelW, svgPixelH);
  return id;
}

function releaseLayer(): void {
  if (layerDepth > 0) layerDepth--;
}

/**
 * Draws a layer over its paint target, in device pixels: the whole bitmap, or the rect a filter
 * wrote, with the opacity the element's group carries.
 */
function compositeLayer(id: number, layer: number, x: number, y: number, w: number, h: number,
  alpha: number, clips: Clip[] = []): void {
  if (!(w > 0) || !(h > 0) || !(alpha > 0)) return;
  hostCanvasSave(id);
  hostCanvasSetTransform(id, 1, 0, 0, 1, 0, 0);
  // A filter runs on the element before its clip takes effect (Filter Effects orders filter,
  // then clip-path), so the paint the filter read was unclipped and the clip is applied here,
  // to the filtered result.
  for (const clip of clips) clipTo(id, clip);
  hostCanvasSetAlpha(id, alpha);
  hostCanvasSetComposite(id, 0);
  // A 1:1 blit of bitmap pixels: nearest sampling keeps the layer exactly as it was drawn.
  hostCanvasDrawCanvas(id, layer, x, y, w, h, x, y, w, h, 0);
  hostCanvasRestore(id);
  // The host keeps global alpha and the blend mode beside its saved state, not in it: a Windows
  // or Linux canvas comes back with the composite's alpha still set. The painter always draws at
  // full alpha and source-over, so put both back.
  hostCanvasSetAlpha(id, 1);
  hostCanvasSetComposite(id, 0);
}

/**
 * Draws one element and its subtree. `inh` is the style of the <use> the element is referenced
 * through, which fills in the properties the element doesn't declare itself.
 *
 * An element naming a filter paints as a group: its own drawing goes into a layer, the filter
 * runs over the region in device pixels, and that layer is composited once.
 */
function drawNode(el: Node, id: number, m: number[], vw: number, vh: number, alpha: number,
  inh: UseStyle | null, depth: number, clips: Clip[]): void {
  if (!el.isElementNode) return;
  if (el.sv[P.P_DISPLAY] === P.D_NONE) return;
  const node = el as Element;
  const name = svgName(node);
  if (skips(name)) return;
  const a = alpha * el.sv[P.P_OPACITY];
  if (!(a > 0)) return;
  const m2 = mul(m, svgMatrix(node, vw, vh));
  const inner = withClips(node, m2, vw, vh, clips);
  const filter = filterTarget(node);
  if (filter === null) {
    drawElement(node, name, id, m2, vw, vh, a, inh, depth, inner);
    return;
  }
  // The filter reads the element unclipped, so the clip applies to its result (see below).
  const layer = acquireLayer();
  drawElement(node, name, layer, m2, vw, vh, 1, inh, depth, []);
  // The filtered result replaces the paint within the filter region and nowhere else.
  const row = compileSvgFilter(filter, node, filterBBox(node, name, vw, vh), m2, vw, vh,
    svgPixelW, svgPixelH, (ref) => (ids === null ? undefined : ids.get(ref)));
  if (row !== null) {
    hostCanvasSvgFilter(layer, row.def, row.linear ? 1 : 0, row.x, row.y, row.w, row.h);
    compositeLayer(id, layer, row.x, row.y, row.w, row.h, a, inner);
  }
  releaseLayer();
}

/** One element's own paint, with no layer of its own: the shapes, text, reference or children. */
function drawElement(node: Element, name: string, id: number, m2: number[], vw: number, vh: number,
  a: number, inh: UseStyle | null, depth: number, inner: Clip[]): void {
  if (name === "use") {
    drawUse(node, id, m2, vw, vh, a, inh, depth, inner);
    return;
  }
  if (name === "svg") {
    // A nested <svg> opens a viewport of its own: its own width and height (all that is left of
    // the parent's when they are auto), moved to its x and y, with its viewBox fitted inside. Its
    // children's percentages and view-box measure that viewport, not the outer one.
    const nx = lengthOf(node, "x", vw) ?? 0;
    const ny = lengthOf(node, "y", vh) ?? 0;
    const nw = lengthOf(node, "width", vw) ?? vw;
    const nh = lengthOf(node, "height", vh) ?? vh;
    if (!(nw > 0) || !(nh > 0)) return;
    const view = parseViewBox((attr) => node.getAttribute(attr));
    let mm = mul(m2, [1, 0, 0, 1, nx, ny]);
    let cvw = nw, cvh = nh;
    if (view !== null) {
      const [align, slice] = parseAspectRatio(node.getAttribute("preserveaspectratio"));
      mm = mul(mm, viewMatrix(view, nw, nh, align, slice));
      cvw = view[2];
      cvh = view[3];
    }
    drawChildren(node, id, mm, cvw, cvh, a, inh === null ? null : childStyle(node, inh), depth, inner);
    return;
  }
  if (name === "g" || name === "a") {
    drawChildren(node, id, m2, vw, vh, a, inh === null ? null : childStyle(node, inh), depth, inner);
    return;
  }
  if (name === "text") {
    drawText(node, id, m2, vw, vh, a, inh, inner);
    return;
  }
  const ops = shapePath(name, (attr) => node.getAttribute(attr), vw, vh);
  if (ops.length === 0) return;
  let fill: number, stroke: number, width: number, rule: number;
  let fillOpacity: number, strokeOpacity: number, cap: number, join: number;
  let dash: string;
  if (inh === null) {
    fill = paintOf(node, P.P_FILL);
    stroke = paintOf(node, P.P_STROKE);
    width = strokeWidth(node.sv[P.P_STROKE_WIDTH], node.su[P.P_STROKE_WIDTH], vw, vh);
    rule = node.sv[P.P_FILL_RULE] === P.FR_EVENODD ? 1 : 0;
    fillOpacity = node.sv[P.P_FILL_OPACITY];
    strokeOpacity = node.sv[P.P_STROKE_OPACITY];
    cap = node.sv[P.P_STROKE_LINECAP];
    join = node.sv[P.P_STROKE_LINEJOIN];
    dash = dashOf(node.sv[P.P_STROKE_DASHARRAY], node.su[P.P_STROKE_DASHARRAY],
      node.sv[P.P_STROKE_DASHOFFSET], node.su[P.P_STROKE_DASHOFFSET], vw, vh);
  } else {
    const color = styleOf(node, P.P_COLOR, inh);
    fill = resolveColor(styleOf(node, P.P_FILL, inh), color);
    stroke = resolveColor(styleOf(node, P.P_STROKE, inh), color);
    const unit = declares(node, P.P_STROKE_WIDTH) ? node.su[P.P_STROKE_WIDTH] : inh.strokeWidthUnit;
    width = strokeWidth(styleOf(node, P.P_STROKE_WIDTH, inh), unit, vw, vh);
    rule = styleOf(node, P.P_FILL_RULE, inh) === P.FR_EVENODD ? 1 : 0;
    fillOpacity = styleOf(node, P.P_FILL_OPACITY, inh);
    strokeOpacity = styleOf(node, P.P_STROKE_OPACITY, inh);
    cap = styleOf(node, P.P_STROKE_LINECAP, inh);
    join = styleOf(node, P.P_STROKE_LINEJOIN, inh);
    const dashUnit = declares(node, P.P_STROKE_DASHARRAY) ? node.su[P.P_STROKE_DASHARRAY] : inh.dashUnit;
    const offsetUnit = declares(node, P.P_STROKE_DASHOFFSET) ? node.su[P.P_STROKE_DASHOFFSET] : inh.dashOffsetUnit;
    dash = dashOf(styleOf(node, P.P_STROKE_DASHARRAY, inh), dashUnit,
      styleOf(node, P.P_STROKE_DASHOFFSET, inh), offsetUnit, vw, vh);
  }
  const hasFill = fill >= 0 || isPaintUrl(fill);
  const hasStroke = (stroke >= 0 || isPaintUrl(stroke)) && width > 0;
  if (!hasFill && !hasStroke) return;
  // A clip path is a device-space clip, so it is set inside a saved state and dropped again
  // once this shape is drawn.
  if (inner.length > 0) hostCanvasSave(id);
  for (const clip of inner) clipTo(id, clip);
  hostCanvasSetTransform(id, m2[0], m2[1], m2[2], m2[3], m2[4], m2[5]);
  hostCanvasBeginPath(id);
  sinkId = id;
  emitPath(ops, sink);
  if (hasFill) {
    if (isPaintUrl(fill)) {
      // A paint server that can't be found paints nothing, as a missing gradient does.
      const url = paintUrlAt(paintUrlIndex(fill));
      const target = url === null || ids === null ? undefined : ids.get(url);
      if (target !== undefined && paintLookup.kind(url as string) === 2) {
        const pat = patternFor(target, vw, vh);
        if (pat !== null) drawPatternFill(id, pat, bboxOf(ops), m2, a * fillOpacity, rule, vw, vh, depth);
      } else {
        const g = resolveGradient(fill, paintLookup, vw, vh);
        if (g !== null) drawGradient(id, g, bboxOf(ops), m2, a * fillOpacity, false, rule);
      }
    } else {
      hostCanvasSetFillColor(id, withAlpha(fill, a * fillOpacity));
      hostCanvasFill(id, rule);
    }
  }
  if (hasStroke) {
    if (isPaintUrl(stroke)) {
      const g = resolveGradient(stroke, paintLookup, vw, vh);
      if (g !== null && drawGradient(id, g, bboxOf(ops), m2, a * strokeOpacity, true, rule)) {
        hostCanvasSetLineWidth(id, width);
        hostCanvasSetLineCap(id, cap);
        hostCanvasSetLineJoin(id, join);
        hostCanvasSetLineDash(id, dash);
        hostCanvasStroke(id);
      }
    } else {
      hostCanvasSetStrokeColor(id, withAlpha(stroke, a * strokeOpacity));
      hostCanvasSetLineWidth(id, width);
      hostCanvasSetLineCap(id, cap);
      hostCanvasSetLineJoin(id, join);
      hostCanvasSetLineDash(id, dash);
      hostCanvasStroke(id);
    }
  }
  if (inner.length > 0) hostCanvasRestore(id);
}

/**
 * Draws a <use>: the element it references, moved by x and y. A referenced <symbol> (or <svg>) is
 * a viewport of the use element's width and height with the target's own viewBox over it, which
 * is how an icon sprite's symbols are sized.
 */
function drawUse(node: Element, id: number, m: number[], vw: number, vh: number, alpha: number,
  inh: UseStyle | null, depth: number, clips: Clip[]): void {
  const href = useHref(node);
  if (href === "" || ids === null || depth >= MAX_USE_DEPTH) return;
  const target = ids.get(href);
  if (target === undefined || target === node) return;
  const x = lengthOf(node, "x", vw) ?? 0;
  const y = lengthOf(node, "y", vh) ?? 0;
  const mu = mul(m, [1, 0, 0, 1, x, y]);
  const base = inh === null ? useStyleOf(node) : childStyle(node, inh);
  const name = svgName(target);
  if (name === "symbol" || name === "svg") {
    const w = lengthOf(node, "width", vw) ?? lengthOf(target, "width", vw) ?? vw;
    const h = lengthOf(node, "height", vh) ?? lengthOf(target, "height", vh) ?? vh;
    if (!(w > 0) || !(h > 0)) return;
    const view = parseViewBox((attr) => target.getAttribute(attr));
    const [align, slice] = parseAspectRatio(target.getAttribute("preserveaspectratio"));
    const mm = view !== null ? mul(mu, viewMatrix(view, w, h, align, slice)) : mu;
    const ivw = view !== null ? view[2] : w;
    const ivh = view !== null ? view[3] : h;
    drawChildren(target, id, mm, ivw, ivh, alpha, childStyle(target, base), depth + 1, clips);
    return;
  }
  drawNode(target, id, mu, vw, vh, alpha, base, depth + 1, clips);
}

/**
 * Draws an inline <svg> into the paint list, as the replaced content of its box (x, y, w, h in
 * the page's CSS px). The picture is rasterized again on every paint: a paint pass only runs when
 * something changed, and the bitmap is sized to the box so a resize redraws at the new size.
 */
export function paintSvg(el: Element, x: number, y: number, w: number, h: number, alpha: number): void {
  if (!(w > 0) || !(h > 0)) return;
  const scale = rasterScale();
  const pw = Math.max(1, Math.ceil(w * scale));
  const ph = Math.max(1, Math.ceil(h * scale));
  if (el.svgCanvas < 0) {
    el.svgCanvas = hostCanvasCreate(pw, ph);
  } else if (pw !== el.svgPixelsW || ph !== el.svgPixelsH) {
    hostCanvasResize(el.svgCanvas, pw, ph);
  }
  el.svgPixelsW = pw;
  el.svgPixelsH = ph;
  const id = el.svgCanvas;
  // A paint pass draws one SVG at a time, and its group layers nest within it.
  svgPixelW = pw;
  svgPixelH = ph;
  layerDepth = 0;
  // The clear is in canvas space, so the identity transform restores it after the last pass's
  // per-shape transforms.
  hostCanvasSetTransform(id, 1, 0, 0, 1, 0, 0);
  hostCanvasClearRect(id, 0, 0, pw, ph);
  // The viewBox maps user units into the box's CSS px; the device scale then makes them pixels.
  const view = svgViewBox(el);
  let m: number[] = [scale, 0, 0, scale, 0, 0];
  if (view !== null) {
    const [align, slice] = parseAspectRatio(el.getAttribute("preserveaspectratio"));
    m = mul(m, viewMatrix(view, w, h, align, slice));
  }
  const vw = view !== null ? view[2] : w;
  const vh = view !== null ? view[3] : h;
  ids = new Map();
  collectIds(el);
  drawChildren(el, id, m, vw, vh, 1, null, 0, []);
  ids = null;
  hostCanvasDraw(id, x, y, w, h, alpha, 1);
}
