// Declaration blocks and the shared value helpers (keywords, lengths, colors). Shared by the
// compiler (build time) and the runtime (inline style changes), so it stays free of
// Diagnostics and Node APIs.

import * as P from "../props.ts";
import { canonicalSystemColors, hasDeferredCurrentColor, hasLightDark, hasModernColor, hasTextImage, parseColor, urlsInText } from "./colors.ts";
import { familyDecl, fontShorthand } from "./fonts.ts";
import { compileProperty } from "./properties.ts";
import {
  EXPR_ABS, EXPR_ACOS, EXPR_ASIN, EXPR_ATAN, EXPR_ATAN2, EXPR_CLAMP, EXPR_COS, EXPR_EXP, EXPR_HYPOT,
  EXPR_LEAF, EXPR_LOG, EXPR_MAX, EXPR_MIN, EXPR_MOD, EXPR_POW, EXPR_REM, EXPR_ROUND, EXPR_SCALE, EXPR_SIGN,
  EXPR_SIN, EXPR_SQRT, EXPR_SUM, EXPR_TAN, exprRows,
} from "./length-exprs.ts";
import type { ContentContext, Decl, FontContext, Loc } from "./types.ts";
import { customPropertyName, hasVar, validDeclarationValue, wideKeyword } from "./vars.ts";
import { longhandIds } from "./shorthands.ts";

/** Index just past the string starting at `i` (a quote); unterminated strings end the input. */
export function skipString(src: string, i: number): number {
  const q = src[i];
  for (let j = i + 1; j < src.length; j++) {
    if (src[j] === "\\") j++;
    else if (src[j] === q) return j + 1;
  }
  return src.length;
}

/** Splits a declaration block on top-level `;`, ignoring strings, functions and nested blocks. */
export function splitDeclarations(body: string): { text: string; offset: number }[] {
  const out: { text: string; offset: number }[] = [];
  let start = 0;
  let paren = 0, bracket = 0, brace = 0;
  for (let j = 0; j < body.length; j++) {
    const ch = body[j];
    if (ch === '"' || ch === "'") { j = skipString(body, j) - 1; continue; }
    if (ch === "(") paren++;
    else if (ch === ")") paren = Math.max(0, paren - 1);
    else if (ch === "[") bracket++;
    else if (ch === "]") bracket = Math.max(0, bracket - 1);
    else if (ch === "{") brace++;
    else if (ch === "}") brace = Math.max(0, brace - 1);
    else if (ch === ";" && paren === 0 && bracket === 0 && brace === 0) {
      out.push({ text: body.slice(start, j), offset: start });
      start = j + 1;
    }
  }
  out.push({ text: body.slice(start), offset: start });
  return out;
}

/**
 * Compiles one declaration's value into numeric declarations, appending them to `out`.
 * Returns null on success, or a message saying why the value was ignored. `loc` locates the
 * declaration in its source, for a resource a value names (an image URL) to report on.
 */
export function compileValue(prop: string, value: string, out: Decl[], fonts?: FontContext, loc?: Loc, content?: ContentContext): string | null {
  // A CSS-wide keyword is valid for every property and is resolved when the style is computed:
  // against the parent's value for `inherit` (and for `unset`/`revert`/`revert-layer` on an
  // inherited property), and against the initial value otherwise. It is kept as text, like a
  // var() value, so the runtime can do that with the property's longhands in hand.
  const keyword = wideKeyword(value);
  if (keyword !== "") {
    // `all` stands for every property, and its only values are the CSS-wide keywords; the runtime
    // applies the keyword to each property at this declaration's place in the cascade.
    if (prop === "all") {
      out.push({ p: -1, v: 0, u: 0, prop, value: keyword });
      return null;
    }
    if (longhandIds(prop) === null) return `'${prop}' is not supported yet; ignored`;
    out.push({ p: -1, v: 0, u: 0, prop, value: keyword });
    return null;
  }
  if (prop === "all") return "'all' takes a CSS-wide keyword (initial, inherit, unset, revert or revert-layer)";
  if (prop === "font-family") return familyDecl(prop, value, out, fonts);
  if (prop === "font") return fontShorthand(value, out, fonts);
  return compileProperty(prop, foldColorCalcs(value), out, fonts, loc, content);
}

/** One `property: value` chunk of a declaration block, compiled. */
export interface ParsedDeclaration {
  /** Lower-case property name; "" when the chunk has no colon. */
  prop: string;
  /** The value text, without a trailing "!important". */
  value: string;
  important: boolean;
  /** Offset of the chunk's first character within the block. */
  offset: number;
  /** Leading whitespace inside the chunk, so a diagnostic points at the property. */
  lead: number;
  /** The chunk, trimmed, for "expected 'property: value'" messages. */
  text: string;
  /** True for an empty chunk, which has no declaration to report. */
  blank: boolean;
  /** The declarations the value compiled to; empty when the value was ignored. */
  decls: Decl[];
  /** Why the value was ignored, or null. */
  error: string | null;
}

/**
 * Splits and compiles a declaration block (a style attribute, or a rule's body), keeping a
 * per-declaration record so the caller can report diagnostics. Declarations that don't compile
 * are kept with their `error` and no declarations, as a browser drops them one by one.
 */
export function parseDeclarationBlock(body: string, fonts?: FontContext, loc?: (offset: number) => Loc, content?: ContentContext): ParsedDeclaration[] {
  const out: ParsedDeclaration[] = [];
  for (const { text: chunk, offset } of splitDeclarations(body)) {
    const lead = chunk.length - chunk.trimStart().length;
    const text = chunk.trim();
    const parsed: ParsedDeclaration = {
      prop: "", value: "", important: false, offset, lead, text, blank: text === "", decls: [], error: null,
    };
    out.push(parsed);
    if (parsed.blank) continue;
    const colon = chunk.indexOf(":");
    if (colon < 0) {
      parsed.error = `expected 'property: value', got '${text}'`;
      continue;
    }
    // A custom property name is case-sensitive; every other property name isn't.
    const named = chunk.slice(0, colon).trim();
    parsed.prop = named.startsWith("--") ? named : named.toLowerCase();
    let value = chunk.slice(colon + 1).trim();
    parsed.important = /!\s*important\s*$/i.test(value);
    if (parsed.important) value = value.replace(/\s*!\s*important\s*$/i, "");
    parsed.value = value;
    if (parsed.prop.startsWith("--")) {
      // The name is decoded here, so `--\30` and `--0` are the same property.
      const name = customPropertyName(named);
      if (name === null) {
        parsed.error = `invalid custom property name '${named}': it must be two dashes and a name`;
        continue;
      }
      parsed.prop = name;
      // A value that isn't a <declaration-value> is a parse error, so the declaration is dropped
      // and an earlier declaration of the same name stays in force.
      if (!validDeclarationValue(value)) {
        parsed.error = `invalid custom property value '${value}': a '!' or ';' outside a function, or an unbalanced bracket, ends the declaration`;
        continue;
      }
      parsed.decls.push({ p: -1, v: 0, u: 0, important: parsed.important, prop: name, value });
      continue;
    }
    // A system colour's value depends on the color-scheme the element is drawn in, so a value that
    // names one is held as text and resolved where the scheme is known. The keyword stays in the
    // text — spelled the way CSS serializes it — so style.color and cssText read back a colour
    // name rather than the var() the computed value resolves through.
    const canonical = canonicalSystemColors(parsed.prop, value);
    // A background image whose text is its computed form is held as text too, so CSSOM can read
    // the url back instead of the packed row.
    const textImage = parsed.prop === "background-image" && hasTextImage(value);
    if (hasVar(value) || hasLightDark(value) || hasDeferredCurrentColor(value) || hasModernColor(parsed.prop, value) || textImage || canonical !== value) {
      // A value using a var() has no numeric form until the element's custom properties are
      // known, so it is held as text and compiled once its style is being computed.
      if (!validDeclarationValue(canonical)) {
        parsed.error = `invalid value '${value}': a '!' or ';' outside a function, or an unbalanced bracket, ends the declaration`;
        continue;
      }
      // A background image kept as text is compiled again where the style is computed, and that
      // build has no site root to resolve a URL against: the images it names are resolved here,
      // against the file the declaration is written in, so the runtime finds them by their text.
      if (textImage) {
        const [line, col] = loc ? loc(offset + lead) : [1, 1];
        for (const url of urlsInText(canonical)) fonts?.image(url, line, col);
      }
      parsed.decls.push({ p: -1, v: 0, u: 0, important: parsed.important, prop: parsed.prop, value: canonical });
      continue;
    }
    parsed.error = compileValue(parsed.prop, value, parsed.decls, fonts, loc ? loc(offset + lead) : undefined, content);
    // Everything a declaration compiled to carries its importance.
    if (parsed.important) for (const d of parsed.decls) d.important = true;
  }
  return out;
}

export function kw(prop: string, value: string, table: Record<string, number>, p: number, out: Decl[]): string | null {
  const v = table[value.toLowerCase()];
  if (v === undefined) return `unsupported value '${value}' for '${prop}' (supported: ${Object.keys(table).join(", ")})`;
  out.push({ p, v, u: P.U_NONE });
  return null;
}

export interface Len { v: number; u: number }

/** Splits a function's arguments on top-level commas, so nested functions stay whole. */
function exprArgs(s: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if (ch === "," && depth === 0) {
      out.push(s.slice(start, i));
      start = i + 1;
    }
  }
  out.push(s.slice(start));
  return out;
}

/** A term of a calc() expression: a length, or a plain number when `l` is null. */
interface CalcTerm { l: Len | null; n: number }

/** Is the whole string one parenthesised group? */
function wrapped(s: string): boolean {
  if (s[0] !== "(" || s[s.length - 1] !== ")") return false;
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "(") depth++;
    else if (s[i] === ")") {
      depth--;
      if (depth === 0) return i === s.length - 1;
    }
  }
  return false;
}

/** The row id of a length, which is the length itself when it is already an expression. */
function exprId(l: Len): number {
  return l.u === P.U_EXPR ? l.v : exprRows.register([EXPR_LEAF, l.v, l.u]);
}

/**
 * Can this length be a term of an expression row? An em leaf is evaluated at used-value time
 * against the element's own font size, which `evalExpr` takes.
 */
function inRow(l: Len): boolean {
  return l.u === P.U_EXPR || l.u === P.U_PX || l.u === P.U_PCT || l.u === P.U_VW || l.u === P.U_VH ||
    l.u === P.U_EM || l.u === P.U_REM || l.u === P.U_LH || (l.u >= P.U_CQW && l.u <= P.U_CQMAX);
}

/** A length times a number; a plain length folds, an expression gets a scale row. */
function scaleLen(l: Len, f: number): Len {
  if (f === 1) return l;
  if (l.u !== P.U_EXPR) return { v: l.v * f, u: l.u };
  return { v: exprRows.register([EXPR_SCALE, l.v, f]), u: P.U_EXPR };
}

/** Two lengths added; same-unit leaves fold, anything else becomes a sum row. */
function addLen(a: Len, b: Len): Len | null {
  if (a.u === b.u && a.u !== P.U_EXPR) return { v: a.v + b.v, u: a.u };
  if (!inRow(a) || !inRow(b)) return null;
  return { v: exprRows.register([EXPR_SUM, 2, exprId(a), exprId(b)]), u: P.U_EXPR };
}

/** A calc() term: a parenthesised sum, a length (which may be min()/max()/clamp()/calc()),
 *  or a plain number. */
function calcTerm(s: string, allowAuto: boolean): CalcTerm | null {
  s = s.trim();
  if (s === "") return null;
  if (wrapped(s)) return calcSum(s.slice(1, s.length - 1), allowAuto);
  // A nested calc() is a term in its own right, as in Tailwind's `calc(var(--spacing) * calc(1 - var(--x)))`.
  if (s.startsWith("calc(") && s[s.length - 1] === ")") return calcSum(s.slice(5, s.length - 1), allowAuto);
  // The infinity constant, which `calc(infinity * 1px)` uses to mean "as large as it can be".
  if (s === "infinity" || s === "+infinity") return { l: null, n: Infinity };
  if (s === "-infinity") return { l: null, n: -Infinity };
  const num = /^[-+]?(?:\d+\.?\d*|\.\d+)$/.exec(s);
  if (num !== null) return { l: null, n: parseFloat(num[0]) };
  const l = parseLength(s, allowAuto);
  return l === null ? null : { l, n: 0 };
}

/** a * b or a / b: a number scales a length; two lengths multiplied or divided are not a length. */
function calcProductTerm(a: CalcTerm, b: CalcTerm, op: string): CalcTerm | null {
  if (op === "*") {
    const al = a.l;
    const bl = b.l;
    if (al !== null && bl !== null) return null;
    if (al !== null) return { l: scaleLen(al, b.n), n: 0 };
    if (bl !== null) return { l: scaleLen(bl, a.n), n: 0 };
    return { l: null, n: a.n * b.n };
  }
  if (b.l !== null || b.n === 0) return null;
  if (a.l === null) return { l: null, n: a.n / b.n };
  return { l: scaleLen(a.l, 1 / b.n), n: 0 };
}

/** One or more calc() terms multiplied and divided, left to right. */
function calcProduct(s: string, allowAuto: boolean): CalcTerm | null {
  const seq: { text: string; op: string }[] = [];
  let depth = 0, start = 0, op = "*";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (depth === 0 && (ch === "*" || ch === "/")) {
      seq.push({ text: s.slice(start, i), op });
      op = ch;
      start = i + 1;
    }
  }
  seq.push({ text: s.slice(start), op });
  let acc = calcTerm(seq[0].text, allowAuto);
  if (acc === null) return null;
  for (let k = 1; k < seq.length; k++) {
    const t = calcTerm(seq[k].text, allowAuto);
    if (t === null) return null;
    acc = calcProductTerm(acc, t, seq[k].op);
    if (acc === null) return null;
  }
  return acc;
}

/** calc()'s terms added and subtracted. CSS needs whitespace around the signs, so `10px+5px`
 *  stays one (invalid) token rather than splitting here. */
function calcSum(s: string, allowAuto: boolean): CalcTerm | null {
  const seq: { text: string; sign: number }[] = [];
  let depth = 0, start = 0, sign = 1;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (depth === 0 && (ch === "+" || ch === "-") && i > 0 && /\s/.test(s[i - 1]) &&
      i + 1 < s.length && /\s/.test(s[i + 1])) {
      seq.push({ text: s.slice(start, i), sign });
      sign = ch === "+" ? 1 : -1;
      start = i + 1;
    }
  }
  seq.push({ text: s.slice(start), sign });
  let acc: CalcTerm | null = calcProduct(seq[0].text, allowAuto);
  if (acc === null) return null;
  for (let k = 1; k < seq.length; k++) {
    const t = calcProduct(seq[k].text, allowAuto);
    if (t === null) return null;
    const signed: CalcTerm = seq[k].sign === 1 ? t : t.l === null ? { l: null, n: -t.n } : { l: scaleLen(t.l, -1), n: 0 };
    const a: Len | null = acc.l;
    const b: Len | null = signed.l;
    if (a !== null && b !== null) {
      const sum = addLen(a, b);
      if (sum === null) return null;
      acc = { l: sum, n: 0 };
    } else if (a !== null) {
      // A unitless zero is a zero length in a sum, as `calc(1px + 0)` has it (a custom property
      // that held `0px` serialises as `0`).
      if (signed.n !== 0) return null;
      acc = { l: a, n: 0 };
    } else if (b !== null) {
      if (acc.n !== 0) return null;
      acc = { l: b, n: 0 };
    } else {
      acc = { l: null, n: acc.n + signed.n };
    }
  }
  return acc;
}

/**
 * The longest length CSS keeps. `calc(infinity * 1px)`, which Tailwind's `rounded-full` writes,
 * means "as large as the box allows"; it becomes this bound, and the corner-overlap scaling
 * brings a radius down to what actually fits.
 */
const MAX_LENGTH = 1e7;

/** A calc() length. Null when it isn't one, or when it doesn't resolve to a length this build
 *  can evaluate. */
function parseCalc(s: string, allowAuto: boolean): Len | null {
  if (!s.startsWith("calc(") || s[s.length - 1] !== ")") return null;
  const t = calcSum(s.slice(5, s.length - 1), allowAuto);
  if (t === null || t.l === null) return null;
  const l = t.l;
  if (!Number.isFinite(l.v)) l.v = l.v < 0 ? -MAX_LENGTH : MAX_LENGTH;
  return l;
}

/** A calc() that works out to a plain number, such as line-height's `calc(1.75 / 1.25)`. It
 *  folds at build time, since a number has no percentage or font size to wait for. */
export function calcNumber(s: string): number | null {
  s = s.trim().toLowerCase();
  if (!s.startsWith("calc(") || s[s.length - 1] !== ")") return null;
  const t = calcSum(s.slice(5, s.length - 1), false);
  if (t === null || t.l !== null || Number.isNaN(t.n)) return null;
  return t.n;
}

// --- Angles -------------------------------------------------------------------
// An angle has no size to wait for either, so a calc() of angles folds here too. `angleSum` and
// `angleProduct` follow the same grammar as calcSum and calcProduct above, over terms that are
// either an angle (in radians) or a plain number.

interface AngleTerm { v: number; angle: boolean }

/** An angle or a number, a parenthesised sum, or a nested calc(). */
function angleAtom(s: string): AngleTerm | null {
  s = s.trim();
  if (s === "") return null;
  if (wrapped(s)) return angleSum(s.slice(1, s.length - 1));
  if (s.startsWith("calc(") && s[s.length - 1] === ")") return angleSum(s.slice(5, s.length - 1));
  const m = /^([-+]?(?:\d+\.?\d*|\.\d+))(deg|grad|rad|turn)?$/.exec(s);
  if (m === null) return null;
  const n = parseFloat(m[1]);
  if (m[2] === undefined) return { v: n, angle: false };
  const v = m[2] === "deg" ? (n * Math.PI) / 180
    : m[2] === "grad" ? (n * Math.PI) / 200
    : m[2] === "turn" ? n * 2 * Math.PI
    : n;
  return { v, angle: true };
}

/** Terms multiplied and divided, left to right: a number scales an angle, and two angles divide
 *  into a number, as CSS's type algebra allows. */
function angleProduct(s: string): AngleTerm | null {
  const seq: { text: string; op: string }[] = [];
  let depth = 0, start = 0, op = "*";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (depth === 0 && (ch === "*" || ch === "/")) {
      seq.push({ text: s.slice(start, i), op });
      op = ch;
      start = i + 1;
    }
  }
  seq.push({ text: s.slice(start), op });
  const first = angleAtom(seq[0].text);
  if (first === null) return null;
  let acc = first;
  for (let k = 1; k < seq.length; k++) {
    const t = angleAtom(seq[k].text);
    if (t === null) return null;
    if (seq[k].op === "*") {
      if (acc.angle && t.angle) return null;
      acc = { v: acc.v * t.v, angle: acc.angle || t.angle };
    } else {
      if (t.v === 0 || (!acc.angle && t.angle)) return null;
      acc = { v: acc.v / t.v, angle: acc.angle && !t.angle };
    }
  }
  return acc;
}

/** Terms added and subtracted, which needs both sides to be the same kind of value. */
function angleSum(s: string): AngleTerm | null {
  const seq: { text: string; sign: number }[] = [];
  let depth = 0, start = 0, sign = 1;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (depth === 0 && (ch === "+" || ch === "-") && i > 0 && /\s/.test(s[i - 1]) &&
      i + 1 < s.length && /\s/.test(s[i + 1])) {
      seq.push({ text: s.slice(start, i), sign });
      sign = ch === "+" ? 1 : -1;
      start = i + 1;
    }
  }
  seq.push({ text: s.slice(start), sign });
  const first = angleProduct(seq[0].text);
  if (first === null) return null;
  let acc = first;
  for (let k = 1; k < seq.length; k++) {
    const t = angleProduct(seq[k].text);
    if (t === null) return null;
    if (t.angle !== acc.angle) return null;
    acc = { v: acc.v + seq[k].sign * t.v, angle: acc.angle };
  }
  return acc;
}

/** A calc() of angles, in radians: `calc(45deg * 2)`, `calc(1turn / 4)`, `calc(0deg + 90deg)`.
 *  Null when it isn't one or doesn't work out to an angle. */
export function calcAngle(s: string): number | null {
  s = s.trim().toLowerCase();
  if (!s.startsWith("calc(") || s[s.length - 1] !== ")") return null;
  const t = angleSum(s.slice(5, s.length - 1));
  return t === null || !t.angle || !Number.isFinite(t.v) ? null : t.v;
}

// --- calc() in colour components ----------------------------------------------

const COLOR_FUNCTIONS = new Set([
  "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color", "color-mix", "device-cmyk",
]);

/** One calc() folded to the plain number or percentage it stands for, or null when it is
 *  something else (a length, say) or doesn't fold. */
function foldedCalc(t: string): string | null {
  const n = calcNumber(t);
  if (n !== null) return String(n);
  const l = parseLength(t, false);
  if (l !== null && l.u === P.U_PCT) return String(l.v) + "%";
  return null;
}

/** Rewrites each calc() inside `s` to the number or percentage it works out to. */
function foldCalcsIn(s: string): string {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    if (s.startsWith("calc(", i)) {
      let close = i + 5, depth = 1;
      while (close < s.length && depth > 0) {
        if (s[close] === "(") depth++;
        else if (s[close] === ")") depth--;
        close++;
      }
      if (depth === 0) {
        const folded = foldedCalc(s.slice(i, close));
        if (folded !== null) {
          out += folded;
          i = close - 1;
          continue;
        }
      }
    }
    out += s[i];
  }
  return out;
}

/**
 * Folds the calc()s inside a colour function's arguments to plain numbers and percentages, so
 * that `hsl(calc(var(--hue) + 40), 80%, 50%)` reads as `hsl(40, 80%, 50%)` once its var() has
 * been substituted. A colour channel is a number computed on its own, so this can happen at
 * build time; nothing outside a colour function is touched.
 */
function foldColorCalcs(value: string): string {
  if (value.indexOf("calc(") < 0) return value;
  let out = "";
  for (let i = 0; i < value.length; i++) {
    if (value[i] !== "(") { out += value[i]; continue; }
    // Only a colour function's own arguments are rewritten; any other function, a gradient's for
    // one, is walked through so that the colours inside it are still found.
    let start = i;
    while (start > 0 && /[a-zA-Z-]/.test(value[start - 1])) start--;
    if (!COLOR_FUNCTIONS.has(value.slice(start, i).toLowerCase())) { out += value[i]; continue; }
    let close = i + 1, depth = 1;
    while (close < value.length && depth > 0) {
      if (value[close] === "(") depth++;
      else if (value[close] === ")") depth--;
      close++;
    }
    if (depth !== 0) { out += value[i]; continue; }
    out += "(" + foldCalcsIn(value.slice(i + 1, close - 1)) + ")";
    i = close - 1;
  }
  return out;
}

/** Set when a math function's arguments fail CSS's type checking, so the caller can report an
 *  invalid value instead of an unsupported one: a browser drops the declaration either way. */
let mathInvalid = false;

function takeMathInvalid(): boolean {
  const v = mathInvalid;
  mathInvalid = false;
  return v;
}

/** The math functions whose value is a length: their rows the length properties take. */
const LENGTH_MATH = new Set(["min", "max", "clamp", "round", "mod", "rem", "abs", "sign"]);

/** The math functions whose value is a number or an angle: invalid where a length is wanted. */
const NUMBER_MATH = new Set(["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "pow", "sqrt", "hypot",
  "log", "exp"]);

/** One math function argument: a number row, or a length row (a bare 0 is a number). */
function mathArg(a: string): { id: number; number: boolean } | null {
  if (/^[-+]?0*(\.0*)?$/.test(a)) return { id: exprRows.register([EXPR_LEAF, 0, P.U_NONE]), number: true };
  if (/^[-+]?(?:\d+\.?\d*|\.\d+)$/.test(a)) {
    return { id: exprRows.register([EXPR_LEAF, parseFloat(a), P.U_NONE]), number: true };
  }
  const l = parseLength(a, false);
  if (l === null || !inRow(l)) return null;
  return { id: exprRows.register([EXPR_LEAF, l.v, l.u]), number: false };
}

/** An angle argument as a row, kept in degrees: a plain number is radians, and a percentage or a
 *  length isn't an angle at all. */
function angleArg(a: string): number | null {
  const m = /^([-+]?(?:\d+\.?\d*|\.\d+))(deg|grad|rad|turn)?$/.exec(a);
  if (m === null) return null;
  const n = parseFloat(m[1]);
  if (m[2] === undefined) return exprRows.register([EXPR_LEAF, (n * 180) / Math.PI, P.U_DEG]);
  const deg = m[2] === "rad" ? (n * 180) / Math.PI : m[2] === "grad" ? n * 0.9 : m[2] === "turn" ? n * 360 : n;
  return exprRows.register([EXPR_LEAF, deg, P.U_DEG]);
}

/**
 * A max()/min()/clamp() or other math function in a length, registered as a row and returned as a
 * length with unit U_EXPR. Null for anything else, or for arguments that aren't lengths this build
 * can evaluate; a function whose value is a number can't stand for a length either.
 */
function parseExpr(s: string, allowAuto: boolean): Len | null {
  const open = s.indexOf("(");
  if (open < 1 || s[s.length - 1] !== ")") return null;
  const name = s.slice(0, open);
  if (!LENGTH_MATH.has(name) && !NUMBER_MATH.has(name)) return null;
  mathInvalid = false;
  let args = exprArgs(s.slice(open + 1, s.length - 1)).map((a) => a.trim());
  // round() may name a strategy first; without one it is `nearest`.
  let strategy = 0;
  if (name === "round" && args.length > 0) {
    const s0 = args[0].toLowerCase();
    const at = s0 === "nearest" ? 0 : s0 === "up" ? 1 : s0 === "down" ? 2 : s0 === "to-zero" ? 3 : -1;
    if (at >= 0) {
      strategy = at;
      args = args.slice(1);
    }
    if (args.length < 1 || args.length > 2) return null;
  }
  if (name === "clamp" ? args.length !== 3 : args.length < 1) return null;
  if (name === "sin" || name === "cos" || name === "tan") {
    if (args.length !== 1) return null;
    const id = angleArg(args[0]);
    if (id === null) { mathInvalid = true; return null; }
    exprRows.register([name === "sin" ? EXPR_SIN : name === "cos" ? EXPR_COS : EXPR_TAN, id]);
    mathInvalid = true; // its value is a number, not a length
    return null;
  }
  if (NUMBER_MATH.has(name)) {
    const arity = name === "atan2" || name === "pow" ? 2 : name === "log" ? args.length : 1;
    if (name === "hypot" ? args.length < 1 : args.length !== arity) return null;
    const ids: number[] = [];
    for (const a of args) {
      const m = mathArg(a);
      if (m === null || !m.number) { mathInvalid = true; return null; }
      ids.push(m.id);
    }
    const op = name === "asin" ? EXPR_ASIN : name === "acos" ? EXPR_ACOS : name === "atan" ? EXPR_ATAN
      : name === "atan2" ? EXPR_ATAN2 : name === "pow" ? EXPR_POW : name === "sqrt" ? EXPR_SQRT
      : name === "hypot" ? EXPR_HYPOT : name === "log" ? EXPR_LOG : EXPR_EXP;
    if (name === "hypot") exprRows.register([op, ids.length, ...ids]);
    else if (name === "log") exprRows.register([op, ids[0], ids.length > 1 ? ids[1] : -1]);
    else exprRows.register([op, ...ids]);
    mathInvalid = true; // its value is a number or an angle, not a length
    return null;
  }
  const ids: number[] = [];
  // The arguments are all lengths or all numbers: a bare 0 is a number, so min(0, 100%) doesn't
  // type check and the declaration is invalid (CSS Values 4, the calc() type rules).
  let numbers = false;
  for (let k = 0; k < args.length; k++) {
    const bareZero = /^[-+]?0*(\.0*)?$/.test(args[k]);
    const l = parseLength(args[k], allowAuto);
    // A leaf the runtime can't evaluate on its own — `lh`, which is resolved against the
    // element's line height before the value is stored — can't go into a row.
    if (l === null || !inRow(l)) return null;
    const isNumber = bareZero;
    if (k === 0) numbers = isNumber;
    else if (isNumber !== numbers) {
      mathInvalid = true;
      return null;
    }
    ids.push(exprRows.register(isNumber ? [EXPR_LEAF, 0, P.U_NONE] : [EXPR_LEAF, l.v, l.u]));
  }
  if (name === "round") {
    const step = ids.length > 1 ? ids[1] : exprRows.register([EXPR_LEAF, 1, numbers ? P.U_NONE : P.U_PX]);
    return { v: exprRows.register([EXPR_ROUND, strategy, ids[0], step]), u: P.U_EXPR };
  }
  if (name === "mod" || name === "rem") {
    if (ids.length !== 2) return null;
    const op = name === "mod" ? EXPR_MOD : EXPR_REM;
    return { v: exprRows.register([op, ids[0], ids[1]]), u: P.U_EXPR };
  }
  if (name === "abs" || name === "sign") {
    if (ids.length !== 1) return null;
    return { v: exprRows.register([name === "abs" ? EXPR_ABS : EXPR_SIGN, ids[0]]), u: P.U_EXPR };
  }
  const row = name === "clamp"
    ? [EXPR_CLAMP, 3, ids[0], ids[1], ids[2]]
    : [name === "min" ? EXPR_MIN : EXPR_MAX, ids.length, ...ids];
  return { v: exprRows.register(row), u: P.U_EXPR };
}

// Absolute units, in CSS pixels (1in is 96px by definition).
const ABSOLUTE_PX: Record<string, number> = {
  in: 96, cm: 96 / 2.54, mm: 96 / 25.4, q: 96 / 101.6, pt: 96 / 72, pc: 16,
};

export function parseLength(s: string, allowAuto: boolean, allowIntrinsic: boolean = false): Len | null {
  s = s.trim().toLowerCase();
  if (allowAuto && s === "auto") return { v: 0, u: P.U_AUTO };
  // The intrinsic sizing keywords, which only the width and height properties take.
  if (allowIntrinsic) {
    if (s === "min-content") return { v: 0, u: P.U_MIN_CONTENT };
    if (s === "max-content") return { v: 0, u: P.U_MAX_CONTENT };
    if (s === "fit-content") return { v: 0, u: P.U_FIT_CONTENT };
    // The fill-available keywords: the space left in the axis once the box's margins are taken
    // out, or auto while that space is indefinite (CSS Sizing 4 §5). The webkit spelling is the
    // same size under its old name.
    if (s === "stretch" || s === "-webkit-fill-available") return { v: 0, u: P.U_STRETCH };
  }
  // The safe-area insets are zero on macOS (there is no notch or rounded screen corner to avoid).
  if (s.startsWith("env(") && s.endsWith(")")) {
    const name = s.slice(4, s.length - 1).trim();
    if (name === "safe-area-inset-top" || name === "safe-area-inset-right" ||
      name === "safe-area-inset-bottom" || name === "safe-area-inset-left") return { v: 0, u: P.U_PX };
    return null;
  }
  const fn = parseExpr(s, allowAuto);
  if (fn !== null) return fn;
  const calc = parseCalc(s, allowAuto);
  if (calc !== null) return calc;
  // A number may carry an explicit sign and an exponent (CSS's `<number>` grammar, which
  // Tailwind uses for `rounded-full`'s 3.40282e38px), and a unitless length is only valid when
  // it is zero.
  const m = /^([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)(px|%|vw|vh|em|lh|rem|in|cm|mm|q|pt|pc|ex|ch|cqw|cqh|cqi|cqb|cqmin|cqmax)?$/.exec(s);
  if (!m) return null;
  const n = parseFloat(m[1]);
  const unit = m[2];
  if (unit === undefined) return n === 0 ? { v: 0, u: P.U_PX } : null;
  switch (unit) {
    case "px": return { v: n, u: P.U_PX };
    case "%": return { v: n, u: P.U_PCT };
    case "vw": return { v: n, u: P.U_VW };
    case "vh": return { v: n, u: P.U_VH };
    case "em": return { v: n, u: P.U_EM };
    case "lh": return { v: n, u: P.U_LH }; // resolved against the used line height
    case "rem": return { v: n, u: P.U_REM }; // a multiple of the root's font size
    case "cqw": return { v: n, u: P.U_CQW };
    case "cqh": return { v: n, u: P.U_CQH };
    case "cqi": return { v: n, u: P.U_CQI };
    case "cqb": return { v: n, u: P.U_CQB };
    case "cqmin": return { v: n, u: P.U_CQMIN };
    case "cqmax": return { v: n, u: P.U_CQMAX };
    case "ex": return { v: n, u: P.U_EX };
    case "ch": return { v: n, u: P.U_CH };
  }
  const abs = ABSOLUTE_PX[unit];
  if (abs !== undefined) return { v: n * abs, u: P.U_PX };
  return null;
}

/** Splits a 1-to-4 value list on whitespace that isn't inside a function. */
function lengthParts(value: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = -1;
  const push = (end: number) => {
    if (start >= 0) out.push(value.slice(start, end));
    start = -1;
  };
  for (let i = 0; i < value.length; i++) {
    const ch = value[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    if (depth === 0 && /\s/.test(ch)) push(i);
    else if (start < 0) start = i;
  }
  push(value.length);
  return out;
}

export function lengths(prop: string, value: string, props: number[], allowAuto: boolean, out: Decl[], nonNegative: boolean = false): string | null {
  const parts = lengthParts(value);
  if (parts.length < 1 || parts.length > 4) return `'${prop}' takes 1 to 4 values`;
  const ls: Len[] = [];
  for (const part of parts) {
    const l = parseLength(part, allowAuto);
    if (!l) {
      return takeMathInvalid()
        ? `invalid value '${part}' for '${prop}': its arguments mix a number with a length, so the declaration is ignored`
        : `unsupported length '${part}' for '${prop}'`;
    }
    if (nonNegative && l.v < 0) return `invalid value '${part}' for '${prop}': it can't be negative, so the declaration is ignored`;
    ls.push(l);
  }
  const [t, r = t, b = t, l = r] = ls;
  const sides = [t, r, b, l];
  for (let k = 0; k < 4; k++) out.push({ p: props[k], v: sides[k].v, u: sides[k].u });
  return null;
}

/** A length property. `nonNegative` rejects the negative values CSS makes the declaration invalid. */
export function single(prop: string, value: string, p: number, allowAuto: boolean, out: Decl[], nonNegative: boolean = false, allowIntrinsic: boolean = false): string | null {
  const l = parseLength(value, allowAuto, allowIntrinsic);
  if (!l) {
    return takeMathInvalid()
      ? `invalid value '${value}' for '${prop}': its arguments mix a number with a length, so the declaration is ignored`
      : `unsupported value '${value}' for '${prop}'`;
  }
  if (nonNegative && l.u !== P.U_AUTO && l.v < 0) return `invalid value '${value}' for '${prop}': it can't be negative, so the declaration is ignored`;
  out.push({ p, v: l.v, u: l.u });
  return null;
}

/**
 * A two-sided logical shorthand (`margin-inline`, `padding-block`): one value for both sides, or
 * the start side's value then the end side's.
 */
export function pair(prop: string, value: string, start: number, end: number, allowAuto: boolean, out: Decl[],
  nonNegative: boolean = false): string | null {
  // Split like a physical 1-to-4 list does, so a math function's spaces stay inside its parentheses.
  const parts = lengthParts(value);
  if (parts.length < 1 || parts.length > 2) return `invalid value '${value}' for '${prop}'`;
  const a = single(prop, parts[0], start, allowAuto, out, nonNegative);
  if (a !== null) return a;
  return single(prop, parts[parts.length - 1], end, allowAuto, out, nonNegative);
}

export function colorDecl(prop: string, value: string, p: number, out: Decl[]): string | null {
  // currentColor is the element's own colour, which only its style knows: it is kept as the -1
  // sentinel the painters and the style pass already use for it.
  if (value.trim().toLowerCase() === "currentcolor") {
    out.push({ p, v: -1, u: P.U_NONE });
    return null;
  }
  const c = parseColor(value);
  if (c === null) return `unsupported color '${value}' for '${prop}'`;
  out.push({ p, v: c, u: P.U_NONE });
  return null;
}
