// Watches a directory and everything under it, one non-recursive fs.watch per directory: the
// native executable has no recursive fs.watch, and on Linux that is how Node itself provides it.
// A directory created later is watched once its parent reports it. Names come back relative to
// the root, as a recursive watcher reports them.

import { readdirSync, statSync, watch } from "node:fs";
import type { FSWatcher } from "node:fs";
import { join, relative } from "node:path";

export interface TreeWatcher {
  close(): void;
}

/**
 * Calls `onChange` with the root-relative name of each file that changes under `root`.
 * `skipDir` names directories (root-relative) that aren't descended into, such as node_modules.
 */
export function watchTree(root: string, skipDir: (name: string) => boolean,
                          onChange: (event: string, name: string) => void): TreeWatcher {
  // Each directory's watcher, held as its close function (scriptc keeps Maps of records and
  // functions, not of FSWatcher objects).
  const watchers = new Map<string, TreeWatcher>();
  let closed = false;

  const add = (dir: string): void => {
    if (closed || watchers.has(dir)) return;
    let watcher: FSWatcher;
    try {
      watcher = watch(dir, (event, name) => {
        if (name === null || closed) return;
        const path = join(dir, String(name));
        const rel = relative(root, path);
        let isDir = false;
        try {
          isDir = statSync(path).isDirectory();
        } catch {
          // removed: drop its watcher, if it was a directory
          const gone = watchers.get(path);
          if (gone !== undefined) {
            gone.close();
            watchers.delete(path);
          }
        }
        if (isDir) {
          // A new directory can arrive with its files (a move, a checkout): they count as changed.
          if (!skipDir(rel) && !watchers.has(path)) addTree(path, true);
          return;
        }
        onChange(event, rel);
      });
    } catch {
      return; // unreadable, or gone before it could be watched
    }
    const opened = watcher;
    watchers.set(dir, { close: () => opened.close() });
  };

  const addTree = (dir: string, report: boolean = false): void => {
    add(dir);
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const entry of entries) {
      const path = join(dir, entry);
      let isDir: boolean;
      try {
        isDir = statSync(path).isDirectory();
      } catch {
        continue;
      }
      if (!isDir) {
        if (report) onChange("rename", relative(root, path));
      } else if (!skipDir(relative(root, path))) {
        addTree(path, report);
      }
    }
  };

  addTree(root);
  return {
    close(): void {
      closed = true;
      for (const watcher of watchers.values()) watcher.close();
      watchers.clear();
    },
  };
}
