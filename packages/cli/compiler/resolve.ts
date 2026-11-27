// Module resolution as Node does it, for the files a build copies: an `import` resolved through a
// package's "import" condition (the build an app's import runs) and a `require()` through its
// "require" condition, both from the importing file, so the app's own node_modules is searched.
//
// Node's own resolvers (import.meta.resolve with a loader hook, createRequire) are only reachable
// from a running Node, and native also runs as a native executable, so this is the same algorithm
// written out: node_modules lookup, package.json "exports", "imports" and self-references with
// their conditions, and "main", extensions and index files for CommonJS and packages without
// "exports". It answers the path Node would load, or null for a builtin, a package that isn't
// installed or a subpath a package doesn't export.

import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

/** How the specifier is loaded: an ES module import, or a CommonJS require. */
export type ResolveMode = "import" | "require";

/** The conditions Node 24 matches in "exports" and "imports" for each mode. */
const CONDITIONS: { [mode in ResolveMode]: string[] } = {
  import: ["node", "import", "module-sync", "default"],
  require: ["node", "require", "module-sync", "default"],
};

/** Node's builtin modules, which a bare specifier names before any installed package. */
const BUILTINS = new Set([
  "assert", "assert/strict", "async_hooks", "buffer", "child_process", "cluster", "console",
  "constants", "crypto", "dgram", "diagnostics_channel", "dns", "dns/promises", "domain", "events",
  "fs", "fs/promises", "http", "http2", "https", "inspector", "inspector/promises", "module", "net",
  "os", "path", "path/posix", "path/win32", "perf_hooks", "process", "punycode", "querystring",
  "readline", "readline/promises", "repl", "stream", "stream/consumers", "stream/promises",
  "stream/web", "string_decoder", "sys", "timers", "timers/promises", "tls", "trace_events", "tty",
  "url", "util", "util/types", "v8", "vm", "wasi", "worker_threads", "zlib",
]);

/** The extensions require() tries, in order. */
const REQUIRE_EXTS = [".js", ".json", ".node"];

interface PackageJson {
  dir: string;
  name?: string;
  main?: string;
  exports?: unknown;
  imports?: unknown;
}

const packageJsons = new Map<string, PackageJson | null>();

function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function real(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

/** The package.json in `dir`, parsed, or null when there is none (or it isn't JSON). */
function readPackageJson(dir: string): PackageJson | null {
  const cached = packageJsons.get(dir);
  if (cached !== undefined) return cached;
  let found: PackageJson | null = null;
  const file = join(dir, "package.json");
  if (isFile(file)) {
    try {
      const json = JSON.parse(readFileSync(file, "utf8")) as { [key: string]: unknown };
      found = { dir };
      if (typeof json.name === "string") found.name = json.name;
      if (typeof json.main === "string") found.main = json.main;
      if ("exports" in json) found.exports = json.exports;
      if ("imports" in json) found.imports = json.imports;
    } catch {
      found = null;
    }
  }
  packageJsons.set(dir, found);
  return found;
}

/** The nearest package.json at or above `dir`, the package scope a file belongs to. */
function packageScope(dir: string): PackageJson | null {
  for (let at = dir; ; ) {
    if (at.endsWith("/node_modules") || at.endsWith("\\node_modules")) return null;
    const pkg = readPackageJson(at);
    if (pkg !== null) return pkg;
    const up = dirname(at);
    if (up === at) return null;
    at = up;
  }
}

/** True when `spec` is a Node builtin: `node:` anything, or one of the bare builtin names. */
export function isBuiltin(spec: string): boolean {
  return spec.startsWith("node:") || BUILTINS.has(spec);
}

/**
 * The file `spec` names when `parentFile` loads it with `mode`, or null when Node would load no
 * file for it (a builtin) or fail to resolve it. Throws nothing.
 */
export function resolveModule(spec: string, parentFile: string, mode: ResolveMode): string | null {
  if (spec === "" || isBuiltin(spec)) return null;
  const conditions = CONDITIONS[mode];
  const parentDir = dirname(resolve(parentFile));
  let found: string | null;
  if (spec.startsWith("file://")) {
    found = loadPath(fileUrlPath(spec), mode);
  } else if (/^[a-z][a-z0-9+.-]*:/i.test(spec) && !/^[a-z]:[\\/]/i.test(spec)) {
    return null; // another URL scheme (data:, http:), which names no file
  } else if (spec.startsWith("./") || spec.startsWith("../") || spec === "." || spec === ".."
             || spec.startsWith("/") || /^[a-z]:[\\/]/i.test(spec) || spec.startsWith("\\")) {
    found = loadPath(resolve(parentDir, spec), mode);
  } else if (spec.startsWith("#")) {
    found = resolveImports(spec, parentDir, conditions, mode);
  } else {
    found = resolvePackage(spec, parentDir, conditions, mode);
  }
  return found === null ? null : real(found);
}

function fileUrlPath(url: string): string {
  let path = decodeURIComponent(url.slice("file://".length));
  if (/^\/[a-z]:\//i.test(path)) path = path.slice(1);
  return path;
}

/** A relative or absolute path: as named for an import (ES modules add no extension, and, like
 *  import.meta.resolve, the path is answered whether or not a file is there), through require's
 *  extensions and index files for a require. */
function loadPath(path: string, mode: ResolveMode): string | null {
  if (mode === "import") return path;
  return loadAsFile(path) ?? loadAsDirectory(path);
}

function loadAsFile(path: string): string | null {
  if (isFile(path)) return path;
  for (const ext of REQUIRE_EXTS) if (isFile(path + ext)) return path + ext;
  return null;
}

function loadIndex(dir: string): string | null {
  for (const ext of REQUIRE_EXTS) {
    const index = join(dir, "index" + ext);
    if (isFile(index)) return index;
  }
  return null;
}

/** A directory as require() loads one, and as an import loads a package without "exports":
 *  its package.json "main", then its index file. */
function loadAsDirectory(dir: string): string | null {
  const pkg = readPackageJson(dir);
  if (pkg?.main !== undefined) {
    const main = resolve(dir, pkg.main);
    const hit = loadAsFile(main) ?? loadIndex(main);
    if (hit !== null) return hit;
  }
  return loadIndex(dir);
}

/** A "#name" specifier, through the "imports" of the package the parent file is in. */
function resolveImports(spec: string, parentDir: string, conditions: string[], mode: ResolveMode): string | null {
  if (spec === "#" || spec.startsWith("#/")) return null;
  const scope = packageScope(parentDir);
  if (scope === null || scope.imports === null || typeof scope.imports !== "object" || Array.isArray(scope.imports)) return null;
  const target = matchMap(spec, scope.imports as { [key: string]: unknown });
  if (target === null) return null;
  return resolveTarget(scope.dir, target.value, target.star, conditions, true, parentDir, mode) ?? null;
}

/** Splits a bare specifier into its package name and the subpath within it (`.` for none). */
function splitPackage(spec: string): { name: string; subpath: string } | null {
  const parts = spec.split("/");
  const count = spec.startsWith("@") ? 2 : 1;
  if (parts.length < count || parts.slice(0, count).some((part) => part === "")) return null;
  const name = parts.slice(0, count).join("/");
  if (name.startsWith(".") || name.includes("\\") || name.includes("%")) return null;
  const rest = parts.slice(count).join("/");
  return { name, subpath: rest === "" ? "." : "./" + rest };
}

function resolvePackage(spec: string, parentDir: string, conditions: string[], mode: ResolveMode): string | null {
  const parsed = splitPackage(spec);
  if (parsed === null) return null;
  const { name, subpath } = parsed;
  // A package names itself through its own "exports".
  const scope = packageScope(parentDir);
  if (scope !== null && scope.name === name && scope.exports !== undefined && scope.exports !== null) {
    return resolveExports(scope, subpath, conditions, mode);
  }
  for (let dir = parentDir; ; ) {
    if (!(dir.endsWith("/node_modules") || dir.endsWith("\\node_modules"))) {
      const pkgDir = join(dir, "node_modules", name);
      if (isDirectory(pkgDir)) {
        const pkg = readPackageJson(pkgDir);
        if (pkg !== null && pkg.exports !== undefined && pkg.exports !== null) {
          return resolveExports(pkg, subpath, conditions, mode);
        }
        const path = join(pkgDir, subpath);
        // An import stops at the first directory of the package's name; require() goes on to the
        // next node_modules up when the file isn't in this one.
        if (mode === "import") return subpath === "." ? loadAsDirectory(pkgDir) : path;
        const hit = subpath === "." ? loadAsDirectory(pkgDir) : loadAsFile(path) ?? loadAsDirectory(path);
        if (hit !== null) return hit;
      }
    }
    const up = dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

/** A subpath through a package's "exports": an exact key, then the longest matching pattern. */
function resolveExports(pkg: PackageJson, subpath: string, conditions: string[], mode: ResolveMode): string | null {
  let exports = pkg.exports;
  const isConditionMap = exports !== null && typeof exports === "object" && !Array.isArray(exports)
    && Object.keys(exports as object).every((key) => !key.startsWith("."));
  if (typeof exports === "string" || Array.isArray(exports) || isConditionMap) exports = { ".": exports };
  if (exports === null || typeof exports !== "object") return null;
  const target = matchMap(subpath, exports as { [key: string]: unknown });
  if (target === null) return null;
  const found = resolveTarget(pkg.dir, target.value, target.star, conditions, false, pkg.dir, mode) ?? null;
  // import.meta.resolve names an exported path whether or not the file is there; require() fails.
  return found !== null && mode === "require" && !isFile(found) ? null : found;
}

/** The entry of an "exports" or "imports" map a key matches: the exact key, or the pattern
 *  (one `*`) with the longest prefix, and what its `*` stands for. */
function matchMap(key: string, map: { [key: string]: unknown }): { value: unknown; star: string | null } | null {
  if (Object.prototype.hasOwnProperty.call(map, key) && !key.includes("*")) return { value: map[key], star: null };
  let best: string | null = null;
  let star = "";
  for (const pattern of Object.keys(map)) {
    const at = pattern.indexOf("*");
    if (at < 0 || pattern.indexOf("*", at + 1) >= 0) continue;
    const prefix = pattern.slice(0, at);
    const suffix = pattern.slice(at + 1);
    if (!key.startsWith(prefix) || key === prefix) continue;
    if (suffix !== "" && (!key.endsWith(suffix) || key.length < pattern.length)) continue;
    if (best === null || comparePatternKeys(best, pattern) > 0) {
      best = pattern;
      star = key.slice(prefix.length, key.length - suffix.length);
    }
  }
  return best === null ? null : { value: map[best], star };
}

/** Node's PATTERN_KEY_COMPARE: negative when `a` sorts first (is the more specific pattern). */
function comparePatternKeys(a: string, b: string): number {
  const baseA = a.indexOf("*");
  const baseB = b.indexOf("*");
  const lengthA = baseA < 0 ? a.length : baseA + 1;
  const lengthB = baseB < 0 ? b.length : baseB + 1;
  if (lengthA > lengthB) return -1;
  if (lengthB > lengthA) return 1;
  if (baseA < 0) return 1;
  if (baseB < 0) return -1;
  if (a.length > b.length) return -1;
  if (b.length > a.length) return 1;
  return 0;
}

/** An "exports" or "imports" target: a path within the package (with `*` replaced), the first of
 *  an array that is a valid target, or the first condition of an object that matches. In
 *  "imports" a target can also name another package. Undefined when no condition matched, null
 *  when the target is invalid or excluded (a null target), as in Node's PACKAGE_TARGET_RESOLVE. */
function resolveTarget(pkgDir: string, target: unknown, star: string | null, conditions: string[],
                       internal: boolean, parentDir: string, mode: ResolveMode): string | null | undefined {
  if (typeof target === "string") {
    const value = star === null ? target : target.split("*").join(star);
    if (!target.startsWith("./")) {
      if (!internal || target.startsWith("../") || target.startsWith("/") || /^[a-z][a-z0-9+.-]*:/i.test(target)) return null;
      return resolvePackage(value, parentDir, conditions, mode);
    }
    const segments = value.slice(2).split(/[\\/]/);
    if (segments.some((s) => s === ".." || s === "." || s.toLowerCase() === "node_modules")) return null;
    return join(pkgDir, value);
  }
  if (Array.isArray(target)) {
    if (target.length === 0) return null;
    let last: string | null | undefined = null;
    for (const entry of target) {
      last = resolveTarget(pkgDir, entry, star, conditions, internal, parentDir, mode);
      if (last !== null && last !== undefined) return last;
    }
    return last;
  }
  if (target !== null && typeof target === "object") {
    const map = target as { [key: string]: unknown };
    for (const key of Object.keys(map)) {
      if (key !== "default" && !conditions.includes(key)) continue;
      const hit = resolveTarget(pkgDir, map[key], star, conditions, internal, parentDir, mode);
      if (hit !== undefined) return hit;
    }
    return undefined;
  }
  return null;
}
