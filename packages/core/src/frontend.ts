// The frontend orchestration: resolve the core's import graph (teaching
// diagnostics for every module-boundary mistake), check every module with
// the provider's own checker (same semantics as the author-facing tsc by
// upstream design), run the subset checker, run integer inference, then —
// when asked — emit the contract sidecar for the whole graph. The
// external core compiler does the compiling; this pass is the subset's
// teaching surface and the contract source.

import { ts, TypedAst, createSubsetProgram, lineColumn } from "./typed_ast.ts";
import { resolveModuleGraph } from "./modules.ts";
import { TypeTable } from "./types.ts";
import { IntInference } from "./infer.ts";
import { SubsetChecker } from "./checker.ts";
import type { PersistRoutes } from "./checker.ts";
import { emitContractSidecar, ContractError } from "./contract.ts";
import { emitServiceContract } from "./service_contract.ts";
import { makeDiagnostic, formatDiagnostic, type SubsetDiagnostic } from "./diagnostics.ts";
import path from "node:path";
import fs from "node:fs";

export interface FrontendOptions {
  /// When set, also emit the contract sidecar (core.contract.json,
  /// schema format 1) from the checked program — the entry spelling the
  /// document states (never a filesystem-absolute leak).
  readonly contractEntry?: string;
  /// Ask the CLI/API caller to consume services.contract.json. The service
  /// surface is analyzed whenever src/services exists because core request
  /// names validate against it; this flag records emission intent.
  readonly servicesContract?: boolean;
  /// app.zon capabilities supplied by the build/check launcher. The core
  /// frontend stays manifest-format agnostic; it needs only declared names
  /// for capability-backed effect diagnostics.
  readonly capabilities?: readonly string[];
  /// Manifest schema version for engine-owned model persistence. When a
  /// state path is also supplied, the frontend remembers the last accepted
  /// version/fingerprint pair and warns if a shape moves without a bump.
  readonly persistVersion?: number;
  readonly persistStatePath?: string;
  /// app.zon's persistence restore routes, projected without manifest syntax
  /// so the frontend can validate them against the core's Msg union.
  readonly persistRoutes?: PersistRoutes;
}

export interface FrontendResult {
  readonly ok: boolean;
  /// The contract sidecar JSON, when options.contractEntry asked for it
  /// (null otherwise, and on any failed check).
  readonly contract: string | null;
  /// The non-deterministic service registry, or null when the app has no
  /// src/services modules (and on any failed check).
  readonly servicesContract: string | null;
  readonly diagnostics: SubsetDiagnostic[];
  /// Non-fatal capability and persistence-contract teaching notices:
  /// surfaced as warnings, never failing the check.
  readonly warnings: SubsetDiagnostic[];
  /// Provider (tsc-semantics) diagnostics, already formatted.
  readonly typeErrors: string[];
  /// Every file the core is built from, absolute, entry first — the
  /// build-graph staleness set (a change to any of them re-checks).
  readonly inputs: string[];
}

export function checkFile(entry: string, options: FrontendOptions = {}): FrontendResult {
  // Module-boundary mistakes (NS1034-NS1037) teach BEFORE the type-checked
  // program is built: a missing file or an escaped src/ boundary would
  // otherwise surface as a raw resolution error.
  const graph = resolveModuleGraph(entry);
  if (graph.diagnostics.length > 0) {
    return { ok: false, contract: null, servicesContract: null, diagnostics: graph.diagnostics, warnings: [], typeErrors: [], inputs: [...graph.files] };
  }

  const program = createSubsetProgram(entry, graph.files);
  const tast = new TypedAst(program);
  const byPath = new Map(program.getSourceFiles().map((f) => [path.resolve(f.fileName), f]));
  const files: ts.SourceFile[] = [];
  for (const p of graph.files) {
    const file = byPath.get(path.resolve(p));
    if (!file) {
      return { ok: false, contract: null, servicesContract: null, diagnostics: [], warnings: [], typeErrors: [`cannot read ${p}`], inputs: [...graph.files] };
    }
    files.push(file);
  }
  if (files.length === 0) {
    return { ok: false, contract: null, servicesContract: null, diagnostics: [], warnings: [], typeErrors: [`cannot read ${entry}`], inputs: [] };
  }

  const fileByPath = new Map(files.map((file) => [path.resolve(file.fileName), file]));
  const coreFiles = graph.coreFiles.map((p) => fileByPath.get(path.resolve(p))!).filter(Boolean);
  const serviceFiles = graph.serviceFiles.map((p) => fileByPath.get(path.resolve(p))!).filter(Boolean);
  const serviceHostFiles = graph.serviceHostFiles.map((p) => fileByPath.get(path.resolve(p))!).filter(Boolean);

  const typeErrors: string[] = [];
  // The core keeps the pinned in-process provider verdict. Services are
  // judged by scriptc's TS7 frontend in the service compile/coverage lane;
  // this provider intentionally has no Node builtin declaration universe.
  for (const file of coreFiles) {
    for (const d of tast.fileDiagnostics(file)) {
      if (d.category !== ts.DiagnosticCategory.Error) continue;
      const where = d.file && d.start !== undefined ? lineColumn(d.file, d.start) : null;
      const msg = ts.flattenDiagnosticMessageText(d.messageText, "\n");
      const name = d.file?.fileName ?? file.fileName;
      typeErrors.push(where ? `${name}:${where.line}:${where.column} TS${d.code} ${msg}` : `TS${d.code} ${msg}`);
    }
  }
  if (typeErrors.length > 0) {
    return { ok: false, contract: null, servicesContract: null, diagnostics: [], warnings: [], typeErrors: [...new Set(typeErrors)], inputs: [...graph.files] };
  }

  const serviceSurface = emitServiceContract(tast, serviceFiles, serviceHostFiles, path.dirname(path.resolve(entry)));
  if (serviceSurface.diagnostics.length > 0) {
    return { ok: false, contract: null, servicesContract: null, diagnostics: [...serviceSurface.diagnostics], warnings: [], typeErrors: [], inputs: [...graph.files] };
  }

  const table = new TypeTable(tast, coreFiles);
  const serviceOps = serviceSurface.contract === null
    ? null
    : new Set(serviceSurface.operations.map((op) => op.name));
  const checker = new SubsetChecker(
    tast,
    table,
    coreFiles,
    serviceOps,
    options.capabilities ?? [],
    options.persistRoutes,
  );
  const checkResult = checker.check();
  if (checkResult.diagnostics.length > 0) {
    return { ok: false, contract: null, servicesContract: null, diagnostics: checkResult.diagnostics, warnings: checkResult.warnings, typeErrors: [], inputs: [...graph.files] };
  }

  const infer = new IntInference(tast, table, coreFiles);
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
    return { ok: false, contract: null, servicesContract: null, diagnostics, warnings: checkResult.warnings, typeErrors: [], inputs: [...graph.files] };
  }
  try {
    // The contract sidecar emits from the SAME checked analysis, so a
    // contract-bearing run keeps every check-time teaching.
    const emittedContract =
      options.contractEntry !== undefined || options.persistVersion !== undefined
        ? emitContractSidecar({ tast, table, infer, checkResult, files: coreFiles, entry: options.contractEntry ?? "src/core.ts" })
        : null;
    const warnings = [...checkResult.warnings];
    if (emittedContract !== null && options.persistVersion !== undefined && options.persistStatePath !== undefined) {
      const fingerprint = (JSON.parse(emittedContract) as { model_fingerprint: string }).model_fingerprint;
      warnings.push(...checkPersistSchemaState(coreFiles[0], options.persistStatePath, options.persistVersion, fingerprint));
    }
    const contract = options.contractEntry !== undefined ? emittedContract : null;
    return { ok: true, contract, servicesContract: serviceSurface.contract, diagnostics: [], warnings, typeErrors: [], inputs: [...graph.files] };
  } catch (e) {
    if (e instanceof ContractError) {
      const file = e.node.getSourceFile();
      const { line, column } = lineColumn(file, e.node.getStart());
      const d = makeDiagnostic("NS1063", `${e.message[0].toUpperCase()}${e.message.slice(1)}.`, file.fileName, line, column);
      return { ok: false, contract: null, servicesContract: null, diagnostics: [d], warnings: checkResult.warnings, typeErrors: [], inputs: [...graph.files] };
    }
    throw e;
  }
}

interface PersistSchemaState {
  readonly version: number;
  readonly model_fingerprint: string;
}

/// Cache the last accepted schema pair outside authored source. A same-version
/// shape edit deliberately does not replace the baseline, so every subsequent
/// check keeps teaching until the manifest version advances.
function checkPersistSchemaState(
  entry: ts.SourceFile,
  statePath: string,
  version: number,
  fingerprint: string,
): SubsetDiagnostic[] {
  let previous: PersistSchemaState | null = null;
  try {
    const parsed = JSON.parse(fs.readFileSync(statePath, "utf8")) as Partial<PersistSchemaState>;
    if (Number.isSafeInteger(parsed.version) && typeof parsed.model_fingerprint === "string") {
      previous = { version: parsed.version!, model_fingerprint: parsed.model_fingerprint };
    }
  } catch {
    // Missing or damaged generated state is a cold check, never a build gate.
  }

  const { line, column } = lineColumn(entry, entry.getStart());
  if (previous !== null && version < previous.version) {
    return [makeDiagnostic(
      "NS1068",
      `app.zon's persistence version moved backward from ${previous.version} to ${version}.`,
      entry.fileName,
      line,
      column,
    )];
  }
  if (previous !== null && version === previous.version && fingerprint !== previous.model_fingerprint) {
    return [makeDiagnostic(
      "NS1068",
      `The checked Model shape changed while app.zon's persistence version stayed at ${version}.`,
      entry.fileName,
      line,
      column,
    )];
  }

  try {
    fs.mkdirSync(path.dirname(statePath), { recursive: true });
    const tmp = `${statePath}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, `${JSON.stringify({ version, model_fingerprint: fingerprint }, null, 2)}\n`);
    fs.renameSync(tmp, statePath);
  } catch {
    // This cache improves teaching only; runtime fingerprint validation stays
    // the hard safety gate when a filesystem is read-only.
  }
  return [];
}

export function checkSource(source: string, name = "core.ts", options: FrontendOptions = {}): FrontendResult {
  // Test seam: materialize an in-memory file through a temp path-less host.
  const tmp = path.join(process.env.TMPDIR ?? "/tmp", `native-core-${process.pid}-${Math.random().toString(36).slice(2)}.ts`);
  fs.writeFileSync(tmp, source);
  try {
    return checkFile(tmp, options);
  } finally {
    fs.unlinkSync(tmp);
  }
}

export { formatDiagnostic };
