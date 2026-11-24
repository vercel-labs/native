// Style sheet parsing with CSS error recovery.

import { type Diagnostics, locator } from "../diagnostics.ts";
import { skipString, splitDeclarations } from "../../shared/css/declarations.ts";
import { compileDeclarations } from "./declarations.ts";
import { encodeCounterStyle, parseCounterStyle } from "../../shared/css/counter-styles.ts";
import { type LayerRegistry } from "./layers.ts";
import type { CounterStyleContext } from "./types.ts";
import { parsePropertyRule } from "./property.ts";
import { parseSelector, selectorWasInvalid, splitTopLevel } from "./selectors.ts";
import { supportsHolds } from "./supports.ts";
import type { ContentContext, CssRule, Decl, FontContext, KeyframesContext, PropertyRule, Selector } from "./types.ts";
import * as P from "../../shared/props.ts";

let ruleOrder = 0;

/**
 * Finds the first `{` at nesting depth zero, ignoring strings and ()/[] blocks. Returns
 * src.length when the prelude runs to the end of the sheet.
 */
export function findOpen(src: string, i: number): number {
  let paren = 0, bracket = 0;
  for (let j = i; j < src.length; j++) {
    const ch = src[j];
    if (ch === '"' || ch === "'") j = skipString(src, j) - 1;
    else if (ch === "(") paren++;
    else if (ch === ")") paren = Math.max(0, paren - 1);
    else if (ch === "[") bracket++;
    else if (ch === "]") bracket = Math.max(0, bracket - 1);
    else if (ch === "{" && paren === 0 && bracket === 0) return j;
  }
  return src.length;
}

/** Index of the `}` matching the `{` at `open`, or src.length if the block is unterminated. */
export function findClose(src: string, open: number): number {
  let depth = 1;
  for (let j = open + 1; j < src.length; j++) {
    const ch = src[j];
    if (ch === '"' || ch === "'") j = skipString(src, j) - 1;
    else if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return j;
    }
  }
  return src.length;
}

/** Finds the `;` ending an at-rule prelude, ignoring strings and blocks. */
function findSemicolon(src: string, i: number): number {
  let paren = 0, bracket = 0;
  for (let j = i; j < src.length; j++) {
    const ch = src[j];
    if (ch === '"' || ch === "'") j = skipString(src, j) - 1;
    else if (ch === "(") paren++;
    else if (ch === ")") paren = Math.max(0, paren - 1);
    else if (ch === "[") bracket++;
    else if (ch === "]") bracket = Math.max(0, bracket - 1);
    else if (ch === "{" && paren === 0 && bracket === 0) return -1; // a block ends the prelude
    else if (ch === ";" && paren === 0 && bracket === 0) return j;
  }
  return src.length;
}

export function parseCss(src: string, file: string, diags: Diagnostics, origin: "ua" | "author", fonts?: FontContext, content?: ContentContext, layers: LayerRegistry | null = null, props: PropertyRule[] | null = null, keyframes?: KeyframesContext, counterStyles?: CounterStyleContext): CssRule[] {
  // Blank out comments but keep offsets/newlines stable.
  src = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  // XHTML test files (and some hand-written ones) wrap style sheets in CDATA sections; the XML
  // parser would have removed the markers before CSS saw the text.
  src = src.replace(/<!\[CDATA\[/g, (m) => " ".repeat(m.length)).replace(/\]\]>/g, (m) => " ".repeat(m.length));
  const loc = locator(src);
  const rules: CssRule[] = [];
  parseRules(src, 0, src.length, "", "", "", false, rules, file, diags, origin, loc, fonts, content, layers, -1, props, keyframes, counterStyles);
  return rules;
}

/**
 * Parses the rules between `start` and `stop`, all of them inside the @media condition `media`,
 * the @container condition `container`, and the cascade layer `layer` (-1 outside every layer).
 */
function parseRules(src: string, start: number, stop: number, media: string, container: string, scope: string,
  starting: boolean, rules: CssRule[],
  file: string, diags: Diagnostics, origin: "ua" | "author", loc: (i: number) => [number, number],
  fonts: FontContext | undefined, content: ContentContext | undefined,
  layers: LayerRegistry | null, layer: number, props: PropertyRule[] | null, keyframes?: KeyframesContext,
  counterStyles?: CounterStyleContext): void {
  let i = start;

  while (i < stop) {
    while (i < stop && /\s/.test(src[i])) i++;
    if (i >= stop) break;

    // Stray `}` and `;` outside any rule are ignored, as is the CDO/CDC pair that HTML
    // comments leave in old style sheets (`<!--` … `-->`).
    if (src[i] === "}" || src[i] === ";") { i++; continue; }
    if (src.startsWith("<!--", i) || src.startsWith("-->", i)) {
      i += src.startsWith("<!--", i) ? 4 : 3;
      continue;
    }

    const [line, col] = loc(i);

    if (src[i] === "@") {
      const m = /^@([\w-]+)/.exec(src.slice(i));
      const name = (m ? m[1] : "").toLowerCase();
      const semi = findSemicolon(src, i);
      const brace = findOpen(src, i);
      if (name === "charset") {
        // Encoding is handled when the file is read; the rule itself is a no-op here.
        i = semi === src.length ? src.length : semi + 1;
        continue;
      }
      if (name === "namespace") {
        // The declaration is read up front (scanNamespaces) and consulted by selector parsing;
        // the rule has no declarations of its own.
        i = semi < 0 ? src.length : (semi === src.length ? src.length : semi + 1);
        continue;
      }
      if (name === "font-feature-values" && fonts) {
        // The aliases are collected up front (scanFontFeatureValues); the rule itself defines no
        // element's style.
        i = findClose(src, brace) + 1;
        continue;
      }
      if (name === "font-face" && fonts) {
        // compileApp registers font faces up front (they may be used before they are declared),
        // so by now the family is available to font-family.
        i = findClose(src, brace) + 1;
        continue;
      }
      if (name === "font-palette-values" && fonts) {
        // The rules were scanned with the font faces, before any declaration was compiled.
        i = findClose(src, brace) + 1;
        continue;
      }
      if (name === "layer" && layers !== null) {
        const preludeStart = i + (m === null ? 1 : m[0].length);
        const open = findOpen(src, i);
        if (semi >= 0 && (open >= stop || semi < open)) {
          // `@layer a, b;` only fixes the order of the named layers; it has no declarations.
          for (const raw of splitTopLevel(src.slice(preludeStart, semi), ",")) {
            const named = raw.trim();
            if (named !== "") layers.declare(layer, named);
          }
          i = semi === src.length ? src.length : semi + 1;
          continue;
        }
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @layer; ignored");
          break;
        }
        const prelude = src.slice(preludeStart, open).trim();
        // A block takes one name; a comma list is only the statement form above.
        if (prelude === "") {
          const inner = layers.anonymous(layer);
          parseRules(src, open + 1, close, media, container, scope, starting, rules, file, diags, origin, loc, fonts, content, layers, inner, props, keyframes, counterStyles);
        } else if (splitTopLevel(prelude, ",").length > 1 || /\s/.test(prelude)) {
          diags.note(file, line, col, "invalid @layer name; its rules are ignored");
        } else {
          const inner = layers.declare(layer, prelude);
          parseRules(src, open + 1, close, media, container, scope, starting, rules, file, diags, origin, loc, fonts, content, layers, inner, props, keyframes, counterStyles);
        }
        i = close + 1;
        continue;
      }
      if (name === "property" && props !== null) {
        // The rule registers a custom property: its syntax, whether it inherits, and the value it
        // starts from. A rule that gets a descriptor wrong is ignored whole, which is why the
        // check runs before anything is registered.
        const preludeStart = i + (m === null ? 1 : m[0].length);
        const open = findOpen(src, i);
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @property; ignored");
          break;
        }
        const parsed = parsePropertyRule(src.slice(preludeStart, open), src.slice(open + 1, close));
        if (parsed.rule === null) {
          diags.warn(file, line, col, `invalid @property rule ignored: ${parsed.why}`);
        } else {
          // Later rules win, as they do in a browser; the runtime registers in this order.
          props.push(parsed.rule);
        }
        i = close + 1;
        continue;
      }
      if (name === "counter-style" && counterStyles) {
        const open = findOpen(src, i);
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @counter-style; ignored");
          break;
        }
        const raw = src.slice(i + (m === null ? 1 : m[0].length), open).trim();
        const styleName = raw.length >= 2 && (raw[0] === '"' || raw[0] === "'") && raw[raw.length - 1] === raw[0]
          ? raw.slice(1, -1) : raw;
        if (!/^[-_a-zA-Z\u0080-\uffff][-_a-zA-Z0-9\u0080-\uffff]*$/.test(styleName) || styleName.toLowerCase() === "decimal") {
          diags.warn(file, line, col, `invalid @counter-style name '${styleName}'; ignored`);
        } else {
          const style = parseCounterStyle(styleName, src.slice(open + 1, close),
            (why) => diags.warn(file, line, col, why));
          if (typeof style === "string") {
            diags.warn(file, line, col, `${style}; ignored`);
          } else {
            counterStyles.style(encodeCounterStyle(style));
          }
        }
        i = close + 1;
        continue;
      }
      if ((name === "keyframes" || name === "-webkit-keyframes") && keyframes) {
        // The name is the rest of the prelude; a quoted one is written without its quotes.
        const open = findOpen(src, i);
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @keyframes; ignored");
          break;
        }
        const raw = src.slice(i + (m === null ? 1 : m[0].length), open).trim();
        const kfName = raw.length >= 2 && (raw[0] === '"' || raw[0] === "'") && raw[raw.length - 1] === raw[0]
          ? raw.slice(1, -1) : raw;
        if (kfName === "") {
          diags.warn(file, line, col, "@keyframes has no name; ignored");
        } else {
          parseKeyframes(src, open + 1, close, kfName, file, diags, loc, fonts, keyframes);
        }
        i = close + 1;
        continue;
      }
      if (name === "starting-style") {
        const open = findOpen(src, i);
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @starting-style; ignored");
          break;
        }
        parseRules(src, open + 1, close, media, container, scope, true, rules, file, diags, origin, loc,
          fonts, content, layers, layer, props, keyframes, counterStyles);
        i = close + 1;
        continue;
      }
      if (name === "media") {
        // Its rules are parsed in place, each remembering the condition it is inside.
        const open = findOpen(src, i);
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @media; ignored");
          break;
        }
        const query = src.slice(i + (m === null ? 1 : m[0].length), open).trim().toLowerCase().replace(/\s+/g, " ");
        const feature = unsupportedFeature(query);
        if (feature !== null) {
          diags.warn(file, line, col, `media feature '${feature}' isn't supported yet; the rules in this @media never apply`);
        }
        parseRules(src, open + 1, close, media === "" ? query : media + " and " + query, container, scope, starting,
          rules, file, diags, origin, loc, fonts, content, layers, layer, props, keyframes, counterStyles);
        i = close + 1;
        continue;
      }
      if (name === "supports") {
        // The condition is decided here, against what this build compiles (see supports.ts).
        const open = findOpen(src, i);
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @supports; ignored");
          break;
        }
        const cond = src.slice(i + (m === null ? 1 : m[0].length), open).trim().replace(/\s+/g, " ");
        const holds = supportsHolds(cond);
        if (holds === null) {
          diags.warn(file, line, col, `invalid @supports condition '${cond}'; its rules are ignored`);
        } else if (!holds) {
          diags.note(file, line, col, `@supports '${cond}' doesn't hold here; its rules are ignored`);
        } else {
          parseRules(src, open + 1, close, media, container, scope, starting, rules, file, diags, origin, loc, fonts, content, layers, layer, props, keyframes, counterStyles);
        }
        i = close + 1;
        continue;
      }
      if (name === "scope") {
        // The prelude names the scope root (and, after `to`, the limit): the rules inside match
        // only elements within that root, which the runtime checks against the element's ancestors.
        const open = findOpen(src, i);
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @scope; ignored");
          break;
        }
        const prelude = src.slice(i + (m === null ? 1 : m[0].length), open).trim().replace(/\s+/g, " ");
        if (prelude === "") diags.warn(file, line, col, "@scope needs a scope root; its rules apply everywhere");
        const inner = prelude === "" ? "(:root)" : prelude;
        parseRules(src, open + 1, close, media, container, scope === "" ? inner : scope + " " + inner, starting,
          rules, file, diags, origin, loc, fonts, content, layers, layer, props, keyframes, counterStyles);
        i = close + 1;
        continue;
      }
      if (name === "container") {
        // The prelude is the query container's name, if any, then the condition the rules test
        // against that ancestor's size (see runtime/container.ts).
        const open = findOpen(src, i);
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @container; ignored");
          break;
        }
        const query = src.slice(i + (m === null ? 1 : m[0].length), open).trim().replace(/\s+/g, " ");
        if (container !== "") {
          // A container query can't be nested, so the inner one is dropped, as a browser does.
          diags.warn(file, line, col, "@container can't be nested; ignored");
          i = close + 1;
          continue;
        }
        if (query === "") diags.warn(file, line, col, "@container has no condition; its rules always apply");
        parseRules(src, open + 1, close, media, query, scope, starting, rules, file, diags, origin, loc, fonts, content, layers, layer, props, keyframes, counterStyles);
        i = close + 1;
        continue;
      }
      if (name === "page") {
        // A page box: `@page`, `@page :first`, or a named page. Its descriptors are parsed for
        // their syntax; laying a page out and paginating comes later, so they have no effect.
        const open = findOpen(src, i);
        const close = open < stop ? findClose(src, open) : stop;
        if (open >= stop || close > stop) {
          diags.warn(file, line, col, "unterminated @page; ignored");
          break;
        }
        const body = src.slice(open + 1, close);
        for (const d of splitDeclarations(body)) {
          const colon = d.text.indexOf(":");
          if (colon < 0) continue;
          const prop = d.text.slice(0, colon).trim().toLowerCase();
          const [dl, dc] = loc(open + 1 + d.offset);
          if (prop === "size" || prop === "margin" || prop.startsWith("margin-") ||
            prop === "page-orientation" || prop === "bleed" || prop === "marks") {
            continue; // accepted for print, which this build doesn't lay out yet
          }
          diags.note(file, dl, dc, `@page descriptor '${prop}' isn't supported yet; ignored`);
        }
        i = close + 1;
        continue;
      }
      if (semi < 0 || brace < semi) {
        diags.warn(file, line, col, `@${name} is not supported yet; its rules are ignored`);
        const close = findClose(src, brace);
        i = close < src.length ? close + 1 : src.length;
      } else {
        diags.warn(file, line, col, `@${name} is not supported yet; ignored`);
        i = semi === src.length ? src.length : semi + 1;
      }
      continue;
    }

    const open = findOpen(src, i);
    if (open >= stop) {
      // A qualified rule whose prelude never reaches a block: drop it, as the spec says,
      // and there is nothing after it that could be a rule.
      diags.warn(file, line, col, "unterminated rule; ignored");
      break;
    }
    const close = findClose(src, open);
    const end = close < stop ? close : stop;
    const selectorStart = i;
    const selectorText = src.slice(i, open).trim();
    const body = src.slice(open + 1, end);
    const bodyStart = open + 1;
    i = end + 1;

    const selectors = parseSelectorList(selectorText, selectorStart, src, file, diags, loc);
    // A rule whose selectors all name nothing styles nothing: its declarations can't apply, so
    // they aren't compiled or reported.
    if (selectors.length === 0) continue;

    // content only generates anything on a ::before/::after rule; elsewhere it's reported, so
    // only the counter lists are handed to a rule that generates no box.

    // The rule's body: its own declarations, and any nested style rules or conditional at-rules
    // it holds (CSS Nesting).
    parseStyleBody(src, bodyStart, end, selectorText, selectorStart, line, col,
      media, container, scope, starting, layer, rules, file, diags, origin, loc, fonts, content, props);
  }
}



/** The selectors of one selector list, with the warning a selector this build can't parse gets. */
function parseSelectorList(selectorText: string, selectorStart: number, src: string, file: string,
  diags: Diagnostics, loc: (i: number) => [number, number]): Selector[] {
  const selectors: Selector[] = [];
  let selOffset = 0;
  for (const raw of splitTopLevel(selectorText, ",")) {
    const text = raw.trim();
    const sel = parseSelector(text);
    if (!sel && selectorWasInvalid()) {
      // A malformed selector is not a gap in the build: a browser drops the rule, and so does this.
      const [sl, sc] = loc(Math.max(selectorStart, src.indexOf(text, selectorStart + selOffset)));
      diags.note(file, sl, sc, `selector '${text}' is invalid; its rule is ignored`);
    } else if (!sel) {
      const [sl, sc] = loc(Math.max(selectorStart, src.indexOf(text, selectorStart + selOffset)));
      diags.warn(file, sl, sc, `selector '${text}' is not supported yet; skipped`,
        /\)\s+of\s/i.test(text) ? "the 'of S' argument of :nth-child() isn't supported yet; write the sibling condition on its own"
          : /:(?:is|where|not)\([^)]*[\s>+~]/.test(text) ? "a combinator inside :not(), or inside an :is()/:where() argument that already has an ancestor of its own, isn't supported yet"
          : /[\[]/.test(text) ? "attribute selectors with a namespace prefix aren't supported yet; the [attr], [attr=v], [attr~=v], [attr|=v], [attr^=v], [attr$=v] and [attr*=v] forms are"
          : /::?(?!hover|active|focus|focus-visible|focus-within|popover-open|checked|indeterminate|default|disabled|enabled|required|optional|read-only|read-write|placeholder-shown|valid|invalid|in-range|out-of-range|root|empty|first-child|last-child|only-child|nth-child|first-of-type|last-of-type|only-of-type|nth-of-type|nth-last-child|nth-last-of-type|not|is|where|has|before|after|marker|placeholder)/i.test(text)
            ? "supported pseudo-classes are :hover, :active, :focus, :focus-visible, :focus-within, :popover-open, :checked, :indeterminate, :default, :disabled, :enabled, :required, :optional, :read-only, :read-write, :placeholder-shown, :valid, :invalid, :in-range, :out-of-range, :root, :empty, :not(), :is(), :where(), :has(), :first-child, :last-child, :only-child, :nth-child() and their *-of-type forms; the supported pseudo-elements are ::before, ::after, ::marker and ::placeholder"
          : undefined);
    } else {
      selectors.push(...sel);
    }
    selOffset += raw.length + 1;
  }
  return selectors;
}

/**
 * The selector a nested style rule resolves to: its own text with `&` standing for the parent,
 * or, with no `&`, the parent and then the child as a descendant selector. Every parent selector
 * pairs with every child one, as the nesting rules say.
 */
function nestedSelectorText(parentText: string, childText: string): string {
  const parents = splitTopLevel(parentText, ",").map((t) => t.trim()).filter((t) => t !== "");
  const children = splitTopLevel(childText, ",").map((t) => t.trim()).filter((t) => t !== "");
  const out: string[] = [];
  for (const p of parents) {
    for (const c of children) {
      out.push(c.indexOf("&") >= 0 ? c.split("&").join(p) : p + " " + c);
    }
  }
  return out.join(", ");
}

/**
 * Parses the body of a style rule: the declarations of the rule itself and the nested rules CSS
 * Nesting allows — nested style rules (with `&`, or as a descendant selector) and the conditional
 * at-rules `@media`, `@supports`, `@container` and `@starting-style`, whose declarations apply to
 * the parent selector inside the condition. A nested block is found at the body's own brace depth,
 * so a value's braces or parentheses don't count.
 */
function parseStyleBody(src: string, start: number, stop: number, selectorText: string, selectorStart: number,
  line: number, col: number, media: string, container: string, scope: string, starting: boolean, layer: number,
  rules: CssRule[], file: string, diags: Diagnostics, origin: "ua" | "author", loc: (i: number) => [number, number],
  fonts: FontContext | undefined, content: ContentContext | undefined, props: PropertyRule[] | null): void {
  const selectors = parseSelectorList(selectorText, selectorStart, src, file, diags, loc);
  const ruleContent = content === undefined ? undefined
    : selectors.some((s) => s.pseudo !== P.PE_NONE) ? content
      : { counter: content.counter, counterStyle: content.counterStyle };
  const emit = (decls: Decl[]): void => {
    if (selectors.length > 0) {
      rules.push({ selectors, decls, order: ruleOrder++, origin, file, line, col, media, layer, container, scope, starting });
    }
  };
  const nested = (prelude: string, open: number, close: number, preludeAt: number): void => {
    if (prelude.startsWith("@")) {
      const m = /^@([\w-]+)/.exec(prelude);
      const name = (m ? m[1] : "").toLowerCase();
      const rest = prelude.slice(m === null ? 1 : m[0].length).trim().replace(/\s+/g, " ");
      const [nl, nc] = loc(preludeAt);
      if (name === "media") {
        const query = rest.toLowerCase();
        const feature = unsupportedFeature(query);
        if (feature !== null) {
          diags.warn(file, nl, nc, `media feature '${feature}' isn't supported yet; the rules in this @media never apply`);
        }
        parseStyleBody(src, open, close, selectorText, selectorStart, line, col,
          media === "" ? query : media + " and " + query, container, scope, starting, layer,
          rules, file, diags, origin, loc, fonts, content, props);
        return;
      }
      if (name === "supports") {
        const holds = supportsHolds(rest);
        if (holds === null) diags.warn(file, nl, nc, `invalid @supports condition '${rest}'; its rules are ignored`);
        else if (!holds) diags.note(file, nl, nc, `@supports '${rest}' doesn't hold here; its rules are ignored`);
        else {
          parseStyleBody(src, open, close, selectorText, selectorStart, line, col, media, container, scope,
            starting, layer, rules, file, diags, origin, loc, fonts, content, props);
        }
        return;
      }
      if (name === "container") {
        if (container !== "") {
          diags.warn(file, nl, nc, "@container can't be nested; ignored");
          return;
        }
        if (rest === "") diags.warn(file, nl, nc, "@container has no condition; its rules always apply");
        parseStyleBody(src, open, close, selectorText, selectorStart, line, col, media, rest, scope, starting,
          layer, rules, file, diags, origin, loc, fonts, content, props);
        return;
      }
      if (name === "starting-style") {
        parseStyleBody(src, open, close, selectorText, selectorStart, line, col, media, container, scope, true,
          layer, rules, file, diags, origin, loc, fonts, content, props);
        return;
      }
      diags.warn(file, nl, nc, `@${name} inside a rule isn't supported yet; its declarations are ignored`);
      return;
    }
    parseStyleBody(src, open, close, nestedSelectorText(selectorText, prelude), preludeAt, line, col,
      media, container, scope, starting, layer, rules, file, diags, origin, loc, fonts, content, props);
  };

  let chunk = start;
  let declStop = start;
  let i = start;
  while (i < stop) {
    const ch = src[i];
    if (ch === '"' || ch === "'") {
      let j = i + 1;
      while (j < stop && src[j] !== ch) {
        if (src[j] === "\\") j++;
        j++;
      }
      i = j + 1;
      continue;
    }
    if (ch === "(") {
      let depth = 0;
      let j = i;
      while (j < stop) {
        if (src[j] === "(") depth++;
        else if (src[j] === ")" && --depth === 0) { j++; break; }
        j++;
      }
      i = j;
      continue;
    }
    if (ch === ";") {
      i++;
      declStop = i;
      continue;
    }
    if (ch === "{") {
      const close = findClose(src, i);
      const end = close < stop ? close : stop;
      // Declarations run to the last top-level `;`; the text after it names what the block is.
      if (declStop > chunk) {
        emit(compileDeclarations(src.slice(chunk, declStop), (off) => loc(chunk + off), file, diags, fonts, ruleContent));
      }
      const preludeAt = declStop;
      let p = preludeAt;
      while (p < i && /\s/.test(src[p])) p++;
      nested(src.slice(p, i).trim(), i + 1, end, p);
      i = end + 1;
      chunk = i;
      declStop = i;
      continue;
    }
    i++;
  }
  if (chunk < stop) {
    emit(compileDeclarations(src.slice(chunk, stop), (off) => loc(chunk + off), file, diags, fonts, ruleContent));
  }
}

/**
 * The blocks of one @keyframes rule: `<from | to | percentage> [, ...] { declarations }`. The
 * selector's offset is its percentage of the way through the animation, `from` 0 and `to` 1.
 */
function parseKeyframes(src: string, start: number, stop: number, name: string, file: string,
  diags: Diagnostics, loc: (i: number) => [number, number], fonts: FontContext | undefined,
  keyframes: KeyframesContext): void {
  keyframes.rule(name);
  let i = start;
  while (i < stop) {
    while (i < stop && /\s/.test(src[i])) i++;
    if (i >= stop) break;
    if (src[i] === "}" || src[i] === ";") { i++; continue; }
    const [line, col] = loc(i);
    const open = findOpen(src, i);
    if (open >= stop) {
      diags.warn(file, line, col, "unterminated @keyframes block; ignored");
      break;
    }
    const close = findClose(src, open);
    const end = close < stop ? close : stop;
    const selectorText = src.slice(i, open).trim();
    const body = src.slice(open + 1, end);
    const bodyStart = open + 1;
    i = end + 1;
    // An unsupported property in a block is reported as it is anywhere else, but an invalid
    // selector only drops that block, so it is a note rather than a page-skipping warning.
    const decls = compileDeclarations(body, (off) => loc(bodyStart + off), file, diags, fonts, undefined);
    for (const raw of splitTopLevel(selectorText, ",")) {
      const sel = raw.trim().toLowerCase();
      let offset = -1;
      if (sel === "from") offset = 0;
      else if (sel === "to") offset = 1;
      else {
        const m = /^([-+]?(?:\d+\.?\d*|\.\d+))%$/.exec(sel);
        if (m !== null) offset = parseFloat(m[1]) / 100;
      }
      if (offset < 0 || offset > 1) {
        diags.note(file, line, col, `keyframe selector '${raw.trim()}' is not supported; its block is ignored`);
        continue;
      }
      keyframes.block(name, offset, decls);
    }
  }
}

// The media features the runtime can evaluate. A query naming another one never matches, which
// is worth a warning since the rules then silently do nothing.
const MEDIA_FEATURES = new Set([
  "width", "height", "device-width", "device-height", "aspect-ratio", "device-aspect-ratio",
  "orientation", "resolution", "device-pixel-ratio", "color", "color-index", "monochrome", "grid",
  "hover", "any-hover", "pointer", "any-pointer",
  "prefers-color-scheme", "prefers-contrast", "prefers-reduced-transparency", "prefers-reduced-motion",
  "prefers-reduced-data", "forced-colors", "color-gamut", "dynamic-range", "video-dynamic-range",
  "scripting", "update", "display-mode", "scan", "overflow-block", "overflow-inline",
]);

/** Is `name` a feature this build evaluates, with or without a min-/max- prefix? */
function knownFeature(name: string): boolean {
  if (MEDIA_FEATURES.has(name)) return true;
  const bare = name.startsWith("min-") || name.startsWith("max-") ? name.slice(4) : name;
  return MEDIA_FEATURES.has(bare);
}

/** The feature a parenthesised condition names: before a colon, in a range, or the whole text. */
function featureOf(inner: string): string {
  const colon = inner.indexOf(":");
  if (colon >= 0) return inner.slice(0, colon).trim().toLowerCase();
  const tokens = inner.split(/[\s<>=]+/).filter((t) => t !== "");
  for (const t of tokens) if (knownFeature(t.toLowerCase())) return t.toLowerCase();
  return (tokens[0] ?? inner).toLowerCase();
}

function unsupportedFeature(query: string): string | null {
  // A feature's value may hold a function of its own, as in `(min-width: calc(30em + 50px))`, so
  // each parenthesised group is taken whole rather than stopping at the value's own parentheses.
  for (let i = 0; i < query.length; i++) {
    if (query[i] !== "(") continue;
    let depth = 0;
    let close = -1;
    for (let j = i; j < query.length; j++) {
      if (query[j] === "(") depth++;
      else if (query[j] === ")" && --depth === 0) { close = j; break; }
    }
    if (close < 0) return null;
    const inner = query.slice(i + 1, close).trim();
    const name = featureOf(inner);
    if (!knownFeature(name)) return name;
    i = close;
  }
  return null;
}
