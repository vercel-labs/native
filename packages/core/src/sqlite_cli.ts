#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { analyzeSqlite, checkMigrationState, formatSqliteDiagnostic, generateCoreDeclarations, generateCoreSurface, generateMigrationsZig } from "./sqlite_codegen.ts";

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
  const sdkEventsOut = args.get("sdk-events-out");
  const sdkTextOut = args.get("sdk-text-out");
  const sdkBytesTextMethodsOut = args.get("sdk-bytes-text-methods-out");
  const sdkEventsDtsOut = args.get("sdk-events-dts-out");
  const sdkTextDtsOut = args.get("sdk-text-dts-out");
  const staticOut = args.get("static-out");
  const zigOut = args.get("zig-out");
  const metadataOut = args.get("metadata-out");
  const dtsOut = args.get("dts-out");
  const state = args.get("state");
  if (!zigOut) throw new Error("usage: sqlite_cli.ts --src <src> --zig-out <file> [--sdk-in <core.ts> --static-in <core.ts> --sdk-out <file> --static-out <file> --metadata-out <file>] [--state <file>]");
  const surfaceArgs = [
    sdkIn, staticIn, sdkOut, staticOut,
    sdkEventsOut, sdkTextOut, sdkBytesTextMethodsOut, sdkEventsDtsOut, sdkTextDtsOut,
  ];
  const emitsSurface = surfaceArgs.every((value) => value !== undefined);
  if (!emitsSurface && surfaceArgs.some((value) => value !== undefined)) {
    throw new Error("SQLite SDK generation requires its core, static, and SDK sibling outputs together");
  }
  const analysis = analyzeSqlite(src);
  const diagnostics = [...analysis.diagnostics, ...(state ? checkMigrationState(analysis, state) : [])];
  for (const diagnostic of [...diagnostics, ...analysis.warnings]) console.error(formatSqliteDiagnostic(diagnostic));
  if (diagnostics.length > 0) process.exit(1);
  if (emitsSurface) {
    const sdkSource = generateCoreSurface(fs.readFileSync(sdkIn!, "utf8"), analysis);
    fs.writeFileSync(sdkOut!, sdkSource);
    const sdkDir = path.dirname(sdkIn!);
    // Generated core surfaces retain these relative SDK imports. Carry
    // their complete implementation and declaration siblings with each
    // projection, including the editor's app-specific relational overlay.
    const siblingDirs = new Set([path.dirname(sdkOut!), path.dirname(staticOut!), ...(dtsOut ? [path.dirname(dtsOut)] : [])]);
    for (const destination of siblingDirs) for (const name of ["bytes", "events", "text", "theme", "internal/image_identity", "internal/markdown_policy"]) {
      for (const extension of [".ts", ".d.ts"]) {
        const output = path.join(destination, name + extension);
        fs.mkdirSync(path.dirname(output), { recursive: true });
        fs.copyFileSync(path.join(sdkDir, name + extension), output);
      }
    }
    for (const [source, destination] of [
      ["events.ts", sdkEventsOut!],
      ["text.ts", sdkTextOut!],
      ["bytes_text_methods.d.ts", sdkBytesTextMethodsOut!],
      ["events.d.ts", sdkEventsDtsOut!],
      ["text.d.ts", sdkTextDtsOut!],
    ] as const) {
      fs.copyFileSync(path.join(sdkDir, source), destination);
    }
    if (dtsOut) {
      const declarations = fs.readFileSync(path.join(sdkDir, "core.d.ts"), "utf8");
      fs.writeFileSync(dtsOut, generateCoreDeclarations(fs.readFileSync(sdkIn!, "utf8"), declarations, analysis));
    }
    fs.writeFileSync(staticOut!, generateCoreSurface(fs.readFileSync(staticIn!, "utf8"), analysis));
  }
  fs.writeFileSync(zigOut, generateMigrationsZig(analysis));
  if (metadataOut) fs.writeFileSync(metadataOut, `${JSON.stringify({ format: 1, schema_hash: analysis.schemaHash, migrations: analysis.migrations.map(({ version, name, hash }) => ({ version, name, hash })), queries: analysis.queries }, null, 2)}\n`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(2);
}
