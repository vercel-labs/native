import { createWriteStream, mkdirSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { exec } from "./util.ts";
import { parseUsageTokens } from "./efficiency.ts";
import type { AgentRunResult } from "./types.ts";

export const GATEWAY_BASE_URL = "https://ai-gateway.vercel.sh";
export const DEFAULT_MODEL = "anthropic/claude-sonnet-5";

/** Tools the agent-under-test may use without prompting (permission rule syntax). */
const ALLOWED_TOOLS = [
  "Read",
  "Edit",
  "Write",
  "Glob",
  "Grep",
  "Bash(zig *)",
  "Bash(native *)",
  // ts-core cases: the agent's check loop is the @native-sdk/core transpiler run
  // through node, and the subset runs under node for behavioral pokes.
  "Bash(node *)",
  "Bash(ls *)",
  "Bash(cat *)",
  "Bash(mkdir *)",
  // File moves and copies are routine scaffolding work (renaming a view,
  // copying an example as a starting point); without them agents burn
  // turns waiting on permission prompts that will never be answered.
  "Bash(cp *)",
  "Bash(mv *)",
  "Bash(rm -rf .zig-cache*)",
  "Bash(rm -rf zig-out*)",
  // Wave-2 friction, straight from the denial tallies: python one-liners
  // (byte math, quick asset generation), everyday read-only git (log for
  // orientation, show for a diff), and the agent invoking the repo's own
  // `native` binary by ABSOLUTE path when it second-guesses PATH. `git
  // stash` is deliberately NOT allowed: workspaces carry no .git, so any
  // mutating git command walks up and operates on the FRAMEWORK repo's
  // index (a stash apply once landed a months-old host stash as a merge
  // conflict mid-battery). GIT_CEILING_DIRECTORIES in the agent env is the
  // structural guard; the missing allow entry is belt and braces.
  // Contamination stays closed: deny rules below are checked first.
  "Bash(python3 -c *)",
  "Bash(git log*)",
  "Bash(git show*)",
  "Bash(*zig-out/bin/native *)",
].join(",");

/**
 * Deny rules for the agent-under-test. The workspace references the framework
 * repo by path, so the whole repo — including this harness — is reachable from
 * the agent's cwd; exploring framework source and examples is realistic (a
 * real user has the repo), but the grading configs and prior results are
 * contamination (observed: 3/20 runs of the 2026-07-04 suite read their own
 * eval.json). Deny rules are checked before allow rules, including for
 * already-allowed tools like Read and Bash(cat *).
 */
const DISALLOWED_TOOLS = [
  "Read(//**/evals/cases/**)",
  "Read(//**/evals/results/**)",
  "Read(//**/evals/harness-lib/**)",
  "Bash(cat *evals/cases*)",
  "Bash(cat *evals/results*)",
  "Bash(cat *evals/harness-lib*)",
  // The cases are committed, so git plumbing can serve them without touching
  // the filesystem (observed: `git show HEAD:evals/cases/<case>/eval.json`).
  // `git show`/`git log` are allowed in general (workspace orientation) but
  // any invocation naming evals content stays denied — deny rules win over
  // allow rules. `git cat-file`/`git grep` reach blob content without an
  // `evals` path in the command line, so they stay fully denied.
  "Bash(git show*evals*)",
  "Bash(git log*evals*)",
  "Bash(git cat-file*)",
  "Bash(git grep*)",
].join(",");

export function findGatewayKey(env: NodeJS.ProcessEnv): string | undefined {
  return env.AI_GATEWAY_API_KEY ?? env.VERCEL_AI_GATEWAY_API_KEY;
}

export interface AgentEnv {
  env: NodeJS.ProcessEnv;
  /** env assembly with the token redacted, for logging / --dry-run. */
  redacted: Record<string, string>;
}

/**
 * Environment for the claude subprocess, per Vercel's AI Gateway docs
 * (https://vercel.com/docs/ai-gateway/coding-agents/claude-code):
 * ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN, and ANTHROPIC_API_KEY set to the
 * EMPTY string (Claude Code prefers a non-empty ANTHROPIC_API_KEY over the
 * auth token). CLAUDE_CONFIG_DIR points at a per-run directory so the
 * agent-under-test is clean: no user-level memory, plugins, or hooks leak in;
 * the workspace's own .claude/skills/native-ui is the only guidance it gets.
 */
export function assembleAgentEnv(
  gatewayKey: string,
  repoRoot: string,
  configDir: string,
  workspaceDir: string,
): AgentEnv {
  const inherited: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (key.startsWith("ANTHROPIC_") || key.startsWith("CLAUDE_") || key === "CLAUDECODE") continue;
    inherited[key] = value;
  }
  const overrides: Record<string, string> = {
    ANTHROPIC_BASE_URL: GATEWAY_BASE_URL,
    ANTHROPIC_AUTH_TOKEN: gatewayKey,
    ANTHROPIC_API_KEY: "",
    CLAUDE_CONFIG_DIR: configDir,
    // Native SDK CLI (markup check, automate, skills) on PATH for the agent.
    PATH: `${join(repoRoot, "zig-out", "bin")}${delimiter}${process.env.PATH ?? ""}`,
    // Workspaces carry no .git; without a ceiling, any git command the
    // agent runs walks up and operates on the FRAMEWORK repo. The ceiling
    // makes git stop at the workspace parent: inside the workspace git
    // sees "not a repository" instead of our index.
    GIT_CEILING_DIRECTORIES: dirname(workspaceDir),
  };
  const redacted = { ...overrides, ANTHROPIC_AUTH_TOKEN: redact(gatewayKey) };
  return { env: { ...inherited, ...overrides }, redacted };
}

function redact(secret: string): string {
  if (secret.length <= 8) return "****";
  return `${secret.slice(0, 4)}...${secret.slice(-4)} (${secret.length} chars)`;
}

export interface AgentInvocation {
  argv: string[];
  cwd: string;
}

/**
 * Harness guidance appended to every case prompt. Wave-2 showed 17 of 20
 * failures were green-at-cap: agents whose checks were already passing
 * burned the turn budget on app launches and extra verification, or lost
 * turns writing scratch files to the blocked /tmp. Cases never restate
 * these; the harness owns them.
 */
export const PROMPT_SUFFIX = [
  "Harness notes:",
  "- Stop once the README check loop is green; do not launch the app or perform extra verification.",
  "- Scratch files go inside the workspace; /tmp is blocked.",
].join("\n");

export function buildInvocation(options: {
  prompt: string;
  model: string;
  maxTurns: number;
  workspace: string;
  skipPermissions: boolean;
}): AgentInvocation {
  const argv = [
    "-p",
    `${options.prompt}\n\n${PROMPT_SUFFIX}`,
    "--output-format",
    "stream-json",
    "--verbose",
    "--model",
    options.model,
    "--max-turns",
    String(options.maxTurns),
  ];
  if (options.skipPermissions) {
    argv.push("--dangerously-skip-permissions");
  } else {
    argv.push("--permission-mode", "acceptEdits", "--allowedTools", ALLOWED_TOOLS);
  }
  // Deny rules apply in both permission modes.
  argv.push("--disallowedTools", DISALLOWED_TOOLS);
  return { argv, cwd: options.workspace };
}

/**
 * Run `claude -p` headless in the workspace, streaming the transcript to
 * `<resultsDir>/transcript.jsonl`, and parse the terminal `result` event for
 * turns/cost/session.
 */
export async function runAgent(options: {
  invocation: AgentInvocation;
  agentEnv: AgentEnv;
  model: string;
  timeoutMs: number;
  resultsDir: string;
}): Promise<AgentRunResult> {
  mkdirSync(options.resultsDir, { recursive: true });
  const transcriptPath = join(options.resultsDir, "transcript.jsonl");
  const transcript = createWriteStream(transcriptPath);
  let buffered = "";
  let resultEvent: Record<string, unknown> | undefined;
  const handleLine = (line: string): void => {
    const trimmed = line.trim();
    if (!trimmed) return;
    transcript.write(`${trimmed}\n`);
    try {
      const event = JSON.parse(trimmed) as Record<string, unknown>;
      if (event.type === "result") resultEvent = event;
    } catch {
      // Non-JSON noise on stdout; keep it in the transcript only.
    }
  };

  let run;
  try {
    run = await exec("claude", options.invocation.argv, {
      cwd: options.invocation.cwd,
      env: options.agentEnv.env,
      timeoutMs: options.timeoutMs,
      onStdout: (chunk) => {
        buffered += chunk;
        let newline;
        while ((newline = buffered.indexOf("\n")) !== -1) {
          handleLine(buffered.slice(0, newline));
          buffered = buffered.slice(newline + 1);
        }
      },
    });
  } catch (error) {
    transcript.end();
    return {
      status: "error",
      model: options.model,
      durationMs: 0,
      transcriptPath,
      errorDetail: `failed to spawn claude: ${(error as Error).message}`,
    };
  }
  handleLine(buffered);
  transcript.end();

  const base: AgentRunResult = {
    status: "completed",
    model: options.model,
    durationMs: run.durationMs,
    transcriptPath,
  };
  if (resultEvent) {
    if (typeof resultEvent.num_turns === "number") base.numTurns = resultEvent.num_turns;
    if (typeof resultEvent.total_cost_usd === "number") base.totalCostUsd = resultEvent.total_cost_usd;
    if (typeof resultEvent.session_id === "string") base.sessionId = resultEvent.session_id;
    // Token accounting comes from here, not the per-message stream: the
    // gateway zeroes usage on streamed assistant events, so the terminal
    // result event's usage block is the only truthful total. Timeout kills
    // never emit one — the token fields simply stay absent then.
    const tokens = parseUsageTokens(resultEvent.usage);
    if (tokens) {
      base.inputTokens = tokens.inputTokens;
      base.outputTokens = tokens.outputTokens;
      base.cacheReadTokens = tokens.cacheReadTokens;
      base.cacheCreationTokens = tokens.cacheCreationTokens;
    }
  }
  if (run.timedOut) {
    return { ...base, status: "timeout", errorDetail: `wall-clock timeout after ${options.timeoutMs}ms` };
  }
  // Hitting --max-turns exits non-zero with is_error, but the workspace is
  // whole and gradable — classify it BEFORE the generic error branches so
  // green-at-cap scores as a pass with the cap recorded as cost.
  if (resultEvent && (resultEvent.subtype === "error_max_turns" || resultEvent.terminal_reason === "max_turns")) {
    return { ...base, status: "capped", cappedAtTurns: true, errorDetail: "hit --max-turns; grading the workspace as delivered" };
  }
  if (run.code !== 0) {
    const stderrTail = run.stderr.split("\n").filter(Boolean).slice(-8).join("\n");
    return { ...base, status: "error", errorDetail: `claude exited ${run.code}\n${stderrTail}` };
  }
  if (resultEvent && resultEvent.is_error === true) {
    return { ...base, status: "error", errorDetail: String(resultEvent.result ?? "agent reported error") };
  }
  return base;
}
