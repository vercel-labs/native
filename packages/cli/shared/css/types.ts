// CSS declaration types, shared by the compiler and the runtime.

import * as P from "../props.ts";

/** One declaration: property id, value and unit. `important` marks a "!important" declaration. */
export interface Decl {
  p: number;
  v: number;
  u: number;
  important?: boolean;
  /**
   * Set instead of a value for a declaration kept as text: a custom property (--x), or a value
   * that uses var(). `p` is -1 there. The text is compiled once the element's custom properties
   * are known (see shared/css/vars.ts).
   */
  prop?: string;
  value?: string;
}

/** What the compiler knows about the app's resources: its @font-face rules and image files. */
export interface FontContext {
  /**
   * Id for a CSS family name; the system font when the app doesn't have that family. A quoted
   * name is a family name whatever it spells: `"fantasy"` is not the `fantasy` keyword.
   */
  family(name: string, quoted?: boolean): number;
  /** Does the app have a font for this family? A generic family always does. */
  available(name: string): boolean;
  /**
   * Registers one font-feature-settings list (a run of `tag=value` pairs joined by semicolons)
   * and returns its id; the host turns it into the OpenType feature settings of the runs that
   * name it.
   */
  features?(spec: string): number;
  /**
   * A named @font-feature-values alias as a feature spec (`ss04=1`), or null when the page has no
   * such alias: `kind` is the at-rule's name (styleset, swash, …), `name` the alias.
   */
  featureValue?(kind: string, name: string): string | null;
  /**
   * Registers one font-variation-settings list (a run of `tag=value` pairs joined by semicolons)
   * and returns its id; the host sets each axis of the runs that name it.
   */
  variations?(spec: string): number;
  /**
   * Id of a palette name an @font-palette-values rule defines, or -1 when no rule has that name;
   * a font-palette value stores 3 + the id.
   */
  palette?(name: string): number;
  /**
   * Registers the ordered families of a font-family list (their ids) in the FONT_FAMILY_LISTS
   * table and returns its row id; the runtime walks it when a face covers only some characters.
   */
  familyList?(ids: number[]): number;
  /** Id for an image URL, resolved against the declaration's style sheet; -1 when unusable. */
  image(url: string, line: number, col: number): number;
  /** Registers one background layer list (a BG_* table row) and returns its id. */
  background(kind: number, row: number[]): number;
  /** Registers one border-image longhand row and returns its id (see P.BORDER_IMAGE_*). */
  borderImage?(row: number[]): number;
  /** Id for a gradient image, encoded by shared/css/gradients.ts (and its CSS text, for CSSOM). */
  gradient(encoded: string, source: string): number;
  /** Registers one box-shadow list (ten numbers per shadow) and returns its id. */
  shadow(row: number[]): number;
  /**
   * Registers one container-name list (space-separated names, in the order it was written) in the
   * CONTAINER_NAMES table and returns its id; -1 when no table is available.
   */
  containerNames?(list: string): number;
  /**
   * Index for the paint server a `fill`/`stroke` names (`url(#id)`), in the app's paint URL
   * table. A URL the context doesn't know is still given an index: the painter resolves it.
   */
  paint(url: string): number;
  /** Registers one grid track list (a GRID_TRACKS row) and returns its id. */
  tracks(row: number[]): number;
  /** Id of a grid line (or area) name in the GRID_NAMES table, registered on first use. */
  trackName(name: string): number;
  /** Registers one named placement (a GRID_PLACEMENTS row) and returns its id. */
  placement(row: number[]): number;
  /** Registers one grid-template-areas list (a GRID_AREA_LISTS row) and returns its id. */
  areaList(row: number[]): number;
  /** Registers one filter list (eight numbers per function) and returns its id. */
  filter(row: number[]): number;
}

/**
 * What the compiler knows about generated content: one table of `content` item lists. Only the
 * build has one, since `content` applies to ::before/::after rules rather than inline styles.
 */
export interface ContentContext {
  /**
   * Id of an encoded item list (see shared/css/content.ts), registered on first use. Only a
   * pseudo-element rule has one, since `content` generates nothing anywhere else.
   */
  item?(encoded: string): number;
  /** Id of an encoded counter list (counter-reset/-increment/-set), registered on first use. */
  counter?(encoded: string): number;
  /**
   * The index a counter-style name is known by, in the app's COUNTER_STYLE_NAMES table: a
   * `list-style-type` or `counter()` that names an `@counter-style` rule is stored as one.
   */
  counterStyle?(name: string): number;
}

/** [line, col] of a declaration being compiled, for diagnostics raised while compiling it. */
export type Loc = [number, number];

/** Generic and common font names that map onto the families the host can draw. */
// The keywords CSS defines, which name a family category rather than a particular face. A named
// family (Arial, Menlo, Georgia) isn't one of them: the build leaves it to the system, and the
// host opens the face the machine has (see the installed families table).
export const GENERIC_FAMILIES: Record<string, number> = {
  "sans-serif": P.FF_SANS, "system-ui": P.FF_SYSTEM, "-apple-system": P.FF_SYSTEM,
  blinkmacsystemfont: P.FF_SYSTEM, "ui-sans-serif": P.FF_SYSTEM,
  monospace: P.FF_MONO,
  serif: P.FF_SERIF,
  // The system's other designs, which the system-ui keywords name, and the -apple-system- prefix
  // Chrome accepts for the same ones.
  // The host has no cursive or fantasy face of its own to name, so they draw in the system font
  // rather than falling through the list as an unknown name would.
  cursive: P.FF_SYSTEM, fantasy: P.FF_SYSTEM,
  "ui-serif": P.FF_UI_SERIF, "-apple-system-ui-serif": P.FF_UI_SERIF,
  "ui-rounded": P.FF_UI_ROUNDED, "-apple-system-ui-rounded": P.FF_UI_ROUNDED,
  "ui-monospace": P.FF_UI_MONOSPACE, "-apple-system-ui-monospace": P.FF_UI_MONOSPACE,
};

/** The family id a generic keyword names, matched as CSS matches it: ASCII case-insensitively. */
export function genericFamily(name: string): number | undefined {
  return GENERIC_FAMILIES[name.toLowerCase()];
}

// ---------------------------------------------------------------------------
// Selectors

export interface Compound {
  tag: string | null; // null = any
  /**
   * The namespace a namespaced type selector names: an element namespace URI, "" for none,
   * "*" for any, or undefined when the selector doesn't constrain it.
   */
  tagNs?: string;
  id: string | null;
  /** :root: the condition is that the element is the document's root element. */
  root: boolean;
  /** :dir(ltr|rtl): 1 for ltr, 2 for rtl, absent when the selector doesn't ask. */
  dir?: number;
  /**
   * :scope: the condition is that the element is the scope a DOM API call was made on. A style
   * sheet has no scope, so there :scope is the root element and is stored as `root` instead.
   */
  scope?: boolean;
  classes: string[];
  states: number; // S_HOVER | S_ACTIVE | S_FOCUS | S_FOCUS_VISIBLE
  /**
   * Sibling-count conditions, as triplets [A, B, ofType] for :nth-child(An+B) (and the
   * *-of-type form, where ofType is 1). `nthStart` counts element siblings from the start,
   * `nthEnd` from the end; either is empty when the compound has no such condition, and a
   * compound with several conditions appends one triplet each.
   */
  nthStart: number[];
  nthEnd: number[];
  /**
   * The `of S` filter of each condition in `nthStart`/`nthEnd`, in the same order as their
   * triplets: a selector's text, or "" for a condition without one. Absent when no condition of
   * that direction has one.
   */
  nthStartOf?: string[];
  nthEndOf?: string[];
  /** :lang(): language ranges the element's language has to match (case-folded). */
  lang?: string[];
  /** Attribute conditions, encoded "name\u0002op\u0002value" (an empty op = present). */
  attrs: string[];
  /** :not() arguments, as compounds; the element must match none of them. */
  nots: Compound[];
  /** :not() arguments that are complex selectors, as text; the element must match none. */
  notSels?: string[];
  /** :empty: the element has no child elements and no text. */
  empty?: boolean;
  /**
   * :host, on the subject compound of a shadow tree's sheet: the rule styles the tree's host, not
   * the elements inside it. `hostArg` is the compound :host(...) requires of the host.
   */
  host?: boolean;
  hostArg?: Compound;
  /**
   * ::slotted(...): the subject compound is the pseudo-element's argument, and the rule styles a
   * node the tree's slot took (one whose assignedSlot sits in the sheet's tree).
   */
  slotted?: boolean;
  /**
   * :has() arguments, each a relative selector: a combinator (`>`, `+`, `~`, or "" for a
   * descendant), a \u0003 separator, then the selector's text. The element must have a relative
   * match for at least one of them.
   */
  has: string[];
}

export const COMB_DESCENDANT = 0;

export const COMB_CHILD = 1;

export const COMB_ADJACENT = 2;

export const COMB_GENERAL = 3;

/** A compound for an ancestor of the subject, with the combinator that links it rightward. */
export interface ChainLink extends Compound {
  comb: number;
}

export interface Selector extends Compound {
  /** Ancestor compounds, nearest first (right to left in the source). */
  chain: ChainLink[];
  specificity: number; // a*10000 + b*100 + c
  /** PE_NONE, or the pseudo-element the rule styles (PE_FIRST_LINE, PE_SELECTION, ...). */
  pseudo: number;
  /** The name ::highlight(name) gives, or "" for every other pseudo-element. */
  pseudoName: string;
  text: string;
}
