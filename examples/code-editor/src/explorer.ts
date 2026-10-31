import { asciiBytes } from "@native-sdk/core";

export type EntryKind = "directory" | "file";
export interface ExplorerEntry {
  readonly name: Uint8Array;
  readonly relative_path: Uint8Array;
  readonly kind: EntryKind;
  readonly depth: number;
  readonly parent: number | null;
  readonly expanded: boolean;
  readonly children_loaded: boolean;
  readonly sort_identity: number;
}

export interface DirectoryItem {
  readonly name: Uint8Array;
  readonly directory: boolean;
}

export function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let i = 0; i < left.length; i += 1) if (left[i] !== right[i]) return false;
  return true;
}

function componentOrder(left: Uint8Array, right: Uint8Array, insensitive: boolean): number {
  const length = Math.min(left.length, right.length);
  for (let i = 0; i < length; i += 1) {
    const a = left[i]!, b = right[i]!;
    const x = insensitive && a >= 65 && a <= 90 ? a + 32 : a;
    const y = insensitive && b >= 65 && b <= 90 ? b + 32 : b;
    if (x !== y) return x < y ? -1 : 1;
  }
  return left.length < right.length ? -1 : left.length > right.length ? 1 : 0;
}

function componentEnd(path: Uint8Array, from: number): number {
  let end = from;
  while (end < path.length && path[end] !== 47) end += 1;
  return end;
}

/** Match native path-component ordering, including case-sensitive ties. */
export function explorerEntryOrder(left: ExplorerEntry, right: ExplorerEntry): number {
  const a = left.relative_path, b = right.relative_path;
  let first = 0, second = 0;
  while (true) {
    if (first > a.length) return second > b.length ? 0 : -1;
    if (second > b.length) return 1;
    const endA = componentEnd(a, first), endB = componentEnd(b, second);
    const partA = a.subarray(first, endA), partB = b.subarray(second, endB);
    if (!bytesEqual(partA, partB)) {
      const directoryA = endA < a.length || left.kind === "directory";
      const directoryB = endB < b.length || right.kind === "directory";
      if (directoryA !== directoryB) return directoryA ? -1 : 1;
      const folded = componentOrder(partA, partB, true);
      return folded === 0 ? componentOrder(partA, partB, false) : folded;
    }
    first = endA + 1;
    second = endB + 1;
  }
}

export function parentPath(path: Uint8Array): Uint8Array | null {
  let separator = -1;
  for (let i = 0; i < path.length; i += 1) if (path[i] === 47) separator = i;
  return separator < 0 ? null : path.subarray(0, separator);
}

export function joinPath(parent: Uint8Array, name: Uint8Array): Uint8Array {
  const output = new Uint8Array(parent.length + 1 + name.length);
  for (let i = 0; i < parent.length; i += 1) output[i] = parent[i]!;
  output[parent.length] = 47;
  for (let i = 0; i < name.length; i += 1) output[parent.length + 1 + i] = name[i]!;
  return output;
}

export function basename(path: Uint8Array): Uint8Array {
  let end = path.length;
  while (end > 0 && (path[end - 1] === 47 || path[end - 1] === 92)) end -= 1;
  if (end === 0) return path;
  let start = end;
  while (start > 0 && path[start - 1] !== 47) start -= 1;
  return path.subarray(start, end);
}

export function skipExplorerDirectory(name: Uint8Array): boolean {
  const skipped = [
    asciiBytes(".git"), asciiBytes(".next"), asciiBytes(".pnpm-store"),
    asciiBytes(".zig-cache"), asciiBytes("node_modules"),
    asciiBytes("zig-cache"), asciiBytes("zig-out"),
  ];
  for (const candidate of skipped) if (bytesEqual(name, candidate)) return true;
  return false;
}

export function explorerItem(item: DirectoryItem, parent: ExplorerEntry | null): ExplorerEntry | null {
  const path = parent === null ? item.name : joinPath(parent.relative_path, item.name);
  if (item.name.length > 255 || path.length > 512) return null;
  const depth = parent === null ? 1 : Math.min(255, parent.depth + 1);
  return {
    name: item.name, relative_path: path, kind: item.directory ? "directory" : "file",
    depth, parent: null, expanded: false,
    children_loaded: !item.directory || depth >= 12 || skipExplorerDirectory(item.name),
    sort_identity: 0,
  };
}

/** Return fresh entries; never mutate a committed tree or borrowed names. */
export function assignExplorerParents(entries: readonly ExplorerEntry[]): ExplorerEntry[] {
  const output: ExplorerEntry[] = [];
  for (const entry of entries) {
    if (entry === undefined) continue;
    const dirname = parentPath(entry.relative_path);
    let parent: number | null = null;
    if (dirname !== null) {
      for (let i = 0; i < entries.length; i += 1) {
        const candidate = entries[i]!;
        if (candidate.kind === "directory" && bytesEqual(candidate.relative_path, dirname)) {
          parent = i >>> 0;
          break;
        }
      }
    }
    output.push({ ...entry, parent });
  }
  return output;
}

export function explorerEntryVisible(entries: readonly ExplorerEntry[], entry: ExplorerEntry): boolean {
  let parent = entry.parent;
  for (let depth = 0; parent !== null && depth < 128; depth += 1) {
    const ancestor = entries[parent];
    if (ancestor === undefined || !ancestor.expanded) return false;
    parent = ancestor.parent;
  }
  return parent === null;
}

export function validExplorerName(name: Uint8Array): boolean {
  if (name.length === 0 || name.length === 1 && name[0] === 46 ||
      name.length === 2 && name[0] === 46 && name[1] === 46) return false;
  for (const byte of name) if (byte === 47 || byte === 92) return false;
  return true;
}

export function descendantSuffix(path: Uint8Array, ancestor: Uint8Array): Uint8Array | null {
  if (path.length <= ancestor.length || path[ancestor.length] !== 47) return null;
  for (let i = 0; i < ancestor.length; i += 1) if (path[i] !== ancestor[i]) return null;
  return path.subarray(ancestor.length + 1);
}

export function renamedExplorerPath(entry: ExplorerEntry, name: Uint8Array): Uint8Array {
  const parent = parentPath(entry.relative_path);
  return parent === null ? name : joinPath(parent, name);
}

export function explorerRenamedPathsFit(entries: readonly ExplorerEntry[], index: number, name: Uint8Array): boolean {
  const selected = entries[index];
  if (selected === undefined) return false;
  const next = renamedExplorerPath(selected, name);
  if (next.length > 512) return false;
  if (selected.kind === "directory") {
    for (const entry of entries) {
      const suffix = descendantSuffix(entry.relative_path, selected.relative_path);
      if (suffix !== null && next.length + 1 + suffix.length > 512) return false;
    }
  }
  return true;
}
