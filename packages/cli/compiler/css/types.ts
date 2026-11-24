// Selector types and constants, used only by the compiler.

import type { Decl, Selector } from "../../shared/css/types.ts";
export type { Decl, FontContext, ContentContext } from "../../shared/css/types.ts";
export { GENERIC_FAMILIES } from "../../shared/css/types.ts";

// The selector types and combinator constants are shared with the runtime, which matches the
// selectors of runtime style sheets (see shared/css/selectors.ts).
export { COMB_DESCENDANT, COMB_CHILD, COMB_ADJACENT, COMB_GENERAL } from "../../shared/css/types.ts";
export type { ChainLink, Compound, Selector } from "../../shared/css/types.ts";

/**
 * What the compiler does with @keyframes: a rule starts a fresh set of blocks for its name
 * (a later @keyframes of the same name replaces the earlier one), and each block adds the
 * declarations at one offset, where 0 is `from` and 1 is `to`.
 */
/** Where `@counter-style` rules go: each is compiled to the string the runtime reads back. */
export interface CounterStyleContext {
  style(encoded: string): void;
  /** The index a style name is known by, for a list-style-type or counter() that names it. */
  name(name: string): number;
}

export interface KeyframesContext {
  rule(name: string): void;
  block(name: string, offset: number, decls: Decl[]): void;
}

export interface CssRule {
  selectors: Selector[];
  decls: Decl[];
  order: number;
  origin: "ua" | "author" | "inline";
  file: string;
  line: number;
  col: number;
  /** The @media condition the rule is inside, or "" for a rule outside any. */
  media: string;
  /** The cascade layer the rule is inside (an id in the sheet's LayerRegistry), or -1 unlayered. */
  layer: number;
  /** The @container condition the rule is inside (`name (width > 400px)`), or "" for none. */
  container: string;
  /** The @scope prelude the rule is inside (`(.card) to (.card .inner)`), or "" for none. */
  scope: string;
  /** True for a rule inside @starting-style: it styles an element's first rendered state. */
  starting: boolean;
}

/** A custom property registered by an `@property` rule (CSS Properties and Values 1, §2). */
export interface PropertyRule {
  name: string;
  /** The syntax descriptor: `*`, or a `|`-separated list of types and keywords. */
  syntax: string;
  inherits: boolean;
  /** The initial value, or null when the rule gives none (only the `*` syntax may). */
  initialValue: string | null;
}
