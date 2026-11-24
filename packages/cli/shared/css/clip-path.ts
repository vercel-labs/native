// CSS Shapes' basic shapes, as `clip-path` takes them. A value is a row in the clip-path table,
// stored with unit U_LIST. Every row starts with the shape's kind and the reference box it is
// resolved against; lengths follow as [value, unit] pairs, so the runtime can resolve them
// against the element and its box.
//
//   inset:   [SH_INSET, box, 0, top, right, bottom, left, radii…]   (radii: 8 pairs, square first)
//   circle:  [SH_CIRCLE, box, 0, radius, position row id]
//   ellipse: [SH_ELLIPSE, box, 0, rx, ry, position row id]
//   polygon: [SH_POLYGON, box, fill rule, x0, y0, x1, y1, …]
//   path:    [SH_PATH, box, fill rule, …path operations]   (the operations of shared/svg.ts)
//
// A circle's radius, and either of an ellipse's, may be a length or percentage, or the
// closest-side and farthest-side keywords (stored in the unit, with a zero value).

import * as P from "../props.ts";
import { pathData } from "../svg.ts";
import { parseLength } from "./declarations.ts";
import type { Len } from "./declarations.ts";
import { splitValue } from "./fonts.ts";
import { parsePosition, positionRows, positionText } from "./position.ts";
import { RowTable } from "./rows.ts";
import type { Decl, FontContext } from "./types.ts";

export const clipPathRows: RowTable = new RowTable();

export const SH_INSET = 0;
export const SH_CIRCLE = 1;
export const SH_ELLIPSE = 2;
export const SH_POLYGON = 3;
export const SH_PATH = 4;
/**
 * `url(#id)` names a `<clipPath>` in the document. The row holds the reference box and an index
 * into the paint URL table (SVG_PAINT_URLS), where the runtime finds the id to look up.
 */
export const SH_REF = 5;

/** The boxes a shape can be resolved against; the border box is the one CSS defaults to. */
export const REF_BORDER_BOX = 0;
export const REF_PADDING_BOX = 1;
export const REF_CONTENT_BOX = 2;
/** shape-outside's own default: a float's shape is taken against its margin box. */
export const REF_MARGIN_BOX = 3;
/** clip-path's SVG boxes: the viewport, the object's bounds, and those grown by its stroke. */
export const REF_VIEW_BOX = 4;
export const REF_FILL_BOX = 5;
export const REF_STROKE_BOX = 6;

function boxKind(text: string, allowMargin: boolean, svgBoxes: boolean): number {
  switch (text) {
    case "border-box": return REF_BORDER_BOX;
    case "padding-box": return REF_PADDING_BOX;
    case "content-box": return REF_CONTENT_BOX;
    case "margin-box": return allowMargin ? REF_MARGIN_BOX : -1;
    case "view-box": return svgBoxes ? REF_VIEW_BOX : -1;
    case "fill-box": return svgBoxes ? REF_FILL_BOX : -1;
    case "stroke-box": return svgBoxes ? REF_STROKE_BOX : -1;
    default: return -1;
  }
}

/** Splits on top-level commas, so `polygon(0 0, 10px 0)` parts stay whole. */
function commaParts(s: string): string[] {
  const out: string[] = [];
  let depth = 0, cur = "";
  for (const ch of s) {
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (ch === "," && depth === 0) {
      out.push(cur);
      cur = "";
    } else cur += ch;
  }
  out.push(cur);
  return out;
}

/** One to four values in CSS's shorthand order: the first is the top, then right, bottom, left. */
function fourSides(ls: Len[]): Len[] | null {
  if (ls.length < 1 || ls.length > 4) return null;
  const t = ls[0];
  const r = ls.length > 1 ? ls[1] : t;
  const b = ls.length > 2 ? ls[2] : t;
  const l = ls.length > 3 ? ls[3] : r;
  return [t, r, b, l];
}

function pair(l: Len): number[] {
  return [l.v, l.u];
}

const CENTER: number[] = [50, P.U_PCT, 0, 50, P.U_PCT, 0];

/** A shape radius: a length, a percentage, or the closest-side and farthest-side keywords. */
function shapeRadius(token: string): Len | null | string {
  const t = token.toLowerCase();
  if (t === "closest-side") return { v: 0, u: P.U_CLOSEST_SIDE };
  if (t === "farthest-side") return { v: 0, u: P.U_FARTHEST_SIDE };
  const l = parseLength(t, false);
  if (l === null) return null;
  if (l.v < 0) return "negative";
  return l;
}

/** `inset(top right bottom left [round <border-radius>])`, without the function name. */
function insetShape(args: string, box: number, prop: string, value: string): number[] | string {
  const toks = splitValue(args);
  let ri = -1;
  for (let i = 0; i < toks.length; i++) if (toks[i].toLowerCase() === "round") ri = i;
  const sideToks = ri < 0 ? toks : toks.slice(0, ri);
  const sides: Len[] = [];
  for (const t of sideToks) {
    const l = parseLength(t, false);
    if (l === null) return `unsupported length '${t}' in '${prop}: ${value}'`;
    sides.push(l);
  }
  const four = fourSides(sides);
  if (four === null) return `unsupported '${value}' for '${prop}': inset() takes one to four lengths`;
  // `round <radius>`: one to four radii, square, or an ellipse when a "/" splits them.
  const flat: Len[] = [0, 1, 2, 3].map(() => ({ v: 0, u: P.U_PX }));
  if (ri >= 0) {
    // A "/" may stand on its own, or split a token into the two halves: `round 5px/10px`.
    const radiusToks: string[] = [];
    for (const t of toks.slice(ri + 1)) {
      const pieces = t.split("/");
      for (let i = 0; i < pieces.length; i++) {
        if (i > 0) radiusToks.push("/");
        if (pieces[i] !== "") radiusToks.push(pieces[i]);
      }
    }
    const halves: Len[][] = [[], []];
    let which = 0;
    for (const t of radiusToks) {
      if (t === "/") {
        which = 1;
        continue;
      }
      const l = parseLength(t, false);
      if (l === null || l.v < 0) return `unsupported corner radius '${t}' in '${prop}: ${value}'`;
      halves[which].push(l);
    }
    const h = fourSides(halves[0]);
    if (h === null) return `unsupported '${value}' for '${prop}': the corner radius takes one to four values`;
    const v = halves[1].length === 0 ? h : fourSides(halves[1]);
    if (v === null) return `unsupported '${value}' for '${prop}': the corner radius takes one to four values`;
    for (let k = 0; k < 4; k++) {
      flat[k * 2] = h[k];
      flat[k * 2 + 1] = v[k];
    }
  }
  const row: number[] = [SH_INSET, box, 0];
  for (const l of four) row.push(l.v, l.u);
  for (const l of flat) row.push(l.v, l.u);
  return row;
}

/** The arguments of circle() or ellipse(), split around the `at <position>` part. */
function radiiAndPosition(args: string, prop: string, value: string): { radii: string[]; pos: number[] } | string {
  const toks = splitValue(args);
  let ai = -1;
  for (let i = 0; i < toks.length; i++) if (toks[i].toLowerCase() === "at") ai = i;
  const radii = ai < 0 ? toks : toks.slice(0, ai);
  const posToks = ai < 0 ? [] : toks.slice(ai + 1);
  if (ai >= 0 && posToks.length === 0) return `unsupported '${value}' for '${prop}': circle() and ellipse() need a position after 'at'`;
  if (posToks.length === 0) return { radii, pos: CENTER };
  const pos = parsePosition(posToks.join(" "), prop);
  if (typeof pos === "string") return pos;
  return { radii, pos };
}

function circleShape(args: string, box: number, prop: string, value: string): number[] | string {
  const split = radiiAndPosition(args, prop, value);
  if (typeof split === "string") return split;
  if (split.radii.length > 1) return `unsupported '${value}' for '${prop}': circle() takes one radius`;
  let radius: Len = { v: 0, u: P.U_CLOSEST_SIDE };
  if (split.radii.length === 1) {
    const r = shapeRadius(split.radii[0]);
    if (r === null) return `unsupported radius '${split.radii[0]}' in '${prop}: ${value}'`;
    if (typeof r === "string") return `invalid '${value}' for '${prop}': the radius can't be negative`;
    radius = r;
  }
  return [SH_CIRCLE, box, 0, radius.v, radius.u, positionRows.register(split.pos)];
}

function ellipseShape(args: string, box: number, prop: string, value: string): number[] | string {
  const split = radiiAndPosition(args, prop, value);
  if (typeof split === "string") return split;
  if (split.radii.length > 2) return `unsupported '${value}' for '${prop}': ellipse() takes two radii`;
  const rs: Len[] = [];
  for (const t of split.radii) {
    const r = shapeRadius(t);
    if (r === null) return `unsupported radius '${t}' in '${prop}: ${value}'`;
    if (typeof r === "string") return `invalid '${value}' for '${prop}': the radii can't be negative`;
    rs.push(r);
  }
  const rx = rs.length > 0 ? rs[0] : { v: 0, u: P.U_CLOSEST_SIDE };
  const ry = rs.length > 1 ? rs[1] : rx;
  return [SH_ELLIPSE, box, 0, rx.v, rx.u, ry.v, ry.u, positionRows.register(split.pos)];
}

function polygonShape(args: string, box: number, prop: string, value: string): number[] | string {
  const parts = commaParts(args);
  let rule = P.FR_NONZERO;
  let start = 0;
  const head = parts[0].trim().toLowerCase();
  if (head === "nonzero" || head === "evenodd") {
    rule = head === "evenodd" ? P.FR_EVENODD : P.FR_NONZERO;
    start = 1;
  }
  const row: number[] = [SH_POLYGON, box, rule];
  let points = 0;
  for (let i = start; i < parts.length; i++) {
    const toks = splitValue(parts[i].trim());
    if (toks.length !== 2) return `unsupported '${value}' for '${prop}': each polygon point takes an x and a y`;
    for (const t of toks) {
      const l = parseLength(t, false);
      if (l === null) return `unsupported length '${t}' in '${prop}: ${value}'`;
      row.push(l.v, l.u);
    }
    points++;
  }
  if (points < 3) return `unsupported '${value}' for '${prop}': polygon() needs at least three points`;
  return row;
}

function pathShape(args: string, box: number, prop: string, value: string): number[] | string {
  const m = /^\s*(?:([A-Za-z]+)\s*,\s*)?(["'])([\s\S]*)\2\s*$/.exec(args);
  if (m === null) return `unsupported '${value}' for '${prop}': path() takes a quoted path`;
  let rule = P.FR_NONZERO;
  if (m[1] !== undefined) {
    const name = m[1].toLowerCase();
    if (name === "evenodd") rule = P.FR_EVENODD;
    else if (name !== "nonzero") return `unsupported fill rule '${m[1]}' in '${prop}: ${value}'`;
  }
  const row: number[] = [SH_PATH, box, rule];
  for (const n of pathData(m[3])) row.push(n);
  return row;
}

/** Compiles `clip-path` into one declaration holding the shape's row id. */
export function clipPath(prop: string, value: string, out: Decl[], fonts?: FontContext,
  target: number = P.P_CLIP_PATH, allowMargin: boolean = false, svgBoxes: boolean = false): string | null {
  const text = value.trim();
  if (text.toLowerCase() === "none") {
    out.push({ p: target, v: -1, u: P.U_NONE });
    return null;
  }
  const toks = splitValue(text);
  let shape: string | null = null;
  // A shape without a box of its own is taken against the border box, save a float's, which
  // uses its margin box.
  let box = allowMargin ? REF_MARGIN_BOX : REF_BORDER_BOX;
  for (const t of toks) {
    if (shape === null && /^[A-Za-z-]+\([\s\S]*\)$/.test(t)) {
      shape = t;
      continue;
    }
    const k = boxKind(t.toLowerCase(), allowMargin, svgBoxes);
    if (k >= 0) {
      box = k;
      continue;
    }
    return `unsupported '${value}' for '${prop}' (use a basic shape: inset(), circle(), ellipse(), polygon() or path())`;
  }
  let row: number[] | string;
  if (shape === null) {
    // A bare geometry box clips to that box: inset(0) leaves the box itself.
    const sides: Len[] = [0, 0, 0, 0].map(() => ({ v: 0, u: P.U_PX }));
    const flat: Len[] = [0, 0, 0, 0, 0, 0, 0, 0].map(() => ({ v: 0, u: P.U_PX }));
    row = [SH_INSET, box, 0];
    for (const l of sides) row.push(l.v, l.u);
    for (const l of flat) row.push(l.v, l.u);
  } else {
    const m = /^([A-Za-z-]+)\(([\s\S]*)\)$/.exec(shape);
    const name = m === null ? "" : m[1].toLowerCase();
    const args = m === null ? "" : m[2];
    switch (name) {
      case "inset":
        row = insetShape(args, box, prop, value);
        break;
      case "circle":
        row = circleShape(args, box, prop, value);
        break;
      case "ellipse":
        row = ellipseShape(args, box, prop, value);
        break;
      case "polygon":
        row = polygonShape(args, box, prop, value);
        break;
      case "path":
        row = pathShape(args, box, prop, value);
        break;
      case "url": {
        const ref = /^\s*(['"]?)([^'"]*)\1\s*$/.exec(args);
        const id = ref === null ? "" : ref[2].trim();
        if (!id.startsWith("#") || id.length < 2) {
          return `unsupported '${value}' for '${prop}' (url() must name a #id in the document)`;
        }
        row = [SH_REF, box, 0, fonts === undefined ? -1 : fonts.paint(id.slice(1))];
        break;
      }
      default:
        return `unsupported shape '${shape}' for '${prop}' (use inset(), circle(), ellipse(), polygon() or path())`;
    }
  }
  if (typeof row === "string") return row;
  out.push({ p: target, v: clipPathRows.register(row), u: P.U_LIST });
  return null;
}

// ---------------------------------------------------------------------------
// Serialization

function numText(n: number): string {
  return String(Math.round(n * 1000) / 1000);
}

/** One length as CSS text, for a computed value; the keywords it can hold are named. */
export function shapeLenText(v: number, u: number): string {
  switch (u) {
    case P.U_PCT: return `${numText(v)}%`;
    case P.U_EM: return `${numText(v)}em`;
    case P.U_VW: return `${numText(v)}vw`;
    case P.U_VH: return `${numText(v)}vh`;
    case P.U_CLOSEST_SIDE: return "closest-side";
    case P.U_FARTHEST_SIDE: return "farthest-side";
    case P.U_AUTO: return "auto";
    case P.U_NONE: return "none";
    default: return `${numText(v)}px`;
  }
}

/** A path's operations as a `d` string, for serializing the computed value of `clip-path`. */
export function pathText(ops: readonly number[]): string {
  const out: string[] = [];
  for (let i = 0; i < ops.length;) {
    const kind = ops[i];
    if (kind === 1) {
      out.push(`M${numText(ops[i + 1])} ${numText(ops[i + 2])}`);
      i += 3;
    } else if (kind === 2) {
      out.push(`L${numText(ops[i + 1])} ${numText(ops[i + 2])}`);
      i += 3;
    } else if (kind === 3) {
      out.push(`Q${numText(ops[i + 1])} ${numText(ops[i + 2])} ${numText(ops[i + 3])} ${numText(ops[i + 4])}`);
      i += 5;
    } else if (kind === 4) {
      out.push(`C${numText(ops[i + 1])} ${numText(ops[i + 2])} ${numText(ops[i + 3])} ${numText(ops[i + 4])} ${numText(ops[i + 5])} ${numText(ops[i + 6])}`);
      i += 7;
    } else {
      out.push("Z");
      i += 1;
    }
  }
  return out.join(" ");
}

function boxText(box: number): string {
  return box === REF_PADDING_BOX ? "padding-box" : box === REF_CONTENT_BOX ? "content-box"
    : box === REF_MARGIN_BOX ? "margin-box" : box === REF_VIEW_BOX ? "view-box"
    : box === REF_FILL_BOX ? "fill-box" : box === REF_STROKE_BOX ? "stroke-box" : "";
}

/** The computed value of `clip-path` for a row id, or `none`. */
export function clipPathText(id: number): string {
  const row = clipPathRows.row(id);
  if (row === null || row.length < 3) return "none";
  const box = boxText(row[1]);
  const suffix = box === "" ? "" : ` ${box}`;
  const rule = row[2] === P.FR_EVENODD ? "evenodd, " : "";
  const pairAt = (i: number): string => shapeLenText(row[i], row[i + 1]);
  switch (row[0]) {
    case SH_INSET: {
      const sides: string[] = [];
      for (let k = 3; k < 11; k += 2) sides.push(pairAt(k));
      let text = `inset(${sides.join(" ")})`;
      const radii: string[] = [];
      for (let k = 11; k + 1 < row.length; k += 2) radii.push(pairAt(k));
      if (radii.some((r) => r !== "0px")) text = `inset(${sides.join(" ")} round ${radii.join(" ")})`;
      return text + suffix;
    }
    case SH_CIRCLE:
      return `circle(${pairAt(3)} at ${positionText(row[5])})${suffix}`;
    case SH_ELLIPSE:
      return `ellipse(${pairAt(3)} ${pairAt(5)} at ${positionText(row[7])})${suffix}`;
    case SH_POLYGON: {
      const points: string[] = [];
      for (let k = 3; k + 3 < row.length; k += 4) points.push(`${pairAt(k)} ${pairAt(k + 2)}`);
      return `polygon(${rule}${points.join(", ")})${suffix}`;
    }
    case SH_PATH: {
      const ops: number[] = [];
      for (let k = 3; k < row.length; k++) ops.push(row[k]);
      return `path(${rule}"${pathText(ops)}")${suffix}`;
    }
    default: return "none";
  }
}
