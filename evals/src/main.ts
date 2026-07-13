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
import { analyzeTranscript, metricsTrackFor } from "./efficiency.ts";
import { computeMarkupShare, formatMarkupShare } from "./markup-share.ts";
import { buildCli, prewarmTsCoreWorkspace, prewarmWorkspace, scaffoldWorkspace } from "./scaffold.ts";
import { DEFAULT_JUDGE_MODEL } from "./judge.ts";
import { ensureSandboxAuth, packRepo, runCaseInSandbox } from "./sandbox.ts";
import { runChecks } from "./grade.ts";
import { formatDuration } from "./util.ts";
import type {
  AgentRunResult,
  CaseAggregate,
  CaseResult,
  CheckAggregate,
  EvalCase,
  RunnableCase,
  RunnerOptions,
  Track,
} from "./types.ts";

const USAGE = `usage: pnpm eval [options] [case ...]

Runs Claude Code headless (claude -p) through the Vercel AI Gateway against a
freshly scaffolded native-sdk workspace, then grades the result.

options:
  --list               list available cases and exit
  --dry-run            everything except the model call: scaffold, deliver the
                       skill, print the env assembly + claude argv, then run
                       the graders against the workspace as-scaffolded; with
                       --sandbox this provisions real microVMs and exercises
                       the whole sandbox path (needs sandbox auth, no
                       gateway key)
  --skip-live          skip snapshot_grep checks (no app launch)
  --skip-permissions   run claude with --dangerously-skip-permissions instead
                       of acceptEdits + an allowlist (sandbox dirs only)
  --keep-workspaces    do not delete .workspaces/<case> after grading
  --trials <n>         run each case n times (each trial fully independent:
                       own workspace, agent run, checks, judge) and report
                       per-case pass rates; default 1
  --concurrency <n>    run up to n case trials in parallel (default: 2 locally,
                       4 with --sandbox)
  --sandbox            run each case in its own Vercel Sandbox microVM booted
                       from the pre-baked image (see evals/sandbox/); needs
                       VERCEL_OIDC_TOKEN via vercel link + env pull, or
                       VERCEL_TOKEN + VERCEL_TEAM_ID + VERCEL_PROJECT_ID
  --sandbox-vcpus <n>  vCPUs per sandbox (default 4; 2048 MB RAM per vCPU)
  --sandbox-image <r>  registry reference for the sandbox image (default:
                       eval-sandbox — the linked project's repository,
                       latest tag)
  --lane <lane>        grading lane: macos-local (default) or linux-sandbox
                       (what --sandbox passes to the harness run inside the
                       microVM; rarely set by hand)
  --track <ts|zig>     app-dual cases only: run just the named authoring
                       track (default: both tracks, as <case>@ts and
                       <case>@zig). Non-dual cases ignore the filter.
  --model <slug>       coder model slug (default: ${DEFAULT_MODEL};
                       also via ZN_EVAL_MODEL)
  --judge-model <slug> judge model slug for llm_judge checks (default:
                       ${DEFAULT_JUDGE_MODEL}; also via ZN_EVAL_JUDGE_MODEL)

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

  const runStamp = new Date().toISOString().replace(/[:.]/g, "-");
  const runResultsDir = join(options.evalsRoot, "results", runStamp);
  const workspacesDir = join(options.evalsRoot, ".workspaces");
  mkdirSync(runResultsDir, { recursive: true });

  let cliPath: string | undefined;
  let tarballPath: string | undefined;
  if (options.sandbox) {
    ensureSandboxAuth(options.evalsRoot);
    console.log("[sandbox] packing repo working tree for upload...");
    tarballPath = await packRepo(options.repoRoot);
  } else {
    cliPath = await buildCli(options.repoRoot);
  }

  // app-dual cases expand into one runnable per selected track (<case>@ts,
  // <case>@zig); everything else is one runnable. With --trials n each
  // runnable becomes n fully independent trial tasks (own workspace, own
  // agent run, own checks + judge) that share the concurrency pool with
  // everything else. trials=1 keeps today's layout exactly.
  const runnables = cases.flatMap((evalCase) => expandTracks(evalCase, options.track));
  const trials = options.trials;
  const tasks = runnables.flatMap((runnable) =>
    Array.from({ length: trials }, (_, index) => ({ runnable, trial: index + 1 })),
  );
  // Sandbox default stays bounded: each case is its own microVM, but plans
  // rate-limit vCPU allocation (Hobby: 40 vCPUs per 10 minutes), so at the
  // default 4 vCPUs a wave of 4 sandboxes fits comfortably under the limit.
  const concurrency = Math.max(
    1,
    Math.min(options.concurrency ?? (options.sandbox ? 4 : 2), tasks.length),
  );
  if (tasks.length > 1) {
    const trialNote = trials > 1 ? ` x ${trials} trials` : "";
    console.log(
      `running ${runnables.length} case run${runnables.length > 1 ? "s" : ""}${trialNote} (${tasks.length} total), ${concurrency} at a time${options.sandbox ? " (vercel sandbox)" : ""}`,
    );
  }
  const trialResults = await runPool(tasks, concurrency, async ({ runnable, trial }) => {
    const { evalCase } = runnable;
    const label = trials > 1 ? `${runnable.label}#${trial}` : runnable.label;
    const log = (line: string): void => console.log(`[${label}] ${line}`);
    const caseResultsDir =
      trials > 1
        ? join(runResultsDir, runnable.label, `trial-${trial}`)
        : join(runResultsDir, runnable.label);
    // Trials of the same case can run concurrently: each needs its own
    // workspace directory or the scaffolds would clobber each other. The
    // "@track" label becomes "-track" here: the workspace name feeds
    // `native init` (module name, bundle id), which wants plain words.
    const workspaceBase = runnable.label.replace("@", "-");
    const workspaceName = trials > 1 ? `${workspaceBase}-trial-${trial}` : workspaceBase;
    mkdirSync(caseResultsDir, { recursive: true });
    try {
      let result: CaseResult;
      if (options.sandbox) {
        result = await runCaseInSandbox({
          evalCase,
          track: runnable.track,
          label: runnable.label,
          tarballPath: tarballPath!,
          gatewayKey,
          model: options.model,
          judgeModel: options.judgeModel,
          vcpus: options.sandboxVcpus,
          image: options.sandboxImage,
          dryRun: options.dryRun,
          localResultsDir: caseResultsDir,
          log,
        });
      } else {
        result = await runCaseLocal(runnable, options, {
          cliPath: cliPath!,
          workspacesDir,
          workspaceName,
          caseResultsDir,
          gatewayKey,
          log,
        });
      }
      if (trials > 1) {
        result.trial = trial;
        // The local runner already wrote result.json before we stamped the
        // trial number; rewrite so the on-disk file carries it too.
        writeFileSync(join(caseResultsDir, "result.json"), `${JSON.stringify(result, null, 2)}\n`);
      }
      return result;
    } catch (error) {
      // One crashed trial (sandbox provisioning, scaffold failure, ...) should
      // not kill the rest of the suite.
      log(`FAILED: ${(error as Error).message}`);
      const result: CaseResult = {
        case: evalCase.name,
        lane: options.sandbox ? "linux-sandbox" : options.lane,
        workspace: "-",
        startedAt: new Date().toISOString(),
        dryRun: options.dryRun,
        agent: {
          status: "error" as const,
          model: options.model,
          durationMs: 0,
          errorDetail: (error as Error).message,
        },
        checks: [],
        passed: false,
      };
      if (runnable.track) result.track = runnable.track;
      if (trials > 1) result.trial = trial;
      return result;
    }
  });

  if (tarballPath) rmSync(tarballPath, { force: true });
  let anyFailed: boolean;
  if (trials === 1) {
    writeFileSync(join(runResultsDir, "summary.json"), `${JSON.stringify(trialResults, null, 2)}\n`);
    printSummary(trialResults, options);
    anyFailed = trialResults.some((result) => !result.passed);
  } else {
    const aggregates = runnables.map((runnable, index) =>
      aggregateCase(
        runnable,
        trialResults.slice(index * trials, (index + 1) * trials),
      ),
    );
    for (const aggregate of aggregates) {
      writeFileSync(
        join(runResultsDir, aggregate.case, "aggregate.json"),
        `${JSON.stringify(aggregate, null, 2)}\n`,
      );
    }
    writeFileSync(join(runResultsDir, "summary.json"), `${JSON.stringify(aggregates, null, 2)}\n`);
    printTrialSummary(aggregates, options);
    anyFailed = aggregates.some((aggregate) => aggregate.passedTrials < aggregate.trials);
  }
  console.log(`\nresults: ${runResultsDir}`);
  // In --dry-run, grader failures against the untouched scaffold are expected
  // (they prove the graders detect a missing solution) — exit 0.
  process.exit(anyFailed && !options.dryRun ? 1 : 0);
}

interface LocalCaseContext {
  cliPath: string;
  workspacesDir: string;
  /** Workspace directory name under .workspaces/ (per-trial when trials > 1). */
  workspaceName: string;
  caseResultsDir: string;
  gatewayKey: string | undefined;
  log: (line: string) => void;
}

async function runCaseLocal(
  runnable: RunnableCase,
  options: RunnerOptions,
  context: LocalCaseContext,
): Promise<CaseResult> {
  const { evalCase, track } = runnable;
  const { log } = context;
  const startedAt = new Date().toISOString();

  const caseDir = join(options.evalsRoot, "cases", evalCase.name);
  const workspace = await scaffoldWorkspace(
    options.repoRoot,
    context.cliPath,
    context.workspacesDir,
    context.workspaceName,
    evalCase.frontend,
    caseDir,
    track,
  );
  const skillNames =
    evalCase.frontend === "ts-core"
      ? ["ts-app-core"]
      : evalCase.frontend === "app-dual"
        ? track === "ts"
          ? ["ts-app-core", "native-ui"]
          : ["native-ui", "zig"]
        : ["native-ui", "zig"];
  log(`[scaffold] workspace ready: ${workspace.path}`);
  log(`[scaffold] skills delivered: ${skillNames.map((name) => `.claude/skills/${name}/SKILL.md`).join(", ")}`);
  if (!options.dryRun) {
    if (evalCase.frontend === "ts-core") {
      await prewarmTsCoreWorkspace(options.repoRoot, workspace, log);
    } else if (evalCase.frontend === "app-dual" && track === "ts") {
      // The ts track's graders hit two graphs: the app's own zero-config
      // build (`native test`) and the transpile + `zig test` harness path.
      // Warm both so neither bills agent wall-clock.
      await prewarmWorkspace(workspace, log);
      await prewarmTsCoreWorkspace(options.repoRoot, workspace, log);
    } else {
      await prewarmWorkspace(workspace, log);
    }
  }

  const configDir = join(context.caseResultsDir, "claude-config");
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
    const agentEnv = assembleAgentEnv(context.gatewayKey ?? "<AI_GATEWAY_API_KEY>", options.repoRoot, configDir, workspace.path);
    log("[dry-run] env overrides for the claude subprocess:");
    for (const [key, value] of Object.entries(agentEnv.redacted)) {
      log(`  ${key}=${value}`);
    }
    log(`[dry-run] claude ${formatArgv(invocation.argv)}`);
    log(`[dry-run] cwd: ${invocation.cwd}`);
    agent = { status: "dry_run", model: options.model, durationMs: 0 };
  } else {
    const agentEnv = assembleAgentEnv(context.gatewayKey!, options.repoRoot, configDir, workspace.path);
    log(`[agent] claude -p (model ${options.model}, max ${evalCase.maxTurns} turns, timeout ${formatDuration(evalCase.timeoutMs)})...`);
    agent = await runAgent({
      invocation,
      agentEnv,
      model: options.model,
      timeoutMs: evalCase.timeoutMs,
      resultsDir: context.caseResultsDir,
    });
    const cost = agent.totalCostUsd !== undefined ? ` $${agent.totalCostUsd.toFixed(4)}` : "";
    const turns = agent.numTurns !== undefined ? ` ${agent.numTurns} turns` : "";
    log(`[agent] ${agent.status} in ${formatDuration(agent.durationMs)}${turns}${cost}`);
    if (agent.errorDetail) log(`[agent] ${agent.errorDetail}`);
  }

  // Telemetry, never a gate: how much of the delivered view is markup vs
  // builder calls. In --dry-run this measures the untouched scaffold.
  const markupShare = computeMarkupShare(workspace.path);
  log(`[markup] ${formatMarkupShare(markupShare)}`);

  // Efficiency read from the transcript: turns-to-first-green is the
  // agent-verification proxy (first green agent-run check after the first
  // source edit — the graders only run once, below), and the post-green tail
  // is the turns burned after that. Full epistemics in efficiency.ts.
  const analysis =
    agent.transcriptPath !== undefined
      ? analyzeTranscript(agent.transcriptPath, metricsTrackFor(evalCase.frontend, track))
      : null;
  if (analysis) {
    const { efficiency } = analysis;
    log(
      efficiency.firstGreenTurn !== null
        ? `[efficiency] agent-verified green at turn ${efficiency.firstGreenTurn}/${efficiency.observedTurns} (${formatDuration(efficiency.firstGreenMs ?? 0)}); ${efficiency.turnsAfterGreen} turns after green`
        : `[efficiency] agent verification never went green (${efficiency.verificationRuns} runs after editing)`,
    );
  }

  const checks = await runChecks(runnable.checks, {
    workspace,
    repoRoot: options.repoRoot,
    caseDir,
    log,
    skipLive: options.skipLive,
    dryRun: options.dryRun,
    agentErrored: agent.status === "error",
    lane: options.lane,
    artifactsDir: context.caseResultsDir,
    taskPrompt: evalCase.prompt,
    judgeModel: options.judgeModel,
    gatewayKey: context.gatewayKey,
  });
  // "capped" (hit --max-turns) grades like completion: the checks decide,
  // and the cap rides result.json as cost (agent.cappedAtTurns, turns).
  const agentOk = agent.status === "completed" || agent.status === "dry_run" || agent.status === "capped";
  // Advisory judge checks record a score but never fail the case.
  const passed =
    agentOk && checks.every((check) => check.status !== "fail" || check.advisory === true);
  const caseResult: CaseResult = {
    case: evalCase.name,
    lane: options.lane,
    workspace: workspace.path,
    startedAt,
    dryRun: options.dryRun,
    agent,
    markupShare,
    checks,
    passed,
  };
  if (analysis) caseResult.efficiency = analysis.efficiency;
  if (track) caseResult.track = track;
  writeFileSync(join(context.caseResultsDir, "result.json"), `${JSON.stringify(caseResult, null, 2)}\n`);
  if (!options.keepWorkspaces) rmSync(workspace.path, { recursive: true, force: true });
  return caseResult;
}

/**
 * Expand a case into its runnable track runs. app-dual cases produce one
 * runnable per selected track — the SAME spec (prompt, timeouts, shared
 * checks), plus the track's thin check additions — labeled `<case>@<track>`.
 * Everything else runs exactly as before, unlabeled.
 */
function expandTracks(evalCase: EvalCase, filter: Track | undefined): RunnableCase[] {
  if (evalCase.frontend !== "app-dual") {
    return [{ evalCase, label: evalCase.name, checks: evalCase.checks }];
  }
  const tracks: Track[] = filter ? [filter] : ["ts", "zig"];
  return tracks.map((track) => ({
    evalCase,
    track,
    label: `${evalCase.name}@${track}`,
    checks: [...evalCase.checks, ...(evalCase.tracks?.[track]?.checks ?? [])],
  }));
}

/** Run `worker` over `items` with at most `limit` in flight; results keep item order. */
async function runPool<T, R>(
  items: T[],
  limit: number,
  worker: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const lanes = Array.from({ length: limit }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await worker(items[index]!);
    }
  });
  await Promise.all(lanes);
  return results;
}

function parseArgs(argv: string[]): RunnerOptions {
  const evalsRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const repoRoot = resolve(evalsRoot, "..");
  const options: RunnerOptions = {
    repoRoot,
    evalsRoot,
    caseNames: [],
    track: undefined,
    model: process.env.NATIVE_SDK_EVAL_MODEL ?? process.env.ZN_EVAL_MODEL ?? DEFAULT_MODEL,
    judgeModel: process.env.NATIVE_SDK_EVAL_JUDGE_MODEL ?? process.env.ZN_EVAL_JUDGE_MODEL ?? DEFAULT_JUDGE_MODEL,
    dryRun: false,
    skipLive: false,
    skipPermissions: false,
    keepWorkspaces: false,
    trials: 1,
    concurrency: undefined,
    sandbox: false,
    sandboxVcpus: 4,
    sandboxImage: "eval-sandbox",
    lane: "macos-local",
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
      case "--judge-model": {
        const value = argv[index + 1];
        if (!value) {
          console.error("--judge-model requires a value");
          process.exit(2);
        }
        options.judgeModel = value;
        index += 1;
        break;
      }
      case "--sandbox":
        options.sandbox = true;
        break;
      case "--sandbox-image": {
        const value = argv[index + 1];
        if (!value) {
          console.error("--sandbox-image requires a value");
          process.exit(2);
        }
        options.sandboxImage = value;
        index += 1;
        break;
      }
      case "--lane": {
        const value = argv[index + 1];
        if (value !== "macos-local" && value !== "linux-sandbox") {
          console.error("--lane must be macos-local or linux-sandbox");
          process.exit(2);
        }
        options.lane = value;
        index += 1;
        break;
      }
      case "--track": {
        const value = argv[index + 1];
        if (value !== "ts" && value !== "zig") {
          console.error("--track must be ts or zig");
          process.exit(2);
        }
        options.track = value;
        index += 1;
        break;
      }
      case "--trials":
      case "--concurrency":
      case "--sandbox-vcpus": {
        const value = Number(argv[index + 1]);
        if (!Number.isInteger(value) || value <= 0) {
          console.error(`${arg} requires a positive integer`);
          process.exit(2);
        }
        if (arg === "--trials") options.trials = value;
        else if (arg === "--concurrency") options.concurrency = value;
        else options.sandboxVcpus = value;
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
  if (evalCase.frontend !== "native" && evalCase.frontend !== "ts-core" && evalCase.frontend !== "app-dual") problems.push(`unsupported frontend "${evalCase.frontend}"`);
  if (evalCase.frontend === "app-dual" && (!evalCase.tracks?.ts || !evalCase.tracks.zig)) problems.push("app-dual cases need tracks.ts and tracks.zig");
  if (evalCase.frontend !== "app-dual" && evalCase.tracks) problems.push("tracks is only valid on app-dual cases");
  if (!Number.isFinite(evalCase.timeoutMs) || evalCase.timeoutMs <= 0) problems.push("timeoutMs must be positive");
  if (!Number.isInteger(evalCase.maxTurns) || evalCase.maxTurns <= 0) problems.push("maxTurns must be a positive integer");
  if (!Array.isArray(evalCase.checks) || evalCase.checks.length === 0) problems.push("checks must be non-empty");
  if (problems.length > 0) {
    console.error(`invalid case config ${path}:\n  ${problems.join("\n  ")}`);
    process.exit(2);
  }
}

/**
 * Fold one case's independent trials into pass rates: per-trial pass/fail,
 * per-check pass counts (keyed by check type + description, so a crashed
 * trial with no checks simply contributes to no counters), and mean judge
 * score across every recorded llm_judge overall.
 */
function aggregateCase(runnable: RunnableCase, results: CaseResult[]): CaseAggregate {
  const checkOrder: string[] = [];
  const checkStats = new Map<string, CheckAggregate>();
  const judgeScores: number[] = [];
  const markupShares: number[] = [];
  const turns: number[] = [];
  const firstGreenTurns: number[] = [];
  const turnsAfterGreen: number[] = [];
  let totalCostUsd: number | undefined;
  let totalInputTokens: number | undefined;
  let totalOutputTokens: number | undefined;
  let totalCacheReadTokens: number | undefined;
  let totalDurationMs = 0;
  for (const result of results) {
    for (const check of result.checks) {
      const key = `${check.type} ${check.description}`;
      let stat = checkStats.get(key);
      if (!stat) {
        stat = { type: check.type, description: check.description, pass: 0, fail: 0, skipped: 0 };
        checkStats.set(key, stat);
        checkOrder.push(key);
      }
      if (check.status === "pass") stat.pass += 1;
      else if (check.status === "fail") stat.fail += 1;
      else stat.skipped += 1;
      if (check.type === "llm_judge" && check.score !== undefined) judgeScores.push(check.score);
      totalDurationMs += check.durationMs;
    }
    if (result.markupShare?.share != null) markupShares.push(result.markupShare.share);
    if (result.agent.numTurns !== undefined) turns.push(result.agent.numTurns);
    if (result.efficiency?.firstGreenTurn != null) firstGreenTurns.push(result.efficiency.firstGreenTurn);
    if (result.efficiency?.turnsAfterGreen != null) turnsAfterGreen.push(result.efficiency.turnsAfterGreen);
    if (result.agent.totalCostUsd !== undefined) {
      totalCostUsd = (totalCostUsd ?? 0) + result.agent.totalCostUsd;
    }
    if (result.agent.inputTokens !== undefined) totalInputTokens = (totalInputTokens ?? 0) + result.agent.inputTokens;
    if (result.agent.outputTokens !== undefined) totalOutputTokens = (totalOutputTokens ?? 0) + result.agent.outputTokens;
    if (result.agent.cacheReadTokens !== undefined) totalCacheReadTokens = (totalCacheReadTokens ?? 0) + result.agent.cacheReadTokens;
    totalDurationMs += result.agent.durationMs;
  }
  // Per-check mean judge score, from every trial that recorded one.
  for (const key of checkOrder) {
    const stat = checkStats.get(key)!;
    if (stat.type !== "llm_judge") continue;
    const scores = results.flatMap((result) =>
      result.checks
        .filter(
          (check) =>
            check.type === stat.type &&
            check.description === stat.description &&
            check.score !== undefined,
        )
        .map((check) => check.score!),
    );
    if (scores.length > 0) stat.meanScore = mean(scores);
  }
  const aggregate: CaseAggregate = {
    case: runnable.label,
    trials: results.length,
    passedTrials: results.filter((result) => result.passed).length,
    checks: checkOrder.map((key) => checkStats.get(key)!),
    totalDurationMs,
    results,
  };
  if (runnable.track) aggregate.track = runnable.track;
  const cappedTrials = results.filter((result) => result.agent.cappedAtTurns === true).length;
  if (cappedTrials > 0) aggregate.cappedTrials = cappedTrials;
  if (judgeScores.length > 0) aggregate.meanJudgeScore = mean(judgeScores);
  if (markupShares.length > 0) aggregate.meanMarkupShare = mean(markupShares);
  if (turns.length > 0) aggregate.meanTurns = mean(turns);
  if (firstGreenTurns.length > 0) aggregate.meanFirstGreenTurn = mean(firstGreenTurns);
  if (turnsAfterGreen.length > 0) aggregate.meanTurnsAfterGreen = mean(turnsAfterGreen);
  if (totalCostUsd !== undefined) aggregate.totalCostUsd = totalCostUsd;
  if (totalInputTokens !== undefined) aggregate.totalInputTokens = totalInputTokens;
  if (totalOutputTokens !== undefined) aggregate.totalOutputTokens = totalOutputTokens;
  if (totalCacheReadTokens !== undefined) aggregate.totalCacheReadTokens = totalCacheReadTokens;
  return aggregate;
}

function mean(values: number[]): number {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

/** Summary for --trials > 1: pass-rate column plus per-check pass counts. */
function printTrialSummary(aggregates: CaseAggregate[], options: RunnerOptions): void {
  console.log(
    `\n=== summary (coder: ${options.model}, judge: ${options.judgeModel}, trials: ${options.trials}${options.dryRun ? ", DRY RUN" : ""}) ===`,
  );
  const rows = aggregates.map((aggregate) => ({
    case: aggregate.case,
    lane: aggregate.results[0]?.lane ?? options.lane,
    "pass rate": `${aggregate.passedTrials}/${aggregate.trials}`,
    checks: aggregate.checks
      .map((check) =>
        check.pass + check.fail === 0 ? "s" : `${check.pass}/${check.pass + check.fail}`,
      )
      .join(" "),
    judge:
      aggregate.meanJudgeScore !== undefined ? `${aggregate.meanJudgeScore.toFixed(1)}/10` : "-",
    markup:
      aggregate.meanMarkupShare !== undefined ? aggregate.meanMarkupShare.toFixed(2) : "-",
    turns: aggregate.meanTurns !== undefined ? aggregate.meanTurns.toFixed(1) : "-",
    // Agent-verification proxy (see EfficiencyMetrics): mean first-green turn
    // and mean post-green tail across the trials that went green.
    "green@": aggregate.meanFirstGreenTurn !== undefined ? aggregate.meanFirstGreenTurn.toFixed(1) : "-",
    tail: aggregate.meanTurnsAfterGreen !== undefined ? aggregate.meanTurnsAfterGreen.toFixed(1) : "-",
    cost: aggregate.totalCostUsd !== undefined ? `$${aggregate.totalCostUsd.toFixed(4)}` : "-",
    time: formatDuration(aggregate.totalDurationMs),
  }));
  const columns = ["case", "lane", "pass rate", "checks", "judge", "markup", "turns", "green@", "tail", "cost", "time"] as const;
  const widths = columns.map((column) =>
    Math.max(column.length, ...rows.map((row) => row[column].length)),
  );
  const line = (cells: string[]): string =>
    cells.map((cell, index) => cell.padEnd(widths[index]!)).join("  ");
  console.log(line([...columns]));
  console.log(line(widths.map((width) => "-".repeat(width))));
  for (const row of rows) console.log(line(columns.map((column) => row[column])));
  console.log("\nper-check pass counts (pass/graded; s = skipped in every trial):");
  for (const aggregate of aggregates) {
    console.log(`  ${aggregate.case} (${aggregate.passedTrials}/${aggregate.trials} trials passed)`);
    for (const check of aggregate.checks) {
      const rate =
        check.pass + check.fail === 0
          ? `s(${check.skipped})`
          : `${check.pass}/${check.pass + check.fail}`;
      const judgeNote = check.meanScore !== undefined ? ` — mean ${check.meanScore.toFixed(1)}/10` : "";
      console.log(`    ${rate.padStart(6)}  ${check.description}${judgeNote}`);
    }
  }
}

function printSummary(results: CaseResult[], options: RunnerOptions): void {
  console.log(
    `\n=== summary (coder: ${options.model}, judge: ${options.judgeModel}${options.dryRun ? ", DRY RUN" : ""}) ===`,
  );
  const rows = results.map((result) => {
    const checkSummary = result.checks
      .map((check) => (check.status === "pass" ? "P" : check.status === "skipped" ? "s" : "F"))
      .join("");
    const judgeScores = result.checks
      .filter((check) => check.type === "llm_judge" && check.score !== undefined)
      .map((check) => `${check.score!.toFixed(1)}/10`);
    return {
      case: result.track ? `${result.case}@${result.track}` : result.case,
      lane: result.lane ?? options.lane,
      result: result.passed ? "PASS" : "FAIL",
      checks: checkSummary,
      judge: judgeScores.join(" ") || "-",
      markup: result.markupShare?.share != null ? result.markupShare.share.toFixed(2) : "-",
      turns: result.agent.numTurns?.toString() ?? "-",
      // Agent-verification proxy (see EfficiencyMetrics): first-green turn
      // and the post-green tail.
      "green@": result.efficiency?.firstGreenTurn != null ? String(result.efficiency.firstGreenTurn) : "-",
      tail: result.efficiency?.turnsAfterGreen != null ? String(result.efficiency.turnsAfterGreen) : "-",
      cost: result.agent.totalCostUsd !== undefined ? `$${result.agent.totalCostUsd.toFixed(4)}` : "-",
      time: formatDuration(result.agent.durationMs + result.checks.reduce((sum, check) => sum + check.durationMs, 0)),
    };
  });
  const columns = ["case", "lane", "result", "checks", "judge", "markup", "turns", "green@", "tail", "cost", "time"] as const;
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
