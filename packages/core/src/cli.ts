#!/usr/bin/env node
// @native-sdk/core: check an app-core subset TypeScript module and emit
// its contract sidecar. The external core compiler does the compiling;
// this CLI is the frontend — the subset's teaching surface and the
// contract source.
//
//   native-core <entry.ts> [--contract <out.contract.json>] [--services-contract <services.contract.json>]
//
// --contract writes the contract sidecar (core.contract.json, schema
// format 1) emitted directly from the checked program — the document the
// external core compiler's projections consume. --contract-entry sets the
// entry spelling the document states (default: the entry argument as
// given, POSIX separators).
//
// Exit codes: 0 checked (and contract written when asked); 1 subset/type
// errors (teaching diagnostics on stderr); 2 usage.

import { checkFile, formatDiagnostic, type FrontendOptions } from "./frontend.ts";
import type { ServicePackage } from "./service_contract.ts";
import fs from "node:fs";
import path from "node:path";
import ts from "@typescript/old";

function main(argv: string[]): number {
  const args = argv.slice(2);
  let entry: string | null = null;
  let contractOut: string | null = null;
  let servicesContractOut: string | null = null;
  let servicesClientOut: string | null = null;
  let servicesEditorClientOut: string | null = null;
  let contractEntry: string | null = null;
  let persistVersion: number | null = null;
  let persistStatePath: string | null = null;
  let persistOk: string | null = null;
  let persistNone: string | null = null;
  let persistErr: string | null = null;
  let sdkCorePath: string | null = null;
  const capabilities: string[] = [];
  const permissions: string[] = [];
  const servicePackages: ServicePackage[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--contract") {
      contractOut = args[++i] ?? null;
    } else if (args[i] === "--services-contract") {
      servicesContractOut = args[++i] ?? null;
    } else if (args[i] === "--services-client") {
      servicesClientOut = args[++i] ?? null;
    } else if (args[i] === "--services-editor-client") {
      servicesEditorClientOut = args[++i] ?? null;
    } else if (args[i] === "--service-package") {
      const spelling = args[++i] ?? "";
      const [name, version, content_hash, extra] = spelling.split("|");
      if (!/^(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+$/i.test(name ?? "") || !/^\d+\.\d+\.\d+$/.test(version ?? "") || !/^[0-9a-f]{64}$/.test(content_hash ?? "") || extra !== undefined) {
        console.error("--service-package requires name|exact-version|64-hex-content-hash");
        return 2;
      }
      servicePackages.push({ name, version, content_hash });
    } else if (args[i] === "--contract-entry") {
      contractEntry = args[++i] ?? null;
    } else if (args[i] === "--capability") {
      const capability = args[++i] ?? null;
      if (capability === null) {
        console.error("--capability requires a name");
        return 2;
      }
      capabilities.push(capability);
    } else if (args[i] === "--permission") {
      const permission = args[++i] ?? null;
      if (permission === null) {
        console.error("--permission requires a name");
        return 2;
      }
      permissions.push(permission);
    } else if (args[i] === "--persist-version") {
      const spelling = args[++i] ?? "";
      const version = Number(spelling);
      if (!Number.isSafeInteger(version) || version <= 0) {
        console.error("--persist-version requires a positive safe integer");
        return 2;
      }
      persistVersion = version;
    } else if (args[i] === "--persist-state") {
      persistStatePath = args[++i] ?? null;
      if (persistStatePath === null) {
        console.error("--persist-state requires a path");
        return 2;
      }
    } else if (args[i] === "--persist-ok") {
      persistOk = args[++i] ?? null;
      if (persistOk === null) {
        console.error("--persist-ok requires a Msg arm name");
        return 2;
      }
    } else if (args[i] === "--persist-none") {
      persistNone = args[++i] ?? null;
      if (persistNone === null) {
        console.error("--persist-none requires a Msg arm name");
        return 2;
      }
    } else if (args[i] === "--persist-err") {
      persistErr = args[++i] ?? null;
      if (persistErr === null) {
        console.error("--persist-err requires a Msg arm name");
        return 2;
      }
    } else if (args[i] === "--sdk-core") {
      sdkCorePath = args[++i] ?? null;
      if (sdkCorePath === null) {
        console.error("--sdk-core requires a generated core.ts path");
        return 2;
      }
    } else if (args[i] === "-o" || args[i] === "--out") {
      console.error(
        "-o named the removed TS-to-Zig emitter (v0.7.0 removed it): TypeScript cores compile through the external core compiler now, and this CLI checks the core and emits its contract sidecar (--contract). Drop the flag.",
      );
      return 2;
    } else if (!args[i].startsWith("-")) {
      entry = args[i];
    } else {
      console.error(`unknown flag ${args[i]}`);
      return 2;
    }
  }
  if (!entry) {
    console.error(
      "usage: native-core <entry.ts> [--contract <out.contract.json>] [--services-contract <services.contract.json>] [--contract-entry <spelling>]",
    );
    return 2;
  }
  const persistRouteCount = [persistOk, persistNone, persistErr].filter((route) => route !== null).length;
  if (persistRouteCount !== 0 && persistRouteCount !== 3) {
    console.error("--persist-ok, --persist-none, and --persist-err must be provided together");
    return 2;
  }
  const persistRoutes =
    persistOk !== null && persistNone !== null && persistErr !== null
      ? { ok: persistOk, none: persistNone, err: persistErr }
      : undefined;
  const options: FrontendOptions = {
    // The document's entry spelling defaults to the argument's own,
    // POSIX separators (the sidecar/facade contract is platform-free).
    contractEntry: contractOut !== null ? (contractEntry ?? entry.split("\\").join("/")) : undefined,
    servicesContract: servicesContractOut !== null,
    servicePackages,
    capabilities,
    permissions,
    persistVersion: persistVersion ?? undefined,
    persistStatePath: persistStatePath ?? undefined,
    persistRoutes,
    sdkCorePath: sdkCorePath ?? undefined,
  };
  const result = checkFile(entry, options);
  for (const e of result.typeErrors) console.error(e);
  for (const d of result.diagnostics) console.error(formatDiagnostic(d));
  // Teaching notices: printed, never failing the build.
  for (const w of result.warnings) console.error(formatDiagnostic(w, "warning"));
  if (!result.ok) return 1;
  if (contractOut !== null) {
    if (result.contract === null) {
      console.error("internal: the check produced no contract sidecar");
      return 1;
    }
    fs.writeFileSync(contractOut, result.contract);
  }
  if (servicesContractOut !== null) {
    if (result.servicesContract === null) {
      console.error("the app has no src/services/**/*.ts modules, so there is no service contract to emit");
      return 1;
    }
    fs.writeFileSync(servicesContractOut, result.servicesContract);
  }
  if (servicesClientOut !== null) {
    if (result.servicesClient === null) {
      console.error("the app has no src/services/**/*.ts modules, so there is no typed service client to emit");
      return 1;
    }
    fs.writeFileSync(servicesClientOut, result.servicesClient);
  }
  if (servicesEditorClientOut !== null) {
    if (result.servicesClient === null) {
      console.error("the app has no src/services/**/*.ts modules, so there is no typed service client to emit");
      return 1;
    }
    const editorDir = path.dirname(servicesEditorClientOut);
    fs.mkdirSync(editorDir, { recursive: true });
    const sourcePrefix = path.relative(path.resolve(editorDir), path.dirname(path.resolve(entry))).split(path.sep).join("/");
    const editorSource = result.servicesClient.replaceAll('from "./', `from "${sourcePrefix}/`);
    fs.writeFileSync(servicesEditorClientOut, editorSource);
    const declaration = ts.transpileDeclaration(editorSource, {
      fileName: "index.ts",
      compilerOptions: { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.ESNext },
      reportDiagnostics: true,
    });
    if (declaration.diagnostics?.some((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error)) {
      console.error("internal: the generated editor service client could not emit declarations");
      return 1;
    }
    fs.writeFileSync(`${editorDir}/index.d.ts`, declaration.outputText);
    fs.writeFileSync(`${editorDir}/package.json`, `${JSON.stringify({
      name: "@native-sdk/services",
      private: true,
      type: "module",
      types: "./index.d.ts",
      exports: { ".": { types: "./index.d.ts", default: "./index.ts" } },
    }, null, 2)}\n`);
  }
  return 0;
}

process.exit(main(process.argv));
