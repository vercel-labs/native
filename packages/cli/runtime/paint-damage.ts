// Damage-limited painting.
//
// With the compositor off, a frame that only changed a few boxes can record just the regions
// those boxes painted, and leave the rest of the window's retained backing alone. The damage is
// the union of each changed node's painted bounds before and after the frame; the painter clips
// the display list to those rectangles and walks past boxes whose subtree cannot reach them.
//
// Anything that can't be localised asks for a full repaint: a page-wide restyle, a resize, a
// scroll, a full layout pass, or a change whose old bounds were never recorded. The painter's
// verification mode (NATIVE_VERIFY_DAMAGE) paints a full frame too and compares.

import * as P from "../shared/props.ts";
import type { Node } from "./dom.ts";
import { Element } from "./dom.ts";
import { paintDamage } from "./invalidation.ts";
import { viewport } from "./layout.ts";
import { absolutePosition } from "./layout/geometry.ts";
import { layoutPasses } from "./layout/box.ts";
import { boxShadows, textShadows } from "./shadows.ts";
import { hasTransform, pageQuad } from "./transform.ts";
import { elementFilter, elementBackdropFilter } from "./filters.ts";
import { display, isReplaced, borderPx } from "./layout/box-model.ts";
import { hostCompositorOn } from "./host.ts";
import { isScrollContainer } from "./layout/flex.ts";

/** Room around a box for antialiased edges and small overhangs; shadows and outlines add more. */
const SLACK = 24;

/** How many separate rectangles are worth repainting before the whole page is cheaper. */
const MAX_RECTS = 8;

/** Damage-limited painting can be turned off with NATIVE_DAMAGE=0, for a comparison or a fallback. */
export const damageEnabled = { on: process.env.NATIVE_DAMAGE === undefined || process.env.NATIVE_DAMAGE === "" || process.env.NATIVE_DAMAGE !== "0" };

/** Paint the frame both a full and a damaged way, and compare the results: NATIVE_VERIFY_DAMAGE. */
export const damageVerify = { on: process.env.NATIVE_VERIFY_DAMAGE !== undefined && process.env.NATIVE_VERIFY_DAMAGE !== "" && process.env.NATIVE_VERIFY_DAMAGE !== "0" };

/** The changed boxes and their ancestors: those paint whatever their recorded ink says, the
 *  ancestors for their own box and the changed boxes (with everything inside them) in full. */
const changedSet = new Map<Node, boolean>();
const ancestorPath = new Map<Node, boolean>();
/** Each box's subtree ink from the last full paint, in viewport coordinates. */
let lastInk = new Map<Node, number[] | null>();
let lastInkPrimed = false;
/** A box painted through a backdrop filter, as the last full paint left it: its place in viewport
 *  coordinates, and how far its filter spreads past what changed. */
interface BackdropBox {
  el: Element;
  box: number[];
  /** The filter's reach in CSS px: a blur samples this far past the pixels that changed. */
  pad: number;
}

/** Whether any box paints through a backdrop filter (kept for the stats) and those boxes, as the
 *  last full paint left them. A change inside such a box repaints the changed region grown by the
 *  filter's reach; a change behind it can change what the filter shows anywhere in the box, which
 *  then repaints whole. */
let pageBackdrop = false;
let backdropBoxes: BackdropBox[] = [];
/** For each backdrop box this frame's damage reached, whether its backdrop is unchanged: the
 *  change was inside it, so the filter's result the last paint left still stands and the host can
 *  draw that back instead of filtering again. */
let backdropReuse = new Map<Element, boolean>();

/** How far a backdrop-filter chain spreads past the pixels it samples. */
function backdropPad(el: Node): number {
  let pad = 0;
  for (const op of elementBackdropFilter(el)) {
    if (op.kind === P.FK_BLUR) pad += Math.ceil(op.a * 3);
    else if (op.kind === P.FK_DROP_SHADOW) pad += Math.ceil(Math.abs(op.dx) + Math.abs(op.dy) + op.blur * 3);
  }
  return pad;
}

/** Whether this frame left the pixels behind the box alone, so the host can keep the filtered
 *  result it has instead of filtering the box again. */
export function backdropReuses(el: Node): boolean {
  return backdropReuse.get(el as Element) === true;
}

/** Whether `el` is `box` or inside it. */
function within(el: Node, box: Node): boolean {
  for (let p: Node | null = el; p !== null; p = p.parentNode) if (p === box) return true;
  return false;
}

/**
 * Adds what the backdrop filters on screen have to repaint for a frame's damage. A change inside
 * such a box is painted with the filter's sample region around it — the changed rectangle grown by
 * how far the filter spreads, clipped to the box — so an animation inside a blurred panel repaints
 * only what moved. A change that isn't inside the box (one behind it, or damage the DOM couldn't
 * name) can change what the filter shows anywhere in it, so the whole box repaints.
 */
export function addBackdropDamage(rects: number[][], changed: Node[], explicit: number[][]): void {
  if (backdropBoxes.length === 0) return;
  const count = rects.length;
  for (const b of backdropBoxes) {
    let reached = false;
    for (let i = 0; i < count; i++) if (overlaps(rects[i], b.box)) { reached = true; break; }
    if (!reached) continue;
    let inside = true;
    for (const r of explicit) if (overlaps(r, b.box)) { inside = false; break; }
    if (inside) {
      for (const el of changed) if (!within(el, b.el)) { inside = false; break; }
    }
    backdropReuse.set(b.el, inside);
    if (!inside) {
      rects.push(b.box);
      continue;
    }
    for (let i = 0; i < count; i++) {
      const r = rects[i];
      if (!overlaps(r, b.box)) continue;
      const x0 = Math.max(b.box[0], r[0] - b.pad);
      const y0 = Math.max(b.box[1], r[1] - b.pad);
      const x1 = Math.min(b.box[0] + b.box[2], r[0] + r[2] + b.pad);
      const y1 = Math.min(b.box[1] + b.box[3], r[1] + r[3] + b.pad);
      if (x1 > x0 && y1 > y0) rects.push([x0, y0, x1 - x0, y1 - y0]);
    }
  }
}

/** The damage the current frame paints: null rects means a full repaint. */
export const damage = {
  full: true,
  rects: [] as number[][],
  /** The nodes that named the damage, for tests and the frame timings. */
  nodes: 0,
  /** Whether the frame painted only damaged regions. */
  limited: false,
  /** Why this frame was (or wasn't) damage-limited, for the stats line. */
  reason: "start",
};

/** The layout pass that was current when the last paint ran: a full pass since then is unknown
 *  damage. */
let seenFullPasses = 0;
/** The first frame has no previous backing to keep; it is always full. */
let primed = false;

/** The rectangles a node's painting covered, in viewport CSS px; null when it has no box. */
export function paintBoundsOf(node: Node): number[] | null {
  let el: Node | null = node;
  if (el !== null && el.nodeType === 3) el = el.parentElement;
  // An inline box has no box of its own: the block it sits in paints its lines.
  while (el instanceof Element && display(el) === P.D_INLINE && !isReplaced(el) && el.parentElement !== null) {
    el = el.parentElement;
  }
  if (el === null || !(el instanceof Element)) return null;
  let x: number, y: number, w: number, h: number;
  const quad = hasTransform(el) ? pageQuad(el, abs(el)[0], abs(el)[1]) : null;
  if (quad !== null) {
    x = Math.min(quad[0], quad[2], quad[4], quad[6]);
    y = Math.min(quad[1], quad[3], quad[5], quad[7]);
    w = Math.max(quad[0], quad[2], quad[4], quad[6]) - x;
    h = Math.max(quad[1], quad[3], quad[5], quad[7]) - y;
  } else {
    const p = abs(el);
    x = p[0];
    y = p[1];
    w = el.w;
    h = el.h;
  }
  // Text that cannot wrap paints past its box; text that wraps stays inside it, whatever its
  // unwrapped width is.
  if (el.sv[P.P_WHITE_SPACE] === P.W_NOWRAP || el.sv[P.P_WHITE_SPACE] === P.W_PRE) {
    if (el.naturalW > w) w = el.naturalW;
    if (el.naturalH > h) h = el.naturalH;
  }
  let grow = SLACK;
  for (const s of boxShadows(el)) grow = Math.max(grow, s.blur * 2 + Math.abs(s.dx) + Math.abs(s.dy) + s.spread + SLACK);
  for (const s of textShadows(el)) grow = Math.max(grow, s.blur * 2 + Math.abs(s.dx) + Math.abs(s.dy) + SLACK);
  if (el.sv[P.P_OUTLINE_STYLE] !== 0) {
    grow = Math.max(grow, el.sv[P.P_OUTLINE_WIDTH] + Math.abs(el.sv[P.P_OUTLINE_OFFSET]) + SLACK);
  }
  if (elementFilter(el).length > 0 || elementBackdropFilter(el).length > 0) {
    // The filter region is the border box grown by 10% on every side.
    const ex = w * 0.1, ey = h * 0.1;
    x -= ex; y -= ey; w += 2 * ex; h += 2 * ey;
  }
  return [Math.floor(x - grow), Math.floor(y - grow), Math.ceil(w + 2 * grow), Math.ceil(h + 2 * grow)];
}

function abs(el: Element): number[] {
  return absolutePosition(el);
}

/** Starts a frame's damage: a fresh page, or a full pass since the last paint, is unknown. */
export function beginDamageFrame(): void {
  damage.limited = false;
  changedSet.clear();
  ancestorPath.clear();
  backdropReuse = new Map();
  damage.full = true;
  damage.rects = [];
}

/**
 * Works out what this frame has to paint, from the paint damage the DOM recorded. Called once
 * styles and layout are final: every changed node's old bounds (captured when it was marked) and
 * new bounds together cover what moved.
 */
export function computeDamage(): void {
  if (!damageEnabled.on) return damageFull("damage-off");
  if (!primed) return damageFull("unprimed");
  if (paintDamage.full) return damageFull("full-mark");
  if (layoutPasses.full !== seenFullPasses) return damageFull("full-layout");
  if (paintDamage.nodes.length === 0 && paintDamage.rects.length === 0) return damageFull("no-nodes");
  changedSet.clear();
  ancestorPath.clear();
  const rects: number[][] = [];
  for (let i = 0; i < paintDamage.nodes.length; i++) {
    const node = paintDamage.nodes[i];
    if (!node.isConnected) return damageFull("disconnected");
    const now = paintBoundsOf(node);
    const before = paintDamage.oldBounds[i];
    if (now === null) return damageFull("no-bounds");
    // A box that arrived since the last full paint has no recorded ink; record it now, after
    // layout, so the rest of this frame and the next can cull against it.
    if (before === null) {
      const ink = subtreeInk(node);
      lastInk.set(node, ink);
      if (ink !== null) {
        for (let p: Node | null = node.parentNode; p !== null; p = p.parentNode) {
          const pi = lastInk.get(p);
          if (pi === undefined) continue;
          lastInk.set(p, pi === null ? ink : union(pi, ink));
        }
      }
    }
    const rect = before === null ? now : union(before, now);
    rects.push(rect);
    addFollowingSiblingDamage(node, rects);
    addScrollbarDamage(node, rects);
    // The changed box paints in full, and every ancestor paints its own box, whatever their
    // recorded ink covered: a box that grew past its old bounds still has to draw the new part.
    changedSet.set(node, true);
    for (let p: Node | null = node.parentNode; p !== null; p = p.parentNode) ancestorPath.set(p, true);
  }
  for (const r of paintDamage.rects) rects.push(r);
  // A backdrop filter samples the pixels behind its box: the damage covers the filter's region.
  addBackdropDamage(rects, paintDamage.nodes, paintDamage.rects);
  const merged = mergeRects(rects);
  if (merged === null) return damageFull(mergeReason);
  damage.full = false;
  damage.rects = merged;
  damage.limited = true;
  damage.reason = "damaged";
  damage.nodes = paintDamage.nodes.length;
}

/** The thumb of each scroll container as the last paint left it, in page coordinates: a box
 *  inside it that changed size can move or resize the thumb without moving the content around
 *  it, and only the thumb's old and new places need repainting. */
const lastThumbs = new Map<Node, number[][]>();

/** Called by the scrollbar painter with the thumb's final page rectangle. */
export function noteScrollThumb(el: Node, x: number, y: number, w: number, h: number, horizontal: boolean): void {
  let rects = lastThumbs.get(el);
  if (rects === undefined) {
    rects = [];
    lastThumbs.set(el, rects);
  }
  const at = horizontal ? 1 : 0;
  if (rects.length <= at) {
    rects.push([x, y, w, h]);
    rects.push([x, y, w, h]);
  }
  rects[at] = [x, y, w, h];
}

/**
 * A box that grows or shrinks moves the in-flow boxes after it. The damage above covers the box
 * itself; when it has a following in-flow sibling anywhere on the way to the root, the box that
 * holds both paints instead, so the moved siblings come with it. A streaming row is the last
 * child all the way up (positioned siblings don't move in flow), so it stays local.
 */
function addFollowingSiblingDamage(node: Node, rects: number[][]): void {
  let child: Node = node;
  let parent: Node | null = node.parentElement;
  while (parent !== null) {
    if (hasFollowingInFlow(parent, child)) {
      const box = paintBoundsOf(parent);
      if (box !== null) rects.push(box);
      return;
    }
    child = parent;
    parent = parent.parentElement;
  }
}

/** Whether `parent` lays out anything in flow after `child`. */
function hasFollowingInFlow(parent: Node, child: Node): boolean {
  const kids = parent.kids;
  let after = false;
  for (let i = 0; i < kids.length; i++) {
    const k = kids[i];
    if (k === child) {
      after = true;
      continue;
    }
    if (!after || k.pseudoKind !== P.PE_NONE) continue;
    // Whitespace between blocks takes no room of its own; a run with a glyph in it does.
    if (k.nodeType === 3 && !hasVisibleText(k.ownText)) continue;
    if (k instanceof Element) {
      if (display(k) === P.D_NONE) continue;
      if (k.sv[P.P_POSITION] === P.POS_ABSOLUTE || k.sv[P.P_POSITION] === P.POS_FIXED) continue;
    }
    return true;
  }
  return false;
}

function hasVisibleText(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c !== 32 && c !== 9 && c !== 10 && c !== 13 && c !== 12) return true;
  }
  return false;
}

/** Adds the old and new thumb rectangles of each scroll container above `node`. */
function addScrollbarDamage(node: Node, rects: number[][]): void {
  for (let el: Node | null = node; el !== null; el = el.parentNode) {
    if (!(el instanceof Element) || !isScrollContainer(el)) continue;
    const p = absolutePosition(el);
    const thick = el.sv[P.P_SCROLLBAR_WIDTH] === P.SBW_THIN ? 3 : 6;
    const bt = borderPx(el.sv[P.P_BORDER_TOP_WIDTH]);
    const br = borderPx(el.sv[P.P_BORDER_RIGHT_WIDTH]);
    const bl = borderPx(el.sv[P.P_BORDER_LEFT_WIDTH]);
    const bb = borderPx(el.sv[P.P_BORDER_BOTTOM_WIDTH]);
    const fresh: number[][] = [];
    const viewY = el.clientHeight, totalY = el.scrollHeight;
    if (totalY > viewY + 0.5 && (el.sv[P.P_OVERFLOW_Y] === P.OV_AUTO || el.sv[P.P_OVERFLOW_Y] === P.OV_SCROLL)) {
      const track = viewY - 4;
      const thumb = Math.max(24, (track * viewY) / totalY);
      const shift = ((track - thumb) * el.scrollY) / (totalY - viewY);
      fresh.push([p[0] + el.w - br - (thick + 3), p[1] + bt + 2 + shift, thick, thumb]);
    }
    const viewX = el.clientWidth, totalX = el.scrollWidth;
    if (totalX > viewX + 0.5 && (el.sv[P.P_OVERFLOW_X] === P.OV_AUTO || el.sv[P.P_OVERFLOW_X] === P.OV_SCROLL)) {
      const track = viewX - 4;
      const thumb = Math.max(24, (track * viewX) / totalX);
      const shift = ((track - thumb) * el.scrollX) / (totalX - viewX);
      fresh.push([p[0] + bl + 2 + shift, p[1] + el.h - bb - (thick + 3), thumb, thick]);
    }
    const old = lastThumbs.get(el);
    if (old !== undefined) for (const r of old) rects.push(r);
    for (const r of fresh) rects.push(r);
  }
}

function damageFull(reason: string): void {
  changedSet.clear();
  ancestorPath.clear();
  damage.full = true;
  damage.limited = false;
  damage.reason = reason;
  damage.rects = [];
  damage.nodes = 0;
}

/**
 * Adds rectangles to a frame that already has damage (a text change plus an animation). Answers
 * false when the union can't stay small, in which case the whole page is painted.
 */
export function addDamageRects(extra: number[][]): boolean {
  if (damage.full) return false;
  const merged = mergeRects(damage.rects.concat(extra));
  if (merged === null) return false;
  damage.rects = merged;
  return true;
}

/** The serials of the boxes this frame damages, comma-separated: with the damaged rectangles, what
 *  a compositing window is asked to patch over the picture it presented last. */
export function damageSerialsText(): string {
  let out = "";
  for (let i = 0; i < paintDamage.nodes.length; i++) {
    const node = paintDamage.nodes[i];
    out += (out === "" ? "" : ",") + node.serial;
  }
  return out;
}

/** Asks this frame to paint the whole page. */
export function markDamageFull(reason: string): void {
  damageFull(reason);
}

/** The union of two rectangles. */
function union(a: number[], b: number[]): number[] {
  const x = Math.min(a[0], b[0]);
  const y = Math.min(a[1], b[1]);
  return [x, y, Math.max(a[0] + a[2], b[0] + b[2]) - x, Math.max(a[1] + a[3], b[1] + b[3]) - y];
}

/**
 * Merges the damaged rectangles, cuts them to the viewport, and answers null when there are too
 * many or they cover too much: the whole page is simpler then.
 */
let mergeReason = "too-much";

function mergeRects(input: number[][]): number[][] | null {
  const out: number[][] = [];
  for (const r of input) {
    const x0 = Math.max(0, Math.floor(r[0]));
    const y0 = Math.max(0, Math.floor(r[1]));
    const x1 = Math.min(viewport.w, Math.ceil(r[0] + r[2]));
    const y1 = Math.min(viewport.h, Math.ceil(r[1] + r[3]));
    if (x1 <= x0 || y1 <= y0) continue;
    let rect = [x0, y0, x1 - x0, y1 - y0];
    // Fold it into a rectangle it overlaps when the union stays close to the two areas: two
    // rectangles that meet at a corner would otherwise make one big box that repaints the empty
    // space between them.
    for (let i = 0; i < out.length; ) {
      const other = out[i];
      const box = union(other, rect);
      const sum = other[2] * other[3] + rect[2] * rect[3];
      if (overlaps(other, rect) && box[2] * box[3] <= sum * 1.25) {
        rect = box;
        out.splice(i, 1);
        i = 0;
      } else {
        i++;
      }
    }
    out.push(rect);
  }
  if (out.length === 0) { mergeReason = "empty"; return null; }
  if (out.length > MAX_RECTS) { mergeReason = "too-many:" + out.length; return null; }
  let area = 0;
  for (const r of out) area += r[2] * r[3];
  if (area >= viewport.w * viewport.h * 0.6) {
    mergeReason = "too-big:" + Math.round((area * 100) / (viewport.w * viewport.h));
    return null;
  }
  mergeReason = "ok";
  return out;
}

function overlaps(a: number[], b: number[]): boolean {
  return a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3];
}

/** True when any damage rectangle touches the rectangle given. */
export function damageTouches(x: number, y: number, w: number, h: number): boolean {
  if (damage.full) return true;
  for (const r of damage.rects) {
    if (x < r[0] + r[2] && r[0] < x + w && y < r[1] + r[3] && r[1] < y + h) return true;
  }
  return false;
}

/** Called by the frame once the damage has been painted. */
export function endDamageFrame(): void {
  primed = true;
  seenFullPasses = layoutPasses.full;
}

// ---------------------------------------------------------------------------
// Subtree ink: the region a box and everything under it can paint, in viewport coordinates. A
// damaged frame walks past a box whose ink misses every damaged rectangle: its pixels can't
// change, since nothing inside it was marked.

let inkCache = new Map<Node, number[] | null>();

/** The page box a node's own painting can reach, without its children. */
function ownInk(el: Node, x: number, y: number, w: number, h: number): number[] {
  if (!(el instanceof Element)) return [x, y, w, h];
  // The ink is the box plus what genuinely paints past it: shadows, an outline, a filter region.
  // It stays tight (a pixel for antialiasing), so a row doesn't reach a scrollbar strip beside it.
  let grow = 1;
  for (const s of boxShadows(el)) grow = Math.max(grow, s.blur * 2 + Math.abs(s.dx) + Math.abs(s.dy) + s.spread + 1);
  for (const s of textShadows(el)) grow = Math.max(grow, s.blur * 2 + Math.abs(s.dx) + Math.abs(s.dy) + 1);
  if (el.sv[P.P_OUTLINE_STYLE] !== 0) {
    grow = Math.max(grow, el.sv[P.P_OUTLINE_WIDTH] + Math.abs(el.sv[P.P_OUTLINE_OFFSET]) + 1);
  }
  if (elementFilter(el).length > 0 || elementBackdropFilter(el).length > 0) {
    const ex = w * 0.1, ey = h * 0.1;
    x -= ex; y -= ey; w += 2 * ex; h += 2 * ey;
  }
  // Text that cannot wrap is painted past its box; wrapped text stays inside it.
  if (el.sv[P.P_WHITE_SPACE] === P.W_NOWRAP || el.sv[P.P_WHITE_SPACE] === P.W_PRE) {
    if (el.naturalW > w) w = el.naturalW;
    if (el.naturalH > h) h = el.naturalH;
  }
  return [x - grow, y - grow, w + 2 * grow, h + 2 * grow];
}

/**
 * The region a box's subtree can paint, from the layout tree: a transformed box contributes its
 * projected quad, everything else its own box grown for shadows and outlines, unioned with its
 * children's ink. Null for a node with no box of its own (a text run paints inside its parent's).
 */
export function subtreeInk(el: Node): number[] | null {
  const cached = inkCache.get(el);
  if (cached !== undefined) return cached;
  if (el instanceof Element && elementBackdropFilter(el).length > 0) pageBackdrop = true;
  let box: number[] | null = null;
  if (el instanceof Element && display(el) !== P.D_NONE) {
    if (hasTransform(el)) {
      const p = absolutePosition(el);
      const quad = pageQuad(el, p[0], p[1]);
      if (quad !== null) {
        const x = Math.min(quad[0], quad[2], quad[4], quad[6]);
        const y = Math.min(quad[1], quad[3], quad[5], quad[7]);
        box = ownInk(el, x, y, Math.max(quad[0], quad[2], quad[4], quad[6]) - x,
          Math.max(quad[1], quad[3], quad[5], quad[7]) - y);
      } else {
        box = ownInk(el, p[0], p[1], el.w, el.h);
      }
    } else {
      const p = absolutePosition(el);
      box = ownInk(el, p[0], p[1], el.w, el.h);
    }
  }
  const kids = el.kids;
  for (let i = 0; i < kids.length; i++) {
    const k = kids[i];
    if (!(k instanceof Element) || display(k) === P.D_NONE) continue;
    const ik = subtreeInk(k);
    if (ik === null) continue;
    box = box === null ? ik : union(box, ik);
  }
  if (box !== null && el instanceof Element && elementBackdropFilter(el).length > 0) {
    backdropBoxes.push({ el, box, pad: backdropPad(el) });
  }
  inkCache.set(el, box);
  return box;
}

/** Starts a paint's ink cache. */
export function beginInk(): void {
  inkCache = new Map<Node, number[] | null>();
}

/** Whether the box is a changed box or inside one: it paints regardless of its recorded ink. */
export function onDamagePath(el: Node): boolean {
  if (ancestorPath.get(el) === true) return true;
  for (let p: Node | null = el; p !== null; p = p.parentNode) {
    if (changedSet.get(p) === true) return true;
  }
  return false;
}

/** Whether the box's recorded subtree ink reaches a damaged rectangle. A box with no recorded
 *  ink paints: a full frame has not run since it was last painted alone. */
export function lastInkHitsDamage(el: Node): boolean {
  const ink = lastInk.get(el);
  if (ink === undefined || ink === null) return true;
  if (damageTouches(ink[0], ink[1], ink[2], ink[3])) return true;
  // A box that scrolled into the damage since the last full paint has its ink recorded where it
  // was then: it is skipped only when its place now misses the damage too.
  if (!(el instanceof Element) || !el.isConnected) return false;
  const p = absolutePosition(el);
  return damageTouches(p[0], p[1], el.w, el.h);
}

/** Records every box's subtree ink after a full paint, for later damaged frames to cull against. */
export function recordFullInk(root: Node): void {
  pageBackdrop = false;
  backdropBoxes = [];
  // The reuse record is this frame's, made by computeDamage: the damage verification paints its
  // reference frame between computing the damage and painting it.
  beginInk();
  subtreeInk(root);
  lastInk = inkCache;
  lastInkPrimed = true;
}

export function inkPrimed(): boolean {
  return lastInkPrimed;
}
