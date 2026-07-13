// Orchestration: resolve the core's import graph (teaching diagnostics for
// every module-boundary mistake), check every module with the provider's
// own checker (same semantics as the author-facing tsc by upstream design),
// run the subset checker, run integer inference, then emit ONE Zig module
// for the whole graph.

import { ts, TypedAst, createSubsetProgram, lineColumn } from "./typed_ast.ts";
import { resolveModuleGraph } from "./modules.ts";
import { TypeTable } from "./types.ts";
import { IntInference } from "./infer.ts";
import { SubsetChecker } from "./checker.ts";
import { Emitter, EmitError, type KernelCapacities } from "./emitter.ts";
import { makeDiagnostic, formatDiagnostic, type SubsetDiagnostic } from "./diagnostics.ts";
import path from "node:path";
import fs from "node:fs";

export interface TranspileOptions {
  /// Frame arena capacity in bytes: the transient budget of one dispatch.
  /// Emitted as a comptime parameter of the core's rt kernel instantiation
  /// (rt default when omitted).
  readonly frameCap?: number;
  /// Model heap capacity in bytes PER SPACE (the two-space committed-model
  /// heap): the live model graph plus not-yet-compacted garbage must fit.
  readonly heapCap?: number;
}

export interface TranspileResult {
  readonly ok: boolean;
  readonly zig: string | null;
  readonly diagnostics: SubsetDiagnostic[];
  /// Non-fatal teaching notices (NS1028 today): surfaced as warnings,
  /// never failing the transpile.
  readonly warnings: SubsetDiagnostic[];
  /// Provider (tsc-semantics) diagnostics, already formatted.
  readonly typeErrors: string[];
  /// Every file the core is built from, absolute, entry first — the
  /// build-graph staleness set (a change to any of them re-emits).
  readonly inputs: string[];
}

function validateCapacities(options: TranspileOptions): KernelCapacities {
  for (const [name, v] of [
    ["frameCap", options.frameCap],
    ["heapCap", options.heapCap],
  ] as const) {
    if (v !== undefined && (!Number.isSafeInteger(v) || v <= 0)) {
      throw new Error(`${name} must be a positive integer byte count, got ${v}`);
    }
  }
  return { frameCap: options.frameCap, heapCap: options.heapCap };
}

export function transpileFile(entry: string, options: TranspileOptions = {}): TranspileResult {
  const capacities = validateCapacities(options);

  // Module-boundary mistakes (NS1034-NS1037) teach BEFORE the type-checked
  // program is built: a missing file or an escaped src/ boundary would
  // otherwise surface as a raw resolution error.
  const graph = resolveModuleGraph(entry);
  if (graph.diagnostics.length > 0) {
    return { ok: false, zig: null, diagnostics: graph.diagnostics, warnings: [], typeErrors: [], inputs: [...graph.files] };
  }

  const program = createSubsetProgram(entry);
  const tast = new TypedAst(program);
  const byPath = new Map(program.getSourceFiles().map((f) => [path.resolve(f.fileName), f]));
  const files: ts.SourceFile[] = [];
  for (const p of graph.files) {
    const file = byPath.get(path.resolve(p));
    if (!file) {
      return { ok: false, zig: null, diagnostics: [], warnings: [], typeErrors: [`cannot read ${p}`], inputs: [...graph.files] };
    }
    files.push(file);
  }
  if (files.length === 0) {
    return { ok: false, zig: null, diagnostics: [], warnings: [], typeErrors: [`cannot read ${entry}`], inputs: [] };
  }

  const typeErrors: string[] = [];
  for (const file of files) {
    for (const d of tast.fileDiagnostics(file)) {
      if (d.category !== ts.DiagnosticCategory.Error) continue;
      const where = d.file && d.start !== undefined ? lineColumn(d.file, d.start) : null;
      const msg = ts.flattenDiagnosticMessageText(d.messageText, "\n");
      const name = d.file?.fileName ?? file.fileName;
      typeErrors.push(where ? `${name}:${where.line}:${where.column} TS${d.code} ${msg}` : `TS${d.code} ${msg}`);
    }
  }
  if (typeErrors.length > 0) {
    return { ok: false, zig: null, diagnostics: [], warnings: [], typeErrors: [...new Set(typeErrors)], inputs: [...graph.files] };
  }

  const table = new TypeTable(tast, files);
  const checker = new SubsetChecker(tast, table, files);
  const checkResult = checker.check();
  if (checkResult.diagnostics.length > 0) {
    return { ok: false, zig: null, diagnostics: checkResult.diagnostics, warnings: checkResult.warnings, typeErrors: [], inputs: [...graph.files] };
  }

  const infer = new IntInference(tast, table, files);
  if (infer.conflicts.length > 0) {
    // R2 consistency: an edge the inference fixed point could not make
    // same-typed is the author's to resolve, taught at check time.
    const diagnostics = infer.conflicts.map((c) => {
      const file = c.node.getSourceFile();
      const { line, column } = lineColumn(file, c.node.getStart());
      return makeDiagnostic(
        "NS1016",
        `\`${c.slotLabel}\` must be an integer where it is used, but a fractional value flows into it.`,
        file.fileName,
        line,
        column,
      );
    });
    return { ok: false, zig: null, diagnostics, warnings: checkResult.warnings, typeErrors: [], inputs: [...graph.files] };
  }
  const emitter = new Emitter(tast, table, infer, checkResult, files, path.basename(entry), capacities);
  try {
    const zig = emitter.emitModule();
    return { ok: true, zig, diagnostics: [], warnings: checkResult.warnings, typeErrors: [], inputs: [...graph.files] };
  } catch (e) {
    if (e instanceof EmitError) {
      const file = e.node.getSourceFile();
      const { line, column } = lineColumn(file, e.node.getStart());
      // Layer-3 re-derivations of taught rules keep their own rule copy;
      // everything else is the internal NS9001 stop.
      const site = e.ruleId === "NS9001" ? `Internal: no v1 mapping for ${e.message}.` : `${e.message[0].toUpperCase()}${e.message.slice(1)}.`;
      const d = makeDiagnostic(e.ruleId, site, file.fileName, line, column);
      return { ok: false, zig: null, diagnostics: [d], warnings: checkResult.warnings, typeErrors: [], inputs: [...graph.files] };
    }
    throw e;
  }
}

export function transpileSource(source: string, name = "core.ts", options: TranspileOptions = {}): TranspileResult {
  // Test seam: materialize an in-memory file through a temp path-less host.
  const tmp = path.join(process.env.TMPDIR ?? "/tmp", `native-core-${process.pid}-${Math.random().toString(36).slice(2)}.ts`);
  fs.writeFileSync(tmp, source);
  try {
    return transpileFile(tmp, options);
  } finally {
    fs.unlinkSync(tmp);
  }
}

export { formatDiagnostic };
