/** The markup closure of a TypeScript app: every `.native` file under
 * `src/` (outside `src/services/`), and the secondary-window views
 * declared by the top-level files in `src/windows/`. The build compiles
 * exactly this closure beside the core, and `native check` verifies the
 * same one.
 */
import fs from "node:fs";
import path from "node:path";
import type { WindowViewSource } from "./view_frontend.ts";

export interface AppViewSources {
  /** Every markup file, keyed by its path relative to `src/`. */
  readonly sources: Map<string, string>;
  /** Secondary windows in label order, each rooted at `src/windows/`. */
  readonly windows: WindowViewSource[];
}

export function appViewSources(srcDir: string): AppViewSources {
  const sources = new Map<string, string>();
  const collect = (dir: string, relative: string): void => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const rel = relative + entry.name;
      if (entry.isDirectory() && rel !== "services") collect(path.join(dir, entry.name), rel + "/");
      else if (entry.isFile() && rel.endsWith(".native")) sources.set(rel, fs.readFileSync(path.join(dir, entry.name), "utf8"));
    }
  };
  collect(srcDir, "");
  const windowSources = new Map([...sources].filter(([name]) => name.startsWith("windows/"))
    .map(([name, source]) => [name.slice("windows/".length), source]));
  const windows = [...windowSources].filter(([name]) => !name.includes("/"))
    .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([entry, source]) => ({ label: entry.slice(0, -".native".length), entry, source, sources: windowSources }));
  return { sources, windows };
}
