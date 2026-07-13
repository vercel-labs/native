// system-monitor-ts table module: the process table's pure presentation
// tier — search matching, the sort order, and the row formatting the
// markup cells bind. core.ts's exported binding helpers (`visibleRows`,
// `matchCount`) stay thin wrappers over these (the binding surface lives
// in the entry module; this module is its machinery).

import { asciiBytes } from "@native-sdk/core";
import { containsIgnoreCase, orderIgnoreCase } from "@native-sdk/core/text";
import { concat2, containsBytes, formatBytes, intDiv, type Bytes, type ParsedProcess } from "./parsers.ts";
import type { Model } from "./core.ts";

/// Process rows the table shows (of the MAX_ROWS kept).
export const MAX_TABLE_ROWS = 14;

export type SortKey = "cpu" | "mem" | "pid" | "name";

export interface TableRow {
  readonly pid: number;
  readonly pidText: Bytes;
  readonly name: Bytes;
  readonly cpuText: Bytes;
  readonly memText: Bytes;
  /// "{name} pid {pid}" — the row's accessibility label, prebuilt because
  /// markup label attributes carry one binding.
  readonly rowLabel: Bytes;
}

export function rowMatches(row: ParsedProcess, query: Bytes): boolean {
  if (query.length === 0) return true;
  if (containsIgnoreCase(row.name, query)) return true;
  return containsBytes(asciiBytes(`${row.pid}`), query);
}

/// Strict weak ordering as a sign: compare by the active key, break ties
/// by pid (unique), then apply the direction — the Zig rowLessThan.
export function rowOrder(sortKey: SortKey, descending: boolean, a: ParsedProcess, b: ParsedProcess): number {
  let keyed = 0;
  if (sortKey === "cpu") keyed = a.cpuTenths - b.cpuTenths;
  else if (sortKey === "mem") keyed = a.rssKb - b.rssKb;
  else if (sortKey === "pid") keyed = a.pid - b.pid;
  else keyed = orderIgnoreCase(a.name, b.name);
  const tied = keyed === 0 ? a.pid - b.pid : keyed;
  return descending ? -tied : tied;
}

/// Table rows from the kept sample rows: search-filtered, sorted by the
/// active key/direction, cut to MAX_TABLE_ROWS, formatted for the cells.
export function tableRows(
  rows: readonly ParsedProcess[],
  query: Bytes,
  key: SortKey,
  descending: boolean,
): readonly TableRow[] {
  const matches: ParsedProcess[] = [];
  for (const row of rows) {
    if (rowMatches(row, query)) matches.push(row);
  }
  const sorted = matches.toSorted((a, b) => rowOrder(key, descending, a, b));
  const out: TableRow[] = [];
  for (const row of sorted) {
    if (out.length >= MAX_TABLE_ROWS) break;
    const whole = intDiv(row.cpuTenths, 10);
    const tenth = row.cpuTenths - whole * 10;
    out.push({
      pid: row.pid,
      pidText: asciiBytes(`${row.pid}`),
      name: row.name,
      cpuText: asciiBytes(`${whole}.${tenth}`),
      memText: formatBytes(row.rssKb * 1024),
      rowLabel: concat2(row.name, asciiBytes(` pid ${row.pid}`)),
    });
  }
  return out;
}

/// Sort chips: a fresh key starts in its natural direction (biggest
/// first for the numeric loads, a-to-z and low pids first); the active
/// key flips. Takes the Model type-only (a runtime back-edge into core.ts
/// would be an import cycle, NS1036; the type erases).
export function sortedBy(model: Model, key: SortKey): Model {
  if (model.sortKey === key) return { ...model, sortDescending: !model.sortDescending };
  return { ...model, sortKey: key, sortDescending: key === "cpu" || key === "mem" };
}
