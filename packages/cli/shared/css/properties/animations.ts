// CSS transitions and animations: the longhands and the two shorthands. Each value compiles to a
// row in the animation table (see shared/css/anim.ts); the engine in runtime/animation.ts reads
// the rows back.
//
// Returns undefined for a property this module doesn't handle.

import * as P from "../../props.ts";
import { AC_ACCUMULATE, AC_ADD, AC_REPLACE, animNames, animRows, timeMs, timingRow, transitionNameItem } from "../anim.ts";
import { splitLayers } from "./backgrounds.ts";
import type { Decl } from "../types.ts";

/** Splits a value on white space that isn't inside a function or a quoted string. */
export function spaceParts(value: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let quote = "";
  let start = -1;
  const push = (end: number) => {
    if (start >= 0) out.push(value.slice(start, end));
    start = -1;
  };
  for (let i = 0; i < value.length; i++) {
    const ch = value[i];
    if (quote !== "") {
      if (ch === quote) quote = "";
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      if (start < 0) start = i;
      continue;
    }
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    if (depth === 0 && /[ \t\r\n\f]/.test(ch)) push(i);
    else if (start < 0) start = i;
  }
  push(value.length);
  return out;
}

/** Strips the quotes from an animation name, if it has them. */
function unquote(text: string): string {
  if (text.length >= 2 && (text[0] === '"' || text[0] === "'") && text[text.length - 1] === text[0]) {
    return text.slice(1, -1);
  }
  return text;
}

/** One list property: its row id as the value, with unit U_LIST. */
function listDecl(p: number, row: number[], out: Decl[]): void {
  out.push({ p, v: animRows.register(row), u: P.U_LIST });
}

const TRANSITION_PROPERTY_KEYWORDS: Record<string, number> = { all: -1, none: -2 };

/**
 * One transition-property name as its row item. CSS takes any <custom-ident> there — a longhand,
 * a shorthand such as border-color, a property this build doesn't animate, or a custom property —
 * and only the names the engine can interpolate ever start a transition.
 */
function transitionItem(text: string): number | null {
  const keyword = TRANSITION_PROPERTY_KEYWORDS[text];
  if (keyword !== undefined) return keyword;
  const p = P.propertyId(text);
  if (p >= 0) return p;
  if (/^--[A-Za-z0-9_-]+$/.test(text) || /^-?[A-Za-z_][A-Za-z0-9_-]*$/.test(text)) {
    return transitionNameItem(text);
  }
  return null;
}

function transitionProperty(value: string, out: Decl[]): string | null {
  const row: number[] = [];
  for (const layer of splitLayers(value)) {
    const item = transitionItem(layer.toLowerCase());
    if (item === null) return `'${layer}' isn't a valid property name for 'transition-property'`;
    row.push(item);
  }
  listDecl(P.P_TRANSITION_PROPERTY, row, out);
  return null;
}

/** A comma-separated list of <time>s; a duration can't be negative. */
function timeList(prop: string, p: number, value: string, out: Decl[]): string | null {
  const row: number[] = [];
  for (const layer of splitLayers(value)) {
    const ms = timeMs(layer);
    if (ms === null) return `unsupported time '${layer}' for '${prop}'`;
    if (prop.endsWith("duration") && ms < 0) return `invalid time '${layer}' for '${prop}': a duration can't be negative, so the declaration is ignored`;
    row.push(ms);
  }
  listDecl(p, row, out);
  return null;
}

/** A comma-separated list of timing functions. */
function timingList(prop: string, p: number, value: string, out: Decl[]): string | null {
  const row: number[] = [];
  for (const layer of splitLayers(value)) {
    const tf = timingRow(layer);
    if (tf === null) return `unsupported timing function '${layer}' for '${prop}'`;
    row.push(animRows.register(tf));
  }
  listDecl(p, row, out);
  return null;
}

/** A comma-separated list of keywords, each mapped to its number. */
function keywordList(prop: string, p: number, value: string, names: Record<string, number>, out: Decl[]): string | null {
  const row: number[] = [];
  for (const layer of splitLayers(value)) {
    const v = names[layer.toLowerCase()];
    if (v === undefined) return `unsupported value '${layer}' for '${prop}' (supported: ${Object.keys(names).join(", ")})`;
    row.push(v);
  }
  listDecl(p, row, out);
  return null;
}

const DIRECTIONS: Record<string, number> = {
  normal: P.AD_NORMAL, reverse: P.AD_REVERSE, alternate: P.AD_ALTERNATE, "alternate-reverse": P.AD_ALTERNATE_REVERSE,
};
const FILL_MODES: Record<string, number> = { none: P.AF_NONE, forwards: P.AF_FORWARDS, backwards: P.AF_BACKWARDS, both: P.AF_BOTH };
const PLAY_STATES: Record<string, number> = { running: P.APS_RUNNING, paused: P.APS_PAUSED };
const BEHAVIORS: Record<string, number> = { normal: P.TB_NORMAL, "allow-discrete": P.TB_ALLOW_DISCRETE };

function nameList(value: string, out: Decl[]): string | null {
  const row: number[] = [];
  for (const layer of splitLayers(value)) {
    const name = unquote(layer);
    if (name.toLowerCase() === "none") row.push(-1);
    else if (name === "") return "invalid empty animation name";
    else row.push(animNames.register(name));
  }
  listDecl(P.P_ANIMATION_NAME, row, out);
  return null;
}

function iterationList(prop: string, value: string, out: Decl[]): string | null {
  const row: number[] = [];
  for (const layer of splitLayers(value)) {
    const text = layer.toLowerCase();
    if (text === "infinite") {
      row.push(-1);
      continue;
    }
    const n = Number(text);
    if (!Number.isFinite(n) || n < 0) return `unsupported value '${layer}' for '${prop}'`;
    row.push(n);
  }
  listDecl(P.P_ANIMATION_ITERATION_COUNT, row, out);
  return null;
}

/**
 * `transition: <property> <duration> <timing-function> <delay>`, one layer per comma-separated
 * group, with any of the four left out and its initial value standing in.
 */
function transitionShorthand(value: string, out: Decl[]): string | null {
  const props: number[] = [];
  const durs: number[] = [];
  const tfs: number[] = [];
  const delays: number[] = [];
  const behs: number[] = [];
  for (const layer of splitLayers(value)) {
    let prop = -1; // all
    let dur = 0;
    let tf = P.TF_EASE;
    let delay = 0;
    let beh = P.TB_NORMAL;
    let times = 0;
    let hasTf = false;
    let hasProp = false;
    let hasBeh = false;
    for (const token of spaceParts(layer)) {
      const behText = token.toLowerCase();
      if (behText === "normal" || behText === "allow-discrete") {
        if (hasBeh) return `too many behaviors in 'transition: ${layer}'`;
        beh = BEHAVIORS[behText];
        hasBeh = true;
        continue;
      }
      const ms = timeMs(token);
      if (ms !== null) {
        if (times === 0) dur = ms;
        else if (times === 1) delay = ms;
        else return `too many times in 'transition: ${layer}'`;
        times++;
        continue;
      }
      const tfRow = timingRow(token);
      if (tfRow !== null) {
        if (hasTf) return `too many timing functions in 'transition: ${layer}'`;
        tf = animRows.register(tfRow);
        hasTf = true;
        continue;
      }
      const text = token.toLowerCase();
      const item = transitionItem(text);
      if (item === null) return `'${token}' isn't a valid property name in 'transition: ${layer}'`;
      if (hasProp) return `too many properties in 'transition: ${layer}'`;
      prop = item;
      hasProp = true;
    }
    if (dur < 0) return `invalid time '${dur}ms' in 'transition: ${layer}': a duration can't be negative`;
    props.push(prop);
    durs.push(dur);
    tfs.push(tf);
    delays.push(delay);
    behs.push(beh);
  }
  listDecl(P.P_TRANSITION_PROPERTY, props, out);
  listDecl(P.P_TRANSITION_DURATION, durs, out);
  listDecl(P.P_TRANSITION_TIMING_FUNCTION, tfs, out);
  listDecl(P.P_TRANSITION_DELAY, delays, out);
  listDecl(P.P_TRANSITION_BEHAVIOR, behs, out);
  return null;
}

/**
 * `animation: <duration> <timing-function> <delay> <iteration-count> <direction> <fill-mode>
 * <play-state> <name>`, one layer per comma-separated group. The first time is the duration and
 * the second the delay; everything else is recognized by its form, and what is left is the name.
 */
function animationShorthand(value: string, out: Decl[]): string | null {
  const names: number[] = [];
  const durs: number[] = [];
  const tfs: number[] = [];
  const delays: number[] = [];
  const iters: number[] = [];
  const dirs: number[] = [];
  const fills: number[] = [];
  const plays: number[] = [];
  for (const layer of splitLayers(value)) {
    let name = -1; // none
    let dur = 0;
    let tf = P.TF_EASE;
    let delay = 0;
    let iter = 1;
    let dir = P.AD_NORMAL;
    let fill = P.AF_NONE;
    let play = P.APS_RUNNING;
    let times = 0;
    let hasTf = false;
    let hasIter = false;
    let hasDir = false;
    let hasFill = false;
    let hasPlay = false;
    let hasName = false;
    for (const token of spaceParts(layer)) {
      const ms = timeMs(token);
      if (ms !== null) {
        if (times === 0) dur = ms;
        else if (times === 1) delay = ms;
        else return `too many times in 'animation: ${layer}'`;
        times++;
        continue;
      }
      // A second one can't be the timing function: what is left of the layer names the
      // animation, so `animation: ease ease` is the curve `ease` and a keyframes rule named
      // `ease`.
      const tfRow = timingRow(token);
      if (tfRow !== null && !hasTf) {
        tf = animRows.register(tfRow);
        hasTf = true;
        continue;
      }
      const text = token.toLowerCase();
      if (!hasIter && (text === "infinite" || /^[-+]?(\d+\.?\d*|\.\d+)$/.test(text))) {
        if (text === "infinite") iter = -1;
        else {
          const n = Number(text);
          if (n < 0) return `invalid iteration count '${token}' in 'animation: ${layer}'`;
          iter = n;
        }
        hasIter = true;
        continue;
      }
      if (!hasDir && DIRECTIONS[text] !== undefined) {
        dir = DIRECTIONS[text];
        hasDir = true;
        continue;
      }
      // `none` fills nothing and names none: the grammar takes it as the fill mode when it can,
      // and the name it leaves at its default is `none` too, so either reading is the same value.
      if (!hasFill && FILL_MODES[text] !== undefined) {
        fill = FILL_MODES[text];
        hasFill = true;
        continue;
      }
      if (!hasPlay && PLAY_STATES[text] !== undefined) {
        play = PLAY_STATES[text];
        hasPlay = true;
        continue;
      }
      // What is left names the animation. `none` is only a name once the other keywords are
      // taken, which the fill-mode keyword above deliberately steps aside for.
      const unquoted = unquote(token);
      if (unquoted === "" || hasName) return `unsupported value '${token}' in 'animation: ${layer}'`;
      name = unquoted.toLowerCase() === "none" ? -1 : animNames.register(unquoted);
      hasName = true;
    }
    if (dur < 0) return `invalid time '${dur}ms' in 'animation: ${layer}': a duration can't be negative`;
    names.push(name);
    durs.push(dur);
    tfs.push(tf);
    delays.push(delay);
    iters.push(iter);
    dirs.push(dir);
    fills.push(fill);
    plays.push(play);
  }
  listDecl(P.P_ANIMATION_NAME, names, out);
  listDecl(P.P_ANIMATION_DURATION, durs, out);
  listDecl(P.P_ANIMATION_TIMING_FUNCTION, tfs, out);
  listDecl(P.P_ANIMATION_DELAY, delays, out);
  listDecl(P.P_ANIMATION_ITERATION_COUNT, iters, out);
  listDecl(P.P_ANIMATION_DIRECTION, dirs, out);
  listDecl(P.P_ANIMATION_FILL_MODE, fills, out);
  listDecl(P.P_ANIMATION_PLAY_STATE, plays, out);
  return null;
}

export function animationsProperty(prop: string, value: string, out: Decl[]): string | null | undefined {
  switch (prop) {
    case "transition-property": return transitionProperty(value, out);
    case "transition-duration": return timeList(prop, P.P_TRANSITION_DURATION, value, out);
    case "transition-delay": return timeList(prop, P.P_TRANSITION_DELAY, value, out);
    case "transition-timing-function": return timingList(prop, P.P_TRANSITION_TIMING_FUNCTION, value, out);
    case "transition-behavior": return keywordList(prop, P.P_TRANSITION_BEHAVIOR, value, BEHAVIORS, out);
    case "transition": return transitionShorthand(value, out);
    case "animation-name": return nameList(value, out);
    case "animation-duration": return timeList(prop, P.P_ANIMATION_DURATION, value, out);
    case "animation-delay": return timeList(prop, P.P_ANIMATION_DELAY, value, out);
    case "animation-timing-function": return timingList(prop, P.P_ANIMATION_TIMING_FUNCTION, value, out);
    case "animation-iteration-count": return iterationList(prop, value, out);
    case "animation-direction": return keywordList(prop, P.P_ANIMATION_DIRECTION, value, DIRECTIONS, out);
    case "animation-fill-mode": return keywordList(prop, P.P_ANIMATION_FILL_MODE, value, FILL_MODES, out);
    case "animation-play-state": return keywordList(prop, P.P_ANIMATION_PLAY_STATE, value, PLAY_STATES, out);
    case "animation-composition": return keywordList(prop, P.P_ANIMATION_COMPOSITION, value, {
      replace: AC_REPLACE, add: AC_ADD, accumulate: AC_ACCUMULATE,
    }, out);
    case "animation": return animationShorthand(value, out);
    default: return undefined;
  }
}
