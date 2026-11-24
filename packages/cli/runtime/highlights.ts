// The Custom Highlight API: the named ranges a page registers on CSS.highlights, which
// ::highlight() names in CSS. Painting reads the registry (see paint.ts).

import { AbstractRange, Range, Text, document, invalidatePaint, type Node } from "./dom.ts";

/** One range a highlight covers. A text node stands for a range over all of its text. */
export type HighlightRange = Range | AbstractRange;

/** A range covering a whole text node, as the API's add() takes one. */
function asRange(range: Range | Text | AbstractRange): HighlightRange {
  if (range instanceof AbstractRange) return range;
  const r = document.createRange();
  r.selectNodeContents(range);
  return r;
}

/**
 * A set of ranges a ::highlight() rule can style. Ranges are kept in the order they were added;
 * `priority` decides which of two highlights paints when their ranges overlap.
 */
export class Highlight {
  get [Symbol.toStringTag](): string { return "Highlight"; }
  /** The ranges this highlight covers, in the order they were added. */
  ranges: HighlightRange[] = [];
  /** Which highlight paints over which when ranges overlap: the higher priority is on top. */
  priority = 0;
  /** The kind of highlight. One a page makes itself is always a plain "highlight". */
  readonly type = "highlight";

  constructor(...init: (Range | Text | AbstractRange)[]) {
    for (const r of init) this.add(r);
  }

  /** How many ranges the highlight covers. */
  get size(): number {
    return this.ranges.length;
  }

  add(range: Range | Text | AbstractRange): this {
    this.ranges.push(asRange(range));
    invalidatePaint();
    return this;
  }

  delete(range: Range | Text | AbstractRange): boolean {
    const i = this.ranges.indexOf(asRange(range));
    if (i < 0) return false;
    this.ranges.splice(i, 1);
    invalidatePaint();
    return true;
  }

  has(range: Range | Text | AbstractRange): boolean {
    return this.ranges.indexOf(asRange(range)) >= 0;
  }

  clear(): void {
    if (this.ranges.length === 0) return;
    this.ranges.length = 0;
    invalidatePaint();
  }

  /** The ranges as a list, so `for (const r of highlight)` and `[...highlight]` work. */
  entries(): [HighlightRange, HighlightRange][] {
    return this.ranges.map((r) => [r, r]);
  }

  keys(): HighlightRange[] {
    return this.ranges.slice();
  }

  values(): HighlightRange[] {
    return this.ranges.slice();
  }

  forEach(callback: (range: HighlightRange, same: HighlightRange, highlight: Highlight) => void): void {
    for (const r of this.ranges) callback(r, r, this);
  }

  /** Iterates the ranges, so a highlight spreads and loops over as a set does. */
  [Symbol.iterator](): Iterator<HighlightRange> {
    return this.ranges[Symbol.iterator]();
  }
}

/** CSS's CSS-wide keywords and the few idents a custom-ident can't be. */
const RESERVED_NAMES = ["initial", "inherit", "unset", "revert", "revert-layer", "default", "none"];

/** Whether `name` can name a highlight: a CSS custom-ident. */
function isHighlightName(name: string): boolean {
  if (name === "" || name === "--") return false;
  if (RESERVED_NAMES.indexOf(name.toLowerCase()) >= 0) return false;
  for (let i = 0; i < name.length; i++) {
    const c = name[i];
    const digit = c >= "0" && c <= "9";
    if (digit && i === 0) return false;
    if (i === 1 && digit && name[0] === "-") return false;
    const ok = digit || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c === "-" || c === "_" || c.charCodeAt(0) >= 0x80;
    if (!ok) return false;
  }
  return true;
}

/**
 * The map of names to highlights a page reads as `CSS.highlights`: one highlight per name, with
 * the usual get/has/set/delete/clear and iteration. A name that isn't a CSS custom-ident throws,
 * as the API says, since ::highlight() couldn't name it.
 */
export class HighlightRegistry {
  get [Symbol.toStringTag](): string { return "HighlightRegistry"; }
  private names: string[] = [];
  private highlights: Highlight[] = [];

  get size(): number {
    return this.names.length;
  }

  set(name: string, highlight: Highlight): this {
    const key = String(name);
    if (!isHighlightName(key)) throw new Error("SyntaxError: '" + key + "' is not a valid highlight name");
    const i = this.names.indexOf(key);
    if (i >= 0) {
      this.highlights[i] = highlight;
    } else {
      this.names.push(key);
      this.highlights.push(highlight);
    }
    invalidatePaint();
    return this;
  }

  get(name: string): Highlight | undefined {
    const i = this.names.indexOf(String(name));
    return i < 0 ? undefined : this.highlights[i];
  }

  has(name: string): boolean {
    return this.names.indexOf(String(name)) >= 0;
  }

  delete(name: string): boolean {
    const key = String(name);
    const i = this.names.indexOf(key);
    if (i < 0) return false;
    this.names.splice(i, 1);
    this.highlights.splice(i, 1);
    invalidatePaint();
    return true;
  }

  clear(): void {
    if (this.names.length === 0) return;
    this.names.length = 0;
    this.highlights.length = 0;
    invalidatePaint();
  }

  keys(): string[] {
    return this.names.slice();
  }

  values(): Highlight[] {
    return this.highlights.slice();
  }

  entries(): [string, Highlight][] {
    const out: [string, Highlight][] = [];
    for (let i = 0; i < this.names.length; i++) out.push([this.names[i], this.highlights[i]]);
    return out;
  }

  forEach(callback: (highlight: Highlight, name: string, registry: HighlightRegistry) => void): void {
    for (let i = 0; i < this.names.length; i++) callback(this.highlights[i], this.names[i], this);
  }

  /** Iterates [name, highlight] pairs, as a map does. */
  [Symbol.iterator](): Iterator<[string, Highlight]> {
    return this.entries()[Symbol.iterator]();
  }

  /**
   * The highlights covering a viewport point, highest priority first (a later registration wins
   * a tie), each with the ranges the point falls in. `shadowRoots` names the shadow trees the
   * search may look into, as the API's option does.
   */
  highlightsFromPoint(x: number, y: number,
    options?: { shadowRoots?: Node[] }): { highlight: Highlight; ranges: HighlightRange[] }[] {
    const roots: Node[] = options !== undefined && options !== null && options.shadowRoots !== undefined &&
      options.shadowRoots !== null ? options.shadowRoots : [];
    const found: { highlight: Highlight; ranges: HighlightRange[]; order: number }[] = [];
    for (let i = 0; i < this.highlights.length; i++) {
      const hl = this.highlights[i];
      const hit: HighlightRange[] = [];
      for (const r of hl.ranges) {
        if (rangeInScope(r, roots) && rangeCoversPoint(r, x, y)) hit.push(r);
      }
      if (hit.length > 0) found.push({ highlight: hl, ranges: hit, order: i });
    }
    found.sort((a, b) => a.highlight.priority !== b.highlight.priority
      ? b.highlight.priority - a.highlight.priority
      : b.order - a.order);
    const out: { highlight: Highlight; ranges: HighlightRange[] }[] = [];
    for (const f of found) out.push({ highlight: f.highlight, ranges: f.ranges });
    return out;
  }
}

/** Whether a range's text is in the document or in one of the named shadow trees. */
function rangeInScope(range: HighlightRange, shadowRoots: Node[]): boolean {
  const root = range.rangeRoot;
  if (root.nodeType === 9) return true;
  return shadowRoots.indexOf(root) >= 0;
}

/** Whether a viewport point falls on one of the boxes a range draws in. */
function rangeCoversPoint(range: HighlightRange, x: number, y: number): boolean {
  const rects = range.getClientRects();
  for (let i = 0; i < rects.length; i++) {
    const r = rects[i];
    if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return true;
  }
  return false;
}

/** The registry a page reads as CSS.highlights. */
export const highlights = new HighlightRegistry();

/** The registered names and their highlights, for the painter. */
export function registeredHighlights(): [string, Highlight][] {
  return highlights.entries();
}

/** Forgets every highlight, which a batch's next page starts without. */
export function resetHighlights(): void {
  highlights.clear();
}
