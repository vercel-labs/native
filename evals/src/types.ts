/** Per-case configuration, loaded from `cases/<name>/eval.json`. */
export interface EvalCase {
  /** Case name; must match the directory name. */
  name: string;
  /** Short human description of what the case exercises. */
  description: string;
  /** The task prompt handed to the agent-under-test. Describes app requirements, never the solution. */
  prompt: string;
  /** Scaffold frontend passed to `zero-native init --frontend <frontend>`. */
  frontend: "native";
  /** Wall-clock budget for the agent run, in milliseconds. */
  timeoutMs: number;
  /** `--max-turns` for the claude invocation. */
  maxTurns: number;
  /** Deterministic graders, run in order after the agent finishes. */
  checks: CheckSpec[];
}

export type CheckSpec =
  | BuildTestCheck
  | MarkupCheckCheck
  | FileGrepCheck
  | SnapshotGrepCheck;

/** Run `zig build test <args>` in the workspace. */
export interface BuildTestCheck {
  type: "build_test";
  /** Extra args, e.g. ["-Dplatform=null"]. */
  args?: string[];
}

/** Run `zero-native markup check` on every `src/**\/*.zml` in the workspace. */
export interface MarkupCheckCheck {
  type: "markup_check";
}

/** Grep workspace files for a pattern. */
export interface FileGrepCheck {
  type: "file_grep";
  /** Glob-ish file selector relative to the workspace: exact path or "src/*.zml". */
  files: string;
  /** JavaScript regular expression source (no flags; matched with "m"). */
  pattern: string;
  /** true = pattern must appear in at least one selected file; false = must appear in none. */
  expect: boolean;
  description: string;
}

/**
 * Build the workspace app with `-Dautomation=true`, launch it, wait for the
 * automation server, then grep the widget snapshot. macOS-local only; skipped
 * (reported as "skipped", not passed) when --skip-live is set.
 */
export interface SnapshotGrepCheck {
  type: "snapshot_grep";
  /** Each JavaScript regexp source must match somewhere in snapshot.txt. */
  patterns: string[];
  description: string;
}

export interface CheckResult {
  type: CheckSpec["type"];
  description: string;
  status: "pass" | "fail" | "skipped";
  /** Trimmed evidence: failing command output tail, missing pattern, etc. */
  detail?: string;
  durationMs: number;
}

export interface AgentRunResult {
  status: "completed" | "timeout" | "error" | "dry_run";
  model: string;
  numTurns?: number;
  totalCostUsd?: number;
  durationMs: number;
  sessionId?: string;
  /** Path to the captured stream-json transcript. */
  transcriptPath?: string;
  errorDetail?: string;
}

export interface CaseResult {
  case: string;
  workspace: string;
  startedAt: string;
  dryRun: boolean;
  agent: AgentRunResult;
  checks: CheckResult[];
  passed: boolean;
}

export interface RunnerOptions {
  repoRoot: string;
  evalsRoot: string;
  caseNames: string[];
  model: string;
  dryRun: boolean;
  skipLive: boolean;
  skipPermissions: boolean;
  keepWorkspaces: boolean;
}
