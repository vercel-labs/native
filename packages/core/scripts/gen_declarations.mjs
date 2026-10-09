#!/usr/bin/env node
// Generate the SDK's shipped declaration files (sdk/*.d.ts) from the
// author-visible modules with the real tsc — never hand-written. The
// npm package ships TS sources as its editor type surface (the exports
// map's `types` condition), and these generated declarations beside
// them so external tooling that consumes declaration files can resolve
// `@native-sdk/core` types without compiling the sources.
//
// The global Uint8Array augmentation (sdk/bytes_text_methods.d.ts) is
// deliberately NOT part of this program: the generated declarations
// must stay clean of ambient augmentations, which collide with other
// toolchains' own lib typings.
//
//   node scripts/gen_declarations.mjs          # (re)write sdk/*.d.ts
//   node scripts/gen_declarations.mjs --check  # verify freshness, no writes

import ts from "@typescript/old";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const sdkDir = path.join(pkg, "sdk");

/// The author-visible modules, in exports-map order.
export const declarationSources = ["core.ts", "bytes.ts", "text.ts", "events.ts", "theme.ts", "internal/image_identity.ts", "internal/markdown_policy.ts"];

/// Generate declaration text per output file name (relative to sdk/),
/// entirely in memory.
export function generateDeclarations() {
  const roots = declarationSources.map((f) => path.join(sdkDir, f));
  const options = {
    // The checker's own environment (typed_ast.ts subsetCompilerOptions),
    // minus the app-side plumbing: strict, modern lib, TS-extension
    // imports rewritten so the emitted declarations resolve as files.
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
  const program = ts.createProgram(roots, options);
  const diagnostics = ts.getPreEmitDiagnostics(program).filter((d) => d.category === ts.DiagnosticCategory.Error);
  if (diagnostics.length > 0) {
    const text = diagnostics
      .map((d) => `TS${d.code} ${ts.flattenDiagnosticMessageText(d.messageText, "\n")}`)
      .join("\n");
    throw new Error(`the SDK sources do not typecheck for declaration emit:\n${text}`);
  }
  const outputs = new Map();
  const result = program.emit(undefined, (fileName, text) => {
    // Declaration emit preserves the sources' `.ts` relative specifiers;
    // spell them `.js` (the declaration ecosystem's convention — tsc
    // resolves `./text.js` to the shipped `./text.d.ts`), so consumers
    // that read declarations never fall through to the sources.
    const rewritten = text.replace(/(from\s+")(\.\.?\/[^"]+)\.ts(")/g, "$1$2.js$3");
    outputs.set(path.relative(sdkDir, fileName), rewritten);
  });
  if (result.emitSkipped) throw new Error("declaration emit was skipped");
  for (const source of declarationSources) {
    const name = source.replace(/\.ts$/, ".d.ts");
    if (!outputs.has(name)) throw new Error(`declaration emit produced no ${name}`);
    if (/declare\s+global|interface\s+Uint8Array/.test(outputs.get(name))) {
      throw new Error(`${name} carries a global augmentation — the generated declarations must stay ambient-clean`);
    }
  }
  return outputs;
}

function main(check) {
  const outputs = generateDeclarations();
  let stale = false;
  for (const [name, text] of outputs) {
    const outPath = path.join(sdkDir, name);
    const current = fs.existsSync(outPath) ? fs.readFileSync(outPath, "utf8") : null;
    if (current === text) continue;
    if (check) {
      stale = true;
      console.error(`${path.relative(pkg, outPath)} is stale — run \`node scripts/gen_declarations.mjs\``);
    } else {
      fs.mkdirSync(path.dirname(outPath), { recursive: true });
      fs.writeFileSync(outPath, text);
      console.error(`wrote ${path.relative(pkg, outPath)}`);
    }
  }
  process.exit(stale ? 1 : 0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.includes("--check"));
}
