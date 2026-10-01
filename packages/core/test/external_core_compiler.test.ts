import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { scriptcPin } from "./helpers.ts";

test("the external core compile lane resolves a global-sibling scriptc package", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-global-scriptc-"));
  try {
    const globalModules = path.join(root, "lib", "node_modules");
    const sdkCore = path.join(globalModules, "@native-sdk", "cli", "packages", "core");
    const scriptcRoot = path.join(globalModules, "scriptc");
    const compilerApiRoot = path.join(globalModules, "@scriptc", "compiler");
    const nativeBin = process.platform !== "win32";
    const bin = nativeBin ? "bin/scriptc.exe" : "dist/bootstrap.js";
    const compiler = path.join(scriptcRoot, bin);
    const stage = path.join(root, "stage");
    fs.mkdirSync(sdkCore, { recursive: true });
    fs.mkdirSync(path.dirname(compiler), { recursive: true });
    fs.mkdirSync(compilerApiRoot, { recursive: true });
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(stage, "profile.json"), "{}\n");
    const manifest = path.join(sdkCore, "package.json");
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: scriptcPin } }));
    fs.writeFileSync(path.join(scriptcRoot, "package.json"), JSON.stringify({
      name: "scriptc",
      version: scriptcPin,
      type: "module",
      bin: { scriptc: bin },
    }));
    fs.writeFileSync(path.join(compilerApiRoot, "package.json"), JSON.stringify({
      name: "@scriptc/compiler", version: scriptcPin, type: "module", exports: "./index.js",
    }));
    fs.writeFileSync(path.join(compilerApiRoot, "index.js"), `
import fs from "node:fs";
import path from "node:path";
export function compilerReleaseVersion() { return ${JSON.stringify(scriptcPin)}; }
export async function compileLibrary({ outPath }) {
  fs.writeFileSync(outPath, "global sibling archive");
  const sidecarPath = path.join(path.dirname(outPath), "core.contract.json");
  fs.writeFileSync(sidecarPath, JSON.stringify({ build_id: "global-sibling", model_unbound: [], msg: { unbound: [] } }));
  return { ok: true, archivePath: outPath, sidecarPath };
}
export function renderDiagnostics() { return ""; }
`);
    const compilerSource = `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log(${JSON.stringify(scriptcPin)}); process.exit(0); }
const output = process.argv[process.argv.indexOf("-o") + 1];
fs.writeFileSync(output + ".lib.a", "global sibling archive");
fs.writeFileSync("core.contract.json", JSON.stringify({ build_id: "global-sibling", model_unbound: [], msg: { unbound: [] } }));
`;
    if (nativeBin) {
      const source = path.join(scriptcRoot, "fixture.mjs");
      fs.writeFileSync(source, compilerSource);
      fs.writeFileSync(compiler, `#!/bin/sh\nexec "${process.execPath}" "${source}" "$@"\n`);
      fs.chmodSync(compiler, 0o755);
    } else {
      fs.writeFileSync(compiler, compilerSource);
    }
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
      model_unbound: [],
      msg: { unbound: [] },
    }));
    const sourceScripts = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts");
    const fixtureScripts = path.join(sdkCore, "scripts");
    fs.mkdirSync(fixtureScripts);
    for (const name of ["run_external_core_compiler.mjs", "run_library_compiler.mjs", "compiler_command.mjs"]) {
      fs.copyFileSync(path.join(sourceScripts, name), path.join(fixtureScripts, name));
    }
    const script = path.join(fixtureScripts, "run_external_core_compiler.mjs");
    const archive = path.join(root, "libfixture_core.a");
    const result = spawnSync(process.execPath, [
      script,
      "--stage", stage,
      "--name", "fixture_core",
      "--manifest", manifest,
      "--frontend-sidecar", frontendSidecar,
      "--out-archive", archive,
      "--out-sidecar", path.join(root, "compiled.contract.json"),
      "--compiler-package-origin", manifest,
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.equal(fs.readFileSync(archive, "utf8"), "global sibling archive");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the external core compile lane uses zig-cc for cross-target and native Windows GNU builds", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-cross-"));
  try {
    const stage = path.join(root, "stage");
    fs.mkdirSync(stage);
    fs.writeFileSync(path.join(stage, "profile.json"), "{}\n");
    const manifest = path.join(root, "package.json");
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: scriptcPin } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
      model_unbound: ["phase"],
      msg: { unbound: ["loaded"] },
    }));
    const compiler = path.join(root, "compiler.mjs");
    const zigDir = path.join(root, "toolchain");
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log(${JSON.stringify(scriptcPin)}); process.exit(0); }
if (process.env.SCRIPTC_CC !== "zigcc") { console.error("expected SCRIPTC_CC=zigcc"); process.exit(9); }
if (process.env.SCRIPTC_TARGET !== "x86_64-windows-gnu") { console.error("wrong target: " + process.env.SCRIPTC_TARGET); process.exit(9); }
if (!(process.env.PATH ?? "").startsWith(${JSON.stringify(zigDir)})) { console.error("zig directory missing from PATH front"); process.exit(9); }
const output = process.argv[process.argv.indexOf("-o") + 1];
fs.writeFileSync(output + ".lib.a", "target archive bytes");
fs.writeFileSync("core.contract.json", JSON.stringify({ build_id: "cross-target", model_unbound: [], msg: { unbound: [] } }));
`);
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "run_external_core_compiler.mjs");
    const archive = path.join(root, "libfixture_core.a");
    const compiledSidecar = path.join(root, "compiled.contract.json");
    const env = { ...process.env };
    delete env.SCRIPTC_CC;
    delete env.SCRIPTC_TARGET;
    for (const hostPlatform of ["aarch64-macos-none", "x86_64-windows-gnu"]) {
      const result = spawnSync(process.execPath, [
        script,
        "--stage", stage,
        "--name", "fixture_core",
        "--manifest", manifest,
        "--frontend-sidecar", frontendSidecar,
        "--out-archive", archive,
        "--out-sidecar", compiledSidecar,
        "--host-platform", hostPlatform,
        "--target-platform", "x86_64-windows-gnu",
        "--zig-exe", path.join(zigDir, "zig"),
        "--compiler-js", compiler,
      ], { encoding: "utf8", env });
      assert.equal(result.status, 0, `${hostPlatform}: ${result.stdout}${result.stderr}`);
      assert.equal(fs.readFileSync(archive, "utf8"), "target archive bytes");
      assert.deepEqual(JSON.parse(fs.readFileSync(compiledSidecar, "utf8")), {
        build_id: "cross-target",
        model_fingerprint: "0123456789abcdef",
        has_migrate: false,
        model_unbound: ["phase"],
        msg: { unbound: ["loaded"] },
      });
    }
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
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: scriptcPin } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
      model_unbound: [],
      msg: { unbound: [] },
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
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: scriptcPin } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
      model_unbound: [],
      msg: { unbound: [] },
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
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: scriptcPin } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
      model_unbound: [],
      msg: { unbound: [] },
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
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: scriptcPin } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
      model_unbound: [],
      msg: { unbound: [] },
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
if (process.argv.includes("-v")) { console.log(${JSON.stringify(scriptcPin)}); process.exit(0); }
if (process.env.SCRIPTC_CC !== "zigcc") { console.error("mobile compile missing SCRIPTC_CC=zigcc"); process.exit(9); }
if (process.env.SCRIPTC_TARGET !== "aarch64-apple-ios-simulator") { console.error("mobile compile got SCRIPTC_TARGET=" + process.env.SCRIPTC_TARGET); process.exit(9); }
const output = process.argv[process.argv.indexOf("-o") + 1];
fs.writeFileSync(output + ".lib.a", "ios simulator archive bytes");
fs.writeFileSync("core.contract.json", JSON.stringify({ build_id: "ios-simulator", model_unbound: [], msg: { unbound: [] } }));
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
    fs.writeFileSync(manifest, JSON.stringify({ dependencies: { scriptc: scriptcPin } }));
    const frontendSidecar = path.join(root, "frontend.contract.json");
    fs.writeFileSync(frontendSidecar, JSON.stringify({
      model_fingerprint: "0123456789abcdef",
      has_migrate: false,
      model_unbound: [],
      msg: { unbound: [] },
    }));
    const compiler = path.join(root, "compiler.mjs");
    fs.writeFileSync(compiler, `
import fs from "node:fs";
if (process.argv.includes("-v")) { console.log(${JSON.stringify(scriptcPin)}); process.exit(0); }
if (process.env.SCRIPTC_CC !== undefined || process.env.SCRIPTC_TARGET !== undefined) { console.error("native compile received cross environment"); process.exit(9); }
const output = process.argv[process.argv.indexOf("-o") + 1];
fs.writeFileSync(output + ".lib.a", "native msvc archive bytes");
fs.writeFileSync("core.contract.json", JSON.stringify({ build_id: "native-msvc", model_unbound: [], msg: { unbound: [] } }));
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
