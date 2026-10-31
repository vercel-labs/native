#!/usr/bin/env node
// scriptc's Node library API co-emits the profile's archive and contract
// sidecar for the SDK's byte-bearing contracts in one compile.

import path from "node:path";
import { pathToFileURL } from "node:url";
import { compilerApiEntry } from "./scriptc_toolchain.mjs";

async function main() {
  const args = process.argv.slice(2);
  if (![6, 8].includes(args.length) || args[0] !== "--profile" || args[2] !== "--out" || args[4] !== "--version") {
    console.error("usage: run_library_compiler.mjs --profile <profile.json> --out <archive> --version <exact-version>");
    return 2;
  }

  let compiler;
  try {
    compiler = await import(pathToFileURL(compilerApiEntry(args.length === 8 && args[6] === "--origin" ? args[7] : import.meta.url)));
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
