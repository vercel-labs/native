// Inline formatting: pieces, line breaking, baselines and fragments; block-in-inline splitting.

import * as P from "../../shared/props.ts";
import { settleNode } from "./incremental.ts";
import { Node, HTMLInputElement, FRAG_TEXT, FRAG_EDGE, EMPTY_LINE, boxKids, langOf } from "../dom.ts";
import { isFlexContainer, isGridContainer, isLanesContainer, lineHeightPx, fontKey, lastLineAlign, lineAlign, isRtl, strongDirection } from "../style.ts";
import { hostAtomicBreakForbidden, hostLineBreakAt, hostLineBreakCount, hostRegisterLineBreaks } from "../host.ts";
import { layoutBox } from "./box.ts";
import { borderLeft, borderRight, clipsX, display, flattenContents, hasOwnText, isFloat, isOutOfFlow, isReplaced, len, marginH, marginV, measure, place, relativeOffset, relativeOffsetSum, visibleChildren, zeroIfNaN, inlineEndBorder, inlineStartBorder } from "./box-model.ts";
import { baselineOffset, ellipsize, firstLineIndent, fontMetrics, intrinsicMaxWidth, intrinsicMinWidth, spacingPx, textWidth, transformText } from "./text.ts";
import { FloatCtx, clearBottom, lineFitY, floatSlot } from "./floats.ts";
import { isTableInternal, layoutInlineTableRun, tableRunContentWidth } from "./table.ts";

// ---------------------------------------------------------------------------
// Inline formatting
//
// A run of inline-level children becomes a list of pieces (words, collapsible spaces, the
// start/end edges of inline elements, atomic inline boxes, forced breaks). Pieces between
// break opportunities form segments; segments are placed greedily into line boxes; each line's
// fragments are aligned on a shared baseline. Fragments are stored on the container.

const K_TEXT = 0;

const K_SPACE = 1;

const K_OPEN = 2;

const K_CLOSE = 3;

const K_ATOMIC = 4;

const K_BREAK = 5;

const K_PSPACE = 6; // preserved space run (pre, pre-wrap): no break opportunity after it

const K_BSPACE = 7; // preserved space run of break-spaces: a break opportunity may move it

const K_ABS = 8; // an out-of-flow box, which takes no room but records where it would have gone

// The fragment kinds live with the arrays that hold them, on the DOM's Node.
export { FRAG_TEXT, FRAG_EDGE } from "../dom.ts";

export const K_ATABLE = 9; // an anonymous inline-table around a run of table parts

const K_SHY = 10; // a soft hyphen: the line may break here, and the mark shows when it does

export class Piece {
  kind: number;
  style: Node; // computed style source (text node, inline element, or atomic box)
  owner: Node; // event target / background owner
  text: string;
  w = 0;
  /** An atomic box's min-content width, which its min-content contribution uses. */
  wMin = 0;
  /** The height of an anonymous inline-table, and its first-row baseline above its top. */
  h = 0;
  asc = 0;
  /** The table parts an anonymous inline-table holds. */
  run: Node[] | null = null;
  /** An edge at a break inside a box: its margin, border and padding aren't rendered. */
  bare = false;
  /** This piece is one character of a word that may be broken between any two characters. */
  brk = false;
  constructor(kind: number, style: Node, owner: Node, text: string) {
    this.kind = kind;
    this.style = style;
    this.owner = owner;
    this.text = text;
  }
}

/** True when a run of pieces shows nothing: no content and only collapsible white space. */
export function isBlankPieces(pieces: Piece[]): boolean {
  for (const p of pieces) {
    if (p.kind === K_ATOMIC || p.kind === K_ABS || p.kind === K_ATABLE) return false;
    if (p.kind === K_TEXT && /[^ \t\f\r\n]/.test(p.text)) return false;
  }
  return true;
}

/**
 * True for a run of pieces that is nothing but collapsible white space. Such a run makes no line
 * box: white space between block-level boxes, or before the first one, leaves no line behind.
 * `nowrap` keeps its spaces as text so they can hang at the end of a line, but they still collapse
 * when they aren't between anything.
 */
export function isCollapsibleRun(pieces: Piece[]): boolean {
  for (const p of pieces) {
    if (p.kind === K_ABS) continue;
    if (p.kind === K_SPACE) continue;
    if (p.kind === K_TEXT && p.style.sv[P.P_WHITE_SPACE] === P.W_NOWRAP && !/[^ \t\f\r\n]/.test(p.text)) continue;
    return false;
  }
  return true;
}

/**
 * Gives the out-of-flow boxes of a run that makes no line box their static position: the block's
 * content edge at the point in the flow the run would have been laid out at.
 */
export function placeAbsOfBlankRun(pieces: Piece[], pl: number, top: number): void {
  for (const p of pieces) {
    if (p.kind !== K_ABS) continue;
    // The run holds no content, so the box is at its start.
    p.style.staticX = pl;
    p.style.staticY = top;
    p.style.staticValid = true;
  }
}

export function isInlineLevel(c: Node): boolean {
  const d = display(c);
  return c.isTextNode || d === P.D_INLINE || d === P.D_INLINE_BLOCK || d === P.D_INLINE_FLEX ||
    d === P.D_INLINE_TABLE || d === P.D_INLINE_GRID || d === P.D_INLINE_GRID_LANES;
}

/** Text that collapses to nothing generates no line box, so it makes nothing inline-level. */
function collapsibleSpaceOnly(c: Node): boolean {
  if (!c.isTextNode) return false;
  const ws = c.sv[P.P_WHITE_SPACE];
  if (ws !== P.W_NORMAL && ws !== P.W_NOWRAP && ws !== P.W_PRE_LINE) return false;
  // Only white space that collapses counts: an ideographic space is preserved and does.
  return !/[^ \t\f\r\n]/.test(c.layoutText);
}

export function hasInlineContent(el: Node): boolean {
  for (const c of flattenContents(boxKids(el))) {
    if (display(c) !== P.D_NONE && isInlineLevel(c) && !collapsibleSpaceOnly(c)) return true;
  }
  return false;
}

/**
 * Collects the run of table-internal boxes that starts at `list[i]` into `run`, with the
 * collapsible white space between them left out: CSS generates one anonymous table around
 * consecutive table parts (CSS 2.1 §17.2.2), and inside inline content that table is an
 * anonymous inline-table. Returns the index just past the run, or `i` when `list[i]` doesn't
 * start one.
 */
function collectTableRun(list: Node[], i: number, run: Node[]): number {
  if (list[i].isTextNode || !isTableInternal(display(list[i]))) return i;
  run.push(list[i]);
  let j = i + 1;
  // The next node the run can see: white space runs between the parts are the table's, and a box
  // that generates nothing (a <script>, a hidden element) stands between them without ending it.
  const nextPart = (from: number): Node | null => {
    for (let k = from; k < list.length; k++) {
      const n = list[k];
      if (display(n) === P.D_NONE) continue;
      if (n.isTextNode && collapsibleSpaceOnly(n)) continue;
      return n;
    }
    return null;
  };
  while (j < list.length) {
    const n = list[j];
    if (display(n) === P.D_NONE) {
      j++;
      continue;
    }
    if (!n.isTextNode && isTableInternal(display(n))) {
      run.push(n);
      j++;
      continue;
    }
    // White space between table parts belongs to the anonymous table, not to the line.
    const after = nextPart(j + 1);
    if (n.isTextNode && collapsibleSpaceOnly(n) && after !== null && !after.isTextNode && isTableInternal(display(after))) {
      j++;
      continue;
    }
    break;
  }
  return j;
}

/** The piece for a run of table parts: its first part supplies the inherited style. */
function tablePiece(run: Node[]): Piece {
  const first = run[0];
  const parent = first.parentElement;
  return new Piece(K_ATABLE, first, parent !== null ? parent : first, "");
}

// Line-break opportunities, from the system's line breaker, kept per language, `line-break` value
// and text: a layout pass asks once for a run of text however many times it measures it.
const breakCache = new Map<string, number[]>();

/** Forgets the line-break opportunities: a batch renders several pages in one process. */
export function resetBreakCache(): void {
  breakCache.clear();
}

/** Does this text hold a character that may need a break opportunity of its own? A run of
 *  letters, digits and spaces breaks at its spaces, which the caller already handles. */
function mayBreakInside(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (!((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) ||
      c === 0x20 || c === 0x09 || c === 0x0a || c === 0x0d)) return true;
  }
  return false;
}

/**
 * The offsets in `text` a line may break at, or null when only the caller's spaces and soft
 * hyphens break it: plain text, or a run whose `word-break`/`line-break` already breaks it
 * everywhere (`break-all`, `anywhere`) or nowhere it shouldn't (`keep-all`).
 */
function lineBreakOffsets(style: Node, text: string): number[] | null {
  const keepAll = style.sv[P.P_WORD_BREAK] === P.WB_KEEP_ALL;
  if (breaksAnywhere(style)) return null;
  const lb = style.sv[P.P_LINE_BREAK];
  if (lb === P.LB_ANYWHERE) return null;
  if (!mayBreakInside(text)) return null;
  const lang = langOf(style);
  const key = lang + "|" + lb + "|" + (keepAll ? "k" : "") + text;
  const hit = breakCache.get(key);
  if (hit !== undefined) return hit;
  const out: number[] = [];
  const id = hostRegisterLineBreaks(text, lang, lb);
  const n = id > 0 ? hostLineBreakCount(id) : 0;
  for (let i = 0; i < n; i++) {
    const at = hostLineBreakAt(id, i);
    // `word-break: keep-all` forbids breaking within a CJK word: no break next to a CJK character,
    // except at an explicit opportunity — after an ideographic comma or period, or after a zero
    // width space. Latin text, and breaks at spaces, are unaffected.
    if (keepAll && at > 0 && at < text.length) {
      const before = text.charCodeAt(at - 1);
      const after = text.charCodeAt(at);
      if ((cjkChar(before) || cjkChar(after)) && !keepAllBreakChar(before)) continue;
    }
    out.push(at);
  }
  breakCache.set(key, out);
  return out;
}

/** The characters `word-break: keep-all` still breaks after: an ideographic comma or full stop,
 *  or the zero width space that asks for a break itself. */
function keepAllBreakChar(c: number): boolean {
  return c === 0x200b || c === 0x3001 || c === 0x3002 || c === 0xff0c || c === 0xff0e;
}

/** Whether a UTF-16 unit is a character of a script `word-break: keep-all` keeps together. */
function cjkChar(c: number): boolean {
  return (c >= 0x1100 && c <= 0x11ff) || (c >= 0x3040 && c <= 0x31ff) || (c >= 0x3400 && c <= 0x4dbf) ||
    (c >= 0x4e00 && c <= 0x9fff) || (c >= 0xac00 && c <= 0xd7af) || (c >= 0xf900 && c <= 0xfaff) ||
    (c >= 0x20000 && c <= 0x3ffff);
}

/** The last code point of `s` (a surrogate pair stays whole). */
function lastCodePoint(s: string): string {
  if (s.length === 0) return "";
  const cp = s.codePointAt(s.length - 1) ?? 0;
  if (cp >= 0xDC00 && cp <= 0xDFFF && s.length >= 2) return s.slice(-2);
  return s.slice(-1);
}

/** The first code point of `s` (a surrogate pair stays whole). */
function firstCodePoint(s: string): string {
  if (s.length === 0) return "";
  const cp = s.codePointAt(0) ?? 0;
  return cp > 0xFFFF ? s.slice(0, 2) : s.slice(0, 1);
}

/**
 * Whether a line may break between two runs of inline content: `a` is the character that ends
 * the text before the boundary and `b` the character that starts the text after it, each one
 * character of its own run, with an atomic inline standing in as U+FFFC. A zero width space at
 * the end of a run is decided by the language's line breaker just as it would be inside one run.
 */
function boundaryBreak(style: Node, a: string, b: string): boolean {
  if (a === "" || b === "") return false;
  if (breaksAnywhere(style)) return true;
  // Without the system's line breaker the only opportunities are the ones CSS adds itself; a
  // break inside a run's text needs the host's line breaker.
  if (!hasLineBreaker()) return false;
  const offs = lineBreakOffsets(style, a + b);
  return offs !== null && offs.indexOf(1) >= 0;
}

/**
 * Whether a line may break between an atomic inline and the character `ch` beside it. CSS adds a
 * soft wrap opportunity there even where UAX #14 would not — next to a no-break space or a
 * punctuation mark — unless `ch` is one of the characters that glue to their neighbours (GL, CM,
 * WJ, ZWJ); the host answers for the character's line-break class.
 */
function atomicBoundary(ch: string): boolean {
  if (ch === "" || ch === "￼") return true;
  return hostAtomicBreakForbidden(ch.codePointAt(0) ?? 0) === 0;
}

/** Whether the host has a line breaker at all (ICU): it is asked once, and the answer holds for
 *  the process. */
let lineBreakerState = -1;
function hasLineBreaker(): boolean {
  if (lineBreakerState < 0) lineBreakerState = hostRegisterLineBreaks("あ", "ja", P.LB_AUTO) > 0 ? 1 : 0;
  return lineBreakerState === 1;
}

/**
 * Marks the text pieces a line may start at although the break is at the edge of the run before
 * them: a run ending in a zero width space, or two runs of a script whose line breaking allows a
 * break between their characters, with only inline box edges between the pieces. A break at a
 * space, a soft hyphen or inside a run is already a piece of its own.
 */
function markRunBoundaryBreaks(pieces: Piece[]): void {
  let prev: Piece | null = null;
  for (const p of pieces) {
    if (p.kind === K_SPACE || p.kind === K_PSPACE || p.kind === K_BSPACE || p.kind === K_BREAK ||
      p.kind === K_SHY) {
      prev = null;
      continue;
    }
    if (p.kind === K_OPEN || p.kind === K_CLOSE || p.kind === K_ABS) continue;
    if (p.kind === K_TEXT && prev !== null) {
      const a = prev.kind === K_TEXT ? lastCodePoint(prev.text) : "￼";
      const ws = p.style.sv[P.P_WHITE_SPACE];
      const open = prev.kind !== K_TEXT
        ? atomicBoundary(firstCodePoint(p.text))
        : boundaryBreak(p.style, a, firstCodePoint(p.text));
      if (ws !== P.W_PRE && !noWrapStyle(p.style) && open) p.brk = true;
    }
    prev = p;
  }
}

/** Control characters are drawn as a visible glyph, as CSS's white space processing asks; the
 *  replacement character stands in for them, and keeps the run one character per character so
 *  the break offsets still line up. */
function visibleControls(s: string): string {
  return s.replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g, "\uFFFD");
}

export function pushText(style: Node, owner: Node, text: string, out: Piece[]): void {
  const ws = style.sv[P.P_WHITE_SPACE];
  const collapse = ws === P.W_NORMAL || ws === P.W_NOWRAP || ws === P.W_PRE_LINE;
  const wrap = ws === P.W_NORMAL || ws === P.W_PRE_WRAP || ws === P.W_PRE_LINE || ws === P.W_BREAK_SPACES;
  const breaks = ws !== P.W_NORMAL && ws !== P.W_NOWRAP; // segment breaks are preserved
  // A space run's kind decides what happens to it at a line edge: a collapsible space is
  // dropped at the start and end of a line, a preserved one is placed. `nowrap` collapses as
  // `normal` does and still drops the spaces at the edges; it only suppresses the break.
  const spaceKind = collapse ? K_SPACE : !wrap ? K_TEXT : ws === P.W_BREAK_SPACES ? K_BSPACE : K_PSPACE;
  // An ideographic space (U+3000) is preserved in every white-space mode: it isn't white space
  // that collapses, it gives a break opportunity after it, and it hangs at the end of a line
  // (or, with break-spaces, wraps to the next one).
  const ideoKind = !wrap ? K_TEXT : ws === P.W_BREAK_SPACES ? K_BSPACE : K_PSPACE;
  // A form feed is a control character CSS keeps visible, not white space that collapses.
  const isSpace = (ch: string) => ch === " " || ch === "\t";
  // `text-transform` changes the rendered text, not the DOM's.
  text = transformText(style, text);
  // Where the system's line breaker lets a line break inside a word, for the language and
  // `line-break` value the run has.
  const lineBreaks = wrap ? lineBreakOffsets(style, text) : null;
  // A preserved tab advances to the next tab stop, which `tab-size` spaces wide; the column it
  // starts from is counted in characters on the line so far.
  const tabSize = style.sv[P.P_TAB_SIZE];
  let col = 0;
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      i++;
      col = 0;
      out.push(breaks ? new Piece(K_BREAK, style, owner, "") : new Piece(spaceKind, style, owner, " "));
      continue;
    }
    if (ch === "\u3000") {
      i++;
      col++;
      out.push(new Piece(ideoKind, style, owner, ch));
      continue;
    }
    if (isSpace(ch)) {
      let j = i;
      while (j < text.length && isSpace(text[j])) j++;
      let spaces = " ";
      if (!collapse) {
        spaces = "";
        for (let k = i; k < j; k++) {
          if (text[k] === "\t") {
            const n = tabSize > 0 ? tabSize - (col % tabSize) : 0;
            for (let m = 0; m < n; m++) spaces += " ";
            col += n;
          } else {
            spaces += " ";
            col++;
          }
        }
      }
      i = j;
      // A tab stop of zero spaces renders nothing.
      if (spaces === "") continue;
      if (spaceKind === K_BSPACE) {
        // break-spaces gives every space its own break opportunity, so a run of them wraps one
        // space at a time instead of moving to the next line whole.
        for (const sp of spaces) out.push(new Piece(spaceKind, style, owner, sp));
      } else {
        out.push(new Piece(spaceKind, style, owner, spaces));
      }
      continue;
    }
    let j = i;
    while (j < text.length && !isSpace(text[j]) && text[j] !== "\n" && text[j] !== "\r" && text[j] !== "\u3000") j++;
    if (lineBreaks === null) {
      pushWord(style, owner, visibleControls(text.slice(i, j)), out);
    } else {
      // A line may start at each break the system's line breaker gives inside this word.
      let a = i;
      for (const o of lineBreaks) {
        if (o <= a || o >= j) continue;
        pushWord(style, owner, visibleControls(text.slice(a, o)), out, a > i);
        a = o;
      }
      pushWord(style, owner, visibleControls(text.slice(a, j)), out, a > i);
    }
    col += j - i;
    i = j;
  }
}

/**
 * Pushes one word. A soft hyphen (U+00AD) is a break opportunity when `hyphens` allows one: the
 * pieces either side of it are separate segments, and a hyphen is drawn at the end of the line
 * only when the break there is taken. `hyphens: none` takes the soft hyphens out of the text.
 */
function pushWord(style: Node, owner: Node, word: string, out: Piece[], brk = false): void {
  if (word.indexOf("\u00ad") < 0) {
    const p = new Piece(K_TEXT, style, owner, word);
    p.brk = brk;
    out.push(p);
    return;
  }
  if (style.sv[P.P_HYPHENS] === P.HY_NONE) {
    out.push(new Piece(K_TEXT, style, owner, word.replace(/\u00ad/g, "")));
    return;
  }
  // A soft hyphen at either edge of the word has no line to break: the edge is one already.
  word = word.replace(/^\u00ad+/, "").replace(/\u00ad+$/, "");
  const parts = word.split("\u00ad");
  for (let k = 0; k < parts.length; k++) {
    if (parts[k] !== "") {
      const p = new Piece(K_TEXT, style, owner, parts[k]);
      // The line may start at this part, breaking at the soft hyphen before it.
      if (k > 0) p.brk = true;
      if (k === 0) p.brk = brk;
      out.push(p);
    }
    if (k < parts.length - 1) out.push(new Piece(K_SHY, style, owner, "-"));
  }
}

function resetInlineBox(c: Node): void {
  c.x = 0;
  c.y = 0;
  c.w = 0;
  c.h = 0;
  c.lines = [];
  c.clearFragments();
}

function gather(items: Node[], out: Piece[]): void {
  let i = 0;
  while (i < items.length) {
    const run: Node[] = [];
    const end = collectTableRun(items, i, run);
    if (end > i) {
      // Table parts inside inline content make one anonymous inline-table, an atomic box.
      const p = tablePiece(run);
      p.run = run;
      out.push(p);
      i = end;
      continue;
    }
    const c = items[i++];
    if (display(c) === P.D_NONE || isOutOfFlow(c)) continue;
    if (c.isTextNode) {
      resetInlineBox(c);
      pushText(c, c.parentElement !== null ? c.parentElement : c, c.layoutText, out);
    } else if (c.localName === "br") {
      resetInlineBox(c);
      out.push(new Piece(K_BREAK, c, c, ""));
    } else if (isReplaced(c)) {
      // An <img> is an atomic inline-level box, even with its default display: inline.
      out.push(new Piece(K_ATOMIC, c, c, ""));
    } else if (display(c) === P.D_INLINE) {
      resetInlineBox(c);
      out.push(new Piece(K_OPEN, c, c, ""));
      if (hasOwnText(c)) pushText(c, c, c.ownText, out);
      else gather(boxKids(c), out);
      out.push(new Piece(K_CLOSE, c, c, ""));
    } else {
      out.push(new Piece(K_ATOMIC, c, c, ""));
    }
  }
}

/**
 * One step of a block container's flow: either a segment of inline content (its pieces, laid out
 * as one anonymous block box) or a block-level box.
 */
class FlowEntry {
  block: Node | null = null;
  /** An out-of-flow box met at this point in the flow, which only needs a static position. */
  abs: Node | null = null;
  pieces: Piece[] = [];
  /** Relative-position shift of the inline boxes around a hoisted block, which it moves with. */
  shiftX = 0;
  shiftY = 0;
}

/**
 * Expands the children of a block container into flow entries, hoisting blocks out of inline.
 * `innerW` is the container's content width, for percentage relative offsets.
 */
export function splitFlow(kids: Node[], innerW: number, innerH: number = NaN): FlowEntry[] {
  const out: FlowEntry[] = [];
  let i = 0;
  while (i < kids.length) {
    // An out-of-flow box between inline-level siblings belongs to their run: it takes no room,
    // but its static position is the point in the line where it would have been.
    const inlineRun = isInlineLevel(kids[i]) ||
      (isOutOfFlow(kids[i]) && i + 1 < kids.length && isInlineLevel(kids[i + 1]));
    if (!inlineRun) {
      const e = new FlowEntry();
      if (isOutOfFlow(kids[i])) e.abs = kids[i];
      else e.block = kids[i];
      out.push(e);
      i++;
      continue;
    }
    const run: Node[] = [];
    while (i < kids.length && (isInlineLevel(kids[i]) || isOutOfFlow(kids[i]))) run.push(kids[i++]);
    splitRun(run, out, innerW, innerH);
  }
  return out;
}

/**
 * Turns a run of inline-level children into pieces, breaking the inline boxes open around any
 * block-level box inside them: the block becomes a flow entry of its own, with the inline boxes
 * that contained it closed before it and reopened after it, as CSS's anonymous block boxes do.
 */
function splitRun(items: Node[], out: FlowEntry[], innerW: number, innerH: number): void {
  const chain: Node[] = [];
  let pieces: Piece[] = [];
  // The edges at the break aren't rendered, so they take no room and no border or padding.
  const closeChain = () => {
    for (let k = chain.length - 1; k >= 0; k--) {
      const p = new Piece(K_CLOSE, chain[k], chain[k], "");
      p.bare = true;
      pieces.push(p);
    }
  };
  const openChain = () => {
    for (const e of chain) {
      const p = new Piece(K_OPEN, e, e, "");
      p.bare = true;
      pieces.push(p);
    }
  };
  const flush = (atBreak: boolean) => {
    // A segment with nothing in it that a break cuts off holds only edges at the break: its
    // inline boxes have no fragment of their own there, so their margin, border and padding
    // don't render. One at the run's end does the same when it starts at a break.
    if (!segmentShows(pieces) && (atBreak || (pieces.length > 0 && pieces[0].bare))) {
      for (const p of pieces) if (p.kind === K_OPEN || p.kind === K_CLOSE) p.bare = true;
    }
    const seg = new FlowEntry();
    seg.pieces = pieces;
    out.push(seg);
    pieces = [];
  };
  const walk = (list: Node[]) => {
    let i = 0;
    while (i < list.length) {
      const run: Node[] = [];
      const end = collectTableRun(list, i, run);
      if (end > i) {
        // Table parts inside inline content make one anonymous inline-table, an atomic box.
        const p = tablePiece(run);
        p.run = run;
        pieces.push(p);
        i = end;
        continue;
      }
      const c = list[i++];
      if (display(c) === P.D_NONE) continue;
      if (isOutOfFlow(c)) {
        // It takes no room in the line, but its static position is the point in the line where
        // it would have been placed.
        pieces.push(new Piece(K_ABS, c, c, ""));
        continue;
      }
      if (c.isTextNode) {
        resetInlineBox(c);
        pushText(c, c.parentElement !== null ? c.parentElement : c, c.layoutText, pieces);
        continue;
      }
      if (c.localName === "br") {
        resetInlineBox(c);
        pieces.push(new Piece(K_BREAK, c, c, ""));
        continue;
      }
      if (isReplaced(c)) {
        pieces.push(new Piece(K_ATOMIC, c, c, ""));
        continue;
      }
      if (display(c) === P.D_INLINE) {
        resetInlineBox(c);
        pieces.push(new Piece(K_OPEN, c, c, ""));
        chain.push(c);
        if (hasOwnText(c)) pushText(c, c, c.ownText, pieces);
        else walk(boxKids(c));
        chain.pop();
        pieces.push(new Piece(K_CLOSE, c, c, ""));
        continue;
      }
      if (isInlineLevel(c)) {
        // An inline-block, an inline-flex or a text run is an atomic box, laying out its own content.
        pieces.push(new Piece(K_ATOMIC, c, c, ""));
        continue;
      }
      // A block-level box inside the inline: close the inline boxes around it, lay the block out
      // as a block-level sibling, then reopen them for whatever follows.
      closeChain();
      // A float doesn't split the inline box the way a block-level box does: the box's edges
      // keep rendering on the line the float starts on, so nothing there is at a break.
      flush(!isFloat(c));
      const blk = new FlowEntry();
      blk.block = c;
      // Relative positioning on an inline box moves the block inside it too.
      for (const e of chain) {
        const off = relativeOffset(e, innerW, innerH);
        blk.shiftX += off[0];
        blk.shiftY += off[1];
      }
      out.push(blk);
      openChain();
    }
  };
  walk(items);
  flush(false);
}

/** Whether a segment cut off at a break inside inline boxes holds anything but their edges. */
function segmentShows(pieces: Piece[]): boolean {
  for (const p of pieces) {
    if (p.kind === K_OPEN || p.kind === K_CLOSE || p.kind === K_SPACE) continue;
    return true;
  }
  return false;
}

function edgeWidth(el: Node, start: boolean, cbW: number): number {
  const m = zeroIfNaN(len(el, start ? P.P_MARGIN_LEFT : P.P_MARGIN_RIGHT, cbW));
  const p = zeroIfNaN(len(el, start ? P.P_PADDING_LEFT : P.P_PADDING_RIGHT, cbW));
  return m + p + (start ? inlineStartBorder(el) : inlineEndBorder(el));
}

class Placed {
  kind: number;
  style: Node;
  owner: Node;
  text: string;
  x: number;
  w: number;
  /** An atomic box's min-content width, for min-content sizing of the line. */
  wMin: number;
  /** An anonymous inline-table's height, its baseline and the table parts it holds. */
  h = 0;
  asc = 0;
  run: Node[] | null = null;
  /** An edge at a break inside a box, whose margin, border and padding aren't rendered. */
  bare = false;
  constructor(kind: number, style: Node, owner: Node, text: string, x: number, w: number, wMin: number) {
    this.kind = kind;
    this.style = style;
    this.owner = owner;
    this.text = text;
    this.x = x;
    this.w = w;
    this.wMin = wMin;
  }
}

/**
 * True when the run holds a break that clears a float of `side`: a `<br clear>` in it puts what
 * follows below those floats, and a float met after the run can't sit beside what came before it.
 */
export function piecesClearFloat(pieces: Piece[], side: number): boolean {
  for (const p of pieces) {
    if (p.kind !== K_BREAK) continue;
    const c = p.style.sv[P.P_CLEAR];
    if (c === P.CL_BOTH || (c === P.CL_LEFT && side === P.FL_LEFT) ||
      (c === P.CL_RIGHT && side === P.FL_RIGHT)) return true;
  }
  return false;
}

/** A line box: the items placed in it, and whether a forced break ended it. */
class Line {
  items: Placed[] = [];
  forced = false;
  // The `clear` of the <br> that ended the line: what follows it starts below the floats that
  // side names (CSS 2.1 9.5.2), since a break cleared of floats is where they stop.
  clear = 0;
  // The width of the first run of content on the line: the part that can't be broken, which a
  // line box has to be wide enough for.
  first = 0;
}

/**
 * True when a line holds text or an atomic box, as opposed to only inline edges. This is what
 * decides where a line's content starts — a collapsible space before the first text or atomic
 * box is at the line's edge and is dropped, whatever edges sit between it and that box.
 */
function lineHasContent(line: Line): boolean {
  for (const item of line.items) {
    if (item.kind === K_TEXT || item.kind === K_ATOMIC || item.kind === K_ATABLE) return true;
  }
  return false;
}

/**
 * True when a line box takes up height: it holds content, or an inline element whose margin,
 * padding or border shows even with nothing in it. A line with neither is a zero-height one
 * (CSS 2.1 9.4.2).
 */
function lineShows(line: Line): boolean {
  if (lineHasContent(line)) return true;
  for (const item of line.items) {
    if ((item.kind === K_OPEN || item.kind === K_CLOSE) && !item.bare && edgeShows(item.style)) {
      return true;
    }
  }
  return false;
}

/** Whether an inline box has a margin, padding or border that renders even around no content. */
function edgeShows(el: Node): boolean {
  for (let p = P.P_MARGIN_TOP; p <= P.P_MARGIN_LEFT; p++) {
    if (el.sv[p] !== 0) return true;
  }
  for (let p = P.P_PADDING_TOP; p <= P.P_PADDING_LEFT; p++) {
    if (el.sv[p] !== 0) return true;
  }
  for (let p = P.P_BORDER_TOP_WIDTH; p <= P.P_BORDER_LEFT_WIDTH; p++) {
    if (el.sv[p] > 0) return true;
  }
  return false;
}

/**
 * Drops a collapsible space run that follows another one with only inline box edges between:
 * white space is collapsed across element boundaries (<span>a </span> <b>b</b> has one space
 * between the words), and it stays with the text before the edge.
 */
function collapseSpaces(pieces: Piece[]): Piece[] {
  const out: Piece[] = [];
  let afterSpace = false; // the last piece that isn't an inline edge is a collapsible space
  for (const p of pieces) {
    if (p.kind === K_OPEN || p.kind === K_CLOSE) {
      out.push(p);
      continue;
    }
    if (p.kind === K_SPACE && afterSpace) continue;
    afterSpace = p.kind === K_SPACE;
    out.push(p);
  }
  return out;
}

/**
 * Breaks pieces into lines of placed items. `avail` may be Infinity (max-content). When `avails`
 * is given it holds the width of each line, which floats can narrow; a line past its end uses
 * the last width.
 */
/**
 * How a run may break inside a word: 1 for `break-all` and `anywhere`, which break wherever the
 * line ends; 2 for `break-word`, which breaks only a word too wide for a line of its own.
 */
function insideBreak(style: Node): number {
  if (breaksAnywhere(style)) return 1;
  const wb = style.sv[P.P_WORD_BREAK];
  if (wb === P.WB_BREAK_WORD || style.sv[P.P_OVERFLOW_WRAP] === P.OW_BREAK_WORD) return 2;
  return 0;
}

/** Whether a line may start at any character, which also makes a run's min-content one glyph. */
export function breaksAnywhere(style: Node): boolean {
  return style.sv[P.P_WORD_BREAK] === P.WB_BREAK_ALL || style.sv[P.P_OVERFLOW_WRAP] === P.OW_ANYWHERE ||
    style.sv[P.P_LINE_BREAK] === P.LB_ANYWHERE;
}

/**
 * Splits the text of each run that may break inside a word into one piece per character, so the
 * line breaker has a break opportunity after each of them.
 */
function splitWords(pieces: Piece[], avail: number, firstIndent: number): Piece[] {
  let out: Piece[] | null = null;
  for (let i = 0; i < pieces.length; i++) {
    const p = pieces[i];
    const mode = p.kind === K_TEXT && p.text.length > 1 ? insideBreak(p.style) : 0;
    // `break-word` only breaks a word that couldn't fit a line by itself; measuring min-content
    // (avail 0) must not force a break, or a table column would shrink to one character.
    const splits = mode === 1 || (mode === 2 && avail > 0 && avail !== Infinity && p.w > avail - firstIndent);
    if (!splits) {
      if (out !== null) out.push(p);
      continue;
    }
    if (out === null) out = pieces.slice(0, i);
    for (const ch of p.text) {
      const c = new Piece(K_TEXT, p.style, p.owner, ch);
      c.w = textWidth(p.style, ch);
      c.brk = true;
      out.push(c);
    }
  }
  return out === null ? pieces : out;
}

/** Whether a line may start at any character — `word-break: break-all` or `line-break: anywhere`,
 *  which shape every line — as opposed to `overflow-wrap: anywhere`, which only breaks a word too
 *  wide for a line of its own. */
function breaksEverywhere(style: Node): boolean {
  return style.sv[P.P_WORD_BREAK] === P.WB_BREAK_ALL || style.sv[P.P_LINE_BREAK] === P.LB_ANYWHERE;
}

/** Whether a run's lines may not wrap: `white-space: nowrap` or `text-wrap: nowrap`. */
function noWrapStyle(style: Node): boolean {
  return style.sv[P.P_WHITE_SPACE] === P.W_NOWRAP || style.sv[P.P_TEXT_WRAP_MODE] === P.TWM_NOWRAP;
}

export function breakLines(pieces: Piece[], avail: number, avails?: number[], firstIndent: number = 0): Line[] {
  pieces = splitWords(collapseSpaces(pieces), avail, firstIndent);
  markRunBoundaryBreaks(pieces);
  const lines: Line[] = [new Line()];
  // The first line starts `firstIndent` in, so that much less of it fits.
  const lineAvail = (): number => {
    const i = lines.length - 1;
    const base = avails === undefined || avails.length === 0
      ? avail
      : i < avails.length ? avails[i] : avails[avails.length - 1];
    return i === 0 ? base - firstIndent : base;
  };
  let lineW = 0;
  let segment: Piece[] = [];
  let segW = 0;
  let space: Piece | null = null;
  // The last character placed on the current line: what a break at the next segment's start is
  // measured from (an atomic box stands in as U+FFFC).
  let lineLast = "";
  // The letter spacing a run carries after its last character hangs past the line's end instead
  // of taking room in it (CSS Text 3 §8.2), so a line fits that much more text than the sum of
  // its items measures. Only positive spacing can hang: a negative one takes room away from the
  // run, and not counting it would make the line read wider than the text it holds — a heading
  // with `letter-spacing: -0.025em` would wrap between two words it measures in one.
  const segmentTrail = (): number => {
    for (let i = segment.length - 1; i >= 0; i--) {
      const p = segment[i];
      if (p.kind === K_TEXT || p.kind === K_SHY) return spacingPx(p.style, P.P_LETTER_SPACING);
      if (p.kind !== K_OPEN && p.kind !== K_CLOSE && p.kind !== K_ABS) return 0;
    }
    return 0;
  };
  const lineTrail = (): number => {
    const items = lines[lines.length - 1].items;
    for (let i = items.length - 1; i >= 0; i--) {
      const it = items[i];
      if (it.kind === K_TEXT) return spacingPx(it.style, P.P_LETTER_SPACING);
      if (it.kind !== K_OPEN && it.kind !== K_CLOSE && it.kind !== K_ABS) return 0;
    }
    return 0;
  };

  const place = (p: Piece) => {
    const line = lines[lines.length - 1].items;
    const last = line.length > 0 ? line[line.length - 1] : null;
    const text = p.kind === K_TEXT || p.kind === K_SHY;
    if (text && last !== null && last.kind === K_TEXT && last.style === p.style) {
      // Merge into the previous text item so a run draws (and kerns) as one string.
      last.text += p.text;
      const w = textWidth(p.style, last.text);
      lineW += w - last.w;
      last.w = w;
      lineLast = lastCodePoint(last.text);
      return;
    }
    const kind = p.kind === K_SPACE || p.kind === K_PSPACE || p.kind === K_BSPACE || p.kind === K_SHY
      ? K_TEXT : p.kind;
    const item = new Placed(kind, p.style, p.owner, p.text, lineW, p.w,
      p.kind === K_ATOMIC || p.kind === K_ATABLE ? p.wMin : p.w);
    item.h = p.h;
    item.asc = p.asc;
    item.run = p.run;
    item.bare = p.bare;
    line.push(item);
    lineW += p.w;
    if (p.kind === K_TEXT || p.kind === K_SHY) lineLast = lastCodePoint(p.text);
    else if (p.kind === K_ATOMIC || p.kind === K_ATABLE) lineLast = "￼";
  };

  /** The first content piece of the segment: the one a line would start at. */
  const segmentFirst = (): Piece | null => {
    for (const p of segment) {
      if (p.kind === K_OPEN || p.kind === K_CLOSE || p.kind === K_ABS) continue;
      return p;
    }
    return null;
  };

  /** Whether a line may break between what it holds and the segment queued after it. */
  const breakBeforeSegment = (): boolean => {
    const first = segmentFirst();
    if (first === null) return true;
    // A space is a break opportunity of its own, and so is a piece the text already marked.
    if (space !== null || first.brk) return true;
    // A space that ended the line is a break opportunity of its own.
    if (lineLast === " " || lineLast === "　") return true;
    const edge = first.kind !== K_TEXT && first.kind !== K_SHY;
    const ch = first.kind === K_TEXT ? firstCodePoint(first.text) : first.kind === K_SHY ? "-" : "￼";
    // Beside an atomic inline CSS gives the break itself, past UAX #14's own answer.
    if (edge || lineLast === "￼") return atomicBoundary(ch === "￼" ? lineLast : ch);
    return boundaryBreak(first.style, lineLast, ch);
  };

  // A preserved space is placed where it stands and hangs past the line edge when the line is
  // full: a line's break goes before the next text, not before the space that ends this one.
  const placeSpace = (p: Piece) => {
    place(p);
  };

  // A break-spaces space that doesn't fit stays on the line as a hanging space, unless the text
  // may break inside a word: `overflow-wrap: break-word` and `line-break: anywhere` give a break
  // opportunity just before the space, and a browser takes it, so the space opens the next line.
  const placeBreakSpaces = (p: Piece) => {
    if (lineHasContent(lines[lines.length - 1]) && lineW + p.w > lineAvail() + 0.5 &&
      (breaksAnywhere(p.style) || insideBreak(p.style) === 2)) {
      lines.push(new Line());
      lineW = 0;
      lineLast = "";
    }
    place(p);
  };

  const commit = () => {
    // Nothing to place: a pending space stays pending, so it can join the next segment (a
    // space before an atomic box, for instance). A collapsible one that ends up at a line
    // edge is dropped when it is finally committed or when the run ends.
    if (segment.length === 0) return;
    const current = lines[lines.length - 1];
    const preserved = space !== null && space.kind !== K_SPACE;
    const content = lineHasContent(current);
    // A collapsible space before nothing but a closing (or empty) inline box is at the line's
    // edge, so it is dropped — the box's edges take no room of their own.
    let segContent = false;
    for (const p of segment) {
      if (p.kind === K_TEXT || p.kind === K_ATOMIC || p.kind === K_ATABLE) {
        segContent = true;
        break;
      }
    }
    if (space !== null && space.kind === K_BSPACE) {
      // break-spaces: the break opportunity follows every space, so the space is placed on its
      // own and only the segment after it can move to the next line.
      placeBreakSpaces(space);
      space = null;
      if (lineHasContent(lines[lines.length - 1]) && lineW + segW > lineAvail() + 0.5) {
        lines.push(new Line());
        lineW = 0;
        lineLast = "";
      }
    } else {
      // A collapsible space that ends up at a line's edge is dropped, so it takes no room and
      // can't push the segment after it onto the next line.
      const sp = space;
      const kept = sp !== null && (preserved || (content && segContent));
      const sw = sp !== null && kept ? sp.w : 0;
      // `nowrap` collapses its spaces but gives no break opportunity, so an overflowing
      // segment stays on the line it is on. `text-wrap: nowrap` says the same thing.
      const nowrap = noWrapStyle(space !== null ? space.style : segment[0].style);
      // A line that begins with a preserved space has content of its own: the space stays on the
      // line and the text after it wraps when the two don't fit (css-text 3, white-space phase 2).
      const holds = content || (space !== null && space.kind !== K_SPACE);
      if (!nowrap && holds && lineW - Math.max(0, lineTrail()) + sw + segW - Math.max(0, segmentTrail()) > lineAvail() + 0.5 &&
        breakBeforeSegment()) {
        // pre-wrap leaves the spaces that caused the break hanging on the line just ended. The
        // line is not a forced one: a break at a space is what the wrap does, so `text-align-last`
        // leaves the line alone and a justified line justifies it like any other.
        if (space !== null && space.kind === K_PSPACE) place(space);
        lines.push(new Line());
        lineW = 0;
        lineLast = "";
      } else if (sp !== null && kept) {
        place(sp);
      }
    }
    const target = lines[lines.length - 1];
    if (!lineHasContent(target)) target.first = segW;
    // A soft hyphen shows only where the line breaks, which `place` is told by showing it.
    for (const p of segment) if (p.kind !== K_SHY) place(p);
    // The pieces were copied onto the line, so the list is emptied rather than made anew.
    segment.length = 0;
    segW = 0;
    space = null;
  };

  for (const p of pieces) {
    if (p.kind === K_SPACE || p.kind === K_PSPACE || p.kind === K_BSPACE) {
      // A break-spaces space is preserved and can't hang past the line's end, so the text before
      // it only stays on this line when the space fits after it too. When it doesn't, the break
      // goes at the opportunity before that text, as a browser's line breaker does: the space
      // that was already a break opportunity stays on the line and the text moves down.
      if (p.kind === K_BSPACE && segment.length > 0 && lineHasContent(lines[lines.length - 1]) &&
        !noWrapStyle(p.style) && !breaksEverywhere(p.style)) {
        const pending = space !== null ? space.w : 0;
        // The break goes after the space only when the space itself fits on the line; a space that
        // does not fit is a break of its own, taken below.
        if (lineW + pending <= lineAvail() + 0.5 && lineW + pending + segW + p.w > lineAvail() + 0.5) {
          if (space !== null && space.kind !== K_SPACE) place(space);
          space = null;
          lines.push(new Line());
          lineW = 0;
          lineLast = "";
        }
      }
      commit();
      if (space === null) space = p;
      else if (p.kind !== K_SPACE) {
        // Preserved spaces don't collapse into each other.
        if (space.kind === K_BSPACE) placeBreakSpaces(space);
        else placeSpace(space);
        // With break-spaces every space is a break opportunity of its own, so once one has filled
        // the line, the next space starts a new one (a line may begin with a preserved space).
        if (space.kind === K_BSPACE && p.kind === K_BSPACE && lineW + p.w > lineAvail() + 0.5 &&
          !noWrapStyle(p.style)) {
          lines.push(new Line());
          lineW = 0;
          lineLast = "";
        }
        space = p;
      } else if (space.kind !== K_SPACE) {
        // A collapsible space between preserved ones isn't at a line edge, so the preserved
        // space is placed and the collapsible one stays pending.
        if (lineHasContent(lines[lines.length - 1])) place(space);
        space = p;
      }
    } else if (p.kind === K_ATOMIC || p.kind === K_ATABLE) {
      commit();
      segment = [p];
      segW = p.w;
      commit();
    } else if (p.kind === K_BREAK) {
      commit();
      // A preserved space just before a forced break is part of the line being ended.
      if (space !== null && space.kind !== K_SPACE) {
    if (space.kind === K_BSPACE) placeBreakSpaces(space);
    else placeSpace(space);
  }
      space = null;
      lines[lines.length - 1].forced = true;
      // A <br> with `clear` ends the line just as the floats of that side are passed: what comes
      // after it starts below them.
      const next = new Line();
      next.clear = p.style.sv[P.P_CLEAR];
      lines.push(next);
      lineW = 0;
    } else {
      segment.push(p);
      segW += p.w;
      // A break inside a word: the queued text no longer fits the line, so the last piece
      // starts the next one. This also holds on an empty line, where each character becomes a
      // line of its own once it is past the edge: that is what break-all's min-content is.
      if (p.brk) {
        const content = lineHasContent(lines[lines.length - 1]);
        const sw = content && space !== null ? space.w : 0;
        if ((content || segW > p.w) && lineW - Math.max(0, lineTrail()) + sw + segW - Math.max(0, segmentTrail()) > lineAvail() + 0.5) {
          segment.pop();
          segW -= p.w;
          // A soft hyphen just before the piece shows, since the line breaks before it.
          let shy: Piece | null = null;
          if (segment.length > 0 && segment[segment.length - 1].kind === K_SHY) {
            const popped = segment.pop();
            if (popped !== undefined) shy = popped;
          }
          if (shy !== null) segW -= shy.w;
          commit();
          if (shy !== null && lineHasContent(lines[lines.length - 1])) place(shy);
          segment = [p];
          segW = p.w;
        }
      }
    }
  }
  commit();
  // Trailing preserved spaces are part of the last line; collapsible ones are not.
  if (space !== null && space.kind !== K_SPACE) {
    if (space.kind === K_BSPACE) placeBreakSpaces(space);
    else placeSpace(space);
  }
  // A forced break at the very end ends the last line rather than starting an empty one. A
  // cleared break keeps its line, since the floats it clears are what the content after the run
  // has to start below.
  if (lines.length > 1 && lines[lines.length - 1].items.length === 0 &&
    lines[lines.length - 1].clear === P.CL_NONE) lines.length--;
  return lines;
}

/**
 * text-wrap: balance. The block keeps the number of lines it wraps to, and its words are handed
 * out so that every line is about as wide as the others: the line that starts with the last word
 * of the text is the one that grows, instead of a long first line and a short last one. A browser
 * balances only a short block, and never one with a forced break in it.
 */
export function balanceLines(pieces: Piece[], avail: number, lines: Line[], indent: number): Line[] {
  // A forced break starts a new group of lines, and each group is balanced on its own: the
  // lines either side of it are not each other's business, and the six-line limit is each
  // group's own.
  const out: Line[] = [];
  let start = 0;
  let ind = indent;
  for (let i = 0; i < pieces.length; i++) {
    if (pieces[i].kind !== K_BREAK) continue;
    out.push(...balanceSegment(pieces.slice(start, i + 1), avail, ind));
    start = i + 1;
    ind = 0;
  }
  if (start < pieces.length) out.push(...balanceSegment(pieces.slice(start), avail, ind));
  return out.length === lines.length ? out : lines;
}

/**
 * The lines one group of pieces wraps to, balanced: the smallest width that still takes the
 * same number of lines leaves them as even as the text allows. A group a word can't be broken
 * in, or one outside the six lines balancing covers, keeps the lines it came with.
 */
function balanceSegment(seg: Piece[], avail: number, indent: number): Line[] {
  const natural = breakLines(seg, avail, undefined, indent);
  if (natural.length < 2 || natural.length > 6) return natural;
  let lo = 1;
  let hi = avail;
  for (let i = 0; i < 14 && hi - lo > 0.25; i++) {
    const mid = (lo + hi) / 2;
    if (breakLines(seg, mid, undefined, indent).length <= natural.length) hi = mid;
    else lo = mid;
  }
  const best = breakLines(seg, hi, undefined, indent);
  return best.length === natural.length ? best : natural;
}

/**
 * text-wrap: pretty. A block whose last line holds a single word moves the word before it down,
 * so the text doesn't end on a lone word. One word moves, and only when the two fit the line.
 */
export function prettyLines(pieces: Piece[], avail: number, lines: Line[], indent: number): Line[] {
  if (lines.length < 2 || lines[lines.length - 1].forced) return lines;
  // The last line's words, which a run of merged text makes hard to count any other way.
  let words = 0;
  for (const item of lines[lines.length - 1].items) {
    if (item.kind === K_OPEN || item.kind === K_CLOSE) continue;
    if (item.kind !== K_TEXT) { words++; continue; }
    const t = item.text.replace(/^ +| +$/g, "");
    if (t !== "") words += t.split(/ +/).length;
  }
  if (words !== 1) return lines;
  const isSpace = (k: number) => k === K_SPACE || k === K_PSPACE || k === K_BSPACE || k === K_BREAK;
  const isEdge = (k: number) => k === K_OPEN || k === K_CLOSE;
  // Walk back over the last word, the space before it and the word before that, to the space
  // that word follows: the break there puts both words on the last line.
  let i = pieces.length - 1;
  while (i >= 0 && isEdge(pieces[i].kind)) i--;
  while (i >= 0 && !isSpace(pieces[i].kind)) i--;
  const sp2 = i;
  if (sp2 <= 0) return lines;
  i--;
  while (i >= 0 && isEdge(pieces[i].kind)) i--;
  while (i >= 0 && !isSpace(pieces[i].kind)) i--;
  const sp1 = i;
  if (sp1 < 0) return lines;
  let w = 0;
  for (let k = sp1 + 1; k < pieces.length; k++) w += pieces[k].w;
  if (w > avail + 0.5) return lines;
  const cut = pieces.slice();
  cut[sp1] = new Piece(K_BREAK, pieces[sp1].style, pieces[sp1].owner, "");
  return breakLines(cut, avail, undefined, indent);
}

/**
 * Records one piece of inline content the container draws: a run of text, an inline box's edge,
 * or an atomic box (an inline-block, an image, a table) that the inline boxes around it span.
 */
function addFragment(el: Node, kind: number, style: Node, owner: Node, text: string,
  x: number, top: number, w: number, line: number): void {
  el.fragKind.push(kind);
  el.fragStyle.push(style);
  el.fragOwner.push(owner);
  el.fragText.push(text);
  el.fragX.push(x);
  el.fragTop.push(top);
  el.fragW.push(w);
  el.fragLine.push(line);
}

export function measurePieces(pieces: Piece[], cbW: number, layoutAtomics: boolean, cbH: number = NaN): void {
  for (const p of pieces) {
    if (p.kind === K_TEXT || p.kind === K_SPACE || p.kind === K_PSPACE || p.kind === K_BSPACE ||
      p.kind === K_SHY) {
      p.w = textWidth(p.style, p.text);
    }
    else if (p.kind === K_OPEN) p.w = p.bare ? 0 : edgeWidth(p.style, true, cbW);
    else if (p.kind === K_CLOSE) p.w = p.bare ? 0 : edgeWidth(p.style, false, cbW);
    else if (p.kind === K_ATOMIC) {
      if (layoutAtomics) {
        layoutBox(p.style, cbW, cbH, NaN, NaN, true);
        p.w = p.style.w + marginH(p.style, cbW);
      } else {
        // An atomic box's percentage width is indefinite while its line's container is being
        // measured, so it contributes the width its content asks for.
        p.w = intrinsicMaxWidth(p.style, cbW, cbH) + marginH(p.style, cbW);
      }
      p.wMin = intrinsicMinWidth(p.style, cbW, cbH) + marginH(p.style, cbW);
    } else if (p.kind === K_ATABLE) {
      const run = p.run!;
      if (layoutAtomics) {
        const info: number[] = [];
        p.h = layoutInlineTableRun(p.owner, run, cbW, 0, info);
        p.w = info[0];
        p.asc = info[1];
      } else {
        p.w = tableRunContentWidth(p.owner, run, cbW, false);
        p.wMin = tableRunContentWidth(p.owner, run, cbW, true);
      }
    }
  }
}

/** The pieces of a run of inline-level children, for intrinsic sizes (see table layout). */
export function gatherPieces(items: Node[], out: Piece[]): void {
  gather(items, out);
}

/** Min-content width of measured pieces: their widest unbreakable segment. */
export function piecesMinContent(pieces: Piece[]): number {
  let max = 0;
  for (const line of breakLines(pieces, 0)) {
    // Each line is one unbreakable segment: its narrowest width is the sum of its parts, where a
    // nested table can still shrink to its own minimum.
    // Spaces at the end of a line take no room: a collapsible one is dropped there, and a
    // pre-wrap one hangs past the line edge (CSS Text 3 §4.1.3), so neither widens the line.
    // Zero-width edges and out-of-flow markers after them don't stop the space from ending the line.
    const skip = new Set<number>();
    for (let i = line.items.length - 1; i >= 0; i--) {
      const item = line.items[i];
      if (hangsAtLineEnd(item)) skip.add(i);
      else if (!((item.kind === K_CLOSE || item.kind === K_OPEN || item.kind === K_ABS) && item.w === 0)) break;
    }
    let w = 0;
    for (let i = 0; i < line.items.length; i++) {
      if (skip.has(i)) continue;
      const item = line.items[i];
      // An atomic box can't break, but it can be as narrow as its own min-content width; so can a
      // nested table, which the anonymous inline-table's own minimum measured.
      const iw = item.kind === K_ATOMIC || item.kind === K_ATABLE ? item.wMin : item.w;
      w = Math.max(w, item.x + iw);
    }
    if (w > max) max = w;
  }
  return max;
}

/** Whether a line item at the end of its line is white space that takes no room there. */
function hangsAtLineEnd(item: Placed): boolean {
  if (item.kind === K_SPACE) return true;
  const preWrap = item.style.sv[P.P_WHITE_SPACE] === P.W_PRE_WRAP;
  if (item.kind === K_PSPACE) return preWrap;
  // A pre-wrap run of spaces and tabs on its own (one inside an inline, say) hangs the same way.
  if (item.kind === K_TEXT) return preWrap && item.text.length > 0 && !/[^ \t]/.test(item.text);
  return false;
}

/** Max-content width of measured pieces: their width on one line. */
export function piecesMaxContent(pieces: Piece[]): number {
  let max = 0;
  for (const line of breakLines(pieces, Infinity)) {
    let w = 0;
    for (const item of line.items) w = Math.max(w, item.x + item.w);
    if (w > max) max = w;
  }
  return max;
}

/** An atomic piece that is a float: it is not part of the line's text, so the text either side
 * of it forms one run, with the spaces around it collapsing together (CSS 2.1 9.5). */
function isFloatPiece(p: Piece): boolean {
  return p.kind === K_ATOMIC && p.owner !== null && isFloat(p.owner);
}

/** The line's own pieces, and the floats met along it. */
function splitFloats(pieces: Piece[]): Piece[][] {
  const line: Piece[] = [];
  const floats: Piece[] = [];
  for (const p of pieces) {
    if (isFloatPiece(p)) floats.push(p);
    else line.push(p);
  }
  return [line, floats];
}

/** The width of the widest line a run of inline pieces makes with no break opportunity. */
function runLineWidth(el: Node, run: Piece[]): number {
  let lineMax = 0;
  const lines = breakLines(run, Infinity);
  for (let li = 0; li < lines.length; li++) {
    const l = lines[li];
    // The separators that end a line hang past it, so they take no room — but the last line is
    // the one the text's own end finishes, and there is no line end there while the box is
    // being sized to its widest line.
    let end = l.items.length;
    // break-spaces wraps its preserved spaces rather than hanging them, so they always count.
    if (li < lines.length - 1 && el.sv[P.P_WHITE_SPACE] !== P.W_BREAK_SPACES) {
      while (end > 0 && hangsAtEnd(l.items[end - 1])) end--;
    }
    let w = 0;
    for (let i = 0; i < end; i++) w = Math.max(w, l.items[i].x + l.items[i].w);
    if (w > lineMax) lineMax = w;
  }
  return lineMax;
}

export function inlineMaxContent(el: Node, cbW: number, cbH: number = NaN, items = visibleChildren(el)): number {
  const pieces: Piece[] = [];
  gather(items, pieces);
  measurePieces(pieces, cbW, false, cbH);
  // The inline content shares a formatting context with the floats in it, and with no break
  // opportunity it fills one line — the box's first line box. The floats beside that line are the
  // ones that come before a float clearing a side one of them is on; a clearing float drops to its
  // own row below, and the content after it still belongs to the first line (CSS 2.1 9.5). So the
  // box is as wide as the widest row, not as wide as every float and the text together.
  let text = 0;
  let have = false;
  for (const p of pieces) {
    if (isFloatPiece(p)) continue;
    have = true;
    break;
  }
  if (have) {
    const line: Piece[] = [];
    for (const p of pieces) if (!isFloatPiece(p)) line.push(p);
    text = runLineWidth(el, line);
  }
  let row = 0;
  let widest = 0;
  let leftFloat = false;
  let rightFloat = false;
  for (const p of pieces) {
    if (!isFloatPiece(p)) continue;
    const clear = p.style.sv[P.P_CLEAR];
    if ((clear === P.CL_LEFT && leftFloat) || (clear === P.CL_RIGHT && rightFloat) ||
      (clear === P.CL_BOTH && (leftFloat || rightFloat))) {
      // The first row is the one the text is on; the floats after a clear start below it.
      row += text;
      text = 0;
      widest = Math.max(widest, row);
      row = 0;
      leftFloat = false;
      rightFloat = false;
    }
    row += p.w;
    const side = p.style.sv[P.P_FLOAT];
    if (side === P.FL_LEFT) leftFloat = true;
    else if (side === P.FL_RIGHT) rightFloat = true;
  }
  row += text;
  return Math.max(widest, row);
}

/**
 * The line count a `line-clamp: auto` box keeps: as many of its lines as its max-height holds,
 * and none when it has no definite max-height.
 */
export function autoClamp(el: Node): number {
  if (el.su[P.P_MAX_HEIGHT] !== P.U_PX) return 0;
  const lh = lineHeightPx(el);
  return lh > 0 ? Math.max(0, Math.floor((el.sv[P.P_MAX_HEIGHT] + 0.5) / lh)) : 0;
}

/** Min-content width of inline content: the widest run of pieces that can't be broken. */
export function inlineMinContent(el: Node, cbW: number, cbH: number = NaN, items = visibleChildren(el)): number {
  const pieces: Piece[] = [];
  gather(items, pieces);
  measurePieces(pieces, cbW, false, cbH);
  const run = splitFloats(pieces);
  // A run the line can't break in—nowrap, pre, one word—is as wide as all its pieces together,
  // so measure the whole line rather than its widest piece.
  let max = piecesMinContent(run[0]);
  // A float can't be broken either, so the widest one sets a floor of its own.
  for (const f of run[1]) if (f.wMin > max) max = f.wMin;
  return max;
}

/** Baseline position of an atomic inline box, from the top of its margin box. */
export function atomicBaseline(c: Node, cbW: number): number {
  // A box showing an older layout's outputs lays out for real before its content is read.
  if (c.lPending >= 0) settleNode(c);
  const mt = zeroIfNaN(len(c, P.P_MARGIN_TOP, cbW));
  if (c instanceof HTMLInputElement) return mt + c.contentY + (c.contentH - lineHeightPx(c)) / 2 + baselineOffset(c);
  if (c.lines.length > 0) {
    const lh = lineHeightPx(c);
    const center = c.tagName === "BUTTON" ? Math.max(0, (c.contentH - c.lines.length * lh) / 2) : 0;
    return mt + c.contentY + center + (c.lines.length - 1) * lh + baselineOffset(c);
  }
  if (c.lineBaseline.length > 0) {
    // A block box is aligned on its last line box; a grid or flex container on the baseline its
    // first row or line has (CSS Flexbox 8.5, CSS Grid 10.1), which is the first one it holds.
    const byFirst = isGridContainer(c) || isLanesContainer(c) || isFlexContainer(c);
    return mt + c.lineBaseline[byFirst ? 0 : c.lineBaseline.length - 1];
  }
  return mt + c.h + zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, cbW));
}

/**
 * The distance the baseline of `box` is raised above its parent's baseline, from vertical-align.
 * `top` and `bottom` are settled against the line box, so they count as 0 here.
 */
function alignShift(box: Node, parent: Node | null): number {
  const v = box.sv[P.P_VERTICAL_ALIGN];
  const u = box.su[P.P_VERTICAL_ALIGN];
  if (u === P.U_PCT) return (v / 100) * lineHeightPx(box);
  if (u !== P.U_NONE) return v;
  const size = box.sv[P.P_FONT_SIZE];
  const m = fontMetrics(box);
  const pm = parent !== null ? fontMetrics(parent) : m;
  switch (v) {
    // sub and super sit at the traditional small offsets from the baseline; the font's own
    // subscript metrics aren't exposed by the host.
    case P.VA_SUB: return -size * 0.2;
    case P.VA_SUPER: return size * 0.33;
    // text-top and text-bottom line up with the parent's content area, which is the font box.
    case P.VA_TEXT_TOP: return pm[0] - m[0];
    case P.VA_TEXT_BOTTOM: return m[1] - pm[1];
    case P.VA_MIDDLE: return (pm[2] - m[2]) / 2;
    default: return 0;
  }
}

/** One inline-level item's vertical metrics within a line box. */
class ItemAlign {
  /** Distance from the item's box top to its baseline. */
  a: number;
  /** The item's box height. */
  h: number;
  /** The baseline's rise above the line's baseline. */
  shift = 0;
  /** VA_TOP or VA_BOTTOM when the box is aligned to the line box itself. */
  rel = P.VA_BASELINE;
  /** The inline box that is aligned to the line box, when `rel` isn't baseline. */
  relBox: Node | null = null;
  /** The style source of the item, which is its own box for an atomic one. */
  source: Node;
  constructor(a: number, h: number, source: Node) {
    this.a = a;
    this.h = h;
    this.source = source;
  }
  // The atomic box's own metrics, when the line-aligned box is the atomic item itself.
  own = false;
  /** Whether the box lines up with the glyph's content area (text-top, text-bottom). */
  textEdge = false;
  /** Whether the box stands on the far side of a reflected line box (see `mirror`). */
  fromEnd = false;
}

/**
 * vertical-align for an atomic inline box, whose box is its own geometry: text-top and
 * text-bottom line its box edges up with the parent's font box, and middle lines its box's
 * midpoint up with the parent's baseline plus half an x-height.
 */
function atomicAlignShift(box: Node, parent: Node | null, a: number, h: number): number {
  const v = box.sv[P.P_VERTICAL_ALIGN];
  if (box.su[P.P_VERTICAL_ALIGN] !== P.U_NONE) return alignShift(box, parent);
  const pm = fontMetrics(parent !== null ? parent : box);
  switch (v) {
    case P.VA_TEXT_TOP: return pm[0] - a;
    case P.VA_TEXT_BOTTOM: return h - a - pm[1];
    case P.VA_MIDDLE: return h / 2 - a + pm[2] / 2;
    default: return alignShift(box, parent);
  }
}

/**
 * The vertical metrics of an item in a line: its box, and how far vertical-align moves it.
 * Text belongs to the inline box around it, so the chain starts at that box. An anonymous
 * inline-table has no element of its own: its box is the table's, and the chain starts at the
 * element that holds the table parts.
 */
function itemAlign(place: Placed, container: Node, cbW: number): ItemAlign {
  const style = place.style;
  const kind = place.kind;
  let a: number;
  let h: number;
  if (kind === K_ATOMIC) {
    a = atomicBaseline(style, cbW);
    h = style.h + marginV(style, cbW);
  } else if (kind === K_ATABLE) {
    a = place.asc;
    h = place.h;
  } else {
    a = baselineOffset(style);
    h = lineHeightPx(style);
  }
  const item = new ItemAlign(a, h, style);
  let e: Node | null = kind === K_ATABLE ? place.owner
    : kind === K_ATOMIC || kind === K_OPEN || kind === K_CLOSE ? style
    : style.isTextNode ? style.parentElement : style;
  while (e !== null && e !== container) {
    const v = e.sv[P.P_VERTICAL_ALIGN];
    if (e.su[P.P_VERTICAL_ALIGN] === P.U_NONE && (v === P.VA_TEXT_TOP || v === P.VA_TEXT_BOTTOM)) {
      item.textEdge = true;
    }
    if (e.su[P.P_VERTICAL_ALIGN] === P.U_NONE && (v === P.VA_TOP || v === P.VA_BOTTOM)) {
      // top and bottom depend on the finished line box; the innermost such box wins.
      item.rel = v;
      item.relBox = e;
      item.own = e === style;
    } else if (e === style && kind === K_ATOMIC) {
      item.shift += atomicAlignShift(e, e.parentElement, a, h);
    } else {
      item.shift += alignShift(e, e.parentElement);
    }
    e = e.parentElement;
  }
  return item;
}

/**
 * Lays out an element's own text through the inline machinery, which it needs when floats
 * shorten its lines. `top` is the local y of the content box, and `by` its context y.
 */
export function layoutOwnText(el: Node, innerW: number, pl: number, top: number,
  ctx: FloatCtx, bx: number, by: number): number {
  const pieces: Piece[] = [];
  pushText(el, el, el.flowText, pieces);
  return layoutInlinePieces(el, pieces, innerW, pl, top, NaN, ctx, bx, by);
}

/**
 * Places already broken lines, starting at `top`. Returns the height used, then each line's top,
 * height and content width: the caller uses those to work out how much room floats leave the next
 * pass. `offs` and `avails` give the left offset and the width of each line, when floats narrow
 * it, and `starts` the lowest top a line can take when floats push it below themselves.
 */
/**
 * How far a line in a turned frame reaches across the page: the widest block size of the boxes on
 * it, or the line itself when no box is wider.
 */
function lineBlockExtent(el: Node, line: Line, innerW: number): number {
  let ext = lineHeightPx(el);
  for (const item of line.items) {
    const style = item.style;
    if (item.kind === K_ATOMIC) ext = Math.max(ext, style.h + marginV(style, innerW));
    else if (item.kind === K_ATABLE) ext = Math.max(ext, item.h + marginV(style, innerW));
    else if (item.kind === K_OPEN || item.kind === K_CLOSE) ext = Math.max(ext, lineHeightPx(style));
  }
  return ext;
}

/** Is this a word separator that inter-word justification may stretch? (CSS Text's set.) */
export function isWordSeparator(ch: string): boolean {
  const cp = ch.codePointAt(0) ?? 0;
  return cp === 0x20 || cp === 0xA0 || cp === 0x1361 || cp === 0x10100 || cp === 0x10101 ||
    cp === 0x1039F || cp === 0x1091F;
}

/** Does this piece end a line as a separator that hangs: a space or word separator, whose
 *  advance takes no room at the edge? */
function hangsAtEnd(p: Placed): boolean {
  if (p.kind !== K_TEXT || p.text === "") return false;
  for (const ch of p.text) {
    const cp = ch.codePointAt(0) ?? 0;
    if (!(cp === 0x20 || cp === 0xA0 || cp === 0x1680 || (cp >= 0x2000 && cp <= 0x200A) ||
      cp === 0x202F || cp === 0x205F || cp === 0x3000 || cp === 0x1361 || cp === 0x10100 ||
      cp === 0x10101 || cp === 0x1039F || cp === 0x1091F)) return false;
  }
  return true;
}

/** How many word separators and characters a text run holds, for justification. */
export function itemTextSpacing(text: string): [number, number] {
  let spaces = 0, chars = 0;
  for (const ch of text) {
    chars++;
    if (isWordSeparator(ch)) spaces++;
  }
  return [spaces, chars];
}

/**
 * The word separators at the end of a run, which a justified line leaves out of the count and
 * paints without its extra spacing: they hang past the line's edge.
 */
export function trailingSeparators(text: string): number {
  let n = 0;
  const chars = [...text];
  for (let i = chars.length - 1; i >= 0 && isWordSeparator(chars[i]); i--) n++;
  return n;
}

/** Does a run take a share of a justified line's spare room? `text-justify: none` says no. */
function justifiedRun(item: Placed): boolean {
  return item.kind === K_TEXT && item.style.sv[P.P_TEXT_JUSTIFY] !== P.TJUST_NONE;
}

/** How many spaces and characters a line's justified runs hold. */
function lineSpaces(line: Line): [number, number] {
  let spaces = 0, chars = 0;
  for (const item of line.items) {
    if (!justifiedRun(item)) continue;
    const [s, c] = itemTextSpacing(item.text);
    spaces += s;
    chars += c;
  }
  return [spaces, chars];
}

function placeLines(el: Node, lines: Line[], innerW: number, pl: number, top: number,
  offs: number[], avails: number[], starts: number[], innerH: number, firstIndent: number = 0,
  clears: number[] = []): number[] {
  const align = lineAlign(el);
  // The last line of the block, and each line a forced break ends, can be aligned on its own.
  const alignLast = lastLineAlign(el);
  const justify = el.sv[P.P_TEXT_JUSTIFY];
  el.lineExtraWord.length = 0;
  el.lineExtraLetter.length = 0;
  const rtl = isRtl(el);
  const strutA = baselineOffset(el);
  const strutD = lineHeightPx(el) - strutA;
  // `top` names the line box's over side and `bottom` its under side, and in vertical text the
  // over side is the page's right — the page's left in sideways-lr (css-writing-modes 6.4) — not
  // the frame's own block-start, so a turned frame settles the two against the other edge.
  const vturn = el.vtext !== 0;
  // A turned frame whose block axis runs towards the page's left (vertical-rl, sideways-rl and
  // sideways-lr) lays its line boxes out as the horizontal line does and then reflects them
  // within the line box, which keeps `middle`, `super` and text-top/text-bottom on the page side
  // Chrome gives them; vertical-lr, whose block axis runs the other way, needs no reflection.
  const mirror = vturn && el.sv[P.P_WRITING_MODE] !== P.WM_VERTICAL_LR;
  const out: number[] = [0];
  let y = top;
  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    // A line box that the floats leave too little room for goes below them.
    if (starts.length > li && top + starts[li] > y) y = top + starts[li];
    // A line after a cleared break starts below the floats that break clears.
    if (clears.length > li && top + clears[li] > y) y = top + clears[li];
    // The first line's indent shifts it and narrows the room its alignment works in. An rtl line
    // takes the indent off its start edge, the right one, so only the room shrinks.
    const ind = li === 0 ? firstIndent : 0;
    const lineOff = (offs.length > li ? offs[li] : 0) + (rtl ? 0 : ind);
    const availW = (avails.length > li ? avails[li] : innerW) - ind;
    // An empty line only counts when a forced break made it (<br>, a preserved newline).
    if (!lineShows(line) && !line.forced) {
      // An inline box around nothing still has a fragment on the line, zero wide at the line's
      // top: a DOM query reports one empty rect for it, as Chrome does. The line takes no
      // height, so the fragment doesn't belong to a painted line.
      for (const item of line.items) {
        if (item.kind === K_ABS) {
          // An out-of-flow box here still needs its static position (the top of where the line
          // would have been).
          item.style.staticX = item.style.wasInline ? pl + item.x : pl;
          item.style.staticY = y;
          item.style.staticValid = true;
          continue;
        }
        if (item.kind !== K_OPEN && item.kind !== K_CLOSE) continue;
        addFragment(el, FRAG_EDGE, item.style, item.owner, item.kind === K_OPEN ? "<" : ">",
          pl + lineOff + item.x, y + strutA - baselineOffset(item.style), 0, EMPTY_LINE);
      }
      out.push(y);
      out.push(0);
      out.push(0);
      continue;
    }
    // Each item's box, moved by its vertical-align. The line's baseline is `above` below the
    // top of the line box. top and bottom are relative to the line box, so they are settled
    // against the height they help determine, in a short fixed-point loop.
    const aligns: ItemAlign[] = [];
    let width = 0;
    for (const item of line.items) {
      if (item.kind === K_ABS) continue;
      width = Math.max(width, item.x + item.w);
      const it = itemAlign(item, el, innerW);
      // A text-top or text-bottom box lines up with the glyph's own content area, and in a
      // reflected line (the -rl modes and sideways-lr) that area faces the line box's far side, so
      // the box is measured from that edge. Every other shift follows the line's over side instead
      // (CSS Writing Modes 7.5), which the settle above has already put on the page's right.
      if (mirror && it.textEdge) {
        it.fromEnd = true;
        it.a = it.h - it.a;
        it.shift = -it.shift;
      } else if (vturn && !mirror && !it.textEdge) {
        // Only vertical-lr reaches the line's over side from its block-end, so only there does a
        // baseline shift run the other way.
        it.shift = -it.shift;
      }
      aligns.push(it);
    }
    // A line's over side is the page's right in vertical-rl, vertical-lr and sideways-rl, and the
    // page's left in sideways-lr (css-writing-modes 6.4), and `top`/`bottom` name those sides, not
    // the frame's own block-start. The frame's block axis runs towards the page's right in a
    // vertical-lr box, so its `top` is the side the frame's block axis ends on: the two swap there
    // and nowhere else.
    const swapTop = el.vtext !== 0 && el.sv[P.P_WRITING_MODE] === P.WM_VERTICAL_LR;
    let above = strutA;
    let below = strutD;
    for (let pass = 0; pass < 3; pass++) {
      // The strut and the baseline-aligned boxes set the baseline; a box aligned to the top or
      // bottom of the line box then moves to that edge, and the line box grows to hold it
      // (CSS 2.1 10.8). So those boxes don't move the baseline while it is being settled.
      above = strutA;
      below = strutD;
      for (const it of aligns) {
        if (it.rel !== P.VA_BASELINE) continue;
        above = Math.max(above, it.shift + it.a);
        below = Math.max(below, it.h - it.a - it.shift);
      }
      let settled = true;
      for (const it of aligns) {
        if (it.relBox === null) continue;
        const ownBox = it.own && it.relBox === it.source;
        const boxA = ownBox ? it.a : baselineOffset(it.relBox);
        const boxH = ownBox ? it.h : lineHeightPx(it.relBox);
        const atStart = swapTop ? it.rel === P.VA_BOTTOM : it.rel === P.VA_TOP;
        const next = atStart ? above - boxA : boxH - boxA - below;
        if (next !== it.shift) settled = false;
        it.shift = next;
      }
      for (const it of aligns) {
        const atStart = swapTop ? it.rel === P.VA_BOTTOM : it.rel === P.VA_TOP;
        if (atStart) below = Math.max(below, it.h - it.a - it.shift);
        else if (it.rel !== P.VA_BASELINE) above = Math.max(above, it.shift + it.a);
      }
      if (settled) break;
    }
    // A line in a turned frame stacks across the page by the widest box on it, and that box's
    // extent is a block size: the baseline arithmetic above measures the inline axis, which is
    // the line's other direction there.
    const advance = el.vtext !== 0 ? lineBlockExtent(el, line, innerW) : above + below;
    const baseline = y + above;
    // `text-align-last` takes the last line of the block and the lines a forced break ends. With
    // no `text-align-last` of its own, a justified block's last line starts where its text does.
    const lastLine = li === lines.length - 1 || line.forced;
    const lineAlignNow = alignLast >= 0 && lastLine ? alignLast
      : lastLine && align === P.T_JUSTIFY ? (rtl ? P.T_RIGHT : P.T_LEFT) : align;
    // A justified line spreads its spare room across its spaces (or characters), except the last
    // line of the block and the lines a forced break ends: text-align-last says how those align,
    // and `auto` there starts them, as CSS leaves a justified block's last line unjustified.
    let extraWord = 0, extraLetter = 0;
    // The spaces that end a justified line hang: they take none of the spare room, and the room
    // they would have covered is what the other spaces share.
    let lastText = -1;
    for (let k = 0; k < line.items.length; k++) if (line.items[k].kind === K_TEXT) lastText = k;
    const trail = lastText >= 0 ? trailingSeparators(line.items[lastText].text) : 0;
    // The separators themselves: an ideographic space is wider than a space.
    const trailText = trail > 0 ? [...line.items[lastText].text].slice(-trail).join("") : "";
    const trailWidth = trailText === "" ? 0 : textWidth(line.items[lastText].style, trailText);
    // Justifying a vertical line would spread its spare room down the page, which this build
    // doesn't do yet; a horizontal line spreads it across.
    if (lineAlignNow === P.T_JUSTIFY && justify !== P.TJUST_NONE && el.vtext === 0 &&
      !(li === lines.length - 1 || line.forced)) {
      const free = availW - (width - trailWidth);
      const [spaces, chars] = lineSpaces(line);
      if (free > 0) {
        if (justify === P.TJUST_INTER_CHARACTER) {
          // The spare room goes between the characters, so the last character keeps its own
          // advance and the line ends at the content edge.
          const gaps = chars - trail - 1;
          if (gaps > 0) extraLetter = free / gaps;
        } else if (spaces - trail > 0) extraWord = free / (spaces - trail);
      }
    }
    let indent = 0;
    if (lineAlignNow === P.T_CENTER) indent = Math.max(0, (availW - width) / 2);
    else if (lineAlignNow === P.T_RIGHT) indent = Math.max(0, availW - width);
    // A justified line of right-to-left text fills the line from its end edge: the text runs to
    // the right edge and the separators that end it hang past the start edge, on the left.
    else if (lineAlignNow === P.T_JUSTIFY && (extraWord !== 0 || extraLetter !== 0) &&
      lastText >= 0 && strongDirection(line.items[lastText].text) === 1) indent = -trailWidth;
    const lineIndex = el.lineBaseline.length;
    el.lineBaseline.push(baseline);
    // A line running down the page aligns on its middle, which is half its block extent in.
    el.lineCentral.push(y + advance / 2);
    // The fragments of a line are numbered by the shown lines before it, so the extras are too.
    el.lineExtraWord[lineIndex] = extraWord;
    el.lineExtraLetter[lineIndex] = extraLetter;
    let aligned = 0;
    // Whether in-flow content has already gone onto this line: a block-level out-of-flow box
    // after it is placed where the next line would start, not where this one does.
    let inFlowBefore = false;
    // Each item moves right by the justification added before it: a text item's own extra glyph
    // spacing shifts everything that follows on the line.
    let shift = 0;
    for (const item of line.items) {
      const x = pl + lineOff + indent + item.x + shift;
      if (item.kind === K_ABS) {
        // How far along the line it would have gone, for a line that runs the other way.
        item.style.staticFlow = item.x;
        // An inline-level box keeps its inline position; a block-level one starts at the
        // content edge, as it would have in the block flow — on the line after this one when
        // this line has already begun, since the box would then follow the whole line.
        item.style.staticX = item.style.wasInline ? x : pl;
        item.style.staticY = item.style.wasInline || !inFlowBefore ? y : baseline + below;
        item.style.staticValid = true;
        continue;
      }
      inFlowBefore = true;
      const it = aligns[aligned++];
      // The top of the box's line-height box in the line: a text-edge box in a reflected line
      // stands on the far side, where its baseline is measured from the line box's other edge.
      const boxTop = it.fromEnd ? y + below - it.shift - it.a : baseline - it.shift - it.a;
      if (item.kind === K_ATABLE) {
        // An anonymous inline-table sits on the line as one atomic box: its first row's
        // baseline is the line's, and its parts are laid out where the line put it.
        const info: number[] = [];
        layoutInlineTableRun(item.owner, item.run!, availW, boxTop, info, x);
        // The line's inline boxes span the atomic box, so it counts as a fragment of them.
        addFragment(el, FRAG_EDGE, item.style, item.owner, "", x, baseline - it.shift, item.w, lineIndex);
        continue;
      }
      if (item.kind === K_ATOMIC) {
        const c = item.style;
        c.x = x + zeroIfNaN(len(c, P.P_MARGIN_LEFT, innerW));
        // A reflected box's top is where its other margin is.
        c.y = boxTop + zeroIfNaN(len(c, it.fromEnd ? P.P_MARGIN_BOTTOM : P.P_MARGIN_TOP, innerW));
        place(c);
        // Relative positioning on an inline box moves the boxes inside it too.
        const around = relativeOffsetSum(c.parentElement, el, innerW, innerH);
        c.x += around[0];
        c.y += around[1];
        // The line's inline boxes span the atomic box, so it counts as a fragment of them.
        addFragment(el, FRAG_EDGE, c, c, "", x + around[0],
          boxTop + (it.a - baselineOffset(c)) + around[1], item.w, lineIndex);
        continue;
      }
      // An inline box moved by relative positioning takes its fragments with it, and so do the
      // fragments of the text and inline boxes inside it.
      const rel = relativeOffsetSum(item.style, el, innerW, innerH);
      // A justified run's fragment is as wide as the run draws: the boxes around it, its
      // underline and its selection then cover the text where it stands, not where it would
      // without the extra spacing.
      let adv = item.w;
      if (justifiedRun(item) && (extraWord !== 0 || extraLetter !== 0)) {
        const [spaceCount, charCount] = itemTextSpacing(item.text);
        // The last run's trailing spaces take no extra either, and an inter-character gap only
        // exists before a character, so a run's own last character adds no gap after it.
        const trailHere = item === line.items[lastText] ? trail : 0;
        adv += (spaceCount - trailHere) * extraWord + Math.max(charCount - trailHere - 1, 0) * extraLetter;
      }
      addFragment(el, item.kind === K_TEXT ? FRAG_TEXT : FRAG_EDGE, item.style, item.owner,
        item.kind === K_TEXT ? item.text : item.kind === K_OPEN ? "<" : ">",
        x + rel[0], boxTop + rel[1], adv, lineIndex);
      shift += adv - item.w;
    }
    out.push(y);
    out.push(advance);
    out.push(width);
    y += advance;
  }
  out[0] = y - top;
  return out;
}

/**
 * Keeps only the lines an element's `line-clamp` allows, ending the last one with an ellipsis.
 * An element may lay its inline content out in several runs (a block between them), so the
 * budget counts the lines it has already placed.
 */
function clampLines(el: Node, lines: Line[], clamp: number, innerW: number, indent: number, avails: number[]): Line[] {
  const room = clamp - el.lineBaseline.length;
  if (room <= 0) {
    lines.length = 0;
    return lines;
  }
  if (lines.length <= room) return lines;
  lines.length = room;
  // block-ellipsis: no-ellipsis keeps the lines and leaves the last one as it is.
  if (el.sv[P.P_BLOCK_ELLIPSIS] === P.BE_NO_ELLIPSIS) {
    lines[room - 1].forced = false;
    return lines;
  }
  const li = room - 1;
  const avail = (avails.length > li ? avails[li] : innerW) - (li === 0 ? indent : 0);
  const line = lines[li];
  line.forced = false;
  const ell = "\u2026";
  // The run of content that ends the line is where the text is cut; the edges after it go.
  let end = -1;
  for (let k = line.items.length - 1; k >= 0; k--) {
    const kind = line.items[k].kind;
    if (kind === K_TEXT || kind === K_ATOMIC || kind === K_ATABLE) { end = k; break; }
  }
  if (end < 0) return lines;
  const item = line.items[end];
  line.items.length = end + 1;
  const ellW = textWidth(item.style, ell);
  if (item.kind !== K_TEXT) {
    // An atomic box isn't cut: the ellipsis follows it where the room runs out.
    line.items.push(new Placed(K_TEXT, item.style, item.owner, ell, item.x + item.w, ellW, 0));
    return lines;
  }
  let text = item.text;
  while (text.length > 0 && item.x + textWidth(item.style, text) + ellW > avail) text = text.slice(0, -1);
  // Spaces cut off at the end would sit between the last glyph and the ellipsis.
  text = text.replace(/ +$/, "");
  item.text = text;
  item.w = textWidth(item.style, text);
  line.items.push(new Placed(K_TEXT, item.style, item.owner, ell, item.x + item.w, ellW, 0));
  return lines;
}

/**
 * Lays out a run of inline content of `el` starting at `top`. Returns the height used. When the
 * run is inside a float context (`ctx`, with `bx`/`by` the context coordinates of the content
 * box's left edge and of `top`), the floats shorten the lines: which line runs into a float
 * depends on where the lines above it ended up, so the run is laid out again until the widths
 * it gives each line stop changing.
 */
export function layoutInlinePieces(el: Node, pieces: Piece[], innerW: number, pl: number, top: number,
  innerH: number = NaN, ctx?: FloatCtx, bx?: number, by?: number, lineTops?: number[]): number {
  measurePieces(pieces, innerW, true, innerH);
  const fctx = ctx === undefined ? null : ctx;
  const ox = bx === undefined ? 0 : bx;
  const oy = by === undefined ? 0 : by;
  const offs: number[] = [];
  const avails: number[] = [];
  // The lowest top each line may take, when floats push it below themselves.
  const starts: number[] = [];
  // The fragments and baselines the runs before this one left: a later pass starts again from
  // there rather than dropping them.
  const nKind = el.fragKind.length;
  const nStyle = el.fragStyle.length;
  const nOwner = el.fragOwner.length;
  const nText = el.fragText.length;
  const nX = el.fragX.length;
  const nTop = el.fragTop.length;
  const nW = el.fragW.length;
  const nLine = el.fragLine.length;
  let used = 0;
  // The widths the floats leave depend on where the lines land, which depends on the widths, so
  // a run beside floats settles over several passes: pushing a line below them changes the room
  // the lines after it get.
  for (let pass = 0; pass < 6; pass++) {
    if (pass > 0) {
      while (el.fragKind.length > nKind) el.fragKind.pop();
      while (el.fragStyle.length > nStyle) el.fragStyle.pop();
      while (el.fragOwner.length > nOwner) el.fragOwner.pop();
      while (el.fragText.length > nText) el.fragText.pop();
      while (el.fragX.length > nX) el.fragX.pop();
      while (el.fragTop.length > nTop) el.fragTop.pop();
      while (el.fragW.length > nW) el.fragW.pop();
      while (el.fragLine.length > nLine) el.fragLine.pop();
      while (el.lineBaseline.length > nLine) el.lineBaseline.pop();
      while (el.lineCentral.length > nLine) el.lineCentral.pop();
    }
    const indent = firstLineIndent(el, innerW);
    el.textIndent = indent;
    let lines = breakLines(pieces, innerW, avails.length > 0 ? avails : undefined, indent);
    // Balanced and pretty lines are a second pass over the same pieces: a line beside a float
    // has its own width, and those two styles only shape a block whose lines are all one width.
    if (avails.length === 0) {
      const wrapStyle = el.sv[P.P_TEXT_WRAP_STYLE];
      if (wrapStyle === P.TWS_BALANCE) lines = balanceLines(pieces, innerW, lines, indent);
      else if (wrapStyle === P.TWS_PRETTY) lines = prettyLines(pieces, innerW, lines, indent);
    }
    let clamp = el.sv[P.P_LINE_CLAMP];
    if (clamp < 0) clamp = autoClamp(el);
    // A clamped ancestor's budget caps the count: the lines past it make nothing at all.
    if (el.clampBudget >= 0 && (clamp <= 0 || el.clampBudget < clamp)) clamp = el.clampBudget;
    if (clamp > 0) lines = clampLines(el, lines, clamp, innerW, indent, avails);
    else if (clamp === 0 && el.clampBudget === 0) lines.length = 0;
    // Where each cleared line has to start: below the floats its break clears, in the run's own
    // coordinates. The floats are all placed before the run is laid out, so they don't move.
    const clears: number[] = [];
    for (const ln of lines) {
      clears.push(ln.clear !== P.CL_NONE && fctx !== null ? clearBottom(fctx, ln.clear) - oy : -Infinity);
    }
    const res = placeLines(el, lines, innerW, pl, top, offs, avails, starts, innerH, indent, clears);
    used = res[0];
    if (lineTops !== undefined) {
      while (lineTops.length > 0) lineTops.pop();
      for (let i = 0; i < lines.length; i++) lineTops.push(res[1 + i * 3] - top);
    }
    if (fctx === null || fctx.boxes.length === 0 || pass === 5) break;
    let changed = avails.length !== lines.length;
    const nextOffs: number[] = [];
    const nextAvails: number[] = [];
    for (let i = 0; i < lines.length; i++) {
      const lineTop = res[1 + i * 3] - top;
      const lineH = res[2 + i * 3];
      // The line sits where this pass put it, or lower when the floats push it down: the room it
      // gets, and so the width the next pass breaks it to, is the room it finds there.
      const landY = starts.length > i && starts[i] > lineTop ? starts[i] : lineTop;
      const slot = floatSlot(fctx, oy + landY, lineH, ox, innerW);
      nextOffs.push(slot[0] - ox);
      nextAvails.push(Math.max(0, slot[1] - slot[0]));
      if (i >= avails.length || avails[i] !== nextAvails[i] || offs[i] !== nextOffs[i]) changed = true;
      // Content the floats leave too little room for, such as a box that can't be broken, takes
      // the line box below them (CSS 2.1 9.5).
      const fit = lines[i].first > nextAvails[i] + 0.5
        ? lineFitY(fctx, oy + landY, Math.max(lineH, 1), ox, innerW, lines[i].first) - oy
        : landY;
      if (i < starts.length) {
        if (fit > starts[i]) { starts[i] = fit; changed = true; }
      } else {
        starts.push(fit);
        changed = true;
      }
      if (starts[i] > lineTop) changed = true;
    }
    offs.length = 0;
    avails.length = 0;
    for (const v of nextOffs) offs.push(v);
    for (const v of nextAvails) avails.push(v);
    if (!changed) break;
  }
  return used;
}

/**
 * Cuts the text of `el`'s inline content at its content edge, ending the line in an ellipsis,
 * when `text-overflow` asks for one and the box clips its overflow. A box's own text is treated
 * the same way by wrapText; this is the path for text that arrives as inline content, such as a
 * text node a script inserted. The fragments keep the width they would have had, so the box's
 * scroll width still covers the whole text, as it does in a browser.
 */
export function elideOverflowText(el: Node, innerW: number, pl: number): void {
  // The ellipsis replaces text cut off by the inline axis's own overflow.
  if (el.sv[P.P_TEXT_OVERFLOW] !== P.TO_ELLIPSIS || !clipsX(el)) return;
  const limit = pl + innerW;
  let line = -1;
  let cut = false;
  for (let i = 0; i < el.fragKind.length; i++) {
    if (el.fragKind[i] !== FRAG_TEXT) continue;
    if (el.fragLine[i] !== line) {
      line = el.fragLine[i];
      cut = false;
    }
    // Once a line has been cut, the text after the ellipsis is not drawn at all.
    if (cut) {
      el.fragText[i] = "";
      continue;
    }
    if (el.fragX[i] + el.fragW[i] <= limit + 0.5) continue;
    el.fragText[i] = ellipsize(el.fragStyle[i], el.fragText[i], limit - el.fragX[i]);
    cut = true;
  }
}

/** Where a run's fragments and line baselines begin, so laying it out can be undone. */
function fragMark(el: Node): number[] {
  return [el.fragKind.length, el.fragStyle.length, el.fragOwner.length, el.fragText.length,
    el.fragX.length, el.fragTop.length, el.fragW.length, el.fragLine.length, el.lineBaseline.length];
}

function fragRollback(el: Node, m: number[]): void {
  while (el.fragKind.length > m[0]) el.fragKind.pop();
  while (el.fragStyle.length > m[1]) el.fragStyle.pop();
  while (el.fragOwner.length > m[2]) el.fragOwner.pop();
  while (el.fragText.length > m[3]) el.fragText.pop();
  while (el.fragX.length > m[4]) el.fragX.pop();
  while (el.fragTop.length > m[5]) el.fragTop.pop();
  while (el.fragW.length > m[6]) el.fragW.pop();
  while (el.fragLine.length > m[7]) el.fragLine.pop();
  while (el.lineBaseline.length > m[8]) el.lineBaseline.pop();
  while (el.lineCentral.length > el.lineBaseline.length) el.lineCentral.pop();
}

/**
 * The y, relative to `top`, where a float that follows `pieces` may go at the highest: the top of
 * the line box the content before it ended on, so that line is shortened by the float (CSS 2.1
 * 9.5.1, rule 5). When a forced break ends the content, the line after it holds none of it, so
 * the float goes there. Laying the run out to find that is undone afterwards.
 */
export function floatLineTop(el: Node, pieces: Piece[], innerW: number, pl: number, top: number,
  innerH: number, ctx: FloatCtx, bx: number, by: number): number {
  const m = fragMark(el);
  const tops: number[] = [];
  const used = layoutInlinePieces(el, pieces, innerW, pl, top, innerH, ctx, bx, by, tops);
  fragRollback(el, m);
  if (pieces.length > 0 && pieces[pieces.length - 1].kind === K_BREAK) return used;
  return tops.length > 0 ? tops[tops.length - 1] : used;
}
