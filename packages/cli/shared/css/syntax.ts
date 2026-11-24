// The syntax descriptor of a registered custom property: `*`, or a `|`-separated list of
// component types and keywords, each with an optional multiplier (CSS Properties and Values 1, §2).
//
// The check answers whether a value belongs to the syntax, which is what decides if a declaration
// of a registered property is valid; a value that doesn't belong leaves the property unset.

import { parseColor } from "./colors.ts";

/** The component types a registered property's values are checked against. */
const SYNTAX_TYPES = new Set([
  "<length>", "<percentage>", "<length-percentage>", "<number>", "<integer>", "<angle>", "<time>",
  "<resolution>", "<color>", "<image>", "<url>", "<string>", "<custom-ident>", "<transform-function>",
  "<transform-list>", "<filter-function>", "<position>", "<paint>",
]);

export const CSS_WIDE = new Set(["initial", "inherit", "unset", "revert", "revert-layer"]);

/** The text of a CSS string token, or null when the value isn't one. */
export function stringToken(value: string): string | null {
  if (value.length < 2) return null;
  const q = value[0];
  if ((q !== '"' && q !== "'") || value[value.length - 1] !== q) return null;
  if (value.slice(1, -1).includes(q) && !value.slice(1, -1).includes("\\" + q)) return null;
  return value.slice(1, -1).replace(/\\(.)/g, "$1").trim();
}

/** Is `value` a single number, or a number with one of `units`? A unitless zero is a length. */
function numberWith(value: string, units: string[], zero: boolean): boolean {
  const m = /^([-+]?(?:\d+\.?\d*|\.\d+))([a-z%]*)$/i.exec(value.trim());
  if (m === null) return false;
  const unit = m[2].toLowerCase();
  if (unit === "") return zero && Number(m[1]) === 0;
  return units.includes(unit);
}

/** Does one `@property` syntax component accept `value`? */
function componentFits(type: string, value: string): boolean {
  const v = value.trim();
  // A math function or a var() is left to the value parser where the property is used.
  if (/^(?:calc|min|max|clamp|env|var)\(/i.test(v)) return true;
  switch (type) {
    case "<length>": return numberWith(v, ["px", "em", "rem", "ex", "ch", "lh", "vw", "vh", "vmin", "vmax", "cm", "mm", "in", "pt", "pc", "q"], true);
    case "<percentage>": return numberWith(v, ["%"], false);
    case "<length-percentage>": return componentFits("<length>", v) || componentFits("<percentage>", v);
    case "<number>": return numberWith(v, [], true);
    case "<integer>": return /^[-+]?\d+$/.test(v);
    case "<angle>": return numberWith(v, ["deg", "rad", "grad", "turn"], true);
    case "<time>": return numberWith(v, ["s", "ms"], false);
    case "<resolution>": return numberWith(v, ["dpi", "dpcm", "dppx", "x"], false);
    case "<color>": return parseColor(v) !== null;
    case "<string>": return stringToken(v) !== null;
    case "<custom-ident>": return /^-?[A-Za-z_][\w-]*$/.test(v) && !CSS_WIDE.has(v.toLowerCase());
    case "<url>": return /^url\(/i.test(v);
    case "<image>": case "<transform-function>": case "<transform-list>": case "<filter-function>":
    case "<position>": case "<paint>": case "<bg-image>": return true;
    default: return true;
  }
}

/** Splits a top-level list on `sep`, ignoring separators inside strings and groups. */
function splitList(s: string, sep: string): string[] {
  const out: string[] = [];
  let depth = 0, quote = "", start = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "\\") { i++; continue; }
    if (quote !== "") { if (ch === quote) quote = ""; continue; }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (ch === "(" || ch === "[") { depth++; continue; }
    if (ch === ")" || ch === "]") { depth--; continue; }
    if (depth === 0 && s.startsWith(sep, i)) {
      out.push(s.slice(start, i));
      start = i + sep.length;
      i += sep.length - 1;
    }
  }
  out.push(s.slice(start));
  return out;
}

/**
 * Does a value belong to the syntax? The descriptor is a `|`-separated list of alternatives, each
 * either one component type, a literal keyword, or a sequence of them; a sequence is taken as
 * given, since splitting a value into its components needs a full parser.
 */
export function fitsSyntax(syntax: string, value: string): boolean {
  if (syntax.trim() === "*") return true;
  for (const alt of syntax.split("|")) {
    const seq = alt.trim().split(/\s+/).filter((s) => s !== "");
    if (seq.length === 0) continue;
    if (seq.length > 1) return true;
    // A multiplier (`<color>#`, `<length>+`, `<length>{1,4}`) allows a list of components.
    const token = seq[0].replace(/(?:[+#]|\{\s*\d+\s*(?:,\s*\d*\s*)?\})$/, "");
    if (token.startsWith("<")) {
      const type = token.toLowerCase();
      if (!SYNTAX_TYPES.has(type)) return true;
      if (seq[0] !== token) {
        // A list of components: the value must at least hold one that fits.
        const list = splitList(value, ",");
        return list.some((part) => componentFits(type, part));
      }
      if (componentFits(type, value)) return true;
      continue;
    }
    if (value.trim().toLowerCase() === token.toLowerCase()) return true;
  }
  return false;
}
