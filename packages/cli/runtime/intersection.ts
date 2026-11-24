// IntersectionObserver: after each layout pass, reports how much of an element's box is inside
// the viewport, or inside a root element's box, when that crosses one of the observer's
// thresholds. Its own module because it needs the layout's absolute positions, and layout
// imports the DOM.

import * as P from "../shared/props.ts";
import { DOMRect, Element } from "./dom.ts";
import { absolutePosition } from "./layout/geometry.ts";
import { viewport } from "./viewport.ts";

export interface IntersectionObserverInit {
  /** The box to intersect with: null (the default) is the viewport. */
  root?: Element | null;
  /** Margin around the root's box, as CSS's margin shorthand (`"10px"`, `"0px 20% 0px"`). */
  rootMargin?: string;
  /** Ratios between 0 and 1 at which to report a change; a number or a list, 0 by default. */
  threshold?: number | number[];
}

export class IntersectionObserverEntry {
  get [Symbol.toStringTag](): string { return "IntersectionObserverEntry"; }
  readonly time: number;
  readonly target: Element;
  readonly isIntersecting: boolean;
  readonly intersectionRatio: number;
  readonly boundingClientRect: DOMRect;
  readonly rootBounds: DOMRect | null;
  readonly intersectionRect: DOMRect;

  constructor(time: number, target: Element, isIntersecting: boolean, intersectionRatio: number,
    boundingClientRect: DOMRect, rootBounds: DOMRect | null, intersectionRect: DOMRect) {
    this.time = time;
    this.target = target;
    this.isIntersecting = isIntersecting;
    this.intersectionRatio = intersectionRatio;
    this.boundingClientRect = boundingClientRect;
    this.rootBounds = rootBounds;
    this.intersectionRect = intersectionRect;
  }
}

/** One side of rootMargin, as a pixel value or a percentage of the root's own side. */
class Margin {
  value = 0;
  percent = false;
}

/** Parses rootMargin's one-to-four values into top, right, bottom and left. */
function parseRootMargin(text: string): Margin[] {
  const words = text.trim() === "" ? ["0px"] : text.trim().split(/\s+/);
  const sides: Margin[] = [];
  for (const word of words.slice(0, 4)) {
    const m = new Margin();
    const pct = word.endsWith("%");
    m.percent = pct;
    const n = Number(pct ? word.slice(0, -1) : word.replace(/px$/, ""));
    m.value = n !== n ? 0 : n;
    sides.push(m);
  }
  // CSS's shorthand: one value is all four, two are vertical and horizontal, three are top,
  // horizontal and bottom, four are top, right, bottom and left.
  const top = sides[0];
  const right = sides.length > 1 ? sides[1] : top;
  const bottom = sides.length > 2 ? sides[2] : top;
  const left = sides.length > 3 ? sides[3] : right;
  return [top, right, bottom, left];
}

/** The threshold index the ratio sits at: how many thresholds it has reached or passed. */
function thresholdIndex(thresholds: readonly number[], ratio: number): number {
  let index = 0;
  for (const t of thresholds) {
    if (ratio >= t) index++;
    else break;
  }
  return index;
}

const OBSERVERS: IntersectionObserver[] = [];

/**
 * Watches elements' boxes against the viewport or a root element's box. The first delivery after
 * observe() reports where each target is, and every delivery after that reports the targets whose
 * ratio crossed a threshold, as a browser's does.
 */
export class IntersectionObserver {
  get [Symbol.toStringTag](): string { return "IntersectionObserver"; }
  private callback: (entries: IntersectionObserverEntry[], observer: IntersectionObserver) => void;
  readonly root: Element | null;
  readonly rootMargin: string;
  readonly thresholds: number[];
  private margins: Margin[];
  private targets: Element[] = [];
  /** The threshold index last reported for each target; -1 before the first delivery. */
  private indexes: number[] = [];
  private intersecting: boolean[] = [];
  private queue: IntersectionObserverEntry[] = [];

  constructor(callback: (entries: IntersectionObserverEntry[], observer: IntersectionObserver) => void,
    init: IntersectionObserverInit = {}) {
    this.callback = callback;
    this.root = init.root === undefined ? null : init.root;
    this.rootMargin = init.rootMargin === undefined ? "0px" : init.rootMargin;
    this.margins = parseRootMargin(this.rootMargin);
    const t = init.threshold;
    let list: number[] = [];
    if (t === undefined) list = [0];
    else if (typeof t === "number") list = [t];
    else list = t.slice();
    list = list.filter((v) => v >= 0 && v <= 1).sort((a, b) => a - b);
    this.thresholds = list.length === 0 ? [0] : list;
  }

  observe(target: Element): void {
    if (this.targets.indexOf(target) >= 0) return;
    this.targets.push(target);
    this.indexes.push(-1);
    this.intersecting.push(false);
    if (OBSERVERS.indexOf(this) < 0) OBSERVERS.push(this);
  }

  unobserve(target: Element): void {
    const i = this.targets.indexOf(target);
    if (i < 0) return;
    this.targets.splice(i, 1);
    this.indexes.splice(i, 1);
    this.intersecting.splice(i, 1);
    if (this.targets.length === 0) this.remove();
  }

  disconnect(): void {
    this.targets = [];
    this.indexes = [];
    this.intersecting = [];
    this.remove();
  }

  takeRecords(): IntersectionObserverEntry[] {
    const out = this.queue;
    this.queue = [];
    return out;
  }

  private remove(): void {
    const i = OBSERVERS.indexOf(this);
    if (i >= 0) OBSERVERS.splice(i, 1);
  }

  /** The root's box in viewport coordinates, before rootMargin. */
  private rootBox(): DOMRect | null {
    if (this.root === null) return new DOMRect(0, 0, viewport.w, viewport.h);
    const el = this.root;
    if (!el.isConnected) return null;
    const p = absolutePosition(el);
    return new DOMRect(p[0] + el.contentX, p[1] + el.contentY, el.contentW, el.contentH);
  }

  /** Where one target stands now: its box, the intersection and the ratio of the two areas. */
  private measure(target: Element): IntersectionObserverEntry {
    const root = this.rootBox();
    const shown = target.isConnected && target.sv[P.P_DISPLAY] !== P.D_NONE;
    const p = absolutePosition(target);
    const box = new DOMRect(p[0], p[1], target.w, target.h);
    if (root === null || !shown) {
      return new IntersectionObserverEntry(performance.now(), target, false, 0, box, root, new DOMRect(0, 0, 0, 0));
    }
    const w = root.width;
    const h = root.height;
    const px = (m: Margin, side: number) => m.percent ? (m.value / 100) * side : m.value;
    const top = px(this.margins[0], h);
    const right = px(this.margins[1], w);
    const bottom = px(this.margins[2], h);
    const left = px(this.margins[3], w);
    const leftEdge = Math.max(root.left - left, box.left);
    const topEdge = Math.max(root.top - top, box.top);
    const rightEdge = Math.min(root.right + right, box.right);
    const bottomEdge = Math.min(root.bottom + bottom, box.bottom);
    const iw = Math.max(0, rightEdge - leftEdge);
    const ih = Math.max(0, bottomEdge - topEdge);
    const area = box.width * box.height;
    const ratio = area > 0 ? Math.min(1, (iw * ih) / area) : 0;
    // A box with no area still intersects when a point of it is inside the root.
    const isIntersecting = (iw > 0 && ih > 0) ||
      (area === 0 && box.left >= root.left - left && box.left <= root.right + right &&
        box.top >= root.top - top && box.top <= root.bottom + bottom);
    return new IntersectionObserverEntry(performance.now(), target, isIntersecting, ratio, box, root,
      new DOMRect(leftEdge, topEdge, iw, ih));
  }

  /** Queues an entry for each target whose state crossed one of the thresholds. */
  deliver(): void {
    for (let i = 0; i < this.targets.length; i++) {
      const entry = this.measure(this.targets[i]);
      const index = entry.isIntersecting ? thresholdIndex(this.thresholds, entry.intersectionRatio) : 0;
      if (index === this.indexes[i] && entry.isIntersecting === this.intersecting[i]) continue;
      this.indexes[i] = index;
      this.intersecting[i] = entry.isIntersecting;
      this.queue.push(entry);
    }
    if (this.queue.length === 0) return;
    const entries = this.queue;
    this.queue = [];
    this.callback(entries, this);
  }
}

/**
 * Runs after a layout pass: hands each observer the entries for the targets whose position or
 * size crossed a threshold since its last delivery.
 */
export function deliverIntersectionObservers(): void {
  if (OBSERVERS.length === 0) return;
  for (const observer of OBSERVERS.slice()) observer.deliver();
}
