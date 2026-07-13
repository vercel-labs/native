// Transcript-derived efficiency analysis, shared by the runner (main.ts stamps
// result.json at trial time) and the authoring-metrics report (which also runs
// it post-hoc over archived results whose result.json predates these fields).
//
// The central metric is turns-to-first-green, and its epistemics matter:
//
//   The graded checks run ONCE, after the trial — the runner has no mid-trial
//   compliance signal, and re-running graders against intermediate workspace
//   states is impossible post-hoc (the transcript records edits, not snapshots).
//   What the transcript DOES record faithfully is every verification command
//   the agent itself ran and its exit status. So `firstGreenTurn` is the first
//   time the agent's OWN verification loop went green (the same command set the
//   graders' build_test/transpile checks run: `native test`, `zig build test`,
//   `native check`, the @native-sdk/core transpiler CLI, `markup check`) after
//   the first source edit — a proxy for "the work was done", not a claim that
//   the full graded check set (file greps, behavioral harnesses, snapshots)
//   passed at that turn. It can read early (agent's check is weaker than the
//   graders') or late (agent verified rarely). On trials whose final graded
//   checks passed, it is a defensible lower-ish bound on "when it actually
//   worked"; on failing trials it only describes the agent's belief.
//
// Turn indexing: `observedTurns` counts distinct assistant API messages in the
// stream-json transcript, which tracks the CLI's num_turns within ±1 (the CLI
// also counts the initial user turn). firstGreenTurn/turnsAfterGreen use this
// one consistent basis so the subtraction is exact.
//
// Token accounting: the gateway zeroes per-message usage in the stream (every
// assistant event reads 0/0), so totals come from the terminal `result`
// event's usage block — authoritative but absent when the run was killed
// before emitting one (wall-clock timeout). `inputTokens` is uncached input
// only; cache reads/creations are broken out separately.

import { existsSync, readFileSync } from "node:fs";
import type { EfficiencyMetrics, Track } from "./types.ts";

/** Metrics-side authoring track: ts-core and app-dual@ts are "ts"; native and app-dual@zig are "zig". */
export type MetricsTrack = "ts" | "zig";

export function metricsTrackFor(frontend: string, track: Track | undefined): MetricsTrack {
  if (track) return track;
  return frontend === "ts-core" ? "ts" : "zig";
}

export interface TokenTotals {
  /** Uncached input tokens (cache reads/creations are separate). */
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
}

/** Parse the `usage` block of a stream-json terminal result event. */
export function parseUsageTokens(usage: unknown): TokenTotals | undefined {
  if (typeof usage !== "object" || usage === null) return undefined;
  const record = usage as Record<string, unknown>;
  const num = (key: string): number => (typeof record[key] === "number" ? (record[key] as number) : 0);
  if (typeof record.output_tokens !== "number") return undefined;
  return {
    inputTokens: num("input_tokens"),
    outputTokens: num("output_tokens"),
    cacheReadTokens: num("cache_read_input_tokens"),
    cacheCreationTokens: num("cache_creation_input_tokens"),
  };
}

/** One agent-run verification command observed in the transcript. */
export interface VerificationRun {
  /** Ran after the agent's first source edit (pre-edit runs grade the scaffold, not the agent). */
  afterEdit: boolean;
  ok: boolean;
  output: string;
  /** Distinct assistant messages seen when the result arrived (the turn index). */
  turn: number;
  /** Epoch ms of the tool_result event, when the transcript stamped one. */
  atMs?: number;
}

export interface TranscriptAnalysis {
  efficiency: EfficiencyMetrics;
  /** Totals from the terminal result event; absent when the run died without one. */
  tokens?: TokenTotals;
  /** Outputs of failing after-edit verification runs (violation-taxonomy feed). */
  failingRunOutputs: string[];
  /** Did the FIRST after-edit verification run pass? null = agent never verified after editing. */
  firstRunGreen: boolean | null;
  /** Failing after-edit verification runs before the first green one (all of them when never green). */
  retriesToGreen: number;
  everGreen: boolean;
  /** Source lines the agent wrote via Write/Edit. */
  generatedLoc: number;
}

interface ToolUse {
  name: string;
  input: Record<string, unknown>;
}

/**
 * Single pass over a stream-json transcript. Returns null when the transcript
 * is missing (dry runs, crashed-before-spawn trials).
 */
export function analyzeTranscript(transcriptPath: string, track: MetricsTrack): TranscriptAnalysis | null {
  if (!existsSync(transcriptPath)) return null;

  const pending = new Map<string, ToolUse>();
  const assistantIds = new Set<string>();
  const runs: VerificationRun[] = [];
  let generatedLoc = 0;
  let editedSource = false;
  let firstTimestampMs: number | undefined;
  let tokens: TokenTotals | undefined;

  for (const line of readFileSync(transcriptPath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let event: Record<string, unknown>;
    try {
      event = JSON.parse(trimmed) as Record<string, unknown>;
    } catch {
      continue;
    }
    if (event.type === "result") {
      tokens = parseUsageTokens(event.usage) ?? tokens;
      continue;
    }
    const atMs = typeof event.timestamp === "string" ? Date.parse(event.timestamp) : Number.NaN;
    if (!Number.isNaN(atMs) && firstTimestampMs === undefined) firstTimestampMs = atMs;
    const message = event.message as { id?: unknown; content?: unknown } | undefined;
    if (!message || !Array.isArray(message.content)) continue;
    if (event.type === "assistant" && typeof message.id === "string") assistantIds.add(message.id);
    for (const block of message.content as Record<string, unknown>[]) {
      if (block.type === "tool_use") {
        const use: ToolUse = {
          name: String(block.name),
          input: (block.input ?? {}) as Record<string, unknown>,
        };
        pending.set(String(block.id), use);
        // Source edits: count generated lines, mark the editing phase.
        if (use.name === "Write" || use.name === "Edit") {
          const path = String(use.input.file_path ?? "");
          if (isSourceFile(path, track)) {
            editedSource = true;
            const text = String((use.name === "Write" ? use.input.content : use.input.new_string) ?? "");
            generatedLoc += text.length === 0 ? 0 : text.split("\n").length;
          }
        }
      } else if (block.type === "tool_result") {
        const use = pending.get(String(block.tool_use_id));
        if (!use || use.name !== "Bash") continue;
        const command = String(use.input.command ?? "");
        if (!isComplianceCommand(command, track)) continue;
        const output = blockText(block.content);
        // Harness friction is not an authoring signal: a command the
        // permission system refused never ran, and an errored compound whose
        // output carries no compiler/checker diagnostic (shell quirks, tool
        // timeouts) graded nothing. Both are dropped from the event stream.
        if (block.is_error === true) {
          if (/requires approval|was blocked|contains multiple operations/.test(output)) continue;
          if (!hasDiagnostic(output)) continue;
        }
        const run: VerificationRun = {
          afterEdit: editedSource,
          ok: block.is_error !== true,
          output,
          turn: assistantIds.size,
        };
        if (!Number.isNaN(atMs)) run.atMs = atMs;
        runs.push(run);
      }
    }
  }

  const graded = runs.filter((run) => run.afterEdit);
  const firstGreenIndex = graded.findIndex((run) => run.ok);
  const firstGreen = firstGreenIndex === -1 ? undefined : graded[firstGreenIndex];
  const observedTurns = assistantIds.size;
  const efficiency: EfficiencyMetrics = {
    observedTurns,
    verificationRuns: graded.length,
    firstGreenTurn: firstGreen ? firstGreen.turn : null,
    firstGreenMs:
      firstGreen && firstGreen.atMs !== undefined && firstTimestampMs !== undefined
        ? firstGreen.atMs - firstTimestampMs
        : null,
    turnsAfterGreen: firstGreen ? observedTurns - firstGreen.turn : null,
  };
  const analysis: TranscriptAnalysis = {
    efficiency,
    failingRunOutputs: graded.filter((run) => !run.ok).map((run) => run.output),
    firstRunGreen: graded.length === 0 ? null : graded[0]!.ok,
    retriesToGreen: firstGreenIndex === -1 ? graded.length : firstGreenIndex,
    everGreen: firstGreenIndex !== -1,
    generatedLoc,
  };
  if (tokens) analysis.tokens = tokens;
  return analysis;
}

export function isSourceFile(path: string, track: MetricsTrack): boolean {
  if (!path.includes("/src/") && !path.startsWith("src/")) return false;
  // Markup is source on both tracks (app-dual workspaces have a view);
  // core-only ts workspaces simply never write .native files.
  return track === "ts"
    ? path.endsWith(".ts") || path.endsWith(".native")
    : path.endsWith(".zig") || path.endsWith(".native");
}

/**
 * The commands that constitute a compliance check. ts track: any invocation
 * of the @native-sdk/core transpiler CLI (typecheck + subset rules +
 * emission), plus the app verbs an app-workspace loop runs (`native check`
 * runs the same checker; `native test`/`native build` compile the emitted
 * core and the markup bindings). zig track: the app build/test verbs the
 * build_test grader runs, plus `native check` and `native markup check` —
 * the markup checker is the closest analog of the subset checker there.
 */
export function isComplianceCommand(command: string, track: MetricsTrack): boolean {
  if (track === "ts" && command.includes("packages/core") && (command.includes("cli.ts") || command.includes("core.ts"))) {
    return true;
  }
  return /\bnative test\b|\bzig build test\b|\bnative build\b|\bnative check\b|\bmarkup check\b/.test(command);
}

/** A compiler/checker diagnostic somewhere in the output. */
export function hasDiagnostic(output: string): boolean {
  return /\berror(:| NS\d{4}| TS\d{4,5})/.test(output);
}

export function blockText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((piece) => (typeof piece === "object" && piece !== null && "text" in piece ? String((piece as { text: unknown }).text) : ""))
    .join("\n");
}
