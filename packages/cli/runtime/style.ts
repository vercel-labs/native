// Computed style. The cascade order and all value parsing were done at build time; here we only
// check class/state conditions, apply inheritance and resolve em units.

import * as P from "../shared/props.ts";
import { parseCounterList } from "../shared/css/lists.ts";
import type { ParsedCounter } from "../shared/css/lists.ts";
import {
  BUILTIN_STYLES, KEYWORD_STYLE_NAMES, decodeCounterStyle, formatCounter, resolveCounterStyle,
} from "../shared/css/counter-styles.ts";
import type { CounterStyleSpec, StyleLookup } from "../shared/css/counter-styles.ts";
import { firstLetterLength } from "../shared/css/first-letter.ts";
import { contentText } from "../shared/css/content.ts";
import type { CounterLookup } from "../shared/css/content.ts";
import { COMB_ADJACENT, COMB_CHILD, COMB_DESCENDANT, COMB_GENERAL } from "../shared/css/types.ts";
import type { ChainLink, Compound, ContentContext, Decl, Selector } from "../shared/css/types.ts";
import { compoundStates, parseSelector, splitTopLevel, tagMatches } from "../shared/css/selectors.ts";
import { compileValue } from "../shared/css/declarations.ts";
import { SYSTEM_COLOR_PREFIX, hasDeferredCurrentColor, imageForm, modernColorForm, resolveCurrentColor, resolveLightDark, withSystemColors } from "../shared/css/colors.ts";
import { gradientCss } from "../shared/css/gradients.ts";
import { colorText, systemColorText } from "./system-colors.ts";
import { evalExpr, exprHasCq, exprHasPercent } from "../shared/css/length-exprs.ts";
import { longhandIds } from "../shared/css/shorthands.ts";
import { hasVar, substituteVars, wideKeyword } from "../shared/css/vars.ts";
import { fitsSyntax } from "../shared/css/syntax.ts";
import { buttonInputType, document, Element, Text, materializeText, newElementFor, refreshFormState, langOf, slotAssignedNodes, slotsIn, ShadowRoot } from "./dom.ts";
import { textRunDependence } from "./text-runs.ts";
import { animatedFontSize, elementMoves, noteComputed } from "./animation.ts";
import { rootFontSize } from "./root-size.ts";
import { INITIAL_V, INITIAL_U, INHERITS } from "./initial-values.ts";
import { incremental, invalidateStyle, invalidateStyleOf, noteLayoutInputs, noteQueriedContainer, queriedContainers, textVersion, setRestyleRootFor, setSubtreeRestyleCheck, startUnsupportedCount, takeIdentityChange } from "./invalidation.ts";
import type { IdentityChange } from "./invalidation.ts";
import type { Node } from "./dom.ts";
import { hostBackingScale, hostFontAscentDevice, hostFontDescentDevice, hostFontLineGapDevice, hostRegisterFeatures } from "./host.ts";
import { mediaMatches } from "./media.ts";
import { containerMatches } from "./container.ts";
import { hintDecls } from "./hints.ts";
import { ADOPTED, getSheetFonts, refreshSheet, runtimeRulesExist, runtimeRulesReachBeyond, setCompiledSheetMediaSink, setCompiledSheetOffSink, setCounterStyleSink, setSheetContent, sheetLayerRank, sheetLayerTotal } from "./sheets.ts";
import type { CSSStyleSheet, SheetRule } from "./sheets.ts";
import { registrationCount, registeredProperty, registrations } from "./registered.ts";
import { viewport } from "./viewport.ts";
import { frameTimes } from "./frame-times.ts";

export class StyleTables {
  ruleClasses: string[][] = [];
  ruleStates: number[] = [];
  /** True for a rule whose declarations set a custom property (or hold a var()). */
  ruleCustoms: boolean[] = [];
  ruleNthStart: number[][] = [];
  ruleNthEnd: number[][] = [];
  /** The "of S" filter of each :nth-child() condition, in the same order ("" for none). */
  ruleNthStartOf: string[][] = [];
  ruleNthEndOf: string[][] = [];
  /** :lang() conditions on each rule's subject compound (empty for none). */
  ruleLang: string[][] = [];
  ruleAttrs: string[][] = [];
  ruleNots: string[][] = [];
  /** :not() arguments that are complex selectors, matched as selectors of their own. */
  ruleNotSels: string[][] = [];
  /** :has() conditions on each rule's subject compound (see Compound.has). */
  ruleHas: string[][] = [];
  /** True for a rule whose subject compound is :empty. */
  ruleEmpty: boolean[] = [];
  /** True for a rule whose subject is :root, which only the document's root element matches. */
  ruleRoot: boolean[] = [];
  ruleDir: number[] = [];
  ruleDecls: number[][] = [];
  /** True for rules that hold only !important declarations; they apply after inline styles. */
  ruleImportant: boolean[] = [];
  /** True for a rule from the UA sheet, whose declarations a revert rolls back to. */
  ruleUa: boolean[] = [];
  /** The pseudo-element kind a rule styles (PE_*); its conditions test the parent element. */
  rulePseudo: number[] = [];
  /** The author sheet each rule came from (-1 for the UA sheet), and each sheet-owning node's. */
  ruleSheet: number[] = [];
  nodeSheet: number[] = [];
  /** The media condition each sheet carries (a <style>/<link> media attribute), or "". */
  sheetMedia: string[] = [];
  /** Whether each sheet starts out disabled (a link disabled attribute), applied at mount. */
  sheetDisabled: boolean[] = [];
  /** The @media condition a rule is inside, or "" outside any; re-evaluated when the window is resized. */
  ruleMedia: string[] = [];
  /** The @container condition a rule is inside, or "": tested against the element's ancestors. */
  ruleContainer: string[] = [];
  /** The @scope prelude a rule is inside, or "" (see ruleInScope). */
  ruleScope: string[] = [];
  /** True for a rule inside @starting-style (see el.starting). */
  ruleStarting: boolean[] = [];
  /** True for a presentation-attribute slot, whose declarations come from the element (hints.ts). */
  ruleHint: boolean[] = [];
  /** Container name lists, one row per container-name value (see shared/css/properties/contain.ts). */
  /** The will-change lists: one row of property ids (or keyword sentinels) per value. */
  willChangeLists: number[][] = [];
  containerNames: string[] = [];
  chainComb: number[][] = [];
  chainTag: string[][] = [];
  chainId: string[][] = [];
  chainRoot: boolean[][] = [];
  chainClasses: string[][][] = [];
  chainStates: number[][] = [];
  chainNthStart: number[][][] = [];
  chainNthEnd: number[][][] = [];
  chainNthStartOf: string[][][] = [];
  chainNthEndOf: string[][][] = [];
  /** :lang() conditions on each ancestor link's compound. */
  chainLang: string[][][] = [];
  /** :dir(ltr|rtl) conditions on ancestor compounds: 1 for ltr, 2 for rtl, 0 for none. */
  chainDir: number[][] = [];
  chainAttrs: string[][][] = [];
  chainNots: string[][][] = [];
  chainNotSels: string[][][] = [];
  chainHas: string[][][] = [];
  /** True for each ancestor link whose compound is :empty. */
  chainEmpty: boolean[][] = [];
  chainStateMask: number = 0;
  dynTags: string[] = [];
  dynIds: string[] = [];
  dynRules: number[] = [];
  /** The pseudo-element kind of each dynamic rule (parallel to dynRules). */
  dynPseudo: number[] = [];
  /** The item lists behind `content` (see shared/css/content.ts). */
  contentItems: string[] = [];
  /** The counter lists behind counter-reset/-increment/-set. */
  counterItems: string[] = [];
  /** The @counter-style rules, as encoded rows, and the names one may be given. */
  counterStyles: string[] = [];
  counterStyleNames: string[] = [];
  /** @font-face family names, in FF_CUSTOM id order, for values parsed at runtime. */
  fontFamilies: string[] = [];
  /** The ordered family ids of each font-family list (FONT_FAMILY_LISTS rows). */
  fontFamilyLists: string[] = [];
  /** Each FONT_FILES face's unicode-range as `lo-hi` pairs, "" for all. */
  fontFaceRanges: string[] = [];
  /** Each face's own OpenType feature settings and font-stretch percentage. */
  fontFaceFeatures: string[] = [];
  fontFaceStretches: number[] = [];
  /** Each face's ascent, descent and line-gap overrides, as fractions; -1 for normal. */
  fontFaceAscents: number[] = [];
  fontFaceDescents: number[] = [];
  fontFaceLineGaps: number[] = [];
  /** Families left to the system, in id order after the @font-face ones. */
  fontInstalledFamilies: string[] = [];
  /** Declarations kept as text: a custom property, or a value that uses var() (see vars.ts). */
  textDeclProps: string[] = [];
  textDeclValues: string[] = [];
}

export const tables: StyleTables = new StyleTables();

/** [1-based position among element siblings, number of element siblings], optionally by tag. */
function siblingPosition(el: Node, ofType: boolean): number[] {
  const p = el.parentElement;
  if (p === null) return [1, 1]; // the root element is the only child of the document
  const tag = el.localName;
  let count = 0;
  let at = 0;
  for (const c of p.kids) {
    // A generated box isn't a sibling for counting, just as ::before isn't in a browser.
    if (!c.isElementNode || c.pseudoKind !== P.PE_NONE) continue;
    if (ofType && c.localName !== tag) continue;
    count++;
    if (c === el) at = count;
  }
  return [at, count];
}

/** Does 1-based index `i` satisfy :nth-child(An+B)? */
function nthMatches(i: number, a: number, b: number): boolean {
  if (a === 0) return i === b;
  const d = i - b;
  if (a > 0 ? d < 0 : d > 0) return false;
  return d % a === 0;
}

/** The selectors of each "of S" filter, parsed once (null when the text doesn't parse). */
const nthOfCache = new Map<string, Selector[] | null>();

/**
 * [1-based position among the siblings matching `filter`, number of them]. Position 0 means the
 * element itself doesn't match, in which case the condition can't hold.
 */
function filteredPosition(el: Element, filter: string): number[] {
  let sels = nthOfCache.get(filter);
  if (sels === undefined) {
    const all: Selector[] = [];
    let ok = true;
    for (const part of splitTopLevel(filter, ",")) {
      const list = parseSelector(part.trim());
      if (list === null) { ok = false; break; }
      for (const sel of list) all.push(sel);
    }
    sels = ok ? all : null;
    nthOfCache.set(filter, sels);
  }
  const p = el.parentElement;
  if (p === null || sels === null) return [0, 0];
  let count = 0;
  let at = 0;
  for (const c of p.kids) {
    if (!c.isElementNode || c.pseudoKind !== P.PE_NONE) continue;
    let fits = false;
    for (const sel of sels) if (selectorMatches(c as Element, sel, null)) { fits = true; break; }
    if (!fits) continue;
    count++;
    if (c === el) at = count;
  }
  return [at, count];
}

/** Selector texts met while matching (:not() arguments, "of S" filters): parsed once. */
const selsCache = new Map<string, Selector[] | null>();

/** Does the element match the selector `text`? A text that doesn't parse matches nothing. */
function selectorArgMatches(el: Element, text: string): boolean {
  let sels = selsCache.get(text);
  if (sels === undefined) {
    sels = parseSelector(text);
    selsCache.set(text, sels);
  }
  if (sels === null) return false;
  for (const sel of sels) if (selectorMatches(el, sel, null)) return true;
  return false;
}

/**
 * The :nth-child()/:nth-last-child() conditions of one compound, from the start and the end.
 * Each list holds triplets [A, B, ofType]; a compound can carry more than one. `startOf`/`endOf`
 * hold the "of S" filter of each condition, aligned with the triplets ("" for none).
 */
const NO_OF: readonly string[] = [];
const NO_LANG: readonly string[] = [];

function nthApplies(el: Element, start: readonly number[], end: readonly number[],
  startOf: readonly string[] = NO_OF, endOf: readonly string[] = NO_OF): boolean {
  for (let k = 0, j = 0; k + 2 < start.length; k += 3, j++) {
    const filter = j < startOf.length ? startOf[j] : "";
    const pos = filter === "" ? siblingPosition(el, start[k + 2] === 1) : filteredPosition(el, filter);
    if (pos[0] === 0 || !nthMatches(pos[0], start[k], start[k + 1])) return false;
  }
  for (let k = 0, j = 0; k + 2 < end.length; k += 3, j++) {
    const filter = j < endOf.length ? endOf[j] : "";
    const pos = filter === "" ? siblingPosition(el, end[k + 2] === 1) : filteredPosition(el, filter);
    if (pos[0] === 0 || !nthMatches(pos[1] - pos[0] + 1, end[k], end[k + 1])) return false;
  }
  return true;
}

/** The element's language, as the rest of the engine reads it (see langOf). */
function elementLanguage(el: Element): string {
  return langOf(el);
}

/**
 * Does one CSS :lang() range match a language tag? The range's subtags have to appear in order
 * among the tag's (RFC 4647 extended filtering), so `fr-FR` matches `fr-Latn-FR` and `*` stands
 * for any one subtag. A tag with a malformed subtag names no language at all.
 */
function langRangeMatches(have: string, want: string): boolean {
  const hs = have.toLowerCase().split("-");
  for (const sub of hs) if (!/^[a-z0-9]{1,8}$/.test(sub)) return false;
  if (want === "*") return true;
  const ws = want.split("-");
  let j = 0;
  for (let i = 0; i < hs.length && j < ws.length; i++) {
    if (ws[j] === "*" || ws[j] === hs[i]) { j++; continue; }
    // A one-letter subtag starts a private-use or extension sequence, which only a range that
    // names it can match: `fr-standard` does not reach "fr-x-standard".
    if (hs[i].length === 1) return false;
  }
  return j === ws.length;
}

/** Does the element's language match one of a compound's :lang() ranges? */
function langApplies(el: Element, langs: readonly string[]): boolean {
  if (langs.length === 0) return true;
  const have = elementLanguage(el);
  if (have === "") return false;
  for (const w of langs) if (langRangeMatches(have, w)) return true;
  return false;
}

const ATTR_SEP = "\u0002";
const NOT_SEP = "\u0001";

/** True when `text` holds a space or a control separator, so it can't be one word. */
function hasWhitespace(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c === 32 || c === 9 || c === 10 || c === 13 || c === 12) return true;
  }
  return false;
}

/** True when `text` holds `word` as one whitespace-separated word, without splitting the text. */
function hasWord(text: string, word: string): boolean {
  const n = text.length;
  const wn = word.length;
  let i = 0;
  while (i < n) {
    // Skip separators.
    while (i < n) {
      const c = text.charCodeAt(i);
      if (c !== 32 && c !== 9 && c !== 10 && c !== 13 && c !== 12) break;
      i++;
    }
    // Compare the word that starts here.
    let k = 0;
    while (i < n && k < wn) {
      const c = text.charCodeAt(i);
      if (c === 32 || c === 9 || c === 10 || c === 13 || c === 12) break;
      if (c !== word.charCodeAt(k)) break;
      i++;
      k++;
    }
    if (k === wn) {
      // A prefix of a longer word isn't a match.
      if (i >= n) return true;
      const c = text.charCodeAt(i);
      if (c === 32 || c === 9 || c === 10 || c === 13 || c === 12) return true;
    }
    // Skip the rest of this word.
    while (i < n) {
      const c = text.charCodeAt(i);
      if (c === 32 || c === 9 || c === 10 || c === 13 || c === 12) break;
      i++;
    }
  }
  return false;
}

/** The compounds of an encoded :not() condition, tokenized once: the encoding is compile-time
 *  text, so the split is cached by the string rather than repeated for every element. */
const notTokens: Map<string, string[]> = new Map();

function notTokensOf(enc: string): string[] {
  const hit = notTokens.get(enc);
  if (hit !== undefined) return hit;
  const out = enc.split(NOT_SEP);
  if (notTokens.size > 512) notTokens.clear();
  notTokens.set(enc, out);
  return out;
}

/**
 * HTML's attributes whose values a selector matches ASCII case-insensitively (HTML's
 * "case-sensitivity of selectors" list): in an HTML document `[lang|=es]` matches `lang="ES"`.
 * The `s` flag makes the test case-sensitive again, and an XML document is case-sensitive always.
 */
const HTML_CI_ATTRS = new Set([
  "accept", "accept-charset", "align", "alink", "axis", "bgcolor", "charset", "checked", "clear",
  "codetype", "color", "compact", "declare", "defer", "dir", "direction", "disabled", "enctype",
  "face", "frame", "hreflang", "http-equiv", "lang", "language", "link", "media", "method",
  "multiple", "nohref", "noresize", "noshade", "nowrap", "readonly", "rel", "rev", "rules",
  "scope", "scrolling", "selected", "shape", "target", "text", "type", "valign", "valuetype", "vlink",
]);

/** Does this attribute's value match case-insensitively by default on this element? */
function attrDefaultsInsensitive(el: Element, name: string): boolean {
  return el.namespaceURI === "http://www.w3.org/1999/xhtml" && HTML_CI_ATTRS.has(name);
}

/**
 * Does the element satisfy one attribute condition, encoded at build time as
 * "name<sep>op[flag]<sep>value" (an empty op = the attribute is present)? The "i" flag compares
 * case-insensitively, the "s" flag case-sensitively, and with neither flag the attribute's own
 * default decides.
 */
function attrMatches(el: Element, enc: string): boolean {
  const a = enc.indexOf(ATTR_SEP);
  const b = enc.indexOf(ATTR_SEP, a + 1);
  const name = enc.slice(0, a);
  const opWithFlag = enc.slice(a + 1, b);
  const want = enc.slice(b + 1);
  const have = el.getAttribute(name);
  if (have === null) return false;
  if (opWithFlag === "") return true;
  const op = opWithFlag.charAt(0);
  const flag = opWithFlag.slice(1);
  const ci = flag === "i" || (flag === "" && attrDefaultsInsensitive(el, name));
  const h = ci ? have.toLowerCase() : have;
  const w = ci ? want.toLowerCase() : want;
  if (op === "=") return h === w;
  if (op === "~") {
    // A whitespace-separated word list; an empty or multi-word value matches nothing. The walk is
    // done over the string as it stands: a class list is tested against every rule of the page,
    // and splitting it would allocate on each test.
    if (w === "" || hasWhitespace(w)) return false;
    return hasWord(h, w);
  }
  if (w === "") return false; // the remaining operators never match an empty value
  if (op === "|") return h === w || (h.length > w.length && h.slice(0, w.length) === w && h.slice(w.length, w.length + 1) === "-");
  if (op === "^") return h.length >= w.length && h.slice(0, w.length) === w;
  if (op === "$") return h.length >= w.length && h.slice(h.length - w.length) === w;
  if (op === "*") return h.indexOf(w) >= 0;
  return false;
}

/** Does the element match one compound encoded for a :not() condition? */
function encodedMatches(el: Element, enc: string): boolean {
  if (enc === "") return true; // :not(*) matches every element
  // A compound with an "of S" filter carries it in tokens of its own ("f"/"g"), read here so the
  // nth tokens below can count only the siblings the filter matches.
  let startOf: string[] | null = null;
  let endOf: string[] | null = null;
  // One filter carries no separator, so the tokens themselves say whether the pass is needed.
  if (enc.startsWith("f") || enc.startsWith("g") || enc.indexOf("\u0001f") >= 0 || enc.indexOf("\u0001g") >= 0) {
    for (const tok of notTokensOf(enc)) {
      if (tok.charAt(0) === "f") startOf = tok.slice(1).split("\u0004");
      else if (tok.charAt(0) === "g") endOf = tok.slice(1).split("\u0004");
    }
  }
  for (const tok of notTokensOf(enc)) {
    const kind = tok.slice(0, 1);
    const v = tok.slice(1);
    if (kind === "t") {
      if (el.localName !== v) return false;
    } else if (kind === "i") {
      if (el.id !== v) return false;
    } else if (kind === "c") {
      if (!el.classList.contains(v)) return false;
    } else if (kind === "s") {
      const s = Number(v);
      if ((s & P.S_FORM_STATES) !== 0) refreshFormState(el, s);
      if ((s & el.state) !== s) return false;
    } else if (kind === "a" || kind === "z") {
      const c = v.split(",");
      const ofs = kind === "a" ? startOf : endOf;
      for (let j = 0, q = 0; j + 2 < c.length; j += 3, q++) {
        const filter = ofs !== null && q < ofs.length ? ofs[q] : "";
        const pos = filter === "" ? siblingPosition(el, Number(c[j + 2]) === 1) : filteredPosition(el, filter);
        if (pos[0] === 0) return false;
        const i = kind === "a" ? pos[0] : pos[1] - pos[0] + 1;
        if (!nthMatches(i, Number(c[j]), Number(c[j + 1]))) return false;
      }
    } else if (kind === "n") {
      // A :not() argument that is a complex selector: the element must match none of them.
      for (const text of v.split("\u0004")) if (selectorArgMatches(el, text)) return false;
    } else if (kind === "l") {
      if (!langApplies(el, v.split(","))) return false;
    } else if (kind === "x") {
      if (!attrMatches(el, v)) return false;
    } else if (kind === "e") {
      if (!isEmptyElement(el)) return false;
    } else if (kind === "h") {
      if (!hasApplies(el, [v])) return false;
    }
  }
  return true;
}

/** Is the element outside all of a compound's :not() arguments? */
function notsApply(el: Element, nots: readonly string[]): boolean {
  for (const n of nots) if (encodedMatches(el, n)) return false;
  return true;
}

// --- :has() -----------------------------------------------------------------
// Each argument is a relative selector: a combinator, \u0003, then the selector's text. The
// element has to have at least one match for one of them: a descendant, child, or sibling that
// matches the selector, with the leftmost compound it names standing in that relation to it.

const hasCache = new Map<string, Selector[] | null>();

/** A :has() argument's selector, parsed once per sheet load. */
function parsedHas(body: string): Selector[] | null {
  const hit = hasCache.get(body);
  if (hit !== undefined) return hit;
  const v = parseSelector(body);
  hasCache.set(body, v);
  return v;
}

/** Does the element have a relative match for one of the compound's :has() arguments? */
function hasApplies(el: Element, list: readonly string[]): boolean {
  for (const raw of list) {
    const at = raw.indexOf("\u0003");
    const lead = at < 0 ? "" : raw.slice(0, at);
    const body = at < 0 ? raw : raw.slice(at + 1);
    const comb = lead === ">" ? COMB_CHILD : lead === "+" ? COMB_ADJACENT
      : lead === "~" ? COMB_GENERAL : COMB_DESCENDANT;
    if (hasOne(el, comb, body)) return true;
  }
  return list.length === 0;
}

function hasOne(anchor: Element, comb: number, body: string): boolean {
  const sels = parsedHas(body);
  if (sels === null) return false;
  const tryAt = (c: Element): boolean => {
    for (const sel of sels) {
      if (!compoundFits(c, sel)) continue;
      if (chainFitsAnchor(sel.chain, 0, c, anchor, comb)) return true;
    }
    return false;
  };
  if (comb === COMB_ADJACENT) {
    // The subject has to be inside the next sibling or a later one: an argument's own `+`/`~`
    // combinators can walk on past the next sibling (`:has(+ .a + .b)`), and `relatedTo` still
    // requires the leftmost compound to be that next sibling.
    for (let s = anchor.nextElementSibling; s !== null; s = s.nextElementSibling) {
      if (subtreeMatches(s, tryAt)) return true;
    }
    return false;
  }
  if (comb === COMB_GENERAL) {
    for (let s = anchor.nextElementSibling; s !== null; s = s.nextElementSibling) {
      if (subtreeMatches(s, tryAt)) return true;
    }
    return false;
  }
  let found = false;
  const walk = (n: Node): void => {
    if (found) return;
    if (n instanceof Element) {
      if (tryAt(n)) { found = true; return; }
      for (const kid of n.kids) walk(kid);
    }
  };
  for (const kid of anchor.kids) walk(kid);
  return found;
}

/** Whether `el` or anything below it matches `f`. */
function subtreeMatches(el: Element, f: (c: Element) => boolean): boolean {
  if (f(el)) return true;
  for (const kid of el.kids) if (kid instanceof Element && subtreeMatches(kid, f)) return true;
  return false;
}

/** Does `el` stand to `anchor` in the relation the argument's leading combinator names? */
function relatedTo(el: Element, anchor: Element, comb: number): boolean {
  if (comb === COMB_CHILD) return el.parentElement === anchor;
  if (comb === COMB_ADJACENT) return el.previousElementSibling === anchor;
  if (comb === COMB_GENERAL) {
    for (let s = el.previousElementSibling; s !== null; s = s.previousElementSibling) if (s === anchor) return true;
    return false;
  }
  for (let p = el.parentElement; p !== null; p = p.parentElement) if (p === anchor) return true;
  return false;
}

/** The chain the argument names, ending with the leftmost compound's relation to the anchor. */
function chainFitsAnchor(chain: ChainLink[], k: number, el: Element, anchor: Element, comb: number): boolean {
  if (k === chain.length) return relatedTo(el, anchor, comb);
  const c = chain[k].comb;
  if (c === COMB_ADJACENT) {
    const s = el.previousElementSibling;
    return s !== null && compoundFits(s, chain[k]) && chainFitsAnchor(chain, k + 1, s, anchor, comb);
  }
  if (c === COMB_GENERAL) {
    for (let s = el.previousElementSibling; s !== null; s = s.previousElementSibling) {
      if (compoundFits(s, chain[k]) && chainFitsAnchor(chain, k + 1, s, anchor, comb)) return true;
    }
    return false;
  }
  let a = el.parentElement;
  while (a !== null) {
    if (compoundFits(a, chain[k]) && chainFitsAnchor(chain, k + 1, a, anchor, comb)) return true;
    if (c === COMB_CHILD) return false;
    a = a.parentElement;
  }
  return false;
}

function linkMatches(rule: number, k: number, el: Element): boolean {
  const tag = tables.chainTag[rule][k];
  if (tag !== "" && tag !== el.localName) return false;
  const id = tables.chainId[rule][k];
  if (id !== "" && id !== el.id) return false;
  if (tables.chainRoot[rule][k] && el !== document.documentElement) return false;
  const states = tables.chainStates[rule][k];
  if ((states & P.S_FORM_STATES) !== 0) refreshFormState(el, states);
  if ((states & el.state) !== states) return false;
  const chainStartOf = rule < tables.chainNthStartOf.length && k < tables.chainNthStartOf[rule].length
    ? tables.chainNthStartOf[rule][k] : NO_OF;
  const chainEndOf = rule < tables.chainNthEndOf.length && k < tables.chainNthEndOf[rule].length
    ? tables.chainNthEndOf[rule][k] : NO_OF;
  if (!nthApplies(el, tables.chainNthStart[rule][k], tables.chainNthEnd[rule][k], chainStartOf, chainEndOf)) return false;
  for (const c of tables.chainClasses[rule][k]) if (!el.classList.contains(c)) return false;
  for (const a of tables.chainAttrs[rule][k]) if (!attrMatches(el, a)) return false;
  if (!langApplies(el, rule < tables.chainLang.length && k < tables.chainLang[rule].length
    ? tables.chainLang[rule][k] : NO_LANG)) return false;
  const chainDir = rule < tables.chainDir.length && k < tables.chainDir[rule].length ? tables.chainDir[rule][k] : 0;
  if (chainDir !== 0 && elementDirection(el) + 1 !== chainDir) return false;
  if (rule < tables.chainEmpty.length && k < tables.chainEmpty[rule].length && tables.chainEmpty[rule][k] && !isEmptyElement(el)) return false;
  if (!notsApply(el, tables.chainNots[rule][k])) return false;
  if (rule < tables.chainNotSels.length && k < tables.chainNotSels[rule].length) {
    for (const t of tables.chainNotSels[rule][k]) if (selectorArgMatches(el, t)) return false;
  }
  if (!hasApplies(el, tables.chainHas[rule][k])) return false;
  return true;
}

/** Right-to-left combinator matching with backtracking over descendant and sibling combinators. */
function chainMatches(rule: number, k: number, el: Element): boolean {
  const n = tables.chainComb[rule].length;
  if (k === n) return true;
  const comb = tables.chainComb[rule][k];
  if (comb === COMB_ADJACENT) {
    const s = el.previousElementSibling;
    return s !== null && linkMatches(rule, k, s) && chainMatches(rule, k + 1, s);
  }
  if (comb === COMB_GENERAL) {
    let s = el.previousElementSibling;
    while (s !== null) {
      if (linkMatches(rule, k, s) && chainMatches(rule, k + 1, s)) return true;
      s = s.previousElementSibling;
    }
    return false;
  }
  let a = el.parentElement;
  while (a !== null) {
    if (linkMatches(rule, k, a) && chainMatches(rule, k + 1, a)) return true;
    if (comb === COMB_CHILD) return false;
    a = a.parentElement;
  }
  return false;
}

/** The dynamic rule table indexed by the class its subject names, so a new element looks at
 *  the rules its own classes name instead of the whole table. A page whose elements are built
 *  by script (a UI kit, a list rendered a few rows a frame) asks this for every element. */
let dynIndexFor: number[] | null = null;
let dynByClass: Map<string, number[]> = new Map();
let dynNoClass: number[] = [];
let dynSeen: Int32Array = new Int32Array(0);
let dynStamp = 0;
let dynCandidates: number[] = [];

/** Builds the class index once per compiled rule table. */
function dynIndex(): void {
  const dynRules = tables.dynRules;
  if (dynIndexFor === dynRules) return;
  dynIndexFor = dynRules;
  dynByClass = new Map();
  dynNoClass = [];
  dynSeen = new Int32Array(dynRules.length);
  dynStamp = 0;
  for (let i = 0; i < dynRules.length; i++) {
    const classes = tables.ruleClasses[dynRules[i]];
    if (classes.length === 0) {
      dynNoClass.push(i);
      continue;
    }
    for (let c = 0; c < classes.length; c++) {
      let list = dynByClass.get(classes[c]);
      if (list === undefined) {
        list = [];
        dynByClass.set(classes[c], list);
      }
      list.push(i);
    }
  }
}

/** Adds a table index to this element's candidates once, however many of its classes name it. */
function addCandidate(i: number): void {
  if (dynSeen[i] === dynStamp) return;
  dynSeen[i] = dynStamp;
  dynCandidates.push(i);
}

function resolveDynamicRules(el: Element): void {
  // Rules from the compiled selector table whose tag and id fit this element. Classes and
  // pseudo-states stay per-rule conditions, exactly as at build time.
  dynIndex();
  dynStamp++;
  const candidates = dynCandidates;
  candidates.length = 0;
  // A rule that names no class can match on its tag or id alone; one that names classes is
  // reached through the classes the element actually has.
  for (let i = 0; i < dynNoClass.length; i++) addCandidate(dynNoClass[i]);
  const names = el.classList.tokens();
  for (let k = 0; k < names.length; k++) {
    const list = dynByClass.get(names[k]);
    if (list === undefined) continue;
    for (let i = 0; i < list.length; i++) addCandidate(list[i]);
  }
  const rules: number[] = [];
  const before: number[] = [];
  const after: number[] = [];
  const marker: number[] = [];
  const placeholder: number[] = [];
  const carriers = new Map<number, number[]>();
  let states = 0;
  for (let c = 0; c < candidates.length; c++) {
    const i = candidates[c];
    const tag = tables.dynTags[i];
    const id = tables.dynIds[i];
    if (tag !== "" && tag !== el.localName) continue;
    if (id !== "" && id !== el.id) continue;
    const r = tables.dynRules[i];
    const pseudo = tables.dynPseudo[i];
    if (pseudo === P.PE_NONE) rules.push(r);
    else if (pseudo === P.PE_BEFORE) before.push(r);
    else if (pseudo === P.PE_AFTER) after.push(r);
    else if (pseudo === P.PE_PLACEHOLDER) placeholder.push(r);
    else if (pseudo === P.PE_MARKER) marker.push(r);
    else {
      // A ::selection, ::target-text, ::first-line or ::first-letter rule: the carrier box takes
      // it, and is made here when the rule only starts matching now.
      let list = carriers.get(pseudo);
      if (list === undefined) {
        list = [];
        carriers.set(pseudo, list);
      }
      list.push(r);
    }
    states |= tables.ruleStates[r];
  }
  el.rules = rules;
  el.sensitiveStates = states;
  el.setPseudoRules(P.PE_BEFORE, before);
  el.setPseudoRules(P.PE_AFTER, after);
  el.setPseudoRules(P.PE_PLACEHOLDER, placeholder);
  for (const [pseudo, list] of carriers) el.setCarrierRules(pseudo, list);
  // A marker box is made only when the element turns out to be a list item, so its rules wait.
  el.markerRules = marker;
  if (el.markerPseudo !== null) el.markerPseudo.rules = marker;
  el.rulesStale = false;
  el.carriersDone = true;
}

// The px size of `medium`. Browsers give the generic monospace family its own, smaller size.
const MEDIUM = 16;
const MONO_MEDIUM = 13;

// ---------------------------------------------------------------------------
// Counter styles (shared/css/counter-styles.ts)

/** Every style the page can name, by name: the built-in ones, then the page's own rules. */
const counterStyleSpecs = new Map<string, CounterStyleSpec>();
let counterStylesReady = false;

/** Forgets the page's styles, so the next page in a batch starts with the built-in ones only. */
export function resetCounterStyles(): void {
  counterStyleSpecs.clear();
  counterStylesReady = false;
}

// A runtime sheet's @counter-style rule registers its style here; a rewrite or a removed rule
// takes it back, leaving the built-in one of that name in place when there is one.
setCounterStyleSink(
  (spec) => {
    ensureCounterStyles();
    const resolved = resolveCounterStyle(spec, (n) => counterStyleSpecs.get(n.toLowerCase()) ?? null);
    counterStyleSpecs.set(spec.name, resolved ?? spec);
  },
  (name) => {
    const builtin = BUILTIN_STYLES.find((b) => b.name === name);
    if (builtin !== undefined) counterStyleSpecs.set(name, builtin);
    else counterStyleSpecs.delete(name);
  },
);

function ensureCounterStyles(): void {
  if (counterStylesReady) return;
  counterStylesReady = true;
  for (const s of BUILTIN_STYLES) counterStyleSpecs.set(s.name, s);
  for (const row of tables.counterStyles) {
    const spec = decodeCounterStyle(row);
    if (spec !== null) counterStyleSpecs.set(spec.name, spec);
  }
  // A style that extends another takes the descriptors its rule left out from the base; the
  // chain is resolved once every name is known, so a rule may extend one defined after it.
  for (const [name, spec] of counterStyleSpecs) {
    if (spec.system !== "extends") continue;
    const resolved = resolveCounterStyle(spec, (n) => counterStyleSpecs.get(n.toLowerCase()) ?? null);
    if (resolved !== null) counterStyleSpecs.set(name, resolved);
  }
}

const styleLookup: StyleLookup = (name: string): CounterStyleSpec | null => {
  ensureCounterStyles();
  return counterStyleSpecs.get(name.toLowerCase()) ?? null;
};

/**
 * The style a list-style-type or counter() value names: a built-in id, or -2 - the index of an
 * @counter-style rule's name in the app's table of them. A name that isn't a style falls back to
 * decimal, as an unknown counter style does (CSS Counter Styles 3 §2.2).
 */
function counterStyleForKey(key: number): CounterStyleSpec {
  ensureCounterStyles();
  const name = key >= 0 ? KEYWORD_STYLE_NAMES[key] ?? "decimal"
    : (() => {
      const idx = -2 - key;
      return idx >= 0 && idx < tables.counterStyleNames.length ? tables.counterStyleNames[idx] : "";
    })();
  return counterStyleSpecs.get(name) ?? counterStyleSpecs.get("decimal") ?? BUILTIN_STYLES[4];
}

/**
 * A marker's text: the style's prefix, the counter's representation at the item's ordinal, and
 * its suffix (". " unless the style says otherwise). The suffix's trailing space is the space
 * before the item's text, so it is dropped from an outside marker, which the layout spaces out.
 */
function markerStyleText(key: number, n: number, outside: boolean, rtl: boolean): string {
  const spec = counterStyleForKey(key);
  if (spec.name === "none") return "";
  // The style's suffix is part of the marker text, space and all: it is the gap a browser shows
  // between the marker and the item's text (CSS Counter Styles 3 §3.4). An outside marker is a
  // box beside the item's line, so a plain trailing space would be trimmed as line-end white
  // space; a no-break space keeps the gap there, on the side the item's text takes it: the
  // marker hangs on the right in a right-to-left line, so its gap goes at its start instead.
  const text = spec.prefix + formatCounter(spec, n, styleLookup) + spec.suffix;
  if (!outside || !text.endsWith(" ")) return text;
  const body = text.slice(0, -1);
  return rtl ? "\u00A0" + body : body + "\u00A0";
}

// A runtime sheet's `content` items join the table the build filled, so a generated box reads
// them the same way it reads a compiled rule's. A var() value that resolves to a `content`
// declaration registers its items the same way.
const contentTable: ContentContext = {
  item(encoded: string): number {
    tables.contentItems.push(encoded);
    return tables.contentItems.length - 1;
  },
  counter(encoded: string): number {
    tables.counterItems.push(encoded);
    return tables.counterItems.length - 1;
  },
  counterStyle(name: string): number {
    const lower = name.toLowerCase();
    const at = tables.counterStyleNames.indexOf(lower);
    if (at >= 0) return at;
    tables.counterStyleNames.push(lower);
    return tables.counterStyleNames.length - 1;
  },
};
setSheetContent(contentTable);

// ---------------------------------------------------------------------------
// Custom properties and var() (shared/css/vars.ts)
//
// A declaration that names a custom property, or uses var(), is held as text. The custom
// properties cascade first, inheriting from the parent; then each text declaration is resolved
// against them and compiled with the same parser the build used. A value that doesn't compile
// is invalid at computed-value time, which leaves its property unset.

/** Custom property names are case-sensitive and start with two dashes. */
function isCustom(prop: string): boolean {
  return prop.startsWith("--");
}

/**
 * Records one custom property declaration (a trimmed value) into `out`. `parent` holds the parent
 * element's computed custom properties, which the CSS-wide keywords reach for; a registered
 * property may declare that it doesn't inherit, and may name the initial value it starts from.
 */
function setCustom(out: Map<string, string>, prop: string, value: string,
  parent: Map<string, string> | null): void {
  const text = value.trim();
  const keyword = wideKeyword(text);
  const reg = registeredProperty(prop);
  if (keyword === "inherit" || keyword === "unset") {
    // Both take the parent's value, except on a registered property that declares it doesn't
    // inherit, where `unset` is the initial value instead.
    if (keyword === "unset" && reg !== null && !reg.inherits) {
      if (reg.initialValue !== null) out.set(prop, reg.initialValue);
      else out.set(prop, "");
      return;
    }
    if (parent !== null && parent.has(prop)) out.set(prop, parent.get(prop) as string);
    else if (reg !== null && reg.initialValue !== null) out.set(prop, reg.initialValue);
    else out.delete(prop);
    return;
  }
  // `initial`, `revert` and `revert-layer` mean the initial value, which a registration names and
  // an unregistered custom property doesn't have: it is guaranteed-invalid, which behaves as if
  // the property weren't set at all.
  if (keyword !== "") {
    if (reg !== null && reg.initialValue !== null) out.set(prop, reg.initialValue);
    else out.set(prop, "");
    return;
  }
  // A value of only whitespace is valid and substitutes to nothing; a space stands in for it, so
  // it isn't mistaken for the guaranteed-invalid sentinel.
  out.set(prop, text === "" ? " " : text);
}

/** Substitutes var() through the custom properties, invalidating the names a cycle reaches. */
function resolveCustoms(raw: Map<string, string>, inherited: Map<string, string> | null): Map<string, string> {
  const out = new Map<string, string>();
  if (inherited !== null) for (const [k, v] of inherited) out.set(k, v);
  const done = new Map<string, string>();
  const invalid = new Set<string>();
  const stack: string[] = [];
  const resolve = (name: string): string | null => {
    const hit = done.get(name);
    if (hit !== undefined) return hit;
    if (invalid.has(name)) return null;
    const text = raw.get(name);
    if (text === undefined) {
      const inheritedValue = inherited === null ? undefined : inherited.get(name);
      return inheritedValue === undefined ? null : inheritedValue;
    }
    if (text === "") {
      invalid.add(name);
      return null;
    }
    stack.push(name);
    // A var() that names a property already on the stack closes a cycle: every property in it,
    // including this one, is invalid at computed-value time. The lookup returns nothing for it,
    // but a fallback doesn't rescue a cycle, hence the flag.
    let cycle = false;
    const substituted = substituteVars(text, (n: string) => {
      if (!raw.has(n)) return inherited === null ? undefined : inherited.get(n);
      const at = stack.lastIndexOf(n);
      if (at >= 0) {
        for (let i = at; i < stack.length; i++) invalid.add(stack[i]);
        cycle = true;
        return undefined;
      }
      const v = resolve(n);
      return v === null ? undefined : v;
    });
    stack.pop();
    if (cycle || substituted === null || invalid.has(name)) {
      invalid.add(name);
      return null;
    }
    // A value that comes out as a CSS-wide keyword after substitution behaves as the keyword.
    const keyword = wideKeyword(substituted);
    if (keyword === "inherit" || keyword === "unset") {
      const inheritedValue = inherited === null ? undefined : inherited.get(name);
      if (inheritedValue === undefined) {
        invalid.add(name);
        return null;
      }
      done.set(name, inheritedValue);
      return inheritedValue;
    }
    if (keyword !== "") {
      invalid.add(name);
      return null;
    }
    done.set(name, substituted);
    return substituted;
  };
  for (const name of raw.keys()) {
    const value = resolve(name);
    if (value === null) out.delete(name);
    else out.set(name, value);
  }
  return out;
}

/** The custom properties an element starts from: the parent's, less the ones a registration says
 * don't inherit, plus the initial value of every registered property nothing has set yet. An
 * unregistered custom property always inherits. */
function baseCustoms(parent: Map<string, string> | null): Map<string, string> | null {
  if (registrationCount() === 0) return parent;
  const out = new Map<string, string>();
  if (parent !== null) {
    for (const [k, v] of parent) {
      const reg = registeredProperty(k);
      if (reg === null || reg.inherits) out.set(k, v);
    }
  }
  for (const r of registrations()) {
    if (r.initialValue !== null && !out.has(r.name)) out.set(r.name, r.initialValue);
  }
  return out;
}

/**
 * A registered property's value has to belong to the syntax it declared. One that doesn't is
 * invalid at computed-value time, which leaves the property unset: the parent's value when it
 * inherits and the parent still has one that fits, and otherwise the initial value.
 */
function checkRegistered(out: Map<string, string>, parent: Map<string, string> | null): void {
  for (const r of registrations()) {
    if (r.syntax === "*") continue;
    const value = out.get(r.name);
    if (value === undefined || fitsSyntax(r.syntax, value)) continue;
    const fromParent = r.inherits && parent !== null ? parent.get(r.name) : undefined;
    if (fromParent !== undefined && fitsSyntax(r.syntax, fromParent)) out.set(r.name, fromParent);
    else if (r.initialValue !== null) out.set(r.name, r.initialValue);
    else out.delete(r.name);
  }
}

/**
 * The element's computed custom properties: the parent's, overridden by its own declarations in
 * cascade order (normal rules, runtime sheets and inline style, then the !important ones).
 */
/** The map a subtree with no custom properties of its own shares: nothing writes to it. */
const EMPTY_CUSTOMS: Map<string, string> = new Map();

function collectCustoms(el: Element, runtime: RuntimeMatch[], parent: Node | null): Map<string, string> {
  const fromParent = parent === null ? null : parent.cprops;
  // Nothing this element applies declares a custom property, so its values are its parent's (with
  // a registered property that doesn't inherit replaced by its initial value). Both were settled
  // where they were made, so there is nothing to substitute or re-check.
  if (runtime.length === 0) {
    let own = false;
    const inlineOwn = el.styleDecl;
    if (inlineOwn !== null) {
      for (const d of inlineOwn.decls) {
        if (d.prop !== undefined && isCustom(d.prop)) { own = true; break; }
      }
    }
    if (!own) {
      for (const r of el.rules) {
        if (r < tables.ruleCustoms.length && tables.ruleCustoms[r] && !ruleStandsDown(r)) { own = true; break; }
      }
    }
    if (!own) {
      const base = baseCustoms(fromParent);
      return base !== null ? base : EMPTY_CUSTOMS;
    }
  }
  const inherited = baseCustoms(fromParent);
  const raw = new Map<string, string>();
  const inline = el.styleDecl;
  for (let phase = 0; phase < 2; phase++) {
    const important = phase === 1;
    for (const r of el.rules) {
      if (ruleStandsDown(r)) continue;
      if (tables.ruleImportant[r] !== important) continue;
      if (!ruleApplies(el, r)) continue;
      const d = tables.ruleDecls[r];
      for (let k = 0; k + 2 < d.length; k += 3) {
        if (d[k] >= 0) continue;
        const id = -1 - d[k];
        const prop = tables.textDeclProps[id];
        if (isCustom(prop)) setCustom(raw, prop, tables.textDeclValues[id], fromParent);
      }
    }
    for (const m of runtime) {
      for (const d of m.rule.decls) {
        if ((d.important === true) !== important) continue;
        if (d.prop !== undefined && isCustom(d.prop)) setCustom(raw, d.prop, d.value === undefined ? "" : d.value, fromParent);
      }
    }
    if (inline !== null) {
      for (const d of inline.decls) {
        if (d.important !== important) continue;
        if (d.prop !== undefined && isCustom(d.prop)) setCustom(raw, d.prop, d.value === undefined ? "" : d.value, fromParent);
      }
    }
  }
  const out = resolveCustoms(raw, inherited);
  checkRegistered(out, fromParent);
  return out;
}

/** Compiled text declarations, by property and substituted value. Rows are per mount. */
const compiledTexts: Map<string, { decls: number[] | null; error: string }> = new Map();

/** Forgets the compile cache, which names rows a new page's tables don't have yet. */
export function resetCompiledText(): void {
  compiledTexts.clear();
}

/**
 * A substituted value that doesn't parse is invalid at computed-value time and drops the
 * declaration silently, which leaves the author with nothing to go on. Headless runs and
 * NATIVE_DEBUG report it, once per property and value, naming the text that was substituted.
 */
const warnInvalid = process.env.NATIVE_STEPS !== undefined || process.env.NATIVE_SNAPSHOT !== undefined ||
  process.env.NATIVE_DEBUG !== undefined;

/** The numeric declarations a substituted value compiles to, or null when it is invalid. */
function compiledText(prop: string, value: string): number[] | null {
  const key = prop + "\u0000" + value;
  const hit = compiledTexts.get(key);
  if (hit !== undefined) return hit.decls;
  const out: Decl[] = [];
  const err = compileValue(prop, value, out, getSheetFonts(), undefined, contentTable);
  const decls: number[] | null = err !== null || out.length === 0 ? null : out.flatMap((d) => [d.p, d.v, d.u]);
  compiledTexts.set(key, { decls, error: err === null ? "" : err });
  if (decls === null && warnInvalid) {
    const why = err === null ? "" : ": " + err;
    console.error("native: '" + prop + ": " + value + "' is invalid at computed-value time and is ignored" + why);
  }
  return decls;
}

/** The bitset width of a property set over PROP_COUNT. */
const PROP_WORDS = Math.ceil(P.PROP_COUNT / 32);

function hasPropBit(bits: Uint32Array | null, p: number): boolean {
  return bits !== null && (bits[p >>> 5] & (1 << (p & 31))) !== 0;
}

function setPropBit(bits: Uint32Array, p: number): void {
  bits[p >>> 5] |= 1 << (p & 31);
}

function clearPropBit(bits: Uint32Array, p: number): void {
  bits[p >>> 5] &= ~(1 << (p & 31));
}

/**
 * Notes that the element's own declarations set property `p`. Only a ::placeholder box keeps the
 * record for paint: the field that draws the placeholder text needs to tell a declared colour from
 * an inherited one (see paintInput). Every element remembers its inherited declarations, which
 * tell the inherited-only fast path a child whose own value a moved inherited value can't reach.
 */
function noteDeclared(el: Element, p: number): void {
  if (el.declaredProps !== null) el.declaredProps[p] = 1;
  if (INHERITS[p]) {
    if (el.inhDeclared === null) el.inhDeclared = new Uint32Array(PROP_WORDS);
    setPropBit(el.inhDeclared, p);
  }
}

/** Notes that the element's own declarations are computed from property `p`'s inherited value. */
function noteDependency(el: Element, p: number): void {
  if (el.inhDepends === null) el.inhDepends = new Uint32Array(PROP_WORDS);
  setPropBit(el.inhDepends, p);
}

/** A declaration of `p` that takes its value from the parent rather than naming one. */
function noteFollowsParent(el: Element, p: number): void {
  if (el.inhDeclared !== null) clearPropBit(el.inhDeclared, p);
  noteDependency(el, p);
}

/** The properties that are a background's or a border's, by index; see faceDeclared. */
let faceProps: Uint8Array | null = null;

/**
 * Whether a declaration of `p` is one of the properties that take a widget's box away from the
 * UA: a background or a border, which CSS calls the appearance-disabling properties.
 */
function faceProp(p: number): boolean {
  if (faceProps === null) {
    faceProps = new Uint8Array(P.PROP_COUNT);
    for (let i = 0; i < P.PROP_COUNT; i++) {
      const name = P.PROPERTY_NAMES[i];
      if (name.startsWith("background-") || name.startsWith("border-")) faceProps[i] = 1;
    }
  }
  return faceProps[p] === 1;
}

/** Notes an author declaration of `p`, which may take a widget's box away from the UA. */
function noteFace(el: Element, p: number): void {
  if (!el.faceDeclared && faceProp(p)) el.faceDeclared = true;
}

/**
 * Applies one declaration kept as text: its var() references are substituted, then the value is
 * compiled. A value that is invalid leaves its property (or a shorthand's longhands) unset, as
 * CSS does for a declaration that is invalid at computed-value time.
 */

/**
 * The UA-origin cascaded value of one longhand for `el`, or null when the UA sheet says nothing
 * about it: `revert` (and `revert-layer`, which falls back to the UA when no layer is left)
 * rolls the declaration back to what the UA sheet gives the element. Important UA declarations
 * win over normal ones, as they do in the cascade.
 */
function uaValue(el: Element, p: number): number[] | null {
  let v = -1;
  let u = -1;
  let vi = -1;
  let ui = -1;
  // Only this element's own rules: the build bakes a node's unconditional UA rules into a rule
  // with no selector of its own, which would match anything if the whole table were scanned.
  for (const r of el.rules) {
    if (ruleStandsDown(r)) continue;
    if (!tables.ruleUa[r]) continue;
    if (!ruleApplies(el, r)) continue;
    const important = tables.ruleImportant[r];
    const d = tables.ruleDecls[r];
    for (let k = 0; k + 2 < d.length; k += 3) {
      if (d[k] !== p) continue;
      if (important) { vi = d[k + 1]; ui = d[k + 2]; }
      else { v = d[k + 1]; u = d[k + 2]; }
    }
  }
  if (vi >= 0) return [vi, ui];
  return v >= 0 ? [v, u] : null;
}

/** Notes what a modern colour function's computed value reads back as. */
function rememberColorForm(el: Element, p: number, form: string): void {
  if (el.colorForm === null) el.colorForm = new Map();
  el.colorForm.set(p, form);
}

/** Forgets a property's computed form, as a value with no form of its own has won. */
function forgetColorForm(el: Element, p: number): void {
  if (el.colorForm !== null) el.colorForm.delete(p);
}

/** Notes the unresolved text of a colour property whose value names currentColor. */
function rememberColorText(el: Element, p: number, value: string): void {
  if (el.colorText === null) el.colorText = new Map();
  el.colorText.set(p, value);
}

/** Forgets a property's unresolved text, as a value that resolved it has won. */
function forgetColorText(el: Element, p: number): void {
  if (el.colorText !== null) el.colorText.delete(p);
}

/** The declarations whose value needs the element's own colour, applied once the cascade ends. */
let deferredCurrent: { prop: string; value: string; important: boolean; author: boolean }[] = [];
let flushingCurrent = false;

function applyText(el: Element, prop: string, value: string, parent: Node | null, important: boolean,
  author = false): void {
  // currentColor is the element's own colour, and the cascade may not have applied `color` yet:
  // the declaration waits until every declaration of this element has been.
  if (!flushingCurrent && hasDeferredCurrentColor(value)) {
    deferredCurrent.push({ prop, value, important, author });
    return;
  }
  const cprops = el.cprops;
  // A system colour (--native-sys-*) is the platform's, resolved here where the element's own
  // color-scheme is known.
  const dark = (el.state & P.S_SCHEME_DARK) !== 0;
  const lookup = (n: string): string | undefined => {
    if (cprops !== null) {
      const it = cprops.get(n);
      if (it !== undefined) return it;
    }
    if (n.startsWith(SYSTEM_COLOR_PREFIX)) {
      const resolved = systemColorText(n.slice(SYSTEM_COLOR_PREFIX.length), dark);
      if (resolved !== null) return resolved;
    }
    return undefined;
  };
  // A light-dark() asks for a colour by scheme; picking its branch first can leave a system colour
  // behind, which then resolves through a custom property, so it becomes that var() before the
  // reference is substituted — and again after, since a var() a page wrote may name a colour.
  let chosen = resolveLightDark(prop, value, dark);
  // A colour function that names currentColor needs the element's own colour to finish.
  if (hasDeferredCurrentColor(chosen)) chosen = resolveCurrentColor(chosen, colorText(el.sv[P.P_COLOR]));
  const rewritten = withSystemColors(prop, chosen);
  const substituted = !hasVar(rewritten) ? rewritten : substituteVars(rewritten, lookup);
  // A value that comes out as a CSS-wide keyword behaves as the keyword, which CSS resolves
  // before the property's own grammar ever sees it.
  const keyword = substituted === null ? "" : wideKeyword(substituted);
  const text = substituted === null || keyword !== "" ? null : withSystemColors(prop, substituted);
  const decls = text === null ? null : compiledText(prop, text);
  if (decls === null) {
    // `all` applies its keyword to every property, at the place the declaration has in the
    // cascade. `direction` is the one property it leaves alone.
    if (prop === "all") {
      if (keyword === "") return;
      for (const name of P.PROPERTY_NAMES) {
        if (name === "direction") continue;
        applyText(el, name, keyword, parent, important, author);
      }
      return;
    }
    const ids = longhandIds(prop);
    if (ids === null) return;
    // A declaration that names no value leaves the property unset, and one that rolls back to the
    // UA's own value leaves the widget the UA's: neither takes the box away from the UA.
    const specified = author && keyword !== "" && keyword !== "revert" && keyword !== "revert-layer";
    for (const p of ids) {
      // `inherit` — and `unset`, `revert` or `revert-layer` on an inherited property, since the UA
      // sheet leaves those to inherit — copies the parent's value; everything else, an invalid
      // value included (which is `unset` too), leaves the initial one.
      // A revert rolls back to the UA origin first: the UA sheet's own value for the property,
      // which for the initial value of `display` is `inline` but for a div's UA rule is `block`.
      if (keyword === "revert" || keyword === "revert-layer") {
        const ua = uaValue(el, p);
        if (ua !== null) {
          el.sv[p] = ua[0];
          el.su[p] = ua[1];
          noteDeclared(el, p);
          continue;
        }
      }
      const unset = keyword === "unset" || keyword === "revert" || keyword === "revert-layer" || keyword === "";
      const inherit = keyword === "inherit" || (unset && INHERITS[p]);
      if (inherit && parent !== null) {
        // A value that names currentColor stays unresolved when inherited: Chrome resolves it
        // against the inheriting element's own colour, so the text travels and resolves here.
        // `color` itself is the exception: inheriting it copies the computed colour, so a child of
        // a color-mix() colour keeps that colour rather than mixing again.
        const text = p !== P.P_COLOR && parent instanceof Element && parent.colorText !== null ? parent.colorText.get(p) : undefined;
        if (text !== undefined) {
          // The text resolves against this element's own colour, so the value follows both.
          noteFollowsParent(el, p);
          noteDependency(el, P.P_COLOR);
          deferredCurrent.push({ prop: P.PROPERTY_NAMES[p], value: text, important, author });
          continue;
        }
        // A logical side shares its computed value with the physical side it names, so an
        // inherited logical side takes the parent's value from that side: the logical slot of an
        // element that never declared the logical property itself holds the initial value.
        const from = isLogicalSide(p) && parent instanceof Element ? logicalPhysicalProp(parent, p) : p;
        el.sv[p] = parent.sv[from];
        el.su[p] = parent.su[from];
        forgetColorText(el, p);
        const form = parent instanceof Element && parent.colorForm !== null ? parent.colorForm.get(p) : undefined;
        if (form !== undefined) rememberColorForm(el, p, form);
        else forgetColorForm(el, p);
      } else {
        el.sv[p] = INITIAL_V[p];
        el.su[p] = INITIAL_U[p];
        forgetColorForm(el, p);
      }
      noteDeclared(el, p);
      if (inherit && parent !== null) noteFollowsParent(el, p);
      if (specified) noteFace(el, p);
      noteSide(p, el.sv[p], el.su[p], important);
    }
    return;
  }
  const current = hasDeferredCurrentColor(value);
  // A value that names currentColor is computed from this element's colour, so a colour inherited
  // from an ancestor can move it (see the inherited-only fast path). A var() may be where the
  // currentColor comes from, so the substituted text counts too.
  if (current || hasDeferredCurrentColor(chosen) ||
    (substituted !== null && hasDeferredCurrentColor(substituted))) noteDependency(el, P.P_COLOR);
  // The form comes from the resolved text: a mix that names currentColor serializes the colour it
  // mixed with, as Chrome does. A background image's text is the substituted one, since a
  // gradient written through var() (how Tailwind builds one) only parses after substitution.
  const form = prop === "background-image"
    ? (text === null ? null : imageForm(text) ?? gradientCss(text))
    : modernColorForm(chosen);
  for (let k = 0; k + 2 < decls.length; k += 3) {
    el.sv[decls[k]] = decls[k + 1];
    el.su[decls[k]] = decls[k + 2];
    // A modern colour function's computed value keeps its own space for CSSOM to read back.
    if (form !== null) rememberColorForm(el, decls[k], form);
    else forgetColorForm(el, decls[k]);
    // A property whose value names currentColor keeps the text that named it; one that resolved
    // to a plain colour has no text to pass on.
    if (current) rememberColorText(el, decls[k], value);
    else forgetColorText(el, decls[k]);
    noteDeclared(el, decls[k]);
    if (author) noteFace(el, decls[k]);
    noteSide(decls[k], decls[k + 1], decls[k + 2], important);
    if (decls[k] === P.P_FONT_SIZE) fontSizeDeclared = true;
    noteDecor(el, decls[k]);
  }
}

/**
 * Whether the element is inside the rule's @scope: the nearest ancestor (or the element itself)
 * matching the scope root, with no element matching a scope limit between. The prelude is parsed
 * once and kept.
 */
const scopeCache = new Map<string, { start: Selector[]; limit: Selector[] | null } | null>();

function anySelectorMatches(el: Element, sels: Selector[]): boolean {
  for (const sel of sels) if (selectorMatches(el, sel, document.documentElement)) return true;
  return false;
}

function ruleInScope(el: Node, prelude: string): boolean {
  let parsed = scopeCache.get(prelude);
  if (parsed === undefined) {
    // `(.root) to (.limit)`: a top-level ` to ` ends the scope root.
    let startText = prelude;
    let limitText: string | null = null;
    const at = topLevelTo(prelude);
    if (at >= 0) {
      startText = prelude.slice(0, at);
      limitText = prelude.slice(at + 4);
    }
    // The prelude writes each selector in parentheses: `(.card) to (.card .inner)`.
    const start = parseSelector(unwrapScope(startText));
    const limit = limitText === null ? null : parseSelector(unwrapScope(limitText));
    parsed = start === null ? null : { start, limit };
    scopeCache.set(prelude, parsed);
  }
  if (parsed === null) return false;
  let root: Element | null = null;
  for (let n: Node | null = el; n !== null; n = n.parentElement) {
    if (n.isElementNode && n.pseudoKind === P.PE_NONE && anySelectorMatches(n as Element, parsed.start)) {
      root = n as Element;
      break;
    }
  }
  if (root === null) return false;
  if (parsed.limit !== null) {
    for (let n: Node | null = el; n !== null && n !== root; n = n.parentElement) {
      if (n.isElementNode && n.pseudoKind === P.PE_NONE && anySelectorMatches(n as Element, parsed.limit)) return false;
    }
  }
  return true;
}

/** The selector text inside an @scope prelude's parentheses. */
function unwrapScope(text: string): string {
  const s = text.trim();
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

/** The index of a top-level ` to ` in an @scope prelude, or -1. */
function topLevelTo(prelude: string): number {
  let depth = 0;
  for (let i = 0; i < prelude.length - 3; i++) {
    const ch = prelude[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (depth === 0 && prelude.startsWith(" to ", i)) return i;
  }
  return -1;
}

/**
 * What each rule's media conditions answered during the current pass: 0 not asked yet, 1 they
 * hold, 2 they don't. A media condition asks the window, not the element, so the answer is the
 * same for every element the rule is tested against; a resize or a colour-scheme change starts a
 * new pass, which clears these. `sheetMediaPass` keeps the same answers per sheet (a `<style
 * media>` or a `<link media>`), and rule 0 asks the sheet's condition before the rule's own.
 */
let mediaPass = new Int8Array(0);
let sheetMediaPass = new Int8Array(0);

/** Forgets the media answers, as a pass over the page must start from the window as it is now. */
function resetMediaPass(): void {
  if (mediaPass.length !== tables.ruleMedia.length) mediaPass = new Int8Array(tables.ruleMedia.length);
  else mediaPass.fill(0);
  const sheets = tables.sheetMedia.length;
  if (sheetMediaPass.length !== sheets) sheetMediaPass = new Int8Array(sheets);
  else sheetMediaPass.fill(0);
}

/** -1 until asked, then 1 when a subtree a script appends can be styled on its own. */
let insertStylesAlone = -1;

/**
 * True when appending an element to the end of a parent cannot change any other element's style,
 * so only the new subtree has to be styled: no rule depends on what has an element as a
 * descendant (`:has()`), on counters (a new reset changes what follows it), or on the marker boxes
 * the style pass makes beside a scroll container. Positions counted from either end are fine:
 * adding at the end leaves every earlier box where it was.
 */
export function appendedSubtreeStylesAlone(): boolean {
  if (insertStylesAlone >= 0) return insertStylesAlone === 1;
  let ok = true;
  if (tables.counterItems.length > 0) ok = false;
  for (let r = 0; ok && r < tables.ruleHas.length; r++) if (tables.ruleHas[r].length > 0) ok = false;
  for (let r = 0; ok && r < tables.chainHas.length; r++) {
    for (const l of tables.chainHas[r]) if (l.length > 0) ok = false;
  }
  for (let r = 0; ok && r < tables.rulePseudo.length; r++) {
    const p = tables.rulePseudo[r];
    if (p === P.PE_SCROLL_MARKER || p === P.PE_SCROLL_MARKER_GROUP || p === P.PE_TARGET_TEXT) ok = false;
  }
  insertStylesAlone = ok ? 1 : 0;
  return ok;
}

/** Forgets the answer, as a newly applied table set may carry different selectors. */
export function resetAppendedSubtreeCheck(): void {
  insertStylesAlone = -1;
  subtreeAlone = -1;
  sideLooking = -1;
  nthOf = -1;
  chainNthOf = -1;
  textSelectors = -1;
}

/** -1 until asked, then 1 when a change to one element stays inside its own subtree. */
let subtreeAlone = -1;

/**
 * How far a change to one connected element reaches: 0 when a page pass is needed (a rule looks up at
 * an ancestor with `:has()`, at a counter, at the marker boxes the style pass makes beside a scroll
 * container, or a runtime sheet a script wrote makes the answer unknown), 1 when the element's own
 * subtree is all, and 2 when the page has `+`/`~` rules and the following sibling subtrees can see
 * the change as well.
 */
export function subtreeRestyleReach(): number {
  if (subtreeAlone < 0) {
    let ok = true;
    if (tables.counterItems.length > 0) ok = false;
    if (runtimeRulesReachBeyond()) ok = false;
    for (let r = 0; ok && r < tables.ruleHas.length; r++) if (tables.ruleHas[r].length > 0) ok = false;
    for (let r = 0; ok && r < tables.chainHas.length; r++) {
      for (const l of tables.chainHas[r]) if (l.length > 0) ok = false;
    }
    for (let r = 0; ok && r < tables.rulePseudo.length; r++) {
      const p = tables.rulePseudo[r];
      if (p === P.PE_SCROLL_MARKER || p === P.PE_SCROLL_MARKER_GROUP || p === P.PE_TARGET_TEXT) ok = false;
    }
    subtreeAlone = ok ? 1 : 0;
  }
  return subtreeAlone;
}

/** True when the page has a rule that looks across at a following sibling (`+`, `~`). */
export function siblingRulesExist(): boolean {
  for (let r = 0; r < tables.chainComb.length; r++) {
    const combs = tables.chainComb[r];
    for (const c of combs) if (c === COMB_ADJACENT || c === COMB_GENERAL) return true;
  }
  return false;
}

/**
 * True when a rule looks sideways without a sibling combinator: it counts :nth-child(… of S)
 * siblings, or its :not() holds a complex selector. Then one element's class or attribute can
 * change what a later sibling matches, so a change reaches the following siblings too.
 */
function sideLookingRulesExist(): boolean {
  if (sideLooking >= 0) return sideLooking === 1;
  let found = nthOfRulesExist();
  for (let r = 0; !found && r < tables.ruleNots.length; r++) {
    for (const f of tables.ruleNthStartOf[r]) if (f !== "") { found = true; break; }
  }
  for (let r = 0; !found && r < tables.ruleNthEndOf.length; r++) {
    for (const f of tables.ruleNthEndOf[r]) if (f !== "") { found = true; break; }
  }
  for (let r = 0; !found && r < tables.chainNthStartOf.length; r++) {
    for (const link of tables.chainNthStartOf[r]) for (const f of link) if (f !== "") { found = true; break; }
  }
  for (let r = 0; !found && r < tables.chainNthEndOf.length; r++) {
    for (const link of tables.chainNthEndOf[r]) for (const f of link) if (f !== "") { found = true; break; }
  }
  for (let r = 0; !found && r < tables.chainNots.length; r++) {
    for (const nots of tables.chainNots[r]) for (const enc of nots) if (hasNotSelToken(enc)) { found = true; break; }
  }
  for (let r = 0; !found && r < tables.ruleNotSels.length; r++) {
    if (tables.ruleNotSels[r].length > 0) found = true;
  }
  for (let r = 0; !found && r < tables.chainNotSels.length; r++) {
    for (const list of tables.chainNotSels[r]) if (list.length > 0) { found = true; break; }
  }
  sideLooking = found ? 1 : 0;
  return found;
}
let sideLooking = -1;

/**
 * True when a rule counts `:nth-child(An+B of S)` siblings. Then one element's class or attribute
 * changes the position of every sibling, before it as well as after it: a count from the end
 * (`:nth-last-child()`) moves when an element before the subject leaves the filtered list.
 */
function nthOfRulesExist(): boolean {
  if (nthOf >= 0) return nthOf === 1;
  let found = false;
  for (let r = 0; !found && r < tables.ruleNthStartOf.length; r++) {
    for (const f of tables.ruleNthStartOf[r]) if (f !== "") { found = true; break; }
  }
  for (let r = 0; !found && r < tables.ruleNthEndOf.length; r++) {
    for (const f of tables.ruleNthEndOf[r]) if (f !== "") { found = true; break; }
  }
  for (let r = 0; !found && r < tables.chainNthStartOf.length; r++) {
    for (const link of tables.chainNthStartOf[r]) for (const f of link) if (f !== "") { found = true; break; }
  }
  for (let r = 0; !found && r < tables.chainNthEndOf.length; r++) {
    for (const link of tables.chainNthEndOf[r]) for (const f of link) if (f !== "") { found = true; break; }
  }
  // A filter inside :not(:nth-child(… of S)) travels in the encoded condition.
  for (let r = 0; !found && r < tables.ruleNots.length; r++) {
    for (const enc of tables.ruleNots[r]) if (hasOfToken(enc)) { found = true; break; }
  }
  for (let r = 0; !found && r < tables.chainNots.length; r++) {
    for (const nots of tables.chainNots[r]) for (const enc of nots) if (hasOfToken(enc)) { found = true; break; }
  }
  nthOf = found ? 1 : 0;
  return found;
}
let nthOf = -1;

/** True when an encoded compound carries an "of S" filter on one of its nth conditions. */
function hasOfToken(enc: string): boolean {
  if (enc.startsWith("f") || enc.startsWith("g")) return true;
  return enc.indexOf("\u0001f") >= 0 || enc.indexOf("\u0001g") >= 0;
}

/** True when a filter sits on an ancestor compound: then a subject below it moves with the chain. */
function chainNthOfRulesExist(): boolean {
  if (chainNthOf >= 0) return chainNthOf === 1;
  let found = false;
  for (let r = 0; !found && r < tables.chainNthStartOf.length; r++) {
    for (const link of tables.chainNthStartOf[r]) for (const f of link) if (f !== "") { found = true; break; }
  }
  for (let r = 0; !found && r < tables.chainNthEndOf.length; r++) {
    for (const link of tables.chainNthEndOf[r]) for (const f of link) if (f !== "") { found = true; break; }
  }
  chainNthOf = found ? 1 : 0;
  return found;
}
let chainNthOf = -1;

/** True when an encoded compound carries a :not() argument that is a complex selector. */
function hasNotSelToken(enc: string): boolean {
  return enc.startsWith("n") || enc.indexOf("\u0001n") >= 0;
}

/** The check the DOM and the CSS object model ask before restyling one element's subtree. */
function subtreeRestyleOk(el: Node): number {
  const reach = subtreeRestyleReach();
  if (reach === 0) return 0;
  if (!(el.parentNode instanceof Element)) return 0;
  if (el.shadowTree() !== null || el.assignedSlot !== null) return 0;
  // A page counting only the siblings a filter matches can see one element's change from every
  // sibling, before and after it; styling the parent's subtree is cheaper than a page pass.
  if (nthOfRulesExist()) return 3;
  // A page with `+`/`~` rules, or a complex :not() argument, can see the change from the boxes
  // after this one; styling them is cheaper than a page pass.
  return siblingRulesExist() || sideLookingRulesExist() ? 2 : 1;
}

setSubtreeRestyleCheck(subtreeRestyleOk);
setRestyleRootFor((n) => {
  // An element with `dir=auto` (or a <bdi>) takes its direction from the text below it, so a
  // change anywhere inside has to restyle from there, not just from the changed element.
  for (let a: Node | null = n; a !== null; a = a.parentNode) {
    if (a instanceof ShadowRoot) { a = a.host; continue; }
    if (!(a instanceof Element)) continue;
    const dir = a.attrMap.get("dir");
    if ((dir !== undefined && dir.trim().toLowerCase() === "auto") || a.localName === "bdi") return a;
  }
  return null;
});

/** -1 until asked: whether any rule's answer depends on what text a subtree holds. */
let textSelectors = -1;

export function refreshTextRunDependence(): void {
  textSelectors = -1;
  textRunDependence.affectSelectors = textRunsAffectSelectors();
}

function textRunsAffectSelectors(): boolean {
  if (textSelectors < 0) {
    let found = tables.counterItems.length > 0;
    for (let r = 0; !found && r < tables.ruleEmpty.length; r++) if (tables.ruleEmpty[r]) found = true;
    for (let r = 0; !found && r < tables.chainEmpty.length; r++) {
      for (const empty of tables.chainEmpty[r]) if (empty) found = true;
    }
    for (let r = 0; !found && r < tables.ruleHas.length; r++) if (tables.ruleHas[r].length > 0) found = true;
    for (let r = 0; !found && r < tables.chainHas.length; r++) {
      for (const has of tables.chainHas[r]) if (has.length > 0) found = true;
    }
    for (let r = 0; !found && r < tables.ruleNthStartOf.length; r++) {
      for (const f of tables.ruleNthStartOf[r]) if (f !== "") found = true;
    }
    textSelectors = found ? 1 : 0;
  }
  return textSelectors === 1;
}


/** True while the media condition on `rule` (and on its sheet) holds. */
function ruleMediaHolds(rule: number): boolean {
  if (rule >= mediaPass.length) return ruleMediaUncached(rule);
  const seen = mediaPass[rule];
  if (seen !== 0) return seen === 1;
  const holds = ruleMediaUncached(rule);
  mediaPass[rule] = holds ? 1 : 2;
  return holds;
}

function ruleMediaUncached(rule: number): boolean {
  // A rule from a sheet with a media condition of its own (`<style media>`, `<link media>`) applies
  // only while that holds, the same way a rule inside @media does.
  const sheet = rule < tables.ruleSheet.length ? tables.ruleSheet[rule] : -1;
  // A page whose sheets carry no media condition — almost every page — pays a length test here.
  if (sheet >= 0 && tables.sheetMedia.length > 0) {
    let holds: boolean;
    const seen = sheet < sheetMediaPass.length ? sheetMediaPass[sheet] : 0;
    if (seen !== 0) holds = seen === 1;
    else {
      const media = sheetMediaOf(sheet);
      holds = media === "" || mediaMatches(media);
      if (sheet < sheetMediaPass.length) sheetMediaPass[sheet] = holds ? 1 : 2;
    }
    if (!holds) return false;
  }
  // A rule inside @media applies only while its condition holds; the window's size is the query.
  const media = tables.ruleMedia[rule];
  return media === "" || mediaMatches(media);
}

function ruleApplies(el: Element, rule: number): boolean {
  // A pseudo-element's rule describes the element that generates it, so that element is the one
  // tested.
  const origin = tables.rulePseudo[rule] !== P.PE_NONE ? pseudoTest(el) : el;
  if (origin === null) return false;
  const test = origin;
  // The subject's own tests come first: a rule that names a class this element doesn't have — the
  // common case — costs one lookup rather than the media, container and scope lookups below.
  for (const c of tables.ruleClasses[rule]) if (!test.classList.contains(c)) return false;
  if (!ruleMediaHolds(rule)) return false;
  // A rule inside @container applies while a matching ancestor container's size says so. The
  // generated box of a pseudo-element asks about the containers around the element that makes it.
  const container = rule < tables.ruleContainer.length ? tables.ruleContainer[rule] : "";
  if (container !== "" && !containerMatches(el, container, tables.containerNames)) return false;
  // A rule inside @scope applies only within its scope root, as seen from the element it styles.
  const scope = rule < tables.ruleScope.length ? tables.ruleScope[rule] : "";
  if (scope !== "" && !ruleInScope(test, scope)) return false;
  // A @starting-style rule styles only the element's first state; it stops applying once the
  // regular cascade replaces that state (which is what the transition animates away from).
  if (rule < tables.ruleStarting.length && tables.ruleStarting[rule] && !test.starting) return false;
  const states = tables.ruleStates[rule];
  // :checked, :disabled, :valid and the rest are derived from the control's state, not set by
  // an event, so they are worked out when a rule asks about them.
  if ((states & P.S_FORM_STATES) !== 0) refreshFormState(test, states);
  if ((states & test.state) !== states) return false;
  if (tables.ruleRoot[rule] && test !== document.documentElement) return false;
  const ruleDir = rule < tables.ruleDir.length ? tables.ruleDir[rule] : 0;
  if (ruleDir !== 0 && elementDirection(test) + 1 !== ruleDir) return false;
  if (rule < tables.ruleEmpty.length && tables.ruleEmpty[rule] && !isEmptyElement(test)) return false;
  if (!nthApplies(test, tables.ruleNthStart[rule], tables.ruleNthEnd[rule],
    rule < tables.ruleNthStartOf.length ? tables.ruleNthStartOf[rule] : NO_OF,
    rule < tables.ruleNthEndOf.length ? tables.ruleNthEndOf[rule] : NO_OF)) return false;
  for (const a of tables.ruleAttrs[rule]) if (!attrMatches(test, a)) return false;
  if (!langApplies(test, rule < tables.ruleLang.length ? tables.ruleLang[rule] : NO_LANG)) return false;
  if (!notsApply(test, tables.ruleNots[rule])) return false;
  if (rule < tables.ruleNotSels.length) for (const t of tables.ruleNotSels[rule]) if (selectorArgMatches(test, t)) return false;
  if (!hasApplies(test, rule < tables.ruleHas.length ? tables.ruleHas[rule] : [])) return false;
  if (tables.chainComb[rule].length > 0 && !chainMatches(rule, 0, test)) return false;
  return true;
}

/** The element a generated box is styled by: its origin when it records one, else its parent. */
function pseudoTest(el: Element): Element | null {
  // An ordinary element is its own test: only a generated box is tested through the element
  // that makes it, which is its recorded origin, or its parent when it didn't record one.
  if (el.pseudoKind === P.PE_NONE) return el;
  return el.pseudoOrigin !== null ? el.pseudoOrigin : el.parentElement;
}

/** The compiled rules of one pseudo-element kind whose tag and id fit `el`. */
function dynamicPseudoRules(el: Element, kind: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < tables.dynRules.length; i++) {
    if (tables.dynPseudo[i] !== kind) continue;
    const tag = tables.dynTags[i];
    const id = tables.dynIds[i];
    if (tag !== "" && tag !== el.localName) continue;
    if (id !== "" && id !== el.id) continue;
    out.push(tables.dynRules[i]);
  }
  return out;
}

/** A generated box of `kind` for `origin`, which the style pass made rather than the build. */
function makeScrollBox(kind: number, rules: number[], origin: Element): Element {
  const box = newElementFor(P.PSEUDO_TAGS[kind], "", "", rules, 0, false);
  box.pseudoOrigin = origin;
  return box;
}

/**
 * Keeps a scroll container's ::scroll-marker-group box and its ::scroll-marker boxes in step with
 * what the box asks for: a group box immediately before or after the container in its parent, and
 * one marker inside it for each child, styled by the child's own ::scroll-marker rule.
 */
function syncScrollMarkers(el: Element): void {
  const mode = el.sv[P.P_SCROLL_MARKER_GROUP];
  const parent = el.parentElement;
  if (mode === P.SG_NONE || parent === null) {
    dropScrollMarkers(el);
    return;
  }
  let group = el.scrollMarkerGroup;
  const groupRules = dynamicPseudoRules(el, P.PE_SCROLL_MARKER_GROUP);
  if (group === null) {
    group = makeScrollBox(P.PE_SCROLL_MARKER_GROUP, groupRules, el);
    group.parentNode = parent;
    el.scrollMarkerGroup = group;
  } else {
    group.rules = groupRules;
  }
  const kids = parent.kids;
  const at = kids.indexOf(group);
  if (at >= 0) kids.splice(at, 1);
  const self = kids.indexOf(el);
  const want = mode === P.SG_BEFORE ? Math.max(0, self) : self + 1;
  kids.splice(want, 0, group);
  // One marker per child element, in the children's order.
  const boxes: Element[] = [];
  for (const c of el.kids) {
    if (!(c instanceof Element) || c.pseudoKind !== P.PE_NONE) continue;
    let box: Element | null = null;
    for (const m of el.scrollMarkers) if (m.pseudoOrigin === c) box = m;
    const rules = dynamicPseudoRules(c, P.PE_SCROLL_MARKER);
    if (box === null) box = makeScrollBox(P.PE_SCROLL_MARKER, rules, c);
    else box.rules = rules;
    box.parentNode = group;
    boxes.push(box);
  }
  group.kids = boxes;
  el.scrollMarkers = boxes;
  // The boxes are made in the middle of a style pass, which may already have walked past where
  // they sit: style them here, against the parent they inherit from.
  computeStyles(group, parent);
  for (const box of boxes) computeStyles(box, group);
}

/** Takes a scroll container's marker boxes out of the tree, as when it stops asking for them. */
function dropScrollMarkers(el: Element): void {
  const group = el.scrollMarkerGroup;
  if (group !== null) {
    const parent = group.parentNode;
    if (parent !== null) {
      const kids = (parent as Element).kids;
      const at = kids.indexOf(group);
      if (at >= 0) kids.splice(at, 1);
    }
    el.scrollMarkerGroup = null;
  }
  el.scrollMarkers = [];
}

/**
 * The counters in scope, innermost instance last per name (CSS Lists 3 §4): a counter-reset
 * pushes an instance that stays in scope for its element, its descendants and its following
 * siblings, so it is popped when the parent's subtree ends.
 */
interface CounterInstance { name: string; value: number; reversed: boolean; }
const counterState = new Map<string, CounterInstance[]>();

/** The counters a counter-reset/-increment/-set declaration list names. */
function declaredCounters(el: Element, p: number): ParsedCounter[] {
  const id = el.sv[p];
  return id >= 0 && id < tables.counterItems.length ? parseCounterList(tables.counterItems[id]) : [];
}

/** A copy of the counters in scope, or null when there are none. */
function counterSnapshot(): Map<string, number[]> | null {
  if (counterState.size === 0) return null;
  const snap = new Map<string, number[]>();
  for (const [name, stack] of counterState) snap.set(name, stack.map((i) => i.value));
  return snap;
}

function pushCounter(el: Node, name: string, value: number, reversed = false): void {
  let stack = counterState.get(name);
  if (stack === undefined) {
    stack = [];
    counterState.set(name, stack);
  }
  const inst = { name, value, reversed };
  stack.push(inst);
  if (el.counterOwn === null) el.counterOwn = [];
  el.counterOwn.push(inst);
}

/**
 * Takes instances out of scope, innermost first, when the scope they were made in ends. A
 * reversed counter stays in scope for the creating element's following siblings, so its own
 * element pops it one level up, where its parent's subtree ends.
 */
function popCounters(list: CounterInstance[], reversed: boolean): void {
  for (let i = list.length - 1; i >= 0; i--) {
    const inst = list[i];
    if (inst.reversed !== reversed) continue;
    const stack = counterState.get(inst.name);
    if (stack === undefined) continue;
    const k = stack.lastIndexOf(inst);
    if (k >= 0) stack.splice(k, 1);
    if (stack.length === 0) counterState.delete(inst.name);
  }
}

/**
 * A reversed counter named without a starting value starts at the value its scope's increments
 * add up to (CSS Lists 3 §4.4.2). The scope reaches past the creating element to its following
 * siblings, so those increments are only known once the whole document's styles are: a pass that
 * has any reversed reset walks the document once for styles alone, records the counter
 * declarations in document order, and adds them up before the real walk applies them.
 */
interface PrepassNode {
  el: Node;
  index: number;
  end: number;
  resets: ParsedCounter[];
  sets: ParsedCounter[];
  increments: ParsedCounter[];
  listItem: boolean;
  hidden: boolean;
}
let runningPrepass = false;
let prepassNodes: PrepassNode[] | null = null;
let reversedInitials: Map<Node, Map<string, number>> | null = null;

/** Whether any counter-reset this document holds is reversed. */
function hasReversedCounters(): boolean {
  for (const encoded of tables.counterItems) if (encoded.indexOf("reversed(") >= 0) return true;
  return false;
}

/** Each reversed reset's initial value, from the increments in the counter's scope. */
function collectReversedInitials(nodes: PrepassNode[]): Map<Node, Map<string, number>> | null {
  const byNode = new Map<Node, PrepassNode>();
  for (const n of nodes) byNode.set(n.el, n);
  const out = new Map<Node, Map<string, number>>();
  for (const n of nodes) {
    if (n.hidden) continue;
    for (const d of n.resets) {
      if (!d.reversed || !d.auto) continue;
      // The scope runs to the end of the parent's subtree: this element's descendants and its
      // following siblings with theirs.
      const parent = n.el.parentNode;
      const parentEntry = parent === null ? undefined : byNode.get(parent);
      const last = parentEntry === undefined ? nodes.length - 1 : parentEntry.end;
      let num = 0;
      let lastNonZero = 0;
      for (let i = n.index; i <= last; i++) {
        const m = nodes[i];
        if (m.hidden) { i = m.end; continue; }
        // A same-named reset in between starts a counter of its own; what it covers is not ours.
        if (i !== n.index && m.resets.some((r) => r.name === d.name)) { i = m.end; continue; }
        const set = m.sets.find((s) => s.name === d.name);
        if (set !== undefined) {
          num += set.value;
          break;
        }
        for (const inc of m.increments) {
          if (inc.name !== d.name) continue;
          const negated = -inc.value;
          if (negated !== 0) lastNonZero = negated;
          num += negated;
        }
        // A list item counts down by one in a reversed list-item counter.
        if (d.name === LIST_ITEM && m.listItem && !m.increments.some((inc) => inc.name === LIST_ITEM)) {
          lastNonZero = 1;
          num += 1;
        }
      }
      num += lastNonZero;
      let byName = out.get(n.el);
      if (byName === undefined) {
        byName = new Map<string, number>();
        out.set(n.el, byName);
      }
      byName.set(d.name, num);
    }
  }
  return out.size > 0 ? out : null;
}

/**
 * Applies an element's counter declarations in document order and records the counters in scope
 * on the node, where its generated content reads them: counter-set first, then
 * counter-increment, then counter-reset, which makes a new innermost instance.
 */
function applyCounters(el: Node): void {
  el.counterOwn = null;
  if (el instanceof Element) {
    // A list holds an implicit `list-item` counter (CSS Lists 3 §4.2): it starts at one below
    // the list's start, at the item count for a reversed list. Its items count on from there.
    if (isListContainer(el)) pushCounter(el, LIST_ITEM, listStartValue(el));
    // In the order CSS Lists applies them: a reset makes the new innermost instance first, so an
    // increment on the same element counts that one (a span that resets and increments shows the
    // reset value plus one), then a set replaces a value and an increment adds to it.
    for (const d of declaredCounters(el, P.P_COUNTER_RESET)) {
      // A reversed counter named without a value starts at the value its scope's increments add
      // up to (CSS Lists 3 §4.4.2), worked out before this pass began.
      const initial = d.reversed && d.auto ? (reversedInitials?.get(el)?.get(d.name) ?? 0) : d.value;
      pushCounter(el, d.name, initial, d.reversed === true);
    }
    for (const d of declaredCounters(el, P.P_COUNTER_SET)) {
      const stack = counterState.get(d.name);
      if (stack === undefined || stack.length === 0) pushCounter(el, d.name, d.value);
      else stack[stack.length - 1].value = d.value;
    }
    for (const d of declaredCounters(el, P.P_COUNTER_INCREMENT)) {
      const stack = counterState.get(d.name);
      if (stack === undefined || stack.length === 0) pushCounter(el, d.name, d.value);
      else stack[stack.length - 1].value += d.value;
    }
    // Every list item increments the implicit counter by one, or by minus one in a reversed
    // list or counter, unless its own counter-increment names it (then that is what it counts by).
    if (el.sv[P.P_DISPLAY] === P.D_LIST_ITEM) {
      const declared = declaredCounters(el, P.P_COUNTER_INCREMENT);
      if (!declared.some((d) => d.name === LIST_ITEM)) {
        const stack = counterState.get(LIST_ITEM);
        const top = stack !== undefined && stack.length > 0 ? stack[stack.length - 1] : null;
        const step = top !== null && top.reversed ? -1 : reversedList(el) ? -1 : 1;
        if (stack === undefined || stack.length === 0) pushCounter(el, LIST_ITEM, step);
        else stack[stack.length - 1].value += step;
      }
      // The value attribute sets the item's number outright, where the item lands.
      const value = el.getAttribute("value");
      if (value !== null && /^-?\d+$/.test(value.trim())) {
        const stack = counterState.get(LIST_ITEM);
        const v = parseInt(value, 10);
        if (stack === undefined || stack.length === 0) pushCounter(el, LIST_ITEM, v);
        else stack[stack.length - 1].value = v;
      }
    }
  }
  el.counterVals = counterSnapshot();
}

/** The implicit counter every list item counts in. */
const LIST_ITEM = "list-item";

/** An `<ol>`, `<ul>` or `<menu>` that starts a list: its items count inside its own scope. */
function isListContainer(el: Element): boolean {
  const t = el.localName;
  return t === "ol" || t === "ul" || t === "menu";
}

/** The list-item value a list's first item takes on, so the first increment lands on `start`. */
function listStartValue(list: Element): number {
  const attr = list.getAttribute("start");
  const start = attr !== null && /^-?\d+$/.test(attr.trim()) ? parseInt(attr, 10) : NaN;
  if (list.hasAttribute("reversed")) {
    // A reversed list counts down to 1: its first item is the number of items it holds, or the
    // start value when it names one. One more than that, since each item then counts down.
    if (!Number.isNaN(start)) return start + 1;
    let n = 0;
    // The items are not styled yet when their list is, so they are counted by tag.
    for (const c of list.kids) if (c instanceof Element && c.localName === "li") n++;
    return n + 1;
  }
  return Number.isNaN(start) ? 0 : start - 1;
}

/** Does the list this item belongs to count down? */
function reversedList(item: Element): boolean {
  const list = item.parentElement;
  return list !== null && list.localName === "ol" && list.hasAttribute("reversed");
}

/**
 * The counter values a generated box's content reads: those in scope at the box itself, which
 * are the originating element's plus whatever the pseudo-element's own declarations say.
 */
function counterLookup(el: Element): CounterLookup {
  const vals = el.counterVals;
  return (name: string, style: number, separator: string | null): string => {
    const stack = vals === null ? undefined : vals.get(name);
    const spec = counterStyleForKey(style);
    const one = (v: number): string => formatCounter(spec, v, styleLookup);
    if (stack === undefined || stack.length === 0) return one(0);
    if (separator === null) return one(stack[stack.length - 1]);
    return stack.map(one).join(separator);
  };
}

/**
 * A list item's marker: its text is the item's list-style-type at the item's ordinal, unless a
 * ::marker rule gives it content of its own. `list-style-type: none` hides it, and so does the
 * element not being a list item after all.
 */
function applyMarker(el: Element): void {
  const item = el.parentElement;
  // A button's box is the one the button layout rules make of it, so a list-item button draws
  // no marker: its content is the button's own.
  const buttonItem = item !== null && (item.localName === "button" ||
    (item.localName === "input" && buttonInputType(item.getAttribute("type") ?? "")));
  if (item === null || item.sv[P.P_DISPLAY] !== P.D_LIST_ITEM || buttonItem ||
    el.sv[P.P_LIST_STYLE_TYPE] === P.LST_NONE) {
    el.sv[P.P_DISPLAY] = P.D_NONE;
    el.ownText = "";
    return;
  }
  const v = el.sv[P.P_CONTENT];
  if (v >= 0 && v < tables.contentItems.length) {
    // An explicit ::marker content replaces the automatic marker text.
    el.ownText = contentText(tables.contentItems[v], (name) => item.getAttribute(name), counterLookup(el));
    return;
  }
  if (v === P.CONTENT_NONE) {
    el.sv[P.P_DISPLAY] = P.D_NONE;
    el.ownText = "";
    return;
  }
  // The item's number is the implicit list-item counter, so a `value` attribute, `start`
  // and `reversed` all reach the marker.
  const stack = el.counterVals === null ? undefined : el.counterVals.get(LIST_ITEM);
  const n = stack !== undefined && stack.length > 0 ? stack[stack.length - 1] : markerOrdinal(item);
  el.ownText = markerStyleText(el.sv[P.P_LIST_STYLE_TYPE], n,
    el.sv[P.P_LIST_STYLE_POSITION] !== P.LSP_INSIDE, isRtl(item));
}

/**
 * The item's place in its list. An <ol> counts from its start attribute, a li's value attribute
 * sets its number, and the items after it count on from there. Siblings are styled before the
 * item itself, so their displays are settled.
 */
function markerOrdinal(item: Element): number {
  const list = item.parentElement;
  if (list === null) return 1;
  let n = 1;
  if (list.localName === "ol") {
    const start = list.getAttribute("start");
    const v = start === null ? NaN : parseInt(start, 10);
    if (!Number.isNaN(v)) n = v;
  }
  let first = true;
  for (const c of list.kids) {
    if (!(c instanceof Element) || c.pseudoKind !== P.PE_NONE || c.sv[P.P_DISPLAY] !== P.D_LIST_ITEM) continue;
    if (!first) n++;
    first = false;
    const value = c.getAttribute("value");
    const v = value === null ? NaN : parseInt(value, 10);
    if (!Number.isNaN(v)) n = v;
    if (c === item) break;
  }
  return n;
}

/** Sets a pseudo-element's generated text, hiding it when its content is none. */
function applyContent(el: Element): void {
  const v = el.sv[P.P_CONTENT];
  const origin = el.parentElement;
  if (v < 0 || v >= tables.contentItems.length) {
    el.ownText = "";
    el.sv[P.P_DISPLAY] = P.D_NONE;
    return;
  }
  el.ownText = contentText(tables.contentItems[v], (name) => (origin !== null ? origin.getAttribute(name) : null),
    counterLookup(el));
}

/**
 * Whether a color-scheme value asks the UA for its dark colours: `dark` alone always does, and
 * `light dark` follows what the system asks for.
 */
function usedDarkScheme(bits: number): boolean {
  if ((bits & P.CS_DARK) === 0) return false;
  if ((bits & P.CS_LIGHT) !== 0) return mediaMatches("(prefers-color-scheme: dark)");
  return true;
}

/** Set when an element left its @starting-style state, so one more pass applies the real one. */
let startingDirty = false;

/** Whether a @starting-style first state was replaced; the caller runs one more style pass. */
export function takeStartingDirty(): boolean {
  const v = startingDirty;
  startingDirty = false;
  return v;
}

/** The pseudo kind each rule id belongs to, for the compiled rules that style a pseudo-element.
 *  Rebuilt when another page's table set replaces the ids. */
let RULE_PSEUDO: Map<number, number> | null = null;
let RULE_PSEUDO_TABLE: number[] | null = null;

function rulePseudo(r: number): number {
  if (RULE_PSEUDO === null || RULE_PSEUDO_TABLE !== tables.dynRules) {
    RULE_PSEUDO = new Map();
    RULE_PSEUDO_TABLE = tables.dynRules;
    for (let i = 0; i < tables.dynRules.length; i++) {
      const p = tables.dynPseudo[i];
      if (p !== P.PE_NONE) RULE_PSEUDO.set(tables.dynRules[i], p);
    }
  }
  return RULE_PSEUDO.get(r) ?? P.PE_NONE;
}

/**
 * The compiled dynamic rules that style one of the fixed carriers — ::first-line, ::first-letter,
 * ::selection, ::target-text, a ::backdrop — indexed by the tag their selector names, with the
 * tagless ones apart. A rule like `.on::target-text` never matched at build time, so no carrier
 * box was made for it and it lives only in the dynamic table; the style pass hands it to the
 * element's carrier the moment it could apply, and the cascade's class test decides.
 */
let DYN_CARRIER_TABLE: number[] | null = null;
let DYN_CARRIER_BY_TAG: Map<string, number[]> = new Map();
let DYN_CARRIER_ANY: number[] = [];

function carrierRuleIndex(): void {
  if (DYN_CARRIER_TABLE === tables.dynRules) return;
  DYN_CARRIER_TABLE = tables.dynRules;
  DYN_CARRIER_BY_TAG = new Map();
  DYN_CARRIER_ANY = [];
  for (let i = 0; i < tables.dynRules.length; i++) {
    const pseudo = tables.dynPseudo[i];
    if (pseudo === P.PE_NONE || pseudo === P.PE_MARKER || pseudo === P.PE_BEFORE ||
      pseudo === P.PE_AFTER || pseudo === P.PE_PLACEHOLDER) continue;
    const tag = tables.dynTags[i];
    if (tag === "") {
      DYN_CARRIER_ANY.push(i);
      continue;
    }
    let list = DYN_CARRIER_BY_TAG.get(tag);
    if (list === undefined) {
      list = [];
      DYN_CARRIER_BY_TAG.set(tag, list);
    }
    list.push(i);
  }
}

/**
 * Makes the style carriers an element's rules need. The build made a box only for the pseudo
 * rules that matched statically; a rule whose class or state the build couldn't see
 * (`.on::target-text`) needs its box the moment it starts matching, and the box then holds the
 * rule so the cascade can apply it. The carrier's rules are checked against the dynamic table on
 * every pass, since a class or state can start matching at any time.
 */
function syncCarriers(el: Element): void {
  if (!el.carriersDone) {
    el.carriersDone = true;
    const lists = new Map<number, number[]>();
    for (const r of el.rules) {
      if (ruleStandsDown(r)) continue;
      const pseudo = rulePseudo(r);
      if (pseudo === P.PE_NONE || pseudo === P.PE_MARKER || pseudo === P.PE_BEFORE ||
        pseudo === P.PE_AFTER || pseudo === P.PE_PLACEHOLDER) continue;
      let list = lists.get(pseudo);
      if (list === undefined) {
        list = [];
        lists.set(pseudo, list);
      }
      list.push(r);
    }
    for (const [pseudo, list] of lists) el.setCarrierRules(pseudo, list);
  }
  carrierRuleIndex();
  const take = (i: number): void => {
    const id = tables.dynIds[i];
    if (id !== "" && id !== el.id) return;
    const r = tables.dynRules[i];
    // Only a rule that matches now gives the element a carrier: the class or state test is the
    // cascade's own, so a rule that matches later is picked up by a later pass.
    if (!ruleApplies(el, r)) return;
    el.addCarrierRules(tables.dynPseudo[i], [r]);
  };
  const byTag = DYN_CARRIER_BY_TAG.get(el.localName);
  if (byTag !== undefined) for (const i of byTag) take(i);
  for (const i of DYN_CARRIER_ANY) take(i);
}

export function computeStyles(el: Node, parent: Node | null): void {
  const prepass = computeStyleCore(el, parent);
  styleDescendants(el, parent, prepass);
}

/**
 * Everything a style pass does for one node — what it inherits, its cascade, and the values it
 * resolves — without its children, which `styleDescendants` walks next. The inherited-only fast
 * path computes its root this way first, to see what the change did before it decides how much of
 * the subtree needs a pass.
 */
function computeStyleCore(el: Node, parent: Node | null): PrepassNode | null {
  frameTimes.styled++;
  // Any value this pass writes can change a font run, so the remembered one is dropped here
  // rather than compared property by property on every font lookup.
  el.featValid = false;
  styleGen++;
  // Every value below can change a used display or spacing, so what this node remembered from
  // its previous pass is dropped. Other nodes keep theirs.
  el.styleGen++;
  if (parent === null) {
    if (!runningPrepass) {
      startUnsupportedCount();
      // A pass over the page records every query again.
      for (const c of queriedContainers) c.qListed = false;
      queriedContainers.length = 0;
    }
    // A pass starts at the document's root: the runtime sheets in document order, then the
    // adopted ones, which a style sheet's rules cascade against.
    resetMediaPass();
    activeSheets = [];
    collectSheets(document.documentElement, activeSheets, null);
    for (const s of ADOPTED) activeSheets.push({ sheet: s, scope: null });
    counterState.clear();
    reversedInitials = null;
    if (!runningPrepass && hasReversedCounters()) {
      // A reversed counter's start depends on increments later in the document, so the styles
      // are worked out once before the counters are applied (see collectReversedInitials).
      runningPrepass = true;
      prepassNodes = [];
      const nodes = prepassNodes;
      computeStyles(el, null);
      runningPrepass = false;
      prepassNodes = null;
      reversedInitials = collectReversedInitials(nodes);
      // The prepass left the pass's state behind: run the real walk from a clean start.
      activeSheets = [];
      collectSheets(document.documentElement, activeSheets, null);
      for (const s of ADOPTED) activeSheets.push({ sheet: s, scope: null });
      counterState.clear();
    }
  }
  if (el.rulesStale && el instanceof Element) resolveDynamicRules(el);
  // A compiled pseudo rule that only starts matching at runtime gets its carrier box here, and
  // every pass rechecks the dynamic table, since a class or state can start matching at any time.
  // A generated box is never a carrier's parent, so carriers don't sync carriers.
  if (el instanceof Element && el.pseudoKind === P.PE_NONE) syncCarriers(el);
  // The container sizes this pass reads are recorded again by the queries that read them, so a
  // layout that changes one of them can tell the answers are out of date (see containerStale).
  el.qUsedW = -1;
  el.qUsedH = -1;
  const sv = el.sv;
  const su = el.su;
  // A text node lays out the data it has now; a flex run may then fold it into a sibling.
  if (el.isTextNode) el.layoutText = el.ownText;
  for (let p = 0; p < P.PROP_COUNT; p++) {
    if (parent !== null && INHERITS[p]) {
      sv[p] = parent.sv[p];
      su[p] = parent.su[p];
    } else {
      sv[p] = INITIAL_V[p];
      su[p] = INITIAL_U[p];
    }
  }
  // A colour's computed form inherits with its value, so a child reads back what its parent set.
  if (el instanceof Element) {
    if (el.colorForm !== null) el.colorForm.clear();
    if (parent instanceof Element && parent.colorForm !== null) {
      for (const [p, form] of parent.colorForm) if (INHERITS[p]) rememberColorForm(el, p, form);
    }
  }
  fontSizeDeclared = false;
  el.decorDeclared = false;
  el.faceDeclared = false;
  // A slot assignment or a shadow tree may have changed since the last pass.
  el.flat = null;
  // The four-sided declarations this element applies, and the order the cascade gave them.
  sideOrder.fill(0);
  sideSeq = 0;
  logicalAt.length = 0;
  if (el instanceof Element) {
    // What this element's own declarations set, and what they are computed from, are made again:
    // the inherited-only fast path reads them until the next pass.
    if (el.inhDeclared !== null) el.inhDeclared.fill(0);
    if (el.inhDepends !== null) el.inhDepends.fill(0);
    // A generated box is inline whatever its originating element's display is. The placeholder
    // box is only a carrier for ::placeholder's style: the field draws the text itself.
    if (el.pseudoKind === P.PE_PLACEHOLDER || el.pseudoKind === P.PE_FIRST_LINE ||
      el.pseudoKind === P.PE_FIRST_LETTER || el.pseudoKind === P.PE_SELECTION ||
      el.pseudoKind === P.PE_HIGHLIGHT || el.pseudoKind === P.PE_TARGET_TEXT) sv[P.P_DISPLAY] = P.D_NONE;
    else if (el.pseudoKind === P.PE_SCROLL_MARKER) sv[P.P_DISPLAY] = P.D_INLINE_BLOCK;
    else if (el.pseudoKind === P.PE_SCROLL_MARKER_GROUP) sv[P.P_DISPLAY] = P.D_INLINE_BLOCK;
    else if (el.pseudoKind !== P.PE_NONE) sv[P.P_DISPLAY] = P.D_INLINE;
    // A runtime sheet may generate a box for this element, or react to its state.
    if (el.pseudoKind === P.PE_NONE) prepareRuntimeBoxes(el);
    // The properties a ::placeholder or ::selection box's rules declare are recorded for the
    // painter that draws with them; only its own declarations count, not what it inherits.
    if (el.pseudoKind === P.PE_PLACEHOLDER || el.pseudoKind === P.PE_SELECTION ||
      el.pseudoKind === P.PE_HIGHLIGHT || el.pseudoKind === P.PE_TARGET_TEXT) {
      if (el.declaredProps === null) el.declaredProps = new Uint8Array(P.PROP_COUNT);
      else el.declaredProps.fill(0);
    }
    // A generated box is styled by the element it belongs to: its parent, or for a box that
    // lives elsewhere in the tree (a scroll marker in its group) the origin it records.
    const test = pseudoTest(el);
    const runtime = test !== null ? runtimeMatches(test, el.pseudoKind) : [];
    // Custom properties inherit, and the element's own declarations override them; every var()
    // resolves against the settled cascade, so this comes before any declaration is applied.
    el.cprops = collectCustoms(el, runtime, parent);
    // The cascade, in order: normal rules, the inline style's normal declarations, important
    // rules, then the inline style's important declarations (which beat author !important).
    // Runtime sheets are later in the document than the compiled ones, so their rules apply
    // after the compiled rules of the same importance.
    // The properties an important declaration sets are remembered for the animation engine.
    el.impProps.length = 0;
    // The `dir` attribute is a presentation hint: it sits below every rule, so an author
    // `direction` still wins.
    if (el.pseudoKind === P.PE_NONE) applyDirHint(el);
    applyRules(el, false, parent);
    applyRuntime(el, runtime, false, parent);
    applyInline(el, false, parent);
    applyRules(el, true, parent);
    applyRuntime(el, runtime, true, parent);
    applyInline(el, true, parent);
    // The element's first state is the @starting-style one: those declarations apply over the
    // regular cascade for this pass only, so the transition from them to the real style runs.
    if (el.starting) applyStarting(el, parent);
    // The writing mode and direction are settled now, so the logical sides can find their own.
    resolveLogicalSides(el);
    // A declaration that names currentColor waited for the element's own colour, which the
    // cascade has now settled.
    if (deferredCurrent.length > 0) {
      const waiting = deferredCurrent;
      deferredCurrent = [];
      flushingCurrent = true;
      for (const d of waiting) applyText(el, d.prop, d.value, parent, d.important, d.author);
      flushingCurrent = false;
    }
    // currentColor: on `color` itself it is the inherited colour, and elsewhere the element's own.
    if (sv[P.P_COLOR] === -1) sv[P.P_COLOR] = parent !== null ? parent.sv[P.P_COLOR] : 0x000000ff;
    if (sv[P.P_BACKGROUND_COLOR] === -1) sv[P.P_BACKGROUND_COLOR] = sv[P.P_COLOR];
  } else {
    // A text run is an anonymous block box: it takes its parent's text alignment and display as
    // a block. A comment never draws or takes room.
    sv[P.P_DISPLAY] = el.nodeType === 3 ? P.D_BLOCK : P.D_NONE;
    // A text run has no declarations of its own, so it carries its parent's custom properties.
    el.cprops = parent === null ? null : parent.cprops;
  }

  // The query containers around this node, as the cascade settled them: paint-time lengths in cq
  // units read these instead of walking up the tree for every background, transform and mask.
  {
    const type = el instanceof Element ? sv[P.P_CONTAINER_TYPE] : P.CT_NORMAL;
    const inline = parent !== null ? parent.cqInline : null;
    const block = parent !== null ? parent.cqBlock : null;
    el.cqInline = type !== P.CT_NORMAL ? el : inline;
    el.cqBlock = type === P.CT_SIZE ? el : block;
    el.cqKnown = true;
  }

  // The overflow axes have a computed-value rule of their own (CSS Overflow 3 §3.1): an axis that
  // is `visible` becomes `auto` when the other axis specifies a scrollable value. `clip` is left
  // as it is, so a box that clips one axis and scrolls the other is a single-axis scroll container
  // and the clipped axis is not scrollable at all.
  const scrolls = (v: number) => v === P.OV_HIDDEN || v === P.OV_AUTO || v === P.OV_SCROLL;
  const scrollX = scrolls(sv[P.P_OVERFLOW_X]);
  const scrollY = scrolls(sv[P.P_OVERFLOW_Y]);
  if (scrollY && sv[P.P_OVERFLOW_X] === P.OV_VISIBLE) sv[P.P_OVERFLOW_X] = P.OV_AUTO;
  if (scrollX && sv[P.P_OVERFLOW_Y] === P.OV_VISIBLE) sv[P.P_OVERFLOW_Y] = P.OV_AUTO;

  // font-size. `medium` is the font family's medium size, which only the generic `monospace`
  // family lowers (13px rather than 16px), and an em or percentage is relative to the parent's
  // size. A size that still rests on `medium` crosses to a fixed family scaled by the ratio of
  // the two medium sizes, so `1.5em` under a default-sized parent is 19.5px in monospace, and is
  // not scaled twice down a chain.
  const fixed = sv[P.P_FIXED_FONT] !== 0;
  const medium = fixed ? MONO_MEDIUM : MEDIUM;
  const parentMedium = parent !== null && parent.sv[P.P_FIXED_FONT] !== 0 ? MONO_MEDIUM : MEDIUM;
  const parentSize = parent !== null ? parent.sv[P.P_FONT_SIZE] : medium;
  let based = sv[P.P_MEDIUM_BASED] !== 0;
  let keyword = su[P.P_FONT_SIZE] === P.U_MEDIUM;
  if (fontSizeDeclared && !keyword) {
    const size = su[P.P_FONT_SIZE];
    if (size === P.U_EM) {
      sv[P.P_FONT_SIZE] = sv[P.P_FONT_SIZE] * parentSize;
    } else if (size === P.U_EXPR) {
      // A calc() that mixes units: its percentages and ems resolve against the parent's size.
      sv[P.P_FONT_SIZE] = exprLength(el, sv[P.P_FONT_SIZE], parentSize, parentSize);
      based = false;
    } else if (size === P.U_REM) {
      // A rem font size is a multiple of the root's, which is the initial size on the root itself.
      sv[P.P_FONT_SIZE] = sv[P.P_FONT_SIZE] * rootFontSize();
      based = false;
    } else if (size === P.U_SMALLER || size === P.U_LARGER) {
      // As in browsers, smaller and larger scale the parent's size by 1.2 either way.
      sv[P.P_FONT_SIZE] = size === P.U_SMALLER ? parentSize / 1.2 : parentSize * 1.2;
    } else {
      based = false;
    }
  } else if (keyword) {
    // `medium`, declared or inherited, is this element's own medium size, which its family may
    // make smaller; nothing is scaled, as the keyword already names this family's size.
    sv[P.P_FONT_SIZE] = medium;
    based = true;
  }
  if (fixed && based && !keyword) {
    // This family's medium size differs from the one the size was computed against.
    sv[P.P_FONT_SIZE] = sv[P.P_FONT_SIZE] * medium / parentMedium;
    based = false;
  }
  su[P.P_FONT_SIZE] = keyword ? P.U_MEDIUM : P.U_PX;
  sv[P.P_MEDIUM_BASED] = based ? 1 : 0;
  su[P.P_MEDIUM_BASED] = P.U_NONE;
  // An animation moving the font size decides what the other ems resolve against, not the size
  // the cascade names. The cascaded size is kept for the transition engine, whose baseline is
  // the size a change is measured from rather than the size a moving one shows.
  if (el instanceof Element) {
    const animated = animatedFontSize(el);
    if (animated >= 0) {
      el.cascadeFontSize = sv[P.P_FONT_SIZE];
      sv[P.P_FONT_SIZE] = animated;
    } else {
      el.cascadeFontSize = -1;
    }
  }
  // Every other em is relative to this element's font size.
  const size = sv[P.P_FONT_SIZE];
  for (let p = 0; p < P.PROP_COUNT; p++) {
    if (su[p] === P.U_EM) {
      sv[p] = sv[p] * size;
      su[p] = P.U_PX;
      continue;
    }
    if (su[p] === P.U_REM) {
      // A rem is a multiple of the root's font size, not this element's.
      sv[p] = sv[p] * rootFontSize();
      su[p] = P.U_PX;
      continue;
    }
    if (su[p] >= P.U_CQW && su[p] <= P.U_CQMAX) {
      // A container query unit is a percentage of the nearest container's content box, or of the
      // viewport when the element has no container above it.
      const unit = su[p];
      const w = cqLength(el, false);
      let base = w;
      if (unit === P.U_CQH || unit === P.U_CQB) base = cqLength(el, true);
      else if (unit === P.U_CQMIN) base = Math.min(w, cqLength(el, true));
      else if (unit === P.U_CQMAX) base = Math.max(w, cqLength(el, true));
      sv[p] = (sv[p] / 100) * base;
      su[p] = P.U_PX;
      continue;
    }
    if (p === P.P_LINE_HEIGHT && su[p] === P.U_PCT) {
      // A line-height percentage is a length relative to this element's own font size, computed
      // here so that a child inherits the length rather than the ratio.
      sv[p] = (sv[p] / 100) * size;
      su[p] = P.U_PX;
      continue;
    }
    // Some values are read straight from the style in layout, without a used-value pass of their
    // own, so an expression is worked out here. A line-height percentage is relative to this
    // element's own font size; any other property's expression must not need a percentage base.
    if (su[p] === P.U_EXPR && earlyExpr(p)) {
      if (p === P.P_LINE_HEIGHT || !exprHasPercent(sv[p])) {
        const px = exprLength(el, sv[p], p === P.P_LINE_HEIGHT ? size : 0, size);
        if (!Number.isNaN(px)) {
          sv[p] = px;
          su[p] = P.U_PX;
        }
      }
    }
  }
  // bolder and lighter are relative to the inherited weight (CSS Fonts 4).
  if (su[P.P_FONT_WEIGHT] === P.U_BOLDER) {
    sv[P.P_FONT_WEIGHT] = bolderWeight(parent !== null ? parent.sv[P.P_FONT_WEIGHT] : 400);
    su[P.P_FONT_WEIGHT] = P.U_NONE;
  } else if (su[P.P_FONT_WEIGHT] === P.U_LIGHTER) {
    sv[P.P_FONT_WEIGHT] = lighterWeight(parent !== null ? parent.sv[P.P_FONT_WEIGHT] : 400);
    su[P.P_FONT_WEIGHT] = P.U_NONE;
  }
  // The lh unit is the element's used line height. On line-height itself it is the parent's, as
  // otherwise it would depend on the very value it is setting.
  if (su[P.P_LINE_HEIGHT] === P.U_LH) {
    const parentLh = parent !== null ? lineHeightPx(parent) : normalLineHeight(sv[P.P_FONT_SIZE], fontKey(el));
    sv[P.P_LINE_HEIGHT] = sv[P.P_LINE_HEIGHT] * parentLh;
    su[P.P_LINE_HEIGHT] = P.U_PX;
  }
  const lhPx = lineHeightPx(el);
  for (let p = 0; p < P.PROP_COUNT; p++) {
    if (su[p] === P.U_LH) {
      sv[p] = sv[p] * lhPx;
      su[p] = P.U_PX;
    }
  }
  // A border with no style, or a hidden one, has no used width: it isn't drawn and takes no
  // room. The declared width is kept in the cascade, so setting a style later brings it back.
  if (sv[P.P_BORDER_TOP_STYLE] === P.BRS_NONE || sv[P.P_BORDER_TOP_STYLE] === P.BRS_HIDDEN) {
    sv[P.P_BORDER_TOP_WIDTH] = 0;
    su[P.P_BORDER_TOP_WIDTH] = P.U_PX;
  }
  if (sv[P.P_BORDER_RIGHT_STYLE] === P.BRS_NONE || sv[P.P_BORDER_RIGHT_STYLE] === P.BRS_HIDDEN) {
    sv[P.P_BORDER_RIGHT_WIDTH] = 0;
    su[P.P_BORDER_RIGHT_WIDTH] = P.U_PX;
  }
  if (sv[P.P_BORDER_BOTTOM_STYLE] === P.BRS_NONE || sv[P.P_BORDER_BOTTOM_STYLE] === P.BRS_HIDDEN) {
    sv[P.P_BORDER_BOTTOM_WIDTH] = 0;
    su[P.P_BORDER_BOTTOM_WIDTH] = P.U_PX;
  }
  if (sv[P.P_BORDER_LEFT_STYLE] === P.BRS_NONE || sv[P.P_BORDER_LEFT_STYLE] === P.BRS_HIDDEN) {
    sv[P.P_BORDER_LEFT_WIDTH] = 0;
    su[P.P_BORDER_LEFT_WIDTH] = P.U_PX;
  }
  if (el.hiddenFlag) sv[P.P_DISPLAY] = P.D_NONE;
  let prepassEntry: PrepassNode | null = null;
  if (runningPrepass) {
    // The style is settled: record what this element counts and where its subtree ends.
    const element = el instanceof Element ? el : null;
    prepassEntry = {
      el,
      index: prepassNodes!.length,
      end: 0,
      resets: element === null ? [] : declaredCounters(element, P.P_COUNTER_RESET),
      sets: element === null ? [] : declaredCounters(element, P.P_COUNTER_SET),
      increments: element === null ? [] : declaredCounters(element, P.P_COUNTER_INCREMENT),
      listItem: element !== null && sv[P.P_DISPLAY] === P.D_LIST_ITEM,
      hidden: sv[P.P_DISPLAY] === P.D_NONE,
    };
    prepassNodes!.push(prepassEntry);
  } else {
    // Counters follow document order, and a pseudo-element's own counter-increment counts before
    // the content it generates reads the counters, so this comes before the generated text below.
    applyCounters(el);
  }
  // Generated content: the pseudo-element's text comes from `content`, and one whose content
  // is none isn't generated at all, so it gets no box. A marker draws the list marker instead.
  if (el instanceof Element) {
    if (!runningPrepass) {
      if (el.pseudoKind === P.PE_MARKER) applyMarker(el);
      else if (el.pseudoKind !== P.PE_NONE && el.pseudoKind !== P.PE_PLACEHOLDER &&
        el.pseudoKind !== P.PE_FIRST_LINE && el.pseudoKind !== P.PE_FIRST_LETTER &&
        el.pseudoKind !== P.PE_SELECTION && el.pseudoKind !== P.PE_HIGHLIGHT &&
        el.pseudoKind !== P.PE_TARGET_TEXT && el.pseudoKind !== P.PE_SCROLL_MARKER &&
        el.pseudoKind !== P.PE_SCROLL_MARKER_GROUP) applyContent(el);
    }
    // Every list item has a marker box, including one that only became a list item at runtime.
    if (sv[P.P_DISPLAY] === P.D_LIST_ITEM && el.markerPseudo === null) el.ensureMarker();
    // A marker with no content of its own draws a bullet, as CSS Overflow 5's default does.
    if (el.pseudoKind === P.PE_SCROLL_MARKER && el.ownText === "" &&
      !declaresProperty(el, P.P_CONTENT, "content")) el.ownText = "\u2022";
    // A scroll container that asks for a marker group makes one; its children make the markers.
    if (el.pseudoKind === P.PE_NONE) syncScrollMarkers(el);
  }
  el.wasInline = false;
  // An absolutely positioned box is blockified (except for a flex container, which stays flex).
  if (!el.isTextNode && (sv[P.P_POSITION] === P.POS_ABSOLUTE || sv[P.P_POSITION] === P.POS_FIXED)) {
    if (isInlineLevelDisplay(sv[P.P_DISPLAY])) {
      // An inline-level box keeps an inline static position even though it is blockified.
      el.wasInline = true;
      sv[P.P_DISPLAY] = blockified(sv[P.P_DISPLAY]);
    }
  }
  // A float is block-level, whatever its display was. It has no effect on a flex item.
  if (!el.isTextNode && sv[P.P_FLOAT] !== P.FL_NONE && (parent === null || !isFlexContainer(parent))) {
    const d = sv[P.P_DISPLAY];
    // One that was inline-level belongs to the inline content it sits in, not to the block flow
    // around it (CSS 2.1 9.5).
    if (isInlineLevelDisplay(d)) el.wasInline = true;
    // CSS 2.1 9.7: every table-internal display computes to block, so the float is a block and
    // the table parts inside it get anonymous tables of their own.
    if (d === P.D_INLINE || d === P.D_INLINE_BLOCK ||
      (d >= P.D_TABLE_ROW_GROUP && d <= P.D_TABLE_CAPTION)) sv[P.P_DISPLAY] = P.D_BLOCK;
    else if (d === P.D_INLINE_TABLE) sv[P.P_DISPLAY] = P.D_TABLE;
    else if (d === P.D_INLINE_FLEX) sv[P.P_DISPLAY] = P.D_FLEX;
    else if (d === P.D_INLINE_GRID) sv[P.P_DISPLAY] = P.D_GRID;
    else if (d === P.D_INLINE_GRID_LANES) sv[P.P_DISPLAY] = P.D_GRID_LANES;
    // So does a table part: a floated row, column, caption or the like is a block, and the cells
    // inside it are then table-internal boxes without a table around them, which the fixup wraps
    // in an anonymous table (CSS 2.1 9.7, 17.2.1).
    else if (d >= P.D_TABLE_ROW_GROUP && d <= P.D_TABLE_CAPTION) sv[P.P_DISPLAY] = P.D_BLOCK;
  }
  // A text node is no box of its own: inheriting `display: contents` from the box it sits in
  // would leave it with nothing to lay out or paint it, so its text is inline there.
  if (el.isTextNode && sv[P.P_DISPLAY] === P.D_CONTENTS) sv[P.P_DISPLAY] = P.D_INLINE;
  // Flex and grid items are blockified; whitespace-only text in one isn't rendered. A display:
  // contents box generates no box, so what it holds are items of the container the contents boxes
  // are flattened into — the item parent is the nearest ancestor that generates a box.
  let itemParent = parent;
  while (itemParent !== null && itemParent.sv[P.P_DISPLAY] === P.D_CONTENTS) itemParent = itemParent.parentElement;
  if (itemParent !== null && (isFlexContainer(itemParent) || isGridContainer(itemParent) || isLanesContainer(itemParent)) && sv[P.P_DISPLAY] !== P.D_NONE) {
    // A text run's white space is not rendered as a flex item when it all collapses; a
    // preserved character such as an ideographic space makes it one.
    if (el.isTextNode && !/[^ \t\f\r\n]/.test(el.layoutText)) sv[P.P_DISPLAY] = P.D_NONE;
    else if (isInlineLevelDisplay(sv[P.P_DISPLAY])) sv[P.P_DISPLAY] = blockified(sv[P.P_DISPLAY]);
  }

  // A table box, row group or row that holds its own text turns it into a child: the table fixup
  // then wraps that text in the anonymous cell (and row) CSS puts around it.
  const part = sv[P.P_DISPLAY];
  if (el.ownText !== "" && el.children.length === 0 &&
    (part === P.D_TABLE || part === P.D_INLINE_TABLE || part === P.D_TABLE_ROW ||
      part === P.D_TABLE_ROW_GROUP || part === P.D_TABLE_HEADER_GROUP || part === P.D_TABLE_FOOTER_GROUP)) {
    materializeText(el);
  }

  // The element's cascade is complete: transitions and animations start from it, and the values
  // they have reached are written before the children are computed, so they inherit them.
  if (el instanceof Element && !runningPrepass) {
    noteComputed(el);
    // The first state a @starting-style rule described is in place; from the next pass the
    // regular cascade applies, and the transition runs from the starting values to it.
    if (el.starting) {
      el.starting = false;
      startingDirty = true;
    }
  }
  // An element's color-scheme picks which of the platform's own colours it is drawn in — the UA
  // sheet's dark rules and the system colours both read this bit — and it inherits, so each
  // element keeps the bit itself. It is set before the children are styled, so they pick it up in
  // this pass; the element's own declarations were cascaded before the bit was known, so a
  // changed bit asks for one more pass for the element and its subtree.
  if (el instanceof Element) {
    // A subtree that keeps its parent's color-scheme keeps its answer too, so the media query one
    // written as `light dark` asks is only evaluated where a page names a scheme.
    const bits = el.sv[P.P_COLOR_SCHEME];
    const parentEl = parent instanceof Element ? parent : null;
    const dark = parentEl !== null && parentEl.sv[P.P_COLOR_SCHEME] === bits
      ? (parentEl.state & P.S_SCHEME_DARK) !== 0
      : usedDarkScheme(bits);
    if (dark !== ((el.state & P.S_SCHEME_DARK) !== 0)) {
      if (dark) el.state |= P.S_SCHEME_DARK;
      else el.state &= ~P.S_SCHEME_DARK;
      // The bit changed the element's own cascade, so it is computed again; its subtree follows
      // in styleDescendants, as it does for the pass that called this one.
      return computeStyleCore(el, parent);
    }
  }
  if (el instanceof Element) {
    // The state bits at the end of the element's own pass, so a restyle can tell which ones moved
    // and whether any rule below this element tests them. What changed about the element's
    // identity is seen now too, so a class set while it was detached doesn't linger.
    el.styleState = el.state;
    el.identClasses = null;
    el.identOther = false;
    el.identStructure = false;
  }
  return prepassEntry;
}

/**
 * Styles the node's children, and does the work that needs them: counter scopes ending, flex and
 * grid text runs merging, a drop cap's float lifting out, and the layout inputs of the box the
 * pass just gave a style.
 */
function styleDescendants(el: Node, parent: Node | null, prepassEntry: PrepassNode | null): void {
  // A shadow tree's elements inherit from their host, and a node a slot took inherits from that
  // slot — the flattened tree is the inheritance tree, not the DOM's.
  const shadow = el.shadowTree();
  let slotted: Node[] | null = null;
  if (shadow !== null) {
    slotted = [];
    for (const slot of slotsIn(shadow)) {
      for (const n of slotAssignedNodes(slot)) slotted.push(n);
    }
  }
  for (const c of el.kids) {
    if (slotted !== null && slotted.indexOf(c) >= 0) continue;
    computeStyles(c, el);
  }
  if (shadow !== null) for (const c of shadow.kids) computeStyles(c, el);
  if (el instanceof Element && el.localName === "slot") {
    for (const n of slotAssignedNodes(el)) computeStyles(n, el);
  }
  if (prepassEntry !== null) prepassEntry.end = prepassNodes!.length - 1;
  if (runningPrepass) return;
  // A counter-reset is in scope for its element and its subtree only, so it ends here: a reset
  // on a sibling leaves the counter its following siblings count in alone (counter-001). A
  // reversed one counts down across its following siblings, so it ends where its parent does.
  if (el.counterOwn !== null) popCounters(el.counterOwn, false);
  for (const c of el.kids) if (c.counterOwn !== null) popCounters(c.counterOwn, true);
  const merges = isFlexContainer(el) || isGridContainer(el) || isLanesContainer(el);
  if (merges) mergeTextRuns(el);
  // A floated ::first-letter lifts the letter into a box of its own, after the children above
  // have their styles (the carrier knows its float by then).
  if (el instanceof Element && el.pseudoKind === P.PE_NONE) syncFirstLetterFloat(el);
  if (incremental.on) {
    // Incremental layout learns here which boxes the pass changed. Merging text runs and lifting
    // a drop cap rewrite the children after their own pass ended, so they are looked at again.
    noteLayoutInputs(el);
    if (el instanceof Element && el.firstLetterFloat !== null) for (const c of el.kids) noteLayoutInputs(c);
    else if (merges) for (const c of el.kids) if (c.isTextNode) noteLayoutInputs(c);
  }
}

// ---------------------------------------------------------------------------
// The inherited-only fast path
//
// A class, attribute or inline style write on an element restyles its subtree (mount.ts). When the
// element's own pass changed only values that are painted — a theme switch's colours, say — and no
// rule can see the change on the element from below it, every descendant's own cascade is still
// what it was: each needs only the inherited values that moved and that it doesn't declare itself.
// This walks the subtree for that, instead of matching every selector again.

/** Turned off by NATIVE_INHERITED_ONLY=0, to measure (and check pixels) with and without it. */
const inheritedFastPathOn = process.env.NATIVE_INHERITED_ONLY !== "0";

/** The properties whose change is painted and nothing else, made once from their names. */
let paintOnlyCache: Uint8Array | null = null;

function paintOnlyTable(): Uint8Array {
  if (paintOnlyCache !== null) return paintOnlyCache;
  const paint = new Uint8Array(P.PROP_COUNT);
  for (let p = 0; p < P.PROP_COUNT; p++) {
    const n = P.PROPERTY_NAMES[p];
    if (n === "color" || n === "fill" || n === "stroke" || n === "fill-opacity" ||
      n === "stroke-opacity" || n === "opacity" || n.endsWith("-color") ||
      n.startsWith("background") || n === "box-shadow" || n === "text-shadow" ||
      n === "filter" || n === "backdrop-filter" || n === "mix-blend-mode" || n === "isolation" ||
      n.startsWith("mask") || n.startsWith("clip-path") || n.startsWith("outline") ||
      n.startsWith("text-decoration") || n.startsWith("text-emphasis") ||
      n === "cursor" || n === "pointer-events" || n === "user-select") paint[p] = 1;
  }
  paintOnlyCache = paint;
  return paint;
}

/** The properties a pass changed on `el`, or null when one of them is more than a painted value. */
function changedPaintOnly(el: Node, oldV: Float64Array, oldU: Float64Array): { mask: Uint32Array; list: number[] } | null {
  const paint = paintOnlyTable();
  const mask = new Uint32Array(PROP_WORDS);
  const list: number[] = [];
  let paintOnly = true;
  for (let p = 0; p < P.PROP_COUNT; p++) {
    if (el.sv[p] === oldV[p] && el.su[p] === oldU[p]) continue;
    list.push(p);
    setPropBit(mask, p);
    if (paint[p] === 0) paintOnly = false;
  }
  return paintOnly ? { mask, list } : null;
}

function sameCustoms(a: Map<string, string> | null, b: Map<string, string> | null): boolean {
  if (a === b) return true;
  if (a === null || b === null || a.size !== b.size) return false;
  for (const [k, v] of a) if (b.get(k) !== v) return false;
  return true;
}

/**
 * The class names any rule tests on an ancestor, so a class the restyled element gained or lost
 * only matters to its descendants if one of them is here. The other chain conditions (`id`,
 * attributes, `:not()`, `:has()`) are all-or-nothing: a page with any of them keeps the full pass
 * when the element's identity moved.
 */
let chainIndexFor: number[][] | null = null;
let ancestorClassNames: Set<string> | null = null;
let ancestorChainsTestMore = false;
/**
 * The state bits a rule tests on a compound other than its subject — an ancestor or an earlier
 * sibling — so a move of one of them can change what an element's descendants or later siblings
 * match. (tables.chainStateMask also counts each rule's own states.) A compound with `:not()` or
 * `:has()` counts as testing every state.
 */
let ancestorStates = 0;
/** The state bits a rule's own `:not()` tests, which an element's sensitiveStates leave out. */
let notStates = 0;

function ensureChainIndex(): void {
  if (chainIndexFor === tables.chainComb) return;
  chainIndexFor = tables.chainComb;
  ancestorClassNames = null;
  ancestorChainsTestMore = false;
  ancestorStates = 0;
  notStates = 0;
  for (let r = 0; r < tables.ruleNots.length; r++) {
    for (const n of tables.ruleNots[r]) {
      for (const tok of notTokensOf(n)) if (tok.charAt(0) === "s") notStates |= Number(tok.slice(1));
    }
  }
  for (let r = 0; r < tables.chainComb.length; r++) {
    if (r < tables.chainStates.length) for (const st of tables.chainStates[r]) ancestorStates |= st;
    if (r < tables.chainNots.length) {
      for (const nots of tables.chainNots[r]) if (nots.length > 0) ancestorStates = -1;
    }
    if (r < tables.chainHas.length) {
      for (const has of tables.chainHas[r]) if (has.length > 0) ancestorStates = -1;
    }
    const links = r < tables.chainClasses.length ? tables.chainClasses[r] : null;
    if (links !== null) {
      for (const link of links) {
        for (const c of link) {
          if (ancestorClassNames === null) ancestorClassNames = new Set<string>();
          ancestorClassNames.add(c);
        }
      }
    }
    if (r < tables.chainId.length) {
      for (const id of tables.chainId[r]) if (id !== "") { ancestorChainsTestMore = true; break; }
    }
    if (r < tables.chainAttrs.length) {
      for (const attrs of tables.chainAttrs[r]) if (attrs.length > 0) { ancestorChainsTestMore = true; break; }
    }
    if (r < tables.chainLang.length) {
      for (const langs of tables.chainLang[r]) if (langs.length > 0) { ancestorChainsTestMore = true; break; }
    }
    if (r < tables.chainDir.length) {
      for (const dir of tables.chainDir[r]) if (dir !== 0) { ancestorChainsTestMore = true; break; }
    }
    if (r < tables.chainNots.length) {
      for (const nots of tables.chainNots[r]) if (nots.length > 0) { ancestorChainsTestMore = true; break; }
    }
    if (r < tables.chainHas.length) {
      for (const has of tables.chainHas[r]) if (has.length > 0) { ancestorChainsTestMore = true; break; }
    }
  }
  // A rule whose subject holds :has() looks down at its descendants, so a state change anywhere
  // below the element can change what it matches.
  for (let r = 0; r < tables.ruleHas.length; r++) {
    if (tables.ruleHas[r].length > 0) { ancestorStates = -1; break; }
  }
}

/**
 * True when the change to `el` can alter what a rule matches in its descendants: a class the page
 * names on an ancestor, an id or attribute test, a moved state a `:nth-*` or state rule below it
 * tests, a child list whose positions and text runs the pass has to see, or any runtime sheet at
 * all, whose selectors this engine can't index.
 */
function descendantsCanSeeChange(el: Element, ident: IdentityChange, stateDelta: number): boolean {
  // A child list moved: `:nth-child` below it, `:empty`, and a flex or grid run that has to merge
  // all need the pass.
  if (ident.structure) return true;
  const identityMoved = (ident.classes !== null && ident.classes.length > 0) || ident.other;
  if (identityMoved && runtimeRulesExist()) return true;
  // A filter or a complex :not() argument can look at the element from a descendant's rule too.
  if (identityMoved && sideLookingRulesExist()) return true;
  // A filtered ancestor compound matches through its descendants' positions, so a restyled root
  // can change what a rule below it matches even when the root's own style did not move.
  if (chainNthOfRulesExist()) return true;
  ensureChainIndex();
  // An inline style is an attribute too: a page whose chains test attributes may look for it.
  if (el.styleDecl !== null && ancestorChainsTestMore) return true;
  if (ident.classes !== null && ident.classes.length > 0) {
    if (ancestorChainsTestMore) return true;
    if (ancestorClassNames !== null) {
      for (const c of ident.classes) if (ancestorClassNames.has(c)) return true;
    }
  }
  if (ident.other && ancestorChainsTestMore) return true;
  if (stateDelta !== 0 && (ancestorStates & stateDelta) !== 0) return true;
  return false;
}

function dependsOnAny(bits: Uint32Array | null, mask: Uint32Array): boolean {
  if (bits === null) return false;
  for (let w = 0; w < bits.length; w++) if ((bits[w] & mask[w]) !== 0) return true;
  return false;
}

/** Copies the inherited values that moved into `c`, less the ones it declares itself. */
function copyInherited(c: Node, parent: Node, list: number[]): void {
  // Font properties inherit, so a copied value can move the child's run.
  c.featValid = false;
  // Letter and word spacing inherit, so a copied value moves the child's remembered spacing.
  c.styleGen++;
  const cv = c.sv;
  const cu = c.su;
  const pv = parent.sv;
  const pu = parent.su;
  const declared = c.inhDeclared;
  const el = c instanceof Element ? c : null;
  const fromForms = parent instanceof Element ? parent.colorForm : null;
  for (let i = 0; i < list.length; i++) {
    const p = list[i];
    if (!INHERITS[p]) continue;
    if (hasPropBit(declared, p)) continue;
    cv[p] = pv[p];
    cu[p] = pu[p];
    // A modern colour function's computed form travels with the value it computed.
    if (el !== null) {
      const form = fromForms !== null ? fromForms.get(p) : undefined;
      if (form !== undefined) rememberColorForm(el, p, form);
      else forgetColorForm(el, p);
    }
  }
}

/** The subtree a shadow tree or a slot reshapes is styled in full, as it always was. */
function fullSubtree(c: Node, parent: Node | null): void {
  computeStyles(c, parent);
}

/**
 * Gives each descendant of `el` the inherited values that moved, and styles in full only the
 * branches whose own declarations are computed from them — a value that inherits explicitly, names
 * currentColor, or moves between passes itself (a transition or an animation).
 */
function fastWalk(el: Node, mask: Uint32Array, list: number[]): void {
  // The flattened tree is the inheritance tree, and where a shadow tree or a slot is involved it
  // is not the DOM's.
  if (el.shadowTree() !== null || el.localName === "slot") {
    fullSubtree(el, el.parentNode instanceof Element ? el.parentNode : null);
    return;
  }
  const kids = el.kids;
  for (let i = 0; i < kids.length; i++) {
    const c = kids[i];
    // A node a slot took is styled through that slot, wherever its DOM parent is.
    if (c.assignedSlot !== null) continue;
    // A child with an identity change of its own — a class, attribute or child-list write in the
    // same frame — has its own cascade to redo, and does it itself.
    if (c instanceof Element && (c.identClasses !== null || c.identOther || c.identStructure || c.rulesStale)) {
      takeIdentityChange(c);
      fullSubtree(c, el);
      continue;
    }
    if (c.pseudoKind !== P.PE_NONE || c.sv.length === 0 || dependsOnAny(c.inhDepends, mask)) {
      fullSubtree(c, el);
      continue;
    }
    if (c instanceof Element && elementMoves(c)) {
      fullSubtree(c, el);
      continue;
    }
    copyInherited(c, el, list);
    fastWalk(c, mask, list);
  }
}

/**
 * Restyles the subtree a localised change reached, taking the inherited-only fast path when the
 * change can reach its descendants only through inheritance. The root itself is always cascaded;
 * when the fast path doesn't apply, the rest of the subtree is styled as a page pass would.
 */
export function restyleSubtree(root: Node, parent: Node | null): void {
  if (!inheritedFastPathOn || !(root instanceof Element) || root.pseudoKind !== P.PE_NONE ||
    parent === null || runningPrepass) {
    computeStyles(root, parent);
    return;
  }
  const oldV = root.sv.slice();
  const oldU = root.su.slice();
  const oldCprops = root.cprops;
  // The state bits at the root's last pass: a hover or focus that moved since then is what its
  // descendants have to be checked against.
  const oldState = root.styleState;
  // What changed about the element is taken before it is styled: its own pass counts as having
  // seen it, so the flags only say what the descendants have to be checked against.
  const ident = takeIdentityChange(root);
  const prepass = computeStyleCore(root, parent);
  const changed = changedPaintOnly(root, oldV, oldU);
  const customsMoved = !sameCustoms(root.cprops, oldCprops);
  if (changed === null || customsMoved || descendantsCanSeeChange(root, ident, oldState ^ root.state)) {
    styleDescendants(root, parent, prepass);
    return;
  }
  if (changed.list.length === 0) {
    // Nothing moved, so the descendants keep their styles; only one that was never styled — a
    // subtree a script built while detached and just inserted — needs the full pass.
    for (const c of root.kids) {
      if (c.sv.length === 0) {
        styleDescendants(root, parent, prepass);
        return;
      }
    }
  } else {
    fastWalk(root, changed.mask, changed.list);
  }
  // The root's text or children can have moved without its style (an emptied box), and only
  // styleDescendants tells layout so otherwise.
  noteLayoutInputs(root);
}

/**
 * An interaction state (hover, active, focus) moved on `el`. When only rules on the element itself
 * test that state, its own cascade is all that can change, and its subtree follows through
 * inheritance (restyleSubtree's fast path), so the element is restyled rather than the page. A
 * state a rule tests on an ancestor or an earlier sibling restyles the subtrees that can match it
 * (invalidateStyleOf); with a runtime sheet, whose selectors aren't indexed, the page is restyled.
 */
export function restyleForState(el: Node, bits: number): void {
  if (runtimeRulesExist()) {
    // A runtime sheet's selectors aren't indexed: the page pass, as before, when any rule tests it.
    if (((el.sensitiveStates | tables.chainStateMask) & bits) !== 0) invalidateStyle();
    return;
  }
  ensureChainIndex();
  if (((el.sensitiveStates | ancestorStates | notStates) & bits) === 0) return;
  // A rule that tests the state on an ancestor matches below the element, so its subtree is
  // restyled in full (restyleSubtree sees the state move and keeps the full pass).
  if ((ancestorStates & bits) !== 0) {
    invalidateStyleOf(el);
    return;
  }
  if (el instanceof Element && !stateFlipsARule(el, bits)) return;
  invalidateStyleOf(el, false);
}

/**
 * Whether one of the rules `el` could match (its own, or a generated box's it makes) matches
 * differently with the state bits it had at its last style pass than with the ones it has now. An
 * element is a candidate for a `:hover` rule on any class it might gain, so the state alone
 * says little; only a rule whose other tests pass can change its cascade.
 */
function stateFlipsARule(el: Element, bits: number): boolean {
  const now = el.state;
  const before = (now & ~bits) | (el.styleState & bits);
  if (before === now) return false;
  const lists: (readonly number[])[] = [el.rules];
  for (const c of el.kids) if (c.pseudoKind !== P.PE_NONE && c instanceof Element) lists.push(c.rules);
  try {
    for (let i = 0; i < lists.length; i++) {
      const owner = i === 0 ? el : null;
      for (const r of lists[i]) {
        const states = tables.ruleStates[r] | ruleNotStates(r);
        if ((states & bits) === 0) continue;
        // A form state is worked out while a rule is tested, which rewrites the element's bits.
        if ((states & P.S_FORM_STATES) !== 0) return true;
        const target = owner !== null ? owner : pseudoBoxOf(el, lists[i]);
        if (target === null) return true;
        el.state = before;
        const was = ruleApplies(target, r);
        el.state = now;
        if (ruleApplies(target, r) !== was) return true;
      }
    }
  } finally {
    el.state = now;
  }
  return false;
}

/** The generated box among `el`'s children whose rule list is `rules`. */
function pseudoBoxOf(el: Element, rules: readonly number[]): Element | null {
  for (const c of el.kids) if (c instanceof Element && c.pseudoKind !== P.PE_NONE && c.rules === rules) return c;
  return null;
}

/** The state bits each rule's own `:not()` tests, made once per table set. */
let notStatesFor: string[][] | null = null;
let notStatesByRule: number[] = [];

function ruleNotStates(r: number): number {
  if (notStatesFor !== tables.ruleNots) {
    notStatesFor = tables.ruleNots;
    notStatesByRule = [];
    for (let i = 0; i < tables.ruleNots.length; i++) {
      let m = 0;
      for (const n of tables.ruleNots[i]) {
        for (const tok of notTokensOf(n)) if (tok.charAt(0) === "s") m |= Number(tok.slice(1));
      }
      notStatesByRule.push(m);
    }
  }
  return r < notStatesByRule.length ? notStatesByRule[r] : 0;
}

/** The first child text node an element's own text lives in, making one if it holds its text
 *  alone; null when the element has no text to start with. */
function firstTextChild(el: Element): Node | null {
  for (const c of el.kids) if (c.isTextNode) return c;
  if (el.ownText === "") return null;
  // The pass walked this element's children before the text became a node, so the text node is
  // made here, where the text holds in the element (after the carriers), and styled on the spot.
  const text = new Text(el.ownText);
  text.parentNode = el;
  let at = 0;
  while (at < el.kids.length && el.kids[at].pseudoKind !== P.PE_NONE) at++;
  el.kids.splice(at, 0, text);
  el.ownText = "";
  textVersion.n++;
  // The pass walked this element's children before the text became a node, so style it here.
  computeStyles(text, el);
  return text;
}

/**
 * A ::first-letter whose rule floats it makes a drop cap: the letter leaves the text's layout
 * and a floated box of the letter's own style draws it, so the rest of the text wraps beside it
 * and under it. The text node keeps the letter as its data — the element's textContent still has
 * it — and lays out from the character after it.
 */
function syncFirstLetterFloat(el: Element): void {
  const carrier = el.firstLetterPseudo;
  const floating = carrier !== null && carrier.sv[P.P_FLOAT] !== P.FL_NONE;
  if (!floating) {
    dropFirstLetterFloat(el);
    return;
  }
  const text = firstTextChild(el);
  if (text === null) {
    dropFirstLetterFloat(el);
    return;
  }
  // The letter takes the punctuation around it, as ::first-letter does; leading space stays with
  // the text.
  const n = firstLetterLength(text.ownText, langOf(el));
  if (n === 0) return;
  let box = el.firstLetterFloat;
  if (box === null) {
    box = newElementFor(P.PSEUDO_TAGS[P.PE_FIRST_LETTER], "", "", carrier.rules, 0, false);
    box.pseudoOrigin = el;
    box.parentNode = el;
    el.kids.unshift(box);
    el.firstLetterFloat = box;
  } else {
    box.rules = carrier.rules;
  }
  box.ownText = text.ownText.slice(0, n);
  // The box was made after the pass walked this element's children, so style it here. A float is
  // a block-level box whatever the pseudo-element's own display says.
  computeStyles(box, el);
  box.sv[P.P_DISPLAY] = P.D_BLOCK;
  text.layoutText = text.ownText.slice(n);
}

/** Takes a drop cap's float box back out, leaving the letter in the text's layout again. */
function dropFirstLetterFloat(el: Element): void {
  const box = el.firstLetterFloat;
  if (box === null) return;
  const at = el.kids.indexOf(box);
  if (at >= 0) el.kids.splice(at, 1);
  box.parentNode = null;
  el.firstLetterFloat = null;
  for (const c of el.kids) {
    if (!c.isTextNode) continue;
    if (c.layoutText !== c.ownText) c.layoutText = c.ownText;
    break;
  }
}

/**
 * A flex container wraps each contiguous sequence of child text runs in one anonymous flex item,
 * and an element that isn't rendered (`display: none`) doesn't break the sequence. The runs are
 * folded into the first text node of the sequence so they lay out as one block item.
 */
function mergeTextRuns(el: Node): void {
  let run: Node | null = null;
  for (const c of el.kids) {
    if (c.isTextNode) {
      if (run === null) {
        run = c;
      } else {
        // Only the layout text moves: the nodes keep their data, so a later write to either
        // one still means what it says.
        run.layoutText += c.layoutText;
        c.layoutText = "";
        c.sv[P.P_DISPLAY] = P.D_NONE;
        // A run that starts with white space is no item until some text joins it.
        if (run.sv[P.P_DISPLAY] === P.D_NONE && /[^ \t\f\r\n]/.test(run.layoutText)) run.sv[P.P_DISPLAY] = P.D_BLOCK;
      }
    } else if (c.sv[P.P_DISPLAY] !== P.D_NONE) {
      run = null;
    }
  }
}

/**
 * Applies the declarations of the @starting-style rules that match the element, over the regular
 * cascade: they describe the style a transition starts from before the element first draws.
 */
function applyStarting(el: Element, parent: Node | null): void {
  const sv = el.sv;
  const su = el.su;
  for (const r of el.rules) {
    if (ruleStandsDown(r)) continue;
    if (r >= tables.ruleStarting.length || !tables.ruleStarting[r]) continue;
    if (!ruleApplies(el, r)) continue;
    const d = tables.ruleDecls[r];
    for (let k = 0; k + 2 < d.length; k += 3) {
      if (d[k] < 0) {
        const id = -1 - d[k];
        const prop = tables.textDeclProps[id];
        if (!isCustom(prop)) applyText(el, prop, tables.textDeclValues[id], parent, false);
        continue;
      }
      sv[d[k]] = d[k + 1];
      su[d[k]] = d[k + 2];
      noteSide(d[k], d[k + 1], d[k + 2], false);
      noteDeclared(el, d[k]);
      noteDecor(el, d[k]);
    }
  }
}

// A logical margin, padding or offset names a side of the box's own axes, so which physical side
// it settles on depends on the element's writing mode and direction — known only once its
// declarations have cascaded. Those declarations are noted with the order the cascade gave them,
// and settled after it: a physical declaration and a logical one for the same side compete by that
// order, the later winning (CSS Logical 1 §4).
const sideOrder = new Int32Array(42);
// The physical corner slots' two radius ids, in the corner order the slots use.
const CORNER_X = [P.P_BORDER_TOP_LEFT_RADIUS, P.P_BORDER_TOP_RIGHT_RADIUS, P.P_BORDER_BOTTOM_RIGHT_RADIUS, P.P_BORDER_BOTTOM_LEFT_RADIUS];
const CORNER_Y = [P.P_BORDER_TOP_LEFT_RADIUS_Y, P.P_BORDER_TOP_RIGHT_RADIUS_Y, P.P_BORDER_BOTTOM_RIGHT_RADIUS_Y, P.P_BORDER_BOTTOM_LEFT_RADIUS_Y];
let sideSeq = 0;
const logicalAt: number[] = [];

/** Which of the four-sided properties a physical one is, or -1. */
function sideSlot(p: number): number {
  if (p >= P.P_MARGIN_TOP && p <= P.P_MARGIN_LEFT) return p - P.P_MARGIN_TOP;
  if (p >= P.P_PADDING_TOP && p <= P.P_PADDING_LEFT) return 4 + p - P.P_PADDING_TOP;
  if (p >= P.P_TOP && p <= P.P_LEFT) return 8 + p - P.P_TOP;
  if (p >= P.P_BORDER_TOP_WIDTH && p <= P.P_BORDER_LEFT_WIDTH) return 12 + p - P.P_BORDER_TOP_WIDTH;
  if (p >= P.P_BORDER_TOP_STYLE && p <= P.P_BORDER_LEFT_STYLE) return 16 + p - P.P_BORDER_TOP_STYLE;
  if (p >= P.P_BORDER_TOP_COLOR && p <= P.P_BORDER_LEFT_COLOR) return 20 + p - P.P_BORDER_TOP_COLOR;
  // A size has one physical counterpart rather than four sides, so the property is the slot.
  if (p === P.P_WIDTH) return 24;
  if (p === P.P_HEIGHT) return 25;
  if (p === P.P_MIN_WIDTH) return 26;
  if (p === P.P_MIN_HEIGHT) return 27;
  if (p === P.P_MAX_WIDTH) return 28;
  if (p === P.P_MAX_HEIGHT) return 29;
  if (p >= P.P_SCROLL_MARGIN_TOP && p <= P.P_SCROLL_MARGIN_LEFT) return 34 + p - P.P_SCROLL_MARGIN_TOP;
  if (p >= P.P_SCROLL_PADDING_TOP && p <= P.P_SCROLL_PADDING_LEFT) return 38 + p - P.P_SCROLL_PADDING_TOP;
  // A corner's two radii share a slot: a logical corner sets both together.
  for (let i = 0; i < 4; i++) if (p === CORNER_X[i] || p === CORNER_Y[i]) return 30 + i;
  return -1;
}

/** The physical property a slot names; a corner's `logical` says which of its two radii. */
function slotProp(slot: number, logical: number): number {
  if (slot < 4) return P.P_MARGIN_TOP + slot;
  if (slot < 8) return P.P_PADDING_TOP + (slot - 4);
  if (slot < 12) return P.P_TOP + (slot - 8);
  if (slot < 16) return P.P_BORDER_TOP_WIDTH + (slot - 12);
  if (slot < 20) return P.P_BORDER_TOP_STYLE + (slot - 16);
  if (slot < 24) return P.P_BORDER_TOP_COLOR + (slot - 20);
  if (slot === 24) return P.P_WIDTH;
  if (slot === 25) return P.P_HEIGHT;
  if (slot === 26) return P.P_MIN_WIDTH;
  if (slot === 27) return P.P_MIN_HEIGHT;
  if (slot === 28) return P.P_MAX_WIDTH;
  if (slot === 29) return P.P_MAX_HEIGHT;
  if (slot >= 34 && slot < 38) return P.P_SCROLL_MARGIN_TOP + (slot - 34);
  if (slot >= 38) return P.P_SCROLL_PADDING_TOP + (slot - 38);
  const corner = slot - 30;
  const y = (logical - P.P_BORDER_START_START_RADIUS) % 2 === 1;
  return y ? CORNER_Y[corner] : CORNER_X[corner];
}

/**
 * The slot a logical side property names: its family, and the physical side its axes put it on. The
 * block axis runs down the page in a horizontal writing mode and across it in a vertical one, and
 * direction ticks the inline axis from its far end in rtl.
 */
function logicalSlot(p: number, vertical: boolean, rtl: boolean, vlr: boolean): number {
  // The scroll insets of the box's own frame settle onto the physical sides its axes name.
  if (p >= P.P_SCROLL_PADDING_BLOCK_START) {
    return logicalSide(38, p - P.P_SCROLL_PADDING_BLOCK_START, vertical, rtl, vlr);
  }
  if (p >= P.P_SCROLL_MARGIN_BLOCK_START) {
    return logicalSide(34, p - P.P_SCROLL_MARGIN_BLOCK_START, vertical, rtl, vlr);
  }
  if (p >= P.P_BORDER_START_START_RADIUS) {
    // A logical corner: its block side and its inline side pick the physical corner.
    const k = (p - P.P_BORDER_START_START_RADIUS) >> 1;
    return 30 + logicalCorner(k, vertical, rtl, vlr);
  }
  // A logical size is a width or a height: the inline axis is the inline size and the block axis
  // the block size, whichever way the page is written.
  if (p >= P.P_INLINE_SIZE) {
    const base = p >= P.P_MAX_INLINE_SIZE ? 28 : p >= P.P_MIN_INLINE_SIZE ? 26 : 24;
    const inline = p === P.P_INLINE_SIZE || p === P.P_MIN_INLINE_SIZE || p === P.P_MAX_INLINE_SIZE;
    return inline === vertical ? base + 1 : base;
  }
  let fam: number;
  let k: number;
  if (p >= P.P_BORDER_BLOCK_START_WIDTH) {
    // A logical border side names one of the twelve border longhands: its part picks the family.
    if (p >= P.P_BORDER_BLOCK_START_COLOR) {
      fam = 20;
      k = p - P.P_BORDER_BLOCK_START_COLOR;
    } else if (p >= P.P_BORDER_BLOCK_START_STYLE) {
      fam = 16;
      k = p - P.P_BORDER_BLOCK_START_STYLE;
    } else {
      fam = 12;
      k = p - P.P_BORDER_BLOCK_START_WIDTH;
    }
  } else if (p >= P.P_INSET_BLOCK_START) {
    fam = 8;
    k = p - P.P_INSET_BLOCK_START;
  } else if (p >= P.P_PADDING_BLOCK_START) {
    fam = 4;
    k = p - P.P_PADDING_BLOCK_START;
  } else {
    fam = 0;
    k = p - P.P_MARGIN_BLOCK_START;
  }
  const blockStart = k < 2;
  const start = (k & 1) === 0;
  return fam + logicalSideOf(k, vertical, rtl, vlr);
}

/** The physical side (0 top, 1 right, 2 bottom, 3 left) logical side `k` names. */
function logicalSideOf(k: number, vertical: boolean, rtl: boolean, vlr: boolean): number {
  const blockStart = k < 2;
  const start = (k & 1) === 0;
  if (vertical) {
    if (blockStart) return vlr ? (start ? 3 : 1) : (start ? 1 : 3);
    return rtl ? (start ? 2 : 0) : (start ? 0 : 2);
  }
  if (blockStart) return start ? 0 : 2;
  return rtl ? (start ? 1 : 3) : (start ? 3 : 1);
}

/** The slot a family's logical side `k` names, given the family's base slot. */
function logicalSide(fam: number, k: number, vertical: boolean, rtl: boolean, vlr: boolean): number {
  return fam + logicalSideOf(k, vertical, rtl, vlr);
}

function logicalCorner(k: number, vertical: boolean, rtl: boolean, vlr: boolean): number {
  const blockStart = k < 2;
  const start = (k & 1) === 0;
  let top: boolean;
  let left: boolean;
  if (!vertical) {
    top = blockStart;
    left = rtl ? !start : start;
  } else {
    // vertical-rl stacks its lines from the right, vertical-lr from the left; the inline axis runs
    // down the page, so inline-start is the top.
    top = start;
    left = vlr ? blockStart : !blockStart;
  }
  return top ? (left ? 0 : 1) : (left ? 3 : 2);
}

/** Whether a code point is a strong right-to-left character: Hebrew, Arabic and their blocks. */
function isRtlStrong(c: number): boolean {
  return (c >= 0x0590 && c <= 0x08FF) || (c >= 0xFB1D && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFF) ||
    (c >= 0x10800 && c <= 0x10FFF) || (c >= 0x1E800 && c <= 0x1EFFF);
}

/** Whether a code point is a strong left-to-right character. */
function isLtrStrong(c: number): boolean {
  if (c < 0x80) return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  if (c === 0xD7 || c === 0xF7) return false; // multiplication and division signs are neutral
  return (c >= 0xC0 && c <= 0x24F) || (c >= 0x370 && c <= 0x58F) || (c >= 0x1E00 && c <= 0x1FFF) ||
    (c >= 0x2C00 && c <= 0x31FF) || (c >= 0x3400 && c <= 0xA4CF) || (c >= 0xAC00 && c <= 0xD7A3) ||
    (c >= 0xF900 && c <= 0xFAFF);
}

/** The direction the given text starts with: 1 for rtl, 0 for ltr, -1 when it has no strong character. */
export function strongDirection(text: string): number {
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (isRtlStrong(c)) return 1;
    if (isLtrStrong(c)) return 0;
  }
  return -1;
}

/** The direction a subtree's text starts with, skipping what HTML's rule sets aside. */
function subtreeDirection(node: Node): number {
  // An element whose text the build kept as its own rather than as a text child.
  const own = node.ownText;
  if (own !== "") {
    const d = strongDirection(own);
    if (d >= 0) return d;
  }
  for (const kid of node.kids) {
    if (kid.nodeType === 3) {
      const d = strongDirection(kid.textContent);
      if (d >= 0) return d;
      continue;
    }
    if (kid.nodeType !== 1) continue;
    const el = kid as Element;
    // A nested element with its own direction, or one whose content never takes direction from
    // the page, is left out: its text isn't this element's for `dir=auto`. An empty or unknown
    // `dir` value names no direction, so the search carries on into that element.
    const nested = el.getAttribute("dir");
    if ((nested !== null && /^(ltr|rtl|auto)$/i.test(nested.trim())) || el.localName === "bdi" ||
      el.localName === "script" || el.localName === "style" || el.localName === "textarea") continue;
    const d = subtreeDirection(el);
    if (d >= 0) return d;
  }
  return -1;
}

/** The direction `dir=auto` takes from the element: a field's value, or the text it holds. */
function autoDirection(el: Element): number {
  const tag = el.localName;
  if (tag === "input" || tag === "textarea") {
    const value = (el as any).value;
    if (typeof value === "string") {
      const d = strongDirection(value);
      if (d >= 0) return d;
    }
    return -1;
  }
  return subtreeDirection(el);
}

/**
 * The declarations the `dir` attribute stands for: `ltr` and `rtl` set the direction, and `auto`
 * reads it from the first strong character in the element (or, for a field, in its value). A
 * `<bdi>` is auto by default. With no strong character the direction stays as inherited.
 */
function applyDirHint(el: Element): void {
  let dir = el.getAttribute("dir");
  if (dir === null && el.localName === "bdi") dir = "auto";
  if (dir === null) return;
  const v = dir.trim().toLowerCase();
  let rtl: boolean;
  if (v === "rtl") rtl = true;
  else if (v === "ltr") rtl = false;
  else if (v === "auto") {
    const d = autoDirection(el);
    if (d < 0) return;
    rtl = d === 1;
  } else return;
  el.sv[P.P_DIRECTION] = rtl ? P.DIR_RTL : P.DIR_LTR;
  el.su[P.P_DIRECTION] = P.U_NONE;
}

/** Notes a declaration that writes a side of the box, so the logical ones settle after it. */
function noteSide(p: number, v: number, u: number, important: boolean): void {
  const slot = sideSlot(p);
  if (slot >= 0) {
    sideOrder[slot] = ++sideSeq;
    return;
  }
  if (isLogicalSide(p)) logicalAt.push(p, v, u, ++sideSeq, important ? 1 : 0);
}

/**
 * Whether `p` is one of the logical side properties the post-cascade pass settles. The families
 * share the props table with properties that name no side (caret-color and its neighbours sit
 * between the border colours and the logical sizes), so each family is named by its own range.
 */
function isLogicalSide(p: number): boolean {
  return (p >= P.P_MARGIN_BLOCK_START && p <= P.P_MARGIN_INLINE_END) ||
    (p >= P.P_PADDING_BLOCK_START && p <= P.P_PADDING_INLINE_END) ||
    (p >= P.P_INSET_BLOCK_START && p <= P.P_INSET_INLINE_END) ||
    (p >= P.P_BORDER_BLOCK_START_WIDTH && p <= P.P_BORDER_INLINE_END_WIDTH) ||
    (p >= P.P_BORDER_BLOCK_START_STYLE && p <= P.P_BORDER_INLINE_END_STYLE) ||
    (p >= P.P_BORDER_BLOCK_START_COLOR && p <= P.P_BORDER_INLINE_END_COLOR) ||
    (p >= P.P_INLINE_SIZE && p <= P.P_MAX_BLOCK_SIZE) ||
    (p >= P.P_BORDER_START_START_RADIUS && p <= P.P_BORDER_END_END_RADIUS_Y) ||
    (p >= P.P_SCROLL_MARGIN_BLOCK_START && p <= P.P_SCROLL_MARGIN_INLINE_END) ||
    (p >= P.P_SCROLL_PADDING_BLOCK_START && p <= P.P_SCROLL_PADDING_INLINE_END);
}

/**
 * The physical property a logical side property settles onto on `el`'s own axes, or -1 when `p`
 * is physical. A logical property shares its computed value with the physical side it names
 * (CSS Logical 1 §4), so a computed-style read answers from that side's slot.
 */
export function logicalPhysicalProp(el: Element, p: number): number {
  if (!isLogicalSide(p)) return -1;
  const wm = el.sv[P.P_WRITING_MODE];
  const vertical = wm !== P.WM_HORIZONTAL_TB;
  const vlr = wm === P.WM_VERTICAL_LR || wm === P.WM_SIDEWAYS_LR;
  const rtl = el.sv[P.P_DIRECTION] === P.DIR_RTL;
  return slotProp(logicalSlot(p, vertical, rtl, vlr), p);
}

/** Settles the logical sides the element declared into the physical sides its axes name. */
function resolveLogicalSides(el: Element): void {
  if (logicalAt.length === 0) return;
  const wm = el.sv[P.P_WRITING_MODE];
  const vertical = wm !== P.WM_HORIZONTAL_TB;
  const vlr = wm === P.WM_VERTICAL_LR || wm === P.WM_SIDEWAYS_LR;
  const rtl = el.sv[P.P_DIRECTION] === P.DIR_RTL;
  for (let i = 0; i + 4 < logicalAt.length; i += 5) {
    const slot = logicalSlot(logicalAt[i], vertical, rtl, vlr);
    // A physical declaration that came later in the cascade keeps the side.
    if (logicalAt[i + 3] < sideOrder[slot]) continue;
    const p = slotProp(slot, logicalAt[i]);
    el.sv[p] = logicalAt[i + 1];
    el.su[p] = logicalAt[i + 2];
    noteDeclared(el, p);
    if (logicalAt[i + 4] !== 0) noteImportant(el, p);
    sideOrder[slot] = logicalAt[i + 3];
  }
  logicalAt.length = 0;
}

/**
 * Notes a declaration of a text-decoration property, whichever source it came from: it marks the
 * element as a place a decoration starts, which the painter draws over the descendant text.
 */
function noteDecor(el: Node, p: number): void {
  if (p === P.P_TEXT_DECORATION || p === P.P_TEXT_DECORATION_STYLE ||
    p === P.P_TEXT_DECORATION_COLOR || p === P.P_TEXT_DECORATION_THICKNESS) el.decorDeclared = true;
}

/**
 * What the cascade does with each compiled rule, by rule id: applies, stands down because its
 * sheet is disabled through the CSSOM (`<style>.disabled`, a sheet's `.disabled`), or stands down
 * because a script took the sheet over by editing it, its runtime rules then being the whole
 * truth. A taken-over sheet's rules stay down even if it is later re-enabled: the build's copies
 * still hold the text the page started with, and would otherwise keep a deleted rule or a
 * removed property in force.
 */
const RULE_APPLIES = 0;
const RULE_DISABLED = 1;
const RULE_TAKEN_OVER = 2;
let ruleState: number[] = [];

/** Whether a compiled rule stands down. Rule ids outside the current table set never do. */
function ruleStandsDown(r: number): boolean {
  return r < ruleState.length && ruleState[r] !== RULE_APPLIES;
}

/** Makes the per-rule state array match the table set the style engine is using. */
function ensureRuleState(): void {
  if (ruleState.length === tables.ruleSheet.length) return;
  ruleState = [];
  for (let i = 0; i < tables.ruleSheet.length; i++) ruleState.push(RULE_APPLIES);
}

/** A compiled sheet joined the cascade or left it: a script disabled or re-enabled the sheet. */
export function setCompiledSheetOff(sheet: number, off: boolean): void {
  if (sheet < 0) return;
  ensureRuleState();
  for (let r = 0; r < tables.ruleSheet.length; r++) {
    if (tables.ruleSheet[r] !== sheet) continue;
    if (off) {
      if (ruleState[r] === RULE_APPLIES) ruleState[r] = RULE_DISABLED;
    } else if (ruleState[r] === RULE_DISABLED) {
      ruleState[r] = RULE_APPLIES;
    }
  }
  invalidateStyle();
}

/** A compiled <style> node's sheet became a runtime sheet: its compiled rules stand down. */
export function disableCompiledSheet(nodeIndex: number): void {
  const sheet = tables.nodeSheet[nodeIndex] ?? -1;
  if (sheet < 0) return;
  ensureRuleState();
  for (let r = 0; r < tables.ruleSheet.length; r++) if (tables.ruleSheet[r] === sheet) ruleState[r] = RULE_TAKEN_OVER;
  invalidateStyle();
}

/** A script's media condition for a sheet of the build, by sheet index; see sheetMediaOf. */
let sheetMediaOverride: (string | undefined)[] = [];

/** The media condition a sheet's rules are tested against: the script's, else the build's. */
function sheetMediaOf(sheet: number): string {
  const over = sheet < sheetMediaOverride.length ? sheetMediaOverride[sheet] : undefined;
  if (over !== undefined) return over;
  return sheet < tables.sheetMedia.length ? tables.sheetMedia[sheet] : "";
}

/** A script set the media condition of a sheet of the build (`<style>.media`, sheet.media). */
export function setCompiledSheetMedia(sheet: number, media: string): void {
  if (sheet < 0) return;
  while (sheetMediaOverride.length <= sheet) sheetMediaOverride.push(undefined);
  sheetMediaOverride[sheet] = media;
  invalidateStyle();
}

/** Forgets which sheets stood down: a newly applied table set has rule ids of its own. */
export function resetDisabledSheets(): void {
  ruleState = [];
  sheetMediaOverride = [];
}

// The CSSOM's `disabled` on a compiled sheet takes its rules in and out of the cascade here, and
// its media condition is what its rules are tested against.
setCompiledSheetOffSink(setCompiledSheetOff);
setCompiledSheetMediaSink(setCompiledSheetMedia);

/** The declarations an SVG element's presentation attributes stand for, as a hint in the cascade. */
function applyHintDecls(el: Element, sv: Float64Array, su: Float64Array, important: boolean): void {
  for (const d of hintDecls(el)) {
    if (d.prop !== undefined) continue;
    sv[d.p] = d.v;
    su[d.p] = d.u;
    forgetColorForm(el, d.p);
    if (important) noteImportant(el, d.p);
    if (d.p === P.P_FONT_SIZE) fontSizeDeclared = true;
  }
}

/** Whether the build left the element a slot in the cascade for its presentation attributes. */
function hasHintSlot(el: Element): boolean {
  for (const r of el.rules) {
    if (r < tables.ruleHint.length && tables.ruleHint[r]) return true;
  }
  return false;
}

function applyRules(el: Element, important: boolean, parent: Node | null): void {
  const sv = el.sv;
  const su = el.su;
  // An <svg> element a script made has no slot of its own in the compiled cascade (the build
  // only writes one for the elements it read), so its presentation attributes are applied here,
  // below every rule, which is where the build's slot would sit. The UA sheet declares none of
  // the attributes' properties, so this is the same place in the cascade.
  if (!important && el.namespaceURI === "http://www.w3.org/2000/svg" && !hasHintSlot(el)) {
    applyHintDecls(el, sv, su, false);
  }
  for (const r of el.rules) {
    if (ruleStandsDown(r)) continue;
    if (tables.ruleImportant[r] !== important) continue;
    if (r < tables.ruleHint.length && tables.ruleHint[r]) {
      // A presentation-attribute slot: the declarations are the attributes the element carries
      // now, so setAttribute()/removeAttribute() of a fill, a stroke or a font restyles it.
      applyHintDecls(el, sv, su, important);
      continue;
    }
    if (!ruleApplies(el, r)) continue;
    const author = !tables.ruleUa[r];
    const d = tables.ruleDecls[r];
    for (let k = 0; k + 2 < d.length; k += 3) {
      if (d[k] < 0) {
        // A declaration kept as text: a var() value, now that the custom properties are known.
        // (The custom properties themselves were cascaded before any of this.)
        const id = -1 - d[k];
        const prop = tables.textDeclProps[id];
        if (!isCustom(prop)) applyText(el, prop, tables.textDeclValues[id], parent, important, author);
        continue;
      }
      sv[d[k]] = d[k + 1];
      su[d[k]] = d[k + 2];
      forgetColorForm(el, d[k]);
      if (important) noteImportant(el, d[k]);
      noteSide(d[k], d[k + 1], d[k + 2], important);
      noteDeclared(el, d[k]);
      if (author) noteFace(el, d[k]);
      if (d[k] === P.P_FONT_SIZE) fontSizeDeclared = true;
      noteDecor(el, d[k]);
    }
  }
}

/**
 * Whether a rule that matches the element declares the property — the element's own value, as
 * opposed to what it inherits. The SVG painter asks this of the content a <use> references: the
 * copy keeps what the referenced element itself declares and inherits the rest from the <use>.
 * Sheets a script adds at runtime are not consulted; their rules were matched when the element
 * was styled, so a copy of an element that a runtime sheet styles inherits instead.
 */
export function declaresProperty(el: Element, prop: number, name: string): boolean {
  for (const r of el.rules) {
    if (ruleStandsDown(r)) continue;
    if (!ruleApplies(el, r)) continue;
    const d = tables.ruleDecls[r];
    for (let k = 0; k + 2 < d.length; k += 3) {
      if (d[k] === prop) return true;
      if (d[k] < 0 && tables.textDeclProps[-1 - d[k]] === name) return true;
    }
  }
  return false;
}

/** Applies the element's inline declarations of one importance, in the order they were set. */
function applyInline(el: Element, important: boolean, parent: Node | null): void {
  const decls = el.styleDecl;
  if (decls === null) return;
  const sv = el.sv;
  const su = el.su;
  for (const d of decls.decls) {
    if (d.important !== important) continue;
    if (d.prop !== undefined) {
      if (!isCustom(d.prop)) applyText(el, d.prop, d.value === undefined ? "" : d.value, parent, important, true);
      continue;
    }
    sv[d.p] = d.v;
    su[d.p] = d.u;
    forgetColorForm(el, d.p);
    if (important) noteImportant(el, d.p);
    noteSide(d.p, d.v, d.u, important);
    noteDeclared(el, d.p);
    noteFace(el, d.p);
    if (d.p === P.P_FONT_SIZE) fontSizeDeclared = true;
    noteDecor(el, d.p);
  }
}

/** Remembers that an important declaration set `p`, which a CSS animation must not override. */
function noteImportant(el: Element, p: number): void {
  if (el.impProps.indexOf(p) < 0) el.impProps.push(p);
}

/** Whether the element's own declarations set font-size, as opposed to inheriting it. */
let fontSizeDeclared = false;

// ---------------------------------------------------------------------------
// Style sheets a script added (runtime/sheets.ts)
//
// Their rules live only at runtime, so they are matched here against every element, after the
// compiled rules of the same importance (they sit later in the document than the sheets the
// build compiled) and in specificity order among themselves.

/** A runtime sheet and the shadow tree it is scoped to (null for the document's own sheets). */
interface ScopedSheet {
  sheet: CSSStyleSheet;
  scope: any;
}

/** The sheets of the document's <style> elements and the adopted ones, in cascade order. */
let activeSheets: ScopedSheet[] = [];

/** Collects the document's sheet-bearing elements, refreshing a <style>'s rules as it goes. */
function collectSheets(node: Node, out: ScopedSheet[], scope: any): void {
  if (node instanceof Element && node.pseudoKind === P.PE_NONE) {
    // A <style> the build compiled is already in the page's compiled rules; its text is applied
    // once, and only a script's rewrite turns it into a runtime sheet.
    if (node.localName === "style" && !node.compiledSheet) refreshSheet(node);
    if (node.sheet !== null && !(node.localName === "style" && node.compiledSheet)) {
      out.push({ sheet: node.sheet, scope });
    }
  }
  for (const c of node.kids) if (c.pseudoKind === P.PE_NONE) collectSheets(c, out, scope);
  // A shadow tree's <style> elements and adopted sheets are scoped to that tree.
  const shadow = node.shadowTree();
  if (shadow !== null) {
    for (const s of shadow.adoptedStyleSheets) out.push({ sheet: s, scope: shadow });
    collectSheets(shadow, out, shadow);
  }
}

/**
 * Whether the at-rules a runtime sheet rule sits inside let it apply: its @media condition, and a
 * @container one against `el`'s ancestors.
 */
function runtimeRuleApplies(rule: SheetRule, el: Element): boolean {
  if (rule.media !== "" && !mediaMatches(rule.media)) return false;
  if (rule.container !== "" && !containerMatches(el, rule.container, tables.containerNames)) return false;
  return true;
}

/** One runtime rule that matches an element, with what orders it in the cascade. */
interface RuntimeMatch {
  rule: SheetRule;
  spec: number;
  order: number;
  /** The rule's cascade layer rank; unlayered rules sort above every layer. */
  layer: number;
}

/**
 * The runtime sheet rules whose selectors match `test`, the element a pseudo-element belongs to,
 * for rules of the pseudo-element `pseudo` (PE_NONE for the element's own rules). The result is
 * in cascade order: ascending specificity, then source order.
 */
/** Whether an element is inside the given shadow tree: its parent chain reaches that root. */
function insideShadowTree(el: Node, root: any): boolean {
  let n: Node | null = el;
  while (n !== null) {
    if (n.parentNode === root) return true;
    n = n.parentNode;
  }
  return false;
}

/**
 * Whether a runtime sheet's selector applies to `el`, given the shadow tree the sheet is in. A
 * plain sheet's selectors are the document's; a shadow tree's sheet styles that tree's elements,
 * its host (:host) and the nodes its slots took (::slotted) — and nothing outside it.
 */
function selectorFitsSheet(el: Element, sel: Selector, root: any): boolean {
  if (sel.host === true) {
    if (root === null || el !== root.host) return false;
    if (sel.hostArg !== undefined && !compoundFits(el, sel.hostArg)) return false;
    return compoundFits(el, sel);
  }
  if (sel.slotted === true) {
    if (root === null) return false;
    const slot = el.assignedSlot;
    return slot !== null && shadowRootOf(slot) === root && compoundFits(el, sel);
  }
  if (root !== null && !insideShadowTree(el, root)) return false;
  return selectorFits(el, sel);
}

/** The shadow tree a node sits in, or null when it is in the document. */
function shadowRootOf(node: Node): any {
  let n: Node | null = node.parentNode;
  while (n !== null) {
    if (n instanceof ShadowRoot) return n;
    n = n.parentNode;
  }
  return null;
}

function runtimeMatches(test: Element, pseudo: number): RuntimeMatch[] {
  const out: RuntimeMatch[] = [];
  if (activeSheets.length === 0) return out;
  let order = 0;
  for (const entry of activeSheets) {
    const sheet = entry.sheet;
    if (sheet.disabledFlag) continue;
    const root = entry.scope;
    for (const rule of sheet.styleRules) {
      order++;
      if (!runtimeRuleApplies(rule, test)) continue;
      // A rule's declarations come from the rule, so the most specific of its matching
      // selectors is the one that orders it here.
      let spec = -1;
      for (const sel of rule.selectors) {
        if (sel.pseudo !== pseudo) continue;
        if (!selectorFitsSheet(test, sel, root)) continue;
        if (sel.specificity > spec) spec = sel.specificity;
      }
      if (spec >= 0) out.push({ rule, spec, order, layer: sheetLayerRank(rule.layer) });
    }
  }
  // Insertion sort by (layer, specificity, source order): the cascade wants the last applied to
  // win, and a later layer outranks an earlier one.
  for (let i = 1; i < out.length; i++) {
    const m = out[i];
    let k = i - 1;
    while (k >= 0 && (out[k].layer > m.layer ||
      (out[k].layer === m.layer && (out[k].spec > m.spec ||
        (out[k].spec === m.spec && out[k].order > m.order))))) {
      out[k + 1] = out[k];
      k--;
    }
    out[k + 1] = m;
  }
  return out;
}

/** Does the element match one compound of a runtime sheet selector? */
/**
 * The direction an element's text runs in: the `dir` attribute it carries, `auto` resolved from
 * the first strong character, or the direction it inherits. Inheriting crosses shadow
 * boundaries: the style pass settles a shadow tree's elements from their host and a slotted
 * node from the slot that took it, so `sv` holds the flattened tree's answer.
 */
function elementDirection(el: Element): number {
  const dir = el.getAttribute("dir");
  const value = dir !== null ? dir.trim().toLowerCase() : (el.localName === "bdi" ? "auto" : "");
  if (value === "rtl") return P.DIR_RTL;
  if (value === "ltr") return P.DIR_LTR;
  if (value === "auto") {
    const d = autoDirection(el);
    if (d >= 0) return d === 1 ? P.DIR_RTL : P.DIR_LTR;
  }
  // Inherited: walk the flattened tree rather than reading the cascade, so an answer taken
  // before the first style pass is right too.
  const slot = el.assignedSlot;
  if (slot !== null) return elementDirection(slot);
  const parent = el.parentNode;
  if (parent === null) return P.DIR_LTR;
  if (parent instanceof ShadowRoot) return elementDirection((parent as any).host);
  return parent instanceof Element ? elementDirection(parent) : P.DIR_LTR;
}

/**
 * CSS's :empty: the element has no child elements and no text. Comments aren't content, and the
 * boxes a pseudo-element generates aren't children of the element's own tree.
 */
function isEmptyElement(el: Element): boolean {
  if (el.ownText !== "") return false;
  for (const k of el.kids) {
    if (k.pseudoKind !== P.PE_NONE) continue;
    if (k.isElementNode) return false;
    if (k.isTextNode && k.ownText !== "") return false;
  }
  return true;
}

function compoundFits(el: Element, c: Compound, scope: Element | null = null): boolean {
  if (!tagMatches(c, el.localName, el.namespaceURI)) return false;
  if (c.id !== null && c.id !== el.id) return false;
  if (c.root && el !== document.documentElement) return false;
  if (c.empty === true && !isEmptyElement(el)) return false;
  if (c.dir !== undefined && elementDirection(el) + 1 !== c.dir) return false;
  // :scope is the element a DOM API call was made on. A style sheet's selectors have none, where
  // parseSelector has already turned :scope into :root.
  if (c.scope === true && el !== (scope === null ? document.documentElement : scope)) return false;
  for (const k of c.classes) if (!el.classList.contains(k)) return false;
  if ((c.states & P.S_FORM_STATES) !== 0) refreshFormState(el, c.states);
  if ((c.states & el.state) !== c.states) return false;
  if (!nthApplies(el, c.nthStart, c.nthEnd, c.nthStartOf ?? NO_OF, c.nthEndOf ?? NO_OF)) return false;
  for (const a of c.attrs) if (!attrMatches(el, a)) return false;
  if (!langApplies(el, c.lang ?? NO_LANG)) return false;
  for (const n of c.nots) if (compoundFits(el, n, scope)) return false;
  if (c.notSels !== undefined) for (const t of c.notSels) if (selectorArgMatches(el, t)) return false;
  if (!hasApplies(el, c.has)) return false;
  return true;
}

/**
 * Does the element match a selector parsed for a DOM API call, with `scope` the element its
 * :scope stands for? This is the same matcher the cascade uses, so a selector means the same
 * thing to the DOM's query methods as it does in a style sheet.
 */
export function selectorMatches(el: Element, sel: Selector, scope: Element | null): boolean {
  // Generated content isn't in the DOM, and a selector naming a pseudo-element names nothing a
  // query can return.
  if (el.pseudoKind !== P.PE_NONE || sel.pseudo !== P.PE_NONE) return false;
  if (!compoundFits(el, sel, scope)) return false;
  return runtimeChainFits(sel.chain, 0, el, scope);
}

/** Does the element match a runtime sheet selector, its ancestors and siblings included? */
function selectorFits(el: Element, sel: Selector): boolean {
  if (!compoundFits(el, sel)) return false;
  return runtimeChainFits(sel.chain, 0, el);
}

function runtimeChainFits(chain: ChainLink[], k: number, el: Element, scope: Element | null = null): boolean {
  if (k === chain.length) return true;
  const comb = chain[k].comb;
  if (comb === COMB_ADJACENT) {
    const s = el.previousElementSibling;
    return s !== null && compoundFits(s, chain[k], scope) && runtimeChainFits(chain, k + 1, s, scope);
  }
  if (comb === COMB_GENERAL) {
    let s = el.previousElementSibling;
    while (s !== null) {
      if (compoundFits(s, chain[k], scope) && runtimeChainFits(chain, k + 1, s, scope)) return true;
      s = s.previousElementSibling;
    }
    return false;
  }
  let a = el.parentElement;
  while (a !== null) {
    if (compoundFits(a, chain[k], scope) && runtimeChainFits(chain, k + 1, a, scope)) return true;
    if (comb === COMB_CHILD) return false;
    a = a.parentElement;
  }
  return false;
}

/** Applies the matching runtime rules' declarations of one importance, in cascade order. */
function applyRuntime(el: Element, matched: RuntimeMatch[], important: boolean, parent: Node | null): void {
  const sv = el.sv;
  const su = el.su;
  // Important declarations reverse the layer order: an earlier layer's !important beats a
  // later one's, and an unlayered !important is the weakest of them.
  let list = matched;
  if (important && matched.length > 1) {
    const total = sheetLayerTotal();
    list = matched.slice().sort((a, b) => (total - a.layer) - (total - b.layer) || a.spec - b.spec || a.order - b.order);
  }
  for (const m of list) {
    for (const d of m.rule.decls) {
      if ((d.important === true) !== important) continue;
      if (d.prop !== undefined) {
        if (!isCustom(d.prop)) applyText(el, d.prop, d.value === undefined ? "" : d.value, parent, important, true);
        continue;
      }
      sv[d.p] = d.v;
      su[d.p] = d.u;
      if (important) noteImportant(el, d.p);
      noteSide(d.p, d.v, d.u, important);
      noteDeclared(el, d.p);
      noteFace(el, d.p);
      if (d.p === P.P_FONT_SIZE) fontSizeDeclared = true;
      noteDecor(el, d.p);
    }
  }
}

/**
 * Before an element's cascade runs: a runtime rule that generates a ::before or ::after box
 * asks for the box the compiled cascade would have made at build time, and the states the
 * element's matching runtime rules test are marked sensitive so a :hover rule restyles it like
 * a compiled one does.
 */
function prepareRuntimeBoxes(el: Element): void {
  if (activeSheets.length === 0) return;
  let states = el.sensitiveStates;
  for (const entry of activeSheets) {
    const sheet = entry.sheet;
    if (sheet.disabledFlag) continue;
    for (const rule of sheet.styleRules) {
      if (!runtimeRuleApplies(rule, el)) continue;
      for (const sel of rule.selectors) {
        if (!selectorFitsSheet(el, sel, entry.scope)) continue;
        states |= compoundStates(sel);
        if (sel.pseudo === P.PE_NONE || el.hasPseudoBox(sel.pseudo)) continue;
        // A ::placeholder rule styles the field's placeholder text, so the carrier box is made
        // for it whether or not it declares content (which ::placeholder never does).
        if (sel.pseudo === P.PE_PLACEHOLDER) {
          el.ensurePseudoBox(sel.pseudo);
          continue;
        }
        for (const d of rule.decls) {
          if (d.p !== P.P_CONTENT) continue;
          el.ensurePseudoBox(sel.pseudo);
          break;
        }
      }
    }
  }
  el.sensitiveStates = states;
}

/** inline, inline-block, inline-flex and inline-grid are inline-level. */
function isInlineLevelDisplay(d: number): boolean {
  return d === P.D_INLINE || d === P.D_INLINE_BLOCK || d === P.D_INLINE_FLEX || d === P.D_INLINE_GRID ||
    d === P.D_INLINE_GRID_LANES;
}

/** The blockified display of an inline-level one: inline-flex and inline-grid keep their kind. */
function blockified(d: number): number {
  return d === P.D_INLINE_FLEX ? P.D_FLEX : d === P.D_INLINE_GRID ? P.D_GRID
    : d === P.D_INLINE_GRID_LANES ? P.D_GRID_LANES : P.D_BLOCK;
}

/** A flex container: `flex`, or `inline-flex`, which is also inline-level. */
export function isFlexContainer(el: Node): boolean {
  const d = el.sv[P.P_DISPLAY];
  return d === P.D_FLEX || d === P.D_INLINE_FLEX;
}

/** A grid container: `grid`, or `inline-grid`, which is also inline-level. */
export function isGridContainer(el: Node): boolean {
  const d = el.sv[P.P_DISPLAY];
  return d === P.D_GRID || d === P.D_INLINE_GRID;
}

/** A grid lanes container: a grid whose items pack into the shortest lane along one axis. */
export function isLanesContainer(el: Node): boolean {
  const d = el.sv[P.P_DISPLAY];
  return d === P.D_GRID_LANES || d === P.D_INLINE_GRID_LANES;
}

/** row and row-reverse: the main axis runs horizontally. */
export function isRowDirection(dir: number): boolean {
  return dir === P.FD_ROW || dir === P.FD_ROW_REVERSE;
}

const deviceMetrics: Map<string, number[]> = new Map();

/** Forgets the per-font line metrics: their keys carry a family id, which each page numbers anew. */
export function resetDeviceMetrics(): void {
  deviceMetrics.clear();
}

/**
 * [ascent, descent, line gap] of a font in whole device pixels. A line box is laid out in device
 * pixels: Chrome rounds each of the three to a whole device pixel, which makes a normal line box
 * and a baseline whole device pixels too. The backing scale is part of the key: the same font on a
 * 2x display has different whole-pixel metrics than on a 1x one.
 */
/** The face a packed font key names, as the index its metric overrides sit at; -1 for none. */
function faceIndexOfKey(key: number): number {
  if (facePalettes.length === 0) return -1;
  const run = Math.floor(key / 10000000);
  const stretch = run >= 1 && run <= runStretch.length ? runStretch[run - 1] : 100;
  const pack = key - run * 10000000;
  const family = Math.floor(pack / 10000);
  const rest = pack - family * 10000;
  const italic = rest >= 1000 ? 1 : 0;
  const w = italic ? rest - 1000 : rest;
  const id = family - P.FF_CUSTOM;
  if (id < 0) return -1;
  let best = -1;
  let bestDist = 0;
  for (let i = 0; i * 3 + 2 < facePalettes.length; i++) {
    if (faceFamilies[i] !== id) continue;
    const faceStretch = tables.fontFaceStretches[i] ?? 100;
    const stretchDist = faceStretch === stretch ? 0 : 1 + Math.abs(faceStretch - stretch) / 1000;
    const dist = faceFaceDistance(i, w, italic) + stretchDist * 100000000;
    if (best < 0 || dist < bestDist) { best = i; bestDist = dist; }
  }
  return best;
}

export function fontDeviceMetrics(size: number, key: number): number[] {
  const k = `${size}|${key}|${hostBackingScale()}`;
  const hit = deviceMetrics.get(k);
  if (hit !== undefined) return hit;
  // A zero font size takes no line: the host's font API would clamp the size and report a whole
  // font's metrics (see fontMetrics in layout/text.ts).
  let m = size > 0
    ? [hostFontAscentDevice(size, key), hostFontDescentDevice(size, key), hostFontLineGapDevice(size, key)]
    : [0, 0, 0];
  // ascent-override, descent-override and line-gap-override replace the face's own metrics with a
  // fraction of the font size, so the line boxes and inline boxes follow them.
  const face = faceIndexOfKey(key);
  if (face >= 0) {
    const asc = face < tables.fontFaceAscents.length ? tables.fontFaceAscents[face] : -1;
    const desc = face < tables.fontFaceDescents.length ? tables.fontFaceDescents[face] : -1;
    const gap = face < tables.fontFaceLineGaps.length ? tables.fontFaceLineGaps[face] : -1;
    if (asc >= 0 || desc >= 0 || gap >= 0) {
      const scale = hostBackingScale();
      m = [
        asc >= 0 ? Math.round(asc * size * scale) : m[0],
        desc >= 0 ? Math.round(desc * size * scale) : m[1],
        gap >= 0 ? Math.round(gap * size * scale) : m[2],
      ];
    }
  }
  deviceMetrics.set(k, m);
  return m;
}

/** `line-height: normal`: the font's ascent, descent and line gap, each rounded to a device pixel. */
function normalLineHeight(size: number, key: number): number {
  if (!(size > 0)) return 0;
  const m = fontDeviceMetrics(size, key);
  return (m[0] + m[1] + m[2]) / hostBackingScale();
}

/** Values that are read straight from the computed style, with no used-value pass of their own,
 *  so a calc() stored in one is evaluated when the style is computed. */
function earlyExpr(p: number): boolean {
  switch (p) {
    case P.P_LINE_HEIGHT:
    case P.P_BORDER_TOP_WIDTH:
    case P.P_BORDER_RIGHT_WIDTH:
    case P.P_BORDER_BOTTOM_WIDTH:
    case P.P_BORDER_LEFT_WIDTH:
    case P.P_LETTER_SPACING:
    case P.P_WORD_SPACING:
    case P.P_VERTICAL_ALIGN:
    case P.P_OUTLINE_OFFSET:
    case P.P_BORDER_SPACING_H:
    case P.P_BORDER_SPACING_V:
    case P.P_TEXT_INDENT:
    case P.P_TEXT_DECORATION_THICKNESS:
    case P.P_UNDERLINE_OFFSET:
      return true;
    default:
      return false;
  }
}

/** Line height in px. Unitless values multiply the font size (and inherit as multipliers). */
export function lineHeightPx(el: Node): number {
  const u = el.su[P.P_LINE_HEIGHT];
  if (u === P.U_NORMAL) return normalLineHeight(el.sv[P.P_FONT_SIZE], fontKey(el));
  return u === P.U_NONE ? el.sv[P.P_LINE_HEIGHT] * el.sv[P.P_FONT_SIZE] : el.sv[P.P_LINE_HEIGHT];
}

/** Whether the element's text runs right to left. */
export function isRtl(el: Node): boolean {
  return el.sv[P.P_DIRECTION] === P.DIR_RTL;
}

/**
 * The writing mode a box is laid out with. The body's is the page's when the root's own is the
 * initial one, so it propagates to the viewport as overflow does (CSS Writing Modes 3 §8.1); the
 * body itself keeps the writing mode it was given.
 */
export function usedWritingMode(el: Node): number {
  const m = el.sv[P.P_WRITING_MODE];
  if (el.parentNode !== document || m !== P.WM_HORIZONTAL_TB) return m;
  const body = document.body;
  return body === null || body === el ? m : body.sv[P.P_WRITING_MODE];
}

/** Whether the element's lines run down the page rather than across it. */
export function isVerticalText(el: Node): boolean {
  return usedWritingMode(el) !== P.WM_HORIZONTAL_TB;
}

/** Whether a vertical element turns its glyphs with the line (the sideways modes). */
export function isSidewaysText(el: Node): boolean {
  const m = el.sv[P.P_WRITING_MODE];
  return m === P.WM_SIDEWAYS_RL || m === P.WM_SIDEWAYS_LR;
}

/**
 * Which side a line's text goes on: `start` and `end` follow the direction the text runs in
 * (`start` is the left in ltr and the right in rtl), while `left` and `right` stay put.
 */
export function lineAlign(el: Node): number {
  return physicalAlign(el.sv[P.P_TEXT_ALIGN], el);
}

/**
 * The physical side an alignment names: `start` and `end` follow the direction the text runs in,
 * while `left` and `right` stay put.
 */
export function physicalAlign(a: number, el: Node): number {
  if (a !== P.T_START && a !== P.T_END) return a;
  return (a === P.T_START) === isRtl(el) ? P.T_RIGHT : P.T_LEFT;
}

/**
 * The alignment of a line ended by a forced break or by the end of the block: `text-align-last`
 * when it names one, else the block's own alignment (-1 for `auto`).
 */
export function lastLineAlign(el: Node): number {
  const v = el.sv[P.P_TEXT_ALIGN_LAST];
  return v > 0 ? physicalAlign(v - 1, el) : -1;
}

/**
 * The height of an element's font box in CSS px: the ascent and descent, without the line gap.
 * An inline box's own rect is this tall, whatever its line-height, and its line box centers it.
 */
export function fontBoxHeight(el: Node): number {  const m = fontDeviceMetrics(el.sv[P.P_FONT_SIZE], fontKey(el));
  return (m[0] + m[1]) / hostBackingScale();
}

/**
 * The upper leading of an element's line box in CSS px: how far its font box starts below the top
 * of the line-height box, since the leading is split above and below the font box. Chrome floors
 * the upper half when it isn't a whole device pixel, as it does for the baseline.
 */
export function fontBoxLeading(el: Node): number {
  const m = fontDeviceMetrics(el.sv[P.P_FONT_SIZE], fontKey(el));
  const scale = hostBackingScale();
  return Math.floor((lineHeightPx(el) * scale - m[0] - m[1]) / 2) / scale;
}

/** font-weight: bolder, relative to the inherited weight (CSS Fonts 4). */
function bolderWeight(w: number): number {
  return w < 350 ? 400 : w < 550 ? 700 : w < 900 ? 900 : w;
}

/** font-weight: lighter, relative to the inherited weight (CSS Fonts 4). */
function lighterWeight(w: number): number {
  return w < 100 ? w : w < 550 ? 100 : w < 750 ? 400 : 700;
}

/**
 * The host font key: the OpenType features' run id * 10000000, plus family * 10000, plus 1000
 * for italic, plus the CSS weight. The run id sits on top because a family's id grows with the
 * app's @font-face families, while the run it names is one of FONT_FEATURES.
 */
export function fontKey(el: Node): number {
  return featureRun(el) * 10000000 + el.sv[P.P_FONT_FAMILY] * 10000 +
    (el.sv[P.P_FONT_STYLE] === P.FS_ITALIC ? 1000 : 0) + el.sv[P.P_FONT_WEIGHT];
}

/** Bumped when the compiled font tables are replaced or appended to, which is when a remembered
 *  font run can no longer name the same list. */
let fontTables = 0;

/** Bumped for every node a style pass computes. A run computed during a pass can have read a
 *  half-written style, so it is only trusted again once the pass's last node has been reached. */
let styleGen = 0;

/** The font-feature-settings lists the compile wrote, by id (see the FONT_FEATURES table). */
let featureSpecs: string[] = [];
/** Lists a substituted value has parsed into, in id order after the compile's own lists. */
let extraFeatures: string[] = [];

/** The list behind a stored font-feature-settings value, for the CSS object model; "" for none. */
export function featureSpec(id: number): string {
  if (id <= 0) return "";
  if (id <= featureSpecs.length) return featureSpecs[id - 1];
  const at = id - featureSpecs.length - 1;
  return at < extraFeatures.length ? extraFeatures[at] : "";
}

/** Points the feature lookups at the app's own lists; mounting a new app replaces them. */
export function setFontFeatures(specs: string[]): void {
  featureSpecs = specs;
  extraFeatures = [];
  fontTables++;
}

/**
 * The id of one font-feature-settings list a value is only parsed into at style time (a value
 * that uses var()), appended after the compile's own lists and shared with them by text.
 */
export function registerFeatureSpec(spec: string): number {
  const wrote = featureSpecs.indexOf(spec);
  if (wrote >= 0) return wrote;
  const at = extraFeatures.indexOf(spec);
  if (at >= 0) return featureSpecs.length + at;
  extraFeatures.push(spec);
  fontTables++;
  return featureSpecs.length + extraFeatures.length - 1;
}

/** The font-variation-settings lists the compile wrote, by id (see the FONT_VARIATIONS table). */
let variationSpecs: string[] = [];
/** Lists a substituted value has parsed into, in id order after the compile's own lists. */
let extraVariations: string[] = [];

/** The list behind a stored font-variation-settings value, for the CSS object model; "" for none. */
export function variationSpec(id: number): string {
  if (id <= 0) return "";
  if (id <= variationSpecs.length) return variationSpecs[id - 1];
  const at = id - variationSpecs.length - 1;
  return at < extraVariations.length ? extraVariations[at] : "";
}

/** Points the variation lookups at the app's own lists; mounting a new app replaces them. */
export function setFontVariations(specs: string[]): void {
  variationSpecs = specs;
  extraVariations = [];
  fontTables++;
}

/** The id of one font-variation-settings list a substituted value is parsed into at style time. */
export function registerVariationSpec(spec: string): number {
  const wrote = variationSpecs.indexOf(spec);
  if (wrote >= 0) return wrote;
  const at = extraVariations.indexOf(spec);
  if (at >= 0) return variationSpecs.length + at;
  extraVariations.push(spec);
  fontTables++;
  return variationSpecs.length + extraVariations.length - 1;
}

/** One @font-palette-values rule, decoded from the FONT_PALETTES table. */
interface PaletteRule {
  name: number;
  /** The CSS family values the rule applies to, as an element's font-family stores them. */
  families: number[];
  baseKind: number;
  base: number;
  /** `index=rrggbb` pairs, joined by commas, as the host takes them. */
  colors: string;
}

/** The font-stretch each run asks for, by run id - 1 (see featureRun). */
let runStretch: number[] = [];

/** The names author palettes take, in id order (FONT_PALETTE_NAMES). */
let paletteNames: string[] = [];
/** The @font-palette-values rules, in source order; the last matching one wins. */
let paletteRules: PaletteRule[] = [];
/** Per FONT_FILES face: palette count, light index, dark index. */
let facePalettes: number[] = [];
/** The family id of each FONT_FILES face, parallel to facePalettes' rows. */
let faceFamilies: number[] = [];
/** The weight range (low * 1024 + high) and style of each face, parallel to faceFamilies. */
let faceWeights: number[] = [];
let faceStyles: number[] = [];

/** Points the palette lookups at the app's own tables; mounting a new app replaces them. */
export function setFontPalettes(names: string[], rules: string[], palettes: number[],
  families: number[], weights: number[], styles: number[]): void {
  paletteNames = names;
  paletteRules = [];
  for (const row of rules) {
    const parts = row.split("\u0000");
    if (parts.length < 5) continue;
    paletteRules.push({
      name: Number(parts[0]),
      families: parts[1] === "" ? [] : parts[1].split(",").map(Number),
      baseKind: Number(parts[2]),
      base: Number(parts[3]),
      colors: parts[4],
    });
  }
  facePalettes = palettes;
  faceFamilies = families;
  faceWeights = weights;
  faceStyles = styles;
}

/** The id of a palette name a runtime style attribute uses, registering one the build didn't see. */
export function registerPaletteName(name: string): number {
  const at = paletteNames.indexOf(name);
  if (at >= 0) return at;
  paletteNames.push(name);
  return paletteNames.length - 1;
}

/** The name behind a palette id, for the CSS object model. */
export function paletteName(id: number): string {
  return id >= 0 && id < paletteNames.length ? paletteNames[id] : "";
}

/**
 * The palette of the face an element's text takes: its CPAL palette count and the light and dark
 * palette indices, choosing among a family's faces the way the host does (the style first, then
 * the nearest weight). Null when no face of the family has a palette table.
 */
/** The palette facts of the face a family's text takes. */
interface FacePaletteInfo {
  count: number;
  light: number;
  dark: number;
  /** The face's unicode-range (`lo-hi` pairs, "" for all), which a cascade has to respect. */
  ranges: string;
}

/** The face a family gives a weight and style, as the host's face_for() picks it. */
function facePaletteFor(family: number, weight: number, italic: number): FacePaletteInfo | null {
  if (facePalettes.length === 0) return null;
  const id = family - P.FF_CUSTOM;
  if (id < 0) return null;
  let best = -1;
  let bestDist = 0;
  for (let i = 0; i * 3 + 2 < facePalettes.length; i++) {
    if (faceFamilies[i] !== id) continue;
    const dist = faceFaceDistance(i, weight, italic);
    if (best < 0 || dist < bestDist) { best = i; bestDist = dist; }
  }
  if (best < 0) return null;
  return {
    count: facePalettes[best * 3],
    light: facePalettes[best * 3 + 1],
    dark: facePalettes[best * 3 + 2],
    ranges: tables.fontFaceRanges[best] ?? "",
  };
}

/** The palette of the face an element's text takes, for its own family. */
function facePalette(el: Node): FacePaletteInfo | null {
  return facePaletteFor(el.sv[P.P_FONT_FAMILY], el.sv[P.P_FONT_WEIGHT],
    el.sv[P.P_FONT_STYLE] === P.FS_ITALIC ? 1 : 0);
}

/** How far a face sits from a weight and style, as the host's face_for() measures it. */
function faceFaceDistance(i: number, weight: number, italic: number): number {
  const weights = faceWeights[i] ?? 400 * 1024 + 400;
  const lo = Math.floor(weights / 1024);
  const hi = weights % 1024;
  const styles = faceStyles[i] ?? 0;
  // CSS's weight search order: a covering face first, then below 400 the lighter faces, above
  // 500 the heavier ones, and in 400..500 the range before either side.
  let near = 0;
  let cat = 0;
  if (weight < lo || weight > hi) {
    const above = lo > weight;
    near = above ? lo - weight : weight - hi;
    if (weight < 400) cat = above ? 2 : 1;
    else if (weight > 500) cat = above ? 1 : 2;
    else cat = above ? 3 : 2;
  }
  return (styles === italic ? 0 : 1000000000) + cat * 1000000 + near;
}

/**
 * The font-palette a node's text asks for with the family `family`, as the run section the host
 * takes: the palette index and any override colours, or "" when the face has no palettes at all.
 * `light` and `dark` pick the first palette the font marks for that background, and fall back to
 * palette 0 when it marks none or has no CPAL table. Palette 0 is always spelled out on a face
 * that has palettes, because the host's own default follows the system appearance.
 */
function paletteSectionFor(el: Node, family: number): string {
  const value = el.sv[P.P_FONT_PALETTE];
  const info = facePaletteFor(family, el.sv[P.P_FONT_WEIGHT],
    el.sv[P.P_FONT_STYLE] === P.FS_ITALIC ? 1 : 0);
  if (value === P.PALETTE_NORMAL) {
    return info !== null && info.count > 0 ? "p:0" : "";
  }
  let baseKind = P.PB_INDEX;
  let base = 0;
  let colors = "";
  if (value === P.PALETTE_LIGHT) baseKind = P.PB_LIGHT;
  else if (value === P.PALETTE_DARK) baseKind = P.PB_DARK;
  else {
    // The last rule with this name whose font-family names the family applies; with none, the
    // value behaves as normal, which is palette 0 on a face that has palettes.
    let found: PaletteRule | null = null;
    for (const rule of paletteRules) {
      if (rule.name === value - P.PALETTE_NAME && rule.families.indexOf(family) >= 0) found = rule;
    }
    if (found === null) return info !== null && info.count > 0 ? "p:0" : "";
    baseKind = found.baseKind;
    base = found.base;
    colors = found.colors;
  }
  if (info === null || info.count <= 0) return "";
  let index: number;
  if (baseKind === P.PB_LIGHT) index = info.light >= 0 ? info.light : 0;
  else if (baseKind === P.PB_DARK) index = info.dark >= 0 ? info.dark : 0;
  // An index the font has no palette for behaves as 0.
  else index = base >= 0 && base < info.count ? base : 0;
  // Palette 0 is still named: an unnamed font takes the host's own default.
  return "p:" + index + (colors === "" ? "" : ":" + colors);
}

/** The palette section for the element's own (first) family. */
function paletteSection(el: Node): string {
  return paletteSectionFor(el, el.sv[P.P_FONT_FAMILY]);
}

/**
 * The later families of a font-family list, as the cascade the host hangs on the primary font:
 * `c:<family>[=<palette index>[:<colours>]];...`, or "" when the list has one family or the
 * first face covers every character. Only a face with a unicode-range needs the cascade: the
 * host restricts the primary face to its range, and CoreText falls the other characters to these
 * entries. Each entry carries the palette its own family's rule gives it.
 */
function fallbackSection(el: Node): string {
  const listId = el.sv[P.P_FONT_FAMILY_LIST];
  if (listId <= 0) return "";
  const row = tables.fontFamilyLists[listId - 1];
  if (row === undefined) return "";
  const families = row.split(",").map(Number);
  if (families.length === 0) return "";
  const primary = facePaletteFor(families[0], el.sv[P.P_FONT_WEIGHT],
    el.sv[P.P_FONT_STYLE] === P.FS_ITALIC ? 1 : 0);
  // The list is walked for every character a family has no glyph for — a face covers the
  // characters its font has, not the whole of Unicode — so the families after the first are what
  // the rest of the text falls to. A first family with no face of its own falls to them as well.
  const entries: string[] = [];
  for (let i = 1; i < families.length; i++) {
    const pal = paletteSectionFor(el, families[i]);
    entries.push(pal === "" ? String(families[i]) : families[i] + "=" + pal.slice(2));
  }
  // With no family after the first, the system font (0) is what the rest of the text falls to.
  if (entries.length === 0 && primary !== null) entries.push("0");
  return entries.length === 0 ? "" : "c:" + entries.join(";");
}

/**
 * The OpenType features the font-variant longhands name, as `tag=value` pairs joined by
 * semicolons. A pair's second value is turned off as well: `lining-nums` asks for lining figures
 * and for the font's old-style ones not to be used, and a browser sends both.
 */
function variantSpec(el: Node): string {
  const out: string[] = [];
  const caps = el.sv[P.P_FONT_VARIANT_CAPS];
  if (caps === P.FVC_SMALL_CAPS) { out.push("smcp=1"); }
  else if (caps === P.FVC_ALL_SMALL_CAPS) { out.push("smcp=1"); out.push("c2sc=1"); }
  else if (caps === P.FVC_PETITE_CAPS) { out.push("pcap=1"); }
  else if (caps === P.FVC_ALL_PETITE_CAPS) { out.push("pcap=1"); out.push("c2pc=1"); }
  else if (caps === P.FVC_UNICASE) { out.push("unic=1"); }
  else if (caps === P.FVC_TITLING_CAPS) { out.push("titl=1"); }
  const lig = el.sv[P.P_FONT_VARIANT_LIGATURES];
  if ((lig & P.FVL_COMMON_ON) !== 0) { out.push("liga=1"); out.push("clig=1"); }
  else if ((lig & P.FVL_COMMON_OFF) !== 0) { out.push("liga=0"); out.push("clig=0"); }
  if ((lig & P.FVL_DISCRETIONARY_ON) !== 0) { out.push("dlig=1"); }
  else if ((lig & P.FVL_DISCRETIONARY_OFF) !== 0) { out.push("dlig=0"); }
  if ((lig & P.FVL_HISTORICAL_ON) !== 0) { out.push("hlig=1"); }
  else if ((lig & P.FVL_HISTORICAL_OFF) !== 0) { out.push("hlig=0"); }
  if ((lig & P.FVL_CONTEXTUAL_ON) !== 0) { out.push("calt=1"); }
  else if ((lig & P.FVL_CONTEXTUAL_OFF) !== 0) { out.push("calt=0"); }
  const num = el.sv[P.P_FONT_VARIANT_NUMERIC];
  if ((num & P.FVN_LINING) !== 0) { out.push("lnum=1"); out.push("onum=0"); }
  else if ((num & P.FVN_OLDSTYLE) !== 0) { out.push("onum=1"); out.push("lnum=0"); }
  if ((num & P.FVN_PROPORTIONAL) !== 0) { out.push("pnum=1"); out.push("tnum=0"); }
  else if ((num & P.FVN_TABULAR) !== 0) { out.push("tnum=1"); out.push("pnum=0"); }
  if ((num & P.FVN_DIAGONAL_FRACTIONS) !== 0) { out.push("frac=1"); out.push("afrc=0"); }
  else if ((num & P.FVN_STACKED_FRACTIONS) !== 0) { out.push("afrc=1"); out.push("frac=0"); }
  if ((num & P.FVN_ORDINAL) !== 0) { out.push("ordn=1"); }
  if ((num & P.FVN_SLASHED_ZERO) !== 0) { out.push("zero=1"); }
  const ea = el.sv[P.P_FONT_VARIANT_EAST_ASIAN];
  if ((ea & P.FVE_JIS78) !== 0) { out.push("jp78=1"); }
  else if ((ea & P.FVE_JIS83) !== 0) { out.push("jp83=1"); }
  else if ((ea & P.FVE_JIS90) !== 0) { out.push("jp90=1"); }
  else if ((ea & P.FVE_JIS04) !== 0) { out.push("jp04=1"); }
  else if ((ea & P.FVE_SIMPLIFIED) !== 0) { out.push("smpl=1"); }
  else if ((ea & P.FVE_TRADITIONAL) !== 0) { out.push("trad=1"); }
  if ((ea & P.FVE_FULL_WIDTH) !== 0) { out.push("fwid=1"); }
  else if ((ea & P.FVE_PROPORTIONAL_WIDTH) !== 0) { out.push("pwid=1"); }
  if ((ea & P.FVE_RUBY) !== 0) { out.push("ruby=1"); }
  const pos = el.sv[P.P_FONT_VARIANT_POSITION];
  if (pos === P.FVP_SUB) { out.push("subs=1"); }
  else if (pos === P.FVP_SUPER) { out.push("sups=1"); }
  if (el.sv[P.P_FONT_VARIANT_ALTERNATES] === P.FVA_HISTORICAL_FORMS) { out.push("hist=1"); }
  // font-kerning asks the font itself: normal turns the kern feature on, none off, auto leaves
  // the font's own default.
  const kern = el.sv[P.P_FONT_KERNING];
  if (kern === P.FKERN_NONE) { out.push("kern=0"); out.push("vkrn=0"); }
  else if (kern === P.FKERN_NORMAL) { out.push("kern=1"); out.push("vkrn=1"); }
  return out.join(";");
}

/** `base` with `over`'s tags taking their values, the tags base doesn't have added on the end. */
function mergeSpec(base: string, over: string): string {
  const tags: string[] = [];
  const values: number[] = [];
  for (const pair of base.split(";")) {
    const eq = pair.indexOf("=");
    if (eq <= 0) continue;
    tags.push(pair.slice(0, eq));
    values.push(Number(pair.slice(eq + 1)));
  }
  for (const pair of over.split(";")) {
    const eq = pair.indexOf("=");
    if (eq <= 0) continue;
    const tag = pair.slice(0, eq);
    const v = Number(pair.slice(eq + 1));
    const at = tags.indexOf(tag);
    if (at >= 0) values[at] = v;
    else { tags.push(tag); values.push(v); }
  }
  const out: string[] = [];
  for (let i = 0; i < tags.length; i++) out.push(tags[i] + "=" + values[i]);
  return out.join(";");
}

/**
 * The host's run id for the font an element's text asks for besides its face, 0 when it asks for
 * nothing special: the OpenType features of the font-variant longhands and font-feature-settings
 * (the latter overriding any tag they share), the variation axes of font-variation-settings, and
 * the kinds of face font-synthesis lets the host draw in when the family lacks them. The host
 * turns the run into attributes of the run's font, which change both the drawing and the
 * measuring of the text.
 */
/**
 * The host's run id for each distinct run text: the host parses the text into a features struct
 * and keeps one per call, so a page whose thousands of text nodes share a handful of runs asks
 * once each rather than once per node.
 */
const featureRunIds: Map<string, number> = new Map();

function runIdFor(text: string): number {
  const hit = featureRunIds.get(text);
  if (hit !== undefined) return hit;
  const id = hostRegisterFeatures(text);
  if (featureRunIds.size > 4096) featureRunIds.clear();
  featureRunIds.set(text, id);
  return id;
}

export function featureRun(el: Node): number {
  // The paint walk asks this of every text run it draws. The answer only moves when the node is
  // restyled, its language moves, or the compiled tables change, so a node that has not been
  // restyled since its last answer returns it without reading its settings again.
  const lang = langOf(el);
  if (el.featValid && el.featGen === styleGen && el.featLang === lang && el.featTables === fontTables) {
    return el.featRun;
  }
  const id = el.sv[P.P_FONT_FEATURE_SETTINGS];
  const varId = el.sv[P.P_FONT_VARIATION_SETTINGS];
  const synth = (el.sv[P.P_FONT_SYNTHESIS_WEIGHT] !== 0 ? P.FSYNTH_WEIGHT : 0) |
    (el.sv[P.P_FONT_SYNTHESIS_STYLE] !== 0 ? P.FSYNTH_STYLE : 0) |
    (el.sv[P.P_FONT_SYNTHESIS_SMALL_CAPS] !== 0 ? P.FSYNTH_SMALL_CAPS : 0);
  const caps = el.sv[P.P_FONT_VARIANT_CAPS];
  const lig = el.sv[P.P_FONT_VARIANT_LIGATURES];
  const num = el.sv[P.P_FONT_VARIANT_NUMERIC];
  const ea = el.sv[P.P_FONT_VARIANT_EAST_ASIAN];
  const pos = el.sv[P.P_FONT_VARIANT_POSITION];
  const alt = el.sv[P.P_FONT_VARIANT_ALTERNATES];
  const palette = el.sv[P.P_FONT_PALETTE];
  const list = el.sv[P.P_FONT_FAMILY_LIST];
  const kerning = el.sv[P.P_FONT_KERNING];
  const adjust = el.sv[P.P_FONT_SIZE_ADJUST];
  const stretch = el.sv[P.P_FONT_STRETCH];
  // One number for the masks, so a node registers its run once per distinct set of them; the
  // two list ids are kept apart, as they can both grow with the app.
  let sig = synth;
  sig = sig * 8 + caps;
  sig = sig * 256 + lig;
  sig = sig * 256 + num;
  sig = sig * 512 + ea;
  sig = sig * 4 + pos;
  sig = sig * 2 + alt;
  sig = sig * 3 + kerning;
  sig = sig * 1001 + (adjust < 0 ? 1000 : Math.round(adjust * 1000));
  sig = sig * 256 + Math.round(stretch);
  // The palette resolves against the element's own family and weight, so those are part of the
  // signature too: an inherited palette picks a different index on a different face.
  const src = ((((id * 65536 + varId) * 4096 + palette) * 8192 + el.sv[P.P_FONT_FAMILY]) * 4096 + list) * 1001 +
    (adjust < 0 ? 1000 : Math.round(adjust * 1000)) * 256 + Math.round(stretch) * 4 +
    (el.sv[P.P_FONT_STYLE] === P.FS_ITALIC ? 1 : 0);
  // The signature covers everything the run depends on, so a node that hasn't changed since the
  // last call answers at once: the palette and fallback sections below are only worked out when
  // the run is registered.
  if (el.featTables === fontTables && el.featSig === sig && el.featSrc === src && el.featLang === lang) {
    el.featValid = true;
    el.featTables = fontTables;
    el.featGen = styleGen;
    return el.featRun;
  }
  // Even `normal` needs a run on a face with palettes: see paletteSection().
  const pal = paletteSection(el);
  // The rest of the family list, which is what a character the first family has no glyph for
  // falls to.
  const cascade = fallbackSection(el);
  const plain = caps === 0 && lig === 0 && num === 0 && ea === 0 && pos === 0 && alt === 0;
  if (plain && id <= 0 && varId <= 0 && synth === P.FSYNTH_ALL && pal === "" && cascade === "" &&
    kerning === P.FKERN_AUTO && adjust < 0 && stretch === 100 && lang === "") {
    // Plain text is the common case, so its answer is remembered too.
    el.featSig = sig;
    el.featSrc = src;
    el.featLang = lang;
    el.featRun = 0;
    el.featValid = true;
    el.featTables = fontTables;
    el.featGen = styleGen;
    return 0;
  }
  let spec = variantSpec(el);
  const explicit = featureSpec(id);
  if (explicit !== "") spec = spec === "" ? explicit : mergeSpec(spec, explicit);
  const axes = variationSpec(varId);
  // A run is one string for the host: its feature settings, its variation axes, the kinds of
  // face it may synthesize and the colour palette it uses, each under a letter.
  const run = spec === "" && axes === "" && synth === P.FSYNTH_ALL && pal === "" && cascade === "" &&
    kerning === P.FKERN_AUTO && adjust < 0 && stretch === 100 && lang === "" ? 0
    : runIdFor("f:" + spec + "|v:" + axes + "|s:" + synth +
      (pal === "" ? "" : "|" + pal) + (cascade === "" ? "" : "|" + cascade) +
      (adjust < 0 ? "" : "|a:" + adjust) +
      (kerning === P.FKERN_NONE ? "|k:0" : "") + (stretch === 100 ? "" : "|t:" + stretch) +
      (lang === "" ? "" : "|g:" + lang));
  if (run > 0 && stretch !== 100) runStretch[run - 1] = stretch;
  el.featSig = sig;
  el.featSrc = src;
  el.featLang = lang;
  el.featRun = run;
  el.featValid = true;
  el.featTables = fontTables;
  el.featGen = styleGen;
  return run;
}

/**
 * The size a container query unit measures: the content box of the nearest ancestor container
 * that has a `container-type` for that axis, or the viewport when there is none. The size is
 * recorded on the container, so a layout that changes it can ask for another style pass.
 */
function cqLength(el: Node, block: boolean): number {
  for (let p = el.parentElement; p !== null; p = p.parentElement) {
    const type = p.sv[P.P_CONTAINER_TYPE];
    if (type === P.CT_NORMAL) continue;
    if (block && type !== P.CT_SIZE) continue;
    noteQueriedContainer(p);
    if (block) {
      p.qUsedH = p.contentH;
      return p.contentH;
    }
    p.qUsedW = p.contentW;
    return p.contentW;
  }
  return block ? viewport.h : viewport.w;
}

/**
 * The content-box size of the nearest container that measures an axis for `el`, or the viewport
 * when it has none: what one cq unit is 1% of. Resolving a cq unit during the style pass records
 * the size it read (cqLength); this one doesn't, for the paint-time values the style pass leaves
 * with their units, like a gradient's colour stops.
 */
/** A length written in a cq unit, in px, measured against `el`'s nearest container for that axis,
 *  or the viewport when it has none. Paint-time values that keep their units (a transform's
 *  translate, a shadow's offset) resolve through here. */
export function cqUnitPx(el: Node, v: number, unit: number): number {
  if (unit === P.U_CQH || unit === P.U_CQB) return (v / 100) * cqLength(el, true);
  if (unit === P.U_CQMIN) return (v / 100) * Math.min(cqLength(el, false), cqLength(el, true));
  if (unit === P.U_CQMAX) return (v / 100) * Math.max(cqLength(el, false), cqLength(el, true));
  return (v / 100) * cqLength(el, false); // cqw and cqi measure the inline axis
}

export function containerBasis(el: Node, block: boolean): number {
  // The style pass recorded the containers around each node, so the common answer — no container
  // at all — costs one test.
  const start = el.parentNode;
  if (start === null) return block ? viewport.h : viewport.w;
  if (start.cqKnown) {
    const c = block ? start.cqBlock : start.cqInline;
    if (c === null) return block ? viewport.h : viewport.w;
    return block ? c.contentH : c.contentW;
  }
  for (let p = el.parentElement; p !== null; p = p.parentElement) {
    const type = p.sv[P.P_CONTAINER_TYPE];
    if (type === P.CT_NORMAL) continue;
    if (block && type !== P.CT_SIZE) continue;
    return block ? p.contentH : p.contentW;
  }
  return block ? viewport.h : viewport.w;
}

/**
 * An expression evaluated for `el`: one that uses a cq unit measures the element's containers, and
 * the others leave those at their default, the viewport, which is what CSS uses when there is no
 * container. Reading a container's size here records it for containerStale, as cqLength does.
 */
export function exprLength(el: Node, id: number, base: number, fontSize: number): number {
  const rem = rootFontSize(), lh = el.sv[P.P_LINE_HEIGHT];
  if (!exprHasCq(id)) return evalExpr(id, base, viewport.w, viewport.h, fontSize, viewport.w, viewport.h, rem, lh);
  return evalExpr(id, base, viewport.w, viewport.h, fontSize, cqLength(el, false), cqLength(el, true), rem, lh);
}

/**
 * True when a container's size changed since the style pass read it, so the queries over it may
 * now answer differently. Layout is what settles a container's size, so the frame runs style and
 * layout again until this is false, which a size-containment box reaches at once: its own size
 * doesn't depend on the content the query changed.
 */
export function containerStale(el: Node): boolean {
  // Only the boxes a query read a size from can have answered for a size they no longer have.
  for (let i = 0; i < queriedContainers.length; i++) {
    const c = queriedContainers[i];
    if (c.qUsedW >= 0 && c.qUsedW !== c.contentW && c.isConnected) return true;
    if (c.qUsedH >= 0 && c.qUsedH !== c.contentH && c.isConnected) return true;
  }
  return false;
}
