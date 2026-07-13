// The core's import graph: which .ts files make up one app core, resolved
// from src/core.ts BEFORE the type-checked program is built, so every
// module-boundary mistake is a teaching diagnostic (NS1034-NS1037) instead
// of a raw tsc resolution error.
//
// The boundary rules (spec: "src/ is the boundary"):
//   - "@native-sdk/core" is the intrinsic SDK surface — typed, never emitted.
//   - "@native-sdk/core/<lib>" names a shipped SDK library module (subset
//     TypeScript, transpiled into the core when imported — module-granular
//     tree-shaking falls out of walking the graph from the entry).
//   - "./x.ts" (and "./sub/x.ts") resolve inside the ENTRY MODULE'S
//     directory subtree — its src/. Escaping it (../, absolute paths) is
//     NS1034; bare npm specifiers are NS1035; a specifier that names no
//     file is NS1037.
//   - Runtime import cycles are NS1036. Type-only edges (`import type`,
//     `export type`) are exempt — they erase under node and constrain no
//     emission order — but still pull their target into the graph, because
//     its type declarations must exist in the emitted module.
//
// The returned file list is the canonical module order everywhere
// downstream (type table, checker, inference, emission): the entry first,
// then its imports depth-first in source order — deterministic, so emitted
// output is stable across runs.

import path from "node:path";
import fs from "node:fs";
import { ts, sdkCoreModulePath, sdkLibraryModules } from "./typed_ast.ts";
import { makeDiagnostic, type SubsetDiagnostic } from "./diagnostics.ts";

export interface ModuleGraph {
  /// Absolute paths in module order: the entry first, then imports
  /// depth-first. Includes imported SDK library modules; never sdk/core.ts.
  readonly files: readonly string[];
  /// The subset of `files` that are SDK library modules (checker
  /// diagnostics inside these are SDK bugs, not app bugs).
  readonly sdkFiles: ReadonlySet<string>;
  readonly diagnostics: SubsetDiagnostic[];
}

interface Edge {
  readonly specifier: string;
  readonly typeOnly: boolean;
  readonly node: ts.Node;
}

/// Import/re-export edges of one parsed file, in source order.
function edgesOf(file: ts.SourceFile): Edge[] {
  const out: Edge[] = [];
  for (const stmt of file.statements) {
    if (ts.isImportDeclaration(stmt) && ts.isStringLiteral(stmt.moduleSpecifier)) {
      out.push({
        specifier: stmt.moduleSpecifier.text,
        typeOnly: stmt.importClause?.isTypeOnly ?? false,
        node: stmt,
      });
    } else if (ts.isExportDeclaration(stmt) && stmt.moduleSpecifier && ts.isStringLiteral(stmt.moduleSpecifier)) {
      out.push({ specifier: stmt.moduleSpecifier.text, typeOnly: stmt.isTypeOnly, node: stmt });
    }
  }
  return out;
}

function diag(
  id: "NS1034" | "NS1035" | "NS1036" | "NS1037",
  site: string,
  file: ts.SourceFile,
  node: ts.Node,
): SubsetDiagnostic {
  const lc = file.getLineAndCharacterOfPosition(node.getStart(file));
  return makeDiagnostic(id, site, file.fileName, lc.line + 1, lc.character + 1);
}

/// Walk the import graph from `entry` (absolute or cwd-relative path).
/// Reads and parses each file once — no type checking here; the caller
/// builds the checked program only when the graph is clean.
export function resolveModuleGraph(entry: string): ModuleGraph {
  const entryPath = path.resolve(entry);
  const boundary = path.dirname(entryPath);
  const sdkBoundary = path.dirname(sdkCoreModulePath);
  const diagnostics: SubsetDiagnostic[] = [];
  const files: string[] = [];
  const sdkFiles = new Set<string>();
  const visiting = new Set<string>(); // DFS stack for runtime-cycle detection
  const done = new Set<string>();

  const insideBoundary = (p: string, root: string): boolean => {
    const rel = path.relative(root, p);
    return rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel);
  };

  const visit = (filePath: string, fromCycleTrail: string[]): void => {
    if (done.has(filePath)) return;
    if (visiting.has(filePath)) return; // a cycle is reported at its back-edge
    visiting.add(filePath);
    files.push(filePath);

    const text = fs.readFileSync(filePath, "utf8");
    const parsed = ts.createSourceFile(filePath, text, ts.ScriptTarget.ESNext, true);
    const isSdk = sdkFiles.has(filePath);
    const root = isSdk ? sdkBoundary : boundary;

    for (const edge of edgesOf(parsed)) {
      const spec = edge.specifier;
      if (spec === "@native-sdk/core") continue; // the intrinsic surface — typed, never emitted
      if (sdkLibraryModules.has(spec)) {
        const target = path.resolve(sdkLibraryModules.get(spec)!);
        if (!fs.existsSync(target)) {
          diagnostics.push(diag("NS1037", `The SDK is missing \`${spec}\` (${target}) — is the checkout complete?`, parsed, edge.node));
          continue;
        }
        sdkFiles.add(target);
        follow(target, edge, parsed, filePath, fromCycleTrail);
        continue;
      }
      if (spec.startsWith("@native-sdk/")) {
        if (edge.typeOnly) continue;
        diagnostics.push(diag(
          "NS1037",
          `\`${spec}\` names no SDK module (this SDK ships ${["@native-sdk/core", ...sdkLibraryModules.keys()].join(", ")}).`,
          parsed,
          edge.node,
        ));
        continue;
      }
      if (!spec.startsWith(".")) {
        if (edge.typeOnly) continue; // type-only npm imports erase — free
        diagnostics.push(diag("NS1035", `\`import ... from "${spec}"\` brings a runtime npm dependency into the core.`, parsed, edge.node));
        continue;
      }
      // A relative specifier: resolve against the importing file.
      const resolved = path.resolve(path.dirname(filePath), spec);
      if (!insideBoundary(resolved, root) || path.isAbsolute(spec)) {
        diagnostics.push(diag("NS1034", `\`import ... from "${spec}"\` resolves outside ${isSdk ? "the SDK's module directory" : "the core's src/ directory"}.`, parsed, edge.node));
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
      follow(resolved, edge, parsed, filePath, fromCycleTrail);
    }

    visiting.delete(filePath);
    done.add(filePath);
  };

  const follow = (target: string, edge: Edge, parsed: ts.SourceFile, from: string, trail: string[]): void => {
    if (visiting.has(target)) {
      // A back-edge. Runtime cycles are taught; type-only ones erase.
      if (!edge.typeOnly) {
        const names = [...trail, from, target].map((p) => path.basename(p));
        diagnostics.push(diag("NS1036", `\`import ... from "${edge.specifier}"\` closes an import cycle (${names.join(" -> ")}).`, parsed, edge.node));
      }
      return;
    }
    visit(target, [...trail, from]);
  };

  if (!fs.existsSync(entryPath)) {
    // The caller reports the unreadable entry itself.
    return { files: [], sdkFiles, diagnostics };
  }
  visit(entryPath, []);
  return { files, sdkFiles, diagnostics };
}
