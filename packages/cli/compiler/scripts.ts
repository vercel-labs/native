// Turning the page's classic scripts into modules scriptc can compile: the browser globals a
// script names become imports, and the window's handler properties it assigns bare become
// `window.on…`, as a classic script's implicit global would.

import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { GLOBALS, WORKER_GLOBALS } from "./globals.ts";
import { ROOT } from "./root.ts";
import { NODE_SUPPLIED } from "./dom-globals.ts";
import { rewriteWorkerConstructions } from "./worker-entries.ts";

const RUNTIME = join(ROOT, "runtime");

/** A source file scriptc compiles as JavaScript: no type checking, no type positions. */
export function isJs(path: string): boolean {
  return /\.[cm]?jsx?$/.test(path);
}

/** A module specifier for `target` as seen from `fromDir`: a URL, so forward slashes everywhere. */
export function importPath(fromDir: string, target: string): string {
  let p = relative(fromDir, target).split("\\").join("/");
  if (!p.startsWith(".")) p = "./" + p;
  return p;
}

/** True when `text` uses `name` as a global. A file that declares the name itself shadows the
 *  global, as it would in a browser, so no import is needed — and importing it would collide. */
export function mentions(text: string, name: string): boolean {
  if (!new RegExp(`\\b${name}\\b`).test(text)) return false;
  // A declaration may be indented (inside a function, say): only the keyword has to start the
  // line once its leading whitespace is allowed for.
  return !new RegExp(
    `^\\s*(?:export\\s+)?(?:declare\\s+)?(?:async\\s+)?(?:function\\s*\\*?|class|const|let|var|interface|type|enum)\\s+${name}\\b`, "m",
  ).test(text);
}

/**
 * True when every use of `name` in `text` is a type position — an annotation, a cast, a generic
 * argument or a union — so the name needs no value binding and the type world the program checks
 * against supplies it.
 */
export function typeOnlyUse(text: string, name: string): boolean {
  const n = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // `extends` is a value use: a class that extends the runtime's class needs its constructor.
  const rest = text
    .replace(new RegExp(`(?::|\\bas|\\bimplements)\\s*${n}\\b`, "g"), "")
    .replace(new RegExp(`[<|&]\\s*${n}\\b`, "g"), "")
    .replace(new RegExp(`\\b${n}\\s*\\[\\]`, "g"), "");
  return !new RegExp(`\\b${n}\\b`).test(rest);
}

/** True when the source has a top-level import or export, so it is a module rather than a classic
 *  script: its declarations stay its own and never become the page's. */
export function isModuleText(text: string): boolean {
  return /^\s*(?:import|export)\b/m.test(text);
}

/** The window's event handler properties, which a classic script may assign as implicit globals. */
const WINDOW_HANDLERS = [
  "onload", "onresize", "onscroll", "onerror", "onunload", "onbeforeunload", "onhashchange",
  "onpopstate", "onmessage", "onpagehide", "onpageshow", "onfocus", "onblur", "onclick",
  "ondblclick", "onstorage", "onrejectionhandled", "onunhandledrejection", "onbeforeprint",
  "onafterprint", "onlanguagechange", "onoffline", "ononline",
];

/**
 * A classic script's bare `onload = …` assigns a window property. In a module it has to name the
 * window, so a statement that starts with one of the handler names is pointed at `window`.
 */
export function classicGlobals(text: string): string {
  const names = WINDOW_HANDLERS.join("|");
  return text.replace(new RegExp(`(^[ \\t]*|[;{}][ \\t]*)(?:\\.\\.\\.)?(${names})([ \\t]*=(?!=))`, "gm"),
    (_m, lead: string, name: string, eq: string) => `${lead}window.${name}${eq}`);
}

/** JavaScript's reserved words: an element can't lend one of these to the window. */
const RESERVED = new Set([
  "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
  "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import",
  "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try",
  "typeof", "var", "void", "while", "with", "yield", "let", "static", "await", "implements",
  "interface", "package", "private", "protected", "public", "arguments", "eval", "undefined",
]);

/** Window properties named access never reaches: the name is the window's own already, so the
 *  element with that id doesn't appear under it (HTML's named access on the window object). */
const WINDOW_OWNED = new Set([
  "window", "self", "document", "top", "parent", "location", "history", "name", "status", "length",
  "closed", "opener", "frames", "origin", "event", "external", "screen", "navigator", "console",
  "performance", "localStorage", "sessionStorage", "indexedDB", "caches", "crypto", "customElements",
  "devicePixelRatio", "innerWidth", "innerHeight", "outerWidth", "outerHeight", "scrollX", "scrollY",
  "pageXOffset", "pageYOffset", "locationbar", "menubar", "personalbar", "scrollbars", "statusbar",
  "toolbar", "frameElement", "visualViewport", "speechSynthesis", "getSelection", "getComputedStyle",
  "matchMedia", "requestAnimationFrame", "cancelAnimationFrame", "setTimeout", "clearTimeout",
  "setInterval", "clearInterval", "queueMicrotask", "fetch", "alert", "confirm", "prompt", "print",
  "focus", "blur", "open", "close", "stop", "postMessage", "addEventListener",
  "removeEventListener", "dispatchEvent", "scroll", "scrollTo", "scrollBy", "structuredClone",
]);

/**
 * HTML's named access on the window: an element with an id is also a global of that name, so a
 * classic script can write `child.style` for `<div id="child">`. The engine binds the names the
 * scripts actually use, once, after the DOM is built — the ones that aren't already a global or
 * the script's own.
 */
export function namedAccess(text: string, ids: string[]): string {
  let out = "";
  const seen = new Set<string>();
  // A name a script declares at its top level shadows the element's: a declaration inside a
  // function doesn't, though, and the script after it still reaches the element by its id.
  const declared = topLevelDeclarations(text);
  for (const id of ids) {
    if (seen.has(id)) continue;
    seen.add(id);
    if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(id)) continue;
    if (RESERVED.has(id) || WINDOW_OWNED.has(id) || declared.has(id)) continue;
    if (GLOBALS.some((g) => g.values.indexOf(id) >= 0 || g.types.indexOf(id) >= 0)) continue;
    // The element is reachable only if some script names it; whether a script declares it at the
    // top level is the check above.
    if (!new RegExp("\\b" + id + "\\b").test(text)) continue;
    out += `var ${id} = document.getElementById(${JSON.stringify(id)});\n`;
  }
  return out;
}

/** One top-level statement of a classic script, and whether it declares a name. */
export interface ScriptStatement {
  text: string;
  decl: boolean;
}

/** The next word after `i`, for the tokens that continue a statement past its closing brace. */
function nextWord(text: string, i: number): string {
  let j = i;
  while (j < text.length && /\s/.test(text[j])) j++;
  const m = /^[A-Za-z]+/.exec(text.slice(j, j + 10));
  return m === null ? "" : m[0];
}

/**
 * A classic script's top-level statements, in order. Depth is tracked so a `;` or a `}` inside a
 * block, an object literal or a for-header doesn't end the statement; a closing brace ends one
 * unless `else`, `catch`, `finally` or a do-while's `while` follows it.
 */
export function scriptStatements(text: string): ScriptStatement[] {
  const out: ScriptStatement[] = [];
  let depth = 0;
  let start = -1;
  const push = (end: number): void => {
    if (start < 0) return;
    const s = text.slice(start, end).trim();
    start = -1;
    if (s === "") return;
    out.push({ text: s, decl: isDeclaration(s) });
  };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      const nl = text.indexOf("\n", i);
      i = nl < 0 ? text.length : nl;
      continue;
    }
    if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < text.length && text[j] !== c) j += text[j] === "\\" ? 2 : 1;
      i = j;
      continue;
    }
    if (start < 0 && !/\s/.test(c)) start = i;
    if (c === "{" || c === "(" || c === "[") {
      depth++;
      continue;
    }
    if (c === "}" || c === ")" || c === "]") {
      depth--;
      if (depth === 0 && c === "}") {
        const word = nextWord(text, i + 1);
        if (word === "else" || word === "catch" || word === "finally" || word === "while") continue;
        push(i + 1);
      }
      continue;
    }
    if (depth === 0 && c === ";" && start >= 0) push(i + 1);
  }
  push(text.length);
  return out;
}

/**
 * True when a statement is a declaration of a name rather than code that runs. Type-side ones
 * count too: a TypeScript script's interface or type alias has to sit beside the functions that
 * name it, not inside the block its statements run in.
 */
function isDeclaration(s: string): boolean {
  return /^(?:(?:async\s+)?function\b|class\b|abstract\s+class\b|var\b|let\b|const\b|interface\b|type\b|enum\b|declare\b|namespace\b)/.test(s);
}

/**
 * A `var`, `let` or `const` statement with simple names, as the declaration to put at a module's
 * top level and the assignments to run where it stood: `const a = 1, b;` becomes `let a, b;` and
 * `a = 1;`. The initializer stays where it stood, so the statements before it run first, as a
 * browser's script order has them. An annotation moves with the name (`const a: T = v` becomes
 * `let a: T;` and `a = v;`). Null when a declarator isn't a plain name (a destructuring pattern),
 * which keeps the statement whole.
 */
export function splitVar(s: string, untypedAsAny: boolean = false): { decl: string; inits: string; names: string[] } | null {
  const m = /^(var|let|const)\s+([\s\S]*?);?\s*$/.exec(s);
  if (m === null) return null;
  const parts = splitDeclarators(m[2]);
  const decls: string[] = [];
  const inits: string[] = [];
  const names: string[] = [];
  for (const part of parts) {
    const name = /^\s*([A-Za-z_$][\w$]*)/.exec(part);
    if (name === null) return null;
    const rest = part.slice(name[0].length);
    // A type annotation runs to the initializer's `=`; without one, nothing may come between the
    // name and it.
    const eq = initializerAt(rest);
    const head = eq < 0 ? rest : rest.slice(0, eq);
    const init = eq < 0 ? "" : rest.slice(eq + 1);
    const annotation = /^\s*:\s*([\s\S]*?)\s*$/.exec(head);
    if (annotation === null && head.trim() !== "") return null;
    // A TypeScript page gets an explicit `any` on a binding it couldn't infer: the split leaves
    // the name used before its assignment (a class method), where tsc refuses to infer it.
    const type = annotation === null ? (untypedAsAny ? "any" : "") : annotation[1];
    names.push(name[0].trim());
    decls.push(type === "" ? name[0].trim() : `${name[0].trim()}: ${type}`);
    if (eq >= 0) inits.push(`${name[0].trim()} = ${init.trim()}`);
  }
  const keyword = m[1] === "var" ? "var" : "let";
  return {
    decl: `${keyword} ${decls.join(", ")};`,
    inits: inits.length === 0 ? "" : inits.join(", ") + ";",
    names,
  };
}

/**
 * The names a top-level declaration introduces: the declarators of a var, let or const, the name
 * of a function, class, interface, type alias, enum or namespace. A destructuring pattern gives
 * every identifier before its initializer, which is more than it binds — a key named in the
 * pattern counts too — and that only ever asks for one more name to be a module binding.
 */
export function declNames(s: string): string[] {
  const split = splitVar(s);
  if (split !== null) return split.names;
  const m = /^(?:(?:async\s+)?function\s*\*?|class|abstract\s+class|interface|type|enum|namespace|declare\s+(?:const|let|var|function|class))\s+([A-Za-z_$][\w$]*)/.exec(s);
  if (m !== null) return [m[1]];
  const eq = s.indexOf("=");
  return identifiersOf(eq < 0 ? s : s.slice(0, eq));
}

/** The identifiers a piece of code names, strings and comments aside. */
export function identifiersOf(text: string): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      const nl = text.indexOf("\n", i);
      i = nl < 0 ? text.length : nl;
      continue;
    }
    if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < text.length && text[j] !== c) j += text[j] === "\\" ? 2 : 1;
      i = j;
      continue;
    }
    if (!/[A-Za-z_$]/.test(c) || (i > 0 && /[\w$]/.test(text[i - 1]))) continue;
    let j = i + 1;
    while (j < text.length && /[\w$]/.test(text[j])) j++;
    const id = text.slice(i, j);
    if (!seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
    i = j - 1;
  }
  return out;
}

/**
 * A declaration's declarators, split at the commas between them. A comma inside brackets or a
 * string doesn't split, and neither does one inside a type's angle brackets before its
 * initializer (`Map<string, number>` is one declarator).
 */
function splitDeclarators(body: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let angle = 0;
  let inType = false;
  let inInit = false;
  let quote = "";
  let at = 0;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (quote !== "") {
      if (c === quote) quote = "";
      else if (c === "\\") i++;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      quote = c;
      continue;
    }
    if (c === "(" || c === "{" || c === "[") {
      depth++;
      continue;
    }
    if (c === ")" || c === "}" || c === "]") {
      depth--;
      continue;
    }
    if (depth !== 0) continue;
    if (!inInit) {
      if (c === ":" && !inType) inType = true;
      else if (c === "<" && inType) angle++;
      else if (c === ">" && inType && angle > 0) angle--;
      else if (c === "=" && angle === 0 && !isOperator(body, i)) inInit = true;
      continue;
    }
    if (c === ",") {
      parts.push(body.slice(at, i));
      at = i + 1;
      inType = false;
      inInit = false;
    }
  }
  parts.push(body.slice(at));
  return parts;
}

/** True for an `=` that belongs to `=>`, `==`, `<=` and the like rather than a declarator. */
function isOperator(text: string, i: number): boolean {
  const prev = i > 0 ? text[i - 1] : "";
  const next = i + 1 < text.length ? text[i + 1] : "";
  return next === ">" || next === "=" || "=!<>".indexOf(prev) >= 0;
}

/** Index of the top-level `=` that starts a declarator's initializer, or -1 if it has none. */
function initializerAt(text: string): number {
  let depth = 0;
  let angle = 0;
  let quote = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote !== "") {
      if (c === quote) quote = "";
      else if (c === "\\") i++;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") quote = c;
    else if (c === "(" || c === "{" || c === "[") depth++;
    else if (c === ")" || c === "}" || c === "]") depth--;
    else if (depth !== 0) continue;
    else if (c === "<") angle++;
    else if (c === ">" && angle > 0) angle--;
    else if (c === "=" && angle === 0 && !isOperator(text, i)) return i;
  }
  return -1;
}

/** Splits text at the given separator, leaving quoted and bracketed separators alone. */
function splitTopLevelText(text: string, sep: string): string[] | null {
  const parts: string[] = [];
  let depth = 0;
  let at = 0;
  let quote = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote !== "") {
      if (c === quote) quote = "";
      else if (c === "\\") i++;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") quote = c;
    else if (c === "(" || c === "{" || c === "[") depth++;
    else if (c === ")" || c === "}" || c === "]") {
      depth--;
      if (depth < 0) return null;
    } else if (c === sep && depth === 0) {
      parts.push(text.slice(at, i));
      at = i + 1;
    }
  }
  if (depth !== 0 || quote !== "") return null;
  parts.push(text.slice(at));
  return parts;
}

/** The first index of `ch` outside quotes and brackets, or -1. */
function topLevelIndex(text: string, ch: string): number {
  let depth = 0;
  let quote = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote !== "") {
      if (c === quote) quote = "";
      else if (c === "\\") i++;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") quote = c;
    else if (c === "(" || c === "{" || c === "[") depth++;
    else if (c === ")" || c === "}" || c === "]") depth--;
    else if (c === ch && depth === 0) return i;
  }
  return -1;
}

/** The offset of the `=` that gives a declarator its value, or -1. `=>`, `==` and `<=` aren't it. */
function assignAt(text: string): number {
  let depth = 0;
  let quote = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote !== "") {
      if (c === quote) quote = "";
      else if (c === "\\") i++;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") quote = c;
    else if (c === "(" || c === "{" || c === "[") depth++;
    else if (c === ")" || c === "}" || c === "]") depth--;
    else if (c === "=" && depth === 0) {
      const prev = i > 0 ? text[i - 1] : "";
      const next = i + 1 < text.length ? text[i + 1] : "";
      if (next === "=" || next === ">" || prev === "=" || prev === "<" || prev === ">" || prev === "!") {
        if (next === "=") i++;
        continue;
      }
      return i;
    }
  }
  return -1;
}

/** A binding target without its `= default`, when it has one. */
function withoutDefault(text: string): string {
  const at = assignAt(text);
  return at < 0 ? text : text.slice(0, at);
}

/**
 * The names a binding target gives to variables: an identifier, an object pattern
 * (`{a, b: c, d = 1, ...rest}`), or an array pattern (`[x, , ...rest]`). A `: type` annotation is
 * dropped. Null when the target isn't one of those.
 */
function patternNames(target: string): string[] | null {
  const colon = topLevelIndex(target, ":");
  const typed = colon < 0 ? target : target.slice(0, colon);
  const text = typed.trim();
  if (text === "") return null;
  if (text[0] === "{") {
    if (text[text.length - 1] !== "}") return null;
    const inner = text.slice(1, -1);
    const entries = splitTopLevelText(inner, ",");
    if (entries === null) return null;
    const out: string[] = [];
    for (const entry of entries) {
      const e = entry.trim();
      if (e === "") continue;
      if (e.startsWith("...")) {
        const rest = e.slice(3).trim();
        if (!/^[A-Za-z_$][\w$]*$/.test(rest)) return null;
        out.push(rest);
        continue;
      }
      // `key: value` binds through the value; a `=` before the colon means the colon belongs to a
      // default value, and the entry is the shorthand `key = default`.
      const c = topLevelIndex(e, ":");
      const eq = assignAt(e);
      if (c >= 0 && (eq < 0 || c < eq)) {
        const ns = patternNames(withoutDefault(e.slice(c + 1)));
        if (ns === null) return null;
        for (const n of ns) out.push(n);
        continue;
      }
      const name = withoutDefault(e).trim();
      if (!/^[A-Za-z_$][\w$]*$/.test(name)) return null;
      out.push(name);
    }
    return out;
  }
  if (text[0] === "[") {
    if (text[text.length - 1] !== "]") return null;
    const entries = splitTopLevelText(text.slice(1, -1), ",");
    if (entries === null) return null;
    const out: string[] = [];
    for (const entry of entries) {
      const e = entry.trim();
      if (e === "") continue;
      if (e.startsWith("...")) {
        const rest = e.slice(3).trim();
        if (!/^[A-Za-z_$][\w$]*$/.test(rest)) return null;
        out.push(rest);
        continue;
      }
      const ns = patternNames(withoutDefault(e));
      if (ns === null) return null;
      for (const n of ns) out.push(n);
    }
    return out;
  }
  return /^[A-Za-z_$][\w$]*$/.test(text) ? [text] : null;
}

/** Whether a comma-separated piece of a declaration begins a declarator rather than a type list. */
function startsDeclarator(piece: string): boolean {
  const t = piece.trim();
  if (t === "") return false;
  if (t[0] === "{" || t[0] === "[") {
    // A binding pattern is followed by its `: type`, its `=` or the declaration's end.
    const close = t[0] === "{" ? "}" : "]";
    let depth = 0;
    let quote = "";
    for (let i = 0; i < t.length; i++) {
      const c = t[i];
      if (quote !== "") {
        if (c === quote) quote = "";
        else if (c === "\\") i++;
        continue;
      }
      if (c === '"' || c === "'" || c === "`") quote = c;
      else if (c === "{" || c === "[" || c === "(") depth++;
      else if (c === "}" || c === "]" || c === ")") {
        depth--;
        if (depth === 0) return c === close && /^\s*(?::|=|$)/.test(t.slice(i + 1));
      }
    }
    return false;
  }
  return /^[A-Za-z_$][\w$]*\s*(,|=|:|$)/.test(t);
}

/**
 * The names a `let`, `const` or `class` statement binds, when the statement has to keep its place
 * in the script: its initializer runs where it is written, not ahead of the statements it may
 * depend on. Null for a declaration with nothing to run (a plain `let a;` can stay hoisted) and
 * for every other kind of statement.
 */
export function inPlaceNames(s: string): string[] | null {
  const cls = /^(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/.exec(s);
  if (cls !== null) return [cls[1]];
  const m = /^(?:const|let)\s+([\s\S]*?);?\s*$/.exec(s);
  if (m === null) return null;
  const split = splitTopLevelText(m[1], ",");
  if (split === null) return null;
  // A comma inside a generic type argument list (`new Map<string, number>()`) looks top-level
  // here; a piece that doesn't begin a declarator belongs to the piece before it.
  const parts: string[] = [];
  for (const piece of split) {
    if (parts.length > 0 && !startsDeclarator(piece)) parts[parts.length - 1] += "," + piece;
    else parts.push(piece);
  }
  const names: string[] = [];
  let initializes = false;
  for (const part of parts) {
    const at = assignAt(part);
    if (at >= 0) initializes = true;
    const ns = patternNames(at < 0 ? part : part.slice(0, at));
    if (ns === null) return null;
    for (const n of ns) if (names.indexOf(n) < 0) names.push(n);
  }
  return initializes && names.length > 0 ? names : null;
}

/**
 * The names a piece of code reads as variables. `identifiersOf` reports every identifier, so a
 * property access (`console.log` names `log`) and an object literal's key would look like
 * references to a script's own bindings; those are skipped here.
 */
function freeNames(text: string): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  let brace = 0;
  let quote = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote !== "") {
      if (c === quote) quote = "";
      else if (c === "\\") i++;
      continue;
    }
    if (c === "/" && text[i + 1] === "/") {
      const nl = text.indexOf("\n", i);
      i = nl < 0 ? text.length : nl;
      continue;
    }
    if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      quote = c;
      continue;
    }
    if (c === "{") {
      brace++;
      continue;
    }
    if (c === "}") {
      brace--;
      continue;
    }
    if (!/[A-Za-z_$]/.test(c) || (i > 0 && /[\w$]/.test(text[i - 1]))) continue;
    let j = i + 1;
    while (j < text.length && /[\w$]/.test(text[j])) j++;
    const id = text.slice(i, j);
    let before = i - 1;
    while (before >= 0 && /\s/.test(text[before])) before--;
    let after = j;
    while (after < text.length && /\s/.test(text[after])) after++;
    i = j - 1;
    // `a.b` reads `a`; `{ b: 1 }` names a key. A bare `{ b }` reads `b`.
    if (before >= 0 && text[before] === ".") continue;
    if (brace > 0 && after < text.length && text[after] === ":") continue;
    if (!seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
  }
  return out;
}

/**
 * Whether a let or const declaration can move to the top of the script whole. Its initializers
 * must name nothing the script declares at its top level: then running them early can't read a
 * binding before its own statement gives it a value, and the declaration keeps its inferred types
 * instead of being split into a bare `let` and an assignment.
 */
export function hoistableDecl(s: string, declared: Set<string>): boolean {
  const m = /^(?:const|let)\s+([\s\S]*?);?\s*$/.exec(s);
  if (m === null) return false;
  const parts = splitTopLevelText(m[1], ",");
  if (parts === null) return false;
  for (const part of parts) {
    const eq = initializerAt(part);
    if (eq < 0) continue;
    for (const id of freeNames(part.slice(eq + 1))) if (declared.has(id)) return false;
  }
  return true;
}

/**
 * The names a script declares at the top level of its own text. A page's scripts run in one module
 * here, so a name one of them leaves on the window must not be rebound if another declares it.
 */
/** A declaration's keyword and name where the scan stands. The match is sticky and reads the name
 *  whole: a fixed-width window of the text cut a name off after sixty characters, and the cut
 *  name went into the generated code. */
const DECL_AT_SITE = /(const|let|var|function|class)(?:\s*\*)?\s+([A-Za-z_$][\w$]*)/y;
/** The same for the names a classic script leaves on the window: `var` and `function` only. */
const VAR_FUNCTION_AT_SITE = /(var|function)(?:\s*\*)?\s+([A-Za-z_$][\w$]*)/y;

export function topLevelDeclarations(text: string): Set<string> {
  const names = new Set<string>();
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      const nl = text.indexOf("\n", i);
      i = nl < 0 ? text.length : nl;
      continue;
    }
    if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < text.length && text[j] !== c) j += text[j] === "\\" ? 2 : 1;
      i = j;
      continue;
    }
    if (c === "{" || c === "(" || c === "[") {
      depth++;
      continue;
    }
    if (c === "}" || c === ")" || c === "]") {
      depth--;
      continue;
    }
    if (depth !== 0 || !/[A-Za-z_$]/.test(c) || (i > 0 && /[\w$]/.test(text[i - 1]))) continue;
    DECL_AT_SITE.lastIndex = i;
    const m = DECL_AT_SITE.exec(text);
    if (m !== null && (i === 0 || !/[\w$.]/.test(text[i - 1]))) {
      names.add(m[2]);
      i += m[0].length - 1;
    }
  }
  return names;
}

/**
 * The names a script leaves on the window (`window.assert_equals = assert_equals`), which a later
 * classic script reaches as a bare global in a browser. The page's scripts share one module here,
 * so a name a script has just written gets a module binding of its own: the next script can then
 * call it by name, as it would through the window.
 */
/**
 * The names a classic script declares with `var` or `function` at the top level, as statements
 * that put each on the window. A browser's classic script makes those properties of the global
 * object, so a later script — or a test that reads a fixture through `window[name]` — finds
 * them there; the page's scripts share one module here, so each name is module-scoped and needs
 * the window write.
 */
export function windowVarNames(text: string): string[] {
  const names: string[] = [];
  const add = (name: string): void => {
    if (names.indexOf(name) >= 0) return;
    if (RESERVED.has(name) || WINDOW_OWNED.has(name)) return;
    if (GLOBALS.some((g) => g.values.indexOf(name) >= 0 || g.types.indexOf(name) >= 0)) return;
    names.push(name);
  };
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      const nl = text.indexOf("\n", i);
      i = nl < 0 ? text.length : nl;
      continue;
    }
    if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < text.length && text[j] !== c) j += text[j] === "\\" ? 2 : 1;
      i = j;
      continue;
    }
    if (c === "{" || c === "(" || c === "[") {
      depth++;
      continue;
    }
    if (c === "}" || c === ")" || c === "]") {
      depth--;
      continue;
    }
    if (depth !== 0 || !/[A-Za-z_$]/.test(c) || (i > 0 && /[\w$]/.test(text[i - 1]))) continue;
    VAR_FUNCTION_AT_SITE.lastIndex = i;
    const m = VAR_FUNCTION_AT_SITE.exec(text);
    if (m === null || (i > 0 && /[\w$.]/.test(text[i - 1]))) continue;
    add(m[2]);
    let j = i + m[0].length;
    if (m[1] === "var") {
      // The rest of the declaration list: a name, then a comma for the next one, with the end of
      // the statement after it. A name may have an initializer whose brackets hold commas.
      let inner = 0;
      for (; j < text.length; j++) {
        const d = text[j];
        if (d === '"' || d === "'" || d === "`") {
          let k = j + 1;
          while (k < text.length && text[k] !== d) k += text[k] === "\\" ? 2 : 1;
          j = k;
          continue;
        }
        if (d === "/" && text[j + 1] === "/") {
          const nl = text.indexOf("\n", j);
          j = nl < 0 ? text.length : nl;
          continue;
        }
        if (d === "/" && text[j + 1] === "*") {
          const e = text.indexOf("*/", j + 2);
          j = e < 0 ? text.length : e + 1;
          continue;
        }
        if (d === "(" || d === "[" || d === "{") { inner++; continue; }
        if (d === ")" || d === "]" || d === "}") { inner--; continue; }
        if (inner === 0 && d === ",") {
          const after = /^\s*([A-Za-z_$][\w$]*)/.exec(text.slice(j + 1, j + 60));
          if (after !== null) add(after[1]);
          continue;
        }
        if (inner === 0 && d === ";") break;
      }
      i = j;
    } else {
      i = j - 1;
    }
  }
  return names;
}

/** The statements that put a classic script's top-level var and function names on the window. */
export function windowVarAliases(text: string): string {
  let out = "";
  for (const name of windowVarNames(text)) out += `window.${name} = ${name};\n`;
  return out;
}

export function windowAliases(text: string, bound: Set<string>, declared: Set<string>): string {
  let out = "";
  const re = /\bwindow\.([A-Za-z_$][A-Za-z0-9_$]*)\s*=(?!=)/g;
  for (let m = re.exec(text); m !== null; m = re.exec(text)) {
    const name = m[1];
    if (bound.has(name)) continue;
    bound.add(name);
    if (RESERVED.has(name) || WINDOW_OWNED.has(name) || declared.has(name)) continue;
    if (GLOBALS.some((g) => g.values.indexOf(name) >= 0 || g.types.indexOf(name) >= 0)) continue;
    out += `var ${name} = window.${name};\n`;
  }
  return out;
}

/**
 * The names a classic script writes without declaring them — `tests = [...]`, which a browser
 * makes a property of the global object. A browser's classic script runs in sloppy mode, where an
 * undeclared assignment writes the global; the page's scripts share one ES module here, and a
 * module is strict, so the same write is a `ReferenceError` (and scriptc refuses to compile it).
 * Bridging the two is this writer's job, not scriptc's: the caller declares these names at the top
 * and copies them back onto the window after each script, so a script that reads one by name or
 * through the window sees what the last one wrote.
 *
 * An assignment to a name that is really a local — a parameter, a catch binding, a `var` inside a
 * function — is harmless: the module binding is shadowed there, and the write goes where it did.
 */
export function implicitGlobals(text: string, declared: Set<string>, bound: Set<string>): string[] {
  const names = new Set<string>();
  // A name this script declares anywhere is one of its own: the write reaches that binding, not
  // the window, even where the two sit in different scopes of the same script. A parameter counts
  // too, since `function f(value) { value = 1 }` writes the parameter.
  const local = new Set<string>();
  for (const m of text.matchAll(/\b(?:var|let|const|function|class)\s+([A-Za-z_$][A-Za-z0-9_$]*)/g)) local.add(m[1]);
  for (const m of text.matchAll(/\(([^()]*)\)\s*=>/g)) for (const id of m[1].matchAll(/[A-Za-z_$][A-Za-z0-9_$]*/g)) local.add(id[0]);
  for (const m of text.matchAll(/\bfunction\b[^(]*\(([^)]*)\)/g)) for (const id of m[1].matchAll(/[A-Za-z_$][A-Za-z0-9_$]*/g)) local.add(id[0]);
  let afterDecl = false;
  // Where the last significant token left the scanner: a `/` after one of these starts a regular
  // expression rather than dividing, and a regex body must not be read as code (its quotes would
  // otherwise swallow the rest of the text).
  let prev = "";
  let prevWord = "";
  const regexAllowed = (): boolean =>
    prev === "" || "([{,;:=!&|?+-*%^~<>".indexOf(prev) >= 0 ||
    /^(return|typeof|case|in|of|delete|void|throw|new|do|else|yield|await|instanceof)$/.test(prevWord);
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      const nl = text.indexOf("\n", i);
      i = nl < 0 ? text.length : nl;
      continue;
    }
    if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (c === "/" && regexAllowed()) {
      let j = i + 1;
      let inClass = false;
      for (; j < text.length; j++) {
        if (text[j] === "\\") {
          j++;
          continue;
        }
        if (text[j] === "[") inClass = true;
        else if (text[j] === "]") inClass = false;
        else if (text[j] === "/" && !inClass) break;
        else if (text[j] === "\n" && !inClass) break;
      }
      i = j;
      prev = "w";
      prevWord = "";
      afterDecl = false;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < text.length && text[j] !== c) j += text[j] === "\\" ? 2 : 1;
      i = j;
      prev = "w";
      prevWord = "";
      afterDecl = false;
      continue;
    }
    if (!/[A-Za-z_$]/.test(c) || (i > 0 && /[\w$]/.test(text[i - 1]))) {
      if (c !== " " && c !== "\t" && c !== "\n" && c !== "\r") {
        prev = c === ")" || c === "]" ? c : c;
        prevWord = "";
      }
      afterDecl = false;
      continue;
    }
    let j = i;
    while (j < text.length && /[\w$]/.test(text[j])) j++;
    const name = text.slice(i, j);
    const qualified = i > 0 && text[i - 1] === ".";
    i = j - 1;
    prev = "w";
    prevWord = name;
    if (afterDecl || qualified) {
      afterDecl = false;
      continue;
    }
    let k = j;
    while (k < text.length && (text[k] === " " || text[k] === "\t")) k++;
    const eq = text[k] === "=" && text[k + 1] !== "=" && text[k + 1] !== ">";
    const compound = /^[-+*/%]$/.test(text[k]) && text[k + 1] === "=";
    const inc = (text[k] === "+" || text[k] === "-") && text[k + 1] === text[k];
    if (!eq && !compound && !inc) {
      afterDecl = name === "var" || name === "let" || name === "const" || name === "function" || name === "class";
      continue;
    }
    // A window event handler property is the window's own even when WINDOW_OWNED doesn't list
    // it: classicGlobals rewrites the script's `onload = …` to `window.onload = …`, so a module
    // binding for the name would stay undefined and the copy-back would wipe the handler.
    if (!RESERVED.has(name) && !WINDOW_OWNED.has(name) && WINDOW_HANDLERS.indexOf(name) < 0 &&
      !declared.has(name) && !local.has(name) && !bound.has(name)) {
      if (!GLOBALS.some((g) => g.values.indexOf(name) >= 0)) names.add(name);
    }
  }
  return [...names];
}

/** Where code injected at the top of a file has to go: just past the file's directive prologue —
 *  the leading string statements, such as `"use strict"`, that only are directives while nothing
 *  stands before them — and whether the last of them ended with its own semicolon. Comments and
 *  blank lines before or between the directives don't end the prologue; an empty one ends at 0.
 *  A string that an expression continues (a call, a member, an operator) isn't a directive, and
 *  the prologue stops before it. */
function afterDirectives(text: string): { end: number; semicolon: boolean } {
  // The tokens that, after a line break, continue the expression a string opened.
  const continues = "([`+-*/%=<>!~&|^?.,:";
  let end = 0;
  let semicolon = false;
  let i = 0;
  for (;;) {
    let j = i;
    // Whitespace and comments before the next statement.
    for (;;) {
      const c = text[j];
      if (c === undefined) return { end, semicolon };
      if (/\s/.test(c)) {
        j++;
        continue;
      }
      const lineComment = c === "/" && text[j + 1] === "/";
      if (lineComment || (c === "/" && text[j + 1] === "*")) {
        const close = lineComment ? text.indexOf("\n", j) : text.indexOf("*/", j + 2);
        if (close < 0) return { end, semicolon };
        j = lineComment ? close + 1 : close + 2;
        continue;
      }
      break;
    }
    const quote = text[j];
    if (quote !== "\"" && quote !== "'") return { end, semicolon };
    let k = j + 1;
    let closed = false;
    while (k < text.length) {
      const c = text[k];
      if (c === "\\") {
        k += 2;
        continue;
      }
      if (c === quote) {
        k++;
        closed = true;
        break;
      }
      if (c === "\n") break; // an unterminated string is not a directive
      k++;
    }
    if (!closed) return { end, semicolon };
    let m = k;
    while (text[m] === " " || text[m] === "\t") m++;
    if (text[m] === ";") {
      end = m + 1;
      semicolon = true;
      i = end;
      continue;
    }
    // Without a semicolon the statement ends at a line break or the end of the file, unless the
    // next token continues the expression or brings its own statement with it.
    let n = m;
    while (n < text.length && /\s/.test(text[n])) n++;
    if (n < text.length) {
      const c = text[n];
      const comment = c === "/" && (text[n + 1] === "/" || text[n + 1] === "*");
      if (!comment && continues.indexOf(c) >= 0) return { end, semicolon };
    }
    end = k;
    semicolon = false;
    i = k;
  }
}

/** A worker's handler properties: `onmessage = …` is `self.onmessage = …` there, since the
 *  worker global object is what holds them (a page's are the window's). */
const WORKER_HANDLERS = "onmessage|onerror|onmessageerror";

export function workerGlobals(text: string): string {
  return text.replace(new RegExp(`(^[ \\t]*|[;{}][ \\t]*)(?:\\.\\.\\.)?(${WORKER_HANDLERS})([ \\t]*=(?!=))`, "gm"),
    (_m, lead: string, name: string, eq: string) => `${lead}self.${name}${eq}`);
}

/** How a build names the helper that gives a native thread the web Worker's API. Unlikely to
 *  collide, and the underscore suffix keeps two rewrites in one file apart. */
function workerAlias(text: string): string {
  let alias = "__nativeWorker";
  while (text.indexOf(alias) >= 0) alias += "_";
  return alias;
}

/** True when the file already binds Worker from worker_threads, so the rewrite can use it. */
function importsNodeWorker(text: string): boolean {
  return /(?:^|\n)\s*import\s+[^;\n]*\bWorker\b[^;\n]*from\s*["'](?:node:)?worker_threads["']/.test(text);
}

export interface InjectOptions {
  /** The file is a worker entry: worker globals instead of the page's, and no window. */
  worker?: boolean;
  /** The app directory, for resolving a worker's URL; absent leaves Worker constructions as
   *  written (a vendored dependency is not the page's scripts). */
  appDir?: string;
  /** The file a worker URL resolves against: the output's own path by default, or the page for
   *  a generated script whose statements came from an inline one. */
  baseFile?: string;
  /** The build checks against a browser's DOM types (a JSX build, or an app whose tsconfig
   *  names the DOM library), so a DOM name left to the type world is the one a dependency's
   *  declarations mean. Otherwise the global names are the runtime's generated interfaces. */
  globalTypes?: boolean;
  /** The build's DOM types come only from a dependency's request for the browser library, and the
   *  page is not JSX: a DOM name used only as a type names the runtime's class, so the page's
   *  annotations and casts and the declarations that reach it are one set of classes. */
  runtimeDomTypes?: boolean;
}

/** Makes the globals an app source refers to importable. scriptc can't yet bind ambient globals,
 *  so they are injected at the top of the file, after any directive prologue: a `"use strict"` that
 *  no longer opens the file means nothing, and the file would compile as sloppy mode. The
 *  injection stays on the directive's own line, so no line moves and a diagnostic still points at
 *  the source. A file that opens with a `// @ts-nocheck` or `// @ts-check` pragma keeps it on line
 *  1 too — scriptc reads the pragma only from the leading comment — and the injected code goes
 *  after it. A classic script (one with no import or export) also gets the window handler rewrite
 *  above. `js` writes for a .js file, which has no type positions: the globals are imported for
 *  their values only. Classic scripts are JavaScript, so a page's scripts are written that way.
 *  A worker entry gets the worker's globals instead, and every `new Worker(...)` in the app's
 *  scripts is wrapped in the web API helper. */
export function withDomImports(text: string, out: string, classic?: boolean, js?: boolean, opts?: InjectOptions): string {
  const isClassic = classic ?? !isModuleText(text);
  if (opts?.worker) text = workerGlobals(text);
  else if (isClassic) text = classicGlobals(text);
  const dir = dirname(out);
  // A CommonJS file can't hold an import: Node reads `import` there as a syntax error, so its
  // globals are required instead, which keeps the file the kind of module it already is.
  const commonjs = /\.cjs$/.test(out);
  let imports = "";
  let wrapped = false;
  if (opts?.appDir !== undefined) {
    const r = rewriteWorkerConstructions(text, opts.baseFile ?? out, opts.appDir, workerAlias(text),
      importPath(dir, join(RUNTIME, "worker.ts")));
    text = r.text;
    wrapped = r.changed;
    imports += r.imports;
  }
  for (const g of opts?.worker ? WORKER_GLOBALS : GLOBALS) {
    const names: string[] = [];
    // A name a file uses only as a type (`el: HTMLInputElement`, `as HTMLDialogElement`) is left
    // to the type world the program checks against, the way a framework's declarations see it.
    // Importing the runtime's class for it would shadow that type with the runtime's own, and a
    // ref callback or an event target whose type crossed from a framework's declarations would
    // then be the wrong one. A name the file also uses as a value is imported as before. A plain
    // TypeScript page whose DOM types come only from a dependency's library request is the
    // exception: it names the runtime's classes, since a browser interface has no lowering.
    for (const n of g.values) {
      if (!mentions(text, n)) continue;
      // A name Node's declarations supply keeps the runtime's binding: the global meaning of
      // `Event` there is Node's, not the class the page's listeners carry.
      if (opts?.globalTypes && !opts?.runtimeDomTypes && !js && !opts?.worker && !NODE_SUPPLIED.has(n) && typeOnlyUse(text, n)) continue;
      names.push(n);
    }
    for (const t of g.types) {
      if (js) break;
      if (g.values.indexOf(t) >= 0) continue; // a value names both the class and its type
      if (mentions(text, t)) names.push(`type ${t}`);
    }
    if (names.length === 0) continue;
    const mod = JSON.stringify(importPath(dir, join(RUNTIME, g.file)));
    imports += commonjs
      ? `const { ${names.join(", ")} } = require(${mod}); `
      : `import { ${names.join(", ")} } from ${mod}; `;
  }
  // The rewritten construction's `new Worker(...)` is scriptc's worker_threads constructor: it
  // is the one lowering that both starts the thread and compiles the entry module it names.
  if (wrapped && !importsNodeWorker(text)) {
    imports += commonjs
      ? `const { Worker } = require("node:worker_threads"); `
      : `import { Worker } from "node:worker_threads"; `;
  }
  if (imports === "") return text;
  const pragma = /^\s*\/\/\s*@ts-(?:nocheck|check)\b[^\n]*\n/.exec(text);
  if (pragma) text = text.slice(pragma[0].length);
  const { end, semicolon } = afterDirectives(text);
  // `;` only when a directive ended without one: dangling relative to it, the injected code would
  // read as a continuation of the string.
  const injected = (end > 0 && !semicolon ? ";" : "") + imports;
  const body = text.slice(0, end) + injected + text.slice(end);
  return pragma ? pragma[0] + body : body;
}
