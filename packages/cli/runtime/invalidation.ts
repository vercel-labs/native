// Which parts of the frame are out of date. Its own module so that the inline style object
// (cssom.ts) can invalidate without importing the DOM it belongs to.

import type { Node } from "./dom.ts";
import * as P from "../shared/props.ts";
import { INITIAL_U, INITIAL_V } from "./initial-values.ts";

/**
 * `composite` asks for a frame that only updates recorded compositor values (a transform or an
 * opacity group) and presents the display list again, without styling, laying out or painting;
 * see runtime/compositor.ts.
 */
export const dirty = { style: true, layout: true, paint: true, composite: false };

/**
 * Counts the changes that can move the document's text runs: a restyle or a relay-out can change
 * which nodes hold text, so the character stream the selection and highlights map through is
 * rebuilt when this number moves (see documentTextRuns).
 */
export const textVersion = { n: 0 };

/**
 * The pseudo-class state bits the app's rules ask about: the compiled tables' rule and ancestor
 * states, and every form state a runtime sheet may name. A script that changes a control's state
 * reads it to know whether a restyle is due. There is no per-element record of who cares, since
 * `input:checked + label` makes one control's change restyle its siblings and its form.
 */
export const stateUsage = { mask: 0 };

export function invalidateStyle(): void {
  textVersion.n++;
  dirty.style = true;
  dirty.layout = true;
  markFullPaint("style");
}

/**
 * The elements a change can only reach through their own subtree: a class, attribute or inline
 * style write on a connected element. The pages that allow this answer through the check style.ts
 * installs — no rule may see past the subtree (`:has()`, a sibling combinator, a counter, a scroll
 * marker); any other page takes the page pass below.
 */
export const styleRoots: Node[] = [];

/**
 * Whether a subtree restyle stands in for a page pass, and how far it reaches; style.ts installs the
 * real check. 0: a page pass is needed. 1: the element's own subtree. 2: its subtree and the
 * subtrees of its following element siblings, which a `+` or `~` rule in the page can see. 3: every
 * element sibling's subtree, whose position a filtered :nth-child() counts.
 */
let subtreeRestyleOk: (el: Node) => number = () => 0;

export function setSubtreeRestyleCheck(fn: (el: Node) => number): void {
  subtreeRestyleOk = fn;
}

/**
 * Installs how a change that only affects how a box composites reaches the compositor. It answers
 * true when the compositor can take it: the box's layer was recorded by the last paint, so the
 * frame updates that layer instead of repainting the page. A box whose layer wasn't recorded (a
 * transform that just appeared, a page the compositor never saw) answers false and takes the
 * ordinary path below.
 */
let compositorStyleChange: (el: Node) => boolean = () => false;

export function setCompositorStyleInvalidation(fn: (el: Node) => boolean): void {
  compositorStyleChange = fn;
}

/**
 * A change to `el` that only its own rules and its descendants' can see. `textMoves` is false for a
 * change that leaves the DOM's text where it was (a hover or focus moving): the document's text
 * runs then stay valid, and a selection doesn't rebuild them. A style pass that moves an element's
 * own text into a node of its own counts the move itself (see materializeText). `compositorOnly`
 * says the change only moves or fades the box, so the compositor may take it instead of a paint.
 */
export function invalidateStyleOf(el: Node, textMoves: boolean = true,
                                  compositorOnly: boolean = false): void {
  // The element whose own style changed, whichever subtree the restyle has to start from.
  const changed = el;
  // A change can reach further than its own subtree: an ancestor whose `dir=auto` reads the
  // text below it, for one. style.ts says where the restyle has to start.
  const root = restyleRootFor(el);
  if (root !== null) el = root;
  const reach = el.isConnected ? subtreeRestyleOk(el) : 0;
  if (reach === 0) {
    invalidateStyle();
    return;
  }
  if (textMoves) textVersion.n++;
  if (reach === 3) {
    // Every sibling can see the change (a filtered :nth-child() count), before it as well as
    // after it, so each sibling's subtree is styled.
    const parent = el.parentNode;
    if (parent === null) styleRoots.push(el);
    else for (const s of parent.kids) if (s.nodeType === 1) styleRoots.push(s);
    dirty.layout = true;
    if (incremental.on) markPaintDirty(el);
    else markFullPaint();
    return;
  }
  styleRoots.push(el);
  // A page whose rules use `+` or `~` can see the change from the boxes after this one: they test
  // their previous siblings, so they are styled too rather than the whole page.
  if (reach === 2) {
    for (let s = el.nextSibling; s !== null; s = s.nextSibling) if (s.nodeType === 1) styleRoots.push(s);
  }
  // A write that only moves or fades the box still has to be resolved by the style pass, but no
  // box moves for it and nothing has to be painted: the frame updates the recorded layer.
  if (compositorOnly && compositorStyleChange(changed)) return;
  dirty.layout = true;
  // With incremental layout, a restyle that stays inside this subtree leaves every other box in
  // place; the layout pass confirms that, and painting can then record just its span.
  if (incremental.on) markPaintDirty(el);
  else markFullPaint();
}

/** The element whose subtree has to be styled for a change to `el`, when one is further up. */
let restyleRootFor: (el: Node) => Node | null = () => null;

export function setRestyleRootFor(fn: (el: Node) => Node | null): void {
  restyleRootFor = fn;
}

/** The elements whose subtrees are due a style computation, cleared as they are taken. */
export function takeStyleRoots(): Node[] {
  const out = styleRoots.splice(0, styleRoots.length);
  return out;
}

/**
 * What changed about an element that a rule could test: the class tokens that came or went, any
 * other attribute, and whether its children moved. The style engine reads them when it decides
 * whether a restyled element's descendants can keep their styles (see the inherited-only fast
 * path in style.ts): a descendant selector only sees a class its ancestor carries, an attribute
 * test only sees an attribute, and `:nth-child` only sees the child list.
 */
export function noteClassChange(el: Node, tokens: readonly string[]): void {
  if (el.identClasses === null) el.identClasses = [];
  const list = el.identClasses;
  for (const t of tokens) if (list.indexOf(t) < 0) list.push(t);
}

/** An id, other attribute or inline style write: a rule may test it on this element. */
export function noteOtherIdentityChange(el: Node): void {
  el.identOther = true;
}

/** A child list or own-text change, which can move what `:nth-child` and `:empty` match below it. */
export function noteStructureChange(el: Node): void {
  el.identStructure = true;
}

/** The identity changes an element carries into its restyle, cleared as they are taken. */
export interface IdentityChange {
  classes: string[] | null;
  other: boolean;
  structure: boolean;
}

export function takeIdentityChange(el: Node): IdentityChange {
  const out: IdentityChange = {
    classes: el.identClasses,
    other: el.identOther,
    structure: el.identStructure,
  };
  el.identClasses = null;
  el.identOther = false;
  el.identStructure = false;
  return out;
}

/**
 * Per-node dirty bits, packed into `Node.dirtyBits`. The style bits belong to the style pass and
 * the paint bits to paint; layout reads and clears the two layout bits. A `*_CHILD` bit is the
 * path bit: it is set on every ancestor of a node that carries the matching `*_SELF` bit, so a
 * pass can walk down to the dirty nodes without visiting the rest.
 */
export const STYLE_SELF = 1;
export const STYLE_SUBTREE = 2;
export const STYLE_CHILD = 4;
export const LAYOUT_SELF = 8;
export const LAYOUT_CHILD = 16;
export const PAINT_SELF = 32;
export const PAINT_CHILD = 64;
export const LAYOUT_DIRTY = LAYOUT_SELF | LAYOUT_CHILD;

/**
 * Bumped by a layout invalidation that names no node (a viewport resize, a font set change, a
 * caller that can't tell what moved): every box's recorded layout and intrinsic sizes are out of
 * date then, whatever its bits say.
 */
export const layoutEpoch = { n: 0 };

/**
 * The boxes whose own computed values changed since the last layout pass, which is what can make a
 * box positioned or a scroll container, and the positioned boxes whose insets moved. Incremental
 * layout keeps its sets of positioned boxes and scroll containers up to date from the first list
 * (layout/box.ts), and places the boxes in the second again, so neither walks the page.
 * `growthStale` says a positioned box went away (removed, hidden, or no longer positioned): the
 * scroll extents it grew are made again from a walk, once.
 */
export const boxChanges = { kind: [] as Node[], placement: [] as Node[], stamp: 1, growthStale: false };

/**
 * The containers a container query (or a container-relative length) read a size from. A layout
 * that changes one of their sizes means the answers are out of date; containerStale checks just
 * these instead of walking the page. A box restyled since keeps its entry, with its record reset.
 */
export const queriedContainers: Node[] = [];

export function noteQueriedContainer(el: Node): void {
  if (el.qListed) return;
  el.qListed = true;
  queriedContainers.push(el);
}

export function noteBoxKindChanged(el: Node): void {
  if (el.lKindStamp === boxChanges.stamp) return;
  el.lKindStamp = boxChanges.stamp;
  boxChanges.kind.push(el);
}

export function notePlacementChanged(el: Node): void {
  if (el.lPlaceStamp === boxChanges.stamp) return;
  el.lPlaceStamp = boxChanges.stamp;
  boxChanges.placement.push(el);
}

/**
 * Asks for a layout. With an element, only that box and the boxes on its path to the root are out
 * of date; with none, everything is.
 */
export function invalidateLayout(el: Node | null = null, paint: Node | null = null, fresh: boolean = false): void {
  textVersion.n++;
  dirty.layout = true;
  // A box's own layout change is localisable when incremental layout can redo just that box (and
  // falls back to a full pass otherwise, which painting sees and turns into a full repaint).
  const span = paint !== null ? paint : el;
  if (el === null || !incremental.on || span === null) {
    markFullPaint(el === null ? "layout-all" : "layout-no-inc");
  } else {
    markPaintDirty(span, fresh);
  }
  if (el === null) layoutEpoch.n++;
  else markLayoutDirty(el);
}
/**
 * The painted boxes a frame has to record again, and whether it has to record the whole page. A
 * change that can't be localised asks for the whole page with markFullPaint(); a change that can
 * names the highest node whose painted span covers it with markPaintDirty(). `dirty.paint` is true
 * exactly while one of the two holds: the painter consumes the set and clears it, and anything
 * that sets the flag directly has to go through markFullPaint instead.
 */
export const paintDamage = {
  full: true,
  nodes: [] as Node[],
  /** Each node's painted bounds when it was marked, parallel to `nodes`; null when it had none. */
  oldBounds: [] as (number[] | null)[],
  /**
   * Rectangles in viewport coordinates to record again, for a change that has geometry of its
   * own: a scroll's scrollport, or the band a selection highlight grew over. They are the old
   * and the new regions together, so they need no bounds captured before the change.
   */
  rects: [] as number[][],
};

/**
 * Asks for a repaint of `rects` (viewport coordinates), together with any node damage marked for
 * the frame. A full paint marked earlier this frame already covers them.
 */
export function markPaintRects(rects: number[][]): void {
  if (paintDamage.full) return;
  for (const r of rects) paintDamage.rects.push(r);
  if (rects.length > 0) dirty.paint = true;
}

/** With NATIVE_PAINT_TRACE, which call site asked for each full paint, for a frame's stats line. */
export const paintMarkTrace = {
  on: process.env.NATIVE_PAINT_TRACE !== undefined,
  counts: new Map<string, number>(),
};

/** Asks for a repaint of the whole page: the conservative answer, and free to give. */
export function markFullPaint(site: string = ""): void {
  if (paintMarkTrace.on) {
    const key = site === "" ? "(untagged)" : site;
    paintMarkTrace.counts.set(key, (paintMarkTrace.counts.get(key) ?? 0) + 1);
  }
  paintDamage.full = true;
  paintDamage.nodes.length = 0;
  paintDamage.oldBounds.length = 0;
  paintDamage.rects.length = 0;
  dirty.paint = true;
}

/**
 * The painter installs this: a node's painted bounds in viewport coordinates, or null when it has
 * no box yet. Marking a node records them now, before the layout it asks for moves it, so the
 * frame can union where it painted with where it paints next.
 */
let paintBoundsHook: (node: Node) => number[] | null = () => null;

export function setPaintBoundsHook(fn: (node: Node) => number[] | null): void {
  paintBoundsHook = fn;
}

/**
 * Marks a box's own layout inputs as changed, and its ancestors as holding a dirty box. Their
 * intrinsic sizes depend on this box, so the sizes they kept are dropped on the way up. A walk
 * that reaches an ancestor already marked stops there: its own ancestors are marked too.
 *
 * It doesn't ask for a frame by itself: the DOM calls that mark boxes also invalidate as they
 * always have, so a mark only says which boxes the next layout has to redo.
 *
 * The box tree differs from the DOM where a shadow tree slots light children somewhere inside it;
 * a change to a slotted node makes the whole layout stale rather than miss the boxes between.
 */
export function markLayoutDirty(el: Node): void {
  el.dirtyBits |= LAYOUT_SELF;
  staleSizes(el);
  let prev = el;
  let n = el.layoutParent();
  while (n !== null) {
    if (n.hasShadowTree() && !prev.isShadowRootNode()) {
      layoutEpoch.n++;
      return;
    }
    if ((n.dirtyBits & LAYOUT_CHILD) !== 0) return;
    n.dirtyBits |= LAYOUT_CHILD;
    staleSizes(n);
    prev = n;
    n = n.layoutParent();
  }
}

/**
 * Asks for a repaint of the span `node`'s commands occupy. For a text run that is the block that
 * owns the line fragments, not the run's parent; a change that also lays the page out is not
 * localisable, since boxes after it move.
 */
export function markPaintDirty(node: Node, fresh: boolean = false): void {
  if (paintDamage.full) return;
  if (!node.isConnected) {
    markFullPaint("dirty-disconnected");
    return;
  }
  if (paintDamage.nodes.length < 256) {
    paintDamage.nodes.push(node);
    // A box that arrived this frame has no old pixels; its bounds before layout would resolve to
    // the block it was put in, and damaging that whole block is what repainted a whole list.
    paintDamage.oldBounds.push(fresh ? null : paintBoundsHook(node));
  } else {
    markFullPaint("dirty-overflow");
    return;
  }
  dirty.paint = true;
}

/** Clears the damage a paint consumed; the painter calls this once it recorded the dirty spans. */
export function clearPaintDamage(): void {
  paintDamage.full = false;
  paintDamage.nodes.length = 0;
  paintDamage.oldBounds.length = 0;
  paintDamage.rects.length = 0;
}

export function invalidatePaint(): void {
  markFullPaint("invalidatePaint");
}

/**
 * Empties a box's intrinsic sizes, setting the first set aside since its last layout: a box laid
 * out again on its own compares its new answers with those (see layout/incremental.ts).
 */
function staleSizes(el: Node): void {
  if (el.szN > 0 && el.szOldN === 0) {
    const k = el.szOld;
    el.szOld = el.szK;
    el.szK = k;
    el.szOldN = el.szN;
    el.szOldEpoch = el.szEpoch;
  }
  el.szN = 0;
}

/**
 * Incremental layout (layout/incremental.ts): reuse a box's last layout when
 * nothing it depends on changed. On unless NATIVE_INCREMENTAL_LAYOUT=0, or the app turns it off
 * with setIncrementalLayout(false); `verify` (NATIVE_VERIFY_INCREMENTAL) lays every frame out a
 * second time from scratch and reports any box the reused layout got wrong.
 */
export const incremental = { on: true, verify: false };

function envOn(name: string): boolean {
  const v = process.env[name];
  return v !== undefined && v !== "" && v !== "0";
}
function envOff(name: string): boolean {
  return process.env[name] === "0";
}
incremental.verify = envOn("NATIVE_VERIFY_INCREMENTAL");
incremental.on = incremental.verify || !envOff("NATIVE_INCREMENTAL_LAYOUT");

/**
 * How a property takes part in the layout signature: 0 in full, 1 not at all (layout never reads
 * opacity or a transform's origin), 2 only as whether it is set, since layout reads whether a box
 * has a transform (a fixed box's containing block) and never what the transform is.
 */
const SIGN_FULL = 0;
const SIGN_NONE = 1;
const SIGN_SET = 2;
const signKind: number[] = [];
for (let p = 0; p < P.PROP_COUNT; p++) signKind.push(SIGN_FULL);
signKind[P.P_OPACITY] = SIGN_NONE;
signKind[P.P_TRANSFORM_ORIGIN] = SIGN_NONE;
signKind[P.P_TRANSFORM] = SIGN_SET;
signKind[P.P_TRANSLATE] = SIGN_SET;
signKind[P.P_ROTATE] = SIGN_SET;
signKind[P.P_SCALE] = SIGN_SET;

/**
 * Layout features incremental layout doesn't reuse layouts around yet, because a box's layout
 * there reads more than its arguments and its subtree: a subgrid takes its tracks from its parent
 * grid, a vertical or orthogonal writing mode turns frames its ancestors and descendants share,
 * grid baseline alignment shims items by their baselines, and an inline box can be the containing
 * block of positioned boxes. A page that styles any of them is laid out in full, as it would be
 * without incremental layout, until its next full style pass finds none (see layoutRoot).
 */
export const unsupportedLayout = { nodes: 0, pass: 0 };

function isBaseline(v: number): boolean {
  return v === P.A_BASELINE || v === P.A_LAST_BASELINE;
}

function usesUnsupportedLayout(el: Node): boolean {
  const sv = el.sv;
  const su = el.su;
  if (sv[P.P_WRITING_MODE] !== P.WM_HORIZONTAL_TB) return true;
  if (su[P.P_GRID_TEMPLATE_COLUMNS] === P.U_SUBGRID || su[P.P_GRID_TEMPLATE_ROWS] === P.U_SUBGRID) return true;
  const d = sv[P.P_DISPLAY];
  const grid = d === P.D_GRID || d === P.D_INLINE_GRID || d === P.D_GRID_LANES || d === P.D_INLINE_GRID_LANES;
  if (grid && (isBaseline(sv[P.P_ALIGN_ITEMS]) || isBaseline(sv[P.P_JUSTIFY_ITEMS]) ||
    sv[P.P_ALIGN_CONTENT] === P.J_BASELINE || sv[P.P_ALIGN_CONTENT] === P.J_LAST_BASELINE ||
    sv[P.P_JUSTIFY_CONTENT] === P.J_BASELINE || sv[P.P_JUSTIFY_CONTENT] === P.J_LAST_BASELINE)) return true;
  if (isBaseline(sv[P.P_ALIGN_SELF]) || isBaseline(sv[P.P_JUSTIFY_SELF])) return true;
  if (d === P.D_INLINE && sv[P.P_POSITION] !== P.POS_STATIC) return true;
  return false;
}

/** Called as a full style pass starts: the count is made again from what it styles. */
export function startUnsupportedCount(): void {
  unsupportedLayout.nodes = 0;
  unsupportedLayout.pass++;
}

/**
 * The properties a box's parent reads when it lays the box out, rather than the box itself: its
 * margins and sizes, how it takes part in its parent's flow, flex or grid, and its writing mode. A
 * box whose own change touches none of them is laid out with the arguments its parent last gave
 * it, so it can be laid out alone (see layout/incremental.ts); one that touches any is laid out
 * by its parent.
 */
const parentFacing: boolean[] = [];
for (let p = 0; p < P.PROP_COUNT; p++) {
  const n = P.propCssName(p);
  parentFacing.push(n.startsWith("margin") || n.startsWith("padding") || /^border.*width$/.test(n) ||
    n.startsWith("width") || n.startsWith("height") || n.startsWith("min-") || n.startsWith("max-") ||
    n === "inline-size" || n === "block-size" || n.startsWith("flex") || n.startsWith("grid-") ||
    n === "order" || n === "align-self" || n === "justify-self" || n === "display" ||
    n === "position" || n === "float" || n === "clear" || n === "box-sizing" || n === "aspect-ratio" ||
    n === "writing-mode" || n === "direction" || n === "vertical-align" || n === "content-visibility" ||
    n === "contain" || n.startsWith("inset") || n === "top" || n === "right" || n === "bottom" ||
    n === "left" || n.startsWith("overflow") || n === "visibility" || n === "column-span" ||
    n === "break-before" || n === "break-after" || n === "page-break-before" || n === "page-break-after");
}

/** Whether a property is an inset, which only places an absolutely positioned box. */
function isInset(p: number): boolean {
  return p === P.P_TOP || p === P.P_RIGHT || p === P.P_BOTTOM || p === P.P_LEFT ||
    p === P.P_INSET_BLOCK_START || p === P.P_INSET_BLOCK_END || p === P.P_INSET_INLINE_START ||
    p === P.P_INSET_INLINE_END;
}

/**
 * Called by the style pass once it has given a node everything layout reads from it: its computed
 * values, its text and its children. When any of those differ from the last time, the box's own
 * layout is out of date. This is how a style change, a text edit or a child added or removed
 * reaches layout whichever DOM call made it.
 *
 * An absolutely positioned box's insets are left out: the out-of-flow pass reads them when it
 * places the box, on every layout, and passes the size they decide to the box's layout as an
 * argument, so a row of a virtual list that only moves isn't laid out again. Whether each one is
 * auto is kept: an auto inset puts the box at its static position, which its parent's layout
 * works out. The values layout doesn't read are left out too (signKind): a list window moved by
 * a transform isn't laid out either.
 */
export function noteLayoutInputs(el: Node): void {
  if (!incremental.on) return;
  if (el.lUnsupportedPass !== unsupportedLayout.pass && usesUnsupportedLayout(el)) {
    el.lUnsupportedPass = unsupportedLayout.pass;
    unsupportedLayout.nodes++;
  }
  const sv = el.sv;
  const su = el.su;
  const pos = sv.length > P.P_POSITION ? sv[P.P_POSITION] : P.POS_STATIC;
  const placed = pos === P.POS_ABSOLUTE || pos === P.POS_FIXED;
  // Two 32-bit hashes: one of each value's integer part, one of its fraction (to 2^-16) with its
  // unit. The style pass runs this for every node it styles, so it stays a few operations a value.
  let a = 0x811c9dc5 | 0;
  let b = 0x2545f491 | 0;
  // The part of it the parent reads (parentFacing), and a positioned box's inset values.
  let f = 0x6a09e667 | 0;
  let ins = 0x3c6ef372 | 0;
  for (let p = 0; p < sv.length; p++) {
    if (placed && isInset(p)) {
      // Whether an inset is auto still counts: an auto inset places the box at its static
      // position, which its parent works out while it lays its children out.
      const auto = su[p] === P.U_AUTO ? p + 1 : 0;
      a = Math.imul(a ^ auto, 0x01000193);
      f = Math.imul(f ^ auto, 0x01000193);
      ins = Math.imul(ins ^ ((sv[p] * 65536) | 0) ^ (su[p] << 20), 0x5bd1e995);
      continue;
    }
    const kind = signKind[p];
    if (kind === SIGN_NONE) continue;
    const v = kind === SIGN_SET ? (sv[p] === INITIAL_V[p] && su[p] === INITIAL_U[p] ? 0 : 1) : sv[p];
    a = Math.imul(a ^ (v | 0), 0x01000193);
    const m = ((v * 65536) | 0) ^ (kind === SIGN_SET ? 0 : su[p] << 20);
    b = Math.imul(b ^ m, 0x5bd1e995);
    if (parentFacing[p]) f = Math.imul(f ^ m ^ (v | 0), 0x5bd1e995);
  }
  // An out-of-flow box that was inline before it was blockified takes an inline static position,
  // which its parent works out: the computed display can't tell the two apart.
  if (el.wasInline) {
    a = Math.imul(a ^ 0x5f3759df, 0x01000193);
    f = Math.imul(f ^ 0x5f3759df, 0x01000193);
  }
  if (placed && ins !== el.lInsets) {
    // Only the out-of-flow pass reads an inset's value: it places the box again.
    el.lInsets = ins;
    notePlacementChanged(el);
  }
  const kids = el.kids;
  let c = Math.imul(0x3c6ef372 ^ kids.length, 0x01000193);
  for (let i = 0; i < kids.length; i++) c = Math.imul(c ^ kids[i].serial, 0x01000193);
  const own = a !== el.lStyleA || b !== el.lStyleB;
  if (own) noteBoxKindChanged(el);
  if (own || c !== el.lKids || el.ownText !== el.lOwnText || el.layoutText !== el.lLayoutText) {
    el.lStyleA = a;
    el.lStyleB = b;
    el.lKids = c;
    el.lOwnText = el.ownText;
    el.lLayoutText = el.layoutText;
    // A change its parent doesn't read leaves the box laid out with the arguments it had.
    if (f !== el.lParentFacing) {
      el.lParentFacing = f;
      el.lOwnChanged = true;
    }
    markLayoutDirty(el);
  }
}
