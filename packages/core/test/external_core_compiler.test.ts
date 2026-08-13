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
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
    }));
    const compiler = path.join(root, "compiler.mjs");
    const zigDir = path.join(root, "toolchain");
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log("0.0.29"); process.exit(0); }
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

test("the external core compile lane refuses cross-target Windows MSVC before compiler work", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-msvc-cross-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    const manifest = path.join(root, "package.json");
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
    }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_core_compiler.mjs");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--name", "fixture_core",
      "--manifest", manifest,
      "--frontend-sidecar", frontendSidecar,
      "--out-archive", path.join(root, "libfixture_core.a"),
      "--out-sidecar", path.join(root, "compiled.contract.json"),
      "--host-platform", "aarch64-macos-none",
      "--target-platform", "x86_64-windows-msvc",
      "--compiler", process.execPath,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /cross-target Windows build/);
    assert.match(result.stderr, /x86_64-windows-gnu/);
    assert.doesNotMatch(result.stderr, /external core compiler did not report a version/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the external core compile lane refuses a macOS target from a non-macOS host", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-macos-cross-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    const manifest = path.join(root, "package.json");
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
    }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_core_compiler.mjs");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--name", "fixture_core",
      "--manifest", manifest,
      "--frontend-sidecar", frontendSidecar,
      "--out-archive", path.join(root, "libfixture_core.a"),
      "--out-sidecar", path.join(root, "compiled.contract.json"),
      "--host-platform", "x86_64-linux-gnu",
      "--target-platform", "aarch64-macos-none",
      "--compiler", process.execPath,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /macOS build host only/);
    assert.doesNotMatch(result.stderr, /external core compiler did not report a version/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the external core compile lane refuses pairings outside the compiler's matrix", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-matrix-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    const manifest = path.join(root, "package.json");
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
    }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_core_compiler.mjs");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--name", "fixture_core",
      "--manifest", manifest,
      "--frontend-sidecar", frontendSidecar,
      "--out-archive", path.join(root, "libfixture_core.a"),
      "--out-sidecar", path.join(root, "compiled.contract.json"),
      "--host-platform", "aarch64-macos-none",
      "--target-platform", "wasm32-wasi-musl",
      "--compiler", process.execPath,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /desktop targets the pinned compiler covers/);
    assert.doesNotMatch(result.stderr, /external core compiler did not report a version/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the external core compile lane admits mobile pairings and refuses the rest with the mobile teaching", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-mobile-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    const manifest = path.join(root, "package.json");
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
    }));
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_core_compiler.mjs");
    const refuse = (host, target, pattern) => {
      const result = spawnSync(process.execPath, [
        script,
        "--stage", stage,
        "--name", "fixture_core",
        "--manifest", manifest,
        "--frontend-sidecar", frontendSidecar,
        "--out-archive", path.join(root, "libfixture_core.a"),
        "--out-sidecar", path.join(root, "compiled.contract.json"),
        "--host-platform", host,
        "--target-platform", target,
        "--compiler", process.execPath,
      ], { encoding: "utf8" });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, pattern);
      assert.doesNotMatch(result.stderr, /external core compiler did not report a version/);
    };
    // iOS needs a macOS build host; both families are aarch64 only.
    refuse("x86_64-linux-gnu", "aarch64-ios-simulator", /macOS build host only/);
    refuse("x86_64-linux-gnu", "x86_64-linux-android", /mobile targets the pinned compiler covers/);
    refuse("aarch64-macos-none", "x86_64-ios-none", /mobile targets the pinned compiler covers/);

    // An admitted iOS-simulator compile rides the zig-cc lane under the
    // compiler's own vendor spelling.
    const compiler = path.join(root, "compiler.mjs");
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log("0.0.29"); process.exit(0); }
if (process.env.SCRIPTC_CC !== "zigcc") { console.error("mobile compile missing SCRIPTC_CC=zigcc"); process.exit(9); }
if (process.env.SCRIPTC_TARGET !== "aarch64-apple-ios-simulator") { console.error("mobile compile got SCRIPTC_TARGET=" + process.env.SCRIPTC_TARGET); process.exit(9); }
const output = process.argv[process.argv.indexOf("-o") + 1];
fs.writeFileSync(output + ".lib.a", "ios simulator archive bytes");
fs.writeFileSync("core.contract.json", JSON.stringify({ build_id: "ios-simulator" }));
`);
    const archive = path.join(root, "libfixture_core.a");
    const env = { ...process.env };
    delete env.SCRIPTC_CC;
    delete env.SCRIPTC_TARGET;
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--name", "fixture_core",
      "--manifest", manifest,
      "--frontend-sidecar", frontendSidecar,
      "--out-archive", archive,
      "--out-sidecar", path.join(root, "compiled.contract.json"),
      "--host-platform", "aarch64-macos-none",
      "--target-platform", "aarch64-ios-simulator",
      "--compiler-js", compiler,
    ], { encoding: "utf8", env });
    assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.equal(fs.readFileSync(archive, "utf8"), "ios simulator archive bytes");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the external core compile lane preserves native Windows MSVC", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-msvc-native-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(stage, "profile.json"), "{}\n");
    const manifest = path.join(root, "package.json");
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: "0.0.29" } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
    }));
    const compiler = path.join(root, "compiler.mjs");
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log("0.0.29"); process.exit(0); }
if (process.env.SCRIPTC_CC !== undefined || process.env.SCRIPTC_TARGET !== undefined) { console.error("native compile received cross environment"); process.exit(9); }
const output = process.argv[process.argv.indexOf("-o") + 1];
fs.writeFileSync(output + ".lib.a", "native msvc archive bytes");
fs.writeFileSync("core.contract.json", JSON.stringify({ build_id: "native-msvc" }));
`);
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_core_compiler.mjs");
    const archive = path.join(root, "libfixture_core.a");
    const env = { ...process.env };
    delete env.SCRIPTC_CC;
    delete env.SCRIPTC_TARGET;
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--name", "fixture_core",
      "--manifest", manifest,
      "--frontend-sidecar", frontendSidecar,
      "--out-archive", archive,
      "--out-sidecar", path.join(root, "compiled.contract.json"),
      "--host-platform", "x86_64-windows-gnu",
      "--target-platform", "x86_64-windows-msvc",
      "--compiler-js", compiler,
    ], { encoding: "utf8", env });
    assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.equal(fs.readFileSync(archive, "utf8"), "native msvc archive bytes");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
