/** Per-case configuration, loaded from `cases/<name>/eval.json`. */
export interface EvalCase {
  /** Case name; must match the directory name. */
  name: string;
  /** Short human description of what the case exercises. */
  description: string;
  /** The task prompt handed to the agent-under-test. Describes app requirements, never the solution. */
  prompt: string;
  /**
   * Workspace shape. "native" scaffolds with `native init --frontend native`
   * (the Zig-core app template); "ts-core" scaffolds a core-only TypeScript
   * workspace (src/core.ts starter, README, the ts-core skill) graded
   * through the @native-sdk/core transpiler; "app-dual" is a wave-2
   * dual-track case: ONE language-blind spec that runs on both authoring
   * tracks — the ts track scaffolds a full TypeScript app
   * (`native init --frontend native --template ts-core`), the zig track the
   * Zig app template (`--template zig-core`) — with a shared check list plus
   * thin per-track additions under `tracks`.
   */
  frontend: "native" | "ts-core" | "app-dual";
  /**
   * app-dual only: per-track configuration. The shared `checks` run on both
   * tracks; each track's `checks` are appended after them. Starters are
   * discovered by convention: `cases/<name>/starter-ts/` overlays the ts
   * workspace, `starter-zig/` the zig workspace.
   */
  tracks?: { ts: TrackSpec; zig: TrackSpec };
  /** Wall-clock budget for the agent run, in milliseconds. */
  timeoutMs: number;
  /** `--max-turns` for the claude invocation. */
  maxTurns: number;
  /** Deterministic graders, run in order after the agent finishes. */
  checks: CheckSpec[];
}

/** The authoring track of one app-dual run. */
export type Track = "ts" | "zig";

/** Thin per-track configuration of an app-dual case. */
export interface TrackSpec {
  /** Track-specific graders, appended after the case's shared checks. */
  checks?: CheckSpec[];
}

/**
 * One schedulable unit: a case on a concrete track. Non-dual cases produce
 * exactly one runnable with `track` undefined; app-dual cases produce one
 * per selected track (label `<case>@<track>`).
 */
export interface RunnableCase {
  evalCase: EvalCase;
  track?: Track | undefined;
  /** `<case>` or `<case>@<track>`: results dir and log prefix. */
  label: string;
  /** The merged check list this run grades with. */
  checks: CheckSpec[];
}

/**
 * Where a case ran and got graded. `macos-local` is the default local run;
 * `linux-sandbox` is a per-case Vercel Sandbox microVM (Linux, headless X).
 */
export type Lane = "macos-local" | "linux-sandbox";

/** Fields every check type accepts. */
interface CheckCommon {
  /**
   * Lanes this check grades on; omitted means every lane. Annotate a check
   * here when the surface it greps exists on only one OS, so on the other
   * lane it reports "skipped (lane)" instead of failing the case — the
   * summary then distinguishes "fails" from "not applicable on this lane".
   */
  lanes?: Lane[];
}

export type CheckSpec =
  | BuildTestCheck
  | MarkupCheckCheck
  | FileGrepCheck
  | SnapshotGrepCheck
  | TsTranspileCheck
  | TsHarnessCheck
  | ZigHarnessCheck
  | LlmJudgeCheck;

/** Run `native test <args>` in the workspace (zero-config app test suite). */
export interface BuildTestCheck extends CheckCommon {
  type: "build_test";
  /** Extra zig build flags passed through, e.g. ["-Dplatform=null"]. */
  args?: string[];
}

/** Run `native markup check` on every `src/**\/*.native` in the workspace. */
export interface MarkupCheckCheck extends CheckCommon {
  type: "markup_check";
}

/**
 * Run the @native-sdk/core transpiler on the workspace core (ts-core cases).
 * Pass = the module typechecks (tsc semantics), passes every subset rule
 * (NS1001-NS1050), and emits Zig. The diagnostics tail is kept as evidence,
 * so violation taxonomy can be read off failing runs.
 */
export interface TsTranspileCheck extends CheckCommon {
  type: "ts_transpile";
  /** Core module path relative to the workspace. Default "src/core.ts". */
  entry?: string;
}

/**
 * Behavioral grading for ts-core cases: transpile the workspace core, then
 * `zig test` the case's harness.zig (from cases/<name>/) against the emitted
 * core and the rt kernel in a scratch directory. The harness drives the real
 * dispatch cycle (update -> commitModelRoot -> frameReset) and asserts the
 * case's required behavior.
 */
export interface TsHarnessCheck extends CheckCommon {
  type: "ts_harness";
  /** Core module path relative to the workspace. Default "src/core.ts". */
  entry?: string;
  /** Harness file name inside the case dir. Default "harness.zig". */
  harness?: string;
  description: string;
}

/**
 * Behavioral grading for the zig track of app-dual cases: copy the case's
 * Zig harness (default "harness-zig.zig") into the workspace as
 * `src/eval_behavior_spec.zig`, append a test import of it to src/main.zig,
 * run `native test` (the workspace's zero-config test graph, so the harness
 * compiles against the agent's real Model/Msg/update with the SDK modules
 * available), then restore the workspace. The harness drives update — the
 * fake effects executor included — and asserts the same behavioral spec the
 * ts track's harness asserts.
 */
export interface ZigHarnessCheck extends CheckCommon {
  type: "zig_harness";
  /** Harness file name inside the case dir. Default "harness-zig.zig". */
  harness?: string;
  /** Extra zig build flags for the `native test` run, e.g. ["-Dplatform=null"]. */
  args?: string[];
  description: string;
}

/** Grep workspace files for a pattern. */
export interface FileGrepCheck extends CheckCommon {
  type: "file_grep";
  /** Glob-ish file selector relative to the workspace: exact path or "src/*.native". */
  files: string;
  /** JavaScript regular expression source (no flags; matched with "m"). */
  pattern: string;
  /** true = pattern must appear in at least one selected file; false = must appear in none. */
  expect: boolean;
  description: string;
}

/**
 * Build the workspace app with `-Dautomation=true`, launch it (directly on
 * the macos-local lane, under the sandbox's Xvfb display on linux-sandbox),
 * wait for the automation server, then grep the widget snapshot. Skipped
 * (reported as "skipped", not passed) when --skip-live is set or the lane
 * has no way to launch the app.
 */
export interface SnapshotGrepCheck extends CheckCommon {
  type: "snapshot_grep";
  /** Each JavaScript regexp source must match somewhere in snapshot.txt. */
  patterns: string[];
  description: string;
}

/**
 * Grade quality dimensions the deterministic checks can't see (idiomatic
 * Model/Msg design, template factoring, test meaningfulness) with a judge
 * model called directly through the AI Gateway. Advisory by default: the
 * score is recorded and printed but never fails the case. Skipped in
 * --dry-run (no model calls).
 */
export interface LlmJudgeCheck extends CheckCommon {
  type: "llm_judge";
  /** Case-specific criteria, each scored 0-10 by the judge. */
  criteria: string[];
  /** Workspace files to show the judge (default: src/*.native, src/main.zig, src/tests.zig). */
  files?: string[];
  /** Overall score at or above this counts as pass. Default 6. */
  minScore?: number;
  /** When false, an overall score below minScore fails the case. Default true. */
  advisory?: boolean;
  description: string;
}

export interface CheckResult {
  type: CheckSpec["type"];
  description: string;
  status: "pass" | "fail" | "skipped";
  /** Trimmed evidence: failing command output tail, missing pattern, etc. */
  detail?: string;
  /** llm_judge only: the judge's overall 0-10 score. */
  score?: number;
  /** llm_judge only: a failing advisory check does not fail the case. */
  advisory?: boolean;
  durationMs: number;
}

export interface AgentRunResult {
  /**
   * "capped" = the run ended by hitting --max-turns. The workspace still
   * grades, and green-at-cap counts as a task pass: 17 of 20 wave-2
   * failures were runs whose every check passed but whose agent burned
   * the cap on extra verification — friction, not semantics. The cap
   * shows up as cost (turns, cappedAtTurns), never as a task failure.
   */
  status: "completed" | "capped" | "timeout" | "error" | "dry_run";
  model: string;
  numTurns?: number;
  totalCostUsd?: number;
  /**
   * Token totals from the CLI's terminal result event. Absent when the run
   * was killed before emitting one (wall-clock timeout). `inputTokens` is
   * uncached input only; cache reads/creations are broken out because they
   * dominate volume (and are billed differently).
   */
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
  /** True exactly when status is "capped": a per-trial cost metric. */
  cappedAtTurns?: boolean;
  durationMs: number;
  sessionId?: string;
  /** Path to the captured stream-json transcript. */
  transcriptPath?: string;
  errorDetail?: string;
}

/**
 * View-authoring telemetry computed from the finished workspace: how much of
 * the UI is `.native` markup vs Zig builder calls. Never a pass/fail signal.
 * Heuristic documented in markup-share.ts.
 */
export interface MarkupShare {
  /** Count of src/*.native markup files (also one subdirectory level deep). */
  nativeFiles: number;
  /** Total bytes across those markup files; a markup file is view code in full. */
  nativeBytes: number;
  /** Unioned lines covered by builder node-constructing call expressions in non-test src/*.zig. */
  builderViewLines: number;
  /** Actual source bytes of those lines, newlines included. */
  builderViewBytes: number;
  /** nativeBytes / (nativeBytes + builderViewBytes); null when no view code was found. */
  share: number | null;
}

/**
 * Efficiency read derived from the trial's transcript (see efficiency.ts for
 * the full epistemics). The first-green fields are the AGENT-VERIFICATION
 * PROXY: the graded checks run once, post-trial, so "first green" here means
 * the first time the agent's OWN verification command (`native test`,
 * `zig build test`, `native check`, the core transpiler CLI, `markup check`)
 * exited green after the first source edit — NOT the first time the full
 * graded check set passed. On trials whose graded checks ultimately passed
 * it is a defensible estimate of "when the work was actually done"; on
 * failing trials it only records the agent's belief.
 */
export interface EfficiencyMetrics {
  /**
   * Distinct assistant API messages in the transcript; tracks the CLI's
   * num_turns within ±1 and is the one consistent basis for the
   * firstGreenTurn/turnsAfterGreen subtraction.
   */
  observedTurns: number;
  /** Agent-run verification commands observed after the first source edit. */
  verificationRuns: number;
  /** Turn index of the first green agent verification; null = never went green. */
  firstGreenTurn: number | null;
  /**
   * ms from the first timestamped transcript event to the first green
   * verification (assistant events carry no timestamps, so the clock starts
   * at the first tool result — early in turn 1); null when never green.
   */
  firstGreenMs: number | null;
  /**
   * observedTurns − firstGreenTurn: the post-green tail. Turns spent after
   * the agent's own checks were already green — the "verification theater"
   * measure the stop-when-green harness note exists to shrink.
   */
  turnsAfterGreen: number | null;
}

export interface CaseResult {
  case: string;
  /** Authoring track of an app-dual run ("ts" | "zig"); absent otherwise. */
  track?: Track;
  /** 1-based trial number; only present when the run had --trials > 1. */
  trial?: number;
  /** Where the case ran and got graded. */
  lane: Lane;
  workspace: string;
  startedAt: string;
  dryRun: boolean;
  agent: AgentRunResult;
  /** Absent only when the run crashed before a workspace existed. */
  markupShare?: MarkupShare;
  /** Transcript-derived efficiency; absent in --dry-run and crashed trials. */
  efficiency?: EfficiencyMetrics;
  checks: CheckResult[];
  passed: boolean;
}

/** Per-check aggregation across the trials of one case (--trials > 1). */
export interface CheckAggregate {
  type: CheckSpec["type"];
  description: string;
  pass: number;
  fail: number;
  skipped: number;
  /** llm_judge only: mean of the recorded overall scores. */
  meanScore?: number;
}

/**
 * Aggregated result for one case across N independent trials, written to
 * results/<stamp>/<case>/aggregate.json (per-trial result.json files live in
 * results/<stamp>/<case>/trial-<n>/). Only produced when --trials > 1.
 */
export interface CaseAggregate {
  /** `<case>` or `<case>@<track>` for app-dual runs. */
  case: string;
  /** Authoring track of an app-dual case ("ts" | "zig"); absent otherwise. */
  track?: Track;
  trials: number;
  /** Trials where every non-advisory check passed and the agent completed (or capped at --max-turns with green checks). */
  passedTrials: number;
  /** Trials that hit --max-turns (a cost signal, independent of pass/fail); absent when zero. */
  cappedTrials?: number;
  checks: CheckAggregate[];
  /** Mean of all recorded llm_judge overall scores across trials. */
  meanJudgeScore?: number;
  /** Mean markup share across trials that measured one (see MarkupShare). */
  meanMarkupShare?: number;
  meanTurns?: number;
  /** Mean turn of the first green agent verification, over trials that had one (see EfficiencyMetrics). */
  meanFirstGreenTurn?: number;
  /** Mean post-green tail (turnsAfterGreen), over trials that went green. */
  meanTurnsAfterGreen?: number;
  totalCostUsd?: number;
  /** Summed token totals across trials that recorded them (see AgentRunResult). */
  totalInputTokens?: number;
  totalOutputTokens?: number;
  totalCacheReadTokens?: number;
  /** Sum of per-trial durations (agent + checks); trials may overlap in wall-clock. */
  totalDurationMs: number;
  results: CaseResult[];
}

export interface RunnerOptions {
  repoRoot: string;
  evalsRoot: string;
  caseNames: string[];
  /**
   * Track filter for app-dual cases: run only the named track. Default
   * (undefined) runs both tracks of every selected dual case. Non-dual
   * cases ignore the filter.
   */
  track: Track | undefined;
  model: string;
  judgeModel: string;
  dryRun: boolean;
  skipLive: boolean;
  skipPermissions: boolean;
  keepWorkspaces: boolean;
  /** Independent trials per case (own workspace, agent run, checks, judge). Default 1. */
  trials: number;
  /** Cases run concurrently up to this limit (default 2 local, all in sandbox mode). */
  concurrency: number | undefined;
  /** Run each case in its own Vercel Sandbox microVM instead of locally. */
  sandbox: boolean;
  sandboxVcpus: number;
  /**
   * Registry reference for the sandbox image (see evals/sandbox/). A bare
   * repository name resolves within the linked project; `latest` tag.
   */
  sandboxImage: string;
  /**
   * Grading lane. Local runs grade on macos-local; the sandbox path passes
   * --lane linux-sandbox to the harness invocation inside the microVM.
   */
  lane: Lane;
}
