// Selector parsing: compounds, combinators, attribute selectors and pseudo-classes. Shared by
// the compiler, which resolves selectors at build time, and the runtime, which matches the
// selectors of style sheets a script adds (see runtime/sheets.ts).

import * as P from "../props.ts";
import { COMB_ADJACENT, COMB_CHILD, COMB_DESCENDANT, COMB_GENERAL } from "./types.ts";
import type { ChainLink, Compound, Selector } from "./types.ts";

export const ATTR_SEP = "\u0002";

const NOT_SEP = "\u0001";

/** Encodes a compound for a runtime :not() condition, which is matched without a parser. */
export function encodeCompound(c: Compound): string {
  const tokens: string[] = [];
  if (c.tag !== null) tokens.push("t" + c.tag);
  if (c.id !== null) tokens.push("i" + c.id);
  if (c.root) tokens.push("r");
  for (const k of c.classes) tokens.push("c" + k);
  for (const k of c.classPrefixes ?? []) tokens.push("p" + k);
  if (c.states !== 0) tokens.push("s" + c.states);
  if (c.nthStart.length > 0) tokens.push("a" + c.nthStart.join(","));
  if (c.nthEnd.length > 0) tokens.push("z" + c.nthEnd.join(","));
  // The "of S" filters, one per condition in the same order, in a token of their own.
  if (c.nthStartOf !== undefined) tokens.push("f" + c.nthStartOf.join("\u0004"));
  if (c.nthEndOf !== undefined) tokens.push("g" + c.nthEndOf.join("\u0004"));
  if (c.empty === true) tokens.push("e");
  for (const x of c.attrs) tokens.push("x" + x);
  if (c.lang !== undefined && c.lang.length > 0) tokens.push("l" + c.lang.join(","));
  // A :not() argument that is a complex selector, to be matched as a selector of its own.
  if (c.notSels !== undefined && c.notSels.length > 0) tokens.push("n" + c.notSels.join("\u0004"));
  // One token per :has() argument, so ":not(:has(> svg))" keeps its relative selector.
  for (const h of c.has) tokens.push("h" + h);
  return tokens.join(NOT_SEP);
}

/**
 * Every state bit a compound mentions, including inside its :not() arguments and the selectors
 * its :has() arguments name: a :hover there still means the element has to be restyled when it
 * changes.
 */
export function compoundStates(c: Compound): number {
  let s = c.states;
  for (const n of c.nots) s |= compoundStates(n);
  if (c.has.length > 0) s |= hasStates(c.has);
  return s;
}

/** The selector text of a `:has()` argument, without its combinator and subject markers. */
function hasArgumentBody(raw: string): string {
  const at = raw.indexOf("\u0003");
  const body = at < 0 ? raw : raw.slice(at + 1);
  return body.charAt(0) === "\u0005" ? body.slice(1) : body;
}

/** Every state bit the selectors of a :has() argument list mention. */
export function hasStates(list: readonly string[]): number {
  let s = 0;
  for (const raw of list) {
    const body = hasArgumentBody(raw);
    const sels = parseSelector(body);
    if (sels === null) continue;
    for (const sel of sels) {
      s |= compoundStates(sel);
      for (const l of sel.chain) s |= compoundStates(l);
    }
  }
  return s;
}

/** Splits on `sep` where it is outside brackets, parentheses and strings. */
export function splitTopLevel(s: string, sep: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let quote = "";
  let start = 0;
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

/** Index just past the bracket or parenthesis matching the one at `open`. */
function findCloseOf(s: string, open: number): number {
  const opener = s[open];
  const closer = opener === "(" ? ")" : "]";
  let depth = 0;
  let quote = "";
  for (let i = open; i < s.length; i++) {
    const ch = s[i];
    if (ch === "\\") { i++; continue; }
    if (quote !== "") { if (ch === quote) quote = ""; continue; }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (ch === opener) depth++;
    else if (ch === closer) {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

function isSpace(ch: string): boolean {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || ch === "\f";
}

/** Reads one CSS escape at `i` (a backslash), as [text, index after it]. */
function readEscape(s: string, i: number): [string, number] {
  let j = i + 1;
  if (j >= s.length) return ["�", j];
  const hex = /^[0-9a-fA-F]{1,6}/.exec(s.slice(j));
  if (hex !== null) {
    j += hex[0].length;
    if (j < s.length && isSpace(s[j])) j++;
    const code = parseInt(hex[0], 16);
    return [code === 0 || code > 0x10ffff ? "�" : String.fromCodePoint(code), j];
  }
  if (s[j] === "\n") return ["", j + 1];
  return [s[j], j + 1];
}

/** Reads a CSS identifier (with escapes) starting at `i`, as [name, index after it]. */
function readIdent(s: string, i: number): [string, number] | null {
  let out = "";
  let j = i;
  // An identifier starts with a letter, an underscore, a non-ASCII character, an escape, or a
  // hyphen followed by one of those; digits and hyphens may only continue it.
  let first = true;
  while (j < s.length) {
    const ch = s[j];
    if (ch === "\\") {
      const [c, n] = readEscape(s, j);
      if (c === "") return null;
      out += c;
      j = n;
      first = false;
      continue;
    }
    if (first) {
      const starts = /[a-zA-Z_]/.test(ch) || ch.charCodeAt(0) > 127;
      const hyphen = ch === "-" && j + 1 < s.length &&
        (/[a-zA-Z_-]/.test(s[j + 1]) || s[j + 1].charCodeAt(0) > 127 || s[j + 1] === "\\");
      if (!starts && !hyphen) return null;
    } else if (!(/[a-zA-Z0-9_-]/.test(ch) || ch.charCodeAt(0) > 127)) {
      break;
    }
    first = false;
    out += ch;
    j++;
  }
  if (out === "") return null;
  return [out, j];
}

/** Reads an attribute value: a quoted string or an identifier, escapes included. */
function readAttrValue(s: string, i: number): [string, number] | null {
  if (s[i] === '"' || s[i] === "'") {
    const q = s[i];
    let out = "";
    let j = i + 1;
    while (j < s.length && s[j] !== q) {
      if (s[j] === "\\") {
        const [c, n] = readEscape(s, j);
        out += c;
        j = n;
        continue;
      }
      if (s[j] === "\n") return null;
      out += s[j];
      j++;
    }
    if (j >= s.length) return null;
    return [out, j + 1];
  }
  return readIdent(s, i);
}

/** Parses one "[attr...]" into "name\u0002op\u0002value" (op "" = present), or null. */
function parseAttr(text: string): string | null {
  const inner = text.slice(1, text.length - 1);
  let i = 0;
  const skip = () => { while (i < inner.length && isSpace(inner[i])) i++; };
  skip();
  if (inner[i] === "|") return null; // namespace prefixes aren't supported
  const nm = readIdent(inner, i);
  if (nm === null) return null;
  const name = nm[0];
  i = nm[1];
  skip();
  if (inner[i] === "|" && inner[i + 1] !== "=") return null; // "ns|attr"
  if (i >= inner.length) return name.toLowerCase() + ATTR_SEP + ATTR_SEP;
  let op = "";
  if (inner[i] === "=") op = "=";
  else if ("~|^$*".indexOf(inner[i]) >= 0 && inner[i + 1] === "=") op = inner[i];
  else return null;
  i += op === "=" ? 1 : 2;
  skip();
  const val = readAttrValue(inner, i);
  if (val === null) return null;
  const value = val[0];
  i = val[1];
  skip();
  let flag = "";
  if (i < inner.length) {
    const f = inner[i].toLowerCase();
    if (f === "i") flag = "i";
    else if (f === "s") flag = "s";
    else return null;
    i++;
    skip();
  }
  if (i !== inner.length) return null;
  return name.toLowerCase() + ATTR_SEP + op + flag + ATTR_SEP + value;
}

/** One simple selector of a compound, already decoded. */
interface Simple {
  kind: "tag" | "id" | "class" | "classPrefix" | "attr" | "pseudo" | "host" | "slotted";
  name: string;
  arg: string | null;
}

/** A complex selector inside :is()/:where(): its subject compound and the ancestors above it. */
interface Frag { subject: Scan; chain: { scan: Scan; comb: number }[] }

interface ScanGroup {
  where: boolean;
  args: Frag[];
  /** The most specific item the forgiving list dropped because it can match nothing here
   *  (":visited"): it adds no alternative, but its weight still counts. */
  dropped?: number;
  /** The specificity the group adds, when it stands for one pseudo-class rather than its
   *  arguments (":link" reads the markup as "a[href], area[href]" but weighs 10, not 11). */
  spec?: number;
}

/** A compound before :is()/:where() are expanded: its simple selectors, groups and :not()s. */
interface Scan {
  simples: Simple[];
  groups: ScanGroup[];
  nots: Compound[];
  /**
   * :not() arguments that are complex selectors (`:not(.a .b)`, `:not(span + span)`), which the
   * runtime matches as selectors of their own; the element must match none of them.
   */
  notSels: string[];
  notSpec: number;
  /** :has() arguments, each a relative selector as it is stored on the compound. */
  has: string[];
  /** The variants this compound expands to, remembered so a nested argument is expanded once
   *  however often the scan is asked — the forgiving pass and the build both ask. */
  expanded?: Variant[] | null;
  expandedDom?: boolean;
  /** PE_NONE, or the pseudo-element the compound ends with. */
  pseudo: number;
  /** The name ::highlight(name) gives, or "" for the other pseudo-elements. */
  pseudoName: string;
}

/**
 * A pseudo-element the runtime doesn't generate content for, in a selector parsed for a DOM API.
 * The selector is valid and names nothing, so it never matches.
 */
const PE_OTHER = -1;

/**
 * Parses one :is()/:where() argument, which may be a complex selector: `.a > .b` there means the
 * element matches `.b` and its parent matches `.a`, so the argument carries a chain of its own.
 */
function scanFrag(text: string, dom: boolean = false, shadow: boolean = false): Frag | null {
  const parts = splitComplex(text);
  if (parts === null) return null;
  const scans: Scan[] = [];
  for (const c of parts.compounds) {
    // An argument is read the same way the selector around it is: a DOM selector keeps the
    // pseudo-classes a sheet can't match (:visited), so an item that names nothing here stays
    // valid instead of turning the argument into a parse failure.
    const s = scanCompound(c, false, false, dom, shadow);
    if (s === null) return null;
    scans.push(s);
  }
  const chain: { scan: Scan; comb: number }[] = [];
  for (let k = scans.length - 2; k >= 0; k--) chain.push({ scan: scans[k], comb: parts.combs[k] });
  return { subject: scans[scans.length - 1], chain };
}

/** Whether every compound of an :is()/:where() argument builds into a matchable compound for
 *  this parse: an item that doesn't is one the list drops. */
function fragBuilds(frag: Frag, dom: boolean): boolean {
  for (const s of [frag.subject, ...frag.chain.map((c) => c.scan)]) {
    const variants = expandScan(s, dom);
    if (variants === null || variants.length === 0) return false;
    for (const v of variants) if (buildCompound(v.simples, dom) === null) return false;
  }
  return true;
}

/** Compounds scanned during the outer parse, so a nested argument is scanned once however many
 *  passes ask about it (the forgiving pass, the specificity pass and the build). */
const scanMemo = new Map<string, Scan | null>();

/** Parses a compound (no combinators) into simple selectors, :is()/:where() and :not(). */
function scanCompound(text: string, inNot: boolean, allowPseudo: boolean = false, dom: boolean = false, shadow: boolean = false): Scan | null {
  // The flags stay in fixed-width fields of their own: a text that begins with the letters they
  // would have used can never be read as flags, nor flags as part of the text.
  const key = `${inNot ? 1 : 0}${allowPseudo ? 1 : 0}${dom ? 1 : 0}${shadow ? 1 : 0}:${text}`;
  const hit = scanMemo.get(key);
  if (hit !== undefined) return hit;
  if (scanMemo.size > 4096) scanMemo.clear();
  const made = scanCompoundFresh(text, inNot, allowPseudo, dom, shadow);
  scanMemo.set(key, made);
  return made;
}

function scanCompoundFresh(text: string, inNot: boolean, allowPseudo: boolean, dom: boolean, shadow: boolean): Scan | null {
  const simples: Simple[] = [];
  const groups: ScanGroup[] = [];
  const nots: Compound[] = [];
  const notSels: string[] = [];
  const has: string[] = [];
  let notSpec = 0;
  let pseudo = P.PE_NONE;
  let pseudoName = "";
  let plain = "";
  const flush = (): boolean => {
    if (plain === "") return true;
    const text = plain.toLowerCase();
    plain = "";
    // `ns|tag`, `*|tag`, `|tag` and a bare `tag` or `*`.
    const m = /^(?:(\*|[a-z][\w-]*|)?\|)?([a-z][\w-]*|\*)$/.exec(text);
    if (m === null) return false;
    const prefix = m[1];
    const name = m[2];
    if (name === "*" && prefix === undefined) return true;
    simples.push({ kind: "tag", name, arg: prefix === undefined ? null : prefix });
    return true;
  };
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === "#" || ch === ".") {
      if (pseudo !== P.PE_NONE || !flush()) return null;
      const id = readIdent(text, i + 1);
      if (id === null) return null;
      // A class name followed by "*" is a class-prefix selector (".foo-*"): it names a class
      // that starts with the name. The star has to close the name.
      let end = id[1];
      let isPrefix = false;
      if (ch === "." && text[end] === "*") {
        isPrefix = true;
        end++;
        if (end < text.length && /[-a-zA-Z0-9_\u0080-\uffff]/.test(text[end])) return null;
      }
      simples.push({ kind: isPrefix ? "classPrefix" : ch === "#" ? "id" : "class", name: id[0], arg: null });
      i = end;
      continue;
    }
    if (ch === "[") {
      if (pseudo !== P.PE_NONE || !flush()) return null;
      const end = findCloseOf(text, i);
      if (end < 0) return null;
      const enc = parseAttr(text.slice(i, end));
      if (enc === null) return null;
      simples.push({ kind: "attr", name: enc, arg: null });
      i = end;
      continue;
    }
    if (ch === ":") {
      if (!flush()) return null;
      // A pseudo-element may only end the subject compound: "a::before", and the legacy
      // ":before". Anything after it would need another compound, so it stays unsupported.
      const doubled = text[i + 1] === ":";
      const nm = readIdent(text, doubled ? i + 2 : i + 1);
      if (nm === null) return null;
      const name = nm[0].toLowerCase();
      let j = nm[1];
      let arg: string | null = null;
      if (text[j] === "(") {
        const end = findCloseOf(text, j);
        if (end < 0) return null;
        arg = text.slice(j + 1, end - 1);
        j = end;
      }
      if (pseudo !== P.PE_NONE) {
        // A pseudo-element may be followed by a state pseudo-class and nothing else:
        // "::scroll-marker:target-current", "::before:hover".
        if (doubled || arg !== null || STATE_PSEUDOS[name] === undefined) return null;
        simples.push({ kind: "pseudo", name, arg: null });
        i = j;
        continue;
      }
      // In a shadow tree's own sheet, :host names the tree's host and ::slotted(...) a node its
      // slot took. A compound carries at most one of either, and ::slotted(..) opens the compound.
      // A document's sheets may write :host too: it is valid there and matches nothing, so a
      // selector list like ":where(:root, :host)" still themes the document through :root.
      if (!dom && name === "host" && !doubled) {
        for (const s of simples) if (s.kind === "host") return null;
        simples.push({ kind: "host", name, arg });
        i = j;
        continue;
      }
      if (shadow && name === "slotted" && doubled) {
        if (arg === null || simples.length > 0 || groups.length > 0 || nots.length > 0 || has.length > 0) return null;
        simples.push({ kind: "slotted", name, arg });
        i = j;
        continue;
      }
      if (name === "highlight") {
        // ::highlight(name) takes a custom-ident, the name of a registry entry. The rest of the
        // pseudo-element grammar is the same: it is doubled and ends the subject compound.
        if (!doubled || !allowPseudo || pseudo !== P.PE_NONE || j !== text.length) return null;
        // A highlight name is a custom-ident, and registry keys match it case-sensitively.
        const nm = arg === null ? "" : arg.trim();
        if (!/^-?[a-z_][\w-]*$/.test(nm)) return null;
        pseudo = P.PE_HIGHLIGHT;
        pseudoName = nm;
        i = j;
        continue;
      }
      if (name === "before" || name === "after" || name === "marker" || name === "placeholder" ||
        name === "backdrop" || name === "first-line" || name === "first-letter" || name === "selection" ||
        name === "target-text" || name === "scroll-marker" || name === "scroll-marker-group") {
        // These have no single-colon form.
        const doubledOnly = name === "placeholder" || name === "backdrop" || name === "first-line" ||
          name === "first-letter" || name === "selection" || name === "target-text" ||
          name === "scroll-marker" || name === "scroll-marker-group";
        if (arg !== null || !allowPseudo || (doubledOnly && !doubled)) return null;
        pseudo = name === "before" ? P.PE_BEFORE : name === "after" ? P.PE_AFTER
          : name === "marker" ? P.PE_MARKER : name === "placeholder" ? P.PE_PLACEHOLDER
          : name === "backdrop" ? P.PE_BACKDROP : name === "first-line" ? P.PE_FIRST_LINE
          : name === "first-letter" ? P.PE_FIRST_LETTER
          : name === "target-text" ? P.PE_TARGET_TEXT
          : name === "scroll-marker" ? P.PE_SCROLL_MARKER
          : name === "scroll-marker-group" ? P.PE_SCROLL_MARKER_GROUP : P.PE_SELECTION;
        i = j;
        continue;
      }
      if (doubled) {
        // ::file-selector-button is a real pseudo-element this runtime draws no box for: there is
        // no file input, so its rule is valid and styles nothing. Any other pseudo-element is
        // valid only in a DOM selector, where it is just as true that it matches nothing.
        if (name === "file-selector-button" && allowPseudo && pseudo === P.PE_NONE && j === text.length) {
          pseudo = PE_OTHER;
          i = j;
          continue;
        }
        if (!dom || !allowPseudo || pseudo !== P.PE_NONE || j !== text.length) return null;
        pseudo = PE_OTHER;
        i = j;
        continue;
      }
      if (name === "has") {
        if (arg === null) return null;
        const args = splitTopLevel(arg, ",").map((a) => a.trim());
        if (args.length === 0 || args.some((a) => a === "")) return null;
        for (const a of args) {
          // A relative selector starts with an optional combinator, then a complex selector.
          const lead = /^([>+~])?\s*([\s\S]*)$/.exec(a);
          const body = lead === null ? "" : lead[2].trim();
          const frag = body === "" ? null : scanFrag(body, dom, shadow);
          if (frag === null) return null;
          // `:has(> :is(.a > .b))`: the leading combinator relates the compound's own subject to
          // the anchor, while the :is() argument's chain sits above that subject. The marker tells
          // the runtime matcher to test the relation on the subject rather than on the leftmost
          // compound of the argument's chain.
          const parts = splitComplex(body);
          let onSubject = false;
          if (parts !== null && parts.compounds.length === 1) {
            const variants = expandScan(frag.subject, dom);
            onSubject = variants !== null && variants.some((v) => v.chain.length > 0);
          }
          has.push((lead === null || lead[1] === undefined ? "" : lead[1]) + "\u0003" + (onSubject ? "\u0005" : "") + body);
        }
        i = j;
        continue;
      }
      if (name === "is" || name === "where" || name === "not") {
        if (arg === null) return null;
        const args = splitTopLevel(arg, ",").map((a) => a.trim());
        if (name === "not") {
          // :not() takes a plain selector list, where one malformed item invalidates the whole.
          if (args.length === 0 || args.some((a) => a === "")) return null;
          // Its arguments stay compounds: the runtime tests each encoded compound on its own.
          if (inNot) return null; // nested :not() isn't supported
          let max = 0;
          for (const a of args) {
            const s = scanCompound(a, true);
            if (s === null) {
              // A complex argument (`:not(.a .b)`, `:not(span + span)`) is matched as a selector
              // of its own; the runtime resolves it against the element like any other.
              const list = parseSelector(a, dom);
              if (list === null) return null;
              // An argument that names nothing (`:not(:visited div)`) asks nothing of the element,
              // so the :not() is true; it still weighs the argument's specificity.
              if (list.length === 0) {
                max = Math.max(max, parsedSpec(a, dom));
                continue;
              }
              let argSpec = 0;
              for (const sel of list) {
                if (sel.pseudo !== P.PE_NONE) return null;
                argSpec = Math.max(argSpec, sel.specificity);
              }
              notSels.push(a);
              max = Math.max(max, argSpec);
              continue;
            }
            const variants = expandScan(s, dom);
            if (variants === null) return null;
            for (const v of variants) {
              const b = buildCompound(v.simples, dom);
              if (b === null) return null;
              if (v.nots.length > 0) return null; // a :not() inside a :not() argument
              if (b.never) continue;
              // ":not(:has(> svg))" asks that the element not have a relative match of its own.
              b.compound.has = v.has;
              nots.push(b.compound);
            }
            max = Math.max(max, scanSpec(s));
          }
          notSpec += max;
        } else {
          // The argument list is forgiving: an item this build can't match is dropped, as a
          // browser drops an item it can't parse, and a list left with nothing matches nothing.
          const frags: Frag[] = [];
          let dropped = 0;
          for (const a of args) {
            if (a === "") continue;
            const f = scanFrag(a, dom, shadow);
            if (f === null || !fragBuilds(f, dom)) {
              // A malformed item is dropped by every browser and weighs nothing; one that is
              // valid but can match nothing here (:visited) adds no alternative, yet :is() still
              // weighs the most specific thing it lists.
              if (f !== null) dropped = Math.max(dropped, droppedWeight(f, dom));
              continue;
            }
            frags.push(f);
          }
          groups.push({ where: name === "where", args: frags, dropped });
        }
      } else if (name === "any-link" || name === "link") {
        // A link is an <a> or <area> with an href; :link is that set without the visited ones,
        // which a page can't tell apart here, so both name the same elements. The group weighs
        // one pseudo-class, as either name does.
        if (arg !== null) return null;
        // Any namespace: a document's default namespace belongs to the author's markup, and
        // :link names the HTML anchors whatever it says (the parser applies it to bare type
        // selectors, which these synthetic ones are not meant to be).
        const a = scanFrag("*|a[href]");
        const area = scanFrag("*|area[href]");
        if (a === null || area === null) return null;
        groups.push({ where: false, args: [a, area], spec: 100 });
      } else {
        simples.push({ kind: "pseudo", name, arg });
      }
      i = j;
      continue;
    }
    if (isSpace(ch) || ch === ">" || ch === "+" || ch === "~" || ch === ",") return null;
    if (pseudo !== P.PE_NONE) return null;
    plain += ch;
    i++;
  }
  if (!flush()) return null;
  return { simples, groups, nots, notSels, notSpec, has, pseudo, pseudoName };
}

/** An ancestor the subject must have, and the combinator that links it to the node below it. */
interface BuiltLink { compound: Compound; comb: number }

/**
 * One expansion of a compound: the simple selectors of each :is()/:where() argument applied, plus
 * the ancestors an argument's own combinators require.
 */
interface Variant { simples: Simple[]; nots: Compound[]; notSels: string[]; has: string[]; chain: BuiltLink[] }

/** Every way the compound's :is()/:where() arguments can apply, as simple-selector lists. */
function expandScan(scan: Scan, dom: boolean = false): Variant[] | null {
  if (scan.expanded !== undefined && scan.expandedDom === dom) return scan.expanded;
  const out = expandScanFresh(scan, dom);
  scan.expanded = out;
  scan.expandedDom = dom;
  return out;
}

function expandScanFresh(scan: Scan, dom: boolean): Variant[] | null {
  let acc: Variant[] = [{ simples: scan.simples.slice(), nots: scan.nots.slice(), notSels: scan.notSels.slice(), has: scan.has.slice(), chain: [] }];
  for (const g of scan.groups) {
    const variants: Variant[] = [];
    for (const a of g.args) {
      const vs = expandFrag(a, dom);
      if (vs === null) return null;
      for (const v of vs) variants.push(v);
    }
    const next: Variant[] = [];
    for (const base of acc) {
      for (const v of variants) {
        // One compound carries at most one chain of ancestors; two would have to be interleaved
        // with no way to say which comes first.
        if (base.chain.length > 0 && v.chain.length > 0) return null;
        next.push({
          simples: base.simples.concat(v.simples),
          nots: base.nots.concat(v.nots),
          notSels: base.notSels.concat(v.notSels),
          has: base.has.concat(v.has),
          chain: base.chain.length > 0 ? base.chain : v.chain,
        });
      }
    }
    acc = next;
    if (acc.length > 64) return null;
  }
  return acc;
}

/** Expands one :is()/:where() argument, keeping the chain its combinators describe. */
function expandFrag(frag: Frag, dom: boolean = false): Variant[] | null {
  const expanded: Variant[][] = [];
  for (const s of [frag.subject, ...frag.chain.map((c) => c.scan)]) {
    const vs = expandScan(s, dom);
    if (vs === null) return null;
    expanded.push(vs);
  }
  let combos: Variant[][] = [[]];
  for (const list of expanded) {
    const next: Variant[][] = [];
    for (const c of combos) for (const v of list) next.push(c.concat([v]));
    combos = next;
    if (combos.length > 64) return null;
  }
  const out: Variant[] = [];
  for (const c of combos) {
    const subject = c[0];
    const links: BuiltLink[] = [];
    let never = false;
    for (let k = 1; k < c.length; k++) {
      // A chain link is a single compound, so an argument's own ancestors can't sit inside one.
      if (c[k].chain.length > 0) return null;
      const b = buildCompound(c[k].simples, dom);
      if (b === null) return null;
      if (b.never) { never = true; break; }
      b.compound.nots = c[k].nots;
      b.compound.has = c[k].has;
      links.push({ compound: b.compound, comb: frag.chain[k - 1].comb });
    }
    if (never) continue;
    if (subject.chain.length > 0 && links.length > 0) return null;
    out.push({ simples: subject.simples, nots: subject.nots, notSels: subject.notSels, has: subject.has, chain: subject.chain.length > 0 ? subject.chain : links });
  }
  return out;
}

/** Both conditions on the same node: the element must satisfy all of both. Null if they conflict. */
function mergeCompound(a: Compound, b: Compound): Compound | null {
  if (a.tag !== null && b.tag !== null && a.tag !== b.tag) return null;
  if (a.id !== null && b.id !== null && a.id !== b.id) return null;
  // "*" asks for any namespace, so it merges with any other: ":link" reads as "*|a[href]" and
  // an author's "a:any-link" in a namespaced sheet still names its own namespace's anchors.
  if (a.tagNs !== undefined && b.tagNs !== undefined && a.tagNs !== b.tagNs &&
    a.tagNs !== "*" && b.tagNs !== "*") return null;
  /** The two compounds' "of S" filters, one entry per condition of both, in order. */
  const ofs = (which: "start" | "end"): string[] | undefined => {
    const an = which === "start" ? a.nthStart.length : a.nthEnd.length;
    const bn = which === "start" ? b.nthStart.length : b.nthEnd.length;
    const af = (which === "start" ? a.nthStartOf : a.nthEndOf) ?? [];
    const bf = (which === "start" ? b.nthStartOf : b.nthEndOf) ?? [];
    if (af.length === 0 && bf.length === 0) return undefined;
    const out: string[] = [];
    for (let i = 0; i < an / 3; i++) out.push(i < af.length ? af[i] : "");
    for (let i = 0; i < bn / 3; i++) out.push(i < bf.length ? bf[i] : "");
    return out;
  };
  const langs = (a.lang ?? []).concat(b.lang ?? []);
  const notSels = (a.notSels ?? []).concat(b.notSels ?? []);
  const prefixes = (a.classPrefixes ?? []).concat(b.classPrefixes ?? []);
  return {
    tag: a.tag !== null ? a.tag : b.tag,
    tagNs: a.tagNs === "*" ? b.tagNs : a.tagNs !== undefined ? a.tagNs : b.tagNs,
    id: a.id !== null ? a.id : b.id,
    root: a.root || b.root,
    dir: a.dir !== undefined ? a.dir : b.dir,
    scope: a.scope === true || b.scope === true ? true : undefined,
    classes: a.classes.concat(b.classes),
    classPrefixes: prefixes.length > 0 ? prefixes : undefined,
    states: a.states | b.states,
    empty: a.empty || b.empty,
    nthStart: a.nthStart.concat(b.nthStart),
    nthEnd: a.nthEnd.concat(b.nthEnd),
    nthStartOf: ofs("start"),
    nthEndOf: ofs("end"),
    attrs: a.attrs.concat(b.attrs),
    lang: langs.length > 0 ? langs : undefined,
    nots: a.nots.concat(b.nots),
    notSels: notSels.length > 0 ? notSels : undefined,
    has: a.has.concat(b.has),
  };
}

/** The weight a dropped forgiving-list item adds: an item whose compounds all build but whose
 *  variants can match nothing here (:visited) keeps its weight, one that doesn't build at all is
 *  malformed and weighs nothing. Both are read from the scan already done, never re-parsed. */
function droppedWeight(frag: Frag, dom: boolean): number {
  let spec = 0;
  for (const s of [frag.subject, ...frag.chain.map((c) => c.scan)]) {
    const variants = expandScan(s, dom);
    if (variants === null) return 0;
    for (const v of variants) if (buildCompound(v.simples, dom) === null) return 0;
    spec += scanSpec(s);
  }
  return spec;
}

/** The selector's specificity: a*10000 + b*100 + c, with :is()/:not() taking their max argument. */
function scanSpec(scan: Scan): number {
  // A pseudo-element counts as a type selector.
  let spec = scan.notSpec + (scan.pseudo !== P.PE_NONE ? 1 : 0);
  let hasSpec = 0;
  for (const s of scan.simples) {
    if (s.kind === "tag") spec += 1;
    else if (s.kind === "id") spec += 10000;
    else if (s.kind === "host") {
      // :host is a pseudo-class; :host(compound) adds the argument's own specificity.
      spec += 100;
      if (s.arg !== null) {
        const inner = scanCompound(s.arg, false, false, false, false);
        if (inner !== null) spec += scanSpec(inner);
      }
    } else if (s.kind === "pseudo" && (s.name === "nth-child" || s.name === "nth-last-child") && s.arg !== null) {
      // The pseudo-class itself, plus the most specific selector in its "of S" list.
      spec += 100;
      const ofAt = /\bof\b/i.exec(s.arg);
      if (ofAt !== null) {
        let max = 0;
        for (const part of splitTopLevel(s.arg.slice(ofAt.index + ofAt[0].length).trim(), ",")) {
          const text = part.trim();
          const list = parseSelector(text);
          if (list !== null && list.length > 0) {
            for (const sel of list) max = Math.max(max, sel.specificity);
            continue;
          }
          // A selector that can match nothing here (:visited) still weighs what it says. The
          // weight comes from the parse done here, never a second pass over the text.
          max = Math.max(max, parsedSpec(text, false));
        }
        spec += max;
      }
    } else spec += 100;
  }
  for (const a of scan.has) {
    const body = hasArgumentBody(a);
    const frag = scanFrag(body);
    if (frag === null) continue;
    let argSpec = 0;
    for (const scan2 of [frag.subject, ...frag.chain.map((c) => c.scan)]) argSpec += scanSpec(scan2);
    hasSpec = Math.max(hasSpec, argSpec);
  }
  spec += hasSpec;
  for (const g of scan.groups) {
    if (g.where) continue;
    if (g.spec !== undefined) {
      spec += g.spec;
      continue;
    }
    let max = g.dropped ?? 0;
    for (const a of g.args) {
      let s = scanSpec(a.subject);
      for (const c of a.chain) s += scanSpec(c.scan);
      max = Math.max(max, s);
    }
    spec += max;
  }
  return spec;
}


interface Built { compound: Compound; specificity: number; never: boolean; chain: BuiltLink[] }

/** The pseudo-classes that are a single state bit on the element. */
const STATE_PSEUDOS: { [name: string]: number } = {
  hover: P.S_HOVER,
  active: P.S_ACTIVE,
  focus: P.S_FOCUS,
  "focus-visible": P.S_FOCUS_VISIBLE,
  "focus-within": P.S_FOCUS_WITHIN,
  "popover-open": P.S_POPOVER_OPEN,
  checked: P.S_CHECKED,
  indeterminate: P.S_INDETERMINATE,
  default: P.S_DEFAULT,
  disabled: P.S_DISABLED,
  enabled: P.S_ENABLED,
  required: P.S_REQUIRED,
  optional: P.S_OPTIONAL,
  "read-only": P.S_READ_ONLY,
  "read-write": P.S_READ_WRITE,
  "placeholder-shown": P.S_PLACEHOLDER_SHOWN,
  "target-current": P.S_TARGET_CURRENT,
  // The UA sheet's own dark colours hang off this private state of the root's used scheme.
  "-native-dark": P.S_SCHEME_DARK,
  valid: P.S_VALID,
  invalid: P.S_INVALID,
  "in-range": P.S_IN_RANGE,
  "out-of-range": P.S_OUT_OF_RANGE,
};

function applyPseudo(c: Compound, name: string, arg: string | null, dom: boolean): "ok" | "invalid" | null {
  if (name === "root") {
    if (arg !== null) return "invalid";
    c.root = true;
    return "ok";
  }
  if (name === "scope") {
    if (arg !== null) return "invalid";
    // A DOM API call gives :scope the element it was made on. A style sheet has no such element,
    // so there :scope is the root, which is how the compiled tables already test :root.
    if (dom) c.scope = true;
    else c.root = true;
    return "ok";
  }
  if (name === "empty") {
    if (arg !== null) return "invalid";
    c.empty = true;
    return "ok";
  }
  if (name === "dir") {
    // The argument is exactly one ident; `:dir()` and `:dir(ltr, rtl)` are syntax errors even
    // where any other ident is accepted as a selector that matches nothing.
    if (arg === null || arg.trim() === "" || arg.indexOf(",") >= 0) return "invalid";
    const v = arg.trim().toLowerCase();
    // The argument is an ident: a quoted string or a number is invalid in both kinds of selector.
    if (!/^-?[a-z_][a-z0-9_-]*$/.test(v)) return "invalid";
    // A markup selector only knows the two directions; a DOM selector accepts any ident and
    // simply matches nothing for the rest, as `document.querySelector(":dir(lol)")` does.
    if (v !== "ltr" && v !== "rtl") return dom ? null : "invalid";
    c.dir = v === "ltr" ? 1 : 2;
    return "ok";
  }
  if (name === "lang") {
    if (arg === null) return "invalid";
    const langs: string[] = [];
    for (const part of splitTopLevel(arg, ",")) {
      let v = part.trim();
      if (v.length >= 2 && (v.startsWith('"') || v.startsWith("'")) && v.charAt(v.length - 1) === v.charAt(0)) {
        v = v.slice(1, -1);
      }
      // CSS escapes inside the argument (`:lang(\\*-FR)`) name the character they stand for.
      v = v.replace(/\\(.)/g, "$1");
      // A language range starts with a letter or a wildcard; a lone number isn't one.
      if (v === "" || !/^[A-Za-z*][A-Za-z0-9*-]*$/.test(v)) return "invalid";
      langs.push(v.toLowerCase());
    }
    if (langs.length === 0) return "invalid";
    c.lang = langs;
    return "ok";
  }
  const bit = STATE_PSEUDOS[name];
  if (bit !== undefined) {
    if (arg !== null) return "invalid";
    c.states |= bit;
    return "ok";
  }
  // A compound can carry several conditions of the same kind (":nth-child(1):nth-of-type(1)");
  // each is stored as a triplet appended to the list for its direction, with the "of S" filter
  // (if the condition has one) in a list of its own, kept in the same order.
  const add = (which: "start" | "end", cond: number[], filter: string = "") => {
    const list = which === "start" ? c.nthStart : c.nthEnd;
    const idx = list.length / 3;
    list.push(cond[0], cond[1], cond[2]);
    if (filter !== "" || (which === "start" ? c.nthStartOf !== undefined : c.nthEndOf !== undefined)) {
      const ofs = which === "start"
        ? (c.nthStartOf ?? (c.nthStartOf = []))
        : (c.nthEndOf ?? (c.nthEndOf = []));
      while (ofs.length < idx) ofs.push("");
      ofs.push(filter);
    }
  };
  if (name === "nth-child" || name === "nth-last-child" || name === "nth-of-type" || name === "nth-last-of-type") {
    if (arg === null) return "invalid";
    // "An+B of S" counts only the siblings that match S; "of" isn't part of the *-of-type forms.
    let nthArgs = arg;
    let filter = "";
    const ofAt = /\bof\b/i.exec(arg);
    if (ofAt !== null) {
      if (/of-type$/.test(name)) return "invalid";
      nthArgs = arg.slice(0, ofAt.index);
      const text = arg.slice(ofAt.index + ofAt[0].length).trim();
      const list = splitTopLevel(text, ",").map((t) => t.trim());
      if (text === "" || list.some((t) => t === "")) return "invalid";
      if (list.some((t) => parseSelector(t) === null)) return null;
      filter = text;
    }
    const ab = parseNth(nthArgs);
    if (ab === null) return "invalid";
    add(/last/.test(name) ? "end" : "start", [ab[0], ab[1], /of-type$/.test(name) ? 1 : 0], filter);
    return "ok";
  }
  if (name === "first-child" || name === "last-child" || name === "only-child" ||
    name === "first-of-type" || name === "last-of-type" || name === "only-of-type") {
    if (arg !== null) return "invalid";
    const ofType = name.endsWith("of-type") ? 1 : 0;
    if (name.startsWith("first") || name.startsWith("only")) add("start", [0, 1, ofType]);
    if (name.startsWith("last") || name.startsWith("only")) add("end", [0, 1, ofType]);
    return "ok";
  }
  return null;
}

/** The `@namespace` prefixes a sheet declares ("" is the default namespace), while it is parsed. */
let activeNamespaces: Map<string, string> | null = null;

export function setSelectorNamespaces(ns: Map<string, string> | null): void {
  if (ns === activeNamespaces) return;
  activeNamespaces = ns;
  // Scans made for the old prefixes are keyed by text alone, and a text's reading can change
  // with the prefixes that name its namespaces.
  scanMemo.clear();
}

/** Whether a compound's type selector fits an element of this local name and namespace. */
export function tagMatches(c: Compound, localName: string, namespaceURI: string | null): boolean {
  if (c.tag !== null && c.tag !== localName) return false;
  const want = c.tagNs;
  if (want === undefined || want === "*") return true;
  return (namespaceURI === null ? "" : namespaceURI) === want;
}

/** The `@namespace` rules a sheet declares: prefix ("" for the default) → namespace URI. */
export function scanNamespaces(src: string): Map<string, string> {
  const out = new Map<string, string>();
  src = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  const re = /@namespace\s+(?:([a-zA-Z_][\w-]*)\s+)?(?:"([^"]*)"|'([^']*)'|url\(\s*["']?([^"')]*)["']?\s*\))\s*;/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    const prefix = m[1] === undefined ? "" : m[1];
    out.set(prefix, m[2] ?? m[3] ?? m[4] ?? "");
  }
  return out;
}

/** The pseudo-classes whose names this parser knows, so a bad argument to one is an error. */
const KNOWN_PSEUDO = /^(root|scope|empty|hover|active|focus|nth-child|nth-last-child|nth-of-type|nth-last-of-type|first-child|last-child|only-child|first-of-type|last-of-type|only-of-type)$/;

/** Pseudo-classes every browser has that this build can't tell which elements match (a page's
 *  visited links): a sheet may name them, and their rules stand and match nothing. */
const KNOWN_NEVER_PSEUDO = /^(visited)$/;

function buildCompound(simples: Simple[], dom: boolean = false): Built | null {
  const c: Compound = { tag: null, id: null, root: false, classes: [], states: 0, nthStart: [], nthEnd: [], attrs: [], nots: [], has: [] };
  let spec = 0;
  let never = false;
  for (const s of simples) {
    if (s.kind === "tag") {
      if (c.tag !== null && c.tag !== s.name) never = true;
      const name = s.name;
      let ns: string | undefined = undefined;
      if (s.arg !== null) {
        const prefix = s.arg;
        if (prefix === "*") ns = "*";
        else if (prefix === "") ns = "";
        else {
          const uri = activeNamespaces === null ? undefined : activeNamespaces.get(prefix);
          if (uri === undefined) return null; // an undeclared prefix is an invalid selector
          ns = uri;
        }
      } else if (activeNamespaces !== null && activeNamespaces.has("")) {
        ns = activeNamespaces.get("") as string; // the default namespace reaches type selectors
      }
      if (name !== "*") c.tag = name;
      if (ns !== undefined) {
        // "*" asks for any namespace, so it fits whatever the compound already names; two
        // different namespaces can't both hold.
        if (c.tagNs !== undefined && c.tagNs !== ns && c.tagNs !== "*" && ns !== "*") never = true;
        else if (c.tagNs === undefined || c.tagNs === "*") c.tagNs = ns;
      }
      spec += 1;
    } else if (s.kind === "id") {
      if (c.id !== null && c.id !== s.name) never = true;
      c.id = s.name;
      spec += 10000;
    } else if (s.kind === "class") {
      c.classes.push(s.name);
      spec += 100;
    } else if (s.kind === "classPrefix") {
      if (c.classPrefixes === undefined) c.classPrefixes = [];
      c.classPrefixes.push(s.name);
      spec += 100;
    } else if (s.kind === "attr") {
      c.attrs.push(s.name);
      spec += 100;
    } else if (s.kind === "host") {
      c.host = true;
      if (s.arg !== null) {
        const inner = scanCompound(s.arg, false, false, false, false);
        if (inner === null || inner.groups.length > 0 || inner.has.length > 0 || inner.pseudo !== P.PE_NONE) return null;
        const built = buildCompound(inner.simples, dom);
        if (built === null) return null;
        if (built.never) never = true;
        else {
          built.compound.nots = inner.nots;
          c.hostArg = built.compound;
        }
      }
      spec += 100;
    } else if (s.kind === "slotted") {
      // ::slotted makes its argument the subject; parseCompoundVariants builds it.
      return null;
    } else {
      const verdict = applyPseudo(c, s.name, s.arg, dom);
      if (verdict === "invalid") { parseSawInvalid = true; return null; }
      if (verdict === null) {
        // A DOM selector may use a pseudo-class this runtime doesn't implement: it is valid and
        // matches nothing. A style sheet may too when the name is one every browser has, like
        // :visited, whose elements a page's own history decides and this build can't tell: the
        // rule stands and matches nothing rather than taking the other selectors of its list
        // with it. A misspelled argument to a name it does know is still an error.
        const ofArg = s.arg !== null && /\bof\b/i.test(s.arg);
        if (dom) {
          if (KNOWN_PSEUDO.test(s.name) && !ofArg) return null;
        } else if (!KNOWN_NEVER_PSEUDO.test(s.name)) return null;
        never = true;
      }
      spec += 100;
    }
  }
  return { compound: c, specificity: spec, never, chain: [] };
}

/** A compound expanded over its :is()/:where() arguments; [] means it can never match. */
function parseCompoundVariants(text: string, dom: boolean, shadow: boolean = false): { variants: Built[]; pseudo: number; pseudoName: string; spec: number } | null {
  const scan = scanCompound(text, false, true, dom, shadow);
  if (scan === null) return null;
  // ::slotted(...) makes its argument the subject: the rule styles the nodes the sheet's tree
  // took. Only state pseudo-classes may follow the pseudo-element (":slotted(p):hover").
  const slotAt = scan.simples.findIndex((s) => s.kind === "slotted");
  if (slotAt >= 0) {
    const arg = scan.simples[slotAt].arg;
    const extra = scan.simples.filter((s, k) => k !== slotAt);
    if (arg === null || scan.pseudo !== P.PE_NONE || scan.groups.length > 0 || scan.nots.length > 0 ||
      scan.has.length > 0) return null;
    for (const s of extra) if (s.kind !== "pseudo") return null;
    const inner = scanCompound(arg, false, false, false, false);
    if (inner === null || inner.groups.length > 0 || inner.has.length > 0 || inner.pseudo !== P.PE_NONE) return null;
    const vs = expandScan(inner, dom);
    if (vs === null || vs.length === 0) return null;
    const spec = 1 + scanSpec(inner);
    const out: Built[] = [];
    for (const v of vs) {
      const b = buildCompound(v.simples.concat(extra), dom);
      if (b === null) return null;
      if (b.never) continue;
      b.compound.nots = v.nots;
      if (v.notSels.length > 0) b.compound.notSels = v.notSels;
      b.compound.has = v.has;
      b.compound.slotted = true;
      out.push({ compound: b.compound, specificity: spec, never: false, chain: [] });
    }
    if (out.length === 0) return null;
    return { variants: out, pseudo: P.PE_NONE, pseudoName: "", spec };
  }
  const variants = expandScan(scan, dom);
  if (variants === null) return null;
  const spec = scanSpec(scan);
  const out: Built[] = [];
  for (const v of variants) {
    const b = buildCompound(v.simples, dom);
    if (b === null) return null;
    if (b.never) continue;
    b.compound.nots = v.nots;
    if (v.notSels.length > 0) b.compound.notSels = v.notSels;
    b.compound.has = v.has;
    out.push({ compound: b.compound, specificity: spec, never: false, chain: v.chain });
  }
  return { variants: out, pseudo: scan.pseudo, pseudoName: scan.pseudoName, spec };
}

/** Splits a complex selector into its compounds and the combinators between them. */
function splitComplex(text: string): { compounds: string[]; combs: number[] } | null {
  const compounds: string[] = [];
  const combs: number[] = [];
  let depth = 0;
  let quote = "";
  let cur = "";
  let spaced = false;
  const push = (comb: number) => {
    compounds.push(cur);
    cur = "";
    spaced = false;
    if (comb !== -1) combs.push(comb);
  };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "\\") { cur += ch; if (i + 1 < text.length) { cur += text[i + 1]; i++; } continue; }
    if (quote !== "") {
      cur += ch;
      if (ch === quote) quote = "";
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
    if (ch === "(" || ch === "[") {
      // An attribute selector may begin a compound, so a space before one still separates the
      // compounds: "#a [x]" names an element with [x] below #a, not one element with both.
      if (spaced) {
        if (cur === "") return null;
        push(COMB_DESCENDANT);
      }
      depth++;
      cur += ch;
      continue;
    }
    if (ch === ")" || ch === "]") {
      depth--;
      if (depth < 0) return null;
      cur += ch;
      continue;
    }
    if (depth > 0) { cur += ch; continue; }
    if (ch === ">" || ch === "+" || ch === "~") {
      if (cur === "") return null;
      push(ch === ">" ? COMB_CHILD : ch === "+" ? COMB_ADJACENT : COMB_GENERAL);
      continue;
    }
    if (isSpace(ch)) {
      if (cur !== "") spaced = true;
      continue;
    }
    if (spaced) {
      if (cur === "") return null;
      push(COMB_DESCENDANT);
    }
    cur += ch;
  }
  if (cur === "" || depth !== 0 || quote !== "") return null;
  compounds.push(cur);
  if (combs.length !== compounds.length - 1) return null;
  return { compounds, combs };
}

/**
 * Parses a complex selector into the selectors it names (one per :is()/:where() expansion).
 *
 * With `dom` set, the text is a selector a DOM API was handed rather than a style sheet's: the
 * pseudo-classes and pseudo-elements this runtime has no use for are valid and simply match
 * nothing, and :scope is kept as itself for the matcher to resolve. Without it, what this
 * runtime can't match is a parse failure, which is how unsupported style sheet selectors are
 * reported.
 */
/** Set while parsing when the selector is malformed (an argument no browser accepts for a
 *  pseudo-class it knows), as opposed to using a form this build hasn't implemented. A browser
 *  drops a rule whose selector is malformed, so the compiler reports that as a note, not a gap. */
let parseSawInvalid = false;
let parseDepth = 0;

/** Whether the last parseSelector() call failed because its selector is invalid. */
export function selectorWasInvalid(): boolean {
  return parseSawInvalid;
}

/**
 * Selector texts parsed during the outer call, so an argument a nested :is()/:not() asks about
 * more than once is parsed once: a deeply nested argument is otherwise re-parsed at every level
 * (and by the specificity pass on top of that).
 */
const parseMemo = new Map<string, { list: Selector[] | null; invalid: boolean; spec: number }>();

export function parseSelector(text: string, dom: boolean = false, shadow: boolean = false,
  specOut?: { spec: number }): Selector[] | null {
  const outer = parseDepth === 0;
  if (outer) {
    parseSawInvalid = false;
    parseMemo.clear();
  } else {
    const hit = parseMemo.get((shadow ? "s" : "") + (dom ? "d" : "") + text);
    if (hit !== undefined) {
      if (hit.invalid) parseSawInvalid = true;
      if (specOut !== undefined) specOut.spec = hit.spec;
      return hit.list;
    }
  }
  // A cap on the nesting: past it the selector is unreadable to a browser as well, and no page
  // gets to make the parser walk a wall of nested arguments.
  if (parseDepth > 64) return null;
  parseDepth++;
  // Every parse records the text's weight, whether or not this call asked for it: a later call
  // that does (a specificity pass) reads it from the memo.
  const spec = specOut !== undefined ? specOut : { spec: 0 };
  const out = parseSelectorInner(text, dom, shadow, spec);
  parseDepth--;
  if (!outer) {
    parseMemo.set((shadow ? "s" : "") + (dom ? "d" : "") + text,
      { list: out, invalid: parseSawInvalid, spec: spec.spec });
  }
  return out;
}

/** A selector text's specificity, taken from the parse that reads it; text that names nothing
 *  here still weighs what it says (":not(:visited div)" counts the pseudo-class). */
function parsedSpec(text: string, dom: boolean): number {
  const out = { spec: 0 };
  parseSelector(text, dom, false, out);
  return out.spec;
}

function parseSelectorInner(text: string, dom: boolean = false, shadow: boolean = false,
  specOut?: { spec: number }): Selector[] | null {
  if (text.trim() === "") return null;
  const parts = splitComplex(text);
  if (parts === null) return null;
  const sets: Built[][] = [];
  const pseudos: number[] = [];
  const pseudoNames: string[] = [];
  // The text's own weight, compound by compound: a compound that names nothing still counts.
  let specSum = 0;
  for (const c of parts.compounds) {
    const v = parseCompoundVariants(c, dom, shadow);
    if (v === null) return null;
    specSum += v.spec;
    sets.push(v.variants);
    pseudos.push(v.pseudo);
    pseudoNames.push(v.pseudoName);
  }
  // A pseudo-element belongs to the subject; "div::before span" names nothing.
  for (let i = 0; i < pseudos.length - 1; i++) if (pseudos[i] !== P.PE_NONE) return null;
  // :host and ::slotted name the subject compound of a shadow tree's sheet. An ancestor selector
  // above them would need a flattened-tree walk the runtime doesn't do, so it stays unsupported.
  for (let i = 0; i < sets.length; i++) {
    for (const v of sets[i]) {
      if (v.compound.host !== true && v.compound.slotted !== true) continue;
      if (i !== sets.length - 1 || sets.length > 1) return null;
    }
  }
  const pseudo = pseudos[pseudos.length - 1];
  const pseudoName = pseudoNames[pseudoNames.length - 1];
  // A style sheet's rule for ::file-selector-button styles nothing, and says so with an empty
  // selector list rather than a selector that could match.
  if (!dom && pseudo === PE_OTHER) return [];
  // Each alternative of the selector so far: the subject compound and the ancestors above it,
  // nearest first, which include the compounds an :is()/:where() argument brought with it.
  interface Combo { subject: Compound | null; chain: ChainLink[]; spec: number }
  let combos: Combo[] = [{ subject: null, chain: [], spec: 0 }];
  for (let i = 0; i < sets.length; i++) {
    const next: Combo[] = [];
    for (const base of combos) {
      for (const v of sets[i]) {
        const links = v.chain;
        if (base.subject === null) {
          next.push({ subject: v.compound, chain: links.map((l) => ({ ...l.compound, comb: l.comb })), spec: base.spec + v.specificity });
          continue;
        }
        const comb = parts.combs[i - 1];
        const above = links.slice(1).map((l) => ({ ...l.compound, comb: l.comb }));
        // The argument's chain starts at its subject: `links[0]` is the node the argument's own
        // first combinator names, and the previous compound (`base.subject`) is `comb` away from
        // that subject. The two have to be woven into one path from the subject upward.
        if (links.length === 0) {
          next.push({ subject: v.compound, chain: [{ ...base.subject, comb }, ...base.chain], spec: base.spec + v.specificity });
          continue;
        }
        if (links[0].comb === COMB_CHILD) {
          // The argument's chain names its subject's parent, so the previous compound is that
          // parent (one element, merged) or, with a descendant combinator, an ancestor above it.
          if (comb !== COMB_CHILD && comb !== COMB_DESCENDANT) return null;
          const merged = mergeCompound(base.subject, links[0].compound);
          // Only one of the two may say what lies above that shared parent.
          if (merged !== null && !(links.length > 1 && base.chain.length > 0)) {
            next.push({
              subject: v.compound,
              chain: [{ ...merged, comb: COMB_CHILD }, ...above, ...base.chain],
              spec: base.spec + v.specificity,
            });
          }
          if (comb === COMB_DESCENDANT) {
            next.push({
              subject: v.compound,
              chain: [...links.map((l) => ({ ...l.compound, comb: l.comb })), { ...base.subject, comb }, ...base.chain],
              spec: base.spec + v.specificity,
            });
          }
          continue;
        }
        if (links[0].comb === COMB_ADJACENT || links[0].comb === COMB_GENERAL) {
          // The argument's chain names a sibling of its subject. A parent or an ancestor of that
          // subject is one of the sibling too, so the previous compound joins the path there.
          if (comb === COMB_CHILD || comb === COMB_DESCENDANT) {
            next.push({
              subject: v.compound,
              chain: [...links.map((l) => ({ ...l.compound, comb: l.comb })), { ...base.subject, comb }, ...base.chain],
              spec: base.spec + v.specificity,
            });
            continue;
          }
          // Two sibling combinators on the same side: only an adjacent one before a general one
          // pins the two to the same element.
          if (links[0].comb === COMB_ADJACENT && comb === COMB_ADJACENT) {
            const merged = mergeCompound(base.subject, links[0].compound);
            if (merged === null) continue;
            if (above.length > 0 && base.chain.length > 0) return null;
            next.push({
              subject: v.compound,
              chain: [{ ...merged, comb: COMB_ADJACENT }, ...above, ...base.chain],
              spec: base.spec + v.specificity,
            });
            continue;
          }
          if (links[0].comb === COMB_ADJACENT && comb === COMB_GENERAL) {
            const merged = mergeCompound(base.subject, links[0].compound);
            if (merged !== null && !(above.length > 0 && base.chain.length > 0)) {
              next.push({
                subject: v.compound,
                chain: [{ ...merged, comb: COMB_ADJACENT }, ...above, ...base.chain],
                spec: base.spec + v.specificity,
              });
            }
            next.push({
              subject: v.compound,
              chain: [...links.map((l) => ({ ...l.compound, comb: l.comb })), { ...base.subject, comb: COMB_GENERAL }, ...base.chain],
              spec: base.spec + v.specificity,
            });
            continue;
          }
          return null;
        }
        if (links[0].comb === COMB_DESCENDANT) {
          // The argument's chain names an ancestor of its subject, and the previous compound is
          // another ancestor. Their order is open — one above the other, or the same element —
          // so each arrangement is a selector of its own.
          if (comb !== COMB_DESCENDANT) return null;
          if (links.length > 1 && base.chain.length > 0) return null;
          const merged = mergeCompound(base.subject, links[0].compound);
          if (merged !== null) {
            next.push({
              subject: v.compound,
              chain: [{ ...merged, comb: COMB_DESCENDANT }, ...above, ...base.chain],
              spec: base.spec + v.specificity,
            });
          }
          // The argument's ancestor above the previous compound.
          next.push({
            subject: v.compound,
            chain: [...links.map((l) => ({ ...l.compound, comb: l.comb })), { ...base.subject, comb: COMB_DESCENDANT }, ...base.chain],
            spec: base.spec + v.specificity,
          });
          // The previous compound above the argument's ancestor.
          next.push({
            subject: v.compound,
            chain: [{ ...base.subject, comb: COMB_DESCENDANT }, ...links.map((l) => ({ ...l.compound, comb: l.comb })), ...base.chain],
            spec: base.spec + v.specificity,
          });
          continue;
        }
        // The argument's ancestor could be the compound before, above it, or between the two
        // combinators' meanings; a chain can say only one, so the selector stays unsupported.
        return null;
      }
    }
    combos = next;
    if (combos.length > 64) return null;
  }
  if (specOut !== undefined) specOut.spec = specSum;
  const out: Selector[] = [];
  for (const combo of combos) {
    if (combo.subject === null) continue;
    if ((combo.subject.host === true || combo.subject.slotted === true) && combo.chain.length > 0) return null;
    out.push({ ...combo.subject, chain: combo.chain, specificity: combo.spec, pseudo, pseudoName, text });
  }
  return out;
}

/** Parses the An+B argument of :nth-child() (integer, odd, even, or An+B), as [A, B]. */
function parseNth(arg: string): number[] | null {
  const s = arg.trim().toLowerCase();
  if (s === "odd") return [2, 1];
  if (s === "even") return [2, 0];
  if (/^[-+]?\d+$/.test(s)) return [0, parseInt(s, 10)];
  const m = /^([-+]?)(\d*)n(?:\s*([-+])\s*(\d+))?$/.exec(s);
  if (!m) return null;
  const a = m[2] === "" ? 1 : parseInt(m[2], 10);
  const sign = m[1] === "-" ? -a : a;
  const b = m[3] === undefined ? 0 : parseInt(m[4], 10) * (m[3] === "-" ? -1 : 1);
  return [sign, b];
}

// ---------------------------------------------------------------------------
// Declarations

export type Loc = (offset: number) => [number, number];
