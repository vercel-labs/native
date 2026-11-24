// CSS transitions and animations, driven by the frame clock.
//
// A transition starts wherever an element's computed value changes (computeStyles reports it
// here); an animation starts with the element's style. Each frame writes the values they have
// reached over the cascaded values, so layout and paint see them like any other computed value.
// The clock is the requestAnimationFrame timestamp, which headless runs set with `frame <ms>`.

import * as P from "../shared/props.ts";
import { AC_ACCUMULATE, AC_REPLACE, ANIMATABLE, animKeyframes, animNames, animRows, autoInsetPx, compositeOf, ease, listMix, mixMatrix, mixValue, needsSameUnit, timingText, unitOf, valueList, timingRow } from "../shared/css/anim.ts";
import { EXPR_LEAF, EXPR_SUM, exprRows } from "../shared/css/length-exprs.ts";
import { AnimationEvent, Element, TransitionEvent, dispatch, parseKeyframes, type Node } from "./dom.ts";
import { dirty, incremental, invalidateStyleOf, markFullPaint, markLayoutDirty, markPaintDirty } from "./invalidation.ts";
import { invalidateComposite } from "./compositor.ts";
import { flushLayoutHook } from "./layout-flush-hook.ts";
import { matrixRow, rowMatrix } from "./transform.ts";
import { rootFontSize } from "./root-size.ts";
import { INITIAL_U, INITIAL_V, INHERITS } from "./initial-values.ts";
import { shadowList, type Shadow } from "./shadows.ts";
import { shadowRows } from "../shared/css/shadows.ts";
import { LAYER_FILTER, LAYER_OPACITY, LAYER_TRANSFORM } from "./layers.ts";

/** One property of an element partway through a transition. */
export class Transition {
  p: number = 0;
  fromV: number = 0;
  fromU: number = 0;
  toV: number = 0;
  toU: number = 0;
  /** The clock time the transition started, and its delay, both in ms. */
  start: number = 0;
  delay: number = 0;
  dur: number = 0;
  tf: number[] = [];
  /** The transition has reached its end value and is on its way out. */
  done: boolean = false;
  /** transitionstart has been sent: the delay is over and the transition is active. */
  started: boolean = false;
  /** The object getAnimations() reports for this transition, made on first ask. */
  handle: Animation | null = null;
}

/** One running (or filling) CSS animation of an element. */
export class KeyframeRun {
  name: number = -1;
  /** The @keyframes blocks for the name, each [name id, offset, property, value, unit, ...]. */
  blocks: number[][] = [];
  /** Every property the keyframes declare. */
  props: number[] = [];
  dur: number = 0;
  delay: number = 0;
  /** The timing functions, cycled over the keyframe intervals. */
  tfs: number[][] = [];
  /** -1 is `infinite`; any other value may be fractional. */
  iter: number = 1;
  dir: number = P.AD_NORMAL;
  fill: number = P.AF_NONE;
  play: number = P.APS_RUNNING;
  /** Milliseconds the animation has run; it stops while the animation is paused. */
  elapsed: number = 0;
  /** The clock at the last update, so only the time that passed is added. */
  last: number = 0;
  /** The clock when it was created: getAnimations() reports it as the start time. */
  startAt: number = 0;
  started: boolean = false;
  lastIter: number = -1;
  /** A finite animation has run to its end (its fill may still apply). */
  done: boolean = false;
  /**
   * The composite its keyframe values take when a keyframe doesn't name one: the element's
   * animation-composition for this animation, replace by default.
   */
  comp: number = AC_REPLACE;
  /** The object getAnimations() reports for this animation, made on first ask. */
  handle: Animation | null = null;
  /** The effect a script started this run with, which reads its keyframes and timing back. */
  effect: KeyframeEffect | null = null;
}

/** What an element's transitions and animations need to know from its last cascade. */
class AnimState {
  /** The cascaded value of every property, before any transition or animation changed it. */
  base: number[] = [];
  baseU: number[] = [];
  /** The first computation only records a baseline: nothing transitions from the initial style. */
  settled: boolean = false;
  /** The properties the last frame overrode. */
  props: number[] = [];

  trans: Transition[] = [];
  /** One entry per animation-name in the list; null where the name is `none`. */
  anims: (KeyframeRun | null)[] = [];
  /** The animations a script started, which no style reconciles and only a cancel drops. */
  script: KeyframeRun[] = [];
}

const states: Map<Element, AnimState> = new Map();
/** The elements with something to update each frame. */
const running: Element[] = [];

/** What an animation's timing reads back: getTiming() and the options Element.animate takes. */
export interface EffectTiming {
  delay?: number;
  endDelay?: number;
  direction?: string;
  fill?: string;
  iterationStart?: number;
  iterations?: number;
  duration?: number;
  easing?: string;
}

/** The timing at a moment: getComputedTiming() says how much the timing works out to. */
export interface ComputedEffectTiming {
  duration: number;
  endTime: number;
  activeDuration: number;
  delay: number;
  endDelay: number;
  iterations: number;
  iterationStart: number;
  direction: string;
  fill: string;
  easing: string;
  /** How far the timing's own phase has run, or null before it starts and after it ends. */
  progress: number | null;
  /** The iteration in progress, or null outside the active phase. */
  currentIteration: number | null;
}

/** The options Element.animate takes beyond timing: fill is part of them already. */
export interface KeyframeAnimationOptions extends EffectTiming {
  /** How every frame's values combine with the ones below: replace (the default), add, accumulate. */
  composite?: string;
  /** The pseudo-element the animation applies to ("::before", "::first-letter"), or "" for the
   *  element itself. Only the properties that pseudo-element accepts are animated. */
  pseudoElement?: string;
}

/**
 * What an animation does: the element it moves, the keyframes it moves between, and its timing.
 * A script reads it from Animation.effect, and updateTiming() changes a run in place.
 */
export class KeyframeEffect {
  get [Symbol.toStringTag](): string { return "KeyframeEffect"; }
  /** The element the animation moves, or null for one that moves nothing yet. */
  target: Element | null;
  /** The frames as a script gave them, in order, each [offset, declarations text]. */
  private frames: number[][] = [];
  private frameTexts: string[] = [];
  /** The run it drives; updateTiming writes its timing through. Engine-private. */
  run: KeyframeRun | null = null;
  /** The transition this effect describes instead of a run, when it belongs to one. */
  trans: Transition | null = null;

  constructor(target: Element | null = null, frames: number[][] = [], texts: string[] = []) {
    this.target = target;
    this.frames = frames;
    this.frameTexts = texts;
  }

  /**
   * The keyframes, each with its offset and the declarations it carries. A keyframe's property
   * names are data rather than fields, and scriptc has no computed property write (issue 40), so
   * each frame is assembled as JSON text and parsed into the object a script reads.
   */
  getKeyframes(): any[] {
    const out: any[] = [];
    for (let i = 0; i < this.frameTexts.length; i++) {
      const offset = this.frames[i] !== undefined ? this.frames[i][1] : 0;
      const parts: string[] = ['"offset":' + String(offset), '"computedOffset":' + String(offset), '"composite":"replace"'];
      for (const part of this.frameTexts[i].split(";")) {
        const at = part.indexOf(":");
        if (at < 0) continue;
        const key = part.slice(0, at).trim();
        const value = part.slice(at + 1).trim();
        if (key === "" || value === "") continue;
        parts.push(JSON.stringify(camelKey(key)) + ":" + JSON.stringify(value));
      }
      out.push(JSON.parse("{" + parts.join(",") + "}"));
    }
    return out;
  }

  /** The timing as it was given, with a run's own values filled in. */
  getTiming(): EffectTiming {
    // A transition's effect reports the timing the transition runs with: one iteration, the
    // timing function the transition uses, and a backwards fill (a browser reports it so).
    const trans = this.trans;
    if (trans !== null) {
      return {
        delay: trans.delay,
        endDelay: 0,
        direction: "normal",
        fill: "backwards",
        iterationStart: 0,
        iterations: 1,
        duration: trans.dur,
        easing: timingText(trans.tf),
      };
    }
    const run = this.run;
    return {
      delay: run !== null ? run.delay : 0,
      endDelay: 0,
      direction: dirText(run !== null ? run.dir : P.AD_NORMAL),
      fill: fillText(run !== null ? run.fill : P.AF_NONE),
      iterationStart: 0,
      iterations: run !== null && run.iter < 0 ? Infinity : run !== null ? run.iter : 1,
      duration: run !== null ? run.dur : 0,
      easing: "linear",
    };
  }

  /** The timing worked out: how long the active phase is and where the run is within it. */
  getComputedTiming(): ComputedEffectTiming {
    const trans = this.trans;
    if (trans !== null) {
      const local = now() - trans.start - trans.delay;
      // The transition's backwards fill holds its start value through the delay, so a browser
      // reports progress 0 there; after the active phase there is nothing to fill forwards.
      const before = local < 0;
      const active = local >= 0 && local < trans.dur;
      return {
        duration: trans.dur,
        endTime: trans.delay + trans.dur,
        activeDuration: trans.dur,
        delay: trans.delay,
        endDelay: 0,
        iterations: 1,
        iterationStart: 0,
        direction: "normal",
        fill: "backwards",
        easing: timingText(trans.tf),
        progress: before ? 0 : active ? local / trans.dur : null,
        currentIteration: before || active ? 0 : null,
      };
    }
    const t = this.getTiming();
    const duration = typeof t.duration === "number" ? t.duration : 0;
    const iterations = typeof t.iterations === "number" ? t.iterations : 1;
    const delay = typeof t.delay === "number" ? t.delay : 0;
    const active = iterations === Infinity ? Infinity : duration * iterations;
    const local = now() - (this.run !== null ? this.run.startAt : now());
    let progress: number | null = null;
    let currentIteration: number | null = null;
    const into = local - delay;
    if (into >= 0 && (active === Infinity || into < active)) {
      progress = active > 0 ? into / active : 0;
      currentIteration = duration > 0 ? Math.floor(into / duration) : 0;
    }
    return {
      duration, activeDuration: active,
      endTime: (active === Infinity ? Infinity : delay + active + 0),
      delay,
      endDelay: 0,
      iterations,
      iterationStart: 0,
      direction: typeof t.direction === "string" ? t.direction : "normal",
      fill: typeof t.fill === "string" ? t.fill : "none",
      easing: "linear",
      progress, currentIteration,
    };
  }

  /** Replaces the keyframes of a running animation; the next frame shows them. */
  setKeyframes(keyframes: any): void {
    const made = parseKeyframes(keyframes);
    this.frames = made.rows;
    this.frameTexts = made.texts;
    const run = this.run;
    if (run === null) return;
    run.blocks = made.rows;
    const props: number[] = [];
    for (const row of made.rows) {
      for (let k = 2; k + 2 < row.length; k += 3) if (props.indexOf(row[k]) < 0) props.push(row[k]);
    }
    run.props = props;
    dirty.style = true;
    dirty.layout = true;
    markFullPaint();
  }

  /** Changes the timing of a run in place; the next frame shows it. */
  updateTiming(timing: EffectTiming = {}): void {
    const run = this.run;
    if (run === null) return;
    if (typeof timing.duration === "number") run.dur = timing.duration;
    if (typeof timing.delay === "number") run.delay = timing.delay;
    if (typeof timing.iterations === "number") run.iter = timing.iterations === Infinity ? -1 : timing.iterations;
    if (typeof timing.direction === "string") run.dir = directionValue(timing.direction);
    if (typeof timing.fill === "string") run.fill = fillValue(timing.fill);
    const tf = typeof timing.easing === "string" ? timingRow(timing.easing) : null;
    if (tf !== null) run.tfs = [tf];
    dirty.style = true;
    dirty.layout = true;
    markFullPaint();
  }
}

/** The direction text for an AD_* value, and back. */
function dirText(v: number): string {
  if (v === P.AD_REVERSE) return "reverse";
  if (v === P.AD_ALTERNATE) return "alternate";
  if (v === P.AD_ALTERNATE_REVERSE) return "alternate-reverse";
  return "normal";
}

function fillText(v: number): string {
  if (v === P.AF_FORWARDS) return "forwards";
  if (v === P.AF_BACKWARDS) return "backwards";
  if (v === P.AF_BOTH) return "both";
  return "none";
}

function directionValue(v: string): number {
  if (v === "reverse") return P.AD_REVERSE;
  if (v === "alternate") return P.AD_ALTERNATE;
  if (v === "alternate-reverse") return P.AD_ALTERNATE_REVERSE;
  return P.AD_NORMAL;
}

function fillValue(v: string): number {
  if (v === "forwards") return P.AF_FORWARDS;
  if (v === "backwards") return P.AF_BACKWARDS;
  if (v === "both") return P.AF_BOTH;
  return P.AF_NONE;
}

/** A css property name as a keyframe object writes it: background-color is backgroundColor. */
function camelKey(name: string): string {
  return name.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase());
}

/**
 * The object getAnimations() reports: a running (or filling) transition or CSS animation, as a
 * script sees it. It reads the engine's own state, so its values are current at the frame clock.
 */
export class Animation {
  get [Symbol.toStringTag](): string { return "Animation"; }
  /** The element the transition or animation runs on. */
  readonly el: Element;
  /** The transition it stands for, or null for a keyframe animation. */
  readonly trans: Transition | null;
  readonly anim: KeyframeRun | null;
  /** A script canceled it, so it is idle rather than running. */
  canceled: boolean = false;
  /** Settles `finished`; cleared once it has run. Engine-private. */
  resolveFinished: (() => void) | null = null;
  /** Settles when the transition or animation finishes, and again if a script cancels it. */
  readonly finished: Promise<Animation>;
  /**
   * Settles once the animation can play, which a browser does on the next frame. Here the frame
   * clock already drives it, so a script that awaits it sees the animation it asked for.
   */
  readonly ready: Promise<Animation>;
  /** The effect a transition reports; made the first time a script asks. */
  private transEffect: KeyframeEffect | null = null;

  /** What the animation does: its target, keyframes and timing. A transition's effect carries
   *  no keyframes but reports the timing the transition runs with, as a browser's does. */
  get effect(): KeyframeEffect | null {
    if (this.anim !== null) return this.anim.effect;
    if (this.trans === null) return null;
    if (this.transEffect === null) {
      const made = new KeyframeEffect(this.el);
      made.trans = this.trans;
      this.transEffect = made;
    }
    return this.transEffect;
  }

  constructor(el: Element, trans: Transition | null, anim: KeyframeRun | null) {
    this.el = el;
    this.trans = trans;
    this.anim = anim;
    const self = this;
    this.finished = new Promise<Animation>((resolve) => {
      self.resolveFinished = (): void => resolve(self);
    });
    this.ready = new Promise<Animation>((resolve) => {
      resolve(self);
    });
  }

  /** The property a transition animates, or "" for a keyframe animation. */
  get transitionProperty(): string {
    return this.trans === null ? "" : P.PROPERTY_NAMES[this.trans.p];
  }

  /** The @keyframes name, or "" for a transition. */
  get animationName(): string {
    return this.anim === null ? "" : animNames.name(this.anim.name);
  }

  /** "running", "paused", "finished" or (once canceled) "idle"; a transition has no paused state. */
  get playState(): string {
    if (this.canceled) return "idle";
    if (this.anim !== null) {
      if (this.anim.done) return "finished";
      return this.anim.play === P.APS_PAUSED ? "paused" : "running";
    }
    return "running";
  }

  /** Milliseconds since the transition or animation began, delay included; negative in a delay. */
  get currentTime(): number {
    if (this.anim !== null) return this.anim.elapsed;
    if (this.trans === null) return 0;
    return clock - this.trans.start;
  }

  /**
   * Moves it to `ms` after its start, delay included: with the animation paused, a script sees the
   * values at that point. A run that had ended starts showing its middle again, and a transition
   * is moved the same way.
   */
  set currentTime(ms: number) {
    if (this.anim !== null) {
      this.anim.elapsed = ms;
      // Moving back into the active phase undoes the end, so the fill shows that moment.
      if (this.anim.done && (this.anim.iter < 0 || ms < this.anim.delay + this.anim.dur * this.anim.iter)) {
        this.anim.done = false;
      }
      // The time a script set is where the run is now; the next tick mustn't add the gap to it.
      this.anim.last = clock;
    } else if (this.trans !== null) {
      this.trans.start = clock - ms;
    }
    const st = states.get(this.el);
    if (st !== undefined) syncRunning(this.el, st);
    dirty.style = true;
    dirty.layout = true;
    markFullPaint();
  }

  get startTime(): number {
    return this.anim !== null ? this.anim.startAt : this.trans === null ? 0 : this.trans.start;
  }

  /** Stops it and puts the element back to its cascaded values; `finished` settles. */
  cancel(): void {
    cancelAnimation(this);
  }

  /** Runs it to its end at once, so a fill applies and `finished` settles. */
  finish(): void {
    const st = states.get(this.el);
    if (st === undefined) return;
    if (this.anim !== null) {
      if (this.anim.iter < 0) return; // an infinite animation has no end to jump to
      this.anim.elapsed = this.anim.delay + this.anim.dur * this.anim.iter;
      this.anim.play = P.APS_RUNNING;
    } else if (this.trans !== null) {
      this.trans.start = clock - this.trans.delay - this.trans.dur;
    }
    dirty.style = true;
    dirty.layout = true;
    markFullPaint();
    syncRunning(this.el, st);
  }

  pause(): void {
    if (this.anim !== null) this.anim.play = P.APS_PAUSED;
  }

  play(): void {
    if (this.anim !== null) this.anim.play = P.APS_RUNNING;
  }
}

/**
 * The objects a CSS transition and a CSS animation report: an Animation of their own class, so a
 * script can tell them apart with instanceof, as it does with a browser's CSSTransition and
 * CSSAnimation.
 */
export class CSSTransition extends Animation {}
export class CSSAnimation extends Animation {}

/** The object for one transition or animation, made once and kept on it. */
function handleOf(el: Element, trans: Transition | null, anim: KeyframeRun | null): Animation {
  const held = trans !== null ? trans.handle : anim === null ? null : anim.handle;
  if (held !== null) return held;
  // A transition and a CSS animation are instances of their own classes; an animation a script
  // started is a plain Animation.
  const made: Animation = trans !== null ? new CSSTransition(el, trans, null)
    : anim !== null && anim.name >= 0 ? new CSSAnimation(el, null, anim)
    : new Animation(el, trans, anim);
  if (trans !== null) trans.handle = made;
  else if (anim !== null) anim.handle = made;
  return made;
}

/** Settles a handle's `finished` promise, if a script ever asked for one. */
function settle(held: Animation | null): void {
  if (held === null || held.resolveFinished === null) return;
  const resolve = held.resolveFinished;
  held.resolveFinished = null;
  resolve();
}

/**
 * A subtree that was in the document has left it: every transition in it is canceled where it
 * stands, each reported as transitioncancel, and the element takes the value its cascade names the
 * next time it is styled. Re-inserting the element later starts a transition from there, as a
 * browser does, rather than continuing one across the move.
 */
export function cancelTransitionOnDetach(node: Node): void {
  if (node.nodeType === 1) {
    const el = node as Element;
    const st = states.get(el);
    if (st !== undefined && st.trans.length > 0) {
      for (const t of st.trans) {
        queue("transitioncancel", el, P.PROPERTY_NAMES[t.p], "", transitionElapsed(t));
        const held = t.handle;
        t.handle = null;
        abandon(held);
      }
      st.trans.length = 0;
      st.props.length = 0;
      dirty.style = true;
      dirty.layout = true;
      markFullPaint();
      const at = running.indexOf(el);
      if (at >= 0) running.splice(at, 1);
    }
  }
  for (const k of node.kids) cancelTransitionOnDetach(k);
}

/** Settles a handle whose transition or animation was canceled, so it reads as idle. */
function abandon(held: Animation | null): void {
  if (held === null) return;
  held.canceled = true;
  settle(held);
}

/** Stops one transition or animation where it is and drops it from its element's state. */
function cancelAnimation(held: Animation): void {
  const st = states.get(held.el);
  if (st === undefined || held.canceled) return;
  held.canceled = true;
  const trans = held.trans;
  const anim = held.anim;
  if (anim !== null) {
    const at = st.anims.indexOf(anim);
    if (at >= 0) st.anims[at] = null;
    const scriptAt = st.script.indexOf(anim);
    if (scriptAt >= 0) st.script.splice(scriptAt, 1);
    // A canceled animation is idle: its fill no longer shows.
    anim.done = true;
    anim.handle = null;
    queue("animationcancel", held.el, "", animNames.name(anim.name), anim.elapsed - anim.delay);
    settle(held);
  } else if (trans !== null) {
    const at = st.trans.indexOf(trans);
    if (at >= 0) st.trans.splice(at, 1);
    trans.handle = null;
    queue("transitioncancel", held.el, P.PROPERTY_NAMES[trans.p], "", transitionElapsed(trans));
    settle(held);
  }
  // The values the transition or animation wrote go back to the cascade on the next pass.
  dirty.style = true;
  dirty.layout = true;
  markFullPaint();
  syncRunning(held.el, st);
}

/** How long a transition has been in its active phase, in ms. */
function transitionElapsed(t: Transition): number {
  const local = clock - t.start - t.delay;
  if (local <= 0) return 0;
  return local < t.dur ? local : t.dur;
}

/** The transitions and animations `el` has, and with `subtree` those of all its descendants. */
export function elementAnimations(el: Element, subtree: boolean): Animation[] {
  // A browser forces style and layout for getAnimations(), so an animation the cascade has just
  // produced is there; the clock may also have moved since the last frame, so every value is
  // brought to it first.
  flushLayoutHook();
  animationTick();
  const out: Animation[] = [];
  collectAnimations(el, subtree, out);
  return out;
}

function collectAnimations(el: Element, subtree: boolean, out: Animation[]): void {
  const st = states.get(el);
  if (st !== undefined) {
    // Transitions come first, then CSS animations, then the ones a script started: the order a
    // browser reports them in composition order.
    for (const t of st.trans) out.push(handleOf(el, t, null));
    for (const a of st.anims) {
      if (a !== null && !finished(a)) out.push(handleOf(el, null, a));
    }
    for (const a of st.script) if (!finished(a)) out.push(handleOf(el, null, a));
  }
  if (!subtree) return;
  for (const c of el.kids) if (c instanceof Element) collectAnimations(c, true, out);
}


let clock: number = 0;

/** Sets the frame clock, in ms. The animation frame callback timestamp drives it. */
export function setClock(time: number): void {
  clock = time;
}

export function now(): number {
  return clock;
}

// ---------------------------------------------------------------------------
// Keyframes

const blockCache: Map<number, number[][]> = new Map();

/** The @keyframes blocks of one name, in offset order. */
function blocksFor(name: number): number[][] {
  const hit = blockCache.get(name);
  if (hit !== undefined) return hit;
  const out: number[][] = [];
  for (const row of animKeyframes.all()) {
    if (row.length >= 2 && row[0] === name) out.push(row);
  }
  blockCache.set(name, out);
  return out;
}

/** Drops the cached blocks, after mount has loaded the compiled tables. */
export function resetKeyframes(): void {
  blockCache.clear();
}

/** The properties an animation's keyframes declare, in first-declared order. */
function declaredProps(blocks: number[][]): number[] {
  const out: number[] = [];
  for (const row of blocks) {
    for (let k = 2; k + 2 < row.length; k += 3) {
      const p = row[k];
      if (out.indexOf(p) < 0) out.push(p);
    }
  }
  return out;
}

/**
 * A property's value, unit and composite in one keyframe block, or null when it doesn't set it.
 * The composite rides above the unit (see packUnit in shared/css/anim.ts).
 */
function declaredValue(row: readonly number[], p: number): number[] | null {
  for (let k = 2; k + 2 < row.length; k += 3) {
    if (row[k] === p) return [row[k + 1], unitOf(row[k + 2]), compositeOf(row[k + 2])];
  }
  return null;
}

// ---------------------------------------------------------------------------
// Reading an element's lists

function items(el: Element, p: number): number[] {
  return valueList(p, el.sv[p], el.su[p]);
}

/** Item `i` of a list value, cycling the list. */
function cycle(list: readonly number[], i: number): number {
  return list.length === 0 ? 0 : list[i % list.length];
}

const DEFAULT_TF: number[] = [P.TF_EASE];

/** The properties that describe an animation rather than being moved by one (CSS Transitions 1). */
const NOT_ANIMATABLE: number[] = [
  P.P_TRANSITION_PROPERTY, P.P_TRANSITION_DURATION, P.P_TRANSITION_TIMING_FUNCTION,
  P.P_TRANSITION_DELAY, P.P_TRANSITION_BEHAVIOR,
  P.P_ANIMATION_NAME, P.P_ANIMATION_DURATION, P.P_ANIMATION_TIMING_FUNCTION, P.P_ANIMATION_DELAY,
  P.P_ANIMATION_ITERATION_COUNT, P.P_ANIMATION_DIRECTION, P.P_ANIMATION_FILL_MODE, P.P_ANIMATION_PLAY_STATE,
];

/** The timing function rows of a timing-function list value, resolved. */
function timingRows(list: readonly number[]): number[][] {
  const out: number[][] = [];
  for (const id of list) {
    const row = animRows.row(id);
    out.push(row === null ? DEFAULT_TF : rowOf(row));
  }
  return out;
}

function rowOf(row: readonly number[]): number[] {
  const out: number[] = [];
  for (const n of row) out.push(n);
  return out;
}

function timingAt(el: Element, p: number, i: number): number[] {
  const ids = items(el, p);
  const row = animRows.row(cycle(ids, i));
  return row === null ? DEFAULT_TF : rowOf(row);
}

// ---------------------------------------------------------------------------
// Starting transitions

/**
 * The transition-property entry that covers `p`: an explicit one first, then `all`. A property
 * named more than once takes the last entry, as the specification says.
 */
/**
 * Whether a display transition is about to start because the box is turning display:none. A
 * discrete transition of display runs only where transition-behavior allows it, with a duration,
 * and only for an element that was rendered: one that was already none has no starting style.
 */
/**
 * Whether a change from a value in unit `au` to one in `bu` can't be interpolated, so the pair
 * flips. A property whose values mix through the element (a colour's channels, a shadow's length
 * resolved to px, an inset's auto) is interpolable whatever the units say.
 */
/**
 * Whether a discrete change waits for transition-behavior: allow-discrete: display, and a size
 * that has nothing to measure the other end against. Every other discrete pair transitions with
 * a flip at the halfway point, as browsers do.
 */
function needsBehavior(p: number, au: number, bu: number): boolean {
  if (p === P.P_DISPLAY) return true;
  if (au === P.U_AUTO || bu === P.U_AUTO) {
    return p === P.P_WIDTH || p === P.P_HEIGHT || p === P.P_MIN_WIDTH || p === P.P_MAX_WIDTH ||
      p === P.P_MIN_HEIGHT || p === P.P_MAX_HEIGHT || p === P.P_FLEX_BASIS;
  }
  return false;
}

function discretePair(p: number, av: number, au: number, bv: number, bu: number): boolean {
  if (p === P.P_VERTICAL_ALIGN) {
    // `baseline` interpolates as the length 0, so only another keyword makes the pair discrete.
    const aKw = au === P.U_NONE;
    const bKw = bu === P.U_NONE;
    if (aKw && bKw) return false;
    if (aKw) return av !== P.VA_BASELINE;
    if (bKw) return bv !== P.VA_BASELINE;
    return false;
  }
  if (p === P.P_DISPLAY) return true;
  return needsSameUnit(p) && au !== bu;
}

function displayExitStarts(el: Element, st: AnimState): boolean {
  if (st.base[P.P_DISPLAY] === P.D_NONE) return false;
  const i = transitionIndex(items(el, P.P_TRANSITION_PROPERTY), P.P_DISPLAY);
  if (i < 0) return false;
  if (cycle(items(el, P.P_TRANSITION_BEHAVIOR), i) !== P.TB_ALLOW_DISCRETE) return false;
  return cycle(items(el, P.P_TRANSITION_DURATION), i) > 0;
}

function transitionIndex(props: readonly number[], p: number): number {
  for (let i = props.length - 1; i >= 0; i--) if (props[i] === p) return i;
  for (let i = props.length - 1; i >= 0; i--) if (props[i] === -1) return i;
  return -1;
}

/**
 * The font size the element's animations show right now, or -1 when none moves one. A style pass
 * asks this before it resolves the element's other em lengths, which are relative to the size the
 * animation has reached, not to the one the cascade names.
 */
export function animatedFontSize(el: Element): number {
  const st = states.get(el);
  if (st === undefined) return -1;
  let size = -1;
  const apply = (a: KeyframeRun): void => {
    if (finished(a) || a.props.indexOf(P.P_FONT_SIZE) < 0) return;
    const t = progressNow(a);
    if (t < 0) return;
    const v = keyframeValue(a, P.P_FONT_SIZE, t, el.sv[P.P_COLOR], el);
    if (v === null) return;
    size = v[1] === P.U_EM ? v[0] * el.sv[P.P_FONT_SIZE] : v[1] === P.U_REM ? v[0] * rootFontSize() : v[0];
  };
  for (const a of st.anims) {
    if (a !== null) apply(a);
  }
  for (const a of st.script) apply(a);
  // A running transition moves the font size too. It comes last because a transition wins over
  // an animation in the cascade, and what it shows is what this pass's em lengths measure out.
  for (const t of st.trans) {
    if (t.p === P.P_FONT_SIZE) size = transitionValue(el, t)[0];
  }
  return size;
}

/**
 * The progress a run shows right now, or -1 when it shows nothing: outside its active phase,
 * which only a fill that reaches there can make visible.
 */
function progressNow(a: KeyframeRun): number {
  const local = a.elapsed - a.delay;
  const total = a.iter < 0 ? -1 : a.dur * a.iter;
  if (local < 0) return a.fill === P.AF_BACKWARDS || a.fill === P.AF_BOTH ? directed(a.dir, 0, 0) : -1;
  if (total >= 0 && local >= total) {
    return a.fill === P.AF_FORWARDS || a.fill === P.AF_BOTH ? endProgress(a) : -1;
  }
  let iter = a.dur > 0 ? Math.floor(local / a.dur) : 0;
  if (a.iter >= 0 && iter > Math.ceil(a.iter) - 1) iter = Math.max(0, Math.ceil(a.iter) - 1);
  const frac = a.dur > 0 ? (local - iter * a.dur) / a.dur : 1;
  return directed(a.dir, iter, frac);
}

/** The transition an element has running for `p`, or null. */
function transitionFor(st: AnimState, p: number): Transition | null {
  for (const t of st.trans) if (t.p === p) return t;
  return null;
}

/**
 * The value a transition shows at the current clock: its from value before the delay, its to
 * value once the duration has run, and the eased mix in between. The style pass resolves a value
 * a transition moves (a font size its em lengths were measured against) with this, and restarts
 * nothing when the value it sees is this one.
 */
function transitionValue(el: Element, t: Transition, current: number = 0): number[] {
  const local = clock - t.start - t.delay;
  if (local < 0) return [t.fromV, t.fromU];
  if (local >= t.dur) return [t.toV, t.toU];
  return mixProperty(el, t.p, t.fromV, t.fromU, t.toV, t.toU, ease(t.tf, local / t.dur), current);
}

/** The value an element shows for `p` right now: mid-transition, or its cascaded value. */
function currentValue(el: Element, st: AnimState, p: number): number[] {
  for (const t of st.trans) {
    if (t.p === p) return transitionValue(el, t);
  }
  // A font size an animation moves is the size this element shows, and the size a transition
  // starting now runs from; `base` holds the cascaded one.
  if (p === P.P_FONT_SIZE) {
    const animated = animatedFontSize(el);
    if (animated >= 0) return [animated, P.U_PX];
  }
  return [st.base[p], st.baseU[p]];
}

/**
 * A property a share of the way from one value to another. A transform list interpolates function
 * by function while both ends name the same functions, and through the matrices they resolve to
 * otherwise; every other property mixes as mixValue does.
 */
function mixProperty(el: Element | null, p: number, av: number, au: number, bv: number, bu: number,
  t: number, current: number): number[] {
  if ((p === P.P_TEXT_SHADOW || p === P.P_BOX_SHADOW) && au === P.U_LIST && bu === P.U_LIST && el !== null) {
    if (av === bv) return [av, P.U_LIST];
    return [mixShadows(el, av, bv, t, current), P.U_LIST];
  }
  if (p === P.P_TRANSFORM && au === P.U_LIST && bu === P.U_LIST) {
    if (av === bv) return [av, P.U_LIST];
    const list = listMix(av, bv, t);
    if (list !== null) return [list, P.U_LIST];
    // Different function lists: mix the matrices they resolve to in the element's own box, with
    // `none` standing for the identity.
    if (el !== null) {
      const ma = rowMatrix(el, av);
      const mb = rowMatrix(el, bv);
      const m = mixMatrix([ma.a, ma.b, ma.c, ma.d, ma.e, ma.f], [mb.a, mb.b, mb.c, mb.d, mb.e, mb.f], t);
      return [matrixRow({ a: m[0], b: m[1], c: m[2], d: m[3], e: m[4], f: m[5] }), P.U_LIST];
    }
  }
  if (p === P.P_TEXT_DECORATION_INSET || p === P.P_TEXT_DECORATION_INSET_END) {
    return insetMix(el, av, au, bv, bu, t);
  }
  if (p === P.P_VERTICAL_ALIGN) {
    // `baseline` interpolates as the length 0, and a length mixes with a percentage through a
    // calc(); two keywords are one value.
    if (au === P.U_NONE && bu === P.U_NONE) return [av, au];
    if (au === P.U_NONE && av === P.VA_BASELINE) return lengthPercentMix(0, P.U_PX, bv, bu, t);
    if (bu === P.U_NONE && bv === P.VA_BASELINE) return lengthPercentMix(av, au, 0, P.U_PX, t);
    return lengthPercentMix(av, au, bv, bu, t);
  }
  return mixValue(p, av, au, bv, bu, t, current);
}

/**
 * text-decoration-inset mixes its two ends as lengths. `auto` stands for the length the line
 * metrics choose at the element's current font size, which is what makes it re-resolve when the
 * size changes mid-transition; a percentage mixes with a length through a calc().
 */
function insetMix(el: Element | null, av: number, au: number, bv: number, bu: number, t: number): number[] {
  // `auto` to `auto` stays auto: there is no length to interpolate toward.
  if (au === P.U_AUTO && bu === P.U_AUTO) return [0, P.U_AUTO];
  const size = el === null ? 16 : el.sv[P.P_FONT_SIZE];
  const a = insetUsed(av, au, size);
  const b = insetUsed(bv, bu, size);
  return lengthPercentMix(a[0], a[1], b[0], b[1], t);
}

/**
 * A length a share of the way to another, or a calc() when one end is a percentage and the other
 * is not. A zero length term is dropped (the percentage alone is the value, as browsers write
 * it); a zero percentage term is kept, since dropping it would change the value's type. The
 * first operand keeps the from value's unit.
 */
function lengthPercentMix(av: number, au: number, bv: number, bu: number, t: number): number[] {
  if (au === bu && au !== P.U_EXPR) return [av + (bv - av) * t, au];
  const aPct = au === P.U_PCT;
  const bPct = bu === P.U_PCT;
  if ((aPct && bu === P.U_PX) || (au === P.U_PX && bPct)) {
    const pct = aPct ? av * (1 - t) : bv * t;
    const px = aPct ? bv * t : av * (1 - t);
    if (px === 0) return [pct, P.U_PCT];
    const first = aPct ? exprRows.register([EXPR_LEAF, pct, P.U_PCT]) : exprRows.register([EXPR_LEAF, px, P.U_PX]);
    const second = aPct ? exprRows.register([EXPR_LEAF, px, P.U_PX]) : exprRows.register([EXPR_LEAF, pct, P.U_PCT]);
    return [exprRows.register([EXPR_SUM, 2, first, second]), P.U_EXPR];
  }
  return mixValue(P.P_VERTICAL_ALIGN, av, au, bv, bu, t, 0);
}

/** One inset end as a length: `auto` resolved, and the other units left for the engine. */
function insetUsed(v: number, u: number, size: number): number[] {
  if (u === P.U_AUTO) return [autoInsetPx(size), P.U_PX];
  if (u === P.U_EM) return [v * size, P.U_PX];
  if (u === P.U_REM) return [v * rootFontSize(), P.U_PX];
  return [v, u];
}

/**
 * A text-shadow or box-shadow list a share of the way to another. Each shadow mixes its colour
 * and its offsets, blur and spread; a shorter list is padded at the end with transparent shadows
 * of zero length, as CSS pads it. The lengths resolve against the element here, so a mixed row is
 * in px and an em list mixes with a px one.
 */
function mixShadows(el: Element, av: number, bv: number, t: number, current: number): number {
  const a: Shadow[] = shadowList(el, av);
  const b: Shadow[] = shadowList(el, bv);
  const n = a.length > b.length ? a.length : b.length;
  if (n === 0) return -1;
  const row: number[] = [];
  for (let i = 0; i < n; i++) {
    const sa: Shadow | null = i < a.length ? a[i] : null;
    const sb: Shadow | null = i < b.length ? b[i] : null;
    const ax = sa === null ? 0 : sa.dx;
    const ay = sa === null ? 0 : sa.dy;
    const ablur = sa === null ? 0 : sa.blur;
    const aspread = sa === null ? 0 : sa.spread;
    const bx = sb === null ? 0 : sb.dx;
    const by = sb === null ? 0 : sb.dy;
    const bblur = sb === null ? 0 : sb.blur;
    const bspread = sb === null ? 0 : sb.spread;
    const ac = sa === null ? 0 : sa.color;
    const bc = sb === null ? 0 : sb.color;
    const color = mixValue(P.P_COLOR, ac, P.U_NONE, bc, P.U_NONE, t, current)[0];
    // `inset` is a discrete part of a box shadow: it changes at the halfway point.
    const inset = t < 0.5 ? sa !== null && sa.inset : sb !== null && sb.inset;
    row.push(
      ax + (bx - ax) * t, P.U_PX,
      ay + (by - ay) * t, P.U_PX,
      Math.max(0, ablur + (bblur - ablur) * t), P.U_PX,
      aspread + (bspread - aspread) * t, P.U_PX,
      color, inset ? 1 : 0,
    );
  }
  return shadowRows.register(row);
}

function stateFor(el: Element): AnimState {
  const st = new AnimState();
  for (let p = 0; p < P.PROP_COUNT; p++) {
    st.base.push(el.sv[p]);
    st.baseU.push(el.su[p]);
  }
  // The pass left the size a transition or animation shows in sv; the baseline is the cascaded
  // size a change is measured from.
  if (el.cascadeFontSize >= 0) st.base[P.P_FONT_SIZE] = el.cascadeFontSize;
  return st;
}

function copyBase(el: Element, st: AnimState): void {
  for (let p = 0; p < P.PROP_COUNT; p++) {
    st.base[p] = el.sv[p];
    st.baseU[p] = el.su[p];
  }
  if (el.cascadeFontSize >= 0) st.base[P.P_FONT_SIZE] = el.cascadeFontSize;
}

/**
 * Whether the element's own values can move between style passes: a declared transition or
 * animation list, or one running (a script animation included). A pass that would otherwise leave
 * the element's style alone has to compute it when this holds, since only a compute compares the
 * values a transition or animation starts from.
 */
export function elementMoves(el: Element): boolean {
  // The state is made by the element's first style pass, so a box without one has never had a
  // style to compare against: its first style starts its transitions and animations from scratch.
  // (The compiled style array can be pre-sized, so its length says nothing about that.)
  const st = states.get(el);
  if (st === undefined) return false;
  if (st.trans.length > 0 || st.anims.length > 0 || st.script.length > 0) return true;
  return el.sv[P.P_TRANSITION_PROPERTY] !== -1 || el.sv[P.P_ANIMATION_NAME] !== -1;
}

/**
 * Called at the end of an element's computeStyles, before its children are computed. Starts the
 * transitions the new values ask for, records the cascade as the baseline animations sit over,
 * and works out which animations should be running.
 */
export function noteComputed(el: Element): void {
  const sv = el.sv;
  const su = el.su;
  let st = states.get(el);
  if (st === undefined) {
    st = stateFor(el);
    st.settled = true; // the initial style is not a change to transition from
    states.set(el, st);
    st.props.length = 0;
    reconcileAnimations(el, st);
    if (st.anims.length > 0) {
      updateElement(el, st, false);
      // This pass resolved the element's em lengths against the font size the cascade names; an
      // animation moving the font size only arrived after that, so the next pass has the right
      // base to ask animatedFontSize for.
      for (const a of st.anims) {
        if (a !== null && a.props.indexOf(P.P_FONT_SIZE) >= 0) dirty.style = true;
      }
    }
    return;
  }
  if (sv[P.P_DISPLAY] === P.D_NONE && transitionFor(st, P.P_DISPLAY) === null && !displayExitStarts(el, st)) {
    // An element that isn't rendered has no transitions or animations; one that comes back
    // starts them over. Each one that was running is canceled, as a browser reports it. A box
    // turning display:none keeps its box while its own exit transition runs, so the pass that
    // starts one — and the passes that run it — fall through instead.
    for (const t of st.trans) {
      queue("transitioncancel", el, P.PROPERTY_NAMES[t.p], "", transitionElapsed(t));
      const held = t.handle;
      t.handle = null;
      abandon(held);
    }
    st.trans.length = 0;
    for (const a of st.anims) {
      if (a === null) continue;
      queue("animationcancel", el, "", animNames.name(a.name), a.elapsed - a.delay);
      const held = a.handle;
      a.handle = null;
      abandon(held);
    }
    st.anims = [];
    copyBase(el, st);
    st.props.length = 0;
    st.settled = true;
    // A run a script started still shows its value: a pseudo-element's style carrier is a
    // display:none child, and the box that paints with it reads the value from its style.
    if (st.script.length > 0) {
      updateElement(el, st, false);
      return;
    }
    const at = running.indexOf(el);
    if (at >= 0) running.splice(at, 1);
    return;
  }
  let emStarted = false;
  if (st.settled) {
    const props = items(el, P.P_TRANSITION_PROPERTY);
    const durs = items(el, P.P_TRANSITION_DURATION);
    const delays = items(el, P.P_TRANSITION_DELAY);
    const behs = items(el, P.P_TRANSITION_BEHAVIOR);
    for (const p of ANIMATABLE) {
      // A box that is turning display:none starts only that transition: its other properties
      // have nothing left to paint.
      if (sv[P.P_DISPLAY] === P.D_NONE && p !== P.P_DISPLAY) continue;
      if (sv[p] === st.base[p] && su[p] === st.baseU[p]) continue;
      // text-decoration-inset's two ends are one property in a transition list: the end inset
      // rides on the entry that names the start.
      const named = p === P.P_TEXT_DECORATION_INSET_END ? P.P_TEXT_DECORATION_INSET : p;
      const i = transitionIndex(props, named);
      if (i < 0) continue;
      // A pair that can't be interpolated changes discretely. A few of those changes transition
      // only where transition-behavior allows one — display, and a size that can't be measured
      // against the other end — while the rest run and flip at the halfway point. A box that
      // wasn't rendered has no starting style to come from, so display:none changes at once.
      const discrete = discretePair(named, sv[p], su[p], st.base[p], st.baseU[p]);
      const allowDiscrete = cycle(behs, i) === P.TB_ALLOW_DISCRETE;
      if (discrete && !allowDiscrete && needsBehavior(named, su[p], st.baseU[p])) continue;
      if (p === P.P_DISPLAY && st.base[p] === P.D_NONE) continue;
      // A pass resolved this value with a transition that is already running (a font size its em
      // lengths were measured against shows the transition's own value); that is not a change to
      // start over from, so the transition keeps running untouched.
      const running = transitionFor(st, p);
      if (running !== null) {
        const cur = transitionValue(el, running);
        if (sv[p] === cur[0] && su[p] === cur[1]) continue;
      }
      const dur = cycle(durs, i);
      if (!(dur > 0)) continue;
      const from = currentValue(el, st, p);
      // A transition for the property already running is replaced: the new one starts from
      // wherever the old one had got to, and the old one is canceled.
      for (let k = st.trans.length - 1; k >= 0; k--) {
        const old = st.trans[k];
        if (old.p !== p) continue;
        st.trans.splice(k, 1);
        queue("transitioncancel", el, P.PROPERTY_NAMES[old.p], "", transitionElapsed(old));
        const held = old.handle;
        old.handle = null;
        abandon(held);
      }
      const t = new Transition();
      t.p = p;
      t.fromV = from[0];
      t.fromU = from[1];
      t.toV = sv[p];
      t.toU = su[p];
      t.start = clock;
      t.delay = cycle(delays, i);
      t.dur = dur;
      t.tf = timingAt(el, P.P_TRANSITION_TIMING_FUNCTION, i);
      st.trans.push(t);
      // transitionrun goes out as soon as the transition exists, delay included.
      queue("transitionrun", el, P.PROPERTY_NAMES[p], "", 0);
      if (p === P.P_FONT_SIZE) emStarted = true;
    }
  }
  // This pass measured the element's em lengths against the size the cascade names; a font-size
  // transition that just started shows another size, so one more pass resolves them against it.
  if (emStarted) dirty.style = true;
  // The cascade is the baseline now, and computeStyles has just rewritten every value, so the
  // previous frame's overrides are gone from sv/su.
  copyBase(el, st);
  st.props.length = 0;
  st.settled = true;
  reconcileAnimations(el, st);
  // Write the values they have reached now, before the children are computed, so an inherited
  // property (a transitioned color, say) reaches them in the same pass. The runs a script started
  // are part of this: an animation Element.animate() made puts its value back over the cascade,
  // including on a pseudo-element's box, which has no frames of its own to wait for.
  if (st.trans.length > 0 || st.anims.length > 0 || st.script.length > 0) updateElement(el, st, false);
}

/** Keeps the animations the element's animation-* lists ask for, restarting changed ones. */
function reconcileAnimations(el: Element, st: AnimState): void {
  const names = items(el, P.P_ANIMATION_NAME);
  const durs = items(el, P.P_ANIMATION_DURATION);
  const delays = items(el, P.P_ANIMATION_DELAY);
  const iters = items(el, P.P_ANIMATION_ITERATION_COUNT);
  const dirs = items(el, P.P_ANIMATION_DIRECTION);
  const fills = items(el, P.P_ANIMATION_FILL_MODE);
  const plays = items(el, P.P_ANIMATION_PLAY_STATE);
  const comps = items(el, P.P_ANIMATION_COMPOSITION);
  const tfs = timingRows(items(el, P.P_ANIMATION_TIMING_FUNCTION));
  const next: (KeyframeRun | null)[] = [];
  for (let i = 0; i < names.length; i++) {
    const name = names[i];
    if (name < 0) {
      next.push(null);
      continue;
    }
    const blocks = blocksFor(name);
    if (blocks.length === 0) {
      next.push(null);
      continue;
    }
    let a = i < st.anims.length ? st.anims[i] : null;
    if (a !== null && a.name !== name) {
      // The list entry names another animation now, so the one there is canceled.
      queue("animationcancel", el, "", animNames.name(a.name), a.elapsed - a.delay);
      const held = a.handle;
      a.handle = null;
      abandon(held);
      a = null;
    }
    if (a === null) {
      a = new KeyframeRun();
      a.name = name;
      a.blocks = blocks;
      a.props = declaredProps(blocks);
      a.startAt = clock;
    } else if (a.play === P.APS_RUNNING && !a.done) {
      // A style recompute between ticks still lets the time that passed count.
      a.elapsed += clock - a.last;
    }
    a.last = clock;
    a.dur = cycle(durs, i);
    a.delay = cycle(delays, i);
    a.iter = cycle(iters, i);
    a.dir = cycle(dirs, i);
    a.fill = cycle(fills, i);
    a.comp = cycle(comps, i);
    a.play = cycle(plays, i);
    a.tfs = tfs;
    next.push(a);
  }
  st.anims = next;
  syncRunning(el, st);
}

/** Adds or removes the element from the per-frame list. */
function syncRunning(el: Element, st: AnimState): void {
  let active = st.trans.length > 0;
  if (!active) {
    for (const a of st.anims) {
      if (a !== null && !finished(a)) active = true;
    }
  }
  if (!active) {
    for (const a of st.script) {
      if (!finished(a)) active = true;
    }
  }
  const at = running.indexOf(el);
  if (active && at < 0) running.push(el);
  else if (!active && at >= 0) running.splice(at, 1);
}

/**
 * The compositable properties an element's animations and transitions currently override, as
 * LAYER_* bits (runtime/layers.ts): the values a layer can change without the box repainting.
 * Empty for an element with nothing running, and for animations of properties that lay out.
 */
export function compositableBits(el: Element): number {
  const st = states.get(el);
  if (st === undefined) return 0;
  let bits = 0;
  for (const p of st.props) {
    if (p === P.P_TRANSFORM || p === P.P_TRANSLATE || p === P.P_ROTATE || p === P.P_SCALE) {
      bits |= LAYER_TRANSFORM;
    } else if (p === P.P_OPACITY) {
      bits |= LAYER_OPACITY;
    } else if (p === P.P_FILTER) {
      bits |= LAYER_FILTER;
    }
  }
  return bits;
}

/** A finite animation that has ended and has no forward fill. */
function finished(a: KeyframeRun): boolean {
  if (!a.done) return false;
  return a.fill !== P.AF_FORWARDS && a.fill !== P.AF_BOTH;
}

// ---------------------------------------------------------------------------
// Events

class AnimEvent {
  type: string = "";
  el: Element | null = null;
  property: string = "";
  animation: string = "";
  /** Milliseconds into the transition or animation. */
  elapsed: number = 0;
}

let events: AnimEvent[] = [];

function queue(type: string, el: Element, property: string, animation: string, elapsed: number): void {
  const e = new AnimEvent();
  e.type = type;
  e.el = el;
  e.property = property;
  e.animation = animation;
  e.elapsed = elapsed;
  events.push(e);
}

/** Sends the transition and animation events the frame produced, after the frame is painted. */
export function flushAnimationEvents(): void {
  if (events.length === 0) return;
  const due = events;
  events = [];
  for (const e of due) {
    if (e.el === null) continue;
    const seconds = e.elapsed / 1000;
    // A transition's events are TransitionEvents; an animation's are AnimationEvents. Both name
    // the pseudo-element the transition or animation moved, and leave it empty for an element.
    const pseudo = pseudoText(e.el);
    const ev = e.type.startsWith("transition")
      ? new TransitionEvent(e.type, { propertyName: e.property, elapsedTime: seconds, pseudoElement: pseudo })
      : new AnimationEvent(e.type, { animationName: e.animation, elapsedTime: seconds, pseudoElement: pseudo });
    dispatch(ev, e.el);
  }
}

/** The CSS name of the pseudo-element a node stands for, or "" for a real element. */
function pseudoText(el: Element): string {
  if (el.pseudoKind === P.PE_BEFORE) return "::before";
  if (el.pseudoKind === P.PE_AFTER) return "::after";
  if (el.pseudoKind === P.PE_MARKER) return "::marker";
  return "";
}

// ---------------------------------------------------------------------------
// Per-frame updates

/** One property value for this frame. */
class Value {
  p: number = 0;
  v: number = 0;
  u: number = 0;
}

function addValue(out: Value[], p: number, v: number, u: number): void {
  for (const x of out) {
    if (x.p === p) {
      x.v = v;
      x.u = u;
      return;
    }
  }
  const x = new Value();
  x.p = p;
  x.v = v;
  x.u = u;
  out.push(x);
}

/** The direction-adjusted progress of one iteration. */
function directed(dir: number, iter: number, frac: number): number {
  if (dir === P.AD_REVERSE) return 1 - frac;
  if (dir === P.AD_ALTERNATE) return iter % 2 === 0 ? frac : 1 - frac;
  if (dir === P.AD_ALTERNATE_REVERSE) return iter % 2 === 0 ? 1 - frac : frac;
  return frac;
}

/**
 * A property's value at `t` of the way through the animation, from the keyframes that declare
 * it. Null when the keyframes leave it to the element's own value: a property they only set
 * after `t`, or only before it and not at the end.
 */
function keyframeValue(a: KeyframeRun, p: number, t: number, current: number, el: Element): number[] | null {
  let before = -1;
  let after = -1;
  // The timing function list cycles over this property's own keyframe intervals, which are the
  // blocks that declare it, not over the animation's blocks as a whole.
  let segment = 0;
  for (let i = 0; i < a.blocks.length; i++) {
    const row = a.blocks[i];
    if (declaredValue(row, p) === null) continue;
    segment++;
    if (row[1] <= t + 0.000001) before = i;
    if (row[1] >= t - 0.000001 && after < 0) after = i;
  }
  // A keyframe list need not declare the first or last frame: what it leaves out is the element's
  // own value (a browser's neutral keyframe at 0% and 100%).
  const st = states.get(el);
  if (st !== undefined && before < 0 && after >= 0) {
    const ar = a.blocks[after];
    const av = declaredValue(ar, p);
    if (av === null) return null;
    const span = ar[1];
    const f = span > 0 ? t / span : 1;
    const tf = a.tfs.length > 0 ? a.tfs[(segment - 1) % a.tfs.length] : DEFAULT_TF;
    const mixed = mixProperty(el, p, st.base[p], st.baseU[p], av[0], av[1], ease(tf, f), current);
    return [mixed[0], mixed[1], AC_REPLACE];
  }
  if (st !== undefined && after < 0 && before >= 0) {
    const br = a.blocks[before];
    const bv = declaredValue(br, p);
    if (bv === null) return null;
    let comp = bv[2];
    if (comp === AC_REPLACE) comp = blockComposite(br);
    if (comp === AC_REPLACE) comp = a.comp;
    const span = 1 - br[1];
    const f = span > 0 ? (t - br[1]) / span : 1;
    const tf = a.tfs.length > 0 ? a.tfs[(segment - 1) % a.tfs.length] : DEFAULT_TF;
    const mixed = mixProperty(el, p, bv[0], bv[1], st.base[p], st.baseU[p], ease(tf, f), current);
    return [mixed[0], mixed[1], comp];
  }
  if (before < 0 || after < 0) return null;
  const br = a.blocks[before];
  const bv = frameValue(br, p, el);
  if (bv === null) return null;
  // A script's frames carry their composite in their own rows; a stylesheet's keyframe names it
  // with animation-composition inside the block, and replaces the value when it names none.
  let comp = bv[2];
  if (comp === AC_REPLACE) comp = blockComposite(br);
  if (comp === AC_REPLACE) comp = a.comp;
  if (before === after) {
    // At a frame's own offset its declared value is the value, except for a unit that resolves
    // differently once interpolated: text-decoration-inset's `auto` stands for a length the
    // element's line metrics choose, so even here it mixes toward its neighbour at progress 0
    // (or from it, at the last frame).
    if ((p === P.P_TEXT_DECORATION_INSET || p === P.P_TEXT_DECORATION_INSET_END) && bv[1] === P.U_AUTO) {
      const forward = after + 1 < a.blocks.length && declaredValue(a.blocks[after + 1], p) !== null;
      const back = forward ? -1 : before - 1 >= 0 && declaredValue(a.blocks[before - 1], p) !== null ? before - 1 : -1;
      const other = forward ? after + 1 : back;
      if (other >= 0) {
        const ov = frameValue(a.blocks[other], p, el);
        if (ov !== null) {
          const tf0 = a.tfs.length > 0 ? a.tfs[(segment - 1) % a.tfs.length] : DEFAULT_TF;
          const start = forward ? [bv[0], bv[1]] : [ov[0], ov[1]];
          const end = forward ? [ov[0], ov[1]] : [bv[0], bv[1]];
          const f0 = forward ? 0 : 1;
          const mixed0 = mixProperty(el, p, start[0], start[1], end[0], end[1], ease(tf0, f0), current);
          return [mixed0[0], mixed0[1], comp];
        }
      }
    }
    return [bv[0], bv[1], comp];
  }
  const ar = a.blocks[after];
  const av = frameValue(ar, p, el);
  if (av === null) return [bv[0], bv[1], comp];
  const span = ar[1] - br[1];
  const f = span > 0 ? (t - br[1]) / span : 1;
  const tf = a.tfs.length > 0 ? a.tfs[(segment - 1) % a.tfs.length] : DEFAULT_TF;
  const mixed = mixProperty(el, p, bv[0], bv[1], av[0], av[1], ease(tf, f), current);
  // The interval's composite is the one its start block names, as a browser takes it.
  return [mixed[0], mixed[1], comp];
}

/**
 * A declared keyframe value, with a CSS-wide keyword resolved against the element: `inherit`
 * takes the parent's computed value, `initial` the property's own starting one, and `unset`
 * either depending on whether the property inherits.
 */
function frameValue(row: readonly number[], p: number, el: Element): number[] | null {
  const v = declaredValue(row, p);
  if (v === null || v[1] !== P.U_WIDE) return v;
  const kw = v[0] | 0;
  const inherit = kw === P.WK_INHERIT || (kw === P.WK_UNSET && INHERITS[p]);
  const parent = el.parentNode;
  if (inherit && parent instanceof Element) return [parent.sv[p], parent.su[p], v[2]];
  return [INITIAL_V[p], INITIAL_U[p], v[2]];
}

/** The composite a stylesheet keyframe block names for its declarations, or replace. */
function blockComposite(row: readonly number[]): number {
  const own = declaredValue(row, P.P_ANIMATION_COMPOSITION);
  if (own === null || own[1] !== P.U_LIST) return AC_REPLACE;
  const items = animRows.row(own[0]);
  if (items === null || items.length === 0) return AC_REPLACE;
  return items[0];
}

/** Adds the values an animation shows at `t` of the way through. */
function applyKeyframes(a: KeyframeRun, t: number, el: Element, out: Value[]): void {
  const current = el.sv[P.P_COLOR];
  const st = states.get(el);
  for (const p of a.props) {
    // animation-composition says how the keyframes compose; it is not itself animated.
    if (p === P.P_ANIMATION_COMPOSITION) continue;
    // The transition-* and animation-* properties are the run's own settings, not values it can
    // move: a keyframe that declares one leaves the cascade's value in place.
    if (NOT_ANIMATABLE.indexOf(p) >= 0) continue;
    // An !important declaration beats a CSS animation; a transition still beats it.
    if (el.impProps.indexOf(p) >= 0) continue;
    const value = keyframeValue(a, p, t, current, el);
    if (value === null) continue;
    let v = value[0];
    let u = value[1];
    if (u === P.U_EM) {
      v = v * el.sv[P.P_FONT_SIZE];
      u = P.U_PX;
    } else if (u === P.U_REM) {
      v = v * rootFontSize();
      u = P.U_PX;
    }
    // An additive keyframe adds its value to the one the cascade gives the element. An accumulate
    // one adds it once per iteration the run has been through.
    const insetAuto = (p === P.P_TEXT_DECORATION_INSET || p === P.P_TEXT_DECORATION_INSET_END) &&
      st !== undefined && st.baseU[p] === P.U_AUTO && u === P.U_PX;
    if (value[2] !== AC_REPLACE && st !== undefined && (st.baseU[p] === u || insetAuto)) {
      const copies = value[2] === AC_ACCUMULATE ? (a.lastIter < 0 ? 1 : a.lastIter + 1) : 1;
      if (u === P.U_LIST && (p === P.P_TEXT_SHADOW || p === P.P_BOX_SHADOW)) {
        // A shadow list composes additively by appending: the keyframe's shadows paint over the
        // element's own list rather than the two lists adding number by number.
        v = appendShadows(st.base[p], v, copies);
      } else if (insetAuto) {
        // `auto` adds as the length it stands for, so the sum is a length the line can draw.
        v = autoInsetPx(el.sv[P.P_FONT_SIZE]) + v * copies;
      } else {
        v = st.base[p] + v * copies;
      }
    }
    addValue(out, p, v, u);
  }
}

/** The row of `add`'s shadows appended to `base`'s, `copies` times, as an additive composition. */
function appendShadows(base: number, add: number, copies: number): number {
  const row: number[] = [];
  const b = shadowRows.row(base);
  if (b !== null) for (const n of b) row.push(n);
  const a = shadowRows.row(add);
  if (a !== null) {
    for (let c = 0; c < copies; c++) for (const n of a) row.push(n);
  }
  return shadowRows.register(row);
}

/** The direction-adjusted progress at the end of the animation. */
function endProgress(a: KeyframeRun): number {
  if (a.iter < 0) return 1;
  const whole = Math.floor(a.iter);
  const part = a.iter - whole;
  const idx = part > 0 ? whole : whole > 0 ? whole - 1 : 0;
  return directed(a.dir, idx, part > 0 ? part : 1);
}

/** The properties that only change how a box is composited: they never move its box or its
 *  descendants, so a frame that changed only these needs no style, layout or paint. */
const COMPOSITOR_PROPS: number[] = [P.P_TRANSFORM, P.P_TRANSLATE, P.P_ROTATE, P.P_SCALE, P.P_OPACITY];

function isCompositorProperty(p: number): boolean {
  return COMPOSITOR_PROPS.indexOf(p) >= 0;
}

/**
 * Advances one element's transitions and animations and writes the values they show over the
 * cascade. Returns false when nothing is left to update. `propagate` asks for another style pass
 * when an inherited property moved, so the element's descendants follow it.
 */
function updateElement(el: Element, st: AnimState, propagate: boolean): boolean {
  const out: Value[] = [];
  for (const t of st.trans) {
    const local = clock - t.start - t.delay;
    if (local < 0) {
      addValue(out, t.p, t.fromV, t.fromU);
    } else if (local >= t.dur) {
      // A frame that skipped the whole active phase still reports its start, then its end.
      if (!t.started) {
        t.started = true;
        queue("transitionstart", el, P.PROPERTY_NAMES[t.p], "", 0);
      }
      addValue(out, t.p, t.toV, t.toU);
      t.done = true;
      queue("transitionend", el, P.PROPERTY_NAMES[t.p], "", t.dur);
    } else {
      // The active phase has begun: transitionstart goes out once, before any value moves.
      if (!t.started) {
        t.started = true;
        queue("transitionstart", el, P.PROPERTY_NAMES[t.p], "", 0);
      }
      const mixed = transitionValue(el, t, el.sv[P.P_COLOR]);
      addValue(out, t.p, mixed[0], mixed[1]);
    }
  }
  for (let i = st.trans.length - 1; i >= 0; i--) {
    if (!st.trans[i].done) continue;
    const held = st.trans[i].handle;
    st.trans[i].handle = null;
    settle(held);
    st.trans.splice(i, 1);
  }

  const runs: KeyframeRun[] = [];
  for (const a of st.anims) if (a !== null) runs.push(a);
  for (const a of st.script) runs.push(a);
  for (const a of runs) {
    if (finished(a)) continue;
    if (a.play === P.APS_RUNNING && !a.done) a.elapsed += clock - a.last;
    a.last = clock;
    const local = a.elapsed - a.delay;
    if (!a.done) {
      const total = a.iter < 0 ? -1 : a.dur * a.iter;
      if (local < 0) {
        // Before its delay: only a backwards fill shows anything.
        if (a.fill === P.AF_BACKWARDS || a.fill === P.AF_BOTH) applyKeyframes(a, directed(a.dir, 0, 0), el, out);
        continue;
      }
      if (total >= 0 && local >= total) {
        a.done = true;
        if (!a.started) {
          a.started = true;
          queue("animationstart", el, "", animNames.name(a.name), 0);
        }
        // The event reports the active time the animation ran for, not how late the frame is.
        queue("animationend", el, "", animNames.name(a.name), a.dur * a.iter);
        const held = a.handle;
        a.handle = null;
        settle(held);
        if (a.fill === P.AF_FORWARDS || a.fill === P.AF_BOTH) applyKeyframes(a, endProgress(a), el, out);
        continue;
      }
      // The active phase.
      if (!a.started) {
        a.started = true;
        queue("animationstart", el, "", animNames.name(a.name), a.elapsed - a.delay);
      }
      let iter = a.dur > 0 ? Math.floor(local / a.dur) : 0;
      if (a.iter >= 0 && iter > Math.ceil(a.iter) - 1) iter = Math.max(0, Math.ceil(a.iter) - 1);
      // An infinite duration never leaves its first iteration, and `iter * dur` would be NaN
      // (0 times Infinity), so its progress is the start.
      const frac = Number.isFinite(a.dur) ? (a.dur > 0 ? (local - iter * a.dur) / a.dur : 1) : 0;
      if (iter !== a.lastIter) {
        if (iter > 0 && a.lastIter >= 0) queue("animationiteration", el, "", animNames.name(a.name), iter * a.dur);
        a.lastIter = iter;
      }
      applyKeyframes(a, directed(a.dir, iter, frac), el, out);
    } else {
      if (a.fill === P.AF_FORWARDS || a.fill === P.AF_BOTH) applyKeyframes(a, endProgress(a), el, out);
    }
  }

  // Compare against what is on the element now, then replace the overrides. A property the
  // update no longer covers goes back to its cascaded value.
  let changed = false;
  let inherited = false;
  // A value that only moves how the box is composited leaves its style and layout alone: the
  // frame updates the recorded layer instead of painting the page again (compositor.ts).
  let compositorOnly = true;
  const moved = (p: number): void => {
    changed = true;
    if (!isCompositorProperty(p)) compositorOnly = false;
    if (P.INHERITED.indexOf(p) >= 0) inherited = true;
  };
  for (const x of out) {
    if (el.sv[x.p] !== x.v || el.su[x.p] !== x.u) moved(x.p);
  }
  for (const p of st.props) {
    let kept = false;
    for (const x of out) if (x.p === p) kept = true;
    if (!kept && (el.sv[p] !== st.base[p] || el.su[p] !== st.baseU[p])) {
      el.sv[p] = st.base[p];
      el.su[p] = st.baseU[p];
      moved(p);
    }
  }
  st.props.length = 0;
  // An animated value can be a font setting, so the node's remembered run goes with it.
  el.featValid = false;
  for (const x of out) {
    el.sv[x.p] = x.v;
    el.su[x.p] = x.u;
    if (st.props.indexOf(x.p) < 0) st.props.push(x.p);
  }
  if (changed) {
    if (compositorOnly) {
      invalidateComposite(el);
    } else {
      dirty.layout = true;
      // A box that moved paints its own bounds; with incremental layout the boxes after it are
      // left where they were unless the layout pass moved them, which the painter sees.
      if (incremental.on) markPaintDirty(el);
      else markFullPaint();
      // The box lays out from the values just written, which the style pass's own record of
      // what it gave the box doesn't hold: the next pass is to see a change either way.
      markLayoutDirty(el);
      el.lOwnChanged = true;
      el.lStyleA = ~el.lStyleA;
    }
  }
  // An inherited value that moved between style passes needs one, so the subtree catches up — and
  // only that subtree: the new value flows down the element's descendants, not across the page.
  if (inherited && propagate) invalidateStyleOf(el);
  return !nothingLeft(el, st);
}

function nothingLeft(el: Element, st: AnimState): boolean {
  if (st.trans.length > 0) return false;
  for (const a of st.anims) if (a !== null && !finished(a)) return false;
  for (const a of st.script) if (!finished(a)) return false;
  return true;
}

/**
 * Registers an animation a script started (Element.animate), so the frame clock drives it. No style
 * reconciles it away: only a cancel drops it. The handle it reports is the one a script holds.
 */
export function startScriptRun(el: Element, run: KeyframeRun): Animation {
  let st = states.get(el);
  if (st === undefined) {
    st = stateFor(el);
    st.settled = true;
    states.set(el, st);
  }
  run.startAt = clock;
  run.last = clock;
  st.script.push(run);
  syncRunning(el, st);
  dirty.style = true;
  dirty.layout = true;
  markFullPaint();
  const held = handleOf(el, null, run);
  run.started = true;
  return held;
}

/** Forgets every element's transitions and animations, so another page can be mounted. */
export function resetAnimations(): void {
  states.clear();
  running.length = 0;
  events = [];
  clock = 0;
}

/** Advances every transition and animation to the current clock. */
export function animationTick(): void {
  if (running.length === 0) return;
  for (let i = running.length - 1; i >= 0; i--) {
    const el = running[i];
    const st = states.get(el);
    if (st === undefined || !updateElement(el, st, true)) running.splice(i, 1);
  }
}
