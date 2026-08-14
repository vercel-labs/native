// Test seam: build the pipeline pieces for an in-memory module.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ts, TypedAst, createSubsetProgram } from "../src/typed_ast.ts";
import { TypeTable } from "../src/types.ts";
import { SubsetChecker, type CheckResult } from "../src/checker.ts";
import { checkFile, type FrontendOptions, type FrontendResult } from "../src/frontend.ts";

export const scriptcPin: string = JSON.parse(
  fs.readFileSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "package.json"), "utf8"),
).dependencies.scriptc;

export function withTempModule<T>(source: string, run: (entry: string) => T): T {
  const tmp = path.join(os.tmpdir(), `tac-test-${process.pid}-${Math.random().toString(36).slice(2)}.ts`);
  fs.writeFileSync(tmp, source);
  try {
    return run(tmp);
  } finally {
    fs.unlinkSync(tmp);
  }
}

/// Multi-file seam: materialize a module map ({"core.ts": src, ...}) into a
/// temp directory (its own src/ boundary) and run against the entry.
export function withTempModules<T>(
  files: Record<string, string>,
  entry: string,
  run: (entryPath: string) => T,
): T {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tac-test-multi-"));
  try {
    for (const [name, source] of Object.entries(files)) {
      const p = path.join(dir, name);
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, source);
    }
    return run(path.join(dir, entry));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/// Full frontend pipeline over a multi-file core (entry defaults to
/// core.ts).
export function checkFiles(
  files: Record<string, string>,
  options: FrontendOptions = {},
  entry = "core.ts",
): FrontendResult {
  return withTempModules(files, entry, (entryPath) => checkFile(entryPath, options));
}

/// Full frontend pipeline (type errors gate first) — what the CLI does.
export function check(source: string, options: FrontendOptions = {}): FrontendResult {
  return withTempModule(source, (entry) => checkFile(entry, options));
}

/// Checker only, without the type-error gate (for rules whose fixtures
/// intentionally use constructs tsc also dislikes).
export function checkOnly(source: string): CheckResult {
  return withTempModule(source, (entry) => {
    const program = createSubsetProgram(entry);
    const tast = new TypedAst(program);
    const file = program.getSourceFile(entry)!;
    const table = new TypeTable(tast, file);
    return new SubsetChecker(tast, table, file).check();
  });
}

export function ruleIds(result: CheckResult): string[] {
  return [...new Set(result.diagnostics.map((d) => d.id))];
}
