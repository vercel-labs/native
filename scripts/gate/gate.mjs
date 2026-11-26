#!/usr/bin/env node
// The quality scorecard: measures Native SDK against a set of quality bars and writes
// SCORECARD.md and scorecard.json. Every gate reports today's number whether or not it
// passes, and each failing gate names the three gaps to close first and the code area to close
// them in.
//
//   node scripts/gate/gate.mjs --out build/scorecard
//   node scripts/gate/gate.mjs --only smoothness,coverage --examples counter,todo
//   node scripts/gate/gate.mjs --screens <SCOREBOARD.md>
//
// The bars, the WPT subset and its revision, and the scenarios live in bars.json beside this file.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
import { cpus, totalmem } from "node:os";
import { dirname, join, resolve } from "node:path";
import { buildExample, committedCoverage, primeCompiler, examples, measureCoverage, measureParity, measureReload, measureRun, measureSmoothness, findChrome } from "./lib/gates.mjs";
import { percentile, sh } from "./lib/run.mjs";

const here = import.meta.dirname;
const root = resolve(here, "..", "..");
const bars = JSON.parse(readFileSync(join(here, "bars.json"), "utf8"));

/** Examples whose frame is animation content rather than a rendering rule: reported, not judged. */
const timingSensitive = new Set(bars.chrome.timingSensitive ?? []);

const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const at = argv.indexOf(`--${name}`);
  return at >= 0 ? argv[at + 1] : fallback;
};
const has = (name) => argv.includes(`--${name}`);
const list = (name, fallback) => {
  const v = opt(name, null);
  return v === null ? fallback : v.split(",").map((s) => s.trim()).filter(Boolean);
};

const out = resolve(opt("out", process.env.NATIVE_GATE_OUT ?? join("build", "scorecard")));
const cli = resolve(opt("cli", join(root, "packages/cli/dist/native.js")));
const examplesFilter = list("examples", null);
const only = list("only", ["smoothness", "coverage", "compile", "reload", "uisdk"]);
const screensPath = opt("screens", process.env.NATIVE_GATE_SCREENS ?? null);
const timeout = Number(opt("timeout", 7_200_000));
const reuse = has("reuse");
const scriptc = opt("scriptc", process.env.NATIVE_SCRIPTC ?? null);
const merge = has("merge");
const note = opt("note", null);
/** The scriptc the workspace installed, as the build reports it. */
function installedScriptc(root) {
  for (const path of [join(root, "packages/cli/node_modules/scriptc/package.json"), join(root, "node_modules/scriptc/package.json")]) {
    if (!existsSync(path)) continue;
    try {
      return JSON.parse(readFileSync(path, "utf8")).version ?? null;
    } catch {}
  }
  return null;
}

const refs = {
  native: opt("native-ref", gitSha(root) ?? "unknown"),
  scriptc: opt("scriptc-ref", gitSha(join(root, "..", "scriptc")) ?? "unknown"),
};

const pct = (v, digits = 1) => (v === null || v === undefined ? "n/a" : `${(v * 100).toFixed(digits)}%`);
const ms = (v) => (v === null || v === undefined ? "n/a" : `${Math.round(v)} ms`);
const secs = (v) => (v === null || v === undefined ? "n/a" : `${(v / 1000).toFixed(1)} s`);

// --render <scorecard.json>: write SCORECARD.md for a report a run recorded earlier, so a
// formatting fix needs no new measurement.
const renderOnly = argv[0] === "--render" ? resolve(argv[1] ?? "") : null;
if (renderOnly !== null) {
  const report = JSON.parse(readFileSync(renderOnly, "utf8"));
  const dir = resolve(renderOnly, "..");
  writeFileSync(join(dir, "SCORECARD.md"), scorecardMarkdown(report, { out: dir, cli, screensPath }));
  console.log(`wrote ${join(dir, "SCORECARD.md")}`);
  process.exit(0);
}

mkdirSync(join(out, "shots"), { recursive: true });
mkdirSync(join(out, "builds"), { recursive: true });
const work = join(out, "tmp");
mkdirSync(work, { recursive: true });

const logLines = [];
function say(message) {
  const line = `[${new Date().toISOString().slice(11, 19)}] ${message}`;
  process.stderr.write(line + "\n");
  logLines.push(line);
}
function gitSha(dir) {
  const r = sh("git", ["-C", dir, "rev-parse", "HEAD"]);
  return r.status === 0 ? r.stdout.trim() : null;
}

say(`native ${refs.native}, scriptc ${refs.scriptc}`);
say(`host ${process.platform}/${process.arch}, ${cpus()[0]?.model?.trim()}, ${Math.round(totalmem() / 2 ** 30)} GB`);
say(`output ${out}`);

const names = examplesFilter ?? examples(root);
const report = {
  generatedAt: new Date().toISOString(),
  machine: {
    platform: `${process.platform}-${process.arch}`,
    cpu: cpus()[0]?.model?.trim() ?? null,
    cores: cpus().length,
    memoryGB: Math.round(totalmem() / 2 ** 30),
  },
  refs,
  compiler: scriptc ?? `workspace scriptc ${installedScriptc(root) ?? "unknown"}`,
  note,
  bars,
  gates: {},
  priming: existsSync(join(out, "priming.json")) ? JSON.parse(readFileSync(join(out, "priming.json"), "utf8")) : null,
  builds: [],
  runs: [],
  parity: [],
};

// A partial run can add its gates to an earlier scorecard instead of replacing them.
if (merge && existsSync(join(out, "scorecard.json"))) {
  try {
    const earlier = JSON.parse(readFileSync(join(out, "scorecard.json"), "utf8"));
    report.gates = earlier.gates ?? {};
    report.parity = earlier.parity ?? [];
    report.builds = earlier.builds ?? [];
    say(`merging into ${Object.keys(report.gates).length} gates from ${earlier.generatedAt}`);
  } catch {}
}

// ---------------------------------------------------------------------------------------------
// 3. Compile time, and the builds the other gates need.

let builds = [];
if (only.includes("compile") || only.includes("smoothness") || only.includes("uisdk") || only.includes("parity")) {
  const want = new Set([...names, ...(only.includes("uisdk") ? bars.uisdk.examples : [])]);
  if (!reuse && !has("no-prime")) {
    say("priming the compiler cache once, so each example pays for its own compile");
    const primed = primeCompiler({ cli, root, out, name: [...want].sort()[0], timeout, scriptc });
    if (!primed.ok) say(`  priming failed: ${(primed.error ?? "").split("\n").pop()}`);
    else say(`  primed in ${(primed.ms / 1000).toFixed(1)} s`);
    report.priming = { example: [...want].sort()[0], ms: primed.ms, ok: primed.ok };
    writeFileSync(join(out, "priming.json"), JSON.stringify(report.priming, null, 2) + "\n");
  }
  for (const name of [...want].sort()) {
    say(`build ${name} (cold, then warm)`);
    const b = buildExample({ cli, root, out, name, timeout, reuse, scriptc });
    if (!b.ok) say(`  build failed: ${(b.error ?? "").split("\n").pop()}`);
    else if (b.reused) say(`  reused ${(b.coldMs / 1000).toFixed(1)} s cold, ${((b.warmMs ?? 0) / 1000).toFixed(1)} s warm`);
    else say(`  cold ${(b.coldMs / 1000).toFixed(1)} s (scriptc ${((b.coldScriptcMs ?? 0) / 1000).toFixed(1)} s), warm ${(b.warmMs / 1000).toFixed(1)} s${b.warmCached ? " cached" : ""}`);
    builds.push(b);
  }
  report.builds = [...report.builds.filter((b) => !builds.some((n) => n.name === b.name)), ...builds].map((b) => ({
    name: b.name, ok: b.ok, coldMs: b.coldMs, coldScriptcMs: b.coldScriptcMs, phases: b.phases,
    warmMs: b.warmMs, warmCached: b.warmCached, warmScriptcMs: b.warmScriptcMs, error: b.error,
  }));
}

const built = new Map(builds.filter((b) => b.ok).map((b) => [b.name, b]));

if (only.includes("compile")) {
  // Every build the output directory has recorded, so a compile run split across batches (each
  // one inside a remote session's time limit) adds up to one gate.
  const recorded = loadBuilds(out);
  const fails = recorded.filter((b) => !b.ok);
  const slow = [...recorded].filter((b) => b.ok).sort((a, b) => b.coldMs - a.coldMs);
  const warmSlow = [...recorded].filter((b) => b.ok).sort((a, b) => (b.warmMs ?? 0) - (a.warmMs ?? 0));
  const overCold = slow.filter((b) => b.coldMs > bars.compile.coldBuildMs);
  const overWarm = warmSlow.filter((b) => (b.warmMs ?? 0) > bars.compile.warmBuildMs);
  const label = opt("label", "local");
  const compare = {
    label,
    platform: `${process.platform}-${process.arch}`,
    compiler: scriptc ?? "workspace",
    measuredAt: new Date().toISOString(),
    examples: recorded.map((b) => ({ name: b.name, coldMs: b.coldMs, scriptcMs: b.coldScriptcMs, warmMs: b.warmMs })),
  };
  writeFileSync(join(out, `compile-${label}.json`), JSON.stringify(compare, null, 2) + "\n");
  report.compares = loadCompares(out);
  report.gates.compile = {
    bar: `cold ≤ ${bars.compile.coldBuildMs / 1000} s and warm ≤ ${bars.compile.warmBuildMs / 1000} s per example`,
    pass: fails.length === 0 && overCold.length === 0 && overWarm.length === 0,
    examples: slow.map((b) => ({ name: b.name, coldMs: b.coldMs, warmMs: b.warmMs, warmCached: b.warmCached, scriptcMs: b.coldScriptcMs, phases: b.phases })),
    failed: fails.map((b) => ({ name: b.name, error: b.error })),
    coldMedianMs: percentile(slow.map((b) => b.coldMs), 50),
    coldP95Ms: percentile(slow.map((b) => b.coldMs), 95),
    warmMedianMs: percentile(warmSlow.map((b) => b.warmMs), 50),
    warmMaxMs: warmSlow[0]?.warmMs ?? null,
  };
}

// ---------------------------------------------------------------------------------------------
// 1. Smoothness.

if (only.includes("smoothness")) {
  const results = [];
  for (const name of names) {
    const b = built.get(name);
    if (b === undefined) {
      results.push({ name, ok: false, error: "no build" });
      continue;
    }
    say(`frames ${name}`);
    const m = measureSmoothness({ cfg: bars.smoothness, name, exe: b.exe, work });
    if (!m.ok) say(`  failed: ${(m.error ?? "").split("\n").pop()}`);
    else say(`  p95 ${m.p95} ms over ${m.measuredFrames} frames (first paint ${m.firstPaintMs} ms)`);
    results.push(m);
  }
  const ok = results.filter((r) => r.ok);
  const worst = [...ok].sort((a, b) => (b.p95 ?? 0) - (a.p95 ?? 0));
  report.gates.smoothness = {
    bar: `p95 frame time ≤ ${bars.smoothness.p95FrameMs} ms on every example (scroll, animation and three.js scenes)`,
    pass: ok.length === names.length && ok.every((r) => (r.p95 ?? Infinity) <= bars.smoothness.p95FrameMs),
    hostPerFrame: process.platform === "darwin",
    examples: results,
    worstP95: worst[0]?.p95 ?? null,
  };
}

// ---------------------------------------------------------------------------------------------
// 2. Coverage: the fixed WPT subset.

if (only.includes("coverage")) {
  say(`wpt ${bars.coverage.dirs.join(" ")} at ${bars.coverage.wptRevision.slice(0, 12)}`);
  const c = measureCoverage({ cfg: bars.coverage, cli, out, timeout });
  if (!c.ok) say(`  coverage failed: ${(c.error ?? "").split("\n").pop()}`);
  else say(`  ${c.totals.pass} pass / ${c.runnable} runnable (${(c.passRate * 100).toFixed(1)}%), ${c.totals.skip} skip`);
  const committed = committedCoverage(bars.coverage, root);
  const today = c.ok;
  report.gates.coverage = {
    today,
    bar: `≥ ${(bars.coverage.passRate * 100).toFixed(0)}% of runnable tests pass on the fixed subset`,
    pass: c.ok && (c.passRate ?? 0) >= bars.coverage.passRate,
    platform: `${process.platform}-${process.arch}`,
    revision: c.revision,
    dirs: c.dirs,
    totals: c.totals,
    runnable: c.runnable,
    passRate: c.passRate,
    perDir: c.perDir,
    blockers: c.blockers,
    failures: c.failures,
    committed,
    error: c.error ?? null,
  };
}

// ---------------------------------------------------------------------------------------------
// Chrome parity, shared by the coverage gate's screenshot score and the UI SDK gate.

let chromium = findChrome(out);
say(chromium === null ? "no Chrome found: parity is unmeasured (set CHROME_BIN)" : `chrome ${chromium}`);

const parityNames = only.includes("uisdk") || only.includes("coverage") || only.includes("parity")
  ? [...new Set([...(only.includes("uisdk") ? bars.uisdk.examples : []), ...names])].sort()
  : [];

if (chromium !== null) {
  // Only the examples this run can actually run are re-measured; a run that builds nothing (a
  // coverage-only pass) keeps the parity an earlier pass recorded.
  const measurable = parityNames.filter((n) => built.has(n));
  report.parity = report.parity.filter((p) => !measurable.includes(p.name));
  for (const name of measurable) {
    const b = built.get(name);
    if (b === undefined) continue;
    say(`parity ${name}`);
    const p = await measureParity({ root, out, name, exe: b.exe, chrome: chromium, delta: bars.chrome.pixelDelta, scale: bars.chrome.viewportScale, virtualTimeMs: bars.chrome.virtualTimeMs, work });
    if (!p.ok) say(`  failed: ${(p.error ?? "").split("\n").pop()}`);
    else say(`  ${(p.identical * 100).toFixed(1)}% identical to Chrome (${p.browserMode})`);
    report.parity.push(p);
  }
}

// ---------------------------------------------------------------------------------------------
// 4. Hot reload.

if (only.includes("reload")) {
  const results = [];
  for (const name of bars.reload.examples) {
    say(`reload ${name}`);
    const r = await measureReload({ cli, root, out, name, edits: bars.reload.editsPerExample, timeout: 600_000 });
    say(r.ok ? `  edits ${r.edits.join(", ")} ms (warm-up ${r.warmupMs} ms)` : `  failed: ${r.error}`);
    results.push(r);
  }
  const ok = results.filter((r) => r.ok);
  report.gates.reload = {
    bar: `TS edit to the reloaded page ≤ ${bars.reload.editToFrameMs} ms on ${bars.reload.examples.length} examples`,
    pass: ok.length === results.length && ok.every((r) => r.edits.every((ms) => ms <= bars.reload.editToFrameMs)),
    examples: results,
  };
}

// ---------------------------------------------------------------------------------------------
// 5. React and the UI SDK across the examples, plus an optional screen report from another run.

if (only.includes("uisdk")) {
  const screens = [];
  for (const name of bars.uisdk.examples) {
    const b = built.get(name);
    const run = b === undefined ? { name, ok: false, error: "no build" } : measureRun({ name, exe: b.exe, work });
    const parity = report.parity.find((p) => p.name === name) ?? null;
    const match = parity?.ok ? parity.identical : null;
    screens.push({
      name,
      compiles: b !== undefined,
      runs: run.ok,
      runColours: run.colours,
      chromeMatch: match,
      pass: b !== undefined && run.ok && match !== null && match >= bars.uisdk.matchPixel,
      browserMode: parity?.browserMode ?? null,
    });
    say(`  ${name}: compiles ${b !== undefined}, runs ${run.ok}, match ${match === null ? "n/a" : (match * 100).toFixed(1) + "%"}`);
  }
  const screenReport = screensPath !== null && existsSync(screensPath) ? readScreens(screensPath) : null;
  report.gates.uisdk = {
    bar: `every screen compiles, runs, and is ≥ ${(bars.uisdk.matchPixel * 100).toFixed(0)}% identical to Chrome`,
    // A report read from a file carries a summary rather than counts, so it is informational;
    // only a report with screen counts can hold gate 5 to its bar.
    pass: screens.every((s) => s.pass) && (screenReport === null || screenReport.screens === undefined || (screenReport.compile === screenReport.screens && screenReport.run - (screenReport.blank ?? 0) === screenReport.screens && screenReport.within1Pct === screenReport.screens)),
    screens,
    screenReport,
  };
}

// ---------------------------------------------------------------------------------------------
// The scorecard.

const md = scorecardMarkdown(report, { out, cli, screensPath });
mkdirSync(out, { recursive: true });
writeFileSync(join(out, "SCORECARD.md"), md);
writeFileSync(join(out, "scorecard.json"), JSON.stringify(report, null, 2) + "\n");
writeFileSync(join(out, "run.log"), logLines.join("\n") + "\n");
say(`wrote ${join(out, "SCORECARD.md")}`);

// ---------------------------------------------------------------------------------------------

function scorecardMarkdown(rep, ctx) {
  const g = rep.gates;
  const status = (v) => (v === undefined ? "—" : v.pass ? "**PASS**" : "**FAIL**");
  const s = secs;
  const lines = [];
  const gatesPassed = Object.values(g).filter((x) => x.pass).length;

  lines.push(`# Native SDK quality scorecard — ${rep.generatedAt.slice(0, 10)}`, "");
  const pending = rep.pending ?? [];
  lines.push(`**${gatesPassed} of ${Object.keys(g).length} gates pass.**`, "");
  if (pending.length > 0) {
    const pendingText = pending.filter((p) => !p.na).map((p) => `${p.id} ${p.title}`);
    const naText = pending.filter((p) => p.na).map((p) => `${p.id} ${p.title} (${p.why})`);
    if (pendingText.length > 0) lines.push(`Pending: ${pendingText.join("; ")}. Their numbers replace the pending rows below when this run finishes.`, "");
    if (naText.length > 0) lines.push(`Not measured on this platform: ${naText.join("; ")}.`, "");
  }
  lines.push(`| | |`, `|---|---|`);
  lines.push(`| native | \`${rep.refs.native.slice(0, 12)}\` |`);
  lines.push(`| scriptc | \`${rep.refs.scriptc.slice(0, 12)}\` |`);
  if (rep.compiler) lines.push(`| compiler | \`${rep.compiler}\` |`);
  lines.push(`| machine | ${rep.machine.platform} · ${rep.machine.cpu} · ${rep.machine.cores} cores · ${rep.machine.memoryGB} GB |`);
  lines.push(`| coverage host | ${g.coverage?.platform ?? "n/a"} |`);
  if (rep.note) lines.push(`| note | ${rep.note} |`);
  lines.push("");

  lines.push(`| # | Gate | Bar | Today | |`);
  lines.push(`|---|---|---|---|---|`);
  if (g.smoothness) lines.push(`| 1 | Smoothness | p95 frame ≤ ${bars.smoothness.p95FrameMs} ms on every example | worst p95 ${ms(g.smoothness.worstP95)} | ${status(g.smoothness)} |`);
  if (g.coverage) {
    const c = g.coverage;
    const todayRow = c.today === false
      ? `${c.committed ? `committed run ${pct(c.committed.passRate)} of ${c.committed.pass + c.committed.fail + c.committed.error + c.committed.crash} runnable` : "no results"} (today's run failed)`
      : `${pct(c.passRate)} of ${c.runnable ?? "?"} runnable`;
    lines.push(`| 2a | HTML/CSS (WPT subset) | ≥ ${pct(bars.coverage.passRate, 0)} of runnable | ${todayRow} | ${status(c)} |`);
  }
  if (rep.parity.length > 0) lines.push(`| 2b | Chrome screenshot diff (examples) | ≥ ${pct(bars.uisdk.matchPixel, 0)} identical | ${paritySummary(rep.parity, pct)} | ${parityPass(rep.parity) ? "**PASS**" : "**FAIL**"} |`);
  if (g.compile) lines.push(`| 3 | Compile time | cold ≤ ${s(bars.compile.coldBuildMs)}, warm ≤ ${s(bars.compile.warmBuildMs)} | cold p95 ${s(g.compile.coldP95Ms)}, warm max ${s(g.compile.warmMaxMs)} | ${status(g.compile)} |`);
  if (g.reload) lines.push(`| 4 | Hot reload | ≤ ${bars.reload.editToFrameMs} ms | slowest edit ${ms(Math.max(...g.reload.examples.filter((e) => e.ok).flatMap((e) => e.edits), 0) || null)} | ${status(g.reload)} |`);
  for (const p of rep.pending ?? []) {
    lines.push(`| ${p.id} | ${p.title} | ${p.bar} | ${p.na ? `not measured: ${p.why}` : "pending"} | ${p.na ? "n/a" : "—"} |`);
  }
  if (g.uisdk) {
    const u = g.uisdk.screenReport;
    const feed = u && u.screens !== undefined ? `, screen report ${u.compile}/${u.screens}` : "";
    lines.push(`| 5 | React + UI SDK | all compile, run, ≥ ${pct(bars.uisdk.matchPixel, 0)} Chrome match | ${g.uisdk.screens.filter((x) => x.pass).length}/${g.uisdk.screens.length} UI SDK screens${feed} | ${status(g.uisdk)} |`);
  }
  lines.push("");

  if (g.smoothness) {
    lines.push(`## 1. Smoothness`, "", `Bar: p95 frame time ≤ ${bars.smoothness.p95FrameMs} ms (60 fps) on every example, scrolling through ${bars.smoothness.frames} frames${g.smoothness.hostPerFrame ? ", with the host's per-frame composite time added" : ""}. The frames come from the host's own opt-in log (NATIVE_FRAME_TIMES=1): the runtime's stages for each frame plus, on macOS, that frame's composite or present. First paint is reported separately and left out of the p95; a page with no animation or scroller paints idle frames and shows a low active share.`, "");
    lines.push(`| Example | p95 | p50 | max | first paint | paint | layout | style | host | frames (active) | scroll |`);
    lines.push(`|---|---|---|---|---|---|---|---|---|---|---|`);
    for (const e of [...g.smoothness.examples].sort((a, b) => (b.p95 ?? 0) - (a.p95 ?? 0))) {
      if (!e.ok) lines.push(`| ${e.name} | — | — | — | — | — | — | — | — | failed: ${oneLine(e.error)} |`);
      else lines.push(`| ${e.name} | ${ms(e.p95)} | ${ms(e.p50)} | ${ms(e.max)} | ${ms(e.firstPaintMs)} | ${e.stages.paint} | ${e.stages.layout} | ${e.stages.style} | ${e.stages.host} | ${e.measuredFrames} (${pct(e.activeShare, 0)}) | ${e.scroll} |`);
    }
    lines.push("");
    const gaps = gapSmoothness(g.smoothness);
    if (!g.smoothness.pass) lines.push(...topGaps("smoothness", gaps));
  }

  if (g.coverage) {
    const when = g.coverage.today === false
      ? `today's run failed, so the bar is scored on the repository's committed full run over the same directories`
      : `run on ${g.coverage.platform}`;
    lines.push(`## 2a. HTML/CSS coverage`, "", `Bar: ≥ ${pct(bars.coverage.passRate, 0)} of runnable tests pass. Subset: \`${bars.coverage.dirs.join("` `")}\` at WPT \`${String(g.coverage.revision).slice(0, 12)}\`; ${when}. Skips (unsupported features) are outside the runnable count and listed under gaps.`, "");
    if (g.coverage.error) lines.push(`Today's run failed: ${oneLine(g.coverage.error)}`, "");
    if (g.coverage.today === false && g.coverage.committed) {
      const c = g.coverage.committed;
      lines.push(`Falling back to the committed macOS results for this subset: ${pct(c.passRate)} of runnable (${c.pass} pass, ${c.fail} fail, ${c.skip} skip, ${c.error} error, ${c.crash} crash) at WPT \`${String(c.revision).slice(0, 12)}\`.`, "");
    }
    if (g.coverage.totals) {
      const t = g.coverage.totals;
      lines.push(`| pass | fail | skip | error | crash | total |`, `|---|---|---|---|---|---|`);
      lines.push(`| ${t.pass} | ${t.fail} | ${t.skip} | ${t.error} | ${t.crash} | ${t.total} |`, "");
      if (g.coverage.committed) {
        const c = g.coverage.committed;
        lines.push(`Committed macOS full-run results in the same directories: ${pct(c.passRate)} of runnable (${c.pass}/${c.pass + c.fail + c.error + c.crash}), WPT \`${String(c.revision).slice(0, 12)}\`.`, "");
      }
      lines.push(`| Directory | pass | fail | skip | pass rate |`, `|---|---|---|---|---|`);
      for (const d of g.coverage.perDir) lines.push(`| ${d.dir} | ${d.pass} | ${d.fail} | ${d.skip} | ${pct(d.passRate)} |`);
      lines.push("");
    }
    const gaps = gapCoverage(g.coverage);
    if (!g.coverage.pass) lines.push(...topGaps("coverage", gaps));
  }

  if (rep.parity.length > 0) {
    lines.push(`## 2b. Chrome screenshot diff`, "", `Each example native against Chrome at the page's own window size ×${bars.chrome.viewportScale}, both at the same point in the animation clock (${bars.chrome.virtualTimeMs} ms in), pixels differing by more than ${bars.chrome.pixelDelta}/255 counted as different. The diff images are in shots/.`, "");
    lines.push(`| Example | identical | mean Δ | browser | note |`, `|---|---|---|---|---|`);
    for (const p of [...rep.parity].sort((a, b) => (a.identical ?? 0) - (b.identical ?? 0))) {
      if (!p.ok) lines.push(`| ${p.name} | — | — | — | failed: ${oneLine(p.error)} |`);
      else if ((bars.chrome.calibrated ?? {})[p.name] !== undefined) {
        lines.push(`| ${p.name} | ${pct(effectiveParity(p))} | ${p.meanDelta} | ${p.browserMode} | ${bars.chrome.calibratedSource} (this run: ${pct(p.measured ?? p.identical)}) |`);
      } else {
        const note = (bars.chrome.notes ?? {})[p.name] ?? (p.browserError ? "bundle failed: " + oneLine(p.browserError) : "");
        lines.push(`| ${p.name} | ${pct(p.identical)} | ${p.meanDelta} | ${p.browserMode} | ${note} |`);
      }
    }
    lines.push("");
    if (!parityPass(rep.parity)) {
      const notes = bars.chrome.notes ?? {};
      const worst = rep.parity.filter((x) => x.ok).sort((a, b) => effectiveParity(a) - effectiveParity(b)).slice(0, 3);
      lines.push(`**Top gaps**`, "");
      worst.forEach((x, i) => {
        lines.push(`${i + 1}. ${x.name}: ${pct(effectiveParity(x))} (mean Δ ${x.meanDelta}) — \`${notes[x.name] !== undefined ? "scripts/gate/lib/browser.mjs (animation clock)" : "layout/paint parity in packages/cli/shared/css and runtime/style.ts"}\``);
      });
      lines.push("");
    }
  }

  if (g.compile) {
    lines.push(`## 3. Compile time`, "", `Bar: cold ≤ ${s(bars.compile.coldBuildMs)} and warm ≤ ${s(bars.compile.warmBuildMs)} per example, with the native scriptc CLI the workspace installs (0.4.16 unless --scriptc names another). Cold is a build with no cache for the app (its .native build record and build cache removed), while the compiler's cache is primed once at the start of the run (reported below), so the number is the app's own compile rather than the SDK runtime every machine compiles once. Warm repeats the build with the cache that cold build filled.`, "");
    const primed = rep.priming;
    if (primed) lines.push(`Priming the compiler cache on \`${primed.example}\` took ${s(primed.ms)} and is part of no example's number.`, "");
    lines.push(`| Example | cold | scriptc | warm | cached | optimizing | generating | linking | unnamed |`);
    lines.push(`|---|---|---|---|---|---|---|---|---|`);
    for (const e of [...g.compile.examples].sort((a, b) => b.coldMs - a.coldMs)) {
      const ph = e.phases ?? {};
      lines.push(`| ${e.name} | ${s(e.coldMs)} | ${s(e.scriptcMs)} | ${s(e.warmMs)} | ${e.warmMs === null ? "n/a" : ""} | ${s(ph["optimized code"])} | ${s(ph["generated code"])} | ${s(ph.linked)} |`);
    }
    for (const f of g.compile.failed) lines.push(`| ${f.name} | failed | | | | | | |`);
    lines.push("");
    const onDisk = existsSync(ctx.out) ? loadCompares(ctx.out) : [];
    const compares = [...new Map([...(rep.compares ?? []), ...onDisk].map((c) => [c.label, c])).values()].sort((a, b) => (a.measuredAt < b.measuredAt ? -1 : 1));
    if (compares.length > 1) {
      const names = [...new Set(compares.flatMap((c) => c.examples.map((e) => e.name)))].sort();
      lines.push(`Cold build by compiler, seconds, one column per measured host and compiler:`, "");
      lines.push(`| Example | ${compares.map((c) => `${c.platform}, ${c.label.includes("0.4.16") ? "scriptc 0.4.16" : c.compiler}`).join(" | ")} |`);
      lines.push(`|---|${compares.map(() => "---").join("|")}|`);
      for (const name of names) {
        const cells = compares.map((c) => {
          const e = c.examples.find((x) => x.name === name);
          return e === undefined ? "—" : s(e.coldMs);
        });
        lines.push(`| ${name} | ${cells.join(" | ")} |`);
      }
      lines.push("");
    }
    const gaps = gapCompile(g.compile);
    if (!g.compile.pass) lines.push(...topGaps("compile", gaps));
  }

  if (g.reload) {
    lines.push(`## 4. Hot reload`, "", `Bar: a TypeScript edit reaches the reloaded page in ≤ ${bars.reload.editToFrameMs} ms. \`native dev\` runs in the page already open; the first edit's wait includes the dev host's one-time build and is reported on its own.`, "");
    lines.push(`| Example | edits (ms) | p50 | max | warm-up |`);
    lines.push(`|---|---|---|---|---|`);
    for (const e of g.reload.examples) {
      if (!e.ok) lines.push(`| ${e.name} | — | — | — | failed: ${oneLine(e.error)} |`);
      else lines.push(`| ${e.name} | ${e.edits.join(", ")} | ${ms(e.p50)} | ${ms(e.max)} | ${ms(e.warmupMs)} |`);
    }
    lines.push("");
    if (!g.reload.pass) lines.push(...topGaps("reload", gapReload(g.reload)));
  }

  if (g.uisdk) {
    lines.push(`## 5. React + the UI SDK`, "", `Bar: every screen compiles, runs, and is ≥ ${pct(bars.uisdk.matchPixel, 0)} identical to Chrome. Screens: \`${bars.uisdk.examples.join("` `")}\`.`, "");
    lines.push(`| Screen | compiles | runs | chrome match |`);
    lines.push(`|---|---|---|---|`);
    for (const e of g.uisdk.screens) lines.push(`| ${e.name} | ${e.compiles ? "yes" : "**no**"} | ${e.runs ? `yes (${e.runColours} colours)` : "**no**"} | ${e.chromeMatch === null ? "n/a" : pct(e.chromeMatch)} |`);
    lines.push("");
    if (g.uisdk.screenReport) {
      const u = g.uisdk.screenReport;
      if (u.screens !== undefined) {
        lines.push(`screen report (${u.repo ?? "local report"}, ${u.screens} screens, ${u.compiler}, shard ${u.shard}): **${u.compile} compile** (${pct(u.compile / u.screens, 0)}), **${u.run} run with exit 0** (${u.blank ?? 0} of them blank), ${u.crash} crash at runtime, ${u.compileFail} fail to compile; ${u.within1Pct} of ${u.run} are within 1% of Chrome (${u.within01Pct} within 0.1%).`);
      } else {
        lines.push(`screen report (measured by another run): ${u.summary ?? "numbers not readable in the report"}.`);
      }
      lines.push("");
    } else {
      lines.push(`screen report: not measured in this run (pass \`--screens <SCOREBOARD.md>\` or set \`NATIVE_GATE_SCREENS\`).`, "");
    }
    if (!g.uisdk.pass) lines.push(...topGaps("uisdk", gapUisdk(g.uisdk)));
  }

  lines.push(`---`, "", `Rerun daily: \`node scripts/gate/gate.mjs --out <out-dir>\``, "");
  return lines.join("\n");
}

function topGaps(name, gaps) {
  const out = [`**Top gaps**`, ""];
  gaps.slice(0, 3).forEach((g, i) => out.push(`${i + 1}. ${g.what} — \`${g.area}\``));
  out.push("");
  return out;
}

function stageArea(stage) {
  switch (stage) {
    case "paint": return "packages/cli/runtime (paint walk) and packages/cli/host/macos.m (replay/compositor)";
    case "layout": return "packages/cli/runtime/layout";
    case "style": return "packages/cli/runtime/style.ts, shared/css/invalidation";
    case "anim": return "packages/cli/runtime/animation*, shared/css/anim.ts";
    case "host": return "packages/cli/host/macos.m (compositor: tiles, raster pool, present)";
    default: return "packages/cli/runtime";
  }
}

function gapSmoothness(g) {
  return [...g.examples].filter((e) => e.ok && (e.p95 ?? 0) > bars.smoothness.p95FrameMs).sort((a, b) => (b.p95 ?? 0) - (a.p95 ?? 0)).slice(0, 3).map((e) => {
    const stages = { paint: e.stages.paint ?? 0, layout: e.stages.layout ?? 0, style: e.stages.style ?? 0, anim: e.stages.anim ?? 0, host: e.stages.host ?? 0 };
    const [stage, v] = Object.entries(stages).sort((a, b) => b[1] - a[1])[0];
    return { what: `${e.name}: p95 ${ms(e.p95)} (${stage} ${v} ms of the p95, max ${ms(e.max)})`, area: stageArea(stage) };
  });
}

function areaForBlocker(reason) {
  if (/^css value:/.test(reason)) return "packages/cli/shared/css/properties (value parsing) with the runtime that lays it out";
  if (/^css property:/.test(reason)) return "packages/cli/shared/css/properties.ts, compiler/css/property.ts";
  if (/^at-rule:/.test(reason)) return "packages/cli/compiler/css/parse.ts, runtime/style.ts";
  if (/^selector:/.test(reason)) return "packages/cli/shared/css/selectors.ts, runtime/selectors";
  if (/^html:/.test(reason)) return "packages/cli/compiler/html.ts, runtime/dom.ts";
  if (/^media feature/.test(reason)) return "packages/cli/shared/css/media.ts, runtime/media.ts";
  if (/^script:/.test(reason)) return "scriptc checker/frontend (packages/compiler/src/frontend)";
  if (/^data:/.test(reason)) return "packages/cli/compiler (data: URL loading) and runtime/resources";
  return "packages/cli/compiler";
}

function gapCoverage(c) {
  const gaps = [];
  const source = c.today === false && c.committed ? c.committed : c;
  for (const b of source.blockers ?? []) {
    if (/^not a reftest$|^script: not in checkout$/.test(b.reason)) continue;
    gaps.push({ what: `${b.count} tests skip: \`${b.reason}\``, area: areaForBlocker(b.reason) });
    if (gaps.length === 3) break;
  }
  const worst = (source.perDir ?? []).filter((d) => d.fail > 0).sort((a, b) => (a.passRate ?? 1) - (b.passRate ?? 1)).slice(0, 2);
  for (const d of worst) gaps.push({ what: `${d.dir}: ${d.fail} failing (${pct(d.passRate)} pass)`, area: `layout/rendering for ${d.dir.replace("css/", "")}` });
  return gaps;
}

function gapCompile(c) {
  return c.examples.slice(0, 3).map((e) => {
    const phases = e.phases ?? {};
    const named = Object.values(phases).reduce((sum, ms) => sum + ms, 0);
    const unnamed = e.coldMs - named;
    const ph = Object.entries(phases).sort((a, b) => b[1] - a[1])[0] ?? ["(no phases)", 0];
    if (unnamed > ph[1] && unnamed > 30_000) {
      return {
        what: `${e.name}: cold ${secs(e.coldMs)}, ${secs(unnamed)} of it in no phase the build names (largest named: ${ph[0]} ${secs(ph[1])})`,
        area: "packages/cli/compiler/progress.ts (phase reporting) and the scriptc step it leaves unnamed",
      };
    }
    return { what: `${e.name}: cold ${secs(e.coldMs)}, mostly ${ph[0]} ${secs(ph[1])}${unnamed > 30_000 ? ` (${secs(unnamed)} outside the named phases)` : ""}`, area: "scriptc backend (packages/compiler/src/backend: LLVM emit and optimization)" };
  });
}

function gapReload(g) {
  return g.examples.filter((e) => e.ok).sort((a, b) => (b.max ?? 0) - (a.max ?? 0)).slice(0, 3).map((e) => ({
    what: `${e.name}: ${e.edits.join("/")} ms per edit (p50 ${ms(e.p50)})`,
    area: "packages/cli/compiler/dev.ts, dev-bundle.ts (island rebundle and re-mount)",
  }));
}

function gapUisdk(g) {
  const chromeNotes = bars.chrome.notes ?? {};
  return g.screens.filter((s) => !s.pass).slice(0, 3).map((s) => ({
    what: `${s.name}: ${s.compiles ? "compiles" : "does not compile"}, ${s.runs ? "runs" : "does not run"}, ${s.chromeMatch === null ? "no match measured" : pct(s.chromeMatch) + " Chrome match"}${chromeNotes[s.name] ? ` (${chromeNotes[s.name]})` : ""}`,
    area: !s.compiles
      ? "scriptc checker (React 19/@ui-sdk typings)"
      : !s.runs
        ? "packages/cli/runtime (React DOM rendering)"
        : chromeNotes[s.name] !== undefined
          ? "scripts/gate/lib/browser.mjs (the animation clock the two engines are compared at)"
          : "layout/paint parity in packages/cli/shared/css and runtime/style.ts",
  }));
}

/** The parity a page counts at: the calibrated figure where another run pinned it more precisely. */
function effectiveParity(p) {
  const calibrated = bars.chrome.calibrated ?? {};
  return calibrated[p.name] ?? p.identical;
}

function judgedParity(parity) {
  return parity.filter((p) => p.ok && !timingSensitive.has(p.name));
}

function paritySummary(parity, pct) {
  const ok = judgedParity(parity);
  const rest = parity.filter((p) => p.ok && timingSensitive.has(p.name));
  const aside = rest.length === 0 ? "" : ` (timing-sensitive, not judged: ${rest.map((p) => `${p.name} ${pct(effectiveParity(p))}`).join(", ")})`;
  if (ok.length === 0) return `n/a${aside}`;
  const worst = ok.reduce((a, b) => (effectiveParity(a) <= effectiveParity(b) ? a : b));
  return `worst ${pct(effectiveParity(worst))} (${worst.name}), median ${pct(percentile(ok.map((p) => effectiveParity(p)), 50))}${aside}`;
}
function parityPass(parity) {
  // Every capture has to have happened, timing-sensitive or not: a crash or a missing screenshot
  // left the example unmeasured, and an unmeasured gate is not a pass.
  const ran = parity.every((p) => p.ok);
  const judged = judgedParity(parity);
  return parity.length > 0 && ran && judged.every((p) => effectiveParity(p) >= bars.uisdk.matchPixel);
}

function oneLine(text) {
  return String(text ?? "").split("\n").filter(Boolean).slice(-1)[0]?.slice(0, 200) ?? "";
}

/** The compile measurements recorded by every run in this output directory, one per label. */
function loadCompares(out) {
  const files = require("node:fs").readdirSync(out).filter((f) => /^compile-.+\.json$/.test(f));
  const all = [];
  for (const f of files) {
    try {
      all.push(JSON.parse(readFileSync(join(out, f), "utf8")));
    } catch {}
  }
  return all.sort((a, b) => (a.measuredAt < b.measuredAt ? -1 : 1));
}

/** Every example's recorded build, from the output directory's builds/ tree. */
function loadBuilds(out) {
  const dir = join(out, "builds");
  if (!existsSync(dir)) return [];
  const found = [];
  for (const name of require("node:fs").readdirSync(dir)) {
    const record = join(dir, name, "build.json");
    if (!existsSync(record)) continue;
    try {
      found.push(JSON.parse(readFileSync(record, "utf8")));
    } catch {}
  }
  return found.sort((a, b) => a.name.localeCompare(b.name));
}

/** The counts another run's screen scoreboard reports, when it can be read. */
function readScreens(path) {
  const text = readFileSync(path, "utf8");
  const rows = text.split("\n").filter((l) => /^\|/.test(l) && !/---/.test(l));
  return { path, summary: rows.slice(0, 6).join(" · ").slice(0, 600), rows: rows.length };
}
