// The two-class TypeScript module graph. The app core remains rooted at
// src/core.ts; every .ts file under src/services/ is an independent service
// root because a valid core never imports a service. Both classes share one
// checked TypeScript program, but only `coreFiles` enter the NS subset checker
// and integer inference.

import path from "node:path";
import fs from "node:fs";
import { ts, sdkCoreModulePath, sdkLibraryModules } from "./typed_ast.ts";
import { makeDiagnostic, type RuleId, type SubsetDiagnostic } from "./diagnostics.ts";

const serviceBuiltins = new Set([
  "fs", "node:fs", "path", "node:path", "process", "node:process", "os", "node:os",
  "child_process", "node:child_process",
]);

export type ModuleClass = "core" | "service";

export interface ModuleGraph {
  /// All program roots/modules in deterministic order: the entry graph first,
  /// followed by the lexically sorted service roots and their dependencies.
  readonly files: readonly string[];
  /// Files that retain the complete NS1001-NS1064 core posture. SDK library
  /// modules are included here, as they were before the service seam.
  readonly coreFiles: readonly string[];
  /// Author files under src/services/. The SubsetChecker never visits these.
  readonly serviceFiles: readonly string[];
  /// Author files that can enter the service executable: every service root
  /// plus its runtime-relative dependencies, including shared core-class
  /// modules. Throw validation and the service source fingerprint use this
  /// set rather than only the files physically under src/services/.
  readonly serviceHostFiles: readonly string[];
  readonly sdkFiles: ReadonlySet<string>;
  readonly diagnostics: SubsetDiagnostic[];
}

interface Edge {
  readonly specifier: string;
  readonly typeOnly: boolean;
  readonly node: ts.Node;
}

function edgesOf(file: ts.SourceFile): Edge[] {
  const out: Edge[] = [];
  for (const stmt of file.statements) {
    if (ts.isImportDeclaration(stmt) && ts.isStringLiteral(stmt.moduleSpecifier)) {
      out.push({ specifier: stmt.moduleSpecifier.text, typeOnly: stmt.importClause?.isTypeOnly ?? false, node: stmt });
    } else if (ts.isExportDeclaration(stmt) && stmt.moduleSpecifier && ts.isStringLiteral(stmt.moduleSpecifier)) {
      out.push({ specifier: stmt.moduleSpecifier.text, typeOnly: stmt.isTypeOnly, node: stmt });
    }
  }
  return out;
}

function tsFilesUnder(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  const out: string[] = [];
  const walk = (current: string): void => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const child = path.join(current, entry.name);
      if (entry.isDirectory()) walk(child);
      else if (entry.isFile() && entry.name.endsWith(".ts") && !entry.name.endsWith(".d.ts")) out.push(path.resolve(child));
    }
  };
  walk(dir);
  return out.sort((a, b) => a.localeCompare(b));
}

function diag(id: RuleId, site: string, file: ts.SourceFile, node: ts.Node): SubsetDiagnostic {
  const lc = file.getLineAndCharacterOfPosition(node.getStart(file));
  return makeDiagnostic(id, site, file.fileName, lc.line + 1, lc.character + 1);
}

/// Resolve the core graph plus every src/services/**/*.ts root. Class is a
/// path property, never inferred from which root happened to reach a file:
/// this is what makes a service->core shared-shape edge legal while a
/// core->service edge is NS1065.
export function resolveModuleGraph(entry: string): ModuleGraph {
  const entryPath = path.resolve(entry);
  const boundary = path.dirname(entryPath);
  const servicesBoundary = path.join(boundary, "services");
  const sdkBoundary = path.dirname(sdkCoreModulePath);
  const diagnostics: SubsetDiagnostic[] = [];
  const files: string[] = [];
  const coreFiles: string[] = [];
  const serviceFiles: string[] = [];
  const sdkFiles = new Set<string>();
  const runtimeEdges = new Map<string, string[]>();
  const done = new Set<string>();
  const visiting = new Set<string>();

  const insideBoundary = (p: string, root: string, includeRoot = false): boolean => {
    const rel = path.relative(root, p);
    return (includeRoot ? rel === "" : false) || (rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel));
  };
  const classOf = (p: string): ModuleClass => insideBoundary(p, servicesBoundary, true) ? "service" : "core";

  const follow = (
    target: string,
    edge: Edge,
    parsed: ts.SourceFile,
    from: string,
    trail: string[],
  ): void => {
    if (!edge.typeOnly) {
      const targets = runtimeEdges.get(from) ?? [];
      targets.push(target);
      runtimeEdges.set(from, targets);
    }
    if (visiting.has(target)) {
      if (!edge.typeOnly) {
        const names = [...trail, from, target].map((p) => path.basename(p));
        diagnostics.push(diag("NS1036", `\`import ... from "${edge.specifier}"\` closes a ${classOf(from)} import cycle (${names.join(" -> ")}).`, parsed, edge.node));
      }
      return;
    }
    visit(target, [...trail, from]);
  };

  const visit = (filePath: string, trail: string[]): void => {
    if (done.has(filePath) || visiting.has(filePath)) return;
    visiting.add(filePath);
    files.push(filePath);
    const fileClass = classOf(filePath);
    if (fileClass === "service") serviceFiles.push(filePath);
    else coreFiles.push(filePath);

    const text = fs.readFileSync(filePath, "utf8");
    const parsed = ts.createSourceFile(filePath, text, ts.ScriptTarget.ESNext, true);
    const isSdk = sdkFiles.has(filePath);
    const root = isSdk ? sdkBoundary : boundary;

    for (const edge of edgesOf(parsed)) {
      const spec = edge.specifier;

      // Services are ordinary static-tier TypeScript, but phase 1 stays
      // vendored-source-only: every bare specifier, including SDK modules,
      // gets the service-specific NS1066 teaching.
      if (fileClass === "service" && !spec.startsWith(".") && !serviceBuiltins.has(spec)) {
        diagnostics.push(diag("NS1066", `\`import ... from "${spec}"\` is a bare service import.`, parsed, edge.node));
        continue;
      }
      if (fileClass === "service" && serviceBuiltins.has(spec)) continue;

      if (spec === "@native-sdk/core") continue;
      if (sdkLibraryModules.has(spec)) {
        const target = path.resolve(sdkLibraryModules.get(spec)!);
        if (!fs.existsSync(target)) {
          diagnostics.push(diag("NS1037", `The SDK is missing \`${spec}\` (${target}) — is the checkout complete?`, parsed, edge.node));
          continue;
        }
        sdkFiles.add(target);
        follow(target, edge, parsed, filePath, trail);
        continue;
      }
      if (spec.startsWith("@native-sdk/")) {
        if (edge.typeOnly) continue;
        diagnostics.push(diag("NS1037", `\`${spec}\` names no SDK module (this SDK ships ${["@native-sdk/core", ...sdkLibraryModules.keys()].join(", ")}).`, parsed, edge.node));
        continue;
      }
      if (!spec.startsWith(".")) {
        if (edge.typeOnly) continue;
        diagnostics.push(diag("NS1035", `\`import ... from "${spec}"\` brings a runtime npm dependency into the core.`, parsed, edge.node));
        continue;
      }

      const resolved = path.resolve(path.dirname(filePath), spec);
      if (!insideBoundary(resolved, root) || path.isAbsolute(spec)) {
        diagnostics.push(diag("NS1034", `\`import ... from "${spec}"\` resolves outside ${isSdk ? "the SDK's module directory" : "the app's src/ directory"}.`, parsed, edge.node));
        continue;
      }
      if (!spec.endsWith(".ts")) {
        const withExt = `${resolved}.ts`;
        const hint = fs.existsSync(withExt)
          ? `\`import ... from "${spec}"\` omits the file extension (\`${spec}.ts\` exists).`
          : `\`import ... from "${spec}"\` names no .ts module file.`;
        diagnostics.push(diag("NS1037", hint, parsed, edge.node));
        continue;
      }
      if (!fs.existsSync(resolved)) {
        diagnostics.push(diag("NS1037", `\`import ... from "${spec}"\` names no file (looked for ${resolved}).`, parsed, edge.node));
        continue;
      }
      if (fileClass === "core" && classOf(resolved) === "service") {
        diagnostics.push(diag("NS1065", `\`import ... from "${spec}"\` crosses from the core into src/services/.`, parsed, edge.node));
        continue;
      }
      follow(resolved, edge, parsed, filePath, trail);
    }

    visiting.delete(filePath);
    done.add(filePath);
  };

  if (!fs.existsSync(entryPath)) return { files: [], coreFiles, serviceFiles, serviceHostFiles: [], sdkFiles, diagnostics };
  visit(entryPath, []);
  const serviceRoots = tsFilesUnder(servicesBoundary);
  for (const serviceRoot of serviceRoots) visit(serviceRoot, []);

  const serviceReachable = new Set<string>();
  const markServiceReachable = (filePath: string): void => {
    if (serviceReachable.has(filePath)) return;
    serviceReachable.add(filePath);
    for (const target of runtimeEdges.get(filePath) ?? []) markServiceReachable(target);
  };
  for (const serviceRoot of serviceRoots) markServiceReachable(serviceRoot);
  const serviceHostFiles = files.filter((filePath) =>
    serviceReachable.has(filePath) && insideBoundary(filePath, boundary, true)
  );
  return { files, coreFiles, serviceFiles, serviceHostFiles, sdkFiles, diagnostics };
}
