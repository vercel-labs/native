// The cached dev host: a compiled executable holding the whole SDK runtime — the DOM, CSS,
// layout, paint and host — and no app code. It mounts whatever page tables the dev data file
// holds, and runs whatever script bundle it is told to, in a Node island. Built once per SDK
// sources, scriptc build, libnode pack, host toolchain and platform, it is shared by every app on
// the machine, so a new app's first `native dev` only formats its own tables.

import { closeSync, existsSync, mkdirSync, openSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { cacheRoot, hashFile, sdkDigest } from "./cache.ts";
import { buildHostObjects, devBootSource, findScriptc, hostBuildKey, linkScriptcTypes, nodeEnvDefine, nodeTypesInstalled, runScriptc, writeProjectTsconfig, type ScriptcResult } from "./build.ts";
import { domGlobalsModule, runtimeClassNames, runtimeValueNames } from "./dom-globals.ts";
import { GLOBALS } from "./globals.ts";
import { compileApp } from "./compile.ts";
import { Diagnostics } from "./diagnostics.ts";
import { installedPackage } from "./installed.ts";
import { importPath } from "./scripts.ts";
import { BuildProgress } from "./progress.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RUNTIME = join(ROOT, "runtime");

/** A change to the host's generated sources bumps this: an old host answers nothing new. */
export const DEV_HOST_VERSION = 7;

/** The page the host compiles its placeholder tables from: an empty document. The dev data file
 *  replaces them before the first frame. */
const EMPTY_PAGE = "<!doctype html><html><head><title></title></head><body></body></html>";

/** Whether scriptc's Node.js load hook (`@scriptc/experimental/register`) is installed. The
 *  island imports it before any app bundle, so the unsupported builtins and native addons a build
 *  refuses are refused in dev too. An older install without the package keeps working without
 *  the guard instead of failing to start. */
export function scriptcRegisterInstalled(): boolean {
  try {
    createRequire(import.meta.url).resolve("@scriptc/experimental/register");
    return true;
  } catch {
    return false;
  }
}

/** The package the island imports for the load hook, linked into the host's own node_modules so
 *  the host build ships it (an island module names modules by package name or literal path). */
function linkScriptcRegister(buildDir: string): void {
  const link = join(buildDir, "node_modules", "@scriptc", "experimental");
  const target = installedPackage(ROOT, join("@scriptc", "experimental")) ?? join(ROOT, "node_modules", "@scriptc", "experimental");
  const linkType: "dir" | "junction" = process.platform === "win32" ? "junction" : "dir";
  let current: string | null = null;
  try {
    current = readlinkSync(link);
  } catch {
    current = null;
  }
  if (current !== null && resolve(current) === resolve(target)) return;
  rmSync(link, { force: true, recursive: true });
  mkdirSync(dirname(link), { recursive: true });
  symlinkSync(target, link, linkType);
}

/** The libnode pack's package name for this platform, or null on one no pack ships for. */
export function libnodePackageName(): string | null {
  if (process.platform !== "darwin" && process.platform !== "linux") return null;
  if (process.arch !== "arm64" && process.arch !== "x64") return null;
  if (process.platform === "darwin") return `@scriptc/libnode-darwin-${process.arch}`;
  const report = process.report?.getReport() as { header?: { glibcVersionRuntime?: string } } | undefined;
  return `@scriptc/libnode-linux-${process.arch}-${report?.header?.glibcVersionRuntime ? "gnu" : "musl"}`;
}

// ---------------------------------------------------------------------------
// The prebuilt dev host: a host built by the release pipeline on each platform, shipped in an
// optional package. A new install starts `native dev` without compiling the host; a checkout, a
// modified SDK or a platform with no package falls back to building one here.

/** The manifest schema a prebuilt host package's host.json carries. */
export const PREBUILT_SCHEMA = "native.dev-host.v1";

/** The libc a Linux host is built against, or null on a platform that has no libc split. */
export function devHostLibc(platform: NodeJS.Platform = process.platform): string | null {
  if (platform !== "linux") return null;
  const report = process.report?.getReport() as { header?: { glibcVersionRuntime?: string } } | undefined;
  return report?.header?.glibcVersionRuntime ? "glibc" : "musl";
}

/** The optional package that ships this platform's prebuilt dev host, or null where there is
 *  none. The name is the platform key the release pipeline builds: darwin-arm64, darwin-x64,
 *  linux-x64, linux-arm64 and win32-x64. */
export function prebuiltPackageName(platform: NodeJS.Platform = process.platform, arch: string = process.arch,
                                    libc: string | null = devHostLibc()): string | null {
  if (platform === "darwin" && (arch === "arm64" || arch === "x64")) return `@native-sdk/dev-host-darwin-${arch}`;
  // A Linux host links the system's glibc: a musl machine builds its own instead.
  if (platform === "linux" && (arch === "arm64" || arch === "x64") && libc === "glibc") return `@native-sdk/dev-host-linux-${arch}`;
  if (platform === "win32" && arch === "x64") return `@native-sdk/dev-host-win32-x64`;
  return null;
}

/** The file name a host executable has on this platform. */
export function hostExecutableName(platform: NodeJS.Platform = process.platform): string {
  return platform === "win32" ? "host.exe" : "host";
}

/** The identity of an SDK tree's dev host: the runtime, shared and host sources the host
 *  compiles, and the compiler bundle that generates its sources. A prebuilt host answers only
 *  for the exact SDK it was built from; the CLI's version is the same on both sides, but a
 *  checkout can carry sources a published package does not. */
const sourceDigests = new Map<string, string>();
export function devHostSourceDigest(root: string): string {
  const hit = sourceDigests.get(root);
  if (hit !== undefined) return hit;
  const hash = createHash("sha256");
  hash.update("native-dev-host-sources\0");
  hash.update(sdkDigest(root));
  hash.update("\0");
  // An installed CLI ships dist/native.js; a source checkout may have no dist, and no published
  // host can match it either way.
  try {
    hash.update(hashFile(join(root, "dist", "native.js")));
  } catch {
    hash.update("no-dist");
  }
  const digest = hash.digest("hex");
  sourceDigests.set(root, digest);
  return digest;
}

/** For tests: forget source digests memoized by devHostSourceDigest. */
export function forgetDevHostSourceDigest(): void {
  sourceDigests.clear();
}

/** A prebuilt dev host package's manifest, as host.json writes it. */
export interface PrebuiltManifest {
  schema: string;
  /** The CLI version the package was released with. */
  version: string;
  /** The SDK source digest (devHostSourceDigest) it was built from. */
  sdk: string;
  /** The ABI of the libnode pack it was built against (libnodeAbiIdentity): a pack of another
   *  ABI cannot load into it. */
  libnodeAbi: string;
  devHostVersion: number;
  platform: string;
  arch: string;
  libc: string | null;
  executable: string;
  bytes: number;
}

export interface PrebuiltDevHost {
  executable: string;
  packageName: string;
  packageDir: string;
  version: string;
  manifest: PrebuiltManifest;
}

/** Reads and validates a prebuilt host package directory: its manifest names this platform, this
 *  SDK and this host version, and its executable is the size the manifest recorded. */
export function readPrebuiltHost(dir: string, packageName: string): PrebuiltDevHost | null {
  let manifest: PrebuiltManifest;
  try {
    manifest = JSON.parse(readFileSync(join(dir, "host.json"), "utf8")) as PrebuiltManifest;
  } catch {
    return null;
  }
  if (manifest === null || typeof manifest !== "object") return null;
  if (manifest.schema !== PREBUILT_SCHEMA) return null;
  if (manifest.devHostVersion !== DEV_HOST_VERSION) return null;
  if (manifest.platform !== process.platform || manifest.arch !== process.arch) return null;
  if ((manifest.libc ?? null) !== devHostLibc()) return null;
  if (manifest.sdk !== devHostSourceDigest(ROOT)) return null;
  // A libnode pack of another ABI cannot load the host's Node islands. A patch of the same ABI
  // is fine, and the CLI's npm range may resolve one.
  if (manifest.libnodeAbi !== libnodeAbiIdentity()) return null;
  // The manifest names a file inside the package, never a path: a package cannot point elsewhere.
  const name = typeof manifest.executable === "string" && manifest.executable !== "" ? manifest.executable : hostExecutableName();
  if (name !== basename(name) || name === "." || name === "..") return null;
  const executable = join(dir, name);
  try {
    const stat = statSync(executable);
    if (!stat.isFile()) return null;
    if (stat.size !== manifest.bytes) return null;
    if (process.platform !== "win32" && (stat.mode & 0o111) === 0) return null;
  } catch {
    return null;
  }
  return { executable, packageName, packageDir: dir, version: String(manifest.version ?? ""), manifest };
}

/** The prebuilt host this machine's install ships, when one is installed and matches this SDK. */
export function prebuiltDevHost(): PrebuiltDevHost | null {
  const packageName = prebuiltPackageName();
  if (packageName === null) return null;
  const dir = installedPackage(ROOT, packageName);
  if (dir === null) return null;
  return readPrebuiltHost(dir, packageName);
}

export interface LibnodePack {
  /** The pack's directory (SCRIPTC_LIBNODE names one outright). */
  dir: string;
  /** Its manifest.json, byte for byte. */
  manifest: Buffer;
}

/** The libnode pack this machine runs islands on, or null when none is installed. */
export function libnodePack(): LibnodePack | null {
  const named = process.env["SCRIPTC_LIBNODE"];
  let dir: string | null;
  if (named !== undefined && named !== "") dir = named;
  else {
    const pkg = libnodePackageName();
    if (pkg === null) return null;
    dir = installedPackage(ROOT, pkg);
  }
  if (dir === null || !existsSync(join(dir, "manifest.json"))) return null;
  const manifest = readFileSync(join(dir, "manifest.json"));
  // A pack for another platform or architecture is no pack here: linking it would mix ABIs.
  try {
    const data = JSON.parse(manifest.toString("utf8")) as { platform?: string; arch?: string };
    if (data.platform !== undefined && data.platform !== process.platform) return null;
    if (data.arch !== undefined && data.arch !== process.arch) return null;
  } catch {
    return null;
  }
  return { dir, manifest };
}

/** The digest of a libnode pack's manifest, or "no-libnode": the shortest name for the pack a
 *  host was built against. A different build of the pack is a different host. */
export function libnodePackDigest(pack: LibnodePack | null = libnodePack()): string {
  return pack === null ? "no-libnode" : createHash("sha256").update(pack.manifest).digest("hex");
}

/** The ABI a libnode pack offers, as the manifest states it: the bridge ABI and Node's module
 *  version. A prebuilt host built against the same ABI loads into a later patch of the pack,
 *  while a pack of another ABI does not. */
export function libnodeAbiIdentity(pack: LibnodePack | null = libnodePack()): string {
  if (pack === null) return "no-libnode";
  try {
    const data = JSON.parse(pack.manifest.toString("utf8")) as { bridgeAbi?: unknown; moduleVersion?: unknown };
    if (data.bridgeAbi === undefined || data.moduleVersion === undefined) return "no-libnode";
    return `${data.bridgeAbi}:${data.moduleVersion}`;
  } catch {
    return "no-libnode";
  }
}

/** The scriptc executable's identity: its path, size and mtime. A different build of the
 *  compiler must not answer from a host it built. */
function scriptcIdentity(): string {
  const path = findScriptc();
  try {
    const st = statSync(path);
    return `${path}\0${st.size}\0${st.mtimeMs}`;
  } catch {
    // Not a file on this machine (a name on PATH): its path is all there is to key on.
    return path;
  }
}

/** The key of the dev host this machine would build: every input that changes its code. The
 *  digest is taken once per process (the second `native dev` of a session answers in
 *  milliseconds); forgetDevHostKey() exists for tests that change an input. */
let memoKey: string | null = null;

export function forgetDevHostKey(): void {
  memoKey = null;
}

export function devHostKey(): string {
  return (memoKey ??= computeDevHostKey());
}

function computeDevHostKey(): string {
  const hash = createHash("sha256");
  hash.update(`native-dev-host\0${DEV_HOST_VERSION}\0${process.platform}\0${process.arch}\0`);
  // The whole SDK runtime and host, by content.
  hash.update(sdkDigest(ROOT));
  hash.update("\0");
  hash.update(scriptcIdentity());
  hash.update("\0");
  hash.update(libnodePackDigest());
  hash.update("\0");
  // The load hook the island imports: a different install (or none) is a different host.
  hash.update(scriptcRegisterInstalled() ? "@scriptc/experimental/register" : "no-register");
  hash.update("\0");
  // The host objects' sources and toolchain. The directory is a constant: object paths are not
  // part of the key, only the sources and the commands that compile them.
  hash.update(hostBuildKey(join(cacheRoot(), "dev-host", "objects")));
  return hash.digest("hex");
}

/** The directory a host build lives in, under the build cache (NATIVE_CACHE_DIR is honored). */
export function devHostDir(): string {
  return join(cacheRoot(), "dev-host", devHostKey());
}

/** The globals module: one compiled shared module that both sides import (NI-6). Every name is
 *  bound to a local const from the runtime module that exports it, because a re-export
 *  (`export { X } from "…"`) is not shared at all: the island would see no keys. */
export function devGlobalsSource(dir: string): { source: string; names: string[] } {
  const lines = [
    "// Generated by native: the page's globals, in one module both the program and its Node",
    "// islands import. Each is a local const so the value crosses; a re-export would not.",
  ];
  const names: string[] = [];
  const seen = new Set<string>();
  // Absolute paths: the host's build directory is in the cache, which can sit on another volume
  // from the SDK, and a relative specifier across volumes resolves to nothing.
  const runtimeModule = (file: string): string => join(RUNTIME, file).split("\\").join("/");
  GLOBALS.forEach((entry, index) => {
    // Every name user code may refer to, sorted by what the module actually declares: a class
    // listed among the types (Window, NodeList) is a value the island needs, and a type listed
    // among the values (ValidityStateFlags is an interface) would fail to bind.
    const listed = runtimeValueNames(RUNTIME, entry.file, [...new Set([...entry.values, ...entry.types])]);
    // Every class the module declares, too: an object of a class no global names (DOMTokenList,
    // from `element.classList`) comes back from a getter or a method, and the island needs its
    // method table registered to answer it.
    const values = [...new Set([...listed, ...runtimeClassNames(RUNTIME, entry.file)])].filter(
      (name) => !seen.has(name),
    );
    if (values.length === 0) return;
    lines.push(`import * as M${index} from ${JSON.stringify(runtimeModule(entry.file))};`);
    for (const name of values) {
      seen.add(name);
      lines.push(`export const ${name} = M${index}.${name};`);
      names.push(name);
    }
  });
  // The page's inline handler attributes call this from island code: a compiled function that
  // attaches the island's handler to the element the compiled tables' index names.
  lines.push(`export { attachHandler } from ${JSON.stringify(runtimeModule("app.ts"))};`);
  return { source: lines.join("\n") + "\n", names };
}

/** The island's side of the dev loop: installs the page's globals on the island's global
 *  object, runs each script bundle, and resets everything a bundle made before the next one. */
function islandLoaderSource(names: string[], register: boolean): string {
  return `// Generated by native dev. Runs the page's scripts in the island: the globals first, then
// each bundle the dev command writes, and a clean slate before the next one.
import { readFileSync } from "node:fs";
import vm from "node:vm";

// Through process.getBuiltinModule rather than a static import: the island's modules may load
// only what the build can ship, and this require is bound to the dev bundle the dev command
// writes outside the program.
const moduleApi = process.getBuiltinModule("node:module");
${register ? `// scriptc's Node.js load hook: the unsupported builtins and native addons a build refuses are
// refused here, with the compiler's own diagnostics. Installed before any app bundle loads.
import "@scriptc/experimental/register";
` : ""}import * as G from "./dev-globals.ts";

const NAMES = ${JSON.stringify(names)};
const root = globalThis;

/** Node's own lazy globals (Event, MessageEvent, WebSocket, navigator) are getter-only
 *  accessors; the delete is required, and touching them in the wrong order initializes
 *  undici against an Event that is already gone. */
function def(name, value) {
  try { delete root[name]; } catch {}
  Object.defineProperty(root, name, { value, writable: true, configurable: true });
}

const timeouts = new Set();
const intervals = new Set();
const immediates = new Set();
const nodeSetTimeout = globalThis.setTimeout;
const nodeSetInterval = globalThis.setInterval;
const nodeSetImmediate = globalThis.setImmediate;
const nodeClearTimeout = globalThis.clearTimeout;
const nodeClearInterval = globalThis.clearInterval;
const nodeClearImmediate = globalThis.clearImmediate;
let baseline = new Set();
// What a compiled program answers for eval, Function and a function's constructor (the
// compiler's CODE_GENERATION_DISALLOWED text). The embedded Node cannot be given Node's
// --disallow-code-generation-from-strings, so the globals refuse instead.
const CODE_GENERATION_DISALLOWED = "Code generation from strings disallowed for this context";
const FunctionPrototype = Function.prototype;
const EvalErrorCtor = EvalError;
function refuseCodeGeneration() {
  throw new EvalErrorCtor(CODE_GENERATION_DISALLOWED);
}

/** Node's timers, recorded so a reset clears what the last bundle left running: the runtime's
 *  \`resetPage\` clears the DOM's timers, but not these. */
function install() {
  def("setTimeout", (fn, ms, ...args) => {
    const handle = nodeSetTimeout(() => { timeouts.delete(handle); if (typeof fn === "function") fn(...args); }, ms);
    timeouts.add(handle);
    return handle;
  });
  def("setInterval", (fn, ms, ...args) => {
    const handle = nodeSetInterval(fn, ms, ...args);
    intervals.add(handle);
    return handle;
  });
  def("setImmediate", (fn, ...args) => {
    const handle = nodeSetImmediate(() => { immediates.delete(handle); if (typeof fn === "function") fn(...args); });
    immediates.add(handle);
    return handle;
  });
  def("clearTimeout", (handle) => { timeouts.delete(handle); nodeClearTimeout(handle); });
  def("clearInterval", (handle) => { intervals.delete(handle); nodeClearInterval(handle); });
  def("clearImmediate", (handle) => { immediates.delete(handle); nodeClearImmediate(handle); });
  def("eval", refuseCodeGeneration);
  def("Function", refuseCodeGeneration);
  try {
    Object.defineProperty(FunctionPrototype, "constructor", {
      value: refuseCodeGeneration, writable: true, configurable: true,
    });
  } catch {}
  for (const name of NAMES) def(name, G[name]);
  def("__nativeAttachHandler", G.attachHandler);
  def("window", G.window);
  def("self", G.self);
}

/** An error as the dev output shows it: the stack, with the diagnostic code when the island
 *  refused something the way a build does (SC1010 for an unsupported builtin, SC2020 for a
 *  native addon). */
function describeError(error) {
  const text = error && error.stack ? error.stack : String(error);
  return error && typeof error.code === "string" ? "[" + error.code + "] " + text : text;
}

let installed = false;
let reporting = false;

export function installGlobals() {
  if (!installed) {
    installed = true;
    try { process.setSourceMapsEnabled(true); } catch {}
    // One bundle's throw used to end the host (seen in the prototype): report it and keep the
    // window, as the runtime does for the compiled program.
    if (!reporting) {
      reporting = true;
      process.on("uncaughtException", (error) => {
        process.stderr.write("native: Uncaught " + describeError(error) + "\\n");
      });
      process.on("unhandledRejection", (reason) => {
        process.stderr.write("native: Unhandled rejection " + describeError(reason) + "\\n");
      });
    }
    install();
    baseline = new Set(Object.keys(root));
  } else {
    install();
  }
}

/** Runs a bundle: "" or the error's stack, with the page left as it was. The bundle is a
 *  classic script in this context. Node's require is installed bound to the bundle's directory
 *  first, so a Node builtin or native addon it reaches is loaded under scriptc's load hook (and
 *  refused with the compiler's diagnostic where a build refuses it); a dynamic import it makes
 *  runs through this context's loader, so the same hook sees it. */
export function run(file) {
  if (file === "") return "";
  let source;
  try {
    source = readFileSync(file, "utf8");
  } catch (error) {
    return describeError(error);
  }
  try {
    def("require", moduleApi.createRequire(file));
    const importDynamically =
      vm.constants && vm.constants.USE_MAIN_CONTEXT_DEFAULT_LOADER
        ? { importModuleDynamically: vm.constants.USE_MAIN_CONTEXT_DEFAULT_LOADER }
        : {};
    new vm.Script(source, { filename: file, ...importDynamically }).runInThisContext();
    return "";
  } catch (error) {
    return describeError(error);
  }
}

/** Clears what the last bundle left: its timers, and the globals it created. */
export function reset() {
  for (const handle of timeouts) nodeClearTimeout(handle);
  for (const handle of intervals) nodeClearInterval(handle);
  for (const handle of immediates) nodeClearImmediate(handle);
  timeouts.clear();
  intervals.clear();
  immediates.clear();
  for (const name of Object.keys(root)) {
    if (baseline.has(name)) continue;
    try { delete root[name]; } catch {}
  }
  install();
}
`;
}

/** The host's own module: the runtime, the page's globals, and the island the app runs in. */
export function devHostSource(dir: string): string {
  return [
    "// Generated by native dev. The SDK runtime with no app code: it mounts the page the dev",
    "// command's tables describe and runs the app's scripts in the Node island.",
    'import "./boot.ts";',
    'import "./dom-globals.ts";',
    'import "./dev-globals.ts";',
    // The host's FFI manifest names every native function, and each is declared in this module:
    // a function only a frame-times path calls is unreachable otherwise.
    `import ${JSON.stringify(join(RUNTIME, "host.ts").split("\\").join("/"))};`,
    'import { requireModule } from "@scriptc/node";',
    `import { run } from ${JSON.stringify(join(RUNTIME, "app.ts").split("\\").join("/"))};`,
    `import { onScripts } from ${JSON.stringify(join(RUNTIME, "app/dev.ts").split("\\").join("/"))};`,
    'const loader = requireModule("./island-loader.mjs");',
    "loader.installGlobals();",
    "onScripts(loader);",
    "run();",
    "",
  ].join("\n");
}

export interface DevHost {
  /** The host executable to run. */
  executable: string;
  /** True when this call built it; false when one was already there. */
  built: boolean;
  /** Where the executable came from: the package the release pipeline shipped, or a build here. */
  prebuilt: boolean;
}

export interface EnsureHostOptions {
  /** The pack to build against; defaults to libnodePack(). */
  pack?: LibnodePack;
  /** Builds even when a host is cached (used by the tests). */
  force?: boolean;
  /** Whether a shipped prebuilt host may answer; false makes this build one (the release job). */
  prebuilt?: boolean;
}

/** The file name an acknowledgement of `token` is written to, beside the scripts token. */
export function ackPath(scriptsTokenFile: string, token: string): string {
  return `${scriptsTokenFile}.${token}.ack`;
}

/** Builds the dev host unless this machine already has this one, and answers its executable.
 *  Two `native dev` sessions starting together build one host: the second waits on the lock and
 *  then finds the first one's. */
export async function ensureDevHost(log: (message: string) => void, options: EnsureHostOptions = {}): Promise<DevHost> {
  // A host the release pipeline built for this exact SDK answers first: it is the difference
  // between a first `native dev` that opens at once and one that compiles the whole runtime.
  if (!options.force && options.prebuilt !== false) {
    const shipped = prebuiltDevHost();
    if (shipped !== null) {
      log(`using the prebuilt dev host from ${shipped.packageName}@${shipped.version}`);
      return { executable: shipped.executable, built: false, prebuilt: true };
    }
  }
  const pack = options.pack ?? libnodePack();
  if (pack === null) throw new Error("native: no @scriptc/libnode-<platform> pack is installed");
  const dir = devHostDir();
  const executable = join(dir, hostExecutableName());
  const key = devHostKey();
  const ready = (): DevHost | null =>
    existsSync(executable) && existsSync(join(dir, "ok")) && readFileSync(join(dir, "ok"), "utf8") === key
      ? { executable, built: false, prebuilt: false }
      : null;
  if (!options.force) {
    const hit = ready();
    if (hit !== null) return hit;
  }

  const lock = `${dir}.lock`;
  mkdirSync(dirname(dir), { recursive: true });
  const deadline = Date.now() + 10 * 60 * 1000;
  let held = false;
  while (!held) {
    try {
      closeSync(openSync(lock, "wx"));
      held = true;
    } catch {
      // Another session is building this host. When it finishes, its host answers this one too.
      const hit = options.force ? null : ready();
      if (hit !== null) return hit;
      if (Date.now() > deadline) throw new Error("native: timed out waiting for another session's dev host build");
      // A synchronous sleep: the build this waits for runs in another process.
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
    }
  }

  try {
    const hit = options.force ? null : ready();
    if (hit !== null) return hit;
    const started = performance.now();
    log("building the dev host (once per SDK version)…");
    mkdirSync(join(dir, "node_modules", "@scriptc"), { recursive: true });
    writeFileSync(join(dir, "package.json"), '{ "type": "module" }\n');
    linkScriptcTypes(dir);
    // The island's package: the same install the app's build would resolve.
    const node = installedPackage(ROOT, "@scriptc/node");
    if (node === null) throw new Error("native: @scriptc/node is not installed beside the CLI");
    const nodeLink = join(dir, "node_modules", "@scriptc", "node");
    rmSync(nodeLink, { force: true, recursive: true });
    symlinkSync(node, nodeLink, process.platform === "win32" ? "junction" : "dir");
    writeProjectTsconfig(dir, "./host.ts");
    writeFileSync(join(dir, "dom-globals.ts"), domGlobalsModule(RUNTIME, nodeTypesInstalled(dir)));
    // The placeholder page's tables, so the host mounts before the dev data file arrives.
    const emptyPage = join(dir, "empty.html");
    writeFileSync(emptyPage, EMPTY_PAGE + "\n");
    const tables = compileApp(emptyPage, new Diagnostics());
    rmSync(emptyPage, { force: true });
    writeFileSync(join(dir, "gen.ts"), tables.genSource);
    writeFileSync(join(dir, "boot.ts"), devBootSource(dir, true));
    const globals = devGlobalsSource(dir);
    writeFileSync(join(dir, "dev-globals.ts"), globals.source);
    const withRegister = scriptcRegisterInstalled();
    if (withRegister) linkScriptcRegister(dir);
    writeFileSync(join(dir, "island-loader.mjs"), islandLoaderSource(globals.names, withRegister));
    writeFileSync(join(dir, "host.ts"), devHostSource(dir));
    const progress = new BuildProgress();
    progress.phase("host");
    buildHostObjects(dir);
    const args = ["build", join(dir, "host.ts"), "--ffi", join(dir, "ffi.json"), "--optimization", "release",
                  "--define", nodeEnvDefine(true), "-o", executable];
    // The compiler's LLVM helper fails without a reason now and then under load: a SC3004, or a
    // death that leaves the compiler with no exit status and no output (a helper the kernel
    // killed, or a pipe the helper's death closed). The same build compiles on a retry.
    const compile = (): Promise<ScriptcResult> => {
      progress.beginScriptc();
      return runScriptc(args, { SCRIPTC_LIBNODE: pack.dir, SCRIPTC_TIMING: "1" },
                        (event) => progress.scriptc(event.phase));
    };
    const crashed = (r: ScriptcResult): boolean => r.status === null || `${r.stdout}${r.stderr}`.includes("SC3004");
    let sc;
    try {
      sc = await compile();
      for (let retry = 0; retry < 2 && crashed(sc); retry++) sc = await compile();
    } catch (err) {
      progress.fail();
      throw err;
    }
    const said = `${sc.stdout}${sc.stderr}`.trim();
    if (sc.status !== 0) {
      progress.fail();
      if (said !== "") process.stderr.write(said + "\n");
      const first = said.split("\n").find((line) => /^\S+:\d+:\d+: error|^error\b|fatal/i.test(line)) ?? "";
      const how = sc.error !== undefined ? sc.error.message
        : sc.signal !== null && sc.signal !== undefined ? `killed by ${sc.signal}`
        : `exit ${sc.status}`;
      throw new Error(`native: failed to build the dev host: ${how}${first === "" ? "" : " — " + first}`);
    }
    progress.finish();
    // The dev host holds the SDK and no app code, so every warning the compiler printed is about
    // the SDK's own runtime: ours to fix, not the app author's. A build leaves those out too
    // (see withoutSdkWarnings); NATIVE_SDK_WARNINGS=1 shows them.
    if (said !== "" && process.env.NATIVE_SDK_WARNINGS === "1") process.stderr.write(said + "\n");
    writeFileSync(join(dir, "ok"), key);
    log(`built the dev host in ${((performance.now() - started) / 1000).toFixed(1)}s`);
    return { executable, built: true, prebuilt: false };
  } finally {
    if (held) rmSync(lock, { force: true });
  }
}

/** For tests and diagnostics: where a host's build key and directory are, without building it. */
export function devHostInfo(): { key: string; dir: string; pack: LibnodePack | null } {
  return { key: devHostKey(), dir: devHostDir(), pack: libnodePack() };
}
