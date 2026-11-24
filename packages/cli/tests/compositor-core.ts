// The compositor core: builds the C tests — the software backend and frame composites, and the
// layerization and tiling logic — and runs them, so a regression in a layer's state, damage, a
// quad's pixels or the grouping rule fails the suite.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-compositor-"));

function build(exe: string, sources: string[], extra: string[]): void {
  const cc = spawnSync("cc", [
    "-O2", "-Wall",
    "-I", "host/compositor",
    "-o", exe,
    ...sources,
    ...extra,
  ], { stdio: "inherit" });
  if (cc.status !== 0) {
    console.error(`native: could not build ${exe}`);
    process.exit(1);
  }
}

function run(exe: string): void {
  const r = spawnSync(exe, [], { stdio: "inherit" });
  if (r.status !== 0) process.exit(1);
}

const pkg = spawnSync("pkg-config", ["--cflags", "--libs", "cairo"], { encoding: "utf8" });
if (pkg.status !== 0) {
  console.error("native: the compositor test needs Cairo's development files (libcairo2-dev)");
  process.exit(1);
}
const cairo = pkg.stdout.trim().split(/\s+/).filter(Boolean);

const software = join(dir, "compositor-test");
build(software, [
  "tests/compositor-test.c",
  "host/compositor/compositor.c",
  "host/compositor/software.c",
], [...cairo, "-lm"]);
run(software);

const layers = join(dir, "compositor-layers-test");
build(layers, [
  "tests/compositor-layers-test.c",
  "host/compositor/layers.c",
  "host/compositor/tiles.c",
  "host/compositor/chunks.c",
  "host/compositor/compositor.c",
  "host/compositor/software.c",
], [...cairo, "-lm"]);
run(layers);
