// Authoring-joy metrics, computed from finished eval runs' transcripts.
//
//   pnpm metrics results/<stamp> [results/<stamp2> ...]
//
// For every case trial in the given results directories this reads
// transcript.jsonl and result.json and derives the agent-authoring metrics
// the deterministic checks cannot see:
//
// - first-pass compliance: did the FIRST compliance check the agent ran after
//   first touching the sources pass? (ts-core: the @native-sdk/core transpiler run;
//   native: `native test` / `zig build test`.) Pre-edit runs don't count —
//   starters compile clean, so they would grade the scaffold, not the agent.
// - retries-to-green: failing compliance runs before the first passing one
//   (after the first source edit). Never-green trials count every failure and
//   are flagged.
// - violation taxonomy: which diagnostics the failing compliance runs carried.
//   ts tracks: NS/TS rule IDs from the transpiler; zig/native tracks: zig
//   "error:" lines. Reported raw and per 1k generated LOC (lines the agent
//   wrote through Write/Edit to source files — content lines of Write,
//   new_string lines of Edit).
// - teaching-error encounters: failing compliance runs that carried a
//   compiler/checker diagnostic — every one is a round-trip through the
//   toolkit's teaching errors, the "did the diagnostics work" signal wave 2
//   tracks on both tracks.
// - task success: result.json's passed (every non-advisory check green).
// - efficiency: turns, cost, wall-clock, output tokens, and — the headline —
//   turns-to-first-green and the post-green tail. First-green is the
//   AGENT-VERIFICATION PROXY (first green agent-run check after the first
//   source edit; the graders only run once, post-trial — see efficiency.ts
//   for the full epistemics). Computed from the transcript, so it works on
//   archived runs whose result.json predates the efficiency fields.
//
// Tracks: "ts" covers the ts-core cases AND the ts side of app-dual cases;
// "zig" covers the pre-existing native cases AND the zig side of app-dual
// cases. The track of an app-dual trial comes from its result.json.
//
// Prints a per-case table, per-track aggregates, a per-track efficiency
// table, and a paired dual-case table (same spec, ts vs zig side by side),
// and writes authoring-metrics.json next to each summary.json.

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { analyzeTranscript } from "./efficiency.ts";
import type { MetricsTrack } from "./efficiency.ts";

interface TrialMetrics {
  case: string;
  track: MetricsTrack;
  trial: number;
  passed: boolean;
  /** null = the agent never ran a compliance check after editing. */
  firstPassCompliant: boolean | null;
  retriesToGreen: number;
  everGreen: boolean;
  complianceRuns: number;
  /** Failing compliance runs carrying a teaching diagnostic (NS/TS ids on the ts track, compiler errors on the zig track). */
  teachingErrorEncounters: number;
  violations: Record<string, number>;
  generatedLoc: number;
  turns: number | null;
  /** Distinct assistant messages in the transcript (fallback turn count when the CLI never reported num_turns, e.g. timeouts). */
  observedTurns: number;
  /** Agent-verification proxy: turn of the first green agent-run check after editing (see efficiency.ts); null = never green. */
  firstGreenTurn: number | null;
  /** ms from the first timestamped transcript event to the first green verification; null = never green. */
  firstGreenMs: number | null;
  /** Post-green tail: turns after the agent's own checks were green — the verification-theater measure. */
  turnsAfterGreen: number | null;
  costUsd: number | null;
  /** Agent wall-clock, ms (result.json agent.durationMs). */
  durationMs: number;
  /** Uncached input tokens; null when the run died without a terminal result event. */
  inputTokens: number | null;
  outputTokens: number | null;
  cacheReadTokens: number | null;
  /** The trial hit --max-turns (green-at-cap still passes; this is the cost flag). */
  cappedAtTurns: boolean;
}

interface CaseMetrics {
  case: string;
  track: MetricsTrack;
  trials: TrialMetrics[];
}

function main(): void {
  const evalsRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const dirs = process.argv.slice(2).map((dir) => resolve(dir));
  if (dirs.length === 0) {
    console.error("usage: pnpm metrics results/<stamp> [results/<stamp2> ...]");
    process.exit(2);
  }
  const cases = new Map<string, CaseMetrics>();
  for (const dir of dirs) {
    for (const label of readdirSync(dir)) {
      const caseDir = join(dir, label);
      // app-dual results live under `<case>@<track>`; the config is the
      // base case's eval.json.
      const at = label.lastIndexOf("@");
      const baseName = at === -1 ? label : label.slice(0, at);
      const labelTrack = at === -1 ? undefined : label.slice(at + 1);
      const configPath = join(evalsRoot, "cases", baseName, "eval.json");
      if (!existsSync(configPath)) continue;
      const frontend = (JSON.parse(readFileSync(configPath, "utf8")) as { frontend: string }).frontend;
      const track: MetricsTrack =
        labelTrack === "ts" || labelTrack === "zig"
          ? labelTrack
          : frontend === "ts-core"
            ? "ts"
            : "zig";
      let entry = cases.get(label);
      if (!entry) {
        entry = { case: label, track, trials: [] };
        cases.set(label, entry);
      }
      for (const trialDir of trialDirs(caseDir)) {
        const trial = analyzeTrial(label, track, trialDir, entry.trials.length + 1);
        if (trial) entry.trials.push(trial);
      }
    }
  }
  const all = [...cases.values()].sort((a, b) => a.case.localeCompare(b.case));
  if (all.length === 0) {
    console.error("no case results found in the given directories");
    process.exit(1);
  }
  printReport(all);
  const payload = JSON.stringify(all, null, 2);
  for (const dir of dirs) writeFileSync(join(dir, "authoring-metrics.json"), `${payload}\n`);
}

/** A case directory holds either result.json directly or trial-<n>/ subdirs. */
function trialDirs(caseDir: string): string[] {
  if (existsSync(join(caseDir, "result.json"))) return [caseDir];
  return readdirSync(caseDir)
    .filter((entry) => entry.startsWith("trial-") && existsSync(join(caseDir, entry, "result.json")))
    .sort((a, b) => Number(a.slice(6)) - Number(b.slice(6)))
    .map((entry) => join(caseDir, entry));
}

function analyzeTrial(
  caseName: string,
  track: MetricsTrack,
  trialDir: string,
  trialNumber: number,
): TrialMetrics | null {
  const result = JSON.parse(readFileSync(join(trialDir, "result.json"), "utf8")) as {
    passed: boolean;
    trial?: number;
    agent: {
      numTurns?: number;
      totalCostUsd?: number;
      cappedAtTurns?: boolean;
      durationMs?: number;
      inputTokens?: number;
      outputTokens?: number;
      cacheReadTokens?: number;
    };
  };
  // The shared walker (also run live by the runner) does the transcript pass:
  // compliance events with the friction filter, first-green + tail, generated
  // LOC, and token totals from the terminal result event.
  const analysis = analyzeTranscript(join(trialDir, "transcript.jsonl"), track);
  if (!analysis) return null;

  const violations: Record<string, number> = {};
  for (const output of analysis.failingRunOutputs) {
    for (const id of extractViolations(output, track)) {
      violations[id] = (violations[id] ?? 0) + 1;
    }
  }
  return {
    case: caseName,
    track,
    trial: result.trial ?? trialNumber,
    passed: result.passed,
    firstPassCompliant: analysis.firstRunGreen,
    retriesToGreen: analysis.retriesToGreen,
    everGreen: analysis.everGreen,
    complianceRuns: analysis.efficiency.verificationRuns,
    // Harness friction was already dropped from the stream, so every
    // remaining failing run carried a real diagnostic: each one is a
    // round-trip through the toolkit's teaching errors.
    teachingErrorEncounters: analysis.failingRunOutputs.length,
    violations,
    generatedLoc: analysis.generatedLoc,
    turns: result.agent.numTurns ?? null,
    observedTurns: analysis.efficiency.observedTurns,
    firstGreenTurn: analysis.efficiency.firstGreenTurn,
    firstGreenMs: analysis.efficiency.firstGreenMs,
    turnsAfterGreen: analysis.efficiency.turnsAfterGreen,
    costUsd: result.agent.totalCostUsd ?? null,
    durationMs: result.agent.durationMs ?? 0,
    // Prefer the runner-stamped totals (new runs); fall back to the
    // transcript's terminal result event for archived runs.
    inputTokens: result.agent.inputTokens ?? analysis.tokens?.inputTokens ?? null,
    outputTokens: result.agent.outputTokens ?? analysis.tokens?.outputTokens ?? null,
    cacheReadTokens: result.agent.cacheReadTokens ?? analysis.tokens?.cacheReadTokens ?? null,
    cappedAtTurns: result.agent.cappedAtTurns ?? false,
  };
}

/** ts track: NS/TS rule ids. zig track: dedup'd zig error lines, bucketed coarse. */
function extractViolations(output: string, track: MetricsTrack): string[] {
  if (track === "ts") {
    const ids = output.match(/\b(?:NS\d{4}|TS\d{4,5})\b/g) ?? [];
    return [...ids];
  }
  const lines = output.split("\n").filter((line) => / error: /.test(line));
  return lines.map((line) => {
    // Bucket the recurring 0.16-idiom shape so the taxonomy can answer
    // "did the zig skill's teaching land": "no member named 'X'" errors
    // keep their member name; everything else stays the coarse bucket.
    const member = /error: .*no member named '([^']+)'/.exec(line);
    return member ? `zig-no-member:${member[1]}` : "zig-error";
  });
}

// ------------------------------------------------------------------ report

interface TrackAggregate {
  track: string;
  trials: number;
  taskPassRate: string;
  firstPassRate: string;
  meanRetries: string;
  neverGreen: number;
  teachingEncounters: number;
  violationsPer1kLoc: string;
  totalViolations: number;
  generatedLoc: number;
  taxonomy: Record<string, number>;
}

function aggregateTrack(track: MetricsTrack, cases: CaseMetrics[]): TrackAggregate {
  const trials = cases.filter((entry) => entry.track === track).flatMap((entry) => entry.trials);
  const withCompliance = trials.filter((trial) => trial.firstPassCompliant !== null);
  const loc = trials.reduce((sum, trial) => sum + trial.generatedLoc, 0);
  const taxonomy: Record<string, number> = {};
  let violations = 0;
  for (const trial of trials) {
    for (const [id, count] of Object.entries(trial.violations)) {
      taxonomy[id] = (taxonomy[id] ?? 0) + count;
      violations += count;
    }
  }
  return {
    track,
    trials: trials.length,
    taskPassRate: rate(trials.filter((trial) => trial.passed).length, trials.length),
    firstPassRate: rate(withCompliance.filter((trial) => trial.firstPassCompliant === true).length, withCompliance.length),
    meanRetries: meanOf(trials.map((trial) => trial.retriesToGreen)),
    neverGreen: trials.filter((trial) => !trial.everGreen).length,
    teachingEncounters: trials.reduce((sum, trial) => sum + trial.teachingErrorEncounters, 0),
    violationsPer1kLoc: loc === 0 ? "-" : ((violations * 1000) / loc).toFixed(1),
    totalViolations: violations,
    generatedLoc: loc,
    taxonomy,
  };
}

function rate(hits: number, total: number): string {
  return total === 0 ? "-" : `${hits}/${total}`;
}

function meanOf(values: number[]): string {
  return values.length === 0 ? "-" : (values.reduce((sum, value) => sum + value, 0) / values.length).toFixed(2);
}

function printReport(cases: CaseMetrics[]): void {
  console.log("=== authoring metrics (per case) ===");
  const rows = cases.map((entry) => {
    const trials = entry.trials;
    const withCompliance = trials.filter((trial) => trial.firstPassCompliant !== null);
    const loc = trials.reduce((sum, trial) => sum + trial.generatedLoc, 0);
    const violations = trials.reduce(
      (sum, trial) => sum + Object.values(trial.violations).reduce((a, b) => a + b, 0),
      0,
    );
    return {
      case: entry.case,
      track: entry.track,
      trials: String(trials.length),
      "task pass": rate(trials.filter((trial) => trial.passed).length, trials.length),
      "first-pass": rate(withCompliance.filter((trial) => trial.firstPassCompliant === true).length, withCompliance.length),
      "retries→green": meanOf(trials.map((trial) => trial.retriesToGreen)),
      teaching: String(trials.reduce((sum, trial) => sum + trial.teachingErrorEncounters, 0)),
      "viol/1kLOC": loc === 0 ? "-" : ((violations * 1000) / loc).toFixed(1),
      loc: String(loc),
    };
  });
  const columns = ["case", "track", "trials", "task pass", "first-pass", "retries→green", "teaching", "viol/1kLOC", "loc"] as const;
  const widths = columns.map((column) => Math.max(column.length, ...rows.map((row) => row[column].length)));
  const line = (cells: string[]): string => cells.map((cell, index) => cell.padEnd(widths[index]!)).join("  ");
  console.log(line([...columns]));
  console.log(line(widths.map((width) => "-".repeat(width))));
  for (const row of rows) console.log(line(columns.map((column) => row[column])));

  console.log("\n=== per track ===");
  for (const track of ["ts", "zig"] as const) {
    const aggregate = aggregateTrack(track, cases);
    if (aggregate.trials === 0) continue;
    console.log(
      `${track}: trials ${aggregate.trials}, task pass ${aggregate.taskPassRate}, first-pass ${aggregate.firstPassRate}, mean retries→green ${aggregate.meanRetries}, never-green ${aggregate.neverGreen}, teaching-error encounters ${aggregate.teachingEncounters}, violations ${aggregate.totalViolations} (${aggregate.violationsPer1kLoc}/1kLOC over ${aggregate.generatedLoc} LOC)`,
    );
    const taxonomy = Object.entries(aggregate.taxonomy).sort((a, b) => b[1] - a[1]);
    for (const [id, count] of taxonomy) console.log(`    ${String(count).padStart(4)}  ${id}`);
  }

  printEfficiencyReport(cases);
}

// -------------------------------------------------------------- efficiency
//
// "first-green" throughout is the agent-verification proxy: the first
// agent-run check (`native test` / transpiler CLI / `native check` /
// `markup check`) that exited green after the first source edit. The graded
// check set runs once, post-trial, so this is "when the agent's own loop went
// green", not "when the graders would have passed" — see efficiency.ts.

function printEfficiencyReport(cases: CaseMetrics[]): void {
  console.log("\n=== efficiency (per track; median (mean); first-green = agent-verification proxy) ===");
  const trackRows = (["ts", "zig"] as const)
    .map((track) => {
      const trials = cases.filter((entry) => entry.track === track).flatMap((entry) => entry.trials);
      if (trials.length === 0) return undefined;
      const greens = trials.filter((trial) => trial.firstGreenTurn !== null);
      return {
        track,
        trials: String(trials.length),
        "green n": `${greens.length}/${trials.length}`,
        turns: medMean(trials.map(effectiveTurns)),
        "first-green": medMean(greens.map((trial) => trial.firstGreenTurn!)),
        tail: medMean(greens.map((trial) => trial.turnsAfterGreen!)),
        "wall min": medMean(trials.map((trial) => trial.durationMs / 60_000)),
        "cost usd": medMean(numbers(trials.map((trial) => trial.costUsd)), 2),
        "out ktok": medMean(numbers(trials.map((trial) => trial.outputTokens)).map((tokens) => tokens / 1000)),
        teaching: String(trials.reduce((sum, trial) => sum + trial.teachingErrorEncounters, 0)),
      };
    })
    .filter((row) => row !== undefined);
  printTable(
    ["track", "trials", "green n", "turns", "first-green", "tail", "wall min", "cost usd", "out ktok", "teaching"],
    trackRows,
  );
  console.log(
    "  tail = turns after the agent's own checks first went green (the post-green polishing the stop-when-green note should shrink).",
  );

  // Paired dual cases: the SAME spec ran on both tracks, so the side-by-side
  // per-case read (n=trials each side) is the strongest comparison available
  // at this scale. Cells are per-case trial means, "ts→zig (Δ = zig − ts)".
  const bases = new Map<string, { ts?: TrialMetrics[]; zig?: TrialMetrics[] }>();
  for (const entry of cases) {
    const at = entry.case.lastIndexOf("@");
    if (at === -1) continue;
    const base = entry.case.slice(0, at);
    const pair = bases.get(base) ?? {};
    pair[entry.track] = entry.trials;
    bases.set(base, pair);
  }
  const paired = [...bases.entries()].filter(([, pair]) => pair.ts && pair.zig).sort((a, b) => a[0].localeCompare(b[0]));
  if (paired.length === 0) return;
  console.log("\n=== paired dual cases (per-case trial means, ts→zig (Δ = zig − ts); first-green/tail over greened trials) ===");
  const pairedRows = paired.map(([base, pair]) => {
    const ts = pair.ts!;
    const zig = pair.zig!;
    const greensOf = (trials: TrialMetrics[]): TrialMetrics[] => trials.filter((trial) => trial.firstGreenTurn !== null);
    return {
      case: base,
      turns: pairedCell(ts.map(effectiveTurns), zig.map(effectiveTurns)),
      "first-green": pairedCell(greensOf(ts).map((trial) => trial.firstGreenTurn!), greensOf(zig).map((trial) => trial.firstGreenTurn!)),
      tail: pairedCell(greensOf(ts).map((trial) => trial.turnsAfterGreen!), greensOf(zig).map((trial) => trial.turnsAfterGreen!)),
      "cost usd": pairedCell(numbers(ts.map((trial) => trial.costUsd)), numbers(zig.map((trial) => trial.costUsd)), 2),
      "wall min": pairedCell(ts.map((trial) => trial.durationMs / 60_000), zig.map((trial) => trial.durationMs / 60_000)),
      pass: `${ts.filter((trial) => trial.passed).length}/${ts.length}→${zig.filter((trial) => trial.passed).length}/${zig.length}`,
    };
  });
  printTable(["case", "turns", "first-green", "tail", "cost usd", "wall min", "pass"], pairedRows);
}

/** The CLI's num_turns when it reported one; the transcript's assistant-message count for runs killed before the terminal result event (timeouts). */
function effectiveTurns(trial: TrialMetrics): number {
  return trial.turns ?? trial.observedTurns;
}

function numbers(values: (number | null)[]): number[] {
  return values.filter((value): value is number => value !== null);
}

function medianOf(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
}

/** "median (mean)" over the values, or "-" when there are none. */
function medMean(values: number[], digits = 1): string {
  if (values.length === 0) return "-";
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  return `${medianOf(values).toFixed(digits)} (${mean.toFixed(digits)})`;
}

/** "ts→zig (Δ)" cell from the two sides' trial means; "-" when either side is empty. */
function pairedCell(ts: number[], zig: number[], digits = 1): string {
  if (ts.length === 0 || zig.length === 0) return "-";
  const meanOfSide = (values: number[]): number => values.reduce((sum, value) => sum + value, 0) / values.length;
  const a = meanOfSide(ts);
  const b = meanOfSide(zig);
  const delta = b - a;
  return `${a.toFixed(digits)}→${b.toFixed(digits)} (${delta >= 0 ? "+" : ""}${delta.toFixed(digits)})`;
}

function printTable<Column extends string>(columns: readonly Column[], rows: Record<Column, string>[]): void {
  const widths = columns.map((column) => Math.max(column.length, ...rows.map((row) => row[column].length)));
  const line = (cells: string[]): string => cells.map((cell, index) => cell.padEnd(widths[index]!)).join("  ");
  console.log(line([...columns]));
  console.log(line(widths.map((width) => "-".repeat(width))));
  for (const row of rows) console.log(line(columns.map((column) => row[column])));
}

main();
