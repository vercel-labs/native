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
import fs from "node:fs";

function main(argv: string[]): number {
  const args = argv.slice(2);
  let entry: string | null = null;
  let contractOut: string | null = null;
  let servicesContractOut: string | null = null;
  let contractEntry: string | null = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--contract") {
      contractOut = args[++i] ?? null;
    } else if (args[i] === "--services-contract") {
      servicesContractOut = args[++i] ?? null;
    } else if (args[i] === "--contract-entry") {
      contractEntry = args[++i] ?? null;
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
  const options: FrontendOptions = {
    // The document's entry spelling defaults to the argument's own,
    // POSIX separators (the sidecar/facade contract is platform-free).
    contractEntry: contractOut !== null ? (contractEntry ?? entry.split("\\").join("/")) : undefined,
    servicesContract: servicesContractOut !== null,
  };
  const result = checkFile(entry, options);
  for (const e of result.typeErrors) console.error(e);
  for (const d of result.diagnostics) console.error(formatDiagnostic(d));
  // Teaching notices (NS1028): printed, never failing the build.
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
  return 0;
}

process.exit(main(process.argv));
