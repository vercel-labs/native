#!/usr/bin/env node
// @native-sdk/core: transpile an app-core subset TypeScript module to Zig.
//
//   native-core <entry.ts> -o <out.zig> [--frame-cap <bytes>] [--heap-cap <bytes>]
//
// --frame-cap / --heap-cap set the emitted core's rt kernel capacities (the
// frame arena and the per-space model heap) as comptime constants; omitted,
// the rt defaults apply.
//
// Exit codes: 0 emitted; 1 subset/type errors (teaching diagnostics on
// stderr); 2 usage.

import { transpileFile, formatDiagnostic, type TranspileOptions } from "./transpile.ts";
import fs from "node:fs";

function parseByteCount(flag: string, raw: string | undefined): number | null {
  const v = raw === undefined ? NaN : Number(raw);
  if (!Number.isSafeInteger(v) || v <= 0) {
    console.error(`${flag} needs a positive integer byte count, got ${raw ?? "<missing>"}`);
    return null;
  }
  return v;
}

function main(argv: string[]): number {
  const args = argv.slice(2);
  let entry: string | null = null;
  let out: string | null = null;
  let frameCap: number | undefined;
  let heapCap: number | undefined;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "-o" || args[i] === "--out") {
      out = args[++i] ?? null;
    } else if (args[i] === "--frame-cap") {
      const v = parseByteCount("--frame-cap", args[++i]);
      if (v === null) return 2;
      frameCap = v;
    } else if (args[i] === "--heap-cap") {
      const v = parseByteCount("--heap-cap", args[++i]);
      if (v === null) return 2;
      heapCap = v;
    } else if (!args[i].startsWith("-")) {
      entry = args[i];
    } else {
      console.error(`unknown flag ${args[i]}`);
      return 2;
    }
  }
  if (!entry) {
    console.error("usage: native-core <entry.ts> -o <out.zig> [--frame-cap <bytes>] [--heap-cap <bytes>]");
    return 2;
  }
  const options: TranspileOptions = { frameCap, heapCap };
  const result = transpileFile(entry, options);
  for (const e of result.typeErrors) console.error(e);
  for (const d of result.diagnostics) console.error(formatDiagnostic(d));
  // Teaching notices (NS1028): printed, never failing the build.
  for (const w of result.warnings) console.error(formatDiagnostic(w, "warning"));
  if (!result.ok || result.zig === null) return 1;
  if (out) {
    fs.writeFileSync(out, result.zig);
  } else {
    process.stdout.write(result.zig);
  }
  return 0;
}

process.exit(main(process.argv));
