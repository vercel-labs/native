#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import ts from "@typescript/old";
import { analyzeSqlite, checkMigrationState, formatSqliteDiagnostic, generateCoreSurface, generateMigrationsZig } from "./sqlite_codegen.ts";

function argsOf(argv: string[]): Map<string, string> {
  const out = new Map<string, string>();
  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i] ?? "";
    const value = argv[i + 1];
    if (!key.startsWith("--") || value === undefined) throw new Error("expected --name value arguments");
    out.set(key.slice(2), value);
  }
  return out;
}

try {
  const args = argsOf(process.argv);
  const src = args.get("src") ?? path.resolve("src");
  const sdkIn = args.get("sdk-in");
  const staticIn = args.get("static-in");
  const sdkOut = args.get("sdk-out");
  const staticOut = args.get("static-out");
  const zigOut = args.get("zig-out");
  const metadataOut = args.get("metadata-out");
  const dtsOut = args.get("dts-out");
  const state = args.get("state");
  if (!zigOut) throw new Error("usage: sqlite_cli.ts --src <src> --zig-out <file> [--sdk-in <core.ts> --static-in <core.ts> --sdk-out <file> --static-out <file> --metadata-out <file>] [--state <file>]");
  const surfaceArgs = [sdkIn, staticIn, sdkOut, staticOut];
  const emitsSurface = surfaceArgs.every((value) => value !== undefined);
  if (!emitsSurface && surfaceArgs.some((value) => value !== undefined)) throw new Error("SQLite SDK generation requires --sdk-in, --static-in, --sdk-out, and --static-out together");
  const analysis = analyzeSqlite(src);
  const diagnostics = [...analysis.diagnostics, ...(state ? checkMigrationState(analysis, state) : [])];
  for (const diagnostic of [...diagnostics, ...analysis.warnings]) console.error(formatSqliteDiagnostic(diagnostic));
  if (diagnostics.length > 0) process.exit(1);
  if (emitsSurface) {
    const sdkSource = generateCoreSurface(fs.readFileSync(sdkIn!, "utf8"), analysis);
    fs.writeFileSync(sdkOut!, sdkSource);
    if (dtsOut) {
      const compilerOptions: ts.CompilerOptions = {
        strict: true,
        exactOptionalPropertyTypes: true,
        target: ts.ScriptTarget.ESNext,
        module: ts.ModuleKind.ESNext,
        moduleResolution: ts.ModuleResolutionKind.Bundler,
        lib: ["lib.esnext.d.ts"],
        types: [],
        allowImportingTsExtensions: true,
        rewriteRelativeImportExtensions: true,
        declaration: true,
        emitDeclarationOnly: true,
        skipLibCheck: false,
      };
      const input = path.resolve(sdkIn!);
      const host = ts.createCompilerHost(compilerOptions);
      const getSourceFile = host.getSourceFile.bind(host);
      host.getSourceFile = (fileName, languageVersion, onError, shouldCreateNewSourceFile) =>
        path.resolve(fileName) === input
          ? ts.createSourceFile(fileName, sdkSource, languageVersion, true)
          : getSourceFile(fileName, languageVersion, onError, shouldCreateNewSourceFile);
      let output = "";
      host.writeFile = (fileName, text) => {
        if (fileName.endsWith("core.d.ts")) output = text;
      };
      const program = ts.createProgram([input], compilerOptions, host);
      const errors = ts
        .getPreEmitDiagnostics(program)
        .filter((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error);
      if (errors.length > 0) {
        throw new Error(
          errors
            .map(
              (diagnostic) =>
                `TS${diagnostic.code} ${ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n")}`,
            )
            .join("\n"),
        );
      }
      const emit = program.emit();
      if (emit.emitSkipped || output.length === 0) {
        throw new Error("generated SQLite SDK declaration emit failed");
      }
      fs.writeFileSync(dtsOut, output.replace(/(from\s+")(\.\.?\/[^\"]+)\.ts(\")/g, "$1$2.js$3"));
    }
    fs.writeFileSync(staticOut!, generateCoreSurface(fs.readFileSync(staticIn!, "utf8"), analysis));
  }
  fs.writeFileSync(zigOut, generateMigrationsZig(analysis));
  if (metadataOut) fs.writeFileSync(metadataOut, `${JSON.stringify({ format: 1, schema_hash: analysis.schemaHash, migrations: analysis.migrations.map(({ version, name, hash }) => ({ version, name, hash })), queries: analysis.queries }, null, 2)}\n`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(2);
}
