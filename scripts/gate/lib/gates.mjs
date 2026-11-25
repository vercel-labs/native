// The five gates, each measured the way the SDK's own tests measure it: a build with a cold and a
// warm cache, frames from the host's opt-in timing, a fixed WPT subset, an edit fed to `native dev`
// and timed to the reloaded page, and a screenshot compared with Chrome's.

import { spawn } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromeShot, decodePng, diffImages, findChrome, writeDiff } from "./browser.mjs";
import { parseBuildLog, parseFrames, percentile, sh, windowSize } from "./run.mjs";

/**
 * Fills the run's compiler cache from one app, so the examples that follow are measured on their
 * own compile rather than on the SDK runtime every machine compiles once. Returns the priming
 * build's time.
 */
export function primeCompiler({ cli, root, out, name, timeout, scriptc = null }) {
  const compilerEnv = scriptc === null ? {} : { NATIVE_SCRIPTC: scriptc };
  const dir = join(root, "examples", name);
  const exe = join(out, "prime", name);
  mkdirSync(join(out, "prime"), { recursive: true });
  rmSync(join(dir, ".native"), { recursive: true, force: true });
  const r = sh(process.execPath, [cli, "build", dir, "-o", exe], {
    env: { NATIVE_CACHE_DIR: join(out, "prime", "cache"), SCRIPTC_CACHE_DIR: join(out, "scriptc-cache"), SCRIPTC_STATE_DIR: join(out, "scriptc-state"), ...compilerEnv },
    timeout,
  });
  return { ok: r.status === 0, ms: Math.round(r.ms), error: r.status === 0 ? null : trim(r.stderr) };
}

/** Every example in the repository, sorted, as the suites enumerate it. */
export function examples(root) {
  const dir = join(root, "examples");
  return readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && existsSync(join(dir, e.name, "index.html")))
    .map((e) => e.name)
    .sort();
}

/** Build one example, twice: with an empty cache and again with the cache that build filled. */
export function buildExample({ cli, root, out, name, timeout, reuse = false, scriptc = null }) {
  const compilerEnv = scriptc === null ? {} : { NATIVE_SCRIPTC: scriptc };
  const dir = join(root, "examples", name);
  const cache = join(out, "builds", name, "cache");
  // A Windows build writes <name>.exe; elsewhere the output path is the executable itself.
  const exe = join(out, "builds", name, process.platform === "win32" ? `${name}.exe` : name);
  const record = join(out, "builds", name, "build.json");
  mkdirSync(join(out, "builds", name), { recursive: true });
  if (reuse && existsSync(record) && existsSync(exe)) {
    try {
      const kept = JSON.parse(readFileSync(record, "utf8"));
      if (kept.ok) return { ...kept, exe, reused: true };
    } catch {}
  }
  // A cold build starts with no cache for this app: native's build cache and the app's own build
  // record (which would let it skip scriptc). The compiler's cache is shared by the whole run and
  // primed once before the first example, so what each example pays is its own compile, not the
  // SDK runtime every app on a machine compiles once.
  const cacheEnv = { SCRIPTC_CACHE_DIR: join(out, "scriptc-cache"), SCRIPTC_STATE_DIR: join(out, "scriptc-state") };
  for (const path of [cache, join(dir, ".native")]) rmSync(path, { recursive: true, force: true });
  rmSync(exe, { recursive: true, force: true });

  const cold = sh(process.execPath, [cli, "build", dir, "-o", exe], {
    env: { NATIVE_CACHE_DIR: cache, ...cacheEnv, ...compilerEnv },
    timeout,
  });
  const coldLog = parseBuildLog(cold.stdout + cold.stderr);
  const built = cold.status === 0 && existsSync(exe);
  let warm = null;
  if (built) {
    const r = sh(process.execPath, [cli, "build", dir, "-o", exe], { env: { NATIVE_CACHE_DIR: cache, ...cacheEnv, ...compilerEnv }, timeout });
    const log = parseBuildLog(r.stdout + r.stderr);
    warm = { ms: Math.round(r.ms), ok: r.status === 0, cached: log.cached, scriptcMs: log.scriptcMs };
  }
  const result = {
    name,
    ok: built,
    coldMs: Math.round(cold.ms),
    coldScriptcMs: coldLog.scriptcMs,
    phases: coldLog.phases,
    warmMs: warm === null ? null : warm.ms,
    warmCached: warm === null ? null : warm.cached,
    warmScriptcMs: warm === null ? null : warm.scriptcMs,
    // The tail of the cold build's output, kept so a later change to the phase parsing can be
    // applied to this record without building again.
    logTail: (cold.stdout + cold.stderr).trim().split("\n").slice(-60).join("\n"),
  };
  writeFileSync(record, JSON.stringify(result, null, 2) + "\n");
  return { ...result, exe: built ? exe : null, error: built ? null : trim(cold.stderr || cold.stdout) };
}

function trim(text) {
  const lines = String(text).trim().split("\n");
  return lines.slice(-12).join("\n");
}

/** The steps a smoothness run drives: frames advancing 16 ms apart, a wheel scroll now and then. */
export function smoothSteps(cfg, name, override = null) {
  const scenario = override ?? (cfg.scenarios ?? {})[name] ?? {};
  const frames = cfg.frames ?? 240;
  const scroll = scenario.scroll ?? "body";
  const parts = [];
  if (scenario.pre) parts.push(scenario.pre);
  parts.push("frame 0");
  for (let i = 1; i <= frames; i++) {
    if (i % 20 === 0 && !scenario.noScroll) parts.push(`wheel ${scroll} 600`);
    if (i % 60 === 0 && !scenario.noScroll) parts.push(`wheel ${scroll} -600`);
    parts.push(`frame ${i * 16}`);
  }
  return parts.join(" | ");
}

/**
 * Run an example headlessly through fixed steps and read its frame timings. A scenario's scroll
 * selector that the page doesn't have makes the run exit on the step, so the same frames are run
 * again without a wheel step and the result says which scenario measured it.
 */
export function measureSmoothness({ cfg, name, exe, work }) {
  const storage = join(work, `${name}.storage.json`);
  // A headless macOS run only composites — and so only reports the host's per-frame time — when
  // it asks for the window's live path.
  const hostEnv = process.platform === "darwin" ? { NATIVE_COMPOSITOR_LIVE: "1" } : {};
  const attempt = (scenario) => {
    const r = sh(exe, [], {
      env: { NATIVE_STEPS: smoothSteps(cfg, name, scenario), NATIVE_FRAME_TIMES: "1", NATIVE_STORAGE: storage, ...hostEnv },
      timeout: 300_000,
    });
    return { r, frames: parseFrames(r.stderr) };
  };
  const scenario = (cfg.scenarios ?? {})[name] ?? {};
  let { r, frames } = attempt(scenario);
  let used = scenario.noScroll ? "none" : (scenario.scroll ?? "body");
  if (r.status !== 0 || frames.length === 0) {
    ({ r, frames } = attempt({ ...scenario, noScroll: true }));
    used = "none";
  }
  const timed = cfg.skipFirstFrame === false ? frames : frames.filter((f) => f.n !== frames[0]?.n);
  const totals = timed.map((f) => f.total + (f.host ?? 0));
  const stages = {};
  for (const key of ["style", "anim", "layout", "paint"]) stages[key] = percentile(timed.map((f) => f[key]), 95);
  stages.host = percentile(timed.map((f) => f.host ?? 0), 95);
  const active = timed.filter((f) => f.total + (f.host ?? 0) > 0.5).length;
  return {
    name,
    ok: r.status === 0 && frames.length > 0,
    exit: r.status,
    scroll: used,
    activeShare: timed.length === 0 ? null : Math.round((active / timed.length) * 1000) / 1000,
    frames: frames.length,
    measuredFrames: timed.length,
    firstPaintMs: frames[0] === undefined ? null : round(frames[0].total + (frames[0].host ?? 0)),
    p50: round(percentile(totals, 50)),
    p95: round(percentile(totals, 95)),
    p99: round(percentile(totals, 99)),
    max: round(totals.length === 0 ? null : Math.max(...totals)),
    stages: Object.fromEntries(Object.entries(stages).map(([k, v]) => [k, round(v)])),
    hostPerFrame: process.platform === "darwin",
    error: r.status === 0 ? null : trim(r.stderr),
  };
}

const round = (v) => (v === null || v === undefined ? null : Math.round(v * 100) / 100);

/** The WPT subset: a revision and a directory list from the bars, run with an isolated checkout. */
export function measureCoverage({ cfg, cli, out, timeout }) {
  const wptDir = join(out, "wpt");
  const resultsPath = join(out, "coverage-results.json");
  const env = { NATIVE_WPT: wptDir, NATIVE_CACHE_DIR: join(out, "wpt-cache") };
  let revision = null;
  let fetchError = null;
  if (!existsSync(join(wptDir, "INDEX.md")) && !existsSync(join(wptDir, ".git"))) {
    const fetch = sh(process.execPath, [cli, "wpt", "fetch"], { env, timeout });
    if (fetch.status !== 0) fetchError = trim(fetch.stderr + fetch.stdout);
  }
  if (!fetchError) {
    const have = sh("git", ["-C", wptDir, "cat-file", "-e", `${cfg.wptRevision}^{commit}`]);
    if (have.status !== 0) sh("git", ["-C", wptDir, "fetch", "--depth", "1", "origin", cfg.wptRevision], { env, timeout });
    const checkout = sh("git", ["-C", wptDir, "checkout", "--force", "--detach", cfg.wptRevision]);
    if (checkout.status !== 0) fetchError = trim(checkout.stderr);
    revision = sh("git", ["-C", wptDir, "rev-parse", "HEAD"]).stdout.trim() || null;
  }
  if (fetchError) {
    return { ok: false, error: fetchError, revision, dirs: cfg.dirs, perDir: [], totals: null, passRate: null, blockers: [] };
  }
  const run = sh(process.execPath, [cli, "wpt", "run", ...cfg.dirs, "--jobs", String(cfg.jobs), "--batch", String(cfg.batch), "--out", resultsPath], { env, timeout });
  if (!existsSync(resultsPath)) {
    return { ok: false, error: trim(run.stderr + run.stdout), revision, dirs: cfg.dirs, perDir: [], totals: null, passRate: null, blockers: [] };
  }
  const data = JSON.parse(readFileSync(resultsPath, "utf8"));
  const results = data.results ?? [];
  const totals = { pass: 0, fail: 0, skip: 0, error: 0, crash: 0, total: results.length };
  const perDir = new Map();
  const reasons = new Map();
  const failures = new Map();
  for (const r of results) {
    totals[r.status] = (totals[r.status] ?? 0) + 1;
    const dir = cfg.dirs.find((d) => r.path === d || r.path.startsWith(d + "/")) ?? "(other)";
    const d = perDir.get(dir) ?? { dir, pass: 0, fail: 0, skip: 0, error: 0, crash: 0, total: 0 };
    d[r.status] = (d[r.status] ?? 0) + 1;
    d.total++;
    perDir.set(dir, d);
    if (r.status === "skip" && r.reason) {
      for (const reason of String(r.reason).split(" | ")) reasons.set(reason, (reasons.get(reason) ?? 0) + 1);
    }
    if ((r.status === "fail" || r.status === "error" || r.status === "crash") && failures.size < 200) {
      failures.set(r.path, r.status);
    }
  }
  const runnable = totals.pass + totals.fail + totals.error + totals.crash;
  const passRate = runnable === 0 ? null : totals.pass / runnable;
  const blockers = [...reasons.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([reason, count]) => ({ reason, count }));
  const dirs = [...perDir.values()].map((d) => {
    const n = d.pass + d.fail + d.error + d.crash;
    return { ...d, passRate: n === 0 ? null : d.pass / n };
  }).sort((a, b) => (a.passRate ?? 1) - (b.passRate ?? 1));
  return {
    ok: true,
    revision: data.wpt ?? revision,
    dirs: cfg.dirs,
    totals,
    runnable,
    passRate,
    perDir: dirs,
    blockers,
    failures: [...failures.entries()].slice(0, 25).map(([path, status]) => ({ path, status })),
    resultsFile: resultsPath,
  };
}

/** The committed macOS results, restricted to the same subset, for context beside today's run. */
export function committedCoverage(cfg, root) {
  const path = join(root, "packages/cli/wpt/results.json");
  if (!existsSync(path)) return null;
  const data = JSON.parse(readFileSync(path, "utf8"));
  const totals = { pass: 0, fail: 0, skip: 0, error: 0, crash: 0 };
  const perDir = new Map();
  const reasons = new Map();
  for (const r of data.results ?? []) {
    const dir = cfg.dirs.find((d) => r.path === d || r.path.startsWith(d + "/"));
    if (dir === undefined) continue;
    totals[r.status] = (totals[r.status] ?? 0) + 1;
    const d = perDir.get(dir) ?? { dir, pass: 0, fail: 0, skip: 0, error: 0, crash: 0 };
    d[r.status] = (d[r.status] ?? 0) + 1;
    perDir.set(dir, d);
    if (r.status === "skip" && r.reason) {
      for (const reason of String(r.reason).split(" | ")) reasons.set(reason, (reasons.get(reason) ?? 0) + 1);
    }
  }
  const runnable = totals.pass + totals.fail + totals.error + totals.crash;
  const dirs = [...perDir.values()].map((d) => {
    const n = d.pass + d.fail + d.error + d.crash;
    return { ...d, passRate: n === 0 ? null : d.pass / n };
  }).sort((a, b) => (a.passRate ?? 1) - (b.passRate ?? 1));
  return {
    revision: data.wpt,
    ...totals,
    passRate: runnable === 0 ? null : totals.pass / runnable,
    perDir: dirs,
    blockers: [...reasons.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([reason, count]) => ({ reason, count })),
  };
}

/**
 * Hot reload: start `native dev` on an example, edit its script, and time the edit to the reloaded
 * page. The first edit is a warm-up whose wait includes the dev host's one-time build, so it is
 * reported separately and kept out of the p95.
 */
export async function measureReload({ cli, root, out, name, edits, timeout }) {
  const dir = join(root, "examples", name);
  const scripts = readdirSync(dir).filter((f) => /\.(tsx?|jsx?|mjs)$/.test(f));
  if (scripts.length === 0) return { name, ok: false, error: "no script to edit" };
  const script = join(dir, scripts[0]);
  const original = readFileSync(script, "utf8");
  const buildOut = join(out, "reload", name);
  mkdirSync(buildOut, { recursive: true });

  const env = { ...process.env, NATIVE_CACHE_DIR: join(out, "reload-cache", name) };
  const child = spawn(process.execPath, [cli, "dev", dir, "-o", buildOut], { env, stdio: ["ignore", "pipe", "pipe"] });
  /** Every line the dev command printed, and the first one not yet matched. */
  const lines = [];
  let cursor = 0;
  const waiters = new Set();
  const note = (line) => {
    lines.push(line);
    for (const w of [...waiters]) w();
  };
  child.stdout.on("data", (d) => String(d).split("\n").filter(Boolean).forEach(note));
  child.stderr.on("data", (d) => String(d).split("\n").filter(Boolean).forEach(note));

  /**
   * The first line after the last match that `re` matches, waiting for it if it has not arrived.
   * Each match moves the cursor, so the next edit waits for its own reload line rather than
   * finding the previous edit's.
   */
  const waitFor = (re, ms) => new Promise((resolve) => {
    const scan = () => {
      for (let i = cursor; i < lines.length; i++) {
        if (!re.test(lines[i])) continue;
        cursor = i + 1;
        return lines[i];
      }
      return null;
    };
    const found = scan();
    if (found !== null) return resolve(found);
    const timer = setTimeout(() => {
      waiters.delete(check);
      resolve(null);
    }, ms);
    const check = () => {
      if (scan() === null) return;
      clearTimeout(timer);
      waiters.delete(check);
      resolve(lines[cursor - 1]);
    };
    waiters.add(check);
  });

  const results = { name, ok: false, edits: [], warmupMs: null };
  try {
    const watching = await waitFor(/native: watching/, 900_000);
    if (watching === null) {
      results.error = "native dev never started watching";
      return results;
    }
    // `native dev` prints that it is watching before the dev host is built, and an edit made
    // before the page exists is applied but never announced. So the warm-up edit is written again
    // until one is acknowledged; each write changes the file, so whichever lands after the app is
    // live is the one that reloads.
    const RELOAD = /native: (?:reloaded scripts in \d+ms|edit→screen \d+ms)/;
    for (let attempt = 0; attempt < 20 && results.warmupMs === null; attempt++) {
      writeFileSync(script, `${original}\n// gate warm-up ${attempt}\n`);
      const line = await waitFor(RELOAD, 30_000);
      if (line !== null) results.warmupMs = reloadMs(line);
    }
    if (results.warmupMs === null) {
      results.error = "no reload was acknowledged";
      results.log = lines.slice(-15);
      return results;
    }
    for (let i = 0; i < edits; i++) {
      writeFileSync(script, `${original}\n// gate reload probe ${i}\n`);
      const line = await waitFor(RELOAD, 120_000);
      if (line === null) {
        results.error = `edit ${i} was not acknowledged`;
        results.log = lines.slice(-15);
        break;
      }
      results.edits.push(reloadMs(line));
    }
    results.ok = results.edits.length > 0;
  } finally {
    writeFileSync(script, original);
    child.kill("SIGINT");
    setTimeout(() => child.kill("SIGKILL"), 4000).unref();
  }
  results.p50 = round(percentile(results.edits, 50));
  results.p95 = round(percentile(results.edits, 95));
  results.max = results.edits.length === 0 ? null : Math.max(...results.edits);
  return results;
}

/** The milliseconds a dev command's reload line reports: the island's reload, or a relaunch. */
function reloadMs(line) {
  const m = /reloaded scripts in (\d+)ms/.exec(line) ?? /edit→screen (\d+)ms/.exec(line);
  return m === null ? null : Number(m[1]);
}

/** One example in Chrome and in native, at frame 0, compared pixel by pixel. */
export async function measureParity({ root, out, name, exe, chrome, delta, scale, work, virtualTimeMs }) {
  const dir = join(root, "examples", name);
  const html = readFileSync(join(dir, "index.html"), "utf8");
  const size = windowSize(html);
  const nativePng = join(out, "shots", `${name}-native.png`);
  const chromePng = join(out, "shots", `${name}-chrome.png`);
  const diffPng = join(out, "shots", `${name}-diff.png`);
  mkdirSync(join(out, "shots"), { recursive: true });
  // Both engines are photographed at the same point in the animation clock, and native is stepped
  // there in 16 ms frames like the 60 fps run Chrome makes: a single jump would let an app that
  // caps its delta hand native a different animation time than the browser shows.
  const steps = ["frame 0"];
  for (let t = 16; t <= virtualTimeMs; t += 16) steps.push(`frame ${t}`);
  const run = sh(exe, [], {
    env: {
      NATIVE_STEPS: steps.join(" | "),
      NATIVE_SNAPSHOT: nativePng,
      NATIVE_STORAGE: join(work, `${name}.parity.storage.json`),
    },
    timeout: 300_000,
  });
  if (run.status !== 0 || !existsSync(nativePng)) {
    return { name, ok: false, error: trim(run.stderr), size, chrome: chrome === null ? "missing" : "ran" };
  }
  if (chrome === null) {
    return { name, ok: false, error: "no Chrome binary", size, nativePng, missingChrome: true };
  }
  const shot = await chromeShot(chrome, dir, { width: size.width, height: size.height, scale, outPng: chromePng, virtualTimeMs });
  if (!shot.ok) return { name, ok: false, error: `chrome: ${shot.stderr}`, size, nativePng };
  const a = decodePng(nativePng);
  const b = decodePng(chromePng);
  const diff = diffImages(a, b, delta);
  writeDiff(a, b, delta, diffPng);
  return {
    name,
    ok: true,
    size,
    identical: diff.identical,
    meanDelta: round(diff.meanDelta),
    nativeSize: [a.w, a.h],
    chromeSize: [b.w, b.h],
    browserMode: shot.mode,
    browserError: shot.error ?? null,
    nativePng,
    chromePng,
    diffPng,
  };
}

/** An example runs when it exits cleanly and paints something with more than one colour. */
export function measureRun({ name, exe, work }) {
  const png = join(work, `${name}.run.png`);
  const r = sh(exe, [], {
    env: { NATIVE_STEPS: "frame 0 | frame 16", NATIVE_SNAPSHOT: png, NATIVE_STORAGE: join(work, `${name}.run.storage.json`) },
    timeout: 300_000,
  });
  let colours = 0;
  if (r.status === 0 && existsSync(png)) {
    const img = decodePng(png);
    const seen = new Set();
    for (let i = 0; i < img.rgba.length; i += 4) seen.add((img.rgba[i] << 16) | (img.rgba[i + 1] << 8) | img.rgba[i + 2]);
    colours = seen.size;
  }
  return { name, ok: r.status === 0 && colours > 1, exit: r.status, colours, error: r.status === 0 ? null : trim(r.stderr) };
}

export { findChrome };
