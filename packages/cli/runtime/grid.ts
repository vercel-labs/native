// Grid track lists: the rows compiled at build time, and resolving one for the element it
// belongs to.
//
// A value is a row id (U_LIST); each row holds GRID_TRACK_STRIDE numbers per track, the min and
// max slots of that track's minmax() (see shared/props.ts). The lengths keep their units until
// layout, which is where em and percentages meet the element and its content box.

import * as P from "../shared/props.ts";
import type { Node } from "./dom.ts";
import { cqUnitPx, exprLength } from "./style.ts";
import { rootFontSize } from "./root-size.ts";
import { fontMetrics, textWidth } from "./layout/text.ts";
import { viewport } from "./layout/box-model.ts";

export class GridTables {
  rows: number[][] = [];
  /** Rows an inline style registers at runtime, by synthetic id. */
  extras: Map<number, number[]> = new Map();
  extraKeys: Map<string, number> = new Map();
  /** The line and area names the compiled rows point into (the app's GRID_NAMES table). */
  names: string[] = [];
  /** Named placements: [name id, occurrence count, span flag] per row. */
  placements: number[][] = [];
  /** Named area lists: a count, then per area its name id and the four lines it spans. */
  areaLists: number[][] = [];
}

export const gridTracks: GridTables = new GridTables();

/** Rows registered at runtime start above every compiled row id. */
const RUNTIME_BASE = 1000000;

/** A name a runtime style sheet writes: its id sits above every compiled one. */
const NAME_BASE = 1000000;
const runtimeNames: string[] = [];
const runtimeNameIds = new Map<string, number>();

/** Id of a grid line or area name, whether the build or a runtime sheet wrote it. */
export function registerTrackName(name: string): number {
  const hit = runtimeNameIds.get(name);
  if (hit !== undefined) return hit;
  const id = NAME_BASE + runtimeNames.length;
  runtimeNames.push(name);
  runtimeNameIds.set(name, id);
  return id;
}

/** The text of a name id. */
export function nameText(id: number): string {
  return id >= NAME_BASE ? runtimeNames[id - NAME_BASE] ?? "" : gridTracks.names[id] ?? "";
}

/** Registers one named placement a runtime style sheet wrote, and returns its id. */
export function registerPlacement(row: number[]): number {
  gridTracks.placements.push(row);
  return gridTracks.placements.length - 1;
}

/** Registers one grid-template-areas list a runtime style sheet wrote, and returns its id. */
export function registerAreaList(row: number[]): number {
  gridTracks.areaLists.push(row);
  return gridTracks.areaLists.length - 1;
}

/** The placement a U_NAME value names, or null when the row isn't there. */
export function placementRow(id: number): { name: string; count: number; span: boolean } | null {
  const row = gridTracks.placements[id];
  if (row === undefined) return null;
  return { name: nameText(row[0]), count: row[1], span: row[2] === 1 };
}

/** One named area: its name and the column and row lines it spans, one-based. */
export interface AreaName {
  name: string;
  rowStart: number;
  rowEnd: number;
  colStart: number;
  colEnd: number;
}

/** The areas a grid-template-areas value names, or null for none. */
export function areaList(id: number): AreaName[] | null {
  if (id < 0) return null;
  const row = gridTracks.areaLists[id];
  if (row === undefined) return null;
  const out: AreaName[] = [];
  for (let i = 1; i + 4 < row.length; i += 5) {
    out.push({ name: nameText(row[i]), rowStart: row[i + 1], rowEnd: row[i + 2], colStart: row[i + 3], colEnd: row[i + 4] });
  }
  return out.length === 0 ? null : out;
}

/** Registers one track list an inline style declared, and returns its id. */
export function registerTrackList(row: number[]): number {
  const key = row.join(",");
  const hit = gridTracks.extraKeys.get(key);
  if (hit !== undefined) return hit;
  const id = RUNTIME_BASE + gridTracks.extras.size;
  gridTracks.extras.set(id, row);
  gridTracks.extraKeys.set(key, id);
  return id;
}

/** One side of a track's minmax(): a fixed size, an intrinsic keyword, or a flex factor. */
export interface TrackSize {
  kind: number;
  v: number;
  u: number;
}

/** A track: its minimum and maximum (CSS Grid calls them the base size and growth limit). */
export interface Track {
  min: TrackSize;
  max: TrackSize;
  /** An `auto-fill`/`auto-fit` repetition: the list it repeats, and whether empty copies collapse. */
  repeat?: { entries: Track[]; fit: boolean };
  /** Names on the line this track starts on. */
  names?: string[];
  /** Names on the line that follows this track. */
  endNames?: string[];
}

/** The tracks one row of a track table holds, from `from` to `-1` or `to`. */
function readTracks(row: number[], from: number, to: number): Track[] {
  const out: Track[] = [];
  const stride = P.GRID_TRACK_STRIDE;
  // The names written since the last track: they name the line before the next one.
  let pending: string[] | undefined;
  for (let i = from; i + stride <= to; i += stride) {
    const kind = row[i];
    if (kind === P.GT_NAMES) {
      // The names fill GT_NAMES_PER_BLOCK slots of each whole block after the marker.
      const count = row[i + 1];
      const blocks = Math.ceil(count / P.GT_NAMES_PER_BLOCK);
      const names: string[] = [];
      for (let k = 0; k < count; k++) {
        const b = Math.floor(k / P.GT_NAMES_PER_BLOCK);
        const o = k % P.GT_NAMES_PER_BLOCK;
        names.push(nameText(row[i + stride * (b + 1) + o]));
      }
      // Names written in separate groups all name the same line.
      pending = pending === undefined ? names : pending.concat(names);
      i += blocks * stride;
      continue;
    }
    if (kind === P.GT_AUTO_FILL || kind === P.GT_AUTO_FIT) {
      // The marker block is followed by the list it repeats, `innerCount` tracks long.
      const innerCount = row[i + 1];
      const start = i + stride;
      const end = Math.min(to, start + innerCount * stride);
      const marker: Track = {
        min: { kind: P.GT_AUTO, v: 0, u: 0 }, max: { kind: P.GT_AUTO, v: 0, u: 0 },
        repeat: { entries: readTracks(row, start, end), fit: kind === P.GT_AUTO_FIT },
      };
      if (pending !== undefined) marker.names = pending;
      pending = undefined;
      out.push(marker);
      i += innerCount * stride;
      continue;
    }
    const track: Track = { min: { kind, v: row[i + 1], u: row[i + 2] }, max: { kind: row[i + 7], v: row[i + 8], u: row[i + 9] } };
    if (pending !== undefined) track.names = pending;
    pending = undefined;
    out.push(track);
  }
  // Names after the last track name the line the list ends on.
  if (pending !== undefined && out.length > 0) out[out.length - 1].endNames = pending;
  return out;
}

/** The tracks a grid-template-* or grid-auto-* value (a row id) names, or null for none. */
/**
 * The line names a names-only track row holds, as CSS text: a subgrid writes its own names after
 * `subgrid`, and they all name the one line the subgrid stands on.
 */
/**
 * The line names a names-only track row holds, one entry per bracket group it was written with,
 * in order: `[a] [b]` names the first line a and the second b.
 */
export function trackNameGroups(id: number): string[][] {
  if (id < 0) return [];
  const row = id >= RUNTIME_BASE ? gridTracks.extras.get(id) : gridTracks.rows[id];
  if (row === undefined) return [];
  const groups: string[][] = [];
  const stride = P.GRID_TRACK_STRIDE;
  for (let i = 0; i + stride <= row.length; i += stride) {
    if (row[i] !== P.GT_NAMES) continue;
    const count = row[i + 1];
    const blocks = Math.ceil(count / P.GT_NAMES_PER_BLOCK);
    const names: string[] = [];
    for (let k = 0; k < count; k++) {
      const b = Math.floor(k / P.GT_NAMES_PER_BLOCK);
      const o = k % P.GT_NAMES_PER_BLOCK;
      names.push(nameText(row[i + stride * (b + 1) + o]));
    }
    groups.push(names);
    i += blocks * stride;
  }
  return groups;
}

/** Those groups as CSS text: each bracket as it was written, `[a] [b]`. */
export function lineNamesText(id: number): string {
  return trackNameGroups(id).map((names) => "[" + names.join(" ") + "]").join(" ");
}

export function trackList(id: number): Track[] | null {
  if (id < 0) return null;
  const row = id >= RUNTIME_BASE ? gridTracks.extras.get(id) : gridTracks.rows[id];
  if (row === undefined) return null;
  const out = readTracks(row, 0, row.length);
  return out.length === 0 ? null : out;
}

/** A track size's length in px, with a percentage resolved against `base`. */
export function trackPx(size: TrackSize, el: Node, base: number): number {
  const v = size.v;
  switch (size.u) {
    case P.U_PCT: return (v / 100) * base;
    case P.U_EM: return v * el.sv[P.P_FONT_SIZE];
    case P.U_REM: return v * rootFontSize();
    case P.U_LH: return v * el.sv[P.P_LINE_HEIGHT];
    case P.U_EX: return v * fontMetrics(el)[2];
    case P.U_CH: return v * textWidth(el, "0");
    case P.U_VW: return (v / 100) * viewport.w;
    case P.U_VH: return (v / 100) * viewport.h;
    case P.U_CQW: case P.U_CQH: case P.U_CQI: case P.U_CQB: case P.U_CQMIN: case P.U_CQMAX:
      return cqUnitPx(el, v, size.u);
    case P.U_EXPR: return exprLength(el, v, base, el.sv[P.P_FONT_SIZE]);
  }
  return v; // px, or a unitless zero
}
