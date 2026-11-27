// Incremental layout: a box whose inputs are the ones it was last laid
// out with, and which holds nothing marked dirty since, keeps the layout it has. The inputs are the
// arguments layoutBox gets plus the box's dirty bits (invalidation.ts), which the style pass sets
// from a signature of what it gave the box (noteLayoutInputs) and the DOM sets on a mutation.
//
// Each box keeps a few of its layouts (slots), since flex and grid lay an item out more than once
// a pass. A dirty path stops at the deepest box that can be laid out alone with the arguments it
// kept and whose outputs, and the intrinsic sizes its parent asked of it, come out the same: a
// relayout root. Nothing above it is laid out then.
//
// On by default; NATIVE_INCREMENTAL_LAYOUT=0 or setIncrementalLayout(false) turns it off.
// NATIVE_VERIFY_INCREMENTAL=1 turns it on and, after each incremental layout, lays the whole page
// out again from scratch and compares the two box trees: every difference is printed as a
// `native: layout mismatch` line.
//
// What is reused is narrow on purpose: not a box in a float context that has floats in it, not a
// table part, not a box in a vertical writing mode or split across columns, and nothing in quirks
// mode, where a percentage height looks up the tree. Those lay out as they always have.

import { writeFileSync } from "node:fs";
import * as P from "../../shared/props.ts";
import { Node, Element, boxKids, document } from "../dom.ts";
import { incremental, layoutEpoch, LAYOUT_DIRTY, LAYOUT_SELF } from "../invalidation.ts";
import { isQuirks } from "../quirk.ts";
import { clipsX, clipsY, display, isFloat, isOutOfFlow } from "./box-model.ts";
import { SIZE_STRIDE, sizeAgain, sizeGenerationNow } from "./text.ts";
import { isInlineLevel } from "./inline.ts";
import { isTableDisplay, isTableInternal } from "./table.ts";
import { isMulticol } from "./multicol.ts";

/** Counters for the current frame: boxes laid out, and boxes whose last layout was reused. */
export const layoutCounts = { laidOut: 0, cached: 0, roots: 0, mismatches: 0, passes: 0, local: 0, full: 0 };

/** Bumped by every layout pass; a dirty box laid out in this pass can be reused within it. */
let pass = 0;
/** Set while verify mode runs its from-scratch pass, which reuses nothing but records everything. */
let forceFull = false;
/** The one box settleLayouts lays out for real; the boxes inside it may still reuse theirs. */
let forceNode: Node | null = null;

export function startLayoutPass(): void {
  pass++;
  layoutCounts.passes++;
}

/** Turns incremental layout on or off at run time; `verify` also checks every frame against a full pass. */
export function setIncrementalLayout(on: boolean, verify: boolean = false): void {
  incremental.on = on || verify;
  incremental.verify = verify;
  // Whatever was recorded while it was off is out of date.
  layoutEpoch.n++;
}

// A slot: the epoch and pass it was made in, the arguments, then the box's own outputs.
const S_EPOCH = 0;
const S_PASS = 1;
const S_CBW = 2;
const S_CBH = 3;
const S_FIXW = 4;
const S_FIXH = 5;
const S_FLAGS = 6;
const S_MGP = 7;
const S_MGN = 8;
/** The last pass a caller asked for this layout, made or reused. */
const S_USED = 9;
const S_OUT = 10;
const OUTPUTS = 18;
const SLOT = S_OUT + OUTPUTS;
/**
 * A box keeps up to this many layouts. A flex item is measured and laid out up to three ways in a
 * pass, and an item of a flex item that is laid out more than once can see as many sets again.
 */
const LAYOUT_SLOTS = 8;

/** Flag 4 marks a layout made in the parent's float context, with no float in it either way. */
const IN_FLOW = 4;
function inputFlags(shrink: boolean, autoHeight: boolean | undefined, inFlow: boolean): number {
  return (shrink ? 1 : 0) | (autoHeight === true ? 2 : 0) | (inFlow ? IN_FLOW : 0);
}

function same(a: number, b: number): boolean {
  return a === b || (a !== a && b !== b);
}

/** Whether slot `i` of `el` still holds: made in this epoch, and before nothing changed under it. */
function current(el: Node, i: number): boolean {
  const s = el.lSlots;
  const at = i * SLOT;
  return s[at + S_EPOCH] === layoutEpoch.n && ((el.dirtyBits & LAYOUT_DIRTY) === 0 || s[at + S_PASS] === pass);
}

/** The epoch slot `i` of `el` was made in. */
function slotEpoch(el: Node, i: number): number {
  return el.lSlots[i * SLOT + S_EPOCH];
}

function sameInputs(s: number[], at: number, cbW: number, cbH: number, fixedW: number, fixedH: number, flags: number,
  mgP: number, mgN: number): boolean {
  return same(s[at + S_CBW], cbW) && same(s[at + S_CBH], cbH) && same(s[at + S_FIXW], fixedW) &&
    same(s[at + S_FIXH], fixedH) && s[at + S_FLAGS] === flags && s[at + S_MGP] === mgP && s[at + S_MGN] === mgN;
}

/** Puts back the box's own outputs from a slot. */
function restore(el: Node, s: number[], at: number): void {
  const o = at + S_OUT;
  el.w = s[o];
  el.h = s[o + 1];
  el.naturalW = s[o + 2];
  el.naturalH = s[o + 3];
  el.tW = 0;
  el.tH = 0;
  el.contentX = s[o + 4];
  el.contentY = s[o + 5];
  el.contentW = s[o + 6];
  el.contentH = s[o + 7];
  el.relX = s[o + 8];
  el.relY = s[o + 9];
  el.escTopP = s[o + 10];
  el.escTopN = s[o + 11];
  el.escBotP = s[o + 12];
  el.escBotN = s[o + 13];
  el.collapsesThrough = s[o + 14] !== 0;
  el.boxTop = s[o + 15];
  el.boxBottom = s[o + 16];
  el.inlineAvail = s[o + 17];
  el.inVtext = 0;
  el.fixedViewport = false;
}

/** Writes the box's own outputs into a slot. */
function saveOutputs(el: Node, s: number[], at: number): void {
  const o = at + S_OUT;
  s[o] = el.w;
  s[o + 1] = el.h;
  s[o + 2] = el.naturalW;
  s[o + 3] = el.naturalH;
  s[o + 4] = el.contentX;
  s[o + 5] = el.contentY;
  s[o + 6] = el.contentW;
  s[o + 7] = el.contentH;
  s[o + 8] = el.relX;
  s[o + 9] = el.relY;
  s[o + 10] = el.escTopP;
  s[o + 11] = el.escTopN;
  s[o + 12] = el.escBotP;
  s[o + 13] = el.escBotN;
  s[o + 14] = el.collapsesThrough ? 1 : 0;
  s[o + 15] = el.boxTop;
  s[o + 16] = el.boxBottom;
  s[o + 17] = el.inlineAvail;
}

/** Boxes showing an older slot's outputs over a subtree laid out for the first (see settleLayouts). */
const pending: Node[] = [];

/**
 * Whether one of `el`'s kept layouts can stand for a call with these inputs. On a hit the box's
 * own outputs are put back as that layout left them: a caller may have changed them since (a flex
 * line stretching an item, an out-of-flow box growing its ancestors' scroll extent).
 *
 * The first slot is the layout the subtree below holds. A hit on another one puts back only the
 * box's own outputs, leaving the subtree as it is: a flex container measuring an item reads its
 * height, then lays it out again with the first slot's arguments, which puts the rest back. When
 * nothing does, settleLayouts lays the box out for real at the end of the pass.
 */
export function reuseLayout(el: Node, cbW: number, cbH: number, fixedW: number, fixedH: number, shrink: boolean,
  autoHeight: boolean | undefined, inFlow: boolean, mgP: number, mgN: number): boolean {
  // A box under a clamp is laid out against a budget its cached inputs don't record.
  if (el.clampBudget >= 0 || el.clampEllipsis) return false;
  if (forceFull || el === forceNode || el.lN === 0) return false;
  // The frame a box sits in comes from its parent (or, out of flow, from the positioned pass,
  // which sets it before the call), and either may have turned since.
  if (el.inVtext !== 0) return false;
  const parent = el.parentElement;
  if (parent !== null && parent.vtext !== 0) return false;
  const flags = inputFlags(shrink, autoHeight, inFlow);
  const s = el.lSlots;
  if (debugMisses) noteMiss(el, cbW, cbH, fixedW, fixedH, flags, mgP, mgN);
  if (current(el, 0) && sameInputs(s, 0, cbW, cbH, fixedW, fixedH, flags, mgP, mgN)) {
    const first = 0;
    s[first + S_USED] = pass;
    restore(el, s, 0);
    el.lPending = -1;
    layoutCounts.cached++;
    return true;
  }
  if (readsBaseline(el)) return false;
  for (let i = 1; i < el.lN; i++) {
    if (!current(el, i) || !sameInputs(s, i * SLOT, cbW, cbH, fixedW, fixedH, flags, mgP, mgN)) continue;
    s[i * SLOT + S_USED] = pass;
    restore(el, s, i * SLOT);
    if (el.lPending < 0) pending.push(el);
    el.lPending = i;
    layoutCounts.cached++;
    return true;
  }
  return false;
}

/** NATIVE_LAYOUT_MISSES=1 prints, per pass, why boxes weren't reused; =2 names the first ones. */
const debugMisses = process.env.NATIVE_LAYOUT_MISSES === "1" || process.env.NATIVE_LAYOUT_MISSES === "2";
const debugMissPaths = process.env.NATIVE_LAYOUT_MISSES === "2";
export const missCounts = { epoch: 0, dirty: 0, inputs: 0 };
function noteMiss(el: Node, cbW: number, cbH: number, fixedW: number, fixedH: number, flags: number, mgP: number, mgN: number): void {
  const s = el.lSlots;
  if (slotEpoch(el, 0) !== layoutEpoch.n) {
    missCounts.epoch++;
    return;
  }
  if (!current(el, 0)) {
    missCounts.dirty++;
    return;
  }
  for (let i = 0; i < el.lN; i++) {
    if (current(el, i) && sameInputs(s, i * SLOT, cbW, cbH, fixedW, fixedH, flags, mgP, mgN)) return;
  }
  missCounts.inputs++;
  if (debugMissPaths && missCounts.inputs <= 40) {
    let kept = "";
    for (let i = 0; i < el.lN; i++) {
      const at = i * SLOT;
      kept += ` [${s[at + S_CBW]},${s[at + S_CBH]} ${s[at + S_FIXW]},${s[at + S_FIXH]} ${s[at + S_FLAGS]}${current(el, i) ? "" : " stale"}]`;
    }
    console.error(`native: miss ${nodePath(el)} asked [${cbW},${cbH} ${fixedW},${fixedH} ${flags}] kept${kept}`);
  }
}
export function printMisses(): void {
  if (!debugMisses) return;
  console.error(`native: layout misses epoch=${missCounts.epoch} dirty=${missCounts.dirty} inputs=${missCounts.inputs} laidOut=${layoutCounts.laidOut} cached=${layoutCounts.cached} roots=${layoutCounts.roots}`);
  missCounts.epoch = 0;
  missCounts.dirty = 0;
  missCounts.inputs = 0;
}

/** Whether the box's parent reads more of it than its outputs: a baseline, or its place in a line. */
function readsBaseline(el: Node): boolean {
  const parent = el.parentElement;
  if (parent === null) return false;
  return el.sv[P.P_ALIGN_SELF] === P.A_BASELINE || el.sv[P.P_ALIGN_SELF] === P.A_LAST_BASELINE ||
    parent.sv[P.P_ALIGN_ITEMS] === P.A_BASELINE || parent.sv[P.P_ALIGN_ITEMS] === P.A_LAST_BASELINE ||
    isInlineLevel(el);
}

/**
 * Lays out, for real, every box that still shows an older slot's outputs: its subtree holds the
 * first slot's layout. The outputs come out as they were, so nothing around it moves.
 */
export function settleLayouts(): boolean {
  if (pending.length === 0) return false;
  while (pending.length > 0) {
    const el = pending.pop()!;
    settleNode(el);
  }
  return true;
}

/**
 * Lays out, for real, one box that shows an older slot's outputs, because something is about to
 * read its content (a baseline): the content must be the one those outputs came from.
 */
export function settleNode(el: Node): void {
  const i = el.lPending;
  if (i < 0) return;
  el.lPending = -1;
  const outer = forceNode;
  forceNode = el;
  layoutSlot(el, el.lSlots, i * SLOT);
  forceNode = outer;
}

/** Lays `el` out with the arguments a slot (in `s`, at `at`) holds. */
function layoutSlot(el: Node, s: number[], at: number): void {
  const flags = s[at + S_FLAGS];
  layoutBoxAgain!(el, s[at + S_CBW], s[at + S_CBH], s[at + S_FIXW], s[at + S_FIXH], (flags & 1) !== 0,
    (flags & 2) !== 0 ? true : undefined, (flags & IN_FLOW) !== 0, s[at + S_MGP], s[at + S_MGN]);
}

/**
 * Called before a box is laid out for real: the layouts it keeps move down a slot, those that no
 * longer hold (and the oldest) dropping out, to leave the first for the one about to be made.
 */
export function keepOlderLayout(el: Node): void {
  el.lPending = -1;
  const s = el.lSlots;
  // Room for the layouts that move down and the one about to be made, grown as a box needs it.
  const want = SLOT * Math.min(el.lN + 1, LAYOUT_SLOTS);
  while (s.length < want) s.push(-1);
  // Gather the slots that still hold, newest first, behind the first one.
  let n = 1;
  const keep = Math.min(el.lN, LAYOUT_SLOTS - 1);
  for (let i = 0; i < el.lN; i++) {
    if (!current(el, i)) continue;
    if (n > keep) {
      // A layout asked for in this pass that finds no room is one whose outputs the parent read
      // but a relayout of the box alone can't check (see canRelayoutAlone).
      if (s[i * SLOT + S_USED] === pass) el.lLostPass = pass;
      continue;
    }
    // Moving down one place at most, slots are copied from the oldest end.
    tmpIdx[n - 1] = i;
    n++;
  }
  for (let k = n - 1; k >= 1; k--) {
    const from = tmpIdx[k - 1] * SLOT;
    const to = k * SLOT;
    if (from !== to) for (let j = 0; j < SLOT; j++) s[to + j] = s[from + j];
  }
  el.lN = n;
  const first = 0;
  s[first + S_EPOCH] = -1;
}
const tmpIdx: number[] = [0, 0, 0, 0, 0, 0, 0, 0];

/** Whether a box's layout, once made, depends only on its inputs and its subtree. */
function cacheable(el: Node): boolean {
  if (el.vtext !== 0 || el.inVtext !== 0 || el.fragBoxes.length > 0) return false;
  if (el.parentElement === null || isQuirks()) return false;
  const d = display(el);
  if (isTableDisplay(d) || isTableInternal(d) || d === P.D_NONE) return false;
  if (isMulticol(el)) return false;
  return true;
}

/**
 * Records the layout `el` just got in its first slot. A box that can't be reused still keeps its
 * outputs there, for resetNaturalSizes.
 */
export function recordLayout(el: Node, cbW: number, cbH: number, fixedW: number, fixedH: number, shrink: boolean,
  autoHeight: boolean | undefined, inFlow: boolean, mgP: number, mgN: number, floatFree: boolean): void {
  layoutCounts.laidOut++;
  // A box laid out again while it lays itself out (an intrinsic height measured by laying the box
  // out) may have taken an older layout's outputs in there: the layout finishing now is the one its
  // subtree and its own outputs hold, so nothing is left to settle.
  el.lPending = -1;
  const s = el.lSlots;
  if (s.length < SLOT) keepOlderLayout(el);
  if (el.lN === 0) el.lN = 1;
  const reusable = incremental.on && floatFree && cacheable(el);
  const at = 0;
  s[at + S_EPOCH] = reusable ? layoutEpoch.n : -1;
  s[at + S_PASS] = pass;
  s[at + S_CBW] = cbW;
  s[at + S_CBH] = cbH;
  s[at + S_FIXW] = fixedW;
  s[at + S_FIXH] = fixedH;
  s[at + S_FLAGS] = inputFlags(shrink, autoHeight, inFlow);
  s[at + S_MGP] = mgP;
  s[at + S_MGN] = mgN;
  s[at + S_USED] = pass;
  saveOutputs(el, s, at);
  // A box that can't be reused keeps no older layouts either.
  if (!reusable) el.lN = 1;
}

/**
 * Puts back the scroll extents layout gave each box before the out-of-flow pass grows them: that
 * pass runs over the whole page every time, and a box whose layout was reused still carries what
 * the last one added, which may have shrunk or moved since.
 */
export function resetNaturalSizes(el: Node): void {
  resetNaturalSize(el);
  if (display(el) === P.D_NONE) return;
  for (const c of boxKids(el)) resetNaturalSizes(c);
}

/**
 * A child's scroll extent as its parent's layout reads it: what the child's own layout gave it,
 * without what positioned boxes grew it by since (resetNaturalSize). The growth is applied again
 * once the pass places them, so a box measures the same extent whichever boxes this pass laid
 * out again.
 */
export function laidOutNaturalW(c: Node): number {
  return c.lN > 0 ? c.lSlots[S_OUT + 2] : 0;
}
export function laidOutNaturalH(c: Node): number {
  return c.lN > 0 ? c.lSlots[S_OUT + 3] : 0;
}

/**
 * The same for one box. A box layout never lays out itself (an inline box, a table row) holds
 * only what out-of-flow boxes grew it by, so it goes back to nothing.
 */
export function resetNaturalSize(el: Node): void {
  if (el.lN > 0) {
    el.naturalW = el.lSlots[S_OUT + 2];
    el.naturalH = el.lSlots[S_OUT + 3];
  } else {
    el.naturalW = 0;
    el.naturalH = 0;
  }
  el.tW = 0;
  el.tH = 0;
}

// ---------------------------------------------------------------------------
// Relayout roots

/**
 * Whether a box that holds a dirty box can be laid out again on its own, with the arguments it
 * last had, so that the boxes around it keep their layouts if what they read of it comes out the
 * same. That covers the relayout roots — absolutely positioned rows, scroll
 * containers, boxes of a fixed size, form fields — and any other box whose outputs don't move.
 * Not a box whose own style changed (its arguments may change with it), one asked for more
 * layouts than it keeps (one it dropped can't be checked), a float, or a box whose parent reads
 * its baseline or places it in a line.
 */
function canRelayoutAlone(el: Node): boolean {
  if (el.lN === 0 || slotEpoch(el, 0) !== layoutEpoch.n || el.lOwnChanged) return false;
  // The last pass that asked for one of its layouts asked for more than it could keep.
  let used = -1;
  for (let i = 0; i < el.lN; i++) used = Math.max(used, el.lSlots[i * SLOT + S_USED]);
  if (el.lLostPass === used) return false;
  if (el.parentElement === null || isFloat(el) || readsBaseline(el)) return false;
  return true;
}

/** Why canRelayoutAlone said no, for NATIVE_LAYOUT_MISSES=2. */
function whyNotAlone(el: Node): string {
  if (el.lN === 0) return "never laid out";
  if (slotEpoch(el, 0) !== layoutEpoch.n) return "layout not reusable";
  if (el.lOwnChanged) return "own style changed";
  if (el.parentElement === null) return "root";
  if (isFloat(el)) return "float";
  if (readsBaseline(el)) return "parent reads its baseline";
  return "asked for more layouts than it keeps";
}

/** Scratch copy of a box's slots, to compare after it is laid out again. */
const before: number[] = [];

/**
 * Lays a box out again with each set of arguments it kept, the first one last, so its subtree
 * ends up in the state its parent left it. True when every layout's outputs came out the same
 * (its scroll extent aside, when it clips or is out of flow) and so did every intrinsic size its
 * parent asked of it.
 */
function relayoutAlone(el: Node): boolean {
  const n = el.lN;
  before.length = 0;
  for (let i = 0; i < n * SLOT; i++) before.push(el.lSlots[i]);
  layoutCounts.roots++;
  const extentMatters = !isOutOfFlow(el) && !(clipsX(el) && clipsY(el));
  let ok = true;
  for (let i = n - 1; i >= 0; i--) {
    const at = i * SLOT;
    if (before[at + S_EPOCH] !== layoutEpoch.n) continue;
    layoutSlot(el, before, at);
    if (!ok) continue;
    const s = el.lSlots;
    for (let j = 0; j < OUTPUTS; j++) {
      if ((j === 2 || j === 3) && !extentMatters) continue;
      if (!same(s[S_OUT + j], before[at + S_OUT + j])) {
        if (debugMissPaths) {
          console.error(`native: moved output ${j} ${before[at + S_OUT + j]} -> ${s[S_OUT + j]} for [${before[at + S_CBW]},${before[at + S_CBH]} ${before[at + S_FIXW]},${before[at + S_FIXH]} ${before[at + S_FLAGS]}] of ${nodePath(el)} made in pass ${before[at + S_PASS]} used ${before[at + S_USED]} now ${pass}`);
        }
        ok = false;
        break;
      }
    }
  }
  if (!ok) return false;
  // The intrinsic sizes the parent asked for before must be the same now.
  if (el.szOldN > 0 && el.szOldEpoch === sizeGenerationNow()) {
    const k = el.szOld;
    const kept: number[] = [];
    for (let i = 0; i < el.szOldN * SIZE_STRIDE; i++) kept.push(k[i]);
    for (let i = 0; i < kept.length; i += SIZE_STRIDE) {
      const now = sizeAgain(el, kept[i], kept[i + 1], kept[i + 2], kept[i + 3]);
      if (!same(now, kept[i + 4])) {
        if (debugMissPaths) console.error(`native: moved intrinsic size ${kept[i]} ${kept[i + 4]} -> ${now} of ${nodePath(el)}`);
        return false;
      }
    }
  }
  return true;
}

/** layoutBox, which this module can't import without a cycle; box.ts hands it over. */
type Relayout = (el: Node, cbW: number, cbH: number, fixedW: number, fixedH: number, shrink: boolean,
  autoHeight: boolean | undefined, inFlow: boolean, mgP: number, mgN: number) => void;
let layoutBoxAgain: Relayout | null = null;
export function setRelayoutHook(f: Relayout): void {
  layoutBoxAgain = f;
}

/**
 * Walks the dirty paths from the root and lays out, on its own, the first box on each that can be
 * (canRelayoutAlone). True when every dirty box was inside one whose outputs came out the same,
 * so nothing around them needs a layout; false as soon as one wasn't, and the caller lays the page
 * out from its root, where the boxes already done are reused.
 */
export function relayoutDirtyRoots(root: Node): boolean {
  relaidRoots.length = 0;
  // Nothing recorded is current after a layout invalidation that named no box.
  if (lastEpoch !== layoutEpoch.n) {
    if (debugMissPaths) console.error("native: full pass: the layout epoch moved");
    return false;
  }
  if ((root.dirtyBits & LAYOUT_DIRTY) === 0) return true;
  return relayoutBelow(root);
}

function fullBecause(why: string, el: Node): boolean {
  if (debugMissPaths) console.error(`native: full pass: ${why} ${nodePath(el)}`);
  return false;
}

/** The boxes this pass laid out alone, whose positioned descendants are placed again after. */
export const relaidRoots: Node[] = [];

/** The layout epoch the last pass ran in. */
let lastEpoch = -1;
export function endLayoutPass(): void {
  lastEpoch = layoutEpoch.n;
}

/**
 * The bits stay set until the pass ends (clearLayoutDirty): a dirty box below a relayout root that
 * the root's own layout doesn't reach — an absolutely positioned one, placed by the out-of-flow
 * pass — must still find itself dirty when that pass gets to it.
 */
/**
 * Lays out what is dirty below `el` from the deepest boxes that can be laid out alone: a dirty
 * child is first left to the boxes inside it, and only laid out alone itself when they can't
 * cover everything that changed in it. False when neither works for some child: `el` (or a box
 * above it) has to be laid out.
 */
function relayoutBelow(el: Node): boolean {
  if ((el.dirtyBits & LAYOUT_SELF) !== 0) return false;
  for (const c of boxKids(el)) {
    if ((c.dirtyBits & LAYOUT_DIRTY) === 0) continue;
    // A box that isn't rendered has nothing to lay out, unless its own style changed: it may have
    // just stopped being rendered, which its parent has to lay out.
    if (!laidOutAtAll(c)) {
      if (c.lOwnChanged) return false;
      continue;
    }
    if (relayoutBelow(c)) continue;
    if (!canRelayoutAlone(c)) {
      if (debugMissPaths && (c.dirtyBits & LAYOUT_SELF) !== 0) fullBecause(c.lOwnChanged ? "own style changed" : `content changed (${whyNotAlone(c)})`, c);
      return false;
    }
    if (!relayoutAlone(c)) return fullBecause("outputs moved", c);
    relaidRoots.push(c);
  }
  // A box marked only because of boxes that aren't rendered has nothing to lay out.
  return true;
}

/**
 * Whether layout reaches a box at all: not when it isn't rendered. Changes in there keep their
 * dirty bits until the box shows again, which marks it dirty in turn; so does what a box with
 * `content-visibility: hidden` holds (see clearLayoutDirty).
 */
function laidOutAtAll(el: Node): boolean {
  return display(el) !== P.D_NONE;
}

/** Clears the layout bits along every dirty path, once a pass has laid the page out. */
export function clearLayoutDirty(el: Node): void {
  if ((el.dirtyBits & LAYOUT_DIRTY) === 0) return;
  if (!laidOutAtAll(el)) {
    // Its parent was laid out with it hidden; what changed inside stays marked until it shows.
    el.lOwnChanged = false;
    return;
  }
  el.lOwnChanged = false;
  el.szOldN = 0;
  el.dirtyBits &= ~LAYOUT_DIRTY;
  if (el.sv[P.P_CONTENT_VISIBILITY] === P.CV_HIDDEN) return;
  for (const c of el.kids) clearLayoutDirty(c);
  const shadow = el.shadowTree();
  if (shadow !== null) clearLayoutDirty(shadow);
  if (el.markerPseudo !== null) clearLayoutDirty(el.markerPseudo);
}

// ---------------------------------------------------------------------------
// Verify mode

/** The geometry of every box, flattened in tree order: VERIFY_FIELDS numbers per box. */
const VERIFY_FIELDS = 19;
const FIELD_NAMES = ["x", "y", "w", "h", "contentX", "contentY", "contentW", "contentH", "naturalW", "naturalH",
  "relX", "relY", "scrollX", "scrollY", "lines", "lineWidths", "fragments", "fragGeometry", "staticXY"];

function arraySum(a: number[]): number {
  let s = 0;
  for (let i = 0; i < a.length; i++) s = s * 1.000001 + a[i] * (i + 1);
  return s;
}

function snapshotInto(el: Node, out: number[], nodes: Node[]): void {
  // A display: contents element has no box of its own, so whatever geometry it holds isn't
  // drawn; its children are compared.
  if (display(el) === P.D_CONTENTS) {
    for (const c of boxKids(el)) if (display(c) !== P.D_NONE) snapshotInto(c, out, nodes);
    return;
  }
  nodes.push(el);
  out.push(el.x, el.y, el.w, el.h, el.contentX, el.contentY, el.contentW, el.contentH, el.naturalW, el.naturalH,
    el.relX, el.relY, el.scrollX, el.scrollY, el.lines.length, arraySum(el.lineWidths), el.fragKind.length,
    arraySum(el.fragX) + arraySum(el.fragTop) * 3 + arraySum(el.fragW) * 7 + arraySum(el.lineBaseline) * 11,
    el.staticValid ? el.staticX * 3 + el.staticY : -1);
  for (const c of boxKids(el)) {
    // A box that isn't rendered has no geometry to compare.
    if (display(c) !== P.D_NONE) snapshotInto(c, out, nodes);
  }
}

/**
 * NATIVE_VERIFY_LOG=<dir> also writes every mismatch to a file of this process's own in that
 * directory, for a test run whose harness keeps the app's stderr to itself.
 */
const verifyDir = process.env.NATIVE_VERIFY_LOG;
let verifyFile = "";
let verifyText = "";
function reportMismatch(line: string): void {
  console.error(line);
  if (verifyDir === undefined || verifyDir === "") return;
  if (verifyFile === "") verifyFile = `${verifyDir}/verify-${Date.now()}-${Math.floor(Math.random() * 1e9)}.log`;
  verifyText += `${document.title}\t${line}\n`;
  writeFileSync(verifyFile, verifyText);
}

/** Where a node sits, for a mismatch report: its tag, id and classes up the tree. */
function nodePath(el: Node): string {
  const parts: string[] = [];
  let n: Node | null = el;
  while (n !== null && parts.length < 6) {
    let s = n.isTextNode ? "#text" : n.localName;
    const id = n.isElementNode ? (n as Element).getAttribute("id") : null;
    if (id !== null && id !== "") s += "#" + id;
    const cls = n.isElementNode ? (n as Element).getAttribute("class") : null;
    if (cls !== null && cls !== "") s += "." + cls.trim().split(/\s+/).slice(0, 3).join(".");
    parts.unshift(s);
    n = n.parentElement;
  }
  return parts.join(" > ");
}

/**
 * Verify mode: lays the page out again from scratch after an incremental layout and reports
 * every box whose geometry differs. The from-scratch layout is the one the frame keeps, so each
 * frame is checked against a correct start.
 */
export function verifyLayout(root: Node, full: () => void): void {
  const before: number[] = [];
  const nodes: Node[] = [];
  snapshotInto(root, before, nodes);
  // Every layout a box keeps that would still be reused, to check against the one the full pass
  // makes for the same arguments: a kept layout that is wrong can hide behind a caller that
  // ignores it this frame and show up in a later one.
  const kept: number[] = [];
  for (let k = 0; k < nodes.length; k++) {
    const el = nodes[k];
    for (let i = 0; i < el.lN; i++) {
      if (!current(el, i)) continue;
      kept.push(k);
      for (let j = 0; j < SLOT; j++) kept.push(el.lSlots[i * SLOT + j]);
    }
  }
  // A new epoch empties every box's intrinsic sizes and recorded layout, so the second pass
  // works everything out again, and records it for the next frame to reuse.
  layoutEpoch.n++;
  forceFull = true;
  try {
    full();
  } finally {
    forceFull = false;
  }
  const after: number[] = [];
  const nodesAfter: Node[] = [];
  snapshotInto(root, after, nodesAfter);
  if (nodes.length !== nodesAfter.length) {
    layoutCounts.mismatches++;
    reportMismatch(`native: layout mismatch: box tree has ${nodes.length} boxes incremental, ${nodesAfter.length} full`);
    return;
  }
  let reported = 0;
  for (let at = 0; at < kept.length; at += SLOT + 1) {
    const el = nodes[kept[at]];
    const o = at + 1;
    for (let i = 0; i < el.lN; i++) {
      const s = el.lSlots;
      if (!sameInputs(s, i * SLOT, kept[o + S_CBW], kept[o + S_CBH], kept[o + S_FIXW], kept[o + S_FIXH],
        kept[o + S_FLAGS], kept[o + S_MGP], kept[o + S_MGN])) continue;
      for (let j = 0; j < OUTPUTS; j++) {
        const a = kept[o + S_OUT + j];
        const b = s[i * SLOT + S_OUT + j];
        if (same(a, b)) continue;
        layoutCounts.mismatches++;
        if (reported < 20) {
          reportMismatch(`native: layout mismatch: ${nodePath(el)} kept layout for [${kept[o + S_CBW]},${kept[o + S_CBH]} ${kept[o + S_FIXW]},${kept[o + S_FIXH]} ${kept[o + S_FLAGS]}] output ${j} incremental=${a} full=${b}`);
        }
        reported++;
        break;
      }
    }
  }
  for (let i = 0; i < nodes.length; i++) {
    for (let f = 0; f < VERIFY_FIELDS; f++) {
      const a = before[i * VERIFY_FIELDS + f];
      const b = after[i * VERIFY_FIELDS + f];
      if (same(a, b)) continue;
      layoutCounts.mismatches++;
      if (reported < 20) {
        reportMismatch(`native: layout mismatch: ${nodePath(nodes[i])} ${FIELD_NAMES[f]} incremental=${a} full=${b}`);
      }
      reported++;
    }
  }
}
