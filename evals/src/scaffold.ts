import { mkdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { exec, tailLines } from "./util.ts";

/** `zig build` once at the repo root so `zig-out/bin/zero-native` exists. */
export async function buildCli(repoRoot: string): Promise<string> {
  const cliPath = join(repoRoot, "zig-out", "bin", "zero-native");
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
  /** Absolute path of the zero-native CLI used for init/skills/markup-check/automate. */
  cliPath: string;
}

/**
 * Scaffold a fresh app workspace exactly as a user would:
 *   zero-native init <workspace> --frontend native
 * then deliver the native-ui skill along the documented user path
 * (`zero-native skills get native-ui`) into `.claude/skills/native-ui/SKILL.md`
 * — `init` itself does not ship any skill, so a real project gets it this way.
 */
export async function scaffoldWorkspace(
  repoRoot: string,
  cliPath: string,
  workspacesDir: string,
  caseName: string,
  frontend: string,
): Promise<Workspace> {
  const workspace = join(workspacesDir, caseName);
  rmSync(workspace, { recursive: true, force: true });
  mkdirSync(workspacesDir, { recursive: true });

  // Run init from the repo root so the relative framework path in
  // build.zig.zon is computed the same way as the repo's scaffold CI job.
  const init = await exec(cliPath, ["init", workspace, "--frontend", frontend], {
    cwd: repoRoot,
    timeoutMs: 60 * 1000,
  });
  if (init.code !== 0) {
    throw new Error(`zero-native init failed:\n${tailLines(init)}`);
  }

  const skill = await exec(cliPath, ["skills", "get", "native-ui"], {
    cwd: repoRoot,
    timeoutMs: 30 * 1000,
  });
  if (skill.code !== 0 || !skill.stdout.includes("name: native-ui")) {
    throw new Error(`zero-native skills get native-ui failed:\n${tailLines(skill)}`);
  }
  const skillDir = join(workspace, ".claude", "skills", "native-ui");
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(join(skillDir, "SKILL.md"), skill.stdout);

  return { path: workspace, cliPath };
}
