import { cpSync, mkdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { exec, tailLines } from "./util.ts";
import type { Track } from "./types.ts";

/** `zig build` once at the repo root so `zig-out/bin/native` exists. */
export async function buildCli(repoRoot: string): Promise<string> {
  const cliPath = join(repoRoot, "zig-out", "bin", "native");
  console.log("[scaffold] zig build (repo root, may take a while on cold cache)...");
  const result = await exec("zig", ["build"], { cwd: repoRoot, timeoutMs: 15 * 60 * 1000 });
  if (result.code !== 0) {
    throw new Error(`zig build failed at repo root:\n${tailLines(result)}`);
  }
  if (!existsSync(cliPath)) {
    throw new Error(`zig build succeeded but ${cliPath} is missing`);
  }
  return cliPath;
}

export interface Workspace {
  /** Absolute path of the app workspace the agent works in. */
  path: string;
  /** Absolute path of the Native SDK CLI used for init/skills/markup-check/automate. */
  cliPath: string;
}

/**
 * Scaffold a fresh app workspace exactly as a user would:
 *   native init <workspace> --frontend native
 * then deliver the native-ui skill along the documented user path
 * (`native skills get native-ui`) into `.claude/skills/native-ui/SKILL.md`
 * — `init` itself does not ship any skill, so a real project gets it this way.
 */
export async function scaffoldWorkspace(
  repoRoot: string,
  cliPath: string,
  workspacesDir: string,
  caseName: string,
  frontend: string,
  caseDir?: string,
  track?: Track,
): Promise<Workspace> {
  const workspace = join(workspacesDir, caseName);
  rmSync(workspace, { recursive: true, force: true });
  mkdirSync(workspacesDir, { recursive: true });

  if (frontend === "ts-core") {
    return scaffoldTsCoreWorkspace(repoRoot, cliPath, workspace, caseDir);
  }
  if (frontend === "app-dual") {
    if (!track) throw new Error("app-dual cases scaffold per track; no track given");
    return scaffoldAppWorkspace(repoRoot, cliPath, workspace, track, caseDir);
  }

  // Run init from the repo root so the relative framework path in
  // build.zig.zon is computed the same way as the repo's scaffold CI job.
  // The pre-existing native track keeps the Zig-core template explicitly:
  // `--template` defaults to ts-core since the TS tier landed, and these
  // cases grade Zig authoring.
  const init = await exec(cliPath, ["init", workspace, "--frontend", frontend, "--template", "zig-core"], {
    cwd: repoRoot,
    timeoutMs: 60 * 1000,
  });
  if (init.code !== 0) {
    throw new Error(`native init failed:\n${tailLines(init)}`);
  }

  await deliverSkills(repoRoot, cliPath, workspace, ["native-ui", "zig"]);

  return { path: workspace, cliPath };
}

/**
 * Deliver skills exactly the way a real user gets them — `native skills get
 * <name>` redirected into `.claude/skills/<name>/SKILL.md` (`init` never
 * ships skills). Each track receives its CURRENT documented skill set and
 * nothing extra; fairness across tracks is "the same delivery path, each
 * track's own guidance".
 */
async function deliverSkills(
  repoRoot: string,
  cliPath: string,
  workspace: string,
  names: string[],
): Promise<void> {
  for (const name of names) {
    const skill = await exec(cliPath, ["skills", "get", name], {
      cwd: repoRoot,
      timeoutMs: 30 * 1000,
    });
    if (skill.code !== 0 || !skill.stdout.includes(`name: ${name}`)) {
      throw new Error(`native skills get ${name} failed:\n${tailLines(skill)}`);
    }
    const skillDir = join(workspace, ".claude", "skills", name);
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(join(skillDir, "SKILL.md"), skill.stdout);
  }
}

/**
 * Scaffold one track of an app-dual case: a FULL app workspace from the
 * repo's own init templates — `native init <ws> --frontend native
 * --template ts-core|zig-core` — so both tracks start from exactly what a
 * real user gets. A `cases/<name>/starter-<track>/` overlay (when the case
 * ships one) is copied over the scaffold: feature-add and bug-fix cases
 * seed their starting app this way, per track, in each track's idiom.
 *
 * Skill delivery per track (the documented `native skills get` path):
 *   ts  — ts-core (the core subset) + native-ui (the markup surface).
 *   zig — native-ui (markup + Zig app logic) + zig (the 0.16 idioms).
 * Both tracks get the shared markup guidance; each gets its own core-tier
 * guidance, current as of the tree under test.
 */
async function scaffoldAppWorkspace(
  repoRoot: string,
  cliPath: string,
  workspace: string,
  track: Track,
  caseDir: string | undefined,
): Promise<Workspace> {
  const template = track === "ts" ? "ts-core" : "zig-core";
  const init = await exec(
    cliPath,
    ["init", workspace, "--frontend", "native", "--template", template],
    { cwd: repoRoot, timeoutMs: 60 * 1000 },
  );
  if (init.code !== 0) {
    throw new Error(`native init (--template ${template}) failed:\n${tailLines(init)}`);
  }

  const starter = caseDir ? join(caseDir, `starter-${track}`) : undefined;
  if (starter && existsSync(starter)) {
    cpSync(starter, workspace, { recursive: true });
  }

  const skills = track === "ts" ? ["ts-core", "native-ui"] : ["native-ui", "zig"];
  await deliverSkills(repoRoot, cliPath, workspace, skills);

  return { path: workspace, cliPath };
}

/**
 * Scaffold a TypeScript app-core workspace (ts-core cases): src/core.ts (the
 * case's starter overlay when it ships one, else a minimal working counter
 * core), a README documenting the check loop, and the ts-core skill
 * delivered along the documented user path (`native skills get ts-core`).
 * No app scaffold: the core module is the whole deliverable, graded through
 * the @native-sdk/core frontend and the case's zig-test harness.
 */
async function scaffoldTsCoreWorkspace(
  repoRoot: string,
  cliPath: string,
  workspace: string,
  caseDir: string | undefined,
): Promise<Workspace> {
  mkdirSync(join(workspace, "src"), { recursive: true });

  const starter = caseDir ? join(caseDir, "starter") : undefined;
  if (starter && existsSync(starter)) {
    cpSync(starter, workspace, { recursive: true });
  } else {
    writeFileSync(join(workspace, "src", "core.ts"), DEFAULT_TS_CORE);
  }
  writeFileSync(join(workspace, "README.md"), tsCoreReadme(repoRoot));

  const skill = await exec(cliPath, ["skills", "get", "ts-core"], {
    cwd: repoRoot,
    timeoutMs: 30 * 1000,
  });
  if (skill.code !== 0 || !skill.stdout.includes("name: ts-core")) {
    throw new Error(`native skills get ts-core failed:\n${tailLines(skill)}`);
  }
  const skillDir = join(workspace, ".claude", "skills", "ts-core");
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(join(skillDir, "SKILL.md"), skill.stdout);

  return { path: workspace, cliPath };
}

const DEFAULT_TS_CORE = `// The app core: Model, Msg, update, and the pure helpers they call, written
// in the app-core TypeScript subset (see .claude/skills/ts-core/SKILL.md
// and README.md). Replace this starter counter with the requested core.

export interface Model {
  readonly count: number;
}

export type Msg = { readonly kind: "increment" } | { readonly kind: "decrement" };

export function initialModel(): Model {
  return { count: 0 };
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "increment":
      return { count: model.count + 1 };
    case "decrement":
      return { count: model.count - 1 };
  }
}
`;

function tsCoreReadme(repoRoot: string): string {
  const frontend = join(repoRoot, "packages", "core", "src", "cli.ts");
  return `# App-core workspace

This workspace holds one deliverable: \`src/core.ts\`, an app core written in the
app-core TypeScript subset. The authoring guide is
\`.claude/skills/ts-core/SKILL.md\` — read it before writing code.

## Check loop

Check after every meaningful edit; the diagnostics teach the rule, the fix,
and the reason:

\`\`\`sh
node ${frontend} src/core.ts
\`\`\`

Exit 0 means the module typechecks and passes the subset checker — the exact
gate every build runs before the external core compiler takes the graph.

The subset is erasable TypeScript, so node can also import \`src/core.ts\`
directly for quick behavioral pokes — semantics match the native build.
`;
}

/**
 * Pre-warm the workspace before the agent starts: the first `native test`
 * in a fresh zero-config workspace compiles the whole SDK (minutes); doing
 * it up front makes the agent's own builds incremental and stops billing
 * agent wall-clock for compilation. Runs the same command the agent's loop
 * and the build_test grader use, so it warms exactly the graph they hit —
 * and proves the scaffold is healthy before spending model tokens.
 */
export async function prewarmWorkspace(
  workspace: Workspace,
  log: (line: string) => void,
): Promise<void> {
  log("[prewarm] native test (cold SDK build)...");
  const result = await exec(workspace.cliPath, ["test"], {
    cwd: workspace.path,
    timeoutMs: 15 * 60 * 1000,
  });
  if (result.code !== 0) {
    throw new Error(`pre-warm build failed — scaffold is broken:\n${tailLines(result)}`);
  }
  log(`[prewarm] done in ${(result.durationMs / 1000).toFixed(0)}s`);
}

/**
 * Pre-warm a ts-core workspace: run the frontend check over the starter
 * core once — proves the scaffold is subset-clean before spending model
 * tokens (the ts_harness grader compiles through the external toolchain
 * itself and needs no warm zig graph here).
 */
export async function prewarmTsCoreWorkspace(
  repoRoot: string,
  workspace: Workspace,
  log: (line: string) => void,
): Promise<void> {
  log("[prewarm] frontend check over the starter core...");
  const check = await exec(
    "node",
    [join(repoRoot, "packages", "core", "src", "cli.ts"), join(workspace.path, "src", "core.ts")],
    { cwd: workspace.path, timeoutMs: 2 * 60 * 1000 },
  );
  if (check.code !== 0) {
    throw new Error(`pre-warm check failed — starter core is broken:\n${tailLines(check)}`);
  }
  log(`[prewarm] done in ${(check.durationMs / 1000).toFixed(0)}s`);
}
