// Composited layers.
//
// A transform or opacity animation doesn't change the page's style or its layout: the box keeps
// its cascade and its box, and only how the layer is composited moves. Browsers use that to skip
// style, layout and paint for such a frame, and update the compositor instead. This module does
// the same for the host's display list: the paint pass reports the index of the transform and
// opacity commands it writes for an element, and a frame where only compositor properties moved
// edits those commands in place and presents the list again.
//
// The pixels are the full path's: the same commands are replayed, with the same matrix and the
// same group alpha a fresh paint would have written.

import * as P from "../shared/props.ts";
import type { Node } from "./dom.ts";
import { Element } from "./dom.ts";
import { display } from "./layout/box-model.ts";
import { dirty, markPaintDirty, setCompositorStyleInvalidation } from "./invalidation.ts";
import { hasTransform, pageMatrix } from "./transform.ts";
import { viewport } from "./layout.ts";
import { absolutePosition } from "./layout/geometry.ts";
import { hostDamageReference, hostPresent, hostPresentRegion, hostUpdateOpacity, hostUpdateTransform, hostVerifyDamage } from "./host.ts";
import { damageVerify } from "./paint-damage.ts";

/** Bit flags for what the last paint recorded for an element. */
const RECORDED_TRANSFORM = 1;
const RECORDED_OPACITY = 2;

/**
 * The rectangles the pending compositor elements cover, old and new, for a frame that is painting
 * anyway: its text damage and these together let the paint record only the regions that change,
 * animations included. Null when one of them can't be answered for (a missing matrix, a hidden
 * back face), which asks for a full paint.
 */
export function pendingDamageRects(): number[][] | null {
  const out: number[][] = [];
  for (let i = 0; i < pendingList.length; i++) {
    const el = pendingList[i];
    const rec = recorded.get(el);
    if (rec === undefined) return null;
    if (el.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN) return null;
    const hasT = hasTransform(el);
    if (hasT !== ((rec.bits & RECORDED_TRANSFORM) !== 0)) return null;
    if (hasT) {
      const m = pageMatrix(el, rec.x, rec.y);
      if (m === null || rec.m === null) return null;
      out.push(quadBounds(rec.x, rec.y, rec.w, rec.h, rec.m));
      out.push(quadBounds(rec.x, rec.y, rec.w, rec.h, [m.a, m.b, m.c, m.d, m.e, m.f]));
    }
    const group = el.sv[P.P_OPACITY] < 1;
    // An opacity change doesn't move the box, and the record only holds a place for a box that
    // also has a transform, so the box's own place now is the rectangle to repaint — for a group
    // starting or ending, and for one that is fading.
    if (group !== ((rec.bits & RECORDED_OPACITY) !== 0)) {
      if (!hasT) {
        const p = absolutePosition(el);
        out.push([p[0], p[1], el.w, el.h]);
      }
      continue;
    }
    if (group && !hasT) {
      const p = absolutePosition(el);
      out.push([p[0], p[1], el.w, el.h]);
    }
  }
  return out;
}

/** The elements this frame's animation moved through the compositor, in frame order. */
export function pendingElements(): Node[] {
  return pendingList;
}

/** The rectangles a compositor frame changes on screen: the old and new places of the moving
 *  boxes, for the host to present over the retained backing. */
export const compositeDamage = { rects: [] as number[][], valid: true, usedRegion: false };

/** How many frames took the compositor path, and how many needed the page painted instead. */
export const compositorStats = { frames: 0, fallbacks: 0 };

/** What the display list holds for each element painted with a compositor command. */
class Recorded {
  /** RECORDED_TRANSFORM and RECORDED_OPACITY bits. */
  bits: number = 0;
  /** The commands the paint pass recorded, by index in the host's display list. An element can
   *  have more than one of each: a floats-only pass paints an opacity box a second time. */
  transforms: number[] = [];
  opacities: number[] = [];
  /** The box origin and size the paint pass drew the transform around, and that matrix. Layout
   *  can't move while an animation only moves compositor properties, so a later frame reuses the
   *  origin exactly and can compare the old and new places for damage. */
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
  m: number[] | null = null;
}
const recorded = new Map<Node, Recorded>();
/** Elements whose compositor properties moved since the last painted frame, in frame order. */
const pendingList: Node[] = [];
const pendingSet = new Map<Node, boolean>();

/** What the paint recorded for a scroll container: the transform its content is painted under,
 *  and the transform a visible scrollbar's thumb is painted under. A scroll step edits these
 *  instead of painting the page again. */
class ScrollRecord {
  content: number = -1;
  /** Whether the list holding the content transform is the whole page, which a frame can present. */
  full: boolean = false;
  barV: number = -1;
  barH: number = -1;
  /**
   * The transform commands that carry positioned boxes painted outside the content transform
   * (positioned boxes are painted by the stacking context that contains them, above this
   * container's transform), with the offsets the paint used. A scroll edits them along with the
   * content, so those boxes move with it instead of the container painting the page again.
   */
  outsideCmds: OutsideScroll[] = [];
}

/** One positioned box's scroll transform: its command, and the offsets it was painted at. */
interface OutsideScroll {
  index: number;
  baseX: number;
  baseY: number;
}
const scrollRecords = new Map<Node, ScrollRecord>();

// What the last paint did with an element's scrollbars: 0 draws none (the style hides them), 1 drew
// them, 2 left them out because they had faded. A scroll step composites over a bar that is drawn,
// and asks for a paint when the bar has to appear again.
const BAR_NONE = 0;
const BAR_DRAWN = 1;
const BAR_FADED = 2;
const barStates = new Map<Node, number>();

/** Forgets the commands a full paint is about to replace. */
export function clearRecorded(): void {
  recorded.clear();
  scrollRecords.clear();
  barStates.clear();
}

/** The paint pass drew this element's scrollbars, left them out, or has none to draw. */
export function noteScrollBarState(el: Node, state: number): void {
  barStates.set(el, state);
}

export { BAR_NONE, BAR_DRAWN, BAR_FADED };

/** What the last paint did with the element's scrollbars; a bar that has to appear needs a paint. */
export function scrollBarState(el: Node): number {
  const s = barStates.get(el);
  return s === undefined ? BAR_FADED : s;
}

function scrollRecordFor(el: Node): ScrollRecord {
  let r = scrollRecords.get(el);
  if (r === undefined) {
    r = new ScrollRecord();
    scrollRecords.set(el, r);
  }
  return r;
}

/** The paint pass recorded a scroll container's content under the transform at `index`; `full` is
 *  false for a damaged list, which holds only the regions that changed and can't be composited
 *  as a whole. */
export function noteScroll(el: Node, index: number, full: boolean): void {
  const r = scrollRecordFor(el);
  r.content = index;
  r.full = full;
}

/**
 * Whether the current paint has recorded `el`'s content under a scroll transform: only then can a
 * positioned box below it carry a command that scrolls with the content.
 */
export function scrollContentRecorded(el: Node): boolean {
  const r = scrollRecords.get(el);
  return r !== undefined && r.content >= 0 && r.full;
}

/**
 * The paint pass is painting a positioned box from a context that is not inside `el`'s content
 * transform, so the box carries a transform of its own at `index`: identity where it was painted,
 * and moved by every scroll of `el`, which edits the command along with the content transform.
 * `paint.ts` records one for each scroll container up to the box's own stacking context, whose
 * painting is inside every container above it.
 */
export function noteOutsideScrollTransform(el: Node, index: number): void {
  const r = scrollRecords.get(el);
  if (r === undefined || r.content < 0) return;
  const e = el as Element;
  r.outsideCmds.push({ index, baseX: e.scrollX, baseY: e.scrollY });
}

/** The paint pass drew a scrollbar thumb under the transform at `index`. */
export function noteScrollBar(el: Node, index: number, horizontal: boolean): void {
  const r = scrollRecordFor(el);
  if (horizontal) r.barH = index;
  else r.barV = index;
}

/**
 * A scroll moved: the recorded transforms carry the content, the positioned boxes painted outside
 * it and the thumb, and the frame only composites. Answers false when the list can't answer for
 * it — nothing recorded (the element wasn't painted as a scroll container) — and the caller
 * paints the page instead.
 */
export function updateScroll(el: Node, x: number, y: number, viewW: number, viewH: number,
                            totalW: number, totalH: number): boolean {
  const r = scrollRecords.get(el);
  if (r === undefined || r.content < 0 || !r.full) return false;
  if (hostUpdateTransform(r.content, 1, 0, 0, 1, -x, -y) === 0) return false;
  // A positioned box painted outside the content transform moved by the change in the offsets
  // since its paint: it carries that in a transform command of its own.
  for (let i = 0; i < r.outsideCmds.length; i++) {
    const o = r.outsideCmds[i];
    if (hostUpdateTransform(o.index, 1, 0, 0, 1, o.baseX - x, o.baseY - y) === 0) return false;
  }
  if (r.barV >= 0 &&
    hostUpdateTransform(r.barV, 1, 0, 0, 1, 0, thumbShift(viewH, totalH, y)) === 0) return false;
  if (r.barH >= 0 &&
    hostUpdateTransform(r.barH, 1, 0, 0, 1, thumbShift(viewW, totalW, x), 0) === 0) return false;
  // The scroll moves content inside the scrollport: that box is what the host has to present.
  const p = absolutePosition(el);
  compositeDamage.rects.push([p[0], p[1], el.w, el.h]);
  dirty.composite = true;
  return true;
}

/** The distance a thumb sits from the start of its track: the one formula the paint and a scroll
 *  step both use. */
function thumbShift(view: number, total: number, offset: number): number {
  if (total <= view) return 0;
  const track = view - 4;
  const thumb = Math.max(24, (track * view) / total);
  return ((track - thumb) * offset) / (total - view);
}

function recordFor(el: Node): Recorded {
  let r = recorded.get(el);
  if (r === undefined) {
    r = new Recorded();
    recorded.set(el, r);
  }
  return r;
}

/** The paint pass recorded the element's transform at (x, y), as the command at `index`. */
export function noteTransform(el: Node, index: number, x: number, y: number, m: number[]): void {
  const r = recordFor(el);
  r.bits |= RECORDED_TRANSFORM;
  if (r.transforms.indexOf(index) < 0) r.transforms.push(index);
  r.x = x;
  r.y = y;
  r.w = el.w;
  r.h = el.h;
  r.m = [m[0], m[1], m[2], m[3], m[4], m[5]];
}

/** The paint pass recorded the element's opacity group, as the command at `index`. */
export function noteOpacity(el: Node, index: number): void {
  const r = recordFor(el);
  r.bits |= RECORDED_OPACITY;
  if (r.opacities.indexOf(index) < 0) r.opacities.push(index);
}

/**
 * A frame's animation moved only compositor properties on this element. It joins this frame's
 * pending list once, however many of its properties moved.
 */
export function invalidateComposite(el: Node): void {
  // An inline box has no layer of its own: the paint draws its text through the lines around it,
  // so nothing was recorded for the compositor to move. Its change is a paint of the box, and the
  // damage covers the block that draws it rather than the page.
  if (!recorded.has(el) && el instanceof Element && display(el) === P.D_INLINE) {
    markPaintDirty(el);
    return;
  }
  if (pendingSet.get(el) === true) return;
  pendingSet.set(el, true);
  pendingList.push(el);
  dirty.composite = true;
}

/** A script-written transform or opacity updates the layer the last paint recorded instead of
 *  repainting the page, the way an animation of the same properties does. `NATIVE_STYLE_COMPOSITOR=0`
 *  keeps the page paint, for a comparison or for a page the compositor misdraws. */
const styleCompositing = process.env.NATIVE_STYLE_COMPOSITOR !== "0";

function styleChangeComposites(el: Node): boolean {
  if (!styleCompositing || !recorded.has(el)) return false;
  invalidateComposite(el);
  return true;
}

setCompositorStyleInvalidation(styleChangeComposites);

/** Drops the pending elements: a full paint has just recorded their current values. */
/** Starts a frame's compositor damage; a scroll step and an animation both add to it. */
export function resetCompositeDamage(): void {
  compositeDamage.rects = [];
  compositeDamage.valid = true;
  compositeDamage.usedRegion = false;
}

export function clearPending(): void {
  pendingList.length = 0;
  pendingSet.clear();
  dirty.composite = false;
}

/**
 * Updates the display list for a frame whose only changes were transforms and opacities, and
 * presents it. Returns false when the list can't answer for one of them — the element wasn't
 * painted with a command (it gained or lost its transform, say), or its opacity group started or
 * ended — and the caller must paint the page instead.
 */
export function compositeFrame(): boolean {
  compositorStats.frames++;
  for (let i = 0; i < pendingList.length; i++) {
    const el = pendingList[i];
    const rec = recorded.get(el);
    if (rec === undefined) return fallback();
    // A hidden back face is a paint-time decision: the box and its subtree stop painting when a
    // 3D transform turns them away, which only a paint can notice.
    if (el.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN) return fallback();
    const bits = rec.bits;
    const hasT = hasTransform(el);
    // The transform appearing or disappearing changes what the box contains for positioned
    // descendants, so that frame needs layout; only a matrix that already existed can move.
    if (hasT !== ((bits & RECORDED_TRANSFORM) !== 0)) return fallback();
    if (hasT) {
      const m = pageMatrix(el, rec.x, rec.y);
      if (m === null) return fallback();
      if (rec.m !== null) {
        compositeDamage.rects.push(quadBounds(rec.x, rec.y, rec.w, rec.h, rec.m));
        compositeDamage.rects.push(quadBounds(rec.x, rec.y, rec.w, rec.h, [m.a, m.b, m.c, m.d, m.e, m.f]));
      } else {
        compositeDamage.valid = false;
      }
      for (let k = 0; k < rec.transforms.length; k++) {
        if (hostUpdateTransform(rec.transforms[k], m.a, m.b, m.c, m.d, m.e, m.f) === 0) return fallback();
      }
    }
    // opacity: 1 means the box paints with no group at all, so crossing that value is a paint,
    // not a compositor change.
    const group = el.sv[P.P_OPACITY] < 1;
    if (group !== ((bits & RECORDED_OPACITY) !== 0)) return fallback();
    if (group) {
      const alpha = el.sv[P.P_OPACITY];
      if (!hasT) compositeDamage.rects.push([rec.x, rec.y, rec.w, rec.h]);
      for (let k = 0; k < rec.opacities.length; k++) {
        if (hostUpdateOpacity(rec.opacities[k], alpha) === 0) return fallback();
      }
    }
  }
  // This frame is answered; the next one starts with an empty list.
  clearPending();
  const rects = compositeDamage.valid ? mergeCompositeRects(compositeDamage.rects) : null;
  if (rects === null) {
    compositeDamage.usedRegion = false;
    hostPresent(viewport.w, viewport.h);
  } else {
    compositeDamage.usedRegion = true;
    const spec = rectsText(rects);
    if (damageVerify.on) {
      hostDamageReference(viewport.w, viewport.h);
      hostVerifyDamage(spec, viewport.w, viewport.h);
    }
    hostPresentRegion(spec, viewport.w, viewport.h);
  }
  return true;
}

/** The bounding box of a box's four corners through a matrix, grown a little for edges. */
function quadBounds(x: number, y: number, w: number, h: number, m: number[]): number[] {
  let minx = 0, miny = 0, maxx = 0, maxy = 0;
  const px = [x, x + w, x + w, x];
  const py = [y, y, y + h, y + h];
  for (let i = 0; i < 4; i++) {
    const tx = m[0] * px[i] + m[2] * py[i] + m[4];
    const ty = m[1] * px[i] + m[3] * py[i] + m[5];
    if (i === 0) { minx = maxx = tx; miny = maxy = ty; }
    else {
      if (tx < minx) minx = tx;
      if (tx > maxx) maxx = tx;
      if (ty < miny) miny = ty;
      if (ty > maxy) maxy = ty;
    }
  }
  const grow = 8;
  return [Math.floor(minx - grow), Math.floor(miny - grow), Math.ceil(maxx - minx + 2 * grow), Math.ceil(maxy - miny + 2 * grow)];
}

/** Clips the moved boxes to the viewport and drops the empties; null when nothing is left. */
function mergeCompositeRects(input: number[][]): number[][] | null {
  const out: number[][] = [];
  for (const r of input) {
    const x0 = Math.max(0, Math.floor(r[0]));
    const y0 = Math.max(0, Math.floor(r[1]));
    const x1 = Math.min(viewport.w, Math.ceil(r[0] + r[2]));
    const y1 = Math.min(viewport.h, Math.ceil(r[1] + r[3]));
    if (x1 > x0 && y1 > y0) out.push([x0, y0, x1 - x0, y1 - y0]);
  }
  return out.length > 0 ? out : null;
}

function rectsText(rects: number[][]): string {
  let out = "";
  for (let i = 0; i < rects.length; i++) {
    if (i > 0) out += ";";
    out += rects[i][0] + "," + rects[i][1] + "," + rects[i][2] + "," + rects[i][3];
  }
  return out;
}

/** A compositor frame that can't answer for an element: the page is painted instead. */
function fallback(): boolean {
  compositorStats.fallbacks++;
  return false;
}
