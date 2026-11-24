// CSS container queries: an `@container` condition, tested against the element's ancestors. The
// query container is the nearest ancestor that has a `container-type` for the feature's axes (for
// a style query, any ancestor), and a `container-name` the query names if it names one. A condition that finds no such ancestor is unknown rather than false: `not` and `and`
// can't settle it, so the rule doesn't apply.

import { noteQueriedContainer } from "./invalidation.ts";
import * as P from "../shared/props.ts";
import { parseLength } from "../shared/css/declarations.ts";
import { parseColor } from "../shared/css/colors.ts";
import type { Node } from "./dom.ts";
import { rootFontSize } from "./root-size.ts";
import { registeredProperty } from "./registered.ts";

// Three-valued results, so a missing container doesn't turn `not (...)` into a match.
const FALSE = 0;
const TRUE = 1;
const UNKNOWN = 2;

// The comparison operators a feature can use, and how one test is named once parsed.
const OPS_LT = 0;
const OPS_LE = 1;
const OPS_GT = 2;
const OPS_GE = 3;
const OPS_EQ = 4;
const OPS_NE = 5;

const AXIS_INLINE = 1;
const AXIS_BLOCK = 2;
const AXIS_BOTH = 3;

/** True when the rule's `@container` condition holds for `el`'s ancestor containers. */
export function containerMatches(el: Node, query: string, names: string[]): boolean {
  const text = query.trim();
  if (text === "") return true;
  // `[ <container-name> ]? <condition>`: the name is the word before the condition, and a
  // condition starts with a "(" or with a function the build knows (`style(`).
  let name = "";
  let cond = text;
  if (text[0] !== "(") {
    let j = 0;
    while (j < text.length && !/[\s(]/.test(text[j])) j++;
    const space = j < text.length && /[\s]/.test(text[j]);
    const sameWord = !space && text.slice(0, j).toLowerCase() === "style";
    if (space) {
      name = text.slice(0, j);
      cond = text.slice(j).trim();
    } else if (!sameWord && j > 0) {
      // A name running straight into its condition, as `sidebar(width > 20px)` writes it.
      name = text.slice(0, j);
      cond = text.slice(j);
    }
  }
  if (cond === "") return false;
  return evaluate(cond, el, names, name) === TRUE;
}

/** The condition, evaluated top down: a comma list is an `or`, then `and`, then `not`. */
function evaluate(text: string, el: Node, names: string[], name: string): number {
  const s = stripParens(text.trim());
  if (s === "") return UNKNOWN;
  const commas = splitCommas(s);
  if (commas !== null) return combine(commas, el, names, name, true);
  const ors = splitKeyword(s, "or");
  if (ors !== null) return combine(ors, el, names, name, true);
  const ands = splitKeyword(s, "and");
  if (ands !== null) return combine(ands, el, names, name, false);
  if (s.toLowerCase().startsWith("not ")) {
    const r = evaluate(s.slice(4), el, names, name);
    return r === TRUE ? FALSE : r === FALSE ? TRUE : UNKNOWN;
  }
  return feature(s, el, names, name);
}

/** Drops one pair of parentheses, but only when the pair covers the whole text. */
function stripParens(s: string): string {
  if (s.length < 2 || s[0] !== "(" || s[s.length - 1] !== ")") return s;
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "(") depth++;
    else if (s[i] === ")") {
      depth--;
      if (depth === 0) return i === s.length - 1 ? s.slice(1, s.length - 1).trim() : s;
    }
  }
  return s;
}

/** Splits a condition list on its top-level commas, or null when it has none. A comma inside a
 *  function (`style(--x: a, b)`) belongs to that function, not the list. */
function splitCommas(s: string): string[] | null {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (ch === "," && depth === 0) {
      parts.push(s.slice(start, i));
      start = i + 1;
    }
  }
  if (parts.length === 0) return null;
  parts.push(s.slice(start));
  return parts;
}

/** Splits on a keyword at the top level of the condition, or null when it isn't there. The
 *  keyword has to stand alone as a word, so `not(...)` is a function call and not a `not`. */
function splitKeyword(s: string, word: string): string[] | null {
  const low = s.toLowerCase();
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    if (depth !== 0 || !low.startsWith(word, i)) continue;
    const before = i === 0 ? " " : s[i - 1];
    const after = i + word.length >= s.length ? " " : s[i + word.length];
    if (!/[\s(]/.test(before) || !/[\s(]/.test(after)) continue;
    parts.push(s.slice(start, i));
    start = i + word.length;
    i += word.length - 1;
  }
  if (parts.length === 0) return null;
  parts.push(s.slice(start));
  return parts;
}

function combine(parts: string[], el: Node, names: string[], name: string, or: boolean): number {
  let unknown = false;
  for (const part of parts) {
    const r = evaluate(part, el, names, name);
    if (or) {
      if (r === TRUE) return TRUE;
    } else if (r === FALSE) return FALSE;
    if (r === UNKNOWN) unknown = true;
  }
  if (unknown) return UNKNOWN;
  return or ? FALSE : TRUE;
}

/** The feature a word names, without its min-/max- prefix, or "" when it names none. */
function featureName(word: string): string {
  const w = word.toLowerCase();
  const bare = w.startsWith("min-") ? w.slice(4) : w.startsWith("max-") ? w.slice(4) : w;
  if (bare === "width" || bare === "height" || bare === "inline-size" || bare === "block-size" ||
    bare === "aspect-ratio" || bare === "orientation") return bare;
  return "";
}

function featureAxis(word: string): number {
  if (word === "width" || word === "inline-size") return AXIS_INLINE;
  if (word === "height" || word === "block-size") return AXIS_BLOCK;
  return AXIS_BOTH;
}

/** Flips a comparison so the feature stays on the left: `400px < width` is `width > 400px`. */
function flip(op: string): string {
  if (op === "<") return ">";
  if (op === ">") return "<";
  if (op === "<=") return ">=";
  if (op === ">=") return "<=";
  return op;
}

function opIndex(op: string): number {
  if (op === "<") return OPS_LT;
  if (op === "<=") return OPS_LE;
  if (op === ">") return OPS_GT;
  if (op === ">=") return OPS_GE;
  return OPS_EQ;
}

function opText(op: number): string {
  if (op === OPS_LT) return "<";
  if (op === OPS_LE) return "<=";
  if (op === OPS_GT) return ">";
  if (op === OPS_GE) return ">=";
  if (op === OPS_NE) return "!=";
  return "=";
}

function compare(current: number, op: string, value: number): boolean {
  if (op === "<") return current < value;
  if (op === ">") return current > value;
  if (op === "<=") return current <= value;
  if (op === ">=") return current >= value;
  // `=` compares the sizes layout rounded to, which are CSS px in fractions of 1/64.
  return Math.abs(current - value) <= 1 / 64;
}

const OPS = ["<=", ">=", "<", ">", "="];

/** Splits `a < b <= c` into its terms and operators; null when there is no operator at all. */
function comparisons(s: string): { terms: string[]; ops: string[] } | null {
  const terms: string[] = [];
  const ops: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    if (depth !== 0) continue;
    let found = "";
    for (const op of OPS) if (s.startsWith(op, i)) { found = op; break; }
    if (found === "") continue;
    terms.push(s.slice(start, i).trim());
    ops.push(found);
    i += found.length - 1;
    start = i + 1;
  }
  if (ops.length === 0) return null;
  terms.push(s.slice(start).trim());
  return { terms, ops };
}

/** The index of the top-level `:` of a `name: value` feature, or -1. */
function colonAt(s: string): number {
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (ch === ":" && depth === 0) return i;
  }
  return -1;
}

/** One feature of a condition, like `(width > 400px)` or `style(--theme: dark)`. */
function feature(s: string, el: Node, names: string[], name: string): number {
  const low = s.toLowerCase();
  if (low.startsWith("style(") && s[s.length - 1] === ")") return styleFeature(s.slice(6, s.length - 1), el, names, name);
  // The comparisons the feature makes, with the feature itself on the left of each.
  const wanted: number[] = [];
  const values: string[] = [];
  let word = "";
  const cmp = comparisons(s);
  if (cmp !== null && cmp.terms.length === 2) {
    const left = featureName(cmp.terms[0]);
    const right = featureName(cmp.terms[1]);
    if (left !== "") {
      word = left;
      wanted.push(opIndex(cmp.ops[0]));
      values.push(cmp.terms[1]);
    } else if (right !== "") {
      word = right;
      wanted.push(opIndex(flip(cmp.ops[0])));
      values.push(cmp.terms[0]);
    } else return UNKNOWN;
  } else if (cmp !== null && cmp.terms.length === 3) {
    // A range: `400px < width < 800px`.
    word = featureName(cmp.terms[1]);
    if (word === "" || featureName(cmp.terms[0]) !== "" || featureName(cmp.terms[2]) !== "") return UNKNOWN;
    wanted.push(opIndex(flip(cmp.ops[0])), opIndex(cmp.ops[1]));
    values.push(cmp.terms[0], cmp.terms[2]);
  } else {
    const colon = colonAt(s);
    if (colon < 0) return UNKNOWN;
    const raw = s.slice(0, colon).trim().toLowerCase();
    word = featureName(raw);
    if (word === "") return UNKNOWN;
    // `min-width: x` is `width >= x`, and `max-width: x` is `width <= x`.
    wanted.push(raw.startsWith("min-") ? OPS_GE : raw.startsWith("max-") ? OPS_LE : OPS_EQ);
    values.push(s.slice(colon + 1).trim());
  }
  const axis = featureAxis(word);
  const container = findContainer(el, names, name, (axis & AXIS_INLINE) !== 0, (axis & AXIS_BLOCK) !== 0, false);
  if (container === null) return UNKNOWN;
  const w = container.contentW;
  const h = container.contentH;
  if (axis !== AXIS_BLOCK) container.qUsedW = w;
  if (axis !== AXIS_INLINE) container.qUsedH = h;
  noteQueriedContainer(container);
  for (let k = 0; k < values.length; k++) {
    let ok = false;
    if (word === "orientation") {
      // The block axis runs down the page, so a taller container is the portrait one.
      const current = h > w ? "portrait" : "landscape";
      const want = values[k].trim().toLowerCase();
      ok = wanted[k] === OPS_EQ ? want === current : wanted[k] === OPS_NE ? want !== current : false;
    } else if (word === "aspect-ratio") {
      // A container with no block size has no ratio to compare against.
      if (!(h > 0)) return UNKNOWN;
      const v = ratioValue(values[k]);
      if (Number.isNaN(v)) return UNKNOWN;
      ok = compare(w / h, opText(wanted[k]), v);
    } else {
      const current = word === "height" || word === "block-size" ? h : w;
      const v = lengthPx(values[k], container, w, h);
      if (Number.isNaN(v)) return UNKNOWN;
      ok = compare(current, opText(wanted[k]), v);
    }
    if (!ok) return FALSE;
  }
  return TRUE;
}

/** A `<number> [ / <number> ]` aspect ratio. */
function ratioValue(text: string): number {
  const slash = text.indexOf("/");
  if (slash < 0) {
    const n = parseFloat(text.trim());
    return Number.isFinite(n) && n > 0 ? n : NaN;
  }
  const a = parseFloat(text.slice(0, slash));
  const b = parseFloat(text.slice(slash + 1));
  return Number.isFinite(a) && Number.isFinite(b) && a > 0 && b > 0 ? a / b : NaN;
}

/**
 * A feature's value in px. An em is the query container's own font size, and a cq unit is its
 * content box, as those units are everywhere else.
 */
function lengthPx(text: string, container: Node, w: number, h: number): number {
  const l = parseLength(text.trim(), false);
  if (l === null) return NaN;
  if (l.u === P.U_PX) return l.v;
  if (l.u === P.U_EM) return l.v * container.sv[P.P_FONT_SIZE];
  if (l.u === P.U_REM) return l.v * rootFontSize();
  if (l.u === P.U_CQW || l.u === P.U_CQI) return (l.v / 100) * w;
  if (l.u === P.U_CQH || l.u === P.U_CQB) return (l.v / 100) * h;
  if (l.u === P.U_CQMIN) return (l.v / 100) * Math.min(w, h);
  if (l.u === P.U_CQMAX) return (l.v / 100) * Math.max(w, h);
  return NaN;
}

/** `style(--x: value)` tests the query container's computed custom property. */
function styleFeature(text: string, el: Node, names: string[], name: string): number {
  const colon = colonAt(text);
  const prop = (colon < 0 ? text : text.slice(0, colon)).trim();
  if (!prop.startsWith("--")) return UNKNOWN;
  const container = findContainer(el, names, name, false, false, true);
  if (container === null) return UNKNOWN;
  const props = container.cprops;
  const have = props === null ? undefined : props.get(prop);
  if (colon < 0) {
    // Without a value the query asks only that the property is set and not empty.
    return have !== undefined && have !== "" ? TRUE : FALSE;
  }
  const want = squash(text.slice(colon + 1));
  const value = have === undefined ? "" : squash(have);
  // A registered color property's computed value is a color, whichever way it was written: ask
  // the color parser, so `contrast-color(#000)` matches `white` where the texts differ.
  const reg = registeredProperty(prop);
  if (reg !== null && /color/i.test(reg.syntax)) {
    const a = parseColor(value !== "" ? value : reg.initialValue ?? "");
    const b = parseColor(want);
    if (a !== null && b !== null) return a === b ? TRUE : FALSE;
  }
  return value === want ? TRUE : FALSE;
}

/** A custom property value with its whitespace runs collapsed, for comparing two of them. */
function squash(s: string): string {
  let out = "";
  let space = false;
  for (const ch of s) {
    if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || ch === "\f") space = true;
    else {
      if (space && out !== "") out += " ";
      space = false;
      out += ch;
    }
  }
  return out;
}

/**
 * The nearest ancestor `el` can query: a container matching the name the query gives (when it
 * gives one) and eligible for the axes the feature reads.
 */
function findContainer(el: Node, names: string[], name: string, inline: boolean, block: boolean, style: boolean): Node | null {
  for (let p = el.parentElement; p !== null; p = p.parentElement) {
    if (style) {
      // Every element is a query container for container style queries, whatever its type.
    } else {
      const type = p.sv[P.P_CONTAINER_TYPE];
      if (inline && type === P.CT_NORMAL) continue;
      if (block && type !== P.CT_SIZE) continue;
    }
    if (name !== "" && !hasName(p, name, names)) continue;
    return p;
  }
  return null;
}

function hasName(p: Node, name: string, names: string[]): boolean {
  const id = p.sv[P.P_CONTAINER_NAME];
  if (id < 0 || id >= names.length) return false;
  const list = names[id];
  return list === name || (" " + list + " ").indexOf(" " + name + " ") >= 0;
}
