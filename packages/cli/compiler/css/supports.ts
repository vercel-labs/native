// @supports conditions, decided at build time: a condition holds when every declaration in it
// compiles. Words from other browsers (`-webkit-appearance`, `-moz-orient`) don't, so the usual
// `@supports (not (-webkit-appearance: …))` guards come out the way they do in a browser that
// lacks them, while `@supports (color: color-mix(in lab, red, red))` holds because it parses.

import { parseDeclarationBlock } from "../../shared/css/declarations.ts";
import { parseSelector, splitTopLevel } from "../../shared/css/selectors.ts";
import { customPropertyName, validDeclarationValue } from "../../shared/css/vars.ts";

/** Splits on a top-level keyword (`and`, `or`): outside parentheses and between spaces. */
function splitKeyword(s: string, word: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let quote = "";
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote !== "") { if (ch === quote) quote = ""; continue; }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (ch === "(") { depth++; continue; }
    if (ch === ")") { depth = Math.max(0, depth - 1); continue; }
    if (depth !== 0) continue;
    if (s.startsWith(word, i) && /\s/.test(s[i - 1] ?? "") && /\s/.test(s[i + word.length] ?? "")) {
      out.push(s.slice(start, i));
      start = i + word.length;
      i += word.length - 1;
    }
  }
  out.push(s.slice(start));
  return out;
}

/** The index of the first `:` outside parentheses and strings, or -1. */
function topColon(s: string): number {
  let depth = 0;
  let quote = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote !== "") { if (ch === quote) quote = ""; continue; }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (ch === ":" && depth === 0) return i;
  }
  return -1;
}

/**
 * Does native compile this declaration? A custom property takes any <declaration-value>, empty
 * included, as long as its name is a dashed identifier and the value has no top-level `;` or
 * `!`; one trailing `!important` is the declaration's flag, not part of the value.
 */
function declarationSupported(prop: string, value: string): boolean {
  if (prop === "") return false;
  if (prop.startsWith("--")) {
    if (customPropertyName(prop) === null) return false;
    let v = value.trim();
    const important = /!\s*important\s*$/i.exec(v);
    if (important !== null) v = v.slice(0, important.index).trim();
    return validDeclarationValue(v);
  }
  // The value has to be one <declaration-value>: a `;` outside any function ends it, and a
  // trailing `!important` is the declaration's flag rather than part of the value.
  let v = value.trim();
  const important = /!\s*important\s*$/i.exec(v);
  if (important !== null) v = v.slice(0, important.index).trim();
  if (v === "" || !validDeclarationValue(v)) return false;
  let any = false;
  for (const d of parseDeclarationBlock(`${prop}: ${value}`)) {
    if (d.error !== null) return false;
    if (!d.blank && d.decls.length > 0) any = true;
  }
  return any;
}

/**
 * Whether one @supports condition holds, or null when it doesn't parse (so its rules are
 * dropped, as an invalid conditional group rule is).
 */
export function supportsHolds(cond: string): boolean | null {
  const s = cond.trim();
  if (s === "") return null;
  const ors = splitKeyword(s, "or");
  if (ors.length > 1) {
    let any = false;
    for (const part of ors) {
      const v = supportsHolds(part);
      if (v === null) return null;
      any = any || v;
    }
    return any;
  }
  const ands = splitKeyword(s, "and");
  if (ands.length > 1) {
    let all = true;
    for (const part of ands) {
      const v = supportsHolds(part);
      if (v === null) return null;
      all = all && v;
    }
    return all;
  }
  const not = /^not\s+/i.exec(s);
  if (not !== null) {
    const v = supportsHolds(s.slice(not[0].length));
    return v === null ? null : !v;
  }
  // `selector(<selector>)` asks whether the build can match that selector. Its argument is a
  // complex selector, not a relative one: a leading combinator is invalid there (Chrome says the
  // same), while `&` is valid whenever nesting is, which it is here.
  const selFn = /^selector\s*\(/i.exec(s);
  if (selFn !== null) {
    const open = selFn[0].length - 1;
    let depth = 0;
    let close = -1;
    for (let i = open; i < s.length; i++) {
      if (s[i] === "(") depth++;
      else if (s[i] === ")") { depth--; if (depth === 0) { close = i; break; } }
    }
    if (close < 0 || s.slice(close + 1).trim() !== "") return null;
    const inner = s.slice(open + 1, close).trim();
    if (inner === "") return false;
    // Every selector of the list has to be one the build can match.
    for (const part of splitTopLevel(inner, ",")) {
      const text = part.trim();
      if (text === "") return false;
      if (text.indexOf("&") >= 0) {
        if (parseSelector(text.split("&").join(":root")) === null) return false;
      } else if (parseSelector(text) === null) return false;
    }
    return true;
  }
  // A declaration is always parenthesised; only a nested condition may be written bare.
  if (!(s.startsWith("(") && s.endsWith(")"))) return null;
  const inner = s.slice(1, -1).trim();
  const colon = topColon(inner);
  if (colon < 0) return supportsHolds(inner);
  return declarationSupported(inner.slice(0, colon).trim(), inner.slice(colon + 1).trim());
}
