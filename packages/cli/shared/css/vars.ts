// CSS custom properties and var() substitution, shared by the compiler (which keeps a value
// that uses var() as text until style time) and the runtime (which resolves it once the
// element's custom properties are known). Custom property names are case-sensitive.

/** Index just past the string starting at `i` (a quote); unterminated strings end the input. */
function skipString(s: string, i: number): number {
  const q = s[i];
  for (let j = i + 1; j < s.length; j++) {
    if (s[j] === "\\") j++;
    else if (s[j] === q) return j + 1;
  }
  return s.length;
}

/** Does `value` use a var() or env() function? A value that does is compiled only at style time. */
export function hasVar(value: string): boolean {
  return hasFunction(value, "var(") || hasFunction(value, "env(");
}

function hasFunction(value: string, fn: string): boolean {
  const lower = value.toLowerCase();
  let at = 0;
  while (true) {
    at = lower.indexOf(fn, at);
    if (at < 0) return false;
    // "myvar(" is a different function: a var() starts a token of its own.
    if (at === 0 || !/[A-Za-z0-9_\-\\\u0080-￿]/.test(value[at - 1])) return true;
    at += fn.length;
  }
}

/** The environment variables env() reads (titlebar-area-x and the like), set by the runtime from
 *  the window; a name with no value here takes env()'s fallback. */
const ENV = new Map<string, string>([
  // The safe-area insets always exist; a Mac window has no notch or rounded corner to avoid, so
  // they are zero unless the page draws under the titlebar (see runtime/app/titlebar.ts).
  ["safe-area-inset-top", "0px"], ["safe-area-inset-right", "0px"],
  ["safe-area-inset-bottom", "0px"], ["safe-area-inset-left", "0px"],
]);

/** Sets the value env(name) substitutes. */
export function setEnvironmentVariable(name: string, value: string): void {
  ENV.set(name, value);
}

/** The index of the ")" matching the "(" at `open`, or -1. Strings and nested parentheses count. */
function closeOf(s: string, open: number): number {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    const ch = s[i];
    if (ch === '"' || ch === "'") {
      i = skipString(s, i) - 1;
      continue;
    }
    if (ch === "\\") {
      i++;
      continue;
    }
    if (ch === "(") depth++;
    else if (ch === ")") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/** The index of the first top-level "," in `s`, or -1. */
function commaOf(s: string): number {
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === '"' || ch === "'") {
      i = skipString(s, i) - 1;
      continue;
    }
    if (ch === "\\") {
      i++;
      continue;
    }
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (ch === "," && depth === 0) return i;
  }
  return -1;
}

/** Is `ch` a name character in a CSS identifier (ASCII letter, digit, dash, underscore, non-ASCII)? */
function nameChar(ch: string): boolean {
  return /[A-Za-z0-9_\-]/.test(ch) || ch.charCodeAt(0) >= 0x80;
}

/**
 * Would `a` followed directly by `b` read as one token? var() substitution works on tokens, never
 * merging its value with the text around it: `--x: orange; color: var(--x)red` is two identifiers,
 * which is not a colour, rather than the one identifier `orangered`. A substituted value that meets
 * text at such a seam is written with a space between them.
 */
function seamMerges(a: string, b: string): boolean {
  if (a === "" || b === "") return false;
  const digit = (ch: string): boolean => ch >= "0" && ch <= "9";
  const name = (ch: string): boolean => nameChar(ch) || ch === "\\";
  if (name(a) && name(b)) return true;
  if (name(a) && b === "(") return true;
  if (digit(a) && (b === "%" || b === ".")) return true;
  if ((a === "." || a === "+" || a === "-") && (digit(b) || b === ".")) return true;
  if (a === "-" && b === "-") return true;
  if ((a === "#" || a === "@") && name(b)) return true;
  return false;
}

/**
 * The index of the character after the escape starting at the `\` at `i` (which may be a hex
 * escape and the whitespace that terminates it, or one escaped character).
 */
function escapeEnd(s: string, i: number): number {
  let j = i + 1;
  let digits = 0;
  while (j < s.length && digits < 6 && /[0-9a-fA-F]/.test(s[j])) {
    j++;
    digits++;
  }
  if (digits === 0) return j + 1;
  // One whitespace character after a hex escape belongs to the escape.
  if (s[j] === "\r" && s[j + 1] === "\n") return j + 2;
  if (s[j] === " " || s[j] === "\t" || s[j] === "\n" || s[j] === "\f") return j + 1;
  return j;
}

/** `name` with its CSS escapes decoded; an out-of-range or surrogate code point is U+FFFD. */
export function unescapeName(name: string): string {
  let out = "";
  let i = 0;
  while (i < name.length) {
    const ch = name[i];
    if (ch !== "\\") {
      out += ch;
      i++;
      continue;
    }
    const end = Math.min(escapeEnd(name, i), name.length);
    const body = name.slice(i + 1, end);
    const hex = /^[0-9a-fA-F]{1,6}/.exec(body);
    if (hex === null) {
      // An escaped character stands for itself.
      if (body.length > 0) out += body[0];
    } else {
      const cp = parseInt(hex[0], 16);
      out += cp === 0 || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) ? "�" : String.fromCodePoint(cp);
    }
    i = end;
  }
  return out;
}

/**
 * The custom property name `text` denotes, or null when it isn't one: two dashes and then an
 * identifier, escapes allowed, which is decoded here so every spelling of a name agrees.
 */
export function customPropertyName(text: string): string | null {
  if (!text.startsWith("--") || text.length <= 2) return null;
  for (let i = 2; i < text.length;) {
    const ch = text[i];
    if (ch === "\\") {
      const next = text[i + 1];
      if (next === undefined || next === "\n" || next === "\r" || next === "\f") return null;
      i = escapeEnd(text, i);
      continue;
    }
    if (!nameChar(ch)) return null;
    i++;
  }
  return unescapeName(text);
}

/**
 * Substitutes every var(--name) or var(--name, fallback) in `value` with what `lookup` returns
 * for the name, or the fallback when the name has no (valid) value. A var() inside a string is
 * left alone: it is text, not a reference. Null means a var() had no fallback either, so the
 * declaration is invalid at computed-value time.
 */
export function substituteVars(value: string, lookup: (name: string) => string | undefined): string | null {
  let out = "";
  let i = 0;
  // Whether the last text appended came from a var()'s value, so text after it needs a separator
  // wherever the two would otherwise merge into one token.
  let seam = false;
  const appendText = (text: string): void => {
    if (seam && out !== "" && text !== "" && seamMerges(out[out.length - 1], text[0])) out += " ";
    out += text;
    seam = false;
  };
  const appendValue = (text: string): void => {
    if (out !== "" && text !== "" && seamMerges(out[out.length - 1], text[0])) out += " ";
    out += text;
    seam = text !== "";
  };
  while (i < value.length) {
    const ch = value[i];
    if (ch === '"' || ch === "'") {
      const end = skipString(value, i);
      appendText(value.slice(i, end));
      i = end;
      continue;
    }
    if (ch === "\\") {
      appendText(value.slice(i, i + 2));
      i += 2;
      continue;
    }
    if ((ch === "v" || ch === "V") && value.slice(i, i + 4).toLowerCase() === "var(" &&
      (i === 0 || (value[i - 1] !== "\\" && !nameChar(value[i - 1])))) {
      const close = closeOf(value, i + 3);
      if (close < 0) return null;
      const inner = value.slice(i + 4, close);
      const comma = commaOf(inner);
      // A name that isn't a custom property name names nothing, so the fallback is used.
      const name = customPropertyName((comma < 0 ? inner : inner.slice(0, comma)).trim());
      const hit = name === null ? undefined : lookup(name);
      if (hit !== undefined) {
        appendValue(hit);
      } else if (comma >= 0) {
        const fallback = substituteVars(inner.slice(comma + 1).trim(), lookup);
        if (fallback === null) return null;
        appendValue(fallback);
      } else {
        return null;
      }
      i = close + 1;
      continue;
    }
    if ((ch === "e" || ch === "E") && value.slice(i, i + 4).toLowerCase() === "env(" &&
      (i === 0 || (value[i - 1] !== "\\" && !nameChar(value[i - 1])))) {
      const close = closeOf(value, i + 3);
      if (close < 0) return null;
      const inner = value.slice(i + 4, close);
      const comma = commaOf(inner);
      const hit = ENV.get((comma < 0 ? inner : inner.slice(0, comma)).trim().toLowerCase());
      if (hit !== undefined) {
        appendValue(hit);
      } else if (comma >= 0) {
        const fallback = substituteVars(inner.slice(comma + 1).trim(), lookup);
        if (fallback === null) return null;
        appendValue(fallback);
      } else {
        return null;
      }
      i = close + 1;
      continue;
    }
    appendText(ch);
    i++;
  }
  return out;
}

/** Is `s[from..to)` a <declaration-value>: balanced, with no top-level `;` or `!`? */
function declarationValue(s: string, from: number, to: number): boolean {
  const open: string[] = [];
  for (let i = from; i < to; i++) {
    const ch = s[i];
    if (ch === '"' || ch === "'") {
      const end = skipString(s, i);
      if (end > to) return false;
      i = end - 1;
      continue;
    }
    if (ch === "\\") {
      i++;
      continue;
    }
    // A CDO or CDC is a token of its own, so the `!` in `<!--` doesn't end the value.
    if (s.startsWith("<!--", i)) {
      i += 3;
      continue;
    }
    if (s.startsWith("-->", i)) {
      i += 2;
      continue;
    }
    if (ch === "(" || ch === "[" || ch === "{") open.push(ch);
    else if (ch === ")" || ch === "]" || ch === "}") {
      const want = ch === ")" ? "(" : ch === "]" ? "[" : "{";
      if (open.length === 0 || open[open.length - 1] !== want) return false;
      open.pop();
    } else if (open.length === 0 && (ch === ";" || ch === "!")) return false;
  }
  return open.length === 0;
}

/**
 * Does `value` meet the <declaration-value> grammar a custom property's value, or a var()'s
 * fallback, needs? A `!` or `;` outside a function, or an unbalanced bracket, makes the whole
 * declaration invalid, so a browser drops it at parse time rather than at computed-value time.
 */
export function validDeclarationValue(value: string): boolean {
  if (!declarationValue(value, 0, value.length)) return false;
  // A var()'s fallback is a <declaration-value> of its own, so the same rule reaches into it.
  for (let i = 0; i < value.length; i++) {
    const ch = value[i];
    if (ch === '"' || ch === "'") {
      i = skipString(value, i) - 1;
      continue;
    }
    if (ch === "\\") {
      i++;
      continue;
    }
    if ((ch === "v" || ch === "V") && value.slice(i, i + 4).toLowerCase() === "var(" &&
      (i === 0 || (value[i - 1] !== "\\" && !nameChar(value[i - 1])))) {
      const close = closeOf(value, i + 3);
      if (close < 0) return false;
      const inner = value.slice(i + 4, close);
      const comma = commaOf(inner);
      if (comma >= 0 && !validDeclarationValue(inner.slice(comma + 1).trim())) return false;
      i = close;
    }
  }
  return true;
}

/** The CSS-wide keyword `text` is (`initial`, `inherit`, `unset`, `revert`, `revert-layer`), or "". */
export function wideKeyword(text: string): string {
  const lower = text.trim().toLowerCase();
  return lower === "initial" || lower === "inherit" || lower === "unset" || lower === "revert" || lower === "revert-layer"
    ? lower : "";
}
