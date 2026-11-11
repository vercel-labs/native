#!/usr/bin/env node
// scriptc's Node library API co-emits the profile's archive and contract
// sidecar for the SDK's byte-bearing contracts in one compile. A standalone
// invocation (the fixture driver) also completes the archive with the runtime
// unit a release's library flavor can omit; the external core driver runs that
// same step itself, so its --origin invocation leaves the archive alone.

import path from "node:path";
import { pathToFileURL } from "node:url";
import { compilerApiEntry, completeLibraryArchive } from "./scriptc_toolchain.mjs";

const usage = "usage: run_library_compiler.mjs --profile <profile.json> --out <archive> --version <exact-version> [--origin <packages/core/package.json>] [--zig-exe <path>]";

async function main() {
  const args = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    const key = process.argv[i];
    const value = process.argv[i + 1];
    if (!["--profile", "--out", "--version", "--origin", "--zig-exe"].includes(key) || value === undefined) {
      console.error(usage);
      return 2;
    }
    args[key.slice(2)] = value;
  }
  if (args.profile === undefined || args.out === undefined || args.version === undefined) {
    console.error(usage);
    return 2;
  }

  let compiler;
  try {
    compiler = await import(pathToFileURL(compilerApiEntry(args.origin ?? import.meta.url)));
  } catch (error) {
    console.error(`the pinned @scriptc/compiler package is missing: ${error instanceof Error ? error.message : String(error)} — reinstall @native-sdk/cli or run npm ci in packages/core`);
    return 2;
  }
  const version = compiler.compilerReleaseVersion();
  if (version !== args.version) {
    console.error(`the library compiler package reports ${version}, but the SDK pins ${args.version}`);
    return 2;
  }

  const profile = path.resolve(args.profile);
  const output = path.resolve(args.out);
  try {
    const result = await compiler.compileLibrary({
      profilePath: profile,
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
  } catch (error) {
    console.error(`the library compiler failed: ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
  if (args.origin === undefined) {
    try {
      completeLibraryArchive(output, {
        origin: import.meta.url,
        profile,
        targetPlatform: process.env.SCRIPTC_TARGET || undefined,
        zigExe: args["zig-exe"],
      });
    } catch (error) {
      console.error(`the compiled core archive could not be completed: ${error instanceof Error ? error.message : String(error)}`);
      return 1;
    }
  }
  return 0;
}

process.exitCode = await main();
