import { createWriteStream, mkdirSync } from "node:fs";
import { delimiter, join } from "node:path";
import { exec } from "./util.ts";
import type { AgentRunResult } from "./types.ts";

export const GATEWAY_BASE_URL = "https://ai-gateway.vercel.sh";
export const DEFAULT_MODEL = "anthropic/claude-sonnet-4.6";

/** Tools the agent-under-test may use without prompting (permission rule syntax). */
const ALLOWED_TOOLS = [
  "Read",
  "Edit",
  "Write",
  "Glob",
  "Grep",
  "Bash(zig *)",
  "Bash(zero-native *)",
  "Bash(ls *)",
  "Bash(cat *)",
  "Bash(mkdir *)",
  "Bash(rm -rf .zig-cache*)",
  "Bash(rm -rf zig-out*)",
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
    // zero-native CLI (markup check, automate, skills) on PATH for the agent.
    PATH: `${join(repoRoot, "zig-out", "bin")}${delimiter}${process.env.PATH ?? ""}`,
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

export function buildInvocation(options: {
  prompt: string;
  model: string;
  maxTurns: number;
  workspace: string;
  skipPermissions: boolean;
}): AgentInvocation {
  const argv = [
    "-p",
    options.prompt,
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
  }
  if (run.timedOut) {
    return { ...base, status: "timeout", errorDetail: `wall-clock timeout after ${options.timeoutMs}ms` };
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
