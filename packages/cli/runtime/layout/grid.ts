import { boxKids } from "../dom.ts";
// Grid layout: the explicit and implicit tracks, auto-placement, the track sizing algorithm and
// the placement of the items.
//
// A grid item's containing block is its grid area, so a box is laid out against the width of the
// columns it spans. Rows are sized from the items' heights, then the items are placed again with
// their area's height, which is what a percentage height inside one resolves against.

import * as P from "../../shared/props.ts";
import { rootFontSize } from "../root-size.ts";
import { isRtl, isVerticalText, usedWritingMode } from "../style.ts";
import type { Node } from "../dom.ts";
import { layoutBox } from "./box.ts";
import { naturalBaseline, naturalLastBaseline } from "./flex.ts";
import { alignEdge, alignOffset, blockEndBorder, blockStartBorder, inlineEndBorder, inlineMirrored, inlineStartBorder, aspectRatio, aspectW, boundedRatioH, clampH, clampW, contentEdge, display, isOutOfFlow, isReplaced, len, marginH, marginV, padH, padV, place, sizeUnit, scriptScrollsX, scriptScrollsY, specH, specW, visibleChildren, zeroIfNaN } from "./box-model.ts";
import { intrinsicMaxWidth, intrinsicMinWidth } from "./text.ts";
import { hasTransform } from "../transform.ts";
import { areaList, placementRow, trackList, trackNameGroups, trackPx } from "../grid.ts";
import type { AreaName, Track } from "../grid.ts";

const INF = Number.POSITIVE_INFINITY;

/** Where one item sits in the grid: zero-based track indices, from the placement properties. */
interface Area {
  col: number;
  colSpan: number;
  row: number;
  rowSpan: number;
  /** True when the column (or row) came from auto-placement rather than the item's own value. */
  autoCol: boolean;
  autoRow: boolean;
}

/** The fixed px a track size names, or NaN when it is intrinsic or flexible. */
function fixedPx(t: { kind: number; v: number; u: number }, el: Node, base: number): number {
  return t.kind === P.GT_LEN ? Math.max(0, trackPx(t, el, base)) : NaN;
}

/** grid-auto-columns (or -rows): the tracks an implicit column (or row) adds, cycling its list. */
function autoTracks(el: Node, p: number): Track[] {
  const list = trackList(el.sv[p]);
  return list === null ? [{ min: { kind: P.GT_AUTO, v: 0, u: 0 }, max: { kind: P.GT_AUTO, v: 0, u: 0 } }] : list;
}

/**
 * One axis of a grid's lines: the explicit track count, whose lines run from 1 to `explicit + 1`,
 * and the names each line carries, by line number.
 */
interface Axis {
  explicit: number;
  names: (string[] | undefined)[] | null;
}

/** A line name with its occurrence count: positive counts from the start, negative from the end. */
interface NamedRef {
  name: string;
  count: number;
}

/** The names a track list carries on each line, with the implicit names a named area adds. */
function axisNames(tracks: Track[], areas: AreaName[] | null, col: boolean): (string[] | undefined)[] {
  const out: (string[] | undefined)[] = [];
  const add = (line: number, name: string): void => {
    if (line < 1) return;
    const cur = out[line];
    out[line] = cur === undefined ? [name] : cur.includes(name) ? cur : [...cur, name];
  };
  for (let i = 0; i < tracks.length; i++) {
    const t = tracks[i];
    if (t.names !== undefined) for (const n of t.names) add(i + 1, n);
    if (t.endNames !== undefined) for (const n of t.endNames) add(i + 2, n);
  }
  if (areas !== null) {
    // A named area names the lines on its edges `<name>-start` and `<name>-end` (CSS Grid 7.3).
    for (const a of areas) {
      add(col ? a.colStart : a.rowStart, a.name + "-start");
      add(col ? a.colEnd : a.rowEnd, a.name + "-end");
    }
  }
  return out;
}

/** The line number a name and occurrence count reach, or NaN when no line answers to it. */
function namedLine(ax: Axis, ref: NamedRef): number {
  const names = ax.names;
  // A name written on its own is occurrence 1 of itself.
  const want = ref.count === 0 ? 1 : ref.count;
  const hits: number[] = [];
  if (names !== null) {
    for (let l = 1; l <= ax.explicit + 1; l++) {
      const ns = names[l];
      if (ns !== undefined && ns.includes(ref.name)) hits.push(l);
    }
  }
  const last = ax.explicit + 1;
  if (want > 0) {
    // Past the explicit grid every implicit line carries the name.
    if (hits.length >= want) return hits[want - 1];
    // A name with no line of its own still reaches the implicit lines past the grid.
    return hits.length > 0 ? last + (want - hits.length) : last + want;
  }
  // A negative count reaches back from the last occurrence of the name.
  const count = -want;
  const fromEnd = hits.length - count;
  if (fromEnd >= 0) return hits[fromEnd];
  // Likewise before the explicit grid, where the lines are 0, -1, ...
  return hits.length > 0 ? hits[0] - (count - hits.length) : 1 - count;
}

/** The first line of the axis carrying `name`, or NaN when no line does. */
function firstNamed(ax: Axis, name: string): number {
  const names = ax.names;
  if (names === null) return NaN;
  for (let l = 1; l <= ax.explicit + 1; l++) {
    const ns = names[l];
    if (ns !== undefined && ns.includes(name)) return l;
  }
  return NaN;
}

/**
 * The line a placement names, resolved from the end when its number is negative. A bare name
 * first matches a named area's edge — `<name>-start` on a start side, `<name>-end` on an end side
 * (CSS Grid 8.3) — and is then occurrence 1 of the name itself. A `span name` is not a line of
 * its own, and NaN is a side the author left to auto-placement.
 */
function lineOf(v: number, u: number, ax: Axis, end: boolean): number {
  if (u === P.U_NAME) {
    const ref = namedRef(v);
    if (ref === null || ref.span) return NaN;
    if (ref.count === 0) {
      const edge = firstNamed(ax, ref.name + (end ? "-end" : "-start"));
      if (!Number.isNaN(edge)) return edge;
    }
    return namedLine(ax, ref);
  }
  if (u !== P.U_NONE) return NaN;
  return v > 0 ? v : ax.explicit + 2 + v;
}

/** The named placement a U_NAME value holds. */
function namedRef(v: number): { name: string; count: number; span: boolean } | null {
  return placementRow(v);
}

/**
 * Where a `span <name>` from a line reaches: the next lines with that name. Implicit lines past
 * the explicit grid carry every name, so a name with no line of its own still spans one implicit
 * track past the grid (CSS Grid 8.3).
 */
function spanToName(ax: Axis, from: number, ref: NamedRef, forward: boolean): number {
  const names = ax.names;
  const last = ax.explicit + 1;
  if (names !== null) {
    let left = ref.count === 0 ? 1 : ref.count;
    for (let step = 1; step <= ax.explicit + 1; step++) {
      const l = forward ? from + step : from - step;
      if (l < 1 || l > last) break;
      const ns = names[l];
      if (ns !== undefined && ns.includes(ref.name) && --left === 0) return l;
    }
  }
  return forward ? last + 1 : 0;
}

/** The span a placement's opposite side asks for, and where its start is when it named one. */
function startOf(startV: number, startU: number, endV: number, endU: number, ax: Axis):
  { start: number; span: number } {
  const s = lineOf(startV, startU, ax, false);
  const e = lineOf(endV, endU, ax, true);
  // `span N` on either side sets the size; the other side may still name a line.
  const spanStart = startU === P.U_SPAN ? startV : 0;
  const spanEnd = endU === P.U_SPAN ? endV : 0;
  const nameStart = startU === P.U_NAME && namedRef(startV)?.span === true ? namedRef(startV) : null;
  const nameEnd = endU === P.U_NAME && namedRef(endV)?.span === true ? namedRef(endV) : null;
  const hasS = !Number.isNaN(s);
  const hasE = !Number.isNaN(e);
  if (hasS && hasE) {
    const a = Math.min(s, e);
    const b = Math.max(s, e);
    return { start: a, span: Math.max(1, b - a) };
  }
  if (hasS) {
    if (nameEnd !== null) {
      const end = spanToName(ax, s, { name: nameEnd.name, count: Math.max(1, nameEnd.count) }, true);
      return { start: s, span: Math.max(1, end - s) };
    }
    return { start: s, span: spanEnd > 0 ? spanEnd : 1 };
  }
  if (hasE) {
    if (nameStart !== null) {
      const start = spanToName(ax, e, { name: nameStart.name, count: Math.max(1, nameStart.count) }, false);
      return { start, span: Math.max(1, e - start) };
    }
    return { start: e - (spanStart > 0 ? spanStart : 1), span: spanStart > 0 ? spanStart : 1 };
  }
  return { start: NaN, span: Math.max(1, spanStart > 0 ? spanStart : spanEnd > 0 ? spanEnd : 1) };
}

/**
 * Moves every area so the first track any of them reaches is 0, which is how the rest of the
 * layout indexes tracks. Only a placement that names a line before the explicit grid reaches
 * one, and the explicit grid then starts at `shift` rather than at 0.
 */
function shiftAreas(areas: Area[], explicitCols: number, explicitRows: number):
  { colShift: number; rowShift: number; cols: number; rows: number } {
  let minC = 0, minR = 0, maxC = explicitCols, maxR = explicitRows;
  for (const a of areas) {
    minC = Math.min(minC, a.col);
    minR = Math.min(minR, a.row);
    maxC = Math.max(maxC, a.col + a.colSpan);
    maxR = Math.max(maxR, a.row + a.rowSpan);
  }
  for (const a of areas) {
    a.col -= minC;
    a.row -= minR;
  }
  return { colShift: -minC, rowShift: -minR, cols: maxC - minC, rows: maxR - minR };
}

/**
 * The tracks a grid uses: the explicit ones at `shift`, with `grid-auto-*` filling in the
 * implicit tracks either side of them. After the explicit grid the sizes run in list order; before
 * it they run backwards, the track nearest the explicit grid taking the last size.
 */
function allTracks(explicit: Track[], autoTracks: Track[], count: number, shift: number): Track[] {
  const out: Track[] = [];
  const n = autoTracks.length;
  for (let i = 0; i < count; i++) {
    if (i < shift) out.push(autoTracks[n - 1 - (shift - 1 - i) % n]);
    else if (i < shift + explicit.length) out.push(explicit[i - shift]);
    else out.push(autoTracks[(i - shift - explicit.length) % n]);
  }
  return out;
}

/**
 * How many tracks a line of the flow holds, which is where the cursor wraps: the explicit ones,
 * widened by any placement and by the widest span an item with no place of its own asks for
 * (CSS Grid 8.5, step 3).
 */
function flowLines(areas: Area[], explicitCount: number, column: boolean): number {
  let n = Math.max(1, explicitCount);
  for (const a of areas) {
    const auto = column ? a.autoRow : a.autoCol;
    const span = column ? a.rowSpan : a.colSpan;
    const at = column ? a.row : a.col;
    n = auto ? Math.max(n, span) : Math.max(n, at + span);
  }
  return n;
}

/**
 * Auto-placement, following CSS Grid 8.5. In a row flow the cursor walks the columns, so a line
 * is a row; a column flow turns that around. `(line, flow)` below is in that space either way.
 * `lines` is how many tracks the cursor's line holds, which is at least the widest span an item
 * with no place of its own asks for.
 *
 * Items placed on both axes take their cells first, then those held to a line fill the earliest
 * free place along it, and only then does the cursor walk: it moves onto an item's own flow
 * position when the item names one, and otherwise takes the first free span, wrapping at the end
 * of a line. `dense` starts the cursor over for every item.
 */
function autoPlace(areas: Area[], lines: number, column: boolean, dense: boolean): void {
  const taken = new Set<number>();
  const key = (r: number, c: number): number => r * 100000 + c;
  // Every cell a span would cover is free. Only an item's own placement reaches before the
  // explicit grid (a negative track index), and the cursor never walks there.
  const freeAt = (a: Area, line: number, flow: number): boolean => {
    const row = column ? flow : line;
    const col = column ? line : flow;
    for (let dr = 0; dr < a.rowSpan; dr++) {
      for (let dc = 0; dc < a.colSpan; dc++) {
        if (taken.has(key(row + dr, col + dc))) return false;
      }
    }
    return true;
  };
  const fill = (a: Area): void => {
    for (let dr = 0; dr < a.rowSpan; dr++) {
      for (let dc = 0; dc < a.colSpan; dc++) taken.add(key(a.row + dr, a.col + dc));
    }
  };
  const flowSpan = (a: Area): number => column ? a.rowSpan : a.colSpan;
  const lineOf = (a: Area): number => column ? a.col : a.row;
  const flowOf = (a: Area): number => column ? a.row : a.col;
  const setLine = (a: Area, v: number): void => {
    if (column) a.col = v;
    else a.row = v;
  };
  const setFlow = (a: Area, v: number): void => {
    if (column) a.row = v;
    else a.col = v;
  };
  const definiteLine = (a: Area): boolean => column ? !a.autoCol : !a.autoRow;
  const definiteFlow = (a: Area): boolean => column ? !a.autoRow : !a.autoCol;

  for (const a of areas) if (definiteLine(a) && definiteFlow(a)) fill(a);
  // An item held to a line takes the earliest free place along it, before the cursor moves.
  for (const a of areas) {
    if (!definiteLine(a) || definiteFlow(a)) continue;
    const line = lineOf(a);
    let flow = 0;
    while (!freeAt(a, line, flow)) flow++;
    setFlow(a, flow);
    fill(a);
  }
  let line = 0;
  let flow = 0;
  for (const a of areas) {
    if (definiteLine(a)) continue;
    if (dense) {
      line = 0;
      flow = 0;
    }
    if (definiteFlow(a)) {
      // The cursor moves onto the item's own place along the flow, then to the first row of
      // that column (or column of that row) where the span fits. A place before the explicit
      // grid is found from the first line, and leaves the cursor where it is.
      const want = flowOf(a);
      if (want < 0) {
        let at = 0;
        while (!freeAt(a, at, want)) at++;
        setLine(a, at);
        fill(a);
        continue;
      }
      if (want < flow) line++;
      flow = want;
      while (!freeAt(a, line, flow)) line++;
      setLine(a, line);
      setFlow(a, flow);
      fill(a);
      continue;
    }
    const width = Math.max(lines, flowSpan(a));
    for (;;) {
      if (flow + flowSpan(a) > width) {
        line++;
        flow = 0;
      }
      if (freeAt(a, line, flow)) break;
      flow++;
    }
    setLine(a, line);
    setFlow(a, flow);
    fill(a);
    flow += flowSpan(a);
  }
}

/**
 * The used size of each track. `minC` and `maxC` are the content contributions a single-span
 * item makes to its track, margins included; a track that only items spanning several tracks
 * reach gets the share of their contribution the other spanned tracks don't account for.
 * `autoMin`, when given, holds the minimum contribution of each track's items — the smallest
 * outer size an item whose size comes from its content can take — which is what an `auto`
 * minimum sizing function asks for, where a `min-content` one asks for `minC`.
 */
function sizeTracks(el: Node, tracks: Track[], avail: number, gap: number, minC: number[], maxC: number[],
  stretch: boolean, minSized = false, autoMin?: number[]): number[] {
  const n = tracks.length;
  const base: number[] = [];
  const limit: number[] = [];
  for (let i = 0; i < n; i++) {
    const t = tracks[i];
    const b = fixedPx(t.min, el, avail);
    const l = fixedPx(t.max, el, avail);
    const contentMin = Math.max(0, minC[i]);
    const contentMax = Math.max(contentMin, maxC[i]);
    let bv: number;
    if (!Number.isNaN(b)) bv = b;
    else if (t.min.kind === P.GT_MAX_CONTENT) bv = contentMax;
    else if (t.min.kind === P.GT_FIT_CONTENT) {
      const lim = t.min.u === P.U_AUTO ? contentMax : Math.max(0, trackPx(t.min, el, avail));
      // A percentage the available space can't resolve — an indefinite container — sizes as auto.
      bv = Number.isNaN(lim) ? contentMax : Math.min(contentMax, Math.max(contentMin, lim));
    } else if (t.min.kind === P.GT_MIN_CONTENT) bv = contentMin;
    // `auto`, or a flexible maximum's automatic minimum: the smallest outer size the items can
    // take, which a definite maximum has already capped where it applies (CSS Grid 12.5.1).
    else bv = autoMin === undefined ? contentMin : Math.max(0, autoMin[i]);
    let lv: number;
    if (!Number.isNaN(l)) lv = l;
    else if (t.max.kind === P.GT_FR) lv = INF;
    else if (t.max.kind === P.GT_MAX_CONTENT || t.max.kind === P.GT_AUTO) lv = contentMax;
    else if (t.max.kind === P.GT_FIT_CONTENT) {
      const lim = t.max.u === P.U_AUTO ? contentMax : Math.max(0, trackPx(t.max, el, avail));
      lv = Number.isNaN(lim) ? contentMax : Math.min(contentMax, Math.max(contentMin, lim));
    } else if (t.max.kind === P.GT_MIN_CONTENT) lv = contentMin;
    // An unresolved percentage sizes as auto: `20%` of an indefinite height behaves as
    // `minmax(auto, max-content)` (CSS Grid 12.5).
    else lv = contentMax;
    base.push(bv);
    limit.push(Math.max(bv, lv));
  }
  const definite = !Number.isNaN(avail);
  const gaps = gap * Math.max(0, n - 1);
  if (!definite) {
    // No space to fit into: every track takes the size its content asks for — its growth limit,
    // or, for a min-content width, the base its automatic minimum asks for. A flexible track is
    // worth as much as the room its items ask for: the used flex fraction is the largest of each
    // flexible track's max-content contribution over its factor, and every flexible track takes
    // that fraction times its own factor (CSS Grid 12.7.1), which is what makes two
    // `minmax(0, 0.4fr)` tracks around a 100px item 40px each.
    const out: number[] = [];
    let fraction = 0;
    if (!minSized) {
      for (let i = 0; i < n; i++) {
        if (tracks[i].max.kind !== P.GT_FR) continue;
        fraction = Math.max(fraction, Math.max(0, maxC[i]) / Math.max(1, tracks[i].max.v));
      }
    }
    for (let i = 0; i < n; i++) {
      const t = tracks[i];
      if (t.max.kind === P.GT_FR) out.push(minSized ? base[i] : Math.max(base[i], fraction * t.max.v));
      else out.push(minSized || limit[i] === INF ? base[i] : limit[i]);
    }
    return out;
  }
  // 1. Maximize: the free space grows every track that can grow (every non-flexible one) up to
  // its growth limit, an equal share at a time.
  let free = avail - gaps;
  let sum = 0;
  for (const b of base) sum += b;
  free -= sum;
  const flex: number[] = [];
  for (let i = 0; i < n; i++) if (tracks[i].max.kind === P.GT_FR) flex.push(i);
  for (let guard = 0; guard < 64 && free > 0.0001; guard++) {
    const open: number[] = [];
    for (let i = 0; i < n; i++) {
      if (flex.includes(i)) continue;
      if (limit[i] === INF || base[i] < limit[i] - 0.0001) open.push(i);
    }
    if (open.length === 0) break;
    const share = free / open.length;
    let used = 0;
    for (const i of open) {
      const room = limit[i] === INF ? INF : limit[i] - base[i];
      const add = Math.min(share, room);
      base[i] += add;
      used += add;
    }
    free -= used;
    if (used < 0.0001) break;
  }
  // 2. Expand the flexible tracks: what is left after the others is shared in proportion to
  // their factors, each track keeping its own automatic minimum.
  if (flex.length > 0) {
    let rest = avail - gaps;
    for (let i = 0; i < n; i++) if (!flex.includes(i)) rest -= base[i];
    rest = Math.max(0, rest);
    // A track whose share is smaller than its own automatic minimum keeps that minimum, and the
    // rest is shared among the others.
    const locked: number[] = [];
    for (let guard = 0; guard < 16; guard++) {
      let totalFr = 0;
      for (const i of flex) if (!locked.includes(i)) totalFr += tracks[i].max.v;
      if (totalFr <= 0) break;
      // The factors are shared over at least one of them, so factors that add up to less than 1
      // leave room over (CSS Grid 12.7.1, "less than 1, set it to 1").
      const denom = Math.max(1, totalFr);
      let next = -1;
      for (const i of flex) {
        if (locked.includes(i)) continue;
        if ((rest * tracks[i].max.v) / denom < base[i] - 0.0001) {
          next = i;
          break;
        }
      }
      if (next < 0) {
        for (const i of flex) if (!locked.includes(i)) base[i] = Math.max(base[i], (rest * tracks[i].max.v) / denom);
        break;
      }
      locked.push(next);
      rest = Math.max(0, rest - base[next]);
    }
  }
  // 3. Stretch: a track whose maximum is `auto` shares any space left over, as
  // `justify-content: normal` does, whatever its minimum (CSS Grid 12.8).
  sum = 0;
  for (const b of base) sum += b;
  let left = avail - gaps - sum;
  if (stretch && left > 0.0001) {
    const stretched: number[] = [];
    for (let i = 0; i < n; i++) if (tracks[i].max.kind === P.GT_AUTO) stretched.push(i);
    if (stretched.length > 0) {
      const share = left / stretched.length;
      for (const i of stretched) base[i] += share;
    }
  }
  return base;
}

/** Does a track list hold a `repeat(auto-fill, …)` or `repeat(auto-fit, …)`? */
function hasRepeat(tracks: Track[]): boolean {
  for (const t of tracks) if (t.repeat !== undefined) return true;
  return false;
}

/**
 * The explicit tracks with each auto-repeat expanded to the number of copies that fit: the
 * largest count whose tracks and gaps stay within `avail`, and one copy when the size isn't
 * known (CSS Grid 7.2.3.1). With no size to fit into, `minAvail` is a definite minimum size
 * instead, which asks for the fewest copies that reach it. Each copy's tracks take the size the
 * items landing in it give them. `fit` marks the tracks an `auto-fit` repeat made, which
 * collapse when no item lands in them.
 */
function expandRepeats(el: Node, tracks: Track[], avail: number, gap: number,
  itemMin: number[], itemMax: number[], minAvail: number = NaN): { tracks: Track[]; fit: boolean[] } {
  const out: Track[] = [];
  const fit: boolean[] = [];
  for (let r = 0; r < tracks.length; r++) {
    const t = tracks[r];
    if (t.repeat === undefined) {
      out.push(t);
      fit.push(false);
      continue;
    }
    const entries = t.repeat.entries;
    const m = entries.length;
    if (m === 0) continue;
    // An item lands in the copy's track its own ordinal picks out, as auto-placement would put it.
    const minC: number[] = [];
    const maxC: number[] = [];
    for (let k = 0; k < m; k++) {
      minC.push(0);
      maxC.push(0);
    }
    for (let k = 0; k < itemMin.length; k++) {
      const i = k % m;
      minC[i] = Math.max(minC[i], itemMin[k]);
      maxC[i] = Math.max(maxC[i], itemMax[k]);
    }
    const sizes = sizeTracks(el, entries, NaN, gap, minC, maxC, false);
    let copy = gap * Math.max(0, m - 1);
    for (const s of sizes) copy += s;
    // The tracks outside this repetition take their room first, each other repetition counting
    // as one copy of itself, and the gutters go between all of them (CSS Grid 7.2.3.1).
    const rest: Track[] = [];
    for (let i = 0; i < tracks.length; i++) {
      const o = tracks[i];
      if (i === r) continue;
      if (o.repeat === undefined) rest.push(o);
      else for (const e of o.repeat.entries) rest.push(e);
    }
    let restSpan = 0;
    if (rest.length > 0) {
      const restSizes = sizeTracks(el, rest, NaN, gap, rest.map(() => 0), rest.map(() => 0), false);
      for (const s of restSizes) if (!Number.isNaN(s)) restSpan += s;
    }
    // Every copy brings its tracks and the gutters between them; the last gutter is the next
    // copy's, so n copies span n * (copy + gap) - gap.
    let n = 1;
    const step = copy + m * gap;
    // The room outside this repetition is what its copies have to fill: a definite size or max
    // size takes as many copies as fit, while a definite minimum size asks for the fewest copies
    // that reach it (CSS Grid 7.2.3.2).
    const room = (Number.isNaN(avail) ? minAvail : avail) + gap - restSpan - rest.length * gap;
    if (!Number.isNaN(room) && step > 0.0001) {
      // Track sizes come out of measured text, so a copy count a hair over a whole number is that
      // number rather than one more.
      n = Number.isNaN(avail) ? Math.ceil(room / step - 0.000001) : Math.floor(room / step);
      if (!Number.isFinite(n) || n < 1) n = 1;
      if (n > 1000) n = 1000;
    }
    // The repetitions' line names ride along: the names before the repetition belong to its
    // first copy's first line, and the names after it to the last copy's last line.
    const lastEntry = entries.length - 1;
    for (let k = 0; k < n; k++) {
      for (let j = 0; j < entries.length; j++) {
        const e = entries[j];
        const first = k === 0 && j === 0;
        const last = k === n - 1 && j === lastEntry;
        const names = first && t.names !== undefined ? mergeNames(e.names, t.names) : e.names;
        const endNames = last && t.endNames !== undefined ? mergeNames(e.endNames, t.endNames) : e.endNames;
        if (names !== e.names || endNames !== e.endNames) out.push({ ...e, names, endNames });
        else out.push(e);
        fit.push(t.repeat.fit);
      }
    }
  }
  return { tracks: out, fit };
}

/** Two sets of line names as one, in order and without repeats. */
function mergeNames(a: string[] | undefined, b: string[]): string[] {
  if (a === undefined) return b.slice();
  const out = a.slice();
  for (const n of b) if (!out.includes(n)) out.push(n);
  return out;
}

/**
 * Drops the auto-fit tracks no item lands in, and remaps the items' areas onto the tracks that
 * stay: a collapsed copy takes no room and the gutters on either side of it go with it.
 */
function collapseEmpty(tracks: Track[], areas: Area[], fitAt: (i: number) => boolean,
  axis: "col" | "row"): { tracks: Track[]; lineMap: number[] } {
  const occupied = new Array<boolean>(tracks.length).fill(false);
  for (const a of areas) {
    const at = axis === "col" ? a.col : a.row;
    const span = axis === "col" ? a.colSpan : a.rowSpan;
    for (let k = 0; k < span; k++) if (at + k < tracks.length) occupied[at + k] = true;
  }
  const kept: Track[] = [];
  const index = new Map<number, number>();
  // How many tracks survive before each line of the un-collapsed numbering: an out-of-flow box
  // names its area by those lines, so they have to be mapped onto the tracks that stay.
  const lineMap: number[] = [];
  for (let i = 0; i < tracks.length; i++) {
    lineMap.push(kept.length);
    if (fitAt(i) && !occupied[i]) continue;
    index.set(i, kept.length);
    kept.push(tracks[i]);
  }
  lineMap.push(kept.length);
  for (const a of areas) {
    if (axis === "col") {
      const at = index.get(a.col);
      if (at !== undefined) a.col = at;
    } else {
      const at = index.get(a.row);
      if (at !== undefined) a.row = at;
    }
  }
  return { tracks: kept, lineMap };
}

/**
 * Where the track set starts in the container's content box, and the extra room between tracks,
 * for one align-content/justify-content value (CSS Align 6.2). `normal` and `stretch` are handled
 * before this, by growing the auto tracks; what free space is left here is overflow.
 */
function distribute(mode: number, free: number, n: number, safe: boolean): [number, number] {
  if (n === 0) return [0, 0];
  // A `safe` packing that would overflow the container packs from the start edge instead.
  if (safe && free < 0) return [0, 0];
  if (mode === P.J_CENTER) return [free / 2, 0];
  if (mode === P.J_END) return [free, 0];
  // A spacing mode given less room than its items need: space-between packs at the start, while
  // the two that leave room at both edges fall back to centering (CSS Align 5.4).
  if (mode === P.J_SPACE_BETWEEN) return n > 1 && free > 0 ? [0, free / (n - 1)] : [0, 0];
  if (mode === P.J_SPACE_AROUND) return [free / n / 2, free / n];
  if (mode === P.J_SPACE_EVENLY) return [free / (n + 1), free / (n + 1)];
  return [0, 0];
}

/**
 * The mode an item's alignment settles on. `normal` fills the grid area, except for an item that
 * brings a size of its own — a replaced box, or one with a preferred aspect ratio — where it
 * behaves as `start` (CSS Align 3, justify-self/align-self `normal`).
 */
function itemMode(mode: number, item: Node): number {
  if (mode !== P.A_NORMAL) return mode;
  return isReplaced(item) || aspectRatio(item) > 0 ? P.A_START : P.A_STRETCH;
}

/** Distance from an item's border-box top to the baseline its alignment uses. A box with no
 *  baseline of its own synthesizes one from its border box's end edge (CSS Align 9.1). */
function itemBaseline(c: Node, last: boolean): number {
  const b = last ? naturalLastBaseline(c) : naturalBaseline(c);
  return b >= 0 ? b : c.h;
}

/** Whether an item's block flow runs against the container's, so the baseline it supplies for
 *  one side of the container is the one it keeps for its other side (CSS Align 9, baseline
 *  alignment across writing modes). An item in an orthogonal flow takes an axis-compatible
 *  writing mode: a vertical item assumes horizontal-tb, and a horizontal one vertical-lr, or
 *  vertical-rl when it runs right to left. */
function baselineFlipped(el: Node, c: Node): boolean {
  const cw = usedWritingMode(el);
  const iw = usedWritingMode(c);
  const rl = (m: number): boolean => m === P.WM_VERTICAL_RL || m === P.WM_SIDEWAYS_RL;
  const cVert = cw !== P.WM_HORIZONTAL_TB;
  const iVert = iw !== P.WM_HORIZONTAL_TB;
  if (!cVert) return false; // a vertical item beside a horizontal one assumes horizontal-tb
  if (!iVert) return rl(cw) !== isRtl(c);
  return rl(cw) !== rl(iw);
}

/** Whether an item's lines run across the container's, which leaves it with no baseline along the
 *  container's block axis: the baselines it has of its own run along that axis, not across it
 *  (CSS Align 9.2). */
function orthoBase(el: Node, c: Node): boolean {
  const vert = (m: number): boolean => m !== P.WM_HORIZONTAL_TB;
  return vert(usedWritingMode(el)) !== vert(usedWritingMode(c));
}

/** The baseline an item supplies the container's set on the side `last` names: the kind it keeps
 *  for that side, which is the other one when its block flow runs the other way. A box written
 *  across the container's block axis has none to supply, so it synthesizes one from its border
 *  box's end edge like a box without a baseline. */
function itemBaseFor(el: Node, c: Node, last: boolean): number {
  if (orthoBase(el, c)) return c.h;
  return itemBaseline(c, baselineFlipped(el, c) ? false : last);
}

/** The natural baseline (`-1` when the box has none) an item supplies for the side `last`. */
function natBaseFor(el: Node, c: Node, last: boolean): number {
  if (orthoBase(el, c)) return -1;
  return baselineFlipped(el, c) || !last ? naturalBaseline(c) : naturalLastBaseline(c);
}

/** The side of the container an item lines up on: the one its keyword names, or the other when
 *  its block flow runs the other way. */
function baseSide(el: Node, c: Node, last: boolean): boolean {
  return baselineFlipped(el, c) ? !last : last;
}

/** An item's block-axis margins as the container's block axis sees them, with whether each is
 *  auto: an item whose block flow runs against the container's puts its own start margin on the
 *  container's end side. */
function blockMargins(el: Node, c: Node, w: number): [number, number, boolean, boolean] {
  const autoT = sizeUnit(c, P.P_MARGIN_TOP) === P.U_AUTO;
  const autoB = sizeUnit(c, P.P_MARGIN_BOTTOM) === P.U_AUTO;
  let mt = autoT ? 0 : zeroIfNaN(len(c, P.P_MARGIN_TOP, w));
  let mb = autoB ? 0 : zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, w));
  let aT = autoT;
  let aB = autoB;
  const cw = usedWritingMode(el);
  const iw = usedWritingMode(c);
  const vert = (m: number): boolean => m !== P.WM_HORIZONTAL_TB;
  const rl = (m: number): boolean => m === P.WM_VERTICAL_RL || m === P.WM_SIDEWAYS_RL;
  if (vert(cw) && vert(iw) && rl(cw) !== rl(iw)) {
    const t = mt;
    mt = mb;
    mb = t;
    const at = aT;
    aT = aB;
    aB = at;
  }
  return [mt, mb, aT, aB];
}

/** The height of an area whose rows are all fixed tracks, or NaN when one takes its size from content. */
function definiteAreaHeight(rowFixed: number[], rowGap: number, a: Area): number {
  let h = rowGap * Math.max(0, a.rowSpan - 1);
  for (let k = 0; k < a.rowSpan; k++) {
    const f = rowFixed[a.row + k];
    if (Number.isNaN(f)) return NaN;
    h += f;
  }
  return h;
}

/**
 * The width an item stretched over a definite area takes from its preferred aspect ratio, which is
 * the width its column has to be able to hold (CSS Grid 11.5).
 */
function stretchRatioWidth(el: Node, c: Node, areaH: number, cbW: number): number {
  if (Number.isNaN(areaH) || !(aspectRatio(c) > 0)) return 0;
  if (alignMode(el, c) !== P.A_STRETCH || sizeUnit(c, P.P_HEIGHT) !== P.U_AUTO) return 0;
  if (sizeUnit(c, P.P_MARGIN_TOP) === P.U_AUTO || sizeUnit(c, P.P_MARGIN_BOTTOM) === P.U_AUTO) return 0;
  return clampW(c, aspectW(c, Math.max(0, areaH - marginV(c, cbW)), cbW), cbW);
}

/** Whether the block-axis alignment winning for an item carries `safe`, which clamps an
 *  overflowing item to the start edge. */
function alignSafe(container: Node, item: Node): boolean {
  const self = item.sv[P.P_ALIGN_SELF];
  return self === P.A_AUTO ? container.su[P.P_ALIGN_ITEMS] === P.U_SAFE : item.su[P.P_ALIGN_SELF] === P.U_SAFE;
}

/** The inline-axis counterpart of alignSafe. */
function justifySafe(container: Node, item: Node): boolean {
  const self = item.sv[P.P_JUSTIFY_SELF];
  return self === P.A_AUTO ? container.su[P.P_JUSTIFY_ITEMS] === P.U_SAFE : item.su[P.P_JUSTIFY_SELF] === P.U_SAFE;
}

/** align-self (the block axis), falling back to the container's align-items. */
function alignMode(container: Node, item: Node): number {
  const self = item.sv[P.P_ALIGN_SELF];
  return alignEdge(itemMode(self === P.A_AUTO ? container.sv[P.P_ALIGN_ITEMS] : self, item));
}

/** justify-content as the grid's inline axis runs: on a horizontal axis a right-to-left
 *  direction turns the physical edges around, and on a vertical one they mean nothing at all,
 *  which is where a browser starts the set instead. */
function contentMode(container: Node, v: number): number {
  if (isVerticalText(container)) {
    if (v === P.J_LEFT || v === P.J_RIGHT) v = P.J_START;
  } else if (isRtl(container)) {
    if (v === P.J_LEFT) v = P.J_RIGHT;
    else if (v === P.J_RIGHT) v = P.J_LEFT;
  }
  return contentEdge(v);
}

/** justify-self (the inline axis), falling back to the container's justify-items. A box laid out
 *  left to right carries no baseline across its inline axis, so a baseline position synthesizes
 *  one from its start edge — its end edge for `last baseline` (CSS Align 9.1). */
function justifyMode(container: Node, item: Node): number {
  const self = item.sv[P.P_JUSTIFY_SELF];
  let mode = itemMode(self === P.A_AUTO ? container.sv[P.P_JUSTIFY_ITEMS] : self, item);
  // A self-relative keyword follows the item's own direction: one that runs the other way from
  // its container lines up on the container's other side.
  if (isRtl(container) !== isRtl(item) && isVerticalText(container) === isVerticalText(item)) {
    if (mode === P.A_SELF_START) mode = P.A_SELF_END;
    else if (mode === P.A_SELF_END) mode = P.A_SELF_START;
  }
  // The physical edges follow the page's direction on a horizontal inline axis, and mean nothing
  // on a vertical one, where a browser drops them.
  if (isVerticalText(container)) {
    if (mode === P.A_LEFT || mode === P.A_RIGHT) mode = P.A_START;
  } else if (isRtl(container)) {
    if (mode === P.A_LEFT) mode = P.A_RIGHT;
    else if (mode === P.A_RIGHT) mode = P.A_LEFT;
  }
  mode = alignEdge(mode);
  if (mode === P.A_BASELINE) return P.A_START;
  if (mode === P.A_LAST_BASELINE) return P.A_END;
  return mode;
}

/** Whether an item's own block flow runs along the container's inline axis the other way round,
 *  which puts the baseline it keeps for one of its own sides on the container's other side (CSS
 *  Align 9, baseline alignment across writing modes). */
function inlineBaseFlipped(el: Node, c: Node): boolean {
  const m = usedWritingMode(c);
  return (m === P.WM_VERTICAL_RL || m === P.WM_SIDEWAYS_RL) !== isRtl(el);
}

/** The side of the container's inline axis an item's baseline group sits on — 0 for the start of
 *  the axis, 1 for its end — or -1 when the item lines up on no baseline there, or carries none
 *  across that axis, which a box written the container's own way does not. */
function inlineBaseSide(el: Node, c: Node): number {
  if (!isVerticalText(c) || isVerticalText(el)) return -1;
  const self = c.sv[P.P_JUSTIFY_SELF];
  const mode = itemMode(self === P.A_AUTO ? el.sv[P.P_JUSTIFY_ITEMS] : self, c);
  if (mode !== P.A_BASELINE && mode !== P.A_LAST_BASELINE) return -1;
  return mode === P.A_LAST_BASELINE !== inlineBaseFlipped(el, c) ? 1 : 0;
}

/** Distance from an item's inline-start border edge to the baseline it lines up on, which is the
 *  first or last one its own `justify-self` names, or -1 when it carries none across the axis. A
 *  box written down the page keeps its line boxes in a turned frame, where a line running right
 *  to left counts its baselines from the other edge. */
function inlineBaseFor(el: Node, c: Node): number {
  if (inlineBaseSide(el, c) < 0) return -1;
  const self = c.sv[P.P_JUSTIFY_SELF];
  const mode = itemMode(self === P.A_AUTO ? el.sv[P.P_JUSTIFY_ITEMS] : self, c);
  const d = mode === P.A_LAST_BASELINE ? naturalLastBaseline(c) : naturalBaseline(c);
  // A box with no baseline of its own synthesizes one from its border box's end edge.
  if (d < 0) return c.w;
  const m = usedWritingMode(c);
  const x = m === P.WM_VERTICAL_RL || m === P.WM_SIDEWAYS_RL ? c.w - d : d;
  return isRtl(el) ? c.w - x : x;
}

/** The line context of one axis: its explicit tracks, widened by any named area, and their names. */
function axisOf(tracks: Track[], areas: AreaName[] | null, col: boolean): Axis {
  return { explicit: Math.max(tracks.length, areaExtent(areas, col)), names: axisNames(tracks, areas, col) };
}

/** The number of tracks an area list's names need, whichever axis the areas span. */
function areaExtent(areas: AreaName[] | null, col: boolean): number {
  if (areas === null) return 0;
  let n = 0;
  for (const a of areas) n = Math.max(n, (col ? a.colEnd : a.rowEnd) - 1);
  return n;
}


/** The row and column tracks an item's placement names, with auto-placement gaps left as auto. */
function areasOf(el: Node, items: Node[], colAx: Axis, rowAx: Axis): Area[] {
  const out: Area[] = [];
  for (const c of items) {
    const cs = startOf(c.sv[P.P_GRID_COLUMN_START], c.su[P.P_GRID_COLUMN_START],
      c.sv[P.P_GRID_COLUMN_END], c.su[P.P_GRID_COLUMN_END], colAx);
    const rs = startOf(c.sv[P.P_GRID_ROW_START], c.su[P.P_GRID_ROW_START],
      c.sv[P.P_GRID_ROW_END], c.su[P.P_GRID_ROW_END], rowAx);
    const autoCol = Number.isNaN(cs.start);
    const autoRow = Number.isNaN(rs.start);
    out.push({
      col: autoCol ? 0 : cs.start - 1, colSpan: cs.span,
      row: autoRow ? 0 : rs.start - 1, rowSpan: rs.span,
      autoCol, autoRow,
    });
  }
  return out;
}

/** The grid items in order-modified document order, which is the order auto-placement fills. */
function orderedItems(el: Node): Node[] {
  const items = visibleChildren(el);
  const idx: number[] = [];
  for (let i = 0; i < items.length; i++) idx.push(i);
  idx.sort((a, b) => {
    const d = items[a].sv[P.P_ORDER] - items[b].sv[P.P_ORDER];
    return d !== 0 ? d : a - b;
  });
  const out: Node[] = [];
  for (const i of idx) out.push(items[i]);
  return out;
}

/** The rectangle of a grid area, or of the content box an out-of-flow box is laid out in, in the
 *  grid's border box coordinates. A child the grid placed takes the area its lines give it. */
interface AreaRect { x: number; y: number; w: number; h: number }

/** An item laid out in its area, before alignment moves it there. */
interface Cell {
  c: Node; a: Area; w: number; h: number; ml: number; mr: number; mt: number; mb: number; mode: number;
  autoH: number; cyc: boolean;
}

/**
 * Where line `L` of one axis sits, in the grid's content box, or NaN when the grid has no such
 * line. `lines` holds each track's start and `sizes` its size, both after the implicit tracks the
 * in-flow items reached were added on either side (`shift`). An empty grid still has line 1,
 * where its content starts.
 */
function lineAt(L: number, lines: number[], sizes: number[], shift: number): number {
  if (Number.isNaN(L)) return NaN;
  const i = L - 1 + shift;
  if (i >= 0 && i < lines.length) return lines[i];
  if (i === lines.length) {
    return lines.length === 0 ? 0 : lines[lines.length - 1] + sizes[sizes.length - 1];
  }
  return NaN;
}

/**
 * Where the track that line `L` ends sits, in the grid's content box: the line itself stands at the
 * start of the track after it, so the gutter that follows comes back off. A gutter is the space
 * between two tracks, not part of either one (CSS Grid 10.1).
 */
function trackEndAt(L: number, lines: number[], sizes: number[], shift: number): number {
  if (Number.isNaN(L)) return NaN;
  const i = L - 1 + shift;
  if (i === 0) return lines.length === 0 ? 0 : lines[0];
  if (i > 0 && i <= lines.length) return lines[i - 1] + sizes[i - 1];
  return NaN;
}

/**
 * The two edges of an out-of-flow child's area on one axis, in the grid's content box. An `auto`
 * placement side sits on the corresponding padding edge of the grid container, and a line the
 * grid doesn't have counts as `auto` (CSS Grid 9.1). `padStart` and `padEnd` are the padding
 * edges, negative outside the content box.
 */
function oofExtent(startV: number, startU: number, endV: number, endU: number, ax: Axis,
  lines: number[], sizes: number[], shift: number, padStart: number, padEnd: number,
  lineMap: number[] | null): { a: number; b: number } {
  // An `auto-fit` grid renumbers its lines when the empty copies collapse; the child names its
  // area by the lines of the track list before that, so those are mapped onto the kept ones.
  const L = (x: number): number => lineMap === null || Number.isNaN(x) ? x : mapCollapsedLine(x, lineMap);
  const s = L(lineOf(startV, startU, ax, false));
  const e = L(lineOf(endV, endU, ax, true));
  let a = NaN;
  let b = NaN;
  if (!Number.isNaN(s) && !Number.isNaN(e)) {
    a = lineAt(s, lines, sizes, shift);
    b = trackEndAt(e, lines, sizes, shift);
  } else if (!Number.isNaN(s) && endU === P.U_SPAN) {
    const r = startOf(startV, startU, endV, endU, ax);
    a = lineAt(s, lines, sizes, shift);
    b = trackEndAt(L(r.start + r.span), lines, sizes, shift);
  } else if (!Number.isNaN(e) && startU === P.U_SPAN) {
    const r = startOf(startV, startU, endV, endU, ax);
    a = lineAt(L(r.start), lines, sizes, shift);
    b = trackEndAt(e, lines, sizes, shift);
  } else if (!Number.isNaN(s)) {
    a = lineAt(s, lines, sizes, shift);
  } else if (!Number.isNaN(e)) {
    b = trackEndAt(e, lines, sizes, shift);
  }
  if (Number.isNaN(a)) a = padStart;
  if (Number.isNaN(b)) b = padEnd;
  return a <= b ? { a, b } : { a: b, b: a };
}

/**
 * Maps a line of the track list an `auto-fit` collapse was given onto the line the kept tracks
 * leave: a line between collapsed copies lands on the next surviving line.
 */
function mapCollapsedLine(line: number, map: number[]): number {
  const i = line - 1;
  if (i < 0) return line;
  if (i >= map.length) return map[map.length - 1] + 1;
  return map[i] + 1;
}

/** True when `el` is the containing block of `c`, which must be a descendant of it. */
function isContainingBlockFor(el: Node, c: Node): boolean {
  const fixed = c.sv[P.P_POSITION] === P.POS_FIXED;
  for (let a = c.parentElement; a !== null && a !== el; a = a.parentElement) {
    if (hasTransform(a) || a.sv[P.P_PERSPECTIVE] >= 0 || a.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN) return false;
    if (!fixed && a.sv[P.P_POSITION] !== P.POS_STATIC) return false;
  }
  return fixed ? hasTransform(el) || el.sv[P.P_PERSPECTIVE] >= 0 || el.sv[P.P_BACKFACE_VISIBILITY] === P.BFV_HIDDEN : el.sv[P.P_POSITION] !== P.POS_STATIC;
}

/**
 * Gives the grid area to every out-of-flow descendant whose containing block this grid is, not
 * only the direct children placeOutOfFlow lays out: a positioned box further down the tree takes
 * the area its own grid placement names as its containing block just the same (CSS Grid 9.1).
 */
function markDescendantAreas(node: Node, root: Node, areaOf: (c: Node) => AreaRect): void {
  for (const c of boxKids(node)) {
    if (display(c) === P.D_NONE) continue;
    if (isOutOfFlow(c) && isContainingBlockFor(root, c)) {
      const ar = areaOf(c);
      c.gridCbValid = true;
      c.gridCbX = ar.x;
      c.gridCbY = ar.y;
      c.gridCbW = ar.w;
      c.gridCbH = ar.h;
    }
    markDescendantAreas(c, root, areaOf);
  }
}

/**
 * Lays out the grid's out-of-flow children. One whose containing block the grid is takes the area
 * its placement names, with an auto side on the container's padding edge, and its static position
 * is the area's start corner aligned by its own `justify-self`/`align-self`; one that is not is
 * laid out against the container's content box (CSS Grid 9.1).
 */
function placeOutOfFlow(el: Node, innerW: number, boxH: number, pl: number, pt: number,
  areaOf: (c: Node) => AreaRect): void {
  for (const c of boxKids(el)) {
    if (display(c) === P.D_NONE || !isOutOfFlow(c)) continue;
    c.gridCbValid = false;
    // The area an absolutely-positioned child names positions it only when the grid container is
    // its containing block; one that is not leaves the child in the content box, aligned there by
    // its own justify-self/align-self.
    const fixed = c.sv[P.P_POSITION] === P.POS_FIXED;
    const isCb = fixed ? hasTransform(el) : el.sv[P.P_POSITION] !== P.POS_STATIC;
    const ar = isCb ? areaOf(c) : { x: pl, y: pt, w: innerW, h: boxH };
    const cw = ar.w;
    const ch = ar.h;
    layoutBox(c, cw, ch, NaN, NaN, true);
    // An out-of-flow box shares no baseline group, so a baseline position falls back to the
    // edge it would synthesize one from: the start edge, or the end edge for `last baseline`.
    const am = alignMode(el, c);
    const ay = am === P.A_BASELINE ? P.A_START : am === P.A_LAST_BASELINE ? P.A_END : am;
    const outerW = c.w + marginH(c, cw);
    const staticW = cw - outerW;
    const jx = alignOffset(justifyMode(el, c), staticW, justifySafe(el, c));
    // A right-to-left area aligns from its right edge, so the box sits the same distance in
    // from the other side.
    c.staticX = inlineMirrored(el) ? ar.x + cw - outerW - jx : ar.x + jx;
    c.staticY = ar.y + alignOffset(ay, ch - c.h - marginV(c, cw), alignSafe(el, c));
    // A percentage on a child in a definite area resolves against the area, not the whole grid.
    if (isCb) {
      c.gridCbValid = true;
      c.gridCbX = ar.x;
      c.gridCbY = ar.y;
      c.gridCbW = ar.w;
      c.gridCbH = ar.h;
    }
  }
}

/** The width an `inline-grid-lanes` shrinks to fit: its grid-axis tracks at their max-content. */
export function gridLanesShrinkWidth(el: Node, cbW: number, cbH: number): number {
  const dirU = el.su[P.P_GRID_LANES_DIRECTION];
  const dirV = el.sv[P.P_GRID_LANES_DIRECTION];
  const colList = trackList(el.sv[P.P_GRID_TEMPLATE_COLUMNS]) ?? [];
  const rowList = trackList(el.sv[P.P_GRID_TEMPLATE_ROWS]) ?? [];
  const rowLanes = dirU === P.U_AUTO ? colList.length === 0 && rowList.length > 0 : (dirV & P.GL_ROW) !== 0;
  if (rowLanes) return cbW;
  return gridIntrinsicWidth(el, cbW, cbH, false);
}

/** The width an `inline-grid` shrinks to fit: its tracks at their max-content sizes. */
export function gridShrinkWidth(el: Node, cbW: number, cbH: number, cbHeight: number = NaN): number {
  return gridIntrinsicWidth(el, cbW, cbH, false, cbHeight);
}

/** A border-box inline size as the content-box size the grid's tracks fill. */
function contentBoxW(el: Node, w: number, cbW: number): number {
  return el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? Math.max(0, w - padH(el, cbW)) : w;
}

/**
 * The content-box inline size an auto-repeat's copies may fill, or NaN when the grid has no
 * definite inline size or max size: its max-width, and the width its preferred aspect ratio
 * transfers from a definite max-height, whichever is smaller (CSS Grid 7.2.3.2, CSS Sizing 4
 * §5.1). `cbH` is the containing block's height, which a percentage max-height resolves against.
 */
function repeatMaxInline(el: Node, cbW: number, cbH: number): number {
  let max = contentBoxW(el, len(el, P.P_MAX_WIDTH, cbW), cbW);
  const maxH = aspectRatio(el) > 0 ? boundedRatioH(el, cbW, cbH) : NaN;
  if (!Number.isNaN(maxH)) {
    const t = contentBoxW(el, aspectW(el, maxH, cbW), cbW);
    if (Number.isNaN(max) || t < max) max = t;
  }
  return max;
}

/**
 * The content-box inline size a grid's auto-repeat copies have to reach, or NaN when the grid has
 * no definite minimum inline size: its min-width, or the width its preferred aspect ratio
 * transfers from a definite min-height, which a definite max-width caps (CSS Grid 7.2.3.2, CSS
 * Sizing 4 §4.4).
 */
function repeatMinInline(el: Node, cbW: number, cbH: number): number {
  let min = contentBoxW(el, len(el, P.P_MIN_WIDTH, cbW), cbW);
  const minH = aspectRatio(el) > 0 ? len(el, P.P_MIN_HEIGHT, cbH) : NaN;
  if (!Number.isNaN(minH)) {
    const adjV = el.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padV(el, cbW);
    let t = contentBoxW(el, aspectW(el, minH + adjV, cbW), cbW);
    const cap = contentBoxW(el, len(el, P.P_MAX_WIDTH, cbW), cbW);
    if (!Number.isNaN(cap) && t > cap) t = cap;
    if (Number.isNaN(min) || t > min) min = t;
  }
  return min;
}

/**
 * The inline size a grid asks for when nothing constrains it: the tracks at the sizes their
 * content gives them, which is what makes an `inline-grid` shrink to fit and what `min-content`
 * and `max-content` name on a grid (CSS Grid 11.5 gives an intrinsically-sized grid its
 * max-content width; the min-content width is the tracks at their automatic minimums).
 */
export function gridIntrinsicWidth(el: Node, cbW: number, cbH: number, minContent: boolean,
  cbHeight: number = NaN): number {
  const items = orderedItems(el);
  // A gap's percentage takes no part in an intrinsic size: it resolves against zero here, and
  // against the width the tracks end up with once the box has one (CSS Align 3, gap percentages).
  const colGap = zeroIfNaN(len(el, P.P_COLUMN_GAP, 0));
  // A max-content grid still may not grow past its max-width, so that is the room an auto-repeat
  // counts its copies against; without one a definite minimum size — its min-width, or the width
  // its preferred aspect ratio transfers from a definite min-height — asks for the fewest copies
  // that reach it, and with neither the count is the single copy an unknown size gets. `cbHeight`
  // is the containing block's height, which a percentage min-height or max-height resolves against.
  const repeatAvail = repeatMaxInline(el, cbW, cbHeight);
  const repeatMin = Number.isNaN(repeatAvail) ? repeatMinInline(el, cbW, cbHeight) : NaN;
  const colExp = expandRepeats(el, trackList(el.sv[P.P_GRID_TEMPLATE_COLUMNS]) ?? [], repeatAvail,
    colGap, [], [], repeatMin);
  const explicit = colExp.tracks;
  const explicitRows = expandRepeats(el, trackList(el.sv[P.P_GRID_TEMPLATE_ROWS]) ?? [], NaN, 0, [], []).tracks;
  const autoCols = autoTracks(el, P.P_GRID_AUTO_COLUMNS);
  const flow = el.sv[P.P_GRID_AUTO_FLOW];
  const column = flow === P.GF_COLUMN || flow === P.GF_COLUMN_DENSE;
  const dense = flow === P.GF_ROW_DENSE || flow === P.GF_COLUMN_DENSE;
  const namedAreas = areaList(el.sv[P.P_GRID_TEMPLATE_AREAS]);
  const colAx = axisOf(explicit, namedAreas, true);
  const rowAx = axisOf(explicitRows, namedAreas, false);
  const areas = areasOf(el, items, colAx, rowAx);
  autoPlace(areas, flowLines(areas, column ? rowAx.explicit : colAx.explicit, column), column, dense);
  const { colShift, rowShift, cols, rows } = shiftAreas(areas, colAx.explicit, rowAx.explicit);
  if (cols === 0) return 0;
  const autoRows = autoTracks(el, P.P_GRID_AUTO_ROWS);
  let colTracks = allTracks(explicit, autoCols, cols, colShift);
  // An `auto-fit` copy no item lands in takes no room, neither track nor gutter.
  if (colExp.fit.length > 0) {
    colTracks = collapseEmpty(colTracks, areas, (i) => colExp.fit[i - colShift] === true, "col").tracks;
  }
  const ncols = colTracks.length;
  // A row a fixed track names is definite, so an item in one resolves its percentage height
  // against its grid area and a preferred aspect ratio turns that into a width.
  const rowGap = zeroIfNaN(len(el, P.P_ROW_GAP, 0));
  const rowFixed: number[] = [];
  for (const t of allTracks(explicitRows, autoRows, rows, rowShift)) rowFixed.push(fixedPx(t.max, el, cbH));
  const basisH = (a: Area): number => {
    const d = definiteAreaHeight(rowFixed, rowGap, a);
    return Number.isNaN(d) ? cbH : d;
  };
  const minC: number[] = [];
  const maxC: number[] = [];
  const autoC: number[] = [];
  for (let i = 0; i < ncols; i++) {
    minC.push(0);
    maxC.push(0);
    autoC.push(0);
  }
  // An item spanning several columns, one of them flexible, has an automatic minimum size of
  // zero (CSS Grid 6.6).
  const zeroMin = (c: Node, a: Area): boolean => {
    if (a.colSpan < 2 || sizeUnit(c, P.P_WIDTH) !== P.U_AUTO || sizeUnit(c, P.P_MIN_WIDTH) !== P.U_AUTO) return false;
    for (let k = 0; k < a.colSpan; k++) if (colTracks[a.col + k].max.kind === P.GT_FR) return true;
    return false;
  };
  // The stretch fit into the columns an item spans: the room their fixed maximums give it, or
  // nothing to cap by when one of them isn't fixed (CSS Grid 12.5.1).
  const stretchFitW = (a: Area): number => {
    let sum = colGap * Math.max(0, a.colSpan - 1);
    for (let k = 0; k < a.colSpan; k++) {
      const f = fixedPx(colTracks[a.col + k].max, el, NaN);
      if (Number.isNaN(f)) return INF;
      sum += f;
    }
    return sum;
  };
  const autoMinW = (c: Node, a: Area, inner: number): number => {
    const auto = sizeUnit(c, P.P_WIDTH) === P.U_AUTO || sizeUnit(c, P.P_WIDTH) === P.U_PCT;
    const given = sizeUnit(c, P.P_MIN_WIDTH) !== P.U_AUTO ? len(c, P.P_MIN_WIDTH, cbW) : NaN;
    // An item that scrolls in the inline axis takes no minimum size from its content: its
    // overflowing content doesn't widen it (CSS Grid 6.6).
    const w = !auto ? inner : !Number.isNaN(given) ? Math.max(0, given)
      : scriptScrollsX(c) ? 0 : Math.min(inner, stretchFitW(a));
    return w + marginH(c, cbW);
  };
  for (let i = 0; i < items.length; i++) {
    const c = items[i];
    const a = areas[i];
    const stretchedW = stretchRatioWidth(el, c, definiteAreaHeight(rowFixed, rowGap, a), cbW);
    const inner = zeroMin(c, a) ? stretchedW
      : Math.max(stretchedW, intrinsicMinWidth(c, cbW, basisH(a)));
    const mn = inner + marginH(c, cbW);
    const an = zeroMin(c, a) ? mn : autoMinW(c, a, inner);
    const mx = Math.max(stretchedW, intrinsicMaxWidth(c, cbW, basisH(a))) + marginH(c, cbW);
    if (a.colSpan === 1) {
      minC[a.col] = Math.max(minC[a.col], mn);
      maxC[a.col] = Math.max(maxC[a.col], mx);
      autoC[a.col] = Math.max(autoC[a.col], an);
    } else {
      let fixedAndGaps = colGap * (a.colSpan - 1);
      const growable: number[] = [];
      for (let k = 0; k < a.colSpan; k++) {
        // The grid's own width is what's being worked out, so a percentage track can't be a fixed
        // share of it: it sizes as auto, and takes its part of a spanning item's size.
        const f = fixedPx(colTracks[a.col + k].max, el, NaN);
        if (Number.isNaN(f)) growable.push(a.col + k);
        else fixedAndGaps += f;
      }
      if (growable.length > 0) {
        for (const k of growable) {
          minC[k] = Math.max(minC[k], Math.max(0, mn - fixedAndGaps) / growable.length);
          maxC[k] = Math.max(maxC[k], Math.max(0, mx - fixedAndGaps) / growable.length);
          autoC[k] = Math.max(autoC[k], Math.max(0, an - fixedAndGaps) / growable.length);
        }
      }
    }
  }
  const sizes = sizeTracks(el, colTracks, NaN, colGap, minC, maxC, false, minContent, autoC);
  let w = colGap * (ncols - 1);
  for (const s of sizes) w += s;
  return w;
}

/**
 * Gives a subgrid item the tracks it spans in its parent: the column sizes are known before the
 * items are laid out, and the row sizes only once the rows are (null keeps the subgrid's own
 * content-sized rows while the parent is still measuring).
 */
function adoptTracks(cols: number[], colGap: number, c: Node, a: Area, rows: number[] | null,
  rowGap: number): void {
  if (c.su[P.P_GRID_TEMPLATE_COLUMNS] === P.U_SUBGRID) {
    const sizes = cols.slice(a.col, a.col + a.colSpan);
    trimSubgridEdges(c, sizes, colGap, true);
    c.sgCols = sizes;
    c.sgColGap = colGap;
    c.sgColSet = true;
  }
  if (rows !== null && c.su[P.P_GRID_TEMPLATE_ROWS] === P.U_SUBGRID) {
    const sizes = rows.slice(a.row, a.row + a.rowSpan);
    trimSubgridEdges(c, sizes, rowGap, false);
    c.sgRows = sizes;
    c.sgRowGap = rowGap;
    c.sgRowSet = true;
  }
}

/** The room a subgrid's own margin, border and padding take at its start and end edges. */
function blockInsets(c: Node, basis: number): [number, number] {
  const start = zeroIfNaN(len(c, P.P_MARGIN_TOP, basis)) + blockStartBorder(c) +
    zeroIfNaN(len(c, P.P_PADDING_TOP, basis));
  const end = zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, basis)) + blockEndBorder(c) +
    zeroIfNaN(len(c, P.P_PADDING_BOTTOM, basis));
  return [start, end];
}

/**
 * The sizes a row-subgrid asks the rows it spans for (CSS Grid 2 §9): its own rows cover the
 * rows of the span in order, its block margin, border and padding go on the outer rows, and the
 * room its box has beyond those rows — its gutters, where they differ from the parent's — is
 * shared out the way its tracks take up a gutter difference: half at each end and a whole one in
 * between. A span row past its own rows asks for nothing. Null when the item does not subgrid its
 * rows at all, or spans only one.
 */
function subgridRows(c: Node, a: Area, parentGap: number): number[] | null {
  if (a.rowSpan < 2 || c.su[P.P_GRID_TEMPLATE_ROWS] !== P.U_SUBGRID) return null;
  const own = c.gridUsedRows;
  if (own.length === 0 || Number.isNaN(c.h)) return null;
  const n = a.rowSpan;
  const rows: number[] = [];
  let sum = 0;
  for (let k = 0; k < n; k++) {
    const s = k < own.length ? own[k] : 0;
    sum += s;
    rows.push(s);
  }
  const [top, bottom] = blockInsets(c, c.h);
  rows[0] += top;
  rows[n - 1] += bottom;
  const per = (c.h - sum - top - bottom - parentGap * (n - 1)) / (n - 1);
  for (let k = 0; k < n; k++) rows[k] = Math.max(0, rows[k] + per * (k === 0 || k === n - 1 ? 0.5 : 1));
  return rows;
}

/** The room a subgrid's own margin, border and padding take at its inline start and end edges. */
function inlineInsets(c: Node, basis: number): [number, number] {
  const box = (m: number, b: number, p: number): number =>
    zeroIfNaN(len(c, m, basis)) + b + zeroIfNaN(len(c, p, basis));
  return [box(P.P_MARGIN_LEFT, inlineStartBorder(c), P.P_PADDING_LEFT),
    box(P.P_MARGIN_RIGHT, inlineEndBorder(c), P.P_PADDING_RIGHT)];
}

/**
 * The room a column-subgrid asks the columns it spans for (CSS Grid 2 §9), one entry per column:
 * the min-content, max-content and automatic minimum widths of the items in each of its own
 * columns, its inline margin, border and padding on the outer spanned columns, and the difference
 * between its own gutters and the parent's shared out half per end column and a whole one in
 * between. Null when the item is not a column-subgrid, or its own contributions are not known yet
 * — the parent measures its children after the first pass, so the second one maps them.
 */
function columnSubgrid(c: Node, a: Area, parentGap: number, basis: number): [number[], number[], number[]] | null {
  if (a.colSpan < 2 || c.su[P.P_GRID_TEMPLATE_COLUMNS] !== P.U_SUBGRID) return null;
  const src = [c.gridColMin, c.gridColMax, c.gridColAuto];
  if (src[0].length === 0) return null;
  const n = a.colSpan;
  const out: [number[], number[], number[]] = [[], [], []];
  for (let s = 0; s < 3; s++) {
    for (let k = 0; k < n; k++) out[s].push(k < src[s].length ? src[s][k] : 0);
  }
  const [start, end] = inlineInsets(c, basis);
  const per = c.gridColGapUsed - parentGap;
  for (let k = 0; k < n; k++) {
    const edge = (k === 0 ? start : 0) + (k === n - 1 ? end : 0);
    const share = per * (k === 0 || k === n - 1 ? 0.5 : 1);
    for (let s = 0; s < 3; s++) out[s][k] = Math.max(0, out[s][k] + edge + share);
  }
  return out;
}

/** A subgrid's own margin, border and padding at an edge sit inside the space its tracks were
 *  sized from — the parent adds them to the edge items' margins — so the content it lays out is
 *  that much narrower. The first track takes the start inset and the last the end one. */
function trimSubgridEdges(c: Node, sizes: number[], gap: number, col: boolean): void {
  if (sizes.length === 0) return;
  let basis = gap * (sizes.length - 1);
  for (const s of sizes) basis += s;
  const inset = (m: number, b: number, p: number): number =>
    zeroIfNaN(len(c, m, basis)) + b + zeroIfNaN(len(c, p, basis));
  const start = col
    ? inset(P.P_MARGIN_LEFT, inlineStartBorder(c), P.P_PADDING_LEFT)
    : inset(P.P_MARGIN_TOP, blockStartBorder(c), P.P_PADDING_TOP);
  const end = col
    ? inset(P.P_MARGIN_RIGHT, inlineEndBorder(c), P.P_PADDING_RIGHT)
    : inset(P.P_MARGIN_BOTTOM, blockEndBorder(c), P.P_PADDING_BOTTOM);
  sizes[0] = Math.max(0, sizes[0] - start);
  const last = sizes.length - 1;
  sizes[last] = Math.max(0, sizes[last] - end);
}

/**
 * A subgrid's own gutter decides how far apart its adopted tracks sit, and the parent sized those
 * tracks for the parent's gutter: the difference between the two comes out of the tracks it sits
 * between, half from each, so the tracks still add up to the box the subgrid was given. A track
 * between two gutters gives up a whole difference and an end track half of one, which is what
 * Chrome lays out: 100px rows either side of a 50px gutter over the parent's 0 become 75, 50, 75
 * of 100, 100, 100. The gap that comes back with the tracks is the one to lay them out with,
 * which a gutter too wide to fit shrinks.
 */
function refitGap(sizes: number[], gap: number, adopted: number): [number[], number] {
  const n = sizes.length;
  if (n < 2 || gap === adopted) return [sizes, gap];
  let area = adopted * (n - 1);
  for (const s of sizes) area += s;
  const half = (gap - adopted) / 2;
  if (half !== 0) {
    for (let i = 0; i < n; i++) {
      const share = i === 0 || i === n - 1 ? half : half * 2;
      sizes[i] = Math.max(0, sizes[i] - share);
    }
  }
  // A gutter wider than the box the subgrid was given cannot be laid out at all: the tracks come
  // out at nothing, so the gap gives way in equal shares and the items still fit inside the box
  // (a gutter that fits leaves the overflow to the tracks, as Chrome does).
  if (gap * (n - 1) > area) gap = Math.max(0, area / (n - 1));
  return [sizes, gap];
}

/**
 * The tracks a subgrid adopted from its parent, with the line names its own template wrote after
 * `subgrid`: each bracket group names the next line, so the first group names line 1.
 */
function adoptedTracks(sizes: number[], nameRow: number): Track[] {
  const tracks = pxTracks(sizes);
  const groups = trackNameGroups(nameRow);
  for (let i = 0; i < tracks.length; i++) {
    const names = groups[i];
    if (names !== undefined && names.length > 0) tracks[i].names = names;
  }
  return tracks;
}

/** A track list made of the px sizes a subgrid adopted from its parent. */
function pxTracks(sizes: number[]): Track[] {
  return sizes.map((s) => ({
    min: { kind: P.GT_LEN, v: s, u: P.U_PX },
    max: { kind: P.GT_LEN, v: s, u: P.U_PX },
  }));
}

export function layoutGrid(el: Node, innerW: number, innerH: number, pl: number, pt: number): number {
  const items = orderedItems(el);
  // What the items ask of the columns, which a parent that subgrids its columns reads back once
  // this layout is done. Cleared first so a grid with no items leaves nothing behind.
  el.gridColMin = [];
  el.gridColMax = [];
  el.gridColAuto = [];
  // A right-to-left direction turns the inline axis around, and the columns are that axis: right
  // to left in a horizontal grid, bottom to top in a vertical one.
  const rtl = inlineMirrored(el);
  // A subgrid adopts the tracks its parent gave it in the subgridded axis, with the parent's
  // gutter where the subgrid leaves `gap` at its initial value (CSS Grid 2, subgrids).
  const subCol = el.su[P.P_GRID_TEMPLATE_COLUMNS] === P.U_SUBGRID && el.sgColSet;
  const subRow = el.su[P.P_GRID_TEMPLATE_ROWS] === P.U_SUBGRID && el.sgRowSet;
  let colGap = zeroIfNaN(len(el, P.P_COLUMN_GAP, innerW));
  // A subgrid's gutter lines up with its parent's; the initial value is what asks for that.
  if (subCol && el.su[P.P_COLUMN_GAP] === P.U_NORMAL) colGap = el.sgColGap;
  // The row gap's percentage needs a height to resolve against: the container's own when it has
  // one, and otherwise the height the rows add up to, which leaves the percentage out. A subgrid
  // is the exception: its rows fill the box its parent gave it, so the height the adopted tracks
  // and the parent's gutters add up to is the one its percentage takes its share of.
  let rowBase = innerH;
  if (Number.isNaN(rowBase) && subRow) {
    rowBase = el.sgRowGap * Math.max(0, el.sgRows.length - 1);
    for (const s of el.sgRows) rowBase += s;
  }
  let rowGap = zeroIfNaN(len(el, P.P_ROW_GAP, Number.isNaN(rowBase) ? 0 : rowBase));
  if (subRow && el.su[P.P_ROW_GAP] === P.U_NORMAL) rowGap = el.sgRowGap;
  // An auto-repeat fits as many copies into the content box as it can, so it is expanded once
  // the box's size, the gap and the items' contributions are known.
  const itemMin: number[] = [];
  const itemMax: number[] = [];
  for (const c of items) {
    itemMin.push(intrinsicMinWidth(c, innerW, NaN) + marginH(c, innerW));
    itemMax.push(intrinsicMaxWidth(c, innerW, NaN) + marginH(c, innerW));
  }
  const colFit = subCol ? refitGap(el.sgCols.slice(), colGap, el.sgColGap) : null;
  if (colFit !== null) colGap = colFit[1];
  el.gridColGapUsed = colGap;
  const colList = colFit !== null
    ? adoptedTracks(colFit[0], el.sv[P.P_GRID_TEMPLATE_COLUMNS])
    : trackList(el.sv[P.P_GRID_TEMPLATE_COLUMNS]) ?? [];
  const colExp = hasRepeat(colList)
    ? expandRepeats(el, colList, innerW, colGap, itemMin, itemMax)
    : { tracks: colList, fit: [] as boolean[] };
  const explicit = colExp.tracks;
  const rowFit = subRow ? refitGap(el.sgRows.slice(), rowGap, el.sgRowGap) : null;
  if (rowFit !== null) rowGap = rowFit[1];
  const rowList = rowFit !== null
    ? adoptedTracks(rowFit[0], el.sv[P.P_GRID_TEMPLATE_ROWS])
    : trackList(el.sv[P.P_GRID_TEMPLATE_ROWS]) ?? [];
  const rowExp = hasRepeat(rowList)
    ? expandRepeats(el, rowList, innerH, rowGap, itemMin.map(() => 0), itemMax.map(() => 0))
    : { tracks: rowList, fit: [] as boolean[] };
  const explicitRows = rowExp.tracks;
  const autoCols = autoTracks(el, P.P_GRID_AUTO_COLUMNS);
  const autoRows = autoTracks(el, P.P_GRID_AUTO_ROWS);
  const flow = el.sv[P.P_GRID_AUTO_FLOW];
  const column = flow === P.GF_COLUMN || flow === P.GF_COLUMN_DENSE;
  const dense = flow === P.GF_ROW_DENSE || flow === P.GF_COLUMN_DENSE;

  // An out-of-flow child can still name the lines it sits between, and that area sizes and
  // positions it, so a grid that holds nothing else keeps the tracks it names.
  let hasOof = false;
  for (const k of boxKids(el)) {
    if (display(k) !== P.D_NONE && isOutOfFlow(k)) hasOof = true;
  }
  if (items.length === 0 && !hasOof) {
    // No items: the explicit tracks still take the room they name.
    let h = 0;
    for (const t of explicitRows) {
      const f = fixedPx(t.max, el, innerH);
      if (!Number.isNaN(f)) h += f;
    }
    const boxH = Number.isNaN(innerH) ? h : innerH;
    placeOutOfFlow(el, innerW, boxH, pl, pt, () => ({ x: pl, y: pt, w: innerW, h: boxH }));
    markDescendantAreas(el, el, () => ({ x: pl, y: pt, w: innerW, h: boxH }));
    return h;
  }

  const namedAreas = areaList(el.sv[P.P_GRID_TEMPLATE_AREAS]);
  const colAx = axisOf(explicit, namedAreas, true);
  const rowAx = axisOf(explicitRows, namedAreas, false);
  const areas = areasOf(el, items, colAx, rowAx);
  autoPlace(areas, flowLines(areas, column ? rowAx.explicit : colAx.explicit, column), column, dense);

  // The grid's used size: the explicit tracks, and the implicit ones the placement reached
  // either side of them. A placement that names a line before the explicit grid adds tracks
  // there, which shift every index along.
  const shifted = shiftAreas(areas, colAx.explicit, rowAx.explicit);
  let cols = shifted.cols;
  let rows = shifted.rows;
  let colTracks = allTracks(explicit, autoCols, cols, shifted.colShift);
  let rowTracks = allTracks(explicitRows, autoRows, rows, shifted.rowShift);
  // An `auto-fit` copy no item lands in collapses away, its gutters with it (CSS Grid 7.2.3.1).
  let colLineMap: number[] | null = null;
  if (colExp.fit.some((f) => f)) {
    const collapsed = collapseEmpty(colTracks, areas, (i) => {
      const k = i - shifted.colShift;
      return k >= 0 && k < colExp.fit.length && colExp.fit[k];
    }, "col");
    colTracks = collapsed.tracks;
    colLineMap = collapsed.lineMap;
    cols = colTracks.length;
  }
  let rowLineMap: number[] | null = null;
  if (rowExp.fit.some((f) => f)) {
    const collapsed = collapseEmpty(rowTracks, areas, (i) => {
      const k = i - shifted.rowShift;
      return k >= 0 && k < rowExp.fit.length && rowExp.fit[k];
    }, "row");
    rowTracks = collapsed.tracks;
    rowLineMap = collapsed.lineMap;
    rows = rowTracks.length;
  }
  // An auto-flowing grid whose template names no columns at all gets one per item.
  if (cols === 0) {
    cols = 1;
    colTracks.push(autoCols[0]);
    for (const a of areas) a.col = 0;
  }
  if (rows === 0) {
    rows = 1;
    rowTracks.push(autoRows[0]);
    for (const a of areas) a.row = 0;
  }

  // The rows a fixed track names are definite before any item is measured, so an item that sits
  // in them resolves a percentage height (and a preferred aspect ratio) against its grid area.
  const rowFixed: number[] = [];
  for (const t of rowTracks) rowFixed.push(fixedPx(t.max, el, innerH));
  // A flexible row's share of a definite height is known before the items are measured, so an
  // item that sits in one resolves a percentage height against that share rather than against the
  // whole of the container, which would make the row as tall as the item asks for.
  const frBasis = ((): number => {
    if (Number.isNaN(innerH)) return NaN;
    let fixedH = rowGap * Math.max(0, rows - 1);
    let frTotal = 0;
    for (let i = 0; i < rows; i++) {
      const t = rowTracks[i];
      if (t.max.kind === P.GT_FR) frTotal += t.max.v;
      else if (Number.isNaN(rowFixed[i])) return NaN;
      else fixedH += rowFixed[i];
    }
    if (frTotal <= 0) return NaN;
    return Math.max(0, innerH - fixedH) / frTotal;
  })();
  const areaBasisH = (a: Area): number => {
    const d = definiteAreaHeight(rowFixed, rowGap, a);
    if (!Number.isNaN(d)) return d;
    // A row that isn't flexible has no share: the percentage stays unresolved.
    if (Number.isNaN(frBasis)) return NaN;
    let h = rowGap * Math.max(0, a.rowSpan - 1);
    for (let k = 0; k < a.rowSpan; k++) {
      const t = rowTracks[a.row + k];
      if (t.max.kind !== P.GT_FR) return NaN;
      h += frBasis * t.max.v;
    }
    return h;
  };

  // Content contributions per column: an item spanning one column gives it its own min-content
  // and max-content widths; one spanning several shares what is left across the spanned tracks
  // that take their size from content. `basisH` is the height of the item's area, which is what a
  // percentage height inside it resolves against.
  // An item spanning several columns, one of them flexible, has an automatic minimum size of
  // zero: its content asks for no room of its own, the flexible columns giving it what they can
  // (CSS Grid 6.6).
  const zeroMin = (c: Node, a: Area): boolean => {
    if (a.colSpan < 2 || sizeUnit(c, P.P_WIDTH) !== P.U_AUTO || sizeUnit(c, P.P_MIN_WIDTH) !== P.U_AUTO) return false;
    for (let k = 0; k < a.colSpan; k++) if (colTracks[a.col + k].max.kind === P.GT_FR) return true;
    return false;
  };
  // The smallest outer size an item whose width comes from its content can take in the columns it
  // spans: a specified min-width replaces its automatic minimum size, and when every column it
  // spans has a fixed maximum the content is capped by the stretch fit into them — so a
  // `minmax(auto, 0)` column takes no room and its items overflow it (CSS Grid 6.6, 12.5.1).
  const stretchFitW = (a: Area): number => {
    let sum = colGap * Math.max(0, a.colSpan - 1);
    for (let k = 0; k < a.colSpan; k++) {
      const f = fixedPx(colTracks[a.col + k].max, el, innerW);
      if (Number.isNaN(f)) return INF;
      sum += f;
    }
    return sum;
  };
  const autoMinW = (c: Node, a: Area, inner: number): number => {
    const auto = sizeUnit(c, P.P_WIDTH) === P.U_AUTO || sizeUnit(c, P.P_WIDTH) === P.U_PCT;
    const given = sizeUnit(c, P.P_MIN_WIDTH) !== P.U_AUTO ? len(c, P.P_MIN_WIDTH, innerW) : NaN;
    // An item that scrolls in the inline axis takes no minimum size from its content: its
    // overflowing content doesn't widen it (CSS Grid 6.6).
    const w = !auto ? inner : !Number.isNaN(given) ? Math.max(0, given)
      : scriptScrollsX(c) ? 0 : Math.min(inner, stretchFitW(a));
    return w + marginH(c, innerW);
  };
  const contributions = (basisH: (a: Area) => number): { minC: number[]; maxC: number[]; autoC: number[] } => {
    const minC: number[] = [];
    const maxC: number[] = [];
    const autoC: number[] = [];
    for (let i = 0; i < cols; i++) {
      minC.push(0);
      maxC.push(0);
      autoC.push(0);
    }
    for (let i = 0; i < items.length; i++) {
      const c = items[i];
      const a = areas[i];
      const stretchedW = stretchRatioWidth(el, c, basisH(a), innerW);
      // A percentage on the item is cyclic here — it resolves against the area the track makes —
      // so the contribution is the item's content's own size (CSS Sizing 5.2).
      const inner = zeroMin(c, a) ? stretchedW
        : Math.max(stretchedW, intrinsicMinWidth(c, innerW, basisH(a)));
      const mn = inner + marginH(c, innerW);
      const an = zeroMin(c, a) ? mn : autoMinW(c, a, inner);
      const mx = Math.max(stretchedW, intrinsicMaxWidth(c, innerW, basisH(a))) + marginH(c, innerW);
      if (a.colSpan === 1) {
        minC[a.col] = Math.max(minC[a.col], mn);
        maxC[a.col] = Math.max(maxC[a.col], mx);
        autoC[a.col] = Math.max(autoC[a.col], an);
      } else {
        // A column-subgrid asks its parent's columns for the room its own columns' items need
        // (CSS Grid 2 §9); its box width is no contribution of its own, since the columns it
        // adopts already give it one.
        const sg = columnSubgrid(c, a, colGap, innerW);
        let fixedAndGaps = colGap * (a.colSpan - 1);
        const growable: number[] = [];
        for (let k = 0; k < a.colSpan; k++) {
          const t = colTracks[a.col + k];
          const f = fixedPx(t.max, el, innerW);
          if (Number.isNaN(f)) growable.push(a.col + k);
          else fixedAndGaps += f;
        }
        if (sg !== null) {
          for (const j of growable) {
            const k = j - a.col;
            minC[j] = Math.max(minC[j], sg[0][k]);
            maxC[j] = Math.max(maxC[j], sg[1][k]);
            autoC[j] = Math.max(autoC[j], sg[2][k]);
          }
        } else if (growable.length > 0) {
          const eachMin = Math.max(0, mn - fixedAndGaps) / growable.length;
          const eachAuto = Math.max(0, an - fixedAndGaps) / growable.length;
          const eachMax = Math.max(0, mx - fixedAndGaps) / growable.length;
          for (const k of growable) {
            minC[k] = Math.max(minC[k], eachMin);
            maxC[k] = Math.max(maxC[k], eachMax);
            autoC[k] = Math.max(autoC[k], eachAuto);
          }
        }
      }
    }
    return { minC, maxC, autoC };
  };
  // justify-content: `normal` (and `stretch`) grows the auto tracks; the packings move the set.
  const jc = contentMode(el, el.sv[P.P_JUSTIFY_CONTENT]);
  const stretchCols = jc === P.J_NORMAL;
  let contrib = contributions(areaBasisH);
  el.gridColMin = contrib.minC;
  el.gridColMax = contrib.maxC;
  el.gridColAuto = contrib.autoC;
  let colSizes = sizeTracks(el, colTracks, innerW, colGap, contrib.minC, contrib.maxC, stretchCols, false, contrib.autoC);
  // The width of an item's area, from the column sizes known so far.
  const areaWidth = (a: Area): number => {
    let w = colGap * (a.colSpan - 1);
    for (let k = 0; k < a.colSpan; k++) w += colSizes[a.col + k];
    return w;
  };

  // Rows: fixed tracks keep their length; the rest take the height of the items in them. An
  // item is measured against the width of the columns it spans, which is its grid area.
  // A row takes its base size from its items unless its minimum sizing function is a length of
  // its own: the maximum a fixed track names is only where the row stops growing, and the room a
  // percentage height inside the row resolves against.
  const rowAuto: boolean[] = [];
  for (const t of rowTracks) {
    rowAuto.push(Number.isNaN(fixedPx(t.min, el, Number.isNaN(innerH) ? NaN : innerH)));
  }
  const rowNeed: number[] = [];
  const rowMin: number[] = [];
  for (let i = 0; i < rows; i++) {
    rowNeed.push(0);
    rowMin.push(0);
  }
  // The stretch fit into the rows an item spans: the room their fixed maximums give it, or
  // nothing to cap by when one of them isn't fixed (CSS Grid 12.5.1).
  const stretchFitH = (a: Area): number => {
    let sum = rowGap * Math.max(0, a.rowSpan - 1);
    for (let k = 0; k < a.rowSpan; k++) {
      const t = rowTracks[a.row + k];
      const f = t.max.kind === P.GT_FR ? NaN : fixedPx(t.max, el, innerH);
      if (Number.isNaN(f)) return INF;
      sum += f;
    }
    return sum;
  };
  // An item has an automatic minimum size only when it spans a row whose minimum is `auto`, and
  // one spanning several rows has none when one of them is flexible (CSS Grid 6.6).
  const autoMinApplies = (a: Area): boolean => {
    let auto = false;
    for (let k = 0; k < a.rowSpan; k++) {
      const t = rowTracks[a.row + k];
      if (t.min.kind === P.GT_AUTO) auto = true;
      if (a.rowSpan > 1 && t.max.kind === P.GT_FR) return false;
    }
    return auto;
  };
  const stretched = (c: Node): boolean => {
    const j = justifyMode(el, c);
    return j === P.A_STRETCH && sizeUnit(c, P.P_WIDTH) === P.U_AUTO &&
      sizeUnit(c, P.P_MARGIN_LEFT) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_RIGHT) !== P.U_AUTO;
  };
  // A row whose items are aligned on a baseline is as tall as the furthest of them above that
  // baseline plus the deepest of them below it, which is not always the tallest item's height.
  const rowFirstTop: number[] = [];
  const rowFirstBottom: number[] = [];
  const rowLastTop: number[] = [];
  const rowLastBottom: number[] = [];
  // The height each item has where its percentage height has nothing to resolve against — the
  // row's own size, which is what the row is being sized from — and whether it has one at all.
  const autoH: number[] = [];
  const cycH: boolean[] = [];
  // A span reaches across rows that are already sized: it only asks for what they lack. A row
  // with a fixed maximum stops growing there, so it takes no content contribution — but its
  // items still count towards the fraction a flexible row is worth, and towards the base of a
  // row whose minimum is `auto`, which has no fixed minimum to stop at.
  const put = (arr: number[], a: Area, n: number, growable: (r: number) => boolean): void => {
    if (a.rowSpan === 1) {
      if (growable(a.row)) arr[a.row] = Math.max(arr[a.row], n);
      return;
    }
    let have = rowGap * (a.rowSpan - 1);
    let count = 0;
    for (let k = 0; k < a.rowSpan; k++) {
      const r = a.row + k;
      if (growable(r)) count++;
      // A row whose size is not a fixed length gives the span nothing yet.
      else if (!Number.isNaN(rowFixed[r])) have += rowFixed[r];
    }
    const each = count > 0 ? Math.max(0, n - have) / count : 0;
    for (let k = 0; k < a.rowSpan; k++) if (growable(a.row + k)) arr[a.row + k] = Math.max(arr[a.row + k], each);
  };
  for (let i = 0; i < rows; i++) {
    rowFirstTop.push(-1);
    rowFirstBottom.push(-1);
    rowLastTop.push(-1);
    rowLastBottom.push(-1);
  }
  for (let i = 0; i < items.length; i++) {
    const c = items[i];
    const a = areas[i];
    const w = areaWidth(a);
    // An item that doesn't stretch and has an automatic width is as wide as its content, up to
    // the room its area gives it: its inline size behaves as fit-content (CSS Grid 6.6).
    const fit = !stretched(c) && sizeUnit(c, P.P_WIDTH) === P.U_AUTO && aspectRatio(c) <= 0;
    // A stretched item takes the area's width, clamped by its own min/max-width — the same size
    // it gets when it is laid out for placement, so the height measured here is the one it takes.
    adoptTracks(colSizes, colGap, c, a, null, rowGap);
    layoutBox(c, Math.max(0, w), areaBasisH(a),
      stretched(c) ? clampW(c, Math.max(0, w - marginH(c, w)), w) : NaN, NaN, fit);
    const need = c.h + marginV(c, w);
    // A percentage height resolves against the row's own size, which is what the row is being
    // sized from here, so the item is measured as its content makes it.
    const cyc = sizeUnit(c, P.P_HEIGHT) === P.U_PCT && Number.isNaN(areaBasisH(a));
    const am = alignMode(el, c);
    const baseline = am === P.A_BASELINE || am === P.A_LAST_BASELINE;
    // A box with no baseline of its own synthesizes one from its end edge — a size it doesn't
    // have yet — and so sits the group out entirely (CSS Grid 11.5, CSS Align 9.2).
    autoH[i] = c.h;
    cycH[i] = cyc;
    const lastKind = am === P.A_LAST_BASELINE;
    const synth = cyc && natBaseFor(el, c, lastKind) < 0;
    // Auto margins take the free space, so a baseline item with one is not in the group.
    if (baseline && !synth && a.rowSpan === 1 && rowAuto[a.row] &&
      sizeUnit(c, P.P_MARGIN_TOP) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_BOTTOM) !== P.U_AUTO) {
      const [mt, mb] = blockMargins(el, c, w);
      const b = itemBaseFor(el, c, lastKind);
      const top = mt + b;
      const bottom = c.h - b + mb;
      if (!baseSide(el, c, lastKind)) {
        rowFirstTop[a.row] = Math.max(rowFirstTop[a.row], top);
        rowFirstBottom[a.row] = Math.max(rowFirstBottom[a.row], bottom);
      } else {
        rowLastTop[a.row] = Math.max(rowLastTop[a.row], top);
        rowLastBottom[a.row] = Math.max(rowLastBottom[a.row], bottom);
      }
    }
    // A row-subgrid contributes its own rows to the rows it spans, not its box's height: a
    // subgrid whose rows are 15 and 15 with a 40px bottom border over five parent rows sizes them
    // 15, 15, 0, 0, 40 (CSS Grid 2 §9).
    const sg = subgridRows(c, a, rowGap);
    if (sg !== null) {
      for (let k = 0; k < a.rowSpan; k++) {
        const r = a.row + k;
        if (!Number.isNaN(rowFixed[r])) rowNeed[r] = Math.max(rowNeed[r], sg[k]);
      }
    } else put(rowNeed, a, need, (r) => Number.isNaN(rowFixed[r]));
  }
  // The base size of an `auto`-minimum row comes from its items' minimum contributions, which
  // include the baseline shim — the distance between the item's baseline and the one its row's
  // group shares — and which the row's fixed maximum caps, but never below the item's own border,
  // padding and shim (CSS Grid 6.6, 11.5, 12.5.1).
  for (let i = 0; i < items.length; i++) {
    const c = items[i];
    const a = areas[i];
    const w = areaWidth(a);
    const margins = marginV(c, w);
    const cyc = sizeUnit(c, P.P_HEIGHT) === P.U_PCT && Number.isNaN(areaBasisH(a));
    const auto = sizeUnit(c, P.P_HEIGHT) === P.U_AUTO || cyc;
    const am = alignMode(el, c);
    let shim = 0;
    if (a.rowSpan === 1 && rowAuto[a.row]) {
      const last = am === P.A_LAST_BASELINE;
      const synth = cyc && natBaseFor(el, c, last) < 0;
      if ((am === P.A_BASELINE || last) && !synth &&
        sizeUnit(c, P.P_MARGIN_TOP) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_BOTTOM) !== P.U_AUTO) {
        const [mt, mb] = blockMargins(el, c, w);
        const b = itemBaseFor(el, c, last);
        // The shim is added on the start side for a first baseline and on the end side for a
        // last one, so it moves the item's contribution out to the group's baseline.
        const side = baseSide(el, c, last);
        shim = Math.max(0, side ? rowLastBottom[a.row] - (c.h - b + mb) : rowFirstTop[a.row] - (mt + b));
      }
    }
    let minNeed: number;
    if (!auto) minNeed = c.h + margins + shim;
    else {
      // A percentage min-height resolves against the item's area height, and an area whose row
      // has no definite height leaves it unresolved, so the content's own minimum applies.
      const given = sizeUnit(c, P.P_MIN_HEIGHT) !== P.U_AUTO ? len(c, P.P_MIN_HEIGHT, areaBasisH(a)) : NaN;
      // A minimum size the author states names the item's content box, so the row is asked for that
      // size with the item's padding and borders around it — the outer size it can't go below
      // (CSS Grid 6.6, CSS Box Sizing 3).
      const around = c.sv[P.P_BOX_SIZING] === P.BS_BORDER ? 0 : padV(c, w);
      // An item that scrolls in the block axis takes no minimum size from its content either.
      if (!Number.isNaN(given)) minNeed = margins + Math.max(0, given + around);
      else if (autoMinApplies(a) && !scriptScrollsY(c)) {
        const border = margins + padV(c, w) + shim;
        minNeed = margins + Math.min(c.h + shim, Math.max(stretchFitH(a), border));
      } else minNeed = margins + shim;
    }
    const sgm = subgridRows(c, a, rowGap);
    if (sgm !== null) {
      for (let k = 0; k < a.rowSpan; k++) {
        const r = a.row + k;
        if (rowAuto[r]) rowMin[r] = Math.max(rowMin[r], sgm[k]);
      }
    } else put(rowMin, a, minNeed, (r) => rowAuto[r]);
  }
  for (let r = 0; r < rows; r++) {
    if (!rowAuto[r]) continue;
    // A baseline group's extent is the room its items ask for: the furthest above the shared
    // baseline plus the deepest below it. The shim each item's minimum contribution carries
    // already accounts for the baseline it sits on.
    if (rowFirstTop[r] >= 0) rowNeed[r] = Math.max(rowNeed[r], rowFirstTop[r] + rowFirstBottom[r]);
    if (rowLastTop[r] >= 0) rowNeed[r] = Math.max(rowNeed[r], rowLastTop[r] + rowLastBottom[r]);
  }
  // The row sizing algorithm: a row's base size comes from its own minimum sizing function or
  // from the items' contributions, its growth limit from its maximum, and a definite height of
  // the container caps how far the rows reach, an `fr` row taking what the others leave.
  const ac = contentEdge(el.sv[P.P_ALIGN_CONTENT]);
  const rowSizes = sizeTracks(el, rowTracks, Number.isNaN(innerH) ? NaN : innerH, rowGap, rowNeed, rowNeed,
    ac === P.AC_STRETCH, false, rowMin);
  el.gridUsedRows = rowSizes;
  // A row's percentage resolves against the height the container has; with no height of its own
  // the container is as tall as its rows add up to, and the percentage takes its share of that.
  let contentH = rowGap * Math.max(0, rows - 1);
  for (const s of rowSizes) contentH += s;
  const rowBasis = Number.isNaN(innerH) ? contentH : innerH;
  if (Number.isNaN(innerH)) {
    for (let i = 0; i < rows; i++) {
      const f = fixedPx(rowTracks[i].max, el, rowBasis);
      // A maximum is where the row stops growing, not a size it shrinks to: a row whose items ask
      // for more than the maximum keeps the size they give it, as the growth limit does
      // (CSS Grid 12.5, 12.6).
      if (!Number.isNaN(f)) rowSizes[i] = Math.max(rowSizes[i], Math.max(0, f));
    }
    // A flexible row's share of the height the rows took is resolved again against that height:
    // two `0.4fr` rows around a 100px item are 40 each, making the grid 80 tall, and then 32 each.
    if (rows > 0 && rowTracks.some((t) => t.max.kind === P.GT_FR)) {
      const again = sizeTracks(el, rowTracks, rowBasis, rowGap, rowNeed, rowNeed, false, false, rowMin);
      for (let i = 0; i < rows; i++) rowSizes[i] = again[i];
    }
    // The container is as tall as its rows' intrinsic sizes, so a percentage row that resolved
    // to less room than it took there leaves space the auto rows stretch into (CSS Grid 12.8;
    // `normal`, a grid's initial alignment, is the stretch).
    if (ac === P.AC_STRETCH) {
      let used = rowGap * Math.max(0, rows - 1);
      for (const s of rowSizes) used += s;
      const left = rowBasis - used;
      const autoRows: number[] = [];
      for (let i = 0; i < rows; i++) if (rowTracks[i].max.kind === P.GT_AUTO) autoRows.push(i);
      if (left > 0.0001 && autoRows.length > 0) {
        const share = left / autoRows.length;
        for (const i of autoRows) rowSizes[i] += share;
      }
    }
  }
  // The items' min-content and max-content contributions can have changed now that their rows
  // have their sizes — a percentage height inside one resolves, and so does an aspect ratio — so
  // the columns are resolved once more with the area heights the rows give them (CSS Grid 12.5).
  const usedAreaH = (a: Area): number => {
    let h = rowGap * Math.max(0, a.rowSpan - 1);
    for (let k = 0; k < a.rowSpan; k++) h += rowSizes[a.row + k];
    return h;
  };
  contrib = contributions(usedAreaH);
  el.gridColMin = contrib.minC;
  el.gridColMax = contrib.maxC;
  el.gridColAuto = contrib.autoC;
  colSizes = sizeTracks(el, colTracks, innerW, colGap, contrib.minC, contrib.maxC, stretchCols, false, contrib.autoC);
  el.gridUsedCols = colSizes;
  // justify-content moves the track set across the container's width.
  let colFree = innerW - colGap * Math.max(0, cols - 1);
  for (const s2 of colSizes) colFree -= s2;
  const [colLead, colExtra] = jc === P.J_NORMAL ? [0, 0] : distribute(jc, colFree, cols, el.su[P.P_JUSTIFY_CONTENT] === P.U_SAFE);
  // Where each column starts.
  const colX: number[] = [];
  let x = colLead;
  for (let i = 0; i < cols; i++) {
    colX.push(x);
    x += colSizes[i] + colGap + colExtra;
  }
  const spanW = (a: Area): number => {
    let w = (colGap + colExtra) * (a.colSpan - 1);
    for (let k = 0; k < a.colSpan; k++) w += colSizes[a.col + k];
    return w;
  };
  // A packing of align-content moves the row set across the container's height; `stretch`, which
  // is what `normal` means for a grid, has already grown the auto rows in the sizing step.
  let rowLead = 0;
  let rowExtra = 0;
  {
    let used = rowGap * Math.max(0, rows - 1);
    for (const s of rowSizes) used += s;
    const left = rowBasis - used;
    if (ac !== P.AC_STRETCH) {
      const [lead, extra] = distribute(ac, left, rows, el.su[P.P_ALIGN_CONTENT] === P.U_SAFE);
      rowLead = lead;
      rowExtra = extra;
    }
  }
  // The height the rows add up to, and the basis the row gap's percentage resolves against, so
  // the percentage leaves it out. A container with no height of its own keeps the intrinsic
  // height its percentage rows resolved against, taller than the rows once they shrank.
  if (!Number.isNaN(innerH)) {
    contentH = rowGap * Math.max(0, rows - 1);
    for (const s of rowSizes) contentH += s;
  }
  if (Number.isNaN(innerH) && !subRow) rowGap = zeroIfNaN(len(el, P.P_ROW_GAP, rowBasis));
  const rowY: number[] = [];
  let y = rowLead;
  for (let i = 0; i < rows; i++) {
    rowY.push(y);
    y += rowSizes[i] + rowGap + rowExtra;
  }
  const spanH = (a: Area): number => {
    let h = (rowGap + rowExtra) * (a.rowSpan - 1);
    for (let k = 0; k < a.rowSpan; k++) h += rowSizes[a.row + k];
    return h;
  };

  // Lay the items out in their areas, stretching them when their alignment asks for it.
  const cells: Cell[] = [];
  for (let i = 0; i < items.length; i++) {
    const c = items[i];
    const a = areas[i];
    const w = Math.max(0, spanW(a));
    const h = Math.max(0, spanH(a));
    const mh = marginH(c, w);
    const mv = marginV(c, w);
    const canStretchW = stretched(c);
    const am = alignMode(el, c);
    const canStretchH = am === P.A_STRETCH && sizeUnit(c, P.P_HEIGHT) === P.U_AUTO &&
      sizeUnit(c, P.P_MARGIN_TOP) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_BOTTOM) !== P.U_AUTO;
    // The area's height is definite, so a percentage height inside the item resolves against it.
    // A width that follows the item's own ratio is left for the box to work out from its height.
    const ratioW = aspectRatio(c) > 0 && sizeUnit(c, P.P_WIDTH) === P.U_AUTO;
    const fixedW = canStretchW ? clampW(c, Math.max(0, w - mh), w) : ratioW ? NaN : c.w;
    // A width of its own is used as it is; an automatic one shrinks to fit the item's content.
    const fitW = !canStretchW && !ratioW && sizeUnit(c, P.P_WIDTH) === P.U_AUTO;
    const fixedH = canStretchH ? clampH(c, Math.max(0, h - mv), w, h) : NaN;
    // The area is the item's containing block: a percentage height inside it resolves against
    // the row (or rows) it spans.
    adoptTracks(colSizes, colGap, c, a, rowSizes, rowGap);
    layoutBox(c, w, h, fixedW, fixedH, fitW);
    const ml = sizeUnit(c, P.P_MARGIN_LEFT) === P.U_AUTO ? 0 : zeroIfNaN(len(c, P.P_MARGIN_LEFT, w));
    const mr = sizeUnit(c, P.P_MARGIN_RIGHT) === P.U_AUTO ? 0 : zeroIfNaN(len(c, P.P_MARGIN_RIGHT, w));
    const [mt, mb] = blockMargins(el, c, w);
    cells.push({ c, a, w, h, ml, mr, mt, mb, mode: am, autoH: autoH[i], cyc: cycH[i] });
  }
  // The items of a row aligned on a baseline share the row's: the group's baseline sits as far
  // down as the furthest of them reaches above it, and the group reaches as far below it as the
  // deepest one. `last baseline` reads the row from its end instead (CSS Align 9.2-9.3). A box
  // spanning tracks joins the group of the track it starts in, or of the one it ends in.
  const groupFirstTop: number[] = [];
  const groupFirstBottom: number[] = [];
  const groupLastTop: number[] = [];
  const groupLastBottom: number[] = [];
  for (let r = 0; r < rows; r++) {
    groupFirstTop.push(-1);
    groupFirstBottom.push(-1);
    groupLastTop.push(-1);
    groupLastBottom.push(-1);
  }
  for (const k of cells) {
    const last = k.mode === P.A_LAST_BASELINE;
    if (k.mode !== P.A_BASELINE && !last) continue;
    if (sizeUnit(k.c, P.P_MARGIN_TOP) === P.U_AUTO || sizeUnit(k.c, P.P_MARGIN_BOTTOM) === P.U_AUTO) continue;
    // A percentage height took the item's content's size while the row was sized, so its extents
    // are those; and a box with no baseline of its own, which would synthesize one from a size it
    // doesn't have yet, is not in the group at all.
    // The side the item lines up on, which is the other one when its block flow runs the other
    // way, and the baseline it supplies for that side.
    const side = baseSide(el, k.c, last);
    let b: number;
    let ch: number;
    if (k.cyc) {
      const nat = natBaseFor(el, k.c, last);
      if (nat < 0) continue;
      b = nat;
      ch = k.autoH;
    } else {
      b = itemBaseFor(el, k.c, last);
      ch = k.c.h;
    }
    const r = side ? k.a.row + k.a.rowSpan - 1 : k.a.row;
    const top = k.mt + b;
    const bottom = ch - b + k.mb;
    if (side) {
      groupLastTop[r] = Math.max(groupLastTop[r], top);
      groupLastBottom[r] = Math.max(groupLastBottom[r], bottom);
    } else {
      groupFirstTop[r] = Math.max(groupFirstTop[r], top);
      groupFirstBottom[r] = Math.max(groupFirstBottom[r], bottom);
    }
  }
  // The items aligned on a baseline across the inline axis share one: the group starts as far
  // across as the furthest of them reaches before its baseline, and a `last baseline` group takes
  // the same measurement past it, since it is packed against the end of the axis (CSS Align
  // 9.2-9.3). The group reaches across every area, so its baseline is placed in each item's own.
  let groupFirstLeft = -1;
  let groupLastRight = -1;
  for (const k of cells) {
    const side = inlineBaseSide(el, k.c);
    if (side < 0) continue;
    // An inline-axis auto margin takes the free space, so there is none to line the item up in.
    if (sizeUnit(k.c, P.P_MARGIN_LEFT) === P.U_AUTO || sizeUnit(k.c, P.P_MARGIN_RIGHT) === P.U_AUTO) continue;
    const ib = inlineBaseFor(el, k.c);
    if (side === 1) groupLastRight = Math.max(groupLastRight, k.c.w - ib + (rtl ? k.ml : k.mr));
    else groupFirstLeft = Math.max(groupFirstLeft, (rtl ? k.mr : k.ml) + ib);
  }
  // Place the items in their areas.
  for (const k of cells) {
    const c = k.c;
    const a = k.a;
    const w = k.w;
    const h = k.h;
    const ml = k.ml;
    const mr = k.mr;
    const mt = k.mt;
    // Alignment sees the free space as it is, negative when the item overflows its area; auto
    // margins take none of a negative one.
    const alignW = w - c.w - ml - mr;
    const alignH = h - c.h - mt - k.mb;
    const freeW = Math.max(0, alignW);
    const freeH = Math.max(0, alignH);
    const autoL = sizeUnit(c, P.P_MARGIN_LEFT) === P.U_AUTO;
    const autoR = sizeUnit(c, P.P_MARGIN_RIGHT) === P.U_AUTO;
    const [, , autoT, autoB] = blockMargins(el, c, w);
    const side = autoL || autoR ? -1 : inlineBaseSide(el, c);
    let dx: number;
    if (autoL && autoR) dx = freeW / 2;
    else if (autoL) dx = freeW;
    else if (autoR) dx = 0;
    else if (side < 0) dx = alignOffset(justifyMode(el, c), alignW, justifySafe(el, c));
    else {
      // The item's baseline lands where the group's sits: at the start of its area, or as far
      // before the end of it as the deepest item in the group reaches past its baseline.
      const ib = inlineBaseFor(el, c);
      const im = rtl ? mr : ml;
      dx = Math.max(0, (side === 1 ? w - groupLastRight : groupFirstLeft) - im - ib);
    }
    let dy: number;
    if (autoT || autoB) {
      if (autoT && autoB) dy = freeH / 2;
      else if (autoT) dy = freeH;
      else dy = 0;
    } else if (k.mode === P.A_BASELINE || k.mode === P.A_LAST_BASELINE) {
      const last = k.mode === P.A_LAST_BASELINE;
      const side = baseSide(el, c, last);
      const b = itemBaseFor(el, c, last);
      // A box with no baseline of its own and a height still resolving against the row is left
      // out of the group, and so stays where the row starts.
      if (k.cyc && natBaseFor(el, c, last) < 0) dy = 0;
      else if (!side) dy = Math.max(0, groupFirstTop[a.row] - mt - b);
      else {
        const re = a.row + a.rowSpan - 1;
        const end = rowY[re] + rowSizes[re];
        dy = end - groupLastBottom[re] - b - (rowY[a.row] + mt);
      }
    } else {
      dy = alignOffset(k.mode, alignH, alignSafe(el, c));
    }
    // A right-to-left grid runs its inline axis the other way: the track set packs against the
    // right edge, and an alignment offset is measured from there.
    c.x = rtl ? pl + innerW - colX[a.col] - mr - c.w - dx
      : pl + colX[a.col] + ml + dx;
    c.y = pt + rowY[a.row] + mt + dy;
    place(c);
  }

  // A grid container's first baseline is the first baseline of the first item in its first row
  // that lines up on a baseline, in grid order — whichever side of it that item lines up on, it is
  // the item's own first baseline the container takes — or else the baseline of the row's first
  // item in grid order, synthesized from its border box when it has none of its own. Its last
  // baseline is its last row's by the same rule (CSS Grid 10.1). A min- or max-height can lay the
  // grid out again, so what the earlier pass reported is replaced rather than kept beside it.
  if (items.length > 0) {
    el.lineBaseline.length = 0;
    el.lineCentral.length = 0;
    let firstRow = areas[0].row;
    let lastRow = -1;
    for (const a of areas) {
      if (a.row < firstRow) firstRow = a.row;
      if (a.row + a.rowSpan - 1 > lastRow) lastRow = a.row + a.rowSpan - 1;
    }
    let firstIx = -1;
    let firstPartIx = -1;
    let lastIx = -1;
    let lastBase = NaN;
    for (let i = 0; i < items.length; i++) {
      const c = items[i];
      const a = areas[i];
      const noAuto = sizeUnit(c, P.P_MARGIN_TOP) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_BOTTOM) !== P.U_AUTO;
      const mode = alignMode(el, c);
      if (a.row === firstRow) {
        if (firstIx < 0 || a.col < areas[firstIx].col) firstIx = i;
        if (noAuto && (mode === P.A_BASELINE || mode === P.A_LAST_BASELINE) &&
          (firstPartIx < 0 || a.col < areas[firstPartIx].col)) firstPartIx = i;
      }
      if (a.row + a.rowSpan - 1 === lastRow) {
        if (lastIx < 0 || a.col + a.colSpan > areas[lastIx].col + areas[lastIx].colSpan) lastIx = i;
        if (noAuto && (mode === P.A_BASELINE || mode === P.A_LAST_BASELINE)) {
          const b = natBaseFor(el, c, mode === P.A_LAST_BASELINE);
          const at = c.y + (b >= 0 ? b : c.h);
          if (Number.isNaN(lastBase) || at > lastBase) lastBase = at;
        }
      }
    }
    let firstBase = NaN;
    if (firstPartIx >= 0) {
      const c = items[firstPartIx];
      const b = natBaseFor(el, c, false);
      firstBase = c.y + (b >= 0 ? b : c.h);
    }
    if (Number.isNaN(firstBase) && firstIx >= 0) {
      const c = items[firstIx];
      const b = naturalBaseline(c);
      firstBase = c.y + (b >= 0 ? b : c.h);
    }
    if (Number.isNaN(lastBase) && lastIx >= 0) {
      const c = items[lastIx];
      const b = naturalLastBaseline(c);
      lastBase = c.y + (b >= 0 ? b : c.h);
    }
    if (!Number.isNaN(firstBase)) el.lineBaseline.push(firstBase);
    if (!Number.isNaN(lastBase)) el.lineBaseline.push(lastBase);
  }
  // An out-of-flow box the grid is the containing block of takes the area its placement gives it
  // (CSS Grid 9.1). An auto side sits on the grid's padding edge, so a child with no placement at
  // all fills the padding box, as it would in a block container.
  const boxH = Number.isNaN(innerH) ? contentH : innerH;
  const padL = zeroIfNaN(len(el, P.P_PADDING_LEFT, innerW));
  const padR = zeroIfNaN(len(el, P.P_PADDING_RIGHT, innerW));
  const padT = zeroIfNaN(len(el, P.P_PADDING_TOP, innerW));
  const padB = zeroIfNaN(len(el, P.P_PADDING_BOTTOM, innerW));
  // An `auto-fit` repeat drops the copies no item lands in and renumbers the lines, but an
  // out-of-flow box names its area by the lines of the track list before that, so the line maps
  // fold them onto the tracks that survive (CSS Grid 9.1). A grid that also grew implicit tracks
  // before its explicit ones keeps the content box instead.
  const colMap = shifted.colShift === 0 ? colLineMap : null;
  const rowMap = shifted.rowShift === 0 ? rowLineMap : null;
  const unfit = (colExp.fit.some((f) => f) && colMap === null) || (rowExp.fit.some((f) => f) && rowMap === null);
  const oofArea = (c: Node): AreaRect => {
    if (unfit) return { x: pl, y: pt, w: innerW, h: boxH };
    const cx = oofExtent(c.sv[P.P_GRID_COLUMN_START], c.su[P.P_GRID_COLUMN_START],
      c.sv[P.P_GRID_COLUMN_END], c.su[P.P_GRID_COLUMN_END], colAx,
      colX, colSizes, shifted.colShift, -padL, innerW + padR, colMap);
    const ry = oofExtent(c.sv[P.P_GRID_ROW_START], c.su[P.P_GRID_ROW_START],
      c.sv[P.P_GRID_ROW_END], c.su[P.P_GRID_ROW_END], rowAx,
      rowY, rowSizes, shifted.rowShift, -padT, boxH + padB, rowMap);
    return { x: rtl ? pl + innerW - cx.b : pl + cx.a, y: pt + ry.a,
      w: Math.max(0, cx.b - cx.a), h: Math.max(0, ry.b - ry.a) };
  };
  placeOutOfFlow(el, innerW, boxH, pl, pt, oofArea);
  markDescendantAreas(el, el, oofArea);
  return contentH;
}


/**
 * Grid lanes (masonry) layout: the grid axis keeps normal tracks, and each item in order goes
 * into the least-filled lane it can span, advancing that lane by its own size (CSS Grid 3).
 * Column lanes stack items down the column tracks; row lanes run them along the row tracks.
 */
export function layoutGridLanes(el: Node, innerW: number, innerH: number, pl: number, pt: number): number {
  const items = orderedItems(el);
  const dirU = el.su[P.P_GRID_LANES_DIRECTION];
  const dirV = el.sv[P.P_GRID_LANES_DIRECTION];
  // A lanes container that is a subgrid itself takes the tracks its parent gave it, in the axis
  // that has tracks (CSS Grid 2, subgrids).
  const subCol = el.su[P.P_GRID_TEMPLATE_COLUMNS] === P.U_SUBGRID && el.sgColSet;
  const subRow = el.su[P.P_GRID_TEMPLATE_ROWS] === P.U_SUBGRID && el.sgRowSet;
  let colGap = zeroIfNaN(len(el, P.P_COLUMN_GAP, innerW));
  // A subgrid's rows fill the box its parent gave it, so its percentage row gap resolves against
  // the height the adopted tracks and the parent's gutters add up to (see layoutGrid).
  let rowBase = innerH;
  if (Number.isNaN(rowBase) && subRow) {
    rowBase = el.sgRowGap * Math.max(0, el.sgRows.length - 1);
    for (const s of el.sgRows) rowBase += s;
  }
  let rowGap = zeroIfNaN(len(el, P.P_ROW_GAP, Number.isNaN(rowBase) ? 0 : rowBase));
  // A subgrid's gutter lines up with its parent's where its own `gap` is the initial value.
  if (subCol && el.su[P.P_COLUMN_GAP] === P.U_NORMAL) colGap = el.sgColGap;
  if (subRow && el.su[P.P_ROW_GAP] === P.U_NORMAL) rowGap = el.sgRowGap;
  const colFit = subCol ? refitGap(el.sgCols.slice(), colGap, el.sgColGap) : null;
  if (colFit !== null) colGap = colFit[1];
  const colList = colFit !== null
    ? adoptedTracks(colFit[0], el.sv[P.P_GRID_TEMPLATE_COLUMNS])
    : trackList(el.sv[P.P_GRID_TEMPLATE_COLUMNS]) ?? [];
  const rowFit = subRow ? refitGap(el.sgRows.slice(), rowGap, el.sgRowGap) : null;
  if (rowFit !== null) rowGap = rowFit[1];
  const rowList = rowFit !== null
    ? adoptedTracks(rowFit[0], el.sv[P.P_GRID_TEMPLATE_ROWS])
    : trackList(el.sv[P.P_GRID_TEMPLATE_ROWS]) ?? [];
  // `normal` takes the axis from the template: row lanes only when just the rows name tracks.
  const rowLanes = dirU === P.U_AUTO ? colList.length === 0 && rowList.length > 0 : (dirV & P.GL_ROW) !== 0;
  const trackReverse = dirU !== P.U_AUTO && (dirV & P.GL_TRACK_REVERSE) !== 0;
  // fill-reverse stacks each lane from its end: items fill upward in a column lane and leftward in a
  // row lane, and the lane's content is packed against the container's end edge.
  const fillReverse = dirU !== P.U_AUTO && (dirV & P.GL_FILL_REVERSE) !== 0;
  const gap = rowLanes ? colGap : rowGap;       // between the items of one lane
  const trackGap = rowLanes ? rowGap : colGap;  // between the lanes themselves
  const trackAvail = rowLanes ? innerH : innerW;
  const list = rowLanes ? rowList : colList;
  const expanded = expandRepeats(el, list, trackAvail, trackGap, [], []);
  const explicit = expanded.tracks;
  const auto = autoTracks(el, rowLanes ? P.P_GRID_AUTO_ROWS : P.P_GRID_AUTO_COLUMNS);
  const ax = axisOf(explicit, null, !rowLanes);

  // Where each item asks to go in the grid axis: a sure line, or auto.
  interface Asking { c: Node; start: number; span: number }
  const asking: Asking[] = [];
  let laneCount = Math.max(1, explicit.length);
  for (const c of items) {
    const s = rowLanes
      ? startOf(c.sv[P.P_GRID_ROW_START], c.su[P.P_GRID_ROW_START], c.sv[P.P_GRID_ROW_END], c.su[P.P_GRID_ROW_END], ax)
      : startOf(c.sv[P.P_GRID_COLUMN_START], c.su[P.P_GRID_COLUMN_START], c.sv[P.P_GRID_COLUMN_END], c.su[P.P_GRID_COLUMN_END], ax);
    asking.push({ c, start: s.start, span: Math.max(1, s.span) });
    if (!Number.isNaN(s.start)) laneCount = Math.max(laneCount, s.start - 1 + s.span);
  }
  const lanes: Track[] = [];
  for (let i = 0; i < laneCount; i++) {
    if (i < explicit.length) lanes.push(explicit[i]);
    else lanes.push(auto[(i - explicit.length) % auto.length]);
  }

  // Track sizing: every auto-placed item contributes to every lane, since any lane may take it.
  const minC: number[] = [];
  const maxC: number[] = [];
  const autoMin: number[] = [];
  for (let i = 0; i < laneCount; i++) { minC.push(0); maxC.push(0); autoMin.push(0); }
  for (const a of asking) {
    const c = a.c;
    const mn = rowLanes ? 0 : intrinsicMinWidth(c, innerW, NaN) + marginH(c, innerW);
    const mx = rowLanes ? 0 : intrinsicMaxWidth(c, innerW, NaN) + marginH(c, innerW);
    for (let i = 0; i < laneCount; i++) {
      minC[i] = Math.max(minC[i], mn);
      maxC[i] = Math.max(maxC[i], mx);
      autoMin[i] = Math.max(autoMin[i], mn);
    }
  }
  if (rowLanes) {
    // A row lane's size comes from the block sizes of its items at the container's width.
    for (const a of asking) {
      layoutBox(a.c, innerW, NaN, NaN, NaN, true);
      const h = a.c.h + marginV(a.c, innerW);
      for (let i = 0; i < laneCount; i++) {
        minC[i] = Math.max(minC[i], h);
        maxC[i] = Math.max(maxC[i], h);
        autoMin[i] = Math.max(autoMin[i], h);
      }
    }
  }
  const jc = contentMode(el, el.sv[P.P_JUSTIFY_CONTENT]);
  const ac = contentEdge(el.sv[P.P_ALIGN_CONTENT]);
  const stretch = rowLanes ? ac === P.AC_STRETCH : jc === P.J_NORMAL;
  let sizes = sizeTracks(el, lanes, Number.isNaN(trackAvail) ? NaN : trackAvail, trackGap,
    minC, maxC, stretch, false, autoMin);
  if (rowLanes) el.gridUsedRows = sizes; else el.gridUsedCols = sizes;
  let total = trackGap * Math.max(0, laneCount - 1);
  for (const s of sizes) total += s;
  const avail = rowLanes ? innerH : innerW;
  const free = Number.isNaN(avail) ? 0 : avail - total;
  const pack = rowLanes ? ac : jc;
  const [lead, extra] = distribute(pack, free, laneCount, false);
  const laneAt: number[] = [];
  let at = lead;
  for (let i = 0; i < laneCount; i++) {
    laneAt.push(at);
    at += sizes[i] + trackGap + extra;
  }
  const spanSize = (start: number, span: number): number => {
    let s = trackGap * (span - 1);
    for (let k = 0; k < span; k++) s += sizes[start + k];
    return s;
  };

  // fit-tolerance: how close to the shortest lane another lane must be to count as tied.
  const ft = el.su[P.P_FIT_TOLERANCE];
  const tol = ft === P.U_NORMAL ? el.sv[P.P_FONT_SIZE]
    : ft === P.U_PX ? el.sv[P.P_FIT_TOLERANCE]
    : ft === P.U_PCT ? (el.sv[P.P_FIT_TOLERANCE] / 100) * (rowLanes ? innerW : (Number.isNaN(innerH) ? 0 : innerH))
    : ft === P.U_EM ? el.sv[P.P_FIT_TOLERANCE] * el.sv[P.P_FONT_SIZE]
    : ft === P.U_REM ? el.sv[P.P_FIT_TOLERANCE] * rootFontSize()
    : 0;
  const flow = el.sv[P.P_GRID_AUTO_FLOW];
  const dense = el.sv[P.P_GRID_LANES_PACK] !== 0 || flow === P.GF_ROW_DENSE || flow === P.GF_COLUMN_DENSE;

  // Running positions, one per lane, along the stacking axis.
  const running: number[] = [];
  for (let i = 0; i < laneCount; i++) running.push(0);
  let cursor = 0;
  // The room each lane's items take along the stacking axis. Dense packing looks for the start-most
  // opening between them; every other rule needs only the lane's end, `running`.
  const occupied: { s: number; e: number }[][] = [];
  for (let i = 0; i < laneCount; i++) occupied.push([]);
  // The earliest place an item `size` long on the stack fits across the lanes it spans.
  const openingAt = (st: number, span: number, size: number): number => {
    let y = 0;
    for (;;) {
      let hit = -1;
      for (let q = 0; q < span; q++) {
        for (const iv of occupied[st + q]) {
          if (y < iv.e && y + Math.max(0, size) > iv.s && iv.e > hit) hit = iv.e;
        }
      }
      if (hit < 0) return y;
      y = hit;
    }
  };
  const placed: { c: Node; start: number; span: number; pos: number; size: number }[] = [];
  for (let k = 0; k < asking.length; k++) {
    const a = asking[k];
    const c = a.c;
    const span = a.span;
    // The item's containing block: the lanes it spans across, its own content along the stack.
    const ml = zeroIfNaN(len(c, P.P_MARGIN_LEFT, innerW));
    const mr = zeroIfNaN(len(c, P.P_MARGIN_RIGHT, innerW));
    const mt = zeroIfNaN(len(c, P.P_MARGIN_TOP, innerW));
    const mb = zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, innerW));
    // How much room the item takes along the stack when it spans the lanes from `st`.
    const sizeAt = (st: number): number => {
      if (rowLanes) {
        layoutBox(c, innerW, sizes[st], NaN, NaN, sizeUnit(c, P.P_WIDTH) === P.U_AUTO && aspectRatio(c) <= 0);
        return c.w + ml + mr;
      }
      const w = spanSize(st, span);
      const stretched = justifyMode(el, c) === P.A_STRETCH && sizeUnit(c, P.P_WIDTH) === P.U_AUTO &&
        sizeUnit(c, P.P_MARGIN_LEFT) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_RIGHT) !== P.U_AUTO;
      layoutBox(c, w, NaN, stretched ? clampW(c, Math.max(0, w - ml - mr), w) : NaN, NaN,
        !stretched && sizeUnit(c, P.P_WIDTH) === P.U_AUTO);
      return c.h + mt + mb;
    };
    let start: number;
    let pos = 0;
    if (!Number.isNaN(a.start) && a.start >= 1 && a.start - 1 + span <= laneCount) {
      start = a.start - 1;
      if (dense) pos = openingAt(start, span, sizeAt(start));
    } else if (Number.isNaN(a.start)) {
      // The least-filled lane the item can span; ties within the tolerance go in the numbering's
      // order, which track-reverse runs from the end. With the numbering reversed, the lane the
      // cursor has passed is the one nearest the end, so every tie breaks toward the end.
      const posOf = (i: number): number => {
        let m = 0;
        for (let q = 0; q < span; q++) m = Math.max(m, running[i + q]);
        return m;
      };
      let autoStart = 0;
      let autoPos = 0;
      let best = Infinity;
      for (let i = 0; i + span <= laneCount; i++) best = Math.min(best, posOf(i));
      for (let q = 0; q + span <= laneCount; q++) {
        const i = trackReverse ? laneCount - span - q : q;
        if (posOf(i) <= best + tol) { autoStart = i; autoPos = posOf(i); break; }
      }
      if (dense) {
        // Dense packing takes the start-most opening that fits — a gap an earlier item left.
        let openStart = autoStart;
        let openY = Infinity;
        let bestY = Infinity;
        for (let q = 0; q + span <= laneCount; q++) {
          const i = trackReverse ? laneCount - span - q : q;
          bestY = Math.min(bestY, openingAt(i, span, sizeAt(i)));
        }
        for (let q = 0; q + span <= laneCount; q++) {
          const i = trackReverse ? laneCount - span - q : q;
          const y = openingAt(i, span, sizeAt(i));
          if (y <= bestY + tol) { openStart = i; openY = y; break; }
        }
        // Only when the opening is more than the fit-tolerance ahead of the place auto-placement
        // gives the item: a lane within the tolerance of that place counts as a tie, and the
        // numbering order then keeps the auto-placement lane. A reversed lane leads with the
        // margin on its end side, which can be negative, so its openings are taken as they come.
        if (fillReverse || openY < autoPos - tol) { start = openStart; pos = openY; }
        else { start = autoStart; pos = autoPos; }
      } else {
        let pick = -1;
        for (let q = 0; q + span <= laneCount && pick < 0; q++) {
          const i = trackReverse ? laneCount - span - q : q;
          if (posOf(i) > best + tol) continue;
          if (trackReverse || i >= cursor) pick = i;
        }
        if (pick < 0) for (let q = 0; q + span <= laneCount && pick < 0; q++) {
          const i = trackReverse ? laneCount - span - q : q;
          if (posOf(i) <= best + tol) pick = i;
        }
        start = pick < 0 ? 0 : pick;
        if (!trackReverse) cursor = start + span;
      }
    } else {
      // A line the grid doesn't have counts as auto; a span past the last lane clamps.
      start = Math.min(Math.max(0, a.start - 1), Math.max(0, laneCount - span));
      if (dense) pos = openingAt(start, span, sizeAt(start));
    }
    if (!dense) for (let q = 0; q < span; q++) pos = Math.max(pos, running[start + q]);

    let size: number;
    // A subgrid item takes the tracks this container gives it in the axis that has tracks, so
    // its own lines line up with the container's (CSS Grid 2, subgrids).
    if (rowLanes) {
      adoptTracks([], 0, c, { col: 0, colSpan: 1, row: start, rowSpan: span, autoCol: true, autoRow: false },
        sizes, trackGap);
    } else {
      adoptTracks(sizes, trackGap, c, { col: start, colSpan: span, row: 0, rowSpan: 1, autoCol: false, autoRow: true },
        null, 0);
    }
    if (rowLanes) {
      // The inline size comes from the content, up to the room the container has.
      const fit = sizeUnit(c, P.P_WIDTH) === P.U_AUTO && aspectRatio(c) <= 0;
      layoutBox(c, innerW, sizes[start], NaN, NaN, fit);
      size = c.w + ml + mr;
      c.y = pt + laneAt[start] + mt;
      c.x = pl + pos + ml;
    } else {
      const w = spanSize(start, span);
      const stretched = justifyMode(el, c) === P.A_STRETCH && sizeUnit(c, P.P_WIDTH) === P.U_AUTO &&
        sizeUnit(c, P.P_MARGIN_LEFT) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_RIGHT) !== P.U_AUTO;
      layoutBox(c, w, NaN, stretched ? clampW(c, Math.max(0, w - ml - mr), w) : NaN, NaN, !stretched && sizeUnit(c, P.P_WIDTH) === P.U_AUTO);
      const freeW = w - c.w - ml - mr;
      c.x = pl + laneAt[start] + ml + alignOffset(justifyMode(el, c), freeW, justifySafe(el, c));
      c.y = pt + pos + mt;
      size = c.h + mt + mb;
    }
    // A reversed lane stacks from its end edge, so the margin that leads is the one on that side
    // (the bottom margin in a column lane, the right one in a row lane) and it may run the item
    // back past the lane's start no further than that edge itself.
    const next = pos + (fillReverse ? size : Math.max(0, size)) + gap;
    for (let q = 0; q < span; q++) {
      running[start + q] = fillReverse ? next : Math.max(running[start + q], next);
      occupied[start + q].push({ s: pos, e: next });
    }
    placed.push({ c, start, span, pos, size });
  }

  let contentH: number;
  if (rowLanes) {
    // A row lane is as tall as the items it holds, margins included. The placement above needs
    // only their inline positions, so the lane sizes can follow it: each lane takes the items
    // that landed in it, and each item then sits at its lane's top.
    for (let i = 0; i < laneCount; i++) { minC[i] = 0; maxC[i] = 0; autoMin[i] = 0; }
    for (const p of placed) {
      const c = p.c;
      const h = c.h + zeroIfNaN(len(c, P.P_MARGIN_TOP, innerW)) + zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, innerW));
      for (let q = 0; q < p.span && p.start + q < laneCount; q++) {
        const i = p.start + q;
        minC[i] = Math.max(minC[i], h);
        maxC[i] = Math.max(maxC[i], h);
        autoMin[i] = Math.max(autoMin[i], h);
      }
    }
    sizes = sizeTracks(el, lanes, Number.isNaN(trackAvail) ? NaN : trackAvail, trackGap,
      minC, maxC, stretch, false, autoMin);
    el.gridUsedRows = sizes;
    total = trackGap * Math.max(0, laneCount - 1);
    for (const s of sizes) total += s;
    const free2 = Number.isNaN(avail) ? 0 : avail - total;
    const [lead2, extra2] = distribute(pack, free2, laneCount, false);
    let at2 = lead2;
    for (let i = 0; i < laneCount; i++) {
      laneAt[i] = at2;
      at2 += sizes[i] + trackGap + extra2;
    }
    // The lanes the item covers are its containing block along the block axis, so lay each item out
    // again against them and put it where its lane now starts. An item with no block size of its
    // own stretches over the lanes it covers, as a grid item fills its area.
    for (const p of placed) {
      const c = p.c;
      const fit = sizeUnit(c, P.P_WIDTH) === P.U_AUTO && aspectRatio(c) <= 0;
      const mt2 = zeroIfNaN(len(c, P.P_MARGIN_TOP, innerW));
      const mb2 = zeroIfNaN(len(c, P.P_MARGIN_BOTTOM, innerW));
      let spanning = 0;
      for (let q = 0; q < p.span && p.start + q < laneCount; q++) {
        spanning += sizes[p.start + q] + (q > 0 ? trackGap : 0);
      }
      // An item with no block size of its own fills a lane that has a size of its own, and one
      // that spans several lanes fills them however they were sized. A single item in an auto
      // lane keeps its own height: the lane is sized to it, and to the tallest of its items.
      const laneFixed = !Number.isNaN(fixedPx(lanes[p.start].min, el, trackAvail));
      // A subgrid item's own `align-self` is ignored in the axis it subgrids: it fills its rows.
      const subRows = c.su[P.P_GRID_TEMPLATE_ROWS] === P.U_SUBGRID && c.sgRowSet;
      const canStretchH = (p.span > 1 || laneFixed) && (subRows || alignMode(el, c) === P.A_STRETCH) &&
        sizeUnit(c, P.P_HEIGHT) === P.U_AUTO &&
        sizeUnit(c, P.P_MARGIN_TOP) !== P.U_AUTO && sizeUnit(c, P.P_MARGIN_BOTTOM) !== P.U_AUTO;
      const fixedH2 = canStretchH ? clampH(c, Math.max(0, spanning - mt2 - mb2), innerW, spanning) : NaN;
      layoutBox(c, innerW, spanning, NaN, fixedH2, fit);
      const ml2 = zeroIfNaN(len(c, P.P_MARGIN_LEFT, innerW));
      const mr2 = zeroIfNaN(len(c, P.P_MARGIN_RIGHT, innerW));
      c.x = fillReverse ? pl + innerW - Math.max(0, p.pos + mr2) - c.w : pl + p.pos + ml2;
      c.y = pt + laneAt[p.start] + mt2;
    }
    contentH = 0;
    for (const s of sizes) contentH += s;
    contentH += trackGap * Math.max(0, laneCount - 1);
    if (Number.isNaN(contentH)) contentH = 0;
  } else {
    let max = 0;
    for (const p of running) max = Math.max(max, p);
    contentH = Math.max(0, max - (items.length > 0 ? gap : 0));
    if (!Number.isNaN(innerH)) contentH = innerH;
  }
  if (fillReverse) {
    // The stacked content hangs off the lane's end edge: a column lane from the bottom of the
    // container and a row lane from its right edge, whichever of the two the container has.
    const end = rowLanes ? innerW : Number.isNaN(innerH) ? contentH : innerH;
    for (const p of placed) {
      const c = p.c;
      const lead = zeroIfNaN(len(c, rowLanes ? P.P_MARGIN_RIGHT : P.P_MARGIN_BOTTOM, innerW));
      if (rowLanes) {
        const edge = Math.max(0, p.pos + lead);
        c.x = pl + end - edge - c.w;
      } else {
        const edge = Math.max(0, p.pos + lead);
        c.y = pt + end - edge - c.h;
      }
    }
  }
  for (const p of placed) place(p.c);

  const boxH = Number.isNaN(contentH) ? 0 : contentH;
  placeOutOfFlow(el, innerW, boxH, pl, pt, () => ({ x: pl, y: pt, w: innerW, h: boxH }));
  markDescendantAreas(el, el, () => ({ x: pl, y: pt, w: innerW, h: boxH }));
  return contentH;
}
