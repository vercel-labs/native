// The build cache behind native: every input a build reads is hashed, and a build whose
// hashes all match one an earlier build stored reuses that build's executable instead of
// running scriptc again.
//
// There are two keys. The fast key covers the app's own files, the SDK's runtime, the
// installed dependencies' file metadata, and the toolchain: it is cheap enough to compute
// before the front end runs, so an unchanged build never parses HTML or CSS. The program
// key adds every module the build wrote into .native (the generated page tables, the copied
// app modules, the vendored dependencies and their declarations), so a change to a vendored
// file that the app's own files don't show still misses.
//
// An entry holds the executable, the compiled page tables a release build reads from its bundle,
// the dev build's tables, the warnings the build printed and a manifest of every module with its
// content hash. The manifest is what tells a dev session which modules an edit changed.

import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { publicDirOf, type BundleFile } from "./bundle.ts";
import { installedPackage } from "./installed.ts";
import { PAGE_TABLES_FILE } from "../shared/page-tables.ts";
import { NATIVE_BINARY } from "./root.ts";

/** The on-disk format of an entry and of the manifest it carries. */
const SCHEMA = 3;

/** Environment variables that change what scriptc compiles or how native writes it. The
 *  caches' own knobs and scriptc's timing output are not part of a build. */
const ENV_PREFIXES = ["SCRIPTC_", "NATIVE_"];
const ENV_IGNORED = new Set([
  "NATIVE_CACHE_DIR",
  "NATIVE_NO_CACHE",
  "NATIVE_CACHE_MAX_MB",
  // Where the executable finds its sources and how it was built, which the sdk and toolchain
  // digests already cover, and its own debugging output.
  "NATIVE_SDK_ROOT",
  "NATIVE_SDK_BINARY",
  "NATIVE_DEBUG",
  "SCRIPTC_CACHE_DIR",
  "SCRIPTC_NO_CACHE",
  "SCRIPTC_STATE_DIR",
  "SCRIPTC_TIMING",
]);

/** A module's logical name and the digest of its content. */
export type Manifest = Map<string, string>;

export interface CacheOptions {
  /** The app directory. */
  appDir: string;
  /** The executable the build writes. */
  out: string;
  /** A dev build has its own tables and debug paths. */
  dev: boolean;
  /** A `--release` build writes the app's identity and is signed, so its executable isn't the
   *  plain build's: the cache keeps the two apart. */
  packaged?: boolean;
  /** The SDK checkout the compiler runs from. */
  root: string;
  /** The page the build was asked for, before it was resolved to the directory's index.html. */
  input: string;
}

export interface CacheEntry {
  /** The program key. */
  key: string;
  /** The fast key the entry was stored under. */
  fast: string;
  out: string;
  dev: boolean;
  /** Bytes of the executable. */
  bytes: number;
  /** The page's compiled statistics, as the summary line prints them. */
  summary: string;
  /** The front end's diagnostics, as the build printed them. */
  diagnostics: string;
  /** What scriptc printed, with the SDK's own warnings tidied away. */
  stderr: string;
  /** Every module in the program, by logical name. */
  files: Manifest;
  /** The identity of the program the executable compiles (see programIdentity), or "" when the
   *  entry predates it. */
  program: string;
  /** Whether the entry carries the page tables a release build reads from its bundle. */
  pageTables: boolean;
  /** The app's own files, copied into the bundle whenever the entry is restored. */
  assets: BundleFile[];
  /** The page's title, for the app bundle's Info.plist. */
  title: string;
  /** The entry's directory. */
  dir: string;
}

/** True unless the user turned the cache off. */
export function cacheEnabled(): boolean {
  const value = process.env["NATIVE_NO_CACHE"];
  return value === undefined || value === "" || value === "0";
}

/** The root of the build cache: NATIVE_CACHE_DIR, else the platform's cache directory. */
export function cacheRoot(): string {
  const named = process.env["NATIVE_CACHE_DIR"];
  if (named !== undefined && named !== "") return resolve(named);
  const xdg = process.env["XDG_CACHE_HOME"];
  const base = xdg !== undefined && xdg !== "" ? xdg : join(homedir(), ".cache");
  return join(base, "native", "build");
}

/** The largest cache in MB; NATIVE_CACHE_MAX_MB overrides the default. 0 or less keeps every
 *  entry. */
function cacheMaxBytes(): number {
  const raw = process.env["NATIVE_CACHE_MAX_MB"];
  const mb = raw === undefined || raw === "" ? 4096 : Number(raw);
  return Number.isFinite(mb) && mb > 0 ? mb * 1024 * 1024 : 0;
}

export function hashText(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

/** A file's content, byte for byte: a font or an image is not text. */
export function hashFile(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

/** A digest of a set of named digests, in a fixed order. */
function digestOf(parts: Iterable<readonly [string, string]>): string {
  const pairs = [...parts].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const hash = createHash("sha256");
  for (const [name, value] of pairs) {
    hash.update(name.replace(/\\/g, "/"));
    hash.update("\0");
    hash.update(value);
    hash.update("\0");
  }
  return hash.digest("hex");
}

/** Every file under `dir`, depth first, as paths relative to it. Directories named in
 *  `skip` (at any depth) are left out, as is a directory `skipDir` rejects, and files
 *  `skipFile` rejects. */
function walk(dir: string, skip: ReadonlySet<string>, skipFile: (rel: string) => boolean = () => false, skipDir: (rel: string) => boolean = () => false): string[] {
  const found: string[] = [];
  const seen = new Set<string>();
  const visit = (path: string, prefix: string): void => {
    // A linked directory is followed, but only once: a workspace package or a link back up
    // the tree would otherwise be walked twice or never end.
    let real: string;
    try {
      real = realpathSync(path);
    } catch {
      return;
    }
    if (seen.has(real)) return;
    seen.add(real);
    for (const name of readdirSync(path)) {
      if (skip.has(name)) continue;
      const child = join(path, name);
      const rel = prefix === "" ? name : prefix + "/" + name;
      const stat = statSync(child);
      if (stat.isDirectory()) {
        if (!skipDir(rel)) visit(child, rel);
        continue;
      }
      if (stat.isFile() && !skipFile(rel)) found.push(rel);
    }
  };
  visit(dir, "");
  return found.sort();
}

/** The digest of a directory's files' contents. */
function hashDirectory(dir: string, skip: ReadonlySet<string>, skipFile?: (rel: string) => boolean, skipDir?: (rel: string) => boolean): string {
  return digestOf(walk(dir, skip, skipFile, skipDir).map((rel) => [rel, hashFile(join(dir, rel))] as const));
}

/** The SDK's own sources: the runtime, the shared CSS parser and the host, whose content
 *  decides both the generated tables and the executable. */
export function sdkDigest(root: string): string {
  const dirs = ["runtime", "shared", "host"];
  const manifest: [string, string][] = [];
  for (const dir of dirs) {
    for (const rel of walk(join(root, dir), new Set(["node_modules"]))) {
      manifest.push([dir + "/" + rel, hashFile(join(root, dir, rel))]);
    }
  }
  return digestOf(manifest);
}

/** The compiler's identity: the native sources, the scriptc version and the compiled
 *  compiler binary. A different compiler must not answer from another one's entries. */
const toolchainDigests = new Map<string, string>();
export function toolchainDigest(root: string): string {
  const hit = toolchainDigests.get(root);
  if (hit !== undefined) return hit;
  const manifest: [string, string][] = [];
  // The compiler's own sources decide how a page becomes generated code.
  // A checkout runs compiler/, and an installed CLI the bundle of it in dist/.
  for (const dir of ["compiler", "dist"]) {
    for (const rel of walk(join(root, dir), new Set(["node_modules", ".native"]))) {
      manifest.push([dir + "/" + rel, hashFile(join(root, dir, rel))]);
    }
  }
  for (const name of ["package.json", "package-lock.json"]) {
    try {
      manifest.push([name, hashFile(join(root, name))]);
    } catch {
      // A checkout without a manifest or a lockfile still builds; it just has one more
      // shared key.
    }
  }
  // The native executable has no compiler/ sources beside it: the executable itself is the
  // compiler, named by its size and modification time like scriptc's below.
  if (NATIVE_BINARY) {
    try {
      const stat = statSync(realpathSync(process.execPath));
      manifest.push(["executable", `${stat.size}:${stat.mtimeMs}`]);
    } catch {
      manifest.push(["executable", process.execPath]);
    }
  }
  // scriptc as the build finds it: installed beside native, hoisted (npm) or nested (pnpm).
  const scriptcDir = installedPackage(root, "scriptc") ?? join(root, "node_modules", "scriptc");
  const scriptc = join(scriptcDir, "package.json");
  try {
    manifest.push(["scriptc/package.json", hashFile(scriptc)]);
  } catch {
    // scriptc may be on PATH; the version it reports is then the only identity it has.
  }
  // The compiler binary is 90 MB: its size and modification time name it without reading it.
  for (const bin of ["scriptc.exe", "scriptc"]) {
    const path = join(scriptcDir, "bin", bin);
    try {
      const stat = statSync(path);
      manifest.push(["scriptc/bin/" + bin, `${stat.size}:${stat.mtimeMs}`]);
      break;
    } catch {
      // The other name, or scriptc isn't installed here.
    }
  }
  manifest.push(["node", process.version], ["platform", process.platform], ["arch", process.arch]);
  const digest = digestOf(manifest);
  toolchainDigests.set(root, digest);
  return digest;
}

/** The build-affecting environment, sorted. */
function environmentDigest(): string {
  const manifest: [string, string][] = [];
  for (const name of Object.keys(process.env).sort()) {
    if (!ENV_PREFIXES.some((prefix) => name.startsWith(prefix)) || ENV_IGNORED.has(name)) continue;
    const value = process.env[name];
    if (value !== undefined) manifest.push([name, value]);
  }
  return digestOf(manifest);
}

/** A digest of the installed dependency tree's file names, sizes and modification times.
 *  This is a fast key: it notices an `npm install`, an added or removed package, or a file
 *  a package's postinstall rewrote. The program key hashes the vendored copies' content. */
function nodeModulesDigest(appDir: string): string {
  const dir = join(appDir, "node_modules");
  if (!existsSync(dir)) return "none";
  const manifest: [string, string][] = [];
  for (const rel of walk(dir, new Set())) {
    const stat = statSync(join(dir, rel));
    manifest.push([rel, `${stat.size}:${stat.mtimeMs}`]);
  }
  const locks: [string, string][] = [];
  for (const lock of [".package-lock.json", "package.json"]) {
    try {
      locks.push([lock, hashFile(join(dir, lock))]);
    } catch {
      // npm's hidden lockfile is optional; a tree installed another way has no lockfile.
    }
  }
  return digestOf([...manifest, ...locks]);
}

/** The fast key's inputs: everything a build reads before it copies or generates a module. */
export function fastManifest(options: CacheOptions): Manifest {
  const { appDir, root } = options;
  const manifest: Manifest = new Map();
  manifest.set("sdk", sdkDigest(root));
  manifest.set("toolchain", toolchainDigest(root));
  manifest.set("environment", environmentDigest());
  // Diagnostics are stored as they were printed, and a terminal gets colours a pipe doesn't.
  manifest.set("tty", String(process.stderr.isTTY === true));
  manifest.set("dependencies", nodeModulesDigest(appDir));
  // The app's own files: the page, styles, images and fonts it names, and its scripts.
  const outName = relative(appDir, resolve(options.out));
  const irName = join(dirname(outName), "entry.ll");
  // A build can put its output inside the app: the executable, its app bundle and its resources
  // directory are outputs, not inputs.
  const ownOutput = (rel: string): boolean =>
    rel === outName || rel === irName ||
    rel === outName + ".app" || rel.startsWith(outName + ".app/") ||
    rel === outName + ".resources" || rel.startsWith(outName + ".resources/");
  manifest.set("app", hashDirectory(
    appDir,
    new Set([".native", "node_modules"]),
    (rel) => {
      // A build's own output is not an input, and a dev session's control files aren't either.
      if (rel.split("/").some((part) => part.startsWith("."))) return true;
      return ownOutput(rel) || rel === outName + ".dSYM";
    },
    // A hidden directory (`.git`, an editor's cache) is never an input, and walking it would
    // cost more than the build. A dev build's dSYM bundle and the app bundle are outputs.
    (rel) => rel.split("/").some((part) => part.startsWith(".")) || ownOutput(rel) || rel === outName + ".dSYM",
  ));
  // A public directory is copied whole, hidden files included (a `.well-known` route, say), so
  // its digest doesn't skip them the way the rest of the app's files above do.
  const publicDir = publicDirOf(appDir);
  if (publicDir !== null) manifest.set("app/public", hashDirectory(publicDir, new Set()));
  manifest.set("app/package.json", existsSync(join(appDir, "package.json")) ? hashFile(join(appDir, "package.json")) : "none");
  manifest.set("app/tsconfig.json", existsSync(join(appDir, "tsconfig.json")) ? hashFile(join(appDir, "tsconfig.json")) : "none");
  manifest.set("page", relative(appDir, resolve(options.input)));
  manifest.set("options", `${options.dev ? "dev" : options.packaged === true ? "packaged" : "plain"}:${resolve(options.out)}`);
  return manifest;
}

/** The fast key of a build. */
export function fastKey(options: CacheOptions): string {
  return digestOf(fastManifest(options));
}

/** Every module the build wrote into `.native`, by logical name, with its content digest.
 *  These are the generated tables, the app's copies, the vendored dependencies and the
 *  declarations copied beside them. */
export function programManifest(buildDir: string): Manifest {
  const manifest: Manifest = new Map();
  const source = join(buildDir, "src");
  if (!existsSync(source)) return manifest;
  for (const rel of walk(source, new Set(["node_modules"]))) {
    manifest.set("src/" + rel, hashFile(join(source, rel)));
  }
  // The dev command's own files are runtime data, not inputs of the program: a state file, a
  // restart token or a ready stamp changes between runs and must not make a new program.
  for (const rel of walk(buildDir, new Set(["src", "node_modules", "cache", "modules.json", "builds.json",
    "dev.json", "dev-state.json", "dev.ctl", "dev-ready", "dev-ready.tmp"]), (name) => {
    const parts = name.split("/");
    return parts.some((part) => part.startsWith(".")) || name.endsWith(".ll") || name.endsWith(".o") || name.endsWith(".key");
  })) {
    manifest.set(rel, hashFile(join(buildDir, rel)));
  }
  return manifest;
}

/** The program key: the fast key plus every module in the build directory. */
export function programKey(fast: string, files: Manifest): string {
  return digestOf([["fast", fast], ...[...files].map(([name, digest]) => [name, digest] as const)]);
}

/**
 * The identity of the program an executable compiles: every input outside the app directory that
 * decides it, and every module the build wrote. The app directory's own files are left out as a
 * whole; the ones that are part of the program are the copies of its scripts in the manifest, so
 * an edit to the page's markup, styles or images leaves the identity alone. A release build
 * carries the page as data beside the executable, so such an edit needs no new executable.
 */
export function programIdentity(options: CacheOptions, files: Manifest): string {
  const parts: [string, string][] = [...files];
  for (const [name, digest] of fastManifest(options)) {
    // The page's own files and the public directory are data the build copies, and the terminal
    // only decides how a diagnostic is coloured.
    if (name === "app" || name === "app/public" || name === "tty") continue;
    parts.push([name, digest]);
  }
  return digestOf(parts);
}

/** The modules whose digests differ between two manifests. */
export function changedModules(before: Manifest, after: Manifest): string[] {
  const changed: string[] = [];
  for (const [name, digest] of after) if (before.get(name) !== digest) changed.push(name);
  for (const name of before.keys()) if (!after.has(name)) changed.push(name);
  return changed.sort();
}

/** One stored build. */
export class BuildCache {
  readonly root: string;
  private readonly entryDir: string;
  private readonly fastDir: string;

  constructor(root: string) {
    this.root = root;
    this.entryDir = join(root, "entries");
    this.fastDir = join(root, "fast");
  }

  /** The cache for a platform, or null when the user turned it off. */
  static open(): BuildCache | null {
    if (!cacheEnabled()) return null;
    try {
      const cache = new BuildCache(cacheRoot());
      mkdirSync(cache.entryDir, { recursive: true });
      mkdirSync(cache.fastDir, { recursive: true });
      return cache;
    } catch {
      // An unwritable cache only costs the next build its hit.
      return null;
    }
  }

  private entryPath(key: string): string {
    return join(this.entryDir, key.slice(0, 2), key);
  }

  /** The entry stored for a fast key, when its program key still names an entry. */
  lookupFast(fast: string): CacheEntry | null {
    try {
      const pointer = JSON.parse(readFileSync(join(this.fastDir, fast + ".json"), "utf8")) as { key?: unknown };
      if (typeof pointer.key !== "string") return null;
      return this.lookup(pointer.key);
    } catch {
      return null;
    }
  }

  /** The entry stored under a program key, if its executable is still there. */
  lookup(key: string): CacheEntry | null {
    try {
      const dir = this.entryPath(key);
      const meta = JSON.parse(readFileSync(join(dir, "meta.json"), "utf8")) as Omit<Partial<CacheEntry>, "files"> & { schema?: number; files?: Record<string, string> };
      if (meta.schema !== SCHEMA || meta.key !== key || typeof meta.fast !== "string") return null;
      const bin = join(dir, "bin");
      if (!existsSync(bin) || statSync(bin).size !== meta.bytes) return null;
      // A hit is a use: the entry's modification time is its place in the eviction order.
      try {
        const now = new Date();
        utimesSync(join(dir, "meta.json"), now, now);
      } catch {
        // An entry that can't be touched is evicted by its old time.
      }
      const files = new Map(meta.files === undefined ? [] : Object.entries(meta.files));
      const assets = Array.isArray(meta.assets)
        ? meta.assets.filter((a): a is BundleFile => a !== null && typeof a === "object" &&
            typeof (a as BundleFile).source === "string" && typeof (a as BundleFile).dest === "string")
        : [];
      return {
        key,
        fast: meta.fast,
        out: typeof meta.out === "string" ? meta.out : "",
        dev: meta.dev === true,
        bytes: typeof meta.bytes === "number" ? meta.bytes : 0,
        summary: typeof meta.summary === "string" ? meta.summary : "",
        diagnostics: typeof meta.diagnostics === "string" ? meta.diagnostics : "",
        stderr: typeof meta.stderr === "string" ? meta.stderr : "",
        files,
        program: typeof meta.program === "string" ? meta.program : "",
        pageTables: existsSync(join(dir, PAGE_TABLES_FILE)),
        assets,
        title: typeof meta.title === "string" ? meta.title : "",
        dir,
      };
    } catch {
      return null;
    }
  }

  /** Stores a build's executable, tables, warnings and manifest. */
  save(entry: { key: string; fast: string; out: string; dev: boolean; bin: string; devData?: string | null; pageData?: string | null; program?: string; summary: string; stderr: string; diagnostics: string; files: Manifest; assets?: readonly BundleFile[]; title?: string }): void {
    const dir = this.entryPath(entry.key);
    const temp = dir + ".tmp-" + process.pid;
    try {
      rmSync(temp, { recursive: true, force: true });
      mkdirSync(temp, { recursive: true });
      copyFileSync(entry.bin, join(temp, "bin"));
      if (entry.dev && entry.devData !== undefined && entry.devData !== null) copyFileSync(entry.devData, join(temp, "dev.json"));
      // A release build's page tables are data in the bundle, so the entry keeps them too: an
      // unchanged build that answers from here still has to write them.
      if (!entry.dev && entry.pageData !== undefined && entry.pageData !== null) copyFileSync(entry.pageData, join(temp, PAGE_TABLES_FILE));
      const meta = {
        schema: SCHEMA,
        key: entry.key,
        fast: entry.fast,
        out: entry.out,
        dev: entry.dev,
        bytes: statSync(join(temp, "bin")).size,
        program: entry.program === undefined ? "" : entry.program,
        summary: entry.summary,
        diagnostics: entry.diagnostics,
        stderr: entry.stderr,
        files: Object.fromEntries(entry.files),
        assets: entry.assets === undefined ? [] : entry.assets,
        title: entry.title === undefined ? "" : entry.title,
        createdAt: Date.now(),
      };
      writeFileSync(join(temp, "meta.json"), JSON.stringify(meta));
      rmSync(dir, { recursive: true, force: true });
      mkdirSync(dirname(dir), { recursive: true });
      renameSync(temp, dir);
      // The pointer goes last, so a reader never finds a fast key whose entry isn't there.
      writeFileSync(join(this.fastDir, entry.fast + ".json"), JSON.stringify({ key: entry.key }));
      this.prune();
    } catch {
      // A failed write only means the next build compiles again.
      rmSync(temp, { recursive: true, force: true });
    }
  }

  /** Copies an entry's executable to `output` and its tables beside the build directory.
   *  The executable is copied rather than linked: a later scriptc build replaces the output,
   *  and the cache's copy must not be the file it replaces. */
  restore(entry: CacheEntry, output: string, devData: string | null): void {
    mkdirSync(dirname(output), { recursive: true });
    // A copy lands under a temporary name and is renamed over the output: a dev session may
    // still be running the previous executable, and writing into a running file fails on Linux.
    const temp = `${output}.native-${process.pid}`;
    copyFileSync(join(entry.dir, "bin"), temp);
    chmodSync(temp, 0o755);
    renameSync(temp, output);
    if (devData !== null && entry.dev && existsSync(join(entry.dir, "dev.json"))) {
      mkdirSync(dirname(devData), { recursive: true });
      const temporary = `${devData}.tmp-${process.pid}`;
      copyFileSync(join(entry.dir, "dev.json"), temporary);
      renameSync(temporary, devData);
    }
  }

  /** Copies an entry's page tables to `dest`, inside a bundle a build is writing. Returns false
   *  when the entry carries none, as a dev build's doesn't. */
  restorePage(entry: CacheEntry, dest: string): boolean {
    const source = join(entry.dir, PAGE_TABLES_FILE);
    if (!existsSync(source)) return false;
    mkdirSync(dirname(dest), { recursive: true });
    // A run that is starting may read the file as it lands, so it is renamed into place.
    const temp = `${dest}.tmp-${process.pid}`;
    copyFileSync(source, temp);
    renameSync(temp, dest);
    return true;
  }

  /** Deletes the least recently used entries while the cache is over its cap. */
  prune(): void {
    const cap = cacheMaxBytes();
    if (cap <= 0) return;
    let total = 0;
    const entries: { dir: string; size: number; at: number }[] = [];
    let buckets: string[] = [];
    try {
      buckets = readdirSync(this.entryDir);
    } catch {
      return;
    }
    for (const bucket of buckets) {
      let names: string[] = [];
      try {
        names = readdirSync(join(this.entryDir, bucket));
      } catch {
        continue;
      }
      for (const name of names) {
        const dir = join(this.entryDir, bucket, name);
        try {
          const path = join(dir, "meta.json");
          const meta = JSON.parse(readFileSync(path, "utf8")) as { bytes?: number };
          const size = (meta.bytes ?? 0) + 4096;
          total += size;
          entries.push({ dir, size, at: statSync(path).mtimeMs });
        } catch {
          // An entry that isn't readable is left for the next prune.
        }
      }
    }
    if (total <= cap) return;
    entries.sort((a, b) => a.at - b.at);
    for (const entry of entries) {
      if (total <= cap) break;
      try {
        rmSync(entry.dir, { recursive: true, force: true });
        total -= entry.size;
      } catch {
        // A directory another process is writing stays.
      }
    }
  }
}

/** Where the cache keeps the manifest the last build wrote, so a dev session can report the
 *  modules an edit changed. It lives with the app, not in the shared cache. */
export function manifestPath(appDir: string): string {
  return join(appDir, ".native", "modules.json");
}

/** The last build's manifest, when it is this app's. */
export function readLastManifest(appDir: string): Manifest | null {
  try {
    const data = JSON.parse(readFileSync(manifestPath(appDir), "utf8")) as { schema?: number; files?: Record<string, string> };
    if (data.schema !== SCHEMA || data.files === undefined) return null;
    return new Map(Object.entries(data.files));
  } catch {
    return null;
  }
}

/** Writes the manifest for the next build (or dev session) to read. */
export function writeManifest(appDir: string, files: Manifest): void {
  try {
    mkdirSync(join(appDir, ".native"), { recursive: true });
    writeFileSync(manifestPath(appDir), JSON.stringify({ schema: SCHEMA, files: Object.fromEntries(files) }));
  } catch {
    // The manifest only feeds the change report.
  }
}

/** What the build that wrote an executable compiled, so a later build can tell whether that
 *  executable is still the program it needs. */
export interface BuildRecord {
  /** The program's identity (see programIdentity). */
  program: string;
  /** The executable's size and modification time, which name the file the build wrote. */
  size: number;
  mtimeMs: number;
  /** How long the compile that wrote it took, in milliseconds: the next build's progress
   *  estimate. Absent on records written before it was kept. */
  scriptcMs?: number;
}

function buildRecordsPath(appDir: string): string {
  return join(appDir, ".native", "builds.json");
}

/** The record a build left for `output`, or null when there isn't one this compiler wrote. */
export function readBuildRecord(appDir: string, output: string): BuildRecord | null {
  try {
    const data = JSON.parse(readFileSync(buildRecordsPath(appDir), "utf8")) as { schema?: number; outputs?: Record<string, Partial<BuildRecord>> };
    if (data.schema !== SCHEMA || data.outputs === undefined || typeof data.outputs !== "object") return null;
    const hit = data.outputs[output];
    if (hit === undefined || typeof hit.program !== "string" || typeof hit.size !== "number" || typeof hit.mtimeMs !== "number") return null;
    const record: BuildRecord = { program: hit.program, size: hit.size, mtimeMs: hit.mtimeMs };
    if (typeof hit.scriptcMs === "number") record.scriptcMs = hit.scriptcMs;
    return record;
  } catch {
    return null;
  }
}

/** Records the program an output's executable was built from. The record only lets a later build
 *  skip scriptc, so one that can't be read or written costs a build and nothing else. */
export function writeBuildRecord(appDir: string, output: string, record: BuildRecord): void {
  const file = buildRecordsPath(appDir);
  const outputs: Record<string, BuildRecord> = {};
  try {
    const data = JSON.parse(readFileSync(file, "utf8")) as { schema?: number; outputs?: Record<string, BuildRecord> };
    if (data.schema === SCHEMA && data.outputs !== undefined && typeof data.outputs === "object") Object.assign(outputs, data.outputs);
  } catch {
    // No record yet, or one this compiler can't read: this build starts it.
  }
  // A cache hit rewrites the record without a compile; the compile that last took time still
  // times the next build's progress estimate.
  const previous = outputs[output];
  outputs[output] = record.scriptcMs === undefined && previous !== undefined && typeof previous.scriptcMs === "number"
    ? { ...record, scriptcMs: previous.scriptcMs }
    : record;
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, JSON.stringify({ schema: SCHEMA, outputs }));
  } catch {
    // The record only feeds the next build's skip.
  }
}

/** A short display name for a module in the change report: vendored copies keep the
 *  package's own path, app modules keep theirs, and generated modules are left out. */
export function moduleName(logical: string): string {
  return logical.replace(/^src\/deps\//, "").replace(/^src\//, "");
}

/** A list for a log line, shortened when it would fill a terminal. */
export function summarizeModules(names: string[], limit = 4): string {
  if (names.length <= limit) return names.join(", ");
  return `${names.slice(0, limit).join(", ")} and ${names.length - limit} more`;
}

