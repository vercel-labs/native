import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_MODEL,
  assembleAgentEnv,
  buildInvocation,
  findGatewayKey,
  runAgent,
} from "./agent.ts";
import { buildCli, scaffoldWorkspace } from "./scaffold.ts";
import { runChecks } from "./grade.ts";
import { formatDuration } from "./util.ts";
import type { AgentRunResult, CaseResult, EvalCase, RunnerOptions } from "./types.ts";

const USAGE = `usage: pnpm eval [options] [case ...]

Runs Claude Code headless (claude -p) through the Vercel AI Gateway against a
freshly scaffolded zero-native workspace, then grades the result.

options:
  --list               list available cases and exit
  --dry-run            everything except the model call: scaffold, deliver the
                       skill, print the env assembly + claude argv, then run
                       the graders against the workspace as-scaffolded
  --skip-live          skip snapshot_grep checks (no app launch)
  --skip-permissions   run claude with --dangerously-skip-permissions instead
                       of acceptEdits + an allowlist (sandbox dirs only)
  --keep-workspaces    do not delete .workspaces/<case> after grading
  --model <slug>       gateway model slug (default: ${DEFAULT_MODEL};
                       also via ZN_EVAL_MODEL)

env:
  AI_GATEWAY_API_KEY   Vercel AI Gateway API key (or VERCEL_AI_GATEWAY_API_KEY)
`;

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  const cases = loadCases(options);
  if (cases.length === 0) {
    console.error("no cases selected");
    process.exit(2);
  }

  const gatewayKey = findGatewayKey(process.env);
  if (!gatewayKey && !options.dryRun) {
    console.error(
      "AI_GATEWAY_API_KEY (or VERCEL_AI_GATEWAY_API_KEY) is not set.\n" +
        "Real runs need a Vercel AI Gateway key; use --dry-run to exercise everything except the model call.",
    );
    process.exit(2);
  }

  const cliPath = await buildCli(options.repoRoot);
  const runStamp = new Date().toISOString().replace(/[:.]/g, "-");
  const runResultsDir = join(options.evalsRoot, "results", runStamp);
  const workspacesDir = join(options.evalsRoot, ".workspaces");
  mkdirSync(runResultsDir, { recursive: true });

  const results: CaseResult[] = [];
  for (const evalCase of cases) {
    console.log(`\n=== case: ${evalCase.name} ===`);
    const caseResultsDir = join(runResultsDir, evalCase.name);
    mkdirSync(caseResultsDir, { recursive: true });
    const startedAt = new Date().toISOString();

    const workspace = await scaffoldWorkspace(
      options.repoRoot,
      cliPath,
      workspacesDir,
      evalCase.name,
      evalCase.frontend,
    );
    console.log(`  [scaffold] workspace ready: ${workspace.path}`);
    console.log(`  [scaffold] skill delivered: .claude/skills/native-ui/SKILL.md`);

    const configDir = join(caseResultsDir, "claude-config");
    mkdirSync(configDir, { recursive: true });
    const invocation = buildInvocation({
      prompt: evalCase.prompt,
      model: options.model,
      maxTurns: evalCase.maxTurns,
      workspace: workspace.path,
      skipPermissions: options.skipPermissions,
    });

    let agent: AgentRunResult;
    if (options.dryRun) {
      const agentEnv = assembleAgentEnv(gatewayKey ?? "<AI_GATEWAY_API_KEY>", options.repoRoot, configDir);
      console.log("  [dry-run] env overrides for the claude subprocess:");
      for (const [key, value] of Object.entries(agentEnv.redacted)) {
        console.log(`    ${key}=${value}`);
      }
      console.log(`  [dry-run] claude ${formatArgv(invocation.argv)}`);
      console.log(`  [dry-run] cwd: ${invocation.cwd}`);
      agent = { status: "dry_run", model: options.model, durationMs: 0 };
    } else {
      const agentEnv = assembleAgentEnv(gatewayKey!, options.repoRoot, configDir);
      console.log(`  [agent] claude -p (model ${options.model}, max ${evalCase.maxTurns} turns, timeout ${formatDuration(evalCase.timeoutMs)})...`);
      agent = await runAgent({
        invocation,
        agentEnv,
        model: options.model,
        timeoutMs: evalCase.timeoutMs,
        resultsDir: caseResultsDir,
      });
      const cost = agent.totalCostUsd !== undefined ? ` $${agent.totalCostUsd.toFixed(4)}` : "";
      const turns = agent.numTurns !== undefined ? ` ${agent.numTurns} turns` : "";
      console.log(`  [agent] ${agent.status} in ${formatDuration(agent.durationMs)}${turns}${cost}`);
      if (agent.errorDetail) console.log(`  [agent] ${agent.errorDetail}`);
    }

    const checks = await runChecks(evalCase.checks, {
      workspace,
      skipLive: options.skipLive,
    });
    const agentOk = agent.status === "completed" || agent.status === "dry_run";
    const passed = agentOk && checks.every((check) => check.status !== "fail");
    const caseResult: CaseResult = {
      case: evalCase.name,
      workspace: workspace.path,
      startedAt,
      dryRun: options.dryRun,
      agent,
      checks,
      passed,
    };
    writeFileSync(join(caseResultsDir, "result.json"), `${JSON.stringify(caseResult, null, 2)}\n`);
    results.push(caseResult);

    if (!options.keepWorkspaces) rmSync(workspace.path, { recursive: true, force: true });
  }

  writeFileSync(join(runResultsDir, "summary.json"), `${JSON.stringify(results, null, 2)}\n`);
  printSummary(results, options);
  console.log(`\nresults: ${runResultsDir}`);
  const failed = results.filter((result) => !result.passed);
  // In --dry-run, grader failures against the untouched scaffold are expected
  // (they prove the graders detect a missing solution) — exit 0.
  process.exit(failed.length > 0 && !options.dryRun ? 1 : 0);
}

function parseArgs(argv: string[]): RunnerOptions {
  const evalsRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const repoRoot = resolve(evalsRoot, "..");
  const options: RunnerOptions = {
    repoRoot,
    evalsRoot,
    caseNames: [],
    model: process.env.ZN_EVAL_MODEL ?? DEFAULT_MODEL,
    dryRun: false,
    skipLive: false,
    skipPermissions: false,
    keepWorkspaces: false,
  };
  let listOnly = false;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]!;
    switch (arg) {
      case "--help":
      case "-h":
        console.log(USAGE);
        process.exit(0);
        break;
      case "--list":
        listOnly = true;
        break;
      case "--dry-run":
        options.dryRun = true;
        break;
      case "--skip-live":
        options.skipLive = true;
        break;
      case "--skip-permissions":
        options.skipPermissions = true;
        break;
      case "--keep-workspaces":
        options.keepWorkspaces = true;
        break;
      case "--model": {
        const value = argv[index + 1];
        if (!value) {
          console.error("--model requires a value");
          process.exit(2);
        }
        options.model = value;
        index += 1;
        break;
      }
      default:
        if (arg.startsWith("-")) {
          console.error(`unknown option: ${arg}\n\n${USAGE}`);
          process.exit(2);
        }
        options.caseNames.push(arg);
    }
  }
  if (listOnly) {
    for (const name of discoverCaseNames(options.evalsRoot)) console.log(name);
    process.exit(0);
  }
  return options;
}

function discoverCaseNames(evalsRoot: string): string[] {
  const casesDir = join(evalsRoot, "cases");
  return readdirSync(casesDir)
    .filter((entry) => existsSync(join(casesDir, entry, "eval.json")))
    .sort();
}

function loadCases(options: RunnerOptions): EvalCase[] {
  const names = options.caseNames.length > 0 ? options.caseNames : discoverCaseNames(options.evalsRoot);
  return names.map((name) => {
    const path = join(options.evalsRoot, "cases", name, "eval.json");
    if (!existsSync(path)) {
      console.error(`unknown case: ${name} (no ${path})`);
      process.exit(2);
    }
    const parsed = JSON.parse(readFileSync(path, "utf8")) as EvalCase;
    validateCase(parsed, name, path);
    return parsed;
  });
}

function validateCase(evalCase: EvalCase, name: string, path: string): void {
  const problems: string[] = [];
  if (evalCase.name !== name) problems.push(`name "${evalCase.name}" != directory "${name}"`);
  if (typeof evalCase.prompt !== "string" || evalCase.prompt.length < 20) problems.push("prompt missing/too short");
  if (evalCase.frontend !== "native") problems.push(`unsupported frontend "${evalCase.frontend}"`);
  if (!Number.isFinite(evalCase.timeoutMs) || evalCase.timeoutMs <= 0) problems.push("timeoutMs must be positive");
  if (!Number.isInteger(evalCase.maxTurns) || evalCase.maxTurns <= 0) problems.push("maxTurns must be a positive integer");
  if (!Array.isArray(evalCase.checks) || evalCase.checks.length === 0) problems.push("checks must be non-empty");
  if (problems.length > 0) {
    console.error(`invalid case config ${path}:\n  ${problems.join("\n  ")}`);
    process.exit(2);
  }
}

function printSummary(results: CaseResult[], options: RunnerOptions): void {
  console.log(`\n=== summary (model: ${options.model}${options.dryRun ? ", DRY RUN" : ""}) ===`);
  const rows = results.map((result) => {
    const checkSummary = result.checks
      .map((check) => (check.status === "pass" ? "P" : check.status === "skipped" ? "s" : "F"))
      .join("");
    return {
      case: result.case,
      result: result.passed ? "PASS" : "FAIL",
      checks: checkSummary,
      turns: result.agent.numTurns?.toString() ?? "-",
      cost: result.agent.totalCostUsd !== undefined ? `$${result.agent.totalCostUsd.toFixed(4)}` : "-",
      time: formatDuration(result.agent.durationMs + result.checks.reduce((sum, check) => sum + check.durationMs, 0)),
    };
  });
  const columns = ["case", "result", "checks", "turns", "cost", "time"] as const;
  const widths = columns.map((column) =>
    Math.max(column.length, ...rows.map((row) => row[column].length)),
  );
  const line = (cells: string[]): string =>
    cells.map((cell, index) => cell.padEnd(widths[index]!)).join("  ");
  console.log(line([...columns]));
  console.log(line(widths.map((width) => "-".repeat(width))));
  for (const row of rows) console.log(line(columns.map((column) => row[column])));
}

function formatArgv(argv: string[]): string {
  return argv
    .map((arg) => (/[\s"']/.test(arg) ? JSON.stringify(arg.length > 120 ? `${arg.slice(0, 120)}...` : arg) : arg))
    .join(" ");
}

main().catch((error) => {
  console.error(error instanceof Error ? error.stack ?? error.message : error);
  process.exit(1);
});
