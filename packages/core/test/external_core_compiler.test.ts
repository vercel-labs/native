import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

test("the external core compile lane uses the target-aware zig-cc environment", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-cross-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(stage, "profile.json"), "{}\n");
    const manifest = path.join(root, "package.json");
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: "0.0.28" } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
    }));
    const compiler = path.join(root, "compiler.mjs");
    const zigDir = path.join(root, "toolchain");
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log("0.0.28"); process.exit(0); }
if (process.env.SCRIPTC_CC !== "zigcc") { console.error("expected SCRIPTC_CC=zigcc"); process.exit(9); }
if (process.env.SCRIPTC_TARGET !== "x86_64-windows-gnu") { console.error("wrong target: " + process.env.SCRIPTC_TARGET); process.exit(9); }
if (!(process.env.PATH ?? "").startsWith(${JSON.stringify(zigDir)})) { console.error("zig directory missing from PATH front"); process.exit(9); }
const output = process.argv[process.argv.indexOf("-o") + 1];
fs.writeFileSync(output + ".lib.a", "target archive bytes");
fs.writeFileSync("core.contract.json", JSON.stringify({ build_id: "cross-target" }));
`);
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_core_compiler.mjs");
    const archive = path.join(root, "libfixture_core.a");
    const compiledSidecar = path.join(root, "compiled.contract.json");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--name", "fixture_core",
      "--manifest", manifest,
      "--frontend-sidecar", frontendSidecar,
      "--out-archive", archive,
      "--out-sidecar", compiledSidecar,
      "--host-platform", "aarch64-macos-none",
      "--target-platform", "x86_64-windows-gnu",
      "--zig-exe", path.join(zigDir, "zig"),
      "--compiler-js", compiler,
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.equal(fs.readFileSync(archive, "utf8"), "target archive bytes");
    assert.deepEqual(JSON.parse(fs.readFileSync(compiledSidecar, "utf8")), {
      build_id: "cross-target",
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
    });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
