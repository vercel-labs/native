// CSS Counter Styles: an `@counter-style` rule's descriptors, and the counter style they define.
//
// A style is stored as one string in the app's COUNTER_STYLES table, its fields separated by
// FIELD and its lists by ITEM: name, system, the system's argument, the symbols, the additive
// pairs, the ranges, the pad, the fallback, the prefix, the suffix and the two negative signs.
// The runtime parses it back when a marker or a counter() names it. The ten styles list-style-type
// has always had are built in, by name, so a style and a keyword share one lookup.

import { readEscape, readIdent, readString } from "./content.ts";

export const FIELD = "\u0003";
export const ITEM = "\u0004";

export const CS_CYCLIC = 0;
export const CS_FIXED = 1;
export const CS_NUMERIC = 2;
export const CS_ALPHABETIC = 3;
export const CS_SYMBOLIC = 4;
export const CS_ADDITIVE = 5;
export const CS_EXTENDS = 6;

// Which descriptors a rule wrote, so an `extends` style can take the rest from its base.
export const SET_SYSTEM = 1, SET_SYMBOLS = 2, SET_ADDITIVE = 4, SET_RANGE = 8, SET_PAD = 16,
  SET_FALLBACK = 32, SET_PREFIX = 64, SET_SUFFIX = 128, SET_NEGATIVE = 256;
export const ALL_SET = 511;

/** An `@counter-style` rule's descriptors, as parsed. */
export interface CounterStyle {
  name: string;
  system: number;
  /** `fixed`'s first value, or the name `extends` inherits from. */
  systemArg: string;
  symbols: string[];
  additive: { value: number; symbol: string }[];
  /** `range`: sorted [low, high] pairs; an empty list is `auto`. */
  ranges: number[][];
  /** `pad`: the width and the symbol, or null for the initial `0 ""`. */
  padWidth: number;
  padSymbol: string;
  fallback: string;
  prefix: string;
  suffix: string;
  negative: string[];
  /** Which descriptors the rule wrote (see SET_*). */
  set: number;
}

/** CSS-wide keywords a <custom-ident> can't be, and so not a symbol either (CSS Values 4). */
const CSS_WIDE = ["initial", "inherit", "unset", "revert", "revert-layer", "default"];

/** One symbol: a string literal, or an identifier with its escapes decoded. */
function readSymbol(s: string, i: number): [string, number] | null {
  const ch = s[i];
  if (ch === undefined) return null;
  if (ch === '"' || ch === "'") return readString(s, i);
  const id = readIdent(s, i);
  if (id === null || CSS_WIDE.indexOf(id[0].toLowerCase()) >= 0) return null;
  return id;
}

/** The symbols of a `symbols` descriptor, which are separated by spaces. */
function readSymbols(s: string): string[] | string {
  const out: string[] = [];
  let i = 0;
  while (i < s.length) {
    while (i < s.length && /\s/.test(s[i])) i++;
    if (i >= s.length) break;
    const sym = readSymbol(s, i);
    if (sym === null) return `unreadable symbol in '${s}'`;
    out.push(sym[0]);
    i = sym[1];
  }
  return out;
}

/** Splits on top-level commas. */
function commaParts(s: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let cur = "";
  for (const ch of s) {
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (ch === "," && depth === 0) {
      out.push(cur.trim());
      cur = "";
    } else cur += ch;
  }
  if (cur.trim() !== "") out.push(cur.trim());
  return out;
}

const SYSTEMS: Record<string, number> = {
  cyclic: CS_CYCLIC, fixed: CS_FIXED, numeric: CS_NUMERIC, alphabetic: CS_ALPHABETIC,
  symbolic: CS_SYMBOLIC, additive: CS_ADDITIVE, extends: CS_EXTENDS,
};

/**
 * Parses one `@counter-style` block. The body is the rule's declarations; returns the style or
 * why the rule can't be one.
 */
export function parseCounterStyle(name: string, body: string, warn?: (why: string) => void,
  seen?: { prop: string; text: string }[]): CounterStyle | string {
  const note = (why: string): void => {
    if (warn !== undefined) warn(`in @counter-style ${name}: ${why}; descriptor ignored`);
  };
  const style: CounterStyle = {
    name, system: CS_NUMERIC, systemArg: "", symbols: [], additive: [], ranges: [],
    padWidth: 0, padSymbol: "", fallback: "decimal", prefix: "", suffix: ". ", negative: ["-", ""],
    set: 0,
  };
  let sawSystem = "";
  let sawSymbols = false;
  for (const chunk of body.split(";")) {
    const colon = chunk.indexOf(":");
    if (colon < 0) continue;
    const prop = chunk.slice(0, colon).trim().toLowerCase();
    const value = chunk.slice(colon + 1).trim();
    if (value === "") continue;
    switch (prop) {
      case "system": {
        const parts = value.split(/\s+/);
        const token = parts[0].toLowerCase();
        const sys = SYSTEMS[token];
        // An unknown system drops the descriptor, not the rule, as in a browser.
        if (sys === undefined) {
          // `system` also takes a counter style's name: the new style takes that style's system
          // and, unless it has symbols of its own, its symbols.
          const base = BUILTIN_STYLES.find((b) => b.name === token);
          if (base === undefined) {
            note(`unknown system '${parts[0]}'`);
            break;
          }
          style.system = SYSTEMS[base.system] ?? CS_NUMERIC;
          style.systemArg = base.systemArg;
          style.set |= SET_SYSTEM;
          if (style.symbols.length === 0) style.symbols = base.symbols.slice();
          sawSystem = token;
          seen?.push({ prop, text: value });
          break;
        }
        style.system = sys;
        style.set |= SET_SYSTEM;
        sawSystem = parts[0].toLowerCase();
        if (sys === CS_FIXED) {
          style.systemArg = parts[1] !== undefined && /^[-+]?\d+$/.test(parts[1]) ? parts[1] : "1";
        } else if (sys === CS_EXTENDS) {
          const id = parts[1] === undefined ? null : readIdent(parts[1], 0);
          if (id === null || CSS_WIDE.indexOf(id[0].toLowerCase()) >= 0) {
            note(`'extends' needs a counter style name`);
            break;
          }
          style.systemArg = id[0];
        }
        seen?.push({ prop, text: value });
        break;
      }
      case "symbols": {
        if (value.toLowerCase() === "none") {
          sawSymbols = true;
          break;
        }
        const syms = readSymbols(value);
        if (typeof syms === "string") {
          note(syms);
          break;
        }
        style.symbols = syms;
        style.set |= SET_SYMBOLS;
        sawSymbols = true;
        seen?.push({ prop, text: value });
        break;
      }
      case "additive-symbols": {
        if (value.toLowerCase() === "none") break;
        for (const part of commaParts(value)) {
          const m = /^([-+]?\d+)\s+([\s\S]+)$/.exec(part);
          if (m === null) {
            note(`unreadable additive-symbols entry '${part}'`);
            continue;
          }
          const sym = readSymbol(m[2], 0);
          if (sym === null || sym[1] !== m[2].length) {
            note(`unreadable symbol '${m[2]}'`);
            continue;
          }
          style.additive.push({ value: parseInt(m[1], 10), symbol: sym[0] });
        }
        // A browser wants the pairs in descending order of value; the formatter walks them down.
        style.additive.sort((a, b) => b.value - a.value);
        style.set |= SET_ADDITIVE;
        seen?.push({ prop, text: value });
        break;
      }
      case "range": {
        if (value.toLowerCase() === "auto") break;
        for (const part of commaParts(value)) {
          const m = /^([-+]?\d+|infinite)\s*(?:to\s*([-+]?\d+|infinite))?$/.exec(part);
          if (m === null) {
            note(`unreadable range '${part}'`);
            continue;
          }
          const lo = m[1] === "-infinite" ? -Infinity : m[1] === "infinite" ? Infinity : parseInt(m[1], 10);
          const hi = m[2] === undefined ? lo : m[2] === "infinite" ? Infinity : m[2] === "-infinite" ? -Infinity : parseInt(m[2], 10);
          style.ranges.push([lo, hi]);
        }
        if (style.ranges.length > 0) {
          style.set |= SET_RANGE;
          seen?.push({ prop, text: value });
        }
        break;
      }
      case "pad": {
        const m = /^(\d+)\s+([\s\S]+)$/.exec(value);
        if (m === null) {
          note(`unreadable pad '${value}'`);
          break;
        }
        const sym = readSymbol(m[2], 0);
        if (sym === null || sym[1] !== m[2].length) {
          note(`unreadable pad symbol '${m[2]}'`);
          break;
        }
        style.padWidth = parseInt(m[1], 10);
        style.padSymbol = sym[0];
        style.set |= SET_PAD;
        seen?.push({ prop, text: value });
        break;
      }
      case "fallback": {
        const id = readIdent(value, 0);
        if (id === null) {
          note(`unreadable fallback '${value}'`);
          break;
        }
        if (CSS_WIDE.indexOf(id[0].toLowerCase()) >= 0) {
          note(`'${value}' is not a counter style name`);
          break;
        }
        style.fallback = id[0];
        style.set |= SET_FALLBACK;
        seen?.push({ prop, text: value });
        break;
      }
      case "prefix":
      case "suffix": {
        const sym = readSymbol(value, 0);
        if (sym === null) {
          note(`unreadable ${prop} '${value}'`);
          break;
        }
        if (prop === "prefix") style.prefix = sym[0];
        else style.suffix = sym[0];
        style.set |= prop === "prefix" ? SET_PREFIX : SET_SUFFIX;
        seen?.push({ prop, text: value });
        break;
      }
      case "negative": {
        const first = readSymbol(value, 0);
        if (first === null) {
          note(`unreadable negative '${value}'`);
          break;
        }
        let second = "";
        let i = first[1];
        while (i < value.length && /\s/.test(value[i])) i++;
        if (i < value.length) {
          const rest = readSymbol(value, i);
          if (rest !== null) second = rest[0];
        }
        style.negative = [first[0], second];
        style.set |= SET_NEGATIVE;
        seen?.push({ prop, text: value });
        break;
      }
      case "speak-as": {
        // Kept for the computed value only; nothing announces anything here. Its values are the
        // three keywords and a counter style's name.
        const id = readIdent(value, 0);
        const rest = id === null ? value : value.slice(id[1]).trim();
        if (id !== null && rest === "" && CSS_WIDE.indexOf(id[0].toLowerCase()) < 0) {
          seen?.push({ prop, text: value });
        }
        break;
      }
      default:
        note(`unknown descriptor '${prop}'`);
        break;
    }
  }
  if (style.system === CS_NUMERIC && style.symbols.length === 0 && sawSystem === "" && !sawSymbols) {
    // A rule with no system and no symbols is a numeric style with the decimal digits, which is
    // what `system: numeric` defaults to.
    style.symbols = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];
  }
  if ((style.system === CS_NUMERIC || style.system === CS_ALPHABETIC || style.system === CS_SYMBOLIC ||
    style.system === CS_CYCLIC || style.system === CS_FIXED) && style.symbols.length === 0) {
    return `@counter-style ${name} has no symbols`;
  }
  if (style.system === CS_ADDITIVE && style.additive.length === 0) {
    return `@counter-style ${name} is additive but has no additive-symbols`;
  }
  return style;
}

/** A style as the row the runtime reads back. */
export function encodeCounterStyle(style: CounterStyle): string {
  const systems = ["cyclic", "fixed", "numeric", "alphabetic", "symbolic", "additive", "extends"];
  const f: string[] = [];
  f.push(style.name);
  f.push(systems[style.system] ?? "numeric");
  f.push(style.systemArg);
  f.push(style.symbols.join(ITEM));
  f.push(style.additive.map((a) => `${a.value}${ITEM}${a.symbol}`).join(FIELD));
  f.push(style.ranges.map((r) => `${r[0]}${ITEM}${r[1]}`).join(FIELD));
  f.push(`${style.padWidth}${ITEM}${style.padSymbol}`);
  f.push(style.fallback);
  f.push(style.prefix);
  f.push(style.suffix);
  f.push(style.negative[0] ?? "");
  f.push(style.negative[1] ?? "");
  f.push(String(style.set));
  return f.join(FIELD);
}

/** A style as the runtime reads it back, for the format below. */
export interface CounterStyleSpec {
  name: string;
  system: string;
  systemArg: string;
  symbols: string[];
  additive: { value: number; symbol: string }[];
  ranges: number[][];
  padWidth: number;
  padSymbol: string;
  fallback: string;
  prefix: string;
  suffix: string;
  negative: string[];
  /** Which descriptors the row wrote (see SET_*). */
  set: number;
}

/** Reads back a row `encodeCounterStyle` wrote. */
export function decodeCounterStyle(encoded: string): CounterStyleSpec | null {
  const f = encoded.split(FIELD);
  if (f.length < 12) return null;
  const pad = f[6].split(ITEM);
  return {
    name: f[0],
    system: f[1],
    systemArg: f[2],
    symbols: f[3] === "" ? [] : f[3].split(ITEM),
    additive: f[4] === "" ? [] : f[4].split(FIELD).map((p) => {
      const it = p.split(ITEM);
      return { value: parseInt(it[0], 10), symbol: it[1] ?? "" };
    }),
    ranges: f[5] === "" ? [] : f[5].split(FIELD).map((p) => {
      const it = p.split(ITEM);
      return [Number(it[0]), Number(it[1])];
    }),
    padWidth: parseInt(pad[0] ?? "0", 10),
    padSymbol: pad[1] ?? "",
    fallback: f[7],
    prefix: f[8],
    suffix: f[9],
    negative: [f[10], f[11]],
    set: f[12] === undefined ? ALL_SET : parseInt(f[12], 10),
  };
}

/** Looks a style up by name, for `fallback` and `extends`. */
export type StyleLookup = (name: string) => CounterStyleSpec | null;

const DECIMAL_DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];

/** `n` in a positional system whose symbols are its digits. */
function positional(symbols: string[], n: number): string {
  if (symbols.length < 2) return "";
  if (n === 0) return symbols[0];
  let s = "";
  let v = n;
  while (v > 0) {
    s = symbols[v % symbols.length] + s;
    v = Math.floor(v / symbols.length);
  }
  return s;
}

/** `n` in a bijective system whose symbols are its digits (a, b … z, aa …). */
function bijective(symbols: string[], n: number): string {
  const len = symbols.length;
  if (len === 0) return "";
  let s = "";
  let v = n;
  while (v > 0) {
    const r = (v - 1) % len;
    s = symbols[r] + s;
    v = Math.floor((v - 1) / len);
  }
  return s;
}

/** `value` modulo `len`, never negative: cyclic systems count through 0 and below too. */
function mod(value: number, len: number): number {
  return ((value % len) + len) % len;
}

/** The digits of `value` in a style, before its pad and sign. */
function digitsOf(spec: CounterStyleSpec, value: number, lookup: StyleLookup): string {
  const len = spec.symbols.length;
  switch (spec.system) {
    case "cyclic":
      if (len === 0) return "";
      return spec.symbols[mod(value - 1, len)];
    case "fixed": {
      const first = parseInt(spec.systemArg, 10);
      const at = value - (Number.isNaN(first) ? 1 : first);
      if (at < 0 || at >= len) return "";
      return spec.symbols[at];
    }
    case "numeric":
      return positional(spec.symbols.length > 0 ? spec.symbols : DECIMAL_DIGITS, value);
    case "alphabetic":
      return bijective(spec.symbols.length > 0 ? spec.symbols : DECIMAL_DIGITS, value);
    case "symbolic": {
      if (len === 0) return "";
      const symbol = spec.symbols[mod(value - 1, len)];
      const times = Math.floor((value - 1) / len) + 1;
      let s = "";
      for (let k = 0; k < times; k++) s += symbol;
      return s;
    }
    case "additive": {
      let rest = value;
      let s = "";
      for (const a of spec.additive) {
        if (a.value <= 0) continue;
        while (rest >= a.value) {
          s += a.symbol;
          rest -= a.value;
        }
      }
      if (rest !== 0) return "";
      if (s === "" && value === 0) {
        for (const a of spec.additive) if (a.value === 0) return a.symbol;
      }
      return s;
    }
    case "extends": {
      const base = lookup(spec.systemArg);
      if (base === null) return positional(DECIMAL_DIGITS, value);
      return digitsOf(base, value, lookup);
    }
    default:
      return positional(DECIMAL_DIGITS, value);
  }
}

/** The systems that put the negative descriptor's signs around a negative value (§3.2). */
function usesNegativeSign(spec: CounterStyleSpec): boolean {
  return spec.system === "symbolic" || spec.system === "alphabetic" ||
    spec.system === "numeric" || spec.system === "additive";
}

/** The ranges a style covers when its `range` is auto (§3.5). */
function autoRanges(spec: CounterStyleSpec): number[][] {
  switch (spec.system) {
    case "fixed": {
      const first = parseInt(spec.systemArg, 10);
      const at = Number.isNaN(first) ? 1 : first;
      return [[at, at + Math.max(0, spec.symbols.length - 1)]];
    }
    case "alphabetic":
    case "symbolic":
      return [[1, Infinity]];
    case "additive":
      return [[0, Infinity]];
    default:
      return [[-Infinity, Infinity]];
  }
}

function inRange(spec: CounterStyleSpec, value: number): boolean {
  const ranges = spec.ranges.length > 0 ? spec.ranges : autoRanges(spec);
  return ranges.some((r) => value >= r[0] && value <= r[1]);
}

/**
 * A counter's representation, as `counter()` and `counters()` return it (CSS Counter Styles 3
 * §2.2): the value in the style's system, padded, with the negative signs when the system uses
 * them, or the fallback style's representation for a value the style doesn't cover. The style's
 * prefix and suffix are not part of it; only the ::marker text they help build uses those.
 */
export function formatCounter(spec: CounterStyleSpec, value: number, lookup: StyleLookup): string {
  if (!inRange(spec, value)) {
    const fb = lookup(spec.fallback);
    if (fb !== null) return formatCounter(fb, value, lookup);
    return String(value);
  }
  const negated = value < 0 && usesNegativeSign(spec);
  let body = digitsOf(spec, negated ? -value : value, lookup);
  if (body === "" && spec.system !== "numeric") {
    const fb = lookup(spec.fallback);
    if (fb !== null) return formatCounter(fb, value, lookup);
    return String(value);
  }
  if (spec.padWidth > body.length && spec.padSymbol !== "") {
    let pad = "";
    for (let k = body.length; k < spec.padWidth; k++) pad += spec.padSymbol;
    body = pad + body;
  }
  if (!negated) return body;
  const signs = spec.negative;
  return (signs[0] ?? "-") + body + (signs[1] ?? "");
}

/** The text an ::marker shows for `value`: the style's prefix and suffix around its representation. */
export function markerCounterText(spec: CounterStyleSpec, value: number, lookup: StyleLookup): string {
  return spec.prefix + formatCounter(spec, value, lookup) + spec.suffix;
}

/**
 * A style that extends another, with the descriptors its rule left out filled in from the base.
 * Returns null when the base is unknown, which leaves the style undefined (as in a browser).
 */
export function resolveCounterStyle(spec: CounterStyleSpec, lookup: StyleLookup, seen?: Set<string>): CounterStyleSpec | null {
  if (spec.system !== "extends") return spec;
  const guard = seen ?? new Set<string>();
  if (guard.has(spec.name)) return null;
  guard.add(spec.name);
  const base = lookup(spec.systemArg);
  if (base === null) return null;
  const resolved = resolveCounterStyle(base, lookup, guard);
  if (resolved === null) return null;
  const out: CounterStyleSpec = { ...resolved, name: spec.name, set: spec.set };
  if (spec.set & SET_SYMBOLS) out.symbols = spec.symbols;
  if (spec.set & SET_ADDITIVE) out.additive = spec.additive;
  if (spec.set & SET_RANGE) out.ranges = spec.ranges;
  if (spec.set & SET_PAD) {
    out.padWidth = spec.padWidth;
    out.padSymbol = spec.padSymbol;
  }
  if (spec.set & SET_FALLBACK) out.fallback = spec.fallback;
  if (spec.set & SET_PREFIX) out.prefix = spec.prefix;
  if (spec.set & SET_SUFFIX) out.suffix = spec.suffix;
  if (spec.set & SET_NEGATIVE) out.negative = spec.negative;
  return out;
}

/** A spec made from its parts, for the styles built into the engine. */
function builtin(name: string, system: string, symbols: string[], extra: Partial<CounterStyleSpec> = {}): CounterStyleSpec {
  return {
    name, system, systemArg: "", symbols, additive: [], ranges: [], padWidth: 0, padSymbol: "",
    fallback: "decimal", prefix: "", suffix: ". ", negative: ["-", ""], set: ALL_SET, ...extra,
  };
}

/**
 * The counter styles every browser has: the ten `list-style-type` keywords and the predefined
 * styles of CSS Counter Styles 3 §7, with the descriptors the spec gives them.
 */
export const BUILTIN_STYLES: CounterStyleSpec[] = [
  builtin("triangle", "cyclic", ["‣"], { suffix: " " }),
  builtin("box-corner", "fixed", ["◰", "◳", "◲", "◱"], { suffix: ": " }),
  builtin("footnote", "symbolic", ["*", "⁑", "†", "‡"], { suffix: " " }),
  builtin("upper-alpha-legal", "symbolic", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]),
  builtin("go", "alphabetic", ["url(white.svg)", "url(black.svg)"], { suffix: " " }),
  builtin("trinary", "numeric", ["0", "1", "2"]),
  builtin("dice", "additive", [], { additive: [{ value: 6, symbol: "⚅" }, { value: 5, symbol: "⚄" }, { value: 4, symbol: "⚃" }, { value: 3, symbol: "⚂" }, { value: 2, symbol: "⚁" }, { value: 1, symbol: "⚀" }], suffix: " " }),
  builtin("decimal-paren", "numeric", ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], { suffix: ") " }),
  builtin("circled-lower-latin", "alphabetic", ["ⓐ", "ⓑ", "ⓒ", "ⓓ", "ⓔ", "ⓕ", "ⓖ", "ⓗ", "ⓘ", "ⓙ", "ⓚ", "ⓛ", "ⓜ", "ⓝ", "ⓞ", "ⓟ", "ⓠ", "ⓡ", "ⓢ", "ⓣ", "ⓤ", "ⓥ", "ⓦ", "ⓧ", "ⓨ", "ⓩ"], { suffix: " " }),
  builtin("decimal", "numeric", ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]),
  builtin("decimal-leading-zero", "numeric", ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], { padWidth: 2, padSymbol: "0" }),
  builtin("arabic-indic", "numeric", ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"]),
  builtin("armenian", "additive", [], { additive: [{ value: 9000, symbol: "Ք" }, { value: 8000, symbol: "Փ" }, { value: 7000, symbol: "Ւ" }, { value: 6000, symbol: "Ց" }, { value: 5000, symbol: "Ր" }, { value: 4000, symbol: "Տ" }, { value: 3000, symbol: "Վ" }, { value: 2000, symbol: "Ս" }, { value: 1000, symbol: "Ռ" }, { value: 900, symbol: "Ջ" }, { value: 800, symbol: "Պ" }, { value: 700, symbol: "Չ" }, { value: 600, symbol: "Ո" }, { value: 500, symbol: "Շ" }, { value: 400, symbol: "Ն" }, { value: 300, symbol: "Յ" }, { value: 200, symbol: "Մ" }, { value: 100, symbol: "Ճ" }, { value: 90, symbol: "Ղ" }, { value: 80, symbol: "Ձ" }, { value: 70, symbol: "Հ" }, { value: 60, symbol: "Կ" }, { value: 50, symbol: "Ծ" }, { value: 40, symbol: "Խ" }, { value: 30, symbol: "Լ" }, { value: 20, symbol: "Ի" }, { value: 10, symbol: "Ժ" }, { value: 9, symbol: "Թ" }, { value: 8, symbol: "Ը" }, { value: 7, symbol: "Է" }, { value: 6, symbol: "Զ" }, { value: 5, symbol: "Ե" }, { value: 4, symbol: "Դ" }, { value: 3, symbol: "Գ" }, { value: 2, symbol: "Բ" }, { value: 1, symbol: "Ա" }], ranges: [[1, 9999]] }),
  builtin("upper-armenian", "additive", [], { additive: [{ value: 9000, symbol: "Ք" }, { value: 8000, symbol: "Փ" }, { value: 7000, symbol: "Ւ" }, { value: 6000, symbol: "Ց" }, { value: 5000, symbol: "Ր" }, { value: 4000, symbol: "Տ" }, { value: 3000, symbol: "Վ" }, { value: 2000, symbol: "Ս" }, { value: 1000, symbol: "Ռ" }, { value: 900, symbol: "Ջ" }, { value: 800, symbol: "Պ" }, { value: 700, symbol: "Չ" }, { value: 600, symbol: "Ո" }, { value: 500, symbol: "Շ" }, { value: 400, symbol: "Ն" }, { value: 300, symbol: "Յ" }, { value: 200, symbol: "Մ" }, { value: 100, symbol: "Ճ" }, { value: 90, symbol: "Ղ" }, { value: 80, symbol: "Ձ" }, { value: 70, symbol: "Հ" }, { value: 60, symbol: "Կ" }, { value: 50, symbol: "Ծ" }, { value: 40, symbol: "Խ" }, { value: 30, symbol: "Լ" }, { value: 20, symbol: "Ի" }, { value: 10, symbol: "Ժ" }, { value: 9, symbol: "Թ" }, { value: 8, symbol: "Ը" }, { value: 7, symbol: "Է" }, { value: 6, symbol: "Զ" }, { value: 5, symbol: "Ե" }, { value: 4, symbol: "Դ" }, { value: 3, symbol: "Գ" }, { value: 2, symbol: "Բ" }, { value: 1, symbol: "Ա" }], ranges: [[1, 9999]] }),
  builtin("lower-armenian", "additive", [], { additive: [{ value: 9000, symbol: "ք" }, { value: 8000, symbol: "փ" }, { value: 7000, symbol: "ւ" }, { value: 6000, symbol: "ց" }, { value: 5000, symbol: "ր" }, { value: 4000, symbol: "տ" }, { value: 3000, symbol: "վ" }, { value: 2000, symbol: "ս" }, { value: 1000, symbol: "ռ" }, { value: 900, symbol: "ջ" }, { value: 800, symbol: "պ" }, { value: 700, symbol: "չ" }, { value: 600, symbol: "ո" }, { value: 500, symbol: "շ" }, { value: 400, symbol: "ն" }, { value: 300, symbol: "յ" }, { value: 200, symbol: "մ" }, { value: 100, symbol: "ճ" }, { value: 90, symbol: "ղ" }, { value: 80, symbol: "ձ" }, { value: 70, symbol: "հ" }, { value: 60, symbol: "կ" }, { value: 50, symbol: "ծ" }, { value: 40, symbol: "խ" }, { value: 30, symbol: "լ" }, { value: 20, symbol: "ի" }, { value: 10, symbol: "ժ" }, { value: 9, symbol: "թ" }, { value: 8, symbol: "ը" }, { value: 7, symbol: "է" }, { value: 6, symbol: "զ" }, { value: 5, symbol: "ե" }, { value: 4, symbol: "դ" }, { value: 3, symbol: "գ" }, { value: 2, symbol: "բ" }, { value: 1, symbol: "ա" }], ranges: [[1, 9999]] }),
  builtin("bengali", "numeric", ["০", "১", "২", "৩", "৪", "৫", "৬", "৭", "৮", "৯"]),
  builtin("cambodian", "numeric", ["០", "១", "២", "៣", "៤", "៥", "៦", "៧", "៨", "៩"]),
  builtin("khmer", "numeric", ["០", "១", "២", "៣", "៤", "៥", "៦", "៧", "៨", "៩"]),
  builtin("cjk-decimal", "numeric", ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"], { ranges: [[0, Infinity]], suffix: "、" }),
  builtin("devanagari", "numeric", ["०", "१", "२", "३", "४", "५", "६", "७", "८", "९"]),
  builtin("georgian", "additive", [], { additive: [{ value: 10000, symbol: "ჵ" }, { value: 9000, symbol: "ჰ" }, { value: 8000, symbol: "ჯ" }, { value: 7000, symbol: "ჴ" }, { value: 6000, symbol: "ხ" }, { value: 5000, symbol: "ჭ" }, { value: 4000, symbol: "წ" }, { value: 3000, symbol: "ძ" }, { value: 2000, symbol: "ც" }, { value: 1000, symbol: "ჩ" }, { value: 900, symbol: "შ" }, { value: 800, symbol: "ყ" }, { value: 700, symbol: "ღ" }, { value: 600, symbol: "ქ" }, { value: 500, symbol: "ფ" }, { value: 400, symbol: "ჳ" }, { value: 300, symbol: "ტ" }, { value: 200, symbol: "ს" }, { value: 100, symbol: "რ" }, { value: 90, symbol: "ჟ" }, { value: 80, symbol: "პ" }, { value: 70, symbol: "ო" }, { value: 60, symbol: "ჲ" }, { value: 50, symbol: "ნ" }, { value: 40, symbol: "მ" }, { value: 30, symbol: "ლ" }, { value: 20, symbol: "კ" }, { value: 10, symbol: "ი" }, { value: 9, symbol: "თ" }, { value: 8, symbol: "ჱ" }, { value: 7, symbol: "ზ" }, { value: 6, symbol: "ვ" }, { value: 5, symbol: "ე" }, { value: 4, symbol: "დ" }, { value: 3, symbol: "გ" }, { value: 2, symbol: "ბ" }, { value: 1, symbol: "ა" }], ranges: [[1, 19999]] }),
  builtin("gujarati", "numeric", ["૦", "૧", "૨", "૩", "૪", "૫", "૬", "૭", "૮", "૯"]),
  builtin("gurmukhi", "numeric", ["੦", "੧", "੨", "੩", "੪", "੫", "੬", "੭", "੮", "੯"]),
  builtin("hebrew", "additive", [], { additive: [{ value: 10000, symbol: "י׳" }, { value: 9000, symbol: "ט׳" }, { value: 8000, symbol: "ח׳" }, { value: 7000, symbol: "ז׳" }, { value: 6000, symbol: "ו׳" }, { value: 5000, symbol: "ה׳" }, { value: 4000, symbol: "ד׳" }, { value: 3000, symbol: "ג׳" }, { value: 2000, symbol: "ב׳" }, { value: 1000, symbol: "א׳" }, { value: 400, symbol: "ת" }, { value: 300, symbol: "ש" }, { value: 200, symbol: "ר" }, { value: 100, symbol: "ק" }, { value: 90, symbol: "צ" }, { value: 80, symbol: "פ" }, { value: 70, symbol: "ע" }, { value: 60, symbol: "ס" }, { value: 50, symbol: "נ" }, { value: 40, symbol: "מ" }, { value: 30, symbol: "ל" }, { value: 20, symbol: "כ" }, { value: 19, symbol: "יט" }, { value: 18, symbol: "יח" }, { value: 17, symbol: "יז" }, { value: 16, symbol: "טז" }, { value: 15, symbol: "טו" }, { value: 10, symbol: "י" }, { value: 9, symbol: "ט" }, { value: 8, symbol: "ח" }, { value: 7, symbol: "ז" }, { value: 6, symbol: "ו" }, { value: 5, symbol: "ה" }, { value: 4, symbol: "ד" }, { value: 3, symbol: "ג" }, { value: 2, symbol: "ב" }, { value: 1, symbol: "א" }], ranges: [[1, 10999]] }),
  builtin("kannada", "numeric", ["೦", "೧", "೨", "೩", "೪", "೫", "೬", "೭", "೮", "೯"]),
  builtin("lao", "numeric", ["໐", "໑", "໒", "໓", "໔", "໕", "໖", "໗", "໘", "໙"]),
  builtin("malayalam", "numeric", ["൦", "൧", "൨", "൩", "൪", "൫", "൬", "൭", "൮", "൯"]),
  builtin("mongolian", "numeric", ["᠐", "᠑", "᠒", "᠓", "᠔", "᠕", "᠖", "᠗", "᠘", "᠙"]),
  builtin("myanmar", "numeric", ["၀", "၁", "၂", "၃", "၄", "၅", "၆", "၇", "၈", "၉"]),
  builtin("oriya", "numeric", ["୦", "୧", "୨", "୩", "୪", "୫", "୬", "୭", "୮", "୯"]),
  builtin("persian", "numeric", ["۰", "۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹"]),
  builtin("lower-roman", "additive", [], { additive: [{ value: 1000, symbol: "m" }, { value: 900, symbol: "cm" }, { value: 500, symbol: "d" }, { value: 400, symbol: "cd" }, { value: 100, symbol: "c" }, { value: 90, symbol: "xc" }, { value: 50, symbol: "l" }, { value: 40, symbol: "xl" }, { value: 10, symbol: "x" }, { value: 9, symbol: "ix" }, { value: 5, symbol: "v" }, { value: 4, symbol: "iv" }, { value: 1, symbol: "i" }], ranges: [[1, 3999]] }),
  builtin("upper-roman", "additive", [], { additive: [{ value: 1000, symbol: "M" }, { value: 900, symbol: "CM" }, { value: 500, symbol: "D" }, { value: 400, symbol: "CD" }, { value: 100, symbol: "C" }, { value: 90, symbol: "XC" }, { value: 50, symbol: "L" }, { value: 40, symbol: "XL" }, { value: 10, symbol: "X" }, { value: 9, symbol: "IX" }, { value: 5, symbol: "V" }, { value: 4, symbol: "IV" }, { value: 1, symbol: "I" }], ranges: [[1, 3999]] }),
  builtin("tamil", "numeric", ["௦", "௧", "௨", "௩", "௪", "௫", "௬", "௭", "௮", "௯"]),
  builtin("telugu", "numeric", ["౦", "౧", "౨", "౩", "౪", "౫", "౬", "౭", "౮", "౯"]),
  builtin("thai", "numeric", ["๐", "๑", "๒", "๓", "๔", "๕", "๖", "๗", "๘", "๙"]),
  builtin("tibetan", "numeric", ["༠", "༡", "༢", "༣", "༤", "༥", "༦", "༧", "༨", "༩"]),
  builtin("lower-alpha", "alphabetic", ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"]),
  builtin("lower-latin", "alphabetic", ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"]),
  builtin("upper-alpha", "alphabetic", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]),
  builtin("upper-latin", "alphabetic", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]),
  builtin("lower-greek", "alphabetic", ["α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ", "ν", "ξ", "ο", "π", "ρ", "σ", "τ", "υ", "φ", "χ", "ψ", "ω"]),
  builtin("hiragana", "alphabetic", ["あ", "い", "う", "え", "お", "か", "き", "く", "け", "こ", "さ", "し", "す", "せ", "そ", "た", "ち", "つ", "て", "と", "な", "に", "ぬ", "ね", "の", "は", "ひ", "ふ", "へ", "ほ", "ま", "み", "む", "め", "も", "や", "ゆ", "よ", "ら", "り", "る", "れ", "ろ", "わ", "ゐ", "ゑ", "を", "ん"], { suffix: "、" }),
  builtin("hiragana-iroha", "alphabetic", ["い", "ろ", "は", "に", "ほ", "へ", "と", "ち", "り", "ぬ", "る", "を", "わ", "か", "よ", "た", "れ", "そ", "つ", "ね", "な", "ら", "む", "う", "ゐ", "の", "お", "く", "や", "ま", "け", "ふ", "こ", "え", "て", "あ", "さ", "き", "ゆ", "め", "み", "し", "ゑ", "ひ", "も", "せ", "す"], { suffix: "、" }),
  builtin("katakana", "alphabetic", ["ア", "イ", "ウ", "エ", "オ", "カ", "キ", "ク", "ケ", "コ", "サ", "シ", "ス", "セ", "ソ", "タ", "チ", "ツ", "テ", "ト", "ナ", "ニ", "ヌ", "ネ", "ノ", "ハ", "ヒ", "フ", "ヘ", "ホ", "マ", "ミ", "ム", "メ", "モ", "ヤ", "ユ", "ヨ", "ラ", "リ", "ル", "レ", "ロ", "ワ", "ヰ", "ヱ", "ヲ", "ン"], { suffix: "、" }),
  builtin("katakana-iroha", "alphabetic", ["イ", "ロ", "ハ", "ニ", "ホ", "ヘ", "ト", "チ", "リ", "ヌ", "ル", "ヲ", "ワ", "カ", "ヨ", "タ", "レ", "ソ", "ツ", "ネ", "ナ", "ラ", "ム", "ウ", "ヰ", "ノ", "オ", "ク", "ヤ", "マ", "ケ", "フ", "コ", "エ", "テ", "ア", "サ", "キ", "ユ", "メ", "ミ", "シ", "ヱ", "ヒ", "モ", "セ", "ス"], { suffix: "、" }),
  builtin("disc", "cyclic", ["•"], { suffix: " " }),
  builtin("circle", "cyclic", ["◦"], { suffix: " " }),
  builtin("square", "cyclic", ["▪"], { suffix: " " }),
  // The spec leaves the glyphs to the UA: a down-pointing triangle for open and a right-pointing
  // one for closed in a horizontal line (the mirror and the vertical forms are not turned yet).
  builtin("disclosure-open", "cyclic", ["\u25BE"], { suffix: " " }),
  builtin("disclosure-closed", "cyclic", ["\u25B8"], { suffix: " " }),
  builtin("cjk-earthly-branch", "fixed", ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"], { fallback: "cjk-decimal", suffix: "、" }),
  builtin("cjk-heavenly-stem", "fixed", ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"], { fallback: "cjk-decimal", suffix: "、" }),
  builtin("japanese", "additive", [], { additive: [{ value: 9000, symbol: "九千" }, { value: 8000, symbol: "八千" }, { value: 7000, symbol: "七千" }, { value: 6000, symbol: "六千" }, { value: 5000, symbol: "五千" }, { value: 4000, symbol: "四千" }, { value: 3000, symbol: "三千" }, { value: 2000, symbol: "二千" }, { value: 1000, symbol: "千" }, { value: 900, symbol: "九百" }, { value: 800, symbol: "八百" }, { value: 700, symbol: "七百" }, { value: 600, symbol: "六百" }, { value: 500, symbol: "五百" }, { value: 400, symbol: "四百" }, { value: 300, symbol: "三百" }, { value: 200, symbol: "二百" }, { value: 100, symbol: "百" }, { value: 90, symbol: "九十" }, { value: 80, symbol: "八十" }, { value: 70, symbol: "七十" }, { value: 60, symbol: "六十" }, { value: 50, symbol: "五十" }, { value: 40, symbol: "四十" }, { value: 30, symbol: "三十" }, { value: 20, symbol: "二十" }, { value: 10, symbol: "十" }, { value: 9, symbol: "九" }, { value: 8, symbol: "八" }, { value: 7, symbol: "七" }, { value: 6, symbol: "六" }, { value: 5, symbol: "五" }, { value: 4, symbol: "四" }, { value: 3, symbol: "三" }, { value: 2, symbol: "二" }, { value: 1, symbol: "一" }, { value: 0, symbol: "〇" }], ranges: [[-9999, 9999]], fallback: "cjk-decimal", suffix: "、", negative: ["マイナス"] }),
  builtin("japanese-formal", "additive", [], { additive: [{ value: 9000, symbol: "九阡" }, { value: 8000, symbol: "八阡" }, { value: 7000, symbol: "七阡" }, { value: 6000, symbol: "六阡" }, { value: 5000, symbol: "伍阡" }, { value: 4000, symbol: "四阡" }, { value: 3000, symbol: "参阡" }, { value: 2000, symbol: "弐阡" }, { value: 1000, symbol: "壱阡" }, { value: 900, symbol: "九百" }, { value: 800, symbol: "八百" }, { value: 700, symbol: "七百" }, { value: 600, symbol: "六百" }, { value: 500, symbol: "伍百" }, { value: 400, symbol: "四百" }, { value: 300, symbol: "参百" }, { value: 200, symbol: "弐百" }, { value: 100, symbol: "壱百" }, { value: 90, symbol: "九拾" }, { value: 80, symbol: "八拾" }, { value: 70, symbol: "七拾" }, { value: 60, symbol: "六拾" }, { value: 50, symbol: "伍拾" }, { value: 40, symbol: "四拾" }, { value: 30, symbol: "参拾" }, { value: 20, symbol: "弐拾" }, { value: 10, symbol: "壱拾" }, { value: 9, symbol: "九" }, { value: 8, symbol: "八" }, { value: 7, symbol: "七" }, { value: 6, symbol: "六" }, { value: 5, symbol: "伍" }, { value: 4, symbol: "四" }, { value: 3, symbol: "参" }, { value: 2, symbol: "弐" }, { value: 1, symbol: "壱" }, { value: 0, symbol: "零" }], ranges: [[-9999, 9999]], fallback: "cjk-decimal", suffix: "、", negative: ["マイナス"] }),
  builtin("korean-hangul", "additive", [], { additive: [{ value: 9000, symbol: "구천" }, { value: 8000, symbol: "팔천" }, { value: 7000, symbol: "칠천" }, { value: 6000, symbol: "육천" }, { value: 5000, symbol: "오천" }, { value: 4000, symbol: "사천" }, { value: 3000, symbol: "삼천" }, { value: 2000, symbol: "이천" }, { value: 1000, symbol: "일천" }, { value: 900, symbol: "구백" }, { value: 800, symbol: "팔백" }, { value: 700, symbol: "칠백" }, { value: 600, symbol: "육백" }, { value: 500, symbol: "오백" }, { value: 400, symbol: "사백" }, { value: 300, symbol: "삼백" }, { value: 200, symbol: "이백" }, { value: 100, symbol: "일백" }, { value: 90, symbol: "구십" }, { value: 80, symbol: "팔십" }, { value: 70, symbol: "칠십" }, { value: 60, symbol: "육십" }, { value: 50, symbol: "오십" }, { value: 40, symbol: "사십" }, { value: 30, symbol: "삼십" }, { value: 20, symbol: "이십" }, { value: 10, symbol: "일십" }, { value: 9, symbol: "구" }, { value: 8, symbol: "팔" }, { value: 7, symbol: "칠" }, { value: 6, symbol: "육" }, { value: 5, symbol: "오" }, { value: 4, symbol: "사" }, { value: 3, symbol: "삼" }, { value: 2, symbol: "이" }, { value: 1, symbol: "일" }, { value: 0, symbol: "영" }], ranges: [[-9999, 9999]], fallback: "cjk-decimal", suffix: ", ", negative: ["마이너스 "] }),
  builtin("korean-hanja", "additive", [], { additive: [{ value: 9000, symbol: "九千" }, { value: 8000, symbol: "八千" }, { value: 7000, symbol: "七千" }, { value: 6000, symbol: "六千" }, { value: 5000, symbol: "五千" }, { value: 4000, symbol: "四千" }, { value: 3000, symbol: "三千" }, { value: 2000, symbol: "二千" }, { value: 1000, symbol: "千" }, { value: 900, symbol: "九百" }, { value: 800, symbol: "八百" }, { value: 700, symbol: "七百" }, { value: 600, symbol: "六百" }, { value: 500, symbol: "五百" }, { value: 400, symbol: "四百" }, { value: 300, symbol: "三百" }, { value: 200, symbol: "二百" }, { value: 100, symbol: "百" }, { value: 90, symbol: "九十" }, { value: 80, symbol: "八十" }, { value: 70, symbol: "七十" }, { value: 60, symbol: "六十" }, { value: 50, symbol: "五十" }, { value: 40, symbol: "四十" }, { value: 30, symbol: "三十" }, { value: 20, symbol: "二十" }, { value: 10, symbol: "十" }, { value: 9, symbol: "九" }, { value: 8, symbol: "八" }, { value: 7, symbol: "七" }, { value: 6, symbol: "六" }, { value: 5, symbol: "五" }, { value: 4, symbol: "四" }, { value: 3, symbol: "三" }, { value: 2, symbol: "二" }, { value: 1, symbol: "一" }, { value: 0, symbol: "零" }], ranges: [[-9999, 9999]], fallback: "cjk-decimal", suffix: ", ", negative: ["마이너스 "] }),
  builtin("korean-hanja-formal", "additive", [], { additive: [{ value: 9000, symbol: "九仟" }, { value: 8000, symbol: "八仟" }, { value: 7000, symbol: "七仟" }, { value: 6000, symbol: "六仟" }, { value: 5000, symbol: "五仟" }, { value: 4000, symbol: "四仟" }, { value: 3000, symbol: "參仟" }, { value: 2000, symbol: "貳仟" }, { value: 1000, symbol: "壹仟" }, { value: 900, symbol: "九百" }, { value: 800, symbol: "八百" }, { value: 700, symbol: "七百" }, { value: 600, symbol: "六百" }, { value: 500, symbol: "五百" }, { value: 400, symbol: "四百" }, { value: 300, symbol: "參百" }, { value: 200, symbol: "貳百" }, { value: 100, symbol: "壹百" }, { value: 90, symbol: "九拾" }, { value: 80, symbol: "八拾" }, { value: 70, symbol: "七拾" }, { value: 60, symbol: "六拾" }, { value: 50, symbol: "五拾" }, { value: 40, symbol: "四拾" }, { value: 30, symbol: "參拾" }, { value: 20, symbol: "貳拾" }, { value: 10, symbol: "壹拾" }, { value: 9, symbol: "九" }, { value: 8, symbol: "八" }, { value: 7, symbol: "七" }, { value: 6, symbol: "六" }, { value: 5, symbol: "五" }, { value: 4, symbol: "四" }, { value: 3, symbol: "參" }, { value: 2, symbol: "貳" }, { value: 1, symbol: "壹" }, { value: 0, symbol: "零" }], ranges: [[-9999, 9999]], fallback: "cjk-decimal", suffix: ", ", negative: ["마이너스 "] }),
  builtin("nko-ordinal", "numeric", ["߀", "߁", "߂", "߃", "߄", "߅", "߆", "߇", "߈", "߉"], { suffix: " - " }),
  builtin("none", "cyclic", [""], { suffix: "" }),
];

// The legacy names a style may also be known by (CSS Counter Styles 3 §7.1), after the array so
// the styles they copy are built.
for (const [name, base] of [["japanese-informal", "japanese"], ["korean-hangul-formal", "korean-hangul"],
  ["korean-hanja-informal", "korean-hanja"]]) {
  const spec = BUILTIN_STYLES.find((b) => b.name === base);
  if (spec !== undefined) BUILTIN_STYLES.push({ ...spec, name });
}

/** The ten keywords, by id: the styles a `list-style-type` keyword names. */
export const KEYWORD_STYLE_NAMES = ["disc", "circle", "square", "decimal", "decimal-leading-zero",
  "lower-alpha", "upper-alpha", "lower-roman", "upper-roman", "none"];

