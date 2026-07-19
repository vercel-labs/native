// The transpiler gate: transpile the fixture core, build it against the rt
// kernel with the fixture shim, replay the deterministic 1k-message run, and
// require the digest of the snapshot+effect log to equal the hand-written
// Zig oracle's. Then run the 10k keystroke bench for the perf band.
//
// Usage: node scripts/gate.mjs [--keep] [--skip-bench]

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

// MD5 of the run1k output (snapshot hex + effect-log hex) produced by the
// hand-written oracle core over the fixed SplitMix64 message sequence. The
// transpiled core must reproduce it exactly — same model bytes, same effect
// stream, for all 1000 dispatches.
const ORACLE_RUN1K_MD5 = "4e1140c16ba5569ab73db860894f4eba";

const keep = process.argv.includes("--keep");
const skipBench = process.argv.includes("--skip-bench");

const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-gate-"));
const log = (msg) => console.log(`[gate] ${msg}`);

try {
  log(`work dir ${work}`);

  // 1. Transpile the fixture core.
  execFileSync(process.execPath, [
    path.join(pkg, "src/cli.ts"),
    path.join(pkg, "test/fixtures/inbox_core_subset.ts"),
    "-o",
    path.join(work, "inbox_core.zig"),
  ], { stdio: "inherit" });
  log("transpiled inbox_core_subset.ts");

  // 2. Assemble the build: rt kernel + shim + harness.
  for (const [src, dst] of [
    ["rt/rt.zig", "rt.zig"],
    ["test/fixtures/shim.zig", "shim.zig"],
    ["test/fixtures/impl.zig", "impl.zig"],
    ["test/fixtures/bench.zig", "bench.zig"],
  ]) {
    fs.copyFileSync(path.join(pkg, src), path.join(work, dst));
  }

  const zig = (args) => execFileSync("zig", args, { cwd: work, stdio: "inherit" });
  const executableName = (name) => process.platform === "win32" ? `${name}.exe` : name;
  const executable = (name) => path.join(work, executableName(name));

  // 3. Build ReleaseSafe (the shipping mode: index checks stay on).
  zig(["build-lib", "-OReleaseSafe", "-femit-bin=libinbox.a", "shim.zig", "-lc"]);
  zig([
    "build-exe", "-OReleaseSafe", `-femit-bin=${executableName("bench_safe")}`,
    "--dep", "impl", "-Mroot=bench.zig", "-Mimpl=impl.zig", "libinbox.a", "-lc",
  ]);
  log("built ReleaseSafe");

  // 4. run1k digest gate.
  execFileSync(executable("bench_safe"), ["run1k", "run1k.txt"], { cwd: work, stdio: "inherit" });
  const digest = createHash("md5").update(fs.readFileSync(path.join(work, "run1k.txt"))).digest("hex");
  if (digest !== ORACLE_RUN1K_MD5) {
    console.error(`[gate] FAIL run1k digest ${digest} != oracle ${ORACLE_RUN1K_MD5}`);
    process.exit(1);
  }
  log(`run1k digest matches oracle (${digest})`);

  // 5. Perf band.
  if (!skipBench) {
    log("bench10k (ReleaseSafe):");
    execFileSync(executable("bench_safe"), ["bench10k"], { cwd: work, stdio: "inherit" });
    zig(["build-lib", "-OReleaseFast", "-femit-bin=libinbox_fast.a", "shim.zig", "-lc"]);
    zig([
      "build-exe", "-OReleaseFast", `-femit-bin=${executableName("bench_fast")}`,
      "--dep", "impl", "-Mroot=bench.zig", "-Mimpl=impl.zig", "libinbox_fast.a", "-lc",
    ]);
    log("bench10k (ReleaseFast):");
    execFileSync(executable("bench_fast"), ["bench10k"], { cwd: work, stdio: "inherit" });
  }

  log("PASS");
} finally {
  if (keep) {
    log(`kept ${work}`);
  } else {
    fs.rmSync(work, { recursive: true, force: true });
  }
}
