#!/usr/bin/env node
// Scriptc 0.2.0's Node library API keeps the profile's archive and contract
// sidecar in one compile. The installed native command has a self-hosted
// union-conversion bug in this sidecar path for byte-bearing SDK contracts.

import path from "node:path";

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 6 || args[0] !== "--profile" || args[2] !== "--out" || args[4] !== "--version") {
    console.error("usage: run_library_compiler.mjs --profile <profile.json> --out <archive> --version <exact-version>");
    return 2;
  }

  let compiler;
  try {
    compiler = await import("@scriptc/compiler");
  } catch (error) {
    console.error(`the pinned @scriptc/compiler package is missing: ${error instanceof Error ? error.message : String(error)} — reinstall @native-sdk/cli or run npm ci in packages/core`);
    return 2;
  }
  const version = compiler.compilerReleaseVersion();
  if (version !== args[5]) {
    console.error(`the library compiler package reports ${version}, but the SDK pins ${args[5]}`);
    return 2;
  }

  const output = path.resolve(args[3]);
  try {
    const result = await compiler.compileLibrary({
      profilePath: path.resolve(args[1]),
      outDir: path.dirname(output),
      outPath: output,
    });
    if (!result.ok) {
      console.error(compiler.renderDiagnostics(result.diagnostics, result.sourceTexts));
      return 1;
    }
    if (!result.sidecarPath) {
      console.error("the library compiler produced no contract sidecar");
      return 1;
    }
    return 0;
  } catch (error) {
    console.error(`the library compiler failed: ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
}

process.exitCode = await main();
