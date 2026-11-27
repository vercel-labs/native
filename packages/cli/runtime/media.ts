// Media queries: `@media` conditions and the matchMedia API, evaluated against the viewport and
// the system's settings. The style engine and the window share this, so they agree.

import * as P from "../shared/props.ts";
import { calcNumber as calcValue, parseLength } from "../shared/css/declarations.ts";
import { evalExpr } from "../shared/css/length-exprs.ts";
import { viewport } from "./viewport.ts";
import {
  hostBackingScale, hostColorScheme, hostFontXHeight, hostIncreaseContrast, hostMeasureText,
  hostMediaType, hostReduceTransparency, hostReducedMotion,
} from "./host.ts";

// The system's settings, read now and again as the app runs: switching the appearance or an
// accessibility setting changes which queries match.
let scheme = hostColorScheme() !== 0 ? "dark" : "light";
let contrast = hostIncreaseContrast();
let transparency = hostReduceTransparency();
let motion = hostReducedMotion();
// The media type the page is laid out for: screen unless NATIVE_MEDIA=print asks for print media.
const mediaType = hostMediaType() !== 0 ? "print" : "screen";

/** Reads the system settings again; true when one of them changed under the running app. */
export function refreshSystemSettings(): boolean {
  const nextScheme = hostColorScheme() !== 0 ? "dark" : "light";
  const nextContrast = hostIncreaseContrast();
  const nextTransparency = hostReduceTransparency();
  const nextMotion = hostReducedMotion();
  const changed = nextScheme !== scheme || nextContrast !== contrast ||
    nextTransparency !== transparency || nextMotion !== motion;
  scheme = nextScheme;
  contrast = nextContrast;
  transparency = nextTransparency;
  motion = nextMotion;
  return changed;
}

/** The advance of "0" in the initial font: the `ch` a media query has no element to take it from. */
function initialCh(): number {
  return hostMeasureText("0", 16, 0, 0, 0);
}

/** The initial font's x-height: the `ex` a media query has no element to take it from. */
function initialEx(): number {
  return hostFontXHeight(16, 0);
}

/**
 * A media query length in px. A media query has no element, so em is the initial font size of
 * 16px (and rem is fixed at 16px when it is parsed), and a calc()/min()/max()/clamp() has no
 * percentage base but may use the viewport units.
 */
function mediaLength(value: string): number {
  const l = parseLength(value, false);
  if (l === null) return 0;
  if (l.u === P.U_EXPR) {
    const px = evalExpr(l.v, 0, viewport.w, viewport.h, 16);
    return Number.isNaN(px) ? 0 : px;
  }
  if (l.u === P.U_EM) return l.v * 16;
  if (l.u === P.U_CH) return l.v * initialCh();
  if (l.u === P.U_EX) return l.v * initialEx();
  if (l.u === P.U_VW) return (viewport.w * l.v) / 100;
  if (l.u === P.U_VH) return (viewport.h * l.v) / 100;
  if (l.u === P.U_PCT) return 0; // a percentage has no base in a media query
  return l.v; // px
}

/** The numeric features: their value is a number a range can be compared against. */
function numericFeature(name: string): number {
  switch (name) {
    case "width": case "device-width": return viewport.w;
    case "height": case "device-height": return viewport.h;
    case "aspect-ratio": case "device-aspect-ratio": return viewport.w / Math.max(1, viewport.h);
    case "resolution": case "device-pixel-ratio": return hostBackingScale();
    case "color": return 8;
    case "color-index": return 0;
    case "monochrome": return 0;
    case "grid": return 0;
    default: return NaN;
  }
}

/** The keyword features: their value is one word. Null for a name this build doesn't know. */
function keywordFeature(name: string): string | null {
  switch (name) {
    case "orientation": return viewport.w >= viewport.h ? "landscape" : "portrait";
    case "hover": case "any-hover": return "hover";
    case "pointer": case "any-pointer": return "fine";
    case "prefers-color-scheme": return scheme;
    case "prefers-contrast": return contrast !== 0 ? "more" : "no-preference";
    case "prefers-reduced-transparency": return transparency !== 0 ? "reduce" : "no-preference";
    case "prefers-reduced-motion": return motion !== 0 ? "reduce" : "no-preference";
    case "prefers-reduced-data": return "no-preference";
    case "forced-colors": return "none";
    case "color-gamut": return "srgb";
    case "dynamic-range": case "video-dynamic-range": return "standard";
    case "scripting": return "enabled";
    case "update": return "fast";
    case "display-mode": return "browser";
    case "display-state": return "normal";
    case "resizable": return "true";
    case "inverted-colors": return "none";
    case "navigation-controls": return "none";
    case "scan": return "progressive";
    case "overflow-block": case "overflow-inline": return "scroll";
    default: return null;
  }
}

/** A dimensionless calc() worked out here, or NaN. */
function calcNumber(t: string): number {
  const n = calcValue(t);
  if (n !== null) return n;
  if (!t.startsWith("min(") && !t.startsWith("max(") && !t.startsWith("clamp(")) return NaN;
  const l = parseLength(t, false);
  if (l === null || l.u !== P.U_EXPR) return NaN;
  const px = evalExpr(l.v, 0, viewport.w, viewport.h, 16);
  return Number.isNaN(px) ? NaN : px;
}

/** A feature value as a number, for the range syntax and min-/max- prefixes: px, a ratio, dppx. */
function featureNumber(name: string, text: string): number {
  const t = text.trim().toLowerCase();
  const calc = calcNumber(t);
  if (!Number.isNaN(calc)) return calc;
  if (name === "width" || name === "height" || name === "device-width" || name === "device-height") {
    return mediaLength(t);
  }
  if (name === "aspect-ratio" || name === "device-aspect-ratio") {
    const slash = t.indexOf("/");
    if (slash >= 0) {
      // Either side may be a calc(): `calc(sign(x) * 59) / calc(79 * sign(x))`.
      const num = (s: string): number => {
        const v = Number(s);
        return Number.isNaN(v) ? calcNumber(s) : v;
      };
      const a = num(t.slice(0, slash).trim());
      const b = num(t.slice(slash + 1).trim());
      // A zero denominator is an infinite ratio ("0/0" is read as "1/0"), which every comparison
      // against a finite ratio resolves.
      if (b === 0) return a >= 0 ? Infinity : -Infinity;
      return a / b;
    }
    return Number(t);
  }
  if (name === "resolution" || name === "device-pixel-ratio") {
    const m = /^([-+]?(?:\d+\.?\d*|\.\d+))(dppx|dpcm|dpi|x)?$/.exec(t);
    if (m === null) return NaN;
    const n = Number(m[1]);
    if (m[2] === "dpi") return n / 96;
    if (m[2] === "dpcm") return (n * 2.54) / 96;
    return n;
  }
  return Number(t);
}

function compare(a: number, op: string, b: number): boolean {
  if (Number.isNaN(a) || Number.isNaN(b)) return false;
  // Layout sizes settle on fractions of a pixel; a query compares at the CSS px the author wrote.
  const eps = 1e-6;
  if (op === "<") return a < b - eps;
  if (op === "<=") return a <= b + eps;
  if (op === ">") return a > b + eps;
  if (op === ">=") return a >= b - eps;
  return Math.abs(a - b) <= 0.5;
}

/** The values each keyword feature accepts; a value outside its list makes the query invalid. */
const KEYWORD_VALUES: Record<string, string[]> = {
  orientation: ["portrait", "landscape"],
  hover: ["none", "hover"], "any-hover": ["none", "hover"],
  pointer: ["none", "coarse", "fine"], "any-pointer": ["none", "coarse", "fine"],
  "prefers-color-scheme": ["light", "dark"],
  "prefers-contrast": ["no-preference", "more", "less", "custom"],
  "prefers-reduced-transparency": ["no-preference", "reduce"],
  "prefers-reduced-motion": ["no-preference", "reduce"],
  "prefers-reduced-data": ["no-preference", "reduce"],
  "forced-colors": ["none", "active"],
  "color-gamut": ["srgb", "p3", "rec2020"],
  "dynamic-range": ["standard", "high"],
  "video-dynamic-range": ["standard", "high"],
  scripting: ["none", "initial-only", "enabled"],
  update: ["none", "slow", "fast"],
  "display-mode": ["browser", "fullscreen", "minimal-ui", "standalone", "picture-in-picture",
    "window-controls-overlay", "unframed"],
  "display-state": ["normal", "minimized", "maximized", "fullscreen"],
  resizable: ["true", "false"],
  "inverted-colors": ["none", "inverted"],
  "navigation-controls": ["none", "back-button"],
  scan: ["interlace", "progressive"],
  "overflow-block": ["none", "scroll", "paged"],
  "overflow-inline": ["none", "scroll"],
};

// A media condition evaluates to true (1), false (0) or invalid (-1). A feature name or value
// the syntax doesn't know makes the whole media query invalid, so it matches nothing — not even
// under `not` (Media Queries 4, error handling).
const INVALID = -1;

/** A colon form (`name: value`), with a min-/max- prefix where the name carries one. */
function evalNamed(name: string, value: string): number {
  let feature = name;
  let op = "=";
  if (name.startsWith("min-")) { feature = name.slice(4); op = ">="; }
  else if (name.startsWith("max-")) { feature = name.slice(4); op = "<="; }
  const num = numericFeature(feature);
  if (!Number.isNaN(num)) {
    // A boolean feature with a number of its own is true when it has one: `(color)` on a colour
    // screen, `(grid)` never here.
    if (value.trim() === "" && op === "=") return num !== 0 ? 1 : 0;
    const v = featureNumber(feature, value);
    if (Number.isNaN(v)) return INVALID;
    return compare(num, op, v) ? 1 : 0;
  }
  const word = keywordFeature(feature);
  if (word === null) return INVALID;
  const want = value.trim().toLowerCase();
  // A media feature in a boolean context is true unless it has no value at all.
  if (want === "") return word !== "none" && word !== "no-preference" ? 1 : 0;
  const allowed = KEYWORD_VALUES[feature];
  if (allowed !== undefined && !allowed.includes(want)) return INVALID;
  return word === want ? 1 : 0;
}

/** Splits on a separator that sits outside parentheses. */
function splitTop(text: string, sep: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  const lower = text.toLowerCase();
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (depth === 0 && lower.startsWith(sep, i)) {
      out.push(text.slice(start, i));
      i += sep.length - 1;
      start = i + 1;
    }
  }
  out.push(text.slice(start));
  return out;
}

/** The operators of a range condition, in the order they appear. */
function rangeParts(inner: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (ch === "(") { depth++; continue; }
    if (ch === ")") { depth = Math.max(0, depth - 1); continue; }
    if (depth !== 0) continue;
    const two = inner.slice(i, i + 2);
    if (two === "<=" || two === ">=") {
      out.push(inner.slice(start, i), two);
      i++;
      start = i + 1;
    } else if (ch === "<" || ch === ">" || ch === "=") {
      out.push(inner.slice(start, i), ch);
      start = i + 1;
    }
  }
  out.push(inner.slice(start));
  return out;
}

/** A `( … )` condition: a colon form, a boolean feature, or a range. */
function evalParen(inner: string): number {
  const t = inner.trim();
  const colon = t.indexOf(":");
  if (colon >= 0) return evalNamed(t.slice(0, colon).trim().toLowerCase(), t.slice(colon + 1));
  const parts = rangeParts(t).map((p) => p.trim());
  if (parts.length === 3) {
    const left = parts[0].toLowerCase();
    const op = parts[1];
    const right = parts[2];
    if (!Number.isNaN(numericFeature(left))) {
      const v = featureNumber(left, right);
      return Number.isNaN(v) ? INVALID : compare(numericFeature(left), op, v) ? 1 : 0;
    }
    const fr = right.toLowerCase();
    if (!Number.isNaN(numericFeature(fr))) {
      const v = featureNumber(fr, left);
      return Number.isNaN(v) ? INVALID : compare(v, op, numericFeature(fr)) ? 1 : 0;
    }
    return INVALID;
  }
  if (parts.length === 5) {
    const fr = parts[2].toLowerCase();
    const num = numericFeature(fr);
    if (Number.isNaN(num)) return INVALID;
    const a = featureNumber(fr, parts[0]);
    const b = featureNumber(fr, parts[4]);
    if (Number.isNaN(a) || Number.isNaN(b)) return INVALID;
    return compare(a, parts[1], num) && compare(num, parts[3], b) ? 1 : 0;
  }
  // A boolean feature: true unless it has no value at all.
  return evalNamed(t.toLowerCase(), "");
}

/** One media condition, joined by `and` / `or` and grouped by parentheses. */
function evalCondition(text: string): number {
  const t = text.trim();
  if (t === "") return 1;
  const ors = splitTop(t, " or ");
  if (ors.length > 1) {
    let invalid = false;
    for (const one of ors) {
      const v = evalCondition(one);
      if (v === 1) return 1;
      if (v === INVALID) invalid = true;
    }
    return invalid ? INVALID : 0;
  }
  const ands = splitTop(t, " and ");
  if (ands.length > 1) {
    let invalid = false;
    for (const one of ands) {
      const v = evalCondition(one);
      if (v === 0) return 0;
      if (v === INVALID) invalid = true;
    }
    return invalid ? INVALID : 1;
  }
  // A media condition is a parenthesised condition (or a run of them joined by and/or), so bare
  // text after a type is invalid: "not all and overflow-inline" names no condition at all.
  if (t[0] !== "(" || t[t.length - 1] !== ")") return INVALID;
  const inner = t.slice(1, t.length - 1).trim();
  // A parenthesised group of conditions, as in `((width > 10px) or (height > 10px))`.
  if (inner.startsWith("(")) return evalCondition(inner);
  return evalParen(inner);
}

/** Splits a media query list on the commas that are not inside a condition's parentheses, so
 *  that `(min-width: min(300px, 50vw))` stays one query. */
function splitConditions(query: string): string[] {
  return splitTop(query, ",");
}

/** One comma-separated media query: an optional type, then its conditions. */
function evalQuery(one: string): boolean {
  let q = one.trim();
  let negate = false;
  if (/^not\s+/i.test(q)) { negate = !negate; q = q.slice(4).trim(); }
  if (/^only\s+/i.test(q)) q = q.slice(5).trim();
  // A media type in front of the conditions: screen and all match, print (and anything unknown) not.
  const type = /^([a-z][a-z-]*)(?=\s|$)/i.exec(q);
  if (type !== null && q[0] !== "(") {
    const t = type[1].toLowerCase();
    q = q.slice(type[1].length).trim();
    // `and`, `or`, `not` and `only` are reserved, so a query using one as a type is invalid, and
    // so is `layer`, which the cascade has taken.
    if (t === "and" || t === "or" || t === "not" || t === "only" || t === "layer") return false;
    if (t !== "all" && t !== mediaType) return negate;
    if (q !== "") {
      if (!/^and\s/i.test(q)) return false;
      q = q.slice(3).trim();
    }
  }
  const ok = evalCondition(q);
  if (ok === INVALID) return false;
  return negate ? ok === 0 : ok === 1;
}

/** True when the media query list, a comma-separated list of conditions, matches. */
export function mediaMatches(query: string): boolean {
  for (const q of splitConditions(query)) {
    if (evalQuery(q)) return true;
  }
  return false;
}
