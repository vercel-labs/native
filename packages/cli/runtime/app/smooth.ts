// Smooth scrolling: a scroll a script asks for that the box's scroll-behavior has travel rather
// than jump to. The journey eases over animation frames, so the loop drives it in an app and a
// test drives it with `frame <ms>`; a wheel or another scroll stops it where it is.

import { Event, document, dispatch, trusted } from "../dom.ts";
import type { Element, Node } from "../dom.ts";
import { dispatchWindow, requestAnimationFrame } from "../window.ts";
import { setCancelSmoothScrollHook, setSmoothScrollHook } from "../smooth-hook.ts";
import { noteScroll } from "./scrollbar.ts";

/** How long a smooth scroll takes from start to target, in ms. */
const SMOOTH_MS = 400;

/** A journey in progress: where the box started, where it is going, and when it set off. */
type Run = { el: Element; fromX: number; fromY: number; toX: number; toY: number; start: number };

const runs: Run[] = [];
let scheduled = false;

/** Sends `el` to (x, y) over animation frames, replacing any journey it was on. */
export function smoothScrollTo(el: Element, x: number, y: number): void {
  cancelSmoothScroll(el);
  runs.push({ el, fromX: el.scrollX, fromY: el.scrollY, toX: x, toY: y, start: -1 });
  schedule();
}

/** Stops the journey `el` is on, if any: it stays where it has got to. */
export function cancelSmoothScroll(el: Node): void {
  for (let i = runs.length - 1; i >= 0; i--) if (runs[i].el === el) runs.splice(i, 1);
}

/** Drops every journey: the page they scrolled is gone, and its boxes with it. */
export function clearSmoothScrolls(): void {
  runs.length = 0;
}

function schedule(): void {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(step);
}

/**
 * Moves every journey on: the eased share of the way at `now`, and its last frame lands exactly
 * on the target. Each move tells the page it scrolled, as a browser's does.
 */
function step(now: number): void {
  scheduled = false;
  if (runs.length === 0) return;
  let more = false;
  for (const run of runs.slice()) {
    const el = run.el;
    if (run.start < 0) run.start = now;
    const t = Math.min(1, (now - run.start) / SMOOTH_MS);
    // Ease in and out: the box gathers speed, then settles, and never turns back.
    const eased = t * t * (3 - 2 * t);
    const beforeX = el.scrollX;
    const beforeY = el.scrollY;
    if (t >= 1) el.scrollInstant(run.toX, run.toY);
    else {
      el.scrollInstant(run.fromX + (run.toX - run.fromX) * eased, run.fromY + (run.toY - run.fromY) * eased);
      more = true;
    }
    if (el.scrollX !== beforeX || el.scrollY !== beforeY) tellScrolled(el);
    if (t >= 1) runs.splice(runs.indexOf(run), 1);
  }
  if (more) schedule();
}

/** A scroll event for the box that moved, and for the window when the page itself moved. */
function tellScrolled(el: Element): void {
  noteScroll(el);
  if (el === document.documentElement) {
    const ev = trusted(new Event("scroll"));
    dispatch(ev, document);
    dispatchWindow(ev);
  } else {
    dispatch(trusted(new Event("scroll")), el);
  }
}

setSmoothScrollHook(smoothScrollTo);
setCancelSmoothScrollHook(cancelSmoothScroll);
