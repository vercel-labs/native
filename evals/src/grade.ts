import { spawn } from "node:child_process";
import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { exec, resolveFiles, tailLines } from "./util.ts";
import { judgeWorkspace } from "./judge.ts";
import type { CheckResult, CheckSpec, Lane, LlmJudgeCheck, SnapshotGrepCheck, TsHarnessCheck, TsTranspileCheck, ZigHarnessCheck } from "./types.ts";
import type { Workspace } from "./scaffold.ts";

export interface GradeContext {
  workspace: Workspace;
  /** SDK repo root (the @native-sdk/core transpiler and rt kernel live here). */
  repoRoot: string;
  /** The case directory (cases/<name>): ts_harness reads harness.zig from it. */
  caseDir: string;
  /** Per-case logger (prefixes the case name when cases run in parallel). */
  log: (line: string) => void;
  /** Skip live snapshot checks (report "skipped"). */
  skipLive: boolean;
  /** Dry runs make no model calls; llm_judge checks report "skipped". */
  dryRun: boolean;
  /** The agent step errored before producing work: llm_judge skips instead of spending judge tokens grading the untouched scaffold. */
  agentErrored?: boolean | undefined;
  /** Grading lane: decides live-check build flags and lane-scoped skips. */
  lane: Lane;
  /**
   * Where grading artifacts (live screenshots) are written. On the
   * linux-sandbox lane this is the case results dir, which the outer runner
   * pulls back before the microVM is destroyed.
   */
  artifactsDir?: string | undefined;
  /** The case's task prompt, shown to the judge alongside the code. */
  taskPrompt: string;
  judgeModel: string;
  gatewayKey?: string | undefined;
}

export async function runChecks(
  checks: CheckSpec[],
  context: GradeContext,
): Promise<CheckResult[]> {
  const results: CheckResult[] = [];
  for (const check of checks) {
    const started = Date.now();
    const result = await runCheck(check, context);
    results.push({ ...result, durationMs: Date.now() - started });
    const marker = result.status === "pass" ? "PASS" : result.status === "skipped" ? "SKIP" : "FAIL";
    context.log(`[check] ${marker} ${result.description}`);
    if (result.detail && (result.status === "fail" || result.type === "llm_judge")) {
      context.log(indent(result.detail, "        | "));
    }
  }
  return results;
}

type PendingResult = Omit<CheckResult, "durationMs">;

/** The check's summary-table description without running it (for lane skips). */
function checkDescription(check: CheckSpec): string {
  switch (check.type) {
    case "build_test":
      return `native test${check.args?.length ? ` ${check.args.join(" ")}` : ""}`;
    case "markup_check":
      return "native markup check src/*.native";
    case "file_grep":
      return check.description;
    case "snapshot_grep":
      return `snapshot: ${check.description}`;
    case "ts_transpile":
      return `@native-sdk/core transpile ${check.entry ?? "src/core.ts"}`;
    case "ts_harness":
      return `harness: ${check.description}`;
    case "zig_harness":
      return `harness: ${check.description}`;
    case "llm_judge":
      return `judge${(check.advisory ?? true) ? " (advisory)" : ""}: ${check.description}`;
  }
}

async function runCheck(check: CheckSpec, context: GradeContext): Promise<PendingResult> {
  // Lane-scoped checks skip (never fail) on lanes they do not grade: a
  // surface that exists on only one OS is an annotation, not a failure.
  if (check.lanes && !check.lanes.includes(context.lane)) {
    return {
      type: check.type,
      description: checkDescription(check),
      status: "skipped",
      detail: `not graded on the ${context.lane} lane (lanes: ${check.lanes.join(", ")})`,
    };
  }
  switch (check.type) {
    case "build_test":
      return buildTest(check.args ?? [], context);
    case "markup_check":
      return markupCheck(context);
    case "file_grep":
      return fileGrep(check.files, check.pattern, check.expect, check.description, context);
    case "snapshot_grep":
      return snapshotGrep(check, context);
    case "ts_transpile":
      return tsTranspile(check, context);
    case "ts_harness":
      return tsHarness(check, context);
    case "zig_harness":
      return zigHarness(check, context);
    case "llm_judge":
      return llmJudge(check, context);
  }
}

/** Path to the @native-sdk/core transpiler CLI inside the SDK repo. */
function transpilerCli(repoRoot: string): string {
  return join(repoRoot, "packages", "core", "src", "cli.ts");
}

/**
 * Compliance grading for ts-core cases: the core module must typecheck (tsc
 * semantics), pass every subset rule, and emit Zig. Failing diagnostics stay
 * in the detail — the NS rule IDs there are the violation taxonomy.
 */
async function tsTranspile(check: TsTranspileCheck, context: GradeContext): Promise<PendingResult> {
  const entry = check.entry ?? "src/core.ts";
  const description = `@native-sdk/core transpile ${entry}`;
  const entryPath = join(context.workspace.path, entry);
  if (!existsSync(entryPath)) {
    return { type: "ts_transpile", description, status: "fail", detail: `${entry} not found in the workspace` };
  }
  const result = await exec("node", [transpilerCli(context.repoRoot), entryPath, "-o", "/dev/null"], {
    cwd: context.workspace.path,
    timeoutMs: 2 * 60 * 1000,
  });
  if (result.code === 0) return { type: "ts_transpile", description, status: "pass" };
  return {
    type: "ts_transpile",
    description,
    status: "fail",
    detail: result.timedOut ? "timed out" : tailLines(result),
  };
}

/**
 * Behavioral grading for ts-core cases: transpile the core, assemble a
 * scratch dir with the emitted core.zig, the rt kernel, and the case's
 * harness.zig, then `zig test harness.zig`. The harness drives the real
 * dispatch cycle and asserts the case's required behavior.
 */
async function tsHarness(check: TsHarnessCheck, context: GradeContext): Promise<PendingResult> {
  const entry = check.entry ?? "src/core.ts";
  const harnessName = check.harness ?? "harness.zig";
  const description = `harness: ${check.description}`;
  const harnessPath = join(context.caseDir, harnessName);
  if (!existsSync(harnessPath)) {
    return { type: "ts_harness", description, status: "fail", detail: `no ${harnessName} in ${context.caseDir}` };
  }
  const entryPath = join(context.workspace.path, entry);
  if (!existsSync(entryPath)) {
    return { type: "ts_harness", description, status: "fail", detail: `${entry} not found in the workspace` };
  }
  const scratch = join(context.workspace.path, ".harness");
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  const transpile = await exec(
    "node",
    [transpilerCli(context.repoRoot), entryPath, "-o", join(scratch, "core.zig")],
    { cwd: context.workspace.path, timeoutMs: 2 * 60 * 1000 },
  );
  if (transpile.code !== 0) {
    return {
      type: "ts_harness",
      description,
      status: "fail",
      detail: `transpile failed:\n${tailLines(transpile)}`,
    };
  }
  copyFileSync(join(context.repoRoot, "packages", "core", "rt", "rt.zig"), join(scratch, "rt.zig"));
  copyFileSync(harnessPath, join(scratch, "harness.zig"));
  copyHarnessLib(context, scratch);
  const test = await exec("zig", ["test", "harness.zig"], {
    cwd: scratch,
    timeoutMs: 10 * 60 * 1000,
  });
  if (test.code === 0) return { type: "ts_harness", description, status: "pass" };
  return {
    type: "ts_harness",
    description,
    status: "fail",
    detail: test.timedOut ? "timed out" : tailLines(test),
  };
}

/**
 * Shared harness helpers (`evals/harness-lib/*.zig` — the Cmd wire-format
 * decoder and friends) copied next to every ts harness, so case harnesses
 * assert effects semantically instead of hand-parsing wire bytes.
 */
function copyHarnessLib(context: GradeContext, scratch: string): void {
  const libDir = join(context.caseDir, "..", "..", "harness-lib");
  if (!existsSync(libDir)) return;
  for (const entry of readdirSync(libDir)) {
    if (entry.endsWith(".zig")) copyFileSync(join(libDir, entry), join(scratch, entry));
  }
}

/** The grader-owned file names the zig harness injects into the workspace. */
const ZIG_HARNESS_SPEC = "eval_behavior_spec.zig";
const ZIG_HARNESS_GLUE = `
// Eval grader glue (injected after the agent run; removed before judging).
test {
    _ = @import("${ZIG_HARNESS_SPEC}");
}
`;

/**
 * Behavioral grading for the zig track of app-dual cases. The case's Zig
 * harness is injected as src/eval_behavior_spec.zig, reached through a test
 * import appended to src/main.zig (the same shape the scaffold's own
 * `test { _ = @import("tests.zig"); }` uses), and run with `native test` so
 * it compiles inside the workspace's real zero-config graph — native_sdk,
 * the fake effects executor, and the agent's Model/Msg/update all in scope.
 * The workspace is restored afterward so later checks (file greps, the
 * judge) see exactly what the agent wrote.
 */
async function zigHarness(check: ZigHarnessCheck, context: GradeContext): Promise<PendingResult> {
  const harnessName = check.harness ?? "harness-zig.zig";
  const description = `harness: ${check.description}`;
  const harnessPath = join(context.caseDir, harnessName);
  if (!existsSync(harnessPath)) {
    return { type: "zig_harness", description, status: "fail", detail: `no ${harnessName} in ${context.caseDir}` };
  }
  const mainPath = join(context.workspace.path, "src", "main.zig");
  if (!existsSync(mainPath)) {
    return { type: "zig_harness", description, status: "fail", detail: "src/main.zig not found in the workspace" };
  }
  const specPath = join(context.workspace.path, "src", ZIG_HARNESS_SPEC);
  const originalMain = readFileSync(mainPath, "utf8");
  copyFileSync(harnessPath, specPath);
  appendFileSync(mainPath, ZIG_HARNESS_GLUE);
  try {
    const test = await exec(context.workspace.cliPath, ["test", ...(check.args ?? [])], {
      cwd: context.workspace.path,
      timeoutMs: 15 * 60 * 1000,
    });
    if (test.code === 0) return { type: "zig_harness", description, status: "pass" };
    return {
      type: "zig_harness",
      description,
      status: "fail",
      detail: test.timedOut ? "timed out" : tailLines(test),
    };
  } finally {
    writeFileSync(mainPath, originalMain);
    rmSync(specPath, { force: true });
  }
}

async function llmJudge(check: LlmJudgeCheck, context: GradeContext): Promise<PendingResult> {
  const advisory = check.advisory ?? true;
  const minScore = check.minScore ?? 6;
  const description = `judge${advisory ? " (advisory)" : ""}: ${check.description}`;
  if (context.dryRun) {
    return { type: "llm_judge", description, status: "skipped", advisory, detail: "--dry-run (no model calls)" };
  }
  if (context.agentErrored) {
    return { type: "llm_judge", description, status: "skipped", advisory, detail: "agent step errored - nothing to judge" };
  }
  if (!context.gatewayKey) {
    return { type: "llm_judge", description, status: "skipped", advisory, detail: "no gateway key" };
  }
  let verdict;
  try {
    verdict = await judgeWorkspace({
      gatewayKey: context.gatewayKey,
      model: context.judgeModel,
      taskPrompt: context.taskPrompt,
      criteria: check.criteria,
      workspacePath: context.workspace.path,
      fileSelectors: check.files,
    });
  } catch (error) {
    const detail = `judge call failed: ${(error as Error).message}`;
    return advisory
      ? { type: "llm_judge", description, status: "skipped", advisory, detail }
      : { type: "llm_judge", description, status: "fail", advisory, detail };
  }
  const lines = verdict.scores.map(
    (entry) => `${entry.score.toFixed(1).padStart(4)}  ${entry.criterion}${entry.note ? ` — ${entry.note}` : ""}`,
  );
  const detail = `overall ${verdict.overall.toFixed(1)}/10 (min ${minScore})\n${lines.join("\n")}${verdict.summary ? `\n${verdict.summary}` : ""}`;
  return {
    type: "llm_judge",
    description,
    status: verdict.overall >= minScore ? "pass" : "fail",
    score: verdict.overall,
    advisory,
    detail,
  };
}

async function buildTest(args: string[], context: GradeContext): Promise<PendingResult> {
  // Workspaces are zero-config (app.zon + src, no build.zig), so the app's
  // test suite runs through the CLI verb — a bare `zig build test` would
  // resolve up the tree to the SDK's own build.zig and grade the wrong graph.
  const description = `native test${args.length ? ` ${args.join(" ")}` : ""}`;
  const result = await exec(context.workspace.cliPath, ["test", ...args], {
    cwd: context.workspace.path,
    timeoutMs: 15 * 60 * 1000,
  });
  if (result.code === 0) return { type: "build_test", description, status: "pass" };
  return {
    type: "build_test",
    description,
    status: "fail",
    detail: result.timedOut ? "timed out" : tailLines(result),
  };
}

async function markupCheck(context: GradeContext): Promise<PendingResult> {
  const files = resolveFiles(context.workspace.path, "src/*.native");
  if (files.length === 0) {
    return {
      type: "markup_check",
      description: "native markup check src/*.native",
      status: "fail",
      detail: "no .native files found under src/",
    };
  }
  const failures: string[] = [];
  for (const file of files) {
    const result = await exec(context.workspace.cliPath, ["markup", "check", file], {
      cwd: context.workspace.path,
      timeoutMs: 60 * 1000,
    });
    if (result.code !== 0) {
      failures.push(`${relative(context.workspace.path, file)}:\n${tailLines(result, 8)}`);
    }
  }
  const description = `native markup check (${files.map((f) => relative(context.workspace.path, f)).join(", ")})`;
  if (failures.length === 0) return { type: "markup_check", description, status: "pass" };
  return { type: "markup_check", description, status: "fail", detail: failures.join("\n") };
}

function fileGrep(
  files: string,
  pattern: string,
  expect: boolean,
  description: string,
  context: GradeContext,
): PendingResult {
  const paths = resolveFiles(context.workspace.path, files);
  const regex = new RegExp(pattern, "m");
  const matching = paths.filter((path) => regex.test(readFileSync(path, "utf8")));
  const found = matching.length > 0;
  if (found === expect) return { type: "file_grep", description, status: "pass" };
  const detail = expect
    ? paths.length === 0
      ? `no files matched selector "${files}"`
      : `pattern /${pattern}/ not found in: ${paths.map((p) => relative(context.workspace.path, p)).join(", ")}`
    : `pattern /${pattern}/ unexpectedly found in: ${matching.map((p) => relative(context.workspace.path, p)).join(", ")}`;
  return { type: "file_grep", description, status: "fail", detail };
}

/**
 * Live grading through the automation harness: build with -Dautomation=true,
 * launch the app, wait for the automation snapshot, then grep it. On the
 * macos-local lane the app launches directly (mirrors the repo's canvas
 * smoke, but local); on the linux-sandbox lane it launches on the sandbox's
 * Xvfb display and an engine screenshot is captured through the automation
 * dropbox as a run artifact before the microVM is destroyed.
 */
async function snapshotGrep(
  check: SnapshotGrepCheck,
  context: GradeContext,
): Promise<PendingResult> {
  const description = `snapshot: ${check.description}`;
  if (context.skipLive) {
    return { type: "snapshot_grep", description, status: "skipped", detail: "--skip-live" };
  }
  const linuxLane = context.lane === "linux-sandbox";
  if (!linuxLane && process.platform !== "darwin") {
    return { type: "snapshot_grep", description, status: "skipped", detail: "requires macOS" };
  }
  if (linuxLane && (process.platform !== "linux" || !process.env.DISPLAY)) {
    return {
      type: "snapshot_grep",
      description,
      status: "skipped",
      detail: "linux-sandbox lane needs a Linux host with DISPLAY set (Xvfb)",
    };
  }
  const workspace = context.workspace.path;
  const platformArg = linuxLane ? "-Dplatform=linux" : "-Dplatform=macos";
  // CLI verb, not bare zig: workspaces are zero-config. macOS grades at the
  // Debug shape (`native build` alone would inject ReleaseFast and spend
  // grader wall-clock on optimization). Linux grades at ReleaseSafe: Debug
  // x86_64-linux binaries go through zig's self-hosted code generator, which
  // currently half-writes one stack-passed pointer in the 22-argument GTK
  // host create-view call (segfault on an 0xaaaa... address at launch);
  // ReleaseSafe selects the LLVM backend and keeps safety checks on.
  const optimizeArg = linuxLane ? "-Doptimize=ReleaseSafe" : "-Doptimize=Debug";
  const build = await exec(
    context.workspace.cliPath,
    ["build", platformArg, "-Dweb-engine=system", "-Dautomation=true", optimizeArg],
    { cwd: workspace, timeoutMs: 15 * 60 * 1000 },
  );
  if (build.code !== 0) {
    return { type: "snapshot_grep", description, status: "fail", detail: `automation build failed:\n${tailLines(build)}` };
  }
  const binary = findAppBinary(workspace);
  if (!binary) {
    return { type: "snapshot_grep", description, status: "fail", detail: "no executable in zig-out/bin" };
  }
  rmSync(join(workspace, ".zig-cache", "native-sdk-automation"), { recursive: true, force: true });
  const app = spawn(binary, [], { cwd: workspace, stdio: "ignore" });
  try {
    // Readiness budget: headless Linux shows a long stall between EGL init
    // and the first published frame (the repo's Linux CI smoke measured a
    // consistent ~27 s on shared runners), so that lane gets a 90 s window;
    // `automate assert` polls until the deadline. macOS keeps the CLI's
    // default `automate wait` behavior.
    const wait = linuxLane
      ? await exec(
          context.workspace.cliPath,
          ["automate", "assert", "--timeout-ms", "90000", "ready=true"],
          { cwd: workspace, timeoutMs: 120 * 1000 },
        )
      : await exec(context.workspace.cliPath, ["automate", "wait"], {
          cwd: workspace,
          timeoutMs: 60 * 1000,
        });
    // Readiness is reported on stderr; exit 0 once ready.
    if (wait.code !== 0 || (!linuxLane && !`${wait.stdout}\n${wait.stderr}`.includes("ready=true"))) {
      return {
        type: "snapshot_grep",
        description,
        status: "fail",
        detail: `automation snapshot never became ready:\n${tailLines(wait, 6)}`,
      };
    }
    const snapshotPath = join(workspace, ".zig-cache", "native-sdk-automation", "snapshot.txt");
    const regexes = check.patterns.map((pattern) => new RegExp(pattern, "m"));
    // Widget lines appear in the snapshot only after the first rendered
    // frame (widget_nodes starts at 0), so poll rather than read once.
    const deadline = Date.now() + 30 * 1000;
    let missing: string[] = check.patterns;
    while (Date.now() < deadline) {
      const snapshot = existsSync(snapshotPath) ? readFileSync(snapshotPath, "utf8") : "";
      missing = check.patterns.filter((_, index) => !regexes[index]!.test(snapshot));
      if (missing.length === 0) break;
      await sleep(300);
    }
    // Capture pixels while the app is still alive — pass or fail, the
    // screenshot is evidence that leaves the sandbox with the results.
    if (linuxLane && context.artifactsDir) {
      await captureEngineScreenshot(context, snapshotPath).catch((error: Error) => {
        context.log(`[live] screenshot capture failed: ${error.message}`);
      });
    }
    if (missing.length === 0) return { type: "snapshot_grep", description, status: "pass" };
    return {
      type: "snapshot_grep",
      description,
      status: "fail",
      detail: `snapshot missing patterns:\n${missing.map((pattern) => `  /${pattern}/`).join("\n")}`,
    };
  } finally {
    app.kill("SIGKILL");
  }
}

/**
 * Engine screenshot through the automation dropbox: resolve the app's
 * gpu_surface view label from the snapshot, queue `automate screenshot`
 * (the dropbox is single-slot — the CLI paces one command at a time), and
 * poll for the rendered png. Best-effort: grading never fails on this.
 */
async function captureEngineScreenshot(
  context: GradeContext,
  snapshotPath: string,
): Promise<void> {
  const workspace = context.workspace.path;
  const snapshot = existsSync(snapshotPath) ? readFileSync(snapshotPath, "utf8") : "";
  const canvas = /view @w\d+\/(\S+) kind=gpu_surface/.exec(snapshot)?.[1];
  if (!canvas) {
    context.log("[live] no gpu_surface view in snapshot; skipping screenshot");
    return;
  }
  const shot = await exec(context.workspace.cliPath, ["automate", "screenshot", canvas], {
    cwd: workspace,
    timeoutMs: 30 * 1000,
  });
  if (shot.code !== 0) throw new Error(`automate screenshot exited ${shot.code}`);
  const pngPath = join(workspace, ".zig-cache", "native-sdk-automation", `screenshot-${canvas}.png`);
  const deadline = Date.now() + 10 * 1000;
  while (Date.now() < deadline) {
    if (existsSync(pngPath) && statSync(pngPath).size > 0) {
      const artifact = join(context.artifactsDir!, `live-${canvas}.png`);
      copyFileSync(pngPath, artifact);
      context.log(`[live] engine screenshot captured: live-${canvas}.png`);
      return;
    }
    await sleep(200);
  }
  throw new Error("screenshot file never appeared");
}

function findAppBinary(workspace: string): string | undefined {
  const binDir = join(workspace, "zig-out", "bin");
  let entries: string[];
  try {
    entries = readdirSync(binDir);
  } catch {
    return undefined;
  }
  for (const entry of entries) {
    const path = join(binDir, entry);
    const stats = statSync(path);
    if (stats.isFile() && (stats.mode & 0o111) !== 0) return path;
  }
  return undefined;
}

function indent(text: string, prefix: string): string {
  return text
    .split("\n")
    .map((line) => `${prefix}${line}`)
    .join("\n");
}
