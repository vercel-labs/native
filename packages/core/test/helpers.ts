// Test seam: build the pipeline pieces for an in-memory module.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ts, TypedAst, createSubsetProgram } from "../src/typed_ast.ts";
import { TypeTable } from "../src/types.ts";
import { SubsetChecker, type CheckResult } from "../src/checker.ts";
import { IntInference } from "../src/infer.ts";
import { Emitter } from "../src/emitter.ts";
import { transpileFile, type TranspileOptions, type TranspileResult } from "../src/transpile.ts";

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

/// Full pipeline over a multi-file core (entry defaults to core.ts).
export function transpileFiles(
  files: Record<string, string>,
  options: TranspileOptions = {},
  entry = "core.ts",
): TranspileResult {
  return withTempModules(files, entry, (entryPath) => transpileFile(entryPath, options));
}

/// Full pipeline (type errors gate first) — what the CLI does.
export function transpile(source: string, options: TranspileOptions = {}): TranspileResult {
  return withTempModule(source, (entry) => transpileFile(entry, options));
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

/// An Emitter over an in-memory module WITHOUT emitting — for pinning
/// internal flow judgments whose interesting inputs the subset checker's
/// own gates keep out of end-to-end fixtures (nested function
/// declarations, module-level `let`). The subset check still runs (the
/// constructor takes its result) but its diagnostics do not gate here.
export function buildEmitter(source: string): { emitter: Emitter; file: ts.SourceFile } {
  return withTempModule(source, (entry) => {
    const program = createSubsetProgram(entry);
    const tast = new TypedAst(program);
    const file = program.getSourceFile(entry)!;
    const table = new TypeTable(tast, file);
    const checkResult = new SubsetChecker(tast, table, file).check();
    const infer = new IntInference(tast, table, [file]);
    return { emitter: new Emitter(tast, table, infer, checkResult, file, path.basename(entry)), file };
  });
}

/// Emit Zig for a module that must pass the checker.
export function emit(source: string): string {
  const result = transpile(source);
  if (!result.ok || result.zig === null) {
    const details = [
      ...result.typeErrors,
      ...result.diagnostics.map((d) => `${d.id} ${d.title}: ${d.message}`),
    ].join("\n");
    throw new Error(`transpile failed:\n${details}`);
  }
  return result.zig;
}
