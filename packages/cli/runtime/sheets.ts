import { Element, ShadowRoot } from "./dom.ts";
// Style sheets built at runtime: the CSSOM side of <style> elements, document.styleSheets and
// the constructable sheets a page adds through adoptedStyleSheets. Each sheet's text is split
// into rules here and compiled with the shared value parser; the style engine then matches the
// rules alongside the compiled ones (see the cascade in style.ts).

import * as P from "../shared/props.ts";
import { LayerRegistry } from "../shared/css/layers.ts";
import { parseDeclarationBlock, skipString } from "../shared/css/declarations.ts";
import { parseSelector, splitTopLevel } from "../shared/css/selectors.ts";
import { COMB_ADJACENT, COMB_GENERAL } from "../shared/css/types.ts";
import { animKeyframes, animNames, wideCode } from "../shared/css/anim.ts";
import { longhandIds } from "../shared/css/shorthands.ts";
import type { ContentContext, Decl, FontContext, Selector } from "../shared/css/types.ts";
import { invalidateStyle, stateUsage } from "./invalidation.ts";
import { decodeCounterStyle, encodeCounterStyle, parseCounterStyle } from "../shared/css/counter-styles.ts";
import type { CounterStyleSpec } from "../shared/css/counter-styles.ts";

/** One style rule of a runtime sheet: its selectors, declarations and @media condition. */
/**
 * The cascade layers the runtime sheets declare, in the order the document meets them: a sheet a
 * script writes puts its rules where its @layer blocks say, as a compiled sheet's do.
 */
let runtimeLayers = new LayerRegistry();
let runtimeLayerOrder: { key: number[]; count: number } | null = null;

function layerOrderOf(): { key: number[]; count: number } {
  if (runtimeLayerOrder === null) runtimeLayerOrder = runtimeLayers.order();
  return runtimeLayerOrder;
}

/** The rank of a layer id for normal declarations; -1 (unlayered) outranks every layer. */
export function sheetLayerRank(layer: number): number {
  const order = layerOrderOf();
  return layer < 0 ? order.count : order.key[layer];
}

/** The number of layer positions, which reverses them for important declarations. */
export function sheetLayerTotal(): number {
  return layerOrderOf().count;
}

/** Forgets the layers a page declared, as the next page starts without them. */
export function resetRuntimeLayers(): void {
  runtimeLayers = new LayerRegistry();
  runtimeLayerOrder = null;
}

export interface SheetRule {
  selectors: Selector[];
  decls: Decl[];
  /** The @media condition the rule is inside, or "" for a rule outside any. */
  media: string;
  /** The @container condition the rule is inside, or ""; tested against ancestor containers. */
  container: string;
  selectorText: string;
  cssText: string;
  /** Where the rule sits in its sheet's text, so the CSSOM list keeps the text's order. */
  pos: number;
  /** The cascade layer the rule is inside (-1 outside every layer). */
  layer: number;
}

/** An `@counter-style` rule of a runtime sheet, as the CSSOM's CSSCounterStyleRule shows it. */
export interface CounterRule {
  name: string;
  descriptors: { prop: string; text: string }[];
  pos: number;
}

/** A rule facade the CSSOM hands out, style or counter style. */
type Facade = CSSRule | CSSCounterStyleRule | CSSMediaRule;

// The style engine registers a runtime counter style here; it can't be imported (style.ts is a
// client of this module), so the engine hands its two functions over at load time.
let addCounterStyle: ((spec: CounterStyleSpec) => void) | null = null;
let dropCounterStyle: ((name: string) => void) | null = null;

/** Tells this module how to put a runtime @counter-style rule into the style engine's registry. */
export function setCounterStyleSink(add: (spec: CounterStyleSpec) => void, drop: (name: string) => void): void {
  addCounterStyle = add;
  dropCounterStyle = drop;
}

/**
 * A sheet's rules can name any form state: its selectors are compiled when the sheet is set, so
 * a control's change restyles whenever a runtime sheet is in play (see noteControlChange).
 */
function noteSheetStates(): void {
  stateUsage.mask |= P.S_FORM_STATES;
}

/** One rule as CSSOM shows it; the style engine reads the SheetRule behind it. */
export class CSSRule {
  get [Symbol.toStringTag](): string { return "CSSRule"; }
  cssText: string;
  selectorText: string;
  parentStyleSheet: CSSStyleSheet | null = null;
  /** The parsed rule this facade shows, which the cascade matches against. */
  rule: SheetRule | null = null;
  /** Where the rule sits in its sheet's text. */
  pos = 0;
  private styleDecl: CSSRuleDeclaration | null = null;

  constructor(cssText: string, selectorText: string) {
    this.cssText = cssText;
    this.selectorText = selectorText;
  }

  /** STYLE_RULE: the kind a selector rule is. */
  get type(): number {
    return 1;
  }

  /** The rule's declarations, which a script reads and rewrites as the style object. */
  get style(): CSSRuleDeclaration {
    if (this.styleDecl === null) this.styleDecl = new CSSRuleDeclaration(this);
    return this.styleDecl;
  }
}

/** A compiled <style> a script edits stops being compiled: its rules join the cascade as runtime
 *  rules, since the build's tables hold the old text. The style engine is told, so the compiled
 *  copies of the sheet's rules stand down (a rule deleted through the CSSOM must stop applying). */
let sheetLiveSink: ((owner: any) => void) | null = null;

/** The style engine's hook: it knows which <style> node hosts which sheet of compiled rules. */
/**
 * True once a script has written a style rule that can see past one element's subtree: a `:has()`
 * condition or a sibling combinator (`+`, `~`). The style engine's subtree restyle asks this; a
 * sheet of plain class rules — what a component library injects — leaves it false, and a change
 * stays inside the subtree it touched.
 */
let runtimeRulesWritten = false;

/**
 * True once a script has written any rule at all. A chained rule from a runtime sheet can match a
 * descendant through an ancestor's class, and the compiled tables the style engine indexes don't
 * hold it, so a page with one keeps the full subtree pass.
 */
let runtimeRulesExistFlag = false;

/** True when one of `rules` holds a selector that reaches past a single element's subtree. */
function rulesReachBeyond(rules: readonly SheetRule[]): boolean {
  for (const rule of rules) {
    for (const sel of rule.selectors) {
      if (sel.has.length > 0) return true;
      for (const link of sel.chain) if (link.comb === COMB_ADJACENT || link.comb === COMB_GENERAL) return true;
    }
  }
  return false;
}

export function runtimeRulesReachBeyond(): boolean {
  return runtimeRulesWritten;
}

/** True once a script has written any style rule: its selectors aren't in the compiled tables. */
export function runtimeRulesExist(): boolean {
  return runtimeRulesExistFlag;
}

export function setSheetLiveSink(fn: (owner: any) => void): void {
  sheetLiveSink = fn;
}

/** Rules that now cascade at runtime, which the style engine's indexes don't hold. */
function noteRuntimeRules(rules: readonly SheetRule[]): void {
  if (rules.length > 0) runtimeRulesExistFlag = true;
  if (rulesReachBeyond(rules)) runtimeRulesWritten = true;
}

function makeLive(sheet: CSSStyleSheet): void {
  const owner = sheet.ownerNode;
  if (owner !== null && owner !== undefined && owner.compiledSheet === true) {
    owner.compiledSheet = false;
    // The compiled tables held these rules until now; from here they cascade as runtime rules.
    noteRuntimeRules(sheet.styleRules);
    if (sheetLiveSink !== null) sheetLiveSink(owner);
  }
}

/** A compiled sheet's rules join the cascade or leave it (`disabled`); -1 says nothing to do. */
let compiledOffSink: ((sheet: number, off: boolean) => void) | null = null;

/** The style engine's hook for a compiled sheet's `disabled`: it holds the rules' table rows. */
export function setCompiledSheetOffSink(fn: (sheet: number, off: boolean) => void): void {
  compiledOffSink = fn;
}

/** A compiled sheet's media condition changed: its rules are tested against the new one. */
let compiledMediaSink: ((sheet: number, media: string) => void) | null = null;

/** The style engine's hook for a compiled sheet's media condition. */
export function setCompiledSheetMediaSink(fn: (sheet: number, media: string) => void): void {
  compiledMediaSink = fn;
}

/**
 * A <link rel=stylesheet> has no sheet object of its own — the build compiled its rules and the
 * CSS text is not in the page — so its element carries the sheet's index (NODE_SHEET) and the
 * setters below reach the compiled rules with that index.
 */

/** A sheet of the build, by index, leaves or joins the cascade: a <link>'s `disabled`. */
export function setCompiledSheetOffByIndex(sheet: number, off: boolean): void {
  if (compiledOffSink !== null) compiledOffSink(sheet, off);
}

/** A sheet of the build, by index, takes a new media condition: a <link>'s `media`. */
export function setCompiledSheetMediaByIndex(sheet: number, media: string): void {
  if (compiledMediaSink !== null) compiledMediaSink(sheet, media);
}

/**
 * A style rule's declaration block, as CSSRule.style shows it. Reading a property gives the text
 * the rule wrote; setting one rewrites the block and recompiles the rule, so the edit shows the
 * next time styles are computed. The setters every camelCase property shares go through
 * setProperty, which takes any property name.
 */
export class CSSRuleDeclaration {
  private facade: CSSRule;
  constructor(facade: CSSRule) {
    this.facade = facade;
  }

  /** The rule's declaration block, as its text has it. */
  private body(): string {
    const rule = this.facade.rule;
    if (rule === null) return "";
    const i = rule.cssText.indexOf("{");
    const j = rule.cssText.lastIndexOf("}");
    return i >= 0 && j > i ? rule.cssText.slice(i + 1, j) : "";
  }

  /** The block's declarations: name, value text, and whether one is important. */
  private entries(): { name: string; value: string; important: boolean }[] {
    const out: { name: string; value: string; important: boolean }[] = [];
    for (const d of parseDeclarationBlock(this.body(), undefined, undefined, undefined)) {
      if (d.prop === "") continue;
      out.push({ name: d.prop, value: d.value, important: d.important });
    }
    return out;
  }

  get length(): number {
    return this.entries().length;
  }
  item(index: number): string {
    const list = this.entries();
    return index >= 0 && index < list.length ? list[index].name : "";
  }
  getPropertyValue(name: string): string {
    const prop = name.trim().toLowerCase();
    for (const e of this.entries()) if (e.name === prop) return e.value;
    return "";
  }
  getPropertyPriority(name: string): string {
    const prop = name.trim().toLowerCase();
    for (const e of this.entries()) if (e.name === prop && e.important) return "important";
    return "";
  }

  setProperty(name: string, value: string, priority?: string): void {
    const prop = name.trim().toLowerCase();
    const text = value.trim();
    const important = priority !== undefined && priority.trim().toLowerCase() === "important";
    const list: string[] = [];
    let replaced = false;
    for (const e of this.entries()) {
      if (e.name === prop) {
        // The first mention is where the new value goes; later duplicates go away.
        if (!replaced && text !== "") {
          list.push(prop + ": " + text + (important ? " !important" : ""));
          replaced = true;
        }
        continue;
      }
      list.push(e.name + ": " + e.value + (e.important ? " !important" : ""));
    }
    if (!replaced && text !== "") list.push(prop + ": " + text + (important ? " !important" : ""));
    this.setBody(list.join("; "));
  }

  removeProperty(name: string): string {
    const old = this.getPropertyValue(name);
    this.setProperty(name, "");
    return old;
  }

  get cssText(): string {
    return this.body().trim();
  }
  set cssText(value: string) {
    this.setBody(String(value));
  }

  /** Recompiles the rule from its selector and a new declaration block, and lets the edit show. */
  private setBody(body: string): void {
    const facade = this.facade;
    const rule = facade.rule;
    const sheet = facade.parentStyleSheet;
    if (rule === null || sheet === null) return;
    const parsed = parseRulesText(rule.selectorText + " { " + body + " }", rule.media);
    if (parsed.rules.length === 1) {
      rule.decls = parsed.rules[0].decls;
      rule.cssText = parsed.rules[0].cssText;
      facade.cssText = rule.cssText;
    } else if (parsed.rules.length === 0) {
      // A block that declares nothing any more still stands as a rule — the parser drops one
      // with no declarations — so the property it just lost takes effect.
      rule.decls = [];
      rule.cssText = rule.selectorText + " { }";
      facade.cssText = rule.cssText;
    } else {
      return;
    }
    makeLive(sheet);
    noteSheetStates();
    invalidateStyle();
  }

  get backgroundColor(): string { return this.getPropertyValue("background-color"); }
  set backgroundColor(value: string) { this.setProperty("background-color", value); }
  get color(): string { return this.getPropertyValue("color"); }
  set color(value: string) { this.setProperty("color", value); }
  get display(): string { return this.getPropertyValue("display"); }
  set display(value: string) { this.setProperty("display", value); }
  get visibility(): string { return this.getPropertyValue("visibility"); }
  set visibility(value: string) { this.setProperty("visibility", value); }
  get opacity(): string { return this.getPropertyValue("opacity"); }
  set opacity(value: string) { this.setProperty("opacity", value); }
  get content(): string { return this.getPropertyValue("content"); }
  set content(value: string) { this.setProperty("content", value); }
  get fontSize(): string { return this.getPropertyValue("font-size"); }
  set fontSize(value: string) { this.setProperty("font-size", value); }
  get fontFamily(): string { return this.getPropertyValue("font-family"); }
  set fontFamily(value: string) { this.setProperty("font-family", value); }
  get fontWeight(): string { return this.getPropertyValue("font-weight"); }
  set fontWeight(value: string) { this.setProperty("font-weight", value); }
  get fontStyle(): string { return this.getPropertyValue("font-style"); }
  set fontStyle(value: string) { this.setProperty("font-style", value); }
  get lineHeight(): string { return this.getPropertyValue("line-height"); }
  set lineHeight(value: string) { this.setProperty("line-height", value); }
  get letterSpacing(): string { return this.getPropertyValue("letter-spacing"); }
  set letterSpacing(value: string) { this.setProperty("letter-spacing", value); }
  get textAlign(): string { return this.getPropertyValue("text-align"); }
  set textAlign(value: string) { this.setProperty("text-align", value); }
  get textDecoration(): string { return this.getPropertyValue("text-decoration"); }
  set textDecoration(value: string) { this.setProperty("text-decoration", value); }
  get textTransform(): string { return this.getPropertyValue("text-transform"); }
  set textTransform(value: string) { this.setProperty("text-transform", value); }
  get whiteSpace(): string { return this.getPropertyValue("white-space"); }
  set whiteSpace(value: string) { this.setProperty("white-space", value); }
  get width(): string { return this.getPropertyValue("width"); }
  set width(value: string) { this.setProperty("width", value); }
  get height(): string { return this.getPropertyValue("height"); }
  set height(value: string) { this.setProperty("height", value); }
  get margin(): string { return this.getPropertyValue("margin"); }
  set margin(value: string) { this.setProperty("margin", value); }
  get padding(): string { return this.getPropertyValue("padding"); }
  set padding(value: string) { this.setProperty("padding", value); }
  get border(): string { return this.getPropertyValue("border"); }
  set border(value: string) { this.setProperty("border", value); }
  get top(): string { return this.getPropertyValue("top"); }
  set top(value: string) { this.setProperty("top", value); }
  get left(): string { return this.getPropertyValue("left"); }
  set left(value: string) { this.setProperty("left", value); }
  get right(): string { return this.getPropertyValue("right"); }
  set right(value: string) { this.setProperty("right", value); }
  get bottom(): string { return this.getPropertyValue("bottom"); }
  set bottom(value: string) { this.setProperty("bottom", value); }
  get position(): string { return this.getPropertyValue("position"); }
  set position(value: string) { this.setProperty("position", value); }
  get transform(): string { return this.getPropertyValue("transform"); }
  set transform(value: string) { this.setProperty("transform", value); }
  get cursor(): string { return this.getPropertyValue("cursor"); }
  set cursor(value: string) { this.setProperty("cursor", value); }
  get overflow(): string { return this.getPropertyValue("overflow"); }
  set overflow(value: string) { this.setProperty("overflow", value); }
  get zIndex(): string { return this.getPropertyValue("z-index"); }
  set zIndex(value: string) { this.setProperty("z-index", value); }
  get boxShadow(): string { return this.getPropertyValue("box-shadow"); }
  set boxShadow(value: string) { this.setProperty("box-shadow", value); }
  get fill(): string { return this.getPropertyValue("fill"); }
  set fill(value: string) { this.setProperty("fill", value); }
  get stroke(): string { return this.getPropertyValue("stroke"); }
  set stroke(value: string) { this.setProperty("stroke", value); }
}

/** The rule's place in its sheet's text, for keeping the CSSOM list in text order. */
function posOf(f: Facade): number {
  return f instanceof CSSCounterStyleRule ? f.rule.pos : f.pos;
}

/**
 * An @counter-style rule a script reads and rewrites (CSS Counter Styles 3 §9.2). Each
 * descriptor is the text the rule wrote; setting one re-parses the whole rule and, when the result
 * still defines a style, hands it to the engine under the same name.
 */
export class CSSCounterStyleRule {
  get [Symbol.toStringTag](): string { return "CSSCounterStyleRule"; }
  rule: CounterRule;
  parentStyleSheet: CSSStyleSheet | null = null;
  /** A counter style has no selector, but every rule facade a sheet hands out answers one, so
   *  app code that reads a sheet's rules doesn't have to narrow the type first. */
  readonly selectorText: string = "";

  constructor(rule: CounterRule) {
    this.rule = rule;
  }

  /** COUNTER_STYLE_RULE. */
  get type(): number {
    return 11;
  }

  get cssText(): string {
    const body = this.rule.descriptors.map((d) => d.prop + ": " + d.text).join("; ");
    return "@counter-style " + this.rule.name + " { " + body + (body === "" ? "" : "; ") + " }";
  }

  set cssText(value: string) {
    const text = String(value).trim();
    const m = /^@counter-style\s+([-_a-zA-Z\u0080-\uffff][-_a-zA-Z0-9\u0080-\uffff]*)\s*\{([\s\S]*)\}\s*$/.exec(text);
    if (m === null) return;
    const seen: { prop: string; text: string }[] = [];
    const style = parseCounterStyle(m[1], m[2], undefined, seen);
    if (typeof style === "string") return;
    this.rule.name = m[1];
    this.rule.descriptors = seen;
    this.changed();
  }

  get name(): string {
    return this.rule.name;
  }

  set name(value: string) {
    const text = String(value).trim();
    if (!/^[-_a-zA-Z\u0080-\uffff][-_a-zA-Z0-9\u0080-\uffff]*$/.test(text) ||
      CSS_WIDE_NAMES.indexOf(text.toLowerCase()) >= 0) return;
    this.rule.name = text;
    this.changed();
  }

  private textOf(prop: string, initial: string): string {
    for (const d of this.rule.descriptors) if (d.prop === prop) return d.text;
    return initial;
  }

  private put(prop: string, value: string): void {
    const text = String(value).trim();
    const next = this.rule.descriptors.filter((d) => d.prop !== prop);
    if (text !== "") next.push({ prop, text });
    const body = next.map((d) => d.prop + ": " + d.text).join("; ");
    const seen: { prop: string; text: string }[] = [];
    const style = parseCounterStyle(this.rule.name, body, undefined, seen);
    // An invalid value leaves the descriptor as it was, as a browser's setters do.
    if (typeof style === "string") return;
    this.rule.descriptors = seen;
    this.changed();
  }

  private changed(): void {
    if (this.parentStyleSheet !== null) {
      this.parentStyleSheet.syncCounterStyles();
      invalidateStyle();
    }
  }

  get system(): string { return this.textOf("system", "symbolic"); }
  set system(v: string) { this.put("system", v); }
  get symbols(): string { return this.textOf("symbols", ""); }
  set symbols(v: string) { this.put("symbols", v); }
  get additiveSymbols(): string { return this.textOf("additive-symbols", ""); }
  set additiveSymbols(v: string) { this.put("additive-symbols", v); }
  get negative(): string { return this.textOf("negative", "-"); }
  set negative(v: string) { this.put("negative", v); }
  get prefix(): string { return this.textOf("prefix", ""); }
  set prefix(v: string) { this.put("prefix", v); }
  get suffix(): string { return this.textOf("suffix", ". "); }
  set suffix(v: string) { this.put("suffix", v); }
  get pad(): string { return this.textOf("pad", "0 \"\""); }
  set pad(v: string) { this.put("pad", v); }
  get range(): string { return this.textOf("range", "auto"); }
  set range(v: string) { this.put("range", v); }
  get fallback(): string { return this.textOf("fallback", "decimal"); }
  set fallback(v: string) { this.put("fallback", v); }
  get speakAs(): string { return this.textOf("speak-as", "auto"); }
  set speakAs(v: string) { this.put("speak-as", v); }
}

const CSS_WIDE_NAMES = ["initial", "inherit", "unset", "revert", "revert-layer", "default", "none"];

/**
 * The media query list of a sheet — CSSOM's MediaList. A `<style media>` or `<link media>`
 * attribute fills it, and a script rewrites it through mediaText, appendMedium or deleteMedium;
 * every change re-runs the cascade, since a condition that starts holding switches rules on.
 */
export class MediaList {
  get [Symbol.toStringTag](): string { return "MediaList"; }
  /** The queries in list order, each as written. */
  items: string[] = [];
  /** The sheet whose rules the list gates, or null for a list no sheet owns. */
  sheet: CSSStyleSheet | null = null;
  /** The @media block whose rules the list gates, for a list a block owns. */
  rule: CSSMediaRule | null = null;

  /** The list as one string, serialized as CSSOM does: queries joined by ", ", "" when empty. */
  get mediaText(): string {
    return serializeMediaList(this.items);
  }
  set mediaText(value: string) {
    this.setFromText(String(value));
  }

  get length(): number {
    return this.items.length;
  }

  item(index: number): string | null {
    const i = Math.floor(index);
    return i >= 0 && i < this.items.length ? this.items[i] : null;
  }

  /** Adds one medium; a comma-separated list is not one medium, and a repeat adds nothing. */
  appendMedium(medium: string): void {
    const q = oneMediaQuery(String(medium));
    if (q === null || this.indexOf(q) >= 0) return;
    this.items.push(q);
    this.changed();
  }

  /** Removes every query equal to `medium`; one that matches nothing is an error, as CSSOM says. */
  deleteMedium(medium: string): void {
    const q = oneMediaQuery(String(medium));
    const key = q === null ? "" : mediaKey(q);
    const left = this.items.filter((x) => mediaKey(x) !== key);
    if (key === "" || left.length === this.items.length) {
      throw new Error("NotFoundError: the media list has no such query");
    }
    this.items = left;
    this.changed();
  }

  toString(): string {
    return this.mediaText;
  }

  /** Replaces the list from a comma-separated string, as a media attribute holds one. */
  setFromText(text: string): void {
    this.items = splitMediaQueries(text);
    this.changed();
  }

  /** Where `q` sits in the list, comparing parsed queries rather than their spellings. */
  indexOf(q: string): number {
    const key = mediaKey(q);
    for (let i = 0; i < this.items.length; i++) if (mediaKey(this.items[i]) === key) return i;
    return -1;
  }

  changed(): void {
    if (this.sheet !== null) this.sheet.mediaChanged();
    else if (this.rule !== null) this.rule.mediaChanged();
    else invalidateStyle();
  }
}

/** Splits a media query list at its top-level commas, dropping empty entries. */
export function splitMediaQueries(text: string): string[] {
  const out: string[] = [];
  for (const part of splitTopLevel(text, ",")) {
    const q = part.trim();
    if (q !== "") out.push(q);
  }
  return out;
}

/** One media query from `medium`, or null when it is a list or is empty (appendMedium refuses). */
function oneMediaQuery(medium: string): string | null {
  const list = splitMediaQueries(medium);
  return list.length === 1 ? list[0] : null;
}

/** One media query as CSSOM serializes it: the type and feature names lowercased, and an `all`
 *  that a feature follows is left out ("all and (color)" is "(color)"). */
function serializeMediaQuery(q: string): string {
  let t = q.trim().replace(/\s+/g, " ");
  t = t.replace(/^([A-Za-z]+)/, (m) => m.toLowerCase());
  t = t.replace(/\(\s*([A-Za-z-]+)\s*:/g, (m, name) => "(" + name.toLowerCase() + ":");
  t = t.replace(/\(\s*([A-Za-z-]+)\s*\)/g, (m, name) => "(" + name.toLowerCase() + ")");
  if (t.indexOf("all and ") === 0) t = t.slice("all and ".length);
  return t;
}

/** A media query list as CSSOM serializes it: the queries in list order, joined by ", ". */
export function serializeMediaList(items: string[]): string {
  const out: string[] = [];
  for (const q of items) out.push(serializeMediaQuery(q));
  return out.join(", ");
}

/** A media query reduced to what it means, so two spellings of one query compare equal. */
function mediaKey(q: string): string {
  return q
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ")
    .replace(/\s*:\s*/g, ":")
    .replace(/\(\s*/g, "(")
    .replace(/\s*\)/g, ")");
}

/** The CSSOM facade of one parsed selector rule. */
function styleFacade(r: SheetRule, sheet: CSSStyleSheet | null): CSSRule {
  const facade = new CSSRule(r.cssText, r.selectorText);
  facade.rule = r;
  facade.parentStyleSheet = sheet;
  facade.pos = r.pos;
  return facade;
}

/** The condition and the body of an `@media` block's text, or null when the text is not one. */
function parseMediaBlock(text: string): { media: string; body: string } | null {
  const open = findOpen(text, 0);
  if (open >= text.length) return null;
  const close = findClose(text, open);
  if (close >= text.length || text.slice(close + 1).trim() !== "") return null;
  return { media: text.slice("@media".length, open).trim(), body: text.slice(open + 1, close) };
}

/**
 * An `@media` block a script inserted (CSSOM's CSSMediaRule, type 4): the rules inside it apply
 * while its condition holds. Its rules sit in the sheet's cascade list as one run, in the place
 * the block was inserted, so the cascade order is the CSSOM's order.
 */
export class CSSMediaRule {
  get [Symbol.toStringTag](): string { return "CSSMediaRule"; }
  /** The condition the block is gated on. */
  media: MediaList = new MediaList();
  /** The rules inside the block, in order. */
  cssRules: Facade[] = [];
  parentStyleSheet: CSSStyleSheet | null = null;
  /** The text the block was written with, so a changed condition parses it again. */
  body = "";
  /** The parsed rules the facades show. */
  rules: SheetRule[] = [];
  /** Where the block sits among the sheet's rules, for the CSSOM's order. */
  pos = 0;

  constructor() {
    this.media.rule = this;
  }

  /** CSSRule.MEDIA_RULE. */
  get type(): number {
    return 4;
  }

  /** CSSOM's `conditionText` is read-only; the list it shows is rewritten through `media`. */
  get conditionText(): string {
    return this.media.mediaText;
  }

  /** The block as CSSOM serializes it: the condition, then its rules two spaces in, one per line. */
  get cssText(): string {
    const inner: string[] = [];
    for (const f of this.cssRules) inner.push("  " + f.cssText);
    return "@media " + this.media.mediaText + " {\n" + inner.join("\n") + (inner.length > 0 ? "\n" : "") + "}";
  }

  insertRule(rule: string, index: number = 0): number {
    const at = Math.floor(index);
    if (at < 0 || at > this.cssRules.length) {
      throw new Error("IndexSizeError: rule index " + at + " is out of range");
    }
    const parsed = parseRulesText(String(rule), this.media.mediaText);
    if (parsed.rules.length !== 1) throw new Error("SyntaxError: insertRule() takes exactly one rule");
    const rule0 = parsed.rules[0];
    this.rules.splice(at, 0, rule0);
    this.cssRules.splice(at, 0, styleFacade(rule0, this.parentStyleSheet));
    this.noteChange();
    return at;
  }

  deleteRule(index: number): void {
    const at = Math.floor(index);
    if (at < 0 || at >= this.cssRules.length) {
      throw new Error("IndexSizeError: rule index " + at + " is out of range");
    }
    this.rules.splice(at, 1);
    this.cssRules.splice(at, 1);
    this.noteChange();
  }

  /** The condition changed: the rules inside are parsed again inside the new one. */
  mediaChanged(): void {
    const parsed = parseRulesText(this.body, this.media.mediaText);
    this.rules = parsed.rules;
    const facades: Facade[] = [];
    for (const r of parsed.rules) facades.push(styleFacade(r, this.parentStyleSheet));
    this.cssRules = facades;
    this.noteChange();
  }

  /** Hands the block's current rules to the sheet's cascade list and lets the change show. */
  noteChange(): void {
    if (this.parentStyleSheet !== null) this.parentStyleSheet.rebuildRules();
    invalidateStyle();
  }
}

/**
 * A sheet a script builds: new CSSStyleSheet() filled with replaceSync()/insertRule(), or the
 * sheet behind a <style> element. Its rules are compiled the first time its text changes.
 */
export class CSSStyleSheet {
  get [Symbol.toStringTag](): string { return "CSSStyleSheet"; }
  /** The selector rules the cascade matches, in text order. */
  styleRules: SheetRule[] = [];
  counters: CounterRule[] = [];
  cssRules: Facade[] = [];
  /** The counter style names this sheet put in the engine, so a rewrite can take them back. */
  counterNames: string[] = [];
  /** The <style> or <link> element the sheet came from, or null for a sheet a script built.
   *  Typed, not `any`: an `any`-typed field stops scriptc lowering this class, and every
   *  page whose script touches document.styleSheets then fails to build. */
  ownerNode: Element | null = null;
  /** The shadow root this sheet was written in, or null for the document's own sheets. */
  scopeRoot: ShadowRoot | null = null;
  parentStyleSheet: CSSStyleSheet | null = null;
  /**
   * The sheet the build compiled from this element's text, by its index in the build's sheet
   * list; -1 for a sheet a script built. Those rules are already in the page's tables, so
   * `disabled` reaches them through the style engine rather than through `styleRules` here.
   */
  compiled = -1;
  /** The sheet's media query list: a media attribute, or what a script made of it (CSSOM). */
  media: MediaList = new MediaList();
  /** The media condition the current runtime rules were parsed with, so a change re-parses them. */
  sourceMedia = "";
  /**
   * The flag behind `disabled`. The style engine reads this directly — it runs per sheet on
   * every style pass, and an accessor read is a call — while CSSOM callers get the pair below.
   */
  disabledFlag = false;
  /**
   * Whether the sheet's rules take no part in the cascade (CSSOM `disabled`). A <style> the
   * build compiled has its rules in the page's tables, so the style engine is told instead: the
   * sheet's rows stand down, and `applyRules` and friends skip them (see style.ts).
   */
  get disabled(): boolean {
    return this.disabledFlag;
  }
  set disabled(value: boolean) {
    const off = Boolean(value);
    if (off === this.disabledFlag) return;
    this.disabledFlag = off;
    if (this.compiled >= 0 && compiledOffSink !== null) compiledOffSink(this.compiled, off);
    invalidateStyle();
  }
  /** The text the current rules came from, so a <style> is parsed again only when it changes. */
  source = "";

  constructor() {
    this.media.sheet = this;
  }

  /**
   * The media list changed. The rules are parsed again with the new condition — a runtime sheet's
   * rules carry it directly — and a sheet the build compiled tells the style engine, which tests
   * the condition for that sheet's rows.
   */
  mediaChanged(): void {
    this.sourceMedia = this.media.mediaText;
    if (this.compiled >= 0 && compiledMediaSink !== null) compiledMediaSink(this.compiled, this.sourceMedia);
    this.setSource(this.source, this.sourceMedia);
    invalidateStyle();
  }

  /** `rules` is the CSSOM's older name for `cssRules`. */
  get rules(): Facade[] {
    return this.cssRules;
  }

  get type(): string {
    return "text/css";
  }

  replaceSync(text: string): void {
    this.setSource(String(text), this.media.mediaText);
    makeLive(this);
  }

  async replace(text: string): Promise<CSSStyleSheet> {
    this.setSource(String(text), this.media.mediaText);
    makeLive(this);
    return this;
  }

  insertRule(rule: string, index: number = 0): number {
    const at = Math.floor(index);
    if (at < 0 || at > this.cssRules.length) {
      throw new Error("IndexSizeError: rule index " + at + " is out of range");
    }
    const text = String(rule).trim();
    if (/^@media\b/i.test(text)) {
      // A whole @media block is one rule: the CSSOM shows it as a CSSMediaRule whose own rules
      // the block holds, and its rules join the cascade where the block was inserted.
      const block = parseMediaBlock(text);
      if (block === null) throw new Error("SyntaxError: insertRule() takes exactly one rule");
      const mediaRule = new CSSMediaRule();
      mediaRule.parentStyleSheet = this;
      mediaRule.body = block.body;
      mediaRule.media.items = splitMediaQueries(block.media);
      mediaRule.pos = at;
      const inner = parseRulesText(block.body, block.media);
      mediaRule.rules = inner.rules;
      const facades: Facade[] = [];
      for (const r of inner.rules) facades.push(styleFacade(r, this));
      mediaRule.cssRules = facades;
      this.cssRules.splice(at, 0, mediaRule);
      noteSheetStates();
      makeLive(this);
      this.rebuildRules();
      return at;
    }
    const parsed = parseRulesText(text, this.media.mediaText);
    if (parsed.rules.length + parsed.counters.length !== 1) {
      throw new Error("SyntaxError: insertRule() takes exactly one rule");
    }
    if (parsed.counters.length === 1) {
      const rule0 = parsed.counters[0];
      this.counters.push(rule0);
      const facade = new CSSCounterStyleRule(rule0);
      facade.parentStyleSheet = this;
      this.cssRules.splice(at, 0, facade);
    } else {
      const rule0 = parsed.rules[0];
      // Where the rule goes in the cascade list: every entry before it that holds style rules,
      // a block counting one per rule inside it, a @counter-style rule none.
      let si = 0;
      for (let k = 0; k < at; k++) {
        const f = this.cssRules[k];
        si += f instanceof CSSMediaRule ? f.rules.length : f instanceof CSSCounterStyleRule ? 0 : 1;
      }
      runtimeRulesExistFlag = true;
      if (rulesReachBeyond([rule0])) runtimeRulesWritten = true;
      this.styleRules.splice(si, 0, rule0);
      const facade = new CSSRule(rule0.cssText, rule0.selectorText);
      facade.rule = rule0;
      facade.pos = at;
      facade.parentStyleSheet = this;
      this.cssRules.splice(at, 0, facade);
    }
    this.syncCounterStyles();
    noteSheetStates();
    makeLive(this);
    invalidateStyle();
    return at;
  }

  deleteRule(index: number): void {
    const at = Math.floor(index);
    if (at < 0 || at >= this.cssRules.length) {
      throw new Error("IndexSizeError: rule index " + at + " is out of range");
    }
    const gone = this.cssRules[at];
    if (gone instanceof CSSMediaRule) {
      this.cssRules.splice(at, 1);
      this.rebuildRules();
      return;
    }
    if (gone instanceof CSSCounterStyleRule) {
      const i = this.counters.indexOf(gone.rule);
      if (i >= 0) this.counters.splice(i, 1);
    } else {
      const parsed = (gone as CSSRule).rule;
      if (parsed !== null) {
        const i = this.styleRules.indexOf(parsed);
        if (i >= 0) this.styleRules.splice(i, 1);
      }
    }
    this.cssRules.splice(at, 1);
    this.syncCounterStyles();
    noteSheetStates();
    makeLive(this);
    invalidateStyle();
  }

  /** Replaces every rule from a sheet's text, the rules inside the media condition `media`. */
  setSource(text: string, media: string = ""): void {
    const compiled = this.ownerNode !== null && this.ownerNode !== undefined && this.ownerNode.compiledSheet === true;
    this.source = text;
    this.sourceMedia = media;
    const parsed = parseRulesText(text, media);
    // A sheet the build compiled keeps its rules in the compiled tables, which the style engine
    // indexes; its text is parsed here only for the CSSOM, until a script makes it live.
    if (!compiled) noteRuntimeRules(parsed.rules);
    this.styleRules = parsed.rules;
    this.counters = parsed.counters;
    const facades: Facade[] = [];
    for (const r of parsed.rules) {
      const facade = new CSSRule(r.cssText, r.selectorText);
      facade.rule = r;
      facade.pos = r.pos;
      facade.parentStyleSheet = this;
      facades.push(facade);
    }
    for (const r of parsed.counters) {
      const facade = new CSSCounterStyleRule(r);
      facade.parentStyleSheet = this;
      facades.push(facade);
    }
    facades.sort((a, b) => posOf(a) - posOf(b));
    this.cssRules = facades;
    this.syncCounterStyles();
    if (compiled) return;
    noteSheetStates();
    invalidateStyle();
  }

  /**
   * Puts the cascade list back together from the CSSOM's rule list. A block's rules go where the
   * block sits, so a rule inserted at a CSSOM index lands in the cascade order that index names.
   */
  rebuildRules(): void {
    const flat: SheetRule[] = [];
    for (const f of this.cssRules) {
      if (f instanceof CSSMediaRule) {
        for (const r of f.rules) flat.push(r);
      } else if (f instanceof CSSCounterStyleRule) {
        continue;
      } else {
        const r = (f as CSSRule).rule;
        if (r !== null) flat.push(r);
      }
    }
    if (flat.length > 0) runtimeRulesExistFlag = true;
    if (rulesReachBeyond(flat)) runtimeRulesWritten = true;
    this.styleRules = flat;
    invalidateStyle();
  }

  /** Puts the sheet's current @counter-style rules in the engine, taking back ones it dropped. */
  syncCounterStyles(): void {
    for (const name of this.counterNames) if (dropCounterStyle !== null) dropCounterStyle(name);
    this.counterNames = [];
    for (const rule of this.counters) {
      const seen: { prop: string; text: string }[] = [];
      const body = rule.descriptors.map((d) => d.prop + ": " + d.text).join("; ");
      const style = parseCounterStyle(rule.name, body, undefined, seen);
      if (typeof style === "string") continue;
      const spec = decodeCounterStyle(encodeCounterStyle(style));
      if (spec !== null && addCounterStyle !== null) addCounterStyle(spec);
      this.counterNames.push(rule.name);
    }
  }
}

/** The sheets a page adopted; they apply after every <style> in the document. */
export const ADOPTED: CSSStyleSheet[] = [];

/** Drops the adopted sheets, for the next page of a run (the WPT runner reuses a process). */
export function clearAdopted(): void {
  ADOPTED.length = 0;
}

/** The contexts a sheet's declarations are compiled with, registered by the modules that own them. */
let fonts: FontContext | undefined = undefined;
let content: ContentContext | undefined = undefined;

export function setSheetFonts(f: FontContext): void {
  fonts = f;
}

export function setSheetContent(c: ContentContext): void {
  content = c;
}

/** The content context runtime values are compiled with (content items and counter lists). */
export function getSheetContent(): ContentContext | undefined {
  return content;
}

/** The font context runtime values are compiled with, for a var() declaration resolved there. */
export function getSheetFonts(): FontContext | undefined {
  return fonts;
}

/** The sheets behind <style> elements, one per element, kept across text changes. */
const OWNER_SHEETS = new WeakMap<any, CSSStyleSheet>();

/**
 * Parses a <style> element's text into its sheet, making the sheet the first time. An unchanged
 * text is left alone, so a frame that touches the element costs nothing.
 */
export function refreshSheet(owner: any): void {
  if (owner === null || owner === undefined || owner.nodeType !== 1 || owner.localName !== "style") return;
  let sheet = OWNER_SHEETS.get(owner);
  if (sheet === undefined) {
    sheet = new CSSStyleSheet();
    sheet.ownerNode = owner;
    // A <style> the build compiled carries the index of its sheet (NODE_SHEET), which is how a
    // script that disables the sheet takes its rules out of the cascade.
    sheet.compiled = typeof owner.sheetIndex === "number" ? owner.sheetIndex : -1;
    OWNER_SHEETS.set(owner, sheet);
    owner.sheet = sheet;
  }
  // A <style> inside a shadow tree styles that tree alone: the sheet records the root it sits in.
  let scope: any = null;
  for (let n: any = owner.parentNode; n !== null; n = n.parentNode) {
    if (n instanceof ShadowRoot) { scope = n; break; }
  }
  sheet.scopeRoot = scope;
  const text: string = owner.textContent;
  const media: string = owner.getAttribute("media") ?? "";
  if (media !== sheet.sourceMedia) sheet.media.items = splitMediaQueries(media);
  if (text !== sheet.source || media !== sheet.sourceMedia) sheet.setSource(text, media);
}

/** Finds the <style> elements in a subtree just added to the document and parses them. */
export function refreshSubtree(node: any): void {
  if (node === null || node === undefined || node.nodeType !== 1) return;
  if (node.localName === "style") refreshSheet(node);
  for (const c of node.kids) refreshSubtree(c);
}

/** A text node inside a <style> changed: the sheet behind it is out of date. */
export function refreshTextOwner(node: any): void {
  const p = node.parentNode;
  if (p !== null && p.nodeType === 1 && p.localName === "style") {
    // A script writing into a sheet the build compiled makes it a runtime sheet from now on.
    p.compiledSheet = false;
    refreshSheet(p);
  }
}

// ---------------------------------------------------------------------------
// Parsing a sheet's text
//
// The walk is the compiler's (compiler/css/parse.ts), minus its diagnostics: the runtime has no
// build to report to, and a browser drops what it can't parse one rule at a time.

/** Index of the first `{` at nesting depth zero, or src.length. */
function findOpen(src: string, from: number): number {
  let paren = 0;
  let bracket = 0;
  for (let j = from; j < src.length; j++) {
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
function findClose(src: string, open: number): number {
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

/** Index of the `;` ending an at-rule prelude, or -1 when a block starts first. */
function findSemicolon(src: string, from: number): number {
  let paren = 0;
  let bracket = 0;
  for (let j = from; j < src.length; j++) {
    const ch = src[j];
    if (ch === '"' || ch === "'") j = skipString(src, j) - 1;
    else if (ch === "(") paren++;
    else if (ch === ")") paren = Math.max(0, paren - 1);
    else if (ch === "[") bracket++;
    else if (ch === "]") bracket = Math.max(0, bracket - 1);
    else if (ch === "{" && paren === 0 && bracket === 0) return -1;
    else if (ch === ";" && paren === 0 && bracket === 0) return j;
  }
  return src.length;
}

/** A media query as the style engine's evaluator reads it: lower case, single spaces. */
function queryText(query: string): string {
  return query.trim().toLowerCase().replace(/\s+/g, " ");
}

/** Parses a sheet, or the text insertRule() was given, into rules. */
export function parseRulesText(src: string, media: string): { rules: SheetRule[]; counters: CounterRule[] } {
  // Comments are blanked out, keeping offsets and newlines, as the compiler does.
  src = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  // XHTML viewers wrap sheets in CDATA sections, which the XML parser removes before CSS sees it.
  src = src.replace(/<!\[CDATA\[/g, (m) => " ".repeat(m.length)).replace(/\]\]>/g, (m) => " ".repeat(m.length));
  const rules: SheetRule[] = [];
  const counters: CounterRule[] = [];
  parseBlock(src, media, "", rules, counters);
  return { rules, counters };
}

/** Registers one `@keyframes` rule a runtime sheet holds, as rows the animation engine steps. */
function registerKeyframes(name: string, body: string): void {
  const id = animNames.register(name);
  let registered = 0;
  let i = 0;
  while (i < body.length) {
    const open = findOpen(body, i);
    if (open >= body.length) break;
    const close = findClose(body, open);
    const prelude = body.slice(i, open).trim().toLowerCase();
    const declBody = body.slice(open + 1, close);
    i = close + 1;
    if (prelude === "") continue;
    const row: number[] = [];
    for (const d of parseDeclarationBlock(declBody, fonts, undefined, content)) {
      for (const x of d.decls) {
        if (x.prop !== undefined) {
          // A CSS-wide keyword: the frame carries it and the engine resolves it against the
          // element when it applies the frame (see U_WIDE).
          const ids = longhandIds(x.prop);
          if (ids === null) continue;
          const code = wideCode(x.value === undefined ? "" : x.value);
          for (const p of ids) row.push(p, code, P.U_WIDE);
          continue;
        }
        row.push(x.p, x.v, x.u);
      }
    }
    if (row.length === 0) continue;
    for (const token of splitTopLevel(prelude, ",")) {
      const text = token.trim();
      let offset = -1;
      if (text === "from") offset = 0;
      else if (text === "to") offset = 1;
      else if (text.endsWith("%")) {
        const n = Number(text.slice(0, -1));
        if (Number.isFinite(n)) offset = n / 100;
      }
      if (offset < 0) continue;
      const outRow: number[] = [id, offset];
      for (const n of row) outRow.push(n);
      animKeyframes.register(outRow);
      registered++;
    }
  }
  // A @keyframes whose blocks name nothing still defines an animation: it exists and moves
  // nothing, which is what an empty rule says.
  if (registered === 0) animKeyframes.register([id, -1]);
  invalidateStyle();
}

function parseBlock(src: string, media: string, container: string, out: SheetRule[],
  counters: CounterRule[], layer: number = -1): void {
  let i = 0;
  while (i < src.length) {
    while (i < src.length && /\s/.test(src[i])) i++;
    if (i >= src.length) break;
    // Stray `}` and `;`, and the CDO/CDC pair old style sheets leave from HTML comments.
    if (src[i] === "}" || src[i] === ";") {
      i++;
      continue;
    }
    if (src.startsWith("<!--", i)) {
      i += 4;
      continue;
    }
    if (src.startsWith("-->", i)) {
      i += 3;
      continue;
    }
    if (src[i] === "@") {
      const m = /^@([\w-]+)/.exec(src.slice(i));
      const name = m === null ? "" : m[1].toLowerCase();
      const open = findOpen(src, i);
      const semi = findSemicolon(src, i);
      if (name === "media" && open < src.length) {
        const close = findClose(src, open);
        const query = queryText(m === null ? "" : src.slice(i + m[0].length, open));
        parseBlock(src.slice(open + 1, close), media === "" ? query : media + " and " + query, container, out, counters, layer);
        i = close + 1;
        continue;
      }
      if (name === "layer") {
        // `@layer name { … }` puts its rules in that layer (nested names allowed), and a bare
        // `@layer { … }` opens an anonymous one; `@layer a, b;` only fixes the order.
        const before = m === null ? "" : src.slice(i + m[0].length, open < src.length && (semi < 0 || open < semi) ? open : (semi < 0 ? src.length : semi));
        const prelude = before.trim();
        if (open < src.length && (semi < 0 || open < semi)) {
          const close = findClose(src, open);
          const inner = prelude === "" ? runtimeLayers.anonymous(layer) : runtimeLayers.declare(layer, prelude);
          runtimeLayerOrder = null;
          parseBlock(src.slice(open + 1, close), media, container, out, counters, inner);
          i = close + 1;
          continue;
        }
        if (semi >= 0) {
          for (const part of prelude.split(",")) {
            const nm = part.trim();
            if (nm !== "") runtimeLayers.declare(layer, nm);
          }
          runtimeLayerOrder = null;
          i = semi + 1;
          continue;
        }
      }
      if (name === "container" && open < src.length) {
        const close = findClose(src, open);
        // The build reads a condition's spacing the same way, and a container query can't nest
        // inside another one, so there is nowhere for a nested condition to go.
        const query = (m === null ? "" : src.slice(i + m[0].length, open)).trim().replace(/\s+/g, " ");
        if (container === "") parseBlock(src.slice(open + 1, close), media, query, out, counters, layer);
        i = close + 1;
        continue;
      }
      if (name === "counter-style" && open < src.length) {
        const close = findClose(src, open);
        const after = src.slice(i + m![0].length, open).trim();
        const body = src.slice(open + 1, close);
        if (/^[-_a-zA-Z\u0080-\uffff][-_a-zA-Z0-9\u0080-\uffff]*$/.test(after)) {
          const seen: { prop: string; text: string }[] = [];
          const parsed = parseCounterStyle(after, body, undefined, seen);
          // A rule that doesn't define a style isn't in the CSSOM at all.
          if (typeof parsed !== "string") counters.push({ name: after, descriptors: seen, pos: i });
        }
        i = close + 1;
        continue;
      }
      if (name === "keyframes" || name === "-webkit-keyframes") {
        // A @keyframes a script adds registers its blocks, so an animation-name that names it
        // starts one: the same tables the build fills. A later rule of the same name doesn't
        // replace the blocks of an earlier one; the stylesheet's animation wins over the runtime's.
        if (open < src.length) {
          const close = findClose(src, open);
          const raw = src.slice(i + (m === null ? 1 : m[0].length), open).trim();
          const kfName = raw.length >= 2 && (raw[0] === '"' || raw[0] === "'") && raw[raw.length - 1] === raw[0]
            ? raw.slice(1, -1) : raw;
          if (kfName !== "") registerKeyframes(kfName, src.slice(open + 1, close));
          i = close + 1;
          continue;
        }
      }
      // Other at-rules are skipped: the runtime has no imports or font faces.
      if (semi < 0 || open < semi) i = findClose(src, open) + 1;
      else i = semi === src.length ? src.length : semi + 1;
      continue;
    }
    const open = findOpen(src, i);
    if (open >= src.length) break;
    const close = findClose(src, open);
    const selectorText = src.slice(i, open).trim();
    const body = src.slice(open + 1, close);
    i = close + 1;
    const selectors: Selector[] = [];
    for (const raw of splitTopLevel(selectorText, ",")) {
      // :host and ::slotted are shadow tree syntax; a sheet outside one keeps them as rules that
      // never match (the matcher checks the sheet's scope).
      const parsed = parseSelector(raw.trim(), false, true);
      if (parsed !== null) for (const s of parsed) selectors.push(s);
    }
    if (selectors.length === 0) continue;
    const decls: Decl[] = [];
    for (const d of parseDeclarationBlock(body, fonts, undefined, content)) {
      for (const x of d.decls) decls.push(x);
    }
    if (decls.length === 0) continue;
    out.push({ selectors, decls, media, container, selectorText, cssText: selectorText + " { " + body.trim() + " }", pos: i, layer });
  }
}
