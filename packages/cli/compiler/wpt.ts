// native wpt: runs web-platform-tests reftests and check-layout tests against native.
//
//   native wpt fetch                    sparse-clone WPT into ~/.cache/native/wpt (or $NATIVE_WPT)
//   native wpt run [dir...] [options]   run tests under the given WPT directories
//   native wpt show <test>              render one test, its reference and their diff into a PNG
//       --filter <regex>   only tests whose path matches
//       --batch <n>        pages per compiled runner binary (default 100)
//       --jobs <n>         batches built and run in parallel (default: CPU count - 2, at most 8)
//       --out <file>       results JSON (default wpt/results.json)
//       --verbose          print every failure
//
// Every page goes through the normal native compiler. A page (or its reference) that hits an
// unsupported feature is skipped with that feature as the reason, so the report is an honest map
// of what's missing. Runnable pages are compiled in batches into one native runner per batch.

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync, rmSync, symlinkSync, copyFileSync, chmodSync, renameSync } from "node:fs";
import { dirname, join, relative, resolve, extname, basename } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { homedir, availableParallelism, freemem } from "node:os";
import { deflateSync } from "node:zlib";
import { createHash } from "node:crypto";
import { Diagnostics, type Diagnostic } from "./diagnostics.ts";
import { applyHostLink, buildTarget, hostCommonCompileCommand, hostCompileCommand, hostCompositorCompileCommand, hostSource, hostSources, hostSourceDigest, isCompositorBackend, prepareMetalShaders, MACOS } from "./native-host.ts";
import { compileApp, type CompiledApp } from "./compile.ts";
import { TABLE_FIELDS as FIELDS } from "./fields.ts";
import { implicitGlobals, namedAccess, topLevelDeclarations, windowAliases, windowVarAliases, withDomImports } from "./scripts.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RUNTIME = join(ROOT, "runtime");
const HOST = join(ROOT, "host");
const WPT = process.env.NATIVE_WPT ?? join(homedir(), ".cache", "native", "wpt");
const WORK = join(ROOT, ".wpt-work");
const VIEW_W = 800;
const VIEW_H = 600;

// Both hosts paint: macOS into a window, Linux into an offscreen Cairo surface for headless runs.
const HOST_SOURCE = hostSource(HOST);

export const DEFAULT_DIRS = [
  "css/css-flexbox", "css/CSS2/normal-flow", "css/CSS2/box-display", "css/CSS2/margin-padding-clear",
  "css/CSS2/colors", "css/CSS2/backgrounds", "css/selectors", "css/css-cascade",
  "css/css-box", "css/css-overflow", "css/css-backgrounds", "css/css-images",
  "css/CSS2/tables", "css/css-tables", "css/CSS2/floats", "css/CSS2/floats-clear", "css/css-transforms",
  "css/css-lists",
  "css/css-sizing", "css/css-position", "css/css-variables", "css/css-grid", "css/mediaqueries",
  "css/css-conditional/container-queries",
  "css/css-transitions", "css/css-animations",
  "css/filter-effects", "css/compositing", "css/css-masking",
  "css/css-pseudo", "css/css-ui", "css/css-color", "css/css-display",
  "css/css-contain", "css/css-will-change", "css/css-easing", "css/css-nesting",
  "css/css-counter-styles", "css/css-shapes", "css/css-scrollbars", "css/css-overscroll-behavior", "css/cssom",
  "css/css-text", "css/css-fonts", "css/css-text-decor", "css/css-writing-modes", "css/css-inline",
  "css/css-values",
  "css/css-align", "css/css-logical", "css/css-multicol", "css/css-break", "css/css-page",
  "css/css-properties-values-api", "css/cssom-view", "css/css-scroll-snap",
  "dom", "domparsing", "shadow-dom", "html/dom", "html/webappapis",
  // The accessibility suites: roles and accessible names, answered by runtime/a11y.ts through
  // test_driver.get_computed_role and get_computed_label.
  "accname", "html-aam", "wai-aria",
];

/** The directories a full (hourly) run adds, selected with `--set extended` or
 *  NATIVE_WPT_EXTENDED=1: the slower html areas. A per-merge gate leaves them out. */
export const EXTENDED_DIRS = ["html/semantics", "html/syntax", "html/rendering"];

const SPARSE = [...DEFAULT_DIRS, ...EXTENDED_DIRS, "css/support", "css/reference", "css/CSS2/support",
  "css/CSS2/reference", "resources", "fonts", "common"];

type Kind = "reftest" | "layout" | "crash" | "testharness";
type Status = "pass" | "fail" | "skip" | "error" | "crash";

interface Test {
  path: string; // relative to WPT root
  kind: Kind;
  /**
   * The references the page must match, any one of them, and the ones it must differ from
   * (`rel=match` and `rel=mismatch`), relative to the WPT root. Both may be listed at once: WPT
   * asks for a match against one of the first and a difference from every one of the second.
   */
  matchRefs?: string[];
  mismatchRefs?: string[];
  fuzzy?: { maxDiff: [number, number]; pixels: [number, number] };
}

interface Result {
  path: string;
  kind: Kind | "other";
  status: Status;
  reason?: string;
}

// ---------------------------------------------------------------------------
// Discovery

function walk(dir: string, out: string[]): void {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      if (["support", "reference", "resources", "crashtests", "tools", "META", "animation", "parsing", "inheritance"].includes(name)) continue;
      walk(p, out);
    } else if ([".html", ".htm", ".xht", ".xhtml"].includes(extname(name))) {
      if (/-ref(\.|-)|-notref|^ref-|reference/.test(name)) continue;
      // A manual test needs a person to look at it; WPT's own runners don't automate those.
      if (/-manual\./.test(name)) continue;
      out.push(p);
    }
  }
}

function parseFuzzy(src: string): Test["fuzzy"] {
  const m = /<meta\s+name=["']?fuzzy["']?\s+content=["']([^"']+)["']/i.exec(src);
  if (!m) return undefined;
  let content = m[1];
  if (content.includes(":") && !/^(maxDifference|totalPixels)/.test(content.trim())) content = content.slice(content.indexOf(":") + 1);
  const range = (s: string | undefined): [number, number] => {
    if (!s) return [0, 0];
    const [a, b] = s.split("-").map((x) => Number(x.trim()));
    return [a, b ?? a];
  };
  const parts = content.split(";").map((s) => s.trim());
  let maxDiff: [number, number] = [0, 0];
  let pixels: [number, number] = [0, 0];
  parts.forEach((p, i) => {
    const kv = p.split("=");
    const key = kv.length > 1 ? kv[0].trim() : i === 0 ? "maxDifference" : "totalPixels";
    const val = kv.length > 1 ? kv[1] : kv[0];
    if (key === "maxDifference") maxDiff = range(val);
    else if (key === "totalPixels") pixels = range(val);
  });
  return { maxDiff, pixels };
}

function classify(abs: string): Test | Result {
  const path = relative(WPT, abs);
  const src = readFileSync(abs, "utf8");
  // A reftest may name several references. It passes when it matches any one of its rel=match
  // references and differs from every one of its rel=mismatch references, and a page may list
  // both kinds at once.
  const matchRefs: string[] = [];
  const mismatchRefs: string[] = [];
  for (const tag of src.match(/<link\s[^>]*>/gi) ?? []) {
    const rel = /\brel=["']?(match|mismatch)["']?/i.exec(tag);
    if (!rel) continue;
    const href = /href=["']([^"']+)["']/i.exec(tag);
    if (!href) return { path, kind: "reftest", status: "skip", reason: "reftest: no href" };
    const refAbs = href[1].startsWith("/") ? join(WPT, href[1]) : join(dirname(abs), href[1]);
    if (!existsSync(refAbs)) return { path, kind: "reftest", status: "skip", reason: "reftest: reference not in checkout" };
    const refPath = relative(WPT, refAbs);
    const list = rel[1].toLowerCase() === "mismatch" ? mismatchRefs : matchRefs;
    if (!list.includes(refPath)) list.push(refPath);
  }
  if (matchRefs.length > 0 || mismatchRefs.length > 0) {
    return { path, kind: "reftest", matchRefs, mismatchRefs, fuzzy: parseFuzzy(src) };
  }
  if (/check-layout-th\.js/.test(src)) return { path, kind: "layout" };
  // A crash test has nothing to compare against: it passes when the page builds and renders
  // without taking the process down.
  if (/-crash\./.test(path)) return { path, kind: "crash" };
  // The speculative-parsing suite depends on the WPT server (its .sub.html placeholders, its
  // fetchlog endpoints) and on iframes, neither of which this runner has.
  if (path.startsWith("html/syntax/speculative-parsing/")) {
    return { path, kind: "other", status: "skip", reason: "needs the WPT server and iframes" };
  }
  // A page whose tests are the testharness API: the runner supplies that API and reads the result.
  if (/<script\s[^>]*src\s*=\s*["']?[^"'\s>]*testharness\.js/i.test(src)) return { path, kind: "testharness" };
  // Not a testharness page (that needs the API and is matched above) and not a reftest: a page
  // that only mentions testharness.js in a comment is a visual test, which has nothing to compare.
  return { path, kind: "other", status: "skip", reason: "not a reftest" };
}

// ---------------------------------------------------------------------------
// Compilation

/** Reduces a native warning to a feature key, the unit the report groups skips by. */
function featureOf(d: Diagnostic): string {
  const m = d.message;
  let r: RegExpExecArray | null;
  if ((r = /^'([\w-]+)' is not supported yet/.exec(m))) return `css property: ${r[1]}`;
  if ((r = /^unsupported value '([^']*)' for '([\w-]+)'/.exec(m))) return `css value: ${r[2]}: ${r[1].split(/\s+/)[0]}`;
  if ((r = /^unsupported (?:length|color|font-size|font-weight|opacity|border value|[\w-]+) '([^']*)'(?: for '([\w-]+)')?/.exec(m))) return `css value: ${r[2] ?? m.split(" ")[1]}`;
  if ((r = /^selector '([^']*)' is not supported/.exec(m))) {
    const s = r[1];
    if (/[+~]/.test(s)) return "selector: sibling combinator";
    if (/\[/.test(s)) return "selector: attribute";
    if ((r = /(::?[\w-]+)/.exec(s))) return `selector: ${r[1].replace(/\(.*/, "")}`;
    return `selector: ${s}`;
  }
  if ((r = /^@([\w-]+)/.exec(m))) return `at-rule: @${r[1]}`;
  if ((r = /^<([\w-]+)/.exec(m))) return `html: <${r[1]}>`;
  if (/^font-family/.test(m)) return "css: font-family (e.g. Ahem)";
  if (/mixes text/.test(m)) return "inline: mixed content";
  if (/'([\w-]+)' takes/.test(m)) return `css value: ${/'([\w-]+)'/.exec(m)![1]}`;
  return m.replace(/'[^']*'/g, "…").slice(0, 60);
}

interface Page {
  key: string;
  app: CompiledApp;
  /** The page's own directory in the checkout, for a module script's relative imports. */
  dir: string;
}

const pageCache = new Map<string, Page | { reasons: string[] } | { error: string }>();

/** Compiles a page: with its scripts for a reftest (they are run, and may hold the snapshot back
 *  with `reftest-wait`), without them for a layout test, whose script is the testharness
 *  plumbing the runner does itself. */
function compilePage(path: string, withScripts: boolean, testharness: boolean = false): Page | { reasons: string[] } | { error: string } {
  const cacheKey = (withScripts ? path + "\u0000scripts" : path) + (testharness ? "\u0000tests" : "");
  const hit = pageCache.get(cacheKey);
  if (hit) return hit;
  const diags = new Diagnostics();
  let result: Page | { reasons: string[] } | { error: string };
  try {
    const app = compileApp(join(WPT, path), diags, { root: WPT, ignoreScripts: !withScripts, testharness });
    const warnings = diags.list.filter((d) => d.severity !== "note");
    const errors = diags.list.filter((d) => d.severity === "error");
    // A script the sparse checkout doesn't hold is a gap in the checkout, not in the page: the
    // page is skipped with that as its reason, as a page with an unsupported feature is.
    const missing = errors.filter((d) => /^script '[^']*' not found$/.test(d.message));
    const other = errors.find((d) => missing.indexOf(d) < 0);
    if (other !== undefined) result = { error: other.message };
    else if (errors.length > 0) {
      const reasons = [...new Set(warnings.filter((d) => d.severity !== "error").map(featureOf))];
      reasons.push("script: not in checkout");
      result = { reasons };
    } else if (warnings.length > 0) result = { reasons: [...new Set(warnings.map(featureOf))] };
    else result = { key: `p${pageCache.size}`, app, dir: dirname(path) };
  } catch (e) {
    result = { error: `compiler crash: ${(e as Error).message}` };
  }
  pageCache.set(cacheKey, result);
  return result;
}

function scriptProblem(app: CompiledApp, kind: Kind): string | null {
  const srcs = app.scriptSrcs.filter((s) => !/testharness(report)?\.js|check-layout-th\.js/.test(s));
  if (srcs.length > 0) return `script: ${basename(srcs[0])}`;
  // scriptc can't lower a read of the `constructor` property: it fails the whole batch with an
  // error that names no page. Such a page is a skip, with the compiler gap as its reason, so it
  // doesn't take every page compiled beside it down with it.
  for (const script of app.scripts) {
    if (/\.\s*constructor\b/.test(script.text)) return "script: property 'constructor' is not supported yet";
  }
  for (const text of app.inlineScripts) {
    const rest = text
      .replace(/checkLayout\([^)]*\)\s*;?/g, "")
      .replace(/(window\.)?onload\s*=\s*(function\s*\(\)|\(\)\s*=>)\s*\{?/g, "")
      .replace(/document\.fonts\.ready\.then\([^)]*\)\s*;?/g, "")
      .replace(/[\s{}();]/g, "");
    if (rest !== "") return kind === "layout" ? "script: layout test runs other JS" : "script: inline JS";
  }
  return null;
}

// ---------------------------------------------------------------------------
// Batch runner

function findScriptc(): string {
  const local = join(ROOT, "node_modules", ".bin", "scriptc");
  return existsSync(local) ? local : "scriptc";
}

function importPath(fromDir: string, target: string): string {
  let p = relative(fromDir, target);
  if (!p.startsWith(".")) p = "./" + p;
  return p;
}


interface Job { page: Page; layout: boolean; test: boolean }

/** What a batch run produced: each page's output line, and the pages whose scripts didn't compile. */
interface BatchOutput {
  outputs: Map<string, string>;
  failures: Map<string, string>;
  /** False when the batch's runner could not be built at all. */
  built?: boolean;
  /** True when the runner died before its first page began: the program itself, not a page. */
  startup?: boolean;
  /** The build directories this batch made, for its caller to remove once it has the results. */
  dirs?: string[];
}

interface ExecResult { status: number | null; stdout: string; stderr: string; signal: string | null }

/** The processes this run has spawned and not yet reaped, so a run that is interrupted can take
 *  them down with it: a compiler killed while one of its children is still running leaves that
 *  child burning a core and holding gigabytes. */
const LIVE_CHILDREN = new Set<number>();

function killGroup(pid: number): void {
  try {
    if (process.platform === "win32") process.kill(pid, "SIGKILL");
    // A compiler spawns its LLVM helper and its type-checker daemon in its own process group when
    // it is detached below, so the group's pid is the one to signal.
    else process.kill(-pid, "SIGKILL");
  } catch {}
  try {
    process.kill(pid, "SIGKILL");
  } catch {}
}

let exitHookInstalled = false;
function installExitHook(): void {
  if (exitHookInstalled) return;
  exitHookInstalled = true;
  const stop = () => {
    for (const pid of LIVE_CHILDREN) killGroup(pid);
    LIVE_CHILDREN.clear();
  };
  process.on("exit", stop);
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
    process.on(signal, () => {
      stop();
      process.exit(130);
    });
  }
}

/** Runs a process asynchronously (so batches can build and run in parallel). */
function exec(cmd: string, args: string[], timeoutMs = 0, env: Record<string, string> = {}): Promise<ExecResult> {
  installExitHook();
  return new Promise((done) => {
    // Detached gives the process a group of its own, so a timeout or an interrupted run kills the
    // compiler's own children (its LLVM helper, its checker daemon) and not just the compiler.
    const child = spawn(cmd, args, {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...env },
      detached: process.platform !== "win32",
    });
    if (child.pid !== undefined) LIVE_CHILDREN.add(child.pid);
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (d: string) => (stdout += d));
    child.stderr.setEncoding("utf8").on("data", (d: string) => (stderr += d));
    let finished = false;
    const finish = (status: number | null, signal: string | null) => {
      if (finished) return;
      finished = true;
      if (child.pid !== undefined) LIVE_CHILDREN.delete(child.pid);
      done({ status, stdout, stderr, signal });
    };
    const timer = timeoutMs > 0
      ? setTimeout(() => {
          if (child.pid !== undefined) killGroup(child.pid);
        }, timeoutMs)
      : null;
    child.on("close", (status, signal) => {
      if (timer) clearTimeout(timer);
      finish(status, signal);
    });
    child.on("error", (e: NodeJS.ErrnoException) => {
      if (timer) clearTimeout(timer);
      // Spawning the binary itself failed (ENOENT), so there is no child to signal.
      if (e.code === "ENOENT" && child.pid === undefined) return finish(-1, null);
      finish(-1, null);
    });
  });
}

/**
 * Kills the type-checker daemon scriptc leaves behind for a build directory, if one is running.
 * scriptc starts one per project directory and lets it idle for ten minutes; a run compiles a
 * directory per batch, so without this a run's daemons accumulate to gigabytes of resident memory
 * and starve the builds that follow. The daemon is found by its `--cwd <dir>` argument, which no
 * other build's daemon carries.
 */
function reapCheckerServers(dir: string): void {
  const marker = `--cwd ${dir}`;
  const pids: number[] = [];
  if (process.platform === "linux") {
    let entries: string[] = [];
    try {
      entries = readdirSync("/proc");
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!/^\d+$/.test(entry)) continue;
      let cmdline = "";
      try {
        cmdline = readFileSync(`/proc/${entry}/cmdline`, "utf8").split("\0").join(" ");
      } catch {
        continue;
      }
      if (cmdline.includes("tsc-ts") && cmdline.includes(marker)) pids.push(Number(entry));
    }
  } else {
    const ps = spawnSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" });
    for (const line of (ps.stdout ?? "").split("\n")) {
      const m = /^\s*(\d+)\s+(.*)$/.exec(line);
      if (m === null) continue;
      if (m[2].includes("tsc-ts") && m[2].includes(marker)) pids.push(Number(m[1]));
    }
  }
  for (const pid of pids) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {}
  }
}

const RUNNER_CACHE = join(homedir(), ".cache", "native", "wpt-runners");
const SLOTS_DIR = join(homedir(), ".cache", "native", "wpt-slots");

/**
 * Keeps the compiled-runner cache within NATIVE_WPT_CACHE_MB (default 8 GB). A run builds many
 * runners of a few hundred megabytes each, and a machine that runs the suite repeatedly fills its
 * volume with them until a run is killed for disk. The oldest entries go first; a build that
 * finished moments ago is the one a rerun would hit, so the newest always stay.
 */
function pruneRunnerCache(): void {
  if (!existsSync(RUNNER_CACHE)) return;
  const entries: { path: string; size: number; at: number }[] = [];
  let total = 0;
  for (const name of readdirSync(RUNNER_CACHE)) {
    // A copy another run is writing is renamed into place when it is complete; pruning it
    // mid-flight would make that run's rename fail.
    if (name.indexOf(".tmp") >= 0) continue;
    const path = join(RUNNER_CACHE, name);
    try {
      const st = statSync(path);
      if (!st.isFile()) continue;
      entries.push({ path, size: st.size, at: st.mtimeMs });
      total += st.size;
    } catch {}
  }
  const max = Math.max(256, Number(process.env.NATIVE_WPT_CACHE_MB ?? 8192)) * 1024 * 1024;
  if (total <= max) return;
  entries.sort((a, b) => a.at - b.at);
  // A runner another run selected moments ago may still be copied: leave recent entries alone on
  // this pass, and the next run prunes them.
  const cutoff = Date.now() - 10 * 60 * 1000;
  for (const entry of entries) {
    if (total <= max) break;
    if (entry.at > cutoff) continue;
    try {
      rmSync(entry.path, { force: true });
      total -= entry.size;
    } catch {}
  }
}

/**
 * How a runner is compiled. The dev posture is -O0 with scriptc's cached LLVM object shards, so
 * every batch after the first reuses the runtime's shards instead of optimizing them again: a
 * release build spends minutes optimizing the same runtime for every batch, which is most of a
 * run's wall clock. A page renders the same either way; only the runner binary's speed changes.
 * SCRIPTC_LANES lets one batch's code generation use the machine's cores, as a dev rebuild does.
 */
const RUNNER_BUILD_FLAGS = ["--optimization", "dev"];
/** How many code-generation lanes one build may use. `run` divides the cores among the batches
 *  it is building at once, so a run does not put eight lanes under six concurrent builds. */
let buildLanes = availableParallelism();
const RUNNER_BUILD_ENV = (): Record<string, string> => ({
  SCRIPTC_LANES: String(Math.max(1, Number(process.env.SCRIPTC_LANES ?? buildLanes))),
});

/**
 * The memory a new process can use without swapping. Linux's `freemem` leaves out the page cache
 * the kernel would gladly reclaim, so on a machine that has read a checkout it reports a few
 * gigabytes where MemAvailable reports most of the RAM; the count of at-once builds follows the
 * latter.
 */
function availableMemory(): number {
  if (process.platform === "linux") {
    try {
      const m = /^MemAvailable:\s+(\d+) kB$/m.exec(readFileSync("/proc/meminfo", "utf8"));
      if (m !== null) return Number(m[1]) * 1024;
    } catch {}
  }
  return freemem();
}

/**
 * Takes one of a few machine-wide slots before building and running batches, so several
 * checkouts running WPT at once take turns instead of thrashing the CPU (a run alone is many
 * times faster than one of seven at once). A slot is a directory holding the owner's pid; a slot
 * whose owner has exited is reclaimed. NATIVE_WPT_SLOTS sets the count (default 2).
 */
async function acquireSlot(): Promise<() => void> {
  const count = Math.max(1, Number(process.env.NATIVE_WPT_SLOTS ?? 2));
  mkdirSync(SLOTS_DIR, { recursive: true });
  let waited = false;
  for (;;) {
    for (let i = 0; i < count; i++) {
      const slot = join(SLOTS_DIR, `slot-${i}`);
      try {
        mkdirSync(slot);
        writeFileSync(join(slot, "pid"), String(process.pid));
        const release = () => rmSync(slot, { recursive: true, force: true });
        process.on("exit", release);
        if (waited) process.stderr.write("\n");
        return release;
      } catch {
        let pid = 0;
        try {
          pid = Number(readFileSync(join(slot, "pid"), "utf8"));
        } catch {}
        let alive = pid > 0;
        if (alive) {
          try {
            process.kill(pid, 0);
          } catch {
            alive = false;
          }
        }
        if (!alive) rmSync(slot, { recursive: true, force: true });
      }
    }
    if (!waited) process.stderr.write(`native wpt: waiting for one of ${count} machine-wide run slots (${SLOTS_DIR})…`);
    waited = true;
    await new Promise((r) => setTimeout(r, 5000));
  }
}
const cacheStats = { hits: 0, misses: 0 };
let digestMemo: string | null = null;

/** A digest of every source a compiled runner depends on besides its own generated code. */
function sourceDigest(): string {
  if (digestMemo !== null) return digestMemo;
  const h = createHash("sha256");
  const files: string[] = [];
  const walkSrc = (d: string) => {
    for (const name of readdirSync(d).sort()) {
      const p = join(d, name);
      if (statSync(p).isDirectory()) walkSrc(p);
      else if (/\.(ts|m|c|json)$/.test(name)) files.push(p);
    }
  };
  // The compiler builds every page's tables (the UA sheet and the property encodings among them),
  // so a change there has to invalidate a cached runner too.
  for (const d of [RUNTIME, join(ROOT, "shared"), HOST, join(ROOT, "compiler")]) walkSrc(d);
  for (const f of files) h.update(relative(ROOT, f)).update("\0").update(readFileSync(f));
  // Runners are native binaries, so a cache shared between platforms must not mix them.
  h.update(process.platform);
  const scriptcPkg = join(ROOT, "node_modules", "scriptc", "package.json");
  h.update(existsSync(scriptcPkg) ? JSON.parse(readFileSync(scriptcPkg, "utf8")).version : "unknown");
  digestMemo = h.digest("hex");
  return digestMemo;
}

/** Compiles the native host once, before any batch links against it. Answers the objects every
 *  runner links: the platform's own source, the shared ones, and — for a Windows target — the
 *  compositor's core and D3D11 backend. */
function ensureHost(): string[] {
  const sources = hostSources(HOST);
  mkdirSync(WORK, { recursive: true });
  const shaders = prepareMetalShaders(HOST, WORK);
  const includeDirs = shaders === null ? [] : [WORK];
  const objects = sources.map((source) => join(WORK, basename(source).replace(/\.(m|c|cpp)$/, ".o")));
  const builds = sources.map((source, i) =>
    i === 0 ? hostCompileCommand(source, objects[i], process.platform, buildTarget(), includeDirs)
    : isCompositorBackend(source) ? hostCompositorCompileCommand(source, objects[i])
    : hostCommonCompileCommand(source, objects[i], HOST));
  // Keyed by the sources' content and the toolchain, like app builds (see compiler/cli.ts).
  const h = createHash("sha256");
  for (const source of sources) h.update(hostSourceDigest(source));
  if (shaders !== null) h.update(shaders.key);
  for (const build of builds) h.update([build.cc, ...build.args].join("\0"));
  const hostKey = h.digest("hex");
  const keyFile = objects[0] + ".key";
  if (!objects.every((obj) => existsSync(obj)) || !existsSync(keyFile) || readFileSync(keyFile, "utf8") !== hostKey) {
    for (const build of builds) {
      const cc = spawnSync(build.cc, build.args, { stdio: "inherit" });
      if (cc.status !== 0) throw new Error("host compile failed");
    }
    writeFileSync(keyFile, hostKey);
  }
  return objects;
}

/** Longest scriptc error kept as a page's skip reason. */
const MAX_REASON = 160;

/** One scriptc diagnostic line for a page's script module, with its page key and error. */
const SC_ERROR = /^(?:\S*\/)?s(p\d+)\.(?:ts|js):\d+:\d+ - error (SC\d+): (.*)$/;

/** The scriptc errors that belong to a page's scripts, keyed by page key, from a failed build. */
function scriptErrors(text: string, known: Set<string>): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of text.split("\n")) {
    const m = SC_ERROR.exec(line.trim());
    if (m === null || !known.has(m[1])) continue;
    if (!out.has(m[1])) out.set(m[1], `${m[2]} ${m[3]}`.slice(0, MAX_REASON));
  }
  return out;
}

/**
 * A module script's imports, pulled into the script itself. WPT's newer tests keep the test in a
 * `<script type="module">` that imports a shared support module; the page's scripts share one
 * module here, and one scope, so an import of a local file becomes that file's body with its
 * exports left plain. A form the rewrite doesn't handle — a default or renamed import, a module
 * still exporting something after that — is left as it is, so a page it can't inline still
 * compiles the way it did before.
 */
function inlineImports(text: string, fromDir: string, seen: Set<string>): string {
  const stmt = /^[ \t]*import\s+(?:\{([^}]*)\}|([A-Za-z_$][\w$]*))\s*from\s*(["'])([^"']+)\3[ \t]*;?/gm;
  return text.replace(stmt, (whole: string, named: string | undefined, ns: string | undefined, _q: string, spec: string) => {
    if (ns !== undefined || named === undefined) return whole;
    const names = named.split(",").map((n) => n.trim()).filter((n) => n !== "");
    // `import {a as b}` renames, which a plain body doesn't: leave the statement to the compiler.
    if (names.some((n) => /\s+as\s+/.test(n))) return whole;
    const target = spec.startsWith("/") ? join(WPT, spec) : resolve(fromDir, spec);
    // A module the page has already pulled in is in scope: a second copy would redeclare it.
    if (seen.has(target)) return "";
    if (!existsSync(target)) return whole;
    seen.add(target);
    let inner = inlineImports(readFileSync(target, "utf8"), dirname(target), seen);
    inner = inner.replace(/^[ \t]*export\s+(?=(?:async\s+)?(?:function|class|const|let|var)\b)/gm, "");
    inner = inner.replace(/^[ \t]*export\s*\{[^}]*\}\s*;?[ \t]*$/gm, "");
    // A JSDoc type is read as TypeScript here, and JSDoc's default (`{Object={}}`) isn't one:
    // the parameter keeps the type and loses the default.
    inner = inner.replace(/\{([A-Za-z_$][\w$.]*(?:\|[\w$.[\]]+)*)=\{[^{}]*\}\}/g, "{$1}");
    return /(^|\n)[ \t]*export\s/.test(inner) ? whole : inner;
  });
}

/** Whether a script's text is a module's rather than a classic script's. */
function isModuleText(text: string): boolean {
  return /^\s*(?:import|export)\b/m.test(text);
}

/**
 * Writes the modules one page needs: one that builds its DOM, one holding its classic scripts in
 * document order (when it has any), and one that pulls them in in that order, so that importing
 * the page mounts it and then runs its scripts, with the DOM available.
 */
function writePageModules(dir: string, job: Job): string[] {
  const key = job.page.key;
  const files: string[] = [];
  const gen = `${key}.ts`;
  writeFileSync(join(dir, gen), job.page.app.genSource);
  files.push(gen);
  const boot = `b${key}.ts`;
  writeFileSync(join(dir, boot), [
    "// Generated by native wpt: the page's DOM, before its scripts run.",
    `import { mount } from ${JSON.stringify(importPath(dir, join(RUNTIME, "app.ts")))};`,
    `import type { AppTables } from ${JSON.stringify(importPath(dir, join(RUNTIME, "app.ts")))};`,
    `import * as G from "./${gen}";`,
    `const t: AppTables = { ${FIELDS.map(([f, g]) => `${f}: G.${g}`).join(", ")} };`,
    `t.width = ${VIEW_W}; t.height = ${VIEW_H};`,
    "mount(t);",
    "",
  ].join("\n"));
  files.push(boot);
  const imports = [`import "./${boot}";`];
  const scripts = job.page.app.scripts;
  const handlers = job.page.app.handlers;
  if (scripts.length > 0 || handlers.length > 0) {
    const script = `s${key}.js`;
    // The page's classic scripts share one scope, as they share the global object in a browser,
    // and run here in document order. An inline handler attribute is a function in that same
    // scope — its code can call what the page's scripts declare, as it would in a browser — and
    // is attached to its element once the DOM exists, before any event is dispatched.
    let body = "";
    const aliased = new Set<string>();
    // The modules a page imports are pulled in once: the scripts share this one scope.
    const inlined = new Set<string>();
    const texts: string[] = [];
    for (const s of scripts) {
      // A module script's imports name the page's support modules: they run in this script's scope.
      texts.push(isModuleText(s.text)
        ? inlineImports(s.text, s.path !== null ? dirname(s.path) : join(WPT, job.page.dir), inlined)
        : s.text);
    }
    const declared = topLevelDeclarations(texts.join("\n"));
    // A classic script's write to a name nothing declares is a property of the global object in a
    // browser; here the page's scripts are one strict module, so each such name gets a binding
    // that is copied onto the window after the script (see implicitGlobals). A module script's
    // own code is strict in a browser too, so only classic scripts are scanned.
    const implicit: string[] = [];
    for (let i = 0; i < scripts.length; i++) {
      if (isModuleText(scripts[i].text)) continue;
      for (const name of implicitGlobals(texts[i], declared, aliased)) {
        if (implicit.indexOf(name) < 0) implicit.push(name);
      }
    }
    // An element id is reached through the binding namedAccess declares below, not as a window
    // property: a name the page's ids share with an implicit global must not be rebound here,
    // or the last write (the empty window property) would shadow the element.
    const idNames = new Set(job.page.app.ids);
    for (const name of implicit) if (!idNames.has(name)) body += `var ${name} = window.${name};\n`;
    for (let i = 0; i < scripts.length; i++) {
      // A classic script sees its own element through document.currentScript while it runs.
      body += "document.currentScript = document.getElementsByTagName(\"script\")[" + scripts[i].order + "];\n";
      body += texts[i] + "\n";
      // A classic script's top-level var and function names are the window's, as in a browser,
      // and so is a name it wrote to without declaring it.
      if (!isModuleText(scripts[i].text)) {
        body += windowVarAliases(texts[i]);
        for (const name of implicit) body += `window.${name} = ${name};\n`;
      }
      // A name the script left on the window is a global to the scripts after it.
      body += windowAliases(texts[i], aliased, declared);
    }
    body += "document.currentScript = null;\n";
    // The page's scripts share this module scope, so the harness's keyboard driver (which
    // testharness.js calls) is bound here rather than exposed as a global an app would get.
    let loader = `import { __nativeSendKeys, actionKey } from ${JSON.stringify(importPath(dir, join(RUNTIME, "app/keyboard.ts")))}; `;
    // test_driver's clicks, hovers and Actions drive the same pointer and wheel path the host
    // uses, so a press focuses what it hits and the pointer stays where it was left.
    loader += `import { pointerDown, pointerUp, pointerMove } from ${JSON.stringify(importPath(dir, join(RUNTIME, "app/pointer.ts")))}; `;
    loader += `import { wheel } from ${JSON.stringify(importPath(dir, join(RUNTIME, "app/scroll.ts")))}; `;
    // Input hit-tests where the page is now: lay it out first, as a browser has before input.
    loader += `import { frame } from ${JSON.stringify(importPath(dir, join(RUNTIME, "app/mount.ts")))}; `;
    if (handlers.length > 0) {
      loader += `import { attachHandler } from ${JSON.stringify(importPath(dir, join(RUNTIME, "app.ts")))}; `;
      for (const h of handlers) {
        body += `attachHandler(${h.node}, ${JSON.stringify(h.type)}, function (this: any, event: any): any {\n`;
        body += h.code + "\n";
        body += "});\n";
      }
    }
    // Element ids are globals too, as in a browser, so `child.style` names <div id="child">.
    body = namedAccess(body, job.page.app.ids) + body;
    writeFileSync(join(dir, script), "// Generated by native wpt from the page's classic scripts.\n"
      + loader + withDomImports(body, join(dir, script), true, true));
    files.push(script);
    imports.push(`import "./${script}";`);
  }
  const page = `pg${key}.ts`;
  writeFileSync(join(dir, page), ["// Generated by native wpt.", ...imports, ""].join("\n"));
  files.push(page);
  return files;
}

/** The runner's main module: mounts and runs each page in turn, takes its snapshot, and moves on
 *  even when a page's script throws. */
function writeMain(dir: string, keys: string[], layout: boolean[], test: boolean[] = []): string {
  const lines = [
    "// Generated by native wpt.",
    `import { paintPage, renderFrame, resetPage, settlePage } from ${JSON.stringify(importPath(dir, join(RUNTIME, "app.ts")))};`,
    `import { checkLayout } from ${JSON.stringify(importPath(dir, join(RUNTIME, "wpt.ts")))};`,
    `import { settleTests } from ${JSON.stringify(importPath(dir, join(RUNTIME, "app.ts")))};`,
    `import { hostSnapshot } from ${JSON.stringify(importPath(dir, join(RUNTIME, "host.ts")))};`,
    "",
    "// One module per page, imported when the page's turn comes: its scripts run against the DOM it",
    "// just built. Every call passes a literal specifier, so scriptc sees every page module at",
    "// build time (it can't bound a specifier computed at run time).",
    "async function runPage(spec: string): Promise<void> {",
    "  const m = await import(spec);",
    "  void m;",
    "}",
    "",
    "function pageLine(i: number): Promise<void> {",
    ...keys.map((k, i) => `  if (i === ${i}) return runPage("./pg${k}.ts");`),
    "  return new Promise<void>((resolve) => resolve());",
    "}",
    "",
    "// The driver builds each runner to match the pages in its batch, and a runner read back from",
    "// the build cache is only trusted for the batch it says it holds.",
    `console.log("PAGES " + ${keys.length});`,
    "",
    "function errorText(e: unknown): string {",
    "  // A classic script may throw a string; the value itself is the message then.",
    "  if (typeof e === \"string\") return e;",
    "  const m = (e as any).message;",
    "  return m === undefined || m === \"\" ? String(e) : m;",
    "}",
    "",
    `const KEYS: string[] = ${JSON.stringify(keys)};`,
    `const layout: boolean[] = ${JSON.stringify(layout)};`,
    `const tests: boolean[] = ${JSON.stringify(test)};`,
    `const start = process.argv.length > 2 ? Number(process.argv[2]) : 0;`,
    "// A runner spawned as a child window by window.open has no pages of its own to drive.",
    `const spawnedAsWindow = process.env.NATIVE_WINDOW_URL !== undefined;`,
    "for (let i = start; i < KEYS.length && !spawnedAsWindow; i++) {",
    "  console.log(\"BEGIN \" + i);",
    "  resetPage();",
    "  try {",
    "    await pageLine(i);",
    "    if (!(await settlePage())) {",
    "      // A reftest that never clears reftest-wait is a failure in WPT's runner too.",
    "      console.log(\"DONE \" + i + \" RUNTIME the page never removed reftest-wait\");",
    "      continue;",
    "    }",
    "    if (tests[i]) {",
    "      const r = await settleTests();",
    "      if (r === \"\") console.log(\"DONE \" + i + \" RUNTIME the testharness produced no result\");",
    "      else console.log(\"DONE \" + i + \" TESTS \" + r);",
    "      continue;",
    "    }",
    "    renderFrame();",
    "    // The snapshot reads the display list, so paint this page's settled tree once more right",
    "    // before it: a page whose frame was left pending (or whose flags were cleared) still",
    "    // snapshots its own pixels and never the previous page's.",
    "    paintPage();",
    "    // The output directory comes from the environment, so the same compiled runner can be reused",
    "    // by every checkout (see the runner cache below).",
    `    hostSnapshot((process.env.NATIVE_WPT_OUT ?? ".") + "/" + KEYS[i] + ".rgba", ${VIEW_W}, ${VIEW_H}, 1);`,
    "    console.log(\"DONE \" + i + \" \" + (layout[i] ? checkLayout() : \"-\"));",
    "  } catch (e) {",
    "    console.log(\"DONE \" + i + \" RUNTIME \" + errorText(e));",
    "  }",
    "}",
    "",
  ];
  const main = join(dir, "main.ts");
  writeFileSync(main, lines.join("\n"));
  return main;
}

/**
 * Compiles one runner binary for a batch of pages and runs it; returns per-page output lines and
 * the pages whose scripts didn't compile (with the error), which stay skips.
 */
async function runBatchOne(index: number, jobs: Job[], outDir: string, hostObjs: string[]): Promise<BatchOutput> {
  const dir = join(WORK, `batch-${index}`);
  try {
    const result = await runBatchInDir(dir, jobs, outDir, hostObjs);
    // The directory's page sources, compiled runner and object files have given the batch
    // everything it reports; the caller removes it once the results are in hand, so that a run of
    // a large directory doesn't leave a gigabyte or more a batch behind.
    return { ...result, dirs: [dir] };
  } finally {
    // The build directory is done with, and so is the checker daemon it started for it.
    reapCheckerServers(dir);
  }
}

/**
 * How long one compiled runner may take for its batch. A testharness page whose tests never
 * settle holds its turn for the harness's 30-second test limit, so a batch of a hundred pages can
 * legitimately run for several minutes; a two-minute cap reported those batches as crashes and
 * split them, so this one is generous.
 */
const RUN_TIMEOUT = 900_000;

async function runBatchInDir(dir: string, jobs: Job[], outDir: string, hostObjs: string[]): Promise<BatchOutput> {
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(join(dir, "node_modules", "@scriptc"), { recursive: true });
  symlinkSync(join(ROOT, "node_modules", "@scriptc", "types"), join(dir, "node_modules", "@scriptc", "types"),
    process.platform === "win32" ? "junction" : "dir");

  const manifest = JSON.parse(readFileSync(join(HOST, "ffi.json"), "utf8"));
  manifest.libraries = hostObjs;
  applyHostLink(manifest);
  writeFileSync(join(dir, "ffi.json"), JSON.stringify(manifest));

  const out = new Map<string, string>();
  const failures = new Map<string, string>();
  const known = new Set(jobs.map((j) => j.page.key));
  let active = jobs.slice();
  const exe = join(dir, "runner");
  const write = () => {
    const files: string[] = [];
    for (const j of active) files.push(...writePageModules(dir, j));
    return { main: writeMain(dir, active.map((j) => j.page.key), active.map((j) => j.layout), active.map((j) => j.test)), files };
  };
  const runnerKey = (main: string, files: string[]) => {
    const h = createHash("sha256").update(sourceDigest()).update(RUNNER_BUILD_FLAGS.join("\0")).update(readFileSync(main));
    for (const f of files) h.update(readFileSync(join(dir, f)));
    return join(RUNNER_CACHE, h.digest("hex"));
  };
  // Build the runner, reusing the build cache when it has this exact batch. Pages whose scripts
  // scriptc refuses leave the batch and stay skips with the error as their reason; `false` means
  // the batch could not be built at all, and every page in it has an ERROR line.
  let reused = false;
  let reusedPath = "";
  const prepare = async (useCache: boolean, store = useCache): Promise<boolean> => {
    reused = false;
    let gen = write();
    let cached = useCache || store ? runnerKey(gen.main, gen.files) : "";
    const copyCached = (): boolean => {
      if (cached === "" || !existsSync(cached)) return false;
      // Another run prunes the shared cache while this one selects a hit: losing that race is a
      // cache miss for this batch, not a failure of the run.
      try {
        copyFileSync(cached, exe);
      } catch {
        return false;
      }
      chmodSync(exe, 0o755);
      cacheStats.hits++;
      reused = true;
      reusedPath = cached;
      return true;
    };
    if (copyCached()) return true;
    // Type errors first, all of them in one pass: a page whose scripts don't typecheck is a skip
    // with the error as its reason, and the rest of the batch still builds.
    const cov = await exec(findScriptc(), ["coverage", gen.main]);
    if (cov.status !== 0 && cov.stdout + cov.stderr !== "") {
      const errs = scriptErrors(cov.stdout + cov.stderr, known);
      if (errs.size > 0) {
        for (const [k, msg] of errs) failures.set(k, msg);
        active = active.filter((j) => !failures.has(j.page.key));
        gen = write();
        cached = useCache || store ? runnerKey(gen.main, gen.files) : "";
        if (copyCached()) return true;
      }
    }
    for (let round = 0; ; round++) {
      const sc = await exec(findScriptc(), ["build", gen.main, "--ffi", join(dir, "ffi.json"), "-o", exe, ...RUNNER_BUILD_FLAGS], 0, RUNNER_BUILD_ENV());
      if (sc.status === 0) {
        if (store) {
          mkdirSync(RUNNER_CACHE, { recursive: true });
          copyFileSync(exe, cached + ".tmp" + process.pid);
          renameSync(cached + ".tmp" + process.pid, cached);
        }
        cacheStats.misses++;
        return true;
      }
      // A page whose scripts scriptc refuses stays a skip, so one bad page doesn't stop the batch.
      const errs = scriptErrors(sc.stdout + sc.stderr, known);
      const fresh = [...errs].filter(([k]) => !failures.has(k));
      if (fresh.length === 0 || round >= 8) {
        const msg = (sc.stderr || sc.stdout).split("\n").find((l) => /error/.test(l)) ?? "scriptc build failed";
        for (const j of active) out.set(j.page.key, `ERROR ${msg.trim()}`.slice(0, 200));
        return false;
      }
      for (const [k, msg] of fresh) failures.set(k, msg);
      active = active.filter((j) => !failures.has(j.page.key));
      gen = write();
      cached = useCache || store ? runnerKey(gen.main, gen.files) : "";
      if (copyCached()) return true;
    }
  };

  // Run the batch, restarting after a crash at the page that crashed. Returns the pages that
  // crashed, or every page when the runner turns out to hold a different batch than this one.
  let startup = false;
  const run = async (): Promise<string[]> => {
    const crashedPages: string[] = [];
    let start = 0;
    while (start < active.length) {
      const r = await exec(exe, [String(start)], RUN_TIMEOUT, { NATIVE_WPT_OUT: outDir });
      let last = start - 1;
      let begun = -1;
      for (const line of (r.stdout ?? "").split("\n")) {
        const p = /^PAGES (\d+)$/.exec(line);
        if (p && Number(p[1]) !== active.length) {
          // A reused runner that was built for another batch says so before it runs a page.
          for (const j of active) out.delete(j.page.key);
          return active.map((j) => j.page.key);
        }
        const b = /^BEGIN (\d+)/.exec(line);
        if (b) begun = Number(b[1]);
        const d = /^DONE (\d+) (.*)$/.exec(line);
        if (d) {
          last = Number(d[1]);
          out.set(active[last].page.key, d[2]);
        }
      }
      if (last >= active.length - 1) break;
      // A program that dies before its first page starts — the compiler built one whose document
      // construction overflows the stack, say — would die the same way at every page it holds.
      // Say so once instead of restarting the runner for each of them, and let the caller split
      // the batch: the halves are smaller programs, and a smaller program does not overflow.
      if (start === 0 && begun < 0) {
        startup = true;
        return crashedPages;
      }
      const crashed = begun > last ? begun : last + 1;
      // A crash usually leaves no message: say how the process ended then, so the report isn't blank.
      const said = (r.stderr ?? "").trim().split("\n").pop() ?? "";
      const how = said !== "" ? said : `exit ${r.status}${r.signal === null ? "" : ` ${r.signal}`}`;
      out.set(active[crashed].page.key, `CRASH ${how}`.slice(0, 200));
      crashedPages.push(active[crashed].page.key);
      start = crashed + 1;
    }
    return crashedPages;
  };

  let built = false;
  if (await prepare(true)) {
    built = true;
    const bad = await run();
    // A runner read back from the cache can be wrong for the batch it is asked to run: build it
    // from the sources and run it again before any page is reported as crashed.
    if (bad.length > 0 && reused) {
      out.clear();
      rmSync(reusedPath, { force: true });
      process.stderr.write(`\nnative wpt: ${basename(dir)}: rebuilding a reused runner that failed on ${bad.length} page(s)\n`);
      if (await prepare(false, true)) await run();
    }
  }
  return { outputs: out, failures, built, startup };
}

/**
 * Builds and runs a batch. One page's construct can make scriptc refuse the whole shared module
 * ("uses of X inherit the blocker on its declaration"), which would report up to a hundred good
 * pages with it; when every page in a batch fails to build, the batch is split in halves until the
 * page that breaks the build stands alone, and only it is reported as an error.
 */
/**
 * How many times a failed batch may be halved. scriptc names the page whose script it refuses, and
 * the batch is rebuilt without it; but an error it reports without a page (an internal error, say)
 * can only be pinned on a page by bisecting. Halving costs one build per half, so a batch that
 * fails for such a reason is cut at most this many times and the pages left are reported as build
 * failures rather than splitting further on every run.
 */
const MAX_SPLIT_DEPTH = 3;

/** The first index a split child takes; top-level batches never reach it. */
let splitIndex = 1_000_000;

async function runBatch(index: number, jobs: Job[], outDir: string, hostObjs: string[], depth: number = 0): Promise<BatchOutput> {
  const first = await runBatchOne(index, jobs, outDir, hostObjs);
  // A build that never succeeded is split, whoever the error was attributed to: the pages that
  // share the module failed with it. A runner that died before its first page began is split the
  // same way, for the same reason: the batch is one program, and smaller programs build and run.
  const why = first.built === false ? "build failed"
    : first.startup === true ? "the runner died before its first page" : "";
  if (jobs.length <= 1 || why === "") return first;
  if (depth === 0 && first.built === false) {
    // Say once what scriptc said, since no page's own reason carries it at this level.
    for (const v of first.outputs.values()) {
      if (v.startsWith("ERROR ")) { process.stderr.write(`\nnative wpt: ${v.slice(0, 200)}\n`); break; }
    }
  }
  if (depth >= MAX_SPLIT_DEPTH) {
    if (first.startup === true) {
      for (const j of jobs) first.outputs.set(j.page.key, "CRASH the runner died before its first page started");
    }
    process.stderr.write(`\nnative wpt: batch ${index}: ${why} for ${jobs.length} page(s); reported as build failures\n`);
    return first;
  }
  const mid = Math.ceil(jobs.length / 2);
  process.stderr.write(`\nnative wpt: batch ${index}: ${why} for ${jobs.length} page(s); splitting to find the page that breaks it\n`);
  // A split child gets an index of its own, above every top-level one: its build directory lives
  // until its parent's results are merged, and a later top-level batch must not reuse it and have
  // its live tree deleted underneath it.
  const half = async (_n: number, part: Job[]): Promise<BatchOutput> =>
    runBatch(splitIndex++, part, outDir, hostObjs, depth + 1);
  const a = await half(1, jobs.slice(0, mid));
  const b = await half(2, jobs.slice(mid));
  const outputs = new Map(first.outputs);
  for (const m of [a.outputs, b.outputs]) for (const [k, v] of m) outputs.set(k, v);
  const failures = new Map(first.failures);
  for (const m of [a.failures, b.failures]) for (const [k, v] of m) failures.set(k, v);
  const dirs = [...(first.dirs ?? []), ...(a.dirs ?? []), ...(b.dirs ?? [])];
  return { outputs, failures, built: true, dirs };
}

function compareImages(a: string, b: string, fuzzy: Test["fuzzy"], mismatch: boolean): { pass: boolean; detail: string; pixels: number } {
  if (!existsSync(a) || !existsSync(b)) return { pass: false, detail: "missing snapshot", pixels: Infinity };
  const x = readFileSync(a);
  const y = readFileSync(b);
  if (x.length !== y.length) return { pass: false, detail: "snapshot size differs", pixels: Infinity };
  let pixels = 0;
  let maxDiff = 0;
  for (let i = 0; i < x.length; i += 4) {
    const d = Math.max(Math.abs(x[i] - y[i]), Math.abs(x[i + 1] - y[i + 1]), Math.abs(x[i + 2] - y[i + 2]), Math.abs(x[i + 3] - y[i + 3]));
    if (d > 0) {
      pixels++;
      if (d > maxDiff) maxDiff = d;
    }
  }
  const f = fuzzy ?? { maxDiff: [0, 0] as [number, number], pixels: [0, 0] as [number, number] };
  const equal = pixels === 0 || (maxDiff >= f.maxDiff[0] && maxDiff <= f.maxDiff[1] && pixels >= f.pixels[0] && pixels <= f.pixels[1]);
  const detail = `${pixels} pixels differ (max ${maxDiff})`;
  return mismatch
    ? { pass: !equal, detail: equal ? "rendered identically to mismatch reference" : detail, pixels }
    : { pass: equal, detail, pixels };
}

// ---------------------------------------------------------------------------
// Commands

function fetch(): void {
  if (!existsSync(WPT)) {
    mkdirSync(dirname(WPT), { recursive: true });
    const c = spawnSync("git", ["clone", "--filter=blob:none", "--depth", "1", "--sparse", "https://github.com/web-platform-tests/wpt.git", WPT], { stdio: "inherit" });
    if (c.status !== 0) process.exit(1);
  }
  // Add to the directories already checked out rather than replacing them: the checkout is shared
  // by every native checkout on the machine, and an older one must not drop directories a newer
  // one added.
  const current = spawnSync("git", ["-C", WPT, "sparse-checkout", "list"], { encoding: "utf8" });
  const dirs = new Set(SPARSE.map((d) => `/${d}/`));
  for (const line of (current.stdout ?? "").split("\n")) if (line.trim()) dirs.add(line.trim());
  const s = spawnSync("git", ["-C", WPT, "sparse-checkout", "set", "--no-cone", ...[...dirs].sort()], { stdio: "inherit" });
  process.exit(s.status ?? 1);
}

async function run(args: string[]): Promise<void> {
  if (!existsSync(WPT)) {
    console.error(`native wpt: no WPT checkout at ${WPT}; run 'native wpt fetch' first`);
    process.exit(1);
  }
  const opt = (name: string) => {
    const i = args.indexOf(name);
    if (i < 0) return undefined;
    const v = args[i + 1];
    args.splice(i, 2);
    return v;
  };
  const filter = opt("--filter");
  const set = opt("--set");
  const extended = set === "extended" || process.env.NATIVE_WPT_EXTENDED === "1";
  const batchSize = Number(opt("--batch") ?? 100);
  // A build holds a few gigabytes (scriptc plus its LLVM helper), so the default count of at-once
  // batches is bounded by memory as well as by cores: eight builds on a 16 GB machine would be
  // killed for running the machine out of memory, which the build then reports as a batch that
  // failed — the failure this default exists to avoid.
  const BUILD_MEMORY = 5 * 1024 ** 3;
  const byMemory = Math.max(1, Math.floor(availableMemory() / BUILD_MEMORY));
  const parallel = Math.max(1, Number(opt("--jobs") ?? Math.min(8, Math.max(1, availableParallelism() - 2), byMemory)));
  // A code-generation lane is a compiler process of its own, holding a couple of gigabytes while
  // it emits its share of the program, so the lanes one build may use are bounded by memory as
  // well as by the cores the batches running beside it leave — eight lanes under two builds on a
  // 16 GB machine is thirteen gigabytes of compiler.
  const LANE_MEMORY = 2 * 1024 ** 3;
  const lanesByMemory = Math.max(1, Math.floor(availableMemory() / (parallel * LANE_MEMORY)));
  buildLanes = Math.max(1, Math.min(4, Math.floor(availableParallelism() / parallel), lanesByMemory));
  // The committed results are the macOS host's. A Linux run writes its own file instead of
  // overwriting them.
  const outFile = resolve(opt("--out") ?? join(ROOT, "wpt", MACOS ? "results.json" : "results-linux.json"));
  const verbose = args.includes("--verbose");
  const dirs = args.filter((a) => !a.startsWith("--"));
  // No directory named: the default set, plus the extended one for a full run.
  if (dirs.length === 0 && extended) dirs.push(...DEFAULT_DIRS, ...EXTENDED_DIRS);
  const t0 = performance.now();

  const files: string[] = [];
  const missing: string[] = [];
  for (const d of dirs.length ? dirs : DEFAULT_DIRS) {
    const abs = join(WPT, d);
    if (existsSync(abs)) walk(abs, files);
    else missing.push(d);
  }
  if (missing.length > 0) {
    // A partial run would write a results.json that silently drops tests and reads as regressions.
    console.error(`native wpt: not in the checkout: ${missing.join(", ")}. Run 'native wpt fetch' first.`);
    process.exit(1);
  }
  const results: Result[] = [];
  const runnable: { test: Test; page: Page; matchRefs: Page[]; mismatchRefs: Page[] }[] = [];
  for (const f of files.sort()) {
    if (filter && !new RegExp(filter).test(relative(WPT, f))) continue;
    const c = classify(f);
    if ("status" in c) {
      results.push(c);
      continue;
    }
    // A reftest's scripts are compiled and run; a layout test's are the testharness plumbing the
    // runner does itself, so they stay out of the build.
    const page = compilePage(c.path, c.kind === "reftest" || c.kind === "testharness", c.kind === "testharness");
    if ("error" in page) {
      results.push({ path: c.path, kind: c.kind, status: "error", reason: page.error });
      continue;
    }
    const pageReasons = "reasons" in page ? page.reasons : [];
    // References that compile cleanly: the page passes when it matches any one of its match
    // references, so one of them with unsupported CSS doesn't sink a test whose other is fine.
    const matchRefs: Page[] = [];
    const mismatchRefs: Page[] = [];
    const refReasons: string[] = [];
    let refError = "";
    if (c.kind === "reftest") {
      for (const refPath of c.matchRefs ?? []) {
        const r = compilePage(refPath, true);
        if ("error" in r) {
          refError = r.error;
          break;
        }
        if ("reasons" in r) refReasons.push(...r.reasons);
        else matchRefs.push(r);
      }
      if (refError === "") {
        for (const refPath of c.mismatchRefs ?? []) {
          const r = compilePage(refPath, true);
          if ("error" in r) {
            refError = r.error;
            break;
          }
          if ("reasons" in r) refReasons.push(...r.reasons);
          else mismatchRefs.push(r);
        }
      }
    }
    if (pageReasons.length > 0 || (c.kind === "reftest" && matchRefs.length === 0 && mismatchRefs.length === 0 && refError === "")) {
      const reasons = pageReasons.length > 0 ? pageReasons : refReasons;
      results.push({ path: c.path, kind: c.kind, status: "skip", reason: [...new Set(reasons)].join(" | ") });
      continue;
    }
    if (refError !== "") {
      results.push({ path: c.path, kind: c.kind, status: "error", reason: `reference: ${refError}` });
      continue;
    }
    const p = page as Page;
    // A crash test's scripts aren't part of what it checks for us: the markup's layout and paint
    // are, so the page renders headless with its scripts left out, as a reftest's are.
    let sp = c.kind === "crash" ? null : scriptProblem(p.app, c.kind);
    for (const ref of matchRefs) if (sp === null) sp = scriptProblem(ref.app, "reftest");
    for (const ref of mismatchRefs) if (sp === null) sp = scriptProblem(ref.app, "reftest");
    if (sp !== null) {
      results.push({ path: c.path, kind: c.kind, status: "skip", reason: sp });
      continue;
    }
    runnable.push({ test: c, page: p, matchRefs, mismatchRefs });
  }

  // Unique pages to render (references are shared between tests).
  const jobs = new Map<string, Job>();
  for (const r of runnable) {
    const prev = jobs.get(r.page.key);
    jobs.set(r.page.key, {
      page: r.page,
      layout: r.test.kind === "layout" || (prev?.layout ?? false),
      test: r.test.kind === "testharness" || (prev?.test ?? false),
    });
    for (const ref of r.matchRefs) if (!jobs.has(ref.key)) jobs.set(ref.key, { page: ref, layout: false, test: false });
    for (const ref of r.mismatchRefs) if (!jobs.has(ref.key)) jobs.set(ref.key, { page: ref, layout: false, test: false });
  }
  const outDir = join(WORK, "snapshots");
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const all = [...jobs.values()];
  const outputs = new Map<string, string>();
  /** Pages whose scripts didn't compile, with scriptc's error: each stays a skip. */
  const scriptFailures = new Map<string, string>();
  /** Adds the result of every runnable page whose runs are in, or of every page on a final pass. */
  const collectInto = (target: Result[], final: boolean): void => {
  for (const r of runnable) {
    // Until every page of a test (its own and its references) has run, there is no verdict: a
    // partial write leaves those tests out rather than calling them errors.
    // A page whose scripts scriptc refused has a verdict of its own (a skip), so it is ready too:
    // an interrupted run keeps it along with the pages that ran.
    const hasRun = (key: string): boolean => outputs.has(key) || scriptFailures.has(key);
    const ready = hasRun(r.page.key) &&
      r.matchRefs.every((ref) => hasRun(ref.key)) && r.mismatchRefs.every((ref) => hasRun(ref.key));
    if (!ready && !final) continue;
    // A page whose scripts scriptc refused is a skip with the error; a script that throws while
    // running is an error, since what the page shows then isn't what it means to show.
    const failed = scriptFailures.get(r.page.key);
    let refFailed: string | undefined;
    for (const ref of r.matchRefs) if (refFailed === undefined) refFailed = scriptFailures.get(ref.key);
    for (const ref of r.mismatchRefs) if (refFailed === undefined) refFailed = scriptFailures.get(ref.key);
    if (failed !== undefined || refFailed !== undefined) {
      const msg = failed ?? refFailed!;
      target.push({ path: r.test.path, kind: r.test.kind, status: "skip", reason: `${failed === undefined ? "reference script: " : "script: "}${msg}` });
      continue;
    }
    const out = outputs.get(r.page.key) ?? "ERROR no output";
    const refOuts = [...r.matchRefs, ...r.mismatchRefs].map((ref) => outputs.get(ref.key) ?? "ERROR no output");
    // A page that throws is the test's error; a reference page that throws is the test's error
    // too, since what it draws then isn't the picture the test compares against — but the reason
    // says which page it was, so a reference's own script isn't read as the test's.
    const badTest = /^(ERROR|CRASH|RUNTIME)/.test(out) ? out : "";
    const badRef = badTest !== "" ? -1 : refOuts.findIndex((o) => /^(ERROR|CRASH|RUNTIME)/.test(o));
    if (badTest !== "" || badRef >= 0) {
      const bad = badTest !== "" ? badTest : refOuts[badRef];
      const status = bad.startsWith("CRASH") ? "crash" : "error";
      const why = bad.replace(/^RUNTIME /, "script threw: ");
      target.push({ path: r.test.path, kind: r.test.kind, status, reason: (badRef >= 0 ? "reference page: " : "") + why });
      continue;
    }
    if (r.test.kind === "testharness") {
      const body = out.replace(/^TESTS /, "");
      let parsed: { status: number; message: string; tests: { name: string; status: number; message: string }[] } | null = null;
      try { parsed = JSON.parse(body); } catch { parsed = null; }
      if (parsed === null) {
        target.push({ path: r.test.path, kind: "testharness", status: "fail", reason: "no test harness result" });
      } else {
        const failed = parsed.tests.filter((t) => t.status !== 0);
        const reasons: string[] = [];
        if (parsed.status !== 0) reasons.push(parsed.message === "" ? "harness error" : parsed.message);
        if (failed.length > 0) reasons.push(`${failed[0].name}: ${failed[0].message === "" ? "failed" : failed[0].message}`);
        const many = failed.length > 1 ? ` (+${failed.length - 1} more)` : "";
        target.push({
          path: r.test.path, kind: "testharness",
          status: reasons.length === 0 ? "pass" : "fail",
          reason: reasons.length === 0 ? undefined : (reasons.join("; ") + many).slice(0, 300),
        });
      }
      continue;
    }
    if (r.test.kind === "layout") {
      // Into the batch's own list, like every other verdict: the final write replaces it.
      if (out.startsWith("PASS")) target.push({ path: r.test.path, kind: "layout", status: "pass" });
      else if (out === "NONE") target.push({ path: r.test.path, kind: "layout", status: "skip", reason: "layout: no expectations found" });
      else if (/unsupported check/.test(out)) target.push({ path: r.test.path, kind: "layout", status: "skip", reason: "layout: " + /unsupported check [\w-]+/.exec(out)![0] });
      else target.push({ path: r.test.path, kind: "layout", status: "fail", reason: out.replace(/^FAIL /, "") });
    } else if (r.test.kind === "crash") {
      target.push({ path: r.test.path, kind: "crash", status: "pass" });
    } else {
      // The page passes when it matches any one of its match references and differs from every
      // one of its mismatch references; the closest reference names the difference otherwise.
      const testRaw = join(outDir, `${r.page.key}.rgba`);
      const cmpOf = (ref: Page, mismatch: boolean) => compareImages(testRaw, join(outDir, `${ref.key}.rgba`), r.test.fuzzy, mismatch);
      const matches = r.matchRefs.map((ref) => cmpOf(ref, false));
      const differs = r.mismatchRefs.map((ref) => cmpOf(ref, true));
      const ok = (matches.length === 0 || matches.some((c) => c.pass)) && differs.every((c) => c.pass);
      const cmps = matches.concat(differs);
      const nearest = cmps.reduce((a, b) => (b.pixels < a.pixels ? b : a));
      target.push({ path: r.test.path, kind: "reftest", status: ok ? "pass" : "fail", reason: ok ? undefined : nearest.detail });
    }
  }
  };

  const batches = Math.ceil(all.length / batchSize);
  const releaseSlot = await acquireSlot();
  const hostObjs = ensureHost();
  let next = 0;
  let finished = 0;
  const progress = () =>
    process.stderr.write(`\rnative wpt: ${finished}/${batches} batches done (${all.length} pages, ${parallel} in parallel)…`);
  progress();
  await Promise.all(Array.from({ length: Math.min(parallel, batches) }, async () => {
    for (let b = next++; b < batches; b = next++) {
      const batch = await runBatch(b, all.slice(b * batchSize, (b + 1) * batchSize), outDir, hostObjs);
      for (const [k, v] of batch.outputs) outputs.set(k, v);
      for (const [k, v] of batch.failures) scriptFailures.set(k, v);
      // The results are in hand, so the batch's build trees are done with: nothing later in the
      // run reads them (a runner reused by a later batch comes from the build cache).
      for (const d of batch.dirs ?? []) rmSync(d, { recursive: true, force: true });
      finished++;
      progress();
      // Write what is known after every batch: a run that is stopped keeps the results of the
      // batches it finished, instead of losing the whole file.
      const done = results.slice();
      collectInto(done, false);
      if (done.length > results.length) {
        done.sort((a, b) => a.path.localeCompare(b.path));
        mkdirSync(dirname(outFile), { recursive: true });
        writeFileSync(outFile, JSON.stringify({ wpt: wptRevision(), partial: true, results: done }, null, 1) + "\n");
      }
    }
  }));
  releaseSlot();
  pruneRunnerCache();
  process.stderr.write(`\nnative wpt: compiled runners: ${cacheStats.misses} built, ${cacheStats.hits} reused from ${relative(process.cwd(), RUNNER_CACHE) || RUNNER_CACHE}\n`);

  collectInto(results, true);
  report(results, verbose, (performance.now() - t0) / 1000);
  mkdirSync(dirname(outFile), { recursive: true });
  results.sort((a, b) => a.path.localeCompare(b.path));
  writeFileSync(outFile, JSON.stringify({ wpt: wptRevision(), results }, null, 1) + "\n");
  console.log(`\nresults: ${relative(process.cwd(), outFile)}`);
}

/**
 * The WPT revision the results were made at: the full hash, so the record doesn't change shape
 * as the repository grows (a short hash lengthens with its object count).
 */
function wptRevision(): string {
  const r = spawnSync("git", ["-C", WPT, "rev-parse", "HEAD"], { encoding: "utf8" });
  return r.stdout.trim();
}

function report(results: Result[], verbose: boolean, seconds: number): void {
  const dirOf = (p: string) => p.split("/").slice(0, p.startsWith("css/CSS2/") ? 3 : 2).join("/");
  const byDir = new Map<string, Record<Status, number>>();
  const blank = (): Record<Status, number> => ({ pass: 0, fail: 0, skip: 0, error: 0, crash: 0 });
  for (const r of results) {
    const d = dirOf(r.path);
    if (!byDir.has(d)) byDir.set(d, blank());
    byDir.get(d)![r.status]++;
  }
  const total = blank();
  console.log("\n" + "directory".padEnd(32) + "pass".padStart(7) + "fail".padStart(7) + "skip".padStart(7) + "err".padStart(6) + "  pass% of run");
  for (const [d, c] of [...byDir].sort()) {
    for (const k of Object.keys(c) as Status[]) total[k] += c[k];
    const run = c.pass + c.fail + c.error + c.crash;
    console.log(d.padEnd(32) + String(c.pass).padStart(7) + String(c.fail).padStart(7) + String(c.skip).padStart(7) +
      String(c.error + c.crash).padStart(6) + "  " + (run ? `${((100 * c.pass) / run).toFixed(0)}%` : "-"));
  }
  const run = total.pass + total.fail + total.error + total.crash;
  console.log("total".padEnd(32) + String(total.pass).padStart(7) + String(total.fail).padStart(7) + String(total.skip).padStart(7) +
    String(total.error + total.crash).padStart(6) + "  " + (run ? `${((100 * total.pass) / run).toFixed(0)}%` : "-") +
    `   (${results.length} tests, ${seconds.toFixed(0)}s)`);

  // What unlocks the most tests: skip reasons, counting a test once per reason it lists.
  const reasons = new Map<string, number>();
  for (const r of results) if (r.status === "skip" && r.kind !== "other") for (const x of (r.reason ?? "").split(" | ")) reasons.set(x, (reasons.get(x) ?? 0) + 1);
  console.log("\ntop skip reasons (reftests and layout tests):");
  for (const [k, v] of [...reasons].sort((a, b) => b[1] - a[1]).slice(0, 25)) console.log(String(v).padStart(6) + "  " + k);

  const fails = results.filter((r) => r.status === "fail" || r.status === "error" || r.status === "crash");
  console.log(`\n${verbose ? "failures" : "first failures (--verbose for all)"}:`);
  for (const r of verbose ? fails : fails.slice(0, 15)) console.log(`  ${r.status.padEnd(5)} ${r.path}  ${r.reason ?? ""}`);
}

// ---------------------------------------------------------------------------
// wpt show: one test, its reference and a diff, side by side

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf: Buffer): number {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** Encodes RGBA pixels as a PNG (no dependencies). */
function encodePng(rgba: Buffer, w: number, h: number): Buffer {
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/** Composes test | reference | diff (differing pixels red, the rest faded) into one image. */
function composeShow(test: Buffer, ref: Buffer | null): Buffer {
  const panels = ref ? 3 : 1;
  const gap = 8;
  const W = VIEW_W * panels + gap * (panels - 1);
  const out = Buffer.alloc(W * VIEW_H * 4, 0x80);
  const put = (panel: number, x: number, y: number, r: number, g: number, b: number) => {
    const i = (y * W + panel * (VIEW_W + gap) + x) * 4;
    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
    out[i + 3] = 255;
  };
  for (let y = 0; y < VIEW_H; y++) {
    for (let x = 0; x < VIEW_W; x++) {
      const i = (y * VIEW_W + x) * 4;
      put(0, x, y, test[i], test[i + 1], test[i + 2]);
      if (!ref) continue;
      put(1, x, y, ref[i], ref[i + 1], ref[i + 2]);
      const differs = test[i] !== ref[i] || test[i + 1] !== ref[i + 1] || test[i + 2] !== ref[i + 2] || test[i + 3] !== ref[i + 3];
      if (differs) put(2, x, y, 255, 0, 0);
      else {
        const l = Math.round(test[i] * 0.3 + test[i + 1] * 0.59 + test[i + 2] * 0.11);
        const f = 200 + Math.round(l * 0.2);
        put(2, x, y, f, f, f);
      }
    }
  }
  return encodePng(out, W, VIEW_H);
}

async function show(args: string[]): Promise<void> {
  const target = args.find((a) => !a.startsWith("--"));
  if (!target) {
    console.error("usage: native wpt show <test path relative to the WPT root>");
    process.exit(2);
  }
  const abs = target.startsWith("/") ? target : join(WPT, target);
  if (!existsSync(abs)) {
    console.error(`native wpt: ${target} not found`);
    process.exit(1);
  }
  const c = classify(abs);
  if ("status" in c) {
    console.log(`${c.path}: ${c.status} (${c.reason})`);
    return;
  }
  const report = (label: string, path: string) => {
    const diags = new Diagnostics();
    compileApp(join(WPT, path), diags, { root: WPT, ignoreScripts: true });
    console.log(`${label}: ${path}`);
    if (diags.list.length) console.log(diags.format(false).split("\n").map((l) => "  " + l).join("\n"));
  };
  report("test", c.path);
  const matchPaths = c.matchRefs ?? [];
  const mismatchPaths = c.mismatchRefs ?? [];
  for (const refPath of matchPaths) report("match reference", refPath);
  for (const refPath of mismatchPaths) report("mismatch reference", refPath);
  const page = compilePage(c.path, c.kind === "reftest" || c.kind === "testharness", c.kind === "testharness");
  if (!("key" in page)) {
    console.log("not runnable:", "error" in page ? page.error : page.reasons.join(" | "));
    return;
  }
  const refs: Page[] = [];
  // Which references are compared for a match and which for a difference, in the order they run.
  const refMismatch: boolean[] = [];
  const refPaths: string[] = [];
  const take = (paths: string[], mismatch: boolean): boolean => {
    for (const refPath of paths) {
      const r = compilePage(refPath, true);
      if (!("key" in r)) {
        console.log("not runnable:", "error" in r ? r.error : r.reasons.join(" | "));
        return false;
      }
      refs.push(r);
      refMismatch.push(mismatch);
      refPaths.push(refPath);
    }
    return true;
  };
  if (!take(matchPaths, false) || !take(mismatchPaths, true)) return;
  const jobs: Job[] = [{ page, layout: c.kind === "layout", test: c.kind === "testharness" }];
  for (const ref of refs) jobs.push({ page: ref, layout: false, test: false });
  const outDir = join(WORK, "show");
  mkdirSync(outDir, { recursive: true });
  const batch = await runBatch(9999, jobs, outDir, ensureHost());
  const testOut = batch.outputs.get(page.key) ?? batch.failures.get(page.key) ?? "";
  if (c.kind === "layout") console.log(`layout check: ${testOut}`);
  const testRaw = join(outDir, `${page.key}.rgba`);
  if (!existsSync(testRaw)) {
    console.log(`render failed: ${testOut}`);
    return;
  }
  // The diff image shows the closest reference; each one's verdict is printed above it.
  let nearestRaw: string | null = null;
  let nearestPixels = Infinity;
  for (let i = 0; i < refs.length; i++) {
    const ref = refs[i];
    const raw = join(outDir, `${ref.key}.rgba`);
    if (!existsSync(raw)) {
      console.log(`reference ${refPaths[i]}: ${batch.outputs.get(ref.key) ?? batch.failures.get(ref.key) ?? "no output"}`);
      continue;
    }
    const cmp = compareImages(testRaw, raw, c.fuzzy, refMismatch[i]);
    const label = refs.length > 1 ? `reftest (${refPaths[i]})` : "reftest";
    console.log(`${label}: ${cmp.pass ? "PASS" : "FAIL"} (${cmp.detail})${c.fuzzy ? ` fuzzy=${JSON.stringify(c.fuzzy)}` : ""}`);
    if (cmp.pixels < nearestPixels) {
      nearestPixels = cmp.pixels;
      nearestRaw = raw;
    }
  }
  const png = join(outDir, basename(c.path).replace(/\.\w+$/, "") + ".png");
  writeFileSync(png, composeShow(readFileSync(testRaw), nearestRaw !== null && existsSync(nearestRaw) ? readFileSync(nearestRaw) : null));
  console.log(`image: ${relative(process.cwd(), png)}  (test | reference | diff in red)`);
}

export async function main(args: string[]): Promise<void> {
  const sub = args[0];
  if (sub === "fetch") fetch();
  else if (sub === "run") await run(args.slice(1));
  else if (sub === "show") await show(args.slice(1));
  else {
    console.error("usage: native wpt <fetch|run|show> [dir...] [--set extended] [--filter re] [--batch n] [--jobs n] [--out file] [--verbose]");
    console.error("  --set extended (or NATIVE_WPT_EXTENDED=1) adds the html dirs a full run measures");
    process.exit(2);
  }
}
