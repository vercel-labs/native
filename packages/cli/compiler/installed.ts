// Where an installed package is, found the way Node finds one: in the node_modules beside a
// directory or in any directory above it. A checkout has the CLI's dependencies in its own
// node_modules; an app that installs the CLI from npm has them hoisted beside it instead.

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

/** The directory of the package `name` as `from` would resolve it, or null when none is installed. */
export function installedPackage(from: string, name: string): string | null {
  for (let dir = from; ; dir = dirname(dir)) {
    const candidate = join(dir, "node_modules", name);
    if (existsSync(join(candidate, "package.json"))) return candidate;
    if (dirname(dir) === dir) return null;
  }
}

/** Every node_modules directory `from` resolves packages in, nearest first. */
export function nodeModulesDirs(from: string): string[] {
  const dirs: string[] = [];
  for (let dir = from; ; dir = dirname(dir)) {
    const candidate = join(dir, "node_modules");
    if (existsSync(candidate)) dirs.push(candidate);
    if (dirname(dir) === dir) return dirs;
  }
}
