// The `content` property: generated text for ::before/::after, held as a table of item lists.
//
// A list is stored as a string of items joined by CONTENT_SEP, each one "t" + text for a string
// or "a" + attribute name for attr(). The tables are compiled into the app, so the runtime only
// decodes them; attr() is read from the originating element when the style is computed.

import * as P from "../props.ts";
import { counterStyleId, counterStyleName, readCounterStyleName } from "./lists.ts";
import type { ContentContext, Decl } from "./types.ts";

export const CONTENT_SEP = "\u0001";

/** The encoded item list for one string item. */
export function textItem(text: string): string {
  return "t" + text;
}

/** The encoded item list for one attr(name) item. */
export function attrItem(name: string): string {
  return "a" + name;
}

// A counter item is "c" + name + FIELD + style, and counters() "s" + name + FIELD + separator +
// FIELD + style. FIELD is a character no name or string from a declaration is likely to hold.
const FIELD = "\u0002";

/** The encoded item for `counter(name)` or `counter(name, style)`. */
export function counterItem(name: string, style: number): string {
  return "c" + name + FIELD + style;
}

/** The encoded item for `counters(name, separator)` or `counters(name, separator, style)`. */
export function countersItem(name: string, separator: string, style: number): string {
  return "s" + name + FIELD + separator + FIELD + style;
}

/** What a counter item resolves its counters through: the stack of a name, innermost last. */
export type CounterLookup = (name: string, style: number, separator: string | null) => string;

/**
 * The text a compiled item list generates. `attribute` reads an attribute of the originating
 * element; a missing attribute contributes the empty string, as attr() does. `counter` reads the
 * counters in scope at the originating element, for counter() and counters().
 */
export function contentText(encoded: string, attribute: (name: string) => string | null,
  counter?: CounterLookup): string {
  let out = "";
  for (const item of encoded.split(CONTENT_SEP)) {
    const kind = item.slice(0, 1);
    const value = item.slice(1);
    if (kind === "t") out += value;
    else if (kind === "a") {
      const v = attribute(value);
      if (v !== null) out += v;
    } else if (kind === "c") {
      const f = value.split(FIELD);
      if (counter !== undefined) out += counter(f[0], Number(f[1]), null);
    } else if (kind === "s") {
      const f = value.split(FIELD);
      if (counter !== undefined) out += counter(f[0], Number(f[2]), f[1]);
    }
  }
  return out;
}

/**
 * The computed value of `content` as CSSOM serializes it: strings quoted, each attr() resolved
 * to the value it generated.
 */
export function contentCss(encoded: string, attribute: (name: string) => string | null): string {
  const parts: string[] = [];
  for (const item of encoded.split(CONTENT_SEP)) {
    const kind = item.slice(0, 1);
    const value = item.slice(1);
    if (kind === "t") parts.push(quote(value));
    else if (kind === "a") {
      const v = attribute(value);
      parts.push(quote(v === null ? "" : v));
    } else if (kind === "c") {
      const f = value.split(FIELD);
      const style = Number(f[1]);
      parts.push(style === P.LST_DECIMAL ? `counter(${f[0]})` : `counter(${f[0]}, ${counterStyleName(style)})`);
    } else if (kind === "s") {
      const f = value.split(FIELD);
      const style = Number(f[2]);
      parts.push(`counters(${f[0]}, ${quote(f[1])}${style === P.LST_DECIMAL ? "" : ", " + counterStyleName(style)})`);
    }
  }
  return parts.join(" ");
}

/** A CSS string literal, with quotes and backslashes escaped. */
function quote(s: string): string {
  return '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\a ") + '"';
}

/** Reads one CSS escape at `i` (a backslash), as [text, index after it]. */
export function readEscape(s: string, i: number): [string, number] {
  let j = i + 1;
  if (j >= s.length) return ["�", j];
  const hex = /^[0-9a-fA-F]{1,6}/.exec(s.slice(j));
  if (hex !== null) {
    j += hex[0].length;
    if (j < s.length && /[ \t\n\r\f]/.test(s[j])) j++;
    const code = parseInt(hex[0], 16);
    return [code === 0 || code > 0x10ffff ? "�" : String.fromCodePoint(code), j];
  }
  if (s[j] === "\n") return ["", j + 1];
  return [s[j], j + 1];
}

/** A quoted string at `i`, decoded, or null when it isn't terminated on one line. */
export function readString(s: string, i: number): [string, number] | null {
  const q = s[i];
  let out = "";
  for (let j = i + 1; j < s.length; j++) {
    const ch = s[j];
    if (ch === q) return [out, j + 1];
    if (ch === "\n") return null;
    if (ch === "\\") {
      const [c, n] = readEscape(s, j);
      out += c;
      j = n - 1;
      continue;
    }
    out += ch;
  }
  return null;
}

/** A CSS identifier at `i`, or null. */
export function readIdent(s: string, i: number): [string, number] | null {
  let out = "";
  let j = i;
  while (j < s.length) {
    const ch = s[j];
    if (/[a-zA-Z0-9_-]/.test(ch) || ch.charCodeAt(0) > 127) { out += ch; j++; continue; }
    if (ch === "\\") {
      const [c, n] = readEscape(s, j);
      if (c === "") return null;
      out += c;
      j = n;
      continue;
    }
    break;
  }
  return out === "" ? null : [out, j];
}

/** Index of the ")" matching the "(" at `open`, or -1. */
function closeOf(s: string, open: number): number {
  let depth = 0;
  for (let j = open; j < s.length; j++) {
    const ch = s[j];
    if (ch === '"' || ch === "'") {
      const str = readString(s, j);
      if (str === null) return -1;
      j = str[1] - 1;
      continue;
    }
    if (ch === "(") depth++;
    else if (ch === ")") {
      depth--;
      if (depth === 0) return j;
    }
  }
  return -1;
}

/** A function's arguments, split at the commas outside its strings and parentheses. */
function splitArgs(s: string): string[] | null {
  const out: string[] = [];
  let start = 0;
  let depth = 0;
  for (let j = 0; j < s.length; j++) {
    const ch = s[j];
    if (ch === '"' || ch === "'") {
      const str = readString(s, j);
      if (str === null) return null;
      j = str[1] - 1;
      continue;
    }
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if (ch === "," && depth === 0) {
      out.push(s.slice(start, j).trim());
      start = j + 1;
    }
  }
  out.push(s.slice(start).trim());
  return out;
}

const QUOTE_KEYWORDS = new Set(["open-quote", "close-quote", "no-open-quote", "no-close-quote"]);

/**
 * The key a counter() names for its style: a built-in list-style-type id, or -2 - the index of an
 * @counter-style rule's name. Null when the name is neither.
 */
function counterStyleKey(text: string, content?: ContentContext): number | null {
  const builtin = counterStyleId(text);
  if (builtin >= 0) return builtin;
  const name = readCounterStyleName(text);
  if (name !== null && content !== undefined && content.counterStyle !== undefined) {
    return -2 - content.counterStyle(name);
  }
  return null;
}

/** Parses a content value into encoded items, or returns why it isn't supported. */
function parseItems(value: string, content?: ContentContext): string[] | string {
  const items: string[] = [];
  let i = 0;
  while (i < value.length) {
    const ch = value[i];
    if (/[ \t\n\r\f]/.test(ch)) { i++; continue; }
    if (ch === '"' || ch === "'") {
      const str = readString(value, i);
      if (str === null) return "an unterminated string in 'content'";
      items.push(textItem(str[0]));
      i = str[1];
      continue;
    }
    const id = readIdent(value, i);
    if (id === null) return `unsupported content value '${value}'`;
    const name = id[0];
    const lower = name.toLowerCase();
    i = id[1];
    if (value[i] === "(") {
      const end = closeOf(value, i);
      if (end < 0) return `unbalanced parentheses in 'content'`;
      const arg = value.slice(i + 1, end).trim();
      if (lower === "attr") {
        const nm = readIdent(arg, 0);
        if (nm === null || nm[1] !== arg.length) return `unsupported attr() argument '${arg}' in 'content'`;
        items.push(attrItem(nm[0]));
      } else if (lower === "counter" || lower === "counters") {
        const args = splitArgs(arg);
        if (args === null || args.length === 0) return `unsupported ${name}() argument '${arg}' in 'content'`;
        const nm = readIdent(args[0], 0);
        if (nm === null || nm[1] !== args[0].length) return `unsupported ${name}() argument '${arg}' in 'content'`;
        if (lower === "counter") {
          if (args.length > 2) return `unsupported counter() argument '${arg}' in 'content'`;
          let style = P.LST_DECIMAL;
          if (args.length === 2) {
            const found = counterStyleKey(args[1], content);
            if (found === null) return `unsupported counter style '${args[1]}' in 'content'`;
            style = found;
          }
          items.push(counterItem(nm[0], style));
        } else {
          // counters() needs its separator, and may name a style after it.
          if (args.length < 2 || args.length > 3) return `unsupported counters() argument '${arg}' in 'content'`;
          const a = args[1];
          const str = a.startsWith('"') || a.startsWith("'") ? readString(a, 0) : null;
          if (str === null || str[1] !== a.length) return `unsupported counters() separator '${a}' in 'content'`;
          let style = P.LST_DECIMAL;
          if (args.length === 3) {
            const found = counterStyleKey(args[2], content);
            if (found === null) return `unsupported counter style '${args[2]}' in 'content'`;
            style = found;
          }
          items.push(countersItem(nm[0], str[0], style));
        }
      } else {
        return `unsupported ${name}() in 'content'`;
      }
      i = end + 1;
      continue;
    }
    if (QUOTE_KEYWORDS.has(lower)) return "the quote keywords of 'content' aren't supported yet";
    return `unsupported content value '${value}'`;
  }
  if (items.length === 0) return "'content' needs a value";
  return items;
}

/**
 * Compiles `content`. `none` stores -1, meaning the pseudo-element isn't generated, and
 * `normal` -2, its initial value which generates nothing either. Without a content context
 * (the runtime parsing an inline style) the property is unsupported.
 */
export function contentProperty(prop: string, value: string, out: Decl[], content?: ContentContext): string | null | undefined {
  if (prop !== "content") return undefined;
  const text = value.trim();
  const lower = text.toLowerCase();
  if (lower === "none" || lower === "normal") {
    out.push({ p: P.P_CONTENT, v: lower === "none" ? P.CONTENT_NONE : P.CONTENT_NORMAL, u: P.U_NONE });
    return null;
  }
  if (content === undefined || content.item === undefined) {
    return "'content' is only supported in ::before and ::after rules";
  }
  const items = parseItems(text, content);
  if (typeof items === "string") return items;
  out.push({ p: P.P_CONTENT, v: content.item(items.join(CONTENT_SEP)), u: P.U_NONE });
  return null;
}
