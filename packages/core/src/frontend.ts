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
import { emitServiceContract, type ServicePackage } from "./service_contract.ts";
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
  /// Exact checked-in npm package facts from app.zon. Bare imports in the
  /// service class are accepted only when named here; the sidecar carries
  /// the same name/version/hash facts into the offline staging gate.
  readonly servicePackages?: readonly ServicePackage[];
  /// app.zon capabilities supplied by the build/check launcher. The core
  /// frontend stays manifest-format agnostic; it needs only declared names
  /// for capability-backed effect diagnostics.
  readonly capabilities?: readonly string[];
  /// app.zon permissions supplied beside capabilities. Core credential
  /// effects are refused unless the explicit runtime grant is present.
  readonly permissions?: readonly string[];
  /// Manifest schema version for engine-owned model persistence. When a
  /// state path is also supplied, the frontend remembers the last accepted
  /// version/fingerprint pair and warns if a shape moves without a bump.
  readonly persistVersion?: number;
  readonly persistStatePath?: string;
  /// app.zon's persistence restore routes, projected without manifest syntax
  /// so the frontend can validate them against the core's Msg union.
  readonly persistRoutes?: PersistRoutes;
  /// Generated @native-sdk/core surface carrying declared SQLite query
  /// constructors. Omitted for non-relational apps and direct checker tests.
  readonly sdkCorePath?: string;
}

export interface FrontendResult {
  readonly ok: boolean;
  /// The contract sidecar JSON, when options.contractEntry asked for it
  /// (null otherwise, and on any failed check).
  readonly contract: string | null;
  /// The non-deterministic service registry, or null when the app has no
  /// src/services modules (and on any failed check).
  readonly servicesContract: string | null;
  /// The generated typed-client module projected from the service sidecar.
  readonly servicesClient: string | null;
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
  const graph = resolveModuleGraph(
    entry,
    (options.servicePackages ?? []).map((packageEntry) => packageEntry.name),
    options.sdkCorePath,
  );
  if (graph.diagnostics.length > 0) {
    return { ok: false, contract: null, servicesContract: null, servicesClient: null, diagnostics: graph.diagnostics, warnings: [], typeErrors: [], inputs: [...graph.files] };
  }

  const loadProgramFiles = (program: ts.Program): {
    readonly files: ts.SourceFile[];
    readonly coreFiles: ts.SourceFile[];
    readonly serviceFiles: ts.SourceFile[];
    readonly serviceHostFiles: ts.SourceFile[];
  } | null => {
    const byPath = new Map(program.getSourceFiles().map((file) => [path.resolve(file.fileName), file]));
    const files = graph.files.map((file) => byPath.get(path.resolve(file))).filter((file): file is ts.SourceFile => file !== undefined);
    if (files.length !== graph.files.length) return null;
    const fileByPath = new Map(files.map((file) => [path.resolve(file.fileName), file]));
    return {
      files,
      coreFiles: graph.coreFiles.map((file) => fileByPath.get(path.resolve(file))!).filter(Boolean),
      serviceFiles: graph.serviceFiles.map((file) => fileByPath.get(path.resolve(file))!).filter(Boolean),
      serviceHostFiles: graph.serviceHostFiles.map((file) => fileByPath.get(path.resolve(file))!).filter(Boolean),
    };
  };

  let program = createSubsetProgram(entry, graph.files, new Map(), options.sdkCorePath);
  let loaded = loadProgramFiles(program);
  if (loaded === null || loaded.files.length === 0) {
    return { ok: false, contract: null, servicesContract: null, servicesClient: null, diagnostics: [], warnings: [], typeErrors: [`cannot read ${entry}`], inputs: [...graph.files] };
  }
  let tast = new TypedAst(program);
  let coreFiles = loaded.coreFiles;
  let serviceFiles = loaded.serviceFiles;
  let serviceHostFiles = loaded.serviceHostFiles;
  let table = new TypeTable(tast, coreFiles);
  let infer = new IntInference(tast, table, coreFiles);
  let serviceSurface = emitServiceContract(
    tast,
    table,
    infer,
    serviceFiles,
    serviceHostFiles,
    path.dirname(path.resolve(entry)),
    options.servicePackages ?? [],
  );
  if (serviceSurface.diagnostics.length > 0) {
    return { ok: false, contract: null, servicesContract: null, servicesClient: null, diagnostics: [...serviceSurface.diagnostics], warnings: [], typeErrors: [], inputs: [...graph.files] };
  }

  // The typed client is virtual during checking: authors import the stable
  // `@native-sdk/services` name, while builds stage this projection as
  // src/services.gen.ts. Rebuild the one provider program with that module
  // mapped at its logical src-root location; generated code is typechecked
  // but excluded from the authored core's NS walk.
  if (serviceSurface.client !== null) {
    const generatedPath = path.join(path.dirname(path.resolve(entry)), "services.gen.ts");
    program = createSubsetProgram(entry, graph.files, new Map([[generatedPath, serviceSurface.client]]), options.sdkCorePath);
    loaded = loadProgramFiles(program);
    if (loaded === null) {
      return { ok: false, contract: null, servicesContract: null, servicesClient: null, diagnostics: [], warnings: [], typeErrors: ["cannot materialize the generated service client"], inputs: [...graph.files] };
    }
    tast = new TypedAst(program);
    coreFiles = loaded.coreFiles;
    serviceFiles = loaded.serviceFiles;
    serviceHostFiles = loaded.serviceHostFiles;
    table = new TypeTable(tast, coreFiles);
    infer = new IntInference(tast, table, coreFiles);
    serviceSurface = emitServiceContract(
      tast,
      table,
      infer,
      serviceFiles,
      serviceHostFiles,
      path.dirname(path.resolve(entry)),
      options.servicePackages ?? [],
    );
    if (serviceSurface.diagnostics.length > 0) {
      return { ok: false, contract: null, servicesContract: null, servicesClient: null, diagnostics: [...serviceSurface.diagnostics], warnings: [], typeErrors: [], inputs: [...graph.files] };
    }
  }

  const typeErrors: string[] = [];
  // The provider catches ordinary shape/type errors in both classes before
  // either compile lane starts. Its declaration universe intentionally has
  // no Node/npm packages, so unresolved ambient service imports are deferred
  // to the pinned scriptc verdict and its static-tier coverage report.
  for (const file of [...coreFiles, ...serviceFiles]) {
    for (const d of tast.fileDiagnostics(file)) {
      if (d.category !== ts.DiagnosticCategory.Error) continue;
      if (serviceFiles.includes(file) && new Set([2304, 2307, 2503, 2580, 2591, 7016]).has(d.code)) continue;
      const where = d.file && d.start !== undefined ? lineColumn(d.file, d.start) : null;
      const msg = ts.flattenDiagnosticMessageText(d.messageText, "\n");
      const name = d.file?.fileName ?? file.fileName;
      typeErrors.push(where ? `${name}:${where.line}:${where.column} TS${d.code} ${msg}` : `TS${d.code} ${msg}`);
    }
  }
  if (typeErrors.length > 0) {
    return { ok: false, contract: null, servicesContract: null, servicesClient: null, diagnostics: [], warnings: [], typeErrors: [...new Set(typeErrors)], inputs: [...graph.files] };
  }

  if (infer.conflicts.length > 0) {
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
    return { ok: false, contract: null, servicesContract: null, servicesClient: null, diagnostics, warnings: [], typeErrors: [], inputs: [...graph.files] };
  }
  const serviceOps = serviceSurface.contract === null
    ? null
    : new Set(serviceSurface.operations.map((op) => op.name));
  const checker = new SubsetChecker(
    tast,
    table,
    coreFiles,
    serviceOps,
    options.capabilities ?? [],
    options.permissions ?? [],
    options.persistRoutes,
    options.sdkCorePath,
  );
  const checkResult = checker.check();
  if (checkResult.diagnostics.length > 0) {
    return { ok: false, contract: null, servicesContract: null, servicesClient: null, diagnostics: checkResult.diagnostics, warnings: checkResult.warnings, typeErrors: [], inputs: [...graph.files] };
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
    return { ok: true, contract, servicesContract: serviceSurface.contract, servicesClient: serviceSurface.client, diagnostics: [], warnings, typeErrors: [], inputs: [...graph.files] };
  } catch (e) {
    if (e instanceof ContractError) {
      const file = e.node.getSourceFile();
      const { line, column } = lineColumn(file, e.node.getStart());
      const d = makeDiagnostic("NS1063", `${e.message[0].toUpperCase()}${e.message.slice(1)}.`, file.fileName, line, column);
      return { ok: false, contract: null, servicesContract: null, servicesClient: null, diagnostics: [d], warnings: checkResult.warnings, typeErrors: [], inputs: [...graph.files] };
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
