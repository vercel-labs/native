import { mkdirSync, readFileSync, existsSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Sandbox } from "@vercel/sandbox";
import { exec } from "./util.ts";
import type { CaseResult, EvalCase } from "./types.ts";

/** Per-sandbox wall clock. 45 minutes is the Hobby-plan ceiling; a case's
 * agent budget (20-25 min) plus incremental builds and grading fits under it. */
const SANDBOX_TIMEOUT_MS = 45 * 60 * 1000;
/** Where evals/sandbox/Dockerfile bakes the repo (pinned ref, warm caches). */
const REPO_DIR = "/opt/native-sdk/repo";
/** The claude CLI refuses --dangerously-skip-permissions as root; the inner harness runs as this user. */
const EVAL_USER = "evalagent";
/** Headless X display for live checks; started per sandbox, so no collisions. */
const DISPLAY = ":77";

/**
 * Environment for every command run in the sandbox. Image ENV is metadata
 * the sandbox runtime is not guaranteed to apply to injected commands, so
 * the values baked into evals/sandbox/Dockerfile are repeated here:
 * fixed cache paths (so per-case builds hit the image's pre-warmed caches
 * regardless of which uid runs them) and the headless-display settings the
 * repo's Linux CI smoke established (web-process sandbox off — microVM
 * seccomp blocks its user namespaces; accessibility-bus lookup off — no
 * session bus exists under Xvfb and the init would stall ~25 s).
 */
const SANDBOX_ENV: Record<string, string> = {
  ZIG_LOCAL_CACHE_DIR: "/opt/native-sdk/zig-local-cache",
  ZIG_GLOBAL_CACHE_DIR: "/opt/native-sdk/zig-global-cache",
  npm_config_store_dir: "/opt/native-sdk/pnpm-store",
  WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS: "1",
  GTK_A11Y: "none",
  DISPLAY,
  DISABLE_AUTOUPDATER: "1",
};

/** Explicit credentials for Sandbox.create (the access-token auth path). */
export interface SandboxCredentials {
  token: string;
  teamId: string;
  projectId: string;
}

let sandboxCredentials: SandboxCredentials | undefined;

/**
 * Auth for Sandbox.create, checked before any sandbox work starts:
 * - VERCEL_OIDC_TOKEN (recommended): from `vercel link` + `vercel env pull`
 *   in evals/ (the runner auto-loads evals/.env.local so no dotenv wrapper
 *   is needed). The token expires after ~12 h; re-pull when auth fails.
 *   The SDK reads this env var itself.
 * - VERCEL_TOKEN + VERCEL_TEAM_ID + VERCEL_PROJECT_ID (access token): for
 *   environments where OIDC is unavailable (external CI). The SDK does not
 *   read these from the environment, so they are captured here and passed
 *   to Sandbox.create explicitly.
 */
export function ensureSandboxAuth(evalsRoot: string): void {
  if (process.env.VERCEL_OIDC_TOKEN) return;
  if (process.env.VERCEL_TOKEN && process.env.VERCEL_TEAM_ID && process.env.VERCEL_PROJECT_ID) {
    sandboxCredentials = {
      token: process.env.VERCEL_TOKEN,
      teamId: process.env.VERCEL_TEAM_ID,
      projectId: process.env.VERCEL_PROJECT_ID,
    };
    return;
  }
  const envFile = join(evalsRoot, ".env.local");
  if (existsSync(envFile)) {
    for (const line of readFileSync(envFile, "utf8").split("\n")) {
      const match = /^VERCEL_OIDC_TOKEN="?([^"]+)"?$/.exec(line.trim());
      if (match) {
        process.env.VERCEL_OIDC_TOKEN = match[1];
        return;
      }
    }
  }
  throw new Error(
    "no sandbox auth. Either run `vercel link` and `vercel env pull .env.local` in evals/ " +
      "(OIDC token, expires ~12h; re-pull when auth fails), or set " +
      "VERCEL_TOKEN + VERCEL_TEAM_ID + VERCEL_PROJECT_ID.",
  );
}

/**
 * Pack the working tree (not HEAD — uncommitted SDK changes should be
 * what gets evaluated) for upload into sandboxes. Built once per run; inside
 * each sandbox it is rsynced over the image's baked repo so builds against
 * the current tip are incremental on top of the pre-warmed caches.
 */
export async function packRepo(repoRoot: string): Promise<string> {
  const tarball = join("/tmp", `native-sdk-evals-repo-${process.pid}.tgz`);
  // Both bare and `*/`-prefixed patterns: BSD tar matches excludes against
  // whole paths, so "node_modules" alone would miss nested ones (and 200MB of
  // third_party/example caches would ride along).
  const excludes = [
    ".git",
    ".claude",
    ".vercel",
    "third_party",
    ".next",
    ".zig-cache",
    "zig-out",
    "node_modules",
    ".workspaces",
    "results",
    ".env.local",
    ".env*.local",
  ].flatMap((pattern) => ["--exclude", pattern, "--exclude", `*/${pattern}`, "--exclude", `*/${pattern}/*`]);
  const result = await exec("tar", ["-czf", tarball, ...excludes, "-C", repoRoot, "."], {
    cwd: repoRoot,
    timeoutMs: 5 * 60 * 1000,
  });
  if (result.code !== 0) throw new Error(`failed to pack repo: ${result.stderr.slice(0, 400)}`);
  return tarball;
}

/**
 * Refresh the baked repo to the uploaded working tree. Deletions propagate
 * (--delete), but build state survives on purpose: caches live outside the
 * repo (see SANDBOX_ENV), and zig-out keeps the baked CLI until the inner
 * harness's own repo-root `zig build` refreshes it incrementally. The
 * excluded directories are exactly the ones the tarball never carries.
 */
const REFRESH = `set -euo pipefail
mkdir -p /tmp/repo-sync
tar xzf /tmp/repo.tgz -C /tmp/repo-sync
rsync -a --delete \
  --exclude .git --exclude .claude --exclude .vercel --exclude third_party \
  --exclude .zig-cache --exclude .native --exclude zig-out --exclude node_modules \
  --exclude .workspaces --exclude results \
  /tmp/repo-sync/ ${REPO_DIR}/
rm -rf /tmp/repo-sync /tmp/repo.tgz
echo "working tree refreshed over baked ref $(cat /opt/native-sdk/baked-ref)"
cd ${REPO_DIR}/evals && pnpm install --frozen-lockfile
`;

/** Start the headless display and block until it accepts connections. */
const XVFB_WAIT = `for _ in $(seq 1 100); do
  xdpyinfo -display ${DISPLAY} >/dev/null 2>&1 && exit 0
  sleep 0.1
done
echo "Xvfb never became ready" >&2
exit 1
`;

export async function runCaseInSandbox(options: {
  evalCase: EvalCase;
  tarballPath: string;
  gatewayKey: string | undefined;
  model: string;
  judgeModel: string;
  vcpus: number;
  image: string;
  dryRun: boolean;
  localResultsDir: string;
  log: (line: string) => void;
}): Promise<CaseResult> {
  const { evalCase, log } = options;
  log(`[sandbox] creating from image ${options.image} (${options.vcpus} vcpus, ${SANDBOX_TIMEOUT_MS / 60000}m timeout)...`);
  const sandbox = await createWithImageRetry(options.image, options.vcpus, log);
  try {
    log(`[sandbox] ${sandbox.name || "created"}; uploading working tree...`);
    await sandbox.writeFiles([
      { path: "/tmp/repo.tgz", content: readFileSync(options.tarballPath) },
    ]);

    await run(sandbox, "refresh repo to current tip", REFRESH, log, false);

    // Live checks need a display before the inner harness starts. Detached:
    // the X server outlives this command and dies with the sandbox.
    await sandbox.runCommand({
      cmd: "Xvfb",
      args: [DISPLAY, "-ac", "-screen", "0", "1600x1000x24"],
      detached: true,
    });
    await run(sandbox, "wait for Xvfb", XVFB_WAIT, log, false);

    // The inner harness does the rest, exactly like a local run but on the
    // linux-sandbox lane: repo-root zig build, scaffold + skill, pre-warm,
    // agent, graders (live checks drive the app on the Xvfb display), judge.
    // --skip-permissions is safe here: the whole VM is the throwaway — but
    // the claude CLI refuses it under root, so the inner harness runs as a
    // dedicated non-root user (the image's shared zig caches are already
    // world-writable for exactly this). setpriv (not runuser/su) so the
    // command env — gateway key, DISPLAY — passes through unmodified.
    await run(
      sandbox,
      "provision non-root eval user",
      `id -u ${EVAL_USER} >/dev/null 2>&1 || useradd -m ${EVAL_USER}; chown -R ${EVAL_USER} /opt/native-sdk`,
      log,
      false,
    );
    const inner = [
      `cd ${REPO_DIR}/evals &&`,
      "pnpm eval --skip-permissions --keep-workspaces --lane linux-sandbox",
      ...(options.dryRun ? ["--dry-run"] : []),
      `--model ${options.model} --judge-model ${options.judgeModel}`,
      evalCase.name,
    ].join(" ");
    const innerAsUser = `setpriv --reuid=${EVAL_USER} --regid=${EVAL_USER} --init-groups env HOME=/home/${EVAL_USER} bash -c ${JSON.stringify(inner)}`;
    // The inner harness prefixes its own lines with the case name; strip it
    // since our `log` adds the same prefix.
    const innerPrefix = `[${evalCase.name}] `;
    const innerLog = (line: string): void =>
      log(line.startsWith(innerPrefix) ? line.slice(innerPrefix.length) : line);
    const innerEnv: Record<string, string> = { ...SANDBOX_ENV };
    if (options.gatewayKey) innerEnv.AI_GATEWAY_API_KEY = options.gatewayKey;
    const innerExit = await run(
      sandbox,
      `inner eval: ${evalCase.name}`,
      innerAsUser,
      innerLog,
      true,
      innerEnv,
    );

    // Pull the whole case results directory home — result.json, transcript,
    // live screenshots — before the microVM (and everything in it) is gone.
    // claude-config is the agent's isolated CLAUDE_CONFIG_DIR; its useful
    // content is already in transcript.jsonl, so it stays behind.
    const stampCmd = await sandbox.runCommand("bash", ["-c", `ls -t ${REPO_DIR}/evals/results | head -1`]);
    const stamp = (await stampCmd.stdout()).trim();
    if (!stamp) throw new Error(`inner run exited ${innerExit} without a results directory`);
    const caseDir = `${REPO_DIR}/evals/results/${stamp}/${evalCase.name}`;
    const pack = await sandbox.runCommand("bash", [
      "-c",
      `cd ${caseDir} && tar czf /tmp/case-results.tgz --exclude claude-config .`,
    ]);
    if (pack.exitCode !== 0) {
      throw new Error(`inner run exited ${innerExit} without writing results (${await pack.stderr()})`);
    }
    const resultsTar = await sandbox.readFileToBuffer({ path: "/tmp/case-results.tgz" });
    if (!resultsTar) throw new Error("case results tarball missing from sandbox");
    mkdirSync(options.localResultsDir, { recursive: true });
    const localTar = join(tmpdir(), `native-sdk-evals-out-${process.pid}-${evalCase.name}.tgz`);
    writeFileSync(localTar, resultsTar);
    const unpack = await exec("tar", ["xzf", localTar, "-C", options.localResultsDir], {
      cwd: options.localResultsDir,
      timeoutMs: 60 * 1000,
    });
    rmSync(localTar, { force: true });
    if (unpack.code !== 0) throw new Error(`failed to unpack case results: ${unpack.stderr.slice(0, 400)}`);

    const resultPath = join(options.localResultsDir, "result.json");
    if (!existsSync(resultPath)) {
      throw new Error(`inner run exited ${innerExit} without writing result.json`);
    }
    const caseResult = JSON.parse(readFileSync(resultPath, "utf8")) as CaseResult;
    caseResult.workspace = `vercel-sandbox:${sandbox.name || "unknown"}`;
    writeFileSync(resultPath, `${JSON.stringify(caseResult, null, 2)}\n`);
    return caseResult;
  } finally {
    log("[sandbox] stopping");
    await sandbox.stop().catch(() => undefined);
  }
}

/**
 * Create the sandbox, riding out image preparation: after a push, the
 * registry needs a while to prepare an optimized image and creation fails
 * with image_not_ready until it finishes. Retry within a bounded window;
 * every other error is real and surfaces immediately.
 */
async function createWithImageRetry(
  image: string,
  vcpus: number,
  log: (line: string) => void,
): Promise<Sandbox> {
  const deadline = Date.now() + 10 * 60 * 1000;
  for (;;) {
    try {
      return await Sandbox.create({
        image,
        resources: { vcpus },
        timeout: SANDBOX_TIMEOUT_MS,
        ...(sandboxCredentials ?? {}),
      });
    } catch (error) {
      const message = (error as Error).message ?? String(error);
      if (/404/.test(message)) {
        throw new Error(
          `sandbox image "${image}" was not found in the registry — ` +
            "build and push it once with evals/sandbox/build-image.sh " +
            `(original error: ${message})`,
        );
      }
      if (!/image_not_ready/i.test(message) || Date.now() > deadline) throw error;
      log("[sandbox] image is still being prepared by the registry; retrying in 30s...");
      await new Promise((resolve) => setTimeout(resolve, 30 * 1000));
    }
  }
}

/** Run a bash script in the sandbox, streaming output lines through `log`. */
async function run(
  sandbox: Sandbox,
  label: string,
  script: string,
  log: (line: string) => void,
  allowFailure: boolean,
  env?: Record<string, string>,
): Promise<number> {
  const command = await sandbox.runCommand({
    cmd: "bash",
    args: ["-c", script],
    ...(env ? { env } : { env: SANDBOX_ENV }),
    detached: true,
  });
  let buffered = "";
  for await (const entry of command.logs()) {
    buffered += entry.data;
    let newline;
    while ((newline = buffered.indexOf("\n")) !== -1) {
      const line = buffered.slice(0, newline).trimEnd();
      buffered = buffered.slice(newline + 1);
      if (line) log(line);
    }
  }
  if (buffered.trim()) log(buffered.trim());
  const finished = await command.wait();
  const exitCode = finished.exitCode ?? -1;
  if (exitCode !== 0 && !allowFailure) {
    throw new Error(`sandbox step failed (${label}): exit ${exitCode}`);
  }
  return exitCode;
}
