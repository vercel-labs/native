// Selecting text with the pointer: where a point falls in a block's laid-out text, and the
// selection a drag or a double-click over it makes.
//
// A character position is held as the element whose text it is and an offset into that
// element's own text, which is how the fragments were laid out; a run of a child text node is
// counted in its parent element's stream, since the owner a fragment records is that element.

import type { Node } from "./dom.ts";
import { Element, Event, document, dispatch, trusted, selectionState, selectionStreamRange, textOwnersBetween, textStreamIndex } from "./dom.ts";
import { FRAG_TEXT, absolutePosition } from "./layout.ts";
import { textWidth } from "./layout/text.ts";
import { clipsX, clipsY, display } from "./layout/box-model.ts";
import { layoutPasses } from "./layout/box.ts";
import { lineHeightPx } from "./style.ts";
import { invalidatePaint, markPaintRects } from "./invalidation.ts";
import * as P from "../shared/props.ts";

/** A character position: the text node (or element with own text) it is in, and its offset. */
export interface TextPosition {
  el: Node;
  offset: number;
}

/** The element a laid-out point falls in, and where in its text, or null over no text at all. */
export function textPointAt(x: number, y: number): TextPosition | null {
  let best: TextPosition | null = null;
  let bestDist = Infinity;
  const visit = (node: Node): void => {
    if (!(node instanceof Element)) return;
    const el = node;
    if (!el.isElementNode) return;
    if (display(el) === P.D_NONE) return;
    // A generated box isn't DOM text: a drop cap's floated letter is in the paragraph's text
    // node as well, so a selection point at it would put the letter in the copy twice.
    if (el.pseudoKind !== P.PE_NONE) return;
    // A box that clips its content, with the point outside the box, holds no text the point can
    // fall in: the walk stops there instead of descending into a list beside the pane.
    const clipX = clipsX(el);
    const clipY = clipsY(el);
    if (clipX || clipY) {
      const o = absolutePosition(el);
      if (clipX && (x < o[0] || x >= o[0] + el.w)) return;
      if (clipY && (y < o[1] || y >= o[1] + el.h)) return;
    }
    // The box's page position is read only when the box holds text to test the point against.
    let origin: number[] | null = null;
    const at = (): number[] => origin ?? (origin = absolutePosition(el));
    for (let i = 0; i < el.fragKind.length; i++) {
      if (el.fragKind[i] !== FRAG_TEXT) continue;
      const text = el.fragText[i];
      if (text === "") continue;
      const style = el.fragStyle[i];
      const top = at()[1] + el.fragTop[i];
      const lineH = Math.max(1, el.lineBaseline.length > 0 ? lineHeight(el) : 1);
      if (y < top - 2 || y > top + lineH + 2) continue;
      const left = at()[0] + el.fragX[i];
      const dist = Math.abs(x - (left + el.fragW[i] / 2));
      if (dist >= bestDist) continue;
      // How far into the run the point is: the characters before it.
      const k = charsBefore(style, text, x - left);
      bestDist = dist;
      // The run's text belongs to the element whose style draws it, but a selection point has to
      // name the text node that holds the characters: the owner's own text, or one of its text
      // children, whichever the offset falls in.
      best = sourceAt(el, streamBefore(el, i) + k);
    }
    // A box that holds only text lays it out in lines of its own rather than fragments: the
    // lines carry the same geometry, one line box per element line.
    if (el.lines.length > 0) {
      const oy = at()[1] + el.contentY;
      const ox = at()[0] + el.contentX;
      const lh = lineHeightPx(el);
      // A first line whose ::first-line font re-broke it takes that font's line height.
      const lh0 = el.firstLineStyle !== null ? lineHeightPx(el.firstLineStyle) : lh;
      // A drop cap's letter is drawn in its own box, so the text on these lines starts one
      // character into the element's text. A point at the very start of the first line is the
      // start of the paragraph, the letter included.
      const letterShift = el.firstLetterFloat !== null ? 1 : 0;
      let before = 0;
      for (let i = 0; i < el.lines.length; i++) {
        const text = el.lines[i];
        const lineH = i === 0 ? lh0 : lh;
        const top = oy + (i === 0 ? 0 : lh0 + (i - 1) * lh);
        if (!(y < top - 2 || y > top + lineH + 2)) {
          const left = ox + lineIndentX(el, i);
          // The first line may be drawn in ::first-line's font, which measured its characters.
          const lineStyle = i === 0 && el.firstLineStyle !== null ? el.firstLineStyle : el;
          const dist = Math.abs(x - (left + textWidth(lineStyle, text) / 2));
          if (dist < bestDist) {
            const k = charsBefore(lineStyle, text, x - left);
            bestDist = dist;
            best = sourceAt(el, before + k + (i === 0 && k === 0 ? 0 : letterShift));
          }
        }
        before += text.length;
      }
    }
    for (const kid of el.kids) visit(kid);
  };
  if (document.documentElement !== null) visit(document.documentElement);
  return best;
}

/**
 * How many of a run's characters end before `dx` px into it: the first k whose prefix of k + 1
 * characters reaches dx. Prefix widths grow with the prefix, so a binary search finds it in a few
 * measurements rather than one per character.
 */
function charsBefore(style: Node, text: string, dx: number): number {
  let lo = 0;
  let hi = text.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (textWidth(style, text.slice(0, mid + 1)) < dx) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/**
 * The node and offset a position in an element's laid-out text falls in. The text sources, in the
 * order the pieces were gathered: the element's own text when it keeps some, then for each child
 * in turn its text or, for an element, its own text and children. A block's fragments split this
 * stream, and a fragment's characters can be found by their offset along it.
 */
function sourceAt(el: Element, offset: number): TextPosition {
  let rest = offset;
  // Where the stream ends if the offset runs out exactly at a source's end: the position after
  // that source, which is the next source's start unless there is none.
  let end: TextPosition = { el, offset };
  const scan = (node: Element): TextPosition | null => {
    const own = node.ownText;
    if (own !== "") {
      if (rest < own.length) return { el: node, offset: rest };
      end = { el: node, offset: own.length };
      rest -= own.length;
    }
    for (const kid of node.kids) {
      if (kid.isTextNode) {
        const text = kid.layoutText;
        if (rest < text.length) return { el: kid, offset: rest };
        end = { el: kid, offset: text.length };
        rest -= text.length;
      } else if (kid instanceof Element) {
        const hit = scan(kid);
        if (hit !== null) return hit;
      }
    }
    return null;
  };
  const hit = scan(el);
  return hit === null ? end : hit;
}

/** The characters a block's fragments hold before fragment `i`, in the block's stream. */
function streamBefore(block: Element, i: number): number {
  let entry = fragBefore.get(block);
  if (entry === undefined || entry.full !== layoutPasses.full || entry.local !== layoutPasses.local) {
    // Counted once per block and layout: a block of a thousand runs would otherwise count its
    // stream start again for every one of them.
    const before: number[] = [];
    let n = 0;
    for (let j = 0; j < block.fragKind.length; j++) {
      before.push(n);
      // Only text a run holds counts: an atomic box (an image, a replaced control) has a
      // placeholder character in the layout but none in the document's text stream, so it can't
      // shift a run.
      if (block.fragKind[j] === FRAG_TEXT) n += block.fragText[j].length;
    }
    before.push(n);
    entry = { full: layoutPasses.full, local: layoutPasses.local, before };
    fragBefore.set(block, entry);
  }
  return i < entry.before.length ? entry.before[i] : entry.before[entry.before.length - 1];
}

/** Each block's run-start offsets, for the layout they were counted under. */
const fragBefore = new Map<Element, { full: number; local: number; before: number[] }>();

/** The start of a line of an element's own text, before alignment moves it. */
function lineIndentX(el: Element, i: number): number {
  return i === 0 ? el.textIndent : 0;
}

/** One line's height for a block, for the band a point has to fall in. */
function lineHeight(el: Element): number {
  const b = el.lineBaseline;
  return b.length > 1 ? Math.max(1, b[1] - b[0]) : Math.max(1, el.sv[P.P_FONT_SIZE] * 1.2);
}

/** The text a position counts along. */
function ownerText(el: Node): string {
  if (!(el instanceof Element)) return el.ownText;
  return el.ownText;
}

/** The word around an offset: back to the nearest space, forward to the next one. */
function wordRange(text: string, offset: number): [number, number] {
  let a = Math.max(0, Math.min(offset, text.length));
  let b = a;
  while (a > 0 && !/\s/.test(text[a - 1])) a--;
  while (b < text.length && !/\s/.test(text[b])) b++;
  return [a, b];
}

let anchor: TextPosition | null = null;

/** The block a selection position is painted by: the nearest ancestor that lays out text. */
function blockOf(node: Node): Element | null {
  let el: Node | null = node;
  while (el !== null && !(el instanceof Element)) el = el.parentElement;
  while (el !== null) {
    if (el instanceof Element && (el.lines.length > 0 || el.fragKind.length > 0)) return el;
    el = el.parentElement;
  }
  return null;
}

/**
 * The rectangle `block` paints for the part of the document's text stream from `a` to `b`: the
 * vertical band of the lines the span touches, across the block's content width. One rectangle
 * per block, so a drag over a description repaints that band rather than the whole pane.
 */
function rectInBlock(block: Element, a: number, b: number): number[] | null {
  const origin = absolutePosition(block);
  let top = Infinity;
  let bottom = -Infinity;
  if (block.lines.length > 0) {
    const lh = lineHeightPx(block);
    const firstH = block.firstLineStyle !== null ? lineHeightPx(block.firstLineStyle) : lh;
    const start = blockStreamStart(block);
    let at = 0;
    let y = origin[1] + block.contentY;
    for (let i = 0; i < block.lines.length; i++) {
      const h = i === 0 ? firstH : lh;
      if (start + at + block.lines[i].length > a && start + at < b) {
        if (y < top) top = y;
        if (y + h > bottom) bottom = y + h;
      }
      at += block.lines[i].length;
      y += h;
    }
  } else {
    const lh = lineHeightPx(block);
    for (let i = 0; i < block.fragKind.length; i++) {
      if (block.fragKind[i] !== FRAG_TEXT) continue;
      const [fs, fe] = fragmentStream(block, i);
      if (fe <= a || fs >= b) continue;
      const y = origin[1] + block.fragTop[i];
      if (y < top) top = y;
      if (y + lh > bottom) bottom = y + lh;
    }
  }
  if (top === Infinity) return null;
  return [origin[0] + block.contentX, top, block.contentW, bottom - top];
}

/**
 * Repaints what a selection change moved: the text between where the old and the new selection
 * start, and between where they end, in the band of lines each block holding it paints. A drag
 * that grows a selection across paragraphs by a word repaints the line the word is on; a press
 * that drops a selection of three paragraphs repaints those three.
 */
function repaintSelectionChange(before: [number, number] | null): void {
  // Browsers send `selectionchange` at the document whenever the selection moves; it is how an
  // editor keeps its toolbar in step with the caret. It doesn't bubble.
  dispatch(trusted(new Event("selectionchange")), document);
  const after = selectionStreamRange();
  const spans: [number, number][] = [];
  if (before === null && after !== null) spans.push(after);
  else if (after === null && before !== null) spans.push(before);
  else if (before !== null && after !== null) {
    if (before[0] !== after[0]) spans.push([Math.min(before[0], after[0]), Math.max(before[0], after[0])]);
    if (before[1] !== after[1]) spans.push([Math.min(before[1], after[1]), Math.max(before[1], after[1])]);
  }
  const rects: number[][] = [];
  for (const [a, b] of spans) {
    const owners = textOwnersBetween(a, b, SELECTION_REPAINT_LIMIT);
    if (owners === null) {
      invalidatePaint();
      return;
    }
    const seen = new Set<Element>();
    for (const n of owners) {
      const block = blockOf(n);
      if (block === null) {
        invalidatePaint();
        return;
      }
      if (seen.has(block)) continue;
      seen.add(block);
      const rect = rectInBlock(block, a, b);
      if (rect !== null) rects.push(rect);
    }
  }
  markPaintRects(rects);
}

/** More text runs than this changing at once repaint the page, which costs less than the bands. */
const SELECTION_REPAINT_LIMIT = 64;

/** Starts a selection at a laid-out point; a drag extends it from here. */
export function beginSelectionAt(x: number, y: number): boolean {
  const at = textPointAt(x, y);
  anchor = at;
  // A new press drops the highlight there was, wherever it was.
  const before = selectionStreamRange();
  if (at === null) {
    selectionState.collapse(null, 0);
    repaintSelectionChange(before);
    return false;
  }
  selectionState.collapse(at.el, at.offset);
  repaintSelectionChange(before);
  return true;
}

/** Extends the selection started by a press to a laid-out point. */
export function extendSelectionTo(x: number, y: number): void {
  if (anchor === null) return;
  const at = textPointAt(x, y);
  if (at === null) return;
  const before = selectionStreamRange();
  selectionState.setPoints(anchor, at);
  repaintSelectionChange(before);
}

/** Selects the word under a laid-out point, as a double-click does. */
export function selectWordAt(x: number, y: number): boolean {
  const at = textPointAt(x, y);
  if (at === null) return false;
  const text = ownerText(at.el);
  const [a, b] = wordRange(text, at.offset);
  anchor = { el: at.el, offset: a };
  const before = selectionStreamRange();
  selectionState.setPoints(anchor, { el: at.el, offset: b });
  repaintSelectionChange(before);
  return b > a;
}

/** Selects the whole element the point is in, as a triple-click does. */
export function selectParagraphAt(x: number, y: number): boolean {
  const at = textPointAt(x, y);
  if (at === null) return false;
  let el: Element = document.documentElement;
  if (at.el instanceof Element) el = at.el;
  else if (at.el.parentElement !== null) el = at.el.parentElement;
  const total = layoutTextLength(el);
  if (total === 0) return false;
  const a = sourceAt(el, 0);
  const b = sourceAt(el, total);
  anchor = a;
  const before = selectionStreamRange();
  selectionState.setPoints(a, b);
  repaintSelectionChange(before);
  return true;
}

/** How many characters an element's laid-out text holds: its own text and its text children's. */
function layoutTextLength(el: Element): number {
  let n = el.ownText.length;
  for (const kid of el.kids) if (kid.isTextNode) n += kid.layoutText.length;
  return n;
}

/** Forgets the drag in progress, leaving the selection as it is. */
export function endSelectionDrag(): void {
  anchor = null;
}

/** The document's selection as character offsets in its text stream, for painting. */
export function selectedSpan(): [number, number] | null {
  return selectionStreamRange();
}

// ---------------------------------------------------------------------------
// Painting the selection
//
// A paint asks the same two questions of every run it draws: what span is selected, and where a
// block's text starts in the document's stream. Both are the same for the whole pass, so they are
// answered once when it begins: a page of runs would otherwise each walk the document's whole
// text stream (and each block would, again, for every line).

let paintSpan: [number, number] | null = null;
let paintSpanSet = false;
const blockStarts = new Map<Node, number>();

/** Starts a paint pass: the selection span and each block's stream start are read once now. */
export function beginSelectionPaint(): void {
  paintSpan = selectionStreamRange();
  paintSpanSet = true;
  blockStarts.clear();
  fragBefore.clear();
}

/** Ends a paint pass, so a change made while nothing is painting is read fresh. */
export function endSelectionPaint(): void {
  paintSpanSet = false;
  paintSpan = null;
  blockStarts.clear();
}

/** The selection as the pass reads it. */
function spanNow(): [number, number] | null {
  return paintSpanSet ? paintSpan : selectionStreamRange();
}

/** The stream offset of a position inside one source of an element's text. */
export function streamOf(node: Node, offset: number): number {
  return textStreamIndex(node, offset);
}

/**
 * The part of a run that is selected, as [from, to) character offsets within the run's own text,
 * or null. `node` and `base` name the source the run starts in and the offset there.
 */
export function selectedPart(node: Node, base: number, len: number): [number, number] | null {
  const span = spanNow();
  if (span === null) return null;
  const start = textStreamIndex(node, base);
  const a = Math.max(span[0], start), b = Math.min(span[1], start + len);
  if (b <= a) return null;
  return [a - start, b - start];
}

/** Where a block's text fragment sits in the document's character stream. */
export function fragmentStream(block: Element, i: number): [number, number] {
  const start = blockStreamStart(block) + streamBefore(block, i);
  return [start, start + block.fragText[i].length];
}

/** The selected part of a block's text fragment, as offsets within its text, or null. */
export function fragmentSelection(block: Element, i: number): [number, number] | null {
  const span = spanNow();
  if (span === null) return null;
  const [start, end] = fragmentStream(block, i);
  const a = Math.max(span[0], start), b = Math.min(span[1], end);
  if (b <= a) return null;
  return [a - start, b - start];
}

/** Where a block's laid-out text begins in the document's character stream. */
function blockStreamStart(block: Element): number {
  const hit = blockStarts.get(block);
  if (hit !== undefined) return hit;
  const at = sourceAt(block, 0);
  const start = textStreamIndex(at.el, at.offset);
  blockStarts.set(block, start);
  return start;
}

/** Where one of an element's own-text lines sits in the document's character stream. */
export function lineStream(el: Element, text: string, before: number): [number, number] {
  const start = blockStreamStart(el) + before;
  return [start, start + text.length];
}

/** The selected part of one of an element's own-text lines, given the line's text and offset. */
export function lineSelection(el: Element, text: string, before: number): [number, number] | null {
  const span = spanNow();
  if (span === null) return null;
  const [start, end] = lineStream(el, text, before);
  const a = Math.max(span[0], start), b = Math.min(span[1], end);
  if (b <= a) return null;
  return [a - start, b - start];
}
