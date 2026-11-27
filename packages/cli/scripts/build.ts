// Builds dist/, the JavaScript the published `native` command runs. Node runs a checkout's
// TypeScript directly, but it won't strip the types of a file under node_modules, which is where
// an installed CLI lives. So the compiler, with the shared modules it imports, is bundled into one
// file. runtime/, shared/ and host/ ship as source, which scriptc and the C compiler build into
// every app.
//
// dist/native.js sits one directory below the package root, as compiler/cli.ts does, so the paths
// the compiler finds from its own file (the runtime, the host, scriptc) are the same in both.

import { build } from "esbuild";
import { copyFileSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");

// Only this build's own files: dist/ also holds the native executable and the npm packages
// scripts/build-native.ts and scripts/pack.ts write there.
for (const name of ["native.js", "testharness.js"]) rmSync(join(dist, name), { force: true });
mkdirSync(dist, { recursive: true });
await build({
  entryPoints: [join(root, "compiler", "cli.ts")],
  outfile: join(dist, "native.js"),
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node24",
  packages: "external",
  logLevel: "warning",
});
// The WPT shim compile.ts reads from beside its own file.
copyFileSync(join(root, "compiler", "testharness.js"), join(dist, "testharness.js"));
