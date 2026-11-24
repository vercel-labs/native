// native dev: applies HTML/CSS edits to the running window. A script edit is rebundled and rerun
// in the host's island, in the page that is already open; `--compiled` rebuilds and relaunches
// the executable instead, as every build did before the island existed.

import { existsSync, mkdirSync, readFileSync, rmSync, watch, writeFileSync } from "node:fs";
import type { FSWatcher } from "node:fs";
import { extname, join, relative, sep } from "node:path";
import { spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { appDirOf, appSources, emitApp, openApp, scriptSignature, writeDevData } from "./build.ts";
import type { AppBuild } from "./build.ts";
import { changedModules, moduleName, readLastManifest, summarizeModules } from "./cache.ts";
import { createScriptBundler } from "./dev-bundle.ts";
import type { ScriptBundler } from "./dev-bundle.ts";
import { ensureDevHost, libnodePack } from "./dev-host.ts";
import { findingKey, runCoverage, writeCoverageProject } from "./dev-coverage.ts";
import type { CoverageFinding } from "./dev-coverage.ts";
import { startInspector } from "./inspect.ts";
import type { Inspector } from "./inspect.ts";
import { devSourcesPath, writeDevSources } from "./source-map.ts";
import { BuildProgress } from "./progress.ts";

/** The markup and style files a reload applies, and the script files that need a rebuild. */
const EDITABLE = new Set([".html", ".htm", ".css", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".json"]);
const SCRIPTS = new Set([".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".json"]);
const MARKUP = new Set([".html", ".htm", ".css"]);

/** Waits this long after the last event, so a burst of writes is one change. */
const SETTLE_MS = 80;

/** How long a script reload waits for the host to say the new bundle ran. The host acknowledges
 *  after re-mounting the page and running the bundle, which on a loaded machine can pass 2 s. */
const ACK_MS = 5000;

function say(msg: string): void {
  console.error(`native: ${msg}`);
}

/**
 * The source table a dev build's runtime maps exceptions with. A build that came from the cache
 * compiled nothing and wrote none, so one is made here from the app's own files: a module a
 * dependency ships keeps its build path in that case, which is all a cached start can lose.
 */
function ensureDevSources(built: AppBuild): void {
  if (existsSync(devSourcesPath(built.appDir))) return;
  const srcOut = join(built.appDir, ".native", "src");
  const inlineFiles: { file: string; line: number }[] = [];
  let inlineIndex = 0;
  for (const s of built.app.scripts) {
    if (s.module && s.path === null) {
      inlineFiles.push({ file: join(srcOut, `.inline-${inlineIndex++}.js`), line: s.line });
    }
  }
  const classic = built.app.scripts.filter((s) => !s.module);
  // writeClassicScripts writes one TypeScript module when any classic script is TypeScript.
  const anyTs = classic.some((s) => s.path !== null && /\.[cm]?tsx?$/.test(s.path));
  const classicBundle = classic.length > 0 ? join(srcOut, anyTs ? ".scripts.ts" : ".scripts.js") : null;
  const handlerFile = classicBundle === null && built.app.handlers.length > 0 ? join(srcOut, ".handlers.js") : null;
  writeDevSources({
    appDir: built.appDir,
    htmlPath: built.htmlPath,
    app: built.app,
    sdk: "",
    srcOut,
    appFiles: [...appSources(built.appDir)].map((s) => s.path),
    vendored: new Map(),
    inlineFiles,
    classicBundle,
    handlerFile,
    firstClassicLine: classic.length > 0 ? classic[0].line : 1,
    firstHandlerLine: built.app.handlers.length > 0 ? built.app.handlers[0].line : 1,
  });
}

/** Which path `native dev` takes: the island when a libnode pack is here, else today's
 *  compiled build. `--compiled` asks for the compiled build whatever is installed. */
export function devMode(compiled: boolean): "island" | "compiled" {
  if (compiled) return "compiled";
  return libnodePack() === null ? "compiled" : "island";
}

export async function dev(input: string, out: string | null, inspectPort: number | null = null,
  compiled = false): Promise<void> {
  const mode = devMode(compiled);
  if (mode === "compiled" && !compiled)
    say("running the compiled build: no @scriptc/libnode pack is installed, and island reloading needs one");
  await (mode === "island" ? devIsland(input, out, inspectPort) : devCompiled(input, out, inspectPort));
}

/** The inspector when one was asked for; a taken port leaves the session working without one. */
async function openInspector(appDir: string, buildDir: string, inspectPort: number | null): Promise<Inspector | null> {
  if (inspectPort === null) return null;
  try {
    const inspector = await startInspector({ appDir, buildDir, port: inspectPort });
    say(`inspector on ${inspector.url}`);
    return inspector;
  } catch (err) {
    say(`inspector: ${err instanceof Error ? err.message : String(err)}`);
    return null;
  }
}

/** Starts the executable, and with an inspector pipes what it prints through the dev command so
 *  the console panel sees each line as the app writes it. */
function startExecutable(executable: string, cwd: string, env: NodeJS.ProcessEnv, inspector: Inspector | null): ChildProcess {
  const running = spawn(executable, [], { cwd, stdio: inspector === null ? "inherit" : ["inherit", "pipe", "pipe"], env });
  if (inspector !== null) {
    const streaming = inspector;
    const pending = { stdout: "", stderr: "" };
    const forward = (stream: "stdout" | "stderr", text: string): void => {
      pending[stream] += text;
      const lines = pending[stream].split("\n");
      pending[stream] = lines.pop() ?? "";
      for (const line of lines) {
        const out = stream === "stdout" ? process.stdout : process.stderr;
        out.write(line + "\n");
        streaming.log(stream, line);
      }
    };
    running.stdout?.on("data", (chunk: Buffer) => forward("stdout", chunk.toString("utf8")));
    running.stderr?.on("data", (chunk: Buffer) => forward("stderr", chunk.toString("utf8")));
  }
  return running;
}

/** The island path: a cached dev host runs the app's scripts in a Node island, so a script edit
 *  is a rebundle and a rerun, not a recompile and a relaunch. */
async function devIsland(input: string, out: string | null, inspectPort: number | null): Promise<void> {
  const appDir = appDirOf(input);
  const buildDir = join(appDir, ".native");
  mkdirSync(buildDir, { recursive: true });
  const dataFile = join(buildDir, "dev.json");
  const stateFile = join(buildDir, "dev-state.json");
  const ctlFile = join(buildDir, "dev.ctl");
  const scriptsFile = join(buildDir, "dev-scripts.token");
  const bundleFile = join(buildDir, "dev-bundle.js");
  const findingsFile = join(buildDir, "dev-findings.json");
  const ackFile = `${scriptsFile}.ack`;
  // State and tokens an earlier session left aren't this page's.
  rmSync(stateFile, { force: true });
  rmSync(ctlFile, { force: true });
  rmSync(scriptsFile, { force: true });
  rmSync(ackFile, { force: true });
  rmSync(findingsFile, { force: true });

  const inspector = await openInspector(appDir, buildDir, inspectPort);
  const host = await ensureDevHost(say);
  // A shipped host was built on another machine, and an executable records the libnode pack's
  // path at build time: point it at this install's pack instead. A host built here already
  // records this machine's own path.
  const pack = host.prebuilt ? libnodePack() : null;
  const env = {
    ...process.env,
    ...(pack === null ? {} : { SCRIPTC_LIBNODE: pack.dir }),
    NATIVE_DEV_TABLES: dataFile,
    NATIVE_DEV_STATE: stateFile,
    NATIVE_DEV_CTL: ctlFile,
    NATIVE_INSPECT_DIR: inspector === null ? "" : join(buildDir, ".inspect"),
    NATIVE_DEV_SOURCES: devSourcesPath(appDir),
    // What the island runs, and the token file that tells it when to run a new one.
    NATIVE_DEV_BUNDLE: bundleFile,
    NATIVE_DEV_SCRIPTS: scriptsFile,
    NATIVE_DEV_FINDINGS: findingsFile,
    // The island refuses code generation from strings (the loader's eval/Function guards): say
    // so, so scriptc's load hook does not warn that the command line lacks the flag. A compiled
    // program's environment is not a Node process, so NODE_OPTIONS itself reaches nothing.
    NODE_OPTIONS: [process.env["NODE_OPTIONS"], "--disallow-code-generation-from-strings"]
      .filter((value) => value !== undefined && value !== "")
      .join(" "),
  };

  const fail = (err: unknown): void => {
    console.error(err instanceof Error ? err.message : String(err));
  };

  let child: ChildProcess | null = null;
  /** Whether the island is running: the first bundle that builds opens the window. */
  let started = false;
  const start = (): void => {
    const running = startExecutable(host.executable, appDir, env, inspector);
    child = running;
    running.on("exit", (code) => {
      if (watcher !== null) watcher.close();
      inspector?.close();
      process.exit(code ?? 0);
    });
  };

  let watcher: FSWatcher | null = null;
  let bundler: ScriptBundler | null = null;
  /** The page's scripts as last bundled; a change to the set means a new context. */
  let scripts = "";

  const prepare = async (built: AppBuild): Promise<string> => {
    writeDevData(built.appDir, built.app);
    if (bundler === null) bundler = await createScriptBundler(built);
    const result = await bundler.rebuild(built);
    ensureDevSources(built);
    if (result.errors === "") scripts = scriptSignature(built.app.scripts);
    return result.errors;
  };

  // Coverage: what a release build would analyze, in the background after the island has run
  // the new scripts. Findings are reported when they arrive; the reload never waits for it.
  const reported = new Set<string>();
  let coverageRunning = false;
  let coveragePending = false;
  let coverageAbort: AbortController | null = null;
  let findingsToken = 0;
  const writeFindings = (summary: string, findings: CoverageFinding[]): void => {
    findingsToken += 1;
    writeFileSync(findingsFile, JSON.stringify({ token: findingsToken, summary, findings }) + "\n");
  };
  const coveragePass = async (): Promise<void> => {
    if (coverageRunning) {
      // The running analysis is about code the page no longer has: stop it and start over.
      coveragePending = true;
      coverageAbort?.abort();
      return;
    }
    coverageRunning = true;
    const controller = new AbortController();
    coverageAbort = controller;
    const started = performance.now();
    try {
      let built: AppBuild;
      try {
        built = openApp(input);
      } catch {
        return;
      }
      const entry = writeCoverageProject(built);
      if (entry === null) {
        writeFindings("", []);
        return;
      }
      const report = await runCoverage(built.appDir, entry, process.env, controller.signal);
      if (report === null) return;
      // Errors are what a release build stops on; the warnings below them are about how the code
      // compiles, and are counted rather than listed.
      const errors = report.findings.filter((finding) => finding.severity === "error");
      const warnings = report.findings.length - errors.length;
      const keys = new Set(errors.map(findingKey));
      const fresh = errors.filter((finding) => !reported.has(findingKey(finding)));
      reported.clear();
      for (const key of keys) reported.add(key);
      for (const finding of fresh)
        say(`coverage: ${finding.file}:${finding.line}:${finding.column} ${finding.code} ${finding.message}`);
      if (fresh.length > 0)
        say(`coverage: ${fresh.length} new finding${fresh.length === 1 ? "" : "s"}; a release build stops on the errors it reports`);
      const took = Math.round(performance.now() - started);
      const how = took >= 1500 ? ` (checked in ${(took / 1000).toFixed(0)}s)` : "";
      if (report.summary !== "") say(`coverage: ${report.summary}${how}`);
      if (warnings > 0)
        say(`coverage: ${warnings} warning${warnings === 1 ? "" : "s"} about how the code compiles (not listed)`);
      writeFindings(report.summary, errors);
    } finally {
      coverageRunning = false;
      if (coverageAbort === controller) coverageAbort = null;
      if (coveragePending) {
        coveragePending = false;
        void coveragePass();
      }
    }
  };

  const first = (() => {
    try {
      return openApp(input) as AppBuild;
    } catch (err) {
      fail(err);
      return null;
    }
  })();
  if (first !== null) {
    try {
      const errors = await prepare(first);
      if (errors === "") {
        start();
        started = true;
        say("coverage: checking what a release build would compile, in the background; it cannot see a refusal that depends on a run-time value, so a compiled smoke run is still the last word");
        void coveragePass();
      } else {
        // Nothing to run: an island started now would run no bundle (or a stale one). The first
        // save that bundles opens the window.
        fail(`the page's scripts did not build, so the host has none to run:\n${errors}`);
        say("the scripts did not bundle; the window opens on the first save that does");
      }
    } catch (err) {
      fail(err);
    }
  }

  /** Waits for the host to acknowledge `token`, or gives up: the window keeps running either way. */
  const waitForAck = async (token: string): Promise<boolean> => {
    const deadline = performance.now() + ACK_MS;
    while (performance.now() < deadline) {
      if (existsSync(ackFile) && readFileSync(ackFile, "utf8") === token) return true;
      await new Promise<void>((resolve) => setTimeout(resolve, 10));
    }
    return false;
  };

  const flush = async (changed: string[]): Promise<void> => {
    if (changed.length === 0) return;
    const t0 = performance.now();
    let built: AppBuild;
    try {
      // A broken edit keeps the last good page on screen; the next save tries again.
      built = openApp(input);
    } catch (err) {
      fail(err);
      return;
    }
    let scriptChanged = false;
    let markupChanged = false;
    for (const file of changed) {
      const ext = extname(file);
      if (SCRIPTS.has(ext)) scriptChanged = true;
      else if (MARKUP.has(ext)) markupChanged = true;
    }
    if (scriptChanged || scriptSignature(built.app.scripts) !== scripts) {
      const signature = scriptSignature(built.app.scripts);
      if (bundler === null) bundler = await createScriptBundler(built);
      const result = await bundler.rebuild(built);
      if (result.errors !== "") {
        // esbuild's message, named as the failed reload it is: the window stays up on the last
        // bundle that ran, and a caller watching for a reload sees why none came.
        fail(`script reload failed: the new bundle did not compile, so the page kept the last one:\n${result.errors}`);
        return;
      }
      writeDevData(built.appDir, built.app);
      ensureDevSources(built);
      scripts = signature;
      if (!started) {
        start();
        started = true;
      }
      const token = String(Date.now());
      writeFileSync(scriptsFile, token);
      const acknowledged = await waitForAck(token);
      if (acknowledged) say(`reloaded scripts in ${Math.round(performance.now() - t0)}ms`);
      // The host keeps running either way; a reload no one confirmed is not reported as done.
      else say(`script reload failed: the host did not acknowledge the new bundle within ${ACK_MS / 1000}s`);
      // In the background: the window has the new scripts, and the report arrives when it does.
      void coveragePass();
      return;
    }
    if (markupChanged) {
      writeDevData(built.appDir, built.app);
      say(`reloaded HTML/CSS in ${(performance.now() - t0).toFixed(0)}ms`);
    }
  };

  // Changes are handled one at a time, in the order they were seen: a reload reads the page's
  // files, and two at once would race over the same files.
  let chain: Promise<void> = Promise.resolve();
  const pending: string[] = [];
  let timer: ReturnType<typeof setTimeout> | null = null;
  const queue = (file: string): void => {
    pending.push(file);
    if (timer !== null) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      const changed = pending.slice();
      pending.length = 0;
      chain = chain.then(() => flush(changed));
    }, SETTLE_MS);
  };

  const ignored = (name: string): boolean => {
    const parts = name.split(sep).join("/").split("/");
    for (const part of parts) {
      if (part === "node_modules" || part === ".git" || part.startsWith(".")) return true;
    }
    return !EDITABLE.has(extname(name));
  };

  watcher = watch(appDir, { recursive: true }, (_event, name) => {
    if (name === null) return;
    const file = name.split(sep).join("/");
    if (ignored(file)) return;
    queue(file);
  });
  say(`watching ${relative(process.cwd(), appDir) || "."}`);

  const stop = (): void => {
    if (watcher !== null) watcher.close();
    if (child !== null) child.kill();
    inspector?.close();
    void bundler?.dispose();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  void out;
}

/** The compiled path: every script edit rebuilds the executable and relaunches it. */
async function devCompiled(input: string, out: string | null, inspectPort: number | null): Promise<void> {
  const appDir = appDirOf(input);
  const buildDir = join(appDir, ".native");
  const dataFile = join(buildDir, "dev.json");
  const stateFile = join(buildDir, "dev-state.json");
  const ctlFile = join(buildDir, "dev.ctl");
  const readyFile = join(buildDir, "dev-ready");
  mkdirSync(buildDir, { recursive: true });
  // A state file left by an earlier session isn't this page's.
  rmSync(stateFile, { force: true });
  rmSync(ctlFile, { force: true });
  rmSync(readyFile, { force: true });

  const inspector = await openInspector(appDir, buildDir, inspectPort);

  const env = {
    ...process.env,
    NATIVE_DEV_TABLES: dataFile,
    NATIVE_DEV_STATE: stateFile,
    NATIVE_DEV_CTL: ctlFile,
    NATIVE_DEV_READY: readyFile,
    NATIVE_INSPECT_DIR: inspector === null ? "" : join(buildDir, ".inspect"),
    // The module-to-source table a build writes, so the app reports an exception against the
    // developer's own files and lines.
    NATIVE_DEV_SOURCES: devSourcesPath(appDir),
  };

  let watcher: FSWatcher | null = null;
  let child: ChildProcess | null = null;
  let restarting = false;
  /** The page's scripts as last built; a change to them needs a new executable. */
  let scripts = "";
  let output = "";
  /** When the edit that started the current relaunch was picked up; 0 when nothing is pending. */
  let editAt = 0;
  /** When the new executable was linked, before the old process is asked to hand over. */
  let builtAt = 0;
  /** The ready token last read, so the first frame of one launch is reported once. */
  let readySeen = "";

  const fail = (err: unknown): void => {
    console.error(err instanceof Error ? err.message : String(err));
  };

  const start = (): void => {
    const running = startExecutable(output, process.cwd(), env, inspector);
    child = running;
    running.on("exit", (code) => {
      if (restarting) return;
      if (watcher !== null) watcher.close();
      inspector?.close();
      process.exit(code ?? 0);
    });
  };

  /** Asks the running executable to save its state and exit, then starts the new one. */
  const relaunch = (): void => {
    restarting = true;
    const old = child;
    if (old === null) {
      start();
      restarting = false;
      return;
    }
    let done = false;
    const finish = (): void => {
      if (done) return;
      done = true;
      start();
      restarting = false;
    };
    old.once("exit", finish);
    // The running build watches this file; a token it hasn't seen means "save and exit".
    writeFileSync(ctlFile, String(Date.now()));
    setTimeout(() => {
      if (!done) old.kill("SIGTERM");
    }, 2000);
  };

  /** Compiles and starts a new executable, returning false when the scripts didn't compile. */
  const rebuild = async (built: AppBuild, signature: string, t0: number): Promise<boolean> => {
    const before = readLastManifest(built.appDir);
    const progress = new BuildProgress();
    let result;
    try {
      result = await emitApp(built, out, true, undefined, undefined, progress);
    } catch (err) {
      progress.fail();
      fail(err);
      return false;
    }
    scripts = signature;
    output = result.output;
    builtAt = Date.now();
    ensureDevSources(built);
    if (!result.cached && before !== null) {
      const after = readLastManifest(built.appDir);
      const changed = after === null ? [] : changedModules(before, after);
      if (changed.length > 0) {
        say(`changed ${changed.length} ${changed.length === 1 ? "module" : "modules"}: ${summarizeModules(changed.map(moduleName))}`);
      }
    }
    say(`rebuilt in ${((performance.now() - t0) / 1000).toFixed(1)}s${result.cached ? " (cached)" : ""}`);
    if (child === null) start();
    else relaunch();
    return true;
  };

  /** A build runs asynchronously now, so an edit made while one is compiling waits for it. */
  let building = false;
  let waiting: string[] = [];

  /** Reports an edit's first painted frame, which the new executable writes when it gets there. */
  const checkReady = (): void => {
    if (!existsSync(readyFile)) return;
    let token = "";
    try {
      token = readFileSync(readyFile, "utf8").trim();
    } catch {
      return;
    }
    if (token === "" || token === readySeen) return;
    readySeen = token;
    // A launch's own first frame (the session's first, or a rebuilding one) has no edit to time.
    if (editAt === 0) return;
    const at = Number(token);
    if (!isFinite(at)) return;
    const now = Date.now();
    say(`edit→screen ${now - editAt}ms (native+scriptc ${builtAt - editAt}ms, launch+first frame ${now - builtAt}ms)`);
    editAt = 0;
  };
  const readyPoll = setInterval(checkReady, 15);
  readyPoll.unref();

  const flushNow = async (changed: string[]): Promise<void> => {
    const t0 = performance.now();
    const editedAt = pendingEditAt === 0 ? Date.now() : pendingEditAt;
    pendingEditAt = 0;
    let built: AppBuild;
    try {
      built = openApp(input);
    } catch (err) {
      // A broken edit keeps the last good page on screen; the next save tries again.
      fail(err);
      return;
    }
    const signature = scriptSignature(built.app.scripts);
    let scriptChanged = false;
    let markupChanged = false;
    for (const file of changed) {
      const ext = extname(file);
      if (SCRIPTS.has(ext)) scriptChanged = true;
      else if (MARKUP.has(ext)) markupChanged = true;
    }
    let reloadStart = t0;
    if (child === null || scriptChanged || signature !== scripts) {
      editAt = editedAt;
      if (await rebuild(built, signature, t0)) return;
      editAt = 0;
      // The scripts didn't compile. If markup changed too, the window that is already up can
      // still show it; a script-only edit has nothing to send, so the next save tries again.
      if (child === null || !markupChanged) return;
      reloadStart = performance.now();
    }
    writeDevData(built.appDir, built.app);
    scripts = signature;
    say(`reloaded HTML/CSS in ${(performance.now() - reloadStart).toFixed(0)}ms`);
  };

  const flush = (changed: string[]): void => {
    if (changed.length === 0) return;
    if (building) {
      waiting.push(...changed);
      return;
    }
    building = true;
    void flushNow(changed).finally(() => {
      building = false;
      if (waiting.length > 0) {
        const next = waiting;
        waiting = [];
        flush(next);
      }
    });
  };

  const pending: string[] = [];
  /** When the first file of the burst being saved arrived; 0 between bursts. */
  let pendingEditAt = 0;
  let timer: ReturnType<typeof setTimeout> | null = null;
  const queue = (file: string): void => {
    if (pending.length === 0) pendingEditAt = Date.now();
    pending.push(file);
    if (timer !== null) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      const changed = pending.slice();
      pending.length = 0;
      flush(changed);
    }, SETTLE_MS);
  };

  const ignored = (name: string): boolean => {
    const parts = name.split(sep).join("/").split("/");
    for (const part of parts) {
      if (part === "node_modules" || part === ".git" || part.startsWith(".")) return true;
    }
    return !EDITABLE.has(extname(name));
  };

  watcher = watch(appDir, { recursive: true }, (_event, name) => {
    if (name === null) return;
    const file = name.split(sep).join("/");
    if (ignored(file)) return;
    queue(file);
  });

  const first = (() => {
    try {
      return openApp(input);
    } catch (err) {
      fail(err);
      return null;
    }
  })();
  if (first !== null) {
    const signature = scriptSignature(first.app.scripts);
    const progress = new BuildProgress();
    try {
      // The first build compiles the whole app, which on a large one takes minutes: it reports
      // its phases like `native build` does.
      const result = await emitApp(first, out, true, undefined, undefined, progress);
      scripts = signature;
      output = result.output;
      ensureDevSources(first);
      start();
    } catch (err) {
      progress.fail();
      fail(err);
    }
  }
  say(`watching ${relative(process.cwd(), appDir) || "."}`);

  const stop = (): void => {
    if (watcher !== null) watcher.close();
    if (child !== null) child.kill();
    inspector?.close();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}
