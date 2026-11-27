// The portable inline-SVG filter engine's bounds: builds tests/svg-filter-test.c with the address
// and undefined-behaviour sanitizers and runs it, so a primitive whose subregion falls outside
// the filter region can never write before or after the engine's heap buffer.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-svg-filter-"));
const exe = join(dir, "svg-filter-test");

const cc = spawnSync("cc", [
  "-O1", "-g", "-Wall",
  "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
  "-I", "host",
  "-o", exe,
  "tests/svg-filter-test.c",
  "host/svg-filter.c",
  "-lm",
], { stdio: "inherit" });
if (cc.status !== 0) {
  console.error("native: could not build the SVG filter bounds test (a C compiler and its sanitizer runtime are needed)");
  process.exit(1);
}

const run = spawnSync(exe, [], {
  stdio: "inherit",
  env: { ...process.env, ASAN_OPTIONS: "detect_leaks=0:abort_on_error=1", UBSAN_OPTIONS: "halt_on_error=1" },
});
process.exit(run.status ?? 1);
